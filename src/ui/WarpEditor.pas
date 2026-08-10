unit WarpEditor;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, SampleTypes, Project,
  AudioEngine, Waveform;

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
    if Frame mod BarLen = 0 then
      Canvas.Pen.Color := clBlack
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
      Canvas.Pen.Color := clBlack;
      Canvas.Pen.Width := 2;
    end
    else if Frame mod Beat = 0 then
    begin
      Canvas.Pen.Color := clGray;
      Canvas.Pen.Width := 1;
    end
    else
    begin
      Canvas.Pen.Color := clSilver;
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
begin
  if AClip.SampleID > High(Project.SamplePeaks) then
    Exit;
  Sample := Project.SamplePool[AClip.SampleID];
  DrawWaveform(Canvas, Rect(0, WarpRulerHeight, Width, Height),
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
  SampleData: PSingle;
  SampleFrameCount, SampleChannels: Integer;
  Transients: TFrameArray;
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

  { pin the new marker to where playback ACTUALLY reads at that timeline
    frame: pass the sample data (zero-crossing snapping) and transients
    (transient-bounded Beats grains), or the computed SourceFrame comes from
    the no-data/fixed-grid code path and inserting a marker - supposedly a
    playback no-op until dragged - would audibly shift Beats-mode audio }
  SampleData := nil;
  SampleFrameCount := 0;
  SampleChannels := 0;
  Transients := nil;
  if (Clip.SampleID >= 0) and (Clip.SampleID <= High(Project.SamplePool)) then
  begin
    SampleData := Project.SamplePool[Clip.SampleID].Data;
    SampleFrameCount := Project.SamplePool[Clip.SampleID].FrameCount;
    SampleChannels := Project.SamplePool[Clip.SampleID].Channels;
    Transients := Project.SampleTransients[Clip.SampleID];
  end;

  SetLength(NewMarkers, Length(Clip.WarpMarkers) + 1);
  for i := 0 to InsertAt - 1 do
    NewMarkers[i] := Clip.WarpMarkers[i];
  NewMarkers[InsertAt].SourceFrame := Round(WarpedSourcePosition(Clip.WarpMarkers,
    ClickFrame, SampleData, SampleFrameCount, SampleChannels,
    AudioEngine.ProjectSampleRate, Clip.WarpMode, Transients, nil, Clip.Offset));
  NewMarkers[InsertAt].TimelineFrame := ClickFrame;
  for i := InsertAt to High(Clip.WarpMarkers) do
    NewMarkers[i + 1] := Clip.WarpMarkers[i];

  Clip.WarpMarkers := NewMarkers;
  SetClipData(Clip);
end;

end.
