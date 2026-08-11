unit EffectsRack;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ComCtrls, ExtCtrls, Graphics, Effects,
  Quadraverb, BBE422A, Alesis3630, BossFZ2, Project, UIScale;

type
  PEffect = ^Effects.TEffect;

  TEffectRackChangedEvent = procedure(Sender: TObject) of object;

  { The Tuner's readout face. Custom-painted rather than assembled out of
    TLabels for two reasons: the three dots per side have to hold fixed
    positions as the reading moves (a text label reflows and jitters, which
    is exactly what you don't want to be watching while tuning), and a dark
    LED-style face reads at a glance the way a tuner has to.

    It owns its own poll timer and pulls the latest detected pitch straight
    off the audio thread via AudioEngineTunerPitchHz - there is no push from
    the engine and nothing to unsubscribe, so the whole thing dies cleanly
    with the TEffectWidget that owns it. }
  TTunerDisplay = class(TCustomControl)
  private
    FTarget: Integer;
    FEffectIndex: Integer;
    FTimer: TTimer;
    FFreqHz: Single;
    procedure PollTimerTimer(Sender: TObject);
    procedure DrawDots(ACount, ADirection, ACenterX, ACenterY: Integer;
      AColor: TColor);
  protected
    procedure Paint; override;
  public
    constructor CreateFor(AOwner: TComponent; AParent: TWinControl;
      ATarget, AEffectIndex: Integer);
  end;

  { one effect's widget box - a plain TPanel populated with whichever native
    controls its Kind needs, wired directly to Project.TrackEffects, or to
    Project.MasterEffects when AIsMaster is set }
  TEffectWidget = class(TPanel)
  private
    { which chain this widget edits: >= 0 is a track index, otherwise one of
      Project's Bus* constants (master or a send) }
    FTarget: Integer;
    FEffectIndex: Integer;
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
    FTunerDisplay: TTunerDisplay;
    FOverdriveFreqSlider, FOverdriveQSlider, FOverdriveDriveSlider,
      FOverdriveColorSlider, FOverdriveMixSlider: TTrackBar;
    FOverdriveFreqValueLabel, FOverdriveQValueLabel, FOverdriveDriveValueLabel,
      FOverdriveColorValueLabel, FOverdriveMixValueLabel: TLabel;
    FQVRTypeCombo: TComboBox;
    FQVRDecayCaption: TLabel;
    FQVRPredelaySlider, FQVRPredelayMixSlider, FQVRDecaySlider,
      FQVRDiffusionSlider, FQVRDensitySlider, FQVRLowDecaySlider,
      FQVRHighDecaySlider, FQVRMixSlider: TTrackBar;
    FQVRPredelayValueLabel, FQVRPredelayMixValueLabel, FQVRDecayValueLabel,
      FQVRDiffusionValueLabel, FQVRDensityValueLabel, FQVRLowDecayValueLabel,
      FQVRHighDecayValueLabel, FQVRMixValueLabel: TLabel;
    FQVDTypeCombo: TComboBox;
    FQVDTimeLEdit, FQVDTimeREdit: TEdit;
    FQVDTimeRCaption: TLabel;
    FQVDFeedbackLSlider, FQVDFeedbackRSlider, FQVDMixSlider: TTrackBar;
    FQVDFeedbackLValueLabel, FQVDFeedbackRValueLabel, FQVDMixValueLabel: TLabel;
    FBBELoContourSlider, FBBEDefinitionSlider, FBBEMixSlider: TTrackBar;
    FBBELoContourValueLabel, FBBEDefinitionValueLabel, FBBEMixValueLabel: TLabel;
    FC36ResponseCombo, FC36KneeCombo: TComboBox;
    FC36ThresholdSlider, FC36RatioSlider, FC36AttackSlider, FC36ReleaseSlider,
      FC36OutputSlider, FC36GateThresholdSlider, FC36GateRateSlider,
      FC36MixSlider: TTrackBar;
    FC36ThresholdValueLabel, FC36RatioValueLabel, FC36AttackValueLabel,
      FC36ReleaseValueLabel, FC36OutputValueLabel, FC36GateThresholdValueLabel,
      FC36GateRateValueLabel, FC36MixValueLabel: TLabel;
    FFZ2ModeCombo: TComboBox;
    FFZ2GainSlider, FFZ2TrebleSlider, FFZ2BassSlider, FFZ2LevelSlider,
      FFZ2MixSlider: TTrackBar;
    FFZ2GainValueLabel, FFZ2TrebleValueLabel, FFZ2BassValueLabel,
      FFZ2LevelValueLabel, FFZ2MixValueLabel: TLabel;
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
    procedure OverdriveFreqSliderChange(Sender: TObject);
    procedure OverdriveQSliderChange(Sender: TObject);
    procedure OverdriveDriveSliderChange(Sender: TObject);
    procedure OverdriveColorSliderChange(Sender: TObject);
    procedure OverdriveMixSliderChange(Sender: TObject);
    procedure QVRTypeChange(Sender: TObject);
    procedure QVRPredelaySliderChange(Sender: TObject);
    procedure QVRPredelayMixSliderChange(Sender: TObject);
    procedure QVRDecaySliderChange(Sender: TObject);
    procedure QVRDiffusionSliderChange(Sender: TObject);
    procedure QVRDensitySliderChange(Sender: TObject);
    procedure QVRLowDecaySliderChange(Sender: TObject);
    procedure QVRHighDecaySliderChange(Sender: TObject);
    procedure QVRMixSliderChange(Sender: TObject);
    procedure QVRUpdateTypeDependentLabels;
    procedure QVDTypeChange(Sender: TObject);
    procedure QVDTimeEditDone(Sender: TObject);
    procedure QVDFeedbackLSliderChange(Sender: TObject);
    procedure QVDFeedbackRSliderChange(Sender: TObject);
    procedure QVDMixSliderChange(Sender: TObject);
    procedure QVDUpdateTypeDependentControls;
    procedure BBELoContourSliderChange(Sender: TObject);
    procedure BBEDefinitionSliderChange(Sender: TObject);
    procedure BBEMixSliderChange(Sender: TObject);
    procedure C36ResponseChange(Sender: TObject);
    procedure C36KneeChange(Sender: TObject);
    procedure C36ThresholdSliderChange(Sender: TObject);
    procedure C36RatioSliderChange(Sender: TObject);
    procedure C36AttackSliderChange(Sender: TObject);
    procedure C36ReleaseSliderChange(Sender: TObject);
    procedure C36OutputSliderChange(Sender: TObject);
    procedure C36GateThresholdSliderChange(Sender: TObject);
    procedure C36GateRateSliderChange(Sender: TObject);
    procedure C36MixSliderChange(Sender: TObject);
    procedure C36UpdateResponseDependentLabels;
    procedure FZ2ModeChange(Sender: TObject);
    procedure FZ2GainSliderChange(Sender: TObject);
    procedure FZ2TrebleSliderChange(Sender: TObject);
    procedure FZ2BassSliderChange(Sender: TObject);
    procedure FZ2LevelSliderChange(Sender: TObject);
    procedure FZ2MixSliderChange(Sender: TObject);
    procedure FZ2UpdateModeDependentLabels;
    { the standard rack column: caption at the top, vertical slider down the
      middle, value readout on the bottom edge. Every effect that lays out
      as columns builds them through here, which is what keeps them all the
      same height as each other. }
    function AddSliderColumn(ALeft: Integer; const ACaption: string;
      AMin, AMax, APosition: Integer; AOnChange: TNotifyEvent;
      const AHint: string; out AValueLabel: TLabel): TTrackBar;
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
    procedure BuildTuner;
    procedure BuildOverdrive;
    procedure BuildQuadraverbReverb;
    procedure BuildQuadraverbDelay;
    procedure BuildExciter422A;
    procedure BuildCompressor3630;
    procedure BuildFuzzFZ2;
  public
    constructor CreateFor(AOwner: TComponent; AParent: TWinControl;
      ATarget, AEffectIndex: Integer; AOnRackChanged: TEffectRackChangedEvent);
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
  { top of the EQ4 gain sliders: clear of the frequency edits (48 + 26) and
    of the "Gain (dB)" caption that sits on its own row 18px above it }
  EQGainRowTop = 92;
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
  { Tuner: one standard-width box holding nothing but a readout face, so the
    only sizes here are the face's own inset and internals }
  TunerWidgetWidth = 220;
  TunerFaceTop = 34;
  TunerFaceMargin = 8;
  TunerFaceBottomGap = 26; { room for the pass-through caption below the face }
  TunerNoteFontHeight = 26;
  TunerDotRadius = 4;
  TunerDotSpacing = 16;
  { distance from the centre of the face out to the FIRST dot. Has to clear
    the widest note name the readout can ever show - "C#-1", four characters
    at TunerNoteFontHeight bold - because the dots sit at fixed offsets
    rather than being measured off each individual reading (see Paint) }
  TunerDotInset = 48;
  { $00BBGGRR, like every other TColor literal in this codebase }
  TunerFaceColor = $001A1512;      { near-black, very slightly warm }
  TunerInTuneColor = $0050FF50;    { green - dead on the note }
  TunerOffPitchColor = $0000AAFF;  { amber - drifting }
  TunerDimColor = $00555555;       { unlit dots and the idle readout }
  TunerCentsColor = $00909090;
  { Overdrive: EQ4-style narrow columns for Freq / Q / Drive / Color / Mix }
  OverdriveColCount = 5;
  OverdriveColWidth = 54;
  OverdriveColGap = 6;
  OverdriveLeftMargin = 8;
  { Q reuses Bandpass's slider convention (position / 20), floored at the
    same 0.1 the DSP clamps to rather than at a Q of 0 the filter can't use }
  OverdriveMinQx20 = 2;
  OverdriveMaxQx20 = 100;
  OverdriveMinDrivePercent = 0;
  OverdriveMaxDrivePercent = 100;
  OverdriveMinColorPercent = 0;
  OverdriveMaxColorPercent = 100;
  OverdriveMinMixPercent = 0;
  OverdriveMaxMixPercent = 100;
  { QuadraVerb Reverb: one wide column for the reverb-type dropdown, then
    eight standard slider columns - one per remaining front-panel page.
    Every range comes from Quadraverb.pas rather than being restated here,
    so the UI can't drift from what the DSP actually accepts. }
  QVRTypeColWidth = 96;
  QVRColCount = 8;
  QVRColWidth = 54;
  QVRColGap = 6;
  QVRLeftMargin = 8;
  { QuadraVerb Delay: wide first column stacking the type dropdown over the
    two delay-time entries. Times are typed rather than dragged - a slider
    spanning 1-800ms across one widget's worth of travel can't resolve a
    single millisecond, and delay times are the one thing on this box you
    genuinely want to dial exactly. }
  QVDTypeColWidth = 96;
  QVDColCount = 3;
  QVDColWidth = 54;
  QVDColGap = 6;
  QVDLeftMargin = 8;
  { The width AddSliderColumn builds at. Every column layout in this unit
    has always used 54; this is the one AddSliderColumn itself reads, so a
    widget that wants standard columns doesn't have to restate it. }
  SliderColWidth = 54;
  { ...and the gap/margin that go with it. Every per-effect ColGap/LeftMargin
    triplet above is 6/8; these are the shared pair the layouts converted
    below use instead of adding four more copies of the same two numbers. }
  SliderColGap = 6;
  SliderColMargin = 8;
  { Bandpass, Chorus, Limiter and Basic Reverb were the last widgets still
    laid out as full-width stacked rows (label / horizontal slider / readout,
    ~46px of design height each). That never really fitted: a GTK trackbar
    draws its own position number inside its bounds, so a row asking for a
    26px-tall slider actually occupies more like 45 and lands on top of the
    readout underneath it - which is what the overlapping text in every one
    of these boxes was. Bandpass was worse still, needing four rows in a box
    fixed at WidgetHeight, so its Q slider and both readouts sat below the
    bottom edge and never appeared at all. All four now use the same column
    layout the rest of the rack converged on (see AddSliderColumn), which
    gives the slider its own full-height lane and puts the readout on a row
    of its own. }
  BandpassColCount = 2;
  ChorusColCount = 2;
  LimiterColCount = 2;
  { Reverb keeps its preset dropdown, so it follows the Sidechain/QuadraVerb
    shape: one wide column for the dropdown, then standard slider columns }
  ReverbTypeColWidth = 96;
  ReverbColCount = 1;
  { BBE 422A: three standard columns - the two the front panel has, plus
    Mix. Both panel knobs are per-channel on the real box and linked here,
    see BBE422A.pas. }
  BBEColCount = 3;
  BBEColWidth = 54;
  BBEColGap = 6;
  BBELeftMargin = 8;
  { Alesis 3630: a wide first column stacking the two front-panel switches
    (Peak/RMS and Hard/Soft knee) as dropdowns, then eight standard slider
    columns for the six knobs, the gate's two, and Mix. Every range comes
    from Alesis3630.pas rather than being restated here. }
  C36SwitchColWidth = 96;
  C36ColCount = 8;
  C36ColWidth = 54;
  C36ColGap = 6;
  C36LeftMargin = 8;
  { Boss FZ-2: a wide first column for the three-way mode switch, then the
    four panel knobs plus Mix as standard slider columns. The knobs read
    0.0-10.0 like the pedal's own markings even though they are stored
    0..100 - see BossFZ2.pas. }
  FZ2ModeColWidth = 96;
  FZ2ColCount = 5;
  FZ2ColWidth = 54;
  FZ2ColGap = 6;
  FZ2LeftMargin = 8;

implementation

uses
  AudioEngine;

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

constructor TTunerDisplay.CreateFor(AOwner: TComponent; AParent: TWinControl;
  ATarget, AEffectIndex: Integer);
begin
  inherited Create(AOwner);
  FTarget := ATarget;
  FEffectIndex := AEffectIndex;
  FFreqHz := 0;
  Parent := AParent;
  { this repaints several times a second forever, so it has to be
    double-buffered - an undrawn FillRect flash at that rate is very visible
    on X11. Color matches the face so a resize/erase can't flash grey either. }
  DoubleBuffered := True;
  Color := TunerFaceColor;

  { owned by Self, not by the form - so it dies with this control when
    MainForm.RebuildEffectWidgets frees the widget tree, rather than
    outliving it and firing at a freed canvas }
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 80; { ~12 refreshes a second; the detector itself only
    produces a new reading about 17 times a second, so there is nothing to
    gain from polling faster }
  FTimer.OnTimer := @PollTimerTimer;
  FTimer.Enabled := True;
end;

procedure TTunerDisplay.PollTimerTimer(Sender: TObject);
var
  NewFreq: Single;
begin
  NewFreq := AudioEngineTunerPitchHz(FTarget, FEffectIndex);
  { only repaint on a real change - a held note settles to a steady reading
    and there is no reason to keep redrawing it }
  if Abs(NewFreq - FFreqHz) < 0.01 then
    Exit;
  FFreqHz := NewFreq;
  Invalidate;
end;

{ Draws up to three dots marching away from the note, ADirection -1 for the
  flat side and +1 for the sharp side. The lit ones are always the INNERMOST
  ones, so the trail grows outward from the note as the pitch drifts further
  off; the unlit remainder stays drawn but dim, to keep the face from
  changing shape every reading. }
procedure TTunerDisplay.DrawDots(ACount, ADirection, ACenterX, ACenterY: Integer;
  AColor: TColor);
var
  i, x, r: Integer;
begin
  r := Px(TunerDotRadius);
  Canvas.Pen.Style := psClear;
  for i := 0 to 2 do
  begin
    x := ACenterX + ADirection * Px(TunerDotInset + i * TunerDotSpacing);
    if i < ACount then
      Canvas.Brush.Color := AColor
    else
      Canvas.Brush.Color := TunerDimColor;
    Canvas.Ellipse(x - r, ACenterY - r, x + r, ACenterY + r);
  end;
  Canvas.Pen.Style := psSolid;
end;

procedure TTunerDisplay.Paint;
var
  MidiNote, Dots, FlatDots, SharpDots, CenterX, CenterY, TextW: Integer;
  Cents: Single;
  NoteText, CentsText: string;
  NoteColor: TColor;
  HaveNote: Boolean;
begin
  Canvas.Brush.Color := TunerFaceColor;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(Rect(0, 0, Width, Height));
  Canvas.Pen.Color := clBlack;
  Canvas.Brush.Style := bsClear;
  Canvas.Rectangle(0, 0, Width, Height);
  Canvas.Brush.Style := bsSolid;

  HaveNote := Effects.TunerNoteFromFreq(FFreqHz, MidiNote, Cents);
  CenterX := Width div 2;
  CenterY := Height div 2 - Px(6);

  if not HaveNote then
  begin
    { idle face: the dots stay put, dim, so the readout doesn't visibly
      rearrange itself the moment a note arrives }
    NoteText := '--';
    NoteColor := TunerDimColor;
    Dots := 0;
    Cents := 0;
  end
  else
  begin
    NoteText := Effects.TunerNoteNames[MidiNote mod 12] +
      IntToStr(MidiNote div 12 - 1);
    Dots := Effects.TunerDotCount(Cents);
    if Dots = 0 then
      NoteColor := TunerInTuneColor
    else
      NoteColor := TunerOffPitchColor;
  end;

  Canvas.Font.Height := -Px(TunerNoteFontHeight);
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := NoteColor;
  Canvas.Brush.Style := bsClear;
  TextW := Canvas.TextWidth(NoteText);
  Canvas.TextOut(CenterX - TextW div 2,
    CenterY - Canvas.TextHeight(NoteText) div 2, NoteText);
  Canvas.Brush.Style := bsSolid;

  { the dots only light on the side the pitch has drifted TOWARDS: flat
    (below the note) reads left, sharp reads right. Both sides are always
    drawn, unlit ones dim, so the face keeps a fixed shape. }
  if Cents < 0 then
    FlatDots := Dots
  else
    FlatDots := 0;
  if Cents > 0 then
    SharpDots := Dots
  else
    SharpDots := 0;
  { the dots hang off fixed offsets from the centre of the face rather than
    off this particular reading's text width, so they don't slide in and out
    as the note name changes between three and four characters }
  DrawDots(FlatDots, -1, CenterX, CenterY, NoteColor);
  DrawDots(SharpDots, 1, CenterX, CenterY, NoteColor);

  Canvas.Font.Height := -Px(11);
  Canvas.Font.Style := [];
  Canvas.Font.Color := TunerCentsColor;
  Canvas.Brush.Style := bsClear;
  if not HaveNote then
    CentsText := 'no pitch'
  else if Round(Cents) > 0 then
    { explicit sign, so the number agrees with the side the dots lit on }
    CentsText := Format('+%d cents   %.1f Hz', [Round(Cents), FFreqHz])
  else
    CentsText := Format('%d cents   %.1f Hz', [Round(Cents), FFreqHz]);
  TextW := Canvas.TextWidth(CentsText);
  Canvas.TextOut(CenterX - TextW div 2, Height - Px(18), CentsText);
  Canvas.Brush.Style := bsSolid;
end;

function TEffectWidget.EffectPtr: PEffect;
var
  SendIndex: Integer;
begin
  SendIndex := Project.BusToSendIndex(FTarget);
  if SendIndex >= 0 then
    Result := @Project.SendEffects[SendIndex][FEffectIndex]
  else if FTarget = Project.BusMaster then
    Result := @Project.MasterEffects[FEffectIndex]
  else
    Result := @Project.TrackEffects[FTarget][FEffectIndex];
end;

constructor TEffectWidget.CreateFor(AOwner: TComponent; AParent: TWinControl;
  ATarget, AEffectIndex: Integer; AOnRackChanged: TEffectRackChangedEvent);
var
  DeleteButton: TButton;
  TitleLabel: TLabel;
  Kind: Integer;
begin
  inherited Create(AOwner);
  FTarget := ATarget;
  FEffectIndex := AEffectIndex;
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
    Effects.ekTuner: TitleLabel.Caption := 'Tuner';
    Effects.ekOverdrive: TitleLabel.Caption := 'Overdrive';
    Effects.ekQuadraverbReverb: TitleLabel.Caption := 'QuadraVerb Reverb';
    Effects.ekQuadraverbDelay: TitleLabel.Caption := 'QuadraVerb Delay';
    Effects.ekExciter422A: TitleLabel.Caption := 'Exciter - 422A';
    Effects.ekCompressor3630: TitleLabel.Caption := 'Compressor - 3630';
    Effects.ekFuzzFZ2: TitleLabel.Caption := 'Fuzz - FZ-2';
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
        Width := Px(SliderColMargin +
          BandpassColCount * (SliderColWidth + SliderColGap) + SliderColMargin);
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
        Width := Px(SliderColMargin +
          LimiterColCount * (SliderColWidth + SliderColGap) + SliderColMargin);
        DeleteButton.Left := Width - Px(28);
        BuildLimiter;
      end;
    Effects.ekChorus:
      begin
        Width := Px(SliderColMargin +
          ChorusColCount * (SliderColWidth + SliderColGap) + SliderColMargin);
        DeleteButton.Left := Width - Px(28);
        BuildChorus;
      end;
    Effects.ekReverb:
      begin
        Width := Px(SliderColMargin + ReverbTypeColWidth + SliderColGap +
          ReverbColCount * (SliderColWidth + SliderColGap) + SliderColMargin);
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
    Effects.ekTuner:
      begin
        Width := Px(TunerWidgetWidth);
        DeleteButton.Left := Width - Px(28);
        BuildTuner;
      end;
    Effects.ekOverdrive:
      begin
        Width := Px(OverdriveLeftMargin + OverdriveColCount * (OverdriveColWidth + OverdriveColGap) + OverdriveLeftMargin);
        DeleteButton.Left := Width - Px(28);
        BuildOverdrive;
      end;
    Effects.ekQuadraverbReverb:
      begin
        Width := Px(QVRLeftMargin + QVRTypeColWidth + QVRColGap +
          QVRColCount * (QVRColWidth + QVRColGap) + QVRLeftMargin);
        DeleteButton.Left := Width - Px(28);
        BuildQuadraverbReverb;
      end;
    Effects.ekQuadraverbDelay:
      begin
        Width := Px(QVDLeftMargin + QVDTypeColWidth + QVDColGap +
          QVDColCount * (QVDColWidth + QVDColGap) + QVDLeftMargin);
        DeleteButton.Left := Width - Px(28);
        BuildQuadraverbDelay;
      end;
    Effects.ekExciter422A:
      begin
        Width := Px(BBELeftMargin + BBEColCount * (BBEColWidth + BBEColGap) +
          BBELeftMargin);
        DeleteButton.Left := Width - Px(28);
        BuildExciter422A;
      end;
    Effects.ekCompressor3630:
      begin
        Width := Px(C36LeftMargin + C36SwitchColWidth + C36ColGap +
          C36ColCount * (C36ColWidth + C36ColGap) + C36LeftMargin);
        DeleteButton.Left := Width - Px(28);
        BuildCompressor3630;
      end;
    Effects.ekFuzzFZ2:
      begin
        Width := Px(FZ2LeftMargin + FZ2ModeColWidth + FZ2ColGap +
          FZ2ColCount * (FZ2ColWidth + FZ2ColGap) + FZ2LeftMargin);
        DeleteButton.Left := Width - Px(28);
        BuildFuzzFZ2;
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

{ Compact enough for a 54px column: "480Hz" below 1kHz, "12.0k" above, where
  the plain "12000 Hz" of the old full-width row would overhang into the
  neighbouring column's readout. }
function BandpassFreqText(AFreqHz: Single): string;
begin
  if AFreqHz >= 1000 then
    Result := Format('%.1fk', [AFreqHz / 1000])
  else
    Result := Format('%dHz', [Round(AFreqHz)]);
end;

procedure TEffectWidget.BuildBandpass;
var
  Col2: Integer;
begin
  { two standard columns - see the BandpassColCount comment for why this is
    no longer the stacked-row layout its Lowpass/Highpass siblings use }
  Col2 := SliderColMargin + SliderColWidth + SliderColGap;

  FBPSlider := AddSliderColumn(SliderColMargin, 'Freq', 0, 100,
    FreqToLogSlider(EffectPtr^.BandpassFreqHz), @BPSliderChange,
    'Center frequency', FBPValueLabel);
  FBPValueLabel.Caption := BandpassFreqText(EffectPtr^.BandpassFreqHz);

  FBPQSlider := AddSliderColumn(Col2, 'Q', 0, 100,
    Round(EffectPtr^.BandpassQ * 20), @BPQSliderChange, 'Bandwidth (Q)',
    FBPQValueLabel);
  FBPQValueLabel.Caption := Format('%.2f', [EffectPtr^.BandpassQ]);
end;

procedure TEffectWidget.BuildEQ4;
var
  b, bx: Integer;
  FreqRowLabel, GainRowLabel: TLabel;
begin
  { logical top-to-bottom flow: a labeled row of frequency inputs, then a
    labeled row of vertical gain sliders directly below their own band.

    Both rows sit on the same rhythm the column layouts use (caption at 30,
    control at 48) - see AddSliderColumn. The gain row's caption used to be
    at 108 with its sliders starting at 114, and a GTK trackbar draws its
    own position number INSIDE its top edge, so those numbers printed
    straight through the "Gain (dB)" caption. Six pixels was never a gap;
    the caption needs a whole row to itself. }
  FreqRowLabel := TLabel.Create(Owner);
  FreqRowLabel.Parent := Self;
  FreqRowLabel.Left := Px(EQLeftMargin);
  FreqRowLabel.Top := Px(30);
  FreqRowLabel.Caption := 'Freq (Hz)';

  GainRowLabel := TLabel.Create(Owner);
  GainRowLabel.Parent := Self;
  GainRowLabel.Left := Px(EQLeftMargin);
  GainRowLabel.Top := Px(EQGainRowTop - 18);
  GainRowLabel.Caption := 'Gain (dB)';

  for b := 0 to Effects.MaxEQBands - 1 do
  begin
    bx := EQLeftMargin + b * (EQBandWidth + EQBandGap);

    FEQFreqEdit[b] := TEdit.Create(Owner);
    FEQFreqEdit[b].Parent := Self;
    FEQFreqEdit[b].Left := Px(bx);
    FEQFreqEdit[b].Top := Px(48);
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
    { too little travel and GTK renders a vertical TTrackBar as barely more
      than its own round thumb (and its position number eats the top ~18px
      of whatever height it is given), so this takes every pixel between the
      Gain caption and the bottom margin }
    FEQGainSlider[b].Top := Px(EQGainRowTop);
    FEQGainSlider[b].Width := Px(EQBandWidth);
    FEQGainSlider[b].Height := Px(WidgetHeight - EQGainRowTop - 8);
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
begin
  FLimiterThresholdSlider := AddSliderColumn(SliderColMargin, 'Ceiling',
    LimiterMinThresholdDb, LimiterMaxThresholdDb,
    Round(EffectPtr^.LimiterThresholdDb), @LimiterThresholdSliderChange,
    'Ceiling (dB)', FLimiterThresholdValueLabel);
  FLimiterThresholdValueLabel.Caption :=
    Format('%d dB', [Round(EffectPtr^.LimiterThresholdDb)]);

  FLimiterReleaseSlider := AddSliderColumn(
    SliderColMargin + SliderColWidth + SliderColGap, 'Release',
    LimiterMinReleaseMs, LimiterMaxReleaseMs,
    Round(EffectPtr^.LimiterReleaseMs), @LimiterReleaseSliderChange,
    'Release (ms)', FLimiterReleaseValueLabel);
  FLimiterReleaseValueLabel.Caption :=
    Format('%d ms', [Round(EffectPtr^.LimiterReleaseMs)]);
end;

procedure TEffectWidget.BuildChorus;
begin
  FChorusRateSlider := AddSliderColumn(SliderColMargin, 'Rate',
    ChorusMinRateX100, ChorusMaxRateX100, Round(EffectPtr^.ChorusRateHz * 100),
    @ChorusRateSliderChange, 'LFO rate (Hz)', FChorusRateValueLabel);
  FChorusRateValueLabel.Caption := Format('%.2fHz', [EffectPtr^.ChorusRateHz]);

  FChorusDepthSlider := AddSliderColumn(
    SliderColMargin + SliderColWidth + SliderColGap, 'Depth',
    ChorusMinDepthPercent, ChorusMaxDepthPercent,
    Round(EffectPtr^.ChorusDepthPercent), @ChorusDepthSliderChange,
    'Modulation depth (%)', FChorusDepthValueLabel);
  FChorusDepthValueLabel.Caption :=
    Format('%d%%', [Round(EffectPtr^.ChorusDepthPercent)]);
end;

procedure TEffectWidget.BuildReverb;
var
  Lbl: TLabel;
  p: Integer;
begin
  { wide dropdown column then one standard slider column, same shape as
    Sidechain/QuadraVerb Reverb }
  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(SliderColMargin);
  Lbl.Top := Px(30);
  Lbl.Caption := 'Type';

  FReverbPresetCombo := TComboBox.Create(Owner);
  FReverbPresetCombo.Parent := Self;
  FReverbPresetCombo.Style := csDropDownList;
  FReverbPresetCombo.Left := Px(SliderColMargin);
  FReverbPresetCombo.Top := Px(48);
  FReverbPresetCombo.Width := Px(ReverbTypeColWidth);
  for p := 0 to Effects.ReverbPresetCount - 1 do
    FReverbPresetCombo.Items.Add(Effects.ReverbPresetNames[p]);
  FReverbPresetCombo.ItemIndex := EffectPtr^.ReverbPreset;
  FReverbPresetCombo.OnChange := @ReverbPresetChange;

  FReverbMixSlider := AddSliderColumn(
    SliderColMargin + ReverbTypeColWidth + SliderColGap, 'Dry/Wet',
    ReverbMinMixPercent, ReverbMaxMixPercent, Round(EffectPtr^.ReverbMixPercent),
    @ReverbMixSliderChange, 'Wet mix (%)', FReverbMixValueLabel);
  FReverbMixValueLabel.Caption :=
    Format('%d%%', [Round(EffectPtr^.ReverbMixPercent)]);
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

procedure TEffectWidget.BuildTuner;
var
  Lbl: TLabel;
begin
  { no controls at all - a tuner has nothing to set. The whole box is the
    readout face plus one line saying what it does (and doesn't) do. }
  FTunerDisplay := TTunerDisplay.CreateFor(Self, Self, FTarget, FEffectIndex);
  FTunerDisplay.Left := Px(TunerFaceMargin);
  FTunerDisplay.Top := Px(TunerFaceTop);
  FTunerDisplay.Width := Width - 2 * Px(TunerFaceMargin);
  FTunerDisplay.Height := Px(WidgetHeight - TunerFaceTop - TunerFaceBottomGap);

  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(TunerFaceMargin);
  Lbl.Top := Px(WidgetHeight - 20);
  Lbl.Caption := 'Listens only - audio unchanged';
end;

procedure TEffectWidget.BuildOverdrive;
var
  Lbl1, Lbl2, Lbl3, Lbl4, Lbl5: TLabel;
  Col1, Col2, Col3, Col4, Col5: Integer;
begin
  { horizontal, EQ4-style column layout - see BuildFlanger's comment, same
    idea, 5 columns }
  Col1 := OverdriveLeftMargin;
  Col2 := Col1 + OverdriveColWidth + OverdriveColGap;
  Col3 := Col2 + OverdriveColWidth + OverdriveColGap;
  Col4 := Col3 + OverdriveColWidth + OverdriveColGap;
  Col5 := Col4 + OverdriveColWidth + OverdriveColGap;

  Lbl1 := TLabel.Create(Owner);
  Lbl1.Parent := Self;
  Lbl1.Left := Px(Col1);
  Lbl1.Top := Px(30);
  Lbl1.Caption := 'Freq';

  FOverdriveFreqSlider := TTrackBar.Create(Owner);
  FOverdriveFreqSlider.Parent := Self;
  FOverdriveFreqSlider.Orientation := trVertical;
  FOverdriveFreqSlider.Left := Px(Col1);
  FOverdriveFreqSlider.Top := Px(48);
  FOverdriveFreqSlider.Width := Px(OverdriveColWidth);
  FOverdriveFreqSlider.Height := Px(WidgetHeight - 48 - 24);
  FOverdriveFreqSlider.Reversed := True;
  FOverdriveFreqSlider.Min := 0;
  FOverdriveFreqSlider.Max := 100;
  FOverdriveFreqSlider.Position := FreqToLogSlider(EffectPtr^.OverdriveFreqHz);
  FOverdriveFreqSlider.ShowHint := True;
  FOverdriveFreqSlider.Hint := 'Which band gets driven hardest';
  FOverdriveFreqSlider.OnChange := @OverdriveFreqSliderChange;

  FOverdriveFreqValueLabel := TLabel.Create(Owner);
  FOverdriveFreqValueLabel.Parent := Self;
  FOverdriveFreqValueLabel.Left := Px(Col1);
  FOverdriveFreqValueLabel.Top := Px(WidgetHeight - 22);
  FOverdriveFreqValueLabel.Caption := Format('%dHz', [Round(EffectPtr^.OverdriveFreqHz)]);

  Lbl2 := TLabel.Create(Owner);
  Lbl2.Parent := Self;
  Lbl2.Left := Px(Col2);
  Lbl2.Top := Px(30);
  Lbl2.Caption := 'Q';

  FOverdriveQSlider := TTrackBar.Create(Owner);
  FOverdriveQSlider.Parent := Self;
  FOverdriveQSlider.Orientation := trVertical;
  FOverdriveQSlider.Left := Px(Col2);
  FOverdriveQSlider.Top := Px(48);
  FOverdriveQSlider.Width := Px(OverdriveColWidth);
  FOverdriveQSlider.Height := Px(WidgetHeight - 48 - 24);
  FOverdriveQSlider.Reversed := True;
  FOverdriveQSlider.Min := OverdriveMinQx20;
  FOverdriveQSlider.Max := OverdriveMaxQx20;
  FOverdriveQSlider.Position := Round(EffectPtr^.OverdriveQ * 20);
  FOverdriveQSlider.ShowHint := True;
  FOverdriveQSlider.Hint := 'How narrow that band is';
  FOverdriveQSlider.OnChange := @OverdriveQSliderChange;

  FOverdriveQValueLabel := TLabel.Create(Owner);
  FOverdriveQValueLabel.Parent := Self;
  FOverdriveQValueLabel.Left := Px(Col2);
  FOverdriveQValueLabel.Top := Px(WidgetHeight - 22);
  FOverdriveQValueLabel.Caption := Format('%.2f', [EffectPtr^.OverdriveQ]);

  Lbl3 := TLabel.Create(Owner);
  Lbl3.Parent := Self;
  Lbl3.Left := Px(Col3);
  Lbl3.Top := Px(30);
  Lbl3.Caption := 'Drive';

  FOverdriveDriveSlider := TTrackBar.Create(Owner);
  FOverdriveDriveSlider.Parent := Self;
  FOverdriveDriveSlider.Orientation := trVertical;
  FOverdriveDriveSlider.Left := Px(Col3);
  FOverdriveDriveSlider.Top := Px(48);
  FOverdriveDriveSlider.Width := Px(OverdriveColWidth);
  FOverdriveDriveSlider.Height := Px(WidgetHeight - 48 - 24);
  FOverdriveDriveSlider.Reversed := True;
  FOverdriveDriveSlider.Min := OverdriveMinDrivePercent;
  FOverdriveDriveSlider.Max := OverdriveMaxDrivePercent;
  FOverdriveDriveSlider.Position := Round(EffectPtr^.OverdriveDrivePercent);
  FOverdriveDriveSlider.OnChange := @OverdriveDriveSliderChange;

  FOverdriveDriveValueLabel := TLabel.Create(Owner);
  FOverdriveDriveValueLabel.Parent := Self;
  FOverdriveDriveValueLabel.Left := Px(Col3);
  FOverdriveDriveValueLabel.Top := Px(WidgetHeight - 22);
  FOverdriveDriveValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.OverdriveDrivePercent)]);

  Lbl4 := TLabel.Create(Owner);
  Lbl4.Parent := Self;
  Lbl4.Left := Px(Col4);
  Lbl4.Top := Px(30);
  Lbl4.Caption := 'Color';

  FOverdriveColorSlider := TTrackBar.Create(Owner);
  FOverdriveColorSlider.Parent := Self;
  FOverdriveColorSlider.Orientation := trVertical;
  FOverdriveColorSlider.Left := Px(Col4);
  FOverdriveColorSlider.Top := Px(48);
  FOverdriveColorSlider.Width := Px(OverdriveColWidth);
  FOverdriveColorSlider.Height := Px(WidgetHeight - 48 - 24);
  FOverdriveColorSlider.Reversed := True;
  FOverdriveColorSlider.Min := OverdriveMinColorPercent;
  FOverdriveColorSlider.Max := OverdriveMaxColorPercent;
  FOverdriveColorSlider.Position := Round(EffectPtr^.OverdriveColorPercent);
  FOverdriveColorSlider.ShowHint := True;
  FOverdriveColorSlider.Hint := '0% = warm soft knee, 100% = hard crunch';
  FOverdriveColorSlider.OnChange := @OverdriveColorSliderChange;

  FOverdriveColorValueLabel := TLabel.Create(Owner);
  FOverdriveColorValueLabel.Parent := Self;
  FOverdriveColorValueLabel.Left := Px(Col4);
  FOverdriveColorValueLabel.Top := Px(WidgetHeight - 22);
  FOverdriveColorValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.OverdriveColorPercent)]);

  Lbl5 := TLabel.Create(Owner);
  Lbl5.Parent := Self;
  Lbl5.Left := Px(Col5);
  Lbl5.Top := Px(30);
  Lbl5.Caption := 'Mix';

  FOverdriveMixSlider := TTrackBar.Create(Owner);
  FOverdriveMixSlider.Parent := Self;
  FOverdriveMixSlider.Orientation := trVertical;
  FOverdriveMixSlider.Left := Px(Col5);
  FOverdriveMixSlider.Top := Px(48);
  FOverdriveMixSlider.Width := Px(OverdriveColWidth);
  FOverdriveMixSlider.Height := Px(WidgetHeight - 48 - 24);
  FOverdriveMixSlider.Reversed := True;
  FOverdriveMixSlider.Min := OverdriveMinMixPercent;
  FOverdriveMixSlider.Max := OverdriveMaxMixPercent;
  FOverdriveMixSlider.Position := Round(EffectPtr^.OverdriveMixPercent);
  FOverdriveMixSlider.OnChange := @OverdriveMixSliderChange;

  FOverdriveMixValueLabel := TLabel.Create(Owner);
  FOverdriveMixValueLabel.Parent := Self;
  FOverdriveMixValueLabel.Left := Px(Col5);
  FOverdriveMixValueLabel.Top := Px(WidgetHeight - 22);
  FOverdriveMixValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.OverdriveMixPercent)]);
end;

{ Shared shape for every QuadraVerb slider column: caption on top, vertical
  slider filling the middle, live value readout at the bottom - the same
  EQ4-style column the rest of the rack uses, just built once here instead
  of copied eight times. }
function TEffectWidget.AddSliderColumn(ALeft: Integer; const ACaption: string;
  AMin, AMax, APosition: Integer; AOnChange: TNotifyEvent;
  const AHint: string; out AValueLabel: TLabel): TTrackBar;
var
  Lbl: TLabel;
begin
  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(ALeft);
  Lbl.Top := Px(30);
  Lbl.Caption := ACaption;

  Result := TTrackBar.Create(Owner);
  Result.Parent := Self;
  Result.Orientation := trVertical;
  Result.Left := Px(ALeft);
  Result.Top := Px(48);
  Result.Width := Px(SliderColWidth);
  Result.Height := Px(WidgetHeight - 48 - 24);
  Result.Reversed := True;
  Result.Min := AMin;
  Result.Max := AMax;
  if APosition < AMin then APosition := AMin;
  if APosition > AMax then APosition := AMax;
  Result.Position := APosition;
  if AHint <> '' then
  begin
    Result.ShowHint := True;
    Result.Hint := AHint;
  end;
  Result.OnChange := AOnChange;

  AValueLabel := TLabel.Create(Owner);
  AValueLabel.Parent := Self;
  AValueLabel.Left := Px(ALeft);
  AValueLabel.Top := Px(WidgetHeight - 22);
end;

{ "PRE 40" / "00" / "PST 70", matching how the original's own Predelay Mix
  page reads (PRE <-99 ... 00 ... 99-> POST). }
function QVPredelayMixText(AValue: Integer): string;
begin
  if AValue < 0 then
    Result := Format('PRE%d', [-AValue])
  else if AValue > 0 then
    Result := Format('PST%d', [AValue])
  else
    Result := '00';
end;

procedure TEffectWidget.BuildQuadraverbReverb;
var
  Lbl: TLabel;
  t, Col, ColStep: Integer;
begin
  ColStep := QVRColWidth + QVRColGap;

  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(QVRLeftMargin);
  Lbl.Top := Px(30);
  Lbl.Caption := 'Reverb type';

  FQVRTypeCombo := TComboBox.Create(Owner);
  FQVRTypeCombo.Parent := Self;
  FQVRTypeCombo.Style := csDropDownList;
  FQVRTypeCombo.Left := Px(QVRLeftMargin);
  FQVRTypeCombo.Top := Px(48);
  FQVRTypeCombo.Width := Px(QVRTypeColWidth);
  for t := 0 to Quadraverb.QVReverbTypeCount - 1 do
    FQVRTypeCombo.Items.Add(Quadraverb.QVReverbTypeNames[t]);
  if (EffectPtr^.QVReverbType >= 0) and
    (EffectPtr^.QVReverbType < Quadraverb.QVReverbTypeCount) then
    FQVRTypeCombo.ItemIndex := EffectPtr^.QVReverbType
  else
    FQVRTypeCombo.ItemIndex := Quadraverb.QVReverbHall;
  FQVRTypeCombo.OnChange := @QVRTypeChange;

  { the two pages whose meaning depends on the type get a note under the
    dropdown rather than being silently different - the real unit relabels
    Decay to Reverse Time and drops the Density page on Hall }
  FQVRDecayCaption := TLabel.Create(Owner);
  FQVRDecayCaption.Parent := Self;
  FQVRDecayCaption.Left := Px(QVRLeftMargin);
  FQVRDecayCaption.Top := Px(84);
  FQVRDecayCaption.Width := Px(QVRTypeColWidth);
  FQVRDecayCaption.WordWrap := True;
  FQVRDecayCaption.AutoSize := False;
  FQVRDecayCaption.Height := Px(WidgetHeight - 84 - 6);

  Col := QVRLeftMargin + QVRTypeColWidth + QVRColGap;
  FQVRPredelaySlider := AddSliderColumn(Col, 'Predly',
    Quadraverb.QVPredelayMinMs, Quadraverb.QVPredelayMaxMs,
    Round(EffectPtr^.QVReverbPredelayMs), @QVRPredelaySliderChange,
    'Time before the first reflections (1-140ms)', FQVRPredelayValueLabel);
  FQVRPredelayValueLabel.Caption := Format('%dms', [Round(EffectPtr^.QVReverbPredelayMs)]);

  Inc(Col, ColStep);
  FQVRPredelayMixSlider := AddSliderColumn(Col, 'Pre/Pst',
    Quadraverb.QVPredelayMixMin, Quadraverb.QVPredelayMixMax,
    Round(EffectPtr^.QVReverbPredelayMix), @QVRPredelayMixSliderChange,
    'How much un-predelayed signal also feeds the tank', FQVRPredelayMixValueLabel);
  FQVRPredelayMixValueLabel.Caption := QVPredelayMixText(Round(EffectPtr^.QVReverbPredelayMix));

  Inc(Col, ColStep);
  FQVRDecaySlider := AddSliderColumn(Col, 'Decay',
    Quadraverb.QVDecayMin, Quadraverb.QVDecayMax,
    Round(EffectPtr^.QVReverbDecay), @QVRDecaySliderChange,
    'Length of the tail (Reverse Time when type is Reverse)', FQVRDecayValueLabel);
  FQVRDecayValueLabel.Caption := Format('%d', [Round(EffectPtr^.QVReverbDecay)]);

  Inc(Col, ColStep);
  FQVRDiffusionSlider := AddSliderColumn(Col, 'Diff',
    Quadraverb.QVDiffusionMin, Quadraverb.QVDiffusionMax,
    Round(EffectPtr^.QVReverbDiffusion), @QVRDiffusionSliderChange,
    'Low = discrete echoes, high = smeared into a wash', FQVRDiffusionValueLabel);
  FQVRDiffusionValueLabel.Caption := Format('%d', [Round(EffectPtr^.QVReverbDiffusion)]);

  Inc(Col, ColStep);
  FQVRDensitySlider := AddSliderColumn(Col, 'Dens',
    Quadraverb.QVDensityMin, Quadraverb.QVDensityMax,
    Round(EffectPtr^.QVReverbDensity), @QVRDensitySliderChange,
    'Gap between the first reflection and the body (no effect on Hall)',
    FQVRDensityValueLabel);
  FQVRDensityValueLabel.Caption := Format('%d', [Round(EffectPtr^.QVReverbDensity)]);

  Inc(Col, ColStep);
  FQVRLowDecaySlider := AddSliderColumn(Col, 'LoDcy',
    Quadraverb.QVBandDecayMin, Quadraverb.QVBandDecayMax,
    Round(EffectPtr^.QVReverbLowDecay), @QVRLowDecaySliderChange,
    'Shortens the low end of the tail only (0 = full length)',
    FQVRLowDecayValueLabel);
  FQVRLowDecayValueLabel.Caption := Format('%d', [Round(EffectPtr^.QVReverbLowDecay)]);

  Inc(Col, ColStep);
  FQVRHighDecaySlider := AddSliderColumn(Col, 'HiDcy',
    Quadraverb.QVBandDecayMin, Quadraverb.QVBandDecayMax,
    Round(EffectPtr^.QVReverbHighDecay), @QVRHighDecaySliderChange,
    'Shortens the top of the tail only - pull it down for a dark wash',
    FQVRHighDecayValueLabel);
  FQVRHighDecayValueLabel.Caption := Format('%d', [Round(EffectPtr^.QVReverbHighDecay)]);

  Inc(Col, ColStep);
  FQVRMixSlider := AddSliderColumn(Col, 'Mix', 0, 100,
    Round(EffectPtr^.QVReverbMixPercent), @QVRMixSliderChange, '',
    FQVRMixValueLabel);
  FQVRMixValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.QVReverbMixPercent)]);

  QVRUpdateTypeDependentLabels;
