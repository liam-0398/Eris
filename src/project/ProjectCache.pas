unit ProjectCache;

{$mode objfpc}{$H+}

interface

{ Binary sidecar ("cache.bin") stored inside the .er bundle next to
  project.ini, holding two kinds of thing that make opening a project slow:

  1. Everything the load has to COMPUTE from a sample rather than read -
     waveform peaks, transients and the fundamental period. Those three
     passes over the audio cost several times what decoding the file costs
     (DetectFundamentalPeriod alone is an autocorrelation over the loudest
     window), and they are pure functions of the sample data, so the answer
     from last save is still the right answer as long as the audio hasn't
     changed. Each entry carries a fingerprint of the audio it was computed
     from and is discarded if the decoded sample doesn't match it.

  2. The clip lists, warp markers included, in fixed-width binary instead of
     project.ini's packed text - no digit-by-digit parsing and no format
     settings, just a length and a block read. The ini's ClipsPacked keys are
     still written and remain the authority: the cache records a stamp
     (ClipTextStamp) over exactly that text, and the load only trusts the
     binary clips when the stamp still matches what the ini says. So a
     hand-edited or externally-rewritten project.ini silently wins over a
     stale cache rather than being ignored.

  The whole file is optional. Nothing here is data the project can't be
  reconstructed without: a missing, truncated, corrupt or version-mismatched
  cache.bin just makes LoadProject do the work the old way, which is what
  loading a project saved by an older build does. }

uses
  SampleTypes, Waveform;

const
  ProjectCacheFileName = 'cache.bin';

type
  { one pool slot's worth of derived analysis, plus the fingerprint of the
    audio it was derived from. StoredPath is the exact string written to the
    ini's Samples/PathN key, so a pool whose entries have been reordered or
    replaced can't silently take another slot's analysis. }
  TSampleCacheEntry = record
    StoredPath: string;
    FrameCount, Channels, SampleRate: Integer;
    DataHash: QWord;
    PeriodFrames: Integer;
    Peaks: TWaveformPeaks;
    Transients: TFrameArray;
  end;
  TSampleCacheEntryArray = array of TSampleCacheEntry;

  TTrackClipsArray = array of TClipArray;

  TProjectCacheData = record
    ClipStamp: QWord;
    Tracks: TTrackClipsArray;
    Samples: TSampleCacheEntryArray;
  end;

{ Cheap content fingerprint of a decoded sample: FNV-1a over up to
  FingerprintTaps evenly-strided 32-bit words of the audio, mixed with the
  total length. Strided rather than complete because this runs on the load
  path and a full pass would eat a good part of what the cache just saved -
  65536 taps is enough that two different files sharing a length, channel
  count, rate AND every tap is not a case worth engineering against, while
  costing well under a millisecond even on a long take. }
function SampleDataFingerprint(AData: PSingle; AFrameCount, AChannels: Integer): QWord;

{ FNV-1a over the per-track packed clip strings exactly as project.ini holds
  them (see ProjectFile.PackClips). Written into the cache at save and
  recomputed from the ini at load - equal means the binary clip block below
  still describes the same arrangement as the text does. }
function ClipTextStamp(const ATexts: array of string): QWord;

function WriteProjectCache(const APath: string; const AData: TProjectCacheData): Boolean;

{ False (with AData zeroed) for any file that is missing, unreadable, not
  ours, a different version, or damaged in any way - never an exception and
  never a partially-populated result the caller could mistake for a hit. }
function ReadProjectCache(const APath: string; out AData: TProjectCacheData): Boolean;

implementation

uses
  SysUtils, Classes;

