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

  { classic vintage-style chorus (think Ableton Live 1/2's Chorus, or a
    tracker's chorus command) - just a short modulated delay line per
    channel, mixed 50/50 with the dry signal, no feedback/multi-voice
    ensemble stacking like a modern chorus. L and R LFOs run 90 degrees out
    of phase for stereo width, which is most of what makes it sound "wide"
    rather than just wobbly. }
  ChorusCenterDelayMs = 15.0;
  ChorusModRangeMs = 8.0;
  ChorusMaxDelayMs = 30.0;

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
    ChorusBufL: array of Single; { lazily sized once the sample rate is known }
    ChorusBufR: array of Single;
    ChorusWritePos: Integer;
    ChorusPhase: Single; { 0..1, one full LFO cycle }
    ReverbCombL, ReverbCombR: array[0..ReverbCombCount - 1] of TCombState;
    ReverbAllpassL, ReverbAllpassR: array[0..ReverbAllpassCount - 1] of TAllpassState;
    ReverbLastPreset: Integer; { -1 = not yet set up, forces setup on first use }
    ReverbLastSampleRate: Integer;
  end;

procedure EffectStateReset(var AState: TEffectState);
procedure DefaultEffect(AKind: Integer; out AEffect: TEffect);

{ Runs one track-insert effect over a single frame's L/R in place. Coefficient
  recomputation only happens when a parameter actually changed since the
  last call, so turning a knob is cheap and holding it still is even cheaper. }
procedure ProcessEffect(var AState: TEffectState; const AEffect: TEffect;
  var L, R: Single; ASampleRate: Integer);

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

{ (Re)allocates every comb/allpass delay line for the current preset and
  sample rate. Only called when either actually changes - not per-sample. }
procedure SetupReverb(var AState: TEffectState; APreset, ASampleRate: Integer);
var
  RoomScale, Feedback, Damping: Single;
  c, StereoSpreadSamples, LenL, LenR: Integer;
begin
  ReverbPresetParams(APreset, RoomScale, Feedback, Damping);
  StereoSpreadSamples := Round(ReverbStereoSpreadSamples44k * ASampleRate / 44100);

  for c := 0 to ReverbCombCount - 1 do
  begin
    LenL := Round(ReverbCombBaseMs[c] * RoomScale * ASampleRate / 1000);
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
    LenL := Round(ReverbAllpassBaseMs[c] * RoomScale * ASampleRate / 1000);
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

function ClampFreq(AFreqHz: Single; ASampleRate: Integer): Single;
begin
  Result := AFreqHz;
  if Result < 20 then
    Result := 20;
  if Result > ASampleRate * 0.49 then
    Result := ASampleRate * 0.49;
end;

procedure ProcessEffect(var AState: TEffectState; const AEffect: TEffect;
  var L, R: Single; ASampleRate: Integer);
var
  b: Integer;
  Freq: Single;
  ThresholdLin, Peak, TargetGain, ReleaseCoeff, ReleaseMs: Single;
  ChorusBufLen: Integer;
  ModL, ModR, DelayMsL, DelayMsR, DepthFrac, WetL, WetR: Double;
  c: Integer;
  RvRoomScale, RvFeedback, RvDamping, RvDamp1, RvDamp2: Single;
  RvDryL, RvDryR, RvInputMono, RvWetL, RvWetR, RvMixFrac: Single;
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
        ThresholdLin := Power(10, AEffect.LimiterThresholdDb / 20);
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
          ReleaseCoeff := Exp(-1 / (0.001 * ReleaseMs * ASampleRate));
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
  end;
end;

end.