end;

procedure TEffectWidget.BuildQuadraverbDelay;
var
  Lbl: TLabel;
  t, Col, ColStep: Integer;
begin
  ColStep := QVDColWidth + QVDColGap;

  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(QVDLeftMargin);
  Lbl.Top := Px(30);
  Lbl.Caption := 'Delay type';

  FQVDTypeCombo := TComboBox.Create(Owner);
  FQVDTypeCombo.Parent := Self;
  FQVDTypeCombo.Style := csDropDownList;
  FQVDTypeCombo.Left := Px(QVDLeftMargin);
  FQVDTypeCombo.Top := Px(48);
  FQVDTypeCombo.Width := Px(QVDTypeColWidth);
  for t := 0 to Quadraverb.QVDelayTypeCount - 1 do
    FQVDTypeCombo.Items.Add(Quadraverb.QVDelayTypeNames[t]);
  if (EffectPtr^.QVDelayType >= 0) and
    (EffectPtr^.QVDelayType < Quadraverb.QVDelayTypeCount) then
    FQVDTypeCombo.ItemIndex := EffectPtr^.QVDelayType
  else
    FQVDTypeCombo.ItemIndex := Quadraverb.QVDelayPingPong;
  FQVDTypeCombo.OnChange := @QVDTypeChange;

  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(QVDLeftMargin);
  Lbl.Top := Px(86);
  Lbl.Caption := 'Time L (ms)';

  FQVDTimeLEdit := TEdit.Create(Owner);
  FQVDTimeLEdit.Parent := Self;
  FQVDTimeLEdit.Left := Px(QVDLeftMargin);
  FQVDTimeLEdit.Top := Px(104);
  FQVDTimeLEdit.Width := Px(QVDTypeColWidth);
  FQVDTimeLEdit.Height := Px(26);
  FQVDTimeLEdit.Tag := 0;
  FQVDTimeLEdit.Text := IntToStr(Round(EffectPtr^.QVDelayTimeLMs));
  FQVDTimeLEdit.OnEditingDone := @QVDTimeEditDone;

  FQVDTimeRCaption := TLabel.Create(Owner);
  FQVDTimeRCaption.Parent := Self;
  FQVDTimeRCaption.Left := Px(QVDLeftMargin);
  FQVDTimeRCaption.Top := Px(132);
  FQVDTimeRCaption.Caption := 'Time R (ms)';

  FQVDTimeREdit := TEdit.Create(Owner);
  FQVDTimeREdit.Parent := Self;
  FQVDTimeREdit.Left := Px(QVDLeftMargin);
  FQVDTimeREdit.Top := Px(150);
  FQVDTimeREdit.Width := Px(QVDTypeColWidth);
  FQVDTimeREdit.Height := Px(26);
  FQVDTimeREdit.Tag := 1;
  FQVDTimeREdit.Text := IntToStr(Round(EffectPtr^.QVDelayTimeRMs));
  FQVDTimeREdit.OnEditingDone := @QVDTimeEditDone;

  Col := QVDLeftMargin + QVDTypeColWidth + QVDColGap;
  FQVDFeedbackLSlider := AddSliderColumn(Col, 'Fdbk L', 0,
    Quadraverb.QVDelayFeedbackMax, Round(EffectPtr^.QVDelayFeedbackL),
    @QVDFeedbackLSliderChange, '', FQVDFeedbackLValueLabel);
  FQVDFeedbackLValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.QVDelayFeedbackL)]);

  Inc(Col, ColStep);
  FQVDFeedbackRSlider := AddSliderColumn(Col, 'Fdbk R', 0,
    Quadraverb.QVDelayFeedbackMax, Round(EffectPtr^.QVDelayFeedbackR),
    @QVDFeedbackRSliderChange, 'Stereo type only', FQVDFeedbackRValueLabel);
  FQVDFeedbackRValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.QVDelayFeedbackR)]);

  Inc(Col, ColStep);
  FQVDMixSlider := AddSliderColumn(Col, 'Mix', 0, 100,
    Round(EffectPtr^.QVDelayMixPercent), @QVDMixSliderChange, '',
    FQVDMixValueLabel);
  FQVDMixValueLabel.Caption := Format('%d%%', [Round(EffectPtr^.QVDelayMixPercent)]);

  QVDUpdateTypeDependentControls;
