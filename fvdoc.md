## Free Vision notes discovered while working

Things dug out of `~/fpcupdeluxe/fpcsrc` while building stage 1, so they
don't need re-deriving from source next time.

**Source layout.** `Objects`, `TCollection`, `TRect`/`TPoint`, `NewStr`/
`DisposeStr` are not in `packages/fv/src` - they're in
`packages/rtl-extra/src/inc/objects.pp`. Within `packages/fv/src`:
`TView`/`TGroup`/`TFrame`/`TScrollBar`/`TListViewer`/`TWindow` are in
`views.pas`; `TInputLine`/`TButton`/`TCluster`/`TListBox`/`TStaticText`/
`TLabel` are in `dialogs.pas`; `TApplication`/`TProgram`/`TDeskTop`/
`TBackGround` are in `app.pas`; `TMenuBar`/`TStatusLine` are in
`menus.pas`. The xterm mouse/keyboard protocol itself isn't part of Free
Vision at all - it's in the FPC RTL, `packages/rtl-console/src/unix/
{mouse,keyboard}.pp`, shared by every Unix target. Only iOS/iphonesim get
a separate `src/darwin` variant (see `fpmake.pp`), so macOS (Darwin) and
Linux both build from that same `src/unix` source - anything true of
one's terminal handling is true of the other's.

**`grep` gotcha.** Plain `grep`/`grep -n` on some files under
`fpcupdeluxe/fpcsrc` silently returns nothing even when the text is
there (locale/encoding detection quirk) - use `grep -a`, or `awk`,
against that tree.

**Coordinates are owner-local, not global.** `Bounds` passed to
`TView.Init` is relative to the immediate Owner's origin, not the
screen - `GetExtent` always returns `(0,0)-(Size)`, even for the
top-level `TApplication`. Every level of nesting needs its own
translation (see `DysnomiaApp.InitDeskTop`'s repeated `Local.Move(...)`).
Caught this the hard way in `TDysToolBar.Init`: its children were
positioned with `Bounds.A.Y` (the bar's row *in the App's frame*, e.g.
row 1) instead of `0` (the bar's own local top row). Since the bar is
only 1 row tall, every child landed one row below its own visible area -
permanently clipped, rendering as an empty black bar with no buttons or
tempo field, even though construction "succeeded" with no error. If a
composite view's own children silently don't appear, suspect this before
anything else - it will not throw, it just clips everything out of view.

**Nothing is focused by default.** `Insert()` doesn't select what it
inserts - without an explicit call, no view anywhere receives keyboard
input, ever. `TView.Select` only sets the immediate Owner's `Current`
(one level). `TView.Focus` recursively climbs `Owner` and calls `Select`
at every level on the way back down - that's the one that actually wires
up keyboard input end-to-end from `TApplication` down to a specific
control. Call `.Focus` on the deepest view you want receiving keys.

Timing matters for that initial call. `TProgram.Init` runs
`InitScreen; InitStatusLine; InitMenuBar; InitDesktop;` and only *after*
`InitDeskTop` returns does it `Insert(DeskTop)`. So calling `.Focus`
*inside* `InitDeskTop` climbs `Owner` from the target view up to
`DeskTop` fine, but `DeskTop.Owner` is still nil at that point - the
climb stops one level short of `TApplication`, so `App.Current` never
gets set. Everything looks like it works anyway, because mouse events
are routed by hit-testing (`FirstThat`/`ContainsMouse`), not by
`Current`, so the user's first click fixes it retroactively by
triggering its own `.Focus` call once `DeskTop.Owner` is finally valid.
The actual bug only shows up as "nothing responds to the keyboard until
you've clicked something once" - do the initial `.Focus` call in the
constructor, after `inherited Init` has fully returned, not from inside
`InitDeskTop`.

**Tab doesn't cross windows by default.** `TWindow.HandleEvent`'s own
`kbTab`/`kbShiftTab` case calls `FocusNext` on itself - that cycles
*that window's own children*, and always consumes the event, so it never
reaches anything above it. To cycle between sibling panes, intercept
Tab/Shift+Tab *before* calling `inherited HandleEvent`, then use the
owner's `SelectNext` (public) followed by `.Focus` on whatever became
`Owner^.Current` (`SelectNext` alone only updates the owner's `Current`,
not the newly-current pane's own). `TGroup.FindNext` and `SetCurrent`
are `private` to `views.pas` and not callable from outside it -
`SelectNext` is the public entry point (see `TDysPane.HandleEvent`).

**Palette cascade and the red-blink bug.** `TView.GetColor(Color)` walks
from `Self` up through *every* `Owner`, calling `GetPalette` at each
level and re-mapping `index := Ord(Palette[index])` wherever a level
returns non-nil - it does not stop at the first hit, it keeps climbing to
the root. If an index exceeds some level's palette length, the result is
`Drivers.ErrorAttr` (`$CF`) - a deliberate "index out of range" sentinel,
not a rendering bug in Free Vision. Attribute byte layout: bit 7 = blink,
bits 4-6 = background (0-7), bits 0-3 = foreground (0-15); `$CF` decodes
to blink + red background + white text, which is exactly the "red and
blinking" panes this repo hit. Root cause: a plain `TWindow`'s own
`GetPalette` (`CBlueWindow`/`CCyanWindow`/`CGrayWindow`, `views.pas`) is
only 8 entries - fine for static content, too short for a child like
`TListBox` (`CListViewer` indexes up to 29). A window hosting one needs a
longer palette instead - `CGrayDialog` (32 entries, `dialogs.pas`) is
what Free Vision's own dialogs use for exactly this, via a `GetPalette`
override (see `TDysPane.GetPalette`). No stock `CAppColor` byte sets bit
7, so treat it as reserved: there's no safe way to represent an
intentional *bright/dark-grey background* in this attribute model
without colliding with that same bit (see `TDysnomiaApp.GetPalette`'s
comment on why black substitutes for "dark grey").

Wrote that rule down correctly and then broke it anyway: the first pass
at a "selected item" colour used `$F0`, reading the high nibble as if
background were a full 0-15 range like foreground. It isn't - `$F0` is
`1111 0000`, i.e. bit 7 (blink) **set**, bg=7, fg=0. That's a blinking
grey tile, not a solid white one - exactly why the list cursor didn't
highlight and blinked instead. The correct reverse-video byte for
"light-grey bg, black fg, no blink" is `$70`. When picking a background
nibble by hand, check bit 7 explicitly - `$F0`/`$Cx`/`$Ex` etc. all look
like plausible "bright background" bytes and are all actually blink.

**`TListViewer` colour indices, concretely.** `TListViewer.Draw`
(`views.pas`) calls `GetColor(2)` for a normal item, `GetColor(3)` for
the focused (keyboard-cursor) item, `GetColor(4)` for a selected-but-
unfocused item, `GetColor(5)` for the multi-column divider. `TListViewer.
GetPalette` returns `CListViewer = #26#26#27#28#29` - a *further* small
remap layer before it ever reaches the owning window/dialog's own
palette, so index 3 ("focused") actually resolves through local dialog
index 27, not 3. Getting the cursor to visibly stand out means giving
index 27 (and usually 28) a distinct colour from index 26 ("normal") in
whatever palette the list's owner returns - all three silently defaulting
to the same byte is what "keyboard focus moves but nothing shows it"
looks like, even though navigation is genuinely working underneath.

**Misc.** `TButton` draws fine at `Size.Y = 1` - its shadow row is only
drawn `if Size.Y > 1`, so single-row toolbar buttons are fine.
`TView.ColourOfs` (added to every palette index before lookup) exists
but nothing in `packages/fv/src` ever assigns it a non-zero value - safe
to ignore, but it's there if some custom view ever needs a palette
sub-range of its own.

**`cthreads` has to be the first unit in the *program*, not just linked
in.** The moment stage 6 gave Dysnomia a real `TThread` (AudioEngine's
playback thread, via `Classes`), the binary ran but crashed on the first
thread create with `Runtime error 232`. FPC's default thread manager on
Unix is a single-threaded stub; `cthreads` (in the RTL, not Free Vision)
installs the real pthread-backed one, but only if its unit `initialization`
runs before anything else's does - which for a `uses` clause means first
in the *program* file, ahead of every unit (including indirectly, since a
unit's own `uses` order doesn't matter here, only the `.lpr`'s does).
`eris.lpr` already had `{$IFDEF UNIX} cthreads, {$ENDIF}` as its first
uses entry; `dysnomia.lpr` needed the identical line before `DysnomiaApp,`.
Whether this bites you depends only on whether anything reachable from the
program actually constructs a `TThread` at runtime - stages 1-5 never did,
so the gap was invisible until stage 6 linked `AudioEngine`.

**Building a custom (non-listbox) focusable content view.** `DysTimeline`'s
grid (stage 7) is a hand-drawn `TView`, not a `TListViewer` descendant like
every other pane's content so far - two things from earlier in this file
turned out to generalize cleanly:
- The `Focusable` + child-view shape (`TDysPane` wraps one focusable child,
  see `DysFilePane`/`DysTrackPane`) works for *any* `TView`, not just
  `TListBox`. `TDysTimelineContent = object(TView)` gets inserted into the
  pane and set as `Focusable` exactly like `TDysFileListBox` does - `.Focus`
  doesn't care what kind of view it's climbing from.
- Keyboard delivery is a real top-down call chain, not a single dispatch to
  whatever's deepest: each `TGroup` between `TApplication` and the focused
  leaf gets its *own* `HandleEvent` invoked (in `Current` order), and each
  one runs its own override's logic before/instead of forwarding via
  `inherited HandleEvent`. That's why `TDysPane`'s Tab-cycling (intercept,
  maybe act, then `inherited`) and a content view's own key handling don't
  fight each other - they're literally different stops on the same
  delivery chain, not competing handlers for the same event. Ctrl+S
  (drag mode) accordingly moved from `TDysTimeline` itself down into
  `TDysTimelineContent.HandleEvent` once the content view became the thing
  that's actually `Current` - left on the outer pane, it would now never
  fire.

**Skip `GetColor`/palette entirely for a hand-rolled view; use raw attribute
bytes.** `GetColor(n)` exists to resolve a small logical index through the
owner-chain palette cascade (see "Palette cascade" above) - useful for
stock controls like `TListViewer` that need to inherit whatever palette
their owner provides. A view that's drawing its own content with its own
fixed meaning (a committed clip block vs. a pending one vs. a plain grid
cell) doesn't need that indirection: `MoveChar`/`MoveStr`'s `Attr: Word`
parameter IS the final screen attribute byte (`GetColor` just returns one
of these, having done the lookup) - passing a hand-picked constant like
`$1F` directly is exactly as valid as passing `GetColor(2)`, skips the
Owner-chain walk, and is far easier to reason about correctly. Same bit
layout rules apply as ever (bit 7 = blink, never set it by accident).

**`MoveStr` at a tick column consumes more than one cell - account for it
or the next write clobbers it.** Drawing a ruler by looping one column at a
time and writing either a tick char or (every Nth column) `IntToStr` of the
elapsed seconds: once the elapsed seconds reaches two digits, `MoveStr`
writes 2 cells starting at that column, but a naive loop still only
`Inc(Col)`s by 1 - so the very next iteration's single-char tick write
lands on the label's second digit and overwrites it immediately. The
label never visibly appears past single digits. Fix: after a multi-cell
write, advance the loop counter by `Length(the string just written)`, not
by 1 - obvious in hindsight, easy to miss because it compiles and looks
right for the first ten columns.

**`bfBroadcast` sends `evBroadcast`, not `evCommand` - a button with that
flag is invisible to a plain `if Event.What = evCommand` handler.** All
five transport buttons (`DysToolBar.Init` in `DysWidgets.pas`: Metronome,
Stop, Play, Rec, Interval) were built with `bfBroadcast`, and
`TDysToolBar.HandleEvent`'s command dispatch (`cmTransportPlay` etc.) only
matches `Event.What = evCommand`. Confirmed in
`fpcupdeluxe/fpcsrc/packages/fv/src/dialogs.pas`, `TButton.Press`: `If
(Flags AND bfBroadcast <> 0) Then Message(Owner, evBroadcast, Command,
@Self) Else` ... `evCommand`. Net effect: clicking Play ran the button's
own press/release visual (so it looked like something happened) but the
`case Event.Command of` block that calls `AudioEngineHasClip`/
`AudioEnginePlay` never ran at all - indistinguishable from "no clip on
the timeline" even with clips committed, because the code path that would
tell the two apart was never reached either way. `bfBroadcast` is for a
control whose action other, unrelated views need to react to (this repo
has no such case yet); a button whose own immediate owner already handles
its command in a `HandleEvent` override wants `bfNormal` instead, so
`Press` sends `evCommand` and that owner's dispatch actually sees it. Any
future toolbar/dialog button in Dysnomia should default to `bfNormal`
unless something else genuinely needs to observe the click via broadcast.

**A `TGroup` descendant's own `Draw` override must call `inherited Draw` (or
its children never repaint on a full redraw).** `TGroup.Draw`'s entire body
is `If Buffer=Nil then DrawSubViews(First, nil) else WriteBuf(...)` -
`Buffer` is never allocated anywhere in this FV build (grepped `views.pas`
for every assignment to it; none exist outside the field declaration), so
in practice that's always `DrawSubViews(First, nil)`, i.e. "paint my
children." `DrawSubViews` itself is `private` to `views.pas`, so a
subclass can't call it directly from another unit - `inherited Draw` is
the only reachable way to invoke it. A hand-written `Draw` override that
paints its own background/content and returns without calling `inherited`
skips that entirely: the override still runs correctly whenever the parent
itself needs a full repaint, but every child view sitting inside it goes
un-repainted, since a child's own `Draw` is only invoked when something
targets that specific child (a click on it, its own state change) - never
as a side effect of the parent's Draw. Symptom: children only appear
piecemeal, as each one gets individually interacted with, and can vanish
again the next time anything forces the parent to redraw as a whole (a
dismissed dialog re-exposing the area, a focus change elsewhere causing a
wider redraw, etc.) - see tui.md's session note on `TDysEffectsContent`.
Order matters when fixing this: paint the background *first*, then call
`inherited Draw` - the reverse order lets the background wipe the children
right back out.

