unit Effects;

{$mode objfpc}{$H+}

interface

uses
  BiquadFilters;

const
  MaxEffectsPerTrack = 4;
  MaxEQBands = 4;

  ekNone = 0;
  ekLowpass = 1;
  ekEQ4 = 2;

type
  { plain flat record with fields used depending on Kind, matching the
    project's existing tagged-record style (see AudioEngine.TCommand) rather
    than a strict Pascal variant record }
  TEffect = record
    Kind: Integer;
    LowpassFreqHz: Single;
    EQFreqHz: array[0..MaxEQBands - 1] of Single;
    EQGainDb: array[0..MaxEQBands - 1] of Single;
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
  end;
end;

end.
