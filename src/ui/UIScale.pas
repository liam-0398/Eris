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
  - On Xorg: applies a fixed 1.05x scale to match Wayland HiDPI appearance }
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
    { Xorg: fixed 1.05x scale - every hand-placed size in this app assumes
      some scale applies (see unit comment), so leaving Xorg fully unscaled
      left every widget smaller than intended. 1.05x (down from 1.5x, then
      1.125x, both of which read too big/stock-GTK3-bulky) keeps widgets
      close to their designed size. Narrow vertical TTrackBars (e.g. the EQ4
      gain sliders) get their own extra travel room directly in EffectsRack
      instead of relying on this multiplier for it. }
    Result := Round(ADesignPixels * 1.05);
end;

end.
