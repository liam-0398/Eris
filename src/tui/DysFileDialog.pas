unit DysFileDialog;

{ The one file-browser dialog behind Load, Save and Save As (DysnomiaApp,
  see tui.md's Bindings) - same TDialog, same listbox, just a different
  title/button caption and a different thing the caller does with the path
  it returns. Modelled on DysPreferences.ShowPreferencesDialog: a plain
  procedural TDialog built from stock Free Vision controls, run with
  Desktop^.ExecView, read back off each control's own kept pointer, then
  Dispose - no custom TDialog descendant needed. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Dialogs, App, MsgBox, DysFilePane,
  ProjectFile;

type
  TDysFileDialogMode = (fdmOpen, fdmSave, fdmSaveAs);

{ Modal; returns True and AResultPath set (a full path, extension included)
  if the user confirmed, False on Cancel/Esc. AInitialDir seeds where the
  browse starts - the open project's own directory for Save/Save As once
  one exists, DysFilePane.DefaultBrowseDir otherwise (see DysnomiaApp).
  AInitialName seeds the Name field, e.g. the current project's own file
  name so Save As starts from something sensible rather than blank. }
function RunFileDialog(AMode: TDysFileDialogMode; const AInitialDir,
  AInitialName: string; out AResultPath: string): Boolean;

implementation

const
  DlgWidth = 60;
  DlgHeight = 22;

type
  { Dirs plus both project extensions (see ProjectFile.ProjectExt/
    StandaloneProjectExt) - Open, Save and Save As all browse the same
    listing, same as MainForm's own Open dialog filter covering both
    kinds at once (LoadProject tells them apart from the bundle's own
    contents, not from what was picked). Enter on a directory descends;
    Enter on a file copies its name into NameEdit (via the ActiveNameEdit
    global below) and immediately confirms the dialog - a normal Open/
    overwrite-Save pick needs nothing more than that. }
  PDysBrowseListBox = ^TDysBrowseListBox;
  TDysBrowseListBox = object(TListBox)
    CurDir: string;
    constructor Init(Bounds: TRect; const AInitialDir: string);
    procedure Reload;
    procedure SelectItem(Item: Sw_Integer); virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

var
  { Set for the duration of one RunFileDialog call - the listbox reaches
    through these to update the dialog's other controls on a pick/
    directory change, and to end the dialog once a file is chosen. Same
    "global points at the one live instance" pattern DysTrackPane's
    ActiveTrackPane and DysTimeline's ActiveTimelineContent already use,
    here scoped to the dialog's own short lifetime instead of the app's. }
  ActiveNameEdit: PInputLine = nil;
  ActivePathLabel: PStaticText = nil;
  ActiveDialog: PDialog = nil;

{ Plain insertion sort, case-insensitive - same small helper DysFilePane
  keeps for its own (also short) directory listing, not worth sharing a
  unit over. }
procedure SortStrings(var A: array of string; Count: Integer);
var
  i, j: Integer;
  Tmp: string;
begin
  for i := 1 to Count - 1 do
  begin
    Tmp := A[i];
    j := i - 1;
    while (j >= 0) and (CompareText(A[j], Tmp) > 0) do
    begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := Tmp;
  end;
end;

constructor TDysBrowseListBox.Init(Bounds: TRect; const AInitialDir: string);
begin
  inherited Init(Bounds, 1, nil);
  CurDir := IncludeTrailingPathDelimiter(AInitialDir);
  Reload;
end;

procedure TDysBrowseListBox.Reload;
var
  Entries: PUnSortedStrCollection;
  SR: TSearchRec;
  Dirs, Files: array of string;
  DirCount, FileCount, i: Integer;
  Ext: string;
begin
  DirCount := 0;
  FileCount := 0;
  Dirs := nil;
  Files := nil;

  if FindFirst(CurDir + '*', faDirectory, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and
         ((SR.Attr and faDirectory) <> 0) then
      begin
        SetLength(Dirs, DirCount + 1);
        Dirs[DirCount] := SR.Name + '/';
        Inc(DirCount);
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;

  if FindFirst(CurDir + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
      begin
        Ext := LowerCase(ExtractFileExt(SR.Name));
        if (Ext = ProjectFile.ProjectExt) or
           (Ext = ProjectFile.StandaloneProjectExt) then
        begin
          SetLength(Files, FileCount + 1);
          Files[FileCount] := SR.Name;
          Inc(FileCount);
        end;
      end;
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;

  SortStrings(Dirs, DirCount);
  SortStrings(Files, FileCount);

  Entries := New(PUnSortedStrCollection, Init(64, 16));
  Entries^.Insert(NewStr('..'));
  for i := 0 to DirCount - 1 do
    Entries^.Insert(NewStr(Dirs[i]));
  for i := 0 to FileCount - 1 do
    Entries^.Insert(NewStr(Files[i]));
  NewList(Entries);

  if ActivePathLabel <> nil then
  begin
    if ActivePathLabel^.Text <> nil then
      DisposeStr(ActivePathLabel^.Text);
    ActivePathLabel^.Text := NewStr(CurDir);
    ActivePathLabel^.DrawView;
  end;
end;

procedure TDysBrowseListBox.SelectItem(Item: Sw_Integer);
var
  Name: string;
  NameBuf: string[255];
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
  else if ActiveNameEdit <> nil then
  begin
    NameBuf := Name;
    ActiveNameEdit^.SetData(NameBuf);
    ActiveNameEdit^.DrawView;
    if ActiveDialog <> nil then
      ActiveDialog^.EndModal(cmOK);
  end;
end;

procedure TDysBrowseListBox.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEnter) then
  begin
    if Focused < Range then
      SelectItem(Focused);
    ClearEvent(Event);
  end;
end;

function RunFileDialog(AMode: TDysFileDialogMode; const AInitialDir,
  AInitialName: string; out AResultPath: string): Boolean;
var
  R: TRect;
  Dlg: PDialog;
  FileList: PDysBrowseListBox;
  PathLabel: PStaticText;
  NameEdit: PInputLine;
  Title, OKCaption: string;
  NameBuf: string[255];
  Res: Word;
  Dir, Name: string;
begin
  Result := False;
  AResultPath := '';

  Title := '';
  OKCaption := '';
  case AMode of
    fdmOpen:   begin Title := 'Open Project'; OKCaption := '~O~pen'; end;
    fdmSave:   begin Title := 'Save Project'; OKCaption := '~S~ave'; end;
    fdmSaveAs: begin Title := 'Save Project As'; OKCaption := '~S~ave'; end;
  end;

  R.Assign(0, 0, DlgWidth, DlgHeight);
  Dlg := New(PDialog, Init(R, Title));

  R.Assign(2, 1, DlgWidth - 2, 2);
  PathLabel := New(PStaticText, Init(R, ''));
  Dlg^.Insert(PathLabel);

  R.Assign(2, 2, DlgWidth - 2, DlgHeight - 5);
  FileList := New(PDysBrowseListBox, Init(R, AInitialDir));
  Dlg^.Insert(FileList);

  R.Assign(2, DlgHeight - 4, 8, DlgHeight - 3);
  Dlg^.Insert(New(PStaticText, Init(R, 'Name:')));
  R.Assign(8, DlgHeight - 4, DlgWidth - 2, DlgHeight - 3);
  NameEdit := New(PInputLine, Init(R, 255));
  NameBuf := AInitialName;
  NameEdit^.SetData(NameBuf);
  Dlg^.Insert(NameEdit);

  R.Assign(2, DlgHeight - 2, 16, DlgHeight - 1);
  Dlg^.Insert(New(PButton, Init(R, OKCaption, cmOK, bfDefault)));
  R.Assign(18, DlgHeight - 2, 30, DlgHeight - 1);
  Dlg^.Insert(New(PButton, Init(R, 'Cancel', cmCancel, bfNormal)));

  ActiveNameEdit := NameEdit;
  ActivePathLabel := PathLabel;
  ActiveDialog := Dlg;
  FileList^.Reload; { paint the path label with the seeded directory }

  Dlg^.SelectNext(False);
  { Same ExecView/Dispose pattern as DysPreferences.ShowPreferencesDialog -
    see tui.md's Free Vision notes for why reading each control's own
    pointer straight back is safe here. }
  Res := Desktop^.ExecView(Dlg);
  if Res = cmOK then
  begin
    Dir := FileList^.CurDir;
    Name := Trim(NameEdit^.Data^);
    if Name <> '' then
    begin
      { a bare name with no extension of its own defaults to a normal
        (non-standalone) project - see ProjectFile.ProjectExt/
        StandaloneProjectExt. }
      if (LowerCase(ExtractFileExt(Name)) <> ProjectFile.ProjectExt) and
         (LowerCase(ExtractFileExt(Name)) <> ProjectFile.StandaloneProjectExt) then
        Name := Name + ProjectFile.ProjectExt;
      AResultPath := Dir + Name;
      Result := True;
    end;
  end;

  ActiveNameEdit := nil;
  ActivePathLabel := nil;
  ActiveDialog := nil;
  Dispose(Dlg, Done);
end;

end.
