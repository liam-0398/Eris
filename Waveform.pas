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

  Each marker-to-marker segment always plays back at 1:1 (pitch untouched):
  if the segment needs to be longer than its natural length, the tail is
  looped to fill the extra time; if shorter, the tail is simply skipped.
  This matches Ableton's "Beats" warp mode rather than a continuous
  vari-speed/Re-Pitch resample across the whole segment - nudging one marker
  no longer detunes the whole span, only the one adjusted segment.

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
  snap-forward only applies in Beats mode; in RePitch mode a segment is a
  plain linear resample and can be split cleanly anywhere. }
function SplitWarpMarkers(const AMarkers: TWarpMarkerArray; ASplitFrame: Int64;
  out ALeftMarkers, ARightMarkers: TWarpMarkerArray;
  AWarpMode: Integer = WarpModeBeats): Int64;

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
  WarpLoopWindowMs = 50;
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
  Overflow, LoopWindow, LoopStart, LoopEnd, ActualLoopWindow: Int64;
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

  if OffsetIntoSeg < SegSourceLen then
  begin
    if SegTimelineLen < SegSourceLen then
    begin
      StopPoint := SegStartSource + SegTimelineLen;
      SnappedStop := FindNearestZeroCrossing(AData, AFrameCount, AChannels,
        StopPoint, WarpZeroCrossSearchFrames);
      CandidatePos := SegStartSource + OffsetIntoSeg;
      if CandidatePos >= SnappedStop then
        Exit(SnappedStop);
      Exit(CandidatePos);
    end;
    Exit(SegStartSource + OffsetIntoSeg);
  end;

  Overflow := OffsetIntoSeg - SegSourceLen;
  LoopWindow := (WarpLoopWindowMs * ASampleRate) div 1000;
  if LoopWindow > SegSourceLen then
    LoopWindow := SegSourceLen;
  if LoopWindow < 1 then
    LoopWindow := 1;

  LoopStart := FindNearestZeroCrossing(AData, AFrameCount, AChannels,
    SegStartSource + SegSourceLen - LoopWindow, WarpZeroCrossSearchFrames);
  LoopEnd := FindNearestZeroCrossing(AData, AFrameCount, AChannels,
    SegStartSource + SegSourceLen, WarpZeroCrossSearchFrames);

  ActualLoopWindow := LoopEnd - LoopStart;
  if ActualLoopWindow < 1 then
    ActualLoopWindow := 1;

  Result := LoopStart + (Overflow mod ActualLoopWindow);
end;

function SplitWarpMarkers(const AMarkers: TWarpMarkerArray; ASplitFrame: Int64;
  out ALeftMarkers, ARightMarkers: TWarpMarkerArray; AWarpMode: Integer): Int64;
var
  i, cnt, k: Integer;
  SplitSource: Int64;
  SegStartTimeline, SegSourceLen, SegTimelineLen, OffsetIntoSeg: Int64;
begin
  ALeftMarkers := nil;
  ARightMarkers := nil;
  if Length(AMarkers) < 2 then
    Exit(ASplitFrame); { unwarped already - nothing to preserve }

  if ASplitFrame < AMarkers[0].TimelineFrame + 1 then
    ASplitFrame := AMarkers[0].TimelineFrame + 1;
  if ASplitFrame > AMarkers[High(AMarkers)].TimelineFrame then
    ASplitFrame := AMarkers[High(AMarkers)].TimelineFrame;

  { a cut strictly inside a stretched (looped) segment can't be represented
    by simply rebasing that segment's end marker: the loop-fill math is
    driven by the segment's full natural length, and truncating the segment
    for the right half would shrink that reference and reconstruct a
    completely different (and wrong) loop window. Snap forward to that
    segment's own end instead - splitting is still exact for every other
    case (natural-rate segments, compressed segments, or a cut already
    sitting on an existing marker). }
  k := 0;
  while (k < Length(AMarkers) - 2) and (ASplitFrame >= AMarkers[k + 1].TimelineFrame) do
    Inc(k);
  SegStartTimeline := AMarkers[k].TimelineFrame;
  SegTimelineLen := AMarkers[k + 1].TimelineFrame - SegStartTimeline;
  SegSourceLen := AMarkers[k + 1].SourceFrame - AMarkers[k].SourceFrame;
  OffsetIntoSeg := ASplitFrame - SegStartTimeline;
  if (AWarpMode = WarpModeBeats) and (OffsetIntoSeg > 0) and
    (OffsetIntoSeg < SegTimelineLen) and (SegTimelineLen > SegSourceLen) then
    ASplitFrame := AMarkers[k + 1].TimelineFrame;

  Result := ASplitFrame;

  { querying WarpedSourcePosition exactly at the array's final TimelineFrame
    is out of its intended domain (valid queries only go up to Length-1) -
    use the marker's own endpoint directly instead }
  if ASplitFrame >= AMarkers[High(AMarkers)].TimelineFrame then
    SplitSource := AMarkers[High(AMarkers)].SourceFrame
  else
    SplitSource := Round(WarpedSourcePosition(AMarkers, ASplitFrame, nil, 0, 0,
      44100, AWarpMode));

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
