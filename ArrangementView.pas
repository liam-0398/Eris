unit ArrangementView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, FileBrowser;

type
  TFileDropEvent = procedure(Sender: TObject; ATrackIndex: Integer;
    const AFilePath: string) of object;

  TSeekEvent = procedure(Sender: TObject; AFrameOffset: Integer) of object;

  TArrangementView = class(TCustomControl)
  private
    const
      HeaderWidth = 160;
      RulerHeight = 24;
      TrackHeight = 80;
      TrackCount = 4;
      BarWidth = 96;
      BarsVisible = 32;
      ClipDisplayWidth = 300;
    var
      FOnFileDrop: TFileDropEvent;
      FOnSeek: TSeekEvent;
      FClipLabels: array[0..TrackCount - 1] of string;
      FClipFrameCounts: array[0..TrackCount - 1] of Integer;
      FActiveTrackIndex: Integer;
      FCursorFrame: Integer;
    function LaneWidth: Integer;
    function TrackIndexAtY(Y: Integer): Integer;
    function ClipRectFor(ATrackIndex: Integer): TRect;
    procedure DrawLanes;
    procedure DrawRuler;
    procedure DrawTrackHeaders;
    procedure DrawClipPlaceholders;
    procedure DrawCursor;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure DragOver(Source: TObject; X, Y: Integer; State: TDragState;
      var Accept: Boolean); override;
    procedure DragDrop(Source: TObject; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetTrackClip(ATrackIndex: Integer; const ALabel: string;
      AFrameCount: Integer);
    procedure SetCursorFrame(AFrameOffset: Integer);
    property OnFileDrop: TFileDropEvent read FOnFileDrop write FOnFileDrop;
    property OnSeek: TSeekEvent read FOnSeek write FOnSeek;
  end;

implementation

constructor TArrangementView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  ControlStyle := ControlStyle + [csOpaque];
  FActiveTrackIndex := -1;
end;

function TArrangementView.LaneWidth: Integer;
begin
  Result := Width - HeaderWidth;
end;

function TArrangementView.TrackIndexAtY(Y: Integer): Integer;
begin
  Result := (Y - RulerHeight) div TrackHeight;
  if Result < 0 then
    Result := 0
  else if Result > TrackCount - 1 then
    Result := TrackCount - 1;
end;

function TArrangementView.ClipRectFor(ATrackIndex: Integer): TRect;
var
  y, ClipWidth: Integer;
begin
  y := RulerHeight + ATrackIndex * TrackHeight;
  ClipWidth := ClipDisplayWidth;
  if ClipWidth > LaneWidth - 8 then
    ClipWidth := LaneWidth - 8;
  if ClipWidth < 0 then
    ClipWidth := 0;
  Result := Rect(4, y + 4, 4 + ClipWidth, y + TrackHeight - 4);
end;

procedure TArrangementView.DrawLanes;
var
  i, x, y: Integer;
begin
  Canvas.Brush.Color := clWindow;
  Canvas.FillRect(Rect(0, RulerHeight, LaneWidth, Height));

  Canvas.Pen.Color := clSilver;
  for i := 0 to TrackCount do
  begin
    y := RulerHeight + i * TrackHeight;
    Canvas.Line(0, y, LaneWidth, y);
  end;

  for i := 0 to BarsVisible do
  begin
    x := i * BarWidth;
    Canvas.Line(x, RulerHeight, x, Height);
  end;

  Canvas.Pen.Color := clBtnShadow;
  Canvas.Line(LaneWidth, 0, LaneWidth, Height);
end;

procedure TArrangementView.DrawRuler;
var
  i, x: Integer;
begin
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(Rect(0, 0, LaneWidth, RulerHeight));
  Canvas.Pen.Color := clBtnShadow;
  for i := 0 to BarsVisible do
  begin
    x := i * BarWidth;
    Canvas.Line(x, 0, x, RulerHeight);
    if i < BarsVisible then
      Canvas.TextOut(x + 4, 4, IntToStr(i + 1));
  end;
end;

procedure TArrangementView.DrawTrackHeaders;
var
  i, y: Integer;
begin
  for i := 0 to TrackCount - 1 do
  begin
    y := RulerHeight + i * TrackHeight;
    Canvas.Brush.Color := clBtnFace;
    Canvas.FillRect(Rect(LaneWidth, y, Width, y + TrackHeight));
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(LaneWidth, y, Width, y + TrackHeight);
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(LaneWidth + 8, y + 8, 'Track ' + IntToStr(i + 1));
    Canvas.Brush.Style := bsSolid;
  end;
end;

procedure TArrangementView.DrawClipPlaceholders;
var
  i: Integer;
  ClipRect: TRect;
begin
  for i := 0 to TrackCount - 1 do
  begin
    if FClipLabels[i] = '' then
      Continue;

    ClipRect := ClipRectFor(i);
    if ClipRect.Right <= ClipRect.Left then
      Continue;

    Canvas.Brush.Color := clAqua;
    Canvas.FillRect(ClipRect);
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(ClipRect);
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(ClipRect.Left + 4, ClipRect.Top + 4, FClipLabels[i]);
    Canvas.Brush.Style := bsSolid;
  end;
end;

procedure TArrangementView.DrawCursor;
var
  ClipRect: TRect;
  FrameCount, x: Integer;
begin
  if (FActiveTrackIndex < 0) or (FActiveTrackIndex > TrackCount - 1) then
    Exit;

  FrameCount := FClipFrameCounts[FActiveTrackIndex];
  if FrameCount <= 0 then
    Exit;

  ClipRect := ClipRectFor(FActiveTrackIndex);
  if ClipRect.Right <= ClipRect.Left then
    Exit;

  x := ClipRect.Left + Round((FCursorFrame / FrameCount) * (ClipRect.Right - ClipRect.Left));
  Canvas.Pen.Color := clRed;
  Canvas.Line(x, 0, x, Height);
end;

procedure TArrangementView.Paint;
begin
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(Rect(LaneWidth, 0, Width, RulerHeight));
  DrawLanes;
  DrawClipPlaceholders;
  DrawCursor;
  DrawRuler;
  DrawTrackHeaders;
end;

procedure TArrangementView.Resize;
begin
  inherited Resize;
  Invalidate;
end;

procedure TArrangementView.SetTrackClip(ATrackIndex: Integer;
  const ALabel: string; AFrameCount: Integer);
begin
  if (ATrackIndex < 0) or (ATrackIndex > TrackCount - 1) then
    Exit;
  FClipLabels[ATrackIndex] := ALabel;
  FClipFrameCounts[ATrackIndex] := AFrameCount;
  FActiveTrackIndex := ATrackIndex;
  FCursorFrame := 0;
  Invalidate;
end;

procedure TArrangementView.SetCursorFrame(AFrameOffset: Integer);
begin
  if FActiveTrackIndex < 0 then
    Exit;
  if AFrameOffset = FCursorFrame then
    Exit;
  FCursorFrame := AFrameOffset;
  Invalidate;
end;

procedure TArrangementView.DragOver(Source: TObject; X, Y: Integer;
  State: TDragState; var Accept: Boolean);
begin
  Accept := (Source is TControl) and (TControl(Source).Parent is TFileBrowser);
end;

procedure TArrangementView.DragDrop(Source: TObject; X, Y: Integer);
var
  Path: string;
begin
  if not ((Source is TControl) and (TControl(Source).Parent is TFileBrowser)) then
    Exit;
  Path := TFileBrowser(TControl(Source).Parent).SelectedFullPath;
  if (Path <> '') and Assigned(FOnFileDrop) then
    FOnFileDrop(Self, TrackIndexAtY(Y), Path);
end;

procedure TArrangementView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  TrackIndex, FrameCount: Integer;
  ClipRect: TRect;
  Frame: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);

  if Button <> mbLeft then
    Exit;

  TrackIndex := TrackIndexAtY(Y);
  if TrackIndex <> FActiveTrackIndex then
    Exit;

  FrameCount := FClipFrameCounts[TrackIndex];
  if FrameCount <= 0 then
    Exit;

  ClipRect := ClipRectFor(TrackIndex);
  if (X < ClipRect.Left) or (X > ClipRect.Right) or (ClipRect.Right <= ClipRect.Left) then
    Exit;

  Frame := Round(((X - ClipRect.Left) / (ClipRect.Right - ClipRect.Left)) * FrameCount);
  if Frame < 0 then
    Frame := 0
  else if Frame > FrameCount - 1 then
    Frame := FrameCount - 1;

  FCursorFrame := Frame;
  Invalidate;
  if Assigned(FOnSeek) then
    FOnSeek(Self, Frame);
end;

end.
