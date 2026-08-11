unit AudioEngine;

{$mode objfpc}{$H+}

interface

const
  { must stay equal to SampleTypes.CanonicalSampleRate, which every sample in
    the pool is converted to on import - see that constant's comment. Can't
    just reference it: this interface section has no uses clause. }
  ProjectSampleRate = 44100;
  { Ceiling on warp markers per clip - these back the fixed-size
    MarkerSource/MarkerTimeline arrays in TPlaybackClip below, which have to
    be fixed-size to stay realtime-safe. Sized for pinning a marker to every
    hit across a multi-bar phrase (a four-bar break with a marker on each
    snare is already past the old limit of 8, and quantising individual synth
    hits wants far more), at 16 bytes per marker per clip. }
  MaxClipWarpMarkers = 128;

type
  TPlaybackClip = record
    Data: PSingle;
    FrameCount: Integer;
    Channels: Integer;
    Offset: Int64;
    Length: Int64;
    Position: Int64;
    Gain: Single;
    MarkerCount: Integer; { 0 = unwarped 1:1 playback }
    MarkerSource: array[0..MaxClipWarpMarkers - 1] of Int64;
    MarkerTimeline: array[0..MaxClipWarpMarkers - 1] of Int64;
    WarpMode: Integer; { 0 = Beats (transient slices), 1 = RePitch (vari-speed),
      2 = Tones (pitch-synchronous, for sustained low-frequency material) }
    PeriodFrames: Integer; { detected fundamental period of the source sample,
      0 if none - Tones mode only, see TonesClipSample }
    DetuneSemitones: Single; { independent pitch trim that never changes the
      clip's own Length/Position - see DetunedClipSample }
    Transients: PInt64; { raw pointer into Project.SampleTransients[SampleID]'s
      data, same lifetime/ownership pattern as Data - see ClipSourcePosition }
    TransientCount: Integer;
  end;
  PPlaybackClip = ^TPlaybackClip;

procedure AudioEngineInit;
procedure AudioEngineShutdown;
procedure AudioEngineSetTrackClips(ATrackIndex: Integer; AItems: PPlaybackClip;
  ACount: Integer);
procedure AudioEnginePlay;
procedure AudioEngineStop;
procedure AudioEngineSeek(AFrame: Int64);
procedure AudioEngineSetLoop(AStart, AEnd: Int64);
procedure AudioEngineClearLoop;
procedure AudioEngineTriggerNote(ATrackIndex: Integer; AData: PSingle;
  AFrameCount, AChannels: Integer; ASemitoneOffset: Single; AGain: Single);
{ Same note trigger as above, but safe to call from a foreign realtime thread
  - specifically the MIDI input callback, which on Windows runs on a thread
  owned by winmm and is not allowed to block, allocate, or re-enter the
  system. AudioEngineTriggerNote can't serve that: it goes through
  PushCommand, which is documented single-producer/main-thread-only and will
  Sleep(1) in a loop while it waits for ring space. Calling it from the MIDI
  callback would both race the main thread on RingHead and risk stalling a
  driver thread for up to a quarter second.
  So this is a second, independent SPSC ring - exactly ONE thread may call it
  (the MIDI callback), drained by the audio thread inside DrainCommands. It
  never waits: if the ring is full the note is dropped, which at 64 slots
  means a burst no human is playing anyway. }
procedure AudioEngineTriggerNoteRT(ATrackIndex: Integer; AData: PSingle;
  AFrameCount, AChannels: Integer; ASemitoneOffset: Single; AGain: Single);
{ Clears every effect's live DSP state - reverb tails, delay lines, filter
  memory, compressor envelopes - without touching the transport or the
  backend. AudioEngineInit does this as part of a full start-up; File>New
  needs the same clean slate without tearing the audio device down, otherwise
  the new project inherits the previous one's tails. Must not be called from
  a realtime thread. }
procedure AudioEngineResetEffectState;
function AudioEngineIsPlaying: Boolean;
{ True while the realtime thread could still touch sample memory - Playing,
  a live note, or a note's release tail (AnyLiveNoteActive covers both) -
  i.e. the condition TPlaybackThread.Execute itself gates FillBlock on.
  AudioEngineIsPlaying alone misses fading-note tails still decaying after
  Stop, which is exactly the window a caller about to free sample memory
  (Project.NewProject via File>New/Open) needs to wait out - freeing out
  from under a still-reading fading note is a use-after-free that corrupts
  the heap for the rest of the process, not just that one note. }
function AudioEngineIsBusy: Boolean;
{ True while the realtime thread is actually running the mixer, which is a
  WIDER condition than AudioEngineIsBusy: a monitored input track keeps
  FillBlock going with the transport stopped and no note sounding. Callers
  that are about to free something the mixer reads through - most of all
  AudioEngineResetEffectState, which releases the dynamic buffers inside
  every effect state - need this one, not the busy test. }
function AudioEngineProcessingActive: Boolean;
function AudioEngineHasClip: Boolean;
{ No-op since the Beats warp stopped caching grain lookups - see
  BeatsClipSample, which derives a slice's position from its segment in O(1)
  and so has no cross-call state to go stale. Kept as an exported symbol
  because callers invoke it on the sample-pool teardown path (Project.NewProject
  via File>New/Open) where it used to matter, and a no-op there is harmless;
  it can be deleted along with those call sites. }
procedure AudioEngineInvalidateGrainCache;
function AudioEngineGetPosition: Int64;
function AudioEngineLiveNoteActive(ATrackIndex: Integer): Boolean;
function AudioEngineLiveNotePosition(ATrackIndex: Integer): Int64;
procedure AudioEngineSetSP1200Enabled(AEnabled: Boolean);
function AudioEngineGetSP1200Enabled: Boolean;
procedure AudioEngineSetMetronomeEnabled(AEnabled: Boolean);
function AudioEngineGetMetronomeEnabled: Boolean;

{ Latest pitch (in Hz) heard by the Effects.ekTuner sitting in a given insert
  slot, or 0 for "nothing tonal there right now". ATarget is a track index or
  one of Project's Bus* constants, the same convention the effects rack uses.
  Meaningless (always 0) for a slot holding any other Kind, since nothing
  else ever writes it.

  The value is produced on the audio thread and read here from the main one
  with no synchronization, deliberately - see Effects.TEffectState's
  TunerFreqHz. Cross-thread accessor only because TrackEffectState/
  MasterEffectState/SendEffectState are implementation-private to this unit. }
function AudioEngineTunerPitchHz(ATarget, AEffectIndex: Integer): Single;

{ Buffer size (frames per callback). Changing it stops the realtime thread,
  closes the backend, reopens it at the new size, and restarts the thread -
  fully serialized on the calling (main) thread, per CLAUDE.md's rule for
  runtime backend/device changes. Must not be called from the audio thread. }
function AudioEngineGetBufferSize: Integer;
procedure AudioEngineSetBufferSize(ANewBufferSize: Integer);

const
  { Which TAudioBackend implementation is live. "Native" is whatever the
    platform's own always-present API is - ALSA on Linux, DirectSound on
    Windows - and is always the fallback. PipeWire is preferred over it at
    startup when PipeWire is actually present; see AudioEngineInit. }
  AudioBackendNative = 0;
  AudioBackendJACK = 1;
  AudioBackendPipeWire = 2;

{ Selecting JACK deliberately does NOT check whether JACK is installed or
  running first. If it isn't, the backend simply never opens and the engine
  runs with nowhere to send audio - silent, but stable and paced, and undone
  by switching back to Native. That's the same failure the backend already
  has to survive when jackd is stopped mid-session, so it's one path rather
  than two plus a probe. On Windows this is always Native.

  Same stop/close/reopen/restart shape (and the same main-thread-only rule)
  as AudioEngineSetBufferSize above - it restarts the capture side too,
  since a backend owns both directions. }
function AudioEngineGetBackend: Integer;
procedure AudioEngineSetBackend(ABackendKind: Integer);

{ Name <-> ordinal for the AudioBackend* constants above, so eris.conf can
  store a backend by name. It has to: the ordinals are platform-relative -
  kind 0 is ALSA on Linux and DirectSound on Windows - so a config file
  carrying a bare 2 would mean PipeWire on one target and nothing at all on
  the other, and these files get shared between builds of the same source
  tree.

  FromName yields -1 for '' and for any name this platform cannot provide
  (a Linux-written 'pipewire' opened on Windows), which every caller reads as
  "no usable preference, decide the way you would have anyway". }
function AudioEngineBackendNameFromKind(AKind: Integer): string;
function AudioEngineBackendKindFromName(const AName: string): Integer;

{ PipeWire-only device selection, by node name ('' = let PipeWire use the
  system default). Every other backend opens its own default device and
  ignores these. Applying them reopens the backend (both directions), same
  main-thread-only rule as everything else here; it's a no-op when the
  values are unchanged or PipeWire isn't the live backend. }
procedure AudioEngineSetPipeWireDevices(const AOutputName, AInputName: string);
function AudioEngineGetPipeWireOutputDevice: string;
function AudioEngineGetPipeWireInputDevice: string;

{ Frees whatever old per-track TPlaybackClip arrays the audio thread has
  retired since the last call - see PendingFrees' declaration. Must be
  called periodically from the MAIN thread only (MainForm's playback poll
  timer already does); never from the audio thread. }
procedure AudioEngineDrainPendingFrees;

{ SP-1200-style per-track swing, shared by the realtime engine (FillBlock)
  and the offline render path (ProjectFile.RenderProjectToWav) so bounced
  audio can never drift from what was heard live. See the implementation
  for the exact convention (50 = straight, matches the SP-1200's 50-75%
  swing range). }
function SwungPosition(APosition: Int64; ASwingPercent: Single;
  ADivision: Integer; ABeatFrames: Int64): Int64;

const
  RecordStateIdle = 0;
  RecordStateCountIn = 1;
  RecordStateRecording = 2;

procedure AudioEngineStartCountIn(ATrackIndex: Integer);
{ Input Track recording: identical RecordState machinery as the count-in
  path above, minus the count-in - the record button just goes straight to
  RecordStateRecording, matching the "playhead moves and starts recording
  immediately, no count-in" behavior line-in recording needs vs. a
  keyboard/instrument take. }
procedure AudioEngineStartRecording(ATrackIndex: Integer);
procedure AudioEngineStopRecording;
function AudioEngineRecordState: Integer;
function AudioEngineTakeRecordedAudio(out AData: PSingle; out AFrameCount: Integer): Boolean;

{ Line-in capture buffer size (frames per capture read), independent of the
  output AudioEngineGetBufferSize/SetBufferSize pair above - stops/restarts
  only the capture thread and its ALSA capture stream, same
  stop-close-reopen-restart shape, still must not be called from either
  realtime thread. }
function AudioEngineGetInputBufferSize: Integer;
procedure AudioEngineSetInputBufferSize(ANewBufferSize: Integer);

{ Line-in input gain trim, applied to every captured sample before it's
  mixed into a monitoring track or tapped into a recording - a plain
  unsynchronized Single, same cross-thread tolerance as Project.TrackVolume
  (see FillBlock's per-track mix): the audio thread reading a value one
  block stale mid-drag is inaudible. }
function AudioEngineGetInputGainDb: Single;
procedure AudioEngineSetInputGainDb(ADb: Single);

implementation

uses
  Classes, SysUtils, AudioBackend,
  {$IFDEF WINDOWS}
  DirectSoundBackend,
  {$ELSE}
  ALSABackend, JACKBackend, PipeWireBackend,
  {$ENDIF}
  Resample, Project, SP1200, Effects, DenormalGuard, AVector, Config;

const
  DefaultBlockFrames = 512;
  OutputChannels = 2;
  { has to comfortably exceed the largest synchronous burst a single UI action
    can produce - RefreshAllTracksUI pushes ckStop + ckSeek plus one
    ckSetTrackClips for EVERY track slot (live tracks and the stale ones being
    cleared), so MaxTracks * 2 + slack }
  RingBufferCapacity = 128;
  { how long PushCommand will wait for the audio thread to free a ring slot
    before giving up - see PushCommand }
  CommandPushTimeoutMs = 250;
  { slots in the separate never-waiting MIDI note ring - see
    AudioEngineTriggerNoteRT }
  NoteRingCapacity = 64;
  PendingFreeCapacity = 128;
  MaxTracks = Project.MaxTracks;
  NoteFadeSamples = 128; { short crossfade on hard-retrigger, avoids a click }
  MaxRecordSeconds = 180;
  ClickDurationMs = 50;
  ClickFreqHz = 1000;
  DefaultInputBufferFrames = 1024;
  { capture ring capacity = InputBufferFrames * this - headroom so the
    capture thread's own blocking-read cadence (a separate ALSA device
    clock from the output stream) can drift a bit against the consumer
    (FillBlock, draining exactly one frame per output sample) without
    underrunning on every tiny hiccup }
  CaptureRingBlocks = 8;

type
  { one queued MIDI note-on, the payload of the NoteRing below; the same
    fields ckTriggerNote carries, minus the command tag }
  TQueuedNote = record
    TrackIndex: Integer;
    Data: PSingle;
    FrameCount: Integer;
    Channels: Integer;
    Rate: Double;
    Gain: Single;
  end;

  TCommandKind = (ckSetTrackClips, ckPlay, ckStop, ckSeek, ckTriggerNote,
    ckStartCountIn, ckStartRecording, ckStopRecording, ckSetLoop, ckClearLoop,
    ckSetSP1200Enabled, ckSetMetronomeEnabled);

  TCommand = record
    Kind: TCommandKind;
    TrackIndex: Integer;
    Items: PPlaybackClip;
    Count: Integer;
    Param: Int64;
    Param2: Int64;
    NoteData: PSingle;
    NoteFrameCount: Integer;
    NoteChannels: Integer;
    NoteRate: Double;
    NoteGain: Single;
  end;

  TTrackClips = record
    Items: PPlaybackClip;
    Count: Integer;
  end;

  TLiveNote = record
    Data: PSingle;
    FrameCount: Integer;
    Channels: Integer;
    Position: Double;
    Rate: Double;
    Gain: Single;
    FadeGain: Single;
    FadeStep: Single;
    Active: Boolean;
  end;

  TPlaybackThread = class(TThread)
  protected
    procedure Execute; override;
  end;

  { Runs a blocking Backend.CaptureRead loop independent of the output
    thread's own blocking-write loop above - the two are separate ALSA PCM
    streams (independent device clocks), so they're paced independently and
    only meet through the SPSC ring buffer (CaptureRingBuffer/PushCaptureFrames/
    PopCaptureFrame) below, exactly like the command ring already decouples
    the main thread from TPlaybackThread. }
  TCaptureThread = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  Backend: TAudioBackend;
  CurrentBackendKind: Integer = AudioBackendNative;
  BlockFrames: Integer;
  PlaybackThread: TPlaybackThread;
  MixBuffer: PSingle;

  { ---- block-major mix scratch -------------------------------------------
    FillBlock processes a whole block through one stage before handing it to
    the next, rather than carrying a single frame all the way from clip read
    to master output. These are the intermediate buffers that shape needs.
    All are BlockFrames long, mono-per-side (deinterleaved), and allocated
    once by AllocMixScratch - never on the realtime thread. Reallocated only
    by AudioEngineSetBufferSize, which stops the playback thread first.

    ScratchL/R hold the track currently being processed; PreFadeL/R its
    pre-fader copy for the send taps; MasterL/R the running sum; SendBufL/R
    one accumulator per send bus; CapBufL/R the block's captured input,
    drained from the ring once and then shared by every monitoring track;
    RecTapL/R the record tap. }
  ScratchL, ScratchR: PSingle;
  PreFadeL, PreFadeR: PSingle;
  MasterL, MasterR: PSingle;
  SendBufL, SendBufR: array[0..Project.SendCount - 1] of PSingle;
  CapBufL, CapBufR: PSingle;
  RecTapL, RecTapR: PSingle;

  InputBufferFrames: Integer;
  CaptureThread: TCaptureThread;
  CaptureAvailable: Boolean;
  { SPSC ring buffer, interleaved stereo floats: single producer (CaptureThread),
    single consumer (FillBlock, on TPlaybackThread) - see PushCaptureFrames/
    PopCaptureFrame. CaptureWriteCount/CaptureReadCount are free-running frame
    counters (never wrapped themselves - only their mod-capacity index into
    the physical buffer is), same shape as RingHead/RingTail's producer/
    consumer split above, just counting frames instead of command slots. }
  CaptureRingBuffer: PSingle;
  CaptureRingCapacityFrames: Int64;
  CaptureWriteCount: Int64;
  CaptureReadCount: Int64;
  { CaptureReadCount mod CaptureRingCapacityFrames, carried forward rather
    than recomputed. The counter is free-running so that modulo is a real
    Int64 idiv, and PopCaptureFrame runs it once per frame of every block on
    the realtime thread. Kept in step with CaptureReadCount by advancing in
    the same place it does, and zeroed with it in AudioEngineSetBufferSize. }
  CaptureReadIdx: Int64;
  InputGainLinear: Single;

  RingBuffer: array[0..RingBufferCapacity - 1] of TCommand;
  RingHead: Integer;
  RingTail: Integer;

  { the MIDI-thread note ring - see AudioEngineTriggerNoteRT's comment for why
    keyboard-played MIDI notes can't just go through RingBuffer above }
  NoteRing: array[0..NoteRingCapacity - 1] of TQueuedNote;
  NoteRingHead: Integer;
  NoteRingTail: Integer;

  { audio thread -> main thread, the mirror image of the command ring above:
    DrainCommands (audio thread) retires a track's old TPlaybackClip array
    every time ckSetTrackClips replaces it, but the realtime rule ("no
    allocation, no file I/O, no locking on the audio callback thread" - see
    CLAUDE.md) rules out calling FreeMem right there. Queuing the pointer
    here and freeing it from the main thread's existing poll timer
    (AudioEngineDrainPendingFrees, called from MainForm's
    PlaybackPollTimerTimer) keeps the free off the realtime thread entirely,
    same lock-free single-producer/single-consumer shape as PushCommand/
    PopCommand just in the opposite direction. }
  PendingFrees: array[0..PendingFreeCapacity - 1] of Pointer;
  PendingFreeHead: Integer;
  PendingFreeTail: Integer;

  TrackClips: array[0..MaxTracks - 1] of TTrackClips;
  Playhead: Int64;
  Playing: Boolean;
  LoopStart: Int64;
  LoopEnd: Int64;
  LoopActive: Boolean;

  LiveNotes: array[0..MaxTracks - 1] of TLiveNote;
  FadingNotes: array[0..MaxTracks - 1] of TLiveNote;

  RecordBuffer: PSingle;
  RecordCapacityFrames: Int64;
  RecordWritePos: Int64;
  RecordTrackIndex: Integer;
  RecordState: Integer;
  CountInBeatsRemaining: Integer;
  CountInFramesUntilNextBeat: Int64;
  ClickSamples: array of Single;
  ClickPlayPos: Integer;

  SP1200Enabled: Boolean;
  MetronomeEnabled: Boolean;
  SP1200MixState: TSP1200State;

  TrackEffectState: array[0..MaxTracks - 1, 0..Effects.MaxEffectsPerTrack - 1] of
    Effects.TEffectState;
  MasterEffectState: array[0..Effects.MaxEffectsPerTrack - 1] of Effects.TEffectState;
  { one chain's worth of state per send bus - the whole point of a send is
    that this is ONE chain however many tracks feed it }
  SendEffectState: array[0..Project.SendCount - 1, 0..Effects.MaxEffectsPerTrack - 1] of
    Effects.TEffectState;

  { Each track's final (post-own-inserts, post-fader) peak level, one value
    per frame of the block, read by any other track's ekSidechain effect.

    This was a single Single per track when FillBlock was frame-major: the
    "for t" loop overwrote it every frame, so a reader saw this frame's value
    for a source track processed earlier in the pass and last frame's value
    for one processed later. Block-major processes a whole track at a time,
    so a scalar would have gone stale by up to a whole block - hence the
    per-frame buffer. A source track EARLIER in the pass now reads exactly
    the values the frame-major engine produced, bit for bit.

    A source track LATER in the pass is the one behavioral difference in the
    restructure: its buffer still holds the PREVIOUS block's frames, so a
    sidechain keyed off a higher-numbered track lags by one block (~11.6ms at
    512 frames) instead of one sample. For the envelope follower this feeds -
    which has an attack measured in milliseconds anyway - that is a shift in
    ducking onset well under its own time constant, and keying a compressor
    off a track above it in the mixer is already the unusual direction. Every
    other routing is unchanged.

    Allocated by AllocMixScratch alongside the mix scratch above. }
  TrackTapBuf: array[0..MaxTracks - 1] of PSingle;

{ Allocates every block-major scratch buffer at the current BlockFrames, and
  zeroes them - the tap buffers in particular are read across blocks (see
  TrackTapBuf), so they must not start as heap garbage. Main thread only,
  with the playback thread stopped; paired with FreeMixScratch. }
procedure AllocMixScratch;
var
  Bytes: PtrUInt;
  i: Integer;

  procedure Alloc(out P: PSingle);
  begin
    GetMem(P, Bytes);
    FillChar(P^, Bytes, 0);
  end;

begin
  Bytes := PtrUInt(BlockFrames) * SizeOf(Single);
  Alloc(ScratchL);
  Alloc(ScratchR);
  Alloc(PreFadeL);
  Alloc(PreFadeR);
  Alloc(MasterL);
  Alloc(MasterR);
  Alloc(CapBufL);
  Alloc(CapBufR);
  Alloc(RecTapL);
  Alloc(RecTapR);
  for i := 0 to Project.SendCount - 1 do
  begin
    Alloc(SendBufL[i]);
    Alloc(SendBufR[i]);
  end;
  for i := 0 to MaxTracks - 1 do
    Alloc(TrackTapBuf[i]);
end;

procedure FreeMixScratch;
var
  i: Integer;

  procedure Release(var P: PSingle);
  begin
    if P <> nil then
    begin
      FreeMem(P);
      P := nil;
    end;
  end;

begin
  Release(ScratchL);
  Release(ScratchR);
  Release(PreFadeL);
  Release(PreFadeR);
  Release(MasterL);
  Release(MasterR);
  Release(CapBufL);
  Release(CapBufR);
  Release(RecTapL);
  Release(RecTapR);
  for i := 0 to Project.SendCount - 1 do
  begin
    Release(SendBufL[i]);
    Release(SendBufR[i]);
  end;
  for i := 0 to MaxTracks - 1 do
    Release(TrackTapBuf[i]);
end;

{ Main-thread-only producer for the command ring. NEVER call this from either
  realtime thread - it can wait.

  Waiting is the point. This used to return False the moment the ring was
  full and every caller ignored that, which silently dropped commands during
  any burst. RefreshAllTracksUI is exactly such a burst: ckStop + ckSeek plus
  one ckSetTrackClips PER TRACK, all pushed synchronously in a tight loop, so
  up to MaxTracks + 2 commands land at once while the audio thread - stopped,
  and therefore sitting in TPlaybackThread.Execute's Sleep(10) branch - is
  only draining at about 100 Hz. A dropped ckSetTrackClips leaves
  TrackClips[t] still pointing at the PREVIOUS project's array, whose Data
  pointers reference a SamplePool that loading has already freed; a dropped
  ckSeek/ckStop/ckPlay wedges the transport outright. That is the
  open-several-projects-then-the-playhead-locks-and-nothing-plays failure.

  The consumer drains unconditionally at the top of every Execute iteration,
  so space always frees up within a block period unless the audio thread is
  dead. Bounded so a dead audio thread degrades to the old drop-it behavior
  rather than hanging the UI forever. }
function PushCommand(const ACmd: TCommand): Boolean;
var
  NextHead, Waited: Integer;
begin
  Waited := 0;
  NextHead := (RingHead + 1) mod RingBufferCapacity;
  while NextHead = RingTail do
  begin
    if Waited >= CommandPushTimeoutMs then
      Exit(False);
    Sleep(1);
    Inc(Waited);
  end;

  RingBuffer[RingHead] := ACmd;
  { the slot's contents must be visible to the consumer before the head that
    publishes it - without this the compiler or CPU is free to reorder them
    and the audio thread can read a half-written command }
  WriteBarrier;
  RingHead := NextHead;
  Result := True;
end;

function PopCommand(out ACmd: TCommand): Boolean;
begin
  if RingTail = RingHead then
    Exit(False);
  { pairs with PushCommand's WriteBarrier - don't let the slot read hoist
    above the head check that says it's populated }
  ReadBarrier;
  ACmd := RingBuffer[RingTail];
  RingTail := (RingTail + 1) mod RingBufferCapacity;
  Result := True;
end;

{ Starts (or hard-retriggers) a track's one keyboard voice. Shared by the
  ckTriggerNote command path and the MIDI note ring below so both routes
  produce an identical voice - including the short crossfade that keeps a
  retrigger from clicking. Audio-thread only. }
procedure StartLiveNote(ATrackIndex: Integer; AData: PSingle;
  AFrameCount, AChannels: Integer; ARate: Double; AGain: Single);
begin
  if (ATrackIndex < 0) or (ATrackIndex >= MaxTracks) or (AData = nil)
    or (AFrameCount <= 0) then
    Exit;

  if LiveNotes[ATrackIndex].Active then
  begin
    FadingNotes[ATrackIndex] := LiveNotes[ATrackIndex];
    FadingNotes[ATrackIndex].FadeStep := 1.0 / NoteFadeSamples;
  end;

  LiveNotes[ATrackIndex].Data := AData;
  LiveNotes[ATrackIndex].FrameCount := AFrameCount;
  LiveNotes[ATrackIndex].Channels := AChannels;
  LiveNotes[ATrackIndex].Position := 0;
  LiveNotes[ATrackIndex].Rate := ARate;
  LiveNotes[ATrackIndex].Gain := AGain;
  LiveNotes[ATrackIndex].FadeGain := 1.0;
  LiveNotes[ATrackIndex].FadeStep := 0;
  LiveNotes[ATrackIndex].Active := True;
end;

{ MIDI-thread producer for the note ring. Never waits and never allocates -
  see AudioEngineTriggerNoteRT's comment. }
procedure PushNoteEvent(const AEvent: TQueuedNote);
var
  NextHead: Integer;
begin
  NextHead := (NoteRingHead + 1) mod NoteRingCapacity;
  if NextHead = NoteRingTail then
    Exit; { full - drop rather than stall a driver thread }

  NoteRing[NoteRingHead] := AEvent;
  { same publish ordering PushCommand relies on: the slot's contents have to
    be visible before the head that advertises them }
  WriteBarrier;
  NoteRingHead := NextHead;
end;

{ Audio-thread consumer for the note ring, called from DrainCommands so MIDI
  notes start on the same block boundary command-queued ones do. }
procedure DrainNoteRing;
var
  Event: TQueuedNote;
begin
  while NoteRingTail <> NoteRingHead do
  begin
    ReadBarrier;
    Event := NoteRing[NoteRingTail];
    NoteRingTail := (NoteRingTail + 1) mod NoteRingCapacity;
    StartLiveNote(Event.TrackIndex, Event.Data, Event.FrameCount,
      Event.Channels, Event.Rate, Event.Gain);
  end;
end;

{ Audio-thread-only producer for the pending-free queue - see PendingFrees'
  declaration. Never called with more than one outstanding entry per track
  between two main-thread poll-timer ticks in practice, so 64 slots is far
  more headroom than this needs; if it ever did fill, the pointer is just
  never freed rather than blocking/allocating on the realtime thread to make
  room, which is the safer failure mode here. }
procedure PushPendingFree(APtr: Pointer);
var
  NextHead: Integer;
begin
  if APtr = nil then
    Exit;
  NextHead := (PendingFreeHead + 1) mod PendingFreeCapacity;
  if NextHead = PendingFreeTail then
    Exit;
  PendingFrees[PendingFreeHead] := APtr;
  PendingFreeHead := NextHead;
end;

{ Capture-thread-only producer for the capture ring - see its declaration.
  A chunk that doesn't fit is dropped whole (never a partial/torn write) so
  a transient stall never desyncs the ring's frame accounting; the consumer
  side just reads silence for whatever it was going to hand over, an
  inaudible one-block glitch rather than a corrupted stream. }
procedure PushCaptureFrames(ASrc: PSingle; AFrameCount: Integer);
var
  Space: Int64;
  i, Idx: Int64;
begin
  Space := CaptureRingCapacityFrames - (CaptureWriteCount - CaptureReadCount);
  if Space < AFrameCount then
    Exit;

  { one Int64 idiv for the whole push instead of one per frame - the index
    then just walks forward and wraps by comparison, which is what the "Space
    < AFrameCount" bail above already guarantees is safe: this write can
    never lap the reader, so it wraps at most once. }
  Idx := CaptureWriteCount mod CaptureRingCapacityFrames;
  for i := 0 to AFrameCount - 1 do
  begin
    CaptureRingBuffer[Idx * 2] := ASrc[i * 2];
    CaptureRingBuffer[Idx * 2 + 1] := ASrc[i * 2 + 1];
    Inc(Idx);
    if Idx >= CaptureRingCapacityFrames then
      Idx := 0;
  end;
  CaptureWriteCount := CaptureWriteCount + AFrameCount;
end;

{ FillBlock-only (audio thread) consumer for the capture ring, one frame at a
  time - silence (not the last real sample held over) whenever the ring is
  empty, so an underrun is heard as a gap rather than a stuck/repeating
  sample. }
procedure PopCaptureFrame(out ACapL, ACapR: Single);
begin
  if CaptureWriteCount - CaptureReadCount <= 0 then
  begin
    ACapL := 0;
    ACapR := 0;
    Exit;
  end;
  ACapL := CaptureRingBuffer[CaptureReadIdx * 2] * InputGainLinear;
  ACapR := CaptureRingBuffer[CaptureReadIdx * 2 + 1] * InputGainLinear;
  Inc(CaptureReadCount);
  { the wrapped twin of the Inc above - see CaptureReadIdx's declaration }
  Inc(CaptureReadIdx);
  if CaptureReadIdx >= CaptureRingCapacityFrames then
    CaptureReadIdx := 0;
end;

function AnyLiveNoteActive: Boolean;
var
  t: Integer;
begin
  Result := False;
  for t := 0 to MaxTracks - 1 do
    if LiveNotes[t].Active or FadingNotes[t].Active then
      Exit(True);
end;

{ True while any Input Track has its "M" monitor toggle on - the realtime
  thread needs to keep calling FillBlock/WriteBlock for this alone even with
  the transport fully stopped and nothing else active, or live-monitored
  input would just go silent the moment playback isn't otherwise running. }
function AnyTrackMonitoring: Boolean;
var
  t: Integer;
begin
  Result := False;
  for t := 0 to MaxTracks - 1 do
    if Project.TrackIsInput[t] and Project.TrackMonitorEnabled[t] and
      Project.TrackEnabled[t] then
      Exit(True);
end;

{ Whether the realtime thread is currently producing audio at all, i.e. the
  exact condition TPlaybackThread.Execute gates FillBlock on. Note that it
  includes input monitoring, not just transport/notes - a monitored line-in
  runs the full effect chain with the transport stopped.

  Deliberately NOT the same thing as AudioEngineIsBusy, which answers the
  narrower "could the engine still be reading sample memory I'm about to
  free" question and so ignores monitoring (which reads captured input, not
  the sample pool). }
function EngineProcessingActive: Boolean;
begin
  Result := Playing or AnyLiveNoteActive or (RecordState <> RecordStateIdle) or
    AnyTrackMonitoring;
end;

procedure DrainCommands;
var
  Cmd: TCommand;
  t: Integer;
begin
  DrainNoteRing;

  while PopCommand(Cmd) do
    case Cmd.Kind of
      ckSetTrackClips:
        begin
          { the array being replaced is only ever reachable through this
            same TrackClips[t].Items slot, and we're about to overwrite that
            slot with Cmd.Items right below, so nothing on this thread (or
            any other) can still be reading through the old pointer by the
            time PushPendingFree hands it off - see PendingFrees' comment
            for why this can't just be FreeMem'd right here instead. }
          PushPendingFree(TrackClips[Cmd.TrackIndex].Items);
          TrackClips[Cmd.TrackIndex].Items := Cmd.Items;
          TrackClips[Cmd.TrackIndex].Count := Cmd.Count;
        end;
      ckPlay:
        Playing := True;
      ckStop:
        begin
          Playing := False;
          { a hard panic-stop: also silences any keyboard-triggered instrument
            notes still sounding, not just the timeline transport }
          for t := 0 to MaxTracks - 1 do
          begin
            LiveNotes[t].Active := False;
            FadingNotes[t].Active := False;
          end;
        end;
      ckSeek:
        begin
          Playhead := Cmd.Param;
          if Playhead < 0 then
            Playhead := 0;
        end;
      ckTriggerNote:
        StartLiveNote(Cmd.TrackIndex, Cmd.NoteData, Cmd.NoteFrameCount,
          Cmd.NoteChannels, Cmd.NoteRate, Cmd.NoteGain);
      ckStartCountIn:
        begin
          RecordTrackIndex := Cmd.TrackIndex;
          RecordState := RecordStateCountIn;
          CountInBeatsRemaining := 4;
          CountInFramesUntilNextBeat := 0;
          RecordWritePos := 0;
          ClickPlayPos := -1;
        end;
      ckStartRecording:
        begin
          { Input Track take: same end state count-in reaches on its last
            beat (RecordStateRecording, Playing True so the playhead moves
            the same way), just entered immediately instead of after 4
            clicks - see AudioEngineStartRecording's declaration comment. }
          RecordTrackIndex := Cmd.TrackIndex;
          RecordState := RecordStateRecording;
          RecordWritePos := 0;
          Playing := True;
        end;
      ckStopRecording:
        begin
          RecordState := RecordStateIdle;
          Playing := False;
        end;
      ckSetLoop:
        begin
          LoopStart := Cmd.Param;
          LoopEnd := Cmd.Param2;
          LoopActive := LoopEnd > LoopStart;
        end;
      ckClearLoop:
        LoopActive := False;
      ckSetSP1200Enabled:
        SP1200Enabled := Cmd.Param <> 0;
      ckSetMetronomeEnabled:
        MetronomeEnabled := Cmd.Param <> 0;
    end;
end;

procedure MixNoteVoice(var ANote: TLiveNote; AFadeGain: Single; var L, R: Single);
var
  s: Single;
begin
  if not ANote.Active then
    Exit;
  if Trunc(ANote.Position) >= ANote.FrameCount then
  begin
    ANote.Active := False;
    Exit;
  end;

  if ANote.Channels = 1 then
  begin
    s := Interpolate(ANote.Data, ANote.FrameCount, ANote.Channels, 0, ANote.Position) *
      ANote.Gain * AFadeGain;
    L := L + s;
    R := R + s;
  end
  else
  begin
    L := L + Interpolate(ANote.Data, ANote.FrameCount, ANote.Channels, 0,
      ANote.Position) * ANote.Gain * AFadeGain;
    R := R + Interpolate(ANote.Data, ANote.FrameCount, ANote.Channels, 1,
      ANote.Position) * ANote.Gain * AFadeGain;
  end;

  ANote.Position := ANote.Position + ANote.Rate;
end;

const
  { Beats mode falls back to a fixed grid of roughly this length whenever a
    marker-to-marker segment contains no detected transient to slice at. }
  WarpGrainMs = 120;
  { Longest a slice may keep sounding past its own timeline allotment,
    decaying, while the next slice plays over the top - see BeatsClipSample.
    The actual release is per-slice and usually shorter; this is just the cap. }
  WarpSliceReleaseMs = 30;
  { Declick ramp at the start of a slice, applied only in a segment that is
    actually being time-modified (at ratio 1 slices hand over contiguously and
    need no ramp). Deliberately far shorter than the release: it has to kill a
    step discontinuity without dulling an attack. }
  WarpSliceAttackFrames = 24;
  { Half-width of the sample-domain crossfade applied at each ping-pong
    reversal inside a stretched slice - see BeatsClipSample. }
  WarpReversalFadeMs = 3;
  { Hard cap on how many slices may sound simultaneously. Overlap depth grows
    as compression deepens (roughly 1/ratio), so this only binds past ~4x;
    dropping the oldest, quietest tail there is inaudible under three louder
    slices and keeps the per-frame cost bounded on the realtime thread. }
  WarpMaxOverlapSlices = 4;
  { width of the position blend applied before each RePitch-mode marker, to
    absorb the rate kink between two segments - see ClipSourcePosition }
  WarpRepitchFadeMs = 4;

{ Which warp segment owns a timeline frame: the lowest k in
  [0, MarkerCount - 2] with AClipRelativeFrame < MarkerTimeline[k + 1], or
  MarkerCount - 2 when the frame is at or past the last internal marker.
  Callers must have already ruled out MarkerCount < 2.

  AHintK is a pure accelerator and never a correctness input. This search used
  to restart from marker 0 on every sample, in all three of the places that
  need it - so a clip carrying a full marker array (MaxClipWarpMarkers = 128)
  cost up to 126 dependent loads PER SAMPLE, and cost the most exactly where
  playback spends most of its time, out at the far end of the clip. That is
  also the shape of cost that sets the minimum workable buffer size, since it
  is worst-case rather than average block time that has to fit. Transport
  moves one frame at a time, so seeding from the previous answer normally
  settles the search in zero steps.

  Adjusting in BOTH directions is what makes an outside seed safe. The frames
  arriving here are not strictly monotonic: a loop wrap throws the position
  back to LoopStart, and the detune layer asks about grain anchors on either
  side of the current frame. A forward-only walk - which is all
  Waveform.WarpedSourcePosition needs, since screen columns genuinely do
  ascend - would stick past the answer and return the wrong segment. Walking
  back while the frame sits below this segment's start, then forward while it
  sits at or past this segment's end, converges on exactly the k the
  scan-from-zero produced, from any starting point. That includes a stale or
  out-of-range hint, which is why an uninitialised one is merely slow rather
  than wrong. }
function FindWarpSegment(Clip: PPlaybackClip; AClipRelativeFrame: Int64;
  AHintK: PInteger): Integer;
begin
  Result := 0;
  if AHintK <> nil then
  begin
    Result := AHintK^;
    if Result < 0 then
      Result := 0
    else if Result > Clip^.MarkerCount - 2 then
      Result := Clip^.MarkerCount - 2;
  end;

  while (Result > 0) and
    (AClipRelativeFrame < Clip^.MarkerTimeline[Result]) do
    Dec(Result);
  while (Result < Clip^.MarkerCount - 2) and
    (AClipRelativeFrame >= Clip^.MarkerTimeline[Result + 1]) do
    Inc(Result);

  if AHintK <> nil then
    AHintK^ := Result;
end;

{ Nominal timeline -> source map for one clip.

  For RePitch this IS the playback position: a continuous vari-speed resample
  across each segment, unchanged from the original warp implementation.

  For Beats it is the NOMINAL map only - the source position the warp
  notionally assigns to a timeline frame. Beats playback does not read through
  a single position at all (see BeatsClipSample), so this is used for the
  detune layer's grain anchors and for non-audio callers that need a single
  answer, not for producing Beats audio.

  AHintK is threaded through from the mix loop purely to accelerate the
  segment search - see FindWarpSegment. Passing nil is always valid. }
function ClipSourcePosition(Clip: PPlaybackClip; AClipRelativeFrame: Int64;
  AHintK: PInteger): Double;
var
  k: Integer;
  SegStartTimeline, SegStartSource, SegTimelineLen, SegSourceLen: Int64;
  OffsetIntoSeg: Int64;
  RePitchFadeFrames, RePitchDistToEnd, NextSegSourceLen, NextSegTimelineLen: Int64;
  RePitchPosA, RePitchPosB, RePitchFadeT: Double;
begin
  if Clip^.MarkerCount < 2 then
    Exit(AClipRelativeFrame);

  k := FindWarpSegment(Clip, AClipRelativeFrame, AHintK);

  SegStartTimeline := Clip^.MarkerTimeline[k];
  SegStartSource := Clip^.MarkerSource[k];
  SegTimelineLen := Clip^.MarkerTimeline[k + 1] - SegStartTimeline;
  SegSourceLen := Clip^.MarkerSource[k + 1] - SegStartSource;
  OffsetIntoSeg := AClipRelativeFrame - SegStartTimeline;

  if Clip^.WarpMode = 1 then
  begin
    { RePitch: the classic continuous vari-speed warp - resample linearly
      across the whole segment (same math the original warp implementation
      and keyboard pitch-shifting both use), so dragging a marker audibly
      stretches/compresses the segments on both sides of it together,
      changing pitch, instead of preserving pitch }
    if SegTimelineLen = 0 then
      Exit(SegStartSource);
    RePitchPosA := SegStartSource + OffsetIntoSeg * (SegSourceLen / SegTimelineLen);

    { Two adjacent segments generally run at different rates, so the read
      pointer's SLOPE (not its position - the two formulas already agree
      exactly at the marker) kinks abruptly at every internal marker. Blend
      this segment's own formula with the next segment's, extrapolated
      backward, over a short window ending exactly at the marker: since both
      converge to the same value there, this fully absorbs the rate change
      before the marker instead of snapping it. }
    if k < Clip^.MarkerCount - 2 then
    begin
      RePitchFadeFrames := (WarpRepitchFadeMs * ProjectSampleRate) div 1000;
      if RePitchFadeFrames > SegTimelineLen div 2 then
        RePitchFadeFrames := SegTimelineLen div 2;
      if RePitchFadeFrames < 1 then
        RePitchFadeFrames := 1;

      RePitchDistToEnd := SegTimelineLen - OffsetIntoSeg;
      if RePitchDistToEnd <= RePitchFadeFrames then
      begin
        NextSegSourceLen := Clip^.MarkerSource[k + 2] - Clip^.MarkerSource[k + 1];
        NextSegTimelineLen := Clip^.MarkerTimeline[k + 2] - Clip^.MarkerTimeline[k + 1];
        if NextSegTimelineLen > 0 then
        begin
          RePitchPosB := Clip^.MarkerSource[k + 1] +
            (OffsetIntoSeg - SegTimelineLen) * (NextSegSourceLen / NextSegTimelineLen);
          RePitchFadeT := 1 - (RePitchDistToEnd / RePitchFadeFrames);
          Exit(RePitchPosA * (1 - RePitchFadeT) + RePitchPosB * RePitchFadeT);
        end;
      end;
    end;

    Exit(RePitchPosA);
  end;

  if SegTimelineLen <= 0 then
    Exit(SegStartSource);
  if SegSourceLen <= 0 then
    Exit(SegStartSource);

  Result := SegStartSource + OffsetIntoSeg * (SegSourceLen / SegTimelineLen);
end;

{ ---------------------------------------------------------------------------
  Beats warp: transient-sliced, overlap-capable renderer.

  Ableton's Beats mode is not a position warp. It cuts the source at every
  transient and triggers each slice as its own voice at the timeline frame the
  warp maps that slice's start to; the slice then plays FORWARD at 1:1 from
  its own start, and is allowed to keep sounding after the next slice has
  already begun. That overlap is the whole trick. Compressing a clip (five
  bars dragged onto four) leaves every slice with less timeline than it has
  audio, and Ableton lets the surplus decay underneath the incoming hit rather
  than cutting it off - which is why it stays dense where a single-read-pointer
  warp goes choppy.

  What this replaces was exactly such a single-read-pointer warp: a scalar
  ClipSourcePosition(frame) -> source position, wrapped in a fixed 4ms
  crossfade. Being single-valued it structurally could not express two slices
  at once, so a compressed slice had to be truncated outright. Three of that
  design's artifacts go away by construction here, not by being patched:

  * No cut-point snapping. FindNearestZeroCrossing is gone entirely. Snapping
    is a workaround for splicing without a crossfade, and it was itself the
    source of an up-to-32-frame backward position jump wherever a stretched
    grain handed over from natural playback to its ping-pong fill. Slices here
    reflect exactly at their own natural boundary, so there is no jump left to
    snap away - and nothing depends on finding a zero crossing inside a 0.7ms
    window, which on bass-heavy material does not exist.

  * No grain lookup cache. Every slice in a segment shares one ratio, so a
    slice's timeline start is an O(1) function of its source start and the
    lookup is a binary search over the transient array, not the
    accumulate-and-scan the cache existed to amortise. That also removes the
    cache's own failure mode: its slice-range test used the TRUNCATED slice
    start while the scan used the exact fractional one, so the two disagreed
    about who owned the last frame before each boundary - and the crossfade's
    own lookahead was what poisoned the cache into taking that path.

  * Release is sized per slice, to that slice's own overlap. At ratio 1 the
    overlap is zero, so an unwarped-but-markered clip is a plain 1:1 read with
    no envelope and no crossfade at all, instead of summing a signal with a
    slightly delayed copy of itself.
  --------------------------------------------------------------------------- }
function BeatsClipSample(Clip: PPlaybackClip; AClipRelativeFrame: Int64;
  AChannel: Integer; AHintK: PInteger): Single;
var
  k: Integer;
  SegStartTimeline, SegStartSource, SegTimelineLen, SegSourceLen: Int64;
  FirstTrans, TransInSeg: Integer;
  SliceCount, GridLen: Int64;
  ReleaseMax, ReversalFade: Int64;
  CurSlice, i: Int64;
  Used: Integer;
  Acc: Double;

  function SafeInterp(APos: Double): Single;
  var
    AbsPos: Double;
  begin
    AbsPos := Clip^.Offset + APos;
    if (AbsPos < 0) or (AbsPos >= Clip^.FrameCount) then
      Result := 0
    else
      Result := Interpolate(Clip^.Data, Clip^.FrameCount, Clip^.Channels,
        AChannel, AbsPos);
  end;

  { (re)points the segment-scoped locals above at marker pair (AK, AK + 1) and
    works out how that segment is sliced. Called a second time when the
    overlap walk-back crosses a marker into the previous segment. }
  procedure LoadSegment(AK: Integer);
  var
    lo, hi, mid: Integer;
    SegEnd: Int64;
  begin
    SegStartTimeline := Clip^.MarkerTimeline[AK];
    SegStartSource := Clip^.MarkerSource[AK];
    SegTimelineLen := Clip^.MarkerTimeline[AK + 1] - SegStartTimeline;
    SegSourceLen := Clip^.MarkerSource[AK + 1] - SegStartSource;
    SegEnd := SegStartSource + SegSourceLen;

    FirstTrans := 0;
    TransInSeg := 0;
    GridLen := 0;
    SliceCount := 1;
    if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
      Exit;

    { Clip^.Transients holds ABSOLUTE positions within the whole sample file
      (the frame of reference DetectTransients works in, and the same cached
      array is shared by every clip that chops a different region out of the
      same sample) while SegStartSource is CLIP-relative - hence the
      -Clip^.Offset on every comparison, or a clip that doesn't start at frame
      0 of its source compares against the wrong region entirely. }
    if (Clip^.Transients <> nil) and (Clip^.TransientCount > 0) then
    begin
      { first transient strictly inside the segment }
      lo := 0;
      hi := Clip^.TransientCount;
      while lo < hi do
      begin
        mid := lo + (hi - lo) div 2;
        if (Clip^.Transients + mid)^ - Clip^.Offset <= SegStartSource then
          lo := mid + 1
        else
          hi := mid;
      end;
      FirstTrans := lo;

      { ...and how many of them land before the segment's end }
      hi := Clip^.TransientCount;
      while lo < hi do
      begin
        mid := lo + (hi - lo) div 2;
        if (Clip^.Transients + mid)^ - Clip^.Offset < SegEnd then
          lo := mid + 1
        else
          hi := mid;
      end;
      TransInSeg := lo - FirstTrans;
    end;

    if TransInSeg > 0 then
      SliceCount := TransInSeg + 1
    else
    begin
      { no onset to slice at - fall back to a fixed grid, re-tiled evenly so
        there is no short remainder slice }
      GridLen := (WarpGrainMs * ProjectSampleRate) div 1000;
      if GridLen > SegSourceLen then
        GridLen := SegSourceLen;
      if GridLen < 1 then
        GridLen := 1;
      SliceCount := SegSourceLen div GridLen;
      if SliceCount < 1 then
        SliceCount := 1;
      GridLen := SegSourceLen div SliceCount;
    end;
  end;

  { source start (clip-relative) of slice AIndex in the loaded segment.
    AIndex = SliceCount returns the segment's own end, so a slice's natural
    span is always SliceLo(i + 1) - SliceLo(i). }
  function SliceLo(AIndex: Int64): Int64;
  begin
    if AIndex <= 0 then
      Exit(SegStartSource);
    if AIndex >= SliceCount then
      Exit(SegStartSource + SegSourceLen);
    if TransInSeg > 0 then
      Result := (Clip^.Transients + FirstTrans + AIndex - 1)^ - Clip^.Offset
    else
      Result := SegStartSource + AIndex * GridLen;
  end;

  { where the warp puts a source position on the timeline. Every slice in a
    segment shares the one ratio, so this is exact and needs no running sum -
    and because each slice's bounds are mapped through it individually, the
    allotments tile the segment with no accumulated rounding drift. }
  function TimelineOf(ASource: Int64): Int64;
  begin
    Result := SegStartTimeline +
      ((ASource - SegStartSource) * SegTimelineLen) div SegSourceLen;
  end;

  { the slice owning AClipRelativeFrame in the loaded segment. Seeded from the
    nominal source position (O(1) for the grid, one binary search for
    transients), then corrected against the real timeline bounds so the seed's
    integer rounding can never disagree with the bounds the renderer itself
    uses. Both correction loops run at most once in practice. }
  function FindSlice: Int64;
  var
    NominalSrc, lo, hi, mid: Int64;
  begin
    NominalSrc := SegStartSource +
      ((AClipRelativeFrame - SegStartTimeline) * SegSourceLen) div SegTimelineLen;

    if TransInSeg > 0 then
    begin
      lo := 0;
      hi := SliceCount - 1;
      while lo < hi do
      begin
        mid := lo + (hi - lo + 1) div 2;
        if SliceLo(mid) <= NominalSrc then
          lo := mid
        else
          hi := mid - 1;
      end;
      Result := lo;
    end
    else
      Result := (NominalSrc - SegStartSource) div GridLen;

    if Result < 0 then
      Result := 0;
    if Result > SliceCount - 1 then
      Result := SliceCount - 1;

    while (Result > 0) and (AClipRelativeFrame < TimelineOf(SliceLo(Result))) do
      Dec(Result);
    while (Result < SliceCount - 1) and
      (AClipRelativeFrame >= TimelineOf(SliceLo(Result + 1))) do
      Inc(Result);
  end;

  { one slice's enveloped output at AClipRelativeFrame, or 0 when it is not
    (or no longer) sounding }
  function SliceContribution(AIndex: Int64): Single;
  var
    Lo, Natural, TL, TLen, Release, Attack, t: Int64;
    LoopStart, LoopEnd, LoopLen, Ov, Ph, F, s: Int64;
    Gain, w: Double;
  begin
    Result := 0;
    Lo := SliceLo(AIndex);
    Natural := SliceLo(AIndex + 1) - Lo;
    if Natural < 1 then
      Exit;

    TL := TimelineOf(Lo);
    TLen := TimelineOf(Lo + Natural) - TL;
    if TLen < 1 then
      Exit;

    t := AClipRelativeFrame - TL;
    if t < 0 then
      Exit;

    { the tail is sized to this slice's OWN overlap, which is what keeps
      ratio 1 exactly transparent - see the header comment }
    Release := Natural - TLen;
    if Release < 0 then
      Release := -Release;
    if Release > ReleaseMax then
      Release := ReleaseMax;
    if t >= TLen + Release then
      Exit;

    Gain := 1;
    if Natural <> TLen then
    begin
      Attack := WarpSliceAttackFrames;
      if Attack > TLen then
        Attack := TLen;
      if (Attack > 0) and (t < Attack) then
        Gain := t / Attack;
    end;
    { linear, not equal-power: the incoming slice is already at full level
      (nothing fades IN over a transient, that is what keeps attacks punchy),
      so this tail is added on top and a linear ramp is what stops the sum
      building up where two slices happen to correlate }
    if (Release > 0) and (t >= TLen) then
      Gain := Gain * (1 - (t - TLen) / Release);

    if t < Natural then
    begin
      { natural 1:1 playback. A COMPRESSED slice never leaves this branch: its
        release is capped at Natural - TLen, so t < TLen + Release <= Natural.
        Its whole job is to keep playing forward, decaying, under the slice
        that has already started. }
      Result := SafeInterp(Lo + t) * Gain;
      Exit;
    end;

    { Stretched: this slice owes more timeline than it has audio. Ping-pong
      over its back half to fill the rest - Ableton's "Loop Back-and-Forth",
      the transient loop mode their own docs call the highest-quality one.

      Each reversal is a real sample-domain crossfade between the two
      direction streams, not a blend of their POSITIONS. Both streams keep
      advancing at a constant +/-1 frame per frame, so there is no rate
      discontinuity anywhere; blending positions (what this used to do) leaves
      the read rate stepping from 1 to 2 at the joins, which is an audible
      pitch tick. At the peak turn the incoming stream reads up to F frames
      past the slice's own end - that is the contiguous next-slice audio, i.e.
      precisely the continuation of what was already playing, and it is fading
      out across the whole window. }
    LoopEnd := Lo + Natural;
    LoopStart := Lo + Natural div 2;
    LoopLen := LoopEnd - LoopStart;
    if LoopLen < 1 then
    begin
      Result := SafeInterp(LoopEnd) * Gain;
      Exit;
    end;

    F := ReversalFade;
    if F > LoopLen div 2 then
      F := LoopLen div 2;
    if F < 1 then
      F := 1;

    Ov := t - Natural;
    Ph := Ov mod (2 * LoopLen);

    { signed distance to the nearer peak turn (Ph = 0, or equivalently
      Ph = 2 * LoopLen). At the very first entry into the ping-pong Ph is 0,
      both streams read LoopEnd, and the result is exactly SafeInterp(LoopEnd)
      - continuous with the natural pass that just ended one frame earlier. }
    if Ph > 2 * LoopLen - F then
      s := Ph - 2 * LoopLen
    else
      s := Ph;

    if (s > -F) and (s < F) then
    begin
      w := (s + F) / (2 * F);
      Result := (SafeInterp(LoopEnd + s) * (1 - w) +
        SafeInterp(LoopEnd - s) * w) * Gain;
      Exit;
    end;

    { and to the valley turn (Ph = LoopLen), where the backward leg hands back
      to the forward one }
    s := Ph - LoopLen;
    if (s > -F) and (s < F) then
    begin
      w := (s + F) / (2 * F);
      Result := (SafeInterp(LoopStart - s) * (1 - w) +
        SafeInterp(LoopStart + s) * w) * Gain;
      Exit;
    end;

    if Ph < LoopLen then
      Result := SafeInterp(LoopEnd - Ph) * Gain
    else
      Result := SafeInterp(LoopStart + (Ph - LoopLen)) * Gain;
  end;

begin
  if Clip^.MarkerCount < 2 then
    Exit(SafeInterp(AClipRelativeFrame));

  { FindWarpSegment has already written k back to the hint, so the walk-back
    below is free to move k into earlier segments without corrupting it - the
    next sample wants to resume from the segment it STARTED in, not from
    whichever one the overlap tail happened to reach. }
  k := FindWarpSegment(Clip, AClipRelativeFrame, AHintK);

  LoadSegment(k);
  if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
    Exit(SafeInterp(SegStartSource));

  ReleaseMax := (WarpSliceReleaseMs * ProjectSampleRate) div 1000;
  if ReleaseMax < 1 then
    ReleaseMax := 1;
  ReversalFade := (WarpReversalFadeMs * ProjectSampleRate) div 1000;
  if ReversalFade < 1 then
    ReversalFade := 1;

  CurSlice := FindSlice;

  { Sum the slice owning this frame plus any earlier ones still decaying over
    it. The walk-back crosses a marker into the previous segment when it has
    to: the last slice of a compressed segment is exactly the one whose tail
    needs to carry over the marker the user pinned a snare to, and stopping at
    the marker instead would put a hole right where they are listening. }
  Acc := 0;
  Used := 0;
  i := CurSlice;
  while Used < WarpMaxOverlapSlices do
  begin
    Acc := Acc + SliceContribution(i);
    Inc(Used);

    Dec(i);
    if i < 0 then
    begin
      if k = 0 then
        Break;
      Dec(k);
      LoadSegment(k);
      if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
        Break;
      i := SliceCount - 1;
    end;

    { nothing earlier than this can still be within its release }
    if AClipRelativeFrame >= TimelineOf(SliceLo(i + 1)) + ReleaseMax then
      Break;
  end;

  Result := Acc;
end;

const
  { LF slices are whole NOTES, not grains. Any onset crowded closer than this
    to the one before it is treated as belonging to the same note rather than
    starting a new slice: DetectTransients' 40ms floor is right for drums and
    far too eager inside a sustained 808, where the amplitude swell from the
    distortion and the pitch glide both read as onsets and produce splices in
    the middle of a note. }
  TonesMinNoteMs = 150;
  { how long a note's tail keeps sounding, decaying, under the next one }
  TonesReleaseMs = 120;
  { declick ramp at a note start - short enough not to soften an 808's attack }
  TonesAttackFrames = 24;
  { cap on the crowded-onset walks below, so a long dense roll can't make the
    lookup unbounded on the realtime thread }
  TonesMaxOnsetWalk = 64;

{ ---------------------------------------------------------------------------
  Tones warp ("LF"): note-triggered 1:1 playback, for sustained low-frequency
  material - 808s, sub bass, anything monophonic.

  This does NOT granulate, and that is the whole design. The first attempt
  here was pitch-synchronous overlap-add, snapping each grain's source start
  to a whole multiple of the detected fundamental period. That fails for the
  job this mode exists to do. Quantising means nudging note onsets, so the
  ratios are close to 1, and at those ratios the snap's accumulated error
  sawtooths slowly: every N grains it duplicates or skips one entire cycle.
  Each of those is a phase jump, heard as slow roughness plus a wobble in the
  time base, and where two grains land anti-phase they cancel while in-phase
  they sum to +6dB into the clipper. Worse, the snap assumes ONE period for
  the whole sample, which a gliding 808 does not have.

  So nothing is resynthesised. Each note is found by its onset, placed at the
  timeline position the warp maps that onset to, and played FORWARD at 1:1
  from its own start - exactly what a producer chopping and re-triggering
  hits by hand would get. Interior audio is untouched, so there is no
  granular artefact to hear at all: no phase jumps, no comb, no pitch wobble.

  A note that overruns its slot (compression) keeps playing and decays under
  the note that has already started, which is what real overlapping 808 tails
  do anyway. A note whose slot is longer than its audio (stretch) simply ends
  and leaves its own natural decay - never a loop, which on bass would be an
  obvious artefact. That is the deliberate trade: LF cannot fill time, so it
  is for correcting timing, not for large stretches. Beats is for those.
  --------------------------------------------------------------------------- }
function TonesClipSample(Clip: PPlaybackClip; AClipRelativeFrame: Int64;
  AChannel: Integer; AHintK: PInteger): Single;
var
  k, Guard: Integer;
  SegStartTimeline, SegStartSource, SegTimelineLen, SegSourceLen, SegEnd: Int64;
  FirstTrans, TransInSeg: Integer;
  MinNote, ReleaseMax, P, NominalSrc: Int64;
  CurLo, CurHi, PrevLo, PrevHi: Int64;
  Acc: Double;

  function SafeInterp(APos: Double): Single;
  var
    AbsPos: Double;
  begin
    AbsPos := Clip^.Offset + APos;
    if (AbsPos < 0) or (AbsPos >= Clip^.FrameCount) then
      Result := 0
    else
      Result := Interpolate(Clip^.Data, Clip^.FrameCount, Clip^.Channels,
        AChannel, AbsPos);
  end;

  function TransAt(AIndex: Integer): Int64;
  begin
    Result := (Clip^.Transients + AIndex)^ - Clip^.Offset;
  end;

  { same segment/transient-range setup as BeatsClipSample - see there }
  procedure LoadSegment(AK: Integer);
  var
    lo, hi, mid: Integer;
  begin
    SegStartTimeline := Clip^.MarkerTimeline[AK];
    SegStartSource := Clip^.MarkerSource[AK];
    SegTimelineLen := Clip^.MarkerTimeline[AK + 1] - SegStartTimeline;
    SegSourceLen := Clip^.MarkerSource[AK + 1] - SegStartSource;
    SegEnd := SegStartSource + SegSourceLen;

    FirstTrans := 0;
    TransInSeg := 0;
    if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
      Exit;
    if (Clip^.Transients = nil) or (Clip^.TransientCount <= 0) then
      Exit;

    lo := 0;
    hi := Clip^.TransientCount;
    while lo < hi do
    begin
      mid := lo + (hi - lo) div 2;
      if TransAt(mid) <= SegStartSource then
        lo := mid + 1
      else
        hi := mid;
    end;
    FirstTrans := lo;

    hi := Clip^.TransientCount;
    while lo < hi do
    begin
      mid := lo + (hi - lo) div 2;
      if TransAt(mid) < SegEnd then
        lo := mid + 1
      else
        hi := mid;
    end;
    TransInSeg := lo - FirstTrans;
  end;

  function TimelineOf(ASource: Int64): Int64;
  begin
    Result := SegStartTimeline +
      ((ASource - SegStartSource) * SegTimelineLen) div SegSourceLen;
  end;

  { Source bounds of the note containing ASrc.

    An onset counts as a note start only if the onset before it is at least
    MinNote away - a purely LOCAL test, so it needs no filtered copy of the
    transient array and gives the same answer from any frame. A cluster of
    swell-triggered onsets inside one sustained note therefore collapses onto
    the first of the cluster, which is the real attack. }
  procedure NoteBounds(ASrc: Int64; out ALo, AHi: Int64);
  var
    lo, hi, mid, j, steps: Integer;
  begin
    ALo := SegStartSource;
    AHi := SegEnd;
    if TransInSeg <= 0 then
      Exit;

    { before the first onset inside the segment: the note runs from the
      segment's own start up to it }
    if TransAt(FirstTrans) > ASrc then
    begin
      AHi := TransAt(FirstTrans);
      Exit;
    end;

    lo := FirstTrans;
    hi := FirstTrans + TransInSeg - 1;
    while lo < hi do
    begin
      mid := lo + (hi - lo + 1) div 2;
      if TransAt(mid) <= ASrc then
        lo := mid
      else
        hi := mid - 1;
    end;
    j := lo;

    steps := 0;
    while (j > FirstTrans) and (TransAt(j) - TransAt(j - 1) < MinNote) and
      (steps < TonesMaxOnsetWalk) do
    begin
      Dec(j);
      Inc(steps);
    end;
    ALo := TransAt(j);

    steps := 0;
    Inc(j);
    while (j < FirstTrans + TransInSeg) and
      (TransAt(j) - TransAt(j - 1) < MinNote) and (steps < TonesMaxOnsetWalk) do
    begin
      Inc(j);
      Inc(steps);
    end;
    if j < FirstTrans + TransInSeg then
      AHi := TransAt(j)
    else
      AHi := SegEnd;

    if ALo < SegStartSource then
      ALo := SegStartSource;
    if AHi > SegEnd then
      AHi := SegEnd;
  end;

  { one note's enveloped output at AClipRelativeFrame, or 0 if it isn't (or is
    no longer) sounding }
  function NoteContribution(ALo, AHi: Int64): Double;
  var
    Natural, TL, TLen, Release, FadeStart, t: Int64;
    Gain: Double;
  begin
    Result := 0;
    Natural := AHi - ALo;
    if Natural < 1 then
      Exit;

    TL := TimelineOf(ALo);
    TLen := TimelineOf(AHi) - TL;
    if TLen < 1 then
      Exit;

    t := AClipRelativeFrame - TL;
    if t < 0 then
      Exit;

    Release := ReleaseMax;
    if Release > Natural then
      Release := Natural;
    { a whole number of cycles, so the ramp itself doesn't put an amplitude
      artefact on the tail of a low-frequency note }
    if (P > 1) and (Release > P) then
      Release := (Release div P) * P;
    if Release < 1 then
      Release := 1;

    { fade from the slot's end when the note overruns it, or from ReleaseMax
      before the audio runs out when it doesn't }
    FadeStart := TLen;
    if FadeStart > Natural - Release then
      FadeStart := Natural - Release;
    if FadeStart < 0 then
      FadeStart := 0;

    if t >= FadeStart + Release then
      Exit;

    Gain := 1;
    if t >= FadeStart then
      Gain := 1 - (t - FadeStart) / Release;
    if t < TonesAttackFrames then
      Gain := Gain * (t / TonesAttackFrames);

    Result := SafeInterp(ALo + t) * Gain;
  end;

begin
  if Clip^.MarkerCount < 2 then
    Exit(SafeInterp(AClipRelativeFrame));

  k := FindWarpSegment(Clip, AClipRelativeFrame, AHintK);

  LoadSegment(k);
  if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
    Exit(SafeInterp(SegStartSource));

  MinNote := (TonesMinNoteMs * ProjectSampleRate) div 1000;
  ReleaseMax := (TonesReleaseMs * ProjectSampleRate) div 1000;
  P := Clip^.PeriodFrames;

  NominalSrc := SegStartSource +
    ((AClipRelativeFrame - SegStartTimeline) * SegSourceLen) div SegTimelineLen;
  NoteBounds(NominalSrc, CurLo, CurHi);

  { the seed came from the nominal source position, so correct it against the
    real timeline bounds the renderer itself uses - 0 or 1 steps in practice }
  Guard := 0;
  while (CurLo > SegStartSource) and (AClipRelativeFrame < TimelineOf(CurLo)) and
    (Guard < TonesMaxOnsetWalk) do
  begin
    NoteBounds(CurLo - 1, CurLo, CurHi);
    Inc(Guard);
  end;
  while (CurHi < SegEnd) and (AClipRelativeFrame >= TimelineOf(CurHi)) and
    (Guard < TonesMaxOnsetWalk) do
  begin
    NoteBounds(CurHi, CurLo, CurHi);
    Inc(Guard);
  end;

  Acc := NoteContribution(CurLo, CurHi);

  { plus the previous note, if its tail is still decaying over this frame -
    crossing back over a marker when it has to, same as the Beats renderer }
  if CurLo > SegStartSource then
  begin
    NoteBounds(CurLo - 1, PrevLo, PrevHi);
    Acc := Acc + NoteContribution(PrevLo, PrevHi);
  end
  else if k > 0 then
  begin
    LoadSegment(k - 1);
    if (SegTimelineLen > 0) and (SegSourceLen > 0) then
    begin
      NoteBounds(SegEnd - 1, PrevLo, PrevHi);
      Acc := Acc + NoteContribution(PrevLo, PrevHi);
    end;
  end;

  Result := Acc;
end;

{ The audio-producing entry point for a warped clip: Beats goes through the
  slice renderer above, Tones through the pitch-synchronous one, RePitch stays
  a plain continuous resample read straight through its position map. Plain
  ClipSourcePosition remains available for callers that want a single nominal
  position (detune anchors, split points, marker placement) rather than audio. }
function ClipSourceSample(Clip: PPlaybackClip; AClipRelativeFrame: Int64;
  AChannel: Integer; AHintK: PInteger): Single;
var
  AbsPos: Double;
begin
  if (Clip^.MarkerCount >= 2) and (Clip^.WarpMode = 2) then
    Exit(TonesClipSample(Clip, AClipRelativeFrame, AChannel, AHintK));
  if (Clip^.MarkerCount >= 2) and (Clip^.WarpMode <> 1) then
    Exit(BeatsClipSample(Clip, AClipRelativeFrame, AChannel, AHintK));

  AbsPos := Clip^.Offset + ClipSourcePosition(Clip, AClipRelativeFrame, AHintK);
  if (AbsPos < 0) or (AbsPos >= Clip^.FrameCount) then
    Result := 0
  else
    Result := Interpolate(Clip^.Data, Clip^.FrameCount, Clip^.Channels,
      AChannel, AbsPos);
end;

{ Independent per-clip pitch trim (the "Detune" slider) that never touches
  Length/Position - added on top of ClipSourcePosition rather than inside
  it, so Beats/RePitch warping itself is completely untouched.

  Splits the timeline into small fixed grains (DetuneGrainMs each), each
  anchored to wherever ClipSourcePosition already says its start should be
  (true regardless of warp mode, so detune composes with either for free).
  Within a grain the read pointer simply advances FORWARD from the anchor
  at the pitch-shifted rate, drifting away from the natural position by up
  to (Rate - 1) * GrainFrames; the next grain re-anchors, and the last
  Overlap frames of every grain crossfade into the next grain's own
  (already running) read. Classic tape-splice/overlap-add granular pitch
  shifting.

  An earlier version instead ping-ponged the read inside each grain's
  natural source span - which plays audio BACKWARD for the tail of every
  grain whenever Rate > 1 (a 1 - 1/Rate fraction of each grain: ~16% at
  +3 semitones, half at +12). Reversed audio every 25ms was audible as
  constant gritty distortion on any detuned clip. Forward drift reads
  contiguous real audio; the small per-grain re-anchor jump is exactly
  what the overlap crossfade is for. }
function DetunedClipSample(Clip: PPlaybackClip; AClipRelativeFrame: Int64;
  AChannel: Integer; AHintK: PInteger): Single;
const
  DetuneGrainMs = 25;
var
  Rate, AnchorStart, AnchorEnd: Double;
  GrainFrames, GrainIndex, GrainStartTimeline, GrainOffsetIntoGrain, Overlap: Int64;
  PosCurrent, SampleCurrent, PosNext, SampleNext, FadeT: Double;

  function SafeInterp(ARelPos: Double): Single;
  var
    AbsPos: Double;
  begin
    AbsPos := Clip^.Offset + ARelPos;
    if (AbsPos < 0) or (AbsPos >= Clip^.FrameCount) then
      Result := 0
    else
      Result := Interpolate(Clip^.Data, Clip^.FrameCount, Clip^.Channels, AChannel, AbsPos);
  end;

begin
  if Clip^.DetuneSemitones = 0 then
    Exit(ClipSourceSample(Clip, AClipRelativeFrame, AChannel, AHintK));

  Rate := Exp((Clip^.DetuneSemitones / 12) * Ln(2));
  GrainFrames := (DetuneGrainMs * ProjectSampleRate) div 1000;
  if GrainFrames < 1 then
    GrainFrames := 1;
  Overlap := GrainFrames div 4;
  if Overlap < 1 then
    Overlap := 1;

  GrainIndex := AClipRelativeFrame div GrainFrames;
  GrainStartTimeline := GrainIndex * GrainFrames;
  GrainOffsetIntoGrain := AClipRelativeFrame - GrainStartTimeline;

  { both anchors share the one hint: they sit a grain apart, so at worst a
    marker falls between them and each query costs the single step back or
    forward that FindWarpSegment's bidirectional adjust is there for }
  AnchorStart := ClipSourcePosition(Clip, GrainStartTimeline, AHintK);

  PosCurrent := AnchorStart + GrainOffsetIntoGrain * Rate;
  SampleCurrent := SafeInterp(PosCurrent);

  if GrainOffsetIntoGrain < GrainFrames - Overlap then
    Exit(SampleCurrent);

  { last Overlap frames of this grain - blend towards the next grain, whose
    own local offset starts a bit negative here, i.e. it's already "running"
    underneath the tail of this one and lands exactly on its own anchor at
    the boundary }
  AnchorEnd := ClipSourcePosition(Clip, GrainStartTimeline + GrainFrames, AHintK);
  PosNext := AnchorEnd + (GrainOffsetIntoGrain - GrainFrames) * Rate;
  SampleNext := SafeInterp(PosNext);

  FadeT := (GrainOffsetIntoGrain - (GrainFrames - Overlap)) / Overlap;
  Result := SampleCurrent * (1 - FadeT) + SampleNext * FadeT;
end;

{ SP-1200-style swing: if APosition falls on an odd step of the given
  division (8th or 16th notes), delay it later by a fraction of that step's
  length. ASwingPercent follows the SP-1200's own convention - 50 = straight,
  75 = the theoretical ceiling where the delayed step lands exactly on the
  next one. Shared identically by the realtime engine and the offline
  render path (ProjectFile.RenderProjectToWav) so bounced audio never
  drifts from what was heard live. }
function SwungPosition(APosition: Int64; ASwingPercent: Single;
  ADivision: Integer; ABeatFrames: Int64): Int64;
var
  StepFrames: Int64;
  StepIndex: Int64;
begin
  if ADivision = 8 then
    StepFrames := ABeatFrames div 2
  else
    StepFrames := ABeatFrames div 4;
  if StepFrames < 1 then
    StepFrames := 1;

  StepIndex := Round(APosition / StepFrames);
  if Odd(StepIndex) then
    Result := APosition + Round((ASwingPercent - 50) / 25 * StepFrames)
  else
    Result := APosition;
end;

const
  { Cap on how many of a track's clips may be sounding at once within a
    single block. Clips on a chopped track sit end to end rather than piled
    up, so real overlap at one instant is a handful; this is deliberately
    far above that. A track that somehow exceeds it is flagged and falls
    back to the original scan-every-clip path in FillBlock, so the cap can
    never change what is heard - only how fast it is arrived at. }
  MaxActiveClipsPerTrack = 256;

var
  { Per-block scratch for BuildActiveClips below. Fixed-size and unit-level
    (not local to FillBlock) so the audio thread never allocates. }
  ActiveClipIdx: array[0..MaxTracks - 1, 0..MaxActiveClipsPerTrack - 1] of Integer;
  ActiveClipSwung: array[0..MaxTracks - 1, 0..MaxActiveClipsPerTrack - 1] of Int64;
  ActiveClipCount: array[0..MaxTracks - 1] of Integer;
  ActiveClipOverflow: array[0..MaxTracks - 1] of Boolean;

{ Works out, ONCE per block, which clips can sound during it and where swing
  puts them.

  FillBlock used to do this per FRAME: for every one of its 512 frames it
  walked every clip on every track and called SwungPosition on each just to
  discover that the clip wasn't playing. That is clip-count x 44100 calls a
  second - fine at a hundred clips, over budget (i.e. dropouts) at a few
  thousand, which is exactly what this app's chop-heavy workflow produces.

  Nothing SwungPosition depends on - the clip's Position, the track's swing
  settings, the tempo - changes within a block, so the result is identical
  for all 512 frames and is computed here instead. The frame loop then only
  visits clips that genuinely overlap the block. }
procedure BuildActiveClips(ABeatFrames: Int64);
var
  t, i, n: Integer;
  sp: Int64;
  SoloActive: Boolean;
  WinAStart, WinAEnd, WinBStart, WinBEnd: Int64;

  function Overlaps(ASwung, ALength: Int64): Boolean;
  begin
    Result := (WinAEnd > ASwung) and (WinAStart < ASwung + ALength);
    if (not Result) and (WinBEnd > WinBStart) then
      Result := (WinBEnd > ASwung) and (WinBStart < ASwung + ALength);
  end;

begin
  WinAStart := Playhead;
  WinAEnd := Playhead + BlockFrames;

  { a block that reaches the loop end carries on from LoopStart partway
    through, so clips around the loop point are in play for it too }
  WinBStart := 0;
  WinBEnd := 0;
  if LoopActive and (WinAEnd >= LoopEnd) then
  begin
    WinBStart := LoopStart;
    WinBEnd := LoopStart + BlockFrames;
  end;

  SoloActive := Project.AnyTrackSoloed;

  for t := 0 to MaxTracks - 1 do
  begin
    ActiveClipCount[t] := 0;
    ActiveClipOverflow[t] := False;
    if not Project.TrackAudible(t, SoloActive) then
      Continue;

    n := 0;
    for i := 0 to TrackClips[t].Count - 1 do
    begin
      sp := SwungPosition(TrackClips[t].Items[i].Position,
        Project.TrackSwingPercent[t], Project.TrackSwingDivision[t], ABeatFrames);
      if not Overlaps(sp, TrackClips[t].Items[i].Length) then
        Continue;
      if n >= MaxActiveClipsPerTrack then
      begin
        ActiveClipOverflow[t] := True;
        Break;
      end;
      ActiveClipIdx[t][n] := i;
      ActiveClipSwung[t][n] := sp;
      Inc(n);
    end;
    ActiveClipCount[t] := n;
  end;
end;

{ ---------------------------------------------------------------------------
  The block mixer.

  This is BLOCK-MAJOR: each stage processes the whole block before handing it
  to the next one, so a track's clips are summed across all 512 frames, then
  its notes, then its inserts, then its fader, and only then does the next
  track start. The engine used to be frame-major - one frame carried all the
  way from clip read to master output, then the next - which meant every
  per-frame iteration re-read Project.TrackEnabled/TrackVolume/
  TrackEffectCount, re-tested every effect slot's Kind, re-resolved every
  send's routing and re-took every branch, 44100 times a second per track.
  All of that is loop-invariant within a block and is hoisted out here.

  What is NOT allowed to change is the arithmetic. Float addition isn't
  associative, so the mix is only bit-identical to the frame-major engine if
  every accumulation still happens in the same order AT each frame - clips in
  active-list order, then notes, then monitoring; tracks in index order into
  the master; then send returns in bus order; then the click. It does, stage
  for stage. Effect chains reorder differently but equivalently: running
  stage 0 across the whole block and then stage 1 across it gives a serial
  chain of stateful effects exactly the same result as alternating them per
  frame, because each stage is a function only of its own state and the
  stream handed to it.

  The two deliberate behavioral differences are documented where they live:
  sidechain taps keyed off a HIGHER-numbered track (see TrackTapBuf), and the
  count-in handover, which now lands on a range boundary instead of mid-block
  (see NextRangeLength).
  --------------------------------------------------------------------------- }
procedure FillBlock;
var
  BeatFrames: Int64;
  GlobalFrame: Int64;
  ClipsBuilt: Boolean;
  RangeStart, RangeLen, f: Integer;

  { Runs ONE effect over a range of an L/R buffer pair. Hoists the sidechain
    source resolution out of the frame loop; the per-frame ProcessEffect call
    itself stays, since every effect in this engine is a serial recurrence
    (biquads, envelope followers, delay lines) with no block form. }
  procedure RunEffect(var AState: Effects.TEffectState;
    const AEffect: Effects.TEffect; ABufL, ABufR: PSingle;
    AStart, ACount: Integer);
  var
    i, Src: Integer;
    Tap: PSingle;
  begin
    Src := AEffect.SidechainSourceTrack;
    if (Src >= 0) and (Src < MaxTracks) then
    begin
      Tap := TrackTapBuf[Src];
      for i := AStart to AStart + ACount - 1 do
        Effects.ProcessEffect(AState, AEffect, ABufL[i], ABufR[i],
          ProjectSampleRate, Tap[i]);
    end
    else
      for i := AStart to AStart + ACount - 1 do
        Effects.ProcessEffect(AState, AEffect, ABufL[i], ABufR[i],
          ProjectSampleRate, 0);
  end;

  { Sums one sounding clip across a range into ScratchL/R.

    Carries its own copy of the transport position, advanced with exactly the
    loop-wrap rule the tail bookkeeping below uses, so a block that crosses
    the loop end reads the same source frames the frame-major engine did -
    BuildActiveClips already admits clips around the loop point for that. }
  procedure MixClipRange(AClip: PPlaybackClip; ASwung: Int64;
    AStart, ACount: Integer);
  var
    i: Integer;
    g, Rel: Int64;
    Mono: Single;
    HintK: Integer;
  begin
    g := GlobalFrame;
    { warp segment cursor for this clip across this range - see
      FindWarpSegment. Starting it at 0 each range costs one full scan per
      clip per block instead of one per SAMPLE, and it is scoped to the one
      clip it belongs to, so it can never be seeded from a clip with a
      different marker array. }
    HintK := 0;
    for i := AStart to AStart + ACount - 1 do
    begin
      Rel := g - ASwung;
      if (Rel >= 0) and (Rel < AClip^.Length) then
      begin
        if AClip^.Channels = 1 then
        begin
          { ONE call, fanned out to both outputs. DetunedClipSample is by far
            the most expensive thing in this loop (granular warp, the
            overlapping-slice sum, interpolation) and is pure in its
            arguments, so two identical calls would do all of that twice to
            arrive at the same number - a flat 2x on every mono clip. }
          Mono := DetunedClipSample(AClip, Rel, 0, @HintK) * AClip^.Gain;
          ScratchL[i] := ScratchL[i] + Mono;
          ScratchR[i] := ScratchR[i] + Mono;
        end
        else
        begin
          { both channels ask about the same Rel, so the second call finds the
            segment the first one just left in HintK without moving at all }
          ScratchL[i] := ScratchL[i] +
            DetunedClipSample(AClip, Rel, 0, @HintK) * AClip^.Gain;
          ScratchR[i] := ScratchR[i] +
            DetunedClipSample(AClip, Rel, 1, @HintK) * AClip^.Gain;
        end;
      end;

      { no Playing test: this is only ever reached from inside ProcessRange's
        "if Playing" clip branch, and Playing cannot change during the track
        pass - NextRangeLength guarantees it }
      Inc(g);
      if LoopActive and (g >= LoopEnd) then
        g := LoopStart;
    end;
  end;

  { Mixes frames [AStart, AStart + ACount) of the block. Called once for a
    normal block, twice when a count-in hands over inside it. }
  procedure ProcessRange(AStart, ACount: Integer);
  var
    t, i, e, s, Last: Integer;
    ZeroBytes: PtrUInt;
    Clip: PPlaybackClip;
    Swung: Int64;
    Vol, PanL, PanR, Amount, ClickVal: Single;
    Tap: PSingle;
    NeedPreFade, SoloActive: Boolean;
  begin
    Last := AStart + ACount - 1;
    { hoisted out of the track loop below like every other loop-invariant
      here - solo can't change part way through a block }
    SoloActive := Project.AnyTrackSoloed;

    ZeroBytes := ACount * SizeOf(Single);

    FillChar(MasterL[AStart], ZeroBytes, 0);
    FillChar(MasterR[AStart], ZeroBytes, 0);
    for s := 0 to Project.SendCount - 1 do
    begin
      FillChar(SendBufL[s][AStart], ZeroBytes, 0);
      FillChar(SendBufR[s][AStart], ZeroBytes, 0);
    end;

    for t := 0 to MaxTracks - 1 do
    begin
      Tap := TrackTapBuf[t];

      if not Project.TrackAudible(t, SoloActive) then
      begin
        { a muted track can't be the thing a kick hits - stop any
          ekSidechain keyed off it from ducking on a stale, frozen level.
          A track silenced by someone else's solo is muted in exactly this
          sense, so it takes the same path. }
        FillChar(Tap[AStart], ZeroBytes, 0);
        Continue;
      end;

      FillChar(ScratchL[AStart], ZeroBytes, 0);
      FillChar(ScratchR[AStart], ZeroBytes, 0);

      if Playing then
      begin
        if ActiveClipOverflow[t] then
          { more simultaneous clips on this track than the active list can
            hold - do it the original way so the mix is unaffected }
          for i := 0 to TrackClips[t].Count - 1 do
          begin
            Clip := @(TrackClips[t].Items[i]);
            Swung := SwungPosition(Clip^.Position, Project.TrackSwingPercent[t],
              Project.TrackSwingDivision[t], BeatFrames);
            MixClipRange(Clip, Swung, AStart, ACount);
          end
        else
          { the common path: only clips BuildActiveClips found overlapping
            this block, with their swing already resolved }
          for i := 0 to ActiveClipCount[t] - 1 do
            MixClipRange(@(TrackClips[t].Items[ActiveClipIdx[t][i]]),
              ActiveClipSwung[t][i], AStart, ACount);
      end;

      { Both voices advance one frame per iteration and deactivate themselves
        on the frame they run out, exactly as when this ran inside the frame
        loop. Skipped wholesale when neither is sounding, which is the case
        on nearly every track of nearly every block. }
      if LiveNotes[t].Active or FadingNotes[t].Active then
        for i := AStart to Last do
        begin
          MixNoteVoice(LiveNotes[t], 1.0, ScratchL[i], ScratchR[i]);
          if FadingNotes[t].Active then
          begin
            MixNoteVoice(FadingNotes[t], FadingNotes[t].FadeGain,
              ScratchL[i], ScratchR[i]);
            FadingNotes[t].FadeGain := FadingNotes[t].FadeGain -
              FadingNotes[t].FadeStep;
            if FadingNotes[t].FadeGain <= 0 then
              FadingNotes[t].Active := False;
          end;
        end;

      { input monitoring: mixes the live captured signal straight into this
        track's audible output with no playhead movement/recording required
        - independent of the record tap just below, so monitoring can stay
        on (or off) throughout a take with no change in what gets recorded }
      if Project.TrackIsInput[t] and Project.TrackMonitorEnabled[t] then
      begin
        VAdd(@ScratchL[AStart], @CapBufL[AStart], ACount);
        VAdd(@ScratchR[AStart], @CapBufR[AStart], ACount);
      end;

      { Record tap, taken here so a take is recorded DRY - before the insert
        chain below, after monitoring.

        Taken for the whole range whenever this is the armed track and the
        recorder is live at all, without narrowing to RecordStateRecording:
        the tail loop applies the per-frame RecordState gate when it writes.
        The frame-major engine tested RecordStateRecording here and could
        then flip it later in the same frame, which put one frame of silence
        at the head of every count-in take. Testing "not Idle" is still
        enough to skip the copy entirely when nothing is armed, since the
        only transition into Recording is out of CountIn. }
      if (t = RecordTrackIndex) and (RecordState <> RecordStateIdle) then
      begin
        if Project.TrackIsInput[t] then
        begin
          { an Input Track's take must be captured regardless of whether
            this track's own "M" monitor toggle happens to be on, matching
            regular tracks' dry tap }
          Move(CapBufL[AStart], RecTapL[AStart], ZeroBytes);
          Move(CapBufR[AStart], RecTapR[AStart], ZeroBytes);
        end
        else
        begin
          Move(ScratchL[AStart], RecTapL[AStart], ZeroBytes);
          Move(ScratchR[AStart], RecTapR[AStart], ZeroBytes);
        end;
      end;

      { per-track insert effects chain. Entirely separate from the SP1200
        master-bus emulation, which runs once on the final mix. }
      for e := 0 to Project.TrackEffectCount[t] - 1 do
        if Project.TrackEffects[t][e].Kind <> Effects.ekNone then
          RunEffect(TrackEffectState[t][e], Project.TrackEffects[t][e],
            ScratchL, ScratchR, AStart, ACount);

      { Pre-fader send tap: taken here, after the inserts but before the
        fader below. That ordering is the whole reason pre-fader exists -
        pull a track's fader to nothing and its contribution to the bus
        (and so the reverb tail it is feeding) carries on regardless, which
        is how a break dissolves into the wash instead of just stopping.
        Only worth copying when some enabled send on this track is actually
        pre-fader; post-fader sends read the faded buffer directly. }
      NeedPreFade := False;
      for s := 0 to Project.SendCount - 1 do
        if Project.SendEnabled[s] and Project.TrackSendEnabled[t][s] and
          Project.SendPreFader[s] then
          NeedPreFade := True;
      if NeedPreFade then
      begin
        Move(ScratchL[AStart], PreFadeL[AStart], ZeroBytes);
        Move(ScratchR[AStart], PreFadeR[AStart], ZeroBytes);
      end;

      { The track fader. This used to be pre-multiplied into every clip's
        Gain by ArrangementView.PushTrackToEngine and into note gains by
        MainForm, i.e. applied before the engine ever saw the audio - which
        left no point in the chain where a pre-fader anything could be
        tapped, and quietly meant a "recorded dry" take was in fact
        recorded through the fader. It is applied here now instead.

        The pan rides along with it: the two collapse into one pair of
        channel gains, so panning costs an extra multiply per block rather
        than an extra pass over the buffer, and VScale2 does both channels
        in a single walk.

        Position in the chain follows Ableton: the pan sits WITH the fader,
        which puts it before the post-fader send tap below and after the
        pre-fader one taken above. So a hard-left track's reverb leans left
        too, while a pre-fader send stays where it was - which is the point
        of a pre-fader send, it is deliberately upstream of the mixer strip.

        At pan 0 both gains are exactly 1.0, so Vol * 1.0 is Vol and a
        project with no pan set mixes bit-identically to before pan existed.

        Note the track tap below is taken after this, so a sidechain keyed
        off this track now follows its pan. VMaxAbs2 takes the louder of the
        two channels, so a hard-panned source still keys at full strength
        rather than dropping to whatever the silent side is. }
      Vol := Project.TrackVolume[t];
      Project.TrackPanGains(Project.TrackPan[t], PanL, PanR);
      VScale2(@ScratchL[AStart], @ScratchR[AStart], Vol * PanL, Vol * PanR,
        ACount);

      for s := 0 to Project.SendCount - 1 do
        if Project.SendEnabled[s] and Project.TrackSendEnabled[t][s] then
        begin
          Amount := Project.TrackSendLevel[t][s];
          if Project.SendPreFader[s] then
          begin
            VAddScaled(@SendBufL[s][AStart], @PreFadeL[AStart], Amount, ACount);
            VAddScaled(@SendBufR[s][AStart], @PreFadeR[AStart], Amount, ACount);
          end
          else
          begin
            VAddScaled(@SendBufL[s][AStart], @ScratchL[AStart], Amount, ACount);
            VAddScaled(@SendBufR[s][AStart], @ScratchR[AStart], Amount, ACount);
          end;
        end;

      { this track's final, post-insert-FX, post-fader level per frame - see
        TrackTapBuf's declaration for what a sidechain keyed off a track
        LATER in this same pass reads. Summed into the master in the same
        pass, in track index order, which is what keeps the master sum
        bit-identical to the frame-major engine's. }
      VMaxAbs2(@Tap[AStart], @ScratchL[AStart], @ScratchR[AStart], ACount);
      VAdd(@MasterL[AStart], @ScratchL[AStart], ACount);
      VAdd(@MasterR[AStart], @ScratchR[AStart], ACount);
    end;

    { Send-bus returns. Each bus runs its chain ONCE on the sum of every
      track feeding it, then returns at its own level - so six tracks into
      one reverb is one shared room and one reverb's worth of CPU, not six
      of each.

      Note the chain runs every frame for as long as the bus is unmuted,
      including frames where nothing is feeding it. That is deliberate: a
      reverb or delay on a send has to keep ringing after the tracks
      feeding it have gone quiet, and skipping the chain on silence would
      freeze the tail mid-decay. Muting the bus does skip it, which is also
      how you get the CPU back from a send you aren't using. }
    for s := 0 to Project.SendCount - 1 do
    begin
      if not Project.SendEnabled[s] then
        Continue;
      for e := 0 to Project.SendEffectCount[s] - 1 do
        if Project.SendEffects[s][e].Kind <> Effects.ekNone then
          RunEffect(SendEffectState[s][e], Project.SendEffects[s][e],
            SendBufL[s], SendBufR[s], AStart, ACount);
      Amount := Project.SendReturnLevel[s];
      VAddScaled(@MasterL[AStart], @SendBufL[s][AStart], Amount, ACount);
      VAddScaled(@MasterR[AStart], @SendBufR[s][AStart], Amount, ACount);
    end;

    { Per-frame transport bookkeeping - the click voice, the recorder and
      the playhead. Genuinely serial (each frame's state depends on the one
      before), so this stays a frame loop; it is a handful of integer tests
      per frame with no DSP in it. }
    for i := AStart to Last do
    begin
      { metronome count-in: 4 clicks spaced one beat apart (at the current
        tempo), then hand off to recording }
      if RecordState = RecordStateCountIn then
      begin
        if CountInFramesUntilNextBeat <= 0 then
        begin
          if CountInBeatsRemaining > 0 then
          begin
            { plays this beat's click; recording starts a full beat after
              the 4th one, not on the same frame as it - matching a normal
              1-2-3-4 count-in where the take begins on the beat after "4" }
            ClickPlayPos := 0;
            Dec(CountInBeatsRemaining);
            CountInFramesUntilNextBeat := BeatFrames;
          end
          else
          begin
            { NextRangeLength normally consumes this handover at a range
              boundary, so the track pass above never runs at a transport
              state the tail is about to change. Getting here would take a
              beat shorter than one block (some thousands of BPM); handled
              anyway rather than left to wedge the count-in. }
            RecordState := RecordStateRecording;
            RecordWritePos := 0;
            Playing := True;
          end;
        end
        else
          Dec(CountInFramesUntilNextBeat);
      end;

      { tempo-aware metronome during normal playback - reuses the exact same
        click sound/voice as the count-in above. The two never collide: this
        only fires once Playing is True, and count-in only runs before Playing
        becomes True. Driven off the absolute playback position (not a running
        countdown) so it stays beat-aligned to frame 0 through seeks/loops
        instead of drifting. }
      if Playing and MetronomeEnabled and (ClickPlayPos < 0) and
        (GlobalFrame mod BeatFrames = 0) then
        ClickPlayPos := 0;

      if (ClickPlayPos >= 0) and (ClickPlayPos < Length(ClickSamples)) then
      begin
        ClickVal := ClickSamples[ClickPlayPos];
        MasterL[i] := MasterL[i] + ClickVal;
        MasterR[i] := MasterR[i] + ClickVal;
        Inc(ClickPlayPos);
      end
      else
        ClickPlayPos := -1;

      if RecordState = RecordStateRecording then
      begin
        if RecordWritePos < RecordCapacityFrames then
        begin
          RecordBuffer[RecordWritePos * 2] := RecTapL[i];
          RecordBuffer[RecordWritePos * 2 + 1] := RecTapR[i];
          Inc(RecordWritePos);
        end
        else
          RecordState := RecordStateIdle; { hit the cap - auto-stop }
      end;

      if Playing then
      begin
        Inc(GlobalFrame);
        if LoopActive and (GlobalFrame >= LoopEnd) then
          GlobalFrame := LoopStart;
      end;
    end;

    { master bus insert chain - applied to the summed mix after every track's
      own inserts, before the hard clamp. Separate from the SP1200 emulation,
      which is a different, always-master, non-editable system applied later
      in TPlaybackThread.Execute on the whole finished block. }
    for e := 0 to Project.MasterEffectCount - 1 do
      if Project.MasterEffects[e].Kind <> Effects.ekNone then
        RunEffect(MasterEffectState[e], Project.MasterEffects[e],
          MasterL, MasterR, AStart, ACount);

    { clamp in place first, then interleave. The interleave is a stride-2
      scatter - AVX2 can do it with an unpack/permute pair, but it runs once
      per block rather than once per track, so it stays plain Pascal. }
    VClamp1(@MasterL[AStart], ACount);
    VClamp1(@MasterR[AStart], ACount);

    for i := AStart to Last do
    begin
      MixBuffer[i * OutputChannels] := MasterL[i];
      MixBuffer[i * OutputChannels + 1] := MasterR[i];
    end;
  end;

  { How many frames from AStart may be mixed at one consistent transport
    state, and applies any handover that falls exactly on AStart.

    Only one thing changes Playing/RecordState mid-block: the count-in's last
    beat elapsing. Frame-major could absorb that anywhere, because it re-read
    both every frame; block-major decides them once per range, so the range
    has to END where the handover is due and the NEXT one starts with it
    already applied. Everything else the tail loop mutates (the click voice,
    the record write position, the cap auto-stop) is invisible to the track
    pass and needs no split. }
  function NextRangeLength(AStart: Integer): Integer;
  begin
    Result := BlockFrames - AStart;
    if (RecordState <> RecordStateCountIn) or (CountInBeatsRemaining > 0) then
      Exit;

    if CountInFramesUntilNextBeat <= 0 then
    begin
      RecordState := RecordStateRecording;
      RecordWritePos := 0;
      { arrangement playback starts on the exact same frame as recording,
        both from wherever the playhead already sits (it hasn't moved since
        Playing was False throughout count-in) }
      Playing := True;
    end
    else if CountInFramesUntilNextBeat < Result then
      Result := CountInFramesUntilNextBeat;
  end;

begin
  BeatFrames := Round((ProjectSampleRate * 60) / Project.TempoBPM);
  GlobalFrame := Playhead;
  ClipsBuilt := False;

  FillChar(MixBuffer^, BlockFrames * OutputChannels * SizeOf(Single), 0);
  { so a block where nothing is armed, or the armed track is muted, records
    silence rather than the previous block's tap }
  FillChar(RecTapL^, BlockFrames * SizeOf(Single), 0);
  FillChar(RecTapR^, BlockFrames * SizeOf(Single), 0);

  { drained once for the whole block, up front, so every monitoring track
    hears the identical live sample on a given frame instead of each draining
    its own share of the ring - see PopCaptureFrame }
  for f := 0 to BlockFrames - 1 do
    PopCaptureFrame(CapBufL[f], CapBufR[f]);

  RangeStart := 0;
  while RangeStart < BlockFrames do
  begin
    RangeLen := NextRangeLength(RangeStart);
    if Playing and not ClipsBuilt then
    begin
      { once per block, as before - but also right after a count-in hands
        over partway through one, where the frame-major engine went on using
        whatever active list the last playing block happened to leave behind }
      BuildActiveClips(BeatFrames);
      ClipsBuilt := True;
    end;
    ProcessRange(RangeStart, RangeLen);
    Inc(RangeStart, RangeLen);
  end;

  if Playing then
    Playhead := GlobalFrame;
end;

procedure TPlaybackThread.Execute;
begin
  { MXCSR is per-thread, so this has to be set here rather than at start-up -
    see DenormalGuard. This is the thread that runs every effect's feedback
    path, so it is the one that matters most. }
  EnableFlushDenormals;

  while not Terminated do
  begin
    DrainCommands;
    if EngineProcessingActive then
    begin
      FillBlock;
      if SP1200Enabled then
        SP1200Process(SP1200MixState, MixBuffer, BlockFrames, OutputChannels,
          ProjectSampleRate);
      Backend.WriteBlock(MixBuffer, BlockFrames);
    end
    else
    begin
      {$IFDEF WINDOWS}
      { DirectSound only. Its buffer is a LOOPING one: the play cursor never
        stops, it just keeps running over whatever bytes are already in the
        ring. So the moment we stop feeding it - a one-shot note ending, or
        the transport being paused - it goes right on replaying the last few
        blocks we happened to leave there, forever. That is the "one-shots
        never end, they start repeating" bug, and it's also why pausing over
        a clip loops that clip while pausing over empty timeline sounds fine:
        in the empty case the stale bytes are already silence.

        ALSA has no equivalent problem - stop writing and the PCM simply
        drains and underruns into silence - so this is deliberately Windows
        only, and the else branch below is the untouched original path.

        Feeding actual silence instead of sleeping also paces this loop for
        free: DirectSoundWriteBlock applies its own backpressure against the
        play cursor, so it returns at roughly real time rather than spinning. }
      FillChar(MixBuffer^, BlockFrames * OutputChannels * SizeOf(Single), 0);
      Backend.WriteBlock(MixBuffer, BlockFrames);
      {$ELSE}
      Sleep(10);
      {$ENDIF}
    end;
  end;
end;

procedure TCaptureThread.Execute;
var
  TempBuf: PSingle;
begin
  EnableFlushDenormals; { per-thread - see DenormalGuard }
  GetMem(TempBuf, InputBufferFrames * OutputChannels * SizeOf(Single));
  try
    while not Terminated do
    begin
      if CaptureAvailable and Backend.CaptureRead(TempBuf, InputBufferFrames) then
        PushCaptureFrames(TempBuf, InputBufferFrames)
      else
        Sleep(5); { no capture device, or a read failure - avoid busy-spinning }
    end;
  finally
    FreeMem(TempBuf);
  end;
end;

procedure PrecomputeClick;
var
  i, ClickLen: Integer;
  Envelope: Single;
begin
  ClickLen := Round(ProjectSampleRate * ClickDurationMs / 1000);
  SetLength(ClickSamples, ClickLen);
  for i := 0 to ClickLen - 1 do
  begin
    Envelope := 1.0 - (i / ClickLen);
    ClickSamples[i] := Envelope * 0.5 * Sin(2 * Pi * ClickFreqHz * i / ProjectSampleRate);
  end;
end;

{ Points Backend at the implementation CurrentBackendKind names. Every field
  of the record is assigned by each Create*Backend function, so there is no
  path where a stale pointer from the previous backend survives a switch.
  Windows has one backend today, so the kind is ignored there rather than
  offering a JACK option that can't be built. }
procedure SelectBackendRecord;
begin
  {$IFDEF WINDOWS}
  Backend := CreateDirectSoundBackend;
  {$ELSE}
  case CurrentBackendKind of
    AudioBackendJACK: Backend := CreateJACKBackend;
    AudioBackendPipeWire: Backend := CreatePipeWireBackend;
  else
    Backend := CreateALSABackend;
  end;
  {$ENDIF}
end;

{ Opens the capture backend + ring buffer and starts CaptureThread - shared
  by AudioEngineInit and AudioEngineSetInputBufferSize (the latter via a
  prior CloseCaptureAndStopThread), same stop/reopen/restart shape
  AudioEngineSetBufferSize uses for the output side. CaptureOpen failing
  (no capture device, e.g. this machine has none, or the DirectSound stub)
  is not fatal - CaptureAvailable just stays False and the capture thread
  idles forever, monitoring/Input-Track recording silently produce silence
  instead of the app failing to start. }
procedure OpenCaptureAndStartThread;
begin
  CaptureRingCapacityFrames := Int64(InputBufferFrames) * CaptureRingBlocks;
  GetMem(CaptureRingBuffer, CaptureRingCapacityFrames * OutputChannels * SizeOf(Single));
  CaptureWriteCount := 0;
  CaptureReadCount := 0;
  CaptureReadIdx := 0;

  CaptureAvailable := Backend.CaptureOpen(ProjectSampleRate, OutputChannels,
    InputBufferFrames);

  CaptureThread := TCaptureThread.Create(False);
  CaptureThread.FreeOnTerminate := False;
end;

procedure CloseCaptureAndStopThread;
begin
  if CaptureThread <> nil then
  begin
    CaptureThread.Terminate;
    CaptureThread.WaitFor;
    FreeAndNil(CaptureThread);
  end;

  if CaptureAvailable then
    Backend.CaptureClose;
  CaptureAvailable := False;

  if CaptureRingBuffer <> nil then
  begin
    FreeMem(CaptureRingBuffer);
    CaptureRingBuffer := nil;
  end;
end;

procedure AudioEngineInit;
var
  i, e: Integer;
  StoredKind: Integer;
begin
  RingHead := 0;
  RingTail := 0;
  NoteRingHead := 0;
  NoteRingTail := 0;
  Playhead := 0;
  Playing := False;
  LoopActive := False;
  SP1200Enabled := False;
  MetronomeEnabled := False;
  SP1200Reset(SP1200MixState);
  RecordState := RecordStateIdle;
  RecordWritePos := 0;
  ClickPlayPos := -1;
  { Each of these keeps the engine's own default unless eris.conf actually
    carries a value - an absent or first-run config leaves start-up behaving
    exactly as it did before Config existed, rather than clamping to zero. }
  InputBufferFrames := DefaultInputBufferFrames;
  if Cfg.InputBufferSize > 0 then
    InputBufferFrames := Cfg.InputBufferSize;
  InputGainLinear := 1.0;
  if Cfg.InputGainDb <> 0 then
    AudioEngineSetInputGainDb(Cfg.InputGainDb);
  AudioEngineInvalidateGrainCache;
  for i := 0 to MaxTracks - 1 do
  begin
    TrackClips[i].Items := nil;
    TrackClips[i].Count := 0;
    LiveNotes[i].Active := False;
    FadingNotes[i].Active := False;
  end;
  AudioEngineResetEffectState;

  BlockFrames := DefaultBlockFrames;
  if Cfg.BufferSize > 0 then
    BlockFrames := Cfg.BufferSize;
  GetMem(MixBuffer, BlockFrames * OutputChannels * SizeOf(Single));
  { zeroes the sidechain tap buffers too, which the mixer reads across block
    boundaries - see TrackTapBuf }
  AllocMixScratch;

  RecordCapacityFrames := MaxRecordSeconds * ProjectSampleRate;
  GetMem(RecordBuffer, RecordCapacityFrames * OutputChannels * SizeOf(Single));

  PrecomputeClick;

  { A backend stored in eris.conf wins outright - it is an explicit choice
    someone made in Preferences, and second-guessing it with a probe would
    make the setting look like it had been ignored.

    Failing that (first run, or a name this platform cannot provide) the old
    behaviour stands: PipeWire when it is genuinely there - library loads AND
    a server socket exists, see PwServerPresent - otherwise the platform
    native one. Note this deliberately does not verify a stored JACK choice
    either, exactly as AudioEngineSetBackend does not; an unavailable backend
    simply never opens, which is silent but stable.

    The device names are pushed straight at PipeWireBackend rather than
    through AudioEngineSetPipeWireDevices, because that one cycles a live
    device to apply them - here nothing is open yet, so recording the choice
    before the first Open is all that is needed. }
  {$IFNDEF WINDOWS}
  StoredKind := AudioEngineBackendKindFromName(Cfg.BackendName);
  if StoredKind >= 0 then
    CurrentBackendKind := StoredKind
  else if PipeWireAvailable then
    CurrentBackendKind := AudioBackendPipeWire;

  PipeWireSetOutputDevice(Cfg.OutputDevice);
  PipeWireSetInputDevice(Cfg.InputDevice);
  {$ELSE}
  StoredKind := -1;
  {$ENDIF}

  SelectBackendRecord;
  Backend.Open(ProjectSampleRate, OutputChannels, BlockFrames);

  PlaybackThread := TPlaybackThread.Create(False);
  PlaybackThread.FreeOnTerminate := False;

  OpenCaptureAndStartThread;
end;

procedure AudioEngineShutdown;
var
  i: Integer;
begin
  CloseCaptureAndStopThread;

  if PlaybackThread <> nil then
  begin
    PlaybackThread.Terminate;
    PlaybackThread.WaitFor;
    FreeAndNil(PlaybackThread);
  end;

  { safe to free directly here, unlike PushPendingFree's realtime-thread
    call site above - the playback thread is fully stopped by this point,
    so nothing can still be reading through any of these }
  AudioEngineDrainPendingFrees;
  for i := 0 to MaxTracks - 1 do
    if TrackClips[i].Items <> nil then
    begin
      FreeMem(TrackClips[i].Items);
      TrackClips[i].Items := nil;
    end;

  Backend.Close;

  if MixBuffer <> nil then
  begin
    FreeMem(MixBuffer);
    MixBuffer := nil;
  end;
  FreeMixScratch;

  if RecordBuffer <> nil then
  begin
    FreeMem(RecordBuffer);
    RecordBuffer := nil;
  end;
end;

procedure AudioEngineSetTrackClips(ATrackIndex: Integer; AItems: PPlaybackClip;
  ACount: Integer);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckSetTrackClips;
  Cmd.TrackIndex := ATrackIndex;
  Cmd.Items := AItems;
  Cmd.Count := ACount;
  PushCommand(Cmd);
end;

procedure AudioEnginePlay;
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckPlay;
  PushCommand(Cmd);
end;

procedure AudioEngineStop;
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckStop;
  PushCommand(Cmd);
  {$IFDEF WINDOWS}
  { the command is only picked up at the top of the playback loop, and on
    DirectSound that loop can be parked in WriteBlock's backpressure wait for
    up to two seconds. Callers that wait for the engine to go idle before
    freeing sample memory (File>New, File>Open) sit on the UI thread for that
    whole time, which is a visibly frozen app. ALSA's write returns as soon as
    the device drains, so it has no equivalent delay to shorten. }
  DirectSoundCancelWait;
  {$ENDIF}
end;

procedure AudioEngineSeek(AFrame: Int64);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckSeek;
  Cmd.Param := AFrame;
  PushCommand(Cmd);
end;

procedure AudioEngineSetLoop(AStart, AEnd: Int64);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckSetLoop;
  Cmd.Param := AStart;
  Cmd.Param2 := AEnd;
  PushCommand(Cmd);
end;

procedure AudioEngineClearLoop;
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckClearLoop;
  PushCommand(Cmd);
end;

procedure AudioEngineTriggerNote(ATrackIndex: Integer; AData: PSingle;
  AFrameCount, AChannels: Integer; ASemitoneOffset: Single; AGain: Single);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckTriggerNote;
  Cmd.TrackIndex := ATrackIndex;
  Cmd.NoteData := AData;
  Cmd.NoteFrameCount := AFrameCount;
  Cmd.NoteChannels := AChannels;
  Cmd.NoteRate := SemitonesToRate(ASemitoneOffset);
  Cmd.NoteGain := AGain;
  PushCommand(Cmd);
end;

procedure AudioEngineTriggerNoteRT(ATrackIndex: Integer; AData: PSingle;
  AFrameCount, AChannels: Integer; ASemitoneOffset: Single; AGain: Single);
var
  Event: TQueuedNote;
begin
  Event.TrackIndex := ATrackIndex;
  Event.Data := AData;
  Event.FrameCount := AFrameCount;
  Event.Channels := AChannels;
  Event.Rate := SemitonesToRate(ASemitoneOffset);
  Event.Gain := AGain;
  PushNoteEvent(Event);
end;

function AudioEngineIsPlaying: Boolean;
begin
  Result := Playing;
end;

function AudioEngineIsBusy: Boolean;
begin
  Result := Playing or AnyLiveNoteActive or (RecordState <> RecordStateIdle);
end;

function AudioEngineProcessingActive: Boolean;
begin
  Result := EngineProcessingActive;
end;

procedure AudioEngineInvalidateGrainCache;
begin
  { nothing to invalidate - see the declaration }
end;

procedure AudioEngineResetEffectState;
var
  i, e: Integer;
begin
  for i := 0 to MaxTracks - 1 do
    for e := 0 to Effects.MaxEffectsPerTrack - 1 do
      Effects.EffectStateReset(TrackEffectState[i][e]);
  for e := 0 to Effects.MaxEffectsPerTrack - 1 do
    Effects.EffectStateReset(MasterEffectState[e]);
  for i := 0 to Project.SendCount - 1 do
    for e := 0 to Effects.MaxEffectsPerTrack - 1 do
      Effects.EffectStateReset(SendEffectState[i][e]);
end;

function AudioEngineHasClip: Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to MaxTracks - 1 do
    if TrackClips[i].Count > 0 then
      Exit(True);
end;

function AudioEngineGetPosition: Int64;
begin
  Result := Playhead;
  {$IFDEF WINDOWS}
  { Playhead is advanced the moment FillBlock hands a block to WriteBlock, but
    on DirectSound that block then waits in an 8-block ring before anyone hears
    it - and the ring is refilled in lumps, so the raw value both runs ahead of
    the audio and moves unevenly. Subtracting what is still queued gives the
    frame actually being played. ALSA's blocking write paces FillBlock itself,
    which is why this is Windows only. }
  Dec(Result, DirectSoundQueuedFrames);
  if Result < 0 then
    Result := 0;
  {$ENDIF}
end;

function AudioEngineLiveNoteActive(ATrackIndex: Integer): Boolean;
begin
  Result := (ATrackIndex >= 0) and (ATrackIndex < MaxTracks) and
    LiveNotes[ATrackIndex].Active;
end;

function AudioEngineLiveNotePosition(ATrackIndex: Integer): Int64;
begin
  if (ATrackIndex < 0) or (ATrackIndex >= MaxTracks) then
    Exit(0);
  Result := Trunc(LiveNotes[ATrackIndex].Position);
end;

procedure AudioEngineSetSP1200Enabled(AEnabled: Boolean);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckSetSP1200Enabled;
  if AEnabled then
    Cmd.Param := 1
  else
    Cmd.Param := 0;
  PushCommand(Cmd);
end;

function AudioEngineGetSP1200Enabled: Boolean;
begin
  Result := SP1200Enabled;
end;

procedure AudioEngineSetMetronomeEnabled(AEnabled: Boolean);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckSetMetronomeEnabled;
  if AEnabled then
    Cmd.Param := 1
  else
    Cmd.Param := 0;
  PushCommand(Cmd);
end;

function AudioEngineGetMetronomeEnabled: Boolean;
begin
  Result := MetronomeEnabled;
end;

function AudioEngineTunerPitchHz(ATarget, AEffectIndex: Integer): Single;
var
  SendIndex: Integer;
begin
  Result := 0;
  if (AEffectIndex < 0) or (AEffectIndex >= Effects.MaxEffectsPerTrack) then
    Exit;
  { With the realtime thread idle, nothing is updating TunerFreqHz and the
    last reading is stale - report nothing rather than leave a note frozen
    on the display after the transport stops. EngineProcessingActive rather
    than Playing, because it also covers a monitored line-in with the
    transport stopped, which is exactly when a tuner is most useful. }
  if not EngineProcessingActive then
    Exit;
  SendIndex := Project.BusToSendIndex(ATarget);
  if SendIndex >= 0 then
    Result := Effects.TunerReadoutHz(SendEffectState[SendIndex][AEffectIndex])
  else if ATarget = Project.BusMaster then
    Result := Effects.TunerReadoutHz(MasterEffectState[AEffectIndex])
  else if (ATarget >= 0) and (ATarget < MaxTracks) then
    Result := Effects.TunerReadoutHz(TrackEffectState[ATarget][AEffectIndex]);
end;

function AudioEngineGetBufferSize: Integer;
begin
  Result := BlockFrames;
end;

procedure AudioEngineSetBufferSize(ANewBufferSize: Integer);
begin
  if ANewBufferSize = BlockFrames then
    Exit;

  { fully stop the realtime thread before touching Backend/MixBuffer - same
    ordering as AudioEngineShutdown, so the callback can never run against a
    closed device or a buffer sized for the old BlockFrames }
  if PlaybackThread <> nil then
  begin
    PlaybackThread.Terminate;
    PlaybackThread.WaitFor;
    FreeAndNil(PlaybackThread);
  end;

  Backend.Close;

  FreeMem(MixBuffer);
  FreeMixScratch;
  BlockFrames := ANewBufferSize;
  GetMem(MixBuffer, BlockFrames * OutputChannels * SizeOf(Single));
  { every block-major scratch buffer is BlockFrames long, so they all have to
    be resized with it - safe here only because the playback thread is fully
    stopped above }
  AllocMixScratch;

  Backend.Open(ProjectSampleRate, OutputChannels, BlockFrames);

  PlaybackThread := TPlaybackThread.Create(False);
  PlaybackThread.FreeOnTerminate := False;
end;

function AudioEngineGetBackend: Integer;
begin
  Result := CurrentBackendKind;
end;

function AudioEngineBackendNameFromKind(AKind: Integer): string;
begin
  {$IFDEF WINDOWS}
  Result := 'directsound';
  {$ELSE}
  case AKind of
    AudioBackendJACK: Result := 'jack';
    AudioBackendPipeWire: Result := 'pipewire';
  else
    Result := 'alsa';
  end;
  {$ENDIF}
end;

function AudioEngineBackendKindFromName(const AName: string): Integer;
begin
  Result := -1;
  {$IFDEF WINDOWS}
  if SameText(AName, 'directsound') then
    Result := AudioBackendNative;
  {$ELSE}
  if SameText(AName, 'alsa') then
    Result := AudioBackendNative
  else if SameText(AName, 'jack') then
    Result := AudioBackendJACK
  else if SameText(AName, 'pipewire') then
    Result := AudioBackendPipeWire;
  {$ENDIF}
end;

procedure AudioEngineSetBackend(ABackendKind: Integer);
begin
  if ABackendKind = CurrentBackendKind then
    Exit;

  { teardown order copies AudioEngineShutdown (capture first, then the
    playback thread, then the device), and the bring-up order copies
    AudioEngineInit (device, playback thread, then capture) - the backend
    record itself is only swapped in between, while nothing is running
    against it }
  CloseCaptureAndStopThread;

  if PlaybackThread <> nil then
  begin
    PlaybackThread.Terminate;
    PlaybackThread.WaitFor;
    FreeAndNil(PlaybackThread);
  end;

  Backend.Close;

  CurrentBackendKind := ABackendKind;
  SelectBackendRecord;

  { Open's result is deliberately ignored, exactly as in AudioEngineInit: a
    backend that can't open (JACK not installed, or its server not running)
    leaves the engine alive but silent rather than failing the switch - see
    AudioEngineSetBackend's interface comment. }
  Backend.Open(ProjectSampleRate, OutputChannels, BlockFrames);

  PlaybackThread := TPlaybackThread.Create(False);
  PlaybackThread.FreeOnTerminate := False;

  OpenCaptureAndStartThread;
end;

function AudioEngineGetPipeWireOutputDevice: string;
begin
  {$IFDEF WINDOWS}
  Result := '';
  {$ELSE}
  Result := PipeWireGetOutputDevice;
  {$ENDIF}
end;

function AudioEngineGetPipeWireInputDevice: string;
begin
  {$IFDEF WINDOWS}
  Result := '';
  {$ELSE}
  Result := PipeWireGetInputDevice;
  {$ENDIF}
end;

procedure AudioEngineSetPipeWireDevices(const AOutputName, AInputName: string);
{$IFNDEF WINDOWS}
var
  Changed: Boolean;
{$ENDIF}
begin
  {$IFNDEF WINDOWS}
  Changed := (AOutputName <> PipeWireGetOutputDevice) or
    (AInputName <> PipeWireGetInputDevice);
  if not Changed then
    Exit;

  { the backend reads these when it opens its streams, so they're set first
    and the device is then cycled - only worth cycling if PipeWire is
    actually the live backend, otherwise this just records the choice for
    whenever it next becomes one }
  PipeWireSetOutputDevice(AOutputName);
  PipeWireSetInputDevice(AInputName);

  if CurrentBackendKind <> AudioBackendPipeWire then
    Exit;

  CloseCaptureAndStopThread;

  if PlaybackThread <> nil then
  begin
    PlaybackThread.Terminate;
    PlaybackThread.WaitFor;
    FreeAndNil(PlaybackThread);
  end;

  Backend.Close;
  Backend.Open(ProjectSampleRate, OutputChannels, BlockFrames);

  PlaybackThread := TPlaybackThread.Create(False);
  PlaybackThread.FreeOnTerminate := False;

  OpenCaptureAndStartThread;
  {$ENDIF}
end;

function AudioEngineGetInputBufferSize: Integer;
begin
  Result := InputBufferFrames;
end;

procedure AudioEngineSetInputBufferSize(ANewBufferSize: Integer);
begin
  if ANewBufferSize = InputBufferFrames then
    Exit;
  CloseCaptureAndStopThread;
  InputBufferFrames := ANewBufferSize;
  OpenCaptureAndStartThread;
end;

function AudioEngineGetInputGainDb: Single;
begin
  if InputGainLinear <= 0 then
    Exit(-100);
  Result := 20 * (Ln(InputGainLinear) / Ln(10));
end;

procedure AudioEngineSetInputGainDb(ADb: Single);
begin
  InputGainLinear := Exp((ADb / 20) * Ln(10));
end;

procedure AudioEngineDrainPendingFrees;
var
  Ptr: Pointer;
begin
  while PendingFreeTail <> PendingFreeHead do
  begin
    Ptr := PendingFrees[PendingFreeTail];
    PendingFreeTail := (PendingFreeTail + 1) mod PendingFreeCapacity;
    FreeMem(Ptr);
  end;
end;

procedure AudioEngineStartCountIn(ATrackIndex: Integer);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckStartCountIn;
  Cmd.TrackIndex := ATrackIndex;
  PushCommand(Cmd);
end;

procedure AudioEngineStartRecording(ATrackIndex: Integer);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckStartRecording;
  Cmd.TrackIndex := ATrackIndex;
  PushCommand(Cmd);
end;

procedure AudioEngineStopRecording;
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckStopRecording;
  PushCommand(Cmd);
end;

function AudioEngineRecordState: Integer;
begin
  Result := RecordState;
end;

function AudioEngineTakeRecordedAudio(out AData: PSingle; out AFrameCount: Integer): Boolean;
begin
  AData := nil;
  AFrameCount := 0;
  if RecordWritePos <= 0 then
    Exit(False);

  AFrameCount := RecordWritePos;
  GetMem(AData, AFrameCount * OutputChannels * SizeOf(Single));
  Move(RecordBuffer^, AData^, AFrameCount * OutputChannels * SizeOf(Single));
  Result := True;
end;

end.
