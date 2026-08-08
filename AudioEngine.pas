unit AudioEngine;

{$mode objfpc}{$H+}

interface

procedure AudioEngineInit;
procedure AudioEngineShutdown;
procedure AudioEnginePushLoadClip(AData: PSingle; AFrameCount, AChannels: Integer);
procedure AudioEnginePlay;
procedure AudioEngineStop;
procedure AudioEngineSeek(AFrame: Integer);
function AudioEngineIsPlaying: Boolean;
function AudioEngineHasClip: Boolean;
function AudioEngineGetPosition: Integer;

implementation

uses
  Classes, SysUtils, AudioBackend, ALSABackend;

const
  BlockFrames = 512;
  OutputChannels = 2;
  OutputSampleRate = 44100;
  RingBufferCapacity = 32;

type
  TCommandKind = (ckLoadClip, ckPlay, ckStop, ckSeek);

  TCommand = record
    Kind: TCommandKind;
    Data: PSingle;
    FrameCount: Integer;
    Channels: Integer;
    Param: Integer;
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

  ClipData: PSingle;
  ClipFrameCount: Integer;
  ClipChannels: Integer;
  ReadPos: Integer;
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
      ckLoadClip:
        begin
          ClipData := Cmd.Data;
          ClipFrameCount := Cmd.FrameCount;
          ClipChannels := Cmd.Channels;
          ReadPos := 0;
          Playing := False;
        end;
      ckPlay:
        if ClipData <> nil then
        begin
          if ReadPos >= ClipFrameCount then
            ReadPos := 0;
          Playing := True;
        end;
      ckStop:
        Playing := False;
      ckSeek:
        if ClipData <> nil then
        begin
          ReadPos := Cmd.Param;
          if ReadPos < 0 then
            ReadPos := 0
          else if ReadPos >= ClipFrameCount then
            ReadPos := ClipFrameCount - 1;
        end;
    end;
end;

procedure FillBlock;
var
  Frame, FramesLeft, SrcIdx: Integer;
begin
  FillChar(MixBuffer^, BlockFrames * OutputChannels * SizeOf(Single), 0);

  if not Playing then
    Exit;

  FramesLeft := ClipFrameCount - ReadPos;
  if FramesLeft > BlockFrames then
    FramesLeft := BlockFrames;

  for Frame := 0 to FramesLeft - 1 do
  begin
    SrcIdx := (ReadPos + Frame) * ClipChannels;
    if ClipChannels = 1 then
    begin
      MixBuffer[Frame * OutputChannels] := ClipData[SrcIdx];
      MixBuffer[Frame * OutputChannels + 1] := ClipData[SrcIdx];
    end
    else
    begin
      MixBuffer[Frame * OutputChannels] := ClipData[SrcIdx];
      MixBuffer[Frame * OutputChannels + 1] := ClipData[SrcIdx + 1];
    end;
  end;

  Inc(ReadPos, FramesLeft);
  if ReadPos >= ClipFrameCount then
  begin
    Playing := False;
    ReadPos := 0;
  end;
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
begin
  RingHead := 0;
  RingTail := 0;
  ClipData := nil;
  ClipFrameCount := 0;
  ClipChannels := 0;
  ReadPos := 0;
  Playing := False;

  GetMem(MixBuffer, BlockFrames * OutputChannels * SizeOf(Single));

  Backend := CreateALSABackend;
  Backend.Open(OutputSampleRate, OutputChannels, BlockFrames);

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

procedure AudioEnginePushLoadClip(AData: PSingle; AFrameCount, AChannels: Integer);
var
  Cmd: TCommand;
begin
  Cmd.Kind := ckLoadClip;
  Cmd.Data := AData;
  Cmd.FrameCount := AFrameCount;
  Cmd.Channels := AChannels;
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

procedure AudioEngineSeek(AFrame: Integer);
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
begin
  Result := ClipData <> nil;
end;

function AudioEngineGetPosition: Integer;
begin
  Result := ReadPos;
end;

end.
