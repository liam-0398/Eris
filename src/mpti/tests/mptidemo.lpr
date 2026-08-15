{
  Phase 0 smoke test: proves the build harness works and exercises
  MptiTypes' endian-safe pack/unpack helpers on whatever host this runs
  on. No terminal I/O yet - later phases replace this with the real
  MPTI demo/test entry point.
}
program mptidemo;

{$mode objfpc}{$H+}

uses
  SysUtils, MptiTypes, MptiCell, MptiCaps, MptiInput, MptiDriver, MptiRender,
  MptiHeadless;

var
  Buf: array[0..7] of Byte;
  Failures: Integer;
  I2: Integer;
  CBuf: TCellBuffer;
  Cell: TCell;
  Caps: TMTermCaps;
  Attrs: TMDeviceAttrs;
  PState: TMInputParseState;
  IEvents: TMInputEventArray;
  DState: TMDriverState;
  RState: TMRenderState;
  Out1: TMByteBuf;
  OutStr: string;
  UB: TMByteBuf;
  HD: TMHeadlessState;
  HScreen: TCellBuffer;

function Bytes(const S: string): TMByteArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
    Result[I - 1] := Byte(S[I]);
end;

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

  { MptiInput: plain char }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes('a'), IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Kind = mekKey)
    and (IEvents[0].Key.Code = mkChar) and (IEvents[0].Key.CodePoint = Ord('a'))
    and (IEvents[0].Key.Mods = []), 'plain char a');

  { Ctrl+A }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#1), IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Key.Code = mkChar)
    and (IEvents[0].Key.CodePoint = Ord('a')) and (IEvents[0].Key.Mods = [kmCtrl]),
    'Ctrl+A');

  { Enter, Tab, Backspace }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#13#9#127), IEvents);
  Check((Length(IEvents) = 3) and (IEvents[0].Key.Code = mkEnter)
    and (IEvents[1].Key.Code = mkTab) and (IEvents[2].Key.Code = mkBackspace),
    'Enter/Tab/Backspace');

  { Arrow keys, unmodified CSI }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#27'[A'#27'[B'#27'[C'#27'[D'), IEvents);
  Check((Length(IEvents) = 4) and (IEvents[0].Key.Code = mkUp)
    and (IEvents[1].Key.Code = mkDown) and (IEvents[2].Key.Code = mkRight)
    and (IEvents[3].Key.Code = mkLeft), 'arrow keys');

  { Modified arrow: Ctrl+Right = CSI 1;5C }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#27'[1;5C'), IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Key.Code = mkRight)
    and (IEvents[0].Key.Mods = [kmCtrl]), 'Ctrl+Right modified CSI');

  { F1 via SS3 and via CSI ~ form }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#27'OP'#27'[11~'), IEvents);
  Check((Length(IEvents) = 2) and (IEvents[0].Key.Code = mkF1)
    and (IEvents[1].Key.Code = mkF1), 'F1 via SS3 and CSI ~');

  { Alt+char }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#27'x'), IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Key.Code = mkChar)
    and (IEvents[0].Key.CodePoint = Ord('x')) and (IEvents[0].Key.Mods = [kmAlt]),
    'Alt+x');

  { Lone ESC held pending until timeout flush }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#27), IEvents);
  Check(Length(IEvents) = 0, 'lone ESC produces no event yet');
  Check((Length(PState.Pending) = 1) and (PState.Pending[0] = 27), 'lone ESC held pending');
  MFlushPendingEscape(PState, IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Key.Code = mkEscape), 'flushed ESC -> Escape key');
  Check(Length(PState.Pending) = 0, 'pending cleared after flush');

  { Split escape sequence across two feeds }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#27'['), IEvents);
  Check(Length(IEvents) = 0, 'split CSI: no event from first half');
  MFeedInput(PState, Bytes('A'), IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Key.Code = mkUp), 'split CSI: completed by second half');

  { UTF-8 multibyte char: e-acute U+00E9 = C3 A9 }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#$C3#$A9), IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Key.Code = mkChar)
    and (IEvents[0].Key.CodePoint = $00E9), 'UTF-8 e-acute decode');

  { SGR mouse: left button press at col 5, row 3 (1-based on wire) }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#27'[<0;5;3M'), IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Kind = mekMouse)
    and (IEvents[0].Mouse.Button = mbLeft) and (IEvents[0].Mouse.Action = maPress)
    and (IEvents[0].Mouse.X = 4) and (IEvents[0].Mouse.Y = 2), 'SGR mouse press');

  MFeedInput(PState, Bytes(#27'[<0;5;3m'), IEvents);
  Check((Length(IEvents) = 2) and (IEvents[1].Mouse.Action = maRelease), 'SGR mouse release');

  { Legacy X10 mouse: button+32, x+32, y+32 raw bytes }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#27'[M'#32#37#35), IEvents); { Cb=0(left), Cx=5, Cy=3 }
  Check((Length(IEvents) = 1) and (IEvents[0].Kind = mekMouse)
    and (IEvents[0].Mouse.Button = mbLeft) and (IEvents[0].Mouse.X = 4)
    and (IEvents[0].Mouse.Y = 2), 'legacy X10 mouse press');

  { Bracketed paste }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#27'[200~hello '#27'[A'' world'#27'[201~'), IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Kind = mekPaste)
    and (IEvents[0].PasteText = 'hello '#27'[A'' world'),
    'bracketed paste treats embedded escape as literal text');

  { Focus in/out }
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Bytes(#27'[I'#27'[O'), IEvents);
  Check((Length(IEvents) = 2) and (IEvents[0].Kind = mekFocusIn)
    and (IEvents[1].Kind = mekFocusOut), 'focus in/out');

  { MptiRender: byte buffer growth past its initial capacity }
  MInitByteBuf(UB);
  for I2 := 1 to 1000 do
    MAppendByte(UB, Byte(I2 and $FF));
  Check(UB.Len = 1000, 'byte buf grows past initial capacity');
  Check(UB.Data[0] = 1, 'byte buf preserves early bytes after growth');
  Check(UB.Data[999] = Byte(1000 and $FF), 'byte buf preserves last appended byte');

  { MptiRender: UTF-8 encode roundtrips through MptiInput's decoder }
  MInitByteBuf(UB);
  MEncodeUtf8($00E9, UB); { e-acute, 2 bytes }
  Check(UB.Len = 2, 'UTF-8 encode e-acute is 2 bytes');
  MInitInputParseState(PState);
  SetLength(IEvents, 0);
  MFeedInput(PState, Copy(UB.Data, 0, UB.Len), IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Key.CodePoint = $00E9),
    'UTF-8 encode/decode roundtrip through MptiInput');

  { MptiRender: first frame is a forced full redraw }
  Caps := MCapsFromEnv('xterm-256color', 'truecolor');
  MInitRenderState(RState, Caps, 4, 2);
  Cell := MBlankCell;
  Cell.CodePoint := Ord('A');
  MSetCell(RState.Back, 0, 0, Cell);
  MRenderDiff(RState, Out1);
  OutStr := MByteBufToString(Out1);
  Check(Pos(#27'[1;1H', OutStr) = 1, 'first frame: cursor positioned to origin first');
  Check(Pos('A', OutStr) > 0, 'first frame: changed cell glyph emitted');
  Check(Pos(#27'[2;1H', OutStr) > 0,
    'first frame: second row (all blank) still gets its own CUP (forced full redraw)');

  { MptiRender: identical second frame emits nothing }
  MRenderDiff(RState, Out1);
  Check(Out1.Len = 0, 'unchanged frame emits zero bytes');

  { MptiRender: single-cell change emits exactly one CUP + glyph, no SGR
    (attrs unchanged from the last emitted cell). }
  Cell := MBlankCell;
  Cell.CodePoint := Ord('Z');
  MSetCell(RState.Back, 2, 1, Cell);
  MRenderDiff(RState, Out1);
  OutStr := MByteBufToString(Out1);
  Check(OutStr = #27'[2;3HZ', 'single unchanged-attr cell diff: bare CUP + glyph, no SGR');

  { MptiRender: attribute change forces a fresh SGR sequence }
  Cell := MBlankCell;
  Cell.CodePoint := Ord('Y');
  Cell.Fg := MMakeColor(1, 2, 3);
  MSetCell(RState.Back, 2, 1, Cell);
  MRenderDiff(RState, Out1);
  OutStr := MByteBufToString(Out1);
  Check(Pos(#27'[0;38;2;1;2;3', OutStr) > 0, 'attribute change emits truecolor SGR');
  Check(OutStr[Length(OutStr)] = 'Y', 'attribute-change diff still ends in the glyph');

  { MptiRender: resize forces the next diff back to full redraw }
  MResizeRenderState(RState, 6, 3);
  Check(RState.ForceFullRedraw, 'resize sets ForceFullRedraw');
  MSetCell(RState.Back, 0, 0, MBlankCell);
  MRenderDiff(RState, Out1);
  Check(Out1.Len > 0, 'post-resize diff redraws (all cells considered changed)');

  { MptiRender: color-mode SGR paths }
  Caps := MCapsFromEnv('linux', ''); { mcm16, no SGR1006 }
  MInitRenderState(RState, Caps, 1, 1);
  Cell := MBlankCell;
  Cell.CodePoint := Ord('Q');
  Cell.Fg := MMakeColor(255, 0, 0); { bright red -> ansi16 index 9 -> fg code 91 }
  MSetCell(RState.Back, 0, 0, Cell);
  MRenderDiff(RState, Out1);
  OutStr := MByteBufToString(Out1);
  Check(Pos(';91;', OutStr) > 0, 'mcm16 SGR uses bright fg code for ansi16 index 9');

  Caps.ColorMode := mcm256;
  MInitRenderState(RState, Caps, 1, 1);
  MSetCell(RState.Back, 0, 0, Cell);
  MRenderDiff(RState, Out1);
  OutStr := MByteBufToString(Out1);
  Check(Pos(';38;5;', OutStr) > 0, 'mcm256 SGR uses 256-color indexed fg');

  Caps.ColorMode := mcmMono;
  MInitRenderState(RState, Caps, 1, 1);
  MSetCell(RState.Back, 0, 0, Cell); { bright red -> mono-bright -> csBold }
  MRenderDiff(RState, Out1);
  OutStr := MByteBufToString(Out1);
  Check(Pos(';1', OutStr) > 0, 'mono mode compensates bright color with bold');
  Check(Pos('38', OutStr) = 0, 'mono mode emits no color codes at all');

  { MptiHeadless: scripted input decodes through the exact same parser
    MptiDriver uses on a real fd - split across two feeds like a real
    fd's short reads would. }
  MInitHeadless(HD, MCapsFromEnv('xterm-256color', 'truecolor'), 80, 24);
  SetLength(IEvents, 0);
  MHeadlessFeedInput(HD, Bytes(#27'['), IEvents);
  Check(Length(IEvents) = 0, 'headless: split CSI first half yields no event yet');
  MHeadlessFeedInput(HD, Bytes('A'), IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Key.Code = mkUp),
    'headless: split CSI completed by second feed');

  { MptiHeadless: lone-ESC ambiguity flush, mirroring MptiDriver's timeout }
  SetLength(IEvents, 0);
  MHeadlessFeedInput(HD, Bytes(#27), IEvents);
  Check(Length(IEvents) = 0, 'headless: lone ESC produces no event yet');
  MHeadlessFlushPendingEscape(HD, IEvents);
  Check((Length(IEvents) = 1) and (IEvents[0].Key.Code = mkEscape),
    'headless: flushed lone ESC -> Escape key');

  { MptiHeadless: resize invalidates the virtual screen and forces a full
    redraw, exactly like a real terminal at a new, as-yet-unknown size. }
  MHeadlessRenderFrame(HD, Out1); { consume the forced initial full redraw }
  MHeadlessSetCell(HD, 0, 0, MBlankCell); { still blank: no actual change }
  MHeadlessRenderFrame(HD, Out1);
  Check(Out1.Len = 0, 'headless: unchanged frame after initial redraw emits nothing');
  MHeadlessResize(HD, 40, 10);
  Check((HD.Cols = 40) and (HD.Rows = 10), 'headless: resize updates Cols/Rows');
  Check(HD.Render.ForceFullRedraw, 'headless: resize forces full redraw');

  { MptiHeadless: full input -> draw -> render -> assert round trip with
    no real terminal anywhere in the loop. }
  Cell := MBlankCell;
  Cell.CodePoint := Ord('K');
  MHeadlessSetCell(HD, 2, 1, Cell);
  MHeadlessRenderFrame(HD, Out1);
  HScreen := MHeadlessScreen(HD);
  Check(MCellsEqual(MGetCell(HScreen, 2, 1), Cell), 'headless: drawn cell visible in MHeadlessScreen after render');
  Check(Pos('K', MByteBufToString(Out1)) > 0, 'headless: drawn cell reflected in emitted ANSI');

  { MptiDriver: only ever probes, never mutates terminal state unless a
    real interactive tty is confirmed present - safe to run in CI/headless. }
  MInitDriver(DState);
  WriteLn('driver: stdin is a tty: ', MDriverHasTTY(DState));
  WriteLn('driver: initial size: ', DState.Cols, 'x', DState.Rows);

  if Failures = 0 then
    WriteLn('mptidemo: all checks passed')
  else
  begin
    WriteLn('mptidemo: ', Failures, ' check(s) failed');
    Halt(1);
  end;
end.
