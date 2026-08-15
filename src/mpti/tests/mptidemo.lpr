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
  MptiHeadless, MptiQueue, MptiCore, MptiLayout, MptiWidgets;

type
  PMDeferredQueue = ^TMDeferredQueue;

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
  EQ: TMEventQueue;
  QMsg: TMQueueMsg;
  Core: TMCoreState;
  WS: PMWidgetState;
  IDa, IDb: TMWidgetID;
  PaneTimeline, PaneTrack: TMWidgetID;
  KT: TMKeymapTable;
  ResolvedAction: TMUInt32;
  Layout: TMLayoutState;
  RectA, RectTaken, RectRemainder: TMRect;
  WideBuf: TCellBuffer;
  GlyphW: Integer;
  HR: TMHitRegistry;
  HitID, HitPane: TMWidgetID;
  MEv: TMMouseEvent;
  Timers: TMTimerSet;
  TH1, TH2: TMTimerHandle;
  Deferred: TMDeferredQueue;
  FakeClockValue: TMInt64;
  PumpCallCount: Integer;
  WBuf: TCellBuffer;
  WCore: TMCoreState;
  WHR: TMHitRegistry;
  WPane: TMWidgetID;
  WBool: Boolean;
  WSel, WScroll, WMenu, WDrop: Integer;
  WText: string;
  WItems: array of string;

function FakeClock: TMInt64;
begin
  Result := FakeClockValue;
end;

procedure FakePump(UserData: Pointer);
begin
  Inc(PInteger(UserData)^);
  Inc(FakeClockValue);
end;

function FakeConditionAt3(UserData: Pointer): Boolean;
begin
  Result := PInteger(UserData)^ >= 3;
end;

function FakeConditionNever(UserData: Pointer): Boolean;
begin
  Result := False;
end;

var
  TimerFireCount: Integer;

procedure TimerCallback(UserData: Pointer);
begin
  Inc(PInteger(UserData)^);
end;

var
  DeferredLog: string;

procedure DeferredCallbackA(UserData: Pointer);
begin
  DeferredLog := DeferredLog + 'A';
end;

procedure DeferredCallbackC(UserData: Pointer);
begin
  DeferredLog := DeferredLog + 'C';
end;

procedure DeferredCallbackB(UserData: Pointer);
begin
  DeferredLog := DeferredLog + 'B';
  MDeferCall(PMDeferredQueue(UserData)^, @DeferredCallbackC, nil);
end;

function Bytes(const S: string): TMByteArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
    Result[I - 1] := Byte(S[I]);
end;

function MakeKeyEv(Code: TMKeyCode; CodePoint: TMUInt32; Mods: TMKeyModSet): TMInputEvent;
begin
  Result.Kind := mekKey;
  Result.Key.Code := Code;
  Result.Key.CodePoint := CodePoint;
  Result.Key.Mods := Mods;
end;

function MakeMouseEv(X, Y: Integer; Button: TMMouseButton; Action: TMMouseAction): TMInputEvent;
begin
  Result.Kind := mekMouse;
  Result.Mouse.X := X;
  Result.Mouse.Y := Y;
  Result.Mouse.Button := Button;
  Result.Mouse.Action := Action;
  Result.Mouse.Mods := [];
end;

