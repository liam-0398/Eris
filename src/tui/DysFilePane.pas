unit DysFilePane;

{ Left dock: a real directory listing (".." to go up, Enter to select,
  Ctrl+I to drop straight in as an instrument track - see Bindings in
  tui.md). Stage 7: Enter on a real file decodes it, adds it to the sample
  pool, and hands it to the timeline as a pending overlay on whatever
  track DysTrackPane.SelectedTrackIndex reports - see DysTimeline for what
  happens next (Left/Right/Up/Down/Enter/Esc). Ctrl+I (drop straight in as
  an instrument track) is still a stub - that needs a MIDI-live track
  concept the timeline doesn't have yet, stage 8. }

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
  Name: string;
begin
  Name := PString(List^.At(Item))^;
  if (Length(Name) > 0) and (Name[Length(Name)] <> '/') and (Name <> '..')
  then
    MessageBox('Would drop "' + Name +
      '" straight in as a new instrument track with the MIDI keyboard' +
      ' live - stage 7.', nil, mfInformation or mfOKButton);
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
