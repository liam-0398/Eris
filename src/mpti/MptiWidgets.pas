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

implementation

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

function MToggleButton(var Core: TMCoreState; var HR: TMHitRegistry; var Buf: TCellBuffer;
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

end.
