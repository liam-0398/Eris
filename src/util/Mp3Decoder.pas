unit Mp3Decoder;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SampleTypes;

{ MP3 (MPEG-1/2/2.5 Layer III) decoder - NOT FINISHED, see the "state" note
  in CLUADE.md for exactly what does and doesn't work yet. Ported by hand
  from the ISO/IEC 11172-3 spec rather than any specific existing decoder's
  source, per the project's "no third-party codec library, ever" rule.

  What works: frame sync/header parsing (TryParseFrameHeader) and the
  MSB-first bit reader (TBitReader) both real spectral-decode work will need.
  DecodeMp3 uses them to validate a file and report its basic shape
  (sample rate, channel count, frame/sample count).

  What doesn't: DecodeMainData/ReconstructSpectrum/SynthesisFilterbank below
  are stubs - actually turning a frame's compressed main data into PCM needs
  Huffman decoding of the big_values/count1 regions, scale factor
  reconstruction, requantization, stereo processing, the IMDCT +
  overlap-add, alias reduction, and the 32-band polyphase synthesis filter.
  None of that is implemented, so DecodeMp3 always returns False. This unit
  is deliberately not referenced from WavDecoder.Decoders yet - see
  WavDecoder.pas's uses clause. }
function DecodeMp3(const APath: string; out ASample: TSample): Boolean;

implementation

const
  { raw 2-bit MPEG version field values, straight out of the header }
  Mpeg25 = 0;
  { 1 is reserved - no valid header ever carries it }
  Mpeg2 = 2;
  Mpeg1 = 3;

  { raw 2-bit layer field value for Layer III - the only layer this unit
    targets (Layer I/II are a different, simpler bitstream this project has
    no need for) }
  LayerIII = 1;

  { channel mode field: 0=stereo, 1=joint stereo, 2=dual channel, 3=mono }
  ChannelModeMono = 3;

  FrameHeaderSize = 4; { bytes - the part TryParseFrameHeader reads }

  { kbps, indexed [0..14] by the 4-bit bitrate index; index 0 ("free format")
    and 15 ("bad") are both rejected by TryParseFrameHeader rather than
    tabulated here }
  BitrateTableMpeg1: array[0..14] of Integer =
    (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320);
  BitrateTableMpeg2: array[0..14] of Integer =
    (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160);

  { Hz, indexed [0..2] by the 2-bit sample rate index; index 3 ("reserved")
    is rejected rather than tabulated }
  SampleRateTableMpeg1: array[0..2] of Integer = (44100, 48000, 32000);
  SampleRateTableMpeg2: array[0..2] of Integer = (22050, 24000, 16000);
  SampleRateTableMpeg25: array[0..2] of Integer = (11025, 12000, 8000);

type
  TMp3FrameHeader = record
    VersionID: Integer;      { raw 2-bit field - Mpeg1/Mpeg2/Mpeg25 above }
    HasCrc: Boolean;         { True if a 16-bit CRC follows this header }
    BitrateIndex: Integer;
    SampleRateIndex: Integer;
    PaddingBit: Boolean;
    ChannelMode: Integer;    { raw 2-bit field }
    SampleRate: Integer;     { Hz, resolved from VersionID + SampleRateIndex }
    BitrateBps: Integer;     { resolved from VersionID + BitrateIndex }
    Channels: Integer;       { 1 or 2, resolved from ChannelMode }
    FrameSize: Integer;      { bytes, header included }
    SamplesPerFrame: Integer; { 1152 for MPEG1, 576 for MPEG2/2.5 }
  end;

  { Bit reader over a byte buffer, MSB-first - the bit order MP3 main data
    (Huffman-coded spectral values, scale factors, side info) uses. Only
    Init/GetBits are implemented; nothing downstream consumes them yet -
    see DecodeMainData's TODO. }
  TBitReader = record
    Data: PByte;
    ByteLen: Integer;
    BitPos: Integer; { absolute bit offset from the start of Data }
  end;

procedure BitReaderInit(out ABR: TBitReader; AData: PByte; AByteLen: Integer);
begin
  ABR.Data := AData;
  ABR.ByteLen := AByteLen;
  ABR.BitPos := 0;
end;

function BitReaderGetBits(var ABR: TBitReader; ACount: Integer): UInt32;
var
  i, BytePos, BitInByte: Integer;
  BitVal: UInt32;
begin
  Result := 0;
  for i := 0 to ACount - 1 do
  begin
    BytePos := ABR.BitPos shr 3;
    BitInByte := 7 - (ABR.BitPos and 7);
    if BytePos >= ABR.ByteLen then
      BitVal := 0 { ran past the end of a well-formed frame's data - should
        not happen, but avoid reading out of bounds if it does }
    else
      BitVal := (ABR.Data[BytePos] shr BitInByte) and 1;
    Result := (Result shl 1) or BitVal;
    Inc(ABR.BitPos);
  end;
end;

{ Parses one 4-byte frame header (AHeaderBytes[0..3], as read straight off
  disk) per ISO/IEC 11172-3 section 2.4.1.3. Only accepts Layer III and only
  the fixed-bitrate table (bitrate index 0 = "free format" and 15 = "bad"
  are both rejected, along with the reserved version/sample-rate values) -
  free-format MP3s are rare enough in practice that supporting them isn't
  worth the extra frame-size bookkeeping they'd need. }
function TryParseFrameHeader(AHeaderBytes: PByte; out AHeader: TMp3FrameHeader): Boolean;
var
  HeaderVal: UInt32;
  LayerID: Integer;
  BitrateKbps: Integer;
begin
  Result := False;
  FillChar(AHeader, SizeOf(AHeader), 0);

  HeaderVal := (UInt32(AHeaderBytes[0]) shl 24) or (UInt32(AHeaderBytes[1]) shl 16) or
    (UInt32(AHeaderBytes[2]) shl 8) or UInt32(AHeaderBytes[3]);

  { sync word: top 11 bits all 1 }
  if (HeaderVal and $FFE00000) <> $FFE00000 then
    Exit;

  AHeader.VersionID := (HeaderVal shr 19) and 3;
  if AHeader.VersionID = 1 then { reserved }
    Exit;

  LayerID := (HeaderVal shr 17) and 3;
  if LayerID <> LayerIII then
    Exit;

  AHeader.HasCrc := ((HeaderVal shr 16) and 1) = 0;
  AHeader.BitrateIndex := (HeaderVal shr 12) and $F;
  if (AHeader.BitrateIndex = 0) or (AHeader.BitrateIndex = 15) then
    Exit;

  AHeader.SampleRateIndex := (HeaderVal shr 10) and 3;
  if AHeader.SampleRateIndex = 3 then { reserved }
    Exit;

  AHeader.PaddingBit := ((HeaderVal shr 9) and 1) = 1;
  AHeader.ChannelMode := (HeaderVal shr 6) and 3;

  if AHeader.VersionID = Mpeg1 then
  begin
    BitrateKbps := BitrateTableMpeg1[AHeader.BitrateIndex];
    AHeader.SampleRate := SampleRateTableMpeg1[AHeader.SampleRateIndex];
    AHeader.SamplesPerFrame := 1152;
  end
  else
  begin
    BitrateKbps := BitrateTableMpeg2[AHeader.BitrateIndex];
    if AHeader.VersionID = Mpeg2 then
      AHeader.SampleRate := SampleRateTableMpeg2[AHeader.SampleRateIndex]
    else
      AHeader.SampleRate := SampleRateTableMpeg25[AHeader.SampleRateIndex];
    AHeader.SamplesPerFrame := 576;
  end;
  AHeader.BitrateBps := BitrateKbps * 1000;

  if AHeader.ChannelMode = ChannelModeMono then
    AHeader.Channels := 1
  else
    AHeader.Channels := 2;

  { ISO/IEC 11172-3 2.4.2.3 - Layer III frame size formula, MPEG1 uses a
    144x multiplier where MPEG2/2.5's halved slot count uses 72x }
  if AHeader.VersionID = Mpeg1 then
    AHeader.FrameSize := (144 * AHeader.BitrateBps) div AHeader.SampleRate
  else
    AHeader.FrameSize := (72 * AHeader.BitrateBps) div AHeader.SampleRate;
  if AHeader.PaddingBit then
    Inc(AHeader.FrameSize);

  Result := AHeader.FrameSize > FrameHeaderSize;
end;

{ TODO (not implemented): Huffman-decode the big_values/count1 regions per
  ISO/IEC 11172-3 2.4.2.7 using the big_values/count1 Huffman tables, then
  dequantize and apply scale factors (2.4.2.6) and the stereo mode
  (2.4.3.4.9.3, for joint-stereo intensity/MS decoding). Nothing calls this
  yet - DecodeMp3 stops at header parsing/validation. }
function DecodeMainData(var ABR: TBitReader; const AHeader: TMp3FrameHeader): Boolean;
begin
  Result := False;
end;

{ TODO (not implemented): per-granule IMDCT (2.4.3.4.7) and overlap-add with
  the previous block's tail, alias reduction (2.4.3.4.9.2), frequency
  inversion on odd subbands (2.4.3.4.9.4). }
function ReconstructSpectrum: Boolean;
begin
  Result := False;
end;

{ TODO (not implemented): 32-subband polyphase synthesis filter (2.4.3.5) -
  a windowed FIR using the standard 512-tap synthesis window, producing 32
  interleaved PCM samples per subband pass. }
function SynthesisFilterbank: Boolean;
begin
  Result := False;
end;

{ Skips a leading ID3v2 tag if present ("ID3" + 2 version bytes + 1 flags
  byte + a 4-byte synced-safe size, each byte only using its low 7 bits).
  No ID3v1/APE tag handling at the far end of the file - harmless here since
  DecodeMp3 stops well short of needing to locate the last frame precisely. }
function SkipId3v2(AStream: TStream): Int64;
var
  Header: array[0..9] of Byte;
  TagSize: Int64;
begin
  Result := 0;
  if AStream.Size < SizeOf(Header) then
    Exit;
  AStream.ReadBuffer(Header, SizeOf(Header));
  if (Header[0] = Ord('I')) and (Header[1] = Ord('D')) and (Header[2] = Ord('3')) then
  begin
    TagSize := (Int64(Header[6]) shl 21) or (Int64(Header[7]) shl 14) or
      (Int64(Header[8]) shl 7) or Int64(Header[9]);
    Result := SizeOf(Header) + TagSize;
  end;
  AStream.Position := Result;
end;

{ Scans every frame in the file to validate it's well-formed Layer III and
  report its basic shape (sample rate/channels/total sample count) - real
  decode-to-PCM work is not implemented (see DecodeMainData/
  ReconstructSpectrum/SynthesisFilterbank above), so this always returns
  False. Kept as a real, exercised code path anyway (rather than an
  immediate stub) because header parsing is genuinely useful on its own and
  is the piece any future Huffman/IMDCT work will build directly on top of. }
function DecodeMp3(const APath: string; out ASample: TSample): Boolean;
var
  Stream: TFileStream;
  StartOffset, Pos: Int64;
  HeaderBytes: array[0..FrameHeaderSize - 1] of Byte;
  Header, FirstHeader: TMp3FrameHeader;
  FrameCount: Integer;
  TotalSamples: Int64;
  HaveFirstHeader: Boolean;
begin
  Result := False;
  FillChar(ASample, SizeOf(ASample), 0);
  FillChar(FirstHeader, SizeOf(FirstHeader), 0);
  HaveFirstHeader := False;
  FrameCount := 0;
  TotalSamples := 0;

  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    StartOffset := SkipId3v2(Stream);
    Pos := StartOffset;

    while Pos + FrameHeaderSize <= Stream.Size do
    begin
      Stream.Position := Pos;
      Stream.ReadBuffer(HeaderBytes, FrameHeaderSize);

      if not TryParseFrameHeader(@HeaderBytes[0], Header) then
      begin
        { not a valid frame header at this offset - resync by advancing one
          byte at a time, same recovery approach every MP3 decoder uses
          since frames aren't otherwise delimited }
        Inc(Pos);
        Continue;
      end;

      if not HaveFirstHeader then
      begin
        FirstHeader := Header;
        HaveFirstHeader := True;
      end
      else if (Header.SampleRate <> FirstHeader.SampleRate) or
        (Header.Channels <> FirstHeader.Channels) then
        { a sample rate/channel-count change mid-file (technically legal in
          MP3, "free-format"/gapless-adjacent streams aside) isn't
          supported - bail out with whatever was found before this frame }
        Break;

      Inc(FrameCount);
      Inc(TotalSamples, Header.SamplesPerFrame);
      Inc(Pos, Header.FrameSize);
    end;

    if not HaveFirstHeader then
      Exit;

    ASample.Channels := FirstHeader.Channels;
    ASample.SampleRate := FirstHeader.SampleRate;
    ASample.FrameCount := TotalSamples;
    ASample.BaseNote := 60.0;

    { main-data decode isn't implemented (see the TODOs above) - report
      failure rather than handing back a Data-less/silent TSample that
      looks superficially valid }
    Result := False;
  finally
    Stream.Free;
  end;
end;

end.
