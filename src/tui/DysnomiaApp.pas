unit DysnomiaApp;

{ Stage 1 Free Vision application shell: menu bar, status line, transport
  bar, docked file/track/timeline panes, bottom bar. Stage 5 linked Project
  and Config (util); stage 6 links aengine/abackend the same way - engine
  starts and stops with the app, same AudioEngineInit/Shutdown pair and
  same ALSA-default behaviour as eris.lpr/MainForm.pas, completely
  untouched. No pane reads from the engine yet, that's stage 7/8. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Menus, Dialogs, App,
  DysGeometry, DysWidgets, DysEffectsRack, DysFilePane, DysTrackPane, DysTimeline,
  DysPreferences, DysFileDialog, Project, Config, ProjectFile;

const
  cmAbout = 1000;
  { File menu - same item order as Eris's own (MainForm.BuildMenu, src/ui).
    New/Open/Save/Save As/Export are stubs per tui.md: none of them touch
    disk yet, only Exit (cmQuit, already a Free Vision builtin) is real. }
  cmFileNew      = 1010;
  cmFileOpen     = 1011;
  cmFileSave     = 1012;
  cmFileSaveAs   = 1013;
  cmFileExport   = 1014;
  { Edit menu - the timeline's own clip-under-cursor operations
    (DysTimeline.TDysTimelineContent), routed through here so the menu and
    the direct Ctrl+C/V/D/E/Delete keys share one implementation, same as
    Eris's MainForm/ArrangementView split. }
  cmEditCopy         = 1020;
  cmEditPaste        = 1021;
  cmEditDuplicate    = 1022;
  cmEditSplit        = 1023;
  cmEditDelete       = 1024;
  cmEditPreferences  = 1025;

type
  PDysnomiaApp = ^TDysnomiaApp;
  TDysnomiaApp = object(TApplication)
    ToolBarPane: PDysToolBarPane;
    BottomPane: PDysBottomPane;
    FilePane: PDysFilePane;
    TrackPane: PDysTrackPane;
    Timeline: PDysTimeline;
    { '' = no project opened/saved yet this session - Save falls back to
      Save As until this is set, same as MainForm.FCurrentProjectPath. }
    CurrentProjectPath: string;
    constructor Init;
    destructor Done; virtual;
    procedure InitMenuBar; virtual;
    procedure InitStatusLine; virtual;
    procedure InitDeskTop; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    function GetPalette: PPalette; virtual;
    procedure Idle; virtual;
  private
    procedure ShowAbout;
    procedure ShowTooSmall(Body: TRect; const Layout: TDysLayout);
    function WaitForEngineIdle: Boolean;
    procedure RefreshAfterProjectChange;
    procedure DoFileOpen;
    procedure DoFileSave;
    procedure DoFileSaveAs;
  end;

implementation

uses
  MsgBox, AudioEngine;

const
  { DysTrackPane's list is a fixed PlaceholderTrackCount (8) rows regardless
    of Project.TrackCount (see DysTrackPane.pas) - Project.DefaultTrackCount
    is 4, Eris's own default, and that's Eris source (not to be touched, per
    tui.md's RULES). Topping TrackCount up to 8 here, Dysnomia-side only,
    is what makes the timeline's own "one row per Project.TrackCount" loop
    (DysTimeline.Draw) actually draw all 8 rows the track pane already
    shows, instead of leaving 4 of them looking like they don't exist. }
  DysStartTrackCount = 8;

procedure EnsureDysTrackCount(ACount: Integer);
begin
  while Project.TrackCount < ACount do
    if not Project.AddTrack then
      Break;
end;

{ App-wide colour override. See DysWidgets.TDysPane's comment for why the
  panes need CGrayDialog rather than a plain window palette; this is the
  other half - recolouring what CGrayDialog's indices actually resolve
  to, without touching anything else CAppColor (App.pas) drives (menu
  bar, status line, blue/cyan window and dialog variants).

  Attribute byte layout here is the classic one: bit 7 = blink, bits 4-6
  = background (0-7), bits 0-3 = foreground (0-15). Every stock palette
  byte in CAppColor keeps bit 7 clear - it's reserved as the Drivers.
  ErrorAttr ($CF) signal for "palette index out of range", which is
  exactly the red-blink Dysnomia was showing before CGrayDialog was
  wired in. So bit 7 stays off here too: "dark grey background" isn't
  representable as an intentional bg colour in this model (that needs a
  4th background bit, which doesn't exist without reusing the blink
  bit) - background 0 (black) is the closest safe substitute, and it's
  what most terminal "black" themes render as anyway. }
var
  DysAppPalette: TPalette;
  DysAppPaletteReady: Boolean = False;

procedure InitDysAppPalette;
const
  { Background is a 3-bit field (bits 4-6, range 0-7) sharing the byte
    with bit 7 (blink) - it is NOT a 4-bit nibble, so a background of 15
    ($Fx) does not mean "bright white bg", it means bg=7 with blink SET.
    $F0 was exactly that mistake and is why the focused list item used to
    blink instead of highlighting: it decoded to blink + light-grey bg +
    black fg, not solid white bg + black fg. $70 (bg=7, fg=0, no blink)
    is the actual reverse-video byte. Foreground has no such limit - the
    full 0-15 range, including "bright" values, is always blink-safe. }
  BgAttr   = $07; { black bg, light grey fg - desktop background pattern }
  PaneNorm = $0F; { black bg, bright white fg - pane text }
  PaneSel  = $70; { light grey bg, black fg - focused/selected list item }
var
  I: Integer;
begin
  DysAppPalette := CAppColor;
  DysAppPalette[1] := Chr(BgAttr);
  for I := 32 to 63 do            { the CGrayDialog block, local idx 1..32 }
    DysAppPalette[I] := Chr(PaneNorm);
  { TListViewer.Draw (views.pas) calls GetColor(2) for a normal item,
    GetColor(3) for the focused (keyboard-cursor) item, GetColor(4) for
    a selected-but-unfocused item - and CListViewer (#26#26#27#28#29,
    views.pas) remaps those through ITS OWN small palette first: local
    idx 2->26, 3->27, 4->28. idx 26 is also what "normal" resolves to,
    so it's left on the PaneNorm default above; only 27 and 28 need to
    stand out, or keyboard focus is invisible even though it's moving. }
  DysAppPalette[32 + 27 - 1] := Chr(PaneSel); { CListViewer local idx 27 }
  DysAppPalette[32 + 28 - 1] := Chr(PaneSel); { CListViewer local idx 28 }
  DysAppPaletteReady := True;
end;

function TDysnomiaApp.GetPalette: PPalette;
begin
  if not DysAppPaletteReady then
    InitDysAppPalette;
  GetPalette := @DysAppPalette;
end;

constructor TDysnomiaApp.Init;
begin
  { Same eris.conf Eris itself reads/writes (Config.ConfigFilePath is
    platform-derived, not app-specific) - loaded before InitDeskTop so a
    later stage's panes can read Config.Cfg from their own Init. Nothing
    here consumes it yet; this just proves util links clean, per stage 5
    in tui.md. }
  ConfigLoad;
  { Same call, same backend defaulting (ALSA unless eris.conf or a present
    PipeWire server says otherwise) as eris.lpr/MainForm.pas - see
    AudioEngineInit. Nothing Dysnomia-specific here. }
  AudioEngineInit;
  EnsureDysTrackCount(DysStartTrackCount);

  inherited Init;
  { Nothing is Current anywhere by default - Insert() doesn't select what
    it inserts, so without this no view anywhere would receive keyboard
    input until the user's first mouse click (mouse events are routed by
    hit-testing, not by Current, so a click "accidentally" fixes this up
    on its own - but a keyboard-only launch would otherwise sit dead).
    This has to run here, after "inherited Init" returns, not at the end
    of InitDeskTop: TProgram.Init only calls Insert(DeskTop) *after*
    InitDeskTop returns, so DeskTop.Owner is still nil while InitDeskTop
    itself is running - Focus's climb up Owner would stop there instead
    of reaching Self (the Application). }
  if FilePane <> nil then
    FilePane^.FocusPane;
end;

{ Round-trips Cfg straight back out unchanged - nothing here edits it yet,
  this only proves the save half of the same link. Engine down before
  config save, same ordering MainForm.Destroy uses (backend closed while
  nothing else still touches it). }
destructor TDysnomiaApp.Done;
begin
  AudioEngineShutdown;
  ConfigSave;
  inherited Done;
end;

procedure TDysnomiaApp.InitMenuBar;
var
  R: TRect;
  FileItems, EditItems, HelpItems: PMenuItem;
begin
  GetExtent(R);
  R.B.Y := R.A.Y + 1;

  FileItems :=
    NewItem('~N~ew', '', kbNoKey, cmFileNew, hcNoContext,
    NewItem('~O~pen...', 'Ctrl-O', kbCtrlO, cmFileOpen, hcNoContext,
    NewItem('~S~ave', 'Ctrl-S', kbCtrlS, cmFileSave, hcNoContext,
    NewItem('Save ~A~s...', 'F12', kbF12, cmFileSaveAs, hcNoContext,
    NewLine(
    NewItem('~E~xport...', '', kbNoKey, cmFileExport, hcNoContext,
    NewLine(
    NewItem('E~x~it', 'Alt-X', kbAltX, cmQuit, hcNoContext,
    nil))))))));

  EditItems :=
    NewItem('~C~opy', 'Ctrl-C', kbCtrlC, cmEditCopy, hcNoContext,
    NewItem('~P~aste', 'Ctrl-V', kbCtrlV, cmEditPaste, hcNoContext,
    NewItem('D~u~plicate', 'Ctrl-D', kbCtrlD, cmEditDuplicate, hcNoContext,
    NewItem('S~p~lit', 'Ctrl-E', kbCtrlE, cmEditSplit, hcNoContext,
    NewItem('D~e~lete', 'Del', kbDel, cmEditDelete, hcNoContext,
    NewLine(
    NewItem('~P~references...', '', kbNoKey, cmEditPreferences, hcNoContext,
    nil)))))));

  HelpItems :=
    NewItem('~A~bout', '', kbNoKey, cmAbout, hcNoContext,
    nil);

  MenuBar := New(PMenuBar, Init(R, NewMenu(
    NewSubMenu('~F~ile', hcNoContext, NewMenu(FileItems),
    NewSubMenu('~E~dit', hcNoContext, NewMenu(EditItems),
    NewSubMenu('~H~elp', hcNoContext, NewMenu(HelpItems),
    nil))))));
end;

procedure TDysnomiaApp.InitStatusLine;
var
  R: TRect;
begin
  GetExtent(R);
  R.A.Y := R.B.Y - 1;
  StatusLine := New(PStatusLine, Init(R,
    NewStatusDef(0, $FFFF,
      NewStatusKey('~Alt-X~ Exit', kbAltX, cmQuit,
      NewStatusKey('~F10~ Menu', kbF10, cmMenu,
      nil)),
    nil)));
end;

procedure TDysnomiaApp.ShowTooSmall(Body: TRect; const Layout: TDysLayout);
var
  Local: TRect;
begin
  DeskTop := New(PDeskTop, Init(Body));
  Local := Body;
  Local.Move(-Body.A.X, -Body.A.Y);
  DeskTop^.Insert(New(PStaticText, Init(Local,
    'Resize to at least ' + IntToStr(MinCols) + 'x' + IntToStr(MinRows) +
    ' - currently ' + IntToStr(Layout.Cols) + 'x' + IntToStr(Layout.Rows))));
end;

{ All five docks are now siblings in one DeskTop group (rather than the
  toolbar/bottom bar living directly in the App, outside DeskTop, as they
  did as plain 1-row bars) - TDysPane's Tab/Shift+Tab handler works off
  Owner^.SelectNext, so panes only cycle together with Tab if they share
  the same Owner. DeskTop now spans the WHOLE body (menu bar to status
  line), not just the middle strip between the two bars; ToolBarPane and
  BottomPane occupy their own rows within it exactly like before, just as
  DeskTop children instead of App children. Insertion order is the Tab
  order: top, then left-to-right across the middle, then bottom. }
procedure TDysnomiaApp.InitDeskTop;
var
  R, Local: TRect;
  Layout: TDysLayout;
begin
  GetExtent(R);
  if MenuBar <> nil then
    Inc(R.A.Y);
  if StatusLine <> nil then
    Dec(R.B.Y);

  Layout := ComputeLayout(R);
  if Layout.TooSmall then
  begin
    ShowTooSmall(R, Layout);
    Exit;
  end;

  DeskTop := New(PDeskTop, Init(R));

  Local := Layout.ToolBar;
  Local.Move(-R.A.X, -R.A.Y);
  ToolBarPane := New(PDysToolBarPane, InitPane(Local));
  DeskTop^.Insert(ToolBarPane);

  Local := Layout.FilePane;
  Local.Move(-R.A.X, -R.A.Y);
  FilePane := New(PDysFilePane, InitPane(Local));
  DeskTop^.Insert(FilePane);

  Local := Layout.Timeline;
  Local.Move(-R.A.X, -R.A.Y);
  Timeline := New(PDysTimeline, InitPane(Local));
  DeskTop^.Insert(Timeline);

  Local := Layout.TrackPane;
  Local.Move(-R.A.X, -R.A.Y);
  TrackPane := New(PDysTrackPane, InitPane(Local));
  DeskTop^.Insert(TrackPane);

  Local := Layout.BottomBar;
  Local.Move(-R.A.X, -R.A.Y);
  BottomPane := New(PDysBottomPane, InitPane(Local));
  DeskTop^.Insert(BottomPane);
end;

{ Mirrors MainForm.WaitForEngineIdle (src/ui): a queued AudioEngineStop
  hasn't necessarily drained the playback thread yet, and LoadProject/
  NewProject free every sample's memory - freeing it out from under a
  thread that's still reading TrackClips is a use-after-free, not just a
  stopped-too-late cosmetic issue.

  USED TO have no timeout at all - unlike MainForm, which only bounds this
  on Windows (5000ms) and is an unguarded `while AudioEngineIsBusy
  do Sleep(1)` on every other platform, same as this used to be
  unconditionally. That is a real "freeze until Alt+X doesn't even work"
  failure mode: this loop runs on the main thread with no event pumping at
  all, so if AudioEngineIsBusy ever stays True (a stuck live note that
  Free Vision's raw-terminal keyboard driver can't send a genuine key-up
  for, unlike an LCL KeyUp event - see tui.md's keyboard notes - or any
  other reason the audio thread stops draining), Dysnomia had no way back:
  no cursor blink, no screen redraw, no reachable Ctrl+C/Alt+X, nothing
  short of killing the process from another terminal. Bounding it uniformly
  (all platforms, not just Windows) and returning False on timeout instead
  of hanging turns that into "File New/Open/Save waited 5s, then declined
  with a message" - recoverable, and the caller's contract changes to match
  MainForm's own Boolean return: on False, do NOT touch Project.NewProject/
  LoadProject/SaveProject - the busy engine might still be reading exactly
  the memory that would free. }
function TDysnomiaApp.WaitForEngineIdle: Boolean;
const
  TimeoutMs = 5000;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + TimeoutMs;
  while AudioEngineIsBusy do
  begin
    if GetTickCount64 > Deadline then
      Exit(False);
    Sleep(1);
  end;
  Result := True;
end;

{ Common to Open and (implicitly, via Project.NewProject) New: the track
  count, clip contents and sample pool can all have changed size or gone
  away entirely, so every pane that caches anything derived from Project
  state needs a fresh Draw, and the timeline's cursor needs to land
  somewhere guaranteed valid rather than wherever it happened to be in the
  project that just closed. }
procedure TDysnomiaApp.RefreshAfterProjectChange;
var
  i: Integer;
begin
  { Project.TempoBPM can change out from under the transport bar's own
    field on a load/New (a loaded project's saved tempo, or NewProject's
    reset to DefaultTempoBPM) - the field only ever wrote TO TempoBPM
    (CommitTempo, on Enter) until this, so it would otherwise still be
    showing whatever was last typed (or the stale 120.0 startup value)
    while the actual project tempo underneath had already moved on. See
    DysWidgets.TDysToolBar.SyncTempoDisplay. }
  { Mirrors MainForm.RefreshAllTracksUI's AudioEngineSeek(0) - without it
    the engine's Playhead keeps whatever value the PREVIOUS project's
    playback left it at, not 0. A loaded project's own timeline cursor
    still resets to frame 0 (below), so the visual "played to the end,
    hit Stop" position and the transport's real Playhead silently
    disagreed until this. }
  AudioEngineSeek(0);
  { The timeline's LoopStart/LoopEnd fields are wiped to -1 below, but the
    engine keeps the previous project's loop - Play then rewinds to the old
    LoopStart every block with no markers visible, a playhead pinned at 0. }
  AudioEngineClearLoop;
  if ActiveToolBar <> nil then
  begin
    ActiveToolBar^.SyncTempoDisplay;
    { MainForm.RefreshAllTracksUI resets its own Play/Pause caption the
      same way - a project change already forced a Stop above this call
      (see cmFileNew/DoFileOpen), so the button showing "Pause" from
      whatever was playing a moment ago would otherwise be a stale label
      pointing at a transport that's no longer running. }
    ActiveToolBar^.Playing := False;
    ActiveToolBar^.UpdateButtons;
  end;
  { UNCONDITIONAL full clear, every slot 0..MaxTracks-1 - not just the
    "stale tail" (Project.TrackCount to MaxTracks-1) this used to clear.
    That range-based version relied on Project.TrackCount already being the
    NEW project's count at the point this runs, which put a silent ordering
    dependency on every caller (cmFileNew happened to call
    EnsureDysTrackCount before this; a future caller that doesn't get that
    order right reintroduces the exact "open-several-projects-and-the-
    playhead-locks" bug MainForm.RefreshAllTracksUI's own comment names -
    stale slots left holding a dangling pointer into memory Project.
    NewProject/LoadProject already FreeMem'd, since AudioEngineHasClip
    still reports "has a clip" for them and FillBlock's mix pass reads
    through them regardless).  Clearing the whole range first removes that
    dependency entirely: every slot starts empty, then PushAllTracksToEngine
    (below) rebuilds exactly 0..Project.TrackCount-1 fresh from Project.Tracks
    - no reasoning anywhere about which range is "old" vs "new" is possible
    to get wrong, because there's no partial/delta step left to get wrong. }
  for i := 0 to Project.MaxTracks - 1 do
    AudioEngineSetTrackClips(i, nil, 0);
  if Timeline <> nil then
  begin
    Timeline^.Content^.CursorTrack := 0;
    Timeline^.Content^.CursorFrame := 0;
    Timeline^.Content^.CursorInLabel := True;
    Timeline^.Content^.CancelOverlay;
    Timeline^.Content^.LoopStart := -1;
    Timeline^.Content^.LoopEnd := -1;
    { The scroll position is otherwise left wherever a previous project's
      playback/manual scrolling last put it (see DysTimeline's
      ViewStartFrame) - resetting it here matches the cursor/loop resets
      just above: a freshly opened project should start looking at its own
      frame 0, not wherever the last one happened to autoscroll to. }
    Timeline^.Content^.ViewStartFrame := 0;
    { The actual fix for "clips are on the timeline but Play does nothing"
      after a project open/New - see PushAllTracksToEngine's own comment
      in DysTimeline.pas. Project.Tracks is what the timeline draws from,
      but the audio engine has its own separate TrackClips arrays that
      only PushTrackToEngine populates - nothing did that here before. }
    Timeline^.Content^.PushAllTracksToEngine;
    Timeline^.Content^.DrawView;
  end;
  if TrackPane <> nil then
    TrackPane^.Listing^.DrawView;
  if FilePane <> nil then
    FilePane^.Listing^.DrawView;
end;

procedure TDysnomiaApp.DoFileOpen;
var
  Path: string;
  StartDir: string;
begin
  if CurrentProjectPath <> '' then
    StartDir := ExtractFileDir(CurrentProjectPath)
  else
    StartDir := DysFilePane.DefaultBrowseDir;
  if not DysFileDialog.RunFileDialog(fdmOpen, StartDir, '', Path) then
    Exit;

  AudioEngineStop;
  if not WaitForEngineIdle then
  begin
    MessageBox('The audio engine stopped responding, so nothing was ' +
      'opened.', nil, mfError or mfOKButton);
    Exit;
  end;
  if not ProjectFile.LoadProject(Path) then
  begin
    MessageBox('Could not open "' + Path + '" as an Eris project.', nil,
      mfError or mfOKButton);
    Exit;
  end;
  CurrentProjectPath := Path;
  RefreshAfterProjectChange;
end;

procedure TDysnomiaApp.DoFileSave;
begin
  if CurrentProjectPath = '' then
  begin
    DoFileSaveAs;
    Exit;
  end;
  if not ProjectFile.SaveProject(CurrentProjectPath) then
    MessageBox('Could not save "' + CurrentProjectPath + '".', nil,
      mfError or mfOKButton);
end;

procedure TDysnomiaApp.DoFileSaveAs;
var
  Path: string;
  StartDir, StartName: string;
begin
  if CurrentProjectPath <> '' then
  begin
    StartDir := ExtractFileDir(CurrentProjectPath);
    StartName := ExtractFileName(CurrentProjectPath);
  end
  else
  begin
    StartDir := DysFilePane.DefaultBrowseDir;
    StartName := '';
  end;
  if not DysFileDialog.RunFileDialog(fdmSaveAs, StartDir, StartName, Path) then
    Exit;

  if not ProjectFile.SaveProject(Path) then
  begin
    MessageBox('Could not save "' + Path + '".', nil, mfError or mfOKButton);
    Exit;
  end;
  CurrentProjectPath := Path;
end;

procedure TDysnomiaApp.ShowAbout;
begin
  MessageBox('Dysnomia - Free Vision frontend for Eris'#13#13 +
    'Stage 1: UI shell, not hooked up to the engine yet.', nil,
    mfInformation or mfOKButton);
end;

{ Free Vision has no timer - TProgram.Idle (see app.pas) is called on every
  pass of the event loop that finds no key/mouse event waiting, which is the
  closest thing to one. Without this the transport buttons worked (Play did
  call AudioEnginePlay) but nothing in the UI ever showed it: no playhead
  moving, so a press looked like it "did nothing" even when audio was
  genuinely running. }
procedure TDysnomiaApp.Idle;
begin
  inherited Idle;
  if (Timeline <> nil) and (Timeline^.Content <> nil) then
    Timeline^.Content^.UpdatePlayhead;
  { Same "no timer, poll on Idle instead" reasoning as the playhead above -
    reflects AudioEngineRecordState onto the Record button and finalizes a
    take the engine auto-stopped on its own (see TDysToolBar.
    PollRecordState). }
  if ActiveToolBar <> nil then
    ActiveToolBar^.PollRecordState;
end;

procedure TDysnomiaApp.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if Event.What = evCommand then
  begin
    case Event.Command of
      cmAbout: ShowAbout;
      cmFileNew:
        begin
          { Mirrors MainForm.FileNewClick: stop and drain the engine before
            NewProject frees every sample's memory out from under it (see
            WaitForEngineIdle), same protocol Open now follows too. }
          AudioEngineStop;
          if WaitForEngineIdle then
          begin
            Project.NewProject;
            EnsureDysTrackCount(DysStartTrackCount);
            CurrentProjectPath := '';
            RefreshAfterProjectChange;
          end
          else
            MessageBox('The audio engine stopped responding, so nothing ' +
              'was reset.', nil, mfError or mfOKButton);
        end;
      cmFileOpen:
        DoFileOpen;
      cmFileSave:
        DoFileSave;
      cmFileSaveAs:
        DoFileSaveAs;
      cmFileExport:
        MessageBox('Export is not wired yet - project load/save is future work.',
          nil, mfInformation or mfOKButton);
      cmEditCopy:
        if Timeline <> nil then
          Timeline^.Content^.CopyClipUnderCursor;
      cmEditPaste:
        if Timeline <> nil then
          Timeline^.Content^.PasteClipAtCursor;
      cmEditDuplicate:
        if Timeline <> nil then
          Timeline^.Content^.DuplicateClipUnderCursor;
      cmEditSplit:
        if Timeline <> nil then
          Timeline^.Content^.SplitClipUnderCursor;
      cmEditDelete:
        if Timeline <> nil then
          Timeline^.Content^.DeleteClipUnderCursor;
      cmEditPreferences:
        ShowPreferencesDialog;
    else
      Exit;
    end;
    ClearEvent(Event);
  end;
end;

end.
