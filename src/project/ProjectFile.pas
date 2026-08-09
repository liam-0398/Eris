unit ProjectFile;

{$mode objfpc}{$H+}

interface

function SaveProject(const APath: string): Boolean;
function LoadProject(const APath: string): Boolean;
function RenderProjectToWav(const AOutputPath: string): Boolean;

implementation

uses
  SysUtils, Classes, IniFiles, FileUtil, SampleTypes, Project, WavDecoder,
  AudioEngine, Resample, Waveform, SP1200, TarArchive, Effects;

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
end;

function LoadEffect(Ini: TIniFile; const ASection, APrefix: string): Effects.TEffect;
var
  b: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := Ini.ReadInteger(ASection, APrefix + 'Kind', Effects.ekNone);
  Result.LowpassFreqHz := Ini.ReadFloat(ASection, APrefix + 'LowpassFreqHz', 8000);
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
end;

type
  TStrArr = array of string;

{ Hand-rolled single-pass split, deliberately not TStrings.DelimitedText -
  the packed clip format below never needs quoting/escaping (its own
  delimiters can't appear inside the numeric fields they separate), so a
  linear Pos-free scan is simpler and cheaper than a general CSV parser. }
function SplitStr(const S: string; ADelim: Char): TStrArr;
var
  Parts: TStrArr;
  Count, StartPos, i: Integer;
begin
  if S = '' then
    Exit(nil);
  SetLength(Parts, 0);
  Count := 0;
  StartPos := 1;
  for i := 1 to Length(S) + 1 do
    if (i > Length(S)) or (S[i] = ADelim) then
    begin
      SetLength(Parts, Count + 1);
      Parts[Count] := Copy(S, StartPos, i - StartPos);
      Inc(Count);
      StartPos := i + 1;
    end;
  Result := Parts;
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

function UnpackClip(const S: string; ATrackID: Integer): TClip;
var
  Fields, MarkerPairs, MarkerFields: TStrArr;
  FS: TFormatSettings;
  m: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  FS := PortableFloatSettings;
  Fields := SplitStr(S, ',');
  if Length(Fields) < 8 then
    Exit;

  Result.SampleID := StrToIntDef(Fields[0], -1);
  Result.Offset := StrToInt64Def(Fields[1], 0);
  Result.Length := StrToInt64Def(Fields[2], 0);
  Result.Position := StrToInt64Def(Fields[3], 0);
  Result.TrackID := ATrackID;
  Result.PitchSemitones := StrToFloatDef(Fields[4], 0, FS);
  Result.Gain := StrToFloatDef(Fields[5], 1.0, FS);
  Result.WarpMode := StrToIntDef(Fields[6], SampleTypes.WarpModeBeats);

  if Fields[7] <> '' then
  begin
    MarkerPairs := SplitStr(Fields[7], MarkerDelim);
    SetLength(Result.WarpMarkers, Length(MarkerPairs));
    for m := 0 to High(MarkerPairs) do
    begin
      MarkerFields := SplitStr(MarkerPairs[m], MarkerFieldDelim);
      if Length(MarkerFields) >= 2 then
      begin
        Result.WarpMarkers[m].SourceFrame := StrToInt64Def(MarkerFields[0], 0);
        Result.WarpMarkers[m].TimelineFrame := StrToInt64Def(MarkerFields[1], 0);
      end;
    end;
  end;
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
  i: Integer;
begin
  Result := '';
  for i := 0 to High(AClips) do
  begin
    if i > 0 then
      Result := Result + ClipDelim;
    Result := Result + PackClip(AClips[i]);
  end;
end;

procedure UnpackClips(const S: string; ATrackID: Integer; out AClips: TClipArray);
var
  Parts: TStrArr;
  i: Integer;
begin
  if S = '' then
  begin
    SetLength(AClips, 0);
    Exit;
  end;
  Parts := SplitStr(S, ClipDelim);
  SetLength(AClips, Length(Parts));
  for i := 0 to High(Parts) do
    AClips[i] := UnpackClip(Parts[i], ATrackID);
end;

function SaveProject(const APath: string): Boolean;
var
  Dir, IniPath, Section, EmbeddedName: string;
  Ini: TIniFile;
  t, i, e: Integer;
begin
  Result := False;

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

    Ini.WriteInteger('Master', 'EffectCount', Project.MasterEffectCount);
    for e := 0 to Project.MasterEffectCount - 1 do
      SaveEffect(Ini, 'Master', 'Effect' + IntToStr(e) + '.', Project.MasterEffects[e]);

    Ini.WriteInteger('Samples', 'Count', Length(Project.SamplePool));
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

      if not FileExists(Project.SamplePaths[i]) then
      begin
        { no real source file to reference - either a recorded clip (never
          loaded from disk, SamplePaths is '') or a sample that came from a
          previously embedded recording (a bare filename from an earlier
          bundle, not a standalone path). Either way, embed its audio as a
          real WAV right inside THIS bundle instead of writing a path that
          resolves to nothing once the old bundle is gone. }
        EmbeddedName := 'recorded' + IntToStr(i) + '.wav';
        EncodeWav(IncludeTrailingPathDelimiter(Dir) + EmbeddedName,
          Project.SamplePool[i].Data, Project.SamplePool[i].FrameCount,
          Project.SamplePool[i].Channels, Project.SamplePool[i].SampleRate);
        Ini.WriteString('Samples', 'Path' + IntToStr(i), EmbeddedName);
      end
      else
        Ini.WriteString('Samples', 'Path' + IntToStr(i), Project.SamplePaths[i]);
    end;

    for t := 0 to Project.TrackCount - 1 do
    begin
      Section := 'Track' + IntToStr(t);
      Ini.WriteInteger(Section, 'Instrument', Project.TrackInstrument[t]);
      Ini.WriteInteger(Section, 'Octave', Project.TrackOctave[t]);
      Ini.WriteFloat(Section, 'Volume', Project.TrackVolume[t]);
      Ini.WriteBool(Section, 'Enabled', Project.TrackEnabled[t]);
      Ini.WriteInt64(Section, 'InstrumentStart', Project.TrackInstrumentStart[t]);
      Ini.WriteInt64(Section, 'InstrumentEnd', Project.TrackInstrumentEnd[t]);
      Ini.WriteFloat(Section, 'SwingPercent', Project.TrackSwingPercent[t]);
      Ini.WriteInteger(Section, 'SwingDivision', Project.TrackSwingDivision[t]);

      Ini.WriteInteger(Section, 'EffectCount', Project.TrackEffectCount[t]);
      for e := 0 to Project.TrackEffectCount[t] - 1 do
        SaveEffect(Ini, Section, 'Effect' + IntToStr(e) + '.', Project.TrackEffects[t][e]);

      { see PackClips' comment - one key holds every clip (and all their warp
        markers) for the track, instead of ~9 keys per clip that made saving
        a heavily-chopped track scale as O(clip-count^2) }
      Ini.WriteString(Section, 'ClipsPacked', PackClips(Project.Tracks[t].Clips));
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

  if FileExists(APath) then
    DeleteFile(APath);
  Result := CreateTarFromDirectory(Dir, APath);
  DeleteDirectory(Dir, False);
