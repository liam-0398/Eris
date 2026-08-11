unit Theme;

{$mode objfpc}{$H+}

{ The palette every painted surface in Eris resolves its colours through.

  It works by shadowing rather than by rewriting call sites. The six functions
  below are named exactly like the LCL system colours the drawing code already
  used - clBtnFace, clWindow and so on - so a unit that lists Theme AFTER
  Graphics in its uses clause silently resolves those names here instead. That
  is why adding one unit name to seven uses clauses re-points roughly sixty
  painting sites, and why none of them had to be touched.

  Object Pascal resolves identifiers right-to-left through the uses clause, and
  a parameterless function is callable without parentheses in objfpc mode,
  so `Canvas.Brush.Color := clBtnFace` keeps compiling and simply means
  something different. The catch to remember when reading the painting code:
  those names are no longer constants, and this unit must therefore qualify
  Graphics.clBtnFace explicitly below or it would call itself forever.

  Track waveform colours are deliberately NOT routed through here. They come
  from ArrangementView's own FTrackColors and identify a track; theming them
  would destroy the thing they exist to communicate. }

interface

uses
  Graphics;

{ Modes are Config's ThemeSystem / ThemeLight / ThemeDark values - the same
  integers that get persisted - rather than a private enum, so nothing has to
  translate between the two.

  System means genuine passthrough: the real LCL system colours, exactly as
  the drawing code saw them before this unit existed. On a dark desktop theme
  the app therefore goes dark on its own, and the native widgets that ignore
  any colour we set them (trackbars, comboboxes, menus) go dark WITH it - the
  one mode where there is no mismatch to live with. It is also the default,
  which is what makes installing this unit a visual no-op.

  Light and Dark pin literal values and stop following the desktop. }
procedure ThemeSetMode(AMode: Integer);
function ThemeGetMode: Integer;
function ThemeIsDark: Boolean;

{ Deliberately shadowing Graphics' constants of the same name - see above. }
function clBtnFace: TColor;
function clWindow: TColor;
function clWindowText: TColor;
function clBtnShadow: TColor;
function clHighlight: TColor;
function clWindowFrame: TColor;

implementation

uses
  SysUtils, Config;

var
  FMode: Integer = ThemeSystem;
  { Latched on the first ThemeSetMode so the environment is read once rather
    than on every repaint. }
  FOverrideChecked: Boolean = False;
  FOverride: Integer = -1;

{ A development override, so the phases that build dark mode before there is
  any UI to select it are not written blind. ERIS_THEME=dark|light|system beats
  both the config file and (later) the Preferences dropdown - an override that
  could be silently countermanded by whatever was last saved would be useless
  for looking at a change. Unset, which is every normal launch, changes
  nothing. }
procedure CheckOverride;
var
  S: string;
begin
  if FOverrideChecked then
    Exit;
  FOverrideChecked := True;

  S := GetEnvironmentVariable('ERIS_THEME');
  if S = '' then
    Exit;
  if SameText(S, 'dark') then
    FOverride := ThemeDark
  else if SameText(S, 'light') then
    FOverride := ThemeLight
  else if SameText(S, 'system') then
    FOverride := ThemeSystem;
end;

procedure ThemeSetMode(AMode: Integer);
begin
  CheckOverride;
  if FOverride >= 0 then
    FMode := FOverride
  else
    FMode := AMode;
end;

function ThemeGetMode: Integer;
begin
  Result := FMode;
end;

{ Only an explicitly pinned Dark counts. System is passthrough even on a dark
  desktop: the LCL hands back dark system colours by itself there, and this
  unit has no business claiming to know which way a GTK theme leans. }
function ThemeIsDark: Boolean;
begin
  Result := FMode = ThemeDark;
end;

{ ---------------------------------------------------------------------------
  The palettes.

  Written with RGBToColor rather than $00BBGGRR literals on purpose - TColor
  stores blue in the high byte, so hex triplets read backwards from every
  colour picker and quietly invite transposed channels.

  Light is close to a stock light desktop, so switching System -> Light is a
  small step rather than a jolt.

  Dark is not Light inverted, and the borders are why. clBtnShadow names an
  edge that is DARKER than the surface it sits on, which only holds on a light
  background; inverting a mid grey returns almost the same mid grey and the
  separators would dissolve into the panels. On a dark surface the edge has to
  go lighter instead, so clBtnShadow rises above clBtnFace here rather than
  falling below it - the one relationship in the palette that flips direction.

  Text is deliberately not pure white either. Light-on-dark blooms under both
  Cairo's and ClearType's subpixel rendering, and pure white maximises it;
  backing off to a bright grey keeps weight closer to what the light theme
  looks like, and closer between the two platforms.
  --------------------------------------------------------------------------- }

function clBtnFace: TColor;
begin
  case FMode of
    ThemeLight: Result := RGBToColor(240, 240, 240);
    ThemeDark: Result := RGBToColor(48, 48, 48);
  else
    Result := Graphics.clBtnFace;
  end;
end;

{ The canvas colour - the arrangement's backdrop and the editors'. Sits below
  clBtnFace in both palettes so the working area reads as recessed against the
  chrome around it. }
function clWindow: TColor;
begin
  case FMode of
    ThemeLight: Result := RGBToColor(255, 255, 255);
    ThemeDark: Result := RGBToColor(30, 30, 30);
  else
    Result := Graphics.clWindow;
  end;
end;

function clWindowText: TColor;
begin
  case FMode of
    ThemeLight: Result := RGBToColor(0, 0, 0);
    ThemeDark: Result := RGBToColor(208, 208, 208);
  else
    Result := Graphics.clWindowText;
  end;
end;

function clBtnShadow: TColor;
begin
  case FMode of
    ThemeLight: Result := RGBToColor(160, 160, 160);
    ThemeDark: Result := RGBToColor(90, 90, 90);
  else
    Result := Graphics.clBtnShadow;
  end;
end;

{ Selection fill. Muted rather than saturated in Dark, because it has to carry
  clWindowText on top of it and a vivid blue leaves that text barely legible. }
function clHighlight: TColor;
begin
  case FMode of
    ThemeLight: Result := RGBToColor(51, 153, 255);
    ThemeDark: Result := RGBToColor(38, 79, 120);
  else
    Result := Graphics.clHighlight;
  end;
end;

{ The hard outline drawn around selected regions. Stays near-black in Dark:
  it is read as a crisp boundary against the highlight fill, not as a shadow,
  so unlike clBtnShadow it does not want lifting. }
function clWindowFrame: TColor;
begin
  case FMode of
    ThemeLight: Result := RGBToColor(0, 0, 0);
    ThemeDark: Result := RGBToColor(16, 16, 16);
  else
    Result := Graphics.clWindowFrame;
  end;
end;

end.
