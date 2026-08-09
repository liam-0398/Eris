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
    FChorusRateSlider: TTrackBar;
    FChorusRateValueLabel: TLabel;
    FChorusDepthSlider: TTrackBar;
    FChorusDepthValueLabel: TLabel;
    FReverbPresetCombo: TComboBox;
    FReverbMixSlider: TTrackBar;
    FReverbMixValueLabel: TLabel;
    FFlangerRateSlider, FFlangerDepthSlider, FFlangerFeedbackSlider, FFlangerMixSlider: TTrackBar;
    FFlangerRateValueLabel, FFlangerDepthValueLabel, FFlangerFeedbackValueLabel,
      FFlangerMixValueLabel: TLabel;
    FPhaserRateSlider, FPhaserDepthSlider, FPhaserFeedbackSlider, FPhaserMixSlider: TTrackBar;
    FPhaserRateValueLabel, FPhaserDepthValueLabel, FPhaserFeedbackValueLabel,
      FPhaserMixValueLabel: TLabel;
    FSidechainSourceCombo: TComboBox;
    FSidechainThresholdSlider, FSidechainAttackSlider, FSidechainReleaseSlider,
      FSidechainStrengthSlider: TTrackBar;
    FSidechainThresholdValueLabel, FSidechainAttackValueLabel, FSidechainReleaseValueLabel,
      FSidechainStrengthValueLabel: TLabel;
    FDrowningToneSlider, FDrowningWarbleRateSlider, FDrowningWarbleDepthSlider,
      FDrowningSizeSlider, FDrowningDecaySlider, FDrowningMixSlider: TTrackBar;
    FDrowningToneValueLabel, FDrowningWarbleRateValueLabel, FDrowningWarbleDepthValueLabel,
      FDrowningSizeValueLabel, FDrowningDecayValueLabel, FDrowningMixValueLabel: TLabel;
    function EffectPtr: PEffect;
    procedure DeleteClick(Sender: TObject);
    procedure LPSliderChange(Sender: TObject);
    procedure EQFreqEditDone(Sender: TObject);
    procedure EQGainSliderChange(Sender: TObject);
    procedure LimiterThresholdSliderChange(Sender: TObject);
    procedure LimiterReleaseSliderChange(Sender: TObject);
    procedure ChorusRateSliderChange(Sender: TObject);
    procedure ChorusDepthSliderChange(Sender: TObject);
    procedure ReverbPresetChange(Sender: TObject);
    procedure ReverbMixSliderChange(Sender: TObject);
    procedure FlangerRateSliderChange(Sender: TObject);
    procedure FlangerDepthSliderChange(Sender: TObject);
    procedure FlangerFeedbackSliderChange(Sender: TObject);
    procedure FlangerMixSliderChange(Sender: TObject);
    procedure PhaserRateSliderChange(Sender: TObject);
    procedure PhaserDepthSliderChange(Sender: TObject);
    procedure PhaserFeedbackSliderChange(Sender: TObject);
    procedure PhaserMixSliderChange(Sender: TObject);
    procedure SidechainSourceChange(Sender: TObject);
    procedure SidechainThresholdSliderChange(Sender: TObject);
    procedure SidechainAttackSliderChange(Sender: TObject);
    procedure SidechainReleaseSliderChange(Sender: TObject);
    procedure SidechainStrengthSliderChange(Sender: TObject);
    procedure DrowningToneSliderChange(Sender: TObject);
    procedure DrowningWarbleRateSliderChange(Sender: TObject);
    procedure DrowningWarbleDepthSliderChange(Sender: TObject);
    procedure DrowningSizeSliderChange(Sender: TObject);
    procedure DrowningDecaySliderChange(Sender: TObject);
    procedure DrowningMixSliderChange(Sender: TObject);
    procedure BuildLowpass;
    procedure BuildEQ4;
    procedure BuildLimiter;
    procedure BuildChorus;
    procedure BuildReverb;
    procedure BuildFlanger;
    procedure BuildPhaser;
    procedure BuildSidechain;
    procedure BuildDrowning;
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
  { Rate is stored/edited as Hz * 100 on the slider (an integer control) so a
    sane 0.05-5 Hz musical range still gets fine-grained steps }
  ChorusMinRateX100 = 5;
  ChorusMaxRateX100 = 500;
  ChorusMinDepthPercent = 0;
  ChorusMaxDepthPercent = 100;
  ReverbMinMixPercent = 0;
  ReverbMaxMixPercent = 100;
  { shared sizing so every effect box lines up with the others in the rack
    and with the rest of the bottom bar's widgets }
  WidgetHeight = 180;
  EQBandWidth = 56;
  EQBandGap = 6;
  EQLeftMargin = 8;
  { Flanger/Phaser share Chorus's rate convention (Hz * 100 on an integer
    slider) and add a Feedback control clamped to 95% in the DSP - the UI
    range matches that clamp so the slider can't imply headroom that isn't
    really there. }
  FlangerMinRateX100 = 5;
  FlangerMaxRateX100 = 500;
  FlangerMinDepthPercent = 0;
  FlangerMaxDepthPercent = 100;
  FlangerMinFeedbackPercent = 0;
  FlangerMaxFeedbackPercent = 95;
  FlangerMinMixPercent = 0;
  FlangerMaxMixPercent = 100;
  PhaserMinRateX100 = 5;
  PhaserMaxRateX100 = 500;
  PhaserMinDepthPercent = 0;
  PhaserMaxDepthPercent = 100;
  PhaserMinFeedbackPercent = 0;
  PhaserMaxFeedbackPercent = 95;
  PhaserMinMixPercent = 0;
  PhaserMaxMixPercent = 100;
  SidechainMinThresholdDb = -60;
  SidechainMaxThresholdDb = 0;
  SidechainMinAttackMs = 1;
  SidechainMaxAttackMs = 200;
  SidechainMinReleaseMs = 10;
  SidechainMaxReleaseMs = 1000;
  SidechainMinStrengthPercent = 0;
  SidechainMaxStrengthPercent = 100;
  { Drowning's Tone control reuses Lowpass's log-frequency slider convention
    (FreqToLogSlider/LogSliderToFreq, LPMinHz/LPMaxHz above) }
  DrowningMinWarbleRateX100 = 5;
  DrowningMaxWarbleRateX100 = 500;
  DrowningMinWarbleDepthPercent = 0;
  DrowningMaxWarbleDepthPercent = 100;
  DrowningMinSizePercent = 0;
  DrowningMaxSizePercent = 100;
  DrowningMinDecayPercent = 0;
  DrowningMaxDecayPercent = 100;
  DrowningMinMixPercent = 0;
  DrowningMaxMixPercent = 100;

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
    Effects.ekChorus: TitleLabel.Caption := 'Chorus';
    Effects.ekReverb: TitleLabel.Caption := 'Basic Reverb';
    Effects.ekFlanger: TitleLabel.Caption := 'Flanger';
    Effects.ekPhaser: TitleLabel.Caption := 'Phaser';
    Effects.ekSidechain: TitleLabel.Caption := 'Sidechain';
    Effects.ekDrowning: TitleLabel.Caption := 'Drowning';
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
    Effects.ekChorus:
      begin
        Width := Px(200);
        DeleteButton.Left := Width - Px(28);
        BuildChorus;
      end;
    Effects.ekReverb:
      begin
        Width := Px(220); { a bit wider - "Basic Reverb" needs the room }
        DeleteButton.Left := Width - Px(28);
        BuildReverb;
      end;
    Effects.ekFlanger:
      begin
        Width := Px(200);
        Height := Px(300); { 4 controls, each needing the same vertical room
          as one of Limiter's/Chorus's rows above - taller than the default
          WidgetHeight }
        DeleteButton.Left := Width - Px(28);
        BuildFlanger;
      end;
    Effects.ekPhaser:
      begin
        Width := Px(200);
        Height := Px(300);
        DeleteButton.Left := Width - Px(28);
        BuildPhaser;
      end;
    Effects.ekSidechain:
      begin
        Width := Px(200);
        Height := Px(360); { source-track combo plus 4 controls }
        DeleteButton.Left := Width - Px(28);
        BuildSidechain;
      end;
    Effects.ekDrowning:
      begin
        Width := Px(220);
        Height := Px(430); { 6 controls }
        DeleteButton.Left := Width - Px(28);
        BuildDrowning;
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
    { Orientation must be set before Left/Top/Width/Height -
      TCustomTrackBar.SetOrientation swaps Width/Height for you (assuming
      they were sized for the old orientation), so setting it up front here
      means the explicit sizes below land correctly instead of getting
      silently transposed into a squashed, overflowing box }
    FEQGainSlider[b].Orientation := trVertical;
    FEQGainSlider[b].Left := Px(bx);
    FEQGainSlider[b].Top := Px(128);
    FEQGainSlider[b].Width := Px(EQBandWidth);
    FEQGainSlider[b].Height := Px(WidgetHeight) - Px(128) - Px(10);
    { GTK's un-inverted vertical range puts the Min value at the top, which
      reads backwards for a gain fader - flip it so dragging up means more
      gain, matching every real mixer/EQ }
    FEQGainSlider[b].Reversed := True;
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

