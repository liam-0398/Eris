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
  private
    procedure SetTitle(B: PButton; const S: string);
    procedure UpdateButtons;
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

  { The bottom dock: blank for now (stage 7 stub, see tui.md) - just the
    pane and its Ctrl+Enter/right-click dropdown stub, no widgets yet. }
  PDysEffectsContent = ^TDysEffectsContent;
  TDysEffectsContent = object(TView)
    constructor Init(Bounds: TRect);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PDysBottomPane = ^TDysBottomPane;
  TDysBottomPane = object(TDysPane)
    Content: PDysEffectsContent;
    constructor InitPane(Bounds: TRect);
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
  Math, AudioEngine, Project, SampleTypes, DysTrackPane;
{ Deliberately not SysUtils: it redeclares NewStr(Const S: String): PString
  with a PAnsiString-based PString, and since implementation uses always
  resolve after the interface's own Objects import, SysUtils being present
  anywhere in this unit's uses chain shadows Objects.NewStr - the very
  thing TDysToolBar.SetTitle, below, needs. IntToStr's only use here
  (DysBottomTrackLabel) goes through Str() instead, avoiding the need for
  it. }

{ Rudimentary dual-octave QWERTY tracker keyboard - same key table as
  MainForm.KeyToSemitoneOffset (src/ui), ported by hand since this object
  has no access to Eris's LCL form. Only lives in the bottom (effects)
  pane, per tui.md's Bindings: the keyboard must not fire from any other
  pane, and Esc here leaves it (see TDysEffectsContent.HandleEvent). }
function DysKeyToSemitoneOffset(AChar: Char; out AOffset: Integer): Boolean;
begin
  Result := True;
  case UpCase(AChar) of
    { bottom row - lower octave }
    'Z': AOffset := 0;
    'S': AOffset := 1;
    'X': AOffset := 2;
    'D': AOffset := 3;
    'C': AOffset := 4;
    'V': AOffset := 5;
    'G': AOffset := 6;
    'B': AOffset := 7;
    'H': AOffset := 8;
    'N': AOffset := 9;
    'J': AOffset := 10;
    'M': AOffset := 11;
    { top row - upper octave, OctaMED/Renoise/Impulse Tracker style }
    'Q': AOffset := 12;
    '2': AOffset := 13;
    'W': AOffset := 14;
    '3': AOffset := 15;
    'E': AOffset := 16;
    'R': AOffset := 17;
    '5': AOffset := 18;
    'T': AOffset := 19;
    '6': AOffset := 20;
    'Y': AOffset := 21;
    '7': AOffset := 22;
    'U': AOffset := 23;
    'I': AOffset := 24;
    '9': AOffset := 25;
    'O': AOffset := 26;
    '0': AOffset := 27;
    'P': AOffset := 28;
  else
    Result := False;
  end;
end;

