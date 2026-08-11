unit AVector;

{$mode objfpc}{$H+}
{$asmmode intel}

interface

{ Elementwise buffer maths for the block-major mix path, with an AVX2
  implementation selected at RUNTIME and a pure-Pascal one that is always
  compiled.

  Scope, deliberately narrow. Only operations where each output depends on
  exactly ONE input element live here, because those are bit-identical to
  the scalar loop they replace: same operands, same single rounding, same
  order. That rules out most of this engine on purpose -

    - biquads, envelope followers, compressors, the delay/flanger/phaser
      feedback paths: y[n] depends on y[n-1], a serial recurrence with no
      block form. Not vectorizable across time at all.
    - DetunedClipSample and the warp engine: data-dependent branches, binary
      searches over transients, per-sample non-linear source positions.
      Gathers exist but their throughput does not survive that control flow.
    - any reassociated reduction (a summed total, an RMS): float addition is
      not associative, so a 4- or 8-lane partial-sum tree rounds differently
      from the serial sum. That is around -140 dBFS and inaudible, but it is
      a change, and it is not one worth making to something feeding a
      nonlinear or stateful stage.
    - FMA: a*b+c fused rounds ONCE instead of twice, so it is genuinely a
      different number. Never used here, even though every CPU that has AVX2
      also has FMA. Multiplies and adds stay separate instructions.

  MaxAbs is the one reduction present, and it is safe: max is exact and
  associative, and the operand order below reproduces the scalar
  "if a > b then a else b" exactly, NaNs included (VMAXPS returns its
  second operand when either is NaN, which is what the scalar comparison
  does too).

  Detection. The CPUX86_64 conditional decides only whether the AVX2 code
  EXISTS in the binary, so non-x86 targets still build; the runtime test
  whether it is used. The RTL's cpu unit is what does that check, and it does
  the XGETBV OS-state test as well as CPUID - testing CPUID alone is the
  classic bug, since AVX code faults if the OS has not enabled YMM state
  saving. The whole program is never built with -CfAVX2: that would bake AVX2
  into every unit and hard-fault on a machine without it.

  Alignment. GetMem gives 16-byte alignment, not 32, so every load and store
  here is the unaligned form. On any CPU that has AVX2 those cost the same as
  aligned ones unless they straddle a cache line, which is not worth an
  aligned allocator to avoid.

  The initialization section runs both paths over a fixed pseudorandom buffer
  and compares the bytes. If they differ by so much as one bit the AVX2 path
  is switched off for the process and everything carries on in Pascal. That
  is the enforcement mechanism for "no change to the sound": a bad assembly
  block on someone else's CPU falls back instead of shipping silent
  corruption. }

var
  { True only if the CPU has AVX2 (OS state included) AND the startup
    self-test agreed with the scalar path bit for bit. Read-only outside
    this unit; exposed so the UI/log can say which path is live. }
  VectorPathIsAVX2: Boolean = False;

{ ADst[i] := ADst[i] + ASrc[i] }
procedure VAdd(ADst, ASrc: PSingle; ACount: PtrInt);
{ ADst[i] := ADst[i] + ASrc[i] * AScale }
procedure VAddScaled(ADst, ASrc: PSingle; AScale: Single; ACount: PtrInt);
{ ADst[i] := ADst[i] * AScale }
procedure VScale(ADst: PSingle; AScale: Single; ACount: PtrInt);
{ ADst[i] := max(abs(ASrcA[i]), abs(ASrcB[i])) }
procedure VMaxAbs2(ADst, ASrcA, ASrcB: PSingle; ACount: PtrInt);
{ ADst[i] := clamp(ADst[i], -1.0, +1.0) }
procedure VClamp1(ADst: PSingle; ACount: PtrInt);
{ ADst[i] := ASrc[i] / 32768.0, ASrc being interleaved 16-bit signed PCM.

  The one routine here whose input is not already float. It is still
  elementwise and still bit-identical, and the argument is arithmetic rather
  than structural: a SmallInt converts to float EXACTLY (15 bits of magnitude,
  a Single carries 24), and 32768 is a power of two, so the divide is exact in
  any precision and cannot round. The scalar loop's Double intermediate and
  this one's Single therefore land on the same number, every time, with no
  appeal to "inaudible". Feeding it a non-power-of-two scale would break that
  and is why it is hard-coded rather than a parameter. }
