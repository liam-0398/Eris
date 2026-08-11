unit WavDecoder;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SampleTypes, AiffDecoder, Resample, AVector;
  { Mp3Decoder is not wired in yet - it doesn't exist as a unit yet, this
    is a deliberate midpoint so AIFF support and the sample-load thread fix
    can be built and tested independently of the still-unwritten MP3 port }

type
  TDecodeFunc = function(const APath: string; out ASample: TSample): Boolean;
  TDecoderEntry = record
    Ext: string;
    Decode: TDecodeFunc;
  end;

  { Incremental form of EncodeWav, for a caller that produces its audio a
    block at a time and would otherwise have to hold the whole thing in RAM
    just to hand it over - see ProjectFile.RenderProjectToWav.

    The total frame count is required up front, because that is what lets the
    header go out correct on the first write with no seek-back at the end: a
    render knows its own length before it starts. Writing more or fewer
    frames than declared produces a file whose header disagrees with its
    data, so don't.

    EncodeWav is implemented on top of this, so both paths share one copy of
    the header layout and the sample conversion and cannot drift apart. }
  TWavWriter = record
    Stream: TFileStream;
    Chunk: array of SmallInt;
    Declared: Int64;   { frames promised in the header }
    Written: Int64;    { frames actually handed over so far }
  end;

function DecodeWav(const APath: string; out ASample: TSample): Boolean;
function DecodeSampleFile(const APath: string; out ASample: TSample): Boolean;
function EncodeWav(const APath: string; AData: PSingle; AFrameCount, AChannels,
  ASampleRate: Integer): Boolean;

function WavWriteBegin(out AW: TWavWriter; const APath: string;
  AFrameCount: Int64; AChannels, ASampleRate: Integer): Boolean;
{ Appends AFrameCount frames of interleaved floats. May be called any number
  of times; the block sizes need not be equal or aligned to anything. }
function WavWriteBlock(var AW: TWavWriter; AData: PSingle;
  AFrameCount: Int64; AChannels: Integer): Boolean;
{ Closes the file. Returns False if fewer frames arrived than were declared,
  which would leave a header claiming data that is not there. }
function WavWriteEnd(var AW: TWavWriter): Boolean;

implementation

const
  FormatPCM = 1;
  FormatIEEEFloat = 3;
  FormatExtensible = $FFFE;

function ReadU32(AStream: TStream): UInt32;
begin
  AStream.ReadBuffer(Result, SizeOf(Result));
end;

function ReadU16(AStream: TStream): UInt16;
begin
  AStream.ReadBuffer(Result, SizeOf(Result));
end;

procedure WriteU16(AStream: TStream; AValue: UInt16);
begin
  AStream.WriteBuffer(AValue, SizeOf(AValue));
end;

procedure WriteU32(AStream: TStream; AValue: UInt32);
begin
  AStream.WriteBuffer(AValue, SizeOf(AValue));
end;

function DecodeWav(const APath: string; out ASample: TSample): Boolean;
var
  Stream: TFileStream;
  RiffId, WaveId, ChunkId: array[0..3] of AnsiChar;
  ChunkSize: UInt32;
  ChunkStart: Int64;
  AudioFormat, NumChannels, BitsPerSample, ExtraSize: UInt16;
  SampleRate: UInt32;
  HaveFmt, HaveData: Boolean;
  DataBytes: Int64;
  RawData: PByte;
  FrameCount, i, SrcOffset, BytesPerSample: Integer;
  Value24: Integer;
