unit DirectSoundBackend;

{$mode objfpc}{$H+}

{ Windows audio backend. Only ever built when targeting Windows - see the
  {$IFDEF WINDOWS} around its one call site in AudioEngine.pas - so this unit
  itself doesn't need cross-platform stubbing; everything below the interface
  guard below is Windows-only Win32 API + a hand-rolled DirectSound streaming
  buffer, mirroring the same TAudioBackend contract ALSABackend.pas fills in
  on Linux. }

interface

uses
  AudioBackend;

function CreateDirectSoundBackend: TAudioBackend;

{ How much already-written audio still sits ahead of the hardware play cursor,
  in frames. The engine advances its playhead the instant it hands a block to
  WriteBlock, but that block is not heard until the ring drains down to it, so
  the UI has to subtract this to show where playback actually is. Callable
  from any thread; 0 before the buffer is playing. }
function DirectSoundQueuedFrames: Integer;

implementation

{$IFDEF WINDOWS}
uses
  Windows, DirectSound;

const
  BufferBlocks = 8; { how many WriteBlock-sized chunks the ring buffer holds -
    generous headroom since, unlike ALSA's blocking write, DirectSound needs
    our own Sleep-based backpressure below to avoid overwriting unplayed audio }

var
  DS: IDirectSound = nil;
  DSBuffer: IDirectSoundBuffer = nil;
  BytesPerFrame: Integer = 4; { channels * 16-bit }
  BufferSizeBytes: DWord = 0;
  WriteCursorBytes: DWord = 0;
  Started: Boolean = False;
  ConvertBuffer: PSmallInt = nil;
  TimerPeriodSet: Boolean = False;

{ Windows' default scheduler tick is ~15.6ms, so the Sleep(1) backpressure in
  WriteBlock below really sleeps for three or four blocks at a time: the ring
  gets filled in lumps, and everything paced off it - the playhead the UI
  reads, the poll timer that reads it - moves in lumps too. Asking for 1ms
  resolution while a stream is open makes that pacing match the block rate.
  Declared straight against winmm rather than pulling in MMSystem. }
function timeBeginPeriod(uPeriod: UINT): UINT; stdcall;
  external 'winmm.dll' name 'timeBeginPeriod';
function timeEndPeriod(uPeriod: UINT): UINT; stdcall;
  external 'winmm.dll' name 'timeEndPeriod';

