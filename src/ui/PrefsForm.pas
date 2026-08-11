unit PrefsForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, AudioEngine, Config,
  Theme
  {$IFNDEF WINDOWS}, PipeWireBackend{$ENDIF};

{$IFDEF WINDOWS}
{ no PipeWire on the Windows build - the device rows there stay placeholders,
  so the form only needs the type to compile against }
type
  TPWDevice = record
    Name: string;
    Description: string;
  end;
  TPWDeviceArray = array of TPWDevice;
{$ENDIF}

type
  TPrefsForm = class(TForm)
  private
    FBackendCombo: TComboBox;
    FOutputCombo: TComboBox;
    FInputCombo: TComboBox;
    FSampleRateCombo: TComboBox;
    FBufferSizeCombo: TComboBox;
    FInputBufferSizeCombo: TComboBox;
    FInputGainSlider: TTrackBar;
    FSP1200Combo: TComboBox;
    FOKButton: TButton;
    FCancelButton: TButton;
    { kept only so the greying below can grey a row's caption along with its
      control - a disabled combo beside a black label reads as a bug }
    FOutputLabel: TLabel;
    FInputLabel: TLabel;
    FSampleRateLabel: TLabel;
    FBufferSizeLabel: TLabel;
    FInputBufferSizeLabel: TLabel;
    { parallel to the Output/Input combo items from index 1 up (index 0 is
      "Default (system)"), because the combo shows each device's description
      while the engine needs its node name }
    FOutputDevices: TPWDeviceArray;
    FInputDevices: TPWDeviceArray;
    procedure BuildLayout;
    procedure UpdateRowsForBackend;
    procedure RefreshDeviceLists;
    procedure BackendComboChange(Sender: TObject);
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
  Height := 364;
  BuildLayout;
end;

