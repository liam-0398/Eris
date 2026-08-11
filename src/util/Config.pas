unit Config;

{$mode objfpc}{$H+}

{ Application-wide settings that outlive a session - how this machine's audio
  is set up, and (later) which theme the UI uses.

  Project-scoped state deliberately does NOT live here. The SP-1200 toggle,
  for instance, is saved per project by ProjectFile because it is part of how
  a track sounds, not part of how this installation is configured; the same
  test decides anything added later.

  Kept as a leaf unit - SysUtils and IniFiles and nothing else. AudioEngine
  reads this during start-up, so whatever this pulled in would land in that
  path too, and the mapping between a backend's name here and its AudioBackend*
  ordinal lives in AudioEngine (which owns those constants) rather than here. }

interface

const
  { Persisted as a name rather than an ordinal so the file's meaning never
    depends on the order these happen to be declared in. Nothing consumes this
    yet - the theme engine will - but it round-trips from the first save so the
    key is present in every file this build writes. }
  ThemeSystem = 0;
  ThemeLight = 1;
  ThemeDark = 2;

type
  { Zero and '' both mean "not configured", and every consumer keeps its own
    default for anything unset. That is what makes a missing eris.conf - or one
    written by a build that had fewer keys - reproduce exactly the behaviour
    this app had before any of this existed, rather than clamping settings to
    zero. It works in the other direction too: TIniFile returns the supplied
    default for a key it cannot find and silently leaves alone any key nothing
    asks for, so an older build reading a newer file loses nothing.

    SampleRate is written and read back but nothing applies it - the engine's
    rate is the ProjectSampleRate constant. The key exists so the value is
    already being carried by the time the backend can honour it. }
  TErisConfig = record
    BackendName: string;
    OutputDevice: string;
    InputDevice: string;
    SampleRate: Integer;
    BufferSize: Integer;
    InputBufferSize: Integer;
    InputGainDb: Integer;
    Theme: Integer;
  end;

var
  Cfg: TErisConfig;

function ConfigFilePath: string;
procedure ConfigLoad;
procedure ConfigSave;

function ConfigThemeToName(AValue: Integer): string;
function ConfigThemeFromName(const AName: string): Integer;

implementation

uses
  SysUtils, IniFiles;

const
  SecAudio = 'audio';
  SecUI = 'ui';

{ GetAppConfigDir(False) is the per-user location the platform itself
  nominates - ~/.config/eris/ on Linux, %APPDATA%\eris\ on Windows - which is
  why there is no $IFDEF in here. ApplicationName defaults to the executable's
  base name, which is 'eris' on both targets. }
function ConfigFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'eris.conf';
end;

function ConfigThemeToName(AValue: Integer): string;
begin
  case AValue of
    ThemeLight: Result := 'light';
    ThemeDark: Result := 'dark';
  else
    Result := 'system';
  end;
end;

{ Anything unrecognised - including a key written by a future build - reads as
  "follow the system", which is the setting that behaves sanely everywhere. }
function ConfigThemeFromName(const AName: string): Integer;
begin
  if SameText(AName, 'light') then
    Result := ThemeLight
  else if SameText(AName, 'dark') then
    Result := ThemeDark
  else
    Result := ThemeSystem;
end;

{ Safe to call when no file exists: TIniFile treats a missing path as an empty
  file rather than an error, so every read below simply yields its default and
  first run needs no special case. }
procedure ConfigLoad;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(ConfigFilePath);
  try
    Cfg.BackendName := Ini.ReadString(SecAudio, 'backend', '');
    Cfg.OutputDevice := Ini.ReadString(SecAudio, 'output_device', '');
    Cfg.InputDevice := Ini.ReadString(SecAudio, 'input_device', '');
    Cfg.SampleRate := Ini.ReadInteger(SecAudio, 'sample_rate', 0);
    Cfg.BufferSize := Ini.ReadInteger(SecAudio, 'buffer_size', 0);
    Cfg.InputBufferSize := Ini.ReadInteger(SecAudio, 'input_buffer_size', 0);
    { A plain integer count of dB, not a float, because the only thing that
      produces this value is a TTrackBar position (see PrefsForm) and an
      integer carries no decimal separator - which is the locale trap
      ProjectFile has to work around with PortableFloatSettings. Widening it
      later costs a format bump and nothing else. }
    Cfg.InputGainDb := Ini.ReadInteger(SecAudio, 'input_gain_db', 0);
    Cfg.Theme := ConfigThemeFromName(Ini.ReadString(SecUI, 'theme', 'system'));
  finally
    Ini.Free;
  end;
end;

procedure ConfigSave;
var
  Ini: TIniFile;
begin
  { ~/.config/eris/ will not exist the first time, and TIniFile does not create
    intermediate directories for itself - without this the write is silently
    lost and the settings simply never persist. }
  ForceDirectories(ExtractFilePath(ConfigFilePath));

  Ini := TIniFile.Create(ConfigFilePath);
  try
    { TIniFile leaves CacheUpdates False by default, which rewrites the whole
      file on every single Write* below (see TIniFile.MaybeUpdateFile in FPC's
      inifiles.pp). Batching them into the one UpdateFile costs a line and
      turns eight rewrites into one. }
    Ini.CacheUpdates := True;

    Ini.WriteString(SecAudio, 'backend', Cfg.BackendName);
    Ini.WriteString(SecAudio, 'output_device', Cfg.OutputDevice);
    Ini.WriteString(SecAudio, 'input_device', Cfg.InputDevice);
    Ini.WriteInteger(SecAudio, 'sample_rate', Cfg.SampleRate);
    Ini.WriteInteger(SecAudio, 'buffer_size', Cfg.BufferSize);
    Ini.WriteInteger(SecAudio, 'input_buffer_size', Cfg.InputBufferSize);
    Ini.WriteInteger(SecAudio, 'input_gain_db', Cfg.InputGainDb);
    Ini.WriteString(SecUI, 'theme', ConfigThemeToName(Cfg.Theme));

    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

end.
