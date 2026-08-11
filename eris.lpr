program eris;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, Config, Theme, MainForm
  { you can add units after this };

{$R *.res}

begin
  RequireDerivedFormResource:=True;
  { Every widget is hand-positioned via UIScale.Px() - the LCL's own automatic
    DPI auto-scaling (which guesses a "design PPI" baked in at build time) has
    no .lfm-based baseline to compare against for these code-only forms, and
    was found stacking an extra unwanted scale factor on top of Px(). }
  Application.Scaled:=False;
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar:=True;
  {$POP}
  Application.Initialize;
  { Before the form exists, because creating it runs AudioEngineInit (see
    MainForm) and that reads Cfg to decide which backend to open and at what
    buffer size. Loading afterwards and applying would mean every launch
    opened the default device only to immediately stop and reopen the
    configured one - an audible glitch and a device cycle for nothing. }
  ConfigLoad;
  { Straight after the load and still before the form exists, so every control
    is built with its final colours rather than created light and repainted.
    Nothing selects a mode yet - this is ThemeSystem, i.e. passthrough to the
    real LCL system colours - until Preferences gains the dropdown. }
  ThemeSetMode(Cfg.Theme);
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.

