unit DysTimeline;

{ Center pane. Stage 7: a real grid - one row per track, a seconds ruler on
  top, committed clips drawn as solid blocks. A file dropped from the file
  pane arrives here as a "pending" (hovering) clip on the track the file
  pane's Enter selected - Left/Right nudges it along the grid, Up/Down
  changes which track it would land on, Enter commits it and pushes the
  track to the engine, Esc cancels it. Drag mode (Ctrl+S) stays a stub -
  that's selection editing, stage 8.

  The grid step (PixelsPerSecond, below) is a fixed constant for now, not
  wired to the toolbar's interval selector - that's stage 8 too, once the
  cycle button actually needs to change something.

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
  clips are shaded per-SampleID (SampleShadeAttr) rather than one fixed
  colour, with a forced black divider (DrawAdjoiningSeparators) wherever
  two same-shade clips are back-to-back and would otherwise look like one
  clip - see tui.md's Bindings and Free Vision notes for all four. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Dialogs, MsgBox, DysWidgets, Project,
  SampleTypes, AudioEngine, Waveform;

const
  { Fixed timeline scale: this many terminal columns per second of audio.
    No zoom/scroll yet - keep it simple until a real need for one shows up
    in daily use (stage 9). }
  PixelsPerSecond = 10;
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
    FramesPerCol: Int64;
    ShowPlayhead: Boolean;
    PlayheadFrame: Int64;
    { Transport loop range, -1 = unset - there's no per-clip/per-track loop
      concept in Project.pas to hook into (checked porting this from Eris),
      so this mirrors ArrangementView's own FLoopStart/FLoopEnd instead:
      global range pushed straight to AudioEngineSetLoop/AudioEngineClearLoop.
      See the 'l' key and tui.md's Bindings. }
    LoopStart: Int64;
    LoopEnd: Int64;
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
    { Polled from TDysnomiaApp.Idle (see DysnomiaApp.pas) - Free Vision has
      no timer, but TProgram.Idle runs on every pass of the event loop that
      finds no key/mouse event waiting, which is close enough to "as fast
      as the terminal can be redrawn" for a playhead. Only redraws when the
      position or play/stopped state actually changed, since Idle fires far
      more often than that. }
    procedure UpdatePlayhead;
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

implementation

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
  PendingAttr = $5F; { magenta bg, bright white fg - not placed yet }
  PlayheadAttr = $4F; { red bg, bright white fg - distinct from both clip colours }
  LoopAttr = $2F; { green bg, bright white fg - transport loop markers }
  BlockChar = #219; { CP437 solid block - see tui.md "Half-block glyphs" }
  PlayheadChar = '|';
  LoopChar = 'L';

  { A committed clip's colour, per-sample not per-clip: BlockChar is a solid
    CP437 glyph that fills the whole cell in the FOREGROUND colour - the
    background nibble underneath never shows through it - so "shade" here
    means picking a foreground, not a background. The 16-colour set only has
    three true grey/white tones (0 and 15 are the ramp's black/white
    endpoints, kept out of the rotation so a clip is never black-on-black or
    indistinguishable from PlayheadChar's own white-on-red): dark grey (8),
    light grey (7), bright white (15). See SampleShadeAttr. }
  ClipShades: array[0..2] of Byte = ($08, $07, $0F);
  SeparatorAttr = $00; { solid black - see DrawAdjoiningSeparators }

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

{ Deterministic per-sample shade, not per-clip - two clips referencing the
  same SampleID (the same audio file dropped twice) always render
  identically, matching "all break01.wav starts white" from the feature
  request. Knuth's multiplicative hash constant rather than SampleID mod 3
  so consecutive file drops don't visibly cycle 1-2-3-1-2-3 - it still has
  only 3 possible outputs (see ClipShades), it just scrambles which SampleID
  lands on which of the 3, and 3-way collisions are expected and handled by
  DrawAdjoiningSeparators below, not avoided here. }
function SampleShadeAttr(ASampleID: Integer): Word;
var
  H: LongWord;
begin
  H := LongWord(ASampleID) * 2654435761;
  Result := ClipShades[(H shr 28) mod Length(ClipShades)];
end;

{ Same-colour clips placed back-to-back (one ends exactly where the next
  starts) render as a single unbroken block with no visible seam between
  two different files - see the feature request. Paints a one-column black
  divider at the second clip's leading column whenever that happens; that
  column is "spent" on the divider rather than either clip, which is the
  best this grid's resolution (FramesPerCol frames/column) can do. }
procedure DrawAdjoiningSeparators(var B: TDrawBuffer; ATrack: Integer;
  AFramesPerCol: Int64; AWidth: Integer);
var
  i, j, Col: Integer;
  EndA, PosB: Int64;
begin
  for i := 0 to High(Project.Tracks[ATrack].Clips) do
  begin
    EndA := Project.Tracks[ATrack].Clips[i].Position +
      Project.Tracks[ATrack].Clips[i].Length;
    for j := 0 to High(Project.Tracks[ATrack].Clips) do
    begin
      if i = j then
        Continue;
      PosB := Project.Tracks[ATrack].Clips[j].Position;
      if PosB <> EndA then
        Continue;
      if SampleShadeAttr(Project.Tracks[ATrack].Clips[j].SampleID) <>
         SampleShadeAttr(Project.Tracks[ATrack].Clips[i].SampleID) then
        Continue;
      Col := LabelWidth + (PosB div AFramesPerCol);
      if (Col >= LabelWidth) and (Col <= AWidth - 1) then
        MoveChar(B[Col], BlockChar, SeparatorAttr, 1);
    end;
  end;
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
    Sample := Project.SamplePool[Clip.SampleID];
    Items[i].Data := Sample.Data;
    Items[i].FrameCount := Sample.FrameCount;
    Items[i].Channels := Sample.Channels;
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

    Items[i].TransientCount := Length(Project.SampleTransients[Clip.SampleID]);
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

  Project.Tracks[ATrack].Clips[AClipIndex].WarpMode := SampleTypes.WarpModeRePitch;
  SetLength(Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers, 2);
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[0].SourceFrame := 0;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[0].TimelineFrame := 0;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[1].SourceFrame := OrigLength;
  Project.Tracks[ATrack].Clips[AClipIndex].WarpMarkers[1].TimelineFrame := TargetLength;
  Project.Tracks[ATrack].Clips[AClipIndex].Length := TargetLength;

  PushTrackToEngine(ATrack);
end;

{ TDysTimelineContent }

constructor TDysTimelineContent.Init(Bounds: TRect);
begin
  inherited Init(Bounds);
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
  FramesPerCol := AudioEngine.ProjectSampleRate div PixelsPerSecond;
  ShowPlayhead := False;
  PlayheadFrame := 0;
  LoopStart := -1;
  LoopEnd := -1;
  ActiveTimelineContent := @Self;
end;

{ Fills B[LabelWidth..Size.X-1] with a clip block wherever [APos, APos+ALen)
  lands, in column space - shared by the committed-clip loop and the
  pending-overlay draw below. }
procedure DrawSpan(var B: TDrawBuffer; AFramesPerCol: Int64; AWidth: Integer;
  APos, ALen: Int64; AAttr: Word);
var
  StartCol, EndCol: Integer;
begin
  if (ALen <= 0) or (AFramesPerCol <= 0) then
    Exit;
  StartCol := LabelWidth + (APos div AFramesPerCol);
  EndCol := LabelWidth + ((APos + ALen - 1) div AFramesPerCol);
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
  Col, Track, Row, i, Sec, PlayCol, CursorCol, LoopStartCol, LoopEndCol: Integer;
  Lbl, SecStr: string;
begin
  PlayCol := -1;
  if ShowPlayhead then
  begin
    PlayCol := LabelWidth + (PlayheadFrame div FramesPerCol);
    if (PlayCol < LabelWidth) or (PlayCol > Size.X - 1) then
      PlayCol := -1; { off the visible grid - draw nothing rather than clamp
                        it to an edge, which would misleadingly suggest the
                        playhead is still in view }
  end;

  LoopStartCol := -1;
  if LoopStart >= 0 then
  begin
    LoopStartCol := LabelWidth + (LoopStart div FramesPerCol);
    if (LoopStartCol < LabelWidth) or (LoopStartCol > Size.X - 1) then
      LoopStartCol := -1;
  end;
  LoopEndCol := -1;
  if LoopEnd >= 0 then
  begin
    LoopEndCol := LabelWidth + (LoopEnd div FramesPerCol);
    if (LoopEndCol < LabelWidth) or (LoopEndCol > Size.X - 1) then
      LoopEndCol := -1;
  end;

  { Ruler: a tick every column, the elapsed second written out at every
    whole-second column. Jumping Col past a multi-digit label (rather than
    just Inc(Col)) matters once Sec reaches two digits - otherwise the next
    column's '.' would immediately overwrite the label's second digit. }
  MoveChar(B, ' ', NormalAttr, Size.X);
  MoveStr(B, StringOfChar(' ', LabelWidth), NormalAttr);
  Col := LabelWidth;
  while Col < Size.X do
  begin
    if ((Col - LabelWidth) mod PixelsPerSecond) = 0 then
    begin
      Sec := (Col - LabelWidth) div PixelsPerSecond;
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

  { One grid row per track, clipped to however many rows actually fit. }
  for Track := 0 to Project.TrackCount - 1 do
  begin
    Row := 1 + Track;
    if Row >= Size.Y then
      Break;

    MoveChar(B, ' ', NormalAttr, Size.X);
    Lbl := TrackTypeChar(Track);
    while Length(Lbl) < LabelWidth do
      Lbl := Lbl + ' ';
    if (Track = CursorTrack) and CursorInLabel then
      MoveStr(B, Lbl, CursorAttr)
    else
      MoveStr(B, Lbl, NormalAttr);

    Col := LabelWidth;
    while Col < Size.X do
    begin
      if ((Col - LabelWidth) mod PixelsPerSecond) = 0 then
        MoveChar(B[Col], '|', NormalAttr, 1)
      else
        MoveChar(B[Col], '.', NormalAttr, 1);
      Inc(Col);
    end;

    for i := 0 to High(Project.Tracks[Track].Clips) do
      DrawSpan(B, FramesPerCol, Size.X, Project.Tracks[Track].Clips[i].Position,
        Project.Tracks[Track].Clips[i].Length,
        SampleShadeAttr(Project.Tracks[Track].Clips[i].SampleID));
    DrawAdjoiningSeparators(B, Track, FramesPerCol, Size.X);

    if Pending and (Track = CursorTrack) then
      DrawSpan(B, FramesPerCol, Size.X, CursorFrame, PendingLength, PendingAttr);

    if LoopStartCol >= 0 then
      MoveChar(B[LoopStartCol], LoopChar, LoopAttr, 1);
    if LoopEndCol >= 0 then
      MoveChar(B[LoopEndCol], LoopChar, LoopAttr, 1);

    if PlayCol >= 0 then
      MoveChar(B[PlayCol], PlayheadChar, PlayheadAttr, 1);

    { The grid-side half of the track cursor - only drawn once it has moved
      off the label column (see CursorInLabel), so the label highlight and
      this marker are never both showing for the same track at once. }
    if (Track = CursorTrack) and (not CursorInLabel) then
    begin
      CursorCol := LabelWidth + (CursorFrame div FramesPerCol);
      if (CursorCol >= LabelWidth) and (CursorCol <= Size.X - 1) then
        MoveChar(B[CursorCol], BlockChar, CursorAttr, 1);
    end;

    WriteLine(0, Row, Size.X, 1, B);
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
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbDown:
        begin
          if CursorTrack < Project.TrackCount - 1 then
            Inc(CursorTrack);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbLeft:
        begin
          if not CursorInLabel then
          begin
            if CursorFrame <= 0 then
              CursorInLabel := True
            else
            begin
              Dec(CursorFrame, FramesPerCol);
              if CursorFrame < 0 then
                CursorFrame := 0;
            end;
          end;
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbRight:
        begin
          if CursorInLabel then
            CursorInLabel := False
          else
            Inc(CursorFrame, FramesPerCol);
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbEnter:
        begin
          PlaceOverlay;
          ClearEvent(Event);
          Exit;
        end;
      kbEsc:
        begin
          CancelOverlay;
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
    case UpCase(Event.CharCode) of
      'W':
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
      'L':
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
  if ((Event.What = evKeyDown) and (Event.KeyCode = kbCtrlEnter)) or
     ((Event.What = evMouseDown) and (Event.Buttons and mbRightButton <> 0))
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

end.
