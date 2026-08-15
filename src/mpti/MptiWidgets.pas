{
  Generic widget library (mpti.md Phase 7). Deliberately minimal for now
  - a single widget (MButton) to prove the whole stack built in Phases
  0-6.5 actually composes end to end (ID-keyed state, hit-test dispatch,
  focus, clipped/wide-glyph-safe drawing) before building the rest of
  the library out on top of the same pattern.

  MButton is the reference shape every later widget in this unit follows:
  - Takes a caller-chosen Name (hashed once via MWidgetID) and PaneID,
    not a persistent object - it is a plain function called fresh every
    frame from current state, per MPTI's immediate-mode design.
  - Registers its own hit rect via MRegisterHitRect, then self-checks
    Events against that same rect (the "self-check" pattern documented
    in MptiCore's unit comment) rather than requiring the caller to run
    a separate centralized MDispatchMouse pass - correct for a single
    ordinary (non-overlapping, non-floating) widget; a popup/dialog
    layered on top of other widgets should use MHitTest/MDispatchMouse
    centrally instead, exactly as MptiCore's doc comment already says.
  - Draws through MPutCodepointClipped, not raw MSetCell - safe against
    both wide glyphs in Caption and a Buf narrower than expected.
  - Returns a plain Boolean: True on exactly the frame it was activated
    (mouse press inside its rect, or Enter/Space while it holds focus),
    nothing more - what "activated" means to the caller (toggle a mute
    flag, open a dialog, whatever) is entirely the app's business.
}
unit MptiWidgets;

{$mode objfpc}{$H+}

interface

uses
  MptiTypes, MptiCell, MptiCore, MptiInput, MptiLayout;

{ Draws a "[ Caption ]" button at (X, Y), one row tall, into Buf.
  Registers its hit rect with HR under PaneID. Events is this frame's
  full decoded input (from MRunOnce/MHeadlessFeedInput) - MButton scans
  it itself rather than requiring the caller to pre-filter, which is
  fine at the scale of a handful of widgets in a frame; an app with
  many widgets would want to dispatch centrally instead (see unit doc
  comment). Returns True exactly on the frame this button was activated. }
function MButton(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Caption: string;
  const Events: TMInputEventArray): Boolean;

{ Same shape as MButton, but persists an on/off state per ID (in
  TMWidgetState.Toggled) instead of firing a one-frame activation pulse.
  Draws "[x] Caption" / "[ ] Caption" - the Dysnomia TSpeedButton
  down-state replacement (mute/solo/etc toggle buttons). Returns the new
  Toggled value every frame (not just on the frame it changed), since
  callers generally want "is this on" every frame, not an edge pulse -
  unlike MButton's click-to-activate contract. }
function MToggleButton(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Caption: string;
  const Events: TMInputEventArray): Boolean;

{ Vertical scrollbar, Height rows tall at (X, Y), for a content range of
  [0, ContentSize) with Visible items shown at once. Current is the
  caller-owned scroll offset (clamped in place) - the widget has no
  scroll state of its own beyond drag bookkeeping (TMWidgetState.DragActive/
  DragStartY), because the scroll position is meaningful to the caller's
  own list/text state and must survive even if this widget's ID is swept
  (e.g. the pane was hidden and its scrollbar not drawn for a while).
  Thumb size/position follow the classic proportional-thumb formula;
  clicking the track above/below the thumb pages by Visible; dragging the
  thumb scrolls continuously; wheel events over the track step by 1.
  Returns True if Current changed this frame. }
function MScrollBar(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y, Height: Integer;
  ContentSize, Visible: Integer; var Current: Integer;
  const Events: TMInputEventArray): Boolean;

{ One row of mutually-exclusive "(o) Label" options stacked vertically
  from (X, Y), one option per row. Selected is the caller-owned index
  (clamped to [0, High(Labels)]) - like MScrollBar's Current, this widget
  has no state of its own beyond hit rects, since which option is chosen
  is meaningful to the caller and must survive the widget's ID being
  swept. Each option gets its own hit rect (Name + '/' + index) so a
  click on any row selects it directly, no separate Tab-cycling needed.
  Returns True if Selected changed this frame. }
function MRadioGroup(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Labels: array of string;
  var Selected: Integer; const Events: TMInputEventArray): Boolean;

{ Horizontal slider Width cells wide at (X, Y), for Value in [Min, Max].
  Value is caller-owned and clamped in place, same rationale as
  MScrollBar/MRadioGroup. Draws a track of '-' with a single 'o' handle
  cell; click-anywhere-on-track jumps the handle there, dragging it
  scrubs continuously - the Dysnomia TDysParamSlider replacement.
  Returns True if Value changed this frame. }
function MSlider(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y, Width: Integer;
  Min, Max: Integer; var Value: Integer; const Events: TMInputEventArray): Boolean;

{ Standalone checkbox: "[x] Caption" / "[ ] Caption", same shape/contract as
  MToggleButton (both share the internal ToggleLike helper below) - kept as
  its own named entry point because the widget list (mpti.md "TUI Features")
  calls out checkboxes and toggle buttons as separate concepts even though
  they render and behave identically here; callers reach for whichever name
  matches their intent. }
function MCheckBox(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Caption: string;
  const Events: TMInputEventArray): Boolean;

{ Single-row-tall text input box, Width cells wide. Text is caller-owned
  (like MSlider's Value/MScrollBar's Current) - the widget's own retained
  state (TMWidgetState.CursorPos as the caret index into Text, ScrollX as
  the horizontal scroll-follows-caret offset) only tracks editing mechanics,
  never the content itself. Only edits while focused (click-to-focus-also-
  acts: a click both focuses and, if it lands past the caption, places the
  caret). Handles Left/Right/Home/End/Backspace/Delete and printable ASCII
  character insertion (mkChar with CodePoint in the 32..126 range - see
  implementation comment for why full Unicode insertion is out of scope
  here). Returns True if Text changed this frame. }
function MTextInput(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y, Width: Integer;
  var Text: string; const Events: TMInputEventArray): Boolean;

{ Scrollable, keyboard/mouse-selectable list, Height rows tall at (X, Y),
  Width cells wide. Doubles as the "file browser / generic list-tree view"
  widget from mpti.md's TUI Features list: MPTI has no opinion on file
  browsing or tree structure - a caller building either just pre-formats
  Items itself (a directory listing's names, or tree rows with a caller-
  chosen indent prefix and expand/collapse glyph baked into the string),
  exactly the same "app owns content, MPTI owns mechanism" split already
  established by MptiLayout not hardcoding any app's pane arrangement.
  Selected/ScrollOffset are caller-owned (clamped in place) for the same
  reason MScrollBar's Current is: meaningful to the app, must survive this
  widget's ID being swept. Up/Down/PageUp/PageDown/Home/End move Selected
  while focused, auto-scrolling to keep it visible; click selects a row and
  focuses; wheel scrolls without changing Selected. Returns True if
  Selected changed this frame. }
function MListView(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y, Width, Height: Integer;
  const Items: array of string; var Selected, ScrollOffset: Integer;
  const Events: TMInputEventArray): Boolean;

{ Row of top-level menu labels starting at (X, Y), separated by two spaces.
  Purely a "what was clicked" reporter plus its own open/closed highlight -
  MMenuBar does not draw or manage a dropdown itself (that's MDropdownList,
  below); an app composes the two, exactly the split MptiLayout already
  uses for pane arrangement (mechanism here, policy in the app). Clicking a
  label toggles it open/closed (click same label again to close); the
  currently-open index is retained internally (keyed off Name, like every
  other widget's state) purely to know which label to draw highlighted -
  it is NOT returned as an edge pulse, since a caller needs to know "is menu
  N open" every frame to decide whether to also draw its dropdown this
  frame, the same "every frame, not just on change" rationale MToggleButton's
  doc comment already gives for its own Result. Escape closes whatever is
  open. Returns the currently-open label index, or -1 if none. }
function MMenuBar(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Items: array of string;
  const Events: TMInputEventArray): Integer;

{ Bordered popup list of Items at (X, Y) - the shared primitive behind both
  "dropdowns" and "context menus" from mpti.md's TUI Features list, since
  both are the same shape (a floating list of choices over whatever's
  behind it) and differ only in what X/Y the caller passes (below a menubar
  label for a dropdown, at the mouse position for a context menu). Unlike
  MListView this owns its open/closed lifecycle for the caller: it is only
  ever drawn by the app while "open" (immediate mode - the app simply stops
  calling it once closed, and whatever it was covering reappears next frame
  for free, satisfying mpti.md FV gap #3 without any invalidation bookkeeping),
  and reports back what should close it. Mouse hover highlights a row (no
  click needed to preview); Up/Down move the highlight; a left-click or
  Enter on a highlighted row selects it; Escape, or a left-click outside R,
  cancels. Returns the selected item's index, -1 if still open with nothing
  chosen yet, or -2 if cancelled - callers check Result >= -1 to decide
  whether to keep drawing this widget next frame. }
function MDropdownList(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Items: array of string;
  const Events: TMInputEventArray): Integer;

{ Draws a bordered frame W x H at (X, Y) with an optional single-line
  Title, clearing its interior to blank first. This is the "pane" and
  "dialog box" primitive from mpti.md's TUI Features list at once - a
  dialog is just a pane drawn on top of other content with widgets (see
  MButton et al.) composed inside its content rect (MRectInset(R, 1) after
  MMakeRect(X, Y, W, H) gives the usable interior). Deliberately draw-only,
  no ID/state: a pane's own identity, if it needs one for focus routing,
  belongs to whatever PaneID the caller already threads through the widgets
  drawn inside it - a border by itself has nothing to focus. Border glyphs
  are plain ASCII ('+'/'-'/'|'), not Unicode box-drawing, so this renders
  correctly on the oldest terminal MPTI has to support (hard requirement
  6 - Tiger's stock xterm) without any capability check. }
procedure MDrawPane(var Buf: TCellBuffer; X, Y, W, H: Integer; const Title: string);

{ Single-cell status light - the "indicator lights" widget from mpti.md's
  TUI Features list. Deliberately the simplest possible shape (draw-only,
  no ID, no HR, no Events): an LED has no interaction of its own, only a
  caller-decided boolean state (record armed, clip playing, peak-over,
  etc), so there is nothing here for a widget-state slot or a hit rect to
  do. On draws a filled glyph in a bright color; off draws a dim glyph -
  color, not just glyph, carries the state so it still reads at a glance in
  a busy DAW meter strip. }
procedure MIndicatorLight(var Buf: TCellBuffer; X, Y: Integer; OnState: Boolean);

{ Horizontal/vertical bar meters - the "meters horizontal and vertical (for
  things like VU)" widget from mpti.md's TUI Features list. Draw-only, same
  rationale as MIndicatorLight: a VU meter's ballistics (attack/decay, peak
  hold) are audio-engine policy, not a TUI framework's business, so these
  just render whatever Value/Max the caller computed this frame - an app
  wanting peak-hold decay recomputes Value itself each frame and this
  widget stays a pure function of it, consistent with mpti.md's immediate-
  mode design (draw becomes a function of state). Value is clamped to
  [0, Max] before rendering; Max <= 0 draws an empty bar rather than
  dividing by zero. }
procedure MMeterH(var Buf: TCellBuffer; X, Y, Width: Integer; Value, Max: Integer);
procedure MMeterV(var Buf: TCellBuffer; X, Y, Height: Integer; Value, Max: Integer);

{ Determinate progress bar, Width cells wide: "[####----] NN%" showing
  Value/Max as both a filled-cell count and a percentage. Same draw-only,
  no-ballistics-owned-here rationale as MMeterH/MMeterV. }
procedure MProgressBar(var Buf: TCellBuffer; X, Y, Width: Integer; Value, Max: Integer);

{ Indeterminate busy/spinner indicator - the other half of mpti.md's
  "progress/busy indicator" TUI Feature, for work with no known Value/Max
  (waiting on the audio engine, a file scan, etc). Needs Core only to read
  Core.FrameCounter as its animation clock - the same per-frame counter
  MBeginCoreFrame already advances for widget-touch tracking, so a spinner
  needs no timer/state slot of its own; it is a pure function of "which
  frame is this," consistent with every other draw-only widget in this
  unit. }
procedure MBusyIndicator(const Core: TMCoreState; var Buf: TCellBuffer; X, Y: Integer);

implementation

{ Minimal non-negative-int-to-decimal-string, kept local so this unit
  doesn't have to pull in SysUtils just to build a per-row widget ID
  suffix - no other MPTI unit depends on SysUtils either (see unit doc
  comment on dependency-freedom, hard requirement 9). }
function DecStr(N: Integer): string;
begin
  if N = 0 then
  begin
    Result := '0';
    Exit;
  end;
  Result := '';
  while N > 0 do
  begin
    Result := Chr(Ord('0') + (N mod 10)) + Result;
    N := N div 10;
  end;
end;

function MButton(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Caption: string;
  const Events: TMInputEventArray): Boolean;
var
  ID: TMWidgetID;
  R: TMRect;
  Focused: Boolean;
  Style: TMCellStyle;
  I, CX: Integer;
  S: string;
  W: Integer;
begin
  ID := MWidgetID(Name);
  R := MMakeRect(X, Y, Length(Caption) + 4, 1); { "[ " + Caption + " ]" }
  MRegisterHitRect(HR, ID, PaneID, R);

  Result := False;
  for I := 0 to High(Events) do
  begin
    if (Events[I].Kind = mekMouse) and (Events[I].Mouse.Action = maPress)
       and (Events[I].Mouse.Button = mbLeft)
       and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
    begin
      MSetFocus(Core, ID, PaneID);
      Result := True;
    end
    else if (Events[I].Kind = mekKey) and MIsFocused(Core, ID)
       and ((Events[I].Key.Code = mkEnter)
            or ((Events[I].Key.Code = mkChar) and (Events[I].Key.CodePoint = 32))) then
      Result := True;
  end;

  Focused := MIsFocused(Core, ID);
  if Focused then Style := [csReverse] else Style := [];

  S := '[ ' + Caption + ' ]';
  CX := X;
  for I := 1 to Length(S) do
  begin
    W := MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX, Y,
      Ord(S[I]), MDefaultFg, MDefaultBg, Style);
    Inc(CX, W);
  end;
end;

{ Shared shape behind MToggleButton and MCheckBox (see their interface doc
  comments) - factored out once a second identically-behaving widget needed
  the exact same click/Enter/Space-toggles-a-persistent-flag logic, rather
  than the two copy-pasting each other, which is how MToggleButton and
  MScrollBar/MRadioGroup/MSlider each ended up as their own from-scratch
  block above (fine for genuinely distinct widgets; not fine for two names
  over one behavior). }
function ToggleLikeWidget(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Caption: string;
  const Events: TMInputEventArray): Boolean;
var
  ID: TMWidgetID;
  R: TMRect;
  St: PMWidgetState;
  Focused: Boolean;
  Style: TMCellStyle;
  I, CX: Integer;
  S: string;
  W: Integer;
begin
  ID := MWidgetID(Name);
  R := MMakeRect(X, Y, Length(Caption) + 4, 1); { "[x] " + Caption }
  MRegisterHitRect(HR, ID, PaneID, R);
  St := MGetWidgetState(Core, ID);

  for I := 0 to High(Events) do
  begin
    if (Events[I].Kind = mekMouse) and (Events[I].Mouse.Action = maPress)
       and (Events[I].Mouse.Button = mbLeft)
       and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
    begin
      MSetFocus(Core, ID, PaneID);
      St^.Toggled := not St^.Toggled;
    end
    else if (Events[I].Kind = mekKey) and MIsFocused(Core, ID)
       and ((Events[I].Key.Code = mkEnter)
            or ((Events[I].Key.Code = mkChar) and (Events[I].Key.CodePoint = 32))) then
      St^.Toggled := not St^.Toggled;
  end;

  Focused := MIsFocused(Core, ID);
  if Focused then Style := [csReverse] else Style := [];

  if St^.Toggled then S := '[x] ' + Caption
  else S := '[ ] ' + Caption;
  CX := X;
  for I := 1 to Length(S) do
  begin
    W := MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX, Y,
      Ord(S[I]), MDefaultFg, MDefaultBg, Style);
    Inc(CX, W);
  end;

  Result := St^.Toggled;
end;

function MToggleButton(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Caption: string;
  const Events: TMInputEventArray): Boolean;
begin
  Result := ToggleLikeWidget(Core, HR, Buf, Name, PaneID, X, Y, Caption, Events);
end;

function MCheckBox(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Caption: string;
  const Events: TMInputEventArray): Boolean;
begin
  Result := ToggleLikeWidget(Core, HR, Buf, Name, PaneID, X, Y, Caption, Events);
end;

function MScrollBar(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y, Height: Integer;
  ContentSize, Visible: Integer; var Current: Integer;
  const Events: TMInputEventArray): Boolean;
var
  ID: TMWidgetID;
  R: TMRect;
  St: PMWidgetState;
  ThumbLen, ThumbPos, MaxScroll, Row: Integer;
  Before: Integer;
  I, GY: Integer;
  Ch: TMUInt32;
begin
  ID := MWidgetID(Name);
  if Height < 1 then Height := 1;
  R := MMakeRect(X, Y, 1, Height);
  MRegisterHitRect(HR, ID, PaneID, R);
  St := MGetWidgetState(Core, ID);

  MaxScroll := ContentSize - Visible;
  if MaxScroll < 0 then MaxScroll := 0;
  if Current < 0 then Current := 0;
  if Current > MaxScroll then Current := MaxScroll;

  { Proportional thumb: length reflects Visible/ContentSize, position
    reflects Current/MaxScroll - the standard scrollbar formula, clamped
    so a full-track or empty-content case still draws a sane 1-row thumb
    rather than dividing by zero. }
  if (ContentSize <= 0) or (Visible >= ContentSize) then
  begin
    ThumbLen := Height;
    ThumbPos := 0;
  end
  else
  begin
    ThumbLen := (Visible * Height) div ContentSize;
    if ThumbLen < 1 then ThumbLen := 1;
    if ThumbLen > Height then ThumbLen := Height;
    if MaxScroll > 0 then
      ThumbPos := (Current * (Height - ThumbLen)) div MaxScroll
    else
      ThumbPos := 0;
  end;

  Before := Current;

  for I := 0 to High(Events) do
  begin
    if Events[I].Kind <> mekMouse then Continue;
    GY := Events[I].Mouse.Y - Y;

    if (Events[I].Mouse.Action = maPress) and (Events[I].Mouse.Button = mbWheelUp)
       and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
      Dec(Current)
    else if (Events[I].Mouse.Action = maPress) and (Events[I].Mouse.Button = mbWheelDown)
       and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
      Inc(Current)
    else if (Events[I].Mouse.Action = maPress) and (Events[I].Mouse.Button = mbLeft)
       and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
    begin
      MSetFocus(Core, ID, PaneID);
      if (GY >= ThumbPos) and (GY < ThumbPos + ThumbLen) then
      begin
        St^.DragActive := True;
        St^.DragStartY := Events[I].Mouse.Y;
      end
      else if GY < ThumbPos then
        Dec(Current, Visible)
      else
        Inc(Current, Visible);
    end
    else if (Events[I].Mouse.Action = maRelease) and (Events[I].Mouse.Button = mbLeft) then
      St^.DragActive := False
    else if (Events[I].Mouse.Action = maDrag) and St^.DragActive
       and (MaxScroll > 0) and (Height > ThumbLen) then
    begin
      Inc(Current, ((Events[I].Mouse.Y - St^.DragStartY) * ContentSize) div Height);
      St^.DragStartY := Events[I].Mouse.Y;
    end;
  end;

  if Current < 0 then Current := 0;
  if Current > MaxScroll then Current := MaxScroll;

  if MaxScroll > 0 then
    ThumbPos := (Current * (Height - ThumbLen)) div MaxScroll
  else
    ThumbPos := 0;

  for Row := 0 to Height - 1 do
  begin
    if (Row >= ThumbPos) and (Row < ThumbPos + ThumbLen) then
      Ch := Ord('#')
    else
      Ch := Ord(':');
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X, Y + Row, Ch,
      MDefaultFg, MDefaultBg, []);
  end;

  Result := Current <> Before;
end;

function MRadioGroup(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Labels: array of string;
  var Selected: Integer; const Events: TMInputEventArray): Boolean;
var
  RowID: TMWidgetID;
  R: TMRect;
  Before, Row, I, CX: Integer;
  S: string;
  Ch: Integer;
  W: Integer;
begin
  if Selected < 0 then Selected := 0;
  if Selected > High(Labels) then Selected := High(Labels);
  Before := Selected;

  for Row := 0 to High(Labels) do
  begin
    RowID := MWidgetID(Name + '/' + DecStr(Row));
    R := MMakeRect(X, Y + Row, Length(Labels[Row]) + 4, 1); { "(o) " + Label }
    MRegisterHitRect(HR, RowID, PaneID, R);

    for I := 0 to High(Events) do
      if (Events[I].Kind = mekMouse) and (Events[I].Mouse.Action = maPress)
         and (Events[I].Mouse.Button = mbLeft)
         and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
      begin
        MSetFocus(Core, RowID, PaneID);
        Selected := Row;
      end;

    if Row = Selected then Ch := Ord('o') else Ch := Ord(' ');
    S := '(' + Chr(Ch) + ') ' + Labels[Row];
    CX := X;
    for I := 1 to Length(S) do
    begin
      W := MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX, Y + Row,
        Ord(S[I]), MDefaultFg, MDefaultBg, []);
      Inc(CX, W);
    end;
  end;

  Result := Selected <> Before;
