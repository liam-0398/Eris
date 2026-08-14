unit ArrangementView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, Forms, Controls, Graphics, LCLType, LCLIntf,
  Buttons, StdCtrls, FileBrowser, SampleTypes, Project, AudioEngine, Waveform,
  WaveformDraw, ThemeScrollBar, PhaseVocoder,
  { last on purpose - Theme shadows Graphics' clBtnFace/clWindow/... with the
    themed palette, and only wins if it is resolved after Graphics }
  ClipOverwrite, Theme;

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
      { half-width of the strip repainted when the playhead moves - the line
        itself is 1px, the margin absorbs pen width and rounding }
      CursorInvalidateMargin = 2;
      ContentEndPaddingSeconds = 10;
      VolumeSliderY = 44;
      VolumeSliderMargin = 10;
      VolumeSliderRadius = 5;
      VolumeSliderGrabPixels = 8;
      { Top of scale for every fader in this view, track and master alike.
        1.25 rather than 2.0 puts unity at 80% of the travel: a couple of dB
        to push into, and the whole rest of the slider to come down with.
        That is how these actually get used - a mix is balanced by pulling
        things down against the loudest thing in it, and a fader whose
        default sits dead centre both looks half turned down and spends half
        its resolution on gains that would clip the master.

        This is a SCALE, not a stored value. A project file holds a linear
        gain, so a project saved when the scale was 0..2 plays back at
        exactly the gain it was saved with - all that changed is where on the
        slider that gain is drawn. A track saved above 1.25 keeps its gain
        and pins its knob at the right-hand end; nothing is clamped on load,
        because clamping is the one thing that WOULD change how an old
        project sounds. }
      TrackVolumeMax = 1.25;
      MasterVolumeMax = TrackVolumeMax;
      MuteButtonSize = 16;
      MuteButtonMargin = 4;
      { solo sits immediately left of the mute and is deliberately the same
        box - the pair reads as one two-state strip per track }
      SoloButtonSize = MuteButtonSize;
      MonitorButtonSize = 16;
      { Per-track pan, as a typed number rather than a slider: it reads
        -100 hard left / 0 centre / +100 hard right, and the value most
        wanted from a pan is an exact one ("put it at 30") that a 60-pixel
        slider cannot be dragged to. Sits on the top line of the header, in
        the gap between the "Track N" label and the solo box - the only
        space there that is not already spoken for. }
      PanEditWidth = 38;
      PanEditHeight = 18;
      { clearance between the pan box and whichever button is to its right -
        solo normally, the "M" monitor toggle on an Input Track }
      PanEditGap = 6;
      { per-track send strip, on its own line under the volume fader: an
        S1/S2 enable button and a level slider for each }
      SendRowY = 60;
      SendButtonWidth = 22;
      SendButtonHeight = 16;
      SendSliderWidth = 40;
      SendSliderRadius = 4;
      SendSliderGrabPixels = 8;
      SendGroupWidth = 76; { button + gap + slider, per send }
      SendLeftMargin = 6;
      { The two send-bus rows are PINNED to the bottom of the header column
        rather than living in the scrolling row list the way the Master row
        does - they're a permanent destination you reach for while looking
        at any part of the arrangement, so scrolling them off screen would
        defeat them. They occupy the header column only and never extend
        left into the timeline. }
      SendRowHeight = 40;
      { A collapsed track row (right-click its header to toggle - see
        MouseDown). Deliberately the same height as one of the pinned send
        rows above: that is the shortest row this view already draws, it is
        known to hold a label and a 16px button strip on one line, and making
        the two match means a stack of collapsed tracks reads as the same kind
        of row as the S1/S2 pair at the bottom. Everything below that first
        line - the volume fader, the send strip, the pan box - is not drawn at
        all, and the track's clips squash into what is left. }
      CollapsedTrackHeight = SendRowHeight;
      { --- master clip light ------------------------------------------------
        The one indicator on the Master row: same box as a track's mute button
        so it reads as part of the same strip, but it is a lamp, not a switch.
        Green below the warning level, yellow approaching the ceiling, red
        once the mix has actually exceeded it.

        The warning level is -3 dBFS in linear terms - close enough to unity
        that yellow means "this is about to clip", not "this is loud". The
        clip level is exactly 1.0 because that is where AudioEngine's master
        clamp starts flattening peaks, and the peak the engine reports is
        measured just before that clamp so the two agree by construction.

        A clip lasts a handful of samples and the meter is polled every
        ~150ms, so red latches for MasterClipHoldMs to be seen at all;
        clicking the lamp clears the latch early.

        The three colours are the mute's clLime/clRed with the solo's clYellow
        between them - the same three accents this header already speaks in,
        rather than a fourth palette nobody has seen before. }
      MasterMeterWarnLevel = 0.708;
      MasterMeterClipLevel = 1.0;
      MasterClipHoldMs = 1500;
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
      FHScrollBar: TThemeScrollBar;
      FVScrollOffset: Integer;
      FVScrollBar: TThemeScrollBar;
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
      { the master fader is a separate flag rather than a track index, because
        the Master row is not a track and has no index to store }
      FDraggingMasterVolume: Boolean;
      { 0 green, 1 yellow, 2 red - recomputed only by PollMasterMeter, so
        painting the row never has to touch the engine }
      FMasterMeterState: Integer;
      FMasterClipHoldUntil: QWord;
      { which per-track send level is being dragged, -1 for none; the send
        index of that drag lives alongside it }
      FDraggingSendTrack: Integer;
      FDraggingSendIndex: Integer;
      { which pinned send-bus row's return level is being dragged, -1 none }
      FDraggingReturnSend: Integer;
      { The per-track S1/S2 enable toggles are REAL TSpeedButtons, not
        canvas rectangles hit-tested in MouseDown like the mute button and
        the sliders around them - same as the BT/LF/RP warp buttons. A
        TSpeedButton is a TGraphicControl, so this costs no window handles;
        it just means the widgetset routes the click instead of this unit
        doing its own arithmetic to decide whether one landed. }
      FSendButtons: array[0..Project.MaxTracks - 1, 0..Project.SendCount - 1] of TSpeedButton;
      { and for the same reason the pan boxes are real TEdits - one per track
        slot, created once, only ever moved and shown/hidden afterwards.
        A TEdit is a TWinControl so these do cost a window handle each,
        unlike the send buttons; at MaxTracks = 32 that is not worth the
        alternative of a single shared box chased around on click. }
      FPanEdits: array[0..Project.MaxTracks - 1] of TEdit;
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
    function NearestTrackIndexAtY(Y: Integer): Integer;
    function MasterRowTop: Integer;
    function RowTop(AIndex: Integer): Integer;
    function TrackRowHeight(AIndex: Integer): Integer;
    function HeaderLineTop(AIndex: Integer): Integer;
    function TrackIsCollapsed(AIndex: Integer): Boolean;
    function AllRowsHeight: Integer;
    procedure ToggleTrackCollapsed(AIndex: Integer);
    function FrameToAbsoluteX(AFrame: Int64): Integer;
    function FrameToX(AFrame: Int64): Integer;
    function XToFrame(AX: Integer): Int64;
    function BeatFrames: Int64;
    function CurrentGridFrames: Int64;
    function SnapFrame(AFrame: Int64): Int64;
    function ClipPixelRect(ATrackIndex: Integer; const AClip: TClip): TRect;
    function HitTestClip(ATrackIndex: Integer; X: Integer; out AClipIndex: Integer;
      out AMode: TDragMode): Boolean;
    function VolumeKnobXFor(AVolume, AMaxVolume: Single): Integer;
    function VolumeKnobX(ATrackIndex: Integer): Integer;
    function MasterClipLightRect: TRect;
    function XToVolume(X: Integer; AMaxVolume: Single): Single;
    function HitTestVolumeSlider(ATrackIndex, Y: Integer): Boolean;
    function MuteButtonRect(ATrackIndex: Integer): TRect;
    function SoloButtonRect(ATrackIndex: Integer): TRect;
    function MonitorButtonRect(ATrackIndex: Integer): TRect;
    function PanEditRect(ATrackIndex: Integer): TRect;
    procedure LayoutPanEdits;
    procedure PanEditEditingDone(Sender: TObject);
    procedure PanEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    function SendButtonLeft(ASendIndex: Integer): Integer;
    procedure LayoutSendButtons;
    procedure SendButtonClick(Sender: TObject);
    function SendSliderLeft(ASendIndex: Integer): Integer;
    function SendKnobX(ATrackIndex, ASendIndex: Integer): Integer;
    function XToSendLevel(ASendIndex, X: Integer): Single;
    function HitTestSendSlider(ATrackIndex, ASendIndex, X, Y: Integer): Boolean;
    function SendRowTop(ASendIndex: Integer): Integer;
    function SendRowMuteRect(ASendIndex: Integer): TRect;
    function SendRowPreRect(ASendIndex: Integer): TRect;
    function ReturnSliderLeft: Integer;
    function ReturnKnobX(ASendIndex: Integer): Integer;
    function XToReturnLevel(X: Integer): Single;
    function HitTestReturnSlider(ASendIndex, X, Y: Integer): Boolean;
    function SendRowIndexAtY(Y: Integer): Integer;
    procedure DrawSendRows;
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
    procedure PollMasterMeter;
    procedure RefreshTrack(ATrackIndex: Integer);
    procedure RefreshAllTracks;
    procedure PushTrackToEngine(ATrackIndex: Integer);
    procedure SetCursorFrame(AFrameOffset: Int64);
    procedure ClearSelection;
    procedure ClearKeyboardTrack;
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
  i, j: Integer;
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  ControlStyle := ControlStyle + [csOpaque];
  { the LCL only captures the mouse for the buttons listed here (default is
    [mbLeft]) - range selection is a RIGHT-drag (see MouseDown), so without
    mbRight the drag would stop getting MouseMove/MouseUp the moment the
    pointer left the control }
  CaptureMouseButtons := [mbLeft, mbRight];
  TabStop := True;
  FPixelsPerSecond := DefaultPixelsPerSecond;
  FSelectedTrack := -1;
  FSelectedClip := -1;
  FKeyboardTrack := -1;
  FLoopStart := -1;
  FLoopEnd := -1;
  FDraggingVolumeTrack := -1;
  FDraggingMasterVolume := False;
  FMasterMeterState := 0;
  FMasterClipHoldUntil := 0;
  FDraggingSendTrack := -1;
  FDraggingSendIndex := -1;
  FDraggingReturnSend := -1;
  FGridDivision := 4; { 1/4 note - matches the grid trackbar's default position }
  FRangeSelectActive := False;
  FRangeStartTrack := -1;
  FRangeEndTrack := -1;

  Randomize;
  for i := 0 to Project.MaxTracks - 1 do
    FTrackColors[i] := RGBToColor(100 + Random(120), 100 + Random(120),
      100 + Random(120));

  { one S1/S2 toggle per track slot, created once up front for every possible
    track (not just the visible ones) so LayoutSendButtons below only ever has
    to move and show/hide them, never create or free anything mid-paint }
  for i := 0 to Project.MaxTracks - 1 do
    for j := 0 to Project.SendCount - 1 do
    begin
      FSendButtons[i][j] := TSpeedButton.Create(Self);
      FSendButtons[i][j].Parent := Self;
      FSendButtons[i][j].Caption := 'S' + IntToStr(j + 1);
      FSendButtons[i][j].Font.Style := [fsBold];
      { a unique GroupIndex plus AllowAllUp is what turns a TSpeedButton into
        a plain independent on/off toggle - shared group indices would make
        them mutually exclusive, which is how BT/LF/RP work but the exact
        opposite of what a pair of sends wants }
      FSendButtons[i][j].GroupIndex := 100 + i * Project.SendCount + j;
      FSendButtons[i][j].AllowAllUp := True;
      FSendButtons[i][j].Tag := i * Project.SendCount + j;
      FSendButtons[i][j].Visible := False;
      FSendButtons[i][j].ShowHint := True;
      FSendButtons[i][j].Hint := Format('Send this track to S%d', [j + 1]);
      FSendButtons[i][j].OnClick := @SendButtonClick;
    end;

  { one pan box per track slot, on the same create-once principle }
  for i := 0 to Project.MaxTracks - 1 do
  begin
    FPanEdits[i] := TEdit.Create(Self);
    FPanEdits[i].Parent := Self;
    { AutoSize off or the widgetset picks the height back from the font and
      LayoutPanEdits' SetBounds stops holding }
    FPanEdits[i].AutoSize := False;
    FPanEdits[i].Alignment := taCenter;
    FPanEdits[i].Text := '0';
    FPanEdits[i].Tag := i;
    FPanEdits[i].Visible := False;
    FPanEdits[i].ShowHint := True;
    FPanEdits[i].Hint := 'Pan: -100 hard left, 0 centre, 100 hard right';
    FPanEdits[i].OnEditingDone := @PanEditEditingDone;
    FPanEdits[i].OnKeyDown := @PanEditKeyDown;
  end;

  FHScrollBar := TThemeScrollBar.Create(Self);
  FHScrollBar.Parent := Self;
  FHScrollBar.Kind := sbHorizontal;
  FHScrollBar.OnChange := @HScrollBarChange;

  FVScrollOffset := 0;
  FVScrollBar := TThemeScrollBar.Create(Self);
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

{ True while this track is drawn as a single-line row. Guarded rather than
  indexing straight into Project.TrackCollapsed because the layout passes
  walk all MaxTracks slots and the Master row asks about index TrackCount. }
function TArrangementView.TrackIsCollapsed(AIndex: Integer): Boolean;
begin
  Result := (AIndex >= 0) and (AIndex < Project.TrackCount) and
    Project.TrackCollapsed[AIndex];
end;

{ How tall row AIndex is. The Master row (AIndex = Project.TrackCount) never
  collapses, so it falls through to the full height like any expanded track. }
function TArrangementView.TrackRowHeight(AIndex: Integer): Integer;
begin
  if TrackIsCollapsed(AIndex) then
    Result := CollapsedTrackHeight
  else
    Result := TrackHeight;
end;

{ Y the top line of a header - label, pan box, monitor/solo/mute strip -
  starts at. On a full-height row that is the top of the row itself, with
  everything below it still to come; on a collapsed row that line is all
  there is, so it is centred in the row instead of clinging to the top edge
  with dead space underneath. Both the painting and the hit-testing of that
  strip go through here, so the two cannot drift apart. }
function TArrangementView.HeaderLineTop(AIndex: Integer): Integer;
begin
  Result := RowTop(AIndex);
  if TrackIsCollapsed(AIndex) then
    Inc(Result, (CollapsedTrackHeight - (MuteButtonMargin * 2 + MuteButtonSize)) div 2);
end;

{ Y where track row AIndex (or, with AIndex = Project.TrackCount, the Master
  row) starts, net of the current vertical scroll offset - every row-Y
  computation in this unit goes through here so FVScrollOffset only has to
  be threaded through in one place.

  Rows are summed rather than multiplied out now that any of them can be
  collapsed to CollapsedTrackHeight. That makes this O(AIndex) where it used
  to be a multiply; with MaxTracks = 32 and the callers being paint/hit-test
  passes that already walk every row, the difference does not show up. }
function TArrangementView.RowTop(AIndex: Integer): Integer;
var
  i: Integer;
begin
  Result := RulerHeight - FVScrollOffset;
  for i := 0 to AIndex - 1 do
    Result := Result + TrackRowHeight(i);
end;

{ Total pixels of scrollable row content: every track row plus the Master row
  below them. The vertical scrollbar's range and clamp are both this. }
function TArrangementView.AllRowsHeight: Integer;
var
  i: Integer;
begin
  Result := TrackRowHeight(Project.TrackCount); { the Master row }
  for i := 0 to Project.TrackCount - 1 do
    Result := Result + TrackRowHeight(i);
end;

function TArrangementView.TrackIndexAtY(Y: Integer): Integer;
var
  i, RowY: Integer;
begin
  Result := -1;
  if (Y < RulerHeight) or (Y >= ContentHeight) then
    Exit;
  RowY := RulerHeight - FVScrollOffset;
  for i := 0 to Project.TrackCount - 1 do
  begin
    if (Y >= RowY) and (Y < RowY + TrackRowHeight(i)) then
      Exit(i);
    RowY := RowY + TrackRowHeight(i);
  end;
end;

{ Same walk as TrackIndexAtY, but clamped to a real track instead of
  answering -1: what a drag that has run off the top or bottom of the row
  stack wants, where "no row here" is not a usable answer. }
function TArrangementView.NearestTrackIndexAtY(Y: Integer): Integer;
var
  i, RowY: Integer;
begin
  if Project.TrackCount <= 0 then
    Exit(0);
  RowY := RulerHeight - FVScrollOffset;
  for i := 0 to Project.TrackCount - 1 do
  begin
    if Y < RowY + TrackRowHeight(i) then
      Exit(i);
    RowY := RowY + TrackRowHeight(i);
  end;
  Result := Project.TrackCount - 1;
end;

{ The collapse toggle itself. Row heights changing moves every row below this
  one, so the scroll offset has to be re-clamped (a collapse can leave it past
  the new bottom) and the scrollbar re-ranged before anything repaints. }
procedure TArrangementView.ToggleTrackCollapsed(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= Project.TrackCount) then
    Exit;
  Project.TrackCollapsed[AIndex] := not Project.TrackCollapsed[AIndex];
  SetVScrollOffset(FVScrollOffset);
  UpdateVScrollBarRange;
  Invalidate;
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
  { the same 4px inset top and bottom whatever the row height is, so a
    collapsed track's clips squash rather than being cropped }
  Result := Rect(FrameToX(AClip.Position), y + 4,
    FrameToX(AClip.Position + AClip.Length), y + TrackRowHeight(ATrackIndex) - 4);
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

{ Knob X for a gain on the header column's full-width fader track. Taken as a
  value plus its top of scale rather than as a track index, so the Master
  row's fader - which has no track index, and does not share the track scale
  either - is the same slider rather than a copy of it. }
function TArrangementView.VolumeKnobXFor(AVolume, AMaxVolume: Single): Integer;
var
  Range: Integer;
  Value: Single;
begin
  Range := (Width - VolumeSliderMargin) - (HeaderLeft + VolumeSliderMargin);
  Value := AVolume / AMaxVolume;
  if Value < 0 then
    Value := 0;
  if Value > 1 then
    Value := 1;
  Result := (HeaderLeft + VolumeSliderMargin) + Round(Value * Range);
end;

function TArrangementView.VolumeKnobX(ATrackIndex: Integer): Integer;
begin
  Result := VolumeKnobXFor(Project.TrackVolume[ATrackIndex], TrackVolumeMax);
end;

{ Where the clip lamp sits on the Master row. Project.TrackCount is the Master
  row's index everywhere in this unit, and the row never collapses, so the
  mute button's own geometry lands it in exactly the slot a track's mute
  occupies - one box, one definition, no second set of margins to keep in
  step. }
function TArrangementView.MasterClipLightRect: TRect;
begin
  Result := MuteButtonRect(Project.TrackCount);
end;

{ The inverse of VolumeKnobXFor, and it takes the same top of scale for the
  same reason - passing TrackVolumeMax here while the knob was drawn against
  MasterVolumeMax would make the master fader jump on the first click. }
function TArrangementView.XToVolume(X: Integer; AMaxVolume: Single): Single;
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
  Result := Frac * AMaxVolume;
end;

{ The grab band is a tolerance around a line, not a rectangle inside the row,
  so on a collapsed track - whose whole row is shorter than VolumeSliderY -
  it would sit past the bottom edge and steal clicks from the row below. A
  collapsed track simply has no fader to hit. Same for the send sliders. }
function TArrangementView.HitTestVolumeSlider(ATrackIndex, Y: Integer): Boolean;
var
  SliderY: Integer;
begin
  if TrackIsCollapsed(ATrackIndex) then
    Exit(False);
  SliderY := RowTop(ATrackIndex) + VolumeSliderY;
  Result := Abs(Y - SliderY) <= VolumeSliderGrabPixels;
end;

function TArrangementView.MuteButtonRect(ATrackIndex: Integer): TRect;
var
  y: Integer;
begin
  y := HeaderLineTop(ATrackIndex);
  Result := Rect(Width - MuteButtonSize - MuteButtonMargin, y + MuteButtonMargin,
    Width - MuteButtonMargin, y + MuteButtonMargin + MuteButtonSize);
end;

{ Solo, in the slot immediately left of the mute. Same box, same margin - the
  only difference is which two colours it takes. }
function TArrangementView.SoloButtonRect(ATrackIndex: Integer): TRect;
var
  y, BoxLeft: Integer;
begin
  y := HeaderLineTop(ATrackIndex);
  BoxLeft := Width - MuteButtonSize - MuteButtonMargin * 2 - SoloButtonSize;
  Result := Rect(BoxLeft, y + MuteButtonMargin,
    BoxLeft + SoloButtonSize, y + MuteButtonMargin + SoloButtonSize);
end;

{ Input Track only: input-monitoring toggle, sitting immediately left of the
  solo button - lets the live captured signal through to this track's
  audible output with no playhead movement/recording required (see
  AudioEngine.FillBlock's TrackIsInput/TrackMonitorEnabled mix). }
function TArrangementView.MonitorButtonRect(ATrackIndex: Integer): TRect;
var
  y, BoxLeft: Integer;
begin
  y := HeaderLineTop(ATrackIndex);
  BoxLeft := Width - MuteButtonSize - SoloButtonSize - MonitorButtonSize -
    MuteButtonMargin * 3;
  Result := Rect(BoxLeft, y + MuteButtonMargin,
    BoxLeft + MonitorButtonSize, y + MuteButtonMargin + MonitorButtonSize);
end;

{ Where the pan box goes: hard against the left edge of whatever button
  starts the toggle strip on this row, so it stays clear of the strip when
  an Input Track's extra "M" button widens it. Anchored to that rather than
  to a fixed offset from the label, because the label is the side that can
  grow ("Input 10" is wider than "Track 1") and it is better for a long
  label to crowd the box than for the box to overlap a button. }
function TArrangementView.PanEditRect(ATrackIndex: Integer): TRect;
var
  y, RightEdge: Integer;
begin
  y := HeaderLineTop(ATrackIndex);
  if Project.TrackIsInput[ATrackIndex] then
    RightEdge := MonitorButtonRect(ATrackIndex).Left - PanEditGap
  else
    RightEdge := SoloButtonRect(ATrackIndex).Left - PanEditGap;
  { the box is two pixels taller than the 16px buttons, so it starts one
    pixel higher to keep the row optically centred on the same line }
  Result := Rect(RightEdge - PanEditWidth, y + MuteButtonMargin - 1,
    RightEdge, y + MuteButtonMargin - 1 + PanEditHeight);
end;

{ --- per-track send strip -------------------------------------------------
  Each send gets a fixed-width group of (enable button, level slider) laid
  out left to right on one line under the volume fader. The button is the
  "is this track in the room" switch; the slider is how much of it. }

function TArrangementView.SendButtonLeft(ASendIndex: Integer): Integer;
begin
  Result := HeaderLeft + SendLeftMargin + ASendIndex * SendGroupWidth;
end;

{ Moves every send button to its track's current row and syncs its lit
  state, then hides the ones whose row is scrolled out of the visible band
  or would land under the pinned S1/S2 rows (graphic controls paint after
  their parent, so an unhidden one would float over those rows).

  Called from Paint, so it tracks scrolling and track add/remove with no
  extra plumbing. Every write is guarded on the value actually changing -
  SetBounds/Visible on a TGraphicControl invalidates the parent, and doing
  that unconditionally from inside Paint would repaint forever. }
procedure TArrangementView.LayoutSendButtons;
var
  i, s, bx, by: Integer;
  Shown, Lit: Boolean;
begin
  for i := 0 to Project.MaxTracks - 1 do
    for s := 0 to Project.SendCount - 1 do
    begin
      by := RowTop(i) + SendRowY - SendButtonHeight div 2;
      { a collapsed row has no send line to sit on - it stops at the button
        strip, and SendRowY is below its bottom edge }
      Shown := (i < Project.TrackCount) and not TrackIsCollapsed(i) and
        (RowTop(i) >= RulerHeight) and
        (RowTop(i) + TrackRowHeight(i) <= ContentHeight) and
        (by + SendButtonHeight <= SendRowTop(0));
      if FSendButtons[i][s].Visible <> Shown then
        FSendButtons[i][s].Visible := Shown;
      if not Shown then
        Continue;

      bx := SendButtonLeft(s);
      if (FSendButtons[i][s].Left <> bx) or (FSendButtons[i][s].Top <> by) then
        FSendButtons[i][s].SetBounds(bx, by, SendButtonWidth, SendButtonHeight);

      Lit := Project.TrackSendEnabled[i][s];
      if FSendButtons[i][s].Down <> Lit then
        FSendButtons[i][s].Down := Lit;
      { same lit/unlit language as the BT/LF/RP warp buttons }
      if Lit then
      begin
        if FSendButtons[i][s].Color <> clSkyBlue then
        begin
          FSendButtons[i][s].Color := clSkyBlue;
          FSendButtons[i][s].Font.Color := clBlack;
        end;
      end
      else if FSendButtons[i][s].Color <> clBtnFace then
      begin
        FSendButtons[i][s].Color := clBtnFace;
        FSendButtons[i][s].Font.Color := clWindowText;
      end;
    end;
end;

{ Same job as LayoutSendButtons, for the pan boxes: move them onto their
  row, hide the ones whose row is not fully visible, and refresh their text
  from the project. Every assignment is guarded by a comparison because this
  runs on each paint, and assigning Text unconditionally would reset the
  caret of a box being typed into. }
procedure TArrangementView.LayoutPanEdits;
var
  i: Integer;
  R: TRect;
  Shown: Boolean;
  Wanted: string;
begin
  for i := 0 to Project.MaxTracks - 1 do
  begin
    R := PanEditRect(i);
    { the box would still fit on a collapsed row's one line, but that line is
      meant to carry the label and the solo/mute pair and nothing else }
    Shown := (i < Project.TrackCount) and not TrackIsCollapsed(i) and
      (RowTop(i) >= RulerHeight) and
      (RowTop(i) + TrackRowHeight(i) <= ContentHeight) and
      (R.Bottom <= SendRowTop(0));
    if FPanEdits[i].Visible <> Shown then
      { hiding a focused box fires its OnEditingDone first, so a value typed
        and then scrolled away commits rather than being dropped }
      FPanEdits[i].Visible := Shown;
    if not Shown then
      Continue;

    if (FPanEdits[i].Left <> R.Left) or (FPanEdits[i].Top <> R.Top) then
      FPanEdits[i].SetBounds(R.Left, R.Top, R.Right - R.Left, R.Bottom - R.Top);

    { the box being typed into is left alone - it is mid-edit and the project
      does not hold its value yet }
    if not FPanEdits[i].Focused then
    begin
      Wanted := IntToStr(Round(Project.TrackPan[i] * 100));
      if FPanEdits[i].Text <> Wanted then
        FPanEdits[i].Text := Wanted;
    end;
  end;
end;

procedure TArrangementView.PanEditEditingDone(Sender: TObject);
var
  Idx, Value: Integer;
begin
  Idx := TEdit(Sender).Tag;
  if (Idx < 0) or (Idx >= Project.MaxTracks) then
    Exit;

  if TryStrToInt(Trim(TEdit(Sender).Text), Value) then
  begin
    Value := EnsureRange(Value, -100, 100);
    { no PushTrackToEngine, for the same reason the volume fader does not
      need one: FillBlock reads Project.TrackPan directly every block }
    Project.TrackPan[Idx] := Value / 100.0;
  end
  else
    { unparseable - put back what the project still holds rather than
      guessing at a number, so a stray keystroke cannot move a track }
    Value := Round(Project.TrackPan[Idx] * 100);

  { echo the accepted value back, which is also what clamps "500" to "100"
    visibly instead of leaving the box disagreeing with the mixer }
  TEdit(Sender).Text := IntToStr(Value);
  Invalidate;
end;

procedure TArrangementView.PanEditKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  Idx: Integer;
begin
  Idx := TEdit(Sender).Tag;
  if (Idx < 0) or (Idx >= Project.MaxTracks) then
    Exit;

  if Key = VK_RETURN then
  begin
    Key := 0;
    PanEditEditingDone(Sender);
    { focus goes back to the arrangement, or the next keyboard-play note
      types a letter into the pan box instead of sounding }
    if CanFocus then
      SetFocus;
  end
  else if Key = VK_ESCAPE then
  begin
    Key := 0;
    TEdit(Sender).Text := IntToStr(Round(Project.TrackPan[Idx] * 100));
    if CanFocus then
      SetFocus;
  end;
end;

procedure TArrangementView.SendButtonClick(Sender: TObject);
var
  Btn: TSpeedButton;
  TrackIndex, SendIndex: Integer;
begin
  Btn := Sender as TSpeedButton;
  TrackIndex := Btn.Tag div Project.SendCount;
  SendIndex := Btn.Tag mod Project.SendCount;
  if (TrackIndex < 0) or (TrackIndex >= Project.MaxTracks) then
    Exit;
  { the button is its own state (AllowAllUp + a unique GroupIndex makes it a
    plain independent toggle), so read it back rather than flipping our own
    copy and hoping the two agree }
  Project.TrackSendEnabled[TrackIndex][SendIndex] := Btn.Down;
  Invalidate;
end;

function TArrangementView.SendSliderLeft(ASendIndex: Integer): Integer;
begin
  Result := HeaderLeft + SendLeftMargin + ASendIndex * SendGroupWidth +
    SendButtonWidth + 6;
end;

function TArrangementView.SendKnobX(ATrackIndex, ASendIndex: Integer): Integer;
var
  Value: Single;
begin
  Value := Project.TrackSendLevel[ATrackIndex][ASendIndex];
  if Value < 0 then Value := 0;
  if Value > 1 then Value := 1;
  Result := SendSliderLeft(ASendIndex) + Round(Value * SendSliderWidth);
end;

function TArrangementView.XToSendLevel(ASendIndex, X: Integer): Single;
var
  Frac: Single;
begin
  Frac := (X - SendSliderLeft(ASendIndex)) / SendSliderWidth;
  if Frac < 0 then Frac := 0;
  if Frac > 1 then Frac := 1;
  Result := Frac;
end;

function TArrangementView.HitTestSendSlider(ATrackIndex, ASendIndex, X, Y: Integer): Boolean;
var
  SliderY, SliderX: Integer;
begin
  if TrackIsCollapsed(ATrackIndex) then
    Exit(False);
  SliderY := RowTop(ATrackIndex) + SendRowY;
  SliderX := SendSliderLeft(ASendIndex);
  Result := (Abs(Y - SliderY) <= SendSliderGrabPixels) and
    (X >= SliderX - SendSliderRadius) and
    (X <= SliderX + SendSliderWidth + SendSliderRadius);
end;

{ --- pinned send-bus rows -------------------------------------------------
  Stacked at the very bottom of the header column, S1 above S2, drawn after
  (and therefore over) the scrolling track headers. }

function TArrangementView.SendRowTop(ASendIndex: Integer): Integer;
begin
  Result := ContentHeight - (Project.SendCount - ASendIndex) * SendRowHeight;
end;

function TArrangementView.SendRowIndexAtY(Y: Integer): Integer;
var
  s: Integer;
begin
  Result := -1;
  for s := 0 to Project.SendCount - 1 do
    if (Y >= SendRowTop(s)) and (Y < SendRowTop(s) + SendRowHeight) then
      Exit(s);
end;

function TArrangementView.SendRowMuteRect(ASendIndex: Integer): TRect;
var
  y: Integer;
begin
  y := SendRowTop(ASendIndex);
  Result := Rect(Width - MuteButtonSize - MuteButtonMargin, y + MuteButtonMargin,
    Width - MuteButtonMargin, y + MuteButtonMargin + MuteButtonSize);
end;

{ PRE/POST switch, immediately left of the bus mute - the one control on
  these rows that isn't in Ableton and is on every 90s desk. }
function TArrangementView.SendRowPreRect(ASendIndex: Integer): TRect;
var
  y, RightEdge: Integer;
begin
  y := SendRowTop(ASendIndex);
  RightEdge := Width - MuteButtonSize - MuteButtonMargin * 2 - 34;
  Result := Rect(RightEdge, y + MuteButtonMargin, RightEdge + 34,
    y + MuteButtonMargin + MuteButtonSize);
end;

function TArrangementView.ReturnSliderLeft: Integer;
begin
  Result := HeaderLeft + 30;
end;

function TArrangementView.ReturnKnobX(ASendIndex: Integer): Integer;
var
  Value: Single;
  Range: Integer;
begin
  Range := (Width - VolumeSliderMargin) - ReturnSliderLeft;
  if Range < 1 then
    Range := 1;
  Value := Project.SendReturnLevel[ASendIndex] / TrackVolumeMax;
  if Value < 0 then Value := 0;
  if Value > 1 then Value := 1;
  Result := ReturnSliderLeft + Round(Value * Range);
end;

function TArrangementView.XToReturnLevel(X: Integer): Single;
var
  Range: Integer;
  Frac: Single;
begin
  Range := (Width - VolumeSliderMargin) - ReturnSliderLeft;
  if Range <= 0 then
    Exit(1.0);
  Frac := (X - ReturnSliderLeft) / Range;
  if Frac < 0 then Frac := 0;
  if Frac > 1 then Frac := 1;
  Result := Frac * TrackVolumeMax;
end;

function TArrangementView.HitTestReturnSlider(ASendIndex, X, Y: Integer): Boolean;
var
  SliderY: Integer;
begin
  SliderY := SendRowTop(ASendIndex) + SendRowHeight - 12;
  Result := (Abs(Y - SliderY) <= VolumeSliderGrabPixels) and
    (X >= ReturnSliderLeft - VolumeSliderRadius);
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
  i, j, MarkerCount, DragZoneCount: Integer;
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
    { clip gain only - the track fader is applied by AudioEngine.FillBlock
      now, not baked in here, so there is a point in the chain a pre-fader
      send can be tapped from (and so a volume drag no longer has to push
      the whole clip array through the command ring to be heard) }
    Items[i].Gain := Clip.Gain;
    Items[i].WarpMode := Clip.WarpMode;
    Items[i].DetuneSemitones := Clip.PitchSemitones;

    if Clip.SampleID <= High(Project.SamplePeriods) then
      Items[i].PeriodFrames := Project.SamplePeriods[Clip.SampleID]
    else
      Items[i].PeriodFrames := 0;

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

    { AU mode's phase-vocoder stretch is expensive (a whole-clip FFT pass),
      so it is built here - off the audio thread, only when a clip's warp
      state actually changed enough to push a fresh snapshot - and cached by
      PhaseVocoder itself (content-hash keyed), not rebuilt per push. The
      audio thread only ever reads the returned buffer - see
      AudioEngine.AudioClipSample. }
    if (Clip.WarpMode = SampleTypes.WarpModeAudio) and (MarkerCount >= 2) then
      Items[i].AUData := PhaseVocoder.GetAUAudio(Sample.Data, Sample.FrameCount,
        Sample.Channels, AudioEngine.ProjectSampleRate, Clip.Offset, Clip.Length,
        Clip.WarpMarkers, Clip.AUFFTSize, Items[i].AUFrameCount)
    else
    begin
      Items[i].AUData := nil;
      Items[i].AUFrameCount := 0;
    end;

    DragZoneCount := Length(Clip.DragZones);
    if DragZoneCount > MaxClipDragZones then
      DragZoneCount := MaxClipDragZones;
    Items[i].DragZoneCount := DragZoneCount;
    for j := 0 to DragZoneCount - 1 do
    begin
      Items[i].DragZoneSourceStart[j] := Clip.DragZones[j].SourceStart;
      Items[i].DragZoneSourceEnd[j] := Clip.DragZones[j].SourceEnd;
      Items[i].DragZoneShift[j] := Clip.DragZones[j].Shift;
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
  concept vertically, a row is one of two fixed heights) and covers every
  track row plus the Master row. }
procedure TArrangementView.SetVScrollOffset(AOffset: Integer);
var
  MaxOffset: Integer;
begin
  MaxOffset := AllRowsHeight - (ContentHeight - RulerHeight);
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
  TotalPixels := AllRowsHeight; { every track row, plus the Master row }
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

  { row rules and the vertical grid below are the same weight of mark as an
    editor's subdivision line, and take the same colour }
  Canvas.Pen.Color := ThemeGridSub;
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
    Canvas.TextOut(x + 4, 4, IntToStr(BarNum));
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
  i, y, h, s, SliderY, kx: Integer;
  MuteRect, SoloRect, MonitorRect: TRect;
begin
  for i := 0 to Project.TrackCount - 1 do
  begin
    y := RowTop(i);
    h := TrackRowHeight(i);
    { row scrolled fully or partially out of the visible band - full-row
      cull rather than clip, so nothing bleeds into the ruler above or the
      horizontal scrollbar's margin below }
    if (y < RulerHeight) or (y + h > ContentHeight) then
      Continue;
    { the focused row is button face pushed one step away from the rest -
      down on a light palette, up on a dark one, which is the direction
      clBtnShadow already moves in }
    if i = FKeyboardTrack then
      Canvas.Brush.Color := clBtnShadow
    else
      Canvas.Brush.Color := clBtnFace;
    Canvas.FillRect(Rect(HeaderLeft, y, Width, y + h));
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(HeaderLeft, y, Width, y + h);
    Canvas.Brush.Style := bsClear;
    if Project.TrackIsInput[i] then
      Canvas.TextOut(HeaderLeft + 8, HeaderLineTop(i) + 8, 'Input ' + IntToStr(i + 1))
    else
      Canvas.TextOut(HeaderLeft + 8, HeaderLineTop(i) + 8, 'Track ' + IntToStr(i + 1));
    Canvas.Brush.Style := bsSolid;

    { simple on/off mute toggle }
    MuteRect := MuteButtonRect(i);
    if Project.TrackEnabled[i] then
      Canvas.Brush.Color := clLime
    else
      Canvas.Brush.Color := clRed;
    { the fill is always one of the two accents, never chrome, so the edge
      wants to stay a hard dark line against it in both palettes }
    Canvas.Pen.Color := clWindowFrame;
    Canvas.Rectangle(MuteRect);

    { solo. Grey unlit, yellow lit - and like the mute it is always one of
      two fixed accents rather than chrome, so it keeps the hard frame }
    SoloRect := SoloButtonRect(i);
    if Project.TrackSolo[i] then
      Canvas.Brush.Color := clYellow
    else
      Canvas.Brush.Color := clGray;
    Canvas.Pen.Color := clWindowFrame;
    Canvas.Rectangle(SoloRect);

    { Input Track only: "M" input-monitoring toggle }
    if Project.TrackIsInput[i] then
    begin
      MonitorRect := MonitorButtonRect(i);
      if Project.TrackMonitorEnabled[i] then
        Canvas.Brush.Color := clYellow
      else
        Canvas.Brush.Color := clBtnFace;
      { unlit, this button is button face sitting on a header of button face -
        the border is the only thing that says there is a button here, so it
        takes the border colour rather than the hard frame the mute uses }
      Canvas.Pen.Color := clBtnShadow;
      Canvas.Rectangle(MonitorRect);
      Canvas.Brush.Style := bsClear;
      Canvas.TextOut(MonitorRect.Left + 4, MonitorRect.Top - 1, 'M');
      Canvas.Brush.Style := bsSolid;
    end;

    { a collapsed row ends here: the label and the toggle strip above are the
      whole of it, and everything below - the fader and the send strip - lives
      in the height that was taken away. The values themselves are untouched;
      only the controls that would set them are gone until it expands again. }
    if TrackIsCollapsed(i) then
      Continue;

    { simple volume slider - a plain line with a draggable knob, no readout }
    SliderY := y + VolumeSliderY;
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Line(HeaderLeft + VolumeSliderMargin, SliderY, Width - VolumeSliderMargin, SliderY);
    kx := VolumeKnobX(i);
    Canvas.Brush.Color := clHighlight;
    Canvas.Pen.Color := clWindowFrame;
    Canvas.Ellipse(kx - VolumeSliderRadius, SliderY - VolumeSliderRadius,
      kx + VolumeSliderRadius, SliderY + VolumeSliderRadius);

    { send strip: an S1/S2 enable button per bus, each with its own level
      slider. The lit colour is deliberately clSkyBlue, the exact same
      "this one is active" language as the BT/LF/RP warp-mode buttons - a
      subtle darken was the first attempt and it was unreadable against
      clBtnFace on a normal GTK theme. }
    for s := 0 to Project.SendCount - 1 do
    begin
      { the S1/S2 button itself is a real TSpeedButton (see
        LayoutSendButtons) and draws itself over this header - only its
        level slider is painted here }

      { The track line is always drawn, so there is visibly a control here
        whether or not the send is on; only the FILLED part and the knob
        change with state, so how far the send is armed stays readable
        while it's switched out. }
      SliderY := y + SendRowY;
      Canvas.Pen.Color := clBtnShadow;
      Canvas.Line(SendSliderLeft(s), SliderY,
        SendSliderLeft(s) + SendSliderWidth, SliderY);
      kx := SendKnobX(i, s);
      if Project.TrackSendEnabled[i][s] then
      begin
        Canvas.Pen.Color := clHighlight;
        Canvas.Pen.Width := 3;
        Canvas.Line(SendSliderLeft(s), SliderY, kx, SliderY);
        Canvas.Pen.Width := 1;
        Canvas.Brush.Color := clHighlight;
      end
      else
        Canvas.Brush.Color := clBtnFace;
      Canvas.Pen.Color := clWindowFrame;
      Canvas.Ellipse(kx - SendSliderRadius, SliderY - SendSliderRadius,
        kx + SendSliderRadius, SliderY + SendSliderRadius);
    end;
  end;

  { master bus row, always the last row, below every real track. No clips and
    no mute - clicking it selects the master effects chain - but it does carry
    the master fader and the clip lamp, the two things that belong to the mix
    as a whole rather than to any one track. }
  y := MasterRowTop;
  h := TrackRowHeight(Project.TrackCount);
  if (y >= RulerHeight) and (y + h <= ContentHeight) then
  begin
    if FKeyboardTrack = -2 then
      Canvas.Brush.Color := clBtnShadow
    else
      Canvas.Brush.Color := clBtnFace;
    Canvas.FillRect(Rect(HeaderLeft, y, Width, y + h));
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(HeaderLeft, y, Width, y + h);
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Style := [fsBold];
    Canvas.TextOut(HeaderLeft + 8, y + 8, 'Master');
    Canvas.Font.Style := [];
    Canvas.Brush.Style := bsSolid;

    { clip lamp - the mute button's box, but read-only: it reports what the
      mix is doing rather than setting anything. State comes from
      PollMasterMeter, never from the engine directly, so a repaint provoked
      by anything else (a scroll, a clip drag) cannot advance or clear it. }
    MuteRect := MasterClipLightRect;
    case FMasterMeterState of
      2: Canvas.Brush.Color := clRed;
      1: Canvas.Brush.Color := clYellow;
    else
      Canvas.Brush.Color := clLime;
    end;
    Canvas.Pen.Color := clWindowFrame;
    Canvas.Rectangle(MuteRect);

    { master fader - the same slider a track has, in the same place on the
      row - same control, same place, same scale, because putting it
      anywhere else would only make it look like a different kind of thing }
    SliderY := y + VolumeSliderY;
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Line(HeaderLeft + VolumeSliderMargin, SliderY, Width - VolumeSliderMargin, SliderY);
    kx := VolumeKnobXFor(Project.MasterVolume, MasterVolumeMax);
    Canvas.Brush.Color := clHighlight;
    Canvas.Pen.Color := clWindowFrame;
    Canvas.Ellipse(kx - VolumeSliderRadius, SliderY - VolumeSliderRadius,
      kx + VolumeSliderRadius, SliderY + VolumeSliderRadius);
  end;
end;

{ The two send-bus rows, pinned to the bottom of the header column. Drawn
  after the track headers so they sit over whichever rows happen to have
  scrolled underneath, and confined to X >= HeaderLeft so they never reach
  into the timeline. }
procedure TArrangementView.DrawSendRows;
var
  s, y, kx, SliderY: Integer;
  R: TRect;
begin
  for s := 0 to Project.SendCount - 1 do
  begin
    y := SendRowTop(s);
    if y < RulerHeight then
      Continue;

    if FKeyboardTrack = Project.SendIndexToBus(s) then
      Canvas.Brush.Color := clBtnShadow
    else
      Canvas.Brush.Color := clBtnFace;
    Canvas.FillRect(Rect(HeaderLeft, y, Width, y + SendRowHeight));
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(HeaderLeft, y, Width, y + SendRowHeight);

    Canvas.Brush.Style := bsClear;
    Canvas.Font.Style := [fsBold];
    Canvas.TextOut(HeaderLeft + 6, y + 3, 'S' + IntToStr(s + 1));
    Canvas.Font.Style := [];
    { effect count, so it's obvious at a glance whether a bus has anything
      on it without having to select it }
    Canvas.TextOut(HeaderLeft + 30, y + 3,
      Format('%d fx', [Project.SendEffectCount[s]]));
    Canvas.Brush.Style := bsSolid;

    { bus mute - same lime/red language as a track's own mute }
    R := SendRowMuteRect(s);
    if Project.SendEnabled[s] then
      Canvas.Brush.Color := clLime
    else
      Canvas.Brush.Color := clRed;
    Canvas.Pen.Color := clWindowFrame;
    Canvas.Rectangle(R);

    { PRE/POST fader-tap switch }
    R := SendRowPreRect(s);
    if Project.SendPreFader[s] then
      Canvas.Brush.Color := clBtnShadow
    else
      Canvas.Brush.Color := clBtnFace;
    { chrome-coloured in the POST state, so border rather than hard frame -
      same reasoning as the input-monitor toggle above }
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Rectangle(R);
    Canvas.Brush.Style := bsClear;
    if Project.SendPreFader[s] then
    begin
      { literal on purpose: PRE is lettered onto the clBtnShadow chip, and
        that chip is a mid grey in both palettes - white reads on it either
        way, where clWindowText would invert with the theme and lose the
        contrast in one of them }
      Canvas.Font.Color := clWhite;
      Canvas.TextOut(R.Left + 5, R.Top - 1, 'PRE');
    end
    else
      Canvas.TextOut(R.Left + 3, R.Top - 1, 'POST');
    Canvas.Font.Color := clWindowText;
    Canvas.Brush.Style := bsSolid;

    { return level - how much of the processed bus comes back to master }
    SliderY := y + SendRowHeight - 12;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(HeaderLeft + 4, SliderY - 8, 'Rtn');
    Canvas.Brush.Style := bsSolid;
    Canvas.Pen.Color := clBtnShadow;
    Canvas.Line(ReturnSliderLeft, SliderY, Width - VolumeSliderMargin, SliderY);
    kx := ReturnKnobX(s);
    Canvas.Brush.Color := clHighlight;
    Canvas.Pen.Color := clWindowFrame;
    Canvas.Ellipse(kx - VolumeSliderRadius, SliderY - VolumeSliderRadius,
      kx + VolumeSliderRadius, SliderY + VolumeSliderRadius);
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
  WaveTop: Integer;
begin
  R := ClipPixelRect(ATrack, AClip);
  if (R.Right < 0) or (R.Left > LaneWidth) then
    Exit;
  if (R.Top < RulerHeight) or (R.Bottom > ContentHeight) then
    Exit;

  { neutral dark interior so the waveform (drawn in the track's color)
    reads clearly against it, full width - no horizontal border/inset.

    Literal, and staying literal: this backdrop belongs to FTrackColors, not
    to the theme. Those colours are bright mid-tones chosen to identify a
    track, they are the same in every mode, and on a light interior they
    would wash out - so the clip interior cannot follow clWindow without
    taking the waveform's legibility with it. }
  Canvas.Brush.Color := clBlack;
  Canvas.FillRect(R);
  { on a full-height row the top 14px are reserved for the clip's name; a
    collapsed row has no room to spare for it (see the name below, which is
    skipped there), so the waveform takes the whole box instead of being
    squashed into what a caption would have left }
  if TrackIsCollapsed(ATrack) then
    WaveTop := R.Top + 1
  else
    WaveTop := R.Top + 14;
  if AClip.SampleID <= High(Project.SamplePeaks) then
    DrawWaveform(Canvas, Rect(R.Left, WaveTop, R.Right, R.Bottom),
      Project.SamplePeaks[AClip.SampleID],
      Project.SamplePool[AClip.SampleID].FrameCount, AClip.Offset,
      AClip.Offset + AClip.Length, AClip.WarpMarkers, FTrackColors[ATrack],
      AClip.WarpMode, Project.SampleTransients[AClip.SampleID], AClip.DragZones);

  { border only (Frame, not Rectangle - Rectangle also fills the interior
    with the current brush, which would erase the waveform just drawn) }
  if AIsSelected then
    Canvas.Pen.Color := clRed
  else
    Canvas.Pen.Color := FTrackColors[ATrack];
  Canvas.Pen.Width := 2;
  Canvas.Frame(R);
  Canvas.Pen.Width := 1;

  if TrackIsCollapsed(ATrack) then
    Exit;

  Canvas.Brush.Style := bsClear;
  { on the always-dark clip interior above, so it stays white in every mode }
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
  { last, so the pinned send rows sit over whichever track headers have
    scrolled under them }
  DrawSendRows;
  { the S1/S2 toggles and the pan boxes are real controls and paint
    themselves after this returns; all this does is put them where their row
    currently is }
  LayoutSendButtons;
  LayoutPanEdits;
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

{ Drains the engine's master peak and works out what colour the clip lamp is.
  Driven from MainForm's 150ms poll timer, which runs whether or not the
  transport is - input monitoring makes sound with the playhead parked, and a
  meter that only worked during playback would be dark exactly when someone is
  setting a guitar's level.

  The engine's peak accumulates across every block since the last call, so
  nothing is missed between polls; the red latch then holds it long enough to
  be read. Repaints only when the colour actually changes - at 6-7 polls a
  second, invalidating unconditionally would be a permanent repaint of the
  whole arrangement for a 16-pixel box. }
procedure TArrangementView.PollMasterMeter;
var
  Peak: Single;
  NowMs: QWord;
  NewState: Integer;
begin
  Peak := AudioEngineTakeMasterPeak;
  { NowMs, not Now: SysUtils.Now is a TDateTime and this is a tick count }
  NowMs := GetTickCount64;
  if Peak >= MasterMeterClipLevel then
    FMasterClipHoldUntil := NowMs + MasterClipHoldMs;

  if NowMs < FMasterClipHoldUntil then
    NewState := 2
  else if Peak >= MasterMeterWarnLevel then
    NewState := 1
  else
    NewState := 0;

  if NewState = FMasterMeterState then
    Exit;
  FMasterMeterState := NewState;
  Invalidate;
end;

procedure TArrangementView.RefreshTrack(ATrackIndex: Integer);
begin
  PushTrackToEngine(ATrackIndex);
  UpdateScrollBarRange;
  UpdateVScrollBarRange;
  Invalidate;
end;

{ Whole-project version of the above, for the "everything changed" callers
  (project open, New, tempo rescale). Calling RefreshTrack in a loop instead
  is quadratic in the thing that matters most on a project open: its
  UpdateScrollBarRange asks ContentEndFrame for the end of the arrangement,
  and that walks EVERY clip on EVERY track - so a 32-track loop re-walked
  the entire project's clip list 32 times over to arrive at the same number
  each time. The engine push is genuinely per-track and stays in the loop;
  the two range updates and the repaint are project-wide and happen once. }
procedure TArrangementView.RefreshAllTracks;
var
  t: Integer;
begin
  for t := 0 to Project.TrackCount - 1 do
    PushTrackToEngine(t);
  UpdateScrollBarRange;
  UpdateVScrollBarRange;
  Invalidate;
end;

procedure TArrangementView.SetCursorFrame(AFrameOffset: Int64);
var
  x: Integer;
  MarginFrames, OldFrame: Int64;

  { Marks just the narrow column the playhead line occupies as needing
    repaint, rather than the whole view. Paint still runs in full, but the
    canvas' clip box is now that column, which DrawWaveform reads (see
    there) - so the clip waveforms, by far the most expensive thing Paint
    does, are skipped for every column outside it. }
  procedure InvalidateCursorColumn(AFrame: Int64);
  var
    cx: Integer;
    R: TRect;
  begin
    if not HandleAllocated then
      Exit;
    cx := FrameToX(AFrame);
    if (cx < -CursorInvalidateMargin) or
      (cx >= LaneWidth + CursorInvalidateMargin) then
      Exit;
    R := Rect(cx - CursorInvalidateMargin, 0,
      cx + CursorInvalidateMargin + 1, ContentHeight);
    LCLIntf.InvalidateRect(Handle, @R, False);
  end;

begin
  if AFrameOffset = FCursorFrame then
    Exit;
  OldFrame := FCursorFrame;
  FCursorFrame := AFrameOffset;

  x := FrameToX(AFrameOffset);
  if (x < 0) or (x >= LaneWidth) then
  begin
    { the view itself scrolled - everything moved, so everything repaints }
    MarginFrames := Round(Int64(AutoScrollMarginPixels) * AudioEngine.ProjectSampleRate /
      FPixelsPerSecond);
    SetScrollFrame(AFrameOffset - MarginFrames);
    Invalidate;
    Exit;
  end;

  { nothing moved except the playhead line: repaint where it was and where
    it now is. This runs on every playback poll tick (6-7x a second), and
    used to repaint every lane, header, ruler and clip waveform each time. }
  InvalidateCursorColumn(OldFrame);
  InvalidateCursorColumn(FCursorFrame);
end;

procedure TArrangementView.ClearSelection;
begin
  SelectClip(-1, -1);
  Invalidate;
end;

{ Drops the focused-track highlight and tells the device panel to follow.
  Needed after a track is deleted: every later track shifts down one index,
  so a retained FKeyboardTrack would silently start pointing at a different
  track (or past the end of the list). }
procedure TArrangementView.ClearKeyboardTrack;
begin
  if FKeyboardTrack = -1 then
    Exit;
  FKeyboardTrack := -1;
  if Assigned(FOnKeyboardTrackChanged) then
    FOnKeyboardTrackChanged(Self);
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
  TrackIndex, ClipIndex, SendIndex: Integer;
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
      Exit;
    end;

    { In the header column the right button is the collapse toggle: over
      exactly the rows (and the same bounds) a left-click selects a track in,
      it folds that track down to its top line - and its timeline row with it -
      or puts it back. The pinned S1/S2 rows and the Master row are not tracks
      and keep no collapsed state, so they are left alone. }
    if X >= HeaderLeft then
    begin
      if SendRowIndexAtY(Y) < 0 then
        ToggleTrackCollapsed(TrackIndexAtY(Y));
      Exit;
    end;

    { Right-drag anywhere in the lane area draws a time-range selection -
      clips included. This used to be the left-button gesture, but a left
      press that landed on a clip was always a clip move/resize grab, so a
      drag that started over (or near) any clip selected and dragged that
      clip instead of drawing a range. On the right button nothing else
      competes for the press, so the drag can start from anywhere. }

    TrackIndex := TrackIndexAtY(Y);
    if TrackIndex < 0 then
      Exit;

    Frame := SnapFrame(XToFrame(X));
    if Frame < 0 then
      Frame := 0;

    { same teardown the old left-button path did before arming a range drag:
      drop any single-clip selection and any previous range, so a plain
      right-click (press with no drag) clears the selection and MouseMove is
      what turns this into a real range }
    SelectClip(-1, -1);
    FGroupDragItems := nil;
    FRangeSelectActive := False;
    FDragMode := dmRangeSelect;
    FDragActive := True;
    FRangeDragStartFrame := Frame;
    FRangeDragStartTrack := TrackIndex;
    Invalidate;
    Exit;
  end;

  if Button <> mbLeft then
    Exit;

  { pinned send-bus rows first - they're drawn over the scrolling track
    headers, so they have to be hit-tested over them too }
  if X >= HeaderLeft then
  begin
    SendIndex := SendRowIndexAtY(Y);
    if SendIndex >= 0 then
    begin
      if PtInRect(SendRowMuteRect(SendIndex), Point(X, Y)) then
      begin
        Project.SendEnabled[SendIndex] := not Project.SendEnabled[SendIndex];
        Invalidate;
        Exit;
      end;
      if PtInRect(SendRowPreRect(SendIndex), Point(X, Y)) then
      begin
        Project.SendPreFader[SendIndex] := not Project.SendPreFader[SendIndex];
        Invalidate;
        Exit;
      end;
      if HitTestReturnSlider(SendIndex, X, Y) then
      begin
        FDraggingReturnSend := SendIndex;
        Project.SendReturnLevel[SendIndex] := XToReturnLevel(X);
        Invalidate;
        Exit;
      end;
      { anywhere else on the row selects the bus, so the effects rack below
        switches to that send's chain - same gesture as the Master row }
      SelectClip(-1, -1);
      if FKeyboardTrack <> Project.SendIndexToBus(SendIndex) then
      begin
        FKeyboardTrack := Project.SendIndexToBus(SendIndex);
        if Assigned(FOnKeyboardTrackChanged) then
          FOnKeyboardTrackChanged(Self);
      end;
      Invalidate;
      Exit;
    end;
  end;

  if (X >= HeaderLeft) and (Y >= MasterRowTop) and
    (Y < MasterRowTop + TrackRowHeight(Project.TrackCount)) then
  begin
    { the clip lamp is not a switch, but a latched red that cannot be cleared
      is a light that stops meaning anything after the first clip of the
      session - so clicking it drops the latch and lets the next poll say
      what the mix is doing now }
    if PtInRect(MasterClipLightRect, Point(X, Y)) then
    begin
      FMasterClipHoldUntil := 0;
      FMasterMeterState := 0;
      Invalidate;
      Exit;
    end;

    { Project.TrackCount is the Master row, and it never collapses, so the
      per-track fader hit test lands on exactly the line drawn above }
    if HitTestVolumeSlider(Project.TrackCount, Y) then
    begin
      FDraggingMasterVolume := True;
      Project.MasterVolume := XToVolume(X, MasterVolumeMax);
      Invalidate;
      Exit;
    end;

    SelectClip(-1, -1);
    if FKeyboardTrack <> Project.BusMaster then
    begin
      FKeyboardTrack := Project.BusMaster;
      if Assigned(FOnKeyboardTrackChanged) then
        FOnKeyboardTrackChanged(Self);
    end;
    Invalidate;
    Exit;
  end;

  TrackIndex := TrackIndexAtY(Y);

  if (TrackIndex >= 0) and (X >= HeaderLeft) then
    for SendIndex := 0 to Project.SendCount - 1 do
    begin
      { no button case here - the S1/S2 toggles are real controls and the
        widgetset routes their clicks; this only has to find the sliders }
      if HitTestSendSlider(TrackIndex, SendIndex, X, Y) then
      begin
        FDraggingSendTrack := TrackIndex;
        FDraggingSendIndex := SendIndex;
        Project.TrackSendLevel[TrackIndex][SendIndex] := XToSendLevel(SendIndex, X);
        Invalidate;
        Exit;
      end;
    end;

  if (TrackIndex >= 0) and (X >= HeaderLeft) and
    PtInRect(MuteButtonRect(TrackIndex), Point(X, Y)) then
  begin
    Project.TrackEnabled[TrackIndex] := not Project.TrackEnabled[TrackIndex];
    Invalidate;
    Exit;
  end;

  if (TrackIndex >= 0) and (X >= HeaderLeft) and
    PtInRect(SoloButtonRect(TrackIndex), Point(X, Y)) then
  begin
    { plain toggle, not radio - solos accumulate, and the mixer silences
      everything not soloed for as long as any one of them is on }
    Project.TrackSolo[TrackIndex] := not Project.TrackSolo[TrackIndex];
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
    { no PushTrackToEngine: FillBlock reads Project.TrackVolume directly
      now, so dragging the fader no longer has to rebuild and re-push the
      whole clip array through the command ring on every mouse move }
    Project.TrackVolume[TrackIndex] := XToVolume(X, TrackVolumeMax);
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

  { Selecting a track is a HEADER gesture only. Clicking a clip - or empty
    lane - in a track's timeline row used to switch the selected track as a
    side effect, which meant editing a clip on one track silently moved
    keyboard play, the device panel and the effects rack onto it. The header
    column is the deliberate way to say "this track now"; the lane is where
    you work on clips, and the two no longer collide. }
  if (X >= HeaderLeft) and (TrackIndex <> FKeyboardTrack) then
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

    { clicking empty lane space just seeks and drops any active range - the
      range-select drag itself moved to the right button (see the mbRight
      branch at the top), so a left drag here no longer starts one }
    FRangeSelectActive := False;

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

  if FDraggingMasterVolume then
  begin
    Project.MasterVolume := XToVolume(X, MasterVolumeMax);
    Invalidate;
    Exit;
  end;

  if FDraggingVolumeTrack >= 0 then
  begin
    Project.TrackVolume[FDraggingVolumeTrack] := XToVolume(X, TrackVolumeMax);
    Invalidate;
    Exit;
  end;

  if FDraggingSendTrack >= 0 then
  begin
    Project.TrackSendLevel[FDraggingSendTrack][FDraggingSendIndex] :=
      XToSendLevel(FDraggingSendIndex, X);
    Invalidate;
    Exit;
  end;

  if FDraggingReturnSend >= 0 then
  begin
    Project.SendReturnLevel[FDraggingReturnSend] := XToReturnLevel(X);
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

        Row := NearestTrackIndexAtY(Y);
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
  DiscardZones: TDragZoneArray;
  SplitRel, SplitSource: Int64;
  t, g, i, GrabbedTrack, GrabbedIdx: Integer;
  Snapshotted: array[0..Project.MaxTracks - 1] of Boolean;
  NewClips: TClipArray;
  HasGroupItem, IsGroupMember: Boolean;
begin
  inherited MouseUp(Button, Shift, X, Y);

  { the range-select drag is the one right-button gesture, and it's finished
    the moment the button comes up - FRangeSelectActive/the range bounds are
    left standing, that IS the selection. Handled (and returned) before the
    slider drags are cleared below so a stray right-click during a fader or
    send drag can't cancel it. }
  if Button = mbRight then
  begin
    if FDragActive and (FDragMode = dmRangeSelect) then
    begin
      FDragActive := False;
      FDragMode := dmNone;
      Invalidate;
    end;
    Exit;
  end;

  FDraggingVolumeTrack := -1;
  FDraggingMasterVolume := False;
  FDraggingSendTrack := -1;
  FDraggingReturnSend := -1;

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
          { source frames, not FDragOrigClip.Length - the receiver adds this
            to Offset to index back into the sample, see ClipSourceLength }
          FOnClipActivate(Self, FDragOrigClip.SampleID, FDragOrigClip.Offset,
            Project.ClipSourceLength(FDragOrigClip));
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
          if FDragOrigClip.WarpMode = SampleTypes.WarpModeDrag then
            SplitRel := SplitDragZones(FDragOrigClip.DragZones,
              FDragCurrentClip.Position - FDragOrigClip.Position, DiscardZones,
              FDragCurrentClip.DragZones, @SplitSource)
          else
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
    { source frames, not .Length - see ClipSourceLength }
    FOnClipActivate(Self, Project.Tracks[TrackIndex].Clips[ClipIndex].SampleID,
      Project.Tracks[TrackIndex].Clips[ClipIndex].Offset,
      Project.ClipSourceLength(Project.Tracks[TrackIndex].Clips[ClipIndex]));
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
  DiscardZones, KeptZones: TDragZoneArray;
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
    if AClip.WarpMode = SampleTypes.WarpModeDrag then
    begin
      SplitRel := SplitDragZones(AClip.DragZones, NewStart - AClip.Position,
        DiscardZones, KeptZones, @SplitSource);
      AResult.DragZones := KeptZones;
    end
    else
    begin
      SplitRel := SplitWarpMarkers(AClip.WarpMarkers, NewStart - AClip.Position,
        DiscardMarkers, KeptMarkers, AClip.WarpMode,
        AudioEngine.ProjectSampleRate, @SplitSource);
      AResult.WarpMarkers := KeptMarkers;
    end;
    AResult.Offset := AClip.Offset + SplitSource;
    AResult.Position := AClip.Position + SplitRel;
  end;

  if NewEnd < ClipEnd then
  begin
    if AClip.WarpMode = SampleTypes.WarpModeDrag then
    begin
      SplitRel := SplitDragZones(AResult.DragZones, NewEnd - AResult.Position,
        KeptZones, DiscardZones);
      AResult.DragZones := KeptZones;
    end
    else
    begin
      SplitRel := SplitWarpMarkers(AResult.WarpMarkers, NewEnd - AResult.Position,
        KeptMarkers, DiscardMarkers, AClip.WarpMode);
      AResult.WarpMarkers := KeptMarkers;
    end;
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
            Project.SampleTransients[Clip.SampleID],
            Project.SamplePeriods[Clip.SampleID], Clip.DragZones,
            Clip.AUFFTSize) * Clip.Gain;
        Buffer[OutIdx + 1] := Buffer[OutIdx + 1] +
          DetunedSample(Clip.WarpMarkers, ClipRelFrame, Clip.PitchSemitones, Clip.Offset,
            Sample.Data, Sample.FrameCount, Sample.Channels,
            AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
            Project.SampleTransients[Clip.SampleID],
            Project.SamplePeriods[Clip.SampleID], Clip.DragZones,
            Clip.AUFFTSize) * Clip.Gain;
      end
      else
      begin
        Buffer[OutIdx] := Buffer[OutIdx] +
          DetunedSample(Clip.WarpMarkers, ClipRelFrame, Clip.PitchSemitones, Clip.Offset,
            Sample.Data, Sample.FrameCount, Sample.Channels,
            AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
            Project.SampleTransients[Clip.SampleID],
            Project.SamplePeriods[Clip.SampleID], Clip.DragZones,
            Clip.AUFFTSize) * Clip.Gain;
        Buffer[OutIdx + 1] := Buffer[OutIdx + 1] +
          DetunedSample(Clip.WarpMarkers, ClipRelFrame, Clip.PitchSemitones, Clip.Offset,
            Sample.Data, Sample.FrameCount, Sample.Channels,
            AudioEngine.ProjectSampleRate, Clip.WarpMode, 1, Clip.Length,
            Project.SampleTransients[Clip.SampleID],
            Project.SamplePeriods[Clip.SampleID], Clip.DragZones,
            Clip.AUFFTSize) * Clip.Gain;
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
  NewClip.AUFFTSize := SampleTypes.AUFFTSizeDefault;

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

    { carry the matching half of the warp markers/drag zones across the cut
      instead of discarding them - otherwise splitting a warped clip would
      silently revert both halves to unwarped 1:1 playback. The returned
      split frame may differ slightly from the requested one (see
      SplitWarpMarkers) - use it for the clip geometry too so the halves'
      lengths stay consistent with their markers/zones. }
    if Selected.WarpMode = SampleTypes.WarpModeDrag then
      SplitRel := SplitDragZones(Selected.DragZones,
        SplitFrame - Selected.Position, LeftPart.DragZones,
        RightPart.DragZones, @SplitSource)
    else
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
