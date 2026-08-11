unit ThemeScrollBar;

{$mode objfpc}{$H+}

{ A drawn scrollbar, because the native one is the last piece of chrome the
  palette cannot reach.

  Every other widget in the app either paints itself through Theme's six
  shadowed colours or was given a Color by ThemeApply. TScrollBar is neither:
  its trough and thumb come from the GTK2 theme engine (and from UxTheme on
  Windows), so a Color assignment is silently ignored and a light scrollbar
  survives on a dark form. The only way past that is to stop asking the
  widgetset for one.

  TThemeScrollBar is a TGraphicControl - no window handle, so the LCL paints
  it on the parent's canvas exactly like it paints TSpeedButton, and it goes
  through the same shadowed colours as the arrangement and the editors. It is
  deliberately a drop-in for the slice of TScrollBar this app actually used:
  Kind / Min / Max / Position / PageSize / SmallChange / LargeChange / OnChange,
  with Kind keeping the LCL's own TScrollBarKind so existing sbHorizontal and
  sbVertical call sites still read the same.

  This is the one theme phase that is not a visual no-op: a drawn scrollbar
  cannot look byte-identical to a native GTK2 one even in Light mode. It is
  drawn to approximate the modern GTK look - flat trough, rounded thumb, no
  arrow buttons - rather than to imitate any particular platform's, since it
  now has to sit convincingly on both a light and a dark surface.

  ONE BEHAVIOURAL DIFFERENCE, relied on by both call sites: assigning Position
  from code does NOT fire OnChange. Only the mouse does. The range updaters
  (ArrangementView.UpdateScrollBarRange, MainForm.UpdateDevicePanelScroll)
  push the view's current offset back into the bar every time they run, and an
  event there would feed the offset straight back into the view that produced
  it. MainForm already assumed this - it calls DeviceScrollBarChange by hand
  after setting Position. }

interface

uses
  { TScrollBarKind (and so sbHorizontal/sbVertical) lives in Forms, not in
    StdCtrls where TScrollBar itself is declared }
  Classes, Controls, Graphics, Forms, UIScale,
  { last on purpose - Theme shadows Graphics' clBtnFace/clBtnShadow/... with
    the themed palette, and only wins if it is resolved after Graphics }
  Theme;

type
  TThemeScrollBar = class(TGraphicControl)
  private
    const
      { gap between the thumb and the trough's edges, both axes. Small enough
        that the bar still reads as full-width, large enough that the rounded
        ends have somewhere to go. }
      TrackInset = 2;
      { a thumb shorter than this is unhittable - at extreme zoom the
        proportional length would otherwise collapse to a couple of pixels }
      MinThumbExtent = 24;
    var
      FKind: TScrollBarKind;
      FMin: Integer;
      FMax: Integer;
      FPosition: Integer;
      FPageSize: Integer;
      FSmallChange: Integer;
      FLargeChange: Integer;
      FOnChange: TNotifyEvent;
      FDragging: Boolean;
      { where inside the thumb the drag started, so the thumb does not jump to
        centre itself under the cursor on the first move }
      FGrabOffset: Integer;
      FHot: Boolean;
    function Span: Integer;
    function EffectivePage: Integer;
    function MaxPosition: Integer;
    function TrackExtent: Integer;
    function ThumbExtent: Integer;
    function ThumbStart: Integer;
    function ThumbColor: TColor;
    procedure SetKind(AValue: TScrollBarKind);
    procedure SetMin(AValue: Integer);
    procedure SetMax(AValue: Integer);
    procedure SetPageSize(AValue: Integer);
    procedure SetPosition(AValue: Integer);
    { the mouse path: clamps, repaints AND notifies. SetPosition is the code
      path and stays silent - see the unit header. }
    procedure UserSetPosition(AValue: Integer);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Kind: TScrollBarKind read FKind write SetKind default sbHorizontal;
    property Min: Integer read FMin write SetMin default 0;
    property Max: Integer read FMax write SetMax default 100;
    property Position: Integer read FPosition write SetPosition default 0;
    { the visible slice of the range. Max is the extent of the CONTENT, as in
      the LCL, so the furthest the thumb can travel to is Max - PageSize. }
    property PageSize: Integer read FPageSize write SetPageSize default 0;
    { kept because both call sites set it, and because it is what an arrow
      button or a wheel step would use. Nothing consumes it while the bar has
      neither: modern GTK scrollbars have no arrows, and a wheel over a
      handleless control is delivered to the parent, which does its own
      scrolling already. }
    property SmallChange: Integer read FSmallChange write FSmallChange default 1;
    { the step taken when the trough either side of the thumb is clicked }
    property LargeChange: Integer read FLargeChange write FLargeChange default 0;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property Align;
    property Anchors;
    property Enabled;
    property Visible;
    property ShowHint;
  end;