end;

function MSlider(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y, Width: Integer;
  Min, Max: Integer; var Value: Integer; const Events: TMInputEventArray): Boolean;
var
  ID: TMWidgetID;
  R: TMRect;
  St: PMWidgetState;
  Before, Range, HandlePos, Col: Integer;
  I, GX: Integer;
  Ch: TMUInt32;
begin
  ID := MWidgetID(Name);
  if Width < 1 then Width := 1;
  R := MMakeRect(X, Y, Width, 1);
  MRegisterHitRect(HR, ID, PaneID, R);
  St := MGetWidgetState(Core, ID);

  if Max < Min then Max := Min;
  if Value < Min then Value := Min;
  if Value > Max then Value := Max;
  Range := Max - Min;
  Before := Value;

  for I := 0 to High(Events) do
  begin
    if Events[I].Kind <> mekMouse then Continue;
    GX := Events[I].Mouse.X - X;

    if (Events[I].Mouse.Action = maPress) and (Events[I].Mouse.Button = mbLeft)
       and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
    begin
      MSetFocus(Core, ID, PaneID);
      St^.DragActive := True;
      if Range > 0 then
        Value := Min + (GX * Range + (Width - 1) div 2) div (Width - 1)
      else
        Value := Min;
    end
    else if (Events[I].Mouse.Action = maRelease) and (Events[I].Mouse.Button = mbLeft) then
      St^.DragActive := False
    else if (Events[I].Mouse.Action = maDrag) and St^.DragActive and (Range > 0) then
    begin
      if GX < 0 then GX := 0;
      if GX > Width - 1 then GX := Width - 1;
      Value := Min + (GX * Range + (Width - 1) div 2) div (Width - 1);
    end;
  end;

  if Value < Min then Value := Min;
  if Value > Max then Value := Max;

  if Range > 0 then
    HandlePos := ((Value - Min) * (Width - 1) + Range div 2) div Range
  else
    HandlePos := 0;

  for Col := 0 to Width - 1 do
  begin
    if Col = HandlePos then Ch := Ord('o') else Ch := Ord('-');
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + Col, Y, Ch,
      MDefaultFg, MDefaultBg, []);
  end;

  Result := Value <> Before;