**`Drivers.mbRightButton`/`mbMiddleButton` are swapped versus what a real
xterm right-click actually sends, on this FPC RTL's Unix driver.**
`packages/rtl-console/src/unix/keyboard.pp`'s own xterm decoders
(`GenMouseEvent`, legacy X10 protocol, and `GenMouseEvent_ExtendedSGR1006`,
the modern SGR1006 protocol - checked both, they agree) map "right button
pressed" (`buttonval and 67 = 2`) to bit value 4, which is `Drivers.
mbMiddleButton`'s bit - `Drivers.mbRightButton` ($02) is actually the bit a
real *middle*-click sends there. `Drivers.pas`'s naming follows the classic
DOS/Borland convention (button 2 = right); the Unix driver's mapping follows
X11's own button numbering (0=left, 1=middle, 2=right) applied as a raw bit
shift instead. Net effect: `Event.Buttons and mbRightButton <> 0` can never
match an actual right-click on this driver - checked and fixed in Dysnomia
(see tui.md's session note on the bottom-pane/track-pane/timeline dropdown).
Same driver serves Darwin, so this isn't Linux-specific and any future
right-click check anywhere in this codebase should test `mbMiddleButton`
(or a locally-named alias of it), not `mbRightButton`.

**`kbCtrlEnter` is a real `Drivers.pas` constant that no Unix terminal can
ever actually produce.** Same root cause as the Ctrl+I/Shift+Enter/
Ctrl+Shift+S cases in tui.md's Bindings section: Enter's byte is CR
(`$0D`), already below `$20`, so Ctrl-masking changes nothing about it, and
`keyboard.pp`'s escape-sequence tree (`roottree`/`AddSpecialSequence` - what
a Ctrl+<non-letter> chord needs to be reachable at all) has no entry for it
- confirmed by grepping the file for the string with zero hits. A constant
existing in `Drivers.pas` is not evidence a real terminal can generate it;
check the driver's own sequence table (or the raw-byte case for a
Ctrl+<letter>) before relying on any KeyCode this framework predefines.

**A selectable `ofTopSelect` view without `ofFirstClick` eats its own
focusing click.** `TView.HandleEvent`'s generic mouse-down handling
(`views.pas`):

```pascal
If (Event.What = evMouseDown) Then
  If (State AND (sfSelected OR sfDisabled) = 0)
    AND (Options AND ofSelectable <> 0) Then
    If (Focus = False) OR (Options AND ofFirstClick = 0)
      Then ClearEvent(Event);
```

reads as: on a mouse-down that also happens to focus an unfocused
selectable view, `ClearEvent` it (swallow it) *unless* `ofFirstClick` is
set - the classic Turbo-Vision "click once just to wake the window, click
again to actually do anything" behavior. This runs as part of `Inherited
HandleEvent` at the top of `TGroup.HandleEvent`/`TWindow.HandleEvent`, so
it applies to the view *receiving the click*, not just leaf controls - a
`TWindow`-descendant dock (`ofSelectable` by inheritance) that never
explicitly sets `ofFirstClick` on itself will always eat its own first
click this way, even though the click DID succeed at focusing it. In a
single-window app with several docked panes (see Dysnomia's `TDysPane`)
this means switching to any unfocused pane by mouse always costs a
throwaway click before a second click lands on anything inside it - easy
to miss if Tab/Shift+Tab is the usual way to move focus, but reads as "the
mouse doesn't work" once mouse-driven pane-switching actually gets used.
Fix: set `ofFirstClick` on whatever level's `Options` actually receives
`ofSelectable` (here, the pane base class, in its own `InitPane`/`Init`) -
not on its children, since the swallow happens at the level that
`Focus`-succeeds, which is the outermost still-unfocused selectable
ancestor of whatever got clicked.

**LazUtils is not LCL - `build-dysnomia.sh` now adds its source dir to the
unit path.** `src/project/ProjectFile.pas` (Eris source, untouched) uses
`FileUtil.DeleteDirectory`; `FileUtil` lives in the `lazutils` Lazarus
package, not in `packages/fv/src` or the plain FPC RTL. Checked
`fileutil.pas`'s own `uses` before adding the path: `Classes, SysUtils,
StrUtils, Masks, LazUTF8, LazFileUtils` - no `Forms`, no `Graphics`, no
widgetset unit anywhere in what it or its dependencies pull in. LazUtils
is what `lazbuild` itself is built on, deliberately kept independent of
any widgetset so command-line Lazarus tooling doesn't need one either -
so pulling it into Dysnomia doesn't reopen the door the Isolation rule
closes (`src/ui`, `src/themeengine`), it's a different, LCL-free door.
`LAZUTILSDIR` in `build-dysnomia.sh` points straight at
`lazarus/components/lazutils` source (no precompiled `.ppu` needed/used -
plain `fpc` compiles whatever of it `ProjectFile.pas` actually reaches,
same as any other `-Fu` source path in this project).

---

## Free Vision API Reference

### Core Classes: Base View System

#### TView (ancestor of all views)
Main properties and fields:
- `GrowMode: Byte` - how view resizes with parent (gfGrowLoX, gfGrowHiX, gfGrowLoY, gfGrowHiY, gfGrowAll, gfGrowRel)
- `DragMode: Byte` - dragging behavior (dmDragMove, dmDragGrow, dmLimitLoX/Y/HiX/Y, dmLimitAll)
- `TabMask: Byte` - tab movement behavior (tmTab, tmShiftTab, tmEnter, tmLeft, tmRight, tmUp, tmDown)
- `ColourOfs: Sw_Integer` - palette offset
- `HelpCtx: Word` - help context
- `State: Word` - state flags (sfVisible, sfCursorVis, sfCursorIns, sfShadow, sfActive, sfSelected, sfFocused, sfDragging, sfDisabled, sfModal, sfDefault, sfExposed, sfIconised)
- `Options: Word` - option flags (ofSelectable, ofTopSelect, ofFirstClick, ofFramed, ofPreProcess, ofPostProcess, ofBuffered, ofTileable, ofCenterX, ofCenterY, ofCentered, ofValidate)
- `EventMask: Word` - which events to receive
- `Origin: TPoint` - view position
- `Size: TPoint` - view dimensions
- `Cursor: TPoint` - cursor position within view
- `Next: PView` - linked list pointer to next peer view
- `Owner: PGroup` - owning group/parent
- `HoldLimit: PComplexArea` - drag limit areas
- `RevCol: Boolean` - reverse colors
- `BackgroundChar: Char` - background fill character

Key methods:
- `CONSTRUCTOR Init(Var Bounds: TRect)` - initialize with rectangle
- `DESTRUCTOR Done; Virtual` - cleanup
- `FUNCTION Execute: Word; Virtual` - modal execution (returns command code)
- `FUNCTION Focus: Boolean` - request focus
- `FUNCTION GetPalette: PPalette; Virtual` - get color palette
- `FUNCTION GetColor(Color: Word): Word` - resolve color index to attribute
- `FUNCTION Valid(Command: Word): Boolean; Virtual` - validate command handling
- `FUNCTION GetState(AState: Word): Boolean` - check if state flag set
- `PROCEDURE Draw; Virtual` - render view
- `PROCEDURE HandleEvent(Var Event: TEvent); Virtual` - process events (evMouseDown, evMouseUp, evMouseMove, evKeyDown, evCommand, evBroadcast)
- `PROCEDURE SetState(AState: Word; Enable: Boolean); Virtual` - set/clear state flag
- `PROCEDURE SetBounds(Var Bounds: TRect)` - change position/size
- `PROCEDURE GetBounds(Var Bounds: TRect)` - query position/size
- `PROCEDURE MoveTo(X, Y: Sw_Integer)` - move view
- `PROCEDURE GrowTo(X, Y: Sw_Integer)` - resize view
- `PROCEDURE DragView(Event: TEvent; Mode: Byte; Var Limits: TRect; MinSize, MaxSize: TPoint)` - interactive dragging
- `PROCEDURE EndModal(Command: Word); Virtual` - terminate modal execution
- `PROCEDURE GetData(Var Rec); Virtual` - retrieve view data
- `PROCEDURE SetData(Var Rec); Virtual` - set view data
- `PROCEDURE SelectAll(Enable: Boolean)` - select all content
- `FUNCTION MouseInView(Point: TPoint): Boolean` - test point containment
- `FUNCTION EventAvail: Boolean` - check pending events
- `PROCEDURE Hide; PROCEDURE Show` - visibility control
- `PROCEDURE Select` - make view selected
- `PROCEDURE MakeFirst` - move to top of drawing order
- `PROCEDURE PutInFrontOf(Target: PView)` - z-order manipulation

#### TGroup (container of views)
Inherits from TView. Organizes child views in a linked list.
- `Phase: (phFocused, phPreProcess, phPostProcess)` - event processing phase
- `EndState: Word` - modal result
- `Current: PView` - focused/selected child
- `Last: PView` - first inserted child
- `Buffer: PVideoBuf` - optional redraw buffer

Key methods:
- `CONSTRUCTOR Init(Var Bounds: TRect)`
- `FUNCTION First: PView` - get first child
- `FUNCTION ExecView(P: PView): Word; Virtual` - execute child as modal
- `FUNCTION FirstThat(P: CodePointer): PView` - find first matching child
- `FUNCTION FocusNext(Forwards: Boolean): Boolean` - move focus between children
- `PROCEDURE Insert(P: PView)` - add child at end
- `PROCEDURE Delete(P: PView)` - remove and delete child
- `PROCEDURE InsertBefore(P, Target: PView)` - insert before target
- `PROCEDURE SelectNext(Forwards: Boolean)` - navigate focus
- `PROCEDURE Lock; PROCEDURE UnLock` - redraw buffering control
- `PROCEDURE ReDraw` - force complete redraw
- `PROCEDURE SelectDefaultView` - activate default child
- `PROCEDURE ForEach(P: CodePointer)` - apply callback to all children
- `FUNCTION ClipChilds: boolean; virtual` - whether to clip children to bounds
- `procedure BeforeInsert(P: PView); virtual` - hook before insert
- `procedure AfterInsert(P: PView); virtual` - hook after insert
- `procedure BeforeDelete(P: PView); virtual` - hook before delete
- `procedure AfterDelete(P: PView); virtual` - hook after delete

#### TFrame (decorative border)
Inherits from TView. Draws a frame line.
- `CONSTRUCTOR Init(Var Bounds: TRect)`
- `FUNCTION GetPalette: PPalette; Virtual` - uses CFrame palette
- `procedure Draw; virtual`
- `procedure HandleEvent(var Event: TEvent); virtual`

#### TWindow (framed container)
Inherits from TGroup. Top-level window with title, frame, and standard controls.
- `Flags: Byte` - window flags (wfMove, wfGrow, wfClose, wfZoom)
- `Number: Sw_Integer` - window number (wnNoNumber = unmanaged)
- `Palette: Sw_Integer` - palette choice (wpBlueWindow, wpCyanWindow, wpGrayWindow)
- `ZoomRect: TRect` - pre-zoom bounds
- `Frame: PFrame` - frame object
- `Title: PString` - title string

Key methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; ATitle: TTitleStr; ANumber: Sw_Integer)`
- `FUNCTION GetPalette: PPalette; Virtual`
- `FUNCTION GetTitle(MaxSize: Sw_Integer): TTitleStr; Virtual`
- `FUNCTION StandardScrollBar(AOptions: Word): PScrollBar` - factory for scrollbars
- `PROCEDURE Zoom; Virtual` - toggle zoom state
- `PROCEDURE Close; Virtual` - close window
- `PROCEDURE InitFrame; Virtual` - create frame
- `PROCEDURE SizeLimits(Var Min, Max: TPoint); Virtual` - enforce size constraints

