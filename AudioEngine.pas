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
function AudioEngineIsPlaying: Boolean;
function AudioEngineHasClip: Boolean;
function AudioEngineGetPosition: Int64;

implementation

uses
  Classes, SysUtils, AudioBackend, ALSABackend;

const
  BlockFrames = 512;
  OutputChannels = 2;
  RingBufferCapacity = 32;
  MaxTracks = 4;

type
  TCommandKind = (ckSetTrackClips, ckPlay, ckStop, ckSeek);

  TCommand = record
    Kind: TCommandKind;
    TrackIndex: Integer;
    Items: PPlaybackClip;
    Count: Integer;
    Param: Int64;
  end;

  TTrackClips = record
    Items: PPlaybackClip;
    Count: Integer;
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

procedure DrainCommands;
var
  Cmd: TCommand;
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
    end;
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

  if not Playing then
    Exit;

  for Frame := 0 to BlockFrames - 1 do
  begin
    GlobalFrame := Playhead + Frame;
    L := 0;
    R := 0;

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

    if L > 1.0 then L := 1.0 else if L < -1.0 then L := -1.0;
    if R > 1.0 then R := 1.0 else if R < -1.0 then R := -1.0;
    MixBuffer[Frame * OutputChannels] := L;
    MixBuffer[Frame * OutputChannels + 1] := R;
  end;

  Inc(Playhead, BlockFrames);
end;

procedure TPlaybackThread.Execute;
begin
  while not Terminated do
  begin
    DrainCommands;
    if Playing then
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
