unit WinMidiInput;

{$mode objfpc}{$H+}

{ Windows MIDI input via winmm, the platform half of MidiInput.pas - same
  arrangement DirectSoundBackend has with AudioBackend, and like that unit
  everything below the interface is wrapped in {$IFDEF WINDOWS} so the file
  still compiles on Linux.

  This unit deliberately does NOT pull in the Windows unit, and declares the
  handful of Win32 types it needs itself. Adding `Windows` to a uses clause
  drags in its own GetEnvironmentVariable/FindClose/etc, which then outrank
  the SysUtils versions the rest of the codebase calls - the exact overload
  clash that FileBrowser.pas already had to work around. Four type aliases
  are cheaper than that blast radius.

  winmm gives us the easy half of MIDI: messages arrive already parsed into
  status/data1/data2 packed in dwParam1, so there is no byte-stream state
  machine here, no running-status reconstruction, and no System Real-Time
  bytes to step over. Those are Linux's problem when that side gets written. }

interface

uses
  MidiInput;

function WinMidiStart(AHandler: TMidiNoteEvent): Boolean;
procedure WinMidiStop;
function WinMidiDeviceName: string;

implementation

{$IFDEF WINDOWS}

type
  TMMRESULT = LongWord;
  TMMUINT = LongWord;
  TMMDWORD = LongWord;
  THMIDIIN = PtrUInt;
  PHMIDIIN = ^THMIDIIN;

  { MIDIINCAPSA. Only szPname is used; the rest is here so the struct is the
    size winmm expects. Field order gives natural 4-byte alignment with no
    padding, so packed and unpacked agree at 44 bytes. }
  TMidiInCapsA = record
    wMid: Word;
    wPid: Word;
    vDriverVersion: TMMUINT;
    szPname: array[0..31] of AnsiChar;
    dwSupport: TMMDWORD;
  end;

const
  MMSYSERR_NOERROR = 0;
  CALLBACK_FUNCTION = $00030000;
  MIM_DATA = $3C3;
  { channel voice message, low nibble is the channel and we accept all 16 }
  MIDI_NOTE_ON = $90;

function midiInGetNumDevs: TMMUINT; stdcall;
  external 'winmm.dll' name 'midiInGetNumDevs';
function midiInGetDevCapsA(ADeviceID: PtrUInt; ACaps: Pointer;
  ASize: TMMUINT): TMMRESULT; stdcall;
  external 'winmm.dll' name 'midiInGetDevCapsA';
function midiInOpen(APhmi: PHMIDIIN; ADeviceID: TMMUINT; ACallback: PtrUInt;
  AInstance: PtrUInt; AFlags: TMMDWORD): TMMRESULT; stdcall;
  external 'winmm.dll' name 'midiInOpen';
function midiInStart(AHmi: THMIDIIN): TMMRESULT; stdcall;
  external 'winmm.dll' name 'midiInStart';
function midiInStop(AHmi: THMIDIIN): TMMRESULT; stdcall;
  external 'winmm.dll' name 'midiInStop';
function midiInReset(AHmi: THMIDIIN): TMMRESULT; stdcall;
  external 'winmm.dll' name 'midiInReset';
function midiInClose(AHmi: THMIDIIN): TMMRESULT; stdcall;
  external 'winmm.dll' name 'midiInClose';

var
  Handle: THMIDIIN = 0;
  Handler: TMidiNoteEvent = nil;
  DeviceName: string = '';
  Started: Boolean = False;

{ Called by winmm on its own thread. Everything the MMSYSTEM callback rules
  forbid applies: no allocation, no system calls back into winmm, no blocking,
  and no exception may escape. All this does is unpack three bytes and call
  the handler, which pushes to a preallocated lock-free ring.

  Handler is cleared before the port is closed in WinMidiStop, so a callback
  already in flight during shutdown finds nil and does nothing rather than
  dispatching into a half-torn-down form. }
procedure MidiInCallback(AHmi: THMIDIIN; AMsg: TMMUINT;
  AInstance, AParam1, AParam2: PtrUInt); stdcall;
var
  Status, Note, Velocity: Byte;
  Local: TMidiNoteEvent;
begin
  if AMsg <> MIM_DATA then
    Exit;

  Status := Byte(AParam1);
  Note := Byte(AParam1 shr 8);
  Velocity := Byte(AParam1 shr 16);

  if (Status and $F0) <> MIDI_NOTE_ON then
    Exit;
  { velocity 0 is the running-status spelling of note-off; we ignore both,
    see MidiInput.pas's header }
  if Velocity = 0 then
    Exit;

  { read once into a local - WinMidiStop can nil the global between the test
    and the call otherwise }
  Local := Handler;
  if Local <> nil then
    Local(Note, Velocity);
end;

function CapsName(ADeviceID: TMMUINT): string;
var
  Caps: TMidiInCapsA;
begin
  FillChar(Caps, SizeOf(Caps), 0);
  if midiInGetDevCapsA(ADeviceID, @Caps, SizeOf(Caps)) = MMSYSERR_NOERROR then
    Result := string(PAnsiChar(@Caps.szPname[0]))
  else
    Result := 'MIDI input';
  if Result = '' then
    Result := 'MIDI input';
end;

function WinMidiStart(AHandler: TMidiNoteEvent): Boolean;
begin
  if Started then
    Exit(True);
  if AHandler = nil then
    Exit(False);
  if midiInGetNumDevs = 0 then
    Exit(False); { nothing plugged in - not an error }

  { device 0, unconditionally. Picking between several keyboards is exactly
    the kind of decision this feature is meant not to have. }
  Handler := AHandler;
  if midiInOpen(@Handle, 0, PtrUInt(@MidiInCallback), 0, CALLBACK_FUNCTION)
    <> MMSYSERR_NOERROR then
  begin
    Handler := nil;
    Handle := 0;
    Exit(False);
  end;

  if midiInStart(Handle) <> MMSYSERR_NOERROR then
  begin
    midiInClose(Handle);
    Handler := nil;
    Handle := 0;
    Exit(False);
  end;

  DeviceName := CapsName(0);
  Started := True;
  Result := True;
end;

procedure WinMidiStop;
begin
  if not Started then
    Exit;

  { order matters: disarm the callback first so anything winmm is midway
    through delivering becomes a no-op, and only then take the port down }
  Handler := nil;
  Started := False;

  midiInStop(Handle);
  { midiInClose fails outright if any buffer is still pending; reset returns
    them all first. We queue no sysex buffers, so this is belt-and-braces. }
  midiInReset(Handle);
  midiInClose(Handle);

  Handle := 0;
  DeviceName := '';
end;

function WinMidiDeviceName: string;
begin
  Result := DeviceName;
end;

{$ELSE}

function WinMidiStart(AHandler: TMidiNoteEvent): Boolean;
begin
  Result := False;
end;

procedure WinMidiStop;
begin
end;

function WinMidiDeviceName: string;
begin
  Result := '';
end;

{$ENDIF}

end.
