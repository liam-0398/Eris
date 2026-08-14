unit PhaseVocoder;

{$mode objfpc}{$H+}

{ AU ("Audio") warp mode, per warp.md: "Phase-locked phase vocoder with
  spectral flux onset detection with hand rolled cooley-turkey fft ... used
  to warp pads, synths, instruments etc ... quantizing existing audio up to
  1/54th-1/4th away from desired destination, occasionally longer."

  Unlike every other warp mode's renderer (Beats/Tones/RePitch/Drag), a
  phase vocoder is not a pure function of one output frame - each STFT grain
  depends on its neighbours through the phase accumulator, and grains
  overlap-add across a window several times wider than one sample. So this
  does not fit AudioEngine's per-frame pull model at all, and does not try
  to: GetAUAudio below runs the WHOLE stretch for a clip once, off the audio
  thread (see PushTrackToEngine/RenderProjectToWav, the only two callers),
  and caches the interleaved result. AudioEngine.AudioClipSample and
  Waveform.AudioSourceSample then do exactly what every other mode's
  renderer does: read one sample out of a buffer that is already
  timeline-shaped, by frame number. That also gets the realtime/offline
  byte-identity every other mode gets from sharing one code path - both
  callers hit the same cache entry for the same clip.

  Algorithm, per channel independently:

  - STFT with a Hann analysis window, hop = AFFTSize/4 (75% overlap, COLA
    for Hann). The analysis grain for each SYNTHESIS hop is read centered on
    SourceOfTimeline(outPos) - the clip's own marker map, interpolated
    per-segment exactly like RePitch - so the local stretch ratio can vary
    continuously across the clip with no drift: every grain's source
    position comes straight from the map, not from accumulating a variable
    hop.
  - Phase-locked ("identity phase locking", Puckette/Laroche-Dolson): find
    the local magnitude peaks in each grain's spectrum, phase-vocode ONLY
    the peaks (propagate expected phase advance from the true source
    displacement between grains), then lock every other bin's phase to its
    nearest peak by holding the bin's ORIGINAL offset from that peak's
    ORIGINAL phase. This is what TonesClipSample's header calls out as
    missing from a plain per-bin vocoder: peaks carry a note's harmonic
    stack's phase relationships along with them, which is what keeps chords
    and inharmonic/reverberant material from smearing into a phasy mush -
    a plain per-bin vocoder decorrelates every bin's phase independently and
    combs on exactly that material.
  - Spectral flux onset detection reseeds the phase lock with the frame's
    OWN measured phase (no vocoder continuity) at every detected onset, so
    an attack is reproduced with its true phase rather than one predicted
    from the audio before it - the same "never splice across a transient"
    principle the old sparse-splice AU renderer used, carried into a real
    STFT engine instead of being a substitute for having one.
  - Overlap-add with a second Hann window on the synthesis side (standard
    analysis+synthesis window pairing) normalized by the running sum of
    window^2, which is what makes the result unity-gain regardless of how
    much a given stretch ratio is overlapping grains.
  --------------------------------------------------------------------------- }

interface

uses
  SampleTypes;

{ Onset frames (absolute, file-relative - same convention as
  Project.SampleTransients) found by spectral flux: an FFT magnitude
  difference from one hop to the next, half-wave rectified and summed across
  bins, peak-picked above its own mean. AOffset/ALength bound the search to
  the region actually needed - the whole function is called only from
  BuildAUAudio, not exposed as a general per-sample analysis (see
  Waveform.DetectTransients for that, a different and coarser detector this
  intentionally does not replace). }
function DetectSpectralFluxOnsets(AData: PSingle; AOffset, ALength: Int64;
  AChannels, ASampleRate: Integer): TFrameArray;

