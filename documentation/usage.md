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

The metronome clicks on every beat during normal playback, not just during
the recording count-in. It stays aligned to the bar, so seeking mid-song
lands it wherever the beat actually falls rather than restarting its count
from where you clicked.

Changing the tempo rescales the whole arrangement, Ableton-style: clips stay
locked to the same bars and beats and actually play faster or slower. It is
not a relabelled ruler over unchanged audio.

The window title shows the current project's name once it has been saved or
opened (`Eris - MyTune`), and is borrowed for status text while a background
job — open, save, export, sample import — is running.

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
  instrument and warp waveform editors. The grid always counts from the very
  beginning of the sample — a sampler key has no position on the timeline of
  its own.
- **Right-click a filled box** to clone its sample and markers into the next
  empty box and select it — the fast way to spread one long sample (a
  breakbeat) across several keys, then drag each key's own markers onto a
  different slice.
- **Empty key = silent.**
- **Octave shift** uses the same `+`/`-` buttons as instrument mode, but
  transposes the *whole bank* in whole-octave steps rather than pitching one
  shared sample per key. The lower QWERTY row plays at the track's current
  octave setting; the upper row plays the same 12 keys an octave up — so with
  the octave set to -1, the upper row plays every key at its original,
  unpitched recording speed.
- A Sampler Track's device panel always shows the per-key waveform editor —
  the clip/warp editor never appears for it, even if a clip on its lane is
  selected.

## Files

| Shortcut | Action |
|---|---|
| `Ctrl+O` | Open a project |
| `Ctrl+S` | Save |
| `Ctrl+Shift+S` | Save As |

