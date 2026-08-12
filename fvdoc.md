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