{ Builds or fetches the cached phase-vocoder stretch of a clip's source
  audio for AU mode - see the unit header. Returns an interleaved
  AChannels-channel buffer, AOutFrameCount frames long, timeline-relative
  (index 0 is the clip's own timeline start, AOutFrameCount = AClipLength),
  or nil if it can't be built (fewer than 2 markers). The returned pointer is
  cache-owned; callers must not free it. AFFTSize is snapped to the nearest
  power of two in [512, 8192]. }
function GetAUAudio(AData: PSingle; AFrameCount, AChannels, ASampleRate: Integer;
  AOffset, AClipLength: Int64; const AMarkers: TWarpMarkerArray;
  AFFTSize: Integer; out AOutFrameCount: Integer): PSingle;

implementation

uses
  Math, FFT, AVector;

function SnapFFTSize(N: Integer): Integer;
begin
  Result := 512;
  while (Result < N) and (Result < 8192) do
    Result := Result * 2;
end;

function DetectSpectralFluxOnsets(AData: PSingle; AOffset, ALength: Int64;
  AChannels, ASampleRate: Integer): TFrameArray;
const
  N = 1024;
  Hop = N div 4;
  MinSpacingMs = 40;
  FluxThresholdMultiplier = 1.4;
var
  Window, Raw: array[0..N - 1] of Single;
  Re, Im: array[0..N - 1] of Single;
  Mag, PrevMag: array[0..N div 2] of Single;
  Flux: array of Single;
  NumFrames, f, i, ch, MinSpacing, ResultCount: Integer;
  LastOnset: Int64;
  Sum, MeanFlux, d: Double;
  Pos: Int64;
begin
  Result := nil;
  if (AData = nil) or (ALength < N) then
    Exit;

  FFT.HannWindow(@Window[0], N);
  NumFrames := (ALength - N) div Hop + 1;
  if NumFrames < 2 then
    Exit;
  SetLength(Flux, NumFrames);
  FillChar(PrevMag, SizeOf(PrevMag), 0);

  for f := 0 to NumFrames - 1 do
  begin
    Pos := AOffset + Int64(f) * Hop;
    for i := 0 to N - 1 do
    begin
      Sum := 0;
      for ch := 0 to AChannels - 1 do
        Sum := Sum + AData[(Pos + i) * AChannels + ch];
      Raw[i] := Sum / AChannels;
    end;
    VMul(@Re[0], @Raw[0], @Window[0], N);
    FillChar(Im, SizeOf(Im), 0);
    FFT.FFTComplex(@Re[0], @Im[0], N, False);

    Sum := 0;
    for i := 0 to N div 2 do
    begin
      Mag[i] := Sqrt(Re[i] * Re[i] + Im[i] * Im[i]);
      d := Mag[i] - PrevMag[i];
      if d > 0 then
        Sum := Sum + d;
    end;
    Flux[f] := Sum;
    Move(Mag[0], PrevMag[0], SizeOf(Mag));
  end;

  MeanFlux := 0;
  for f := 0 to NumFrames - 1 do
    MeanFlux := MeanFlux + Flux[f];
  MeanFlux := MeanFlux / NumFrames;

  MinSpacing := ((MinSpacingMs * ASampleRate) div 1000) div Hop;
  if MinSpacing < 1 then
    MinSpacing := 1;

  SetLength(Result, NumFrames);
  ResultCount := 0;
  LastOnset := -Int64(MinSpacing) - 1;
  for f := 1 to NumFrames - 2 do
    if (Flux[f] > MeanFlux * FluxThresholdMultiplier) and
      (Flux[f] >= Flux[f - 1]) and (Flux[f] >= Flux[f + 1]) and
      (f - LastOnset >= MinSpacing) then
    begin
      Result[ResultCount] := AOffset + Int64(f) * Hop;
      Inc(ResultCount);
      LastOnset := f;
    end;
  SetLength(Result, ResultCount);
end;

{ Nominal source position for timeline frame ATimeline (clip-relative on
  both axes), interpolated within whichever marker segment it falls in -
  the same per-segment-linear map WarpedSourcePosition uses for RePitch, but
  kept local rather than shared: the alternative was a Waveform<->
  PhaseVocoder circular unit dependency (Waveform.AudioSourceSample has to
  call GetAUAudio below), and this is 10 lines. }
function SourceOfTimeline(const AMarkers: TWarpMarkerArray; ATimeline: Double): Double;
var
  k: Integer;
  SegStartTimeline, SegStartSource, SegTimelineLen, SegSourceLen: Double;
begin
  k := 0;
  while (k < Length(AMarkers) - 2) and (ATimeline >= AMarkers[k + 1].TimelineFrame) do
    Inc(k);
  SegStartTimeline := AMarkers[k].TimelineFrame;
  SegStartSource := AMarkers[k].SourceFrame;
  SegTimelineLen := AMarkers[k + 1].TimelineFrame - SegStartTimeline;
  SegSourceLen := AMarkers[k + 1].SourceFrame - SegStartSource;
  if SegTimelineLen <= 0 then
    Exit(SegStartSource);
  Result := SegStartSource + (ATimeline - SegStartTimeline) * SegSourceLen / SegTimelineLen;
end;

{ Wrap A into (-Pi, Pi] - the standard phase vocoder unwrap step, applied to
  a measured-vs-predicted phase deviation before it's used as a frequency
  estimate. }
function PrincipalAngle(A: Double): Double;
begin
  Result := A - 2 * Pi * Round(A / (2 * Pi));
end;

function BuildAUAudio(AData: PSingle; AFrameCount, AChannels, ASampleRate: Integer;
  AOffset, AClipLength: Int64; const AMarkers: TWarpMarkerArray;
  AFFTSize: Integer; out AOutFrameCount: Integer): PSingle;
const
  { peaks below 1% of a frame's own loudest bin don't count - keeps a quiet/
    noisy frame from seeding phase locks off the noise floor }
  NoiseFloorRatio = 0.01;
var
  Half, Hs, ch, k, p, i, PeakCount, NearestIdx: Integer;
  Window, Raw, Re, Im, Mag, Phase, PrevAnaPhase, LastOutPhase, Grain: array of Single;
  Peaks: array of Integer;
  Acc, WinSum: array of Single;
  Onsets: TFrameArray;
  OnsetIdx: Integer;
  OutLen, OutPos, AbsStart, AbsFirst, AbsSpan, h: Int64;
  SrcCenter, SrcCenterPrev, Ha, MaxMag, s: Double;
  CrossedOnset: Boolean;
  Buf: PSingle;
begin
  Result := nil;
  AOutFrameCount := 0;
  if Length(AMarkers) < 2 then
    Exit;
  OutLen := AClipLength;
  if OutLen < 1 then
    Exit;

  Half := AFFTSize div 2;
  Hs := AFFTSize div 4;

  SetLength(Window, AFFTSize);
  FFT.HannWindow(@Window[0], AFFTSize);

  { onset search only needs to cover the source span the marker map actually
    reads, padded by one grain each side }
  AbsFirst := AOffset + Round(SourceOfTimeline(AMarkers, 0)) - AFFTSize;
  if AbsFirst < 0 then
    AbsFirst := 0;
  AbsSpan := (AOffset + Round(SourceOfTimeline(AMarkers, OutLen)) + AFFTSize) - AbsFirst;
  if AbsFirst + AbsSpan > AFrameCount then
    AbsSpan := AFrameCount - AbsFirst;
  Onsets := DetectSpectralFluxOnsets(AData, AbsFirst, AbsSpan, AChannels, ASampleRate);

  GetMem(Buf, OutLen * AChannels * SizeOf(Single));
  FillChar(Buf^, OutLen * AChannels * SizeOf(Single), 0);

  SetLength(Raw, AFFTSize); SetLength(Re, AFFTSize); SetLength(Im, AFFTSize);
  SetLength(Grain, AFFTSize);
  SetLength(Mag, Half + 1); SetLength(Phase, Half + 1);
  SetLength(PrevAnaPhase, Half + 1); SetLength(LastOutPhase, Half + 1);
  SetLength(Peaks, Half + 1);
  SetLength(Acc, OutLen); SetLength(WinSum, OutLen);

  for ch := 0 to AChannels - 1 do
  begin
    FillChar(Acc[0], OutLen * SizeOf(Single), 0);
    FillChar(WinSum[0], OutLen * SizeOf(Single), 0);
    FillChar(PrevAnaPhase[0], Length(PrevAnaPhase) * SizeOf(Single), 0);
    FillChar(LastOutPhase[0], Length(LastOutPhase) * SizeOf(Single), 0);

    SrcCenterPrev := SourceOfTimeline(AMarkers, 0);
    OnsetIdx := 0;
    OutPos := 0;
    while OutPos < OutLen do
    begin
      SrcCenter := SourceOfTimeline(AMarkers, OutPos);
      if OutPos = 0 then
        Ha := Hs
      else
        Ha := SrcCenter - SrcCenterPrev;

      AbsStart := AOffset + Round(SrcCenter) - Half;
      for i := 0 to AFFTSize - 1 do
        if (AbsStart + i >= 0) and (AbsStart + i < AFrameCount) then
          Raw[i] := AData[(AbsStart + i) * AChannels + ch]
        else
          Raw[i] := 0;
      VMul(@Re[0], @Raw[0], @Window[0], AFFTSize);
      FillChar(Im[0], AFFTSize * SizeOf(Single), 0);
      FFT.FFTComplex(@Re[0], @Im[0], AFFTSize, False);

      MaxMag := 0;
      for k := 0 to Half do
      begin
        Mag[k] := Sqrt(Re[k] * Re[k] + Im[k] * Im[k]);
        Phase[k] := ArcTan2(Im[k], Re[k]);
        if Mag[k] > MaxMag then
          MaxMag := Mag[k];
      end;

      PeakCount := 0;
      for k := 0 to Half do
      begin
        if Mag[k] < MaxMag * NoiseFloorRatio then
          Continue;
        if ((k = 0) or (Mag[k] >= Mag[k - 1])) and
          ((k = Half) or (Mag[k] >= Mag[k + 1])) then
        begin
          Peaks[PeakCount] := k;
          Inc(PeakCount);
        end;
      end;
      if PeakCount = 0 then
      begin
        Peaks[0] := 0;
        PeakCount := 1;
      end;

      { did the grain's own center just cross a detected onset since the
        previous grain? if so this grain's phase is not predicted, it is
        measured - see the unit header }
      while (OnsetIdx < Length(Onsets)) and (Onsets[OnsetIdx] < AOffset + Round(SrcCenter)) do
        Inc(OnsetIdx);
      CrossedOnset := (OutPos = 0) or
        ((OnsetIdx < Length(Onsets)) and
         (Onsets[OnsetIdx] >= AOffset + Round(SrcCenterPrev)) and
         (Onsets[OnsetIdx] < AOffset + Round(SrcCenter)));

      { propagate the peaks' phase via the standard vocoder step ... }
      for p := 0 to PeakCount - 1 do
      begin
        k := Peaks[p];
        if CrossedOnset then
          LastOutPhase[k] := Phase[k]
        else
          LastOutPhase[k] := LastOutPhase[k] + (2 * Pi * k / AFFTSize) * Ha +
            PrincipalAngle(Phase[k] - PrevAnaPhase[k] - (2 * Pi * k / AFFTSize) * Ha);
      end;

      { ... then lock every other bin to its nearest peak, holding the ORIGINAL
        phase offset from that peak - identity phase locking }
      NearestIdx := 0;
      for k := 0 to Half do
      begin
        while (NearestIdx < PeakCount - 1) and
          (Abs(Peaks[NearestIdx + 1] - k) <= Abs(Peaks[NearestIdx] - k)) do
          Inc(NearestIdx);
        p := Peaks[NearestIdx];
        if k <> p then
        begin
          if CrossedOnset then
            LastOutPhase[k] := Phase[k]
          else
            LastOutPhase[k] := LastOutPhase[p] + (Phase[k] - Phase[p]);
        end;
      end;

      for k := 0 to Half do
      begin
        Re[k] := Mag[k] * Cos(LastOutPhase[k]);
        Im[k] := Mag[k] * Sin(LastOutPhase[k]);
      end;
      for k := 1 to AFFTSize - Half - 1 do
      begin
        Re[AFFTSize - k] := Re[k];
        Im[AFFTSize - k] := -Im[k];
      end;
      FFT.FFTComplex(@Re[0], @Im[0], AFFTSize, True);
      VMul(@Grain[0], @Re[0], @Window[0], AFFTSize);

      for i := 0 to AFFTSize - 1 do
      begin
        h := OutPos - Half + i;
        if (h >= 0) and (h < OutLen) then
        begin
          Acc[h] := Acc[h] + Grain[i];
          WinSum[h] := WinSum[h] + Window[i] * Window[i];
        end;
      end;

      Move(Phase[0], PrevAnaPhase[0], Length(Phase) * SizeOf(Single));
      SrcCenterPrev := SrcCenter;
      Inc(OutPos, Hs);
    end;

    for i := 0 to OutLen - 1 do
    begin
      if WinSum[i] > 1e-9 then
        s := Acc[i] / WinSum[i]
      else
        s := 0;
      Buf[i * AChannels + ch] := s;
    end;
  end;

  Result := Buf;
  AOutFrameCount := OutLen;
end;

type
  TAUCacheEntry = record
    Key: QWord;
    Data: PSingle;
    FrameCount: Integer;
  end;

const
  AUCacheCapacity = 48;

var
  AUCache: array[0..AUCacheCapacity - 1] of TAUCacheEntry;
  AUCacheCount: Integer = 0;
  AUCacheNext: Integer = 0;

function HashAUKey(AData: PSingle; AFrameCount, AChannels, ASampleRate: Integer;
  AOffset, AClipLength: Int64; const AMarkers: TWarpMarkerArray; AFFTSize: Integer): QWord;
const
  FnvPrime: QWord = QWord(1099511628211);
var
  h: QWord;
  m: Integer;

  procedure Mix(V: QWord);
  begin
    h := (h xor V) * FnvPrime;
  end;

begin
  h := QWord(14695981039346656037);
  Mix(QWord(PtrUInt(AData)));
  Mix(QWord(AFrameCount));
  Mix(QWord(AChannels));
  Mix(QWord(ASampleRate));
  Mix(QWord(AOffset));
  Mix(QWord(AClipLength));
  Mix(QWord(AFFTSize));
  for m := 0 to High(AMarkers) do
  begin
    Mix(QWord(AMarkers[m].SourceFrame));
    Mix(QWord(AMarkers[m].TimelineFrame));
  end;
  Result := h;
end;

function GetAUAudio(AData: PSingle; AFrameCount, AChannels, ASampleRate: Integer;
  AOffset, AClipLength: Int64; const AMarkers: TWarpMarkerArray;
  AFFTSize: Integer; out AOutFrameCount: Integer): PSingle;
var
  Key: QWord;
  i, Slot: Integer;
begin
  AOutFrameCount := 0;
  Result := nil;
  if (AData = nil) or (Length(AMarkers) < 2) then
    Exit;

  AFFTSize := SnapFFTSize(AFFTSize);
  Key := HashAUKey(AData, AFrameCount, AChannels, ASampleRate, AOffset,
    AClipLength, AMarkers, AFFTSize);

  for i := 0 to AUCacheCount - 1 do
    if AUCache[i].Key = Key then
    begin
      AOutFrameCount := AUCache[i].FrameCount;
      Exit(AUCache[i].Data);
    end;

  Result := BuildAUAudio(AData, AFrameCount, AChannels, ASampleRate, AOffset,
    AClipLength, AMarkers, AFFTSize, AOutFrameCount);
  if Result = nil then
    Exit;

  { fixed-capacity ring: builds only ever happen off the audio thread
    (PushTrackToEngine/RenderProjectToWav), so what matters is bounding
    growth across a long editing session, not micro-optimising eviction }
  if AUCacheCount < AUCacheCapacity then
  begin
    Slot := AUCacheCount;
    Inc(AUCacheCount);
  end
  else
  begin
    Slot := AUCacheNext;
    AUCacheNext := (AUCacheNext + 1) mod AUCacheCapacity;
    if AUCache[Slot].Data <> nil then
      FreeMem(AUCache[Slot].Data);
  end;
  AUCache[Slot].Key := Key;
  AUCache[Slot].Data := Result;
  AUCache[Slot].FrameCount := AOutFrameCount;
end;

end.