{ Mirrors MainForm.TriggerKeyboardNote (src/ui), targeting DysTrackPane's
  SelectedTrackIndex ("the track under the cursor") rather than
  ArrangementView.KeyboardTrack - Dysnomia has no separate keyboard-track
  concept, the track pane's own selection stands in for it. Rudimentary on
  purpose: no Sampler Track key-bank branch (TriggerSamplerKeyNote's side
  of FormKeyDown's case) - a plain instrument track only, same as what
  DysFilePane's Ctrl+I currently assigns. }
procedure TriggerDysKeyboardNote(ASemitoneOffset: Integer);
var
  Track, SampleID, TotalOffset: Integer;
  Sample: TSample;
  StartFrame, EndFrame, TrimmedCount: Int64;
begin
  Track := SelectedTrackIndex;
  SampleID := Project.TrackInstrument[Track];
  if SampleID < 0 then
    Exit;
  Sample := Project.SamplePool[SampleID];
  StartFrame := Project.TrackInstrumentStart[Track];
  EndFrame := Project.TrackInstrumentEnd[Track];
  if StartFrame < 0 then
    StartFrame := 0;
  if EndFrame > Sample.FrameCount then
    EndFrame := Sample.FrameCount;
  TrimmedCount := EndFrame - StartFrame;
  if TrimmedCount <= 0 then
    Exit;
  TotalOffset := ASemitoneOffset + Project.TrackOctave[Track] * 12;
  AudioEngineTriggerNote(Track, @Sample.Data[StartFrame * Sample.Channels],
    TrimmedCount, Sample.Channels, TotalOffset,
    Power(10, Project.TrackInstrumentGainDb[Track] / 20));
end;

{ The little A/I/S-plus-number badge drawn at the very left of the bottom
  bar (see TDysEffectsContent.Draw) - same track-type priority as
  DysTimeline.TrackTypeChar (Sampler beats Instrument beats plain Audio),
  duplicated rather than exported since TrackTypeChar is private to
  DysTimeline and this is rudimentary/display-only. }
function DysBottomTrackLabel(ATrack: Integer): string;
var
  NumStr: string;
begin
  if (ATrack < 0) or (ATrack > High(Project.TrackIsSampler)) then
  begin
    Result := 'A';
    Exit;
  end;
  if Project.TrackIsSampler[ATrack] then
    Result := 'S'
  else if Project.TrackInstrument[ATrack] >= 0 then
    Result := 'I'
  else
    Result := 'A';
  Str(ATrack + 1, NumStr);
  Result := Result + NumStr;
end;

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
  Tempo^.SetData(S);
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

{ TDysEffectsContent }

constructor TDysEffectsContent.Init(Bounds: TRect);
begin
  inherited Init(Bounds);
  GrowMode := 0;
  EventMask := EventMask or evMouseDown or evKeyDown;
  { Same reason DysTimelineContent needs this - see tui.md's Free Vision
    notes ("Nothing is focused by default"): a hand-rolled TView has to
    opt itself into Select/Focus, a stock control does this in its own
    Init already. }
  Options := Options or (ofSelectable + ofFirstClick);
end;

procedure TDysEffectsContent.Draw;
var
  B: TDrawBuffer;
  C: Word;
  S, Lbl: string;
  Row: Integer;
begin
  C := GetColor(1);
  { Track identifier badge, very left of the bar - "which track am I about
    to hear if I play the keyboard right now" (see HandleEvent below). }
  Lbl := DysBottomTrackLabel(SelectedTrackIndex);
  S := ' effects: (none yet - Ctrl+Enter or right-click to add) ';
  for Row := 0 to Size.Y - 1 do
  begin
    MoveChar(B, ' ', C, Size.X);
    if Row = 0 then
    begin
      MoveStr(B, Lbl, C);
      MoveStr(B[Length(Lbl) + 1], S, C);
    end;
    WriteLine(0, Row, Size.X, 1, B);
  end;
end;

{ The dual-octave keyboard (see DysKeyToSemitoneOffset/TriggerDysKeyboardNote
  above) only fires here - the bottom effects pane is the one place Focus
  can land where a QWERTY letter has no other meaning already claimed (the
  file/track panes use letters to filter/type, the timeline uses W/L as
  commands) - so gating it to this view's own HandleEvent is the whole
  gate, no extra focus-tracking needed. Esc "stops keyboard input at all"
  per this session's ask: it hands focus back to the track pane, off the
  view that was reading note keys. }
procedure TDysEffectsContent.HandleEvent(var Event: TEvent);
var
  Offset: Integer;
begin
  inherited HandleEvent(Event);
  if Event.What = evKeyDown then
  begin
    if Event.KeyCode = kbEsc then
    begin
      if ActiveTrackPane <> nil then
        ActiveTrackPane^.FocusPane;
      ClearEvent(Event);
      Exit;
    end;
    if DysKeyToSemitoneOffset(Event.CharCode, Offset) then
    begin
      TriggerDysKeyboardNote(Offset);
      ClearEvent(Event);
      Exit;
    end;
  end;
  if ((Event.What = evKeyDown) and (Event.KeyCode = kbCtrlEnter)) or
     ((Event.What = evMouseDown) and (Event.Buttons and mbRightButton <> 0))
  then
  begin
    MessageBox('Effects rack dropdown is stage 7 - not wired yet.', nil,
      mfInformation or mfOKButton);
    ClearEvent(Event);
  end;
end;

{ TDysBottomPane }

constructor TDysBottomPane.InitPane(Bounds: TRect);
var
  R: TRect;
begin
  inherited InitPane(Bounds, 'Effects');
  R := ContentRect;
  Content := New(PDysEffectsContent, Init(R));
  Insert(Content);
  Focusable := Content;
end;

end.
