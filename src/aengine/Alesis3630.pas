unit Alesis3630;

{$mode objfpc}{$H+}

{ Alesis 3630 (1989) dual-channel compressor/limiter with gate - the
  $100 rack unit that ended up on more jungle records than every expensive
  compressor put together, because it was the one everybody could afford.

  Ranges and behaviour below are quoted from the 3630 reference manual. The
  things that make it a 3630 rather than a generic compressor, all modelled:

  1. IT IS A FEED-FORWARD VCA BOX AND THE SMOOTHING HAPPENS IN THE CONTROL
     PATH, NOT ON THE AUDIO. Attack and Release here are one-pole time
     constants on the gain reduction expressed in dB, and the dB figure is
     what becomes a linear gain afterwards. That is why the 3630 pumps the
     way it does: a fixed time constant in the log domain means the louder
     it is working, the further it has to travel, so heavy gain reduction
     releases audibly slower than light gain reduction even in Peak mode.

  2. RMS MODE IGNORES THE ATTACK AND RELEASE KNOBS ENTIRELY. This is not an
     approximation, it is the manual: "in RMS mode, the attack and release
     times will be program dependent. The front panel attack and release
     controls will have no effect on the signal." Modelled as a cascaded
     fast/slow mean-square detector whose fall time is stretched in
     proportion to how hard the box has been working recently - see
     A36ProgramReleaseStretch. This is the mode the long, breathing,
     obviously-squashed break sound comes from.

  3. THE SOFT KNEE IS WIDE. "With hard knee response, signals are clamped to
     the limiting threshold as soon as they exceed it. With soft knee
     response, signals are clamped more gently." The 3630's is broad enough
     that on a break it starts working well before the meters admit it,
     which is most of what people mean when they call the soft setting
     "musical" and the hard setting "severe".

  4. STEREO LINK IS ALWAYS ON, and per the manual the control signal is
     derived from a combination of both inputs - "an input signal on either
     Channel A or Channel B will cause compression to occur... even if there
     is no input signal present on the opposite channel". So the detector
     below takes the larger of the two channels and one gain serves both,
     which is also the only way an insert on a stereo track can avoid
     wandering the image.

  Why this box in this program: fast attack, high ratio, Peak mode, hard
  knee is the classic mid-90s break treatment - it flattens the ghost notes
  up into the snare and turns an Amen into a solid block of noise. RMS mode
  with a low ratio across the whole mix is the other half of its reputation:
  the long program-dependent release is what makes a pad wash swell back up
  between snares, which is the entire atmospheric-jungle master-bus trick.

  Deliberately NOT implemented, being things this side of the music never
  touched:
  - The side chain insert jack (both its keying and its de-essing uses). It
    is a rear-panel patch point for an external box; a chain slot has
    nowhere to route one, and ekSidechain already covers keying off another
    track.
  - Dual-mono operation / the stereo link switch, per (4) above.
  - The +4dBu / -10dBV switch and the Input-Output meter switch: analog
    gain-staging and metering with nothing to correspond to here.
  - The gain reduction, input/output and gate LED displays.
  - The unit's own hiss. The 3630 is famous for it, but a noise floor an
    insert can't be told to stop adding is not something anybody wants
    baked into every project.

  Levels: the panel is calibrated in dBu and the DSP works in dBFS, so the
  two are tied together at A36ZeroDbfsDbu. }

interface

uses
  Math;

