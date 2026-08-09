unit TarArchive;

{$mode objfpc}{$H+}

interface

{ Minimal ustar reader/writer - just enough to bundle/unbundle a project
  directory into a single .er file (regular files only, no symlinks/long
  names/etc., which is all Eris' own project bundles ever contain). No
  external "tar" binary required. }

function CreateTarFromDirectory(const ASourceDir, ATarPath: string): Boolean;
function ExtractTarToDirectory(const ATarPath, ADestDir: string): Boolean;

implementation

uses
  SysUtils, Classes, DateUtils;

const
  BlockSize = 512;

type
  TTarHeader = array[0..BlockSize - 1] of Byte;

function OctalStr(AValue: Int64; ADigits: Integer): string;
var
  i: Integer;
begin
  SetLength(Result, ADigits);
  for i := ADigits downto 1 do
  begin
    Result[i] := Chr(Ord('0') + (AValue mod 8));
    AValue := AValue div 8;
  end;
end;

function OctalVal(const AField: string): Int64;
var
  i: Integer;
  s: string;
begin
  Result := 0;
  s := Trim(AField);
  for i := 1 to Length(s) do
    if s[i] in ['0'..'7'] then
      Result := Result * 8 + (Ord(s[i]) - Ord('0'))
    else
      Break;
end;

function FieldStr(const AHeader: TTarHeader; AOffset, ALen: Integer): string;
var
  j: Integer;
begin
  Result := '';
  for j := 0 to ALen - 1 do
  begin
    if AHeader[AOffset + j] = 0 then
      Break;
    Result := Result + Chr(AHeader[AOffset + j]);
  end;
end;

procedure PutStr(var AHeader: TTarHeader; AOffset: Integer; const AValue: string);
var
  i: Integer;
begin
  for i := 1 to Length(AValue) do
    AHeader[AOffset + i - 1] := Ord(AValue[i]);
end;

function BuildHeader(const AName: string; ASize: Int64): TTarHeader;
var
  i, Sum: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  PutStr(Result, 0, AName);           { name, offset 0, len 100 }
  PutStr(Result, 100, '0000644');     { mode, offset 100, len 8 }
  PutStr(Result, 108, '0000000');     { uid }
  PutStr(Result, 116, '0000000');     { gid }
  PutStr(Result, 124, OctalStr(ASize, 11)); { size, offset 124, len 12 }
  PutStr(Result, 136, OctalStr(DateTimeToUnix(Now), 11)); { mtime }
  for i := 148 to 155 do
    Result[i] := Ord(' ');            { checksum field: spaces while summing }
  Result[156] := Ord('0');            { typeflag: regular file }
  PutStr(Result, 257, 'ustar');       { magic }
  Result[263] := Ord('0');            { version }
  Result[264] := Ord('0');

  Sum := 0;
  for i := 0 to BlockSize - 1 do
    Sum := Sum + Result[i];

  PutStr(Result, 148, OctalStr(Sum, 6));
  Result[154] := 0;
  Result[155] := Ord(' ');
end;

procedure AddFileEntry(ATarStream: TStream; const AArchiveName, AFullPath: string);
var
  Header: TTarHeader;
  Src: TFileStream;
  Size, Padded: Int64;
  ZeroBuf: array[0..BlockSize - 1] of Byte;
begin
  Src := TFileStream.Create(AFullPath, fmOpenRead or fmShareDenyWrite);
  try
    Size := Src.Size;
    Header := BuildHeader(AArchiveName, Size);
    ATarStream.WriteBuffer(Header, SizeOf(Header));
    ATarStream.CopyFrom(Src, Size);

    Padded := ((Size + BlockSize - 1) div BlockSize) * BlockSize;
    if Padded > Size then
    begin
      FillChar(ZeroBuf, SizeOf(ZeroBuf), 0);
      ATarStream.WriteBuffer(ZeroBuf, Padded - Size);
    end;
  finally
    Src.Free;
  end;
end;

procedure CollectFiles(const ABaseDir, ARelDir: string; AList: TStringList);
var
  SR: TSearchRec;
  RelPath: string;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ABaseDir) + ARelDir + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      RelPath := ARelDir + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        CollectFiles(ABaseDir, RelPath + '/', AList)
      else
        AList.Add(RelPath);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function CreateTarFromDirectory(const ASourceDir, ATarPath: string): Boolean;
var
  Files: TStringList;
  TarStream: TFileStream;
  i: Integer;
  ZeroBlock: TTarHeader;
begin
  Result := False;
  if not DirectoryExists(ASourceDir) then
    Exit;

  Files := TStringList.Create;
  try
    CollectFiles(ASourceDir, '', Files);

    TarStream := TFileStream.Create(ATarPath, fmCreate);
    try
      for i := 0 to Files.Count - 1 do
        AddFileEntry(TarStream, Files[i],
          IncludeTrailingPathDelimiter(ASourceDir) + Files[i]);

      { two all-zero blocks mark the end of the archive }
      FillChar(ZeroBlock, SizeOf(ZeroBlock), 0);
      TarStream.WriteBuffer(ZeroBlock, SizeOf(ZeroBlock));
      TarStream.WriteBuffer(ZeroBlock, SizeOf(ZeroBlock));
    finally
      TarStream.Free;
    end;

    Result := True;
  finally
    Files.Free;
  end;
end;

function ExtractTarToDirectory(const ATarPath, ADestDir: string): Boolean;
var
  TarStream: TFileStream;
  Header: TTarHeader;
  Name: string;
  Size, Padded, Remaining, ChunkSize: Int64;
  DestPath, DestDirPart: string;
  Dest: TFileStream;
  Buf: array[0..65535] of Byte;
  AllZero: Boolean;
  i: Integer;
begin
  Result := False;
  if not FileExists(ATarPath) then
    Exit;

  ForceDirectories(ADestDir);

  TarStream := TFileStream.Create(ATarPath, fmOpenRead or fmShareDenyWrite);
  try
    while TarStream.Position + BlockSize <= TarStream.Size do
    begin
      TarStream.ReadBuffer(Header, SizeOf(Header));

      AllZero := True;
      for i := 0 to BlockSize - 1 do
        if Header[i] <> 0 then
        begin
          AllZero := False;
          Break;
        end;
      if AllZero then
        Break; { end-of-archive marker }

      Name := FieldStr(Header, 0, 100);
      Size := OctalVal(FieldStr(Header, 124, 12));
      Padded := ((Size + BlockSize - 1) div BlockSize) * BlockSize;

      if Name <> '' then
      begin
        DestPath := IncludeTrailingPathDelimiter(ADestDir) +
          StringReplace(Name, '/', PathDelim, [rfReplaceAll]);
        DestDirPart := ExtractFilePath(DestPath);
        if DestDirPart <> '' then
          ForceDirectories(DestDirPart);

        Dest := TFileStream.Create(DestPath, fmCreate);
        try
          Remaining := Size;
          while Remaining > 0 do
          begin
            ChunkSize := Remaining;
            if ChunkSize > SizeOf(Buf) then
              ChunkSize := SizeOf(Buf);
            TarStream.ReadBuffer(Buf, ChunkSize);
            Dest.WriteBuffer(Buf, ChunkSize);
            Remaining := Remaining - ChunkSize;
          end;
        finally
          Dest.Free;
        end;

        if Padded > Size then
          TarStream.Seek(Padded - Size, soFromCurrent);
      end
      else if Padded > 0 then
        TarStream.Seek(Padded, soFromCurrent);
    end;

    Result := True;
  finally
    TarStream.Free;
  end;
end;

end.