implementation

{ Mixes towards a second colour by AAmount (0..1). Used for the hover/drag
  thumb, which needs to lift in Dark and darken in Light off the same base -
  deriving it beats adding two more palette entries that only this control
  would ever read. }
function Blend(A, B: TColor; AAmount: Double): TColor;
var
  Ar, Ag, Ab, Br, Bg, Bb: Byte;
begin
  RedGreenBlue(ColorToRGB(A), Ar, Ag, Ab);
  RedGreenBlue(ColorToRGB(B), Br, Bg, Bb);
  Result := RGBToColor(
    Round(Ar + (Br - Ar) * AAmount),
    Round(Ag + (Bg - Ag) * AAmount),
    Round(Ab + (Bb - Ab) * AAmount));
end;

constructor TThemeScrollBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  { csCaptureMouse is what makes a drag work on a control with no handle: the
    LCL then captures on mouse-down and keeps routing moves here even once the
    cursor has left the bar, which is exactly what dragging a thumb needs. }
  ControlStyle := ControlStyle + [csCaptureMouse];
  FKind := sbHorizontal;
  FMin := 0;
  FMax := 100;
  FPosition := 0;
  FPageSize := 0;
  FSmallChange := 1;
  FLargeChange := 0;
end;

{ ---------------------------------------------------------------------------
  Geometry. All of it is expressed along "the axis" so the two orientations
  share one set of sums; only ThumbRect and the hit test know which way round
  the control actually is.
  --------------------------------------------------------------------------- }

function TThemeScrollBar.Span: Integer;
begin
  Result := FMax - FMin;
  if Result < 1 then
    Result := 1;
end;

function TThemeScrollBar.EffectivePage: Integer;
begin
  Result := FPageSize;
  if Result < 1 then
    Result := 1;
  if Result > Span then
    Result := Span;
end;

function TThemeScrollBar.MaxPosition: Integer;
begin
  Result := FMax - EffectivePage;
  if Result < FMin then
    Result := FMin;
end;

function TThemeScrollBar.TrackExtent: Integer;
begin
  if FKind = sbHorizontal then
    Result := Width
  else
    Result := Height;
  Dec(Result, 2 * TrackInset);
  if Result < 0 then
    Result := 0;
end;

{ Proportional, like every scrollbar: the thumb is as much of the track as the
  page is of the content, so its length reads as the zoom level. }
function TThemeScrollBar.ThumbExtent: Integer;
var
  Track, Smallest: Integer;
begin
  Track := TrackExtent;
  Result := Round(Track * (EffectivePage / Span));
  Smallest := Px(MinThumbExtent);
  if Result < Smallest then
    Result := Smallest;
  if Result > Track then
    Result := Track;
end;

function TThemeScrollBar.ThumbStart: Integer;
var
  Range, Slack: Integer;
begin
  Range := MaxPosition - FMin;
  Slack := TrackExtent - ThumbExtent;
  if (Range <= 0) or (Slack <= 0) then
    { nothing to scroll: the thumb fills the track and sits at the start }
    Result := TrackInset
  else
    Result := TrackInset + Round(Slack * ((FPosition - FMin) / Range));
end;

function TThemeScrollBar.ThumbColor: TColor;
begin
  Result := clBtnShadow;
  if FDragging or FHot then
    { towards the text colour, which is the far end of the palette in both
      directions - lighter than the thumb in Dark, darker in Light }
    Result := Blend(Result, clWindowText, 0.35);
end;

{ ---------------------------------------------------------------------------
  Property setters. Each clamps Position into the range it just changed,
  because a range update can legitimately shrink the content out from under a
  scrolled view. Both call sites assign Position after the range, or re-clamp
  it themselves, so nothing depends on an intermediate value surviving.
  --------------------------------------------------------------------------- }

procedure TThemeScrollBar.SetKind(AValue: TScrollBarKind);
begin
  if FKind = AValue then
    Exit;
  FKind := AValue;
  Invalidate;
end;

procedure TThemeScrollBar.SetMin(AValue: Integer);
begin
  if FMin = AValue then
    Exit;
  FMin := AValue;
  SetPosition(FPosition);
  Invalidate;
