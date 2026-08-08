unit MainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls,
  StdCtrls, ArrangementView, PrefsForm, FileBrowser, SampleTypes, WavDecoder,
  AudioEngine, Project;

type
  TForm1 = class(TForm)
  private
    FMainMenu: TMainMenu;
    FTransportPanel: TPanel;
    FPlayPauseButton: TButton;
    FTempoLabel: TLabel;
    FTempoEdit: TEdit;
    FFileBrowser: TFileBrowser;
    FFileBrowserSplitter: TSplitter;
    FArrangementView: TArrangementView;
    FSplitter: TSplitter;
    FDevicePanel: TPanel;
    FDevicePanelLabel: TLabel;
    FPlaybackPollTimer: TTimer;

    procedure BuildMenu;
    procedure BuildLayout;

    procedure FileExitClick(Sender: TObject);
    procedure EditPreferencesClick(Sender: TObject);
    procedure EditUndoClick(Sender: TObject);
    procedure HelpAboutClick(Sender: TObject);
    procedure PlayPauseClick(Sender: TObject);
    procedure TransportPanelResize(Sender: TObject);
    procedure TempoEditEditingDone(Sender: TObject);
    procedure ArrangementViewFileDrop(Sender: TObject; ATrackIndex: Integer;
      AFramePosition: Int64; const AFilePath: string);
    procedure ArrangementViewSeek(Sender: TObject; AFrameOffset: Int64);
    procedure PlaybackPollTimerTimer(Sender: TObject);
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
  Width := 900;
  Height := 600;

  FTransportPanel := TPanel.Create(Self);
  FTransportPanel.Parent := Self;
  FTransportPanel.Align := alTop;
  FTransportPanel.Height := 40;
  FTransportPanel.BevelOuter := bvNone;
  FTransportPanel.OnResize := @TransportPanelResize;

  FTempoLabel := TLabel.Create(Self);
  FTempoLabel.Parent := FTransportPanel;
  FTempoLabel.Caption := 'Tempo:';
  FTempoLabel.Left := 8;
  FTempoLabel.Top := 12;

  FTempoEdit := TEdit.Create(Self);
  FTempoEdit.Parent := FTransportPanel;
  FTempoEdit.Text := IntToStr(Round(Project.DefaultTempoBPM));
  FTempoEdit.Left := 56;
  FTempoEdit.Top := 8;
  FTempoEdit.Width := 50;
  FTempoEdit.OnEditingDone := @TempoEditEditingDone;

  FPlayPauseButton := TButton.Create(Self);
  FPlayPauseButton.Parent := FTransportPanel;
  FPlayPauseButton.Caption := 'Play';
  FPlayPauseButton.Width := 80;
  FPlayPauseButton.Height := 28;
  FPlayPauseButton.OnClick := @PlayPauseClick;

  FDevicePanel := TPanel.Create(Self);
  FDevicePanel.Parent := Self;
  FDevicePanel.Align := alBottom;
  FDevicePanel.Height := 160;
  FDevicePanel.BevelOuter := bvNone;

  FDevicePanelLabel := TLabel.Create(Self);
  FDevicePanelLabel.Parent := FDevicePanel;
  FDevicePanelLabel.Caption := 'Device / instrument panel (selected track)';
  FDevicePanelLabel.Left := 8;
  FDevicePanelLabel.Top := 8;

  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Align := alBottom;

  FFileBrowser := TFileBrowser.Create(Self);
  FFileBrowser.Parent := Self;
  FFileBrowser.Align := alLeft;
  FFileBrowser.Width := 220;

  FFileBrowserSplitter := TSplitter.Create(Self);
  FFileBrowserSplitter.Parent := Self;
  FFileBrowserSplitter.Align := alLeft;

  FArrangementView := TArrangementView.Create(Self);
  FArrangementView.Parent := Self;
  FArrangementView.Align := alClient;
  FArrangementView.OnFileDrop := @ArrangementViewFileDrop;
  FArrangementView.OnSeek := @ArrangementViewSeek;

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
begin
  FPlayPauseButton.Left := (FTransportPanel.ClientWidth - FPlayPauseButton.Width) div 2;
  FPlayPauseButton.Top := (FTransportPanel.ClientHeight - FPlayPauseButton.Height) div 2;
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

procedure TForm1.PlaybackPollTimerTimer(Sender: TObject);
begin
  if AudioEngineIsPlaying then
    FArrangementView.SetCursorFrame(AudioEngineGetPosition)
  else if FPlayPauseButton.Caption = 'Pause' then
    FPlayPauseButton.Caption := 'Play';
end;

end.
