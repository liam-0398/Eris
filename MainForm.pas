unit MainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls,
  StdCtrls, LCLType, ArrangementView, PrefsForm, FileBrowser, SampleTypes,
  WavDecoder, AudioEngine, Project;

type
  TForm1 = class(TForm)
  private
    FMainMenu: TMainMenu;
    FTransportPanel: TPanel;
    FStopButton: TButton;
    FPlayPauseButton: TButton;
    FTempoLabel: TLabel;
    FTempoEdit: TEdit;
    FFileBrowser: TFileBrowser;
    FFileBrowserSplitter: TSplitter;
    FArrangementView: TArrangementView;
    FSplitter: TSplitter;
    FDevicePanel: TPanel;
    FTrackWidget: TPanel;
    FTrackWidgetLabel: TLabel;
    FInstrumentWidget: TPanel;
    FInstrumentNameLabel: TLabel;
    FInstrumentDeleteButton: TButton;
    FOctaveLabel: TLabel;
    FOctaveMinusButton: TButton;
    FOctavePlusButton: TButton;
    FDropHintLabel: TLabel;
    FPlaybackPollTimer: TTimer;

    procedure BuildMenu;
    procedure BuildLayout;

    procedure FileExitClick(Sender: TObject);
    procedure EditPreferencesClick(Sender: TObject);
    procedure EditUndoClick(Sender: TObject);
    procedure HelpAboutClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure PlayPauseClick(Sender: TObject);
    procedure TransportPanelResize(Sender: TObject);
    procedure TempoEditEditingDone(Sender: TObject);
    procedure ArrangementViewFileDrop(Sender: TObject; ATrackIndex: Integer;
      AFramePosition: Int64; const AFilePath: string);
    procedure ArrangementViewSeek(Sender: TObject; AFrameOffset: Int64);
    procedure ArrangementViewKeyboardTrackChanged(Sender: TObject);
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
  BuildMenu;
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
  FileMenu, EditMenu, ViewMenu, TrackMenu, HelpMenu, UndoItem: TMenuItem;
begin
  FMainMenu := TMainMenu.Create(Self);
  Menu := FMainMenu;

  FileMenu := AddMenu('&File');
  AddItem(FileMenu, '&New', nil);
  AddItem(FileMenu, '&Open...', nil);
  AddItem(FileMenu, '&Save', nil);
  AddItem(FileMenu, 'Save &As...', nil);
  AddSeparator(FileMenu);
  AddItem(FileMenu, '&Export...', nil);
  AddSeparator(FileMenu);
  AddItem(FileMenu, 'E&xit', @FileExitClick);

  EditMenu := AddMenu('&Edit');
  UndoItem := AddItem(EditMenu, '&Undo', @EditUndoClick);
  UndoItem.ShortCut := Menus.ShortCut(Ord('Z'), [ssCtrl]);
  AddSeparator(EditMenu);
  AddItem(EditMenu, '&Preferences...', @EditPreferencesClick);

  ViewMenu := AddMenu('&View');
  AddItem(ViewMenu, 'Zoom &In', nil);
  AddItem(ViewMenu, 'Zoom &Out', nil);

  TrackMenu := AddMenu('&Track');
  AddItem(TrackMenu, '&Add Track', nil);

  HelpMenu := AddMenu('&Help');
  AddItem(HelpMenu, '&About...', @HelpAboutClick);
end;