end;

procedure TThemeScrollBar.SetMax(AValue: Integer);
begin
  if FMax = AValue then
    Exit;
  FMax := AValue;
  SetPosition(FPosition);
  Invalidate;
end;

procedure TThemeScrollBar.SetPageSize(AValue: Integer);
begin
  if FPageSize = AValue then
    Exit;
  FPageSize := AValue;
  SetPosition(FPosition);
  Invalidate;
end;

procedure TThemeScrollBar.SetPosition(AValue: Integer);
begin
  if AValue < FMin then
    AValue := FMin;
  if AValue > MaxPosition then
    AValue := MaxPosition;
  if FPosition = AValue then
    Exit;
  FPosition := AValue;
  Invalidate;
end;

procedure TThemeScrollBar.UserSetPosition(AValue: Integer);
var
  Before: Integer;
begin
  Before := FPosition;
  SetPosition(AValue);
  if (FPosition <> Before) and Assigned(FOnChange) then
    FOnChange(Self);
end;

{ ---------------------------------------------------------------------------
  Painting.
  --------------------------------------------------------------------------- }

procedure TThemeScrollBar.Paint;
var
  Start, Extent, Radius: Integer;
  L, T, R, B: Integer;
begin
  { the trough takes chrome colour rather than canvas colour: the horizontal
    bar sits under the arrangement's lanes and the vertical one between the
    lanes and the track headers, and in both places it belongs to the frame
    around the canvas, not to the canvas }
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(0, 0, Width, Height);

  Start := ThumbStart;
  Extent := ThumbExtent;
  if Extent <= 0 then
    Exit;

  if FKind = sbHorizontal then
  begin
    L := Start;
    T := TrackInset;
    R := Start + Extent;
    B := Height - TrackInset;
  end
  else
  begin
    L := TrackInset;
    T := Start;
    R := Width - TrackInset;
    B := Start + Extent;
  end;
  if (R <= L) or (B <= T) then
    Exit;

  { pen as well as brush - RoundRect outlines with the current pen, and the
    default black one would put a hard edge round the thumb in both palettes }
  Canvas.Brush.Color := ThumbColor;
  Canvas.Pen.Color := Canvas.Brush.Color;
  { fully rounded ends: a radius of the short side turns the rectangle into a
    capsule, which is what every current desktop draws }
  Radius := R - L;
  if (B - T) < Radius then
    Radius := B - T;
  Canvas.RoundRect(L, T, R, B, Radius, Radius);
end;

{ ---------------------------------------------------------------------------
  Mouse. Drag the thumb, page the trough. No arrow buttons - GTK3 and current
  Windows both dropped them, and they would be the fiddliest part to make
  look right at 16px.
  --------------------------------------------------------------------------- }

procedure TThemeScrollBar.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Coord, Start, Extent, Step: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> mbLeft then
    Exit;

  if FKind = sbHorizontal then
    Coord := X
  else
    Coord := Y;
  Start := ThumbStart;
  Extent := ThumbExtent;

  if (Coord >= Start) and (Coord < Start + Extent) then
  begin
    FDragging := True;
    FGrabOffset := Coord - Start;
    Invalidate;
    Exit;
  end;

  Step := FLargeChange;
  if Step <= 0 then
    Step := EffectivePage;
  if Coord < Start then
    UserSetPosition(FPosition - Step)
  else
    UserSetPosition(FPosition + Step);
end;

procedure TThemeScrollBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Coord, Slack, Range, Offset: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FDragging then
    Exit;

  Slack := TrackExtent - ThumbExtent;
  Range := MaxPosition - FMin;
  if (Slack <= 0) or (Range <= 0) then
    Exit;

  if FKind = sbHorizontal then
    Coord := X
  else
    Coord := Y;
  { back out the grab point and the inset, then invert ThumbStart's sum }
  Offset := Coord - FGrabOffset - TrackInset;
  UserSetPosition(FMin + Round(Range * (Offset / Slack)));
end;

procedure TThemeScrollBar.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FDragging then
  begin
    FDragging := False;
    Invalidate;
  end;
end;

procedure TThemeScrollBar.MouseEnter;
begin
  inherited MouseEnter;
  FHot := True;
  Invalidate;
end;

procedure TThemeScrollBar.MouseLeave;
begin
  inherited MouseLeave;
  FHot := False;
  Invalidate;
end;

end.
