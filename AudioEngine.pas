unit AudioEngine;

{$mode objfpc}{$H+}

interface

const
  ProjectSampleRate = 44100;

type
  TPlaybackClip = record
    Data: PSingle;
    FrameCount: Integer;
    Channels: Integer;
    Offset: Int64;
    Length: Int64;
    Position: Int64;
    Gain: Single;
  end;
  PPlaybackClip = ^TPlaybackClip;

procedure AudioEngineInit;
procedure AudioEngineShutdown;
procedure AudioEngineSetTrackClips(ATrackIndex: Integer; AItems: PPlaybackClip;
  ACount: Integer);
procedure AudioEnginePlay;
procedure AudioEngineStop;
procedure AudioEngineSeek(AFrame: Int64);
procedure AudioEngineTriggerNote(ATrackIndex: Integer; AData: PSingle;
  AFrameCount, AChannels: Integer; ASemitoneOffset: Single; AGain: Single);
function AudioEngineIsPlaying: Boolean;
function AudioEngineHasClip: Boolean;
function AudioEngineGetPosition: Int64;

implementation

uses
  Classes, SysUtils, AudioBackend, ALSABackend, Resample;

const
  BlockFrames = 512;
  OutputChannels = 2;
  RingBufferCapacity = 32;
  MaxTracks = 4;
  NoteFadeSamples = 128; { short crossfade on hard-retrigger, avoids a click }

type
  TCommandKind = (ckSetTrackClips, ckPlay, ckStop, ckSeek, ckTriggerNote);

  TCommand = record
    Kind: TCommandKind;
    TrackIndex: Integer;
    Items: PPlaybackClip;
    Count: Integer;
    Param: Int64;
    NoteData: PSingle;
    NoteFrameCount: Integer;
    NoteChannels: Integer;
    NoteRate: Double;
    NoteGain: Single;
  end;

  TTrackClips = record
    Items: PPlaybackClip;
    Count: Integer;
  end;

  TLiveNote = record
    Data: PSingle;
    FrameCount: Integer;
    Channels: Integer;
    Position: Double;
    Rate: Double;
    Gain: Single;
    FadeGain: Single;
    FadeStep: Single;
    Active: Boolean;
  end;

  TPlaybackThread = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  Backend: TAudioBackend;
  PlaybackThread: TPlaybackThread;
  MixBuffer: PSingle;

  RingBuffer: array[0..RingBufferCapacity - 1] of TCommand;
  RingHead: Integer;
  RingTail: Integer;

  TrackClips: array[0..MaxTracks - 1] of TTrackClips;
  Playhead: Int64;
  Playing: Boolean;

  LiveNotes: array[0..MaxTracks - 1] of TLiveNote;
  FadingNotes: array[0..MaxTracks - 1] of TLiveNote;

function PushCommand(const ACmd: TCommand): Boolean;
var
  NextHead: Integer;
begin
  NextHead := (RingHead + 1) mod RingBufferCapacity;
  if NextHead = RingTail then
    Exit(False);
  RingBuffer[RingHead] := ACmd;
  RingHead := NextHead;
  Result := True;
end;

function PopCommand(out ACmd: TCommand): Boolean;
begin
  if RingTail = RingHead then
    Exit(False);
  ACmd := RingBuffer[RingTail];
  RingTail := (RingTail + 1) mod RingBufferCapacity;
  Result := True;
end;

function AnyLiveNoteActive: Boolean;
var
  t: Integer;
begin
  Result := False;
  for t := 0 to MaxTracks - 1 do
    if LiveNotes[t].Active or FadingNotes[t].Active then
      Exit(True);
end;

procedure DrainCommands;
var
  Cmd: TCommand;
  t: Integer;
begin
  while PopCommand(Cmd) do
    case Cmd.Kind of
      ckSetTrackClips:
        begin
          TrackClips[Cmd.TrackIndex].Items := Cmd.Items;
          TrackClips[Cmd.TrackIndex].Count := Cmd.Count;
        end;
      ckPlay:
        Playing := True;
      ckStop:
        Playing := False;
      ckSeek:
        begin
          Playhead := Cmd.Param;
          if Playhead < 0 then
            Playhead := 0;
        end;
      ckTriggerNote:
        begin
          t := Cmd.TrackIndex;
          if LiveNotes[t].Active then
          begin
            FadingNotes[t] := LiveNotes[t];
            FadingNotes[t].FadeStep := 1.0 / NoteFadeSamples;
          end;

          LiveNotes[t].Data := Cmd.NoteData;
          LiveNotes[t].FrameCount := Cmd.NoteFrameCount;
          LiveNotes[t].Channels := Cmd.NoteChannels;
          LiveNotes[t].Position := 0;
          LiveNotes[t].Rate := Cmd.NoteRate;
          LiveNotes[t].Gain := Cmd.NoteGain;
          LiveNotes[t].FadeGain := 1.0;
          LiveNotes[t].FadeStep := 0;
          LiveNotes[t].Active := True;
        end;
    end;
end;

procedure MixNoteVoice(var ANote: TLiveNote; AFadeGain: Single; var L, R: Single);
var
  s: Single;
begin
  if not ANote.Active then
    Exit;
  if Trunc(ANote.Position) >= ANote.FrameCount then
  begin
    ANote.Active := False;
    Exit;
  end;

  if ANote.Channels = 1 then
  begin
    s := Interpolate(ANote.Data, ANote.FrameCount, ANote.Channels, 0, ANote.Position) *
      ANote.Gain * AFadeGain;
    L := L + s;
    R := R + s;
  end
  else
  begin
    L := L + Interpolate(ANote.Data, ANote.FrameCount, ANote.Channels, 0,
      ANote.Position) * ANote.Gain * AFadeGain;
    R := R + Interpolate(ANote.Data, ANote.FrameCount, ANote.Channels, 1,
      ANote.Position) * ANote.Gain * AFadeGain;
  end;

  ANote.Position := ANote.Position + ANote.Rate;
