{
  Hand-written VT/SGR input parser (mpti.md #5, #10). MPTI is
  dependency-free (hard requirement 9), so this cannot delegate to FPC's
  rtl-console unix mouse/keyboard decoding the way src/tui does via Free
  Vision - nothing reusable exists in this repo for that, confirmed
  during planning. This unit is that parser, written from scratch.

  Deliberately pure and terminal-I/O-free: it consumes bytes that some
  caller already read from somewhere (a real fd in MptiDriver, or a
  scripted byte array in a headless test) and produces events. That
  split is what makes this exhaustively unit-testable without a real
  tty - see the checks in mptidemo.lpr.

  Scope: keyboard (C0 controls, CSI/SS3 function-key forms, UTF-8
  printable text, Alt-prefixed keys, Ctrl+letter), mouse (SGR 1006
  primary, legacy X10 fallback per mpti.md's DysGeometry-column-clamp
  precedent), bracketed paste, focus in/out. The kitty keyboard protocol
  is out of scope for now (mpti.md only asks MptiCaps to detect it, not
  for MPTI to speak it yet) - any kitty-protocol CSI-u sequence a
  terminal sends unprompted will fall through and decode as its literal
  bytes rather than crash the parser; this is safe because MptiDriver
  never enables that protocol.
}
unit MptiInput;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, MptiTypes;

type
  TMKeyCode = (
    mkNone, mkChar, mkEnter, mkTab, mkBackspace, mkEscape,
    mkUp, mkDown, mkLeft, mkRight,
    mkHome, mkEnd, mkPageUp, mkPageDown, mkInsert, mkDelete,
    mkF1, mkF2, mkF3, mkF4, mkF5, mkF6, mkF7, mkF8, mkF9, mkF10, mkF11, mkF12
  );

  TMKeyMod = (kmShift, kmAlt, kmCtrl);
  TMKeyModSet = set of TMKeyMod;

  TMKeyEvent = record
    Code: TMKeyCode;
    CodePoint: TMUInt32; { valid when Code = mkChar }
    Mods: TMKeyModSet;
  end;

  TMMouseButton = (mbNone, mbLeft, mbMiddle, mbRight, mbWheelUp, mbWheelDown);
  TMMouseAction = (maPress, maRelease, maDrag, maMove);

  TMMouseEvent = record
    X, Y: Integer; { 0-based }
    Button: TMMouseButton;
    Action: TMMouseAction;
    Mods: TMKeyModSet;
  end;

  TMEventKind = (mekNone, mekKey, mekMouse, mekPaste, mekFocusIn, mekFocusOut);

  TMInputEvent = record
    Kind: TMEventKind;
    Key: TMKeyEvent;
    Mouse: TMMouseEvent;
    PasteText: string; { valid when Kind = mekPaste }
  end;

  TMInputEventArray = array of TMInputEvent;

  TMInputParseState = record
    Pending: TMByteArray;   { unconsumed bytes carried across MFeedInput calls }
    InPaste: Boolean;
    PasteBuf: string;
  end;

procedure MInitInputParseState(out State: TMInputParseState);

{ Appends any bytes still pending from a previous call to Data, parses as
  many complete events as possible, appends them to Events, and leaves
  whatever trailing bytes are not yet a complete sequence in
  State.Pending for the next call. }
procedure MFeedInput(var State: TMInputParseState; const Data: array of Byte;
  var Events: TMInputEventArray);

{ Called by the driver when the escape-ambiguity timeout fires (no more
  bytes arrived after a lone ESC, so it wasn't the start of a longer
  sequence after all). If State.Pending is exactly a single ESC byte,
  emits it as a literal Escape keypress; otherwise the pending bytes are
  an incomplete/malformed sequence and are discarded. Either way,
  State.Pending is cleared. }
procedure MFlushPendingEscape(var State: TMInputParseState; var Events: TMInputEventArray);

implementation

procedure MInitInputParseState(out State: TMInputParseState);
begin
  SetLength(State.Pending, 0);
  State.InPaste := False;
  State.PasteBuf := '';
end;

procedure AppendEvent(var Events: TMInputEventArray; const Ev: TMInputEvent);
begin
  SetLength(Events, Length(Events) + 1);
  Events[High(Events)] := Ev;
end;

function BlankEvent: TMInputEvent;
begin
  Result.Kind := mekNone;
  FillChar(Result.Key, SizeOf(Result.Key), 0);
  FillChar(Result.Mouse, SizeOf(Result.Mouse), 0);
  Result.PasteText := '';
end;

function KeyEvent(Code: TMKeyCode; Mods: TMKeyModSet): TMInputEvent;
begin
  Result := BlankEvent;
  Result.Kind := mekKey;
  Result.Key.Code := Code;
  Result.Key.CodePoint := 0;
  Result.Key.Mods := Mods;
end;

function CharEvent(CodePoint: TMUInt32; Mods: TMKeyModSet): TMInputEvent;
begin
  Result := BlankEvent;
  Result.Kind := mekKey;
  Result.Key.Code := mkChar;
  Result.Key.CodePoint := CodePoint;
  Result.Key.Mods := Mods;
end;

function ModsFromSGRParam(P: Integer): TMKeyModSet;
var
  Bits: Integer;
begin
  Result := [];
  if P <= 0 then Exit;
  Bits := P - 1;
  if (Bits and 1) <> 0 then Include(Result, kmShift);
  if (Bits and 2) <> 0 then Include(Result, kmAlt);
  if (Bits and 4) <> 0 then Include(Result, kmCtrl);
end;

{ UTF-8 sequence length from a lead byte, or 0 if Lead is not a valid
  UTF-8 lead byte (continuation byte or invalid). }
function Utf8SeqLen(Lead: Byte): Integer;
begin
  if Lead < $80 then Result := 1
  else if (Lead and $E0) = $C0 then Result := 2
  else if (Lead and $F0) = $E0 then Result := 3
  else if (Lead and $F8) = $F0 then Result := 4
  else Result := 0;
end;

function DecodeUtf8(const Buf: TMByteArray; Pos, Len: Integer): TMUInt32;
begin
  case Len of
    1: Result := Buf[Pos];
    2: Result := ((Buf[Pos] and $1F) shl 6) or (Buf[Pos + 1] and $3F);
    3: Result := ((Buf[Pos] and $0F) shl 12) or ((Buf[Pos + 1] and $3F) shl 6)
                 or (Buf[Pos + 2] and $3F);
    4: Result := ((Buf[Pos] and $07) shl 18) or ((Buf[Pos + 1] and $3F) shl 12)
                 or ((Buf[Pos + 2] and $3F) shl 6) or (Buf[Pos + 3] and $3F);
  else
    Result := Buf[Pos];
  end;
end;

{ Splits a CSI parameter string like "1;5" into integers. Empty fields
  become 0 (CSI's documented default). }
procedure SplitParams(const S: string; out Nums: array of Integer; out Count: Integer);
var
  I: Integer;
  Cur: string;

  procedure Flush;
  begin
    if Count <= High(Nums) then
      Nums[Count] := StrToIntDef(Cur, 0);
    Inc(Count);
    Cur := '';
  end;

begin
  Count := 0;
  Cur := '';
  for I := 1 to Length(S) do
  begin
    if S[I] = ';' then
      Flush
    else if S[I] in ['0'..'9'] then
      Cur := Cur + S[I];
  end;
  Flush;
end;

const
  ParseCap = 64; { max bytes a CSI/SS3 sequence may scan before giving up }

type
  TParseOutcome = (poOk, poIncomplete, poInvalid);

{ Tries to parse one complete event starting at Buf[Pos] (0-based).
  On poOk, Consumed is the number of bytes making up that event (Ev is
  valid, but Ev.Kind may be mekNone for sequences that are consumed but
  produce no user-visible event, e.g. a bracketed-paste start marker).
  On poIncomplete, more bytes are needed before a decision can be made.
  On poInvalid, the byte at Pos is unrecognized/malformed; the caller
  should skip exactly 1 byte and resync. }
function TryParseOne(const Buf: TMByteArray; Pos, Len: Integer;
  out Consumed: Integer; out Ev: TMInputEvent): TParseOutcome;
var
  B: Byte;
  P2: Integer;
  FinalPos: Integer;
  ParamStr: string;
  Marker: Char;
  Nums: array[0..7] of Integer;
  NumCount: Integer;
  SeqLen: Integer;
  Cb, Cx, Cy: Integer;
  ButtonBits: Integer;
  IsWheel, IsMotion: Boolean;
begin
  Consumed := 0;
  Ev := BlankEvent;
  B := Buf[Pos];

  case B of
    27: { ESC }
      begin
        if Pos + 1 >= Len then
          Exit(poIncomplete); { lone ESC so far - driver resolves via timeout }

        if Buf[Pos + 1] = Ord('[') then
        begin
          { Legacy X10 mouse: CSI M Cb Cx Cy - fixed 3 raw bytes after 'M',
            no final-byte scan applies. }
          if (Pos + 2 < Len) and (Buf[Pos + 2] = Ord('M')) then
          begin
            if Pos + 5 >= Len then
              Exit(poIncomplete);
            Cb := Buf[Pos + 3] - 32;
            Cx := Buf[Pos + 4] - 32;
            Cy := Buf[Pos + 5] - 32;
            ButtonBits := Cb and 3;
            IsWheel := (Cb and 64) <> 0;
            Ev.Kind := mekMouse;
            Ev.Mouse.X := Cx - 1;
            Ev.Mouse.Y := Cy - 1;
            Ev.Mouse.Mods := [];
            if (Cb and 4) <> 0 then Include(Ev.Mouse.Mods, kmShift);
            if (Cb and 8) <> 0 then Include(Ev.Mouse.Mods, kmAlt);
            if (Cb and 16) <> 0 then Include(Ev.Mouse.Mods, kmCtrl);
            if IsWheel then
            begin
              if ButtonBits = 0 then Ev.Mouse.Button := mbWheelUp
              else Ev.Mouse.Button := mbWheelDown;
              Ev.Mouse.Action := maPress;
            end
            else if ButtonBits = 3 then
            begin
              Ev.Mouse.Button := mbNone;
              Ev.Mouse.Action := maRelease;
            end
            else
            begin
              case ButtonBits of
                0: Ev.Mouse.Button := mbLeft;
                1: Ev.Mouse.Button := mbMiddle;
                2: Ev.Mouse.Button := mbRight;
              end;
              Ev.Mouse.Action := maPress;
            end;
            Consumed := 6;
            Exit(poOk);
          end;

          { General CSI: scan for a final byte in $40..$7E. }
          P2 := Pos + 2;
          FinalPos := -1;
          while (P2 < Len) and (P2 - Pos < ParseCap) do
          begin
            if Buf[P2] in [$40..$7E] then
            begin
              FinalPos := P2;
              Break;
            end;
            Inc(P2);
          end;

          if FinalPos < 0 then
          begin
            if P2 - Pos >= ParseCap then
              Exit(poInvalid); { runaway garbage, resync }
            Exit(poIncomplete);
          end;

          ParamStr := '';
          Marker := #0;
          P2 := Pos + 2;
          if (P2 < FinalPos) and (Buf[P2] in [Ord('<'), Ord('?'), Ord('=')]) then
          begin
            Marker := Chr(Buf[P2]);
            Inc(P2);
          end;
          while P2 < FinalPos do
          begin
            ParamStr := ParamStr + Chr(Buf[P2]);
            Inc(P2);
          end;

          Consumed := FinalPos - Pos + 1;
          SplitParams(ParamStr, Nums, NumCount);

          case Chr(Buf[FinalPos]) of
            'M', 'm':
              if Marker = '<' then
              begin
                if NumCount < 3 then Exit(poInvalid);
                Cb := Nums[0]; Cx := Nums[1]; Cy := Nums[2];
                ButtonBits := Cb and 3;
                IsWheel := (Cb and 64) <> 0;
                IsMotion := (Cb and 32) <> 0;
                Ev.Kind := mekMouse;
                Ev.Mouse.X := Cx - 1;
                Ev.Mouse.Y := Cy - 1;
                Ev.Mouse.Mods := [];
                if (Cb and 4) <> 0 then Include(Ev.Mouse.Mods, kmShift);
                if (Cb and 8) <> 0 then Include(Ev.Mouse.Mods, kmAlt);
                if (Cb and 16) <> 0 then Include(Ev.Mouse.Mods, kmCtrl);
                if IsWheel then
                begin
                  if ButtonBits = 0 then Ev.Mouse.Button := mbWheelUp
                  else Ev.Mouse.Button := mbWheelDown;
                  Ev.Mouse.Action := maPress;
                end
                else
                begin
                  case ButtonBits of
                    0: Ev.Mouse.Button := mbLeft;
                    1: Ev.Mouse.Button := mbMiddle;
                    2: Ev.Mouse.Button := mbRight;
                  else
                    Ev.Mouse.Button := mbNone;
                  end;
                  if IsMotion then Ev.Mouse.Action := maDrag
                  else if Chr(Buf[FinalPos]) = 'M' then Ev.Mouse.Action := maPress
                  else Ev.Mouse.Action := maRelease;
                end;
              end
              else
                Exit(poInvalid);
            'A': Ev := KeyEvent(mkUp, ModsFromSGRParam(Nums[1]));
            'B': Ev := KeyEvent(mkDown, ModsFromSGRParam(Nums[1]));
            'C': Ev := KeyEvent(mkRight, ModsFromSGRParam(Nums[1]));
            'D': Ev := KeyEvent(mkLeft, ModsFromSGRParam(Nums[1]));
            'H': Ev := KeyEvent(mkHome, ModsFromSGRParam(Nums[1]));
            'F': Ev := KeyEvent(mkEnd, ModsFromSGRParam(Nums[1]));
            'P': Ev := KeyEvent(mkF1, ModsFromSGRParam(Nums[1]));
            'Q': Ev := KeyEvent(mkF2, ModsFromSGRParam(Nums[1]));
            'R': Ev := KeyEvent(mkF3, ModsFromSGRParam(Nums[1]));
            'S': Ev := KeyEvent(mkF4, ModsFromSGRParam(Nums[1]));
            'I': Ev.Kind := mekFocusIn;
            'O': Ev.Kind := mekFocusOut;
            '~':
              begin
                if NumCount = 0 then
                  Exit(poInvalid);
                case Nums[0] of
                  1, 7:   Ev := KeyEvent(mkHome, ModsFromSGRParam(Nums[1]));
                  2:      Ev := KeyEvent(mkInsert, ModsFromSGRParam(Nums[1]));
                  3:      Ev := KeyEvent(mkDelete, ModsFromSGRParam(Nums[1]));
                  4, 8:   Ev := KeyEvent(mkEnd, ModsFromSGRParam(Nums[1]));
                  5:      Ev := KeyEvent(mkPageUp, ModsFromSGRParam(Nums[1]));
                  6:      Ev := KeyEvent(mkPageDown, ModsFromSGRParam(Nums[1]));
                  11:     Ev := KeyEvent(mkF1, ModsFromSGRParam(Nums[1]));
                  12:     Ev := KeyEvent(mkF2, ModsFromSGRParam(Nums[1]));
                  13:     Ev := KeyEvent(mkF3, ModsFromSGRParam(Nums[1]));
                  14:     Ev := KeyEvent(mkF4, ModsFromSGRParam(Nums[1]));
                  15:     Ev := KeyEvent(mkF5, ModsFromSGRParam(Nums[1]));
                  17:     Ev := KeyEvent(mkF6, ModsFromSGRParam(Nums[1]));
                  18:     Ev := KeyEvent(mkF7, ModsFromSGRParam(Nums[1]));
                  19:     Ev := KeyEvent(mkF8, ModsFromSGRParam(Nums[1]));
                  20:     Ev := KeyEvent(mkF9, ModsFromSGRParam(Nums[1]));
                  21:     Ev := KeyEvent(mkF10, ModsFromSGRParam(Nums[1]));
                  23:     Ev := KeyEvent(mkF11, ModsFromSGRParam(Nums[1]));
                  24:     Ev := KeyEvent(mkF12, ModsFromSGRParam(Nums[1]));
                  200:    Ev.Kind := mekNone; { paste-start: caller enters paste mode }
                  201:    Ev.Kind := mekNone; { stray paste-end outside paste mode: ignore }
                else
                  Ev.Kind := mekNone;
                end;
              end;
          else
            Exit(poInvalid);
          end;

          Exit(poOk);
        end
        else if Buf[Pos + 1] = Ord('O') then
        begin
          { SS3: ESC O <letter>, xterm F1-F4, unmodified. }
          if Pos + 2 >= Len then
            Exit(poIncomplete);
          Consumed := 3;
          case Chr(Buf[Pos + 2]) of
            'P': Ev := KeyEvent(mkF1, []);
            'Q': Ev := KeyEvent(mkF2, []);
            'R': Ev := KeyEvent(mkF3, []);
            'S': Ev := KeyEvent(mkF4, []);
          else
            Exit(poInvalid);
          end;
          Exit(poOk);
        end
        else
        begin
          { Alt+<byte>: reparse the byte after ESC as a normal key, add
            kmAlt, consume ESC + however many bytes that key needed. }
          case TryParseOne(Buf, Pos + 1, Len, SeqLen, Ev) of
            poOk:
              begin
                Include(Ev.Key.Mods, kmAlt);
                Consumed := SeqLen + 1;
                Exit(poOk);
              end;
            poIncomplete: Exit(poIncomplete);
          else
            Exit(poInvalid);
          end;
        end;
      end;

    9: begin Ev := KeyEvent(mkTab, []); Consumed := 1; Exit(poOk); end;
    10, 13: begin Ev := KeyEvent(mkEnter, []); Consumed := 1; Exit(poOk); end;
    127, 8: begin Ev := KeyEvent(mkBackspace, []); Consumed := 1; Exit(poOk); end;
    0: begin Ev := CharEvent(32, [kmCtrl]); Consumed := 1; Exit(poOk); end;
    1..7, 11, 12, 14..26:
      begin
        Ev := CharEvent(B + 96, [kmCtrl]);
        Consumed := 1;
        Exit(poOk);
      end;
    28..31:
      begin
        Ev := CharEvent(B + 64, [kmCtrl]);
        Consumed := 1;
        Exit(poOk);
      end;
  else
    if B < 128 then
    begin
      Ev := CharEvent(B, []);
      Consumed := 1;
      Exit(poOk);
    end
    else
    begin
      SeqLen := Utf8SeqLen(B);
      if SeqLen = 0 then
        Exit(poInvalid);
      if Pos + SeqLen > Len then
        Exit(poIncomplete);
      Ev := CharEvent(DecodeUtf8(Buf, Pos, SeqLen), []);
      Consumed := SeqLen;
      Exit(poOk);
    end;
  end;
end;

const
  PasteStart: array[0..7] of Byte = (27, Ord('['), Ord('2'), Ord('0'), Ord('0'), Ord('~'), 0, 0);
  PasteStartLen = 6;
  PasteEnd: array[0..7] of Byte = (27, Ord('['), Ord('2'), Ord('0'), Ord('1'), Ord('~'), 0, 0);
  PasteEndLen = 6;

function MatchesAt(const Buf: TMByteArray; Pos, Len: Integer;
  const Pattern: array of Byte; PatLen: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Pos + PatLen > Len then Exit;
  for I := 0 to PatLen - 1 do
    if Buf[Pos + I] <> Pattern[I] then Exit;
  Result := True;
end;

procedure MFeedInput(var State: TMInputParseState; const Data: array of Byte;
  var Events: TMInputEventArray);
var
  Buf: TMByteArray;
  Len, Pos, Consumed: Integer;
  Outcome: TParseOutcome;
  Ev: TMInputEvent;
  PasteEv: TMInputEvent;
begin
  SetLength(Buf, Length(State.Pending) + Length(Data));
  if Length(State.Pending) > 0 then
    Move(State.Pending[0], Buf[0], Length(State.Pending));
  if Length(Data) > 0 then
    Move(Data[0], Buf[Length(State.Pending)], Length(Data));
  Len := Length(Buf);
  Pos := 0;

  while Pos < Len do
  begin
    if State.InPaste then
    begin
      if MatchesAt(Buf, Pos, Len, PasteEnd, PasteEndLen) then
      begin
        PasteEv := BlankEvent;
        PasteEv.Kind := mekPaste;
        PasteEv.PasteText := State.PasteBuf;
        AppendEvent(Events, PasteEv);
        State.PasteBuf := '';
        State.InPaste := False;
        Pos := Pos + PasteEndLen;
      end
      else
      begin
        State.PasteBuf := State.PasteBuf + Chr(Buf[Pos]);
        Inc(Pos);
      end;
      Continue;
    end;

    if MatchesAt(Buf, Pos, Len, PasteStart, PasteStartLen) then
    begin
      State.InPaste := True;
      State.PasteBuf := '';
      Pos := Pos + PasteStartLen;
      Continue;
    end;

    Outcome := TryParseOne(Buf, Pos, Len, Consumed, Ev);
    case Outcome of
      poOk:
        begin
          if Ev.Kind <> mekNone then
            AppendEvent(Events, Ev);
          Inc(Pos, Consumed);
        end;
      poInvalid:
        Inc(Pos); { resync: drop one byte }
      poIncomplete:
        Break;
    end;
  end;

  if State.InPaste then
  begin
    { Bytes already folded into PasteBuf; nothing left pending. }
    SetLength(State.Pending, 0);
  end
  else
  begin
    SetLength(State.Pending, Len - Pos);
    if Len - Pos > 0 then
      Move(Buf[Pos], State.Pending[0], Len - Pos);
  end;
end;

procedure MFlushPendingEscape(var State: TMInputParseState; var Events: TMInputEventArray);
begin
  if (Length(State.Pending) = 1) and (State.Pending[0] = 27) then
    AppendEvent(Events, KeyEvent(mkEscape, []));
  SetLength(State.Pending, 0);
end;

end.