procedure TEffectWidget.BuildChorus;
var
  Lbl1, Lbl2: TLabel;
begin
  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(8);
  Lbl1.Top := Px(36);
  Lbl1.Caption := 'Rate (Hz)';

  FChorusRateSlider := TTrackBar.Create(Owner);
  FChorusRateSlider.Parent := Self;
  FChorusRateSlider.Left := Px(8);
  FChorusRateSlider.Top := Px(54);
  FChorusRateSlider.Width := Width - Px(16);
  FChorusRateSlider.Height := Px(26);
  FChorusRateSlider.Min := ChorusMinRateX100;
  FChorusRateSlider.Max := ChorusMaxRateX100;
  FChorusRateSlider.Position := Round(EffectPtr^.ChorusRateHz * 100);
  FChorusRateSlider.OnChange := @ChorusRateSliderChange;

  FChorusRateValueLabel := TLabel.Create(Owner);
  FChorusRateValueLabel.Parent := Self;
  FChorusRateValueLabel.Left := Px(8);
  FChorusRateValueLabel.Top := Px(82);
  FChorusRateValueLabel.Caption := Format('%.2f Hz', [EffectPtr^.ChorusRateHz]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(8);
  Lbl2.Top := Px(100);
  Lbl2.Caption := 'Depth (%)';

  FChorusDepthSlider := TTrackBar.Create(Owner);
  FChorusDepthSlider.Parent := Self;
  FChorusDepthSlider.Left := Px(8);
  FChorusDepthSlider.Top := Px(118);
  FChorusDepthSlider.Width := Width - Px(16);
  FChorusDepthSlider.Height := Px(26);
  FChorusDepthSlider.Min := ChorusMinDepthPercent;
  FChorusDepthSlider.Max := ChorusMaxDepthPercent;
  FChorusDepthSlider.Position := Round(EffectPtr^.ChorusDepthPercent);
  FChorusDepthSlider.OnChange := @ChorusDepthSliderChange;

  FChorusDepthValueLabel := TLabel.Create(Owner);
  FChorusDepthValueLabel.Parent := Self;
  FChorusDepthValueLabel.Left := Px(8);
  FChorusDepthValueLabel.Top := Px(146);
  FChorusDepthValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.ChorusDepthPercent)]);
