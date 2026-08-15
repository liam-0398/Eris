unit DysMptiApp;

{ MPTI-frontend replacement for the main Dysnomia DAW (mpti.md). This is
  NOT the Tracker (DysTrackerApp), NOT the Control Station
  (DysControlStationApp), and NOT the launcher (DysLauncher) - all three
  stay on Free Vision, per the conversion scope. Only the main DAW shell
  that used to be TDysnomiaApp (DysnomiaApp.pas) is being ported here,
  in stages.

  Stage 1 (this file): boots the MPTI driver/render/core stack in place
  of TApplication.Init/Run/Done, computes the same five-pane layout
  DysGeometry.ComputeLayout describes (reimplemented against TMRect
  here rather than reusing DysGeometry's TRect-returning function, so
  this unit pulls in no Objects/Drivers/Views - MPTI's dependency-free
  rule (mpti.md req. 9) applies to Dysnomia's own MPTI-side code too,
  not just src/mpti itself), and draws an empty bordered pane per
  region plus a menu bar and status line. Engine/Config/remote-server
  lifecycle is wired with the exact same calls TDysnomiaApp.Init/Done
  used, so this stage is a like-for-like shell swap before any real
  pane content gets ported (stage 2 onward).

  DysnomiaApp.pas, DysWidgets.pas, DysEffectsRack.pas, DysFilePane.pas,
  DysTrackPane.pas, DysTimeline.pas, DysFileDialog.pas stay in place,
  untouched, as read-only reference for porting their behaviour into
  MPTI widgets stage by stage - they are no longer instantiated by
  dysnomia.lpr's DAW path once this unit takes over (see dysnomia.lpr),
  but nothing here modifies or removes them. }

{$mode objfpc}{$H+}

interface

procedure RunDysnomiaMpti;

implementation

uses
  SysUtils, BaseUnix,
  MptiTypes, MptiCell, MptiCaps, MptiInput, MptiDriver, MptiRender,
  MptiCore, MptiLayout, MptiWidgets,
  Config, AudioEngine, Project, DysRemoteServer;

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
  StatusLineText = '~Alt-X~ Exit   ~F10~ Menu';

type
  TDysMptiLayout = record
    TooSmall: Boolean;
    Cols, Rows: Integer;
    ToolBar, FilePane, TrackPane, Timeline, BottomBar: TMRect;
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
  Fg, Bg: TMColor);
var
  I, CX, W: Integer;
begin
  CX := X;
  for I := 1 to Length(S) do
  begin
    W := MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX, Y, Ord(S[I]), Fg, Bg, []);
    Inc(CX, W);
  end;
end;

procedure DrawText(var Buf: TCellBuffer; X, Y: Integer; const S: string);
begin
  DrawText(Buf, X, Y, S, MDefaultFg, MDefaultBg);
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

{ Alt+X, matching TDysnomiaApp's own cmQuit binding (InitMenuBar's
  kbAltX File > Exit item). }
function IsQuitKey(const Ev: TMInputEvent): Boolean;
begin
  Result := (Ev.Kind = mekKey) and (Ev.Key.Code = mkChar) and
    (Ev.Key.CodePoint = Ord('x')) and (kmAlt in Ev.Key.Mods);
end;

const
  MnFile = 0;
  MnEdit = 1;
  MnHelp = 2;

  FileMenuItems: array[0..0] of string = ('Exit');
  HelpMenuItems: array[0..0] of string = ('About');

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
  PaneID: TMWidgetID;
  OpenMenu: Integer;
  FileDropSel, HelpDropSel: Integer;
  ShowFileDrop, ShowHelpDrop: Boolean;
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
      PaneID := MWidgetID('dysnomia/menubar');
      Quit := False;
      ShowFileDrop := False;
      ShowHelpDrop := False;

      while not Quit do
      begin
        SetLength(Events, 0);
        if MRunOnce(D, 10, Events, Kind) then
        begin
          if Kind = dekResize then
            MResizeRenderState(RState, D.Cols, D.Rows)
          else
            for I := 0 to High(Events) do
              if IsQuitKey(Events[I]) then
                Quit := True;
        end;

        DysRemoteDrainQueue;

        MClearCellBuffer(RState.Back, MBlankCell);
        MBeginCoreFrame(Core);
        MBeginHitRegistry(HR);

        Layout := ComputeDysMptiLayout(RState.Back.Width, RState.Back.Height);
        if Layout.TooSmall then
          ShowTooSmall(RState.Back, Layout.Cols, Layout.Rows)
        else
        begin
          DrawPaneAt(RState.Back, Layout.ToolBar, 'Transport');
          DrawPaneAt(RState.Back, Layout.FilePane, 'Files');
          DrawPaneAt(RState.Back, Layout.Timeline, 'Timeline');
          DrawPaneAt(RState.Back, Layout.TrackPane, 'Tracks');
          DrawPaneAt(RState.Back, Layout.BottomBar, 'Effects / Waveform');

          OpenMenu := MMenuBar(Core, HR, RState.Back, 'dysnomia/menubar', PaneID,
            0, MenuBarRow, ['File', 'Edit', 'Help'], Events);

          if OpenMenu = MnFile then
            ShowFileDrop := True
          else if OpenMenu <> MnFile then
            ShowFileDrop := False;
          if OpenMenu = MnHelp then
            ShowHelpDrop := True
          else if OpenMenu <> MnHelp then
            ShowHelpDrop := False;

          if ShowFileDrop then
          begin
            FileDropSel := MDropdownList(Core, HR, RState.Back, 'dysnomia/filemenu',
              PaneID, 0, MenuBarRow + 1, FileMenuItems, Events);
            if FileDropSel = 0 then
              Quit := True
            else if FileDropSel <> -1 then
              ShowFileDrop := False;
          end;

          if ShowHelpDrop then
          begin
            HelpDropSel := MDropdownList(Core, HR, RState.Back, 'dysnomia/helpmenu',
              PaneID, 12, MenuBarRow + 1, HelpMenuItems, Events);
            if HelpDropSel <> -1 then
              ShowHelpDrop := False;
          end;

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
