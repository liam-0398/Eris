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
  Config, AudioEngine, Project, SampleTypes, WavDecoder, ProjectFile, DysRemoteServer,
  Effects, Quadraverb, BBE422A, Alesis3630, BossFZ2, Waveform, Math;

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
  PEffect = ^Effects.TEffect;

  TDysMptiLayout = record
    TooSmall: Boolean;
    Cols, Rows: Integer;
    ToolBar, FilePane, TrackPane, Timeline, EffectsPane, WaveformPane: TMRect;
  end;

  { ModalKind gates the whole main loop: while it's non-zero the four dock
    panes and the menu bar stop consuming Events entirely (see
    RunDysnomiaMpti) and only the modal's own draw+handle procedure does -
    the same "one thing owns input this frame" rule a real modal dialog
    needs, done by hand since MPTI has no TDialog/ExecView of its own. }
  TDysModalKind = (dmNone, dmFileDialog, dmPreferences, dmTrackOptions);
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

    { Effects rack (bottom-left pane): flattened cursor over
      Project.TrackEffects[CursorTrack] - see BuildEffectRows. Row 0 of
      each effect is its own header (kind name + remove hint); the rows
      after it are that effect's own parameters (BuildEffectParams).
      ShowAddEffectMenu drives the Add-effect popup (an MDropdownList of
      Effects.ekXxx kind names), mirroring TDysEffectsContent.
      OpenAddEffectMenu's own add-then-append shape. }
    EffCursor: Integer;
    ShowAddEffectMenu: Boolean;
    { -1 = category list showing; >= 0 = that category's own effect
      submenu showing (index into EffCatNames/EffCatKinds below). Two
      levels because a flat 18-item popup (the original single-level
      MDropdownList this replaced) ran off the bottom of the screen in a
      short terminal - see DrawEffectsPane's own comment. }
    AddEffectCatIdx: Integer;

    { Recording (transport bar's Rec button, DysStartRecording/
      DysFinalizeRecording ported below) - mirrors DysTimeline's own
      module-level RecordTrackIndex/RecordStartFrame; this file has no
      unit-level var section for the main loop to keep session state in,
      so they live on TDysAppState instead. }
    RecordTrackIndex: Integer;
    RecordStartFrame: Int64;

    { Track options popup (Ctrl+O on the track pane) - CTRL-O is meant as
      the standard "options popup for whatever's under the cursor" binding
      across this codebase going forward, not just tracks; this is the
      first of what should be a growing set of such popups. Gain/Pan are
      TDysAppState-local text mirrors of Project.TrackVolume/TrackPan,
      same "type a number, Enter commits, Esc reverts" shape the
      Preferences dialog's own text rows use. }
    OptTrack: Integer;
    OptGainText, OptPanText: string;
    OptFocusIdx: Integer;

    { Waveform pane (bottom-right) peak cache - see DrawWaveformPane's own
      header comment on why this is cached rather than recomputed every
      Draw. -1/-1/-1 = nothing cached yet, forcing the first frame's
      lookup to compute it. }
    WaveCacheTrack, WaveCacheClipIdx, WaveCacheSampleID: Integer;
    WavePeaks: Waveform.TWaveformPeaks;
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

  Result.FilePane := MMakeRect(0, BodyTop, FilePaneWidth, BodyBottom - BodyTop);
  Result.TrackPane := MMakeRect(Cols - TrackPaneWidth, BodyTop, TrackPaneWidth, BodyBottom - BodyTop);
  Result.Timeline := MMakeRect(FilePaneWidth, BodyTop, Cols - TrackPaneWidth - FilePaneWidth, BodyBottom - BodyTop);

  { Bottom dock splits Waveform (left) / Effects (right, gets the extra
    column on an odd width - param names/values need the room more than
    the wave shape does), same "two docks share the one bottom strip"
    layout DysGeometry's own BottomBar gave TDysBottomPane's toggled
    Content/WaveformView - side by side here instead of toggled, since
    MPTI's per-pane focus (Tab/Shift+Tab) already gives each its own
    keyboard-reachable pane with no need to hide one behind the other. }
  Result.WaveformPane := MMakeRect(0, BodyBottom, Cols div 2, BottomBarHeight);
  Result.EffectsPane := MMakeRect(Cols div 2, BodyBottom, Cols - Cols div 2, BottomBarHeight);
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

procedure DrawPaneAt(var Buf: TCellBuffer; const R: TMRect; const Title: string; Focused: Boolean);
begin
  if MRectEmpty(R) then
    Exit;
  MDrawPane(Buf, R.X, R.Y, R.W, R.H, Title, Focused);
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
  { The clip's own leading column, always - see DrawClipSpan. White (was
    dark grey), so the seam reads clearly against every track colour
    including the darker ones in TrackColorPalette. }
  ClipStartColor: array[0..2] of Byte = (255, 255, 255);

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
        State.PrefFocusIdx := (State.PrefFocusIdx + 7) mod 8
      else
        State.PrefFocusIdx := (State.PrefFocusIdx + 1) mod 8;
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

  if MButton(Core, HR, Buf, 'prefs/ok', MWidgetID('prefs/ok'), R.X + 2, R.Y + R.H - 2, 'OK', Events) then
    ConfirmPreferences(State);
  if MButton(Core, HR, Buf, 'prefs/cancel', MWidgetID('prefs/ok'), R.X + 14, R.Y + R.H - 2, 'Cancel', Events) then
    State.ModalKind := dmNone;

  for I := 0 to High(Events) do
    if (Events[I].Kind = mekKey) and (Events[I].Key.Code = mkEscape) then
      State.ModalKind := dmNone;
end;

{ ---------------------------------------------------------------------
  Track options popup (Ctrl+O on the track pane) - the first of what's
  meant to be a standard "Ctrl+O on whatever's under the cursor" popup
  convention across this codebase (see TDysAppState.OptTrack's own
  comment), so it follows the same small-modal shape DrawFileDialogFrame/
  DrawPreferencesFrame already established rather than inventing a new
  one: goes through State.ModalKind (dmTrackOptions), gets the same
  input-exclusivity gate the other two already get in RunDysnomiaMpti,
  and edits through a text mirror of the live Project field, Enter/OK to
  commit. Gain is Project.TrackVolume's own linear multiplier (1.0 =
  unity, same domain the field is already in); Pan is shown as the whole
  -100..100 number the old FV track header displayed it as (Project.
  TrackPan's own comment), converted back to -1.0..1.0 on commit. }
procedure DoShowTrackOptions(var State: TDysAppState; ATrack: Integer);
begin
  if (ATrack < 0) or (ATrack >= Project.TrackCount) then
    Exit;
  State.OptTrack := ATrack;
  State.OptGainText := FormatFloat('0.00', Project.TrackVolume[ATrack]);
  State.OptPanText := IntToStr(Round(Project.TrackPan[ATrack] * 100));
  State.OptFocusIdx := 0;
  State.ModalKind := dmTrackOptions;
end;

procedure ConfirmTrackOptions(var State: TDysAppState);
var
  GainVal: Double;
  PanVal: Integer;
begin
  if (State.OptTrack >= 0) and (State.OptTrack < Project.TrackCount) then
  begin
    if TryStrToFloat(State.OptGainText, GainVal) then
    begin
      if GainVal < 0 then GainVal := 0;
      Project.TrackVolume[State.OptTrack] := GainVal;
    end;
    if TryStrToInt(State.OptPanText, PanVal) then
    begin
      if PanVal < -100 then PanVal := -100;
      if PanVal > 100 then PanVal := 100;
      Project.TrackPan[State.OptTrack] := PanVal / 100;
    end;
  end;
  State.ModalKind := dmNone;
end;

procedure DrawTrackOptionsFrame(var Core: TMCoreState; var HR: TMHitRegistry;
  var Buf: TCellBuffer; var State: TDysAppState; const Events: TMInputEventArray);
var
  R: TMRect;
  Y, I: Integer;
  ID: TMWidgetID;
  Backward: Boolean;
begin
  R := ModalRect(Buf.Width, Buf.Height, 34, 10);
  MDrawPane(Buf, R.X, R.Y, R.W, R.H, 'Track ' + IntToStr(State.OptTrack + 1) + ' Options');

  for I := 0 to High(Events) do
    if EventIsFocusPaneKey(Events[I], Backward) then
      State.OptFocusIdx := (State.OptFocusIdx + 1) mod 2; { only 2 fields: forward/backward land the same }

  Y := R.Y + 2;
  DrawText(Buf, R.X + 2, Y, 'Gain (linear, 1.00 = unity):');
  Inc(Y);
  ID := MWidgetID('trackopts/gain');
  if State.OptFocusIdx = 0 then
    MSetFocus(Core, ID, ID);
  MTextInput(Core, HR, Buf, 'trackopts/gain', ID, R.X + 2, Y, 10, State.OptGainText, Events);
  Inc(Y, 2);

  DrawText(Buf, R.X + 2, Y, 'Pan (-100..100):');
  Inc(Y);
  ID := MWidgetID('trackopts/pan');
  if State.OptFocusIdx = 1 then
    MSetFocus(Core, ID, ID);
  MTextInput(Core, HR, Buf, 'trackopts/pan', ID, R.X + 2, Y, 10, State.OptPanText, Events);

  for I := 0 to High(Events) do
    if (Events[I].Kind = mekKey) and (Events[I].Key.Code = mkEnter) then
      ConfirmTrackOptions(State);

  if MButton(Core, HR, Buf, 'trackopts/ok', MWidgetID('trackopts/ok'), R.X + 2, R.Y + R.H - 2, 'OK', Events) then
    ConfirmTrackOptions(State);
  if MButton(Core, HR, Buf, 'trackopts/cancel', MWidgetID('trackopts/ok'), R.X + 14, R.Y + R.H - 2, 'Cancel', Events) then
    State.ModalKind := dmNone;

  for I := 0 to High(Events) do
    if (Events[I].Kind = mekKey) and (Events[I].Key.Code = mkEscape) then
      State.ModalKind := dmNone;
end;

{ Draws and self-handles the right-dock track listing: one row per track,
  offset down 2 rows (R.Y + 3 + T, not R.Y + 1 + T) to line up with the
  timeline grid's own header+ruler rows (DrawTimeline's Row := 2 + T at
  CY0 = R.Y + 1, i.e. absolute row R.Y + 3 + T - the exact same formula,
  so a track's number always sits beside its own lane regardless of
  which row of the grid the pane happens to start on). Numbers-only
  (the old "Track N" text didn't fit this pane's 8-column width - see
  build-dysnomia.sh's own FilePaneWidth/TrackPaneWidth constants).
  'm'/'s' toggle mute/solo on whichever track State.CursorTrack (shared
  with the timeline/file panes) is on; Ctrl+O opens the options popup. }
procedure DrawTrackPane(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const R: TMRect; var State: TDysAppState; PaneID: TMWidgetID; Focused: Boolean;
  const Events: TMInputEventArray);
var
  T, Y, CW: Integer;
  Fg: TMColor;
  Style: TMCellStyle;
  Hit: TMRect;
  I: Integer;
begin
  if (R.W < 3) or (R.H < 4) then Exit;
  CW := R.W - 2;

  Hit := MMakeRect(R.X + 1, R.Y + 1, CW, R.H - 2);
  MRegisterHitRect(HR, PaneID, PaneID, Hit);
  for I := 0 to High(Events) do
    if (Events[I].Kind = mekMouse) and (Events[I].Mouse.Action = maPress) and
       (Events[I].Mouse.Button = mbLeft) and MRectContains(Hit, Events[I].Mouse.X, Events[I].Mouse.Y) then
      MSetFocus(Core, PaneID, PaneID);

  if Focused then
    for I := 0 to High(Events) do
      if Events[I].Kind = mekKey then
        case Events[I].Key.Code of
          mkUp: if State.CursorTrack > 0 then Dec(State.CursorTrack);
          mkDown: if State.CursorTrack < Project.TrackCount - 1 then Inc(State.CursorTrack);
          mkChar:
            if (Events[I].Key.CodePoint = Ord('o')) and (kmCtrl in Events[I].Key.Mods) then
              DoShowTrackOptions(State, State.CursorTrack)
            else
              case Events[I].Key.CodePoint of
                Ord('m'), Ord('M'):
                  Project.TrackEnabled[State.CursorTrack] := not Project.TrackEnabled[State.CursorTrack];
                Ord('s'), Ord('S'):
                  Project.TrackSolo[State.CursorTrack] := not Project.TrackSolo[State.CursorTrack];
              end;
        end;

  for T := 0 to Project.TrackCount - 1 do
  begin
    Y := R.Y + 3 + T;
    if Y > R.Y + R.H - 2 then Break;
    if Focused and (T = State.CursorTrack) then
      Style := [csReverse]
    else
      Style := [];
    if not Project.TrackEnabled[T] then
      Fg := MMakeColor(220, 70, 70)
    else if Project.TrackSolo[T] then
      Fg := MMakeColor(220, 210, 70)
    else
      Fg := MDefaultFg;
    DrawText(Buf, R.X + 1, Y, Copy(IntToStr(T + 1), 1, CW), Fg, MDefaultBg, Style);
  end;
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

{ Grid/ruler tick positions for the visible width - fixed at quarter-note
  resolution regardless of the transport's own snap interval (the button
  up top, IntervalIdx/GridStepFrames): drawing ticks at 1/16 resolution
  would be unreadable clutter at this app's fixed zoom, so the VISUAL grid
  stays at quarters while cursor/clip snapping follows whatever interval
  is actually selected - two different things that happen to share a unit
  (frames) but not a density. Every 4th quarter (a bar) is marked Major
  and labelled with its 1-based bar number, per the user's "1.0 2.0 3.0"
  request. This is DAW-specific policy (what a "bar" is, at this project's
  tempo) - see MTimelineRuler's own doc comment for why that stays out of
  MPTI itself. }
function BuildGridTicks(const State: TDysAppState; CW: Integer): TMRulerTickArray;
var
  BarF, QuarterF, F: Int64;
  FirstQ, LastQ, QIdx, Col: Int64;
  Count: Integer;
begin
  Result := nil;
  BarF := BarFrames;
  if (BarF <= 0) or (State.FramesPerCol <= 0) then
    Exit;
  QuarterF := BarF div 4;
  if QuarterF <= 0 then
    Exit;
  FirstQ := (State.ViewStartFrame + QuarterF - 1) div QuarterF;
  LastQ := (State.ViewStartFrame + Int64(CW) * State.FramesPerCol) div QuarterF;
  Count := 0;
  for QIdx := FirstQ to LastQ do
  begin
    F := QIdx * QuarterF;
    Col := (F - State.ViewStartFrame) div State.FramesPerCol;
    if (Col >= 0) and (Col < CW) then
    begin
      SetLength(Result, Count + 1);
      Result[Count].Col := Col;
      if (QIdx mod 4) = 0 then
      begin
        Result[Count].Major := True;
        Result[Count].Label_ := IntToStr(QIdx div 4);
      end
      else
      begin
        Result[Count].Major := False;
        Result[Count].Label_ := '';
      end;
      Inc(Count);
    end;
  end;
end;

procedure DrawTimeline(var Buf: TCellBuffer; const R: TMRect; var State: TDysAppState;
  Focused: Boolean; NowMs: QWord);
var
  CX0, CY0, CW, CH, T, Row, I, Col: Integer;
  Label_: string;
  LblFg, LblBg: TMColor;
  LblStyle: TMCellStyle;
  Clip: TClip;
  PlayCol, LoopStartCol, LoopEndCol, CursorCol: Integer;
  PosSec: Double;
  Header: string;
  FlashOn: Boolean;
  LoopColor, GridColor: TMColor;
  Ticks: TMRulerTickArray;
  PlayFrame: Int64;
begin
  if (R.W < TimelineLabelWidth + 4) or (R.H < 4) then
    Exit;
  CX0 := R.X + 1 + TimelineLabelWidth;
  CY0 := R.Y + 1;
  CW := R.W - 2 - TimelineLabelWidth;
  CH := R.H - 2;
  if (CW < 1) or (CH < 3) then
    Exit;

  { Autoscroll: once the playhead scrolls off the right (or left) edge of
    the visible grid, re-anchor ViewStartFrame so it's visible again -
    same "the timeline is what follows playback" idea as DysTimeline's own
    UpdatePlayhead/EnsureFrameVisible (src/tui, read-only reference),
    simplified to a single re-centre rather than a minimum nudge since
    this stage has no manual horizontal scroll of its own to preserve. }
  if AudioEngineIsPlaying then
  begin
    PlayFrame := AudioEngineGetPosition;
    if FrameToCol(PlayFrame, State, CW) < 0 then
    begin
      State.ViewStartFrame := PlayFrame - (Int64(CW) * State.FramesPerCol) div 3;
      if State.ViewStartFrame < 0 then
        State.ViewStartFrame := 0;
    end;
  end;

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

  { Ruler row: quarter-note ticks, bold + bar-numbered every 4th (bar
    boundary) - MTimelineRuler is MPTI's own generic tick-drawing
    primitive (mpti.md's Timeline Ruler feature), fed Dysnomia's own idea
    of where a bar falls (see BuildGridTicks). }
  Ticks := BuildGridTicks(State, CW);
  MTimelineRuler(Buf, CX0, CY0 + 1, CW, Ticks, True);

  GridColor := MMakeColor(90, 90, 90);
  FlashOn := (NowMs div 400) mod 2 = 0;

  for T := 0 to Project.TrackCount - 1 do
  begin
    Row := 2 + T;
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

    { Empty-track baseline (dashes) plus the same grid ticks as the ruler,
      overlaid on top - drawn before clips so a clip cleanly overwrites
      the grid wherever it actually sits, same raster order MDrawPane's
      own "clears its interior first" convention follows. }
    for Col := 0 to CW - 1 do
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX0 + Col, CY0 + Row,
        Ord('-'), GridColor, MDefaultBg, []);
    MTimelineRuler(Buf, CX0, CY0 + Row, CW, Ticks, False);

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

  { Loop markers, drawn on the ruler row right alongside the bar ticks. }
  LoopColor := MMakeColor(120, 220, 140);
  if State.LoopStart >= 0 then
  begin
    LoopStartCol := FrameToCol(State.LoopStart, State, CW);
    if LoopStartCol >= 0 then
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX0 + LoopStartCol, CY0 + 1,
        Ord('L'), LoopColor, MDefaultBg, [csBold]);
  end;
  if State.LoopEnd >= 0 then
  begin
    LoopEndCol := FrameToCol(State.LoopEnd, State, CW);
    if LoopEndCol >= 0 then
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX0 + LoopEndCol, CY0 + 1,
        Ord('L'), LoopColor, MDefaultBg, [csBold]);
  end;

  if AudioEngineIsPlaying then
  begin
    PlayCol := FrameToCol(AudioEngineGetPosition, State, CW);
    if PlayCol >= 0 then
      for Row := 2 to CH - 1 do
        MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX0 + PlayCol, CY0 + Row,
          Ord('|'), MMakeColor(255, 80, 80), MDefaultBg, [csBold]);
  end;