end;

procedure TEffectWidget.BuildReverb;
var
  Lbl1, Lbl2: TLabel;
  p: Integer;
begin
  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(8);
  Lbl1.Top := Px(36);
  Lbl1.Caption := 'Type';

  FReverbPresetCombo := TComboBox.Create(Owner);
  FReverbPresetCombo.Parent := Self;
  FReverbPresetCombo.Style := csDropDownList;
  FReverbPresetCombo.Left := Px(8);
  FReverbPresetCombo.Top := Px(54);
  FReverbPresetCombo.Width := Width - Px(16);
  for p := 0 to Effects.ReverbPresetCount - 1 do
    FReverbPresetCombo.Items.Add(Effects.ReverbPresetNames[p]);
  FReverbPresetCombo.ItemIndex := EffectPtr^.ReverbPreset;
  FReverbPresetCombo.OnChange := @ReverbPresetChange;

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(8);
  Lbl2.Top := Px(100);
  Lbl2.Caption := 'Dry / Wet';

  FReverbMixSlider := TTrackBar.Create(Owner);
  FReverbMixSlider.Parent := Self;
  FReverbMixSlider.Left := Px(8);
  FReverbMixSlider.Top := Px(118);
  FReverbMixSlider.Width := Width - Px(16);
  FReverbMixSlider.Height := Px(26);
  FReverbMixSlider.Min := ReverbMinMixPercent;
  FReverbMixSlider.Max := ReverbMaxMixPercent;
  FReverbMixSlider.Position := Round(EffectPtr^.ReverbMixPercent);
  FReverbMixSlider.OnChange := @ReverbMixSliderChange;

  FReverbMixValueLabel := TLabel.Create(Owner);
  FReverbMixValueLabel.Parent := Self;
  FReverbMixValueLabel.Left := Px(8);
  FReverbMixValueLabel.Top := Px(146);
  FReverbMixValueLabel.Caption := Format('%d%% wet', [Round(EffectPtr^.ReverbMixPercent)]);
end;

procedure TEffectWidget.BuildFlanger;
var
  Lbl1, Lbl2, Lbl3, Lbl4: TLabel;
begin
  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(8);
  Lbl1.Top := Px(36);
  Lbl1.Caption := 'Rate (Hz)';

  FFlangerRateSlider := TTrackBar.Create(Owner);
  FFlangerRateSlider.Parent := Self;
  FFlangerRateSlider.Left := Px(8);
  FFlangerRateSlider.Top := Px(54);
  FFlangerRateSlider.Width := Width - Px(16);
  FFlangerRateSlider.Height := Px(26);
  FFlangerRateSlider.Min := FlangerMinRateX100;
  FFlangerRateSlider.Max := FlangerMaxRateX100;
  FFlangerRateSlider.Position := Round(EffectPtr^.FlangerRateHz * 100);
  FFlangerRateSlider.OnChange := @FlangerRateSliderChange;

  FFlangerRateValueLabel := TLabel.Create(Owner);
  FFlangerRateValueLabel.Parent := Self;
  FFlangerRateValueLabel.Left := Px(8);
  FFlangerRateValueLabel.Top := Px(82);
  FFlangerRateValueLabel.Caption := Format('%.2f Hz', [EffectPtr^.FlangerRateHz]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(8);
  Lbl2.Top := Px(100);
  Lbl2.Caption := 'Depth (%)';

  FFlangerDepthSlider := TTrackBar.Create(Owner);
  FFlangerDepthSlider.Parent := Self;
  FFlangerDepthSlider.Left := Px(8);
  FFlangerDepthSlider.Top := Px(118);
  FFlangerDepthSlider.Width := Width - Px(16);
  FFlangerDepthSlider.Height := Px(26);
  FFlangerDepthSlider.Min := FlangerMinDepthPercent;
  FFlangerDepthSlider.Max := FlangerMaxDepthPercent;
  FFlangerDepthSlider.Position := Round(EffectPtr^.FlangerDepthPercent);
  FFlangerDepthSlider.OnChange := @FlangerDepthSliderChange;

  FFlangerDepthValueLabel := TLabel.Create(Owner);
  FFlangerDepthValueLabel.Parent := Self;
  FFlangerDepthValueLabel.Left := Px(8);
  FFlangerDepthValueLabel.Top := Px(146);
  FFlangerDepthValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.FlangerDepthPercent)]);

  Lbl3 := TLabel.Create(Owner);
  Lbl3.Parent := Self;
  Lbl3.Left := Px(8);
  Lbl3.Top := Px(164);
  Lbl3.Caption := 'Feedback (%)';

  FFlangerFeedbackSlider := TTrackBar.Create(Owner);
  FFlangerFeedbackSlider.Parent := Self;
  FFlangerFeedbackSlider.Left := Px(8);
  FFlangerFeedbackSlider.Top := Px(182);
  FFlangerFeedbackSlider.Width := Width - Px(16);
  FFlangerFeedbackSlider.Height := Px(26);
  FFlangerFeedbackSlider.Min := FlangerMinFeedbackPercent;
  FFlangerFeedbackSlider.Max := FlangerMaxFeedbackPercent;
  FFlangerFeedbackSlider.Position := Round(EffectPtr^.FlangerFeedbackPercent);
  FFlangerFeedbackSlider.OnChange := @FlangerFeedbackSliderChange;

  FFlangerFeedbackValueLabel := TLabel.Create(Owner);
  FFlangerFeedbackValueLabel.Parent := Self;
  FFlangerFeedbackValueLabel.Left := Px(8);
  FFlangerFeedbackValueLabel.Top := Px(210);
  FFlangerFeedbackValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.FlangerFeedbackPercent)]);

  Lbl4 := TLabel.Create(Owner);
  Lbl4.Parent := Self;
  Lbl4.Left := Px(8);
  Lbl4.Top := Px(228);
  Lbl4.Caption := 'Dry / Wet';

  FFlangerMixSlider := TTrackBar.Create(Owner);
  FFlangerMixSlider.Parent := Self;
  FFlangerMixSlider.Left := Px(8);
  FFlangerMixSlider.Top := Px(246);
  FFlangerMixSlider.Width := Width - Px(16);
  FFlangerMixSlider.Height := Px(26);
  FFlangerMixSlider.Min := FlangerMinMixPercent;
  FFlangerMixSlider.Max := FlangerMaxMixPercent;
  FFlangerMixSlider.Position := Round(EffectPtr^.FlangerMixPercent);
  FFlangerMixSlider.OnChange := @FlangerMixSliderChange;

  FFlangerMixValueLabel := TLabel.Create(Owner);
  FFlangerMixValueLabel.Parent := Self;
  FFlangerMixValueLabel.Left := Px(8);
  FFlangerMixValueLabel.Top := Px(274);
  FFlangerMixValueLabel.Caption := Format('%d%% wet', [Round(EffectPtr^.FlangerMixPercent)]);
