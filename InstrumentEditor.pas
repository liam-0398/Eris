unit InstrumentEditor;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, SampleTypes, Project, Waveform;

const
  InstrumentDefaultPixelsPerSecond = 150;
  InstrumentMinPixelsPerSecond = 20;
  InstrumentMaxPixelsPerSecond = 2000;
  InstrumentZoomFactor = 1.25;
  InstrumentMinWidgetWidth = 120;
  InstrumentMaxWidgetWidth = 4000;

var
  InstrumentZoomPixelsPerSecond: Double = InstrumentDefaultPixelsPerSecond;

function InstrumentWidthForFrames(AFrameCount: Int64; ASampleRate: Integer): Integer;
procedure InstrumentZoomIn;
procedure InstrumentZoomOut;

type
  TInstrumentEditor = class(TCustomControl)
  private
    const
      MarkerGrabPixels = 6;
    var
      FTrackIndex: Integer;
      FDragWhich: Integer; { -1 none, 0 start marker, 1 end marker }
      FPlayheadFrame: Int64;
      FIsPlaying: Boolean;
      FOnChanged: TNotifyEvent;
    function GetSampleID: Integer;
    function FrameToX(AFrame: Int64; ASampleRate: Integer): Integer;
    function XToFrame(AX: Integer; ASampleRate: Integer): Int64;
    function HitTestMarker(X: Integer; ASampleRate: Integer): Integer;
    procedure DrawClipWaveform(ASampleID: Integer);
    procedure DrawMarkers(ASampleRate: Integer);
    procedure DrawPlayhead(ASampleRate: Integer);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetTrack(ATrackIndex: Integer);
    procedure SetPlayheadState(AFrame: Int64; APlaying: Boolean);
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

implementation

function InstrumentWidthForFrames(AFrameCount: Int64; ASampleRate: Integer): Integer;
begin
  if ASampleRate <= 0 then
    ASampleRate := 44100;
  Result := Round(AFrameCount * InstrumentZoomPixelsPerSecond / ASampleRate);
  if Result < InstrumentMinWidgetWidth then
    Result := InstrumentMinWidgetWidth;
  if Result > InstrumentMaxWidgetWidth then
    Result := InstrumentMaxWidgetWidth;
end;

procedure InstrumentZoomIn;
begin
  InstrumentZoomPixelsPerSecond := InstrumentZoomPixelsPerSecond * InstrumentZoomFactor;
  if InstrumentZoomPixelsPerSecond > InstrumentMaxPixelsPerSecond then
    InstrumentZoomPixelsPerSecond := InstrumentMaxPixelsPerSecond;
end;

procedure InstrumentZoomOut;
begin
  InstrumentZoomPixelsPerSecond := InstrumentZoomPixelsPerSecond / InstrumentZoomFactor;
  if InstrumentZoomPixelsPerSecond < InstrumentMinPixelsPerSecond then
    InstrumentZoomPixelsPerSecond := InstrumentMinPixelsPerSecond;
end;

constructor TInstrumentEditor.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  ControlStyle := ControlStyle + [csOpaque];
  FTrackIndex := -1;
  FDragWhich := -1;
end;

function TInstrumentEditor.GetSampleID: Integer;
begin
  if (FTrackIndex < 0) or (FTrackIndex >= Project.MaxTracks) then
    Exit(-1);
  Result := Project.TrackInstrument[FTrackIndex];
  if (Result < 0) or (Result > High(Project.SamplePool)) then
    Result := -1;
end;

function TInstrumentEditor.FrameToX(AFrame: Int64; ASampleRate: Integer): Integer;
begin
  if ASampleRate <= 0 then
    Exit(0);
  Result := Round((AFrame * InstrumentZoomPixelsPerSecond) / ASampleRate);
end;

function TInstrumentEditor.XToFrame(AX: Integer; ASampleRate: Integer): Int64;
begin
  Result := Round((Int64(AX) * ASampleRate) / InstrumentZoomPixelsPerSecond);
end;

function TInstrumentEditor.HitTestMarker(X: Integer; ASampleRate: Integer): Integer;
var
  sx, ex: Integer;
begin
  Result := -1;
  ex := FrameToX(Project.TrackInstrumentEnd[FTrackIndex], ASampleRate);
  if Abs(X - ex) <= MarkerGrabPixels then
    Exit(1);
  sx := FrameToX(Project.TrackInstrumentStart[FTrackIndex], ASampleRate);
  if Abs(X - sx) <= MarkerGrabPixels then
    Exit(0);
end;