---

### Control Types

#### TButton
Inherits from TView. Clickable button with command dispatch.
- `AmDefault: Boolean` - is default button (drawn with extra border)
- `Flags: Byte` - button flags (bfNormal, bfDefault, bfLeftJust, bfBroadcast, bfGrabFocus)
- `Command: Word` - command sent when pressed
- `Title: PString` - button text

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; ATitle: TTitleStr; ACommand: Word; AFlags: Word)`
- `FUNCTION GetPalette: PPalette; Virtual` - uses CButton palette
- `PROCEDURE Press; Virtual` - simulate button press (sends evCommand)
- `PROCEDURE Draw; Virtual`
- `PROCEDURE DrawState(Down: Boolean)` - draw pressed/unpressed
- `PROCEDURE MakeDefault(Enable: Boolean)` - toggle default appearance

#### TInputLine
Inherits from TView. Single-line text input with editing.
- `MaxLen: Sw_Integer` - maximum input length
- `CurPos: Sw_Integer` - cursor position
- `FirstPos: Sw_Integer` - first visible character
- `SelStart, SelEnd: Sw_Integer` - selection range
- `Data: PString` - input text
- `Validator: PValidator` - optional input validator

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; AMaxLen: Sw_Integer)`
- `FUNCTION Valid(Command: Word): Boolean; Virtual` - validate input
- `FUNCTION GetPalette: PPalette; Virtual` - uses CInputLine palette
- `PROCEDURE Draw; Virtual`
- `PROCEDURE DrawCursor; Virtual`
- `PROCEDURE SelectAll(Enable: Boolean)` - select/deselect all text
- `PROCEDURE SetValidator(AValid: PValidator)` - assign validator
- `PROCEDURE GetData(Var Rec); PROCEDURE SetData(Var Rec); Virtual` - get/set string

#### TCluster (base for radio buttons, checkboxes)
Inherits from TView. Groups of selectable items (radio buttons or checkboxes).
- `Id: Sw_Integer` - cluster id for messaging
- `Sel: Sw_Integer` - selected item index
- `Value: LongInt` - bit value representing selection
- `EnableMask: LongInt` - which items are enabled
- `Strings: TStringCollection` - list of option strings

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; AStrings: PSItem)` - PSItem is linked list of items
- `FUNCTION Mark(Item: Sw_Integer): Boolean; Virtual` - is item marked
- `FUNCTION ButtonState(Item: Sw_Integer): Boolean` - is button enabled
- `PROCEDURE Press(Item: Sw_Integer); Virtual` - handle item click
- `PROCEDURE MovedTo(Item: Sw_Integer); Virtual` - handle item focus
- `PROCEDURE Draw; Virtual`
- `PROCEDURE DrawBox(Const Icon: String; Marker: Char)` - draw checkbox/radio
- `PROCEDURE SetButtonState(AMask: Longint; Enable: Boolean)` - enable/disable items
- `PROCEDURE GetData(Var Rec); PROCEDURE SetData(Var Rec); Virtual` - get/set selected value

#### TRadioButtons
Inherits from TCluster. Mutually exclusive selection (exactly one selected).
- Only one item can be marked at a time
- `Press()` and `MovedTo()` ensure only one selection

#### TCheckBoxes
Inherits from TCluster. Independent boolean selections (0 or more selected).
- Each bit in `Value` represents one checkbox

#### TListBox
Inherits from TListViewer. Displays scrollable list of selectable strings.
- `List: PCollection` - collection of strings
- Manages selection and focused item

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; ANumCols: Sw_Word; AScrollBar: PScrollBar)`
- `FUNCTION GetText(Item: Sw_Integer; MaxLen: Sw_Integer): String; Virtual` - get item text
- `PROCEDURE NewList(AList: PCollection); Virtual` - set collection
- `procedure Insert(Item: Pointer); virtual` - add item to list
- `procedure DeleteItem(Item: Sw_Integer); virtual` - remove item
- `procedure DeleteFocusedItem; virtual` - delete selected item
- `procedure FreeAll; virtual` - clear and dispose all
- `function GetFocusedItem: Pointer; virtual` - get selected item

#### TStaticText
Inherits from TView. Read-only text display.
- `Text: PString` - text content

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; Const AText: String)`
- `PROCEDURE Draw; Virtual`
- `PROCEDURE GetText(Var S: String); Virtual`
- `FUNCTION GetPalette: PPalette; Virtual` - uses CStaticText palette

#### TLabel
Inherits from TStaticText. Labels that can highlight linked controls.
- `Light: Boolean` - highlight state
- `Link: PView` - linked view (often TInputLine)

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; CONST AText: String; ALink: PView)`
- `PROCEDURE Draw; Virtual` - draws text + underlines shortcut
- Uses CLabel palette

#### TScrollBar
Inherits from TView. Vertical or horizontal scroll control.
- `Value: Sw_Integer` - current position
- `Min, Max: Sw_Integer` - range
- `PgStep: Sw_Integer` - page scroll amount
- `ArStep: Sw_Integer` - arrow scroll amount
- `Id: Sw_Integer` - scrollbar id

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect)`
- `FUNCTION ScrollStep(Part: Sw_Integer): Sw_Integer; Virtual` - delta for part clicked
- `FUNCTION GetPalette: PPalette; Virtual` - uses CScrollBar palette
- `PROCEDURE Draw; Virtual`
- `PROCEDURE SetValue(AValue: Sw_Integer)` - set position
- `PROCEDURE SetRange(AMin, AMax: Sw_Integer)` - set range
- `PROCEDURE SetStep(APgStep, AArStep: Sw_Integer)` - set scroll steps
- `PROCEDURE HandleEvent(Var Event: TEvent); Virtual` - respond to clicks/keys

Parts for ScrollStep:
- sbLeftArrow (0), sbRightArrow (1), sbPageLeft (2), sbPageRight (3)
- sbUpArrow (4), sbDownArrow (5), sbPageUp (6), sbPageDown (7), sbIndicator (8)

#### TScroller
Inherits from TView. View with scrollbars for panning content.
- `Delta: TPoint` - current scroll position
- `Limit: TPoint` - maximum scrollable area
- `HScrollBar, VScrollBar: PScrollBar` - scrollbar references

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; AHScrollBar, AVScrollBar: PScrollBar)`
- `PROCEDURE ScrollDraw; Virtual` - redraw scrollable content
- `PROCEDURE SetLimit(X, Y: Sw_Integer)` - set content size
- `PROCEDURE ScrollTo(X, Y: Sw_Integer)` - scroll to position
- `FUNCTION GetPalette: PPalette; Virtual` - uses CScroller palette

#### TListViewer
Inherits from TView. Abstract list display with scrolling.
- `NumCols: Sw_Integer` - number of columns
- `TopItem, Focused: Sw_Integer` - visible and selected item indices
- `Range: Sw_Integer` - total number of items
- `HScrollBar, VScrollBar: PScrollBar` - attached scrollbars

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; ANumCols: Sw_Word; AHScrollBar, AVScrollBar: PScrollBar)`
- `FUNCTION IsSelected(Item: Sw_Integer): Boolean; Virtual` - is item selected
- `FUNCTION GetText(Item: Sw_Integer; MaxLen: Sw_Integer): String; Virtual` - item text (override)
- `PROCEDURE Draw; Virtual`
- `PROCEDURE FocusItem(Item: Sw_Integer); Virtual` - select item
- `PROCEDURE SetTopItem(Item: Sw_Integer)` - scroll to show item
- `PROCEDURE SelectItem(Item: Sw_Integer); Virtual` - select item

---

### Application Framework Classes

#### TApplication
Inherits from TProgram. Main application object managing windows and events.
- Manages desktop, menu bar, status line
- Processes application-level commands
- Handles idle time

Methods:
- `CONSTRUCTOR Init` - initialize with screen
- `DESTRUCTOR Done; Virtual` - cleanup
- `PROCEDURE Run; Virtual` - main event loop
- `PROCEDURE Idle; Virtual` - called when no events pending
- `PROCEDURE HandleEvent(Var Event: TEvent); Virtual` - process events
- `PROCEDURE Tile` - tile windows on desktop
- `PROCEDURE Cascade` - cascade windows
- `PROCEDURE DosShell` - spawn shell
- `FUNCTION InsertWindow(P: PWindow): PWindow` - add window to desktop
- `FUNCTION ExecuteDialog(P: PDialog; Data: Pointer): Word` - run modal dialog

#### TDeskTop
Inherits from TGroup. Container managing multiple windows.
- `Background: PBackground` - optional background view
- `TileColumnsFirst: Boolean` - tiling direction

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect)`
- `PROCEDURE Tile(Var R: TRect)` - arrange windows in grid
- `PROCEDURE Cascade(Var R: TRect)` - cascade window positions
- `PROCEDURE TileError; Virtual` - called on tiling error
- `PROCEDURE InitBackGround; Virtual` - create background

#### TDialog
Inherits from TWindow. Modal dialog container with standard buttons/fields.
- Inherits standard window frame and title
- Manages child control layout

Methods:
- `CONSTRUCTOR Init(var Bounds: TRect; ATitle: TTitleStr)`
- `FUNCTION Valid(Command: Word): Boolean; virtual` - validate all children before close
- `FUNCTION NewButton(...): PButton` - factory for standard button
- `FUNCTION NewInputLine(...): PInputLine` - factory for input line
- `FUNCTION NewLabel(...): PLabel` - factory for label
- `PROCEDURE Cancel(ACommand: Word); virtual` - cancel dialog
- `PROCEDURE ChangeTitle(ANewTitle: TTitleStr); virtual` - update title
- `PROCEDURE FreeSubView(ASubView: PView); virtual` - remove child
- `FUNCTION IsSubView(AView: PView): Boolean; virtual` - test child ownership

#### TBackGround
Inherits from TView. Fills view area with repeating character pattern.
- `Pattern: Char` - fill character (usually space or CP437 block char)

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; APattern: Char)`
- `PROCEDURE Draw; Virtual` - fill with pattern
- Uses CBackGround palette

---

### Menu System Classes

#### TMenuView (abstract menu base)
Inherits from TView. Base for menu bars and popup menus.
- `ParentMenu: PMenuView` - submenu parent
- `Menu: PMenu` - menu structure (TMenu record)
- `Current: PMenuItem` - currently highlighted item
- `OldItem: PMenuItem` - previous item (for redraw optimization)

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect)`
- `FUNCTION Execute: Word; Virtual` - run menu and return command
- `FUNCTION GetHelpCtx: Word; Virtual` - get help context
- `FUNCTION GetPalette: PPalette; Virtual` - uses CMenuView palette
- `FUNCTION FindItem(Ch: Char): PMenuItem` - find by letter
- `FUNCTION HotKey(KeyCode: Word): PMenuItem` - find by key
- `FUNCTION NewSubView(Var Bounds: TRect; AMenu: PMenu; AParentMenu: PMenuView): PMenuView; Virtual` - factory for submenu view
- `PROCEDURE HandleEvent(Var Event: TEvent); Virtual` - process keys/mouse
- `PROCEDURE GetItemRect(Item: PMenuItem; Var R: TRect); Virtual` - item position

#### TMenuBar
Inherits from TMenuView. Horizontal menu bar at top.
- `CONSTRUCTOR Init(Var Bounds: TRect; AMenu: PMenu)`
- `PROCEDURE Draw; Virtual` - draws horizontal items

#### TMenuBox
Inherits from TMenuView. Vertical popup menu.
- `CONSTRUCTOR Init(Var Bounds: TRect; AMenu: PMenu; AParentMenu: PMenuView)`
- `PROCEDURE Draw; Virtual` - draws framed vertical list

#### TMenuPopup
Inherits from TMenuBox. Non-modal popup menu.
- `CONSTRUCTOR Init(Var Bounds: TRect; AMenu: PMenu)`

