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
end;

function SaveProject(const APath: string): Boolean;
var
  Dir, IniPath, Section, Prefix, EmbeddedName: string;
  Ini: TIniFile;
  t, i, m, e: Integer;
  Clip: TClip;
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

      Ini.WriteInteger(Section, 'ClipCount', Length(Project.Tracks[t].Clips));

      for i := 0 to High(Project.Tracks[t].Clips) do
      begin
        Clip := Project.Tracks[t].Clips[i];
        Prefix := 'Clip' + IntToStr(i) + '.';
        Ini.WriteInteger(Section, Prefix + 'SampleID', Clip.SampleID);
        Ini.WriteInt64(Section, Prefix + 'Offset', Clip.Offset);
        Ini.WriteInt64(Section, Prefix + 'Length', Clip.Length);
        Ini.WriteInt64(Section, Prefix + 'Position', Clip.Position);
        Ini.WriteFloat(Section, Prefix + 'Pitch', Clip.PitchSemitones);
        Ini.WriteFloat(Section, Prefix + 'Gain', Clip.Gain);
        Ini.WriteInteger(Section, Prefix + 'WarpMode', Clip.WarpMode);

        Ini.WriteInteger(Section, Prefix + 'MarkerCount', Length(Clip.WarpMarkers));
        for m := 0 to High(Clip.WarpMarkers) do
        begin
          Ini.WriteInt64(Section, Prefix + 'Marker' + IntToStr(m) + '.Source',
            Clip.WarpMarkers[m].SourceFrame);
          Ini.WriteInt64(Section, Prefix + 'Marker' + IntToStr(m) + '.Timeline',
            Clip.WarpMarkers[m].TimelineFrame);
        end;
      end;
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
  Frame, OutIdx: Int64;
  SP1200St: TSP1200State;
  MasterEffectState: array[0..Effects.MaxEffectsPerTrack - 1] of Effects.TEffectState;
  L, R: Single;
  e: Integer;
  RenderBeatFrames, SwungPos: Int64;
begin
  Result := False;
  RenderBeatFrames := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM);
  ProjectLengthFrames := 0;
  for t := 0 to Project.TrackCount - 1 do
    for i := 0 to High(Project.Tracks[t].Clips) do
    begin
      Clip := Project.Tracks[t].Clips[i];
      SwungPos := AudioEngine.SwungPosition(Clip.Position,
        Project.TrackSwingPercent[t], Project.TrackSwingDivision[t], RenderBeatFrames);
      if SwungPos + Clip.Length > ProjectLengthFrames then
        ProjectLengthFrames := SwungPos + Clip.Length;
    end;

  if ProjectLengthFrames <= 0 then
    Exit;

  GetMem(Buffer, ProjectLengthFrames * OutChannels * SizeOf(Single));
  try
    FillChar(Buffer^, ProjectLengthFrames * OutChannels * SizeOf(Single), 0);

    for t := 0 to Project.TrackCount - 1 do
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
            Buffer[OutIdx] := Buffer[OutIdx] +
              DetunedSample(Clip.WarpMarkers, Frame, Clip.PitchSemitones, Clip.Offset,
                Sample.Data, Sample.FrameCount, Sample.Channels,
                AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
                Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
            Buffer[OutIdx + 1] := Buffer[OutIdx + 1] +
              DetunedSample(Clip.WarpMarkers, Frame, Clip.PitchSemitones, Clip.Offset,
                Sample.Data, Sample.FrameCount, Sample.Channels,
                AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
                Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
          end
          else
          begin
            Buffer[OutIdx] := Buffer[OutIdx] +
              DetunedSample(Clip.WarpMarkers, Frame, Clip.PitchSemitones, Clip.Offset,
                Sample.Data, Sample.FrameCount, Sample.Channels,
                AudioEngine.ProjectSampleRate, Clip.WarpMode, 0, Clip.Length,
                Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
            Buffer[OutIdx + 1] := Buffer[OutIdx + 1] +
              DetunedSample(Clip.WarpMarkers, Frame, Clip.PitchSemitones, Clip.Offset,
                Sample.Data, Sample.FrameCount, Sample.Channels,
                AudioEngine.ProjectSampleRate, Clip.WarpMode, 1, Clip.Length,
                Project.SampleTransients[Clip.SampleID]) * Clip.Gain;
          end;
        end;
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
            Effects.ProcessEffect(MasterEffectState[e], Project.MasterEffects[e], L, R,
              ProjectSampleRate);
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
    FreeMem(Buffer);
  end;
end;

end.
