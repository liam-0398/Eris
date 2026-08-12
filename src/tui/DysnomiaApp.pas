unit DysnomiaApp;

{ Stage 1 Free Vision application shell: menu bar, status line, transport
  bar, docked file/track/timeline panes, bottom bar. Nothing here reaches
  into aengine, abackend or project - see tui.md, "Build stages", stage 1
  is UI only. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Menus, Dialogs, App,
  DysGeometry, DysWidgets, DysFilePane, DysTrackPane, DysTimeline;

const
  cmAbout = 1000;

type
  PDysnomiaApp = ^TDysnomiaApp;
  TDysnomiaApp = object(TApplication)
    ToolBar: PDysToolBar;
    BottomBar: PDysBottomBar;
    FilePane: PDysFilePane;
    TrackPane: PDysTrackPane;
    Timeline: PDysTimeline;
    constructor Init;
    procedure InitMenuBar; virtual;
    procedure InitStatusLine; virtual;
    procedure InitDeskTop; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    function GetPalette: PPalette; virtual;
  private
    procedure ShowAbout;
    procedure ShowTooSmall(Body: TRect; const Layout: TDysLayout);
  end;

implementation

uses
  MsgBox;

{ App-wide colour override. See DysWidgets.TDysPane's comment for why the
  panes need CGrayDialog rather than a plain window palette; this is the
  other half - recolouring what CGrayDialog's indices actually resolve
  to, without touching anything else CAppColor (App.pas) drives (menu
  bar, status line, blue/cyan window and dialog variants).

  Attribute byte layout here is the classic one: bit 7 = blink, bits 4-6
  = background (0-7), bits 0-3 = foreground (0-15). Every stock palette
  byte in CAppColor keeps bit 7 clear - it's reserved as the Drivers.
  ErrorAttr ($CF) signal for "palette index out of range", which is
  exactly the red-blink Dysnomia was showing before CGrayDialog was
  wired in. So bit 7 stays off here too: "dark grey background" isn't
  representable as an intentional bg colour in this model (that needs a
  4th background bit, which doesn't exist without reusing the blink
  bit) - background 0 (black) is the closest safe substitute, and it's
  what most terminal "black" themes render as anyway. }
var
  DysAppPalette: TPalette;
  DysAppPaletteReady: Boolean = False;

procedure InitDysAppPalette;
const
  BgAttr   = $07; { black bg, light grey fg - desktop background pattern }
  PaneNorm = $0F; { black bg, bright white fg - pane text }
  PaneSel  = $F0; { white bg, black fg - focused/selected list item }
  PaneDim  = $08; { black bg, dark grey fg }
var
  I: Integer;
begin
  DysAppPalette := CAppColor;
  DysAppPalette[1] := Chr(BgAttr);
  for I := 32 to 63 do            { the CGrayDialog block, local idx 1..32 }
    DysAppPalette[I] := Chr(PaneNorm);
  DysAppPalette[32 + 26 - 1] := Chr(PaneSel); { CListViewer local idx 26 }
  DysAppPalette[32 + 27 - 1] := Chr(PaneSel); { CListViewer local idx 27 }
  DysAppPalette[32 + 28 - 1] := Chr(PaneDim); { CListViewer local idx 28 }
  DysAppPaletteReady := True;
end;

function TDysnomiaApp.GetPalette: PPalette;
begin
  if not DysAppPaletteReady then
    InitDysAppPalette;
  GetPalette := @DysAppPalette;
end;

constructor TDysnomiaApp.Init;
begin
  inherited Init;
end;

procedure TDysnomiaApp.InitMenuBar;
var
  R: TRect;
begin
  GetExtent(R);
  R.B.Y := R.A.Y + 1;
  MenuBar := New(PMenuBar, Init(R, NewMenu(
    NewSubMenu('~F~ile', hcNoContext, NewMenu(
      NewItem('E~x~it', 'Alt-X', kbAltX, cmQuit, hcNoContext,
      nil)),
    NewSubMenu('~H~elp', hcNoContext, NewMenu(
      NewItem('~A~bout', '', kbNoKey, cmAbout, hcNoContext,
      nil)),
    nil)))));
end;

procedure TDysnomiaApp.InitStatusLine;
var
  R: TRect;
begin
  GetExtent(R);
  R.A.Y := R.B.Y - 1;
  StatusLine := New(PStatusLine, Init(R,
    NewStatusDef(0, $FFFF,
      NewStatusKey('~Alt-X~ Exit', kbAltX, cmQuit,
      NewStatusKey('~F10~ Menu', kbF10, cmMenu,
      nil)),
    nil)));
end;

procedure TDysnomiaApp.ShowTooSmall(Body: TRect; const Layout: TDysLayout);
var
  Local: TRect;
begin
  DeskTop := New(PDeskTop, Init(Body));
  Local := Body;
  Local.Move(-Body.A.X, -Body.A.Y);
  DeskTop^.Insert(New(PStaticText, Init(Local,
    'Resize to at least ' + IntToStr(MinCols) + 'x' + IntToStr(MinRows) +
    ' - currently ' + IntToStr(Layout.Cols) + 'x' + IntToStr(Layout.Rows))));
end;

procedure TDysnomiaApp.InitDeskTop;
var
  R, BodyR, Local: TRect;
  Layout: TDysLayout;
begin
  GetExtent(R);
  if MenuBar <> nil then
    Inc(R.A.Y);
  if StatusLine <> nil then
    Dec(R.B.Y);

  Layout := ComputeLayout(R);
  if Layout.TooSmall then
  begin
    ShowTooSmall(R, Layout);
    Exit;
  end;

  ToolBar := New(PDysToolBar, Init(Layout.ToolBar));
  Insert(ToolBar);
  BottomBar := New(PDysBottomBar, Init(Layout.BottomBar));
  Insert(BottomBar);

  BodyR.Assign(R.A.X, Layout.ToolBar.B.Y, R.B.X, Layout.BottomBar.A.Y);
  DeskTop := New(PDeskTop, Init(BodyR));

  Local := Layout.FilePane;
  Local.Move(-BodyR.A.X, -BodyR.A.Y);
  FilePane := New(PDysFilePane, InitPane(Local));
  DeskTop^.Insert(FilePane);

  Local := Layout.TrackPane;
  Local.Move(-BodyR.A.X, -BodyR.A.Y);
  TrackPane := New(PDysTrackPane, InitPane(Local));
  DeskTop^.Insert(TrackPane);

  Local := Layout.Timeline;
  Local.Move(-BodyR.A.X, -BodyR.A.Y);
  Timeline := New(PDysTimeline, InitPane(Local));
  DeskTop^.Insert(Timeline);

  { Nothing is Current anywhere by default - Insert() doesn't select what
    it inserts, so without this no view anywhere ever receives keyboard
    input. Focus climbs the whole Owner chain (App -> DeskTop -> pane),
    so one call establishes it end to end. }
  FilePane^.FocusPane;
end;

procedure TDysnomiaApp.ShowAbout;
begin
  MessageBox('Dysnomia - Free Vision frontend for Eris'#13#13 +
    'Stage 1: UI shell, not hooked up to the engine yet.', nil,
    mfInformation or mfOKButton);
end;

procedure TDysnomiaApp.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if Event.What = evCommand then
  begin
    case Event.Command of
      cmAbout: ShowAbout;
    else
      Exit;
    end;
    ClearEvent(Event);
  end;
end;

end.
