unit BossFZ2;

{$mode objfpc}{$H+}

{ Boss FZ-2 Hyper Fuzz (1993-1997) - the black one with four knobs and a
  three-way mode switch, and the single most direct route to the guitar
  sound on Electric Wizard's Dopethrone.

  It is NOT a Boss distortion with a fuzz badge on it. Underneath the usual
  Boss input buffer and output stage the FZ-2 is a Univox Super-Fuzz, and
  the Super-Fuzz is built around one idea nothing else on a pedalboard does:

  1. TWO CASCADED HIGH-GAIN STAGES, both driven far past the point of being
     amplifiers. By the time signal leaves the second one it is essentially
     a square wave with the transient shape of the pick attack still in it.

  2. A DIFFERENTIAL PAIR RUN AS A FULL-WAVE RECTIFIER (Q13/Q14 on the FZ-2
     board - "two transistors facing each other with a common emitter").
     Perfectly matched it would output |x|: pure octave-up, plus DC that the
     next coupling cap removes. Real pairs are never matched, so one half of
     the waveform comes through hotter than the other, a residue of the
     fundamental survives, and that residue beating against the octave is
     what gives the Super-Fuzz its ring-modulator edge, its enormous
     compression and its faint suggestion of an octave DOWN as well as up.
     The octave-up is loudest around the 12th fret and mostly a texture
     lower down, exactly like an Octavia with the wick turned down.

  3. BACK-TO-BACK DIODES clipping the rectifier's output. This is where the
     sustain-forever wall comes from: everything above the diode drop is
     simply gone, so the fuzz holds full level until the string stops.

  4. A BRIDGED-T NOTCH AT ~1kHz, switched in and out. This is the whole
     difference between the two fuzz modes: "Fuzz 1 takes the output of the
     circuit from the end of the Super Fuzz circuit, while Fuzz 2 runs that
     same signal through a mid-scoop circuit." Fuzz II is the fat, hollow,
     almost bassy one, and it is the Dopethrone setting.

  Boss's own additions on top of the Super-Fuzz are the makeup gain (the
  vintage circuit's output was feeble), an active two-band tone stack driven
  off a dual pot, and a third mode switch position: Boost, a clean +25dB
  with the tone stack still live and no fuzz circuit in the path at all.

  ---

  ALIASING, and why this unit oversamples 4x when Effects.ekOverdrive does
  not. A full-wave rectifier is a frequency doubler by construction, and a
  hard diode clip generates harmonics without limit; a 3kHz partial of a
  power chord comes out of this chain with meaningful energy well past
  80kHz. Run at host rate all of that folds back down as inharmonic hash and
  the pedal stops sounding like a pedal and starts sounding like a bitcrush.
  So the whole nonlinear block - both gain stages, the rectifier, the diodes
  and the interstage filters that shape them - runs at 4x, between an 8-pole
  Butterworth pair. The linear tail (notch, tone stack, level) has nothing
  to alias and stays at host rate.

  ---

  Deliberately NOT implemented:
  - The Boss buffer and the FLB (flip-flop) bypass switching. A DAW insert
    slot already is the bypass, and a unity-gain buffer inside a float chain
    is a no-op.
  - Boss's noise-reduction stage. It exists on the board to keep a +66dB
    fuzz from hissing between notes into a real amp; a plugin has no noise
    floor of its own to suppress, and gating a fuzz is a decision the user
    can make with the 3630's gate if they want it.
  - The battery/PSU sag. The FZ-2 runs off a regulated 9V rail and does not
    have the dying-battery character a Fuzz Face trades on.
  - The +16dBu-ish input clip point of the input buffer, for the reason the
    422A's is skipped too - nothing inside a float insert reaches it.

  This is a MONO pedal. Two independent instances run here, one per channel,
  which is what a stereo pair of FZ-2s would do; there is no detector or
  shared control voltage anywhere in the circuit, so nothing needs linking
  across L/R the way the 422A's and the 3630's do. }

interface

uses
  Math, BiquadFilters;

