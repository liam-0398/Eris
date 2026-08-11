unit UIScale;

{$mode objfpc}{$H+}

interface

uses
  Forms, SysUtils;

{ Every widget in this app is built by hand in code with hardcoded pixel
  offsets, which the LCL's own design-time auto-scaling never sees (that
  machinery only rescales controls placed via a .lfm). Px() rescales a
  hand-picked "design" pixel value according to the display environment:
  - On Wayland with HiDPI: uses Screen.PixelsPerInch scaling (handles 150% scale etc)
  - Everywhere else (Xorg, Windows): 1:1, design pixels as written }
function Px(ADesignPixels: Integer): Integer;

implementation

function IsWaylandSession: Boolean;
begin
  { WAYLAND_DISPLAY is only ever set by a live Wayland compositor - unlike
    XDG_SESSION_TYPE, which can be stale/wrong when leftover from a previous
    login or overridden by GDK_BACKEND=x11 forcing an XWayland/X11 run. }
  Result := GetEnvironmentVariable('WAYLAND_DISPLAY') <> '';
end;

function Px(ADesignPixels: Integer): Integer;
begin
  if IsWaylandSession then
    { Wayland: use DPI-based scaling (handles HiDPI, 150% scale, etc.) }
    Result := Round(ADesignPixels * Screen.PixelsPerInch / 96)
  else
    { Xorg and Windows: none. The multiplier here has come down over time
      (1.5x, then 1.125x, then 1.05x, all of which still read bulkier than
      the design sizes), and at 1.0 the hand-placed pixel values are simply
      taken as written. Narrow vertical TTrackBars (e.g. the EQ4 gain
      sliders) already get their extra travel room directly in EffectsRack
      rather than from this multiplier, so nothing depends on it being > 1. }
    Result := ADesignPixels;
end;

end.
