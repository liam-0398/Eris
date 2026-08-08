unit PrefsForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls;

type
  TPrefsForm = class(TForm)
  private
    FBackendCombo: TComboBox;
    FDeviceCombo: TComboBox;
    FSampleRateCombo: TComboBox;
    FBufferSizeCombo: TComboBox;
    FOKButton: TButton;
    FCancelButton: TButton;
    procedure BuildLayout;
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
  Height := 220;
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

  FOKButton := TButton.Create(Self);
  FOKButton.Parent := Self;
  FOKButton.Caption := 'OK';
  FOKButton.ModalResult := mrOK;
  FOKButton.Left := 164;
  FOKButton.Top := 164;
  FOKButton.Width := 75;
  FOKButton.Default := True;

  FCancelButton := TButton.Create(Self);
  FCancelButton.Parent := Self;
  FCancelButton.Caption := 'Cancel';
  FCancelButton.ModalResult := mrCancel;
  FCancelButton.Left := 245;
  FCancelButton.Top := 164;
  FCancelButton.Width := 75;
  FCancelButton.Cancel := True;
end;

end.
