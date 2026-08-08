unit MainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls,
  StdCtrls, ComCtrls, Buttons, LCLType, ArrangementView, PrefsForm, FileBrowser,
  SampleTypes, WavDecoder, AudioEngine, Project, ProjectFile, WarpEditor,
  InstrumentEditor, Effects, EffectsRack, UIScale;

type
  TForm1 = class(TForm)
  private
    const
      TrackWidgetLeft = 8;
      TrackWidgetWidth = 120; { wide enough for the swing controls below the name }
      InstrumentSlotLeft = 136;
      WarpSlotLeft = 364;
      DeviceScrollBarHeight = 16;
      WidgetTop = 8 + DeviceScrollBarHeight;
      WidgetHeight = 180;
      WidgetBottomMargin = 8;
      { SP-1200's own swing settings: 50 = straight/off, then its five real
        detents. Slider Position is an index into this array. }
      SwingDetents: array[0..5] of Integer = (50, 54, 58, 63, 67, 71);
    var
    FMainMenu: TMainMenu;
    FTransportPanel: TPanel;
    FMetronomeToggle: TSpeedButton;
    FStopButton: TButton;
    FPlayPauseButton: TButton;
    FRecordButton: TButton;
    FRecordStartFrame: Int64;
    FRecordTrackIndex: Integer;
    FRecordingCounter: Integer;
    FTempoLabel: TLabel;
    FTempoEdit: TEdit;
    FGridLabel: TLabel;
    FGridTrackBar: TTrackBar;
    FFileBrowser: TFileBrowser;
    FFileBrowserSplitter: TSplitter;
    FArrangementView: TArrangementView;
    FSplitter: TSplitter;
    FDevicePanel: TPanel;
    FTrackWidget: TPanel;
    FTrackWidgetLabel: TLabel;
    FSwingLabel: TLabel;
    FSwingDivisionButton: TSpeedButton;
    FSwingSlider: TTrackBar;
    FSwingValueLabel: TLabel;
    FInstrumentWidget: TPanel;
    FInstrumentNameLabel: TLabel;
    FInstrumentDeleteButton: TButton;
    FOctaveLabel: TLabel;
    FOctaveMinusButton: TButton;
    FOctavePlusButton: TButton;
    FDropHintLabel: TLabel;
    FWarpWidget: TPanel;
    FWarpEditor: TWarpEditor;
    FWarpRepitchToggle: TSpeedButton;
    FInstrumentEditorWidget: TPanel;
    FInstrumentEditor: TInstrumentEditor;
    FDeviceScrollBar: TScrollBar;
    FEffectsMenu: TPopupMenu;
    FEffectWidgets: array of TEffectWidget;
    FLastEffectsRackTrack: Integer;
    FPlaybackPollTimer: TTimer;
    FCurrentProjectPath: string;

    procedure BuildMenu;
    procedure BuildLayout;
    procedure RefreshAllTracksUI;

    procedure FileNewClick(Sender: TObject);
    procedure FileOpenClick(Sender: TObject);
    procedure FileSaveClick(Sender: TObject);
    procedure FileSaveAsClick(Sender: TObject);
    procedure FileExportClick(Sender: TObject);
    procedure FileExitClick(Sender: TObject);
    procedure EditPreferencesClick(Sender: TObject);
    procedure EditUndoClick(Sender: TObject);
    procedure EditCopyClick(Sender: TObject);
    procedure EditPasteClick(Sender: TObject);
    procedure EditDuplicateClick(Sender: TObject);
    procedure EditSplitClick(Sender: TObject);
    procedure EditDeleteClick(Sender: TObject);
    procedure ViewZoomInClick(Sender: TObject);
    procedure ViewZoomOutClick(Sender: TObject);
    procedure TrackAddClick(Sender: TObject);
    procedure HelpAboutClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure PlayPauseClick(Sender: TObject);
    procedure RecordClick(Sender: TObject);
    procedure FinalizeRecording;
    procedure TransportPanelResize(Sender: TObject);
    procedure DevicePanelResize(Sender: TObject);
    procedure TempoEditEditingDone(Sender: TObject);
    procedure GridTrackBarChange(Sender: TObject);
    procedure ArrangementViewFileDrop(Sender: TObject; ATrackIndex: Integer;
      AFramePosition: Int64; const AFilePath: string);
    procedure ArrangementViewSeek(Sender: TObject; AFrameOffset: Int64);
    procedure ArrangementViewKeyboardTrackChanged(Sender: TObject);
    procedure ArrangementViewClipSelectionChanged(Sender: TObject);
    procedure WarpEditorClipChanged(Sender: TObject);
    procedure InstrumentEditorChanged(Sender: TObject);
    procedure WarpRepitchToggleClick(Sender: TObject);
    procedure UpdateWarpRepitchToggleLook;
    procedure MetronomeToggleClick(Sender: TObject);
    procedure UpdateMetronomeToggleLook;
    procedure SwingDivisionButtonClick(Sender: TObject);
    procedure SwingSliderChange(Sender: TObject);
    procedure UpdateSwingControls;
    procedure WarpZoomInClick(Sender: TObject);
    procedure WarpZoomOutClick(Sender: TObject);
    procedure InstrumentZoomInClick(Sender: TObject);
    procedure InstrumentZoomOutClick(Sender: TObject);
    procedure RefreshWarpWidgetSize;
    procedure RefreshInstrumentWidgetSize;
    function EffectsRackBaseLeft: Integer;
    function EffectsRackTotalWidth: Integer;
    procedure RebuildEffectWidgets;
    procedure EffectRackChanged(Sender: TObject);
    procedure AddEffectToCurrentTrack(AKind: Integer);
    procedure AddLowpassEffectClick(Sender: TObject);
    procedure AddEQ4EffectClick(Sender: TObject);
    procedure AddLimiterEffectClick(Sender: TObject);
    procedure AddChorusEffectClick(Sender: TObject);
    procedure AddReverbEffectClick(Sender: TObject);
    procedure BuildEffectsMenu;
    procedure DevicePanelMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure DeviceScrollBarChange(Sender: TObject);
    procedure UpdateDevicePanelScroll;
    procedure DevicePanelDragOver(Sender, Source: TObject; X, Y: Integer;
      State: TDragState; var Accept: Boolean);
    procedure DevicePanelDragDrop(Sender, Source: TObject; X, Y: Integer);
    procedure FileBrowserFileActivate(Sender: TObject; const AFilePath: string);
    procedure LoadInstrumentForKeyboardTrack(const APath: string);
    procedure UpdateDevicePanel;
    procedure InstrumentDeleteClick(Sender: TObject);
    procedure OctaveMinusClick(Sender: TObject);
    procedure OctavePlusClick(Sender: TObject);
    procedure TriggerKeyboardNote(ASemitoneOffset: Integer);
    procedure PlaybackPollTimerTimer(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

constructor TForm1.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Caption := 'Eris';
  FLastEffectsRackTrack := -2;
  BuildMenu;
  BuildEffectsMenu;
  BuildLayout;
  AudioEngineInit;
  KeyPreview := True;
  OnKeyDown := @FormKeyDown;
end;

destructor TForm1.Destroy;
var
  i: Integer;
begin
  AudioEngineShutdown;
  for i := 0 to High(Project.SamplePool) do
    if Project.SamplePool[i].Data <> nil then
      FreeMem(Project.SamplePool[i].Data);
  inherited Destroy;
end;

procedure TForm1.BuildMenu;

  function AddMenu(const ACaption: string): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    FMainMenu.Items.Add(Result);
  end;

  function AddItem(AParent: TMenuItem; const ACaption: string;
    AOnClick: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    Result.OnClick := AOnClick;
    AParent.Add(Result);
  end;

  procedure AddSeparator(AParent: TMenuItem);
  begin
    AddItem(AParent, '-', nil);
  end;

var
  FileMenu, EditMenu, ViewMenu, TrackMenu, HelpMenu, UndoItem,
  ZoomInItem, ZoomOutItem, CopyItem, PasteItem, DuplicateItem, SplitItem,
  DeleteItem, OpenItem, SaveItem, SaveAsItem, AddTrackItem: TMenuItem;
begin
  FMainMenu := TMainMenu.Create(Self);
  Menu := FMainMenu;

  FileMenu := AddMenu('&File');
  AddItem(FileMenu, '&New', @FileNewClick);
  OpenItem := AddItem(FileMenu, '&Open...', @FileOpenClick);
  OpenItem.ShortCut := Menus.ShortCut(Ord('O'), [ssCtrl]);
  SaveItem := AddItem(FileMenu, '&Save', @FileSaveClick);
  SaveItem.ShortCut := Menus.ShortCut(Ord('S'), [ssCtrl]);
  SaveAsItem := AddItem(FileMenu, 'Save &As...', @FileSaveAsClick);
  SaveAsItem.ShortCut := Menus.ShortCut(Ord('S'), [ssCtrl, ssShift]);
  AddSeparator(FileMenu);
  AddItem(FileMenu, '&Export...', @FileExportClick);
  AddSeparator(FileMenu);
  AddItem(FileMenu, 'E&xit', @FileExitClick);

  EditMenu := AddMenu('&Edit');
  UndoItem := AddItem(EditMenu, '&Undo', @EditUndoClick);
  UndoItem.ShortCut := Menus.ShortCut(Ord('Z'), [ssCtrl]);
  AddSeparator(EditMenu);
  CopyItem := AddItem(EditMenu, '&Copy', @EditCopyClick);
  CopyItem.ShortCut := Menus.ShortCut(Ord('C'), [ssCtrl]);
  PasteItem := AddItem(EditMenu, '&Paste', @EditPasteClick);
  PasteItem.ShortCut := Menus.ShortCut(Ord('V'), [ssCtrl]);
  DuplicateItem := AddItem(EditMenu, 'D&uplicate', @EditDuplicateClick);
  DuplicateItem.ShortCut := Menus.ShortCut(Ord('D'), [ssCtrl]);
  SplitItem := AddItem(EditMenu, 'S&plit', @EditSplitClick);
  SplitItem.ShortCut := Menus.ShortCut(Ord('E'), [ssCtrl]);
  DeleteItem := AddItem(EditMenu, 'D&elete', @EditDeleteClick);
  DeleteItem.ShortCut := Menus.ShortCut(VK_DELETE, []);
  AddSeparator(EditMenu);
  AddItem(EditMenu, '&Preferences...', @EditPreferencesClick);

  ViewMenu := AddMenu('&View');
  ZoomInItem := AddItem(ViewMenu, 'Zoom &In', @ViewZoomInClick);
  ZoomInItem.ShortCut := Menus.ShortCut(VK_OEM_PLUS, [ssCtrl]);
  ZoomOutItem := AddItem(ViewMenu, 'Zoom &Out', @ViewZoomOutClick);
  ZoomOutItem.ShortCut := Menus.ShortCut(VK_OEM_MINUS, [ssCtrl]);

  TrackMenu := AddMenu('&Track');
  AddTrackItem := AddItem(TrackMenu, '&Add Track', @TrackAddClick);
  AddTrackItem.ShortCut := Menus.ShortCut(Ord('N'), [ssCtrl]);

  HelpMenu := AddMenu('&Help');
  AddItem(HelpMenu, '&About...', @HelpAboutClick);
end;

procedure TForm1.BuildLayout;

  function AddZoomButtons(AParent: TWinControl; AZoomInClick, AZoomOutClick: TNotifyEvent): TPanel;
  var
    BtnPlus, BtnMinus: TButton;
  begin
    Result := TPanel.Create(Self);
    Result.Parent := AParent;
    Result.Align := alLeft;
    Result.Width := Px(22);
    Result.BevelOuter := bvNone;

    BtnPlus := TButton.Create(Self);
    BtnPlus.Parent := Result;
    BtnPlus.Caption := '+';
    BtnPlus.Align := alTop;
    BtnPlus.Height := Px(24);
    BtnPlus.OnClick := AZoomInClick;

    BtnMinus := TButton.Create(Self);
    BtnMinus.Parent := Result;
    BtnMinus.Caption := '-';
    BtnMinus.Align := alBottom;
    BtnMinus.Height := Px(24);
    BtnMinus.OnClick := AZoomOutClick;
  end;

var
  WarpButtonsPanel: TPanel;
begin
  Width := 1280;
  Height := 800;

  FTransportPanel := TPanel.Create(Self);
  FTransportPanel.Parent := Self;
  FTransportPanel.Align := alTop;
  FTransportPanel.Height := Px(52);
  FTransportPanel.BevelOuter := bvNone;
  FTransportPanel.OnResize := @TransportPanelResize;

  FTempoLabel := TLabel.Create(Self);
  FTempoLabel.Parent := FTransportPanel;
  FTempoLabel.Caption := 'Tempo:';
  FTempoLabel.Left := Px(8);
  FTempoLabel.Top := Px(19);

  FTempoEdit := TEdit.Create(Self);
  FTempoEdit.Parent := FTransportPanel;
  FTempoEdit.Text := IntToStr(Round(Project.DefaultTempoBPM));
  FTempoEdit.Left := Px(64);
  FTempoEdit.Top := Px(14);
  FTempoEdit.Width := Px(64);
  FTempoEdit.OnEditingDone := @TempoEditEditingDone;

  { timeline grid resolution - pinned to the far right of the top bar }
  FGridTrackBar := TTrackBar.Create(Self);
  FGridTrackBar.Parent := FTransportPanel;
  FGridTrackBar.Min := 0;
  FGridTrackBar.Max := 4;
  FGridTrackBar.Frequency := 1;
  FGridTrackBar.TickStyle := tsAuto;
  FGridTrackBar.Position := 0; { 1/16, finest - matches ArrangementView's default }
  FGridTrackBar.Width := Px(140);
  FGridTrackBar.Height := Px(36);
  FGridTrackBar.ShowHint := True;
  FGridTrackBar.Hint := 'Timeline grid resolution';
  FGridTrackBar.OnChange := @GridTrackBarChange;

  FGridLabel := TLabel.Create(Self);
  FGridLabel.Parent := FTransportPanel;
  FGridLabel.Caption := '1/16';

  { tempo-aware metronome toggle - sits just left of Stop, colored when on }
  FMetronomeToggle := TSpeedButton.Create(Self);
  FMetronomeToggle.Parent := FTransportPanel;
  FMetronomeToggle.Caption := 'M';
  FMetronomeToggle.Width := Px(32);
  FMetronomeToggle.Height := Px(32);
  FMetronomeToggle.Font.Style := [fsBold];
  FMetronomeToggle.ShowHint := True;
  FMetronomeToggle.Hint := 'Metronome (tempo-aware click on every beat during playback)';
  FMetronomeToggle.OnClick := @MetronomeToggleClick;
  UpdateMetronomeToggleLook;

  FStopButton := TButton.Create(Self);
  FStopButton.Parent := FTransportPanel;
  FStopButton.Caption := 'Stop';
  FStopButton.Width := Px(80);
  FStopButton.Height := Px(32);
  FStopButton.OnClick := @StopClick;

  FPlayPauseButton := TButton.Create(Self);
  FPlayPauseButton.Parent := FTransportPanel;
  FPlayPauseButton.Caption := 'Play';
  FPlayPauseButton.Width := Px(80);
  FPlayPauseButton.Height := Px(32);
  FPlayPauseButton.OnClick := @PlayPauseClick;

  FRecordButton := TButton.Create(Self);
  FRecordButton.Parent := FTransportPanel;
  FRecordButton.Caption := 'Record';
  FRecordButton.Width := Px(80);
  FRecordButton.Height := Px(32);
  FRecordButton.OnClick := @RecordClick;

  FDevicePanel := TPanel.Create(Self);
  FDevicePanel.Parent := Self;
  FDevicePanel.Align := alBottom;
  FDevicePanel.Height := Px(WidgetTop + WidgetHeight + WidgetBottomMargin);
  FDevicePanel.BevelOuter := bvNone;
  FDevicePanel.OnDragOver := @DevicePanelDragOver;
  FDevicePanel.OnDragDrop := @DevicePanelDragDrop;
  FDevicePanel.OnResize := @DevicePanelResize;
  FDevicePanel.OnMouseDown := @DevicePanelMouseDown;

  { horizontal scroll for the device widgets - only shown if their total
    width outgrows the panel, e.g. when the warp widget expands for a long
    clip; sits at the very top of the bottom bar, opposite the timeline's
    own scrollbar at the bottom of the arrangement view }
  FDeviceScrollBar := TScrollBar.Create(Self);
  FDeviceScrollBar.Parent := FDevicePanel;
  FDeviceScrollBar.Kind := sbHorizontal;
  FDeviceScrollBar.Align := alTop;
  FDeviceScrollBar.Height := Px(DeviceScrollBarHeight);
  FDeviceScrollBar.Visible := False;
  FDeviceScrollBar.OnChange := @DeviceScrollBarChange;

  { "Track N" widget - always present, identifies whose device chain this is.
    Also hosts the per-track swing controls (only meaningful - and only
    visible - for a real track, not Master/no-track). }
  FTrackWidget := TPanel.Create(Self);
  FTrackWidget.Parent := FDevicePanel;
  FTrackWidget.Left := Px(TrackWidgetLeft);
  FTrackWidget.Top := Px(WidgetTop);
  FTrackWidget.Width := Px(TrackWidgetWidth);
  FTrackWidget.Height := Px(WidgetHeight);
  FTrackWidget.BevelOuter := bvRaised;

  FTrackWidgetLabel := TLabel.Create(Self);
  FTrackWidgetLabel.Parent := FTrackWidget;
  FTrackWidgetLabel.Align := alTop;
  FTrackWidgetLabel.Height := Px(44);
  FTrackWidgetLabel.Alignment := taCenter;
  FTrackWidgetLabel.Layout := tlCenter;
  FTrackWidgetLabel.Caption := 'No Track';

  FSwingLabel := TLabel.Create(Self);
  FSwingLabel.Parent := FTrackWidget;
  FSwingLabel.Left := Px(8);
  FSwingLabel.Top := Px(52);
  FSwingLabel.Caption := 'Swing';

  { SP-1200-style swing division toggle - which grid unit swing pairs up.
    Defaults to 16th notes; click to switch to 8th notes (or back). }
  FSwingDivisionButton := TSpeedButton.Create(Self);
  FSwingDivisionButton.Parent := FTrackWidget;
  FSwingDivisionButton.Caption := '1/16';
  FSwingDivisionButton.Left := Px(TrackWidgetWidth) - Px(44);
  FSwingDivisionButton.Top := Px(48);
  FSwingDivisionButton.Width := Px(36);
  FSwingDivisionButton.Height := Px(22);
  FSwingDivisionButton.ShowHint := True;
  FSwingDivisionButton.Hint := 'Swing grid: click to switch between 1/8 and 1/16 notes';
  FSwingDivisionButton.OnClick := @SwingDivisionButtonClick;

  { snaps to the SP-1200's own 6 swing detents (50=straight, then its five
    real settings 54/58/63/67/71) - Position is an index into SwingDetents,
    not the raw percentage, so it always lands exactly on one of those }
  FSwingSlider := TTrackBar.Create(Self);
  FSwingSlider.Parent := FTrackWidget;
  FSwingSlider.Left := Px(8);
  FSwingSlider.Top := Px(74);
  FSwingSlider.Width := Px(TrackWidgetWidth) - Px(16);
  FSwingSlider.Height := Px(26);
  FSwingSlider.Min := 0;
  FSwingSlider.Max := High(SwingDetents);
  FSwingSlider.TickStyle := tsAuto;
  FSwingSlider.ShowHint := True;
  FSwingSlider.Hint := 'Swing amount (SP-1200 detents: 50/54/58/63/67/71%)';
  FSwingSlider.OnChange := @SwingSliderChange;

  FSwingValueLabel := TLabel.Create(Self);
  FSwingValueLabel.Parent := FTrackWidget;
  FSwingValueLabel.Left := Px(8);
  FSwingValueLabel.Top := Px(102);
  FSwingValueLabel.Caption := '50% (straight)';

  { instrument widget - one "device" holding the sample dragged in for
    keyboard play on the currently selected track }
  FInstrumentWidget := TPanel.Create(Self);
  FInstrumentWidget.Parent := FDevicePanel;
  FInstrumentWidget.Left := Px(InstrumentSlotLeft);
  FInstrumentWidget.Top := Px(WidgetTop);
  FInstrumentWidget.Width := Px(220);
  FInstrumentWidget.Height := Px(WidgetHeight);
  FInstrumentWidget.BevelOuter := bvRaised;
  FInstrumentWidget.Visible := False;

  FInstrumentDeleteButton := TButton.Create(Self);
  FInstrumentDeleteButton.Parent := FInstrumentWidget;
  FInstrumentDeleteButton.Caption := 'X';
  FInstrumentDeleteButton.Left := FInstrumentWidget.Width - Px(24);
  FInstrumentDeleteButton.Top := Px(4);
  FInstrumentDeleteButton.Width := Px(20);
  FInstrumentDeleteButton.Height := Px(20);
  FInstrumentDeleteButton.OnClick := @InstrumentDeleteClick;

  FInstrumentNameLabel := TLabel.Create(Self);
  FInstrumentNameLabel.Parent := FInstrumentWidget;
  FInstrumentNameLabel.Left := Px(8);
  FInstrumentNameLabel.Top := Px(8);
  FInstrumentNameLabel.Width := FInstrumentWidget.Width - Px(40);
  FInstrumentNameLabel.Height := Px(40);
  FInstrumentNameLabel.AutoSize := False;
  FInstrumentNameLabel.WordWrap := True;

  FOctaveLabel := TLabel.Create(Self);
  FOctaveLabel.Parent := FInstrumentWidget;
  FOctaveLabel.Left := Px(8);
  FOctaveLabel.Top := Px(64);
  FOctaveLabel.Caption := 'Octave: 0';

  FOctaveMinusButton := TButton.Create(Self);
  FOctaveMinusButton.Parent := FInstrumentWidget;
  FOctaveMinusButton.Caption := '-';
  FOctaveMinusButton.Left := Px(8);
  FOctaveMinusButton.Top := Px(88);
  FOctaveMinusButton.Width := Px(28);
  FOctaveMinusButton.Height := Px(24);
  FOctaveMinusButton.OnClick := @OctaveMinusClick;

  FOctavePlusButton := TButton.Create(Self);
  FOctavePlusButton.Parent := FInstrumentWidget;
  FOctavePlusButton.Caption := '+';
  FOctavePlusButton.Left := Px(44);
  FOctavePlusButton.Top := Px(88);
  FOctavePlusButton.Width := Px(28);
  FOctavePlusButton.Height := Px(24);
  FOctavePlusButton.OnClick := @OctavePlusClick;

  FDropHintLabel := TLabel.Create(Self);
  FDropHintLabel.Parent := FDevicePanel;
  FDropHintLabel.Left := Px(InstrumentSlotLeft);
  FDropHintLabel.Top := Px(WidgetTop);
  { pinned to the same footprint as the instrument widget it stands in for -
    AutoSize off + WordWrap so a long hint never bleeds into whatever's
    parented to its right (e.g. the master bus effects rack) }
  FDropHintLabel.AutoSize := False;
  FDropHintLabel.WordWrap := True;
  FDropHintLabel.Width := Px(220);
  FDropHintLabel.Height := Px(WidgetHeight);
  FDropHintLabel.Caption := 'Select a track to load an instrument';

  { warp editor widget - appears when a clip is selected on the timeline }
  FWarpWidget := TPanel.Create(Self);
  FWarpWidget.Parent := FDevicePanel;
  FWarpWidget.Left := Px(WarpSlotLeft);
  FWarpWidget.Top := Px(WidgetTop);
  FWarpWidget.Width := Px(500);
  FWarpWidget.Height := Px(WidgetHeight);
  FWarpWidget.BevelOuter := bvRaised;
  FWarpWidget.Visible := False;
  FWarpWidget.Caption := '';

  WarpButtonsPanel := AddZoomButtons(FWarpWidget, @WarpZoomInClick, @WarpZoomOutClick);
  WarpButtonsPanel.Width := Px(34); { a bit wider than the plain zoom column, so the toggle isn't tiny }

  { Re-Pitch toggle - the classic continuous vari-speed warp (same tech as
    keyboard pitch-shifting), as an alternative to the default Beats mode.
    Lives in the same left-side handle as the zoom +/- buttons. State is
    shown by color/caption, not just the native pressed-look, which is too
    subtle to notice at a glance. }
  FWarpRepitchToggle := TSpeedButton.Create(Self);
  FWarpRepitchToggle.Parent := WarpButtonsPanel;
  FWarpRepitchToggle.Caption := 'RP';
  FWarpRepitchToggle.Align := alBottom;
  FWarpRepitchToggle.Height := Px(40);
  FWarpRepitchToggle.Font.Style := [fsBold];
  FWarpRepitchToggle.ShowHint := True;
  FWarpRepitchToggle.Hint := 'Re-Pitch warp mode (continuous vari-speed, changes pitch)' +
    LineEnding + 'instead of the default Beats mode (preserves pitch)';
  FWarpRepitchToggle.OnClick := @WarpRepitchToggleClick;

  FWarpEditor := TWarpEditor.Create(Self);
  FWarpEditor.Parent := FWarpWidget;
  FWarpEditor.Align := alClient;
  FWarpEditor.OnClipChanged := @WarpEditorClipChanged;

  { instrument (keyboard-play) waveform editor - shares the same slot as the
    warp widget, shown instead of it when no clip is selected on the timeline }
  FInstrumentEditorWidget := TPanel.Create(Self);
  FInstrumentEditorWidget.Parent := FDevicePanel;
  FInstrumentEditorWidget.Left := Px(WarpSlotLeft);
  FInstrumentEditorWidget.Top := Px(WidgetTop);
  FInstrumentEditorWidget.Width := Px(400);
  FInstrumentEditorWidget.Height := Px(WidgetHeight);
  FInstrumentEditorWidget.BevelOuter := bvRaised;
  FInstrumentEditorWidget.Visible := False;
  FInstrumentEditorWidget.Caption := '';

  AddZoomButtons(FInstrumentEditorWidget, @InstrumentZoomInClick, @InstrumentZoomOutClick);

  FInstrumentEditor := TInstrumentEditor.Create(Self);
  FInstrumentEditor.Parent := FInstrumentEditorWidget;
  FInstrumentEditor.Align := alClient;
  FInstrumentEditor.OnChanged := @InstrumentEditorChanged;

  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Align := alBottom;

  FFileBrowser := TFileBrowser.Create(Self);
  FFileBrowser.Parent := Self;
  FFileBrowser.Align := alLeft;
  FFileBrowser.Width := Px(220);
  FFileBrowser.Constraints.MinWidth := Px(120);
  FFileBrowser.Constraints.MaxWidth := Px(600);
  FFileBrowser.OnFileActivate := @FileBrowserFileActivate;

  { the default splitter width is a handful of unscaled pixels - at a HiDPI
    Xft.dpi setting that's a sliver too thin to reliably grab, which is what
    made this look like it couldn't be dragged at all }
  FFileBrowserSplitter := TSplitter.Create(Self);
  FFileBrowserSplitter.Parent := Self;
  FFileBrowserSplitter.Align := alLeft;
  FFileBrowserSplitter.Width := Px(6);

  FArrangementView := TArrangementView.Create(Self);
  FArrangementView.Parent := Self;
  FArrangementView.Align := alClient;
  FArrangementView.OnFileDrop := @ArrangementViewFileDrop;
  FArrangementView.OnSeek := @ArrangementViewSeek;
  FArrangementView.OnKeyboardTrackChanged := @ArrangementViewKeyboardTrackChanged;
  FArrangementView.OnClipSelectionChanged := @ArrangementViewClipSelectionChanged;

  TransportPanelResize(FTransportPanel);

  FPlaybackPollTimer := TTimer.Create(Self);
  FPlaybackPollTimer.Interval := 150;
  FPlaybackPollTimer.OnTimer := @PlaybackPollTimerTimer;
  FPlaybackPollTimer.Enabled := True;
end;

procedure TForm1.RefreshAllTracksUI;
var
  t: Integer;
begin
  AudioEngineStop;
  AudioEngineSeek(0);
  FArrangementView.ClearSelection;
  FArrangementView.SetCursorFrame(0);
  for t := 0 to Project.TrackCount - 1 do
    FArrangementView.RefreshTrack(t);
  FTempoEdit.Text := IntToStr(Round(Project.TempoBPM));
  FPlayPauseButton.Caption := 'Play';
  UpdateDevicePanel;
end;

procedure TForm1.FileNewClick(Sender: TObject);
begin
  Project.NewProject;
  FCurrentProjectPath := '';
  RefreshAllTracksUI;
end;

procedure TForm1.FileOpenClick(Sender: TObject);
var
  Dlg: TOpenDialog;
begin
  Dlg := TOpenDialog.Create(Self);
  try
    Dlg.Title := 'Open Eris Project';
    Dlg.Filter := 'Eris Project (*.er)|*.er';
    if not Dlg.Execute then
      Exit;

    if not LoadProject(Dlg.FileName) then
    begin
      ShowMessage('Could not load project "' + Dlg.FileName + '".');
      Exit;
    end;

    FCurrentProjectPath := Dlg.FileName;
    RefreshAllTracksUI;
  finally
    Dlg.Free;
  end;
end;

procedure TForm1.FileSaveClick(Sender: TObject);
begin
  if FCurrentProjectPath = '' then
    FileSaveAsClick(Sender)
  else if not SaveProject(FCurrentProjectPath) then
    ShowMessage('Could not save project "' + FCurrentProjectPath + '".');
end;

procedure TForm1.FileSaveAsClick(Sender: TObject);
var
  Dlg: TSaveDialog;
  Path: string;
begin
  Dlg := TSaveDialog.Create(Self);
  try
    Dlg.Title := 'Save Eris Project As';
    Dlg.Filter := 'Eris Project (*.er)|*.er';
    Dlg.DefaultExt := '.er';
    if not Dlg.Execute then
      Exit;

    Path := Dlg.FileName;
    if LowerCase(ExtractFileExt(Path)) <> '.er' then
      Path := Path + '.er';

    if not SaveProject(Path) then
    begin
      ShowMessage('Could not save project "' + Path + '".');
      Exit;
    end;

    FCurrentProjectPath := Path;
  finally
    Dlg.Free;
  end;
end;

procedure TForm1.FileExportClick(Sender: TObject);
var
  Dlg: TSaveDialog;
  Path: string;
begin
  Dlg := TSaveDialog.Create(Self);
  try
    Dlg.Title := 'Export Arrangement to WAV';
    Dlg.Filter := 'WAV audio (*.wav)|*.wav';
    Dlg.DefaultExt := '.wav';
    if not Dlg.Execute then
      Exit;

    Path := Dlg.FileName;
    if LowerCase(ExtractFileExt(Path)) <> '.wav' then
      Path := Path + '.wav';

    if not RenderProjectToWav(Path) then
      ShowMessage('Nothing to export - the arrangement is empty.')
    else
      ShowMessage('Exported to "' + Path + '".');
  finally
    Dlg.Free;
  end;
end;

procedure TForm1.FileExitClick(Sender: TObject);
begin
  Close;
end;

procedure TForm1.EditPreferencesClick(Sender: TObject);
var
  Dlg: TPrefsForm;
begin
  Dlg := TPrefsForm.Create(Self);
  try
    Dlg.ShowModal;
  finally
    Dlg.Free;
  end;
end;

procedure TForm1.EditUndoClick(Sender: TObject);
var
  TrackIndex: Integer;
begin
  if Project.PopUndo(TrackIndex) then
  begin
    FArrangementView.ClearSelection;
    FArrangementView.RefreshTrack(TrackIndex);
  end;
end;

{ these are also bound as menu shortcuts (not just handled in
  ArrangementView.KeyDown) specifically so they keep working no matter which
  control currently has keyboard focus - the device panel grew a lot of
  focusable widgets (sliders, edit boxes) this session, and raw KeyDown only
  fires for whichever control is focused. Deferring to normal text editing
  when a text box is focused mirrors the same guard FormKeyDown already uses
  for note-triggering. }

procedure TForm1.EditCopyClick(Sender: TObject);
begin
  if ActiveControl is TCustomEdit then
    Exit;
  FArrangementView.CopySelection;
end;

procedure TForm1.EditPasteClick(Sender: TObject);
begin
  if ActiveControl is TCustomEdit then
    Exit;
  FArrangementView.PasteSelection;
end;

procedure TForm1.EditDuplicateClick(Sender: TObject);
begin
  if ActiveControl is TCustomEdit then
    Exit;
  FArrangementView.DuplicateSelection;
end;

procedure TForm1.EditSplitClick(Sender: TObject);
begin
  if ActiveControl is TCustomEdit then
    Exit;
  FArrangementView.SplitAtCursor;
end;

procedure TForm1.EditDeleteClick(Sender: TObject);
begin
  if ActiveControl is TCustomEdit then
    Exit;
  FArrangementView.DeleteSelection;
end;

procedure TForm1.ViewZoomInClick(Sender: TObject);
begin
  FArrangementView.ZoomIn;
end;

procedure TForm1.ViewZoomOutClick(Sender: TObject);
begin
  FArrangementView.ZoomOut;
end;

procedure TForm1.TrackAddClick(Sender: TObject);
begin
  if Project.AddTrack then
    FArrangementView.Invalidate
  else
    ShowMessage(Format('Maximum of %d tracks reached.', [Project.MaxTracks]));
end;

procedure TForm1.HelpAboutClick(Sender: TObject);
begin
  ShowMessage('Eris' + LineEnding + 'A linear-timeline, audio-only DAW.');
end;

procedure TForm1.StopClick(Sender: TObject);
begin
  if AudioEngineRecordState <> RecordStateIdle then
    FinalizeRecording;
  AudioEngineStop;
  AudioEngineSeek(0);
  FArrangementView.SetCursorFrame(0);
  FPlayPauseButton.Caption := 'Play';
end;

procedure TForm1.PlayPauseClick(Sender: TObject);
begin
  if AudioEngineIsPlaying then
  begin
    if AudioEngineRecordState <> RecordStateIdle then
      FinalizeRecording;
    AudioEngineStop;
    FPlayPauseButton.Caption := 'Play';
    Exit;
  end;

  if not AudioEngineHasClip then
    Exit;

  AudioEnginePlay;
  FPlayPauseButton.Caption := 'Pause';
end;

procedure TForm1.RecordClick(Sender: TObject);
begin
  if AudioEngineRecordState <> RecordStateIdle then
  begin
    FinalizeRecording;
    Exit;
  end;

  if FArrangementView.KeyboardTrack < 0 then
  begin
    ShowMessage('Select a track first.');
    Exit;
  end;
  if Project.TrackInstrument[FArrangementView.KeyboardTrack] < 0 then
  begin
    ShowMessage('Load an instrument for this track first.');
    Exit;
  end;

  FRecordTrackIndex := FArrangementView.KeyboardTrack;
  FRecordStartFrame := FArrangementView.CursorFrame;
  AudioEngineSeek(FRecordStartFrame);
  AudioEngineStartCountIn(FRecordTrackIndex);
  FRecordButton.Caption := 'Counting in...';
end;

procedure TForm1.FinalizeRecording;
var
  WasRecording: Boolean;
  Data: PSingle;
  FrameCount: Integer;
  Sample: TSample;
  Clip: TClip;
begin
  WasRecording := AudioEngineRecordState = RecordStateRecording;
  AudioEngineStopRecording;
  FRecordButton.Caption := 'Record';

  if not WasRecording then
    Exit; { cancelled during count-in - nothing to keep }
  if not AudioEngineTakeRecordedAudio(Data, FrameCount) then
    Exit;

  FillChar(Sample, SizeOf(Sample), 0);
  Sample.Data := Data;
  Sample.FrameCount := FrameCount;
  Sample.Channels := 2;
  Sample.SampleRate := AudioEngine.ProjectSampleRate;
  Sample.BaseNote := 60.0;

  Inc(FRecordingCounter);
  Clip.SampleID := Project.AddSampleToPool(Sample,
    'Recording ' + IntToStr(FRecordingCounter), '');
  Clip.Offset := 0;
  Clip.Length := FrameCount;
  Clip.Position := FRecordStartFrame;
  Clip.TrackID := FRecordTrackIndex;
  Clip.PitchSemitones := 0;
  Clip.Gain := 1.0;
  Clip.WarpMode := SampleTypes.WarpModeBeats;

  Project.PushUndoSnapshot(FRecordTrackIndex);
  Project.CommitClipToTrack(FRecordTrackIndex, Clip);
  FArrangementView.RefreshTrack(FRecordTrackIndex);
end;

procedure TForm1.TransportPanelResize(Sender: TObject);
var
  Gap, GroupWidth, GroupLeft, ButtonTop: Integer;
begin
  Gap := Px(8);
  GroupWidth := FMetronomeToggle.Width + Gap + FStopButton.Width + Gap +
    FPlayPauseButton.Width + Gap + FRecordButton.Width;
  GroupLeft := (FTransportPanel.ClientWidth - GroupWidth) div 2;
  ButtonTop := (FTransportPanel.ClientHeight - FPlayPauseButton.Height) div 2;

  FMetronomeToggle.Left := GroupLeft;
  FMetronomeToggle.Top := ButtonTop;
  FStopButton.Left := FMetronomeToggle.Left + FMetronomeToggle.Width + Gap;
  FStopButton.Top := ButtonTop;
  FPlayPauseButton.Left := GroupLeft + FMetronomeToggle.Width + Gap + FStopButton.Width + Gap;
  FPlayPauseButton.Top := ButtonTop;
  FRecordButton.Left := FPlayPauseButton.Left + FPlayPauseButton.Width + Gap;
  FRecordButton.Top := ButtonTop;

  FGridTrackBar.Left := FTransportPanel.ClientWidth - FGridTrackBar.Width - Gap;
  FGridTrackBar.Top := (FTransportPanel.ClientHeight - FGridTrackBar.Height) div 2;
  FGridLabel.Left := FGridTrackBar.Left - FGridLabel.Width - Gap;
  FGridLabel.Top := Px(19);
end;

procedure TForm1.GridTrackBarChange(Sender: TObject);
const
  Divisions: array[0..4] of Integer = (16, 8, 4, 2, 1);
  Labels: array[0..4] of string = ('1/16', '1/8', '1/4', '1/2', '1 bar');
var
  Idx: Integer;
begin
  Idx := FGridTrackBar.Position;
  if (Idx < 0) or (Idx > High(Divisions)) then
    Exit;
  FArrangementView.SetGridDivision(Divisions[Idx]);
  FGridLabel.Caption := Labels[Idx];
  TransportPanelResize(FTransportPanel);
end;

procedure TForm1.TempoEditEditingDone(Sender: TObject);
var
  Value: Integer;
begin
  if not TryStrToInt(Trim(FTempoEdit.Text), Value) then
    Value := Round(Project.DefaultTempoBPM);
  if Value < 20 then
    Value := 20
  else if Value > 999 then
    Value := 999;
  FTempoEdit.Text := IntToStr(Value);
  Project.TempoBPM := Value;
  FArrangementView.Invalidate;
end;

procedure TForm1.ArrangementViewFileDrop(Sender: TObject; ATrackIndex: Integer;
  AFramePosition: Int64; const AFilePath: string);
var
  Sample: TSample;
  Clip: TClip;
begin
  if not DecodeSampleFile(AFilePath, Sample) then
  begin
    ShowMessage('Could not load "' + AFilePath + '" as a WAV file.');
    Exit;
  end;

  Clip.SampleID := Project.AddSampleToPool(Sample, ExtractFileName(AFilePath),
    AFilePath);
  Clip.Offset := 0;
  Clip.Length := Sample.FrameCount;
  Clip.Position := AFramePosition;
  Clip.TrackID := ATrackIndex;
  Clip.PitchSemitones := 0;
  Clip.Gain := 1.0;
  Clip.WarpMode := SampleTypes.WarpModeBeats;

  Project.PushUndoSnapshot(ATrackIndex);
  Project.CommitClipToTrack(ATrackIndex, Clip);
  FArrangementView.RefreshTrack(ATrackIndex);
end;

procedure TForm1.ArrangementViewSeek(Sender: TObject; AFrameOffset: Int64);
begin
  AudioEngineSeek(AFrameOffset);
end;

procedure TForm1.ArrangementViewKeyboardTrackChanged(Sender: TObject);
begin
  UpdateDevicePanel;
end;

procedure TForm1.ArrangementViewClipSelectionChanged(Sender: TObject);
begin
  if FArrangementView.SelectedClipIndex >= 0 then
  begin
    FWarpEditor.SetClip(FArrangementView.SelectedTrack,
      FArrangementView.SelectedClipIndex);
    FWarpWidget.Visible := True;
    RefreshWarpWidgetSize;
    FWarpRepitchToggle.Down :=
      Project.Tracks[FArrangementView.SelectedTrack].Clips[FArrangementView.SelectedClipIndex].WarpMode
      = SampleTypes.WarpModeRePitch;
    UpdateWarpRepitchToggleLook;
  end
  else
    FWarpWidget.Visible := False;
  UpdateDevicePanel;
end;

procedure TForm1.WarpEditorClipChanged(Sender: TObject);
begin
  if FArrangementView.SelectedTrack >= 0 then
    FArrangementView.RefreshTrack(FArrangementView.SelectedTrack);
  RefreshWarpWidgetSize;
end;

procedure TForm1.InstrumentEditorChanged(Sender: TObject);
begin
  { the start/end trim points are read live from Project at each keypress -
    nothing needs to be pushed ahead of time }
end;

procedure TForm1.WarpRepitchToggleClick(Sender: TObject);
var
  Track, ClipIdx: Integer;
begin
  { TSpeedButton only auto-toggles Down for grouped buttons (GroupIndex <> 0)
    - this one is standalone (GroupIndex = 0), so a plain click never flips
    Down on its own; flip it ourselves }
  FWarpRepitchToggle.Down := not FWarpRepitchToggle.Down;

  Track := FArrangementView.SelectedTrack;
  ClipIdx := FArrangementView.SelectedClipIndex;
  if (Track < 0) or (ClipIdx < 0) or
    (ClipIdx > High(Project.Tracks[Track].Clips)) then
  begin
    FWarpRepitchToggle.Down := False; { nothing selected - nothing to toggle }
    UpdateWarpRepitchToggleLook;
    Exit;
  end;

  if FWarpRepitchToggle.Down then
    Project.Tracks[Track].Clips[ClipIdx].WarpMode := SampleTypes.WarpModeRePitch
  else
    Project.Tracks[Track].Clips[ClipIdx].WarpMode := SampleTypes.WarpModeBeats;

  UpdateWarpRepitchToggleLook;
  FArrangementView.RefreshTrack(Track);
  FWarpEditor.Invalidate;
end;

procedure TForm1.MetronomeToggleClick(Sender: TObject);
begin
  { standalone TSpeedButton (GroupIndex = 0) never auto-toggles Down on
    click - only grouped buttons get that for free - so flip it ourselves }
  FMetronomeToggle.Down := not FMetronomeToggle.Down;
  AudioEngineSetMetronomeEnabled(FMetronomeToggle.Down);
  UpdateMetronomeToggleLook;
end;

procedure TForm1.UpdateMetronomeToggleLook;
begin
  if FMetronomeToggle.Down then
  begin
    FMetronomeToggle.Color := clLime;
    FMetronomeToggle.Font.Color := clBlack;
  end
  else
  begin
    FMetronomeToggle.Color := clBtnFace;
    FMetronomeToggle.Font.Color := clWindowText;
  end;
end;

procedure TForm1.SwingDivisionButtonClick(Sender: TObject);
var
  Track: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  if Track < 0 then
    Exit;
  if Project.TrackSwingDivision[Track] = 16 then
    Project.TrackSwingDivision[Track] := 8
  else
    Project.TrackSwingDivision[Track] := 16;
  UpdateSwingControls;
end;

procedure TForm1.SwingSliderChange(Sender: TObject);
var
  Track: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  if Track < 0 then
    Exit;
  Project.TrackSwingPercent[Track] := SwingDetents[FSwingSlider.Position];
  if FSwingSlider.Position = 0 then
    FSwingValueLabel.Caption := '50% (straight)'
  else
    FSwingValueLabel.Caption := IntToStr(SwingDetents[FSwingSlider.Position]) + '%';
end;

procedure TForm1.UpdateSwingControls;
var
  Track, i, Diff, BestIdx, BestDiff: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  FSwingLabel.Visible := Track >= 0;
  FSwingDivisionButton.Visible := Track >= 0;
  FSwingSlider.Visible := Track >= 0;
  FSwingValueLabel.Visible := Track >= 0;
  if Track < 0 then
    Exit;

  if Project.TrackSwingDivision[Track] = 8 then
    FSwingDivisionButton.Caption := '1/8'
  else
    FSwingDivisionButton.Caption := '1/16';

  BestIdx := 0;
  BestDiff := MaxInt;
  for i := 0 to High(SwingDetents) do
  begin
    Diff := Abs(SwingDetents[i] - Round(Project.TrackSwingPercent[Track]));
    if Diff < BestDiff then
    begin
      BestDiff := Diff;
      BestIdx := i;
    end;
  end;
  FSwingSlider.Position := BestIdx;

  if BestIdx = 0 then
    FSwingValueLabel.Caption := '50% (straight)'
  else
    FSwingValueLabel.Caption := IntToStr(SwingDetents[BestIdx]) + '%';
end;

procedure TForm1.UpdateWarpRepitchToggleLook;
begin
  FWarpRepitchToggle.Caption := 'RP';
  if FWarpRepitchToggle.Down then
  begin
    FWarpRepitchToggle.Color := clLime;
    FWarpRepitchToggle.Font.Color := clBlack;
  end
  else
  begin
    FWarpRepitchToggle.Color := clBtnFace;
    FWarpRepitchToggle.Font.Color := clWindowText;
  end;
end;

procedure TForm1.WarpZoomInClick(Sender: TObject);
begin
  WarpEditor.WarpZoomIn;
  RefreshWarpWidgetSize;
end;

procedure TForm1.WarpZoomOutClick(Sender: TObject);
begin
  WarpEditor.WarpZoomOut;
  RefreshWarpWidgetSize;
end;

procedure TForm1.InstrumentZoomInClick(Sender: TObject);
begin
  InstrumentEditor.InstrumentZoomIn;
  RefreshInstrumentWidgetSize;
end;

procedure TForm1.InstrumentZoomOutClick(Sender: TObject);
begin
  InstrumentEditor.InstrumentZoomOut;
  RefreshInstrumentWidgetSize;
end;

procedure TForm1.RefreshWarpWidgetSize;
begin
  if (FArrangementView.SelectedTrack >= 0) and (FArrangementView.SelectedClipIndex >= 0) and
    (FArrangementView.SelectedClipIndex <= High(Project.Tracks[FArrangementView.SelectedTrack].Clips)) then
    FWarpWidget.Width := WarpWidthForFrames(
      Project.Tracks[FArrangementView.SelectedTrack].Clips[FArrangementView.SelectedClipIndex].Length);
  FWarpEditor.Invalidate;
  UpdateDevicePanelScroll;
end;

procedure TForm1.RefreshInstrumentWidgetSize;
var
  Track, SampleID: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  if Track >= 0 then
  begin
    SampleID := Project.TrackInstrument[Track];
    if SampleID >= 0 then
      FInstrumentEditorWidget.Width := InstrumentWidthForFrames(
        Project.SamplePool[SampleID].FrameCount, Project.SamplePool[SampleID].SampleRate);
  end;
  FInstrumentEditor.Invalidate;
  UpdateDevicePanelScroll;
end;

procedure TForm1.RebuildEffectWidgets;
var
  i, Track: Integer;
begin
  for i := 0 to High(FEffectWidgets) do
    FEffectWidgets[i].Free;
  FEffectWidgets := nil;

  Track := FArrangementView.KeyboardTrack;
  FLastEffectsRackTrack := Track;
  if Track = -2 then
  begin
    SetLength(FEffectWidgets, Project.MasterEffectCount);
    for i := 0 to High(FEffectWidgets) do
      FEffectWidgets[i] := TEffectWidget.CreateFor(Self, FDevicePanel, -1, i,
        @EffectRackChanged, True);
  end
  else if Track >= 0 then
  begin
    SetLength(FEffectWidgets, Project.TrackEffectCount[Track]);
    for i := 0 to High(FEffectWidgets) do
      FEffectWidgets[i] := TEffectWidget.CreateFor(Self, FDevicePanel, Track, i,
        @EffectRackChanged);
  end;

  UpdateDevicePanelScroll;
end;

procedure TForm1.EffectRackChanged(Sender: TObject);
begin
  RebuildEffectWidgets;
end;

procedure TForm1.AddEffectToCurrentTrack(AKind: Integer);
var
  Track: Integer;
  Added: Boolean;
begin
  Track := FArrangementView.KeyboardTrack;
  if Track = -2 then
    Added := Project.AddMasterEffect(AKind)
  else if Track >= 0 then
    Added := Project.AddTrackEffect(Track, AKind)
  else
  begin
    ShowMessage('Select a track first.');
    Exit;
  end;
  if not Added then
  begin
    ShowMessage(Format('Maximum of %d effects per track.', [Effects.MaxEffectsPerTrack]));
    Exit;
  end;
  RebuildEffectWidgets;
end;

procedure TForm1.AddLowpassEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekLowpass);
end;

procedure TForm1.AddEQ4EffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekEQ4);
end;

procedure TForm1.AddLimiterEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekLimiter);
end;

procedure TForm1.AddChorusEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekChorus);
end;

