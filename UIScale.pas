unit UIScale;

{$mode objfpc}{$H+}

interface

uses
  Forms;

{ Every widget in this app is built by hand in code with hardcoded pixel
  offsets, which the LCL's own design-time auto-scaling never sees (that
  machinery only rescales controls placed via a .lfm). On a HiDPI display
  (e.g. Xft.dpi 192 instead of the assumed 96) fonts render roughly twice as
  tall/wide as those offsets assume, so text overlaps its own box. Px()
  rescales a hand-picked "design" pixel value to the actual screen's DPI -
  wrap it around every hardcoded Top/Left/Width/Height/margin. }
function Px(ADesignPixels: Integer): Integer;

implementation

function Px(ADesignPixels: Integer): Integer;
begin
  Result := Round(ADesignPixels * Screen.PixelsPerInch / 96);
end;

end.