const
  { "Threshold (-40 to +20 dBu)". Pinning 0dBFS to +20dBu puts the top of
    the panel's own range exactly at full scale, so the knob's travel maps
    onto the useful part of a float mix instead of running off the end. }
  A36ZeroDbfsDbu = 20.0;
  A36ThresholdMinDbu = -40;
  A36ThresholdMaxDbu = 20;

  { "Attack (0.1 ms to 200 ms)" / "Release (50 ms to 3 seconds)", both Peak
    mode only. Swept logarithmically - a linear sweep would spend nine
    tenths of its travel between 20ms and 200ms. }
  A36AttackMinMs = 0.1;
  A36AttackMaxMs = 200.0;
  A36ReleaseMinMs = 50.0;
  A36ReleaseMaxMs = 3000.0;

  { "Output (-20 to +20 dB)" }
  A36OutputMinDb = -20;
  A36OutputMaxDb = 20;

  { "Compression Ratio: 1:1 - infinity:1". The slider is swept
    logarithmically from 1:1 up to A36RatioMaxFinite, and its very top
    position is the panel's infinity detent - a true limiter. }
  A36RatioMaxFinite = 30.0;
  A36RatioInfinite = 1.0E6;
  { at or above this a ratio reads as the infinity detent rather than a
    number, both for display and for DefaultEffect }
  A36RatioInfThreshold = 1000.0;

  { "Hard knee - Soft knee". Width in dB, centred on the threshold; hard is
    a width of zero. }
  A36SoftKneeDb = 18.0;

  { Detector response. "Peak or RMS response." }
  A36ResponsePeak = 0;
  A36ResponseRms = 1;
  A36ResponseCount = 2;
  A36ResponseNames: array[0..A36ResponseCount - 1] of string =
    ('Peak', 'RMS');

  A36KneeHard = 0;
  A36KneeSoft = 1;
  A36KneeCount = 2;
  A36KneeNames: array[0..A36KneeCount - 1] of string =
    ('Hard', 'Soft');

  { RMS mode's own fixed time constants, standing in for the knobs it
    ignores. Fast stage reads the envelope, slow stage is the one that
    actually drives the VCA. }
  A36RmsFastMs = 5.0;
  A36RmsAttackMs = 15.0;
  A36RmsReleaseMs = 250.0;
  { how fast the "how hard has this been working" accumulator moves }
  A36RmsHoldMs = 500.0;
  { and how much that accumulator stretches the release: at 10dB of
    sustained gain reduction the release runs 2.5x longer than at rest.
    This is the program dependence the manual promises in RMS mode. }
  A36ProgramReleaseStretch = 0.15;

  { Gate. "Threshold (no gating to -10dBV)" - -10dBV is -7.78dBu, so against
    A36ZeroDbfsDbu the panel's fully-clockwise gate threshold is -27.8dBFS.
    Fully counter-clockwise "disables the noise gate and lets the signal
    through unaltered", which is the A36GateOffDbfs sentinel. }
  A36GateThresholdMaxDbfs = -27.8;
  A36GateThresholdMinDbfs = -80.0;
  A36GateOffDbfs = -99.0;
  { "Rate (20 ms to 2 seconds)" - "determines how long it takes for the gate
    to fade smoothly from the gate open to gate closed setting", i.e. it is
    a close time only. The 3630's gate opens effectively instantly. }
  A36GateRateMinMs = 20.0;
  A36GateRateMaxMs = 2000.0;
  A36GateOpenMs = 1.0;
  { the gate closes 3dB below where it opens, so material sitting right on
    the threshold doesn't chatter }
  A36GateHysteresisDb = 3.0;

  { Slider travel for every log-swept control on this box, so the UI never
    restates a range this unit already owns. }
  A36SliderMax = 100;

type
  TA36State = record
    { detector }
    RmsFast: Single;
    RmsSlow: Single;
    RmsHold: Single;
    { current gain reduction as a POSITIVE number of dB, linked across L/R }
    GrDb: Single;
    { gate }
    GateEnv: Single;
    GateGain: Single;
    GateOpen: Boolean;
    { cached coefficients - recomputed only when the setting behind them
      actually moved, same convention as the rest of Effects.pas }
    LastSampleRate: Integer;
    LastAttackMs, LastReleaseMs, LastGateRateMs: Single;
    AttackCoeff, ReleaseCoeff, GateCloseCoeff: Single;
    { the gate's two thresholds as linear amplitudes, so deciding open vs
      closed is a comparison rather than a log on every sample }
    LastGateThresholdDbfs: Single;
    GateOpenLin, GateCloseLin: Single;
    RmsFastCoeff, RmsAttackCoeff, RmsReleaseCoeff, RmsHoldCoeff: Single;
    GateOpenCoeff, GateEnvCoeff: Single;
    LastThresholdDbu: Single;
    ThresholdDb: Single;  { the same threshold, in dBFS }
    { the same threshold again as a linear amplitude, and the bottom corner
      of the soft knee likewise - what the per-sample "is there anything to
      do at all?" test compares against, so the common case costs no log }
    ThresholdLin: Single;
    KneeStartLin: Single;
    LastOutputDb: Single;
    OutputGain: Single;
  end;

procedure A36Reset(var AState: TA36State);

{ One host-rate frame in place. AThresholdDbu is on the panel's dBu scale;
  ARatio is a plain ratio (A36RatioInfinite for the infinity detent);
  AGateThresholdDbfs is dBFS or A36GateOffDbfs; AMixPercent is 0..100. }
procedure A36Process(var AState: TA36State; var L, R: Single;
  ASampleRate, AResponse, AKnee: Integer;
  AThresholdDbu, ARatio, AAttackMs, AReleaseMs, AOutputDb,
  AGateThresholdDbfs, AGateRateMs, AMixPercent: Single);

{ Slider position <-> value for the log-swept controls. These live here
  rather than in the rack widget so the UI can't drift from what the DSP
  accepts - same reason Quadraverb.pas owns its own ranges. }
function A36SliderToLogMs(APos: Integer; AMinMs, AMaxMs: Single): Single;
function A36LogMsToSlider(AMs, AMinMs, AMaxMs: Single): Integer;
function A36SliderToRatio(APos: Integer): Single;
function A36RatioToSlider(ARatio: Single): Integer;
{ Position 0 is the panel's fully-counter-clockwise "no gating". }
function A36SliderToGateDbfs(APos: Integer): Single;
function A36GateDbfsToSlider(ADbfs: Single): Integer;

implementation

const
  { 20 / ln(10) - turns a natural log into dB in one multiply }
  A36DbPerNeper = 8.6858896380650366;
  { ln(10) / 20 - and back again }
  A36NeperPerDb = 0.11512925464970229;
  { below this much gain reduction the box is doing nothing audible and the
    exponential can be skipped outright }
  A36GrEpsilon = 0.0005;

function A36SliderToLogMs(APos: Integer; AMinMs, AMaxMs: Single): Single;
begin
  if APos < 0 then APos := 0;
  if APos > A36SliderMax then APos := A36SliderMax;
  Result := AMinMs * Exp((APos / A36SliderMax) * Ln(AMaxMs / AMinMs));
end;

function A36LogMsToSlider(AMs, AMinMs, AMaxMs: Single): Integer;
begin
  if AMs < AMinMs then AMs := AMinMs;
  if AMs > AMaxMs then AMs := AMaxMs;
  Result := Round(A36SliderMax * Ln(AMs / AMinMs) / Ln(AMaxMs / AMinMs));
end;

function A36SliderToRatio(APos: Integer): Single;
begin
  if APos < 0 then APos := 0;
  if APos >= A36SliderMax then
  begin
    Result := A36RatioInfinite; { the panel's own infinity detent }
    Exit;
  end;
  { 1:1 at the bottom up to A36RatioMaxFinite at the last finite step }
  Result := Exp((APos / (A36SliderMax - 1)) * Ln(A36RatioMaxFinite));
end;

function A36RatioToSlider(ARatio: Single): Integer;
begin
  if ARatio >= A36RatioInfThreshold then
  begin
    Result := A36SliderMax;
    Exit;
  end;
  if ARatio < 1 then ARatio := 1;
  if ARatio > A36RatioMaxFinite then ARatio := A36RatioMaxFinite;
  Result := Round((A36SliderMax - 1) * Ln(ARatio) / Ln(A36RatioMaxFinite));
end;

function A36SliderToGateDbfs(APos: Integer): Single;
begin
  if APos <= 0 then
  begin
    Result := A36GateOffDbfs;
    Exit;
  end;
  if APos > A36SliderMax then APos := A36SliderMax;
  Result := A36GateThresholdMinDbfs + ((APos - 1) / (A36SliderMax - 1)) *
    (A36GateThresholdMaxDbfs - A36GateThresholdMinDbfs);
end;

function A36GateDbfsToSlider(ADbfs: Single): Integer;
begin
  if ADbfs <= A36GateOffDbfs then
  begin
    Result := 0;
    Exit;
  end;
  if ADbfs < A36GateThresholdMinDbfs then ADbfs := A36GateThresholdMinDbfs;
  if ADbfs > A36GateThresholdMaxDbfs then ADbfs := A36GateThresholdMaxDbfs;
  Result := 1 + Round((A36SliderMax - 1) *
    (ADbfs - A36GateThresholdMinDbfs) /
    (A36GateThresholdMaxDbfs - A36GateThresholdMinDbfs));
end;

procedure A36Reset(var AState: TA36State);
begin
  FillChar(AState, SizeOf(AState), 0);
  AState.GateGain := 1.0; { open - nothing to gate until a threshold is set }
  AState.GateOpen := True;
  AState.OutputGain := 1.0;
  { NaN for every "last setting seen" cache, so the first real call always
    recomputes - see Effects.EffectStateReset for the full reasoning. }
  AState.LastAttackMs := NaN;
  AState.LastReleaseMs := NaN;
  AState.LastGateRateMs := NaN;
  AState.LastThresholdDbu := NaN;
  AState.LastOutputDb := NaN;
  AState.LastGateThresholdDbfs := NaN;
end;

{ Standard one-pole time constant: the fraction of the remaining distance to
  close per sample so that the step response reaches 1-1/e after AMs. }
function A36Coeff(AMs: Single; ASampleRate: Integer): Single;
begin
  if AMs < 0.001 then
    AMs := 0.001;
  Result := 1 - Exp(-1 / (AMs * 0.001 * ASampleRate));
end;

procedure A36Process(var AState: TA36State; var L, R: Single;
  ASampleRate, AResponse, AKnee: Integer;
  AThresholdDbu, ARatio, AAttackMs, AReleaseMs, AOutputDb,
  AGateThresholdDbfs, AGateRateMs, AMixPercent: Single);
var
  DryL, DryR: Single;
  Det, DetSq, Level, LevelDb, OverDb, Slope, TargetGrDb, KneeFloor: Single;
  Coeff, EffReleaseCoeff, Gain: Single;
  MixFrac, WetL, WetR: Single;
begin
  if AState.LastSampleRate <> ASampleRate then
  begin
    AState.RmsFastCoeff := A36Coeff(A36RmsFastMs, ASampleRate);
    AState.RmsAttackCoeff := A36Coeff(A36RmsAttackMs, ASampleRate);
    AState.RmsReleaseCoeff := A36Coeff(A36RmsReleaseMs, ASampleRate);
    AState.RmsHoldCoeff := A36Coeff(A36RmsHoldMs, ASampleRate);
    AState.GateOpenCoeff := A36Coeff(A36GateOpenMs, ASampleRate);
    AState.GateEnvCoeff := A36Coeff(A36RmsFastMs, ASampleRate);
    AState.LastSampleRate := ASampleRate;
    AState.LastAttackMs := NaN;
    AState.LastReleaseMs := NaN;
    AState.LastGateRateMs := NaN;
  end;
  if AAttackMs <> AState.LastAttackMs then
  begin
    AState.AttackCoeff := A36Coeff(AAttackMs, ASampleRate);
    AState.LastAttackMs := AAttackMs;
  end;
  if AReleaseMs <> AState.LastReleaseMs then
  begin
    AState.ReleaseCoeff := A36Coeff(AReleaseMs, ASampleRate);
    AState.LastReleaseMs := AReleaseMs;
  end;
  if AGateRateMs <> AState.LastGateRateMs then
  begin
    AState.GateCloseCoeff := A36Coeff(AGateRateMs, ASampleRate);
    AState.LastGateRateMs := AGateRateMs;
  end;
  if AThresholdDbu <> AState.LastThresholdDbu then
  begin
    AState.ThresholdDb := AThresholdDbu - A36ZeroDbfsDbu;
    AState.ThresholdLin := Exp(AState.ThresholdDb * A36NeperPerDb);
    AState.KneeStartLin := Exp((AState.ThresholdDb - A36SoftKneeDb * 0.5) *
      A36NeperPerDb);
    AState.LastThresholdDbu := AThresholdDbu;
  end;
  if AOutputDb <> AState.LastOutputDb then
  begin
    AState.OutputGain := Exp(AOutputDb * A36NeperPerDb);
    AState.LastOutputDb := AOutputDb;
  end;
  if AGateThresholdDbfs <> AState.LastGateThresholdDbfs then
  begin
    AState.GateOpenLin := Exp(AGateThresholdDbfs * A36NeperPerDb);
    AState.GateCloseLin := Exp((AGateThresholdDbfs - A36GateHysteresisDb) *
      A36NeperPerDb);
    AState.LastGateThresholdDbfs := AGateThresholdDbfs;
  end;

  DryL := L;
  DryR := R;

  { --- detector. The larger of the two channels, per the manual's stereo
    link: either channel alone is enough to make the box work. --- }
  Det := Abs(L);
  if Abs(R) > Det then
    Det := Abs(R);

  if AResponse = A36ResponseRms then
  begin
    { Cascaded fast/slow mean-square. The slow stage rises quickly and falls
      slowly, and its fall is stretched further the longer the box has been
      working - the manual's "program dependent" attack and release. The
      front-panel Attack and Release are not consulted at all here, exactly
      as the manual says they aren't. }
    DetSq := Det * Det;
    AState.RmsFast := AState.RmsFast +
      AState.RmsFastCoeff * (DetSq - AState.RmsFast);
    if AState.RmsFast > AState.RmsSlow then
      Coeff := AState.RmsAttackCoeff
    else
    begin
      AState.RmsHold := AState.RmsHold +
        AState.RmsHoldCoeff * (AState.GrDb - AState.RmsHold);
      Coeff := AState.RmsReleaseCoeff /
        (1 + AState.RmsHold * A36ProgramReleaseStretch);
    end;
    AState.RmsSlow := AState.RmsSlow + Coeff * (AState.RmsFast - AState.RmsSlow);
    if AState.RmsSlow < 0 then
      AState.RmsSlow := 0;
    Level := Sqrt(AState.RmsSlow);
  end
  else
  begin
    { Peak mode: the rectified peak straight into the knee, with all of the
      smoothing done on the gain reduction below rather than here. That is
      what makes Attack read as "how fast the limiting action kicks in"
      rather than as a lowpass on the detector. The ripple this leaves on
      sustained low frequencies is real and is the reason the original's
      Release knob bottoms out at 50ms rather than going faster. }
    Level := Det;
  end;

  { --- knee --- }
  if ARatio < 1 then
    ARatio := 1;
  Slope := 1 - 1 / ARatio;
  { Nothing at or below the bottom of the curve can produce gain reduction -
    the threshold itself with a hard knee, half a knee below it with a soft
    one - and on real material that is the overwhelmingly common case. Test
    it against the cached linear threshold so the log is never taken at all
    there rather than computed and thrown away. }
  if AKnee = A36KneeSoft then
    KneeFloor := AState.KneeStartLin
  else
    KneeFloor := AState.ThresholdLin;
  TargetGrDb := 0;
  if Level > KneeFloor then
  begin
    LevelDb := Ln(Level) * A36DbPerNeper;
    OverDb := LevelDb - AState.ThresholdDb;
    if AKnee = A36KneeSoft then
    begin
      if OverDb >= A36SoftKneeDb * 0.5 then
        TargetGrDb := OverDb * Slope
      else
        { quadratic interpolation across the knee: zero reduction AND zero
          slope at the bottom corner, full slope at the top one, so the
          transfer curve has no kink at either end of it }
        TargetGrDb := Slope * Sqr(OverDb + A36SoftKneeDb * 0.5) /
          (2 * A36SoftKneeDb);
    end
    else
      TargetGrDb := OverDb * Slope;
  end;

  { --- the VCA's control path: one-pole in dB, not in linear gain --- }
  if TargetGrDb > AState.GrDb then
  begin
    if AResponse = A36ResponseRms then
      Coeff := AState.RmsAttackCoeff
    else
      Coeff := AState.AttackCoeff;
  end
  else
  begin
    if AResponse = A36ResponseRms then
    begin
      EffReleaseCoeff := AState.RmsReleaseCoeff /
        (1 + AState.RmsHold * A36ProgramReleaseStretch);
      Coeff := EffReleaseCoeff;
    end
    else
      Coeff := AState.ReleaseCoeff;
  end;
  AState.GrDb := AState.GrDb + Coeff * (TargetGrDb - AState.GrDb);
  if AState.GrDb < 0 then
    AState.GrDb := 0;

  if AState.GrDb < A36GrEpsilon then
    Gain := 1
  else
    Gain := Exp(-AState.GrDb * A36NeperPerDb);

  WetL := L * Gain * AState.OutputGain;
  WetR := R * Gain * AState.OutputGain;

  { --- gate, last in the chain and keyed off its own input, which is why
    "set the Ratio to 1:1" turns the 3630 into a standalone noise gate --- }
  if AGateThresholdDbfs > A36GateOffDbfs then
  begin
    Det := Abs(WetL);
    if Abs(WetR) > Det then
      Det := Abs(WetR);
    AState.GateEnv := AState.GateEnv +
      AState.GateEnvCoeff * (Det - AState.GateEnv);
    { hysteresis: once open it stays open until the level drops a full
      A36GateHysteresisDb BELOW where it opened, so material sitting on the
      threshold can't chatter the gate }
    if AState.GateOpen then
      AState.GateOpen := AState.GateEnv > AState.GateCloseLin
    else
      AState.GateOpen := AState.GateEnv > AState.GateOpenLin;
    if AState.GateOpen then
      AState.GateGain := AState.GateGain +
        AState.GateOpenCoeff * (1 - AState.GateGain)
    else
      AState.GateGain := AState.GateGain +
        AState.GateCloseCoeff * (0 - AState.GateGain);
    WetL := WetL * AState.GateGain;
    WetR := WetR * AState.GateGain;
  end
  else if AState.GateGain <> 1 then
  begin
    { the panel's fully-counter-clockwise "no gating" - snap back open so
      turning the gate off can't leave a fade hanging }
    AState.GateGain := 1;
    AState.GateOpen := True;
  end;

  MixFrac := AMixPercent / 100;
  if MixFrac < 0 then MixFrac := 0;
  if MixFrac > 1 then MixFrac := 1;
  L := DryL * (1 - MixFrac) + WetL * MixFrac;
  R := DryR * (1 - MixFrac) + WetR * MixFrac;
end;

end.
