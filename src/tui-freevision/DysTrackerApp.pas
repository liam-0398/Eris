unit DysTrackerApp;

{ The launcher's "Tracker" screen (tui.md's Tracker section) - a separate
  TUI process, synced to a running DAW instance over DysRemoteProtocol's
  socket link. Follows the DAW's tempo/transport/selected-track live
  (polled once per Idle tick, same cadence TDysToolBar.PollRecordState
  already uses in the DAW), is read-only whenever the DAW-selected track
  isn't an instrument track, and can Render its pattern into a clip
  dropped at the DAW timeline's cursor.

  Three docked panes (reusing DysWidgets.TDysPane as the bordered/Tab-
  cycling container, same as every DAW pane): a transport bar on top,
  a vertical note grid on the left, a vertical effects list on the right -
  intentionally one file rather than a separate Panes unit, the three
  content views are small enough that splitting them cost more (an extra
  circular-uses seam) than it saved. }

{$mode objfpc}{$H+}

interface

uses
  App;

type
  TDysTrackerApp = object(TApplication)
    PollTick: Integer;
    procedure InitDeskTop; virtual;
    procedure Idle; virtual;
  end;

procedure RunDysTracker;

implementation

uses
  SysUtils, Objects, Drivers, Views, Menus, Dialogs, MsgBox, Sockets, BaseUnix,
  DysRemoteProtocol, DysWidgets, DysEffectsRack;