function OneEvent(const Ev: TMInputEvent): TMInputEventArray;
begin
  SetLength(Result, 1);
  Result[0] := Ev;
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

  { MptiQueue: SPSC event queue FIFO ordering }
  MInitQueue(EQ);
  QMsg.Kind := 1; QMsg.Param1 := 111; QMsg.Param2 := 0; QMsg.Data := nil;
  Check(MQueuePush(EQ, QMsg), 'queue: push 1 succeeds');
  QMsg.Kind := 2; QMsg.Param1 := 222;
  Check(MQueuePush(EQ, QMsg), 'queue: push 2 succeeds');
  Check(MQueuePop(EQ, QMsg) and (QMsg.Kind = 1) and (QMsg.Param1 = 111), 'queue: pop 1 is FIFO-first');
  Check(MQueuePop(EQ, QMsg) and (QMsg.Kind = 2) and (QMsg.Param1 = 222), 'queue: pop 2 is FIFO-second');
  Check(not MQueuePop(EQ, QMsg), 'queue: pop on empty queue fails');

  { MptiQueue: full queue drops rather than blocks (mirrors PushNoteEvent) }
  MInitQueue(EQ);
  I2 := 0;
  while MQueuePush(EQ, QMsg) do Inc(I2);
  Check(I2 = MQueueCapacity - 1, 'queue: capacity is Capacity-1 usable slots (one-slot-of-margin ring)');
  Check(not MQueuePush(EQ, QMsg), 'queue: push on full queue fails (dropped, not blocked)');

  { MptiQueue: timers - one-shot fires once at its due time, not before }
  MInitTimers(Timers);
  TimerFireCount := 0;
  MScheduleTimer(Timers, 1000, 500, 0, @TimerCallback, @TimerFireCount);
  MPumpTimers(Timers, 1400); { before due }
  Check(TimerFireCount = 0, 'timer: does not fire before its due time');
  MPumpTimers(Timers, 1500); { exactly due }
  Check(TimerFireCount = 1, 'timer: fires once its due time is reached');
  MPumpTimers(Timers, 2000); { one-shot: should not fire again }
  Check(TimerFireCount = 1, 'timer: one-shot does not refire');

  { MptiQueue: repeating timer reschedules itself }
  MInitTimers(Timers);
  TimerFireCount := 0;
  MScheduleTimer(Timers, 0, 100, 100, @TimerCallback, @TimerFireCount);
  MPumpTimers(Timers, 100);
  Check(TimerFireCount = 1, 'repeating timer: first fire at due time');
  MPumpTimers(Timers, 150);
  Check(TimerFireCount = 1, 'repeating timer: does not fire again before next interval');
  MPumpTimers(Timers, 200);
  Check(TimerFireCount = 2, 'repeating timer: fires again once next interval elapses');

  { MptiQueue: cancelled timer never fires }
  MInitTimers(Timers);
  TimerFireCount := 0;
  TH1 := MScheduleTimer(Timers, 0, 50, 0, @TimerCallback, @TimerFireCount);
  TH2 := MScheduleTimer(Timers, 0, 50, 0, @TimerCallback, @TimerFireCount);
  MCancelTimer(Timers, TH1);
  MPumpTimers(Timers, 100);
  Check(TimerFireCount = 1, 'timer: cancelled timer does not fire, uncancelled sibling does');

  { MptiQueue: deferred calls run in FIFO order, not immediately }
  MInitDeferred(Deferred);
  DeferredLog := '';
  Check(MDeferCall(Deferred, @DeferredCallbackA, nil), 'deferred: MDeferCall succeeds');
  Check(DeferredLog = '', 'deferred: call does not run until MRunDeferred');
  MRunDeferred(Deferred);
  Check(DeferredLog = 'A', 'deferred: call runs on MRunDeferred');

  { MptiQueue: a callback that self-defers waits for the *next* MRunDeferred,
    not the batch currently running - proves the queue can't starve the loop }
  DeferredLog := '';
  MDeferCall(Deferred, @DeferredCallbackB, @Deferred);
  MRunDeferred(Deferred);
  Check(DeferredLog = 'B', 'deferred: self-deferring call does not run its follow-up same iteration');
  MRunDeferred(Deferred);
  Check(DeferredLog = 'BC', 'deferred: follow-up runs on the next MRunDeferred');

  { MptiQueue: bounded wait pumps until Condition is true, no real Sleep needed }
  FakeClockValue := 0;
  PumpCallCount := 0;
  Check(MBoundedWait(@FakeConditionAt3, @PumpCallCount, @FakePump, @PumpCallCount,
    @FakeClock, 1000, 0), 'bounded wait: returns True once Condition becomes true');
  Check(PumpCallCount = 3, 'bounded wait: pumps exactly until Condition is satisfied');

  { MptiQueue: bounded wait gives up at the timeout instead of hanging forever }
  FakeClockValue := 0;
  PumpCallCount := 0;
  Check(not MBoundedWait(@FakeConditionNever, nil, @FakePump, @PumpCallCount,
    @FakeClock, 5, 0), 'bounded wait: returns False once the timeout elapses');

  { MptiCore: widget ID hashing is stable and distinguishes distinct names }
  Check(MWidgetID('track_pane/track_3/mute_btn') = MWidgetID('track_pane/track_3/mute_btn'),
    'core: MWidgetID is stable for the same name');
  Check(MWidgetID('track_pane/track_3/mute_btn') <> MWidgetID('track_pane/track_3/solo_btn'),
    'core: MWidgetID distinguishes different names');
  Check(MWidgetID('') <> 0, 'core: MWidgetID never returns the empty-slot sentinel');

  { IDa/IDb from here on are two genuinely distinct widget IDs, reused
    across the rest of the MptiCore checks below. }
  IDa := MWidgetID('widget/a');
  IDb := MWidgetID('widget/b');

  { MptiCore: get-or-create state table, persistence across frames }
  MInitCore(Core, 4); { tiny initial capacity to exercise growth below }
  MBeginCoreFrame(Core);
  WS := MGetWidgetState(Core, IDa);
  WS^.ScrollY := 7;
  WS := MGetWidgetState(Core, IDa);
  Check(WS^.ScrollY = 7, 'core: state persists across MGetWidgetState calls for the same ID');
  Check(WS^.SelectStart = -1, 'core: a freshly-created slot defaults SelectStart to -1 (no selection)');

  { MptiCore: table grows past its initial capacity without losing data }
  for I2 := 0 to 49 do
  begin
    WS := MGetWidgetState(Core, MWidgetID('widget_' + IntToStr(I2)));
    WS^.CursorPos := I2;
  end;
  Check(Core.Capacity > 4, 'core: table grew past its tiny initial capacity');
  WS := MGetWidgetState(Core, IDa);
  Check(WS^.ScrollY = 7, 'core: original entry survives a grow/rehash');
  WS := MGetWidgetState(Core, MWidgetID('widget_37'));
  Check(WS^.CursorPos = 37, 'core: entry added before growth survives with correct data');

  { MptiCore: sweep reaps only what has not been touched recently }
  MInitCore(Core);
  MBeginCoreFrame(Core); { frame 1 }
  MGetWidgetState(Core, IDa)^.ScrollY := 1;
  MBeginCoreFrame(Core); { frame 2 }
  MGetWidgetState(Core, IDb)^.ScrollY := 2; { IDb touched again, IDa not }
  MSweepStaleWidgets(Core, 0); { reap anything not touched THIS frame }
  Check(Core.UsedCount = 1, 'core: sweep reaps the untouched entry, keeps the touched one');

  { MptiCore: explicit forget removes exactly the named entry }
  MInitCore(Core);
  MBeginCoreFrame(Core);
  MGetWidgetState(Core, IDa)^.ScrollY := 1;
  MGetWidgetState(Core, IDb)^.ScrollY := 2;
  MForgetWidget(Core, IDa);
  Check(Core.UsedCount = 1, 'core: MForgetWidget removes exactly one entry');
  WS := MGetWidgetState(Core, IDb);
  Check(WS^.ScrollY = 2, 'core: MForgetWidget leaves unrelated entries intact');

  { MptiCore: focus }
  PaneTimeline := MWidgetID('pane/timeline');
  PaneTrack := MWidgetID('pane/track');
  MInitCore(Core);
  Check(not MIsFocused(Core, IDa), 'core: nothing focused initially');
  MSetFocus(Core, IDa, PaneTimeline);
  Check(MIsFocused(Core, IDa), 'core: MSetFocus makes MIsFocused true for that ID');
  Check(not MIsFocused(Core, IDb), 'core: MIsFocused false for an unrelated ID');
  MClearFocus(Core);
  Check(not MIsFocused(Core, IDa), 'core: MClearFocus clears focus');

  { MptiCore: per-pane keymap - hard requirement 12, the same chord means
    something different (or nothing) depending which pane owns focus }
  PaneTimeline := MWidgetID('pane/timeline');
  PaneTrack := MWidgetID('pane/track');
  MInitKeymapTable(KT);
  MBindKey(KT, PaneTimeline, mkChar, [kmCtrl], 1001); { duplicate clip }
  MBindKey(KT, PaneTrack, mkChar, [kmCtrl], 2001);     { duplicate track }
  Check(MResolveKey(KT, PaneTimeline, mkChar, [kmCtrl], ResolvedAction)
    and (ResolvedAction = 1001), 'core: Ctrl+D in timeline pane resolves to its own action');
  Check(MResolveKey(KT, PaneTrack, mkChar, [kmCtrl], ResolvedAction)
    and (ResolvedAction = 2001), 'core: Ctrl+D in track pane resolves to a different action');
  Check(not MResolveKey(KT, MWidgetID('pane/unbound'), mkChar, [kmCtrl], ResolvedAction),
    'core: unbound pane resolves nothing');
  Check(not MResolveKey(KT, PaneTimeline, mkChar, [kmAlt], ResolvedAction),
    'core: same key, different mods, resolves nothing if unbound');

  { MptiCore: rebinding the same chord in the same pane overwrites, not duplicates }
  MBindKey(KT, PaneTimeline, mkChar, [kmCtrl], 9999);
  Check(MResolveKey(KT, PaneTimeline, mkChar, [kmCtrl], ResolvedAction)
    and (ResolvedAction = 9999), 'core: rebinding the same chord overwrites the previous action');
  Check(Length(KT.Panes[0].Bindings) = 1, 'core: rebinding does not create a duplicate binding entry');

  { MptiLayout: rect helpers }
  RectA := MMakeRect(0, 0, 100, 40);
  Check(not MRectEmpty(RectA), 'layout: a normal rect is not empty');
  Check(MRectEmpty(MMakeRect(0, 0, 0, 5)), 'layout: zero width is empty');
  Check(MRectFits(RectA, 100, 40), 'layout: rect fits its own exact size');
  Check(not MRectFits(RectA, 101, 40), 'layout: rect does not fit something 1 wider than itself');
  Check(MRectContains(RectA, 0, 0), 'layout: contains its own origin');
  Check(MRectContains(RectA, 99, 39), 'layout: contains its bottom-right-most cell');
  Check(not MRectContains(RectA, 100, 39), 'layout: does not contain one past its right edge');

  { MptiLayout: split primitives - generalizes DysGeometry's inline carving }
  MSplitTop(RectA, 3, RectTaken, RectRemainder);
  Check((RectTaken.X = 0) and (RectTaken.Y = 0) and (RectTaken.W = 100) and (RectTaken.H = 3),
    'layout: MSplitTop takes a 3-row strip off the top');
  Check((RectRemainder.X = 0) and (RectRemainder.Y = 3) and (RectRemainder.W = 100) and (RectRemainder.H = 37),
    'layout: MSplitTop remainder starts below the taken strip');

  MSplitLeft(RectRemainder, 24, RectTaken, RectRemainder);
  Check((RectTaken.W = 24) and (RectTaken.H = 37), 'layout: MSplitLeft takes a 24-col strip');
  Check(RectRemainder.X = 24, 'layout: MSplitLeft remainder starts after the taken strip');

  { MptiLayout: split amount is clamped, never yields a negative-size remainder }
  MSplitLeft(MMakeRect(0, 0, 10, 5), 999, RectTaken, RectRemainder);
  Check((RectTaken.W = 10) and (RectRemainder.W = 0), 'layout: oversized split clamps to the rect''s own extent');

  { MptiLayout: resize updates the tracked extent, sets Dirty, and posts
    through the Phase 5 event queue rather than a resize-only side channel }
  MInitLayout(Layout, 80, 24);
  Check(Layout.Dirty, 'layout: freshly initialized layout starts Dirty (first frame needs a pass)');
  MLayoutClearDirty(Layout);
  Check(not Layout.Dirty, 'layout: MLayoutClearDirty clears it');
  MInitQueue(EQ);
  MLayoutOnResize(Layout, EQ, 120, 40);
  Check((Layout.Extent.W = 120) and (Layout.Extent.H = 40), 'layout: MLayoutOnResize updates the extent');
  Check(Layout.Dirty, 'layout: MLayoutOnResize sets Dirty');
  Check(MQueuePop(EQ, QMsg) and (QMsg.Kind = MQueueKindResize)
    and (QMsg.Param1 = 120) and (QMsg.Param2 = 40),
    'layout: MLayoutOnResize posts a resize message through the event queue');

  { MptiCell: Unicode column width - best-effort common-case coverage }
  Check(MCodepointWidth(Ord('A')) = 1, 'width: plain ASCII is 1 column');
  Check(MCodepointWidth($0301) = 0, 'width: a combining acute accent is 0 columns');
  Check(MCodepointWidth($4E2D) = 2, 'width: a CJK ideograph (U+4E2D) is 2 columns');
  Check(MCodepointWidth($AC00) = 2, 'width: a Hangul syllable is 2 columns');

  { MptiCell: MPutCodepoint writes a wide glyph plus its continuation cell }
  MInitCellBuffer(WideBuf, 4, 1);
  MClearCellBuffer(WideBuf, MBlankCell);
  GlyphW := MPutCodepoint(WideBuf, 0, 0, $4E2D, MDefaultFg, MDefaultBg, []);
  Check(GlyphW = 2, 'wide glyph: MPutCodepoint reports width 2 for a CJK ideograph');
  Check(MGetCell(WideBuf, 0, 0).CodePoint = $4E2D, 'wide glyph: left half holds the actual codepoint');
  Check(MIsWideContinuation(MGetCell(WideBuf, 1, 0)), 'wide glyph: right half is the continuation sentinel');
  GlyphW := MPutCodepoint(WideBuf, 2, 0, Ord('X'), MDefaultFg, MDefaultBg, []);
  Check(GlyphW = 1, 'wide glyph: a normal ASCII char still reports width 1');

  { MptiCell: MPutCodepoint at the buffer's last column doesn't overrun }
  MInitCellBuffer(WideBuf, 3, 1);
  GlyphW := MPutCodepoint(WideBuf, 2, 0, $4E2D, MDefaultFg, MDefaultBg, []);
  Check(GlyphW = 2, 'wide glyph at edge: still reports full width');
  Check(MGetCell(WideBuf, 2, 0).CodePoint = $4E2D, 'wide glyph at edge: left half written safely with no continuation cell to write');

  { MptiCell: clipped writes respect the caller's rect, not just buffer bounds }
  MInitCellBuffer(WideBuf, 10, 5);
  MClearCellBuffer(WideBuf, MBlankCell);
  Cell := MBlankCell;
  Cell.CodePoint := Ord('Z');
  Check(MSetCellClipped(WideBuf, 2, 2, 3, 3, 2, 2, Cell), 'clip: cell inside the clip rect is written');
  Check(MGetCell(WideBuf, 2, 2).CodePoint = Ord('Z'), 'clip: written content is actually there');
  Check(not MSetCellClipped(WideBuf, 2, 2, 3, 3, 6, 2, Cell),
    'clip: cell within buffer bounds but outside the clip rect is rejected');
  Check(MGetCell(WideBuf, 6, 2).CodePoint = MBlankCell.CodePoint, 'clip: a rejected write leaves the cell unchanged');

  { MptiCell: MPutCodepointClipped reports full glyph width even when its
    continuation cell falls outside the clip rect }
  GlyphW := MPutCodepointClipped(WideBuf, 2, 2, 3, 3, 4, 2, $4E2D, MDefaultFg, MDefaultBg, []);
  Check(GlyphW = 2, 'clip: MPutCodepointClipped still reports width 2 when partially clipped');
  Check(MGetCell(WideBuf, 4, 2).CodePoint = $4E2D, 'clip: left half written since it is inside the clip rect');
  Check(not MIsWideContinuation(MGetCell(WideBuf, 5, 2)),
    'clip: continuation cell not written since it falls outside the clip rect');

  { MptiRender: a wide glyph advances the diff's tracked cursor by 2, so
    an immediately-following changed cell needs no extra CUP }
  Caps := MCapsFromEnv('xterm-256color', 'truecolor');
  MInitRenderState(RState, Caps, 3, 1); { exactly wide-glyph + adjacent char, no trailing cell }
  MPutCodepoint(RState.Back, 0, 0, $4E2D, MDefaultFg, MDefaultBg, []);
  MPutCodepoint(RState.Back, 2, 0, Ord('X'), MDefaultFg, MDefaultBg, []);
  MRenderDiff(RState, Out1);
  OutStr := MByteBufToString(Out1);
  Check(Pos(#27'[1;1H', OutStr) = 1, 'wide glyph render: frame starts with CUP at the origin');
  Check(Pos(#27'[1;3H', OutStr) = 0,
    'wide glyph render: no CUP needed before the adjacent char (cursor already advanced 2 cols)');
  Check(OutStr[Length(OutStr)] = 'X', 'wide glyph render: the adjacent normal char is still emitted correctly');
  Check(MGetCell(RState.Front, 0, 0).CodePoint = $4E2D, 'wide glyph render: front buffer records the glyph');
  Check(MIsWideContinuation(MGetCell(RState.Front, 1, 0)),
    'wide glyph render: front buffer records the continuation cell');

  { MptiCore: hit-test registry resolves overlapping widgets topmost-first }
  MBeginHitRegistry(HR);
  Check(HR.Count = 0, 'hit: registry starts empty after MBeginHitRegistry');
  MRegisterHitRect(HR, MWidgetID('base/pane'), MWidgetID('pane/base'), MMakeRect(0, 0, 50, 20));
  MRegisterHitRect(HR, MWidgetID('popup/menu'), MWidgetID('pane/popup'), MMakeRect(10, 5, 10, 5));
  Check(MHitTest(HR, 5, 5, HitID, HitPane) and (HitID = MWidgetID('base/pane')),
    'hit: point outside the popup resolves to the base pane');
  Check(MHitTest(HR, 12, 6, HitID, HitPane) and (HitID = MWidgetID('popup/menu')),
    'hit: overlapping point resolves to the topmost (last-registered) widget');
  Check(not MHitTest(HR, 100, 100, HitID, HitPane), 'hit: point outside everything resolves to nothing');

  { MptiCore: MDispatchMouse resolves the hit and applies click-to-focus
    only on a press, never on hover/move (FV gap #7's default) }
  MInitCore(Core);
  MEv.X := 12; MEv.Y := 6; MEv.Button := mbLeft; MEv.Action := maPress; MEv.Mods := [];
  Check(MDispatchMouse(Core, HR, MEv, HitID, HitPane) and (HitID = MWidgetID('popup/menu')),
    'dispatch: press on the popup resolves the hit widget');
  Check(MIsFocused(Core, MWidgetID('popup/menu')), 'dispatch: a press also sets focus');

  MClearFocus(Core);
  MEv.Action := maMove;
  Check(MDispatchMouse(Core, HR, MEv, HitID, HitPane), 'dispatch: hover/move still resolves the hit widget');
  Check(not MIsFocused(Core, HitID), 'dispatch: hover/move does not change focus');

  { MptiCore: MBeginFrame is the canonical per-iteration ordering of the
    Phase 5 primitives }
  MInitCore(Core);
  MInitTimers(Timers);
  MInitDeferred(Deferred);
  TimerFireCount := 0;
  MScheduleTimer(Timers, 0, 100, 0, @TimerCallback, @TimerFireCount);
  DeferredLog := '';
  MDeferCall(Deferred, @DeferredCallbackA, nil);
  Check(Core.FrameCounter = 0, 'glue: frame counter starts at 0');
  MBeginFrame(Core, Timers, Deferred, 100);
  Check(Core.FrameCounter = 1, 'glue: MBeginFrame advances the core frame counter');
  Check(TimerFireCount = 1, 'glue: MBeginFrame pumps due timers');
  Check(DeferredLog = 'A', 'glue: MBeginFrame runs deferred calls queued before this iteration');

  { MptiWidgets (Phase 7): generic widget library, exercised headlessly by
    constructing TMInputEventArrays directly (same technique as MEv above
    for MDispatchMouse) rather than routing through a real/headless driver
    - the widgets only ever consume already-decoded TMInputEventArray, so
    that's a faithful, and much simpler, test surface. }
  MInitCellBuffer(WBuf, 40, 20);
  MInitCore(WCore);
  WPane := MWidgetID('test/pane');

  { MButton: click-to-focus-also-acts, then Enter while focused activates again }
  MBeginHitRegistry(WHR);
  WBool := MButton(WCore, WHR, WBuf, 'w/button', WPane, 2, 2, 'OK',
    OneEvent(MakeMouseEv(3, 2, mbLeft, maPress)));
  Check(WBool, 'MButton: click inside its rect activates on the same frame');
  Check(MIsFocused(WCore, MWidgetID('w/button')), 'MButton: click also focuses (FV gap #7 default)');
  MBeginHitRegistry(WHR);
  WBool := MButton(WCore, WHR, WBuf, 'w/button', WPane, 2, 2, 'OK',
    OneEvent(MakeKeyEv(mkEnter, 0, [])));
  Check(WBool, 'MButton: Enter while focused activates without a click');

  { MCheckBox: click toggles, state persists across frames }
  MBeginHitRegistry(WHR);
  WBool := MCheckBox(WCore, WHR, WBuf, 'w/check', WPane, 2, 3, 'Loop',
    OneEvent(MakeMouseEv(3, 3, mbLeft, maPress)));
  Check(WBool, 'MCheckBox: click turns it on');
  MBeginHitRegistry(WHR);
  WBool := MCheckBox(WCore, WHR, WBuf, 'w/check', WPane, 2, 3, 'Loop', nil);
  Check(WBool, 'MCheckBox: stays on across a frame with no events (retained state)');

  { MTextInput: typing inserts at the caret, Backspace deletes before it }
  WText := '';
  MBeginHitRegistry(WHR);
  MTextInput(WCore, WHR, WBuf, 'w/text', WPane, 2, 4, 10, WText,
    OneEvent(MakeMouseEv(2, 4, mbLeft, maPress))); { focus it }
  Check(MIsFocused(WCore, MWidgetID('w/text')), 'MTextInput: click focuses');
  MBeginHitRegistry(WHR);
  MTextInput(WCore, WHR, WBuf, 'w/text', WPane, 2, 4, 10, WText, OneEvent(MakeKeyEv(mkChar, Ord('h'), [])));
  MBeginHitRegistry(WHR);
  MTextInput(WCore, WHR, WBuf, 'w/text', WPane, 2, 4, 10, WText, OneEvent(MakeKeyEv(mkChar, Ord('i'), [])));
  Check(WText = 'hi', 'MTextInput: two char events append in order');
  MBeginHitRegistry(WHR);
  MTextInput(WCore, WHR, WBuf, 'w/text', WPane, 2, 4, 10, WText, OneEvent(MakeKeyEv(mkBackspace, 0, [])));
  Check(WText = 'h', 'MTextInput: Backspace deletes the char before the caret');
  MBeginHitRegistry(WHR);
  MTextInput(WCore, WHR, WBuf, 'w/text', WPane, 2, 4, 10, WText, OneEvent(MakeKeyEv(mkHome, 0, [])));
  MBeginHitRegistry(WHR);
  MTextInput(WCore, WHR, WBuf, 'w/text', WPane, 2, 4, 10, WText, OneEvent(MakeKeyEv(mkChar, Ord('X'), [])));
  Check(WText = 'Xh', 'MTextInput: Home moves the caret to 0, insert happens there');

  { MListView: Down moves selection, mouse click selects a row directly }
  SetLength(WItems, 3);
  WItems[0] := 'alpha';
  WItems[1] := 'beta';
  WItems[2] := 'gamma';
  WSel := 0;
  WScroll := 0;
  MBeginHitRegistry(WHR);
  MListView(WCore, WHR, WBuf, 'w/list', WPane, 2, 6, 10, 3, WItems, WSel, WScroll,
    OneEvent(MakeMouseEv(2, 6, mbLeft, maPress))); { focus it via row 0 click }
  MBeginHitRegistry(WHR);
  WBool := MListView(WCore, WHR, WBuf, 'w/list', WPane, 2, 6, 10, 3, WItems, WSel, WScroll,
    OneEvent(MakeKeyEv(mkDown, 0, [])));
  Check(WBool and (WSel = 1), 'MListView: Down while focused moves Selected to the next row');
  MBeginHitRegistry(WHR);
  WBool := MListView(WCore, WHR, WBuf, 'w/list', WPane, 2, 6, 10, 3, WItems, WSel, WScroll,
    OneEvent(MakeMouseEv(2, 8, mbLeft, maPress))); { row 2 (y=8) of a list starting at y=6 }
  Check(WBool and (WSel = 2), 'MListView: clicking a row selects it directly');

  { MMenuBar: click opens (highlighted index returned every frame), same
    click again closes; Escape also closes }
  MBeginHitRegistry(WHR);
  WMenu := MMenuBar(WCore, WHR, WBuf, 'w/menubar', WPane, 0, 0, ['File', 'Edit'],
    OneEvent(MakeMouseEv(2, 0, mbLeft, maPress))); { inside "File"'s padded rect }
  Check(WMenu = 0, 'MMenuBar: clicking a label opens it (returns its index)');
  MBeginHitRegistry(WHR);
  WMenu := MMenuBar(WCore, WHR, WBuf, 'w/menubar', WPane, 0, 0, ['File', 'Edit'], nil);
  Check(WMenu = 0, 'MMenuBar: stays open across a frame with no events');
  MBeginHitRegistry(WHR);
  WMenu := MMenuBar(WCore, WHR, WBuf, 'w/menubar', WPane, 0, 0, ['File', 'Edit'],
    OneEvent(MakeMouseEv(2, 0, mbLeft, maPress))); { same label again }
  Check(WMenu = -1, 'MMenuBar: clicking the open label again closes it');

  { MDropdownList: Down highlights, Enter selects; a click outside cancels }
  MBeginHitRegistry(WHR);
  WDrop := MDropdownList(WCore, WHR, WBuf, 'w/dropdown', WPane, 5, 5, ['One', 'Two', 'Three'],
    OneEvent(MakeKeyEv(mkDown, 0, [])));
  Check(WDrop = -1, 'MDropdownList: still open (no selection yet) after just moving the highlight');
  MBeginHitRegistry(WHR);
  WDrop := MDropdownList(WCore, WHR, WBuf, 'w/dropdown', WPane, 5, 5, ['One', 'Two', 'Three'],
    OneEvent(MakeKeyEv(mkEnter, 0, [])));
  Check(WDrop = 1, 'MDropdownList: Enter selects the highlighted row (index 1, after one Down)');
  MBeginHitRegistry(WHR);
  WDrop := MDropdownList(WCore, WHR, WBuf, 'w/dropdown', WPane, 5, 5, ['One', 'Two', 'Three'],
    OneEvent(MakeMouseEv(0, 0, mbLeft, maPress))); { far outside the popup's rect }
  Check(WDrop = -2, 'MDropdownList: a press outside the popup cancels');

  { Draw-only widgets: no interaction, just verify they write the cells
    they claim to (using MGetCell against WBuf, per MptiCell's contract). }
  MDrawPane(WBuf, 0, 10, 6, 3, 'Hi');
  Check(MGetCell(WBuf, 0, 10).CodePoint = Ord('+'), 'MDrawPane: top-left corner is a + glyph');
  Check(MGetCell(WBuf, 4, 10).CodePoint = Ord('-'), 'MDrawPane: top edge is a - glyph away from the title');
  Check(MGetCell(WBuf, 2, 10).CodePoint = Ord('H'), 'MDrawPane: title text is drawn into the top border');
  Check(MGetCell(WBuf, 2, 11).CodePoint = 32, 'MDrawPane: interior is cleared to blank');

  MIndicatorLight(WBuf, 0, 13, True);
  Check(MGetCell(WBuf, 0, 13).CodePoint = Ord('@'), 'MIndicatorLight: on-state draws the filled glyph');
  MIndicatorLight(WBuf, 0, 13, False);
  Check(MGetCell(WBuf, 0, 13).CodePoint = Ord('.'), 'MIndicatorLight: off-state draws the dim glyph');

  MMeterH(WBuf, 0, 14, 10, 5, 10);
  Check(MGetCell(WBuf, 0, 14).CodePoint = Ord('#'), 'MMeterH: half-full meter lights the first half');
  Check(MGetCell(WBuf, 9, 14).CodePoint = Ord('.'), 'MMeterH: half-full meter leaves the second half unlit');

  MMeterV(WBuf, 0, 15, 4, 2, 4);
  Check(MGetCell(WBuf, 0, 15).CodePoint = Ord('.'), 'MMeterV: half-full meter leaves the top unlit');
  Check(MGetCell(WBuf, 0, 15 + 3).CodePoint = Ord('#'), 'MMeterV: half-full meter fills from the bottom');

  MProgressBar(WBuf, 0, 16, 10, 5, 10);
  Check(MGetCell(WBuf, 0, 16).CodePoint = Ord('['), 'MProgressBar: opens with a [ bracket');
  Check(MGetCell(WBuf, 0, 16).CodePoint <> 0, 'MProgressBar: drew into the buffer at all');

  WCore.FrameCounter := 5;
  MBusyIndicator(WCore, WBuf, 0, 17);
  Check(MGetCell(WBuf, 0, 17).CodePoint = Ord('/'), 'MBusyIndicator: frame 5 mod 4 = 1 -> the second glyph (''/'')');

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