begin
  Result := False;
  FillChar(ASample, SizeOf(ASample), 0);
  HaveFmt := False;
  HaveData := False;
  AudioFormat := 0;
  NumChannels := 0;
  SampleRate := 0;
  BitsPerSample := 0;
  RawData := nil;
  DataBytes := 0;

  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    Stream.ReadBuffer(RiffId, 4);
    if (RiffId[0] <> 'R') or (RiffId[1] <> 'I') or (RiffId[2] <> 'F') or (RiffId[3] <> 'F') then
      Exit;
    ReadU32(Stream);
    Stream.ReadBuffer(WaveId, 4);
    if (WaveId[0] <> 'W') or (WaveId[1] <> 'A') or (WaveId[2] <> 'V') or (WaveId[3] <> 'E') then
      Exit;

    while Stream.Position <= Stream.Size - 8 do
    begin
      Stream.ReadBuffer(ChunkId, 4);
      ChunkSize := ReadU32(Stream);
      ChunkStart := Stream.Position;

      if (ChunkId[0] = 'f') and (ChunkId[1] = 'm') and (ChunkId[2] = 't') and (ChunkId[3] = ' ') then
      begin
        AudioFormat := ReadU16(Stream);
        NumChannels := ReadU16(Stream);
        SampleRate := ReadU32(Stream);
        ReadU32(Stream);
        ReadU16(Stream);
        BitsPerSample := ReadU16(Stream);

        if ChunkSize > 16 then
        begin
          ExtraSize := ReadU16(Stream);
          if (AudioFormat = FormatExtensible) and (ExtraSize >= 22) then
          begin
            Stream.Seek(6, soCurrent);
            Stream.ReadBuffer(AudioFormat, 2);
          end;
        end;

        HaveFmt := True;
      end
      else if (ChunkId[0] = 'd') and (ChunkId[1] = 'a') and (ChunkId[2] = 't') and (ChunkId[3] = 'a') then
      begin
        DataBytes := ChunkSize;
        GetMem(RawData, DataBytes);
        Stream.ReadBuffer(RawData^, DataBytes);
        HaveData := True;
      end;

      Stream.Position := ChunkStart + ChunkSize + (ChunkSize and 1);

      if HaveFmt and HaveData then
        Break;
    end;

    if not (HaveFmt and HaveData) then
    begin
      if RawData <> nil then
        FreeMem(RawData);
      Exit;
    end;

    if (AudioFormat <> FormatPCM) and (AudioFormat <> FormatIEEEFloat) then
    begin
      FreeMem(RawData);
      Exit;
    end;

    BytesPerSample := BitsPerSample div 8;
    if (NumChannels = 0) or (BytesPerSample = 0) then
    begin
      FreeMem(RawData);
      Exit;
    end;

    FrameCount := DataBytes div (NumChannels * BytesPerSample);

    GetMem(ASample.Data, FrameCount * NumChannels * SizeOf(Single));

    { 16-bit PCM - overwhelmingly the common case, and the one Eris itself
      writes - gets its own path. The general loop below re-tests the format
      and re-enters a case on BitsPerSample for EVERY sample, which for a
      3-minute stereo file is ~16M redundant branches on values that cannot
      change mid-file. Same arithmetic, so the decoded floats are identical.

      AVector.VConvertS16 is that loop, 8 samples per instruction where the
      CPU has AVX2 and byte-identical Pascal where it does not - see its
      comment for why the widen-and-scale cannot round differently. This runs
      for EVERY sample a project loads, including the ones already at the
      canonical rate that skip ResampleToCanonical entirely, so it is the
      widest-reaching thing on the load path. }
    if (AudioFormat = FormatPCM) and (BitsPerSample = 16) then
      VConvertS16(ASample.Data, PSmallInt(RawData),
        Int64(FrameCount) * NumChannels)
    else
    for i := 0 to (FrameCount * NumChannels) - 1 do
    begin
      SrcOffset := i * BytesPerSample;
      if AudioFormat = FormatIEEEFloat then
      begin
        if BitsPerSample = 32 then
          ASample.Data[i] := PSingle(@RawData[SrcOffset])^
        else
          ASample.Data[i] := 0;
      end
      else
        case BitsPerSample of
          8:
            ASample.Data[i] := (RawData[SrcOffset] - 128) / 128.0;
          16:
            ASample.Data[i] := PSmallInt(@RawData[SrcOffset])^ / 32768.0;
          24:
            begin
              Value24 := RawData[SrcOffset] or (RawData[SrcOffset + 1] shl 8) or
                (RawData[SrcOffset + 2] shl 16);
              if (Value24 and $800000) <> 0 then
                Value24 := Value24 or Integer($FF000000);
              ASample.Data[i] := Value24 / 8388608.0;
            end;
          32:
            ASample.Data[i] := PLongInt(@RawData[SrcOffset])^ / 2147483648.0;
        else
          ASample.Data[i] := 0;
        end;
    end;

    FreeMem(RawData);

    ASample.FrameCount := FrameCount;
    ASample.Channels := NumChannels;
    ASample.SampleRate := SampleRate;
    ASample.BaseNote := 60.0;

    Result := True;
  finally
    Stream.Free;
  end;
