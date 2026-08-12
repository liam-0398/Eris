program Dysnomia;

{ Dysnomia - the Free Vision frontend for Eris.

  Deliberately contains no LCL, no Lazarus, no widgetset. Built by
  build-dysnomia.sh (native) and build-dysnomia-ppc.sh (powerpc-darwin)
  with plain fpc. If an LCL unit ever creeps into the uses graph the build
  fails with "Can't find unit Forms" - that failure is the guard rail,
  keep it. }

{$mode objfpc}{$H+}

uses
  DysnomiaApp;

var
  Moon: TDysnomiaApp;

begin
  Moon.Init;
  Moon.Run;
  Moon.Done;
end.
