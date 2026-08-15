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

const
  { Sentinel CodePoint marking "this cell is the right half of a wide
    (double-width) glyph to its left - do not draw anything here." Safe
    as a sentinel because it exceeds Unicode's actual maximum scalar
    value (U+10FFFF), so no real codepoint can ever collide with it. }
  MWideContinuation = TMUInt32($FFFFFFFF);

function MIsWideContinuation(const C: TCell): Boolean; inline;

{ Best-effort terminal column width of a Unicode scalar value: 0
  (combining mark/zero-width joiner - approximated by a practical subset
  of ranges, not the full Unicode database), 1 (normal), or 2 (East
  Asian Wide/Fullwidth - CJK ideographs, Hangul syllables, etc, again a
  practical common-case range table rather than an exhaustive one).
  Callers needing exact East Asian Width conformance should not rely on
  this; it covers what a DAW's track names/labels/UI text realistically
  contain. }
function MCodepointWidth(CP: TMUInt32): Integer;

{ Writes CP at (X, Y), and - if it is a wide glyph - also writes a
  MWideContinuation cell at (X+1, Y) so the renderer knows not to draw
  anything independently there (see MptiRender's diff loop). Unchecked
  by design, same contract as MSetCell/MGetCell: callers must ensure
  both cells are in-bounds. Prefer this over raw MSetCell whenever the
  content being drawn might include wide glyphs - MSetCell alone has no
  way to reserve the continuation cell a wide glyph needs. Returns the
  column width actually written (1 or 2; never 0 - a zero-width
  codepoint written standalone via this function still occupies exactly
  one cell as itself, since composing it onto a preceding cell would
  need grapheme-cluster tracking this unit does not implement). }
function MPutCodepoint(var Buf: TCellBuffer; X, Y: Integer; CP: TMUInt32;
  const Fg, Bg: TMColor; Style: TMCellStyle): Integer;

{ Bounds-checked variants of MSetCell/MPutCodepoint for widgets drawing
  inside a caller-given rect (ClipX, ClipY, ClipW, ClipH - plain
  integers rather than MptiLayout's TMRect, so this unit keeps its
  zero-dependency-beyond-MptiTypes status; callers with a TMRect just
  pass R.X, R.Y, R.W, R.H). A widget that draws past its own pane's
  edge should use these instead of the unchecked MSetCell/MPutCodepoint,
  which do not know about any pane boundary at all. }
function MSetCellClipped(var Buf: TCellBuffer; ClipX, ClipY, ClipW, ClipH,
  X, Y: Integer; const C: TCell): Boolean;

{ Same clipping contract as MSetCellClipped, wide-glyph-aware like
  MPutCodepoint. Always returns the full column width the glyph would
  have advanced (1 or 2) even when fully or partially clipped away, so
  callers laying out left-to-right text keep correct cursor math
  regardless of how much was actually visible. }
function MPutCodepointClipped(var Buf: TCellBuffer; ClipX, ClipY, ClipW, ClipH,
  X, Y: Integer; CP: TMUInt32; const Fg, Bg: TMColor; Style: TMCellStyle): Integer;

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

function MIsWideContinuation(const C: TCell): Boolean; inline;
begin
  Result := C.CodePoint = MWideContinuation;
end;

type
  TMCPRange = record
    Lo, Hi: TMUInt32;
  end;

const
  { Practical zero-width subset: combining diacriticals (Latin, Cyrillic,
    Hebrew, Arabic, Thai), zero-width space/joiners, variation selectors,
    combining half marks. Sorted, non-overlapping, ascending by Lo. }
  ZeroWidthRanges: array[0..10] of TMCPRange = (
    (Lo: $0300; Hi: $036F),  { Combining Diacritical Marks }
    (Lo: $0483; Hi: $0489),  { Combining Cyrillic }
    (Lo: $0591; Hi: $05C7),  { Hebrew points, approximated as one range }
    (Lo: $0610; Hi: $061A),  { Arabic marks }
    (Lo: $064B; Hi: $065F),  { Arabic combining }
    (Lo: $0670; Hi: $0670),  { Arabic letter superscript alef }
    (Lo: $06D6; Hi: $06ED),  { Arabic marks, approximated as one range }
    (Lo: $0E31; Hi: $0E3A),  { Thai combining, approximated as one range }
    (Lo: $200B; Hi: $200F),  { zero-width space/joiners/marks }
    (Lo: $20D0; Hi: $20FF),  { Combining Diacritical Marks for Symbols }
    (Lo: $FE00; Hi: $FE0F)   { Variation selectors }
  );

  { Practical East-Asian-Wide subset: Hangul Jamo, CJK punctuation/
    radicals/ideographs, Hiragana/Katakana, Hangul syllables, CJK
    compatibility, fullwidth forms, and the supplementary-plane CJK
    ideograph extensions. Sorted, non-overlapping, ascending by Lo. }
  WideRanges: array[0..11] of TMCPRange = (
    (Lo: $1100;  Hi: $115F),
    (Lo: $2E80;  Hi: $303E),
    (Lo: $3041;  Hi: $33FF),
    (Lo: $3400;  Hi: $4DBF),
    (Lo: $4E00;  Hi: $9FFF),
    (Lo: $A000;  Hi: $A4CF),
    (Lo: $AC00;  Hi: $D7A3),
    (Lo: $F900;  Hi: $FAFF),
    (Lo: $FF00;  Hi: $FF60),
    (Lo: $FFE0;  Hi: $FFE6),
    (Lo: $20000; Hi: $2FFFD),
    (Lo: $30000; Hi: $3FFFD)
  );

function InRanges(CP: TMUInt32; const Ranges: array of TMCPRange): Boolean;
var
  Lo, Hi, Mid: Integer;
begin
  Lo := 0;
  Hi := High(Ranges);
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if CP < Ranges[Mid].Lo then Hi := Mid - 1
    else if CP > Ranges[Mid].Hi then Lo := Mid + 1
    else Exit(True);
  end;
  Result := False;
end;

function MCodepointWidth(CP: TMUInt32): Integer;
begin
  if InRanges(CP, ZeroWidthRanges) then Result := 0
  else if InRanges(CP, WideRanges) then Result := 2
  else Result := 1;
end;

function MPutCodepoint(var Buf: TCellBuffer; X, Y: Integer; CP: TMUInt32;
  const Fg, Bg: TMColor; Style: TMCellStyle): Integer;
var
  C: TCell;
  W: Integer;
begin
  W := MCodepointWidth(CP);
  if W < 1 then W := 1; { see interface doc comment: no composition, so never 0 here }

  C.CodePoint := CP;
  C.Fg := Fg;
  C.Bg := Bg;
  C.Style := Style;
  MSetCell(Buf, X, Y, C);

  if (W = 2) and (X + 1 < Buf.Width) then
  begin
    C.CodePoint := MWideContinuation;
    MSetCell(Buf, X + 1, Y, C);
  end;

  Result := W;
end;

function MSetCellClipped(var Buf: TCellBuffer; ClipX, ClipY, ClipW, ClipH,
  X, Y: Integer; const C: TCell): Boolean;
begin
  Result := (X >= ClipX) and (X < ClipX + ClipW) and (X >= 0) and (X < Buf.Width)
    and (Y >= ClipY) and (Y < ClipY + ClipH) and (Y >= 0) and (Y < Buf.Height);
  if Result then
    MSetCell(Buf, X, Y, C);
end;

function MPutCodepointClipped(var Buf: TCellBuffer; ClipX, ClipY, ClipW, ClipH,
  X, Y: Integer; CP: TMUInt32; const Fg, Bg: TMColor; Style: TMCellStyle): Integer;
var
  C: TCell;
  W: Integer;
begin
  W := MCodepointWidth(CP);
  if W < 1 then W := 1;

  C.CodePoint := CP;
  C.Fg := Fg;
  C.Bg := Bg;
  C.Style := Style;
  MSetCellClipped(Buf, ClipX, ClipY, ClipW, ClipH, X, Y, C);

  if W = 2 then
  begin
    C.CodePoint := MWideContinuation;
    MSetCellClipped(Buf, ClipX, ClipY, ClipW, ClipH, X + 1, Y, C);
  end;

  Result := W;
end;

end.
