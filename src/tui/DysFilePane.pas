unit DysFilePane;

{ Left dock: a real directory listing (".." to go up, Enter to select).
  This only touches the filesystem, never aengine/abackend/project, so it
  stays inside stage 1's "not hooked up to anything" - dropping a file on
  a track, and the shift-enter instrument-track shortcut, are stage 7
  work once there is a track/timeline to drop onto.

  Shift+Enter is designed but not implemented: a raw terminal has no way
  to report it. Shift does not change the byte(s) Enter sends (still CR),
  so xterm's basic key reporting is indistinguishable from plain Enter -
  unlike Ctrl+Enter, which FV already defines as kbCtrlEnter because
  Ctrl+M is a genuinely different byte (LF, $0A) from CR ($0D). Getting
  Shift+Enter to work needs a terminal-side extended keyboard protocol
  (e.g. xterm's modifyOtherKeys, or the kitty keyboard protocol) which
  Tiger's X11 xterm does not have, so it needs a decision before stage 7,
  not a guess baked in here. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Dialogs, MsgBox, DysWidgets;

type
  PDysFileListBox = ^TDysFileListBox;
  TDysFileListBox = object(TListBox)
    CurDir: string;
    constructor Init(Bounds: TRect);
    procedure Reload;
    procedure SelectItem(Item: Sw_Integer); virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PDysFilePane = ^TDysFilePane;
  TDysFilePane = object(TDysPane)
    Listing: PDysFileListBox;
    constructor InitPane(Bounds: TRect);
  end;

implementation

constructor TDysFileListBox.Init(Bounds: TRect);
begin
  inherited Init(Bounds, 1, nil);
  CurDir := IncludeTrailingPathDelimiter(GetCurrentDir);
  Reload;
end;

procedure TDysFileListBox.Reload;
var
  Entries: PUnSortedStrCollection;
  SR: TSearchRec;
begin
  Entries := New(PUnSortedStrCollection, Init(64, 16));
  Entries^.Insert(NewStr('..'));
  if FindFirst(CurDir + '*', faDirectory, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and
         ((SR.Attr and faDirectory) <> 0) then
        Entries^.Insert(NewStr(SR.Name + '/'));
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  if FindFirst(CurDir + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
        Entries^.Insert(NewStr(SR.Name));
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  NewList(Entries);
end;

procedure TDysFileListBox.SelectItem(Item: Sw_Integer);
var
  Name: string;
begin
  Name := PString(List^.At(Item))^;
  if Name = '..' then
  begin
    CurDir := IncludeTrailingPathDelimiter(
      ExtractFileDir(ExcludeTrailingPathDelimiter(CurDir)));
    Reload;
  end
  else if (Length(Name) > 0) and (Name[Length(Name)] = '/') then
  begin
    CurDir := CurDir + Name;
    Reload;
  end
  else
    MessageBox('Would overlay "' + Name +
      '" on the track under the cursor and drop it on Enter - stage 7.',
      nil, mfInformation or mfOKButton);
end;

procedure TDysFileListBox.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEnter) then
  begin
    if Focused < Range then
      SelectItem(Focused);
    ClearEvent(Event);
  end;
end;

constructor TDysFilePane.InitPane(Bounds: TRect);
var
  R: TRect;
begin
  inherited InitPane(Bounds, 'Files');
  R := ContentRect;
  Listing := New(PDysFileListBox, Init(R));
  Insert(Listing);
end;

end.
