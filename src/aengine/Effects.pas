unit Effects;

{$mode objfpc}{$H+}

interface

uses
  Math, BiquadFilters;

const
  MaxEffectsPerTrack = 4;
  MaxEQBands = 4;

  ekNone = 0;
  ekLowpass = 1;
  ekEQ4 = 2;
  ekLimiter = 3;
  ekChorus = 4;
  ekReverb = 5;
  ekFlanger = 6;
  ekPhaser = 7;
  ekSidechain = 8;
  ekDrowning = 9;

  { classic vintage-style chorus (think Ableton Live 1/2's Chorus, or a
    tracker's chorus command) - just a short modulated delay line per
    channel, mixed 50/50 with the dry signal, no feedback/multi-voice
    ensemble stacking like a modern chorus. L and R LFOs run 90 degrees out
    of phase for stereo width, which is most of what makes it sound "wide"
    rather than just wobbly. }
  ChorusCenterDelayMs = 15.0;
  ChorusModRangeMs = 8.0;
  ChorusMaxDelayMs = 30.0;

  { Flanger: the same modulated-delay recipe as Chorus, but a much shorter
    center delay (a few ms instead of ~15ms) plus a feedback path around the
    delay line - the feedback is what turns it from "chorus but shorter"
    into the distinctive metallic, resonant flanger sweep. }
  FlangerCenterDelayMs = 4.0;
  FlangerModRangeMs = 3.5;
  FlangerMaxDelayMs = 8.0;

  { Phaser: N cascaded first-order allpass stages (classic Small
    Stone/Phase 90 recipe), all sharing one LFO-swept center frequency per
    channel, plus a feedback tap around the whole chain for a more
    pronounced, resonant sweep. }
  PhaserStageCount = 4;
  PhaserMinFreqHz = 200.0;
  PhaserMaxFreqHz = 2000.0;

  { "Basic Reverb" - a small Schroeder/Freeverb-style tank: a handful of
    parallel comb filters (each with a one-pole lowpass in its feedback path
    for natural high-frequency damping) feeding a couple of series allpass
    filters for diffusion. Far simpler than a modern algorithmic reverb, but
    it's the same basic recipe most simple/vintage reverbs actually use. }
  ReverbPresetSmall = 0;
  ReverbPresetRoom = 1;
  ReverbPresetClub = 2;
  ReverbPresetHall = 3;
  ReverbPresetPlate = 4;
  ReverbPresetCount = 5;
  ReverbPresetNames: array[0..ReverbPresetCount - 1] of string =
    ('Small', 'Room', 'Club', 'Hall', 'Plate');

  ReverbCombCount = 4;
  ReverbAllpassCount = 2;
  ReverbAllpassFeedback = 0.5;
  { classic Freeverb comb/allpass tuning (originally in samples @ 44.1kHz),
    expressed in ms so they scale cleanly to any project sample rate }
  ReverbCombBaseMs: array[0..ReverbCombCount - 1] of Single =
    (35.31, 36.67, 33.81, 32.24);
  ReverbAllpassBaseMs: array[0..ReverbAllpassCount - 1] of Single =
    (12.61, 10.00);
  { small L/R delay-length offset for stereo width, Freeverb's own trick,
    expressed relative to a 44.1kHz reference like the tunings above }
  ReverbStereoSpreadSamples44k = 23;

type
  { plain flat record with fields used depending on Kind, matching the
    project's existing tagged-record style (see AudioEngine.TCommand) rather
    than a strict Pascal variant record }
  TEffect = record
    Kind: Integer;
    LowpassFreqHz: Single;
    EQFreqHz: array[0..MaxEQBands - 1] of Single;
    EQGainDb: array[0..MaxEQBands - 1] of Single;
    LimiterThresholdDb: Single;
    LimiterReleaseMs: Single;
    ChorusRateHz: Single;
    ChorusDepthPercent: Single;
    ReverbPreset: Integer;
    ReverbMixPercent: Single;
    FlangerRateHz: Single;
    FlangerDepthPercent: Single;
    FlangerFeedbackPercent: Single;
    FlangerMixPercent: Single;
    PhaserRateHz: Single;
    PhaserDepthPercent: Single;
    PhaserFeedbackPercent: Single;
    PhaserMixPercent: Single;
    { SidechainSourceTrack is a 0-based track index (Project.Tracks/TrackEffects
      convention); ProcessEffect itself never sees Project - AudioEngine looks
      the source track's live level up and passes it in as ASidechainLevel }
    SidechainSourceTrack: Integer;
    SidechainThresholdDb: Single;
    SidechainAttackMs: Single;
    SidechainReleaseMs: Single;
    SidechainStrengthPercent: Single;
    { "Drowning" (Experimental category): LP tone -> chorus-style warble ->
      comb/allpass reverb tank, see ProcessEffect's ekDrowning branch }
    DrowningToneHz: Single;
    DrowningWarbleRateHz: Single;
    DrowningWarbleDepthPercent: Single;
    DrowningSizePercent: Single;
    DrowningDecayPercent: Single;
    DrowningMixPercent: Single;
  end;

  TEffectChannelState = record
    LowpassBq: TBiquadState;
    EQBq: array[0..MaxEQBands - 1] of TBiquadState;
  end;

  TCombState = record
    Buf: array of Single;
    BufPos: Integer;
    FilterStore: Single;
  end;

  TAllpassState = record
    Buf: array of Single;
    BufPos: Integer;
  end;

  TEffectState = record
    Channels: array[0..1] of TEffectChannelState; { L, R }
    LowpassCoeffs: TBiquadCoeffs;
    EQCoeffs: array[0..MaxEQBands - 1] of TBiquadCoeffs;
    LastSampleRate: Integer;
    LastLowpassFreq: Single;
    LastEQFreq: array[0..MaxEQBands - 1] of Single;
    LastEQGain: array[0..MaxEQBands - 1] of Single;
    LimiterGain: Single; { current smoothed gain reduction, linked across L/R
      so limiting never shifts the stereo image }
    { cached so Power()/Exp() below only run when a slider actually moved,
      same pattern as LastLowpassFreq/LastEQFreq above - previously these
      ran unconditionally on every single sample }
    LastLimiterThresholdDb: Single;
    LimiterThresholdLin: Single;
    LastLimiterReleaseMs: Single;
    LimiterReleaseCoeff: Single;
    ChorusBufL: array of Single; { lazily sized once the sample rate is known }
    ChorusBufR: array of Single;
    ChorusWritePos: Integer;
    ChorusPhase: Single; { 0..1, one full LFO cycle }
    ReverbCombL, ReverbCombR: array[0..ReverbCombCount - 1] of TCombState;
    ReverbAllpassL, ReverbAllpassR: array[0..ReverbAllpassCount - 1] of TAllpassState;
    ReverbLastPreset: Integer; { -1 = not yet set up, forces setup on first use }
    ReverbLastSampleRate: Integer;
    FlangerBufL: array of Single; { lazily sized once the sample rate is known }
    FlangerBufR: array of Single;
    FlangerWritePos: Integer;
    FlangerPhase: Single; { 0..1, one full LFO cycle }
    PhaserZ1x: array[0..1, 0..PhaserStageCount - 1] of Single; { [channel][stage] }
    PhaserZ1y: array[0..1, 0..PhaserStageCount - 1] of Single;
    PhaserFeedbackSample: array[0..1] of Single; { last chain output, fed back into this channel's input }
    PhaserPhase: Single;
    SidechainGain: Single; { current smoothed ducking gain, 1.0 = no reduction }
    { same caching as Limiter above }
    LastSidechainThresholdDb: Single;
    SidechainThresholdLin: Single;
    LastSidechainAttackMs: Single;
    SidechainAttackCoeff: Single;
    LastSidechainReleaseMs: Single;
    SidechainReleaseCoeff: Single;
    { Drowning reuses Channels[].LowpassBq/LowpassCoeffs (tone stage),
      ChorusBufL/R/ChorusWritePos/ChorusPhase (warble stage) and
      ReverbCombL/R/ReverbAllpassL/R (tank stage) above - only these two
      "last settings seen" fields are Drowning-specific, since its tank is
      sized off a continuous Size slider rather than ekReverb's preset list }
    DrowningLastSizePercent: Single;
    DrowningLastSampleRate: Integer;
  end;

procedure EffectStateReset(var AState: TEffectState);
procedure DefaultEffect(AKind: Integer; out AEffect: TEffect);

{ Runs one track-insert effect over a single frame's L/R in place. Coefficient
  recomputation only happens when a parameter actually changed since the
  last call, so turning a knob is cheap and holding it still is even cheaper.
  ASidechainLevel is the current linear peak level of AEffect.SidechainSourceTrack
  - meaningless for every Kind except ekSidechain, and looked up by the
  caller (AudioEngine), since this unit has no idea Project/tracks exist. }
procedure ProcessEffect(var AState: TEffectState; const AEffect: TEffect;
  var L, R: Single; ASampleRate: Integer; ASidechainLevel: Single);

implementation

const
  LowpassQ = 0.707;
  EQQ = 1.0;

procedure EffectStateReset(var AState: TEffectState);
begin
  FillChar(AState, SizeOf(AState), 0);
  AState.LimiterGain := 1.0; { unity - no reduction until something is loud enough to need it }
  AState.ReverbLastPreset := -1; { 0 is a valid preset (Small) - must not look
    already-set-up before SetupReverb has ever actually allocated buffers }
  AState.SidechainGain := 1.0; { unity - no ducking until the source track actually hits }
  { NaN, not 0 - a real threshold/release value of exactly 0 is legal, and
    would otherwise look like "unchanged" against a zeroed Last* field on
    the very first call, leaving the paired *Lin/*Coeff field at its
    zeroed (wrong) default instead of ever actually being computed. NaN
    never compares equal to anything, including itself, so the first real
    call always recomputes regardless of what value it sees. }
  AState.LastLimiterThresholdDb := NaN;
  AState.LastLimiterReleaseMs := NaN;
  AState.LastSidechainThresholdDb := NaN;
  AState.LastSidechainAttackMs := NaN;
  AState.LastSidechainReleaseMs := NaN;
end;

procedure DefaultEffect(AKind: Integer; out AEffect: TEffect);
begin
  FillChar(AEffect, SizeOf(AEffect), 0);
  AEffect.Kind := AKind;
  case AKind of
    ekLowpass:
      AEffect.LowpassFreqHz := 8000;
    ekEQ4:
      begin
        { sane low/low-mid/high-mid/high spread, unity gain (0dB) to start }
        AEffect.EQFreqHz[0] := 100;
        AEffect.EQFreqHz[1] := 500;
        AEffect.EQFreqHz[2] := 2000;
        AEffect.EQFreqHz[3] := 8000;
      end;
    ekLimiter:
      begin
        AEffect.LimiterThresholdDb := -1.0; { ceiling just under 0dBFS }
        AEffect.LimiterReleaseMs := 150;
      end;
    ekChorus:
      begin
        AEffect.ChorusRateHz := 0.5; { classic slow, lush default sweep }
        AEffect.ChorusDepthPercent := 50;
      end;
    ekReverb:
      begin
        AEffect.ReverbPreset := ReverbPresetRoom;
        AEffect.ReverbMixPercent := 30;
      end;
    ekFlanger:
      begin
        AEffect.FlangerRateHz := 0.3;
        AEffect.FlangerDepthPercent := 60;
        AEffect.FlangerFeedbackPercent := 40;
        AEffect.FlangerMixPercent := 50;
      end;
    ekPhaser:
      begin
        AEffect.PhaserRateHz := 0.4;
        AEffect.PhaserDepthPercent := 70;
        AEffect.PhaserFeedbackPercent := 30;
        AEffect.PhaserMixPercent := 50;
      end;
    ekSidechain:
      begin
        AEffect.SidechainSourceTrack := 0;
        AEffect.SidechainThresholdDb := -20;
        AEffect.SidechainAttackMs := 5;
        AEffect.SidechainReleaseMs := 150;
        AEffect.SidechainStrengthPercent := 70;
      end;
    ekDrowning:
      begin
        { 2012-Clams-Casino-vocal-wash defaults: dark, slow-warbling, big and
          long-tailed, roughly half-drowned rather than fully submerged }
        AEffect.DrowningToneHz := 2500;
        AEffect.DrowningWarbleRateHz := 0.35;
        AEffect.DrowningWarbleDepthPercent := 55;
        AEffect.DrowningSizePercent := 65;
        AEffect.DrowningDecayPercent := 70;
        AEffect.DrowningMixPercent := 45;
      end;
  end;
end;

{ Fractional-delay read from a circular buffer with linear interpolation;
  AReadPos may be (slightly) negative, since write-position minus a delay in
  samples can dip below 0 near the start of playback - wrap it back into
  range first. }
function ReadDelayInterp(const ABuf: array of Single; ALen: Integer;
  AReadPos: Double): Single;
var
  i0, i1: Integer;
  Frac: Double;
begin
  while AReadPos < 0 do
    AReadPos := AReadPos + ALen;
  i0 := Trunc(AReadPos) mod ALen;
  Frac := AReadPos - Trunc(AReadPos);
  i1 := (i0 + 1) mod ALen;
  Result := ABuf[i0] * (1 - Frac) + ABuf[i1] * Frac;
end;

{ One comb filter with a one-pole lowpass (damp1/damp2) inside its feedback
  path - the lowpass is what makes the decaying tail sound like it's losing
  high end naturally (air absorption) instead of ringing forever. }
function ProcessComb(var AState: TCombState; AInput, AFeedback, ADamp1,
  ADamp2: Single): Single;
var
  Output: Single;
begin
  Output := AState.Buf[AState.BufPos];
  AState.FilterStore := (Output * ADamp2) + (AState.FilterStore * ADamp1);
  AState.Buf[AState.BufPos] := AInput + AState.FilterStore * AFeedback;
  Inc(AState.BufPos);
  if AState.BufPos >= Length(AState.Buf) then
    AState.BufPos := 0;
  Result := Output;
end;

function ProcessAllpass(var AState: TAllpassState; AInput, AFeedback: Single): Single;
var
  BufOut: Single;
begin
  BufOut := AState.Buf[AState.BufPos];
  Result := -AInput + BufOut;
  AState.Buf[AState.BufPos] := AInput + BufOut * AFeedback;
  Inc(AState.BufPos);
  if AState.BufPos >= Length(AState.Buf) then
    AState.BufPos := 0;
end;

procedure ReverbPresetParams(APreset: Integer; out ARoomScale, AFeedback,
  ADamping: Single);
begin
  case APreset of
    ReverbPresetSmall:
      begin ARoomScale := 0.5;  AFeedback := 0.60; ADamping := 0.30; end;
    ReverbPresetClub:
      begin ARoomScale := 0.9;  AFeedback := 0.78; ADamping := 0.25; end;
    ReverbPresetHall:
      begin ARoomScale := 1.4;  AFeedback := 0.86; ADamping := 0.40; end;
    ReverbPresetPlate:
      begin ARoomScale := 0.65; AFeedback := 0.80; ADamping := 0.15; end;
  else
    { ReverbPresetRoom and any unrecognized value }
    begin ARoomScale := 0.75; AFeedback := 0.70; ADamping := 0.35; end;
  end;
end;

{ (Re)allocates every comb/allpass delay line for a given room scale and
  sample rate. Only called when either actually changes - not per-sample.
  Shared by ekReverb (which resolves RoomScale from a fixed preset via
  ReverbPresetParams) and ekDrowning (which sizes its tank straight off a
  continuous Size slider instead of a preset). }
procedure SetupReverbTank(var AState: TEffectState; ARoomScale: Single; ASampleRate: Integer);
var
  c, StereoSpreadSamples, LenL, LenR: Integer;
begin
  StereoSpreadSamples := Round(ReverbStereoSpreadSamples44k * ASampleRate / 44100);

  for c := 0 to ReverbCombCount - 1 do
  begin
    LenL := Round(ReverbCombBaseMs[c] * ARoomScale * ASampleRate / 1000);
    if LenL < 1 then
      LenL := 1;
    LenR := LenL + StereoSpreadSamples;
    SetLength(AState.ReverbCombL[c].Buf, LenL);
    SetLength(AState.ReverbCombR[c].Buf, LenR);
    FillChar(AState.ReverbCombL[c].Buf[0], LenL * SizeOf(Single), 0);
    FillChar(AState.ReverbCombR[c].Buf[0], LenR * SizeOf(Single), 0);
    AState.ReverbCombL[c].BufPos := 0;
    AState.ReverbCombR[c].BufPos := 0;
    AState.ReverbCombL[c].FilterStore := 0;
    AState.ReverbCombR[c].FilterStore := 0;
  end;

  for c := 0 to ReverbAllpassCount - 1 do
  begin
    LenL := Round(ReverbAllpassBaseMs[c] * ARoomScale * ASampleRate / 1000);
    if LenL < 1 then
      LenL := 1;
    LenR := LenL + StereoSpreadSamples;
    SetLength(AState.ReverbAllpassL[c].Buf, LenL);
    SetLength(AState.ReverbAllpassR[c].Buf, LenR);
    FillChar(AState.ReverbAllpassL[c].Buf[0], LenL * SizeOf(Single), 0);
    FillChar(AState.ReverbAllpassR[c].Buf[0], LenR * SizeOf(Single), 0);
    AState.ReverbAllpassL[c].BufPos := 0;
    AState.ReverbAllpassR[c].BufPos := 0;
  end;
end;

procedure SetupReverb(var AState: TEffectState; APreset, ASampleRate: Integer);
var
  RoomScale, Feedback, Damping: Single;
begin
  ReverbPresetParams(APreset, RoomScale, Feedback, Damping);
  SetupReverbTank(AState, RoomScale, ASampleRate);
end;

{ One first-order allpass stage (the "Regalia-Mitra" form used by most
  analog-modeled phaser plugins): a single pole/zero pair whose -90 degree
  point sits at AFreqHz. AZ1x/AZ1y are that stage's own x[n-1]/y[n-1] -
  cascading PhaserStageCount of these with a shared, LFO-swept AFreqHz is
  what produces the classic multi-notch phaser sweep. }
function ProcessAllpassFirstOrder(var AZ1x, AZ1y: Single; AInput, AFreqHz: Single;
  ASampleRate: Integer): Single;
var
  Coeff, Tan: Single;
begin
  Tan := Math.Tan(Pi * AFreqHz / ASampleRate);
  Coeff := (Tan - 1) / (Tan + 1);
  Result := Coeff * (AInput - AZ1y) + AZ1x;
  AZ1x := AInput;
  AZ1y := Result;
end;

function ClampFreq(AFreqHz: Single; ASampleRate: Integer): Single;
begin
  Result := AFreqHz;
  if Result < 20 then
    Result := 20;
  if Result > ASampleRate * 0.49 then
    Result := ASampleRate * 0.49;
end;

procedure ProcessEffect(var AState: TEffectState; const AEffect: TEffect;
  var L, R: Single; ASampleRate: Integer; ASidechainLevel: Single);
var
  b: Integer;
  Freq: Single;
  ThresholdLin, Peak, TargetGain, ReleaseCoeff, ReleaseMs: Single;
  ChorusBufLen: Integer;
  ModL, ModR, DelayMsL, DelayMsR, DepthFrac, WetL, WetR: Double;
  c, s: Integer;
  RvRoomScale, RvFeedback, RvDamping, RvDamp1, RvDamp2: Single;
  RvDryL, RvDryR, RvInputMono, RvWetL, RvWetR, RvMixFrac: Single;
  FlangerBufLen: Integer;
  FeedbackFrac, MixFrac: Single;
  PhFreqL, PhFreqR, PhFeedbackFrac, PhInL, PhInR, PhOutL, PhOutR: Single;
  ScAttackMs, ScAttackCoeff, ScStrengthFrac: Single;
  ToneL, ToneR: Single;
begin
  case AEffect.Kind of
    ekLowpass:
      begin
        Freq := ClampFreq(AEffect.LowpassFreqHz, ASampleRate);
        if (ASampleRate <> AState.LastSampleRate) or
          (Freq <> AState.LastLowpassFreq) then
        begin
          ComputeLowpassBiquad(Freq, ASampleRate, LowpassQ, AState.LowpassCoeffs);
          AState.LastLowpassFreq := Freq;
        end;
        L := ProcessBiquad(AState.Channels[0].LowpassBq, AState.LowpassCoeffs, L);
        R := ProcessBiquad(AState.Channels[1].LowpassBq, AState.LowpassCoeffs, R);
        AState.LastSampleRate := ASampleRate;
      end;
    ekEQ4:
      begin
        for b := 0 to MaxEQBands - 1 do
        begin
          Freq := ClampFreq(AEffect.EQFreqHz[b], ASampleRate);
          if (ASampleRate <> AState.LastSampleRate) or
            (Freq <> AState.LastEQFreq[b]) or
            (AEffect.EQGainDb[b] <> AState.LastEQGain[b]) then
          begin
            ComputePeakingBiquad(Freq, ASampleRate, EQQ, AEffect.EQGainDb[b],
              AState.EQCoeffs[b]);
            AState.LastEQFreq[b] := Freq;
            AState.LastEQGain[b] := AEffect.EQGainDb[b];
          end;
          L := ProcessBiquad(AState.Channels[0].EQBq[b], AState.EQCoeffs[b], L);
          R := ProcessBiquad(AState.Channels[1].EQBq[b], AState.EQCoeffs[b], R);
        end;
        AState.LastSampleRate := ASampleRate;
      end;
    ekLimiter:
      begin
        { zero-lookahead peak limiter, gain reduction linked across L/R so
          the stereo image never shifts. Attack is instant (the target gain
          for THIS sample is computed from THIS sample's peak and applied to
          it immediately), which is what actually guarantees the ceiling is
          never exceeded; release is a smooth one-pole climb back to unity
          to avoid audible pumping. }
        if AEffect.LimiterThresholdDb <> AState.LastLimiterThresholdDb then
        begin
          AState.LimiterThresholdLin := Power(10, AEffect.LimiterThresholdDb / 20);
          AState.LastLimiterThresholdDb := AEffect.LimiterThresholdDb;
        end;
        ThresholdLin := AState.LimiterThresholdLin;

        Peak := Abs(L);
        if Abs(R) > Peak then
          Peak := Abs(R);

        if Peak > ThresholdLin then
          TargetGain := ThresholdLin / Peak
        else
          TargetGain := 1.0;

        if TargetGain < AState.LimiterGain then
          AState.LimiterGain := TargetGain
        else
        begin
          ReleaseMs := AEffect.LimiterReleaseMs;
          if ReleaseMs < 1 then
            ReleaseMs := 1;
          { ASampleRate isn't part of this check, unlike Lowpass/EQ4's above -
            it's AudioEngine.ProjectSampleRate, a compile-time constant that
            never actually varies within a run (both the realtime and
            offline-render callers pass the same value every single call),
            so checking it here would only ever defeat this cache, never
            protect anything real }
          if ReleaseMs <> AState.LastLimiterReleaseMs then
          begin
            AState.LimiterReleaseCoeff := Exp(-1 / (0.001 * ReleaseMs * ASampleRate));
            AState.LastLimiterReleaseMs := ReleaseMs;
          end;
          ReleaseCoeff := AState.LimiterReleaseCoeff;
          AState.LimiterGain := TargetGain + (AState.LimiterGain - TargetGain) * ReleaseCoeff;
        end;

        L := L * AState.LimiterGain;
        R := R * AState.LimiterGain;
      end;
    ekChorus:
      begin
        if AState.ChorusBufL = nil then
        begin
          ChorusBufLen := Round(ASampleRate * ChorusMaxDelayMs / 1000) + 1;
          SetLength(AState.ChorusBufL, ChorusBufLen);
          SetLength(AState.ChorusBufR, ChorusBufLen);
          AState.ChorusWritePos := 0;
          AState.ChorusPhase := 0;
        end;
        ChorusBufLen := Length(AState.ChorusBufL);

        AState.ChorusBufL[AState.ChorusWritePos] := L;
        AState.ChorusBufR[AState.ChorusWritePos] := R;

        DepthFrac := AEffect.ChorusDepthPercent / 100;
        { L and R LFOs 90 degrees apart - this is what gives the classic
          "wide" stereo swirl rather than a single wobbling voice }
        ModL := Sin(2 * Pi * AState.ChorusPhase);
        ModR := Sin(2 * Pi * AState.ChorusPhase + Pi / 2);
        DelayMsL := ChorusCenterDelayMs + ModL * ChorusModRangeMs * DepthFrac;
        DelayMsR := ChorusCenterDelayMs + ModR * ChorusModRangeMs * DepthFrac;

        WetL := ReadDelayInterp(AState.ChorusBufL, ChorusBufLen,
          AState.ChorusWritePos - DelayMsL * ASampleRate / 1000);
        WetR := ReadDelayInterp(AState.ChorusBufR, ChorusBufLen,
          AState.ChorusWritePos - DelayMsR * ASampleRate / 1000);

        { fixed 50/50 dry/wet mix, no separate mix knob - matches the old,
          simpler chorus devices this is modeled on }
        L := 0.5 * L + 0.5 * WetL;
        R := 0.5 * R + 0.5 * WetR;

        AState.ChorusWritePos := (AState.ChorusWritePos + 1) mod ChorusBufLen;
        AState.ChorusPhase := AState.ChorusPhase + AEffect.ChorusRateHz / ASampleRate;
        if AState.ChorusPhase >= 1 then
          AState.ChorusPhase := AState.ChorusPhase - 1;
      end;
    ekReverb:
      begin
        if (AState.ReverbLastPreset <> AEffect.ReverbPreset) or
          (AState.ReverbLastSampleRate <> ASampleRate) then
        begin
          SetupReverb(AState, AEffect.ReverbPreset, ASampleRate);
          AState.ReverbLastPreset := AEffect.ReverbPreset;
          AState.ReverbLastSampleRate := ASampleRate;
        end;

        ReverbPresetParams(AEffect.ReverbPreset, RvRoomScale, RvFeedback, RvDamping);
        RvDamp1 := RvDamping;
        RvDamp2 := 1 - RvDamp1;

        RvDryL := L;
        RvDryR := R;
        RvInputMono := (L + R) * 0.5;

        RvWetL := 0;
        RvWetR := 0;
        for c := 0 to ReverbCombCount - 1 do
        begin
          RvWetL := RvWetL + ProcessComb(AState.ReverbCombL[c], RvInputMono,
            RvFeedback, RvDamp1, RvDamp2);
          RvWetR := RvWetR + ProcessComb(AState.ReverbCombR[c], RvInputMono,
            RvFeedback, RvDamp1, RvDamp2);
        end;
        RvWetL := RvWetL / ReverbCombCount;
        RvWetR := RvWetR / ReverbCombCount;

        for c := 0 to ReverbAllpassCount - 1 do
        begin
          RvWetL := ProcessAllpass(AState.ReverbAllpassL[c], RvWetL, ReverbAllpassFeedback);
          RvWetR := ProcessAllpass(AState.ReverbAllpassR[c], RvWetR, ReverbAllpassFeedback);
        end;

        RvMixFrac := AEffect.ReverbMixPercent / 100;
        L := RvDryL * (1 - RvMixFrac) + RvWetL * RvMixFrac;
        R := RvDryR * (1 - RvMixFrac) + RvWetR * RvMixFrac;
      end;
    ekFlanger:
      begin
        if AState.FlangerBufL = nil then
        begin
          FlangerBufLen := Round(ASampleRate * FlangerMaxDelayMs / 1000) + 1;
          SetLength(AState.FlangerBufL, FlangerBufLen);
          SetLength(AState.FlangerBufR, FlangerBufLen);
          AState.FlangerWritePos := 0;
          AState.FlangerPhase := 0;
        end;
        FlangerBufLen := Length(AState.FlangerBufL);

        DepthFrac := AEffect.FlangerDepthPercent / 100;
        ModL := Sin(2 * Pi * AState.FlangerPhase);
        ModR := Sin(2 * Pi * AState.FlangerPhase + Pi / 2);
        DelayMsL := FlangerCenterDelayMs + ModL * FlangerModRangeMs * DepthFrac;
        DelayMsR := FlangerCenterDelayMs + ModR * FlangerModRangeMs * DepthFrac;

        WetL := ReadDelayInterp(AState.FlangerBufL, FlangerBufLen,
          AState.FlangerWritePos - DelayMsL * ASampleRate / 1000);
        WetR := ReadDelayInterp(AState.FlangerBufR, FlangerBufLen,
          AState.FlangerWritePos - DelayMsR * ASampleRate / 1000);

        { feedback around the delay line itself (not just the output mix) is
          what makes a flanger's sweep resonant/metallic rather than sounding
          like a short chorus - clamp well under 1.0 so it can't run away }
        FeedbackFrac := AEffect.FlangerFeedbackPercent / 100;
        if FeedbackFrac > 0.95 then FeedbackFrac := 0.95;
        if FeedbackFrac < 0 then FeedbackFrac := 0;
        AState.FlangerBufL[AState.FlangerWritePos] := L + WetL * FeedbackFrac;
        AState.FlangerBufR[AState.FlangerWritePos] := R + WetR * FeedbackFrac;

        MixFrac := AEffect.FlangerMixPercent / 100;
        L := L * (1 - MixFrac) + WetL * MixFrac;
        R := R * (1 - MixFrac) + WetR * MixFrac;

        AState.FlangerWritePos := (AState.FlangerWritePos + 1) mod FlangerBufLen;
        AState.FlangerPhase := AState.FlangerPhase + AEffect.FlangerRateHz / ASampleRate;
        if AState.FlangerPhase >= 1 then
          AState.FlangerPhase := AState.FlangerPhase - 1;
      end;
    ekPhaser:
      begin
        DepthFrac := AEffect.PhaserDepthPercent / 100;
        ModL := Sin(2 * Pi * AState.PhaserPhase);
        ModR := Sin(2 * Pi * AState.PhaserPhase + Pi / 2);
        { sweep range narrows around the min/max midpoint as Depth drops,
          rather than shifting the whole range up or down }
        PhFreqL := (PhaserMinFreqHz + PhaserMaxFreqHz) / 2 +
          ModL * ((PhaserMaxFreqHz - PhaserMinFreqHz) / 2) * DepthFrac;
        PhFreqR := (PhaserMinFreqHz + PhaserMaxFreqHz) / 2 +
          ModR * ((PhaserMaxFreqHz - PhaserMinFreqHz) / 2) * DepthFrac;

        PhFeedbackFrac := AEffect.PhaserFeedbackPercent / 100;
        if PhFeedbackFrac > 0.95 then PhFeedbackFrac := 0.95;
        if PhFeedbackFrac < 0 then PhFeedbackFrac := 0;

        PhInL := L + AState.PhaserFeedbackSample[0] * PhFeedbackFrac;
        PhInR := R + AState.PhaserFeedbackSample[1] * PhFeedbackFrac;

        PhOutL := PhInL;
        PhOutR := PhInR;
        for s := 0 to PhaserStageCount - 1 do
        begin
          PhOutL := ProcessAllpassFirstOrder(AState.PhaserZ1x[0, s], AState.PhaserZ1y[0, s],
            PhOutL, PhFreqL, ASampleRate);
          PhOutR := ProcessAllpassFirstOrder(AState.PhaserZ1x[1, s], AState.PhaserZ1y[1, s],
            PhOutR, PhFreqR, ASampleRate);
        end;

        AState.PhaserFeedbackSample[0] := PhOutL;
        AState.PhaserFeedbackSample[1] := PhOutR;

        MixFrac := AEffect.PhaserMixPercent / 100;
        L := L * (1 - MixFrac) + PhOutL * MixFrac;
        R := R * (1 - MixFrac) + PhOutR * MixFrac;

        AState.PhaserPhase := AState.PhaserPhase + AEffect.PhaserRateHz / ASampleRate;
        if AState.PhaserPhase >= 1 then
          AState.PhaserPhase := AState.PhaserPhase - 1;
      end;
    ekSidechain:
      begin
        { classic ducker: an envelope follower on another track's level,
          gating this track's gain down whenever that source crosses
          Threshold - mainly for keying a bass/pad track off a kick track so
          it visibly "breathes" with it. Attack/Release smoothing (not an
          instant snap like the Limiter above) is what makes the duck read
          as musical pumping rather than a click. }
        if AEffect.SidechainThresholdDb <> AState.LastSidechainThresholdDb then
        begin
          AState.SidechainThresholdLin := Power(10, AEffect.SidechainThresholdDb / 20);
          AState.LastSidechainThresholdDb := AEffect.SidechainThresholdDb;
        end;
        ThresholdLin := AState.SidechainThresholdLin;

        ScStrengthFrac := AEffect.SidechainStrengthPercent / 100;
        if ScStrengthFrac > 1 then ScStrengthFrac := 1;
        if ScStrengthFrac < 0 then ScStrengthFrac := 0;

        if ASidechainLevel > ThresholdLin then
          TargetGain := 1 - ScStrengthFrac
        else
          TargetGain := 1.0;

        if TargetGain < AState.SidechainGain then
        begin
          ScAttackMs := AEffect.SidechainAttackMs;
          if ScAttackMs < 1 then ScAttackMs := 1;
          if ScAttackMs <> AState.LastSidechainAttackMs then
          begin
            AState.SidechainAttackCoeff := Exp(-1 / (0.001 * ScAttackMs * ASampleRate));
            AState.LastSidechainAttackMs := ScAttackMs;
          end;
          ScAttackCoeff := AState.SidechainAttackCoeff;
          AState.SidechainGain := TargetGain + (AState.SidechainGain - TargetGain) * ScAttackCoeff;
        end
        else
        begin
          ReleaseMs := AEffect.SidechainReleaseMs;
          if ReleaseMs < 1 then ReleaseMs := 1;
          if ReleaseMs <> AState.LastSidechainReleaseMs then
          begin
            AState.SidechainReleaseCoeff := Exp(-1 / (0.001 * ReleaseMs * ASampleRate));
            AState.LastSidechainReleaseMs := ReleaseMs;
          end;
          ReleaseCoeff := AState.SidechainReleaseCoeff;
          AState.SidechainGain := TargetGain + (AState.SidechainGain - TargetGain) * ReleaseCoeff;
        end;

        L := L * AState.SidechainGain;
        R := R * AState.SidechainGain;
      end;
    ekDrowning:
      begin
        { tone stage: darkens the signal before it ever reaches the warble/
          tank below - an attenuated-highs signal decaying into a modulated
          wash is most of what reads as "submerged" rather than just
          "reverb with chorus on it" }
        Freq := ClampFreq(AEffect.DrowningToneHz, ASampleRate);
        if (ASampleRate <> AState.LastSampleRate) or (Freq <> AState.LastLowpassFreq) then
        begin
          ComputeLowpassBiquad(Freq, ASampleRate, LowpassQ, AState.LowpassCoeffs);
          AState.LastLowpassFreq := Freq;
        end;
        ToneL := ProcessBiquad(AState.Channels[0].LowpassBq, AState.LowpassCoeffs, L);
        ToneR := ProcessBiquad(AState.Channels[1].LowpassBq, AState.LowpassCoeffs, R);
        AState.LastSampleRate := ASampleRate;

        { warble stage: same modulated-delay recipe as Chorus, feeding 100%
          into the tank below - the overall dry/wet is controlled once, at
          the very end, not here }
        if AState.ChorusBufL = nil then
        begin
          ChorusBufLen := Round(ASampleRate * ChorusMaxDelayMs / 1000) + 1;
          SetLength(AState.ChorusBufL, ChorusBufLen);
          SetLength(AState.ChorusBufR, ChorusBufLen);
          AState.ChorusWritePos := 0;
          AState.ChorusPhase := 0;
        end;
        ChorusBufLen := Length(AState.ChorusBufL);
        AState.ChorusBufL[AState.ChorusWritePos] := ToneL;
        AState.ChorusBufR[AState.ChorusWritePos] := ToneR;

        DepthFrac := AEffect.DrowningWarbleDepthPercent / 100;
        ModL := Sin(2 * Pi * AState.ChorusPhase);
        ModR := Sin(2 * Pi * AState.ChorusPhase + Pi / 2);
        DelayMsL := ChorusCenterDelayMs + ModL * ChorusModRangeMs * DepthFrac;
        DelayMsR := ChorusCenterDelayMs + ModR * ChorusModRangeMs * DepthFrac;
        WetL := ReadDelayInterp(AState.ChorusBufL, ChorusBufLen,
          AState.ChorusWritePos - DelayMsL * ASampleRate / 1000);
        WetR := ReadDelayInterp(AState.ChorusBufR, ChorusBufLen,
          AState.ChorusWritePos - DelayMsR * ASampleRate / 1000);
        AState.ChorusWritePos := (AState.ChorusWritePos + 1) mod ChorusBufLen;
        AState.ChorusPhase := AState.ChorusPhase + AEffect.DrowningWarbleRateHz / ASampleRate;
        if AState.ChorusPhase >= 1 then
          AState.ChorusPhase := AState.ChorusPhase - 1;

        { blend some unmodulated tone back in under the warble - pure 100%
          warble reads as thin and watery; keeping some solid signal under
          it gives the tank something to actually decay from }
        WetL := 0.6 * ToneL + 0.4 * WetL;
        WetR := 0.6 * ToneR + 0.4 * WetR;

        { tank stage: same comb/allpass recipe as Basic Reverb, sized off
          the continuous Size slider instead of a fixed preset }
        RvRoomScale := 0.4 + (AEffect.DrowningSizePercent / 100) * 1.6;
        RvFeedback := 0.5 + (AEffect.DrowningDecayPercent / 100) * 0.45;
        RvDamping := 0.35;
        if (AState.DrowningLastSizePercent <> AEffect.DrowningSizePercent) or
          (AState.DrowningLastSampleRate <> ASampleRate) then
        begin
          SetupReverbTank(AState, RvRoomScale, ASampleRate);
          AState.DrowningLastSizePercent := AEffect.DrowningSizePercent;
          AState.DrowningLastSampleRate := ASampleRate;
        end;
        RvDamp1 := RvDamping;
        RvDamp2 := 1 - RvDamp1;
        RvInputMono := (WetL + WetR) * 0.5;

        RvWetL := 0;
        RvWetR := 0;
        for c := 0 to ReverbCombCount - 1 do
        begin
          RvWetL := RvWetL + ProcessComb(AState.ReverbCombL[c], RvInputMono,
            RvFeedback, RvDamp1, RvDamp2);
          RvWetR := RvWetR + ProcessComb(AState.ReverbCombR[c], RvInputMono,
            RvFeedback, RvDamp1, RvDamp2);
        end;
        RvWetL := RvWetL / ReverbCombCount;
        RvWetR := RvWetR / ReverbCombCount;

        for c := 0 to ReverbAllpassCount - 1 do
        begin
          RvWetL := ProcessAllpass(AState.ReverbAllpassL[c], RvWetL, ReverbAllpassFeedback);
          RvWetR := ProcessAllpass(AState.ReverbAllpassR[c], RvWetR, ReverbAllpassFeedback);
        end;

        MixFrac := AEffect.DrowningMixPercent / 100;
        L := L * (1 - MixFrac) + RvWetL * MixFrac;
        R := R * (1 - MixFrac) + RvWetR * MixFrac;
      end;
  end;
end;

end.
