unit ProjectFile;

{$mode objfpc}{$H+}

interface

function SaveProject(const APath: string): Boolean;
function LoadProject(const APath: string): Boolean;
function RenderProjectToWav(const AOutputPath: string): Boolean;

implementation

uses
  SysUtils, Classes, IniFiles, SampleTypes, Project, WavDecoder, AudioEngine;

function SaveProject(const APath: string): Boolean;
var
  Dir, IniPath, Section, Prefix: string;
  Ini: TIniFile;
  t, i: Integer;
  Clip: TClip;
begin
  Result := False;
  Dir := ExcludeTrailingPathDelimiter(APath);
  if not DirectoryExists(Dir) then
    if not CreateDir(Dir) then
      Exit;

  IniPath := IncludeTrailingPathDelimiter(Dir) + 'project.ini';
  if FileExists(IniPath) then
    DeleteFile(IniPath);

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
      end;
    end;

    Result := True;
  finally
    Ini.Free;
  end;
end;

function LoadProject(const APath: string): Boolean;
var
  Dir, IniPath, Section, Prefix, StoredPath, ResolvedPath: string;
  Ini: TIniFile;
  t, i, SampleCount, ClipCount: Integer;
  Sample, EmptySample: TSample;
  Clip: TClip;
begin
  Result := False;
  Dir := ExcludeTrailingPathDelimiter(APath);
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

        SetLength(Project.Tracks[t].Clips, Length(Project.Tracks[t].Clips) + 1);
        Project.Tracks[t].Clips[High(Project.Tracks[t].Clips)] := Clip;
      end;
    end;

    Result := True;
  finally
    Ini.Free;
  end;
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
  Frame, SrcFrame, OutIdx: Int64;
  SrcIdx: Integer;
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
          SrcFrame := Clip.Offset + Frame;
          if (SrcFrame < 0) or (SrcFrame >= Sample.FrameCount) then
            Continue;

          OutIdx := (Clip.Position + Frame) * OutChannels;
          SrcIdx := SrcFrame * Sample.Channels;

          if Sample.Channels = 1 then
          begin
            Buffer[OutIdx] := Buffer[OutIdx] + Sample.Data[SrcIdx] * Clip.Gain;
            Buffer[OutIdx + 1] := Buffer[OutIdx + 1] + Sample.Data[SrcIdx] * Clip.Gain;
          end
          else
          begin
            Buffer[OutIdx] := Buffer[OutIdx] + Sample.Data[SrcIdx] * Clip.Gain;
            Buffer[OutIdx + 1] := Buffer[OutIdx + 1] + Sample.Data[SrcIdx + 1] * Clip.Gain;
          end;
        end;
      end;

    Result := EncodeWav(AOutputPath, Buffer, ProjectLengthFrames, OutChannels,
      ProjectSampleRate);
  finally
    FreeMem(Buffer);
  end;
end;

end.
