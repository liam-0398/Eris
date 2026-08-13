# Eris

It's all just audio at the end of the day, the way it should be.

An audio-only DAW, inspired by the early versions of Ableton Live, Player Pro, and OctaMED. Written in Pascal (Lazarus/FPC).

Native, dependency-free audio path (ALSA, JACK or Pipewire on Linux, DirectSound on Windows), non-destructive clip editing with three independent time-warp modes, a
per-track/master effects chain, SP-1200-style per-track swing, and an SP-1200
emulation mode baked identically into live monitoring and offline
export.

# DISCLAIMER
**HEAVY LLM usage** I know decent Pascal but do not know about audio engineering and decided to just go forth with having an LLM implement what I wanted instead of putting in the years to do it myself. I do plan to rewrite it bit by bit but the focus currently is having a usable DAW that does exactly what I want, written in the language I want and adhering to the constraints I want. Every idea and technical decision is my own but the implementation is brought to you by Claude.  

## Features

- **Arrangement view**: multi-track linear timeline (up to 32 tracks),
  track headers with per-track mute, solo and volume, horizontal and
  vertical scrollbars, zoomable, adjustable grid snap resolution (1/16 note
  to 1 bar). Changing the tempo rescales the whole arrangement 
  (clips stay locked to the same bars/beats) rather than just relabelling the
  ruler.
- **Non-destructive clip editing**: split, move, resize/trim, drag-and-drop,
  overwrite-on-drop, time-range select with copy/paste/duplicate,
  consolidate-to-one-clip, multi-level undo (no redo).
- **Per-clip gain and detune**: a gain trim (±24 dB) and a pitch detune
  on every clip, in the warp widget.
- **Clip warping**: three independent per-clip modes —
  - **Beats** (default, `BT`): transient-sliced and overlap-capable. The
    source is cut at every detected transient and each slice is triggered as
    its own voice at the timeline frame the warp maps it to, playing forward
    at 1:1 and allowed to keep sounding under the next hit. Pitch-preserving.
  - **Re-Pitch** (`RP`): classic continuous vari-speed resample — changes
    pitch with length, like a sampler or tracker.
  - **Low Frequency** (`LF`): note-triggered 1:1 playback for sustained
    low-frequency material — 808s, sub bass, anything monophonic where Beats
    has no transients worth slicing at. Nothing is resynthesised or
    granulated, so there is no phase-jump or comb artefact; the trade-off is
    that it cannot fill time, making it a timing-correction mode rather than
    a large-stretch mode.
  - A visual warp marker editor per clip (add/move/delete markers, local
    stretch or shift-everything-after, beat-snapped right-edge resize).
- **SP-1200 swing**: per-track, snapped to the SP-1200's own detents
  (50/54/58/63/67/71%), against either a 1/16 or 1/8 grid. Applied
  identically in live playback, consolidate, and export.
- **Keyboard-play instruments**: drag an audio file (or an existing timeline
  clip) onto a track's device slot, QWERTY tracker-style key-to-note mapping,
  monophonic one-shot playback with hard retrigger, per-track octave shift,
  sample trim and gain trim, resample-based vari-speed pitch shift (linear
  interpolation, deliberately lo-fi/OctaMED character, not a clean stretch
  algorithm).
- **Sampler Track**: a dedicated, sample-only track type — a one-octave bank
  of 12 keyboard-played samples (one per lower-row QWERTY key). Drag a timeline clip onto a key to assign it, preserving whatever trim the clip already had; right-click a filled key to clone it into the next empty key, so one long sample (a breakbeat) can be
  spread across the keyboard and re-sliced per key. Unlike instrument mode,
  the octave shift transposes the whole bank by whole octaves rather than
  pitching each key individually. Created via Track > Add Sampler Track
  (`Ctrl+Alt+N`).
- **Input tracks**: a dedicated track type that records the live capture
  device instead of its own keyboard/timeline audio, with a
  per-track `M` input-monitor toggle that routes the live signal into the mix
  with no recording and no playhead movement (so it doubles as headphone
  monitoring while tracking). Input buffer size and input gain are set in
  Preferences.
- **Recording**: 4-beat count-in on normal and Sampler tracks; Input tracks
  arm and record immediately with no count-in. Records straight to a new clip
  at the cursor on the selected track.
