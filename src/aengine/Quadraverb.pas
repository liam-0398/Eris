unit Quadraverb;

{$mode objfpc}{$H+}

{ Alesis QuadraVerb (1989) reverb and delay.

  Not a generic reverb with a nostalgic name on it - the structure, the
  parameter ranges and the internal sample rate are all taken from the
  original box, because on a QuadraVerb those three things ARE the sound.
  Parameter ranges below are quoted from the QuadraVerb GT reference manual
  (the GT's reverb/delay algorithms are the original QuadraVerb's); the
  delay-time ceilings are the ones the standard "QuadMode" configuration
  actually offered, not the larger ones you only got by giving up other
  modules.

  Three things make a QuadraVerb sound like a QuadraVerb rather than like a
  clean modern reverb, and all three are modelled here:

  1. It runs its DSP at 31.25 kHz, not 44.1/48. Everything above ~15.6 kHz
     simply does not exist in the wet path, and every delay length in the
     network is quantised to 32 microsecond steps. Running the whole tank at
     the original rate (see TQVRateConv) reproduces both, and it is the
     single biggest reason a QuadraVerb tail sits *behind* a mix instead of
     on top of it.
  2. Its delay memory is 16-bit linear while the DSP accumulates wider. Every
     trip around a comb or a feedback loop goes through that 16-bit round
     trip, so the quantisation noise compounds - hundreds of times over on a
     long tail. That is the "grainy", slightly metallic QuadraVerb texture,
     and it's why the tail dirties as it decays rather than just fading.
     See QVQuantize16.
  3. The dry path never gets digitised at all on the real unit - it runs
     through analog VCAs around the converters. So the dry signal here is
     never band-limited or quantised either; only the wet path is.

  Why this box in this program: it is the atmospheric-jungle reverb. The
  Good Looking / LTJ Bukem sound - long dark halls behind a break, pads
  smeared into a wash, ping-pong delays on stabs - was largely made on
  QuadraVerbs and their Alesis siblings, and it sounds the way it does
  *because* of the band limit and the grain above, not in spite of them.
  Parameters the original had but that side of the music never used (the
  reverb gate and its hold/release/gated-level pages, the multi-tap delay,
  the internal module routing/input-mix matrix) are deliberately not
  implemented - see the README of this unit's effects in
  documentation/usage.md. }

interface

uses
  Math, BiquadFilters;