end;

const
  { Samples converted per write. TFileStream is UNBUFFERED - every
    WriteBuffer call is a write() syscall straight through to the OS - so
    the obvious "convert one sample, write its 2 bytes" loop this replaced
    cost one syscall per sample: measured at ~4.9 SECONDS per minute of
    stereo audio, versus ~17ms for the same data written in bulk. That was
    paid on every Export AND on every Save (SaveProject re-encodes each
    embedded recorded sample), which is what made both read as a hang on a
    project with any real amount of recorded material.

    Chunked rather than one buffer for the whole file so peak memory stays
    fixed (128KB) instead of scaling with render length. }
  ChunkSamples = 65536;

function WavWriteBegin(out AW: TWavWriter; const APath: string;
  AFrameCount: Int64; AChannels, ASampleRate: Integer): Boolean;
var
  DataBytes, RiffSize, ByteRate: UInt32;
  BlockAlign: UInt16;
begin
  Result := False;
  AW.Stream := nil;
  AW.Declared := AFrameCount;
  AW.Written := 0;
  SetLength(AW.Chunk, ChunkSamples);

  DataBytes := AFrameCount * AChannels * 2;
  BlockAlign := AChannels * 2;
  ByteRate := UInt32(ASampleRate) * BlockAlign;
  RiffSize := 4 + (8 + 16) + (8 + DataBytes);

  AW.Stream := TFileStream.Create(APath, fmCreate);

  AW.Stream.WriteBuffer('RIFF', 4);
  WriteU32(AW.Stream, RiffSize);
  AW.Stream.WriteBuffer('WAVE', 4);

  AW.Stream.WriteBuffer('fmt ', 4);
  WriteU32(AW.Stream, 16);
  WriteU16(AW.Stream, FormatPCM);
  WriteU16(AW.Stream, AChannels);
  WriteU32(AW.Stream, ASampleRate);
  WriteU32(AW.Stream, ByteRate);
  WriteU16(AW.Stream, BlockAlign);
  WriteU16(AW.Stream, 16);

  AW.Stream.WriteBuffer('data', 4);
  WriteU32(AW.Stream, DataBytes);
  Result := True;
end;

function WavWriteBlock(var AW: TWavWriter; AData: PSingle;
  AFrameCount: Int64; AChannels: Integer): Boolean;
var
  i, ThisChunk: Integer;
  Done, TotalSamples: Int64;
  Value: Single;
begin
  Result := False;
  if AW.Stream = nil then
    Exit;

  { the identical clamp and Round per sample the single-shot encoder always
    used, so the bytes written do not depend on how the caller blocked its
    audio up }
  TotalSamples := AFrameCount * AChannels;
  Done := 0;
  while Done < TotalSamples do
  begin
    if TotalSamples - Done > ChunkSamples then
      ThisChunk := ChunkSamples
    else
      ThisChunk := TotalSamples - Done;

    for i := 0 to ThisChunk - 1 do
    begin
      Value := AData[Done + i];
      if Value > 1.0 then
        Value := 1.0
      else if Value < -1.0 then
        Value := -1.0;
      AW.Chunk[i] := Round(Value * 32767.0);
    end;

    AW.Stream.WriteBuffer(AW.Chunk[0], ThisChunk * 2);
    Inc(Done, ThisChunk);
  end;

  AW.Written := AW.Written + AFrameCount;
  Result := True;
end;

function WavWriteEnd(var AW: TWavWriter): Boolean;
begin
  Result := (AW.Stream <> nil) and (AW.Written = AW.Declared);
  if AW.Stream <> nil then
  begin
    AW.Stream.Free;
    AW.Stream := nil;
  end;
  SetLength(AW.Chunk, 0);
end;

function EncodeWav(const APath: string; AData: PSingle; AFrameCount, AChannels,
  ASampleRate: Integer): Boolean;
var
  W: TWavWriter;
begin
  Result := False;
  if not WavWriteBegin(W, APath, AFrameCount, AChannels, ASampleRate) then
    Exit;
  try
    Result := WavWriteBlock(W, AData, AFrameCount, AChannels);
  finally
    Result := WavWriteEnd(W) and Result;
  end;
end;

