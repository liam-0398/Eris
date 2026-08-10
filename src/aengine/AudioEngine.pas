unit AudioEngine;

{$mode objfpc}{$H+}

interface

const
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

{ Buffer size (frames per callback). Changing it stops the realtime thread,
  closes the backend, reopens it at the new size, and restarts the thread -
  fully serialized on the calling (main) thread, per CLAUDE.md's rule for
  runtime backend/device changes. Must not be called from the audio thread. }
function AudioEngineGetBufferSize: Integer;
procedure AudioEngineSetBufferSize(ANewBufferSize: Integer);

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
  ALSABackend,
  {$ENDIF}
  Resample, Project, SP1200, Effects;

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
  BlockFrames: Integer;
  PlaybackThread: TPlaybackThread;
  MixBuffer: PSingle;

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
  InputGainLinear: Single;

  RingBuffer: array[0..RingBufferCapacity - 1] of TCommand;
  RingHead: Integer;
  RingTail: Integer;

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

  { Each track's final (post-own-inserts) peak level for the CURRENT block's
    frame being processed by FillBlock's "for t" loop below - written once
    per track per frame, read by any other track's ekSidechain effect. For a
    source track processed earlier than the reader in that same "for t" pass
    this is this frame's real value; for a source track processed later it's
    still last frame's value (one-sample stale). That's inaudible for a
    ducking envelope follower, so it's not worth the complexity of a second
    pass over tracks just to avoid it. }
  TrackTapLevel: array[0..MaxTracks - 1] of Single;

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
  for i := 0 to AFrameCount - 1 do
  begin
    Idx := (CaptureWriteCount + i) mod CaptureRingCapacityFrames;
    CaptureRingBuffer[Idx * 2] := ASrc[i * 2];
    CaptureRingBuffer[Idx * 2 + 1] := ASrc[i * 2 + 1];
  end;
  CaptureWriteCount := CaptureWriteCount + AFrameCount;
end;

{ FillBlock-only (audio thread) consumer for the capture ring, one frame at a
  time - silence (not the last real sample held over) whenever the ring is
  empty, so an underrun is heard as a gap rather than a stuck/repeating
  sample. }
procedure PopCaptureFrame(out ACapL, ACapR: Single);
var
  Idx: Int64;
begin
  if CaptureWriteCount - CaptureReadCount <= 0 then
  begin
    ACapL := 0;
    ACapR := 0;
    Exit;
  end;
  Idx := CaptureReadCount mod CaptureRingCapacityFrames;
  ACapL := CaptureRingBuffer[Idx * 2] * InputGainLinear;
  ACapR := CaptureRingBuffer[Idx * 2 + 1] * InputGainLinear;
  Inc(CaptureReadCount);
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

procedure DrainCommands;
var
  Cmd: TCommand;
  t: Integer;
begin
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
        begin
          t := Cmd.TrackIndex;
          if LiveNotes[t].Active then
          begin
            FadingNotes[t] := LiveNotes[t];
            FadingNotes[t].FadeStep := 1.0 / NoteFadeSamples;
          end;

          LiveNotes[t].Data := Cmd.NoteData;
          LiveNotes[t].FrameCount := Cmd.NoteFrameCount;
          LiveNotes[t].Channels := Cmd.NoteChannels;
          LiveNotes[t].Position := 0;
          LiveNotes[t].Rate := Cmd.NoteRate;
          LiveNotes[t].Gain := Cmd.NoteGain;
          LiveNotes[t].FadeGain := 1.0;
          LiveNotes[t].FadeStep := 0;
          LiveNotes[t].Active := True;
        end;
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

{ Nominal timeline -> source map for one clip.

  For RePitch this IS the playback position: a continuous vari-speed resample
  across each segment, unchanged from the original warp implementation.

  For Beats it is the NOMINAL map only - the source position the warp
  notionally assigns to a timeline frame. Beats playback does not read through
  a single position at all (see BeatsClipSample), so this is used for the
  detune layer's grain anchors and for non-audio callers that need a single
  answer, not for producing Beats audio. }
