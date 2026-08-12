unit ProjectFile;

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  { Thin TThread wrappers so File > Open/Save/Export and single-file sample
    import (drag-to-timeline, "use as instrument") can run off the UI
    thread - Open/Save pack or unpack a tar archive (TarArchive.pas) plus
    decode every referenced sample, and Export renders the whole
    arrangement; all four are slow enough on a real project/sample to read
    as "not responding" if run inline on the calling event handler.

    Same immediate-start pattern as TSampleLoadThread below (Create(True)
    hangs under FPC's Linux/cthreads suspended-thread emulation - see that
    class's constructor comment). OnTerminate is a constructor PARAMETER,
    set before inherited Create(False) - the same "every field populated
    before the thread can possibly run" rule TSampleLoadThread.Create
    already follows for FJobs. Assigning OnTerminate as a property AFTER
    Create(False) returns is a real race, not just a theoretical one: for
    a fast job (small file, or an instant decode failure) the thread can
    finish and evaluate "if Assigned(OnTerminate)" as still nil - the
    caller hasn't reached that assignment yet - skip calling it entirely,
    and then free itself (FreeOnTerminate). The caller's next line then
    writes OnTerminate into an already-freed object. }
  TProjectLoadThread = class(TThread)
  private
    FPath: string;
    FSuccess: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const APath: string; AOnTerminate: TNotifyEvent);
    property Path: string read FPath;
    property Success: Boolean read FSuccess;
  end;

  TProjectSaveThread = class(TThread)
  private
    FPath: string;
    FSuccess: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const APath: string; AOnTerminate: TNotifyEvent);
    property Path: string read FPath;
    property Success: Boolean read FSuccess;
  end;

  TProjectRenderThread = class(TThread)
  private
    FPath: string;
    FSuccess: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const APath: string; AOnTerminate: TNotifyEvent);
    property Path: string read FPath;
    property Success: Boolean read FSuccess;
  end;

  { Decodes one sample file and adds it to the pool off the UI thread - the
    same decode+peak+transient cost LoadSamplesThreaded fans out across a
    pool for a whole project, here done for the single file a drag-drop or
    "use as instrument" action just picked. }
  TSampleImportThread = class(TThread)
  private
    FPath: string;
    FDisplayName: string;
    FSuccess: Boolean;
    FSampleID: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const APath, ADisplayName: string;
      AOnTerminate: TNotifyEvent);
    property Path: string read FPath;
    property Success: Boolean read FSuccess;
    property SampleID: Integer read FSampleID;
  end;

