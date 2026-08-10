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

  { detected transient/onset positions within a sample, in source frames,
    ascending order - see Waveform.DetectTransients }
  TFrameArray = array of Int64;

const
  { The one sample rate everything in the pool is held at. The engine has no
    per-sample rate: AudioEngine plays every voice at ProjectSampleRate and
    derives its playback rate purely from pitch, while the editors size their
    rulers and markers from TSample.SampleRate - so a sample stored at any
    other rate makes those two disagree, which put the instrument editor's end
    marker away from the end of the audio and played the sample off-pitch by
    the rate ratio. WavDecoder.DecodeSampleFile converts everything to this on
    the way in so the mismatch can't arise. Must stay equal to
    AudioEngine.ProjectSampleRate, which can't reference it (AudioEngine's
    interface section has no uses clause). }
  CanonicalSampleRate = 44100;

  { Beats (default): each segment plays at 1:1 and loops/truncates its tail
    to hit the next marker, preserving pitch - see AudioEngine.ClipSourcePosition.
    RePitch: the classic continuous vari-speed warp - each segment resamples
    linearly across its whole span using the same resample engine as
    keyboard pitch-shifting, so moving a marker changes playback speed (and
    therefore pitch) smoothly across both the segment before and after it. }
  { Tones ("LF"): pitch-synchronous overlap-add for sustained low-frequency
    material - 808s, sub bass, anything monophonic where Beats' transient
    slicing has nothing useful to slice at and its splices land mid-cycle of
    a waveform whose period is longer than the crossfade. See
    AudioEngine.TonesClipSample. }
  WarpModeBeats = 0;
  WarpModeRePitch = 1;
  WarpModeTones = 2;

type
  TClip = record
    SampleID: Integer;
    Offset, Length: Int64;
    Position: Int64;
    TrackID: Integer;
    PitchSemitones: Single;
    Gain: Single;
    WarpMarkers: TWarpMarkerArray;
    WarpMode: Integer;
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
