unit DysTimeline;

{ Center pane. Stage 7: a real grid - one row per track, a seconds ruler on
  top, committed clips drawn as solid blocks. A file dropped from the file
  pane arrives here as a "pending" (hovering) clip on the track the file
  pane's Enter selected - Left/Right nudges it along the grid, Up/Down
  changes which track it would land on, Enter commits it and pushes the
  track to the engine, Esc cancels it. Drag mode (Ctrl+S) stays a stub -
  that's selection editing, stage 8.

  The grid step Left/Right nudges by is wired to the toolbar's interval
  selector (GridStepFrames); zoom (PxPerSec, +/-) and horizontal scroll
  (ViewStartFrame, autoscrolling to follow the playhead during playback)
  are both runtime-adjustable - see tui.md's most recent session note.

  The per-row label (LabelWidth columns wide) is a single track-type
  letter - A/I/S, see TrackTypeChar - derived fresh from Project state on
  every Draw rather than cached, so it tracks Ctrl+I in the file pane (or
  anything else that flips TrackIsSampler/TrackInstrument) with no extra
  wiring. The track cursor (CursorTrack + CursorInLabel) is two-
  dimensional: Up/Down always moves CursorTrack, Left/Right move between
  the label column and the grid, and Ctrl+Enter/right-click open the track
  dropdown for CursorTrack from either position - see tui.md's Bindings.

  'w' re-warps the clip under the cursor to the nearest power-of-two bar
  count (WarpClipToNearestPow2Bar); 'l' cycles a transport loop range
  start/end/clear at the cursor's frame (LoopStart/LoopEnd). Committed
  clips are shaded per-TRACK (TrackColorAttr/TrackColors, randomly assigned
  once at startup - same idea as Eris's own ArrangementView.FTrackColors,
  src/ui) rather than one fixed colour, with a grey marker at every clip's
  own leading column (DrawClipStartMarker) so two same-track clips placed
  back-to-back still read as two clips, not one - see tui.md's Bindings and
  Free Vision notes for all four. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Dialogs, MsgBox, DysWidgets, Project,
  SampleTypes, AudioEngine, Waveform;

const
  { Startup timeline scale, in terminal columns per second of audio - now
    adjustable at runtime (see PxPerSec, SetZoom, the '+'/'-' keys) rather
    than the fixed constant this used to be. Kept as the field's initial
    value and SetZoom's implicit "back to default" reference point. }
  DefaultPixelsPerSecond = 10;
  MinPixelsPerSecond = 1;
  MaxPixelsPerSecond = 100;
  LabelWidth = 5;

type
  PDysTimelineContent = ^TDysTimelineContent;
  TDysTimelineContent = object(TView)
    CursorTrack: Integer;
    CursorFrame: Int64;
    { True: the track cursor sits on the A/I/S label column (Up/Down only).
      False: it sits in the grid at CursorFrame (Left/Right nudge it, and it
      can walk back onto the label column at CursorFrame = 0). See the unit
      header comment. }
    CursorInLabel: Boolean;
    Pending: Boolean;
    PendingSampleID: Integer;
    PendingLength: Int64;
    { Runtime zoom level (columns/second) and its derived frames-per-column -
      see SetZoom. Both replace what used to be the fixed PixelsPerSecond
      constant. }
    PxPerSec: Integer;
    FramesPerCol: Int64;
    { The frame drawn at the leftmost grid column (LabelWidth) - horizontal
      scroll position. 0 until something moves it: manual nudging past the
      visible edge (EnsureFrameVisible) or the playhead auto-following
      during playback (UpdatePlayhead). }
    ViewStartFrame: Int64;
    ShowPlayhead: Boolean;
    PlayheadFrame: Int64;
    { Transport loop range, -1 = unset - there's no per-clip/per-track loop
      concept in Project.pas to hook into (checked porting this from Eris),
      so this mirrors ArrangementView's own FLoopStart/FLoopEnd instead:
      global range pushed straight to AudioEngineSetLoop/AudioEngineClearLoop.
      See the 'l' key and tui.md's Bindings. }
    LoopStart: Int64;
    LoopEnd: Int64;
    { Shift+W: interactive re-warp of the clip under the cursor, mirroring
      BeginOverlay/Pending's "blink until solidified" pattern instead of
      warping straight to the nearest power-of-two bar (that's still plain
      'w' - WarpClipToNearestPow2Bar). Left/Right grow/shrink ResizeLength by
      GridStepFrames (so it stays grid-snapped the whole time, same
      convention the cursor's own Left/Right already use); Enter solidifies
      by resampling the clip to ResizeLength via WarpClipToLength (the same
      two-WarpMarker mechanism 'w' uses, just targeting an arbitrary grid-
      snapped length instead of a power-of-two bar count); Esc cancels. }
    ResizeActive: Boolean;
    ResizeTrack: Integer;
    ResizeClipIndex: Integer;
    ResizeLength: Int64;
    { 'm': interactive move of the clip under the cursor, same blink-until-
      solidified shape as resize above. Left/Right nudge MovePosition by
      GridStepFrames; Enter solidifies by removing the clip from its old
      slot and re-committing it at MovePosition (CommitClipToTrack's own
      OverwriteClips handles anything already sitting at the destination,
      same as Paste); Esc cancels. }
    MoveActive: Boolean;
    MoveTrack: Integer;
    MoveClipIndex: Integer;
    MoveLength: Int64;
    MovePosition: Int64;
    { 'k': marks the clip under the cursor as the one whose waveform is
      shown in the bottom pane's waveform widget (Ctrl+W toggles that pane
      between it and the effects rack - see DysWidgets/DysEffectsRack).
      Blinks (MarkedAttr) the same "still there, just visually flagged"
      way Pending/ResizeActive/MoveActive's spans do, but unlike those
      three this isn't a transient edit-in-progress state that gets
      cleared on commit/Esc - it just sits on whatever clip was last
      marked until something else marks a different one. -1 = nothing
      marked. Bounds-checked against the track's current clip count on
      every Draw rather than cleared on every edit that could invalidate
      it (split/delete/duplicate shifting indices) - simpler, and a stale
      mark just stops rendering rather than pointing at the wrong clip. }
    MarkedTrack: Integer;
    MarkedClipIndex: Integer;
    procedure MarkClipUnderCursor;
    constructor Init(Bounds: TRect);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure BeginOverlay(ASampleID: Integer; ALength: Int64);
    procedure CancelOverlay;
    procedure PlaceOverlay;
    { Clip manipulation "under the cursor" - all five key off the same clip
      lookup (ClipIndexAtFrame at CursorTrack/CursorFrame) and the same
      cursor-frame convention 'l' already established (see tui.md's
      Bindings). Ported from ArrangementView's Copy/Paste/Duplicate/Split/
      DeleteSelection (src/ui) simplified for a single cursor instead of a
      selection: there's no multi-clip range-select here, so the clipboard
      only ever holds one clip. Public so both the direct keys (HandleEvent)
      and the Edit menu (DysnomiaApp, routed through ActiveTimelineContent)
      call the same implementation, same as Eris's MainForm/ArrangementView
      split. }
    procedure CopyClipUnderCursor;
    procedure PasteClipAtCursor;
    procedure DuplicateClipUnderCursor;
    procedure SplitClipUnderCursor;
    procedure DeleteClipUnderCursor;
    { Enter while ResizeActive/MoveActive - see the field comments above. }
    procedure SolidifyResize;
    procedure SolidifyMove;
    { Whole-project version of PushTrackToEngine (below, private to this
      unit) - mirrors ArrangementView.RefreshAllTracks (src/ui), the "every
      track changed" call Eris's own MainForm makes after project open/New/
      tempo rescale. Dysnomia's RefreshAfterProjectChange (DysnomiaApp.pas)
      used to skip this entirely: it reset the cursor and redrew the panes,
      but never told the audio engine a single clip existed, so a freshly
      loaded project's clips were visible on the timeline (drawn straight
      from Project.Tracks) yet AudioEngineHasClip stayed False - Play
      silently did nothing, looking exactly like a locked transport. }
    procedure PushAllTracksToEngine;
    { Polled from TDysnomiaApp.Idle (see DysnomiaApp.pas) - Free Vision has
      no timer, but TProgram.Idle runs on every pass of the event loop that
      finds no key/mouse event waiting, which is close enough to "as fast
      as the terminal can be redrawn" for a playhead. Only redraws when the
      position or play/stopped state actually changed, since Idle fires far
      more often than that. }
    procedure UpdatePlayhead;
    { Timeline zoom (the '+'/'-' keys, see HandleEvent) - clamps to
      Min/MaxPixelsPerSecond, recomputes FramesPerCol, and re-anchors the
      scroll position so the cursor stays visible at the new scale. }
    procedure SetZoom(ANewPxPerSec: Integer);
    { Scrolls just enough (not a full re-centre) to bring AFrame back into
      the visible grid, used both after a manual cursor move past the
      current edge and by UpdatePlayhead's autoscroll. }
    procedure EnsureFrameVisible(AFrame: Int64);
    { How many frames the visible grid (Size.X - LabelWidth columns) spans
      at the current zoom - 0 before the view has ever been sized. }
    function VisibleFrameSpan: Int64;
    { Scrolls DysWidgets.ViewStartTrack (vertical, TRACK units) the minimum
      amount to bring ATrack's whole TrackHeight-row block back inside the
      grid - same "minimum nudge, not a re-centre" shape as EnsureFrameVisible.
      Called after Up/Down moves CursorTrack and after 'h'/'H' changes
      TrackHeight (a taller block can push the cursor's track off-screen even
      though CursorTrack itself didn't move). Redraws the track pane too,
      since it renders off the same ViewStartTrack/TrackHeight and would
      otherwise fall out of sync with the grid until something else redrew it. }
    procedure EnsureTrackVisible(ATrack: Integer);
    { PageUp/PageDown: scrolls ViewStartTrack by one screenful of tracks
      (ADelta = -1/+1) without moving CursorTrack UNLESS the cursor's track
      scrolled out of view, in which case it's clamped back onto the nearest
      now-visible track - see the field comment on ViewStartTrack in
      DysWidgets.pas for why scrolling only ever happens from here. }
    procedure ScrollTracksBy(ADelta: Integer);
    { The frame step Left/Right nudges the cursor (and a pending overlay)
      by - wired to the toolbar's interval cycle button (ActiveToolBar^.
      IntervalIdx: 1/4, 1/8, 1/16, 1 bar) instead of a fixed column, so the
      button actually does something (see tui.md). Falls back to one grid
      column if tempo/interval state isn't available yet. }
    function GridStepFrames: Int64;
  end;

  PDysTimeline = ^TDysTimeline;
  TDysTimeline = object(TDysPane)
    Content: PDysTimelineContent;
    constructor InitPane(Bounds: TRect);
  end;

{ Set once, by TDysTimelineContent.Init - there is exactly one timeline in
  this single-window app. DysFilePane reaches through this to hand off a
  freshly-loaded sample, the same way DysTrackPane.ActiveTrackPane exposes
  which track is selected - see tui.md's Free Vision notes on why globals
  rather than back-references between sibling panes. }
var
  ActiveTimelineContent: PDysTimelineContent = nil;

{ Wired to DysWidgets.TDysToolBar's Record button (see that unit's own
  StartRecordingProc/FinalizeRecordingProc comment for why the wiring is a
  callback var instead of a direct call: TDysToolBar lives in DysWidgets,
  which DysTimeline itself `uses` for TDysPane, so the reverse import would
  be circular). Live here rather than in DysEffectsRack.pas (which already
  hosts the other two toolbar callbacks) because both need PushTrackToEngine/
  TClip-building machinery that's private to this unit - moving THAT out
  instead would be the bigger, riskier change for no real benefit. }
procedure DysStartRecording;
procedure DysFinalizeRecording;

{ Ctrl+D/Ctrl+V on the waveform pane's own selection/paste-cursor - called
  from DysnomiaApp.pas's cmEditDuplicate/cmEditPaste, same routing as
  DysChopMarkedClipRegion (ChopWaveformSelectionProc) for Delete. See
  either procedure's own implementation comment. }
procedure DysDuplicateWaveformSelection;
procedure DysPasteWaveformClipboard;

implementation

uses
  DysTrackPane, DysEffectsRack;

{ The clip clipboard: a single TClip, not Eris's array-of-(RelTrack,TClip) -
  there's no multi-track range selection here to copy, just "the clip under
  the cursor" (see ClipIndexAtFrame), so one slot is enough. Position is
  rebased to 0 on copy and re-based to CursorFrame on paste, same convention
  ArrangementView.CopySelection/PasteSelection use. }
var
  ClipboardClip: TClip;
  ClipboardHasItem: Boolean = False;

const
  NormalAttr = $0F; { black bg, bright white fg - matches DysWidgets' PaneNorm }
  CursorAttr = $70; { light grey bg, black fg, no blink - matches PaneSel }
  { magenta bg, bright white fg, BLINKING (bit 7 set) - not placed yet.
    Every other attribute byte in this unit deliberately keeps bit 7 clear
    (see tui.md's "Palette cascade and the red-blink bug" - blink is
    normally an accident to avoid, since no stock CAppColor byte sets it).
    Here it's the opposite: a still-pending clip needs to read as visibly
    different from a committed one at a glance, not just a different
    hue - "blink until committed" (Enter/PlaceOverlay clears Pending and
    the block redraws in its real per-sample shade, see PlaceOverlay). }
  PendingAttr = $DF;
  { Blue bg, bright white fg, BLINKING - a distinct hue from PendingAttr's
    magenta so "marked for the waveform widget" (an indefinitely-lived
    flag) doesn't read as "still pending/being edited" (a transient
    edit-in-progress state that clears on Enter/Esc) - see MarkedTrack's
    own field comment. }
  MarkedAttr = $9F;
  PlayheadAttr = $4F; { red bg, bright white fg - distinct from both clip colours }
  LoopAttr = $2F; { green bg, bright white fg - transport loop markers }
  BlockChar = #219; { CP437 solid block - see tui.md "Half-block glyphs" }
  PlayheadChar = '|';
  LoopChar = 'L';

  { One random colour per TRACK (not per-sample - see TrackColors below),
    same idea as Eris's own ArrangementView.FTrackColors (src/ui), just
    drawn from the 16-colour CGA set instead of RGBToColor's full range.
    Excludes black/white/grey (reserved for ClipStartAttr's marker, below,
    so it's never mistaken for a track's own colour) and red/green (already
    PlayheadAttr/LoopAttr) - 8 remaining hues, saturated enough to stay
    readable on the black background every clip uses. }
  TrackColorPalette: array[0..7] of Byte =
    ($01, $02, $03, $05, $06, $09, $0B, $0D);
  { The clip's own leading column, always - not just where two same-colour
    clips happen to touch (the old DrawAdjoiningSeparators). Per-track
    colour means every clip on a track shares its neighbour's exact shade
    as the common case now, not a rare hash collision, so marking only
    actual adjacency stopped being enough: this marks EVERY clip's start,
    so two clips back-to-back are always visibly two clips. Grey, not
    black, so it reads as "a seam" rather than a gap of silence. }
  ClipStartAttr = $08; { black bg, dark grey fg }

var
  { Assigned once per track index at TDysTimelineContent.Init, same
    "Randomize, then one Random call per slot" as ArrangementView's own
    FTrackColors - see TrackColorPalette above. Session-only, like Eris's:
    not saved to the project, just needs to stay stable for as long as this
    run of the app is open. }
  TrackColors: array[0..Project.MaxTracks - 1] of Byte;

{ A/I/S per tui.md: Sampler Track wins over instrument (a track can carry
  both TrackIsSampler and a live TrackInstrument at once - see Project.pas's
  comment on TrackIsSampler - so the more specific classification takes
  priority), then a live keyboard-play instrument, else the plain default. }
function TrackTypeChar(ATrack: Integer): Char;
begin
  if (ATrack < 0) or (ATrack > High(Project.TrackIsSampler)) then
  begin
    Result := 'A';
    Exit;
  end;
  if Project.TrackIsSampler[ATrack] then
    Result := 'S'
  else if Project.TrackInstrument[ATrack] >= 0 then
    Result := 'I'
  else
    Result := 'A';
end;

function TrackColorAttr(ATrack: Integer): Word;
begin
  if (ATrack < 0) or (ATrack > High(TrackColors)) then
    Result := TrackColorPalette[0]
  else
    Result := TrackColors[ATrack];
end;

{ The clip-start grey marker - see ClipStartAttr. Called once per clip per
  SubRow from Draw's per-track loop, after that row's clips have already
  been filled in solid, so this always wins the top pixel of a clip's own
  leading edge regardless of what colour sits behind it. }
procedure DrawClipStartMarker(var B: TDrawBuffer; AFramesPerCol: Int64;
  AWidth: Integer; APos: Int64; AViewStart: Int64);
var
  Col: Integer;
begin
  if AFramesPerCol <= 0 then
    Exit;
  if APos < AViewStart then
    Exit; { off the left edge of the visible grid }
  Col := LabelWidth + ((APos - AViewStart) div AFramesPerCol);
  if (Col >= LabelWidth) and (Col <= AWidth - 1) then
    MoveChar(B[Col], BlockChar, ClipStartAttr, 1);
end;

{ Frames per bar at the project's current tempo, hardcoded to 4/4 like
  ArrangementView.BeatFrames/CurrentGridFrames (src/ui) - Project.pas has no
  time-signature field, and Eris doesn't either, so there's nothing else to
  read here. }
function BarFrames: Int64;
begin
  if Project.TempoBPM <= 0 then
  begin
    Result := 0;
    Exit;
  end;
  Result := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM) * 4;
end;

{ The clip on ATrack whose span covers AFrame, or -1. Same "is this frame
  inside [Position, Position+Length)" test PlaceOverlay's own commit uses
  implicitly, just as a lookup instead of an insert. }
function ClipIndexAtFrame(ATrack: Integer; AFrame: Int64): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(Project.Tracks[ATrack].Clips) do
    if (AFrame >= Project.Tracks[ATrack].Clips[i].Position) and
       (AFrame < Project.Tracks[ATrack].Clips[i].Position +
         Project.Tracks[ATrack].Clips[i].Length) then
    begin
      Result := i;
      Exit;
    end;
end;

{ Ported from ArrangementView.PushTrackToEngine (src/ui) - same translation
  from Project's TClip array to the engine's TPlaybackClip array, just not a
  method on an LCL control since none exists here. Kept a faithful copy
  (markers included, even though nothing here creates warped clips yet) so
  a later stage that adds warp editing to Dysnomia doesn't have to revisit
  this. }
procedure PushTrackToEngine(ATrackIndex: Integer);
var
  Items: PPlaybackClip;
  i, j, MarkerCount, Count: Integer;
  Clip: TClip;
  Sample: TSample;
begin
  Count := Length(Project.Tracks[ATrackIndex].Clips);
  if Count = 0 then
    Items := nil
  else
    GetMem(Items, Count * SizeOf(TPlaybackClip));

  for i := 0 to Count - 1 do
  begin
    Clip := Project.Tracks[ATrackIndex].Clips[i];
    { SampleID can be out of range of the pool for a project file that
      references a sample which failed to load - indexing unguarded here
      hands the engine a garbage Data/Transients pointer, which crashes the
      playback thread on the first block it renders (silently, since FPC
      kills a thread on an unhandled exception rather than propagating it) -
      Playing stays latched True with nothing left to advance the playhead.
      Treat an out-of-range SampleID the same as a resolved-but-empty
      sample: FrameCount 0, so the engine's own bounds checks play it as
      silence instead. }
    if Clip.SampleID <= High(Project.SamplePool) then
    begin
      Sample := Project.SamplePool[Clip.SampleID];
      Items[i].Data := Sample.Data;
      Items[i].FrameCount := Sample.FrameCount;
      Items[i].Channels := Sample.Channels;
    end
    else
    begin
      Items[i].Data := nil;
      Items[i].FrameCount := 0;
      Items[i].Channels := 0;
    end;
    Items[i].Offset := Clip.Offset;
    Items[i].Length := Clip.Length;
    Items[i].Position := Clip.Position;
    Items[i].Gain := Clip.Gain;
    Items[i].WarpMode := Clip.WarpMode;
    Items[i].DetuneSemitones := Clip.PitchSemitones;

    if Clip.SampleID <= High(Project.SamplePeriods) then
      Items[i].PeriodFrames := Project.SamplePeriods[Clip.SampleID]
    else
      Items[i].PeriodFrames := 0;

    if Clip.SampleID <= High(Project.SampleTransients) then
      Items[i].TransientCount := Length(Project.SampleTransients[Clip.SampleID])
    else
      Items[i].TransientCount := 0;
    if Items[i].TransientCount > 0 then
      Items[i].Transients := PInt64(Project.SampleTransients[Clip.SampleID])
    else
      Items[i].Transients := nil;

    MarkerCount := Length(Clip.WarpMarkers);
    if MarkerCount > MaxClipWarpMarkers then
      MarkerCount := MaxClipWarpMarkers;
    Items[i].MarkerCount := MarkerCount;
    for j := 0 to MarkerCount - 1 do
    begin
      Items[i].MarkerSource[j] := Clip.WarpMarkers[j].SourceFrame;
      Items[i].MarkerTimeline[j] := Clip.WarpMarkers[j].TimelineFrame;
    end;
  end;

  AudioEngineSetTrackClips(ATrackIndex, Items, Count);
end;

var
  { The track/frame a take was started against - captured at StartRecording
    time same as MainForm's own FRecordTrackIndex/FRecordStartFrame, since
    SelectedTrackIndex/CursorFrame can both drift (Tab elsewhere, cursor
    keys) over however long a count-in plus take actually runs. }
  RecordTrackIndex: Integer = -1;
  RecordStartFrame: Int64 = 0;

{ Mirrors MainForm.RecordClick (src/ui) - same track/instrument checks, same
  count-in-unless-line-in split, just targeting DysTrackPane.
  SelectedTrackIndex/DysTimeline.ActiveTimelineContent^.CursorFrame instead
  of ArrangementView's KeyboardTrack/CursorFrame. Only called (via
  DysWidgets.StartRecordingProc) when AudioEngineRecordState is already
  confirmed Idle - see TDysToolBar's own Record button handling. }
{ Real implementation behind DysWidgets.SeekPlaybackToCursorProc - see that
  var's own comment. Mirrors DysStartRecording's own seek-to-cursor line
  above, just without the recording bookkeeping around it. }
procedure DysSeekPlaybackToCursor;
begin
  if ActiveTimelineContent <> nil then
    AudioEngineSeek(ActiveTimelineContent^.CursorFrame);
end;

{ Real implementation behind DysWidgets.CycleTrackHeightProc - the toolbar's
  height button (next to IntervalBtn) can't call
  TDysTimelineContent.EnsureTrackVisible itself (DysWidgets can't `uses
  DysTimeline`, see that unit's own comment on the callback), so it goes
  through this instead. Same effect as the timeline's own 'h'/'H' key
  (HandleEvent below) - both end up here, so there's exactly one place that
  re-derives "is the cursor's track still visible after the height
  changed". }
procedure DysCycleTrackHeight;
begin
  CycleTrackHeight;
  if ActiveTimelineContent <> nil then
  begin
    ActiveTimelineContent^.EnsureTrackVisible(ActiveTimelineContent^.CursorTrack);
    ActiveTimelineContent^.DrawView;
  end;
end;

procedure DysStartRecording;
begin
  RecordTrackIndex := SelectedTrackIndex;
  if RecordTrackIndex < 0 then
    Exit;
  RecordStartFrame := 0;
  if ActiveTimelineContent <> nil then
    RecordStartFrame := ActiveTimelineContent^.CursorFrame;
  AudioEngineSeek(RecordStartFrame);

  if Project.TrackIsInput[RecordTrackIndex] then
  begin
    { line-in take: no keyboard instrument to check for, no count-in - see
      MainForm.RecordClick's identical comment. }
    AudioEngineStartRecording(RecordTrackIndex);
    Exit;
  end;

  if not Project.TrackIsSampler[RecordTrackIndex] and
    (Project.TrackInstrument[RecordTrackIndex] < 0) then
  begin
    MessageBox('Load an instrument for this track first.', nil,
      mfInformation or mfOKButton);
    Exit;
  end;

  AudioEngineStartCountIn(RecordTrackIndex);
end;

{ Mirrors MainForm.FinalizeRecording (src/ui): stops the engine's capture
  (a no-op if it was only counting in and never actually reached Recording,
  same as there) and, if anything was actually captured, wraps it as a new
  TSample/TClip and commits it to RecordTrackIndex at RecordStartFrame -
  same field set PlaceOverlay's own commit above uses, then the same
  PushTrackToEngine call so the engine picks it up immediately. Called both
  from the Record button (manual stop) and from TDysToolBar's Idle-driven
  poll of AudioEngineRecordState (the engine auto-stopping on its own
  recording-length cap, same as MainForm's timer-driven equivalent). }
procedure DysFinalizeRecording;
var
  WasRecording: Boolean;
  Data: PSingle;
  FrameCount: Integer;
  Sample: TSample;
  NewClip: TClip;
begin
  WasRecording := AudioEngineRecordState = RecordStateRecording;
  AudioEngineStopRecording;
  if not WasRecording then
    Exit; { cancelled during count-in - nothing to keep }
  if not AudioEngineTakeRecordedAudio(Data, FrameCount) then
    Exit;
  if RecordTrackIndex < 0 then
    Exit;

  FillChar(Sample, SizeOf(Sample), 0);
  Sample.Data := Data;
  Sample.FrameCount := FrameCount;
  Sample.Channels := 2;
  Sample.SampleRate := AudioEngine.ProjectSampleRate;
  Sample.BaseNote := 60.0;

  FillChar(NewClip, SizeOf(NewClip), 0);
  NewClip.SampleID := Project.AddSampleToPool(Sample,
    'Recording ' + IntToStr(Length(Project.SamplePool)), '');
  NewClip.Offset := 0;
  NewClip.Length := FrameCount;
  NewClip.Position := RecordStartFrame;
  NewClip.TrackID := RecordTrackIndex;
  NewClip.Gain := 1.0;
  NewClip.PitchSemitones := 0;
  NewClip.WarpMode := WarpModeBeats;

  Project.PushUndoSnapshot(RecordTrackIndex);
  Project.CommitClipToTrack(RecordTrackIndex, NewClip);
  PushTrackToEngine(RecordTrackIndex);
end;

{ The 'w' key: re-warp a clip's length to the nearest power-of-two bar count
  (1, 2, 4, 8, 16...) rather than the nearest whole bar - a "clean loop" in
  practice means a musically round length, and 3 or 5 bars is not that even
  though it's a whole number. Ported from ArrangementView's shift-drag
  resize-right (MouseUp, src/ui): force WarpMode to WarpModeRePitch and give
  the clip exactly two WarpMarkers spanning the original source length onto
  the new (target) timeline length - AudioEngine.ClipSourcePosition's
  WarpMode=1 branch reads the ratio between bounding markers and resamples
  by adjusting playback rate on the fly, so this changes nothing about the
  underlying sample data, only how fast the clip's own copy of it is read.
  Unlike the Eris drag (which only rewrites the trailing marker, preserving
  whatever markers already existed for a mid-drag edit), this always treats
  the clip's current Length as the whole source span and replaces the
  marker list outright - simpler, and correct for warping an entire clip in
  one keypress rather than dragging one edge of it.

  BUG FIXED: the original picked the target bar count via
  Round(Ln(LenBars)/Ln(2)) - "nearest" in LOG space, rounded with FPC's
  round-half-to-even. Any clip landing near the geometric mean of two
  candidates (LenBars close to sqrt(2)*2^k, e.g. ~1.41 bars) is exactly the
  0.5 tie Round resolves to the EVEN Pow2, silently rounding down instead of
  to the clip's actual nearest neighbour - "warp a ~1.9-bar clip and
  sometimes get something short instead of 2 bars" was this: LenBars near a
  tie in log-space is not the same clip as LenBars near a tie in real bar
  count, so log-space "nearest" disagreed with what the user actually saw
  onscreen. Fixed by comparing the two power-of-two CANDIDATES directly in
  bar space (LenBars, not its logarithm) and picking whichever is closer -
  no log(), no Round() tie-break, "nearest" now means what it looks like. }
{ Rounds AValue to the nearest multiple of AStep - shared by Shift+W (resize)
  and 'm' (move) so their interactive start point is already grid-aligned,
  same convention the cursor's own Left/Right movement (GridStepFrames)
  established. }
function SnapToGrid(AValue, AStep: Int64): Int64;
begin
  if AStep <= 0 then
  begin
    Result := AValue;
    Exit;
  end;
  Result := ((AValue + (AStep div 2)) div AStep) * AStep;
end;

{ The resampling half of 'w' (WarpClipToNearestPow2Bar), factored out so
  Shift+W's interactive resize can retarget the clip to an arbitrary grid-
  snapped length instead of only the nearest power-of-two bar count -
  identical two-WarpMarker/WarpModeRePitch mechanism either way (see the
  header comment on WarpClipToNearestPow2Bar for why this changes nothing
  about the underlying sample data). }
procedure WarpClipToLength(ATrack, AClipIndex: Integer; ATargetLength: Int64);
var
  OrigLength: Int64;
begin
  if (AClipIndex < 0) or (ATargetLength <= 0) then
    Exit;
  OrigLength := Project.Tracks[ATrack].Clips[AClipIndex].Length;
  if OrigLength <= 0 then
    Exit;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMode := SampleTypes.WarpModeRePitch;
  SetLength(Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers, 2);
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[0].SourceFrame := 0;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[0].TimelineFrame := 0;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[1].SourceFrame := OrigLength;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[1].TimelineFrame := ATargetLength;
  Project.Tracks[ATrack].Clips[AClipIndex].Length := ATargetLength;

  PushTrackToEngine(ATrack);
end;

procedure WarpClipToNearestPow2Bar(ATrack, AClipIndex: Integer);
var
  Frames, Bars, OrigLength, TargetLength: Int64;
  LenBars: Double;
  Pow2Lo: Integer;
  BarsLo, BarsHi: Int64;
begin
  Frames := BarFrames;
  if (Frames <= 0) or (AClipIndex < 0) then
    Exit;
  OrigLength := Project.Tracks[ATrack].Clips[AClipIndex].Length;
  if OrigLength <= 0 then
    Exit;
  LenBars := OrigLength / Frames;
  { Floor to the power-of-two AT OR BELOW LenBars, then compare LenBars
    against that candidate and the next one up directly (in bars, not
    logs) - ties (equidistant) favour the higher candidate, matching
    "round half up" rather than the banker's-rounding tie-break Round()
    would otherwise apply in log space. }
  Pow2Lo := Trunc(Ln(LenBars) / Ln(2));
  if Pow2Lo < 0 then
    Pow2Lo := 0;
  BarsLo := Int64(1) shl Pow2Lo;
  while BarsLo > LenBars do
  begin
    Dec(Pow2Lo);
    if Pow2Lo < 0 then
    begin
      Pow2Lo := 0;
      Break;
    end;
    BarsLo := Int64(1) shl Pow2Lo;
  end;
  BarsHi := BarsLo * 2;
  while BarsLo * 2 <= LenBars do
  begin
    BarsLo := BarsLo * 2;
    BarsHi := BarsLo * 2;
  end;
  if (LenBars - BarsLo) < (BarsHi - LenBars) then
    Bars := BarsLo
  else
    Bars := BarsHi;
  TargetLength := Bars * Frames;

  WarpClipToLength(ATrack, AClipIndex, TargetLength);
end;

{ TDysTimelineContent }

constructor TDysTimelineContent.Init(Bounds: TRect);
var
  i: Integer;
begin
  inherited Init(Bounds);
  { One random colour per track slot, same "Randomize once, one Random call
    per slot" as ArrangementView.FTrackColors (src/ui) - see TrackColorAttr/
    TrackColorPalette. All MaxTracks slots get one up front, not just
    Project.TrackCount's current value, so a track added later already has
    a colour waiting rather than needing this re-run. }
  Randomize;
  for i := 0 to High(TrackColors) do
    TrackColors[i] := TrackColorPalette[Random(Length(TrackColorPalette))];
  GrowMode := 0;
  EventMask := EventMask or evMouseDown or evKeyDown;
  { Bare TView.Init leaves Options at 0 - ofSelectable is what makes
    TView.Select (and so Focus, which calls it at every level on the way
    down - see tui.md's Free Vision notes) actually assign Owner^.Current
    to Self. Every stock interactive control sets this in its own Init
    (see TListViewer.Init); a hand-rolled TView descendant has to do the
    same or Focus silently no-ops on it while still returning True, so
    keyboard input never actually reaches it - exactly the "Enter does
    nothing" bug this fixed. ofFirstClick for the same reason mouse focus
    works on every other pane's content. }
  Options := Options or (ofSelectable + ofFirstClick);
  CursorTrack := 0;
  CursorFrame := 0;
  CursorInLabel := True;
  Pending := False;
  PendingSampleID := -1;
  PendingLength := 0;
  PxPerSec := DefaultPixelsPerSecond;
  FramesPerCol := AudioEngine.ProjectSampleRate div PxPerSec;
  ViewStartFrame := 0;
  ShowPlayhead := False;
  PlayheadFrame := 0;
  LoopStart := -1;
  LoopEnd := -1;
  ResizeActive := False;
  ResizeClipIndex := -1;
  MoveActive := False;
  MoveClipIndex := -1;
  MarkedTrack := -1;
  MarkedClipIndex := -1;
  ActiveTimelineContent := @Self;
end;

{ Fills B[LabelWidth..Size.X-1] with a clip block wherever [APos, APos+ALen)
  lands, in column space - shared by the committed-clip loop and the
  pending-overlay draw below. }
procedure DrawSpan(var B: TDrawBuffer; AFramesPerCol: Int64; AWidth: Integer;
  APos, ALen: Int64; AAttr: Word; AViewStart: Int64);
var
  StartCol, EndCol: Integer;
begin
  if (ALen <= 0) or (AFramesPerCol <= 0) then
    Exit;
  if APos + ALen <= AViewStart then
    Exit; { entirely scrolled off the left edge - division below truncates
            toward zero, not floor, so a raw negative-column calc here
            could otherwise land back inside the visible range by mistake }
  StartCol := LabelWidth + ((APos - AViewStart) div AFramesPerCol);
  EndCol := LabelWidth + ((APos + ALen - 1 - AViewStart) div AFramesPerCol);
  if StartCol < LabelWidth then
    StartCol := LabelWidth;
  if EndCol > AWidth - 1 then
    EndCol := AWidth - 1;
  if EndCol < StartCol then
    Exit;
  MoveChar(B[StartCol], BlockChar, AAttr, EndCol - StartCol + 1);
end;

procedure TDysTimelineContent.Draw;
var
  B: TDrawBuffer;
  Col, Track, Row, SubRow, i, Sec, PlayCol, CursorCol, LoopStartCol,
    LoopEndCol: Integer;
  Lbl, SecStr: string;
begin
  PlayCol := -1;
  if ShowPlayhead then
  begin
    PlayCol := LabelWidth + ((PlayheadFrame - ViewStartFrame) div FramesPerCol);
    if (PlayCol < LabelWidth) or (PlayCol > Size.X - 1) then
      PlayCol := -1; { off the visible grid - draw nothing rather than clamp
                        it to an edge, which would misleadingly suggest the
                        playhead is still in view }
  end;

  LoopStartCol := -1;
  if LoopStart >= 0 then
  begin
    LoopStartCol := LabelWidth + ((LoopStart - ViewStartFrame) div FramesPerCol);
    if (LoopStartCol < LabelWidth) or (LoopStartCol > Size.X - 1) then
      LoopStartCol := -1;
  end;
  LoopEndCol := -1;
  if LoopEnd >= 0 then
  begin
    LoopEndCol := LabelWidth + ((LoopEnd - ViewStartFrame) div FramesPerCol);
    if (LoopEndCol < LabelWidth) or (LoopEndCol > Size.X - 1) then
      LoopEndCol := -1;
  end;

  { Ruler: a tick every column, the elapsed second (from the true frame at
    that column, ViewStartFrame plus however many columns in - not just the
    column's own offset from the left edge, since scrolling means the left
    edge is no longer necessarily frame 0) written out at every whole-
    second column. Jumping Col past a multi-digit label (rather than just
    Inc(Col)) matters once Sec reaches two digits - otherwise the next
    column's '.' would immediately overwrite the label's second digit. }
  MoveChar(B, ' ', NormalAttr, Size.X);
  MoveStr(B, StringOfChar(' ', LabelWidth), NormalAttr);
  Col := LabelWidth;
  while Col < Size.X do
  begin
    if ((Col - LabelWidth) mod PxPerSec) = 0 then
    begin
      Sec := (ViewStartFrame + (Col - LabelWidth) * FramesPerCol) div
        AudioEngine.ProjectSampleRate;
      SecStr := IntToStr(Sec);
      MoveStr(B[Col], SecStr, NormalAttr);
      Inc(Col, Length(SecStr));
    end
    else
    begin
      MoveChar(B[Col], '.', NormalAttr, 1);
      Inc(Col);
    end;
  end;
  if LoopStartCol >= 0 then
    MoveChar(B[LoopStartCol], LoopChar, LoopAttr, 1);
  if LoopEndCol >= 0 then
    MoveChar(B[LoopEndCol], LoopChar, LoopAttr, 1);
  if PlayCol >= 0 then
    MoveChar(B[PlayCol], PlayheadChar, PlayheadAttr, 1);
  WriteLine(0, 0, Size.X, 1, B);

  { One TrackHeight-row block per track, starting at ViewStartTrack (vertical
    scroll - see EnsureTrackVisible/ScrollTracksBy) and clipped to however
    many rows actually fit. Every layer below (background ticks, clips,
    separators, overlays, loop/playhead markers, cursor) repeats once per
    SubRow instead of writing a single row, and TrackTopRow is the ONE
    formula (shared with DysTrackPane, see DysWidgets.pas) computing where
    each block starts - nothing here re-derives that independently. }
  for Track := ViewStartTrack to Project.TrackCount - 1 do
  begin
    Row := TrackTopRow(Track);
    if Row >= Size.Y then
      Break;

    Lbl := TrackTypeChar(Track);
    while Length(Lbl) < LabelWidth do
      Lbl := Lbl + ' ';

    for SubRow := 0 to TrackHeight - 1 do
    begin
      if Row + SubRow >= Size.Y then
        Break;

      MoveChar(B, ' ', NormalAttr, Size.X);
      { The A/I/S label only sits on the block's top row - the rest of a
        tall block gets a blank label column, same "number/letter aligns
        with the top row" convention DysTrackPane's own listing follows. }
      if SubRow = 0 then
      begin
        if (Track = CursorTrack) and CursorInLabel then
          MoveStr(B, Lbl, CursorAttr)
        else
          MoveStr(B, Lbl, NormalAttr);
      end
      else
        MoveStr(B, StringOfChar(' ', LabelWidth), NormalAttr);

      Col := LabelWidth;
      while Col < Size.X do
      begin
        if ((Col - LabelWidth) mod PxPerSec) = 0 then
          MoveChar(B[Col], '|', NormalAttr, 1)
        else
          MoveChar(B[Col], '.', NormalAttr, 1);
        Inc(Col);
      end;

      for i := 0 to High(Project.Tracks[Track].Clips) do
      begin
        { The clip currently being interactively resized/moved is skipped here
          and drawn again below with PendingAttr at its TENTATIVE span instead
          - same "blink until solidified" look BeginOverlay's Pending clip
          already has, see the field comments on ResizeActive/MoveActive. }
        if (ResizeActive and (Track = ResizeTrack) and (i = ResizeClipIndex)) or
           (MoveActive and (Track = MoveTrack) and (i = MoveClipIndex)) then
          Continue;
        DrawSpan(B, FramesPerCol, Size.X, Project.Tracks[Track].Clips[i].Position,
          Project.Tracks[Track].Clips[i].Length, TrackColorAttr(Track),
          ViewStartFrame);
        DrawClipStartMarker(B, FramesPerCol, Size.X,
          Project.Tracks[Track].Clips[i].Position, ViewStartFrame);
      end;

      if Pending and (Track = CursorTrack) then
        DrawSpan(B, FramesPerCol, Size.X, CursorFrame, PendingLength, PendingAttr,
          ViewStartFrame);

      if ResizeActive and (Track = ResizeTrack) then
        DrawSpan(B, FramesPerCol, Size.X,
          Project.Tracks[Track].Clips[ResizeClipIndex].Position, ResizeLength,
          PendingAttr, ViewStartFrame);

      if MoveActive and (Track = MoveTrack) then
        DrawSpan(B, FramesPerCol, Size.X, MovePosition, MoveLength, PendingAttr,
          ViewStartFrame);

      { 'k' - see MarkedTrack's own field comment on why this is bounds-
        checked here rather than cleared by every edit that could move/
        invalidate the index: a split/delete/duplicate on this track since
        the mark was set could have shifted or removed it entirely, and
        re-checking Length on every Draw is simpler than hunting down every
        place that would otherwise need to fix the mark up. }
      if (Track = MarkedTrack) and (MarkedClipIndex >= 0) and
         (MarkedClipIndex <= High(Project.Tracks[Track].Clips)) then
        DrawSpan(B, FramesPerCol, Size.X,
          Project.Tracks[Track].Clips[MarkedClipIndex].Position,
          Project.Tracks[Track].Clips[MarkedClipIndex].Length,
          MarkedAttr, ViewStartFrame);

      if LoopStartCol >= 0 then
        MoveChar(B[LoopStartCol], LoopChar, LoopAttr, 1);
      if LoopEndCol >= 0 then
        MoveChar(B[LoopEndCol], LoopChar, LoopAttr, 1);

      if PlayCol >= 0 then
        MoveChar(B[PlayCol], PlayheadChar, PlayheadAttr, 1);

      { The grid-side half of the track cursor - only drawn once it has moved
        off the label column (see CursorInLabel), so the label highlight and
        this marker are never both showing for the same track at once. Drawn
        on every SubRow so the cursor reads as a full-height column through a
        tall block, not just a mark on its top row. }
      if (Track = CursorTrack) and (not CursorInLabel) then
      begin
        CursorCol := LabelWidth + ((CursorFrame - ViewStartFrame) div FramesPerCol);
        if (CursorCol >= LabelWidth) and (CursorCol <= Size.X - 1) then
          MoveChar(B[CursorCol], BlockChar, CursorAttr, 1);
      end;

      WriteLine(0, Row + SubRow, Size.X, 1, B);
    end;
  end;
end;

procedure TDysTimelineContent.HandleEvent(var Event: TEvent);
var
  ClipIdx: Integer;
  Candidate: Int64;
begin
  if Event.What = evKeyDown then
  begin
    case Event.KeyCode of
      kbUp:
        begin
          if CursorTrack > 0 then
            Dec(CursorTrack);
          EnsureTrackVisible(CursorTrack);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbDown:
        begin
          if CursorTrack < Project.TrackCount - 1 then
            Inc(CursorTrack);
          EnsureTrackVisible(CursorTrack);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbPgUp:
        begin
          ScrollTracksBy(-1);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbPgDn:
        begin
          ScrollTracksBy(1);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbLeft:
        begin
          if ResizeActive then
          begin
            Dec(ResizeLength, GridStepFrames);
            if ResizeLength < GridStepFrames then
              ResizeLength := GridStepFrames; { never below one grid step }
            DrawView;
            ClearEvent(Event);
            Exit;
          end;
          if MoveActive then
          begin
            Dec(MovePosition, GridStepFrames);
            if MovePosition < 0 then
              MovePosition := 0;
            DrawView;
            ClearEvent(Event);
            Exit;
          end;
          if not CursorInLabel then
          begin
            if CursorFrame <= 0 then
              CursorInLabel := True
            else
            begin
              Dec(CursorFrame, GridStepFrames);
              if CursorFrame < 0 then
                CursorFrame := 0;
              EnsureFrameVisible(CursorFrame);
            end;
          end;
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbRight:
        begin
          if ResizeActive then
          begin
            Inc(ResizeLength, GridStepFrames);
            DrawView;
            ClearEvent(Event);
            Exit;
          end;
          if MoveActive then
          begin
            Inc(MovePosition, GridStepFrames);
            DrawView;
            ClearEvent(Event);
            Exit;
          end;
          if CursorInLabel then
            CursorInLabel := False
          else
          begin
            Inc(CursorFrame, GridStepFrames);
            EnsureFrameVisible(CursorFrame);
          end;
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbEnter:
        begin
          if ResizeActive then
            SolidifyResize
          else if MoveActive then
            SolidifyMove
          else
            PlaceOverlay;
          ClearEvent(Event);
          Exit;
        end;
      kbEsc:
        begin
          if ResizeActive then
            ResizeActive := False
          else if MoveActive then
            MoveActive := False
          else
            CancelOverlay;
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbCtrlS:
        begin
          MessageBox('Drag mode is stage 8 - selection editing not wired yet.',
            nil, mfInformation or mfOKButton);
          ClearEvent(Event);
          Exit;
        end;
      { Space is play/pause ONLY here, with the timeline focused - see
        tui.md's Bindings. Everywhere else Space is left alone (a file
        pane row, a track row, a toolbar button all have their own
        meaning for it, or none). Routed through DysWidgets.ActiveToolBar
        so this runs the exact same AudioEngineIsPlaying/HasClip logic
        and button-label update the Play button itself uses. }
      kbSpaceBar:
        begin
          if ActiveToolBar <> nil then
            ActiveToolBar^.TogglePlayPause;
          ClearEvent(Event);
          Exit;
        end;
      { Same operations the Edit menu's Copy/Paste/Duplicate/Split/Delete
        items call (DysnomiaApp.HandleEvent) - bound directly here too, same
        dual-binding ArrangementView.KeyDown/MainForm's Edit menu use in
        Eris, so the shortcuts work with the timeline focused whether or not
        the menu bar is ever touched. }
      kbCtrlC:
        begin
          CopyClipUnderCursor;
          ClearEvent(Event);
          Exit;
        end;
      kbCtrlV:
        begin
          PasteClipAtCursor;
          ClearEvent(Event);
          Exit;
        end;
      kbCtrlD:
        begin
          DuplicateClipUnderCursor;
          ClearEvent(Event);
          Exit;
        end;
      kbCtrlE:
        begin
          SplitClipUnderCursor;
          ClearEvent(Event);
          Exit;
        end;
      kbDel:
        begin
          DeleteClipUnderCursor;
          ClearEvent(Event);
          Exit;
        end;
    end;
    { Char-code case, not UpCase - unlike Ctrl+<letter> or Enter (see tui.md's
      "Three of these were redesigned" note), Shift DOES change a plain
      letter's byte, so 'w' and 'W' arrive as genuinely distinct codes and
      can mean different things: 'w' still warps straight to the nearest
      power-of-two bar, 'W' now starts the interactive resize instead. 'l'/
      'L' and '+'/'=' etc. don't need the distinction, so those still match
      case-insensitively where that was already true. }
    case Event.CharCode of
      '+', '=':
        begin
          { '=' too - the unshifted key sharing that cap on most keyboards,
            so zoom-in doesn't strictly require Shift. }
          SetZoom(PxPerSec + 1);
          ClearEvent(Event);
          Exit;
        end;
      '-':
        begin
          SetZoom(PxPerSec - 1);
          ClearEvent(Event);
          Exit;
        end;
      'w':
        begin
          ClipIdx := ClipIndexAtFrame(CursorTrack, CursorFrame);
          if ClipIdx >= 0 then
          begin
            WarpClipToNearestPow2Bar(CursorTrack, ClipIdx);
            DrawView;
          end;
          ClearEvent(Event);
          Exit;
        end;
      'W':
        begin
          { Start the interactive resize - see the ResizeActive field
            comment. Starting length is the clip's current length snapped to
            the grid, so the very first Left/Right press moves it by exactly
            one grid step rather than an odd leftover fraction. }
          ClipIdx := ClipIndexAtFrame(CursorTrack, CursorFrame);
          if ClipIdx >= 0 then
          begin
            ResizeActive := True;
            ResizeTrack := CursorTrack;
            ResizeClipIndex := ClipIdx;
            ResizeLength := SnapToGrid(
              Project.Tracks[CursorTrack].Clips[ClipIdx].Length, GridStepFrames);
            if ResizeLength < GridStepFrames then
              ResizeLength := GridStepFrames;
            DrawView;
          end;
          ClearEvent(Event);
          Exit;
        end;
      'm', 'M':
        begin
          { Start the interactive move - see the MoveActive field comment.
            Starting position is the clip's current position snapped to the
            grid, same reasoning as ResizeLength above. }
          ClipIdx := ClipIndexAtFrame(CursorTrack, CursorFrame);
          if ClipIdx >= 0 then
          begin
            MoveActive := True;
            MoveTrack := CursorTrack;
            MoveClipIndex := ClipIdx;
            MoveLength := Project.Tracks[CursorTrack].Clips[ClipIdx].Length;
            MovePosition := SnapToGrid(
              Project.Tracks[CursorTrack].Clips[ClipIdx].Position, GridStepFrames);
            if MovePosition < 0 then
              MovePosition := 0;
            DrawView;
          end;
          ClearEvent(Event);
          Exit;
        end;
      'k', 'K':
        begin
          MarkClipUnderCursor;
          ClearEvent(Event);
          Exit;
        end;
      'h', 'H':
        begin
          { Cycle the track row height 1/2/3 - same as the toolbar's H:n
            button next to the interval selector (DysWidgets.HeightBtn) -
            both go through DysCycleTrackHeight so there's one place that
            keeps the cursor's track visible after a taller block could
            have pushed it off-screen. }
          DysCycleTrackHeight;
          if ActiveToolBar <> nil then
            ActiveToolBar^.UpdateButtons;
          ClearEvent(Event);
          Exit;
        end;
      'l', 'L':
        begin
          { Three-press cycle: start marker, end marker, clear - see tui.md.
            CursorFrame is already column-aligned (it only ever moves by
            FramesPerCol - see kbLeft/kbRight above), so it IS the frame at
            the left border of the cursor's cell, no extra snapping needed. }
          if LoopStart < 0 then
            LoopStart := CursorFrame
          else if LoopEnd < 0 then
          begin
            Candidate := CursorFrame;
            if Candidate <= LoopStart then
            begin
              LoopEnd := LoopStart;
              LoopStart := Candidate;
            end
            else
              LoopEnd := Candidate;
            AudioEngineSetLoop(LoopStart, LoopEnd);
          end
          else
          begin
            LoopStart := -1;
            LoopEnd := -1;
            AudioEngineClearLoop;
          end;
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
    end;
  end;
  { App-wide dropdown convention (tui.md's Bindings): whether the cursor is
    on the label column or out in the grid, CursorTrack is still "the track
    under the cursor" - same target DysTrackPane's own Ctrl+Enter handler
    uses for its row. }
  if ((Event.What = evKeyDown) and
      ((Event.KeyCode = kbCtrlEnter) or (Event.KeyCode = kbDropdownKey))) or
     ((Event.What = evMouseDown) and (Event.Buttons and mbActualRightButton <> 0))
  then
  begin
    MessageBox('Track ' + IntToStr(CursorTrack + 1) +
      ': mute / solo / volume popup is stage 8 - not wired yet.',
      nil, mfInformation or mfOKButton);
    ClearEvent(Event);
    Exit;
  end;
  inherited HandleEvent(Event);
end;

procedure TDysTimelineContent.BeginOverlay(ASampleID: Integer; ALength: Int64);
begin
  PendingSampleID := ASampleID;
  PendingLength := ALength;
  Pending := True;
  { Left/Right nudges the pending clip along the grid (tui.md's Bindings) -
    force the cursor off the label column so the very first arrow press
    after a drop moves the clip instead of just leaving the label column. }
  CursorInLabel := False;
  DrawView;
end;

procedure TDysTimelineContent.CancelOverlay;
begin
  if not Pending then
    Exit;
  Pending := False;
  PendingSampleID := -1;
  DrawView;
end;

procedure TDysTimelineContent.PlaceOverlay;
var
  NewClip: TClip;
begin
  if not Pending then
    Exit;
  FillChar(NewClip, SizeOf(NewClip), 0);
  NewClip.SampleID := PendingSampleID;
  NewClip.Offset := 0;
  NewClip.Length := PendingLength;
  NewClip.Position := CursorFrame;
  NewClip.TrackID := CursorTrack;
  NewClip.Gain := 1.0;
  NewClip.PitchSemitones := 0;
  NewClip.WarpMode := WarpModeBeats;
  Project.CommitClipToTrack(CursorTrack, NewClip);
  PushTrackToEngine(CursorTrack);

  Pending := False;
  PendingSampleID := -1;
  DrawView;
end;

procedure TDysTimelineContent.CopyClipUnderCursor;
var
  ClipIdx: Integer;
begin
  ClipIdx := ClipIndexAtFrame(CursorTrack, CursorFrame);
  if ClipIdx < 0 then
    Exit;
  ClipboardClip := Project.Tracks[CursorTrack].Clips[ClipIdx];
  ClipboardClip.Position := 0; { rebased - see the clipboard var's comment }
  ClipboardHasItem := True;
end;

procedure TDysTimelineContent.PasteClipAtCursor;
var
  NewClip: TClip;
begin
  if not ClipboardHasItem then
    Exit;
  NewClip := ClipboardClip;
  NewClip.Position := CursorFrame + NewClip.Position;
  NewClip.TrackID := CursorTrack;
  Project.CommitClipToTrack(CursorTrack, NewClip);
  PushTrackToEngine(CursorTrack);
  DrawView;
end;

procedure TDysTimelineContent.DuplicateClipUnderCursor;
var
  ClipIdx: Integer;
  NewClip: TClip;
begin
  ClipIdx := ClipIndexAtFrame(CursorTrack, CursorFrame);
  if ClipIdx < 0 then
    Exit;
  NewClip := Project.Tracks[CursorTrack].Clips[ClipIdx];
  { Immediately after the original, Ableton-style, same as
    ArrangementView.DuplicateSelection's single-clip branch - not
    overlapping, not at the cursor. }
  NewClip.Position := NewClip.Position + NewClip.Length;
  Project.CommitClipToTrack(CursorTrack, NewClip);
  PushTrackToEngine(CursorTrack);
  { Move the cursor onto the duplicate, so a repeated Ctrl+D keeps stacking
    copies rightward instead of re-duplicating the original every time. }
  CursorFrame := NewClip.Position;
  DrawView;
end;

procedure TDysTimelineContent.SplitClipUnderCursor;
var
  ClipIdx: Integer;
  Selected, LeftPart, RightPart: TClip;
  SplitRel, SplitSource: Int64;
  NewClips: TClipArray;
  i, k: Integer;
begin
  ClipIdx := ClipIndexAtFrame(CursorTrack, CursorFrame);
  if ClipIdx < 0 then
    Exit;
  Selected := Project.Tracks[CursorTrack].Clips[ClipIdx];
  { Strictly inside, same guard ArrangementView.SplitAtCursor uses - a split
    exactly on an edge would just produce an empty half. }
  if (CursorFrame <= Selected.Position) or
     (CursorFrame >= Selected.Position + Selected.Length) then
    Exit;

  LeftPart := Selected;
  RightPart := Selected;
  { Divides the existing WarpMarkers between the two halves instead of
    discarding them (see Waveform.SplitWarpMarkers) - naively truncating
    would silently revert both halves to unwarped playback. SplitSource is
    the SOURCE-domain split point, which RightPart.Offset must advance by,
    NOT the timeline-domain CursorFrame - the two differ for any clip that's
    been time-warped (see the comment on SplitWarpMarkers itself). }
  SplitRel := SplitWarpMarkers(Selected.WarpMarkers,
    CursorFrame - Selected.Position, LeftPart.WarpMarkers,
    RightPart.WarpMarkers, Selected.WarpMode, AudioEngine.ProjectSampleRate,
    @SplitSource);

  LeftPart.Length := SplitRel;
  RightPart.Offset := Selected.Offset + SplitSource;
  RightPart.Position := Selected.Position + SplitRel;
  RightPart.Length := Selected.Length - SplitRel;

  SetLength(NewClips, Length(Project.Tracks[CursorTrack].Clips) + 1);
  k := 0;
  for i := 0 to High(Project.Tracks[CursorTrack].Clips) do
  begin
    if i = ClipIdx then
    begin
      NewClips[k] := LeftPart;
      Inc(k);
      NewClips[k] := RightPart;
      Inc(k);
    end
    else
    begin
      NewClips[k] := Project.Tracks[CursorTrack].Clips[i];
      Inc(k);
    end;
  end;
  Project.ReplaceTrackClips(CursorTrack, NewClips);
  PushTrackToEngine(CursorTrack);
  DrawView;
end;

procedure TDysTimelineContent.DeleteClipUnderCursor;
var
  ClipIdx: Integer;
begin
  ClipIdx := ClipIndexAtFrame(CursorTrack, CursorFrame);
  if ClipIdx < 0 then
    Exit;
  Project.RemoveClipAt(CursorTrack, ClipIdx);
  PushTrackToEngine(CursorTrack);
  DrawView;
end;

{ 'k' - see the MarkedTrack/MarkedClipIndex field comment. Hands the
  clip's SampleID/Offset/Length off to the bottom pane's waveform widget
  via SetWaveformClipProc (DysWidgets.pas's own comment on why this is a
  callback rather than a direct call) - that call also switches the
  bottom pane onto the waveform view if it wasn't already showing it, so
  marking a clip gives immediate visual feedback rather than silently
  updating a widget that might be hidden behind the effects rack. }
procedure TDysTimelineContent.MarkClipUnderCursor;
var
  ClipIdx: Integer;
begin
  ClipIdx := ClipIndexAtFrame(CursorTrack, CursorFrame);
  if ClipIdx < 0 then
    Exit;
  MarkedTrack := CursorTrack;
  MarkedClipIndex := ClipIdx;
  DrawView;
  if Assigned(SetWaveformClipProc) then
    with Project.Tracks[CursorTrack].Clips[ClipIdx] do
      SetWaveformClipProc(SampleID, Offset, Length, Gain, PitchSemitones, WarpMode,
        CursorTrack, ClipIdx);
end;

{ Wired to DysWidgets.ChopWaveformSelectionProc - see that var's own
  comment. AStartSource/AEndSource are absolute source-domain frame
  positions into the underlying sample (same domain as TClip.Offset),
  exactly what the waveform widget's own drag-selection already works in
  (TDysWaveformContent.ColToSourceFrame). Excises that span from the
  MARKED clip (MarkedTrack/MarkedClipIndex, set by 'k' - not necessarily
  whatever's under the timeline cursor right now), then RIPPLES every other
  clip on the same track that started at or after the chopped span leftward
  by the chopped length, closing the hole rather than leaving a gap (unlike
  DeleteClipUnderCursor above, which still leaves one for a whole-clip
  Delete - this callback's own Delete-key path is scoped to a drag
  selection, not a whole clip, so there's no reason to match that
  convention here). Only supports an UNWARPED
  clip (WarpMarkers empty/singleton, the default state for a clip fresh off
  the file pane or a plain Ctrl+V/Ctrl+D copy - see SplitWarpMarkers's own
  "Length(AMarkers) < 2 -> 1:1 playback" comment): the source-domain
  selection this callback receives can only be mapped straight onto
  timeline-domain Position/Length when source frame and timeline frame
  advance 1:1, which a time-warped clip's own WarpMarkers deliberately
  breaks. Chopping a warped clip needs the same piecewise-linear remap
  SplitWarpMarkers already does, just at TWO cut points instead of one -
  real, but not attempted here; refuses with a message instead of
  producing a chop that would silently play back wrong. }
procedure DysChopMarkedClipRegion(AStartSource, AEndSource: Int64);
var
  Track, ClipIdx: Integer;
  Original, LeftPart, RightPart: TClip;
  ClipStart, ClipEnd: Int64;
  HaveLeft, HaveRight: Boolean;
  NewClips: TClipArray;
  i, k: Integer;
  Delta, ShiftAfterPos: Int64;
begin
  if ActiveTimelineContent = nil then
    Exit;
  Track := ActiveTimelineContent^.MarkedTrack;
  ClipIdx := ActiveTimelineContent^.MarkedClipIndex;
  if (Track < 0) or (Track > High(Project.Tracks)) then
    Exit;
  if (ClipIdx < 0) or (ClipIdx > High(Project.Tracks[Track].Clips)) then
    Exit;
  Original := Project.Tracks[Track].Clips[ClipIdx];
  if Length(Original.WarpMarkers) >= 2 then
  begin
    MessageBox('Chopping a time-warped clip (after ''w''/Shift+W) is not ' +
      'supported yet - only a plain, unwarped clip can be chopped.', nil,
      mfError or mfOKButton);
    Exit;
  end;

  ClipStart := Original.Offset;
  ClipEnd := Original.Offset + Original.Length;
  if AStartSource < ClipStart then
    AStartSource := ClipStart;
  if AEndSource > ClipEnd then
    AEndSource := ClipEnd;
  if AEndSource <= AStartSource then
    Exit;

  HaveLeft := AStartSource > ClipStart;
  HaveRight := AEndSource < ClipEnd;

  { Ripple, not a gap (per the user's own ask): everything at or after the
    chopped span's own END - in TIMELINE terms, ShiftAfterPos below - slides
    left by Delta frames once the excised span is gone, same "close the
    hole" behaviour a DAW's ripple-delete gives. Unwarped (guarded above),
    so source and timeline frames advance 1:1 and Delta/ShiftAfterPos both
    carry straight over from source domain without any remap. }
  Delta := AEndSource - AStartSource;
  ShiftAfterPos := Original.Position + (AEndSource - ClipStart);

  if HaveLeft then
  begin
    LeftPart := Original;
    LeftPart.Length := AStartSource - ClipStart;
  end;
  if HaveRight then
  begin
    RightPart := Original;
    RightPart.Offset := AEndSource;
    RightPart.Length := ClipEnd - AEndSource;
    { Placed directly after LeftPart's own end (ShiftAfterPos - Delta,
      i.e. Original.Position + (AStartSource - ClipStart)) rather than at
      the old gap-leaving ShiftAfterPos - this is already its FINAL,
      post-ripple position, which is also why the ripple loop below (keyed
      on Position >= ShiftAfterPos) never touches it again. }
    RightPart.Position := ShiftAfterPos - Delta;
  end;

  if not HaveLeft and not HaveRight then
    { Whole clip selected - same outcome as Delete. }
    Project.RemoveClipAt(Track, ClipIdx)
  else
  begin
    SetLength(NewClips, Length(Project.Tracks[Track].Clips) -
      1 + Ord(HaveLeft) + Ord(HaveRight));
    k := 0;
    for i := 0 to High(Project.Tracks[Track].Clips) do
    begin
      if i = ClipIdx then
      begin
        if HaveLeft then
        begin
          NewClips[k] := LeftPart;
          Inc(k);
        end;
        if HaveRight then
        begin
          NewClips[k] := RightPart;
          Inc(k);
        end;
      end
      else
      begin
        NewClips[k] := Project.Tracks[Track].Clips[i];
        Inc(k);
      end;
    end;
    Project.ReplaceTrackClips(Track, NewClips);
  end;

  { Second pass, after whichever of RemoveClipAt/ReplaceTrackClips above
    actually ran: every OTHER clip on this same track whose own Position was
    at or past the chopped span's end shifts left by Delta too, closing the
    hole left behind. RightPart (if any) is already at its final position
    (see its own comment above) and sits BELOW ShiftAfterPos, so this loop
    skips it - nothing here double-shifts it. }
  for i := 0 to High(Project.Tracks[Track].Clips) do
    if Project.Tracks[Track].Clips[i].Position >= ShiftAfterPos then
      Dec(Project.Tracks[Track].Clips[i].Position, Delta);

  PushTrackToEngine(Track);

  { The chopped span is gone from view either way - clear the waveform
    widget rather than guessing which remaining piece (if any) to re-show;
    press 'k' again on whichever piece to inspect it. }
  ActiveTimelineContent^.MarkedTrack := -1;
  ActiveTimelineContent^.MarkedClipIndex := -1;
  if Assigned(SetWaveformClipProc) then
    SetWaveformClipProc(-1, 0, 0, 0, 0, 0, -1, -1);
  ActiveTimelineContent^.DrawView;
end;

{ Inverse of DysChopMarkedClipRegion's own left-ripple: splits the
  CURRENTLY MARKED clip at AAtSourceFrame (absolute source-domain, same
  convention as that function's AStartSource/AEndSource) and inserts a
  brand new clip [ASampleID,AOffset,ALength) between the two halves,
  rippling every OTHER clip on the track whose Position is at or past the
  split point rightward by ALength to make room. Shared by Ctrl+D
  (DysDuplicateWaveformSelection - duplicates the waveform pane's current
  selection immediately after itself) and Ctrl+V
  (DysPasteWaveformClipboard - pastes at the pane's click-set insertion
  cursor). Same "only a plain unwarped clip" restriction as the chop, for
  the same reason: source and timeline frames need to advance 1:1 for
  AAtSourceFrame to translate into a timeline position at all. }
procedure DysInsertIntoMarkedClip(AAtSourceFrame: Int64; ASampleID: Integer;
  AOffset, ALength: Int64);
var
  Track, ClipIdx: Integer;
  Original, LeftPart, MiddlePart, RightPart: TClip;
  ClipStart, ClipEnd, SplitPos: Int64;
  HaveLeft, HaveRight: Boolean;
  NewClips: TClipArray;
  i, k: Integer;
begin
  if (ActiveTimelineContent = nil) or (ALength <= 0) then
    Exit;
  Track := ActiveTimelineContent^.MarkedTrack;
  ClipIdx := ActiveTimelineContent^.MarkedClipIndex;
  if (Track < 0) or (Track > High(Project.Tracks)) then
    Exit;
  if (ClipIdx < 0) or (ClipIdx > High(Project.Tracks[Track].Clips)) then
    Exit;
  Original := Project.Tracks[Track].Clips[ClipIdx];
  if Length(Original.WarpMarkers) >= 2 then
  begin
    MessageBox('Editing a time-warped clip''s waveform this way is not ' +
      'supported yet - only a plain, unwarped clip can be chopped.', nil,
      mfError or mfOKButton);
    Exit;
  end;

  ClipStart := Original.Offset;
  ClipEnd := Original.Offset + Original.Length;
  if AAtSourceFrame < ClipStart then
    AAtSourceFrame := ClipStart;
  if AAtSourceFrame > ClipEnd then
    AAtSourceFrame := ClipEnd;

  HaveLeft := AAtSourceFrame > ClipStart;
  HaveRight := AAtSourceFrame < ClipEnd;
  SplitPos := Original.Position + (AAtSourceFrame - ClipStart);

  if HaveLeft then
  begin
    LeftPart := Original;
    LeftPart.Length := AAtSourceFrame - ClipStart;
  end;

  FillChar(MiddlePart, SizeOf(MiddlePart), 0);
  MiddlePart.SampleID := ASampleID;
  MiddlePart.Offset := AOffset;
  MiddlePart.Length := ALength;
  MiddlePart.Position := SplitPos;
  MiddlePart.TrackID := Track;
  MiddlePart.Gain := 1.0;
  MiddlePart.PitchSemitones := 0;
  MiddlePart.WarpMode := WarpModeBeats;

  if HaveRight then
  begin
    RightPart := Original;
    RightPart.Offset := AAtSourceFrame;
    RightPart.Length := ClipEnd - AAtSourceFrame;
    RightPart.Position := SplitPos + ALength;
  end;

  SetLength(NewClips, Length(Project.Tracks[Track].Clips) +
    1 + Ord(HaveLeft) + Ord(HaveRight) - 1);
  k := 0;
  for i := 0 to High(Project.Tracks[Track].Clips) do
  begin
    if i = ClipIdx then
    begin
      if HaveLeft then
      begin
        NewClips[k] := LeftPart;
        Inc(k);
      end;
      NewClips[k] := MiddlePart;
      Inc(k);
      if HaveRight then
      begin
        NewClips[k] := RightPart;
        Inc(k);
      end;
    end
    else
    begin
      { An unrelated clip on the same track: ripple it right if it started
        at or past the split point - RightPart (above) is already at its
        final post-insert position and is handled in the `if i = ClipIdx`
        branch instead, so it's never seen here and can't be double-shifted. }
      NewClips[k] := Project.Tracks[Track].Clips[i];
      if NewClips[k].Position >= SplitPos then
        Inc(NewClips[k].Position, ALength);
      Inc(k);
    end;
  end;
  Project.ReplaceTrackClips(Track, NewClips);
  PushTrackToEngine(Track);

  { Same "clear the mark, press 'k' again" convention as the chop - the
    marked clip just became two or three different clips, none of which is
    unambiguously "the same one" to keep showing. }
  ActiveTimelineContent^.MarkedTrack := -1;
  ActiveTimelineContent^.MarkedClipIndex := -1;
  if Assigned(SetWaveformClipProc) then
    SetWaveformClipProc(-1, 0, 0, 0, 0, 0, -1, -1);
  ActiveTimelineContent^.DrawView;
end;

{ Ctrl+D on the waveform pane - see tui.md's Bindings and
  DysCopyWaveformSelection's own comment on why this lives here rather
  than in DysEffectsRack. Duplicates the CURRENT SELECTION (not the
  clipboard - same "act on what's selected, not what was last copied"
  distinction the timeline's own Ctrl+D already draws) immediately after
  itself, Ableton-style, same as DuplicateClipUnderCursor. }
procedure DysDuplicateWaveformSelection;
var
  SelStart, SelEnd: Int64;
  SelSampleID: Integer;
begin
  if (ActiveBottomPane = nil) or (ActiveBottomPane^.WaveformView = nil) then
    Exit;
  with ActiveBottomPane^.WaveformView^ do
  begin
    if (not SelActive) or (SampleID < 0) then
      Exit;
    SelStart := SelStartFrame;
    SelEnd := SelEndFrame;
    SelSampleID := SampleID;
  end;
  DysInsertIntoMarkedClip(SelEnd, SelSampleID, SelStart, SelEnd - SelStart);
end;

{ Ctrl+V on the waveform pane - pastes DysCopyWaveformSelection's clipboard
  at the pane's own click-set insertion cursor (CursorActive/CursorFrame -
  see that field's comment). Does nothing (rather than guessing a
  position) if either is missing. }
procedure DysPasteWaveformClipboard;
var
  AtFrame, ClipOffset, ClipLength: Int64;
  ClipSampleID: Integer;
begin
  if (ActiveBottomPane = nil) or (ActiveBottomPane^.WaveformView = nil) then
    Exit;
  if not DysGetWaveClipboard(ClipSampleID, ClipOffset, ClipLength) then
    Exit;
  with ActiveBottomPane^.WaveformView^ do
  begin
    if not CursorActive then
      Exit;
    AtFrame := CursorFrame;
  end;
  DysInsertIntoMarkedClip(AtFrame, ClipSampleID, ClipOffset, ClipLength);
end;

procedure TDysTimelineContent.SolidifyResize;
begin
  if not ResizeActive then
    Exit;
  WarpClipToLength(ResizeTrack, ResizeClipIndex, ResizeLength);
  ResizeActive := False;
  DrawView;
end;

procedure TDysTimelineContent.SolidifyMove;
var
  MovedClip: TClip;
begin
  if not MoveActive then
    Exit;
  MovedClip := Project.Tracks[MoveTrack].Clips[MoveClipIndex];
  Project.RemoveClipAt(MoveTrack, MoveClipIndex);
  MovedClip.Position := MovePosition;
  Project.CommitClipToTrack(MoveTrack, MovedClip);
  PushTrackToEngine(MoveTrack);
  MoveActive := False;
  DrawView;
end;

procedure TDysTimelineContent.PushAllTracksToEngine;
var
  t: Integer;
begin
  for t := 0 to Project.TrackCount - 1 do
    PushTrackToEngine(t);
end;

function TDysTimelineContent.VisibleFrameSpan: Int64;
begin
  if Size.X <= LabelWidth then
    Result := 0
  else
    Result := (Size.X - LabelWidth) * FramesPerCol;
end;

{ Scrolls the minimum amount to bring AFrame back inside the visible grid -
  not a re-centre, so a manual nudge past the edge only moves the view by
  one step, and the playhead crossing the right edge during playback keeps
  scrolling forward column-by-column rather than jumping. Landing AFrame
  exactly one column shy of the far edge (rather than flush against it)
  means the newly-revealed column isn't immediately re-crossed next tick. }
procedure TDysTimelineContent.EnsureFrameVisible(AFrame: Int64);
var
  VF: Int64;
begin
  VF := VisibleFrameSpan;
  if VF <= 0 then
    Exit;
  if AFrame < ViewStartFrame then
    ViewStartFrame := AFrame
  else if AFrame >= ViewStartFrame + VF then
    ViewStartFrame := AFrame - VF + FramesPerCol;
  if ViewStartFrame < 0 then
    ViewStartFrame := 0;
end;

procedure TDysTimelineContent.EnsureTrackVisible(ATrack: Integer);
var
  VisibleRows, TracksVisible: Integer;
begin
  VisibleRows := Size.Y - 1; { row 0 is the ruler, not a track row }
  if VisibleRows <= 0 then
    Exit;
  TracksVisible := VisibleRows div TrackHeight;
  if TracksVisible < 1 then
    TracksVisible := 1;
  if ATrack < ViewStartTrack then
    ViewStartTrack := ATrack
  else if ATrack >= ViewStartTrack + TracksVisible then
    ViewStartTrack := ATrack - TracksVisible + 1;
  if ViewStartTrack < 0 then
    ViewStartTrack := 0;
  if ActiveTrackPane <> nil then
    ActiveTrackPane^.Listing^.DrawView;
end;

procedure TDysTimelineContent.ScrollTracksBy(ADelta: Integer);
var
  VisibleRows, PageSize, MaxStart: Integer;
begin
  VisibleRows := Size.Y - 1;
  if VisibleRows <= 0 then
    Exit;
  PageSize := VisibleRows div TrackHeight;
  if PageSize < 1 then
    PageSize := 1;
  Inc(ViewStartTrack, ADelta * PageSize);
  if ViewStartTrack < 0 then
    ViewStartTrack := 0;
  MaxStart := Project.TrackCount - PageSize;
  if MaxStart < 0 then
    MaxStart := 0;
  if ViewStartTrack > MaxStart then
    ViewStartTrack := MaxStart;
  { PageUp/PageDown move the VIEW, not the cursor - but a cursor scrolled
    out of sight would otherwise look like Up/Down stopped working until
    it's nudged back into view by hand, so clamp it onto whatever's now
    visible instead. }
  if CursorTrack < ViewStartTrack then
    CursorTrack := ViewStartTrack
  else if CursorTrack >= ViewStartTrack + PageSize then
    CursorTrack := ViewStartTrack + PageSize - 1;
  if CursorTrack > Project.TrackCount - 1 then
    CursorTrack := Project.TrackCount - 1;
  if CursorTrack < 0 then
    CursorTrack := 0;
  if ActiveTrackPane <> nil then
    ActiveTrackPane^.Listing^.DrawView;
end;

procedure TDysTimelineContent.SetZoom(ANewPxPerSec: Integer);
begin
  if ANewPxPerSec < MinPixelsPerSecond then
    ANewPxPerSec := MinPixelsPerSecond
  else if ANewPxPerSec > MaxPixelsPerSecond then
    ANewPxPerSec := MaxPixelsPerSecond;
  if ANewPxPerSec = PxPerSec then
    Exit;
  PxPerSec := ANewPxPerSec;
  FramesPerCol := AudioEngine.ProjectSampleRate div PxPerSec;
  if FramesPerCol <= 0 then
    FramesPerCol := 1;
  { Re-anchor on whatever should still be visible after the scale change -
    the playhead while playing (otherwise zooming during playback could
    scroll it straight out of view), the cursor otherwise. }
  if ShowPlayhead then
    EnsureFrameVisible(PlayheadFrame)
  else
    EnsureFrameVisible(CursorFrame);
  DrawView;
end;

{ BarFrames (above) at the toolbar's currently-selected interval - see
  DysWidgets.IntervalNames ('1/4', '1/8', '1/16', '1bar'), same order as
  IntervalIdx cycles. Falls back to one grid column if BarFrames can't be
  computed yet (TempoBPM <= 0) or the toolbar doesn't exist yet (shouldn't
  happen once the app's fully constructed, but Init order isn't this
  method's business to assume). }
function TDysTimelineContent.GridStepFrames: Int64;
var
  Frames: Int64;
begin
  Frames := BarFrames;
  if Frames <= 0 then
  begin
    Result := FramesPerCol;
    Exit;
  end;
  if ActiveToolBar = nil then
  begin
    Result := Frames div 4;
    Exit;
  end;
  case ActiveToolBar^.IntervalIdx of
    0: Result := Frames div 4;  { 1/4 }
    1: Result := Frames div 8;  { 1/8 }
    2: Result := Frames div 16; { 1/16 }
    3: Result := Frames;        { 1 bar }
  else
    Result := Frames div 4;
  end;
  if Result <= 0 then
    Result := FramesPerCol;
end;

procedure TDysTimelineContent.UpdatePlayhead;
var
  NewShow: Boolean;
  NewFrame: Int64;
begin
  NewShow := AudioEngineIsPlaying;
  NewFrame := AudioEngineGetPosition;
  if (NewShow <> ShowPlayhead) or (NewShow and (NewFrame <> PlayheadFrame)) then
  begin
    ShowPlayhead := NewShow;
    PlayheadFrame := NewFrame;
    if NewShow then
      EnsureFrameVisible(PlayheadFrame);
    DrawView;
  end;
end;

{ TDysTimeline }

constructor TDysTimeline.InitPane(Bounds: TRect);
var
  R: TRect;
begin
  inherited InitPane(Bounds, 'Timeline');
  R := ContentRect;
  Content := New(PDysTimelineContent, Init(R));
  Insert(Content);
  Focusable := Content;
end;

initialization
  { Wires DysWidgets.TDysToolBar's Record button to the real
    implementations - see DysWidgets.pas's own comment on why it can't
    `uses DysTimeline` directly to call these itself. }
  StartRecordingProc := @DysStartRecording;
  FinalizeRecordingProc := @DysFinalizeRecording;
  SeekPlaybackToCursorProc := @DysSeekPlaybackToCursor;
  ChopWaveformSelectionProc := @DysChopMarkedClipRegion;
  CycleTrackHeightProc := @DysCycleTrackHeight;

end.
