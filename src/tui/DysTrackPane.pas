unit DysTrackPane;

{ Right dock: numbered track slots. Still placeholder-count (8) rows rather
  than Project.TrackCount ones - reconciling the two is stage 8. Ctrl+Enter
  (or right-click, the app-wide dropdown convention from tui.md) is wired
  to a stub so the convention is proven out even though there's nothing
  real to adjust yet.

  What IS real as of stage 7: SelectedTrackIndex, below, is how DysFilePane
  finds "the track under the cursor" (see tui.md's Bindings table) when a
  file gets loaded - the file pane has no track concept of its own. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Dialogs, MsgBox, DysWidgets, Project;

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

{ Set once, by TDysTrackPane.InitPane - there is exactly one track pane in
  this single-window app. }
var
  ActiveTrackPane: PDysTrackPane = nil;

{ 0-based, clamped to Project.TrackCount - 1: the list box shows
  PlaceholderTrackCount (8) rows regardless of how many tracks the project
  actually has, so a focused row past the real track count would otherwise
  hand DysFilePane an out-of-range Project.Tracks index. }
function SelectedTrackIndex: Integer;

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
      ': mute / solo / volume popup is stage 8 - not wired yet.',
      nil, mfInformation or mfOKButton);
    ClearEvent(Event);
  end;
end;

function SelectedTrackIndex: Integer;
begin
  Result := 0;
  if ActiveTrackPane = nil then
    Exit;
  Result := ActiveTrackPane^.Listing^.Focused;
  if Result > Project.TrackCount - 1 then
    Result := Project.TrackCount - 1;
  if Result < 0 then
    Result := 0;
end;

constructor TDysTrackPane.InitPane(Bounds: TRect);
var
  R: TRect;
begin
  inherited InitPane(Bounds, 'Tr');
  R := ContentRect;
  Listing := New(PDysTrackListBox, Init(R));
  Insert(Listing);
  Focusable := Listing;
  ActiveTrackPane := @Self;
end;

end.
