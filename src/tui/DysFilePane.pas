unit DysFilePane;

{ Left dock: a real directory listing (".." to go up, Enter to select,
  Ctrl+I to drop straight in as an instrument track - see Bindings in
  tui.md). Stage 7: Enter on a real file decodes it, adds it to the sample
  pool, and hands it to the timeline as a pending overlay on whatever
  track DysTrackPane.SelectedTrackIndex reports - see DysTimeline for what
  happens next (Left/Right/Up/Down/Enter/Esc). Ctrl+I decodes the file the
  same way and assigns it straight to Project.TrackInstrument on that same
  track, skipping the overlay - which is also what flips that track's A/I/S
  letter on the timeline to 'I' (see DysTimeline.TrackTypeChar, which reads
  Project state fresh on every Draw). Actually driving the track live from
  a MIDI/computer keyboard once assigned is still stage 8. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Objects, Drivers, Views, Dialogs, MsgBox, DysWidgets, DysTimeline,
  DysTrackPane, Project, SampleTypes, WavDecoder;

type
  PDysFileListBox = ^TDysFileListBox;
  TDysFileListBox = object(TListBox)
    CurDir: string;
    constructor Init(Bounds: TRect);
    procedure Reload;
    procedure SelectItem(Item: Sw_Integer); virtual;
    procedure SelectAsInstrument(Item: Sw_Integer);
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  PDysFilePane = ^TDysFilePane;
  TDysFilePane = object(TDysPane)
    Listing: PDysFileListBox;
    constructor InitPane(Bounds: TRect);
  end;

const
  { Shared with DysFileDialog (project Load/Save/Save As), which browses
    from the same starting point as this pane's own sample browser. }
  DefaultBrowseDir = '/NFS/Music/Production';

implementation

{ Plain insertion sort, case-insensitive - the lists this sorts (one
  directory's worth of entries) are never long enough for anything fancier
  to matter. }
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

constructor TDysFileListBox.Init(Bounds: TRect);
begin
  inherited Init(Bounds, 1, nil);
  CurDir := IncludeTrailingPathDelimiter(DefaultBrowseDir);
  Reload;
end;

procedure TDysFileListBox.Reload;
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
        if (Ext = '.wav') or (Ext = '.aiff') then
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
end;

procedure TDysFileListBox.SelectItem(Item: Sw_Integer);
var
  Name, FullPath: string;
  Sample: TSample;
  SampleID: Integer;
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
  else if ActiveTimelineContent <> nil then
  begin
    FullPath := CurDir + Name;
    if DecodeSampleFile(FullPath, Sample) then
    begin
      SampleID := Project.AddSampleToPool(Sample, Name, FullPath);
      ActiveTimelineContent^.CursorTrack := SelectedTrackIndex;
      ActiveTimelineContent^.BeginOverlay(SampleID, Sample.FrameCount);
      ActiveTimelineContent^.Focus;
    end
    else
      MessageBox('Could not decode "' + Name + '" as audio.', nil,
        mfError or mfOKButton);
  end;
end;

procedure TDysFileListBox.SelectAsInstrument(Item: Sw_Integer);
var
  Name, FullPath: string;
  Sample: TSample;
  SampleID, TrackIdx: Integer;
begin
  Name := PString(List^.At(Item))^;
  if (Length(Name) = 0) or (Name[Length(Name)] = '/') or (Name = '..') then
    Exit;
  FullPath := CurDir + Name;
  if not DecodeSampleFile(FullPath, Sample) then
  begin
    MessageBox('Could not decode "' + Name + '" as audio.', nil,
      mfError or mfOKButton);
    Exit;
  end;
  SampleID := Project.AddSampleToPool(Sample, Name, FullPath);
  TrackIdx := SelectedTrackIndex;
  { Mirrors MainForm.AssignSampleAsKeyboardInstrumentFor (src/ui): the start/
    end trim markers default to the whole sample since there's no clip to
    inherit a trim window from here. }
  Project.TrackInstrument[TrackIdx] := SampleID;
  Project.TrackInstrumentStart[TrackIdx] := 0;
  Project.TrackInstrumentEnd[TrackIdx] := Sample.FrameCount;
  if ActiveTimelineContent <> nil then
    ActiveTimelineContent^.DrawView;
end;

procedure TDysFileListBox.HandleEvent(var Event: TEvent);
begin
  inherited HandleEvent(Event);
  if Event.What <> evKeyDown then
    Exit;
  if Event.KeyCode = kbEnter then
  begin
    if Focused < Range then
      SelectItem(Focused);
    ClearEvent(Event);
  end
  else if Event.KeyCode = kbCtrlI then
  begin
    if Focused < Range then
      SelectAsInstrument(Focused);
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
  Focusable := Listing;
end;

end.
