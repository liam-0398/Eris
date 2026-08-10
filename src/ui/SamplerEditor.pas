unit SamplerEditor;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, SampleTypes, Project,
  Waveform, InstrumentEditor;

const
  { same lower-row QWERTY layout as MainForm's KeyToSemitoneOffset, boxes
    0..11 left to right }
  SamplerKeyLabels: array[0..Project.SamplerKeysPerOctave - 1] of Char =
    ('Z', 'S', 'X', 'D', 'C', 'V', 'G', 'B', 'H', 'N', 'J', 'M');

type
  TSamplerKeySelectEvent = procedure(Sender: TObject; AKeyIndex: Integer) of object;

  { The 12-box key strip shown in the device panel for a Sampler Track's
    keyboard track - one box per key of KeyToSemitoneOffset's lower row.
    Left-clicking a box selects it (see SetKey/TSamplerKeyEditor below); a
    clip dropped from the timeline onto a box (see
    MainForm.ArrangementViewClipActivate) calls SelectKey directly, without
    going through MouseDown. Right-clicking a filled box clones its sample+
    trim into the next empty box and selects that - the fast way to spread
    one long sample (e.g. a breakbeat) across several keys, then drag each
    key's own start/end markers in TSamplerKeyEditor to pick a different
    slice per key. }
  TSamplerKeysWidget = class(TCustomControl)
  private
    FTrackIndex: Integer;
    FSelectedKey: Integer;
    FOnKeySelected: TSamplerKeySelectEvent;
    function BoxRect(AKeyIndex: Integer): TRect;
    function NextEmptyKey(AFromKey: Integer): Integer;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetTrack(ATrackIndex: Integer);
    procedure SelectKey(AKeyIndex: Integer);
    function XToKeyIndex(AX: Integer): Integer;
    property SelectedKey: Integer read FSelectedKey;
    property OnKeySelected: TSamplerKeySelectEvent read FOnKeySelected write FOnKeySelected;
  end;

  { Waveform + start/end marker editor for whichever key is currently
    selected on a TSamplerKeysWidget - same drag-marker behavior as
    TInstrumentEditor, just addressing Project.TrackSamplerSlots[Track][Key]
    instead of the single TrackInstrumentStart/End pair, and sharing the
    same InstrumentZoomPixelsPerSecond zoom level. }
  TSamplerKeyEditor = class(TCustomControl)
  private
    const
      MarkerGrabPixels = 6;
      { same fixed ruler-strip height as WarpEditor.WarpRulerHeight /
        TInstrumentEditor.RulerHeight }
      RulerHeight = 18;
    var
      FTrackIndex: Integer;
      FKeyIndex: Integer;
      FDragWhich: Integer; { -1 none, 0 start marker, 1 end marker }
      FOnChanged: TNotifyEvent;
    function GetSampleID: Integer;
    function FrameToX(AFrame: Int64; ASampleRate: Integer): Integer;
    function XToFrame(AX: Integer; ASampleRate: Integer): Int64;
    function HitTestMarker(X: Integer; ASampleRate: Integer): Integer;
    { same tempo-grid math as WarpEditor.BeatFrames/BarBeatLabel and
      TInstrumentEditor's copy - a sampler key has no warp markers/Position
      either, so this grid always starts counting from frame 0 (bar 1 beat 0)
      at the very start of the key's assigned sample. }
    function BeatFrames(ASampleRate: Integer): Int64;
    function BarBeatLabel(AFrame: Int64; ASampleRate: Integer): string;
    procedure DrawClipWaveform(ASampleID: Integer);
    procedure DrawGrid(ASampleRate: Integer);
    procedure DrawRulerStrip(ASampleRate: Integer);
    procedure DrawMarkers(ASampleRate: Integer);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetKey(ATrackIndex, AKeyIndex: Integer);
    property OnChanged: TNotifyEvent read FOnChanged write FOnChanged;
  end;

implementation

{ TSamplerKeysWidget }

constructor TSamplerKeysWidget.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  ControlStyle := ControlStyle + [csOpaque];
  FTrackIndex := -1;
  FSelectedKey := -1;
end;

function TSamplerKeysWidget.BoxRect(AKeyIndex: Integer): TRect;
var
  BoxW: Integer;
begin
  BoxW := Width div Project.SamplerKeysPerOctave;
  Result := Rect(AKeyIndex * BoxW + 2, 2, (AKeyIndex + 1) * BoxW - 2, Height - 2);
end;

function TSamplerKeysWidget.XToKeyIndex(AX: Integer): Integer;
var
  BoxW, k: Integer;
begin
  Result := -1;
  BoxW := Width div Project.SamplerKeysPerOctave;
  if BoxW <= 0 then
    Exit;
  k := AX div BoxW;
  if (k >= 0) and (k < Project.SamplerKeysPerOctave) then
    Result := k;
end;

procedure TSamplerKeysWidget.SetTrack(ATrackIndex: Integer);
begin
  if FTrackIndex <> ATrackIndex then
    FSelectedKey := -1;
  FTrackIndex := ATrackIndex;
  Invalidate;
end;

procedure TSamplerKeysWidget.SelectKey(AKeyIndex: Integer);
begin
  FSelectedKey := AKeyIndex;
  Invalidate;
end;

procedure TSamplerKeysWidget.Paint;
var
  k: Integer;
  R: TRect;
  Slot: Project.TSamplerSlot;
begin
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(Rect(0, 0, Width, Height));
  if (FTrackIndex < 0) or (FTrackIndex >= Project.MaxTracks) then
    Exit;

  for k := 0 to Project.SamplerKeysPerOctave - 1 do
  begin
    R := BoxRect(k);
    Slot := Project.TrackSamplerSlots[FTrackIndex][k];
    if Slot.SampleID >= 0 then
      Canvas.Brush.Color := clMoneyGreen
    else
      Canvas.Brush.Color := clWindow;
    if k = FSelectedKey then
    begin
      Canvas.Pen.Color := clHighlight;
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
    Canvas.TextOut(R.Left + 4, R.Top + 2, SamplerKeyLabels[k]);
    Canvas.Brush.Style := bsSolid;
  end;
end;

{ First empty (SampleID < 0) box found scanning forward from AFromKey,
  wrapping around; -1 if every box is filled. Never returns AFromKey itself -
  callers only reach here after confirming AFromKey is filled. }
function TSamplerKeysWidget.NextEmptyKey(AFromKey: Integer): Integer;
var
  i, Idx: Integer;
begin
  Result := -1;
  for i := 1 to Project.SamplerKeysPerOctave do
  begin
    Idx := (AFromKey + i) mod Project.SamplerKeysPerOctave;
    if Project.TrackSamplerSlots[FTrackIndex][Idx].SampleID < 0 then
      Exit(Idx);
  end;
end;

procedure TSamplerKeysWidget.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  k, Target: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (FTrackIndex < 0) or (FTrackIndex >= Project.MaxTracks) then
    Exit;
  k := XToKeyIndex(X);
  if k < 0 then
    Exit;

  if Button = mbLeft then
  begin
    FSelectedKey := k;
    Invalidate;
    if Assigned(FOnKeySelected) then
      FOnKeySelected(Self, k);
  end
  else if Button = mbRight then
  begin
    if Project.TrackSamplerSlots[FTrackIndex][k].SampleID < 0 then
      Exit; { nothing to duplicate }
    Target := NextEmptyKey(k);
    if Target < 0 then
      Exit; { bank is full }
    Project.TrackSamplerSlots[FTrackIndex][Target] :=
      Project.TrackSamplerSlots[FTrackIndex][k];
    FSelectedKey := Target;
    Invalidate;
    if Assigned(FOnKeySelected) then
      FOnKeySelected(Self, Target);
  end;
end;

{ TSamplerKeyEditor }

constructor TSamplerKeyEditor.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := True;
  ControlStyle := ControlStyle + [csOpaque];
  FTrackIndex := -1;
  FKeyIndex := -1;
  FDragWhich := -1;
end;

function TSamplerKeyEditor.GetSampleID: Integer;
begin
  if (FTrackIndex < 0) or (FTrackIndex >= Project.MaxTracks) or
    (FKeyIndex < 0) or (FKeyIndex >= Project.SamplerKeysPerOctave) then
    Exit(-1);
  Result := Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].SampleID;
  if (Result < 0) or (Result > High(Project.SamplePool)) then
    Result := -1;
