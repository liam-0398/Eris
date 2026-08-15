{
  Threading contract & event queue (mpti.md Phase 5, mpti.md #1 and #8).
  Four independent primitives, all UI-thread-facing:

  1. A worker-thread -> UI-thread event queue (TMEventQueue), using the
     exact SPSC ring-buffer idiom already proven in this codebase's
     realtime audio path (src/aengine/AudioEngine.pas's NoteRing/
     PushNoteEvent/DrainNoteRing): a fixed-capacity array, plain Integer
     head/tail counters, WriteBarrier before publishing a new Head,
     ReadBarrier before trusting a slot the Head/Tail check says is
     populated. No TCriticalSection, no atomics on the indices - none
     exist anywhere in src/ today, and correctness here comes from the
     same strict single-writer/single-reader discipline the audio engine
     already relies on. WriteBarrier/ReadBarrier are FPC System
     intrinsics - no unit needs to be pulled in for them.

     THE RULE (mpti.md #1): a background/worker thread may only ever
     call MQueuePush. It must never touch a TCellBuffer (MptiCell/
     MptiRender), MptiCore's future widget-state table, or any
     MptiDriver/MptiHeadless state directly - all of that belongs
     exclusively to the UI thread. Posting a TMQueueMsg through this
     queue is the *only* thread-safe crossing point MPTI provides.
     MQueuePush never blocks (mirrors PushNoteEvent, not PushCommand):
     a stalled/slow UI thread must never stall a worker thread, so a
     full queue drops the message rather than waiting.

  2. A real timer/scheduled-callback primitive (FV gap #1: FV only had
     Idle polling). TMTimerSet is UI-thread-only (no cross-thread
     concern, so no barriers) - MPumpTimers is called once per UI
     main-loop iteration, from the same loop that drains TMEventQueue
     and MptiDriver/MptiHeadless input, not from a separate poll path.

  3. A "run after the current handler fully unwinds" primitive (FV gap
     #2): TMDeferredQueue. Also UI-thread-only. A callback queued via
     MDeferCall runs the next time MRunDeferred is called (by
     convention, at the top of the next main-loop iteration) - never
     synchronously/reentrantly from within MDeferCall itself, and a
     callback that itself calls MDeferCall queues for the iteration
     *after* that, so a chain of self-deferring calls can't starve the
     main loop.

  4. A bounded async-wait helper (mpti.md #8), replacing the
     `while AudioEngineIsBusy do Sleep(1)` pattern
     (src/ui/MainForm.pas's non-Windows TForm1.WaitForEngineIdle, the
     concrete unbounded case mpti.md calls out - the tui/ copies already
     independently bounded it at a hardcoded 5000ms via GetTickCount64).
     MBoundedWait takes an explicit Clock function rather than calling
     GetTickCount64 itself, so it - like everything else in MPTI - stays
     headless-testable: a test can inject a fake clock that advances
     without any real wall-clock wait.
}
unit MptiQueue;

{$mode objfpc}{$H+}

interface

uses
  MptiTypes;

const
  MQueueCapacity = 256;
  MTimerCapacity = 64;
  MDeferredCapacity = 64;

type
  { Opaque, caller-defined payload. MPTI itself never interprets Kind or
    Data - Kind is whatever tag the app wants (e.g. "meter update",
    "playhead moved", "recording finished"), Data is caller-owned and
    MPTI never dereferences or frees it. }
  TMQueueMsg = record
    Kind: TMUInt32;
    Param1: TMInt64;
    Param2: TMInt64;
    Data: Pointer;
  end;

  TMEventQueue = record
    Buffer: array[0..MQueueCapacity - 1] of TMQueueMsg;
    Head, Tail: Integer;
  end;

procedure MInitQueue(out Q: TMEventQueue);

{ Producer side - safe to call from any thread, including the UI thread
  itself. Never blocks: returns False and drops Msg if the queue is
  full rather than stalling the caller (see unit doc comment #1). }
function MQueuePush(var Q: TMEventQueue; const Msg: TMQueueMsg): Boolean;

{ Consumer side - UI thread only. Pops one message if available. }
function MQueuePop(var Q: TMEventQueue; out Msg: TMQueueMsg): Boolean;

type
  TMCallback = procedure(UserData: Pointer);
  TMTimerHandle = Integer;

  TMTimerEntry = record
    Active: Boolean;
    DueAtMs: TMInt64;
    IntervalMs: TMInt64; { 0 = one-shot; > 0 = reschedules itself on fire }
    Callback: TMCallback;
    UserData: Pointer;
  end;

  TMTimerSet = record
    Entries: array[0..MTimerCapacity - 1] of TMTimerEntry;
  end;

procedure MInitTimers(out T: TMTimerSet);

{ Schedules Callback to fire at NowMs + DelayMs, then every IntervalMs
  after that if IntervalMs > 0 (one-shot if 0). Returns a handle usable
  with MCancelTimer, or -1 if no free slot (MTimerCapacity exhausted). }
function MScheduleTimer(var T: TMTimerSet; NowMs, DelayMs, IntervalMs: TMInt64;
  Callback: TMCallback; UserData: Pointer): TMTimerHandle;
procedure MCancelTimer(var T: TMTimerSet; Handle: TMTimerHandle);

{ Call once per UI main-loop iteration with the current time. Fires
  (calls directly, synchronously) every timer whose DueAtMs has passed,
  rescheduling repeating ones and deactivating one-shot ones. Not for
  cross-thread use - see unit doc comment #2. }
procedure MPumpTimers(var T: TMTimerSet; NowMs: TMInt64);

type
  TMDeferredEntry = record
    Callback: TMCallback;
    UserData: Pointer;
  end;

  TMDeferredQueue = record
    Entries: array[0..MDeferredCapacity - 1] of TMDeferredEntry;
    Count: Integer;
  end;

procedure MInitDeferred(out Q: TMDeferredQueue);

{ Queues Callback to run on the next MRunDeferred call, never
  immediately/reentrantly. Returns False (and drops the call) if
  MDeferredCapacity is exhausted. UI-thread only - a worker thread
  wanting the UI thread to run something posts through MQueuePush
  instead (see unit doc comment #1 vs #3). }
function MDeferCall(var Q: TMDeferredQueue; Callback: TMCallback; UserData: Pointer): Boolean;

{ Runs every call queued so far, in FIFO order, then clears the queue.
  Calls made *during* this run (a callback that itself calls MDeferCall)
  are appended to a fresh queue and wait for the next MRunDeferred, so
  a chain of self-deferring calls can never starve the caller. }
procedure MRunDeferred(var Q: TMDeferredQueue);

type
  TMConditionFunc = function(UserData: Pointer): Boolean;
  TMPumpProc = procedure(UserData: Pointer);
  TMClockFunc = function: TMInt64;

{ Polls Condition(CondUserData) up to TimeoutMs milliseconds (per Clock,
  never a real-time assumption - see unit doc comment #4), calling
  Pump(PumpUserData) between polls instead of blocking the process -
  Pump is expected to be the app's own "run one iteration of input/
  queue/timer/deferred processing" routine, so the whole app stays
  responsive (Alt+X, redraws, everything) while waiting, unlike
  `while Busy do Sleep(1)`. Sleeps PollIntervalMs between polls (0 = no
  sleep, busy-poll bounded only by TimeoutMs - what a headless test with
  a fake Clock should pass). Returns True if Condition became true
  within the timeout, False if the timeout elapsed first. }
function MBoundedWait(Condition: TMConditionFunc; CondUserData: Pointer;
  Pump: TMPumpProc; PumpUserData: Pointer; Clock: TMClockFunc;
  TimeoutMs: Integer; PollIntervalMs: Integer = 1): Boolean;

implementation

uses
  SysUtils;

procedure MInitQueue(out Q: TMEventQueue);
begin
  Q.Head := 0;
  Q.Tail := 0;
end;

function MQueuePush(var Q: TMEventQueue; const Msg: TMQueueMsg): Boolean;
var
  NextHead: Integer;
begin
  NextHead := (Q.Head + 1) mod MQueueCapacity;
  if NextHead = Q.Tail then
    Exit(False); { full - drop rather than stall the calling thread }

  Q.Buffer[Q.Head] := Msg;
  { the slot's contents must be visible to the consumer before the head
    that publishes it - mirrors AudioEngine.pas's PushNoteEvent }
  WriteBarrier;
  Q.Head := NextHead;
  Result := True;
end;

function MQueuePop(var Q: TMEventQueue; out Msg: TMQueueMsg): Boolean;
begin
  if Q.Tail = Q.Head then
    Exit(False);
  { pairs with MQueuePush's WriteBarrier - don't let the slot read hoist
    above the head/tail check that says it's populated }
  ReadBarrier;
  Msg := Q.Buffer[Q.Tail];
  Q.Tail := (Q.Tail + 1) mod MQueueCapacity;
  Result := True;
end;

procedure MInitTimers(out T: TMTimerSet);
var
  I: Integer;
begin
  for I := 0 to MTimerCapacity - 1 do
    T.Entries[I].Active := False;
end;

function MScheduleTimer(var T: TMTimerSet; NowMs, DelayMs, IntervalMs: TMInt64;
  Callback: TMCallback; UserData: Pointer): TMTimerHandle;
var
  I: Integer;
begin
  for I := 0 to MTimerCapacity - 1 do
    if not T.Entries[I].Active then
    begin
      T.Entries[I].Active := True;
      T.Entries[I].DueAtMs := NowMs + DelayMs;
      T.Entries[I].IntervalMs := IntervalMs;
      T.Entries[I].Callback := Callback;
      T.Entries[I].UserData := UserData;
      Exit(I);
    end;
  Result := -1;
end;

procedure MCancelTimer(var T: TMTimerSet; Handle: TMTimerHandle);
begin
  if (Handle >= 0) and (Handle < MTimerCapacity) then
    T.Entries[Handle].Active := False;
end;

procedure MPumpTimers(var T: TMTimerSet; NowMs: TMInt64);
var
  I: Integer;
begin
  for I := 0 to MTimerCapacity - 1 do
    if T.Entries[I].Active and (NowMs >= T.Entries[I].DueAtMs) then
    begin
      if T.Entries[I].IntervalMs > 0 then
        T.Entries[I].DueAtMs := T.Entries[I].DueAtMs + T.Entries[I].IntervalMs
      else
        T.Entries[I].Active := False;
      T.Entries[I].Callback(T.Entries[I].UserData);
    end;
end;

procedure MInitDeferred(out Q: TMDeferredQueue);
begin
  Q.Count := 0;
end;

function MDeferCall(var Q: TMDeferredQueue; Callback: TMCallback; UserData: Pointer): Boolean;
begin
  if Q.Count >= MDeferredCapacity then
    Exit(False);
  Q.Entries[Q.Count].Callback := Callback;
  Q.Entries[Q.Count].UserData := UserData;
  Inc(Q.Count);
  Result := True;
end;

procedure MRunDeferred(var Q: TMDeferredQueue);
var
  Batch: TMDeferredQueue;
  I: Integer;
begin
  { Snapshot-then-clear before running anything: a callback that calls
    MDeferCall during this loop appends to the now-empty Q, so it lands
    in the *next* MRunDeferred rather than growing the batch we're
    currently iterating (which would either loop forever on a
    self-deferring call or run it same-iteration, the opposite of what
    "runs after full unwind" promises). }
  Batch := Q;
  Q.Count := 0;
  for I := 0 to Batch.Count - 1 do
    Batch.Entries[I].Callback(Batch.Entries[I].UserData);
end;

function MBoundedWait(Condition: TMConditionFunc; CondUserData: Pointer;
  Pump: TMPumpProc; PumpUserData: Pointer; Clock: TMClockFunc;
  TimeoutMs: Integer; PollIntervalMs: Integer): Boolean;
var
  Deadline: TMInt64;
begin
  Deadline := Clock() + TimeoutMs;
  while not Condition(CondUserData) do
  begin
    if Clock() > Deadline then
      Exit(False);
    Pump(PumpUserData);
    if PollIntervalMs > 0 then
      Sleep(PollIntervalMs);
  end;
  Result := True;
end;

end.
