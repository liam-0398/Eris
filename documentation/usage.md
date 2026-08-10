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
| Tempo box (top-left) | Type a BPM (20–999) and click away / press Tab to apply. |
| Grid slider (top-right) | Sets the timeline snap resolution: 1/16, 1/8, 1/4, 1/2, or 1 bar. |

The metronome clicks on every beat during normal playback (not just
count-in), using the exact same click sound as the 4-beat recording
count-in. It's tempo-aware and stays aligned to absolute time, not to when
you pressed Play — if you seek mid-song, it snaps to where the beat actually
falls rather than restarting its own count from your seek point.

Changing the tempo is Ableton-style: every clip's position, length and warp
markers are rescaled so the arrangement stays locked to the same bars and
beats and actually plays faster or slower. It is not a relabelled ruler over
unchanged audio. A clip that was never explicitly warped gets a whole-clip
warp synthesized for it first, so it stretches instead of being truncated.

The window title shows the current project's name once it has been saved or
opened (`Eris - MyTune`), and is temporarily borrowed for status text while a
background job — open, save, export, sample import — is running.

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

The instrument widget also has a **Gain** slider (±24 dB, up = louder) in its
right-hand column. It trims the keyboard-played instrument only — the track
fader that timeline clips also pass through is left alone, so you can balance
your live playing against the arrangement without touching the mix.

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
| `Ctrl+O` | Open a project |
| `Ctrl+S` | Save |
| `Ctrl+Shift+S` | Save As |

