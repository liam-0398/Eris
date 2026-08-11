unit FileBrowser;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls, StdCtrls, Graphics, Dialogs, UIScale,
  Theme, Config
  {$IFDEF WINDOWS}, Windows, Forms{$ENDIF};

type
  TFileActivateEvent = procedure(Sender: TObject; const AFilePath: string) of object;

  TFileBrowser = class(TPanel)
  private
    FPathLabel: TLabel;
    FNavPanel: TPanel;
    FHomeButton: TButton;
    FRootButton: TButton;
    FCustom1Button: TButton;
    FCustom2Button: TButton;
    FDividerPanel: TPanel;
    FListBox: TListBox;
    FCurrentDir: string;
    FOnFileActivate: TFileActivateEvent;
    {$IFDEF WINDOWS}
    FPendingDir: string;
    FNavQueued: Boolean;
    {$ENDIF}
    function HasSampleExtension(const AName: string): Boolean;
    function UserHomeDir: string;
    procedure Populate;
    {$IFDEF WINDOWS}
    procedure PopulateDrives;
    function AtDriveRoot: Boolean;
    procedure AsyncNavigate(Data: PtrInt);
    {$ENDIF}
    procedure NavigateTo(const ADir: string);
    function CustomDir(AIndex: Integer): string;
    procedure StoreCustomDir(AIndex: Integer; const ADir: string);
    function ChooseCustomDir(AIndex: Integer): Boolean;
    procedure GoCustom(AIndex: Integer);
    procedure UpdateCustomHints;
    procedure ListBoxDblClick(Sender: TObject);
    procedure HomeButtonClick(Sender: TObject);
    procedure RootButtonClick(Sender: TObject);
    procedure Custom1ButtonClick(Sender: TObject);
    procedure Custom2ButtonClick(Sender: TObject);
    procedure CustomButtonMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    {$IFDEF WINDOWS}
    destructor Destroy; override;
    {$ENDIF}
    procedure ThemeRefresh;
    procedure SetDirectory(const ADir: string);
    function SelectedFullPath: string;
    property OnFileActivate: TFileActivateEvent read FOnFileActivate
      write FOnFileActivate;
  end;

implementation

const
  { every extension DecodeSampleFile can actually open - kept in sync with
    WavDecoder's own Decoders table by hand, since this panel only lists
    files, it doesn't decode them }
  SampleExtensions: array[0..3] of string = ('.wav', '.aiff', '.aif', '.mp3');
  DefaultBrowseDir = '/NFS/Music/Production/';
  {$IFDEF WINDOWS}
  { Sentinel FCurrentDir for the drive-list view. Windows has no single
    filesystem root to point "/" at, so it gets a pseudo-folder listing the
    drives instead - the equivalent of "This PC". It is deliberately not a
    valid path, so anything that would otherwise hit the filesystem has to
    test for it first. }
  DrivesDir = '::drives';
  {$ENDIF}

constructor TFileBrowser.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;

  FPathLabel := TLabel.Create(Self);
  FPathLabel.Parent := Self;
  FPathLabel.Align := alTop;
  FPathLabel.AutoSize := False;
  FPathLabel.Height := Px(24);
  FPathLabel.Layout := tlCenter;

  { quick-nav row between the path display and the file list: jump straight
    to the home folder or to the filesystem/drive root instead of clicking
    ".." repeatedly }
  FNavPanel := TPanel.Create(Self);
  FNavPanel.Parent := Self;
  FNavPanel.Align := alTop;
  FNavPanel.Height := Px(28);
  FNavPanel.BevelOuter := bvNone;

  FHomeButton := TButton.Create(Self);
  FHomeButton.Parent := FNavPanel;
  FHomeButton.Caption := 'H';
  FHomeButton.Align := alLeft;
  FHomeButton.Width := Px(32);
  FHomeButton.ShowHint := True;
  {$IFDEF WINDOWS}
  FHomeButton.Hint := 'Go to your user folder';
  {$ELSE}
  FHomeButton.Hint := 'Go to home folder';
  {$ENDIF}
  FHomeButton.OnClick := @HomeButtonClick;

  FRootButton := TButton.Create(Self);
  FRootButton.Parent := FNavPanel;
  FRootButton.Caption := '/';
  FRootButton.Align := alLeft;
  FRootButton.Width := Px(32);
  FRootButton.ShowHint := True;
  {$IFDEF WINDOWS}
  FRootButton.Hint := 'Show all drives';
  {$ELSE}
  FRootButton.Hint := 'Go to filesystem root';
  {$ENDIF}
  FRootButton.OnClick := @RootButtonClick;

  { two user-defined roots, e.g. a sample library and a downloads folder. Both
    start unconfigured: the first click asks for a folder, every click after
    that jumps straight to it (right-click re-picks). }
  FCustom1Button := TButton.Create(Self);
  FCustom1Button.Parent := FNavPanel;
  FCustom1Button.Caption := 'C1';
  FCustom1Button.Align := alLeft;
  FCustom1Button.Width := Px(32);
  FCustom1Button.ShowHint := True;
  FCustom1Button.OnClick := @Custom1ButtonClick;
  FCustom1Button.OnMouseDown := @CustomButtonMouseDown;

  FCustom2Button := TButton.Create(Self);
  FCustom2Button.Parent := FNavPanel;
  FCustom2Button.Caption := 'C2';
  FCustom2Button.Align := alLeft;
  FCustom2Button.Width := Px(32);
  FCustom2Button.ShowHint := True;
  FCustom2Button.OnClick := @Custom2ButtonClick;
  FCustom2Button.OnMouseDown := @CustomButtonMouseDown;

  UpdateCustomHints;

  FDividerPanel := TPanel.Create(Self);
  FDividerPanel.Parent := Self;
  FDividerPanel.Align := alTop;
  FDividerPanel.Height := Px(3);
  FDividerPanel.BevelOuter := bvNone;
  { a rule, not a container - this panel is nothing but its colour, so it
    opts out of ThemeApply's blanket recolour of TPanel (which would paint it
    button face and erase it) and takes the divider colour itself }
  FDividerPanel.Tag := ThemeTagSkip;
  FDividerPanel.Color := clWindowFrame;

  FListBox := TListBox.Create(Self);
  FListBox.Parent := Self;
  FListBox.Align := alClient;
  FListBox.DragMode := dmAutomatic;
  FListBox.OnDblClick := @ListBoxDblClick;

  if DirectoryExists(DefaultBrowseDir) then
    SetDirectory(DefaultBrowseDir)
  else
    SetDirectory(UserHomeDir);