procedure TForm1.AddReverbEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekReverb);
end;

procedure TForm1.BuildEffectsMenu;

  function AddCategory(const ACaption: string): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    FEffectsMenu.Items.Add(Result);
  end;

  function AddEffectItem(AParent: TMenuItem; const ACaption: string;
    AOnClick: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    Result.OnClick := AOnClick;
    AParent.Add(Result);
  end;

var
  FiltersItem, EQItem, ModulationItem, ReverbItem, UtilityItem, MasteringItem,
  Placeholder: TMenuItem;
begin
  FEffectsMenu := TPopupMenu.Create(Self);

  FiltersItem := AddCategory('Filters');
  AddEffectItem(FiltersItem, 'LP', @AddLowpassEffectClick);

  EQItem := AddCategory('EQ');
  AddEffectItem(EQItem, '4', @AddEQ4EffectClick);

  ModulationItem := AddCategory('Modulation');
  AddEffectItem(ModulationItem, 'Chorus', @AddChorusEffectClick);

  ReverbItem := AddCategory('Reverb');
  AddEffectItem(ReverbItem, 'Basic Reverb', @AddReverbEffectClick);

  UtilityItem := AddCategory('Utility');
  Placeholder := AddEffectItem(UtilityItem, '(none yet)', nil);
  Placeholder.Enabled := False;

  MasteringItem := AddCategory('Mastering');
  AddEffectItem(MasteringItem, 'Limiter', @AddLimiterEffectClick);
end;

procedure TForm1.DevicePanelMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbRight then
    Exit;
  FEffectsMenu.PopupComponent := FDevicePanel;
  FEffectsMenu.Popup(Mouse.CursorPos.X, Mouse.CursorPos.Y - 140);
end;

function TForm1.EffectsRackBaseLeft: Integer;
begin
  if FWarpWidget.Visible then
    Result := Px(WarpSlotLeft) + FWarpWidget.Width + Px(8)
  else if FInstrumentEditorWidget.Visible then
    Result := Px(WarpSlotLeft) + FInstrumentEditorWidget.Width + Px(8)
  else
    Result := Px(WarpSlotLeft);
end;

function TForm1.EffectsRackTotalWidth: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FEffectWidgets) do
    Result := Result + FEffectWidgets[i].Width + Px(8);
