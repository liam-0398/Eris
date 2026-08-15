{
  Phase 0 smoke test: proves the build harness works and exercises
  MptiTypes' endian-safe pack/unpack helpers on whatever host this runs
  on. No terminal I/O yet - later phases replace this with the real
  MPTI demo/test entry point.
}
program mptidemo;

{$mode objfpc}{$H+}

uses
  MptiTypes, MptiCell, MptiCaps;

var
  Buf: array[0..7] of Byte;
  Failures: Integer;
  CBuf: TCellBuffer;
  Cell: TCell;
  Caps: TMTermCaps;
  Attrs: TMDeviceAttrs;

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

  { MptiCell: cell buffer basics }
  MInitCellBuffer(CBuf, 10, 5);
  Check((CBuf.Width = 10) and (CBuf.Height = 5), 'cell buffer init dimensions');
  Check(MCellsEqual(MGetCell(CBuf, 0, 0), MBlankCell), 'cell buffer inits blank');

  Cell := MBlankCell;
  Cell.CodePoint := Ord('X');
  Cell.Fg := MMakeColor(255, 0, 0);
  Cell.Style := [csBold, csUnderline];
  MSetCell(CBuf, 3, 2, Cell);
  Check(MCellsEqual(MGetCell(CBuf, 3, 2), Cell), 'cell buffer set/get roundtrip');
  Check(not MCellsEqual(MGetCell(CBuf, 0, 0), Cell), 'unrelated cell unaffected');

  MResizeCellBuffer(CBuf, 20, 8);
  Check((CBuf.Width = 20) and (CBuf.Height = 8), 'cell buffer resize dimensions');
  Check(MCellsEqual(MGetCell(CBuf, 3, 2), Cell), 'cell buffer resize preserves in-bounds cell');
  Check(MCellsEqual(MGetCell(CBuf, 15, 6), MBlankCell), 'cell buffer resize blanks new area');

  MResizeCellBuffer(CBuf, 5, 3);
  Check((CBuf.Width = 5) and (CBuf.Height = 3), 'cell buffer shrink dimensions');

  { MptiCaps: env heuristics }
  Caps := MCapsFromEnv('xterm-256color', 'truecolor');
  Check(Caps.ColorMode = mcmTrueColor, 'truecolor env -> mcmTrueColor');
  Check(Caps.MouseSGR1006, 'modern 256color term -> SGR1006');
  Check(Caps.MouseMaxCols = -1, 'SGR1006 -> unbounded mouse cols');

  Caps := MCapsFromEnv('xterm', '');
  Check(Caps.ColorMode = mcm16, 'bare xterm -> mcm16');
  Check(not Caps.MouseSGR1006, 'bare xterm (Tiger case) -> no SGR1006');
  Check(Caps.MouseMaxCols = MMouseLegacyMaxCols, 'bare xterm -> 223-col legacy clamp');

  Caps := MCapsFromEnv('linux', '');
  Check(Caps.ColorMode = mcm16, 'linux console -> mcm16');
  Check(Caps.MouseMaxCols = 0, 'linux console -> no mouse');

  Caps := MCapsFromEnv('', '');
  Check(Caps.ColorMode = mcm16, 'empty $TERM -> minimal caps');

  { MptiCaps: DA1 response parsing }
  Attrs := MParseDeviceAttrs1(#27'[?64;1;9c');
  Check(Attrs.Valid, 'DA1 parse valid');
  Check(Attrs.TermType = 64, 'DA1 term type parsed');
  Check(MDeviceAttrsHasFeature(Attrs, 9), 'DA1 feature list contains 9');
  Check(not MDeviceAttrsHasFeature(Attrs, 99), 'DA1 feature list excludes 99');

  Attrs := MParseDeviceAttrs1('not an escape sequence');
  Check(not Attrs.Valid, 'DA1 parse rejects garbage');

  { MptiCaps: color quantization }
  Check(MQuantizeToXterm256(MMakeColor(0, 0, 0)) = 16, 'black quantizes to cube origin (16)');
  Check(MQuantizeToXterm256(MMakeColor(255, 255, 255)) = 231, 'white quantizes to cube corner (231)');
  Check(MQuantizeToAnsi16(MMakeColor(255, 0, 0)) = 9, 'bright red quantizes to ansi16 index 9');
  Check(MQuantizeToMonoBright(MMakeColor(255, 255, 255)), 'white is mono-bright');
  Check(not MQuantizeToMonoBright(MMakeColor(0, 0, 0)), 'black is not mono-bright');

  if Failures = 0 then
    WriteLn('mptidemo: all checks passed')
  else
  begin
    WriteLn('mptidemo: ', Failures, ' check(s) failed');
    Halt(1);
  end;
end.
