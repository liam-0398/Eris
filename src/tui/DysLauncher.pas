unit DysLauncher;

{ The screen shown by ./dysnomia before any real app boots - a keyboard
  -selectable choice of DAW / Control Station / Tracker (tui.md's launcher
  section). Built the same TDialog/TRadioButtons way DysPreferences.pas's
  ShowPreferencesDialog already is: a TApplication of its own (it needs to
  own the screen init/teardown, same as TDysnomiaApp does), whose entire
  job is Init -> show one modal dialog via Desktop^.ExecView -> record the
  choice -> Done, never entering the normal event-loop Run at all - there's
  nothing else on this screen to pump events for. dysnomia.lpr runs this
  first, then Init/Run/Done's whichever real app the choice picked,
  sequentially, one process either way. }

{$mode objfpc}{$H+}

interface

uses
  App;

const
  dlcQuit = 0;
  dlcDAW = 1;
  dlcControlStation = 2;
  dlcTracker = 3;

type
  TDysLauncherApp = object(TApplication)
    Choice: Integer;
    constructor Init;
    procedure ShowChoiceDialog;
  end;

{ Runs the launcher screen (Init, show the dialog, Done) and returns which
  app dysnomia.lpr should start next - dlcQuit if the user cancelled/Esc'd
  out with nothing chosen. }
function RunDysLauncher: Integer;

implementation

uses
  Objects, Drivers, Views, Dialogs;

const
  DlgWidth = 40;
  DlgHeight = 12;

constructor TDysLauncherApp.Init;
begin
  inherited Init;
  Choice := dlcQuit;
end;

procedure TDysLauncherApp.ShowChoiceDialog;
var
  R: TRect;
  Dlg: PDialog;
  ChoiceRG: PRadioButtons;
  Res: Word;
begin
  R.Assign(0, 0, DlgWidth, DlgHeight);
  Dlg := New(PDialog, Init(R, 'Dysnomia'));

  R.Assign(2, 2, DlgWidth - 2, 6);
  ChoiceRG := New(PRadioButtons, Init(R,
    NewSItem('DAW', NewSItem('Control Station', NewSItem('Tracker', nil)))));
  ChoiceRG^.Value := 0;
  Dlg^.Insert(ChoiceRG);

  R.Assign(2, DlgHeight - 3, 14, DlgHeight - 1);
  Dlg^.Insert(New(PButton, Init(R, '~O~K', cmOK, bfDefault)));
  R.Assign(16, DlgHeight - 3, 28, DlgHeight - 1);
  Dlg^.Insert(New(PButton, Init(R, 'Cancel', cmCancel, bfNormal)));

  Dlg^.SelectNext(False);
  { Same ExecView/manual-Dispose pattern as DysPreferences.
    ShowPreferencesDialog - see that unit's own comment on why (TGroup.
    ExecView inserts/removes Dlg but never Disposes it). }
  Res := Desktop^.ExecView(Dlg);
  if Res = cmOK then
    case ChoiceRG^.Value of
      0: Choice := dlcDAW;
      1: Choice := dlcControlStation;
      2: Choice := dlcTracker;
    else
      Choice := dlcQuit;
    end
  else
    Choice := dlcQuit;
  Dispose(Dlg, Done);
end;

function RunDysLauncher: Integer;
var
  Launcher: TDysLauncherApp;
begin
  Launcher.Init;
  Launcher.ShowChoiceDialog;
  Result := Launcher.Choice;
  Launcher.Done;
end;

end.