const
  CacheMagic: array[0..7] of AnsiChar = 'ERISCACH';
  { 2: Waveform.DetectFundamentalPeriod changed shape - its inner reductions
    are reassociated (and FMA-fused where the CPU allows), and ELag is now
    slid from lag to lag instead of recomputed. The answer it produces is a
    lag in samples and is overwhelmingly likely to be identical, but it is
    not GUARANTEED identical, and that is enough to matter here: an entry
    written by an older build would be trusted on a cache hit while a
    re-import of the same audio recomputed it, so one sample could end up
    warping two ways depending on nothing but cache state. Bumping forces
    every existing entry to be recomputed once, after which hits and misses
    agree again. Raise this whenever any of the three cached analyses
    changes its output for the same input, for the same reason.
    3: per-clip binary layout gained a DragZones block (WarpModeDrag) right
    after WarpMarkers - an old-version cache is a byte-for-byte different
    shape, not just different analysis output, so it must be rejected
    outright rather than misparsed; the version check does that. }
  CacheVersion = 3;

  FnvOffset: QWord = QWord(14695981039346656037);
  FnvPrime: QWord = QWord(1099511628211);

  FingerprintTaps = 65536;

  { sanity ceilings for counts read back out of a file that may be damaged -
    every count is also bounds-checked against the bytes actually left, so
    these only exist to stop an absurd length allocating before that check }
  MaxCacheTracks = 4096;
  MaxCacheClipsPerTrack = 1 shl 22;
  MaxCacheSamples = 1 shl 20;
  MaxCacheStrLen = 1 shl 16;
  MaxCacheMarkersPerClip = 1 shl 20;
  MaxCacheTransients = 1 shl 24;

function SampleDataFingerprint(AData: PSingle; AFrameCount, AChannels: Integer): QWord;
var
  Total, Stride, i: PtrInt;
  H: QWord;
  Words: PLongWord;
begin
  H := FnvOffset;
  if (AData = nil) or (AFrameCount <= 0) or (AChannels <= 0) then
    Exit(H);

  Total := PtrInt(AFrameCount) * AChannels;
  Stride := (Total + FingerprintTaps - 1) div FingerprintTaps;
  if Stride < 1 then
    Stride := 1;

  { hashed as raw 32-bit patterns, not as floats - no comparisons are done on
    the values, so NaN/denormal bit patterns are just bytes here }
  Words := PLongWord(AData);
  i := 0;
  while i < Total do
  begin
    H := (H xor QWord(Words[i])) * FnvPrime;
    Inc(i, Stride);
  end;

  H := (H xor QWord(Total)) * FnvPrime;
  H := (H xor QWord(AChannels)) * FnvPrime;
  Result := H;
end;

function ClipTextStamp(const ATexts: array of string): QWord;
var
  t, i, L: Integer;
  H: QWord;
begin
  H := FnvOffset;
  H := (H xor QWord(Length(ATexts))) * FnvPrime;
  for t := 0 to High(ATexts) do
  begin
    L := Length(ATexts[t]);
    H := (H xor QWord(L)) * FnvPrime;
    for i := 1 to L do
      H := (H xor QWord(Ord(ATexts[t][i]))) * FnvPrime;
  end;
  Result := H;
end;

procedure WrInt32(AStream: TStream; AValue: LongInt);
begin
  AStream.WriteBuffer(AValue, SizeOf(AValue));
end;

procedure WrInt64(AStream: TStream; AValue: Int64);
begin
  AStream.WriteBuffer(AValue, SizeOf(AValue));
end;

procedure WrQWord(AStream: TStream; AValue: QWord);
begin
  AStream.WriteBuffer(AValue, SizeOf(AValue));
end;

procedure WrSingle(AStream: TStream; AValue: Single);
begin
  AStream.WriteBuffer(AValue, SizeOf(AValue));
end;

procedure WrStr(AStream: TStream; const AValue: string);
begin
  WrInt32(AStream, Length(AValue));
  if Length(AValue) > 0 then
    AStream.WriteBuffer(AValue[1], Length(AValue));
end;

function WriteProjectCache(const APath: string; const AData: TProjectCacheData): Boolean;
var
  Mem: TMemoryStream;
  t, i, c, m: Integer;
  Clips: TClipArray;
