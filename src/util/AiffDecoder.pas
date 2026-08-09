unit AiffDecoder;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, SampleTypes;

{ AIFF and AIFF-C (compressed-container, but only its "NONE" and "sowt"
  variants - see below) decoder, mirroring WavDecoder.DecodeWav's shape:
  read the whole chunk list once, convert straight to float32, done. AIFF is
  IFF-chunked like RIFF/WAV but big-endian, and its integer PCM is always
  SIGNED at every bit depth (WAV's legacy 8-bit is unsigned) - both handled
  below. Only 8/16/24/32-bit integer PCM is supported (matches WavDecoder's
  own scope); IEEE-float AIFF and real audio-compression codecs (ulaw,
  alaw, ima4, etc.) are out of scope and cause decode to fail cleanly. }
function DecodeAiff(const APath: string; out ASample: TSample): Boolean;

implementation

function ReadU16BE(AStream: TStream): UInt16;
begin
  AStream.ReadBuffer(Result, SizeOf(Result));
  Result := SwapEndian(Result);
end;

function ReadU32BE(AStream: TStream): UInt32;
begin
  AStream.ReadBuffer(Result, SizeOf(Result));
  Result := SwapEndian(Result);
end;

function Is4CC(const AId: array of AnsiChar; const AName: string): Boolean;
begin
  Result := (Length(AName) = 4) and (AId[0] = AName[1]) and (AId[1] = AName[2]) and
    (AId[2] = AName[3]) and (AId[3] = AName[4]);
end;

{ AIFF's sample rate is stored as an 80-bit IEEE 754 "extended precision"
  float, big-endian: 1 sign bit + 15-bit biased exponent (bias 16383), then
  a 64-bit mantissa with an EXPLICIT leading integer bit (unlike a normal
  IEEE double's implicit one) - so the mantissa read as a plain unsigned
  64-bit integer already equals significand * 2^63, giving the plain
  closed-form below. This is a standalone implementation of the documented
  bit layout (also used by x87 "long double"), not a port of any specific
  reference decoder. Infinity/NaN/negative cases are real possibilities in
  the general 80-bit format but not in a sample-rate field in practice, so
  they're not handled - a corrupt/bogus value here just produces a garbage
  SampleRate, which is no worse than the rest of a decode from a corrupt
  file. }
function ExtendedToDouble(const ABytes: array of Byte): Double;
var
  Exponent: Integer;
  Mantissa: UInt64;
  i: Integer;
begin
  Exponent := ((ABytes[0] and $7F) shl 8) or ABytes[1];
  Mantissa := 0;
  for i := 2 to 9 do
    Mantissa := (Mantissa shl 8) or ABytes[i];

  if (Exponent = 0) and (Mantissa = 0) then
    Exit(0);

  Result := Mantissa * Power(2, Exponent - 16383 - 63);
  if (ABytes[0] and $80) <> 0 then
    Result := -Result;
end;

function DecodeAiff(const APath: string; out ASample: TSample): Boolean;
var
  Stream: TFileStream;
  FormId, FormType, ChunkId, CompressionType: array[0..3] of AnsiChar;
  ChunkSize: UInt32;
  ChunkStart: Int64;
  HaveComm, HaveSsnd, IsAifc, IsLittleEndianPCM, CompressionOK: Boolean;
  NumChannels, SampleSize: UInt16;
  SampleRateBytes: array[0..9] of Byte;
  SsndOffset: UInt32;
  DataBytes: Int64;
  RawData: PByte;
  FrameCount, i, SrcOffset, BytesPerSample: Integer;
  Value24: Integer;
begin
  Result := False;
  FillChar(ASample, SizeOf(ASample), 0);
  HaveComm := False;
  HaveSsnd := False;
  IsLittleEndianPCM := False;
  CompressionOK := True;
  NumChannels := 0;
  SampleSize := 0;
  RawData := nil;
  DataBytes := 0;

  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    Stream.ReadBuffer(FormId, 4);
    if not Is4CC(FormId, 'FORM') then
      Exit;
    ReadU32BE(Stream); { overall form size - unused, chunk walk below is self-terminating }
    Stream.ReadBuffer(FormType, 4);
    IsAifc := Is4CC(FormType, 'AIFC');
    if not (IsAifc or Is4CC(FormType, 'AIFF')) then
      Exit;

    while Stream.Position <= Stream.Size - 8 do
    begin
      Stream.ReadBuffer(ChunkId, 4);
      ChunkSize := ReadU32BE(Stream);
      ChunkStart := Stream.Position;

      if Is4CC(ChunkId, 'COMM') then
      begin
        NumChannels := ReadU16BE(Stream);
        ReadU32BE(Stream); { numSampleFrames - FrameCount is derived from the
          SSND chunk's own byte count below instead, same as WavDecoder }
        SampleSize := ReadU16BE(Stream);
        Stream.ReadBuffer(SampleRateBytes, 10);

        if IsAifc and (ChunkSize > 18) then
        begin
          Stream.ReadBuffer(CompressionType, 4);
          if Is4CC(CompressionType, 'sowt') then
            IsLittleEndianPCM := True
          else if not Is4CC(CompressionType, 'NONE') then
            CompressionOK := False;
        end;

        HaveComm := True;
      end
      else if Is4CC(ChunkId, 'SSND') then
      begin
        SsndOffset := ReadU32BE(Stream);
        ReadU32BE(Stream); { blockSize - always 0 for plain PCM, ignored }
        DataBytes := Int64(ChunkSize) - 8 - SsndOffset;
        if DataBytes < 0 then
          DataBytes := 0;
        if SsndOffset > 0 then
          Stream.Position := Stream.Position + SsndOffset;
        GetMem(RawData, DataBytes);
        Stream.ReadBuffer(RawData^, DataBytes);
        HaveSsnd := True;
      end;

      { IFF chunks pad to an even byte boundary, same as RIFF }
      Stream.Position := ChunkStart + ChunkSize + (ChunkSize and 1);

      if HaveComm and HaveSsnd then
        Break;
    end;

    if not (HaveComm and HaveSsnd and CompressionOK) then
    begin
      if RawData <> nil then
        FreeMem(RawData);
      Exit;
    end;

    BytesPerSample := SampleSize div 8;
    if (NumChannels = 0) or (BytesPerSample = 0) then
    begin
      FreeMem(RawData);
      Exit;
    end;

    FrameCount := DataBytes div (NumChannels * BytesPerSample);

    GetMem(ASample.Data, FrameCount * NumChannels * SizeOf(Single));

    for i := 0 to (FrameCount * NumChannels) - 1 do
    begin
      SrcOffset := i * BytesPerSample;
      if IsLittleEndianPCM then
        { 'sowt' AIFC: byte-swapped PCM, i.e. plain little-endian - same
          read as WavDecoder's WAV path, host is already little-endian }
        case BytesPerSample of
          1: ASample.Data[i] := ShortInt(RawData[SrcOffset]) / 128.0;
          2: ASample.Data[i] := PSmallInt(@RawData[SrcOffset])^ / 32768.0;
          3:
            begin
              Value24 := RawData[SrcOffset] or (RawData[SrcOffset + 1] shl 8) or
                (RawData[SrcOffset + 2] shl 16);
              if (Value24 and $800000) <> 0 then
                Value24 := Value24 or Integer($FF000000);
              ASample.Data[i] := Value24 / 8388608.0;
            end;
          4: ASample.Data[i] := PLongInt(@RawData[SrcOffset])^ / 2147483648.0;
        else
          ASample.Data[i] := 0;
        end
      else
        { standard AIFF: big-endian signed PCM at every bit depth (no
          unsigned-8-bit convention like WAV's legacy format) }
        case BytesPerSample of
          1: ASample.Data[i] := ShortInt(RawData[SrcOffset]) / 128.0;
          2: ASample.Data[i] := SmallInt(SwapEndian(PWord(@RawData[SrcOffset])^)) / 32768.0;
          3:
            begin
              Value24 := (RawData[SrcOffset] shl 16) or (RawData[SrcOffset + 1] shl 8) or
                RawData[SrcOffset + 2];
              if (Value24 and $800000) <> 0 then
                Value24 := Value24 or Integer($FF000000);
              ASample.Data[i] := Value24 / 8388608.0;
            end;
          4: ASample.Data[i] := LongInt(SwapEndian(PLongWord(@RawData[SrcOffset])^)) / 2147483648.0;
        else
          ASample.Data[i] := 0;
        end;
    end;

    FreeMem(RawData);

    ASample.FrameCount := FrameCount;
    ASample.Channels := NumChannels;
    ASample.SampleRate := Round(ExtendedToDouble(SampleRateBytes));
    ASample.BaseNote := 60.0;

    Result := True;
  finally
    Stream.Free;
  end;
end;

end.