procedure TInstrumentEditor.DrawClipWaveform(ASampleID: Integer);
var
  Sample: TSample;
begin
  Sample := Project.SamplePool[ASampleID];
  DrawWaveform(Canvas, Rect(0, 0, Width, Height), Project.SamplePeaks[ASampleID],
    Sample.FrameCount, 0, Sample.FrameCount, nil, clAqua);
end;

procedure TInstrumentEditor.DrawMarkers(ASampleRate: Integer);
var
  sx, ex: Integer;
begin
  sx := FrameToX(Project.TrackInstrumentStart[FTrackIndex], ASampleRate);
  Canvas.Pen.Color := clLime;
  Canvas.Pen.Width := 2;
  Canvas.Line(sx, 0, sx, Height);
  Canvas.Pen.Width := 1;
  Canvas.Brush.Color := clLime;
  Canvas.Polygon([Point(sx - 5, 0), Point(sx + 5, 0), Point(sx, 8)]);

  ex := FrameToX(Project.TrackInstrumentEnd[FTrackIndex], ASampleRate);
  Canvas.Pen.Color := clRed;
  Canvas.Pen.Width := 2;
  Canvas.Line(ex, 0, ex, Height);
  Canvas.Pen.Width := 1;
  Canvas.Brush.Color := clRed;
  Canvas.Polygon([Point(ex - 5, 0), Point(ex + 5, 0), Point(ex, 8)]);
end;

procedure TInstrumentEditor.DrawPlayhead(ASampleRate: Integer);
var
  x: Integer;
begin
  if not FIsPlaying then
    Exit;
  x := FrameToX(FPlayheadFrame, ASampleRate);
  Canvas.Pen.Color := clYellow;
  Canvas.Pen.Width := 2;
  Canvas.Line(x, 0, x, Height);
  Canvas.Pen.Width := 1;
end;

procedure TInstrumentEditor.Paint;
var
  SampleID: Integer;
begin
  Canvas.Brush.Color := clWindow;
  Canvas.FillRect(Rect(0, 0, Width, Height));

  SampleID := GetSampleID;
  if SampleID < 0 then
    Exit;

  DrawClipWaveform(SampleID);
  DrawMarkers(Project.SamplePool[SampleID].SampleRate);
  DrawPlayhead(Project.SamplePool[SampleID].SampleRate);
end;

procedure TInstrumentEditor.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  SampleID: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then
    Exit;
  SampleID := GetSampleID;
  if SampleID < 0 then
    Exit;
  FDragWhich := HitTestMarker(X, Project.SamplePool[SampleID].SampleRate);
end;

procedure TInstrumentEditor.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  SampleID: Integer;
  FrameCount, NewFrame: Int64;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragWhich < 0 then
    Exit;
  SampleID := GetSampleID;
  if SampleID < 0 then
    Exit;

  FrameCount := Project.SamplePool[SampleID].FrameCount;
  NewFrame := XToFrame(X, Project.SamplePool[SampleID].SampleRate);
  if NewFrame < 0 then
    NewFrame := 0;
  if NewFrame > FrameCount then
    NewFrame := FrameCount;

  if FDragWhich = 0 then
  begin
    if NewFrame >= Project.TrackInstrumentEnd[FTrackIndex] then
      NewFrame := Project.TrackInstrumentEnd[FTrackIndex] - 1;
    if NewFrame < 0 then
      NewFrame := 0;
    Project.TrackInstrumentStart[FTrackIndex] := NewFrame;
  end
  else
  begin
    if NewFrame <= Project.TrackInstrumentStart[FTrackIndex] then
      NewFrame := Project.TrackInstrumentStart[FTrackIndex] + 1;
    if NewFrame > FrameCount then
      NewFrame := FrameCount;
    Project.TrackInstrumentEnd[FTrackIndex] := NewFrame;
  end;

  if Assigned(FOnChanged) then
    FOnChanged(Self);
  Invalidate;
end;

procedure TInstrumentEditor.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragWhich := -1;
end;

procedure TInstrumentEditor.SetTrack(ATrackIndex: Integer);
begin
  FTrackIndex := ATrackIndex;
  FDragWhich := -1;
  Invalidate;
end;

procedure TInstrumentEditor.SetPlayheadState(AFrame: Int64; APlaying: Boolean);
begin
  if (AFrame = FPlayheadFrame) and (APlaying = FIsPlaying) then
    Exit;
  FPlayheadFrame := AFrame;
  FIsPlaying := APlaying;
  Invalidate;
end;

end.