File > New, File > Export... and File > Exit have no shortcuts. Note that
`Ctrl+N` is **not** "New Project" — it adds a track (see
[Tracks](#tracks)).

Project files (`.er`) are real tar archives under the hood — no external
`tar` tool is used or required, on any platform. Older loose-directory `.er`
bundles still load. Recorded audio that never came from a file on disk is
embedded into the archive as a real WAV, so it survives save/load.

Open, Save, Export and single-file sample import all run on a background
thread, so the UI stays responsive; the window title shows progress and the
File/Edit/Track menus are disabled while a job is in flight.

### Supported audio files

- **WAV** — 8/16/24/32-bit integer PCM and 32-bit float.
- **AIFF / AIF** — 8/16/24/32-bit integer PCM.
- **MP3** — listed by the file browser, but **not decodable yet**. The
  decoder in `src/util/Mp3Decoder.pas` parses frame headers only; the actual
  spectral decode is unimplemented, so loading an `.mp3` will fail. It is
  deliberately not registered in the decoder table.

Export writes 16-bit stereo WAV only.

## Editing clips

| Shortcut | Action |
|---|---|
| `Ctrl+Z` | Undo (multi-level; there is no redo) |
| `Ctrl+C` | Copy the selected clip, or every clip touched by an active range selection |
| `Ctrl+V` | Paste at the cursor position, on the track you last clicked |
| `Ctrl+D` | Duplicate the selection. With a range selected, the duplicate is placed immediately after it and **the selection itself moves along with it** — hitting Ctrl+D repeatedly stacks copies rightward, Ableton-style. |
| `Ctrl+E` | Split the selected clip at the cursor position |
| `Ctrl+J` | Consolidate — see below |
| `Delete` | Delete the selected clip |

These all also work while the arrangement view has focus (not just via the
Edit menu), but are suspended while you're typing in a text box.

### Consolidate (`Ctrl+J`)

Bounces the selected time range on **one** track down into a single new clip,
Ableton-style. It renders through exactly the same code path as the offline
export — same warp mode, detune, gain and swing — so a consolidated clip
sounds identical to what you just heard.

Two deliberate limits: it only acts on a **range** selection (not a single
selected clip), and a range spanning more than one track is a no-op. There is
no per-track fan-out. Consolidating an empty range does nothing rather than
producing a silent clip.

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
- Consolidate (`Ctrl+J`) needs a range selection and ignores multi-track
  ones.

### Dragging in from the file browser

Drag a supported audio file from the browser and drop it either:
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

## Tracks

| Shortcut | Action |
|---|---|
| `Ctrl+N` | Add a new (normal) track |
| `Ctrl+Shift+N` | Add an Input Track — see [Input tracks](#input-tracks) |
| `Ctrl+Alt+N` | Add a Sampler Track — see [Sampler Track](#sampler-track) |
| `Ctrl+D` | Track > Delete Track — **but see the caveat below** |

The maximum is 32 tracks; adding past that shows a message and does nothing.

**Caveat on `Ctrl+D`:** it is bound to both Edit > Duplicate and Track >
Delete Track. Only one of them can win, so use the **Track > Delete Track
menu item** when you actually want to delete a track.

Delete Track removes the track whose header you last clicked (the focused
track), falling back to the track of the selected clip. This means a track
with no clips on it — a freshly added instrument or sampler track — can still
be deleted. The Master row is not deletable.

### Track headers & the Master row

- **Click a track's header** to select it (for keyboard-play, for the
  swing/instrument widgets, and for the effects-rack menu below). The focused
  track's header is drawn grey.
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
- The arrangement view has both a **horizontal** scrollbar (along the bottom
  of the lane area) and a **vertical** one (down the right of the lanes) once
  there are more tracks than fit on screen.

### Input tracks

An Input Track (Track > Add Input Track, or `Ctrl+Shift+N`) records the live
capture device — ALSA line-in on Linux — instead of its own keyboard-played
or timeline audio. Its header reads `Input 3` rather than `Track 3`.

- Input tracks get an extra **`M` button** on the header (yellow when on):
  the **input monitor**. It routes the live captured signal straight into
  that track's mix, post-tap and pre-insert-FX, with no recording and no
  playhead movement — so it works both as a "am I plugged in and at a sane
  level?" check and as headphone monitoring while you actually record.
  (Not to be confused with the metronome `M` in the transport bar.)
- Pressing **Record** on an Input Track **skips the count-in entirely** —
  the playhead starts moving and capture begins immediately.
- **Input gain** and **input buffer size** live in Edit > Preferences.

### Per-track swing

Select a track and the device panel's left-hand widget shows its swing
controls:

- **Swing slider** — snaps to the SP-1200's own six detents: 50% (straight),
  54, 58, 63, 67, 71. The current value is shown in the widget's label
  (`Swing 58%`). It is a detent index, not a free percentage, so it always
  lands on one of those six.
- **Division button** (`1/16` / `1/8`) — which grid unit swing pairs up.
  Click to toggle. Defaults to 1/16.

Swing delays every other grid step's clips later by that percentage, per
track. It applies identically to live playback, Consolidate, and Export.

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
maps onto its source audio. The `+`/`-` buttons in its left column zoom the
waveform horizontally.

- **Drag the end marker** (the red grab bar at the clip's right edge) to
  change the clip's length — always an elastic stretch of the final segment
  (the source content doesn't shift, it just plays faster/slower to fit).
  This is the "drag five bars onto four" gesture, so it gets a wider grab
  zone than a normal marker and the cursor changes to a resize arrow when
  you're over it.
  - It **snaps to the beat grid** drawn underneath it — landing exactly on a
    bar line is the whole point of the gesture. **Hold Alt** to place it
    freely.
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
  start/end). Inserting a marker is a genuine playback no-op until you drag
  it — it splits a segment without changing any slice's timing.
- **Double-click an existing marker** does nothing — that's not how you
  remove one.
- **Right-click a marker to delete it.** The start and end markers can't be
  deleted this way (there's always at least two).

### Clip gain and detune

To the right of the warp mode buttons, every selected clip gets two vertical
sliders (drag **up** to increase, matching a real mixer):

- **Gain** — ±24 dB trim on that clip alone, on top of the track fader.
- **Detune** — ±12 semitones. This is a pure pitch change; the clip's length
  on the timeline does **not** change.

### Warp modes: BT / LF / RP

Three buttons in the warp editor's left column, mutually exclusive, lit
green when active. They set the *selected clip's* mode and do nothing if no
clip is selected.

- **`BT` — Beats** (default). Transient-sliced and overlap-capable: the
  source is cut at every detected transient, and each slice is triggered as
  its own voice at the timeline frame the warp maps its start to, then plays
  **forward at 1:1** and is allowed to keep sounding after the next slice has
  already started. That overlap is the point — compressing a clip leaves each
  slice with more audio than timeline, and the surplus decays underneath the
  incoming hit instead of being cut off, which is why it stays dense where a
  single-read-pointer warp goes choppy. Pitch is preserved. This is the mode
  for breaks and drums, and the only mode that can genuinely fill time on a
  large stretch.
- **`LF` — Tones**. For sustained low-frequency material: 808s, sub bass,
  anything monophonic where Beats has nothing useful to slice at and its
  splices land mid-cycle of a waveform whose period is longer than the
  crossfade. Nothing is resynthesised or granulated — each note is found by
  its onset (with a 150 ms minimum, so an 808's amplitude swell and pitch
  glide don't read as extra onsets), placed where the warp maps that onset,
  and played forward at 1:1 from its own start. Interior audio is completely
  untouched, so there is no phase jump, comb filtering or pitch wobble at
  all.
  - **Its limit is deliberate:** LF cannot fill time. A note whose slot is
    longer than its audio simply ends and leaves its own natural decay — it
    never loops, because a looped bass note is an obvious artefact. Use LF to
    *correct timing*, not to stretch. Use Beats for large stretches.
- **`RP` — Re-Pitch**. The old-school alternative: a continuous vari-speed
  resample, exactly like slowing down/speeding up a sampler or tape — pitch
  changes with length. You can also hold Shift while resizing a clip's edge
  to invoke the same kind of stretch for a single drag, without changing the
  clip's stored mode.

Switching a clip **into** Re-Pitch from either pitch-preserving mode resets
its length, since a pitch-preserving warp's length is free in a way a
vari-speed one's is not.

## File browser

- **H button** — jump to your home folder. On Windows this is your user
  folder (`C:\Users\Name`), not Documents.
- **/ button** — jump to the filesystem root. On Windows there is no single
  root, so this opens a **drive list** ("This PC") instead; picking a drive
  enters it, and `..` from a drive root goes back to the drive list.
- **Drag the vertical splitter** between the browser and the timeline to
  resize the browser panel.
- Only `.wav`, `.aiff`, `.aif` and `.mp3` files are shown (along with
  folders). Note that `.mp3` is listed but cannot be decoded yet — see
  [Supported audio files](#supported-audio-files).

## Effects

**Right-click empty space in the bottom device panel** to open the "add
effect" menu. Whatever is currently selected — a track, or the Master row —
is what the effect gets added to. Categories: Filters, EQ, Modulation,
Reverb, Utility, Mastering, Experimental.

Each effect widget has an **X** button in its corner to remove it. Master
effects run after every track's own inserts, and before the SP-1200
emulation.

### Filters

- **LP** — lowpass, one slider (cutoff, 20 Hz–20 kHz, logarithmic — most of
  the useful range is in the lower half of the slider, matching how frequency
  perception actually works). Defaults to 8 kHz.
- **HP** — highpass, same log cutoff slider. Defaults to 100 Hz.
- **BP** — bandpass, with a log **Center frequency** slider (default 1 kHz)
  and a **Q (bandwidth)** slider (default 1.00).

### EQ

- **4** — 4-band EQ. Frequency is typed per band, gain is on vertical
  sliders (±12 dB). Dragging a gain slider **up increases gain** (matching a
  real mixer) — most GTK vertical sliders default to the opposite, this one's
  been corrected. Bands default to 100 / 500 / 2000 / 8000 Hz at 0 dB.

### Modulation

- **Chorus** — classic Ableton Live 1/2-style chorus: a single short
  modulated delay per channel (not a modern multi-voice ensemble), fixed
  50/50 dry/wet. **Rate** (0.05–5 Hz) and **Depth** (0–100%) are the only two
  controls, on purpose. Defaults 0.5 Hz / 50%.
- **Flanger** — **Rate** (0.05–5 Hz), **Depth** (0–100%), **Fdbk**
  (feedback, 0–95%), **Mix** (0–100% wet). Defaults 0.3 Hz / 60% / 40% / 50%.
- **Phaser** — **Rate** (0.05–5 Hz), **Depth** (0–100%), **Fdbk** (0–95%),
  **Mix** (0–100% wet). Defaults 0.4 Hz / 70% / 30% / 50%.

### Reverb

- **Basic Reverb** — pick a room type (Small, Room, Club, Hall, Plate) from
  the dropdown and set the Dry/Wet balance (0–100%). Nothing else to
  configure — the room type controls size/decay/tone together. Defaults to
  Room at 30% wet.

### Utility

- **Sidechain** — ducks this track from another track's level. **Source** is
  a dropdown of tracks; then **Thresh** (−60…0 dB), **Attack** (1–200 ms),
  **Release** (10–1000 ms) and **Strength** (0–100%, how much gain reduction
  full ducking applies). Defaults: track 1, −20 dB, 5 ms, 150 ms, 70%.

### Mastering

- **Limiter** — **Ceiling** (−24…0 dB) and **Release** (10–500 ms).
  Zero-lookahead, instant attack, so it's a true brick-wall ceiling; release
  is smoothed to avoid audible pumping. Defaults −1 dB / 150 ms.

### Experimental

Newest and least battle-tested; kept out of the normal categories rather than
sorted into them by DSP type.

- **Drowning** — a vocal-wash chain: lowpass tone stage → chorus-style
  warble → comb/allpass reverb tank. **Tone** (log cutoff), **W.Rate**
  (warble rate, 0.05–5 Hz), **W.Depth** (0–100%), **Size** (0–100%, tank
  size), **Decay** (0–100%), **Mix** (0–100% wet). Defaults are a
  2012-Clams-Casino-style wash: 2500 Hz, 0.35 Hz, 55%, 65%, 70%, 45%.

**Known gap:** HP and BP filter parameters are not yet written to the project
file, so their cutoff/Q reset to defaults on reload. Every other effect's
parameters persist.

## Preferences

Edit > Preferences. What actually does something today:

- **SP-1200 emulation** (On/Off) — applied immediately on change.
- **Buffer size** (128–4096) — applied on **OK**, since it stops and reopens
  the audio backend.
- **Input buffer** (128–4096) — same, for the capture device. Defaults to
  1024, a sensible size for line-in.
- **Input gain** (−24…+24 dB) — applied immediately as you drag.

**Backend**, **Device** and **Sample rate** are placeholders for future
backend options and don't do anything yet.

## SP-1200 emulation

A separate, always-available master-bus mode, toggled in Preferences. When
on, it applies a lo-fi sample-and-hold decimation (to roughly 26 kHz / 12-bit,
with no anti-aliasing) to the entire master output — live and on export,
identically. What you hear while mixing is exactly what gets rendered.

## Recording

Position the cursor where you want the take to start, select a track, then
press Record.

- **Normal and Sampler tracks**: a 4-beat count-in plays first (the same
  click as the metronome), then recording starts. A normal track needs an
  instrument loaded; a Sampler Track doesn't (it captures whatever its key
  bank plays). Stopping during the count-in cancels the take.
- **Input tracks**: no count-in — recording starts immediately from the live
  capture device.

Either way, the take lands as a new clip at the cursor on that track.
Recorded audio is embedded directly into the `.er` project file on save, so
it survives closing and reopening the project even though it was never loaded
from a file on disk.

## Display scaling

Every widget is hand-placed in code, so the LCL's design-time autoscaling
never sees it. Eris scales itself instead: on a Wayland session it uses the
screen's reported DPI (so 150% desktop scaling works), and on Xorg it applies
a fixed 1.05× so the hand-picked sizes come out as intended. There is no
user-facing setting for this.
