unit DysMptiApp;

{ MPTI-frontend replacement for the main Dysnomia DAW (mpti.md). This is
  NOT the Tracker (DysTrackerApp), NOT the Control Station
  (DysControlStationApp), and NOT the launcher (DysLauncher) - all three
  stay on Free Vision, per the conversion scope. Only the main DAW shell
  that used to be TDysnomiaApp (DysnomiaApp.pas) is being ported here,
  in stages.

  Stage 2 (this file): transport bar (tempo + play/stop), file browser
  (directory listing -> decode -> drop a pending clip), the timeline
  canvas (pending-clip flash, arrow-key move, Enter to solidify, Esc to
  cancel, committed clips as solid bars with a left index strip), and
  the track pane (track selection, shared with the timeline's own
  cursor track). Tab/Shift+Tab cycle focus between all four; Alt+X quits
  from anywhere. Enough to drop a clip on a track and press Play.

  Deliberately NOT ported yet: metronome/record/interval/track-height
  toolbar controls, mute/solo, effects rack, waveform pane, warp/loop/
  copy-paste editing, project load/save dialogs. DysnomiaApp.pas,
  DysWidgets.pas, DysEffectsRack.pas, DysFilePane.pas, DysTrackPane.pas,
  DysTimeline.pas, DysFileDialog.pas stay in place, untouched, as
  read-only reference for porting the rest in later stages - they are no
  longer instantiated by dysnomia.lpr's DAW path, but nothing here
  modifies or removes them.

  Generic, reusable UI conventions (Tab/Shift+Tab pane focus is the
  underlying key decode, box-drawing pane borders) belong in MPTI itself
  (src/mpti) so every MPTI app gets them - see MptiInput's CSI-Z decode
  and MptiWidgets.MDrawPane. Anything DAW-specific (clips, tracks, the
  timeline canvas, the transport) stays here in Dysnomia's own code. }

{$mode objfpc}{$H+}

interface

procedure RunDysnomiaMpti;

implementation

uses
  SysUtils, BaseUnix,
  MptiTypes, MptiCell, MptiCaps, MptiInput, MptiDriver, MptiRender,
  MptiCore, MptiLayout, MptiWidgets,
  Config, AudioEngine, Project, SampleTypes, WavDecoder, ProjectFile, DysRemoteServer;

const
  { Same numbers as DysGeometry's constants (src/tui/DysGeometry.pas) -
    duplicated rather than imported because DysGeometry's own
    ComputeLayout returns an Objects.TRect, and pulling in Objects for
    just these constants isn't worth a dependency this unit otherwise
    doesn't need. Keep these in sync with DysGeometry.pas by hand until
    the old FV shell is retired. }
  MinCols = 100;
  MinRows = 40;
  FilePaneWidth = 24;
  TrackPaneWidth = 8;
  ToolBarHeight = 3;
  BottomBarHeight = (FilePaneWidth * 2) div 3;

  DysStartTrackCount = 8;

  MenuBarRow = 0;
  StatusLineText = '~Alt-X~ Exit   ~Tab~ Next pane   ~Shift-Tab~ Prev pane   ~F10~ Menu';

  { Same starting point as DysFilePane.DefaultBrowseDir. }
  DefaultBrowseDir = '/NFS/Music/Production';

  DefaultPixelsPerSecond = 10;
  TimelineLabelWidth = 4;
  BlockChar = $2588; { solid full block }

type
  TStringArray = array of string;

  TDysMptiLayout = record
    TooSmall: Boolean;
    Cols, Rows: Integer;
    ToolBar, FilePane, TrackPane, Timeline, BottomBar: TMRect;
  end;

  { ModalKind gates the whole main loop: while it's non-zero the four dock
    panes and the menu bar stop consuming Events entirely (see
    RunDysnomiaMpti) and only the modal's own draw+handle procedure does -
    the same "one thing owns input this frame" rule a real modal dialog
    needs, done by hand since MPTI has no TDialog/ExecView of its own. }
  TDysModalKind = (dmNone, dmFileDialog, dmPreferences);
  TDysFileDialogMode = (dfmOpen, dfmSaveAs);

  TDysAppState = record
    { Shared cursor: which track a dropped clip lands on, and which
      track's row the timeline highlights - one field, not the two
      independent cursors DysTrackPane/DysTimeline used to keep (see
      this file's header comment - fresh implementation, no need to
      replicate that split). }
    CursorTrack: Integer;
    CursorFrame: Int64;
    Pending: Boolean;
    PendingSampleID: Integer;
    PendingLength: Int64;
    FramesPerCol: Int64;
    ViewStartFrame: Int64;
    FileCurDir: string;
    FileEntries: array of string;
    FileSelected, FileScroll: Integer;
    TrackScroll: Integer;
    TempoText: string;
    CurrentProjectPath: string;
    StatusMessage: string;

    { Grid step (Left/Right, and the pending/resize/move edit states below)
      - cycled by the transport bar's interval button, same IntervalNames/
      IntervalIdx shape as DysWidgets.TDysToolBar. }
    IntervalIdx: Integer;

    { Transport loop range, -1 = unset - mirrors DysTimeline's own
      LoopStart/LoopEnd (the 'l' key). }
    LoopStart, LoopEnd: Int64;

    { Shift+W: interactive re-warp of the clip under the cursor - mirrors
      DysTimeline's ResizeActive/ResizeTrack/ResizeClipIndex/ResizeLength. }
    ResizeActive: Boolean;
    ResizeTrack, ResizeClipIndex: Integer;
    ResizeLength: Int64;

    { One random colour per track slot, assigned once at startup - mirrors
      DysTimeline's own TrackColors (session-only, not saved to the
      project). }
    TrackColors: array[0..Project.MaxTracks - 1] of TMColor;

    ModalKind: TDysModalKind;

    { File dialog (Open / Save As) - one shared modal, DysFileDialog's own
      TDysFileDialogMode split ported straight across (src/tui, read-only
      reference). FocusIdx: 0 = the list, 1 = the Name field. }
    FDMode: TDysFileDialogMode;
    FDCurDir: string;
    FDEntries: array of string;
    FDSelected, FDScroll: Integer;
    FDNameText: string;
    FDFocusIdx: Integer;

    { Preferences - one text/radio field per DysPreferences.pas row,
      FocusIdx 0..8 in the same top-to-bottom order they're drawn. }
    PrefFocusIdx: Integer;
    PrefBackend: Integer;
    PrefOutputDev, PrefInputDev: string;
    PrefSampleRate: string;
    PrefBufferSize: string;
    PrefSP1200: Integer;
    PrefInputBuf: string;
    PrefInputGain: string;
    PrefTheme: Integer;
  end;

function ComputeDysMptiLayout(Cols, Rows: Integer): TDysMptiLayout;
var
  BodyTop, BodyBottom, BodyHeight: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Cols := Cols;
  Result.Rows := Rows;
  { Menu bar (row 0) and status line (last row) are carved out here,
    same as TApplication did for TDysnomiaApp before ComputeLayout ran. }
  BodyTop := 1;
  BodyBottom := Rows - 1;
  BodyHeight := BodyBottom - BodyTop;
  Result.TooSmall := (Cols < MinCols) or (Rows < MinRows) or (BodyHeight < ToolBarHeight + BottomBarHeight + 3);
  if Result.TooSmall then
    Exit;

  Result.ToolBar := MMakeRect(0, BodyTop, Cols, ToolBarHeight);
  BodyTop := BodyTop + ToolBarHeight;
  BodyBottom := Rows - 1 - BottomBarHeight;

  Result.BottomBar := MMakeRect(0, BodyBottom, Cols, BottomBarHeight);
  Result.FilePane := MMakeRect(0, BodyTop, FilePaneWidth, BodyBottom - BodyTop);
  Result.TrackPane := MMakeRect(Cols - TrackPaneWidth, BodyTop, TrackPaneWidth, BodyBottom - BodyTop);
  Result.Timeline := MMakeRect(FilePaneWidth, BodyTop, Cols - TrackPaneWidth - FilePaneWidth, BodyBottom - BodyTop);
end;

procedure EnsureDysTrackCount(ACount: Integer);
begin
  while Project.TrackCount < ACount do
    if not Project.AddTrack then
      Break;
end;

procedure DrawText(var Buf: TCellBuffer; X, Y: Integer; const S: string;
  Fg, Bg: TMColor; Style: TMCellStyle);
var
  I, CX, W: Integer;
begin
  CX := X;
  for I := 1 to Length(S) do
  begin
    W := MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX, Y, Ord(S[I]), Fg, Bg, Style);
    Inc(CX, W);
  end;
end;

procedure DrawText(var Buf: TCellBuffer; X, Y: Integer; const S: string);
begin
  DrawText(Buf, X, Y, S, MDefaultFg, MDefaultBg, []);
end;

procedure DrawPaneAt(var Buf: TCellBuffer; const R: TMRect; const Title: string);
begin
  if MRectEmpty(R) then
    Exit;
  MDrawPane(Buf, R.X, R.Y, R.W, R.H, Title);
end;

procedure ShowTooSmall(var Buf: TCellBuffer; Cols, Rows: Integer);
begin
  DrawText(Buf, 2, 2, 'Resize to at least ' + IntToStr(MinCols) + 'x' +
    IntToStr(MinRows) + ' - currently ' + IntToStr(Cols) + 'x' + IntToStr(Rows));
end;

{ Alt+X, matching the old TDysnomiaApp's own cmQuit binding (File > Exit,
  kbAltX). }