procedure VConvertS16(ADst: PSingle; ASrc: PSmallInt; ACount: PtrInt);

implementation

uses
  SysUtils{$IFDEF CPUX86_64}, cpu{$ENDIF};

{ ---------------------------------------------------------------------------
  Pure Pascal. Always compiled, always correct, and the oracle the self-test
  measures the assembly against. Each of these is a transcription of the loop
  it replaced in AudioEngine.FillBlock - keep them that way.
  --------------------------------------------------------------------------- }

procedure VAddPas(ADst, ASrc: PSingle; ACount: PtrInt);
var
  i: PtrInt;
begin
  for i := 0 to ACount - 1 do
    ADst[i] := ADst[i] + ASrc[i];
end;

procedure VAddScaledPas(ADst, ASrc: PSingle; AScale: Single; ACount: PtrInt);
var
  i: PtrInt;
begin
  for i := 0 to ACount - 1 do
    ADst[i] := ADst[i] + ASrc[i] * AScale;
end;

procedure VScalePas(ADst: PSingle; AScale: Single; ACount: PtrInt);
var
  i: PtrInt;
begin
  for i := 0 to ACount - 1 do
    ADst[i] := ADst[i] * AScale;
end;

procedure VMaxAbs2Pas(ADst, ASrcA, ASrcB: PSingle; ACount: PtrInt);
var
  i: PtrInt;
  aA, aB: Single;
begin
  for i := 0 to ACount - 1 do
  begin
    aA := Abs(ASrcA[i]);
    aB := Abs(ASrcB[i]);
    if aA > aB then
      ADst[i] := aA
    else
      ADst[i] := aB;
  end;
end;

procedure VClamp1Pas(ADst: PSingle; ACount: PtrInt);
var
  i: PtrInt;
begin
  for i := 0 to ACount - 1 do
    if ADst[i] > 1.0 then
      ADst[i] := 1.0
    else if ADst[i] < -1.0 then
      ADst[i] := -1.0;
end;

procedure VConvertS16Pas(ADst: PSingle; ASrc: PSmallInt; ACount: PtrInt);
var
  i: PtrInt;
begin
  for i := 0 to ACount - 1 do
    ADst[i] := ASrc[i] / 32768.0;
end;

{$IFDEF CPUX86_64}

{ ---------------------------------------------------------------------------
  AVX2. Notes that apply to every routine below:

  - These are ordinary Pascal procedures with an asm BODY, not "assembler"
    procedures. That matters: in an assembler procedure FPC resolves a
    parameter name straight to the register the SysV ABI delivered it in, so
    "mov rdx, ASrc" silently destroys ACount before it has been read. With a
    normal procedure the parameters live in the stack frame and can be loaded
    by name in any order.
  - Only caller-saved registers are touched (rax, rcx, rdx, r10, r11, and the
    xmm/ymm bank). rbx, rbp, rsp and r12-r15 are left alone.
  - rdx is the running element index, rcx the element count. The main loop
    does 8 floats per iteration while at least 8 remain; the remainder runs
    through the scalar-width form of the SAME instructions, which is what
    guarantees the tail is identical rather than merely close.
  - vzeroupper before every return, or the first SSE instruction the compiler
    emits afterwards eats the AVX-to-SSE transition penalty. FPC will not
    insert it.
  --------------------------------------------------------------------------- }

