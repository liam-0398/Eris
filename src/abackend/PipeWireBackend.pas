unit PipeWireBackend;

{$mode objfpc}{$H+}

{ Native PipeWire output/capture backend, filling the same TAudioBackend
  record as ALSABackend, JACKBackend and DirectSoundBackend so AudioEngine can
  swap to it at runtime with nothing else changing.

  This is a real PipeWire client (pw_stream), not the ALSA or JACK
  compatibility layer - Eris shows up in qpwgraph as its own node, and both
  directions can be pointed at a specific device.

  ---------------------------------------------------------------------------
  THE ADAPTER

  Same shape, and same reason, as JACKBackend: PipeWire calls the process
  callback on its own thread while AudioEngine expects a blocking
  Backend.WriteBlock it can pace itself against. A lock-free SPSC ring bridges
  the two - WriteBlock produces with backpressure, the callback consumes -
  so the shared playback path that ALSA and DirectSound also use is untouched.
  Latency is the ring's fill target (set to the same depth ALSABackend asks
  ALSA for), not PipeWire's quantum. Inverting the engine is what would
  delete the ring; see JACKBackend's header for the fuller note.

  ---------------------------------------------------------------------------
  SAMPLE RATE

  Unlike JACK, no resampling is needed here. The stream asks for
  AudioEngine.ProjectSampleRate as a fixed format and PipeWire converts
  between that and whatever the graph is running at, per stream. That is the
  normal way a PipeWire client requests its own rate. }

interface

uses
  AudioBackend;

type
  TPWDevice = record
    Name: string;         { node.name - what gets passed as target.object }
    Description: string;  { node.description - what the user reads }
  end;
  TPWDeviceArray = array of TPWDevice;

function CreatePipeWireBackend: TAudioBackend;

{ Enumerates PipeWire sinks (AOutputs=True) or sources (AOutputs=False) by
  making its own short-lived connection - independent of whether the backend
  is currently open, so Preferences can list devices while another backend is
  live. Returns an empty array if PipeWire isn't there at all. }
function PipeWireListDevices(AOutputs: Boolean): TPWDeviceArray;

{ Target node.name for each direction, '' meaning "let PipeWire pick the
  default". Set before the backend is opened (AudioEngine re-opens it when
  either changes). }
procedure PipeWireSetOutputDevice(const AName: string);
procedure PipeWireSetInputDevice(const AName: string);
function PipeWireGetOutputDevice: string;
function PipeWireGetInputDevice: string;

{ True when the library loads AND something is listening - used to pick the
  startup default backend. }
function PipeWireAvailable: Boolean;

implementation

uses
  SysUtils, ctypes, PipeWire;

