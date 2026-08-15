unit DysPreferences;

{ The Edit menu's Preferences dialog - same options as Eris's own PrefsForm
  (src/ui), built from a Free Vision TDialog instead of an LCL form since
  there's no combo box / track bar equivalent here: enumerated choices
  (backend, SP-1200, theme) are TRadioButtons, everything else (devices,
  sample rate, buffer sizes, input gain) is a plain TInputLine with the
  allowed range spelled out in its label. Unlike PrefsForm, nothing here
  applies live as you change it (no SP-1200/gain preview) - everything
  commits together on OK, which is simpler and fine for a keyboard-driven
  dialog with no waveform/meter to watch react.

  Deliberately does NOT touch src/themeengine (ThemeSetMode/ThemeGetMode) -
  that unit is LCL-widgetset colour theming and is one of the two paths
  excluded from Dysnomia's build entirely (see tui.md's Isolation section).
  The Theme row here only ever reads/writes Cfg.Theme, the same as every
  other row - Eris's own OKButtonClick only applies Sample Rate and Theme
  by writing Cfg and calling ConfigSave too (both are documented in
  PrefsForm as "not applied live"), so this isn't a reduction in behaviour,
  it's the same behaviour Eris already has for exactly these two rows,
  extended to all of them for consistency in a dialog with no live preview
  to begin with. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Dialogs, App, Config, AudioEngine;

procedure ShowPreferencesDialog;

implementation

const
  DlgWidth = 58;
  DlgHeight = 28;

procedure ShowPreferencesDialog;
var
  R: TRect;
  Dlg: PDialog;
  BackendRG, SP1200RG, ThemeRG: PRadioButtons;
  OutputDevIL, InputDevIL, SampleRateIL, BufferSizeIL, InputBufIL,
    InputGainIL: PInputLine;
  Y, N: Integer;
  S: string[48];
  Res: Word;
