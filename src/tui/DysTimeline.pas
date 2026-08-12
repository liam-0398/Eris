unit DysTimeline;

{ Center pane. Stage 1 is a placeholder box only - the timeline itself,
  drag mode, and the copy/paste/duplicate/consolidate keys are stage 7,
  once aengine/project are linked and there is real clip data to draw.

  One thing worth flagging before stage 7: tui.md describes the drag
  trigger as "hitting ctrl-shift", but a bare modifier chord with no base
  key generates no keystroke at all over a raw terminal - Ctrl and Shift
  only show up in what they do to a key that's actually pressed (e.g.
  Ctrl+Shift+Right arrow is reportable, "Ctrl+Shift" by itself is not).
  So the real binding needs to be Ctrl+Shift+<something> - which key is a
  design choice, not implemented here. }

{$mode objfpc}{$H+}

interface

uses
  Objects, Drivers, Views, Dialogs, DysWidgets;

type
  PDysTimeline = ^TDysTimeline;
  TDysTimeline = object(TDysPane)
    constructor InitPane(Bounds: TRect);
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

end.
