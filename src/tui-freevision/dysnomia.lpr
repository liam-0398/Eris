program Dysnomia;

{ Dysnomia - the Free Vision frontend for Eris.

  Deliberately contains no LCL, no Lazarus, no widgetset. Built by
  build-dysnomia.sh (native) and build-dysnomia-ppc.sh (powerpc-darwin)
  with plain fpc. If an LCL unit ever creeps into the uses graph the build
  fails with "Can't find unit Forms" - that failure is the guard rail,
  keep it.

  Launcher-first boot (tui.md): shows DysLauncher's DAW/Control Station/
  Tracker choice, then Init/Run/Done's whichever one was picked - one
  process either way, same as before the launcher existed for the DAW
  path. Cancelling the launcher (Esc/Cancel) just exits. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  DysLauncher, DysnomiaApp, DysControlStationApp, DysTrackerApp;

var
  Moon: TDysnomiaApp;

begin
  case RunDysLauncher of
    dlcDAW:
      begin
        Moon.Init;
        Moon.Run;
        Moon.Done;
      end;
    dlcControlStation:
      RunDysControlStation;
    dlcTracker:
      RunDysTracker;
  end;
end.
