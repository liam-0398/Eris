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
    FHPSlider: TTrackBar;
    FHPValueLabel: TLabel;
    FBPSlider: TTrackBar;
    FBPValueLabel: TLabel;
    FBPQSlider: TTrackBar;
    FBPQValueLabel: TLabel;
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
    procedure HPSliderChange(Sender: TObject);
    procedure BPSliderChange(Sender: TObject);
    procedure BPQSliderChange(Sender: TObject);
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
    procedure BuildHighpass;
    procedure BuildBandpass;
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
  { horizontal layout: one wider column for the source-track dropdown (needs
    room for "Track 16"), then EQ4-style narrow slider columns for
    Threshold/Attack/Release/Strength - see BuildSidechain }
  SidechainSourceColWidth = 80;
  SidechainSliderColCount = 4;
  SidechainColWidth = 54;
  SidechainColGap = 6;
  SidechainLeftMargin = 8;
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
  { horizontal EQ4-style column layout - see the ekDrowning case in
    CreateFor and BuildDrowning below }
  DrowningColCount = 6;
  DrowningColWidth = 54;
  DrowningColGap = 6;
  DrowningLeftMargin = 8;
  FlangerColCount = 4;
  FlangerColWidth = 54;
  FlangerColGap = 6;
  FlangerLeftMargin = 8;
  PhaserColCount = 4;
  PhaserColWidth = 54;
  PhaserColGap = 6;
  PhaserLeftMargin = 8;

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
    Effects.ekLowpass: TitleLabel.Caption := 'LP';
    Effects.ekHighpass: TitleLabel.Caption := 'HP';
    Effects.ekBandpass: TitleLabel.Caption := 'BP';
    Effects.ekEQ4: TitleLabel.Caption := 'EQ 4';
    Effects.ekLimiter: TitleLabel.Caption := 'Limiter';
    Effects.ekChorus: TitleLabel.Caption := 'Chorus';
    Effects.ekReverb: TitleLabel.Caption := 'Basic Reverb';
    Effects.ekFlanger: TitleLabel.Caption := 'Flanger';
    Effects.ekPhaser: TitleLabel.Caption := 'Phaser';
    Effects.ekSidechain: TitleLabel.Caption := 'Sidechain';
    Effects.ekDrowning: TitleLabel.Caption := 'Drowning';
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
    Effects.ekHighpass:
      begin
        Width := Px(200);
        DeleteButton.Left := Width - Px(28);
        BuildHighpass;
      end;
    Effects.ekBandpass:
      begin
        Width := Px(200);
        DeleteButton.Left := Width - Px(28);
        BuildBandpass;
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
        { horizontal, EQ4-style column layout - see BuildDrowning's comment,
          same idea, 4 columns instead of 6 }
        Width := Px(FlangerLeftMargin + FlangerColCount * (FlangerColWidth + FlangerColGap) + FlangerLeftMargin);
        DeleteButton.Left := Width - Px(28);
        BuildFlanger;
      end;
    Effects.ekPhaser:
      begin
        Width := Px(PhaserLeftMargin + PhaserColCount * (PhaserColWidth + PhaserColGap) + PhaserLeftMargin);
        DeleteButton.Left := Width - Px(28);
        BuildPhaser;
      end;
    Effects.ekSidechain:
      begin
        { horizontal layout, standard WidgetHeight: a wider first column for
          the source-track dropdown, then 4 narrow EQ4-style slider columns -
          see BuildSidechain }
        Width := Px(SidechainLeftMargin + SidechainSourceColWidth + SidechainColGap +
          SidechainSliderColCount * (SidechainColWidth + SidechainColGap) + SidechainLeftMargin);
        DeleteButton.Left := Width - Px(28);
        BuildSidechain;
      end;
    Effects.ekDrowning:
      begin
        { horizontal, EQ4-style column layout (6 narrow columns of a label +
          vertical slider + value readout) instead of 6 stacked full-width
          rows, so it stays the same Height as every other widget in the
          rack rather than towering over them }
        Width := Px(DrowningLeftMargin + DrowningColCount * (DrowningColWidth + DrowningColGap) + DrowningLeftMargin);
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

procedure TEffectWidget.BuildHighpass;
var
  Lbl: TLabel;