end;

{ Shared row-drawing helper for MListView/MMenuBar/MDropdownList: writes S
  left-aligned into exactly Width cells (padding with spaces, or clipping
  S if it's longer), so a selected/highlighted row's reverse-video style
  covers the row's full width rather than stopping wherever the caption
  text itself ends. }
procedure DrawRowClipped(var Buf: TCellBuffer; ClipX, ClipY, ClipW, ClipH,
  X, Y, Width: Integer; const S: string; Style: TMCellStyle);
var
  I, CX, Consumed: Integer;
  Ch: TMUInt32;
begin
  CX := X;
  Consumed := 0;
  I := 1;
  while Consumed < Width do
  begin
    if I <= Length(S) then
    begin
      Ch := Ord(S[I]);
      Inc(I);
    end
    else
      Ch := 32;
    MPutCodepointClipped(Buf, ClipX, ClipY, ClipW, ClipH, CX, Y, Ch,
      MDefaultFg, MDefaultBg, Style);
    Inc(CX);
    Inc(Consumed);
  end;
end;

function MTextInput(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y, Width: Integer;
  var Text: string; const Events: TMInputEventArray): Boolean;
var
  ID: TMWidgetID;
  R: TMRect;
  St: PMWidgetState;
  Focused: Boolean;
  Before: string;
  I, GX, Idx, Col: Integer;
  BaseStyle, Style: TMCellStyle;
  Ch: TMUInt32;
begin
  ID := MWidgetID(Name);
  if Width < 1 then Width := 1;
  R := MMakeRect(X, Y, Width, 1);
  MRegisterHitRect(HR, ID, PaneID, R);
  St := MGetWidgetState(Core, ID);

  if St^.CursorPos < 0 then St^.CursorPos := 0;
  if St^.CursorPos > Length(Text) then St^.CursorPos := Length(Text);
  Before := Text;

  for I := 0 to High(Events) do
  begin
    if (Events[I].Kind = mekMouse) and (Events[I].Mouse.Action = maPress)
       and (Events[I].Mouse.Button = mbLeft)
       and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
    begin
      MSetFocus(Core, ID, PaneID);
      GX := St^.ScrollX + (Events[I].Mouse.X - X);
      if GX < 0 then GX := 0;
      if GX > Length(Text) then GX := Length(Text);
      St^.CursorPos := GX;
    end
    else if (Events[I].Kind = mekKey) and MIsFocused(Core, ID) then
    begin
      case Events[I].Key.Code of
        mkLeft:
          if St^.CursorPos > 0 then Dec(St^.CursorPos);
        mkRight:
          if St^.CursorPos < Length(Text) then Inc(St^.CursorPos);
        mkHome:
          St^.CursorPos := 0;
        mkEnd:
          St^.CursorPos := Length(Text);
        mkBackspace:
          if St^.CursorPos > 0 then
          begin
            Text := Copy(Text, 1, St^.CursorPos - 1) + Copy(Text, St^.CursorPos + 1, MaxInt);
            Dec(St^.CursorPos);
          end;
        mkDelete:
          if St^.CursorPos < Length(Text) then
            Text := Copy(Text, 1, St^.CursorPos) + Copy(Text, St^.CursorPos + 2, MaxInt);
        mkChar:
          { Printable ASCII only - MTextInput's TextBuf/Text is a plain
            Pascal string (bytes), and MPTI has no grapheme-cluster or
            multi-byte UTF-8-composition support anywhere else either (see
            MptiCell's doc comment on MPutCodepoint); a DAW's field names/
            tempo values/file-save names realistically need ASCII entry,
            not full Unicode text editing. }
          if (Events[I].Key.CodePoint >= 32) and (Events[I].Key.CodePoint <= 126) then
          begin
            Text := Copy(Text, 1, St^.CursorPos) + Chr(Events[I].Key.CodePoint)
              + Copy(Text, St^.CursorPos + 1, MaxInt);
            Inc(St^.CursorPos);
          end;
      end;
    end;
  end;

  if St^.CursorPos < 0 then St^.CursorPos := 0;
  if St^.CursorPos > Length(Text) then St^.CursorPos := Length(Text);

  { Scroll-follows-caret: keep CursorPos inside [ScrollX, ScrollX+Width). }
  if St^.CursorPos < St^.ScrollX then St^.ScrollX := St^.CursorPos;
  if St^.CursorPos > St^.ScrollX + Width - 1 then St^.ScrollX := St^.CursorPos - Width + 1;
  if St^.ScrollX < 0 then St^.ScrollX := 0;

  Focused := MIsFocused(Core, ID);
  if Focused then BaseStyle := [csUnderline] else BaseStyle := [];

  for Col := 0 to Width - 1 do
  begin
    Idx := St^.ScrollX + Col;
    if Idx < Length(Text) then Ch := Ord(Text[Idx + 1]) else Ch := 32;
    Style := BaseStyle;
    if Focused and (Idx = St^.CursorPos) then Style := [csReverse];
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + Col, Y, Ch,
      MDefaultFg, MDefaultBg, Style);
  end;

  Result := Text <> Before;
end;

function MListView(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y, Width, Height: Integer;
  const Items: array of string; var Selected, ScrollOffset: Integer;
  const Events: TMInputEventArray): Boolean;
var
  ID: TMWidgetID;
  R: TMRect;
  MaxScroll, Before, Row, Idx, I: Integer;
  Style: TMCellStyle;
begin
  ID := MWidgetID(Name);
  if Width < 1 then Width := 1;
  if Height < 1 then Height := 1;
  R := MMakeRect(X, Y, Width, Height);
  MRegisterHitRect(HR, ID, PaneID, R);

  if Length(Items) = 0 then
    Selected := -1
  else
  begin
    if Selected < 0 then Selected := 0;
    if Selected > High(Items) then Selected := High(Items);
  end;
  Before := Selected;

  MaxScroll := Length(Items) - Height;
  if MaxScroll < 0 then MaxScroll := 0;

  for I := 0 to High(Events) do
  begin
    if (Events[I].Kind = mekMouse) and (Events[I].Mouse.Action = maPress)
       and (Events[I].Mouse.Button = mbLeft)
       and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
    begin
      MSetFocus(Core, ID, PaneID);
      Row := ScrollOffset + (Events[I].Mouse.Y - Y);
      if (Row >= 0) and (Row < Length(Items)) then Selected := Row;
    end
    else if (Events[I].Kind = mekMouse) and (Events[I].Mouse.Action = maPress)
       and (Events[I].Mouse.Button = mbWheelUp)
       and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
      Dec(ScrollOffset)
    else if (Events[I].Kind = mekMouse) and (Events[I].Mouse.Action = maPress)
       and (Events[I].Mouse.Button = mbWheelDown)
       and MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
      Inc(ScrollOffset)
    else if (Events[I].Kind = mekKey) and MIsFocused(Core, ID) and (Length(Items) > 0) then
    begin
      case Events[I].Key.Code of
        mkUp:
          if Selected > 0 then Dec(Selected);
        mkDown:
          if Selected < High(Items) then Inc(Selected);
        mkPageUp:
          begin
            Selected := Selected - Height;
            if Selected < 0 then Selected := 0;
          end;
        mkPageDown:
          begin
            Selected := Selected + Height;
            if Selected > High(Items) then Selected := High(Items);
          end;
        mkHome:
          Selected := 0;
        mkEnd:
          Selected := High(Items);
      end;
    end;
  end;

  if Length(Items) = 0 then
    Selected := -1
  else
  begin
    if Selected < 0 then Selected := 0;
    if Selected > High(Items) then Selected := High(Items);
    { Auto-scroll to keep Selected visible. }
    if Selected < ScrollOffset then ScrollOffset := Selected;
    if Selected > ScrollOffset + Height - 1 then ScrollOffset := Selected - Height + 1;
  end;
  if ScrollOffset < 0 then ScrollOffset := 0;
  if ScrollOffset > MaxScroll then ScrollOffset := MaxScroll;

  for Row := 0 to Height - 1 do
  begin
    Idx := ScrollOffset + Row;
    if Idx < Length(Items) then
    begin
      if Idx = Selected then Style := [csReverse] else Style := [];
      DrawRowClipped(Buf, 0, 0, Buf.Width, Buf.Height, X, Y + Row, Width, Items[Idx], Style);
    end
    else
      DrawRowClipped(Buf, 0, 0, Buf.Width, Buf.Height, X, Y + Row, Width, '', []);
  end;

  Result := Selected <> Before;
end;

function MMenuBar(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Items: array of string;
  const Events: TMInputEventArray): Integer;
var
  ID, ItemID: TMWidgetID;
  St: PMWidgetState;
  OpenIndex: Integer;
  ItemX, ItemW, CX, I, K: Integer;
  R: TMRect;
  Style: TMCellStyle;
begin
  ID := MWidgetID(Name);
  St := MGetWidgetState(Core, ID);
  OpenIndex := St^.SelectStart; { -1 on first creation, per MGetWidgetState's init }

  ItemX := X;
  for I := 0 to High(Items) do
  begin
    ItemID := MWidgetID(Name + '/' + DecStr(I));
    ItemW := Length(Items[I]) + 2; { one space padding each side }
    R := MMakeRect(ItemX, Y, ItemW, 1);
    MRegisterHitRect(HR, ItemID, PaneID, R);

    for K := 0 to High(Events) do
      if (Events[K].Kind = mekMouse) and (Events[K].Mouse.Action = maPress)
         and (Events[K].Mouse.Button = mbLeft)
         and MRectContains(R, Events[K].Mouse.X, Events[K].Mouse.Y) then
      begin
        if OpenIndex = I then OpenIndex := -1 else OpenIndex := I;
      end;

    if OpenIndex = I then Style := [csReverse] else Style := [];
    CX := ItemX;
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX, Y, 32, MDefaultFg, MDefaultBg, Style);
    Inc(CX);
    for K := 1 to Length(Items[I]) do
    begin
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX, Y, Ord(Items[I][K]),
        MDefaultFg, MDefaultBg, Style);
      Inc(CX);
    end;
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX, Y, 32, MDefaultFg, MDefaultBg, Style);

    ItemX := ItemX + ItemW + 1; { one blank column of separation between labels }
  end;

  for K := 0 to High(Events) do
    if (Events[K].Kind = mekKey) and (Events[K].Key.Code = mkEscape) then
      OpenIndex := -1;

  St^.SelectStart := OpenIndex;
  Result := OpenIndex;
