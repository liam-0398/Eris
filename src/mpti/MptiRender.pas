{
  Diff/double-buffer renderer (mpti.md Phase 3). The caller draws a full
  frame into State.Back every tick (immediate mode: nothing here assumes
  incremental drawing), and MRenderDiff compares Back against Front - the
  renderer's record of what the terminal actually has on screen right now
  - emitting only the minimal ANSI needed to bring the terminal from Front
  to Back, then makes Front equal to Back for the next frame.

  Two things kept deliberately cheap here because hard requirement 13 says
  performance is paramount:

  - The output buffer is a manually-doubled byte array (TMByteBuf), not
    repeated AnsiString concatenation. Pascal string += reallocates on
    every append with no amortized-growth guarantee; for a
    once-per-frame, potentially-whole-screen write, that matters.
  - Cursor position and SGR state are tracked across the *whole* diff, not
    reset per cell - a changed cell immediately following the previous
    write (same row, adjacent column) costs zero extra bytes for
    repositioning, and unchanged attributes between two changed cells
    cost zero extra bytes for a new SGR sequence. This is the "batched
    into as few writes as possible" requirement from the phase plan.

  Color reduction uses MptiCaps' degradation-ladder quantizers, selected
  once per emitted SGR sequence by State.Caps.ColorMode - never baked into
  TCell itself (MptiCell stores full-fidelity 24-bit color always).
}
unit MptiRender;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, MptiTypes, MptiCell, MptiCaps;

type
  { Manually-doubled byte buffer - see unit doc comment for why this isn't
    just a string. }
  TMByteBuf = record
    Data: TMByteArray;
    Len: Integer;
  end;

  TMRenderState = record
    Caps: TMTermCaps;
    Front, Back: TCellBuffer;
    { -1 means "position unknown, must emit a CUP before the next write"
      (true at startup and forced after every resize). }
    CursorRow, CursorCol: Integer;
    AttrsValid: Boolean; { False forces an SGR sequence before the next write }
    LastFg, LastBg: TMColor;
    LastStyle: TMCellStyle;
    ForceFullRedraw: Boolean;
  end;

procedure MInitByteBuf(var B: TMByteBuf);
procedure MAppendByte(var B: TMByteBuf; V: Byte); inline;
procedure MAppendBytes(var B: TMByteBuf; const Bytes: array of Byte);
procedure MAppendStr(var B: TMByteBuf; const S: string);
function MByteBufToString(const B: TMByteBuf): string;

