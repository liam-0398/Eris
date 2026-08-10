unit PipeWire;

{$mode objfpc}{$H+}

{ Minimal libpipewire-0.3 binding, hand-written in the same style as ALSA.pas
  and Jack.pas - only what PipeWireBackend actually calls, no third-party
  package.

  Loaded at runtime (see Jack.pas for why a static `external` would be worse:
  a missing .so would stop Eris starting at all rather than just making one
  backend unavailable).

  ---------------------------------------------------------------------------
  WHERE THE NUMBERS COME FROM

  PipeWire's C API leans on macros and `static inline` helpers that no .so
  exports - spa_pod_builder, spa_format_audio_raw_build, and the
  pw_core_get_registry/pw_registry_add_listener method macros. A binding has
  to reproduce them, which means hardcoding SPA type ids, struct offsets and
  vtable slot indices.

  Every constant and offset below was read out of the installed headers by a
  generated C program (offsetof/sizeof and the enum values themselves) rather
  than transcribed by eye, and the format POD in PipeWireBackend was compared
  against the exact bytes spa_format_audio_raw_build emits. If PipeWire ever
  breaks these (they are ABI, so it shouldn't), that is where to look.

  Verified against PipeWire 0.3.14xx headers. }

interface

uses
  ctypes;

const
  { SPA POD types - spa/utils/type.h }
  SPA_TYPE_Id     = 3;
  SPA_TYPE_Int    = 4;
  SPA_TYPE_Array  = 13;
  SPA_TYPE_Object = 15;

  { spa/param/format.h, spa/param/param.h }
  SPA_TYPE_OBJECT_Format   = 262147;
  SPA_PARAM_EnumFormat     = 3;
  SPA_FORMAT_mediaType     = 1;
  SPA_FORMAT_mediaSubtype  = 2;
  SPA_FORMAT_AUDIO_format   = 65537;
  SPA_FORMAT_AUDIO_rate     = 65539;
  SPA_FORMAT_AUDIO_channels = 65540;
  SPA_FORMAT_AUDIO_position = 65541;

  SPA_MEDIA_TYPE_audio    = 1;
  SPA_MEDIA_SUBTYPE_raw   = 1;
  SPA_AUDIO_FORMAT_F32_LE = 283;
  SPA_AUDIO_CHANNEL_FL    = 3;
  SPA_AUDIO_CHANNEL_FR    = 4;

  { pipewire/stream.h }
  PW_DIRECTION_INPUT  = 0;
  PW_DIRECTION_OUTPUT = 1;

  PW_STREAM_FLAG_AUTOCONNECT = 1;
  PW_STREAM_FLAG_MAP_BUFFERS = 4;
  PW_STREAM_FLAG_RT_PROCESS  = 16;

  PW_VERSION_STREAM_EVENTS = 2;

  { pipewire/core.h }
  PW_VERSION_CORE_EVENTS     = 1;
  PW_VERSION_REGISTRY        = 3;
  PW_VERSION_REGISTRY_EVENTS = 0;
  PW_ID_CORE                 = 0;
  PW_ID_ANY                  = cuint32($FFFFFFFF);

  { vtable slot indices, derived from the offsetof values in the method
    structs - every slot is 8 bytes and slot 0 is the struct's own `version`
    field, so index = offset div 8 }
  PW_CORE_METHOD_SYNC          = 3;  { offset 24 }
  PW_CORE_METHOD_GET_REGISTRY  = 6;  { offset 48 }
  PW_REGISTRY_METHOD_ADD_LISTENER = 1; { offset 8 }

  { property keys - pipewire/keys.h }
  PW_KEY_MEDIA_TYPE      = 'media.type';
  PW_KEY_MEDIA_CATEGORY  = 'media.category';
  PW_KEY_MEDIA_ROLE      = 'media.role';
  PW_KEY_MEDIA_CLASS     = 'media.class';
  PW_KEY_APP_NAME        = 'application.name';
  PW_KEY_NODE_NAME       = 'node.name';
  PW_KEY_NODE_DESCRIPTION = 'node.description';
  PW_KEY_NODE_LATENCY    = 'node.latency';
  PW_KEY_TARGET_OBJECT   = 'target.object';

  PW_TYPE_INTERFACE_Node = 'PipeWire:Interface:Node';

type
  Ppw_loop = Pointer;
  Ppw_thread_loop = Pointer;
  Ppw_context = Pointer;
  Ppw_core = Pointer;
  Ppw_registry = Pointer;
  Ppw_stream = Pointer;
  Ppw_properties = Pointer;

  { spa/utils/dict.h - 16 bytes, items is an array of key/value pairs }
  Pspa_dict_item = ^Tspa_dict_item;
  Tspa_dict_item = record
    Key: PChar;
    Value: PChar;
  end;

  Pspa_dict = ^Tspa_dict;
  Tspa_dict = record
    Flags: cuint32;
    NItems: cuint32;
    Items: Pspa_dict_item;
  end;

  { spa/utils/hook.h - opaque to us, 48 bytes, filled in by *_add_listener }
  Tspa_hook = array[0..47] of Byte;
  Pspa_hook = ^Tspa_hook;

  { spa/utils/hook.h - the first member of every proxy object, which is how
    the pw_*_method macros find the vtable }
  Pspa_interface = ^Tspa_interface;
  Tspa_interface = record
    IfaceType: PChar;
    Version: cuint32;
    Pad: cuint32;
    CbFuncs: Pointer;   { -> the method struct, slot 0 = its version field }
    CbData: Pointer;    { -> the object every method takes as its first arg }
  end;

  { spa/buffer/buffer.h }
  Pspa_chunk = ^Tspa_chunk;
  Tspa_chunk = record
    Offset: cuint32;
    Size: cuint32;
    Stride: cint32;
    Flags: cint32;
  end;

  Pspa_data = ^Tspa_data;
  Tspa_data = record
    DataType: cuint32;
    Flags: cuint32;
    Fd: cint64;
    MapOffset: cuint32;
    MaxSize: cuint32;
    Data: Pointer;
    Chunk: Pspa_chunk;
  end;

  Pspa_buffer = ^Tspa_buffer;
  Tspa_buffer = record
    NMetas: cuint32;
    NDatas: cuint32;
    Metas: Pointer;
    Datas: Pspa_data;
  end;

  { pipewire/stream.h - 40 bytes }
  Ppw_buffer = ^Tpw_buffer;
  Tpw_buffer = record
    Buffer: Pspa_buffer;
    UserData: Pointer;
    Size: cuint64;
    Requested: cuint64;
    Time: cuint64;
  end;

  { pipewire/stream.h - 96 bytes: a version field padded to 8, then 11 slots.
    Only Process is ever filled in here; the rest must stay nil. }
  Tpw_stream_events = record
    Version: cuint32;
    Pad: cuint32;
    Destroy: Pointer;
    StateChanged: Pointer;
    ControlInfo: Pointer;
    IoChanged: Pointer;
    ParamChanged: Pointer;
    AddBuffer: Pointer;
    RemoveBuffer: Pointer;
    Process: Pointer;
    Drained: Pointer;
    Command: Pointer;
    TriggerDone: Pointer;
  end;
  Ppw_stream_events = ^Tpw_stream_events;

  { pipewire/core.h - 80 bytes }
  Tpw_core_events = record
    Version: cuint32;
    Pad: cuint32;
    Info: Pointer;
    Done: Pointer;
    Ping: Pointer;
    Error: Pointer;
    RemoveId: Pointer;
    BoundId: Pointer;
    AddMem: Pointer;
    RemoveMem: Pointer;
    BoundProps: Pointer;
  end;
  Ppw_core_events = ^Tpw_core_events;

  { pipewire/core.h - 24 bytes }
  Tpw_registry_events = record
    Version: cuint32;
    Pad: cuint32;
    Global: Pointer;
    GlobalRemove: Pointer;
  end;
  Ppw_registry_events = ^Tpw_registry_events;

  TPwStreamProcessCb = procedure(AData: Pointer); cdecl;
  TPwCoreDoneCb = procedure(AData: Pointer; AId: cuint32; ASeq: cint); cdecl;
  TPwRegistryGlobalCb = procedure(AData: Pointer; AId: cuint32;
    APermissions: cuint32; AType: PChar; AVersion: cuint32;
    AProps: Pspa_dict); cdecl;

var
  pw_init: procedure(AArgc: Pointer; AArgv: Pointer); cdecl;

  pw_thread_loop_new: function(AName: PChar; AProps: Pspa_dict): Ppw_thread_loop; cdecl;
  pw_thread_loop_destroy: procedure(ALoop: Ppw_thread_loop); cdecl;
  pw_thread_loop_get_loop: function(ALoop: Ppw_thread_loop): Ppw_loop; cdecl;
  pw_thread_loop_start: function(ALoop: Ppw_thread_loop): cint; cdecl;
  pw_thread_loop_stop: procedure(ALoop: Ppw_thread_loop); cdecl;
  pw_thread_loop_lock: procedure(ALoop: Ppw_thread_loop); cdecl;
  pw_thread_loop_unlock: procedure(ALoop: Ppw_thread_loop); cdecl;
  pw_thread_loop_wait: procedure(ALoop: Ppw_thread_loop); cdecl;
  pw_thread_loop_signal: procedure(ALoop: Ppw_thread_loop; AWaitForAccept: cbool); cdecl;

  pw_properties_new_dict: function(ADict: Pspa_dict): Ppw_properties; cdecl;
  pw_properties_free: procedure(AProps: Ppw_properties); cdecl;

  pw_stream_new_simple: function(ALoop: Ppw_loop; AName: PChar;
    AProps: Ppw_properties; AEvents: Ppw_stream_events;
    AData: Pointer): Ppw_stream; cdecl;
  pw_stream_destroy: procedure(AStream: Ppw_stream); cdecl;
  pw_stream_connect: function(AStream: Ppw_stream; ADirection: cint;
    ATargetId: cuint32; AFlags: cuint32; AParams: PPointer;
    ANParams: cuint32): cint; cdecl;
  pw_stream_dequeue_buffer: function(AStream: Ppw_stream): Ppw_buffer; cdecl;
  pw_stream_queue_buffer: function(AStream: Ppw_stream; ABuffer: Ppw_buffer): cint; cdecl;

  pw_context_new: function(ALoop: Ppw_loop; AProps: Ppw_properties;
    AUserDataSize: csize_t): Ppw_context; cdecl;
  pw_context_destroy: procedure(AContext: Ppw_context); cdecl;
  pw_context_connect: function(AContext: Ppw_context; AProps: Ppw_properties;
    AUserDataSize: csize_t): Ppw_core; cdecl;
  pw_core_disconnect: function(ACore: Ppw_core): cint; cdecl;

{ True once libpipewire is loaded, every symbol is resolved and pw_init has
  run. Safe to call repeatedly. }
function PwLoad: Boolean;

{ "Is PipeWire actually here?" - the library being installed isn't enough,
  something has to be listening. Used to pick the startup default backend. }
function PwServerPresent: Boolean;

{ The two pw_*_method macros this binding needs, done by hand: both dispatch
  through the object's leading spa_interface, and both pass cb.data (NOT the
  proxy pointer) as the method's first argument, exactly as
  spa_callbacks_call_res does. }