end;

function MDropdownList(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
  const Name: string; PaneID: TMWidgetID; X, Y: Integer; const Items: array of string;
  const Events: TMInputEventArray): Integer;
var
  ID: TMWidgetID;
  St: PMWidgetState;
  R: TMRect;
  Width, Height, MaxLen, I, Row: Integer;
  Highlighted, SelectedIdx: Integer;
  Cancelled: Boolean;
  Style: TMCellStyle;
begin
  ID := MWidgetID(Name);
  St := MGetWidgetState(Core, ID);
  { A popup only ever exists while the app keeps calling this each frame
    (immediate mode), so it always owns input focus for that duration -
    see interface doc comment. }
  MSetFocus(Core, ID, PaneID);

  MaxLen := 0;
  for I := 0 to High(Items) do
    if Length(Items[I]) > MaxLen then MaxLen := Length(Items[I]);
  Width := MaxLen + 4; { border + 1 space padding each side }
  Height := Length(Items) + 2; { top/bottom border }
  R := MMakeRect(X, Y, Width, Height);
  MRegisterHitRect(HR, ID, PaneID, R);

  Highlighted := St^.CursorPos;
  if Length(Items) = 0 then Highlighted := 0
  else
  begin
    if Highlighted < 0 then Highlighted := 0;
    if Highlighted > High(Items) then Highlighted := High(Items);
  end;
  SelectedIdx := -1;
  Cancelled := False;

  for I := 0 to High(Events) do
  begin
    if Events[I].Kind = mekKey then
    begin
      case Events[I].Key.Code of
        mkEscape:
          Cancelled := True;
        mkUp:
          if Highlighted > 0 then Dec(Highlighted);
        mkDown:
          if Highlighted < High(Items) then Inc(Highlighted);
        mkEnter:
          if Length(Items) > 0 then SelectedIdx := Highlighted;
      end;
    end
    else if Events[I].Kind = mekMouse then
    begin
      Row := Events[I].Mouse.Y - Y - 1; { content starts one row below the top border }
      if (Events[I].Mouse.Action = maMove) or (Events[I].Mouse.Action = maDrag) then
      begin
        if MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y)
           and (Row >= 0) and (Row < Length(Items)) then
          Highlighted := Row;
      end
      else if (Events[I].Mouse.Action = maPress) and (Events[I].Mouse.Button = mbLeft) then
      begin
        if not MRectContains(R, Events[I].Mouse.X, Events[I].Mouse.Y) then
          Cancelled := True
        else if (Row >= 0) and (Row < Length(Items)) then
        begin
          Highlighted := Row;
          SelectedIdx := Row;
        end;
      end;
    end;
  end;

  St^.CursorPos := Highlighted;

  MDrawPane(Buf, X, Y, Width, Height, '');
  for Row := 0 to High(Items) do
  begin
    if Row = Highlighted then Style := [csReverse] else Style := [];
    DrawRowClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + 1, Y + 1 + Row, Width - 2,
      ' ' + Items[Row], Style);
  end;

  if Cancelled then Result := -2
  else Result := SelectedIdx;
