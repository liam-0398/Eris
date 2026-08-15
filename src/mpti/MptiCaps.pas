{
  Terminal capability negotiation (mpti.md #5). Dependency-free (hard
  requirement 9) means this cannot reach for terminfo/ncurses the way a
  normal 256-color-aware TUI toolkit would - the capability knowledge has
  to be built into the framework itself: a small internal heuristic
  table keyed on $TERM/$COLORTERM, refined at runtime by whatever the
  terminal driver (Phase 2) manages to probe over the wire (DA1/DA2
  device-attribute queries).

  Everything in this unit is pure and terminal-I/O-free by design, so it
  is fully exercisable by the headless test harness (Phase 4) without a
  real tty: given a $TERM/$COLORTERM string, or a captured DA1 response
  string, what capabilities does MPTI conclude?

  The degradation ladder itself (mpti.md #5: truecolor -> 256 -> 16 ->
  mono) is implemented here as the color-quantization functions the
  renderer (Phase 3) calls once per changed cell, keyed off the
  TMColorMode this unit resolved at startup.
}
unit MptiCaps;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, MptiTypes, MptiCell;

type
  TMColorMode = (mcmMono, mcm16, mcm256, mcmTrueColor);

  TMTermCaps = record
    ColorMode: TMColorMode;
    { SGR (1006) mouse mode: coordinates unbounded, terminates on M/m.
      Legacy X10 mouse mode: coordinates encoded as byte+32, capped at
      223 columns before the encoding wraps - see MMouseMaxCols and the
      DysGeometry DARWIN-ifdef precedent this preserves. }
    MouseSGR1006: Boolean;
    MouseMaxCols: Integer; { -1 = unbounded (SGR1006) }
    BracketedPaste: Boolean;
    FocusEvents: Boolean;
    KittyKeyboard: Boolean;
    { Whether the terminal's locale is UTF-8, per $LANG/$LC_ALL/$LC_CTYPE -
      needed by anything that wants to gate a Unicode-block-specific glyph
      (braille dot patterns U+2800-28FF, say) behind more than "some xterm
      or other", since the box-drawing/block glyphs MPTI already uses
      unconditionally are safe on any terminal built after CP437-only
      hardware went away but braille cells are a much newer, less
      universally-fonted block. False (conservative) whenever the locale
      string doesn't mention UTF-8 at all, same "err toward the lower
      capability on ambiguity" rule MCapsFromEnv already follows for
      everything else in this record. }
    UnicodeOk: Boolean;
  end;

  TMDeviceAttrs = record
    Valid: Boolean;
    TermType: Integer;      { first DA1 parameter }
    Features: array of Integer; { remaining DA1 parameters }
  end;

const
  { Legacy X10 mouse reporting encodes coordinates as a single byte
    (value + 32), which wraps above this column - the same constant
    DysGeometry.pas hardcodes for the DARWIN/Tiger-xterm case. }
  MMouseLegacyMaxCols = 223;

{ Conservative heuristic baseline from environment strings alone, before
  any runtime probing has happened (or if it never can - e.g. output is
  not actually a tty). Errs toward the safe/lower capability whenever a
  $TERM value is ambiguous. }
function MCapsFromEnv(const TermEnv, ColorTermEnv: string; const LocaleEnv: string = ''): TMTermCaps;

{ Least-capable caps: 16 colors, no SGR1006, no paste/focus/kitty. Used
  as the MCapsFromEnv fallback for completely unrecognized $TERM values,
  and as a safe starting point before any negotiation has occurred. }
function MMinimalCaps: TMTermCaps;

