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

  CaptureHandle: Psnd_pcm_t = nil;
  CaptureChannelCount: Integer = 2;
  CaptureConvertBuffer: PSmallInt = nil;

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

{ Line-in capture - the default ALSA capture device, opened as an independent
  PCM stream from the playback one above (own handle, own params, own
  latency/buffer-frames setting - see AudioEngine's separate "input buffer"
  size). Same S16_LE/interleaved/blocking-I/O shape as playback, just read
  instead of write. }
function ALSACaptureOpen(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
var
  Err: cint;
  LatencyUs: cuint;
begin
  Result := False;
  CaptureChannelCount := AChannels;

  Err := snd_pcm_open(@CaptureHandle, 'default', SND_PCM_STREAM_CAPTURE, 0);
  if Err < 0 then
  begin
    CaptureHandle := nil;
    Exit;
  end;

  LatencyUs := (ABufferFrames * 4 * 1000000) div ASampleRate;
  Err := snd_pcm_set_params(CaptureHandle, SND_PCM_FORMAT_S16_LE,
    SND_PCM_ACCESS_RW_INTERLEAVED, AChannels, ASampleRate, 1, LatencyUs);
  if Err < 0 then
  begin
    snd_pcm_close(CaptureHandle);
    CaptureHandle := nil;
    Exit;
  end;

  Err := snd_pcm_prepare(CaptureHandle);
  if Err < 0 then
  begin
    snd_pcm_close(CaptureHandle);
    CaptureHandle := nil;
    Exit;
  end;

  GetMem(CaptureConvertBuffer, ABufferFrames * AChannels * SizeOf(SmallInt));
  Result := True;
end;

function ALSACaptureRead(ABuffer: PSingle; AFrameCount: Integer): Boolean;
var
  i, SampleCount: Integer;
  Frames: clong;
begin
  Result := False;
  if CaptureHandle = nil then
    Exit;

  Frames := snd_pcm_readi(CaptureHandle, CaptureConvertBuffer, AFrameCount);
  if Frames < 0 then
  begin
    if snd_pcm_prepare(CaptureHandle) >= 0 then
      Frames := snd_pcm_readi(CaptureHandle, CaptureConvertBuffer, AFrameCount)
    else
      Exit;
  end;
  if Frames < 0 then
    Exit;

  { blocking readi (SND_PCM_ACCESS_RW_INTERLEAVED, same as ALSAWriteBlock's
    writei) only ever returns short of AFrameCount on error, already handled
    above - a non-negative result here always means the full request }
  SampleCount := AFrameCount * CaptureChannelCount;
  for i := 0 to SampleCount - 1 do
    ABuffer[i] := CaptureConvertBuffer[i] / 32768.0;
  Result := True;
end;

procedure ALSACaptureClose;
begin
  if CaptureHandle <> nil then
  begin
    snd_pcm_close(CaptureHandle);
    CaptureHandle := nil;
  end;
  if CaptureConvertBuffer <> nil then
  begin
    FreeMem(CaptureConvertBuffer);
    CaptureConvertBuffer := nil;
  end;
end;

function CreateALSABackend: TAudioBackend;
begin
  Result.Open := @ALSAOpen;
  Result.WriteBlock := @ALSAWriteBlock;
  Result.Close := @ALSAClose;
  Result.CaptureOpen := @ALSACaptureOpen;
  Result.CaptureRead := @ALSACaptureRead;
  Result.CaptureClose := @ALSACaptureClose;
end;

end.
