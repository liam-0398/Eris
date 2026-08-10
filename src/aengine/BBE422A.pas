unit BBE422A;

{$mode objfpc}{$H+}

{ BBE Sonic Maximizer 422A - the cheap half-rack two-channel RCA one that
  ended up in front of half the DAT machines in the country.

  Not a treble EQ with a nostalgic name on it. The BBE process is two things
  happening at once, and the first one is the part everybody forgets:

  1. THREE-BAND TIME ALIGNMENT. The signal is split at 150Hz and 1200Hz, and
     the two lower bands are pushed BACKWARDS in time relative to the top -
     the low group by about 2.5ms (group delay through a passive low-pass in
     the original), the mid group by about 0.5ms (through an active
     band-pass). The high group is the reference and is not delayed at all.
     BBE's claim is that this un-does the phase smear a loudspeaker adds; the
     part that matters here is that recombining three bands that no longer
     line up is NOT a flat operation, and the not-flatness is the sound. The
     transient of a break arrives top-first, and the low end of the same hit
     lands a fifth of a 1/32-note later.

  2. DYNAMIC AMPLITUDE COMPENSATION. The high band runs through a VCA whose
     control voltage comes from RMS loudness detectors watching the mid and
     high bands and comparing them. The box has a target ratio between the
     two and continuously drives the top band towards it - so it is a program
     dependent dynamic EQ, not a shelf. On the original's front panel this
     shows on three LEDs: red when the high band was too loud and is being
     compressed, green when it was too quiet and is being expanded, amber
     when it is already where the box wants it. See BBE422Process.

  Lo Contour is separate from both: a tight bump at 50Hz inside the
  (delayed) low band, -12dB fully counter-clockwise to +10dB fully clockwise,
  per the 422A manual.

  Why this box in this program: it is the jungle mastering-chain cheat code.
  A 422A across the two-track is what made a lot of mid-90s atmospheric
  records sound like the break was in front of the pads rather than buried
  in them - the top of the break arrives first and the sub arrives late, so
  the hats and the ride crack over a wash that is physically behind them,
  and Lo Contour puts the weight back at 50Hz where the sub lives. Used on
  the master bus and directly on breaks in about equal measure.

  Deliberately NOT implemented, being things this side of the music never
  touched:
  - Per-channel independent Lo Contour and Definition. The 422A is two
    genuinely separate mono channels; nobody processing a stereo mix ever
    wanted them set differently, and the detector below is linked across L/R
    for the same reason ekLimiter's is - so the process can't shift the
    stereo image.
  - The status/clip LEDs, the In-Out switch (a chain slot and a Mix control
    already cover it) and the +16dBu input clip point, which nothing inside
    a float DAW insert is going to reach.
  - The rear-panel remote jack and the -10dBV/+4dBu level matching. }

interface

uses
  Math, BiquadFilters;

