unit WarpEditor;

{$mode objfpc}{$H+}

interface

uses
  { Theme last - it shadows Graphics' system colours; see Theme.pas }
  Classes, SysUtils, Controls, Graphics, LCLType, SampleTypes, Project,
  AudioEngine, Waveform, WaveformDraw, Theme;

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
      { see WarpEditor.md / warp.md "D (drag) mode": the gap ResolveZoneOverlaps
        leaves between a trimmed zone's new edge and whichever zone won the
        overlap, so the loser's tail/head fades cleanly into silence (see
        AudioEngine.DragClipSample's own fade) instead of butting a hard edge
        against the winner. }
      DragZoneOverlapGapMs = 15;
    var
      FTrackIndex: Integer;
      FClipIndex: Integer;
      FDragMarkerIndex: Integer;
      FDragZoneIndex: Integer;
      FZoneDragStartX: Integer;
      FZoneDragStartShift: Int64;
      { -1 = no zone placement in progress. First double-click in D mode sets
        this (the green start marker); the following double-click completes
        the zone against it (the red end marker) and clears it back to -1.
        See DblClick / HandleDragZoneDblClick. }
      FPendingZoneStartFrame: Int64;
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
    procedure DrawDragZones(const AClip: TClip);
    procedure DrawPlayhead(const AClip: TClip);
    function HitTestDragZone(const AClip: TClip; X: Integer): Integer;
    { trims/drops other zones that overlap AZones[AActiveIndex]'s rendered
      range - the actively-dragged zone always wins, see the header comment
      on the implementation. Returns the active zone's index in AZones after
      any earlier zones were dropped, since removal shifts indices down. }
    function ResolveDragZoneOverlaps(var AZones: TDragZoneArray; AActiveIndex: Integer): Integer;
    procedure DeleteDragZone(const AClip: TClip; AIndex: Integer);
    procedure CreateDragZoneFromRange(const AClip: TClip; AStart, AEnd: Int64);
    procedure HandleDragZoneDblClick(const AClip: TClip; AFrame: Int64);
    procedure DragZoneMouseDown(const AClip: TClip; X: Integer; Button: TMouseButton);
    procedure DragZoneMouseMove(const AClip: TClip; X: Integer; Shift: TShiftState);
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
  FDragZoneIndex := -1;
  FPendingZoneStartFrame := -1;
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

  { deliberately NOT the same self-healing trick for DragZones: unlike
    WarpMarkers (which can never usefully be empty), an empty DragZones is a
    real, meaningful, user-reachable state - right-click deleting the last
    zone. Seeding a default zone here on every fetch would resurrect it the
    instant it was deleted. The one-time "don't silence a clip just because
    it switched into D mode" default lives where the mode switch itself
    happens instead - see MainForm.SetSelectedClipWarpMode. }
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
    Project.SampleTransients[AClip.SampleID], AClip.DragZones);
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

{ Drag ("D") mode's own marker rendering - a green edge (the grabbed start of
  a zone) and a red edge (its end, also a resize... except a zone doesn't
  resize, it only slides, so the red edge here is decoration matching the
  other modes' visual language rather than a second grab handle) for every
  zone, at the zone's RENDERED (post-Shift) position. Called instead of
  DrawMarkers, never alongside it - see Paint. }
procedure TWarpEditor.DrawDragZones(const AClip: TClip);
var
  i, xStart, xEnd: Integer;
  RStart, REnd: Int64;