begin
  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(8);
  Lbl.Top := Px(40);
  Lbl.Caption := 'Cutoff frequency';

  FHPSlider := TTrackBar.Create(Owner);
  FHPSlider.Parent := Self;
  FHPSlider.Left := Px(8);
  FHPSlider.Top := Px(68);
  FHPSlider.Width := Width - Px(16);
  FHPSlider.Height := Px(60);
  FHPSlider.Min := 0;
  FHPSlider.Max := 100;
  FHPSlider.Position := FreqToLogSlider(EffectPtr^.HighpassFreqHz);
  FHPSlider.OnChange := @HPSliderChange;

  FHPValueLabel := TLabel.Create(Owner);
  FHPValueLabel.Parent := Self;
  FHPValueLabel.Left := Px(8);
  FHPValueLabel.Top := Px(140);
  FHPValueLabel.Caption := Format('%d Hz', [Round(EffectPtr^.HighpassFreqHz)]);
end;

procedure TEffectWidget.BuildBandpass;
var
  Lbl: TLabel;
begin
  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(8);
  Lbl.Top := Px(40);
  Lbl.Caption := 'Center frequency';

  FBPSlider := TTrackBar.Create(Owner);
  FBPSlider.Parent := Self;
  FBPSlider.Left := Px(8);
  FBPSlider.Top := Px(68);
  FBPSlider.Width := Width - Px(16);
  FBPSlider.Height := Px(60);
  FBPSlider.Min := 0;
  FBPSlider.Max := 100;
  FBPSlider.Position := FreqToLogSlider(EffectPtr^.BandpassFreqHz);
  FBPSlider.OnChange := @BPSliderChange;

  FBPValueLabel := TLabel.Create(Owner);
  FBPValueLabel.Parent := Self;
  FBPValueLabel.Left := Px(8);
  FBPValueLabel.Top := Px(140);
  FBPValueLabel.Caption := Format('%d Hz', [Round(EffectPtr^.BandpassFreqHz)]);

  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(8);
  Lbl.Top := Px(160);
  Lbl.Caption := 'Q (bandwidth)';

  FBPQSlider := TTrackBar.Create(Owner);
  FBPQSlider.Parent := Self;
  FBPQSlider.Left := Px(8);
  FBPQSlider.Top := Px(188);
  FBPQSlider.Width := Width - Px(16);
  FBPQSlider.Height := Px(60);
  FBPQSlider.Min := 0;
  FBPQSlider.Max := 100;
  FBPQSlider.Position := Round(EffectPtr^.BandpassQ * 20);
  FBPQSlider.OnChange := @BPQSliderChange;

  FBPQValueLabel := TLabel.Create(Owner);
  FBPQValueLabel.Parent := Self;
  FBPQValueLabel.Left := Px(8);
  FBPQValueLabel.Top := Px(260);
  FBPQValueLabel.Caption := Format('Q: %.2f', [EffectPtr^.BandpassQ]);
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
  Col1, Col2, Col3, Col4: Integer;