end;

procedure TEffectWidget.DeleteClick(Sender: TObject);
var
  SendIndex: Integer;
begin
  SendIndex := Project.BusToSendIndex(FTarget);
  if SendIndex >= 0 then
    Project.RemoveSendEffect(SendIndex, FEffectIndex)
  else if FTarget = Project.BusMaster then
    Project.RemoveMasterEffect(FEffectIndex)
  else
    Project.RemoveTrackEffect(FTarget, FEffectIndex);
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
  FBPValueLabel.Caption := BandpassFreqText(Freq);
end;

procedure TEffectWidget.BPQSliderChange(Sender: TObject);
var
  Q: Single;
begin
  Q := FBPQSlider.Position / 20;
  EffectPtr^.BandpassQ := Q;
  FBPQValueLabel.Caption := Format('%.2f', [Q]);
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
  { no space before the unit - the readout now sits in a 54px column }
  FChorusRateValueLabel.Caption := Format('%.2fHz', [RateHz]);
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
  FReverbMixValueLabel.Caption := Format('%d%%', [FReverbMixSlider.Position]);
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

procedure TEffectWidget.OverdriveFreqSliderChange(Sender: TObject);
var
  Freq: Single;
begin
  Freq := LogSliderToFreq(FOverdriveFreqSlider.Position);
  EffectPtr^.OverdriveFreqHz := Freq;
  FOverdriveFreqValueLabel.Caption := Format('%dHz', [Round(Freq)]);
