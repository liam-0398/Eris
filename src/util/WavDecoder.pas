unit WavDecoder;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SampleTypes, AiffDecoder;
  { Mp3Decoder is not wired in yet - it doesn't exist as a unit yet, this
    is a deliberate midpoint so AIFF support and the sample-load thread fix
    can be built and tested independently of the still-unwritten MP3 port }

type
  TDecodeFunc = function(const APath: string; out ASample: TSample): Boolean;
  TDecoderEntry = record
    Ext: string;
    Decode: TDecodeFunc;
  end;

function DecodeWav(const APath: string; out ASample: TSample): Boolean;
function DecodeSampleFile(const APath: string; out ASample: TSample): Boolean;
function EncodeWav(const APath: string; AData: PSingle; AFrameCount, AChannels,
  ASampleRate: Integer): Boolean;

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

function EncodeWav(const APath: string; AData: PSingle; AFrameCount, AChannels,
  ASampleRate: Integer): Boolean;
var
  Stream: TFileStream;
  DataBytes, RiffSize, ByteRate: UInt32;
  BlockAlign: UInt16;
  i: Integer;
  Value: Single;
  Sample16: SmallInt;
begin
  Result := False;
  DataBytes := AFrameCount * AChannels * 2;
  BlockAlign := AChannels * 2;
  ByteRate := UInt32(ASampleRate) * BlockAlign;
  RiffSize := 4 + (8 + 16) + (8 + DataBytes);

  Stream := TFileStream.Create(APath, fmCreate);
  try
    Stream.WriteBuffer('RIFF', 4);
    WriteU32(Stream, RiffSize);
    Stream.WriteBuffer('WAVE', 4);

    Stream.WriteBuffer('fmt ', 4);
    WriteU32(Stream, 16);
    WriteU16(Stream, FormatPCM);
    WriteU16(Stream, AChannels);
    WriteU32(Stream, ASampleRate);
    WriteU32(Stream, ByteRate);
    WriteU16(Stream, BlockAlign);
    WriteU16(Stream, 16);

    Stream.WriteBuffer('data', 4);
    WriteU32(Stream, DataBytes);

    for i := 0 to (AFrameCount * AChannels) - 1 do
    begin
      Value := AData[i];
      if Value > 1.0 then
        Value := 1.0
      else if Value < -1.0 then
        Value := -1.0;
      Sample16 := Round(Value * 32767.0);
      Stream.WriteBuffer(Sample16, 2);
    end;

    Result := True;
  finally
    Stream.Free;
  end;
end;

const
  Decoders: array[0..2] of TDecoderEntry = (
    (Ext: '.wav'; Decode: @DecodeWav),
    (Ext: '.aiff'; Decode: @DecodeAiff),
    (Ext: '.aif'; Decode: @DecodeAiff)
    { .mp3 added once Mp3Decoder exists }
  );

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
      Exit;
    end;
end;

end.