function ClipSourcePosition(Clip: PPlaybackClip; AClipRelativeFrame: Int64): Double;
var
  k: Integer;
  SegStartTimeline, SegStartSource, SegTimelineLen, SegSourceLen: Int64;
  OffsetIntoSeg: Int64;
  RePitchFadeFrames, RePitchDistToEnd, NextSegSourceLen, NextSegTimelineLen: Int64;
  RePitchPosA, RePitchPosB, RePitchFadeT: Double;
begin
  if Clip^.MarkerCount < 2 then
    Exit(AClipRelativeFrame);

  k := 0;
  while (k < Clip^.MarkerCount - 2) and
    (AClipRelativeFrame >= Clip^.MarkerTimeline[k + 1]) do
    Inc(k);

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
  AChannel: Integer): Single;
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

  k := 0;
  while (k < Clip^.MarkerCount - 2) and
    (AClipRelativeFrame >= Clip^.MarkerTimeline[k + 1]) do
    Inc(k);

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
  AChannel: Integer): Single;
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

  k := 0;
  while (k < Clip^.MarkerCount - 2) and
    (AClipRelativeFrame >= Clip^.MarkerTimeline[k + 1]) do
    Inc(k);

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
  AChannel: Integer): Single;
var
  AbsPos: Double;
begin
  if (Clip^.MarkerCount >= 2) and (Clip^.WarpMode = 2) then
    Exit(TonesClipSample(Clip, AClipRelativeFrame, AChannel));
  if (Clip^.MarkerCount >= 2) and (Clip^.WarpMode <> 1) then
    Exit(BeatsClipSample(Clip, AClipRelativeFrame, AChannel));

  AbsPos := Clip^.Offset + ClipSourcePosition(Clip, AClipRelativeFrame);
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
  AChannel: Integer): Single;
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
    Exit(ClipSourceSample(Clip, AClipRelativeFrame, AChannel));

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

  AnchorStart := ClipSourcePosition(Clip, GrainStartTimeline);

  PosCurrent := AnchorStart + GrainOffsetIntoGrain * Rate;
  SampleCurrent := SafeInterp(PosCurrent);

  if GrainOffsetIntoGrain < GrainFrames - Overlap then
    Exit(SampleCurrent);

  { last Overlap frames of this grain - blend towards the next grain, whose
    own local offset starts a bit negative here, i.e. it's already "running"
    underneath the tail of this one and lands exactly on its own anchor at
    the boundary }
  AnchorEnd := ClipSourcePosition(Clip, GrainStartTimeline + GrainFrames);
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

procedure FillBlock;

  function SidechainLevelFor(ASourceTrack: Integer): Single;
  begin
    if (ASourceTrack < 0) or (ASourceTrack >= MaxTracks) then
      Result := 0
    else
      Result := TrackTapLevel[ASourceTrack];
  end;

var
  Frame, t, i, e: Integer;
  GlobalFrame, ClipRelFrame, SwungPos: Int64;
  Clip: PPlaybackClip;
  L, R, TrackL, TrackR, RecL, RecR, ClickVal, CapL, CapR: Single;
  BeatFrames: Int64;