begin
  { horizontal, EQ4-style column layout: label on top, vertical slider
    filling the middle, value readout at the bottom - keeps this the same
    Height as every other widget in the rack instead of stacking 4
    full-width rows into a much taller box }
  Col1 := FlangerLeftMargin;
  Col2 := Col1 + FlangerColWidth + FlangerColGap;
  Col3 := Col2 + FlangerColWidth + FlangerColGap;
  Col4 := Col3 + FlangerColWidth + FlangerColGap;

  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(Col1);
  Lbl1.Top := Px(30);
  Lbl1.Caption := 'Rate';

  FFlangerRateSlider := TTrackBar.Create(Owner);
  FFlangerRateSlider.Parent := Self;
  FFlangerRateSlider.Orientation := trVertical;
  FFlangerRateSlider.Left := Px(Col1);
  FFlangerRateSlider.Top := Px(48);
  FFlangerRateSlider.Width := Px(FlangerColWidth);
  FFlangerRateSlider.Height := Px(WidgetHeight - 48 - 24);
  FFlangerRateSlider.Reversed := True;
  FFlangerRateSlider.Min := FlangerMinRateX100;
  FFlangerRateSlider.Max := FlangerMaxRateX100;
  FFlangerRateSlider.Position := Round(EffectPtr^.FlangerRateHz * 100);
  FFlangerRateSlider.OnChange := @FlangerRateSliderChange;

  FFlangerRateValueLabel := TLabel.Create(Owner);
  FFlangerRateValueLabel.Parent := Self;
  FFlangerRateValueLabel.Left := Px(Col1);
  FFlangerRateValueLabel.Top := Px(WidgetHeight - 22);
  FFlangerRateValueLabel.Caption := Format('%.2fHz', [EffectPtr^.FlangerRateHz]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(Col2);
  Lbl2.Top := Px(30);
  Lbl2.Caption := 'Depth';

  FFlangerDepthSlider := TTrackBar.Create(Owner);
  FFlangerDepthSlider.Parent := Self;
  FFlangerDepthSlider.Orientation := trVertical;
  FFlangerDepthSlider.Left := Px(Col2);
  FFlangerDepthSlider.Top := Px(48);
  FFlangerDepthSlider.Width := Px(FlangerColWidth);
  FFlangerDepthSlider.Height := Px(WidgetHeight - 48 - 24);
  FFlangerDepthSlider.Reversed := True;
  FFlangerDepthSlider.Min := FlangerMinDepthPercent;
  FFlangerDepthSlider.Max := FlangerMaxDepthPercent;
  FFlangerDepthSlider.Position := Round(EffectPtr^.FlangerDepthPercent);
  FFlangerDepthSlider.OnChange := @FlangerDepthSliderChange;

  FFlangerDepthValueLabel := TLabel.Create(Owner);
  FFlangerDepthValueLabel.Parent := Self;
  FFlangerDepthValueLabel.Left := Px(Col2);
  FFlangerDepthValueLabel.Top := Px(WidgetHeight - 22);
  FFlangerDepthValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.FlangerDepthPercent)]);

  Lbl3 := TLabel.Create(Owner);
  Lbl3.Parent := Self;
  Lbl3.Left := Px(Col3);
  Lbl3.Top := Px(30);
  Lbl3.Caption := 'Fdbk';

  FFlangerFeedbackSlider := TTrackBar.Create(Owner);
  FFlangerFeedbackSlider.Parent := Self;
  FFlangerFeedbackSlider.Orientation := trVertical;
  FFlangerFeedbackSlider.Left := Px(Col3);
  FFlangerFeedbackSlider.Top := Px(48);
  FFlangerFeedbackSlider.Width := Px(FlangerColWidth);
  FFlangerFeedbackSlider.Height := Px(WidgetHeight - 48 - 24);
  FFlangerFeedbackSlider.Reversed := True;
  FFlangerFeedbackSlider.Min := FlangerMinFeedbackPercent;
  FFlangerFeedbackSlider.Max := FlangerMaxFeedbackPercent;
  FFlangerFeedbackSlider.Position := Round(EffectPtr^.FlangerFeedbackPercent);
  FFlangerFeedbackSlider.OnChange := @FlangerFeedbackSliderChange;

  FFlangerFeedbackValueLabel := TLabel.Create(Owner);
  FFlangerFeedbackValueLabel.Parent := Self;
  FFlangerFeedbackValueLabel.Left := Px(Col3);
  FFlangerFeedbackValueLabel.Top := Px(WidgetHeight - 22);
  FFlangerFeedbackValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.FlangerFeedbackPercent)]);

  Lbl4 := TLabel.Create(Owner);
  Lbl4.Parent := Self;
  Lbl4.Left := Px(Col4);
  Lbl4.Top := Px(30);
  Lbl4.Caption := 'Mix';

  FFlangerMixSlider := TTrackBar.Create(Owner);
  FFlangerMixSlider.Parent := Self;
  FFlangerMixSlider.Orientation := trVertical;
  FFlangerMixSlider.Left := Px(Col4);
  FFlangerMixSlider.Top := Px(48);
  FFlangerMixSlider.Width := Px(FlangerColWidth);
  FFlangerMixSlider.Height := Px(WidgetHeight - 48 - 24);
  FFlangerMixSlider.Reversed := True;
  FFlangerMixSlider.Min := FlangerMinMixPercent;
  FFlangerMixSlider.Max := FlangerMaxMixPercent;
  FFlangerMixSlider.Position := Round(EffectPtr^.FlangerMixPercent);
  FFlangerMixSlider.OnChange := @FlangerMixSliderChange;

  FFlangerMixValueLabel := TLabel.Create(Owner);
  FFlangerMixValueLabel.Parent := Self;
  FFlangerMixValueLabel.Left := Px(Col4);
  FFlangerMixValueLabel.Top := Px(WidgetHeight - 22);
  FFlangerMixValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.FlangerMixPercent)]);
end;

procedure TEffectWidget.BuildPhaser;
var
  Lbl1, Lbl2, Lbl3, Lbl4: TLabel;
  Col1, Col2, Col3, Col4: Integer;