end;

procedure TEffectWidget.OverdriveQSliderChange(Sender: TObject);
var
  Q: Single;
begin
  Q := FOverdriveQSlider.Position / 20;
  EffectPtr^.OverdriveQ := Q;
  FOverdriveQValueLabel.Caption := Format('%.2f', [Q]);
end;

procedure TEffectWidget.OverdriveDriveSliderChange(Sender: TObject);
begin
  EffectPtr^.OverdriveDrivePercent := FOverdriveDriveSlider.Position;
  FOverdriveDriveValueLabel.Caption := Format('%d%%', [FOverdriveDriveSlider.Position]);
end;

procedure TEffectWidget.OverdriveColorSliderChange(Sender: TObject);
begin
  EffectPtr^.OverdriveColorPercent := FOverdriveColorSlider.Position;
  FOverdriveColorValueLabel.Caption := Format('%d%%', [FOverdriveColorSlider.Position]);
end;

procedure TEffectWidget.OverdriveMixSliderChange(Sender: TObject);
begin
  EffectPtr^.OverdriveMixPercent := FOverdriveMixSlider.Position;
  FOverdriveMixValueLabel.Caption := Format('%d%% wet', [FOverdriveMixSlider.Position]);
end;

{ Keeps the note under the type dropdown honest about the two pages whose
  meaning the type changes, rather than leaving a control that silently
  means something else or silently does nothing. }