begin
  FillChar(MixBuffer^, BlockFrames * OutputChannels * SizeOf(Single), 0);
  BeatFrames := Round((ProjectSampleRate * 60) / Project.TempoBPM);
  GlobalFrame := Playhead;

  for Frame := 0 to BlockFrames - 1 do
  begin
    L := 0;
    R := 0;
    RecL := 0;
    RecR := 0;
    { popped once per frame (not once per track) so every monitoring track
      hears the identical live sample this frame, instead of each track
      draining its own share of the ring - see PopCaptureFrame }
    PopCaptureFrame(CapL, CapR);

    for t := 0 to MaxTracks - 1 do
    begin
      if not Project.TrackEnabled[t] then
      begin
        { a muted track can't be the thing a kick hits - stop any
          ekSidechain keyed off it from ducking on a stale, frozen level }
        TrackTapLevel[t] := 0;
        Continue;
      end;

      TrackL := 0;
      TrackR := 0;

      if Playing then
        for i := 0 to TrackClips[t].Count - 1 do
        begin
          Clip := @(TrackClips[t].Items[i]);
          SwungPos := SwungPosition(Clip^.Position, Project.TrackSwingPercent[t],
            Project.TrackSwingDivision[t], BeatFrames);
          ClipRelFrame := GlobalFrame - SwungPos;
          if (ClipRelFrame < 0) or (ClipRelFrame >= Clip^.Length) then
            Continue;

          if Clip^.Channels = 1 then
          begin
            TrackL := TrackL + DetunedClipSample(Clip, ClipRelFrame, 0) * Clip^.Gain;
            TrackR := TrackR + DetunedClipSample(Clip, ClipRelFrame, 0) * Clip^.Gain;
          end
          else
          begin
            TrackL := TrackL + DetunedClipSample(Clip, ClipRelFrame, 0) * Clip^.Gain;
            TrackR := TrackR + DetunedClipSample(Clip, ClipRelFrame, 1) * Clip^.Gain;
          end;
        end;

      MixNoteVoice(LiveNotes[t], 1.0, TrackL, TrackR);
      if FadingNotes[t].Active then
      begin
        MixNoteVoice(FadingNotes[t], FadingNotes[t].FadeGain, TrackL, TrackR);
        FadingNotes[t].FadeGain := FadingNotes[t].FadeGain - FadingNotes[t].FadeStep;
        if FadingNotes[t].FadeGain <= 0 then
          FadingNotes[t].Active := False;
      end;

      { input monitoring: mixes the live captured signal straight into this
        track's audible output with no playhead movement/recording required
        - independent of the record tap just below, so monitoring can stay
        on (or off) throughout a take with no change in what gets recorded }
      if Project.TrackIsInput[t] and Project.TrackMonitorEnabled[t] then
      begin
        TrackL := TrackL + CapL;
        TrackR := TrackR + CapR;
      end;

      if (RecordState = RecordStateRecording) and (t = RecordTrackIndex) then
      begin
        if Project.TrackIsInput[t] then
        begin
          { tapped straight from the capture ring, not TrackL/TrackR - an
            Input Track's take must be captured regardless of whether this
            track's own "M" monitor toggle happens to be on, matching
            regular tracks' "recorded dry" tap just below }
          RecL := CapL;
          RecR := CapR;
        end
        else
        begin
          RecL := TrackL;
          RecR := TrackR;
        end;
      end;

      { per-track insert effects chain - applied after the record tap, so a
        take is recorded dry even if the track's monitored/played-back
        output is being filtered/EQ'd. Entirely separate from the SP1200
        master-bus emulation, which runs once on the final mix. }
      for e := 0 to Project.TrackEffectCount[t] - 1 do
        if Project.TrackEffects[t][e].Kind <> Effects.ekNone then
          Effects.ProcessEffect(TrackEffectState[t][e], Project.TrackEffects[t][e],
            TrackL, TrackR, ProjectSampleRate,
            SidechainLevelFor(Project.TrackEffects[t][e].SidechainSourceTrack));

      { this track's final, post-insert-FX level for the frame - see
        TrackTapLevel's declaration for why a source track processed later
        in this same "for t" pass reads one frame stale here, not zero. }
      if Abs(TrackL) > Abs(TrackR) then
        TrackTapLevel[t] := Abs(TrackL)
      else
        TrackTapLevel[t] := Abs(TrackR);

      L := L + TrackL;
      R := R + TrackR;
    end;

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
          RecordState := RecordStateRecording;
          RecordWritePos := 0;
          { arrangement playback starts on the exact same frame as
            recording, both from wherever the playhead already sits (it
            hasn't moved since Playing was False throughout count-in) }
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
      L := L + ClickVal;
      R := R + ClickVal;
      Inc(ClickPlayPos);
    end
    else
      ClickPlayPos := -1;

    if RecordState = RecordStateRecording then
    begin
      if RecordWritePos < RecordCapacityFrames then
      begin
        RecordBuffer[RecordWritePos * 2] := RecL;
        RecordBuffer[RecordWritePos * 2 + 1] := RecR;
        Inc(RecordWritePos);
      end
      else
        RecordState := RecordStateIdle; { hit the cap - auto-stop }
    end;

    { master bus insert chain - applied to the summed mix after every track's
      own inserts, before the hard clamp. Separate from the SP1200 emulation,
      which is a different, always-master, non-editable system applied later
      in TPlaybackThread.Execute on the whole finished block. }
    for e := 0 to Project.MasterEffectCount - 1 do
      if Project.MasterEffects[e].Kind <> Effects.ekNone then
        Effects.ProcessEffect(MasterEffectState[e], Project.MasterEffects[e], L, R,
          ProjectSampleRate, SidechainLevelFor(Project.MasterEffects[e].SidechainSourceTrack));

    if L > 1.0 then L := 1.0 else if L < -1.0 then L := -1.0;
    if R > 1.0 then R := 1.0 else if R < -1.0 then R := -1.0;
    MixBuffer[Frame * OutputChannels] := L;
    MixBuffer[Frame * OutputChannels + 1] := R;

    if Playing then
    begin
      Inc(GlobalFrame);
      if LoopActive and (GlobalFrame >= LoopEnd) then
        GlobalFrame := LoopStart;
    end;
  end;

  if Playing then
    Playhead := GlobalFrame;
end;

procedure TPlaybackThread.Execute;
begin
  while not Terminated do
  begin
    DrainCommands;
    if Playing or AnyLiveNoteActive or (RecordState <> RecordStateIdle) or
      AnyTrackMonitoring then
    begin
      FillBlock;
      if SP1200Enabled then
        SP1200Process(SP1200MixState, MixBuffer, BlockFrames, OutputChannels,
          ProjectSampleRate);
      Backend.WriteBlock(MixBuffer, BlockFrames);
    end
    else
      Sleep(10);
  end;
end;

procedure TCaptureThread.Execute;
var
  TempBuf: PSingle;
begin
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
begin
  RingHead := 0;
  RingTail := 0;
  Playhead := 0;
  Playing := False;
  LoopActive := False;
  SP1200Enabled := False;
  MetronomeEnabled := False;
  SP1200Reset(SP1200MixState);
  RecordState := RecordStateIdle;
  RecordWritePos := 0;
  ClickPlayPos := -1;
  InputBufferFrames := DefaultInputBufferFrames;
  InputGainLinear := 1.0;
  AudioEngineInvalidateGrainCache;
  for i := 0 to MaxTracks - 1 do
  begin
    TrackClips[i].Items := nil;
    TrackClips[i].Count := 0;
    LiveNotes[i].Active := False;
    FadingNotes[i].Active := False;
    TrackTapLevel[i] := 0;
    for e := 0 to Effects.MaxEffectsPerTrack - 1 do
      Effects.EffectStateReset(TrackEffectState[i][e]);
  end;
  for e := 0 to Effects.MaxEffectsPerTrack - 1 do
    Effects.EffectStateReset(MasterEffectState[e]);

  BlockFrames := DefaultBlockFrames;
  GetMem(MixBuffer, BlockFrames * OutputChannels * SizeOf(Single));

  RecordCapacityFrames := MaxRecordSeconds * ProjectSampleRate;
  GetMem(RecordBuffer, RecordCapacityFrames * OutputChannels * SizeOf(Single));

  PrecomputeClick;

  {$IFDEF WINDOWS}
  Backend := CreateDirectSoundBackend;
  {$ELSE}
  Backend := CreateALSABackend;
  {$ENDIF}
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

function AudioEngineIsPlaying: Boolean;
begin
  Result := Playing;
end;

function AudioEngineIsBusy: Boolean;
begin
  Result := Playing or AnyLiveNoteActive or (RecordState <> RecordStateIdle);
end;

procedure AudioEngineInvalidateGrainCache;
begin
  { nothing to invalidate - see the declaration }
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
  BlockFrames := ANewBufferSize;
  GetMem(MixBuffer, BlockFrames * OutputChannels * SizeOf(Single));

  Backend.Open(ProjectSampleRate, OutputChannels, BlockFrames);

  PlaybackThread := TPlaybackThread.Create(False);
  PlaybackThread.FreeOnTerminate := False;
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
