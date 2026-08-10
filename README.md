# Eris

A linear-timeline, audio-only DAW for jungle/breakbeat production, inspired by
the early versions of Ableton Live, Player Pro, and OctaMED. Written in
Object Pascal (Lazarus/FPC).

Native, dependency-light audio path (ALSA on Linux, DirectSound on Windows),
non-destructive clip editing with three independent time-warp modes, a
per-track/master effects chain, SP-1200-style per-track swing, and an SP-1200
emulation mode baked identically into live monitoring and offline
export.

DISCLAIMER: HEAVY LLM usage. I know decent Pascal but do not know about audio engineering and decided to just go forth with having an LLM implement what I wanted instead of putting in the years to do it myself. I do plan to rewrite it bit by bit but the focus currently is having a usable DAW that does exactly what I want, written in the language I want and adhering to the constraints I want. Every idea and technical decision is my own but the implementation is brought to you by Claude.  

## Features

- **Arrangement view**: multi-track linear timeline (up to 32 tracks),
  Ableton-style track headers with per-track mute and volume, horizontal and
  vertical scrollbars, zoomable, adjustable grid snap resolution (1/16 note
  to 1 bar). Changing the tempo rescales the whole arrangement Ableton-style
  (clips stay locked to the same bars/beats) rather than just relabelling the
  ruler.
- **Non-destructive clip editing**: split, move, resize/trim, drag-and-drop,
  overwrite-on-drop, time-range select with copy/paste/duplicate,
  consolidate-to-one-clip, multi-level undo (no redo).
- **Per-clip gain and detune**: a gain trim (±24 dB) and a pitch detune
  (±12 semitones, length unchanged) on every clip, in the warp widget.
- **Clip warping**: three independent per-clip modes —
  - **Beats** (default, `BT`): transient-sliced and overlap-capable. The
    source is cut at every detected transient and each slice is triggered as
    its own voice at the timeline frame the warp maps it to, playing forward
    at 1:1 and allowed to keep sounding under the next hit — the same trick
    Ableton's Beats mode uses, which is why compressing a clip (five bars
    dragged onto four) stays dense instead of going choppy. Pitch-preserving.
  - **Re-Pitch** (`RP`): classic continuous vari-speed resample — changes
    pitch with length, like a sampler or tracker.
  - **Tones / LF** (`LF`): note-triggered 1:1 playback for sustained
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
  of 12 keyboard-played samples (one per lower-row QWERTY key) instead of a
  single shared instrument. Drag a timeline clip onto a key to assign it,
  preserving whatever trim the clip already had; right-click a filled key to
  clone it into the next empty key, so one long sample (a breakbeat) can be
  spread across the keyboard and re-sliced per key. Unlike instrument mode,
  the octave shift transposes the whole bank by whole octaves rather than
  pitching each key individually. Created via Track > Add Sampler Track
  (`Ctrl+Alt+N`).
- **Input tracks**: a dedicated track type that records the live capture
  device (ALSA line-in) instead of its own keyboard/timeline audio, with a
  per-track `M` input-monitor toggle that routes the live signal into the mix
  with no recording and no playhead movement (so it doubles as headphone
  monitoring while tracking). Input buffer size and input gain are set in
  Preferences.
- **Recording**: 4-beat count-in on normal and Sampler tracks; Input tracks
  arm and record immediately with no count-in. Records straight to a new clip
  at the cursor on the selected track.
- **Tempo-aware metronome**, independent of count-in, toggled on/off live.
- **Effects**: insert chains on every track, on the send buses and on a
  dedicated **Master** row — filters, EQ, modulation (chorus/flanger/phaser),
  overdrive, compression, limiting, reverb, delay, an exciter, sidechain
  ducking and a tuner. Several are emulations of the cheap 90s hardware this
  music was actually made on, aimed at the atmospheric-jungle use of those
  boxes rather than at being general-purpose plugins. See
  [`documentation/usage.md`](documentation/usage.md) for the list.
- **Send buses**: two sends (S1/S2) pinned to the bottom of the track pane,
  with a per-track enable button and send-level slider on every track
  header, and per-bus return level, pre/post-fader tap and mute. One effect
  chain serves every track feeding it — so a reverb shared across the break,
  the pads and the stabs is one room they are all in, at one reverb's worth
  of CPU rather than one per track.
- **SP-1200 emulation**: a separate, always-available master-bus lo-fi mode,
  baked identically into live playback and rendered/exported audio so they
  can never drift apart.
- **Save/Load**: `.er` project files are real tar archives (native
  reader/writer, no external `tar` dependency on any platform), backward
  compatible with older loose-directory `.er` bundles. Recorded audio with no
  source file is embedded into the bundle as a real WAV so it survives
  save/load. Open/Save/Export and sample import all run off the UI thread.
- **Export**: render the full arrangement (including all effects, swing and
  SP-1200) to a WAV file.
- **Sample import**: WAV (8/16/24/32-bit integer PCM and 32-bit float) and
  AIFF/AIF (8/16/24/32-bit integer PCM), via hand-written decoders — no
  third-party codec library. An MP3 decoder is in the tree but unfinished
  and deliberately not wired in yet.
- **File browser**: quick-nav to home/root (a drive list on Windows) and a
  resizable width, drag-and-drop straight onto a track or the instrument
  slot.
- **Cross-platform UI**: hand-built widgets with DPI-aware scaling
  (Wayland HiDPI and Xorg both handled), and a Windows build using
  DirectSound.

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
4. **Windows target**: if you want to build/test the DirectSound backend,
   also install the Windows cross-target packages from fpcupdeluxe's "Cross
   compile" tab (target `win64`/`win32`) before building with
   `--os=win64 --cpu=x86_64`.

## Compiling with lazbuild

From the project root (this directory):

```sh
# incremental build - only recompiles what changed
<path-to-fpcupdeluxe>/lazarus/lazbuild eris.lpi

# full clean rebuild - use this after pulling changes, switching branches,
# or whenever something seems stale
<path-to-fpcupdeluxe>/lazarus/lazbuild -B eris.lpi
```

This produces an `eris` executable in the project root; run it directly
(`./eris` on Linux). There's no separate install step.

To cross-build for Windows (once the win64 packages are installed via
fpcupdeluxe):

```sh
<path-to-fpcupdeluxe>/lazarus/lazbuild --os=win64 --cpu=x86_64 -B eris.lpi
```

## Documentation

See [`documentation/usage.md`](documentation/usage.md) for the user guide —
every keyboard shortcut and mouse gesture, including the non-obvious ones
(loop points, warp marker dragging, modifier-key behavior, etc).

## Status

Under active development. Not yet feature-complete or considered stable.
