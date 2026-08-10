unit Jack;

{$mode objfpc}{$H+}

{ Minimal libjack binding, in the same hand-written style as ALSA.pas /
  DirectSound.pas - only the entry points JACKBackend actually calls, no
  third-party headers or packages.

  Unlike ALSA.pas this loads the library at RUNTIME rather than declaring
  `external 'libjack.so.0'`. libasound is always present on a Linux desktop;
  libjack may not be, and a static external is resolved by the dynamic
  linker at process LOAD time - so one missing .so would stop Eris starting
  at all, rather than just making one backend unavailable. JackLoad returns
  False when it isn't installed, which is what lets the JACK backend be
  selectable on a machine with no JACK at all (it just never produces
  audio - see JACKBackend's unit comment). }

interface

uses
  ctypes;

const
  { jack_options_t }
  JackNullOption    = $00;
  JackNoStartServer = $01;

  { JackPortFlags - note these are from the PORT's own point of view, so a
    hardware playback port (something you send audio TO) is an INPUT port. }
  JackPortIsInput    = $01;
  JackPortIsOutput   = $02;
  JackPortIsPhysical = $04;

  JACK_DEFAULT_AUDIO_TYPE = '32 bit float mono audio';

type
  Pjack_client_t = Pointer;
  Pjack_port_t = Pointer;
  jack_nframes_t = cuint32;
  Pjack_default_audio_sample_t = ^cfloat;

  TJackProcessCallback = function(ANFrames: jack_nframes_t;
    AArg: Pointer): cint; cdecl;
  TJackShutdownCallback = procedure(AArg: Pointer); cdecl;

var
  { jack_client_open is variadic in C (extra args only get read for options
    this backend never passes), so a plain fixed-arity cdecl pointer is a
    safe way to call it - the caller cleans the stack either way. }
  jack_client_open: function(AClientName: PChar; AOptions: cint;
    AStatus: pcint): Pjack_client_t; cdecl;
  jack_client_close: function(AClient: Pjack_client_t): cint; cdecl;
  jack_activate: function(AClient: Pjack_client_t): cint; cdecl;
  jack_deactivate: function(AClient: Pjack_client_t): cint; cdecl;
  jack_set_process_callback: function(AClient: Pjack_client_t;
    ACallback: TJackProcessCallback; AArg: Pointer): cint; cdecl;
  jack_on_shutdown: procedure(AClient: Pjack_client_t;
    ACallback: TJackShutdownCallback; AArg: Pointer); cdecl;
  jack_get_sample_rate: function(AClient: Pjack_client_t): jack_nframes_t; cdecl;
  jack_get_buffer_size: function(AClient: Pjack_client_t): jack_nframes_t; cdecl;
  jack_port_register: function(AClient: Pjack_client_t; APortName: PChar;
    APortType: PChar; AFlags: culong; ABufferSize: culong): Pjack_port_t; cdecl;
  jack_port_unregister: function(AClient: Pjack_client_t;
    APort: Pjack_port_t): cint; cdecl;
  jack_port_get_buffer: function(APort: Pjack_port_t;
    ANFrames: jack_nframes_t): Pointer; cdecl;
  jack_port_name: function(APort: Pjack_port_t): PChar; cdecl;
  jack_get_ports: function(AClient: Pjack_client_t; APortNamePattern: PChar;
    ATypeNamePattern: PChar; AFlags: culong): PPChar; cdecl;
  jack_connect: function(AClient: Pjack_client_t; ASourcePort: PChar;
    ADestinationPort: PChar): cint; cdecl;
  jack_free: procedure(APtr: Pointer); cdecl;

{ True once libjack is loaded and every symbol above is resolved. Safe to
  call repeatedly - it only does the work once. }
function JackLoad: Boolean;
procedure JackUnload;

implementation

uses
  dynlibs;

var
  LibHandle: TLibHandle = 0;
  Loaded: Boolean = False;

function JackLoad: Boolean;

  function Sym(const AName: string; out ATarget: Pointer): Boolean;
  begin
    ATarget := GetProcedureAddress(LibHandle, AName);
    Result := ATarget <> nil;
  end;

begin
  if Loaded then
    Exit(True);

  if LibHandle = 0 then
    LibHandle := LoadLibrary('libjack.so.0');
  if LibHandle = 0 then
    LibHandle := LoadLibrary('libjack.so');
  if LibHandle = 0 then
    Exit(False);

  Result :=
    Sym('jack_client_open', Pointer(jack_client_open)) and
    Sym('jack_client_close', Pointer(jack_client_close)) and
    Sym('jack_activate', Pointer(jack_activate)) and
    Sym('jack_deactivate', Pointer(jack_deactivate)) and
    Sym('jack_set_process_callback', Pointer(jack_set_process_callback)) and
    Sym('jack_on_shutdown', Pointer(jack_on_shutdown)) and
    Sym('jack_get_sample_rate', Pointer(jack_get_sample_rate)) and
    Sym('jack_get_buffer_size', Pointer(jack_get_buffer_size)) and
    Sym('jack_port_register', Pointer(jack_port_register)) and
    Sym('jack_port_unregister', Pointer(jack_port_unregister)) and
    Sym('jack_port_get_buffer', Pointer(jack_port_get_buffer)) and
    Sym('jack_port_name', Pointer(jack_port_name)) and
    Sym('jack_get_ports', Pointer(jack_get_ports)) and
    Sym('jack_connect', Pointer(jack_connect)) and
    Sym('jack_free', Pointer(jack_free));

  if not Result then
  begin
    UnloadLibrary(LibHandle);
    LibHandle := 0;
    Exit;
  end;

  Loaded := True;
end;

procedure JackUnload;
begin
  { deliberately does NOT unload the .so - JACK spawns its own client thread
    and tearing the library out from under a driver that may not have fully
    finished with it is a good way to crash on exit. Reopening the backend
    goes through JackLoad again, which no-ops. }
  Loaded := Loaded;
end;

end.