end;

function TSamplerKeyEditor.FrameToX(AFrame: Int64; ASampleRate: Integer): Integer;
begin
  if ASampleRate <= 0 then
    Exit(0);
  Result := Round((AFrame * InstrumentEditor.InstrumentZoomPixelsPerSecond) / ASampleRate);
end;

function TSamplerKeyEditor.XToFrame(AX: Integer; ASampleRate: Integer): Int64;
begin
  Result := Round((Int64(AX) * ASampleRate) / InstrumentEditor.InstrumentZoomPixelsPerSecond);
end;

function TSamplerKeyEditor.HitTestMarker(X: Integer; ASampleRate: Integer): Integer;
var
  sx, ex: Integer;
begin
  Result := -1;
  ex := FrameToX(Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].EndFrame, ASampleRate);
  if Abs(X - ex) <= MarkerGrabPixels then
    Exit(1);
  sx := FrameToX(Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].StartFrame, ASampleRate);
  if Abs(X - sx) <= MarkerGrabPixels then
    Exit(0);
end;

function TSamplerKeyEditor.BeatFrames(ASampleRate: Integer): Int64;
begin
  if Project.TempoBPM <= 0 then
    Exit(0);
  Result := Round((ASampleRate * 60) / Project.TempoBPM);
end;

function TSamplerKeyEditor.BarBeatLabel(AFrame: Int64; ASampleRate: Integer): string;
var
  BF, TotalBeats, BarNum, BeatInBar: Int64;
begin
  BF := BeatFrames(ASampleRate);
  if BF <= 0 then
    Exit('1.0');
  TotalBeats := AFrame div BF;
  BarNum := TotalBeats div 4;
  BeatInBar := TotalBeats mod 4;
  Result := IntToStr(BarNum + 1) + '.' + IntToStr(BeatInBar);