function PwCoreGetRegistry(ACore: Ppw_core): Ppw_registry;
function PwCoreSync(ACore: Ppw_core; AId: cuint32; ASeq: cint): cint;
function PwRegistryAddListener(ARegistry: Ppw_registry; AHook: Pspa_hook;
  AEvents: Ppw_registry_events; AData: Pointer): cint;
{ pw_core_add_listener is a method too, but on the core's OWN interface }
function PwCoreAddListener(ACore: Ppw_core; AHook: Pspa_hook;
  AEvents: Ppw_core_events; AData: Pointer): cint;

implementation

uses
  SysUtils, dynlibs
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

type
  TSlotGetRegistry = function(AObject: Pointer; AVersion: cuint32;
    AUserDataSize: csize_t): Ppw_registry; cdecl;
  TSlotSync = function(AObject: Pointer; AId: cuint32; ASeq: cint): cint; cdecl;
  TSlotAddListener = function(AObject: Pointer; AHook: Pspa_hook;
    AEvents: Pointer; AData: Pointer): cint; cdecl;

var
  LibHandle: TLibHandle = 0;
  Loaded: Boolean = False;

function PwLoad: Boolean;

  function Sym(const AName: string; out ATarget: Pointer): Boolean;
  begin
    ATarget := GetProcedureAddress(LibHandle, AName);
    Result := ATarget <> nil;
  end;

begin
  if Loaded then
    Exit(True);

  if LibHandle = 0 then
    LibHandle := LoadLibrary('libpipewire-0.3.so.0');
  if LibHandle = 0 then
    LibHandle := LoadLibrary('libpipewire-0.3.so');
  if LibHandle = 0 then
    Exit(False);

  Result :=
    Sym('pw_init', Pointer(pw_init)) and
    Sym('pw_thread_loop_new', Pointer(pw_thread_loop_new)) and
    Sym('pw_thread_loop_destroy', Pointer(pw_thread_loop_destroy)) and
    Sym('pw_thread_loop_get_loop', Pointer(pw_thread_loop_get_loop)) and
    Sym('pw_thread_loop_start', Pointer(pw_thread_loop_start)) and
    Sym('pw_thread_loop_stop', Pointer(pw_thread_loop_stop)) and
    Sym('pw_thread_loop_lock', Pointer(pw_thread_loop_lock)) and
    Sym('pw_thread_loop_unlock', Pointer(pw_thread_loop_unlock)) and
    Sym('pw_thread_loop_wait', Pointer(pw_thread_loop_wait)) and
    Sym('pw_thread_loop_signal', Pointer(pw_thread_loop_signal)) and
    Sym('pw_properties_new_dict', Pointer(pw_properties_new_dict)) and
    Sym('pw_properties_free', Pointer(pw_properties_free)) and
    Sym('pw_stream_new_simple', Pointer(pw_stream_new_simple)) and
    Sym('pw_stream_destroy', Pointer(pw_stream_destroy)) and
    Sym('pw_stream_connect', Pointer(pw_stream_connect)) and
    Sym('pw_stream_dequeue_buffer', Pointer(pw_stream_dequeue_buffer)) and
    Sym('pw_stream_queue_buffer', Pointer(pw_stream_queue_buffer)) and
    Sym('pw_context_new', Pointer(pw_context_new)) and
    Sym('pw_context_destroy', Pointer(pw_context_destroy)) and
    Sym('pw_context_connect', Pointer(pw_context_connect)) and
    Sym('pw_core_disconnect', Pointer(pw_core_disconnect));

  if not Result then
  begin
    UnloadLibrary(LibHandle);
    LibHandle := 0;
    Exit;
  end;

  pw_init(nil, nil);
  Loaded := True;
end;

function PwServerPresent: Boolean;
var
  Dir: string;
begin
  if not PwLoad then
    Exit(False);

  { the usual place, and the one pipewire itself defaults to: a socket named
    pipewire-0 in the user's runtime dir. PIPEWIRE_RUNTIME_DIR wins if it's
    set, then XDG_RUNTIME_DIR, then the conventional /run/user/<uid>. }
  Dir := GetEnvironmentVariable('PIPEWIRE_RUNTIME_DIR');
  if Dir = '' then
    Dir := GetEnvironmentVariable('XDG_RUNTIME_DIR');
  if Dir = '' then
    {$IFDEF UNIX}
    Dir := '/run/user/' + IntToStr(FpGetUid);
    {$ELSE}
    Exit(False);
    {$ENDIF}

  Result := FileExists(IncludeTrailingPathDelimiter(Dir) + 'pipewire-0');
end;

function PwCoreGetRegistry(ACore: Ppw_core): Ppw_registry;
var
  Iface: Pspa_interface;
  Slots: PPointer;
begin
  Result := nil;
  if ACore = nil then
    Exit;
  Iface := Pspa_interface(ACore);
  Slots := PPointer(Iface^.CbFuncs);
  if Slots = nil then
    Exit;
  Result := TSlotGetRegistry(Slots[PW_CORE_METHOD_GET_REGISTRY])(
    Iface^.CbData, PW_VERSION_REGISTRY, 0);
end;

function PwCoreSync(ACore: Ppw_core; AId: cuint32; ASeq: cint): cint;
var
  Iface: Pspa_interface;
  Slots: PPointer;
begin
  Result := -1;
  if ACore = nil then
    Exit;
  Iface := Pspa_interface(ACore);
  Slots := PPointer(Iface^.CbFuncs);
  if Slots = nil then
    Exit;
  Result := TSlotSync(Slots[PW_CORE_METHOD_SYNC])(Iface^.CbData, AId, ASeq);
end;

{ add_listener sits at the same slot (1) in both method structs, so one
  helper body serves the core and the registry - see the two offsetof-derived
  constants above. }
function AddListenerAt(AObject: Pointer; ASlot: Integer; AHook: Pspa_hook;
  AEvents: Pointer; AData: Pointer): cint;
var
  Iface: Pspa_interface;
  Slots: PPointer;
begin
  Result := -1;
  if AObject = nil then
    Exit;
  Iface := Pspa_interface(AObject);
  Slots := PPointer(Iface^.CbFuncs);
  if Slots = nil then
    Exit;
  FillChar(AHook^, SizeOf(Tspa_hook), 0);
  Result := TSlotAddListener(Slots[ASlot])(Iface^.CbData, AHook, AEvents, AData);
end;

function PwRegistryAddListener(ARegistry: Ppw_registry; AHook: Pspa_hook;
  AEvents: Ppw_registry_events; AData: Pointer): cint;
begin
  Result := AddListenerAt(ARegistry, PW_REGISTRY_METHOD_ADD_LISTENER, AHook,
    AEvents, AData);
end;

function PwCoreAddListener(ACore: Ppw_core; AHook: Pspa_hook;
  AEvents: Ppw_core_events; AData: Pointer): cint;
begin
  Result := AddListenerAt(ACore, PW_REGISTRY_METHOD_ADD_LISTENER, AHook,
    AEvents, AData);
end;

end.