end;

procedure TEffectWidget.BuildPhaser;
var
  Lbl1, Lbl2, Lbl3, Lbl4: TLabel;
begin
  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(8);
  Lbl1.Top := Px(36);
  Lbl1.Caption := 'Rate (Hz)';

  FPhaserRateSlider := TTrackBar.Create(Owner);
  FPhaserRateSlider.Parent := Self;
  FPhaserRateSlider.Left := Px(8);
  FPhaserRateSlider.Top := Px(54);
  FPhaserRateSlider.Width := Width - Px(16);
  FPhaserRateSlider.Height := Px(26);
  FPhaserRateSlider.Min := PhaserMinRateX100;
  FPhaserRateSlider.Max := PhaserMaxRateX100;
  FPhaserRateSlider.Position := Round(EffectPtr^.PhaserRateHz * 100);
  FPhaserRateSlider.OnChange := @PhaserRateSliderChange;

  FPhaserRateValueLabel := TLabel.Create(Owner);
  FPhaserRateValueLabel.Parent := Self;
  FPhaserRateValueLabel.Left := Px(8);
  FPhaserRateValueLabel.Top := Px(82);
  FPhaserRateValueLabel.Caption := Format('%.2f Hz', [EffectPtr^.PhaserRateHz]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(8);
  Lbl2.Top := Px(100);
  Lbl2.Caption := 'Depth (%)';

  FPhaserDepthSlider := TTrackBar.Create(Owner);
  FPhaserDepthSlider.Parent := Self;
  FPhaserDepthSlider.Left := Px(8);
  FPhaserDepthSlider.Top := Px(118);
  FPhaserDepthSlider.Width := Width - Px(16);
  FPhaserDepthSlider.Height := Px(26);
  FPhaserDepthSlider.Min := PhaserMinDepthPercent;
  FPhaserDepthSlider.Max := PhaserMaxDepthPercent;
  FPhaserDepthSlider.Position := Round(EffectPtr^.PhaserDepthPercent);
  FPhaserDepthSlider.OnChange := @PhaserDepthSliderChange;

  FPhaserDepthValueLabel := TLabel.Create(Owner);
  FPhaserDepthValueLabel.Parent := Self;
  FPhaserDepthValueLabel.Left := Px(8);
  FPhaserDepthValueLabel.Top := Px(146);
  FPhaserDepthValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.PhaserDepthPercent)]);

  Lbl3 := TLabel.Create(Owner);
  Lbl3.Parent := Self;
  Lbl3.Left := Px(8);
  Lbl3.Top := Px(164);
  Lbl3.Caption := 'Feedback (%)';

  FPhaserFeedbackSlider := TTrackBar.Create(Owner);
  FPhaserFeedbackSlider.Parent := Self;
  FPhaserFeedbackSlider.Left := Px(8);
  FPhaserFeedbackSlider.Top := Px(182);
  FPhaserFeedbackSlider.Width := Width - Px(16);
  FPhaserFeedbackSlider.Height := Px(26);
  FPhaserFeedbackSlider.Min := PhaserMinFeedbackPercent;
  FPhaserFeedbackSlider.Max := PhaserMaxFeedbackPercent;
  FPhaserFeedbackSlider.Position := Round(EffectPtr^.PhaserFeedbackPercent);
  FPhaserFeedbackSlider.OnChange := @PhaserFeedbackSliderChange;

  FPhaserFeedbackValueLabel := TLabel.Create(Owner);
  FPhaserFeedbackValueLabel.Parent := Self;
  FPhaserFeedbackValueLabel.Left := Px(8);
  FPhaserFeedbackValueLabel.Top := Px(210);
  FPhaserFeedbackValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.PhaserFeedbackPercent)]);

  Lbl4 := TLabel.Create(Owner);
  Lbl4.Parent := Self;
  Lbl4.Left := Px(8);
  Lbl4.Top := Px(228);
  Lbl4.Caption := 'Dry / Wet';

  FPhaserMixSlider := TTrackBar.Create(Owner);
  FPhaserMixSlider.Parent := Self;
  FPhaserMixSlider.Left := Px(8);
  FPhaserMixSlider.Top := Px(246);
  FPhaserMixSlider.Width := Width - Px(16);
  FPhaserMixSlider.Height := Px(26);
  FPhaserMixSlider.Min := PhaserMinMixPercent;
  FPhaserMixSlider.Max := PhaserMaxMixPercent;
  FPhaserMixSlider.Position := Round(EffectPtr^.PhaserMixPercent);
  FPhaserMixSlider.OnChange := @PhaserMixSliderChange;

  FPhaserMixValueLabel := TLabel.Create(Owner);
  FPhaserMixValueLabel.Parent := Self;
  FPhaserMixValueLabel.Left := Px(8);
  FPhaserMixValueLabel.Top := Px(274);
  FPhaserMixValueLabel.Caption := Format('%d%% wet', [Round(EffectPtr^.PhaserMixPercent)]);
