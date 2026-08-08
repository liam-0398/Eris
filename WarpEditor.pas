unit WarpEditor;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, SampleTypes, Project,
  AudioEngine, Waveform;

type
  TWarpEditor = class(TCustomControl)
  private
    const
      PixelsPerSecond = 200;
      MarkerGrabPixels = 6;
      MinMarkerGapFrames = 100;
    var
      FTrackIndex: Integer;
      FClipIndex: Integer;
      FDragMarkerIndex: Integer;
      FLastMouseX: Integer;
      FOnClipChanged: TNotifyEvent;
    function GetClip(out AClip: TClip): Boolean;
    procedure SetClipData(const AClip: TClip);
    function FrameToX(AFrame: Int64): Integer;
    function XToFrame(AX: Integer): Int64;
    function EighthNoteFrames: Int64;
    function SourceFrameAt(const AClip: TClip; ATimelineFrame: Int64): Int64;
    function HitTestMarker(const AClip: TClip; X: Integer): Integer;
    procedure DrawGrid;
    procedure DrawClipWaveform(const AClip: TClip);
    procedure DrawMarkers(const AClip: TClip);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure DblClick; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetClip(ATrackIndex, AClipIndex: Integer);
    property OnClipChanged: TNotifyEvent read FOnClipChanged write FOnClipChanged;
  end;

implementation

constructor TWarpEditor.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  ControlStyle := ControlStyle + [csOpaque];
  FTrackIndex := -1;
  FClipIndex := -1;
  FDragMarkerIndex := -1;
end;

function TWarpEditor.GetClip(out AClip: TClip): Boolean;
begin
  Result := (FTrackIndex >= 0) and (FTrackIndex < Project.TrackCount) and
    (FClipIndex >= 0) and (FClipIndex <= High(Project.Tracks[FTrackIndex].Clips));
  if Result then
    AClip := Project.Tracks[FTrackIndex].Clips[FClipIndex];
end;

procedure TWarpEditor.SetClipData(const AClip: TClip);
begin
  if (FTrackIndex < 0) or (FClipIndex < 0) then
    Exit;
  Project.Tracks[FTrackIndex].Clips[FClipIndex] := AClip;
  if Assigned(FOnClipChanged) then
    FOnClipChanged(Self);
  Invalidate;
end;

function TWarpEditor.FrameToX(AFrame: Int64): Integer;
begin
  Result := (AFrame * PixelsPerSecond) div AudioEngine.ProjectSampleRate;
end;

function TWarpEditor.XToFrame(AX: Integer): Int64;
begin
  Result := (Int64(AX) * AudioEngine.ProjectSampleRate) div PixelsPerSecond;
end;

function TWarpEditor.EighthNoteFrames: Int64;
var
  BeatFrames: Int64;
begin
  BeatFrames := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM);
  Result := BeatFrames div 2;
end;

function TWarpEditor.SourceFrameAt(const AClip: TClip; ATimelineFrame: Int64): Int64;
var
  k: Integer;
  SegTime, SegSrc: Int64;
begin
  if Length(AClip.WarpMarkers) < 2 then
    Exit(ATimelineFrame);

  k := 0;
  while (k < Length(AClip.WarpMarkers) - 2) and
    (ATimelineFrame >= AClip.WarpMarkers[k + 1].TimelineFrame) do
    Inc(k);

  SegTime := AClip.WarpMarkers[k + 1].TimelineFrame - AClip.WarpMarkers[k].TimelineFrame;
  SegSrc := AClip.WarpMarkers[k + 1].SourceFrame - AClip.WarpMarkers[k].SourceFrame;
  if SegTime = 0 then
    Result := AClip.WarpMarkers[k].SourceFrame
  else
    Result := AClip.WarpMarkers[k].SourceFrame +
      Round((ATimelineFrame - AClip.WarpMarkers[k].TimelineFrame) * (SegSrc / SegTime));
end;

function TWarpEditor.HitTestMarker(const AClip: TClip; X: Integer): Integer;
var
  i, mx: Integer;