procedure TEffectWidget.QVRUpdateTypeDependentLabels;
begin
  case EffectPtr^.QVReverbType of
    Quadraverb.QVReverbReverse:
      FQVRDecayCaption.Caption := 'Decay sets Reverse Time: the swell ramps ' +
        'up over it, then cuts off.';
    Quadraverb.QVReverbHall:
      FQVRDecayCaption.Caption := 'Hall has no Density page on the original, ' +
        'so Dens does nothing here.';
  else
    FQVRDecayCaption.Caption := '';
  end;
end;

procedure TEffectWidget.QVRTypeChange(Sender: TObject);
begin
  EffectPtr^.QVReverbType := FQVRTypeCombo.ItemIndex;
  QVRUpdateTypeDependentLabels;
end;

procedure TEffectWidget.QVRPredelaySliderChange(Sender: TObject);
begin
  EffectPtr^.QVReverbPredelayMs := FQVRPredelaySlider.Position;
  FQVRPredelayValueLabel.Caption := Format('%dms', [FQVRPredelaySlider.Position]);
end;

procedure TEffectWidget.QVRPredelayMixSliderChange(Sender: TObject);
begin
  EffectPtr^.QVReverbPredelayMix := FQVRPredelayMixSlider.Position;
  FQVRPredelayMixValueLabel.Caption := QVPredelayMixText(FQVRPredelayMixSlider.Position);