end;

procedure TEffectWidget.BuildSidechain;
var
  Lbl0, Lbl1, Lbl2, Lbl3, Lbl4: TLabel;
  t: Integer;
begin
  Lbl0 := TLabel.Create(Owner);
  Lbl0.Parent := Self;
  Lbl0.Left := Px(8);
  Lbl0.Top := Px(36);
  Lbl0.Caption := 'Source track';

  { lists every possible track slot (Project.MaxTracks), not just the
    currently-visible TrackCount, so a saved choice never goes out of range
    if tracks are added/removed later }
  FSidechainSourceCombo := TComboBox.Create(Owner);
  FSidechainSourceCombo.Parent := Self;
  FSidechainSourceCombo.Style := csDropDownList;
  FSidechainSourceCombo.Left := Px(8);
  FSidechainSourceCombo.Top := Px(54);
  FSidechainSourceCombo.Width := Width - Px(16);
  for t := 0 to Project.MaxTracks - 1 do
    FSidechainSourceCombo.Items.Add('Track ' + IntToStr(t + 1));
  FSidechainSourceCombo.ItemIndex := EffectPtr^.SidechainSourceTrack;
  FSidechainSourceCombo.OnChange := @SidechainSourceChange;

  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(8);
  Lbl1.Top := Px(100);
  Lbl1.Caption := 'Threshold (dB)';

  FSidechainThresholdSlider := TTrackBar.Create(Owner);
  FSidechainThresholdSlider.Parent := Self;
  FSidechainThresholdSlider.Left := Px(8);
  FSidechainThresholdSlider.Top := Px(118);
  FSidechainThresholdSlider.Width := Width - Px(16);
  FSidechainThresholdSlider.Height := Px(26);
  FSidechainThresholdSlider.Min := SidechainMinThresholdDb;
  FSidechainThresholdSlider.Max := SidechainMaxThresholdDb;
  FSidechainThresholdSlider.Position := Round(EffectPtr^.SidechainThresholdDb);
  FSidechainThresholdSlider.OnChange := @SidechainThresholdSliderChange;

  FSidechainThresholdValueLabel := TLabel.Create(Owner);
  FSidechainThresholdValueLabel.Parent := Self;
  FSidechainThresholdValueLabel.Left := Px(8);
  FSidechainThresholdValueLabel.Top := Px(146);
  FSidechainThresholdValueLabel.Caption := Format('%d dB', [Round(EffectPtr^.SidechainThresholdDb)]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(8);
  Lbl2.Top := Px(164);
  Lbl2.Caption := 'Attack (ms)';

  FSidechainAttackSlider := TTrackBar.Create(Owner);
  FSidechainAttackSlider.Parent := Self;
  FSidechainAttackSlider.Left := Px(8);
  FSidechainAttackSlider.Top := Px(182);
  FSidechainAttackSlider.Width := Width - Px(16);
  FSidechainAttackSlider.Height := Px(26);
  FSidechainAttackSlider.Min := SidechainMinAttackMs;
  FSidechainAttackSlider.Max := SidechainMaxAttackMs;
  FSidechainAttackSlider.Position := Round(EffectPtr^.SidechainAttackMs);
  FSidechainAttackSlider.OnChange := @SidechainAttackSliderChange;

  FSidechainAttackValueLabel := TLabel.Create(Owner);
  FSidechainAttackValueLabel.Parent := Self;
  FSidechainAttackValueLabel.Left := Px(8);
  FSidechainAttackValueLabel.Top := Px(210);
  FSidechainAttackValueLabel.Caption := Format('%d ms', [Round(EffectPtr^.SidechainAttackMs)]);

  Lbl3 := TLabel.Create(Owner);
  Lbl3.Parent := Self;
  Lbl3.Left := Px(8);
  Lbl3.Top := Px(228);
  Lbl3.Caption := 'Release (ms)';

  FSidechainReleaseSlider := TTrackBar.Create(Owner);
  FSidechainReleaseSlider.Parent := Self;
  FSidechainReleaseSlider.Left := Px(8);
  FSidechainReleaseSlider.Top := Px(246);
  FSidechainReleaseSlider.Width := Width - Px(16);
  FSidechainReleaseSlider.Height := Px(26);
  FSidechainReleaseSlider.Min := SidechainMinReleaseMs;
  FSidechainReleaseSlider.Max := SidechainMaxReleaseMs;
  FSidechainReleaseSlider.Position := Round(EffectPtr^.SidechainReleaseMs);
  FSidechainReleaseSlider.OnChange := @SidechainReleaseSliderChange;

  FSidechainReleaseValueLabel := TLabel.Create(Owner);
  FSidechainReleaseValueLabel.Parent := Self;
  FSidechainReleaseValueLabel.Left := Px(8);
  FSidechainReleaseValueLabel.Top := Px(274);
  FSidechainReleaseValueLabel.Caption := Format('%d ms', [Round(EffectPtr^.SidechainReleaseMs)]);

  Lbl4 := TLabel.Create(Owner);
  Lbl4.Parent := Self;
  Lbl4.Left := Px(8);
  Lbl4.Top := Px(292);
  Lbl4.Caption := 'Strength (%)';

  FSidechainStrengthSlider := TTrackBar.Create(Owner);
  FSidechainStrengthSlider.Parent := Self;
  FSidechainStrengthSlider.Left := Px(8);
  FSidechainStrengthSlider.Top := Px(310);
  FSidechainStrengthSlider.Width := Width - Px(16);
  FSidechainStrengthSlider.Height := Px(26);
  FSidechainStrengthSlider.Min := SidechainMinStrengthPercent;
  FSidechainStrengthSlider.Max := SidechainMaxStrengthPercent;
  FSidechainStrengthSlider.Position := Round(EffectPtr^.SidechainStrengthPercent);
  FSidechainStrengthSlider.OnChange := @SidechainStrengthSliderChange;

  FSidechainStrengthValueLabel := TLabel.Create(Owner);
  FSidechainStrengthValueLabel.Parent := Self;
  FSidechainStrengthValueLabel.Left := Px(8);
  FSidechainStrengthValueLabel.Top := Px(338);
  FSidechainStrengthValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.SidechainStrengthPercent)]);
