# Eris usage guide

Every keyboard shortcut and mouse gesture in the app, including the
non-obvious ones (loop points, warp marker dragging, modifier-key behavior).
If something you expect to work isn't listed here, it isn't implemented yet.

## Transport & playback

| Input | Effect |
|---|---|
| `Space` | Play / Pause |
| `Ctrl` + `+` (numpad, or `=` on the main keyboard) | Zoom timeline in |
| `Ctrl` + `-` (numpad or main keyboard) | Zoom timeline out |
| **M button** (left of Stop) | Toggle the metronome. Click it — it's a manual toggle, not a momentary button, and turns lime-green when on. |
| **RP button** (left column of the Warp editor) | Toggle the *selected clip's* warp mode between Beats (default) and Re-Pitch. Does nothing if no clip is selected. Turns lime-green when Re-Pitch is active. |
| Tempo box (top-left) | Type a BPM (20–999) and click away / press Tab to apply. |
| Grid slider (top-right) | Sets the timeline snap resolution: 1/16, 1/8, 1/4, 1/2, or 1 bar. |

The metronome clicks on every beat during normal playback (not just
count-in), using the exact same click sound as the 4-beat recording
count-in. It's tempo-aware and stays aligned to absolute time, not to when
you pressed Play — if you seek mid-song, it snaps to where the beat actually
falls rather than restarting its own count from your seek point.

### Keyboard-play (QWERTY note mapping)

Once a track has an instrument loaded and is selected (click its header),
your keyboard plays it like a tracker — monophonic, one-shot, hard retrigger
(a new note always cuts off whatever was already playing on that track).
Typing in any text box (tempo, EQ frequency, etc.) suspends this so you can
type normally.

Bottom row = lower octave, top row = upper octave (classic OctaMED / Renoise
/ Impulse Tracker layout):

```
Upper octave:  Q  2  W  3  E  R  5  T  6  Y  7  U  I  9  O  0  P
Lower octave:  Z  S  X  D  C  V  G  B  H  N  J  M
```

The track's own octave offset (`+`/`-` buttons on the instrument widget)
shifts the whole mapping up/down by full octaves.

### Sampler Track

A Sampler Track (Track menu > Add Sampler Track, or `Ctrl+Alt+N`) is a
dedicated, sample-only track type: instead of one shared instrument, its
device panel shows 12 boxes — one per lower-row QWERTY key
(`Z S X D C V G B H N J M`) — each holding its own independent sample.

- **Assign a key** by dragging a clip from the timeline onto one of the 12
  boxes. Whatever trim the clip already had carries over as that key's
  start/end markers, instead of defaulting to the whole underlying sample.
  Dropping onto an already-filled key **replaces it outright** — no
  stacking.
- **Click a box** to select it and show its waveform plus start/end markers
  below, with the same `+`/`-` zoom buttons and bar/beat grid as the
  instrument and warp waveform editors. The grid always starts counting
  from the very beginning of the sample (bar 1, beat 0) — a sampler key has
  no position on the timeline of its own.
- **Right-click a filled box** to clone its sample and start/end markers
  into the next empty box (searching forward, wrapping around) and select
  it — the fast way to spread one long sample (a breakbeat) across several
  keys, then drag each key's own markers onto a different slice.
- **Empty key = silent.**
- **Octave shift** uses the same `+`/`-` buttons as instrument mode, but
  behaves differently: instead of pitching one shared sample per key, a
  Sampler Track's 12 keys each keep their own assigned sample, and the
  octave shift transposes the *whole bank* together in whole-octave steps
  only. The lower QWERTY row plays at the track's current octave setting;
  the upper row plays the same 12 keys one (or more) octave(s) up — so, for
  example, with the octave set to -1, the upper row plays every key at its
  original, unpitched recording speed.
- A Sampler Track's device panel slot is always the per-key waveform editor
  — the clip/warp editor never shows for it, even if a clip happens to be
  selected on its timeline lane.

## Files