{ Parses a raw DA1 response of the shape ESC [ ? Pn ; Pn ; ... c (the
  ESC[? prefix and trailing c/letter are optional - callers may pass
  either the full escape sequence or just the parameter list). Returns
  Valid = False if Resp does not contain a parseable parameter list. }
function MParseDeviceAttrs1(const Resp: string): TMDeviceAttrs;
function MDeviceAttrsHasFeature(const Attrs: TMDeviceAttrs; Feature: Integer): Boolean;

{ Degradation ladder: reduce a full-fidelity 24-bit color to what
  ColorMode can actually display. }
function MQuantizeToXterm256(const C: TMColor): Byte;
function MQuantizeToAnsi16(const C: TMColor): Byte; { 0-15 }
{ Mono has no color at all - only on/off. Returns True if C is bright
  enough that the renderer should compensate with csBold rather than
  drop the distinction entirely. }
function MQuantizeToMonoBright(const C: TMColor): Boolean;

implementation

function MMinimalCaps: TMTermCaps;
begin
  Result.ColorMode := mcm16;
  Result.MouseSGR1006 := False;
  Result.MouseMaxCols := MMouseLegacyMaxCols;
  Result.BracketedPaste := False;
  Result.FocusEvents := False;
  Result.KittyKeyboard := False;
  Result.UnicodeOk := False;
end;

function MCapsFromEnv(const TermEnv, ColorTermEnv: string; const LocaleEnv: string = ''): TMTermCaps;
var
  T, CT, Loc: string;
begin
  Result := MMinimalCaps;
  T := LowerCase(TermEnv);
  CT := LowerCase(ColorTermEnv);
  Loc := UpperCase(LocaleEnv);
  Result.UnicodeOk := (Pos('UTF-8', Loc) > 0) or (Pos('UTF8', Loc) > 0);

  if T = '' then
    Exit; { no $TERM at all: stay minimal, most conservative case }

  { Color depth }
  if (CT = 'truecolor') or (CT = '24bit') or (Pos('direct', T) > 0) then
    Result.ColorMode := mcmTrueColor
  else if (Pos('256color', T) > 0) or (Pos('256', T) > 0) then
    Result.ColorMode := mcm256
  else if (T = 'linux') or (T = 'xterm') or (T = 'xterm-color')
       or (T = 'vt100') or (T = 'vt220') or (T = 'dumb') then
    Result.ColorMode := mcm16
  else
    Result.ColorMode := mcm16; { unrecognized: stay conservative }

  { Mouse protocol. SGR1006 is near-universal on anything actively
    maintained (xterm since ~2010, all xterm-256color-reporting
    terminals, screen/tmux passthrough) but is exactly what Tiger's
    stock 'xterm'/'xterm-color' TERM predates - preserve the
    DysGeometry-documented fallback for that case rather than assuming
    it's available. Runtime probing (Phase 2) is the authoritative
    source; this is only the pre-probe guess. }
  if (T = 'xterm') or (T = 'xterm-color') or (T = 'vt100') or (T = 'vt220')
     or (T = 'dumb') then
  begin
    Result.MouseSGR1006 := False;
    Result.MouseMaxCols := MMouseLegacyMaxCols;
  end
  else if T = 'linux' then
  begin
    { Linux virtual console: no X11-style mouse reporting protocol at
      all in the general case (gpm aside, out of scope). }
    Result.MouseSGR1006 := False;
    Result.MouseMaxCols := 0;
  end
  else
  begin
    Result.MouseSGR1006 := True;
    Result.MouseMaxCols := -1;
  end;

  { Bracketed paste / focus events: supported by every terminal family
    modern enough to also do SGR1006, absent on the old/dumb set above. }
  Result.BracketedPaste := Result.MouseSGR1006;
  Result.FocusEvents := Result.MouseSGR1006;

  { Kitty keyboard protocol: only ever present on terminals that
    self-identify unambiguously; $TERM alone is not reliable evidence,
    so this stays False here and is only ever set True by an actual
    runtime probe in Phase 2. }
  Result.KittyKeyboard := False;
end;

function MParseDeviceAttrs1(const Resp: string): TMDeviceAttrs;
var
  S: string;
  StartIdx, I: Integer;
  Nums: array of Integer;
  NumCount: Integer;
  Cur: string;

  procedure FlushCur;
  begin
    if Cur <> '' then
    begin
      SetLength(Nums, NumCount + 1);
      Nums[NumCount] := StrToIntDef(Cur, 0);
      Inc(NumCount);
      Cur := '';
    end;
  end;

begin
  Result.Valid := False;
  Result.TermType := 0;
  SetLength(Result.Features, 0);
  SetLength(Nums, 0);

  { Strip a leading ESC [ ? and a trailing letter (c, or any alpha final
    byte), if present, leaving just the ';'-separated parameter list. }
  S := Resp;
  StartIdx := Pos('[', S);
  if StartIdx > 0 then
    S := Copy(S, StartIdx + 1, Length(S) - StartIdx);
  if (Length(S) > 0) and (S[1] = '?') then
    Delete(S, 1, 1);
  if (Length(S) > 0) and (S[Length(S)] in ['a'..'z', 'A'..'Z']) then
    SetLength(S, Length(S) - 1);

  if S = '' then
    Exit;

  NumCount := 0;
  Cur := '';
  for I := 1 to Length(S) do
  begin
    if S[I] = ';' then
      FlushCur
    else if S[I] in ['0'..'9'] then
      Cur := Cur + S[I]
    else
    begin
      { unexpected character: not a DA1-shaped response }
      Exit;
    end;
  end;
  FlushCur;

  if NumCount = 0 then
    Exit;

  Result.Valid := True;
  Result.TermType := Nums[0];
  if NumCount > 1 then
  begin
    SetLength(Result.Features, NumCount - 1);
    for I := 1 to NumCount - 1 do
      Result.Features[I - 1] := Nums[I];
  end;
end;

function MDeviceAttrsHasFeature(const Attrs: TMDeviceAttrs; Feature: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  if not Attrs.Valid then
    Exit;
  for I := 0 to High(Attrs.Features) do
    if Attrs.Features[I] = Feature then
    begin
      Result := True;
      Exit;
    end;
end;

function MQuantizeToXterm256(const C: TMColor): Byte;

  function CubeStep(V: Byte): Integer; inline;
  begin
    { xterm's 6-step color cube ramp: 0, 95, 135, 175, 215, 255 }
    if V < 48 then Result := 0
    else if V < 115 then Result := 1
    else Result := (V - 35) div 40;
    if Result > 5 then Result := 5;
  end;

const
  CubeVal: array[0..5] of Integer = (0, 95, 135, 175, 215, 255);
var
  IR, IG, IB: Integer;
  CubeR, CubeG, CubeB: Integer;
  GrayLevel, GrayVal: Integer;
  CubeDist, GrayDist: Integer;
  Luma: Integer;
begin
  IR := C.R; IG := C.G; IB := C.B;

  { Nearest color-cube index (16..231) }
  CubeR := CubeStep(C.R);
  CubeG := CubeStep(C.G);
  CubeB := CubeStep(C.B);
  CubeDist := Sqr(IR - CubeVal[CubeR]) + Sqr(IG - CubeVal[CubeG]) + Sqr(IB - CubeVal[CubeB]);

  { Nearest grayscale-ramp index (232..255), 24 steps from 8 to 238 }
  Luma := (IR + IG + IB) div 3;
  GrayLevel := (Luma - 8) div 10;
  if GrayLevel < 0 then GrayLevel := 0;
  if GrayLevel > 23 then GrayLevel := 23;
  GrayVal := 8 + GrayLevel * 10;
  GrayDist := Sqr(IR - GrayVal) + Sqr(IG - GrayVal) + Sqr(IB - GrayVal);

  if GrayDist < CubeDist then
    Result := 232 + GrayLevel
  else
    Result := 16 + (36 * CubeR) + (6 * CubeG) + CubeB;
end;

function MQuantizeToAnsi16(const C: TMColor): Byte;
const
  { Standard xterm ANSI 0-15 approximate RGB values. }
  Palette: array[0..15] of TMColor = (
    (R:0;   G:0;   B:0),    (R:205; G:0;   B:0),   (R:0;   G:205; B:0),   (R:205; G:205; B:0),
    (R:0;   G:0;   B:238),  (R:205; G:0;   B:205), (R:0;   G:205; B:205), (R:229; G:229; B:229),
    (R:127; G:127; B:127),  (R:255; G:0;   B:0),   (R:0;   G:255; B:0),   (R:255; G:255; B:0),
    (R:92;  G:92;  B:255),  (R:255; G:0;   B:255), (R:0;   G:255; B:255), (R:255; G:255; B:255)
  );
var
  I, Best, BestDist, Dist: Integer;
begin
  Best := 0;
  BestDist := MaxInt;
  for I := 0 to 15 do
  begin
    Dist := Sqr(Integer(C.R) - Integer(Palette[I].R))
      + Sqr(Integer(C.G) - Integer(Palette[I].G))
      + Sqr(Integer(C.B) - Integer(Palette[I].B));
    if Dist < BestDist then
    begin
      BestDist := Dist;
      Best := I;
    end;
  end;
  Result := Best;
end;

function MQuantizeToMonoBright(const C: TMColor): Boolean;
var
  Luma: Integer;
begin
  { Perceptual luma threshold (Rec. 601 weights, integer approximation). }
  Luma := (299 * C.R + 587 * C.G + 114 * C.B) div 1000;
  Result := Luma > 127;
end;

end.