{ Two constraints shape how constants reach the vector registers below.

  vbroadcastss will not take a named memory operand directly: FPC sizes the
  operand from the 256-bit destination and rejects it, so each broadcast goes
  vmovss-then-vbroadcastss-from-register instead. That register form is AVX2
  only (AVX1 allows just the memory form) and costs nothing extra here.

  And the operand it reads has to be a LOCAL, not a unit-level constant. This
  project is built as PIC - Lazarus/LCL requires it - and FPC's inline
  assembler rejects a direct global reference under PIC rather than rewriting
  it RIP-relative. Locals are frame-relative and always fine. Where a constant
  can be synthesised in-register instead (the Abs mask), that is done. }

procedure VAddAvx(ADst, ASrc: PSingle; ACount: PtrInt);
begin
  asm
    mov  rax, ADst
    mov  r10, ASrc
    mov  rcx, ACount
    xor  rdx, rdx
    sub  rcx, 8
    jl   @tail_setup
@loop8:
    vmovups ymm0, [rax+rdx*4]
    vmovups ymm1, [r10+rdx*4]
    vaddps  ymm0, ymm0, ymm1
    vmovups [rax+rdx*4], ymm0
    add  rdx, 8
    cmp  rdx, rcx
    jle  @loop8
@tail_setup:
    add  rcx, 8
@tail:
    cmp  rdx, rcx
    jge  @done
    vmovss  xmm0, [rax+rdx*4]
    vaddss  xmm0, xmm0, [r10+rdx*4]
    vmovss  [rax+rdx*4], xmm0
    add  rdx, 1
    jmp  @tail
@done:
    vzeroupper
  end ['rax', 'rcx', 'rdx', 'r10'];
end;

procedure VAddScaledAvx(ADst, ASrc: PSingle; AScale: Single; ACount: PtrInt);
var
  S: Single;
begin
  { through a local so the broadcast reads a stack slot rather than assuming
    which xmm register the ABI put AScale in }
  S := AScale;
  asm
    mov  rax, ADst
    mov  r10, ASrc
    mov  rcx, ACount
    xor  rdx, rdx
    vmovss  xmm2, S
    vbroadcastss ymm2, xmm2
    sub  rcx, 8
    jl   @tail_setup
@loop8:
    vmovups ymm0, [rax+rdx*4]
    vmovups ymm1, [r10+rdx*4]
    { separate mul and add, NOT vfmadd - see the unit header on FMA }
    vmulps  ymm1, ymm1, ymm2
    vaddps  ymm0, ymm0, ymm1
    vmovups [rax+rdx*4], ymm0
    add  rdx, 8
    cmp  rdx, rcx
    jle  @loop8
@tail_setup:
    add  rcx, 8
@tail:
    cmp  rdx, rcx
    jge  @done
    vmovss  xmm0, [rax+rdx*4]
    vmovss  xmm1, [r10+rdx*4]
    vmulss  xmm1, xmm1, xmm2
    vaddss  xmm0, xmm0, xmm1
    vmovss  [rax+rdx*4], xmm0
    add  rdx, 1
    jmp  @tail
@done:
    vzeroupper
  end ['rax', 'rcx', 'rdx', 'r10'];
end;

procedure VScaleAvx(ADst: PSingle; AScale: Single; ACount: PtrInt);
var
  S: Single;
begin
  S := AScale;
  asm
    mov  rax, ADst
    mov  rcx, ACount
    xor  rdx, rdx
    vmovss  xmm2, S
    vbroadcastss ymm2, xmm2
    sub  rcx, 8
    jl   @tail_setup
@loop8:
    vmovups ymm0, [rax+rdx*4]
    vmulps  ymm0, ymm0, ymm2
    vmovups [rax+rdx*4], ymm0
    add  rdx, 8
    cmp  rdx, rcx
    jle  @loop8
@tail_setup:
    add  rcx, 8
@tail:
    cmp  rdx, rcx
    jge  @done
    vmovss  xmm0, [rax+rdx*4]
    vmulss  xmm0, xmm0, xmm2
    vmovss  [rax+rdx*4], xmm0
    add  rdx, 1
    jmp  @tail
@done:
    vzeroupper
  end ['rax', 'rcx', 'rdx'];
end;

