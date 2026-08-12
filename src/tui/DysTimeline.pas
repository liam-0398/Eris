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
  cycle button actually needs to change something. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Dialogs, MsgBox, DysWidgets, Project,
  SampleTypes, AudioEngine;

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
    Pending: Boolean;
    PendingSampleID: Integer;
    PendingLength: Int64;
    FramesPerCol: Int64;
    ShowPlayhead: Boolean;
    PlayheadFrame: Int64;
    constructor Init(Bounds: TRect);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure BeginOverlay(ASampleID: Integer; ALength: Int64);
    procedure CancelOverlay;
    procedure PlaceOverlay;
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

const
  NormalAttr = $0F; { black bg, bright white fg - matches DysWidgets' PaneNorm }
  CursorAttr = $70; { light grey bg, black fg, no blink - matches PaneSel }
  ClipAttr   = $1F; { blue bg, bright white fg - a committed clip }
  PendingAttr = $5F; { magenta bg, bright white fg - not placed yet }
  PlayheadAttr = $4F; { red bg, bright white fg - distinct from both clip colours }
  BlockChar = #219; { CP437 solid block - see tui.md "Half-block glyphs" }
  PlayheadChar = '|';

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
  Pending := False;
  PendingSampleID := -1;
  PendingLength := 0;
  FramesPerCol := AudioEngine.ProjectSampleRate div PixelsPerSecond;
  ShowPlayhead := False;
  PlayheadFrame := 0;
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
  Col, Track, Row, i, Sec, PlayCol: Integer;
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
    Lbl := 'T' + IntToStr(Track + 1);
    while Length(Lbl) < LabelWidth do
      Lbl := Lbl + ' ';
    if Track = CursorTrack then
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
        Project.Tracks[Track].Clips[i].Length, ClipAttr);

    if Pending and (Track = CursorTrack) then
      DrawSpan(B, FramesPerCol, Size.X, CursorFrame, PendingLength, PendingAttr);

    if PlayCol >= 0 then
      MoveChar(B[PlayCol], PlayheadChar, PlayheadAttr, 1);

    WriteLine(0, Row, Size.X, 1, B);
  end;
end;

procedure TDysTimelineContent.HandleEvent(var Event: TEvent);
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
          Dec(CursorFrame, FramesPerCol);
          if CursorFrame < 0 then
            CursorFrame := 0;
          DrawView;
          ClearEvent(Event);
          Exit;
        end;
      kbRight:
        begin
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
    end;
  end;
  inherited HandleEvent(Event);
end;

procedure TDysTimelineContent.BeginOverlay(ASampleID: Integer; ALength: Int64);
begin
  PendingSampleID := ASampleID;
  PendingLength := ALength;
  Pending := True;
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