const
  RingCapacityFrames = 65536;
  TargetBlockMultiple = 4;   { matches ALSABackend's own latency request }

  { The EnumFormat POD for audio/raw F32LE, built by hand because SPA's
    builders are header-only inline code. These 42 words are byte-for-byte
    what spa_format_audio_raw_build emits for a fixed stereo format; only the
    rate word is patched per open. Layout, for anyone checking it against
    spa/pod/pod.h: an 8-byte pod header (size, type), an 8-byte object body
    (object_type, object_id), then one property per entry as
    (key, flags, value_size, value_type, value, pad). }
  PodWordCount = 42;
  PodRateIndex = 26;

type
  TFormatPod = array[0..PodWordCount - 1] of cuint32;

var
  { streams and their loop }
  Loop: Ppw_thread_loop = nil;
  PlayStream: Ppw_stream = nil;
  CaptureStream: Ppw_stream = nil;
  PlayEvents: Tpw_stream_events;
  CaptureEvents: Tpw_stream_events;

  EngineRate: Integer = 0;
  ChannelCount: Integer = 2;
  EngineBlockFrames: Integer = 0;
  LastQuantumFrames: Integer = 0;

  OutputDeviceName: string = '';
  InputDeviceName: string = '';

  { playback ring - producer TPlaybackThread, consumer PipeWire }
  PlayRing: PSingle = nil;
  PlayWriteCount: Int64 = 0;
  PlayReadCount: Int64 = 0;

  { capture ring - producer PipeWire, consumer TCaptureThread }
  CaptureRing: PSingle = nil;
  CaptureOn: Boolean = False;
  CaptureWriteCount: Int64 = 0;
  CaptureReadCount: Int64 = 0;

function PipeWireAvailable: Boolean;
begin
  Result := PwServerPresent;
end;

procedure PipeWireSetOutputDevice(const AName: string);
begin
  OutputDeviceName := AName;
end;

procedure PipeWireSetInputDevice(const AName: string);
begin
  InputDeviceName := AName;
end;

function PipeWireGetOutputDevice: string;
begin
  Result := OutputDeviceName;
end;

function PipeWireGetInputDevice: string;
begin
  Result := InputDeviceName;
end;

function BuildFormatPod(ARate: Integer): TFormatPod;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result[0] := 160;                      { pod size, excluding this header }
  Result[1] := SPA_TYPE_Object;
  Result[2] := SPA_TYPE_OBJECT_Format;
  Result[3] := SPA_PARAM_EnumFormat;

  Result[4] := SPA_FORMAT_mediaType;
  Result[6] := 4; Result[7] := SPA_TYPE_Id; Result[8] := SPA_MEDIA_TYPE_audio;

  Result[10] := SPA_FORMAT_mediaSubtype;
  Result[12] := 4; Result[13] := SPA_TYPE_Id; Result[14] := SPA_MEDIA_SUBTYPE_raw;

  Result[16] := SPA_FORMAT_AUDIO_format;
  Result[18] := 4; Result[19] := SPA_TYPE_Id; Result[20] := SPA_AUDIO_FORMAT_F32_LE;

  Result[22] := SPA_FORMAT_AUDIO_rate;
  Result[24] := 4; Result[25] := SPA_TYPE_Int; Result[PodRateIndex] := ARate;

  Result[28] := SPA_FORMAT_AUDIO_channels;
  Result[30] := 4; Result[31] := SPA_TYPE_Int; Result[32] := 2;

  { position is an array of two channel ids: size=16 / type=Array, then
    child_size=4 / child_type=Id, then the two values }
  Result[34] := SPA_FORMAT_AUDIO_position;
  Result[36] := 16; Result[37] := SPA_TYPE_Array;
  Result[38] := 4;  Result[39] := SPA_TYPE_Id;
  Result[40] := SPA_AUDIO_CHANNEL_FL;
  Result[41] := SPA_AUDIO_CHANNEL_FR;
end;

function PlaybackTargetFrames: Int64;
var
  Quantum: Integer;
begin
  Quantum := LastQuantumFrames;
  if Quantum <= 0 then
    Quantum := EngineBlockFrames;
  Result := Int64(Quantum) + Int64(EngineBlockFrames) * TargetBlockMultiple;
  if Result > RingCapacityFrames then
    Result := RingCapacityFrames;
end;

{ ---------------------------------------------------------------------------
  Realtime callbacks - PipeWire's thread. No allocation, no locks, no managed
  types, no exceptions past this line. }

procedure PlaybackProcess(AData: Pointer); cdecl;
var
  Buf: Ppw_buffer;
  SBuf: Pspa_buffer;
  D: Pspa_data;
  Dst: PSingle;
  i, n, Stride, SrcIdx, DstIdx, Cap: Integer;
  Avail: Int64;
begin
  if (PlayStream = nil) or (PlayRing = nil) then
    Exit;
  Buf := pw_stream_dequeue_buffer(PlayStream);
  if Buf = nil then
    Exit;

  SBuf := Buf^.Buffer;
  if (SBuf = nil) or (SBuf^.NDatas < 1) then
  begin
    pw_stream_queue_buffer(PlayStream, Buf);
    Exit;
  end;

  D := SBuf^.Datas;
  Dst := PSingle(D^.Data);
  if Dst = nil then
  begin
    pw_stream_queue_buffer(PlayStream, Buf);
    Exit;
  end;

  Stride := ChannelCount * SizeOf(Single);
  n := D^.MaxSize div Stride;
  if (Buf^.Requested > 0) and (Int64(Buf^.Requested) < n) then
    n := Buf^.Requested;
  LastQuantumFrames := n;

  Cap := RingCapacityFrames;
  Avail := PlayWriteCount - PlayReadCount;

  for i := 0 to n - 1 do
  begin
    DstIdx := i * ChannelCount;
    if i < Avail then
    begin
      SrcIdx := Integer((PlayReadCount + i) mod Cap) * ChannelCount;
      Dst[DstIdx] := PlayRing[SrcIdx];
      Dst[DstIdx + 1] := PlayRing[SrcIdx + 1];
    end
    else
    begin
      { underrun - the producer hasn't kept up. Emit silence for the rest of
        the block rather than repeating stale audio. }
      Dst[DstIdx] := 0;
      Dst[DstIdx + 1] := 0;
    end;
  end;

  if Avail > 0 then
  begin
    if Avail > n then
      Avail := n;
    PlayReadCount := PlayReadCount + Avail;
  end;

  D^.Chunk^.Offset := 0;
  D^.Chunk^.Stride := Stride;
  D^.Chunk^.Size := n * Stride;

  pw_stream_queue_buffer(PlayStream, Buf);
end;

procedure CaptureProcess(AData: Pointer); cdecl;
var
  Buf: Ppw_buffer;
  SBuf: Pspa_buffer;
  D: Pspa_data;
  Src: PSingle;
  i, n, Stride, SrcIdx, DstIdx, Cap: Integer;
  Space: Int64;
begin
  if (CaptureStream = nil) or (CaptureRing = nil) or (not CaptureOn) then
    Exit;
  Buf := pw_stream_dequeue_buffer(CaptureStream);
  if Buf = nil then
    Exit;

  SBuf := Buf^.Buffer;
  if (SBuf = nil) or (SBuf^.NDatas < 1) then
  begin
    pw_stream_queue_buffer(CaptureStream, Buf);
    Exit;
  end;

  D := SBuf^.Datas;
  Src := PSingle(D^.Data);
  if (Src = nil) or (D^.Chunk = nil) then
  begin
    pw_stream_queue_buffer(CaptureStream, Buf);
    Exit;
  end;

  Stride := ChannelCount * SizeOf(Single);
  n := D^.Chunk^.Size div Stride;
  Src := PSingle(PByte(Src) + D^.Chunk^.Offset);

  Cap := RingCapacityFrames;
  Space := Cap - (CaptureWriteCount - CaptureReadCount);
  { ring full means nothing is draining it (no Input track armed) - drop
    rather than overwrite frames the consumer may still be reading }
  if Space >= n then
  begin
    for i := 0 to n - 1 do
    begin
      SrcIdx := i * ChannelCount;
      DstIdx := Integer((CaptureWriteCount + i) mod Cap) * ChannelCount;
      CaptureRing[DstIdx] := Src[SrcIdx];
      CaptureRing[DstIdx + 1] := Src[SrcIdx + 1];
    end;
    CaptureWriteCount := CaptureWriteCount + n;
  end;

  pw_stream_queue_buffer(CaptureStream, Buf);
end;

{ ---------------------------------------------------------------------------
  Stream setup }

{ pw_properties_new is variadic, which a dlsym'd fixed-arity pointer can't
  safely express, so the properties are built as a spa_dict instead -
  pw_properties_new_dict copies both the keys and the values, so the local
  strings backing them only have to survive this call. }
function MakeStreamProps(const ACategory, ANodeName, ATarget: string;
  ALatency: string): Ppw_properties;
var
  Items: array[0..6] of Tspa_dict_item;
  Dict: Tspa_dict;
  Count: Integer;
  KMediaType, KCategory, KRole, KApp, KNode, KLatency, KTarget: string;
begin
  KMediaType := 'Audio';
  KCategory := ACategory;
  KRole := 'Production';
  KApp := 'Eris';
  KNode := ANodeName;
  KLatency := ALatency;
  KTarget := ATarget;

  Count := 0;
  Items[Count].Key := PW_KEY_MEDIA_TYPE;  Items[Count].Value := PChar(KMediaType); Inc(Count);
  Items[Count].Key := PW_KEY_MEDIA_CATEGORY; Items[Count].Value := PChar(KCategory); Inc(Count);
  Items[Count].Key := PW_KEY_MEDIA_ROLE;  Items[Count].Value := PChar(KRole); Inc(Count);
  Items[Count].Key := PW_KEY_APP_NAME;    Items[Count].Value := PChar(KApp); Inc(Count);
  Items[Count].Key := PW_KEY_NODE_NAME;   Items[Count].Value := PChar(KNode); Inc(Count);
  Items[Count].Key := PW_KEY_NODE_LATENCY; Items[Count].Value := PChar(KLatency); Inc(Count);
  { omitted entirely (not set to '') when there's no explicit device, so
    PipeWire falls back to the user's default sink/source }
  if KTarget <> '' then
  begin
    Items[Count].Key := PW_KEY_TARGET_OBJECT;
    Items[Count].Value := PChar(KTarget);
    Inc(Count);
  end;

  Dict.Flags := 0;
  Dict.NItems := Count;
  Dict.Items := @Items[0];
  Result := pw_properties_new_dict(@Dict);
end;

procedure PipeWireClose; forward;

function EnsureLoop: Boolean;
begin
  Result := False;
  if not PwLoad then
    Exit;
  if Loop = nil then
  begin
    Loop := pw_thread_loop_new('eris-pw', nil);
    if Loop = nil then
      Exit;
    if pw_thread_loop_start(Loop) < 0 then
    begin
      pw_thread_loop_destroy(Loop);
      Loop := nil;
      Exit;
    end;
  end;
  Result := True;
end;

function PipeWireOpen(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
var
  Pod: TFormatPod;
  Params: array[0..0] of Pointer;
  Props: Ppw_properties;
begin
  Result := False;
  EngineRate := ASampleRate;
  ChannelCount := AChannels;
  EngineBlockFrames := ABufferFrames;
  LastQuantumFrames := ABufferFrames;

  if AChannels <> 2 then
    Exit;
  if not EnsureLoop then
    Exit;

  PlayWriteCount := 0;
  PlayReadCount := 0;
  GetMem(PlayRing, RingCapacityFrames * ChannelCount * SizeOf(Single));
  FillChar(PlayRing^, RingCapacityFrames * ChannelCount * SizeOf(Single), 0);

  FillChar(PlayEvents, SizeOf(PlayEvents), 0);
  PlayEvents.Version := PW_VERSION_STREAM_EVENTS;
  PlayEvents.Process := @PlaybackProcess;

  pw_thread_loop_lock(Loop);
  try
    Props := MakeStreamProps('Playback', 'Eris', OutputDeviceName,
      IntToStr(ABufferFrames) + '/' + IntToStr(ASampleRate));
    { ownership of Props passes to the stream }
    PlayStream := pw_stream_new_simple(pw_thread_loop_get_loop(Loop), 'Eris',
      Props, @PlayEvents, nil);
    if PlayStream = nil then
      Exit;

    Pod := BuildFormatPod(ASampleRate);
    Params[0] := @Pod[0];

    if pw_stream_connect(PlayStream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
      PW_STREAM_FLAG_AUTOCONNECT or PW_STREAM_FLAG_MAP_BUFFERS or
      PW_STREAM_FLAG_RT_PROCESS, @Params[0], 1) < 0 then
    begin
      pw_stream_destroy(PlayStream);
      PlayStream := nil;
      Exit;
    end;
  finally
    pw_thread_loop_unlock(Loop);
  end;

  if PlayStream = nil then
  begin
    PipeWireClose;
    Exit;
  end;

  Result := True;
end;

function PipeWireWriteBlock(ABuffer: PSingle; AFrameCount: Integer): Boolean;
var
  i, Idx, Src, Cap, Waited: Integer;
begin
  { no server, or the stream never connected - pace at roughly the block's
    real duration and report failure, so the engine stays alive but silent
    instead of spinning at 100% CPU }
  if (PlayStream = nil) or (PlayRing = nil) then
  begin
    if EngineRate > 0 then
      Sleep(1 + (AFrameCount * 1000) div EngineRate)
    else
      Sleep(5);
    Exit(False);
  end;

  Cap := RingCapacityFrames;

  Waited := 0;
  while (PlayWriteCount - PlayReadCount + AFrameCount > PlaybackTargetFrames)
    and (Waited < 1000) do
  begin
    Sleep(1);
    Inc(Waited);
  end;

  for i := 0 to AFrameCount - 1 do
  begin
    Idx := Integer((PlayWriteCount + i) mod Cap) * ChannelCount;
    Src := i * ChannelCount;
    PlayRing[Idx] := ABuffer[Src];
    PlayRing[Idx + 1] := ABuffer[Src + 1];
  end;
  PlayWriteCount := PlayWriteCount + AFrameCount;

  Result := True;
end;

procedure PipeWireClose;
begin
  if Loop <> nil then
  begin
    pw_thread_loop_lock(Loop);
    if PlayStream <> nil then
    begin
      pw_stream_destroy(PlayStream);
      PlayStream := nil;
    end;
    if CaptureStream <> nil then
    begin
      pw_stream_destroy(CaptureStream);
      CaptureStream := nil;
    end;
    pw_thread_loop_unlock(Loop);

    pw_thread_loop_stop(Loop);
    pw_thread_loop_destroy(Loop);
    Loop := nil;
  end;

  CaptureOn := False;

  if PlayRing <> nil then
  begin
    FreeMem(PlayRing);
    PlayRing := nil;
  end;
  if CaptureRing <> nil then
  begin
    FreeMem(CaptureRing);
    CaptureRing := nil;
  end;
end;

{ Line-in capture: a second stream on the same loop, pointed at the selected
  source (or the default one). Independent of the playback stream, so
  monitoring and Input Track recording work exactly as they do on ALSA. }
function PipeWireCaptureOpen(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
var
  Pod: TFormatPod;
  Params: array[0..0] of Pointer;
  Props: Ppw_properties;
begin
  Result := False;
  if (Loop = nil) or (AChannels <> ChannelCount) then
    Exit;

  CaptureWriteCount := 0;
  CaptureReadCount := 0;
  GetMem(CaptureRing, RingCapacityFrames * ChannelCount * SizeOf(Single));
  FillChar(CaptureRing^, RingCapacityFrames * ChannelCount * SizeOf(Single), 0);

  FillChar(CaptureEvents, SizeOf(CaptureEvents), 0);
  CaptureEvents.Version := PW_VERSION_STREAM_EVENTS;
  CaptureEvents.Process := @CaptureProcess;

  pw_thread_loop_lock(Loop);
  try
    Props := MakeStreamProps('Capture', 'Eris Input', InputDeviceName,
      IntToStr(ABufferFrames) + '/' + IntToStr(ASampleRate));
    CaptureStream := pw_stream_new_simple(pw_thread_loop_get_loop(Loop),
      'Eris Input', Props, @CaptureEvents, nil);
    if CaptureStream = nil then
      Exit;

    Pod := BuildFormatPod(ASampleRate);
    Params[0] := @Pod[0];

    if pw_stream_connect(CaptureStream, PW_DIRECTION_INPUT, PW_ID_ANY,
      PW_STREAM_FLAG_AUTOCONNECT or PW_STREAM_FLAG_MAP_BUFFERS or
      PW_STREAM_FLAG_RT_PROCESS, @Params[0], 1) < 0 then
    begin
      pw_stream_destroy(CaptureStream);
      CaptureStream := nil;
      Exit;
    end;
  finally
    pw_thread_loop_unlock(Loop);
  end;

  if CaptureStream = nil then
  begin
    FreeMem(CaptureRing);
    CaptureRing := nil;
    Exit;
  end;

  CaptureOn := True;
  Result := True;
end;

function PipeWireCaptureRead(ABuffer: PSingle; AFrameCount: Integer): Boolean;
var
  i, Cap, SrcIdx, DstIdx: Integer;
begin
  Result := False;
  if (not CaptureOn) or (CaptureRing = nil) then
    Exit;

  { not enough captured yet - AudioEngine's capture thread sleeps and retries,
    the same path it takes when there is no capture device at all }
  if CaptureWriteCount - CaptureReadCount < AFrameCount then
    Exit;

  Cap := RingCapacityFrames;
  for i := 0 to AFrameCount - 1 do
  begin
    SrcIdx := Integer((CaptureReadCount + i) mod Cap) * ChannelCount;
    DstIdx := i * ChannelCount;
    ABuffer[DstIdx] := CaptureRing[SrcIdx];
    ABuffer[DstIdx + 1] := CaptureRing[SrcIdx + 1];
  end;
  CaptureReadCount := CaptureReadCount + AFrameCount;

  Result := True;
end;

procedure PipeWireCaptureClose;
begin
  CaptureOn := False;

  if (Loop <> nil) and (CaptureStream <> nil) then
  begin
    pw_thread_loop_lock(Loop);
    pw_stream_destroy(CaptureStream);
    CaptureStream := nil;
    pw_thread_loop_unlock(Loop);
  end;

  if CaptureRing <> nil then
  begin
    FreeMem(CaptureRing);
    CaptureRing := nil;
  end;
end;

{ ---------------------------------------------------------------------------
  Device enumeration }

const
  MaxEnumDevices = 64;

type
  { fixed-size, deliberately: the registry callback runs on PipeWire's own
    thread, and filling Pascal managed types (strings, dynamic arrays) from a
    foreign thread is exactly the kind of thing not to do in a callback.
    Converted to real strings on the calling thread once the round-trip is
    done. }
  TRawDevice = record
    Name: array[0..127] of Char;
    Desc: array[0..255] of Char;
  end;

var
  EnumBuf: array[0..MaxEnumDevices - 1] of TRawDevice;
  EnumCount: Integer = 0;
  EnumWantSinks: Boolean = False;
  EnumDone: Boolean = False;
  EnumLoop: Ppw_thread_loop = nil;

function DictLookup(AProps: Pspa_dict; const AKey: string): PChar;
var
  i: Integer;
  Item: Pspa_dict_item;
begin
  Result := nil;
  if AProps = nil then
    Exit;
  Item := AProps^.Items;
  for i := 0 to Integer(AProps^.NItems) - 1 do
  begin
    if (Item[i].Key <> nil) and (StrComp(Item[i].Key, PChar(AKey)) = 0) then
      Exit(Item[i].Value);
  end;
end;

procedure RegistryGlobal(AData: Pointer; AId: cuint32; APermissions: cuint32;
  AType: PChar; AVersion: cuint32; AProps: Pspa_dict); cdecl;
var
  MediaClass, NodeName, NodeDesc: PChar;
  Wanted: string;
begin
  if EnumCount >= MaxEnumDevices then
    Exit;
  if (AType = nil) or (StrComp(AType, PW_TYPE_INTERFACE_Node) <> 0) then
    Exit;

  MediaClass := DictLookup(AProps, PW_KEY_MEDIA_CLASS);
  if MediaClass = nil then
    Exit;

  if EnumWantSinks then
    Wanted := 'Audio/Sink'
  else
    Wanted := 'Audio/Source';
  if StrComp(MediaClass, PChar(Wanted)) <> 0 then
    Exit;

  NodeName := DictLookup(AProps, PW_KEY_NODE_NAME);
  if NodeName = nil then
    Exit;
  NodeDesc := DictLookup(AProps, PW_KEY_NODE_DESCRIPTION);
  if NodeDesc = nil then
    NodeDesc := NodeName;

  { zero first so both stay null-terminated even at exactly the buffer
    length, and so the slot never carries anything from a previous scan }
  FillChar(EnumBuf[EnumCount], SizeOf(EnumBuf[EnumCount]), 0);
  StrLCopy(@EnumBuf[EnumCount].Name[0], NodeName,
    High(EnumBuf[EnumCount].Name));
  StrLCopy(@EnumBuf[EnumCount].Desc[0], NodeDesc,
    High(EnumBuf[EnumCount].Desc));
  Inc(EnumCount);
end;

procedure CoreDone(AData: Pointer; AId: cuint32; ASeq: cint); cdecl;
begin
  { the sync round-trip has come back, so every global that existed when it
    was issued has already been delivered - wake the waiting enumerator }
  if AId = PW_ID_CORE then
  begin
    EnumDone := True;
    if EnumLoop <> nil then
      pw_thread_loop_signal(EnumLoop, False);
  end;
end;

function PipeWireListDevices(AOutputs: Boolean): TPWDeviceArray;
var
  Context: Ppw_context;
  Core: Ppw_core;
  Registry: Ppw_registry;
  RegEvents: Tpw_registry_events;
  CoreEvents: Tpw_core_events;
  RegHook, CoreHook: Tspa_hook;
  Spins, i: Integer;
begin
  Result := nil;
  if not PwLoad then
    Exit;
  if not PwServerPresent then
    Exit;

  EnumCount := 0;
  EnumDone := False;
  EnumWantSinks := AOutputs;

  EnumLoop := pw_thread_loop_new('eris-pw-enum', nil);
  if EnumLoop = nil then
    Exit;

  Context := nil;
  Core := nil;
  try
    if pw_thread_loop_start(EnumLoop) < 0 then
      Exit;

    pw_thread_loop_lock(EnumLoop);
    try
      Context := pw_context_new(pw_thread_loop_get_loop(EnumLoop), nil, 0);
      if Context = nil then
        Exit;
      Core := pw_context_connect(Context, nil, 0);
      if Core = nil then
        Exit;
      Registry := PwCoreGetRegistry(Core);
      if Registry = nil then
        Exit;

      FillChar(RegEvents, SizeOf(RegEvents), 0);
      RegEvents.Version := PW_VERSION_REGISTRY_EVENTS;
      RegEvents.Global := @RegistryGlobal;
      PwRegistryAddListener(Registry, @RegHook, @RegEvents, nil);

      FillChar(CoreEvents, SizeOf(CoreEvents), 0);
      CoreEvents.Version := PW_VERSION_CORE_EVENTS;
      CoreEvents.Done := @CoreDone;
      PwCoreAddListener(Core, @CoreHook, @CoreEvents, nil);

      { a sync is the standard "tell me when you've sent everything you
        already had" round-trip - the done event above fires after every
        global that existed at this point has been delivered }
      PwCoreSync(Core, PW_ID_CORE, 0);

      { bounded, so a server that never answers can't hang Preferences.
        pw_thread_loop_wait drops the lock while it waits. }
      Spins := 0;
      while (not EnumDone) and (Spins < 200) do
      begin
        pw_thread_loop_wait(EnumLoop);
        Inc(Spins);
      end;
    finally
      pw_thread_loop_unlock(EnumLoop);
    end;
  finally
    if Core <> nil then
      pw_core_disconnect(Core);
    if Context <> nil then
      pw_context_destroy(Context);
    pw_thread_loop_stop(EnumLoop);
    pw_thread_loop_destroy(EnumLoop);
    EnumLoop := nil;
  end;

  SetLength(Result, EnumCount);
  for i := 0 to EnumCount - 1 do
  begin
    Result[i].Name := StrPas(PChar(@EnumBuf[i].Name[0]));
    Result[i].Description := StrPas(PChar(@EnumBuf[i].Desc[0]));
  end;
end;

function CreatePipeWireBackend: TAudioBackend;
begin
  Result.Open := @PipeWireOpen;
  Result.WriteBlock := @PipeWireWriteBlock;
  Result.Close := @PipeWireClose;
  Result.CaptureOpen := @PipeWireCaptureOpen;
  Result.CaptureRead := @PipeWireCaptureRead;
  Result.CaptureClose := @PipeWireCaptureClose;
end;

end.