begin
  Col1 := PhaserLeftMargin;
  Col2 := Col1 + PhaserColWidth + PhaserColGap;
  Col3 := Col2 + PhaserColWidth + PhaserColGap;
  Col4 := Col3 + PhaserColWidth + PhaserColGap;

  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(Col1);
  Lbl1.Top := Px(30);
  Lbl1.Caption := 'Rate';

  FPhaserRateSlider := TTrackBar.Create(Owner);
  FPhaserRateSlider.Parent := Self;
  FPhaserRateSlider.Orientation := trVertical;
  FPhaserRateSlider.Left := Px(Col1);
  FPhaserRateSlider.Top := Px(48);
  FPhaserRateSlider.Width := Px(PhaserColWidth);
  FPhaserRateSlider.Height := Px(WidgetHeight - 48 - 24);
  FPhaserRateSlider.Reversed := True;
  FPhaserRateSlider.Min := PhaserMinRateX100;
  FPhaserRateSlider.Max := PhaserMaxRateX100;
  FPhaserRateSlider.Position := Round(EffectPtr^.PhaserRateHz * 100);
  FPhaserRateSlider.OnChange := @PhaserRateSliderChange;

  FPhaserRateValueLabel := TLabel.Create(Owner);
  FPhaserRateValueLabel.Parent := Self;
  FPhaserRateValueLabel.Left := Px(Col1);
  FPhaserRateValueLabel.Top := Px(WidgetHeight - 22);
  FPhaserRateValueLabel.Caption := Format('%.2fHz', [EffectPtr^.PhaserRateHz]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(Col2);
  Lbl2.Top := Px(30);
  Lbl2.Caption := 'Depth';

  FPhaserDepthSlider := TTrackBar.Create(Owner);
  FPhaserDepthSlider.Parent := Self;
  FPhaserDepthSlider.Orientation := trVertical;
  FPhaserDepthSlider.Left := Px(Col2);
  FPhaserDepthSlider.Top := Px(48);
  FPhaserDepthSlider.Width := Px(PhaserColWidth);
  FPhaserDepthSlider.Height := Px(WidgetHeight - 48 - 24);
  FPhaserDepthSlider.Reversed := True;
  FPhaserDepthSlider.Min := PhaserMinDepthPercent;
  FPhaserDepthSlider.Max := PhaserMaxDepthPercent;
  FPhaserDepthSlider.Position := Round(EffectPtr^.PhaserDepthPercent);
  FPhaserDepthSlider.OnChange := @PhaserDepthSliderChange;

  FPhaserDepthValueLabel := TLabel.Create(Owner);
  FPhaserDepthValueLabel.Parent := Self;
  FPhaserDepthValueLabel.Left := Px(Col2);
  FPhaserDepthValueLabel.Top := Px(WidgetHeight - 22);
  FPhaserDepthValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.PhaserDepthPercent)]);

  Lbl3 := TLabel.Create(Owner);
  Lbl3.Parent := Self;
  Lbl3.Left := Px(Col3);
  Lbl3.Top := Px(30);
  Lbl3.Caption := 'Fdbk';

  FPhaserFeedbackSlider := TTrackBar.Create(Owner);
  FPhaserFeedbackSlider.Parent := Self;
  FPhaserFeedbackSlider.Orientation := trVertical;
  FPhaserFeedbackSlider.Left := Px(Col3);
  FPhaserFeedbackSlider.Top := Px(48);
  FPhaserFeedbackSlider.Width := Px(PhaserColWidth);
  FPhaserFeedbackSlider.Height := Px(WidgetHeight - 48 - 24);
  FPhaserFeedbackSlider.Reversed := True;
  FPhaserFeedbackSlider.Min := PhaserMinFeedbackPercent;
  FPhaserFeedbackSlider.Max := PhaserMaxFeedbackPercent;
  FPhaserFeedbackSlider.Position := Round(EffectPtr^.PhaserFeedbackPercent);
  FPhaserFeedbackSlider.OnChange := @PhaserFeedbackSliderChange;

  FPhaserFeedbackValueLabel := TLabel.Create(Owner);
  FPhaserFeedbackValueLabel.Parent := Self;
  FPhaserFeedbackValueLabel.Left := Px(Col3);
  FPhaserFeedbackValueLabel.Top := Px(WidgetHeight - 22);
  FPhaserFeedbackValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.PhaserFeedbackPercent)]);

  Lbl4 := TLabel.Create(Owner);
  Lbl4.Parent := Self;
  Lbl4.Left := Px(Col4);
  Lbl4.Top := Px(30);
  Lbl4.Caption := 'Mix';

  FPhaserMixSlider := TTrackBar.Create(Owner);
  FPhaserMixSlider.Parent := Self;
  FPhaserMixSlider.Orientation := trVertical;
  FPhaserMixSlider.Left := Px(Col4);
  FPhaserMixSlider.Top := Px(48);
  FPhaserMixSlider.Width := Px(PhaserColWidth);
  FPhaserMixSlider.Height := Px(WidgetHeight - 48 - 24);
  FPhaserMixSlider.Reversed := True;
  FPhaserMixSlider.Min := PhaserMinMixPercent;
  FPhaserMixSlider.Max := PhaserMaxMixPercent;
  FPhaserMixSlider.Position := Round(EffectPtr^.PhaserMixPercent);
  FPhaserMixSlider.OnChange := @PhaserMixSliderChange;

  FPhaserMixValueLabel := TLabel.Create(Owner);
  FPhaserMixValueLabel.Parent := Self;
  FPhaserMixValueLabel.Left := Px(Col4);
  FPhaserMixValueLabel.Top := Px(WidgetHeight - 22);
  FPhaserMixValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.PhaserMixPercent)]);
