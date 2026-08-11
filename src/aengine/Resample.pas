unit Resample;

{$mode objfpc}{$H+}
{$INLINE ON}

interface

type
  TInterpolateFunc = function(AData: PSingle; AFrameCount, AChannels,
    AChannel: Integer; APosition: Double): Single;

var
  { The indirection, kept only for anything that genuinely needs to swap the
    implementation at runtime. NOTHING currently does - it is assigned once
    below and never reassigned - so every hot caller now calls
    LinearInterpolate DIRECTLY instead.

    That matters more than it looks. A procedure VARIABLE is an indirect call
    the compiler cannot inline or devirtualise, and this is the innermost
    function in the engine: the warp path calls it once per channel per
    output frame per clip, i.e. twice per frame per playing clip, for a body
    that is about fifteen instructions. The call overhead was a sizeable
    fraction of the work. WavDecoder.ResampleToCanonical had already written
    the loop out by hand for exactly this reason; the realtime callers just
    could not, because their position varies per sample.

    Bit-exact, trivially: the direct calls run the SAME function body with the
    same operands in the same order. Only the call sequence changed. }
  Interpolate: TInterpolateFunc;

{ Marked inline so the direct callers can absorb it. Cross-unit inlining
  needs the directive on the interface declaration as well as the
  implementation one. }
function LinearInterpolate(AData: PSingle; AFrameCount, AChannels,
  AChannel: Integer; APosition: Double): Single; inline;
function SemitonesToRate(ASemitones: Single): Double;

implementation

uses
  Math;

function LinearInterpolate(AData: PSingle; AFrameCount, AChannels,
  AChannel: Integer; APosition: Double): Single; inline;
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