#### TStatusLine
Inherits from TView. Status bar showing keyboard hints.
- `Items: PStatusItem` - current items to display
- `Defs: PStatusDef` - status definitions by help context

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect; ADefs: PStatusDef)`
- `FUNCTION GetPalette: PPalette; Virtual` - uses CStatusLine palette
- `FUNCTION Hint(AHelpCtx: Word): String; Virtual` - get hint text for context
- `PROCEDURE Draw; Virtual` - display current items
- `PROCEDURE Update; Virtual` - update for new context
- `PROCEDURE HandleEvent(Var Event: TEvent); Virtual` - respond to commands

---

### Utility Controls

#### THeapView (gadgets.pas)
Inherits from TView. Displays available heap memory.
- `Mode: THeapViewMode` - display format (HVNormal, HVComma, HVKb, HVMb)
- `OldMem: LongInt` - previous memory value
- Updates automatically when memory changes

Methods:
- `constructor Init(var Bounds: TRect)` - normal decimal format
- `constructor InitComma(var Bounds: TRect)` - with thousands separators
- `constructor InitKb(var Bounds: TRect)` - kilobytes
- `constructor InitMb(var Bounds: TRect)` - megabytes
- `PROCEDURE Update` - check memory and redraw if changed
- `PROCEDURE Draw; Virtual`

#### TClockView (gadgets.pas)
Inherits from TView. Displays current system time with auto-refresh.
- `LastTime: Longint` - last displayed time
- `Refresh: Byte` - refresh rate
- `TimeStr: String[10]` - formatted time

Methods:
- `CONSTRUCTOR Init(Var Bounds: TRect)`
- `FUNCTION FormatTimeStr(H, M, S: Word): String; Virtual` - custom format (override)
- `PROCEDURE Update; Virtual` - check time and redraw
- `PROCEDURE Draw; Virtual`

#### TColoredText (colortxt.pas)
Inherits from TStaticText. Displays text with explicit color attribute.
- `Attr: Byte` - color attribute

Methods:
- `constructor Init(var Bounds: TRect; const AText: String; Attribute: Byte)`
- `function GetTheColor: byte; virtual` - resolve color (respects AppPalette)
- `PROCEDURE Draw; Virtual`

---

### Event System

#### TEvent Record
Union-based event record with multiple payload types:

Fields common to all:
- `What: Sw_Word` - event type (evNothing, evMouse, evKeyDown, evCommand, evBroadcast)

Mouse event fields (What = evMouseDown/Up/Move/Auto):
- `Buttons: Byte` - buttons pressed (mbLeftButton, mbRightButton, mbMiddleButton, mbScrollWheelUp/Down)
- `Double: Boolean` - double-click flag
- `Where: TPoint` - mouse position

Keyboard event fields (What = evKeyDown):
- `KeyCode: Word` - full extended key code
- `CharCode: Char` - ASCII character
- `ScanCode: Byte` - keyboard scan code
- `KeyShift: Byte` - shift state (kbLeftShift, kbRightShift, kbCtrlShift, kbAltShift, kbCapsState, kbNumState, kbScrollState, kbInsState)

Message event fields (What = evCommand/evBroadcast):
- `Command: Sw_Word` - command code
- `Id: Sw_Word` - sender/target id
- `Data: Real` - numeric data
- `InfoPtr: Pointer` - or InfoLong/InfoWord/InfoInt/InfoByte/InfoChar - data payload

#### Event Processing Flow
1. TApplication.Run() calls GetEvent() in loop
2. Events dispatched through view hierarchy via HandleEvent()
3. Views can consume (clear) events or pass up to owner
4. Commands propagate to focused view and up the hierarchy
5. Broadcast events go to all views in group

#### Event Types and Masks
- `evNothing = $0000` - no event
- `evMouseDown = $0001`, evMouseUp = $0002`, evMouseMove = $0004`, evMouseAuto = $0008` - mouse events
- `evKeyDown = $0010` - keyboard input
- `evCommand = $0100` - command/button press
- `evBroadcast = $0200` - broadcast to all views
- `evMouse = $000F` - any mouse event mask
- `evKeyboard = $0010` - any keyboard event mask

#### Standard Command Codes (views.pas)
- `cmQuit = 1` - application quit
- `cmMenu = 3` - menu activated
- `cmClose = 4` - close window
- `cmZoom = 5` - zoom window
- `cmNext = 7` - next window
- `cmPrev = 8` - previous window
- `cmHelp = 9` - help request
- `cmOK = 10, cmCancel = 11, cmYes = 12, cmNo = 13` - dialog responses
- `cmCut = 20, cmCopy = 21, cmPaste = 22, cmUndo = 23` - clipboard
- `cmTile = 25, cmCascade = 26` - window management
- `cmReceivedFocus = 50, cmReleasedFocus = 51` - focus change
- `cmScrollBarChanged = 53, cmScrollBarClicked = 54` - scrollbar notifications
- `cmListItemSelected = 56` - list selection

#### Application Command Codes (app.pas)
- `cmNew = 30, cmOpen = 31, cmSave = 32, cmSaveAs = 33, cmSaveAll = 34` - file operations
- `cmChangeDir = 35, cmDosShell = 36, cmCloseAll = 37` - miscellaneous

---

### Color and Palette System

#### Palette Concept
Colors in Free Vision use an indirect palette system. Views return a TPalette (String of characters), where each character is an index into the application's global color table. This allows:
- Runtime palette switching (color/BW/monochrome)
- Consistent theming across all controls
- Easy text attribute overrides

#### GetPalette() Return Values
Each control class defines its palette with standard palette indices:

Core view palettes:
- `CFrame = #1#1#2#2#3` - frame (border, active, focus variations)
- `CScrollBar = #4#5#5` - scrollbar (parts)
- `CScroller = #6#7` - scroller background
- `CListViewer = #26#26#27#28#29` - list (normal, focused, selected, divider)

Window palettes (by wpXXX flag):
- `CBlueWindow = #8..#15` (8 entries)
- `CCyanWindow = #16..#23` (8 entries)
- `CGrayWindow = #24..#31` (8 entries)

Dialog control palettes:
- `CStaticText = #6#7#8#9`
- `CLabel = #7#8#9#9`
- `CButton = #10#11#12#13#14#14#14#15` - (normal, default, selected, disabled, shortcut, shadow)
- `CCluster = #16#17#18#18#31#6` - radio/checkbox
- `CInputLine = #19#19#20#21#14` - text input
- `CListBox = #26#27#28#29` - list items

#### GetColor(Index: Word) Implementation
Maps palette index to actual video attribute byte:
```
Index = GetPalette()[PaletteIndex];
Result = ColorTable[Index];
```

Application has three color modes (app.pas):
- `CColor` - full color palette (48 bytes)
- `CBlackWhite` - B&W palette
- `CMonochrome` - monochrome palette

#### MapColor(color: byte): byte
View method to remap colors, used by derived classes for customization.

---

### Additional Core Classes

#### TInterior (views.pas)
Inherits from TView. Provides basic grouped content without window chrome.
- `CONSTRUCTOR Init(Var Bounds: TRect)`
- `FUNCTION GetPalette: PPalette; Virtual`
- Core view without frame or window title

#### TSizeableWindow (views.pas)
Window with size limit constraints enforced via virtual SizeLimits method.
- `PROCEDURE SizeLimits(Var Min, Max: TPoint); Virtual` - override to enforce bounds
- Automatically constrains window resize operations to limits defined

#### TEditor (editors.pas)
Advanced multi-line text editor with line/block operations.
- `FileName: String` - associated file path
- `Modified: Boolean` - unsaved changes flag
- `CurPtr: Word` - cursor position in buffer
- `CurLine: Longint` - current line number
- `TopLine: Longint` - first visible line
- Methods for line insertion, deletion, search/replace operations
- Full clipboard integration (cut/copy/paste blocks)

---

### Advanced Stream I/O and Persistence

#### TStream (memory.pas)
Base stream class for serializing Free Vision objects.

Key methods:
- `CONSTRUCTOR Init(InitSize: Sw_Word; Duplicated: Boolean)`
- `FUNCTION GetPos: Longint` - current stream position
- `FUNCTION GetSize: Longint` - stream byte count
- `PROCEDURE Read(Var Buf; Count: Word)` - read bytes
- `PROCEDURE Write(Var Buf; Count: Word)` - write bytes
- `PROCEDURE Seek(Pos: Longint)` - jump to position
- `PROCEDURE Reset` - clear stream, rewind to 0
- `PROCEDURE Truncate` - resize to current position
- `FUNCTION ReadStr: PString` - read heap-allocated string
- `PROCEDURE WriteStr(P: PString)` - write heap string with length prefix
- `FUNCTION ReadWord: Word; FUNCTION WriteWord(W: Word)`
- `FUNCTION ReadLong: Longint; PROCEDURE WriteLong(L: Longint)`

#### RegisterView() / Stream Registration
Dynamically register custom view classes for streaming:
```
TYPE TStreamRec = RECORD
  ObjType: Word;     // Unique ID (idXXX constant)
  VmtLink: Pointer;  // TypeOf(TMyView)
  Load: Pointer;     // @TMyView.Load
  Store: Pointer;    // @TMyView.Store
END;
```

#### Load/Store Virtual Methods
```
CONSTRUCTOR MyView.Load(Var S: TStream); Virtual;
PROCEDURE MyView.Store(Var S: TStream); Virtual;
```
- Always call parent's Load/Store first to preserve base state
- Use S.ReadStr/WriteStr for heap strings
- Use GetSubViewPtr/PutSubViewPtr for child view pointers
- Manual Read/Write for custom fields

---

### Text Output and Drawing Primitives

#### TDrawBuffer and Screen Writing
Free Vision's text output uses character/attribute pairs:

Methods:
- `PROCEDURE WriteStr(X, Y: Sw_Integer; Str: String; Color: Byte)` - write colored string
- `PROCEDURE WriteChar(X, Y: Sw_Integer; C: Char; Color: Byte; Count: Word)` - repeat char
- `PROCEDURE WriteLine(X, Y, W, H: Sw_Integer; Var Buf)` - write raw buffer region
- `PROCEDURE WriteBuf(X, Y, W, H: Sw_Integer; Var Buf)` - write with optional clip

Helper functions:
- `FUNCTION TextWidth(Const Txt: String): Sw_Integer` - unformatted string width
- `FUNCTION CTextWidth(Const Txt: String): Sw_Integer` - width accounting for ~ shortcut skip
- Used to measure button/label text before layout

#### MoveStr / MoveChar (fvcommon.pas)
Buffer manipulation helpers (write to memory buffer, not screen directly):
- `PROCEDURE MoveStr(Var Buf, S: String; Attr: Byte; var Indent: Integer)` - fill buffer with string
- `PROCEDURE MoveChar(Var Buf: TDrawBuffer; C: Char; Attr: Byte; Len: Sw_Integer)` - fill N cells
- `FUNCTION StrLen(Const S: String): Sw_Integer` - account for ~ shortcut character

#### Cursor Control
- `PROCEDURE ShowCursor; PROCEDURE HideCursor` - manage cursor visibility
- `PROCEDURE BlockCursor; PROCEDURE NormalCursor` - cursor shape (block vs underline)
- `PROCEDURE DrawCursor; Virtual` - redraw cursor in view
- `PROCEDURE ResetCursor; Virtual` - reset to default state after event

---

### Input Validation

#### Validator Classes (validate.pas)
Base class: `TValidator` - override Valid() to implement custom validation.

Standard validators:
- `TRangeValidator` - numeric range (0-99)
  - `CONSTRUCTOR Init(AMin, AMax: Longint)`
  - Valid if value within [AMin, AMax]

- `TFilterValidator` - character filtering
  - `CONSTRUCTOR Init(AValidChars: String)`
  - Valid if all characters in AValidChars

- `TPictureValidator` - format pattern matching
  - `CONSTRUCTOR Init(APicture: String)`
  - Picture syntax: # = digit, ? = letter, ~ = alphanumeric

Custom validators override:
```
FUNCTION Valid(S: String): Boolean; Virtual;
FUNCTION Error: String; Virtual;  // Error message
```

#### Validator Usage
- Assign to TInputLine via `SetValidator(V: PValidator)`
- With `Options := Options or ofValidate` flag set, called before accepting input
- Return false to reject, optionally display error via Message()

---

### Message Routing and Commands

#### Message() Function
Route commands and events between views:

```
FUNCTION Message(Receiver: PView; What, Command: Word; 
                 InfoPtr: Pointer): Word;
```

- `What`: event type (evCommand, evBroadcast, evMouseDown, etc.)
- `Command`: command code (cmOK, cmYes, cmClose, etc.)
- `InfoPtr`: optional data payload (button pointer, etc.)
- Returns: result from receiver's HandleEvent
- Delivers synchronously (blocks until handled)

#### Event Masking
Views filter events via `EventMask: Word` field:
- `evNothing = $0000` - ignore all
- `evMouse = $000F` - any mouse event
- `evKeyboard = $0010` - keyboard only
- `evCommand = $0100` - command messages
- `evAll = $FFFF` - accept everything

#### Command Enable/Disable
- `FUNCTION CommandEnabled(Command: Word): Boolean`
- `PROCEDURE EnableCommands(Commands: TCommandSet)` - bitset of cmXXX codes
- `PROCEDURE DisableCommands(Commands: TCommandSet)`
- `PROCEDURE SetCmdState(Commands: TCommandSet; Enable: Boolean)`

---

### Utility Functions (fvcommon.pas)

#### String Utilities
- `FUNCTION NewStr(Const S: String): PString` - allocate heap string
- `PROCEDURE DisposeStr(P: PString)` - free heap string
- `FUNCTION UpStr(Const S: String): String` - uppercase
- `FUNCTION StUpStr(S: String): String` - uppercase in-place (modifies parameter)
- `FUNCTION CtrlToArrow(Ch: Char): Char` - map Ctrl+X to arrow equivalent

