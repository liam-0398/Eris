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
      also has FMA3. Multiplies and adds stay separate instructions.

  On adding an FMA3 path later. It is a real option, but it does not fit
  under VectorPathIsAVX2 and cannot be bolted on without three things:

    - Its own flag. FMA3 changes results, so it has to be separately
      switchable from AVX2 rather than riding the same boolean. Detection is
      not the hard part: AVX2 implies FMA3 on every shipping x86-64 part
      (Haswell onward, Excavator/Zen onward), and the RTL exposes FMASupport
      anyway if belt and braces is wanted.
    - Its own self-test. SelfTestPasses below is CompareMem, and an FMA path
      fails that BY DESIGN - being a different number is the whole point. It
      would need a second tier comparing against the scalar result within a
      tolerance (1 ULP, or an absolute epsilon well under -140 dBFS) instead
      of byte-for-byte, which is a materially weaker guarantee than what the
      rest of this unit gives.
    - A decision about old projects. The only routine here with anything to
      fuse is VAddScaled - VScale and VScale2 are pure multiplies with no
      addend - and VAddScaled is what the send taps and send returns run
      through. Switching it changes those sums, so a bounce stops matching
      the same project bounced by an earlier build. That is the actual cost;
      the assembly is the easy half.

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

  { The FMA3 tier, and a SEPARATE flag on purpose - see "The analysis tier"
    below. Governs only VDotSum/VDiffSqSum, never anything on the mix path. }
  VectorPathIsFMA3: Boolean = False;

