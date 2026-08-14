unit DysTrackPane;

{ Right dock: numbered track slots. Still placeholder-count (8) rows rather
  than Project.TrackCount ones - reconciling the two is stage 8. Ctrl+Enter
  (or right-click, the app-wide dropdown convention from tui.md) is wired
  to a stub so the convention is proven out even though there's nothing
  real to adjust yet.

  What IS real as of stage 7: SelectedTrackIndex, below, is how DysFilePane
  finds "the track under the cursor" (see tui.md's Bindings table) when a
  file gets loaded - the file pane has no track concept of its own.

  Hand-rolled TView, not TListBox (which this used to be): once the
  timeline grid grew a toggleable TrackHeight (see DysTimeline.pas/
  DysWidgets.pas), the row a track's number sits on stopped being "the
  track index" and became TrackTopRow(track) - a formula that also governs
  vertical scroll (ViewStartTrack). TListBox's Focused/TopItem model is one
  list item per row; keeping the pane's numbers aligned with the grid's
  blocks under that model would mean padding the item list with blank
  filler rows and intercepting every navigation key to skip them, i.e.
  reimplementing this same row math a second time inside TListBox's frame
  and hoping the two never drift apart. Building straight on TView instead
  - same MoveChar/WriteLine, raw-attribute-byte approach DysTimeline's own
  grid uses (see that unit and fvdoc.md's "Palette cascade" note on why
  WriteChar/WriteStr are avoided) - means this pane reads TrackTopRow/
  TrackHeight/ViewStartTrack directly from DysWidgets, the same values the
  grid itself draws from, so alignment holds by construction instead of by
  two implementations being kept in lockstep by hand. Per the "scroll only
  ever happens from the timeline" decision, this pane never changes
  ViewStartTrack itself - it only ever redraws against whatever DysTimeline
  last set it to (see EnsureTrackVisible/ScrollTracksBy there). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Dialogs, MsgBox, DysWidgets, Project;

const
  PlaceholderTrackCount = 8;

type
  PDysTrackListing = ^TDysTrackListing;
  TDysTrackListing = object(TView)
    SelectedTrack: Integer; { 0-based - Project.Tracks index directly, no
                               blank-row offset to correct for anymore }
    TrackMute: array[0..PlaceholderTrackCount - 1] of Boolean;
    TrackSolo: array[0..PlaceholderTrackCount - 1] of Boolean;
    constructor Init(Bounds: TRect);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PDysTrackPane = ^TDysTrackPane;
  TDysTrackPane = object(TDysPane)
    Listing: PDysTrackListing;
    constructor InitPane(Bounds: TRect);
  end;

{ Set once, by TDysTrackPane.InitPane - there is exactly one track pane in
  this single-window app. }
var
  ActiveTrackPane: PDysTrackPane = nil;

{ 0-based, clamped to Project.TrackCount - 1. }
function SelectedTrackIndex: Integer;

implementation

const
  { Same literal bytes as DysTimeline's own NormalAttr/CursorAttr - kept as
    a separate copy rather than a cross-unit reference (DysTimeline already
    `uses DysTrackPane`, so the reverse would be circular), same convention
    DysEffectsRack's own PlayheadAttr duplicate already follows. }
  NormalAttr = $0F; { black bg, bright white fg }
  CursorAttr = $70; { light grey bg, black fg - selected track }
  MuteAttr   = $04; { black bg, dark red fg }
  SoloAttr   = $06; { black bg, brown/yellow fg }

constructor TDysTrackListing.Init(Bounds: TRect);
var
  I: Integer;
begin
  inherited Init(Bounds);
  GrowMode := 0;
  EventMask := EventMask or evMouseDown or evKeyDown;
  { ofSelectable/ofFirstClick - see DysTimeline.TDysTimelineContent.Init's
    own comment on why a hand-rolled TView needs these set explicitly. }
  Options := Options or (ofSelectable + ofFirstClick);
  SelectedTrack := 0;
  for I := 0 to PlaceholderTrackCount - 1 do
  begin
    TrackMute[I] := False;
    TrackSolo[I] := False;
  end;
end;

{ Row 0 is always the blank row that aligns with the timeline grid's own
  ruler row (TrackTopRow(ViewStartTrack) = 1, never 0 - see DysWidgets.pas);
  every track after that occupies TrackHeight rows starting at
  TrackTopRow(track), the exact formula the grid itself uses. Only the
  block's top row carries the track number - the rest render blank, same
  "number lines up with the top of its block" layout the grid's own A/I/S
  label column follows for a tall track. }
procedure TDysTrackListing.Draw;
var
  B: TDrawBuffer;
  Track, Y, SubRow: Integer;
  NumStr: string;
  Attr: Word;
begin
  MoveChar(B, ' ', NormalAttr, Size.X);
  WriteLine(0, 0, Size.X, 1, B);

  for Track := ViewStartTrack to Project.TrackCount - 1 do
  begin
    Y := TrackTopRow(Track);
    if Y >= Size.Y then
      Break;

    for SubRow := 0 to TrackHeight - 1 do
    begin
      if Y + SubRow >= Size.Y then
        Break;

      if Track = SelectedTrack then
        MoveChar(B, ' ', CursorAttr, Size.X)
      else
        MoveChar(B, ' ', NormalAttr, Size.X);

      if SubRow = 0 then
      begin
        NumStr := IntToStr(Track + 1);
        if Track = SelectedTrack then
          Attr := CursorAttr
        else if (Track < PlaceholderTrackCount) and TrackMute[Track] then
          Attr := MuteAttr
        else if (Track < PlaceholderTrackCount) and TrackSolo[Track] then
          Attr := SoloAttr
        else
          Attr := NormalAttr;
        MoveStr(B, NumStr, Attr);
      end;

      WriteLine(0, Y + SubRow, Size.X, 1, B);
    end;
  end;
end;

procedure TDysTrackListing.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);

  if Event.What = evKeyDown then
  begin
    case Event.KeyCode of
      kbUp:
        begin
          if SelectedTrack > 0 then
            Dec(SelectedTrack);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbDown:
        begin
          if SelectedTrack < Project.TrackCount - 1 then
            Inc(SelectedTrack);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
    end;

    { Handle mute (m) and solo (s) key presses on the selected track. Mute
      is display-only (never pushed to Project - stage 8, same as before
      this rewrite); solo mirrors into Project.TrackSolo so it actually
      gates playback (see Project.TrackAudible). }
    if SelectedTrack < PlaceholderTrackCount then
      case Char(Event.CharCode) of
        'm', 'M':
          begin
            TrackMute[SelectedTrack] := not TrackMute[SelectedTrack];
            if SelectedTrack < Project.TrackCount then
              Project.TrackSolo[SelectedTrack] := False;
            DrawView;
            ClearEvent(Event);
          end;
        's', 'S':
          begin
            TrackSolo[SelectedTrack] := not TrackSolo[SelectedTrack];
            if SelectedTrack < Project.TrackCount then
              Project.TrackSolo[SelectedTrack] := TrackSolo[SelectedTrack];
            if TrackSolo[SelectedTrack] then
              TrackMute[SelectedTrack] := False;
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
    MessageBox('Track ' + IntToStr(SelectedTrack + 1) +
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
  Result := ActiveTrackPane^.Listing^.SelectedTrack;
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
  Listing := New(PDysTrackListing, Init(R));
  Insert(Listing);
  Focusable := Listing;
  ActiveTrackPane := @Self;
end;

end.
