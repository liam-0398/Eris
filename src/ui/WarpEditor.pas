unit WarpEditor;

{$mode objfpc}{$H+}

interface

uses
  { Theme last - it shadows Graphics' system colours; see Theme.pas }
  Classes, SysUtils, Controls, Graphics, LCLType, SampleTypes, Project,
  AudioEngine, Waveform, Theme;

const
  WarpDefaultPixelsPerSecond = 150;
  WarpMinPixelsPerSecond = 20;
  WarpMaxPixelsPerSecond = 2000;
  WarpZoomFactor = 1.25;
  WarpRulerHeight = 18;
  WarpMinWidgetWidth = 120;
  WarpMaxWidgetWidth = 4000;

var
  WarpZoomPixelsPerSecond: Double = WarpDefaultPixelsPerSecond;

function WarpWidthForFrames(AFrames: Int64): Integer;
procedure WarpZoomIn;
procedure WarpZoomOut;

type
  TWarpEditor = class(TCustomControl)
  private
    const
      MarkerGrabPixels = 6;
      { the right edge gets a wider grab zone than a plain marker: it is the
        "drag five bars onto four" gesture the whole clip's tempo fit hangs
        on, so it should be easy to catch }
      EdgeGrabPixels = 10;
      MinMarkerGapFrames = 100;
    var
      FTrackIndex: Integer;
      FClipIndex: Integer;
      FDragMarkerIndex: Integer;
      FLastMouseX: Integer;
      FPlayheadFrame: Int64;
      FIsPlaying: Boolean;
      FOnClipChanged: TNotifyEvent;
    function GetClip(out AClip: TClip): Boolean;
    procedure SetClipData(const AClip: TClip);
    function FrameToX(AFrame: Int64): Integer;
    function XToFrame(AX: Integer): Int64;
    function BeatFrames: Int64;
    function EighthNoteFrames: Int64;
    function BarBeatLabel(AFrame: Int64): string;
    function HitTestMarker(const AClip: TClip; X: Integer): Integer;
    function RightEdgeX(const AClip: TClip): Integer;
    function SnapToBeat(AFrame: Int64): Int64;
    procedure DeleteMarker(const AClip: TClip; AIndex: Integer);
    procedure DrawRulerStrip(const AClip: TClip);
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

function WarpWidthForFrames(AFrames: Int64): Integer;
begin
  Result := Round(AFrames * WarpZoomPixelsPerSecond / AudioEngine.ProjectSampleRate);
  if Result < WarpMinWidgetWidth then
    Result := WarpMinWidgetWidth;
  if Result > WarpMaxWidgetWidth then
    Result := WarpMaxWidgetWidth;
end;

procedure WarpZoomIn;
begin
  WarpZoomPixelsPerSecond := WarpZoomPixelsPerSecond * WarpZoomFactor;
  if WarpZoomPixelsPerSecond > WarpMaxPixelsPerSecond then
    WarpZoomPixelsPerSecond := WarpMaxPixelsPerSecond;
end;

procedure WarpZoomOut;
begin
  WarpZoomPixelsPerSecond := WarpZoomPixelsPerSecond / WarpZoomFactor;
  if WarpZoomPixelsPerSecond < WarpMinPixelsPerSecond then
    WarpZoomPixelsPerSecond := WarpMinPixelsPerSecond;
end;

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
  if not Result then
    Exit;
  AClip := Project.Tracks[FTrackIndex].Clips[FClipIndex];

  { self-healing default: every fetch (not just the first SetClip after
    selection) guarantees at least a start and end marker, so nothing else
    touching WarpMarkers can leave the editor with none to show/drag }
  if Length(AClip.WarpMarkers) < 2 then
  begin
    SetLength(AClip.WarpMarkers, 2);
    AClip.WarpMarkers[0].SourceFrame := 0;
    AClip.WarpMarkers[0].TimelineFrame := 0;
    AClip.WarpMarkers[1].SourceFrame := AClip.Length;
    AClip.WarpMarkers[1].TimelineFrame := AClip.Length;
    Project.Tracks[FTrackIndex].Clips[FClipIndex] := AClip;
  end;
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
  Result := Round(AFrame * WarpZoomPixelsPerSecond / AudioEngine.ProjectSampleRate);
end;

function TWarpEditor.XToFrame(AX: Integer): Int64;
begin
  Result := Round(AX * AudioEngine.ProjectSampleRate / WarpZoomPixelsPerSecond);
end;

function TWarpEditor.BeatFrames: Int64;
begin
  Result := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM);