procedure TForm1.BuildLayout;
begin
  Width := 1280;
  Height := 800;

  FTransportPanel := TPanel.Create(Self);
  FTransportPanel.Parent := Self;
  FTransportPanel.Align := alTop;
  FTransportPanel.Height := 52;
  FTransportPanel.BevelOuter := bvNone;
  FTransportPanel.OnResize := @TransportPanelResize;

  FTempoLabel := TLabel.Create(Self);
  FTempoLabel.Parent := FTransportPanel;
  FTempoLabel.Caption := 'Tempo:';
  FTempoLabel.Left := 8;
  FTempoLabel.Top := 19;

  FTempoEdit := TEdit.Create(Self);
  FTempoEdit.Parent := FTransportPanel;
  FTempoEdit.Text := IntToStr(Round(Project.DefaultTempoBPM));
  FTempoEdit.Left := 56;
  FTempoEdit.Top := 14;
  FTempoEdit.Width := 64;
  FTempoEdit.OnEditingDone := @TempoEditEditingDone;

  FStopButton := TButton.Create(Self);
  FStopButton.Parent := FTransportPanel;
  FStopButton.Caption := 'Stop';
  FStopButton.Width := 80;
  FStopButton.Height := 32;
  FStopButton.OnClick := @StopClick;

  FPlayPauseButton := TButton.Create(Self);
  FPlayPauseButton.Parent := FTransportPanel;
  FPlayPauseButton.Caption := 'Play';
  FPlayPauseButton.Width := 80;
  FPlayPauseButton.Height := 32;
  FPlayPauseButton.OnClick := @PlayPauseClick;

  FDevicePanel := TPanel.Create(Self);
  FDevicePanel.Parent := Self;
  FDevicePanel.Align := alBottom;
  FDevicePanel.Height := 160;
  FDevicePanel.BevelOuter := bvNone;
  FDevicePanel.OnDragOver := @DevicePanelDragOver;
  FDevicePanel.OnDragDrop := @DevicePanelDragDrop;

  { "Track N" widget - always present, identifies whose device chain this is }
  FTrackWidget := TPanel.Create(Self);
  FTrackWidget.Parent := FDevicePanel;
  FTrackWidget.Left := 8;
  FTrackWidget.Top := 8;
  FTrackWidget.Width := 100;
  FTrackWidget.Height := 144;
  FTrackWidget.BevelOuter := bvRaised;

  FTrackWidgetLabel := TLabel.Create(Self);
  FTrackWidgetLabel.Parent := FTrackWidget;
  FTrackWidgetLabel.Align := alClient;
  FTrackWidgetLabel.Alignment := taCenter;
  FTrackWidgetLabel.Layout := tlCenter;
  FTrackWidgetLabel.Caption := 'No Track';

  { instrument widget - one "device" holding the sample dragged in for
    keyboard play on the currently selected track }
  FInstrumentWidget := TPanel.Create(Self);
  FInstrumentWidget.Parent := FDevicePanel;
  FInstrumentWidget.Left := 116;
  FInstrumentWidget.Top := 8;
  FInstrumentWidget.Width := 220;
  FInstrumentWidget.Height := 144;
  FInstrumentWidget.BevelOuter := bvRaised;
  FInstrumentWidget.Visible := False;

  FInstrumentDeleteButton := TButton.Create(Self);
  FInstrumentDeleteButton.Parent := FInstrumentWidget;
  FInstrumentDeleteButton.Caption := 'X';
  FInstrumentDeleteButton.Left := FInstrumentWidget.Width - 24;
  FInstrumentDeleteButton.Top := 4;
  FInstrumentDeleteButton.Width := 20;
  FInstrumentDeleteButton.Height := 20;
  FInstrumentDeleteButton.OnClick := @InstrumentDeleteClick;

  FInstrumentNameLabel := TLabel.Create(Self);
  FInstrumentNameLabel.Parent := FInstrumentWidget;
  FInstrumentNameLabel.Left := 8;
  FInstrumentNameLabel.Top := 8;
  FInstrumentNameLabel.Width := FInstrumentWidget.Width - 40;
  FInstrumentNameLabel.Height := 40;
  FInstrumentNameLabel.AutoSize := False;
  FInstrumentNameLabel.WordWrap := True;

  FOctaveLabel := TLabel.Create(Self);
  FOctaveLabel.Parent := FInstrumentWidget;
  FOctaveLabel.Left := 8;
  FOctaveLabel.Top := 64;
  FOctaveLabel.Caption := 'Octave: 0';

  FOctaveMinusButton := TButton.Create(Self);
  FOctaveMinusButton.Parent := FInstrumentWidget;
  FOctaveMinusButton.Caption := '-';
  FOctaveMinusButton.Left := 8;
  FOctaveMinusButton.Top := 88;
  FOctaveMinusButton.Width := 28;
  FOctaveMinusButton.Height := 24;
  FOctaveMinusButton.OnClick := @OctaveMinusClick;

  FOctavePlusButton := TButton.Create(Self);
  FOctavePlusButton.Parent := FInstrumentWidget;
  FOctavePlusButton.Caption := '+';
  FOctavePlusButton.Left := 44;
  FOctavePlusButton.Top := 88;
  FOctavePlusButton.Width := 28;
  FOctavePlusButton.Height := 24;
  FOctavePlusButton.OnClick := @OctavePlusClick;

  FDropHintLabel := TLabel.Create(Self);
  FDropHintLabel.Parent := FDevicePanel;
  FDropHintLabel.Left := 116;
  FDropHintLabel.Top := 8;
  FDropHintLabel.Caption := 'Select a track to load an instrument';

  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Align := alBottom;

  FFileBrowser := TFileBrowser.Create(Self);
  FFileBrowser.Parent := Self;
  FFileBrowser.Align := alLeft;
  FFileBrowser.Width := 220;
  FFileBrowser.OnFileActivate := @FileBrowserFileActivate;

  FFileBrowserSplitter := TSplitter.Create(Self);
  FFileBrowserSplitter.Parent := Self;
  FFileBrowserSplitter.Align := alLeft;

  FArrangementView := TArrangementView.Create(Self);
  FArrangementView.Parent := Self;
  FArrangementView.Align := alClient;
  FArrangementView.OnFileDrop := @ArrangementViewFileDrop;
  FArrangementView.OnSeek := @ArrangementViewSeek;
  FArrangementView.OnKeyboardTrackChanged := @ArrangementViewKeyboardTrackChanged;

  TransportPanelResize(FTransportPanel);

  FPlaybackPollTimer := TTimer.Create(Self);
  FPlaybackPollTimer.Interval := 150;
  FPlaybackPollTimer.OnTimer := @PlaybackPollTimerTimer;
  FPlaybackPollTimer.Enabled := True;
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

