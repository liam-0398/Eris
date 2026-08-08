unit FileBrowser;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, ExtCtrls, StdCtrls, Graphics;

type
  TFileBrowser = class(TPanel)
  private
    FPathLabel: TLabel;
    FListBox: TListBox;
    FCurrentDir: string;
    function HasWavExtension(const AName: string): Boolean;
    procedure Populate;
    procedure ListBoxDblClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetDirectory(const ADir: string);
    function SelectedFullPath: string;
  end;

implementation

const
  WavExtension = '.wav';
  DefaultBrowseDir = '/NFS/Music/Production/';

constructor TFileBrowser.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;

  FPathLabel := TLabel.Create(Self);
  FPathLabel.Parent := Self;
  FPathLabel.Align := alTop;
  FPathLabel.AutoSize := False;
  FPathLabel.Height := 20;
  FPathLabel.Layout := tlCenter;

  FListBox := TListBox.Create(Self);
  FListBox.Parent := Self;
  FListBox.Align := alClient;
  FListBox.DragMode := dmAutomatic;
  FListBox.OnDblClick := @ListBoxDblClick;

  if DirectoryExists(DefaultBrowseDir) then
    SetDirectory(DefaultBrowseDir)
  else
    SetDirectory(GetEnvironmentVariable('HOME'));
end;

function TFileBrowser.HasWavExtension(const AName: string): Boolean;
begin
  Result := (Length(AName) > Length(WavExtension)) and
    (CompareText(Copy(AName, Length(AName) - Length(WavExtension) + 1,
      Length(WavExtension)), WavExtension) = 0);
end;

procedure TFileBrowser.Populate;
var
  SearchRec: TSearchRec;
  Dirs, Files: TStringList;
  i: Integer;
begin
  FListBox.Clear;
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
        else if HasWavExtension(SearchRec.Name) then
          Files.Add(SearchRec.Name);
      until FindNext(SearchRec) <> 0;
      FindClose(SearchRec);
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

procedure TFileBrowser.ListBoxDblClick(Sender: TObject);
var
  Item, NewDir: string;
begin
  if FListBox.ItemIndex < 0 then
    Exit;
  Item := FListBox.Items[FListBox.ItemIndex];

  if Item = '..' then
  begin
    NewDir := ExtractFileDir(FCurrentDir);
    if NewDir = '' then
      NewDir := PathDelim;
    SetDirectory(NewDir);
  end
  else if (Item <> '') and (Item[Length(Item)] = PathDelim) then
    SetDirectory(IncludeTrailingPathDelimiter(FCurrentDir) + Item);
end;

procedure TFileBrowser.SetDirectory(const ADir: string);
begin
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