end;

procedure TForm1.DeviceScrollBarChange(Sender: TObject);
var
  Offset, EffLeft, i: Integer;
begin
  Offset := FDeviceScrollBar.Position;
  FTrackWidget.Left := Px(TrackWidgetLeft) - Offset;
  FInstrumentWidget.Left := Px(InstrumentSlotLeft) - Offset;
  FDropHintLabel.Left := Px(InstrumentSlotLeft) - Offset;
  FWarpWidget.Left := Px(WarpSlotLeft) - Offset;
  FInstrumentEditorWidget.Left := Px(WarpSlotLeft) - Offset;

  EffLeft := EffectsRackBaseLeft - Offset;
  for i := 0 to High(FEffectWidgets) do
  begin
    FEffectWidgets[i].Left := EffLeft;
    FEffectWidgets[i].Top := Px(WidgetTop);
    Inc(EffLeft, FEffectWidgets[i].Width + Px(8));
  end;
end;

procedure TForm1.UpdateDevicePanelScroll;
var
  ContentRight, PanelWidth: Integer;
begin
  ContentRight := Px(TrackWidgetLeft) + FTrackWidget.Width;
  if FInstrumentWidget.Visible then
    ContentRight := Max(ContentRight, Px(InstrumentSlotLeft) + FInstrumentWidget.Width);
  if FWarpWidget.Visible then
    ContentRight := Max(ContentRight, Px(WarpSlotLeft) + FWarpWidget.Width)
  else if FInstrumentEditorWidget.Visible then
    ContentRight := Max(ContentRight, Px(WarpSlotLeft) + FInstrumentEditorWidget.Width);
  if Length(FEffectWidgets) > 0 then
    ContentRight := Max(ContentRight, EffectsRackBaseLeft + EffectsRackTotalWidth);
  ContentRight := ContentRight + Px(TrackWidgetLeft); { trailing margin }

  PanelWidth := FDevicePanel.ClientWidth;

  if ContentRight > PanelWidth then
  begin
    FDeviceScrollBar.Visible := True;
    FDeviceScrollBar.Min := 0;
    FDeviceScrollBar.Max := ContentRight;
    FDeviceScrollBar.PageSize := PanelWidth;
    FDeviceScrollBar.LargeChange := PanelWidth;
    FDeviceScrollBar.SmallChange := 32;
    if FDeviceScrollBar.Position > ContentRight - PanelWidth then
      FDeviceScrollBar.Position := ContentRight - PanelWidth;
  end
  else
  begin
    FDeviceScrollBar.Visible := False;
    FDeviceScrollBar.Position := 0;
  end;

  DeviceScrollBarChange(FDeviceScrollBar);