function IsQuitKey(const Ev: TMInputEvent): Boolean;
begin
  Result := (Ev.Kind = mekKey) and (Ev.Key.Code = mkChar) and
    (Ev.Key.CodePoint = Ord('x')) and (kmAlt in Ev.Key.Mods);
end;

function EventIsFocusPaneKey(const Ev: TMInputEvent; out Backward: Boolean): Boolean;
begin
  Result := (Ev.Kind = mekKey) and (Ev.Key.Code = mkTab);
  Backward := Result and (kmShift in Ev.Key.Mods);
end;

const
  MnFile = 0;
  MnEdit = 1;
  MnHelp = 2;

  FiNew = 0;
  FiOpen = 1;
  FiSave = 2;
  FiSaveAs = 3;
  FiExit = 4;

  FileMenuItems: array[0..4] of string = ('New', 'Open...', 'Save', 'Save As...', 'Exit');
  EditMenuItems: array[0..0] of string = ('Preferences...');
  HelpMenuItems: array[0..0] of string = ('About');

  IntervalNames: array[0..3] of string = ('1/4', '1/8', '1/16', '1bar');

  { One random colour per track, drawn from a small saturated RGB palette -
    mirrors DysTimeline's own 8-entry CGA-ish TrackColorPalette, just as
    real RGB triples instead of 4-bit CGA indices (MPTI's TCell has no such
    limit - see mpti.md §2). }
  TrackColorPalette: array[0..7] of array[0..2] of Byte = (
    (220, 90, 90), (90, 200, 120), (90, 150, 220), (210, 190, 80),
    (190, 100, 210), (90, 200, 200), (220, 140, 70), (150, 150, 230)
  );
  { The clip's own leading column, always - see DrawClipSpan. Dark grey,
    not black, so it reads as "a seam" against every track colour rather
    than a gap of silence. }
  ClipStartColor: array[0..2] of Byte = (70, 70, 70);

{ Frames per bar at the project's current tempo (hardcoded 4/4, same
  simplification DysTimeline.BarFrames made - Project.pas has no time
  signature field). Used to derive a sensible grid step for Left/Right
  clip nudging. }
function BarFrames: Int64;
begin
  if Project.TempoBPM <= 0 then
    Result := 0
  else
    Result := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM) * 4;
end;

function GridStepFrames(const State: TDysAppState): Int64;
var
  Frames: Int64;
begin
  Frames := BarFrames;
  if Frames <= 0 then
    Result := State.FramesPerCol
  else
    case State.IntervalIdx of
      0: Result := Frames div 4;  { 1/4 }
      1: Result := Frames div 8;  { 1/8 }
      2: Result := Frames div 16; { 1/16 }
      3: Result := Frames;        { 1 bar }
    else
      Result := Frames div 4;
    end;
  if Result <= 0 then
    Result := State.FramesPerCol;
  if Result <= 0 then
    Result := 1;
end;

{ Rebuilds a TPlaybackClip array straight from Project.Tracks[ATrackIndex]
  and hands it to the engine - a deliberately trimmed copy of
  DysTimeline.PushTrackToEngine (src/tui, read-only reference): transients/
  period detection aren't reachable from this stage (Tones/Audio warp
  modes never get created here), so those fields stay zeroed. Warp markers
  ARE translated (needed by WarpClipToLength/Shift+W's WarpModeRePitch
  clips). AudioEngineSetTrackClips takes ownership of Items (pushed through
  the command ring - see AudioEngine.pas), so this never frees it itself,
  same as the reference implementation. }
procedure PushTrackToEngineSimple(ATrackIndex: Integer);
var
  Items: PPlaybackClip;
  I, J, Count, MarkerCount: Integer;
  Clip: TClip;
  Sample: TSample;
begin
  Count := Length(Project.Tracks[ATrackIndex].Clips);
  if Count = 0 then
    Items := nil
  else
    GetMem(Items, Count * SizeOf(TPlaybackClip));

  for I := 0 to Count - 1 do
  begin
    Clip := Project.Tracks[ATrackIndex].Clips[I];
    FillChar(Items[I], SizeOf(TPlaybackClip), 0);
    if Clip.SampleID <= High(Project.SamplePool) then
    begin
      Sample := Project.SamplePool[Clip.SampleID];
      Items[I].Data := Sample.Data;
      Items[I].FrameCount := Sample.FrameCount;
      Items[I].Channels := Sample.Channels;
    end;
    Items[I].Offset := Clip.Offset;
    Items[I].Length := Clip.Length;
    Items[I].Position := Clip.Position;
    Items[I].Gain := Clip.Gain;
    Items[I].WarpMode := Clip.WarpMode;
    Items[I].DetuneSemitones := Clip.PitchSemitones;

    MarkerCount := Length(Clip.WarpMarkers);
    if MarkerCount > MaxClipWarpMarkers then
      MarkerCount := MaxClipWarpMarkers;
    Items[I].MarkerCount := MarkerCount;
    for J := 0 to MarkerCount - 1 do
    begin
      Items[I].MarkerSource[J] := Clip.WarpMarkers[J].SourceFrame;
      Items[I].MarkerTimeline[J] := Clip.WarpMarkers[J].TimelineFrame;
    end;
  end;

  AudioEngineSetTrackClips(ATrackIndex, Items, Count);
end;

function SnapToGrid(AValue, AStep: Int64): Int64;
begin
  if AStep <= 0 then
  begin
    Result := AValue;
    Exit;
  end;
  Result := ((AValue + (AStep div 2)) div AStep) * AStep;
end;

{ The clip on ATrack whose span covers AFrame, or -1 - same lookup
  DysTimeline.ClipIndexAtFrame does. }
function ClipIndexAtFrame(ATrack: Integer; AFrame: Int64): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(Project.Tracks[ATrack].Clips) do
    if (AFrame >= Project.Tracks[ATrack].Clips[I].Position) and
       (AFrame < Project.Tracks[ATrack].Clips[I].Position + Project.Tracks[ATrack].Clips[I].Length) then
      Exit(I);
end;

{ Re-samples a clip to ATargetLength via a two-WarpMarker RePitch span -
  ported straight from DysTimeline.WarpClipToLength (src/tui, read-only
  reference; see its own comment for why ClipSourceLength, not .Length, is
  the correct source span to warp from). Shift+W's interactive resize
  (ResizeActive) is the only caller in this stage - plain 'w' (warp to
  nearest power-of-two bar) wasn't requested and isn't ported yet. }
