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

  { classic vintage-style chorus (think Ableton Live 1/2's Chorus, or a
    tracker's chorus command) - just a short modulated delay line per
    channel, mixed 50/50 with the dry signal, no feedback/multi-voice
    ensemble stacking like a modern chorus. L and R LFOs run 90 degrees out
    of phase for stereo width, which is most of what makes it sound "wide"
    rather than just wobbly. }
  ChorusCenterDelayMs = 15.0;
  ChorusModRangeMs = 8.0;
  ChorusMaxDelayMs = 30.0;

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
  end;

  TEffectChannelState = record
    LowpassBq: TBiquadState;
    EQBq: array[0..MaxEQBands - 1] of TBiquadState;
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
  end;
end;

end.
