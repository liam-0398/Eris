unit DysWidgets;

{ Stage 1 shell widgets: a fixed (non-draggable, non-closable) docked pane
  built on TWindow so border/title drawing reuses the framework's own
  tested TFrame code, and the transport bar / bottom bar for the rows
  above and below the desktop. Nothing here calls into aengine, abackend
  or project - local UI state only, per tui.md stage 1. }

{$mode objfpc}{$H+}

interface

uses
  Objects, Drivers, Views, Dialogs, MsgBox;

const
  cmToggleMetronome = 2001;
  cmTransportStop   = 2002;
  cmTransportPlay   = 2003;
  cmTransportRecord = 2004;
  cmCycleInterval   = 2005;
  cmDropdownStub    = 2006;

type
  { A docked, fixed pane: border and title only, no move/grow/close.

    GetPalette returns CGrayDialog rather than TWindow's own (8-entry)
    window palette: a TListBox's palette (CListViewer, Views.pas) indexes
    up to 29, which is out of range for an 8-entry window palette and
    falls back to Drivers.ErrorAttr ($CF - blink, red background). That
    was the "red and blinking" pane. CGrayDialog is 32 entries, the size
    Free Vision's own dialogs use precisely because they host controls
    like list boxes - this is the framework's own fix for this, not a
    workaround. TDysnomiaApp.GetPalette recolors that block to black on
    white; see its comment for why "dark grey" isn't literally possible. }
  PDysPane = ^TDysPane;
  TDysPane = object(TWindow)
    Focusable: PView; { the pane's own interactive child, if it has one }
    constructor InitPane(Bounds: TRect; const ATitle: string);
    function ContentRect: TRect;
    function GetPalette: PPalette; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure FocusPane;
  end;

  PDysToolBar = ^TDysToolBar;
  TDysToolBar = object(TGroup)
    Tempo: PInputLine;
    MetronomeBtn, StopBtn, PlayBtn, RecordBtn, IntervalBtn: PButton;
    MetronomeOn, Playing, Recording: Boolean;
    IntervalIdx: Integer;
    constructor Init(Bounds: TRect);
    procedure HandleEvent(var Event: TEvent); virtual;
  private
    procedure SetTitle(B: PButton; const S: string);
    procedure UpdateButtons;
  end;

  PDysBottomBar = ^TDysBottomBar;
  TDysBottomBar = object(TView)
    constructor Init(Bounds: TRect);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

const
  IntervalNames: array[0..3] of string = ('1/4', '1/8', '1/16', '1bar');

implementation

{ TDysPane }

constructor TDysPane.InitPane(Bounds: TRect; const ATitle: string);
begin
  inherited Init(Bounds, ATitle, wnNoNumber);
  Flags := 0;      { no move, grow or close - this is a dock, not a window }
  GrowMode := 0;   { the app repositions panes itself on layout, not FV }
  Focusable := nil;
end;

function TDysPane.ContentRect: TRect;
begin
  GetExtent(Result);
  Result.Grow(-1, -1);
end;

function TDysPane.GetPalette: PPalette;
const
  P: string[Length(CGrayDialog)] = CGrayDialog;
begin
  GetPalette := @P;
end;

procedure TDysPane.FocusPane;
begin
  if Focusable <> nil then
    Focusable^.Focus
  else
    Self.Focus;
end;

{ Tab/Shift+Tab cycle between docked panes (see Bindings in tui.md)
  instead of Free Vision's own TWindow.HandleEvent, which would just
  cycle focus among this one pane's own children - there's only one, so
  by default Tab does nothing visible at all. Intercepting before
  "inherited" means our single child never gets a chance to eat the key
  first. }
procedure TDysPane.HandleEvent(var Event: TEvent);
begin
  if (Event.What = evKeyDown) and
     ((Event.KeyCode = kbTab) or (Event.KeyCode = kbShiftTab)) and
     (Owner <> nil) then
  begin
    { TGroup.FindNext/SetCurrent are private to Views.pas, so this goes
      through the two public calls instead: SelectNext moves the desktop's
      Current to the next pane, then FocusPane on that pane re-walks the
      chain down into its own listbox (SelectNext alone only sets
      Owner.Current, it does not touch the target pane's own Current). }
    Owner^.SelectNext(Event.KeyCode = kbTab);
    if (Owner^.Current <> nil) and (Owner^.Current <> @Self) then
      PDysPane(Owner^.Current)^.FocusPane;
    ClearEvent(Event);
    Exit;
  end;
  inherited HandleEvent(Event);
end;

{ TDysToolBar }

{ Child Bounds here are local to the toolbar's own origin (row 0, since
  the bar is 1 row tall), not Bounds (which is this view's position in
  its OWNER's frame - see "Coordinates are owner-local" in tui.md). Using
  Bounds.A.Y instead of 0 was the original bug: every child ended up
  placed one row below the toolbar's own 1-row-tall visible area, so
  nothing in it was ever actually on screen. }
constructor TDysToolBar.Init(Bounds: TRect);
var
  R: TRect;
  X: Integer;
  TempoDefault: string[6];
begin
  inherited Init(Bounds);
  GrowMode := 0;
  X := 1;

  R.Assign(X, 0, X + 6, 1);
  Insert(New(PStaticText, Init(R, 'Tempo:')));
  X := X + 7;

  R.Assign(X, 0, X + 6, 1);
  Tempo := New(PInputLine, Init(R, 6));
  TempoDefault := '120.0';
  Tempo^.SetData(TempoDefault);
  Insert(Tempo);
  X := X + 7;

  R.Assign(X, 0, X + 3, 1);
  MetronomeBtn := New(PButton, Init(R, 'M', cmToggleMetronome, bfBroadcast));
  Insert(MetronomeBtn);
  X := X + 4;

  R.Assign(X, 0, X + 6, 1);
  StopBtn := New(PButton, Init(R, 'Stop', cmTransportStop, bfBroadcast));
  Insert(StopBtn);
  X := X + 7;

  R.Assign(X, 0, X + 6, 1);
  PlayBtn := New(PButton, Init(R, 'Play', cmTransportPlay, bfBroadcast));
  Insert(PlayBtn);
  X := X + 7;

  R.Assign(X, 0, X + 5, 1);
  RecordBtn := New(PButton, Init(R, 'Rec', cmTransportRecord, bfBroadcast));
  Insert(RecordBtn);
  X := X + 6;

  IntervalIdx := 0;
  R.Assign(X, 0, X + 6, 1);
  IntervalBtn := New(PButton, Init(R, IntervalNames[0], cmCycleInterval,
    bfBroadcast));
  Insert(IntervalBtn);
end;

procedure TDysToolBar.SetTitle(B: PButton; const S: string);
begin
  if B^.Title <> nil then
    DisposeStr(B^.Title);
  B^.Title := NewStr(S);
  B^.DrawView;
end;

procedure TDysToolBar.UpdateButtons;
begin
  SetTitle(MetronomeBtn, 'M');
  MetronomeBtn^.SetState(sfSelected, MetronomeOn);
  if Playing then
    SetTitle(PlayBtn, 'Pause')
  else
    SetTitle(PlayBtn, 'Play');
  RecordBtn^.SetState(sfSelected, Recording);
  RecordBtn^.DrawView;
  SetTitle(IntervalBtn, IntervalNames[IntervalIdx]);
end;

procedure TDysToolBar.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if Event.What = evCommand then
  begin
    case Event.Command of
      cmToggleMetronome:
        begin
          MetronomeOn := not MetronomeOn;
          UpdateButtons;
        end;
      cmTransportStop:
        begin
          Playing := False;
          Recording := False;
          UpdateButtons;
        end;
      cmTransportPlay:
        begin
          Playing := not Playing;
          UpdateButtons;
        end;
      cmTransportRecord:
        begin
          Recording := not Recording;
          UpdateButtons;
        end;
      cmCycleInterval:
        begin
          IntervalIdx := (IntervalIdx + 1) mod Length(IntervalNames);
          UpdateButtons;
        end;
    else
      Exit;
    end;
    ClearEvent(Event);
  end;
end;

{ TDysBottomBar }

constructor TDysBottomBar.Init(Bounds: TRect);
begin
  inherited Init(Bounds);
  GrowMode := 0;
  EventMask := EventMask or evMouseDown or evKeyDown;
end;

procedure TDysBottomBar.Draw;
var
  B: TDrawBuffer;
  C: Word;
  S: string;
begin
  C := GetColor(1);
  MoveChar(B, ' ', C, Size.X);
  S := ' effects: (none yet - Ctrl+Enter or right-click to add) ';
  MoveStr(B, S, C);
  WriteLine(0, 0, Size.X, 1, B);
end;

procedure TDysBottomBar.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if ((Event.What = evKeyDown) and (Event.KeyCode = kbCtrlEnter)) or
     ((Event.What = evMouseDown) and (Event.Buttons and mbRightButton <> 0))
  then
  begin
    MessageBox('Effects rack dropdown is stage 7 - not wired yet.', nil,
      mfInformation or mfOKButton);
    ClearEvent(Event);
  end;
end;

end.