begin
  Result := -1;
  for i := 0 to High(AClip.WarpMarkers) do
  begin
    mx := FrameToX(AClip.WarpMarkers[i].TimelineFrame);
    if Abs(X - mx) <= MarkerGrabPixels then
      Exit(i);
  end;
end;

procedure TWarpEditor.DrawGrid;
var
  Grid, Frame: Int64;
  x: Integer;
begin
  Grid := EighthNoteFrames;
  if Grid <= 0 then
    Exit;
  Canvas.Pen.Color := clSilver;
  Frame := 0;
  x := FrameToX(Frame);
  while x < Width do
  begin
    Canvas.Line(x, 0, x, Height);
    Frame := Frame + Grid;
    x := FrameToX(Frame);
  end;
end;

procedure TWarpEditor.DrawClipWaveform(const AClip: TClip);
var
  Sample: TSample;
begin
  if AClip.SampleID > High(Project.SamplePeaks) then
    Exit;
  Sample := Project.SamplePool[AClip.SampleID];
  DrawWaveform(Canvas, Rect(0, 0, Width, Height), Project.SamplePeaks[AClip.SampleID],
    Sample.FrameCount, AClip.Offset, AClip.Offset + AClip.Length, clBlack);
end;

procedure TWarpEditor.DrawMarkers(const AClip: TClip);
var
  i, x: Integer;
begin
  for i := 0 to High(AClip.WarpMarkers) do
  begin
    x := FrameToX(AClip.WarpMarkers[i].TimelineFrame);
    if i = 0 then
      Canvas.Pen.Color := clGray
    else if i = High(AClip.WarpMarkers) then
      Canvas.Pen.Color := clRed
    else
      Canvas.Pen.Color := clLime;
    Canvas.Pen.Width := 2;
    Canvas.Line(x, 0, x, Height);
    Canvas.Pen.Width := 1;
    Canvas.Brush.Color := Canvas.Pen.Color;
    Canvas.Polygon([Point(x - 5, 0), Point(x + 5, 0), Point(x, 8)]);
  end;
end;

procedure TWarpEditor.Paint;
var
  Clip: TClip;
begin
  Canvas.Brush.Color := clWindow;
  Canvas.FillRect(Rect(0, 0, Width, Height));

  if not GetClip(Clip) then
    Exit;

  DrawClipWaveform(Clip);
  DrawGrid;
  DrawMarkers(Clip);
end;

procedure TWarpEditor.SetClip(ATrackIndex, AClipIndex: Integer);
var
  Clip: TClip;
begin
  FTrackIndex := ATrackIndex;
  FClipIndex := AClipIndex;
  FDragMarkerIndex := -1;

  if GetClip(Clip) and (Length(Clip.WarpMarkers) < 2) then
  begin
    SetLength(Clip.WarpMarkers, 2);
    Clip.WarpMarkers[0].SourceFrame := 0;
    Clip.WarpMarkers[0].TimelineFrame := 0;
    Clip.WarpMarkers[1].SourceFrame := Clip.Length;
    Clip.WarpMarkers[1].TimelineFrame := Clip.Length;
    Project.Tracks[FTrackIndex].Clips[FClipIndex] := Clip;
  end;

  Invalidate;
end;

procedure TWarpEditor.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Clip: TClip;
begin
  inherited MouseDown(Button, Shift, X, Y);
  FLastMouseX := X;

  if (Button <> mbLeft) or not GetClip(Clip) then
    Exit;

  FDragMarkerIndex := HitTestMarker(Clip, X);
  if FDragMarkerIndex = 0 then
    FDragMarkerIndex := -1; { start marker is fixed }
end;

procedure TWarpEditor.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Clip: TClip;
  NewFrame, MinFrame, MaxFrame: Int64;
  NewMarkers: TWarpMarkerArray;
