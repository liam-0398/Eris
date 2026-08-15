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

end.