- **Metronome**, independent of count-in, toggled on/off live.
- **Effects**: per-track and master-bus insert chains — Lowpass, Highpass and
  Bandpass filters, 4-band EQ, Limiter, Chorus, Flanger, Phaser, Overdrive
  (band-focused saturation for loudness, 808 mangling or plain crunch),
  Sidechain, Tuner, Reverb.
- **Send buses**: two sends (S1/S2) pinned to the bottom of the track pane,
  with a per-track enable button and send-level slider on every track
  header, and per-bus return level, pre/post-fader tap and mute. 
- **SP-1200 emulation**: a separate, always-available master-bus lo-fi
  decimation mode (sample-and-hold to ~26kHz/12-bit).
- **Save/Load**: `.er` project files are tar archives (native
  reader/writer, no external `tar` dependency on any platform).
- **Sample import**: WAV (8/16/24/32-bit integer PCM and 32-bit float) and
  AIFF/AIF (8/16/24/32-bit integer PCM), via built-in decoders.
- **File browser**: quick-nav to home/root (a drive list on Windows) and a
  resizable width, drag-and-drop straight onto a track or the instrument
  slot.
- **Unbeatable Performance**: Heavily optimized for the lowest latency 
  and CPU usage possible. Inline assembly for critical components and 
  auto-detected AVX2 support in areas where it makes sense. 

## Dysnomia

A **WIP** (it barely functions currently) TUI frontend for Eris aiming to implement as many features as possible.

- **Less bloat, more power**: Keyboard driven (mouse optional) interface that 
gives you the choice to run this on practically a toaster and have the full power
of a complex audio engine availible anywhere on any of your tech. (Effects count 
and buffer size obviously dependant on if you are trying to run this on an M68k
or not lol)
- **Cross-Platform**: A big motivator for making this is to run on anything and
everything, including running over SSH. Support for PowerPC Macs is coming soon
and it will target G4s, optimized with Altivec for the absolute best performance. Theoretically it will compile on any platform FPC and FPC's 
Free Vision will compile on.

## Getting the toolchain (fpcupdeluxe)

Eris is built with **Lazarus + Free Pascal (FPC)**. The easiest way to get a
working, self-contained install of both — without depending on whatever
(often outdated) version your OS package manager ships — is
[fpcupdeluxe](https://github.com/LazarusIDE/fpcupdeluxe):

1. Download the fpcupdeluxe release for your platform from its
   [releases page](https://github.com/LazarusIDE/fpcupdeluxe/releases)
   (a single executable/AppImage — no install step).
2. Run it. In the GUI:
   - Pick a stable **FPC** version (3.2.2 or newer) and click **Install FPC**.
   - Pick a stable **Lazarus** version and click **Install Lazarus**.
   - fpcupdeluxe downloads and builds both from source into its own install
     directory (e.g. `~/fpcupdeluxe/`) — it doesn't touch any system Pascal
     toolchain you may already have.
3. When both finish, the Lazarus IDE and `lazbuild` (its headless build
   tool) live under that install directory, typically at
   `~/fpcupdeluxe/lazarus/lazbuild`.

## Compiling

From the project root:

```sh
# incremental build - only recompiles what changed
<path-to-fpcupdeluxe>/lazarus/lazbuild eris.lpi

# full clean rebuild - use this after pulling changes, switching branches,
# or whenever something seems stale
<path-to-fpcupdeluxe>/lazarus/lazbuild -B eris.lpi
```
This produces an `eris` executable in the project root; run it directly
(`./eris` on Linux). There's no separate install step.
```
```sh
# x86_64 build 
./build-dysnomia.sh

# ppc build 
./build-dysnomia-ppc.sh
```
This produces a `dysnomia` executable in the dysnomia-bin folder; run it directly
(`./dysnomia`). There's no separate install step.
```

## Documentation

See [`documentation/usage.md`](documentation/usage.md) for the full keyboard
shortcut and mouse-gesture reference, including non-obvious interactions
(loop points, warp marker dragging, modifier-key behavior, etc).

## Status

Under active development. Not yet feature-complete or considered stable.
Use at your own risk, save format not fully locked in yet.
