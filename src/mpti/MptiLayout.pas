{
  Reusable layout primitives (mpti.md Phase 6, mpti.md #6). Generalizes
  what DysGeometry.ComputeLayout (src/tui, read-only reference) did by
  hand for one specific app: DysGeometry is a single hardcoded function
  that carves a fixed top toolbar, a fixed bottom bar, two fixed-width
  side columns, and treats whatever's left as one fluid middle pane -
  called exactly once, at startup, with no resize hook at all (confirmed
  by reading it: TDysnomiaApp.InitDeskTop calls it once during Init;
  nothing ever calls it again on SIGWINCH).

  MptiLayout does not hardcode any app's specific pane arrangement -
  that's app-level policy, out of MPTI's scope. What it provides instead
  is: (1) the same "peel a fixed-size strip off one edge, keep the
  remainder" primitive DysGeometry used inline, exposed as reusable
  MSplit* functions any app-level layout function can chain to build
  its own arrangement, and (2) the live-resize wiring DysGeometry never
  had - mpti.md #6 says resize is a first-class event delivered through
  the same queue as keyboard/mouse, not something every app hand-rolls,
  so MLayoutOnResize both updates the tracked extent AND posts a
  reserved-Kind TMQueueMsg through the Phase 5 event queue, giving
  anything downstream (not just the immediate layout consumer) one
  consistent way to learn "the terminal resized."
}
unit MptiLayout;

{$mode objfpc}{$H+}

interface

uses
  MptiTypes, MptiQueue;

const
  { Reserved TMQueueMsg.Kind for a resize notification: Param1 = new
    Cols, Param2 = new Rows, Data unused. Every other Kind value is free
    for app use - MPTI only ever reserves this one. }
  MQueueKindResize = 1;

type
  TMRect = record
    X, Y, W, H: Integer;
  end;

function MMakeRect(X, Y, W, H: Integer): TMRect; inline;
function MRectEmpty(const R: TMRect): Boolean; inline;
function MRectFits(const R: TMRect; MinW, MinH: Integer): Boolean; inline;
function MRectContains(const R: TMRect; X, Y: Integer): Boolean; inline;

{ Shrinks R by Amount on all four sides (e.g. carving a bordered
  widget's content area out of its own rect). Clamped so W/H never go
  negative - an inset larger than the rect just yields an empty rect
  rather than wrapping around. }
function MRectInset(const R: TMRect; Amount: Integer): TMRect;

{ Peels a strip of thickness Amount off one edge of R into Taken,
  leaving the rest in Remainder. Amount is clamped to R's own extent
  along that axis first, so Remainder's size is never negative -
  requesting more than R has just consumes all of it. This is the exact
  primitive DysGeometry.ComputeLayout used inline (via TRect.Assign
  arithmetic) to carve its toolbar/bottom-bar/side-columns; here it's
  reusable and composable instead of hardcoded per-app. }
procedure MSplitLeft(const R: TMRect; Amount: Integer; out Taken, Remainder: TMRect);
procedure MSplitRight(const R: TMRect; Amount: Integer; out Taken, Remainder: TMRect);
procedure MSplitTop(const R: TMRect; Amount: Integer; out Taken, Remainder: TMRect);
procedure MSplitBottom(const R: TMRect; Amount: Integer; out Taken, Remainder: TMRect);

type
  TMLayoutState = record
    Extent: TMRect;  { current full-terminal extent: X=0, Y=0, W=Cols, H=Rows }
    Dirty: Boolean;  { True since the last resize until MLayoutClearDirty }
  end;

procedure MInitLayout(out L: TMLayoutState; Cols, Rows: Integer);

{ Call when a resize is detected (MptiDriver's dekResize / MptiHeadless's
  MHeadlessResize) - updates L.Extent, sets Dirty so the app's own
  layout function knows its cached rects are stale, and posts a
  MQueueKindResize message through Q so anything else downstream also
  learns about it through the same event queue mpti.md #6 asks for,
  rather than a resize-specific side channel. }
procedure MLayoutOnResize(var L: TMLayoutState; var Q: TMEventQueue; NewCols, NewRows: Integer);

{ Call once per frame after the app's own layout function has re-run (if
  Dirty was set) - clears Dirty until the next resize. }
procedure MLayoutClearDirty(var L: TMLayoutState);

implementation

function MMakeRect(X, Y, W, H: Integer): TMRect; inline;
begin
  Result.X := X;
  Result.Y := Y;
  Result.W := W;
  Result.H := H;
end;

function MRectEmpty(const R: TMRect): Boolean; inline;
begin
  Result := (R.W <= 0) or (R.H <= 0);
end;

function MRectFits(const R: TMRect; MinW, MinH: Integer): Boolean; inline;
begin
  Result := (R.W >= MinW) and (R.H >= MinH);
end;

function MRectContains(const R: TMRect; X, Y: Integer): Boolean; inline;
begin
  Result := (X >= R.X) and (X < R.X + R.W) and (Y >= R.Y) and (Y < R.Y + R.H);
end;

function MRectInset(const R: TMRect; Amount: Integer): TMRect;
begin
  Result.X := R.X + Amount;
  Result.Y := R.Y + Amount;
  Result.W := R.W - Amount * 2;
  Result.H := R.H - Amount * 2;
  if Result.W < 0 then Result.W := 0;
  if Result.H < 0 then Result.H := 0;
end;

procedure MSplitLeft(const R: TMRect; Amount: Integer; out Taken, Remainder: TMRect);
var
  A: Integer;
begin
  A := Amount;
  if A > R.W then A := R.W;
  if A < 0 then A := 0;
  Taken := MMakeRect(R.X, R.Y, A, R.H);
  Remainder := MMakeRect(R.X + A, R.Y, R.W - A, R.H);
end;

procedure MSplitRight(const R: TMRect; Amount: Integer; out Taken, Remainder: TMRect);
var
  A: Integer;
begin
  A := Amount;
  if A > R.W then A := R.W;
  if A < 0 then A := 0;
  Taken := MMakeRect(R.X + R.W - A, R.Y, A, R.H);
  Remainder := MMakeRect(R.X, R.Y, R.W - A, R.H);
end;

procedure MSplitTop(const R: TMRect; Amount: Integer; out Taken, Remainder: TMRect);
var
  A: Integer;
begin
  A := Amount;
  if A > R.H then A := R.H;
  if A < 0 then A := 0;
  Taken := MMakeRect(R.X, R.Y, R.W, A);
  Remainder := MMakeRect(R.X, R.Y + A, R.W, R.H - A);
end;

procedure MSplitBottom(const R: TMRect; Amount: Integer; out Taken, Remainder: TMRect);
var
  A: Integer;
begin
  A := Amount;
  if A > R.H then A := R.H;
  if A < 0 then A := 0;
  Taken := MMakeRect(R.X, R.Y + R.H - A, R.W, A);
  Remainder := MMakeRect(R.X, R.Y, R.W, R.H - A);
end;

procedure MInitLayout(out L: TMLayoutState; Cols, Rows: Integer);
begin
  L.Extent := MMakeRect(0, 0, Cols, Rows);
  L.Dirty := True; { first frame always needs an initial layout pass }
end;

procedure MLayoutOnResize(var L: TMLayoutState; var Q: TMEventQueue; NewCols, NewRows: Integer);
var
  Msg: TMQueueMsg;
begin
  L.Extent := MMakeRect(0, 0, NewCols, NewRows);
  L.Dirty := True;

  Msg.Kind := MQueueKindResize;
  Msg.Param1 := NewCols;
  Msg.Param2 := NewRows;
  Msg.Data := nil;
  MQueuePush(Q, Msg);
end;

procedure MLayoutClearDirty(var L: TMLayoutState);
begin
  L.Dirty := False;
end;

end.
