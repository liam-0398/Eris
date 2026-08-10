unit AudioEngine;

{$mode objfpc}{$H+}

interface

const
  ProjectSampleRate = 44100;
  MaxClipWarpMarkers = 8;

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
    WarpMode: Integer; { 0 = Beats (loop/truncate, preserves pitch), 1 = RePitch (vari-speed) }
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
{ Must be called after AudioEngineIsBusy waits false and before Project.NewProject
  frees SamplePool - see GrainCache's declaration comment: it's keyed by each
  clip's raw sample Data pointer, and FreeMem'ing the old pool then GetMem'ing
  the new one very plausibly hands back the same address for a similarly
  sized block, which would silently serve a stale grain answer computed
  against a completely different, now-freed sample. }
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
  RingBufferCapacity = 32;
  PendingFreeCapacity = 64;
  GrainCacheSlots = 16;
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

  { Beats-mode grain lookup cache for ClipSourcePosition/FindTransientGrain -
    see the comment right above FindTransientGrain's declaration for why
    this exists. Keyed by (sample data pointer, clip offset, segment) rather
    than by the TPlaybackClip pointer itself: that pointer is into a GetMem
    block that gets freed and reallocated on every edit (PushTrackToEngine),
    and a same-sized reallocation - e.g. every step of a live warp-marker
    drag - can plausibly get served the very same address back from the
    allocator's free list while genuinely meaning a different clip/segment.
    (Data, Offset, SegStartSource, SegSourceLen) together fully determine
    which absolute region of Clip^.Transients a lookup searches - see
    FindTransientGrain's own comment on that translation - so two lookups
    that agree on all four are, by construction, asking the identical
    question and must get the identical answer; there is no coincidental
    false-hit case to worry about, unlike keying on clip identity would be.
    Sized for MaxTracks simultaneously-active clips with headroom; a miss
    just falls back to the real scan, never a wrong answer. }
  GrainCache: array[0..GrainCacheSlots - 1] of record
    Data: PSingle;
    Offset: Int64;
    SegStartSource, SegSourceLen: Int64;
    GrainStartSource, GrainSourceLen: Int64;
    GrainStartTimeline, GrainEndTimeline: Int64;
    GrainTimelineLenF: Double;
  end;
  GrainCacheNextSlot: Integer;

  { Each track's final (post-own-inserts) peak level for the CURRENT block's
    frame being processed by FillBlock's "for t" loop below - written once
    per track per frame, read by any other track's ekSidechain effect. For a
    source track processed earlier than the reader in that same "for t" pass
    this is this frame's real value; for a source track processed later it's
    still last frame's value (one-sample stale). That's inaudible for a
    ducking envelope follower, so it's not worth the complexity of a second
    pass over tracks just to avoid it. }
  TrackTapLevel: array[0..MaxTracks - 1] of Single;

function PushCommand(const ACmd: TCommand): Boolean;
var
  NextHead: Integer;
begin
  NextHead := (RingHead + 1) mod RingBufferCapacity;
  if NextHead = RingTail then
    Exit(False);
  RingBuffer[RingHead] := ACmd;
  RingHead := NextHead;
  Result := True;
end;

