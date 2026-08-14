unit MainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls,
  StdCtrls, ComCtrls, Buttons, LCLType, ArrangementView, PrefsForm, FileBrowser,
  SampleTypes, AudioEngine, Project, ProjectFile, WarpEditor, ThemeScrollBar,
  { Theme last - it shadows Graphics' system colours; see Theme.pas }
  InstrumentEditor, SamplerEditor, Effects, EffectsRack, UIScale, MidiInput,
  WaveformDraw, Theme;

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
      { per-clip gain trim and pitch detune, shown on the warp widget }
      ClipGainMinDb = -24;
      ClipGainMaxDb = 24;
      ClipDetuneMinSemitones = -12;
      ClipDetuneMaxSemitones = 12;
      { the "R" (render) button's own vertical bar on the right edge of the
        warp widget - see FWarpEditor.Width/RefreshWarpWidgetSize, which
        both have to carve this much space back out of the waveform area }
      WarpRightPanelWidth = 34;
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
    FInstrumentWidget: TPanel;
    FInstrumentNameLabel: TLabel;
    FInstrumentDeleteButton: TButton;
    FOctaveLabel: TLabel;
    FOctaveMinusButton: TButton;
    FOctavePlusButton: TButton;
    FDropHintLabel: TLabel;
    FWarpWidget: TPanel;
    FWarpEditor: TWarpEditor;
    FWarpGridButton: TButton;
    FWarpRepitchButton: TSpeedButton;
    FWarpBeatsButton: TSpeedButton;
    FWarpAudioButton: TSpeedButton;
    FWarpTonesButton: TSpeedButton;
    FWarpDragButton: TSpeedButton;
    FWarpRenderButton: TSpeedButton;
    FInstrumentGainSlider: TTrackBar;
    FInstrumentGainValueLabel: TLabel;
    FClipGainSlider: TTrackBar;
    FClipGainValueLabel: TLabel;
    FClipDetuneSlider: TTrackBar;
    FClipDetuneValueLabel: TLabel;
    { AU mode only - see UpdateWarpModeButtons/UpdateClipControls. Position is
      log2(FFT size), not the size itself, so the slider's integer steps land
      exactly on powers of two - see ClipFFTSizeSliderChange. }
    FClipFFTSizeSlider: TTrackBar;
    FClipFFTSizeValueLabel: TLabel;
    FClipFFTSizeLbl: TLabel;
    FInstrumentEditorWidget: TPanel;
    FInstrumentEditor: TInstrumentEditor;
    FInstrumentGridButton: TButton;
    FSamplerWidget: TPanel;
    FSamplerOctaveLabel: TLabel;
    FSamplerOctaveMinusButton: TButton;
    FSamplerOctavePlusButton: TButton;
    FSamplerKeys: TSamplerKeysWidget;
    FSamplerEditorWidget: TPanel;
    FSamplerKeyEditor: TSamplerKeyEditor;
    FSamplerGridButton: TButton;
    FDeviceScrollBar: TThemeScrollBar;
    FEffectsMenu: TPopupMenu;
    FEffectWidgets: array of TEffectWidget;
    FLastEffectsRackTrack: Integer;
    FPlaybackPollTimer: TTimer;
    FCurrentProjectPath: string;
    FNewMenuItem: TMenuItem;
    FOpenMenuItem: TMenuItem;
    FSaveMenuItem: TMenuItem;
    FSaveAsMenuItem: TMenuItem;
    FExportMenuItem: TMenuItem;
    FEditMenu: TMenuItem;
    FTrackMenu: TMenuItem;
    FBackgroundBusy: Boolean;
    FPendingImportTrack: Integer;
    FPendingImportFrame: Int64;

    procedure BuildMenu;
    procedure BuildLayout;
    procedure RefreshAllTracksUI;
    procedure SetBackgroundBusy(ABusy: Boolean; const AStatusText: string;
      AGuardPlayback: Boolean);
    procedure StartProjectSave(const APath: string);
    procedure ProjectLoadThreadTerminate(Sender: TObject);
    procedure ProjectSaveThreadTerminate(Sender: TObject);
    procedure ProjectRenderThreadTerminate(Sender: TObject);
    procedure TimelineImportThreadTerminate(Sender: TObject);
    procedure InstrumentImportThreadTerminate(Sender: TObject);

    procedure FileNewClick(Sender: TObject);
    procedure FileOpenClick(Sender: TObject);
    procedure FileSaveClick(Sender: TObject);
    procedure FileSaveAsClick(Sender: TObject);
    procedure FileExportClick(Sender: TObject);
    procedure FileExitClick(Sender: TObject);
    procedure EditPreferencesClick(Sender: TObject);
    procedure ApplyThemeChange;
    procedure EditUndoClick(Sender: TObject);
    procedure EditCopyClick(Sender: TObject);
    procedure EditPasteClick(Sender: TObject);
    procedure EditDuplicateClick(Sender: TObject);
    procedure EditSplitClick(Sender: TObject);
    procedure EditDeleteClick(Sender: TObject);
    procedure EditConsolidateClick(Sender: TObject);
    procedure ViewZoomInClick(Sender: TObject);
    procedure ViewZoomOutClick(Sender: TObject);
    procedure TrackAddClick(Sender: TObject);
    procedure TrackAddInputClick(Sender: TObject);
    procedure TrackAddSamplerClick(Sender: TObject);
    procedure TrackDeleteClick(Sender: TObject);
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
    procedure ArrangementViewClipActivate(Sender: TObject; ASampleID: Integer;
      AOffset, ALength: Int64);
    procedure ArrangementViewSeek(Sender: TObject; AFrameOffset: Int64);
    procedure ArrangementViewKeyboardTrackChanged(Sender: TObject);
    procedure ArrangementViewClipSelectionChanged(Sender: TObject);
    procedure WarpEditorClipChanged(Sender: TObject);
    procedure InstrumentEditorChanged(Sender: TObject);
    procedure WarpRepitchButtonClick(Sender: TObject);
    procedure WarpBeatsButtonClick(Sender: TObject);
    procedure SetSelectedClipWarpMode(AMode: Integer);
    procedure UpdateWarpModeButtons;
    procedure ClipGainSliderChange(Sender: TObject);
    procedure InstrumentGainSliderChange(Sender: TObject);
    procedure WarpTonesButtonClick(Sender: TObject);
    procedure WarpAudioButtonClick(Sender: TObject);
    procedure WarpDragButtonClick(Sender: TObject);
    procedure WarpRenderButtonClick(Sender: TObject);
    procedure UpdateWindowTitle;
    function WaitForEngineIdle: Boolean;
    procedure ClipDetuneSliderChange(Sender: TObject);
    procedure ClipFFTSizeSliderChange(Sender: TObject);
    procedure UpdateClipControls;
    procedure MetronomeToggleClick(Sender: TObject);
    procedure UpdateMetronomeToggleLook;
    procedure SwingDivisionButtonClick(Sender: TObject);
    procedure SwingSliderChange(Sender: TObject);
    procedure UpdateSwingControls;
    procedure WarpZoomInClick(Sender: TObject);
    procedure WarpZoomOutClick(Sender: TObject);
    procedure WaveformGridButtonClick(Sender: TObject);
    procedure InstrumentZoomInClick(Sender: TObject);
    procedure InstrumentZoomOutClick(Sender: TObject);
    procedure RefreshWarpWidgetSize;
    procedure RefreshInstrumentWidgetSize;
    procedure RefreshSamplerWidgetSize;
    function EffectsRackBaseLeft: Integer;
    function EffectsRackTotalWidth: Integer;
    procedure RebuildEffectWidgets;
    procedure EffectRackChanged(Sender: TObject);
    procedure DeferredRebuildEffectWidgets(Data: PtrInt);
    procedure AddEffectToCurrentTrack(AKind: Integer);
    procedure AddLowpassEffectClick(Sender: TObject);
    procedure AddHighpassEffectClick(Sender: TObject);
    procedure AddBandpassEffectClick(Sender: TObject);
    procedure AddEQ4EffectClick(Sender: TObject);
    procedure AddLimiterEffectClick(Sender: TObject);
    procedure AddChorusEffectClick(Sender: TObject);
    procedure AddReverbEffectClick(Sender: TObject);
    procedure AddFlangerEffectClick(Sender: TObject);
    procedure AddPhaserEffectClick(Sender: TObject);
    procedure AddSidechainEffectClick(Sender: TObject);
    procedure AddDrowningEffectClick(Sender: TObject);
    procedure AddTunerEffectClick(Sender: TObject);
    procedure AddOverdriveEffectClick(Sender: TObject);
    procedure AddExciter422AEffectClick(Sender: TObject);
    procedure AddFuzzFZ2EffectClick(Sender: TObject);
    procedure AddCompressor3630EffectClick(Sender: TObject);
    procedure AddQuadraverbReverbEffectClick(Sender: TObject);
    procedure AddQuadraverbDelayEffectClick(Sender: TObject);
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
    procedure AssignSampleAsKeyboardInstrumentFor(ATrack, ASampleID: Integer;
      AStartFrame, AEndFrame: Int64);
    procedure AssignSampleAsKeyboardInstrument(ASampleID: Integer; AStartFrame, AEndFrame: Int64);
    procedure UpdateDevicePanel;
    procedure InstrumentDeleteClick(Sender: TObject);
    procedure OctaveMinusClick(Sender: TObject);
    procedure OctavePlusClick(Sender: TObject);
    procedure TriggerKeyboardNote(ASemitoneOffset: Integer);
    procedure SamplerKeySelected(Sender: TObject; AKeyIndex: Integer);
    procedure SamplerKeyEditorChanged(Sender: TObject);
    procedure TriggerSamplerKeyNote(ABoxIndex, AOctaveDelta: Integer);
    procedure RefreshMidiSnapshot;
    procedure PlaybackPollTimerTimer(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  Form1: TForm1;

implementation

uses
  { only for the theme dropdown's round trip - the dialog writes Cfg.Theme and
    saves, this form reads it back to decide whether to re-theme }
  Config;

{$R *.lfm}

const
  { MIDI note number that plays a track's instrument at its own native pitch,
    i.e. the MIDI equivalent of the QWERTY layout's offset 0. Middle C. }
  MidiRootNote = 60;

  { a track index no real target can equal - Project's bus targets run down to
    BusSendLast, so anything below that forces the next UpdateDevicePanel to
    rebuild the effects rack rather than assuming it's still current }
  InvalidEffectsRackTrack = Project.BusSendLast - 1;

type
  { One playable voice, resolved down to what AudioEngineTriggerNoteRT needs
    and nothing more - no sample IDs, no indices into anything the main
    thread might reindex underneath us. Data is already advanced past the
    trim start, so the MIDI thread does no arithmetic on Project state. }
  TMidiVoice = record
    Data: PSingle;
    FrameCount: Integer;
    Channels: Integer;
  end;

  { Everything the MIDI callback needs to turn a note number into a voice,
    published by the main thread so the callback never reads Project or the
    LCL. See MidiInput.pas's header for why the callback can't just call
    TriggerKeyboardNote directly. }
  TMidiSnapshot = record
    Valid: Boolean;
    TrackIndex: Integer;
    IsSampler: Boolean;
    Octave: Integer;
    Gain: Single;
    Instrument: TMidiVoice;
    Slots: array[0..Project.SamplerKeysPerOctave - 1] of TMidiVoice;
  end;

var
  { single writer (main thread, RefreshMidiSnapshot), single reader (the MIDI
    driver thread). Valid is cleared for the duration of a rewrite so the
    reader skips a torn record.

    This leaves one narrow window - the reader can pass the Valid test and
    then be descheduled while the main thread reassigns the instrument and
    frees the old sample - which is knowingly not closed here. The audio
    engine already holds raw sample-pool pointers across exactly the same
    window (LiveNotes[t].Data), so closing it properly means refcounting the
    pool, which is a much larger change than adding MIDI in. }
  MidiSnapshot: TMidiSnapshot;

{ Runs on the MIDI driver's thread - see MidiInput.pas's contract. Reads only
  MidiSnapshot and pushes to the engine's lock-free note ring; touches no LCL
  object and no Project global, allocates nothing, and blocks on nothing. }
procedure MidiNoteReceived(ANote, AVelocity: Integer);
var
  Voice: TMidiVoice;
  Index, Octave, Box, Offset: Integer;
  Gain: Single;
begin
  if not MidiSnapshot.Valid then
    Exit;
  { pairs with RefreshMidiSnapshot's barrier - don't let the field reads
    hoist above the Valid check that says they're populated }
  ReadBarrier;

  if MidiSnapshot.TrackIndex < 0 then
    Exit;

  Index := ANote - MidiRootNote;

  if MidiSnapshot.IsSampler then
  begin
    { A Sampler Track has one octave of key boxes, so the note folds into a
      box plus however many octaves above the bank it lands - same mapping
      FormKeyDown does for QWERTY. It can't reuse div/mod the way FormKeyDown
      does, though: those truncate toward zero, and unlike the QWERTY layout
      (offsets 0..28) MIDI reaches well below the root, where truncation
      would hand back a negative box index. Floor toward minus infinity
      instead so notes under middle C wrap onto real keys. }
    if Index >= 0 then
      Octave := Index div Project.SamplerKeysPerOctave
    else
      Octave := -((-Index + Project.SamplerKeysPerOctave - 1)
        div Project.SamplerKeysPerOctave);
    Box := Index - Octave * Project.SamplerKeysPerOctave;
    Voice := MidiSnapshot.Slots[Box];
    Offset := (MidiSnapshot.Octave + Octave) * 12;
  end
  else
  begin
    Voice := MidiSnapshot.Instrument;
    Offset := Index + MidiSnapshot.Octave * 12;
  end;

  if Voice.Data = nil then
    Exit; { empty key, or no instrument loaded on this track }

  { velocity straight onto the instrument's own gain trim. No range limit on
    Offset on purpose: a five-octave controller plus the octave buttons can
    ask for playback rates far outside anything musical, and that is a
    legitimate thing to want out of a sampler. }
  Gain := MidiSnapshot.Gain * (AVelocity / 127);
  AudioEngineTriggerNoteRT(MidiSnapshot.TrackIndex, Voice.Data,
    Voice.FrameCount, Voice.Channels, Offset, Gain);
end;

constructor TForm1.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Caption := 'Eris';
  FLastEffectsRackTrack := Project.BusMaster;
  BuildMenu;
  BuildEffectsMenu;
  BuildLayout;
  AudioEngineInit;
  KeyPreview := True;
  OnKeyDown := @FormKeyDown;
  { a plugged-in USB MIDI keyboard now plays the selected track's instrument
    alongside the QWERTY keys. Returns False and changes nothing when there
    isn't one, so there's no failure to report. Notes are ignored until the
    first RefreshMidiSnapshot arms the snapshot below. }
  MidiInputStart(@MidiNoteReceived);

  {$IFDEF WINDOWS}
  { Win32 paints the old brush through the default WM_ERASEBKGND during a
    resize. Against light grey that flash goes unnoticed; against a dark form
    it reads as the window blinking white. GTK2 does not need it. }
  DoubleBuffered := True;
  {$ENDIF}
  { last, once every control this form owns exists - the walk only sees what
    is already parented, and in System mode it does nothing at all }
  ThemeApply(Self);
end;

destructor TForm1.Destroy;
var
  i: Integer;
begin
  { before AudioEngineShutdown and before the sample pool is freed - once
    this returns, no further MIDI callback can reference either }
  MidiInputStop;
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
  DeleteItem, ConsolidateItem,
  AddTrackItem, AddInputTrackItem, AddSamplerTrackItem, DeleteTrackItem: TMenuItem;
begin
  FMainMenu := TMainMenu.Create(Self);
  Menu := FMainMenu;

  FileMenu := AddMenu('&File');
  FNewMenuItem := AddItem(FileMenu, '&New', @FileNewClick);
  FOpenMenuItem := AddItem(FileMenu, '&Open...', @FileOpenClick);
  FOpenMenuItem.ShortCut := Menus.ShortCut(Ord('O'), [ssCtrl]);
  FSaveMenuItem := AddItem(FileMenu, '&Save', @FileSaveClick);
  FSaveMenuItem.ShortCut := Menus.ShortCut(Ord('S'), [ssCtrl]);
  FSaveAsMenuItem := AddItem(FileMenu, 'Save &As...', @FileSaveAsClick);
  FSaveAsMenuItem.ShortCut := Menus.ShortCut(Ord('S'), [ssCtrl, ssShift]);
  AddSeparator(FileMenu);
  FExportMenuItem := AddItem(FileMenu, '&Export...', @FileExportClick);
  AddSeparator(FileMenu);
  AddItem(FileMenu, 'E&xit', @FileExitClick);

  EditMenu := AddMenu('&Edit');
  FEditMenu := EditMenu;
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
  ConsolidateItem := AddItem(EditMenu, 'Conso&lidate', @EditConsolidateClick);
  ConsolidateItem.ShortCut := Menus.ShortCut(Ord('J'), [ssCtrl]);
  AddSeparator(EditMenu);
  AddItem(EditMenu, '&Preferences...', @EditPreferencesClick);

  ViewMenu := AddMenu('&View');
  ZoomInItem := AddItem(ViewMenu, 'Zoom &In', @ViewZoomInClick);
  ZoomInItem.ShortCut := Menus.ShortCut(VK_OEM_PLUS, [ssCtrl]);
  ZoomOutItem := AddItem(ViewMenu, 'Zoom &Out', @ViewZoomOutClick);
  ZoomOutItem.ShortCut := Menus.ShortCut(VK_OEM_MINUS, [ssCtrl]);

  TrackMenu := AddMenu('&Track');
  FTrackMenu := TrackMenu;
  AddTrackItem := AddItem(TrackMenu, '&Add Track', @TrackAddClick);
  AddTrackItem.ShortCut := Menus.ShortCut(Ord('N'), [ssCtrl]);
  AddInputTrackItem := AddItem(TrackMenu, 'Add &Input Track', @TrackAddInputClick);
  AddInputTrackItem.ShortCut := Menus.ShortCut(Ord('N'), [ssCtrl, ssShift]);
  AddSamplerTrackItem := AddItem(TrackMenu, 'Add Sam&pler Track', @TrackAddSamplerClick);
  AddSamplerTrackItem.ShortCut := Menus.ShortCut(Ord('N'), [ssCtrl, ssAlt]);
  DeleteTrackItem := AddItem(TrackMenu, '&Delete Track', @TrackDeleteClick);
  { Ctrl+Shift+D, not Ctrl+D - Edit > Duplicate already owns plain Ctrl+D,
    and only one of two identically-bound menu items can ever win the
    dispatch, so this shortcut did nothing at all before. }
  DeleteTrackItem.ShortCut := Menus.ShortCut(Ord('D'), [ssCtrl, ssShift]);

  HelpMenu := AddMenu('&Help');
  AddItem(HelpMenu, '&About...', @HelpAboutClick);
end;

procedure TForm1.BuildLayout;

  function AddZoomButtons(AParent: TWinControl; AZoomInClick, AZoomOutClick: TNotifyEvent;
    out AGridButton: TButton): TPanel;
  var
    BtnPlus, BtnMinus: TButton;
  begin
    Result := TPanel.Create(Self);
    Result.Parent := AParent;
    Result.Align := alLeft;
    Result.Width := Px(40);
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

    { waveform grid resolution - cycles 1/4 -> 1/8 -> 1/16 -> 1/32 -> 1/4 }
    AGridButton := TButton.Create(Self);
    AGridButton.Parent := Result;
    AGridButton.Caption := WaveformGridDivisionLabel;
    AGridButton.Align := alClient;
    AGridButton.ShowHint := True;
    AGridButton.Hint := 'Waveform grid resolution';
    AGridButton.OnClick := @WaveformGridButtonClick;
  end;

var
  WarpZoomPanel, WarpButtonsPanel, ClipControlsPanel, RightButtonsPanel: TPanel;
  GainLbl, DetuneLbl, InstGainLbl: TLabel;
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
  FGridTrackBar.Max := 5;
  FGridTrackBar.Frequency := 1;
  FGridTrackBar.TickStyle := tsAuto;
  FGridTrackBar.Position := 3; { 1/4 note - matches ArrangementView's default }
  FGridTrackBar.Width := Px(140);
  FGridTrackBar.Height := Px(36);
  FGridTrackBar.ShowHint := True;
  FGridTrackBar.Hint := 'Timeline grid resolution';
  FGridTrackBar.OnChange := @GridTrackBarChange;

  FGridLabel := TLabel.Create(Self);
  FGridLabel.Parent := FTransportPanel;
  FGridLabel.Caption := '1/4';

  { tempo-aware metronome toggle - sits just left of Stop, colored when on }
  FMetronomeToggle := TSpeedButton.Create(Self);
  FMetronomeToggle.Parent := FTransportPanel;
  FMetronomeToggle.Caption := 'M';
  FMetronomeToggle.Width := Px(32);
  FMetronomeToggle.Height := Px(32);
  FMetronomeToggle.Font.Style := [fsBold];
  { A TSpeedButton with GroupIndex = 0 cannot be Down: LCL's SetDown forces
    the value back to False, so assigning Down in the click handler silently
    did nothing and the metronome could never be switched on at all. Giving it
    its own group (grouping is scoped per parent control) makes Down real, and
    AllowAllUp lets the single button in that group pop back up. Clicking now
    toggles Down natively, so the handler must NOT flip it as well. }
  FMetronomeToggle.GroupIndex := 9;
  FMetronomeToggle.AllowAllUp := True;
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
  FDeviceScrollBar := TThemeScrollBar.Create(Self);
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

  { the percentage lives in this caption rather than its own label under the
    slider: GTK2 gives a TTrackBar a taller minimum height than the Px(26)
    asked for below, so a separate label at Px(102) got overlapped by the
    slider on X11. Folding the value up here keeps it visible and leaves the
    slider the whole rest of the widget. }
  FSwingLabel := TLabel.Create(Self);
  FSwingLabel.Parent := FTrackWidget;
  FSwingLabel.Left := Px(8);
  FSwingLabel.Top := Px(52);
  FSwingLabel.Caption := 'Swing 50%';

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

  { instrument gain trim - the keyboard-play counterpart of the clip gain
    slider in the warp widget, same dB range and same vertical/Reversed
    convention, sat in the empty right-hand column below the delete button.
    Trims the instrument only; the track fader that timeline clips also pass
    through is left alone. }
  InstGainLbl := TLabel.Create(Self);
  InstGainLbl.Parent := FInstrumentWidget;
  InstGainLbl.Left := Px(150);
  InstGainLbl.Top := Px(56);
  InstGainLbl.Caption := 'Gain';

  FInstrumentGainSlider := TTrackBar.Create(Self);
  FInstrumentGainSlider.Parent := FInstrumentWidget;
  FInstrumentGainSlider.Orientation := trVertical;
  FInstrumentGainSlider.Left := Px(150);
  FInstrumentGainSlider.Top := Px(72);
  FInstrumentGainSlider.Width := Px(32);
  FInstrumentGainSlider.Height := Px(80);
  FInstrumentGainSlider.Reversed := True; { up = more gain, same as the clip slider }
  FInstrumentGainSlider.Min := ClipGainMinDb;
  FInstrumentGainSlider.Max := ClipGainMaxDb;
  FInstrumentGainSlider.Position := 0;
  FInstrumentGainSlider.ShowHint := True;
  FInstrumentGainSlider.Hint := 'Instrument gain trim (dB)';
  FInstrumentGainSlider.OnChange := @InstrumentGainSliderChange;

  FInstrumentGainValueLabel := TLabel.Create(Self);
  FInstrumentGainValueLabel.Parent := FInstrumentWidget;
  FInstrumentGainValueLabel.Left := Px(148);
  FInstrumentGainValueLabel.Top := Px(156);
  FInstrumentGainValueLabel.Caption := '0 dB';

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

  { Zoom +/- get their own leftmost column now, separate from the mode
    buttons - five mode buttons plus the zoom pair no longer fit stacked
    in one Px(180)-tall column (188px needed vs 180 available), which was
    hiding the D button. Two columns instead of shrinking buttons further.
    WarpButtonsPanel is created FIRST here so it docks OUTWARD of
    WarpZoomPanel - for alLeft, later-created lands closer to the edge
    (opposite of the alBottom stacking used by the mode buttons below),
    so creating the mode column first pushes the zoom column to the
    true left edge, matching BT/AU/LF/RP/D staying as the inner column. }
  WarpButtonsPanel := TPanel.Create(Self);
  WarpButtonsPanel.Parent := FWarpWidget;
  WarpButtonsPanel.Align := alLeft;
  WarpButtonsPanel.Width := Px(34); { a bit wider than the plain zoom column, so the toggle isn't tiny }
  WarpButtonsPanel.BevelOuter := bvNone;

  WarpZoomPanel := AddZoomButtons(FWarpWidget, @WarpZoomInClick, @WarpZoomOutClick, FWarpGridButton);

  { Warp mode - two dedicated buttons instead of one toggle that renamed
    itself, since a single relabeling button read as ambiguous (couldn't
    tell "this names the active mode" from "this names what clicking does").
    RP sits above BT in the same left-side handle as the zoom +/- buttons.
    Same GroupIndex + AllowAllUp=False makes them mutually exclusive
    natively - exactly one is ever Down, matching WarpMode always being
    either Beats or RePitch. Created BT first, RP second: same-edge
    (alBottom) docking stacks later-added controls above earlier ones, so
    RP ends up above BT as asked. }
  FWarpBeatsButton := TSpeedButton.Create(Self);
  FWarpBeatsButton.Parent := WarpButtonsPanel;
  FWarpBeatsButton.Caption := 'BT';
  FWarpBeatsButton.Align := alBottom;
  FWarpBeatsButton.Height := Px(28);
  FWarpBeatsButton.Font.Style := [fsBold];
  FWarpBeatsButton.GroupIndex := 1;
  FWarpBeatsButton.AllowAllUp := False;
  FWarpBeatsButton.ShowHint := True;
  FWarpBeatsButton.OnClick := @WarpBeatsButtonClick;

  { AU (Audio) - the default mode. Same exclusive group and the same size,
    shape and behavior as the other three; created straight after BT so the
    alBottom stacking puts it directly above it. For sustained harmonic
    material - pads, played instruments, sampler output - which Beats can
    only granulate and LF only handles when it's monophonic; see
    AudioEngine.AudioClipSample. }
  FWarpAudioButton := TSpeedButton.Create(Self);
  FWarpAudioButton.Parent := WarpButtonsPanel;
  FWarpAudioButton.Caption := 'AU';
  FWarpAudioButton.Align := alBottom;
  FWarpAudioButton.Height := Px(28);
  FWarpAudioButton.Font.Style := [fsBold];
  FWarpAudioButton.GroupIndex := 1;
  FWarpAudioButton.AllowAllUp := False;
  FWarpAudioButton.ShowHint := True;
  FWarpAudioButton.OnClick := @WarpAudioButtonClick;

  { LF (Tones) - sits between AU and RP in the same exclusive group. For
    sustained low-frequency material where Beats' transient slicing has
    nothing to slice at; see AudioEngine.TonesClipSample. }
  FWarpTonesButton := TSpeedButton.Create(Self);
  FWarpTonesButton.Parent := WarpButtonsPanel;
  FWarpTonesButton.Caption := 'LF';
  FWarpTonesButton.Align := alBottom;
  FWarpTonesButton.Height := Px(28);
  FWarpTonesButton.Font.Style := [fsBold];
  FWarpTonesButton.GroupIndex := 1;
  FWarpTonesButton.AllowAllUp := False;
  FWarpTonesButton.ShowHint := True;
  FWarpTonesButton.OnClick := @WarpTonesButtonClick;

  FWarpRepitchButton := TSpeedButton.Create(Self);
  FWarpRepitchButton.Parent := WarpButtonsPanel;
  FWarpRepitchButton.Caption := 'RP';
  FWarpRepitchButton.Align := alBottom;
  FWarpRepitchButton.Height := Px(28);
  FWarpRepitchButton.Font.Style := [fsBold];
  FWarpRepitchButton.GroupIndex := 1;
  FWarpRepitchButton.AllowAllUp := False;
  FWarpRepitchButton.ShowHint := True;
  FWarpRepitchButton.OnClick := @WarpRepitchButtonClick;

  { D (Drag) - a blend of RePitch and Tones that slides whole zones of
    audio along the timeline with no resampling at all instead of varying
    playback rate, trading a little silence for zero warp distortion on
    quantize-heavy sampled material; see AudioEngine.DragClipSample and
    warp.md "D (drag) mode". Same exclusive group, created last so the
    alBottom stacking puts it above RP. }
  FWarpDragButton := TSpeedButton.Create(Self);
  FWarpDragButton.Parent := WarpButtonsPanel;
  FWarpDragButton.Caption := 'D';
  FWarpDragButton.Align := alBottom;
  FWarpDragButton.Height := Px(28);
  FWarpDragButton.Font.Style := [fsBold];
  FWarpDragButton.GroupIndex := 1;
  FWarpDragButton.AllowAllUp := False;
  FWarpDragButton.ShowHint := True;
  FWarpDragButton.OnClick := @WarpDragButtonClick;

  { per-clip gain trim and pitch detune - sits between the zoom/RP button
    column and the waveform itself. Detune never changes the clip's own
    Length/Position (see AudioEngine.DetunedClipSourcePosition) - it's an
    independent pitch nudge, not a re-warp. }
  ClipControlsPanel := TPanel.Create(Self);
  ClipControlsPanel.Parent := FWarpWidget;
  ClipControlsPanel.Left := WarpZoomPanel.Width + WarpButtonsPanel.Width;
  ClipControlsPanel.Top := 0;
  ClipControlsPanel.Width := Px(118);
  ClipControlsPanel.Height := Px(WidgetHeight);
  ClipControlsPanel.BevelOuter := bvNone;

  GainLbl := TLabel.Create(Self);
  GainLbl.Parent := ClipControlsPanel;
  GainLbl.Left := Px(4);
  GainLbl.Top := Px(4);
  GainLbl.Caption := 'Gain';

  FClipGainSlider := TTrackBar.Create(Self);
  FClipGainSlider.Parent := ClipControlsPanel;
  { Orientation MUST be set before Width/Height - TCustomTrackBar.SetOrientation
    swaps them automatically (assuming they were sized for the OLD orientation),
    so setting it first here means the sizes set below land correctly instead
    of getting silently transposed into a squashed, badly-overflowing box }
  FClipGainSlider.Orientation := trVertical;
  FClipGainSlider.Left := Px(4);
  FClipGainSlider.Top := Px(20);
  FClipGainSlider.Width := Px(32);
  FClipGainSlider.Height := Px(130);
  FClipGainSlider.Reversed := True; { up = more gain, same convention as the EQ }
  FClipGainSlider.Min := ClipGainMinDb;
  FClipGainSlider.Max := ClipGainMaxDb;
  FClipGainSlider.Position := 0;
  FClipGainSlider.ShowHint := True;
  FClipGainSlider.Hint := 'Clip gain trim (dB)';
  FClipGainSlider.OnChange := @ClipGainSliderChange;

  FClipGainValueLabel := TLabel.Create(Self);
  FClipGainValueLabel.Parent := ClipControlsPanel;
  FClipGainValueLabel.Left := Px(4);
  FClipGainValueLabel.Top := Px(154);
  FClipGainValueLabel.Caption := '0 dB';

  DetuneLbl := TLabel.Create(Self);
  DetuneLbl.Parent := ClipControlsPanel;
  DetuneLbl.Left := Px(42);
  DetuneLbl.Top := Px(4);
  DetuneLbl.Caption := 'Detune';

  FClipDetuneSlider := TTrackBar.Create(Self);
  FClipDetuneSlider.Parent := ClipControlsPanel;
  FClipDetuneSlider.Orientation := trVertical; { see the comment on the gain slider above }
  FClipDetuneSlider.Left := Px(42);
  FClipDetuneSlider.Top := Px(20);
  FClipDetuneSlider.Width := Px(32);
  FClipDetuneSlider.Height := Px(130);
  FClipDetuneSlider.Reversed := True; { up = higher pitch }
  FClipDetuneSlider.Min := ClipDetuneMinSemitones;
  FClipDetuneSlider.Max := ClipDetuneMaxSemitones;
  FClipDetuneSlider.Position := 0;
  FClipDetuneSlider.ShowHint := True;
  FClipDetuneSlider.Hint := 'Pitch detune (semitones) - does not change the clip''s length';
  FClipDetuneSlider.OnChange := @ClipDetuneSliderChange;

  FClipDetuneValueLabel := TLabel.Create(Self);
  FClipDetuneValueLabel.Parent := ClipControlsPanel;
  FClipDetuneValueLabel.Left := Px(42);
  FClipDetuneValueLabel.Top := Px(154);
  FClipDetuneValueLabel.Caption := '0 st';

  { AU mode's STFT grain size - only ever visible while a clip is in AU mode,
    see UpdateWarpModeButtons. Position is log2(size): Min=9 -> 512,
    Max=13 -> 8192, matching warp.md's asked-for range. }
  FClipFFTSizeLbl := TLabel.Create(Self);
  FClipFFTSizeLbl.Parent := ClipControlsPanel;
  FClipFFTSizeLbl.Left := Px(80);
  FClipFFTSizeLbl.Top := Px(4);
  FClipFFTSizeLbl.Caption := 'FFT';

  FClipFFTSizeSlider := TTrackBar.Create(Self);
  FClipFFTSizeSlider.Parent := ClipControlsPanel;
  FClipFFTSizeSlider.Orientation := trVertical;
  FClipFFTSizeSlider.Left := Px(80);
  FClipFFTSizeSlider.Top := Px(20);
  FClipFFTSizeSlider.Width := Px(32);
  FClipFFTSizeSlider.Height := Px(130);
  FClipFFTSizeSlider.Reversed := True; { up = higher resolution, same convention as gain/detune }
  FClipFFTSizeSlider.Min := 9;
  FClipFFTSizeSlider.Max := 13;
  FClipFFTSizeSlider.Position := 12;
  FClipFFTSizeSlider.ShowHint := True;
  FClipFFTSizeSlider.Hint :=
    'AU mode FFT/grain size - higher resolves chords and sustained pads ' +
    'more cleanly, lower tracks fast instrument/vocal chops more tightly';
  FClipFFTSizeSlider.OnChange := @ClipFFTSizeSliderChange;

  FClipFFTSizeValueLabel := TLabel.Create(Self);
  FClipFFTSizeValueLabel.Parent := ClipControlsPanel;
  FClipFFTSizeValueLabel.Left := Px(80);
  FClipFFTSizeValueLabel.Top := Px(154);
  FClipFFTSizeValueLabel.Caption := '4096';

  { "R" (Render): its own vertical bar on the right edge, same style/size as
    the D/AU/LF/RP/BT column on the left - see warp.md "D (drag) mode".
    Align:=alRight docks it to FWarpWidget's right edge automatically as
    RefreshWarpWidgetSize resizes the widget, so nothing else has to track
    its position - only its WIDTH, which FWarpEditor.Width and
    RefreshWarpWidgetSize both subtract back out (WarpRightPanelWidth). }
  RightButtonsPanel := TPanel.Create(Self);
  RightButtonsPanel.Parent := FWarpWidget;
  RightButtonsPanel.Align := alRight;
  RightButtonsPanel.Width := Px(WarpRightPanelWidth);
  RightButtonsPanel.BevelOuter := bvNone;

  FWarpRenderButton := TSpeedButton.Create(Self);
  FWarpRenderButton.Parent := RightButtonsPanel;
  FWarpRenderButton.Caption := 'R';
  FWarpRenderButton.Align := alTop;
  FWarpRenderButton.Height := Px(28);
  FWarpRenderButton.Font.Style := [fsBold];
  FWarpRenderButton.ShowHint := True;
  FWarpRenderButton.Hint := 'Render warped zones to a new clip (not yet implemented)';
  FWarpRenderButton.OnClick := @WarpRenderButtonClick;

  FWarpEditor := TWarpEditor.Create(Self);
  FWarpEditor.Parent := FWarpWidget;
  { explicit bounds + right-anchor instead of Align:=alClient - ClipControlsPanel
    isn't itself Align-managed, so alClient's sibling-avoidance wouldn't have
    known to leave room for it. Right-anchoring still keeps this filling the
    rest of FWarpWidget's width as RefreshWarpWidgetSize resizes it. }
  FWarpEditor.Left := WarpZoomPanel.Width + WarpButtonsPanel.Width + ClipControlsPanel.Width;
  FWarpEditor.Top := 0;
  FWarpEditor.Width := FWarpWidget.Width - FWarpEditor.Left - RightButtonsPanel.Width;
  FWarpEditor.Height := Px(WidgetHeight);
  FWarpEditor.Anchors := [akLeft, akTop, akRight];
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

  AddZoomButtons(FInstrumentEditorWidget, @InstrumentZoomInClick, @InstrumentZoomOutClick, FInstrumentGridButton);

  FInstrumentEditor := TInstrumentEditor.Create(Self);
  FInstrumentEditor.Parent := FInstrumentEditorWidget;
  FInstrumentEditor.Align := alClient;
  FInstrumentEditor.OnChanged := @InstrumentEditorChanged;

  { Sampler Track keyboard widget - shares the instrument slot, shown
    instead of it when the keyboard track is a Sampler Track. Octave
    controls reuse the same TrackOctave click handlers as the instrument
    widget's, since both just Inc/Dec Project.TrackOctave[KeyboardTrack]. }
  FSamplerWidget := TPanel.Create(Self);
  FSamplerWidget.Parent := FDevicePanel;
  FSamplerWidget.Left := Px(InstrumentSlotLeft);
  FSamplerWidget.Top := Px(WidgetTop);
  FSamplerWidget.Width := Px(220);
  FSamplerWidget.Height := Px(WidgetHeight);
  FSamplerWidget.BevelOuter := bvRaised;
  FSamplerWidget.Visible := False;

  FSamplerOctaveLabel := TLabel.Create(Self);
  FSamplerOctaveLabel.Parent := FSamplerWidget;
  FSamplerOctaveLabel.Left := Px(8);
  FSamplerOctaveLabel.Top := Px(8);
  FSamplerOctaveLabel.Caption := 'Octave: 0';

  FSamplerOctaveMinusButton := TButton.Create(Self);
  FSamplerOctaveMinusButton.Parent := FSamplerWidget;
  FSamplerOctaveMinusButton.Caption := '-';
  FSamplerOctaveMinusButton.Left := Px(8);
  FSamplerOctaveMinusButton.Top := Px(32);
  FSamplerOctaveMinusButton.Width := Px(28);
  FSamplerOctaveMinusButton.Height := Px(24);
  FSamplerOctaveMinusButton.OnClick := @OctaveMinusClick;

  FSamplerOctavePlusButton := TButton.Create(Self);
  FSamplerOctavePlusButton.Parent := FSamplerWidget;
  FSamplerOctavePlusButton.Caption := '+';
  FSamplerOctavePlusButton.Left := Px(44);
  FSamplerOctavePlusButton.Top := Px(32);
  FSamplerOctavePlusButton.Width := Px(28);
  FSamplerOctavePlusButton.Height := Px(24);
  FSamplerOctavePlusButton.OnClick := @OctavePlusClick;

  FSamplerKeys := TSamplerKeysWidget.Create(Self);
  FSamplerKeys.Parent := FSamplerWidget;
  FSamplerKeys.Left := Px(8);
  FSamplerKeys.Top := Px(64);
  FSamplerKeys.Width := FSamplerWidget.Width - Px(16);
  FSamplerKeys.Height := Px(100);
  FSamplerKeys.OnKeySelected := @SamplerKeySelected;

  { per-key waveform/marker editor - shares the warp/instrument-editor slot }
  FSamplerEditorWidget := TPanel.Create(Self);
  FSamplerEditorWidget.Parent := FDevicePanel;
  FSamplerEditorWidget.Left := Px(WarpSlotLeft);
  FSamplerEditorWidget.Top := Px(WidgetTop);
  FSamplerEditorWidget.Width := Px(400);
  FSamplerEditorWidget.Height := Px(WidgetHeight);
  FSamplerEditorWidget.BevelOuter := bvRaised;
  FSamplerEditorWidget.Visible := False;
  FSamplerEditorWidget.Caption := '';

  { same zoom level/buttons as the instrument waveform editor - both share
    InstrumentEditor.InstrumentZoomPixelsPerSecond, so one zoom click
    affects whichever of the two is currently shown (and the other next
    time it's shown) via RefreshInstrumentWidgetSize/RefreshSamplerWidgetSize. }
  AddZoomButtons(FSamplerEditorWidget, @InstrumentZoomInClick, @InstrumentZoomOutClick, FSamplerGridButton);

  FSamplerKeyEditor := TSamplerKeyEditor.Create(Self);
  FSamplerKeyEditor.Parent := FSamplerEditorWidget;
  FSamplerKeyEditor.Align := alClient;
  FSamplerKeyEditor.OnChanged := @SamplerKeyEditorChanged;

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
  FArrangementView.OnClipActivate := @ArrangementViewClipActivate;
  FArrangementView.OnSeek := @ArrangementViewSeek;
  FArrangementView.OnKeyboardTrackChanged := @ArrangementViewKeyboardTrackChanged;
  FArrangementView.OnClipSelectionChanged := @ArrangementViewClipSelectionChanged;

  HandleNeeded; { force the align pass so ClientWidth below is real, not a stale pre-handle default }
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
  { one pass over the project, not one per track - see RefreshAllTracks }
  FArrangementView.RefreshAllTracks;

  { Clear every engine track slot above the new project's track count.
    Nothing else does, and FillBlock iterates all MaxTracks slots gated only
    on Project.TrackEnabled[t] - which LoadProject also only writes for
    t < TrackCount, so a slot left over from a bigger project stays enabled
    AND still holds that project's TPlaybackClip array. Those clips' raw
    Transients/Data pointers reference sample arrays the load has already
    replaced: SampleTransients is an array OF DYNAMIC ARRAYS, so SetLength
    genuinely frees the old inner arrays rather than leaking them, and the
    stale slot is then binary-searching freed memory with a garbage count on
    the next Play. That is the open-several-projects-and-the-playhead-locks
    bug - it needs nothing more than one project having fewer tracks than the
    one opened before it. }
  for t := Project.TrackCount to Project.MaxTracks - 1 do
    AudioEngineSetTrackClips(t, nil, 0);

  FTempoEdit.Text := IntToStr(Round(Project.TempoBPM));
  FPlayPauseButton.Caption := 'Play';
  UpdateDevicePanel;
end;

{ Central on/off switch for every background project operation (Open/Save/
  Export/import). Disables the controls that could start a second one or
  mutate Project state out from under it. For Open and import, which
  actually resize Project.SamplePool/Tracks arrays - the same arrays the
  realtime audio callback reads during playback - AGuardPlayback also
  disables the transport (Play/Stop/Record) so a new playback can't start
  mid-resize; painting is left alone (an earlier version of this hid the
  arrangement view/device panel outright, but toggling Visible mid-import
  turned out to disturb their scroll/zoom state - a resize-on-hide glitch
  that pinned the playhead - and caused a visible flash, worse than the
  read-only repaint race it was guarding against). Save and Export don't
  need the transport guard (they don't touch playback), but they DO need
  editing locked out below - SaveProject reads Project.Tracks/SamplePool
  on a background thread with no lock, so an Undo/Split/Delete/Add Track
  mutating those same arrays mid-save (via a menu shortcut, which bypasses
  FArrangementView.Enabled since it's routed through the form's own
  KeyPreview handler) is a real torn-read race that can write corrupt clip
  data to disk. FEditMenu/FTrackMenu below close that gap. }
procedure TForm1.SetBackgroundBusy(ABusy: Boolean; const AStatusText: string;
  AGuardPlayback: Boolean);
begin
  FBackgroundBusy := ABusy;
  FNewMenuItem.Enabled := not ABusy;
  FOpenMenuItem.Enabled := not ABusy;
  FSaveMenuItem.Enabled := not ABusy;
  FSaveAsMenuItem.Enabled := not ABusy;
  FExportMenuItem.Enabled := not ABusy;
  FArrangementView.Enabled := not ABusy;
  FFileBrowser.Enabled := not ABusy;
  FDevicePanel.Enabled := not ABusy;
  FEditMenu.Enabled := not ABusy;
  FTrackMenu.Enabled := not ABusy;

  { transport is only ever disabled going into a guarded busy state, but
    always re-enabled coming out of one, regardless of what AGuardPlayback
    the caller passes on the way out (every OnTerminate handler passes
    False there, since re-guarding on the way down is meaningless) - a
    mismatched True-in/False-out here previously left it stuck disabled
    forever after the first Open/import, since the release call's False
    made this block a no-op. }
  if ABusy then
  begin
    if AGuardPlayback then
      FTransportPanel.Enabled := False;
  end
  else
    FTransportPanel.Enabled := True;

  if ABusy then
    Caption := 'Eris - ' + AStatusText
  else
    UpdateWindowTitle;
end;

{ "Eris - ProjectName" once a project has a path, plain "Eris" before then.
  Called on every FCurrentProjectPath change and whenever a background job
  releases the title it borrowed for its status text. }
procedure TForm1.UpdateWindowTitle;
begin
  if FCurrentProjectPath = '' then
    Caption := 'Eris'
  else
  begin
    Caption := 'Eris - ' + ChangeFileExt(ExtractFileName(FCurrentProjectPath), '');
    { worth saying outright: it is the difference between a project that
      needs the kits folder to be there and one that doesn't }
    if Project.Standalone then
      Caption := Caption + ' [standalone]';
  end;
end;

{ Blocks until the audio thread has actually acted on a queued stop - see the
  callers for why nothing may free sample memory before that happens.

  On Windows the wait is bounded. A DirectSound device that has stopped
  draining (unplugged, taken by an exclusive-mode app, asleep) can hold the
  playback thread off its command queue indefinitely, and an unbounded spin
  here turns that into a hung window the user can only kill. Returning False
  makes the caller abandon the operation instead: the project is left exactly
  as it was, which is safe precisely because nothing has been freed yet. ALSA
  writes return when the device drains or errors, so on Linux this is the
  original unbounded loop, unchanged. }
function TForm1.WaitForEngineIdle: Boolean;
{$IFDEF WINDOWS}
var
  Deadline: QWord;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  Deadline := GetTickCount64 + 5000;
  while AudioEngineIsBusy do
  begin
    if GetTickCount64 > Deadline then
      Exit(False);
    Sleep(1);
  end;
  {$ELSE}
  while AudioEngineIsBusy do
    Sleep(1);
  {$ENDIF}
  Result := True;
end;

procedure TForm1.FileNewClick(Sender: TObject);
begin
  if FBackgroundBusy then
    Exit;
  { Stop is only a queued command for the audio thread to pick up - if we
    let NewProject free every sample's memory before that thread has
    actually drained it and stopped touching TrackClips/LiveNotes, it can
    read/crash on freed memory (and never touch playback again after that,
    which is exactly "can't play, no sound at all" - not just this project). }
  AudioEngineStop;
  if not WaitForEngineIdle then
  begin
    ShowMessage('The audio device stopped responding, so the project was ' +
      'left open. Check the device, or pick another one in Preferences.');
    Exit;
  end;
  AudioEngineInvalidateGrainCache;
  Project.NewProject;
  { the unpacked copy of a standalone project is kept alive only for as long
    as that project is open, and File > New is the one way to close one
    without opening another in its place (LoadProject releases it itself) }
  ReleaseBundleDir;
  { NewProject clears the effect CHAINS, but the engine's live effect state -
    reverb tails, delay lines, filter memory - belongs to the audio engine and
    survived the stop above, so the new project would otherwise start by
    flushing out the last one's tails. }
  AudioEngineResetEffectState;
  { force the effects rack to rebuild. UpdateDevicePanel only rebuilds when
    the selected track CHANGES, and File>New usually leaves the selection
    exactly where it was - so without this the rack goes on showing widgets
    for the effects the project no longer has. }
  FLastEffectsRackTrack := InvalidEffectsRackTrack;
  FCurrentProjectPath := '';
  UpdateWindowTitle;
  RefreshAllTracksUI;
end;

procedure TForm1.FileOpenClick(Sender: TObject);
var
  Dlg: TOpenDialog;
begin
  if FBackgroundBusy then
    Exit;
  Dlg := TOpenDialog.Create(Self);
  try
    Dlg.Title := 'Open Eris Project';
    { one entry covering both kinds, because opening them is the same
      operation - LoadProject tells them apart from the bundle's own contents,
      not from what was picked here }
    Dlg.Filter := 'Eris Project (*.er, *.ers)|*.er;*.ers|' +
      'Eris Project (*.er)|*.er|' +
      'Eris Standalone Project (*.ers)|*.ers';
    if not Dlg.Execute then
      Exit;

    { see FileNewClick - must be fully stopped (not just have the Stop
      command queued) before the background thread's LoadProject call
      frees the old project's sample memory out from under a still-running
      audio thread }
    AudioEngineStop;
    if not WaitForEngineIdle then
    begin
      ShowMessage('The audio device stopped responding, so nothing was ' +
        'opened. Check the device, or pick another one in Preferences.');
      Exit;
    end;
    AudioEngineInvalidateGrainCache;

    SetBackgroundBusy(True, 'Opening...', True);
    TProjectLoadThread.Create(Dlg.FileName, @ProjectLoadThreadTerminate);
  finally
    Dlg.Free;
  end;
end;

procedure TForm1.ProjectLoadThreadTerminate(Sender: TObject);
var
  Ok: Boolean;
  Path: string;
begin
  Ok := TProjectLoadThread(Sender).Success;
  Path := TProjectLoadThread(Sender).Path;
  SetBackgroundBusy(False, '', False);
  if not Ok then
  begin
    ShowMessage('Could not load project "' + Path + '".');
    Exit;
  end;

  FCurrentProjectPath := Path;
  UpdateWindowTitle;
  RefreshAllTracksUI;
  ShowMessage('Loaded "' + Path + '".');
end;

procedure TForm1.FileSaveClick(Sender: TObject);
begin
  if FBackgroundBusy then
    Exit;
  if FCurrentProjectPath = '' then
    FileSaveAsClick(Sender)
  else
    StartProjectSave(FCurrentProjectPath);
end;

procedure TForm1.FileSaveAsClick(Sender: TObject);
var
  Dlg: TSaveDialog;
  Path, Ext: string;
begin
  if FBackgroundBusy then
    Exit;
  Dlg := TSaveDialog.Create(Self);
  try
    Dlg.Title := 'Save Eris Project As';
    { the file type IS the choice - a standalone project is just this same
      bundle with every sample copied inside it, so picking the second entry
      is all there is to making one. Nothing else about saving changes, here
      or afterwards. }
    Dlg.Filter := 'Eris Project (*.er)|*.er|' +
      'Eris Standalone Project - samples included (*.ers)|*.ers';
    { a project that is already standalone offers to stay that way }
    if Project.Standalone then
      Dlg.FilterIndex := 2
    else
      Dlg.FilterIndex := 1;
    if Dlg.FilterIndex = 2 then
      Dlg.DefaultExt := StandaloneProjectExt
    else
      Dlg.DefaultExt := ProjectExt;
    if not Dlg.Execute then
      Exit;

    Path := Dlg.FileName;
    Ext := LowerCase(ExtractFileExt(Path));
    { an extension typed by hand wins - it says what the user wants as
      plainly as the filter does, and SaveProject reads the same extension
      to decide what to write, so honouring it here is what keeps the name
      and the contents from disagreeing }
    if (Ext <> ProjectExt) and (Ext <> StandaloneProjectExt) then
    begin
      if Dlg.FilterIndex = 2 then
        Path := Path + StandaloneProjectExt
      else
        Path := Path + ProjectExt;
    end;

    StartProjectSave(Path);
  finally
    Dlg.Free;
  end;
end;

procedure TForm1.StartProjectSave(const APath: string);
begin
  SetBackgroundBusy(True, 'Saving...', False);
  TProjectSaveThread.Create(APath, @ProjectSaveThreadTerminate);
end;

procedure TForm1.ProjectSaveThreadTerminate(Sender: TObject);
var
  Ok: Boolean;
  Path: string;
begin
  Ok := TProjectSaveThread(Sender).Success;
  Path := TProjectSaveThread(Sender).Path;
  SetBackgroundBusy(False, '', False);
  if not Ok then
  begin
    ShowMessage('Could not save project "' + Path + '".');
    Exit;
  end;

  FCurrentProjectPath := Path;
  UpdateWindowTitle;
  ShowMessage('Saved "' + Path + '".');
end;

procedure TForm1.FileExportClick(Sender: TObject);
var
  Dlg: TSaveDialog;
  Path: string;
begin
  if FBackgroundBusy then
    Exit;
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

    SetBackgroundBusy(True, 'Exporting...', False);
    TProjectRenderThread.Create(Path, @ProjectRenderThreadTerminate);
  finally
    Dlg.Free;
  end;
end;

procedure TForm1.ProjectRenderThreadTerminate(Sender: TObject);
var
  Ok: Boolean;
  Path: string;
begin
  Ok := TProjectRenderThread(Sender).Success;
  Path := TProjectRenderThread(Sender).Path;
  SetBackgroundBusy(False, '', False);
  if not Ok then
    ShowMessage('Nothing to export - the arrangement is empty.')
  else
    ShowMessage('Exported to "' + Path + '".');
end;

procedure TForm1.FileExitClick(Sender: TObject);
begin
  Close;
end;

procedure TForm1.EditPreferencesClick(Sender: TObject);
var
  Dlg: TPrefsForm;
  ModeBefore: Integer;
begin
  Dlg := TPrefsForm.Create(Self);
  try
    if Dlg.ShowModal = mrOK then
    begin
      { the dialog only writes Cfg.Theme (and saves it); applying it is this
        side's job. Compare the mode BEFORE and AFTER rather than against
        Cfg.Theme, because ThemeSetMode can refuse the value outright when
        ERIS_THEME is latched - and then there is genuinely nothing to redraw. }
      ModeBefore := ThemeGetMode;
      ThemeSetMode(Cfg.Theme);
      if ThemeGetMode <> ModeBefore then
        ApplyThemeChange;
    end;
  finally
    Dlg.Free;
  end;
end;

{ Everything a mode switch needs beyond the generic walk.

  ThemeRefreshAll re-colours the native widgets on every open form and
  invalidates the lot, which is all the custom-painted controls need - they
  read the palette while drawing, so a repaint IS the update. The three calls
  after it are the things the walk deliberately cannot do:

  - the file browser's divider carries ThemeTagSkip, so the walk steps over it
    and its owner has to re-assert it;
  - the metronome and warp toggles are TSpeedButtons, which the walk flattens
    to button face - correct for an unlit one, wrong for a lit one, and only
    their own updater knows which is which.

  ArrangementView's send buttons are the same case but need nothing here:
  LayoutSendButtons runs from its Paint and reasserts clSkyBlue on the lit
  ones, and the Invalidate above is what gets Paint to run. }
procedure TForm1.ApplyThemeChange;
begin
  ThemeRefreshAll;
  FFileBrowser.ThemeRefresh;
  UpdateMetronomeToggleLook;
  UpdateWarpModeButtons;
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

procedure TForm1.EditConsolidateClick(Sender: TObject);
begin
  if ActiveControl is TCustomEdit then
    Exit;
  FArrangementView.ConsolidateSelection;
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

procedure TForm1.TrackAddInputClick(Sender: TObject);
begin
  if Project.AddInputTrack then
    FArrangementView.Invalidate
  else
    ShowMessage(Format('Maximum of %d tracks reached.', [Project.MaxTracks]));
end;

procedure TForm1.TrackAddSamplerClick(Sender: TObject);
begin
  if Project.AddSamplerTrack then
    FArrangementView.Invalidate
  else
    ShowMessage(Format('Maximum of %d tracks reached.', [Project.MaxTracks]));
end;

procedure TForm1.TrackDeleteClick(Sender: TObject);
var
  Track, t: Integer;
begin
  { Delete the FOCUSED track - the one whose header was last clicked, which
    is what KeyboardTrack holds and what the whole device panel already
    treats as "the current track". This used to insist on SelectedTrack,
    which only clicking a CLIP ever sets, so any track with no clips on it -
    every freshly added sampler or instrument track - could never be deleted
    at all. Falls back to SelectedTrack so selecting a clip still implies its
    track, and rejects -2 (the Master row, which isn't deletable). }
  Track := FArrangementView.KeyboardTrack;
  if Track < 0 then
    Track := FArrangementView.SelectedTrack;
  if Track < 0 then
  begin
    ShowMessage('Select a track to delete.');
    Exit;
  end;

  { A delete RENUMBERS the project: every track above the deleted one shifts
    down an index, in the very arrays the realtime mixer reads live
    (TrackEnabled/TrackVolume/TrackEffects), while the engine holds its own
    copy of each track's clips indexed the same way. Restructuring that under
    a running mixer is the stop-then-wait protocol File>New/Open already use,
    so a delete goes through it too. Finalize first, or a take in progress
    would be written back to a track index that is about to mean something
    else. }
  if AudioEngineRecordState <> RecordStateIdle then
    FinalizeRecording;
  AudioEngineStop;
  if not WaitForEngineIdle then
  begin
    ShowMessage('The audio device stopped responding, so the track was not ' +
      'deleted. Check the device, or pick another one in Preferences.');
    Exit;
  end;
  FPlayPauseButton.Caption := 'Play';

  if Project.DeleteTrack(Track) then
  begin
    { The engine keeps a TPlaybackClip array per track index and NOTHING else
      re-indexes it, so every track from the deleted one up would go on
      playing the clips of whatever track used to sit at its index - the
      deleted track's own audio still sounding from its old slot, unmutable
      because the header controls at that index now edit a different track's
      numbers. That is the ghost track. Re-push all of them, then clear the
      slots past the new track count: FillBlock walks all MaxTracks slots and
      gates only on Project.TrackEnabled, so the top slot the delete vacated
      would otherwise keep its clips AND its enabled flag (see
      RefreshAllTracksUI, which clears them for the same reason after a load). }
    FArrangementView.RefreshAllTracks;
    for t := Project.TrackCount to Project.MaxTracks - 1 do
      AudioEngineSetTrackClips(t, nil, 0);
    { The chains moved with their tracks, so slot t now runs what was on t+1
      while the engine's filter/delay/reverb state for that slot still belongs
      to the old occupant. Only safe to clear while the mixer is definitely
      not running: EffectStateReset FREES the dynamic buffers inside a state
      (reverb tanks, chorus/flanger lines), and an input track left monitoring
      keeps FillBlock going straight through the stop above. Stale state is a
      filter/tail mismatch that decays out on its own; a free under a live
      mixer is a use-after-free - so with monitoring up we keep the mismatch. }
    if not AudioEngineProcessingActive then
      AudioEngineResetEffectState;

    FArrangementView.ClearSelection;
    { every later track just shifted down one index - see ClearKeyboardTrack }
    FArrangementView.ClearKeyboardTrack;
    { and the rack is still showing the chain of whatever track it had
      targeted, which is now a different track's chain (or none) }
    FLastEffectsRackTrack := InvalidEffectsRackTrack;
    UpdateDevicePanel;
    FArrangementView.Invalidate;
  end;
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

  FRecordTrackIndex := FArrangementView.KeyboardTrack;
  FRecordStartFrame := FArrangementView.CursorFrame;
  AudioEngineSeek(FRecordStartFrame);

  if Project.TrackIsInput[FRecordTrackIndex] then
  begin
    { line-in take: no keyboard instrument to check for, no count-in - the
      playhead just starts moving and recording immediately, same as the
      count-in's own final beat does for a normal track }
    AudioEngineStartRecording(FRecordTrackIndex);
    FRecordButton.Caption := 'Recording... (click to stop)';
    Exit;
  end;

  { A Sampler Track never uses TrackInstrument (it plays TrackSamplerSlots
    instead) - the recording path itself doesn't care which one a track
    uses, it just captures whatever the track's live note output is, so
    this guard only needs to reject the "nothing to play" case for a
    normal track. }
  if not Project.TrackIsSampler[FRecordTrackIndex] and
    (Project.TrackInstrument[FRecordTrackIndex] < 0) then
  begin
    ShowMessage('Load an instrument for this track first.');
    Exit;
  end;

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
  Clip.AUFFTSize := SampleTypes.AUFFTSizeDefault;

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
  Divisions: array[0..5] of Integer = (32, 16, 8, 4, 2, 1);
  Labels: array[0..5] of string = ('1/32', '1/16', '1/8', '1/4', '1/2', '1 bar');
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
  OldBPM: Single;
begin
  if not TryStrToInt(Trim(FTempoEdit.Text), Value) then
    Value := Round(Project.DefaultTempoBPM);
  if Value < 20 then
    Value := 20
  else if Value > 999 then
    Value := 999;
  FTempoEdit.Text := IntToStr(Value);

  OldBPM := Project.TempoBPM;
  if Value <> Round(OldBPM) then
  begin
    { Ableton-style: the arrangement stays locked to the same bars/beats,
      so it actually plays faster/slower - not just a relabeled ruler over
      an unchanged recording. See Project.RescaleForTempoChange. }
    Project.RescaleForTempoChange(OldBPM, Value);
    Project.TempoBPM := Value;
    FArrangementView.RescaleTimeReferences(OldBPM / Value);
    { every track's clips moved, but the scrollbar ranges only need working
      out once for the new arrangement length - see RefreshAllTracks }
    FArrangementView.RefreshAllTracks;
  end
  else
    Project.TempoBPM := Value;

  FArrangementView.Invalidate;
end;

procedure TForm1.ArrangementViewFileDrop(Sender: TObject; ATrackIndex: Integer;
  AFramePosition: Int64; const AFilePath: string);
begin
  if FBackgroundBusy then
    Exit;
  FPendingImportTrack := ATrackIndex;
  FPendingImportFrame := AFramePosition;
  SetBackgroundBusy(True, 'Importing...', True);
  TSampleImportThread.Create(AFilePath, ExtractFileName(AFilePath),
    @TimelineImportThreadTerminate);
end;

procedure TForm1.TimelineImportThreadTerminate(Sender: TObject);
var
  ImportThread: TSampleImportThread;
  Clip: TClip;
begin
  ImportThread := TSampleImportThread(Sender);
  SetBackgroundBusy(False, '', False);
  if not ImportThread.Success then
  begin
    ShowMessage('Could not load "' + ImportThread.Path + '" as a WAV file.');
    Exit;
  end;

  Clip.SampleID := ImportThread.SampleID;
  Clip.Offset := 0;
  Clip.Length := Project.SamplePool[ImportThread.SampleID].FrameCount;
  Clip.Position := FPendingImportFrame;
  Clip.TrackID := FPendingImportTrack;
  Clip.PitchSemitones := 0;
  Clip.Gain := 1.0;
  Clip.WarpMode := SampleTypes.WarpModeBeats;
  Clip.AUFFTSize := SampleTypes.AUFFTSizeDefault;

  Project.PushUndoSnapshot(FPendingImportTrack);
  Project.CommitClipToTrack(FPendingImportTrack, Clip);
  FArrangementView.RefreshTrack(FPendingImportTrack);
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
  { a Sampler Track is sample-only - its device panel slot is always the
    per-key waveform editor, never the clip/warp editor, even if a clip
    happens to be sitting on its timeline lane and gets selected. }
  if (FArrangementView.SelectedClipIndex >= 0) and
    not Project.TrackIsSampler[FArrangementView.SelectedTrack] then
  begin
    FWarpEditor.SetClip(FArrangementView.SelectedTrack,
      FArrangementView.SelectedClipIndex);
    FWarpWidget.Visible := True;
    RefreshWarpWidgetSize;
    case Project.Tracks[FArrangementView.SelectedTrack].Clips[FArrangementView.SelectedClipIndex].WarpMode of
      SampleTypes.WarpModeRePitch: FWarpRepitchButton.Down := True;
      SampleTypes.WarpModeTones: FWarpTonesButton.Down := True;
      SampleTypes.WarpModeAudio: FWarpAudioButton.Down := True;
      SampleTypes.WarpModeDrag: FWarpDragButton.Down := True;
    else
      { mode 0 and anything unrecognised, matching ClipSourceSample's own
        catch-all so the lit button always names what is actually playing }
      FWarpBeatsButton.Down := True;
    end;
    UpdateWarpModeButtons;
    UpdateClipControls;
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

procedure TForm1.WarpRepitchButtonClick(Sender: TObject);
begin
  SetSelectedClipWarpMode(SampleTypes.WarpModeRePitch);
end;

procedure TForm1.WarpBeatsButtonClick(Sender: TObject);
begin
  SetSelectedClipWarpMode(SampleTypes.WarpModeBeats);
end;

procedure TForm1.WarpTonesButtonClick(Sender: TObject);
begin
  SetSelectedClipWarpMode(SampleTypes.WarpModeTones);
end;

procedure TForm1.WarpAudioButtonClick(Sender: TObject);
begin
  SetSelectedClipWarpMode(SampleTypes.WarpModeAudio);
end;

procedure TForm1.WarpDragButtonClick(Sender: TObject);
begin
  SetSelectedClipWarpMode(SampleTypes.WarpModeDrag);
end;

{ Stub: "R" is meant to bounce the clip's warped zones into a plain new clip
  that keeps sounding the same but drops the markers/zones, matching what AU/
  LF/RP/BT clips can already do informally by ear-matching a re-recorded
  bounce. warp.md asks for it explicitly; deferred to a later session rather
  than rushed - see the button's own Hint for what to expect meanwhile. }
procedure TForm1.WarpRenderButtonClick(Sender: TObject);
begin
  ShowMessage('Render to new clip is not implemented yet.');
end;

procedure TForm1.SetSelectedClipWarpMode(AMode: Integer);
var
  Track, ClipIdx: Integer;
  PrevMode: Integer;
  FirstSource, LastSource, SourceSpan: Int64;
  NewMarkers: TWarpMarkerArray;
begin
  Track := FArrangementView.SelectedTrack;
  ClipIdx := FArrangementView.SelectedClipIndex;
  if (Track < 0) or (ClipIdx < 0) or
    (ClipIdx > High(Project.Tracks[Track].Clips)) then
  begin
    UpdateWarpModeButtons;
    Exit;
  end;

  PrevMode := Project.Tracks[Track].Clips[ClipIdx].WarpMode;

  { Tones and Audio are pitch-preserving exactly like Beats, so entering
    RePitch from any of the three has the same problem and needs the same
    reset below. }
  if (AMode = SampleTypes.WarpModeRePitch) and (PrevMode <> SampleTypes.WarpModeRePitch) then
  begin
    { Beats mode's Length is free to be any pitch-preserving stretch/squeeze
      of the source, possibly across several markers each with their own
      ratio. Carrying that straight into RePitch would turn it into an
      arbitrary, un-asked-for pitch shift (and a per-segment one, not a
      single rate). Reset to a plain 2-marker, rate-1 tracker resample of
      the same source material instead - true tracker style, one segment,
      no incidental pitch change from the mode switch itself. An actual
      resample pitch/length then comes from deliberately dragging the clip
      edge or the warp editor's end marker afterward (both already force
      RePitch and rescale Length/markers together, per the shift-drag fix
      above) - the "use warp markers to resample" option stays available,
      it just isn't triggered by the mode switch alone. }
    if Length(Project.Tracks[Track].Clips[ClipIdx].WarpMarkers) >= 2 then
    begin
      FirstSource := Project.Tracks[Track].Clips[ClipIdx].WarpMarkers[0].SourceFrame;
      LastSource := Project.Tracks[Track].Clips[ClipIdx].WarpMarkers[
        High(Project.Tracks[Track].Clips[ClipIdx].WarpMarkers)].SourceFrame;
    end
    else
    begin
      FirstSource := 0;
      LastSource := Project.Tracks[Track].Clips[ClipIdx].Length;
    end;
    SourceSpan := LastSource - FirstSource;

    SetLength(NewMarkers, 2);
    NewMarkers[0].SourceFrame := FirstSource;
    NewMarkers[0].TimelineFrame := 0;
    NewMarkers[1].SourceFrame := LastSource;
    NewMarkers[1].TimelineFrame := SourceSpan;

    Project.Tracks[Track].Clips[ClipIdx].WarpMarkers := NewMarkers;
    Project.Tracks[Track].Clips[ClipIdx].Length := SourceSpan;
  end;

  { Drag has no markers at all, and unlike every other mode an empty
    DragZones is NOT "silent by default" - AudioEngine.DragClipSample treats
    any frame not covered by a zone as plain raw/unedited audio, exactly as
    if unwarped (see warp.md "D (drag) mode": only the marked/dragged zones
    move, everything else stays put). So switching into D needs no seeding
    at all - a fresh clip just plays normally until the user double-clicks a
    start/end pair to carve out its first zone. }
  Project.Tracks[Track].Clips[ClipIdx].WarpMode := AMode;
  if (AMode = SampleTypes.WarpModeAudio) and
    (Project.Tracks[Track].Clips[ClipIdx].AUFFTSize = 0) then
    Project.Tracks[Track].Clips[ClipIdx].AUFFTSize := SampleTypes.AUFFTSizeDefault;

  { Project.Tracks holds the UI/offline copy of the clip. The realtime
    audio thread plays from its OWN fixed-size TPlaybackClip copy (see
    CLAUDE.md "Two independently-maintained copies of the warp/pitch
    algorithm") and only ever picks up a change when PushTrackToEngine
    sends a fresh snapshot up the ring buffer. The old single-toggle
    handler never called this, so WarpMode changed in the data model and
    on screen but never audibly - clicking it did nothing you could hear. }
  FArrangementView.PushTrackToEngine(Track);

  UpdateWarpModeButtons;
  FArrangementView.RefreshTrack(Track);
  FWarpEditor.Invalidate;
end;

procedure TForm1.MetronomeToggleClick(Sender: TObject);
begin
  { Down has already been toggled natively by the time this fires - the button
    is in its own GroupIndex with AllowAllUp, see its creation. Flipping it
    again here would just cancel that out. }
  AudioEngineSetMetronomeEnabled(FMetronomeToggle.Down);
  UpdateMetronomeToggleLook;
end;

procedure TForm1.UpdateMetronomeToggleLook;
begin
  if FMetronomeToggle.Down then
  begin
    { black because the lit colour is a fixed accent, not because the theme
      is light - clWindowText would go pale on clLime in Dark mode }
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
  FSwingLabel.Caption := 'Swing ' +
    IntToStr(SwingDetents[FSwingSlider.Position]) + '%';
end;

procedure TForm1.UpdateSwingControls;
var
  Track, i, Diff, BestIdx, BestDiff: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  FSwingLabel.Visible := Track >= 0;
  FSwingDivisionButton.Visible := Track >= 0;
  FSwingSlider.Visible := Track >= 0;
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
  FSwingLabel.Caption := 'Swing ' + IntToStr(SwingDetents[BestIdx]) + '%';
end;

procedure TForm1.UpdateWarpModeButtons;
begin
  { Two separate buttons instead of one relabeling toggle: whichever mode is
    ACTIVE gets a bright, distinct color and stays visibly pressed (native
    GroupIndex behavior); the inactive one goes back to plain button face.
    Two different fixed captions ("RP" always means RePitch, "BT" always
    means Beats) plus which one is lit together remove any doubt about
    which mode a clip is in - nothing here relies on a single button
    renaming itself. }
  { the lit captions stay clBlack in every theme: they sit on fixed accents,
    so they follow the accent rather than the palette }
  if FWarpRepitchButton.Down then
  begin
    FWarpRepitchButton.Color := clLime;
    FWarpRepitchButton.Font.Color := clBlack;
  end
  else
  begin
    FWarpRepitchButton.Color := clBtnFace;
    FWarpRepitchButton.Font.Color := clWindowText;
  end;
  FWarpRepitchButton.Hint := 'Warp mode: Re-Pitch (continuous vari-speed, changes pitch)';

  if FWarpBeatsButton.Down then
  begin
    FWarpBeatsButton.Color := clSkyBlue;
    FWarpBeatsButton.Font.Color := clBlack;
  end
  else
  begin
    FWarpBeatsButton.Color := clBtnFace;
    FWarpBeatsButton.Font.Color := clWindowText;
  end;
  FWarpBeatsButton.Hint := 'Warp mode: Beats (transient slices, preserves pitch)';

  if FWarpTonesButton.Down then
  begin
    FWarpTonesButton.Color := clMoneyGreen;
    FWarpTonesButton.Font.Color := clBlack;
  end
  else
  begin
    FWarpTonesButton.Color := clBtnFace;
    FWarpTonesButton.Font.Color := clWindowText;
  end;
  FWarpTonesButton.Hint :=
    'Warp mode: Tones/LF (pitch-synchronous - for 808s and sustained bass)';

  if FWarpAudioButton.Down then
  begin
    FWarpAudioButton.Color := clYellow;
    FWarpAudioButton.Font.Color := clBlack;
  end
  else
  begin
    FWarpAudioButton.Color := clBtnFace;
    FWarpAudioButton.Font.Color := clWindowText;
  end;
  FWarpAudioButton.Hint :=
    'Warp mode: Audio/AU (phase-locked phase vocoder - for pads, instruments, sampler output)';

  { FFT resolution slider only makes sense in AU mode - see the unit header
    on PhaseVocoder.pas }
  FClipFFTSizeSlider.Visible := FWarpAudioButton.Down;
  FClipFFTSizeValueLabel.Visible := FWarpAudioButton.Down;
  FClipFFTSizeLbl.Visible := FWarpAudioButton.Down;

  if FWarpDragButton.Down then
  begin
    FWarpDragButton.Color := clFuchsia;
    FWarpDragButton.Font.Color := clBlack;
  end
  else
  begin
    FWarpDragButton.Color := clBtnFace;
    FWarpDragButton.Font.Color := clWindowText;
  end;
  FWarpDragButton.Hint :=
    'Warp mode: Drag/D (slide zones with no resampling - drag start/end markers, ' +
    'double-click to grab a note)';
end;

procedure TForm1.ClipGainSliderChange(Sender: TObject);
var
  Track, ClipIdx: Integer;
  GainDb: Integer;
begin
  Track := FArrangementView.SelectedTrack;
  ClipIdx := FArrangementView.SelectedClipIndex;
  if (Track < 0) or (ClipIdx < 0) or (ClipIdx > High(Project.Tracks[Track].Clips)) then
    Exit;
  GainDb := FClipGainSlider.Position;
  Project.Tracks[Track].Clips[ClipIdx].Gain := Power(10, GainDb / 20);
  FClipGainValueLabel.Caption := Format('%d dB', [GainDb]);
  FArrangementView.RefreshTrack(Track);
end;

procedure TForm1.InstrumentGainSliderChange(Sender: TObject);
var
  Track, GainDb: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  if Track < 0 then
    Exit;
  GainDb := FInstrumentGainSlider.Position;
  Project.TrackInstrumentGainDb[Track] := GainDb;
  FInstrumentGainValueLabel.Caption := Format('%d dB', [GainDb]);
end;

procedure TForm1.ClipDetuneSliderChange(Sender: TObject);
var
  Track, ClipIdx: Integer;
  Semitones: Integer;
begin
  Track := FArrangementView.SelectedTrack;
  ClipIdx := FArrangementView.SelectedClipIndex;
  if (Track < 0) or (ClipIdx < 0) or (ClipIdx > High(Project.Tracks[Track].Clips)) then
    Exit;
  Semitones := FClipDetuneSlider.Position;
  Project.Tracks[Track].Clips[ClipIdx].PitchSemitones := Semitones;
  FClipDetuneValueLabel.Caption := Format('%d st', [Semitones]);
  FArrangementView.RefreshTrack(Track);
end;

procedure TForm1.ClipFFTSizeSliderChange(Sender: TObject);
var
  Track, ClipIdx, Size: Integer;
begin
  Track := FArrangementView.SelectedTrack;
  ClipIdx := FArrangementView.SelectedClipIndex;
  if (Track < 0) or (ClipIdx < 0) or (ClipIdx > High(Project.Tracks[Track].Clips)) then
    Exit;
  Size := 1 shl FClipFFTSizeSlider.Position;
  Project.Tracks[Track].Clips[ClipIdx].AUFFTSize := Size;
  FClipFFTSizeValueLabel.Caption := IntToStr(Size);
  { unlike gain/detune this changes the actual DSP, not just a multiplier
    applied at read time - the clip's cached phase-vocoder stretch has to be
    rebuilt, which PushTrackToEngine does (GetAUAudio's cache key includes
    AFFTSize, so this lands as a fresh cache entry rather than reusing the
    stale one) }
  FArrangementView.PushTrackToEngine(Track);
  FArrangementView.RefreshTrack(Track);
end;

procedure TForm1.UpdateClipControls;
var
  Track, ClipIdx, GainDb: Integer;
begin
  Track := FArrangementView.SelectedTrack;
  ClipIdx := FArrangementView.SelectedClipIndex;
  if (Track < 0) or (ClipIdx < 0) or (ClipIdx > High(Project.Tracks[Track].Clips)) then
    Exit;

  GainDb := Round(20 * Log10(Project.Tracks[Track].Clips[ClipIdx].Gain));
  if GainDb < ClipGainMinDb then GainDb := ClipGainMinDb;
  if GainDb > ClipGainMaxDb then GainDb := ClipGainMaxDb;
  FClipGainSlider.Position := GainDb;
  FClipGainValueLabel.Caption := Format('%d dB', [GainDb]);

  FClipDetuneSlider.Position := Round(Project.Tracks[Track].Clips[ClipIdx].PitchSemitones);
  FClipDetuneValueLabel.Caption := Format('%d st', [FClipDetuneSlider.Position]);

  if Project.Tracks[Track].Clips[ClipIdx].AUFFTSize < 512 then
    FClipFFTSizeSlider.Position := 12
  else
    FClipFFTSizeSlider.Position :=
      Round(Log2(Project.Tracks[Track].Clips[ClipIdx].AUFFTSize));
  FClipFFTSizeValueLabel.Caption := IntToStr(1 shl FClipFFTSizeSlider.Position);
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

procedure TForm1.WaveformGridButtonClick(Sender: TObject);
var
  GridLabel: string;
begin
  CycleWaveformGridDivision;
  GridLabel := WaveformGridDivisionLabel;
  FWarpGridButton.Caption := GridLabel;
  FInstrumentGridButton.Caption := GridLabel;
  FSamplerGridButton.Caption := GridLabel;
  FWarpEditor.Invalidate;
  FInstrumentEditor.Invalidate;
  FSamplerKeyEditor.Invalidate;
end;

procedure TForm1.InstrumentZoomInClick(Sender: TObject);
begin
  InstrumentEditor.InstrumentZoomIn;
  RefreshInstrumentWidgetSize;
  RefreshSamplerWidgetSize;
end;

procedure TForm1.InstrumentZoomOutClick(Sender: TObject);
begin
  InstrumentEditor.InstrumentZoomOut;
  RefreshInstrumentWidgetSize;
  RefreshSamplerWidgetSize;
end;

procedure TForm1.RefreshWarpWidgetSize;
const
  MinWaveformWidth = 60;
var
  MinTotalWidth: Integer;
begin
  if (FArrangementView.SelectedTrack >= 0) and (FArrangementView.SelectedClipIndex >= 0) and
    (FArrangementView.SelectedClipIndex <= High(Project.Tracks[FArrangementView.SelectedTrack].Clips)) then
  begin
    { FWarpEditor is inset by FWarpEditor.Left (the zoom/RP buttons and the
      gain/detune sliders), so the widget has to be that much wider than the
      waveform itself or the editor ends up Left pixels too narrow - which put
      the clip's own end marker off the right edge and made it ungrabbable.
      The MinTotalWidth floor just below already assumed this shape. }
    FWarpWidget.Width := FWarpEditor.Left + WarpWidthForFrames(
      Project.Tracks[FArrangementView.SelectedTrack].Clips[FArrangementView.SelectedClipIndex].Length)
      + Px(WarpRightPanelWidth);
    { the zoom/RP buttons and the gain/detune sliders both take a fixed
      amount of width off the top - never let the waveform itself collapse
      to nothing for a short/zoomed-out clip }
    MinTotalWidth := FWarpEditor.Left + Px(MinWaveformWidth) + Px(WarpRightPanelWidth);
    if FWarpWidget.Width < MinTotalWidth then
      FWarpWidget.Width := MinTotalWidth;
  end;
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

{ mirrors RefreshInstrumentWidgetSize above, just keyed off the selected
  Sampler Track key's own slot instead of the track's single TrackInstrument }
procedure TForm1.RefreshSamplerWidgetSize;
var
  Track, KeyIndex, SampleID: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  if (Track >= 0) and Project.TrackIsSampler[Track] then
  begin
    KeyIndex := FSamplerKeys.SelectedKey;
    if KeyIndex >= 0 then
    begin
      SampleID := Project.TrackSamplerSlots[Track][KeyIndex].SampleID;
      if SampleID >= 0 then
        FSamplerEditorWidget.Width := InstrumentWidthForFrames(
          Project.SamplePool[SampleID].FrameCount, Project.SamplePool[SampleID].SampleRate);
    end;
  end;
  FSamplerKeyEditor.Invalidate;
  UpdateDevicePanelScroll;
end;

procedure TForm1.RebuildEffectWidgets;
var
  i, Target, SendIndex, Count: Integer;
begin
  for i := 0 to High(FEffectWidgets) do
    FEffectWidgets[i].Free;
  FEffectWidgets := nil;

  { Target is a track index or one of Project's Bus* constants; the widgets
    take it verbatim and resolve their own chain from it }
  Target := FArrangementView.KeyboardTrack;
  FLastEffectsRackTrack := Target;
  SendIndex := Project.BusToSendIndex(Target);
  if SendIndex >= 0 then
    Count := Project.SendEffectCount[SendIndex]
  else if Target = Project.BusMaster then
    Count := Project.MasterEffectCount
  else if Target >= 0 then
    Count := Project.TrackEffectCount[Target]
  else
    Count := 0;

  SetLength(FEffectWidgets, Count);
  for i := 0 to High(FEffectWidgets) do
    FEffectWidgets[i] := TEffectWidget.CreateFor(Self, FDevicePanel, Target, i,
      @EffectRackChanged);

  UpdateDevicePanelScroll;
end;

procedure TForm1.EffectRackChanged(Sender: TObject);
begin
  { This fires from TEffectWidget.DeleteClick, which is still on the call
    stack of the very delete BUTTON's own OnClick - RebuildEffectWidgets
    Frees every TEffectWidget, including that button's parent widget, while
    the widgetset (GTK/Qt) is still unwinding the click dispatch for it.
    Freeing a control from inside its own event handler is a well-known
    use-after-free trap, and the resulting heap corruption is a very
    plausible source of the "effects randomly disappearing" reports -
    corruption is nondeterministic and not necessarily confined to the
    control that got freed. Deferring the actual rebuild until the click has
    fully unwound back to the message loop avoids it. }
  Application.QueueAsyncCall(@DeferredRebuildEffectWidgets, 0);
end;

procedure TForm1.DeferredRebuildEffectWidgets(Data: PtrInt);
begin
  RebuildEffectWidgets;
end;

procedure TForm1.AddEffectToCurrentTrack(AKind: Integer);
var
  Target, SendIndex: Integer;
  Added: Boolean;
begin
  Target := FArrangementView.KeyboardTrack;
  SendIndex := Project.BusToSendIndex(Target);
  if SendIndex >= 0 then
    Added := Project.AddSendEffect(SendIndex, AKind)
  else if Target = Project.BusMaster then
    Added := Project.AddMasterEffect(AKind)
  else if Target >= 0 then
    Added := Project.AddTrackEffect(Target, AKind)
  else
  begin
    ShowMessage('Select a track, the Master row, or a send row first.');
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

procedure TForm1.AddHighpassEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekHighpass);
end;

procedure TForm1.AddBandpassEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekBandpass);
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

procedure TForm1.AddFlangerEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekFlanger);
end;

procedure TForm1.AddPhaserEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekPhaser);
end;

procedure TForm1.AddSidechainEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekSidechain);
end;

procedure TForm1.AddDrowningEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekDrowning);
end;

procedure TForm1.AddTunerEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekTuner);
end;

procedure TForm1.AddOverdriveEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekOverdrive);
end;

procedure TForm1.AddQuadraverbReverbEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekQuadraverbReverb);
end;

procedure TForm1.AddQuadraverbDelayEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekQuadraverbDelay);
end;

procedure TForm1.AddExciter422AEffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekExciter422A);
end;

procedure TForm1.AddCompressor3630EffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekCompressor3630);
end;

procedure TForm1.AddFuzzFZ2EffectClick(Sender: TObject);
begin
  AddEffectToCurrentTrack(Effects.ekFuzzFZ2);
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
  FiltersItem, EQItem, ModulationItem, DistortionItem, ReverbItem, DelayItem,
  DynamicsItem, ExciterItem, PedalsItem, UtilityItem, MasteringItem,
  ExperimentalItem: TMenuItem;
begin
  FEffectsMenu := TPopupMenu.Create(Self);

  FiltersItem := AddCategory('Filters');
  AddEffectItem(FiltersItem, 'LP', @AddLowpassEffectClick);
  AddEffectItem(FiltersItem, 'HP', @AddHighpassEffectClick);
  AddEffectItem(FiltersItem, 'BP', @AddBandpassEffectClick);

  EQItem := AddCategory('EQ');
  AddEffectItem(EQItem, '4', @AddEQ4EffectClick);

  ModulationItem := AddCategory('Modulation');
  AddEffectItem(ModulationItem, 'Chorus', @AddChorusEffectClick);
  AddEffectItem(ModulationItem, 'Flanger', @AddFlangerEffectClick);
  AddEffectItem(ModulationItem, 'Phaser', @AddPhaserEffectClick);

  DistortionItem := AddCategory('Distortion');
  AddEffectItem(DistortionItem, 'Overdrive', @AddOverdriveEffectClick);

  ReverbItem := AddCategory('Reverb');
  AddEffectItem(ReverbItem, 'Basic Reverb', @AddReverbEffectClick);
  AddEffectItem(ReverbItem, 'QuadraVerb Reverb', @AddQuadraverbReverbEffectClick);

  DelayItem := AddCategory('Delay');
  AddEffectItem(DelayItem, 'QuadraVerb Delay', @AddQuadraverbDelayEffectClick);

  DynamicsItem := AddCategory('Dynamics');
  AddEffectItem(DynamicsItem, 'Compressor - 3630', @AddCompressor3630EffectClick);

  ExciterItem := AddCategory('Exciter');
  AddEffectItem(ExciterItem, 'Exciter - 422A', @AddExciter422AEffectClick);

  { emulations of actual stompboxes, kept apart from the generic Distortion/
    Modulation categories above - what you reach for here is a specific
    pedal, not a class of effect }
  PedalsItem := AddCategory('Pedals');
  AddEffectItem(PedalsItem, 'Fuzz - FZ-2', @AddFuzzFZ2EffectClick);

  UtilityItem := AddCategory('Utility');
  AddEffectItem(UtilityItem, 'Sidechain', @AddSidechainEffectClick);
  AddEffectItem(UtilityItem, 'Tuner', @AddTunerEffectClick);

  MasteringItem := AddCategory('Mastering');
  AddEffectItem(MasteringItem, 'Limiter', @AddLimiterEffectClick);

  { newest/least battle-tested effects live here, kept apart from the
    "normal" categories above rather than sorted into them by DSP type }
  ExperimentalItem := AddCategory('Experimental');
  AddEffectItem(ExperimentalItem, 'Drowning', @AddDrowningEffectClick);
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
  else if FSamplerEditorWidget.Visible then
    Result := Px(WarpSlotLeft) + FSamplerEditorWidget.Width + Px(8)
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
  FSamplerWidget.Left := Px(InstrumentSlotLeft) - Offset;
  FWarpWidget.Left := Px(WarpSlotLeft) - Offset;
  FInstrumentEditorWidget.Left := Px(WarpSlotLeft) - Offset;
  FSamplerEditorWidget.Left := Px(WarpSlotLeft) - Offset;

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
  if FSamplerWidget.Visible then
    ContentRight := Max(ContentRight, Px(InstrumentSlotLeft) + FSamplerWidget.Width);
  if FWarpWidget.Visible then
    ContentRight := Max(ContentRight, Px(WarpSlotLeft) + FWarpWidget.Width)
  else if FInstrumentEditorWidget.Visible then
    ContentRight := Max(ContentRight, Px(WarpSlotLeft) + FInstrumentEditorWidget.Width)
  else if FSamplerEditorWidget.Visible then
    ContentRight := Max(ContentRight, Px(WarpSlotLeft) + FSamplerEditorWidget.Width);
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
  { Sampler Tracks are sample-only - no single "load an instrument" slot, so
    file-browser drops onto the device panel background are only accepted
    for a normal (non-sampler) track. A sampler key gets its sample from a
    timeline clip dragged onto its own box instead - see ArrangementViewClipActivate. }
  Accept := (FArrangementView.KeyboardTrack >= 0) and
    not Project.TrackIsSampler[FArrangementView.KeyboardTrack] and
    (Source is TControl) and (TControl(Source).Parent is TFileBrowser);
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
begin
  if FBackgroundBusy then
    Exit;
  FPendingImportTrack := FArrangementView.KeyboardTrack;
  if FPendingImportTrack < 0 then
    Exit;
  { Sampler Tracks have no single instrument slot to load a file into - see
    DevicePanelDragOver's comment. }
  if Project.TrackIsSampler[FPendingImportTrack] then
    Exit;

  SetBackgroundBusy(True, 'Importing...', True);
  TSampleImportThread.Create(APath, ExtractFileName(APath),
    @InstrumentImportThreadTerminate);
end;

procedure TForm1.InstrumentImportThreadTerminate(Sender: TObject);
var
  ImportThread: TSampleImportThread;
begin
  ImportThread := TSampleImportThread(Sender);
  SetBackgroundBusy(False, '', False);
  if not ImportThread.Success then
  begin
    ShowMessage('Could not load "' + ImportThread.Path + '" as a WAV file.');
    Exit;
  end;

  { FPendingImportTrack, not FArrangementView.KeyboardTrack - the keyboard
    track could have changed while the import thread was running. A fresh
    import has no clip behind it, so the whole sample is the start/end
    window. }
  AssignSampleAsKeyboardInstrumentFor(FPendingImportTrack, ImportThread.SampleID,
    0, Project.SamplePool[ImportThread.SampleID].FrameCount);
end;

{ Shared by the import-thread completion above and by activating an
  already-resident sample (a timeline clip double-clicked or dragged onto
  the device panel - see ArrangementViewClipActivate) - the latter has
  nothing to decode/import, the sample's already in Project.SamplePool.
  AStartFrame seeds the start marker - normally the activating clip's own
  Offset. No end marker is placed here (see InstrumentEditor): playback
  always runs to the actual end of the sample until the user double-clicks
  the widget to drop one. }
procedure TForm1.AssignSampleAsKeyboardInstrumentFor(ATrack, ASampleID: Integer;
  AStartFrame, AEndFrame: Int64);
begin
  if (ATrack < 0) or (ASampleID < 0) or (ASampleID > High(Project.SamplePool)) then
    Exit;
  Project.TrackInstrument[ATrack] := ASampleID;
  if (AStartFrame < 0) or (AStartFrame >= Project.SamplePool[ASampleID].FrameCount) then
    AStartFrame := 0;
  Project.TrackInstrumentStart[ATrack] := AStartFrame;
  Project.TrackInstrumentEnd[ATrack] := Project.InstrumentEndUnset;
  UpdateDevicePanel;
end;

procedure TForm1.AssignSampleAsKeyboardInstrument(ASampleID: Integer; AStartFrame, AEndFrame: Int64);
begin
  AssignSampleAsKeyboardInstrumentFor(FArrangementView.KeyboardTrack, ASampleID,
    AStartFrame, AEndFrame);
end;

procedure TForm1.ArrangementViewClipActivate(Sender: TObject; ASampleID: Integer;
  AOffset, ALength: Int64);
var
  Track, KeyIdx: Integer;
  P: TPoint;
begin
  if FBackgroundBusy then
    Exit;

  Track := FArrangementView.KeyboardTrack;
  if (Track >= 0) and Project.TrackIsSampler[Track] then
  begin
    { dropped/double-clicked onto a Sampler Track: which of the 12 key boxes
      is the mouse over right now, in FSamplerKeys' own client coordinates -
      only meaningful for the drag-past-the-bottom-edge gesture (MouseUp),
      not for a plain double-click, which has no "over a box" position and
      is simply a no-op here. }
    P := FSamplerKeys.ScreenToClient(Mouse.CursorPos);
    if (P.Y < 0) or (P.Y >= FSamplerKeys.Height) then
      Exit;
    KeyIdx := FSamplerKeys.XToKeyIndex(P.X);
    if KeyIdx < 0 then
      Exit;
    Project.AssignSamplerSlot(Track, KeyIdx, ASampleID, AOffset, AOffset + ALength);
    FSamplerKeys.SelectKey(KeyIdx);
    UpdateDevicePanel;
    Exit;
  end;

  AssignSampleAsKeyboardInstrument(ASampleID, AOffset, AOffset + ALength);
end;

procedure TForm1.UpdateDevicePanel;
var
  Track, SampleID, SendIndex: Integer;
begin
  Track := FArrangementView.KeyboardTrack;
  UpdateSwingControls;

  { a send bus, like the Master row, has no instrument and no clip to warp -
    the whole bottom bar for it is just its effect chain, which is the point
    of clicking the S row in the first place }
  SendIndex := Project.BusToSendIndex(Track);
  if SendIndex >= 0 then
  begin
    FTrackWidgetLabel.Caption := Format('Send S%d', [SendIndex + 1]);
    FInstrumentWidget.Visible := False;
    FInstrumentEditorWidget.Visible := False;
    FSamplerWidget.Visible := False;
    FSamplerEditorWidget.Visible := False;
    FWarpWidget.Visible := False;
    FDropHintLabel.Caption := Format(
      'Send bus S%d - right-click here to add effects every track on this send shares',
      [SendIndex + 1]);
    FDropHintLabel.Visible := True;
    if FLastEffectsRackTrack <> Track then
      RebuildEffectWidgets;
    UpdateDevicePanelScroll;
    Exit;
  end;

  if Track = Project.BusMaster then
  begin
    FTrackWidgetLabel.Caption := 'Master';
    FInstrumentWidget.Visible := False;
    FInstrumentEditorWidget.Visible := False;
    FSamplerWidget.Visible := False;
    FSamplerEditorWidget.Visible := False;
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
    FSamplerWidget.Visible := False;
    FSamplerEditorWidget.Visible := False;
    FDropHintLabel.Caption := 'Select a track to load an instrument';
    FDropHintLabel.Visible := not FWarpWidget.Visible;
    if FLastEffectsRackTrack <> Track then
      RebuildEffectWidgets;
    UpdateDevicePanelScroll;
    Exit;
  end;

  FTrackWidgetLabel.Caption := 'Track ' + IntToStr(Track + 1);

  if Project.TrackIsSampler[Track] then
  begin
    FInstrumentWidget.Visible := False;
    FInstrumentEditorWidget.Visible := False;
    FDropHintLabel.Visible := False;

    FSamplerWidget.Visible := True;
    FSamplerOctaveLabel.Caption := Format('Octave: %d', [Project.TrackOctave[Track]]);
    FSamplerKeys.SetTrack(Track);

    FSamplerEditorWidget.Visible := not FWarpWidget.Visible;
    if FSamplerEditorWidget.Visible then
    begin
      FSamplerKeyEditor.SetKey(Track, FSamplerKeys.SelectedKey);
      RefreshSamplerWidgetSize;
    end;
  end
  else
  begin
    FSamplerWidget.Visible := False;
    FSamplerEditorWidget.Visible := False;

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
      FInstrumentGainSlider.Position := Round(Project.TrackInstrumentGainDb[Track]);
      FInstrumentGainValueLabel.Caption :=
        Format('%d dB', [FInstrumentGainSlider.Position]);

      FInstrumentEditorWidget.Visible := not FWarpWidget.Visible;
      if FInstrumentEditorWidget.Visible then
      begin
        FInstrumentEditor.SetTrack(Track);
        RefreshInstrumentWidgetSize;
      end;
    end;
  end;

  if FLastEffectsRackTrack <> Track then
    RebuildEffectWidgets;
  UpdateDevicePanelScroll;
  RefreshMidiSnapshot;
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
  if (EndFrame <= 0) or (EndFrame > Sample.FrameCount) then
    EndFrame := Sample.FrameCount;
  TrimmedCount := EndFrame - StartFrame;
  if TrimmedCount <= 0 then
    Exit;

  TotalOffset := ASemitoneOffset + Project.TrackOctave[Track] * 12;
  { instrument gain trim only - the track fader itself is applied by
    AudioEngine.FillBlock now rather than being baked into the note's gain
    here, so that notes and clips both pass through one fader in one place }
  AudioEngineTriggerNote(Track, @Sample.Data[StartFrame * Sample.Channels],
    TrimmedCount, Sample.Channels, TotalOffset,
    Power(10, Project.TrackInstrumentGainDb[Track] / 20));
end;

procedure TForm1.SamplerKeySelected(Sender: TObject; AKeyIndex: Integer);
begin
  UpdateDevicePanel;
end;

procedure TForm1.SamplerKeyEditorChanged(Sender: TObject);
begin
  FSamplerKeys.Invalidate;
end;

{ ABoxIndex is 0..11 (one of the 12 keys); AOctaveDelta is how many octaves
  above the key bank's own resting pitch the pressed physical key represents
  (0 for the lower QWERTY row, 1+ for the upper row - see FormKeyDown). Each
  key plays its own assigned sample at native rate at AOctaveDelta=0 and
  Project.TrackOctave[Track]=0; unlike instrument mode's single sample
  pitch-shifted per key, here only the *octave* (never a smaller semitone
  offset) is applied, real-time vari-speed via the same engine path. }
procedure TForm1.TriggerSamplerKeyNote(ABoxIndex, AOctaveDelta: Integer);
var
  Track, SampleID, TotalOffset: Integer;
  Sample: TSample;
  Slot: Project.TSamplerSlot;
  StartFrame, EndFrame, TrimmedCount: Int64;
begin
  Track := FArrangementView.KeyboardTrack;
  if (Track < 0) or not Project.TrackIsSampler[Track] then
    Exit;
  if (ABoxIndex < 0) or (ABoxIndex >= Project.SamplerKeysPerOctave) then
    Exit;

  Slot := Project.TrackSamplerSlots[Track][ABoxIndex];
  SampleID := Slot.SampleID;
  if SampleID < 0 then
    Exit; { empty key = silent }

  Sample := Project.SamplePool[SampleID];

  StartFrame := Slot.StartFrame;
  EndFrame := Slot.EndFrame;
  if StartFrame < 0 then
    StartFrame := 0;
  if EndFrame > Sample.FrameCount then
    EndFrame := Sample.FrameCount;
  TrimmedCount := EndFrame - StartFrame;
  if TrimmedCount <= 0 then
    Exit;

  TotalOffset := (Project.TrackOctave[Track] + AOctaveDelta) * 12;
  { instrument gain trim only - the track fader itself is applied by
    AudioEngine.FillBlock now rather than being baked into the note's gain
    here, so that notes and clips both pass through one fader in one place }
  AudioEngineTriggerNote(Track, @Sample.Data[StartFrame * Sample.Channels],
    TrimmedCount, Sample.Channels, TotalOffset,
    Power(10, Project.TrackInstrumentGainDb[Track] / 20));
end;

{ Republishes what the MIDI thread is allowed to play - see MidiSnapshot.
  Called from UpdateDevicePanel, which every instrument/octave/gain/track
  change already funnels through, and again from the playback poll timer as a
  backstop so a path that forgets to call UpdateDevicePanel can at worst leave
  the snapshot one tick stale. That staleness only ever affects which sample
  is armed, never note latency - notes themselves never touch this timer. }
procedure TForm1.RefreshMidiSnapshot;
var
  Track, k: Integer;

  procedure FillVoice(out AVoice: TMidiVoice; ASampleID: Integer;
    AStart, AEnd: Int64);
  var
    Sample: TSample;
    Count: Int64;
  begin
    AVoice.Data := nil;
    AVoice.FrameCount := 0;
    AVoice.Channels := 0;
    if (ASampleID < 0) or (ASampleID > High(Project.SamplePool)) then
      Exit;

    Sample := Project.SamplePool[ASampleID];
    if Sample.Data = nil then
      Exit;

    { same trim clamping TriggerKeyboardNote does before it hands a span to
      the engine }
    if AStart < 0 then
      AStart := 0;
    if (AEnd <= 0) or (AEnd > Sample.FrameCount) then
      AEnd := Sample.FrameCount;
    Count := AEnd - AStart;
    if Count <= 0 then
      Exit;

    AVoice.Data := @Sample.Data[AStart * Sample.Channels];
    AVoice.FrameCount := Count;
    AVoice.Channels := Sample.Channels;
  end;

begin
  { disarm for the duration of the rewrite so the MIDI thread never reads a
    half-updated record }
  MidiSnapshot.Valid := False;
  WriteBarrier;

  Track := FArrangementView.KeyboardTrack;
  MidiSnapshot.TrackIndex := Track;
  MidiSnapshot.Instrument.Data := nil;
  for k := 0 to Project.SamplerKeysPerOctave - 1 do
    MidiSnapshot.Slots[k].Data := nil;

  { a send bus or the master row has no instrument to play }
  if (Track < 0) or (Track >= Project.MaxTracks) then
  begin
    WriteBarrier;
    MidiSnapshot.Valid := True;
    Exit;
  end;

  MidiSnapshot.IsSampler := Project.TrackIsSampler[Track];
  MidiSnapshot.Octave := Project.TrackOctave[Track];
  MidiSnapshot.Gain := Power(10, Project.TrackInstrumentGainDb[Track] / 20);

  if MidiSnapshot.IsSampler then
    for k := 0 to Project.SamplerKeysPerOctave - 1 do
      FillVoice(MidiSnapshot.Slots[k],
        Project.TrackSamplerSlots[Track][k].SampleID,
        Project.TrackSamplerSlots[Track][k].StartFrame,
        Project.TrackSamplerSlots[Track][k].EndFrame)
  else
    FillVoice(MidiSnapshot.Instrument, Project.TrackInstrument[Track],
      Project.TrackInstrumentStart[Track], Project.TrackInstrumentEnd[Track]);

  { publish: contents visible before the flag that advertises them }
  WriteBarrier;
  MidiSnapshot.Valid := True;
end;

procedure TForm1.PlaybackPollTimerTimer(Sender: TObject);
var
  Track: Integer;
begin
  RefreshMidiSnapshot;

  { frees whatever old per-track clip arrays PushTrackToEngine's replacements
    have made obsolete since the last tick - see PendingFrees' declaration
    in AudioEngine.pas for why this can't happen on the audio thread itself }
  AudioEngineDrainPendingFrees;

  { master clip lamp - polled here rather than driven from the audio thread,
    which must not touch the LCL }
  FArrangementView.PollMasterMeter;

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
  Offset, Track: Integer;
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
    Track := FArrangementView.KeyboardTrack;
    if (Track >= 0) and Project.TrackIsSampler[Track] then
      { Offset spans two-plus octaves of KeyToSemitoneOffset's tracker-style
        layout (lower row 0..11, upper row 12..28+); a Sampler Track has
        only 12 boxes, so fold that back to a box index plus how many whole
        octaves above the bank's own pitch the key represents - see
        TriggerSamplerKeyNote's comment. }
      TriggerSamplerKeyNote(Offset mod Project.SamplerKeysPerOctave,
        Offset div Project.SamplerKeysPerOctave)
    else
      TriggerKeyboardNote(Offset);
    Key := 0;
  end;
end;

end.