const
  { The original's internal DSP rate. Nyquist 15.625 kHz - the published
    "16Hz-20kHz" bandwidth was measured through the analog dry path, not the
    effect path. }
  QVSampleRate = 31250;
  { anti-alias / reconstruction corner, just under that Nyquist. Two
    cascaded biquads per side; deliberately not a brickwall, because the
    original's own converter filters weren't either and the leftover
    top-octave slop is part of the texture. }
  QVAntiAliasHz = 14000.0;

  { Reverb types. The original's five, in its own order. (Plate 2 / Room 2 /
    Chamber 2 / Hall 2 on the real unit are the same algorithms given more
    DSP in configurations that spend fewer modules, not different sounds -
    there is only one configuration here, so there is nothing to pick.) }
  QVReverbPlate = 0;
  QVReverbRoom = 1;
  QVReverbChamber = 2;
  QVReverbHall = 3;
  QVReverbReverse = 4;
  QVReverbTypeCount = 5;
  QVReverbTypeNames: array[0..QVReverbTypeCount - 1] of string =
    ('Plate', 'Room', 'Chamber', 'Hall', 'Reverse');

  QVDelayMono = 0;
  QVDelayStereo = 1;
  QVDelayPingPong = 2;
  QVDelayTypeCount = 3;
  QVDelayTypeNames: array[0..QVDelayTypeCount - 1] of string =
    ('Mono', 'Stereo', 'Ping-Pong');

  { Parameter ranges, all straight off the original's front panel. }
  QVPredelayMinMs = 1;
  QVPredelayMaxMs = 140;
  { "PRE <-99 ... 00 ... 99-> POST": -99 feeds the tank only the
    non-predelayed signal, +99 only the predelayed one, 00 mixes equally }
  QVPredelayMixMin = -99;
  QVPredelayMixMax = 99;
  QVDecayMin = 0;
  QVDecayMax = 99;
  QVDiffusionMin = 1;
  QVDiffusionMax = 9;
  QVDensityMin = 1;
  QVDensityMax = 9;
  { Low/High Frequency Decay are "always a negative number since this
    parameter shortens the time of reverb with [that] frequency content
    compared to the master reverb decay time" (manual). 0 = that band decays
    at the master rate; -99 = as short as the box will make it. }
  QVBandDecayMin = -99;
  QVBandDecayMax = 0;

  { QuadMode delay ceilings: mono gets one line so it gets twice the time. }
  QVDelayMonoMaxMs = 800;
  QVDelayStereoMaxMs = 400;
  QVDelayFeedbackMax = 99;

  { network sizes }
  QVCombCount = 6;
  QVDiffuserCount = 4;
  QVTailAllpassCount = 3;

type
  TQVDelayLine = record
    Buf: array of Single;
    Pos: Integer;
  end;

  { A Schroeder comb with BOTH bands damped in its feedback path, which is
    what the original's separate Low/High Frequency Decay pages need: one
    one-pole lowpass to make the highs decay faster than the master rate,
    and one low-band tap subtracted back out to make the lows decay faster.
    Either can be left at unity independently. }
  TQVComb = record
    Buf: array of Single;
    Pos: Integer;
    LpStore: Single;
    LfStore: Single;
  end;

  TQVAllpass = record
    Buf: array of Single;
    Pos: Integer;
  end;

  { Host rate <-> QVSampleRate conversion for the wet path. Band-limit at
    host rate, decimate by running the tank on only ~71% of host frames
    (44100 -> 31250), then linearly interpolate back up and band-limit
    again. Linear interpolation on the way back out is deliberate and in
    keeping with the rest of this program (see CLAUDE.md on resampling) -
    it is also roughly what a 1989 converter reconstruction path did. }
  TQVRateConv = record
    Phase: Double;
    Ratio: Double;
    Coeffs: TBiquadCoeffs;
    InAa: array[0..1, 0..1] of TBiquadState;  { [channel][stage] }
    OutAa: array[0..1, 0..1] of TBiquadState;
    PrevOut: array[0..1] of Single;
    CurOut: array[0..1] of Single;
    LastHostRate: Integer;
  end;

  TQVReverbState = record
    Conv: TQVRateConv;
    Predelay: TQVDelayLine;
    DensityLine: TQVDelayLine;
    Diff: array[0..1, 0..QVDiffuserCount - 1] of TQVAllpass;
    Comb: array[0..1, 0..QVCombCount - 1] of TQVComb;
    Tail: array[0..1, 0..QVTailAllpassCount - 1] of TQVAllpass;
    { everything below is derived from the front-panel parameters and only
      recomputed when one of them actually moves - see QVReverbUpdate }
    LastType: Integer;
    LastDecay: Single;
    LastDiffusion: Single;
    LastDensity: Single;
    LastLowDecay: Single;
    LastHighDecay: Single;
    CombFeedback: array[0..1, 0..QVCombCount - 1] of Single;
    CombLpCoeff: array[0..1, 0..QVCombCount - 1] of Single;
    LfSplitCoeff: Single;
    LfCut: Single;
    DiffCoeff: Single;
    DensityGapSamples: Integer;
    { Reverse type only }
    ReverseRamp: Single;
    ReverseStep: Single;
    ReverseActive: Boolean;
  end;

  TQVDelayState = record
    Conv: TQVRateConv;
    Line: array[0..1] of TQVDelayLine;
  end;

procedure QVReverbReset(var AState: TQVReverbState);
procedure QVDelayReset(var AState: TQVDelayState);

{ Both process one host-rate frame in place. AMixPercent is the original's
  Reverb/Delay Output Level expressed as an insert dry/wet, since an insert
  slot has no separate direct-level page to balance it against. }
procedure QVReverbProcess(var AState: TQVReverbState; var L, R: Single;
  AHostRate, AReverbType: Integer; APredelayMs, APredelayMix, ADecay,
  ADiffusion, ADensity, ALowDecay, AHighDecay, AMixPercent: Single);

procedure QVDelayProcess(var AState: TQVDelayState; var L, R: Single;
  AHostRate, ADelayType: Integer; ATimeLMs, ATimeRMs, AFeedbackL,
  AFeedbackR, AMixPercent: Single);

{ Ceiling for a delay type, in ms - the original's own QuadMode limits. }
function QVDelayMaxMs(ADelayType: Integer): Integer;

implementation

const
  { Comb/diffuser/tail tunings per reverb type, in ms. Mutually prime-ish
    lengths so the network doesn't develop a periodic ring. The type is what
    sets the SIZE and spacing of the space; Decay separately sets how long
    it rings, so switching type at a fixed Decay changes the character
    without changing the length of the tail. }
  QVCombMs: array[0..QVReverbTypeCount - 1, 0..QVCombCount - 1] of Single = (
    (22.1, 25.7, 28.3, 31.9, 34.7, 37.3),   { Plate - small, tight, dense }
    (27.3, 31.1, 35.9, 39.7, 43.1, 47.3),   { Room }
    (33.1, 38.3, 43.7, 48.1, 53.9, 58.7),   { Chamber }
    (44.9, 51.7, 58.3, 65.1, 71.9, 79.3),   { Hall - large and slow }
    (33.1, 38.3, 43.7, 48.1, 53.9, 58.7));  { Reverse - Chamber's tank }

  QVDiffuserMs: array[0..QVReverbTypeCount - 1, 0..QVDiffuserCount - 1] of Single = (
    (4.7, 6.1, 8.3, 11.9),
    (5.9, 7.7, 10.3, 13.7),
    (7.1, 9.7, 12.9, 16.3),
    (9.7, 13.1, 17.3, 22.9),
    (7.1, 9.7, 12.9, 16.3));

  QVTailMs: array[0..QVReverbTypeCount - 1, 0..QVTailAllpassCount - 1] of Single = (
    (3.1, 5.3, 7.9),
    (3.7, 6.1, 9.1),
    (4.3, 7.3, 10.7),
    (5.9, 9.7, 13.9),
    (4.3, 7.3, 10.7));

  { how long each type rings at a given Decay setting, relative to Hall }
  QVDecayScale: array[0..QVReverbTypeCount - 1] of Single =
    (0.70, 0.60, 0.85, 1.00, 0.85);

  { right-channel delay lengths are offset by this much so the two sides
    decorrelate into a stereo image - the same trick the existing Basic
    Reverb uses, and what the original's stereo output taps do }
  QVStereoSpreadMs = 0.73;

  { Decay 00-99 maps exponentially onto RT60. 99 on a Hall is ~10s, which is
    about where the real unit tops out and well into the territory the
    atmospheric-jungle records live in. }
  QVDecayMinSeconds = 0.25;
  QVDecayRange = 40.0;
  QVCombFeedbackMax = 0.97;

  { how far Low/High Frequency Decay at -99 can shorten their band }
  QVBandDecayDepth = 0.93;
  { crossover the low-band damping works below }
  QVLfSplitHz = 500.0;

  { Density 1-9 sets the gap between the first reflection and the body of
    the reverb: "at the maximum setting of 9, the reverb will seem to
    explode since the first reflection will no longer be perceived as a
    separate echo" (manual). }
  QVDensityMaxGapMs = 55.0;
  QVDensityMinGapMs = 2.0;
  { Hall has no Density page on the real unit, so it gets a fixed gap }
  QVHallGapMs = 18.0;

  { Diffusion 1-9 -> allpass coefficient. Low settings leave the individual
    echoes audible, high settings smear them together. }
  QVDiffusionMinCoeff = 0.20;
  QVDiffusionMaxCoeff = 0.75;

  { Reverse: Decay becomes Reverse Time, the length of the swell. }
  QVReverseMinMs = 100.0;
  QVReverseMaxMs = 1500.0;
  QVReverseTriggerLevel = 0.03; { ~-30 dBFS }
  { don't re-arm on the same attack - only once the swell is properly under
    way can a new transient restart it }
  QVReverseRetriggerPoint = 0.10;

  QVPredelayBufMs = QVPredelayMaxMs + 2;
  QVDensityBufMs = 64;

function QVDelayMaxMs(ADelayType: Integer): Integer;
begin
  if ADelayType = QVDelayMono then
    Result := QVDelayMonoMaxMs
  else
    Result := QVDelayStereoMaxMs;
end;

function QVMsToSamples(AMs: Single): Integer;
begin
  Result := Round(AMs * QVSampleRate / 1000);
  if Result < 1 then
    Result := 1;
end;

{ 16-bit linear, the width of the original's delay memory. Applied on every
  write into every delay line, so a signal circulating in a comb or a
  feedback loop is re-quantised on each pass and the error accumulates -
  which is the point. Clamped rather than wrapped: the real converter
  clipped, it didn't fold over. }
function QVQuantize16(AValue: Single): Single;
begin
  if AValue > 1.0 then
    AValue := 1.0
  else if AValue < -1.0 then
    AValue := -1.0;
  Result := Round(AValue * 32768) / 32768;
end;

procedure QVLineAlloc(var ALine: TQVDelayLine; ALengthMs: Single);
var
  Len: Integer;
begin
  Len := QVMsToSamples(ALengthMs) + 1;
  SetLength(ALine.Buf, Len);
  FillChar(ALine.Buf[0], Len * SizeOf(Single), 0);
  ALine.Pos := 0;
end;

procedure QVLineWrite(var ALine: TQVDelayLine; AValue: Single);
begin
  ALine.Buf[ALine.Pos] := QVQuantize16(AValue);
  Inc(ALine.Pos);
  if ALine.Pos >= Length(ALine.Buf) then
    ALine.Pos := 0;
end;

{ Fractional read back from a line, in samples behind the write head.
  Linearly interpolated so a delay time between two whole QV-rate samples
  doesn't have to snap to one of them. }
function QVLineRead(const ALine: TQVDelayLine; ADelaySamples: Double): Single;
var
  Len, i0, i1: Integer;
  Pos: Double;
  Frac: Double;
begin
  Len := Length(ALine.Buf);
  if Len <= 0 then
    Exit(0);
  if ADelaySamples > Len - 1 then
    ADelaySamples := Len - 1;
  if ADelaySamples < 0 then
    ADelaySamples := 0;
  Pos := ALine.Pos - ADelaySamples;
  while Pos < 0 do
    Pos := Pos + Len;
  i0 := Trunc(Pos) mod Len;
  Frac := Pos - Trunc(Pos);
  i1 := (i0 + 1) mod Len;
  Result := ALine.Buf[i0] * (1 - Frac) + ALine.Buf[i1] * Frac;
end;

procedure QVCombAlloc(var AComb: TQVComb; ALengthMs: Single);
var
  Len: Integer;
begin
  Len := QVMsToSamples(ALengthMs);
  SetLength(AComb.Buf, Len);
  FillChar(AComb.Buf[0], Len * SizeOf(Single), 0);
  AComb.Pos := 0;
  AComb.LpStore := 0;
  AComb.LfStore := 0;
end;

function QVProcessComb(var AComb: TQVComb; AInput, AFeedback, ALpCoeff,
  ALfSplitCoeff, ALfCut: Single): Single;
var
  Damped: Single;
begin
  Result := AComb.Buf[AComb.Pos];

  { high-frequency decay: one-pole lowpass, unity at DC, so the top of the
    tail dies away sooner than the master decay time }
  AComb.LpStore := Result * (1 - ALpCoeff) + AComb.LpStore * ALpCoeff;
  Damped := AComb.LpStore;

  { low-frequency decay: take the sub-QVLfSplitHz content and subtract part
    of it back out, which shortens the low band without touching the highs.
    LfCut = 0 leaves the lows at the master rate. }
  AComb.LfStore := AComb.LfStore * ALfSplitCoeff + Damped * (1 - ALfSplitCoeff);
  Damped := Damped - ALfCut * AComb.LfStore;

  AComb.Buf[AComb.Pos] := QVQuantize16(AInput + Damped * AFeedback);
  Inc(AComb.Pos);
  if AComb.Pos >= Length(AComb.Buf) then
    AComb.Pos := 0;
end;

procedure QVAllpassAlloc(var AAp: TQVAllpass; ALengthMs: Single);
var
  Len: Integer;
begin
  Len := QVMsToSamples(ALengthMs);
  SetLength(AAp.Buf, Len);
  FillChar(AAp.Buf[0], Len * SizeOf(Single), 0);
  AAp.Pos := 0;
end;

{ Schroeder allpass with a settable coefficient - the coefficient is
  Diffusion, which is why low Diffusion lets you hear the individual echoes
  and high Diffusion blends them into a wash.

  This is the TRUE allpass form, y[n] = w[n-M] - g*w[n] over
  w[n] = x[n] + g*w[n-M], and it has to be: the numerator is then the mirror
  of the denominator, so |H| is exactly 1 at every frequency for any g.

  The form Freeverb uses (and that ekReverb's ProcessAllpass above uses)
  subtracts g*x[n] rather than g*w[n], which is only unity-gain at the one
  coefficient Freeverb hardcodes, g = 0.5. Its DC gain is g/(1-g) - fine at
  0.5, but 3x at the 0.75 the top of the Diffusion range wants, compounding
  to about +40dB across four diffusers in series. Diffusion has to be
  sweepable here, so it needs the form that stays unity across the sweep. }
function QVProcessAllpass(var AAp: TQVAllpass; AInput, ACoeff: Single): Single;
var
  BufOut, W: Single;
begin
  BufOut := AAp.Buf[AAp.Pos];
  W := AInput + BufOut * ACoeff;
  Result := BufOut - W * ACoeff;
  AAp.Buf[AAp.Pos] := QVQuantize16(W);
  Inc(AAp.Pos);
  if AAp.Pos >= Length(AAp.Buf) then
    AAp.Pos := 0;
end;

procedure QVConvReset(var AConv: TQVRateConv);
begin
  FillChar(AConv, SizeOf(AConv), 0);
  AConv.LastHostRate := 0;
  AConv.Ratio := 1;
end;

procedure QVConvSetup(var AConv: TQVRateConv; AHostRate: Integer);
begin
  if AConv.LastHostRate = AHostRate then
    Exit;
  ComputeLowpassBiquad(QVAntiAliasHz, AHostRate, 0.707, AConv.Coeffs);
  if AHostRate <= QVSampleRate then
    AConv.Ratio := 1
  else
    AConv.Ratio := QVSampleRate / AHostRate;
  AConv.Phase := 0;
  AConv.LastHostRate := AHostRate;
end;

function QVConvFilterIn(var AConv: TQVRateConv; AChannel: Integer;
  AInput: Single): Single;
begin
  Result := ProcessBiquad(AConv.InAa[AChannel, 0], AConv.Coeffs, AInput);
  Result := ProcessBiquad(AConv.InAa[AChannel, 1], AConv.Coeffs, Result);
end;

function QVConvFilterOut(var AConv: TQVRateConv; AChannel: Integer;
  AInput: Single): Single;
begin
  Result := ProcessBiquad(AConv.OutAa[AChannel, 0], AConv.Coeffs, AInput);
  Result := ProcessBiquad(AConv.OutAa[AChannel, 1], AConv.Coeffs, Result);
end;

{ True when this host frame is the one that advances the QV-rate clock.
  Ratio is below 1 at any sane host rate, so this fires on ~71% of frames at
  44.1kHz and never twice for one frame. }
function QVConvTickDue(var AConv: TQVRateConv): Boolean;
begin
  AConv.Phase := AConv.Phase + AConv.Ratio;
  Result := AConv.Phase >= 1;
  if Result then
    AConv.Phase := AConv.Phase - 1;
end;

function QVConvInterpolate(const AConv: TQVRateConv; AChannel: Integer): Single;
begin
  Result := AConv.PrevOut[AChannel] +
    (AConv.CurOut[AChannel] - AConv.PrevOut[AChannel]) * AConv.Phase;
end;

procedure QVReverbReset(var AState: TQVReverbState);
begin
  FillChar(AState, SizeOf(AState), 0);
  QVConvReset(AState.Conv);
  { -1 rather than 0: 0 is a real reverb type (Plate) and would look
    already-built before anything had actually been allocated }
  AState.LastType := -1;
  AState.LastDecay := NaN;
  AState.LastDiffusion := NaN;
  AState.LastDensity := NaN;
  AState.LastLowDecay := NaN;
  AState.LastHighDecay := NaN;
end;

procedure QVDelayReset(var AState: TQVDelayState);
begin
  FillChar(AState, SizeOf(AState), 0);
  QVConvReset(AState.Conv);
end;

procedure QVReverbAllocate(var AState: TQVReverbState; AType: Integer);
var
  c, ch: Integer;
  Spread: Single;
begin
  if AState.Predelay.Buf = nil then
  begin
    QVLineAlloc(AState.Predelay, QVPredelayBufMs);
    QVLineAlloc(AState.DensityLine, QVDensityBufMs);
  end;
  for ch := 0 to 1 do
  begin
    if ch = 1 then
      Spread := QVStereoSpreadMs
    else
      Spread := 0;
    for c := 0 to QVCombCount - 1 do
      QVCombAlloc(AState.Comb[ch, c], QVCombMs[AType, c] + Spread);
    for c := 0 to QVDiffuserCount - 1 do
      QVAllpassAlloc(AState.Diff[ch, c], QVDiffuserMs[AType, c] + Spread);
    for c := 0 to QVTailAllpassCount - 1 do
      QVAllpassAlloc(AState.Tail[ch, c], QVTailMs[AType, c] + Spread);
  end;
end;

{ Recomputes every derived coefficient from the front-panel values. Only
  called when one of them actually moved, so turning a knob is cheap and
  holding it still costs nothing. }
procedure QVReverbUpdate(var AState: TQVReverbState; AType: Integer;
  ADecay, ADiffusion, ADensity, ALowDecay, AHighDecay: Single);
var
  ch, c: Integer;
  Rt60, LenSec, g, Ratio, GapMs: Single;
  HfRatio, LfRatio, gBand, r: Single;
begin
  Rt60 := QVDecayMinSeconds * Power(QVDecayRange, ADecay / QVDecayMax) *
    QVDecayScale[AType];
  { Reverse doesn't ring out on its own - the swell envelope defines its
    length, so the tank underneath it is tied to Reverse Time instead }
  if AType = QVReverbReverse then
    Rt60 := 0.8 * (QVReverseMinMs + (ADecay / QVDecayMax) *
      (QVReverseMaxMs - QVReverseMinMs)) / 1000;
  if Rt60 < 0.05 then
    Rt60 := 0.05;

  HfRatio := 1 - QVBandDecayDepth * (Abs(AHighDecay) / 99);
  LfRatio := 1 - QVBandDecayDepth * (Abs(ALowDecay) / 99);
  if HfRatio < 0.02 then HfRatio := 0.02;
  if LfRatio < 0.02 then LfRatio := 0.02;

  for ch := 0 to 1 do
    for c := 0 to QVCombCount - 1 do
    begin
      LenSec := Length(AState.Comb[ch, c].Buf) / QVSampleRate;
      { the feedback that gives this comb length the requested RT60 }
      g := Power(10, -3 * LenSec / Rt60);
      if g > QVCombFeedbackMax then
        g := QVCombFeedbackMax;
      AState.CombFeedback[ch, c] := g;

      { the same comb wants a SMALLER feedback at high frequencies to hit
        the shortened HF RT60; the one-pole in its loop has to supply
        exactly that ratio at Nyquist, which for a one-pole of coefficient a
        is (1-a)/(1+a) }
      gBand := Power(10, -3 * LenSec / (Rt60 * HfRatio));
      r := gBand / g;
      if r > 0.999 then r := 0.999;
      if r < 0.001 then r := 0.001;
      AState.CombLpCoeff[ch, c] := (1 - r) / (1 + r);
      if AState.CombLpCoeff[ch, c] > 0.95 then
        AState.CombLpCoeff[ch, c] := 0.95;
    end;

  { the low band is shared across combs - a single subtract-back amount,
    since it only has to be approximately right to read as "the lows die
    first" (the front panel offers one number for it, not one per comb) }
  LenSec := Length(AState.Comb[0, 0].Buf) / QVSampleRate;
  g := Power(10, -3 * LenSec / Rt60);
  gBand := Power(10, -3 * LenSec / (Rt60 * LfRatio));
  Ratio := gBand / g;
  if Ratio > 1 then Ratio := 1;
  if Ratio < 0 then Ratio := 0;
  AState.LfCut := 1 - Ratio;
  AState.LfSplitCoeff := Exp(-2 * Pi * QVLfSplitHz / QVSampleRate);

  AState.DiffCoeff := QVDiffusionMinCoeff +
    ((ADiffusion - QVDiffusionMin) / (QVDiffusionMax - QVDiffusionMin)) *
    (QVDiffusionMaxCoeff - QVDiffusionMinCoeff);

  if AType = QVReverbHall then
    GapMs := QVHallGapMs
  else
    GapMs := QVDensityMaxGapMs -
      ((ADensity - QVDensityMin) / (QVDensityMax - QVDensityMin)) *
      (QVDensityMaxGapMs - QVDensityMinGapMs);
  AState.DensityGapSamples := QVMsToSamples(GapMs);

  AState.ReverseStep := 1 / ((QVReverseMinMs + (ADecay / QVDecayMax) *
    (QVReverseMaxMs - QVReverseMinMs)) * QVSampleRate / 1000);
end;

{ One QV-rate tick of the reverb. }
procedure QVReverbTick(var AState: TQVReverbState; AInL, AInR: Single;
  AType: Integer; APredelayMs, APredelayMix: Single; out AOutL, AOutR: Single);
var
  Mono, Pre, Post, TankIn, Early, Body, Wet: Single;
  PostFrac, PreFrac: Single;
  ch, c: Integer;
  Sum: Single;
  Outs: array[0..1] of Single;
begin
  { the tank is mono-in / stereo-out, as it is on the original - the stereo
    image comes from the two output sides being detuned against each other,
    not from carrying the input's own stereo through }
  Mono := (AInL + AInR) * 0.5;

  Post := QVLineRead(AState.Predelay, QVMsToSamples(APredelayMs));
  QVLineWrite(AState.Predelay, Mono);
  Pre := Mono;

  { Predelay Mix: -99 = only the non-predelayed signal feeds the tank,
    0 = both equally, +99 = only the predelayed one }
  PostFrac := 0.5 + (APredelayMix / 99) * 0.5;
  if PostFrac < 0 then PostFrac := 0;
  if PostFrac > 1 then PostFrac := 1;
  PreFrac := 1 - PostFrac;
  TankIn := Post * PostFrac + Pre * PreFrac;

  { Density: the first reflection comes out immediately, the body of the
    reverb is held back by the gap. Small Density = an audible separate
    echo then the wash; large Density = they merge and it "explodes". }
  Early := TankIn;
  Body := QVLineRead(AState.DensityLine, AState.DensityGapSamples);
  QVLineWrite(AState.DensityLine, TankIn);

  for ch := 0 to 1 do
  begin
    { diffuser chain first - this is what turns a handful of discrete
      echoes into a wash before the tank ever sees it }
    Wet := Body;
    for c := 0 to QVDiffuserCount - 1 do
      Wet := QVProcessAllpass(AState.Diff[ch, c], Wet, AState.DiffCoeff);

    Sum := 0;
    for c := 0 to QVCombCount - 1 do
      Sum := Sum + QVProcessComb(AState.Comb[ch, c], Wet,
        AState.CombFeedback[ch, c], AState.CombLpCoeff[ch, c],
        AState.LfSplitCoeff, AState.LfCut);
    Sum := Sum / QVCombCount;

    for c := 0 to QVTailAllpassCount - 1 do
      Sum := QVProcessAllpass(AState.Tail[ch, c], Sum, 0.5);

    Outs[ch] := Sum + Early * 0.3;
  end;

  if AType = QVReverbReverse then
  begin
    { "reflections get louder over time, until they are cut off upon
      reaching a maximum volume level" (manual) - a ramp from silence to
      full over Reverse Time, then killed dead, retriggered by the next
      transient }
    if (Abs(Mono) > QVReverseTriggerLevel) and
      ((not AState.ReverseActive) or (AState.ReverseRamp > QVReverseRetriggerPoint)) then
    begin
      AState.ReverseActive := True;
      AState.ReverseRamp := 0;
    end;
    if AState.ReverseActive then
    begin
      AState.ReverseRamp := AState.ReverseRamp + AState.ReverseStep;
      if AState.ReverseRamp >= 1 then
      begin
        AState.ReverseRamp := 0;
        AState.ReverseActive := False;
      end;
    end;
    Outs[0] := Outs[0] * AState.ReverseRamp;
    Outs[1] := Outs[1] * AState.ReverseRamp;
  end;

  AOutL := Outs[0];
  AOutR := Outs[1];
end;

procedure QVReverbProcess(var AState: TQVReverbState; var L, R: Single;
  AHostRate, AReverbType: Integer; APredelayMs, APredelayMix, ADecay,
  ADiffusion, ADensity, ALowDecay, AHighDecay, AMixPercent: Single);
var
  DryL, DryR, InL, InR, WetL, WetR, MixFrac: Single;
begin
  if (AReverbType < 0) or (AReverbType >= QVReverbTypeCount) then
    AReverbType := QVReverbHall;

  QVConvSetup(AState.Conv, AHostRate);
  if AState.LastType <> AReverbType then
  begin
    QVReverbAllocate(AState, AReverbType);
    AState.LastType := AReverbType;
    { comb lengths just changed, so every feedback coefficient derived from
      them is stale - force the update below to run }
    AState.LastDecay := NaN;
  end;
  if (ADecay <> AState.LastDecay) or (ADiffusion <> AState.LastDiffusion) or
    (ADensity <> AState.LastDensity) or (ALowDecay <> AState.LastLowDecay) or
    (AHighDecay <> AState.LastHighDecay) then
  begin
    QVReverbUpdate(AState, AReverbType, ADecay, ADiffusion, ADensity,
      ALowDecay, AHighDecay);
    AState.LastDecay := ADecay;
    AState.LastDiffusion := ADiffusion;
    AState.LastDensity := ADensity;
    AState.LastLowDecay := ALowDecay;
    AState.LastHighDecay := AHighDecay;
  end;

  { the dry path is never band-limited or quantised - on the real unit it
    doesn't go through the converters at all }
  DryL := L;
  DryR := R;

  InL := QVConvFilterIn(AState.Conv, 0, L);
  InR := QVConvFilterIn(AState.Conv, 1, R);

  if QVConvTickDue(AState.Conv) then
  begin
    AState.Conv.PrevOut[0] := AState.Conv.CurOut[0];
    AState.Conv.PrevOut[1] := AState.Conv.CurOut[1];
    QVReverbTick(AState, InL, InR, AReverbType, APredelayMs, APredelayMix,
      AState.Conv.CurOut[0], AState.Conv.CurOut[1]);
  end;

  WetL := QVConvFilterOut(AState.Conv, 0, QVConvInterpolate(AState.Conv, 0));
  WetR := QVConvFilterOut(AState.Conv, 1, QVConvInterpolate(AState.Conv, 1));

  MixFrac := AMixPercent / 100;
  if MixFrac < 0 then MixFrac := 0;
  if MixFrac > 1 then MixFrac := 1;
  L := DryL * (1 - MixFrac) + WetL * MixFrac;
  R := DryR * (1 - MixFrac) + WetR * MixFrac;
end;

procedure QVDelayTick(var AState: TQVDelayState; AInL, AInR: Single;
  ADelayType: Integer; ATimeLMs, ATimeRMs, AFeedbackL, AFeedbackR: Single;
  out AOutL, AOutR: Single);
var
  Mono, TapL, TapR, FbL, FbR: Single;
begin
  FbL := AFeedbackL / 100;
  FbR := AFeedbackR / 100;
  if FbL > 0.99 then FbL := 0.99;
  if FbR > 0.99 then FbR := 0.99;

  case ADelayType of
    QVDelayStereo:
      begin
        { two completely independent lines - set them to different times for
          the polyrhythmic repeats the manual points at }
        TapL := QVLineRead(AState.Line[0], ATimeLMs * QVSampleRate / 1000);
        TapR := QVLineRead(AState.Line[1], ATimeRMs * QVSampleRate / 1000);
        QVLineWrite(AState.Line[0], AInL + TapL * FbL);
        QVLineWrite(AState.Line[1], AInR + TapR * FbR);
      end;
    QVDelayPingPong:
      begin
        { the repeat bounces L->R->L: the left line feeds the right one, and
          only the right line's output comes back round through Feedback, so
          one trip round the loop is two delay times. The right-hand Time and
          Feedback pages don't exist in this mode on the real unit, so this
          uses the left ones for both. }
        TapL := QVLineRead(AState.Line[0], ATimeLMs * QVSampleRate / 1000);
        TapR := QVLineRead(AState.Line[1], ATimeLMs * QVSampleRate / 1000);
        Mono := (AInL + AInR) * 0.5;
        QVLineWrite(AState.Line[0], Mono + TapR * FbL);
        QVLineWrite(AState.Line[1], TapL);
      end;
  else
    { QVDelayMono - one line, same signal to both outputs, and because it's
      one line it gets twice the maximum time }
    Mono := (AInL + AInR) * 0.5;
    TapL := QVLineRead(AState.Line[0], ATimeLMs * QVSampleRate / 1000);
    QVLineWrite(AState.Line[0], Mono + TapL * FbL);
    TapR := TapL;
  end;

  AOutL := TapL;
  AOutR := TapR;
end;

procedure QVDelayProcess(var AState: TQVDelayState; var L, R: Single;
  AHostRate, ADelayType: Integer; ATimeLMs, ATimeRMs, AFeedbackL,
  AFeedbackR, AMixPercent: Single);
var
  DryL, DryR, InL, InR, WetL, WetR, MixFrac: Single;
  MaxMs: Integer;
begin
  QVConvSetup(AState.Conv, AHostRate);
  if AState.Line[0].Buf = nil then
  begin
    { both lines are sized for the mono ceiling so switching type at runtime
      never has to reallocate on the audio thread }
    QVLineAlloc(AState.Line[0], QVDelayMonoMaxMs);
    QVLineAlloc(AState.Line[1], QVDelayMonoMaxMs);
  end;

  MaxMs := QVDelayMaxMs(ADelayType);
  if ATimeLMs > MaxMs then ATimeLMs := MaxMs;
  if ATimeRMs > MaxMs then ATimeRMs := MaxMs;
  if ATimeLMs < 1 then ATimeLMs := 1;
  if ATimeRMs < 1 then ATimeRMs := 1;

  DryL := L;
  DryR := R;

  InL := QVConvFilterIn(AState.Conv, 0, L);
  InR := QVConvFilterIn(AState.Conv, 1, R);

  if QVConvTickDue(AState.Conv) then
  begin
    AState.Conv.PrevOut[0] := AState.Conv.CurOut[0];
    AState.Conv.PrevOut[1] := AState.Conv.CurOut[1];
    QVDelayTick(AState, InL, InR, ADelayType, ATimeLMs, ATimeRMs,
      AFeedbackL, AFeedbackR, AState.Conv.CurOut[0], AState.Conv.CurOut[1]);
  end;

  WetL := QVConvFilterOut(AState.Conv, 0, QVConvInterpolate(AState.Conv, 0));
  WetR := QVConvFilterOut(AState.Conv, 1, QVConvInterpolate(AState.Conv, 1));

  MixFrac := AMixPercent / 100;
  if MixFrac < 0 then MixFrac := 0;
  if MixFrac > 1 then MixFrac := 1;
  L := DryL * (1 - MixFrac) + WetL * MixFrac;
  R := DryR * (1 - MixFrac) + WetR * MixFrac;
end;

end.
