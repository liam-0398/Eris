unit MidiInput;

{$mode objfpc}{$H+}

{ Generic USB MIDI keyboard input, in the same shape as AudioBackend: a
  platform-neutral facade here, one implementation unit per platform behind
  it (WinMidiInput for winmm; ALSA still to come).

  Deliberately minimal, and the omissions are choices rather than gaps:

  - Note-ON only. Eris's keyboard play is one-shot - FormKeyDown starts a
    voice and nothing stops it early, the sample just runs to its end - so
    note-off carries no information we could act on. Note-offs, and the
    velocity-0 note-ons that mean the same thing under running status, are
    discarded at the source.
  - No device picking. If a keyboard is plugged in we take the first input
    port and play it; if two are plugged in we still take the first. There is
    no UI, no preference, and nothing to persist in the project file.
  - No hotplug. The port is opened once at startup. Plug the keyboard in
    before launching Eris.
  - All 16 channels are accepted, since nothing downstream distinguishes
    them.

  The handler is invoked ON THE MIDI DRIVER'S OWN THREAD, not the main
  thread, which is what keeps the latency down to the USB and audio-buffer
  cost with no message loop in between. That puts hard limits on what a
  handler may do: no LCL access, no allocation, no blocking, no exceptions.
  MainForm's handler obeys this by reading a snapshot the main thread
  publishes and pushing to AudioEngineTriggerNoteRT, which is lock-free. }

interface

type
  { ANote is a raw MIDI note number (0..127, 60 = middle C); AVelocity is
    1..127, never 0. See the unit header for the thread contract. }
  TMidiNoteEvent = procedure(ANote, AVelocity: Integer);

{ Opens the first available MIDI input port and starts delivering note-ons to
  AHandler. False means no keyboard, no driver, or no MIDI support on this
  platform - all of which are normal, none of which are errors: the caller is
  expected to carry on silently. Safe to call when MIDI is already started
  (it is a no-op). }
function MidiInputStart(AHandler: TMidiNoteEvent): Boolean;

{ Stops delivery and closes the port. Guarantees no further handler calls
  once it returns, so this must run BEFORE anything the handler touches is
  torn down - in particular before the sample pool is freed. Safe to call
  when nothing was ever started. }
procedure MidiInputStop;

{ Human-readable name of the open port, or '' when nothing is open. For
  status/logging only. }
function MidiInputDeviceName: string;

implementation

{$IFDEF WINDOWS}
uses
  WinMidiInput;
{$ENDIF}

function MidiInputStart(AHandler: TMidiNoteEvent): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := WinMidiStart(AHandler);
  {$ELSE}
  { Linux stub. The plan when this gets filled in is ALSA rawmidi over the
    /dev/snd/midiC*D* node that snd-usbmidi creates for any class-compliant
    keyboard: find the first match, open it read-only, and run a blocking
    read loop on a TThread. Unlike winmm - which hands over pre-parsed
    three-byte messages in dwParam1 - that path delivers a raw byte stream,
    so it additionally needs running-status handling (most keyboards omit
    the status byte on repeat note-ons) and has to skip System Real-Time
    bytes such as 0xFE active sensing, which can appear interleaved MID
    message without disturbing running status. }
  Result := False;
  {$ENDIF}
end;

procedure MidiInputStop;
begin
  {$IFDEF WINDOWS}
  WinMidiStop;
  {$ENDIF}
end;

function MidiInputDeviceName: string;
begin
  {$IFDEF WINDOWS}
  Result := WinMidiDeviceName;
  {$ELSE}
  Result := '';
  {$ENDIF}
end;

end.
