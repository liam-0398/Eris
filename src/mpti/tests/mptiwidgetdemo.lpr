{
  Manual visual demo for Phase 7's first widget (MptiWidgets.MButton).
  NOT part of the automated suite (run.sh) - it needs a real interactive
  tty and blocks waiting for input, which would just hang an automated
  run. Build and run this directly against a real terminal, e.g. via
  Claude Code's "!" prefix so it attaches to the actual session
  terminal rather than a captured/piped subprocess.

  Click the button with the mouse, or Tab... actually there's only one
  widget, so it starts unfocused - click it once to focus, or just
  click it (that's both focus and activation in one, per MPTI's
  click-to-focus-also-acts default). Once focused, Enter or Space also
  activates it. q or Esc quits.
}
program mptiwidgetdemo;

{$mode objfpc}{$H+}

uses
  BaseUnix, SysUtils, MptiTypes, MptiCell, MptiCaps, MptiInput, MptiDriver,
  MptiRender, MptiCore, MptiLayout, MptiWidgets;

procedure DrawText(var Buf: TCellBuffer; X, Y: Integer; const S: string);
var
  I, CX, W: Integer;
begin
  CX := X;
  for I := 1 to Length(S) do
  begin
    W := MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX, Y,
      Ord(S[I]), MDefaultFg, MDefaultBg, []);
    Inc(CX, W);
  end;
end;

var
  D: TMDriverState;
  RState: TMRenderState;
  Core: TMCoreState;
  HR: TMHitRegistry;
  Events: TMInputEventArray;
  Kind: TMDriverEventKind;
  Output: TMByteBuf;
  Quit: Boolean;
  Clicks: Integer;
  PaneID: TMWidgetID;
  I: Integer;
begin
  MInitDriver(D);
  if not MDriverHasTTY(D) then
  begin
    WriteLn('mptiwidgetdemo needs a real terminal - run it directly (e.g. via the "!" prefix), not through a captured/piped shell.');
    Halt(1);
  end;

  D.Caps := MCapsFromEnv(GetEnvironmentVariable('TERM'), GetEnvironmentVariable('COLORTERM'));
  MEnableRawMode(D);
  MInstallResizeHandler(D);
  MEnableTerminalModes(D);

  MInitRenderState(RState, D.Caps, D.Cols, D.Rows);
  MInitCore(Core);
  PaneID := MWidgetID('demo/main');
  Clicks := 0;
  Quit := False;

  while not Quit do
  begin
    SetLength(Events, 0);
    if MRunOnce(D, 200, Events, Kind) then
    begin
      if Kind = dekResize then
        MResizeRenderState(RState, D.Cols, D.Rows)
      else
        for I := 0 to High(Events) do
          if (Events[I].Kind = mekKey) and
             ((Events[I].Key.Code = mkEscape)
              or ((Events[I].Key.Code = mkChar) and (Events[I].Key.CodePoint = Ord('q')))) then
            Quit := True;
    end;

    MClearCellBuffer(RState.Back, MBlankCell);
    MBeginCoreFrame(Core);
    MBeginHitRegistry(HR);

    DrawText(RState.Back, 2, 1, 'MPTI Phase 7 minimal widget demo');
    DrawText(RState.Back, 2, 2, 'Click the button (or focus it and press Enter/Space). q or Esc quits.');

    if MButton(Core, HR, RState.Back, 'demo/button', PaneID, 2, 4, 'Click Me', Events) then
      Inc(Clicks);

    DrawText(RState.Back, 2, 6, 'Clicked ' + IntToStr(Clicks) + ' time(s).');

    MRenderDiff(RState, Output);
    if Output.Len > 0 then
      FpWrite(D.OutFd, Output.Data[0], Output.Len);
  end;

  MDisableTerminalModes(D);
  MRemoveResizeHandler(D);
  MDisableRawMode(D);
  WriteLn;
  WriteLn('mptiwidgetdemo: goodbye - button was clicked ', Clicks, ' time(s).');
end.