end;

procedure MDrawPane(var Buf: TCellBuffer; X, Y, W, H: Integer; const Title: string);
const
  { Box-drawing glyphs (U+2500 family) for a solid pane border, in place
    of plain-ASCII '+'/'-'/'|'. Every xterm-family terminal MPTI targets,
    including Tiger's stock xterm (mpti.md req. 6), has shipped these
    since well before CP437-only hardware became irrelevant, so this is
    safe as MPTI's unconditional default rather than a capability
    -negotiated fallback - a stylistic choice that applies to every MPTI
    app, not just Dysnomia. }
  GlyphHLine = $2500;
  GlyphVLine = $2502;
  GlyphTL    = $250C;
  GlyphTR    = $2510;
  GlyphBL    = $2514;
  GlyphBR    = $2518;
var
  Row, Col, TX, I: Integer;
begin
  if (W < 2) or (H < 2) then Exit; { too small to have both a border and interior }

  for Col := 0 to W - 1 do
  begin
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + Col, Y, GlyphHLine,
      MDefaultFg, MDefaultBg, []);
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + Col, Y + H - 1, GlyphHLine,
      MDefaultFg, MDefaultBg, []);
  end;
  for Row := 0 to H - 1 do
  begin
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X, Y + Row, GlyphVLine,
      MDefaultFg, MDefaultBg, []);
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + W - 1, Y + Row, GlyphVLine,
      MDefaultFg, MDefaultBg, []);
  end;
  MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X, Y, GlyphTL, MDefaultFg, MDefaultBg, []);
  MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + W - 1, Y, GlyphTR, MDefaultFg, MDefaultBg, []);
  MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X, Y + H - 1, GlyphBL, MDefaultFg, MDefaultBg, []);
  MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + W - 1, Y + H - 1, GlyphBR, MDefaultFg, MDefaultBg, []);

  for Row := 1 to H - 2 do
    for Col := 1 to W - 2 do
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + Col, Y + Row, 32,
        MDefaultFg, MDefaultBg, []);

  if Title <> '' then
  begin
    TX := X + 2;
    for I := 1 to Length(Title) do
    begin
      if TX >= X + W - 2 then Break; { leave the closing border/corner alone }
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, TX, Y, Ord(Title[I]),
        MDefaultFg, MDefaultBg, []);
      Inc(TX);
    end;
  end;
