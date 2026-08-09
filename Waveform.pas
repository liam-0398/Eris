unit Waveform;

{$mode objfpc}{$H+}

interface

uses
  Graphics, Types, SampleTypes, Resample;

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

{ Clip-warp segment lookup shared by every warp-aware consumer (the realtime
  engine keeps its own fixed-size copy of this same math for lock-free
  safety - see AudioEngine.ClipSourcePosition). Returns a frame position
  relative to the clip's Offset; an empty/short AMarkers means unwarped 1:1
  playback.

  Each marker-to-marker segment is subdivided into small grains (roughly
  WarpGrainMs each, approximating transient-bounded slices) that all play
  back at 1:1 (pitch untouched): a grain that needs more time than it
  naturally has plays forward to its end, then ping-pongs (back-and-forth)
  near its own midpoint to fill the rest, matching Ableton's "Beats" mode
  "Loop Back-and-Forth" transient loop - a grain that needs less time just
  gets cut short. This is a world apart from a continuous vari-speed/Re-Pitch
  resample across the whole segment - nudging one marker only affects the
  one adjusted segment's grains, not the whole clip's pitch.

  AData/AFrameCount/AChannels are optional: when supplied, loop and
  truncation cut points are snapped to nearby zero crossings to avoid
  clicking. Callers that only need this for on-screen drawing (no click risk)
  can omit them.

  AWarpMode = WarpModeRePitch switches to the classic continuous vari-speed
  warp instead (same math as keyboard pitch-shifting): each segment resamples
  linearly across its whole span, so dragging a marker audibly
  stretches/compresses both neighboring segments together. }
function WarpedSourcePosition(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; AData: PSingle = nil; AFrameCount: Integer = 0;
  AChannels: Integer = 0; ASampleRate: Integer = 44100;
  AWarpMode: Integer = WarpModeBeats;
  const ATransients: TFrameArray = nil; AGrainEnd: PInt64 = nil;
  AOffset: Int64 = 0): Double;

{ Sample-domain crossfade wrapper around WarpedSourcePosition - see
  AudioEngine.ClipSourceSample for the full rationale (this is the
  shared/offline-safe copy of the same algorithm). AClipLength is the clip's
  own total timeline length (frames), used to avoid crossfading past the
  clip's own end; AOffset is the clip's source offset, same as DetunedSample. }
function WarpedSourceSample(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; AClipLength: Int64; AOffset: Int64; AData: PSingle;
  AFrameCount: Integer; AChannels: Integer; ASampleRate: Integer;
  AWarpMode: Integer; AChannel: Integer;
  const ATransients: TFrameArray = nil): Single;

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
  AClipLength: Int64 = -1; const ATransients: TFrameArray = nil): Single;

{ Draws the waveform for [AStartFrame, AEndFrame) of a sample (out of
  ATotalFrameCount frames covered by APeaks) into ARect. When AMarkers has
  fewer than 2 entries this is a plain linear stretch; otherwise each pixel
  column is mapped through the warp before looking up its peak bin, so the
  drawn waveform visually stretches/compresses exactly like the audio does. }
procedure DrawWaveform(ACanvas: TCanvas; const ARect: TRect;
  const APeaks: TWaveformPeaks; ATotalFrameCount, AStartFrame, AEndFrame: Int64;
  const AMarkers: TWarpMarkerArray; AColor: TColor; AWarpMode: Integer = WarpModeBeats;
  const ATransients: TFrameArray = nil);

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

function ComputeWaveformPeaks(const ASample: TSample): TWaveformPeaks;
var
  BinCount, i, f, ch: Integer;
  FramesPerBin: Double;
  StartF, EndF: Integer;
  MinV, MaxV, V: Single;
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

    MinV := ASample.Data[StartF * ASample.Channels];
    MaxV := MinV;
    for f := StartF to EndF - 1 do
      for ch := 0 to ASample.Channels - 1 do
      begin
        V := ASample.Data[f * ASample.Channels + ch];
        if V < MinV then MinV := V;
        if V > MaxV then MaxV := V;
      end;

    Result.Mins[i] := MinV;
    Result.Maxs[i] := MaxV;
  end;
end;

const
  WarpGrainMs = 120;
  WarpZeroCrossSearchFrames = 32;
  WarpReversalFadeMs = 4;
  { width of the position blend applied before each RePitch-mode marker, to
    absorb the rate kink between two segments - see WarpedSourcePosition }
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