begin
  R.Assign(0, 0, DlgWidth, DlgHeight);
  Dlg := New(PDialog, Init(R, 'Preferences'));
  Y := 1;

  R.Assign(2, Y, DlgWidth - 2, Y + 1);
  Dlg^.Insert(New(PStaticText, Init(R, 'Audio backend:')));
  Inc(Y);
  R.Assign(2, Y, 24, Y + 3);
  BackendRG := New(PRadioButtons, Init(R,
    NewSItem('ALSA', NewSItem('JACK', NewSItem('PipeWire', nil)))));
  BackendRG^.Value := AudioEngineGetBackend;
  Dlg^.Insert(BackendRG);
  Inc(Y, 3);

  R.Assign(2, Y, DlgWidth - 2, Y + 1);
  Dlg^.Insert(New(PStaticText, Init(R, 'Output device (PipeWire only):')));
  Inc(Y);
  R.Assign(2, Y, DlgWidth - 4, Y + 1);
  OutputDevIL := New(PInputLine, Init(R, 48));
  S := AudioEngineGetPipeWireOutputDevice;
  OutputDevIL^.SetData(S);
  Dlg^.Insert(OutputDevIL);
  Inc(Y, 2);

  R.Assign(2, Y, DlgWidth - 2, Y + 1);
  Dlg^.Insert(New(PStaticText, Init(R, 'Input device (PipeWire only):')));
  Inc(Y);
  R.Assign(2, Y, DlgWidth - 4, Y + 1);
  InputDevIL := New(PInputLine, Init(R, 48));
  S := AudioEngineGetPipeWireInputDevice;
  InputDevIL^.SetData(S);
  Dlg^.Insert(InputDevIL);
  Inc(Y, 2);

  R.Assign(2, Y, DlgWidth - 2, Y + 1);
  Dlg^.Insert(New(PStaticText, Init(R, 'Sample rate (44100 / 48000 / 96000):')));
  Inc(Y);
  R.Assign(2, Y, 14, Y + 1);
  SampleRateIL := New(PInputLine, Init(R, 6));
  Str(Cfg.SampleRate, S);
  SampleRateIL^.SetData(S);
  Dlg^.Insert(SampleRateIL);
  Inc(Y, 2);

  R.Assign(2, Y, DlgWidth - 2, Y + 1);
  Dlg^.Insert(New(PStaticText, Init(R, 'Buffer size (128-4096, power of two):')));
  Inc(Y);
  R.Assign(2, Y, 14, Y + 1);
  BufferSizeIL := New(PInputLine, Init(R, 6));
  Str(AudioEngineGetBufferSize, S);
  BufferSizeIL^.SetData(S);
  Dlg^.Insert(BufferSizeIL);
  Inc(Y, 2);

  R.Assign(2, Y, DlgWidth - 2, Y + 1);
  Dlg^.Insert(New(PStaticText, Init(R, 'SP-1200 (bit-crush):')));
  Inc(Y);
  R.Assign(2, Y, 14, Y + 2);
  SP1200RG := New(PRadioButtons, Init(R, NewSItem('Off', NewSItem('On', nil))));
  if AudioEngineGetSP1200Enabled then
    SP1200RG^.Value := 1
  else
    SP1200RG^.Value := 0;
  Dlg^.Insert(SP1200RG);
  Inc(Y, 2);

  R.Assign(2, Y, DlgWidth - 2, Y + 1);
  Dlg^.Insert(New(PStaticText, Init(R, 'Input buffer size (128-4096):')));
  Inc(Y);
  R.Assign(2, Y, 14, Y + 1);
  InputBufIL := New(PInputLine, Init(R, 6));
  Str(AudioEngineGetInputBufferSize, S);
  InputBufIL^.SetData(S);
  Dlg^.Insert(InputBufIL);
  Inc(Y, 2);

  R.Assign(2, Y, DlgWidth - 2, Y + 1);
  Dlg^.Insert(New(PStaticText, Init(R, 'Input gain, dB (-24..24):')));
  Inc(Y);
  R.Assign(2, Y, 14, Y + 1);
  InputGainIL := New(PInputLine, Init(R, 6));
  Str(Round(AudioEngineGetInputGainDb), S);
  InputGainIL^.SetData(S);
  Dlg^.Insert(InputGainIL);
  Inc(Y, 2);

  R.Assign(2, Y, DlgWidth - 2, Y + 1);
  Dlg^.Insert(New(PStaticText, Init(R, 'Theme:')));
  Inc(Y);
  R.Assign(2, Y, 24, Y + 3);
  ThemeRG := New(PRadioButtons, Init(R,
    NewSItem('Follow system', NewSItem('Light', NewSItem('Dark', nil)))));
  ThemeRG^.Value := Cfg.Theme;
  Dlg^.Insert(ThemeRG);

  R.Assign(2, DlgHeight - 3, 14, DlgHeight - 1);
  Dlg^.Insert(New(PButton, Init(R, '~O~K', cmOK, bfDefault)));
  R.Assign(16, DlgHeight - 3, 28, DlgHeight - 1);
  Dlg^.Insert(New(PButton, Init(R, 'Cancel', cmCancel, bfNormal)));

  Dlg^.SelectNext(False);
  { TGroup.ExecView (called via Desktop^.ExecView below) inserts Dlg itself
    (it has no Owner yet) and removes it again once modal execution ends,
    but does not Dispose it - so it's safe to read straight off each
    control's own kept pointer afterward, then Dispose manually. Simpler
    and more direct than the classic SetData/GetData packed-record dance
    (TGroup.GetData walks children in insertion order via raw DataSize
    pointer arithmetic - exact but easy to get subtly wrong by hand). }
  Res := Desktop^.ExecView(Dlg);
  if Res = cmOK then
  begin
    AudioEngineSetBackend(BackendRG^.Value);
    if BackendRG^.Value = AudioBackendPipeWire then
      AudioEngineSetPipeWireDevices(OutputDevIL^.Data^, InputDevIL^.Data^);
    if TryStrToInt(SampleRateIL^.Data^, N) then
      Cfg.SampleRate := N;
    if TryStrToInt(BufferSizeIL^.Data^, N) then
      AudioEngineSetBufferSize(N);
    AudioEngineSetSP1200Enabled(SP1200RG^.Value = 1);
    if TryStrToInt(InputBufIL^.Data^, N) then
      AudioEngineSetInputBufferSize(N);
    if TryStrToInt(InputGainIL^.Data^, N) then
      AudioEngineSetInputGainDb(N);
    Cfg.Theme := ThemeRG^.Value;

    { Same order/source Eris's own OKButtonClick uses: reads config fields
      back from the engine (not the combo/edit text) so eris.conf only ever
      persists values that actually took effect - Sample Rate and Theme are
      the two exceptions, since nothing applies either of them live. }
    Cfg.BackendName := AudioEngineBackendNameFromKind(AudioEngineGetBackend);
    Cfg.OutputDevice := AudioEngineGetPipeWireOutputDevice;
    Cfg.InputDevice := AudioEngineGetPipeWireInputDevice;
    Cfg.BufferSize := AudioEngineGetBufferSize;
    Cfg.InputBufferSize := AudioEngineGetInputBufferSize;
    Cfg.InputGainDb := Round(AudioEngineGetInputGainDb);
    ConfigSave;
  end;
  Dispose(Dlg, Done);
  { TGroup.Remove (inside ExecView, above) is supposed to re-expose and
    redraw whatever the dialog was covering on its own - in practice the
    screen was still showing dialog leftovers after Dispose, both here and
    in RunFileDialog (DysFileDialog.pas), reported as "closing a dialog
    glitches everything out". Forcing the whole desktop to repaint once the
    dialog is gone for good is the standard Turbo Vision/Free Vision fallback
    for exactly this - see tui.md's Free Vision notes. ReDraw, not DrawView:
    DrawView only repaints if Desktop's own Exposed flag happens to be set
    and only forces a non-forced buffer flush - TGroup.ReDraw skips that
    gate and forces the flush unconditionally, which is the more reliable
    primitive when the whole point is "definitely clear this, regardless of
    whatever Free Vision's own Exposed bookkeeping currently thinks". }
  Desktop^.ReDraw;
end;

end.