| Shortcut | Action |
|---|---|
| `Ctrl+N` | Add a new track (**not** "New Project" — there's no shortcut for that) |
| `Ctrl+Alt+N` | Add a new Sampler Track — see [Sampler Track](#sampler-track) below |
| `Ctrl+O` | Open a project |
| `Ctrl+S` | Save |
| `Ctrl+Shift+S` | Save As |

Project files (`.er`) are real tar archives under the hood — no external
`tar` tool is used or required. Export (File > Export...) has no shortcut.

## Editing clips

| Shortcut | Action |
|---|---|
| `Ctrl+Z` | Undo (multi-level; there is no redo) |
| `Ctrl+C` | Copy the selected clip, or every clip touched by an active range selection |
| `Ctrl+V` | Paste at the cursor position, on the track you last clicked |
| `Ctrl+D` | Duplicate the selection. With a range selected, the duplicate is placed immediately after it and **the selection itself moves along with it** — hitting Ctrl+D repeatedly stacks copies rightward, Ableton-style. |
| `Ctrl+E` | Split the selected clip at the cursor position |
| `Delete` | Delete the selected clip |

These all also work while the arrangement view has focus (not just via the
Edit menu), but are suspended while you're typing in a text box.

### Moving and resizing clips

- **Drag the middle of a clip** to move it — you can drag it onto a
  different track. Snaps to the grid by default.
- **Drag a clip's left or right edge** to trim it. By default this is a
  plain **truncate**: it just cuts (or extends into silence on the right
  edge), keeping whatever warp/pitch that part of the clip already had —
  nothing about the sound changes, you're just cutting it shorter or longer.
- **Hold Shift while dragging an edge** instead does an **elastic resize**:
  the same underlying audio content gets stretched or squeezed to fit the
  new length (this changes the effective pitch/speed, same as dragging the
  end marker in the Warp editor). Use this when you actually want the clip
  to "become" a different length rather than just being cut.
- **Hold Ctrl while dragging** (move *or* resize) bypasses grid snapping
  entirely, for free placement.

  **Ctrl = ignore the grid. Shift (on a resize handle only) = stretch
  instead of cut.** They're independent and can't be confused with each
  other since Shift only does anything special on a resize drag.

### Selecting a range across time and tracks

- **Click and drag on empty space** in the lane area (not on a clip) to draw
  a rectangular selection across whatever tracks the drag crosses. A plain
  click (no drag) just moves the playback cursor there.
- Copy/Paste/Duplicate all understand this range selection the same way they
  understand a single selected clip — clips only partially inside the range
  get split at the boundary automatically.

### Dragging in from the file browser

Drag a `.wav` file from the browser and drop it either:
- **onto a track's lane** — creates a new clip there, or
- **onto the device panel** (bottom bar) — loads it as that track's
  keyboard-play instrument. Only works if a real track (not Master, not
  "no track") is currently selected.

Double-clicking a file in the browser does the instrument-load version
directly, using whichever track is currently selected.

You can also drag a clip that's already on the timeline off the **bottom
edge of the arrangement view**, onto the device panel below (or just
double-click the clip) to load it as the instrument the same way. This
seeds the instrument's start **and** end markers from wherever that clip
was already trimmed to on the timeline, instead of always resetting to the
whole underlying sample.

## Track headers & the Master row

- **Click a track's header** to select it (for keyboard-play and for the
  effects-rack menu below).
- **Click the small square in the corner of a track header** to mute/unmute
  it (lime = on, red = off).
- **Click-drag the horizontal line below the track name** to set that
  track's volume.
- **Click the "Master" row at the bottom of the track list** to select the
  master bus instead of a track — this is what right-clicking the device
  panel adds effects *to* when Master is selected (see below). Clicking the
  Master row's lane area to its left (rather than its header text) does not
  select it — it just moves the playback cursor, same as clicking any other
  empty lane space.

## Loop points

**Right-click in the ruler strip** (the bar/beat numbers above the
timeline) to set loop points — this is not obvious from the UI and has no
menu equivalent:

1. First right-click sets the loop **start**.
2. Second right-click sets the loop **end** — if you click before the
   existing start, the two swap, so you don't need to click in order.
3. Right-clicking again once both are set **clears the loop** entirely.

Right-clicking anywhere else in the ruler/timeline does nothing.

## The Warp editor

Select a clip to open its Warp editor in the bottom bar. Every clip has at
least a start and end marker; add more to control how the clip's timing
maps onto its source audio.

- **Drag the end marker** to change the clip's length — this is always an
  elastic stretch of the final segment (the source content doesn't shift,
  it just plays faster/slower to fit).
- **The start marker can't be dragged.**
- **Drag a middle marker (plain drag)** — a *local* edit: only the two
  segments touching that marker stretch to meet its new position. This is
  Ableton's actual default behavior, despite looking like it should ripple
  further.
- **Ctrl+drag a middle marker** — shifts that marker *and every marker after
  it* by the same amount (which also changes the clip's total length),
  without touching anyone's pitch. Use this to nudge a recurring timing
  drift in one motion instead of fixing every marker individually.
- **Double-click empty space** in the waveform to insert a new marker there
  (rejected if it'd land too close to an existing one, or right at the very
  start/end).
- **Double-click an existing marker** does nothing — that's not how you
  remove one.
- **Right-click a marker to delete it.** The start and end markers can't be
  deleted this way (there's always at least two).

### Beats vs. Re-Pitch (the RP button)

- **Beats** (default) time-stretches without changing pitch, using small
  transient-sized grains that loop back-and-forth to fill extra time —
  close to Ableton's "Preserve: Transients" + "Loop Back-and-Forth" combo.
  Good for lining up breaks/drums without them changing key.
- **Re-Pitch** is the old-school alternative: a continuous vari-speed
  resample, exactly like slowing down/speeding up a sampler or tape — pitch
  changes with length. Toggle it with the RP button next to the clip's warp
  editor, or hold Shift while resizing a clip's edge to invoke the same kind
  of stretch for a single drag without changing the clip's stored mode.

## File browser

- **H button** — jump to your home folder.
- **/ button** — jump to the filesystem root (or the current drive's root
  on Windows).
- **Drag the vertical splitter** between the browser and the timeline to
  resize the browser panel.
- Only `.wav` files are shown (along with folders).

## Effects

**Right-click empty space in the bottom device panel** to open the "add
effect" menu. Whatever is currently selected — a track, or the Master row —
is what the effect gets added to. Categories: Filters, EQ, Modulation,
Reverb, Utility (currently empty), Mastering.

Each effect widget has an **X** button in its corner to remove it.

- **Filters > LP** — lowpass filter, one slider (cutoff, 20 Hz–20 kHz,
  logarithmic — most of the useful range is in the lower half of the
  slider, matching how frequency perception actually works).
- **EQ > 4** — 4-band EQ, frequency typed per band, gain on vertical
  sliders. Dragging a gain slider **up increases gain** (matching a real
  mixer) — most GTK vertical sliders default to the opposite, this one's
  been corrected.
- **Modulation > Chorus** — classic Ableton Live 1/2-style chorus: a single
  short modulated delay per channel (not a modern multi-voice ensemble),
  fixed 50/50 dry/wet. Rate (0.05–5 Hz) and Depth (0–100%) are the only two
  controls, on purpose.
- **Reverb > Basic Reverb** — pick a room type (Small, Room, Club, Hall,
  Plate) from the dropdown and set the Dry/Wet balance. Nothing else to
  configure — the room type controls size/decay/tone together.
- **Mastering > Limiter** — Ceiling (dB) and Release (ms). Zero-lookahead,
  instant attack, so it's a true brick-wall ceiling; release is smoothed to
  avoid audible pumping.

## SP-1200 emulation

Edit > Preferences has an SP-1200 emulation toggle (On/Off) — this is the
only control in that dialog that actually does anything yet; Backend,
Device, Sample rate, and Buffer size are placeholders for future backend
options. When on, it applies a lo-fi sample-and-hold decimation to the
entire master output, live and on export, identically — what you hear while
mixing is exactly what gets rendered.

## Recording

Press Record to start a 4-beat count-in (using the same click as the
metronome), then it records straight to a new clip on whichever track was
selected when you pressed it. Recorded audio is embedded directly into the
`.er` project file on save, so it survives closing and reopening the
project even though it was never loaded from a file on disk.