end;

procedure TEffectWidget.BuildSidechain;
var
  Lbl0, Lbl1, Lbl2, Lbl3, Lbl4: TLabel;
  Col1, Col2, Col3, Col4, Col5: Integer;
  t: Integer;
begin
  { horizontal layout, standard WidgetHeight: a wider first column for the
    source-track dropdown, then EQ4-style narrow slider columns for
    Threshold/Attack/Release/Strength - same idea as BuildFlanger/
    BuildDrowning, just with one wide column instead of all-narrow }
  Col1 := SidechainLeftMargin;
  Col2 := Col1 + SidechainSourceColWidth + SidechainColGap;
  Col3 := Col2 + SidechainColWidth + SidechainColGap;
  Col4 := Col3 + SidechainColWidth + SidechainColGap;
  Col5 := Col4 + SidechainColWidth + SidechainColGap;

  Lbl0 := TLabel.Create(Owner);
  Lbl0.Parent := Self;
  Lbl0.Left := Px(Col1);
  Lbl0.Top := Px(30);
  Lbl0.Caption := 'Source';

  { lists every possible track slot (Project.MaxTracks), not just the
    currently-visible TrackCount, so a saved choice never goes out of range
    if tracks are added/removed later }
  FSidechainSourceCombo := TComboBox.Create(Owner);
  FSidechainSourceCombo.Parent := Self;
  FSidechainSourceCombo.Style := csDropDownList;
  FSidechainSourceCombo.Left := Px(Col1);
  FSidechainSourceCombo.Top := Px(48);
  FSidechainSourceCombo.Width := Px(SidechainSourceColWidth);
  for t := 0 to Project.MaxTracks - 1 do
    FSidechainSourceCombo.Items.Add('Track ' + IntToStr(t + 1));
  FSidechainSourceCombo.ItemIndex := EffectPtr^.SidechainSourceTrack;
  FSidechainSourceCombo.OnChange := @SidechainSourceChange;

  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(Col2);
  Lbl1.Top := Px(30);
  Lbl1.Caption := 'Thresh';

  FSidechainThresholdSlider := TTrackBar.Create(Owner);
  FSidechainThresholdSlider.Parent := Self;
  FSidechainThresholdSlider.Orientation := trVertical;
  FSidechainThresholdSlider.Left := Px(Col2);
  FSidechainThresholdSlider.Top := Px(48);
  FSidechainThresholdSlider.Width := Px(SidechainColWidth);
  FSidechainThresholdSlider.Height := Px(WidgetHeight - 48 - 24);
  FSidechainThresholdSlider.Reversed := True;
  FSidechainThresholdSlider.Min := SidechainMinThresholdDb;
  FSidechainThresholdSlider.Max := SidechainMaxThresholdDb;
  FSidechainThresholdSlider.Position := Round(EffectPtr^.SidechainThresholdDb);
  FSidechainThresholdSlider.OnChange := @SidechainThresholdSliderChange;

  FSidechainThresholdValueLabel := TLabel.Create(Owner);
  FSidechainThresholdValueLabel.Parent := Self;
  FSidechainThresholdValueLabel.Left := Px(Col2);
  FSidechainThresholdValueLabel.Top := Px(WidgetHeight - 22);
  FSidechainThresholdValueLabel.Caption := Format('%ddB', [Round(EffectPtr^.SidechainThresholdDb)]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(Col3);
  Lbl2.Top := Px(30);
  Lbl2.Caption := 'Attack';

  FSidechainAttackSlider := TTrackBar.Create(Owner);
  FSidechainAttackSlider.Parent := Self;
  FSidechainAttackSlider.Orientation := trVertical;
  FSidechainAttackSlider.Left := Px(Col3);
  FSidechainAttackSlider.Top := Px(48);
  FSidechainAttackSlider.Width := Px(SidechainColWidth);
  FSidechainAttackSlider.Height := Px(WidgetHeight - 48 - 24);
  FSidechainAttackSlider.Reversed := True;
  FSidechainAttackSlider.Min := SidechainMinAttackMs;
  FSidechainAttackSlider.Max := SidechainMaxAttackMs;
  FSidechainAttackSlider.Position := Round(EffectPtr^.SidechainAttackMs);
  FSidechainAttackSlider.OnChange := @SidechainAttackSliderChange;

  FSidechainAttackValueLabel := TLabel.Create(Owner);
  FSidechainAttackValueLabel.Parent := Self;
  FSidechainAttackValueLabel.Left := Px(Col3);
  FSidechainAttackValueLabel.Top := Px(WidgetHeight - 22);
  FSidechainAttackValueLabel.Caption := Format('%dms', [Round(EffectPtr^.SidechainAttackMs)]);

  Lbl3 := TLabel.Create(Owner);
  Lbl3.Parent := Self;
  Lbl3.Left := Px(Col4);
  Lbl3.Top := Px(30);
  Lbl3.Caption := 'Release';

  FSidechainReleaseSlider := TTrackBar.Create(Owner);
  FSidechainReleaseSlider.Parent := Self;
  FSidechainReleaseSlider.Orientation := trVertical;
  FSidechainReleaseSlider.Left := Px(Col4);
  FSidechainReleaseSlider.Top := Px(48);
  FSidechainReleaseSlider.Width := Px(SidechainColWidth);
  FSidechainReleaseSlider.Height := Px(WidgetHeight - 48 - 24);
  FSidechainReleaseSlider.Reversed := True;
  FSidechainReleaseSlider.Min := SidechainMinReleaseMs;
  FSidechainReleaseSlider.Max := SidechainMaxReleaseMs;
  FSidechainReleaseSlider.Position := Round(EffectPtr^.SidechainReleaseMs);
  FSidechainReleaseSlider.OnChange := @SidechainReleaseSliderChange;

  FSidechainReleaseValueLabel := TLabel.Create(Owner);
  FSidechainReleaseValueLabel.Parent := Self;
  FSidechainReleaseValueLabel.Left := Px(Col4);
  FSidechainReleaseValueLabel.Top := Px(WidgetHeight - 22);
  FSidechainReleaseValueLabel.Caption := Format('%dms', [Round(EffectPtr^.SidechainReleaseMs)]);

  Lbl4 := TLabel.Create(Owner);
  Lbl4.Parent := Self;
  Lbl4.Left := Px(Col5);
  Lbl4.Top := Px(30);
  Lbl4.Caption := 'Strength';

  FSidechainStrengthSlider := TTrackBar.Create(Owner);
  FSidechainStrengthSlider.Parent := Self;
  FSidechainStrengthSlider.Orientation := trVertical;
  FSidechainStrengthSlider.Left := Px(Col5);
  FSidechainStrengthSlider.Top := Px(48);
  FSidechainStrengthSlider.Width := Px(SidechainColWidth);
  FSidechainStrengthSlider.Height := Px(WidgetHeight - 48 - 24);
  FSidechainStrengthSlider.Reversed := True;
  FSidechainStrengthSlider.Min := SidechainMinStrengthPercent;
  FSidechainStrengthSlider.Max := SidechainMaxStrengthPercent;
  FSidechainStrengthSlider.Position := Round(EffectPtr^.SidechainStrengthPercent);
  FSidechainStrengthSlider.OnChange := @SidechainStrengthSliderChange;

  FSidechainStrengthValueLabel := TLabel.Create(Owner);
  FSidechainStrengthValueLabel.Parent := Self;
  FSidechainStrengthValueLabel.Left := Px(Col5);
  FSidechainStrengthValueLabel.Top := Px(WidgetHeight - 22);
  FSidechainStrengthValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.SidechainStrengthPercent)]);