const
  NoNote = -1000;
  DefaultStepsPerBar = 16;
  DefaultLengthBars = 4;
  PollEveryTicks = 15; { ~150ms at the Idle loop's own Sleep(10) cadence }

  cmTrkPlayToggle = 4001;
  cmTrkRecord = 4002;
  cmTrkRender = 4003;
  cmTrkCycleGrid = 4004;

  { Row-label shading (see tui.md's Tracker section) - kept within this
    palette's non-blink background range (0-7, same ceiling DysTimeline's
    NormalAttr/CursorAttr/PlayheadAttr already respect) since a background
    value of 8+ triggers real terminal blink here, not brightness. Bar
    starts get the brightest reading available (light-grey bg, bright
    white text); 1/4-note rows get the same background with plain white
    text, a visibly dimmer step; everything else is plain. }
  BarStartAttr = $7F;
  QuarterAttr = $70;
  PlainRowAttr = $0F;
  CursorRowAttr = $2F;

type
  TDysTrackerNoteEntry = Integer; { NoNote or a base semitone offset }

var
  { Single-active-instance pattern, same as ActiveToolBar/ActiveTrackPane
    elsewhere in this codebase - the three panes below all need to reach
    shared connection/pattern state without a uses cycle back to this
    unit's own TApplication descendant. }
  Sock: cint = -1;
  Connected: Boolean = False;
  SockIn, SockOut: Text;
  RemoteState: TDysRemoteState;
  Pattern: array of TDysTrackerNoteEntry;
  CursorRow: Integer = 0;
  LengthBars: Integer = DefaultLengthBars;
  StepsPerBar: Integer = DefaultStepsPerBar;
  TransportBar: Pointer = nil; { PTrackerTransportBar, typed below }
  GridContent: Pointer = nil;  { PTrackerGridContent }
  EffectsContent: Pointer = nil; { PTrackerEffectsContent }

function TotalRows: Integer;
begin
  Result := LengthBars * StepsPerBar;
end;

procedure ResizePattern;
var
  i: Integer;
begin
  SetLength(Pattern, TotalRows);
  for i := 0 to High(Pattern) do
    Pattern[i] := NoNote;
  if CursorRow >= TotalRows then
    CursorRow := 0;
end;

{ Closes a dead connection - called whenever a round-trip's ReadLn/WriteLn
  hits an I/O error, so the app degrades to "waiting for DAW" instead of
  hanging on a socket the other end no longer owns. }
procedure DropConnection;
begin
  if Connected then
  begin
    {$I-}
    Close(SockIn);
    Close(SockOut);
    {$I+}
    IOResult;
  end;
  Connected := False;
end;

function TryConnect: Boolean;
begin
  Result := False;
  Sock := fpsocket(AF_UNIX, SOCK_STREAM, 0);
  if Sock < 0 then Exit;
  if not Sockets.Connect(Sock, RemoteSocketPath, SockIn, SockOut) then
  begin
    CloseSocket(Sock);
    Exit;
  end;
  Connected := True;
  Result := True;
end;

{ One blocking request/response round-trip - every server reply is exactly
  one line (DysRemoteServer's own contract), so this never has to guess
  how much to read. Returns '' and drops the connection on any I/O error. }
function SendRecv(const ALine: string): string;
begin
  Result := '';
  if not Connected then Exit;
  {$I-}
  WriteLn(SockOut, ALine);
  Flush(SockOut);
  ReadLn(SockIn, Result);
  {$I+}
  if IOResult <> 0 then
  begin
    DropConnection;
    Result := '';
  end;
end;

procedure PollState;
var
  Reply: string;
begin
  if not Connected then
  begin
    TryConnect;
    Exit;
  end;
  Reply := SendRecv(EncodeGetState);
  if Reply <> '' then
    DecodeState(Reply, RemoteState);
end;

{ Transport bar - mirrors TDysToolBar's own PButton/PInputLine
  composition (DysWidgets.pas) rather than a hand-drawn hit-test, for the
  same reason: free mouse+keyboard handling from Free Vision's own button/
  input-line views instead of reimplementing it. Tempo and the connection
  status are read-only, so those are hand-drawn text (Draw override,
  background-first-then-inherited per tui.md's TGroup.Draw lesson) rather
  than another control. }
type
  PTrackerTransportBar = ^TTrackerTransportBar;
  TTrackerTransportBar = object(TGroup)
    LengthIL: PInputLine;
    PlayBtn, RecordBtn, GridBtn, RenderBtn: PButton;
    constructor Init(Bounds: TRect);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
    procedure SyncButtons;
  end;

procedure SetBtnTitle(B: PButton; const S: string);
begin
  if B^.Title <> nil then DisposeStr(B^.Title);
  B^.Title := NewStr(S);
  B^.DrawView;
end;

constructor TTrackerTransportBar.Init(Bounds: TRect);
var
  R: TRect;
  S: string;
begin
  inherited Init(Bounds);
  GrowMode := 0;

  R.Assign(30, 0, 44, 1);
  Insert(New(PStaticText, Init(R, 'Length (bars):')));
  R.Assign(45, 0, 51, 1);
  LengthIL := New(PInputLine, Init(R, 4));
  S := IntToStr(LengthBars);
  LengthIL^.SetData(S);
  Insert(LengthIL);

  R.Assign(53, 0, 62, 1);
  GridBtn := New(PButton, Init(R, '1/16', cmTrkCycleGrid, bfNormal));
  Insert(GridBtn);

  R.Assign(63, 0, 71, 1);
  PlayBtn := New(PButton, Init(R, 'Play', cmTrkPlayToggle, bfNormal));
  Insert(PlayBtn);

  R.Assign(72, 0, 79, 1);
  RecordBtn := New(PButton, Init(R, 'Rec', cmTrkRecord, bfNormal));
  Insert(RecordBtn);

  R.Assign(80, 0, 90, 1);
  RenderBtn := New(PButton, Init(R, 'Render', cmTrkRender, bfNormal));
  Insert(RenderBtn);
end;

procedure TTrackerTransportBar.Draw;
var
  B: TDrawBuffer;
  S: string;
begin
  MoveChar(B, ' ', PlainRowAttr, Size.X);
  if not Connected then
    S := 'Waiting for DAW...'
  else
  begin
    S := Format('Tempo %.1f  Track %d %s', [RemoteState.TempoBPM,
      RemoteState.TrackIndex + 1, RemoteState.TrackName]);
    if RemoteState.Recording then S := S + '  [REC]'
    else if RemoteState.Playing then S := S + '  [PLAY]';
    if not RemoteState.IsInstrumentTrack then
      S := S + '  (not an instrument track)';
  end;
  MoveStr(B, S, PlainRowAttr);
  WriteLine(0, 0, Size.X, 1, B);
  inherited Draw;
end;

procedure TTrackerTransportBar.SyncButtons;
begin
  if RemoteState.Playing then SetBtnTitle(PlayBtn, 'Stop')
  else SetBtnTitle(PlayBtn, 'Play');
end;

procedure TTrackerTransportBar.HandleEvent(var Event: TEvent);
var
  N: Integer;
begin
  inherited HandleEvent(Event);
  if Event.What = evCommand then
  begin
    case Event.Command of
      cmTrkPlayToggle:
        begin
          if RemoteState.Playing then SendRecv(RemoteCmdStop)
          else SendRecv(RemoteCmdPlay);
          ClearEvent(Event);
        end;
      cmTrkRecord:
        begin
          SendRecv(RemoteCmdRecord);
          ClearEvent(Event);
        end;
      cmTrkCycleGrid:
        begin
          case StepsPerBar of
            4: StepsPerBar := 8;
            8: StepsPerBar := 16;
            16: StepsPerBar := 32;
          else
            StepsPerBar := 4;
          end;
          case StepsPerBar of
            4: SetBtnTitle(GridBtn, '1/4');
            8: SetBtnTitle(GridBtn, '1/8');
            16: SetBtnTitle(GridBtn, '1/16');
          else
            SetBtnTitle(GridBtn, '1/32');
          end;
          ResizePattern;
          if GridContent <> nil then
            PView(GridContent)^.DrawView;
          ClearEvent(Event);
        end;
      cmTrkRender:
        begin
          if TryStrToInt(LengthIL^.Data^, N) and (N > 0) then
            LengthBars := N;
          ResizePattern;
          ClearEvent(Event);
        end;
    end;
  end;
end;

{ Vertical single-track step grid - no velocity, no effect columns, per
  tui.md's Tracker section. Read-only whenever the DAW-selected track
  isn't an instrument track. }
type
  PTrackerGridContent = ^TTrackerGridContent;
  TTrackerGridContent = object(TView)
    ViewStart: Integer;
    constructor Init(Bounds: TRect);
    procedure EnsureCursorVisible;
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

constructor TTrackerGridContent.Init(Bounds: TRect);
begin
  inherited Init(Bounds);
  GrowMode := gfGrowHiX + gfGrowHiY;
  Options := Options or ofSelectable;
  ViewStart := 0;
end;

procedure TTrackerGridContent.EnsureCursorVisible;
begin
  if CursorRow < ViewStart then
    ViewStart := CursorRow
  else if CursorRow >= ViewStart + Size.Y then
    ViewStart := CursorRow - Size.Y + 1;
  if ViewStart < 0 then ViewStart := 0;
end;

procedure TTrackerGridContent.Draw;
var
  B: TDrawBuffer;
  Row, Y, Bar, StepInBar: Integer;
  LabelStr, NoteStr: string;
  Attr: Word;
const
  LabelWidth = 8;
begin
  EnsureCursorVisible;
  if not RemoteState.IsInstrumentTrack then
  begin
    MoveChar(B, ' ', PlainRowAttr, Size.X);
    MoveStr(B, ' select an instrument track in the DAW', PlainRowAttr);
    WriteLine(0, 0, Size.X, 1, B);
    for Y := 1 to Size.Y - 1 do
    begin
      MoveChar(B, ' ', PlainRowAttr, Size.X);
      WriteLine(0, Y, Size.X, 1, B);
    end;
    Exit;
  end;
  for Y := 0 to Size.Y - 1 do
  begin
    Row := ViewStart + Y;
    MoveChar(B, ' ', PlainRowAttr, Size.X);
    if Row < TotalRows then
    begin
      Bar := Row div StepsPerBar;
      StepInBar := Row mod StepsPerBar;
      LabelStr := Format('%d.%-2d', [Bar, StepInBar]);
      if StepInBar = 0 then Attr := BarStartAttr
      else if (StepsPerBar >= 4) and (StepInBar mod (StepsPerBar div 4) = 0) then
        Attr := QuarterAttr
      else Attr := PlainRowAttr;
      if Row = CursorRow then Attr := CursorRowAttr;
      MoveStr(B, Copy(LabelStr + '       ', 1, LabelWidth), Attr);
      if Pattern[Row] <> NoNote then
        NoteStr := 'note ' + IntToStr(Pattern[Row])
      else
        NoteStr := '';
      MoveStr(B[LabelWidth], NoteStr, PlainRowAttr);
    end;
    WriteLine(0, Y, Size.X, 1, B);
  end;
end;

procedure TTrackerGridContent.HandleEvent(var Event: TEvent);
var
  Offset: Integer;
begin
  inherited HandleEvent(Event);
  if not RemoteState.IsInstrumentTrack then Exit;
  if Event.What = evKeyDown then
  begin
    case Event.KeyCode of
      kbUp:
        begin
          if CursorRow > 0 then Dec(CursorRow);
          DrawView; ClearEvent(Event);
        end;
      kbDown:
        begin
          if CursorRow < TotalRows - 1 then Inc(CursorRow);
          DrawView; ClearEvent(Event);
        end;
      kbPgUp:
        begin
          Dec(CursorRow, StepsPerBar);
          if CursorRow < 0 then CursorRow := 0;
          DrawView; ClearEvent(Event);
        end;
      kbPgDn:
        begin
          Inc(CursorRow, StepsPerBar);
          if CursorRow > TotalRows - 1 then CursorRow := TotalRows - 1;
          DrawView; ClearEvent(Event);
        end;
      kbDel:
        begin
          Pattern[CursorRow] := NoNote;
          DrawView; ClearEvent(Event);
        end;
    else
      if (Event.CharCode <> #0) and DysKeyToSemitoneOffset(Event.CharCode, Offset) then
      begin
        Pattern[CursorRow] := Offset;
        SendRecv(EncodeNoteOn(Offset));
        DrawView;
        ClearEvent(Event);
      end;
    end;
  end;
end;

{ Vertical effects list for the DAW-selected track - visually the same
  param-box language as TDysEffectsContent's bottom pane (DysEffectsRack.
  pas) but a plain list this pass: add (reusing that unit's own
  BuildAddEffectMenu/cmAddEffectBase popup, same menu the DAW's own
  effects rack shows) and remove are real; live per-param editing is not
  yet wired - see tui.md's Tracker section on why (needs TDysEffectBox's
  per-kind field table factored into something this remote path can share
  too, future work). }
type
  PTrackerEffectsContent = ^TTrackerEffectsContent;
  TTrackerEffectsContent = object(TView)
    Selected: Integer;
    constructor Init(Bounds: TRect);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

constructor TTrackerEffectsContent.Init(Bounds: TRect);
begin
  inherited Init(Bounds);
  GrowMode := gfGrowHiX + gfGrowHiY;
  Options := Options or ofSelectable;
  Selected := -1;
end;

procedure TTrackerEffectsContent.Draw;
var
  B: TDrawBuffer;
  i, Y: Integer;
  Attr: Word;
begin
  MoveChar(B, ' ', PlainRowAttr, Size.X);
  MoveStr(B, ' Effects (a=add, Del=remove)', PlainRowAttr);
  WriteLine(0, 0, Size.X, 1, B);
  for Y := 1 to Size.Y - 1 do
  begin
    i := Y - 1;
    MoveChar(B, ' ', PlainRowAttr, Size.X);
    if i <= High(RemoteState.Effects) then
    begin
      if i = Selected then Attr := CursorRowAttr else Attr := PlainRowAttr;
      MoveStr(B, ' ' + RemoteState.Effects[i].Name, Attr);
    end;
    WriteLine(0, Y, Size.X, 1, B);
  end;
end;

procedure TTrackerEffectsContent.HandleEvent(var Event: TEvent);
var
  MenuData: PMenu;
  MenuBoxPtr: PMenuBox;
  DeskR, R: TRect;
  Cmd: Word;
begin
  inherited HandleEvent(Event);
  if Event.What = evKeyDown then
  begin
    case Event.KeyCode of
      kbUp:
        begin
          if Selected > 0 then Dec(Selected)
          else if Selected < 0 then Selected := 0;
          DrawView; ClearEvent(Event);
        end;
      kbDown:
        begin
          if Selected < High(RemoteState.Effects) then Inc(Selected);
          DrawView; ClearEvent(Event);
        end;
      kbDel:
        begin
          if (Selected >= 0) and (Selected <= High(RemoteState.Effects)) then
            SendRecv(EncodeRemoveEffect(Selected));
          Selected := -1;
          DrawView; ClearEvent(Event);
        end;
    end;
    if (Event.What = evKeyDown) and (Event.CharCode in ['a', 'A']) then
    begin
      Desktop^.GetExtent(DeskR);
      Owner^.MakeGlobal(Origin, R.A);
      R.A.X := R.A.X + 1; R.A.Y := R.A.Y + 1;
      R.Assign(R.A.X, R.A.Y, DeskR.B.X, DeskR.B.Y);
      MenuData := BuildAddEffectMenu;
      MenuBoxPtr := New(PMenuBox, Init(R, MenuData, nil));
      Cmd := Desktop^.ExecView(MenuBoxPtr);
      Dispose(MenuBoxPtr, Done);
      DisposeMenu(MenuData);
      if Cmd >= cmAddEffectBase then
        SendRecv(EncodeAddEffect(Cmd - cmAddEffectBase));
      ClearEvent(Event);
    end;
  end;
end;

{ TDysTrackerApp - InitDeskTop builds the three docked panes the same way
  TDysnomiaApp.InitDeskTop (DysnomiaApp.pas) builds its own five: a fresh
  PDeskTop, DysWidgets.TDysPane's own InitPane(Bounds, Title) as the
  bordered container for each, Focusable set to the pane's real content
  view so Tab-cycling (TDysPane.HandleEvent, already inherited) lands
  focus somewhere useful. Esc key/Alt+X quitting, mouse, resize etc. all
  come from TApplication.Run unchanged - no reimplementation of Free
  Vision's own event loop, unlike an earlier draft of this file. }

procedure TDysTrackerApp.InitDeskTop;
var
  R, Full: TRect;
  Transport: PTrackerTransportBar;
  Grid: PTrackerGridContent;
  Fx: PTrackerEffectsContent;
  TransportPane, GridPane, EffectsPane: PDysPane;
begin
  GetExtent(Full);
  DeskTop := New(PDeskTop, Init(Full));

  R.Assign(Full.A.X, Full.A.Y, Full.B.X, Full.A.Y + 3);
  TransportPane := New(PDysPane, InitPane(R, 'Transport'));
  R := TransportPane^.ContentRect;
  R.Assign(0, 0, R.B.X - R.A.X, 1);
  Transport := New(PTrackerTransportBar, Init(R));
  TransportPane^.Insert(Transport);
  TransportPane^.Focusable := @Transport^;
  TransportBar := Transport;
  DeskTop^.Insert(TransportPane);

  R.Assign(Full.A.X, Full.A.Y + 3, Full.A.X + (Full.B.X - Full.A.X) * 3 div 5,
    Full.B.Y);
  GridPane := New(PDysPane, InitPane(R, 'Tracker'));
  R := GridPane^.ContentRect;
  R.Assign(0, 0, R.B.X - R.A.X, R.B.Y - R.A.Y);
  Grid := New(PTrackerGridContent, Init(R));
  GridPane^.Insert(Grid);
  GridPane^.Focusable := @Grid^;
  GridContent := Grid;
  DeskTop^.Insert(GridPane);

  R.Assign(Full.A.X + (Full.B.X - Full.A.X) * 3 div 5, Full.A.Y + 3, Full.B.X,
    Full.B.Y);
  EffectsPane := New(PDysPane, InitPane(R, 'Effects'));
  R := EffectsPane^.ContentRect;
  R.Assign(0, 0, R.B.X - R.A.X, R.B.Y - R.A.Y);
  Fx := New(PTrackerEffectsContent, Init(R));
  EffectsPane^.Insert(Fx);
  EffectsPane^.Focusable := @Fx^;
  EffectsContent := Fx;
  DeskTop^.Insert(EffectsPane);
end;

{ Same "no timer, poll on Idle" shape as TDysnomiaApp.Idle (DysnomiaApp.
  pas) - GET_STATE once every PollEveryTicks ticks, Sleep(10) every tick. }
procedure TDysTrackerApp.Idle;
begin
  inherited Idle;
  Inc(PollTick);
  if PollTick mod PollEveryTicks = 0 then
  begin
    PollState;
    if TransportBar <> nil then
    begin
      PTrackerTransportBar(TransportBar)^.SyncButtons;
      PTrackerTransportBar(TransportBar)^.DrawView;
    end;
    if GridContent <> nil then PView(GridContent)^.DrawView;
    if EffectsContent <> nil then PView(EffectsContent)^.DrawView;
  end;
  Sleep(10);
end;

procedure RunDysTracker;
var
  TrackerApp: TDysTrackerApp;
begin
  ResizePattern;
  TryConnect;
  TrackerApp.Init;
  TrackerApp.Run;
  TrackerApp.Done;
  DropConnection;
end;

end.
