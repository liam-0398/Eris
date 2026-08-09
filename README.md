# Eris

A linear-timeline, audio-only DAW for jungle/breakbeat production, inspired by
the early versions of Ableton Live, Player Pro, and OctaMED. Written in
Object Pascal (Lazarus/FPC).

Native, dependency-light audio path (ALSA on Linux, DirectSound on Windows),
non-destructive clip editing with two independent time-warp modes, a
per-track/master effects chain, and an SP-1200 lo-fi emulation mode baked
identically into live monitoring and offline export.

DISCLAIMER: HEAVY LLM usage. I know decent Pascal but do not know about audio engineering and decided to just go forth with having an LLM implement what I wanted instead of putting in the years to do it myself. I do plan to rewrite it bit by bit but the focus currently is having a usable DAW that does exactly what I want, written in the language I want and adhering to the constraints I want. Every idea and technical decision is my own but the implementation is brought to you by Claude.  

## Features

- **Arrangement view**: multi-track linear timeline (up to 16 tracks),
  Ableton-style track headers with per-track mute and volume, zoomable/
  scrollable, adjustable grid snap resolution (1/16 note to 1 bar).
- **Non-destructive clip editing**: split, move, resize/trim, drag-and-drop,
  overwrite-on-drop, time-range select with copy/paste/duplicate, multi-level
  undo (no redo).
- **Clip warping**: two independent per-clip modes —
  - **Beats** (default): grain-based, pitch-preserving time-stretch with
    ping-pong loop fill on stretched segments, in the spirit of Ableton's
    "Preserve: Transients" / "Loop Back-and-Forth".
  - **Re-Pitch**: classic continuous vari-speed resample — changes pitch with
    length, like a sampler or tracker.
  - A visual warp marker editor per clip (add/move/delete markers, local
    stretch or shift-everything-after).
- **Keyboard-play instruments**: drag a WAV onto a track's device slot,
  QWERTY tracker-style key-to-note mapping, monophonic one-shot playback with
  hard retrigger, per-track octave shift and sample trim, resample-based
  vari-speed pitch shift (linear interpolation, deliberately lo-fi/OctaMED
  character, not a clean stretch algorithm).
- **Recording**: 4-beat count-in, records straight to a new clip on the
  source track.
- **Tempo-aware metronome**, independent of count-in, toggled on/off live.
- **Effects**: per-track and master-bus insert chains (Lowpass filter, 4-band
  EQ, Limiter, Chorus, Basic Reverb — see `documentation/usage.md` for every
  parameter), plus a dedicated **Master** track/bus row for global effects.
- **SP-1200 emulation**: a separate, always-available master-bus lo-fi
  decimation mode (sample-and-hold to ~26kHz/12-bit, no anti-aliasing), baked
  identically into live playback and rendered/exported audio so they can
  never drift apart.
- **Save/Load**: `.er` project files are real tar archives (native
  reader/writer, no external `tar` dependency on any platform), backward
  compatible with older loose-directory `.er` bundles. Recorded audio with no
  source file is embedded into the bundle as a real WAV so it survives
  save/load.
- **Export**: render the full arrangement (including all effects and SP-1200)
  to a WAV file.
- **File browser**: WAV-only browser with quick-nav to home/root and a
  resizable width, drag-and-drop straight onto a track or the instrument
  slot.

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

See [`documentation/usage.md`](documentation/usage.md) for the full keyboard
shortcut and mouse-gesture reference, including non-obvious interactions
(loop points, warp marker dragging, modifier-key behavior, etc).

## Status

Under active development. Not yet feature-complete or considered stable.
