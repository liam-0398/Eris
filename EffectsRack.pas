unit EffectsRack;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ComCtrls, ExtCtrls, Graphics, Effects,
  Project, UIScale;

type
  PEffect = ^Effects.TEffect;

  TEffectRackChangedEvent = procedure(Sender: TObject) of object;

  { one effect's widget box - a plain TPanel populated with whichever native
    controls its Kind needs, wired directly to Project.TrackEffects, or to
    Project.MasterEffects when AIsMaster is set }
  TEffectWidget = class(TPanel)
  private
    FTrackIndex: Integer;
    FEffectIndex: Integer;
    FIsMaster: Boolean;
    FOnRackChanged: TEffectRackChangedEvent;
    FLPSlider: TTrackBar;
    FLPValueLabel: TLabel;
    FEQFreqEdit: array[0..Effects.MaxEQBands - 1] of TEdit;
    FEQGainSlider: array[0..Effects.MaxEQBands - 1] of TTrackBar;
    FLimiterThresholdSlider: TTrackBar;
    FLimiterThresholdValueLabel: TLabel;
    FLimiterReleaseSlider: TTrackBar;
    FLimiterReleaseValueLabel: TLabel;
    function EffectPtr: PEffect;
    procedure DeleteClick(Sender: TObject);
    procedure LPSliderChange(Sender: TObject);
    procedure EQFreqEditDone(Sender: TObject);
    procedure EQGainSliderChange(Sender: TObject);
    procedure LimiterThresholdSliderChange(Sender: TObject);
    procedure LimiterReleaseSliderChange(Sender: TObject);
    procedure BuildLowpass;
    procedure BuildEQ4;
    procedure BuildLimiter;
  public
    constructor CreateFor(AOwner: TComponent; AParent: TWinControl;
      ATrackIndex, AEffectIndex: Integer; AOnRackChanged: TEffectRackChangedEvent;
      AIsMaster: Boolean = False);
  end;

