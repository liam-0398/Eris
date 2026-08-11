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
  Graphics, Controls;

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

{ Recolours the native LCL widgets, which never see the painting code the six
  functions below serve - a TComboBox is a real GTK/Win32 widget and draws
  itself. Walks AControl and everything parented beneath it, so one call on a
  form covers every control on it whenever they happen to have been created.

  Does nothing at all in System mode: passthrough means leaving the widgets to
  the desktop theme, and pinning colours on them would be the opposite. }
procedure ThemeApply(AControl: TControl);

{ Put this in a control's Tag and ThemeApply will pass over it AND everything
  parented under it, leaving whatever colour it was built with.

  For controls whose colour carries meaning rather than chrome. The walk
  recolours every TPanel it meets, which is right for the panels used as
  containers and wrong for one used as a rule or a divider - that panel IS its
  colour, and repainting it as button face erases it. Tag rather than a
  registry so the exclusion lives on the control and cannot outlive it. }
const
  ThemeTagSkip = -31415;

{ Deliberately shadowing Graphics' constants of the same name - see above. }
function clBtnFace: TColor;
function clWindow: TColor;
function clWindowText: TColor;
function clBtnShadow: TColor;
function clHighlight: TColor;
function clWindowFrame: TColor;

{ The musical grid: bar, beat, and the subdivision between beats, in that
  order of weight. Ordinary names rather than shadowed ones, because the LCL
  has no system colour that means "an eighth-note line" - the six above are
  chrome, and the grid is the one thing drawn on the canvas that they cannot
  express. The editors reached for clBlack/clGray/clSilver instead, which is
  exactly the hierarchy these three keep, and exactly what breaks on a dark
  canvas: all three of those go the wrong way at once.

  Three levels rather than a shade-of-one-colour helper because the ratios
  between them are not uniform - see the palette note below. }
function ThemeGridBar: TColor;
function ThemeGridBeat: TColor;
function ThemeGridSub: TColor;

implementation

uses
  SysUtils, Forms, StdCtrls, ExtCtrls, Buttons, Config;

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

{ ---------------------------------------------------------------------------
  The grid.

  System returns the literals the editors used before these existed - clBlack,
  clGray, clSilver - so routing the grid through here costs nothing in the
  default mode. Light returns the same three values as real colours, so the
  step from System to Light does not move the grid either.

  Dark keeps the RATIO between the three rather than their contrast against
  the canvas. A bar line at 208 to match the light theme's black-on-white
  would be a row of bright rails across a dark editor, and the waveform drawn
  in the track's own colour has to stay the loudest thing in the view; the
  grid is scaffolding and should read as scaffolding. So the whole family is
  pitched down to sit just far enough above clWindow (30) to separate, and
  the same bloom that keeps clWindowText off pure white applies here with
  more force - these are hairlines, and a hairline blooms harder than a
  glyph.
  --------------------------------------------------------------------------- }

function ThemeGridBar: TColor;
begin
  case FMode of
    ThemeLight: Result := RGBToColor(0, 0, 0);
    ThemeDark: Result := RGBToColor(150, 150, 150);
  else
    Result := Graphics.clBlack;
  end;
end;

function ThemeGridBeat: TColor;
begin
  case FMode of
    ThemeLight: Result := RGBToColor(128, 128, 128);
    ThemeDark: Result := RGBToColor(95, 95, 95);
  else
    Result := Graphics.clGray;
  end;
end;

{ The faintest tier, and the one with no chrome equivalent at all: clBtnFace
  is the nearest of the six and it sits 240-on-255 in Light, which is a line
  you cannot see. Also used for the arrangement's lane grid and row rules,
  which are the same weight of mark. }
function ThemeGridSub: TColor;
begin
  case FMode of
    ThemeLight: Result := RGBToColor(200, 200, 200);
    ThemeDark: Result := RGBToColor(58, 58, 58);
  else
    Result := Graphics.clSilver;
  end;
end;

{ ---------------------------------------------------------------------------
  The native-widget walk.

  An allow-list, not a sweep: a class that is not named here is recursed into
  but left alone. That is the conservative choice on purpose - the classes
  below are the ones both GTK2 and Win32 actually honour a Color on, and the
  ones left out fall into two groups.

  Cannot be themed, on either platform, so setting anything is at best wasted
  and at worst an artefact: TButton and TComboBox's dropdown list are drawn by
  the GTK2 theme engine and by UxTheme respectively; TTrackBar's trough and
  thumb are entirely theme-drawn; menus are native GTK menus that the LCL
  cannot reach at all. This is the known ceiling - some light chrome survives
  in Dark mode, and the honest fix is System mode or a dark desktop theme, not
  a fight with the widget toolkit. TScrollBar was in this group too, which is
  why it is no longer used anywhere - see ThemeScrollBar.pas.

  Do not NEED theming: the custom-painted controls - the arrangement, the
  effects rack, the editors - paint every pixel themselves through the six
  shadowed colours above, so they are already themed by the time this runs.

  Casts are explicit rather than going through TControl because Color and Font
  are not published at that level for every descendant. }
procedure ThemeApply(AControl: TControl);
var
  i: Integer;
  Parent: TWinControl;
begin
  if FMode = ThemeSystem then
    Exit;
  { opted out - and so is everything under it, which is the useful reading
    for a control that manages its own appearance }
  if AControl.Tag = ThemeTagSkip then
    Exit;

  if AControl is TCustomForm then
    TCustomForm(AControl).Color := clBtnFace
  else if AControl is TPanel then
  begin
    TPanel(AControl).Color := clBtnFace;
    TPanel(AControl).Font.Color := clWindowText;
  end
  else if AControl is TLabel then
    { background only ever comes from the parent - a TLabel is transparent on
      both widgetsets, which is exactly what we want, so only the text moves }
    TLabel(AControl).Font.Color := clWindowText
  else if AControl is TEdit then
  begin
    TEdit(AControl).Color := clWindow;
    TEdit(AControl).Font.Color := clWindowText;
  end
  else if AControl is TListBox then
  begin
    TListBox(AControl).Color := clWindow;
    TListBox(AControl).Font.Color := clWindowText;
  end
  else if AControl is TComboBox then
  begin
    { the closed control takes these on both platforms; the popup list it
      opens is a separate native window and keeps the system's colours }
    TComboBox(AControl).Color := clWindow;
    TComboBox(AControl).Font.Color := clWindowText;
  end
  else if AControl is TSpeedButton then
  begin
    { the one button class that themes, on both platforms - a TGraphicControl
      with no window handle, so the LCL paints it rather than the widgetset.
      Anything ArrangementView later lights up (the send buttons) reasserts
      its own colour on the next refresh. }
    TSpeedButton(AControl).Color := clBtnFace;
    TSpeedButton(AControl).Font.Color := clWindowText;
  end
  else if AControl is TSplitter then
    TSplitter(AControl).Color := clBtnFace;

  if AControl is TWinControl then
  begin
    Parent := TWinControl(AControl);
    for i := 0 to Parent.ControlCount - 1 do
      ThemeApply(Parent.Controls[i]);
  end;
end;

end.