procedure TPrefsForm.BuildLayout;
var
  CurrentBufferSizeIdx, CurrentInputBufferSizeIdx, CurrentSampleRateIdx: Integer;
  { the two row captions nothing ever greys - AddRow hands every label back,
    and these are the ones with no field to keep them in }
  BackendLabel, SP1200Label: TLabel;

  function AddRow(const ALabel: string; ATop: Integer;
    out ALabelCtl: TLabel): TComboBox;
  begin
    ALabelCtl := TLabel.Create(Self);
    ALabelCtl.Parent := Self;
    ALabelCtl.Caption := ALabel;
    ALabelCtl.Left := 12;
    ALabelCtl.Top := ATop + 4;

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
  { the item order here IS AudioEngine's AudioBackend* constant order - index
    0 is always the platform's native backend }
  FBackendCombo := AddRow('Backend:', 16, BackendLabel);
  {$IFDEF WINDOWS}
  FBackendCombo.Items.Add('DirectSound');
  {$ELSE}
  FBackendCombo.Items.Add('ALSA');
  FBackendCombo.Items.Add('JACK');
  FBackendCombo.Items.Add('PipeWire');
  {$ENDIF}
  if AudioEngineGetBackend < FBackendCombo.Items.Count then
    FBackendCombo.ItemIndex := AudioEngineGetBackend
  else
    FBackendCombo.ItemIndex := 0;
  FBackendCombo.OnChange := @BackendComboChange;

  { Live under PipeWire, which can point each direction at a specific node -
    RefreshDeviceLists fills them. Still placeholders under ALSA, where
    picking a particular hw:X,Y card (a Scarlett 2i2, say) isn't wired up
    yet, and greyed for good under JACK, where routing belongs to the
    patchbay rather than to this dialog. }
  FOutputCombo := AddRow('Output:', 52, FOutputLabel);
  FInputCombo := AddRow('Input:', 88, FInputLabel);

  FSampleRateCombo := AddRow('Sample rate:', 124, FSampleRateLabel);
  FSampleRateCombo.Items.Add('44100');
  FSampleRateCombo.Items.Add('48000');
  FSampleRateCombo.Items.Add('96000');
  { The one row on this form that reflects eris.conf rather than the engine,
    because the engine has no rate to report - it is fixed at compile time by
    ProjectSampleRate. The value round-trips through the config file so the
    choice is already being carried by the time a backend can act on it. }
  CurrentSampleRateIdx := FSampleRateCombo.Items.IndexOf(IntToStr(Cfg.SampleRate));
  if CurrentSampleRateIdx >= 0 then
    FSampleRateCombo.ItemIndex := CurrentSampleRateIdx
  else
    FSampleRateCombo.ItemIndex := 0;

  FBufferSizeCombo := AddRow('Buffer size:', 160, FBufferSizeLabel);
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

  FSP1200Combo := AddRow('SP-1200:', 196, SP1200Label);
  FSP1200Combo.Items.Add('Off');
  FSP1200Combo.Items.Add('On');
  if AudioEngineGetSP1200Enabled then
    FSP1200Combo.ItemIndex := 1
  else
    FSP1200Combo.ItemIndex := 0;
  FSP1200Combo.OnChange := @SP1200ComboChange;

  FInputBufferSizeCombo := AddRow('Input buffer:', 232, FInputBufferSizeLabel);
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
  FInputGainSlider := AddSliderRow('Input gain:', 268);
  FInputGainSlider.Min := -24;
  FInputGainSlider.Max := 24;
  FInputGainSlider.Frequency := 6;
  FInputGainSlider.TickStyle := tsAuto;
  FInputGainSlider.Position := Round(AudioEngineGetInputGainDb);
  FInputGainSlider.ShowHint := True;
  FInputGainSlider.Hint := IntToStr(FInputGainSlider.Position) + ' dB';
  FInputGainSlider.OnChange := @InputGainSliderChange;

  FOKButton := TButton.Create(Self);
  FOKButton.Parent := Self;
  FOKButton.Caption := 'OK';
  FOKButton.ModalResult := mrOK;
  FOKButton.Left := 164;
  FOKButton.Top := 308;
  FOKButton.Width := 75;
  FOKButton.Default := True;
  FOKButton.OnClick := @OKButtonClick;

  FCancelButton := TButton.Create(Self);
  FCancelButton.Parent := Self;
  FCancelButton.Caption := 'Cancel';
  FCancelButton.ModalResult := mrCancel;
  FCancelButton.Left := 245;
  FCancelButton.Top := 308;
  FCancelButton.Width := 75;
  FCancelButton.Cancel := True;

  RefreshDeviceLists;
  UpdateRowsForBackend;

  {$IFDEF WINDOWS}
  { see the matching note in MainForm - dark forms flash white on resize
    through Win32's default background erase }
  DoubleBuffered := True;
  {$ENDIF}
  { last, once every row exists; a no-op in System mode }
  ThemeApply(Self);
end;

{ Re-enumerates the PipeWire sinks and sources and reselects whatever the
  engine is currently pointed at. Called from BuildLayout - and Preferences
  builds a fresh form every time it's opened (see MainForm) - so plugging an
  interface in and reopening this dialog is all it takes to see it. Also
  called when the backend dropdown is switched to PipeWire.

  Entry 0 is always "Default (system)", which maps to the empty target name
  and means "follow whatever the desktop's default device is", including
  when that changes later. Anything else pins Eris to that node. }
procedure TPrefsForm.RefreshDeviceLists;

  procedure Fill(ACombo: TComboBox; const ADevices: TPWDeviceArray;
    const ACurrent: string);
  var
    i, Sel: Integer;
  begin
    ACombo.Items.BeginUpdate;
    try
      ACombo.Items.Clear;
      ACombo.Items.AddObject('Default (system)', nil);
      Sel := 0;
      for i := 0 to High(ADevices) do
      begin
        { the node name is what the engine needs, the description is what a
          human recognises - show the second, carry the first }
        ACombo.Items.Add(ADevices[i].Description);
        if ADevices[i].Name = ACurrent then
          Sel := i + 1;
      end;
      ACombo.ItemIndex := Sel;
    finally
      ACombo.Items.EndUpdate;
    end;
  end;

begin
  {$IFDEF WINDOWS}
  FOutputCombo.Items.Clear;
  FOutputCombo.Items.Add('Default (system)');
  FOutputCombo.ItemIndex := 0;
  FInputCombo.Items.Clear;
  FInputCombo.Items.Add('Default (system)');
  FInputCombo.ItemIndex := 0;
  {$ELSE}
  FOutputDevices := PipeWireListDevices(True);
  FInputDevices := PipeWireListDevices(False);
  Fill(FOutputCombo, FOutputDevices, AudioEngineGetPipeWireOutputDevice);
  Fill(FInputCombo, FInputDevices, AudioEngineGetPipeWireInputDevice);
  {$ENDIF}
end;

{ Greys every row JACK takes ownership of. Under JACK the sample rate and
  the period size are the SERVER's, fixed before it starts and changed in
  qjackctl (or the PipeWire config) - a client cannot negotiate either - and
  device routing is the patchbay's. Leaving those editable here would show
  values that silently don't apply. SP-1200 and Input gain stay live: both
  are Eris-side processing that no backend has any say over.

  Note the buffer-size row is about latency, which under JACK is set by the
  server's frames/period. Eris still has an internal block size behind the
  scenes, it just isn't what determines output latency any more. }
procedure TPrefsForm.UpdateRowsForBackend;
var
  Native, PipeWire: Boolean;
begin
  Native := FBackendCombo.ItemIndex <> AudioBackendJACK;
  { device selection is implemented for PipeWire only - under ALSA these are
    placeholders and under JACK they're the patchbay's job, so in both cases
    an editable dropdown would be claiming something untrue }
  PipeWire := FBackendCombo.ItemIndex = AudioBackendPipeWire;

  FOutputCombo.Enabled := PipeWire;
  FOutputLabel.Enabled := PipeWire;
  FInputCombo.Enabled := PipeWire;
  FInputLabel.Enabled := PipeWire;
  FSampleRateCombo.Enabled := Native;
  FSampleRateLabel.Enabled := Native;
  FBufferSizeCombo.Enabled := Native;
  FBufferSizeLabel.Enabled := Native;
  FInputBufferSizeCombo.Enabled := Native;
  FInputBufferSizeLabel.Enabled := Native;
end;

procedure TPrefsForm.BackendComboChange(Sender: TObject);
begin
  { greys immediately so the dialog reflects the choice, but the switch
    itself waits for OK - it stops and reopens the audio device (see
    AudioEngineSetBackend), which has no business happening while someone
    scrolls through a dropdown }
  if FBackendCombo.ItemIndex = AudioBackendPipeWire then
    RefreshDeviceLists;
  UpdateRowsForBackend;
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

{ Index 0 is "Default (system)" and maps to the empty name the backend reads
  as "let PipeWire pick"; everything after it indexes ADevices directly. }
function SelectedDeviceName(ACombo: TComboBox;
  const ADevices: TPWDeviceArray): string;
begin
  Result := '';
  if (ACombo.ItemIndex >= 1) and (ACombo.ItemIndex <= Length(ADevices)) then
    Result := ADevices[ACombo.ItemIndex - 1].Name;
end;

procedure TPrefsForm.OKButtonClick(Sender: TObject);
var
  NewBufferSize, NewInputBufferSize: Integer;
begin
  { applied on OK rather than on the combo's own OnChange, unlike SP-1200
    above - these stop/reopen the audio backend (see AudioEngineSetBufferSize
    and AudioEngineSetBackend), which would otherwise restart on every
    keystroke/scroll through the dropdown.

    Backend first: it reopens the device on its own, so applying a buffer
    size before it would only be undone. The buffer rows are then applied
    only if UpdateRowsForBackend left them enabled - under JACK those values
    are the server's and pushing this dialog's numbers at the engine would
    be a lie. }
  AudioEngineSetBackend(FBackendCombo.ItemIndex);

  { device choice next, and only when the rows are live (PipeWire) - it
    reopens the streams itself, and no-ops if nothing actually changed }
  if FOutputCombo.Enabled then
    AudioEngineSetPipeWireDevices(SelectedDeviceName(FOutputCombo, FOutputDevices),
      SelectedDeviceName(FInputCombo, FInputDevices));

  if FBufferSizeCombo.Enabled and
    TryStrToInt(FBufferSizeCombo.Text, NewBufferSize) then
    AudioEngineSetBufferSize(NewBufferSize);
  if FInputBufferSizeCombo.Enabled and
    TryStrToInt(FInputBufferSizeCombo.Text, NewInputBufferSize) then
    AudioEngineSetInputBufferSize(NewInputBufferSize);

  { Read back from the engine rather than from the controls, so what lands in
    eris.conf is what actually took effect. The two are not always the same:
    under JACK the buffer rows are greyed and never applied above, and saving
    the numbers still sitting in those dropdowns would persist settings this
    session never ran with, then restore them on the next launch.

    Sample rate is the exception - nothing applies it, so the combo is the
    only source there. Theme is carried through untouched; no UI writes it
    yet, and re-saving what was loaded keeps the key from being dropped. }
  Cfg.BackendName := AudioEngineBackendNameFromKind(AudioEngineGetBackend);
  Cfg.OutputDevice := AudioEngineGetPipeWireOutputDevice;
  Cfg.InputDevice := AudioEngineGetPipeWireInputDevice;
  Cfg.BufferSize := AudioEngineGetBufferSize;
  Cfg.InputBufferSize := AudioEngineGetInputBufferSize;
  Cfg.InputGainDb := Round(AudioEngineGetInputGainDb);
  if not TryStrToInt(FSampleRateCombo.Text, Cfg.SampleRate) then
    Cfg.SampleRate := 0;
  ConfigSave;
end;

end.
