unit PrefsForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, AudioEngine;

type
  TPrefsForm = class(TForm)
  private
    FBackendCombo: TComboBox;
    FDeviceCombo: TComboBox;
    FSampleRateCombo: TComboBox;
    FBufferSizeCombo: TComboBox;
    FInputBufferSizeCombo: TComboBox;
    FInputGainSlider: TTrackBar;
    FSP1200Combo: TComboBox;
    FOKButton: TButton;
    FCancelButton: TButton;
    procedure BuildLayout;
    procedure SP1200ComboChange(Sender: TObject);
    procedure InputGainSliderChange(Sender: TObject);
    procedure OKButtonClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

constructor TPrefsForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'Preferences';
  Position := poScreenCenter;
  BorderStyle := bsDialog;
  Width := 340;
  Height := 328;
  BuildLayout;
end;

procedure TPrefsForm.BuildLayout;
var
  CurrentBufferSizeIdx, CurrentInputBufferSizeIdx: Integer;

  function AddRow(const ALabel: string; ATop: Integer): TComboBox;
  var
    Lbl: TLabel;
  begin
    Lbl := TLabel.Create(Self);
    Lbl.Parent := Self;
    Lbl.Caption := ALabel;
    Lbl.Left := 12;
    Lbl.Top := ATop + 4;

    Result := TComboBox.Create(Self);
    Result.Parent := Self;
    Result.Style := csDropDownList;
    Result.Left := 120;
    Result.Top := ATop;
    Result.Width := 200;
  end;

  { same label column / same left+width as AddRow's combo above, just a
    horizontal slider instead of a dropdown - used for Input gain, the one
    continuous (not enumerated) setting on this form }
  function AddSliderRow(const ALabel: string; ATop: Integer): TTrackBar;
  var
    Lbl: TLabel;
  begin
    Lbl := TLabel.Create(Self);
    Lbl.Parent := Self;
    Lbl.Caption := ALabel;
    Lbl.Left := 12;
    Lbl.Top := ATop + 4;

    Result := TTrackBar.Create(Self);
    Result.Parent := Self;
    Result.Left := 120;
    Result.Top := ATop;
    Result.Width := 200;
    Result.Height := 26;
  end;