begin
  for i := 0 to High(AClip.DragZones) do
  begin
    RStart := AClip.DragZones[i].SourceStart + AClip.DragZones[i].Shift;
    REnd := AClip.DragZones[i].SourceEnd + AClip.DragZones[i].Shift;
    xStart := FrameToX(RStart);
    xEnd := FrameToX(REnd);

    Canvas.Pen.Color := clGreen;
    Canvas.Pen.Width := 2;
    Canvas.Line(xStart, WarpRulerHeight, xStart, Height);
    Canvas.Pen.Color := clRed;
    Canvas.Line(xEnd, WarpRulerHeight, xEnd, Height);
    Canvas.Pen.Width := 1;

    Canvas.Brush.Color := clGreen;
    Canvas.Polygon([Point(xStart - 5, WarpRulerHeight), Point(xStart + 5, WarpRulerHeight),
      Point(xStart, WarpRulerHeight + 8)]);
    Canvas.Brush.Color := clRed;
    Canvas.Polygon([Point(xEnd - 5, WarpRulerHeight), Point(xEnd + 5, WarpRulerHeight),
      Point(xEnd, WarpRulerHeight + 8)]);
  end;

  { the awaiting-its-end-marker start click, dashed so it reads as
    "not committed yet" rather than a real zone edge }
  if FPendingZoneStartFrame >= 0 then
  begin
    xStart := FrameToX(FPendingZoneStartFrame);
    Canvas.Pen.Color := clGreen;
    Canvas.Pen.Width := 2;
    Canvas.Pen.Style := psDash;
    Canvas.Line(xStart, WarpRulerHeight, xStart, Height);
    Canvas.Pen.Style := psSolid;
    Canvas.Pen.Width := 1;
    Canvas.Brush.Color := clGreen;
    Canvas.Polygon([Point(xStart - 5, WarpRulerHeight), Point(xStart + 5, WarpRulerHeight),
      Point(xStart, WarpRulerHeight + 8)]);
  end;
end;

function TWarpEditor.HitTestDragZone(const AClip: TClip; X: Integer): Integer;
var
  i: Integer;
  Frame, RStart, REnd: Int64;
begin
  Result := -1;
  Frame := XToFrame(X);
  for i := 0 to High(AClip.DragZones) do
  begin
    RStart := AClip.DragZones[i].SourceStart + AClip.DragZones[i].Shift;
    REnd := AClip.DragZones[i].SourceEnd + AClip.DragZones[i].Shift;
    if (Frame >= RStart) and (Frame < REnd) then
      Exit(i);
  end;
end;

{ The actively-dragged zone (AActiveIndex) always keeps its full rendered
  span - see warp.md "D (drag) mode": dragging one zone over another
  overwrites the overlap, and the OTHER (stationary) zone loses whichever
  edge touches the dragged one, trimmed back by a small gap so the loser's
  own tail/head fade (DragClipSample/DragZoneSourceSample) has silence to
  fade into instead of butting a hard edge against the winner. A stationary
  zone trimmed down to nothing is dropped outright. }
function TWarpEditor.ResolveDragZoneOverlaps(var AZones: TDragZoneArray;
  AActiveIndex: Integer): Integer;
var
  GapFrames, ARStart, AREnd, ORStart, OREnd, NewEnd, NewStart: Int64;
  i, KeptCount, RemovedBeforeActive: Integer;
  Kept: TDragZoneArray;
begin
  Result := AActiveIndex;
  if (AActiveIndex < 0) or (AActiveIndex > High(AZones)) then
    Exit;

  GapFrames := (DragZoneOverlapGapMs * AudioEngine.ProjectSampleRate) div 1000;
  ARStart := AZones[AActiveIndex].SourceStart + AZones[AActiveIndex].Shift;
  AREnd := AZones[AActiveIndex].SourceEnd + AZones[AActiveIndex].Shift;

  SetLength(Kept, Length(AZones));
  KeptCount := 0;
  RemovedBeforeActive := 0;
  for i := 0 to High(AZones) do
  begin
    if i = AActiveIndex then
    begin
      Kept[KeptCount] := AZones[i];
      Inc(KeptCount);
      Continue;
    end;

    ORStart := AZones[i].SourceStart + AZones[i].Shift;
    OREnd := AZones[i].SourceEnd + AZones[i].Shift;

    if (OREnd <= ARStart) or (ORStart >= AREnd) then
    begin
      Kept[KeptCount] := AZones[i];
      Inc(KeptCount);
      Continue;
    end;

    if ORStart < ARStart then
    begin
      { stationary zone sits to the left - shave its tail }
      NewEnd := ARStart - GapFrames;
      if NewEnd - AZones[i].Shift <= AZones[i].SourceStart then
      begin
        if i < AActiveIndex then
          Inc(RemovedBeforeActive);
        Continue;
      end;
      Kept[KeptCount] := AZones[i];
      Kept[KeptCount].SourceEnd := NewEnd - AZones[i].Shift;
      Inc(KeptCount);
    end
    else
    begin
      { stationary zone sits to the right (or is engulfed entirely, which
        this also drops - see the header comment) - shave its head }
      NewStart := AREnd + GapFrames;
      if NewStart - AZones[i].Shift >= AZones[i].SourceEnd then
      begin
        if i < AActiveIndex then
          Inc(RemovedBeforeActive);
        Continue;
      end;
      Kept[KeptCount] := AZones[i];
      Kept[KeptCount].SourceStart := NewStart - AZones[i].Shift;
      Inc(KeptCount);
    end;
  end;

  SetLength(Kept, KeptCount);
  AZones := Kept;
  Result := AActiveIndex - RemovedBeforeActive;
