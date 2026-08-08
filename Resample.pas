unit Resample;

{$mode objfpc}{$H+}

interface

type
  TInterpolateFunc = function(AData: PSingle; AFrameCount, AChannels,
    AChannel: Integer; APosition: Double): Single;

var
  Interpolate: TInterpolateFunc;

function LinearInterpolate(AData: PSingle; AFrameCount, AChannels,
  AChannel: Integer; APosition: Double): Single;
function SemitonesToRate(ASemitones: Single): Double;

implementation

uses
  Math;

function LinearInterpolate(AData: PSingle; AFrameCount, AChannels,
  AChannel: Integer; APosition: Double): Single;
var
  Idx: Integer;
  Frac: Double;
  S0, S1: Single;
begin
  Idx := Trunc(APosition);
  if (Idx < 0) or (Idx >= AFrameCount) then
    Exit(0);

  Frac := APosition - Idx;
  S0 := AData[Idx * AChannels + AChannel];
  if Idx + 1 < AFrameCount then
    S1 := AData[(Idx + 1) * AChannels + AChannel]
  else
    S1 := 0;

  Result := S0 + Frac * (S1 - S0);
end;

function SemitonesToRate(ASemitones: Single): Double;
begin
  Result := Power(2.0, ASemitones / 12.0);
end;

initialization
  Interpolate := @LinearInterpolate;

end.
