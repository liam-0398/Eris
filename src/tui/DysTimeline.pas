unit DysTimeline;

{ Center pane. Stage 1 is a placeholder box only - the timeline itself,
  drag mode, and the copy/paste/duplicate/consolidate keys are stage 7,
  once aengine/project are linked and there is real clip data to draw.
  Ctrl+S (drag mode) is wired to a stub here so the binding is proven out
  the same way Ctrl+Enter is elsewhere - see Bindings in tui.md. }

{$mode objfpc}{$H+}

interface

uses
  Objects, Drivers, Views, Dialogs, MsgBox, DysWidgets;

type
  PDysTimeline = ^TDysTimeline;
  TDysTimeline = object(TDysPane)
    constructor InitPane(Bounds: TRect);
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

implementation

constructor TDysTimeline.InitPane(Bounds: TRect);
var
  R: TRect;
begin
  inherited InitPane(Bounds, 'Timeline');
  R := ContentRect;
  Insert(New(PStaticText, Init(R, '(no project loaded - stage 5)')));
end;

procedure TDysTimeline.HandleEvent(var Event: TEvent);
begin
  if (Event.What = evKeyDown) and (Event.KeyCode = kbCtrlS) then
  begin
    MessageBox('Drag mode is stage 7 - no clip data to drag yet.', nil,
      mfInformation or mfOKButton);
    ClearEvent(Event);
    Exit;
  end;
  inherited HandleEvent(Event);
end;

end.
