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
    TrackMute: array[0..PlaceholderTrackCount] of Boolean;
    TrackSolo: array[0..PlaceholderTrackCount] of Boolean;
    constructor Init(Bounds: TRect);
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure Draw; virtual;
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

{ 0-based, clamped to Project.TrackCount - 1: the list box shows one blank
  row (aligns row 1 of the list with row 1 of the timeline grid, whose row 0
  is the seconds ruler - see DysTimeline.Draw) followed by PlaceholderTrackCount
  (8) numbered rows regardless of how many tracks the project actually has,
  so a focused row past the real track count - or the blank row itself -
  would otherwise hand DysFilePane an out-of-range Project.Tracks index. }
function SelectedTrackIndex: Integer;

implementation

procedure TDysTrackListBox.Draw;
var
  Item: Integer;
  Y: Integer;
  Attr: Byte;
  Text: String;
  B: TDrawBuffer;
  NormalAttr: Byte = $0F;     { black bg, bright white fg }
  SelectedAttr: Byte = $70;   { light grey bg, black fg }
  MutedAttr: Byte = $04;      { black bg, dark red fg }
  SoloAttr: Byte = $06;       { black bg, brown/yellow fg }
begin
  { Custom rendering without calling inherited Draw, to avoid palette/blink issues }
  for Item := 0 to Range - 1 do
  begin
    Y := Item - TopItem;
    if (Y < 0) or (Y >= Size.Y) then
      Continue;

    { Clear line and set base attribute }
    if Item = Focused then
      MoveChar(B, ' ', SelectedAttr, Size.X)
    else
      MoveChar(B, ' ', NormalAttr, Size.X);

    Text := PString(List^.At(Item))^;
    if Text <> '' then
    begin
      { Determine color for non-blank items }
      if Item = Focused then
        Attr := SelectedAttr { selection overrides mute/solo color }
      else if Item > 0 then { skip blank row 0 }
      begin
        if TrackMute[Item] then
          Attr := MutedAttr
        else if TrackSolo[Item] then
          Attr := SoloAttr
        else
          Attr := NormalAttr;
      end
      else
        Attr := NormalAttr;

      MoveStr(B, Text, Attr);
    end;

    WriteLine(0, Y, Size.X, 1, B);
  end;
end;

constructor TDysTrackListBox.Init(Bounds: TRect);
var
  Entries: PUnSortedStrCollection;
  I: Integer;
begin
  inherited Init(Bounds, 1, nil);
  for I := 0 to PlaceholderTrackCount do
  begin
    TrackMute[I] := False;
    TrackSolo[I] := False;
  end;
  Entries := New(PUnSortedStrCollection, Init(PlaceholderTrackCount + 1, 4));
  Entries^.Insert(NewStr(''));
  for I := 1 to PlaceholderTrackCount do
    Entries^.Insert(NewStr(IntToStr(I)));
  NewList(Entries);
end;

procedure TDysTrackListBox.HandleEvent(var Event: TEvent);
var
  TrackIdx: Integer;
begin
  inherited HandleEvent(Event);

  { Handle mute (m) and solo (s) key presses on tracks 1-8 }
  if (Event.What = evKeyDown) and (Focused > 0) then
  begin
    TrackIdx := Focused;
    case Char(Event.CharCode) of
      'm', 'M':
      begin
        TrackMute[TrackIdx] := not TrackMute[TrackIdx];
        if TrackIdx <= Project.TrackCount then
          Project.TrackSolo[TrackIdx - 1] := False; { clear solo when muting }
        DrawView;
        ClearEvent(Event);
      end;
      's', 'S':
      begin
        TrackSolo[TrackIdx] := not TrackSolo[TrackIdx];
        if TrackIdx <= Project.TrackCount then
          Project.TrackSolo[TrackIdx - 1] := TrackSolo[TrackIdx];
        if TrackSolo[TrackIdx] then
          TrackMute[TrackIdx] := False; { clear mute when soloing }
        DrawView;
        ClearEvent(Event);
      end;
    end;
  end;

  if ((Event.What = evKeyDown) and
      ((Event.KeyCode = kbCtrlEnter) or (Event.KeyCode = kbDropdownKey))) or
     ((Event.What = evMouseDown) and (Event.Buttons and mbActualRightButton <> 0))
  then
  begin
    if Focused > 0 then
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
  { -1: row 0 is the blank alignment row, not track 1 - see the comment
    above. Focused = 0 clamps to track index 0 same as any other
    out-of-range row, it just isn't allowed to read as "track 1 selected". }
  Result := ActiveTrackPane^.Listing^.Focused - 1;
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
  { Start cursor at track 1 instead of blank row 0 }
  Listing^.FocusItem(1);
  ActiveTrackPane := @Self;
end;

end.
