unit Waveform;

{$mode objfpc}{$H+}

interface

uses
  SampleTypes, Resample, AVector;

const
  MaxWaveformBins = 4096;

type
  TWaveformPeaks = record
    Mins: array of Single;
    Maxs: array of Single;
  end;

function ComputeWaveformPeaks(const ASample: TSample): TWaveformPeaks;

{ Onset/transient detection, cached per-sample in Project.SampleTransients -
  see the implementation for the algorithm. Used to place Beats-mode grain
  boundaries on real attacks instead of an arbitrary fixed grid. }
function DetectTransients(AData: PSingle; AFrameCount, AChannels,
  ASampleRate: Integer): TFrameArray;

{ Dominant fundamental period of a sample, in frames, or 0 if none could be
  found. Cached per-sample at load time in Project.SamplePeriods, exactly like
  DetectTransients/SamplePeaks, and used only by the Tones ("LF") warp mode to
  place its grains on whole waveform periods. }
function DetectFundamentalPeriod(AData: PSingle; AFrameCount, AChannels,
  ASampleRate: Integer): Integer;

{ Nominal timeline -> source map for a warped clip, as a frame position
  relative to the clip's Offset. An empty/short AMarkers means unwarped 1:1.

  For AWarpMode = WarpModeRePitch this IS the playback position: the classic
  continuous vari-speed warp (same math as keyboard pitch-shifting), each
  segment resampling linearly across its whole span, so dragging a marker
  audibly stretches/compresses both neighbouring segments together.

  For Beats it is the nominal map ONLY. Beats playback does not read through
  a single position at all - it sums overlapping transient slices, see
  WarpedSourceSample - so this is for callers that need one answer per frame
  rather than audio: split points, marker placement, waveform drawing. It
  needs no sample data or transients, which is why it no longer takes them. }
{ AHintK (optional) is an in/out cursor into AMarkers holding the segment
  index the previous call landed on. Locating the segment is otherwise a
  linear walk restarted from marker 0 on EVERY call, which for a caller that
  sweeps monotonically forward (DrawWaveform, one or two calls per pixel
  column) makes drawing one warped clip O(columns x markers). Passing the
  same variable back in makes the whole sweep O(columns + markers).

  It is only ever an optimisation, never a behaviour change: the walk below
  moves forward only, so seeding it at any index at or before the correct
  one converges on the identical segment. Callers must therefore query in
  non-decreasing ATimelineFrame order (an out-of-order query is still safe
  - it is validated and reset - but gains nothing). }
function WarpedSourcePosition(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; ASampleRate: Integer = 44100;
  AWarpMode: Integer = WarpModeBeats; AHintK: PInteger = nil;
  const AZones: TDragZoneArray = nil): Double;

{ Drag ("D") mode's own nominal timeline -> source map, kept separate from
  WarpedSourcePosition above because a drag zone (source span + timeline
  shift) isn't representable as a TWarpMarker pair - there is no continuous
  rate to interpolate, playback inside a zone is a flat 1:1 offset and the
  gaps between zones are not "the warp", they are silence. AZones must be
  sorted ascending by rendered start and non-overlapping - see WarpEditor's
  overlap trim, which is what keeps that true.

  Returns the source frame (clip-relative, like WarpedSourcePosition) when
  ATimelineFrame falls inside a zone, or DragZoneSilence when it falls in a
  gap - callers (waveform drawing, DragZoneSourceSample) must check for that
  sentinel rather than treating it as a real position. }
const
  DragZoneSilence = -1;
function DragZoneSourcePosition(const AZones: TDragZoneArray;
  ATimelineFrame: Int64): Int64;

{ True if ATimelineFrame sits inside some zone's HOME span while that zone
  has actually moved elsewhere (Shift <> 0) - the gap it left behind. Used to
  tell that real silence apart from "no zone covers this frame, so it's just
  raw/unedited audio" wherever DragZoneSourcePosition/DragZoneSourceSample
  return their DragZoneSilence sentinel, since that sentinel alone no longer
  means silence - see DragZoneSourceSample. }
function DragFrameInVacatedHole(const AZones: TDragZoneArray; AFrame: Int64): Boolean;

{ The audio-producing warp entry point: Ableton-style Beats (a sum over the
  transient slices sounding at ATimelineFrame - see the implementation) or a
  straight read through the RePitch position map. This is the shared/offline
  copy of AudioEngine.BeatsClipSample, used by the render path so a bounce
  matches live playback. AOffset is the clip's source offset, same as
  DetunedSample. AClipLength is retained for signature compatibility with
  that caller and is not used. }
function WarpedSourceSample(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; AClipLength: Int64; AOffset: Int64; AData: PSingle;
  AFrameCount: Integer; AChannels: Integer; ASampleRate: Integer;
  AWarpMode: Integer; AChannel: Integer;
  const ATransients: TFrameArray = nil; APeriodFrames: Integer = 0;
  const AZones: TDragZoneArray = nil): Single;

{ Offline/shared copy of AudioEngine.DragClipSample - same zone lookup, same
  short fade of a zone's tail into the silence that follows it, so a bounce
  matches live Drag-mode playback exactly. }
function DragZoneSourceSample(const AZones: TDragZoneArray;
  ATimelineFrame: Int64; AOffset: Int64; AData: PSingle;
  AFrameCount: Integer; AChannels: Integer; ASampleRate: Integer;
  AChannel: Integer): Single;

