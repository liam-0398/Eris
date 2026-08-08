unit PrefsForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, AudioEngine;

type
  TPrefsForm = class(TForm)
  private
    FBackendCombo: TComboBox;
    FDeviceCombo: TComboBox;
    FSampleRateCombo: TComboBox;
    FBufferSizeCombo: TComboBox;
    FSP1200Combo: TComboBox;
    FOKButton: TButton;
    FCancelButton: TButton;
    procedure BuildLayout;
    procedure SP1200ComboChange(Sender: TObject);
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
  Height := 256;
  BuildLayout;
end;

procedure TPrefsForm.BuildLayout;

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

begin
  FBackendCombo := AddRow('Backend:', 16);
  FBackendCombo.Items.Add('ALSA');
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
  FBufferSizeCombo.ItemIndex := 2;

  FSP1200Combo := AddRow('SP-1200 emulation:', 160);
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
  FOKButton.Top := 200;
  FOKButton.Width := 75;
  FOKButton.Default := True;

  FCancelButton := TButton.Create(Self);
  FCancelButton.Parent := Self;
  FCancelButton.Caption := 'Cancel';
  FCancelButton.ModalResult := mrCancel;
  FCancelButton.Left := 245;
  FCancelButton.Top := 200;
  FCancelButton.Width := 75;
  FCancelButton.Cancel := True;
end;

procedure TPrefsForm.SP1200ComboChange(Sender: TObject);
begin
  AudioEngineSetSP1200Enabled(FSP1200Combo.ItemIndex = 1);
end;

end.