#### Key Utilities
- `FUNCTION GetAltChar(Ch: Char): Char` - extract ~ underlined letter for Alt+X
- `FUNCTION GetCtrlChar(Ch: Char): Char` - extract ^ underlined letter for Ctrl+X
- `FUNCTION IsPrintable(Ch: Char): Boolean` - non-control character

#### Rect and Point Utilities
- `PROCEDURE Normalize(Var R: TRect)` - ensure A <= B
- `FUNCTION Union(R1, R2: TRect): TRect` - bounding box
- `FUNCTION Intersect(R1, R2: TRect): TRect` - overlap region
- `FUNCTION IntersectRect(Var R: TRect; R1, R2: TRect): Boolean` - overlap with result
- `PROCEDURE OffsetRect(Var R: TRect; Dx, Dy: Integer)` - translate
- `FUNCTION PtInRect(P: TPoint; Const R: TRect): Boolean` - point containment

---

### Standard Dialogs (stddlg.pas)

#### TFileDialog
Full file/directory browser with path navigation:
- `CONSTRUCTOR Init(WildCard, Title, InputName, FkeyWord, HelpCtx: String; Mask: Word)`
- `FileName: String` - selected file on OK
- `Directory: String` - current directory path
- `Mask: Word` - file attributes (faArchive, faReadOnly, faHidden, etc.)
- Supports multi-level directory navigation, pattern filtering
- Returns cmOK/cmCancel on completion

Flags (Mask parameter):
- `faArchive` - show archive files
- `faReadOnly` - show read-only files
- `faHidden` - show hidden files
- `faSysFile` - show system files

#### MessageBox Dialog
```
FUNCTION MessageBox(const Msg: String; const Title: String; 
                    Buttons: Word): Word;
```
Returns one of: `cmYes, cmNo, cmOK, cmCancel`
Button flags: `mfYesNoCancel, mfYesNo, mfOkCancel, mfOkButton`

#### InputBox Dialog
```
FUNCTION InputBox(const Title: String; const APrompt: String; 
                  var Result: String): Word;
```
Single-line prompt dialog, returns cmOK/cmCancel

---

### Desktop and Window Management

#### TProgram (app.pas)
Base class for TApplication. Handles screen initialization and main event loop.
- `PROCEDURE InitScreen` - set up video mode, palette
- `PROCEDURE InitStatusLine` - create status bar
- `PROCEDURE InitMenuBar` - create menu bar (virtual)
- `PROCEDURE InitDesktop` - create desktop and background (virtual)
- `PROCEDURE Run; Virtual` - main event loop, never returns normally
- `PROCEDURE Idle; Virtual` - called when event queue empty
- `PROCEDURE HandleEvent(Var Event: TEvent); Virtual` - process global commands
- `PROCEDURE Shutdown` - cleanup (called on exit)

#### ScreenMode Control (drivers.pas)
Global screen functions:
- `FUNCTION VideoMode: Word` - query current mode
- `PROCEDURE SetMode(Mode: Word)` - set resolution/colors
- `PROCEDURE SetCursorType(CT: Word)` - cursor style (crHiddenCursor, crUnderline, crBlock, crFullBlock)
- `FUNCTION CursorType: Word` - current style
- `PROCEDURE SetCursorPos(X, Y: Word)` - move cursor
- `PROCEDURE GetCursorPos(Var X, Y: Word)` - read cursor position
- `PROCEDURE ClearScreen(Color: Byte)` - fill screen
- `FUNCTION SaveScreen: Pointer` - save screen buffer (malloc)
- `PROCEDURE RestoreScreen(SavePtr: Pointer)` - restore from buffer

---

### Resource Management

#### Memory Utilities
`MemAvail, MaxAvail: Longint` - global memory functions (RTL)
- `THeapView` gadget displays this in status line

#### String Pool (NewStr / DisposeStr)
Free Vision uses pool-allocated strings for efficiency:
```
VAR MyStr: PString;
BEGIN
  MyStr := NewStr('Hello');  // allocate from pool
  // ... use MyStr^
  DisposeStr(MyStr);         // return to pool
END;
```

---

### Collections and Data Structures

#### TCollection (rtl-extra/src/inc/objects.pp)
Generic dynamic array for heap objects:
- `CONSTRUCTOR Init(ALimit, ADelta: Sw_Integer)` - initial size, growth increment
- `PROCEDURE Insert(Item: Pointer)` - append
- `PROCEDURE AtInsert(Index: Sw_Integer; Item: Pointer)` - insert at position
- `PROCEDURE AtDelete(Index: Sw_Integer)` - remove by index
- `PROCEDURE DeleteAll` - clear all items
- `FUNCTION At(Index: Sw_Integer): Pointer` - indexed access
- `FUNCTION Count: Sw_Integer` - item count
- `FUNCTION FirstThat(P: CodePointer): Pointer` - search by predicate
- `PROCEDURE ForEach(P: CodePointer)` - apply to all

Used by TListBox, TDialog for managing list items and controls.

#### TStringCollection
Variant of TCollection specialized for PString pointers.

#### Items and PSItem (menus.pas)
Linked-list menu item structure:
```
TYPE PMenuItem = ^TMenuItem;
     TMenuItem = RECORD
       Next: PMenuItem;
       Name: PString;
       Command: Word;
       KeyCode: Word;
       HelpCtx: Word;
       SubMenu: PMenu;
     END;
```

Menu construction helpers:
- `FUNCTION NewItem(Name: String; Command: Word; KeyCode: Word; HelpCtx: Word; Next: PMenuItem): PMenuItem`
- `FUNCTION NewSubMenu(Name: String; HelpCtx: Word; SubMenu: PMenu; Next: PMenuItem): PMenuItem`
- `FUNCTION NewMenu(Items: PMenuItem): PMenu`
- `PROCEDURE DisposeMenu(M: PMenu)` - free heap-allocated menu structure

---

### Common Patterns

#### Initializing a View Hierarchy
```
// Typical window initialization
var
  R: TRect;
  W: PWindow;
  Btn: PButton;
begin
  R.Assign(10, 5, 60, 15);  // x1, y1, x2, y2
  W := New(PWindow, Init(R, 'Title', 1));  // Window number
  
  // Add controls to window
  Btn := New(PButton, Init(R, '~OK', cmOK, bfDefault));
  W^.Insert(Btn);
  
  // Execute modal
  if Application^.ExecView(W) = cmOK then
    // handle OK
end;
```

#### Event Handling Pattern
```
PROCEDURE TMyView.HandleEvent(Var Event: TEvent);
begin
  case Event.What of
    evMouseDown:
      begin
        // Handle mouse down
        ClearEvent(Event);  // Mark as handled
      end;
    evKeyDown:
      begin
        case Event.KeyCode of
          kbEnter: 
            begin
              Message(Owner, evCommand, cmYes, nil);
              ClearEvent(Event);
            end;
        end;
      end;
  end;
  inherited HandleEvent(Event);  // Let parent handle remainder
end;
```

#### Data Exchange Pattern
```
// Get data from dialog controls
PROCEDURE TMyDialog.GetData(Var Rec);
var
  R: TMyRecord absolute Rec;
begin
  inherited GetData(Rec);  // Let children populate
  // Post-process if needed
end;

// Set data into dialog controls
PROCEDURE TMyDialog.SetData(Var Rec);
var
  R: TMyRecord absolute Rec;
begin
  inherited SetData(Rec);  // Distribute to children
  // Post-process if needed
end;
```

#### Custom Drawing Pattern
```
PROCEDURE TMyView.Draw;
var
  B: TDrawBuffer;
  Color: Byte;
begin
  Color := GetColor(1);  // Get palette index 1
  MoveChar(B, ' ', Color, Size.X);  // Fill buffer
  WriteLine(0, 0, Size.X, Size.Y, B);  // Output
end;
```

#### Scrollbar Integration
```
var
  HScroll, VScroll: PScrollBar;
  MyList: PListViewer;
begin
  HScroll := StandardScrollBar(sbHorizontal);
  VScroll := StandardScrollBar(sbVertical);
  MyList := New(PListViewer, Init(R, 1, HScroll, VScroll));
  Window^.Insert(MyList);
  // Scrollbars auto-linked through shared id
end;
```

#### Validator Usage
```
PROCEDURE SetupValidationField(Input: PInputLine);
var
  V: PValidator;
begin
  V := New(PRangeValidator, Init(0, 99));  // Range 0-99
  Input^.SetValidator(V);
  Input^.Options := Input^.Options or ofValidate;
end;
```

#### Creating Modal Dialogs with Controls
```
TYPE TMyData = RECORD
  Name: String[80];
  Count: Integer;
END;

VAR
  D: TDialog;
  R: TRect;
  NameField: PInputLine;
  CountField: PInputLine;
  OkBtn: PButton;
  Data: TMyData;

BEGIN
  R.Assign(10, 5, 70, 15);
  D := New(PDialog, Init(R, 'Data Entry'));
  
  // Add controls to dialog
  NameField := D^.NewInputLine(R, 'Name: ', 80);
  D^.Insert(NameField);
  
  CountField := D^.NewInputLine(R, 'Count: ', 5);
  D^.Insert(CountField);
  
  OkBtn := D^.NewButton(R, '~OK', cmOK, bfDefault);
  D^.Insert(OkBtn);
  
  // Exchange data
  Data.Name := 'Default';
  Data.Count := 0;
  D^.SetData(Data);
  
  // Execute modal
  if Application^.ExecuteDialog(D, nil) = cmOK then
  BEGIN
    D^.GetData(Data);
    // Use Data.Name, Data.Count
  END;
END;
```

#### Working with List Views and Scrollbars
```
TYPE MyListData = RECORD
  Items: PCollection;
  Selected: Integer;
END;

VAR
  List: PListBox;
  HScroll: PScrollBar;
  VScroll: PScrollBar;
  Window: PWindow;
  R: TRect;
  Data: MyListData;

BEGIN
  // Create window
  R.Assign(5, 3, 75, 20);
  Window := New(PWindow, Init(R, 'List Example', 1));
  
  // Create scrollbars
  HScroll := Window^.StandardScrollBar(sbHorizontal);
  VScroll := Window^.StandardScrollBar(sbVertical);
  
  // Shrink bounds for list (leave room for scrollbars)
  R.Assign(1, 1, Size.X - 2, Size.Y - 2);
  List := New(PListBox, Init(R, 1, HScroll, VScroll));
  
  // Create and populate collection
  New(MyListData.Items, Init(100, 10));  // 100 initial, grow by 10
  MyListData.Items^.Insert(NewStr('Item 1'));
  MyListData.Items^.Insert(NewStr('Item 2'));
  // ...
  
  List^.NewList(MyListData.Items);
  Window^.Insert(List);
  Window^.Insert(HScroll);
  Window^.Insert(VScroll);
  
  // Execute
  if Application^.ExecView(Window) = cmOK then
  BEGIN
    List^.GetData(Data);
    // Data.Selected contains selected item index
  END;
END;
```

#### Key Intercept Pattern for Tab Navigation
```
PROCEDURE TMyPane.HandleEvent(Var Event: TEvent);
BEGIN
  // Intercept Tab before inherited to override default focus cycling
  IF (Event.What = evKeyDown) THEN
  BEGIN
    CASE Event.KeyCode OF
      kbTab:
        BEGIN
          Owner^.SelectNext(True);  // Move to next sibling pane
          IF Owner^.Current <> nil THEN
            Owner^.Current^.Focus;  // Focus the new pane
          ClearEvent(Event);        // Consume the event
        END;
      kbShiftTab:
        BEGIN
          Owner^.SelectNext(False);
          IF Owner^.Current <> nil THEN
            Owner^.Current^.Focus;
          ClearEvent(Event);
        END;
    END;
  END;
  inherited HandleEvent(Event);  // Let normal handling proceed
END;
```

#### Drawing Custom Grid/Table Content
```
TYPE TMyGrid = OBJECT(TView)
  Rows, Cols: Integer;
  Data: ^ARRAY[0..999] OF String;
  PROCEDURE Draw; Virtual;
  PROCEDURE HandleEvent(Var Event: TEvent); Virtual;
END;

PROCEDURE TMyGrid.Draw;
VAR
  X, Y, CellWidth: Integer;
  B: TDrawBuffer;
  Attr: Byte;
BEGIN
  CellWidth := 10;
  
  FOR Y := 0 TO Rows - 1 DO
  BEGIN
    MoveStr(B, '', GetColor(2), 0);  // Initialize buffer
    
    FOR X := 0 TO Cols - 1 DO
    BEGIN
      IF (X = CurX) AND (Y = CurY) THEN
        Attr := GetColor(3)  // Focused cell
      ELSE
        Attr := GetColor(2); // Normal cell
      
      WriteChar(X * CellWidth, Y, ' ', Attr, CellWidth);
      WriteStr(X * CellWidth + 1, Y, 
               Copy(Data^[Y * Cols + X], 1, CellWidth - 2), Attr);
    END;
  END;
END;
```