const
  { --- the mode switch --- }
  FZ2ModeFuzz1 = 0;
  FZ2ModeFuzz2 = 1;
  FZ2ModeBoost = 2;
  FZ2ModeCount = 3;
  FZ2ModeNames: array[0..FZ2ModeCount - 1] of string =
    ('Fuzz I', 'Fuzz II', 'Boost');

  { All four knobs are 0..10 on the panel and 0..100 here, so a slider has
    something to resolve. The widget divides by 10 for display. }
  FZ2KnobMin = 0;
  FZ2KnobMax = 100;

  { --- oversampling ---
    4x with an 8-pole Butterworth each way. The cutoff is deliberately below
    host Nyquist rather than at it: there is nothing above 18kHz coming out
    of a fuzz pedal that anyone wants, and buying ~4dB more rejection of the
    fold-down band with it is a straight trade up. }
  FZ2Oversample = 4;
  FZ2AAStages = 4;
  { Q of each cascaded 2nd-order section of an 8-pole Butterworth. }
  FZ2AAQ: array[0..FZ2AAStages - 1] of Single =
    (0.50979558, 0.60134489, 0.89997622, 2.56291544);
  FZ2AACutoffRatio = 0.42; { x the HOST rate }

  { --- input --- }
  { The input coupling cap. Low enough to pass a guitar tuned to B without
    thinning it, high enough to keep DC and stage rumble out of a chain
    with 66dB of gain in it. }
  FZ2InputHpHz = 30.0;

  { --- the two gain stages ---
    Gain fully counter-clockwise is still 26dB into the clipper, because the
    FZ-2 fully counter-clockwise is still a fuzz. Fully clockwise is 66dB
    across both stages, which is what turns any input level at all into the
    same square wave. }
  FZ2Stage1MinDb = 6.0;
  FZ2Stage1MaxDb = 46.0;
  FZ2Stage2Db = 20.0;
  { Interstage coupling. The highpass in front of each clipper is what keeps
    a downtuned riff articulate instead of turning the low end into one
    continuous slab - it is also why the pedal cleans up more on the neck
    pickup than the gain setting suggests it should.
    60Hz and not the ~85Hz a general-purpose fuzz would want, because this
    one is pointed at a guitar in C# or B: there are TWO of these in series,
    so a corner up at 85 would take about 10dB off a 69Hz fundamental before
    the clipper ever saw it. At 60 the pair costs it under 4dB, which is
    still enough to keep the clipper tight. }
  FZ2InterstageHpHz = 60.0;
  { Collector/Miller rolloff after stage 1. A fuzz is not bright BEFORE the
    tone stack; without this the squarewave's upper harmonics reach the
    rectifier at full strength and the octave section turns to fizz. }
  FZ2InterstageLpHz = 6000.0;
  { Bias offsets. Single-supply transistor stages never sit centred, and the
    even harmonics that asymmetry produces are a real part of the sound.
    Opposite signs so the two stages don't compound into a large DC step. }
  FZ2Stage1Bias = 0.06;
  FZ2Stage2Bias = -0.04;

  { --- the differential pair / octave section ---
    The mismatch between the two halves. 1.0 vs 0.82 is a deliberately
    sloppy pair: a matched one (1.0/1.0) gives a clean octave-up and loses
    the ring-mod grind entirely, and the real thing was built out of
    whatever came off the reel. }
  FZ2RectPosGain = 1.0;
  FZ2RectNegGain = 0.82;
  { How much rectified signal is blended back against the straight one. The
    Super-Fuzz's octave is a strong texture rather than a full-wet Octavia,
    which is why it reads as "harmonically wrong" rather than as an octave
    pedal. }
  FZ2OctaveMix = 0.55;
  { Pole of the DC blocker that stands in for the coupling cap after the
    rectifier. Rectification puts a large DC offset on everything and it has
    to come off before the diodes, or they clip asymmetrically for the wrong
    reason. }
  FZ2RectDcBlockHz = 20.0;

  { --- back-to-back diodes ---
    Drive is how far past the diode drop the rectifier's output is pushed;
    Knee is where the curve leaves unity. Below the knee the response is
    linear (the diodes are not conducting yet), above it a tanh takes it to
    a flat ceiling with a slope that is continuous at the corner - the
    softish shoulder germanium has, not the instant corner of a comparator. }
  FZ2DiodeDrive = 3.0;
  FZ2DiodeKnee = 0.55;

  { Output bandwidth of the fuzz section, before the tone stack gets to it. }
  FZ2PostLpHz = 7500.0;
  FZ2OutDcBlockHz = 10.0;

  { --- the bridged-T notch, i.e. the whole of Fuzz II ---
    Wide and deep rather than surgical: the original is a passive bridged-T
    around a single transistor and it takes out most of the octave either
    side of 1kHz, which is what makes Fuzz II sound "very fat, almost
    bassy" next to Fuzz I. }
  FZ2NotchHz = 1000.0;
  FZ2NotchQ = 0.75;
  FZ2NotchDepthDb = -18.0;

  { --- tone stack ---
    Boss's active two-band, not the Super-Fuzz's tone switch. Both knobs are
    flat at 5 on the panel (50 here) and reach +/-12dB at the ends. }
  FZ2BassHz = 100.0;
  FZ2TrebleHz = 3000.0;
  FZ2ToneRangeDb = 12.0;
  { Shelf slope. Under 1.0 so the corner widens instead of resonating - a
    Baxandall-style tone control has no peak at its corner and neither
    should this. }
  FZ2ToneShelfSlope = 0.7;

  { --- Boost mode --- }
  FZ2BoostMaxDb = 25.0;

  { Level fully clockwise. Above unity on purpose: the FZ-2 is loud, and
    "slams the next thing in the chain" is part of what it is for. The taper
    is squared, which is roughly the audio-taper pot the panel has. }
  FZ2MaxOutGain = 1.5;

  { Anti-denormal. Everything from the first gain stage onwards idles on the
    bias offsets and so never reaches zero, but the recursive filters IN
    FRONT of it - the input highpass and the upsampler's cascade - decay all
    the way down on a silent input, and so do the notch and the tone stack
    at the far end. x86 pays roughly two orders of magnitude per denormal
    operation, and at 4x rate that is enough to show up as a CPU step the
    moment a player stops. Applied with an alternating sign so it adds no
    DC, at -400dBFS, and the input highpass removes it immediately anyway. }
  FZ2DenormalOffset = 1E-20;

type
  { Everything one channel needs. Two of these; nothing is shared between
    them but the coefficients. }
  TFZ2ChannelState = record
    InHp: TBiquadState;
    { anti-imaging on the way up, anti-aliasing on the way back down }
    UpAA: array[0..FZ2AAStages - 1] of TBiquadState;
    DownAA: array[0..FZ2AAStages - 1] of TBiquadState;
    { these four all run at the oversampled rate }
    S1Hp, S1Lp, S2Hp, PostLp: TBiquadState;
    RectDcX1, RectDcY1: Single;
    { host rate from here down }
    OutDcX1, OutDcY1: Single;
    Notch: TBiquadState;
    BassSh, TrebleSh: TBiquadState;
  end;

  TFZ2State = record
    Ch: array[0..1] of TFZ2ChannelState;
    InHpCoeffs: TBiquadCoeffs;
    AACoeffs: array[0..FZ2AAStages - 1] of TBiquadCoeffs;
    S1HpCoeffs, S1LpCoeffs, S2HpCoeffs, PostLpCoeffs: TBiquadCoeffs;
    NotchCoeffs: TBiquadCoeffs;
    BassCoeffs, TrebleCoeffs: TBiquadCoeffs;
    RectDcCoeff, OutDcCoeff: Single;
    { cached so the Power() calls behind the knobs only run when a knob
      actually moved, same pattern as the Limiter's threshold }
    Stage1Gain, Stage2Gain, BoostGain: Single;
    { +1/-1, flipped once per host frame - see FZ2DenormalOffset }
    DenormalSign: Single;
    LastGain: Single;
    LastTreble, LastBass: Single;
    LastSampleRate: Integer;
  end;

procedure FZ2Reset(var AState: TFZ2State);

{ One host-rate frame in place. AMode is one of the FZ2Mode* constants;
  AGain/ATreble/ABass/ALevel are the four panel knobs on 0..100, and
  AMixPercent is this program's addition (the pedal has no wet/dry). }
procedure FZ2Process(var AState: TFZ2State; var L, R: Single;
  ASampleRate: Integer; AMode: Integer;
  AGain, ATreble, ABass, ALevel, AMixPercent: Single);

implementation

{ Pade (3,2) rational approximation of tanh, clamped where it would overshoot.
  Within about 0.2% of the real thing across the range that matters and far
  cheaper than the libm call, which is worth caring about here specifically:
  the oversampled block below evaluates three of these per channel per
  sub-sample, i.e. 24 per stereo frame. At |x| >= 3 the numerator and
  denominator meet exactly at 1, so clamping there is continuous. }
function FZ2Tanh(AInput: Single): Single;
var
  x2: Single;
begin
  if AInput >= 3 then
    Exit(1);
  if AInput <= -3 then
    Exit(-1);
  x2 := AInput * AInput;
  Result := AInput * (27 + x2) / (27 + 9 * x2);
end;

{ Back-to-back diode pair. Linear until the diodes start conducting at
  FZ2DiodeKnee, then a tanh shoulder up to a flat +/-1 ceiling. tanh'(0) = 1,
  so the slope is continuous at the corner and the curve has no kink in it
  the way a naive max/min clip does. }
function FZ2DiodeClip(AInput: Single): Single;
var
  Mag, Over: Single;
begin
  Mag := Abs(AInput);
  if Mag <= FZ2DiodeKnee then
    Exit(AInput);
  Over := (Mag - FZ2DiodeKnee) / (1 - FZ2DiodeKnee);
  Mag := FZ2DiodeKnee + (1 - FZ2DiodeKnee) * FZ2Tanh(Over);
  if AInput < 0 then
    Result := -Mag
  else
    Result := Mag;
end;

function FZ2DcBlock(var AX1, AY1: Single; ACoeff, AInput: Single): Single;
begin
  Result := AInput - AX1 + ACoeff * AY1;
  AX1 := AInput;
  AY1 := Result;
end;

procedure FZ2Reset(var AState: TFZ2State);
begin
  FillChar(AState, SizeOf(AState), 0);
  AState.DenormalSign := 1;
  { NaN rather than 0, for the reason Effects.EffectStateReset spells out:
    0 is a legal setting for all three of these knobs and must not look
    "unchanged" against a zeroed field on the very first call, leaving the
    gain/coefficients they feed at their zeroed (silent) defaults. }
  AState.LastGain := NaN;
  AState.LastTreble := NaN;
  AState.LastBass := NaN;
end;

procedure FZ2Setup(var AState: TFZ2State; ASampleRate: Integer);
var
  OsRate, AACutoff: Double;
  k: Integer;
begin
  OsRate := ASampleRate * FZ2Oversample;
  AACutoff := FZ2AACutoffRatio * ASampleRate;

  ComputeHighpassBiquad(FZ2InputHpHz, ASampleRate, 0.707, AState.InHpCoeffs);
  for k := 0 to FZ2AAStages - 1 do
    ComputeLowpassBiquad(AACutoff, OsRate, FZ2AAQ[k], AState.AACoeffs[k]);

  ComputeHighpassBiquad(FZ2InterstageHpHz, OsRate, 0.707, AState.S1HpCoeffs);
  ComputeLowpassBiquad(FZ2InterstageLpHz, OsRate, 0.707, AState.S1LpCoeffs);
  ComputeHighpassBiquad(FZ2InterstageHpHz, OsRate, 0.707, AState.S2HpCoeffs);
  ComputeLowpassBiquad(FZ2PostLpHz, OsRate, 0.707, AState.PostLpCoeffs);

  ComputePeakingBiquad(FZ2NotchHz, ASampleRate, FZ2NotchQ, FZ2NotchDepthDb,
    AState.NotchCoeffs);

  AState.RectDcCoeff := Exp(-2 * Pi * FZ2RectDcBlockHz / OsRate);
  AState.OutDcCoeff := Exp(-2 * Pi * FZ2OutDcBlockHz / ASampleRate);

  AState.Stage2Gain := Power(10, FZ2Stage2Db / 20);
  AState.LastSampleRate := ASampleRate;
end;

{ The whole nonlinear block, start to finish, for one channel and one host
  frame. Everything between the two filter cascades runs FZ2Oversample times. }
function FZ2FuzzChannel(var AState: TFZ2State; var ACh: TFZ2ChannelState;
  AInput: Single; ADenormal: Single): Single;
var
  s, k: Integer;
  x, Sub, Rect, Out_: Single;
begin
  x := ProcessBiquad(ACh.InHp, AState.InHpCoeffs, AInput + ADenormal);
  Out_ := 0;

  for s := 0 to FZ2Oversample - 1 do
  begin
    { Zero-stuff. The x FZ2Oversample puts back the energy the three zero
      samples took out; the cascade below is what turns the stuffed train
      back into a band-limited signal. }
    if s = 0 then
      Sub := x * FZ2Oversample
    else
      Sub := 0;
    for k := 0 to FZ2AAStages - 1 do
      Sub := ProcessBiquad(ACh.UpAA[k], AState.AACoeffs[k], Sub);

    { --- stage 1 --- }
    Sub := ProcessBiquad(ACh.S1Hp, AState.S1HpCoeffs, Sub);
    Sub := FZ2Tanh(Sub * AState.Stage1Gain + FZ2Stage1Bias);
    Sub := ProcessBiquad(ACh.S1Lp, AState.S1LpCoeffs, Sub);

    { --- stage 2 --- }
    Sub := ProcessBiquad(ACh.S2Hp, AState.S2HpCoeffs, Sub);
    Sub := FZ2Tanh(Sub * AState.Stage2Gain + FZ2Stage2Bias);

    { --- the differential pair, run as a full-wave rectifier --- }
    if Sub >= 0 then
      Rect := Sub * FZ2RectPosGain
    else
      Rect := -Sub * FZ2RectNegGain;
    Rect := FZ2DcBlock(ACh.RectDcX1, ACh.RectDcY1, AState.RectDcCoeff, Rect);
    Sub := Sub * (1 - FZ2OctaveMix) + Rect * FZ2OctaveMix;

    { --- back-to-back diodes --- }
    Sub := FZ2DiodeClip(Sub * FZ2DiodeDrive);

    Sub := ProcessBiquad(ACh.PostLp, AState.PostLpCoeffs, Sub);

    for k := 0 to FZ2AAStages - 1 do
      Sub := ProcessBiquad(ACh.DownAA[k], AState.AACoeffs[k], Sub);
    { Decimate by keeping one sub-sample per group. Which one is arbitrary
      as long as it is always the same one - the cascade above has already
      removed everything that would have folded. }
    if s = FZ2Oversample - 1 then
      Out_ := Sub;
  end;

  Result := FZ2DcBlock(ACh.OutDcX1, ACh.OutDcY1, AState.OutDcCoeff, Out_);
end;

procedure FZ2Process(var AState: TFZ2State; var L, R: Single;
  ASampleRate: Integer; AMode: Integer;
  AGain, ATreble, ABass, ALevel, AMixPercent: Single);
var
  c: Integer;
  DryL, DryR, In_, Wet, OutGain, LevelFrac, MixFrac, Denormal: Single;
  Wets: array[0..1] of Single;
begin
  if AState.LastSampleRate <> ASampleRate then
    FZ2Setup(AState, ASampleRate);

  if AGain <> AState.LastGain then
  begin
    AState.Stage1Gain := Power(10,
      (FZ2Stage1MinDb + (AGain / 100) * (FZ2Stage1MaxDb - FZ2Stage1MinDb)) / 20);
    { In Boost mode the same knob is the boost amount instead - the pedal
      has one Gain pot and the mode switch decides what it feeds. }
    AState.BoostGain := Power(10, (AGain / 100) * FZ2BoostMaxDb / 20);
    AState.LastGain := AGain;
  end;
  if ABass <> AState.LastBass then
  begin
    ComputeLowShelfBiquad(FZ2BassHz, ASampleRate, FZ2ToneShelfSlope,
      (ABass - 50) / 50 * FZ2ToneRangeDb, AState.BassCoeffs);
    AState.LastBass := ABass;
  end;
  if ATreble <> AState.LastTreble then
  begin
    ComputeHighShelfBiquad(FZ2TrebleHz, ASampleRate, FZ2ToneShelfSlope,
      (ATreble - 50) / 50 * FZ2ToneRangeDb, AState.TrebleCoeffs);
    AState.LastTreble := ATreble;
  end;

  DryL := L;
  DryR := R;

  AState.DenormalSign := -AState.DenormalSign;
  Denormal := AState.DenormalSign * FZ2DenormalOffset;

  for c := 0 to 1 do
  begin
    if c = 0 then In_ := L else In_ := R;

    if AMode = FZ2ModeBoost then
      { no fuzz circuit in the path at all - the mode switch takes the
        Super-Fuzz out and leaves the makeup amp and the tone stack }
      Wet := In_ * AState.BoostGain
    else
      Wet := FZ2FuzzChannel(AState, AState.Ch[c], In_, Denormal);

    { Second injection point. The notch and the tone stack sit downstream of
      the output DC blocker, so unlike the fuzz block they really do see
      zero on a silent input - and in Boost mode the entire path does. }
    Wet := Wet + Denormal;

    { Fuzz II is Fuzz I through the bridged-T. That IS the difference
      between the two positions - same fuzz, one mid-scoop. }
    if AMode = FZ2ModeFuzz2 then
      Wet := ProcessBiquad(AState.Ch[c].Notch, AState.NotchCoeffs, Wet);

    Wet := ProcessBiquad(AState.Ch[c].BassSh, AState.BassCoeffs, Wet);
    Wet := ProcessBiquad(AState.Ch[c].TrebleSh, AState.TrebleCoeffs, Wet);
    Wets[c] := Wet;
  end;

  LevelFrac := ALevel / 100;
  if LevelFrac < 0 then LevelFrac := 0;
  if LevelFrac > 1 then LevelFrac := 1;
  OutGain := LevelFrac * LevelFrac * FZ2MaxOutGain;

  MixFrac := AMixPercent / 100;
  if MixFrac < 0 then MixFrac := 0;
  if MixFrac > 1 then MixFrac := 1;

  L := DryL * (1 - MixFrac) + Wets[0] * OutGain * MixFrac;
  R := DryR * (1 - MixFrac) + Wets[1] * OutGain * MixFrac;
end;

end.
