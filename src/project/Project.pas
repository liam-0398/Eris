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

  { Send buses. Two of them, fixed - the point of a send is that one
    expensive effect chain serves many tracks, and two is what a 90s desk
    with a pair of aux buses gave you. Any track can feed either. }
  SendCount = 2;

  { Effect-chain targets. Every "which chain am I editing / adding to"
    integer in this program uses this convention: >= 0 is a track index,
    and these negatives are the buses. Predates the sends (the master bus
    was already -2 by convention, spelled as a bare literal); named here so
    the send rows could join it without adding a second scheme. }
  BusMaster = -2;
  BusSendFirst = -3;
  { send bus index S (0-based) is target BusSendFirst - S, so S1 = -3 and
    S2 = -4 - see BusToSendIndex/SendIndexToBus }
  BusSendLast = BusSendFirst - (SendCount - 1);

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

  { dominant fundamental period per sample in frames (0 = none found) -
    computed once at load like SampleTransients, used only by the Tones
    ("LF") warp mode to place grains on whole waveform periods }
  SamplePeriods: array of Integer;
  TempoBPM: Single = DefaultTempoBPM;

  { tracks that have been deleted are marked as inactive; used to maintain
    track numbering so deleted track numbers are never reused }
  TrackActive: array[0..MaxTracks - 1] of Boolean;
  NextTrackID: Integer = 1;

  { keyboard-play instrument assigned to each track via the device panel;
    -1 means no instrument loaded }
  TrackInstrument: array[0..MaxTracks - 1] of Integer;
  TrackOctave: array[0..MaxTracks - 1] of Integer;
  { gain trim in dB for keyboard-played instrument notes, the instrument-side
    counterpart of a clip's own Gain slider - applied on top of TrackVolume
    when a note is triggered, so it trims the instrument without touching the
    track fader that timeline clips also go through. 0 = unity. }
  TrackInstrumentGainDb: array[0..MaxTracks - 1] of Single;
  { linear gain multiplier applied on top of each clip's own Gain; 1.0 = unity/default }
  TrackVolume: array[0..MaxTracks - 1] of Single;

  { trim points (in source sample frames) for the keyboard-play instrument on
    each track; default is the entire sample (Start=0, End=FrameCount) }
  TrackInstrumentStart: array[0..MaxTracks - 1] of Int64;
  TrackInstrumentEnd: array[0..MaxTracks - 1] of Int64;

  { simple mute toggle, shown on the track header in the arrangement view }
  TrackEnabled: array[0..MaxTracks - 1] of Boolean;

  { solo, the button immediately left of the mute on the track header. Any
    number of tracks can be soloed at once; while at least one is, every
    track that isn't soloed is silenced as if muted. Solo never clears a
    track's own mute, so a muted track stays muted even when soloed - see
    TrackAudible, which is the single test the mixer and the offline bounce
    both go through. }
  TrackSolo: array[0..MaxTracks - 1] of Boolean;

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

  { --- Send buses (S1/S2) -------------------------------------------------
    A send takes a copy of a track's signal, sums it with copies from every
    other track feeding the same send, runs that ONE sum through ONE effect
    chain, and returns the result to the master bus. Two things come out of
    that which per-track inserts can't give you:

    - every track on the send sits in the same space. A reverb fed from six
      tracks is one room they are all in, not six rooms that happen to have
      the same settings. For atmospheric jungle that IS the production
      technique - the break, the pads and the stabs sharing one long dark
      hall is what glues the record together.
    - it costs one reverb instead of six. A QuadraVerb Reverb per track is
      a real CPU bill; a QuadraVerb Reverb on a send is paid once however
      many tracks feed it.

    TrackSendLevel is how much of that track goes to the bus (0..1).
    TrackSendEnabled is the S1/S2 button on the track header - the level
    slider is ignored entirely while it's off, so a send can be armed at a
    useful level and then switched in and out without losing the setting. }
  TrackSendEnabled: array[0..MaxTracks - 1, 0..SendCount - 1] of Boolean;
  TrackSendLevel: array[0..MaxTracks - 1, 0..SendCount - 1] of Single;

  SendEffects: array[0..SendCount - 1, 0..Effects.MaxEffectsPerTrack - 1] of
    Effects.TEffect;
  SendEffectCount: array[0..SendCount - 1] of Integer;
  { how much of the processed bus comes back into the master, same 0..2
    linear range as TrackVolume so the two feel the same to drag }
  SendReturnLevel: array[0..SendCount - 1] of Single;
  { bus mute. Off means the bus is not mixed in AND its chain is skipped
    entirely, so muting a send you aren't using also gets the CPU back. }
  SendEnabled: array[0..SendCount - 1] of Boolean;
  { Pre-fader takes the tap before the track's own volume fader, post-fader
    after it. Post is the normal choice and the default. Pre is here because
    it's the one that matters for this music: with a pre-fader send you can
    pull a track's fader all the way down and its reverb tail keeps ringing
    on the bus, which is how you get a break to dissolve into the wash
    instead of just stopping. }
  SendPreFader: array[0..SendCount - 1] of Boolean;

function AddSampleToPool(const ASample: TSample; const AName, APath: string): Integer;
procedure CommitClipToTrack(ATrackIndex: Integer; const ANewClip: TClip);
procedure ReplaceTrackClips(ATrackIndex: Integer; const AClips: TClipArray);
procedure RemoveClipAt(ATrackIndex, AClipIndex: Integer);

function AddTrackEffect(ATrackIndex, AKind: Integer): Boolean;
procedure RemoveTrackEffect(ATrackIndex, AEffectIndex: Integer);
function AddMasterEffect(AKind: Integer): Boolean;
procedure RemoveMasterEffect(AEffectIndex: Integer);
function AddSendEffect(ASendIndex, AKind: Integer): Boolean;
procedure RemoveSendEffect(ASendIndex, AEffectIndex: Integer);

{ Bus target <-> send index. BusToSendIndex returns -1 for anything that
  isn't a send target, so callers can use it as the "is this a send?" test
  as well as the conversion. }
{ How many SOURCE frames a clip actually consumes, which is NOT AClip.Length.
  Length is a TIMELINE span - RescaleForTempoChange rewrites it to the last
  warp marker's TimelineFrame - so for any clip that has been warped or lived
  through a tempo change it no longer matches the stretch of sample sitting
  behind it. Anything indexing back into the source sample must use this:
  Offset + Length silently lands short of the real end when the tempo went up
  (the end marker stops midway through the sample) and past it when the tempo
  went down, where a bounds check quietly swaps in the whole sample instead. }
function ClipSourceLength(const AClip: TClip): Int64;
function BusToSendIndex(ATarget: Integer): Integer;
function SendIndexToBus(ASendIndex: Integer): Integer;

{ True while any track has solo engaged, i.e. while solo is doing anything
  at all. Callers in the audio path hoist this out of their track loop - it
  can't change within a block - rather than paying for the scan per track. }
function AnyTrackSoloed: Boolean;
{ Whether this track should be heard: not muted, and either soloed or with
  no solo active anywhere. The one place mute and solo are combined; every
  mixing path (realtime and bounce) gates on this rather than TrackEnabled.
  ASoloActive is AnyTrackSoloed, passed in so a loop over tracks evaluates
  it once. }
function TrackAudible(ATrackIndex: Integer; ASoloActive: Boolean): Boolean;

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

procedure InitSendBuses;
var
  s, i: Integer;
begin
  for s := 0 to SendCount - 1 do
  begin
    SendEffectCount[s] := 0;
    { same reasoning as InitTrackInstruments' slot blanking below }
    for i := 0 to Effects.MaxEffectsPerTrack - 1 do
      SendEffects[s][i].Kind := Effects.ekNone;
    { unity return and unmuted, so dropping an effect on a send and turning
      one track's S button on is audible immediately with nothing else set }
    SendReturnLevel[s] := 1.0;
    SendEnabled[s] := True;
    SendPreFader[s] := False;
    for i := 0 to MaxTracks - 1 do
    begin
      TrackSendEnabled[i][s] := False;
      { armed at a useful amount so the button alone does something - the
        slider is a trim on top, not a gate you have to find first }
      TrackSendLevel[i][s] := 0.5;
    end;
  end;
end;

{ Puts one track slot back to its just-created defaults. Covers EVERY
  per-track array in this unit, including the two AddTrack used to leave
  alone - the effect slots sitting behind TrackEffectCount, and the send
  enable/level pair - which is what let a re-used slot come back holding the
  previous occupant's inserts and sends. Shared by AddTrack and DeleteTrack
  so the slot a delete vacates and the slot the next add hands out are the
  same blank. Deliberately does not touch TrackActive: the two callers want
  opposite values for it. }
procedure ResetTrackSlot(ATrackIndex: Integer);
var
  e, s: Integer;
begin
  Tracks[ATrackIndex].Clips := nil;
  TrackInstrument[ATrackIndex] := -1;
  TrackOctave[ATrackIndex] := 0;
  TrackInstrumentGainDb[ATrackIndex] := 0;
  TrackVolume[ATrackIndex] := 1.0;
  TrackInstrumentStart[ATrackIndex] := 0;
  TrackInstrumentEnd[ATrackIndex] := 0;
  TrackEnabled[ATrackIndex] := True;
  TrackSolo[ATrackIndex] := False;
  TrackSwingPercent[ATrackIndex] := 50;
  TrackSwingDivision[ATrackIndex] := 16;
  TrackIsInput[ATrackIndex] := False;
  TrackMonitorEnabled[ATrackIndex] := False;
  TrackIsSampler[ATrackIndex] := False;
  ClearSamplerSlots(ATrackIndex);
  { blank the slots themselves and not just the count - same reasoning as
    InitTrackInstruments below }
  for e := 0 to Effects.MaxEffectsPerTrack - 1 do
    TrackEffects[ATrackIndex][e].Kind := Effects.ekNone;
  TrackEffectCount[ATrackIndex] := 0;
  for s := 0 to SendCount - 1 do
  begin
    TrackSendEnabled[ATrackIndex][s] := False;
    TrackSendLevel[ATrackIndex][s] := 0.5;
  end;
end;

procedure InitTrackInstruments;
var
  i, e: Integer;
begin
  for i := 0 to MaxTracks - 1 do
  begin
    { blank the slots themselves, not just the count. Everything that walks a
      chain stops at TrackEffectCount, but leaving the previous project's
      TEffect records sitting in the slots means the next AddTrackEffect
      lands on top of stale parameters, and any code that tests Kind <>
      ekNone (as the slot comment above promises it may) sees effects the new
      project doesn't have. }
    for e := 0 to Effects.MaxEffectsPerTrack - 1 do
      TrackEffects[i][e].Kind := Effects.ekNone;
    TrackActive[i] := i < DefaultTrackCount;
    TrackInstrument[i] := -1;
    TrackOctave[i] := 0;
    TrackInstrumentGainDb[i] := 0;
    TrackVolume[i] := 1.0;
    TrackInstrumentStart[i] := 0;
    TrackInstrumentEnd[i] := 0;
    TrackEnabled[i] := True;
    TrackSolo[i] := False;
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

function BusToSendIndex(ATarget: Integer): Integer;
begin
  if (ATarget <= BusSendFirst) and (ATarget >= BusSendLast) then
    Result := BusSendFirst - ATarget
  else
    Result := -1;
end;

function SendIndexToBus(ASendIndex: Integer): Integer;
begin
  Result := BusSendFirst - ASendIndex;
end;

function AnyTrackSoloed: Boolean;
var
  t: Integer;
begin
  Result := False;
  { only real tracks: DeleteTrack shifts the flags down and leaves the
    vacated slot above TrackCount holding whatever the old last track had,
    which would otherwise be a solo nothing on screen can switch back off }
  for t := 0 to TrackCount - 1 do
    if TrackSolo[t] then
      Exit(True);
end;

function TrackAudible(ATrackIndex: Integer; ASoloActive: Boolean): Boolean;
begin
  Result := TrackEnabled[ATrackIndex] and
    ((not ASoloActive) or TrackSolo[ATrackIndex]);
end;

function AddSendEffect(ASendIndex, AKind: Integer): Boolean;
var
  Slot: Integer;
begin
  if (ASendIndex < 0) or (ASendIndex >= SendCount) then
    Exit(False);
  if SendEffectCount[ASendIndex] >= Effects.MaxEffectsPerTrack then
    Exit(False);
  Slot := SendEffectCount[ASendIndex];
  Effects.DefaultEffect(AKind, SendEffects[ASendIndex][Slot]);
  Inc(SendEffectCount[ASendIndex]);
  Result := True;
end;

procedure RemoveSendEffect(ASendIndex, AEffectIndex: Integer);
var
  j: Integer;
begin
  if (ASendIndex < 0) or (ASendIndex >= SendCount) then
    Exit;
  if (AEffectIndex < 0) or (AEffectIndex >= SendEffectCount[ASendIndex]) then
    Exit;
  for j := AEffectIndex to SendEffectCount[ASendIndex] - 2 do
    SendEffects[ASendIndex][j] := SendEffects[ASendIndex][j + 1];
  Dec(SendEffectCount[ASendIndex]);
  SendEffects[ASendIndex][SendEffectCount[ASendIndex]].Kind := Effects.ekNone;
end;

function AddSampleToPool(const ASample: TSample; const AName, APath: string): Integer;
begin
  SetLength(SamplePool, Length(SamplePool) + 1);
  SetLength(SampleNames, Length(SampleNames) + 1);
  SetLength(SamplePaths, Length(SamplePaths) + 1);
  SetLength(SamplePeaks, Length(SamplePeaks) + 1);
  SetLength(SampleTransients, Length(SampleTransients) + 1);
  SetLength(SamplePeriods, Length(SamplePeriods) + 1);
  Result := High(SamplePool);
  SamplePool[Result] := ASample;
  SampleNames[Result] := AName;
  SamplePaths[Result] := APath;
  SamplePeaks[Result] := ComputeWaveformPeaks(ASample);
  SampleTransients[Result] := DetectTransients(ASample.Data, ASample.FrameCount,
    ASample.Channels, ASample.SampleRate);
  SamplePeriods[Result] := DetectFundamentalPeriod(ASample.Data,
    ASample.FrameCount, ASample.Channels, ASample.SampleRate);
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
  ResetTrackSlot(TrackCount);
  TrackActive[TrackCount] := True;
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

{ A sidechain names its source as a raw track index, so the shift a delete
  performs moves the track out from under every chain keyed off one: without
  this a compressor keyed to track 5 silently starts ducking to whatever
  moved down into slot 5. Walks every chain in the project - tracks, master
  and both sends - because any of them can carry an ekSidechain.

  A chain keyed off the track being DELETED has nothing left to follow.
  There is no "no source" value for this field (the rack's picker is a plain
  list of tracks, index = track), so it falls back to track 0, exactly where
  a freshly added sidechain starts. }
procedure RemapSidechainSourcesForDelete(ADeletedIndex: Integer);

  procedure Remap(var AEffect: Effects.TEffect);
  begin
    if AEffect.SidechainSourceTrack > ADeletedIndex then
      Dec(AEffect.SidechainSourceTrack)
    else if AEffect.SidechainSourceTrack = ADeletedIndex then
      AEffect.SidechainSourceTrack := 0;
  end;

var
  t, s, e: Integer;
begin
  for t := 0 to TrackCount - 1 do
    for e := 0 to TrackEffectCount[t] - 1 do
      Remap(TrackEffects[t][e]);
  for e := 0 to MasterEffectCount - 1 do
    Remap(MasterEffects[e]);
  for s := 0 to SendCount - 1 do
    for e := 0 to SendEffectCount[s] - 1 do
      Remap(SendEffects[s][e]);
end;

{ Undo snapshots are stored against a track INDEX, so the same shift leaves
  every entry above the deleted track pointing one track too high - an Undo
  after a delete would restore its clips onto a neighbour. Entries belonging
  to the deleted track itself have nothing to be restored to and are dropped. }
procedure RemapUndoStackForDelete(ADeletedIndex: Integer);
var
  i, k: Integer;
begin
  k := 0;
  for i := 0 to High(UndoStack) do
  begin
    if UndoStack[i].TrackIndex = ADeletedIndex then
      Continue;
    UndoStack[k] := UndoStack[i];
    if UndoStack[k].TrackIndex > ADeletedIndex then
      Dec(UndoStack[k].TrackIndex);
    Inc(k);
  end;
  SetLength(UndoStack, k);
end;

function DeleteTrack(ATrackIndex: Integer): Boolean;
var
  t: Integer;
begin
  if (ATrackIndex < 0) or (ATrackIndex >= TrackCount) or not TrackActive[ATrackIndex] then
    Exit(False);

  { no "mark this index inactive" step: the shift below overwrites the slot
    outright, and the slot that ends up genuinely unused is the one at the
    top, cleared after it }
  for t := ATrackIndex to TrackCount - 2 do
  begin
    Tracks[t] := Tracks[t + 1];
    TrackActive[t] := TrackActive[t + 1];
    TrackInstrument[t] := TrackInstrument[t + 1];
    TrackOctave[t] := TrackOctave[t + 1];
    TrackInstrumentGainDb[t] := TrackInstrumentGainDb[t + 1];
    TrackVolume[t] := TrackVolume[t + 1];
    TrackInstrumentStart[t] := TrackInstrumentStart[t + 1];
    TrackInstrumentEnd[t] := TrackInstrumentEnd[t + 1];
    TrackEnabled[t] := TrackEnabled[t + 1];
    TrackSolo[t] := TrackSolo[t + 1];
    TrackEffectCount[t] := TrackEffectCount[t + 1];
    TrackSwingPercent[t] := TrackSwingPercent[t + 1];
    TrackSwingDivision[t] := TrackSwingDivision[t + 1];
    TrackIsInput[t] := TrackIsInput[t + 1];
    TrackMonitorEnabled[t] := TrackMonitorEnabled[t + 1];
    TrackIsSampler[t] := TrackIsSampler[t + 1];
    Move(TrackSamplerSlots[t + 1, 0], TrackSamplerSlots[t, 0], SizeOf(TrackSamplerSlots[t]));
    Move(TrackEffects[t + 1, 0], TrackEffects[t, 0], SizeOf(TrackEffects[t]));
    Move(TrackSendEnabled[t + 1, 0], TrackSendEnabled[t, 0], SizeOf(TrackSendEnabled[t]));
    Move(TrackSendLevel[t + 1, 0], TrackSendLevel[t, 0], SizeOf(TrackSendLevel[t]));
  end;

  Dec(TrackCount);
  { The shift copied every track down over its predecessor but left the top
    slot holding a full duplicate of what used to be the last track - its
    clips, its mute, its solo, its inserts and its sends - and nothing on
    screen reaches that slot any more. It is not dormant: the mixer walks all
    MaxTracks slots and gates only on TrackEnabled, so a stale enabled
    duplicate up there is audio no header can mute (AnyTrackSoloed stops at
    TrackCount, but nothing else does). Blank it. }
  ResetTrackSlot(TrackCount);
  TrackActive[TrackCount] := False;

  { everything else in the project that stores a track index has just been
    renumbered out from under it }
  RemapSidechainSourcesForDelete(ATrackIndex);
  RemapUndoStackForDelete(ATrackIndex);
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
  SetLength(SamplePeriods, 0);
  SetLength(UndoStack, 0);

  for i := 0 to MaxTracks - 1 do
    Tracks[i].Clips := nil;

  TrackCount := DefaultTrackCount;
  NextTrackID := DefaultTrackCount + 1;
  InitTrackInstruments;
  InitSendBuses;
  MasterEffectCount := 0;
  { as with the track and send chains, blank the slots and not just the count }
  for i := 0 to Effects.MaxEffectsPerTrack - 1 do
    MasterEffects[i].Kind := Effects.ekNone;
  TempoBPM := DefaultTempoBPM;
end;

function ClipSourceLength(const AClip: TClip): Int64;
begin
  { markers are relative to Offset and start at SourceFrame 0, so the last
    one's SourceFrame is the source-frame count - see RescaleForTempoChange,
    which seeds exactly that pair for a clip that had no markers yet }
  if System.Length(AClip.WarpMarkers) >= 2 then
    Result := AClip.WarpMarkers[High(AClip.WarpMarkers)].SourceFrame
  else
    Result := AClip.Length;
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
  InitSendBuses;

end.