begin
  Result := False;
  Mem := TMemoryStream.Create;
  try
    try
      Mem.WriteBuffer(CacheMagic, SizeOf(CacheMagic));
      WrInt32(Mem, CacheVersion);
      WrQWord(Mem, AData.ClipStamp);

      WrInt32(Mem, Length(AData.Tracks));
      for t := 0 to High(AData.Tracks) do
      begin
        Clips := AData.Tracks[t];
        WrInt32(Mem, Length(Clips));
        for c := 0 to High(Clips) do
        begin
          WrInt32(Mem, Clips[c].SampleID);
          WrInt64(Mem, Clips[c].Offset);
          WrInt64(Mem, Clips[c].Length);
          WrInt64(Mem, Clips[c].Position);
          WrSingle(Mem, Clips[c].PitchSemitones);
          WrSingle(Mem, Clips[c].Gain);
          WrInt32(Mem, Clips[c].WarpMode);
          { TrackID is deliberately not stored - the reader stamps it from
            the track the clip was read back under, which is the only value
            it can correctly have }
          WrInt32(Mem, Length(Clips[c].WarpMarkers));
          for m := 0 to High(Clips[c].WarpMarkers) do
          begin
            WrInt64(Mem, Clips[c].WarpMarkers[m].SourceFrame);
            WrInt64(Mem, Clips[c].WarpMarkers[m].TimelineFrame);
          end;
          WrInt32(Mem, Length(Clips[c].DragZones));
          for m := 0 to High(Clips[c].DragZones) do
          begin
            WrInt64(Mem, Clips[c].DragZones[m].SourceStart);
            WrInt64(Mem, Clips[c].DragZones[m].SourceEnd);
            WrInt64(Mem, Clips[c].DragZones[m].Shift);
          end;
        end;
      end;

      WrInt32(Mem, Length(AData.Samples));
      for i := 0 to High(AData.Samples) do
      begin
        WrStr(Mem, AData.Samples[i].StoredPath);
        WrInt32(Mem, AData.Samples[i].FrameCount);
        WrInt32(Mem, AData.Samples[i].Channels);
        WrInt32(Mem, AData.Samples[i].SampleRate);
        WrQWord(Mem, AData.Samples[i].DataHash);
        WrInt32(Mem, AData.Samples[i].PeriodFrames);

        { Mins and Maxs are always the same length (ComputeWaveformPeaks
          sizes them together), so one count covers both }
        WrInt32(Mem, Length(AData.Samples[i].Peaks.Mins));
        if Length(AData.Samples[i].Peaks.Mins) > 0 then
        begin
          Mem.WriteBuffer(AData.Samples[i].Peaks.Mins[0],
            Length(AData.Samples[i].Peaks.Mins) * SizeOf(Single));
          Mem.WriteBuffer(AData.Samples[i].Peaks.Maxs[0],
            Length(AData.Samples[i].Peaks.Maxs) * SizeOf(Single));
        end;

        WrInt32(Mem, Length(AData.Samples[i].Transients));
        if Length(AData.Samples[i].Transients) > 0 then
          Mem.WriteBuffer(AData.Samples[i].Transients[0],
            Length(AData.Samples[i].Transients) * SizeOf(Int64));
      end;

      Mem.SaveToFile(APath);
      Result := True;
    except
      { the cache is an optimisation - a disk-full or permission failure
        here must not fail the save that is otherwise complete }
      Result := False;
    end;
  finally
    Mem.Free;
  end;

  if not Result then
    DeleteFile(APath);
end;

type
  { plain bounds-checked cursor over the whole file, read into memory in one
    go - every Rd* below returns False rather than raising if the file ends
    early, so a truncated cache degrades to a cache miss }
  TCacheReader = record
    Base: PByte;
    Size, Pos: PtrInt;
  end;

