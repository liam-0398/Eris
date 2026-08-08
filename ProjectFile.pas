unit ProjectFile;

{$mode objfpc}{$H+}

interface

function SaveProject(const APath: string): Boolean;
function LoadProject(const APath: string): Boolean;
function RenderProjectToWav(const AOutputPath: string): Boolean;

implementation

uses
  SysUtils, Classes, IniFiles, FileUtil, SampleTypes, Project, WavDecoder,
  AudioEngine, Resample, Waveform, SP1200, TarArchive;

function SaveProject(const APath: string): Boolean;
var
  Dir, IniPath, Section, Prefix: string;
  Ini: TIniFile;
  t, i, m: Integer;
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

    Ini.WriteInteger('Samples', 'Count', Length(Project.SamplePool));
    for i := 0 to High(Project.SamplePool) do
      Ini.WriteString('Samples', 'Path' + IntToStr(i), Project.SamplePaths[i]);

    for t := 0 to Project.TrackCount - 1 do
    begin
      Section := 'Track' + IntToStr(t);
      Ini.WriteInteger(Section, 'Instrument', Project.TrackInstrument[t]);
      Ini.WriteInteger(Section, 'Octave', Project.TrackOctave[t]);
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

function LoadProject(const APath: string): Boolean;
var
  Dir, IniPath, Section, Prefix, StoredPath, ResolvedPath: string;
  Ini: TIniFile;
  t, i, m, SampleCount, ClipCount, MarkerCount: Integer;
  Sample, EmptySample: TSample;
  Clip: TClip;
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
  FillChar(EmptySample, SizeOf(EmptySample), 0);

  Ini := TIniFile.Create(IniPath);
  try
    Project.TempoBPM := Ini.ReadFloat('Project', 'Tempo', Project.DefaultTempoBPM);

    SampleCount := Ini.ReadInteger('Samples', 'Count', 0);
    for i := 0 to SampleCount - 1 do
    begin
      StoredPath := Ini.ReadString('Samples', 'Path' + IntToStr(i), '');

      { resolve relative to the .er directory first, falling back to absolute }
      ResolvedPath := IncludeTrailingPathDelimiter(Dir) + StoredPath;
      if not FileExists(ResolvedPath) then
        ResolvedPath := StoredPath;

      if DecodeSampleFile(ResolvedPath, Sample) then
        Project.AddSampleToPool(Sample, ExtractFileName(StoredPath), StoredPath)
      else
        Project.AddSampleToPool(EmptySample, '(missing: ' + ExtractFileName(StoredPath) + ')',
          StoredPath);
    end;

    for t := 0 to Project.TrackCount - 1 do
    begin
      Section := 'Track' + IntToStr(t);
      Project.TrackInstrument[t] := Ini.ReadInteger(Section, 'Instrument', -1);
      Project.TrackOctave[t] := Ini.ReadInteger(Section, 'Octave', 0);

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
  SrcPos: Double;
  SP1200St: TSP1200State;
begin
  Result := False;
  ProjectLengthFrames := 0;
  for t := 0 to Project.TrackCount - 1 do
    for i := 0 to High(Project.Tracks[t].Clips) do
    begin
      Clip := Project.Tracks[t].Clips[i];
      if Clip.Position + Clip.Length > ProjectLengthFrames then
        ProjectLengthFrames := Clip.Position + Clip.Length;
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

        for Frame := 0 to Clip.Length - 1 do
        begin
          SrcPos := Clip.Offset + WarpedSourcePosition(Clip.WarpMarkers, Frame,
            Sample.Data, Sample.FrameCount, Sample.Channels, AudioEngine.ProjectSampleRate,
            Clip.WarpMode);
          if (SrcPos < 0) or (SrcPos >= Sample.FrameCount) then
            Continue;

          OutIdx := (Clip.Position + Frame) * OutChannels;

          if Sample.Channels = 1 then
          begin
            Buffer[OutIdx] := Buffer[OutIdx] +
              Interpolate(Sample.Data, Sample.FrameCount, Sample.Channels, 0, SrcPos) * Clip.Gain;
            Buffer[OutIdx + 1] := Buffer[OutIdx + 1] +
              Interpolate(Sample.Data, Sample.FrameCount, Sample.Channels, 0, SrcPos) * Clip.Gain;
          end
          else
          begin
            Buffer[OutIdx] := Buffer[OutIdx] +
              Interpolate(Sample.Data, Sample.FrameCount, Sample.Channels, 0, SrcPos) * Clip.Gain;
            Buffer[OutIdx + 1] := Buffer[OutIdx + 1] +
              Interpolate(Sample.Data, Sample.FrameCount, Sample.Channels, 1, SrcPos) * Clip.Gain;
          end;
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