end;

procedure TEffectWidget.QVRDecaySliderChange(Sender: TObject);
begin
  EffectPtr^.QVReverbDecay := FQVRDecaySlider.Position;
  FQVRDecayValueLabel.Caption := Format('%d', [FQVRDecaySlider.Position]);
end;

procedure TEffectWidget.QVRDiffusionSliderChange(Sender: TObject);
begin
  EffectPtr^.QVReverbDiffusion := FQVRDiffusionSlider.Position;
  FQVRDiffusionValueLabel.Caption := Format('%d', [FQVRDiffusionSlider.Position]);
end;

procedure TEffectWidget.QVRDensitySliderChange(Sender: TObject);
begin
  EffectPtr^.QVReverbDensity := FQVRDensitySlider.Position;
  FQVRDensityValueLabel.Caption := Format('%d', [FQVRDensitySlider.Position]);
end;

procedure TEffectWidget.QVRLowDecaySliderChange(Sender: TObject);
begin
  EffectPtr^.QVReverbLowDecay := FQVRLowDecaySlider.Position;
  FQVRLowDecayValueLabel.Caption := Format('%d', [FQVRLowDecaySlider.Position]);
end;

procedure TEffectWidget.QVRHighDecaySliderChange(Sender: TObject);
begin
  EffectPtr^.QVReverbHighDecay := FQVRHighDecaySlider.Position;
  FQVRHighDecayValueLabel.Caption := Format('%d', [FQVRHighDecaySlider.Position]);
end;

procedure TEffectWidget.QVRMixSliderChange(Sender: TObject);
begin
  EffectPtr^.QVReverbMixPercent := FQVRMixSlider.Position;
  FQVRMixValueLabel.Caption := Format('%d%% wet', [FQVRMixSlider.Position]);
end;

{ The right-hand Time and Feedback pages only exist in Stereo on the real
  unit, and the time ceiling halves outside Mono because Stereo/Ping-Pong
  have to fit two lines in the same memory. Both are reflected here. }
procedure TEffectWidget.QVDUpdateTypeDependentControls;
var
  Stereo: Boolean;
  MaxMs: Integer;
begin
  Stereo := EffectPtr^.QVDelayType = Quadraverb.QVDelayStereo;
  FQVDTimeRCaption.Enabled := Stereo;
  FQVDTimeREdit.Enabled := Stereo;
  FQVDFeedbackRSlider.Enabled := Stereo;
  FQVDFeedbackRValueLabel.Enabled := Stereo;

  MaxMs := Quadraverb.QVDelayMaxMs(EffectPtr^.QVDelayType);
  FQVDTimeLEdit.Hint := Format('1-%d ms', [MaxMs]);
  FQVDTimeLEdit.ShowHint := True;
  FQVDTimeREdit.Hint := FQVDTimeLEdit.Hint;
  FQVDTimeREdit.ShowHint := True;
  if EffectPtr^.QVDelayTimeLMs > MaxMs then
  begin
    EffectPtr^.QVDelayTimeLMs := MaxMs;
    FQVDTimeLEdit.Text := IntToStr(MaxMs);
  end;
  if EffectPtr^.QVDelayTimeRMs > MaxMs then
  begin
    EffectPtr^.QVDelayTimeRMs := MaxMs;
    FQVDTimeREdit.Text := IntToStr(MaxMs);
  end;
end;

procedure TEffectWidget.QVDTypeChange(Sender: TObject);
begin
  EffectPtr^.QVDelayType := FQVDTypeCombo.ItemIndex;
  QVDUpdateTypeDependentControls;
end;

procedure TEffectWidget.QVDTimeEditDone(Sender: TObject);
var
  Edit: TEdit;
  Value, MaxMs: Integer;
begin
  Edit := Sender as TEdit;
  MaxMs := Quadraverb.QVDelayMaxMs(EffectPtr^.QVDelayType);
  if not TryStrToInt(Trim(Edit.Text), Value) then
  begin
    if Edit.Tag = 0 then
      Value := Round(EffectPtr^.QVDelayTimeLMs)
    else
      Value := Round(EffectPtr^.QVDelayTimeRMs);
  end;
  if Value < 1 then Value := 1;
  if Value > MaxMs then Value := MaxMs;
  Edit.Text := IntToStr(Value);
  if Edit.Tag = 0 then
    EffectPtr^.QVDelayTimeLMs := Value
  else
    EffectPtr^.QVDelayTimeRMs := Value;
end;

procedure TEffectWidget.QVDFeedbackLSliderChange(Sender: TObject);
begin
  EffectPtr^.QVDelayFeedbackL := FQVDFeedbackLSlider.Position;
  FQVDFeedbackLValueLabel.Caption := Format('%d%%', [FQVDFeedbackLSlider.Position]);
end;

procedure TEffectWidget.QVDFeedbackRSliderChange(Sender: TObject);
begin
  EffectPtr^.QVDelayFeedbackR := FQVDFeedbackRSlider.Position;
  FQVDFeedbackRValueLabel.Caption := Format('%d%%', [FQVDFeedbackRSlider.Position]);
end;

procedure TEffectWidget.QVDMixSliderChange(Sender: TObject);
begin
  EffectPtr^.QVDelayMixPercent := FQVDMixSlider.Position;
  FQVDMixValueLabel.Caption := Format('%d%% wet', [FQVDMixSlider.Position]);
end;

{ "+4dB" / "0dB" / "-7dB" - the 422A's Lo Contour is calibrated in dB at
  50Hz and is asymmetric (-12 to +10), so the sign has to show. }
function BBELoContourText(AValue: Integer): string;
begin
  if AValue > 0 then
    Result := Format('+%ddB', [AValue])
  else
    Result := Format('%ddB', [AValue]);
end;

procedure TEffectWidget.BuildExciter422A;
var
  Col, ColStep: Integer;