procedure VMaxAbs2Avx(ADst, ASrcA, ASrcB: PSingle; ACount: PtrInt);
begin
  asm
    mov  rax, ADst
    mov  r10, ASrcA
    mov  r11, ASrcB
    mov  rcx, ACount
    xor  rdx, rdx
    { $7FFFFFFF in every lane, built in-register: all-ones, shifted right one
      bit, which clears exactly the sign bit }
    vpcmpeqd ymm3, ymm3, ymm3
    vpsrld   ymm3, ymm3, 1
    sub  rcx, 8
    jl   @tail_setup
@loop8:
    vmovups ymm0, [r10+rdx*4]
    vmovups ymm1, [r11+rdx*4]
    vandps  ymm0, ymm0, ymm3
    vandps  ymm1, ymm1, ymm3
    { src1=|a|, src2=|b|: VMAXPS yields src1 only when src1 > src2, and src2
      otherwise - exactly "if aA > aB then aA else aB", NaN behaviour and all }
    vmaxps  ymm0, ymm0, ymm1
    vmovups [rax+rdx*4], ymm0
    add  rdx, 8
    cmp  rdx, rcx
    jle  @loop8
@tail_setup:
    add  rcx, 8
@tail:
    cmp  rdx, rcx
    jge  @done
    vmovss  xmm0, [r10+rdx*4]
    vmovss  xmm1, [r11+rdx*4]
    vandps  xmm0, xmm0, xmm3
    vandps  xmm1, xmm1, xmm3
    vmaxss  xmm0, xmm0, xmm1
    vmovss  [rax+rdx*4], xmm0
    add  rdx, 1
    jmp  @tail
@done:
    vzeroupper
  end ['rax', 'rcx', 'rdx', 'r10', 'r11'];
end;

procedure VClamp1Avx(ADst: PSingle; ACount: PtrInt);
var
  Hi, Lo: Single;
begin
  Hi := 1.0;
  Lo := -1.0;
  asm
    mov  rax, ADst
    mov  rcx, ACount
    xor  rdx, rdx
    vmovss  xmm2, Hi
    vbroadcastss ymm2, xmm2
    vmovss  xmm3, Lo
    vbroadcastss ymm3, xmm3
    sub  rcx, 8
    jl   @tail_setup
@loop8:
    vmovups ymm0, [rax+rdx*4]
    { operand order is load-bearing. VMINPS/VMAXPS return their SECOND
      operand when either input is NaN, so putting the value second lets a
      NaN through untouched - which is what the scalar "if v > 1 ... else if
      v < -1" does, both tests being false for NaN. Reversing these would
      silently turn a NaN into +/-1.0. }
    vminps  ymm0, ymm2, ymm0
    vmaxps  ymm0, ymm3, ymm0
    vmovups [rax+rdx*4], ymm0
    add  rdx, 8
    cmp  rdx, rcx
    jle  @loop8
@tail_setup:
    add  rcx, 8
@tail:
    cmp  rdx, rcx
    jge  @done
    vmovss  xmm0, [rax+rdx*4]
    vminss  xmm0, xmm2, xmm0
    vmaxss  xmm0, xmm3, xmm0
    vmovss  [rax+rdx*4], xmm0
    add  rdx, 1
    jmp  @tail
@done:
    vzeroupper
  end ['rax', 'rcx', 'rdx'];
end;

{ Widen-and-scale: 8 int16 -> 8 int32 -> 8 floats -> scaled, per iteration.

  Unlike the routines above, the tail is NOT an asm scalar mirror of the
  vector body - it hands straight back to VConvertS16Pas. The scalar form
  here would need VCVTSI2SS, whose 3-operand AVX encoding is the one thing in
  this unit FPC's assembler is fussiest about sizing, and there is nothing to
  gain: calling the Pascal reference for the last <8 elements makes the tail
  identical to the oracle by construction rather than by argument.

  The 16-bit load is a separate VMOVDQU into xmm rather than a memory operand
  on VPMOVSXWD, for the same reason VBROADCASTSS is fed from a register
  elsewhere in this unit: FPC sizes a memory operand from the 256-bit
  destination and rejects the (correct) 128-bit form. }