#### Building a Popup Context Menu at Mouse Position
```
PROCEDURE TMyView.RightClickMenu(Event: TEvent);
VAR
  Menu: PMenu;
  MenuBox: PMenuBox;
  Item: PMenuItem;
  Local: TPoint;
  R: TRect;
  Command: Word;
BEGIN
  // Build menu structure (items in reverse order)
  Item := nil;
  Item := NewItem('~Close', cmClose, kbEscape, 0, Item);
  Item := NewItem('~Edit', cmEdit, 0, 0, Item);
  Item := NewItem('~Delete', cmDelete, kbDel, 0, Item);
  Menu := NewMenu(Item);
  
  // Convert global mouse coords to local/global as needed
  Desktop^.MakeLocal(Event.Where, Local);
  
  // Create menu box, allowing it to auto-fit
  R.Assign(Local.X, Local.Y, Local.X + 20, Local.Y + 10);
  MenuBox := New(PMenuBox, Init(R, Menu, nil));
  
  // Execute menu
  Command := Desktop^.ExecView(MenuBox);
  
  // Clean up
  Dispose(MenuBox, Done);
  DisposeMenu(Menu);
  
  // Handle selection
  IF Command <> 0 THEN
    Message(Owner, evCommand, Command, @Self);
END;
```

#### Single-Row Horizontal Scrollbar as Slider
```
PROCEDURE InitTempoControl;
VAR
  R: TRect;
  TempoSlider: PScrollBar;
  CurrentTempo: Integer;
BEGIN
  R.Assign(10, 5, 50, 6);  // 1 row tall = horizontal scrollbar
  TempoSlider := New(PScrollBar, Init(R));
  
  // Configure as slider
  TempoSlider^.SetRange(60, 200);       // BPM range
  TempoSlider^.SetStep(4, 20);          // Arrow=4, Page=20
  TempoSlider^.SetValue(120);           // Default
  TempoSlider^.Id := idTempoSlider;
  
  Window^.Insert(TempoSlider);
  TempoSlider^.Focus;
END;

// In HandleEvent:
IF Event.What = evCommand THEN
BEGIN
  CASE Event.Command OF
    cmScrollBarChanged:
      IF Event.Id = idTempoSlider THEN
      BEGIN
        CurrentTempo := TempoSlider^.Value;
        AudioEngine.SetTempo(CurrentTempo);
        DrawTempo;
        ClearEvent(Event);
      END;
  END;
END;
```

---

### Standard Command and State Interaction

#### State Flags
Views use state flags to track runtime conditions:
- `sfVisible` - drawn on screen
- `sfActive` - in active window
- `sfSelected` - currently selected/focused
- `sfFocused` - has keyboard focus
- `sfDragging` - being dragged
- `sfDisabled` - not responsive
- `sfModal` - running as modal

#### Option Flags
Options define view capabilities:
- `ofSelectable` - can receive focus
- `ofFramed` - has border frame
- `ofPreProcess` - custom event preprocessing
- `ofPostProcess` - custom event postprocessing
- `ofBuffered` - double-buffer rendering
- `ofTileable` - can be tiled on desktop
- `ofCentered` / `ofCenterX` / `ofCenterY` - alignment in parent
- `ofValidate` - run validator on data

#### Command Sets
Commands can be enabled/disabled per view:
```
PROCEDURE DisableCommands(Commands: TCommandSet);
PROCEDURE EnableCommands(Commands: TCommandSet);
FUNCTION CommandEnabled(Command: Word): Boolean;
```

---

### Key Constants Reference

#### Mouse Buttons (Drivers.pas)
- `mbLeftButton = $01`
- `mbRightButton = $02`
- `mbMiddleButton = $04`
- `mbScrollWheelUp = $10`
- `mbScrollWheelDown = $08`

#### Keyboard Shift States (Drivers.pas)
- `kbLeftShift = $0002, kbRightShift = $0001` - shift
- `kbCtrlShift = $0004` - control
- `kbAltShift = $0008` - alt
- `kbCapsState, kbNumState, kbScrollState = $0040, $0020, $0010` - toggle states
- `kbInsState = $0080` - insert mode

#### Extended Key Codes (Drivers.pas - selection)
Function keys: `kbF1..kbF12`, `kbShiftF1..kbShiftF12`, `kbCtrlF1..kbCtrlF12`, `kbAltF1..kbAltF12`
Navigation: `kbHome, kbEnd, kbPageUp, kbPageDown, kbUp, kbDown, kbLeft, kbRight`
Editing: `kbIns, kbDel, kbTab, kbShiftTab, kbEnter, kbEscape, kbBackspace`
Special: `kbCtrlEnd, kbCtrlHome, kbCtrlLeft, kbCtrlRight`, etc.

#### View Grow Modes (views.pas)
- `gfGrowLoX = $01` - grow with left edge
- `gfGrowLoY = $02` - grow with top edge
- `gfGrowHiX = $04` - grow with right edge
- `gfGrowHiY = $08` - grow with bottom edge
- `gfGrowAll = $0F` - grow all sides
- `gfGrowRel = $10` - proportional grow

#### Draw View Masks (views.pas)
- `vdBackGnd = $01` - draw background
- `vdInner = $02` - draw inner detail
- `vdCursor = $04` - draw cursor
- `vdBorder = $08` - draw border
- `vdFocus = $10` - draw focus indicator
- `vdNoChild = $20` - don't draw children
- `vdShadow = $40` - draw shadow
- `vdAll` - all of the above

#### Tab Movement Masks (views.pas)
- `tmTab = $01` - Tab key
- `tmShiftTab = $02` - Shift+Tab
- `tmEnter = $04` - Enter key
- `tmLeft = $08, tmRight = $10` - arrow keys
- `tmUp = $20, tmDown = $40` - arrow keys

---

### View Hierarchy and Ownership Model

#### Parent-Child Relationships
- TGroup maintains linked list of children (via `Next` pointer)
- Each view has `Owner` pointing to parent group
- Views drawn in insertion order (first inserted = drawn first = behind)
- `MakeFirst()` moves view to end of list (drawn last = on top)
- `PutInFrontOf()` positions relative to target

#### Modal Execution Nesting
- Views can execute modal via `Execute()` method
- `TApplication` maintains phase state (phFocused, phPreProcess, phPostProcess)
- `EndModal(Command)` terminates modal with result code
- `ExecView(P)` executes child view, returns command
- `ExecuteDialog(P, Data)` executes dialog with data exchange

#### Focus and Selection Navigation
- `FocusNext(Forwards)` moves focus between selectable children
- `SelectNext(Forwards)` navigates in cluster items
- `SelectDefaultView` activates default child (sfDefault flag)
- Focus can be stolen by `ofFirstClick` option or `GrabFocus` flag

#### Help Context Propagation
- Views have `HelpCtx: Word` for context-sensitive help
- `GetHelpCtx()` virtual allows derived lookup
- Propagates to TStatusLine for hint display
- Menu items have separate `HelpCtx` in TMenuItem record

---

### Validation and Data Exchange

#### Validation Mechanism
Views with `ofValidate` option call `Valid(Command)` before processing commands:
```
FUNCTION TView.Valid(Command: Word): Boolean; virtual;
```
Returns false if validation fails (preventing dialog close, etc.).
Override in derived classes to add custom logic.

#### Data Record Convention
Dialog controls support data exchange via typed records:
```
TYPE TMyData = RECORD
  Username: String[80];
  Age: Integer;
END;

PROCEDURE PopulateDialog(Data: TMyData);
VAR D: TMyData := Data;
BEGIN
  MyDialog^.SetData(D);
END;

PROCEDURE RetrieveData(VAR Data: TMyData);
VAR D: TMyData;
BEGIN
  MyDialog^.GetData(D);
  Data := D;
END;
```

Children fields matched by name convention (optional - manual mapping common).
Parent TGroup calls `SetData`/`GetData` on all children recursively.

---

### Streaming and Persistence

#### Stream Registration
Objects register Load/Store methods via TStreamRec for persistence:
```
CONST RMyView: TStreamRec = (
  ObjType: idMyView;
  VmtLink: TypeOf(TMyView);
  Load: @TMyView.Load;
  Store: @TMyView.Store
);
```

#### Stream Save/Load Pattern
```
// Save to stream
CONSTRUCTOR TMyView.Init(...);

PROCEDURE TMyView.Store(Var S: TStream);
BEGIN
  TView.Store(S);  // Call parent
  S.Write(...);    // Write custom fields
END;

// Load from stream
CONSTRUCTOR TMyView.Load(Var S: TStream);
BEGIN
  Inherited Load(S);  // Call parent
  S.Read(...);        // Read custom fields
END;
```

Child views stored via `PutSubViewPtr()/GetSubViewPtr()` which handles dynamic allocation.

---

### Found while building the effects rack (DysEffectsRack.pas)

**`TScrollBar` is a perfectly usable slider on its own, with real keyboard
support built in - not just mouse.** `TScrollBar.HandleEvent` (`views.pas`)
handles `evKeyDown` directly: for a horizontal bar (`Size.Y = 1`), Left/
Right step by `ArStep`, Ctrl+Left/Ctrl+Right page by `PgStep`, Home/End jump
to Min/Max - and critically this branch is gated only on `State and
sfVisible <> 0`, not on focus, so it fires whenever the scrollbar is the
view actually receiving the event (i.e. whenever it's `Current`), no extra
autoscroll-owner wiring needed the way a `TScroller`'s attached scrollbars
usually get driven. `TScrollBar.Init` picks horizontal vs vertical purely
from `Size.X = 1` (vertical) vs otherwise (horizontal) - a `Bounds` with
width > 1 and height = 1 is a horizontal bar automatically. This makes it a
one-object "slider" with mouse drag/click AND keyboard for free; the only
work needed on top is resyncing whatever external value it represents
after `inherited HandleEvent` runs.

**Building a standalone popup menu (not a menu-bar submenu): `NewMenu`/
`NewSubMenu`/`NewItem` (`Menus.pas`) plus `Desktop^.ExecView`.** These are
plain functions, not methods - `NewItem(Name, Param, KeyCode, Command,
AHelpCtx, Next)` and `NewSubMenu(Name, AHelpCtx, SubMenu, Next)` both
prepend onto a `PMenuItem` linked list via their own `Next` parameter (so
building one bottom-up, each call's `Next` fed the previous result, ends up
in the REVERSE of on-screen order - insert the last-wanted item first).
`TMenuBox.Init(Bounds, AMenu, AParentMenu)` auto-sizes itself down to fit
its actual item text within whatever `Bounds` is passed (computes real
width/height from the menu's own strings, then clips/shifts to fit inside
`Bounds` - passing the full Desktop extent as `Bounds`, anchored at the
desired top-left, is the normal way to say "as big as it needs, no bigger,
starting here"). Running it as a context-menu popup (not a menu-bar
dropdown) is the same `TGroup.ExecView` idiom this codebase already uses
for `TDialog` (`DysFileDialog`/`DysPreferences`): `Desktop^.ExecView
(MenuBoxPtr)` inserts it, runs `TMenuView.Execute`'s own tracking loop
(mouse/keyboard menu navigation, fully self-contained), removes it, and
returns the selected `Command` (0 if cancelled/Esc) - then `Dispose(MenuBox
Ptr, Done)` plus `DisposeMenu(TheMenu)` clean up both the view and the
heap-allocated `PMenuItem`/`PMenu` chain `NewMenu`/`NewSubMenu`/`NewItem`
built.

**`TView.MakeLocal`/`MakeGlobal` convert between global (screen) and a
view's own local coordinates - needed any time a global point (like
`Event.Where`) has to become a `Bounds` for something inserted elsewhere.**
`Event.Where` on a mouse event is in global/screen coordinates; a view's
own `Bounds`/`Origin` are always relative to its immediate `Owner` (see the
"Coordinates are owner-local" note above). `SomeView^.MakeLocal(GlobalPt,
var LocalPt)` walks `Self` up through every `Owner`, subtracting each
level's `Origin`, stopping early (without subtracting that level) if the
running total ever goes negative - so calling it on the view you're about
to `Insert`/position something INTO (e.g. `Desktop^.MakeLocal(Event.Where,
Local)` before building a `TMenuBox` bound for `Desktop^.ExecView`) gives
exactly the coordinate space that view's own children need. `MakeGlobal`
is the exact inverse (adds `Origin` walking up), useful for the opposite
case - turning a view's own local point (e.g. `(0,0)`, its own top-left)
into a global one when no mouse position is available (a keyboard-
triggered popup has to synthesize somewhere to open).