{ ADst[i] := ADst[i] + ASrc[i] }
procedure VAdd(ADst, ASrc: PSingle; ACount: PtrInt);
{ ADst[i] := ADst[i] + ASrc[i] * AScale }
procedure VAddScaled(ADst, ASrc: PSingle; AScale: Single; ACount: PtrInt);
{ ADst[i] := ADst[i] * AScale }
procedure VScale(ADst: PSingle; AScale: Single; ACount: PtrInt);
{ ADstL[i] := ADstL[i] * AScaleL and ADstR[i] := ADstR[i] * AScaleR

  Two VScale calls fused into one pass. Not a new operation - it is exactly
  the pair it replaces, elementwise and bit-identical to each - but the two
  buffers are always walked together at the same length by the caller (a
  stereo track's fader and pan), so doing them in one loop halves the loop
  overhead and interleaves two independent dependency chains, which is free
  throughput on any out-of-order core. }
procedure VScale2(ADstL, ADstR: PSingle; AScaleL, AScaleR: Single; ACount: PtrInt);
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
{ AMin/AMax := the smallest and largest of ASrc[0..ACount-1].

  The second reduction in this unit, and like MaxAbs it earns its place by
  being exact rather than by being inaudible: min and max round nothing, and
  they are associative, so folding eight lanes gives the identical answer a
  left-to-right scan gives. Two cases make that a claim worth stating
  precisely rather than waving at, and both are covered by the self-test:

    - NaN. Every compare here is ordered as "replace the accumulator only if
      the new value strictly wins", which is what the scalar "if V < MinV"
      does, and which VMINPS reproduces when the incoming sample is src1 and
      the accumulator is src2. A NaN therefore never displaces an
      accumulator and never poisons a lane, so the lanes being folded are
      always NaN-free and the fold order cannot matter.
    - Signed zero. -0.0 and +0.0 compare equal, so neither ever strictly
      wins, so whichever the accumulator was seeded with survives - in every
      lane, and therefore through the fold too. The scalar loop keeps the
      same one for the same reason.

  ACount must be at least 1; the seed is ASrc[0]. }
procedure VMinMax(ASrc: PSingle; ACount: PtrInt; out AMin, AMax: Single);

{ ---------------------------------------------------------------------------
  The analysis tier. Reductions, reassociated, FMA-fused - everything the
  routines above are forbidden to do.

  The rule that governs everything above is "each output depends on exactly
  one input element, so it is bit-identical". These two break it and are
  still safe, for a reason that is about WHERE THE ANSWER GOES rather than
  about arithmetic. Both are pitch-detection kernels. Their output is an
  integer lag or a frequency in Hz, consumed by a tuner readout and by warp
  grain placement. Neither value is ever a sample. Neither reaches the mix
  buffer, and neither can affect whether RenderProjectToWav matches
  FillBlock - which is the actual property the no-FMA rule protects.

  So they get what the header says an FMA path would need:

    - their own flag (VectorPathIsFMA3), switchable independently of AVX2,
    - their own self-test, comparing to the Pascal oracle within a TIGHT
      relative tolerance rather than byte for byte. 1e-9 relative is roughly
      a million times looser than the ~1e-16 an FMA fusion moves a term and
      roughly a million times tighter than dropping a single element, so it
      still catches every structural mistake an asm block can make - a wrong
      lane count, a mis-strided load, a skipped tail - while passing the
      rounding difference it exists to permit.

  Both accumulate in DOUBLE, in several independent partial sums, then add
  the partials. That is deliberately not the serial scalar order: one
  accumulator is a dependency chain of 4-cycle adds and leaves the multiply
  units idle three cycles in four, which was the actual cost of both loops.
  The Pascal fallbacks reassociate the same way, so switching paths at
  runtime does not change the answer by more than the tolerance either.

  Neither has an AVX2-without-FMA variant. FMA3 shipped with AVX2 on every
  x86-64 part that has ever sold it (Haswell on, Excavator/Zen on), so the
  case would be dead code; a machine that somehow had one without the other
  falls back to Pascal, which is correct, just slower. }

{ Sum of AA[i] * AB[i]. }
function VDotSum(AA, AB: PSingle; ACount: PtrInt): Double;
{ Sum of (AA[i] - AB[i])^2.

  The difference is taken in SINGLE and only then widened, in both paths.
  That is not a corner cut. Where these callers care - at the lag that IS the
  period - the two operands are close, and Sterbenz's lemma makes a
  same-precision subtraction of nearby values EXACT, so the single subtract
  loses nothing precisely where the minimum is being resolved. Away from the
  period the terms are large and a 1e-7 relative wobble on a number the
  caller only compares against a 0.15 threshold is meaningless. }
function VDiffSqSum(AA, AB: PSingle; ACount: PtrInt): Double;

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

procedure VScale2Pas(ADstL, ADstR: PSingle; AScaleL, AScaleR: Single; ACount: PtrInt);
var
  i: PtrInt;
begin
  for i := 0 to ACount - 1 do
  begin
    ADstL[i] := ADstL[i] * AScaleL;
    ADstR[i] := ADstR[i] * AScaleR;
  end;
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

procedure VMinMaxPas(ASrc: PSingle; ACount: PtrInt; out AMin, AMax: Single);
var
  i: PtrInt;
  mn, mx, v: Single;
begin
  mn := ASrc[0];
  mx := mn;
  for i := 0 to ACount - 1 do
  begin
    v := ASrc[i];
    if v < mn then mn := v;
    if v > mx then mx := v;
  end;
  AMin := mn;
  AMax := mx;
end;

{ The analysis-tier oracles. Four accumulators rather than one, matching the
  assembly's shape - see the interface note. Even with no AVX2 in the binary
  at all this is the faster form, so it is what the callers get either way. }

function VDotSumPas(AA, AB: PSingle; ACount: PtrInt): Double;
var
  i: PtrInt;
  a0, a1, a2, a3: Double;
begin
  a0 := 0; a1 := 0; a2 := 0; a3 := 0;
  i := 0;
  while i + 3 < ACount do
  begin
    a0 := a0 + Double(AA[i]) * AB[i];
    a1 := a1 + Double(AA[i + 1]) * AB[i + 1];
    a2 := a2 + Double(AA[i + 2]) * AB[i + 2];
    a3 := a3 + Double(AA[i + 3]) * AB[i + 3];
    Inc(i, 4);
  end;
  while i < ACount do
  begin
    a0 := a0 + Double(AA[i]) * AB[i];
    Inc(i);
  end;
  Result := (a0 + a1) + (a2 + a3);
end;

function VDiffSqSumPas(AA, AB: PSingle; ACount: PtrInt): Double;
var
  i: PtrInt;
  a0, a1, a2, a3: Double;
  d0, d1, d2, d3: Single;
begin
  a0 := 0; a1 := 0; a2 := 0; a3 := 0;
  i := 0;
  while i + 3 < ACount do
  begin
    { the Single locals are load-bearing: assigning to one forces the
      rounding to Single that the assembly's vsubps does, whatever precision
      FPC evaluated the subtraction in }
    d0 := AA[i] - AB[i];
    d1 := AA[i + 1] - AB[i + 1];
    d2 := AA[i + 2] - AB[i + 2];
    d3 := AA[i + 3] - AB[i + 3];
    a0 := a0 + Double(d0) * d0;
    a1 := a1 + Double(d1) * d1;
    a2 := a2 + Double(d2) * d2;
    a3 := a3 + Double(d3) * d3;
    Inc(i, 4);
  end;
  while i < ACount do
  begin
    d0 := AA[i] - AB[i];
    a0 := a0 + Double(d0) * d0;
    Inc(i);
  end;
  Result := (a0 + a1) + (a2 + a3);
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

{ The one routine here that writes two buffers. Both scale factors are
  broadcast up front (ymm2 for L, ymm3 for R) and the body issues the two
  load/mul/store chains back to back - they touch different registers and
  different memory, so they dual-issue rather than queue. rax and r10 are the
  two destinations; the index and count registers are shared, which is only
  sound because the caller guarantees both buffers are ACount long. }
procedure VScale2Avx(ADstL, ADstR: PSingle; AScaleL, AScaleR: Single; ACount: PtrInt);
var
  SL, SR: Single;
begin
  SL := AScaleL;
  SR := AScaleR;
  asm
    mov  rax, ADstL
    mov  r10, ADstR
    mov  rcx, ACount
    xor  rdx, rdx
    vmovss  xmm2, SL
    vbroadcastss ymm2, xmm2
    vmovss  xmm3, SR
    vbroadcastss ymm3, xmm3
    sub  rcx, 8
    jl   @tail_setup
@loop8:
    vmovups ymm0, [rax+rdx*4]
    vmovups ymm1, [r10+rdx*4]
    vmulps  ymm0, ymm0, ymm2
    vmulps  ymm1, ymm1, ymm3
    vmovups [rax+rdx*4], ymm0
    vmovups [r10+rdx*4], ymm1
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
    vmulss  xmm0, xmm0, xmm2
    vmulss  xmm1, xmm1, xmm3
    vmovss  [rax+rdx*4], xmm0
    vmovss  [r10+rdx*4], xmm1
    add  rdx, 1
    jmp  @tail
@done:
    vzeroupper
  end ['rax', 'rcx', 'rdx', 'r10'];
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

procedure VMinMaxAvx(ASrc: PSingle; ACount: PtrInt; out AMin, AMax: Single);
var
  mn, mx: Single;
begin
  { through locals rather than writing the out-parameters from inside the asm
    block: a var/out parameter's NAME in FPC asm is the referent, not the
    pointer, and there is no need to depend on which of those it resolves to }
  asm
    mov  rax, ASrc
    mov  rcx, ACount
    xor  rdx, rdx
    { both accumulators seeded from element 0, exactly as the scalar does }
    vmovss  xmm2, [rax]
    vbroadcastss ymm2, xmm2
    vmovaps ymm3, ymm2
    sub  rcx, 8
    jl   @tail_setup
@loop8:
    vmovups ymm0, [rax+rdx*4]
    { incoming value is src1, accumulator src2 - the operand order is the
      whole NaN and signed-zero argument, see VMinMax's declaration }
    vminps  ymm2, ymm0, ymm2
    vmaxps  ymm3, ymm0, ymm3
    add  rdx, 8
    cmp  rdx, rcx
    jle  @loop8
@tail_setup:
    add  rcx, 8
    { fold 8 lanes to 1, same operand order throughout }
    vextractf128 xmm0, ymm2, 1
    vminps  xmm2, xmm0, xmm2
    vshufps xmm0, xmm2, xmm2, $0E
    vminps  xmm2, xmm0, xmm2
    vshufps xmm0, xmm2, xmm2, $01
    vminss  xmm2, xmm0, xmm2
    vextractf128 xmm1, ymm3, 1
    vmaxps  xmm3, xmm1, xmm3
    vshufps xmm1, xmm3, xmm3, $0E
    vmaxps  xmm3, xmm1, xmm3
    vshufps xmm1, xmm3, xmm3, $01
    vmaxss  xmm3, xmm1, xmm3
@tail:
    cmp  rdx, rcx
    jge  @done
    vmovss  xmm0, [rax+rdx*4]
    vminss  xmm2, xmm0, xmm2
    vmaxss  xmm3, xmm0, xmm3
    add  rdx, 1
    jmp  @tail
@done:
    vmovss  mn, xmm2
    vmovss  mx, xmm3
    vzeroupper
  end ['rax', 'rcx', 'rdx'];
  AMin := mn;
  AMax := mx;
end;

{ ---------------------------------------------------------------------------
  FMA3. Same house rules as the AVX2 block above - asm body inside a normal
  procedure so parameters live in the frame, only caller-saved registers,
  vzeroupper before returning - plus two of its own:

  - Four ymm accumulators of four DOUBLES each, sixteen input floats an
    iteration. Four is not arbitrary: vfmadd has about four cycles of
    latency against two issue ports, so fewer than four independent chains
    leaves the ports idle and more than four buys nothing here, where the
    working set is a few kilobytes and already in L1.
  - Every widening goes vmovups-to-xmm then vcvtps2pd-from-REGISTER, never
    vcvtps2pd straight from memory. The memory form takes a 128-bit operand
    against a 256-bit destination and FPC sizes memory operands from the
    destination, so it rejects it - the same trap the vbroadcastss note
    above describes, in a different instruction.

  The result comes back through a Double local rather than being left in
  xmm0: FPC owns the function-result register and writing it from inside an
  asm body would be assuming a calling convention that the rest of this unit
  is careful not to assume.
  --------------------------------------------------------------------------- }

function VDotSumFma(AA, AB: PSingle; ACount: PtrInt): Double;
var
  Acc: Double;
begin
  asm
    mov  rax, AA
    mov  r10, AB
    mov  rcx, ACount
    xor  rdx, rdx
    vxorpd ymm4, ymm4, ymm4
    vxorpd ymm5, ymm5, ymm5
    vxorpd ymm6, ymm6, ymm6
    vxorpd ymm7, ymm7, ymm7
    sub  rcx, 16
    jl   @tail_setup
@loop16:
    vmovups   xmm0, [rax+rdx*4]
    vmovups   xmm1, [r10+rdx*4]
    vcvtps2pd ymm0, xmm0
    vcvtps2pd ymm1, xmm1
    vfmadd231pd ymm4, ymm0, ymm1
    vmovups   xmm0, [rax+rdx*4+16]
    vmovups   xmm1, [r10+rdx*4+16]
    vcvtps2pd ymm0, xmm0
    vcvtps2pd ymm1, xmm1
    vfmadd231pd ymm5, ymm0, ymm1
    vmovups   xmm0, [rax+rdx*4+32]
    vmovups   xmm1, [r10+rdx*4+32]
    vcvtps2pd ymm0, xmm0
    vcvtps2pd ymm1, xmm1
    vfmadd231pd ymm6, ymm0, ymm1
    vmovups   xmm0, [rax+rdx*4+48]
    vmovups   xmm1, [r10+rdx*4+48]
    vcvtps2pd ymm0, xmm0
    vcvtps2pd ymm1, xmm1
    vfmadd231pd ymm7, ymm0, ymm1
    add  rdx, 16
    cmp  rdx, rcx
    jle  @loop16
@tail_setup:
    add  rcx, 16
    { fold the four accumulators, then the four lanes, into xmm4 low }
    vaddpd ymm4, ymm4, ymm5
    vaddpd ymm6, ymm6, ymm7
    vaddpd ymm4, ymm4, ymm6
    vextractf128 xmm5, ymm4, 1
    vaddpd xmm4, xmm4, xmm5
    vhaddpd xmm4, xmm4, xmm4
@tail:
    cmp  rdx, rcx
    jge  @done
    { register-form widen, for the operand-sizing reason in the block header }
    vmovss xmm0, [rax+rdx*4]
    vmovss xmm1, [r10+rdx*4]
    vcvtss2sd xmm0, xmm0, xmm0
    vcvtss2sd xmm1, xmm1, xmm1
    vmulsd xmm0, xmm0, xmm1
    vaddsd xmm4, xmm4, xmm0
    add  rdx, 1
    jmp  @tail
@done:
    vmovsd Acc, xmm4
    vzeroupper
  end ['rax', 'rcx', 'rdx', 'r10'];
  Result := Acc;
end;

function VDiffSqSumFma(AA, AB: PSingle; ACount: PtrInt): Double;
var
  Acc: Double;
begin
  asm
    mov  rax, AA
    mov  r10, AB
    mov  rcx, ACount
    xor  rdx, rdx
    vxorpd ymm4, ymm4, ymm4
    vxorpd ymm5, ymm5, ymm5
    vxorpd ymm6, ymm6, ymm6
    vxorpd ymm7, ymm7, ymm7
    sub  rcx, 16
    jl   @tail_setup
@loop16:
    { subtract in SINGLE, widen, then square-accumulate - see VDiffSqSum's
      declaration for why the narrow subtract is the right one }
    vmovups   xmm0, [rax+rdx*4]
    vsubps    xmm0, xmm0, [r10+rdx*4]
    vcvtps2pd ymm0, xmm0
    vfmadd231pd ymm4, ymm0, ymm0
    vmovups   xmm1, [rax+rdx*4+16]
    vsubps    xmm1, xmm1, [r10+rdx*4+16]
    vcvtps2pd ymm1, xmm1
    vfmadd231pd ymm5, ymm1, ymm1
    vmovups   xmm2, [rax+rdx*4+32]
    vsubps    xmm2, xmm2, [r10+rdx*4+32]
    vcvtps2pd ymm2, xmm2
    vfmadd231pd ymm6, ymm2, ymm2
    vmovups   xmm3, [rax+rdx*4+48]
    vsubps    xmm3, xmm3, [r10+rdx*4+48]
    vcvtps2pd ymm3, xmm3
    vfmadd231pd ymm7, ymm3, ymm3
    add  rdx, 16
    cmp  rdx, rcx
    jle  @loop16
@tail_setup:
    add  rcx, 16
    vaddpd ymm4, ymm4, ymm5
    vaddpd ymm6, ymm6, ymm7
    vaddpd ymm4, ymm4, ymm6
    vextractf128 xmm5, ymm4, 1
    vaddpd xmm4, xmm4, xmm5
    vhaddpd xmm4, xmm4, xmm4
@tail:
    cmp  rdx, rcx
    jge  @done
    vmovss xmm0, [rax+rdx*4]
    vsubss xmm0, xmm0, [r10+rdx*4]
    vcvtss2sd xmm0, xmm0, xmm0
    vmulsd xmm0, xmm0, xmm0
    vaddsd xmm4, xmm4, xmm0
    add  rdx, 1
    jmp  @tail
@done:
    vmovsd Acc, xmm4
    vzeroupper
  end ['rax', 'rcx', 'rdx', 'r10'];
  Result := Acc;
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

procedure VScale2(ADstL, ADstR: PSingle; AScaleL, AScaleR: Single; ACount: PtrInt);
begin
  if ACount <= 0 then
    Exit;
{$IFDEF CPUX86_64}
  if VectorPathIsAVX2 then
  begin
    VScale2Avx(ADstL, ADstR, AScaleL, AScaleR, ACount);
    Exit;
  end;
{$ENDIF}
  VScale2Pas(ADstL, ADstR, AScaleL, AScaleR, ACount);
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

procedure VMinMax(ASrc: PSingle; ACount: PtrInt; out AMin, AMax: Single);
begin
  if ACount <= 0 then
  begin
    AMin := 0;
    AMax := 0;
    Exit;
  end;
{$IFDEF CPUX86_64}
  if VectorPathIsAVX2 then
  begin
    VMinMaxAvx(ASrc, ACount, AMin, AMax);
    Exit;
  end;
{$ENDIF}
  VMinMaxPas(ASrc, ACount, AMin, AMax);
end;

function VDotSum(AA, AB: PSingle; ACount: PtrInt): Double;
begin
  if ACount <= 0 then
    Exit(0);
{$IFDEF CPUX86_64}
  if VectorPathIsFMA3 then
    Exit(VDotSumFma(AA, AB, ACount));
{$ENDIF}
  Result := VDotSumPas(AA, AB, ACount);
end;

function VDiffSqSum(AA, AB: PSingle; ACount: PtrInt): Double;
begin
  if ACount <= 0 then
    Exit(0);
{$IFDEF CPUX86_64}
  if VectorPathIsFMA3 then
    Exit(VDiffSqSumFma(AA, AB, ACount));
{$ENDIF}
  Result := VDiffSqSumPas(AA, AB, ACount);
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
  { second destination pair, used only by VScale2 - the one routine here
    that writes two buffers, so one Ref/Tst pair cannot cover it }
  RefBuf2, TstBuf2: array[0..N - 1] of Single;
  S16Src: array[0..N - 1] of SmallInt;
  Seed: LongWord;
  i, PkN: Integer;
  RefMin, RefMax, TstMin, TstMax: Single;

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

  { two different scales on purpose: equal ones would still pass if the R
    broadcast were wrong and picked up L's register }
  Reset;
  Move(SrcB, RefBuf2, SizeOf(SrcB));
  Move(SrcB, TstBuf2, SizeOf(SrcB));
  VScale2Pas(@RefBuf[0], @RefBuf2[0], 0.71, -1.31, N);
  VScale2Avx(@TstBuf[0], @TstBuf2[0], 0.71, -1.31, N);
  if not Same then Exit;
  if not CompareMem(@RefBuf2[0], @TstBuf2[0], SizeOf(RefBuf2)) then Exit;

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

  { MinMax returns scalars rather than filling a buffer, so it compares its
    two results' BYTES instead of a buffer's - which is the point, since
    +0.0 and -0.0 are equal under "=" and only a byte compare distinguishes
    the one this is required to return from the one it must not.

    Src already carries -0.0, a denormal and values outside +/-1. Run it at a
    length that exercises the vector body and the tail, again at an exact
    multiple of 8 so a tail bug cannot hide, and once over a single element
    where the seed IS the answer. }
  for i := 0 to 2 do
  begin
    case i of
      0: PkN := N;
      1: PkN := 32;
    else PkN := 1;
    end;
    VMinMaxPas(@Src[0], PkN, RefMin, RefMax);
    VMinMaxAvx(@Src[0], PkN, TstMin, TstMax);
    if not CompareMem(@RefMin, @TstMin, SizeOf(Single)) then Exit;
    if not CompareMem(@RefMax, @TstMax, SizeOf(Single)) then Exit;
  end;

  Result := True;
end;

{ The analysis tier's self-test. Separate from SelfTestPasses because it
  cannot be CompareMem - the FMA path differs from the oracle by design, so
  byte equality would fail it every time on every machine.

  The tolerance is relative and deliberately tight. Fusing a multiply-add
  moves a term by around 1e-16 relative, and the two paths also sum their
  partials in a different order, which over 61 terms is worth a few times
  that; dropping, double-counting or mis-striding a single element moves the
  answer by order 1e-2 relative. 1e-9 sits six orders clear of the first and
  seven clear of the second, so it admits exactly the rounding it is meant
  to admit and nothing else. The absolute floor keeps a near-zero reference
  from making the test vacuous.

  Both operand buffers are fed the same values the AVX2 test uses, denormal,
  signed zero and out-of-range entries included, and the length is the same
  non-multiple of 16 so the vector body and the scalar remainder are both
  exercised. }
function SelfTestFmaPasses: Boolean;
const
  N = 61; { 3 vector iterations of 16 + a 13-element tail }
var
  A, B: array[0..N - 1] of Single;
  Seed: LongWord;
  i: Integer;

  function Close(ARef, ATst: Double): Boolean;
  begin
    Result := Abs(ATst - ARef) <= 1.0e-9 * Abs(ARef) + 1.0e-12;
  end;

begin
  Result := False;
  Seed := 22050;
  for i := 0 to N - 1 do
  begin
    Seed := Seed * 1103515245 + 12345;
    A[i] := ((Integer(Seed shr 8) / 8388608.0) - 1.0) * 3.0;
    Seed := Seed * 1103515245 + 12345;
    B[i] := (Integer(Seed shr 8) / 8388608.0) - 1.0;
  end;
  A[0] := 0.0;
  A[1] := -0.0;
  A[2] := 1.0e-42;  { denormal - and note FTZ/DAZ may be on, on both paths }
  B[3] := 0.0;
  B[4] := -0.0;
  { one exactly-equal pair, so VDiffSqSum has a term that must come out at
    precisely zero rather than merely small }
  B[5] := A[5];

  if not Close(VDotSumPas(@A[0], @B[0], N), VDotSumFma(@A[0], @B[0], N)) then
    Exit;
  if not Close(VDiffSqSumPas(@A[0], @B[0], N), VDiffSqSumFma(@A[0], @B[0], N)) then
    Exit;

  { and again at a length that is an exact multiple of 16, so a tail bug
    cannot hide behind a tail that always runs }
  if not Close(VDotSumPas(@A[0], @B[0], 32), VDotSumFma(@A[0], @B[0], 32)) then
    Exit;
  if not Close(VDiffSqSumPas(@A[0], @B[0], 32), VDiffSqSumFma(@A[0], @B[0], 32)) then
    Exit;

  { and at a length shorter than one vector iteration, which skips the main
    loop entirely and must still fold four zeroed accumulators correctly }
  if not Close(VDotSumPas(@A[0], @B[0], 5), VDotSumFma(@A[0], @B[0], 5)) then
    Exit;
  if not Close(VDiffSqSumPas(@A[0], @B[0], 5), VDiffSqSumFma(@A[0], @B[0], 5)) then
    Exit;

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
  { FMASupport rides the same _AVXSupport (so the same XGETBV check) and adds
    the FMA3 CPUID bit. AVX2 is required as well because the assembly uses
    ymm integer-domain forms alongside the FMAs; in practice no shipping part
    has one without the other. }
  if AVX2Support and FMASupport then
    VectorPathIsFMA3 := SelfTestFmaPasses;
{$ENDIF}

end.