end;

procedure TForm1.DevicePanelResize(Sender: TObject);
begin
  UpdateDevicePanelScroll;
end;

procedure TForm1.DevicePanelDragOver(Sender, Source: TObject; X, Y: Integer;
  State: TDragState; var Accept: Boolean);
begin
  Accept := (FArrangementView.KeyboardTrack >= 0) and (Source is TControl) and
    (TControl(Source).Parent is TFileBrowser);
end;

procedure TForm1.DevicePanelDragDrop(Sender, Source: TObject; X, Y: Integer);
var
  Path: string;
begin
  if not ((Source is TControl) and (TControl(Source).Parent is TFileBrowser)) then
    Exit;

  Path := TFileBrowser(TControl(Source).Parent).SelectedFullPath;
  if Path = '' then
    Exit;

  LoadInstrumentForKeyboardTrack(Path);
end;

procedure TForm1.FileBrowserFileActivate(Sender: TObject; const AFilePath: string);
begin
  LoadInstrumentForKeyboardTrack(AFilePath);
end;

procedure TForm1.LoadInstrumentForKeyboardTrack(const APath: string);
var
  Sample: TSample;
  Track: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  if Track < 0 then
    Exit;

  if not DecodeSampleFile(APath, Sample) then
  begin
    ShowMessage('Could not load "' + APath + '" as a WAV file.');
    Exit;
  end;

  Project.TrackInstrument[Track] := Project.AddSampleToPool(Sample,
    ExtractFileName(APath), APath);
  Project.TrackInstrumentStart[Track] := 0;
  Project.TrackInstrumentEnd[Track] := Sample.FrameCount;
  UpdateDevicePanel;