end;

procedure TEffectWidget.BuildDrowning;
var
  Lbl1, Lbl2, Lbl3, Lbl4, Lbl5, Lbl6: TLabel;
begin
  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(8);
  Lbl1.Top := Px(36);
  Lbl1.Caption := 'Tone (Hz)';

  FDrowningToneSlider := TTrackBar.Create(Owner);
  FDrowningToneSlider.Parent := Self;
  FDrowningToneSlider.Left := Px(8);
  FDrowningToneSlider.Top := Px(54);
  FDrowningToneSlider.Width := Width - Px(16);
  FDrowningToneSlider.Height := Px(26);
  FDrowningToneSlider.Min := 0;
  FDrowningToneSlider.Max := 100;
  FDrowningToneSlider.Position := FreqToLogSlider(EffectPtr^.DrowningToneHz);
  FDrowningToneSlider.OnChange := @DrowningToneSliderChange;

  FDrowningToneValueLabel := TLabel.Create(Owner);
  FDrowningToneValueLabel.Parent := Self;
  FDrowningToneValueLabel.Left := Px(8);
  FDrowningToneValueLabel.Top := Px(82);
  FDrowningToneValueLabel.Caption := Format('%d Hz', [Round(EffectPtr^.DrowningToneHz)]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(8);
  Lbl2.Top := Px(100);
  Lbl2.Caption := 'Warble rate (Hz)';

  FDrowningWarbleRateSlider := TTrackBar.Create(Owner);
  FDrowningWarbleRateSlider.Parent := Self;
  FDrowningWarbleRateSlider.Left := Px(8);
  FDrowningWarbleRateSlider.Top := Px(118);
  FDrowningWarbleRateSlider.Width := Width - Px(16);
  FDrowningWarbleRateSlider.Height := Px(26);
  FDrowningWarbleRateSlider.Min := DrowningMinWarbleRateX100;
  FDrowningWarbleRateSlider.Max := DrowningMaxWarbleRateX100;
  FDrowningWarbleRateSlider.Position := Round(EffectPtr^.DrowningWarbleRateHz * 100);
  FDrowningWarbleRateSlider.OnChange := @DrowningWarbleRateSliderChange;

  FDrowningWarbleRateValueLabel := TLabel.Create(Owner);
  FDrowningWarbleRateValueLabel.Parent := Self;
  FDrowningWarbleRateValueLabel.Left := Px(8);
  FDrowningWarbleRateValueLabel.Top := Px(146);
  FDrowningWarbleRateValueLabel.Caption := Format('%.2f Hz', [EffectPtr^.DrowningWarbleRateHz]);

  Lbl3 := TLabel.Create(Owner);
  Lbl3.Parent := Self;
  Lbl3.Left := Px(8);
  Lbl3.Top := Px(164);
  Lbl3.Caption := 'Warble depth (%)';

  FDrowningWarbleDepthSlider := TTrackBar.Create(Owner);
  FDrowningWarbleDepthSlider.Parent := Self;
  FDrowningWarbleDepthSlider.Left := Px(8);
  FDrowningWarbleDepthSlider.Top := Px(182);
  FDrowningWarbleDepthSlider.Width := Width - Px(16);
  FDrowningWarbleDepthSlider.Height := Px(26);
  FDrowningWarbleDepthSlider.Min := DrowningMinWarbleDepthPercent;
  FDrowningWarbleDepthSlider.Max := DrowningMaxWarbleDepthPercent;
  FDrowningWarbleDepthSlider.Position := Round(EffectPtr^.DrowningWarbleDepthPercent);
  FDrowningWarbleDepthSlider.OnChange := @DrowningWarbleDepthSliderChange;

  FDrowningWarbleDepthValueLabel := TLabel.Create(Owner);
  FDrowningWarbleDepthValueLabel.Parent := Self;
  FDrowningWarbleDepthValueLabel.Left := Px(8);
  FDrowningWarbleDepthValueLabel.Top := Px(210);
  FDrowningWarbleDepthValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.DrowningWarbleDepthPercent)]);

  Lbl4 := TLabel.Create(Owner);
  Lbl4.Parent := Self;
  Lbl4.Left := Px(8);
  Lbl4.Top := Px(228);
  Lbl4.Caption := 'Size (%)';

  FDrowningSizeSlider := TTrackBar.Create(Owner);
  FDrowningSizeSlider.Parent := Self;
  FDrowningSizeSlider.Left := Px(8);
  FDrowningSizeSlider.Top := Px(246);
  FDrowningSizeSlider.Width := Width - Px(16);
  FDrowningSizeSlider.Height := Px(26);
  FDrowningSizeSlider.Min := DrowningMinSizePercent;
  FDrowningSizeSlider.Max := DrowningMaxSizePercent;
  FDrowningSizeSlider.Position := Round(EffectPtr^.DrowningSizePercent);
  FDrowningSizeSlider.OnChange := @DrowningSizeSliderChange;

  FDrowningSizeValueLabel := TLabel.Create(Owner);
  FDrowningSizeValueLabel.Parent := Self;
  FDrowningSizeValueLabel.Left := Px(8);
  FDrowningSizeValueLabel.Top := Px(274);
  FDrowningSizeValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.DrowningSizePercent)]);

  Lbl5 := TLabel.Create(Owner);
  Lbl5.Parent := Self;
  Lbl5.Left := Px(8);
  Lbl5.Top := Px(292);
  Lbl5.Caption := 'Decay (%)';

  FDrowningDecaySlider := TTrackBar.Create(Owner);
  FDrowningDecaySlider.Parent := Self;
  FDrowningDecaySlider.Left := Px(8);
  FDrowningDecaySlider.Top := Px(310);
  FDrowningDecaySlider.Width := Width - Px(16);
  FDrowningDecaySlider.Height := Px(26);
  FDrowningDecaySlider.Min := DrowningMinDecayPercent;
  FDrowningDecaySlider.Max := DrowningMaxDecayPercent;
  FDrowningDecaySlider.Position := Round(EffectPtr^.DrowningDecayPercent);
  FDrowningDecaySlider.OnChange := @DrowningDecaySliderChange;

  FDrowningDecayValueLabel := TLabel.Create(Owner);
  FDrowningDecayValueLabel.Parent := Self;
  FDrowningDecayValueLabel.Left := Px(8);
  FDrowningDecayValueLabel.Top := Px(338);
  FDrowningDecayValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.DrowningDecayPercent)]);

  Lbl6 := TLabel.Create(Owner);
  Lbl6.Parent := Self;
  Lbl6.Left := Px(8);
  Lbl6.Top := Px(356);
  Lbl6.Caption := 'Dry / Wet';

  FDrowningMixSlider := TTrackBar.Create(Owner);
  FDrowningMixSlider.Parent := Self;
  FDrowningMixSlider.Left := Px(8);
  FDrowningMixSlider.Top := Px(374);
  FDrowningMixSlider.Width := Width - Px(16);
  FDrowningMixSlider.Height := Px(26);
  FDrowningMixSlider.Min := DrowningMinMixPercent;
  FDrowningMixSlider.Max := DrowningMaxMixPercent;
  FDrowningMixSlider.Position := Round(EffectPtr^.DrowningMixPercent);
  FDrowningMixSlider.OnChange := @DrowningMixSliderChange;

  FDrowningMixValueLabel := TLabel.Create(Owner);
  FDrowningMixValueLabel.Parent := Self;
  FDrowningMixValueLabel.Left := Px(8);
  FDrowningMixValueLabel.Top := Px(402);
  FDrowningMixValueLabel.Caption := Format('%d%% wet', [Round(EffectPtr^.DrowningMixPercent)]);
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