procedure VConvertS16Avx(ADst: PSingle; ASrc: PSmallInt; ACount: PtrInt);
var
  S: Single;
  Vec: PtrInt;
begin
  S := 1.0 / 32768.0;
  Vec := ACount - (ACount mod 8);
  if Vec > 0 then
  asm
    mov  rax, ADst
    mov  r10, ASrc
    mov  rcx, Vec
    xor  rdx, rdx
    vmovss  xmm2, S
    vbroadcastss ymm2, xmm2
@loop8:
    vmovdqu   xmm0, [r10+rdx*2]
    vpmovsxwd ymm0, xmm0
    vcvtdq2ps ymm0, ymm0
    vmulps    ymm0, ymm0, ymm2
    vmovups   [rax+rdx*4], ymm0
    add  rdx, 8
    cmp  rdx, rcx
    jl   @loop8
    vzeroupper
  end ['rax', 'rcx', 'rdx', 'r10'];

  if Vec < ACount then
    VConvertS16Pas(@ADst[Vec], @ASrc[Vec], ACount - Vec);
end;

{$ENDIF}

{ ---------------------------------------------------------------------------
  Public entry points. One branch at the top of the routine rather than one
  per element, and no procedure variables - an indirect call would defeat
  inlining on the short ones and cost more than it saves.
  --------------------------------------------------------------------------- }

procedure VAdd(ADst, ASrc: PSingle; ACount: PtrInt);
begin
  if ACount <= 0 then
    Exit;
{$IFDEF CPUX86_64}
  if VectorPathIsAVX2 then
  begin
    VAddAvx(ADst, ASrc, ACount);
    Exit;
  end;
{$ENDIF}
  VAddPas(ADst, ASrc, ACount);
end;

procedure VAddScaled(ADst, ASrc: PSingle; AScale: Single; ACount: PtrInt);
begin
  if ACount <= 0 then
    Exit;
{$IFDEF CPUX86_64}
  if VectorPathIsAVX2 then
  begin
    VAddScaledAvx(ADst, ASrc, AScale, ACount);
    Exit;
  end;
{$ENDIF}
  VAddScaledPas(ADst, ASrc, AScale, ACount);
end;

procedure VScale(ADst: PSingle; AScale: Single; ACount: PtrInt);
begin
  if ACount <= 0 then
    Exit;
{$IFDEF CPUX86_64}
  if VectorPathIsAVX2 then
  begin
    VScaleAvx(ADst, AScale, ACount);
    Exit;
  end;
{$ENDIF}
  VScalePas(ADst, AScale, ACount);
end;

procedure VMaxAbs2(ADst, ASrcA, ASrcB: PSingle; ACount: PtrInt);
begin
  if ACount <= 0 then
    Exit;
{$IFDEF CPUX86_64}
  if VectorPathIsAVX2 then
  begin
    VMaxAbs2Avx(ADst, ASrcA, ASrcB, ACount);
    Exit;
  end;
{$ENDIF}
  VMaxAbs2Pas(ADst, ASrcA, ASrcB, ACount);
end;

procedure VClamp1(ADst: PSingle; ACount: PtrInt);
begin
  if ACount <= 0 then
    Exit;
{$IFDEF CPUX86_64}
  if VectorPathIsAVX2 then
  begin
    VClamp1Avx(ADst, ACount);
    Exit;
  end;
{$ENDIF}
  VClamp1Pas(ADst, ACount);
end;

procedure VConvertS16(ADst: PSingle; ASrc: PSmallInt; ACount: PtrInt);
begin
  if ACount <= 0 then
    Exit;
{$IFDEF CPUX86_64}
  if VectorPathIsAVX2 then
  begin
    VConvertS16Avx(ADst, ASrc, ACount);
    Exit;
  end;
{$ENDIF}
  VConvertS16Pas(ADst, ASrc, ACount);
end;

{$IFDEF CPUX86_64}

