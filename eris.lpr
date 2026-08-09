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
  Forms, MainForm
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
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.