procedure TEffectWidget.ChorusRateSliderChange(Sender: TObject);
var
  RateHz: Single;
begin
  RateHz := FChorusRateSlider.Position / 100;
  EffectPtr^.ChorusRateHz := RateHz;
  FChorusRateValueLabel.Caption := Format('%.2f Hz', [RateHz]);
end;

procedure TEffectWidget.ChorusDepthSliderChange(Sender: TObject);
begin
  EffectPtr^.ChorusDepthPercent := FChorusDepthSlider.Position;
  FChorusDepthValueLabel.Caption := Format('%d%%', [FChorusDepthSlider.Position]);
end;

procedure TEffectWidget.ReverbPresetChange(Sender: TObject);
begin
  EffectPtr^.ReverbPreset := FReverbPresetCombo.ItemIndex;
end;

procedure TEffectWidget.ReverbMixSliderChange(Sender: TObject);
begin
  EffectPtr^.ReverbMixPercent := FReverbMixSlider.Position;
  FReverbMixValueLabel.Caption := Format('%d%% wet', [FReverbMixSlider.Position]);
end;

procedure TEffectWidget.FlangerRateSliderChange(Sender: TObject);
var
  RateHz: Single;
begin
  RateHz := FFlangerRateSlider.Position / 100;
  EffectPtr^.FlangerRateHz := RateHz;
  FFlangerRateValueLabel.Caption := Format('%.2f Hz', [RateHz]);
end;