end;

procedure MIndicatorLight(var Buf: TCellBuffer; X, Y: Integer; OnState: Boolean);
var
  Fg: TMColor;
  Ch: TMUInt32;
begin
  if OnState then
  begin
    Fg := MMakeColor(0, 255, 0);
    Ch := Ord('@');
  end
  else
  begin
    Fg := MMakeColor(64, 64, 64);
    Ch := Ord('.');
  end;
  MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X, Y, Ch, Fg, MDefaultBg, []);
end;

procedure MMeterH(var Buf: TCellBuffer; X, Y, Width: Integer; Value, Max: Integer);
var
  Filled, Col: Integer;
  Ch: TMUInt32;
  Fg: TMColor;
begin
  if Width < 1 then Exit;
  if Max < 1 then Max := 1;
  if Value < 0 then Value := 0;
  if Value > Max then Value := Max;
  Filled := (Value * Width) div Max;

  for Col := 0 to Width - 1 do
  begin
    if Col < Filled then
    begin
      Ch := Ord('#');
      Fg := MMakeColor(0, 220, 0);
    end
    else
    begin
      Ch := Ord('.');
      Fg := MDefaultFg;
    end;
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + Col, Y, Ch, Fg, MDefaultBg, []);
  end;
end;

procedure MMeterV(var Buf: TCellBuffer; X, Y, Height: Integer; Value, Max: Integer);
var
  Filled, Row: Integer;
  Ch: TMUInt32;
  Fg: TMColor;