end;

procedure TEffectWidget.BuildDrowning;
var
  Lbl1, Lbl2, Lbl3, Lbl4, Lbl5, Lbl6: TLabel;
  Col1, Col2, Col3, Col4, Col5, Col6: Integer;
begin
  { horizontal, EQ4-style column layout - see BuildFlanger's comment, same
    idea, 6 columns instead of 4 }
  Col1 := DrowningLeftMargin;
  Col2 := Col1 + DrowningColWidth + DrowningColGap;
  Col3 := Col2 + DrowningColWidth + DrowningColGap;
  Col4 := Col3 + DrowningColWidth + DrowningColGap;
  Col5 := Col4 + DrowningColWidth + DrowningColGap;
  Col6 := Col5 + DrowningColWidth + DrowningColGap;

  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(Col1);
  Lbl1.Top := Px(30);
  Lbl1.Caption := 'Tone';

  FDrowningToneSlider := TTrackBar.Create(Owner);
  FDrowningToneSlider.Parent := Self;
  FDrowningToneSlider.Orientation := trVertical;
  FDrowningToneSlider.Left := Px(Col1);
  FDrowningToneSlider.Top := Px(48);
  FDrowningToneSlider.Width := Px(DrowningColWidth);
  FDrowningToneSlider.Height := Px(WidgetHeight - 48 - 24);
  FDrowningToneSlider.Reversed := True;
  FDrowningToneSlider.Min := 0;
  FDrowningToneSlider.Max := 100;
  FDrowningToneSlider.Position := FreqToLogSlider(EffectPtr^.DrowningToneHz);
  FDrowningToneSlider.OnChange := @DrowningToneSliderChange;

  FDrowningToneValueLabel := TLabel.Create(Owner);
  FDrowningToneValueLabel.Parent := Self;
  FDrowningToneValueLabel.Left := Px(Col1);
  FDrowningToneValueLabel.Top := Px(WidgetHeight - 22);
  FDrowningToneValueLabel.Caption := Format('%dHz', [Round(EffectPtr^.DrowningToneHz)]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(Col2);
  Lbl2.Top := Px(30);
  Lbl2.Caption := 'W.Rate';

  FDrowningWarbleRateSlider := TTrackBar.Create(Owner);
  FDrowningWarbleRateSlider.Parent := Self;
  FDrowningWarbleRateSlider.Orientation := trVertical;
  FDrowningWarbleRateSlider.Left := Px(Col2);
  FDrowningWarbleRateSlider.Top := Px(48);
  FDrowningWarbleRateSlider.Width := Px(DrowningColWidth);
  FDrowningWarbleRateSlider.Height := Px(WidgetHeight - 48 - 24);
  FDrowningWarbleRateSlider.Reversed := True;
  FDrowningWarbleRateSlider.Min := DrowningMinWarbleRateX100;
  FDrowningWarbleRateSlider.Max := DrowningMaxWarbleRateX100;
  FDrowningWarbleRateSlider.Position := Round(EffectPtr^.DrowningWarbleRateHz * 100);
  FDrowningWarbleRateSlider.OnChange := @DrowningWarbleRateSliderChange;

  FDrowningWarbleRateValueLabel := TLabel.Create(Owner);
  FDrowningWarbleRateValueLabel.Parent := Self;
  FDrowningWarbleRateValueLabel.Left := Px(Col2);
  FDrowningWarbleRateValueLabel.Top := Px(WidgetHeight - 22);
  FDrowningWarbleRateValueLabel.Caption := Format('%.2fHz', [EffectPtr^.DrowningWarbleRateHz]);

  Lbl3 := TLabel.Create(Owner);
  Lbl3.Parent := Self;
  Lbl3.Left := Px(Col3);
  Lbl3.Top := Px(30);
  Lbl3.Caption := 'W.Depth';

  FDrowningWarbleDepthSlider := TTrackBar.Create(Owner);
  FDrowningWarbleDepthSlider.Parent := Self;
  FDrowningWarbleDepthSlider.Orientation := trVertical;
  FDrowningWarbleDepthSlider.Left := Px(Col3);
  FDrowningWarbleDepthSlider.Top := Px(48);
  FDrowningWarbleDepthSlider.Width := Px(DrowningColWidth);
  FDrowningWarbleDepthSlider.Height := Px(WidgetHeight - 48 - 24);
  FDrowningWarbleDepthSlider.Reversed := True;
  FDrowningWarbleDepthSlider.Min := DrowningMinWarbleDepthPercent;
  FDrowningWarbleDepthSlider.Max := DrowningMaxWarbleDepthPercent;
  FDrowningWarbleDepthSlider.Position := Round(EffectPtr^.DrowningWarbleDepthPercent);
  FDrowningWarbleDepthSlider.OnChange := @DrowningWarbleDepthSliderChange;

  FDrowningWarbleDepthValueLabel := TLabel.Create(Owner);
  FDrowningWarbleDepthValueLabel.Parent := Self;
  FDrowningWarbleDepthValueLabel.Left := Px(Col3);
  FDrowningWarbleDepthValueLabel.Top := Px(WidgetHeight - 22);
  FDrowningWarbleDepthValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.DrowningWarbleDepthPercent)]);

  Lbl4 := TLabel.Create(Owner);
  Lbl4.Parent := Self;
  Lbl4.Left := Px(Col4);
  Lbl4.Top := Px(30);
  Lbl4.Caption := 'Size';

  FDrowningSizeSlider := TTrackBar.Create(Owner);
  FDrowningSizeSlider.Parent := Self;
  FDrowningSizeSlider.Orientation := trVertical;
  FDrowningSizeSlider.Left := Px(Col4);
  FDrowningSizeSlider.Top := Px(48);
  FDrowningSizeSlider.Width := Px(DrowningColWidth);
  FDrowningSizeSlider.Height := Px(WidgetHeight - 48 - 24);
  FDrowningSizeSlider.Reversed := True;
  FDrowningSizeSlider.Min := DrowningMinSizePercent;
  FDrowningSizeSlider.Max := DrowningMaxSizePercent;
  FDrowningSizeSlider.Position := Round(EffectPtr^.DrowningSizePercent);
  FDrowningSizeSlider.OnChange := @DrowningSizeSliderChange;

  FDrowningSizeValueLabel := TLabel.Create(Owner);
  FDrowningSizeValueLabel.Parent := Self;
  FDrowningSizeValueLabel.Left := Px(Col4);
  FDrowningSizeValueLabel.Top := Px(WidgetHeight - 22);
  FDrowningSizeValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.DrowningSizePercent)]);

  Lbl5 := TLabel.Create(Owner);
  Lbl5.Parent := Self;
  Lbl5.Left := Px(Col5);
  Lbl5.Top := Px(30);
  Lbl5.Caption := 'Decay';

  FDrowningDecaySlider := TTrackBar.Create(Owner);
  FDrowningDecaySlider.Parent := Self;
  FDrowningDecaySlider.Orientation := trVertical;
  FDrowningDecaySlider.Left := Px(Col5);
  FDrowningDecaySlider.Top := Px(48);
  FDrowningDecaySlider.Width := Px(DrowningColWidth);
  FDrowningDecaySlider.Height := Px(WidgetHeight - 48 - 24);
  FDrowningDecaySlider.Reversed := True;
  FDrowningDecaySlider.Min := DrowningMinDecayPercent;
  FDrowningDecaySlider.Max := DrowningMaxDecayPercent;
  FDrowningDecaySlider.Position := Round(EffectPtr^.DrowningDecayPercent);
  FDrowningDecaySlider.OnChange := @DrowningDecaySliderChange;

  FDrowningDecayValueLabel := TLabel.Create(Owner);
  FDrowningDecayValueLabel.Parent := Self;
  FDrowningDecayValueLabel.Left := Px(Col5);
  FDrowningDecayValueLabel.Top := Px(WidgetHeight - 22);
  FDrowningDecayValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.DrowningDecayPercent)]);

  Lbl6 := TLabel.Create(Owner);
  Lbl6.Parent := Self;
  Lbl6.Left := Px(Col6);
  Lbl6.Top := Px(30);
  Lbl6.Caption := 'Mix';

  FDrowningMixSlider := TTrackBar.Create(Owner);
  FDrowningMixSlider.Parent := Self;
  FDrowningMixSlider.Orientation := trVertical;
  FDrowningMixSlider.Left := Px(Col6);
  FDrowningMixSlider.Top := Px(48);
  FDrowningMixSlider.Width := Px(DrowningColWidth);
  FDrowningMixSlider.Height := Px(WidgetHeight - 48 - 24);
  FDrowningMixSlider.Reversed := True;
  FDrowningMixSlider.Min := DrowningMinMixPercent;
  FDrowningMixSlider.Max := DrowningMaxMixPercent;
  FDrowningMixSlider.Position := Round(EffectPtr^.DrowningMixPercent);
  FDrowningMixSlider.OnChange := @DrowningMixSliderChange;

  FDrowningMixValueLabel := TLabel.Create(Owner);
  FDrowningMixValueLabel.Parent := Self;
  FDrowningMixValueLabel.Left := Px(Col6);
  FDrowningMixValueLabel.Top := Px(WidgetHeight - 22);
  FDrowningMixValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.DrowningMixPercent)]);
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

procedure TEffectWidget.HPSliderChange(Sender: TObject);
var
  Freq: Single;
begin
  Freq := LogSliderToFreq(FHPSlider.Position);
  EffectPtr^.HighpassFreqHz := Freq;
  FHPValueLabel.Caption := Format('%d Hz', [Round(Freq)]);
end;

procedure TEffectWidget.BPSliderChange(Sender: TObject);
var
  Freq: Single;
begin
  Freq := LogSliderToFreq(FBPSlider.Position);
  EffectPtr^.BandpassFreqHz := Freq;
  FBPValueLabel.Caption := Format('%d Hz', [Round(Freq)]);
end;

procedure TEffectWidget.BPQSliderChange(Sender: TObject);
var
  Q: Single;
begin
  Q := FBPQSlider.Position / 20;
  EffectPtr^.BandpassQ := Q;
  FBPQValueLabel.Caption := Format('Q: %.2f', [Q]);
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
