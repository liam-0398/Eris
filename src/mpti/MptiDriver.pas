{
  Terminal I/O driver (mpti.md #5, #6, #10, req. 6/7/8). Raw-mode
  termios, a select()-driven read loop over BaseUnix/Termio (the only
  RTL units used here - still no FV, no rtl-console decoding, no
  ncurses/terminfo, per hard requirement 9), and SIGWINCH delivered
  through a self-pipe into that same loop rather than touching shared
  state from inside a signal handler.

  This unit owns the live fd; MptiInput.pas does the actual byte
  decoding and is what stays headless-testable. Nothing here is
  exercised by the automated mptidemo checks (there is no real tty in
  that build/test environment) - MEnableRawMode/MRunOnce are only meant
  to be called once MDriverHasTTY confirms stdin is actually a
  terminal; the headless driver (Phase 4) is the substitute when it
  isn't.
}
unit MptiDriver;

{$mode objfpc}{$H+}

interface

uses
  BaseUnix, Termio, MptiTypes, MptiInput, MptiCaps;

const
  { How long to wait after a lone/incomplete escape sequence before
    concluding no more bytes are coming and resolving it (mpti.md's
    "no kbCtrlEnter a driver can never produce" spirit applies here
    too: don't leave an ambiguous ESC sitting unresolved forever). }
  MEscapeAmbiguityMs = 50;

type
  TMDriverState = record
    Fd: cint;
    OutFd: cint;
    SavedTermios: Termios;
    RawModeActive: Boolean;
    WinchReadFd, WinchWriteFd: cint;
    WinchInstalled: Boolean;
    ParseState: TMInputParseState;
    Caps: TMTermCaps;
    Cols, Rows: Integer;
  end;

  TMDriverEventKind = (dekInput, dekResize);

function MDriverHasTTY(const D: TMDriverState): Boolean;

procedure MInitDriver(out D: TMDriverState; InFd: cint = 0; OutFd: cint = 1);

procedure MEnableRawMode(var D: TMDriverState);
procedure MDisableRawMode(var D: TMDriverState);

{ Installs the SIGWINCH self-pipe handler. Safe to call even when D is
  not a real tty; MRunOnce simply never sees a resize in that case. }
procedure MInstallResizeHandler(var D: TMDriverState);
procedure MRemoveResizeHandler(var D: TMDriverState);

procedure MQueryWindowSize(const D: TMDriverState; out Cols, Rows: Integer);

{ Writes the mode-enable sequences (SGR mouse tracking, bracketed paste,
  focus events) appropriate to D.Caps, plus a DA1 probe query. Call once
  after MEnableRawMode. }
procedure MEnableTerminalModes(const D: TMDriverState);
{ Writes the matching disable sequences. Call before MDisableRawMode on
  shutdown so the terminal is left sane for whatever runs next in it. }
procedure MDisableTerminalModes(const D: TMDriverState);

{ Blocks (via select, up to TimeoutMs ms; -1 = forever) for the next
  chunk of input or a pending SIGWINCH. On a lone/incomplete escape
  sequence with nothing following, automatically shortens the wait to
  MEscapeAmbiguityMs and flushes it as a literal Escape keypress if
  still nothing arrives - callers never have to manage that timeout
  themselves. Returns False on a plain timeout with nothing to do;
  True otherwise, with Kind describing what happened (Events appended
  for dekInput, D.Cols/D.Rows updated for dekResize). }
function MRunOnce(var D: TMDriverState; TimeoutMs: Integer;
  var Events: TMInputEventArray; out Kind: TMDriverEventKind): Boolean;

implementation

var
  GWinchWriteFd: cint = -1;

procedure WinchSignalHandler(Sig: Longint); cdecl;
var
  B: Byte;
begin
  if GWinchWriteFd >= 0 then
  begin
    B := 1;
    FpWrite(GWinchWriteFd, B, 1);
  end;
end;

function MDriverHasTTY(const D: TMDriverState): Boolean;
begin
  Result := IsATTY(D.Fd) <> 0;
end;

procedure MInitDriver(out D: TMDriverState; InFd: cint; OutFd: cint);
begin
  FillChar(D, SizeOf(D), 0);
  D.Fd := InFd;
  D.OutFd := OutFd;
  D.RawModeActive := False;
  D.WinchReadFd := -1;
  D.WinchWriteFd := -1;
  D.WinchInstalled := False;
  MInitInputParseState(D.ParseState);
  D.Caps := MMinimalCaps;
  MQueryWindowSize(D, D.Cols, D.Rows);
end;

procedure MEnableRawMode(var D: TMDriverState);
var
  Raw: Termios;
begin
  if D.RawModeActive then Exit;
  if TCGetAttr(D.Fd, D.SavedTermios) <> 0 then Exit;
  Raw := D.SavedTermios;
  CFMakeRaw(Raw);
  { Non-blocking reads: readiness is already gated by select() in
    MRunOnce, so the read() call itself should never block. }
  Raw.c_cc[VMIN] := 0;
  Raw.c_cc[VTIME] := 0;
  if TCSetAttr(D.Fd, TCSANOW, Raw) = 0 then
    D.RawModeActive := True;
end;

procedure MDisableRawMode(var D: TMDriverState);
begin
  if not D.RawModeActive then Exit;
  TCSetAttr(D.Fd, TCSANOW, D.SavedTermios);
  D.RawModeActive := False;
end;

procedure MInstallResizeHandler(var D: TMDriverState);
var
  Fds: TFilDes;
  Flags: cint;
begin
  if D.WinchInstalled then Exit;
  if FpPipe(Fds) <> 0 then Exit;
  D.WinchReadFd := Fds[0];
  D.WinchWriteFd := Fds[1];

  { Both ends non-blocking: the read end because MRunOnce drains it
    opportunistically, the write end because the signal handler must
    never block (a full pipe just means a resize notification is
    already queued - dropping the extra write is fine). }
  Flags := FpFcntl(D.WinchReadFd, F_GetFl);
  FpFcntl(D.WinchReadFd, F_SetFl, Flags or O_NONBLOCK);
  Flags := FpFcntl(D.WinchWriteFd, F_GetFl);
  FpFcntl(D.WinchWriteFd, F_SetFl, Flags or O_NONBLOCK);

  GWinchWriteFd := D.WinchWriteFd;
  FpSignal(SIGWINCH, @WinchSignalHandler);
  D.WinchInstalled := True;
end;

procedure MRemoveResizeHandler(var D: TMDriverState);
begin
  if not D.WinchInstalled then Exit;
  FpSignal(SIGWINCH, SignalHandler(SIG_DFL));
  GWinchWriteFd := -1;
  FpClose(D.WinchReadFd);
  FpClose(D.WinchWriteFd);
  D.WinchReadFd := -1;
  D.WinchWriteFd := -1;
  D.WinchInstalled := False;
end;

procedure MQueryWindowSize(const D: TMDriverState; out Cols, Rows: Integer);
var
  WS: TWinSize;
begin
  Cols := 80;
  Rows := 24;
  if FpIOCtl(D.Fd, TIOCGWINSZ, @WS) = 0 then
  begin
    if WS.ws_col > 0 then Cols := WS.ws_col;
    if WS.ws_row > 0 then Rows := WS.ws_row;
  end;
end;

procedure WriteRaw(const D: TMDriverState; const S: string);
begin
  if Length(S) > 0 then
    FpWrite(D.OutFd, S[1], Length(S));
end;

procedure MEnableTerminalModes(const D: TMDriverState);
begin
  if D.Caps.MouseSGR1006 then
    WriteRaw(D, #27'[?1000h'#27'[?1006h'); { basic mouse tracking + SGR extension }
  if D.Caps.BracketedPaste then
    WriteRaw(D, #27'[?2004h');
  if D.Caps.FocusEvents then
    WriteRaw(D, #27'[?1004h');
  WriteRaw(D, #27'[c'); { DA1 probe; response arrives through the normal input stream }
end;

procedure MDisableTerminalModes(const D: TMDriverState);
begin
  if D.Caps.FocusEvents then
    WriteRaw(D, #27'[?1004l');
  if D.Caps.BracketedPaste then
    WriteRaw(D, #27'[?2004l');
  if D.Caps.MouseSGR1006 then
    WriteRaw(D, #27'[?1006l'#27'[?1000l');
end;

function MRunOnce(var D: TMDriverState; TimeoutMs: Integer;
  var Events: TMInputEventArray; out Kind: TMDriverEventKind): Boolean;
var
  RFds: TFDSet;
  MaxFd: cint;
  SelTimeout: cint;
  SelResult: cint;
  ReadBuf: array[0..4095] of Byte;
  NRead: cint;
  DrainBuf: array[0..63] of Byte;
  NewCols, NewRows: Integer;
begin
  Result := False;
  Kind := dekInput;

  SelTimeout := TimeoutMs;
  if (Length(D.ParseState.Pending) > 0) and
     ((TimeoutMs < 0) or (TimeoutMs > MEscapeAmbiguityMs)) then
    SelTimeout := MEscapeAmbiguityMs;

  fpFD_ZERO(RFds);
  fpFD_SET(D.Fd, RFds);
  MaxFd := D.Fd;
  if D.WinchInstalled then
  begin
    fpFD_SET(D.WinchReadFd, RFds);
    if D.WinchReadFd > MaxFd then MaxFd := D.WinchReadFd;
  end;

  SelResult := fpSelect(MaxFd + 1, @RFds, nil, nil, SelTimeout);
  if SelResult <= 0 then
  begin
    if Length(D.ParseState.Pending) > 0 then
    begin
      MFlushPendingEscape(D.ParseState, Events);
      Kind := dekInput;
      Exit(True);
    end;
    Exit(False);
  end;

  if D.WinchInstalled and (fpFD_ISSET(D.WinchReadFd, RFds) <> 0) then
  begin
    repeat
      NRead := FpRead(D.WinchReadFd, DrainBuf, SizeOf(DrainBuf));
    until NRead < SizeOf(DrainBuf);
    MQueryWindowSize(D, NewCols, NewRows);
    D.Cols := NewCols;
    D.Rows := NewRows;
    Kind := dekResize;
    Exit(True);
  end;

  if fpFD_ISSET(D.Fd, RFds) <> 0 then
  begin
    NRead := FpRead(D.Fd, ReadBuf, SizeOf(ReadBuf));
    if NRead > 0 then
    begin
      MFeedInput(D.ParseState, Slice(ReadBuf, NRead), Events);
      Kind := dekInput;
      Exit(True);
    end;
  end;

  Exit(False);
end;

end.