end;

{$IFDEF WINDOWS}
{ a navigation deferred by NavigateTo must not outlive the panel it would
  repopulate - closing the app between the click and the idle call would
  otherwise land on a freed object }
destructor TFileBrowser.Destroy;
begin
  Application.RemoveAsyncCalls(Self);
  inherited Destroy;
end;
{$ENDIF}

{ What the "H" button means: the user's own top-level folder. }
function TFileBrowser.UserHomeDir: string;
begin
  {$IFDEF WINDOWS}
  { %USERPROFILE% (C:\Users\Name) is the real counterpart of $HOME. FPC's
    GetUserDir can hand back the Documents folder on Windows instead, which
    is a level too deep and not what this button is for - so only fall back
    to it if the environment gives us nothing usable.

    Qualified with SysUtils because the Windows unit in this unit's uses
    clause exports its own GetEnvironmentVariable - the raw Win32
    (PChar; PChar; LongWord): DWord one, which is not what's wanted here. }
  Result := SysUtils.GetEnvironmentVariable('USERPROFILE');
  if (Result = '') or not DirectoryExists(Result) then
    Result := SysUtils.GetEnvironmentVariable('HOMEDRIVE') +
      SysUtils.GetEnvironmentVariable('HOMEPATH');
  if (Result = '') or not DirectoryExists(Result) then
    Result := GetUserDir;
  {$ELSE}
  Result := GetUserDir;
  {$ENDIF}
end;

{$IFDEF WINDOWS}
{ True at the top of a drive, e.g. 'C:' - SetDirectory strips the trailing
  delimiter, so a drive root is exactly two characters. }
function TFileBrowser.AtDriveRoot: Boolean;
begin
  Result := (Length(FCurrentDir) = 2) and (FCurrentDir[2] = ':');
end;

procedure TFileBrowser.PopulateDrives;
var
  Mask: DWORD;
  i: Integer;
begin
  Mask := GetLogicalDrives;
  for i := 0 to 25 do
    if (Mask and (DWORD(1) shl i)) <> 0 then
      FListBox.Items.Add(Chr(Ord('A') + i) + ':' + PathDelim);
end;
{$ENDIF}

function TFileBrowser.HasSampleExtension(const AName: string): Boolean;
var
  Ext: string;
  i: Integer;
begin
  Result := False;
  Ext := LowerCase(ExtractFileExt(AName));
  for i := 0 to High(SampleExtensions) do
    if Ext = SampleExtensions[i] then
      Exit(True);
end;

procedure TFileBrowser.Populate;
var
  SearchRec: TSearchRec;
  Dirs, Files: TStringList;
  i: Integer;
begin
  FListBox.Clear;

  {$IFDEF WINDOWS}
  if FCurrentDir = DrivesDir then
  begin
    FPathLabel.Caption := 'This PC';
    PopulateDrives;
    Exit;
  end;
  {$ENDIF}

  FPathLabel.Caption := FCurrentDir;

  Dirs := TStringList.Create;
  Files := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(FCurrentDir) + '*', faAnyFile, SearchRec) = 0 then
    begin
      repeat
        if (SearchRec.Name = '') or (SearchRec.Name[1] = '.') then
          Continue;
        if (SearchRec.Attr and faDirectory) <> 0 then
          Dirs.Add(SearchRec.Name + PathDelim)
        else if HasSampleExtension(SearchRec.Name) then
          Files.Add(SearchRec.Name);
      until FindNext(SearchRec) <> 0;
      { qualified for the same reason as GetEnvironmentVariable above: on
        Windows the Windows unit's FindClose(QWord) shadows this one. Same
        symbol as the bare call on every other platform. }
      SysUtils.FindClose(SearchRec);
    end;
    Dirs.Sort;
    Files.Sort;

    if FCurrentDir <> PathDelim then
      FListBox.Items.Add('..');
    for i := 0 to Dirs.Count - 1 do
      FListBox.Items.Add(Dirs[i]);
    for i := 0 to Files.Count - 1 do
      FListBox.Items.Add(Files[i]);
  finally
    Dirs.Free;
    Files.Free;
  end;
end;

{$IFDEF WINDOWS}
procedure TFileBrowser.AsyncNavigate(Data: PtrInt);
begin
  FNavQueued := False;
  SetDirectory(FPendingDir);
end;
{$ENDIF}

{ Rebuilding the list is the last thing a double-click does everywhere, but on
  Windows it was happening *inside* the double-click message, while the list
  box still holds the mouse capture the dmAutomatic drag tracker took on the
  preceding button-down. Emptying the list out from under that tracker leaves
  the capture stuck with no control left to release it, and the whole app stops
  taking input - the "click .. and it hangs" freeze. So on Windows the drag is
  stopped first and the repopulate is deferred until the click's message has
  finished unwinding. GTK2 tracks drags itself and never had the problem, so
  the other platforms navigate inline exactly as before. }
procedure TFileBrowser.NavigateTo(const ADir: string);
begin
  {$IFDEF WINDOWS}
  if (DragManager <> nil) and DragManager.IsDragging then
    DragManager.DragStop(False);
  FPendingDir := ADir;
  if FNavQueued then
    Exit;
  FNavQueued := True;
  Application.QueueAsyncCall(@AsyncNavigate, 0);
  {$ELSE}
  SetDirectory(ADir);
  {$ENDIF}
end;

procedure TFileBrowser.ListBoxDblClick(Sender: TObject);
var
  Item, NewDir: string;
begin
  if FListBox.ItemIndex < 0 then
    Exit;
  Item := FListBox.Items[FListBox.ItemIndex];

  {$IFDEF WINDOWS}
  { in the drive list every entry is already an absolute root, so it replaces
    the current directory instead of being appended to it }
  if FCurrentDir = DrivesDir then
  begin
    NavigateTo(Item);
    Exit;
  end;
  {$ENDIF}

  if Item = '..' then
  begin
    {$IFDEF WINDOWS}
    { above a drive root there is only the drive list }
    if AtDriveRoot then
    begin
      NavigateTo(DrivesDir);
      Exit;
    end;
    {$ENDIF}
    NewDir := ExtractFileDir(FCurrentDir);
    if NewDir = '' then
      NewDir := PathDelim;
    NavigateTo(NewDir);
  end
  else if (Item <> '') and (Item[Length(Item)] = PathDelim) then
    NavigateTo(IncludeTrailingPathDelimiter(FCurrentDir) + Item)
  else if Assigned(FOnFileActivate) then
    FOnFileActivate(Self, IncludeTrailingPathDelimiter(FCurrentDir) + Item);
end;

procedure TFileBrowser.HomeButtonClick(Sender: TObject);
begin
  SetDirectory(UserHomeDir);
end;

{ Cfg is the single copy of these paths - the browser deliberately keeps no
  cached duplicate, so a config reload or a second browser instance can never
  disagree with what the buttons do. }
function TFileBrowser.CustomDir(AIndex: Integer): string;
begin
  if AIndex = 1 then
    Result := Cfg.Custom1Dir
  else
    Result := Cfg.Custom2Dir;
end;

procedure TFileBrowser.StoreCustomDir(AIndex: Integer; const ADir: string);
begin
  if AIndex = 1 then
    Cfg.Custom1Dir := ADir
  else
    Cfg.Custom2Dir := ADir;
  { written straight through rather than at shutdown: the choice was an
    explicit act by the user, and ConfigSave rewrites the whole record from
    Cfg, so nothing else in the file is disturbed }
  ConfigSave;
  UpdateCustomHints;
end;

{ False if the user cancelled - the caller must then leave the current
  directory alone rather than navigating anywhere. }
function TFileBrowser.ChooseCustomDir(AIndex: Integer): Boolean;
var
  Dlg: TSelectDirectoryDialog;
  StartDir: string;
begin
  Result := False;
  Dlg := TSelectDirectoryDialog.Create(nil);
  try
    Dlg.Title := Format('Choose the folder for C%d', [AIndex]);
    { open on the slot's own folder when it has one, otherwise wherever the
      browser is now - on Windows that can be the DrivesDir sentinel, which
      DirectoryExists rejects, leaving InitialDir unset as it should }
    StartDir := CustomDir(AIndex);
    if not DirectoryExists(StartDir) then
      StartDir := FCurrentDir;
    if DirectoryExists(StartDir) then
      Dlg.InitialDir := StartDir;
    if not Dlg.Execute then
      Exit;
    if not DirectoryExists(Dlg.FileName) then
      Exit;
    StoreCustomDir(AIndex, Dlg.FileName);
    Result := True;
  finally
    Dlg.Free;
  end;
end;

{ A slot whose folder has since been deleted or unmounted behaves like an
  unconfigured one and asks again, rather than navigating into nothing. }
procedure TFileBrowser.GoCustom(AIndex: Integer);
var
  Dir: string;
begin
  Dir := CustomDir(AIndex);
  if not DirectoryExists(Dir) then
  begin
    if not ChooseCustomDir(AIndex) then
      Exit;
    Dir := CustomDir(AIndex);
  end;
  SetDirectory(Dir);
end;

procedure TFileBrowser.UpdateCustomHints;

  function HintFor(AIndex: Integer): string;
  var
    Dir: string;
  begin
    Dir := CustomDir(AIndex);
    if Dir = '' then
      Result := Format('C%d: click to choose a folder', [AIndex])
    else
      Result := Dir + ' (right-click to change)';
  end;

begin
  FCustom1Button.Hint := HintFor(1);
  FCustom2Button.Hint := HintFor(2);
end;

procedure TFileBrowser.Custom1ButtonClick(Sender: TObject);
begin
  GoCustom(1);
end;

procedure TFileBrowser.Custom2ButtonClick(Sender: TObject);
begin
  GoCustom(2);
end;

{ The only way to re-point a slot once it is set: a right-click picks a new
  folder and goes there. Left-click never re-asks, because that would make the
  common case - jumping to a folder you use constantly - cost a dialog. }
procedure TFileBrowser.CustomButtonMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  Index: Integer;
begin
  if Button <> mbRight then
    Exit;
  if Sender = FCustom1Button then
    Index := 1
  else
    Index := 2;
  if ChooseCustomDir(Index) then
    SetDirectory(CustomDir(Index));
end;

procedure TFileBrowser.RootButtonClick(Sender: TObject);
begin
  {$IFDEF WINDOWS}
  { Windows has no single filesystem root, and jumping to the CURRENT drive's
    root can't reach any other drive - so this opens the drive list instead }
  SetDirectory(DrivesDir);
  {$ELSE}
  SetDirectory(PathDelim);
  {$ENDIF}
end;

{ Re-asserts the one colour a runtime theme switch cannot reach on its own.
  The divider carries ThemeTagSkip so the walk leaves it alone (button face
  would erase it), which also means the walk cannot update it - only its owner
  knows it is meant to be clWindowFrame rather than whatever it was built
  with. Called from TForm1.ApplyThemeChange. }
procedure TFileBrowser.ThemeRefresh;
begin
  FDividerPanel.Color := clWindowFrame;
end;

procedure TFileBrowser.SetDirectory(const ADir: string);
begin
  {$IFDEF WINDOWS}
  { the pseudo-folder is not a path - keep it verbatim }
  if ADir = DrivesDir then
  begin
    FCurrentDir := DrivesDir;
    Populate;
    Exit;
  end;
  {$ENDIF}

  FCurrentDir := ExcludeTrailingPathDelimiter(ADir);
  if FCurrentDir = '' then
    FCurrentDir := PathDelim;
  Populate;
end;

function TFileBrowser.SelectedFullPath: string;
var
  Item: string;
begin
  Result := '';
  if FListBox.ItemIndex < 0 then
    Exit;
  Item := FListBox.Items[FListBox.ItemIndex];
  if (Item = '..') or (Item = '') or (Item[Length(Item)] = PathDelim) then
    Exit;
  Result := IncludeTrailingPathDelimiter(FCurrentDir) + Item;
end;

end.