**FPC's unit system refuses a 3-unit circular `uses` cycle outright, with a
specific fatal error naming the two units it noticed the loop between.**
`A uses B; B uses C; C uses A` fails to compile the moment the third leg is
added, as `<file of C>(<line>,<col>) Fatal: Circular unit reference between
C and A` - naming only the two units whose mutual reference finally closed
the loop, not the third one actually responsible, which can be misleading
if the error looks like it's blaming the wrong pair. There is no "forward
unit declaration" escape hatch for this the way there is for forward type
pointers within one unit's own `type` block - the only fix is moving
whichever type is creating the extra edge into a unit that already sits on
one side of the existing two-unit dependency, so the graph among unit
`interface` sections stays acyclic. (Implementation-section-only `uses`
additions don't help either, once the cycle runs through an interface-
section dependency.)

---

## Advanced FV Implementation Details

### Constructor Semantics and Object Initialization

#### Object Creation Pattern
Free Vision strictly requires manual allocation via `New()` with virtual constructor:
```
VAR MyView: PView;
BEGIN
  MyView := New(PView, Init(Bounds));  // Allocate + call Init
  // ...
  Dispose(MyView, Done);               // Call Done + deallocate
END;
```

**Critical**: Never call `inherited Init` in intermediate constructors if they return early or fail - the base TView.Init must run to establish the object's fields properly. If a custom constructor needs to validate arguments before calling inherited, do that validation *before* `inherited Init`, not after.

#### Init vs Constructor
FPC objects use virtual methods `Init` (constructors) and `Done` (destructors), not the `constructor`/`destructor` keywords. Never override `Create` or `Destroy` in Free Vision classes - use `Init` and `Done` instead. Virtual destructors don't exist in classic Pascal - `Done` is a plain virtual method that TView defines, inherited by all descendants, called manually before `Dispose`.

#### Initialization Order
Objects registered with `TView` must call `inherited Init` first in their constructor, before setting their own fields. Some properties (like `Options`, `State`, `EventMask`) are set by `TView.Init` to sensible defaults - overwriting them before calling inherited can lose those defaults.

---

### Input and Focus Management Details

#### Focus Delivery Chain
Keyboard input flows top-down through the owner chain:
1. Application.HandleEvent() - app-level commands
2. Owner (TGroup/TWindow) - intermediate containers
3. Current child's HandleEvent - leaf view that has focus
4. Event.What = evKeyDown, routing via Key/KeyCode fields

Each level sees the event in its HandleEvent, and can:
- Clear the event (mark as consumed)
- Forward via `inherited HandleEvent(Event)` (not consumed)
- Send a different command upstream via `Message(Owner, ...)`

**Critical mistake**: If a parent's HandleEvent consumes an event (clears it) before calling inherited, the child never sees it. Conversely, if a parent doesn't clear it and calls inherited, the child gets it. The parent-child relationship is reversed from typical UI frameworks - the parent routes to Current first, then processes the leftovers.

#### Selectable vs Focusable
- `ofSelectable` flag (Option) - view can receive focus
- `sfFocused` state flag (State) - view currently has focus
- `.Focus()` method - ask to receive keyboard input (climbs owner chain, fails silently if owner is nil)
- `.Select()` method - become owner's Current child (doesn't climb, doesn't affect siblings)

A view with `ofSelectable` set but never explicitly `.Focus()`'d will receive mouse events (hit-tested in `FirstThat`) but not keyboard events. Tab cycling via `SelectNext` only moves the owner's `Current`, it doesn't automatically climb or deliver keys.

#### Mouse Events and Hit Testing
Mouse events (evMouseDown, evMouseUp, evMouseMove) are routed by spatial hit-testing, not by focus:
1. Event.Where is in global screen coordinates
2. Owner traverses children in reverse insertion order (drawn-last-is-topmost)
3. Calls `ContainsMouse(Where)` on each until one returns true
4. Sends event to that child; child's HandleEvent fires immediately
5. Owner calls inherited HandleEvent for non-mouse events only

A mouse-aware view doesn't need keyboard focus to receive mouse events.

---

### Redrawing and Buffering

#### Draw() Call Frequency
`Draw()` is called:
- On initialization via `DrawView()` (called by TApplication after inserting a top-level window)
- After events that change appearance (select, state, data)
- After `ReDraw()` call on parent (full redraw cascade)
- On window focus change or mode switch
- NOT automatically on every event

**Do not rely on Draw() being called after HandleEvent()** - if you change internal state, call `DrawView()` yourself or let the parent's `ReDraw()` pick it up on the next event loop iteration.

#### Buffered Output Pattern
```
PROCEDURE TMyView.Draw;
VAR
  B: TDrawBuffer;  // Line buffer (up to 256 chars)
  Color: Byte;
BEGIN
  Color := GetColor(1);
  MoveStr(B, 'My Text', Color, 0);  // Write to buffer
  WriteLine(0, 0, Size.X, 1, B);    // Copy buffer to screen
END;
```

TDrawBuffer is character/attribute pairs (2 bytes per cell). `WriteLine` is the low-level screen output. Never call WriteChar/WriteStr directly on screen - build in a buffer first via MoveStr/MoveChar, then output once.

#### Palette and Color Resolution
GetColor(Index) is expensive - it walks the entire owner chain. Call it once per Draw(), cache the result in a local, then use that byte for all MoveStr/MoveChar calls in that draw pass.

---

### State Flags and Property Interactions

#### State Flags That Matter
- `sfVisible` - drawn on screen (set by Show/Hide)
- `sfCursorVis` - cursor visible within view
- `sfActive` - in active window (set by app on focus change)
- `sfSelected` - currently selected (TCluster items, list items)
- `sfFocused` - has keyboard input (set by .Focus())
- `sfDragging` - being mouse-dragged (set by DragView)
- `sfDisabled` - not responsive to input (can be read/set manually)

#### View Options
- `ofSelectable` - participates in Tab cycling
- `ofFramed` - TWindow draws frame around it
- `ofPreProcess` - view's HandleEvent runs before children's
- `ofPostProcess` - view's HandleEvent runs after children's
- `ofBuffered` - TGroup double-buffers this view's draw
- `ofTileable` - included in Desktop.Tile() arrangement
- `ofCentered` / `ofCenterX` / `ofCenterY` - auto-center in owner

Setting `ofBuffered` on a TGroup makes the entire group redraw to memory first, then output in one block - useful for flicker-free updates of complex child hierarchies.

#### Options and Init
Options are NOT reset by Init() - if you set them before calling inherited, they persist. Set them *after* inherited Init returns if you want to override the defaults.

---

### Common Runtime Errors and Their Causes

#### "View doesn't appear" (silent)
- Bounds are relative to owner, not global. Check `GetExtent()` returns `(0,0)-(Size)` not actual screen coords.
- View is behind other views. Call `MakeFirst()` to bring to front.
- View's Owner is nil (not inserted yet). Confirm `Insert()` was called.
- View is outside owner's bounds. Even if it's inserted, if Origin + Bounds extends past owner's Size, it clips.
- Parent's `ClipChilds()` returns true but child is outside parent's visible area.

#### "Keyboard input not working"
- View doesn't have focus. Call `.Focus()` *after* insertion is complete (not inside InitDeskTop).
- Owner's `Current` is nil. Call `SelectNext(True)` to pick a child, then `.Focus()` on it.
- View is disabled (sfDisabled flag). Check with GetState(sfDisabled).
- View doesn't have ofSelectable option set.
- Parent's HandleEvent consumed the event before calling inherited.

#### "Palette is messed up / red/blinking artifacts"
- Palette index out of range. Window's GetPalette() palette is too short for its child control (e.g. plain TWindow with TListBox). Use CGrayDialog palette instead.
- Blink bit accidentally set. Check for $F0, $Cx, $Ex - these all have bit 7 set. Use $70 for reverse-video instead.
- GetColor(n) returns wrong index because palette cascade re-mapped it. Build a custom palette that accounts for all child palettes, or skip GetColor entirely and use raw attribute bytes.

#### "Button/command doesn't fire"
- Button has bfBroadcast flag instead of bfNormal. Broadcast sends evBroadcast, not evCommand. Change to bfNormal.
- Owner's HandleEvent doesn't have a `case Event.Command of` block. Commands only fire if owner is listening.
- Event consumed somewhere up the chain. Check that inherited HandleEvent is being called.

#### "Tab cycling strange / focus jumps unexpectedly"
- Intermediate TGroup between focused view and TWindow. If two levels of TGroup exist, SelectNext on the outer one doesn't account for the inner one. Flatten the hierarchy if possible.
- Tab handled by TWindow before outer container. TWindow has its own tab handler that calls FocusNext. Intercept kbTab in the parent before calling inherited.

#### "Scrollbar doesn't move / list doesn't scroll"
- Scrollbar's Id doesn't match the list's id. TListViewer auto-queries scrollbars by id - if they don't match, events don't connect.
- List hasn't called SetTopItem() or FocusItem() after setting range. Initial layout is manual.
- Scrollbar's Range (Min/Max/Page) not set. Call SetRange and SetStep after creating it.

#### "Window is draggable but moves off-screen"
- DragView limits are TRect - if not set, there's no constraint. Provide a valid Limits rect in DragView call, anchored to parent's visible area.

---

### Performance and Memory Optimization

#### String Management
Always use NewStr/DisposeStr for heap strings in Free Vision:
```
S := NewStr('text');  // Allocate from pool
// ...
DisposeStr(S);        // Return to pool (not Dispose)
```

Free Vision maintains a pool to reduce allocation churn. Direct Pascal strings use stack/local memory, which is fine for temporaries, but pooled strings survive across event processing.

#### Collection Sizing
When creating a TCollection, choose initial size and growth delta wisely:
```
NEW(MyCollection, Init(100, 10));  // Start at 100, grow by 10
```
Growth is geometric (multiplied, not added), so setting delta=1 for a large collection means many tiny reallocs. A rule of thumb: delta ~= sqrt(initial size).

#### View Redraw Batching
If many properties change, batch the redraws:
```
TWindow.Lock;    // Stop redrawing
View1.SetState(sfActive, True);
View2.SetState(sfActive, False);
View3.SetData(...);
TWindow.Unlock;  // Redraw everything at once
TWindow.ReDraw;  // Force full cascade
```

Lock/Unlock disables incremental draws; ReDraw forces a complete repaint. Without batching, each SetState can trigger a Draw().

#### Large Grids / Tables
For views with 100+ rows/columns:
- Don't create actual views for each cell - that's 10,000 objects. Use a single TView and hand-draw via Draw().
- Cache measurements (cell width, row height) in instance variables, don't recalculate on every Draw() call.
- Implement scroll-aware rendering: only Draw() the visible cells, use TopItem/TopColumn to track scroll state.
- If selection is visible, draw it differently in Draw(), don't track 1000 selected-state flags.

---

### Event Processing Phases and Message Flow

#### Event Loop Phases
TApplication.Run() repeats:
1. GetEvent() - get next input (blocking if queue empty, calls Idle())
2. Call HandleEvent(Event) on TApplication, propagates to views
3. Event.What still set? (not consumed) - route to mouse/keyboard specific handlers
4. Return to step 1

Message() calls HandleEvent synchronously and return immediately - it doesn't enter a nested loop.

#### Broadcast Messages
`evBroadcast` is sent to every view in a group (not just Current):
1. TGroup iterates children
2. Calls HandleEvent on each with the broadcast event
3. Children can consume it (clear Event.What) to stop propagation to siblings

Used when a button click should update multiple unrelated views. Rare in most apps.

---

### Memory Leaks and Resource Management

#### Disposing Views Properly
Always match New/Dispose:
```
P := New(PMyView, Init(...));
Window^.Insert(P);
// ...
Window^.Delete(P);  // Remove from owner first
// Now P is deleted and disposed - DO NOT access it
// DO NOT call Dispose(P) again
```

TGroup.Delete() both removes from the linked list AND calls Dispose() on the view. Calling Dispose() after Delete() causes double-free.

If you create a view but decide not to insert it:
```
P := New(PMyView, Init(...));
IF some_condition THEN
  Window^.Insert(P)
ELSE
  Dispose(P, Done);  // Clean up unused view
```

#### Stream Memory
TStream allocates a buffer internally. When done:
```
MyStream := New(PStream, Init(1024, False));
// ... read/write
Dispose(MyStream, Done);  // Free the buffer
```

#### Palette Memory
Palette strings returned by GetPalette() are static (in code segment), never heap-allocated. Do not DisposeStr them.

---

### TApplication Subclassing

