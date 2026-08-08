unit ArrangementView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, FileBrowser, SampleTypes,
  Project, AudioEngine;

type
  TFileDropEvent = procedure(Sender: TObject; ATrackIndex: Integer;
    AFramePosition: Int64; const AFilePath: string) of object;

  TSeekEvent = procedure(Sender: TObject; AFrameOffset: Int64) of object;

  TDragMode = (dmNone, dmMove, dmResizeLeft, dmResizeRight);

  TArrangementView = class(TCustomControl)
  private
    const
      HeaderWidth = 160;
      RulerHeight = 24;
      TrackHeight = 80;
      PixelsPerSecond = 100;
      MinGridPixelWidth = 16;
      EdgeGrabPixels = 6;
    var
      FOnFileDrop: TFileDropEvent;
      FOnSeek: TSeekEvent;
      FOnPlayPauseToggle: TNotifyEvent;
      FTrackColors: array[0..Project.TrackCount - 1] of TColor;
      FCursorFrame: Int64;
      FSelectedTrack: Integer;
      FSelectedClip: Integer;
      FDragMode: TDragMode;
      FDragActive: Boolean;
      FDragTrack: Integer;
      FDragClip: Integer;
      FDragGrabOffsetFrames: Int64;
      FDragOrigClip: TClip;
      FDragCurrentClip: TClip;
    function LaneWidth: Integer;
    function TrackIndexAtY(Y: Integer): Integer;
    function FrameToX(AFrame: Int64): Integer;
    function XToFrame(AX: Integer): Int64;
    function BeatFrames: Int64;
    function CurrentGridFrames: Int64;
    function SnapFrame(AFrame: Int64): Int64;
    function ClipPixelRect(ATrackIndex: Integer; const AClip: TClip): TRect;
    function HitTestClip(ATrackIndex: Integer; X: Integer; out AClipIndex: Integer;
      out AMode: TDragMode): Boolean;
    procedure PushTrackToEngine(ATrackIndex: Integer);
    procedure DrawLanes;
    procedure DrawRuler;
    procedure DrawTrackHeaders;
    procedure DrawClips;
    procedure DrawCursor;
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
    property OnFileDrop: TFileDropEvent read FOnFileDrop write FOnFileDrop;
    property OnSeek: TSeekEvent read FOnSeek write FOnSeek;
    property OnPlayPauseToggle: TNotifyEvent read FOnPlayPauseToggle
      write FOnPlayPauseToggle;
  end;

implementation

constructor TArrangementView.Create(AOwner: TComponent);
var
  i: Integer;
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True;
  FSelectedTrack := -1;
  FSelectedClip := -1;

  Randomize;
  for i := 0 to Project.TrackCount - 1 do
    FTrackColors[i] := RGBToColor(100 + Random(120), 100 + Random(120),
      100 + Random(120));
end;

function TArrangementView.LaneWidth: Integer;
begin
  Result := Width - HeaderWidth;
end;

function TArrangementView.TrackIndexAtY(Y: Integer): Integer;
begin
  if Y < RulerHeight then
    Exit(-1);
  Result := (Y - RulerHeight) div TrackHeight;
  if Result >= Project.TrackCount then
    Result := -1;
end;

function TArrangementView.FrameToX(AFrame: Int64): Integer;
begin
  Result := (AFrame * PixelsPerSecond) div AudioEngine.ProjectSampleRate;
end;

function TArrangementView.XToFrame(AX: Integer): Int64;
begin
  Result := (Int64(AX) * AudioEngine.ProjectSampleRate) div PixelsPerSecond;
end;

function TArrangementView.BeatFrames: Int64;
begin
  Result := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM);
end;

function TArrangementView.CurrentGridFrames: Int64;
const
  Divisions: array[0..5] of Integer = (1, 2, 4, 8, 16, 32);
var
  BarF: Int64;
  i: Integer;
  DivFrames: Int64;