function RdAvail(const AR: TCacheReader; ABytes: PtrInt): Boolean;
begin
  Result := (ABytes >= 0) and (AR.Pos + ABytes <= AR.Size);
end;

function RdRaw(var AR: TCacheReader; ADest: Pointer; ABytes: PtrInt): Boolean;
begin
  if not RdAvail(AR, ABytes) then
    Exit(False);
  if ABytes > 0 then
    Move((AR.Base + AR.Pos)^, ADest^, ABytes);
  Inc(AR.Pos, ABytes);
  Result := True;
end;

function RdInt32(var AR: TCacheReader; out AValue: LongInt): Boolean;
begin
  Result := RdRaw(AR, @AValue, SizeOf(AValue));
end;

function RdInt64(var AR: TCacheReader; out AValue: Int64): Boolean;
begin
  Result := RdRaw(AR, @AValue, SizeOf(AValue));
end;

function RdQWord(var AR: TCacheReader; out AValue: QWord): Boolean;
begin
  Result := RdRaw(AR, @AValue, SizeOf(AValue));
end;

function RdSingle(var AR: TCacheReader; out AValue: Single): Boolean;
begin
  Result := RdRaw(AR, @AValue, SizeOf(AValue));
end;

{ reads a count that is about to size an allocation: rejected unless the
  bytes it claims to be followed by are actually present }
function RdCount(var AR: TCacheReader; AItemSize: PtrInt; AMax: LongInt;
  out AValue: LongInt): Boolean;
begin
  AValue := 0;
  if not RdInt32(AR, AValue) then
    Exit(False);
  Result := (AValue >= 0) and (AValue <= AMax) and
    RdAvail(AR, PtrInt(AValue) * AItemSize);
end;

function RdStr(var AR: TCacheReader; out AValue: string): Boolean;
var
  L: LongInt;
begin
  AValue := '';
  if not RdCount(AR, 1, MaxCacheStrLen, L) then
    Exit(False);
  SetLength(AValue, L);
  if L > 0 then
    Exit(RdRaw(AR, @AValue[1], L));
  Result := True;
end;

{ the parse proper - every failure path just leaves AData in whatever state
  it had reached, which ReadProjectCache below then discards wholesale }
function ParseProjectCache(const APath: string; var AData: TProjectCacheData): Boolean;
var
  Buf: array of Byte;
  R: TCacheReader;
  Magic: array[0..7] of AnsiChar;
  Version, TrackCount, ClipCount, MarkerCount, DragZoneCount, SampleCount,
    PeakCount, TransientCount: LongInt;
  t, c, m, i: Integer;
  Stream: TFileStream;
