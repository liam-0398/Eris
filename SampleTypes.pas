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

  { A warp marker pins one point in the source audio (SourceFrame, relative to
    the clip's Offset) to one point on the timeline (TimelineFrame, relative
    to the clip's Position). Between consecutive markers, playback runs at
    whatever vari-speed rate is needed to cover that source span in that
    timeline span - the same resample engine used for keyboard pitch. An
    empty array means unwarped (1:1) playback. }
  TWarpMarker = record
    SourceFrame: Int64;
    TimelineFrame: Int64;
  end;
  TWarpMarkerArray = array of TWarpMarker;

  TClip = record
    SampleID: Integer;
    Offset, Length: Int64;
    Position: Int64;
    TrackID: Integer;
    PitchSemitones: Single;
    Gain: Single;
    WarpMarkers: TWarpMarkerArray;
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
