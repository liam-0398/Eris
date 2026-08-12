unit DysTrackPane;

{ Right dock: numbered track slots. Stage 1 placeholder content only - no
  aengine link yet, so there is no real track list to show (that's
  stage 6/7). Ctrl+Enter (or right-click, the app-wide dropdown
  convention from tui.md) is wired to a stub so the convention is proven
  out even though there's nothing real to adjust yet. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Dialogs, MsgBox, DysWidgets;

const
  PlaceholderTrackCount = 8;

type
  PDysTrackListBox = ^TDysTrackListBox;
  TDysTrackListBox = object(TListBox)
    constructor Init(Bounds: TRect);
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PDysTrackPane = ^TDysTrackPane;
  TDysTrackPane = object(TDysPane)
    Listing: PDysTrackListBox;
    constructor InitPane(Bounds: TRect);
  end;

implementation

constructor TDysTrackListBox.Init(Bounds: TRect);
var
  Entries: PUnSortedStrCollection;
  I: Integer;
begin
  inherited Init(Bounds, 1, nil);
  Entries := New(PUnSortedStrCollection, Init(PlaceholderTrackCount, 4));
  for I := 1 to PlaceholderTrackCount do
    Entries^.Insert(NewStr(IntToStr(I)));
  NewList(Entries);
end;

procedure TDysTrackListBox.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if ((Event.What = evKeyDown) and (Event.KeyCode = kbCtrlEnter)) or
     ((Event.What = evMouseDown) and (Event.Buttons and mbRightButton <> 0))
  then
  begin
    MessageBox('Track ' + PString(List^.At(Focused))^ +
      ': mute / solo / volume popup is stage 7 - no engine link yet.',
      nil, mfInformation or mfOKButton);
    ClearEvent(Event);
  end;
end;

constructor TDysTrackPane.InitPane(Bounds: TRect);
var
  R: TRect;
begin
  inherited InitPane(Bounds, 'Tr');
  R := ContentRect;
  Listing := New(PDysTrackListBox, Init(R));
  Insert(Listing);
end;

end.
