unit Project;

{$mode objfpc}{$H+}

interface

uses
  SampleTypes, ClipOverwrite, Waveform;

const
  MaxTracks = 16;
  DefaultTrackCount = 4;
  DefaultTempoBPM = 160.0;

type
  TTrack = record
    Clips: TClipArray;
  end;

var
  { the arrays below are always sized to MaxTracks so the audio engine's
    matching fixed-size arrays never need to be reallocated; TrackCount is
    how many of those slots are currently active/visible }
  TrackCount: Integer = DefaultTrackCount;
  Tracks: array[0..MaxTracks - 1] of TTrack;
  SamplePool: array of TSample;
  SampleNames: array of string;
  SamplePaths: array of string;
  SamplePeaks: array of TWaveformPeaks;
  TempoBPM: Single = DefaultTempoBPM;

  { keyboard-play instrument assigned to each track via the device panel;
    -1 means no instrument loaded }
  TrackInstrument: array[0..MaxTracks - 1] of Integer;
  TrackOctave: array[0..MaxTracks - 1] of Integer;

function AddSampleToPool(const ASample: TSample; const AName, APath: string): Integer;
procedure CommitClipToTrack(ATrackIndex: Integer; const ANewClip: TClip);
procedure ReplaceTrackClips(ATrackIndex: Integer; const AClips: TClipArray);
procedure RemoveClipAt(ATrackIndex, AClipIndex: Integer);

procedure PushUndoSnapshot(ATrackIndex: Integer);
function PopUndo(out ATrackIndex: Integer): Boolean;

function AddTrack: Boolean;
procedure NewProject;

implementation

type
  TUndoSnapshot = record
    TrackIndex: Integer;
    Clips: TClipArray;
  end;

var
  UndoStack: array of TUndoSnapshot;

procedure InitTrackInstruments;
var
  i: Integer;
begin
  for i := 0 to MaxTracks - 1 do
  begin
    TrackInstrument[i] := -1;
    TrackOctave[i] := 0;
  end;
end;

function AddSampleToPool(const ASample: TSample; const AName, APath: string): Integer;
begin
  SetLength(SamplePool, Length(SamplePool) + 1);
  SetLength(SampleNames, Length(SampleNames) + 1);
  SetLength(SamplePaths, Length(SamplePaths) + 1);
  SetLength(SamplePeaks, Length(SamplePeaks) + 1);
  Result := High(SamplePool);
  SamplePool[Result] := ASample;
  SampleNames[Result] := AName;
  SamplePaths[Result] := APath;
  SamplePeaks[Result] := ComputeWaveformPeaks(ASample);
end;

procedure CommitClipToTrack(ATrackIndex: Integer; const ANewClip: TClip);
var
  Updated: TClipArray;
begin
  Updated := OverwriteClips(Tracks[ATrackIndex].Clips, ANewClip.Position,
    ANewClip.Length);
  SetLength(Updated, Length(Updated) + 1);
  Updated[High(Updated)] := ANewClip;
  Tracks[ATrackIndex].Clips := Updated;
end;

procedure ReplaceTrackClips(ATrackIndex: Integer; const AClips: TClipArray);
begin
  Tracks[ATrackIndex].Clips := AClips;
end;

procedure RemoveClipAt(ATrackIndex, AClipIndex: Integer);
var
  Clips, NewClips: TClipArray;
  j, k: Integer;
begin
  Clips := Tracks[ATrackIndex].Clips;
  SetLength(NewClips, Length(Clips) - 1);
  k := 0;
  for j := 0 to High(Clips) do
    if j <> AClipIndex then
    begin
      NewClips[k] := Clips[j];
      Inc(k);
    end;
  Tracks[ATrackIndex].Clips := NewClips;
end;

procedure PushUndoSnapshot(ATrackIndex: Integer);
var
  Snap: TUndoSnapshot;
begin
  Snap.TrackIndex := ATrackIndex;
  Snap.Clips := Copy(Tracks[ATrackIndex].Clips, 0, Length(Tracks[ATrackIndex].Clips));
  SetLength(UndoStack, Length(UndoStack) + 1);
  UndoStack[High(UndoStack)] := Snap;
end;

function PopUndo(out ATrackIndex: Integer): Boolean;
var
  Snap: TUndoSnapshot;
begin
  if Length(UndoStack) = 0 then
    Exit(False);
  Snap := UndoStack[High(UndoStack)];
  SetLength(UndoStack, Length(UndoStack) - 1);
  Tracks[Snap.TrackIndex].Clips := Snap.Clips;
  ATrackIndex := Snap.TrackIndex;
  Result := True;
end;

function AddTrack: Boolean;
begin
  if TrackCount >= MaxTracks then
    Exit(False);
  Tracks[TrackCount].Clips := nil;
  TrackInstrument[TrackCount] := -1;
  TrackOctave[TrackCount] := 0;
  Inc(TrackCount);
  Result := True;
end;

procedure NewProject;
var
  i: Integer;
begin
  for i := 0 to High(SamplePool) do
    if SamplePool[i].Data <> nil then
      FreeMem(SamplePool[i].Data);
  SetLength(SamplePool, 0);
  SetLength(SampleNames, 0);
  SetLength(SamplePaths, 0);
  SetLength(SamplePeaks, 0);
  SetLength(UndoStack, 0);

  for i := 0 to MaxTracks - 1 do
    Tracks[i].Clips := nil;

  TrackCount := DefaultTrackCount;
  InitTrackInstruments;
  TempoBPM := DefaultTempoBPM;
end;

initialization
  InitTrackInstruments;

end.