begin
  inherited MouseMove(Shift, X, Y);

  if FDragMarkerIndex < 0 then
    Exit;
  if not GetClip(Clip) then
    Exit;

  NewFrame := XToFrame(X);
  if NewFrame < 0 then
    NewFrame := 0;

  NewMarkers := Copy(Clip.WarpMarkers, 0, Length(Clip.WarpMarkers));

  if FDragMarkerIndex = High(NewMarkers) then
  begin
    { the end marker: dragging it changes the clip's total length, keeping
      the source content it points to fixed - a vari-speed stretch of the
      final segment }
    MinFrame := NewMarkers[FDragMarkerIndex - 1].TimelineFrame + 1;
    if NewFrame < MinFrame then
      NewFrame := MinFrame;
    NewMarkers[FDragMarkerIndex].TimelineFrame := NewFrame;
    Clip.Length := NewFrame;
  end
  else
  begin
    MinFrame := NewMarkers[FDragMarkerIndex - 1].TimelineFrame + 1;
    MaxFrame := NewMarkers[FDragMarkerIndex + 1].TimelineFrame - 1;
    if NewFrame < MinFrame then
      NewFrame := MinFrame;
    if NewFrame > MaxFrame then
      NewFrame := MaxFrame;
    NewMarkers[FDragMarkerIndex].TimelineFrame := NewFrame;
  end;

  Clip.WarpMarkers := NewMarkers;
  SetClipData(Clip);
end;

procedure TWarpEditor.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragMarkerIndex := -1;
end;

procedure TWarpEditor.DblClick;
var
  Clip: TClip;
  HitIndex: Integer;
  ClickFrame: Int64;
  NewMarkers: TWarpMarkerArray;
  InsertAt, i: Integer;
begin
  inherited DblClick;

  if not GetClip(Clip) then
    Exit;

  HitIndex := HitTestMarker(Clip, FLastMouseX);

  if (HitIndex > 0) and (HitIndex < High(Clip.WarpMarkers)) then
  begin
    { remove an existing user-added marker }
    NewMarkers := nil;
    SetLength(NewMarkers, Length(Clip.WarpMarkers) - 1);
    InsertAt := 0;
    for i := 0 to High(Clip.WarpMarkers) do
      if i <> HitIndex then
      begin
        NewMarkers[InsertAt] := Clip.WarpMarkers[i];
        Inc(InsertAt);
      end;
    Clip.WarpMarkers := NewMarkers;
    SetClipData(Clip);
    Exit;
  end;

  if HitIndex >= 0 then
    Exit; { double-clicked the fixed start or end marker - nothing to do }

  { add a new marker at the clicked point, pinned to wherever it currently
    maps in the source under the existing warp - inserting it changes
    nothing about playback until it's subsequently dragged }
  ClickFrame := XToFrame(FLastMouseX);
  if (ClickFrame <= 0) or (ClickFrame >= Clip.Length) then
    Exit;
  if Length(Clip.WarpMarkers) >= MaxClipWarpMarkers then
    Exit;

  InsertAt := 1;
  while (InsertAt < Length(Clip.WarpMarkers)) and
    (Clip.WarpMarkers[InsertAt].TimelineFrame < ClickFrame) do
    Inc(InsertAt);

  if (InsertAt < Length(Clip.WarpMarkers)) and
    (Abs(Clip.WarpMarkers[InsertAt].TimelineFrame - ClickFrame) < MinMarkerGapFrames) then
    Exit;
  if (InsertAt > 0) and
    (Abs(Clip.WarpMarkers[InsertAt - 1].TimelineFrame - ClickFrame) < MinMarkerGapFrames) then
    Exit;

  SetLength(NewMarkers, Length(Clip.WarpMarkers) + 1);
  for i := 0 to InsertAt - 1 do
    NewMarkers[i] := Clip.WarpMarkers[i];
  NewMarkers[InsertAt].SourceFrame := SourceFrameAt(Clip, ClickFrame);
  NewMarkers[InsertAt].TimelineFrame := ClickFrame;
  for i := InsertAt to High(Clip.WarpMarkers) do
    NewMarkers[i + 1] := Clip.WarpMarkers[i];

  Clip.WarpMarkers := NewMarkers;
  SetClipData(Clip);
end;

end.
