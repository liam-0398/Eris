{
  Live-tty exercise for MptiDriver: raw mode, SIGWINCH self-pipe,
  mode-enable/disable escape sequences, and MRunOnce's event decoding,
  all against a real fd - the parts of Phase 2 that MptiInput's pure
  unit tests (tests/mptidemo.lpr) cannot cover because they need an
  actual pty. Requires a controlling terminal (checks MDriverHasTTY and
  exits immediately if none - safe to invoke from a non-interactive
  shell by accident). Driven by drive_pty.py, which allocates a pty,
  injects known byte sequences and a resize, and asserts on the
  resulting stderr log - run that, not this binary directly.
}
program mptidrivertest;
{$mode objfpc}{$H+}
uses
  SysUtils, MptiDriver, MptiInput, MptiCaps;
var
  D: TMDriverState;
  Events: TMInputEventArray;
  Kind: TMDriverEventKind;
  I, N, Iterations: Integer;
  SawResize: Boolean;
begin
  MInitDriver(D);
  WriteLn(StdErr, 'hastty=', MDriverHasTTY(D));
  if not MDriverHasTTY(D) then
  begin
    WriteLn(StdErr, 'no tty, exiting');
    Halt(0);
  end;
  D.Caps := MCapsFromEnv(GetEnvironmentVariable('TERM'), GetEnvironmentVariable('COLORTERM'));
  MEnableRawMode(D);
  MInstallResizeHandler(D);
  MEnableTerminalModes(D);
  Iterations := 0;
  N := 0;
  SawResize := False;
  while Iterations < 30 do
  begin
    Inc(Iterations);
    SetLength(Events, 0);
    if MRunOnce(D, 300, Events, Kind) then
    begin
      if Kind = dekResize then
      begin
        WriteLn(StdErr, 'resize -> ', D.Cols, 'x', D.Rows);
        SawResize := True;
      end
      else
        for I := 0 to High(Events) do
        begin
          case Events[I].Kind of
            mekKey: WriteLn(StdErr, 'key code=', Ord(Events[I].Key.Code),
              ' cp=', Events[I].Key.CodePoint,
              ' ctrl=', kmCtrl in Events[I].Key.Mods,
              ' alt=', kmAlt in Events[I].Key.Mods,
              ' shift=', kmShift in Events[I].Key.Mods);
            mekMouse: WriteLn(StdErr, 'mouse btn=', Ord(Events[I].Mouse.Button),
              ' x=', Events[I].Mouse.X, ' y=', Events[I].Mouse.Y);
            mekPaste: WriteLn(StdErr, 'paste="', Events[I].PasteText, '"');
            mekFocusIn: WriteLn(StdErr, 'focus in');
            mekFocusOut: WriteLn(StdErr, 'focus out');
          end;
          Inc(N);
        end;
    end;
    if (N >= 3) and SawResize then Break;
  end;
  MDisableTerminalModes(D);
  MRemoveResizeHandler(D);
  MDisableRawMode(D);
  WriteLn(StdErr, 'done, events=', N);
end.