{ Cuts a warp marker array in two at ASplitFrame (clip-relative timeline
  frame), for use whenever a clip itself is split or trimmed (explicit split,
  drag-resizing an edge, or one clip overwriting part of another). Without
  this, changing a clip's Offset/Length invalidates its markers' meaning and
  they'd have to be discarded - silently reverting the clip to unwarped 1:1
  and undoing any warp editing across the whole remainder of the clip.

  ALeftMarkers keeps everything before the cut plus a synthesized end marker
  exactly at it; ARightMarkers gets a synthesized (0,0) start marker plus
  everything after, rebased so index 0 lines up with the new clip's own
  Offset/Position. Either side collapses to unwarped (nil) if it would be
  left with fewer than 2 markers (e.g. the cut landed exactly on an existing
  marker) or the input wasn't warped to begin with.

  Returns the ACTUAL split frame used, which the caller must use for the
  clip's own Length/Offset/Position split too (instead of its original
  ASplitFrame) so the geometry and the markers stay consistent. It normally
  equals ASplitFrame, but a cut strictly inside a stretched (looped) segment
  gets pushed forward to that segment's own end: the loop-fill math is driven
  by the segment's full natural length, so truncating the segment for the
  right half would shrink that reference and reconstruct a different (wrong)
  loop - there's no marker pair that reproduces a partial loop exactly. This
  snap-forward only applies in Beats mode (and only pushes forward to the
  grain's own end, not the whole segment's, now that segments are subdivided
  into small grains); in RePitch mode a segment is a plain linear resample
  and can be split cleanly anywhere. }
{ ASplitSourceOut (optional) receives the SOURCE-domain frame of the cut -
  the source position the warp maps the returned (timeline) split frame to.
  Callers building the right half of a split/trim MUST advance the new
  clip's Offset by THIS value, not by the returned timeline frame: Offset
  is source-domain, and for any stretched/compressed clip (any clip after
  a tempo rescale) the two differ - using the timeline value shifts the
  right half's audio and breaks its (SplitSource-rebased) markers. }
function SplitWarpMarkers(const AMarkers: TWarpMarkerArray; ASplitFrame: Int64;
  out ALeftMarkers, ARightMarkers: TWarpMarkerArray;
  AWarpMode: Integer = WarpModeBeats; ASampleRate: Integer = 44100;
  ASplitSourceOut: PInt64 = nil): Int64;

{ Drag mode's own SplitWarpMarkers - same job (rebase a clip's warp state
  across a split/trim so it isn't silently discarded), same ASplitSourceOut
  contract, called from the exact same ArrangementView.pas sites right
  alongside SplitWarpMarkers. Not built on SplitWarpMarkers/TWarpMarkerArray
  though: a zone is always slope-1 (SourceEnd-SourceStart = REnd-RStart, no
  resampling - see TDragZone), so there is no segment/grain search to reuse
  from that machinery, only its REBASE IDIOM (subtract the split's source
  value from source-domain fields, subtract ASplitFrame from timeline-domain
  ones) - the same arithmetic SplitWarpMarkers itself does to build
  ARightMarkers, and the same one every ArrangementView call site already
  applies by hand to a split clip's Offset/Position.

  Unlike Beats, a Drag split never needs to snap forward - a zone has no
  loop fill to preserve - so the returned split frame always equals
  ASplitFrame exactly. ASplitSourceOut falls back to ASplitFrame itself (the
  same "unwarped 1:1" convention SplitWarpMarkers uses for an empty/short
  marker array) when the cut lands in a gap between zones, since silence has
  no source position of its own to report. }
function SplitDragZones(const AZones: TDragZoneArray; ASplitFrame: Int64;
  out ALeftZones, ARightZones: TDragZoneArray;
  ASplitSourceOut: PInt64 = nil): Int64;

{ Independent per-clip pitch trim (the "Detune" slider) layered on top of
  WarpedSourcePosition rather than inside it, so Beats/RePitch warping
  itself is completely untouched by this - see AudioEngine.DetunedClipSample
  (the realtime engine's own copy of the identical trick) for the full
  explanation, including why this returns an already-blended sample instead
  of a raw position (crossfades across each grain boundary to avoid a
  click, since an arbitrary pitch ratio generally can't land back exactly
  on the next grain's own start). Used by offline render
  (ProjectFile.RenderProjectToWav) so a bounce matches live playback. }
function DetunedSample(const AMarkers: TWarpMarkerArray; ATimelineFrame: Int64;
  ADetuneSemitones: Single; AOffset: Int64; AData: PSingle;
  AFrameCount, AChannels, ASampleRate: Integer; AWarpMode, AChannel: Integer;
  AClipLength: Int64 = -1; const ATransients: TFrameArray = nil;
  APeriodFrames: Integer = 0; const AZones: TDragZoneArray = nil): Single;

{ DrawWaveform moved to src/ui/WaveformDraw.pas - it was the sole reason this
  unit depended on Graphics, and src/ui is unreachable from Dysnomia's build
  (see tui.md, "Isolation"). Everything it needs (TWaveformPeaks,
  TWarpMarkerArray, TFrameArray, WarpedSourcePosition) is still exported from
  here. }

implementation

{ Simple broadband energy-flux onset detector: a block-averaged absolute-
  amplitude envelope, then peaks in its positive-only derivative ("flux")
  above a threshold, with a minimum spacing enforced so a single transient
  doesn't fire twice. This is a standard, well-established (if basic)
  onset-detection technique - not claiming to match Ableton's own (never
  published) algorithm, just landing grain boundaries on real attacks
  instead of an arbitrary fixed grid, which is the actual point.
  Frame 0 is always included as an implicit boundary. Computed once per
  sample at load time (like ComputeWaveformPeaks) and cached - see
  Project.SampleTransients. }
function DetectTransients(AData: PSingle; AFrameCount, AChannels,
  ASampleRate: Integer): TFrameArray;
const
  EnvelopeWindowMs = 5;
  MinSpacingMs = 40;
  FluxThresholdMultiplier = 1.5;
var
  EnvelopeWindow, MinSpacing, i, f, ch, j, BestBlock: Integer;
  Envelope, Flux: array of Single;
  Sum, MeanFlux: Double;
  Count, ResultCount, LastTransient, BlockEnd: Integer;
begin
  Result := nil;
  if (AData = nil) or (AFrameCount <= 0) then
    Exit;

  EnvelopeWindow := (EnvelopeWindowMs * ASampleRate) div 1000;
  if EnvelopeWindow < 1 then
    EnvelopeWindow := 1;
  MinSpacing := (MinSpacingMs * ASampleRate) div 1000;
  if MinSpacing < 1 then
    MinSpacing := 1;

  Count := (AFrameCount + EnvelopeWindow - 1) div EnvelopeWindow;
  if Count < 3 then
  begin
    SetLength(Result, 1);
    Result[0] := 0;
    Exit;
  end;

  SetLength(Envelope, Count);
  for i := 0 to Count - 1 do
  begin
    BlockEnd := (i + 1) * EnvelopeWindow;
    if BlockEnd > AFrameCount then
      BlockEnd := AFrameCount;
    Sum := 0;
    for f := i * EnvelopeWindow to BlockEnd - 1 do
      for ch := 0 to AChannels - 1 do
        Sum := Sum + Abs(AData[f * AChannels + ch]);
    Envelope[i] := Sum / ((BlockEnd - i * EnvelopeWindow) * AChannels);
  end;

  SetLength(Flux, Count);
  Flux[0] := 0;
  MeanFlux := 0;
  for i := 1 to Count - 1 do
  begin
    Flux[i] := Envelope[i] - Envelope[i - 1];
    if Flux[i] < 0 then
      Flux[i] := 0;
    MeanFlux := MeanFlux + Flux[i];
  end;
  MeanFlux := MeanFlux / Count;

  SetLength(Result, Count);
  Result[0] := 0;
  ResultCount := 1;
  LastTransient := 0;

  for i := 1 to Count - 2 do
    if (Flux[i] > MeanFlux * FluxThresholdMultiplier) and
      (Flux[i] >= Flux[i - 1]) and (Flux[i] >= Flux[i + 1]) and
      (i * EnvelopeWindow - LastTransient >= MinSpacing) then
    begin
      { the flux-peak block already CONTAINS the risen attack energy -
        marking the boundary there leaves the first few ms of the hit in
        the PREVIOUS grain, where Beats-mode loop/truncate can clip it or
        double it (an audible flam/stutter on every hit). Step back to the
        quietest of the few blocks just before the peak so the boundary
        sits in the pre-attack gap instead, like Ableton's own markers do.
        (LastTransient keeps tracking the peak, so MinSpacing still
        measures peak-to-peak; the refinement moves boundaries at most
        3 blocks, well under MinSpacing, preserving ascending order.) }
      BestBlock := i;
      j := i - 3;
      if j < 1 then
        j := 1;
      while j < i do
      begin
        if Envelope[j] < Envelope[BestBlock] then
          BestBlock := j;
        Inc(j);
      end;
      Result[ResultCount] := BestBlock * EnvelopeWindow;
      Inc(ResultCount);
      LastTransient := i * EnvelopeWindow;
    end;

  SetLength(Result, ResultCount);
end;

{ Normalised autocorrelation over the highest-energy window in the sample.

  Deliberately biased towards bass: the lag search runs from 1000 Hz down to
  20 Hz, and an octave error UPWARDS is harmless here (an integer multiple of
  the period is still a period, so grain placement stays phase-correct) while
  one downwards would not be - which is why plain autocorrelation, whose
  errors go upwards, is the right tool rather than something cleverer. }
function DetectFundamentalPeriod(AData: PSingle; AFrameCount, AChannels,
  ASampleRate: Integer): Integer;
const
  MinHz = 20;
  MaxHz = 1000;
  WindowFrames = 2048;
var
  MinLag, MaxLag, Lag, i, Need, Start, BestStart: Integer;
  ch: Integer;
  Mono: array of Single;
  MonoP: PSingle;
  Sum, E0, ELag, Score, BestScore, Rms, BestRms, v: Double;
begin
  Result := 0;
  if (AData = nil) or (AFrameCount <= 0) or (AChannels <= 0) then
    Exit;

  MinLag := ASampleRate div MaxHz;
  MaxLag := ASampleRate div MinHz;
  if MinLag < 2 then
    MinLag := 2;
  Need := WindowFrames + MaxLag;
  if AFrameCount < Need then
    Exit; { too short to judge a bass period from }

  { pick the loudest window - an 808's decay tail correlates poorly, its body
    correlates cleanly }
  BestStart := 0;
  BestRms := -1;
  Start := 0;
  while Start + Need <= AFrameCount do
  begin
    Rms := 0;
    i := Start;
    while i < Start + WindowFrames do
    begin
      v := AData[i * AChannels];
      Rms := Rms + v * v;
      Inc(i, 8); { every 8th frame is plenty to rank windows by energy }
    end;
    if Rms > BestRms then
    begin
      BestRms := Rms;
      BestStart := Start;
    end;
    Inc(Start, WindowFrames);
  end;
  if BestRms <= 0 then
    Exit;

  SetLength(Mono, Need);
  for i := 0 to Need - 1 do
  begin
    v := 0;
    for ch := 0 to AChannels - 1 do
      v := v + AData[(BestStart + i) * AChannels + ch];
    Mono[i] := v / AChannels;
  end;

  MonoP := @Mono[0];

  E0 := VDotSum(MonoP, MonoP, WindowFrames);
  if E0 <= 0 then
    Exit;

  { ELag is the energy of the window STARTING at Lag, so consecutive lags
    share all but one sample at each end of it:

      ELag(k+1) = ELag(k) - Mono[k]^2 + Mono[k + WindowFrames]^2

    Recomputing it from scratch per lag was half the total work of this
    function - MaxLag - MinLag is around 2350 lags at 48k, each summing 2048
    squares to get a number 2046 of whose terms it already had. Seeded once
    here for MinLag and slid at the top of the loop after that, which leaves
    one genuine reduction per lag instead of two.

    Both index reads stay in range: the update at lag k+1 reads Mono[k] and
    Mono[k + WindowFrames], and k tops out at MaxLag - 1, so the highest
    index touched is MaxLag - 1 + WindowFrames = Need - 1.

    Accumulated drift is the thing to check with a subtractive sliding sum,
    and it is nothing here: ELag is Double, the terms are bounded by 1, and
    2350 updates at 1e-16 relative each land around 1e-13 - against a
    BestScore gate of 0.6 and score gaps between competing lags in the 1e-3
    range. }
  ELag := VDotSum(MonoP + MinLag, MonoP + MinLag, WindowFrames);

  BestScore := 0;
  for Lag := MinLag to MaxLag do
  begin
    if Lag > MinLag then
      ELag := ELag - Sqr(Double(Mono[Lag - 1]))
        + Sqr(Double(Mono[Lag - 1 + WindowFrames]));
    { tested before the dot product rather than after it, as the original
      could not: a silent lag window now costs nothing instead of a full
      WindowFrames reduction whose result was thrown away }
    if ELag <= 0 then
      Continue;
    { one dot product over an 8KB window that is entirely L1-resident, so
      this is compute-bound rather than memory-bound and is the one place in
      this codebase where FMA3's two-per-cycle throughput fully lands }
    Sum := VDotSum(MonoP, MonoP + Lag, WindowFrames);
    { normalised, so a long lag isn't penalised purely for covering quieter
      audio - without this the search collapses onto MinLag every time }
    Score := Sum / Sqrt(E0 * ELag);
    if Score > BestScore then
    begin
      BestScore := Score;
      Result := Lag;
    end;
  end;

  { a weak best peak means this isn't periodic enough to treat as tonal -
    report nothing and let the caller fall back }
  if BestScore < 0.6 then
    Result := 0;
end;

function ComputeWaveformPeaks(const ASample: TSample): TWaveformPeaks;
var
  BinCount, i: Integer;
  FramesPerBin: Double;
  StartF, EndF: Integer;
  MinV, MaxV: Single;
begin
  BinCount := ASample.FrameCount;
  if BinCount > MaxWaveformBins then
    BinCount := MaxWaveformBins;
  if BinCount < 1 then
    BinCount := 1;

  SetLength(Result.Mins, BinCount);
  SetLength(Result.Maxs, BinCount);

  if (ASample.FrameCount <= 0) or (ASample.Data = nil) then
  begin
    for i := 0 to BinCount - 1 do
    begin
      Result.Mins[i] := 0;
      Result.Maxs[i] := 0;
    end;
    Exit;
  end;

  FramesPerBin := ASample.FrameCount / BinCount;

  for i := 0 to BinCount - 1 do
  begin
    StartF := Trunc(i * FramesPerBin);
    EndF := Trunc((i + 1) * FramesPerBin);
    if EndF <= StartF then
      EndF := StartF + 1;
    if EndF > ASample.FrameCount then
      EndF := ASample.FrameCount;

    { the nested f/ch loops this replaces walked
      Data[StartF*Channels .. EndF*Channels), one element at a time and in
      that exact order - the sample data is interleaved, so a bin is already
      a single contiguous run and there was never anything to gather.
      VMinMax is bit-identical to the loop it replaces, signed zeros and
      NaNs included; see its declaration for why that is exact rather than
      approximate. }
    VMinMax(@ASample.Data[StartF * ASample.Channels],
      (EndF - StartF) * ASample.Channels, MinV, MaxV);

    Result.Mins[i] := MinV;
    Result.Maxs[i] := MaxV;
  end;
end;

const
  { see the matching constants in AudioEngine - this unit is the offline/
    shared copy of the identical algorithm and must stay in step with it, or
    a bounce stops matching what was heard live }
  WarpGrainMs = 120;
  WarpSliceReleaseMs = 30;
  WarpSliceAttackFrames = 24;
  WarpReversalFadeMs = 3;
  WarpMaxOverlapSlices = 4;
  WarpRepitchFadeMs = 4;
  TonesMinNoteMs = 150;
  TonesReleaseMs = 120;
  TonesAttackFrames = 24;
  TonesMaxOnsetWalk = 64;

function WarpedSourcePosition(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; ASampleRate: Integer; AWarpMode: Integer;
  AHintK: PInteger; const AZones: TDragZoneArray): Double;
var
  k: Integer;
  SegStartTimeline, SegStartSource, SegTimelineLen, SegSourceLen: Int64;
  OffsetIntoSeg: Int64;
  RePitchFadeFrames, RePitchDistToEnd, NextSegSourceLen, NextSegTimelineLen: Int64;
  RePitchPosA, RePitchPosB, RePitchFadeT: Double;
  ZonePos: Int64;
begin
  { Drag has no markers - the zone lookup stands in for the marker walk
    below. A gap (no zone covers this frame) falls back to identity so a
    detune grain anchored here still lands somewhere sane rather than at
    the DragZoneSourceSample silence sentinel, which is only meaningful to
    that function's own caller, not to a generic position consumer. }
  if AWarpMode = WarpModeDrag then
  begin
    ZonePos := DragZoneSourcePosition(AZones, ATimelineFrame);
    if ZonePos = DragZoneSilence then
      Exit(ATimelineFrame);
    Exit(ZonePos);
  end;

  if Length(AMarkers) < 2 then
    Exit(ATimelineFrame);

  { seeded from the caller's cursor when it supplied one - see the header }
  k := 0;
  if AHintK <> nil then
  begin
    k := AHintK^;
    if (k < 0) or (k > Length(AMarkers) - 2) then
      k := 0;
  end;
  while (k < Length(AMarkers) - 2) and
    (ATimelineFrame >= AMarkers[k + 1].TimelineFrame) do
    Inc(k);
  if AHintK <> nil then
    AHintK^ := k;

  SegStartTimeline := AMarkers[k].TimelineFrame;
  SegStartSource := AMarkers[k].SourceFrame;
  SegTimelineLen := AMarkers[k + 1].TimelineFrame - SegStartTimeline;
  SegSourceLen := AMarkers[k + 1].SourceFrame - SegStartSource;
  OffsetIntoSeg := ATimelineFrame - SegStartTimeline;

  if AWarpMode = WarpModeRePitch then
  begin
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
    if k < Length(AMarkers) - 2 then
    begin
      RePitchFadeFrames := (WarpRepitchFadeMs * ASampleRate) div 1000;
      if RePitchFadeFrames > SegTimelineLen div 2 then
        RePitchFadeFrames := SegTimelineLen div 2;
      if RePitchFadeFrames < 1 then
        RePitchFadeFrames := 1;

      RePitchDistToEnd := SegTimelineLen - OffsetIntoSeg;
      if RePitchDistToEnd <= RePitchFadeFrames then
      begin
        NextSegSourceLen := AMarkers[k + 2].SourceFrame - AMarkers[k + 1].SourceFrame;
        NextSegTimelineLen := AMarkers[k + 2].TimelineFrame - AMarkers[k + 1].TimelineFrame;
        if NextSegTimelineLen > 0 then
        begin
          RePitchPosB := AMarkers[k + 1].SourceFrame +
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

function DragZoneSourcePosition(const AZones: TDragZoneArray;
  ATimelineFrame: Int64): Int64;
var
  z: Integer;
  RStart, REnd: Int64;
begin
  for z := 0 to High(AZones) do
  begin
    RStart := AZones[z].SourceStart + AZones[z].Shift;
    REnd := AZones[z].SourceEnd + AZones[z].Shift;
    if (ATimelineFrame >= RStart) and (ATimelineFrame < REnd) then
      Exit(AZones[z].SourceStart + (ATimelineFrame - RStart));
  end;
  Result := DragZoneSilence;
end;

{ mirrors AudioEngine.DragFrameInVacatedHole - true if AFrame sits in some
  zone's HOME span while that zone has actually moved elsewhere (Shift <> 0),
  i.e. the gap it left behind. A zone that never moved has no hole - its home
  is its rendered span, already covered by the caller's own zone scan. }
function DragFrameInVacatedHole(const AZones: TDragZoneArray; AFrame: Int64): Boolean;
var
  z: Integer;
begin
  Result := False;
  for z := 0 to High(AZones) do
  begin
    if AZones[z].Shift = 0 then
      Continue;
    if (AFrame >= AZones[z].SourceStart) and (AFrame < AZones[z].SourceEnd) then
      Exit(True);
  end;
end;

{ mirrors AudioEngine.DragClipSample - see that function for the rationale
  (1:1 playback inside a zone; frames outside every zone are raw/unedited
  audio, exactly as if unwarped, EXCEPT a moved zone's vacated home span,
  which is silence; tail-only crossfade into a genuine hole). Kept as a
  straight port rather than a shared helper because the two sides read from
  different data shapes (PSingle/FrameCount here vs a PPlaybackClip there)
  for the same reason every other mode's offline copy does. }
function DragZoneSourceSample(const AZones: TDragZoneArray;
  ATimelineFrame: Int64; AOffset: Int64; AData: PSingle;
  AFrameCount: Integer; AChannels: Integer; ASampleRate: Integer;
  AChannel: Integer): Single;
const
  DragFadeMs = 8;
var
  z: Integer;
  RStart, REnd, FadeFrames, DistToEnd, ZoneFadeCap: Int64;
  SrcFrame, AbsPos: Int64;
  Gain: Single;
begin
  FadeFrames := (DragFadeMs * ASampleRate) div 1000;
  for z := 0 to High(AZones) do
  begin
    RStart := AZones[z].SourceStart + AZones[z].Shift;
    REnd := AZones[z].SourceEnd + AZones[z].Shift;
    if (ATimelineFrame < RStart) or (ATimelineFrame >= REnd) then
      Continue;

    SrcFrame := AZones[z].SourceStart + (ATimelineFrame - RStart);
    AbsPos := AOffset + SrcFrame;
    if (AbsPos < 0) or (AbsPos >= AFrameCount) then
      Exit(0);

    Result := LinearInterpolate(AData, AFrameCount, AChannels, AChannel, AbsPos);

    ZoneFadeCap := FadeFrames;
    if REnd - RStart < ZoneFadeCap then
      ZoneFadeCap := REnd - RStart;
    DistToEnd := REnd - ATimelineFrame;
    if (DistToEnd < ZoneFadeCap) and DragFrameInVacatedHole(AZones, REnd) then
    begin
      Gain := DistToEnd / ZoneFadeCap;
      Result := Result * Gain;
    end;
    Exit;
  end;

  if DragFrameInVacatedHole(AZones, ATimelineFrame) then
    Exit(0);

  { raw/unedited background - plays the clip's own audio exactly as if it
    had no warp at all }
  AbsPos := AOffset + ATimelineFrame;
  if (AbsPos < 0) or (AbsPos >= AFrameCount) then
    Exit(0);
  Result := LinearInterpolate(AData, AFrameCount, AChannels, AChannel, AbsPos);
end;

{ Beats warp renderer - the offline/shared copy of AudioEngine.BeatsClipSample.
  See that function's header comment for the full rationale (why Beats is a sum
  over overlapping transient slices rather than a single read position, and why
  the zero-crossing snapping and grain cache the old implementation needed are
  both gone). This copy exists because the realtime side can only ever have a
  raw PInt64/Count pair for its transients, the lock-free-safe shape, while
  every other caller has a TFrameArray; the two must stay in step. }
{ Tones ("LF") renderer - the offline/shared copy of AudioEngine.
  TonesClipSample. See that function's header for why this places whole notes
  at 1:1 rather than granulating. }
function TonesSourceSample(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; AOffset: Int64; AData: PSingle;
  AFrameCount: Integer; AChannels: Integer; ASampleRate: Integer;
  AChannel: Integer; const ATransients: TFrameArray;
  APeriodFrames: Integer): Single;
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
    AbsPos := AOffset + APos;
    if (AbsPos < 0) or (AbsPos >= AFrameCount) then
      Result := 0
    else
      Result := LinearInterpolate(AData, AFrameCount, AChannels, AChannel, AbsPos);
  end;

  function TransAt(AIndex: Integer): Int64;
  begin
    Result := ATransients[AIndex] - AOffset;
  end;

  { same segment/transient-range setup as BeatsClipSample - see there }
  procedure LoadSegment(AK: Integer);
  var
    lo, hi, mid: Integer;
  begin
    SegStartTimeline := AMarkers[AK].TimelineFrame;
    SegStartSource := AMarkers[AK].SourceFrame;
    SegTimelineLen := AMarkers[AK + 1].TimelineFrame - SegStartTimeline;
    SegSourceLen := AMarkers[AK + 1].SourceFrame - SegStartSource;
    SegEnd := SegStartSource + SegSourceLen;

    FirstTrans := 0;
    TransInSeg := 0;
    if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
      Exit;
    if Length(ATransients) = 0 then
      Exit;

    lo := 0;
    hi := Length(ATransients);
    while lo < hi do
    begin
      mid := lo + (hi - lo) div 2;
      if TransAt(mid) <= SegStartSource then
        lo := mid + 1
      else
        hi := mid;
    end;
    FirstTrans := lo;

    hi := Length(ATransients);
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

  { one note's enveloped output at ATimelineFrame, or 0 if it isn't (or is
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

    t := ATimelineFrame - TL;
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
  if Length(AMarkers) < 2 then
    Exit(SafeInterp(ATimelineFrame));

  k := 0;
  while (k < Length(AMarkers) - 2) and
    (ATimelineFrame >= AMarkers[k + 1].TimelineFrame) do
    Inc(k);

  LoadSegment(k);
  if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
    Exit(SafeInterp(SegStartSource));

  MinNote := (TonesMinNoteMs * ASampleRate) div 1000;
  ReleaseMax := (TonesReleaseMs * ASampleRate) div 1000;
  P := APeriodFrames;

  NominalSrc := SegStartSource +
    ((ATimelineFrame - SegStartTimeline) * SegSourceLen) div SegTimelineLen;
  NoteBounds(NominalSrc, CurLo, CurHi);

  { the seed came from the nominal source position, so correct it against the
    real timeline bounds the renderer itself uses - 0 or 1 steps in practice }
  Guard := 0;
  while (CurLo > SegStartSource) and (ATimelineFrame < TimelineOf(CurLo)) and
    (Guard < TonesMaxOnsetWalk) do
  begin
    NoteBounds(CurLo - 1, CurLo, CurHi);
    Inc(Guard);
  end;
  while (CurHi < SegEnd) and (ATimelineFrame >= TimelineOf(CurHi)) and
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

const
  { see AudioEngine.AudioAnchorFadeFrames }
  AudioAnchorFadeFrames = 64;

{ Audio ("AU") renderer - the offline/shared copy of
  AudioEngine.AudioClipSample. See that function's header for why the stretch
  is paid for at sparse splices rather than by a continuous overlap, and why
  that is what separates this from the period snapping TonesClipSample's
  header rejects. }
function AudioSourceSample(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; AClipLength: Int64; AOffset: Int64; AData: PSingle;
  AFrameCount: Integer; AChannels: Integer; ASampleRate: Integer;
  AChannel: Integer; const ATransients: TFrameArray;
  APeriodFrames: Integer): Single;
var
  k: Integer;
  SegStartTimeline, SegStartSource, SegTimelineLen, SegSourceLen, SegEnd: Int64;
  FirstTrans, TransInSeg: Integer;
  P, NominalSrc: Int64;
  CurIdx, CurSrc, CurTL, PrevSrc, t: Int64;
  CurVal, PrevVal, w: Double;
  HavePrev: Boolean;

  function SafeInterp(APos: Double): Single;
  var
    AbsPos: Double;
  begin
    AbsPos := AOffset + APos;
    if (AbsPos < 0) or (AbsPos >= AFrameCount) then
      Result := 0
    else
      Result := LinearInterpolate(AData, AFrameCount, AChannels, AChannel, AbsPos);
  end;

  function TransAt(AIndex: Integer): Int64;
  begin
    Result := ATransients[AIndex] - AOffset;
  end;

  { same segment/transient-range setup as TonesSourceSample - see there }
  procedure LoadSegment(AK: Integer);
  var
    lo, hi, mid: Integer;
  begin
    SegStartTimeline := AMarkers[AK].TimelineFrame;
    SegStartSource := AMarkers[AK].SourceFrame;
    SegTimelineLen := AMarkers[AK + 1].TimelineFrame - SegStartTimeline;
    SegSourceLen := AMarkers[AK + 1].SourceFrame - SegStartSource;
    SegEnd := SegStartSource + SegSourceLen;

    FirstTrans := 0;
    TransInSeg := 0;
    if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
      Exit;
    if Length(ATransients) = 0 then
      Exit;

    lo := 0;
    hi := Length(ATransients);
    while lo < hi do
    begin
      mid := lo + (hi - lo) div 2;
      if TransAt(mid) <= SegStartSource then
        lo := mid + 1
      else
        hi := mid;
    end;
    FirstTrans := lo;

    hi := Length(ATransients);
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

  function AnchorLo(AIndex: Int64): Int64;
  begin
    if (AIndex <= 0) or (TransInSeg <= 0) then
      Exit(SegStartSource);
    if AIndex > TransInSeg then
      AIndex := TransInSeg;
    Result := TransAt(FirstTrans + AIndex - 1);
  end;

  function FindAnchor: Int64;
  var
    lo, hi, mid: Int64;
  begin
    if TransInSeg <= 0 then
      Exit(0);

    lo := 0;
    hi := TransInSeg;
    while lo < hi do
    begin
      mid := lo + (hi - lo + 1) div 2;
      if AnchorLo(mid) <= NominalSrc then
        lo := mid
      else
        hi := mid - 1;
    end;
    Result := lo;

    while (Result > 0) and (ATimelineFrame < TimelineOf(AnchorLo(Result))) do
      Dec(Result);
    while (Result < TransInSeg) and
      (ATimelineFrame >= TimelineOf(AnchorLo(Result + 1))) do
      Inc(Result);
  end;

  function RegionSample(AAnchorSrc, AAnchorTL: Int64): Single;
  var
    u, Num, k0, kNb: Int64;
    StepSigned, Step, z, zf, dLow, dHigh, dNear, Fade, w: Double;
  begin
    u := ATimelineFrame - AAnchorTL;
    if u < 0 then
      u := 0;

    Num := SegTimelineLen - SegSourceLen;
    if Num = 0 then
      Exit(SafeInterp(AAnchorSrc + u));

    StepSigned := (Double(SegTimelineLen) * P) / Num;
    Step := Abs(StepSigned);
    if Step < 1 then
      Exit(SafeInterp(AAnchorSrc + u));

    z := u / StepSigned;
    zf := z + 0.5;
    k0 := Trunc(zf);
    if (zf < 0) and (zf <> k0) then
      Dec(k0);

    dLow := Abs(u - (k0 - 0.5) * StepSigned);
    dHigh := Abs(u - (k0 + 0.5) * StepSigned);
    if dLow <= dHigh then
    begin
      dNear := dLow;
      kNb := k0 - 1;
    end
    else
    begin
      dNear := dHigh;
      kNb := k0 + 1;
    end;

    Fade := P;
    if Fade > Step * 0.5 then
      Fade := Step * 0.5;
    if Fade < 1 then
      Fade := 1;

    if dNear >= Fade * 0.5 then
      Exit(SafeInterp(AAnchorSrc + u - k0 * P));

    w := 0.5 + dNear / Fade;
    w := w * w * (3 - 2 * w);
    Result := SafeInterp(AAnchorSrc + u - k0 * P) * w +
      SafeInterp(AAnchorSrc + u - kNb * P) * (1 - w);
  end;

begin
  if Length(AMarkers) < 2 then
    Exit(SafeInterp(ATimelineFrame));

  P := APeriodFrames;
  if P < 1 then
    { no usable fundamental - hand off to Beats rather than granulate on a
      guessed period. Passing WarpModeBeats explicitly, not AWarpMode, or
      this recurses. }
    Exit(WarpedSourceSample(AMarkers, ATimelineFrame, AClipLength, AOffset,
      AData, AFrameCount, AChannels, ASampleRate, WarpModeBeats, AChannel,
      ATransients, APeriodFrames));

  k := 0;
  while (k < Length(AMarkers) - 2) and
    (ATimelineFrame >= AMarkers[k + 1].TimelineFrame) do
    Inc(k);

  LoadSegment(k);
  if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
    Exit(SafeInterp(SegStartSource));

  NominalSrc := SegStartSource +
    ((ATimelineFrame - SegStartTimeline) * SegSourceLen) div SegTimelineLen;

  CurIdx := FindAnchor;
  CurSrc := AnchorLo(CurIdx);
  CurTL := TimelineOf(CurSrc);
  t := ATimelineFrame - CurTL;

  HavePrev := False;
  PrevVal := 0;
  if (t >= 0) and (t < AudioAnchorFadeFrames) then
  begin
    if CurIdx > 0 then
    begin
      PrevSrc := AnchorLo(CurIdx - 1);
      PrevVal := RegionSample(PrevSrc, TimelineOf(PrevSrc));
      HavePrev := True;
    end
    else if k > 0 then
    begin
      LoadSegment(k - 1);
      if (SegTimelineLen > 0) and (SegSourceLen > 0) then
      begin
        PrevSrc := AnchorLo(TransInSeg);
        PrevVal := RegionSample(PrevSrc, TimelineOf(PrevSrc));
        HavePrev := True;
      end;
      LoadSegment(k);
    end;
  end;

  CurVal := RegionSample(CurSrc, CurTL);

  if HavePrev then
  begin
    w := t / AudioAnchorFadeFrames;
    Result := PrevVal * (1 - w) + CurVal * w;
  end
  else
    Result := CurVal;
end;

function WarpedSourceSample(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; AClipLength: Int64; AOffset: Int64; AData: PSingle;
  AFrameCount: Integer; AChannels: Integer; ASampleRate: Integer;
  AWarpMode: Integer; AChannel: Integer;
  const ATransients: TFrameArray; APeriodFrames: Integer;
  const AZones: TDragZoneArray): Single;
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
    AbsPos := AOffset + APos;
    if (AbsPos < 0) or (AbsPos >= AFrameCount) then
      Result := 0
    else
      Result := LinearInterpolate(AData, AFrameCount, AChannels, AChannel, AbsPos);
  end;

  procedure LoadSegment(AK: Integer);
  var
    lo, hi, mid: Integer;
    SegEnd: Int64;
  begin
    SegStartTimeline := AMarkers[AK].TimelineFrame;
    SegStartSource := AMarkers[AK].SourceFrame;
    SegTimelineLen := AMarkers[AK + 1].TimelineFrame - SegStartTimeline;
    SegSourceLen := AMarkers[AK + 1].SourceFrame - SegStartSource;
    SegEnd := SegStartSource + SegSourceLen;

    FirstTrans := 0;
    TransInSeg := 0;
    GridLen := 0;
    SliceCount := 1;
    if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
      Exit;

    { ATransients holds ABSOLUTE positions within the whole sample file while
      SegStartSource is CLIP-relative - hence the -AOffset on every comparison,
      exactly as in AudioEngine's copy. }
    if Length(ATransients) > 0 then
    begin
      lo := 0;
      hi := Length(ATransients);
      while lo < hi do
      begin
        mid := lo + (hi - lo) div 2;
        if ATransients[mid] - AOffset <= SegStartSource then
          lo := mid + 1
        else
          hi := mid;
      end;
      FirstTrans := lo;

      hi := Length(ATransients);
      while lo < hi do
      begin
        mid := lo + (hi - lo) div 2;
        if ATransients[mid] - AOffset < SegEnd then
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
      GridLen := (WarpGrainMs * ASampleRate) div 1000;
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

  function SliceLo(AIndex: Int64): Int64;
  begin
    if AIndex <= 0 then
      Exit(SegStartSource);
    if AIndex >= SliceCount then
      Exit(SegStartSource + SegSourceLen);
    if TransInSeg > 0 then
      Result := ATransients[FirstTrans + AIndex - 1] - AOffset
    else
      Result := SegStartSource + AIndex * GridLen;
  end;

  function TimelineOf(ASource: Int64): Int64;
  begin
    Result := SegStartTimeline +
      ((ASource - SegStartSource) * SegTimelineLen) div SegSourceLen;
  end;

  function FindSlice: Int64;
  var
    NominalSrc, lo, hi, mid: Int64;
  begin
    NominalSrc := SegStartSource +
      ((ATimelineFrame - SegStartTimeline) * SegSourceLen) div SegTimelineLen;

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

    while (Result > 0) and (ATimelineFrame < TimelineOf(SliceLo(Result))) do
      Dec(Result);
    while (Result < SliceCount - 1) and
      (ATimelineFrame >= TimelineOf(SliceLo(Result + 1))) do
      Inc(Result);
  end;

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

    t := ATimelineFrame - TL;
    if t < 0 then
      Exit;

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
    if (Release > 0) and (t >= TLen) then
      Gain := Gain * (1 - (t - TLen) / Release);

    if t < Natural then
    begin
      Result := SafeInterp(Lo + t) * Gain;
      Exit;
    end;

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
  if AWarpMode = WarpModeDrag then
    Exit(DragZoneSourceSample(AZones, ATimelineFrame, AOffset, AData,
      AFrameCount, AChannels, ASampleRate, AChannel));

  if Length(AMarkers) < 2 then
    Exit(SafeInterp(ATimelineFrame));

  if AWarpMode = WarpModeAudio then
    Exit(AudioSourceSample(AMarkers, ATimelineFrame, AClipLength, AOffset, AData,
      AFrameCount, AChannels, ASampleRate, AChannel, ATransients, APeriodFrames));

  if AWarpMode = WarpModeTones then
    Exit(TonesSourceSample(AMarkers, ATimelineFrame, AOffset, AData, AFrameCount,
      AChannels, ASampleRate, AChannel, ATransients, APeriodFrames));

  if AWarpMode = WarpModeRePitch then
    Exit(SafeInterp(WarpedSourcePosition(AMarkers, ATimelineFrame, ASampleRate,
      AWarpMode)));

  k := 0;
  while (k < Length(AMarkers) - 2) and
    (ATimelineFrame >= AMarkers[k + 1].TimelineFrame) do
    Inc(k);

  LoadSegment(k);
  if (SegTimelineLen <= 0) or (SegSourceLen <= 0) then
    Exit(SafeInterp(SegStartSource));

  ReleaseMax := (WarpSliceReleaseMs * ASampleRate) div 1000;
  if ReleaseMax < 1 then
    ReleaseMax := 1;
  ReversalFade := (WarpReversalFadeMs * ASampleRate) div 1000;
  if ReversalFade < 1 then
    ReversalFade := 1;

  CurSlice := FindSlice;

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

    if ATimelineFrame >= TimelineOf(SliceLo(i + 1)) + ReleaseMax then
      Break;
  end;

  Result := Acc;
end;

{ Forward-drift/re-anchor granular pitch trim - see AudioEngine.
  DetunedClipSample (the realtime copy of the identical algorithm) for the
  full rationale, including why the read drifts FORWARD past the grain's
  natural span instead of ping-ponging inside it (the ping-pong played
  reversed audio for the tail of every grain at any Rate > 1 - audible as
  constant gritty distortion on any detuned clip). }
function DetunedSample(const AMarkers: TWarpMarkerArray; ATimelineFrame: Int64;
  ADetuneSemitones: Single; AOffset: Int64; AData: PSingle;
  AFrameCount, AChannels, ASampleRate: Integer; AWarpMode, AChannel: Integer;
  AClipLength: Int64; const ATransients: TFrameArray;
  APeriodFrames: Integer; const AZones: TDragZoneArray): Single;
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
    AbsPos := AOffset + ARelPos;
    if (AbsPos < 0) or (AbsPos >= AFrameCount) then
      Result := 0
    else
      Result := LinearInterpolate(AData, AFrameCount, AChannels, AChannel, AbsPos);
  end;

begin
  if ADetuneSemitones = 0 then
    Exit(WarpedSourceSample(AMarkers, ATimelineFrame, AClipLength, AOffset,
      AData, AFrameCount, AChannels, ASampleRate, AWarpMode, AChannel,
      ATransients, APeriodFrames, AZones));

  Rate := Exp((ADetuneSemitones / 12) * Ln(2));
  GrainFrames := (DetuneGrainMs * ASampleRate) div 1000;
  if GrainFrames < 1 then
    GrainFrames := 1;
  Overlap := GrainFrames div 4;
  if Overlap < 1 then
    Overlap := 1;

  GrainIndex := ATimelineFrame div GrainFrames;
  GrainStartTimeline := GrainIndex * GrainFrames;
  GrainOffsetIntoGrain := ATimelineFrame - GrainStartTimeline;

  { anchors use the raw position lookup WITH transients, matching the
    realtime copy (AudioEngine.DetunedClipSample anchors to the same nominal
    map), so a bounce's detune grains land exactly where live playback's do }
  AnchorStart := WarpedSourcePosition(AMarkers, GrainStartTimeline,
    ASampleRate, AWarpMode, nil, AZones);

  PosCurrent := AnchorStart + GrainOffsetIntoGrain * Rate;
  SampleCurrent := SafeInterp(PosCurrent);

  if GrainOffsetIntoGrain < GrainFrames - Overlap then
    Exit(SampleCurrent);

  { last Overlap frames of this grain - blend towards the next grain, whose
    own local offset starts a bit negative here, i.e. it's already "running"
    underneath the tail of this one and lands exactly on its own anchor at
    the boundary }
  AnchorEnd := WarpedSourcePosition(AMarkers, GrainStartTimeline + GrainFrames,
    ASampleRate, AWarpMode, nil, AZones);
  PosNext := AnchorEnd + (GrainOffsetIntoGrain - GrainFrames) * Rate;
  SampleNext := SafeInterp(PosNext);

  FadeT := (GrainOffsetIntoGrain - (GrainFrames - Overlap)) / Overlap;
  Result := SampleCurrent * (1 - FadeT) + SampleNext * FadeT;
end;

function SplitWarpMarkers(const AMarkers: TWarpMarkerArray; ASplitFrame: Int64;
  out ALeftMarkers, ARightMarkers: TWarpMarkerArray; AWarpMode: Integer;
  ASampleRate: Integer; ASplitSourceOut: PInt64): Int64;
var
  i, cnt, k: Integer;
  SplitSource: Int64;
  SegStartTimeline, SegSourceLen, SegTimelineLen, OffsetIntoSeg: Int64;
  GrainSourceLen, GrainCount, GrainIndex, GrainStartTimeline, GrainOffsetIntoGrain: Int64;
  GrainTimelineLenF: Double;
begin
  ALeftMarkers := nil;
  ARightMarkers := nil;
  if Length(AMarkers) < 2 then
  begin
    { unwarped already - nothing to preserve; 1:1 playback means the source
      cut is the same frame as the timeline cut }
    if ASplitSourceOut <> nil then
      ASplitSourceOut^ := ASplitFrame;
    Exit(ASplitFrame);
  end;

  if ASplitFrame < AMarkers[0].TimelineFrame + 1 then
    ASplitFrame := AMarkers[0].TimelineFrame + 1;
  if ASplitFrame > AMarkers[High(AMarkers)].TimelineFrame then
    ASplitFrame := AMarkers[High(AMarkers)].TimelineFrame;

  k := 0;
  while (k < Length(AMarkers) - 2) and (ASplitFrame >= AMarkers[k + 1].TimelineFrame) do
    Inc(k);
  SegStartTimeline := AMarkers[k].TimelineFrame;
  SegTimelineLen := AMarkers[k + 1].TimelineFrame - SegStartTimeline;
  SegSourceLen := AMarkers[k + 1].SourceFrame - AMarkers[k].SourceFrame;
  OffsetIntoSeg := ASplitFrame - SegStartTimeline;

  if (AWarpMode = WarpModeBeats) and (OffsetIntoSeg > 0) and
    (OffsetIntoSeg < SegTimelineLen) and (SegTimelineLen > SegSourceLen) and
    (SegSourceLen > 0) then
  begin
    { a cut strictly inside a stretched slice's ping-pong fill can't be
      represented by simply rebasing markers there: the fill is driven by that
      slice's own natural length, and truncating it for the right half would
      reconstruct a different (wrong) loop. Snap forward to that slice's end
      instead - a much smaller nudge than snapping to the whole segment's.

      This walks a FIXED GRID rather than the transient-bounded slices
      WarpedSourceSample actually plays, because callers don't hand this
      function a transient array; it was already an approximation before the
      slice rework and stays one. The consequence is only that a split inside
      a stretched segment can land up to one slice away from where it would
      ideally snap - never a wrong split, just a slightly coarser one. }
    GrainSourceLen := (WarpGrainMs * ASampleRate) div 1000;
    if GrainSourceLen > SegSourceLen then
      GrainSourceLen := SegSourceLen;
    if GrainSourceLen < 1 then
      GrainSourceLen := 1;
    GrainCount := SegSourceLen div GrainSourceLen;
    if GrainCount < 1 then
      GrainCount := 1;
    GrainSourceLen := SegSourceLen div GrainCount;

    GrainTimelineLenF := SegTimelineLen / GrainCount;
    GrainIndex := Trunc(OffsetIntoSeg / GrainTimelineLenF);
    if GrainIndex >= GrainCount then
      GrainIndex := GrainCount - 1;
    GrainStartTimeline := Trunc(GrainIndex * GrainTimelineLenF);
    GrainOffsetIntoGrain := OffsetIntoSeg - GrainStartTimeline;

    if GrainOffsetIntoGrain >= GrainSourceLen then
    begin
      ASplitFrame := SegStartTimeline + Trunc((GrainIndex + 1) * GrainTimelineLenF);
      if ASplitFrame > AMarkers[k + 1].TimelineFrame then
        ASplitFrame := AMarkers[k + 1].TimelineFrame;
    end;
  end;

  Result := ASplitFrame;

  { querying WarpedSourcePosition exactly at the array's final TimelineFrame
    is out of its intended domain (valid queries only go up to Length-1) -
    use the marker's own endpoint directly instead }
  if ASplitFrame >= AMarkers[High(AMarkers)].TimelineFrame then
    SplitSource := AMarkers[High(AMarkers)].SourceFrame
  else
    SplitSource := Round(WarpedSourcePosition(AMarkers, ASplitFrame,
      ASampleRate, AWarpMode));

  if ASplitSourceOut <> nil then
    ASplitSourceOut^ := SplitSource;

  cnt := 0;
  for i := 0 to High(AMarkers) do
    if AMarkers[i].TimelineFrame < ASplitFrame then
      Inc(cnt);
  SetLength(ALeftMarkers, cnt + 1);
  cnt := 0;
  for i := 0 to High(AMarkers) do
    if AMarkers[i].TimelineFrame < ASplitFrame then
    begin
      ALeftMarkers[cnt] := AMarkers[i];
      Inc(cnt);
    end;
  ALeftMarkers[cnt].TimelineFrame := ASplitFrame;
  ALeftMarkers[cnt].SourceFrame := SplitSource;

  cnt := 0;
  for i := 0 to High(AMarkers) do
    if AMarkers[i].TimelineFrame > ASplitFrame then
      Inc(cnt);
  SetLength(ARightMarkers, cnt + 1);
  ARightMarkers[0].TimelineFrame := 0;
  ARightMarkers[0].SourceFrame := 0;
  cnt := 1;
  for i := 0 to High(AMarkers) do
    if AMarkers[i].TimelineFrame > ASplitFrame then
    begin
      ARightMarkers[cnt].TimelineFrame := AMarkers[i].TimelineFrame - ASplitFrame;
      ARightMarkers[cnt].SourceFrame := AMarkers[i].SourceFrame - SplitSource;
      Inc(cnt);
    end;

  { a cut landing exactly on an existing marker leaves that side with just
    the single synthesized boundary marker - collapse to unwarped instead of
    keeping a degenerate 1-marker array }
  if Length(ALeftMarkers) < 2 then
    ALeftMarkers := nil;
  if Length(ARightMarkers) < 2 then
    ARightMarkers := nil;
end;

function SplitDragZones(const AZones: TDragZoneArray; ASplitFrame: Int64;
  out ALeftZones, ARightZones: TDragZoneArray;
  ASplitSourceOut: PInt64): Int64;
var
  i, LCount, RCount: Integer;
  RStart, REnd, SplitSource, ShiftDelta: Int64;
  L, R: TDragZoneArray;
begin
  Result := ASplitFrame;

  SplitSource := DragZoneSourcePosition(AZones, ASplitFrame);
  if SplitSource = DragZoneSilence then
    SplitSource := ASplitFrame; { gap - same "unwarped 1:1" fallback as SplitWarpMarkers uses for an empty marker array }
  if ASplitSourceOut <> nil then
    ASplitSourceOut^ := SplitSource;

  { the uniform correction every RIGHT-side zone's Shift needs, for exactly
    the reason SplitWarpMarkers' ARightMarkers rebase (TimelineFrame -
    ASplitFrame, SourceFrame - SplitSource) needs two different subtractions
    rather than one: Offset (source-domain) and Position (timeline-domain)
    advance by different amounts whenever the split doesn't land in a gap,
    and Shift = renderedTimeline - source has to absorb that difference to
    keep each zone's RENDERED position unchanged by the rebase itself. }
  ShiftDelta := SplitSource - ASplitFrame;

  SetLength(L, Length(AZones));
  SetLength(R, Length(AZones));
  LCount := 0;
  RCount := 0;

  for i := 0 to High(AZones) do
  begin
    RStart := AZones[i].SourceStart + AZones[i].Shift;
    REnd := AZones[i].SourceEnd + AZones[i].Shift;

    if REnd <= ASplitFrame then
    begin
      { entirely left of the cut - this clip's Offset/Position aren't
        changing, so the zone needs no rebasing at all }
      L[LCount] := AZones[i];
      Inc(LCount);
      Continue;
    end;

    if RStart >= ASplitFrame then
    begin
      { entirely right - same rebase SplitWarpMarkers applies to a whole
        marker, just carried through Shift instead of a single TimelineFrame
        field }
      R[RCount].SourceStart := AZones[i].SourceStart - SplitSource;
      R[RCount].SourceEnd := AZones[i].SourceEnd - SplitSource;
      R[RCount].Shift := AZones[i].Shift + ShiftDelta;
      Inc(RCount);
      Continue;
    end;

    { straddles the cut - truncate a copy for each side. The left half keeps
      its own Shift (nothing about its rendered position changes); the right
      half becomes a fresh, unshifted zone starting exactly at the split's
      own source position, which is what SplitSource already is when the cut
      lands inside this very zone (1:1 playback, so "source position at the
      cut" and "this zone's own rebase point" are the same number) }
    L[LCount] := AZones[i];
    L[LCount].SourceEnd := ASplitFrame - AZones[i].Shift;
    Inc(LCount);

    R[RCount].SourceStart := 0;
    R[RCount].SourceEnd := AZones[i].SourceEnd - SplitSource;
    R[RCount].Shift := 0;
    Inc(RCount);
  end;

  SetLength(L, LCount);
  SetLength(R, RCount);
  ALeftZones := L;
  ARightZones := R;
end;

end.