begin
  BarF := BeatFrames * 4;
  Result := BarF;
  for i := 0 to High(Divisions) do
  begin
    DivFrames := BarF div Divisions[i];
    if FrameToX(DivFrames) >= MinGridPixelWidth then
      Result := DivFrames
    else
      Break;
  end;
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

procedure TArrangementView.PushTrackToEngine(ATrackIndex: Integer);
var
  Items: PPlaybackClip;
  i: Integer;
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
    Items[i].Gain := Clip.Gain;
  end;

  AudioEngineSetTrackClips(ATrackIndex, Items, Count);
end;

procedure TArrangementView.DrawLanes;
var
  i, x: Integer;
  y: Integer;
  Grid, Frame: Int64;
begin
  Canvas.Brush.Color := clWindow;
  Canvas.FillRect(Rect(0, RulerHeight, LaneWidth, Height));

  Canvas.Pen.Color := clSilver;
  for i := 0 to Project.TrackCount do
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
      Canvas.Line(x, RulerHeight, x, Height);
      Frame := Frame + Grid;
      x := FrameToX(Frame);
    end;
  end;

  Canvas.Pen.Color := clBtnShadow;
  Canvas.Line(LaneWidth, 0, LaneWidth, Height);
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

procedure TArrangementView.DrawTrackHeaders;
var
  i, y: Integer;
begin
  for i := 0 to Project.TrackCount - 1 do
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

      Canvas.Brush.Color := FTrackColors[t];
      Canvas.FillRect(R);
      if IsSelected then
      begin
        Canvas.Pen.Color := clRed;
        Canvas.Pen.Width := 2;
      end
      else
      begin
        Canvas.Pen.Color := clBtnShadow;
        Canvas.Pen.Width := 1;
      end;
      Canvas.Rectangle(R);
      Canvas.Pen.Width := 1;

      Canvas.Brush.Style := bsClear;
      if Clip.SampleID <= High(Project.SampleNames) then
        ClipName := Project.SampleNames[Clip.SampleID]
      else
        ClipName := '';
      Canvas.TextOut(R.Left + 4, R.Top + 4, ClipName);
      Canvas.Brush.Style := bsSolid;
    end;
end;

procedure TArrangementView.DrawCursor;
var
  x: Integer;
begin
  x := FrameToX(FCursorFrame);
  Canvas.Pen.Color := clRed;
  Canvas.Line(x, 0, x, Height);
end;

procedure TArrangementView.Paint;
begin
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(Rect(LaneWidth, 0, Width, RulerHeight));
  DrawLanes;
  DrawClips;
  DrawCursor;
  DrawRuler;
  DrawTrackHeaders;
end;

procedure TArrangementView.Resize;
begin
  inherited Resize;
  Invalidate;
end;

procedure TArrangementView.RefreshTrack(ATrackIndex: Integer);
begin
  PushTrackToEngine(ATrackIndex);
  Invalidate;
end;

procedure TArrangementView.SetCursorFrame(AFrameOffset: Int64);
begin
  if AFrameOffset = FCursorFrame then
    Exit;
  FCursorFrame := AFrameOffset;
  Invalidate;
end;

procedure TArrangementView.ClearSelection;
begin
  FSelectedTrack := -1;
  FSelectedClip := -1;
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

  if Button <> mbLeft then
    Exit;

  TrackIndex := TrackIndexAtY(Y);

  if TrackIndex < 0 then
  begin
    FSelectedTrack := -1;
    FSelectedClip := -1;
    Frame := SnapFrame(XToFrame(X));
    if Frame < 0 then
      Frame := 0;
    FCursorFrame := Frame;
    Invalidate;
    if Assigned(FOnSeek) then
      FOnSeek(Self, Frame);
    Exit;
  end;

  if HitTestClip(TrackIndex, X, ClipIndex, Mode) then
  begin
    FSelectedTrack := TrackIndex;
    FSelectedClip := ClipIndex;
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
    FSelectedTrack := -1;
    FSelectedClip := -1;
    Frame := SnapFrame(XToFrame(X));
    if Frame < 0 then
      Frame := 0;
    FCursorFrame := Frame;
    Invalidate;
    if Assigned(FOnSeek) then
      FOnSeek(Self, Frame);
  end;