procedure WarpClipToLength(ATrack, AClipIndex: Integer; ATargetLength: Int64);
var
  SourceLength: Int64;
begin
  if (AClipIndex < 0) or (ATargetLength <= 0) then
    Exit;
  SourceLength := Project.ClipSourceLength(Project.Tracks[ATrack].Clips[AClipIndex]);
  if SourceLength <= 0 then
    Exit;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMode := SampleTypes.WarpModeRePitch;
  SetLength(Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers, 2);
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[0].SourceFrame := 0;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[0].TimelineFrame := 0;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[1].SourceFrame := SourceLength;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[1].TimelineFrame := ATargetLength;
  Project.Tracks[ATrack].Clips[AClipIndex].Length := ATargetLength;
  PushTrackToEngineSimple(ATrack);
end;

{ Plain insertion sort, case-insensitive - same shape as DysFilePane's own
  SortStrings, copied rather than shared (that unit stays FV-coupled/
  read-only per this file's header comment). }
procedure SortStrings(var A: array of string; Count: Integer);
var
  I, J: Integer;
  Tmp: string;
begin
  for I := 1 to Count - 1 do
  begin
    Tmp := A[I];
    J := I - 1;
    while (J >= 0) and (CompareText(A[J], Tmp) > 0) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := Tmp;
  end;
end;

function MatchesExt(const Name: string; const Exts: array of string): Boolean;
var
  Ext: string;
  I: Integer;
begin
  Ext := LowerCase(ExtractFileExt(Name));
  Result := False;
  for I := 0 to High(Exts) do
    if Ext = Exts[I] then
      Exit(True);
end;

{ Shared directory-scan core behind both the file pane's sample browser and
  the Open/Save As dialog's project browser - the two were near-identical
  copies (DysFilePane.TDysFileListBox.Reload / DysFileDialog.
  TDysBrowseListBox.Reload, both read-only reference now), differing only
  in which extensions they keep. }
function ScanDirEntries(const Dir: string; const Exts: array of string): TStringArray;
var
  SR: TSearchRec;
  Dirs, Files: array of string;
  DirCount, FileCount, I: Integer;
begin
  DirCount := 0;
  FileCount := 0;
  Dirs := nil;
  Files := nil;

  if FindFirst(Dir + '*', faDirectory, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and ((SR.Attr and faDirectory) <> 0) then
      begin
        SetLength(Dirs, DirCount + 1);
        Dirs[DirCount] := SR.Name + '/';
        Inc(DirCount);
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;

  if FindFirst(Dir + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if ((SR.Attr and faDirectory) = 0) and MatchesExt(SR.Name, Exts) then
      begin
        SetLength(Files, FileCount + 1);
        Files[FileCount] := SR.Name;
        Inc(FileCount);
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;

  SortStrings(Dirs, DirCount);
  SortStrings(Files, FileCount);

  SetLength(Result, 1 + DirCount + FileCount);
  Result[0] := '..';
  for I := 0 to DirCount - 1 do
    Result[1 + I] := Dirs[I];
  for I := 0 to FileCount - 1 do
    Result[1 + DirCount + I] := Files[I];
end;

procedure ReloadFileEntries(var State: TDysAppState);
begin
  State.FileEntries := ScanDirEntries(State.FileCurDir, ['.wav', '.aiff']);
  State.FileSelected := 0;
  State.FileScroll := 0;
end;

procedure ReloadFDEntries(var State: TDysAppState);
begin
  State.FDEntries := ScanDirEntries(State.FDCurDir,
    [ProjectFile.ProjectExt, ProjectFile.StandaloneProjectExt]);
  State.FDSelected := 0;
  State.FDScroll := 0;
end;

{ Enter on the file listing: '..'/a directory navigates, a sample file
  decodes and becomes a pending (flashing, not-yet-committed) clip on
  State.CursorTrack at State.CursorFrame - the same "hand off to the
  timeline" shape DysFilePane.TDysFileListBox.SelectItem used, just
  without a modal MessageBox on decode failure (no message-box widget
  exists yet in MPTI - silently ignored, same effective outcome). }
procedure ActivateFileEntry(var State: TDysAppState);
var
  Name, FullPath: string;
  Sample: TSample;
begin
  if (State.FileSelected < 0) or (State.FileSelected > High(State.FileEntries)) then
    Exit;
  Name := State.FileEntries[State.FileSelected];
  if Name = '..' then
  begin
    State.FileCurDir := IncludeTrailingPathDelimiter(
      ExtractFileDir(ExcludeTrailingPathDelimiter(State.FileCurDir)));
    ReloadFileEntries(State);
  end
  else if (Length(Name) > 0) and (Name[Length(Name)] = '/') then
  begin
    State.FileCurDir := State.FileCurDir + Name;
    ReloadFileEntries(State);
  end
  else
  begin
    FullPath := State.FileCurDir + Name;
    if DecodeSampleFile(FullPath, Sample) then
    begin
      State.PendingSampleID := Project.AddSampleToPool(Sample, Name, FullPath);
      State.PendingLength := Sample.FrameCount;
      State.Pending := True;
    end;
  end;
end;

procedure CancelPending(var State: TDysAppState);
begin
  State.Pending := False;
  State.PendingSampleID := -1;
end;

{ Enter while a clip is pending: commits it to Project at CursorFrame/
  CursorTrack and pushes the track to the engine immediately, same two
  steps DysTimeline.PlaceOverlay took. }
procedure SolidifyPending(var State: TDysAppState);
var
  NewClip: TClip;
begin
  if not State.Pending then
    Exit;
  FillChar(NewClip, SizeOf(NewClip), 0);
  NewClip.SampleID := State.PendingSampleID;
  NewClip.Offset := 0;
  NewClip.Length := State.PendingLength;
  NewClip.Position := State.CursorFrame;
  NewClip.TrackID := State.CursorTrack;
  NewClip.Gain := 1.0;
  NewClip.PitchSemitones := 0;
  NewClip.WarpMode := SampleTypes.WarpModeBeats;
  Project.CommitClipToTrack(State.CursorTrack, NewClip);
  PushTrackToEngineSimple(State.CursorTrack);
  CancelPending(State);
end;

{ Bounded busy-wait for the engine to drain, mirroring TDysnomiaApp.
  WaitForEngineIdle (src/tui, read-only reference): a queued AudioEngineStop
  hasn't necessarily drained the playback thread yet, and New/Load free
  every sample's memory - freeing it out from under a thread still reading
  it is a use-after-free, not just a cosmetic race. Bounded rather than an
  unguarded loop, same reasoning as the reference implementation's own
  comment on the disaster case this avoids. }
function WaitForEngineIdle: Boolean;
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

{ Common to New/Open: every pane's own idea of "current state" (cursor,
  pending clip, tempo display) can be stale after the project underneath
  it changed size or vanished, and the engine needs every track's clips
  pushed fresh - mirrors TDysnomiaApp.RefreshAfterProjectChange (src/tui),
  trimmed to what this stage actually has (no timeline scroll/loop-marker
  state yet to reset). }
procedure RefreshAfterProjectChange(var State: TDysAppState);
var
  I: Integer;
begin
  AudioEngineSeek(0);
  AudioEngineClearLoop;
  for I := 0 to Project.MaxTracks - 1 do
    AudioEngineSetTrackClips(I, nil, 0);
  for I := 0 to Project.TrackCount - 1 do
    PushTrackToEngineSimple(I);
  State.CursorTrack := 0;
  State.CursorFrame := 0;
  State.ViewStartFrame := 0;
  CancelPending(State);
  State.TempoText := IntToStr(Round(Project.TempoBPM));
end;

procedure DoFileNew(var State: TDysAppState);
begin
  AudioEngineStop;
  if not WaitForEngineIdle then
  begin
    State.StatusMessage := 'The audio engine stopped responding - nothing was reset.';
    Exit;
  end;
  Project.NewProject;
  EnsureDysTrackCount(DysStartTrackCount);
  State.CurrentProjectPath := '';
  RefreshAfterProjectChange(State);
  State.StatusMessage := 'New project.';
end;

procedure DoFileOpenBegin(var State: TDysAppState);
var
  StartDir: string;
begin
  if State.CurrentProjectPath <> '' then
    StartDir := ExtractFileDir(State.CurrentProjectPath)
  else
    StartDir := DefaultBrowseDir;
  State.FDMode := dfmOpen;
  State.FDCurDir := IncludeTrailingPathDelimiter(StartDir);
  State.FDNameText := '';
  State.FDFocusIdx := 0;
  ReloadFDEntries(State);
  State.ModalKind := dmFileDialog;
end;

procedure DoFileSaveAsBegin(var State: TDysAppState);
var
  StartDir, StartName: string;
begin
  if State.CurrentProjectPath <> '' then
  begin
    StartDir := ExtractFileDir(State.CurrentProjectPath);
    StartName := ExtractFileName(State.CurrentProjectPath);
  end
  else
  begin
    StartDir := DefaultBrowseDir;
    StartName := '';
  end;
  State.FDMode := dfmSaveAs;
  State.FDCurDir := IncludeTrailingPathDelimiter(StartDir);
  State.FDNameText := StartName;
  State.FDFocusIdx := 0;
  ReloadFDEntries(State);
  State.ModalKind := dmFileDialog;
end;

procedure DoFileSave(var State: TDysAppState);
begin
  if State.CurrentProjectPath = '' then
  begin
    DoFileSaveAsBegin(State);
    Exit;
  end;
  if not ProjectFile.SaveProject(State.CurrentProjectPath) then
    State.StatusMessage := 'Could not save "' + State.CurrentProjectPath + '".'
  else
    State.StatusMessage := 'Saved ' + State.CurrentProjectPath;
end;

{ A bare name with no extension of its own defaults to a normal (non-
  standalone) project - same rule DysFileDialog.RunFileDialog used. }
function BuildFDPath(const State: TDysAppState; const NameIn: string): string;
var
  Name: string;
begin
  Name := Trim(NameIn);
  if Name = '' then
  begin
    Result := '';
    Exit;
  end;
  if (LowerCase(ExtractFileExt(Name)) <> ProjectFile.ProjectExt) and
     (LowerCase(ExtractFileExt(Name)) <> ProjectFile.StandaloneProjectExt) then
    Name := Name + ProjectFile.ProjectExt;
  Result := State.FDCurDir + Name;
end;

procedure ConfirmFileDialog(var State: TDysAppState);
var
  Path: string;
begin
  Path := BuildFDPath(State, State.FDNameText);
  if Path = '' then
    Exit;
  case State.FDMode of
    dfmOpen:
      begin
        AudioEngineStop;
        if not WaitForEngineIdle then
          State.StatusMessage := 'The audio engine stopped responding - nothing was opened.'
        else if not ProjectFile.LoadProject(Path) then
          State.StatusMessage := 'Could not open "' + Path + '" as an Eris project.'
        else
        begin
          State.CurrentProjectPath := Path;
          RefreshAfterProjectChange(State);
          State.StatusMessage := 'Opened ' + Path;
        end;
      end;
    dfmSaveAs:
      begin
        if not ProjectFile.SaveProject(Path) then
          State.StatusMessage := 'Could not save "' + Path + '".'
        else
        begin
          State.CurrentProjectPath := Path;
          State.StatusMessage := 'Saved ' + Path;
        end;
      end;
  end;
  State.ModalKind := dmNone;
end;

{ Enter on the file list: '..'/a directory navigates; a project file fills
  the Name field and immediately confirms - same shape as DysFileDialog's
  own TDysBrowseListBox.SelectItem. }
procedure ActivateFDEntry(var State: TDysAppState);
var
  Name: string;
begin
  if (State.FDSelected < 0) or (State.FDSelected > High(State.FDEntries)) then
    Exit;
  Name := State.FDEntries[State.FDSelected];
  if Name = '..' then
  begin
    State.FDCurDir := IncludeTrailingPathDelimiter(
      ExtractFileDir(ExcludeTrailingPathDelimiter(State.FDCurDir)));
    ReloadFDEntries(State);
  end
  else if (Length(Name) > 0) and (Name[Length(Name)] = '/') then
  begin
    State.FDCurDir := State.FDCurDir + Name;
    ReloadFDEntries(State);
  end
  else
  begin
    State.FDNameText := Name;
    ConfirmFileDialog(State);
  end;
end;

function ModalRect(ScreenW, ScreenH, W, H: Integer): TMRect;
begin
  if W > ScreenW then
    W := ScreenW;
  if H > ScreenH then
    H := ScreenH;
  Result := MMakeRect((ScreenW - W) div 2, (ScreenH - H) div 2, W, H);
end;

{ Open/Save As modal - draws on top of whatever the main loop already drew
  this frame and is the ONLY thing that gets to consume Events while it's
  up (see RunDysnomiaMpti's ModalKind gate). }
procedure DrawFileDialogFrame(var Core: TMCoreState; var HR: TMHitRegistry;
  var Buf: TCellBuffer; var State: TDysAppState; const Events: TMInputEventArray);
var
  R: TMRect;
  Title: string;
  ListID, NameID: TMWidgetID;
  I: Integer;
  Backward: Boolean;
begin
  R := ModalRect(Buf.Width, Buf.Height, 64, 22);
  if State.FDMode = dfmOpen then
    Title := 'Open Project'
  else
    Title := 'Save Project As';
  MDrawPane(Buf, R.X, R.Y, R.W, R.H, Title);
  DrawText(Buf, R.X + 2, R.Y + 1, Copy(State.FDCurDir, 1, R.W - 4));

  ListID := MWidgetID('filedlg/list');
  NameID := MWidgetID('filedlg/name');

  for I := 0 to High(Events) do
    if EventIsFocusPaneKey(Events[I], Backward) then
      State.FDFocusIdx := (State.FDFocusIdx + 1) mod 2;
  if State.FDFocusIdx = 1 then
    MSetFocus(Core, NameID, NameID)
  else
    MSetFocus(Core, ListID, ListID);

  MListView(Core, HR, Buf, 'filedlg/list', ListID, R.X + 2, R.Y + 2, R.W - 4, R.H - 7,
    State.FDEntries, State.FDSelected, State.FDScroll, Events);
  if MIsFocused(Core, ListID) then
    for I := 0 to High(Events) do
      if (Events[I].Kind = mekKey) and (Events[I].Key.Code = mkEnter) then
        ActivateFDEntry(State);

  DrawText(Buf, R.X + 2, R.Y + R.H - 4, 'Name:');
  MTextInput(Core, HR, Buf, 'filedlg/name', NameID, R.X + 8, R.Y + R.H - 4, R.W - 10,
    State.FDNameText, Events);
  if MIsFocused(Core, NameID) then
    for I := 0 to High(Events) do
      if (Events[I].Kind = mekKey) and (Events[I].Key.Code = mkEnter) then
        ConfirmFileDialog(State);

  if MButton(Core, HR, Buf, 'filedlg/ok', ListID, R.X + 2, R.Y + R.H - 2, 'OK', Events) then
    ConfirmFileDialog(State);
  if MButton(Core, HR, Buf, 'filedlg/cancel', ListID, R.X + 14, R.Y + R.H - 2, 'Cancel', Events) then
    State.ModalKind := dmNone;

  for I := 0 to High(Events) do
    if (Events[I].Kind = mekKey) and (Events[I].Key.Code = mkEscape) then
      State.ModalKind := dmNone;
end;

procedure DoShowPreferences(var State: TDysAppState);
begin
  State.PrefBackend := AudioEngineGetBackend;
  State.PrefOutputDev := AudioEngineGetPipeWireOutputDevice;
  State.PrefInputDev := AudioEngineGetPipeWireInputDevice;
  State.PrefSampleRate := IntToStr(Config.Cfg.SampleRate);
  State.PrefBufferSize := IntToStr(AudioEngineGetBufferSize);
  if AudioEngineGetSP1200Enabled then
    State.PrefSP1200 := 1
  else
    State.PrefSP1200 := 0;
  State.PrefInputBuf := IntToStr(AudioEngineGetInputBufferSize);
  State.PrefInputGain := IntToStr(Round(AudioEngineGetInputGainDb));
  State.PrefTheme := Config.Cfg.Theme;
  State.PrefFocusIdx := 0;
  State.ModalKind := dmPreferences;
end;

{ Same fields, same order/source as DysPreferences.ShowPreferencesDialog's
  own OK handler (src/tui, read-only reference) - reads config fields back
  from the engine rather than the edited text, so eris.conf only ever
  persists values that actually took effect; Sample Rate and Theme are the
  two exceptions (neither applies live), same as the reference. }
procedure ConfirmPreferences(var State: TDysAppState);
var
  N: Integer;
begin
  AudioEngineSetBackend(State.PrefBackend);
  if State.PrefBackend = AudioBackendPipeWire then
    AudioEngineSetPipeWireDevices(State.PrefOutputDev, State.PrefInputDev);
  if TryStrToInt(State.PrefSampleRate, N) then
    Config.Cfg.SampleRate := N;
  if TryStrToInt(State.PrefBufferSize, N) then
    AudioEngineSetBufferSize(N);
  AudioEngineSetSP1200Enabled(State.PrefSP1200 = 1);
  if TryStrToInt(State.PrefInputBuf, N) then
    AudioEngineSetInputBufferSize(N);
  if TryStrToInt(State.PrefInputGain, N) then
    AudioEngineSetInputGainDb(N);
  Config.Cfg.Theme := State.PrefTheme;

  Config.Cfg.BackendName := AudioEngineBackendNameFromKind(AudioEngineGetBackend);
  Config.Cfg.OutputDevice := AudioEngineGetPipeWireOutputDevice;
  Config.Cfg.InputDevice := AudioEngineGetPipeWireInputDevice;
  Config.Cfg.BufferSize := AudioEngineGetBufferSize;
  Config.Cfg.InputBufferSize := AudioEngineGetInputBufferSize;
  Config.Cfg.InputGainDb := Round(AudioEngineGetInputGainDb);
  ConfigSave;
  State.ModalKind := dmNone;
  State.StatusMessage := 'Preferences saved.';
end;

procedure DrawPreferencesFrame(var Core: TMCoreState; var HR: TMHitRegistry;
  var Buf: TCellBuffer; var State: TDysAppState; const Events: TMInputEventArray);
var
  R: TMRect;
  Y, I: Integer;
  ID: TMWidgetID;
  Backward: Boolean;

  { One text-input row: label, then the field itself. FieldIdx identifies
    this row's slot in the Tab order (PrefFocusIdx) - Core focus only
    follows it for the currently active field, since MTextInput needs a
    real Core-level focus to accept typed characters. }
  procedure TextRow(const Label_: string; var Text: string; const WidgetName: string; This: Integer);
  begin
    DrawText(Buf, R.X + 2, Y, Label_);
    Inc(Y);
    ID := MWidgetID(WidgetName);
    if State.PrefFocusIdx = This then
      MSetFocus(Core, ID, ID);
    MTextInput(Core, HR, Buf, WidgetName, ID, R.X + 2, Y, 20, Text, Events);
    Inc(Y, 2);
  end;

  { One radio-group row. MRadioGroup only reacts to mouse clicks on its own
    (see MptiWidgets.pas), so Up/Down keyboard navigation while this row
    is the active Tab stop is handled here by hand, straight against
    Selected - the same "self-check" shape MButton's own doc comment
    describes for widgets outside MPTI's stock set. }
  procedure RadioRow(const Label_: string; var Selected: Integer; const Labels: array of string;
    const WidgetName: string; This: Integer);
  var
    K: Integer;
  begin
    DrawText(Buf, R.X + 2, Y, Label_);
    Inc(Y);
    MRadioGroup(Core, HR, Buf, WidgetName, MWidgetID(WidgetName), R.X + 2, Y, Labels, Selected, Events);
    if State.PrefFocusIdx = This then
      for K := 0 to High(Events) do
        if Events[K].Kind = mekKey then
          case Events[K].Key.Code of
            mkUp: if Selected > 0 then Dec(Selected);
            mkDown: if Selected < High(Labels) then Inc(Selected);
          end;
    Inc(Y, Length(Labels) + 1);
  end;

begin
  R := ModalRect(Buf.Width, Buf.Height, 60, 28);
  MDrawPane(Buf, R.X, R.Y, R.W, R.H, 'Preferences');

  for I := 0 to High(Events) do
    if EventIsFocusPaneKey(Events[I], Backward) then
    begin
      if Backward then
        State.PrefFocusIdx := (State.PrefFocusIdx + 8) mod 9
      else
        State.PrefFocusIdx := (State.PrefFocusIdx + 1) mod 9;
    end;

  Y := R.Y + 1;
  RadioRow('Audio backend:', State.PrefBackend, ['ALSA', 'JACK', 'PipeWire'], 'prefs/backend', 0);
  TextRow('Output device (PipeWire only):', State.PrefOutputDev, 'prefs/outdev', 1);
  TextRow('Input device (PipeWire only):', State.PrefInputDev, 'prefs/indev', 2);
  TextRow('Sample rate (44100 / 48000 / 96000):', State.PrefSampleRate, 'prefs/samplerate', 3);
  TextRow('Buffer size (128-4096, power of two):', State.PrefBufferSize, 'prefs/buffersize', 4);
  RadioRow('SP-1200 (bit-crush):', State.PrefSP1200, ['Off', 'On'], 'prefs/sp1200', 5);
  TextRow('Input buffer size (128-4096):', State.PrefInputBuf, 'prefs/inputbuf', 6);
  TextRow('Input gain, dB (-24..24):', State.PrefInputGain, 'prefs/inputgain', 7);
  RadioRow('Theme:', State.PrefTheme, ['Follow system', 'Light', 'Dark'], 'prefs/theme', 8);

  if MButton(Core, HR, Buf, 'prefs/ok', MWidgetID('prefs/ok'), R.X + 2, R.Y + R.H - 2, 'OK', Events) then
    ConfirmPreferences(State);
  if MButton(Core, HR, Buf, 'prefs/cancel', MWidgetID('prefs/ok'), R.X + 14, R.Y + R.H - 2, 'Cancel', Events) then
    State.ModalKind := dmNone;

  for I := 0 to High(Events) do
    if (Events[I].Kind = mekKey) and (Events[I].Key.Code = mkEscape) then
      State.ModalKind := dmNone;
end;

{ Draws one clip span [APos, APos+ALen) in column space, plus the small
  black leading-edge strip (this file's own visual convention - not an
  MPTI-wide one, see the header comment) that marks where the clip
  actually starts so two same-coloured clips back to back still read as
  two clips, not one. }
procedure DrawClipSpan(var Buf: TCellBuffer; CX0, CY, CW: Integer;
  AFramesPerCol, AViewStart, APos, ALen: Int64; Fg, Bg: TMColor; Style: TMCellStyle);
var
  StartCol, EndCol, Col: Integer;
begin
  if (ALen <= 0) or (AFramesPerCol <= 0) then
    Exit;
  if APos + ALen <= AViewStart then
    Exit;
  StartCol := (APos - AViewStart) div AFramesPerCol;
  EndCol := (APos + ALen - 1 - AViewStart) div AFramesPerCol;
  if StartCol < 0 then
    StartCol := 0;
  if EndCol > CW - 1 then
    EndCol := CW - 1;
  if EndCol < StartCol then
    Exit;
  for Col := StartCol to EndCol do
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX0 + Col, CY, BlockChar, Fg, Bg, Style);
  { Leading-edge strip: only when the clip's true start column is itself
    visible (APos >= AViewStart) - a clip scrolled partway off the left
    edge shouldn't grow a fake strip at column 0. Dark grey (see
    ClipStartColor), not black, so it reads against every track's own
    random colour rather than looking like a gap of silence. }
  if APos >= AViewStart then
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX0 + StartCol, CY, BlockChar,
      MMakeColor(ClipStartColor[0], ClipStartColor[1], ClipStartColor[2]), Bg, Style);
end;

{ Column for an absolute frame position, or -1 if it's off the visible
  grid - shared by the playhead/loop-marker/cursor overlays below. }
function FrameToCol(AFrame: Int64; const State: TDysAppState; CW: Integer): Integer;
begin
  if State.FramesPerCol <= 0 then
    Exit(-1);
  Result := (AFrame - State.ViewStartFrame) div State.FramesPerCol;
  if (Result < 0) or (Result >= CW) then
    Result := -1;
end;

procedure DrawTimeline(var Buf: TCellBuffer; const R: TMRect; var State: TDysAppState;
  Focused: Boolean; NowMs: QWord);
var
  CX0, CY0, CW, CH, T, Row, I: Integer;
  Label_: string;
  LblFg, LblBg: TMColor;
  LblStyle: TMCellStyle;
  Clip: TClip;
  PlayCol, LoopStartCol, LoopEndCol, CursorCol: Integer;
  PosSec: Double;
  Header: string;
  FlashOn: Boolean;
  LoopColor: TMColor;
begin
  if (R.W < TimelineLabelWidth + 4) or (R.H < 3) then
    Exit;
  CX0 := R.X + 1 + TimelineLabelWidth;
  CY0 := R.Y + 1;
  CW := R.W - 2 - TimelineLabelWidth;
  CH := R.H - 2;
  if (CW < 1) or (CH < 2) then
    Exit;

  PosSec := State.CursorFrame / AudioEngine.ProjectSampleRate;
  Header := 'trk ' + IntToStr(State.CursorTrack + 1) + '  t=' +
    FormatFloat('0.00', PosSec) + 's  step=' + IntervalNames[State.IntervalIdx];
  if State.Pending then
    Header := Header + '  [PENDING: arrows move, Enter drops, Esc cancels]'
  else if State.ResizeActive then
    Header := Header + '  [WARP: arrows resize, Enter applies, Esc cancels]'
  else if AudioEngineIsPlaying then
    Header := Header + '  [playing]';
  DrawText(Buf, CX0 - TimelineLabelWidth, CY0, Header);

  FlashOn := (NowMs div 400) mod 2 = 0;

  for T := 0 to Project.TrackCount - 1 do
  begin
    Row := 1 + T;
    if Row >= CH then
      Break;

    Label_ := 'T' + IntToStr(T + 1);
    if T = State.CursorTrack then
    begin
      LblFg := MDefaultBg;
      LblBg := MDefaultFg;
      LblStyle := [];
    end
    else
    begin
      LblFg := MDefaultFg;
      LblBg := MDefaultBg;
      LblStyle := [];
    end;
    for I := 0 to TimelineLabelWidth - 1 do
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, R.X + 1 + I, CY0 + Row, 32,
        LblFg, LblBg, LblStyle);
    DrawText(Buf, R.X + 1, CY0 + Row, Label_, LblFg, LblBg, LblStyle);

    for I := 0 to High(Project.Tracks[T].Clips) do
    begin
      Clip := Project.Tracks[T].Clips[I];
      if (T = State.ResizeTrack) and (I = State.ResizeClipIndex) and State.ResizeActive then
        DrawClipSpan(Buf, CX0, CY0 + Row, CW, State.FramesPerCol, State.ViewStartFrame,
          Clip.Position, State.ResizeLength, MMakeColor(255, 210, 60), MDefaultBg, [csBold])
      else
        DrawClipSpan(Buf, CX0, CY0 + Row, CW, State.FramesPerCol, State.ViewStartFrame,
          Clip.Position, Clip.Length, State.TrackColors[T], MDefaultBg, []);
    end;

    if State.Pending and (T = State.CursorTrack) and FlashOn then
      DrawClipSpan(Buf, CX0, CY0 + Row, CW, State.FramesPerCol, State.ViewStartFrame,
        State.CursorFrame, State.PendingLength, MMakeColor(255, 210, 60), MDefaultBg, [csBold]);

    { Cursor indicator: only when there's nothing else already marking this
      exact spot (a pending/resizing clip already reads as "the cursor is
      here"), so plain cursor movement stays visible too. }
    if (T = State.CursorTrack) and not State.Pending and not State.ResizeActive then
    begin
      CursorCol := FrameToCol(State.CursorFrame, State, CW);
      if CursorCol >= 0 then
        MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX0 + CursorCol, CY0 + Row,
          Ord(' '), MDefaultFg, MDefaultBg, [csReverse]);
    end;
  end;

  { Loop markers, drawn on the header row (not per-track - keeps them out
    of the way of clip blocks, same simplification the header's own
    single-line summary already makes). }
  LoopColor := MMakeColor(120, 220, 140);
  if State.LoopStart >= 0 then
  begin
    LoopStartCol := FrameToCol(State.LoopStart, State, CW);
    if LoopStartCol >= 0 then
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX0 + LoopStartCol, CY0,
        Ord('L'), LoopColor, MDefaultBg, [csBold]);
  end;
  if State.LoopEnd >= 0 then
  begin
    LoopEndCol := FrameToCol(State.LoopEnd, State, CW);
    if LoopEndCol >= 0 then
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX0 + LoopEndCol, CY0,
        Ord('L'), LoopColor, MDefaultBg, [csBold]);
  end;

  if AudioEngineIsPlaying then
  begin
    PlayCol := FrameToCol(AudioEngineGetPosition, State, CW);
    if PlayCol >= 0 then
      for Row := 1 to CH - 1 do
        MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX0 + PlayCol, CY0 + Row,
          Ord('|'), MMakeColor(255, 80, 80), MDefaultBg, [csBold]);
  end;