end;


{ ---------------------------------------------------------------------
  Instrument tracks - 'i' on a file-browser entry (DysFilePane's own
  binding, ported verbatim from TDysFileListBox.SelectAsInstrument, src/
  tui read-only reference) assigns the decoded sample straight to
  Project.TrackInstrument on State.CursorTrack instead of dropping a
  clip on the timeline. No end marker (InstrumentEndUnset) - playback
  runs to the sample's own end, same as the reference. }
procedure SelectFileAsInstrument(var State: TDysAppState);
var
  Name, FullPath: string;
  Sample: TSample;
  SampleID: Integer;
begin
  if (State.FileSelected < 0) or (State.FileSelected > High(State.FileEntries)) then
    Exit;
  Name := State.FileEntries[State.FileSelected];
  if (Name = '..') or (Length(Name) = 0) or (Name[Length(Name)] = '/') then
    Exit;
  FullPath := State.FileCurDir + Name;
  if not DecodeSampleFile(FullPath, Sample) then
  begin
    State.StatusMessage := 'Could not decode "' + Name + '" as audio.';
    Exit;
  end;
  SampleID := Project.AddSampleToPool(Sample, Name, FullPath);
  Project.TrackInstrument[State.CursorTrack] := SampleID;
  Project.TrackInstrumentStart[State.CursorTrack] := 0;
  Project.TrackInstrumentEnd[State.CursorTrack] := Project.InstrumentEndUnset;
  State.StatusMessage := 'Track ' + IntToStr(State.CursorTrack + 1) + ' instrument: ' + Name;
end;

{ ---------------------------------------------------------------------
  Dual-octave QWERTY instrument keyboard - ported straight from
  DysWidgets.DysKeyToSemitoneOffset/DysEffectsRack.TriggerDysKeyboardNote/
  AdjustDysKeyboardOctave (src/tui, read-only reference; same key table
  as MainForm.KeyToSemitoneOffset, src/ui), active while the transport
  pane holds focus - same "the toolbar is where the keyboard lives" home
  the FV rack used - targeting State.CursorTrack instead of DysTrackPane.
  SelectedTrackIndex (this file's one shared cursor, see TDysAppState's
  own header comment). }
function DysKeyToSemitoneOffsetMpti(AChar: Char; out AOffset: Integer): Boolean;
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

procedure TriggerInstrumentNote(var State: TDysAppState; ASemitoneOffset: Integer);
var
  Track, SampleID, TotalOffset: Integer;
  Sample: TSample;
  StartFrame, EndFrame, TrimmedCount: Int64;
begin
  Track := State.CursorTrack;
  SampleID := Project.TrackInstrument[Track];
  if SampleID < 0 then
    Exit;
  Sample := Project.SamplePool[SampleID];
  StartFrame := Project.TrackInstrumentStart[Track];
  EndFrame := Project.TrackInstrumentEnd[Track];
  if StartFrame < 0 then
    StartFrame := 0;
  if (EndFrame <= 0) or (EndFrame > Sample.FrameCount) then
    EndFrame := Sample.FrameCount;
  TrimmedCount := EndFrame - StartFrame;
  if TrimmedCount <= 0 then
    Exit;
  TotalOffset := ASemitoneOffset + Project.TrackOctave[Track] * 12;
  AudioEngineTriggerNote(Track, @Sample.Data[StartFrame * Sample.Channels],
    TrimmedCount, Sample.Channels, TotalOffset,
    Power(10, Project.TrackInstrumentGainDb[Track] / 20));
end;

{ Ctrl+Z/Ctrl+X - matches AdjustDysKeyboardOctave's own -4..4 clamp
  (MainForm.SamplerOctaveDownClick/UpClick's own range, src/ui). }
procedure AdjustInstrumentOctave(var State: TDysAppState; ADelta: Integer);
var
  Track: Integer;
begin
  Track := State.CursorTrack;
  if ADelta < 0 then
  begin
    if Project.TrackOctave[Track] > -4 then
      Dec(Project.TrackOctave[Track]);
  end
  else
  begin
    if Project.TrackOctave[Track] < 4 then
      Inc(Project.TrackOctave[Track]);
  end;
end;

{ ---------------------------------------------------------------------
  Recording (transport bar Rec button) - ported from DysTimeline.
  DysStartRecording/DysFinalizeRecording (src/tui, read-only reference),
  targeting State.CursorTrack/State.CursorFrame instead of DysTrackPane/
  DysTimeline's own separate cursors (this file has one shared cursor -
  see TDysAppState's own header comment). RecordTrackIndex/
  RecordStartFrame move from the reference's unit-level vars onto
  TDysAppState since this file has no such var section of its own.
  --------------------------------------------------------------------- }
{ Mirrors DysWidgets.TDysToolBar.PollRecordState's own caption states. }
function RecordButtonCaption(ARecordState: Integer): string;
begin
  case ARecordState of
    RecordStateCountIn: Result := 'Cnt';
    RecordStateRecording: Result := 'REC';
  else
    Result := 'Rec';
  end;
end;

procedure DoStartRecording(var State: TDysAppState);
begin
  State.RecordTrackIndex := State.CursorTrack;
  if State.RecordTrackIndex < 0 then
    Exit;
  State.RecordStartFrame := State.CursorFrame;
  AudioEngineSeek(State.RecordStartFrame);

  if Project.TrackIsInput[State.RecordTrackIndex] then
  begin
    { line-in take: no keyboard instrument to check for, no count-in. }
    AudioEngineStartRecording(State.RecordTrackIndex);
    Exit;
  end;

  if not Project.TrackIsSampler[State.RecordTrackIndex] and
    (Project.TrackInstrument[State.RecordTrackIndex] < 0) then
  begin
    State.StatusMessage := 'Load an instrument for this track first.';
    Exit;
  end;

  AudioEngineStartCountIn(State.RecordTrackIndex);
end;

procedure DoFinalizeRecording(var State: TDysAppState);
var
  Data: PSingle;
  FrameCount: Integer;
  Sample: TSample;
  NewClip: TClip;
begin
  { Unlike the reference (DysTimeline.DysFinalizeRecording), this doesn't
    gate on AudioEngineRecordState still reading Recording at call time -
    by the time the engine's own recording-length cap auto-stops it (see
    the main loop's own poll, above), RecordState has already dropped
    back to Idle, so that check would always read False for the auto-stop
    path and silently drop the take. AudioEngineTakeRecordedAudio
    returning nothing/zero frames is what actually means "there was
    nothing to keep" (a manual stop during count-in, before anything was
    captured), and covers that case just as well. }
  AudioEngineStopRecording;
  if not AudioEngineTakeRecordedAudio(Data, FrameCount) then
    Exit;
  if (State.RecordTrackIndex < 0) or (FrameCount <= 0) then
    Exit;

  FillChar(Sample, SizeOf(Sample), 0);
  Sample.Data := Data;
  Sample.FrameCount := FrameCount;
  Sample.Channels := 2;
  Sample.SampleRate := AudioEngine.ProjectSampleRate;
  Sample.BaseNote := 60.0;

  FillChar(NewClip, SizeOf(NewClip), 0);
  NewClip.SampleID := Project.AddSampleToPool(Sample,
    'Recording ' + IntToStr(Length(Project.SamplePool)), '');
  NewClip.Offset := 0;
  NewClip.Length := FrameCount;
  NewClip.Position := State.RecordStartFrame;
  NewClip.TrackID := State.RecordTrackIndex;
  NewClip.Gain := 1.0;
  NewClip.PitchSemitones := 0;
  NewClip.WarpMode := SampleTypes.WarpModeBeats;

  Project.CommitClipToTrack(State.RecordTrackIndex, NewClip);
  PushTrackToEngineSimple(State.RecordTrackIndex);
  State.StatusMessage := 'Recorded to track ' + IntToStr(State.RecordTrackIndex + 1) + '.';
end;

{ ---------------------------------------------------------------------
  Effects rack (bottom-left pane) - ported from DysEffectsRack.pas's own
  TDysEffectBox.BuildParams (src/tui, read-only reference), same names
  and ranges, just appended into a flat array instead of constructing a
  TScrollBar/TInputLine pair per parameter: MPTI has no per-row labelled-
  slider widget (mpti.md's widget list doesn't call for one, see this
  file's header comment on what's in scope to add to MPTI itself), and
  this pane doesn't have the room for one regardless - Left/Right nudges
  the value shown on the currently selected parameter row directly, the
  same "value's already live, no separate Apply step" wiring the
  original's direct-field-pointer bindings had. Every field the original
  exposed is exposed here, including its handful of discrete mode/type
  enums (shown and nudged as plain integers - MPTI has no listbox-in-a-
  row widget either) - same visible/adjustable parameter set as the FV
  rack, not new functionality. }
type
  TEffParam = record
    Name: string[10];
    UnitStr: string[5];
    Min, Max, Scale: Single;
    FloatPtr: PSingle;
    IntPtr: PInteger;
  end;
  TEffParamArray = array[0..15] of TEffParam;

procedure EffAddF(var Params: TEffParamArray; var Count: Integer;
  const AName, AUnitStr: string; AMin, AMax, AScale: Single; APtr: PSingle);
begin
  if Count > High(Params) then Exit;
  Params[Count].Name := AName;
  Params[Count].UnitStr := AUnitStr;
  Params[Count].Min := AMin;
  Params[Count].Max := AMax;
  Params[Count].Scale := AScale;
  Params[Count].FloatPtr := APtr;
  Params[Count].IntPtr := nil;
  Inc(Count);
end;

procedure EffAddI(var Params: TEffParamArray; var Count: Integer;
  const AName, AUnitStr: string; AMin, AMax: Integer; APtr: PInteger);
begin
  if Count > High(Params) then Exit;
  Params[Count].Name := AName;
  Params[Count].UnitStr := AUnitStr;
  Params[Count].Min := AMin;
  Params[Count].Max := AMax;
  Params[Count].Scale := 1;
  Params[Count].FloatPtr := nil;
  Params[Count].IntPtr := APtr;
  Inc(Count);
end;

function BuildEffectParams(AKind: Integer; EffectPtr: PEffect; out Params: TEffParamArray): Integer;
var
  I, Count, MaxSrcTrack: Integer;
begin
  Count := 0;
  case AKind of
    Effects.ekLowpass:
      EffAddF(Params, Count, 'Freq', 'Hz', 20, 20000, 1, @EffectPtr^.LowpassFreqHz);
    Effects.ekHighpass:
      EffAddF(Params, Count, 'Freq', 'Hz', 20, 20000, 1, @EffectPtr^.HighpassFreqHz);
    Effects.ekBandpass:
      begin
        EffAddF(Params, Count, 'Freq', 'Hz', 20, 20000, 1, @EffectPtr^.BandpassFreqHz);
        EffAddF(Params, Count, 'Q', '', 0.1, 10, 10, @EffectPtr^.BandpassQ);
      end;
    Effects.ekEQ4:
      for I := 0 to Effects.MaxEQBands - 1 do
      begin
        EffAddF(Params, Count, 'F' + Chr(Ord('1') + I), 'Hz', 20, 20000, 1, @EffectPtr^.EQFreqHz[I]);
        EffAddF(Params, Count, 'G' + Chr(Ord('1') + I), 'dB', -12, 12, 1, @EffectPtr^.EQGainDb[I]);
      end;
    Effects.ekLimiter:
      begin
        EffAddF(Params, Count, 'Thresh', 'dB', -24, 0, 1, @EffectPtr^.LimiterThresholdDb);
        EffAddF(Params, Count, 'Release', 'ms', 10, 500, 1, @EffectPtr^.LimiterReleaseMs);
      end;
    Effects.ekChorus:
      begin
        EffAddF(Params, Count, 'Rate', 'Hz', 0.05, 5.0, 100, @EffectPtr^.ChorusRateHz);
        EffAddF(Params, Count, 'Depth', '%', 0, 100, 1, @EffectPtr^.ChorusDepthPercent);
      end;
    Effects.ekReverb:
      begin
        EffAddI(Params, Count, 'Preset', '', 0, Effects.ReverbPresetCount - 1, @EffectPtr^.ReverbPreset);
        EffAddF(Params, Count, 'Mix', '%', 0, 100, 1, @EffectPtr^.ReverbMixPercent);
      end;
    Effects.ekFlanger:
      begin
        EffAddF(Params, Count, 'Rate', 'Hz', 0.05, 5.0, 100, @EffectPtr^.FlangerRateHz);
        EffAddF(Params, Count, 'Depth', '%', 0, 100, 1, @EffectPtr^.FlangerDepthPercent);
        EffAddF(Params, Count, 'Feedback', '%', 0, 95, 1, @EffectPtr^.FlangerFeedbackPercent);
        EffAddF(Params, Count, 'Mix', '%', 0, 100, 1, @EffectPtr^.FlangerMixPercent);
      end;
    Effects.ekPhaser:
      begin
        EffAddF(Params, Count, 'Rate', 'Hz', 0.05, 5.0, 100, @EffectPtr^.PhaserRateHz);
        EffAddF(Params, Count, 'Depth', '%', 0, 100, 1, @EffectPtr^.PhaserDepthPercent);
        EffAddF(Params, Count, 'Feedback', '%', 0, 95, 1, @EffectPtr^.PhaserFeedbackPercent);
        EffAddF(Params, Count, 'Mix', '%', 0, 100, 1, @EffectPtr^.PhaserMixPercent);
      end;
    Effects.ekSidechain:
      begin
        MaxSrcTrack := Project.TrackCount - 1;
        if MaxSrcTrack < 0 then MaxSrcTrack := 0;
        EffAddI(Params, Count, 'SrcTrk', '', 0, MaxSrcTrack, @EffectPtr^.SidechainSourceTrack);
        EffAddF(Params, Count, 'Thresh', 'dB', -60, 0, 1, @EffectPtr^.SidechainThresholdDb);
        EffAddF(Params, Count, 'Attack', 'ms', 1, 200, 1, @EffectPtr^.SidechainAttackMs);
        EffAddF(Params, Count, 'Release', 'ms', 10, 1000, 1, @EffectPtr^.SidechainReleaseMs);
        EffAddF(Params, Count, 'Strength', '%', 0, 100, 1, @EffectPtr^.SidechainStrengthPercent);
      end;
    Effects.ekDrowning:
      begin
        EffAddF(Params, Count, 'Tone', 'Hz', 20, 20000, 1, @EffectPtr^.DrowningToneHz);
        EffAddF(Params, Count, 'WRate', 'Hz', 0.05, 5.0, 100, @EffectPtr^.DrowningWarbleRateHz);
        EffAddF(Params, Count, 'WDepth', '%', 0, 100, 1, @EffectPtr^.DrowningWarbleDepthPercent);
        EffAddF(Params, Count, 'Size', '%', 0, 100, 1, @EffectPtr^.DrowningSizePercent);
        EffAddF(Params, Count, 'Decay', '%', 0, 100, 1, @EffectPtr^.DrowningDecayPercent);
        EffAddF(Params, Count, 'Mix', '%', 0, 100, 1, @EffectPtr^.DrowningMixPercent);
      end;
    Effects.ekTuner:
      ; { read-only - no user parameters, see Effects.pas's own note }
    Effects.ekOverdrive:
      begin
        EffAddF(Params, Count, 'Freq', 'Hz', 20, 20000, 1, @EffectPtr^.OverdriveFreqHz);
        EffAddF(Params, Count, 'Q', '', 0.1, 5.0, 20, @EffectPtr^.OverdriveQ);
        EffAddF(Params, Count, 'Drive', '%', 0, 100, 1, @EffectPtr^.OverdriveDrivePercent);
        EffAddF(Params, Count, 'Color', '%', 0, 100, 1, @EffectPtr^.OverdriveColorPercent);
        EffAddF(Params, Count, 'Mix', '%', 0, 100, 1, @EffectPtr^.OverdriveMixPercent);
      end;
    Effects.ekQuadraverbReverb:
      begin
        EffAddI(Params, Count, 'Type', '', 0, Quadraverb.QVReverbTypeCount - 1, @EffectPtr^.QVReverbType);
        EffAddF(Params, Count, 'Predelay', 'ms', Quadraverb.QVPredelayMinMs, Quadraverb.QVPredelayMaxMs, 1,
          @EffectPtr^.QVReverbPredelayMs);
        EffAddF(Params, Count, 'PreMix', '%', Quadraverb.QVPredelayMixMin, Quadraverb.QVPredelayMixMax, 1,
          @EffectPtr^.QVReverbPredelayMix);
        EffAddF(Params, Count, 'Decay', '%', Quadraverb.QVDecayMin, Quadraverb.QVDecayMax, 1,
          @EffectPtr^.QVReverbDecay);
        EffAddF(Params, Count, 'Diffuse', '', Quadraverb.QVDiffusionMin, Quadraverb.QVDiffusionMax, 1,
          @EffectPtr^.QVReverbDiffusion);
        EffAddF(Params, Count, 'Density', '', Quadraverb.QVDensityMin, Quadraverb.QVDensityMax, 1,
          @EffectPtr^.QVReverbDensity);
        EffAddF(Params, Count, 'LowDecay', 'dB', Quadraverb.QVBandDecayMin, Quadraverb.QVBandDecayMax, 1,
          @EffectPtr^.QVReverbLowDecay);
        EffAddF(Params, Count, 'HiDecay', 'dB', Quadraverb.QVBandDecayMin, Quadraverb.QVBandDecayMax, 1,
          @EffectPtr^.QVReverbHighDecay);
        EffAddF(Params, Count, 'Mix', '%', 0, 100, 1, @EffectPtr^.QVReverbMixPercent);
      end;
    Effects.ekQuadraverbDelay:
      begin
        EffAddI(Params, Count, 'Type', '', 0, Quadraverb.QVDelayTypeCount - 1, @EffectPtr^.QVDelayType);
        EffAddF(Params, Count, 'TimeL', 'ms', 0, Quadraverb.QVDelayMonoMaxMs, 1, @EffectPtr^.QVDelayTimeLMs);
        EffAddF(Params, Count, 'TimeR', 'ms', 0, Quadraverb.QVDelayStereoMaxMs, 1, @EffectPtr^.QVDelayTimeRMs);
        EffAddF(Params, Count, 'FbkL', '%', 0, Quadraverb.QVDelayFeedbackMax, 1, @EffectPtr^.QVDelayFeedbackL);
        EffAddF(Params, Count, 'FbkR', '%', 0, Quadraverb.QVDelayFeedbackMax, 1, @EffectPtr^.QVDelayFeedbackR);
        EffAddF(Params, Count, 'Mix', '%', 0, 100, 1, @EffectPtr^.QVDelayMixPercent);
      end;
    Effects.ekExciter422A:
      begin
        EffAddF(Params, Count, 'LoContour', 'dB', BBE422A.BBELoContourMinDb, BBE422A.BBELoContourMaxDb, 1,
          @EffectPtr^.BBELoContourDb);
        EffAddF(Params, Count, 'Definitn', '%', BBE422A.BBEDefinitionMin, BBE422A.BBEDefinitionMax, 1,
          @EffectPtr^.BBEDefinition);
        EffAddF(Params, Count, 'Mix', '%', 0, 100, 1, @EffectPtr^.BBEMixPercent);
      end;
    Effects.ekCompressor3630:
      begin
        EffAddI(Params, Count, 'Response', '', 0, Alesis3630.A36ResponseCount - 1, @EffectPtr^.C36Response);
        EffAddI(Params, Count, 'Knee', '', 0, Alesis3630.A36KneeCount - 1, @EffectPtr^.C36Knee);
        EffAddF(Params, Count, 'Thresh', 'dBu', Alesis3630.A36ThresholdMinDbu, Alesis3630.A36ThresholdMaxDbu, 1,
          @EffectPtr^.C36ThresholdDbu);
        EffAddF(Params, Count, 'Ratio', 'x', 1, Alesis3630.A36RatioMaxFinite, 10, @EffectPtr^.C36Ratio);
        EffAddF(Params, Count, 'Attack', 'ms', Alesis3630.A36AttackMinMs, Alesis3630.A36AttackMaxMs, 10,
          @EffectPtr^.C36AttackMs);
        EffAddF(Params, Count, 'Release', 'ms', Alesis3630.A36ReleaseMinMs, Alesis3630.A36ReleaseMaxMs, 1,
          @EffectPtr^.C36ReleaseMs);
        EffAddF(Params, Count, 'Output', 'dB', Alesis3630.A36OutputMinDb, Alesis3630.A36OutputMaxDb, 1,
          @EffectPtr^.C36OutputDb);
        EffAddF(Params, Count, 'GateThr', 'dBfs', Alesis3630.A36GateThresholdMinDbfs,
          Alesis3630.A36GateThresholdMaxDbfs, 10, @EffectPtr^.C36GateThresholdDbfs);
        EffAddF(Params, Count, 'GateRate', 'ms', Alesis3630.A36GateRateMinMs, Alesis3630.A36GateRateMaxMs, 1,
          @EffectPtr^.C36GateRateMs);
        EffAddF(Params, Count, 'Mix', '%', 0, 100, 1, @EffectPtr^.C36MixPercent);
      end;
    Effects.ekFuzzFZ2:
      begin
        EffAddI(Params, Count, 'Mode', '', 0, BossFZ2.FZ2ModeCount - 1, @EffectPtr^.FZ2Mode);
        EffAddF(Params, Count, 'Gain', '%', BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, 1, @EffectPtr^.FZ2Gain);
        EffAddF(Params, Count, 'Treble', '%', BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, 1, @EffectPtr^.FZ2Treble);
        EffAddF(Params, Count, 'Bass', '%', BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, 1, @EffectPtr^.FZ2Bass);
        EffAddF(Params, Count, 'Level', '%', BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, 1, @EffectPtr^.FZ2Level);
        EffAddF(Params, Count, 'Mix', '%', 0, 100, 1, @EffectPtr^.FZ2MixPercent);
      end;
  end;
  Result := Count;
end;

function EffParamValue(const P: TEffParam): Double;
begin
  if Assigned(P.FloatPtr) then Result := P.FloatPtr^
  else if Assigned(P.IntPtr) then Result := P.IntPtr^
  else Result := 0;
end;

procedure EffParamNudge(const P: TEffParam; ADir: Integer);
var
  Step, V: Double;
begin
  if ADir = 0 then Exit;
  if Assigned(P.IntPtr) then
  begin
    V := P.IntPtr^ + ADir;
    if V < P.Min then V := P.Min;
    if V > P.Max then V := P.Max;
    P.IntPtr^ := Round(V);
  end
  else if Assigned(P.FloatPtr) then
  begin
    Step := (P.Max - P.Min) / 50;
    if Step <= 0 then Step := 1;
    V := P.FloatPtr^ + ADir * Step;
    if V < P.Min then V := P.Min;
    if V > P.Max then V := P.Max;
    P.FloatPtr^ := V;
  end;
end;

function EffectKindName(AKind: Integer): string;
begin
  case AKind of
    Effects.ekLowpass: Result := 'Lowpass';
    Effects.ekHighpass: Result := 'Highpass';
    Effects.ekBandpass: Result := 'Bandpass';
    Effects.ekEQ4: Result := '4-Band EQ';
    Effects.ekLimiter: Result := 'Limiter';
    Effects.ekChorus: Result := 'Chorus';
    Effects.ekReverb: Result := 'Reverb';
    Effects.ekFlanger: Result := 'Flanger';
    Effects.ekPhaser: Result := 'Phaser';
    Effects.ekSidechain: Result := 'Sidechain';
    Effects.ekDrowning: Result := 'Drowning';
    Effects.ekTuner: Result := 'Tuner';
    Effects.ekOverdrive: Result := 'Overdrive';
    Effects.ekQuadraverbReverb: Result := 'QV Reverb';
    Effects.ekQuadraverbDelay: Result := 'QV Delay';
    Effects.ekExciter422A: Result := 'Exciter 422A';
    Effects.ekCompressor3630: Result := 'Comp 3630';
    Effects.ekFuzzFZ2: Result := 'Fuzz FZ-2';
  else
    Result := 'Effect';
  end;
end;

const
  { Same category grouping as the LCL rack's own BuildEffectsMenu (src/ui/
    MainForm.pas, read-only reference) - a flat 18-item popup (this file's
    first cut) ran off the bottom of a normal-height terminal, the same
    problem a flat Free Vision popup menu would have had, which is why
    the LCL rack already groups these. EffCatKinds pads unused slots with
    Effects.ekNone (0), which is never itself a selectable effect, so it
    is a safe sentinel; EffCatCount is how many of each row are real. }
  EffCatNames: array[0..11] of string = (
    'Filters', 'EQ', 'Modulation', 'Distortion', 'Reverb', 'Delay',
    'Dynamics', 'Exciter', 'Pedals', 'Utility', 'Mastering', 'Experimental'
  );
  EffCatCount: array[0..11] of Integer = (3, 1, 3, 1, 2, 1, 1, 1, 1, 2, 1, 1);
  EffCatKinds: array[0..11, 0..2] of Integer = (
    (Effects.ekLowpass, Effects.ekHighpass, Effects.ekBandpass),
    (Effects.ekEQ4, Effects.ekNone, Effects.ekNone),
    (Effects.ekChorus, Effects.ekFlanger, Effects.ekPhaser),
    (Effects.ekOverdrive, Effects.ekNone, Effects.ekNone),
    (Effects.ekReverb, Effects.ekQuadraverbReverb, Effects.ekNone),
    (Effects.ekQuadraverbDelay, Effects.ekNone, Effects.ekNone),
    (Effects.ekCompressor3630, Effects.ekNone, Effects.ekNone),
    (Effects.ekExciter422A, Effects.ekNone, Effects.ekNone),
    (Effects.ekFuzzFZ2, Effects.ekNone, Effects.ekNone),
    (Effects.ekSidechain, Effects.ekTuner, Effects.ekNone),
    (Effects.ekLimiter, Effects.ekNone, Effects.ekNone),
    (Effects.ekDrowning, Effects.ekNone, Effects.ekNone)
  );

type
  TEffRow = record
    IsHeader: Boolean;
    EffIdx, ParamIdx: Integer;
  end;
  TEffRowArray = array of TEffRow;

function BuildEffectRows(ATrack: Integer): TEffRowArray;
var
  I, J, N, PCount: Integer;
  Params: TEffParamArray;
begin
  Result := nil;
  N := 0;
  for I := 0 to Project.TrackEffectCount[ATrack] - 1 do
  begin
    SetLength(Result, N + 1);
    Result[N].IsHeader := True;
    Result[N].EffIdx := I;
    Result[N].ParamIdx := -1;
    Inc(N);
    PCount := BuildEffectParams(Project.TrackEffects[ATrack][I].Kind,
      @Project.TrackEffects[ATrack][I], Params);
    for J := 0 to PCount - 1 do
    begin
      SetLength(Result, N + 1);
      Result[N].IsHeader := False;
      Result[N].EffIdx := I;
      Result[N].ParamIdx := J;
      Inc(N);
    end;
  end;
end;

{ Draws and self-handles the effects rack pane for whatever track the
  timeline cursor (State.CursorTrack) is currently on - rebuilds every
  frame from Project.TrackEffects directly (no cached rack-widget tree to
  keep in sync, unlike TDysEffectsContent.RebuildBoxes's own explicit
  rebuild-on-focus/rebuild-on-mutate calls - immediate mode means this is
  just always current). Up/Down move the flattened row cursor; Left/Right
  nudge the value on a parameter row; 'a' opens the add-effect popup;
  Delete/'x' removes the effect the cursor's row belongs to. }
procedure DrawEffectsPane(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const R: TMRect; var State: TDysAppState; PaneID: TMWidgetID; Focused: Boolean;
  const Events: TMInputEventArray);
var
  Rows: TEffRowArray;
  Params: TEffParamArray;
  PCount, I, Row, Y, CW: Integer;
  Line: string;
  Style: TMCellStyle;
  Names: TStringArray;
  AddSel: Integer;
  Hit: TMRect;
begin
  if (R.W < 8) or (R.H < 3) then Exit;
  CW := R.W - 2;

  Rows := BuildEffectRows(State.CursorTrack);
  if State.EffCursor > High(Rows) then State.EffCursor := High(Rows);
  if State.EffCursor < 0 then State.EffCursor := 0;

  Hit := MMakeRect(R.X + 1, R.Y + 1, CW, R.H - 2);
  MRegisterHitRect(HR, PaneID, PaneID, Hit);
  for I := 0 to High(Events) do
    if (Events[I].Kind = mekMouse) and (Events[I].Mouse.Action = maPress) and
       (Events[I].Mouse.Button = mbLeft) and MRectContains(Hit, Events[I].Mouse.X, Events[I].Mouse.Y) then
      MSetFocus(Core, PaneID, PaneID);

  if Focused and not State.ShowAddEffectMenu then
    for I := 0 to High(Events) do
      if Events[I].Kind = mekKey then
      begin
        case Events[I].Key.Code of
          mkUp: if State.EffCursor > 0 then Dec(State.EffCursor);
          mkDown: if State.EffCursor < High(Rows) then Inc(State.EffCursor);
          mkLeft, mkRight:
            if (State.EffCursor >= 0) and (State.EffCursor <= High(Rows)) and
               not Rows[State.EffCursor].IsHeader then
            begin
              PCount := BuildEffectParams(Project.TrackEffects[State.CursorTrack][Rows[State.EffCursor].EffIdx].Kind,
                @Project.TrackEffects[State.CursorTrack][Rows[State.EffCursor].EffIdx], Params);
              if Rows[State.EffCursor].ParamIdx < PCount then
                if Events[I].Key.Code = mkLeft then
                  EffParamNudge(Params[Rows[State.EffCursor].ParamIdx], -1)
                else
                  EffParamNudge(Params[Rows[State.EffCursor].ParamIdx], 1);
            end;
          mkDelete:
            if (State.EffCursor >= 0) and (State.EffCursor <= High(Rows)) then
            begin
              Project.RemoveTrackEffect(State.CursorTrack, Rows[State.EffCursor].EffIdx);
              Rows := BuildEffectRows(State.CursorTrack);
              if State.EffCursor > High(Rows) then State.EffCursor := High(Rows);
            end;
          mkChar:
            case Events[I].Key.CodePoint of
              Ord('a'), Ord('A'): State.ShowAddEffectMenu := True;
              Ord('x'), Ord('X'):
                if (State.EffCursor >= 0) and (State.EffCursor <= High(Rows)) then
                begin
                  Project.RemoveTrackEffect(State.CursorTrack, Rows[State.EffCursor].EffIdx);
                  Rows := BuildEffectRows(State.CursorTrack);
                  if State.EffCursor > High(Rows) then State.EffCursor := High(Rows);
                end;
            end;
        end;
      end;

  Y := R.Y + 1;
  if Length(Rows) = 0 then
    DrawText(Buf, R.X + 1, Y, Copy('(no effects - a: add)', 1, CW))
  else
    for Row := 0 to High(Rows) do
    begin
      if Y > R.Y + R.H - 2 then Break;
      if Focused and (Row = State.EffCursor) then Style := [csReverse] else Style := [];
      if Rows[Row].IsHeader then
      begin
        Line := IntToStr(Rows[Row].EffIdx + 1) + '. ' +
          EffectKindName(Project.TrackEffects[State.CursorTrack][Rows[Row].EffIdx].Kind) + '  [x]';
        DrawText(Buf, R.X + 1, Y, Copy(Line, 1, CW), MDefaultFg, MDefaultBg, Style + [csBold]);
      end
      else
      begin
        PCount := BuildEffectParams(Project.TrackEffects[State.CursorTrack][Rows[Row].EffIdx].Kind,
          @Project.TrackEffects[State.CursorTrack][Rows[Row].EffIdx], Params);
        if Rows[Row].ParamIdx < PCount then
          Line := '   ' + Params[Rows[Row].ParamIdx].Name + ': ' +
            FormatFloat('0.##', EffParamValue(Params[Rows[Row].ParamIdx])) + Params[Rows[Row].ParamIdx].UnitStr
        else
          Line := '';
        DrawText(Buf, R.X + 1, Y, Copy(Line, 1, CW), MDefaultFg, MDefaultBg, Style);
      end;
      Inc(Y);
    end;

  if State.ShowAddEffectMenu and (State.AddEffectCatIdx < 0) then
  begin
    { Level 1: category list - clamped to the pane's own height so it
      never runs off the bottom of a short terminal (the bug this
      cascade was added to fix: a flat 18-item popup routinely did). }
    SetLength(Names, Length(EffCatNames));
    for I := 0 to High(EffCatNames) do
      Names[I] := EffCatNames[I];
    AddSel := MDropdownList(Core, HR, Buf, 'effects/addmenu/cat', PaneID,
      R.X + 2, Min(R.Y + 2, Buf.Height - (Length(Names) + 2)), Names, Events);
    if AddSel >= 0 then
      State.AddEffectCatIdx := AddSel
    else if AddSel = -2 then
      State.ShowAddEffectMenu := False;
  end
  else if State.ShowAddEffectMenu and (State.AddEffectCatIdx >= 0) then
  begin
    { Level 2: the chosen category's own effects - cascaded to the right
      of where the category list was, same "cascading submenu" shape a
      Free Vision popup menu's own sub-items would show. Escape/outside-
      click here backs up to the category list rather than closing the
      whole popup, so picking the wrong category isn't a full restart. }
    SetLength(Names, EffCatCount[State.AddEffectCatIdx]);
    for I := 0 to High(Names) do
      Names[I] := EffectKindName(EffCatKinds[State.AddEffectCatIdx][I]);
    AddSel := MDropdownList(Core, HR, Buf, 'effects/addmenu/sub', PaneID,
      R.X + 2 + Length(EffCatNames[State.AddEffectCatIdx]) + 4,
      Min(R.Y + 2 + State.AddEffectCatIdx, Buf.Height - (Length(Names) + 2)), Names, Events);
    if AddSel >= 0 then
    begin
      Project.AddTrackEffect(State.CursorTrack, EffCatKinds[State.AddEffectCatIdx][AddSel]);
      State.ShowAddEffectMenu := False;
      State.AddEffectCatIdx := -1;
    end
    else if AddSel = -2 then
      State.AddEffectCatIdx := -1; { back to the category list, not fully closed }
  end;
end;

{ ---------------------------------------------------------------------
  Waveform pane (bottom-right) - follows whatever clip the timeline
  cursor is currently sitting over on State.CursorTrack (no separate
  "mark" key like the FV rack's 'k' - CursorFrame already IS "where the
  cursor is", so there is nothing a mark step would add here). Peaks
  are cached (State.WaveCache*/WavePeaks) and only recomputed when the
  marked clip's identity actually changes, same reasoning
  TDysWaveformContent.SetClip's own comment gives for computing once per
  mark rather than once per Draw. Renders via braille dot patterns when
  the terminal's own locale reports UTF-8 (Caps.UnicodeOk, negotiated at
  startup - see MptiCaps' own comment on why that's a runtime, not
  compile-time, decision: one binary, checked fresh against $LANG every
  run), falling back to the plain full-block glyph DysWidgets.
  WaveRowGlyph used otherwise - never a hard build-time choice between
  two binaries. }
procedure DrawWaveformBlocks(var Buf: TCellBuffer; X, Y, W, H: Integer; const Peaks: TWaveformPeaks);
var
  Col, Row, BinCount, BinLo, BinHi, I: Integer;
  MinV, MaxV, MidRow, Top, Bot, OverlapTop, OverlapBot: Double;
begin
  BinCount := Length(Peaks.Maxs);
  if BinCount = 0 then Exit;
  MidRow := H / 2;
  for Col := 0 to W - 1 do
  begin
    BinLo := (Col * BinCount) div W;
    BinHi := ((Col + 1) * BinCount) div W - 1;
    if BinHi < BinLo then BinHi := BinLo;
    if BinHi > BinCount - 1 then BinHi := BinCount - 1;
    MinV := Peaks.Mins[BinLo];
    MaxV := Peaks.Maxs[BinLo];
    for I := BinLo + 1 to BinHi do
    begin
      if Peaks.Mins[I] < MinV then MinV := Peaks.Mins[I];
      if Peaks.Maxs[I] > MaxV then MaxV := Peaks.Maxs[I];
    end;
    Top := MidRow - MaxV * MidRow;
    Bot := MidRow - MinV * MidRow;
    if Bot < Top + 0.02 then Bot := Top + 0.02;
    for Row := 0 to H - 1 do
    begin
      OverlapTop := Top - Row;
      if OverlapTop < 0 then OverlapTop := 0;
      OverlapBot := Bot - Row;
      if OverlapBot > 1 then OverlapBot := 1;
      if (OverlapBot > OverlapTop) and (OverlapBot - OverlapTop >= 0.5) then
        MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + Col, Y + Row, BlockChar,
          MDefaultFg, MDefaultBg, []);
    end;
  end;
end;

procedure DrawWaveformBraille(var Buf: TCellBuffer; X, Y, W, H: Integer; const Peaks: TWaveformPeaks);
const
  DotBits: array[0..3, 0..1] of Integer = ((1, 8), (2, 16), (4, 32), (64, 128));
var
  Col, Row, S, BinCount, BinLo, BinHi, I, Bits: Integer;
  MinV, MaxV, MidRow, Top, Bot, SubTop, SubBot, OverlapTop, OverlapBot: Double;
  Cp: TMUInt32;
begin
  BinCount := Length(Peaks.Maxs);
  if BinCount = 0 then Exit;
  MidRow := H / 2;
  for Col := 0 to W - 1 do
  begin
    BinLo := (Col * BinCount) div W;
    BinHi := ((Col + 1) * BinCount) div W - 1;
    if BinHi < BinLo then BinHi := BinLo;
    if BinHi > BinCount - 1 then BinHi := BinCount - 1;
    MinV := Peaks.Mins[BinLo];
    MaxV := Peaks.Maxs[BinLo];
    for I := BinLo + 1 to BinHi do
    begin
      if Peaks.Mins[I] < MinV then MinV := Peaks.Mins[I];
      if Peaks.Maxs[I] > MaxV then MaxV := Peaks.Maxs[I];
    end;
    Top := MidRow - MaxV * MidRow;
    Bot := MidRow - MinV * MidRow;
    if Bot < Top + 0.02 then Bot := Top + 0.02;
    for Row := 0 to H - 1 do
    begin
      Bits := 0;
      for S := 0 to 3 do
      begin
        SubTop := Row + S / 4;
        SubBot := Row + (S + 1) / 4;
        OverlapTop := Top;
        if OverlapTop < SubTop then OverlapTop := SubTop;
        OverlapBot := Bot;
        if OverlapBot > SubBot then OverlapBot := SubBot;
        if OverlapBot > OverlapTop then
          Bits := Bits or DotBits[S][0] or DotBits[S][1];
      end;
      if Bits <> 0 then
      begin
        Cp := $2800 + TMUInt32(Bits);
        MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + Col, Y + Row, Cp,
          MDefaultFg, MDefaultBg, []);
      end;
    end;
  end;
end;

procedure DrawWaveformPane(var HR: TMHitRegistry; var Buf: TCellBuffer; const R: TMRect;
  var State: TDysAppState; PaneID: TMWidgetID; UseBraille: Boolean);
var
  ClipIdx, Track: Integer;
  Clip: TClip;
  Windowed: TSample;
  Avail, SrcLen: Int64;
  CX0, CY0, CW, CH, WaveRows: Integer;
  Hdr: string;
begin
  if (R.W < 6) or (R.H < 3) then Exit;
  CX0 := R.X + 1;
  CY0 := R.Y + 1;
  CW := R.W - 2;
  CH := R.H - 2;

  { A single whole-pane hit rect standing in for this pane's one and only
    Tab stop - the view has nothing to interact with (it just follows the
    timeline cursor), but still needs SOME widget registered under its
    own PaneID or MFocusCycleInPane/MFocusNextPane (MptiCore.pas) has
    nothing to land focus on and Shift+Tab would silently skip it. }
  MRegisterHitRect(HR, PaneID, PaneID, MMakeRect(R.X + 1, R.Y + 1, CW, CH));

  Track := State.CursorTrack;
  ClipIdx := ClipIndexAtFrame(Track, State.CursorFrame);
  if ClipIdx < 0 then
  begin
    DrawText(Buf, CX0, CY0, Copy('waveform: (place cursor over a clip)', 1, CW));
    State.WaveCacheClipIdx := -1;
    Exit;
  end;
  Clip := Project.Tracks[Track].Clips[ClipIdx];

  if (State.WaveCacheTrack <> Track) or (State.WaveCacheClipIdx <> ClipIdx) or
     (State.WaveCacheSampleID <> Clip.SampleID) then
  begin
    State.WaveCacheTrack := Track;
    State.WaveCacheClipIdx := ClipIdx;
    State.WaveCacheSampleID := Clip.SampleID;
    State.WavePeaks.Mins := nil;
    State.WavePeaks.Maxs := nil;
    if (Clip.SampleID >= 0) and (Clip.SampleID <= High(Project.SamplePool)) then
    begin
      Windowed := Project.SamplePool[Clip.SampleID];
      Avail := Windowed.FrameCount - Clip.Offset;
      if Avail < 0 then Avail := 0;
      SrcLen := Project.ClipSourceLength(Clip);
      if SrcLen < Avail then Avail := SrcLen;
      if (Windowed.Data <> nil) and (Avail > 0) then
      begin
        Windowed.Data := @Windowed.Data[Clip.Offset * Windowed.Channels];
        Windowed.FrameCount := Avail;
        State.WavePeaks := Waveform.ComputeWaveformPeaks(Windowed);
      end;
    end;
  end;

  Hdr := 'waveform: sample ' + IntToStr(Clip.SampleID) + '  gain ' +
    FormatFloat('0.00', Clip.Gain) + '  detune ' + FormatFloat('0.0', Clip.PitchSemitones) + 'st';
  DrawText(Buf, CX0, CY0, Copy(Hdr, 1, CW));

  WaveRows := CH - 1;
  if (WaveRows < 1) or (Length(State.WavePeaks.Maxs) = 0) then Exit;

  if UseBraille then
    DrawWaveformBraille(Buf, CX0, CY0 + 1, CW, WaveRows, State.WavePeaks)
  else
    DrawWaveformBlocks(Buf, CX0, CY0 + 1, CW, WaveRows, State.WavePeaks);
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
  TransportPaneID, TempoID, FileListID, TrackListID, TimelineID: TMWidgetID;
  EffectsPaneID, WaveformPaneID: TMWidgetID;
  TempoLabel: string;
  TempoW, TempoX: Integer;
  OpenMenu: Integer;
  FileDropSel, EditDropSel, HelpDropSel: Integer;
  ShowFileDrop, ShowEditDrop, ShowHelpDrop: Boolean;
  State: TDysAppState;
  PaneIDs: array[0..5] of TMWidgetID;
  FocusIdx: Integer;
  Backward: Boolean;
  TX, StopX, PlayX, IntervalX, RecX: Integer;
  R: TMRect;
  TempoVal: Double;
  TempoCode: Word;
  TimelineHit: TMRect;
  NowMs: QWord;
  PalIdx, ClipIdx: Integer;
  LoopCandidate: Int64;
  NoteOffset: Integer;
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

    D.Caps := MCapsFromEnv(GetEnvironmentVariable('TERM'), GetEnvironmentVariable('COLORTERM'),
      GetEnvironmentVariable('LANG'));
    MEnableRawMode(D);
    MInstallResizeHandler(D);
    MEnableTerminalModes(D);
    try
      MInitRenderState(RState, D.Caps, D.Cols, D.Rows);
      MInitCore(Core);
      MenuPaneID := MWidgetID('dysnomia/menubar');
      TransportPaneID := MWidgetID('dysnomia/transport');
      TempoID := MWidgetID('toolbar/tempo');
      FileListID := MWidgetID('files/list');
      TrackListID := MWidgetID('tracks/list');
      TimelineID := MWidgetID('timeline/canvas');
      EffectsPaneID := MWidgetID('dysnomia/effects');
      WaveformPaneID := MWidgetID('dysnomia/waveform');
      PaneIDs[0] := TransportPaneID;
      PaneIDs[1] := FileListID;
      PaneIDs[2] := TimelineID;
      PaneIDs[3] := TrackListID;
      PaneIDs[4] := EffectsPaneID;
      PaneIDs[5] := WaveformPaneID;

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
      State.EffCursor := 0;
      State.AddEffectCatIdx := -1;
      State.RecordTrackIndex := -1;
      State.OptTrack := -1;
      State.WaveCacheTrack := -1;
      State.WaveCacheClipIdx := -1;
      State.WaveCacheSampleID := -1;
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

        { Which dock currently owns focus - read from MPTI's own
          Core.FocusedPane (set last frame, by the Tab/Shift+Tab handling
          below) purely to pick a border style this frame; not while a
          modal is up, since none of the four docks are interactive then. }
        FocusIdx := -1;
        if State.ModalKind = dmNone then
          for I := 0 to High(PaneIDs) do
            if PaneIDs[I] = Core.FocusedPane then
              FocusIdx := I;

        { Recording auto-finalizes itself the moment AudioEngineRecordState
          drops back to Idle on its own (the engine's own recording-length
          cap - see AudioEngine.MaxRecordSeconds), not just on a manual Rec
          click - same "poll on the way in, don't wait for a click" shape
          DysWidgets.TDysToolBar.PollRecordState used. A manual click stops
          and finalizes immediately from the Rec button's own handler below
          instead, so this only ever fires for the engine's own auto-stop. }
        if (State.RecordTrackIndex >= 0) and (AudioEngineRecordState = RecordStateIdle) then
        begin
          DoFinalizeRecording(State);
          State.RecordTrackIndex := -1;
        end;

        Layout := ComputeDysMptiLayout(RState.Back.Width, RState.Back.Height);
        if Layout.TooSmall then
          ShowTooSmall(RState.Back, Layout.Cols, Layout.Rows)
        else
        begin
          DrawPaneAt(RState.Back, Layout.ToolBar, 'Transport', FocusIdx = 0);
          DrawPaneAt(RState.Back, Layout.FilePane, 'Files', FocusIdx = 1);
          DrawPaneAt(RState.Back, Layout.Timeline, 'Timeline', FocusIdx = 2);
          DrawPaneAt(RState.Back, Layout.TrackPane, 'Trk', FocusIdx = 3);
          DrawPaneAt(RState.Back, Layout.EffectsPane, 'Effects', FocusIdx = 4);
          DrawPaneAt(RState.Back, Layout.WaveformPane, 'Waveform', FocusIdx = 5);

          { The four dock panes and the menu bar only get to consume
            Events while no modal is up - a modal is the only thing
            allowed to read input this frame (see DrawFileDialogFrame/
            DrawPreferencesFrame, and the Tab-cycling gate above). }
          if State.ModalKind = dmNone then
          begin
          { Transport: Stop/Play/Interval first (left to right), Tempo
            pinned to the far right - so Tab (which now walks every
            widget in the pane, see the focus-cycling block below) reaches
            the buttons first and the text field - the one control that
            eats plain character keys while it holds focus - last, per
            the user's own request. All four share TransportPaneID as
            their PaneID, which is what groups them for that Tab cycle. }
          R := Layout.ToolBar;
          TX := R.X + 1;
          StopX := TX;
          if MButton(Core, HR, RState.Back, 'toolbar/stop', TransportPaneID, StopX, R.Y + 1,
            'Stop', Events) then
          begin
            AudioEngineStop;
            AudioEngineSeek(0);
          end;
          PlayX := StopX + 8;
          if MButton(Core, HR, RState.Back, 'toolbar/play', TransportPaneID, PlayX, R.Y + 1,
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
          if MButton(Core, HR, RState.Back, 'toolbar/interval', TransportPaneID, IntervalX, R.Y + 1,
            IntervalNames[State.IntervalIdx], Events) then
            State.IntervalIdx := (State.IntervalIdx + 1) mod Length(IntervalNames);

          { Record - mirrors DysWidgets.TDysToolBar's own Rec button
            caption states (Rec/Cnt/REC, driven by AudioEngineRecordState).
            A click while counting in or recording stops+finalizes right
            away (DoFinalizeRecording); a click while idle starts
            (DoStartRecording). The engine's own auto-stop-at-cap case is
            polled and finalized at the top of the frame instead - see
            that block's own comment. }
          RecX := IntervalX + 8;
          if MButton(Core, HR, RState.Back, 'toolbar/record', TransportPaneID, RecX, R.Y + 1,
            RecordButtonCaption(AudioEngineRecordState), Events) then
          begin
            if AudioEngineRecordState <> RecordStateIdle then
            begin
              DoFinalizeRecording(State);
              State.RecordTrackIndex := -1;
            end
            else
              DoStartRecording(State);
          end;

          TempoLabel := 'Tempo:';
          TempoW := Length(TempoLabel) + 1 + 6;
          TempoX := R.X + R.W - 1 - TempoW;
          if TempoX < RecX + 8 then
            TempoX := RecX + 8; { narrow terminal: just follow Rec instead of overlapping it }
          DrawText(RState.Back, TempoX, R.Y + 1, TempoLabel);
          MTextInput(Core, HR, RState.Back, 'toolbar/tempo', TransportPaneID,
            TempoX + Length(TempoLabel) + 1, R.Y + 1, 6, State.TempoText, Events);
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

          { Dual-octave QWERTY instrument keyboard - live while the
            transport pane holds focus, same home the FV rack's own
            keyboard had. Guarded off whenever the Tempo field itself
            currently owns text-edit focus, so typing a tempo doesn't
            also trigger notes for any digit/letter that happens to
            double as a keyboard-note key (DysKeyToSemitoneOffsetMpti's
            own table includes several digits). Ctrl+Z/Ctrl+X shift the
            octave; every other mapped key triggers a note. }
          if (FocusIdx = 0) and not MIsFocused(Core, TempoID) then
            for I := 0 to High(Events) do
              if (Events[I].Kind = mekKey) and (Events[I].Key.Code = mkChar) and
                 (Events[I].Key.CodePoint >= 32) and (Events[I].Key.CodePoint <= 126) then
              begin
                if (kmCtrl in Events[I].Key.Mods) and
                   (Events[I].Key.CodePoint in [Ord('z'), Ord('Z')]) then
                  AdjustInstrumentOctave(State, -1)
                else if (kmCtrl in Events[I].Key.Mods) and
                   (Events[I].Key.CodePoint in [Ord('x'), Ord('X')]) then
                  AdjustInstrumentOctave(State, 1)
                else if not (kmCtrl in Events[I].Key.Mods) and
                   DysKeyToSemitoneOffsetMpti(Chr(Events[I].Key.CodePoint), NoteOffset) then
                  TriggerInstrumentNote(State, NoteOffset);
              end;

          { File browser. }
          R := Layout.FilePane;
          MListView(Core, HR, RState.Back, 'files/list', FileListID,
            R.X + 1, R.Y + 1, R.W - 2, R.H - 2, State.FileEntries,
            State.FileSelected, State.FileScroll, Events);
          if MIsFocused(Core, FileListID) then
            for I := 0 to High(Events) do
              if Events[I].Kind = mekKey then
              begin
                if Events[I].Key.Code = mkEnter then
                  ActivateFileEntry(State)
                else if (Events[I].Key.Code = mkChar) and
                  ((Events[I].Key.CodePoint = Ord('i')) or (Events[I].Key.CodePoint = Ord('I'))) then
                  SelectFileAsInstrument(State);
              end;

          { Track pane: one row per track, Selected IS State.CursorTrack -
            single source of truth (see this file's header comment). Not a
            stock MPTI widget any more (was MListView) - see DrawTrackPane's
            own header comment for why (row alignment with the timeline
            grid, mute/solo colour, Ctrl+O). }
          R := Layout.TrackPane;
          DrawTrackPane(Core, HR, RState.Back, R, State, TrackListID, FocusIdx = 3, Events);

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
                      Ord(' '):
                        { Space toggles Play/Pause with the timeline
                          focused - same action as the transport bar's own
                          Play/Pause button, just reachable without
                          Shift-Tabbing all the way over to it first. }
                        if AudioEngineIsPlaying then
                          AudioEngineStop
                        else if AudioEngineHasClip then
                        begin
                          AudioEngineSeek(State.CursorFrame);
                          AudioEnginePlay;
                        end;
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

          { Effects rack / waveform panes - both self-checked against
            Events/HR, same "not a stock MPTI widget" pattern the timeline
            canvas above already uses. }
          DrawEffectsPane(Core, HR, RState.Back, Layout.EffectsPane, State, EffectsPaneID,
            FocusIdx = 4, Events);
          DrawWaveformPane(HR, RState.Back, Layout.WaveformPane, State, WaveformPaneID, D.Caps.UnicodeOk);

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
              FiNew: begin DoFileNew(State); ShowFileDrop := False; MMenuBarClose(Core, 'dysnomia/menubar'); end;
              FiOpen: begin DoFileOpenBegin(State); ShowFileDrop := False; MMenuBarClose(Core, 'dysnomia/menubar'); end;
              FiSave: begin DoFileSave(State); ShowFileDrop := False; MMenuBarClose(Core, 'dysnomia/menubar'); end;
              FiSaveAs: begin DoFileSaveAsBegin(State); ShowFileDrop := False; MMenuBarClose(Core, 'dysnomia/menubar'); end;
              FiExit: Quit := True;
              -1: ; { still open }
            else
              begin ShowFileDrop := False; MMenuBarClose(Core, 'dysnomia/menubar'); end; { -2: cancelled }
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
              MMenuBarClose(Core, 'dysnomia/menubar');
            end
            else if EditDropSel <> -1 then
            begin
              ShowEditDrop := False;
              MMenuBarClose(Core, 'dysnomia/menubar');
            end;
          end;

          if ShowHelpDrop then
          begin
            HelpDropSel := MDropdownList(Core, HR, RState.Back, 'dysnomia/helpmenu',
              MenuPaneID, 12, MenuBarRow + 1, HelpMenuItems, Events);
            if HelpDropSel <> -1 then
            begin
              ShowHelpDrop := False;
              MMenuBarClose(Core, 'dysnomia/menubar');
            end;
          end;

          { Tab walks every widget in the currently-focused pane; Shift+Tab
            switches which pane is focused (landing on its first widget) -
            MPTI's own generic focus-navigation primitives (MptiCore.pas),
            called here rather than at the top of the frame because HR only
            reflects everything all four panes registered THIS frame once
            they've actually drawn (see MFocusCycleInPane's own doc
            comment). }
          for I := 0 to High(Events) do
            if EventIsFocusPaneKey(Events[I], Backward) then
            begin
              if Backward then
                MFocusNextPane(Core, HR, PaneIDs, True)
              else
                MFocusCycleInPane(Core, HR, Core.FocusedPane, True);
            end;
          end;

          NowMs := GetTickCount64;
          DrawTimeline(RState.Back, Layout.Timeline, State, MIsFocused(Core, TimelineID), NowMs);

          if State.ModalKind = dmFileDialog then
            DrawFileDialogFrame(Core, HR, RState.Back, State, Events)
          else if State.ModalKind = dmPreferences then
            DrawPreferencesFrame(Core, HR, RState.Back, State, Events)
          else if State.ModalKind = dmTrackOptions then
            DrawTrackOptionsFrame(Core, HR, RState.Back, State, Events);

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
      MShutdownDriver(D);
      WriteLn;
    end;
  finally
    DysRemoteServerStop;
    AudioEngineShutdown;
    ConfigSave;
  end;
end;

end.