const
  { normal project - the ini references samples by their path out on disk }
  ProjectExt = '.er';
  { "Eris Standalone Project" - same archive, except every sample the project
    uses is copied INTO it, so the file is self-contained and opens with its
    audio intact wherever it ends up. Which of the two a save produces is
    decided by the extension of the path being written, so Save (which reuses
    the open project's own path) keeps writing whatever kind was opened, with
    nothing to confirm. }
  StandaloneProjectExt = '.ers';

{ True for a path this build would write as a standalone bundle }
function IsStandalonePath(const APath: string): Boolean;

function SaveProject(const APath: string): Boolean;
function LoadProject(const APath: string): Boolean;
function RenderProjectToWav(const AOutputPath: string): Boolean;

{ Drops the extracted copy of the open standalone project kept alive by
  LoadProject (see FBundleDir) - call when the project it belongs to is
  abandoned without another being loaded, i.e. File > New. }
procedure ReleaseBundleDir;

implementation

uses
  SysUtils, IniFiles, FileUtil, SampleTypes, Project, ProjectCache, WavDecoder,
  AudioEngine, Resample, Waveform, SP1200, TarArchive, Effects, Quadraverb,
  Alesis3630, BossFZ2, ThreadUtil, DenormalGuard, AVector
  {$IFDEF WINDOWS}, Windows{$ENDIF};

{ RTL RenameFile is rename(2) on unix - which replaces an existing
  destination atomically - but MoveFile on Windows, which FAILS outright if
  the destination exists. That is why saving over an existing project used
  to report "could not save" on Windows while Save As to a fresh name worked
  fine. MoveFileEx with MOVEFILE_REPLACE_EXISTING restores the unix
  semantics the save path below is written against, keeping the replacement
  a single operation rather than a delete-then-rename that would leave the
  last good save deleted if the rename then failed. }
function ReplaceFile(const AFrom, ATo: string): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := MoveFileExW(PWideChar(UnicodeString(AFrom)),
    PWideChar(UnicodeString(ATo)), MOVEFILE_REPLACE_EXISTING);
  {$ELSE}
  Result := RenameFile(AFrom, ATo);
  {$ENDIF}
end;

var
  { Where the open standalone project was unpacked, kept alive for as long as
    it stays open instead of being deleted at the end of the load like a
    normal project's scratch copy is.

    It is the only surviving copy of that project's audio as FILES: a
    standalone bundle stores each sample under a bare name inside itself, so
    once the load finishes, Project.SamplePaths holds names that resolve
    nowhere on disk. Without this, the next Save would have nothing to copy
    and would fall back to re-encoding each sample out of the pool - which
    still saves a valid standalone project, but writes 16-bit
    canonical-rate WAVs (see WavWriteBegin/ResampleToCanonical), so a
    24-bit kit would quietly lose its depth on the first round trip.
    Holding the extracted copy lets Save byte-copy the originals instead,
    however many times the project is saved and reopened.

    '' when no standalone project is open. }
  FBundleDir: string = '';

function IsStandalonePath(const APath: string): Boolean;
begin
  Result := LowerCase(ExtractFileExt(APath)) = StandaloneProjectExt;
end;

procedure ReleaseBundleDir;
begin
  if (FBundleDir <> '') and DirectoryExists(FBundleDir) then
    DeleteDirectory(FBundleDir, False);
  FBundleDir := '';
end;

constructor TProjectLoadThread.Create(const APath: string; AOnTerminate: TNotifyEvent);
begin
  FPath := APath;
  OnTerminate := AOnTerminate;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TProjectLoadThread.Execute;
begin
  FSuccess := LoadProject(FPath);
end;

constructor TProjectSaveThread.Create(const APath: string; AOnTerminate: TNotifyEvent);
begin
  FPath := APath;
  OnTerminate := AOnTerminate;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TProjectSaveThread.Execute;
begin
  FSuccess := SaveProject(FPath);
end;

constructor TProjectRenderThread.Create(const APath: string; AOnTerminate: TNotifyEvent);
begin
  FPath := APath;
  OnTerminate := AOnTerminate;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TProjectRenderThread.Execute;
begin
  { same per-thread denormal mode the realtime playback thread runs in, so a
    bounce can't diverge from what was heard live - and so a long reverb tail
    doesn't make the render itself crawl. See DenormalGuard. }
  EnableFlushDenormals;
  FSuccess := RenderProjectToWav(FPath);
end;

constructor TSampleImportThread.Create(const APath, ADisplayName: string;
  AOnTerminate: TNotifyEvent);
begin
  FPath := APath;
  FDisplayName := ADisplayName;
  FSampleID := -1;
  OnTerminate := AOnTerminate;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TSampleImportThread.Execute;
var
  Sample: TSample;
begin
  FSuccess := DecodeSampleFile(FPath, Sample);
  if FSuccess then
    FSampleID := Project.AddSampleToPool(Sample, FDisplayName, FPath);
end;

{ Every field of TEffect is written/read unconditionally regardless of Kind -
  it's a flat tagged record, so this is simpler and safer than branching per
  Kind, and any fields unused by a given Kind are just harmlessly ignored. }
procedure SaveEffect(Ini: TIniFile; const ASection, APrefix: string;
  const AEffect: Effects.TEffect);
var
  b: Integer;
begin
  Ini.WriteInteger(ASection, APrefix + 'Kind', AEffect.Kind);
  Ini.WriteFloat(ASection, APrefix + 'LowpassFreqHz', AEffect.LowpassFreqHz);
  Ini.WriteFloat(ASection, APrefix + 'HighpassFreqHz', AEffect.HighpassFreqHz);
  Ini.WriteFloat(ASection, APrefix + 'BandpassFreqHz', AEffect.BandpassFreqHz);
  Ini.WriteFloat(ASection, APrefix + 'BandpassQ', AEffect.BandpassQ);
  for b := 0 to Effects.MaxEQBands - 1 do
  begin
    Ini.WriteFloat(ASection, APrefix + 'EQFreq' + IntToStr(b), AEffect.EQFreqHz[b]);
    Ini.WriteFloat(ASection, APrefix + 'EQGain' + IntToStr(b), AEffect.EQGainDb[b]);
  end;
  Ini.WriteFloat(ASection, APrefix + 'LimiterThresholdDb', AEffect.LimiterThresholdDb);
  Ini.WriteFloat(ASection, APrefix + 'LimiterReleaseMs', AEffect.LimiterReleaseMs);
  Ini.WriteFloat(ASection, APrefix + 'ChorusRateHz', AEffect.ChorusRateHz);
  Ini.WriteFloat(ASection, APrefix + 'ChorusDepthPercent', AEffect.ChorusDepthPercent);
  Ini.WriteInteger(ASection, APrefix + 'ReverbPreset', AEffect.ReverbPreset);
  Ini.WriteFloat(ASection, APrefix + 'ReverbMixPercent', AEffect.ReverbMixPercent);
  Ini.WriteFloat(ASection, APrefix + 'FlangerRateHz', AEffect.FlangerRateHz);
  Ini.WriteFloat(ASection, APrefix + 'FlangerDepthPercent', AEffect.FlangerDepthPercent);
  Ini.WriteFloat(ASection, APrefix + 'FlangerFeedbackPercent', AEffect.FlangerFeedbackPercent);
  Ini.WriteFloat(ASection, APrefix + 'FlangerMixPercent', AEffect.FlangerMixPercent);
  Ini.WriteFloat(ASection, APrefix + 'PhaserRateHz', AEffect.PhaserRateHz);
  Ini.WriteFloat(ASection, APrefix + 'PhaserDepthPercent', AEffect.PhaserDepthPercent);
  Ini.WriteFloat(ASection, APrefix + 'PhaserFeedbackPercent', AEffect.PhaserFeedbackPercent);
  Ini.WriteFloat(ASection, APrefix + 'PhaserMixPercent', AEffect.PhaserMixPercent);
  Ini.WriteInteger(ASection, APrefix + 'SidechainSourceTrack', AEffect.SidechainSourceTrack);
  Ini.WriteFloat(ASection, APrefix + 'SidechainThresholdDb', AEffect.SidechainThresholdDb);
  Ini.WriteFloat(ASection, APrefix + 'SidechainAttackMs', AEffect.SidechainAttackMs);
  Ini.WriteFloat(ASection, APrefix + 'SidechainReleaseMs', AEffect.SidechainReleaseMs);
  Ini.WriteFloat(ASection, APrefix + 'SidechainStrengthPercent', AEffect.SidechainStrengthPercent);
  Ini.WriteFloat(ASection, APrefix + 'DrowningToneHz', AEffect.DrowningToneHz);
  Ini.WriteFloat(ASection, APrefix + 'DrowningWarbleRateHz', AEffect.DrowningWarbleRateHz);
  Ini.WriteFloat(ASection, APrefix + 'DrowningWarbleDepthPercent', AEffect.DrowningWarbleDepthPercent);
  Ini.WriteFloat(ASection, APrefix + 'DrowningSizePercent', AEffect.DrowningSizePercent);
  Ini.WriteFloat(ASection, APrefix + 'DrowningDecayPercent', AEffect.DrowningDecayPercent);
  Ini.WriteFloat(ASection, APrefix + 'DrowningMixPercent', AEffect.DrowningMixPercent);
  { ekTuner has no parameters of its own - its Kind above is the whole of it }
  Ini.WriteFloat(ASection, APrefix + 'OverdriveFreqHz', AEffect.OverdriveFreqHz);
  Ini.WriteFloat(ASection, APrefix + 'OverdriveQ', AEffect.OverdriveQ);
  Ini.WriteFloat(ASection, APrefix + 'OverdriveDrivePercent', AEffect.OverdriveDrivePercent);
  Ini.WriteFloat(ASection, APrefix + 'OverdriveColorPercent', AEffect.OverdriveColorPercent);
  Ini.WriteFloat(ASection, APrefix + 'OverdriveMixPercent', AEffect.OverdriveMixPercent);
  Ini.WriteInteger(ASection, APrefix + 'QVReverbType', AEffect.QVReverbType);
  Ini.WriteFloat(ASection, APrefix + 'QVReverbPredelayMs', AEffect.QVReverbPredelayMs);
  Ini.WriteFloat(ASection, APrefix + 'QVReverbPredelayMix', AEffect.QVReverbPredelayMix);
  Ini.WriteFloat(ASection, APrefix + 'QVReverbDecay', AEffect.QVReverbDecay);
  Ini.WriteFloat(ASection, APrefix + 'QVReverbDiffusion', AEffect.QVReverbDiffusion);
  Ini.WriteFloat(ASection, APrefix + 'QVReverbDensity', AEffect.QVReverbDensity);
  Ini.WriteFloat(ASection, APrefix + 'QVReverbLowDecay', AEffect.QVReverbLowDecay);
  Ini.WriteFloat(ASection, APrefix + 'QVReverbHighDecay', AEffect.QVReverbHighDecay);
  Ini.WriteFloat(ASection, APrefix + 'QVReverbMixPercent', AEffect.QVReverbMixPercent);
  Ini.WriteInteger(ASection, APrefix + 'QVDelayType', AEffect.QVDelayType);
  Ini.WriteFloat(ASection, APrefix + 'QVDelayTimeLMs', AEffect.QVDelayTimeLMs);
  Ini.WriteFloat(ASection, APrefix + 'QVDelayTimeRMs', AEffect.QVDelayTimeRMs);
  Ini.WriteFloat(ASection, APrefix + 'QVDelayFeedbackL', AEffect.QVDelayFeedbackL);
  Ini.WriteFloat(ASection, APrefix + 'QVDelayFeedbackR', AEffect.QVDelayFeedbackR);
  Ini.WriteFloat(ASection, APrefix + 'QVDelayMixPercent', AEffect.QVDelayMixPercent);
  Ini.WriteFloat(ASection, APrefix + 'BBELoContourDb', AEffect.BBELoContourDb);
  Ini.WriteFloat(ASection, APrefix + 'BBEDefinition', AEffect.BBEDefinition);
  Ini.WriteFloat(ASection, APrefix + 'BBEMixPercent', AEffect.BBEMixPercent);
  Ini.WriteInteger(ASection, APrefix + 'C36Response', AEffect.C36Response);
  Ini.WriteInteger(ASection, APrefix + 'C36Knee', AEffect.C36Knee);
  Ini.WriteFloat(ASection, APrefix + 'C36ThresholdDbu', AEffect.C36ThresholdDbu);
  Ini.WriteFloat(ASection, APrefix + 'C36Ratio', AEffect.C36Ratio);
  Ini.WriteFloat(ASection, APrefix + 'C36AttackMs', AEffect.C36AttackMs);
  Ini.WriteFloat(ASection, APrefix + 'C36ReleaseMs', AEffect.C36ReleaseMs);
  Ini.WriteFloat(ASection, APrefix + 'C36OutputDb', AEffect.C36OutputDb);
  Ini.WriteFloat(ASection, APrefix + 'C36GateThresholdDbfs', AEffect.C36GateThresholdDbfs);
  Ini.WriteFloat(ASection, APrefix + 'C36GateRateMs', AEffect.C36GateRateMs);
  Ini.WriteFloat(ASection, APrefix + 'C36MixPercent', AEffect.C36MixPercent);
  Ini.WriteInteger(ASection, APrefix + 'FZ2Mode', AEffect.FZ2Mode);
  Ini.WriteFloat(ASection, APrefix + 'FZ2Gain', AEffect.FZ2Gain);
  Ini.WriteFloat(ASection, APrefix + 'FZ2Treble', AEffect.FZ2Treble);
  Ini.WriteFloat(ASection, APrefix + 'FZ2Bass', AEffect.FZ2Bass);
  Ini.WriteFloat(ASection, APrefix + 'FZ2Level', AEffect.FZ2Level);
  Ini.WriteFloat(ASection, APrefix + 'FZ2MixPercent', AEffect.FZ2MixPercent);
end;

function LoadEffect(Ini: TIniFile; const ASection, APrefix: string): Effects.TEffect;
var
  b: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := Ini.ReadInteger(ASection, APrefix + 'Kind', Effects.ekNone);
  Result.LowpassFreqHz := Ini.ReadFloat(ASection, APrefix + 'LowpassFreqHz', 8000);
  { defaults here mirror Effects.DefaultEffect, so a project saved before
    these three keys existed reloads its HP/BP at the same settings the
    effect was created with rather than at 0 Hz / Q 0 }
  Result.HighpassFreqHz := Ini.ReadFloat(ASection, APrefix + 'HighpassFreqHz', 100);
  Result.BandpassFreqHz := Ini.ReadFloat(ASection, APrefix + 'BandpassFreqHz', 1000);
  Result.BandpassQ := Ini.ReadFloat(ASection, APrefix + 'BandpassQ', 1.0);
  for b := 0 to Effects.MaxEQBands - 1 do
  begin
    Result.EQFreqHz[b] := Ini.ReadFloat(ASection, APrefix + 'EQFreq' + IntToStr(b), 0);
    Result.EQGainDb[b] := Ini.ReadFloat(ASection, APrefix + 'EQGain' + IntToStr(b), 0);
  end;
  Result.LimiterThresholdDb := Ini.ReadFloat(ASection, APrefix + 'LimiterThresholdDb', -1);
  Result.LimiterReleaseMs := Ini.ReadFloat(ASection, APrefix + 'LimiterReleaseMs', 150);
  Result.ChorusRateHz := Ini.ReadFloat(ASection, APrefix + 'ChorusRateHz', 0.5);
  Result.ChorusDepthPercent := Ini.ReadFloat(ASection, APrefix + 'ChorusDepthPercent', 50);
  Result.ReverbPreset := Ini.ReadInteger(ASection, APrefix + 'ReverbPreset', Effects.ReverbPresetRoom);
  Result.ReverbMixPercent := Ini.ReadFloat(ASection, APrefix + 'ReverbMixPercent', 30);
  Result.FlangerRateHz := Ini.ReadFloat(ASection, APrefix + 'FlangerRateHz', 0.3);
  Result.FlangerDepthPercent := Ini.ReadFloat(ASection, APrefix + 'FlangerDepthPercent', 60);
  Result.FlangerFeedbackPercent := Ini.ReadFloat(ASection, APrefix + 'FlangerFeedbackPercent', 40);
  Result.FlangerMixPercent := Ini.ReadFloat(ASection, APrefix + 'FlangerMixPercent', 50);
  Result.PhaserRateHz := Ini.ReadFloat(ASection, APrefix + 'PhaserRateHz', 0.4);
  Result.PhaserDepthPercent := Ini.ReadFloat(ASection, APrefix + 'PhaserDepthPercent', 70);
  Result.PhaserFeedbackPercent := Ini.ReadFloat(ASection, APrefix + 'PhaserFeedbackPercent', 30);
  Result.PhaserMixPercent := Ini.ReadFloat(ASection, APrefix + 'PhaserMixPercent', 50);
  Result.SidechainSourceTrack := Ini.ReadInteger(ASection, APrefix + 'SidechainSourceTrack', 0);
  Result.SidechainThresholdDb := Ini.ReadFloat(ASection, APrefix + 'SidechainThresholdDb', -20);
  Result.SidechainAttackMs := Ini.ReadFloat(ASection, APrefix + 'SidechainAttackMs', 5);
  Result.SidechainReleaseMs := Ini.ReadFloat(ASection, APrefix + 'SidechainReleaseMs', 150);
  Result.SidechainStrengthPercent := Ini.ReadFloat(ASection, APrefix + 'SidechainStrengthPercent', 70);
  Result.DrowningToneHz := Ini.ReadFloat(ASection, APrefix + 'DrowningToneHz', 2500);
  Result.DrowningWarbleRateHz := Ini.ReadFloat(ASection, APrefix + 'DrowningWarbleRateHz', 0.35);
  Result.DrowningWarbleDepthPercent := Ini.ReadFloat(ASection, APrefix + 'DrowningWarbleDepthPercent', 55);
  Result.DrowningSizePercent := Ini.ReadFloat(ASection, APrefix + 'DrowningSizePercent', 65);
  Result.DrowningDecayPercent := Ini.ReadFloat(ASection, APrefix + 'DrowningDecayPercent', 70);
  Result.DrowningMixPercent := Ini.ReadFloat(ASection, APrefix + 'DrowningMixPercent', 45);
  Result.OverdriveFreqHz := Ini.ReadFloat(ASection, APrefix + 'OverdriveFreqHz', 800);
  Result.OverdriveQ := Ini.ReadFloat(ASection, APrefix + 'OverdriveQ', 0.7);
  Result.OverdriveDrivePercent := Ini.ReadFloat(ASection, APrefix + 'OverdriveDrivePercent', 40);
  Result.OverdriveColorPercent := Ini.ReadFloat(ASection, APrefix + 'OverdriveColorPercent', 30);
  Result.OverdriveMixPercent := Ini.ReadFloat(ASection, APrefix + 'OverdriveMixPercent', 100);
  Result.QVReverbType := Ini.ReadInteger(ASection, APrefix + 'QVReverbType', Quadraverb.QVReverbHall);
  Result.QVReverbPredelayMs := Ini.ReadFloat(ASection, APrefix + 'QVReverbPredelayMs', 65);
  Result.QVReverbPredelayMix := Ini.ReadFloat(ASection, APrefix + 'QVReverbPredelayMix', 70);
  Result.QVReverbDecay := Ini.ReadFloat(ASection, APrefix + 'QVReverbDecay', 82);
  Result.QVReverbDiffusion := Ini.ReadFloat(ASection, APrefix + 'QVReverbDiffusion', 8);
  Result.QVReverbDensity := Ini.ReadFloat(ASection, APrefix + 'QVReverbDensity', 6);
  Result.QVReverbLowDecay := Ini.ReadFloat(ASection, APrefix + 'QVReverbLowDecay', -10);
  Result.QVReverbHighDecay := Ini.ReadFloat(ASection, APrefix + 'QVReverbHighDecay', -62);
  Result.QVReverbMixPercent := Ini.ReadFloat(ASection, APrefix + 'QVReverbMixPercent', 35);
  Result.QVDelayType := Ini.ReadInteger(ASection, APrefix + 'QVDelayType', Quadraverb.QVDelayPingPong);
  Result.QVDelayTimeLMs := Ini.ReadFloat(ASection, APrefix + 'QVDelayTimeLMs', 375);
  Result.QVDelayTimeRMs := Ini.ReadFloat(ASection, APrefix + 'QVDelayTimeRMs', 375);
  Result.QVDelayFeedbackL := Ini.ReadFloat(ASection, APrefix + 'QVDelayFeedbackL', 45);
  Result.QVDelayFeedbackR := Ini.ReadFloat(ASection, APrefix + 'QVDelayFeedbackR', 45);
  Result.QVDelayMixPercent := Ini.ReadFloat(ASection, APrefix + 'QVDelayMixPercent', 30);
  Result.BBELoContourDb := Ini.ReadFloat(ASection, APrefix + 'BBELoContourDb', 4);
  Result.BBEDefinition := Ini.ReadFloat(ASection, APrefix + 'BBEDefinition', 65);
  Result.BBEMixPercent := Ini.ReadFloat(ASection, APrefix + 'BBEMixPercent', 100);
  Result.C36Response := Ini.ReadInteger(ASection, APrefix + 'C36Response', Alesis3630.A36ResponsePeak);
  Result.C36Knee := Ini.ReadInteger(ASection, APrefix + 'C36Knee', Alesis3630.A36KneeHard);
  Result.C36ThresholdDbu := Ini.ReadFloat(ASection, APrefix + 'C36ThresholdDbu', -8);
  Result.C36Ratio := Ini.ReadFloat(ASection, APrefix + 'C36Ratio', 8);
  Result.C36AttackMs := Ini.ReadFloat(ASection, APrefix + 'C36AttackMs', 1);
  Result.C36ReleaseMs := Ini.ReadFloat(ASection, APrefix + 'C36ReleaseMs', 120);
  Result.C36OutputDb := Ini.ReadFloat(ASection, APrefix + 'C36OutputDb', 4);
  Result.C36GateThresholdDbfs := Ini.ReadFloat(ASection, APrefix + 'C36GateThresholdDbfs',
    Alesis3630.A36GateOffDbfs);
  Result.C36GateRateMs := Ini.ReadFloat(ASection, APrefix + 'C36GateRateMs', 200);
  Result.C36MixPercent := Ini.ReadFloat(ASection, APrefix + 'C36MixPercent', 100);
  Result.FZ2Mode := Ini.ReadInteger(ASection, APrefix + 'FZ2Mode', BossFZ2.FZ2ModeFuzz2);
  Result.FZ2Gain := Ini.ReadFloat(ASection, APrefix + 'FZ2Gain', 100);
  Result.FZ2Treble := Ini.ReadFloat(ASection, APrefix + 'FZ2Treble', 62);
  Result.FZ2Bass := Ini.ReadFloat(ASection, APrefix + 'FZ2Bass', 88);
  Result.FZ2Level := Ini.ReadFloat(ASection, APrefix + 'FZ2Level', 45);
  Result.FZ2MixPercent := Ini.ReadFloat(ASection, APrefix + 'FZ2MixPercent', 100);
end;

function PortableFloatSettings: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

const
  { one key per track holds every clip, instead of ~9 keys per clip plus 2
    per warp marker - see the comment on PackClips below for why }
  ClipDelim = '|';
  MarkerDelim = ';';
  MarkerFieldDelim = ':';

function PackClip(const AClip: TClip): string;
var
  FS: TFormatSettings;
  m: Integer;
  MarkerPart: string;
begin
  FS := PortableFloatSettings;
  MarkerPart := '';
  for m := 0 to High(AClip.WarpMarkers) do
  begin
    if m > 0 then
      MarkerPart := MarkerPart + MarkerDelim;
    MarkerPart := MarkerPart + IntToStr(AClip.WarpMarkers[m].SourceFrame) +
      MarkerFieldDelim + IntToStr(AClip.WarpMarkers[m].TimelineFrame);
  end;
  Result := Format('%d,%d,%d,%d,%s,%s,%d,%s', [AClip.SampleID, AClip.Offset,
    AClip.Length, AClip.Position, FloatToStr(AClip.PitchSemitones, FS),
    FloatToStr(AClip.Gain, FS), AClip.WarpMode, MarkerPart]);
end;

{ Packs a whole track's clip list (including every clip's warp markers) into
  ONE string, written under a single ini key - see LoadProject/SaveProject.
  TIniFile (src: FPC's inifiles.pp) does a linear scan to find a key within
  a section on every single Read/Write call, AND (since CacheUpdates isn't
  enabled - see SaveProject) rewrites the entire ini file to disk on every
  single Write call. The old format wrote ~9 keys per clip plus 2 per warp
  marker directly into the track's section, so saving/loading a heavily
  chopped track (this app's core workflow) was O(clip-count^2) both ways.
  Collapsing all of a track's clips into one key makes every track cost a
  small, fixed number of ini calls regardless of clip count. }
function PackClips(const AClips: TClipArray): string;
var
  i, Used, Piece: Integer;
  Part: string;
begin
  Result := '';
  Used := 0;
  for i := 0 to High(AClips) do
  begin
    Part := PackClip(AClips[i]);
    Piece := Length(Part);
    if i > 0 then
      Inc(Piece);
    { grow geometrically into a single buffer instead of `Result := Result +
      Part`, which reallocates the whole (by then very long) string on every
      clip of a heavily chopped track }
    if Used + Piece > Length(Result) then
      SetLength(Result, (Used + Piece) * 2 + 64);
    if i > 0 then
    begin
      Inc(Used);
      Result[Used] := ClipDelim;
    end;
    if Length(Part) > 0 then
      Move(Part[1], Result[Used + 1], Length(Part));
    Inc(Used, Length(Part));
  end;
  SetLength(Result, Used);
end;

{ Parses one track's packed text in a single forward pass, allocating only
  the clip array (sized once, up front, from a delimiter count) and one
  marker array per warped clip.

  What this replaces was three nested levels of splitting: the track string
  into per-clip strings, each clip string into its 8 fields, then the marker
  field into pairs and each pair into two numbers - so every character of
  the track was copied into a fresh heap string three or four times over,
  and each split grew its result array one element at a time (a realloc and
  move per clip, on a track that can hold thousands). Reading the digits
  straight out of the original string removes all of it; the two Copy calls
  left are the float fields, kept so their text still round-trips through
  exactly the same StrToFloatDef that wrote them.

  Field scanning stops dead at a clip boundary, so a malformed clip can only
  ever damage itself and never consume the clips after it. }
procedure UnpackClips(const S: string; ATrackID: Integer; out AClips: TClipArray);
var
  L, P, ClipCount, i, MarkerCount, FieldStart: Integer;
  FS: TFormatSettings;
  Markers: TWarpMarkerArray;

  { integer field: reads the digits at P and leaves P on whatever stopped it }
  function ScanInt: Int64;
  var
    Neg: Boolean;
  begin
    Result := 0;
    Neg := False;
    if (P <= L) and ((S[P] = '-') or (S[P] = '+')) then
    begin
      Neg := S[P] = '-';
      Inc(P);
    end;
    while (P <= L) and (S[P] >= '0') and (S[P] <= '9') do
    begin
      Result := Result * 10 + (Ord(S[P]) - Ord('0'));
      Inc(P);
    end;
    if Neg then
      Result := -Result;
  end;

  { step over the rest of the current comma-separated field and its comma }
  procedure NextField;
  begin
    while (P <= L) and (S[P] <> ',') and (S[P] <> ClipDelim) do
      Inc(P);
    if (P <= L) and (S[P] = ',') then
      Inc(P);
  end;

begin
  Markers := nil;
  L := Length(S);
  if L = 0 then
  begin
    SetLength(AClips, 0);
    Exit;
  end;

  ClipCount := 1;
  for i := 1 to L do
    if S[i] = ClipDelim then
      Inc(ClipCount);
  SetLength(AClips, ClipCount);

  FS := PortableFloatSettings;
  P := 1;
  for i := 0 to ClipCount - 1 do
  begin
    { SetLength above zero-filled every element, so anything a short/damaged
      clip never assigns is already 0 (and WarpMarkers already nil) }
    AClips[i].TrackID := ATrackID;

    AClips[i].SampleID := ScanInt; NextField;
    AClips[i].Offset := ScanInt; NextField;
    AClips[i].Length := ScanInt; NextField;
    AClips[i].Position := ScanInt; NextField;

    FieldStart := P;
    while (P <= L) and (S[P] <> ',') and (S[P] <> ClipDelim) do
      Inc(P);
    AClips[i].PitchSemitones := StrToFloatDef(Copy(S, FieldStart, P - FieldStart), 0, FS);
    if (P <= L) and (S[P] = ',') then
      Inc(P);

    FieldStart := P;
    while (P <= L) and (S[P] <> ',') and (S[P] <> ClipDelim) do
      Inc(P);
    AClips[i].Gain := StrToFloatDef(Copy(S, FieldStart, P - FieldStart), 1.0, FS);
    if (P <= L) and (S[P] = ',') then
      Inc(P);

    AClips[i].WarpMode := ScanInt; NextField;

    { markers run to the end of this clip; collected into one buffer that is
      reused across clips and copied out at its final size, so the marker
      count never has to be counted in a separate scan }
    MarkerCount := 0;
    while (P <= L) and (S[P] <> ClipDelim) do
    begin
      if MarkerCount >= Length(Markers) then
        SetLength(Markers, MarkerCount * 2 + 16);
      Markers[MarkerCount].SourceFrame := ScanInt;
      if (P <= L) and (S[P] = MarkerFieldDelim) then
        Inc(P);
      Markers[MarkerCount].TimelineFrame := ScanInt;
      Inc(MarkerCount);
      while (P <= L) and (S[P] <> MarkerDelim) and (S[P] <> ClipDelim) do
        Inc(P);
      if (P <= L) and (S[P] = MarkerDelim) then
        Inc(P);
    end;
    if MarkerCount > 0 then
      AClips[i].WarpMarkers := Copy(Markers, 0, MarkerCount);

    { on to the next clip }
    while (P <= L) and (S[P] <> ClipDelim) do
      Inc(P);
    if P <= L then
      Inc(P);
  end;
end;

{ Where sample i's audio can be read as a file right now, or '' if it can't
  be. The stored path if it still resolves, otherwise the same name inside
  the extracted copy of the standalone bundle this project was opened from -
  which is where it lives after such a project is loaded (see FBundleDir). }
function ResolveSampleSource(AIndex: Integer): string;
begin
  Result := Project.SamplePaths[AIndex];
  if Result = '' then
    Exit;
  if FileExists(Result) then
    Exit;
  { only a bare name can have come out of a bundle, and only that can be
    joined to one - a stale absolute path from some other machine must not
    be turned into a bundle-relative lookup that happens to hit }
  if (FBundleDir <> '') and (ExtractFilePath(Result) = '') then
  begin
    Result := IncludeTrailingPathDelimiter(FBundleDir) + Result;
    if FileExists(Result) then
      Exit;
  end;
  Result := '';
end;

function CopyFileTo(const ASource, ADest: string): Boolean;
var
  Src, Dst: TFileStream;
begin
  Result := False;
  try
    Src := TFileStream.Create(ASource, fmOpenRead or fmShareDenyNone);
    try
      Dst := TFileStream.Create(ADest, fmCreate);
      try
        Dst.CopyFrom(Src, Src.Size);
        Result := True;
      finally
        Dst.Free;
      end;
    finally
      Src.Free;
    end;
  except
    { an unreadable source or a full disk is not fatal to the save - the
      caller falls back to writing the sample out of the pool instead }
    Result := False;
  end;
end;

function SaveProject(const APath: string): Boolean;
var
  Dir, IniPath, Section, Prefix, EmbeddedName, TmpPath, StoredPath: string;
  SourcePath: string;
  Ini: TIniFile;
  t, i, e, j: Integer;
  { .ers rather than .er - see StandaloneProjectExt. Decided once, here, from
    the path being written, so Save and Save As go through exactly the same
    logic and neither needs to ask the user anything. }
  Standalone: Boolean;
  { what each pool slot ended up stored as, so a sample used by two slots is
    copied into the bundle once rather than twice }
  Stored: array of string;
  { the source each of those came from, for that same comparison - two slots
    are the same file only if they resolved to the same place }
  Sources: array of string;
  { every track's packed clip text, kept so the cache written below can be
    stamped with a hash of exactly the text that went into the ini }
  PackedText: array of string;
  Cache: TProjectCacheData;
begin
  Result := False;
  Standalone := IsStandalonePath(APath);

  { build the bundle in a scratch directory, then pack it into a single
    .er tar file - a real file (not a directory) is what makes a standard
    Open dialog able to select it instead of just navigating into it }
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'eris_save_tmp';
  if DirectoryExists(Dir) then
    DeleteDirectory(Dir, False);
  if not ForceDirectories(Dir) then
    Exit;

  IniPath := IncludeTrailingPathDelimiter(Dir) + 'project.ini';

  Ini := TIniFile.Create(IniPath);
  { TIniFile (unlike TMemIniFile) leaves CacheUpdates False by default, which
    means every single Write* call below rewrites the ENTIRE ini file to
    disk immediately (see TIniFile.MaybeUpdateFile/UpdateFile in FPC's
    inifiles.pp) instead of once at the end - for a project with any real
    number of tracks/effects this made save time scale with the SQUARE of
    the file's growing size. Enabling it batches every write in memory and
    flushes once, on Ini.Free below. }
  Ini.CacheUpdates := True;
  try
    Ini.WriteFloat('Project', 'Tempo', Project.TempoBPM);
    Ini.WriteInteger('Project', 'TrackCount', Project.TrackCount);
    Ini.WriteBool('Project', 'SP1200Enabled', AudioEngineGetSP1200Enabled);
    { recorded so a bundle still says what it is after being renamed, and so
      the UI can show it - what the save actually DOES is driven by the
      extension above, not by this key }
    Ini.WriteBool('Project', 'Standalone', Standalone);

    Ini.WriteFloat('Master', 'Volume', Project.MasterVolume);
    Ini.WriteInteger('Master', 'EffectCount', Project.MasterEffectCount);
    for e := 0 to Project.MasterEffectCount - 1 do
      SaveEffect(Ini, 'Master', 'Effect' + IntToStr(e) + '.', Project.MasterEffects[e]);

    { one [SendN] section per send bus, same shape as [Master] plus the
      bus-level controls; the per-track enable/level halves live with their
      own track below }
    for i := 0 to Project.SendCount - 1 do
    begin
      Section := 'Send' + IntToStr(i);
      Ini.WriteFloat(Section, 'ReturnLevel', Project.SendReturnLevel[i]);
      Ini.WriteBool(Section, 'Enabled', Project.SendEnabled[i]);
      Ini.WriteBool(Section, 'PreFader', Project.SendPreFader[i]);
      Ini.WriteInteger(Section, 'EffectCount', Project.SendEffectCount[i]);
      for e := 0 to Project.SendEffectCount[i] - 1 do
        SaveEffect(Ini, Section, 'Effect' + IntToStr(e) + '.', Project.SendEffects[i][e]);
    end;

    Ini.WriteInteger('Samples', 'Count', Length(Project.SamplePool));
    SetLength(Cache.Samples, Length(Project.SamplePool));
    SetLength(Stored, Length(Project.SamplePool));
    SetLength(Sources, Length(Project.SamplePool));
    for i := 0 to High(Project.SamplePool) do
    begin
      { written unconditionally so a sample's display name (e.g. a
        Consolidate-produced clip, always named 'Consolidated') survives a
        save/load round trip - previously this was implied by the source
        filename and got silently replaced with the embedded WAV's bare
        filename ('recorded3.wav') the moment a path-less sample got
        embedded, below. Purely cosmetic - SampleNames is never used as a
        lookup key anywhere, so this has no bearing on the embedding path
        just below staying collision-free (that's keyed by pool index i,
        not by name). }
      Ini.WriteString('Samples', 'Name' + IntToStr(i), Project.SampleNames[i]);

      { A standalone save embeds EVERY sample; a normal one embeds only those
        with no file left to point at. Both end at the same place - a name
        inside this bundle, which LoadProject resolves against the bundle
        before trying it as an absolute path - so the two kinds of project
        differ only in how much they carry, not in format. That is what lets
        a sample added to an .ers today be packed in by the very next save
        with no extra bookkeeping: the decision is re-made per sample, per
        save, from the path being written. }
      SourcePath := ResolveSampleSource(i);
      Sources[i] := SourcePath;

      if (not Standalone) and FileExists(Project.SamplePaths[i]) then
      begin
        { a normal project just references it where it sits }
        StoredPath := Project.SamplePaths[i];
      end
      else if SourcePath <> '' then
      begin
        { copy the file in BYTE FOR BYTE rather than re-encoding it out of
          the pool: the pool is 32-bit float resampled to the engine's rate
          (ResampleToCanonical) and EncodeWav writes 16-bit, so re-encoding a
          24-bit or 96k source would permanently bake a conversion into the
          archive. Copying also skips the encode entirely, and keeps the
          original extension so the right decoder is picked on load. }
        StoredPath := '';
        for j := 0 to i - 1 do
          if (Sources[j] <> '') and (Sources[j] = SourcePath) then
          begin
            { the same file backing two pool slots - one copy, two references }
            StoredPath := Stored[j];
            Break;
          end;
        if StoredPath = '' then
        begin
          EmbeddedName := 'sample' + IntToStr(i) +
            LowerCase(ExtractFileExt(SourcePath));
          if CopyFileTo(SourcePath, IncludeTrailingPathDelimiter(Dir) + EmbeddedName) then
            StoredPath := EmbeddedName;
        end;
      end
      else
        StoredPath := '';

      if StoredPath = '' then
      begin
        { nothing readable to copy - either a recorded clip that was never a
          file at all (SamplePaths is ''), or a source that has since gone
          missing, or a copy that failed. Write the audio the pool is holding
          out as a real WAV instead, so the bundle still carries it rather
          than a path that resolves to nothing. }
        EmbeddedName := 'recorded' + IntToStr(i) + '.wav';
        EncodeWav(IncludeTrailingPathDelimiter(Dir) + EmbeddedName,
          Project.SamplePool[i].Data, Project.SamplePool[i].FrameCount,
          Project.SamplePool[i].Channels, Project.SamplePool[i].SampleRate);
        StoredPath := EmbeddedName;
      end;

      Stored[i] := StoredPath;
      Ini.WriteString('Samples', 'Path' + IntToStr(i), StoredPath);

      { the derived analysis this pool slot already holds, banked for the
        next load - see ProjectCache. Keyed to the same path string the ini
        just got, and fingerprinted against the audio it describes. }
      Cache.Samples[i].StoredPath := StoredPath;
      Cache.Samples[i].FrameCount := Project.SamplePool[i].FrameCount;
      Cache.Samples[i].Channels := Project.SamplePool[i].Channels;
      Cache.Samples[i].SampleRate := Project.SamplePool[i].SampleRate;
      Cache.Samples[i].DataHash := SampleDataFingerprint(Project.SamplePool[i].Data,
        Project.SamplePool[i].FrameCount, Project.SamplePool[i].Channels);
      if i <= High(Project.SamplePeaks) then
        Cache.Samples[i].Peaks := Project.SamplePeaks[i];
      if i <= High(Project.SampleTransients) then
        Cache.Samples[i].Transients := Project.SampleTransients[i];
      if i <= High(Project.SamplePeriods) then
        Cache.Samples[i].PeriodFrames := Project.SamplePeriods[i];
    end;

    SetLength(PackedText, Project.TrackCount);
    SetLength(Cache.Tracks, Project.TrackCount);
    for t := 0 to Project.TrackCount - 1 do
    begin
      Section := 'Track' + IntToStr(t);
      Ini.WriteInteger(Section, 'Instrument', Project.TrackInstrument[t]);
      Ini.WriteInteger(Section, 'Octave', Project.TrackOctave[t]);
      Ini.WriteFloat(Section, 'InstrumentGainDb', Project.TrackInstrumentGainDb[t]);
      Ini.WriteFloat(Section, 'Volume', Project.TrackVolume[t]);
      Ini.WriteFloat(Section, 'Pan', Project.TrackPan[t]);
      Ini.WriteBool(Section, 'Enabled', Project.TrackEnabled[t]);
      Ini.WriteBool(Section, 'Solo', Project.TrackSolo[t]);
      Ini.WriteBool(Section, 'Collapsed', Project.TrackCollapsed[t]);
      Ini.WriteInt64(Section, 'InstrumentStart', Project.TrackInstrumentStart[t]);
      Ini.WriteInt64(Section, 'InstrumentEnd', Project.TrackInstrumentEnd[t]);
      Ini.WriteFloat(Section, 'SwingPercent', Project.TrackSwingPercent[t]);
      Ini.WriteInteger(Section, 'SwingDivision', Project.TrackSwingDivision[t]);
      Ini.WriteBool(Section, 'IsInput', Project.TrackIsInput[t]);
      Ini.WriteBool(Section, 'MonitorEnabled', Project.TrackMonitorEnabled[t]);

      Ini.WriteBool(Section, 'IsSampler', Project.TrackIsSampler[t]);
      if Project.TrackIsSampler[t] then
        for i := 0 to Project.SamplerKeysPerOctave - 1 do
        begin
          Prefix := 'SamplerSlot' + IntToStr(i) + '.';
          Ini.WriteInteger(Section, Prefix + 'SampleID',
            Project.TrackSamplerSlots[t][i].SampleID);
          Ini.WriteInt64(Section, Prefix + 'Start', Project.TrackSamplerSlots[t][i].StartFrame);
          Ini.WriteInt64(Section, Prefix + 'End', Project.TrackSamplerSlots[t][i].EndFrame);
        end;

      Ini.WriteInteger(Section, 'EffectCount', Project.TrackEffectCount[t]);
      for e := 0 to Project.TrackEffectCount[t] - 1 do
        SaveEffect(Ini, Section, 'Effect' + IntToStr(e) + '.', Project.TrackEffects[t][e]);

      for i := 0 to Project.SendCount - 1 do
      begin
        Ini.WriteBool(Section, 'Send' + IntToStr(i) + 'On',
          Project.TrackSendEnabled[t][i]);
        Ini.WriteFloat(Section, 'Send' + IntToStr(i) + 'Level',
          Project.TrackSendLevel[t][i]);
      end;

      { see PackClips' comment - one key holds every clip (and all their warp
        markers) for the track, instead of ~9 keys per clip that made saving
        a heavily-chopped track scale as O(clip-count^2). Still the format of
        record even with the binary cache written below: the cache is only
        believed when its stamp matches this exact text. }
      PackedText[t] := PackClips(Project.Tracks[t].Clips);
      Ini.WriteString(Section, 'ClipsPacked', PackedText[t]);
      Cache.Tracks[t] := Project.Tracks[t].Clips;
    end;

    Result := True;
  finally
    Ini.Free;
  end;

  if not Result then
  begin
    DeleteDirectory(Dir, False);
    Exit;
  end;

  { the load-accelerating sidecar, written into the bundle alongside
    project.ini so CreateTarFromDirectory picks it up like any other file.
    A failure here is deliberately not a failure of the save - the project
    is already fully described by the ini, and a bundle with no (or a
    rejected) cache just loads the slow way. }
  Cache.ClipStamp := ClipTextStamp(PackedText);
  WriteProjectCache(IncludeTrailingPathDelimiter(Dir) + ProjectCacheFileName, Cache);

  { write to a sibling temp file and rename over APath only once the tar is
    confirmed good - renaming on the same filesystem is atomic, so a crash/
    power loss/disk-full mid-write leaves a harmless .tmp behind instead of
    deleting the last good save before its replacement is known to exist }
  TmpPath := APath + '.tmp';
  { qualified because the Windows unit in this unit's uses clause also
    exports a DeleteFile, taking a PChar rather than a string }
  if FileExists(TmpPath) then
    SysUtils.DeleteFile(TmpPath);
  if CreateTarFromDirectory(Dir, TmpPath) then
    Result := ReplaceFile(TmpPath, APath)
  else
  begin
    SysUtils.DeleteFile(TmpPath);
    Result := False;
  end;
  DeleteDirectory(Dir, False);

  { the project in memory is now whichever kind was just written - so Save
    As from .er to .ers makes the open project standalone from here on, and
    the title bar can say so }
  if Result then
    Project.Standalone := Standalone;
end;

{ decode + peak/transient analysis is pure CPU+file-I/O work with no shared
  mutable state (WavDecoder's only global is a read-only decoder table;
  ComputeWaveformPeaks/DetectTransients touch only their own arguments) -
  safe to fan out across threads. Capped via ThreadUtil.WorkerThreadCap
  (hardware threads - 1, floor 2) rather than a fixed count, so a big
  project's sample load actually scales with the machine it's running on. }

type
  TSampleLoadJob = record
    Index: Integer;
    StoredPath, ResolvedPath: string;
    { '' for a project.ini saved before display names were persisted (see
      SaveProject) - Execute below falls back to deriving one from
      StoredPath exactly as it always did, so old projects still load fine }
    DisplayName: string;
    { this slot's entry from the bundle's cache.bin, already matched by path
      (see LoadProject) but NOT yet by content - Execute below fingerprints
      what it actually decoded before believing any of it. False on a bundle
      with no cache, i.e. anything saved by an older build, in which case
      the three analysis passes run exactly as they always did. }
    HasCache: Boolean;
    CacheFrameCount, CacheChannels, CacheSampleRate: Integer;
    CacheDataHash: QWord;
    CachePeriodFrames: Integer;
    CachePeaks: TWaveformPeaks;
    CacheTransients: TFrameArray;
  end;
  TSampleLoadJobArray = array of TSampleLoadJob;

  { Every thread sees the WHOLE job list and claims work from it one index at
    a time through a shared atomic cursor, rather than being handed a fixed
    slice up front. Each index is still claimed by exactly one thread, so the
    no-locking argument for writing Project.SamplePool[i] etc. is unchanged -
    what changes is WHICH thread gets which job, and that it is decided when
    the thread is free rather than before any file has been opened.

    Static slicing is what this replaced, and it splits by job COUNT while the
    cost is dominated by job SIZE. A real project's samples span three orders
    of magnitude (a 4KB one-shot next to a 2MB recorded take), so the fixed
    slices are wildly unequal in work: one thread draws the four big takes,
    finishes long after the rest, and since LoadSamplesThreaded cannot return
    until every WaitFor returns, that one straggler IS the load time while ten
    cores sit idle. Pulling from a cursor self-balances - a thread that drew a
    big file simply claims fewer of them. }
  TSampleLoadThread = class(TThread)
  private
    { shared with every other worker and with the caller; read-only here }
    FJobs: TSampleLoadJobArray;
    FCursor: PLongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(const AJobs: TSampleLoadJobArray; ACursor: PLongInt);
  end;

constructor TSampleLoadThread.Create(const AJobs: TSampleLoadJobArray;
  ACursor: PLongInt);
begin
  { fields are set BEFORE calling the inherited constructor, which starts
    the thread immediately (CreateSuspended=False) - Execute only ever
    sees a fully-populated FJobs. Matches AudioEngine.TPlaybackThread, the
    only other TThread in this codebase: suspended creation (Create(True)
    + a later .Start) hung indefinitely here - FPC's suspended-thread
    emulation on Linux/cthreads never actually resumed, so WaitFor blocked
    the GUI thread forever on every project open. }
  { a reference to the caller's array, not a copy - it is never written after
    this point, and the refcount is taken here on the CALLER's thread, before
    the thread below can possibly run }
  FJobs := AJobs;
  FCursor := ACursor;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TSampleLoadThread.Execute;
var
  i, Idx: Integer;
  Sample, EmptySample: TSample;
  CacheHit: Boolean;
begin
  FillChar(EmptySample, SizeOf(EmptySample), 0);
  while True do
  begin
    { claim the next job; InterlockedIncrement returns the POST-increment
      value, so subtracting one gives the index this thread just took and no
      other thread can take }
    i := InterlockedIncrement(FCursor^) - 1;
    if i > High(FJobs) then
      Break;

    Idx := FJobs[i].Index;
    if DecodeSampleFile(FJobs[i].ResolvedPath, Sample) then
    begin
      Project.SamplePool[Idx] := Sample;
      if FJobs[i].DisplayName <> '' then
        Project.SampleNames[Idx] := FJobs[i].DisplayName
      else
        Project.SampleNames[Idx] := ExtractFileName(FJobs[i].StoredPath);
    end
    else
    begin
      Project.SamplePool[Idx] := EmptySample;
      Project.SampleNames[Idx] := '(missing: ' + ExtractFileName(FJobs[i].StoredPath) + ')';
    end;
    Project.SamplePaths[Idx] := FJobs[i].StoredPath;

    { Peaks, transients and the fundamental period are three more passes over
      the audio on top of decoding it - together several times the cost of
      the decode, and DetectFundamentalPeriod's autocorrelation is the worst
      of them - yet all three are pure functions of the sample data. If the
      bundle banked them at save time and the audio still fingerprints the
      same, take them and skip all three. A stale entry (an external sample
      edited since the save) fails the fingerprint and just falls through to
      computing them. }
    CacheHit := False;
    if FJobs[i].HasCache and (Project.SamplePool[Idx].Data <> nil) and
      (Project.SamplePool[Idx].FrameCount = FJobs[i].CacheFrameCount) and
      (Project.SamplePool[Idx].Channels = FJobs[i].CacheChannels) and
      (Project.SamplePool[Idx].SampleRate = FJobs[i].CacheSampleRate) then
      CacheHit := SampleDataFingerprint(Project.SamplePool[Idx].Data,
        Project.SamplePool[Idx].FrameCount, Project.SamplePool[Idx].Channels) =
        FJobs[i].CacheDataHash;

    if CacheHit then
    begin
      { plain dynamic-array assignments: the cache arrays are never written
        after LoadProject built them, and FPC refcounts them atomically, so
        several workers taking a reference at once is safe }
      Project.SamplePeaks[Idx] := FJobs[i].CachePeaks;
      Project.SampleTransients[Idx] := FJobs[i].CacheTransients;
      Project.SamplePeriods[Idx] := FJobs[i].CachePeriodFrames;
    end
    else
    begin
      { mirrors Project.AddSampleToPool exactly - analyze whatever ended up
        in the pool slot, real or empty }
      Project.SamplePeaks[Idx] := ComputeWaveformPeaks(Project.SamplePool[Idx]);
      Project.SampleTransients[Idx] := DetectTransients(Project.SamplePool[Idx].Data,
        Project.SamplePool[Idx].FrameCount, Project.SamplePool[Idx].Channels,
        Project.SamplePool[Idx].SampleRate);
      Project.SamplePeriods[Idx] := DetectFundamentalPeriod(Project.SamplePool[Idx].Data,
        Project.SamplePool[Idx].FrameCount, Project.SamplePool[Idx].Channels,
        Project.SamplePool[Idx].SampleRate);
    end;
  end;
end;

{ Decodes every sample referenced by the project in parallel. Project.
  SamplePool/SampleNames/SamplePaths/SamplePeaks/SampleTransients must
  already be sized to Length(AJobs) - each job's Index is its slot in
  those arrays - before this is called. }
procedure LoadSamplesThreaded(const AJobs: TSampleLoadJobArray);
var
  ThreadCount, w: Integer;
  { the shared claim counter - a local is safe because every thread that can
    reach it is joined below before this procedure returns }
  Cursor: LongInt;
  Threads: array of TSampleLoadThread;
begin
  if Length(AJobs) = 0 then
    Exit;

  ThreadCount := Length(AJobs);
  if ThreadCount > ThreadUtil.WorkerThreadCap then
    ThreadCount := ThreadUtil.WorkerThreadCap;

  Cursor := 0;
  SetLength(Threads, ThreadCount);

  { each thread starts running as soon as it's constructed (Create(False) -
    see the constructor's comment) - no separate Start pass needed. Threads
    created earlier begin claiming jobs while the later ones are still being
    constructed, which is harmless: the cursor is the only thing handing work
    out. }
  for w := 0 to ThreadCount - 1 do
    Threads[w] := TSampleLoadThread.Create(AJobs, @Cursor);

  for w := 0 to ThreadCount - 1 do
  begin
    Threads[w].WaitFor;
    Threads[w].Free;
  end;
end;

function LoadProject(const APath: string): Boolean;
const
  { a value ClipsPacked can never legitimately hold, so one ReadString
    answers both "is the key there" and "what does it say" - ValueExists
    plus ReadString is two linear scans of the same section }
  NoPackedKey = #1;
var
  Dir, IniPath, Section, Prefix, StoredPath, ResolvedPath: string;
  Ini: TIniFile;
  t, i, m, e, SampleCount, ClipCount, MarkerCount: Integer;
  Clip: TClip;
  SampleJobs: TSampleLoadJobArray;
  Cache: TProjectCacheData;
  HaveCache, UseCachedClips, AllTracksPacked: Boolean;
  { whether the bundle being read is a standalone one, and so whether the
    unpacked copy of it below is kept alive after this returns }
  Standalone, Unpacked: Boolean;
  KeepDir: string;
  { each track's ClipsPacked text, parsed after the track loop so the cache's
    stamp can be checked against all of it first }
  PackedText: array of string;
begin
  Result := False;

  { scratch only, and deliberately NOT the directory a standalone project's
    unpacked copy ends up living in (that gets its own name below) - so
    wiping it here can never destroy the audio backing a project that is
    already open, however this load then goes }
  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'eris_load_tmp';
  if DirectoryExists(Dir) then
    DeleteDirectory(Dir, False);

  Unpacked := False;
  if DirectoryExists(APath) then
    { backward compatible with older projects saved as a loose directory
      bundle rather than a packed .er tar file }
    Dir := ExcludeTrailingPathDelimiter(APath)
  else if FileExists(APath) then
  begin
    if not ExtractTarToDirectory(APath, Dir) then
      Exit;
    Unpacked := True;
  end
  else
    Exit;

  IniPath := IncludeTrailingPathDelimiter(Dir) + 'project.ini';
  if not FileExists(IniPath) then
    Exit;

  Project.NewProject;

  { optional, and absent from every bundle saved before it existed - see
    ProjectCache. Read before anything uses it; a False here just means
    every sample gets analyzed and every clip parsed the long way. }
  HaveCache := ReadProjectCache(IncludeTrailingPathDelimiter(Dir) +
    ProjectCacheFileName, Cache);

  Ini := TIniFile.Create(IniPath);
  try
    Project.TempoBPM := Ini.ReadFloat('Project', 'Tempo', Project.DefaultTempoBPM);
    Project.TrackCount := Ini.ReadInteger('Project', 'TrackCount', Project.DefaultTrackCount);
    if Project.TrackCount < 1 then
      Project.TrackCount := 1
    else if Project.TrackCount > Project.MaxTracks then
      Project.TrackCount := Project.MaxTracks;
    AudioEngineSetSP1200Enabled(Ini.ReadBool('Project', 'SP1200Enabled', False));

    { the key is what a standalone bundle says about itself; the extension is
      the fallback for one that predates the key or was renamed. Either way
      this only decides whether the unpacked copy is KEPT below - the samples
      load from wherever their stored paths resolve regardless, which is why
      both kinds of project open through this one path with nothing special
      about either. }
    Standalone := Ini.ReadBool('Project', 'Standalone', IsStandalonePath(APath));
    Project.Standalone := Standalone;

    { absent in projects written before the master fader existed - those load
      at unity, the gain at which it multiplies by exactly 1.0 and so cannot
      change how they sound }
    Project.MasterVolume := Ini.ReadFloat('Master', 'Volume', 1.0);
    Project.MasterEffectCount := Ini.ReadInteger('Master', 'EffectCount', 0);
    if Project.MasterEffectCount > Effects.MaxEffectsPerTrack then
      Project.MasterEffectCount := Effects.MaxEffectsPerTrack;
    for e := 0 to Project.MasterEffectCount - 1 do
      Project.MasterEffects[e] := LoadEffect(Ini, 'Master', 'Effect' + IntToStr(e) + '.');

    { defaults here mirror Project.InitSendBuses, so a project saved before
      sends existed loads with two empty, unity, unmuted buses rather than
      with muted ones at zero return }
    for i := 0 to Project.SendCount - 1 do
    begin
      Section := 'Send' + IntToStr(i);
      Project.SendReturnLevel[i] := Ini.ReadFloat(Section, 'ReturnLevel', 1.0);
      Project.SendEnabled[i] := Ini.ReadBool(Section, 'Enabled', True);
      Project.SendPreFader[i] := Ini.ReadBool(Section, 'PreFader', False);
      Project.SendEffectCount[i] := Ini.ReadInteger(Section, 'EffectCount', 0);
      if Project.SendEffectCount[i] > Effects.MaxEffectsPerTrack then
        Project.SendEffectCount[i] := Effects.MaxEffectsPerTrack;
      for e := 0 to Project.SendEffectCount[i] - 1 do
        Project.SendEffects[i][e] := LoadEffect(Ini, Section, 'Effect' + IntToStr(e) + '.');
    end;

    SampleCount := Ini.ReadInteger('Samples', 'Count', 0);

    { The outgoing project's audio is raw GetMem'd blocks hanging off
      TSample.Data - SetLength below drops the TSample records but cannot know
      to free what they point at, so without this every Open leaked the whole
      previous project's sample memory for the rest of the session. Safe to do
      here: the caller (FileOpenClick) has already stopped the transport and
      spun until AudioEngineIsBusy went false, which is exactly the protocol
      NewProject uses before its own identical free loop. }
    for i := 0 to High(Project.SamplePool) do
      if Project.SamplePool[i].Data <> nil then
        FreeMem(Project.SamplePool[i].Data);

    { pre-size every output array once, up front, so the worker threads can
      write to their own disjoint indices with no locking and no risk of a
      concurrent SetLength reallocating out from under another thread }
    SetLength(Project.SamplePool, SampleCount);
    SetLength(Project.SampleNames, SampleCount);
    SetLength(Project.SamplePaths, SampleCount);
    SetLength(Project.SamplePeaks, SampleCount);
    SetLength(Project.SampleTransients, SampleCount);
    SetLength(Project.SamplePeriods, SampleCount);

    SetLength(SampleJobs, SampleCount);
    for i := 0 to SampleCount - 1 do
    begin
      StoredPath := Ini.ReadString('Samples', 'Path' + IntToStr(i), '');

      { resolve relative to the .er directory first, falling back to absolute }
      ResolvedPath := IncludeTrailingPathDelimiter(Dir) + StoredPath;
      if not FileExists(ResolvedPath) then
        ResolvedPath := StoredPath;

      SampleJobs[i].Index := i;
      SampleJobs[i].StoredPath := StoredPath;
      SampleJobs[i].ResolvedPath := ResolvedPath;
      { '' (default) for a pre-existing project.ini that never wrote this
        key - TSampleLoadThread.Execute falls back to the old
        derive-from-filename behavior in that case }
      SampleJobs[i].DisplayName := Ini.ReadString('Samples', 'Name' + IntToStr(i), '');

      { hand this slot its banked analysis if the cache has an entry for the
        same pool index AND the same path string - a pool that has been
        reordered or repointed since the cache was written therefore can't
        hand slot i the analysis of some other sample. The audio itself is
        checked in the worker, once it has actually been decoded. }
      if HaveCache and (i <= High(Cache.Samples)) and
        (Cache.Samples[i].StoredPath = StoredPath) and
        (Cache.Samples[i].FrameCount > 0) then
      begin
        SampleJobs[i].HasCache := True;
        SampleJobs[i].CacheFrameCount := Cache.Samples[i].FrameCount;
        SampleJobs[i].CacheChannels := Cache.Samples[i].Channels;
        SampleJobs[i].CacheSampleRate := Cache.Samples[i].SampleRate;
        SampleJobs[i].CacheDataHash := Cache.Samples[i].DataHash;
        SampleJobs[i].CachePeriodFrames := Cache.Samples[i].PeriodFrames;
        SampleJobs[i].CachePeaks := Cache.Samples[i].Peaks;
        SampleJobs[i].CacheTransients := Cache.Samples[i].Transients;
      end;
    end;

    LoadSamplesThreaded(SampleJobs);

    SetLength(PackedText, Project.TrackCount);
    AllTracksPacked := True;
    for t := 0 to Project.TrackCount - 1 do
    begin
      Section := 'Track' + IntToStr(t);
      Project.TrackInstrument[t] := Ini.ReadInteger(Section, 'Instrument', -1);
      Project.TrackOctave[t] := Ini.ReadInteger(Section, 'Octave', 0);
      Project.TrackInstrumentGainDb[t] := Ini.ReadFloat(Section, 'InstrumentGainDb', 0);
      Project.TrackVolume[t] := Ini.ReadFloat(Section, 'Volume', 1.0);
      { absent in projects written before pan existed - those load centred,
        which is the position at which pan multiplies by exactly 1.0 and so
        changes nothing about how they sound }
      Project.TrackPan[t] := Ini.ReadFloat(Section, 'Pan', 0.0);
      Project.TrackEnabled[t] := Ini.ReadBool(Section, 'Enabled', True);
      { absent in projects written before solo existed - those load unsoloed,
        which is the state in which solo changes nothing }
      Project.TrackSolo[t] := Ini.ReadBool(Section, 'Solo', False);
      { how the track is drawn, not how it sounds - absent in projects written
        before collapsing existed, and those load fully expanded }
      Project.TrackCollapsed[t] := Ini.ReadBool(Section, 'Collapsed', False);
      Project.TrackSwingPercent[t] := Ini.ReadFloat(Section, 'SwingPercent', 50);
      Project.TrackSwingDivision[t] := Ini.ReadInteger(Section, 'SwingDivision', 16);
      Project.TrackIsInput[t] := Ini.ReadBool(Section, 'IsInput', False);
      Project.TrackMonitorEnabled[t] := Ini.ReadBool(Section, 'MonitorEnabled', False);

      Project.TrackIsSampler[t] := Ini.ReadBool(Section, 'IsSampler', False);
      if Project.TrackIsSampler[t] then
        for i := 0 to Project.SamplerKeysPerOctave - 1 do
        begin
          Prefix := 'SamplerSlot' + IntToStr(i) + '.';
          Project.TrackSamplerSlots[t][i].SampleID :=
            Ini.ReadInteger(Section, Prefix + 'SampleID', -1);
          Project.TrackSamplerSlots[t][i].StartFrame :=
            Ini.ReadInt64(Section, Prefix + 'Start', 0);
          Project.TrackSamplerSlots[t][i].EndFrame :=
            Ini.ReadInt64(Section, Prefix + 'End', 0);
          if (Project.TrackSamplerSlots[t][i].SampleID < 0) or
            (Project.TrackSamplerSlots[t][i].SampleID > High(Project.SamplePool)) then
            Project.TrackSamplerSlots[t][i].SampleID := -1;
        end;

      Project.TrackInstrumentStart[t] := Ini.ReadInt64(Section, 'InstrumentStart', 0);
      if (Project.TrackInstrument[t] >= 0) and
        (Project.TrackInstrument[t] <= High(Project.SamplePool)) then
        Project.TrackInstrumentEnd[t] := Ini.ReadInt64(Section, 'InstrumentEnd',
          Project.SamplePool[Project.TrackInstrument[t]].FrameCount)
      else
        Project.TrackInstrumentEnd[t] := Ini.ReadInt64(Section, 'InstrumentEnd', 0);

      Project.TrackEffectCount[t] := Ini.ReadInteger(Section, 'EffectCount', 0);
      if Project.TrackEffectCount[t] > Effects.MaxEffectsPerTrack then
        Project.TrackEffectCount[t] := Effects.MaxEffectsPerTrack;
      for e := 0 to Project.TrackEffectCount[t] - 1 do
        Project.TrackEffects[t][e] := LoadEffect(Ini, Section, 'Effect' + IntToStr(e) + '.');

      for i := 0 to Project.SendCount - 1 do
      begin
        Project.TrackSendEnabled[t][i] :=
          Ini.ReadBool(Section, 'Send' + IntToStr(i) + 'On', False);
        Project.TrackSendLevel[t][i] :=
          Ini.ReadFloat(Section, 'Send' + IntToStr(i) + 'Level', 0.5);
      end;

      { current format - see PackClips/SaveProject. Read but NOT parsed here:
        the cache checked after this loop may make parsing it unnecessary,
        and its text is what that check is against. }
      PackedText[t] := Ini.ReadString(Section, 'ClipsPacked', NoPackedKey);
      if PackedText[t] = NoPackedKey then
      begin
        PackedText[t] := '';
        AllTracksPacked := False;

        { backward compatibility: a project.ini saved before clips were
          packed into one key stores one flat Clip<N>.* key (plus 2 more per
          warp marker) per clip instead - keep parsing that layout so those
          old projects still load correctly. Re-saving a project loaded this
          way writes the new packed format only (SaveProject no longer
          writes these flat keys at all), so this branch only ever fires on
          a project untouched since before this change. }
        ClipCount := Ini.ReadInteger(Section, 'ClipCount', 0);
        for i := 0 to ClipCount - 1 do
        begin
          Prefix := 'Clip' + IntToStr(i) + '.';
          Clip.SampleID := Ini.ReadInteger(Section, Prefix + 'SampleID', -1);
          Clip.Offset := Ini.ReadInt64(Section, Prefix + 'Offset', 0);
          Clip.Length := Ini.ReadInt64(Section, Prefix + 'Length', 0);
          Clip.Position := Ini.ReadInt64(Section, Prefix + 'Position', 0);
          Clip.TrackID := t;
          Clip.PitchSemitones := Ini.ReadFloat(Section, Prefix + 'Pitch', 0);
          Clip.Gain := Ini.ReadFloat(Section, Prefix + 'Gain', 1.0);
          Clip.WarpMode := Ini.ReadInteger(Section, Prefix + 'WarpMode', SampleTypes.WarpModeBeats);

          MarkerCount := Ini.ReadInteger(Section, Prefix + 'MarkerCount', 0);
          SetLength(Clip.WarpMarkers, MarkerCount);
          for m := 0 to MarkerCount - 1 do
          begin
            Clip.WarpMarkers[m].SourceFrame := Ini.ReadInt64(Section,
              Prefix + 'Marker' + IntToStr(m) + '.Source', 0);
            Clip.WarpMarkers[m].TimelineFrame := Ini.ReadInt64(Section,
              Prefix + 'Marker' + IntToStr(m) + '.Timeline', 0);
          end;

          SetLength(Project.Tracks[t].Clips, Length(Project.Tracks[t].Clips) + 1);
          Project.Tracks[t].Clips[High(Project.Tracks[t].Clips)] := Clip;
        end;
      end;
    end;

    { The cache's clip block is only believed when its stamp still matches
      the ini text that was just read - so an externally edited (or older,
      or partly flat-format) project.ini always wins over it, and the binary
      block can never be a second, silently diverging copy of the
      arrangement. When it does match, the whole text parse is skipped. }
    UseCachedClips := HaveCache and AllTracksPacked and
      (Length(Cache.Tracks) = Project.TrackCount) and
      (Cache.ClipStamp = ClipTextStamp(PackedText));

    for t := 0 to Project.TrackCount - 1 do
      if UseCachedClips then
        Project.Tracks[t].Clips := Cache.Tracks[t]
      else if PackedText[t] <> '' then
        { '' covers both "the track really has no clips" and "this track came
          from the flat legacy layout above, which already filled it in" -
          neither wants the parser, and the second must not be overwritten }
        UnpackClips(PackedText[t], t, Project.Tracks[t].Clips);

    Result := True;
  finally
    Ini.Free;
  end;

  { Whatever project was open is gone, so the unpacked copy held for ITS sake
    must go too - and must go before the new one is kept, because a bundle's
    samples are stored under bare names: leaving the old directory in place
    would let a bare name belonging to this project resolve inside the
    previous project's bundle and pick up the wrong audio entirely.
    Deliberately not done on the failure paths above, which leave the open
    project untouched and so must leave its bundle alone as well. }
  if Result then
    ReleaseBundleDir;

  if not Unpacked then
    { loaded in place from a loose directory - no scratch copy to keep or
      delete, and its samples are already where they'll be at save time }
    Exit;

  { A standalone project's samples exist ONLY inside the bundle, so throwing
    the unpacked copy away here would leave the pool's paths resolving
    nowhere - see FBundleDir for what that would cost the next save. }
  if Result and Standalone then
  begin
    KeepDir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
      'eris_bundle_' + IntToStr(GetProcessID);
    if DirectoryExists(KeepDir) then
      DeleteDirectory(KeepDir, False);
    { a rename within one filesystem, not a copy of every sample. Moving it
      off the fixed scratch name is the whole point: that name is wiped at
      the START of every load, including one that then fails and leaves this
      project open. If the rename somehow fails, the scratch name still
      holds the right files, so keep it rather than lose the audio. }
    if RenameFile(Dir, KeepDir) then
      FBundleDir := KeepDir
    else
      FBundleDir := Dir;
  end
  else
    DeleteDirectory(Dir, False);
end;

{ Renders the whole arrangement to a 16-bit WAV.

  BLOCK-MAJOR: the timeline is walked in RenderBlockFrames-frame chunks, and
  every stage runs over one chunk before the next stage sees it - the same
  shape AudioEngine.FillBlock has. It used to be whole-timeline-major, giving
  every track, every send bus and the master a float buffer as long as the
  entire project; see the block-size constant and the memory note below.

  The pass ORDER within a block is exactly the pass order the whole-timeline
  version used across the project, which is what makes the output identical
  rather than merely equivalent - see SidechainLevelFor for the one place
  that could have gone wrong. }
function RenderProjectToWav(const AOutputPath: string): Boolean;
const
  OutChannels = 2;
  { Frames rendered per pass. Nothing about the audio depends on this number:
    every stage is either same-frame (the fader, the send taps, the sums, the
    clip reads) or a sequential state machine carried across blocks (the
    effect chains, the SP-1200). It only trades per-block loop overhead
    against scratch memory, and at this size the scratch is ~1MB total for a
    32-track project of ANY length. }
  RenderBlockFrames = 4096;
var
  ProjectLengthFrames: Int64;
  t, i: Integer;
  Clip: TClip;
  Sample: TSample;
  MasterBuf: PSingle;
  TrackBuffers: array[0..Project.MaxTracks - 1] of PSingle;
  { On the heap, not the stack, and indexed exactly as the fixed arrays they
    replaced were. TEffectState is 3.5KB, so at MaxTracks x
    MaxEffectsPerTrack these three are ~2.9MB between them - fine as an
    allocation, not fine as one stack frame on the render thread. }
  TrackEffectState: array of array of Effects.TEffectState;
  Frame, OutIdx, SampleIdx: Int64;
  SP1200St: TSP1200State;
  MasterEffectState: array of Effects.TEffectState;
  L, R, MonoSample: Single;
  e, sIdx: Integer;
  RenderBeatFrames, SwungPos: Int64;
  { send buses, mirroring AudioEngine.FillBlock's SendL/SendR accumulators -
    one scratch buffer per bus, now one BLOCK long rather than one timeline
    long, refilled every block }
  SendBuffers: array[0..Project.SendCount - 1] of PSingle;
  SendEffectState: array of array of Effects.TEffectState;
  SendAmount, PreFaderL, PreFaderR, TrackVol, TrackPanL, TrackPanR: Single;
  BlockStart, BlockLen, FirstAbs, LastAbs, AbsFrame, ClipFrame: Int64;
  W: TWavWriter;
  WavStarted: Boolean;
  { the whole render is one instant as far as solo is concerned - it can't be
    toggled while it runs - so this is read once and every track gate below
    goes through Project.TrackAudible with it }
  SoloActive: Boolean;

  { Offline equivalent of AudioEngine.FillBlock's SidechainLevelFor - reads
    straight off the source track's buffer at the current frame rather than
    realtime's post-FX/one-frame-stale TrackTapLevel; a deliberate,
    documented approximation (matching this codebase's existing tolerance for
    that exact class of gap).

    ALocalFrame is an index into the current block, not the timeline - that
    is the only thing about this that the block-major rework changed. What it
    reads is unchanged, and that is worth being precise about, because it is
    the one place where blocking the render could have altered the output.
    The source track's buffer is mutated in place by the pass below, so what
    this sees depends on where the source sits in track order: a
    LOWER-numbered source has already been through its inserts and its fader
    and reads post-FX, a HIGHER-numbered one has only been through the clip
    pass and reads pre-FX, and the track itself reads pre-FX because the
    frame is not written back until its whole chain has run. Since pass 1
    completes for every track before pass 2 begins, that relationship holds
    within a block exactly as it held across the timeline, and every read is
    same-frame - there is no lookahead or lookbehind that a block boundary
    could truncate. }
  function SidechainLevelFor(ASourceTrack: Integer; ALocalFrame: Int64): Single;
  var
    SL, SR: Single;
  begin
    if (ASourceTrack < 0) or (ASourceTrack >= Project.MaxTracks) or
      (TrackBuffers[ASourceTrack] = nil) then
      Result := 0
    else
    begin
      SL := Abs(TrackBuffers[ASourceTrack][ALocalFrame * OutChannels]);
      SR := Abs(TrackBuffers[ASourceTrack][ALocalFrame * OutChannels + 1]);
      if SL > SR then Result := SL else Result := SR;
    end;
  end;

begin
  Result := False;
  SoloActive := Project.AnyTrackSoloed;
  RenderBeatFrames := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM);
  ProjectLengthFrames := 0;
  for t := 0 to Project.TrackCount - 1 do
  begin
    if not Project.TrackAudible(t, SoloActive) then
      Continue;
    for i := 0 to High(Project.Tracks[t].Clips) do
    begin
      Clip := Project.Tracks[t].Clips[i];
      SwungPos := AudioEngine.SwungPosition(Clip.Position,
        Project.TrackSwingPercent[t], Project.TrackSwingDivision[t], RenderBeatFrames);
      if SwungPos + Clip.Length > ProjectLengthFrames then
        ProjectLengthFrames := SwungPos + Clip.Length;
    end;
  end;

  if ProjectLengthFrames <= 0 then
    Exit;

  MasterBuf := nil;
  WavStarted := False;
  FillChar(TrackBuffers, SizeOf(TrackBuffers), 0);
  FillChar(SendBuffers, SizeOf(SendBuffers), 0);
  try
    { fixed scratch, sized by the block and not by the project }
    GetMem(MasterBuf, RenderBlockFrames * OutChannels * SizeOf(Single));
    for sIdx := 0 to Project.SendCount - 1 do
      if Project.SendEnabled[sIdx] then
        GetMem(SendBuffers[sIdx], RenderBlockFrames * OutChannels * SizeOf(Single));
    for t := 0 to Project.TrackCount - 1 do
      if Project.TrackAudible(t, SoloActive) then
        GetMem(TrackBuffers[t], RenderBlockFrames * OutChannels * SizeOf(Single));

    SetLength(TrackEffectState, Project.MaxTracks, Effects.MaxEffectsPerTrack);
    SetLength(SendEffectState, Project.SendCount, Effects.MaxEffectsPerTrack);
    SetLength(MasterEffectState, Effects.MaxEffectsPerTrack);

    { Every chain's state is reset ONCE, here, and then carried across every
      block - which is what the whole-timeline version got for free by making
      a single pass down each track. Resetting inside the block loop would
      restart every filter, envelope follower and reverb tail eleven times a
      second and the bounce would be nothing like the playback. }
    for t := 0 to Project.MaxTracks - 1 do
      for e := 0 to Effects.MaxEffectsPerTrack - 1 do
        Effects.EffectStateReset(TrackEffectState[t][e]);
    for sIdx := 0 to Project.SendCount - 1 do
      for e := 0 to Effects.MaxEffectsPerTrack - 1 do
        Effects.EffectStateReset(SendEffectState[sIdx][e]);
    for e := 0 to Effects.MaxEffectsPerTrack - 1 do
      Effects.EffectStateReset(MasterEffectState[e]);
    if AudioEngineGetSP1200Enabled then
      SP1200Reset(SP1200St);

    { the length is known before a single frame is rendered, so the header
      goes out correct up front and the audio can stream straight past it }
    if not WavWriteBegin(W, AOutputPath, ProjectLengthFrames, OutChannels,
      ProjectSampleRate) then
      Exit;
    WavStarted := True;

    BlockStart := 0;
    while BlockStart < ProjectLengthFrames do
    begin
      BlockLen := ProjectLengthFrames - BlockStart;
      if BlockLen > RenderBlockFrames then
        BlockLen := RenderBlockFrames;

      { ---------- pass 1: clips into each track's own scratch ----------
        Runs for EVERY track before pass 2 touches any of them, so that a
        sidechain reading a higher-numbered track still finds that track's
        raw pre-FX audio, exactly as it did when this was whole-timeline. }
      for t := 0 to Project.TrackCount - 1 do
      begin
        if not Project.TrackAudible(t, SoloActive) then
          Continue;

        FillChar(TrackBuffers[t]^, BlockLen * OutChannels * SizeOf(Single), 0);

        for i := 0 to High(Project.Tracks[t].Clips) do
        begin
          Clip := Project.Tracks[t].Clips[i];
          Sample := Project.SamplePool[Clip.SampleID];
          SwungPos := AudioEngine.SwungPosition(Clip.Position,
            Project.TrackSwingPercent[t], Project.TrackSwingDivision[t], RenderBeatFrames);

          { The clip's span on the timeline, intersected with this block. The
            whole-timeline version walked the clip's own frames 0..Length-1
            and wrote at SwungPos + Frame; this walks the block's frames and
            recovers the same clip-relative index, so DetunedSample is handed
            identical arguments and returns identical values.

            Intersecting also clamps the low end at the block start, and so
            at 0 - the old form indexed the output at (SwungPos + Frame),
            which for a negative SwungPos wrote off the front of the buffer.
            Unreachable for any project whose swing leaves clips at or after
            zero, which is why it never showed up. }
          FirstAbs := SwungPos;
          if FirstAbs < BlockStart then
            FirstAbs := BlockStart;
          LastAbs := SwungPos + Clip.Length;
          if LastAbs > BlockStart + BlockLen then
            LastAbs := BlockStart + BlockLen;

          AbsFrame := FirstAbs;
          while AbsFrame < LastAbs do
          begin
            ClipFrame := AbsFrame - SwungPos;
            OutIdx := (AbsFrame - BlockStart) * OutChannels;

            { transients passed through (absolute file positions; translated
              clip-relative inside the warp lookup via Clip.Offset) so a bounce
              uses the same transient-bounded Beats grains as live playback -
              omitting them silently fell back to the fixed ~120ms grid,
              making bounces audibly diverge from what was heard live }
            if Sample.Channels = 1 then
            begin
              { ONE call, fanned out to both outputs - mirrors the identical
                fix in AudioEngine.FillBlock's mono branch (see there). The two
                calls this replaced took the same arguments, channel 0 included,
                so the whole warp/interpolation ran twice per frame to produce
                one number. }
              MonoSample := DetunedSample(Clip.WarpMarkers, ClipFrame,
                Clip.PitchSemitones, Clip.Offset, Sample.Data, Sample.FrameCount,
                Sample.Channels, AudioEngine.ProjectSampleRate, Clip.WarpMode, 0,
                Clip.Length, Project.SampleTransients[Clip.SampleID],
                Project.SamplePeriods[Clip.SampleID]) * Clip.Gain;
              TrackBuffers[t][OutIdx] := TrackBuffers[t][OutIdx] + MonoSample;
              TrackBuffers[t][OutIdx + 1] := TrackBuffers[t][OutIdx + 1] + MonoSample;
            end
            else
            begin
              TrackBuffers[t][OutIdx] := TrackBuffers[t][OutIdx] +
                DetunedSample(Clip.WarpMarkers, ClipFrame, Clip.PitchSemitones, Clip.Offset,
                  Sample.Data, Sample.FrameCount, Sample.Channels,
                  AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
                  Project.SampleTransients[Clip.SampleID],
                    Project.SamplePeriods[Clip.SampleID]) * Clip.Gain;
              TrackBuffers[t][OutIdx + 1] := TrackBuffers[t][OutIdx + 1] +
                DetunedSample(Clip.WarpMarkers, ClipFrame, Clip.PitchSemitones, Clip.Offset,
                  Sample.Data, Sample.FrameCount, Sample.Channels,
                  AudioEngine.ProjectSampleRate, Clip.WarpMode, 1, Clip.Length,
                  Project.SampleTransients[Clip.SampleID],
                    Project.SamplePeriods[Clip.SampleID]) * Clip.Gain;
            end;

            Inc(AbsFrame);
          end;
        end;
      end;

      { ---------- pass 2: per-track inserts, fader, send taps, sum ----------
        the same order FillBlock uses, so a bounce matches what was heard }
      FillChar(MasterBuf^, BlockLen * OutChannels * SizeOf(Single), 0);
      for sIdx := 0 to Project.SendCount - 1 do
        if SendBuffers[sIdx] <> nil then
          FillChar(SendBuffers[sIdx]^, BlockLen * OutChannels * SizeOf(Single), 0);

      for t := 0 to Project.TrackCount - 1 do
      begin
        if not Project.TrackAudible(t, SoloActive) then
          Continue;

        if Project.TrackEffectCount[t] > 0 then
          for Frame := 0 to BlockLen - 1 do
          begin
            L := TrackBuffers[t][Frame * OutChannels];
            R := TrackBuffers[t][Frame * OutChannels + 1];
            for e := 0 to Project.TrackEffectCount[t] - 1 do
              if Project.TrackEffects[t][e].Kind <> Effects.ekNone then
                Effects.ProcessEffect(TrackEffectState[t][e], Project.TrackEffects[t][e],
                  L, R, ProjectSampleRate,
                  SidechainLevelFor(Project.TrackEffects[t][e].SidechainSourceTrack, Frame));
            TrackBuffers[t][Frame * OutChannels] := L;
            TrackBuffers[t][Frame * OutChannels + 1] := R;
          end;

        { The track fader, and the pre/post-fader send taps around it. Note
          that the fader is applied HERE and not at clip level, keeping the
          ordering identical to FillBlock's. }
        TrackVol := Project.TrackVolume[t];
        { pan folded into the fader gains exactly as FillBlock does it, and
          in the same place in the chain - after the pre-fader tap, before
          the post-fader one. Mirroring it here is not optional: this is the
          bounce's own copy of the chain, and a difference in gain staging
          between the two is precisely how a render stops matching what was
          heard. Pre-multiplied into the same scalar rather than applied as
          a separate step, so the arithmetic matches too. }
        Project.TrackPanGains(Project.TrackPan[t], TrackPanL, TrackPanR);
        TrackPanL := TrackVol * TrackPanL;
        TrackPanR := TrackVol * TrackPanR;
        for Frame := 0 to BlockLen - 1 do
        begin
          OutIdx := Frame * OutChannels;
          PreFaderL := TrackBuffers[t][OutIdx];
          PreFaderR := TrackBuffers[t][OutIdx + 1];
          L := PreFaderL * TrackPanL;
          R := PreFaderR * TrackPanR;
          TrackBuffers[t][OutIdx] := L;
          TrackBuffers[t][OutIdx + 1] := R;

          for sIdx := 0 to Project.SendCount - 1 do
            if Project.SendEnabled[sIdx] and Project.TrackSendEnabled[t][sIdx] then
            begin
              SendAmount := Project.TrackSendLevel[t][sIdx];
              if Project.SendPreFader[sIdx] then
              begin
                SendBuffers[sIdx][OutIdx] := SendBuffers[sIdx][OutIdx] + PreFaderL * SendAmount;
                SendBuffers[sIdx][OutIdx + 1] := SendBuffers[sIdx][OutIdx + 1] + PreFaderR * SendAmount;
              end
              else
              begin
                SendBuffers[sIdx][OutIdx] := SendBuffers[sIdx][OutIdx] + L * SendAmount;
                SendBuffers[sIdx][OutIdx + 1] := SendBuffers[sIdx][OutIdx + 1] + R * SendAmount;
              end;
            end;
        end;

        for SampleIdx := 0 to BlockLen * OutChannels - 1 do
          MasterBuf[SampleIdx] := MasterBuf[SampleIdx] + TrackBuffers[t][SampleIdx];
      end;

      { ---------- pass 3: send buses ----------
        one chain per bus over the summed contributions, returned into the
        master at the bus's own return level. Runs on every block including
        ones nothing fed, so a reverb tail on a send decays past the last
        thing that fed it rather than being cut off - same reasoning as
        FillBlock's version, and now literally the same mechanism. }
      for sIdx := 0 to Project.SendCount - 1 do
      begin
        if (not Project.SendEnabled[sIdx]) or (SendBuffers[sIdx] = nil) then
          Continue;
        for Frame := 0 to BlockLen - 1 do
        begin
          OutIdx := Frame * OutChannels;
          L := SendBuffers[sIdx][OutIdx];
          R := SendBuffers[sIdx][OutIdx + 1];
          for e := 0 to Project.SendEffectCount[sIdx] - 1 do
            if Project.SendEffects[sIdx][e].Kind <> Effects.ekNone then
              Effects.ProcessEffect(SendEffectState[sIdx][e], Project.SendEffects[sIdx][e],
                L, R, ProjectSampleRate,
                SidechainLevelFor(Project.SendEffects[sIdx][e].SidechainSourceTrack, Frame));
          MasterBuf[OutIdx] := MasterBuf[OutIdx] + L * Project.SendReturnLevel[sIdx];
          MasterBuf[OutIdx + 1] := MasterBuf[OutIdx + 1] + R * Project.SendReturnLevel[sIdx];
        end;
      end;

      { ---------- pass 4: master inserts ---------- }
      if Project.MasterEffectCount > 0 then
        for Frame := 0 to BlockLen - 1 do
        begin
          L := MasterBuf[Frame * OutChannels];
          R := MasterBuf[Frame * OutChannels + 1];
          for e := 0 to Project.MasterEffectCount - 1 do
            if Project.MasterEffects[e].Kind <> Effects.ekNone then
              { 0 for the sidechain level: per-track signal no longer exists
                distinctly by the time a master effect runs (every track's
                already been summed into MasterBuf just above), same as before
                - only per-track inserts gained real sidechain support here. }
              Effects.ProcessEffect(MasterEffectState[e], Project.MasterEffects[e], L, R,
                ProjectSampleRate, 0);
          MasterBuf[Frame * OutChannels] := L;
          MasterBuf[Frame * OutChannels + 1] := R;
        end;

      { ---------- pass 4b: master fader ----------
        The mirror of FillBlock's, and it has to sit exactly here - after the
        master inserts and before SP-1200 - or a bounce stops matching what
        was heard. One VScale over the interleaved buffer rather than two:
        the gain is the same for both channels, so the interleaving is
        irrelevant to it. Skipped at unity for the same reason as there. }
      if Project.MasterVolume <> 1.0 then
        VScale(MasterBuf, Project.MasterVolume, BlockLen * OutChannels);

      { ---------- pass 5: SP-1200, then straight out to disk ----------
        SP1200Process is a strictly sequential per-frame state machine, so
        feeding it consecutive blocks with the state carried between them
        produces the same samples as one call over the whole timeline. }
      if AudioEngineGetSP1200Enabled then
        SP1200Process(SP1200St, MasterBuf, BlockLen, OutChannels,
          ProjectSampleRate);

      if not WavWriteBlock(W, MasterBuf, BlockLen, OutChannels) then
        Exit;

      BlockStart := BlockStart + BlockLen;
    end;

    Result := True;
  finally
    { closing also verifies that as many frames arrived as the header
      promised, so a render that bailed out mid-way reports failure rather
      than leaving a plausible-looking truncated file }
    if WavStarted then
      Result := WavWriteEnd(W) and Result;
    for t := 0 to Project.MaxTracks - 1 do
      if TrackBuffers[t] <> nil then
        FreeMem(TrackBuffers[t]);
    for sIdx := 0 to Project.SendCount - 1 do
      if SendBuffers[sIdx] <> nil then
        FreeMem(SendBuffers[sIdx]);
    if MasterBuf <> nil then
      FreeMem(MasterBuf);
  end;
end;

finalization
  { a standalone project's unpacked copy is as large as its audio, so it is
    given back on the way out rather than left in the temp directory. A hard
    crash still leaks one such directory (named for the process that made
    it), which is why it lives under GetTempDir in the first place. }
  ReleaseBundleDir;

end.