end;

function TrackLabels(Count: Integer): TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
    Result[I] := 'Track ' + IntToStr(I + 1);
end;

procedure RunDysnomiaMpti;
var
  D: TMDriverState;
  RState: TMRenderState;
  Core: TMCoreState;
  HR: TMHitRegistry;
  Events: TMInputEventArray;
  Kind: TMDriverEventKind;
  Output: TMByteBuf;
  Quit: Boolean;
  I: Integer;
  Layout: TDysMptiLayout;
  MenuPaneID: TMWidgetID;
  TempoID, FileListID, TrackListID, TimelineID: TMWidgetID;
  OpenMenu: Integer;
  FileDropSel, EditDropSel, HelpDropSel: Integer;
  ShowFileDrop, ShowEditDrop, ShowHelpDrop: Boolean;
  State: TDysAppState;
  FocusIDs: array[0..3] of TMWidgetID;
  FocusIdx, NewFocusIdx: Integer;
  Backward: Boolean;
  TX, StopX, PlayX, IntervalX: Integer;
  R: TMRect;
  TempoVal: Double;
  TempoCode: Word;
  TimelineHit: TMRect;
  NowMs: QWord;
  PalIdx, ClipIdx: Integer;
  LoopCandidate: Int64;
begin
  ConfigLoad;
  AudioEngineInit;
  EnsureDysTrackCount(DysStartTrackCount);
  DysRemoteServerStart;
  try
    MInitDriver(D);
    if not MDriverHasTTY(D) then
    begin
      WriteLn('Dysnomia (MPTI) needs a real terminal.');
      Exit;
    end;

    D.Caps := MCapsFromEnv(GetEnvironmentVariable('TERM'), GetEnvironmentVariable('COLORTERM'));
    MEnableRawMode(D);
    MInstallResizeHandler(D);
    MEnableTerminalModes(D);
    try
      MInitRenderState(RState, D.Caps, D.Cols, D.Rows);
      MInitCore(Core);
      MenuPaneID := MWidgetID('dysnomia/menubar');
      TempoID := MWidgetID('toolbar/tempo');
      FileListID := MWidgetID('files/list');
      TrackListID := MWidgetID('tracks/list');
      TimelineID := MWidgetID('timeline/canvas');
      FocusIDs[0] := TempoID;
      FocusIDs[1] := FileListID;
      FocusIDs[2] := TimelineID;
      FocusIDs[3] := TrackListID;

      FillChar(State, SizeOf(State), 0);
      State.CursorTrack := 0;
      State.CursorFrame := 0;
      State.Pending := False;
      State.PendingSampleID := -1;
      State.FramesPerCol := AudioEngine.ProjectSampleRate div DefaultPixelsPerSecond;
      State.ViewStartFrame := 0;
      State.FileCurDir := IncludeTrailingPathDelimiter(DefaultBrowseDir);
      ReloadFileEntries(State);
      State.TempoText := IntToStr(Round(Project.TempoBPM));
      State.IntervalIdx := 2; { 1/16 - same default DysWidgets used }
      State.LoopStart := -1;
      State.LoopEnd := -1;
      State.ResizeActive := False;
      State.ResizeClipIndex := -1;
      { One random colour per track slot, all MaxTracks of them up front
        (not just Project.TrackCount's current value) so a track added
        later already has one waiting - same "Randomize once" shape
        DysTimeline.TDysTimelineContent.Init used for its own TrackColors. }
      Randomize;
      for I := 0 to High(State.TrackColors) do
      begin
        PalIdx := Random(Length(TrackColorPalette));
        State.TrackColors[I] := MMakeColor(TrackColorPalette[PalIdx][0],
          TrackColorPalette[PalIdx][1], TrackColorPalette[PalIdx][2]);
      end;

      { Same starting focus as TDysnomiaApp.Init's FilePane^.FocusPane. }
      MSetFocus(Core, FileListID, FileListID);

      State.CurrentProjectPath := '';

      Quit := False;
      ShowFileDrop := False;
      ShowEditDrop := False;
      ShowHelpDrop := False;

      while not Quit do
      begin
        SetLength(Events, 0);
        MRunOnce(D, 10, Events, Kind);
        if Kind = dekResize then
          MResizeRenderState(RState, D.Cols, D.Rows);

        for I := 0 to High(Events) do
          if IsQuitKey(Events[I]) then
            Quit := True;

        DysRemoteDrainQueue;

        MClearCellBuffer(RState.Back, MBlankCell);
        MBeginCoreFrame(Core);
        MBeginHitRegistry(HR);

        { Tab/Shift+Tab pane cycling - global, checked before any widget
          gets a chance to consume the key (none of them react to mkTab
          anyway, but this keeps the precedence explicit and matches
          Alt+X's own "global keys checked first" shape). Only while no
          modal owns input - a modal cycles its own fields instead (see
          DrawFileDialogFrame/DrawPreferencesFrame). }
        FocusIdx := -1;
        if State.ModalKind = dmNone then
        begin
          for I := 0 to 3 do
            if MIsFocused(Core, FocusIDs[I]) then
              FocusIdx := I;
          for I := 0 to High(Events) do
            if EventIsFocusPaneKey(Events[I], Backward) then
            begin
              if FocusIdx < 0 then
                NewFocusIdx := 0
              else if Backward then
                NewFocusIdx := (FocusIdx + 3) mod 4
              else
                NewFocusIdx := (FocusIdx + 1) mod 4;
              MSetFocus(Core, FocusIDs[NewFocusIdx], FocusIDs[NewFocusIdx]);
              FocusIdx := NewFocusIdx;
            end;
        end;

        Layout := ComputeDysMptiLayout(RState.Back.Width, RState.Back.Height);
        if Layout.TooSmall then
          ShowTooSmall(RState.Back, Layout.Cols, Layout.Rows)
        else
        begin
          if FocusIdx = 0 then
            DrawPaneAt(RState.Back, Layout.ToolBar, '» Transport «')
          else
            DrawPaneAt(RState.Back, Layout.ToolBar, 'Transport');
          if FocusIdx = 1 then
            DrawPaneAt(RState.Back, Layout.FilePane, '» Files «')
          else
            DrawPaneAt(RState.Back, Layout.FilePane, 'Files');
          if FocusIdx = 2 then
            DrawPaneAt(RState.Back, Layout.Timeline, '» Timeline «')
          else
            DrawPaneAt(RState.Back, Layout.Timeline, 'Timeline');
          if FocusIdx = 3 then
            DrawPaneAt(RState.Back, Layout.TrackPane, '» Trk «')
          else
            DrawPaneAt(RState.Back, Layout.TrackPane, 'Trk');
          DrawPaneAt(RState.Back, Layout.BottomBar, 'Effects / Waveform');

          { The four dock panes and the menu bar only get to consume
            Events while no modal is up - a modal is the only thing
            allowed to read input this frame (see DrawFileDialogFrame/
            DrawPreferencesFrame, and the Tab-cycling gate above). }
          if State.ModalKind = dmNone then
          begin
          { Transport: tempo field + Play/Stop. }
          R := Layout.ToolBar;
          TX := R.X + 1;
          DrawText(RState.Back, TX, R.Y + 1, 'Tempo:');
          TX := TX + 7;
          MTextInput(Core, HR, RState.Back, 'toolbar/tempo', TempoID,
            TX, R.Y + 1, 6, State.TempoText, Events);
          TX := TX + 7;
          for I := 0 to High(Events) do
            if (Events[I].Kind = mekKey) and (Events[I].Key.Code = mkEnter) and
               MIsFocused(Core, TempoID) then
            begin
              Val(State.TempoText, TempoVal, TempoCode);
              if TempoCode <> 0 then
                TempoVal := Project.DefaultTempoBPM;
              if TempoVal < 20 then
                TempoVal := 20
              else if TempoVal > 999 then
                TempoVal := 999;
              Project.TempoBPM := TempoVal;
              State.TempoText := IntToStr(Round(TempoVal));
            end;

          StopX := TX;
          if MButton(Core, HR, RState.Back, 'toolbar/stop', TempoID, StopX, R.Y + 1,
            'Stop', Events) then
          begin
            AudioEngineStop;
            AudioEngineSeek(0);
          end;
          PlayX := StopX + 8;
          if MButton(Core, HR, RState.Back, 'toolbar/play', TempoID, PlayX, R.Y + 1,
            'Play/Pause', Events) then
          begin
            if AudioEngineIsPlaying then
              AudioEngineStop
            else if AudioEngineHasClip then
            begin
              AudioEngineSeek(State.CursorFrame);
              AudioEnginePlay;
            end;
          end;

          { Grid-step interval, cycled on click - same "cycle on click,
            caption shows the current value" shape as DysWidgets'
            IntervalBtn. Drives GridStepFrames, which the timeline's own
            Left/Right (and Shift+W's resize) read every time they move. }
          IntervalX := PlayX + 13;
          if MButton(Core, HR, RState.Back, 'toolbar/interval', TempoID, IntervalX, R.Y + 1,
            IntervalNames[State.IntervalIdx], Events) then
            State.IntervalIdx := (State.IntervalIdx + 1) mod Length(IntervalNames);

          { File browser. }
          R := Layout.FilePane;
          MListView(Core, HR, RState.Back, 'files/list', FileListID,
            R.X + 1, R.Y + 1, R.W - 2, R.H - 2, State.FileEntries,
            State.FileSelected, State.FileScroll, Events);
          if MIsFocused(Core, FileListID) then
            for I := 0 to High(Events) do
              if (Events[I].Kind = mekKey) and (Events[I].Key.Code = mkEnter) then
                ActivateFileEntry(State);

          { Track pane: one row per track, Selected IS State.CursorTrack -
            single source of truth (see this file's header comment). }
          R := Layout.TrackPane;
          MListView(Core, HR, RState.Back, 'tracks/list', TrackListID,
            R.X + 1, R.Y + 1, R.W - 2, R.H - 2, TrackLabels(Project.TrackCount),
            State.CursorTrack, State.TrackScroll, Events);

          { Timeline canvas - self-checked against Events/HR the same
            pattern MButton's own doc comment describes, since this isn't
            a stock MPTI widget. }
          R := Layout.Timeline;
          TimelineHit := MMakeRect(R.X + 1, R.Y + 1, R.W - 2, R.H - 2);
          MRegisterHitRect(HR, TimelineID, TimelineID, TimelineHit);
          for I := 0 to High(Events) do
            if (Events[I].Kind = mekMouse) and (Events[I].Mouse.Action = maPress) and
               (Events[I].Mouse.Button = mbLeft) and
               MRectContains(TimelineHit, Events[I].Mouse.X, Events[I].Mouse.Y) then
              MSetFocus(Core, TimelineID, TimelineID);
          if MIsFocused(Core, TimelineID) then
            for I := 0 to High(Events) do
              if Events[I].Kind = mekKey then
                case Events[I].Key.Code of
                  mkUp:
                    if State.CursorTrack > 0 then
                      Dec(State.CursorTrack);
                  mkDown:
                    if State.CursorTrack < Project.TrackCount - 1 then
                      Inc(State.CursorTrack);
                  mkLeft:
                    if State.ResizeActive then
                    begin
                      Dec(State.ResizeLength, GridStepFrames(State));
                      if State.ResizeLength < GridStepFrames(State) then
                        State.ResizeLength := GridStepFrames(State);
                    end
                    else
                    begin
                      Dec(State.CursorFrame, GridStepFrames(State));
                      if State.CursorFrame < 0 then
                        State.CursorFrame := 0;
                    end;
                  mkRight:
                    if State.ResizeActive then
                      Inc(State.ResizeLength, GridStepFrames(State))
                    else
                      Inc(State.CursorFrame, GridStepFrames(State));
                  mkEnter:
                    if State.ResizeActive then
                    begin
                      WarpClipToLength(State.ResizeTrack, State.ResizeClipIndex, State.ResizeLength);
                      State.ResizeActive := False;
                    end
                    else
                      SolidifyPending(State);
                  mkEscape:
                    if State.ResizeActive then
                      State.ResizeActive := False
                    else
                      CancelPending(State);
                  mkChar:
                    case Events[I].Key.CodePoint of
                      Ord('l'), Ord('L'):
                        { Three-press cycle: start marker, end marker,
                          clear - ported from DysTimeline's own 'l' key. }
                        if State.LoopStart < 0 then
                          State.LoopStart := State.CursorFrame
                        else if State.LoopEnd < 0 then
                        begin
                          LoopCandidate := State.CursorFrame;
                          if LoopCandidate <= State.LoopStart then
                          begin
                            State.LoopEnd := State.LoopStart;
                            State.LoopStart := LoopCandidate;
                          end
                          else
                            State.LoopEnd := LoopCandidate;
                          AudioEngineSetLoop(State.LoopStart, State.LoopEnd);
                        end
                        else
                        begin
                          State.LoopStart := -1;
                          State.LoopEnd := -1;
                          AudioEngineClearLoop;
                        end;
                      Ord('W'):
                        { Start the interactive resize - starting length is
                          the clip's current length snapped to the grid, so
                          the first Left/Right press moves it by exactly one
                          grid step. Ported from DysTimeline's own 'W' key
                          (plain 'w' - warp straight to nearest power-of-two
                          bar - wasn't requested and isn't ported). }
                        begin
                          ClipIdx := ClipIndexAtFrame(State.CursorTrack, State.CursorFrame);
                          if ClipIdx >= 0 then
                          begin
                            State.ResizeActive := True;
                            State.ResizeTrack := State.CursorTrack;
                            State.ResizeClipIndex := ClipIdx;
                            State.ResizeLength := SnapToGrid(
                              Project.Tracks[State.CursorTrack].Clips[ClipIdx].Length, GridStepFrames(State));
                            if State.ResizeLength < GridStepFrames(State) then
                              State.ResizeLength := GridStepFrames(State);
                          end;
                        end;
                    end;
                end;

          { Menu bar / dropdowns. }
          OpenMenu := MMenuBar(Core, HR, RState.Back, 'dysnomia/menubar', MenuPaneID,
            0, MenuBarRow, ['File', 'Edit', 'Help'], Events);

          if OpenMenu = MnFile then
            ShowFileDrop := True
          else if OpenMenu <> MnFile then
            ShowFileDrop := False;
          if OpenMenu = MnEdit then
            ShowEditDrop := True
          else if OpenMenu <> MnEdit then
            ShowEditDrop := False;
          if OpenMenu = MnHelp then
            ShowHelpDrop := True
          else if OpenMenu <> MnHelp then
            ShowHelpDrop := False;

          if ShowFileDrop then
          begin
            FileDropSel := MDropdownList(Core, HR, RState.Back, 'dysnomia/filemenu',
              MenuPaneID, 0, MenuBarRow + 1, FileMenuItems, Events);
            case FileDropSel of
              FiNew: begin DoFileNew(State); ShowFileDrop := False; end;
              FiOpen: begin DoFileOpenBegin(State); ShowFileDrop := False; end;
              FiSave: begin DoFileSave(State); ShowFileDrop := False; end;
              FiSaveAs: begin DoFileSaveAsBegin(State); ShowFileDrop := False; end;
              FiExit: Quit := True;
              -1: ; { still open }
            else
              ShowFileDrop := False; { -2: cancelled }
            end;
          end;

          if ShowEditDrop then
          begin
            EditDropSel := MDropdownList(Core, HR, RState.Back, 'dysnomia/editmenu',
              MenuPaneID, 6, MenuBarRow + 1, EditMenuItems, Events);
            if EditDropSel = 0 then
            begin
              DoShowPreferences(State);
              ShowEditDrop := False;
            end
            else if EditDropSel <> -1 then
              ShowEditDrop := False;
          end;

          if ShowHelpDrop then
          begin
            HelpDropSel := MDropdownList(Core, HR, RState.Back, 'dysnomia/helpmenu',
              MenuPaneID, 12, MenuBarRow + 1, HelpMenuItems, Events);
            if HelpDropSel <> -1 then
              ShowHelpDrop := False;
          end;
          end;

          NowMs := GetTickCount64;
          DrawTimeline(RState.Back, Layout.Timeline, State, MIsFocused(Core, TimelineID), NowMs);

          if State.ModalKind = dmFileDialog then
            DrawFileDialogFrame(Core, HR, RState.Back, State, Events)
          else if State.ModalKind = dmPreferences then
            DrawPreferencesFrame(Core, HR, RState.Back, State, Events);

          if State.StatusMessage <> '' then
            DrawText(RState.Back, 0, RState.Back.Height - 1, State.StatusMessage)
          else
            DrawText(RState.Back, 0, RState.Back.Height - 1, StatusLineText);
        end;

        MRenderDiff(RState, Output);
        if Output.Len > 0 then
          FpWrite(D.OutFd, Output.Data[0], Output.Len);
      end;
    finally
      MDisableTerminalModes(D);
      MRemoveResizeHandler(D);
      MDisableRawMode(D);
      WriteLn;
    end;
  finally
    DysRemoteServerStop;
    AudioEngineShutdown;
    ConfigSave;
  end;
end;

end.
