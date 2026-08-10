unit Project;

{$mode objfpc}{$H+}

interface

uses
  SampleTypes, ClipOverwrite, Waveform, Effects;

const
  MaxTracks = 32;
  DefaultTrackCount = 4;
  DefaultTempoBPM = 160.0;
  SamplerKeysPerOctave = 12;

type
  TTrack = record
    Clips: TClipArray;
  end;

  { One key of a Sampler Track's one-octave key bank. SampleID = -1 means the
    key is empty (silent). StartFrame/EndFrame are trim points into the
    source sample, same meaning as TrackInstrumentStart/End below - the key
    plays that trimmed span at whatever rate TrackOctave (plus the pressed
    key's own octave, see MainForm.TriggerSamplerKeyNote) works out to. }
  TSamplerSlot = record
    SampleID: Integer;
    StartFrame, EndFrame: Int64;
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
  { detected transient/onset positions per sample, in source frames - used to
    place Beats-mode grain boundaries on real attacks instead of an
    arbitrary fixed grid. Computed once at load time, like SamplePeaks. }
  SampleTransients: array of TFrameArray;
  TempoBPM: Single = DefaultTempoBPM;

  { tracks that have been deleted are marked as inactive; used to maintain
    track numbering so deleted track numbers are never reused }
  TrackActive: array[0..MaxTracks - 1] of Boolean;
  NextTrackID: Integer = 1;

  { keyboard-play instrument assigned to each track via the device panel;
    -1 means no instrument loaded }
  TrackInstrument: array[0..MaxTracks - 1] of Integer;
  TrackOctave: array[0..MaxTracks - 1] of Integer;
  { linear gain multiplier applied on top of each clip's own Gain; 1.0 = unity/default }
  TrackVolume: array[0..MaxTracks - 1] of Single;

  { trim points (in source sample frames) for the keyboard-play instrument on
    each track; default is the entire sample (Start=0, End=FrameCount) }
  TrackInstrumentStart: array[0..MaxTracks - 1] of Int64;
  TrackInstrumentEnd: array[0..MaxTracks - 1] of Int64;

  { simple mute toggle, shown on the track header in the arrangement view }
  TrackEnabled: array[0..MaxTracks - 1] of Boolean;

  { Input Track: records from the live capture device (ALSA line-in for now)
    instead of from its own keyboard-played/timeline audio - see AudioEngine's
    RecL/RecR record tap and the "M" input-monitor button on the track header.
    TrackMonitorEnabled routes the live captured signal straight into this
    track's mix (post-tap, pre-insert-FX) with no playhead movement and no
    recording required, so it also doubles as headphone monitoring while
    actually recording. Meaningful only when TrackIsInput is set, but stored
    per track like every other track flag here. }
  TrackIsInput: array[0..MaxTracks - 1] of Boolean;
  TrackMonitorEnabled: array[0..MaxTracks - 1] of Boolean;

  { Sampler Track: a track dedicated entirely to a one-octave bank of
    keyboard-played samples (see MainForm's sampler device-panel widget and
    TriggerSamplerKeyNote) instead of the normal single-instrument keyboard
    play above - set only at track-creation time via AddSamplerTrack,
    mirroring TrackIsInput/AddInputTrack, and never combined with
    TrackInstrument/TrackIsInput on the same track. }
  TrackIsSampler: array[0..MaxTracks - 1] of Boolean;
  TrackSamplerSlots: array[0..MaxTracks - 1, 0..SamplerKeysPerOctave - 1] of TSamplerSlot;

  { SP-1200-style swing: delays every other grid step's clips later by a
    percentage. 50 = straight/off, 54..71 mirror the SP-1200's own five
    detents, 75 is the theoretical ceiling (off-step lands exactly on the
    next step - see AudioEngine.SwungPosition). SwingDivision is the grid
    unit swing pairs up (8 = 8th notes, 16 = 16th notes, the default). }
  TrackSwingPercent: array[0..MaxTracks - 1] of Single;
  TrackSwingDivision: array[0..MaxTracks - 1] of Integer;

  { per-track insert effects chain - a fixed number of ordered slots per
    track, Kind = ekNone marks an unused slot beyond TrackEffectCount }
  TrackEffects: array[0..MaxTracks - 1, 0..Effects.MaxEffectsPerTrack - 1] of
    Effects.TEffect;
  TrackEffectCount: array[0..MaxTracks - 1] of Integer;

  { master bus insert chain - applied to the final mix, after every track's
    own inserts, before the SP1200 emulation (a separate, always-on system) }
  MasterEffects: array[0..Effects.MaxEffectsPerTrack - 1] of Effects.TEffect;
  MasterEffectCount: Integer;

function AddSampleToPool(const ASample: TSample; const AName, APath: string): Integer;
procedure CommitClipToTrack(ATrackIndex: Integer; const ANewClip: TClip);
procedure ReplaceTrackClips(ATrackIndex: Integer; const AClips: TClipArray);
procedure RemoveClipAt(ATrackIndex, AClipIndex: Integer);

function AddTrackEffect(ATrackIndex, AKind: Integer): Boolean;
procedure RemoveTrackEffect(ATrackIndex, AEffectIndex: Integer);
function AddMasterEffect(AKind: Integer): Boolean;
procedure RemoveMasterEffect(AEffectIndex: Integer);

procedure PushUndoSnapshot(ATrackIndex: Integer);
function PopUndo(out ATrackIndex: Integer): Boolean;

function AddTrack: Boolean;
function AddInputTrack: Boolean;
function AddSamplerTrack: Boolean;
procedure AssignSamplerSlot(ATrackIndex, AKeyIndex, ASampleID: Integer;
  AStartFrame, AEndFrame: Int64);
function DeleteTrack(ATrackIndex: Integer): Boolean;
procedure NewProject;

{ Ableton-style tempo change: rescales every clip's Position/Length and warp
  markers' TimelineFrame (never SourceFrame/Offset - those are source-domain
  and tempo-independent) by AOldBPM/ANewBPM, so the whole arrangement plays
  back faster/slower while staying locked to the same bars/beats, instead of
  just moving the ruler labels underneath an unchanged recording. A clip
  that was never explicitly warped gets a synthesized whole-clip warp first
  (matching Ableton's own default Beats/pitch-preserving behavior) so it
  actually stretches instead of just getting truncated/left short. }
procedure RescaleForTempoChange(AOldBPM, ANewBPM: Single);

implementation

type
  TUndoSnapshot = record
    TrackIndex: Integer;
    Clips: TClipArray;
  end;

var
  UndoStack: array of TUndoSnapshot;

procedure ClearSamplerSlots(ATrackIndex: Integer);
var
  k: Integer;
begin
  for k := 0 to SamplerKeysPerOctave - 1 do
  begin
    TrackSamplerSlots[ATrackIndex][k].SampleID := -1;
    TrackSamplerSlots[ATrackIndex][k].StartFrame := 0;
    TrackSamplerSlots[ATrackIndex][k].EndFrame := 0;
  end;
end;

procedure InitTrackInstruments;
var
  i: Integer;
begin
  for i := 0 to MaxTracks - 1 do
  begin
    TrackActive[i] := i < DefaultTrackCount;
    TrackInstrument[i] := -1;
    TrackOctave[i] := 0;
    TrackVolume[i] := 1.0;
    TrackInstrumentStart[i] := 0;
    TrackInstrumentEnd[i] := 0;
    TrackEnabled[i] := True;
    TrackEffectCount[i] := 0;
    TrackSwingPercent[i] := 50;
    TrackSwingDivision[i] := 16;
    TrackIsInput[i] := False;
    TrackMonitorEnabled[i] := False;
    TrackIsSampler[i] := False;
    ClearSamplerSlots(i);
  end;
end;

function AddTrackEffect(ATrackIndex, AKind: Integer): Boolean;
var
  Slot: Integer;
begin
  if (ATrackIndex < 0) or (ATrackIndex >= MaxTracks) then
    Exit(False);
  if TrackEffectCount[ATrackIndex] >= Effects.MaxEffectsPerTrack then
    Exit(False);
  Slot := TrackEffectCount[ATrackIndex];
  Effects.DefaultEffect(AKind, TrackEffects[ATrackIndex][Slot]);
  Inc(TrackEffectCount[ATrackIndex]);
  Result := True;
end;

procedure RemoveTrackEffect(ATrackIndex, AEffectIndex: Integer);
var
  j: Integer;
begin
  if (ATrackIndex < 0) or (ATrackIndex >= MaxTracks) then
    Exit;
  if (AEffectIndex < 0) or (AEffectIndex >= TrackEffectCount[ATrackIndex]) then
    Exit;
  for j := AEffectIndex to TrackEffectCount[ATrackIndex] - 2 do
    TrackEffects[ATrackIndex][j] := TrackEffects[ATrackIndex][j + 1];
  Dec(TrackEffectCount[ATrackIndex]);
  TrackEffects[ATrackIndex][TrackEffectCount[ATrackIndex]].Kind := Effects.ekNone;
end;

function AddMasterEffect(AKind: Integer): Boolean;
var
  Slot: Integer;
begin
  if MasterEffectCount >= Effects.MaxEffectsPerTrack then
    Exit(False);
  Slot := MasterEffectCount;
  Effects.DefaultEffect(AKind, MasterEffects[Slot]);
  Inc(MasterEffectCount);
  Result := True;
end;

procedure RemoveMasterEffect(AEffectIndex: Integer);
var
  j: Integer;
begin
  if (AEffectIndex < 0) or (AEffectIndex >= MasterEffectCount) then
    Exit;
  for j := AEffectIndex to MasterEffectCount - 2 do
    MasterEffects[j] := MasterEffects[j + 1];
  Dec(MasterEffectCount);
  MasterEffects[MasterEffectCount].Kind := Effects.ekNone;
end;

function AddSampleToPool(const ASample: TSample; const AName, APath: string): Integer;
begin
  SetLength(SamplePool, Length(SamplePool) + 1);
  SetLength(SampleNames, Length(SampleNames) + 1);
  SetLength(SamplePaths, Length(SamplePaths) + 1);
  SetLength(SamplePeaks, Length(SamplePeaks) + 1);
  SetLength(SampleTransients, Length(SampleTransients) + 1);
  Result := High(SamplePool);
  SamplePool[Result] := ASample;
  SampleNames[Result] := AName;
  SamplePaths[Result] := APath;
  SamplePeaks[Result] := ComputeWaveformPeaks(ASample);
  SampleTransients[Result] := DetectTransients(ASample.Data, ASample.FrameCount,
    ASample.Channels, ASample.SampleRate);
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
  TrackActive[TrackCount] := True;
  TrackInstrument[TrackCount] := -1;
  TrackOctave[TrackCount] := 0;
  TrackVolume[TrackCount] := 1.0;
  TrackInstrumentStart[TrackCount] := 0;
  TrackInstrumentEnd[TrackCount] := 0;
  TrackEnabled[TrackCount] := True;
  TrackEffectCount[TrackCount] := 0;
  TrackSwingPercent[TrackCount] := 50;
  TrackSwingDivision[TrackCount] := 16;
  TrackIsInput[TrackCount] := False;
  TrackMonitorEnabled[TrackCount] := False;
  TrackIsSampler[TrackCount] := False;
  ClearSamplerSlots(TrackCount);
  Inc(TrackCount);
  Inc(NextTrackID);
  Result := True;
end;

function AddInputTrack: Boolean;
begin
  Result := AddTrack;
  if Result then
    TrackIsInput[TrackCount - 1] := True;
end;

function AddSamplerTrack: Boolean;
begin
  Result := AddTrack;
  if Result then
    TrackIsSampler[TrackCount - 1] := True;
end;

procedure AssignSamplerSlot(ATrackIndex, AKeyIndex, ASampleID: Integer;
  AStartFrame, AEndFrame: Int64);
begin
  if (ATrackIndex < 0) or (ATrackIndex >= MaxTracks) then
    Exit;
  if (AKeyIndex < 0) or (AKeyIndex >= SamplerKeysPerOctave) then
    Exit;
  if (ASampleID < 0) or (ASampleID > High(SamplePool)) then
    Exit;
  if AStartFrame < 0 then
    AStartFrame := 0;
  { AEndFrame is normally the source clip's own Offset+Length (its trim
    window), so the key's end marker auto-populates at wherever that clip
    was cut, not always the whole underlying sample - only fall back to the
    full sample when the caller didn't have a sensible window (e.g. a fresh
    import with no clip behind it) or passed something bogus. }
  if (AEndFrame <= AStartFrame) or (AEndFrame > SamplePool[ASampleID].FrameCount) then
    AEndFrame := SamplePool[ASampleID].FrameCount;
  { drop onto an occupied key replaces it outright - no stacking/round-robin }
  TrackSamplerSlots[ATrackIndex][AKeyIndex].SampleID := ASampleID;
  TrackSamplerSlots[ATrackIndex][AKeyIndex].StartFrame := AStartFrame;
  TrackSamplerSlots[ATrackIndex][AKeyIndex].EndFrame := AEndFrame;
end;

function DeleteTrack(ATrackIndex: Integer): Boolean;
var
  t: Integer;
begin
  if (ATrackIndex < 0) or (ATrackIndex >= TrackCount) or not TrackActive[ATrackIndex] then
    Exit(False);

  TrackActive[ATrackIndex] := False;

  for t := ATrackIndex to TrackCount - 2 do
  begin
    Tracks[t] := Tracks[t + 1];
    TrackActive[t] := TrackActive[t + 1];
    TrackInstrument[t] := TrackInstrument[t + 1];
    TrackOctave[t] := TrackOctave[t + 1];
    TrackVolume[t] := TrackVolume[t + 1];
    TrackInstrumentStart[t] := TrackInstrumentStart[t + 1];
    TrackInstrumentEnd[t] := TrackInstrumentEnd[t + 1];
    TrackEnabled[t] := TrackEnabled[t + 1];
    TrackEffectCount[t] := TrackEffectCount[t + 1];
    TrackSwingPercent[t] := TrackSwingPercent[t + 1];
    TrackSwingDivision[t] := TrackSwingDivision[t + 1];
    TrackIsInput[t] := TrackIsInput[t + 1];
    TrackMonitorEnabled[t] := TrackMonitorEnabled[t + 1];
    TrackIsSampler[t] := TrackIsSampler[t + 1];
    Move(TrackSamplerSlots[t + 1, 0], TrackSamplerSlots[t, 0], SizeOf(TrackSamplerSlots[t]));
    Move(TrackEffects[t + 1, 0], TrackEffects[t, 0], SizeOf(TrackEffects[t]));
  end;

  Dec(TrackCount);
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
  SetLength(SampleTransients, 0);
  SetLength(UndoStack, 0);

  for i := 0 to MaxTracks - 1 do
    Tracks[i].Clips := nil;

  TrackCount := DefaultTrackCount;
  NextTrackID := DefaultTrackCount + 1;
  InitTrackInstruments;
  MasterEffectCount := 0;
  TempoBPM := DefaultTempoBPM;
end;

procedure RescaleForTempoChange(AOldBPM, ANewBPM: Single);
var
  Ratio: Double;
  t, i, m: Integer;
  Clip: TClip;
begin
  if (AOldBPM <= 0) or (ANewBPM <= 0) or (AOldBPM = ANewBPM) then
    Exit;
  { frames-per-beat = SampleRate*60/BPM, so a frame position at a fixed beat
    scales by OldBPM/NewBPM - raise tempo, everything happens in fewer
    frames, i.e. sooner/faster }
  Ratio := AOldBPM / ANewBPM;

  for t := 0 to TrackCount - 1 do
  begin
    if Length(Tracks[t].Clips) = 0 then
      Continue;
    PushUndoSnapshot(t);
    for i := 0 to High(Tracks[t].Clips) do
    begin
      Clip := Tracks[t].Clips[i];

      if Length(Clip.WarpMarkers) < 2 then
      begin
        SetLength(Clip.WarpMarkers, 2);
        Clip.WarpMarkers[0].SourceFrame := 0;
        Clip.WarpMarkers[0].TimelineFrame := 0;
        Clip.WarpMarkers[1].SourceFrame := Clip.Length;
        Clip.WarpMarkers[1].TimelineFrame := Round(Clip.Length * Ratio);
      end
      else
        for m := 0 to High(Clip.WarpMarkers) do
          Clip.WarpMarkers[m].TimelineFrame :=
            Round(Clip.WarpMarkers[m].TimelineFrame * Ratio);

      { keep Length exactly matching the last marker's TimelineFrame -
        everything downstream assumes they agree exactly }
      Clip.Length := Clip.WarpMarkers[High(Clip.WarpMarkers)].TimelineFrame;
      Clip.Position := Round(Clip.Position * Ratio);

      Tracks[t].Clips[i] := Clip;
    end;
  end;
end;

initialization
  InitTrackInstruments;

end.
