{
  Headless/fake driver (mpti.md Phase 4, hard requirement/goal #9: fully
  testable without a real terminal). MptiDriver owns a live fd and can
  only be meaningfully exercised against a real pty (src/mpti/tests -
  mptidrivertest.lpr + drive_pty.py). This unit is the substitute used by
  ordinary automated tests: it combines the same two headless-safe pieces
  MptiDriver combines around a live fd - MptiInput's parser and
  MptiRender's diff renderer - around a *scripted* input queue and a
  virtual screen instead.

  Unlike MptiDriver, there is no select()/blocking here at all: a
  headless script is deterministic by construction (the test decides
  exactly what bytes arrive and when a resize happens), so
  MHeadlessFeedInput/MHeadlessResize are called directly by the test
  rather than discovered via a run-loop. This intentionally does not
  mirror MRunOnce's polling shape - there is nothing to poll.

  What this unit gives later phases (6+ widget/layout code) once it
  exists: drive a widget frame with scripted keyboard/mouse/paste input,
  call MHeadlessRenderFrame, then assert against MHeadlessScreen's
  TCellBuffer or the emitted ANSI bytes - a full input-to-pixels round
  trip with no human at a terminal. Nothing widget-shaped exists yet
  (Phase 6+), so this phase's own tests exercise the plumbing directly:
  scripted bytes decode to the same events MptiInput's unit tests
  already prove, a resize invalidates the virtual screen and forces a
  full redraw, and a manually-drawn cell survives the input -> render ->
  assert round trip.
}
unit MptiHeadless;

{$mode objfpc}{$H+}

interface

uses
  MptiTypes, MptiCell, MptiCaps, MptiInput, MptiRender;

type
  TMHeadlessState = record
    ParseState: TMInputParseState;
    Caps: TMTermCaps;
    Cols, Rows: Integer;
    Render: TMRenderState;
  end;

procedure MInitHeadless(out D: TMHeadlessState; const Caps: TMTermCaps;
  Cols, Rows: Integer);

{ Feeds scripted bytes through the same parser MptiDriver uses on a real
  fd, appending decoded events to Events. Split across multiple calls
  exactly like a real fd's short reads would be - State.ParseState
  carries incomplete sequences across calls exactly as it does for
  MptiDriver. }
procedure MHeadlessFeedInput(var D: TMHeadlessState; const Data: array of Byte;
  var Events: TMInputEventArray);

{ Simulates MptiDriver's escape-ambiguity timeout firing: a lone pending
  ESC with nothing following resolves to a literal Escape keypress. }
procedure MHeadlessFlushPendingEscape(var D: TMHeadlessState;
  var Events: TMInputEventArray);

{ Simulates a SIGWINCH-driven resize: updates Cols/Rows and resizes the
  virtual screen, which (via MResizeRenderState) forces the next
  MHeadlessRenderFrame back to a full redraw - the virtual screen's prior
  contents at the old size are no longer meaningful, exactly as a real
  terminal's actual on-screen contents at a new size are unknown to
  MptiRender until it redraws everything. }
procedure MHeadlessResize(var D: TMHeadlessState; NewCols, NewRows: Integer);

{ Draws into the virtual screen's back buffer - what a widget/layout
  layer will do once it exists (Phase 6+); tests drive this directly for
  now. Same unchecked-by-design contract as MSetCell. }
procedure MHeadlessSetCell(var D: TMHeadlessState; X, Y: Integer; const C: TCell); inline;

{ Diffs the back buffer against what the virtual screen currently shows,
  appending the emitted ANSI to Output (reset to empty first) exactly as
  MRenderDiff does against a real terminal - just never written to an fd. }
procedure MHeadlessRenderFrame(var D: TMHeadlessState; var Output: TMByteBuf);

{ What the virtual screen displays right now (i.e. after the most recent
  MHeadlessRenderFrame) - the assertion target for "did the framework
  draw the right thing." Read-only by contract: the returned TCellBuffer
  shares its Cells array with D.Render.Front (no defensive copy, per hard
  requirement 13), so callers must treat it as a snapshot to inspect, not
  a buffer to mutate - writing through it corrupts the live front buffer. }
function MHeadlessScreen(const D: TMHeadlessState): TCellBuffer; inline;

implementation

procedure MInitHeadless(out D: TMHeadlessState; const Caps: TMTermCaps;
  Cols, Rows: Integer);
begin
  MInitInputParseState(D.ParseState);
  D.Caps := Caps;
  D.Cols := Cols;
  D.Rows := Rows;
  MInitRenderState(D.Render, Caps, Cols, Rows);
end;

procedure MHeadlessFeedInput(var D: TMHeadlessState; const Data: array of Byte;
  var Events: TMInputEventArray);
begin
  MFeedInput(D.ParseState, Data, Events);
end;

procedure MHeadlessFlushPendingEscape(var D: TMHeadlessState;
  var Events: TMInputEventArray);
begin
  MFlushPendingEscape(D.ParseState, Events);
end;

procedure MHeadlessResize(var D: TMHeadlessState; NewCols, NewRows: Integer);
begin
  D.Cols := NewCols;
  D.Rows := NewRows;
  MResizeRenderState(D.Render, NewCols, NewRows);
end;

procedure MHeadlessSetCell(var D: TMHeadlessState; X, Y: Integer; const C: TCell); inline;
begin
  MSetCell(D.Render.Back, X, Y, C);
end;

procedure MHeadlessRenderFrame(var D: TMHeadlessState; var Output: TMByteBuf);
begin
  MRenderDiff(D.Render, Output);
end;

function MHeadlessScreen(const D: TMHeadlessState): TCellBuffer; inline;
begin
  Result := D.Render.Front;
end;

end.