end;

procedure TArrangementView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  MouseFrame, NewPosition, NewEnd, MinPos, MaxPos, MinEnd, Delta: Int64;
  FreePlacement: Boolean;
  TargetTrack: Integer;
begin
  inherited MouseMove(Shift, X, Y);

  if not FDragActive then
    Exit;

  FreePlacement := ssShift in Shift;
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
  else
    Exit;
  end;

  Invalidate;
end;

procedure TArrangementView.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  OrigTrack: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);

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
        FSelectedTrack := FDragTrack;
        FSelectedClip := High(Project.Tracks[FDragTrack].Clips);
        if OrigTrack <> FDragTrack then
          PushTrackToEngine(OrigTrack);
        PushTrackToEngine(FDragTrack);
      end;
    dmResizeLeft, dmResizeRight:
      begin
        Project.Tracks[FDragTrack].Clips[FDragClip] := FDragCurrentClip;
        PushTrackToEngine(FDragTrack);
      end;
  end;

  FDragActive := False;
  FDragMode := dmNone;
  Invalidate;
end;

procedure TArrangementView.KeyDown(var Key: Word; Shift: TShiftState);
var
  Track: Integer;
  Selected, NewClip, LeftPart, RightPart: TClip;
  SplitFrame: Int64;
  Clips, NewClips: TClipArray;
  j, k: Integer;
begin
  inherited KeyDown(Key, Shift);

  if Key = VK_SPACE then
  begin
    if Assigned(FOnPlayPauseToggle) then
      FOnPlayPauseToggle(Self);
    Key := 0;
    Exit;
  end;

  if Key = VK_DELETE then
  begin
    if (FSelectedTrack >= 0) and (FSelectedClip >= 0) and
      (FSelectedClip <= High(Project.Tracks[FSelectedTrack].Clips)) then
    begin
      Project.PushUndoSnapshot(FSelectedTrack);
      Project.RemoveClipAt(FSelectedTrack, FSelectedClip);
      PushTrackToEngine(FSelectedTrack);
      FSelectedClip := -1;
      Invalidate;
    end;
    Key := 0;
    Exit;
  end;

  if not (ssCtrl in Shift) then
    Exit;
  if FSelectedTrack < 0 then
    Exit;

  Track := FSelectedTrack;
  if (FSelectedClip < 0) or (FSelectedClip > High(Project.Tracks[Track].Clips)) then
    Exit;

  if (Key = Ord('D')) then
  begin
    Selected := Project.Tracks[Track].Clips[FSelectedClip];
    NewClip := Selected;
    NewClip.Position := Selected.Position + Selected.Length;

    Project.PushUndoSnapshot(Track);
    Project.CommitClipToTrack(Track, NewClip);
    PushTrackToEngine(Track);

    FSelectedClip := High(Project.Tracks[Track].Clips);
    Invalidate;
    Key := 0;
  end
  else if (Key = Ord('E')) then
  begin
    Selected := Project.Tracks[Track].Clips[FSelectedClip];
    SplitFrame := FCursorFrame;

    if (SplitFrame > Selected.Position) and
      (SplitFrame < Selected.Position + Selected.Length) then
    begin
      LeftPart := Selected;
      LeftPart.Length := SplitFrame - Selected.Position;

      RightPart := Selected;
      RightPart.Offset := Selected.Offset + (SplitFrame - Selected.Position);
      RightPart.Position := SplitFrame;
      RightPart.Length := (Selected.Position + Selected.Length) - SplitFrame;

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

      FSelectedClip := -1;
      Invalidate;
    end;
    Key := 0;
  end;
end;

end.