end;

const
  { decode + peak/transient analysis is pure CPU+file-I/O work with no
    shared mutable state (WavDecoder's only global is a read-only decoder
    table; ComputeWaveformPeaks/DetectTransients touch only their own
    arguments) - safe to fan out across threads. Capped at a small fixed
    count rather than querying core count, matching the project's "keep
    dependencies short" preference over pulling in a CPU-count API. }
  MaxSampleLoadThreads = 4;

type
  TSampleLoadJob = record
    Index: Integer;
    StoredPath, ResolvedPath: string;
    { '' for a project.ini saved before display names were persisted (see
      SaveProject) - Execute below falls back to deriving one from
      StoredPath exactly as it always did, so old projects still load fine }
    DisplayName: string;
  end;
  TSampleLoadJobArray = array of TSampleLoadJob;

  { Each thread owns a disjoint slice of sample-pool indices, pre-sized by
    the caller before any thread starts - writes to Project.SamplePool[i]
    etc. from different threads never touch the same array element, so no
    locking is needed despite the arrays being shared globals. }
  TSampleLoadThread = class(TThread)
  private
    FJobs: TSampleLoadJobArray;
  protected
    procedure Execute; override;
  public
    constructor Create(const AJobs: TSampleLoadJobArray);
  end;

constructor TSampleLoadThread.Create(const AJobs: TSampleLoadJobArray);
begin
  { fields are set BEFORE calling the inherited constructor, which starts
    the thread immediately (CreateSuspended=False) - Execute only ever
    sees a fully-populated FJobs. Matches AudioEngine.TPlaybackThread, the
    only other TThread in this codebase: suspended creation (Create(True)
    + a later .Start) hung indefinitely here - FPC's suspended-thread
    emulation on Linux/cthreads never actually resumed, so WaitFor blocked
    the GUI thread forever on every project open. }
  FJobs := Copy(AJobs, 0, Length(AJobs));
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TSampleLoadThread.Execute;
var
  i, Idx: Integer;
  Sample, EmptySample: TSample;
begin
  FillChar(EmptySample, SizeOf(EmptySample), 0);
  for i := 0 to High(FJobs) do
  begin
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
    { mirrors Project.AddSampleToPool exactly - analyze whatever ended up
      in the pool slot, real or empty }
    Project.SamplePeaks[Idx] := ComputeWaveformPeaks(Project.SamplePool[Idx]);
    Project.SampleTransients[Idx] := DetectTransients(Project.SamplePool[Idx].Data,
      Project.SamplePool[Idx].FrameCount, Project.SamplePool[Idx].Channels,
      Project.SamplePool[Idx].SampleRate);
  end;
end;

{ Decodes every sample referenced by the project in parallel. Project.
  SamplePool/SampleNames/SamplePaths/SamplePeaks/SampleTransients must
  already be sized to Length(AJobs) - each job's Index is its slot in
  those arrays - before this is called. }
procedure LoadSamplesThreaded(const AJobs: TSampleLoadJobArray);
var
  ThreadCount, ChunkSize, w, StartIdx, EndIdx: Integer;
  Threads: array of TSampleLoadThread;
begin
  if Length(AJobs) = 0 then
    Exit;

  ThreadCount := Length(AJobs);
  if ThreadCount > MaxSampleLoadThreads then
    ThreadCount := MaxSampleLoadThreads;

  ChunkSize := (Length(AJobs) + ThreadCount - 1) div ThreadCount;
  SetLength(Threads, ThreadCount);

  { each thread starts running as soon as it's constructed (Create(False) -
    see the constructor's comment) - no separate Start pass needed }
  for w := 0 to ThreadCount - 1 do
  begin
    StartIdx := w * ChunkSize;
    EndIdx := StartIdx + ChunkSize;
    if EndIdx > Length(AJobs) then
      EndIdx := Length(AJobs);
    Threads[w] := TSampleLoadThread.Create(Copy(AJobs, StartIdx, EndIdx - StartIdx));
  end;

  for w := 0 to ThreadCount - 1 do
  begin
    Threads[w].WaitFor;
    Threads[w].Free;
  end;
end;

function LoadProject(const APath: string): Boolean;
var
  Dir, IniPath, Section, Prefix, StoredPath, ResolvedPath: string;
  Ini: TIniFile;
  t, i, m, e, SampleCount, ClipCount, MarkerCount: Integer;
  Clip: TClip;
  SampleJobs: TSampleLoadJobArray;
begin
  Result := False;

  Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'eris_load_tmp';
  if DirectoryExists(Dir) then
    DeleteDirectory(Dir, False);

  if DirectoryExists(APath) then
    { backward compatible with older projects saved as a loose directory
      bundle rather than a packed .er tar file }
    Dir := ExcludeTrailingPathDelimiter(APath)
  else if FileExists(APath) then
  begin
    if not ExtractTarToDirectory(APath, Dir) then
      Exit;
  end
  else
    Exit;

  IniPath := IncludeTrailingPathDelimiter(Dir) + 'project.ini';
  if not FileExists(IniPath) then
    Exit;

  Project.NewProject;

  Ini := TIniFile.Create(IniPath);
  try
    Project.TempoBPM := Ini.ReadFloat('Project', 'Tempo', Project.DefaultTempoBPM);
    Project.TrackCount := Ini.ReadInteger('Project', 'TrackCount', Project.DefaultTrackCount);
    if Project.TrackCount < 1 then
      Project.TrackCount := 1
    else if Project.TrackCount > Project.MaxTracks then
      Project.TrackCount := Project.MaxTracks;
    AudioEngineSetSP1200Enabled(Ini.ReadBool('Project', 'SP1200Enabled', False));

    Project.MasterEffectCount := Ini.ReadInteger('Master', 'EffectCount', 0);
    if Project.MasterEffectCount > Effects.MaxEffectsPerTrack then
      Project.MasterEffectCount := Effects.MaxEffectsPerTrack;
    for e := 0 to Project.MasterEffectCount - 1 do
      Project.MasterEffects[e] := LoadEffect(Ini, 'Master', 'Effect' + IntToStr(e) + '.');

    SampleCount := Ini.ReadInteger('Samples', 'Count', 0);

    { pre-size every output array once, up front, so the worker threads can
      write to their own disjoint indices with no locking and no risk of a
      concurrent SetLength reallocating out from under another thread }
    SetLength(Project.SamplePool, SampleCount);
    SetLength(Project.SampleNames, SampleCount);
    SetLength(Project.SamplePaths, SampleCount);
    SetLength(Project.SamplePeaks, SampleCount);
    SetLength(Project.SampleTransients, SampleCount);

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
    end;

    LoadSamplesThreaded(SampleJobs);

    for t := 0 to Project.TrackCount - 1 do
    begin
      Section := 'Track' + IntToStr(t);
      Project.TrackInstrument[t] := Ini.ReadInteger(Section, 'Instrument', -1);
      Project.TrackOctave[t] := Ini.ReadInteger(Section, 'Octave', 0);
      Project.TrackVolume[t] := Ini.ReadFloat(Section, 'Volume', 1.0);
      Project.TrackEnabled[t] := Ini.ReadBool(Section, 'Enabled', True);
      Project.TrackSwingPercent[t] := Ini.ReadFloat(Section, 'SwingPercent', 50);
      Project.TrackSwingDivision[t] := Ini.ReadInteger(Section, 'SwingDivision', 16);

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

      if Ini.ValueExists(Section, 'ClipsPacked') then
        { current format - see PackClips/SaveProject }
        UnpackClips(Ini.ReadString(Section, 'ClipsPacked', ''), t, Project.Tracks[t].Clips)
      else
      begin
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

    Result := True;
  finally
    Ini.Free;
  end;

  if not DirectoryExists(APath) then
    DeleteDirectory(Dir, False);
end;

function RenderProjectToWav(const AOutputPath: string): Boolean;
const
  OutChannels = 2;
var
  ProjectLengthFrames: Int64;
  t, i: Integer;
  Clip: TClip;
  Sample: TSample;
  Buffer: PSingle;
  TrackBuffers: array[0..Project.MaxTracks - 1] of PSingle;
  TrackEffectState: array[0..Project.MaxTracks - 1, 0..Effects.MaxEffectsPerTrack - 1] of
    Effects.TEffectState;
  Frame, OutIdx, SampleIdx: Int64;
  SP1200St: TSP1200State;
  MasterEffectState: array[0..Effects.MaxEffectsPerTrack - 1] of Effects.TEffectState;
  L, R: Single;
  e: Integer;
  RenderBeatFrames, SwungPos: Int64;

  { Offline equivalent of AudioEngine.FillBlock's SidechainLevelFor - reads
    straight off the source track's raw (pre-FX) buffer at the current
    Frame rather than realtime's post-FX/one-frame-stale TrackTapLevel; a
    deliberate, documented approximation (matching this codebase's existing
    tolerance for that exact class of gap) rather than restructuring this
    whole render to be frame-major just for sidechain parity. }
  function SidechainLevelFor(ASourceTrack: Integer): Single;
  var
    SL, SR: Single;
  begin
    if (ASourceTrack < 0) or (ASourceTrack >= Project.MaxTracks) or
      (TrackBuffers[ASourceTrack] = nil) then
      Result := 0
    else
    begin
      SL := Abs(TrackBuffers[ASourceTrack][Frame * OutChannels]);
      SR := Abs(TrackBuffers[ASourceTrack][Frame * OutChannels + 1]);
      if SL > SR then Result := SL else Result := SR;
    end;
  end;

begin
  Result := False;
  RenderBeatFrames := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM);
  ProjectLengthFrames := 0;
  for t := 0 to Project.TrackCount - 1 do
  begin
    if not Project.TrackEnabled[t] then
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

  GetMem(Buffer, ProjectLengthFrames * OutChannels * SizeOf(Single));
  FillChar(TrackBuffers, SizeOf(TrackBuffers), 0);
  try
    FillChar(Buffer^, ProjectLengthFrames * OutChannels * SizeOf(Single), 0);

    { each enabled track renders into its OWN scratch buffer first - needed
      so its insert-FX chain (below) can run on just that track's signal,
      exactly like AudioEngine.FillBlock's per-track TrackL/TrackR does,
      before summing into the master buffer. Previously every clip summed
      straight into the master buffer and Project.TrackEffects was never
      even read here, so insert effects silently never applied to a bounce. }
    for t := 0 to Project.TrackCount - 1 do
    begin
      if not Project.TrackEnabled[t] then
        Continue;

      GetMem(TrackBuffers[t], ProjectLengthFrames * OutChannels * SizeOf(Single));
      FillChar(TrackBuffers[t]^, ProjectLengthFrames * OutChannels * SizeOf(Single), 0);

      for i := 0 to High(Project.Tracks[t].Clips) do
      begin
        Clip := Project.Tracks[t].Clips[i];
        Sample := Project.SamplePool[Clip.SampleID];
        SwungPos := AudioEngine.SwungPosition(Clip.Position,
          Project.TrackSwingPercent[t], Project.TrackSwingDivision[t], RenderBeatFrames);

        for Frame := 0 to Clip.Length - 1 do
        begin
          OutIdx := (SwungPos + Frame) * OutChannels;

          { transients passed through (absolute file positions; translated
            clip-relative inside the warp lookup via Clip.Offset) so a bounce
            uses the same transient-bounded Beats grains as live playback -
            omitting them silently fell back to the fixed ~120ms grid,
            making bounces audibly diverge from what was heard live }
          if Sample.Channels = 1 then
          begin
            TrackBuffers[t][OutIdx] := TrackBuffers[t][OutIdx] +
              DetunedSample(Clip.WarpMarkers, Frame, Clip.PitchSemitones, Clip.Offset,
                Sample.Data, Sample.FrameCount, Sample.Channels,
                AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
                Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
            TrackBuffers[t][OutIdx + 1] := TrackBuffers[t][OutIdx + 1] +
              DetunedSample(Clip.WarpMarkers, Frame, Clip.PitchSemitones, Clip.Offset,
                Sample.Data, Sample.FrameCount, Sample.Channels,
                AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
                Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
          end
          else
          begin
            TrackBuffers[t][OutIdx] := TrackBuffers[t][OutIdx] +
              DetunedSample(Clip.WarpMarkers, Frame, Clip.PitchSemitones, Clip.Offset,
                Sample.Data, Sample.FrameCount, Sample.Channels,
                AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
                Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
            TrackBuffers[t][OutIdx + 1] := TrackBuffers[t][OutIdx + 1] +
              DetunedSample(Clip.WarpMarkers, Frame, Clip.PitchSemitones, Clip.Offset,
                Sample.Data, Sample.FrameCount, Sample.Channels,
                AudioEngine.ProjectSampleRate, Clip.WarpMode, 1, Clip.Length,
                Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
          end;
        end;
      end;
    end;

    { per-track insert effects (mirrors the master-effect loop below, just
      per-track), then sum into the master buffer }
    for t := 0 to Project.TrackCount - 1 do
    begin
      if not Project.TrackEnabled[t] then
        Continue;

      if Project.TrackEffectCount[t] > 0 then
      begin
        for e := 0 to Effects.MaxEffectsPerTrack - 1 do
          Effects.EffectStateReset(TrackEffectState[t][e]);
        for Frame := 0 to ProjectLengthFrames - 1 do
        begin
          L := TrackBuffers[t][Frame * OutChannels];
          R := TrackBuffers[t][Frame * OutChannels + 1];
          for e := 0 to Project.TrackEffectCount[t] - 1 do
            if Project.TrackEffects[t][e].Kind <> Effects.ekNone then
              Effects.ProcessEffect(TrackEffectState[t][e], Project.TrackEffects[t][e],
                L, R, ProjectSampleRate,
                SidechainLevelFor(Project.TrackEffects[t][e].SidechainSourceTrack));
          TrackBuffers[t][Frame * OutChannels] := L;
          TrackBuffers[t][Frame * OutChannels + 1] := R;
        end;
      end;

      for SampleIdx := 0 to ProjectLengthFrames * OutChannels - 1 do
        Buffer[SampleIdx] := Buffer[SampleIdx] + TrackBuffers[t][SampleIdx];
    end;

    if Project.MasterEffectCount > 0 then
    begin
      for e := 0 to Effects.MaxEffectsPerTrack - 1 do
        Effects.EffectStateReset(MasterEffectState[e]);
      for Frame := 0 to ProjectLengthFrames - 1 do
      begin
        L := Buffer[Frame * OutChannels];
        R := Buffer[Frame * OutChannels + 1];
        for e := 0 to Project.MasterEffectCount - 1 do
          if Project.MasterEffects[e].Kind <> Effects.ekNone then
            { 0 for the sidechain level: per-track signal no longer exists
              distinctly by the time a master effect runs (every track's
              already been summed into Buffer just above), same as before -
              only per-track inserts gained real sidechain support here. }
            Effects.ProcessEffect(MasterEffectState[e], Project.MasterEffects[e], L, R,
              ProjectSampleRate, 0);
        Buffer[Frame * OutChannels] := L;
        Buffer[Frame * OutChannels + 1] := R;
      end;
    end;

    if AudioEngineGetSP1200Enabled then
    begin
      SP1200Reset(SP1200St);
      SP1200Process(SP1200St, Buffer, ProjectLengthFrames, OutChannels,
        ProjectSampleRate);
    end;

    Result := EncodeWav(AOutputPath, Buffer, ProjectLengthFrames, OutChannels,
      ProjectSampleRate);
  finally
    for t := 0 to Project.MaxTracks - 1 do
      if TrackBuffers[t] <> nil then
        FreeMem(TrackBuffers[t]);
    FreeMem(Buffer);
  end;
end;

end.
