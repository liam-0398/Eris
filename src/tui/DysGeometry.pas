unit DysGeometry;

{ Fluid layout math for Dysnomia. One code path covers 1024x768 through
  1920x1080 and beyond - every pane is computed from the live grid size,
  nothing is hand-tuned per resolution. See tui.md, "Variable resolution". }

{$mode objfpc}{$H+}

interface

uses
  Objects;

const
  MinCols = 100;
  MinRows = 30;

  { Legacy xterm mouse mode (1000) encodes column/row in one byte each and
    caps at 223. SGR mode (1006) lifts that cap but Tiger's X11 shipped an
    xterm that predates it, so the G4 build assumes the worst case and
    clamps.

    The Linux build carries no such clamp: packages/rtl-console/src/unix/
    mouse.pp (SysInitMouse) and keyboard.pp (GenMouseEvent_ExtendedSGR1006)
    already send "ESC[?1006h" unconditionally at mouse-init and parse
    whichever report format comes back - X10 (`ESC[M`) or SGR (`ESC[<`).
    That negotiation is automatic and applies to both x86_64-linux and
    powerpc-darwin, since Darwin (outside iOS) builds from the same
    src/unix sources. What differs is not the toolchain, it's whether the
    terminal on the other end understands 1006 - which for a real Tiger
    xterm it doesn't, and for anything a Linux user is likely running it
    does. Hence the ifdef: assume the worst on the platform where the old
    terminal is a certainty, trust the negotiation everywhere else. }
{$ifdef DARWIN}
  MaxCols = 223;
{$else}
  MaxCols = 255; { Free Vision's own ceiling - ScreenWidth is a Byte
                    (Drivers.MaxViewWidth) - not a Dysnomia-imposed cap. }
{$endif}

  FilePaneWidth = 24;
  TrackPaneWidth = 8;
  ToolBarHeight = 1;
  BottomBarHeight = 1;

type
  TDysLayout = record
    TooSmall: Boolean;
    Cols, Rows: Integer;
    ToolBar, FilePane, TrackPane, Timeline, BottomBar: TRect;
  end;

function ComputeLayout(Extent: TRect): TDysLayout;

implementation

function ComputeLayout(Extent: TRect): TDysLayout;
var
  W, H, BodyTop, BodyBottom: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  W := Extent.B.X - Extent.A.X;
  H := Extent.B.Y - Extent.A.Y;
  if W > MaxCols then
    W := MaxCols;

  Result.Cols := W;
  Result.Rows := H;
  Result.TooSmall := (W < MinCols) or (H < MinRows);
  if Result.TooSmall then
    Exit;

  { Row 0 of Extent is the menu bar and the last row is the status line -
    both already carved out by TApplication before this is called. }
  Result.ToolBar.Assign(Extent.A.X, Extent.A.Y, Extent.A.X + W,
    Extent.A.Y + ToolBarHeight);

  BodyTop := Result.ToolBar.B.Y;
  BodyBottom := Extent.B.Y - BottomBarHeight;

  Result.BottomBar.Assign(Extent.A.X, BodyBottom, Extent.A.X + W,
    BodyBottom + BottomBarHeight);

  Result.FilePane.Assign(Extent.A.X, BodyTop, Extent.A.X + FilePaneWidth,
    BodyBottom);
  Result.TrackPane.Assign(Extent.A.X + W - TrackPaneWidth, BodyTop,
    Extent.A.X + W, BodyBottom);
  Result.Timeline.Assign(Result.FilePane.B.X, BodyTop,
    Result.TrackPane.A.X, BodyBottom);
end;

end.
