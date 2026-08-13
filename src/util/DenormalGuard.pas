unit DenormalGuard;

{$mode objfpc}{$H+}

interface

uses
  Math;

{ Puts the CALLING thread's SSE unit into flush-to-zero / denormals-are-zero
  mode, and leaves it there for the life of that thread.

  Why this exists. A reverb or delay tail decaying towards silence does not
  reach zero - it passes through the denormal range (roughly 1e-38 and below)
  and can sit there for a very long time, because the feedback path keeps
  multiplying an already tiny number by something just under 1. Denormal
  operands are handled by microcode rather than the normal SSE pipeline, so
  every such multiply-add costs tens to hundreds of cycles instead of one.
  The result is the classic DAW failure mode: a project that runs at 15% CPU
  while it is playing spikes into dropouts a few seconds AFTER the last note,
  when nothing audible is happening at all. Downtuned material into a long
  send reverb - which is exactly this project's use case - is the worst case,
  since the low end keeps the tail alive longest.

  FTZ (bit 15) makes a denormal RESULT flush to zero; DAZ (bit 6) makes a
  denormal INPUT read as zero. Both are needed: FTZ alone still pays the
  microcode cost on operands that were already denormal when they entered the
  feedback buffer.

  This does technically change the output, in that a value below ~1e-38
  becomes exactly 0. That is around -760 dBFS - some 640 dB below the 24-bit
  noise floor, and further below the quietest sample a Single can carry at
  full scale than the entire dynamic range of human hearing. It is universal
  practice in every DAW and plugin format for this reason.

  MXCSR is per-thread state (it lives in the thread context the kernel saves
  and restores), so this must be called ON each thread that does DSP, not
  once at startup. In this project that means the playback thread, the
  capture thread, and the offline render thread.

  No-op on non-x86 targets, which have their own (usually always-on)
  denormal behavior and no MXCSR to set.

  This also masks the Invalid/ZeroDivide/Overflow FPU exceptions on the
  calling thread. FPC/Delphi's default FPU control word - unlike C's -
  leaves those UNMASKED (a Borland-heritage default), so a transient 0/0 or
  Sqrt() of a negative number deep in some effect's DSP math (decaying
  feedback paths cross zero and hit exact edge cases sometimes) raises a
  hard EInvalidOp exception instead of just producing a NaN. GTK - which
  Eris's LCL frontend links in - happens to reset the FPU control word as a
  side effect of its own startup, which masks these traps as a side effect;
  a bare console app like Dysnomia never touches it, so the identical DSP
  edge case that quietly outputs NaN under Eris raises a real exception
  under Dysnomia instead (caught by TPlaybackThread.Execute's except block,
  but still audible as playback stopping dead). Audio DSP should never
  trap on this regardless of what some other library's init code happens
  to do - a stray NaN should degrade to silence, not kill the thread - so
  this masks it explicitly rather than relying on an accident of whichever
  toolkit happens to be linked in. }
procedure EnableFlushDenormals;

implementation

{$IF DEFINED(CPUX86_64) OR DEFINED(CPUI386)}
const
  MXCSR_FTZ = $8000; { flush denormal results to zero }
  MXCSR_DAZ = $0040; { treat denormal operands as zero }
{$ENDIF}

procedure EnableFlushDenormals;
begin
  {$IF DEFINED(CPUX86_64)}
  { x86-64 mandates SSE2, and every x86-64 part supports DAZ, so both bits
    are safe to write unconditionally here. On i386 below, DAZ is NOT
    guaranteed (some early SSE2 steppings left bit 6 reserved, and writing a
    reserved MXCSR bit raises #GP), so that path sets FTZ only rather than
    carrying an FXSAVE/MXCSR_MASK probe for CPUs this project does not
    target. }
  SetMXCSR(GetMXCSR or MXCSR_FTZ or MXCSR_DAZ);
  {$ELSEIF DEFINED(CPUI386)}
  SetMXCSR(GetMXCSR or MXCSR_FTZ);
  {$ENDIF}
  SetExceptionMask(GetExceptionMask + [exInvalidOp, exZeroDivide, exOverflow,
    exUnderflow, exDenormalized, exPrecision]);
end;

end.
