unit SampleTypes;

{$mode objfpc}{$H+}

interface

type
  TSample = record
    Data: PSingle;
    FrameCount: Integer;
    Channels: Integer;
    SampleRate: Integer;
    BaseNote: Single;
  end;

  TClip = record
    SampleID: Integer;
    Offset, Length: Int64;
    Position: Int64;
    TrackID: Integer;
    PitchSemitones: Single;
    Gain: Single;
  end;

implementation

end.