begin
  if Height < 1 then Exit;
  if Max < 1 then Max := 1;
  if Value < 0 then Value := 0;
  if Value > Max then Value := Max;
  Filled := (Value * Height) div Max;

  for Row := 0 to Height - 1 do
  begin
    { Row 0 is the top; the meter fills upward from the bottom, so the
      bottom-most Filled rows are lit. }
    if Row >= Height - Filled then
    begin
      Ch := Ord('#');
      Fg := MMakeColor(0, 220, 0);
    end
    else
    begin
      Ch := Ord('.');
      Fg := MDefaultFg;
    end;
    MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X, Y + Row, Ch, Fg, MDefaultBg, []);
  end;
end;

procedure MProgressBar(var Buf: TCellBuffer; X, Y, Width: Integer; Value, Max: Integer);
var
  BarWidth, Filled, Col, CX, Pct, I: Integer;
  PctStr: string;
begin
  if Width < 3 then Exit; { need room for at least "[ ]" }
  if Max < 1 then Max := 1;
  if Value < 0 then Value := 0;
  if Value > Max then Value := Max;
  Pct := (Value * 100) div Max;
  PctStr := DecStr(Pct) + '%';

  if Width > Length(PctStr) + 1 + 2 then
    BarWidth := Width - Length(PctStr) - 1
  else
    BarWidth := Width;

  MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X, Y, Ord('['), MDefaultFg, MDefaultBg, []);
  MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + BarWidth - 1, Y, Ord(']'),
    MDefaultFg, MDefaultBg, []);

  Filled := ((BarWidth - 2) * Value) div Max;
  for Col := 0 to BarWidth - 3 do
  begin
    if Col < Filled then
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + 1 + Col, Y, Ord('#'),
        MDefaultFg, MDefaultBg, [])
    else
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X + 1 + Col, Y, Ord('-'),
        MDefaultFg, MDefaultBg, []);
  end;

  if BarWidth < Width then
  begin
    CX := X + BarWidth + 1;
    for I := 1 to Length(PctStr) do
    begin
      MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, CX, Y, Ord(PctStr[I]),
        MDefaultFg, MDefaultBg, []);
      Inc(CX);
    end;
  end;
end;

procedure MBusyIndicator(const Core: TMCoreState; var Buf: TCellBuffer; X, Y: Integer);
const
  Frames: array[0..3] of Char = ('|', '/', '-', '\');
var
  Idx: Integer;
begin
  Idx := Integer(Core.FrameCounter mod 4);
  MPutCodepointClipped(Buf, 0, 0, Buf.Width, Buf.Height, X, Y, Ord(Frames[Idx]),
    MDefaultFg, MDefaultBg, []);
end;

end.
