program runtests;

{$mode objfpc}{$H+}

uses
  consoletestrunner, ClipOverwriteTests;

var
  App: TTestRunner;
begin
  App := TTestRunner.Create(nil);
  App.Initialize;
  App.Run;
  App.Free;
end.
