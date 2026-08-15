program Dysnomia;

{ Dysnomia - the Free Vision frontend for Eris.

  Deliberately contains no LCL, no Lazarus, no widgetset. Built by
  build-dysnomia.sh (native) and build-dysnomia-ppc.sh (powerpc-darwin)
  with plain fpc. If an LCL unit ever creeps into the uses graph the build
  fails with "Can't find unit Forms" - that failure is the guard rail,
  keep it.

  No interactive launcher screen (removed per user request - the DAW/
  Control Station/Tracker picker used to be DysLauncher's job). Boots
  straight into the MPTI DAW by default; Control Station and Tracker
  (both still Free Vision, untouched) are reachable with a command-line
  argument instead of a selection screen. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, DysMptiApp, DysControlStationApp, DysTrackerApp;

var
  Mode: string;
begin
  Mode := '';
  if ParamCount >= 1 then
    Mode := LowerCase(ParamStr(1));
  if (Mode = 'control-station') or (Mode = 'controlstation') then
    RunDysControlStation
  else if Mode = 'tracker' then
    RunDysTracker
  else
    RunDysnomiaMpti;
end.
