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

  TClipArray = array of TClip;

  { Not read/written anywhere yet - recording and the piano roll will use this
    later, defined now so both can build on it without a later redesign. }
  TNoteEvent = record
    StartFrame: Int64;
    PitchSemitones: Single;
    LengthFrames: Int64;
  end;

implementation

end.