begin
  ColStep := BBEColWidth + BBEColGap;
  Col := BBELeftMargin;

  FBBELoContourSlider := AddSliderColumn(Col, 'LoCntr',
    BBE422A.BBELoContourMinDb, BBE422A.BBELoContourMaxDb,
    Round(EffectPtr^.BBELoContourDb), @BBELoContourSliderChange,
    'Phase-compensated bump at 50Hz, inside the delayed low band',
    FBBELoContourValueLabel);
  FBBELoContourValueLabel.Caption :=
    BBELoContourText(Round(EffectPtr^.BBELoContourDb));

  Inc(Col, ColStep);
  FBBEDefinitionSlider := AddSliderColumn(Col, 'Defin',
    BBE422A.BBEDefinitionMin, BBE422A.BBEDefinitionMax,
    Round(EffectPtr^.BBEDefinition), @BBEDefinitionSliderChange,
    'How hard the VCA drags the high band towards the balance the box wants',
    FBBEDefinitionValueLabel);
  FBBEDefinitionValueLabel.Caption := Format('%d', [Round(EffectPtr^.BBEDefinition)]);

  Inc(Col, ColStep);
  FBBEMixSlider := AddSliderColumn(Col, 'Mix', 0, 100,
    Round(EffectPtr^.BBEMixPercent), @BBEMixSliderChange,
    'Under 100% combs the low end - the wet path is 2.5ms late down there',
    FBBEMixValueLabel);
  FBBEMixValueLabel.Caption := Format('%d%% wet', [Round(EffectPtr^.BBEMixPercent)]);
end;

procedure TEffectWidget.BBELoContourSliderChange(Sender: TObject);
begin
  EffectPtr^.BBELoContourDb := FBBELoContourSlider.Position;
  FBBELoContourValueLabel.Caption := BBELoContourText(FBBELoContourSlider.Position);
end;

procedure TEffectWidget.BBEDefinitionSliderChange(Sender: TObject);
begin
  EffectPtr^.BBEDefinition := FBBEDefinitionSlider.Position;
  FBBEDefinitionValueLabel.Caption := Format('%d', [FBBEDefinitionSlider.Position]);
end;

procedure TEffectWidget.BBEMixSliderChange(Sender: TObject);
begin
  EffectPtr^.BBEMixPercent := FBBEMixSlider.Position;
  FBBEMixValueLabel.Caption := Format('%d%% wet', [FBBEMixSlider.Position]);
end;

{ "8.0:1" / "20:1" / "INF:1", matching how the original's ratio scale reads
  (1:1 through to an infinity detent at the top of the travel). }
function C36RatioText(ARatio: Single): string;
begin
  if ARatio >= Alesis3630.A36RatioInfThreshold then
    Result := 'INF:1'
  else if ARatio < 10 then
    Result := Format('%.1f:1', [ARatio])
  else
    Result := Format('%.0f:1', [ARatio]);
end;

{ The 3630's time controls span 0.1ms to 3 seconds between them, so the unit
  has to change with the value or the readout is unreadable at one end. }
function C36TimeText(AMs: Single): string;
begin
  if AMs < 10 then
    Result := Format('%.1fms', [AMs])
  else if AMs < 1000 then
    Result := Format('%.0fms', [AMs])
  else
    Result := Format('%.2fs', [AMs / 1000]);
end;

function C36GateText(ADbfs: Single): string;
begin
  if ADbfs <= Alesis3630.A36GateOffDbfs then
    Result := 'OFF'
  else
    Result := Format('%.0fdB', [ADbfs]);
end;

procedure TEffectWidget.BuildCompressor3630;
var
  Lbl: TLabel;
  i, Col, ColStep: Integer;
begin
  ColStep := C36ColWidth + C36ColGap;

  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(C36LeftMargin);
  Lbl.Top := Px(30);
  Lbl.Caption := 'Response';

  FC36ResponseCombo := TComboBox.Create(Owner);
  FC36ResponseCombo.Parent := Self;
  FC36ResponseCombo.Style := csDropDownList;
  FC36ResponseCombo.Left := Px(C36LeftMargin);
  FC36ResponseCombo.Top := Px(48);
  FC36ResponseCombo.Width := Px(C36SwitchColWidth);
  for i := 0 to Alesis3630.A36ResponseCount - 1 do
    FC36ResponseCombo.Items.Add(Alesis3630.A36ResponseNames[i]);
  if (EffectPtr^.C36Response >= 0) and
    (EffectPtr^.C36Response < Alesis3630.A36ResponseCount) then
    FC36ResponseCombo.ItemIndex := EffectPtr^.C36Response
  else
    FC36ResponseCombo.ItemIndex := Alesis3630.A36ResponsePeak;
  FC36ResponseCombo.ShowHint := True;
  FC36ResponseCombo.Hint := 'RMS makes Attack and Release program dependent ' +
    'and ignores both knobs, as on the original';
  FC36ResponseCombo.OnChange := @C36ResponseChange;

  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(C36LeftMargin);
  Lbl.Top := Px(86);
  Lbl.Caption := 'Knee';

  FC36KneeCombo := TComboBox.Create(Owner);
  FC36KneeCombo.Parent := Self;
  FC36KneeCombo.Style := csDropDownList;
  FC36KneeCombo.Left := Px(C36LeftMargin);
  FC36KneeCombo.Top := Px(104);
  FC36KneeCombo.Width := Px(C36SwitchColWidth);
  for i := 0 to Alesis3630.A36KneeCount - 1 do
    FC36KneeCombo.Items.Add(Alesis3630.A36KneeNames[i]);
  if (EffectPtr^.C36Knee >= 0) and
    (EffectPtr^.C36Knee < Alesis3630.A36KneeCount) then
    FC36KneeCombo.ItemIndex := EffectPtr^.C36Knee
  else
    FC36KneeCombo.ItemIndex := Alesis3630.A36KneeHard;
  FC36KneeCombo.ShowHint := True;
  FC36KneeCombo.Hint := 'Hard clamps at the threshold, soft starts ' +
    'well below it';
  FC36KneeCombo.OnChange := @C36KneeChange;

  Col := C36LeftMargin + C36SwitchColWidth + C36ColGap;
  FC36ThresholdSlider := AddSliderColumn(Col, 'Thresh',
    Alesis3630.A36ThresholdMinDbu, Alesis3630.A36ThresholdMaxDbu,
    Round(EffectPtr^.C36ThresholdDbu), @C36ThresholdSliderChange,
    'Panel scale, in dBu - the top of it is full scale', FC36ThresholdValueLabel);
  FC36ThresholdValueLabel.Caption :=
    Format('%ddBu', [Round(EffectPtr^.C36ThresholdDbu)]);

  Inc(Col, ColStep);
  FC36RatioSlider := AddSliderColumn(Col, 'Ratio', 0, Alesis3630.A36SliderMax,
    Alesis3630.A36RatioToSlider(EffectPtr^.C36Ratio), @C36RatioSliderChange,
    'Fully clockwise is the infinity detent - a hard limiter',
    FC36RatioValueLabel);
  FC36RatioValueLabel.Caption := C36RatioText(EffectPtr^.C36Ratio);

  Inc(Col, ColStep);
  FC36AttackSlider := AddSliderColumn(Col, 'Attack', 0, Alesis3630.A36SliderMax,
    Alesis3630.A36LogMsToSlider(EffectPtr^.C36AttackMs,
      Alesis3630.A36AttackMinMs, Alesis3630.A36AttackMaxMs),
    @C36AttackSliderChange, 'Peak mode only (0.1-200ms)', FC36AttackValueLabel);

  Inc(Col, ColStep);
  FC36ReleaseSlider := AddSliderColumn(Col, 'Rlse', 0, Alesis3630.A36SliderMax,
    Alesis3630.A36LogMsToSlider(EffectPtr^.C36ReleaseMs,
      Alesis3630.A36ReleaseMinMs, Alesis3630.A36ReleaseMaxMs),
    @C36ReleaseSliderChange, 'Peak mode only (50ms-3s)', FC36ReleaseValueLabel);

  Inc(Col, ColStep);
  FC36OutputSlider := AddSliderColumn(Col, 'Output',
    Alesis3630.A36OutputMinDb, Alesis3630.A36OutputMaxDb,
    Round(EffectPtr^.C36OutputDb), @C36OutputSliderChange,
    'Makeup gain - the box has no automatic one', FC36OutputValueLabel);
  FC36OutputValueLabel.Caption := Format('%ddB', [Round(EffectPtr^.C36OutputDb)]);

  Inc(Col, ColStep);
  FC36GateThresholdSlider := AddSliderColumn(Col, 'Gate', 0,
    Alesis3630.A36SliderMax,
    Alesis3630.A36GateDbfsToSlider(EffectPtr^.C36GateThresholdDbfs),
    @C36GateThresholdSliderChange,
    'Fully counter-clockwise is the panel''s "no gating"',
    FC36GateThresholdValueLabel);
  FC36GateThresholdValueLabel.Caption :=
    C36GateText(EffectPtr^.C36GateThresholdDbfs);

  Inc(Col, ColStep);
  FC36GateRateSlider := AddSliderColumn(Col, 'Rate', 0, Alesis3630.A36SliderMax,
    Alesis3630.A36LogMsToSlider(EffectPtr^.C36GateRateMs,
      Alesis3630.A36GateRateMinMs, Alesis3630.A36GateRateMaxMs),
    @C36GateRateSliderChange,
    'How long the gate takes to fade closed (20ms-2s)', FC36GateRateValueLabel);
  FC36GateRateValueLabel.Caption := C36TimeText(EffectPtr^.C36GateRateMs);

  Inc(Col, ColStep);
  FC36MixSlider := AddSliderColumn(Col, 'Mix', 0, 100,
    Round(EffectPtr^.C36MixPercent), @C36MixSliderChange,
    'Under 100% is parallel compression, which the original could not do',
    FC36MixValueLabel);
  FC36MixValueLabel.Caption := Format('%d%% wet', [Round(EffectPtr^.C36MixPercent)]);

  C36UpdateResponseDependentLabels;
end;

