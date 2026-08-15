unit DysControlStationApp;

{ Stub for the launcher's "Control Station" entry (tui.md's design-draft
  section) - the mixer/detail-view idea is parked there for later, not
  built this pass. This just proves the launcher's third choice reaches a
  real screen and returns cleanly to being re-launchable, same Init/Done
  shape every other launcher target uses. No socket connection attempted. }

{$mode objfpc}{$H+}

interface

uses
  App;

type
  TDysControlStationApp = object(TApplication)
  end;

procedure RunDysControlStation;

implementation

uses
  MsgBox, Dialogs;

procedure RunDysControlStation;
var
  StubApp: TDysControlStationApp;
begin
  StubApp.Init;
  MessageBox('Control Station - coming soon.' + #13#13 +
    'See tui.md''s design-draft section for the planned mixer/detail view.',
    nil, mfInformation or mfOKButton);
  StubApp.Done;
end;

end.