function DirectSoundOpen(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
var
  Fmt: TWaveFormatEx;
  Desc: TDSBufferDesc;
  Hr: HRESULT;
begin
  Result := False;
  WriteCursorBytes := 0;
  Started := False;

  Hr := DirectSoundCreate(nil, DS, nil);
  if Hr <> DS_OK then
  begin
    DS := nil;
    Exit;
  end;

  { GetDesktopWindow is a safe generic handle for an audio engine that has no
    window of its own to hand in - a long-standing, widely used fallback for
    exactly this situation }
  Hr := DS.SetCooperativeLevel(GetDesktopWindow, DSSCL_PRIORITY);
  if Hr <> DS_OK then
  begin
    DS := nil;
    Exit;
  end;

  BytesPerFrame := AChannels * SizeOf(SmallInt);
  BufferSizeBytes := DWord(ABufferFrames * BytesPerFrame * BufferBlocks);

  FillChar(Fmt, SizeOf(Fmt), 0);
  Fmt.wFormatTag := WAVE_FORMAT_PCM;
  Fmt.nChannels := AChannels;
  Fmt.nSamplesPerSec := ASampleRate;
  Fmt.wBitsPerSample := 16;
  Fmt.nBlockAlign := BytesPerFrame;
  Fmt.nAvgBytesPerSec := DWord(ASampleRate * BytesPerFrame);

  FillChar(Desc, SizeOf(Desc), 0);
  Desc.dwSize := SizeOf(Desc);
  Desc.dwFlags := DSBCAPS_GETCURRENTPOSITION2 or DSBCAPS_GLOBALFOCUS or
    DSBCAPS_CTRLVOLUME;
  Desc.dwBufferBytes := BufferSizeBytes;
  Desc.lpwfxFormat := @Fmt;

  Hr := DS.CreateSoundBuffer(Desc, DSBuffer, nil);
  if Hr <> DS_OK then
  begin
    DSBuffer := nil;
    DS := nil;
    Exit;
  end;

  GetMem(ConvertBuffer, ABufferFrames * AChannels * SizeOf(SmallInt));

  { see TimerPeriodSet's declaration - held only while a stream is open }
  if not TimerPeriodSet then
    TimerPeriodSet := timeBeginPeriod(1) = 0;

  Result := True;
end;

function DirectSoundWriteBlock(ABuffer: PSingle; AFrameCount: Integer): Boolean;
var
  i, SampleCount, BytesNeeded: Integer;
  Value: Single;
  PlayCursor, WriteCursorHw, Used, Free: DWord;
  Ptr1, Ptr2: Pointer;
  Bytes1, Bytes2: DWord;
  Hr: HRESULT;
  Attempts: Integer;
begin
  Result := False;
  if (DS = nil) or (DSBuffer = nil) then
    Exit;

  SampleCount := AFrameCount * (BytesPerFrame div SizeOf(SmallInt));
  for i := 0 to SampleCount - 1 do
  begin
    Value := ABuffer[i];
    if Value > 1.0 then
      Value := 1.0
    else if Value < -1.0 then
      Value := -1.0;
    ConvertBuffer[i] := Round(Value * 32767.0);
  end;

  BytesNeeded := AFrameCount * BytesPerFrame;

  { wait until there's room ahead of the hardware's play cursor - this is our
    stand-in for ALSA's blocking snd_pcm_writei, since Lock/Unlock never
    blocks on its own }
  Attempts := 0;
  repeat
    if DSBuffer.GetCurrentPosition(PlayCursor, WriteCursorHw) <> DS_OK then
      Exit;
    Used := (WriteCursorBytes - PlayCursor + BufferSizeBytes) mod BufferSizeBytes;
    Free := BufferSizeBytes - Used;
    if Free >= DWord(BytesNeeded) then
      Break;
    Sleep(1);
    Inc(Attempts);
  until Attempts > 2000; { ~2s worst case - avoid ever hanging forever }

  Hr := DSBuffer.Lock(WriteCursorBytes, DWord(BytesNeeded), Ptr1, Bytes1, Ptr2,
    Bytes2, 0);
  if Hr <> DS_OK then
    Exit;

  if (Ptr1 <> nil) and (Bytes1 > 0) then
    Move(ConvertBuffer^, Ptr1^, Bytes1);
  if (Ptr2 <> nil) and (Bytes2 > 0) then
    Move(Pointer(PByte(ConvertBuffer) + Bytes1)^, Ptr2^, Bytes2);

  DSBuffer.Unlock(Ptr1, Bytes1, Ptr2, Bytes2);

  WriteCursorBytes := (WriteCursorBytes + DWord(BytesNeeded)) mod BufferSizeBytes;

  if not Started then
  begin
    DSBuffer.Play(0, 0, DSBPLAY_LOOPING);
    Started := True;
  end;

  Result := True;
end;

function DirectSoundQueuedFrames: Integer;
var
  PlayCursor, WriteCursorHw, Used: DWord;
begin
  Result := 0;
  if (DSBuffer = nil) or not Started then
    Exit;
  if DSBuffer.GetCurrentPosition(PlayCursor, WriteCursorHw) <> DS_OK then
    Exit;
  Used := (WriteCursorBytes - PlayCursor + BufferSizeBytes) mod BufferSizeBytes;
  Result := Used div DWord(BytesPerFrame);
end;

procedure DirectSoundClose;
begin
  if TimerPeriodSet then
  begin
    timeEndPeriod(1);
    TimerPeriodSet := False;
  end;
  if DSBuffer <> nil then
  begin
    DSBuffer.Stop;
    DSBuffer := nil;
  end;
  DS := nil; { interface references release themselves }
  if ConvertBuffer <> nil then
  begin
    FreeMem(ConvertBuffer);
    ConvertBuffer := nil;
  end;
end;

{$ENDIF}

{ Line-in capture stub - not implemented yet on Windows. Always returning
  False (never nil) means AudioEngine's capture thread can call CaptureOpen/
  CaptureRead unconditionally, exactly like on the ALSA side, and just never
  gets audio: CaptureOpen fails, so AudioEngine's CaptureAvailable stays
  False and the capture thread idles instead of ever calling CaptureRead. }
function DirectSoundCaptureOpenStub(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
begin
  Result := False;
end;

function DirectSoundCaptureReadStub(ABuffer: PSingle; AFrameCount: Integer): Boolean;
begin
  Result := False;
end;

procedure DirectSoundCaptureCloseStub;
begin
end;

function CreateDirectSoundBackend: TAudioBackend;
begin
  {$IFDEF WINDOWS}
  Result.Open := @DirectSoundOpen;
  Result.WriteBlock := @DirectSoundWriteBlock;
  Result.Close := @DirectSoundClose;
  {$ELSE}
  Result.Open := nil;
  Result.WriteBlock := nil;
  Result.Close := nil;
  {$ENDIF}
  Result.CaptureOpen := @DirectSoundCaptureOpenStub;
  Result.CaptureRead := @DirectSoundCaptureReadStub;
  Result.CaptureClose := @DirectSoundCaptureCloseStub;
end;

end.
