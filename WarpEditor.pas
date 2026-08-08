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
      DefaultPixelsPerSecond = 200;
      MinPixelsPerSecond = 20;
      MarkerGrabPixels = 6;
      MinMarkerGapFrames = 100;
    var
      FTrackIndex: Integer;
      FClipIndex: Integer;
      FDragMarkerIndex: Integer;
      FLastMouseX: Integer;
      FZoomPixelsPerSecond: Double;
      FPlayheadFrame: Int64;
      FIsPlaying: Boolean;
      FOnClipChanged: TNotifyEvent;
    function GetClip(out AClip: TClip): Boolean;
    procedure SetClipData(const AClip: TClip);
    procedure RecomputeZoom(const AClip: TClip);
    function FrameToX(AFrame: Int64): Integer;
    function XToFrame(AX: Integer): Int64;
    function EighthNoteFrames: Int64;
    function HitTestMarker(const AClip: TClip; X: Integer): Integer;
    procedure DeleteMarker(const AClip: TClip; AIndex: Integer);
    procedure DrawGrid;
    procedure DrawClipWaveform(const AClip: TClip);
    procedure DrawMarkers(const AClip: TClip);
    procedure DrawPlayhead(const AClip: TClip);
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
    procedure SetPlayheadState(AGlobalFrame: Int64; APlaying: Boolean);
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
  FZoomPixelsPerSecond := DefaultPixelsPerSecond;
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

procedure TWarpEditor.RecomputeZoom(const AClip: TClip);
begin
  { fit the whole clip to the widget's width, so the end marker (used to
    adjust length) is never dragged off-screen for longer clips }
  if (AClip.Length > 0) and (Width > 0) then
    FZoomPixelsPerSecond := (Width * AudioEngine.ProjectSampleRate) / AClip.Length
  else
    FZoomPixelsPerSecond := DefaultPixelsPerSecond;
  if FZoomPixelsPerSecond < MinPixelsPerSecond then
    FZoomPixelsPerSecond := MinPixelsPerSecond;
end;

function TWarpEditor.FrameToX(AFrame: Int64): Integer;
begin
  Result := Round(AFrame * FZoomPixelsPerSecond / AudioEngine.ProjectSampleRate);
end;

function TWarpEditor.XToFrame(AX: Integer): Int64;
begin
  Result := Round(AX * AudioEngine.ProjectSampleRate / FZoomPixelsPerSecond);
end;

function TWarpEditor.EighthNoteFrames: Int64;
var
  BeatFrames: Int64;
begin
  BeatFrames := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM);
  Result := BeatFrames div 2;
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

procedure TWarpEditor.DeleteMarker(const AClip: TClip; AIndex: Integer);
var
  NewMarkers: TWarpMarkerArray;
  Clip: TClip;
  InsertAt, i: Integer;
begin
  if (AIndex <= 0) or (AIndex >= High(AClip.WarpMarkers)) then
    Exit; { start and end markers can't be removed }

  SetLength(NewMarkers, Length(AClip.WarpMarkers) - 1);
  InsertAt := 0;
  for i := 0 to High(AClip.WarpMarkers) do
    if i <> AIndex then
    begin
      NewMarkers[InsertAt] := AClip.WarpMarkers[i];
      Inc(InsertAt);
    end;

  Clip := AClip;
  Clip.WarpMarkers := NewMarkers;
  SetClipData(Clip);
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
    Sample.FrameCount, AClip.Offset, AClip.Offset + AClip.Length,
    AClip.WarpMarkers, clAqua);
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

procedure TWarpEditor.DrawPlayhead(const AClip: TClip);
var
  ClipRelFrame: Int64;
  x: Integer;
begin
  if not FIsPlaying then
    Exit;
  ClipRelFrame := FPlayheadFrame - AClip.Position;
  if (ClipRelFrame < 0) or (ClipRelFrame >= AClip.Length) then
    Exit;
  x := FrameToX(ClipRelFrame);
  Canvas.Pen.Color := clYellow;
  Canvas.Pen.Width := 2;
  Canvas.Line(x, 0, x, Height);
  Canvas.Pen.Width := 1;
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
  DrawPlayhead(Clip);
end;

procedure TWarpEditor.SetClip(ATrackIndex, AClipIndex: Integer);
var
  Clip: TClip;
begin
  FTrackIndex := ATrackIndex;
  FClipIndex := AClipIndex;
  FDragMarkerIndex := -1;

  if GetClip(Clip) then
  begin
    if Length(Clip.WarpMarkers) < 2 then
    begin
      SetLength(Clip.WarpMarkers, 2);
      Clip.WarpMarkers[0].SourceFrame := 0;
      Clip.WarpMarkers[0].TimelineFrame := 0;
      Clip.WarpMarkers[1].SourceFrame := Clip.Length;
      Clip.WarpMarkers[1].TimelineFrame := Clip.Length;
      Project.Tracks[FTrackIndex].Clips[FClipIndex] := Clip;
    end;
    RecomputeZoom(Clip);
  end;

  Invalidate;
end;

procedure TWarpEditor.SetPlayheadState(AGlobalFrame: Int64; APlaying: Boolean);
begin
  if (AGlobalFrame = FPlayheadFrame) and (APlaying = FIsPlaying) then
    Exit;
  FPlayheadFrame := AGlobalFrame;
  FIsPlaying := APlaying;
  Invalidate;
end;

procedure TWarpEditor.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Clip: TClip;
  HitIndex: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  FLastMouseX := X;

  if not GetClip(Clip) then
    Exit;

  HitIndex := HitTestMarker(Clip, X);

  if Button = mbRight then
  begin
    DeleteMarker(Clip, HitIndex);
    Exit;
  end;

  if Button <> mbLeft then
    Exit;

  FDragMarkerIndex := HitIndex;
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
var
  Clip: TClip;
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragMarkerIndex := -1;
  if GetClip(Clip) then
    RecomputeZoom(Clip); { snap the view back to fit after an edit completes }
  Invalidate;
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
  if HitIndex >= 0 then
    Exit; { hit an existing marker - use right-click to remove one instead }

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
  NewMarkers[InsertAt].SourceFrame := Round(WarpedSourcePosition(Clip.WarpMarkers, ClickFrame));
  NewMarkers[InsertAt].TimelineFrame := ClickFrame;
  for i := InsertAt to High(Clip.WarpMarkers) do
    NewMarkers[i + 1] := Clip.WarpMarkers[i];

  Clip.WarpMarkers := NewMarkers;
  SetClipData(Clip);
end;

end.
