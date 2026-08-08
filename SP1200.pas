unit SP1200;

{$mode objfpc}{$H+}

interface

const
  { the hardware's fixed converter rate and bit depth - never configurable,
    matching the real box }
  SP1200SampleRate = 26040;
  SP1200QuantLevels = 2048; { 2^11 - signed 12-bit full-scale }

type
  TBiquadCoeffs = record
    B0, B1, B2, A1, A2: Single;
  end;

  TBiquadState = record
    X1, X2, Y1, Y2: Single;
  end;

  TSP1200Channel = record
    PreBq1, PreBq2: TBiquadState; { anti-aliasing stage ahead of the "ADC" }
    PostBq: TBiquadState;         { reconstruction stage after the "DAC" }
    HeldValue: Single;            { sample-and-hold register for decimation }
    Phase: Double;
  end;

  TSP1200State = record
    Channels: array[0..1] of TSP1200Channel;
    PreCoeffs: TBiquadCoeffs;
    PostCoeffs: TBiquadCoeffs;
    LastSampleRate: Integer; { 0 forces a coefficient recompute on first use }
  end;

{ Zeroes all filter/decimation history - call once when a state record is
  first brought into use (never mid-stream, that would click). }
procedure SP1200Reset(var AState: TSP1200State);

{ Runs the emulation in place over an interleaved buffer of AChannels
  channels (max 2, matching Eris' fixed stereo output). Shared by both the
  realtime engine and offline WAV export so on/off behaves identically for
  monitored playback and rendered files. Backend-agnostic by construction -
  it only ever touches the float mix buffer, never anything backend-specific. }
procedure SP1200Process(var AState: TSP1200State; ABuffer: PSingle;
  AFrameCount: Int64; AChannels: Integer; AProjectSampleRate: Integer);

implementation

procedure ComputeLowpassBiquad(AFc, AFs, AQ: Double; out ACoeffs: TBiquadCoeffs);
var
  w0, alpha, cosw0, a0: Double;
begin
  w0 := 2 * Pi * AFc / AFs;
  alpha := Sin(w0) / (2 * AQ);
  cosw0 := Cos(w0);
  a0 := 1 + alpha;
  ACoeffs.B0 := ((1 - cosw0) / 2) / a0;
  ACoeffs.B1 := (1 - cosw0) / a0;
  ACoeffs.B2 := ACoeffs.B0;
  ACoeffs.A1 := (-2 * cosw0) / a0;
  ACoeffs.A2 := (1 - alpha) / a0;
end;

function ProcessBiquad(var AState: TBiquadState; const ACoeffs: TBiquadCoeffs;
  AInput: Single): Single;
var
  Output: Single;
begin
  Output := ACoeffs.B0 * AInput + ACoeffs.B1 * AState.X1 + ACoeffs.B2 * AState.X2
    - ACoeffs.A1 * AState.Y1 - ACoeffs.A2 * AState.Y2;
  AState.X2 := AState.X1;
  AState.X1 := AInput;
  AState.Y2 := AState.Y1;
  AState.Y1 := Output;
  Result := Output;
end;

procedure SP1200Reset(var AState: TSP1200State);
begin
  FillChar(AState, SizeOf(AState), 0);
end;

procedure SP1200Process(var AState: TSP1200State; ABuffer: PSingle;
  AFrameCount: Int64; AChannels: Integer; AProjectSampleRate: Integer);
const
  { gentle multi-pole approximation of the SP-1200's analog anti-alias and
    reconstruction filters - not a measured transfer function, just a
    reasonable stand-in shape (soft rolloff starting well under the 13020Hz
    Nyquist of the 26040Hz converter rate) }
  PreFilterCutoffHz = 9500;
  PreFilterQ = 0.707;
  PostFilterCutoffHz = 11000;
  PostFilterQ = 0.707;
var
  Frame: Int64;
  ch: Integer;
  Idx: Int64;
  Input, Filtered, Quantized, Output: Single;
  QInt: Integer;
begin
  if AProjectSampleRate <> AState.LastSampleRate then
  begin
    ComputeLowpassBiquad(PreFilterCutoffHz, AProjectSampleRate, PreFilterQ,
      AState.PreCoeffs);
    ComputeLowpassBiquad(PostFilterCutoffHz, AProjectSampleRate, PostFilterQ,
      AState.PostCoeffs);
    AState.LastSampleRate := AProjectSampleRate;
  end;

  for Frame := 0 to AFrameCount - 1 do
    for ch := 0 to AChannels - 1 do
    begin
      if ch > High(AState.Channels) then
        Continue;

      Idx := Frame * AChannels + ch;
      Input := ABuffer[Idx];

      { anti-aliasing filter, ahead of the "ADC" }
      Filtered := ProcessBiquad(AState.Channels[ch].PreBq1, AState.PreCoeffs, Input);
      Filtered := ProcessBiquad(AState.Channels[ch].PreBq2, AState.PreCoeffs, Filtered);

      { decimate to 26040Hz via a fractional-phase sample-and-hold, so the
        ratio is exact regardless of the project's own sample rate }
      AState.Channels[ch].Phase := AState.Channels[ch].Phase +
        (SP1200SampleRate / AProjectSampleRate);
      if AState.Channels[ch].Phase >= 1.0 then
      begin
        AState.Channels[ch].Phase := AState.Channels[ch].Phase - 1.0;
        AState.Channels[ch].HeldValue := Filtered;
      end;

      { truncate to 12-bit, no dither - matching the real converter }
      Quantized := AState.Channels[ch].HeldValue;
      if Quantized > 1.0 then
        Quantized := 1.0
      else if Quantized < -1.0 then
        Quantized := -1.0;
      QInt := Trunc(Quantized * SP1200QuantLevels);
      Quantized := QInt / SP1200QuantLevels;

      { reconstruction filter, after the "DAC" }
      Output := ProcessBiquad(AState.Channels[ch].PostBq, AState.PostCoeffs, Quantized);

      ABuffer[Idx] := Output;
    end;
end;

end.