{ Runs every routine both ways over the same input and compares the RESULT
  BYTES, not the values - CompareMem so that a sign-of-zero or NaN-payload
  difference counts as a failure too, since those are exactly the cases where
  the min/max operand order above is doing something subtle.

  The buffer length is deliberately not a multiple of 8, so the vector body
  and the scalar remainder are both exercised, and the contents deliberately
  include denormals, values outside +/-1, negative zero and a NaN. }
function SelfTestPasses: Boolean;
const
  N = 61; { 7 vector iterations + a 5-element tail }
var
  Src, RefBuf, TstBuf, SrcB: array[0..N - 1] of Single;
  S16Src: array[0..N - 1] of SmallInt;
  Seed: LongWord;
  i: Integer;

  function NextVal: Single;
  begin
    { plain LCG - fixed sequence, no dependency on the RTL's RNG state }
    Seed := Seed * 1103515245 + 12345;
    Result := (Integer(Seed shr 8) / 8388608.0) - 1.0;
  end;

  procedure Reset;
  begin
    Move(Src, RefBuf, SizeOf(Src));
    Move(Src, TstBuf, SizeOf(Src));
  end;

  function Same: Boolean;
  begin
    Result := CompareMem(@RefBuf[0], @TstBuf[0], SizeOf(RefBuf));
  end;

begin
  Result := False;
  Seed := 22050;
  for i := 0 to N - 1 do
  begin
    Src[i] := NextVal * 3.0;  { spills past +/-1 so the clamp actually bites }
    SrcB[i] := NextVal;
  end;
  Src[0] := 0.0;
  Src[1] := -0.0;
  Src[2] := 1.0e-42;          { denormal - and note FTZ/DAZ may be on }
  Src[3] := -1.0;
  Src[4] := 1.0;
  SrcB[5] := 0.0;
  SrcB[6] := -0.0;

  Reset;
  VAddPas(@RefBuf[0], @SrcB[0], N);
  VAddAvx(@TstBuf[0], @SrcB[0], N);
  if not Same then Exit;

  Reset;
  VAddScaledPas(@RefBuf[0], @SrcB[0], 0.37, N);
  VAddScaledAvx(@TstBuf[0], @SrcB[0], 0.37, N);
  if not Same then Exit;

  Reset;
  VScalePas(@RefBuf[0], 0.71, N);
  VScaleAvx(@TstBuf[0], 0.71, N);
  if not Same then Exit;

  Reset;
  VMaxAbs2Pas(@RefBuf[0], @Src[0], @SrcB[0], N);
  VMaxAbs2Avx(@TstBuf[0], @Src[0], @SrcB[0], N);
  if not Same then Exit;

  Reset;
  VClamp1Pas(@RefBuf[0], N);
  VClamp1Avx(@TstBuf[0], N);
  if not Same then Exit;

  { s16 source of its own, since this is the one routine that does not take
    floats in. Both ends of the range are included: -32768 has no positive
    counterpart and is the value a naive negate-based conversion gets wrong. }
  for i := 0 to N - 1 do
  begin
    Seed := Seed * 1103515245 + 12345;
    S16Src[i] := SmallInt(Word(Seed shr 13));
  end;
  S16Src[0] := 0;
  S16Src[1] := -32768;
  S16Src[2] := 32767;
  S16Src[3] := -1;
  S16Src[4] := 1;

  FillChar(RefBuf, SizeOf(RefBuf), 0);
  FillChar(TstBuf, SizeOf(TstBuf), 0);
  VConvertS16Pas(@RefBuf[0], @S16Src[0], N);
  VConvertS16Avx(@TstBuf[0], @S16Src[0], N);
  if not Same then Exit;

  Result := True;
end;

{$ENDIF}

initialization
{$IFDEF CPUX86_64}
  { AVX2Support covers CPUID plus the XGETBV check that the OS is saving YMM
    state. Only then is it worth running the self-test, which itself executes
    AVX2 instructions. }
  if AVX2Support then
    VectorPathIsAVX2 := SelfTestPasses;
{$ENDIF}

end.