#### Minimal TApplication Subclass
```
TYPE TMyApp = OBJECT(TApplication)
  PROCEDURE InitDesktop; Virtual;
  PROCEDURE InitStatusLine; Virtual;
  PROCEDURE HandleEvent(Var Event: TEvent); Virtual;
END;

PROCEDURE TMyApp.InitDesktop;
BEGIN
  inherited InitDesktop;  // Sets up basic desktop/background
  // Add your custom windows here
  DeskTop^.Insert(...);
END;

PROCEDURE TMyApp.InitStatusLine;
VAR
  R: TRect;
BEGIN
  GetExtent(R);
  R.A.Y := R.B.Y - 1;        // Bottom line
  NEW(StatusLine, Init(R, NewStatusDef(...)));
  Insert(StatusLine);
END;

PROCEDURE TMyApp.HandleEvent(Var Event: TEvent);
BEGIN
  CASE Event.What OF
    evCommand: CASE Event.Command OF
      cmQuit: BEGIN EndModal(cmQuit); ClearEvent(Event); END;
    END;
  END;
  inherited HandleEvent(Event);
END;
```

#### Initialization Order
TApplication.Init calls in sequence:
1. InitScreen - set video mode, clear screen
2. InitStatusLine - create status bar
3. InitMenuBar - create menu bar (virtual, app-defined)
4. InitDesktop - create desktop (virtual, app-defined)
5. Insert(DeskTop) - only *after* all InitXXX calls

So `DeskTop^.Owner` is nil inside InitDesktop, but becomes valid after Init returns. This is why `.Focus()` calls made inside InitDesktop don't propagate to the app level.

---

### Deep Dive: View Rendering Pipeline

#### Screen Coordinates vs Local Coordinates
- Global/Screen coords: (0,0) is top-left of terminal, max is screen width/height
- Local coords: (0,0) is top-left of a view's own area, max is view's Size
- Owner coords: (0,0) is top-left of view's Owner (the immediate parent)

TRect bounds in Init() is always in owner-local coords, never screen coords.
Event.Where from mouse events is always in screen coords.
TPoint returned by GetExtent() is always local-relative (0,0)-(Size).

To convert mouse event coords to local:
```
LocalPt := Event.Where;
View^.MakeLocal(LocalPt, LocalPt);  // Subtracts all ancestor Origins
```

#### Drawing Order and Z-Order
Children are stored in insertion order (linked list). First inserted is drawn first (appears behind). Last inserted is drawn last (appears in front). `MakeFirst()` moves a view to the end of the list (brings to front). This only affects drawing, not input routing (mouse hit-test is also reverse order).

#### Clipping
By default, views are not clipped to their owner's bounds. A TView at (0,0,100,100) inside a TWindow at (0,0,50,50) will draw in cells 0-99 even though the owner is only 50 wide - part of its output will overwrite the owner's siblings.

To enable clipping, set `ClipChilds := true` in the parent (custom override of ClipChilds virtual method, or manually set a clip area).

---

### Keyboard Input Deep Dive

#### Key Codes and Scancodes
- KeyCode: Extended key code (kbEnter, kbTab, kbF1, etc.)
- CharCode: ASCII character (only set for printable keys)
- ScanCode: Raw hardware scan code (rarely used)
- KeyShift: Modifier state (kbCtrlShift, kbAltShift, kbLeftShift, etc.)

Examples:
- Pressing 'a' generates KeyCode=kbEnter (no), CharCode='a', KeyShift=0
- Pressing Enter generates KeyCode=kbEnter, CharCode=^M ($0D), KeyShift=0
- Pressing Ctrl+C generates KeyCode=<some code>, CharCode=^C, KeyShift=kbCtrlShift

#### Special Key Handling
```
IF (Event.KeyShift AND kbCtrlShift) <> 0 THEN
  // Ctrl is held

IF (Event.KeyShift AND (kbLeftShift OR kbRightShift)) <> 0 THEN
  // Shift is held

IF (Event.KeyShift AND kbAltShift) <> 0 THEN
  // Alt is held
```

#### Custom Key Binding
To handle a key globally, intercept it in TApplication.HandleEvent before calling inherited:
```
PROCEDURE TMyApp.HandleEvent(Var Event: TEvent);
BEGIN
  IF Event.What = evKeyDown THEN
  BEGIN
    CASE Event.KeyCode OF
      kbCtrlS: BEGIN SaveProject; ClearEvent(Event); END;
      kbCtrlL: BEGIN ShowLog; ClearEvent(Event); END;
    END;
  END;
  inherited HandleEvent(Event);
END;
```

---

### Testing and Debugging

#### No Built-in Logging
Free Vision has no debug output or logging framework. Add your own:
```
TYPE TDebugLog = OBJECT
  F: Text;
  PROCEDURE Log(Const Msg: String);
END;

PROCEDURE TDebugLog.Log(Const Msg: String);
BEGIN
  WriteLn(F, TimeStr + ': ' + Msg);
  Flush(F);
END;
```

Assign(F, 'debug.log'); Rewrite(F);
Call Log() from strategic points in your view's HandleEvent.

#### Breakpoints and GDB
FPC generates DWARF debug info by default (with -g flag). Use GDB on the binary:
```
gdb ./myprogram
(gdb) break TMyView.HandleEvent
(gdb) run
(gdb) c              (continue)
(gdb) p Event.What   (print variable)
(gdb) step           (step into)
(gdb) next           (step over)
```

Terminal redirection: GDB takes over stdin/stdout. Run under `screen` or `tmux`, or use GDB's batch mode to write a script.

---

## Building Sophisticated Applications: Stress-Tested Patterns

The patterns below are drawn from real applications that push Free Vision's limits (Dysnomia's 2000+ line UI, multi-pane real-time content, custom rendering, live input).

### Multi-Level Nested Containers

Real applications often need multiple levels of TWindow → TPane → Content structure:
```
TApplication
  ├─ TDeskTop
  │  ├─ TMainWindow
  │  │  ├─ TToolBar (TGroup)
  │  │  ├─ TPaneContainer (TGroup, horizontal splitter)
  │  │  │  ├─ TFilePane (TWindow/TGroup)
  │  │  │  │  └─ TFileListBox
  │  │  │  ├─ TTrackPane (TWindow/TGroup)
  │  │  │  │  └─ TTrackListBox
  │  │  │  └─ TPreviewPane (TWindow/TGroup)
  │  │  │     └─ TGridView (custom TView)
```

**Key principle**: Tab-cycling between panes happens at the container level, not window level. Each TPane implements Tab/Shift+Tab to move between siblings:
```
PROCEDURE TPane.HandleEvent(Var Event: TEvent);
BEGIN
  IF (Event.What = evKeyDown) AND (Event.KeyCode = kbTab) THEN
  BEGIN
    Owner^.SelectNext(True);  // Move to next TPane sibling
    IF Owner^.Current <> nil THEN
      Owner^.Current^.Focus;  // Focus the new pane
    ClearEvent(Event);
  END;
  inherited HandleEvent(Event);
END;
```

Without this pattern, Tab is consumed by TWindow.HandleEvent at the top level and never reaches the pane container.

### Custom Content Views with Real-Time Updates

Instead of TListBox (which expects a TCollection), build a hand-drawn TView for:
- Grids with 100+ rows (TListBox creates one object per row)
- Waveform displays, timelines, sequencers
- Live-updating data (e.g., audio meters, status values)

Pattern:
```
TYPE TTimelineView = OBJECT(TView)
  TopTime: Longint;        // First visible second
  FocusedClip: PClip;      // Currently focused clip
  SelectionStart, End: Longint;
  
  PROCEDURE Draw; Virtual;
  PROCEDURE HandleEvent(Var Event: TEvent); Virtual;
  PROCEDURE ScrollTo(Time: Longint);
  PROCEDURE SelectClip(C: PClip);
END;

PROCEDURE TTimelineView.Draw;
VAR
  X, Y: Integer;
  B: TDrawBuffer;
  Attr: Byte;
  TimeStr: String;
BEGIN
  // Draw header (time ruler)
  Attr := GetColor(1);
  MoveStr(B, '', Attr, 0);
  FOR X := 0 TO Size.X - 1 DO
  BEGIN
    IF (TopTime + X) MOD 10 = 0 THEN
    BEGIN
      TimeStr := IntToStr((TopTime + X) DIV 10);
      MoveStr(B, TimeStr, Attr, X);
      X := X + Length(TimeStr) - 1;  // Skip over written chars
    END
    ELSE IF (TopTime + X) MOD 5 = 0 THEN
      MoveChar(B, '·', Attr, 1);
  END;
  WriteLine(0, 0, Size.X, 1, B);
  
  // Draw clips
  FOR Y := 1 TO Size.Y - 1 DO
  BEGIN
    IF Y - 1 < Clips^.Count THEN
    BEGIN
      Clip := PClip(Clips^.At(Y - 1));
      DrawClipRow(Y, Clip);
    END;
  END;
END;

PROCEDURE TTimelineView.HandleEvent(Var Event: TEvent);
VAR Local: TPoint;
BEGIN
  CASE Event.What OF
    evMouseDown:
    BEGIN
      Owner^.MakeLocal(Event.Where, Local);
      IF Local.Y > 0 THEN  // Clicked on clip area
      BEGIN
        SelectClip(GetClipAtTime(Local.X + TopTime, Local.Y - 1));
        DrawView;
      END;
      ClearEvent(Event);
    END;
    evKeyDown:
    BEGIN
      CASE Event.KeyCode OF
        kbRight: BEGIN ScrollTo(TopTime + 1); DrawView; ClearEvent(Event); END;
        kbLeft: BEGIN ScrollTo(TopTime - 1); DrawView; ClearEvent(Event); END;
        kbUp: BEGIN SelectClip(PreviousClip(FocusedClip)); DrawView; ClearEvent(Event); END;
        kbDown: BEGIN SelectClip(NextClip(FocusedClip)); DrawView; ClearEvent(Event); END;
      END;
    END;
  END;
  inherited HandleEvent(Event);
END;
```

**Performance**: Only render visible rows/columns in the Draw() call. Use instance variables to track which rows are allocated/cached (e.g., RowCache: ARRAY[0..MaxVisibleRows] OF TRowData).

### Polling External State Without Blocking

For audio/DSP applications, monitor external state in Idle():
```
PROCEDURE TMyApp.Idle;
BEGIN
  // Check if audio engine has new data
  IF AudioEngine.HasNewSamples THEN
  BEGIN
    UpdateMeterView(AudioEngine.GetMeter(0), AudioEngine.GetMeter(1));
    MeterView^.DrawView;  // Redraw just the meter
  END;
  
  // Check if file loading finished
  IF FileLoader.IsComplete THEN
  BEGIN
    LoadFileIntoEditor(FileLoader.Result);
    EditorView^.DrawView;
  END;
  
  inherited Idle;
END;
```

Idle() is called whenever the input event queue is empty. It's the safe place to poll background work (threads, audio callbacks, file I/O completion) without blocking the UI event loop.

### Building Modular Panes That Share State

Pass references to shared state objects (not copies) through pane constructors:
```
TYPE TProjectPane = OBJECT(TWindow)
  Project: PProject;  // Shared reference
  CONSTRUCTOR Init(P: PProject; ...);
END;

CONSTRUCTOR TProjectPane.Init(P: PProject; ...);
BEGIN
  inherited Init(...);
  Project := P;
  // Now all child controls can access Project
END;

// Elsewhere:
PROCEDURE UpdateTrackCount;
VAR P: PProjectPane;
BEGIN
  P := PProjectPane(Owner^.Current);
  IF P <> nil THEN
    P^.Project^.Tracks := P^.Project^.Tracks + 1;
  P^.DrawView;  // Redraw the pane
END;
```

This avoids deep copying state and keeps all panes in sync with the same underlying data.

### Dispatching Custom Commands Between Panes

For application-level commands that affect multiple panes, use the Message() function:
```
// From a button/menu:
Message(Application, evCommand, cmAddTrack, nil);

// Handled at app level:
PROCEDURE TMyApp.HandleEvent(Var Event: TEvent);
BEGIN
  CASE Event.What OF
    evCommand: CASE Event.Command OF
      cmAddTrack:
      BEGIN
        ProjectPane^.Project^.AddTrack;
        ProjectPane^.DrawView;
        TimelinePane^.DrawView;
        ClearEvent(Event);
      END;
    END;
  END;
  inherited HandleEvent(Event);
END;
```

This decouples panes - they don't directly call each other's methods, they post commands to the application.

### Animations and Timed Updates

For blinking cursors, animated indicators, or real-time meters:
```
PROCEDURE TMyApp.Idle;
VAR Ticks: Longint;
BEGIN
  GetTime(Ticks);
  
  // Blink cursor every 500ms
  IF (Ticks DIV 500) MOD 2 = 0 THEN
    CursorView^.Show
  ELSE
    CursorView^.Hide;
  
  // Animate a spinner
  CASE (Ticks DIV 100) MOD 4 OF
    0: SpinnerChar := '/';
    1: SpinnerChar := '-';
    2: SpinnerChar := '\';
    3: SpinnerChar := '|';
  END;
  SpinnerView^.DrawView;
  
  inherited Idle;
END;
```

GetTime() returns milliseconds since system start (resolution varies by platform, but ~10ms granularity is typical).

---