end;

procedure TForm1.UpdateDevicePanel;
var
  Track, SampleID: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  UpdateSwingControls;

  if Track = -2 then
  begin
    FTrackWidgetLabel.Caption := 'Master';
    FInstrumentWidget.Visible := False;
    FInstrumentEditorWidget.Visible := False;
    FWarpWidget.Visible := False;
    FDropHintLabel.Caption := 'Master bus - no instrument or warp';
    FDropHintLabel.Visible := True;
    if FLastEffectsRackTrack <> Track then
      RebuildEffectWidgets;
    UpdateDevicePanelScroll;
    Exit;
  end;

  if Track < 0 then
  begin
    FTrackWidgetLabel.Caption := 'No Track';
    FInstrumentWidget.Visible := False;
    FInstrumentEditorWidget.Visible := False;
    FDropHintLabel.Caption := 'Select a track to load an instrument';
    FDropHintLabel.Visible := not FWarpWidget.Visible;
    if FLastEffectsRackTrack <> Track then
      RebuildEffectWidgets;
    UpdateDevicePanelScroll;
    Exit;
  end;

  FTrackWidgetLabel.Caption := 'Track ' + IntToStr(Track + 1);

  SampleID := Project.TrackInstrument[Track];
  if SampleID < 0 then
  begin
    FInstrumentWidget.Visible := False;
    FInstrumentEditorWidget.Visible := False;
    FDropHintLabel.Caption := 'Drag a WAV file here to sample it';
    FDropHintLabel.Visible := not FWarpWidget.Visible;
  end
  else
  begin
    FDropHintLabel.Visible := False;
    FInstrumentWidget.Visible := True;
    FInstrumentNameLabel.Caption := Project.SampleNames[SampleID];
    FOctaveLabel.Caption := Format('Octave: %d', [Project.TrackOctave[Track]]);

    FInstrumentEditorWidget.Visible := not FWarpWidget.Visible;
    if FInstrumentEditorWidget.Visible then
    begin
      FInstrumentEditor.SetTrack(Track);
      RefreshInstrumentWidgetSize;
    end;
  end;

  if FLastEffectsRackTrack <> Track then
    RebuildEffectWidgets;
  UpdateDevicePanelScroll;