end;

procedure TWarpEditor.DeleteDragZone(const AClip: TClip; AIndex: Integer);
var
  NewZones: TDragZoneArray;
  Clip: TClip;
  InsertAt, i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(AClip.DragZones)) then
    Exit;

  SetLength(NewZones, Length(AClip.DragZones) - 1);
  InsertAt := 0;
  for i := 0 to High(AClip.DragZones) do
    if i <> AIndex then
    begin
      NewZones[InsertAt] := AClip.DragZones[i];
      Inc(InsertAt);
    end;

  Clip := AClip;
  Clip.DragZones := NewZones;
  SetClipData(Clip);
end;

{ Two-click zone placement - see warp.md "you set a start marker that is
  green and an end marker that is red". The first double-click in D mode
  only records FPendingZoneStartFrame (drawn as a lone green marker with no
  partner yet); this one completes it into an actual zone once the second
  click supplies the other end. A second click before the pending frame
  (i.e. clicking left of where you started) just swaps the order - the zone
  spans whichever two points were clicked, direction doesn't matter. }
procedure TWarpEditor.HandleDragZoneDblClick(const AClip: TClip; AFrame: Int64);
begin
  if (AFrame < 0) or (AFrame >= AClip.Length) then
    Exit;

  if FPendingZoneStartFrame < 0 then
  begin
    FPendingZoneStartFrame := AFrame;
    Invalidate;
    Exit;
  end;

  if FPendingZoneStartFrame < AFrame then
    CreateDragZoneFromRange(AClip, FPendingZoneStartFrame, AFrame)
  else
    CreateDragZoneFromRange(AClip, AFrame, FPendingZoneStartFrame);
  FPendingZoneStartFrame := -1;
end;

{ Carves [AStart, AEnd) out of every existing zone it overlaps (trimming
  whichever edge is touched, dropping a zone entirely if the new range
  covers it completely - same "who's covered gets shaved or dropped" idea
  as ResolveDragZoneOverlaps, just against a fixed range instead of a zone
  being actively dragged) and inserts it as a brand new zone with Shift=0.
  Needed because a fresh D-mode clip starts as one zone covering the whole
  waveform (MainForm.SetSelectedClipWarpMode's one-time seed), so without
  this carve the very first placed zone would have nothing to cut into. }
procedure TWarpEditor.CreateDragZoneFromRange(const AClip: TClip; AStart, AEnd: Int64);
var
  i: Integer;
  RStart, REnd: Int64;
  Clip: TClip;
  NewZones: TDragZoneArray;
begin
  if AStart < 0 then
    AStart := 0;
  if AEnd > AClip.Length then
    AEnd := AClip.Length;
  if AEnd <= AStart then
    Exit;

  SetLength(NewZones, 0);
  for i := 0 to High(AClip.DragZones) do
  begin
    RStart := AClip.DragZones[i].SourceStart + AClip.DragZones[i].Shift;
    REnd := AClip.DragZones[i].SourceEnd + AClip.DragZones[i].Shift;

    if (REnd <= AStart) or (RStart >= AEnd) then
    begin
      { no overlap - keep as-is }
      SetLength(NewZones, Length(NewZones) + 1);
      NewZones[High(NewZones)] := AClip.DragZones[i];
      Continue;
    end;

    if RStart < AStart then
    begin
      { survives on the left, trimmed back to where the new zone starts }
      SetLength(NewZones, Length(NewZones) + 1);
      NewZones[High(NewZones)] := AClip.DragZones[i];
      NewZones[High(NewZones)].SourceEnd := AStart - AClip.DragZones[i].Shift;
    end;
    if REnd > AEnd then
    begin
      { survives on the right, trimmed back to where the new zone ends }
      SetLength(NewZones, Length(NewZones) + 1);
      NewZones[High(NewZones)] := AClip.DragZones[i];
      NewZones[High(NewZones)].SourceStart := AEnd - AClip.DragZones[i].Shift;
    end;
    { fully covered by the new zone - dropped }
  end;

  if Length(NewZones) >= MaxClipDragZones then
    Exit;
  SetLength(NewZones, Length(NewZones) + 1);
  NewZones[High(NewZones)].SourceStart := AStart;
  NewZones[High(NewZones)].SourceEnd := AEnd;
  NewZones[High(NewZones)].Shift := 0;

  Clip := AClip;
  Clip.DragZones := NewZones;
  SetClipData(Clip);
end;

procedure TWarpEditor.DragZoneMouseDown(const AClip: TClip; X: Integer;
  Button: TMouseButton);
var
  HitIndex: Integer;
begin
  HitIndex := HitTestDragZone(AClip, X);

  if Button = mbRight then
  begin
    DeleteDragZone(AClip, HitIndex);
    Exit;
  end;
  if Button <> mbLeft then
    Exit;

  FDragZoneIndex := HitIndex;
  if FDragZoneIndex >= 0 then
  begin
    FZoneDragStartX := X;
    FZoneDragStartShift := AClip.DragZones[FDragZoneIndex].Shift;
  end;
end;

{ Slides the grabbed zone by the same pixel delta the mouse has moved since
  MouseDown (not since the last MouseMove - re-deriving from the fixed start
  avoids the drift plain incremental deltas accumulate from integer→frame
  rounding every event), snaps its rendered start to the beat grid unless
  Alt is held (matching the other modes' marker-drag convention), then runs
  overlap resolution against every other zone before committing. }
procedure TWarpEditor.DragZoneMouseMove(const AClip: TClip; X: Integer;
  Shift: TShiftState);
var
  DeltaFrames, NewShift, NewRStart: Int64;
  Clip: TClip;
  NewZones: TDragZoneArray;
begin
  if FDragZoneIndex < 0 then
    Exit;

  Clip := AClip;
  NewZones := Copy(Clip.DragZones, 0, Length(Clip.DragZones));

  DeltaFrames := XToFrame(X) - XToFrame(FZoneDragStartX);
  NewShift := FZoneDragStartShift + DeltaFrames;

  if not (ssAlt in Shift) then
  begin
    NewRStart := SnapToBeat(NewZones[FDragZoneIndex].SourceStart + NewShift);
    NewShift := NewRStart - NewZones[FDragZoneIndex].SourceStart;
  end;

  NewZones[FDragZoneIndex].Shift := NewShift;
  FDragZoneIndex := ResolveDragZoneOverlaps(NewZones, FDragZoneIndex);

  Clip.DragZones := NewZones;
  SetClipData(Clip);
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
  if Clip.WarpMode = WarpModeDrag then
    DrawDragZones(Clip)
  else
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
  FDragZoneIndex := -1;
  FPendingZoneStartFrame := -1;
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

  if Clip.WarpMode = WarpModeDrag then
  begin
    DragZoneMouseDown(Clip, X, Button);
    Exit;
  end;

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

  if GetClip(Clip) and (Clip.WarpMode = WarpModeDrag) then
  begin
    if FDragZoneIndex < 0 then
    begin
      if HitTestDragZone(Clip, X) >= 0 then
        Cursor := crSizeWE
      else
        Cursor := crDefault;
      Exit;
    end;
    DragZoneMouseMove(Clip, X, Shift);
    Exit;
  end;

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
  FDragZoneIndex := -1;
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

  if Clip.WarpMode = WarpModeDrag then
  begin
    HandleDragZoneDblClick(Clip, XToFrame(FLastMouseX));
    Exit;
  end;

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