function WarpedSourcePosition(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; AData: PSingle; AFrameCount: Integer;
  AChannels: Integer; ASampleRate: Integer; AWarpMode: Integer;
  const ATransients: TFrameArray; AGrainEnd: PInt64; AOffset: Int64): Double;
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

  { Looks up the transient-bounded grain (SourceFrame span between two
    detected onsets, or between a segment edge and the nearest onset) that
    OffsetIntoSeg falls into, scaling each grain's natural source length by
    the segment's overall stretch ratio to get its timeline span. Returns
    False (leaving the fixed-grid fallback below in charge) when there are no
    transients to work with. }
  function FindTransientGrain(out AGrainStartSource, AGrainSourceLen,
    AGrainStartTimeline, AGrainEndTimeline: Int64;
    out AGrainTimelineLenF: Double): Boolean;
  var
    Ratio: Double;
    TIdx: Integer;
    BoundaryPos, NextBoundaryPos, NaturalLen: Int64;
    AccumTimeline, GrainTL: Double;
  begin
    Result := False;
    if Length(ATransients) = 0 then
      Exit;

    Ratio := SegTimelineLen / SegSourceLen;

    { ATransients holds ABSOLUTE positions within the whole sample file
      (DetectTransients' frame of reference; the same cached array is shared
      by every clip chopping a different region of one sample) - but
      SegStartSource/SegSourceLen are CLIP-relative (relative to AOffset,
      same as AMarkers' SourceFrame). Translate by -AOffset before every
      comparison, exactly like AudioEngine.ClipSourcePosition's copy. }
    TIdx := 0;
    while (TIdx < Length(ATransients)) and
      (ATransients[TIdx] - AOffset <= SegStartSource) do
      Inc(TIdx);

    { no transient strictly inside this segment: report failure so the
      fixed-grid fallback subdivides it (~WarpGrainMs grains) instead of
      treating the whole segment as ONE giant grain, whose single long
      ping-pong is exactly the obvious-loop sound grains exist to avoid }
    if (TIdx >= Length(ATransients)) or
      (ATransients[TIdx] - AOffset >= SegStartSource + SegSourceLen) then
      Exit;

    BoundaryPos := SegStartSource;
    AccumTimeline := 0;

    while True do
    begin
      if (TIdx < Length(ATransients)) and
        (ATransients[TIdx] - AOffset < SegStartSource + SegSourceLen) then
        NextBoundaryPos := ATransients[TIdx] - AOffset
      else
        NextBoundaryPos := SegStartSource + SegSourceLen;

      NaturalLen := NextBoundaryPos - BoundaryPos;
      if NaturalLen < 1 then
      begin
        { degenerate boundary - shouldn't normally happen given
          DetectTransients' own minimum spacing, but never trust it blindly }
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
          WarpedSourceSample then converges onto this grain's own natural
          continuation (a no-op) and the real splice 1-2 frames later plays
          completely unfaded. }
        AGrainEndTimeline := Trunc(AccumTimeline + GrainTL);
        if AGrainEndTimeline < AccumTimeline + GrainTL then
          Inc(AGrainEndTimeline);
        AGrainTimelineLenF := GrainTL;
        Exit(True);
      end;

      AccumTimeline := AccumTimeline + GrainTL;
      BoundaryPos := NextBoundaryPos;
      Inc(TIdx);
    end;
  end;

begin
  if Length(AMarkers) < 2 then
    Exit(ATimelineFrame);

  k := 0;
  while (k < Length(AMarkers) - 2) and
    (ATimelineFrame >= AMarkers[k + 1].TimelineFrame) do
    Inc(k);

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
      before the marker instead of snapping it - same idea as the ping-pong
      reversal smoothing below, applied to a rate kink instead of a
      direction reversal. }
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

  { Beats: subdivide into grains bounded by detected transients (falling back
    to a fixed grid when no transients are available) and distribute the
    stretch/compression evenly across each grain - see
    AudioEngine.ClipSourcePosition for the full rationale (this is the
    shared/offline-safe copy of the same algorithm). }
  HaveTransientGrain := FindTransientGrain(GrainStartSource, GrainSourceLen,
    GrainStartTimeline, GrainEndTimeline, GrainTimelineLenF);

  if not HaveTransientGrain then
  begin
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
    if GrainTimelineLenF < GrainSourceLen then
    begin
      StopPoint := GrainStartSource + Trunc(GrainTimelineLenF);
      { AData/AFrameCount span the WHOLE sample file (absolute frame 0 =
        start of the WAV) while StopPoint is clip-relative (relative to
        AOffset, same as AMarkers' SourceFrame values) - translate to
        absolute for the search, then back for the returned (clip-relative)
        position, or a clip that's a chop of a longer sample (AOffset <> 0)
        snaps to a "zero crossing" that's actually near an unrelated part of
        the file. }
      SnappedStop := FindNearestZeroCrossing(AData, AFrameCount, AChannels,
        StopPoint + AOffset, WarpZeroCrossSearchFrames) - AOffset;
      CandidatePos := GrainStartSource + GrainOffsetIntoGrain;
      if CandidatePos >= SnappedStop then
        Exit(SnappedStop);
      Exit(CandidatePos);
    end;
    Exit(GrainStartSource + GrainOffsetIntoGrain);
  end;

  { ping-pong (Ableton's "Loop Back-and-Forth") within the back half of this
    grain to fill extra time, instead of a forward-repeat that tends to
    sound like an obvious loop }
  Overflow := GrainOffsetIntoGrain - GrainSourceLen;
  { same clip-relative -> absolute -> clip-relative translation as the
    truncate branch above - see the comment there }
  LoopRegionStart := FindNearestZeroCrossing(AData, AFrameCount, AChannels,
    GrainStartSource + GrainSourceLen div 2 + AOffset, WarpZeroCrossSearchFrames) - AOffset;
  LoopRegionEnd := FindNearestZeroCrossing(AData, AFrameCount, AChannels,
    GrainStartSource + GrainSourceLen + AOffset, WarpZeroCrossSearchFrames) - AOffset;
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
    discontinuity that zero-crossing snapping (which only fixes amplitude
    discontinuities) can't touch. Blend the two candidate POSITIONS on
    either side of each reversal so the read pointer's trajectory turns
    around smoothly instead of snapping instantly; both candidates reference
    the same underlying audio (just approached from opposite directions), so
    blending positions here - unlike across unrelated grains - is a
    legitimate smoothing of one continuous path. }
  FadeFrames := (WarpReversalFadeMs * ASampleRate) / 1000;
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
  { see AudioEngine.ClipSourceSample - grains are unrelated slices of audio,
    so their boundary needs a real sample-domain crossfade, unlike a
    ping-pong reversal (which can be smoothed by blending positions alone). }
  WarpGrainCrossfadeMs = 4;

function WarpedSourceSample(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; AClipLength: Int64; AOffset: Int64; AData: PSingle;
  AFrameCount: Integer; AChannels: Integer; ASampleRate: Integer;
  AWarpMode: Integer; AChannel: Integer; const ATransients: TFrameArray): Single;
var
  PosA, PosB0, PosB, FadeT: Double;
  GrainEnd, FadeFrames, DistToEnd: Int64;
  SampleA, SampleB: Single;

  function SafeInterp(APos: Double): Single;
  var
    AbsPos: Double;
  begin
    AbsPos := AOffset + APos;
    if (AbsPos < 0) or (AbsPos >= AFrameCount) then
      Result := 0
    else
      Result := Interpolate(AData, AFrameCount, AChannels, AChannel, AbsPos);
  end;

begin
  if Length(AMarkers) < 2 then
    Exit(SafeInterp(ATimelineFrame));

  GrainEnd := -1;
  PosA := WarpedSourcePosition(AMarkers, ATimelineFrame, AData, AFrameCount,
    AChannels, ASampleRate, AWarpMode, ATransients, @GrainEnd, AOffset);
  SampleA := SafeInterp(PosA);

  FadeFrames := (WarpGrainCrossfadeMs * ASampleRate) div 1000;
  if FadeFrames < 1 then
    FadeFrames := 1;

  DistToEnd := GrainEnd - ATimelineFrame;
  if (GrainEnd < 0) or (DistToEnd <= 0) or (DistToEnd > FadeFrames) or
    (GrainEnd >= AClipLength) then
    Exit(SampleA);

  PosB0 := WarpedSourcePosition(AMarkers, GrainEnd, AData, AFrameCount,
    AChannels, ASampleRate, AWarpMode, ATransients, nil, AOffset);
  PosB := PosB0 - DistToEnd;
  SampleB := SafeInterp(PosB);

  FadeT := 1 - (DistToEnd / FadeFrames);
  Result := SampleA * (1 - FadeT) + SampleB * FadeT;
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
  AClipLength: Int64; const ATransients: TFrameArray): Single;
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
      Result := Interpolate(AData, AFrameCount, AChannels, AChannel, AbsPos);
  end;

begin
  if ADetuneSemitones = 0 then
    Exit(WarpedSourceSample(AMarkers, ATimelineFrame, AClipLength, AOffset,
      AData, AFrameCount, AChannels, ASampleRate, AWarpMode, AChannel,
      ATransients));

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
    realtime copy (AudioEngine's ClipSourcePosition always sees the clip's
    transients) - otherwise a bounce's detune grains would anchor to
    fixed-grid warp positions while live playback anchors to
    transient-bounded ones }
  AnchorStart := WarpedSourcePosition(AMarkers, GrainStartTimeline, AData,
    AFrameCount, AChannels, ASampleRate, AWarpMode, ATransients, nil, AOffset);

  PosCurrent := AnchorStart + GrainOffsetIntoGrain * Rate;
  SampleCurrent := SafeInterp(PosCurrent);

  if GrainOffsetIntoGrain < GrainFrames - Overlap then
    Exit(SampleCurrent);

  { last Overlap frames of this grain - blend towards the next grain, whose
    own local offset starts a bit negative here, i.e. it's already "running"
    underneath the tail of this one and lands exactly on its own anchor at
    the boundary }
  AnchorEnd := WarpedSourcePosition(AMarkers, GrainStartTimeline + GrainFrames,
    AData, AFrameCount, AChannels, ASampleRate, AWarpMode, ATransients, nil, AOffset);
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
    { a cut strictly inside one grain's ping-pong loop zone can't be
      represented by simply rebasing markers there: the loop math is driven
      by that grain's own natural length, and truncating it for the right
      half would reconstruct a different (wrong) loop. Snap forward to that
      GRAIN's own end (not the whole segment's, now that segments are
      subdivided into small grains - see WarpedSourcePosition) - a much
      smaller nudge than the old whole-segment snap. }
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
    SplitSource := Round(WarpedSourcePosition(AMarkers, ASplitFrame, nil, 0, 0,
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

procedure DrawWaveform(ACanvas: TCanvas; const ARect: TRect;
  const APeaks: TWaveformPeaks; ATotalFrameCount, AStartFrame, AEndFrame: Int64;
  const AMarkers: TWarpMarkerArray; AColor: TColor; AWarpMode: Integer;
  const ATransients: TFrameArray);
var
  x, midY, halfH, RectWidth: Integer;
  BinCount: Integer;
  ClipLength, TimelineFrame0, TimelineFrame1: Int64;
  SrcFrame0, SrcFrame1: Double;
  Bin0, Bin1, b: Integer;
  MinV, MaxV: Single;
  y0, y1: Integer;
begin
  BinCount := Length(APeaks.Mins);
  RectWidth := ARect.Right - ARect.Left;
  ClipLength := AEndFrame - AStartFrame;
  if (BinCount = 0) or (ATotalFrameCount <= 0) or (RectWidth <= 0) or
    (ClipLength <= 0) then
    Exit;

  midY := (ARect.Top + ARect.Bottom) div 2;
  halfH := (ARect.Bottom - ARect.Top) div 2;
  ACanvas.Pen.Color := AColor;

  for x := ARect.Left to ARect.Right - 1 do
  begin
    TimelineFrame0 := ((x - ARect.Left) * ClipLength) div RectWidth;
    TimelineFrame1 := ((x - ARect.Left + 1) * ClipLength) div RectWidth;
    if TimelineFrame1 <= TimelineFrame0 then
      TimelineFrame1 := TimelineFrame0 + 1;

    { AStartFrame doubles as the clip's source offset here - passing it as
      AOffset keeps the transient-bounded grain mapping identical to what
      playback computes, so the drawn stretch matches the audible one }
    SrcFrame0 := AStartFrame + WarpedSourcePosition(AMarkers, TimelineFrame0,
      nil, 0, 0, 44100, AWarpMode, ATransients, nil, AStartFrame);
    SrcFrame1 := AStartFrame + WarpedSourcePosition(AMarkers, TimelineFrame1,
      nil, 0, 0, 44100, AWarpMode, ATransients, nil, AStartFrame);
    if SrcFrame1 <= SrcFrame0 then
      SrcFrame1 := SrcFrame0 + 1;

    Bin0 := Trunc(SrcFrame0 * BinCount / ATotalFrameCount);
    Bin1 := Trunc(SrcFrame1 * BinCount / ATotalFrameCount);
    if Bin0 < 0 then Bin0 := 0;
    if Bin0 >= BinCount then Continue;
    if Bin1 <= Bin0 then Bin1 := Bin0 + 1;
    if Bin1 > BinCount then Bin1 := BinCount;

    MinV := APeaks.Mins[Bin0];
    MaxV := APeaks.Maxs[Bin0];
    for b := Bin0 + 1 to Bin1 - 1 do
    begin
      if APeaks.Mins[b] < MinV then MinV := APeaks.Mins[b];
      if APeaks.Maxs[b] > MaxV then MaxV := APeaks.Maxs[b];
    end;

    y0 := midY - Round(MaxV * halfH);
    y1 := midY - Round(MinV * halfH);
    if y1 = y0 then
      y1 := y0 + 1;
    ACanvas.Line(x, y0, x, y1);
  end;
end;

end.