function PopCommand(out ACmd: TCommand): Boolean;
begin
  if RingTail = RingHead then
    Exit(False);
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
  { Beats mode subdivides a warp segment into grains roughly this long
    (approximating transient-bounded slices without real onset detection),
    each independently looped/truncated to fill its share of the
    stretch/compression - keeps pitch untouched, matching Ableton's "Beats"
    warp mode rather than vari-speed/Re-Pitch }
  WarpGrainMs = 120;
  { small local search window used to land loop/truncate cut points on a
    near-silent sample, so the splice doesn't click }
  WarpZeroCrossSearchFrames = 32;
  { half-width of the position blend applied around each ping-pong reversal -
    see the reversal-smoothing block in ClipSourcePosition }
  WarpReversalFadeMs = 4;
  { width of the position blend applied before each RePitch-mode marker, to
    absorb the rate kink between two segments - see ClipSourcePosition }
  WarpRepitchFadeMs = 4;

function FindNearestZeroCrossing(AData: PSingle; AFrameCount, AChannels: Integer;
  ACenterFrame: Int64; ASearchRadius: Integer): Int64;
var
  i, lo, hi: Int64;
  ch: Integer;
  amp, bestAmp: Single;
begin
  if (AData = nil) or (AFrameCount <= 0) then
    Exit(ACenterFrame);

  Result := ACenterFrame;
  if Result < 0 then
    Result := 0;
  if Result > AFrameCount - 1 then
    Result := AFrameCount - 1;

  lo := ACenterFrame - ASearchRadius;
  if lo < 0 then
    lo := 0;
  hi := ACenterFrame + ASearchRadius;
  if hi > AFrameCount - 1 then
    hi := AFrameCount - 1;

  bestAmp := 1.0e30;
  for i := lo to hi do
  begin
    amp := 0;
    for ch := 0 to AChannels - 1 do
      amp := amp + Abs(AData[i * AChannels + ch]);
    if amp < bestAmp then
    begin
      bestAmp := amp;
      Result := i;
    end;
  end;
end;

function ClipSourcePosition(Clip: PPlaybackClip; AClipRelativeFrame: Int64;
  AGrainEnd: PInt64 = nil): Double;
var
  k: Integer;
  SegStartTimeline, SegStartSource, SegTimelineLen, SegSourceLen: Int64;
  OffsetIntoSeg, StopPoint, SnappedStop, CandidatePos: Int64;
  GrainSourceLen, GrainCount, GrainIndex: Int64;
  GrainTimelineLenF: Double;
  GrainStartTimeline, GrainStartSource, GrainOffsetIntoGrain: Int64;
  GrainEndTimeline: Int64;
  Overflow, LoopRegionStart, LoopRegionEnd, LoopLen, Period: Int64;
  Phase, FadeFrames, FadeT, PosA, PosB, SignedOffset, DistToPeak: Double;
  HaveTransientGrain: Boolean;
  RePitchFadeFrames, RePitchDistToEnd, NextSegSourceLen, NextSegTimelineLen: Int64;
  RePitchPosA, RePitchPosB, RePitchFadeT: Double;

  { Same transient-bounded grain lookup as Waveform.WarpedSourcePosition -
    kept as an independent copy (rather than a shared helper taking a
    TFrameArray) because this side of the engine only ever has a raw
    PInt64/Count pair (Clip^.Transients/TransientCount), the lock-free-safe
    shape - see the TPlaybackClip field comments. }
  function FindTransientGrain(out AGrainStartSource, AGrainSourceLen,
    AGrainStartTimeline, AGrainEndTimeline: Int64;
    out AGrainTimelineLenF: Double): Boolean;
  var
    Ratio: Double;
    TIdx: Integer;
    BoundaryPos, NextBoundaryPos, NaturalLen: Int64;
    AccumTimeline, GrainTL: Double;
    CacheIdx, ci: Integer;
  begin
    Result := False;
    if (Clip^.Transients = nil) or (Clip^.TransientCount <= 0) then
      Exit;

    { fast path: playback advances one sample at a time and a grain
      typically spans hundreds to thousands of samples, so the overwhelming
      majority of calls ask about the same grain as the previous call for
      this exact clip+segment. Reusing it skips walking Clip^.Transients
      from the start (the loops below) on every single output sample, which
      is what actually costs time for a sample with many detected
      transients - this is a pure memoization of that scan, not a change to
      what it computes; a cache miss/mismatch always just falls through to
      the unchanged scan below. }
    CacheIdx := -1;
    for ci := 0 to GrainCacheSlots - 1 do
      if (GrainCache[ci].Data = Clip^.Data) and (GrainCache[ci].Offset = Clip^.Offset) and
        (GrainCache[ci].SegStartSource = SegStartSource) and
        (GrainCache[ci].SegSourceLen = SegSourceLen) then
      begin
        CacheIdx := ci;
        if (OffsetIntoSeg >= GrainCache[ci].GrainStartTimeline) and
          (OffsetIntoSeg < GrainCache[ci].GrainStartTimeline + GrainCache[ci].GrainTimelineLenF) then
        begin
          AGrainStartSource := GrainCache[ci].GrainStartSource;
          AGrainSourceLen := GrainCache[ci].GrainSourceLen;
          AGrainStartTimeline := GrainCache[ci].GrainStartTimeline;
          AGrainEndTimeline := GrainCache[ci].GrainEndTimeline;
          AGrainTimelineLenF := GrainCache[ci].GrainTimelineLenF;
          Exit(True);
        end;
        Break;
      end;
    if CacheIdx < 0 then
    begin
      CacheIdx := GrainCacheNextSlot;
      GrainCacheNextSlot := (GrainCacheNextSlot + 1) mod GrainCacheSlots;
    end;

    Ratio := SegTimelineLen / SegSourceLen;

    { Clip^.Transients holds ABSOLUTE positions within the whole sample file
      (that's the frame of reference DetectTransients works in, and the same
      cached array is shared by every clip that chops a different region out
      of the same sample) - but SegStartSource/SegSourceLen are CLIP-relative
      (relative to Clip^.Offset, same as MarkerSource). Every comparison
      against them has to translate by -Clip^.Offset first, or a clip that
      doesn't start at frame 0 of its source (any sample chop) compares
      transients against the wrong region entirely. }
    TIdx := 0;
    while (TIdx < Clip^.TransientCount) and
      ((Clip^.Transients + TIdx)^ - Clip^.Offset <= SegStartSource) do
      Inc(TIdx);

    { no transient strictly inside this segment: report failure so the
      fixed-grid fallback subdivides it (~WarpGrainMs grains) instead of
      treating the whole segment as ONE giant grain, whose single long
      ping-pong is exactly the obvious-loop sound grains exist to avoid.
      (DetectTransients always returns at least frame 0, so without this
      check the fallback was unreachable for any loaded sample.) }
    if (TIdx >= Clip^.TransientCount) or
      ((Clip^.Transients + TIdx)^ - Clip^.Offset >= SegStartSource + SegSourceLen) then
      Exit;

    BoundaryPos := SegStartSource;
    AccumTimeline := 0;

    while True do
    begin
      if (TIdx < Clip^.TransientCount) and
        ((Clip^.Transients + TIdx)^ - Clip^.Offset < SegStartSource + SegSourceLen) then
        NextBoundaryPos := (Clip^.Transients + TIdx)^ - Clip^.Offset
      else
        NextBoundaryPos := SegStartSource + SegSourceLen;

      NaturalLen := NextBoundaryPos - BoundaryPos;
      if NaturalLen < 1 then
      begin
        if NextBoundaryPos >= SegStartSource + SegSourceLen then
          Exit;
        BoundaryPos := NextBoundaryPos;
        Inc(TIdx);
        Continue;
      end;

      GrainTL := NaturalLen * Ratio;

      if (OffsetIntoSeg < AccumTimeline + GrainTL) or
        (NextBoundaryPos >= SegStartSource + SegSourceLen) then
      begin
        AGrainStartSource := BoundaryPos;
        AGrainSourceLen := NaturalLen;
        AGrainStartTimeline := Trunc(AccumTimeline);
        { the FIRST timeline frame the lookup above assigns to the NEXT
          grain, i.e. ceil of this grain's real (fractional) end. Trunc'ing
          both start and length instead loses up to 2 frames, reporting a
          "grain end" that still belongs to THIS grain - the crossfade in
          ClipSourceSample then converges onto this grain's own natural
          continuation (a no-op) and the real splice 1-2 frames later plays
          completely unfaded. }
        AGrainEndTimeline := Trunc(AccumTimeline + GrainTL);
        if AGrainEndTimeline < AccumTimeline + GrainTL then
          Inc(AGrainEndTimeline);
        AGrainTimelineLenF := GrainTL;

        GrainCache[CacheIdx].Data := Clip^.Data;
        GrainCache[CacheIdx].Offset := Clip^.Offset;
        GrainCache[CacheIdx].SegStartSource := SegStartSource;
        GrainCache[CacheIdx].SegSourceLen := SegSourceLen;
        GrainCache[CacheIdx].GrainStartSource := AGrainStartSource;
        GrainCache[CacheIdx].GrainSourceLen := AGrainSourceLen;
        GrainCache[CacheIdx].GrainStartTimeline := AGrainStartTimeline;
        GrainCache[CacheIdx].GrainEndTimeline := AGrainEndTimeline;
        GrainCache[CacheIdx].GrainTimelineLenF := AGrainTimelineLenF;

        Exit(True);
      end;

      AccumTimeline := AccumTimeline + GrainTL;
      BoundaryPos := NextBoundaryPos;
      Inc(TIdx);
    end;
  end;

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
      changing pitch, instead of preserving pitch via loop/truncate }
    if SegTimelineLen = 0 then
      Exit(SegStartSource);
    RePitchPosA := SegStartSource + OffsetIntoSeg * (SegSourceLen / SegTimelineLen);

    { Two adjacent segments generally run at different rates, so the read
      pointer's SLOPE (not its position - the two formulas already agree
      exactly at the marker) kinks abruptly at every internal marker. Blend
      this segment's own formula with the next segment's, extrapolated
      backward, over a short window ending exactly at the marker: since both
      converge to the same value there, this fully absorbs the rate change
      before the marker instead of snapping it - same idea as the ping-pong
      reversal smoothing above, applied to a rate kink instead of a
      direction reversal. }
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

  { Beats: subdivide the segment into many small grains (roughly WarpGrainMs
    each) instead of treating the whole marker-to-marker span as one
    loop/truncate unit, and distribute the stretch/compression evenly across
    all of them. This is what real transient-preserving time-stretch does
    (Ableton's Beats mode slices at every transient, not just at the two
    warp markers you placed) - one big loop repeat at the tail of a long
    segment is what makes a stretch sound like an obvious loop; many small
    grains is what makes it sound natural. }
  HaveTransientGrain := FindTransientGrain(GrainStartSource, GrainSourceLen,
    GrainStartTimeline, GrainEndTimeline, GrainTimelineLenF);

  if not HaveTransientGrain then
  begin
    GrainSourceLen := (WarpGrainMs * ProjectSampleRate) div 1000;
    if GrainSourceLen > SegSourceLen then
      GrainSourceLen := SegSourceLen;
    if GrainSourceLen < 1 then
      GrainSourceLen := 1;
    GrainCount := SegSourceLen div GrainSourceLen;
    if GrainCount < 1 then
      GrainCount := 1;
    GrainSourceLen := SegSourceLen div GrainCount; { re-tile evenly, no remainder grain }

    GrainTimelineLenF := SegTimelineLen / GrainCount;
    GrainIndex := Trunc(OffsetIntoSeg / GrainTimelineLenF);
    if GrainIndex >= GrainCount then
      GrainIndex := GrainCount - 1;
    GrainStartTimeline := Trunc(GrainIndex * GrainTimelineLenF);
    GrainStartSource := SegStartSource + GrainIndex * GrainSourceLen;
    { first timeline frame at which Trunc(OffsetIntoSeg / GrainTimelineLenF)
      actually flips to the next index - ceil, for the same reason as the
      transient path (see FindTransientGrain's grain-end comment) }
    GrainEndTimeline := Trunc((GrainIndex + 1) * GrainTimelineLenF);
    if GrainEndTimeline < (GrainIndex + 1) * GrainTimelineLenF then
      Inc(GrainEndTimeline);
  end;

  { float accumulation can push the last grain's ceil'd end a frame past the
    segment - clamp to the next marker's own frame, which is exactly where
    the next segment's first grain takes over }
  if GrainEndTimeline > SegTimelineLen then
    GrainEndTimeline := SegTimelineLen;

  GrainOffsetIntoGrain := OffsetIntoSeg - GrainStartTimeline;

  if AGrainEnd <> nil then
    AGrainEnd^ := SegStartTimeline + GrainEndTimeline;

  if GrainOffsetIntoGrain < GrainSourceLen then
  begin
    { natural, un-stretched playback within this grain }
    if GrainTimelineLenF < GrainSourceLen then
    begin
      { this grain needs to end up SHORTER than its natural length - land on
        a nearby zero crossing instead of hard-cutting, so the handover to
        the next grain doesn't click }
      StopPoint := GrainStartSource + Trunc(GrainTimelineLenF);
      { Clip^.Data/FrameCount span the WHOLE sample file (absolute frame 0 =
        start of the WAV) while StopPoint is clip-relative (relative to
        Clip^.Offset, same as MarkerSource) - translate to absolute for the
        search, then back for the returned (clip-relative) position, or a
        clip that's a chop of a longer sample (Offset <> 0) snaps to a
        "zero crossing" that's actually near an unrelated part of the file. }
      SnappedStop := FindNearestZeroCrossing(Clip^.Data, Clip^.FrameCount,
        Clip^.Channels, StopPoint + Clip^.Offset, WarpZeroCrossSearchFrames) -
        Clip^.Offset;
      CandidatePos := GrainStartSource + GrainOffsetIntoGrain;
      if CandidatePos >= SnappedStop then
        Exit(SnappedStop);
      Exit(CandidatePos);
    end;
    Exit(GrainStartSource + GrainOffsetIntoGrain);
  end;

  { this grain needs to be LONGER - ping-pong (play forward to the grain's
    end, then backward to a zero crossing near its middle, then forward
    again) to fill the extra time, rather than a crude forward-repeat which
    tends to sound like an obvious loop. Matches Ableton's "Loop
    Back-and-Forth" transient loop mode, the one their own docs call out as
    giving the highest-quality result. }
  Overflow := GrainOffsetIntoGrain - GrainSourceLen;
  { same clip-relative -> absolute -> clip-relative translation as the
    truncate branch above - see the comment there }
  LoopRegionStart := FindNearestZeroCrossing(Clip^.Data, Clip^.FrameCount,
    Clip^.Channels, GrainStartSource + GrainSourceLen div 2 + Clip^.Offset,
    WarpZeroCrossSearchFrames) - Clip^.Offset;
  LoopRegionEnd := FindNearestZeroCrossing(Clip^.Data, Clip^.FrameCount,
    Clip^.Channels, GrainStartSource + GrainSourceLen + Clip^.Offset,
    WarpZeroCrossSearchFrames) - Clip^.Offset;
  { never snap PAST the grain's own natural boundary - only earlier, so the
    loop can never read into the next grain (or past the segment's end) }
  if LoopRegionEnd > GrainStartSource + GrainSourceLen then
    LoopRegionEnd := GrainStartSource + GrainSourceLen;

  LoopLen := LoopRegionEnd - LoopRegionStart;
  if LoopLen < 1 then
    LoopLen := 1;
  Period := 2 * LoopLen;
  Phase := Overflow mod Period;

  { A reversal flips the read pointer's direction outright - a slope
    discontinuity zero-crossing snapping (which only fixes amplitude
    discontinuities) can't touch. Blend the two candidate POSITIONS on
    either side of each reversal so the read pointer's trajectory turns
    around smoothly instead of snapping instantly; both candidates reference
    the same underlying audio (just approached from opposite directions), so
    blending positions here - unlike across unrelated grains - is a
    legitimate smoothing of one continuous path. }
  FadeFrames := (WarpReversalFadeMs * ProjectSampleRate) / 1000;
  if FadeFrames > LoopLen / 2 then
    FadeFrames := LoopLen / 2;
  if FadeFrames < 1 then
    FadeFrames := 1;

  { valley: reversal at Phase = LoopLen (forward pass hands off to backward) }
  if Abs(Phase - LoopLen) < FadeFrames then
  begin
    FadeT := (Phase - LoopLen + FadeFrames) / (2 * FadeFrames);
    PosA := LoopRegionEnd - Phase;
    PosB := LoopRegionStart + (Phase - LoopLen);
    Exit(PosA * (1 - FadeT) + PosB * FadeT);
  end;

  { peak: reversal at Phase = 0 / Period (backward pass hands off to forward) }
  DistToPeak := Phase;
  if Period - Phase < DistToPeak then
    DistToPeak := Period - Phase;
  if DistToPeak < FadeFrames then
  begin
    if Phase > Period - FadeFrames then
      SignedOffset := Phase - Period
    else
      SignedOffset := Phase;
    FadeT := (SignedOffset + FadeFrames) / (2 * FadeFrames);
    { both legs expressed around the peak itself: the pre-reversal
      (incoming, forward) leg is E + SignedOffset, the post-reversal
      (outgoing, backward) leg is E - SignedOffset. Building the incoming
      leg from the WRAPPED phase instead (the old
      LoopRegionStart + (Phase - LoopLen)) is a full Period short once
      Phase wraps past 0 - and at the very first entry into the ping-pong
      (Phase = 0, blend forced to its midpoint) it output the loop
      MIDPOINT instead of the grain end: a hard position jump of half the
      loop region at the tail of EVERY stretched grain. }
    PosB := LoopRegionEnd + SignedOffset;
    PosA := LoopRegionEnd - SignedOffset;
    Exit(PosB * (1 - FadeT) + PosA * FadeT);
  end;

  if Phase < LoopLen then
    Result := LoopRegionEnd - Phase
  else
    Result := LoopRegionStart + (Phase - LoopLen);
end;

const
  { Beats-mode grains are transient-bounded (or fixed-grid) SLICES of
    unrelated audio - unlike a ping-pong reversal, the position just before a
    grain boundary and the position just after it do NOT reference the same
    underlying audio, so blending POSITIONS there (as the reversal-smoothing
    above legitimately does) would produce a meaningless third position.
    This has to be a real sample-domain crossfade instead. }
  WarpGrainCrossfadeMs = 4;

{ Wraps ClipSourcePosition with the sample-domain crossfade described above:
  within the last WarpGrainCrossfadeMs of any grain's timeline allotment,
  blends the natural/ping-pong sample against a preview of the next grain's
  own natural start (walked backward from that start by exactly how far off
  the boundary we are, so it lands exactly on that start AT the boundary -
  i.e. continuous with what the next grain will read on its own from the very
  next frame). This is the actual audio-producing entry point; plain
  ClipSourcePosition stays available unchanged for non-audio callers (split
  points, anchors) that want the raw, un-blended position. }
function ClipSourceSample(Clip: PPlaybackClip; AClipRelativeFrame: Int64;
  AChannel: Integer): Single;
var
  PosA, PosB0, PosB, FadeT: Double;
  GrainEnd, FadeFrames, DistToEnd: Int64;
  SampleA, SampleB: Single;

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

begin
  if Clip^.MarkerCount < 2 then
    Exit(SafeInterp(AClipRelativeFrame));

  GrainEnd := -1;
  PosA := ClipSourcePosition(Clip, AClipRelativeFrame, @GrainEnd);
  SampleA := SafeInterp(PosA);

  FadeFrames := (WarpGrainCrossfadeMs * ProjectSampleRate) div 1000;
  if FadeFrames < 1 then
    FadeFrames := 1;

  DistToEnd := GrainEnd - AClipRelativeFrame;
  if (GrainEnd < 0) or (DistToEnd <= 0) or (DistToEnd > FadeFrames) or
    (GrainEnd >= Clip^.Length) then
    Exit(SampleA);

  PosB0 := ClipSourcePosition(Clip, GrainEnd);
  PosB := PosB0 - DistToEnd;
  SampleB := SafeInterp(PosB);

  FadeT := 1 - (DistToEnd / FadeFrames);
  Result := SampleA * (1 - FadeT) + SampleB * FadeT;
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
var
  i: Integer;
begin
  for i := 0 to GrainCacheSlots - 1 do
    GrainCache[i].Data := nil;
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