end;

procedure TForm1.InstrumentDeleteClick(Sender: TObject);
var
  Track: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  if Track < 0 then
    Exit;
  Project.TrackInstrument[Track] := -1;
  UpdateDevicePanel;
end;

procedure TForm1.OctaveMinusClick(Sender: TObject);
var
  Track: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  if Track < 0 then
    Exit;
  if Project.TrackOctave[Track] > -4 then
    Dec(Project.TrackOctave[Track]);
  UpdateDevicePanel;
end;

procedure TForm1.OctavePlusClick(Sender: TObject);
var
  Track: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  if Track < 0 then
    Exit;
  if Project.TrackOctave[Track] < 4 then
    Inc(Project.TrackOctave[Track]);
  UpdateDevicePanel;
end;

procedure TForm1.TriggerKeyboardNote(ASemitoneOffset: Integer);
var
  Track, SampleID, TotalOffset: Integer;
  Sample: TSample;
  StartFrame, EndFrame, TrimmedCount: Int64;
begin
  Track := FArrangementView.KeyboardTrack;
  if Track < 0 then
    Exit;

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
    TrimmedCount, Sample.Channels, TotalOffset, Project.TrackVolume[Track]);
end;

procedure TForm1.PlaybackPollTimerTimer(Sender: TObject);
var
  Track: Integer;
