unit Waveform;

{$mode objfpc}{$H+}

interface

uses
  Graphics, Types, SampleTypes;

const
  MaxWaveformBins = 4096;

type
  TWaveformPeaks = record
    Mins: array of Single;
    Maxs: array of Single;
  end;

function ComputeWaveformPeaks(const ASample: TSample): TWaveformPeaks;

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
  AWarpMode: Integer = WarpModeBeats): Double;

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
function SplitWarpMarkers(const AMarkers: TWarpMarkerArray; ASplitFrame: Int64;
  out ALeftMarkers, ARightMarkers: TWarpMarkerArray;
  AWarpMode: Integer = WarpModeBeats; ASampleRate: Integer = 44100): Int64;

{ Independent per-clip pitch trim (the "Detune" slider) layered on top of
  WarpedSourcePosition rather than inside it, so Beats/RePitch warping
  itself is completely untouched by this - see
  AudioEngine.DetunedClipSourcePosition (the realtime engine's own copy of
  the identical trick) for the full explanation. Used by offline render
  (ProjectFile.RenderProjectToWav) so a bounce matches live playback. }
function DetunedSourcePosition(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; ADetuneSemitones: Single; AData: PSingle;
  AFrameCount, AChannels, ASampleRate: Integer; AWarpMode: Integer): Double;

{ Draws the waveform for [AStartFrame, AEndFrame) of a sample (out of
  ATotalFrameCount frames covered by APeaks) into ARect. When AMarkers has
  fewer than 2 entries this is a plain linear stretch; otherwise each pixel
  column is mapped through the warp before looking up its peak bin, so the
  drawn waveform visually stretches/compresses exactly like the audio does. }
procedure DrawWaveform(ACanvas: TCanvas; const ARect: TRect;
  const APeaks: TWaveformPeaks; ATotalFrameCount, AStartFrame, AEndFrame: Int64;
  const AMarkers: TWarpMarkerArray; AColor: TColor; AWarpMode: Integer = WarpModeBeats);

implementation

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
  AChannels: Integer; ASampleRate: Integer; AWarpMode: Integer): Double;
var
  k: Integer;
  SegStartTimeline, SegStartSource, SegTimelineLen, SegSourceLen: Int64;
  OffsetIntoSeg, StopPoint, SnappedStop, CandidatePos: Int64;
  GrainSourceLen, GrainCount, GrainIndex: Int64;
  GrainTimelineLenF: Double;
  GrainStartTimeline, GrainStartSource, GrainOffsetIntoGrain: Int64;
  Overflow, LoopRegionStart, LoopRegionEnd, LoopLen, Period, Phase: Int64;
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
    Exit(SegStartSource + OffsetIntoSeg * (SegSourceLen / SegTimelineLen));
  end;

  if SegTimelineLen <= 0 then
    Exit(SegStartSource);
  if SegSourceLen <= 0 then
    Exit(SegStartSource);

  { Beats: subdivide into small grains and distribute the stretch/compression
    evenly across them - see AudioEngine.ClipSourcePosition for the full
    rationale (this is the shared/offline-safe copy of the same algorithm). }
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
  GrainOffsetIntoGrain := OffsetIntoSeg - GrainStartTimeline;

  if GrainOffsetIntoGrain < GrainSourceLen then
  begin
    if GrainTimelineLenF < GrainSourceLen then
    begin
      StopPoint := GrainStartSource + Trunc(GrainTimelineLenF);
      SnappedStop := FindNearestZeroCrossing(AData, AFrameCount, AChannels,
        StopPoint, WarpZeroCrossSearchFrames);
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
  LoopRegionStart := FindNearestZeroCrossing(AData, AFrameCount, AChannels,
    GrainStartSource + GrainSourceLen div 2, WarpZeroCrossSearchFrames);
  LoopRegionEnd := FindNearestZeroCrossing(AData, AFrameCount, AChannels,
    GrainStartSource + GrainSourceLen, WarpZeroCrossSearchFrames);
  { never snap PAST the grain's own natural boundary - only earlier, so the
    loop can never read into the next grain (or past the segment's end) }
  if LoopRegionEnd > GrainStartSource + GrainSourceLen then
    LoopRegionEnd := GrainStartSource + GrainSourceLen;

  LoopLen := LoopRegionEnd - LoopRegionStart;
  if LoopLen < 1 then
    LoopLen := 1;
  Period := 2 * LoopLen;
  Phase := Overflow mod Period;
  if Phase < LoopLen then
    Result := LoopRegionEnd - Phase
  else
    Result := LoopRegionStart + (Phase - LoopLen);
end;

function DetunedSourcePosition(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; ADetuneSemitones: Single; AData: PSingle;
  AFrameCount, AChannels, ASampleRate: Integer; AWarpMode: Integer): Double;
const
  DetuneGrainMs = 25; { small on purpose - see AudioEngine.DetunedClipSourcePosition }
var
  Rate, Phase, Period, AnchorStart, AnchorEnd, GrainNaturalSourceLen, ConsumedSource: Double;
  GrainFrames, GrainIndex, GrainStartTimeline, GrainOffsetIntoGrain: Int64;
begin
  if ADetuneSemitones = 0 then
    Exit(WarpedSourcePosition(AMarkers, ATimelineFrame, AData, AFrameCount,
      AChannels, ASampleRate, AWarpMode));

  Rate := Exp((ADetuneSemitones / 12) * Ln(2));
  GrainFrames := (DetuneGrainMs * ASampleRate) div 1000;
  if GrainFrames < 1 then
    GrainFrames := 1;

  GrainIndex := ATimelineFrame div GrainFrames;
  GrainStartTimeline := GrainIndex * GrainFrames;
  GrainOffsetIntoGrain := ATimelineFrame - GrainStartTimeline;

  AnchorStart := WarpedSourcePosition(AMarkers, GrainStartTimeline, AData,
    AFrameCount, AChannels, ASampleRate, AWarpMode);
  AnchorEnd := WarpedSourcePosition(AMarkers, GrainStartTimeline + GrainFrames,
    AData, AFrameCount, AChannels, ASampleRate, AWarpMode);
  GrainNaturalSourceLen := AnchorEnd - AnchorStart;
  if GrainNaturalSourceLen < 1 then
    GrainNaturalSourceLen := 1;

  ConsumedSource := GrainOffsetIntoGrain * Rate;

  Period := 2 * GrainNaturalSourceLen;
  Phase := ConsumedSource - Trunc(ConsumedSource / Period) * Period;
  if Phase < GrainNaturalSourceLen then
    Result := AnchorStart + Phase
  else
    Result := AnchorStart + (Period - Phase);
end;

function SplitWarpMarkers(const AMarkers: TWarpMarkerArray; ASplitFrame: Int64;
  out ALeftMarkers, ARightMarkers: TWarpMarkerArray; AWarpMode: Integer;
  ASampleRate: Integer): Int64;
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
    Exit(ASplitFrame); { unwarped already - nothing to preserve }

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
  const AMarkers: TWarpMarkerArray; AColor: TColor; AWarpMode: Integer);
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

    SrcFrame0 := AStartFrame + WarpedSourcePosition(AMarkers, TimelineFrame0,
      nil, 0, 0, 44100, AWarpMode);
    SrcFrame1 := AStartFrame + WarpedSourcePosition(AMarkers, TimelineFrame1,
      nil, 0, 0, 44100, AWarpMode);
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