const
  LPMinHz = 20.0;
  LPMaxHz = 20000.0;
  EQMinGainDb = -12;
  EQMaxGainDb = 12;
  LimiterMinThresholdDb = -24;
  LimiterMaxThresholdDb = 0;
  LimiterMinReleaseMs = 10;
  LimiterMaxReleaseMs = 500;
  { shared sizing so every effect box lines up with the others in the rack
    and with the rest of the bottom bar's widgets }
  WidgetHeight = 180;
  EQBandWidth = 56;
  EQBandGap = 6;
  EQLeftMargin = 8;

implementation

function FreqToLogSlider(AFreqHz: Single): Integer;
begin
  Result := Round(100 * (Ln(AFreqHz / LPMinHz) / Ln(LPMaxHz / LPMinHz)));
  if Result < 0 then Result := 0;
  if Result > 100 then Result := 100;
end;

function LogSliderToFreq(APos: Integer): Single;
begin
  Result := LPMinHz * Exp((APos / 100) * Ln(LPMaxHz / LPMinHz));
end;

function TEffectWidget.EffectPtr: PEffect;
begin
  if FIsMaster then
    Result := @Project.MasterEffects[FEffectIndex]
  else
    Result := @Project.TrackEffects[FTrackIndex][FEffectIndex];
end;

constructor TEffectWidget.CreateFor(AOwner: TComponent; AParent: TWinControl;
  ATrackIndex, AEffectIndex: Integer; AOnRackChanged: TEffectRackChangedEvent;
  AIsMaster: Boolean = False);
var
  DeleteButton: TButton;
  TitleLabel: TLabel;
  Kind: Integer;
begin
  inherited Create(AOwner);
  FTrackIndex := ATrackIndex;
  FEffectIndex := AEffectIndex;
  FIsMaster := AIsMaster;
  FOnRackChanged := AOnRackChanged;
  Parent := AParent;
  BevelOuter := bvRaised;
  Height := Px(WidgetHeight);

  Kind := EffectPtr^.Kind;

  TitleLabel := TLabel.Create(AOwner);
  TitleLabel.Parent := Self;
  TitleLabel.Left := Px(8);
  TitleLabel.Top := Px(8);
  TitleLabel.Font.Style := [fsBold];
  case Kind of
    Effects.ekEQ4: TitleLabel.Caption := 'EQ 4';
    Effects.ekLimiter: TitleLabel.Caption := 'Limiter';
  else
    TitleLabel.Caption := 'LP';
  end;

  DeleteButton := TButton.Create(AOwner);
  DeleteButton.Parent := Self;
  DeleteButton.Caption := 'X';
  DeleteButton.Width := Px(22);
  DeleteButton.Height := Px(22);
  DeleteButton.Top := Px(6);
  DeleteButton.OnClick := @DeleteClick;

  case Kind of
    Effects.ekLowpass:
      begin
        Width := Px(200);
        DeleteButton.Left := Width - Px(28);
        BuildLowpass;
      end;
    Effects.ekEQ4:
      begin
        Width := Px(EQLeftMargin + Effects.MaxEQBands * (EQBandWidth + EQBandGap) + EQLeftMargin);
        DeleteButton.Left := Width - Px(28);
        BuildEQ4;
      end;
    Effects.ekLimiter:
      begin
        Width := Px(200);
        DeleteButton.Left := Width - Px(28);
        BuildLimiter;
      end;
  end;
end;

procedure TEffectWidget.BuildLowpass;
var
  Lbl: TLabel;
begin
  { row 1 (title/delete) already placed by CreateFor; everything below is
    one clean top-to-bottom flow: description -> slider -> live readout }
  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(8);
  Lbl.Top := Px(40);
  Lbl.Caption := 'Cutoff frequency';

  FLPSlider := TTrackBar.Create(Owner);
  FLPSlider.Parent := Self;
  FLPSlider.Left := Px(8);
  FLPSlider.Top := Px(68);
  FLPSlider.Width := Width - Px(16);
  FLPSlider.Height := Px(60);
  FLPSlider.Min := 0;
  FLPSlider.Max := 100;
  FLPSlider.Position := FreqToLogSlider(EffectPtr^.LowpassFreqHz);
  FLPSlider.OnChange := @LPSliderChange;

  FLPValueLabel := TLabel.Create(Owner);
  FLPValueLabel.Parent := Self;
  FLPValueLabel.Left := Px(8);
  FLPValueLabel.Top := Px(140);
  FLPValueLabel.Caption := Format('%d Hz', [Round(EffectPtr^.LowpassFreqHz)]);
end;

procedure TEffectWidget.BuildEQ4;
var
  b, bx: Integer;
  FreqRowLabel, GainRowLabel: TLabel;
begin
  { logical top-to-bottom flow: a labeled row of frequency inputs, then a
    labeled row of vertical gain sliders directly below their own band }
  FreqRowLabel := TLabel.Create(Owner);
  FreqRowLabel.Parent := Self;
  FreqRowLabel.Left := Px(EQLeftMargin);
  FreqRowLabel.Top := Px(38);
  FreqRowLabel.Caption := 'Freq (Hz)';

  GainRowLabel := TLabel.Create(Owner);
  GainRowLabel.Parent := Self;
  GainRowLabel.Left := Px(EQLeftMargin);
  GainRowLabel.Top := Px(108);
  GainRowLabel.Caption := 'Gain (dB)';

  for b := 0 to Effects.MaxEQBands - 1 do
  begin
    bx := EQLeftMargin + b * (EQBandWidth + EQBandGap);

    FEQFreqEdit[b] := TEdit.Create(Owner);
    FEQFreqEdit[b].Parent := Self;
    FEQFreqEdit[b].Left := Px(bx);
    FEQFreqEdit[b].Top := Px(60);
    FEQFreqEdit[b].Width := Px(EQBandWidth);
    FEQFreqEdit[b].Height := Px(26);
    FEQFreqEdit[b].Text := IntToStr(Round(EffectPtr^.EQFreqHz[b]));
    FEQFreqEdit[b].Tag := b;
    FEQFreqEdit[b].OnEditingDone := @EQFreqEditDone;

    FEQGainSlider[b] := TTrackBar.Create(Owner);
    FEQGainSlider[b].Parent := Self;
    FEQGainSlider[b].Left := Px(bx);
    FEQGainSlider[b].Top := Px(128);
    FEQGainSlider[b].Width := Px(EQBandWidth);
    FEQGainSlider[b].Height := Px(WidgetHeight) - Px(128) - Px(10);
    FEQGainSlider[b].Orientation := trVertical;
    FEQGainSlider[b].Min := EQMinGainDb;
    FEQGainSlider[b].Max := EQMaxGainDb;
    FEQGainSlider[b].Position := Round(EffectPtr^.EQGainDb[b]);
    FEQGainSlider[b].Tag := b;
    FEQGainSlider[b].ShowHint := True;
    FEQGainSlider[b].Hint := 'Band gain (dB)';
    FEQGainSlider[b].OnChange := @EQGainSliderChange;
  end;
end;

procedure TEffectWidget.BuildLimiter;
var
  Lbl1, Lbl2: TLabel;
begin
  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(8);
  Lbl1.Top := Px(36);
  Lbl1.Caption := 'Ceiling (dB)';

  FLimiterThresholdSlider := TTrackBar.Create(Owner);
  FLimiterThresholdSlider.Parent := Self;
  FLimiterThresholdSlider.Left := Px(8);
  FLimiterThresholdSlider.Top := Px(54);
  FLimiterThresholdSlider.Width := Width - Px(16);
  FLimiterThresholdSlider.Height := Px(26);
  FLimiterThresholdSlider.Min := LimiterMinThresholdDb;
  FLimiterThresholdSlider.Max := LimiterMaxThresholdDb;
  FLimiterThresholdSlider.Position := Round(EffectPtr^.LimiterThresholdDb);
  FLimiterThresholdSlider.OnChange := @LimiterThresholdSliderChange;

  FLimiterThresholdValueLabel := TLabel.Create(Owner);
  FLimiterThresholdValueLabel.Parent := Self;
  FLimiterThresholdValueLabel.Left := Px(8);
  FLimiterThresholdValueLabel.Top := Px(82);
  FLimiterThresholdValueLabel.Caption := Format('%d dB', [Round(EffectPtr^.LimiterThresholdDb)]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(8);
  Lbl2.Top := Px(100);
  Lbl2.Caption := 'Release (ms)';

  FLimiterReleaseSlider := TTrackBar.Create(Owner);
  FLimiterReleaseSlider.Parent := Self;
  FLimiterReleaseSlider.Left := Px(8);
  FLimiterReleaseSlider.Top := Px(118);
  FLimiterReleaseSlider.Width := Width - Px(16);
  FLimiterReleaseSlider.Height := Px(26);
  FLimiterReleaseSlider.Min := LimiterMinReleaseMs;
  FLimiterReleaseSlider.Max := LimiterMaxReleaseMs;
  FLimiterReleaseSlider.Position := Round(EffectPtr^.LimiterReleaseMs);
  FLimiterReleaseSlider.OnChange := @LimiterReleaseSliderChange;

  FLimiterReleaseValueLabel := TLabel.Create(Owner);
  FLimiterReleaseValueLabel.Parent := Self;
  FLimiterReleaseValueLabel.Left := Px(8);
  FLimiterReleaseValueLabel.Top := Px(146);
  FLimiterReleaseValueLabel.Caption := Format('%d ms', [Round(EffectPtr^.LimiterReleaseMs)]);
end;

procedure TEffectWidget.DeleteClick(Sender: TObject);
begin
  if FIsMaster then
    Project.RemoveMasterEffect(FEffectIndex)
  else
    Project.RemoveTrackEffect(FTrackIndex, FEffectIndex);
  if Assigned(FOnRackChanged) then
    FOnRackChanged(Self);
end;

procedure TEffectWidget.LPSliderChange(Sender: TObject);
var
  Freq: Single;
begin
  Freq := LogSliderToFreq(FLPSlider.Position);
  EffectPtr^.LowpassFreqHz := Freq;
  FLPValueLabel.Caption := Format('%d Hz', [Round(Freq)]);
end;

procedure TEffectWidget.EQFreqEditDone(Sender: TObject);
var
  b: Integer;
  Value: Integer;
begin
  b := (Sender as TEdit).Tag;
  if not TryStrToInt(Trim((Sender as TEdit).Text), Value) then
    Value := Round(EffectPtr^.EQFreqHz[b]);
  if Value < Round(LPMinHz) then Value := Round(LPMinHz);
  if Value > Round(LPMaxHz) then Value := Round(LPMaxHz);
  (Sender as TEdit).Text := IntToStr(Value);
  EffectPtr^.EQFreqHz[b] := Value;
end;

procedure TEffectWidget.EQGainSliderChange(Sender: TObject);
var
  b: Integer;
begin
  b := (Sender as TTrackBar).Tag;
  EffectPtr^.EQGainDb[b] := (Sender as TTrackBar).Position;
end;

procedure TEffectWidget.LimiterThresholdSliderChange(Sender: TObject);
begin
  EffectPtr^.LimiterThresholdDb := FLimiterThresholdSlider.Position;
  FLimiterThresholdValueLabel.Caption := Format('%d dB', [FLimiterThresholdSlider.Position]);
end;

procedure TEffectWidget.LimiterReleaseSliderChange(Sender: TObject);
begin
  EffectPtr^.LimiterReleaseMs := FLimiterReleaseSlider.Position;
  FLimiterReleaseValueLabel.Caption := Format('%d ms', [FLimiterReleaseSlider.Position]);
end;

end.