procedure MInitRenderState(var State: TMRenderState; const Caps: TMTermCaps;
  Width, Height: Integer);
{ Resizes both buffers and forces a full redraw on the next MRenderDiff -
  the terminal's actual on-screen contents at the new size are unknown, so
  Front can't be trusted to reflect them. }
procedure MResizeRenderState(var State: TMRenderState; Width, Height: Integer);

{ Encodes a Unicode scalar value as UTF-8 into B. Used both by the renderer
  (emitting cell glyphs) and available standalone for anything else in
  MPTI that needs it. }
procedure MEncodeUtf8(CP: TMUInt32; var B: TMByteBuf);

{ Diffs State.Back against State.Front, appends the minimal ANSI needed to
  Output (Output is reset to empty first), and makes Front equal to Back.
  Does not write to any fd itself - MptiDriver/the caller does that with
  Output's bytes, keeping this unit terminal-I/O-free and headlessly
  testable per mpti.md #9. }
procedure MRenderDiff(var State: TMRenderState; var Output: TMByteBuf);

implementation

const
  InitialCapacity = 256;

procedure MInitByteBuf(var B: TMByteBuf);
begin
  SetLength(B.Data, InitialCapacity);
  B.Len := 0;
end;

procedure MEnsureCapacity(var B: TMByteBuf; Extra: Integer); inline;
var
  NewCap: Integer;
begin
  if B.Len + Extra <= Length(B.Data) then
    Exit;
  NewCap := Length(B.Data);
  if NewCap = 0 then
    NewCap := InitialCapacity;
  while NewCap < B.Len + Extra do
    NewCap := NewCap * 2;
  SetLength(B.Data, NewCap);
end;

procedure MAppendByte(var B: TMByteBuf; V: Byte); inline;
begin
  MEnsureCapacity(B, 1);
  B.Data[B.Len] := V;
  Inc(B.Len);
end;

procedure MAppendBytes(var B: TMByteBuf; const Bytes: array of Byte);
var
  I: Integer;
begin
  MEnsureCapacity(B, Length(Bytes));
  for I := 0 to High(Bytes) do
  begin
    B.Data[B.Len] := Bytes[I];
    Inc(B.Len);
  end;
end;

procedure MAppendStr(var B: TMByteBuf; const S: string);
var
  I: Integer;
begin
  MEnsureCapacity(B, Length(S));
  for I := 1 to Length(S) do
  begin
    B.Data[B.Len] := Byte(S[I]);
    Inc(B.Len);
  end;
end;

function MByteBufToString(const B: TMByteBuf): string;
var
  I: Integer;
begin
  SetLength(Result, B.Len);
  for I := 0 to B.Len - 1 do
    Result[I + 1] := Char(B.Data[I]);
end;

procedure MEncodeUtf8(CP: TMUInt32; var B: TMByteBuf);
begin
  if CP <= $7F then
    MAppendByte(B, Byte(CP))
  else if CP <= $7FF then
  begin
    MAppendByte(B, Byte($C0 or (CP shr 6)));
    MAppendByte(B, Byte($80 or (CP and $3F)));
  end
  else if CP <= $FFFF then
  begin
    MAppendByte(B, Byte($E0 or (CP shr 12)));
    MAppendByte(B, Byte($80 or ((CP shr 6) and $3F)));
    MAppendByte(B, Byte($80 or (CP and $3F)));
  end
  else
  begin
    MAppendByte(B, Byte($F0 or (CP shr 18)));
    MAppendByte(B, Byte($80 or ((CP shr 12) and $3F)));
    MAppendByte(B, Byte($80 or ((CP shr 6) and $3F)));
    MAppendByte(B, Byte($80 or (CP and $3F)));
  end;
end;

procedure MInitRenderState(var State: TMRenderState; const Caps: TMTermCaps;
  Width, Height: Integer);
begin
  State.Caps := Caps;
  MInitCellBuffer(State.Front, Width, Height);
  MInitCellBuffer(State.Back, Width, Height);
  State.CursorRow := -1;
  State.CursorCol := -1;
  State.AttrsValid := False;
  State.LastStyle := [];
  State.ForceFullRedraw := True;
end;

procedure MResizeRenderState(var State: TMRenderState; Width, Height: Integer);
begin
  MResizeCellBuffer(State.Front, Width, Height);
  MResizeCellBuffer(State.Back, Width, Height);
  State.CursorRow := -1;
  State.CursorCol := -1;
  State.AttrsValid := False;
  State.ForceFullRedraw := True;
end;

procedure EmitSGR(var State: TMRenderState; var Output: TMByteBuf; const C: TCell);
var
  FgIdx, BgIdx: Byte;
  Bright: Boolean;
  Style: TMCellStyle;
begin
  MAppendStr(Output, #27'[0');
  Style := C.Style;

  case State.Caps.ColorMode of
    mcmTrueColor:
      begin
        MAppendStr(Output, ';38;2;' + IntToStr(C.Fg.R) + ';' + IntToStr(C.Fg.G) + ';' + IntToStr(C.Fg.B));
        MAppendStr(Output, ';48;2;' + IntToStr(C.Bg.R) + ';' + IntToStr(C.Bg.G) + ';' + IntToStr(C.Bg.B));
      end;
    mcm256:
      begin
        FgIdx := MQuantizeToXterm256(C.Fg);
        BgIdx := MQuantizeToXterm256(C.Bg);
        MAppendStr(Output, ';38;5;' + IntToStr(FgIdx));
        MAppendStr(Output, ';48;5;' + IntToStr(BgIdx));
      end;
    mcm16:
      begin
        FgIdx := MQuantizeToAnsi16(C.Fg);
        BgIdx := MQuantizeToAnsi16(C.Bg);
        if FgIdx < 8 then
          MAppendStr(Output, ';' + IntToStr(30 + FgIdx))
        else
          MAppendStr(Output, ';' + IntToStr(90 + (FgIdx - 8)));
        if BgIdx < 8 then
          MAppendStr(Output, ';' + IntToStr(40 + BgIdx))
        else
          MAppendStr(Output, ';' + IntToStr(100 + (BgIdx - 8)));
      end;
    mcmMono:
      begin
        Bright := MQuantizeToMonoBright(C.Fg);
        if Bright then
          Include(Style, csBold);
      end;
  end;

  if csBold in Style then MAppendStr(Output, ';1');
  if csUnderline in Style then MAppendStr(Output, ';4');
  if csItalic in Style then MAppendStr(Output, ';3');
  if csReverse in Style then MAppendStr(Output, ';7');
  if csBlink in Style then MAppendStr(Output, ';5');
  if csStrikethrough in Style then MAppendStr(Output, ';9');

  MAppendByte(Output, Byte('m'));

  State.LastFg := C.Fg;
  State.LastBg := C.Bg;
  State.LastStyle := C.Style;
  State.AttrsValid := True;
end;

function AttrsMatch(const State: TMRenderState; const C: TCell): Boolean; inline;
begin
  Result := State.AttrsValid
    and MColorsEqual(State.LastFg, C.Fg)
    and MColorsEqual(State.LastBg, C.Bg)
    and (State.LastStyle = C.Style);
end;

procedure MRenderDiff(var State: TMRenderState; var Output: TMByteBuf);
var
  X, Y: Integer;
  Cur, Prev: TCell;
  Changed: Boolean;
begin
  MInitByteBuf(Output);

  for Y := 0 to State.Back.Height - 1 do
    for X := 0 to State.Back.Width - 1 do
    begin
      Cur := MGetCell(State.Back, X, Y);

      if State.ForceFullRedraw then
        Changed := True
      else
      begin
        Prev := MGetCell(State.Front, X, Y);
        Changed := not MCellsEqual(Prev, Cur);
      end;

      if not Changed then
        Continue;

      if (State.CursorRow <> Y) or (State.CursorCol <> X) then
      begin
        MAppendStr(Output, #27'[' + IntToStr(Y + 1) + ';' + IntToStr(X + 1) + 'H');
        State.CursorRow := Y;
        State.CursorCol := X;
      end;

      if not AttrsMatch(State, Cur) then
        EmitSGR(State, Output, Cur);

      MEncodeUtf8(Cur.CodePoint, Output);

      { A write advances the terminal's own cursor by one column. Track
        that so the next changed cell on the same row, immediately after
        this one, needs no CUP at all. Right-edge auto-wrap is not relied
        on here: if the next write actually needs column 0 of the next
        row, the CursorRow/CursorCol mismatch check above still forces a
        fresh CUP - the only cost of not modeling wrap is one possibly
        redundant (but always correct) CUP at the row boundary. }
      Inc(State.CursorCol);
    end;

  { Front must end up holding an independent copy of Back's cells, not a
    shared reference to the same dynamic array - Back is caller-owned and
    gets overwritten next frame, which would otherwise silently corrupt
    Front's record of what the terminal displays. TCell has no managed
    fields (no strings/dynamic arrays inside it - Style is a plain set),
    so a bulk Move is both correct and the fastest way to do this. }
  State.Front.Width := State.Back.Width;
  State.Front.Height := State.Back.Height;
  if Length(State.Front.Cells) <> Length(State.Back.Cells) then
    SetLength(State.Front.Cells, Length(State.Back.Cells));
  if Length(State.Back.Cells) > 0 then
    Move(State.Back.Cells[0], State.Front.Cells[0],
      Length(State.Back.Cells) * SizeOf(TCell));

  State.ForceFullRedraw := False;
end;

end.