end;

procedure TSamplerKeyEditor.DrawClipWaveform(ASampleID: Integer);
var
  Sample: TSample;
begin
  Sample := Project.SamplePool[ASampleID];
  DrawWaveform(Canvas, Rect(0, RulerHeight, Width, Height), Project.SamplePeaks[ASampleID],
    Sample.FrameCount, 0, Sample.FrameCount, nil, clAqua);
end;

procedure TSamplerKeyEditor.DrawGrid(ASampleRate: Integer);
var
  Eighth, Beat, BarLen, Frame: Int64;
  x: Integer;
begin
  Eighth := BeatFrames(ASampleRate) div 2;
  if Eighth <= 0 then
    Exit;
  Beat := Eighth * 2;
  BarLen := Beat * 4;

  Frame := 0;
  x := FrameToX(Frame, ASampleRate);
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
    Canvas.Line(x, RulerHeight, x, Height);
    Frame := Frame + Eighth;
    x := FrameToX(Frame, ASampleRate);
  end;
  Canvas.Pen.Width := 1;
end;

procedure TSamplerKeyEditor.DrawRulerStrip(ASampleRate: Integer);
var
  Beat, BarLen, Frame: Int64;
  x: Integer;
begin
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(Rect(0, 0, Width, RulerHeight));
  Canvas.Pen.Color := clBtnShadow;
  Canvas.Line(0, RulerHeight - 1, Width, RulerHeight - 1);

  Beat := BeatFrames(ASampleRate);
  if Beat <= 0 then
    Exit;
  BarLen := Beat * 4;

  Frame := 0;
  x := FrameToX(Frame, ASampleRate);
  while x < Width do
  begin
    if Frame mod BarLen = 0 then
      Canvas.Pen.Color := clBlack
    else
      Canvas.Pen.Color := clBtnShadow;
    Canvas.Line(x, RulerHeight - 6, x, RulerHeight);
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(x + 2, 2, BarBeatLabel(Frame, ASampleRate));
    Canvas.Brush.Style := bsSolid;
    Frame := Frame + Beat;
    x := FrameToX(Frame, ASampleRate);
  end;
end;

procedure TSamplerKeyEditor.DrawMarkers(ASampleRate: Integer);
var
  sx, ex: Integer;
begin
  sx := FrameToX(Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].StartFrame, ASampleRate);
  Canvas.Pen.Color := clLime;
  Canvas.Pen.Width := 2;
  Canvas.Line(sx, 0, sx, Height);
  Canvas.Pen.Width := 1;
  Canvas.Brush.Color := clLime;
  Canvas.Polygon([Point(sx - 5, RulerHeight), Point(sx + 5, RulerHeight), Point(sx, RulerHeight + 8)]);

  ex := FrameToX(Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].EndFrame, ASampleRate);
  Canvas.Pen.Color := clRed;
  Canvas.Pen.Width := 2;
  Canvas.Line(ex, 0, ex, Height);
  Canvas.Pen.Width := 1;
  Canvas.Brush.Color := clRed;
  Canvas.Polygon([Point(ex - 5, RulerHeight), Point(ex + 5, RulerHeight), Point(ex, RulerHeight + 8)]);
end;

procedure TSamplerKeyEditor.Paint;
var
  SampleID: Integer;
begin
  Canvas.Brush.Color := clWindow;
  Canvas.FillRect(Rect(0, 0, Width, Height));

  SampleID := GetSampleID;
  if SampleID < 0 then
    Exit;

  DrawClipWaveform(SampleID);
  DrawGrid(Project.SamplePool[SampleID].SampleRate);
  DrawRulerStrip(Project.SamplePool[SampleID].SampleRate);
  DrawMarkers(Project.SamplePool[SampleID].SampleRate);
end;

procedure TSamplerKeyEditor.MouseDown(Button: TMouseButton; Shift: TShiftState;
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

procedure TSamplerKeyEditor.MouseMove(Shift: TShiftState; X, Y: Integer);
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
    if NewFrame >= Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].EndFrame then
      NewFrame := Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].EndFrame - 1;
    if NewFrame < 0 then
      NewFrame := 0;
    Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].StartFrame := NewFrame;
  end
  else
  begin
    if NewFrame <= Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].StartFrame then
      NewFrame := Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].StartFrame + 1;
    if NewFrame > FrameCount then
      NewFrame := FrameCount;
    Project.TrackSamplerSlots[FTrackIndex][FKeyIndex].EndFrame := NewFrame;
  end;

  if Assigned(FOnChanged) then
    FOnChanged(Self);
  Invalidate;
end;

procedure TSamplerKeyEditor.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragWhich := -1;
end;

procedure TSamplerKeyEditor.SetKey(ATrackIndex, AKeyIndex: Integer);
begin
  FTrackIndex := ATrackIndex;
  FKeyIndex := AKeyIndex;
  FDragWhich := -1;
  Invalidate;
end;

end.