end;

procedure FillBlock;
var
  Frame, t, i: Integer;
  GlobalFrame, SrcFrame: Int64;
  Clip: PPlaybackClip;
  L, R: Single;
  SrcIdx: Integer;
begin
  FillChar(MixBuffer^, BlockFrames * OutputChannels * SizeOf(Single), 0);

  for Frame := 0 to BlockFrames - 1 do
  begin
    L := 0;
    R := 0;

    if Playing then
    begin
      GlobalFrame := Playhead + Frame;
      for t := 0 to MaxTracks - 1 do
        for i := 0 to TrackClips[t].Count - 1 do
        begin
          Clip := @(TrackClips[t].Items[i]);
          if (GlobalFrame < Clip^.Position) or
            (GlobalFrame >= Clip^.Position + Clip^.Length) then
            Continue;

          SrcFrame := Clip^.Offset + (GlobalFrame - Clip^.Position);
          if (SrcFrame < 0) or (SrcFrame >= Clip^.FrameCount) then
            Continue;

          SrcIdx := SrcFrame * Clip^.Channels;
          if Clip^.Channels = 1 then
          begin
            L := L + Clip^.Data[SrcIdx] * Clip^.Gain;
            R := R + Clip^.Data[SrcIdx] * Clip^.Gain;
          end
          else
          begin
            L := L + Clip^.Data[SrcIdx] * Clip^.Gain;
            R := R + Clip^.Data[SrcIdx + 1] * Clip^.Gain;
          end;
        end;
    end;

    for t := 0 to MaxTracks - 1 do
    begin
      MixNoteVoice(LiveNotes[t], 1.0, L, R);
      if FadingNotes[t].Active then
      begin
        MixNoteVoice(FadingNotes[t], FadingNotes[t].FadeGain, L, R);
        FadingNotes[t].FadeGain := FadingNotes[t].FadeGain - FadingNotes[t].FadeStep;
        if FadingNotes[t].FadeGain <= 0 then
          FadingNotes[t].Active := False;
      end;
    end;

    if L > 1.0 then L := 1.0 else if L < -1.0 then L := -1.0;
    if R > 1.0 then R := 1.0 else if R < -1.0 then R := -1.0;
    MixBuffer[Frame * OutputChannels] := L;
    MixBuffer[Frame * OutputChannels + 1] := R;
  end;

  if Playing then
    Inc(Playhead, BlockFrames);
end;

procedure TPlaybackThread.Execute;
begin
  while not Terminated do
  begin
    DrainCommands;
    if Playing or AnyLiveNoteActive then
    begin
      FillBlock;
      Backend.WriteBlock(MixBuffer, BlockFrames);
    end
    else
      Sleep(10);
  end;
end;

procedure AudioEngineInit;
var
  i: Integer;
begin
  RingHead := 0;
  RingTail := 0;
  Playhead := 0;
  Playing := False;
  for i := 0 to MaxTracks - 1 do
  begin
    TrackClips[i].Items := nil;
    TrackClips[i].Count := 0;
    LiveNotes[i].Active := False;
    FadingNotes[i].Active := False;
  end;

  GetMem(MixBuffer, BlockFrames * OutputChannels * SizeOf(Single));

  Backend := CreateALSABackend;
  Backend.Open(ProjectSampleRate, OutputChannels, BlockFrames);

  PlaybackThread := TPlaybackThread.Create(False);
  PlaybackThread.FreeOnTerminate := False;
end;

procedure AudioEngineShutdown;
begin
  if PlaybackThread <> nil then
  begin
    PlaybackThread.Terminate;
    PlaybackThread.WaitFor;
    FreeAndNil(PlaybackThread);
  end;

  Backend.Close;

  if MixBuffer <> nil then
  begin
    FreeMem(MixBuffer);
    MixBuffer := nil;
  end;
end;

procedure AudioEngineSetTrackClips(ATrackIndex: Integer; AItems: PPlaybackClip;
  ACount: Integer);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckSetTrackClips;
  Cmd.TrackIndex := ATrackIndex;
  Cmd.Items := AItems;
  Cmd.Count := ACount;
  PushCommand(Cmd);
end;

procedure AudioEnginePlay;
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckPlay;
  PushCommand(Cmd);
end;

procedure AudioEngineStop;
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckStop;
  PushCommand(Cmd);
end;

procedure AudioEngineSeek(AFrame: Int64);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckSeek;
  Cmd.Param := AFrame;
  PushCommand(Cmd);
end;

procedure AudioEngineTriggerNote(ATrackIndex: Integer; AData: PSingle;
  AFrameCount, AChannels: Integer; ASemitoneOffset: Single; AGain: Single);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckTriggerNote;
  Cmd.TrackIndex := ATrackIndex;
  Cmd.NoteData := AData;
  Cmd.NoteFrameCount := AFrameCount;
  Cmd.NoteChannels := AChannels;
  Cmd.NoteRate := SemitonesToRate(ASemitoneOffset);
  Cmd.NoteGain := AGain;
  PushCommand(Cmd);
end;

function AudioEngineIsPlaying: Boolean;
begin
  Result := Playing;
end;

function AudioEngineHasClip: Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to MaxTracks - 1 do
    if TrackClips[i].Count > 0 then
      Exit(True);
end;

function AudioEngineGetPosition: Int64;
begin
  Result := Playhead;
end;

end.