begin
  FBackendCombo := AddRow('Backend:', 16);
  {$IFDEF WINDOWS}
  FBackendCombo.Items.Add('DirectSound');
  {$ELSE}
  FBackendCombo.Items.Add('ALSA');
  {$ENDIF}
  FBackendCombo.Items.Add('PortAudio (planned)');
  FBackendCombo.Items.Add('JACK (planned)');
  FBackendCombo.ItemIndex := 0;

  FDeviceCombo := AddRow('Device:', 52);
  FDeviceCombo.Items.Add('Default');
  FDeviceCombo.ItemIndex := 0;

  FSampleRateCombo := AddRow('Sample rate:', 88);
  FSampleRateCombo.Items.Add('44100');
  FSampleRateCombo.Items.Add('48000');
  FSampleRateCombo.Items.Add('96000');
  FSampleRateCombo.ItemIndex := 0;

  FBufferSizeCombo := AddRow('Buffer size:', 124);
  FBufferSizeCombo.Items.Add('128');
  FBufferSizeCombo.Items.Add('256');
  FBufferSizeCombo.Items.Add('512');
  FBufferSizeCombo.Items.Add('1024');
  FBufferSizeCombo.Items.Add('2048');
  FBufferSizeCombo.Items.Add('4096');
  CurrentBufferSizeIdx := FBufferSizeCombo.Items.IndexOf(
    IntToStr(AudioEngineGetBufferSize));
  if CurrentBufferSizeIdx >= 0 then
    FBufferSizeCombo.ItemIndex := CurrentBufferSizeIdx
  else
    FBufferSizeCombo.ItemIndex := 2;

  FInputBufferSizeCombo := AddRow('Input buffer:', 160);
  FInputBufferSizeCombo.Items.Add('128');
  FInputBufferSizeCombo.Items.Add('256');
  FInputBufferSizeCombo.Items.Add('512');
  FInputBufferSizeCombo.Items.Add('1024');
  FInputBufferSizeCombo.Items.Add('2048');
  FInputBufferSizeCombo.Items.Add('4096');
  CurrentInputBufferSizeIdx := FInputBufferSizeCombo.Items.IndexOf(
    IntToStr(AudioEngineGetInputBufferSize));
  if CurrentInputBufferSizeIdx >= 0 then
    FInputBufferSizeCombo.ItemIndex := CurrentInputBufferSizeIdx
  else
    FInputBufferSizeCombo.ItemIndex := 3; { 1024 - a sensible default for line-in capture }

  { -24..+24 dB, matching this app's other gain sliders (see MainForm's clip
    gain slider) - applied on change, unlike the buffer-size combos, since
    it's just a plain unsynchronized Single (see AudioEngineSetInputGainDb),
    not something that stops/reopens the audio backend }
  FInputGainSlider := AddSliderRow('Input gain:', 196);
  FInputGainSlider.Min := -24;
  FInputGainSlider.Max := 24;
  FInputGainSlider.Frequency := 6;
  FInputGainSlider.TickStyle := tsAuto;
  FInputGainSlider.Position := Round(AudioEngineGetInputGainDb);
  FInputGainSlider.ShowHint := True;
  FInputGainSlider.Hint := IntToStr(FInputGainSlider.Position) + ' dB';
  FInputGainSlider.OnChange := @InputGainSliderChange;

  FSP1200Combo := AddRow('SP-1200 emulation:', 232);
  FSP1200Combo.Items.Add('Off');
  FSP1200Combo.Items.Add('On');
  if AudioEngineGetSP1200Enabled then
    FSP1200Combo.ItemIndex := 1
  else
    FSP1200Combo.ItemIndex := 0;
  FSP1200Combo.OnChange := @SP1200ComboChange;

  FOKButton := TButton.Create(Self);
  FOKButton.Parent := Self;
  FOKButton.Caption := 'OK';
  FOKButton.ModalResult := mrOK;
  FOKButton.Left := 164;
  FOKButton.Top := 272;
  FOKButton.Width := 75;
  FOKButton.Default := True;
  FOKButton.OnClick := @OKButtonClick;

  FCancelButton := TButton.Create(Self);
  FCancelButton.Parent := Self;
  FCancelButton.Caption := 'Cancel';
  FCancelButton.ModalResult := mrCancel;
  FCancelButton.Left := 245;
  FCancelButton.Top := 272;
  FCancelButton.Width := 75;
  FCancelButton.Cancel := True;
end;

procedure TPrefsForm.SP1200ComboChange(Sender: TObject);
begin
  AudioEngineSetSP1200Enabled(FSP1200Combo.ItemIndex = 1);
end;

procedure TPrefsForm.InputGainSliderChange(Sender: TObject);
begin
  FInputGainSlider.Hint := IntToStr(FInputGainSlider.Position) + ' dB';
  AudioEngineSetInputGainDb(FInputGainSlider.Position);
end;

procedure TPrefsForm.OKButtonClick(Sender: TObject);
var
  NewBufferSize, NewInputBufferSize: Integer;
begin
  { applied on OK rather than on the combo's own OnChange, unlike SP-1200
    above - this one stops/reopens the audio backend (see
    AudioEngineSetBufferSize), which would otherwise restart on every
    keystroke/scroll through the dropdown }
  if TryStrToInt(FBufferSizeCombo.Text, NewBufferSize) then
    AudioEngineSetBufferSize(NewBufferSize);
  if TryStrToInt(FInputBufferSizeCombo.Text, NewInputBufferSize) then
    AudioEngineSetInputBufferSize(NewInputBufferSize);
end;

end.