const
  { The original's own crossover points. }
  BBELowXoverHz = 150.0;
  BBEHighXoverHz = 1200.0;
  { Cascaded pairs of Butterworth sections (24dB/oct) rather than single
    biquads. Band separation matters more here than in a normal crossover:
    the bands are deliberately time-offset from each other, so anything that
    leaks across a corner arrives twice at two different times and combs. }
  BBEXoverQ = 0.707;

  { Group delays relative to the high band, which is the reference and is
    not delayed. }
  BBELowDelayMs = 2.5;
  BBEMidDelayMs = 0.5;

  { Lo Contour: "regulates the amount of phase compensated bass
    equalization... -12dBu fully counter-clockwise to +10dBu fully
    clockwise at 50Hz" (422A manual). Asymmetric on purpose - that's the
    panel. Q is high enough to stay a bump at 50 rather than a shelf. }
  BBELoContourHz = 50.0;
  BBELoContourQ = 1.4;
  BBELoContourMinDb = -12;
  BBELoContourMaxDb = 10;

  { Definition ("regulates the amount of amplitude compensation"). }
  BBEDefinitionMin = 0;
  BBEDefinitionMax = 100;
  { The high:mid RMS ratio the box treats as already-correct. Typical dense
    program material sits near here, which is why a well-balanced mix moves
    the original's LEDs very little and a dull one pins them green. }
  BBERefRelDb = -12.0;
  { How far clockwise Definition can push that target - i.e. how much
    brighter than "correct" the box will try to make the material. }
  BBEDefinitionRangeDb = 14.0;
  { Fraction of the remaining error the VCA actually closes. Deliberately
    not 1.0: the original nudges the balance, it doesn't normalise it, and
    full correction would flatten every source to the same spectrum. }
  BBECorrectionStrength = 0.7;
  { VCA authority in both directions - the "up to 10dB" the process is
    usually quoted at. }
  BBEMaxBoostDb = 10.0;
  BBEMaxCutDb = -10.0;

  { "RMS average loudness detectors" - one time constant, slow enough to
    read loudness rather than chase individual transients. }
  BBEDetectorMs = 30.0;
  { Slew on the VCA's own control voltage, on top of the detector. Also what
    makes the control-rate update below inaudible. }
  BBEVcaSlewMs = 5.0;
  { The comparison, the two logs and the exponential run once per this many
    frames instead of per sample. At 44.1kHz that is every 0.73ms - far
    faster than the 30ms detector feeding it can move, so nothing is lost,
    and BBEVcaSlewMs smooths the steps away regardless. }
  BBEControlPeriod = 32;
  { Below this the mid band has nothing in it to compare against and the
    ratio is meaningless (0/0). Hold the VCA at unity instead of letting it
    slam to full boost over silence and then snap back on the next hit. }
  BBEDetectorFloorRms = 0.0003; { ~-70dBFS }

type
  TBBEDelayLine = record
    Buf: array of Single;
    Pos: Integer;
    Len: Integer;
  end;

  TBBE422State = record
    { band split, two cascaded sections each, [channel][stage] }
    LowLp: array[0..1, 0..1] of TBiquadState;
    MidHp: array[0..1, 0..1] of TBiquadState;
    MidLp: array[0..1, 0..1] of TBiquadState;
    HighHp: array[0..1, 0..1] of TBiquadState;
    ContourBq: array[0..1] of TBiquadState;
    LowLpCoeffs, MidHpCoeffs, MidLpCoeffs, HighHpCoeffs: TBiquadCoeffs;
    ContourCoeffs: TBiquadCoeffs;
    LowLine, MidLine: array[0..1] of TBBEDelayLine;
    { mean-square, linked across L/R so the VCA can never move one channel's
      top end without the other's }
    MidEnv, HighEnv: Single;
    EnvCoeff: Single;
    SlewCoeff: Single;
    VcaGain: Single;   { what the high band is actually multiplied by now }
    VcaTarget: Single; { what the last control-rate comparison asked for }
    ControlCount: Integer;
    LastSampleRate: Integer;
    LastLoContourDb: Single;
  end;

procedure BBE422Reset(var AState: TBBE422State);

{ One host-rate frame in place. ALoContourDb is in dB on the panel's own
  -12..+10 scale; ADefinition and AMixPercent are 0..100. }
procedure BBE422Process(var AState: TBBE422State; var L, R: Single;
  ASampleRate: Integer; ALoContourDb, ADefinition, AMixPercent: Single);

implementation

procedure BBELineAlloc(var ALine: TBBEDelayLine; ADelayMs: Single;
  ASampleRate: Integer);
begin
  { Integer sample delay, no interpolation. The finest of these two delays is
    0.5ms and the highest frequency inside the band it delays is 1200Hz, so
    one sample of rounding is under 2 degrees of phase - well below anything
    the analog group delay it stands in for held to. }
  ALine.Len := Round(ADelayMs * 0.001 * ASampleRate);
  if ALine.Len < 1 then
    ALine.Len := 1;
  SetLength(ALine.Buf, ALine.Len);
  FillChar(ALine.Buf[0], ALine.Len * SizeOf(Single), 0);
  ALine.Pos := 0;
end;

{ Push one sample in, take the one from ALine.Len frames ago out. }
function BBELineTick(var ALine: TBBEDelayLine; AInput: Single): Single;
begin
  Result := ALine.Buf[ALine.Pos];
  ALine.Buf[ALine.Pos] := AInput;
  Inc(ALine.Pos);
  if ALine.Pos >= ALine.Len then
    ALine.Pos := 0;
end;

procedure BBE422Reset(var AState: TBBE422State);
begin
  FillChar(AState, SizeOf(AState), 0);
  AState.VcaGain := 1.0;
  AState.VcaTarget := 1.0;
  { NaN rather than 0, for the reason Effects.EffectStateReset spells out:
    0dB is a legal Lo Contour setting and must not look "unchanged" against
    a zeroed field on the very first call. }
  AState.LastLoContourDb := NaN;
end;

procedure BBE422Setup(var AState: TBBE422State; ASampleRate: Integer);
var
  c: Integer;
begin
  ComputeLowpassBiquad(BBELowXoverHz, ASampleRate, BBEXoverQ, AState.LowLpCoeffs);
  ComputeHighpassBiquad(BBELowXoverHz, ASampleRate, BBEXoverQ, AState.MidHpCoeffs);
  ComputeLowpassBiquad(BBEHighXoverHz, ASampleRate, BBEXoverQ, AState.MidLpCoeffs);
  ComputeHighpassBiquad(BBEHighXoverHz, ASampleRate, BBEXoverQ, AState.HighHpCoeffs);
  for c := 0 to 1 do
  begin
    BBELineAlloc(AState.LowLine[c], BBELowDelayMs, ASampleRate);
    BBELineAlloc(AState.MidLine[c], BBEMidDelayMs, ASampleRate);
  end;
  AState.EnvCoeff := 1 - Exp(-1 / (BBEDetectorMs * 0.001 * ASampleRate));
  AState.SlewCoeff := 1 - Exp(-1 / (BBEVcaSlewMs * 0.001 * ASampleRate));
  AState.MidEnv := 0;
  AState.HighEnv := 0;
  AState.ControlCount := 0;
  AState.LastSampleRate := ASampleRate;
end;

procedure BBE422Process(var AState: TBBE422State; var L, R: Single;
  ASampleRate: Integer; ALoContourDb, ADefinition, AMixPercent: Single);
var
  c: Integer;
  DryL, DryR: Single;
  In_, Low, Mid, High: Single;
  BandLow: array[0..1] of Single;
  BandMid: array[0..1] of Single;
  BandHigh: array[0..1] of Single;
  MidSq, HighSq: Single;
  MidRms, HighRms, RelDb, TargetDb, CorrDb, DefFrac: Single;
  MixFrac, WetL, WetR: Single;
begin
  if AState.LastSampleRate <> ASampleRate then
    BBE422Setup(AState, ASampleRate);
  if ALoContourDb <> AState.LastLoContourDb then
  begin
    ComputePeakingBiquad(BBELoContourHz, ASampleRate, BBELoContourQ,
      ALoContourDb, AState.ContourCoeffs);
    AState.LastLoContourDb := ALoContourDb;
  end;

  DryL := L;
  DryR := R;

  { --- split, then delay the two lower bands behind the top one --- }
  for c := 0 to 1 do
  begin
    if c = 0 then In_ := L else In_ := R;

    Low := ProcessBiquad(AState.LowLp[c, 0], AState.LowLpCoeffs, In_);
    Low := ProcessBiquad(AState.LowLp[c, 1], AState.LowLpCoeffs, Low);
    { Lo Contour lives inside the low band and so is delayed with it - the
      manual's "phase compensated bass equalization" }
    Low := ProcessBiquad(AState.ContourBq[c], AState.ContourCoeffs, Low);

    Mid := ProcessBiquad(AState.MidHp[c, 0], AState.MidHpCoeffs, In_);
    Mid := ProcessBiquad(AState.MidHp[c, 1], AState.MidHpCoeffs, Mid);
    Mid := ProcessBiquad(AState.MidLp[c, 0], AState.MidLpCoeffs, Mid);
    Mid := ProcessBiquad(AState.MidLp[c, 1], AState.MidLpCoeffs, Mid);

    High := ProcessBiquad(AState.HighHp[c, 0], AState.HighHpCoeffs, In_);
    High := ProcessBiquad(AState.HighHp[c, 1], AState.HighHpCoeffs, High);

    BandLow[c] := BBELineTick(AState.LowLine[c], Low);
    BandMid[c] := BBELineTick(AState.MidLine[c], Mid);
    BandHigh[c] := High;
  end;

  { --- detectors: compare the mid band against the high band ---
    Mean of the two channels' SQUARES, not the square of their mean: this is
    a loudness comparison, and summing L and R first would let anything
    out-of-phase across the stereo field cancel itself out of the detector
    and read as a band that isn't there.
    The mid tap is taken after its delay line, so what the two envelopes
    describe is the mid and high content leaving the box together, rather
    than the mid content 0.5ms before it does. At a 30ms time constant the
    difference is academic either way. }
  MidSq := (BandMid[0] * BandMid[0] + BandMid[1] * BandMid[1]) * 0.5;
  HighSq := (BandHigh[0] * BandHigh[0] + BandHigh[1] * BandHigh[1]) * 0.5;
  AState.MidEnv := AState.MidEnv + AState.EnvCoeff * (MidSq - AState.MidEnv);
  AState.HighEnv := AState.HighEnv + AState.EnvCoeff * (HighSq - AState.HighEnv);

  if AState.ControlCount <= 0 then
  begin
    AState.ControlCount := BBEControlPeriod;
    DefFrac := ADefinition / 100;
    if DefFrac < 0 then DefFrac := 0;
    if DefFrac > 1 then DefFrac := 1;
    MidRms := Sqrt(AState.MidEnv);
    if (MidRms < BBEDetectorFloorRms) or (DefFrac = 0) then
      CorrDb := 0
    else
    begin
      HighRms := Sqrt(AState.HighEnv);
      RelDb := 20 * Log10((HighRms + 1E-9) / MidRms);
      TargetDb := BBERefRelDb + DefFrac * BBEDefinitionRangeDb;
      { Both the target AND the authority scale with the knob, so fully
        counter-clockwise is genuinely flat (amber) rather than "still
        correcting, just towards a lower target". Clockwise therefore always
        means more top end, which is what the panel promises - but how much
        more depends on what the material already had, which is what makes
        this the BBE process rather than a shelving EQ. }
      CorrDb := (TargetDb - RelDb) * (BBECorrectionStrength * DefFrac);
      if CorrDb > BBEMaxBoostDb then CorrDb := BBEMaxBoostDb;
      if CorrDb < BBEMaxCutDb then CorrDb := BBEMaxCutDb;
    end;
    AState.VcaTarget := Power(10, CorrDb / 20);
  end;
  Dec(AState.ControlCount);
  AState.VcaGain := AState.VcaGain +
    AState.SlewCoeff * (AState.VcaTarget - AState.VcaGain);

  { --- recombine. The sum is not flat and is not meant to be: three bands
    that no longer share a timebase cannot cancel back to the input. --- }
  WetL := BandLow[0] + BandMid[0] + BandHigh[0] * AState.VcaGain;
  WetR := BandLow[1] + BandMid[1] + BandHigh[1] * AState.VcaGain;

  MixFrac := AMixPercent / 100;
  if MixFrac < 0 then MixFrac := 0;
  if MixFrac > 1 then MixFrac := 1;
  L := DryL * (1 - MixFrac) + WetL * MixFrac;
  R := DryR * (1 - MixFrac) + WetR * MixFrac;
end;

end.
