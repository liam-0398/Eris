{
  Immediate-mode core (mpti.md Phase 6): the ID-keyed persistent-state
  table, focus management, and per-pane key mapping.

  ID-keyed retained state (explicit design decision, stated at planning
  time and restated here since this is the unit that implements it):
  MPTI is immediate-mode - callers redraw the whole visible frame from
  current application state every frame, not a persistent view-object
  graph - but true zero-state immediate mode still needs somewhere to
  keep a text cursor position, scroll offset, in-progress drag, etc.
  That state lives here, in a framework-owned open-addressing hash table
  keyed by a caller-supplied stable ID (a string like
  "track_pane/track_3/mute_btn", hashed once via MWidgetID), not in a
  persistent widget object. Every future widget-drawing function
  (Phase 7+) takes an ID as its first parameter and calls
  MGetWidgetState to get at its slot in this table.

  Garbage collection policy, stated explicitly because it's a real
  design tradeoff: entries are NOT reaped every frame just for not being
  drawn that frame - a widget hidden for a few frames (a collapsed
  panel, an off-screen scroll target) should not lose its retained state
  the instant it stops being drawn. Instead, MSweepStaleWidgets is an
  explicit, caller-invoked operation (call it occasionally - e.g. once a
  second - not every frame) that reaps anything not touched in
  StaleAfterFrames frames. Something genuinely gone for good (a deleted
  track's controls) should use MForgetWidget explicitly instead of
  waiting on the sweep.

  Focus default (FV gap #7): a widget's own click handling is expected
  to call MSetFocus and perform its click action in the same call -
  click-to-focus-also-acts is the framework-level default for any
  docked/always-visible container. "Click once to wake, again to act"
  is something a floating/overlapping widget (Phase 7+, e.g. a popup
  menu) opts into itself; this unit does not impose it.

  Per-pane key mapping (hard requirement 12, FV gap #9): TMKeymapTable
  is the single place in MPTI where "what claims this key" is looked
  up - the same physical chord (e.g. Ctrl+D) resolves to a different
  app-defined action depending on which pane currently owns focus
  (timeline pane: duplicate clip; track pane: duplicate track). MPTI
  itself never interprets the Action tag - that's entirely the app's
  domain, exactly like TMQueueMsg.Kind in MptiQueue.

  Phase 6.5 additions (identified during the Phase 6 review as gaps in
  the substrate, not things a widget library alone would cover):
  TMHitRegistry/MRegisterHitRect/MHitTest/MDispatchMouse is the mouse
  counterpart to the keymap table above - "what claims this click,"
  resolved against whatever rects were registered while this frame was
  drawn (immediate-mode, so never stale). MBeginFrame is the canonical
  per-iteration ordering of the Phase 5 primitives (timers, deferred
  calls, frame-touch tracking) that nothing had written down before -
  see its own doc comment for the exact order and why it matters.
}
unit MptiCore;

{$mode objfpc}{$H+}

interface

uses
  MptiTypes, MptiInput, MptiLayout, MptiQueue;

type
  TMWidgetID = TMUInt64;

  { Union-of-fields persistent state, not a per-widget-type record: a
    hash table keyed by ID has no way to know in advance which shape of
    state a given ID's widget wants, and MPTI is deliberately
    minimal-OOP (hard requirement 5) so there's no polymorphic base
    state object to subclass. Any given widget only ever reads/writes
    the handful of fields relevant to it; the rest sit unused, which
    costs a few dozen bytes per slot - a non-issue at DAW-UI widget
    counts (hundreds, not millions). }
  TMWidgetState = record
    ScrollX, ScrollY: Integer;
    CursorPos: Integer;    { text cursor / list selection index }
    SelectStart: Integer;  { text selection anchor; -1 = no selection }
    DragActive: Boolean;
    DragStartX, DragStartY: Integer;
    Toggled: Boolean;      { checkbox/toggle-button/expand-collapse state }
    TextBuf: string;       { text-input contents }
  end;
  PMWidgetState = ^TMWidgetState;

  TMCoreSlot = record
    ID: TMWidgetID;
    InUse: Boolean;
    LastFrameSeen: TMUInt64;
    State: TMWidgetState;
  end;

  TMCoreState = record
    Slots: array of TMCoreSlot;
    Capacity: Integer;     { always a power of two }
    UsedCount: Integer;
    FrameCounter: TMUInt64;
    FocusedID: TMWidgetID; { 0 = nothing focused }
    FocusedPane: TMWidgetID; { 0 = no pane owns focus }
  end;

{ FNV-1a 64-bit hash of Name, remapped away from 0 (0 is the table's
  empty-slot sentinel - a widget ID must never collide with it). Two
  different Name strings hashing to the same value is possible in
  principle (64-bit FNV-1a, not cryptographic) but astronomically
  unlikely at any realistic widget-ID count; not defended against
  further, consistent with performance being paramount over handling a
  practically-nonexistent case. }
function MWidgetID(const Name: string): TMWidgetID;

procedure MInitCore(out Core: TMCoreState; InitialCapacity: Integer = 256);

{ Increment the frame counter - call once per frame, before any
  MGetWidgetState calls that frame. Marks the start of a new frame for
  the "was this ID touched this frame" bookkeeping MSweepStaleWidgets
  relies on. }
procedure MBeginCoreFrame(var Core: TMCoreState);

{ Finds ID's slot, creating one (growing/rehashing the table first if
  the load factor requires it) if this is the first time ID has been
  seen. Marks the slot as touched this frame. Returns a pointer so
  callers can read and mutate State's fields directly - this is the
  framework-owned persistent-state table the whole design rests on. }
function MGetWidgetState(var Core: TMCoreState; ID: TMWidgetID): PMWidgetState;

{ Reaps any slot not touched in the last StaleAfterFrames frames. Call
  this occasionally (e.g. once a second), not every frame - see unit
  doc comment for why aggressive per-frame reaping would be wrong. }
procedure MSweepStaleWidgets(var Core: TMCoreState; StaleAfterFrames: TMUInt64);

{ Explicit removal for state known to be permanently gone (e.g. a
  deleted track's controls) - don't wait on the next sweep. }
procedure MForgetWidget(var Core: TMCoreState; ID: TMWidgetID);

function MIsFocused(const Core: TMCoreState; ID: TMWidgetID): Boolean; inline;
procedure MSetFocus(var Core: TMCoreState; ID: TMWidgetID; PaneID: TMWidgetID);
procedure MClearFocus(var Core: TMCoreState);

type
  { Action is an app-defined tag, uninterpreted by MPTI - identical
    convention to TMQueueMsg.Kind in MptiQueue. }
  TMKeyBinding = record
    Key: TMKeyCode;
    Mods: TMKeyModSet;
    Action: TMUInt32;
  end;

  TMPaneKeymap = record
    PaneID: TMWidgetID;
    Bindings: array of TMKeyBinding;
  end;

  TMKeymapTable = record
    Panes: array of TMPaneKeymap;
  end;

procedure MInitKeymapTable(out KT: TMKeymapTable);

{ Binds Key+Mods to Action within PaneID's keymap, creating PaneID's
  keymap on first use. Rebinding the same Key+Mods within the same pane
  overwrites the previous Action rather than creating a duplicate
  binding - MResolveKey's result must always be unambiguous. }
procedure MBindKey(var KT: TMKeymapTable; PaneID: TMWidgetID; Key: TMKeyCode;
  Mods: TMKeyModSet; Action: TMUInt32);

{ The single place in MPTI where "what claims this key" is resolved
  (mpti.md FV gap #9) - looks up Key+Mods within PaneID's keymap only
  (hard requirement 12: the same chord may mean something different, or
  nothing at all, in a different pane). Returns False with Action
  undefined if PaneID has no keymap or nothing is bound to Key+Mods
  within it. }
function MResolveKey(const KT: TMKeymapTable; PaneID: TMWidgetID; Key: TMKeyCode;
  Mods: TMKeyModSet; out Action: TMUInt32): Boolean;

const
  MHitCapacity = 512;

type
  { Input-to-widget hit-test router (Phase 6.5, gap #2): given a mouse
    event and the rects each widget registered while drawing itself,
    which widget did it land on? Immediate-mode, so this registry only
    ever reflects the CURRENT frame's draw calls - MBeginHitRegistry
    clears it, so there is never a stale hit region left over from a
    widget that stopped drawing.

    Two supported usage patterns, both valid, pick per widget:
    - Self-check (same-frame, most common): a widget calls
      MRegisterHitRect for its own rect, then immediately checks
      MRectContains against that same rect for this iteration's already-
      decoded input events. Zero latency between click and reaction.
    - Centralized (MHitTest/MDispatchMouse): call once the frame's draw
      pass has fully populated the registry, to resolve a single event
      against every widget registered so far, topmost (last-registered,
      i.e. drawn last/on top) wins. Needed wherever z-order actually
      matters and self-check isn't enough on its own - a popup menu or
      dialog drawn over a base pane, where the base pane's own widgets
      must not react to a click that a floating widget on top of them
      already claimed. }
  TMHitEntry = record
    ID, PaneID: TMWidgetID;
    Rect: TMRect;
  end;

  TMHitRegistry = record
    Entries: array[0..MHitCapacity - 1] of TMHitEntry;
    Count: Integer;
  end;

{ Call once per frame, before drawing - clears prior registrations. }
procedure MBeginHitRegistry(var HR: TMHitRegistry);

{ Called by a widget's own draw function as it draws itself. Silently
  drops the registration past MHitCapacity rather than growing
  unbounded or raising - a screen has a hard ceiling on how many
  simultaneously-visible widgets fit in it at all, so MHitCapacity is
  sized generously above any realistic single-frame widget count rather
  than being a real limit callers need to plan around. }
procedure MRegisterHitRect(var HR: TMHitRegistry; ID, PaneID: TMWidgetID; const R: TMRect);

{ Topmost (last-registered) entry containing (X, Y), if any. }
function MHitTest(const HR: TMHitRegistry; X, Y: Integer; out ID, PaneID: TMWidgetID): Boolean;

{ Convenience wrapper: resolves Ev against HR, and - for a press action
  only - calls MSetFocus on the hit widget (FV gap #7's click-to-focus-
  also-acts default, already documented at the top of this unit, applied
  here centrally so callers using the centralized dispatch pattern get
  it for free rather than re-implementing it per widget). Does nothing
  to focus for hover/drag/release/wheel actions. Returns False (Core's
  focus unchanged) if Ev didn't land on anything registered. }
function MDispatchMouse(var Core: TMCoreState; const HR: TMHitRegistry;
  const Ev: TMMouseEvent; out ID, PaneID: TMWidgetID): Boolean;

{ Tab-within-a-pane focus cycling (mpti.md hard requirement 12's other
  half: per-pane key mappings imply per-pane widget navigation too, not
  just per-pane commands). Moves Core's focus to the next (Forward=True)
  or previous registered widget whose PaneID is WithinPane, wrapping
  around; if nothing in the pane currently holds focus, lands on the
  first entry found instead. HR must already reflect every widget the
  pane drew THIS frame - call this only after the pane's own widgets
  have run (typically once, at the end of the frame, after every pane an
  app might tab into has drawn - see an app's own main loop for why:
  widgets self-register into HR as a side effect of drawing, so the full
  per-pane list only exists once they all have). Returns True if a
  widget in the pane now holds focus. }
function MFocusCycleInPane(var Core: TMCoreState; const HR: TMHitRegistry;
  WithinPane: TMWidgetID; Forward: Boolean): Boolean;

{ Pane-level counterpart to MFocusCycleInPane: moves Core.FocusedPane to
  the next/previous entry in the app's own Panes list (its docks/panels,
  in whatever order it wants Shift+Tab-equivalent switching to follow),
  then immediately focuses that pane's own first widget via
  MFocusCycleInPane, so switching panes always lands on something usable
  rather than leaving focus nowhere. Same HR-must-be-current-frame
  requirement as MFocusCycleInPane. Returns the new FocusedPane, or 0 if
  Panes is empty. }
function MFocusNextPane(var Core: TMCoreState; const HR: TMHitRegistry;
  const Panes: array of TMWidgetID; Forward: Boolean): TMWidgetID;

{ Phase 6.5 gap #3: the canonical per-iteration bookkeeping order for the
  Phase 5 primitives, in one place instead of every app re-deriving it.
  Call once per main-loop iteration, AFTER MRunOnce/MHeadlessFeedInput
  has produced this iteration's input events (MResolveKey/MDispatchMouse
  consume those separately - this only handles what doesn't depend on
  them) and BEFORE the app draws its frame:
    1. MBeginCoreFrame - starts this frame's widget-touch tracking.
    2. MPumpTimers - fires anything due; a timer callback may itself
       call MDeferCall or MQueuePush, both safe to do from here.
    3. MRunDeferred - runs whatever was deferred by the PREVIOUS
       iteration's handlers (never the current one - MRunDeferred's own
       contract guarantees that).
  Draining Queue itself is deliberately NOT done here: a TMQueueMsg's
  meaning is entirely app-defined (see MptiQueue's doc comment), so
  there is no generic handling to provide - call MQueuePop in a loop
  right after this returns. }
procedure MBeginFrame(var Core: TMCoreState; var Timers: TMTimerSet;
  var Deferred: TMDeferredQueue; NowMs: TMInt64);

implementation

function MWidgetID(const Name: string): TMWidgetID;
const
  FNVOffsetBasis = TMUInt64($CBF29CE484222325);
  FNVPrime       = TMUInt64($100000001B3);
var
  I: Integer;
  H: TMUInt64;
begin
  H := FNVOffsetBasis;
  for I := 1 to Length(Name) do
  begin
    H := H xor TMUInt64(Byte(Name[I]));
    H := H * FNVPrime;
  end;
  if H = 0 then
    H := 1; { 0 is the empty-slot sentinel; remap the one colliding hash }
  Result := H;
end;

procedure MInitCore(out Core: TMCoreState; InitialCapacity: Integer);
var
  I: Integer;
begin
  Core.Capacity := InitialCapacity;
  SetLength(Core.Slots, Core.Capacity);
  for I := 0 to Core.Capacity - 1 do
    Core.Slots[I].InUse := False;
  Core.UsedCount := 0;
  Core.FrameCounter := 0;
  Core.FocusedID := 0;
  Core.FocusedPane := 0;
end;

procedure MBeginCoreFrame(var Core: TMCoreState);
begin
  Inc(Core.FrameCounter);
end;

{ Open-addressing linear probe, table size always a power of two so
  "mod Capacity" is a mask. Forward-declared for use by both
  MGetWidgetState and the grow path inside it. }
function FindSlot(var Core: TMCoreState; ID: TMWidgetID): Integer; forward;

procedure GrowCore(var Core: TMCoreState);
var
  OldSlots: array of TMCoreSlot;
  OldCapacity, I, Idx: Integer;
begin
  OldSlots := Core.Slots;
  OldCapacity := Core.Capacity;

  Core.Capacity := Core.Capacity * 2;
  SetLength(Core.Slots, Core.Capacity);
  for I := 0 to Core.Capacity - 1 do
    Core.Slots[I].InUse := False;

  for I := 0 to OldCapacity - 1 do
    if OldSlots[I].InUse then
    begin
      Idx := FindSlot(Core, OldSlots[I].ID);
      Core.Slots[Idx] := OldSlots[I];
    end;
end;

function FindSlot(var Core: TMCoreState; ID: TMWidgetID): Integer;
var
  Idx, Mask: Integer;
begin
  Mask := Core.Capacity - 1;
  Idx := Integer(ID and TMUInt64(Mask));
  while Core.Slots[Idx].InUse and (Core.Slots[Idx].ID <> ID) do
    Idx := (Idx + 1) and Mask;
  Result := Idx;
end;

function MGetWidgetState(var Core: TMCoreState; ID: TMWidgetID): PMWidgetState;
var
  Idx: Integer;
begin
  { Grow before insert whenever load factor would exceed ~70% - done
    up front so FindSlot always has room to terminate its probe. }
  if (Core.UsedCount + 1) * 10 > Core.Capacity * 7 then
    GrowCore(Core);

  Idx := FindSlot(Core, ID);
  if not Core.Slots[Idx].InUse then
  begin
    Core.Slots[Idx].InUse := True;
    Core.Slots[Idx].ID := ID;
    FillChar(Core.Slots[Idx].State, SizeOf(TMWidgetState), 0);
    Core.Slots[Idx].State.SelectStart := -1;
    Core.Slots[Idx].State.TextBuf := '';
    Inc(Core.UsedCount);
  end;
  Core.Slots[Idx].LastFrameSeen := Core.FrameCounter;
  Result := @Core.Slots[Idx].State;
end;

procedure MSweepStaleWidgets(var Core: TMCoreState; StaleAfterFrames: TMUInt64);
var
  I: Integer;
  Kept: array of TMCoreSlot;
  KeptCount: Integer;
begin
  { A slot cleared in place inside an open-addressing table would break
    the probe chains of every entry that landed past it via collision,
    so reaping rebuilds the table from the surviving entries instead of
    clearing slots in place. Sweeps are infrequent (caller-paced, e.g.
    once a second) so this O(Capacity) rebuild is not a hot-path cost. }
  KeptCount := 0;
  SetLength(Kept, Core.UsedCount);
  for I := 0 to Core.Capacity - 1 do
    if Core.Slots[I].InUse and
       (Core.FrameCounter - Core.Slots[I].LastFrameSeen <= StaleAfterFrames) then
    begin
      Kept[KeptCount] := Core.Slots[I];
      Inc(KeptCount);
    end;

  for I := 0 to Core.Capacity - 1 do
    Core.Slots[I].InUse := False;
  Core.UsedCount := 0;

  for I := 0 to KeptCount - 1 do
  begin
    Core.Slots[FindSlot(Core, Kept[I].ID)] := Kept[I];
    Inc(Core.UsedCount);
  end;
end;

procedure MForgetWidget(var Core: TMCoreState; ID: TMWidgetID);
var
  I: Integer;
  Kept: array of TMCoreSlot;
  KeptCount: Integer;
begin
  { Same rebuild-from-survivors approach as MSweepStaleWidgets and for
    the same reason: clearing ID's slot in place would break the probe
    chain of anything that landed past it via collision. Filters on ID
    instead of staleness; everything else is identical. }
  KeptCount := 0;
  SetLength(Kept, Core.UsedCount);
  for I := 0 to Core.Capacity - 1 do
    if Core.Slots[I].InUse and (Core.Slots[I].ID <> ID) then
    begin
      Kept[KeptCount] := Core.Slots[I];
      Inc(KeptCount);
    end;

  for I := 0 to Core.Capacity - 1 do
    Core.Slots[I].InUse := False;
  Core.UsedCount := 0;

  for I := 0 to KeptCount - 1 do
  begin
    Core.Slots[FindSlot(Core, Kept[I].ID)] := Kept[I];
    Inc(Core.UsedCount);
  end;
end;

function MIsFocused(const Core: TMCoreState; ID: TMWidgetID): Boolean; inline;
begin
  Result := (ID <> 0) and (Core.FocusedID = ID);
end;

procedure MSetFocus(var Core: TMCoreState; ID: TMWidgetID; PaneID: TMWidgetID);
begin
  Core.FocusedID := ID;
  Core.FocusedPane := PaneID;
end;

procedure MClearFocus(var Core: TMCoreState);
begin
  Core.FocusedID := 0;
  Core.FocusedPane := 0;
end;

procedure MInitKeymapTable(out KT: TMKeymapTable);
begin
  SetLength(KT.Panes, 0);
end;

function FindPane(const KT: TMKeymapTable; PaneID: TMWidgetID): Integer;
var
  I: Integer;
begin
  for I := 0 to High(KT.Panes) do
    if KT.Panes[I].PaneID = PaneID then
      Exit(I);
  Result := -1;
end;

procedure MBindKey(var KT: TMKeymapTable; PaneID: TMWidgetID; Key: TMKeyCode;
  Mods: TMKeyModSet; Action: TMUInt32);
var
  PaneIdx, BindIdx: Integer;
begin
  PaneIdx := FindPane(KT, PaneID);
  if PaneIdx < 0 then
  begin
    SetLength(KT.Panes, Length(KT.Panes) + 1);
    PaneIdx := High(KT.Panes);
    KT.Panes[PaneIdx].PaneID := PaneID;
    SetLength(KT.Panes[PaneIdx].Bindings, 0);
  end;

  for BindIdx := 0 to High(KT.Panes[PaneIdx].Bindings) do
    if (KT.Panes[PaneIdx].Bindings[BindIdx].Key = Key)
       and (KT.Panes[PaneIdx].Bindings[BindIdx].Mods = Mods) then
    begin
      KT.Panes[PaneIdx].Bindings[BindIdx].Action := Action;
      Exit;
    end;

  SetLength(KT.Panes[PaneIdx].Bindings, Length(KT.Panes[PaneIdx].Bindings) + 1);
  BindIdx := High(KT.Panes[PaneIdx].Bindings);
  KT.Panes[PaneIdx].Bindings[BindIdx].Key := Key;
  KT.Panes[PaneIdx].Bindings[BindIdx].Mods := Mods;
  KT.Panes[PaneIdx].Bindings[BindIdx].Action := Action;
end;

function MResolveKey(const KT: TMKeymapTable; PaneID: TMWidgetID; Key: TMKeyCode;
  Mods: TMKeyModSet; out Action: TMUInt32): Boolean;
var
  PaneIdx, I: Integer;
begin
  PaneIdx := FindPane(KT, PaneID);
  if PaneIdx < 0 then
    Exit(False);
  for I := 0 to High(KT.Panes[PaneIdx].Bindings) do
    if (KT.Panes[PaneIdx].Bindings[I].Key = Key)
       and (KT.Panes[PaneIdx].Bindings[I].Mods = Mods) then
    begin
      Action := KT.Panes[PaneIdx].Bindings[I].Action;
      Exit(True);
    end;
  Result := False;
end;

procedure MBeginHitRegistry(var HR: TMHitRegistry);
begin
  HR.Count := 0;
end;

procedure MRegisterHitRect(var HR: TMHitRegistry; ID, PaneID: TMWidgetID; const R: TMRect);
begin
  if HR.Count >= MHitCapacity then
    Exit; { see interface doc comment: silently dropped, not an error }
  HR.Entries[HR.Count].ID := ID;
  HR.Entries[HR.Count].PaneID := PaneID;
  HR.Entries[HR.Count].Rect := R;
  Inc(HR.Count);
end;

function MHitTest(const HR: TMHitRegistry; X, Y: Integer; out ID, PaneID: TMWidgetID): Boolean;
var
  I: Integer;
begin
  { Scan from the most-recently-registered entry backwards: later draws
    are drawn on top in immediate mode, so the last registration whose
    rect contains (X, Y) is the topmost, correct hit. }
  for I := HR.Count - 1 downto 0 do
    if MRectContains(HR.Entries[I].Rect, X, Y) then
    begin
      ID := HR.Entries[I].ID;
      PaneID := HR.Entries[I].PaneID;
      Exit(True);
    end;
  Result := False;
end;

function MDispatchMouse(var Core: TMCoreState; const HR: TMHitRegistry;
  const Ev: TMMouseEvent; out ID, PaneID: TMWidgetID): Boolean;
begin
  Result := MHitTest(HR, Ev.X, Ev.Y, ID, PaneID);
  if Result and (Ev.Action = maPress) then
    MSetFocus(Core, ID, PaneID);
end;

function MFocusCycleInPane(var Core: TMCoreState; const HR: TMHitRegistry;
  WithinPane: TMWidgetID; Forward: Boolean): Boolean;
var
  Ids: array[0..MHitCapacity - 1] of TMWidgetID;
  Count, I, J, CurIdx, NewIdx: Integer;
  Dup: Boolean;
begin
  Count := 0;
  for I := 0 to HR.Count - 1 do
    if HR.Entries[I].PaneID = WithinPane then
    begin
      Dup := False;
      for J := 0 to Count - 1 do
        if Ids[J] = HR.Entries[I].ID then
        begin
          Dup := True;
          Break;
        end;
      if not Dup then
      begin
        Ids[Count] := HR.Entries[I].ID;
        Inc(Count);
      end;
    end;

  Result := False;
  if Count = 0 then
    Exit;

  CurIdx := -1;
  for I := 0 to Count - 1 do
    if Ids[I] = Core.FocusedID then
    begin
      CurIdx := I;
      Break;
    end;

  if CurIdx < 0 then
    NewIdx := 0
  else if Forward then
    NewIdx := (CurIdx + 1) mod Count
  else
    NewIdx := (CurIdx + Count - 1) mod Count;

  MSetFocus(Core, Ids[NewIdx], WithinPane);
  Result := True;
end;

function MFocusNextPane(var Core: TMCoreState; const HR: TMHitRegistry;
  const Panes: array of TMWidgetID; Forward: Boolean): TMWidgetID;
var
  CurIdx, NewIdx, I: Integer;
begin
  Result := 0;
  if Length(Panes) = 0 then
    Exit;

  CurIdx := -1;
  for I := 0 to High(Panes) do
    if Panes[I] = Core.FocusedPane then
    begin
      CurIdx := I;
      Break;
    end;

  if CurIdx < 0 then
    NewIdx := 0
  else if Forward then
    NewIdx := (CurIdx + 1) mod Length(Panes)
  else
    NewIdx := (CurIdx + Length(Panes) - 1) mod Length(Panes);

  MClearFocus(Core);
  MFocusCycleInPane(Core, HR, Panes[NewIdx], True);
  Result := Panes[NewIdx];
end;

procedure MBeginFrame(var Core: TMCoreState; var Timers: TMTimerSet;
  var Deferred: TMDeferredQueue; NowMs: TMInt64);
begin
  MBeginCoreFrame(Core);
  MPumpTimers(Timers, NowMs);
  MRunDeferred(Deferred);
end;

end.
