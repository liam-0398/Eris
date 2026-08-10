unit JACKBackend;

{$mode objfpc}{$H+}

{ JACK output/capture backend, fitting the same TAudioBackend record shape as
  ALSABackend and DirectSoundBackend so AudioEngine can swap between them at
  runtime with no other change.

  Works against real jackd (jackd1/jackd2) and against pipewire-jack
  identically - both provide the same libjack.so.0 ABI, and nothing in here
  is specific to either.

  ---------------------------------------------------------------------------
  THE ADAPTER, AND WHY

  JACK is callback-driven: the server calls JackProcess on ITS realtime
  thread and expects the buffers filled before it returns. AudioEngine is
  pull-driven: TPlaybackThread owns the clock and calls Backend.WriteBlock,
  which is expected to BLOCK until the device has taken the audio (that's
  what paces the engine - see ALSABackend's snd_pcm_writei).

  Rather than invert the engine (which would be a change to the shared
  playback path that ALSA and DirectSound also run through), this bridges the
  two with a lock-free SPSC ring: WriteBlock is the producer and applies
  backpressure exactly like a blocking device write, JackProcess is the
  consumer. ALSA and DirectSound are untouched by this file existing.

  The cost is latency: steady-state occupancy of that ring sits at the
  producer's target fill, so JACK's own period size is NOT the round-trip
  latency here. The target is deliberately set to the same depth
  ALSABackend already asks ALSA for (4 x the engine's block, plus one JACK
  period of headroom), so this backend is no laggier than the existing one -
  but it does not deliver the low latency JACK is capable of. Getting that
  needs the engine inverted so FillBlock runs inside JackProcess; the ring
  is what that change would delete.

  ---------------------------------------------------------------------------
  SAMPLE RATE

  The JACK server's rate is authoritative and cannot be negotiated by a
  client - it is set in qjackctl (or the PipeWire config) before the server
  starts. Eris is fixed at AudioEngine.ProjectSampleRate. When the two
  differ, both directions are linearly resampled on the ring, which is the
  same thing ALSABackend already relies on ALSA to do for it (it passes
  soft_resample=1 to snd_pcm_set_params). Matching the server to the project
  rate avoids the conversion entirely and is worth doing in qjackctl. }

interface

uses
  AudioBackend;

function CreateJACKBackend: TAudioBackend;

implementation

uses
  SysUtils, ctypes, Jack;

const
  { Generously sized so a mid-session JACK period change never needs a
    reallocation (which couldn't be done from the realtime callback anyway).
    Occupancy - and therefore latency - is bounded by the much smaller
    running target computed in PlaybackTargetFrames, not by this. }
  RingCapacityFrames = 65536;

  { Multiplier on the engine's block size for the producer's fill target,
    copied from ALSABackend's own latency request
    (LatencyUs := ABufferFrames * 4 * ...) so switching backends doesn't
    change how much slack the playback thread has before it underruns. }
  TargetBlockMultiple = 4;

var
  Client: Pjack_client_t = nil;
  ClientRunning: Boolean = False;
  OutPortL: Pjack_port_t = nil;
  OutPortR: Pjack_port_t = nil;
  InPortL: Pjack_port_t = nil;
  InPortR: Pjack_port_t = nil;

  ServerRate: Integer = 0;
  EngineRate: Integer = 0;
  ChannelCount: Integer = 2;
  EngineBlockFrames: Integer = 0;
  { last nframes JackProcess was called with - written by the realtime thread,
    read by WriteBlock purely to size its fill target, so a stale value for
    one block is harmless }
  LastPeriodFrames: Integer = 0;

  { engine frames consumed per server frame produced, and its inverse for the
    capture direction - both 1.0 when the rates match }
  PlayRatio: Double = 1.0;
  CaptureRatio: Double = 1.0;

  { Playback ring: interleaved, ChannelCount per frame, at EngineRate.
    Producer = TPlaybackThread via JACKWriteBlock. Consumer = JackProcess. }
  PlayRing: PSingle = nil;
  PlayWriteCount: Int64 = 0;
  PlayReadCount: Int64 = 0;   { published Trunc(PlayReadPos), for the producer }
  PlayReadPos: Double = 0;    { consumer-private fractional read cursor }

  { Capture ring: interleaved, ChannelCount per frame, at SERVER rate - the
    rate conversion happens on the consumer side in JACKCaptureRead, same as
    playback does it on the consumer side. Producer = JackProcess.
    Consumer = AudioEngine's TCaptureThread via JACKCaptureRead. }
  CaptureRing: PSingle = nil;
  CaptureActive: Boolean = False;
  CaptureWriteCount: Int64 = 0;
  CaptureReadCount: Int64 = 0;
  CaptureReadPos: Double = 0;

{ Producer's fill target: how many frames it will let sit in the ring before
  blocking. One JACK period of headroom (so a callback can always be served
  in full) plus the same multiple of the engine block ALSA is asked for. }
function PlaybackTargetFrames: Int64;
var
  Period: Integer;
begin
  Period := LastPeriodFrames;
  if Period <= 0 then
    Period := EngineBlockFrames;
  Result := Int64(Period) + Int64(EngineBlockFrames) * TargetBlockMultiple;
  if Result > RingCapacityFrames then
    Result := RingCapacityFrames;
end;

{ ---------------------------------------------------------------------------
  Realtime callbacks - called on JACK's own thread. No allocation, no locks,
  no managed types, no exceptions past this line. }

procedure JackShutdown(AArg: Pointer); cdecl;
begin
  { the server went away (jackd stopped, or qjackctl restarted it). Just mark
    the client dead - JACKWriteBlock then paces itself and returns False,
    exactly as it does when JACK was never installed, and the user recovers
    by reopening the backend or switching back to ALSA. }
  ClientRunning := False;
end;

function JackProcess(ANFrames: jack_nframes_t; AArg: Pointer): cint; cdecl;
var
  OutL, OutR, InL, InR: PSingle;
  i, n, Cap, i0, i1: Integer;
  Base: Int64;
  Frac: Double;
  Space: Int64;
  WriteIdx: Integer;
begin
  Result := 0;
  n := ANFrames;
  LastPeriodFrames := n;
  Cap := RingCapacityFrames;

  OutL := PSingle(jack_port_get_buffer(OutPortL, ANFrames));
  OutR := PSingle(jack_port_get_buffer(OutPortR, ANFrames));
  if (OutL = nil) or (OutR = nil) then
    Exit;

  for i := 0 to n - 1 do
  begin
    Base := Trunc(PlayReadPos);
    { needs Base and Base+1 for the interpolation - if the producer hasn't
      got that far yet this is an underrun: emit silence and DON'T advance,
      so the stream resumes where it left off instead of skipping }
    if Base + 1 >= PlayWriteCount then
    begin
      OutL[i] := 0;
      OutR[i] := 0;
      Continue;
    end;

    Frac := PlayReadPos - Base;
    i0 := Integer(Base mod Cap) * ChannelCount;
    i1 := Integer((Base + 1) mod Cap) * ChannelCount;

    OutL[i] := PlayRing[i0] + Frac * (PlayRing[i1] - PlayRing[i0]);
    OutR[i] := PlayRing[i0 + 1] + Frac * (PlayRing[i1 + 1] - PlayRing[i0 + 1]);

    PlayReadPos := PlayReadPos + PlayRatio;
  end;

  PlayReadCount := Trunc(PlayReadPos);

  if CaptureActive and (InPortL <> nil) and (InPortR <> nil) then
  begin
    InL := PSingle(jack_port_get_buffer(InPortL, ANFrames));
    InR := PSingle(jack_port_get_buffer(InPortR, ANFrames));
    if (InL <> nil) and (InR <> nil) then
    begin
      Space := Cap - (CaptureWriteCount - CaptureReadCount);
      { ring full means the capture thread isn't draining (no Input track
        armed, most likely) - drop this block rather than overwrite frames
        the consumer is still reading }
      if Space >= n then
        for i := 0 to n - 1 do
        begin
          WriteIdx := Integer((CaptureWriteCount + i) mod Cap) * ChannelCount;
          CaptureRing[WriteIdx] := InL[i];
          CaptureRing[WriteIdx + 1] := InR[i];
        end;
      if Space >= n then
        CaptureWriteCount := CaptureWriteCount + n;
    end;
  end;
end;

{ ---------------------------------------------------------------------------
  Connection helper }

{ Wires our ports to the first two matching hardware ports, so selecting JACK
  produces sound without a trip to the patchbay first. AFlags selects which
  side to look for; everything after that is the user's to rewire in
  qjackctl/qpwgraph, and nothing here ever reconnects behind their back. }
procedure AutoConnect(APortA, APortB: Pjack_port_t; AFlags: culong;
  AOursAreOutputs: Boolean);
var
  Ports: PPChar;
  NameA, NameB: PChar;
begin
  Ports := jack_get_ports(Client, nil, JACK_DEFAULT_AUDIO_TYPE, AFlags);
  if Ports = nil then
    Exit;
  try
    NameA := Ports[0];
    if NameA = nil then
      Exit;
    NameB := Ports[1];

    if AOursAreOutputs then
    begin
      jack_connect(Client, jack_port_name(APortA), NameA);
      if NameB <> nil then
        jack_connect(Client, jack_port_name(APortB), NameB);
    end
    else
    begin
      jack_connect(Client, NameA, jack_port_name(APortA));
      if NameB <> nil then
        jack_connect(Client, NameB, jack_port_name(APortB));
    end;
  finally
    jack_free(Ports);
  end;
end;

{ ---------------------------------------------------------------------------
  TAudioBackend implementation }

procedure JACKClose; forward;

function JACKOpen(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
var
  Status: cint;
begin
  Result := False;
  EngineRate := ASampleRate;
  ChannelCount := AChannels;
  EngineBlockFrames := ABufferFrames;

  { two mono ports, matching this engine's fixed stereo output }
  if AChannels <> 2 then
    Exit;

  if not JackLoad then
    Exit;

  Status := 0;
  Client := jack_client_open('Eris', JackNoStartServer, @Status);
  if Client = nil then
    Exit;

  ServerRate := jack_get_sample_rate(Client);
  if ServerRate <= 0 then
    ServerRate := EngineRate;
  LastPeriodFrames := jack_get_buffer_size(Client);

  PlayRatio := EngineRate / ServerRate;
  CaptureRatio := ServerRate / EngineRate;

  PlayWriteCount := 0;
  PlayReadCount := 0;
  PlayReadPos := 0;
  GetMem(PlayRing, RingCapacityFrames * ChannelCount * SizeOf(Single));
  FillChar(PlayRing^, RingCapacityFrames * ChannelCount * SizeOf(Single), 0);

  OutPortL := jack_port_register(Client, 'out_L', JACK_DEFAULT_AUDIO_TYPE,
    JackPortIsOutput, 0);
  OutPortR := jack_port_register(Client, 'out_R', JACK_DEFAULT_AUDIO_TYPE,
    JackPortIsOutput, 0);
  if (OutPortL = nil) or (OutPortR = nil) then
  begin
    JACKClose;
    Exit;
  end;

  jack_on_shutdown(Client, @JackShutdown, nil);
  if jack_set_process_callback(Client, @JackProcess, nil) <> 0 then
  begin
    JACKClose;
    Exit;
  end;

  if jack_activate(Client) <> 0 then
  begin
    JACKClose;
    Exit;
  end;

  ClientRunning := True;
  { hardware playback ports are INPUTs from the port's point of view }
  AutoConnect(OutPortL, OutPortR, JackPortIsPhysical or JackPortIsInput, True);

  Result := True;
end;

function JACKWriteBlock(ABuffer: PSingle; AFrameCount: Integer): Boolean;
var
  i, Idx, Cap: Integer;
  Src: Integer;
  Waited: Integer;
begin
  Cap := RingCapacityFrames;

  { No server (JACK not installed, never started, or it died under us). Pace
    at roughly the block's real duration and report failure: the engine keeps
    running with nowhere to send audio - a dead engine the user fixes by
    switching backend - but this must not spin, or an idle Eris would sit at
    100% CPU. }
  if (Client = nil) or (not ClientRunning) or (PlayRing = nil) then
  begin
    if EngineRate > 0 then
      Sleep(1 + (AFrameCount * 1000) div EngineRate)
    else
      Sleep(5);
    Exit(False);
  end;

  { Backpressure, standing in for a blocking device write. Bounded so a
    server that stops calling us back (or a client kicked out of the graph)
    can't wedge the playback thread forever. }
  Waited := 0;
  while (PlayWriteCount - PlayReadCount + AFrameCount > PlaybackTargetFrames)
    and ClientRunning and (Waited < 1000) do
  begin
    Sleep(1);
    Inc(Waited);
  end;

  if not ClientRunning then
    Exit(False);

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

procedure JACKClose;
begin
  if Client <> nil then
  begin
    if ClientRunning then
      jack_deactivate(Client);
    jack_client_close(Client);
    Client := nil;
  end;

  ClientRunning := False;
  OutPortL := nil;
  OutPortR := nil;
  InPortL := nil;
  InPortR := nil;
  CaptureActive := False;

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

{ Capture rides on the same client and the same process callback as playback -
  JACK hands input and output to one callback together - so this only
  registers the input ports and arms the capture ring. It therefore requires
  JACKOpen to have succeeded; with no client there is nothing to register a
  port on, and it reports failure the same way DirectSoundBackend's capture
  stub does. }
function JACKCaptureOpen(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
begin
  Result := False;
  if (Client = nil) or (not ClientRunning) or (AChannels <> ChannelCount) then
    Exit;

  CaptureWriteCount := 0;
  CaptureReadCount := 0;
  CaptureReadPos := 0;
  GetMem(CaptureRing, RingCapacityFrames * ChannelCount * SizeOf(Single));
  FillChar(CaptureRing^, RingCapacityFrames * ChannelCount * SizeOf(Single), 0);

  InPortL := jack_port_register(Client, 'in_L', JACK_DEFAULT_AUDIO_TYPE,
    JackPortIsInput, 0);
  InPortR := jack_port_register(Client, 'in_R', JACK_DEFAULT_AUDIO_TYPE,
    JackPortIsInput, 0);
  if (InPortL = nil) or (InPortR = nil) then
  begin
    FreeMem(CaptureRing);
    CaptureRing := nil;
    Exit;
  end;

  CaptureActive := True;
  { hardware capture ports are OUTPUTs from the port's point of view }
  AutoConnect(InPortL, InPortR, JackPortIsPhysical or JackPortIsOutput, False);

  Result := True;
end;

function JACKCaptureRead(ABuffer: PSingle; AFrameCount: Integer): Boolean;
var
  i, Cap, i0, i1, Dst: Integer;
  Base, LastNeeded: Int64;
  Frac, Pos: Double;
begin
  Result := False;
  if (not CaptureActive) or (CaptureRing = nil) or (not ClientRunning) then
    Exit;

  Cap := RingCapacityFrames;

  { everything this call will touch has to already be in the ring - report
    failure otherwise and let AudioEngine's capture thread sleep and retry,
    which is the same path it takes when there's no capture device at all }
  LastNeeded := Trunc(CaptureReadPos + (AFrameCount - 1) * CaptureRatio) + 1;
  if LastNeeded >= CaptureWriteCount then
    Exit;

  Pos := CaptureReadPos;
  for i := 0 to AFrameCount - 1 do
  begin
    Base := Trunc(Pos);
    Frac := Pos - Base;
    i0 := Integer(Base mod Cap) * ChannelCount;
    i1 := Integer((Base + 1) mod Cap) * ChannelCount;
    Dst := i * ChannelCount;

    ABuffer[Dst] := CaptureRing[i0] + Frac * (CaptureRing[i1] - CaptureRing[i0]);
    ABuffer[Dst + 1] := CaptureRing[i0 + 1] +
      Frac * (CaptureRing[i1 + 1] - CaptureRing[i0 + 1]);

    Pos := Pos + CaptureRatio;
  end;

  CaptureReadPos := Pos;
  CaptureReadCount := Trunc(Pos);
  Result := True;
end;

procedure JACKCaptureClose;
begin
  CaptureActive := False;

  if (Client <> nil) and ClientRunning then
  begin
    if InPortL <> nil then
      jack_port_unregister(Client, InPortL);
    if InPortR <> nil then
      jack_port_unregister(Client, InPortR);
  end;
  InPortL := nil;
  InPortR := nil;

  if CaptureRing <> nil then
  begin
    FreeMem(CaptureRing);
    CaptureRing := nil;
  end;
end;

function CreateJACKBackend: TAudioBackend;
begin
  Result.Open := @JACKOpen;
  Result.WriteBlock := @JACKWriteBlock;
  Result.Close := @JACKClose;
  Result.CaptureOpen := @JACKCaptureOpen;
  Result.CaptureRead := @JACKCaptureRead;
  Result.CaptureClose := @JACKCaptureClose;
end;

end.