procedure TForm1.HelpAboutClick(Sender: TObject);
begin
  ShowMessage('Eris' + LineEnding + 'A linear-timeline, audio-only DAW.');
end;

procedure TForm1.StopClick(Sender: TObject);
begin
  AudioEngineStop;
  AudioEngineSeek(0);
  FArrangementView.SetCursorFrame(0);
  FPlayPauseButton.Caption := 'Play';
end;

procedure TForm1.PlayPauseClick(Sender: TObject);
begin
  if not AudioEngineHasClip then
    Exit;

  if AudioEngineIsPlaying then
  begin
    AudioEngineStop;
    FPlayPauseButton.Caption := 'Play';
  end
  else
  begin
    AudioEnginePlay;
    FPlayPauseButton.Caption := 'Pause';
  end;
end;

procedure TForm1.TransportPanelResize(Sender: TObject);
const
  Gap = 8;
var
  GroupWidth, GroupLeft, ButtonTop: Integer;
begin
  GroupWidth := FStopButton.Width + Gap + FPlayPauseButton.Width;
  GroupLeft := (FTransportPanel.ClientWidth - GroupWidth) div 2;
  ButtonTop := (FTransportPanel.ClientHeight - FPlayPauseButton.Height) div 2;

  FStopButton.Left := GroupLeft;
  FStopButton.Top := ButtonTop;
  FPlayPauseButton.Left := GroupLeft + FStopButton.Width + Gap;
  FPlayPauseButton.Top := ButtonTop;
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

  Clip.SampleID := Project.AddSampleToPool(Sample, ExtractFileName(AFilePath));
  Clip.Offset := 0;
  Clip.Length := Sample.FrameCount;
  Clip.Position := AFramePosition;
  Clip.TrackID := ATrackIndex;
  Clip.PitchSemitones := 0;
  Clip.Gain := 1.0;

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
    ExtractFileName(APath));
  UpdateDevicePanel;
end;

procedure TForm1.UpdateDevicePanel;
var
  Track, SampleID: Integer;
begin
  Track := FArrangementView.KeyboardTrack;

  if Track < 0 then
  begin
    FTrackWidgetLabel.Caption := 'No Track';
    FInstrumentWidget.Visible := False;
    FDropHintLabel.Caption := 'Select a track to load an instrument';
    FDropHintLabel.Visible := True;
    Exit;
  end;

  FTrackWidgetLabel.Caption := 'Track ' + IntToStr(Track + 1);

  SampleID := Project.TrackInstrument[Track];
  if SampleID < 0 then
  begin
    FInstrumentWidget.Visible := False;
    FDropHintLabel.Caption := 'Drag a WAV file here to sample it';
    FDropHintLabel.Visible := True;
  end
  else
  begin
    FDropHintLabel.Visible := False;
    FInstrumentWidget.Visible := True;
    FInstrumentNameLabel.Caption := Project.SampleNames[SampleID];
    FOctaveLabel.Caption := Format('Octave: %d', [Project.TrackOctave[Track]]);
  end;
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
begin
  Track := FArrangementView.KeyboardTrack;
  if Track < 0 then
    Exit;

  SampleID := Project.TrackInstrument[Track];
  if SampleID < 0 then
    Exit;

  Sample := Project.SamplePool[SampleID];
  TotalOffset := ASemitoneOffset + Project.TrackOctave[Track] * 12;
  AudioEngineTriggerNote(Track, Sample.Data, Sample.FrameCount, Sample.Channels,
    TotalOffset, 1.0);
end;

procedure TForm1.PlaybackPollTimerTimer(Sender: TObject);
begin
  if AudioEngineIsPlaying then
    FArrangementView.SetCursorFrame(AudioEngineGetPosition)
  else if FPlayPauseButton.Caption = 'Pause' then
    FPlayPauseButton.Caption := 'Play';
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
    Exit;

  if KeyToSemitoneOffset(Key, Offset) then
  begin
    TriggerKeyboardNote(Offset);
    Key := 0;
  end;
end;

end.
