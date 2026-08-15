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
  cmCycleTrackHeight = 2006;
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
    MetronomeBtn, StopBtn, PlayBtn, RecordBtn, IntervalBtn, HeightBtn: PButton;
    MetronomeOn, Playing: Boolean;
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
    { Called from TDysnomiaApp.Idle (Free Vision has no timer - see that
      unit's own comment) every pass of the event loop, same "poll instead
      of a callback from the audio thread" shape MainForm's timer used for
      this. Reflects AudioEngineRecordState onto the Record button's label
      and, if the engine dropped back to Idle on its own (hit its recording
      length cap) without RecordBtn's own click handler having done it,
      finalizes the take the same way a manual click would have. }
    procedure PollRecordState;
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

{ Rudimentary dual-octave QWERTY tracker keyboard - lives here (rather than
  DysEffectsRack.pas, where the actual note-triggering used to happen) so
  TDysToolBar.HandleEvent, below, can check a typed key against it without
  DysWidgets needing to `uses DysEffectsRack` (would be circular: DysEffects
  Rack already `uses DysWidgets` for TDysPane/TDysBottomPane's own ancestor).
  Same key table as MainForm.KeyToSemitoneOffset (src/ui). }
function DysKeyToSemitoneOffset(AChar: Char; out AOffset: Integer): Boolean;

{ TriggerDysKeyboardNote/AdjustDysKeyboardOctave (DysEffectsRack.pas) do the
  actual work - they need Project/AudioEngine/DysTrackPane.SelectedTrackIndex,
  none of which DysWidgets can `uses` without the same circularity noted
  above. DysEffectsRack's own `initialization` section (see its comment)
  points these at its real implementations before any event ever reaches
  TDysToolBar - nil here only until then. }
var
  TriggerKeyboardNoteProc: procedure(ASemitoneOffset: Integer) = nil;
  AdjustKeyboardOctaveProc: procedure(ADelta: Integer) = nil;

{ DysStartRecording/DysFinalizeRecording (DysTimeline.pas) do the actual
  work - they need Project/AudioEngine/DysTrackPane.SelectedTrackIndex/
  DysTimeline.ActiveTimelineContent, none of which DysWidgets can `uses`
  without the same circularity noted above (DysTimeline itself `uses
  DysWidgets` for TDysPane). DysTimeline's own `initialization` section
  points these at the real implementations. StartRecordingProc is only
  ever invoked while AudioEngineRecordState is confirmed Idle, and
  FinalizeRecordingProc only while it's CountIn or Recording - see
  TDysToolBar.HandleEvent's cmTransportRecord case and PollRecordState. }
var
  StartRecordingProc: procedure = nil;
  FinalizeRecordingProc: procedure = nil;

{ Same circularity/wiring as the two callbacks above: TogglePlayPause (below)
  needs to seek the engine to DysTimeline.ActiveTimelineContent^.CursorFrame
  before AudioEnginePlay, so Play always starts from wherever the timeline
  cursor currently sits rather than wherever the engine last stopped -
  DysTimeline's own `initialization` section points this at the real
  implementation alongside StartRecordingProc/FinalizeRecordingProc. }
var
  SeekPlaybackToCursorProc: procedure = nil;

{ Same circularity as the callbacks above: the toolbar's height button
  (next to IntervalBtn - see HeightBtn/cmCycleTrackHeight) needs more than
  just DysWidgets.CycleTrackHeight itself, since a taller block can push
  the timeline cursor's own track off-screen - it also has to re-run
  DysTimeline.TDysTimelineContent.EnsureTrackVisible and redraw both the
  grid and the track pane, exactly like the 'h'/'H' key on the timeline
  does. DysTimeline's own `initialization` section points this at the real
  implementation. }
var
  CycleTrackHeightProc: procedure = nil;

{ Called from DysTimeline.TDysTimelineContent.MarkClipUnderCursor (the 'k'
  key) to hand the marked clip off to the bottom pane's waveform widget -
  same circularity as the two callbacks above (DysTimeline `uses
  DysWidgets`, so the reverse call can't be direct), except this one's real
  implementation is in DysEffectsRack.pas (the unit that actually owns
  TDysBottomPane/the waveform widget), which points it there from its own
  `initialization` section alongside the note-trigger/octave callbacks.
  AGain/ADetune/AWarpMode are the clip's own TClip.Gain/PitchSemitones/
  WarpMode fields - the waveform widget displays them alongside the
  waveform itself (same info EditsRack/the WarpEditor show in src/ui,
  display-only here, no editing yet). ATrack/AClipIdx (added alongside the
  playhead feature) are Project.Tracks[ATrack].Clips[AClipIdx]'s own
  indices for this same clip - the waveform widget keeps these rather than
  a copy of Position, so its playhead can re-resolve the clip's live
  Position/Offset/Length from Project each poll instead of a snapshot a
  later ripple chop elsewhere could move out from under it; -1/-1 (from
  DysChopMarkedClipRegion's own clear-the-mark call) means "nothing marked",
  same sentinel ASampleID<0 already uses. }
var
  SetWaveformClipProc: procedure(ASampleID: Integer; AOffset, ALength: Int64;
    AGain, ADetune: Single; AWarpMode, ATrack, AClipIdx: Integer) = nil;

{ Called from DysEffectsRack.TDysWaveformContent.HandleEvent's Delete key,
  once the user has drag-selected a span over the waveform (mouse handling
  lives entirely in that view - Free Vision's own TView.MouseEvent drag
  loop, nothing DysWidgets needs to know about) - same circularity as
  SetWaveformClipProc above (DysEffectsRack `uses DysWidgets`, not the other
  way around), except the real implementation this points to
  (DysChopMarkedClipRegion) is in DysTimeline.pas, alongside
  StartRecordingProc/FinalizeRecordingProc/SeekPlaybackToCursorProc, since
  it needs to mutate the MARKED clip (DysTimeline.ActiveTimelineContent^.
  MarkedTrack/MarkedClipIndex) rather than anything local to the waveform
  widget itself. AStartFrame/AEndFrame are absolute source-domain sample
  frame positions (same domain as TClip.Offset), not timeline frames. }
var
  ChopWaveformSelectionProc: procedure(AStartFrame, AEndFrame: Int64) = nil;

const
  MinTrackHeight = 1;
  MaxTrackHeight = 3;

{ Rows a single track occupies in the timeline grid and the track pane
  listing - toggled by 'h'/'H' on the timeline (DysTimeline.HandleEvent).
  Lives here, not in DysTimeline, so DysTrackPane (which does not and
  cannot `uses DysTimeline` - see DysTimeline's own implementation `uses
  DysTrackPane`, the reverse would be circular) can read it too: both
  panes must render off the exact same value or the "track number lines
  up with the top row of its block" alignment breaks. }
var
  TrackHeight: Integer = 1;
  { First track drawn at the top of the grid (row 1, just under the
    ruler) - vertical scroll in TRACK units, not screen rows. Changed only
    from DysTimeline (Up/Down following the cursor, PageUp/PageDown) per
    the "scroll only happens from the timeline" decision - DysTrackPane's
    own listing has no independent scroll of its own, it just redraws
    against whatever this currently is. See DysTimeline.EnsureTrackVisible. }
  ViewStartTrack: Integer = 0;

{ Cycles TrackHeight through 1/2/3 and returns the new value - same shape
  as WaveformDraw.CycleWaveformGridDivision (src/ui) in the GUI. }
function CycleTrackHeight: Integer;

{ 'H:' plus the current TrackHeight, for HeightBtn's caption - a plain
  function rather than IntToStr inline at the call site because this
  unit's implementation section deliberately does not `uses SysUtils` (see
  the comment just above `implementation`: it would shadow Objects.NewStr,
  which TDysToolBar.SetTitle needs), so this uses Str() instead, same as
  DysEffectsRack's own IdStr/GainStr. }
function TrackHeightLabel: string;

{ The screen row (0 = the seconds ruler) the TOP of ATrack's block sits
  on, given the current TrackHeight/ViewStartTrack - the one formula both
  DysTimeline.Draw and DysTrackPane's listing key off, so their row math
  can't independently drift apart. ATrack is 0-based, same as
  Project.Tracks. }
function TrackTopRow(ATrack: Integer): Integer;

{ One row's worth of a single waveform bar column, given the bar's own
  continuous vertical span (ATop..ABot, in fractional-row units where row 0
  is this row's own top edge and row 1 its bottom) against THIS row's fixed
  [0,1) slice. Shared by DysEffectsRack's bottom-pane waveform widget and
  DysTimeline's inline per-clip waveform - see either call site for the
  CP437/half-block reasoning (checked against the Unix video driver: no
  sub-cell or Braille addressing is reachable through Free Vision's draw
  pipeline at all, so a half-block plus a plain-ASCII sliver is the finest
  vertical resolution actually achievable per row). }
function WaveRowGlyph(ATop, ABot: Double): Char;

implementation

uses
  AudioEngine, Project;
{ Deliberately not SysUtils: it redeclares NewStr(Const S: String): PString
  with a PAnsiString-based PString, and since implementation uses always
  resolve after the interface's own Objects import, SysUtils being present
  anywhere in this unit's uses chain shadows Objects.NewStr - the very
  thing TDysToolBar.SetTitle, below, needs. }

function DysKeyToSemitoneOffset(AChar: Char; out AOffset: Integer): Boolean;
begin
  Result := True;
  case UpCase(AChar) of
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

{ TDysPane }

constructor TDysPane.InitPane(Bounds: TRect; const ATitle: string);
begin
  inherited Init(Bounds, ATitle, wnNoNumber);
  Flags := 0;      { no move, grow or close - this is a dock, not a window }
  GrowMode := 0;   { the app repositions panes itself on layout, not FV }
  Focusable := nil;
  { Without ofFirstClick, TView.HandleEvent's own generic mouse-down check
    (views.pas: "If (Focus = False) OR (Options and ofFirstClick = 0) Then
    ClearEvent") swallows the very click that focuses an unfocused pane -
    standard Turbo Vision "click once to wake the window, again to actually
    do anything" behaviour. With five docked panes and Tab/Shift+Tab as the
    normal way to move between them, that was easy to not notice; it became
    obvious once the effects rack started actually rendering its boxes and
    got clicked on a lot - switching to any OTHER pane by mouse afterwards
    needed one throwaway click before the second one actually landed on
    anything, which read as "the mouse stopped working" for every pane but
    whichever one was already focused. ofFirstClick here means the same
    click that focuses a pane is also delivered to whatever's under it. }
  Options := Options or ofFirstClick;
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

  IntervalIdx := 2; { 1/16 - see IntervalNames; also the bottom waveform
                       pane's default grid, DysEffectsRack.DysWaveGridStepFrames }
  R.Assign(X, 0, X + 6, 1);
  IntervalBtn := New(PButton, Init(R, IntervalNames[IntervalIdx], cmCycleInterval,
    bfNormal));
  Insert(IntervalBtn);
  X := X + 7;

  { Right next to the interval (cursor movement/grid step) button - same
    "cycle on click, caption shows the current value" shape, for
    DysWidgets.TrackHeight/CycleTrackHeight rather than IntervalIdx. }
  R.Assign(X, 0, X + 4, 1);
  HeightBtn := New(PButton, Init(R, TrackHeightLabel, cmCycleTrackHeight,
    bfNormal));
  Insert(HeightBtn);

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
  { Record's own caption is driven entirely by AudioEngineRecordState, via
    PollRecordState - not by anything tracked locally here (there used to
    be a local Recording: Boolean, same shape as Playing/MetronomeOn, but
    unlike Play/Stop the engine can drop out of Recording on its own - see
    PollRecordState's own comment - so a local flag would drift out of
    sync with reality the moment that happened; reading the engine's own
    state directly on every Idle pass can't drift). }
  SetTitle(IntervalBtn, IntervalNames[IntervalIdx]);
  SetTitle(HeightBtn, TrackHeightLabel);
end;

{ Mirrors MainForm.PlayPauseClick: Stop wins if already playing, otherwise
  only start if there's actually a clip somewhere - see AudioEngineHasClip -
  so Play on an empty project does nothing rather than silently "playing"
  nothing. Factored out of the Play button's own cmTransportPlay case so
  the timeline's Space key (tui.md's Bindings) triggers the exact same
  logic and button-label update, via ActiveToolBar. Finalizes an in-
  progress take first, same as MainForm.PlayPauseClick - stopping playback
  mid-recording would otherwise leave the engine's capture dangling. }
procedure TDysToolBar.TogglePlayPause;
begin
  if AudioEngineIsPlaying then
  begin
    if (AudioEngineRecordState <> RecordStateIdle) and
       Assigned(FinalizeRecordingProc) then
    begin
      FinalizeRecordingProc;
      SetTitle(RecordBtn, 'Rec');
    end;
    AudioEngineStop;
    Playing := False;
  end
  else if AudioEngineHasClip then
  begin
    if Assigned(SeekPlaybackToCursorProc) then
      SeekPlaybackToCursorProc;
    AudioEnginePlay;
    Playing := True;
  end;
  UpdateButtons;
end;

{ See this type's own declaration comment. }
procedure TDysToolBar.PollRecordState;
begin
  case AudioEngineRecordState of
    RecordStateCountIn:
      SetTitle(RecordBtn, 'Cnt');
    RecordStateRecording:
      SetTitle(RecordBtn, 'REC');
    RecordStateIdle:
      if (RecordBtn^.Title <> nil) and (RecordBtn^.Title^ <> 'Rec') then
      begin
        { The button's own caption is the only record of "were we counting
          in or recording a moment ago" available here - RecordState
          having already dropped back to Idle on its own (the engine hit
          its recording length cap) means whatever RecordButtonProc would
          normally do on a manual stop-click never ran, so run its
          finalize half now instead. }
        if Assigned(FinalizeRecordingProc) then
          FinalizeRecordingProc;
        SetTitle(RecordBtn, 'Rec');
      end;
  end;
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
var
  Offset: Integer;
begin
  { The instrument keyboard (QWERTY -> note) only plays while the top
    (transport) pane is the one selected - it used to live on the bottom
    effects pane instead (moved here wholesale, see DysEffectsRack.pas's
    session note). MUST run BEFORE `inherited HandleEvent`, not after:
    Tempo is this pane's default focus target (TDysToolBarPane.InitPane's
    Focusable := Bar^.Tempo) and stays Current across most of a session
    unless Up/Down explicitly moves off it, so `inherited HandleEvent`
    (TGroup.HandleEvent, which dispatches a focused evKeyDown to Current)
    routes every plain letter/digit straight into Tempo's own TInputLine.
    HandleEvent first - which happily accepts ANY printable character as
    text (it validates as a BPM number only later, in CommitTempo, not per
    keystroke) and clears the event. Checking AFTER inherited (the first
    version of this fix) meant the note keys were already consumed and
    gone by the time this code ran, and the keyboard looked completely
    dead - exactly the reported symptom. Explicitly skipped while Tempo
    itself is focused, so it can still be typed into normally; every other
    Current (one of the four buttons, or nothing yet) falls through to
    this unconditionally. Ctrl+Z/Ctrl+X (genuinely distinct bytes, not the
    raw letters, so no collision with the note keys themselves) shift the
    octave instead of playing a note. }
  if (Event.What = evKeyDown) and (Tempo^.State and sfFocused = 0) then
  begin
    if Event.KeyCode = kbCtrlZ then
    begin
      if Assigned(AdjustKeyboardOctaveProc) then
        AdjustKeyboardOctaveProc(-1);
      ClearEvent(Event);
      Exit;
    end;
    if Event.KeyCode = kbCtrlX then
    begin
      if Assigned(AdjustKeyboardOctaveProc) then
        AdjustKeyboardOctaveProc(1);
      ClearEvent(Event);
      Exit;
    end;
    if DysKeyToSemitoneOffset(Event.CharCode, Offset) then
    begin
      if Assigned(TriggerKeyboardNoteProc) then
        TriggerKeyboardNoteProc(Offset);
      ClearEvent(Event);
      Exit;
    end;
  end;
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
          { Mirrors MainForm.StopClick: finalize an in-progress take before
            stopping/seeking, same reasoning as TogglePlayPause's own
            finalize-first step. }
          if (AudioEngineRecordState <> RecordStateIdle) and
             Assigned(FinalizeRecordingProc) then
          begin
            FinalizeRecordingProc;
            SetTitle(RecordBtn, 'Rec');
          end;
          AudioEngineStop;
          AudioEngineSeek(0);
          Playing := False;
          UpdateButtons;
        end;
      cmTransportPlay:
        TogglePlayPause;
      cmTransportRecord:
        { Mirrors MainForm.RecordClick: a click while counting in or
          recording stops/finalizes; a click while Idle starts a count-in
          (or, for a line-in track, starts capturing immediately - see
          DysStartRecording). PollRecordState (Idle-driven, see its own
          comment) reflects the resulting state onto this button's caption
          on the very next event-loop pass - no caption change needed
          here, only the engine calls themselves. }
        if AudioEngineRecordState <> RecordStateIdle then
        begin
          if Assigned(FinalizeRecordingProc) then
            FinalizeRecordingProc;
          SetTitle(RecordBtn, 'Rec');
        end
        else if Assigned(StartRecordingProc) then
          StartRecordingProc;
      cmCycleInterval:
        begin
          IntervalIdx := (IntervalIdx + 1) mod Length(IntervalNames);
          UpdateButtons;
        end;
      cmCycleTrackHeight:
        begin
          if Assigned(CycleTrackHeightProc) then
            CycleTrackHeightProc
          else
            CycleTrackHeight; { no timeline yet - still update the shared
                                 value/caption, just nothing to re-scroll }
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

function CycleTrackHeight: Integer;
begin
  Inc(TrackHeight);
  if TrackHeight > MaxTrackHeight then
    TrackHeight := MinTrackHeight;
  Result := TrackHeight;
end;

function TrackTopRow(ATrack: Integer): Integer;
begin
  Result := 1 + (ATrack - ViewStartTrack) * TrackHeight;
end;

function TrackHeightLabel: string;
var
  HStr: string;
begin
  Str(TrackHeight, HStr);
  Result := 'H:' + HStr;
end;

{ Deliberately only 2 levels (full block or blank), not the 4-level full/
  half/sliver ramp this used to be: a real signal's noise floor between
  drum hits is never EXACTLY zero, so the old sliver tier ('.'/'`' for
  anything covering under 40% of a row) lit up on almost every quiet
  column, not just genuinely loud ones - across a busy break every row
  chattered with punctuation and the whole clip read as static rather than
  a shape with peaks in it. A hard 50% threshold means a row is either
  clearly hit or clearly not, so the ear-relevant question ("where's the
  kick/snare/hat, where can I chop") reads at a glance instead of needing
  to squint at texture. See DysTimeline.DrawClipWaveSpan for the transient
  tick marks that do the actual "where exactly to chop" job on top of this. }
function WaveRowGlyph(ATop, ABot: Double): Char;
var
  OverlapTop, OverlapBot: Double;
begin
  OverlapTop := ATop;
  if OverlapTop < 0 then
    OverlapTop := 0;
  OverlapBot := ABot;
  if OverlapBot > 1 then
    OverlapBot := 1;
  if OverlapBot <= OverlapTop then
    Exit(' ');
  if OverlapBot - OverlapTop >= 0.5 then
    Exit(Chr(219)) { full block }
  else
    Exit(' ');
end;

end.
