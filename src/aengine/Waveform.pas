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
function WarpedSourcePosition(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; ASampleRate: Integer = 44100;
  AWarpMode: Integer = WarpModeBeats): Double;

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
  drawn waveform visually stretches/compresses exactly like the audio does.

  ATransients is retained for call-site compatibility but no longer read: the
  columns are mapped through the nominal warp position, which needs no slice
  layout. It can go once the UI callers stop passing it. }
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
  { see the matching constants in AudioEngine - this unit is the offline/
    shared copy of the identical algorithm and must stay in step with it, or
    a bounce stops matching what was heard live }
  WarpGrainMs = 120;
  WarpSliceReleaseMs = 30;
  WarpSliceAttackFrames = 24;
  WarpReversalFadeMs = 3;
  WarpMaxOverlapSlices = 4;
  WarpRepitchFadeMs = 4;

function WarpedSourcePosition(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; ASampleRate: Integer; AWarpMode: Integer): Double;
var
  k: Integer;
  SegStartTimeline, SegStartSource, SegTimelineLen, SegSourceLen: Int64;
  OffsetIntoSeg: Int64;
  RePitchFadeFrames, RePitchDistToEnd, NextSegSourceLen, NextSegTimelineLen: Int64;
  RePitchPosA, RePitchPosB, RePitchFadeT: Double;
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

{ Beats warp renderer - the offline/shared copy of AudioEngine.BeatsClipSample.
  See that function's header comment for the full rationale (why Beats is a sum
  over overlapping transient slices rather than a single read position, and why
  the zero-crossing snapping and grain cache the old implementation needed are
  both gone). This copy exists because the realtime side can only ever have a
  raw PInt64/Count pair for its transients, the lock-free-safe shape, while
  every other caller has a TFrameArray; the two must stay in step. }
function WarpedSourceSample(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; AClipLength: Int64; AOffset: Int64; AData: PSingle;
  AFrameCount: Integer; AChannels: Integer; ASampleRate: Integer;
  AWarpMode: Integer; AChannel: Integer;
  const ATransients: TFrameArray): Single;
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
      Result := Interpolate(AData, AFrameCount, AChannels, AChannel, AbsPos);
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
  if Length(AMarkers) < 2 then
    Exit(SafeInterp(ATimelineFrame));

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
    realtime copy (AudioEngine.DetunedClipSample anchors to the same nominal
    map), so a bounce's detune grains land exactly where live playback's do }
  AnchorStart := WarpedSourcePosition(AMarkers, GrainStartTimeline,
    ASampleRate, AWarpMode);

  PosCurrent := AnchorStart + GrainOffsetIntoGrain * Rate;
  SampleCurrent := SafeInterp(PosCurrent);

  if GrainOffsetIntoGrain < GrainFrames - Overlap then
    Exit(SampleCurrent);

  { last Overlap frames of this grain - blend towards the next grain, whose
    own local offset starts a bit negative here, i.e. it's already "running"
    underneath the tail of this one and lands exactly on its own anchor at
    the boundary }
  AnchorEnd := WarpedSourcePosition(AMarkers, GrainStartTimeline + GrainFrames,
    ASampleRate, AWarpMode);
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

    { the nominal map is relative to the clip's own Offset, which AStartFrame
      is here - so add it back to get an absolute source frame. Drawing the
      nominal map (rather than the old per-grain ping-pong positions) is also
      what makes a stretched region read as a smooth stretch on screen instead
      of a scribble. }
    SrcFrame0 := AStartFrame + WarpedSourcePosition(AMarkers, TimelineFrame0,
      44100, AWarpMode);
    SrcFrame1 := AStartFrame + WarpedSourcePosition(AMarkers, TimelineFrame1,
      44100, AWarpMode);
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