begin
  Result := False;
  AData.ClipStamp := 0;
  AData.Tracks := nil;
  AData.Samples := nil;

  if not FileExists(APath) then
    Exit;

  try
    Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try
      if Stream.Size <= 0 then
        Exit;
      SetLength(Buf, Stream.Size);
      Stream.ReadBuffer(Buf[0], Stream.Size);
    finally
      Stream.Free;
    end;
  except
    Exit;
  end;

  R.Base := @Buf[0];
  R.Size := Length(Buf);
  R.Pos := 0;

  if not RdRaw(R, @Magic, SizeOf(Magic)) then
    Exit;
  for i := 0 to High(Magic) do
    if Magic[i] <> CacheMagic[i] then
      Exit;
  if not RdInt32(R, Version) then
    Exit;
  if Version <> CacheVersion then
    Exit;
  if not RdQWord(R, AData.ClipStamp) then
    Exit;

  if not RdCount(R, 4, MaxCacheTracks, TrackCount) then
    Exit;
  SetLength(AData.Tracks, TrackCount);
  for t := 0 to TrackCount - 1 do
  begin
    if not RdCount(R, 4, MaxCacheClipsPerTrack, ClipCount) then
      Exit;
    SetLength(AData.Tracks[t], ClipCount);
    for c := 0 to ClipCount - 1 do
    begin
      if not RdInt32(R, AData.Tracks[t][c].SampleID) then Exit;
      if not RdInt64(R, AData.Tracks[t][c].Offset) then Exit;
      if not RdInt64(R, AData.Tracks[t][c].Length) then Exit;
      if not RdInt64(R, AData.Tracks[t][c].Position) then Exit;
      if not RdSingle(R, AData.Tracks[t][c].PitchSemitones) then Exit;
      if not RdSingle(R, AData.Tracks[t][c].Gain) then Exit;
      if not RdInt32(R, AData.Tracks[t][c].WarpMode) then Exit;
      AData.Tracks[t][c].TrackID := t;

      if not RdCount(R, 2 * SizeOf(Int64), MaxCacheMarkersPerClip, MarkerCount) then
        Exit;
      SetLength(AData.Tracks[t][c].WarpMarkers, MarkerCount);
      for m := 0 to MarkerCount - 1 do
      begin
        if not RdInt64(R, AData.Tracks[t][c].WarpMarkers[m].SourceFrame) then Exit;
        if not RdInt64(R, AData.Tracks[t][c].WarpMarkers[m].TimelineFrame) then Exit;
      end;

      if not RdCount(R, 3 * SizeOf(Int64), MaxCacheMarkersPerClip, DragZoneCount) then
        Exit;
      SetLength(AData.Tracks[t][c].DragZones, DragZoneCount);
      for m := 0 to DragZoneCount - 1 do
      begin
        if not RdInt64(R, AData.Tracks[t][c].DragZones[m].SourceStart) then Exit;
        if not RdInt64(R, AData.Tracks[t][c].DragZones[m].SourceEnd) then Exit;
        if not RdInt64(R, AData.Tracks[t][c].DragZones[m].Shift) then Exit;
      end;
    end;
  end;

  if not RdCount(R, 4, MaxCacheSamples, SampleCount) then
    Exit;
  SetLength(AData.Samples, SampleCount);
  for i := 0 to SampleCount - 1 do
  begin
    if not RdStr(R, AData.Samples[i].StoredPath) then Exit;
    if not RdInt32(R, AData.Samples[i].FrameCount) then Exit;
    if not RdInt32(R, AData.Samples[i].Channels) then Exit;
    if not RdInt32(R, AData.Samples[i].SampleRate) then Exit;
    if not RdQWord(R, AData.Samples[i].DataHash) then Exit;
    if not RdInt32(R, AData.Samples[i].PeriodFrames) then Exit;

    if not RdCount(R, 2 * SizeOf(Single), MaxWaveformBins, PeakCount) then
      Exit;
    SetLength(AData.Samples[i].Peaks.Mins, PeakCount);
    SetLength(AData.Samples[i].Peaks.Maxs, PeakCount);
    if PeakCount > 0 then
    begin
      if not RdRaw(R, @AData.Samples[i].Peaks.Mins[0], PeakCount * SizeOf(Single)) then Exit;
      if not RdRaw(R, @AData.Samples[i].Peaks.Maxs[0], PeakCount * SizeOf(Single)) then Exit;
    end;

    if not RdCount(R, SizeOf(Int64), MaxCacheTransients, TransientCount) then
      Exit;
    SetLength(AData.Samples[i].Transients, TransientCount);
    if TransientCount > 0 then
      if not RdRaw(R, @AData.Samples[i].Transients[0], TransientCount * SizeOf(Int64)) then
        Exit;
  end;

  Result := True;
end;

function ReadProjectCache(const APath: string; out AData: TProjectCacheData): Boolean;
begin
  AData.ClipStamp := 0;
  AData.Tracks := nil;
  AData.Samples := nil;

  Result := ParseProjectCache(APath, AData);
  if not Result then
  begin
    { a partial parse is worse than no parse - the caller checks counts and
      stamps, not how far the read got }
    AData.ClipStamp := 0;
    AData.Tracks := nil;
    AData.Samples := nil;
  end;
end;

end.
