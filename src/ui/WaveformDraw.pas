unit WaveformDraw;

{$mode objfpc}{$H+}

interface

uses
  Graphics, Types, SampleTypes, Waveform;

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
  const ATransients: TFrameArray = nil; const AZones: TDragZoneArray = nil);

implementation

procedure DrawWaveform(ACanvas: TCanvas; const ARect: TRect;
  const APeaks: TWaveformPeaks; ATotalFrameCount, AStartFrame, AEndFrame: Int64;
  const AMarkers: TWarpMarkerArray; AColor: TColor; AWarpMode: Integer;
  const ATransients: TFrameArray; const AZones: TDragZoneArray);
var
  x, midY, halfH, RectWidth: Integer;
  BinCount: Integer;
  ClipLength, TimelineFrame0, TimelineFrame1: Int64;
  SrcFrame0, SrcFrame1: Double;
  ZonePos0, ZonePos1: Int64;
  Bin0, Bin1, b: Integer;
  MinV, MaxV: Single;
  y0, y1: Integer;
  XFrom, XTo: Integer;
  VisRect: TRect;
  HintK: Integer;
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

  { Only the columns that can actually appear on screen. ARect is the clip's
    UNCLIPPED pixel rect, so at high zoom a long clip's rect is tens of
    thousands of pixels wide while a few hundred of them are visible - the
    loop used to run every one of those columns, doing two warp lookups and
    a fully off-canvas Canvas.Line each, which is the high-zoom paint stall.
    Narrowing to the canvas' clip box also means a partial repaint (the
    playhead moving over a couple of columns) costs a couple of columns of
    work here rather than a full redraw of every clip. The per-column
    arithmetic below is still keyed off ARect.Left, so which frames a given
    x maps to is unchanged - this only skips columns that were being drawn
    where nobody could see them. }
  XFrom := ARect.Left;
  XTo := ARect.Right - 1;
  VisRect := ACanvas.ClipRect;
  if VisRect.Right > VisRect.Left then
  begin
    if XFrom < VisRect.Left then
      XFrom := VisRect.Left;
    if XTo > VisRect.Right - 1 then
      XTo := VisRect.Right - 1;
  end;

  HintK := 0;
  for x := XFrom to XTo do
  begin
    TimelineFrame0 := ((x - ARect.Left) * ClipLength) div RectWidth;
    TimelineFrame1 := ((x - ARect.Left + 1) * ClipLength) div RectWidth;
    if TimelineFrame1 <= TimelineFrame0 then
      TimelineFrame1 := TimelineFrame0 + 1;

    { Drag has no markers/segments to walk - a column is either inside a
      zone (draw that slice of the source peaks, shifted) or in a gap
      (silence - leave the column blank rather than drawing whatever
      unrelated audio happens to sit at that raw timeline position, which
      WarpedSourcePosition's identity fallback would otherwise show). }
    if AWarpMode = WarpModeDrag then
    begin
      ZonePos0 := DragZoneSourcePosition(AZones, TimelineFrame0);
      ZonePos1 := DragZoneSourcePosition(AZones, TimelineFrame1 - 1);
      if (ZonePos0 = DragZoneSilence) and (ZonePos1 = DragZoneSilence) then
        Continue;
      if ZonePos0 = DragZoneSilence then
        ZonePos0 := ZonePos1;
      if ZonePos1 = DragZoneSilence then
        ZonePos1 := ZonePos0;
      SrcFrame0 := AStartFrame + ZonePos0;
      SrcFrame1 := AStartFrame + ZonePos1 + 1;
    end
    else
    begin
      { the nominal map is relative to the clip's own Offset, which
        AStartFrame is here - so add it back to get an absolute source
        frame. Drawing the nominal map (rather than the old per-grain
        ping-pong positions) is also what makes a stretched region read as
        a smooth stretch on screen instead of a scribble. }
      { x ascends, so TimelineFrame0/1 do too - HintK carries the segment
        search forward instead of restarting it from marker 0 every column }
      SrcFrame0 := AStartFrame + WarpedSourcePosition(AMarkers, TimelineFrame0,
        44100, AWarpMode, @HintK);
      SrcFrame1 := AStartFrame + WarpedSourcePosition(AMarkers, TimelineFrame1,
        44100, AWarpMode, @HintK);
    end;
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
