unit DysWidgets;

{ Stage 1 shell widgets: a fixed (non-draggable, non-closable) docked pane
  built on TWindow so border/title drawing reuses the framework's own
  tested TFrame code, and the transport bar / bottom bar for the rows
  above and below the desktop. Stage 7: Play/Stop on the transport bar
  call into AudioEngine for real (see TDysToolBar.HandleEvent) - metronome,
  record and the interval cycle button are still local UI state only,
  stage 8. }

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

  { Ctrl+Enter can never actually reach this app from a real terminal -
    Enter's byte is already CR ($0D), below $20, so Ctrl-masking (what
    makes every other Ctrl+<letter> chord here a genuinely distinct byte)
    changes nothing about it, and packages/rtl-console/src/unix/keyboard.pp's
    escape-sequence tree (what a Ctrl+<non-letter> chord would need to be
    reachable at all - same bug class as Ctrl+I/Shift+Enter/Ctrl+Shift+S,
    see tui.md's Bindings section) has no entry for it either. kbCtrlEnter
    is a real, distinct Drivers.pas KeyCode constant, but nothing in the
    Unix keyboard driver can ever produce it from a keypress. kbF2 is the
    concrete, reachable replacement - unclaimed elsewhere in this app. }
  kbDropdownKey = kbF2;

  { The bit an actual xterm/SGR1006 right-click sends, on this FPC RTL's
    Unix mouse driver (rtl-console/src/unix/keyboard.pp: GenMouseEvent /
    GenMouseEvent_ExtendedSGR1006, "buttonval and 67" case 2, "right button
    pressed") - it's bit value 4, which is Drivers.pas's own mbMiddleButton
    bit, not mbRightButton ($02 - actually the value a real middle-click
    sends there). Checking Drivers.mbRightButton for "was this a right-
    click" is why right-click never opened any dropdown in this app: a real
    right-click's byte never has that bit set. Same driver is used on
    Darwin (see fvdoc's "Source layout" note), so this isn't Linux-only. }
  mbActualRightButton = mbMiddleButton;

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
    procedure FocusPane; virtual;
  end;

  PDysToolBar = ^TDysToolBar;
  TDysToolBar = object(TGroup)
    Tempo: PInputLine;
    MetronomeBtn, StopBtn, PlayBtn, RecordBtn, IntervalBtn: PButton;
    MetronomeOn, Playing, Recording: Boolean;
    IntervalIdx: Integer;
    constructor Init(Bounds: TRect);
    procedure HandleEvent(var Event: TEvent); virtual;
    { Shared by the Play button's own cmTransportPlay case and the
      timeline's Space key (see DysTimeline.HandleEvent / tui.md's
      Bindings) - one implementation, same "Stop wins if already playing,
      else only start if there's a clip" rule either way gets there. }
    procedure TogglePlayPause;
    procedure CommitTempo;
    procedure SyncTempoDisplay;
    { Public so DysnomiaApp.RefreshAfterProjectChange can reset the Play/
      Pause label after forcing Playing := False on a project change - was
      private, no external caller needed it before that. }
    procedure UpdateButtons;
  private
    procedure SetTitle(B: PButton; const S: string);
  end;

  { Wraps TDysToolBar in a docked, titled, Tab-reachable pane - same
    border/focus machinery as the file/track/timeline docks (TDysPane),
    so the transport bar joins the same Tab/Shift+Tab cycle instead of
    living outside it. See tui.md's Layout/Bindings. }
  PDysToolBarPane = ^TDysToolBarPane;
  TDysToolBarPane = object(TDysPane)
    Bar: PDysToolBar;
    constructor InitPane(Bounds: TRect);
    procedure FocusPane; virtual;
  end;

const
  IntervalNames: array[0..3] of string = ('1/4', '1/8', '1/16', '1bar');

{ Set once, by TDysToolBar.Init - there is exactly one transport bar in
  this single-window app. DysTimeline reaches through this to run Space's
  play/pause (see tui.md's Bindings), the same "global points at the one
  instance" pattern ActiveTrackPane/ActiveTimelineContent already use. }
var
  ActiveToolBar: PDysToolBar = nil;

implementation

uses
  AudioEngine, Project;
{ Deliberately not SysUtils: it redeclares NewStr(Const S: String): PString
  with a PAnsiString-based PString, and since implementation uses always
  resolve after the interface's own Objects import, SysUtils being present
  anywhere in this unit's uses chain shadows Objects.NewStr - the very
  thing TDysToolBar.SetTitle, below, needs. }

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
begin
  inherited Init(Bounds);
  GrowMode := 0;
  X := 1;

  R.Assign(X, 0, X + 6, 1);
  Insert(New(PStaticText, Init(R, 'Tempo:')));
  X := X + 7;

  R.Assign(X, 0, X + 6, 1);
  Tempo := New(PInputLine, Init(R, 6));
  Insert(Tempo);
  X := X + 7;

  R.Assign(X, 0, X + 3, 1);
  MetronomeBtn := New(PButton, Init(R, 'M', cmToggleMetronome, bfNormal));
  Insert(MetronomeBtn);
  X := X + 4;

  R.Assign(X, 0, X + 6, 1);
  StopBtn := New(PButton, Init(R, 'Stop', cmTransportStop, bfNormal));
  Insert(StopBtn);
  X := X + 7;

  R.Assign(X, 0, X + 6, 1);
  PlayBtn := New(PButton, Init(R, 'Play', cmTransportPlay, bfNormal));
  Insert(PlayBtn);
  X := X + 7;

  R.Assign(X, 0, X + 5, 1);
  RecordBtn := New(PButton, Init(R, 'Rec', cmTransportRecord, bfNormal));
  Insert(RecordBtn);
  X := X + 6;

  IntervalIdx := 0;
  R.Assign(X, 0, X + 6, 1);
  IntervalBtn := New(PButton, Init(R, IntervalNames[0], cmCycleInterval,
    bfNormal));
  Insert(IntervalBtn);

  ActiveToolBar := @Self;
  { Was hardcoded to the text '120.0' regardless of Project.TempoBPM's own
    default (160.0, Project.DefaultTempoBPM) - the field never actually
    reflected the project's real tempo from the moment the app started,
    which is what made it look "garbage": editing it and hitting Enter
    (CommitTempo) worked, but the number shown before that had never once
    corresponded to anything real. SyncTempoDisplay is the read-direction
    counterpart to CommitTempo's write direction - see RefreshAfterProject
    Change (DysnomiaApp.pas) for the other place this needs to run, after
    a project load/New changes TempoBPM out from under this field. }
  SyncTempoDisplay;
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

{ Mirrors MainForm.PlayPauseClick: Stop wins if already playing, otherwise
  only start if there's actually a clip somewhere - see AudioEngineHasClip -
  so Play on an empty project does nothing rather than silently "playing"
  nothing. Factored out of the Play button's own cmTransportPlay case so
  the timeline's Space key (tui.md's Bindings) triggers the exact same
  logic and button-label update, via ActiveToolBar. }
procedure TDysToolBar.TogglePlayPause;
begin
  if AudioEngineIsPlaying then
  begin
    AudioEngineStop;
    Playing := False;
  end
  else if AudioEngineHasClip then
  begin
    AudioEnginePlay;
    Playing := True;
  end;
  UpdateButtons;
end;

{ Reads Tempo's text, clamps it the same way MainForm.TempoEditEditingDone
  does (src/ui, 20-999 BPM, garbage falls back to DefaultTempoBPM), writes
  it to Project.TempoBPM and reflects the clamped value back into the
  field. No SysUtils in this unit (see the top-of-implementation note) so
  parsing/formatting goes through Val/Str, not StrToInt/IntToStr. }
{ Writes Tempo^.Data^ directly rather than calling TInputLine.SetData -
  SetData's Rec parameter is untyped and it does a raw Move(Rec, Data^[0],
  DataSize) of exactly MaxLen+1 (7) bytes starting at Rec's own address,
  not a real string assignment. That's fine when Rec is itself a fixed
  string[6] (7 bytes, length byte + 6 chars - same layout Data^ has, which
  is how the original hardcoded '120.0' setup called it), but S here is a
  plain `string` - under this unit's long-string mode, that's AnsiString:
  an 8-byte heap pointer, not inline character data. SetData(S) would have copied
  the first 7 bytes of that POINTER's own bit pattern into Data^ as if
  they were a length byte plus six characters - garbage almost by
  definition, and exactly the "random foreign characters, uneditable"
  symptom this fixed. Data (PString = PShortString, Objects.pas) is a
  genuine ShortString pointer; Data^ := S does a real, correctly-sized
  AnsiString-to-ShortString conversion instead, safe here since Value is
  always <=3 digits, well under MaxLen (6). }
procedure TDysToolBar.CommitTempo;
var
  S: string;
  Parsed: Double;
  Value: LongInt;
  Code: Word;
begin
  S := Tempo^.Data^;
  Val(S, Parsed, Code);
  if Code <> 0 then
    Value := Round(Project.DefaultTempoBPM)
  else
    Value := Round(Parsed);
  if Value < 20 then
    Value := 20
  else if Value > 999 then
    Value := 999;
  Project.TempoBPM := Value;
  Str(Value, S);
  Tempo^.Data^ := S;
  Tempo^.DrawView;
end;

{ Read-direction counterpart to CommitTempo: pushes Project.TempoBPM's
  current value into the field, rather than reading the field into the
  project. Called once from Init (see its comment) and again from
  DysnomiaApp.RefreshAfterProjectChange whenever a project load/New
  changes TempoBPM without going through this field at all. }
procedure TDysToolBar.SyncTempoDisplay;
var
  S: string;
begin
  Str(Round(Project.TempoBPM), S);
  Tempo^.Data^ := S;
  if State and sfVisible <> 0 then
    Tempo^.DrawView;
end;

procedure TDysToolBar.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  { Tab/Shift+Tab is reserved app-wide for pane switching (see TDysPane),
    so moving between this pane's own widgets - Tempo, then the four
    buttons - uses Up/Down instead, same as any other in-pane cursor
    move; Enter/Space then activate whatever's focused via Free Vision's
    own default-button/press handling, no extra code needed for that
    part. Left/Right are deliberately left alone: Tempo is a text field
    and needs them for cursor movement within its own contents. }
  if (Event.What = evKeyDown) and
     ((Event.KeyCode = kbUp) or (Event.KeyCode = kbDown)) then
  begin
    SelectNext(Event.KeyCode = kbDown);
    ClearEvent(Event);
    Exit;
  end;
  { Enter has no meaning to a plain TInputLine outside a TDialog (it isn't
    an editing key, and there's no default-button/EndModal machinery to
    catch it here the way a dialog's OK button would) - TInputLine.
    HandleEvent leaves it uncleared and it would otherwise bubble all the
    way up and vanish with no effect, which is why the field could never
    actually be "submitted". Only acts while Tempo itself is focused, so
    Enter on one of the buttons still goes through TButton's own Press
    handling untouched. }
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEnter) and
     (Tempo^.State and sfFocused <> 0) then
  begin
    CommitTempo;
    ClearEvent(Event);
    Exit;
  end;
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
          AudioEngineStop;
          AudioEngineSeek(0);
          Playing := False;
          Recording := False;
          UpdateButtons;
        end;
      cmTransportPlay:
        TogglePlayPause;
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

{ TDysToolBarPane }

constructor TDysToolBarPane.InitPane(Bounds: TRect);
var
  R: TRect;
begin
  inherited InitPane(Bounds, 'Transport');
  R := ContentRect;
  Bar := New(PDysToolBar, Init(R));
  Insert(Bar);
  Focusable := Bar^.Tempo;
end;

{ Overrides TDysPane.FocusPane's fixed "always Focusable" behaviour: the
  base version would jump back to Tempo (Focusable, set once above) every
  time Tab/Shift+Tab cycles back into this pane, regardless of which of
  the bar's five widgets (Tempo or one of the four buttons) had focus last
  - that's what made the transport bar feel like it "steals focus into the
  tempo box" and made the buttons unreachable by keyboard, since leaving
  and returning to the pane always undid an Up/Down move away from Tempo.
  Bar^.Current (set by TDysToolBar's own Up/Down handling, see HandleEvent
  below) tracks whichever widget was actually last selected; Tempo is only
  the fallback for the very first focus, before anything has been current. }
procedure TDysToolBarPane.FocusPane;
begin
  if Bar^.Current <> nil then
    Bar^.Current^.Focus
  else
    Bar^.Tempo^.Focus;
end;

end.
