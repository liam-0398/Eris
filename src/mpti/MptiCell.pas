{
  Cell/attribute model (mpti.md #2). Color and style are separate fields,
  never packed into shared bits the way FV's Word-per-cell (byte glyph +
  byte attribute, 4-bit fg/3-bit bg + blink) does - that's the blink-bit
  collision trap mpti.md #3/#8 call out.

  Color is always stored full-fidelity 24-bit RGB regardless of what the
  target terminal can actually display; reduction to 256/16/mono happens
  only at output time (MptiCaps' quantization helpers), per the
  degradation-ladder rule in mpti.md #5. That keeps this unit itself
  terminal-capability-agnostic and trivially testable headless.

  TCellBuffer is a flat row-major array + explicit Width/Height rather
  than a class, per hard requirement 5 (functional, minimal OOP): it is
  plain data, operated on by plain procedures taking it as a var
  parameter, not an object with methods.
}
unit MptiCell;

{$mode objfpc}{$H+}

interface

uses
  MptiTypes;

type
  TMColor = record
    R, G, B: Byte;
  end;

  TMCellStyleFlag = (
    csBold,
    csUnderline,
    csItalic,
    csReverse,
    csBlink,
    csStrikethrough
  );
  TMCellStyle = set of TMCellStyleFlag;

  { CodePoint is a Unicode scalar value (UCS-4). Combining marks and
    wide (double-width) glyphs are not handled by this record alone -
    that policy lives in the renderer, which decides whether a wide
    glyph occupies this cell plus a following "continuation" cell. }
  TCell = record
    CodePoint: TMUInt32;
    Fg, Bg: TMColor;
    Style: TMCellStyle;
  end;

  TCellArray = array of TCell;

  TCellBuffer = record
    Width, Height: Integer;
    Cells: TCellArray;
  end;

function MMakeColor(R, G, B: Byte): TMColor; inline;
function MColorsEqual(const A, B: TMColor): Boolean; inline;

function MDefaultFg: TMColor; inline;
function MDefaultBg: TMColor; inline;
function MBlankCell: TCell; inline;
function MCellsEqual(const A, B: TCell): Boolean; inline;

procedure MInitCellBuffer(var Buf: TCellBuffer; AWidth, AHeight: Integer);
{ Resizes in place. Cells outside the old bounds are blank; cells within
  both old and new bounds are preserved. }
procedure MResizeCellBuffer(var Buf: TCellBuffer; AWidth, AHeight: Integer);
procedure MClearCellBuffer(var Buf: TCellBuffer; const Fill: TCell);

{ Unchecked by design (performance is paramount, hard requirement 13) -
  callers are expected to stay within 0 <= X < Width, 0 <= Y < Height.
  Layout/widget code that cannot guarantee that should clip before
  calling, not rely on a bounds check here. }
function MGetCell(const Buf: TCellBuffer; X, Y: Integer): TCell; inline;
procedure MSetCell(var Buf: TCellBuffer; X, Y: Integer; const C: TCell); inline;

implementation

function MMakeColor(R, G, B: Byte): TMColor; inline;
begin
  Result.R := R;
  Result.G := G;
  Result.B := B;
end;

function MColorsEqual(const A, B: TMColor): Boolean; inline;
begin
  Result := (A.R = B.R) and (A.G = B.G) and (A.B = B.B);
end;

function MDefaultFg: TMColor; inline;
begin
  Result := MMakeColor($C0, $C0, $C0);
end;

function MDefaultBg: TMColor; inline;
begin
  Result := MMakeColor(0, 0, 0);
end;

function MBlankCell: TCell; inline;
begin
  Result.CodePoint := 32; { space }
  Result.Fg := MDefaultFg;
  Result.Bg := MDefaultBg;
  Result.Style := [];
end;

function MCellsEqual(const A, B: TCell): Boolean; inline;
begin
  Result := (A.CodePoint = B.CodePoint)
    and MColorsEqual(A.Fg, B.Fg)
    and MColorsEqual(A.Bg, B.Bg)
    and (A.Style = B.Style);
end;

procedure MInitCellBuffer(var Buf: TCellBuffer; AWidth, AHeight: Integer);
var
  I: Integer;
  Blank: TCell;
begin
  Buf.Width := AWidth;
  Buf.Height := AHeight;
  SetLength(Buf.Cells, AWidth * AHeight);
  Blank := MBlankCell;
  for I := 0 to High(Buf.Cells) do
    Buf.Cells[I] := Blank;
end;

procedure MResizeCellBuffer(var Buf: TCellBuffer; AWidth, AHeight: Integer);
var
  NewBuf: TCellBuffer;
  X, Y, CopyW, CopyH: Integer;
begin
  if (AWidth = Buf.Width) and (AHeight = Buf.Height) then
    Exit;

  MInitCellBuffer(NewBuf, AWidth, AHeight);

  if (Buf.Width > 0) and (Buf.Height > 0) then
  begin
    if Buf.Width < AWidth then CopyW := Buf.Width else CopyW := AWidth;
    if Buf.Height < AHeight then CopyH := Buf.Height else CopyH := AHeight;
    for Y := 0 to CopyH - 1 do
      for X := 0 to CopyW - 1 do
        MSetCell(NewBuf, X, Y, MGetCell(Buf, X, Y));
  end;

  Buf := NewBuf;
end;

procedure MClearCellBuffer(var Buf: TCellBuffer; const Fill: TCell);
var
  I: Integer;
begin
  for I := 0 to High(Buf.Cells) do
    Buf.Cells[I] := Fill;
end;

function MGetCell(const Buf: TCellBuffer; X, Y: Integer): TCell; inline;
begin
  Result := Buf.Cells[Y * Buf.Width + X];
end;

procedure MSetCell(var Buf: TCellBuffer; X, Y: Integer; const C: TCell); inline;
begin
  Buf.Cells[Y * Buf.Width + X] := C;
end;

end.
