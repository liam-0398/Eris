# Dysnomia User Guide

Dysnomia is a terminal-based interface to Eris's engine. If you're comfortable with DAWs and trackers, this will feel familiar — think of it as a keyboard-driven alternative to the graphical version.

## Layout

The interface is split into panes:
- **Top (Toolbar)**: tempo, metronome, transport controls
- **Left (File Browser)**: load samples
- **Center (Timeline)**: your arrangement
- **Right (Track Headers)**: track controls
- **Bottom (Effects / Waveform)**: effect rack or detailed sample editing

Use **Tab / Shift+Tab** to move focus between panes.

## The Golden Rule

**Ctrl+Enter** (or F2 on a real terminal, or right-click) opens a dropdown for whatever's focused. This is how you access detail anywhere — track mute/solo, effect chains, etc. It's the same gesture everywhere.

## Transport & Playback

| Key | Action |
|---|---|
| `Space` | Play / Pause (only works when timeline is focused) |
| `Ctrl+O` | Open project |
| `Ctrl+S` | Save |
| Tempo box | Click or Tab into it, type a BPM (20–999), Tab/Enter to apply |
| M button | Toggle metronome on/off |
| Grid slider | Set timeline snap: 1/16, 1/8, 1/4, 1/2, or 1 bar |
| `+` / `-` | Zoom timeline in/out |

## File Browser

| Key | Action |
|---|---|
| `Enter` | Descend into a folder, or load a file onto the track under the cursor |
| `Ctrl+T` | Load file as a new instrument track with keyboard play active |
| `Esc` | Exit the file browser (or leave the keyboard) |

Drag files from the browser onto the timeline to place them, or onto a track header to load as an instrument.

## Timeline & Clips

Navigate with arrow keys:
- **Up / Down**: move cursor between tracks
- **Left / Right**: navigate left/right in time, or switch between the track column and the grid
- **+** / **-**: zoom in/out

### Editing clips

| Key | Action |
|---|---|
| `Ctrl+C` | Copy clip under cursor |
| `Ctrl+V` | Paste at cursor, on the selected track |
| `Ctrl+D` | Duplicate clip (repeatedly stacks copies rightward, Ableton-style) |
| `Ctrl+E` | Split clip at cursor |
| `Delete` | Delete clip under cursor |
| `w` | Auto-fit clip to nearest power-of-two bar length (clean loop) |
| `Shift+W` | Interactive resize — Left/Right adjust length by grid steps, Enter commits, Esc cancels |
| `m` | Interactive move — Left/Right nudge position, Enter commits, Esc cancels |
| `k` | Mark this clip to show in the waveform editor below |
| `l` | Cycle loop points: 1st press = start, 2nd = end (swaps if out of order), 3rd = clear |

### Drag mode

| Key | Action |
|---|---|
| `Ctrl+S` | Enter drag mode |
| `Enter` | Solidify the drag, then normal edit keys act on it |
| `Esc` | Cancel |

## Instrument Keyboard

When the toolbar is focused, use QWERTY to play the selected track's instrument. The octave buttons (same as the graphical version) shift the whole keyboard up/down.

| Key | Action |
|---|---|
| `Ctrl+Z` | Octave down |
| `Ctrl+X` | Octave up |
| `Esc` | Leave keyboard mode |

This is the classic tracker layout: bottom row is low, top row is high. A track needs an instrument loaded and to be selected (click its header) before keyboard play works.

## Effects & Sends

**Bottom pane**: right-click to add an effect to the selected track, send bus, or master. Every effect you add appears here with its own controls.

| Key | Action |
|---|---|
| `Ctrl+W` | Toggle bottom pane between effects rack and waveform editor |

Track headers show send levels (S1 / S2) and return amount. Click or Ctrl+Enter a track to open its full control panel.

## Waveform Editor

Select a clip and press `k`, or click a clip to open its waveform in the bottom pane. You'll see:
- **Start / end markers** (red bar on the right edge) — drag to trim
- **Middle markers** — drag to time-stretch locally, or Ctrl+drag to nudge this and all later markers
- **Double-click** empty space to add a marker
- **Right-click** a marker to delete it

Warp modes (BT / LF / RP) set how stretches work — see [the graphical guide](usage.md#warp-modes-bt--lf--rp) for details, it's the same here.

To the right of the waveform: **Gain** (±24 dB) and **Detune** (±12 semitones) per clip.

## Sampler Tracks

A sampler track is 12 boxes, one per QWERTY key. Drag clips from the timeline onto the boxes to assign them, or right-click a filled box to clone it. The waveform editor below shows the currently selected box's start/end markers — edit them the same way you would for any clip.

## Recording

Position the cursor where you want to start, select a track, then press Record. Normal and sampler tracks get a 4-beat count-in first; input tracks start immediately from your audio interface.

The take lands as a new clip at the cursor and is stored inside the project file.

## Keyboard Shortcuts (File Menu)

| Key | Action |
|---|---|
| `Ctrl+O` | Open project |
| `Ctrl+S` | Save |
| `Ctrl+Shift+S` | Save As |
| `F12` | Save As (alternative) |
| `Alt+X` | Exit |

Projects save as `.er` files (or `.ers` for standalone). Everything you record lives inside the file.

## Tips

- **The cursor is always at the left edge of a clip.** All edit operations (copy, split, delete) key off "the clip under the cursor," so there's one consistent "where does this act" rule everywhere.
- **Track selection is independent of the clip under the cursor.** Click a track header to select it for keyboard play and effects. Clicking or navigating in the timeline doesn't change the selected track.
- **Copy/paste uses the selected track as the anchor.** If you copy a range across multiple tracks, paste rebuilds it downward from whichever track you have selected.
- **Tempo rescales the whole arrangement.** Clips stay locked to the same bars and beats, they just play faster or slower.
- **Swing per track** — select a track and adjust in its control panel. Swing values snap to the SP-1200's six settings.

## Known Limitations

- **Export** is not yet implemented.
- **Ctrl+S is shadowed.** It opens drag mode on the timeline, so File > Save's shortcut doesn't work while the timeline is focused. Use the menu instead, or switch focus to another pane first.
- **Drag mode** is a stub — Enter/Esc bindings are reserved for future expansion.

## Projects & Audio Files

Dysnomia uses the same project format (`.er`) as the graphical Eris, so you can open the same project in either interface.

Supported formats: **WAV** (8/16/24/32-bit, int or float) and **AIFF** (8/16/24/32-bit int). Everything resamples to the project rate on import.

Export writes 16-bit stereo WAV (graphical version only for now).