{ RMS mode drives its own attack and release from the program material and
  the front-panel knobs do nothing at all in it - the manual is explicit
  about that - so grey them out rather than leaving two live-looking sliders
  that don't reach the audio. }
procedure TEffectWidget.C36UpdateResponseDependentLabels;
var
  IsRms: Boolean;
begin
  IsRms := EffectPtr^.C36Response = Alesis3630.A36ResponseRms;
  FC36AttackSlider.Enabled := not IsRms;
  FC36ReleaseSlider.Enabled := not IsRms;
  if IsRms then
  begin
    FC36AttackValueLabel.Caption := 'prog';
    FC36ReleaseValueLabel.Caption := 'prog';
  end
  else
  begin
    FC36AttackValueLabel.Caption := C36TimeText(EffectPtr^.C36AttackMs);
    FC36ReleaseValueLabel.Caption := C36TimeText(EffectPtr^.C36ReleaseMs);
  end;
end;

procedure TEffectWidget.C36ResponseChange(Sender: TObject);
begin
  EffectPtr^.C36Response := FC36ResponseCombo.ItemIndex;
  C36UpdateResponseDependentLabels;
end;

procedure TEffectWidget.C36KneeChange(Sender: TObject);
begin
  EffectPtr^.C36Knee := FC36KneeCombo.ItemIndex;
end;

procedure TEffectWidget.C36ThresholdSliderChange(Sender: TObject);
begin
  EffectPtr^.C36ThresholdDbu := FC36ThresholdSlider.Position;
  FC36ThresholdValueLabel.Caption :=
    Format('%ddBu', [FC36ThresholdSlider.Position]);
end;

procedure TEffectWidget.C36RatioSliderChange(Sender: TObject);
var
  Ratio: Single;
begin
  Ratio := Alesis3630.A36SliderToRatio(FC36RatioSlider.Position);
  EffectPtr^.C36Ratio := Ratio;
  FC36RatioValueLabel.Caption := C36RatioText(Ratio);
end;

procedure TEffectWidget.C36AttackSliderChange(Sender: TObject);
var
  Ms: Single;
begin
  Ms := Alesis3630.A36SliderToLogMs(FC36AttackSlider.Position,
    Alesis3630.A36AttackMinMs, Alesis3630.A36AttackMaxMs);
  EffectPtr^.C36AttackMs := Ms;
  FC36AttackValueLabel.Caption := C36TimeText(Ms);
end;

procedure TEffectWidget.C36ReleaseSliderChange(Sender: TObject);
var
  Ms: Single;
begin
  Ms := Alesis3630.A36SliderToLogMs(FC36ReleaseSlider.Position,
    Alesis3630.A36ReleaseMinMs, Alesis3630.A36ReleaseMaxMs);
  EffectPtr^.C36ReleaseMs := Ms;
  FC36ReleaseValueLabel.Caption := C36TimeText(Ms);
end;

procedure TEffectWidget.C36OutputSliderChange(Sender: TObject);
begin
  EffectPtr^.C36OutputDb := FC36OutputSlider.Position;
  FC36OutputValueLabel.Caption := Format('%ddB', [FC36OutputSlider.Position]);
end;

procedure TEffectWidget.C36GateThresholdSliderChange(Sender: TObject);
var
  Dbfs: Single;
begin
  Dbfs := Alesis3630.A36SliderToGateDbfs(FC36GateThresholdSlider.Position);
  EffectPtr^.C36GateThresholdDbfs := Dbfs;
  FC36GateThresholdValueLabel.Caption := C36GateText(Dbfs);
end;

procedure TEffectWidget.C36GateRateSliderChange(Sender: TObject);
var
  Ms: Single;
begin
  Ms := Alesis3630.A36SliderToLogMs(FC36GateRateSlider.Position,
    Alesis3630.A36GateRateMinMs, Alesis3630.A36GateRateMaxMs);
  EffectPtr^.C36GateRateMs := Ms;
  FC36GateRateValueLabel.Caption := C36TimeText(Ms);
end;

procedure TEffectWidget.C36MixSliderChange(Sender: TObject);
begin
  EffectPtr^.C36MixPercent := FC36MixSlider.Position;
  FC36MixValueLabel.Caption := Format('%d%% wet', [FC36MixSlider.Position]);
end;

{ The FZ-2's knobs are marked 0-10, not 0-100 and not in percent, so that is
  what the readouts say. }
function FZ2KnobText(AValue: Integer): string;
begin
  Result := Format('%.1f', [AValue / 10]);
end;

procedure TEffectWidget.BuildFuzzFZ2;
var
  Lbl: TLabel;
  i, Col, ColStep: Integer;
begin
  ColStep := FZ2ColWidth + FZ2ColGap;

  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := Px(FZ2LeftMargin);
  Lbl.Top := Px(30);
  Lbl.Caption := 'Mode';

  FFZ2ModeCombo := TComboBox.Create(Owner);
  FFZ2ModeCombo.Parent := Self;
  FFZ2ModeCombo.Style := csDropDownList;
  FFZ2ModeCombo.Left := Px(FZ2LeftMargin);
  FFZ2ModeCombo.Top := Px(48);
  FFZ2ModeCombo.Width := Px(FZ2ModeColWidth);
  for i := 0 to BossFZ2.FZ2ModeCount - 1 do
    FFZ2ModeCombo.Items.Add(BossFZ2.FZ2ModeNames[i]);
  if (EffectPtr^.FZ2Mode >= 0) and (EffectPtr^.FZ2Mode < BossFZ2.FZ2ModeCount) then
    FFZ2ModeCombo.ItemIndex := EffectPtr^.FZ2Mode
  else
    FFZ2ModeCombo.ItemIndex := BossFZ2.FZ2ModeFuzz2;
  FFZ2ModeCombo.ShowHint := True;
  FFZ2ModeCombo.Hint := 'Fuzz II is Fuzz I through the 1kHz mid-scoop; ' +
    'Boost takes the fuzz out of the path entirely';
  FFZ2ModeCombo.OnChange := @FZ2ModeChange;

  Col := FZ2LeftMargin + FZ2ModeColWidth + FZ2ColGap;
  FFZ2GainSlider := AddSliderColumn(Col, 'Gain',
    BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, Round(EffectPtr^.FZ2Gain),
    @FZ2GainSliderChange, 'How hard both stages are driven - in Boost mode ' +
    'this is the boost amount instead', FFZ2GainValueLabel);

  Inc(Col, ColStep);
  FFZ2TrebleSlider := AddSliderColumn(Col, 'Treble',
    BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, Round(EffectPtr^.FZ2Treble),
    @FZ2TrebleSliderChange, 'High shelf, flat at 5.0', FFZ2TrebleValueLabel);
  FFZ2TrebleValueLabel.Caption := FZ2KnobText(Round(EffectPtr^.FZ2Treble));

  Inc(Col, ColStep);
  FFZ2BassSlider := AddSliderColumn(Col, 'Bass',
    BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, Round(EffectPtr^.FZ2Bass),
    @FZ2BassSliderChange, 'Low shelf, flat at 5.0', FFZ2BassValueLabel);
  FFZ2BassValueLabel.Caption := FZ2KnobText(Round(EffectPtr^.FZ2Bass));

  Inc(Col, ColStep);
  FFZ2LevelSlider := AddSliderColumn(Col, 'Level',
    BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, Round(EffectPtr^.FZ2Level),
    @FZ2LevelSliderChange, 'Output volume - well above unity at the top, ' +
    'like the pedal', FFZ2LevelValueLabel);
  FFZ2LevelValueLabel.Caption := FZ2KnobText(Round(EffectPtr^.FZ2Level));

  Inc(Col, ColStep);
  FFZ2MixSlider := AddSliderColumn(Col, 'Mix', 0, 100,
    Round(EffectPtr^.FZ2MixPercent), @FZ2MixSliderChange,
    'The pedal has no blend - anything under 100% is this program''s idea',
    FFZ2MixValueLabel);
  FFZ2MixValueLabel.Caption := Format('%d%% wet', [Round(EffectPtr^.FZ2MixPercent)]);

  FZ2UpdateModeDependentLabels;
end;

{ Boost mode reuses the Gain pot as a straight clean-boost control, so the
  readout switches from the panel's 0-10 to the dB it is actually asking
  for - the same reason the 3630's Attack/Release readouts change in RMS
  mode. The knob still does something in both, so unlike those two it is
  never disabled. }
procedure TEffectWidget.FZ2UpdateModeDependentLabels;
begin
  if EffectPtr^.FZ2Mode = BossFZ2.FZ2ModeBoost then
    FFZ2GainValueLabel.Caption := Format('+%ddB',
      [Round(EffectPtr^.FZ2Gain / 100 * BossFZ2.FZ2BoostMaxDb)])
  else
    FFZ2GainValueLabel.Caption := FZ2KnobText(Round(EffectPtr^.FZ2Gain));
end;

procedure TEffectWidget.FZ2ModeChange(Sender: TObject);
begin
  EffectPtr^.FZ2Mode := FFZ2ModeCombo.ItemIndex;
  FZ2UpdateModeDependentLabels;
end;

procedure TEffectWidget.FZ2GainSliderChange(Sender: TObject);
begin
  EffectPtr^.FZ2Gain := FFZ2GainSlider.Position;
  FZ2UpdateModeDependentLabels;
end;

procedure TEffectWidget.FZ2TrebleSliderChange(Sender: TObject);
begin
  EffectPtr^.FZ2Treble := FFZ2TrebleSlider.Position;
  FFZ2TrebleValueLabel.Caption := FZ2KnobText(FFZ2TrebleSlider.Position);
end;

procedure TEffectWidget.FZ2BassSliderChange(Sender: TObject);
begin
  EffectPtr^.FZ2Bass := FFZ2BassSlider.Position;
  FFZ2BassValueLabel.Caption := FZ2KnobText(FFZ2BassSlider.Position);
end;

procedure TEffectWidget.FZ2LevelSliderChange(Sender: TObject);
begin
  EffectPtr^.FZ2Level := FFZ2LevelSlider.Position;
  FFZ2LevelValueLabel.Caption := FZ2KnobText(FFZ2LevelSlider.Position);
end;

procedure TEffectWidget.FZ2MixSliderChange(Sender: TObject);
begin
  EffectPtr^.FZ2MixPercent := FFZ2MixSlider.Position;
  FFZ2MixValueLabel.Caption := Format('%d%% wet', [FFZ2MixSlider.Position]);
end;

end.
