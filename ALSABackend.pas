unit ALSABackend;

{$mode objfpc}{$H+}

interface

uses
  AudioBackend;

function CreateALSABackend: TAudioBackend;

implementation

uses
  ALSA, ctypes;

var
  Handle: Psnd_pcm_t = nil;
  ChannelCount: Integer = 2;
  ConvertBuffer: PSmallInt = nil;

function ALSAOpen(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
var
  Err: cint;
  LatencyUs: cuint;
begin
  Result := False;
  ChannelCount := AChannels;

  Err := snd_pcm_open(@Handle, 'default', SND_PCM_STREAM_PLAYBACK, 0);
  if Err < 0 then
  begin
    Handle := nil;
    Exit;
  end;

  LatencyUs := (ABufferFrames * 4 * 1000000) div ASampleRate;
  Err := snd_pcm_set_params(Handle, SND_PCM_FORMAT_S16_LE,
    SND_PCM_ACCESS_RW_INTERLEAVED, AChannels, ASampleRate, 1, LatencyUs);
  if Err < 0 then
  begin
    snd_pcm_close(Handle);
    Handle := nil;
    Exit;
  end;

  Err := snd_pcm_prepare(Handle);
  if Err < 0 then
  begin
    snd_pcm_close(Handle);
    Handle := nil;
    Exit;
  end;

  GetMem(ConvertBuffer, ABufferFrames * AChannels * SizeOf(SmallInt));
  Result := True;
end;

function ALSAWriteBlock(ABuffer: PSingle; AFrameCount: Integer): Boolean;
var
  i, SampleCount: Integer;
  Value: Single;
  Frames: clong;
begin
  Result := False;
  if Handle = nil then
    Exit;

  SampleCount := AFrameCount * ChannelCount;
  for i := 0 to SampleCount - 1 do
  begin
    Value := ABuffer[i];
    if Value > 1.0 then
      Value := 1.0
    else if Value < -1.0 then
      Value := -1.0;
    ConvertBuffer[i] := Round(Value * 32767.0);
  end;

  Frames := snd_pcm_writei(Handle, ConvertBuffer, AFrameCount);
  if Frames < 0 then
  begin
    if snd_pcm_prepare(Handle) >= 0 then
      Frames := snd_pcm_writei(Handle, ConvertBuffer, AFrameCount);
  end;

  Result := Frames >= 0;
end;

procedure ALSAClose;
begin
  if Handle <> nil then
  begin
    snd_pcm_close(Handle);
    Handle := nil;
  end;
  if ConvertBuffer <> nil then
  begin
    FreeMem(ConvertBuffer);
    ConvertBuffer := nil;
  end;
end;

function CreateALSABackend: TAudioBackend;
begin
  Result.Open := @ALSAOpen;
  Result.WriteBlock := @ALSAWriteBlock;
  Result.Close := @ALSAClose;
end;

end.
