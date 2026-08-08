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
  can omit them. }
function WarpedSourcePosition(const AMarkers: TWarpMarkerArray;
  ATimelineFrame: Int64; AData: PSingle = nil; AFrameCount: Integer = 0;
  AChannels: Integer = 0; ASampleRate: Integer = 44100): Double;

{ Draws the waveform for [AStartFrame, AEndFrame) of a sample (out of
  ATotalFrameCount frames covered by APeaks) into ARect. When AMarkers has
  fewer than 2 entries this is a plain linear stretch; otherwise each pixel
  column is mapped through the warp before looking up its peak bin, so the
  drawn waveform visually stretches/compresses exactly like the audio does. }
procedure DrawWaveform(ACanvas: TCanvas; const ARect: TRect;
  const APeaks: TWaveformPeaks; ATotalFrameCount, AStartFrame, AEndFrame: Int64;
  const AMarkers: TWarpMarkerArray; AColor: TColor);

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
  AChannels: Integer; ASampleRate: Integer): Double;
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

procedure DrawWaveform(ACanvas: TCanvas; const ARect: TRect;
  const APeaks: TWaveformPeaks; ATotalFrameCount, AStartFrame, AEndFrame: Int64;
  const AMarkers: TWarpMarkerArray; AColor: TColor);
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

    SrcFrame0 := AStartFrame + WarpedSourcePosition(AMarkers, TimelineFrame0);
    SrcFrame1 := AStartFrame + WarpedSourcePosition(AMarkers, TimelineFrame1);
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
