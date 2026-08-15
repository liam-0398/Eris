{
  Core fixed-width types and endian-safe (de)serialization helpers for
  MPTI. No FV, no rtl-console, no unit outside the standard FPC RTL.

  Endianness (hard requirement 2) and the "no raw Move/typecast-based
  (de)serialization" rule (mpti.md #7) are enforced here from the start:
  every multi-byte read/write below is done by explicit shift-and-mask,
  never by Move-ing a record over a byte buffer, so behaviour is identical
  on little- and big-endian hosts (x86_64 vs. powerpc) by construction
  rather than by convention.
}
unit MptiTypes;

{$mode objfpc}{$H+}

interface

type
  TMByte    = Byte;
  TMInt8    = ShortInt;
  TMUInt16  = Word;
  TMInt16   = SmallInt;
  TMUInt32  = LongWord;
  TMInt32   = LongInt;
  TMUInt64  = QWord;
  TMInt64   = Int64;
  TMFloat32 = Single;
  TMFloat64 = Double;

  TMByteArray = array of Byte;

{ True on a little-endian host (x86_64). False on big-endian (powerpc). }
function MHostIsLittleEndian: Boolean; inline;

{ Little-endian buffer reads/writes. Offset is the index of the first byte. }
function MReadUInt16LE(const Buf: array of Byte; Offset: SizeInt): TMUInt16;
function MReadUInt32LE(const Buf: array of Byte; Offset: SizeInt): TMUInt32;
function MReadUInt64LE(const Buf: array of Byte; Offset: SizeInt): TMUInt64;
procedure MWriteUInt16LE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt16);
procedure MWriteUInt32LE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt32);
procedure MWriteUInt64LE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt64);

{ Big-endian buffer reads/writes, same contract. }
function MReadUInt16BE(const Buf: array of Byte; Offset: SizeInt): TMUInt16;
function MReadUInt32BE(const Buf: array of Byte; Offset: SizeInt): TMUInt32;
function MReadUInt64BE(const Buf: array of Byte; Offset: SizeInt): TMUInt64;
procedure MWriteUInt16BE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt16);
procedure MWriteUInt32BE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt32);
procedure MWriteUInt64BE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt64);

implementation

function MHostIsLittleEndian: Boolean; inline;
begin
  {$ifdef ENDIAN_LITTLE}
  Result := True;
  {$else}
  Result := False;
  {$endif}
end;

function MReadUInt16LE(const Buf: array of Byte; Offset: SizeInt): TMUInt16;
begin
  Result := TMUInt16(Buf[Offset]) or (TMUInt16(Buf[Offset + 1]) shl 8);
end;

function MReadUInt32LE(const Buf: array of Byte; Offset: SizeInt): TMUInt32;
begin
  Result := TMUInt32(Buf[Offset])
    or (TMUInt32(Buf[Offset + 1]) shl 8)
    or (TMUInt32(Buf[Offset + 2]) shl 16)
    or (TMUInt32(Buf[Offset + 3]) shl 24);
end;

function MReadUInt64LE(const Buf: array of Byte; Offset: SizeInt): TMUInt64;
var
  Lo, Hi: TMUInt32;
begin
  Lo := MReadUInt32LE(Buf, Offset);
  Hi := MReadUInt32LE(Buf, Offset + 4);
  Result := TMUInt64(Lo) or (TMUInt64(Hi) shl 32);
end;

procedure MWriteUInt16LE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt16);
begin
  Buf[Offset] := Byte(Value and $FF);
  Buf[Offset + 1] := Byte((Value shr 8) and $FF);
end;

procedure MWriteUInt32LE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt32);
begin
  Buf[Offset] := Byte(Value and $FF);
  Buf[Offset + 1] := Byte((Value shr 8) and $FF);
  Buf[Offset + 2] := Byte((Value shr 16) and $FF);
  Buf[Offset + 3] := Byte((Value shr 24) and $FF);
end;

procedure MWriteUInt64LE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt64);
begin
  MWriteUInt32LE(Buf, Offset, TMUInt32(Value and $FFFFFFFF));
  MWriteUInt32LE(Buf, Offset + 4, TMUInt32((Value shr 32) and $FFFFFFFF));
end;

function MReadUInt16BE(const Buf: array of Byte; Offset: SizeInt): TMUInt16;
begin
  Result := (TMUInt16(Buf[Offset]) shl 8) or TMUInt16(Buf[Offset + 1]);
end;

function MReadUInt32BE(const Buf: array of Byte; Offset: SizeInt): TMUInt32;
begin
  Result := (TMUInt32(Buf[Offset]) shl 24)
    or (TMUInt32(Buf[Offset + 1]) shl 16)
    or (TMUInt32(Buf[Offset + 2]) shl 8)
    or TMUInt32(Buf[Offset + 3]);
end;

function MReadUInt64BE(const Buf: array of Byte; Offset: SizeInt): TMUInt64;
var
  Hi, Lo: TMUInt32;
begin
  Hi := MReadUInt32BE(Buf, Offset);
  Lo := MReadUInt32BE(Buf, Offset + 4);
  Result := (TMUInt64(Hi) shl 32) or TMUInt64(Lo);
end;

procedure MWriteUInt16BE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt16);
begin
  Buf[Offset] := Byte((Value shr 8) and $FF);
  Buf[Offset + 1] := Byte(Value and $FF);
end;

procedure MWriteUInt32BE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt32);
begin
  Buf[Offset] := Byte((Value shr 24) and $FF);
  Buf[Offset + 1] := Byte((Value shr 16) and $FF);
  Buf[Offset + 2] := Byte((Value shr 8) and $FF);
  Buf[Offset + 3] := Byte(Value and $FF);
end;

procedure MWriteUInt64BE(var Buf: array of Byte; Offset: SizeInt; Value: TMUInt64);
begin
  MWriteUInt32BE(Buf, Offset, TMUInt32((Value shr 32) and $FFFFFFFF));
  MWriteUInt32BE(Buf, Offset + 4, TMUInt32(Value and $FFFFFFFF));
end;

end.