const
  Decoders: array[0..2] of TDecoderEntry = (
    (Ext: '.wav'; Decode: @DecodeWav),
    (Ext: '.aiff'; Decode: @DecodeAiff),
    (Ext: '.aif'; Decode: @DecodeAiff)
    { .mp3 added once Mp3Decoder exists }
  );

{ Converts a freshly decoded sample to CanonicalSampleRate in place, so the
  pool only ever holds one rate - see that constant's comment for why a
  mixed-rate pool misbehaves. Runs the same linear interpolation the engine's
  own vari-speed playback does, so an imported 48k file sounds exactly like
  the engine pitching it would. A no-op for anything already at the canonical
  rate, which is every file Eris itself writes.

  The interpolation is written out here rather than calling
  Resample.Interpolate per sample. That is a procedure VARIABLE, so every
  output sample was an indirect call - unindexable, uninlinable, and repeating
  per CHANNEL work that only depends on the frame: the Trunc, the two bounds
  compares and the Frac subtract were all recomputed for channel 1 having just
  been computed for channel 0. On a stereo 48k file that is ~10M indirect
  calls and half of them redundant. Resample.Interpolate stays exactly as it
  is for the realtime path, where the position genuinely varies per sample and
  the branch cannot be hoisted.

  Bit-exact against what it replaces, deliberately: the position is still
  i * Ratio as a fresh Double multiply and NOT an accumulator (pos := pos +
  Ratio drifts by a ulp per step and would change every value after the
  first), Frac stays Double, S1 - S0 stays a Single subtract, and the one
  rounding back to Single still happens at the store. Same operands, same
  order, same roundings. }
procedure ResampleToCanonical(var ASample: TSample);
var
  Src, NewData: PSingle;
  NewCount, SrcCount, Channels, i, c, Idx, SrcBase, DstBase: Integer;
  Ratio, Pos, Frac: Double;
  S0, S1: Single;
  HaveNext: Boolean;
begin
  if (ASample.Data = nil) or (ASample.FrameCount <= 0)
    or (ASample.Channels <= 0) or (ASample.SampleRate <= 0)
    or (ASample.SampleRate = CanonicalSampleRate) then
    Exit;

  { source frames consumed per output frame - >1 downsampling, <1 upsampling }
  Ratio := ASample.SampleRate / CanonicalSampleRate;
  NewCount := Round(ASample.FrameCount / Ratio);
  if NewCount <= 0 then
    Exit;

  { hoisted out of the loop - these are record fields read ~10M times each }
  Src := ASample.Data;
  SrcCount := ASample.FrameCount;
  Channels := ASample.Channels;

  GetMem(NewData, Int64(NewCount) * Channels * SizeOf(Single));
  DstBase := 0;
  for i := 0 to NewCount - 1 do
  begin
    Pos := i * Ratio;
    Idx := Trunc(Pos);
    { Round() above can put the last output frame past the end of the source -
      the old code hit the same case as Interpolate's own out-of-range guard
      and got the same silence }
    if (Idx < 0) or (Idx >= SrcCount) then
      FillChar(NewData[DstBase], Channels * SizeOf(Single), 0)
    else
    begin
      Frac := Pos - Idx;
      SrcBase := Idx * Channels;
      HaveNext := Idx + 1 < SrcCount;
      for c := 0 to Channels - 1 do
      begin
        S0 := Src[SrcBase + c];
        if HaveNext then
          S1 := Src[SrcBase + Channels + c]
        else
          S1 := 0;
        NewData[DstBase + c] := S0 + Frac * (S1 - S0);
      end;
    end;
    Inc(DstBase, Channels);
  end;

  FreeMem(ASample.Data);
  ASample.Data := NewData;
  ASample.FrameCount := NewCount;
  ASample.SampleRate := CanonicalSampleRate;
end;

function DecodeSampleFile(const APath: string; out ASample: TSample): Boolean;
var
  Ext: string;
  i: Integer;
begin
  Result := False;
  Ext := LowerCase(ExtractFileExt(APath));
  for i := 0 to High(Decoders) do
    if Decoders[i].Ext = Ext then
    begin
      Result := Decoders[i].Decode(APath, ASample);
      { before any caller computes peaks, transients or periods off it, and
        before it can reach the pool at a foreign rate }
      if Result then
        ResampleToCanonical(ASample);
      Exit;
    end;
end;

end.