begin
  if AudioEngineIsPlaying then
    FArrangementView.SetCursorFrame(AudioEngineGetPosition)
  else if FPlayPauseButton.Caption = 'Pause' then
    FPlayPauseButton.Caption := 'Play';

  FWarpEditor.SetPlayheadState(AudioEngineGetPosition, AudioEngineIsPlaying);

  if FInstrumentEditorWidget.Visible then
  begin
    Track := FArrangementView.KeyboardTrack;
    if Track >= 0 then
      FInstrumentEditor.SetPlayheadState(
        Project.TrackInstrumentStart[Track] + AudioEngineLiveNotePosition(Track),
        AudioEngineLiveNoteActive(Track));
  end;

  case AudioEngineRecordState of
    RecordStateCountIn:
      FRecordButton.Caption := 'Counting in...';
    RecordStateRecording:
      FRecordButton.Caption := 'Recording... (click to stop)';
    RecordStateIdle:
      if FRecordButton.Caption <> 'Record' then
        FinalizeRecording; { engine auto-stopped (hit the recording cap) }
  end;
end;

function KeyToSemitoneOffset(AKey: Word; out AOffset: Integer): Boolean;
begin
  Result := True;
  case AKey of
    { bottom row - lower octave }
    Ord('Z'): AOffset := 0;
    Ord('S'): AOffset := 1;
    Ord('X'): AOffset := 2;
    Ord('D'): AOffset := 3;
    Ord('C'): AOffset := 4;
    Ord('V'): AOffset := 5;
    Ord('G'): AOffset := 6;
    Ord('B'): AOffset := 7;
    Ord('H'): AOffset := 8;
    Ord('N'): AOffset := 9;
    Ord('J'): AOffset := 10;
    Ord('M'): AOffset := 11;
    { top row - upper octave, OctaMED/Renoise/Impulse Tracker style }
    Ord('Q'): AOffset := 12;
    Ord('2'): AOffset := 13;
    Ord('W'): AOffset := 14;
    Ord('3'): AOffset := 15;
    Ord('E'): AOffset := 16;
    Ord('R'): AOffset := 17;
    Ord('5'): AOffset := 18;
    Ord('T'): AOffset := 19;
    Ord('6'): AOffset := 20;
    Ord('Y'): AOffset := 21;
    Ord('7'): AOffset := 22;
    Ord('U'): AOffset := 23;
    Ord('I'): AOffset := 24;
    Ord('9'): AOffset := 25;
    Ord('O'): AOffset := 26;
    Ord('0'): AOffset := 27;
    Ord('P'): AOffset := 28;
  else
    Result := False;
  end;
end;

procedure TForm1.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  Offset: Integer;
begin
  if ActiveControl is TCustomEdit then
    Exit;

  if Key = VK_SPACE then
  begin
    PlayPauseClick(Self);
    Key := 0;
    Exit;
  end;

  if ssCtrl in Shift then
  begin
    if Key = VK_ADD then
    begin
      FArrangementView.ZoomIn;
      Key := 0;
    end
    else if Key = VK_SUBTRACT then
    begin
      FArrangementView.ZoomOut;
      Key := 0;
    end;
    Exit;
  end;

  if KeyToSemitoneOffset(Key, Offset) then
  begin
    TriggerKeyboardNote(Offset);
    Key := 0;
  end;
end;

end.
