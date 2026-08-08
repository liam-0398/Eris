unit Project;

{$mode objfpc}{$H+}

interface

uses
  SampleTypes, ClipOverwrite;

const
  TrackCount = 4;
  DefaultTempoBPM = 160.0;

type
  TTrack = record
    Clips: TClipArray;
  end;

var
  Tracks: array[0..TrackCount - 1] of TTrack;
  SamplePool: array of TSample;
  SampleNames: array of string;
  TempoBPM: Single = DefaultTempoBPM;

function AddSampleToPool(const ASample: TSample; const AName: string): Integer;
procedure CommitClipToTrack(ATrackIndex: Integer; const ANewClip: TClip);
procedure ReplaceTrackClips(ATrackIndex: Integer; const AClips: TClipArray);
procedure RemoveClipAt(ATrackIndex, AClipIndex: Integer);

procedure PushUndoSnapshot(ATrackIndex: Integer);
function PopUndo(out ATrackIndex: Integer): Boolean;

implementation

type
  TUndoSnapshot = record
    TrackIndex: Integer;
    Clips: TClipArray;
  end;

var
  UndoStack: array of TUndoSnapshot;

function AddSampleToPool(const ASample: TSample; const AName: string): Integer;
begin
  SetLength(SamplePool, Length(SamplePool) + 1);
  SetLength(SampleNames, Length(SampleNames) + 1);
  Result := High(SamplePool);
  SamplePool[Result] := ASample;
  SampleNames[Result] := AName;
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

end.