File > New, File > Export... and File > Exit have no shortcuts. Note that
`Ctrl+N` is **not** "New Project" — it adds a track (see
[Tracks](#tracks)).

Projects save as a single `.er` file. Anything you recorded that never came
from a file on disk is stored inside it, so takes survive closing and
reopening the project.

Open, Save, Export and sample import all run in the background, so the app
stays responsive; the window title shows progress and the File/Edit/Track
menus are disabled until the job finishes.

### Supported audio files

- **WAV** — 8/16/24/32-bit integer PCM and 32-bit float.
- **AIFF / AIF** — 8/16/24/32-bit integer PCM.
- **MP3** — listed by the file browser, but **not loadable yet**. Opening one
  will fail.

Export writes 16-bit stereo WAV.

Samples that aren't at the project's sample rate are resampled on import, so
they play at the right speed and pitch.

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

These all work with the arrangement view focused as well as from the Edit
menu, but are suspended while you're typing in a text box.

### Consolidate (`Ctrl+J`)

Bounces the selected time range on **one** track down into a single new clip,
Ableton-style. Warp mode, detune, gain and swing are all printed into it, so
a consolidated clip sounds identical to what you just heard.

Two deliberate limits: it only acts on a **range** selection (not a single
selected clip), and a range spanning more than one track does nothing.
Consolidating an empty range does nothing rather than producing a silent
clip.

### Moving and resizing clips

- **Drag the middle of a clip** to move it — you can drag it onto a
  different track. Snaps to the grid by default.
- **Drag a clip's left or right edge** to trim it. By default this is a
  plain **truncate**: it just cuts (or extends into silence on the right
  edge), keeping whatever warp/pitch that part of the clip already had —
  nothing about the sound changes, you're just cutting it shorter or longer.
- **Hold Shift while dragging an edge** instead does an **elastic resize**:
  the same audio gets stretched or squeezed to fit the new length (this
  changes the pitch/speed, same as dragging the end marker in the Warp
  editor). Use this when you want the clip to "become" a different length
  rather than just being cut.
- **Hold Ctrl while dragging** (move *or* resize) bypasses grid snapping
  entirely, for free placement.

  **Ctrl = ignore the grid. Shift (on a resize handle only) = stretch
  instead of cut.** They're independent and can't be confused with each
  other, since Shift only does anything special on a resize drag.

### Selecting a range across time and tracks

- **Right-click and drag anywhere in the lane area** — over empty space or
  straight across clips, it doesn't matter — to draw a rectangular selection
  across whatever tracks the drag crosses. It's the right button precisely
  so that starting the drag on top of a clip never grabs that clip instead.
  A plain right-click (no drag) just clears the selection.
- **Left-click empty space** moves the playback cursor there and drops any
  active range; left-dragging never starts a range selection.
- To *move* a range selection, left-drag any clip inside it — the whole
  selection moves together.
- Copy/Paste/Duplicate understand a range selection the same way they
  understand a single selected clip — clips only partially inside the range
  get split at the boundary automatically.
- Consolidate (`Ctrl+J`) needs a range selection, and ignores multi-track
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
keeps whatever trim that clip already had on the timeline instead of
resetting to the whole underlying sample.

## Tracks

| Shortcut | Action |
|---|---|
| `Ctrl+N` | Add a new (normal) track |
| `Ctrl+Shift+N` | Add an Input Track — see [Input tracks](#input-tracks) |
| `Ctrl+Alt+N` | Add a Sampler Track — see [Sampler Track](#sampler-track) |
| `Ctrl+Shift+D` | Delete the current track |

The maximum is 32 tracks; adding past that shows a message and does nothing.

Delete Track removes the track whose header you last clicked, falling back to
the track of the selected clip. So a track with no clips on it — a freshly
added instrument or sampler track — can still be deleted. The Master row is
not deletable.

### Track headers & the Master row

- **Click a track's header** to select it (for keyboard-play, for the
  swing/instrument widgets, and for the effects rack below). The focused
  track's header is drawn grey.
- **Click the small square in the corner of a track header** to mute/unmute
  it (lime = on, red = off).
- **Click-drag the horizontal line below the track name** to set that
  track's volume.
- **Click the "Master" row at the bottom of the track list** to select the
  master bus instead of a track — that's what effects get added to while it's
  selected. Clicking the Master row's lane area to its left (rather than its
  header text) does not select it; it just moves the playback cursor, same as
  clicking any other empty lane space.
- The arrangement view has both a **horizontal** scrollbar (along the bottom
  of the lane area) and a **vertical** one (down the right of the lanes) once
  there are more tracks than fit on screen.

### Sends (S1 / S2)

Two send buses, **S1** and **S2**, pinned to the bottom of the track pane —
they stay put while the track list scrolls, and they only occupy the header
column, never the timeline.

A send takes a copy of a track's signal, sums it with the copies from every
other track feeding the same send, runs that **one** sum through **one**
effect chain, and returns it to the master. So everything on a send sits in
the same space — a reverb fed from the break, the pads and the stabs is one
room they're all in, not three reverbs that happen to match — and it costs
one effect's worth of CPU no matter how many tracks feed it.

On each **track header**, under the volume fader:

- **S1** and **S2** buttons — off by default, darkening when on. Just the
  on/off for feeding that bus.
- A **level slider** next to each — how much of this track goes to that bus.
  It's ignored while the button is off and greys out to show it, so you can
  leave a send set at a useful amount and switch it in and out without losing
  the setting. New tracks start at half.

On each **S1 / S2 row**:

- **Click anywhere on the row** to select the bus. The bottom device panel
  switches to that send's effect chain — add effects there exactly as you
  would for a track or the Master row. The row shows how many effects the bus
  is carrying.
- **Rtn** slider — return level, how much of the processed bus comes back
  into the master. Same range as a track fader.
- **PRE / POST** button — where each feeding track is tapped. **POST**
  (default) taps after that track's fader, so pulling the fader down takes
  its send down with it, like Ableton. **PRE** taps before the fader, so you
  can pull a track's fader all the way to nothing and its contribution to the
  bus keeps going — which is how you get a break to dissolve into the wash
  instead of just stopping.
- The small square in the corner — bus mute (lime = on, red = off). Muting a
  bus skips its chain entirely, so it's also how you get the CPU back from a
  send you aren't using.

Muting a *track* stops it feeding the sends too, pre-fader included.

Sends are saved with the project and sound the same in playback and in an
exported WAV.

### Input tracks

An Input Track (Track > Add Input Track, or `Ctrl+Shift+N`) records the live
capture device — line-in — instead of its own keyboard-played or timeline
audio. Its header reads `Input 3` rather than `Track 3`.

Recording and monitoring work the same on all three Linux backends
(PipeWire, ALSA and JACK). Which source gets captured is the system default
under ALSA, the **Input** dropdown in Preferences under PipeWire, and
whatever you patch into Eris's `in_L`/`in_R` ports under JACK.

- Input tracks get an extra **`M` button** on the header (yellow when on):
  the **input monitor**. It routes the live signal straight into that track's
  mix, with no recording and no playhead movement — so it works both as an
  "am I plugged in and at a sane level?" check and as headphone monitoring
  while you record. (Not to be confused with the metronome `M` in the
  transport bar.)
- Pressing **Record** on an Input Track **skips the count-in** — the playhead
  starts moving and capture begins immediately.
- **Input gain** and **input buffer size** live in Edit > Preferences.

### Per-track swing

Select a track and the device panel's left-hand widget shows its swing
controls:

- **Swing slider** — snaps to the SP-1200's own six settings: 50%
  (straight), 54, 58, 63, 67, 71. The current value is shown in the widget's
  label (`Swing 58%`); it always lands on one of those six.
- **Division button** (`1/16` / `1/8`) — which grid unit swing pairs up.
  Click to toggle. Defaults to 1/16.

Swing pushes every other grid step later by that amount, per track, and
applies identically to playback, Consolidate and Export.

## Loop points

**Right-click in the ruler strip** (the bar/beat numbers above the
timeline) to set loop points — this is not obvious from the UI and has no
menu equivalent:

1. First right-click sets the loop **start**.
2. Second right-click sets the loop **end** — if you click before the
   existing start, the two swap, so you don't need to click in order.
3. Right-clicking again once both are set **clears the loop** entirely.

Right-clicking elsewhere in the ruler strip does nothing. Below the ruler,
in the lane area, right-drag is the time-range selection gesture instead
(see "Selecting a range across time and tracks" above).

## The Warp editor

Select a clip to open its Warp editor in the bottom bar. Every clip has at
least a start and end marker; add more to control how the clip's timing maps
onto its audio. The `+`/`-` buttons in its left column zoom the waveform.

- **Drag the end marker** (the red grab bar at the clip's right edge) to
  change the clip's length — always a stretch of the final segment. This is
  the "drag five bars onto four" gesture, so it gets a wider grab zone than a
  normal marker and the cursor changes to a resize arrow over it.
  - It **snaps to the beat grid** drawn underneath — landing exactly on a bar
    line is the whole point of the gesture. **Hold Alt** to place it freely.
- **The start marker can't be dragged.**
- **Drag a middle marker (plain drag)** — a *local* edit: only the two
  segments touching that marker stretch to meet its new position. This is
  Ableton's actual default behavior, despite looking like it should ripple
  further.
- **Ctrl+drag a middle marker** — shifts that marker *and every marker after
  it* by the same amount (which also changes the clip's total length),
  without touching anyone's pitch. Use this to nudge a recurring timing drift
  in one motion instead of fixing every marker individually.
- **Double-click empty space** in the waveform to insert a new marker there
  (rejected if it'd land too close to an existing one, or right at the very
  start/end). A new marker changes nothing until you drag it.
- **Double-click an existing marker** does nothing — that's not how you
  remove one.
- **Right-click a marker to delete it.** The start and end markers can't be
  deleted (there's always at least two).

### Clip gain and detune

To the right of the warp mode buttons, every selected clip gets two vertical
sliders (drag **up** to increase, matching a real mixer):

- **Gain** — ±24 dB trim on that clip alone, on top of the track fader.
- **Detune** — ±12 semitones. A pure pitch change; the clip's length on the
  timeline does **not** change.

### Warp modes: BT / LF / RP

Three buttons in the warp editor's left column, mutually exclusive, lit green
when active. They set the *selected clip's* mode and do nothing if no clip is
selected.

- **`BT` — Beats** (default). The mode for breaks and drums. The clip is cut
  at its transients and each hit is fired at the time the warp puts it,
  playing at its natural speed and allowed to ring on underneath the next
  one. Pitch doesn't change with length, and it stays dense rather than going
  choppy when you squeeze a clip down. This is the only mode that handles
  large stretches well.
- **`LF` — Tones**. For sustained low material — 808s, sub bass, anything
  monophonic where Beats has nothing useful to slice at and ends up wobbling
  the pitch. Each note is placed where the warp puts it and plays through
  untouched, so there are no artefacts at all.
  - **Its limit is deliberate:** LF can't fill time. A note whose slot is
    longer than its audio just ends and leaves its natural decay — it never
    loops, because a looped bass note is an obvious artefact. Use LF to
    *correct timing*, not to stretch; use Beats for large stretches.
- **`RP` — Re-Pitch**. The old-school one: speed and pitch change together,
  exactly like slowing down or speeding up a sampler or a record. You can
  also hold Shift while resizing a clip's edge to get the same effect for a
  single drag, without changing the clip's stored mode.

Switching a clip **into** Re-Pitch from either of the other two resets its
length, since a pitch-preserving warp's length is free in a way a
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
  folders). `.mp3` is listed but can't be loaded yet — see
  [Supported audio files](#supported-audio-files).

## Effects

**Right-click empty space in the bottom device panel** to open the "add
effect" menu. Whatever is currently selected — a track, a send bus, or the
Master row — is what the effect gets added to. Each effect widget has an
**X** button in its corner to remove it, and every effect's settings are
saved with the project.

Master effects run after every track's own inserts, and before the SP-1200
emulation.

What's in the menu, by category:

- **Filters** — lowpass, highpass and bandpass.
- **EQ** — a 4-band EQ.
- **Modulation** — chorus, flanger, phaser.
- **Distortion** — Overdrive: a saturator for making something louder,
  wrecking an 808, or just adding crunch. You can aim it at a particular
  band, so the grit lands where you want it instead of across everything.
- **Reverb** — a simple room-type reverb (pick a size, set dry/wet), plus a
  detailed emulation of a classic late-80s rack reverb for the atmospheric
  sound.
- **Delay** — the delay side of that same rack unit: mono, stereo or
  ping-pong, with its repeats getting darker and grainier as they circulate.
- **Dynamics** — a compressor/limiter/gate modelled on the cheap 90s
  workhorse, with peak and RMS modes and a built-in gate.
- **Exciter** — a Sonic Maximizer-style processor: not a treble EQ, it splits
  the signal into bands and shifts their timing against each other so the top
  of a hit arrives in front of its own low end.
- **Utility** — Sidechain (duck this track from another track's level) and
  Tuner (see below).
- **Mastering** — a brick-wall limiter.
- **Experimental** — newest and least battle-tested. Currently Drowning, a
  vocal-wash effect.

Most effects have a **Mix** control, so anything can be run in parallel
rather than fully in-line.

### Reading the Tuner

The Tuner has no controls and never touches the audio — drop it on a track,
play, and read the display. The big character is the nearest note with its
octave, green when you're on it and amber when you're not. The three dots
either side light on the side the pitch has drifted **towards** (left =
flat, right = sharp), and **fewer dots means closer** — one dot is a few
cents out, three is nearly a quarter-tone. Underneath is the exact deviation
in cents and the raw frequency.

It reads one sustained pitch at a time, so it works on bass, 808s, leads and
vocals; chords, drums and noise read as `-- / no pitch` rather than as a
made-up note. It holds the last note for a second or so after the sound
stops so it doesn't blink between notes.

It works with the transport stopped as long as audio is running, so an Input
track with its **M** monitor on gives you a live tuner for whatever is
plugged into the line-in.

## Preferences

Edit > Preferences. What actually does something today:

- **Backend** — PipeWire, ALSA or JACK on Linux; DirectSound on Windows.
  Applied on **OK**, since it stops and reopens the audio device. Eris starts
  on **PipeWire** if PipeWire is actually running, and falls back to ALSA if
  it isn't. See [Using PipeWire](#using-pipewire) and
  [Using JACK](#using-jack) below.
- **Output** / **Input** — which device each direction uses. Live under
  PipeWire only (see below); placeholders under ALSA, greyed under JACK.
- **SP-1200** (On/Off) — applied immediately.
- **Buffer size** (128–4096) — applied on **OK**, since it stops and reopens
  the audio device.
- **Input buffer** (128–4096) — same, for the capture device. Defaults to
  1024, a sensible size for line-in.
- **Input gain** (−24…+24 dB) — applied immediately as you drag.

**Sample rate** is a placeholder and doesn't do anything yet.

### Using PipeWire

The default on any machine actually running PipeWire, and the one to use
unless you have a reason not to. Eris connects as a real PipeWire client
(not through the ALSA or JACK compatibility layers), so it appears in
qpwgraph as its own node and can be rewired there like anything else.

**Output** and **Input** list your PipeWire sinks and sources by name:

- **Default (system)** — follow whatever your desktop's current default
  device is, including when that changes later. This is the right choice
  most of the time.
- Anything else pins Eris to that specific device, and it stays pinned even
  if the system default moves.

**The lists refresh every time you open Preferences.** Plug an interface in,
open Edit > Preferences, and it's there — no restart. They also refresh the
moment you pick PipeWire in the Backend dropdown.

Changing either device reopens both streams, so there's a brief gap in the
audio when you hit OK. Selecting a device that has since disappeared falls
back to the system default rather than going silent.

The sample rate needs no attention here: Eris asks PipeWire for its own rate
and PipeWire converts to whatever the graph is running at.

### Using JACK

Pick **JACK** as the backend and hit OK. Eris registers as a JACK client
called `Eris` with `out_L`/`out_R` (and `in_L`/`in_R` for capture), and
connects itself to the first pair of hardware ports it finds so you get sound
without a trip to the patchbay. Rewire it however you like afterwards in
qjackctl or qpwgraph — Eris never reconnects behind you.

This works with real JACK (jackd) and with PipeWire's JACK layer; they
provide the same library and Eris doesn't care which is running.

Selecting JACK **greys out Output, Input, Sample rate, Buffer size and Input
buffer**, because under JACK those aren't Eris's to set: the sample rate and
the period size belong to the server and are set in qjackctl before it
starts, and routing belongs to the patchbay. Everything else in this dialog
still applies.

Two things worth knowing:

- **If JACK isn't installed or the server isn't running**, selecting it is
  still allowed. Eris just runs with nowhere to send audio — silent, no
  error, no crash. Switch the backend back to ALSA to get sound again. Same
  applies if the server dies while Eris is connected.
- **If the JACK server isn't at 44100**, Eris resamples to match it, which
  costs a little quality. Setting the server to 44100 in qjackctl avoids the
  conversion entirely.

## SP-1200 emulation

A master-bus lo-fi mode, toggled in Preferences. When on, it crunches the
entire master output the way an SP-1200 does, live and on export identically
— what you hear while mixing is exactly what gets rendered.

## Recording

Position the cursor where you want the take to start, select a track, then
press Record.

- **Normal and Sampler tracks**: a 4-beat count-in plays first (the same
  click as the metronome), then recording starts. A normal track needs an
  instrument loaded; a Sampler Track doesn't (it captures whatever its key
  bank plays). Stopping during the count-in cancels the take.
- **Input tracks**: no count-in — recording starts immediately from the live
  capture device.

Either way, the take lands as a new clip at the cursor on that track, and is
stored inside the project file on save, so it survives closing and reopening
even though it never came from a file on disk.

## Display scaling

Eris scales its interface to your display automatically — Wayland sessions
follow the desktop's scaling setting, Xorg gets a fixed small bump. There is
no user-facing setting for this.
