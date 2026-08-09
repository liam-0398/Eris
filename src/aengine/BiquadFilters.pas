unit BiquadFilters;

{$mode objfpc}{$H+}

interface

type
  TBiquadCoeffs = record
    B0, B1, B2, A1, A2: Single;
  end;

  TBiquadState = record
    X1, X2, Y1, Y2: Single;
  end;

procedure ComputeLowpassBiquad(AFc, AFs, AQ: Double; out ACoeffs: TBiquadCoeffs);
procedure ComputeHighpassBiquad(AFc, AFs, AQ: Double; out ACoeffs: TBiquadCoeffs);
procedure ComputeBandpassBiquad(AFc, AFs, AQ: Double; out ACoeffs: TBiquadCoeffs);
procedure ComputePeakingBiquad(AFc, AFs, AQ, AGainDb: Double; out ACoeffs: TBiquadCoeffs);
function ProcessBiquad(var AState: TBiquadState; const ACoeffs: TBiquadCoeffs;
  AInput: Single): Single;

implementation

uses
  Math;

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

procedure ComputeHighpassBiquad(AFc, AFs, AQ: Double; out ACoeffs: TBiquadCoeffs);
var
  w0, alpha, cosw0, a0: Double;
begin
  w0 := 2 * Pi * AFc / AFs;
  alpha := Sin(w0) / (2 * AQ);
  cosw0 := Cos(w0);
  a0 := 1 + alpha;
  ACoeffs.B0 := ((1 + cosw0) / 2) / a0;
  ACoeffs.B1 := (-(1 + cosw0)) / a0;
  ACoeffs.B2 := ACoeffs.B0;
  ACoeffs.A1 := (-2 * cosw0) / a0;
  ACoeffs.A2 := (1 - alpha) / a0;
end;

procedure ComputeBandpassBiquad(AFc, AFs, AQ: Double; out ACoeffs: TBiquadCoeffs);
var
  w0, alpha, cosw0, a0: Double;
begin
  w0 := 2 * Pi * AFc / AFs;
  alpha := Sin(w0) / (2 * AQ);
  cosw0 := Cos(w0);
  a0 := 1 + alpha;
  ACoeffs.B0 := alpha / a0;
  ACoeffs.B1 := 0;
  ACoeffs.B2 := -alpha / a0;
  ACoeffs.A1 := (-2 * cosw0) / a0;
  ACoeffs.A2 := (1 - alpha) / a0;
end;

{ standard RBJ cookbook peaking/bell EQ }
procedure ComputePeakingBiquad(AFc, AFs, AQ, AGainDb: Double; out ACoeffs: TBiquadCoeffs);
var
  w0, alpha, cosw0, a0, AAmp: Double;
begin
  AAmp := Power(10, AGainDb / 40);
  w0 := 2 * Pi * AFc / AFs;
  alpha := Sin(w0) / (2 * AQ);
  cosw0 := Cos(w0);
  a0 := 1 + alpha / AAmp;
  ACoeffs.B0 := (1 + alpha * AAmp) / a0;
  ACoeffs.B1 := (-2 * cosw0) / a0;
  ACoeffs.B2 := (1 - alpha * AAmp) / a0;
  ACoeffs.A1 := (-2 * cosw0) / a0;
  ACoeffs.A2 := (1 - alpha / AAmp) / a0;
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

end.