end;

function TWarpEditor.EighthNoteFrames: Int64;
begin
  Result := BeatFrames div 2;
end;

function TWarpEditor.BarBeatLabel(AFrame: Int64): string;
var
  BF, TotalBeats, BarNum, BeatInBar: Int64;
begin
  BF := BeatFrames;
  if BF <= 0 then
    Exit('1.0');
  TotalBeats := AFrame div BF;
  BarNum := TotalBeats div 4;
  BeatInBar := TotalBeats mod 4;
  Result := IntToStr(BarNum + 1) + '.' + IntToStr(BeatInBar);
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

{ x of the clip's right edge - the end marker, which is also the resize
  handle. Always goes through FrameToX so it agrees with the ruler, the grid,
  the markers and (since DrawClipWaveform was corrected) the waveform. }
function TWarpEditor.RightEdgeX(const AClip: TClip): Integer;
begin
  Result := FrameToX(AClip.WarpMarkers[High(AClip.WarpMarkers)].TimelineFrame);
end;

{ nearest beat on the grid this editor actually draws (clip-relative, counted
  from the clip's own frame 0, same as DrawGrid) }
function TWarpEditor.SnapToBeat(AFrame: Int64): Int64;
var
  BF, Rem: Int64;
begin
  Result := AFrame;
  BF := BeatFrames;
  if BF <= 0 then
    Exit;
  Rem := AFrame mod BF;
  if Rem * 2 >= BF then
    Result := AFrame - Rem + BF
  else
    Result := AFrame - Rem;
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

procedure TWarpEditor.DrawRulerStrip(const AClip: TClip);
var
  Beat, BarLen, Frame: Int64;
  x: Integer;
begin
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(Rect(0, 0, Width, WarpRulerHeight));
  Canvas.Pen.Color := clBtnShadow;
  Canvas.Line(0, WarpRulerHeight - 1, Width, WarpRulerHeight - 1);

  Beat := BeatFrames;
  if Beat <= 0 then
    Exit;
  BarLen := Beat * 4;

  Frame := 0;
  x := FrameToX(Frame);
  while x < Width do
  begin
    { the ruler strip is chrome, not canvas, so the bar tick takes the
      foreground colour of the text beside it rather than ThemeGridBar }
    if Frame mod BarLen = 0 then
      Canvas.Pen.Color := clWindowText
    else
      Canvas.Pen.Color := clBtnShadow;
    Canvas.Line(x, WarpRulerHeight - 6, x, WarpRulerHeight);
    Canvas.Brush.Style := bsClear;
    { correlate with the main arrangement ruler's numbering, not a
      clip-local count that would always start over at "1.1" }
    Canvas.TextOut(x + 2, 2, BarBeatLabel(Frame + AClip.Position));
    Canvas.Brush.Style := bsSolid;
    Frame := Frame + Beat;
    x := FrameToX(Frame);
  end;
end;

procedure TWarpEditor.DrawGrid;
var
  Eighth, Beat, BarLen, Frame: Int64;
  x: Integer;
begin
  Eighth := EighthNoteFrames;
  if Eighth <= 0 then
    Exit;
  Beat := Eighth * 2;
  BarLen := Beat * 4;

  Frame := 0;
  x := FrameToX(Frame);
  while x < Width do
  begin
    if Frame mod BarLen = 0 then
    begin
      Canvas.Pen.Color := ThemeGridBar;
      Canvas.Pen.Width := 2;
    end
    else if Frame mod Beat = 0 then
    begin
      Canvas.Pen.Color := ThemeGridBeat;
      Canvas.Pen.Width := 1;
    end
    else
    begin
      Canvas.Pen.Color := ThemeGridSub;
      Canvas.Pen.Width := 1;
    end;
    Canvas.Line(x, WarpRulerHeight, x, Height);
    Frame := Frame + Eighth;
    x := FrameToX(Frame);
  end;
  Canvas.Pen.Width := 1;
end;

procedure TWarpEditor.DrawClipWaveform(const AClip: TClip);
var
  Sample: TSample;
  RightX: Integer;
begin
  if AClip.SampleID > High(Project.SamplePeaks) then
    Exit;
  Sample := Project.SamplePool[AClip.SampleID];

  { The waveform has to use the SAME frame -> pixel mapping as the ruler, the
    grid and the markers, all of which go through FrameToX. This used to
    stretch the clip across the control's full Width instead, which is
    FWarpEditor.Left pixels narrower than FrameToX's own idea of where the
    clip ends - so every marker drifted progressively right of the waveform
    peak it was pinned to, and the end marker landed off the right edge
    entirely, which is why the edge could not be grabbed at all. }
  RightX := FrameToX(AClip.Length);
  if RightX <= 0 then
    Exit;
  DrawWaveform(Canvas, Rect(0, WarpRulerHeight, RightX, Height),
    Project.SamplePeaks[AClip.SampleID], Sample.FrameCount, AClip.Offset,
    AClip.Offset + AClip.Length, AClip.WarpMarkers, clAqua, AClip.WarpMode,
    Project.SampleTransients[AClip.SampleID]);
end;

procedure TWarpEditor.DrawMarkers(const AClip: TClip);
var
  i, x: Integer;
begin
  for i := 0 to High(AClip.WarpMarkers) do
  begin
    x := FrameToX(AClip.WarpMarkers[i].TimelineFrame);
    if i = 0 then
      Canvas.Pen.Color := clBlue
    else if i = High(AClip.WarpMarkers) then
      Canvas.Pen.Color := clRed
    else
      Canvas.Pen.Color := clLime;
    Canvas.Pen.Width := 2;
    Canvas.Line(x, 0, x, Height);
    Canvas.Pen.Width := 1;
    Canvas.Brush.Color := Canvas.Pen.Color;
    Canvas.Polygon([Point(x - 5, WarpRulerHeight), Point(x + 5, WarpRulerHeight),
      Point(x, WarpRulerHeight + 8)]);
  end;

  { grab bar inside the end marker, so the right edge reads as a resize handle
    rather than just another marker line }
  x := RightEdgeX(AClip);
  Canvas.Brush.Color := clRed;
  Canvas.FillRect(Rect(x - 3, WarpRulerHeight, x, Height));
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
  DrawRulerStrip(Clip);
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
  GetClip(Clip); { triggers GetClip's own default-marker repair }
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

  { the right edge wins over any interior marker sitting under the cursor:
    an interior marker can always be re-added with a double-click, whereas
    the edge is only reachable here }
  if Abs(X - RightEdgeX(Clip)) <= EdgeGrabPixels then
    HitIndex := High(Clip.WarpMarkers);

  FDragMarkerIndex := HitIndex;
  if FDragMarkerIndex = 0 then
    FDragMarkerIndex := -1; { start marker is fixed }
end;

procedure TWarpEditor.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Clip: TClip;
  NewFrame, MinFrame, MaxFrame, Delta: Int64;
  NewMarkers: TWarpMarkerArray;
  j: Integer;
begin
  inherited MouseMove(Shift, X, Y);

  if FDragMarkerIndex < 0 then
  begin
    { hover feedback for the resize handle }
    if GetClip(Clip) and (Abs(X - RightEdgeX(Clip)) <= EdgeGrabPixels) then
      Cursor := crSizeWE
    else
      Cursor := crDefault;
    Exit;
  end;
  if not GetClip(Clip) then
    Exit;

  NewFrame := XToFrame(X);
  if NewFrame < 0 then
    NewFrame := 0;

  NewMarkers := Copy(Clip.WarpMarkers, 0, Length(Clip.WarpMarkers));

  if FDragMarkerIndex = High(NewMarkers) then
  begin
    { The end marker, i.e. the waveform's right edge. Dragging it changes the
      clip's total timeline length while the source content it points at stays
      put, so the final segment stretches or compresses to fit - in Beats mode
      that redistributes the slices without touching pitch, in RePitch it is a
      vari-speed stretch.

      Snapped to the beat grid drawn underneath it, because landing exactly on
      a bar line is the entire point of the gesture (five bars onto four is
      worthless if it lands on 3.97). Hold Alt to place it freely. }
    if not (ssAlt in Shift) then
      NewFrame := SnapToBeat(NewFrame);
    MinFrame := NewMarkers[FDragMarkerIndex - 1].TimelineFrame + 1;
    if NewFrame < MinFrame then
      NewFrame := MinFrame;
    NewMarkers[FDragMarkerIndex].TimelineFrame := NewFrame;
    Clip.Length := NewFrame;
  end
  else if ssCtrl in Shift then
  begin
    { Ctrl+drag: reposition this marker and slide every later marker
      (including the end marker, so the clip's length follows along too) by
      the same delta, leaving their own source/timeline relationships - and
      therefore their pitch - completely untouched. Useful for fixing a
      recurring timing offset (e.g. every snare landing a beat late) in one
      drag instead of one marker at a time, since only the segment before
      the dragged marker actually stretches; everything after just slides. }
    MinFrame := NewMarkers[FDragMarkerIndex - 1].TimelineFrame + 1;
    if NewFrame < MinFrame then
      NewFrame := MinFrame;
    Delta := NewFrame - NewMarkers[FDragMarkerIndex].TimelineFrame;
    NewMarkers[FDragMarkerIndex].TimelineFrame := NewFrame;
    for j := FDragMarkerIndex + 1 to High(NewMarkers) do
      NewMarkers[j].TimelineFrame := NewMarkers[j].TimelineFrame + Delta;
    Clip.Length := NewMarkers[High(NewMarkers)].TimelineFrame;
  end
  else
  begin
    { plain drag (Ableton's default): local edit - both segments adjacent to
      this marker stretch/compress to meet it (their own neighboring markers
      stay fixed), so the waveform visibly redistributes on both sides of
      the dragged marker; nothing beyond those two segments is touched }
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

  { pin the new marker to the source frame the warp already maps this timeline
    frame to, which makes inserting it a genuine playback no-op until it's
    dragged: splitting a segment there leaves both halves with the segment's
    original ratio, so every slice keeps the timeline position and length it
    already had. (This used to have to pass sample data and transients so the
    pin matched the old engine's per-grain ping-pong read position; the nominal
    map needs neither - see Waveform.WarpedSourcePosition.) }
  SetLength(NewMarkers, Length(Clip.WarpMarkers) + 1);
  for i := 0 to InsertAt - 1 do
    NewMarkers[i] := Clip.WarpMarkers[i];
  NewMarkers[InsertAt].SourceFrame := Round(WarpedSourcePosition(Clip.WarpMarkers,
    ClickFrame, AudioEngine.ProjectSampleRate, Clip.WarpMode));
  NewMarkers[InsertAt].TimelineFrame := ClickFrame;
  for i := InsertAt to High(Clip.WarpMarkers) do
    NewMarkers[i + 1] := Clip.WarpMarkers[i];

  Clip.WarpMarkers := NewMarkers;
  SetClipData(Clip);
end;

end.
