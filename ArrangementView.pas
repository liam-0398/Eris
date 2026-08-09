unit ArrangementView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, Forms, Controls, Graphics, LCLType, StdCtrls,
  FileBrowser, SampleTypes, Project, AudioEngine, Waveform;

type
  TFileDropEvent = procedure(Sender: TObject; ATrackIndex: Integer;
    AFramePosition: Int64; const AFilePath: string) of object;

  TSeekEvent = procedure(Sender: TObject; AFrameOffset: Int64) of object;

  TDragMode = (dmNone, dmMove, dmResizeLeft, dmResizeRight, dmRangeSelect);

  TArrangementView = class(TCustomControl)
  private
    const
      HeaderWidth = 160;
      RulerHeight = 24;
      TrackHeight = 80;
      DefaultPixelsPerSecond = 100;
      MinPixelsPerSecond = 5;
      MaxPixelsPerSecond = 3000;
      ZoomFactor = 1.25;
      EdgeGrabPixels = 6;
      ScrollBarHeight = 16;
      AutoScrollMarginPixels = 40;
      ContentEndPaddingSeconds = 10;
      VolumeSliderY = 44;
      VolumeSliderMargin = 10;
      VolumeSliderRadius = 5;
      VolumeSliderGrabPixels = 8;
      TrackVolumeMax = 2.0;
      MuteButtonSize = 16;
      MuteButtonMargin = 4;
    var
      FOnFileDrop: TFileDropEvent;
      FOnSeek: TSeekEvent;
      FOnKeyboardTrackChanged: TNotifyEvent;
      FOnClipSelectionChanged: TNotifyEvent;
      FTrackColors: array[0..Project.MaxTracks - 1] of TColor;
      FPixelsPerSecond: Double;
      FCursorFrame: Int64;
      FScrollFrame: Int64;
      FHScrollBar: TScrollBar;
      FSelectedTrack: Integer;
      FSelectedClip: Integer;
      FKeyboardTrack: Integer;
      FDragMode: TDragMode;
      FDragActive: Boolean;
      FDragTrack: Integer;
      FDragClip: Integer;
      FDragGrabOffsetFrames: Int64;
      FDragOrigClip: TClip;
      FDragCurrentClip: TClip;
      FLoopStart: Int64;
      FLoopEnd: Int64;
      FDraggingVolumeTrack: Integer;
      FGridDivision: Integer; { divisions per bar, e.g. 16 = 1/16th notes }
      FRangeSelectActive: Boolean;
      FRangeDragStartFrame: Int64;
      FRangeDragStartTrack: Integer;
      FRangeStartFrame, FRangeEndFrame: Int64;
      FRangeStartTrack, FRangeEndTrack: Integer;
    function LaneWidth: Integer;
    function ContentHeight: Integer;
    function ContentEndFrame: Int64;
    function TrackIndexAtY(Y: Integer): Integer;
    function MasterRowTop: Integer;
    function FrameToAbsoluteX(AFrame: Int64): Integer;
    function FrameToX(AFrame: Int64): Integer;
    function XToFrame(AX: Integer): Int64;
    function BeatFrames: Int64;
    function CurrentGridFrames: Int64;
    function SnapFrame(AFrame: Int64): Int64;
    function ClipPixelRect(ATrackIndex: Integer; const AClip: TClip): TRect;
    function HitTestClip(ATrackIndex: Integer; X: Integer; out AClipIndex: Integer;
      out AMode: TDragMode): Boolean;
    function VolumeKnobX(ATrackIndex: Integer): Integer;
    function XToVolume(X: Integer): Single;
    function HitTestVolumeSlider(ATrackIndex, Y: Integer): Boolean;
    function MuteButtonRect(ATrackIndex: Integer): TRect;
    procedure SelectClip(ATrack, AClip: Integer);
    procedure PushTrackToEngine(ATrackIndex: Integer);
    procedure UpdateEngineLoop;
    procedure SetScrollFrame(AFrame: Int64);
    procedure UpdateScrollBarRange;
    procedure HScrollBarChange(Sender: TObject);
    procedure DrawLanes;
    procedure DrawRuler;
    procedure DrawLoopMarkers;
    procedure DrawTrackHeaders;
    procedure DrawClips;
    procedure DrawCursor;
    procedure DrawRangeSelection;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure DragOver(Source: TObject; X, Y: Integer; State: TDragState;
      var Accept: Boolean); override;
    procedure DragDrop(Source: TObject; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure RefreshTrack(ATrackIndex: Integer);
    procedure SetCursorFrame(AFrameOffset: Int64);
    procedure ClearSelection;
    procedure ZoomIn;
    procedure ZoomOut;
    procedure SetGridDivision(ADivision: Integer);
    procedure CopySelection;
    procedure PasteSelection;
    procedure DuplicateSelection;
    procedure SplitAtCursor;
    procedure DeleteSelection;
    procedure RescaleTimeReferences(ARatio: Double);
    property KeyboardTrack: Integer read FKeyboardTrack;
    property SelectedTrack: Integer read FSelectedTrack;
    property SelectedClipIndex: Integer read FSelectedClip;
    property CursorFrame: Int64 read FCursorFrame;
    property OnFileDrop: TFileDropEvent read FOnFileDrop write FOnFileDrop;
    property OnSeek: TSeekEvent read FOnSeek write FOnSeek;
    property OnKeyboardTrackChanged: TNotifyEvent read FOnKeyboardTrackChanged
      write FOnKeyboardTrackChanged;
    property OnClipSelectionChanged: TNotifyEvent read FOnClipSelectionChanged
      write FOnClipSelectionChanged;
  end;

implementation

type
  TClipboardItem = record
    RelTrack: Integer; { 0-based offset from the base track of the copied selection }
    Clip: TClip;        { Position holds an offset relative to the selection start }
  end;

var
  ClipboardItems: array of TClipboardItem;

constructor TArrangementView.Create(AOwner: TComponent);
var
  i: Integer;
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True;
  FPixelsPerSecond := DefaultPixelsPerSecond;
  FSelectedTrack := -1;
  FSelectedClip := -1;
  FKeyboardTrack := -1;
  FLoopStart := -1;
  FLoopEnd := -1;
  FDraggingVolumeTrack := -1;
  FGridDivision := 16;
  FRangeSelectActive := False;
  FRangeStartTrack := -1;
  FRangeEndTrack := -1;

  Randomize;
  for i := 0 to Project.MaxTracks - 1 do
    FTrackColors[i] := RGBToColor(100 + Random(120), 100 + Random(120),
      100 + Random(120));

  FHScrollBar := TScrollBar.Create(Self);
  FHScrollBar.Parent := Self;
  FHScrollBar.Kind := sbHorizontal;
  FHScrollBar.OnChange := @HScrollBarChange;
end;

function TArrangementView.LaneWidth: Integer;
begin
  Result := Width - HeaderWidth;
end;

function TArrangementView.ContentHeight: Integer;
begin
  Result := Height - ScrollBarHeight;
end;

function TArrangementView.ContentEndFrame: Int64;
var
  t, i: Integer;
  EndFrame, ClipEnd: Int64;
begin
  EndFrame := 0;
  for t := 0 to Project.TrackCount - 1 do
    for i := 0 to High(Project.Tracks[t].Clips) do
    begin
      ClipEnd := Project.Tracks[t].Clips[i].Position + Project.Tracks[t].Clips[i].Length;
      if ClipEnd > EndFrame then
        EndFrame := ClipEnd;
    end;
  { pad past the furthest clip so there's always room to keep scrolling,
    like Ableton's effectively-endless arrangement canvas }
  Result := EndFrame + (Int64(ContentEndPaddingSeconds) * AudioEngine.ProjectSampleRate);
end;

function TArrangementView.MasterRowTop: Integer;
begin
  Result := RulerHeight + Project.TrackCount * TrackHeight;
end;

function TArrangementView.TrackIndexAtY(Y: Integer): Integer;
begin
  if (Y < RulerHeight) or (Y >= ContentHeight) then
    Exit(-1);
  Result := (Y - RulerHeight) div TrackHeight;
  if Result >= Project.TrackCount then
    Result := -1;
end;

function TArrangementView.FrameToAbsoluteX(AFrame: Int64): Integer;
begin
  Result := Round((AFrame * FPixelsPerSecond) / AudioEngine.ProjectSampleRate);
end;

function TArrangementView.FrameToX(AFrame: Int64): Integer;
begin
  Result := FrameToAbsoluteX(AFrame - FScrollFrame);
end;

function TArrangementView.XToFrame(AX: Integer): Int64;
begin
  Result := FScrollFrame + Round((Int64(AX) * AudioEngine.ProjectSampleRate) / FPixelsPerSecond);
end;

procedure TArrangementView.ZoomIn;
begin
  FPixelsPerSecond := FPixelsPerSecond * ZoomFactor;
  if FPixelsPerSecond > MaxPixelsPerSecond then
    FPixelsPerSecond := MaxPixelsPerSecond;
  UpdateScrollBarRange;
  Invalidate;
end;

procedure TArrangementView.ZoomOut;
begin
  FPixelsPerSecond := FPixelsPerSecond / ZoomFactor;
  if FPixelsPerSecond < MinPixelsPerSecond then
    FPixelsPerSecond := MinPixelsPerSecond;
  UpdateScrollBarRange;
  Invalidate;
end;

function TArrangementView.BeatFrames: Int64;
begin
  Result := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM);
end;

function TArrangementView.CurrentGridFrames: Int64;
begin
  Result := (BeatFrames * 4) div FGridDivision;
end;

procedure TArrangementView.SetGridDivision(ADivision: Integer);
begin
  if ADivision < 1 then
    ADivision := 1;
  FGridDivision := ADivision;
  Invalidate;
end;

function TArrangementView.SnapFrame(AFrame: Int64): Int64;
var
  Grid: Int64;
begin
  Grid := CurrentGridFrames;
  if Grid <= 0 then
    Exit(AFrame);
  Result := Round(AFrame / Grid) * Grid;
end;

function TArrangementView.ClipPixelRect(ATrackIndex: Integer;
  const AClip: TClip): TRect;
var
  y: Integer;
begin
  y := RulerHeight + ATrackIndex * TrackHeight;
  Result := Rect(FrameToX(AClip.Position), y + 4,
    FrameToX(AClip.Position + AClip.Length), y + TrackHeight - 4);
end;

function TArrangementView.HitTestClip(ATrackIndex: Integer; X: Integer;
  out AClipIndex: Integer; out AMode: TDragMode): Boolean;
var
  i: Integer;
  R: TRect;
begin
  AClipIndex := -1;
  AMode := dmNone;
  Result := False;
  for i := 0 to High(Project.Tracks[ATrackIndex].Clips) do
  begin
    R := ClipPixelRect(ATrackIndex, Project.Tracks[ATrackIndex].Clips[i]);
    if (X < R.Left - EdgeGrabPixels) or (X > R.Right + EdgeGrabPixels) then
      Continue;

    AClipIndex := i;
    if Abs(X - R.Left) <= EdgeGrabPixels then
      AMode := dmResizeLeft
    else if Abs(X - R.Right) <= EdgeGrabPixels then
      AMode := dmResizeRight
    else if (X >= R.Left) and (X <= R.Right) then
      AMode := dmMove
    else
      Continue;

    Result := True;
    Exit;
  end;
end;

function TArrangementView.VolumeKnobX(ATrackIndex: Integer): Integer;
var
  Range: Integer;
  Value: Single;
begin
  Range := (Width - VolumeSliderMargin) - (LaneWidth + VolumeSliderMargin);
  Value := Project.TrackVolume[ATrackIndex] / TrackVolumeMax;
  if Value < 0 then
    Value := 0;
  if Value > 1 then
    Value := 1;
  Result := (LaneWidth + VolumeSliderMargin) + Round(Value * Range);
end;

function TArrangementView.XToVolume(X: Integer): Single;
var
  Range: Integer;
  Frac: Single;
begin
  Range := (Width - VolumeSliderMargin) - (LaneWidth + VolumeSliderMargin);
  if Range <= 0 then
    Exit(1.0);
  Frac := (X - (LaneWidth + VolumeSliderMargin)) / Range;
  if Frac < 0 then
    Frac := 0;
  if Frac > 1 then
    Frac := 1;
  Result := Frac * TrackVolumeMax;
end;

function TArrangementView.HitTestVolumeSlider(ATrackIndex, Y: Integer): Boolean;
var
  SliderY: Integer;
begin
  SliderY := RulerHeight + ATrackIndex * TrackHeight + VolumeSliderY;
  Result := Abs(Y - SliderY) <= VolumeSliderGrabPixels;
end;

function TArrangementView.MuteButtonRect(ATrackIndex: Integer): TRect;
var
  y: Integer;
begin
  y := RulerHeight + ATrackIndex * TrackHeight;
  Result := Rect(Width - MuteButtonSize - MuteButtonMargin, y + MuteButtonMargin,
    Width - MuteButtonMargin, y + MuteButtonMargin + MuteButtonSize);
end;

procedure TArrangementView.SelectClip(ATrack, AClip: Integer);
begin
  if (ATrack = FSelectedTrack) and (AClip = FSelectedClip) then
    Exit;
  FSelectedTrack := ATrack;
  FSelectedClip := AClip;
  if Assigned(FOnClipSelectionChanged) then
    FOnClipSelectionChanged(Self);
end;

procedure TArrangementView.PushTrackToEngine(ATrackIndex: Integer);
var
  Items: PPlaybackClip;
  i, j, MarkerCount: Integer;
  Clip: TClip;
  Sample: TSample;
  Count: Integer;
begin
  Count := Length(Project.Tracks[ATrackIndex].Clips);
  if Count = 0 then
    Items := nil
  else
    GetMem(Items, Count * SizeOf(TPlaybackClip));

  for i := 0 to Count - 1 do
  begin
    Clip := Project.Tracks[ATrackIndex].Clips[i];
    Sample := Project.SamplePool[Clip.SampleID];
    Items[i].Data := Sample.Data;
    Items[i].FrameCount := Sample.FrameCount;
    Items[i].Channels := Sample.Channels;
    Items[i].Offset := Clip.Offset;
    Items[i].Length := Clip.Length;
    Items[i].Position := Clip.Position;
    Items[i].Gain := Clip.Gain * Project.TrackVolume[ATrackIndex];
    Items[i].WarpMode := Clip.WarpMode;
    Items[i].DetuneSemitones := Clip.PitchSemitones;

    MarkerCount := Length(Clip.WarpMarkers);
    if MarkerCount > MaxClipWarpMarkers then
      MarkerCount := MaxClipWarpMarkers;
    Items[i].MarkerCount := MarkerCount;
    for j := 0 to MarkerCount - 1 do
    begin
      Items[i].MarkerSource[j] := Clip.WarpMarkers[j].SourceFrame;
      Items[i].MarkerTimeline[j] := Clip.WarpMarkers[j].TimelineFrame;
    end;
  end;

  AudioEngineSetTrackClips(ATrackIndex, Items, Count);
end;

procedure TArrangementView.UpdateEngineLoop;
begin
  if (FLoopStart >= 0) and (FLoopEnd >= 0) and (FLoopEnd > FLoopStart) then
    AudioEngineSetLoop(FLoopStart, FLoopEnd)
  else
    AudioEngineClearLoop;
end;

procedure TArrangementView.SetScrollFrame(AFrame: Int64);
var
  MaxFrame: Int64;
begin
  if AFrame < 0 then
    AFrame := 0;
  MaxFrame := ContentEndFrame;
  if AFrame > MaxFrame then
    AFrame := MaxFrame;
  if AFrame = FScrollFrame then
    Exit;
  FScrollFrame := AFrame;
  UpdateScrollBarRange;
  Invalidate;
end;

procedure TArrangementView.UpdateScrollBarRange;
var
  TotalPixels, Page: Integer;
begin
  if not Assigned(FHScrollBar) then
    Exit;
  TotalPixels := FrameToAbsoluteX(ContentEndFrame);
  Page := LaneWidth;
  if Page < 1 then
    Page := 1;
  if TotalPixels < Page then
    TotalPixels := Page;

  FHScrollBar.Min := 0;
  FHScrollBar.Max := TotalPixels;
  FHScrollBar.PageSize := Page;
  FHScrollBar.SmallChange := AutoScrollMarginPixels;
  FHScrollBar.LargeChange := Page;
  FHScrollBar.Position := FrameToAbsoluteX(FScrollFrame);
end;

procedure TArrangementView.HScrollBarChange(Sender: TObject);
var
  NewFrame: Int64;
begin
  NewFrame := Round((Int64(FHScrollBar.Position) * AudioEngine.ProjectSampleRate) /
    FPixelsPerSecond);
  SetScrollFrame(NewFrame);
end;

procedure TArrangementView.DrawLanes;
var
  i, x: Integer;
  y: Integer;
  Grid, Frame: Int64;
begin
  Canvas.Brush.Color := clWindow;
  Canvas.FillRect(Rect(0, RulerHeight, LaneWidth, ContentHeight));

  Canvas.Pen.Color := clSilver;
  for i := 0 to Project.TrackCount + 1 do
  begin
    y := RulerHeight + i * TrackHeight;
    Canvas.Line(0, y, LaneWidth, y);
  end;

  Grid := CurrentGridFrames;
  if Grid > 0 then
  begin
    Frame := 0;
    x := FrameToX(Frame);
    while x < LaneWidth do
    begin
      Canvas.Line(x, RulerHeight, x, ContentHeight);
      Frame := Frame + Grid;
      x := FrameToX(Frame);
    end;
  end;

  Canvas.Pen.Color := clBtnShadow;
  Canvas.Line(LaneWidth, 0, LaneWidth, ContentHeight);
end;

procedure TArrangementView.DrawRuler;
var
  BarF: Int64;
  x, BarNum: Integer;
begin
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(Rect(0, 0, LaneWidth, RulerHeight));
  Canvas.Pen.Color := clBtnShadow;

  BarF := BeatFrames * 4;
  if BarF <= 0 then
    Exit;

  BarNum := 0;
  x := 0;
  while x < LaneWidth do
  begin
    Canvas.Line(x, 0, x, RulerHeight);
    Canvas.TextOut(x + 4, 4, IntToStr(BarNum + 1));
    Inc(BarNum);
    x := FrameToX(BarNum * BarF);
  end;
end;

procedure TArrangementView.DrawLoopMarkers;
var
  xs, xe: Integer;
begin
  if (FLoopStart >= 0) and (FLoopEnd >= 0) then
  begin
    xs := FrameToX(FLoopStart);
    xe := FrameToX(FLoopEnd);
    if (xe >= 0) and (xs <= LaneWidth) then
    begin
      Canvas.Brush.Color := clYellow;
      Canvas.Brush.Style := bsSolid;
      Canvas.Pen.Style := psClear;
      Canvas.Rectangle(Max(xs, 0), 2, Min(xe, LaneWidth), 6);
      Canvas.Pen.Style := psSolid;
    end;
  end;

  if FLoopStart >= 0 then
  begin
    xs := FrameToX(FLoopStart);
    if (xs >= 0) and (xs <= LaneWidth) then
    begin
      Canvas.Pen.Color := clGreen;
      Canvas.Pen.Width := 2;
      Canvas.Line(xs, 0, xs, ContentHeight);
      Canvas.Pen.Width := 1;
      Canvas.Brush.Color := clGreen;
      Canvas.Polygon([Point(xs - 5, 0), Point(xs + 5, 0), Point(xs, 8)]);
    end;
  end;

  if FLoopEnd >= 0 then
  begin
    xe := FrameToX(FLoopEnd);
    if (xe >= 0) and (xe <= LaneWidth) then
    begin
      Canvas.Pen.Color := $0080FF;
      Canvas.Pen.Width := 2;
      Canvas.Line(xe, 0, xe, ContentHeight);
      Canvas.Pen.Width := 1;
      Canvas.Brush.Color := $0080FF;
      Canvas.Polygon([Point(xe - 5, 0), Point(xe + 5, 0), Point(xe, 8)]);
    end;
  end;
end;

procedure TArrangementView.DrawTrackHeaders;
var
  i, y, SliderY, kx: Integer;
  MuteRect: TRect;
begin
  for i := 0 to Project.TrackCount - 1 do
  begin
    y := RulerHeight + i * TrackHeight;
    if i = FKeyboardTrack then
      Canvas.Brush.Color := clGray
    else
      Canvas.Brush.Color := clBtnFace;
    Canvas.FillRect(Rect(LaneWidth, y, Width, y + TrackHeight));
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(LaneWidth, y, Width, y + TrackHeight);
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(LaneWidth + 8, y + 8, 'Track ' + IntToStr(i + 1));
    Canvas.Brush.Style := bsSolid;

    { simple on/off mute toggle }
    MuteRect := MuteButtonRect(i);
    if Project.TrackEnabled[i] then
      Canvas.Brush.Color := clLime
    else
      Canvas.Brush.Color := clRed;
    Canvas.Pen.Color := clBlack;
    Canvas.Rectangle(MuteRect);

    { simple volume slider - a plain line with a draggable knob, no readout }
    SliderY := y + VolumeSliderY;
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Line(LaneWidth + VolumeSliderMargin, SliderY, Width - VolumeSliderMargin, SliderY);
    kx := VolumeKnobX(i);
    Canvas.Brush.Color := clHighlight;
    Canvas.Pen.Color := clWindowFrame;
    Canvas.Ellipse(kx - VolumeSliderRadius, SliderY - VolumeSliderRadius,
      kx + VolumeSliderRadius, SliderY + VolumeSliderRadius);
  end;

  { master bus row, always the last row, below every real track - no clips,
    mute, or volume slider, just a click target for the master effects chain }
  y := MasterRowTop;
  if FKeyboardTrack = -2 then
    Canvas.Brush.Color := clGray
  else
    Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(Rect(LaneWidth, y, Width, y + TrackHeight));
  Canvas.Pen.Color := clBtnShadow;
  Canvas.Rectangle(LaneWidth, y, Width, y + TrackHeight);
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Style := [fsBold];
  Canvas.TextOut(LaneWidth + 8, y + 8, 'Master');
  Canvas.Font.Style := [];
  Canvas.Brush.Style := bsSolid;
end;

procedure TArrangementView.DrawClips;
var
  t, i: Integer;
  Clip: TClip;
  R: TRect;
  IsSelected, IsDragging: Boolean;
  ClipName: string;
begin
  for t := 0 to Project.TrackCount - 1 do
    for i := 0 to High(Project.Tracks[t].Clips) do
    begin
      IsDragging := FDragActive and (FDragMode <> dmNone) and (t = FDragTrack) and
        (i = FDragClip);
      if IsDragging then
        Clip := FDragCurrentClip
      else
        Clip := Project.Tracks[t].Clips[i];

      R := ClipPixelRect(t, Clip);
      if (R.Right < 0) or (R.Left > LaneWidth) then
        Continue;

      IsSelected := (t = FSelectedTrack) and (i = FSelectedClip);

      { neutral dark interior so the waveform (drawn in the track's color)
        reads clearly against it, full width - no horizontal border/inset }
      Canvas.Brush.Color := clBlack;
      Canvas.FillRect(R);
      if Clip.SampleID <= High(Project.SamplePeaks) then
        DrawWaveform(Canvas, Rect(R.Left, R.Top + 14, R.Right, R.Bottom),
          Project.SamplePeaks[Clip.SampleID],
          Project.SamplePool[Clip.SampleID].FrameCount, Clip.Offset,
          Clip.Offset + Clip.Length, Clip.WarpMarkers, FTrackColors[t], Clip.WarpMode);

      { border only (Frame, not Rectangle - Rectangle also fills the
        interior with the current brush, which would erase the waveform
        just drawn) }
      if IsSelected then
        Canvas.Pen.Color := clRed
      else
        Canvas.Pen.Color := FTrackColors[t];
      Canvas.Pen.Width := 2;
      Canvas.Frame(R);
      Canvas.Pen.Width := 1;

      Canvas.Brush.Style := bsClear;
      Canvas.Font.Color := clWhite;
      if Clip.SampleID <= High(Project.SampleNames) then
        ClipName := Project.SampleNames[Clip.SampleID]
      else
        ClipName := '';
      Canvas.TextOut(R.Left + 4, R.Top + 2, ClipName);
      Canvas.Font.Color := clWindowText;
      Canvas.Brush.Style := bsSolid;
    end;
end;

procedure TArrangementView.DrawCursor;
var
  x: Integer;
begin
  x := FrameToX(FCursorFrame);
  if (x < 0) or (x >= LaneWidth) then
    Exit;
  Canvas.Pen.Color := clRed;
  Canvas.Line(x, 0, x, ContentHeight);
end;

procedure TArrangementView.DrawRangeSelection;
var
  xs, xe, yTop, yBottom, t1, t2: Integer;
begin
  if not FRangeSelectActive then
    Exit;
  if (FRangeStartTrack < 0) or (FRangeEndTrack < 0) then
    Exit;

  t1 := Min(FRangeStartTrack, FRangeEndTrack);
  t2 := Max(FRangeStartTrack, FRangeEndTrack);

  xs := FrameToX(Min(FRangeStartFrame, FRangeEndFrame));
  xe := FrameToX(Max(FRangeStartFrame, FRangeEndFrame));
  if (xe < 0) or (xs > LaneWidth) then
    Exit;
  xs := Max(xs, 0);
  xe := Min(xe, LaneWidth);

  yTop := RulerHeight + t1 * TrackHeight;
  yBottom := RulerHeight + (t2 + 1) * TrackHeight;

  { drawn before DrawClips so clips still render normally on top - only the
    empty lane background under/around them gets the highlight tint }
  Canvas.Brush.Color := clHighlight;
  Canvas.Brush.Style := bsSolid;
  Canvas.Pen.Color := clHighlight;
  Canvas.Rectangle(xs, yTop, xe, yBottom);
end;

procedure TArrangementView.Paint;
begin
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(Rect(LaneWidth, 0, Width, RulerHeight));
  Canvas.FillRect(Rect(0, ContentHeight, Width, Height));
  DrawLanes;
  DrawRangeSelection;
  DrawClips;
  DrawCursor;
  DrawRuler;
  DrawLoopMarkers;
  DrawTrackHeaders;
end;

procedure TArrangementView.Resize;
begin
  inherited Resize;
  if Assigned(FHScrollBar) then
  begin
    FHScrollBar.SetBounds(0, ContentHeight, LaneWidth, ScrollBarHeight);
    UpdateScrollBarRange;
  end;
  Invalidate;
end;

procedure TArrangementView.RefreshTrack(ATrackIndex: Integer);
begin
  PushTrackToEngine(ATrackIndex);
  UpdateScrollBarRange;
  Invalidate;
end;

procedure TArrangementView.SetCursorFrame(AFrameOffset: Int64);
var
  x: Integer;
  MarginFrames: Int64;
begin
  if AFrameOffset = FCursorFrame then
    Exit;
  FCursorFrame := AFrameOffset;

  x := FrameToX(AFrameOffset);
  if (x < 0) or (x >= LaneWidth) then
  begin
    MarginFrames := Round(Int64(AutoScrollMarginPixels) * AudioEngine.ProjectSampleRate /
      FPixelsPerSecond);
    SetScrollFrame(AFrameOffset - MarginFrames);
  end;

  Invalidate;
end;

procedure TArrangementView.ClearSelection;
begin
  SelectClip(-1, -1);
  Invalidate;
end;

{ Companion to Project.RescaleForTempoChange - the clips moved, so the
  cursor and loop points (frame positions this view owns, not Project's)
  need to move by the same ratio to stay at the same musical position
  rather than pointing at whatever now happens to be at their old frame. }
procedure TArrangementView.RescaleTimeReferences(ARatio: Double);
begin
  if FLoopStart >= 0 then
    FLoopStart := Round(FLoopStart * ARatio);
  if FLoopEnd >= 0 then
    FLoopEnd := Round(FLoopEnd * ARatio);
  UpdateEngineLoop;

  FCursorFrame := Round(FCursorFrame * ARatio);
  AudioEngineSeek(FCursorFrame);

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
  TrackIndex: Integer;
begin
  if not ((Source is TControl) and (TControl(Source).Parent is TFileBrowser)) then
    Exit;
  Path := TFileBrowser(TControl(Source).Parent).SelectedFullPath;
  if Path = '' then
    Exit;

  TrackIndex := TrackIndexAtY(Y);
  if TrackIndex < 0 then
    TrackIndex := 0;

  if Assigned(FOnFileDrop) then
    FOnFileDrop(Self, TrackIndex, SnapFrame(XToFrame(X)), Path);
end;

procedure TArrangementView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  TrackIndex, ClipIndex: Integer;
  Mode: TDragMode;
  Frame: Int64;
begin
  inherited MouseDown(Button, Shift, X, Y);

  if CanFocus then
    SetFocus;

  if Button = mbRight then
  begin
    if Y < RulerHeight then
    begin
      if (FLoopStart >= 0) and (FLoopEnd >= 0) then
      begin
        FLoopStart := -1;
        FLoopEnd := -1;
      end
      else if FLoopStart < 0 then
      begin
        Frame := SnapFrame(XToFrame(X));
        if Frame < 0 then
          Frame := 0;
        FLoopStart := Frame;
      end
      else
      begin
        Frame := SnapFrame(XToFrame(X));
        if Frame < 0 then
          Frame := 0;
        if Frame < FLoopStart then
        begin
          FLoopEnd := FLoopStart;
          FLoopStart := Frame;
        end
        else if Frame > FLoopStart then
          FLoopEnd := Frame;
      end;
      UpdateEngineLoop;
      Invalidate;
    end;
    Exit;
  end;

  if Button <> mbLeft then
    Exit;

  if (X >= LaneWidth) and (Y >= MasterRowTop) and (Y < MasterRowTop + TrackHeight) then
  begin
    SelectClip(-1, -1);
    if FKeyboardTrack <> -2 then
    begin
      FKeyboardTrack := -2;
      if Assigned(FOnKeyboardTrackChanged) then
        FOnKeyboardTrackChanged(Self);
    end;
    Invalidate;
    Exit;
  end;

  TrackIndex := TrackIndexAtY(Y);

  if (TrackIndex >= 0) and (X >= LaneWidth) and
    PtInRect(MuteButtonRect(TrackIndex), Point(X, Y)) then
  begin
    Project.TrackEnabled[TrackIndex] := not Project.TrackEnabled[TrackIndex];
    Invalidate;
    Exit;
  end;

  if (TrackIndex >= 0) and (X >= LaneWidth) and HitTestVolumeSlider(TrackIndex, Y) then
  begin
    FDraggingVolumeTrack := TrackIndex;
    Project.TrackVolume[TrackIndex] := XToVolume(X);
    PushTrackToEngine(TrackIndex);
    Invalidate;
    Exit;
  end;

  if TrackIndex < 0 then
  begin
    SelectClip(-1, -1);
    FRangeSelectActive := False;
    Frame := SnapFrame(XToFrame(X));
    if Frame < 0 then
      Frame := 0;
    FCursorFrame := Frame;
    Invalidate;
    if Assigned(FOnSeek) then
      FOnSeek(Self, Frame);
    Exit;
  end;

  if TrackIndex <> FKeyboardTrack then
  begin
    FKeyboardTrack := TrackIndex;
    if Assigned(FOnKeyboardTrackChanged) then
      FOnKeyboardTrackChanged(Self);
  end;

  if HitTestClip(TrackIndex, X, ClipIndex, Mode) then
  begin
    FRangeSelectActive := False;
    SelectClip(TrackIndex, ClipIndex);
    FDragMode := Mode;
    FDragActive := True;
    FDragTrack := TrackIndex;
    FDragClip := ClipIndex;
    FDragOrigClip := Project.Tracks[TrackIndex].Clips[ClipIndex];
    FDragCurrentClip := FDragOrigClip;
    if Mode = dmMove then
      FDragGrabOffsetFrames := XToFrame(X) - FDragOrigClip.Position;
    Project.PushUndoSnapshot(TrackIndex);
    Invalidate;
  end
  else
  begin
    SelectClip(-1, -1);
    Frame := SnapFrame(XToFrame(X));
    if Frame < 0 then
      Frame := 0;
    FCursorFrame := Frame;

    { clicking empty lane space seeks immediately (unchanged); it also
      arms a potential time-range selection drag, same as Ableton - a plain
      click leaves no visible range (MouseMove below is what actually turns
      this into a real selection), a click-drag selects [start,end) across
      whichever tracks the drag crosses }
    FDragMode := dmRangeSelect;
    FDragActive := True;
    FRangeSelectActive := False;
    FRangeDragStartFrame := Frame;
    FRangeDragStartTrack := TrackIndex;

    Invalidate;
    if Assigned(FOnSeek) then
      FOnSeek(Self, Frame);
  end;
end;

procedure TArrangementView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  MouseFrame, NewPosition, NewEnd, MinPos, MaxPos, MinEnd, Delta: Int64;
  FreePlacement: Boolean;
  TargetTrack, Row: Integer;
begin
  inherited MouseMove(Shift, X, Y);

  if FDraggingVolumeTrack >= 0 then
  begin
    Project.TrackVolume[FDraggingVolumeTrack] := XToVolume(X);
    PushTrackToEngine(FDraggingVolumeTrack);
    Invalidate;
    Exit;
  end;

  if not FDragActive then
    Exit;

  { Ctrl bypasses grid snapping for free/unbounded placement while dragging -
    kept distinct from Shift, which (on a resize handle, see MouseUp) means
    something else entirely: enforce the elastic Re-Pitch warp stretch. }
  FreePlacement := ssCtrl in Shift;
  MouseFrame := XToFrame(X);

  case FDragMode of
    dmMove:
      begin
        NewPosition := MouseFrame - FDragGrabOffsetFrames;
        if not FreePlacement then
          NewPosition := SnapFrame(NewPosition);
        if NewPosition < 0 then
          NewPosition := 0;
        FDragCurrentClip.Position := NewPosition;

        TargetTrack := TrackIndexAtY(Y);
        if TargetTrack >= 0 then
          FDragTrack := TargetTrack;
      end;
    dmResizeLeft:
      begin
        NewPosition := MouseFrame;
        if not FreePlacement then
          NewPosition := SnapFrame(NewPosition);
        MinPos := FDragOrigClip.Position - FDragOrigClip.Offset;
        MaxPos := FDragOrigClip.Position + FDragOrigClip.Length - 1;
        if NewPosition < MinPos then
          NewPosition := MinPos;
        if NewPosition > MaxPos then
          NewPosition := MaxPos;

        Delta := NewPosition - FDragOrigClip.Position;
        FDragCurrentClip.Position := NewPosition;
        FDragCurrentClip.Offset := FDragOrigClip.Offset + Delta;
        FDragCurrentClip.Length := FDragOrigClip.Length - Delta;
      end;
    dmResizeRight:
      begin
        { no upper bound: dragging past the end of the underlying sample data
          just extends the clip into silence, useful for lining clips up
          without needing extra source audio }
        NewEnd := MouseFrame;
        if not FreePlacement then
          NewEnd := SnapFrame(NewEnd);
        MinEnd := FDragOrigClip.Position + 1;
        if NewEnd < MinEnd then
          NewEnd := MinEnd;

        FDragCurrentClip.Length := NewEnd - FDragOrigClip.Position;
      end;
    dmRangeSelect:
      begin
        FRangeStartFrame := FRangeDragStartFrame;
        FRangeEndFrame := SnapFrame(MouseFrame);
        if FRangeEndFrame < 0 then
          FRangeEndFrame := 0;

        Row := (Y - RulerHeight) div TrackHeight;
        if Row < 0 then
          Row := 0;
        if Row > Project.TrackCount - 1 then
          Row := Project.TrackCount - 1;
        FRangeStartTrack := FRangeDragStartTrack;
        FRangeEndTrack := Row;

        if FRangeEndFrame <> FRangeStartFrame then
          FRangeSelectActive := True;
      end;
  else
    Exit;
  end;

  Invalidate;
end;

procedure TArrangementView.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  OrigTrack: Integer;
  DiscardMarkers: TWarpMarkerArray;
  SplitRel: Int64;
begin
  inherited MouseUp(Button, Shift, X, Y);

  FDraggingVolumeTrack := -1;

  if not FDragActive then
    Exit;

  OrigTrack := FSelectedTrack;

  case FDragMode of
    dmMove:
      begin
        if OrigTrack <> FDragTrack then
          Project.PushUndoSnapshot(FDragTrack);
        Project.RemoveClipAt(OrigTrack, FDragClip);
        Project.CommitClipToTrack(FDragTrack, FDragCurrentClip);
        SelectClip(FDragTrack, High(Project.Tracks[FDragTrack].Clips));
        if OrigTrack <> FDragTrack then
          PushTrackToEngine(OrigTrack);
        PushTrackToEngine(FDragTrack);
      end;
    dmResizeLeft:
      begin
        if ssShift in Shift then
        begin
          { elastic resize (the old always-on behavior, now an explicit
            opt-in): keep playing the exact same full original source
            window, just stretch/squeeze it to fit the new duration - Offset
            stays put, only the far marker's TimelineFrame rescales. }
          FDragCurrentClip.Offset := FDragOrigClip.Offset;
          FDragCurrentClip.Length := FDragOrigClip.Position + FDragOrigClip.Length -
            FDragCurrentClip.Position;
          if Length(FDragOrigClip.WarpMarkers) >= 2 then
          begin
            FDragCurrentClip.WarpMarkers := Copy(FDragOrigClip.WarpMarkers, 0,
              Length(FDragOrigClip.WarpMarkers));
            FDragCurrentClip.WarpMarkers[High(FDragCurrentClip.WarpMarkers)].TimelineFrame :=
              FDragCurrentClip.Length;
          end
          else
            FDragCurrentClip.WarpMarkers := FDragOrigClip.WarpMarkers;
        end
        else
        begin
          { default: plain truncate - Offset/Position moved forward,
            equivalent to the right half of a split at the trimmed-away
            point, so carry the matching (rebased) warp markers across
            instead of discarding them (which would silently drop the pitch/
            warp on what remains). The returned split frame may differ
            slightly from the drag position (see SplitWarpMarkers) - align
            the clip's own geometry to it too so the markers and geometry
            stay consistent. }
          SplitRel := SplitWarpMarkers(FDragOrigClip.WarpMarkers,
            FDragCurrentClip.Position - FDragOrigClip.Position, DiscardMarkers,
            FDragCurrentClip.WarpMarkers, FDragOrigClip.WarpMode);
          FDragCurrentClip.Offset := FDragOrigClip.Offset + SplitRel;
          FDragCurrentClip.Position := FDragOrigClip.Position + SplitRel;
          FDragCurrentClip.Length := FDragOrigClip.Length - SplitRel;
        end;
        Project.Tracks[FDragTrack].Clips[FDragClip] := FDragCurrentClip;
        PushTrackToEngine(FDragTrack);
      end;
    dmResizeRight:
      begin
        if ssShift in Shift then
        begin
          { elastic resize (the old always-on behavior, now an explicit
            opt-in): keep the warp end marker (if any) in step with the new
            length, equivalent to dragging the warp editor's end marker -
            stretches/squeezes the same source content to fit. Copy first -
            dynamic arrays are refcounted, and mutating a shared element in
            place would corrupt the undo snapshot and the live Project data. }
          if Length(FDragCurrentClip.WarpMarkers) >= 2 then
          begin
            FDragCurrentClip.WarpMarkers := Copy(FDragCurrentClip.WarpMarkers, 0,
              Length(FDragCurrentClip.WarpMarkers));
            FDragCurrentClip.WarpMarkers[High(FDragCurrentClip.WarpMarkers)].TimelineFrame :=
              FDragCurrentClip.Length;
          end;
        end;
        { default (no shift): plain truncate/extend - only the far edge
          moves, so clip-relative frame 0 still means the same thing and the
          existing warp markers need no rebasing at all; just leave them as
          they already are (still FDragOrigClip's, untouched since
          MouseMove only ever changes Length for this drag mode) and let
          Length do the cutting/extending at whatever rate was already
          playing. }
        Project.Tracks[FDragTrack].Clips[FDragClip] := FDragCurrentClip;
        PushTrackToEngine(FDragTrack);
      end;
  end;

  FDragActive := False;
  FDragMode := dmNone;
  Invalidate;
end;

{ Extracts whatever portion of AClip falls inside [ARangeStart, ARangeEnd),
  trimming its warp markers to match exactly like a real split would - used
  by both range-select copy and range-select duplicate. Returns False if
  AClip doesn't overlap the range at all. }
function ExtractClipInRange(const AClip: TClip; ARangeStart, ARangeEnd: Int64;
  out AResult: TClip): Boolean;
var
  ClipEnd, NewStart, NewEnd, SplitRel: Int64;
  DiscardMarkers, KeptMarkers: TWarpMarkerArray;
begin
  ClipEnd := AClip.Position + AClip.Length;
  if (ClipEnd <= ARangeStart) or (AClip.Position >= ARangeEnd) then
    Exit(False);

  AResult := AClip;
  NewStart := Max(AClip.Position, ARangeStart);
  NewEnd := Min(ClipEnd, ARangeEnd);

  if NewStart > AClip.Position then
  begin
    SplitRel := SplitWarpMarkers(AClip.WarpMarkers, NewStart - AClip.Position,
      DiscardMarkers, KeptMarkers, AClip.WarpMode);
    AResult.WarpMarkers := KeptMarkers;
    AResult.Offset := AClip.Offset + SplitRel;
    AResult.Position := AClip.Position + SplitRel;
  end;

  if NewEnd < ClipEnd then
  begin
    SplitRel := SplitWarpMarkers(AResult.WarpMarkers, NewEnd - AResult.Position,
      KeptMarkers, DiscardMarkers, AClip.WarpMode);
    AResult.WarpMarkers := KeptMarkers;
    AResult.Length := SplitRel;
  end
  else
    AResult.Length := ClipEnd - AResult.Position;

  Result := True;
end;

procedure TArrangementView.CopySelection;
var
  t1, t2, t, i: Integer;
  RangeStart, RangeEnd: Int64;
  Extracted: TClip;
begin
  ClipboardItems := nil;

  if FRangeSelectActive then
  begin
    t1 := Min(FRangeStartTrack, FRangeEndTrack);
    t2 := Max(FRangeStartTrack, FRangeEndTrack);
    RangeStart := Min(FRangeStartFrame, FRangeEndFrame);
    RangeEnd := Max(FRangeStartFrame, FRangeEndFrame);
    if RangeEnd <= RangeStart then
      Exit;

    for t := t1 to t2 do
      for i := 0 to High(Project.Tracks[t].Clips) do
        if ExtractClipInRange(Project.Tracks[t].Clips[i], RangeStart, RangeEnd,
          Extracted) then
        begin
          Extracted.Position := Extracted.Position - RangeStart;
          SetLength(ClipboardItems, Length(ClipboardItems) + 1);
          ClipboardItems[High(ClipboardItems)].RelTrack := t - t1;
          ClipboardItems[High(ClipboardItems)].Clip := Extracted;
        end;
  end
  else if (FSelectedTrack >= 0) and (FSelectedClip >= 0) and
    (FSelectedClip <= High(Project.Tracks[FSelectedTrack].Clips)) then
  begin
    Extracted := Project.Tracks[FSelectedTrack].Clips[FSelectedClip];
    Extracted.Position := 0;
    SetLength(ClipboardItems, 1);
    ClipboardItems[0].RelTrack := 0;
    ClipboardItems[0].Clip := Extracted;
  end;
end;

procedure TArrangementView.PasteSelection;
var
  i, BaseTrack, TargetTrack: Integer;
  NewClip: TClip;
  Snapshotted: array[0..Project.MaxTracks - 1] of Boolean;
begin
  if Length(ClipboardItems) = 0 then
    Exit;
  BaseTrack := FKeyboardTrack;
  if BaseTrack < 0 then
    Exit;

  FillChar(Snapshotted, SizeOf(Snapshotted), 0);

  for i := 0 to High(ClipboardItems) do
  begin
    TargetTrack := BaseTrack + ClipboardItems[i].RelTrack;
    if (TargetTrack < 0) or (TargetTrack >= Project.TrackCount) then
      Continue;
    if not Snapshotted[TargetTrack] then
    begin
      Project.PushUndoSnapshot(TargetTrack);
      Snapshotted[TargetTrack] := True;
    end;
    NewClip := ClipboardItems[i].Clip;
    NewClip.Position := FCursorFrame + NewClip.Position;
    NewClip.TrackID := TargetTrack;
    Project.CommitClipToTrack(TargetTrack, NewClip);
    PushTrackToEngine(TargetTrack);
  end;
  Invalidate;
end;

procedure TArrangementView.DuplicateSelection;
var
  t1, t2, t, i: Integer;
  RangeStart, RangeEnd, Span: Int64;
  Extracted, NewClip: TClip;
  Snapshotted: array[0..Project.MaxTracks - 1] of Boolean;
  SrcClips: TClipArray;
begin
  if FRangeSelectActive then
  begin
    t1 := Min(FRangeStartTrack, FRangeEndTrack);
    t2 := Max(FRangeStartTrack, FRangeEndTrack);
    RangeStart := Min(FRangeStartFrame, FRangeEndFrame);
    RangeEnd := Max(FRangeStartFrame, FRangeEndFrame);
    if RangeEnd <= RangeStart then
      Exit;
    Span := RangeEnd - RangeStart;

    FillChar(Snapshotted, SizeOf(Snapshotted), 0);
    for t := t1 to t2 do
    begin
      { snapshot first - CommitClipToTrack below reassigns/reorders
        Project.Tracks[t].Clips (it overwrites whatever the duplicate lands
        on), so iterating that array live while also mutating it would skip
        or misread entries for any track with more than one clip in range }
      SrcClips := Copy(Project.Tracks[t].Clips, 0, Length(Project.Tracks[t].Clips));
      for i := 0 to High(SrcClips) do
        if ExtractClipInRange(SrcClips[i], RangeStart, RangeEnd, Extracted) then
        begin
          if not Snapshotted[t] then
          begin
            Project.PushUndoSnapshot(t);
            Snapshotted[t] := True;
          end;
          NewClip := Extracted;
          NewClip.Position := Extracted.Position + Span;
          Project.CommitClipToTrack(t, NewClip);
          PushTrackToEngine(t);
        end;
    end;

    { move the selection along with the duplicate, Ableton-style, so
      repeated Ctrl+D keeps stacking copies rightward }
    FRangeStartFrame := FRangeStartFrame + Span;
    FRangeEndFrame := FRangeEndFrame + Span;
    Invalidate;
  end
  else if (FSelectedTrack >= 0) and (FSelectedClip >= 0) and
    (FSelectedClip <= High(Project.Tracks[FSelectedTrack].Clips)) then
  begin
    Extracted := Project.Tracks[FSelectedTrack].Clips[FSelectedClip];
    NewClip := Extracted;
    NewClip.Position := Extracted.Position + Extracted.Length;

    Project.PushUndoSnapshot(FSelectedTrack);
    Project.CommitClipToTrack(FSelectedTrack, NewClip);
    PushTrackToEngine(FSelectedTrack);

    SelectClip(FSelectedTrack, High(Project.Tracks[FSelectedTrack].Clips));
    Invalidate;
  end;
end;

procedure TArrangementView.DeleteSelection;
begin
  if (FSelectedTrack >= 0) and (FSelectedClip >= 0) and
    (FSelectedClip <= High(Project.Tracks[FSelectedTrack].Clips)) then
  begin
    Project.PushUndoSnapshot(FSelectedTrack);
    Project.RemoveClipAt(FSelectedTrack, FSelectedClip);
    PushTrackToEngine(FSelectedTrack);
    SelectClip(FSelectedTrack, -1);
    Invalidate;
  end;
end;

procedure TArrangementView.SplitAtCursor;
var
  Track: Integer;
  Selected, LeftPart, RightPart: TClip;
  SplitFrame, SplitRel: Int64;
  Clips, NewClips: TClipArray;
  j, k: Integer;
begin
  if FSelectedTrack < 0 then
    Exit;
  Track := FSelectedTrack;
  if (FSelectedClip < 0) or (FSelectedClip > High(Project.Tracks[Track].Clips)) then
    Exit;

  Selected := Project.Tracks[Track].Clips[FSelectedClip];
  SplitFrame := FCursorFrame;

  if (SplitFrame > Selected.Position) and
    (SplitFrame < Selected.Position + Selected.Length) then
  begin
    LeftPart := Selected;
    RightPart := Selected;

    { carry the matching half of the warp markers across the cut instead of
      discarding them - otherwise splitting a warped clip would silently
      revert both halves to unwarped 1:1 playback. The returned split frame
      may differ slightly from the requested one (see SplitWarpMarkers) -
      use it for the clip geometry too so the halves' lengths stay
      consistent with their markers. }
    SplitRel := SplitWarpMarkers(Selected.WarpMarkers,
      SplitFrame - Selected.Position, LeftPart.WarpMarkers,
      RightPart.WarpMarkers, Selected.WarpMode);

    LeftPart.Length := SplitRel;

    RightPart.Offset := Selected.Offset + SplitRel;
    RightPart.Position := Selected.Position + SplitRel;
    RightPart.Length := Selected.Length - SplitRel;

    Project.PushUndoSnapshot(Track);

    Clips := Project.Tracks[Track].Clips;
    SetLength(NewClips, Length(Clips) + 1);
    k := 0;
    for j := 0 to High(Clips) do
    begin
      if j = FSelectedClip then
      begin
        NewClips[k] := LeftPart;
        Inc(k);
        NewClips[k] := RightPart;
        Inc(k);
      end
      else
      begin
        NewClips[k] := Clips[j];
        Inc(k);
      end;
    end;
    Project.ReplaceTrackClips(Track, NewClips);
    PushTrackToEngine(Track);

    SelectClip(Track, -1);
    Invalidate;
  end;
end;

procedure TArrangementView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);

  if Key = VK_DELETE then
  begin
    DeleteSelection;
    Key := 0;
    Exit;
  end;

  if not (ssCtrl in Shift) then
    Exit;

  if Key = Ord('C') then
  begin
    CopySelection;
    Key := 0;
  end
  else if Key = Ord('V') then
  begin
    PasteSelection;
    Key := 0;
  end
  else if Key = Ord('D') then
  begin
    DuplicateSelection;
    Key := 0;
  end
  else if Key = Ord('E') then
  begin
    SplitAtCursor;
    Key := 0;
  end;
end;

end.
