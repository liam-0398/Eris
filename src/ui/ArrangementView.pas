unit ArrangementView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, Forms, Controls, Graphics, LCLType, StdCtrls,
  FileBrowser, SampleTypes, Project, AudioEngine, Waveform, ClipOverwrite;

type
  TFileDropEvent = procedure(Sender: TObject; ATrackIndex: Integer;
    AFramePosition: Int64; const AFilePath: string) of object;

  TSeekEvent = procedure(Sender: TObject; AFrameOffset: Int64) of object;

  { Fired when a timeline clip is "activated" as an instrument the same way
    a file-browser file is - double-clicked, or dragged down off the bottom
    of the arrangement onto the device panel's instrument slot below (see
    MouseUp's dmMove branch and DblClick). Carries the clip's SampleID
    directly rather than a path: the sample is already resident in
    Project.SamplePool (loaded from disk, or - for a recorded clip - never
    backed by a file at all), so there's nothing to import. }
  { AOffset/ALength are the clip's own Offset/Length (its trim window into
    the source sample) - carried along so a drop onto a Sampler Track's key
    strip, or onto the single-instrument slot, (see
    MainForm.ArrangementViewClipActivate) can seed that key/instrument's
    start AND end markers from wherever the dragged clip itself was
    trimmed to, instead of always defaulting to the whole underlying
    sample. }
  TClipSampleEvent = procedure(Sender: TObject; ASampleID: Integer;
    AOffset, ALength: Int64) of object;

  TDragMode = (dmNone, dmMove, dmResizeLeft, dmResizeRight, dmRangeSelect, dmGroupMove);

  { One clip being dragged as part of a multi-clip group move (started by
    grabbing a clip that's part of the active range selection). OrigTrack/
    OrigClipIndex is where it lives in Project.Tracks right now - needed at
    MouseUp to pull it back out of there; CurrentTrack/CurrentClip is its
    live, dragged position, which DrawClips renders from during the drag. }
  TGroupDragItem = record
    OrigTrack, OrigClipIndex: Integer;
    CurrentTrack: Integer;
    CurrentClip: TClip;
  end;
  TGroupDragItemArray = array of TGroupDragItem;

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
      VScrollBarWidth = 16;
      AutoScrollMarginPixels = 40;
      ContentEndPaddingSeconds = 10;
      VolumeSliderY = 44;
      VolumeSliderMargin = 10;
      VolumeSliderRadius = 5;
      VolumeSliderGrabPixels = 8;
      TrackVolumeMax = 2.0;
      MuteButtonSize = 16;
      MuteButtonMargin = 4;
      MonitorButtonSize = 16;
    var
      FOnFileDrop: TFileDropEvent;
      FOnSeek: TSeekEvent;
      FOnClipActivate: TClipSampleEvent;
      FOnKeyboardTrackChanged: TNotifyEvent;
      FOnClipSelectionChanged: TNotifyEvent;
      FTrackColors: array[0..Project.MaxTracks - 1] of TColor;
      FPixelsPerSecond: Double;
      FCursorFrame: Int64;
      FScrollFrame: Int64;
      FHScrollBar: TScrollBar;
      FVScrollOffset: Integer;
      FVScrollBar: TScrollBar;
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
      FGroupDragItems: TGroupDragItemArray;
      FGroupDragGrabItemIndex: Integer;
      FGroupDragGrabTrack: Integer;
      FGroupDragGrabOrigPosition: Int64;
      FGroupDragFrameDelta: Int64;
      FGroupDragTrackDelta: Integer;
    function LaneWidth: Integer;
    function HeaderLeft: Integer;
    function ContentHeight: Integer;
    function ContentEndFrame: Int64;
    function TrackIndexAtY(Y: Integer): Integer;
    function MasterRowTop: Integer;
    function RowTop(AIndex: Integer): Integer;
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
    function MonitorButtonRect(ATrackIndex: Integer): TRect;
    function ClipOverlapsRange(const AClip: TClip; ARangeStart, ARangeEnd: Int64): Boolean;
    procedure BuildGroupDragItems(ARangeStart, ARangeEnd: Int64; AT1, AT2: Integer);
    procedure SelectClip(ATrack, AClip: Integer);
    procedure UpdateEngineLoop;
    procedure SetScrollFrame(AFrame: Int64);
    procedure UpdateScrollBarRange;
    procedure HScrollBarChange(Sender: TObject);
    procedure SetVScrollOffset(AOffset: Integer);
    procedure UpdateVScrollBarRange;
    procedure VScrollBarChange(Sender: TObject);
    procedure DrawLanes;
    procedure DrawRuler;
    procedure DrawLoopMarkers;
    procedure DrawTrackHeaders;
    procedure DrawOneClip(ATrack: Integer; const AClip: TClip; AIsSelected: Boolean);
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
    procedure DblClick; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure RefreshTrack(ATrackIndex: Integer);
    procedure PushTrackToEngine(ATrackIndex: Integer);
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
    procedure ConsolidateSelection;
    procedure RescaleTimeReferences(ARatio: Double);
    property KeyboardTrack: Integer read FKeyboardTrack;
    property SelectedTrack: Integer read FSelectedTrack;
    property SelectedClipIndex: Integer read FSelectedClip;
    property CursorFrame: Int64 read FCursorFrame;
    property OnFileDrop: TFileDropEvent read FOnFileDrop write FOnFileDrop;
    property OnSeek: TSeekEvent read FOnSeek write FOnSeek;
    property OnClipActivate: TClipSampleEvent read FOnClipActivate write FOnClipActivate;
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

  FVScrollOffset := 0;
  FVScrollBar := TScrollBar.Create(Self);
  FVScrollBar.Parent := Self;
  FVScrollBar.Kind := sbVertical;
  FVScrollBar.OnChange := @VScrollBarChange;
end;

function TArrangementView.LaneWidth: Integer;
begin
  Result := Width - HeaderWidth - VScrollBarWidth;
end;

{ X where the track-header column begins - the strip [LaneWidth, HeaderLeft)
  in between is the vertical scrollbar itself (a real child control, so it
  already intercepts its own clicks; this only matters for painting/hit-test
  math that needs to know where header content starts). }
function TArrangementView.HeaderLeft: Integer;
begin
  Result := LaneWidth + VScrollBarWidth;
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
  Result := RowTop(Project.TrackCount);
end;

{ Y where track row AIndex (or, with AIndex = Project.TrackCount, the Master
  row) starts, net of the current vertical scroll offset - every row-Y
  computation in this unit goes through here so FVScrollOffset only has to
  be threaded through in one place. }
function TArrangementView.RowTop(AIndex: Integer): Integer;
begin
  Result := RulerHeight + AIndex * TrackHeight - FVScrollOffset;
end;

function TArrangementView.TrackIndexAtY(Y: Integer): Integer;
begin
  if (Y < RulerHeight) or (Y >= ContentHeight) then
    Exit(-1);
  Result := (Y - RulerHeight + FVScrollOffset) div TrackHeight;
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
  y := RowTop(ATrackIndex);
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

{ Shared overlap test - same check CopySelection/DuplicateSelection/
  DeleteSelection's range branches already do inline, factored out so a
  group-move drag can reuse it too. }
function TArrangementView.ClipOverlapsRange(const AClip: TClip;
  ARangeStart, ARangeEnd: Int64): Boolean;
begin
  Result := (AClip.Position + AClip.Length > ARangeStart) and
    (AClip.Position < ARangeEnd);
end;

{ Populates FGroupDragItems with every clip on tracks [AT1, AT2] that
  overlaps [ARangeStart, ARangeEnd) - the set of clips a group-move drag
  carries together. }
procedure TArrangementView.BuildGroupDragItems(ARangeStart, ARangeEnd: Int64;
  AT1, AT2: Integer);
var
  t, i: Integer;
begin
  FGroupDragItems := nil;
  for t := AT1 to AT2 do
    for i := 0 to High(Project.Tracks[t].Clips) do
      if ClipOverlapsRange(Project.Tracks[t].Clips[i], ARangeStart, ARangeEnd) then
      begin
        SetLength(FGroupDragItems, Length(FGroupDragItems) + 1);
        FGroupDragItems[High(FGroupDragItems)].OrigTrack := t;
        FGroupDragItems[High(FGroupDragItems)].OrigClipIndex := i;
        FGroupDragItems[High(FGroupDragItems)].CurrentTrack := t;
        FGroupDragItems[High(FGroupDragItems)].CurrentClip := Project.Tracks[t].Clips[i];
      end;
end;

function TArrangementView.VolumeKnobX(ATrackIndex: Integer): Integer;
var
  Range: Integer;
  Value: Single;
begin
  Range := (Width - VolumeSliderMargin) - (HeaderLeft + VolumeSliderMargin);
  Value := Project.TrackVolume[ATrackIndex] / TrackVolumeMax;
  if Value < 0 then
    Value := 0;
  if Value > 1 then
    Value := 1;
  Result := (HeaderLeft + VolumeSliderMargin) + Round(Value * Range);
end;

function TArrangementView.XToVolume(X: Integer): Single;
var
  Range: Integer;
  Frac: Single;
begin
  Range := (Width - VolumeSliderMargin) - (HeaderLeft + VolumeSliderMargin);
  if Range <= 0 then
    Exit(1.0);
  Frac := (X - (HeaderLeft + VolumeSliderMargin)) / Range;
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
  SliderY := RowTop(ATrackIndex) + VolumeSliderY;
  Result := Abs(Y - SliderY) <= VolumeSliderGrabPixels;
end;

function TArrangementView.MuteButtonRect(ATrackIndex: Integer): TRect;
var
  y: Integer;
begin
  y := RowTop(ATrackIndex);
  Result := Rect(Width - MuteButtonSize - MuteButtonMargin, y + MuteButtonMargin,
    Width - MuteButtonMargin, y + MuteButtonMargin + MuteButtonSize);
end;

{ Input Track only: input-monitoring toggle, sitting immediately left of the
  mute button - lets the live captured signal through to this track's
  audible output with no playhead movement/recording required (see
  AudioEngine.FillBlock's TrackIsInput/TrackMonitorEnabled mix). }
function TArrangementView.MonitorButtonRect(ATrackIndex: Integer): TRect;
var
  y, RightEdge: Integer;
begin
  y := RowTop(ATrackIndex);
  RightEdge := Width - MuteButtonSize - MuteButtonMargin * 2 - MonitorButtonSize;
  Result := Rect(RightEdge, y + MuteButtonMargin,
    RightEdge + MonitorButtonSize, y + MuteButtonMargin + MonitorButtonSize);
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

    Items[i].TransientCount := Length(Project.SampleTransients[Clip.SampleID]);
    if Items[i].TransientCount > 0 then
      Items[i].Transients := PInt64(Project.SampleTransients[Clip.SampleID])
    else
      Items[i].Transients := nil;

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

{ mirrors SetScrollFrame/UpdateScrollBarRange/HScrollBarChange above, one
  dimension over - AOffset is in pixels (not frames; there's no zoom-level
  concept vertically, TrackHeight is a fixed constant) and covers every
  track row plus the Master row. }
procedure TArrangementView.SetVScrollOffset(AOffset: Integer);
var
  MaxOffset: Integer;
begin
  MaxOffset := (Project.TrackCount + 1) * TrackHeight - (ContentHeight - RulerHeight);
  if MaxOffset < 0 then
    MaxOffset := 0;
  if AOffset < 0 then
    AOffset := 0;
  if AOffset > MaxOffset then
    AOffset := MaxOffset;
  if AOffset = FVScrollOffset then
    Exit;
  FVScrollOffset := AOffset;
  UpdateVScrollBarRange;
  Invalidate;
end;

procedure TArrangementView.UpdateVScrollBarRange;
var
  TotalPixels, Page: Integer;
begin
  if not Assigned(FVScrollBar) then
    Exit;
  TotalPixels := (Project.TrackCount + 1) * TrackHeight; { +1 for the Master row }
  Page := ContentHeight - RulerHeight;
  if Page < 1 then
    Page := 1;
  if TotalPixels < Page then
    TotalPixels := Page;

  FVScrollBar.Min := 0;
  FVScrollBar.Max := TotalPixels;
  FVScrollBar.PageSize := Page;
  FVScrollBar.SmallChange := TrackHeight;
  FVScrollBar.LargeChange := Page;
  FVScrollBar.Position := FVScrollOffset;
end;

procedure TArrangementView.VScrollBarChange(Sender: TObject);
begin
  SetVScrollOffset(FVScrollBar.Position);
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
    y := RowTop(i);
    if (y < RulerHeight) or (y > ContentHeight) then
      Continue;
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
  MuteRect, MonitorRect: TRect;
begin
  for i := 0 to Project.TrackCount - 1 do
  begin
    y := RowTop(i);
    { row scrolled fully or partially out of the visible band - full-row
      cull rather than clip, so nothing bleeds into the ruler above or the
      horizontal scrollbar's margin below }
    if (y < RulerHeight) or (y + TrackHeight > ContentHeight) then
      Continue;
    if i = FKeyboardTrack then
      Canvas.Brush.Color := clGray
    else
      Canvas.Brush.Color := clBtnFace;
    Canvas.FillRect(Rect(HeaderLeft, y, Width, y + TrackHeight));
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(HeaderLeft, y, Width, y + TrackHeight);
    Canvas.Brush.Style := bsClear;
    if Project.TrackIsInput[i] then
      Canvas.TextOut(HeaderLeft + 8, y + 8, 'Input ' + IntToStr(i + 1))
    else
      Canvas.TextOut(HeaderLeft + 8, y + 8, 'Track ' + IntToStr(i + 1));
    Canvas.Brush.Style := bsSolid;

    { simple on/off mute toggle }
    MuteRect := MuteButtonRect(i);
    if Project.TrackEnabled[i] then
      Canvas.Brush.Color := clLime
    else
      Canvas.Brush.Color := clRed;
    Canvas.Pen.Color := clBlack;
    Canvas.Rectangle(MuteRect);

    { Input Track only: "M" input-monitoring toggle }
    if Project.TrackIsInput[i] then
    begin
      MonitorRect := MonitorButtonRect(i);
      if Project.TrackMonitorEnabled[i] then
        Canvas.Brush.Color := clYellow
      else
        Canvas.Brush.Color := clBtnFace;
      Canvas.Pen.Color := clBlack;
      Canvas.Rectangle(MonitorRect);
      Canvas.Brush.Style := bsClear;
      Canvas.TextOut(MonitorRect.Left + 4, MonitorRect.Top - 1, 'M');
      Canvas.Brush.Style := bsSolid;
    end;

    { simple volume slider - a plain line with a draggable knob, no readout }
    SliderY := y + VolumeSliderY;
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Line(HeaderLeft + VolumeSliderMargin, SliderY, Width - VolumeSliderMargin, SliderY);
    kx := VolumeKnobX(i);
    Canvas.Brush.Color := clHighlight;
    Canvas.Pen.Color := clWindowFrame;
    Canvas.Ellipse(kx - VolumeSliderRadius, SliderY - VolumeSliderRadius,
      kx + VolumeSliderRadius, SliderY + VolumeSliderRadius);
  end;

  { master bus row, always the last row, below every real track - no clips,
    mute, or volume slider, just a click target for the master effects chain }
  y := MasterRowTop;
  if (y >= RulerHeight) and (y + TrackHeight <= ContentHeight) then
  begin
    if FKeyboardTrack = -2 then
      Canvas.Brush.Color := clGray
    else
      Canvas.Brush.Color := clBtnFace;
    Canvas.FillRect(Rect(HeaderLeft, y, Width, y + TrackHeight));
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(HeaderLeft, y, Width, y + TrackHeight);
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Style := [fsBold];
    Canvas.TextOut(HeaderLeft + 8, y + 8, 'Master');
    Canvas.Font.Style := [];
    Canvas.Brush.Style := bsSolid;
  end;
end;

{ Renders one clip - factored out of DrawClips so a group-move drag can call
  it a second time for clips at their live (possibly different-track)
  dragged position, not just for the Project.Tracks[t].Clips[i] array in
  track order. }
procedure TArrangementView.DrawOneClip(ATrack: Integer; const AClip: TClip;
  AIsSelected: Boolean);
var
  R: TRect;
  ClipName: string;
begin
  R := ClipPixelRect(ATrack, AClip);
  if (R.Right < 0) or (R.Left > LaneWidth) then
    Exit;
  if (R.Top < RulerHeight) or (R.Bottom > ContentHeight) then
    Exit;

  { neutral dark interior so the waveform (drawn in the track's color)
    reads clearly against it, full width - no horizontal border/inset }
  Canvas.Brush.Color := clBlack;
  Canvas.FillRect(R);
  if AClip.SampleID <= High(Project.SamplePeaks) then
    DrawWaveform(Canvas, Rect(R.Left, R.Top + 14, R.Right, R.Bottom),
      Project.SamplePeaks[AClip.SampleID],
      Project.SamplePool[AClip.SampleID].FrameCount, AClip.Offset,
      AClip.Offset + AClip.Length, AClip.WarpMarkers, FTrackColors[ATrack],
      AClip.WarpMode, Project.SampleTransients[AClip.SampleID]);

  { border only (Frame, not Rectangle - Rectangle also fills the interior
    with the current brush, which would erase the waveform just drawn) }
  if AIsSelected then
    Canvas.Pen.Color := clRed
  else
    Canvas.Pen.Color := FTrackColors[ATrack];
  Canvas.Pen.Width := 2;
  Canvas.Frame(R);
  Canvas.Pen.Width := 1;

  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := clWhite;
  if AClip.SampleID <= High(Project.SampleNames) then
    ClipName := Project.SampleNames[AClip.SampleID]
  else
    ClipName := '';
  Canvas.TextOut(R.Left + 4, R.Top + 2, ClipName);
  Canvas.Font.Color := clWindowText;
  Canvas.Brush.Style := bsSolid;
end;

procedure TArrangementView.DrawClips;
var
  t, i, g: Integer;
  Clip: TClip;
  IsSelected, IsDragging, Suppress: Boolean;
begin
  for t := 0 to Project.TrackCount - 1 do
    for i := 0 to High(Project.Tracks[t].Clips) do
    begin
      { during a group move, every dragged clip's ORIGINAL slot is skipped
        here - it's redrawn below at its live (possibly different-track)
        position instead }
      Suppress := False;
      if FDragActive and (FDragMode = dmGroupMove) then
        for g := 0 to High(FGroupDragItems) do
          if (FGroupDragItems[g].OrigTrack = t) and
            (FGroupDragItems[g].OrigClipIndex = i) then
          begin
            Suppress := True;
            Break;
          end;
      if Suppress then
        Continue;

      IsDragging := FDragActive and (FDragMode in [dmMove, dmResizeLeft, dmResizeRight]) and
        (t = FDragTrack) and (i = FDragClip);
      if IsDragging then
        Clip := FDragCurrentClip
      else
        Clip := Project.Tracks[t].Clips[i];

      IsSelected := (t = FSelectedTrack) and (i = FSelectedClip);
      DrawOneClip(t, Clip, IsSelected);
    end;

  if FDragActive and (FDragMode = dmGroupMove) then
    for g := 0 to High(FGroupDragItems) do
      DrawOneClip(FGroupDragItems[g].CurrentTrack, FGroupDragItems[g].CurrentClip,
        (FGroupDragItems[g].OrigTrack = FSelectedTrack) and
        (FGroupDragItems[g].OrigClipIndex = FSelectedClip));
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

  yTop := Max(RowTop(t1), RulerHeight);
  yBottom := Min(RowTop(t2 + 1), ContentHeight);
  if yBottom <= yTop then
    Exit;

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
  if Assigned(FVScrollBar) then
  begin
    { sits only against the timeline, from the ruler's bottom edge to the
      horizontal scrollbar's top edge - never over the ruler or header row }
    FVScrollBar.SetBounds(LaneWidth, RulerHeight, VScrollBarWidth,
      ContentHeight - RulerHeight);
    UpdateVScrollBarRange;
  end;
  Invalidate;
end;

procedure TArrangementView.RefreshTrack(ATrackIndex: Integer);
begin
  PushTrackToEngine(ATrackIndex);
  UpdateScrollBarRange;
  UpdateVScrollBarRange;
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
  t1, t2, g: Integer;
  RangeStart, RangeEnd: Int64;
  GroupHasClickedClip: Boolean;
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

  if (X >= HeaderLeft) and (Y >= MasterRowTop) and (Y < MasterRowTop + TrackHeight) then
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

  if (TrackIndex >= 0) and (X >= HeaderLeft) and
    PtInRect(MuteButtonRect(TrackIndex), Point(X, Y)) then
  begin
    Project.TrackEnabled[TrackIndex] := not Project.TrackEnabled[TrackIndex];
    Invalidate;
    Exit;
  end;

  if (TrackIndex >= 0) and (X >= HeaderLeft) and Project.TrackIsInput[TrackIndex] and
    PtInRect(MonitorButtonRect(TrackIndex), Point(X, Y)) then
  begin
    Project.TrackMonitorEnabled[TrackIndex] := not Project.TrackMonitorEnabled[TrackIndex];
    Invalidate;
    Exit;
  end;

  if (TrackIndex >= 0) and (X >= HeaderLeft) and HitTestVolumeSlider(TrackIndex, Y) then
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

  { X >= HeaderLeft means this click landed in the header column (and wasn't
    the mute button/volume slider, both already handled above) - track
    selection is done, but there's no clip/lane content over there to hit-
    test or seek to. Without this guard, XToFrame(X) treated a header-
    column pixel as a timeline position and every header click silently
    seeked the playhead to whatever frame that pixel happened to map to. }
  if X >= HeaderLeft then
  begin
    Invalidate;
    Exit;
  end;

  if HitTestClip(TrackIndex, X, ClipIndex, Mode) then
  begin
    { grabbing a clip that's part of the active range selection drags the
      WHOLE selection together, Ableton-style - but only on a plain move
      grab; grabbing a resize handle within a multi-selection still resizes
      just that one clip, matching Ableton. }
    GroupHasClickedClip := False;
    if FRangeSelectActive and (Mode = dmMove) then
    begin
      t1 := Min(FRangeStartTrack, FRangeEndTrack);
      t2 := Max(FRangeStartTrack, FRangeEndTrack);
      RangeStart := Min(FRangeStartFrame, FRangeEndFrame);
      RangeEnd := Max(FRangeStartFrame, FRangeEndFrame);
      BuildGroupDragItems(RangeStart, RangeEnd, t1, t2);
      for g := 0 to High(FGroupDragItems) do
        if (FGroupDragItems[g].OrigTrack = TrackIndex) and
          (FGroupDragItems[g].OrigClipIndex = ClipIndex) then
        begin
          GroupHasClickedClip := True;
          FGroupDragGrabItemIndex := g;
          Break;
        end;
    end;

    if GroupHasClickedClip then
    begin
      { SelectClip (not a direct field assignment) so MainForm's warp
        widget/RP-BT toggle stay in sync with whichever clip was grabbed,
        same as the single-clip dmMove path below - it doesn't touch
        FRangeSelectActive, so the active selection survives this call }
      SelectClip(TrackIndex, ClipIndex);
      FDragMode := dmGroupMove;
      FDragActive := True;
      FGroupDragGrabTrack := TrackIndex;
      FGroupDragGrabOrigPosition := Project.Tracks[TrackIndex].Clips[ClipIndex].Position;
      FDragGrabOffsetFrames := XToFrame(X) - FGroupDragGrabOrigPosition;
      FGroupDragFrameDelta := 0;
      FGroupDragTrackDelta := 0;
      { undo snapshots for a group move are taken at MouseUp, once the full
        set of touched tracks is known - see the dmGroupMove case there }
      Invalidate;
    end
    else
    begin
      FGroupDragItems := nil;
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
    end;
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
  TargetTrack, Row, g, GroupMinTrack, GroupMaxTrack: Integer;
  GroupMinPosition, OrigPos: Int64;
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

        Row := (Y - RulerHeight + FVScrollOffset) div TrackHeight;
        if Row < 0 then
          Row := 0;
        if Row > Project.TrackCount - 1 then
          Row := Project.TrackCount - 1;
        FRangeStartTrack := FRangeDragStartTrack;
        FRangeEndTrack := Row;

        if FRangeEndFrame <> FRangeStartFrame then
          FRangeSelectActive := True;
      end;
    dmGroupMove:
      begin
        if Length(FGroupDragItems) = 0 then
          Exit;

        NewPosition := MouseFrame - FDragGrabOffsetFrames;
        if not FreePlacement then
          NewPosition := SnapFrame(NewPosition);
        FGroupDragFrameDelta := NewPosition - FGroupDragGrabOrigPosition;

        { clamp the delta for the group AS A WHOLE (not per-item) so relative
          spacing survives instead of compressing - only the earliest item's
          position can't go negative, matching dmMove's own clamp }
        GroupMinPosition := -1;
        for g := 0 to High(FGroupDragItems) do
        begin
          OrigPos := Project.Tracks[FGroupDragItems[g].OrigTrack].
            Clips[FGroupDragItems[g].OrigClipIndex].Position;
          if (GroupMinPosition < 0) or (OrigPos < GroupMinPosition) then
            GroupMinPosition := OrigPos;
        end;
        if GroupMinPosition + FGroupDragFrameDelta < 0 then
          FGroupDragFrameDelta := -GroupMinPosition;

        TargetTrack := TrackIndexAtY(Y);
        if TargetTrack >= 0 then
        begin
          FGroupDragTrackDelta := TargetTrack - FGroupDragGrabTrack;

          GroupMinTrack := FGroupDragItems[0].OrigTrack;
          GroupMaxTrack := FGroupDragItems[0].OrigTrack;
          for g := 1 to High(FGroupDragItems) do
          begin
            if FGroupDragItems[g].OrigTrack < GroupMinTrack then
              GroupMinTrack := FGroupDragItems[g].OrigTrack;
            if FGroupDragItems[g].OrigTrack > GroupMaxTrack then
              GroupMaxTrack := FGroupDragItems[g].OrigTrack;
          end;
          if GroupMinTrack + FGroupDragTrackDelta < 0 then
            FGroupDragTrackDelta := -GroupMinTrack;
          if GroupMaxTrack + FGroupDragTrackDelta > Project.TrackCount - 1 then
            FGroupDragTrackDelta := Project.TrackCount - 1 - GroupMaxTrack;
        end;

        for g := 0 to High(FGroupDragItems) do
        begin
          FGroupDragItems[g].CurrentClip := Project.Tracks[FGroupDragItems[g].OrigTrack].
            Clips[FGroupDragItems[g].OrigClipIndex];
          FGroupDragItems[g].CurrentClip.Position :=
            FGroupDragItems[g].CurrentClip.Position + FGroupDragFrameDelta;
          FGroupDragItems[g].CurrentTrack := FGroupDragItems[g].OrigTrack + FGroupDragTrackDelta;
        end;
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
  SplitRel, SplitSource: Int64;
  t, g, i, GrabbedTrack, GrabbedIdx: Integer;
  Snapshotted: array[0..Project.MaxTracks - 1] of Boolean;
  NewClips: TClipArray;
  HasGroupItem, IsGroupMember: Boolean;
begin
  inherited MouseUp(Button, Shift, X, Y);

  FDraggingVolumeTrack := -1;

  if not FDragActive then
    Exit;

  OrigTrack := FSelectedTrack;

  case FDragMode of
    dmMove:
      begin
        { dragged past the bottom edge of the arrangement view itself - onto
          the device panel below, where a file dropped from the file browser
          loads as the keyboard track's instrument (see MainForm's
          DevicePanelDragDrop). A clip dragged there activates the same way
          instead of actually moving/duplicating it on the timeline - mouse
          capture keeps delivering coordinates here even once Y runs past
          Height, same as the volume-slider drag above tolerates X doing. }
        if (Y >= Height) and Assigned(FOnClipActivate) then
        begin
          FOnClipActivate(Self, FDragOrigClip.SampleID, FDragOrigClip.Offset,
            FDragOrigClip.Length);
          FDragActive := False;
          FDragMode := dmNone;
          Invalidate;
          Exit;
        end;

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
            stays put, only the far marker's TimelineFrame rescales. Force
            RePitch mode so this is a plain vari-speed resample (same math
            as keyboard-play) instead of falling through to Beats mode's
            grain-subdivide/crossfade path, which is what actually pops. }
          FDragCurrentClip.WarpMode := SampleTypes.WarpModeRePitch;
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
          { Offset is SOURCE-domain: advance it by the source-side cut, not
            the timeline one - they differ on any stretched/warped clip (see
            SplitWarpMarkers' ASplitSourceOut comment) }
          SplitRel := SplitWarpMarkers(FDragOrigClip.WarpMarkers,
            FDragCurrentClip.Position - FDragOrigClip.Position, DiscardMarkers,
            FDragCurrentClip.WarpMarkers, FDragOrigClip.WarpMode,
            AudioEngine.ProjectSampleRate, @SplitSource);
          FDragCurrentClip.Offset := FDragOrigClip.Offset + SplitSource;
          FDragCurrentClip.Position := FDragOrigClip.Position + SplitRel;
          FDragCurrentClip.Length := FDragOrigClip.Length - SplitRel;
        end;
        Project.Tracks[FDragTrack].Clips[FDragClip] := FDragCurrentClip;
        PushTrackToEngine(FDragTrack);
        { resizing an already-selected clip never goes through SelectClip (it
          no-ops when track/clip index are unchanged), so anything that
          mirrors the selected clip's state - the warp editor, the RP toggle
          - would otherwise go stale right after a Shift-drag flips WarpMode.
          Fire the same notification SelectClip would. }
        if Assigned(FOnClipSelectionChanged) then
          FOnClipSelectionChanged(Self);
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
            place would corrupt the undo snapshot and the live Project data.
            Force RePitch mode so this is a plain vari-speed resample (same
            math as keyboard-play) instead of falling through to Beats
            mode's grain-subdivide/crossfade path, which is what actually
            pops. }
          FDragCurrentClip.WarpMode := SampleTypes.WarpModeRePitch;
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
        { see the matching comment in dmResizeLeft above }
        if Assigned(FOnClipSelectionChanged) then
          FOnClipSelectionChanged(Self);
      end;
    dmGroupMove:
      begin
        if Length(FGroupDragItems) > 0 then
        begin
          FillChar(Snapshotted, SizeOf(Snapshotted), 0);

          { phase 1: pull every dragged clip out of its ORIGINAL slot, per
            track, by rebuilding that track's array with the group's
            indices filtered out - same snapshot-then-filter approach
            DuplicateSelection already uses, so removing several clips from
            one track never trips over shifting indices }
          for t := 0 to Project.TrackCount - 1 do
          begin
            HasGroupItem := False;
            for g := 0 to High(FGroupDragItems) do
              if FGroupDragItems[g].OrigTrack = t then
              begin
                HasGroupItem := True;
                Break;
              end;
            if not HasGroupItem then
              Continue;

            if not Snapshotted[t] then
            begin
              Project.PushUndoSnapshot(t);
              Snapshotted[t] := True;
            end;

            NewClips := nil;
            for i := 0 to High(Project.Tracks[t].Clips) do
            begin
              IsGroupMember := False;
              for g := 0 to High(FGroupDragItems) do
                if (FGroupDragItems[g].OrigTrack = t) and
                  (FGroupDragItems[g].OrigClipIndex = i) then
                begin
                  IsGroupMember := True;
                  Break;
                end;
              if not IsGroupMember then
              begin
                SetLength(NewClips, Length(NewClips) + 1);
                NewClips[High(NewClips)] := Project.Tracks[t].Clips[i];
              end;
            end;
            Project.ReplaceTrackClips(t, NewClips);
          end;

          { phase 2: commit each item into its live destination - by now
            every group member has already been removed from every track's
            array, so CommitClipToTrack's internal OverwriteClips only ever
            punches genuinely foreign (non-group) clips, never another
            group member, even where two members land close together }
          for g := 0 to High(FGroupDragItems) do
          begin
            if not Snapshotted[FGroupDragItems[g].CurrentTrack] then
            begin
              Project.PushUndoSnapshot(FGroupDragItems[g].CurrentTrack);
              Snapshotted[FGroupDragItems[g].CurrentTrack] := True;
            end;
            Project.CommitClipToTrack(FGroupDragItems[g].CurrentTrack,
              FGroupDragItems[g].CurrentClip);
          end;

          for t := 0 to Project.TrackCount - 1 do
            if Snapshotted[t] then
              PushTrackToEngine(t);

          { the grabbed clip's index in its destination track's array isn't
            known until every commit above has run (CommitClipToTrack can
            insert/remove neighbors), and FSelectedClip is still pointing at
            its stale ORIGINAL index - find its new index by Position (only
            one clip can occupy a given Position on a track after
            OverwriteClips has run) and reselect it there, or every other
            operation that trusts FSelectedTrack/FSelectedClip (the RP/BT
            toggle, Delete, ...) would silently act on the wrong clip. }
          GrabbedTrack := FGroupDragItems[FGroupDragGrabItemIndex].CurrentTrack;
          GrabbedIdx := -1;
          for g := 0 to High(Project.Tracks[GrabbedTrack].Clips) do
            if Project.Tracks[GrabbedTrack].Clips[g].Position =
              FGroupDragItems[FGroupDragGrabItemIndex].CurrentClip.Position then
            begin
              GrabbedIdx := g;
              Break;
            end;
          if GrabbedIdx >= 0 then
            SelectClip(GrabbedTrack, GrabbedIdx);

          { move the persisted range selection along with the group,
            Ableton-style - same idea as DuplicateSelection advancing its
            own selection after duplicating }
          FRangeStartFrame := FRangeStartFrame + FGroupDragFrameDelta;
          FRangeEndFrame := FRangeEndFrame + FGroupDragFrameDelta;
          FRangeStartTrack := FRangeStartTrack + FGroupDragTrackDelta;
          FRangeEndTrack := FRangeEndTrack + FGroupDragTrackDelta;
        end;
        FGroupDragItems := nil;
      end;
  end;

  FDragActive := False;
  FDragMode := dmNone;
  Invalidate;
end;

{ Double-clicking a clip activates it as the keyboard track's instrument,
  same as double-clicking a file in the file browser (see MainForm's
  FileBrowserFileActivate) - the other of the two "same as file drag or
  double click" entry points MouseUp's dmMove branch above covers for the
  drag gesture. }
procedure TArrangementView.DblClick;
var
  P: TPoint;
  TrackIndex, ClipIndex: Integer;
  Mode: TDragMode;
begin
  inherited DblClick;
  P := ScreenToClient(Mouse.CursorPos);
  if P.X >= HeaderLeft then
    Exit;
  TrackIndex := TrackIndexAtY(P.Y);
  if TrackIndex < 0 then
    Exit;
  if not HitTestClip(TrackIndex, P.X, ClipIndex, Mode) then
    Exit;
  if Assigned(FOnClipActivate) then
    FOnClipActivate(Self, Project.Tracks[TrackIndex].Clips[ClipIndex].SampleID,
      Project.Tracks[TrackIndex].Clips[ClipIndex].Offset,
      Project.Tracks[TrackIndex].Clips[ClipIndex].Length);
end;

{ Extracts whatever portion of AClip falls inside [ARangeStart, ARangeEnd),
  trimming its warp markers to match exactly like a real split would - used
  by both range-select copy and range-select duplicate. Returns False if
  AClip doesn't overlap the range at all. }
function ExtractClipInRange(const AClip: TClip; ARangeStart, ARangeEnd: Int64;
  out AResult: TClip): Boolean;
var
  ClipEnd, NewStart, NewEnd, SplitRel, SplitSource: Int64;
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
    { Offset is SOURCE-domain - advance by the source-side cut, not the
      timeline one (see SplitWarpMarkers' ASplitSourceOut comment) }
    SplitRel := SplitWarpMarkers(AClip.WarpMarkers, NewStart - AClip.Position,
      DiscardMarkers, KeptMarkers, AClip.WarpMode,
      AudioEngine.ProjectSampleRate, @SplitSource);
    AResult.WarpMarkers := KeptMarkers;
    AResult.Offset := AClip.Offset + SplitSource;
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
var
  t1, t2, t: Integer;
  RangeStart, RangeEnd: Int64;
begin
  if FRangeSelectActive then
  begin
    t1 := Min(FRangeStartTrack, FRangeEndTrack);
    t2 := Max(FRangeStartTrack, FRangeEndTrack);
    RangeStart := Min(FRangeStartFrame, FRangeEndFrame);
    RangeEnd := Max(FRangeStartFrame, FRangeEndFrame);
    if RangeEnd <= RangeStart then
      Exit;

    { OverwriteClips already does exactly "punch this time window out of a
      track's clips, trimming/splitting partial overlaps with correct
      warp-marker handling" - the same primitive single-clip drop-collision
      uses (Project.CommitClipToTrack) - just without appending a new clip
      back afterward. }
    for t := t1 to t2 do
    begin
      Project.PushUndoSnapshot(t);
      Project.ReplaceTrackClips(t,
        ClipOverwrite.OverwriteClips(Project.Tracks[t].Clips, RangeStart,
        RangeEnd - RangeStart));
      PushTrackToEngine(t);
    end;
    Invalidate;
  end
  else if (FSelectedTrack >= 0) and (FSelectedClip >= 0) and
    (FSelectedClip <= High(Project.Tracks[FSelectedTrack].Clips)) then
  begin
    Project.PushUndoSnapshot(FSelectedTrack);
    Project.RemoveClipAt(FSelectedTrack, FSelectedClip);
    PushTrackToEngine(FSelectedTrack);
    SelectClip(FSelectedTrack, -1);
    Invalidate;
  end;
end;

{ Ableton-style "Consolidate": bounces the selected time range on ONE track
  into a single new clip. Only ever acts on a single-track selection - a
  range spanning more than one track is a no-op, by design (no per-track
  fan-out). }
procedure TArrangementView.ConsolidateSelection;
const
  OutChannels = 2;
var
  t, i: Integer;
  RangeStart, RangeEnd, RangeLen, OutFrame, OutIdx, ClipRelFrame, SwungPos: Int64;
  Clip: TClip;
  Sample: TSample;
  NewSample: TSample;
  NewClip: TClip;
  Buffer: PSingle;
  HasContent: Boolean;
begin
  if not FRangeSelectActive then
    Exit;
  if FRangeStartTrack <> FRangeEndTrack then
    Exit;

  t := FRangeStartTrack;
  if (t < 0) or (t >= Project.TrackCount) then
    Exit;
  RangeStart := Min(FRangeStartFrame, FRangeEndFrame);
  RangeEnd := Max(FRangeStartFrame, FRangeEndFrame);
  if RangeEnd <= RangeStart then
    Exit;
  RangeLen := RangeEnd - RangeStart;

  HasContent := False;
  for i := 0 to High(Project.Tracks[t].Clips) do
  begin
    SwungPos := AudioEngine.SwungPosition(Project.Tracks[t].Clips[i].Position,
      Project.TrackSwingPercent[t], Project.TrackSwingDivision[t], BeatFrames);
    if (SwungPos + Project.Tracks[t].Clips[i].Length > RangeStart) and
      (SwungPos < RangeEnd) then
    begin
      HasContent := True;
      Break;
    end;
  end;
  if not HasContent then
    Exit; { nothing in range on this track - no point in a silent clip }

  GetMem(Buffer, RangeLen * OutChannels * SizeOf(Single));
  FillChar(Buffer^, RangeLen * OutChannels * SizeOf(Single), 0);

  { render exactly like ProjectFile.RenderProjectToWav's offline bounce - same
    per-clip DetunedSample primitive AND the same SwungPosition shift, so
    warp mode/detune/transient-grain/swing behavior all match live playback
    with no new DSP. Without the swing shift here, a bounce of swung clips
    silently reverted to their straight grid position - "consolidate" would
    quietly flatten the swing feel. }
  for i := 0 to High(Project.Tracks[t].Clips) do
  begin
    Clip := Project.Tracks[t].Clips[i];
    SwungPos := AudioEngine.SwungPosition(Clip.Position,
      Project.TrackSwingPercent[t], Project.TrackSwingDivision[t], BeatFrames);
    if (SwungPos + Clip.Length <= RangeStart) or (SwungPos >= RangeEnd) then
      Continue;
    Sample := Project.SamplePool[Clip.SampleID];

    for OutFrame := 0 to RangeLen - 1 do
    begin
      ClipRelFrame := (RangeStart + OutFrame) - SwungPos;
      if (ClipRelFrame < 0) or (ClipRelFrame >= Clip.Length) then
        Continue;
      OutIdx := OutFrame * OutChannels;

      if Sample.Channels = 1 then
      begin
        Buffer[OutIdx] := Buffer[OutIdx] +
          DetunedSample(Clip.WarpMarkers, ClipRelFrame, Clip.PitchSemitones, Clip.Offset,
            Sample.Data, Sample.FrameCount, Sample.Channels,
            AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
            Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
        Buffer[OutIdx + 1] := Buffer[OutIdx + 1] +
          DetunedSample(Clip.WarpMarkers, ClipRelFrame, Clip.PitchSemitones, Clip.Offset,
            Sample.Data, Sample.FrameCount, Sample.Channels,
            AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
            Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
      end
      else
      begin
        Buffer[OutIdx] := Buffer[OutIdx] +
          DetunedSample(Clip.WarpMarkers, ClipRelFrame, Clip.PitchSemitones, Clip.Offset,
            Sample.Data, Sample.FrameCount, Sample.Channels,
            AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
            Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
        Buffer[OutIdx + 1] := Buffer[OutIdx + 1] +
          DetunedSample(Clip.WarpMarkers, ClipRelFrame, Clip.PitchSemitones, Clip.Offset,
            Sample.Data, Sample.FrameCount, Sample.Channels,
            AudioEngine.ProjectSampleRate, Clip.WarpMode, 1, Clip.Length,
            Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
      end;
    end;
  end;

  FillChar(NewSample, SizeOf(NewSample), 0);
  NewSample.Data := Buffer;
  NewSample.FrameCount := RangeLen;
  NewSample.Channels := OutChannels;
  NewSample.SampleRate := AudioEngine.ProjectSampleRate;
  NewSample.BaseNote := 60.0;

  { WarpMarkers left unset (nil) - a fresh dynamic-array field, same
    convention MainForm.FinalizeRecording uses for its own new TClip; fewer
    than 2 markers means "plain, unwarped" everywhere this is read. }
  NewClip.SampleID := Project.AddSampleToPool(NewSample, 'Consolidated', '');
  NewClip.Offset := 0;
  NewClip.Length := RangeLen;
  NewClip.Position := RangeStart;
  NewClip.TrackID := t;
  NewClip.PitchSemitones := 0;
  NewClip.Gain := 1.0;
  NewClip.WarpMode := SampleTypes.WarpModeBeats;

  Project.PushUndoSnapshot(t);
  { CommitClipToTrack already punches every existing clip inside
    [RangeStart, RangeEnd) via the same OverwriteClips path DeleteSelection's
    range branch above uses directly - no separate punch step needed here. }
  Project.CommitClipToTrack(t, NewClip);
  PushTrackToEngine(t);
  Invalidate;
end;

procedure TArrangementView.SplitAtCursor;
var
  Track: Integer;
  Selected, LeftPart, RightPart: TClip;
  SplitFrame, SplitRel, SplitSource: Int64;
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
      RightPart.WarpMarkers, Selected.WarpMode,
      AudioEngine.ProjectSampleRate, @SplitSource);

    LeftPart.Length := SplitRel;

    { Offset is SOURCE-domain - advance by the source-side cut, not the
      timeline one (see SplitWarpMarkers' ASplitSourceOut comment) }
    RightPart.Offset := Selected.Offset + SplitSource;
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
  end
  else if Key = Ord('J') then
  begin
    ConsolidateSelection;
    Key := 0;
  end;
end;

end.
