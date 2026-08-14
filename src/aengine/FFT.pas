unit FFT;

{$mode objfpc}{$H+}

{ Hand-rolled iterative radix-2 Cooley-Tukey complex FFT, per warp.md's AU
  mode spec ("hand rolled cooley-turkey fft"). N must be a power of two.
  Re/Im are separate Single arrays rather than one array-of-complex, so the
  windowing/magnitude passes around it in PhaseVocoder.pas can go through
  AVector's elementwise SIMD routines without an interleave/deinterleave
  step - see AVector.pas "Elementwise only" rule. }

interface

{ In-place forward (AInverse=False) or inverse (AInverse=True) FFT of length
  AN (power of two) over ARe/AIm. The inverse pass includes the 1/N scale, so
  Forward then Inverse round-trips to the original signal, not N times it. }
procedure FFTComplex(ARe, AIm: PSingle; AN: Integer; AInverse: Boolean);

{ Periodic Hann window, AN samples, written into ADst. Periodic (not
  symmetric) so a run of hopped, overlapped windows sums to a constant per
  the standard STFT/OLA identity - see PhaseVocoder.pas. }
procedure HannWindow(ADst: PSingle; AN: Integer);

implementation

uses
  Math;

procedure FFTComplex(ARe, AIm: PSingle; AN: Integer; AInverse: Boolean);
var
  i, j, k, bit, len, half, half2: Integer;
  tr, ti, wr, wi, wpr, wpi, tmp, ang, sign: Double;
  Sc: Single;
begin
  if AN <= 1 then
    Exit;

  { bit-reversal permutation, in place }
  j := 0;
  for i := 0 to AN - 2 do
  begin
    if i < j then
    begin
      tr := ARe[i]; ARe[i] := ARe[j]; ARe[j] := tr;
      ti := AIm[i]; AIm[i] := AIm[j]; AIm[j] := ti;
    end;
    bit := AN shr 1;
    while (bit >= 1) and ((j and bit) <> 0) do
    begin
      j := j and not bit;
      bit := bit shr 1;
    end;
    j := j or bit;
  end;

  if AInverse then sign := 1.0 else sign := -1.0;

  { iterative Cooley-Tukey: butterfly stages of doubling length, twiddle
    factors recurred by angle addition (standard trig-recurrence, one sin/cos
    per stage rather than per butterfly) }
  len := 2;
  while len <= AN do
  begin
    half := len shr 1;
    ang := sign * 2.0 * Pi / len;
    wpr := Cos(ang);
    wpi := Sin(ang);
    i := 0;
    while i < AN do
    begin
      wr := 1.0;
      wi := 0.0;
      for k := 0 to half - 1 do
      begin
        half2 := i + k + half;
        tr := wr * ARe[half2] - wi * AIm[half2];
        ti := wr * AIm[half2] + wi * ARe[half2];
        ARe[half2] := ARe[i + k] - tr;
        AIm[half2] := AIm[i + k] - ti;
        ARe[i + k] := ARe[i + k] + tr;
        AIm[i + k] := AIm[i + k] + ti;

        tmp := wr;
        wr := wr * wpr - wi * wpi;
        wi := tmp * wpi + wi * wpr;
      end;
      Inc(i, len);
    end;
    len := len shl 1;
  end;

  if AInverse then
  begin
    Sc := 1.0 / AN;
    for i := 0 to AN - 1 do
    begin
      ARe[i] := ARe[i] * Sc;
      AIm[i] := AIm[i] * Sc;
    end;
  end;
end;

procedure HannWindow(ADst: PSingle; AN: Integer);
var
  i: Integer;
begin
  for i := 0 to AN - 1 do
    ADst[i] := 0.5 - 0.5 * Cos(2.0 * Pi * i / AN);
end;

end.