procedure TEffectWidget.FlangerDepthSliderChange(Sender: TObject);
begin
  EffectPtr^.FlangerDepthPercent := FFlangerDepthSlider.Position;
  FFlangerDepthValueLabel.Caption := Format('%d%%', [FFlangerDepthSlider.Position]);
end;

procedure TEffectWidget.FlangerFeedbackSliderChange(Sender: TObject);
begin
  EffectPtr^.FlangerFeedbackPercent := FFlangerFeedbackSlider.Position;
  FFlangerFeedbackValueLabel.Caption := Format('%d%%', [FFlangerFeedbackSlider.Position]);
end;

procedure TEffectWidget.FlangerMixSliderChange(Sender: TObject);
begin
  EffectPtr^.FlangerMixPercent := FFlangerMixSlider.Position;
  FFlangerMixValueLabel.Caption := Format('%d%% wet', [FFlangerMixSlider.Position]);
end;

procedure TEffectWidget.PhaserRateSliderChange(Sender: TObject);
var
  RateHz: Single;
begin
  RateHz := FPhaserRateSlider.Position / 100;
  EffectPtr^.PhaserRateHz := RateHz;
  FPhaserRateValueLabel.Caption := Format('%.2f Hz', [RateHz]);
end;

procedure TEffectWidget.PhaserDepthSliderChange(Sender: TObject);
begin
  EffectPtr^.PhaserDepthPercent := FPhaserDepthSlider.Position;
  FPhaserDepthValueLabel.Caption := Format('%d%%', [FPhaserDepthSlider.Position]);
end;

procedure TEffectWidget.PhaserFeedbackSliderChange(Sender: TObject);
begin
  EffectPtr^.PhaserFeedbackPercent := FPhaserFeedbackSlider.Position;
  FPhaserFeedbackValueLabel.Caption := Format('%d%%', [FPhaserFeedbackSlider.Position]);
end;

procedure TEffectWidget.PhaserMixSliderChange(Sender: TObject);
begin
  EffectPtr^.PhaserMixPercent := FPhaserMixSlider.Position;
  FPhaserMixValueLabel.Caption := Format('%d%% wet', [FPhaserMixSlider.Position]);
end;

procedure TEffectWidget.SidechainSourceChange(Sender: TObject);
begin
  EffectPtr^.SidechainSourceTrack := FSidechainSourceCombo.ItemIndex;
end;

procedure TEffectWidget.SidechainThresholdSliderChange(Sender: TObject);
begin
  EffectPtr^.SidechainThresholdDb := FSidechainThresholdSlider.Position;
  FSidechainThresholdValueLabel.Caption := Format('%d dB', [FSidechainThresholdSlider.Position]);
end;

procedure TEffectWidget.SidechainAttackSliderChange(Sender: TObject);
begin
  EffectPtr^.SidechainAttackMs := FSidechainAttackSlider.Position;
  FSidechainAttackValueLabel.Caption := Format('%d ms', [FSidechainAttackSlider.Position]);
end;

procedure TEffectWidget.SidechainReleaseSliderChange(Sender: TObject);
begin
  EffectPtr^.SidechainReleaseMs := FSidechainReleaseSlider.Position;
  FSidechainReleaseValueLabel.Caption := Format('%d ms', [FSidechainReleaseSlider.Position]);
end;

procedure TEffectWidget.SidechainStrengthSliderChange(Sender: TObject);
begin
  EffectPtr^.SidechainStrengthPercent := FSidechainStrengthSlider.Position;
  FSidechainStrengthValueLabel.Caption := Format('%d%%', [FSidechainStrengthSlider.Position]);
end;

procedure TEffectWidget.DrowningToneSliderChange(Sender: TObject);
var
  Freq: Single;
begin
  Freq := LogSliderToFreq(FDrowningToneSlider.Position);
  EffectPtr^.DrowningToneHz := Freq;
  FDrowningToneValueLabel.Caption := Format('%d Hz', [Round(Freq)]);
end;

procedure TEffectWidget.DrowningWarbleRateSliderChange(Sender: TObject);
var
  RateHz: Single;
begin
  RateHz := FDrowningWarbleRateSlider.Position / 100;
  EffectPtr^.DrowningWarbleRateHz := RateHz;
  FDrowningWarbleRateValueLabel.Caption := Format('%.2f Hz', [RateHz]);
end;

procedure TEffectWidget.DrowningWarbleDepthSliderChange(Sender: TObject);
begin
  EffectPtr^.DrowningWarbleDepthPercent := FDrowningWarbleDepthSlider.Position;
  FDrowningWarbleDepthValueLabel.Caption := Format('%d%%', [FDrowningWarbleDepthSlider.Position]);
end;

procedure TEffectWidget.DrowningSizeSliderChange(Sender: TObject);
begin
  EffectPtr^.DrowningSizePercent := FDrowningSizeSlider.Position;
  FDrowningSizeValueLabel.Caption := Format('%d%%', [FDrowningSizeSlider.Position]);
end;

procedure TEffectWidget.DrowningDecaySliderChange(Sender: TObject);
begin
  EffectPtr^.DrowningDecayPercent := FDrowningDecaySlider.Position;
  FDrowningDecayValueLabel.Caption := Format('%d%%', [FDrowningDecaySlider.Position]);
end;

procedure TEffectWidget.DrowningMixSliderChange(Sender: TObject);
begin
  EffectPtr^.DrowningMixPercent := FDrowningMixSlider.Position;
  FDrowningMixValueLabel.Caption := Format('%d%% wet', [FDrowningMixSlider.Position]);
end;

end.
