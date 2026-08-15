{
  Phase 0 smoke test: proves the build harness works and exercises
  MptiTypes' endian-safe pack/unpack helpers on whatever host this runs
  on. No terminal I/O yet - later phases replace this with the real
  MPTI demo/test entry point.
}
program mptidemo;

{$mode objfpc}{$H+}

uses
  MptiTypes;

var
  Buf: array[0..7] of Byte;
  Failures: Integer;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if not Cond then
  begin
    WriteLn('FAIL: ', Msg);
    Inc(Failures);
  end
  else
    WriteLn('ok:   ', Msg);
end;

begin
  Failures := 0;

  if MHostIsLittleEndian then
    WriteLn('host endianness: little')
  else
    WriteLn('host endianness: big');

  MWriteUInt32LE(Buf, 0, $12345678);
  Check(MReadUInt32LE(Buf, 0) = $12345678, 'UInt32 LE roundtrip');
  Check((Buf[0] = $78) and (Buf[3] = $12), 'UInt32 LE byte order');

  MWriteUInt32BE(Buf, 0, $12345678);
  Check(MReadUInt32BE(Buf, 0) = $12345678, 'UInt32 BE roundtrip');
  Check((Buf[0] = $12) and (Buf[3] = $78), 'UInt32 BE byte order');

  MWriteUInt64LE(Buf, 0, $0102030405060708);
  Check(MReadUInt64LE(Buf, 0) = $0102030405060708, 'UInt64 LE roundtrip');

  MWriteUInt64BE(Buf, 0, $0102030405060708);
  Check(MReadUInt64BE(Buf, 0) = $0102030405060708, 'UInt64 BE roundtrip');

  MWriteUInt16LE(Buf, 0, $ABCD);
  Check(MReadUInt16LE(Buf, 0) = $ABCD, 'UInt16 LE roundtrip');

  MWriteUInt16BE(Buf, 0, $ABCD);
  Check(MReadUInt16BE(Buf, 0) = $ABCD, 'UInt16 BE roundtrip');

  if Failures = 0 then
    WriteLn('mptidemo: all checks passed')
  else
  begin
    WriteLn('mptidemo: ', Failures, ' check(s) failed');
    Halt(1);
  end;
end.
