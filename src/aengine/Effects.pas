unit Effects;

{$mode objfpc}{$H+}

interface

uses
  Math, BiquadFilters, Quadraverb, BBE422A, Alesis3630, BossFZ2;

const
  MaxEffectsPerTrack = 4;
  MaxEQBands = 4;

  ekNone = 0;
  ekLowpass = 1;
  ekEQ4 = 2;
  ekLimiter = 3;
  ekChorus = 4;
  ekReverb = 5;
  ekFlanger = 6;
  ekPhaser = 7;
  ekSidechain = 8;
  ekDrowning = 9;
  ekHighpass = 10;
  ekBandpass = 11;
  ekTuner = 12;
  ekOverdrive = 13;
  ekQuadraverbReverb = 14;
  ekQuadraverbDelay = 15;
  ekExciter422A = 16;
  ekCompressor3630 = 17;
  ekFuzzFZ2 = 18;

  { classic vintage-style chorus (think Ableton Live 1/2's Chorus, or a
    tracker's chorus command) - just a short modulated delay line per
    channel, mixed 50/50 with the dry signal, no feedback/multi-voice
    ensemble stacking like a modern chorus. L and R LFOs run 90 degrees out
    of phase for stereo width, which is most of what makes it sound "wide"
    rather than just wobbly. }
  ChorusCenterDelayMs = 15.0;
  ChorusModRangeMs = 8.0;
  ChorusMaxDelayMs = 30.0;

  { Flanger: the same modulated-delay recipe as Chorus, but a much shorter
    center delay (a few ms instead of ~15ms) plus a feedback path around the
    delay line - the feedback is what turns it from "chorus but shorter"
    into the distinctive metallic, resonant flanger sweep. }
  FlangerCenterDelayMs = 4.0;
  FlangerModRangeMs = 3.5;
  FlangerMaxDelayMs = 8.0;

  { Phaser: N cascaded first-order allpass stages (classic Small
    Stone/Phase 90 recipe), all sharing one LFO-swept center frequency per
    channel, plus a feedback tap around the whole chain for a more
    pronounced, resonant sweep. }
  PhaserStageCount = 4;
  PhaserMinFreqHz = 200.0;
  PhaserMaxFreqHz = 2000.0;

  { "Basic Reverb" - a small Schroeder/Freeverb-style tank: a handful of
    parallel comb filters (each with a one-pole lowpass in its feedback path
    for natural high-frequency damping) feeding a couple of series allpass
    filters for diffusion. Far simpler than a modern algorithmic reverb, but
    it's the same basic recipe most simple/vintage reverbs actually use. }
  ReverbPresetSmall = 0;
  ReverbPresetRoom = 1;
  ReverbPresetClub = 2;
  ReverbPresetHall = 3;
  ReverbPresetPlate = 4;
  ReverbPresetCount = 5;
  ReverbPresetNames: array[0..ReverbPresetCount - 1] of string =
    ('Small', 'Room', 'Club', 'Hall', 'Plate');

  ReverbCombCount = 4;
  ReverbAllpassCount = 2;
  ReverbAllpassFeedback = 0.5;
  { classic Freeverb comb/allpass tuning (originally in samples @ 44.1kHz),
    expressed in ms so they scale cleanly to any project sample rate }
  ReverbCombBaseMs: array[0..ReverbCombCount - 1] of Single =
    (35.31, 36.67, 33.81, 32.24);
  ReverbAllpassBaseMs: array[0..ReverbAllpassCount - 1] of Single =
    (12.61, 10.00);
  { small L/R delay-length offset for stereo width, Freeverb's own trick,
    expressed relative to a 44.1kHz reference like the tunings above }
  ReverbStereoSpreadSamples44k = 23;
  { Largest room any caller of SetupReverbTank can ask for, and so the size
    every tank line is actually allocated at. ekReverb's biggest preset is
    Hall at 1.4; ekDrowning maps its Size slider to 0.4 + Size/100 * 1.6,
    which tops out at exactly 2.0. Raise this if either of those grows, or
    the tank quietly clamps to a smaller room than was asked for. }
  ReverbMaxRoomScale = 2.0;

  { "Tuner" (Utility category): a completely passive pitch readout - it never
    touches the audio, it only listens to whatever reaches its slot in the
    chain and reports the note being played.

    Detection runs on a heavily decimated mono copy of the signal. A tuner
    needs nothing above ~1.5kHz, and the cost of the difference function in
    TunerDetect is quadratic in the window length, so decimating to ~8kHz
    first is what makes this cheap enough to sit in a realtime chain at all.
    The algorithm is YIN's cumulative-mean-normalised difference function
    rather than plain autocorrelation: plain autocorrelation octave-errors
    badly on anything with a strong second harmonic, which is most of what
    ends up on a DAW track. }
  TunerTargetRateHz = 8000;
  TunerWindowSamples = 1024; { ~116ms of analysis at 8.8kHz }
  TunerHopSamples = 512;     { detection re-runs this often, ~17x a second }
  { lag search bounds, in analysis samples. The ceiling is the window's own
    half-length (TunerWindowSamples div 2), which at 8.8kHz reaches down to
    ~17Hz - well below anything TunerMinHz will accept. }
  TunerMinLag = 6;
  TunerYinThreshold = 0.15;  { YIN's absolute threshold, its paper's value }
  { above this, the best dip found isn't convincing enough to call a pitch -
    noise, a drum hit, or a chord all land here }
  TunerMaxCmnd = 0.55;
  TunerGateRms = 0.0025;     { ~-52 dBFS; below it there is nothing to read }
  { consecutive no-reading hops before the display blanks. ~1.5s, long enough
    that the readout holds through the gap between two notes instead of
    flickering off between every one. }
  TunerHopsToClear = 26;
  TunerMinHz = 25.0;
  TunerMaxHz = 2000.0;
  TunerA4Hz = 440.0;
  { cents thresholds for the 1st, 2nd and 3rd off-pitch dot - see
    TunerDotCount. Under the first one the note reads as in tune and no dots
    light at all. }
  TunerDot1Cents = 5.0;
  TunerDot2Cents = 20.0;
  TunerDot3Cents = 35.0;
  TunerNoteNames: array[0..11] of string =
    ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B');

  { "Overdrive" (Distortion category): a general-purpose saturator - loudness
    maximiser, 808 destroyer, or a bit of crunch, depending on where the
    controls sit.

    The Frequency/Q pair is a pre-emphasis peaking boost in front of the
    waveshaper, followed by the exact inverse peaking cut behind it (an RBJ
    peaking filter at -G is the reciprocal magnitude of the same filter at
    +G, so the two cancel). That makes Frequency/Q read as "where the grit
    is" rather than as a plain tone control: the emphasised band is the
    first thing to reach the shaper's knee and so distorts hardest, but
    whatever the shaper left linear gets its boost taken straight back out,
    so the overall balance stays roughly flat instead of leaving an EQ bump
    behind. Same trick a Tube Screamer's mid hump plays, minus the hump.

    Because the shaper saturates to +/-1 and the only thing after it is a
    CUT, the wet path can never leave this effect above full scale however
    hard it's driven. }
  OverdrivePreEmphasisDb = 9.0;
  OverdriveMaxDriveDb = 36.0;
  { deliberate asymmetry, faded out as Color goes hard: an offset waveform
    clips unevenly and so generates even harmonics, which is most of what
    separates a warm tube-ish overdrive from a buzzy symmetric one }
  OverdriveAsymBias = 0.08;
  { DC blocker pole. Deliberately way down at ~3.5Hz rather than the usual
    ~30Hz: the offset it has to remove is pure DC and doesn't care, while
    an 808's fundamental sits at 40-60Hz and a 30Hz one-pole would audibly
    thin exactly the material this effect exists to mangle. }
  OverdriveDcBlockCoeff = 0.9995;

type
  { plain flat record with fields used depending on Kind, matching the
    project's existing tagged-record style (see AudioEngine.TCommand) rather
    than a strict Pascal variant record }
  TEffect = record
    Kind: Integer;
    LowpassFreqHz: Single;
    HighpassFreqHz: Single;
    BandpassFreqHz: Single;
    BandpassQ: Single;
    EQFreqHz: array[0..MaxEQBands - 1] of Single;
    EQGainDb: array[0..MaxEQBands - 1] of Single;
    LimiterThresholdDb: Single;
    LimiterReleaseMs: Single;
    ChorusRateHz: Single;
    ChorusDepthPercent: Single;
    ReverbPreset: Integer;
    ReverbMixPercent: Single;
    FlangerRateHz: Single;
    FlangerDepthPercent: Single;
    FlangerFeedbackPercent: Single;
    FlangerMixPercent: Single;
    PhaserRateHz: Single;
    PhaserDepthPercent: Single;
    PhaserFeedbackPercent: Single;
    PhaserMixPercent: Single;
    { SidechainSourceTrack is a 0-based track index (Project.Tracks/TrackEffects
      convention); ProcessEffect itself never sees Project - AudioEngine looks
      the source track's live level up and passes it in as ASidechainLevel }
    SidechainSourceTrack: Integer;
    SidechainThresholdDb: Single;
    SidechainAttackMs: Single;
    SidechainReleaseMs: Single;
    SidechainStrengthPercent: Single;
    { "Drowning" (Experimental category): LP tone -> chorus-style warble ->
      comb/allpass reverb tank, see ProcessEffect's ekDrowning branch }
    DrowningToneHz: Single;
    DrowningWarbleRateHz: Single;
    DrowningWarbleDepthPercent: Single;
    DrowningSizePercent: Single;
    DrowningDecayPercent: Single;
    DrowningMixPercent: Single;
    { ekTuner has no parameters at all - it only reads. Its result lives in
      TEffectState below (TunerFreqHz), not here, because it's produced by
      the audio thread rather than set by the user, and TEffect is what gets
      serialised into the project file. }
    OverdriveFreqHz: Single;
    OverdriveQ: Single;
    OverdriveDrivePercent: Single;
    OverdriveColorPercent: Single;
    OverdriveMixPercent: Single;
    { QuadraVerb. Names and ranges are the original front panel's - see
      Quadraverb.pas, which owns all the DSP and the range constants. }
    QVReverbType: Integer;
    QVReverbPredelayMs: Single;
    QVReverbPredelayMix: Single;
    QVReverbDecay: Single;
    QVReverbDiffusion: Single;
    QVReverbDensity: Single;
    QVReverbLowDecay: Single;
    QVReverbHighDecay: Single;
    QVReverbMixPercent: Single;
    QVDelayType: Integer;
    QVDelayTimeLMs: Single;
    QVDelayTimeRMs: Single;
    QVDelayFeedbackL: Single;
    QVDelayFeedbackR: Single;
    QVDelayMixPercent: Single;
    { BBE Sonic Maximizer 422A. Names and ranges are the original front
      panel's - see BBE422A.pas, which owns all the DSP and the range
      constants. Mix is this program's addition, not the box's: the 422A
      only has a hard In/Out switch. }
    BBELoContourDb: Single;
    BBEDefinition: Single;
    BBEMixPercent: Single;
    { Alesis 3630. Same arrangement - see Alesis3630.pas. C36Ratio is a
      plain ratio, with A36RatioInfinite standing for the panel's infinity
      detent; C36GateThresholdDbfs is dBFS, or A36GateOffDbfs for the
      panel's fully-counter-clockwise "no gating". }
    C36Response: Integer;
    C36Knee: Integer;
    C36ThresholdDbu: Single;
    C36Ratio: Single;
    C36AttackMs: Single;
    C36ReleaseMs: Single;
    C36OutputDb: Single;
    C36GateThresholdDbfs: Single;
    C36GateRateMs: Single;
    C36MixPercent: Single;
    { Boss FZ-2 Hyper Fuzz. Same arrangement again - see BossFZ2.pas, which
      owns all the DSP and every range constant. FZ2Mode is one of its
      FZ2Mode* constants; the four knobs are the panel's own 0..10, stored
      here on 0..100 so a slider has something to resolve. Mix is this
      program's addition, not the pedal's. }
    FZ2Mode: Integer;
    FZ2Gain: Single;
    FZ2Treble: Single;
    FZ2Bass: Single;
    FZ2Level: Single;
    FZ2MixPercent: Single;
  end;

  TEffectChannelState = record
    LowpassBq: TBiquadState;
    HighpassBq: TBiquadState;
    BandpassBq: TBiquadState;
    EQBq: array[0..MaxEQBands - 1] of TBiquadState;
  end;

  { Buf is allocated once at the largest room the tank can ever be asked for
    (see ReverbMaxRoomScale) and never resized again; Len is how much of it
    this room actually uses, and is the delay length as far as the DSP is
    concerned. The two were the same thing when the buffer was resized per
    room - but that resize ran from ProcessEffect, i.e. on the realtime
    thread, and ekDrowning sizes its tank from a continuous Size slider, so
    dragging that slider reallocated twelve buffers per mouse move underneath
    the audio callback. Separating them makes a room change a length
    assignment and a memset. }
  { named so SetTankLine can take one by reference and SetLength it - an
    anonymous "array of Single" field would arrive there as an open array }
  TSingleArray = array of Single;

  TCombState = record
    Buf: TSingleArray;
    Len: Integer;
    BufPos: Integer;
    FilterStore: Single;
  end;

  TAllpassState = record
    Buf: TSingleArray;
    Len: Integer;
    BufPos: Integer;
  end;

  TEffectState = record
    Channels: array[0..1] of TEffectChannelState; { L, R }
    LowpassCoeffs: TBiquadCoeffs;
    HighpassCoeffs: TBiquadCoeffs;
    BandpassCoeffs: TBiquadCoeffs;
    EQCoeffs: array[0..MaxEQBands - 1] of TBiquadCoeffs;
    LastSampleRate: Integer;
    LastLowpassFreq: Single;
    LastHighpassFreq: Single;
    LastBandpassFreq: Single;
    LastBandpassQ: Single;
    LastEQFreq: array[0..MaxEQBands - 1] of Single;
    LastEQGain: array[0..MaxEQBands - 1] of Single;
    LimiterGain: Single; { current smoothed gain reduction, linked across L/R
      so limiting never shifts the stereo image }
    { cached so Power()/Exp() below only run when a slider actually moved,
      same pattern as LastLowpassFreq/LastEQFreq above - previously these
      ran unconditionally on every single sample }
    LastLimiterThresholdDb: Single;
    LimiterThresholdLin: Single;
    LastLimiterReleaseMs: Single;
    LimiterReleaseCoeff: Single;
    ChorusBufL: array of Single; { lazily sized once the sample rate is known }
    ChorusBufR: array of Single;
    ChorusWritePos: Integer;
    ChorusPhase: Single; { 0..1, one full LFO cycle }
    ReverbCombL, ReverbCombR: array[0..ReverbCombCount - 1] of TCombState;
    ReverbAllpassL, ReverbAllpassR: array[0..ReverbAllpassCount - 1] of TAllpassState;
    ReverbLastPreset: Integer; { -1 = not yet set up, forces setup on first use }
    ReverbLastSampleRate: Integer;
    { tank coefficients resolved from the preset, and the dry/wet fraction -
      recomputed only when the thing they derive from actually moved, same
      pattern as LastLowpassFreq/LimiterThresholdLin above }
    ReverbFeedback: Single;
    ReverbDamp1: Single;
    ReverbDamp2: Single;
    LastReverbMixPercent: Single;
    ReverbMixFrac: Single;
    FlangerBufL: array of Single; { lazily sized once the sample rate is known }
    FlangerBufR: array of Single;
    FlangerWritePos: Integer;
    FlangerPhase: Single; { 0..1, one full LFO cycle }
    PhaserZ1x: array[0..1, 0..PhaserStageCount - 1] of Single; { [channel][stage] }
    PhaserZ1y: array[0..1, 0..PhaserStageCount - 1] of Single;
    PhaserFeedbackSample: array[0..1] of Single; { last chain output, fed back into this channel's input }
    PhaserPhase: Single;
    SidechainGain: Single; { current smoothed ducking gain, 1.0 = no reduction }
    { same caching as Limiter above }
    LastSidechainThresholdDb: Single;
    SidechainThresholdLin: Single;
    LastSidechainAttackMs: Single;
    SidechainAttackCoeff: Single;
    LastSidechainReleaseMs: Single;
    SidechainReleaseCoeff: Single;
    { Drowning reuses Channels[].LowpassBq/LowpassCoeffs (tone stage),
      ChorusBufL/R/ChorusWritePos/ChorusPhase (warble stage) and
      ReverbCombL/R/ReverbAllpassL/R (tank stage) above - only these two
      "last settings seen" fields are Drowning-specific, since its tank is
      sized off a continuous Size slider rather than ekReverb's preset list }
    DrowningLastSizePercent: Single;
    DrowningLastSampleRate: Integer;
    { Tuner. TunerBuf/TunerDiff are lazily sized on first use like
      ChorusBufL/FlangerBufL above rather than being fixed-size arrays for a
      specific reason: TEffectState is held in a MaxTracks x
      MaxEffectsPerTrack array, and ProjectFile.RenderProjectToWav declares
      one of those as a LOCAL - 6KB of scratch per state would put most of a
      megabyte on that function's stack. The tuner also reuses
      Channels[0].LowpassBq/LowpassCoeffs for its anti-alias filter, same
      state-sharing convention as ekDrowning. }
    TunerBuf: array of Single;   { the analysis window, decimated mono }
    TunerDiff: array of Single;  { the CMND function, one entry per lag }
    TunerFill: Integer;
    TunerDecimPos: Integer;
    TunerDecimAccum: Single;
    TunerDecimFactor: Integer;
    TunerLastSampleRate: Integer;
    TunerQuietHops: Integer;
    { The actual cross-thread readout: written here by the audio thread,
      read by the rack widget's refresh timer on the UI thread via
      TunerReadoutHz. A plain unsynchronized Single, same tolerance as
      Project.TrackVolume - a display one block stale is invisible. }
    TunerFreqHz: Single;
    { Overdrive. Reuses Channels[].EQBq[0]/[1] and EQCoeffs[0]/[1] for its
      pre-emphasis/post-de-emphasis filter pair - only one Kind is ever live
      in a slot, the same sharing convention Lowpass/EQ4/Drowning already
      use - so only these caches are Overdrive-specific. }
    LastOverdriveFreq: Single;
    LastOverdriveQ: Single;
    LastOverdriveDrivePercent: Single;
    OverdriveDriveGain: Single;
    OverdriveDcX1: array[0..1] of Single;
    OverdriveDcY1: array[0..1] of Single;
    { QuadraVerb. Both carry their own host-rate/31.25kHz converter, so
      neither shares any of the state above - the two are genuinely
      separate machines and a slot only ever runs one of them. }
    QVReverb: TQVReverbState;
    QVDelay: TQVDelayState;
    { Same again for the two emulated boxes below: each owns its whole
      signal path, including its own filters and delay lines, so neither
      shares any of the state above. }
    BBE: TBBE422State;
    C36: TA36State;
    FZ2: TFZ2State;
  end;

procedure EffectStateReset(var AState: TEffectState);
procedure DefaultEffect(AKind: Integer; out AEffect: TEffect);

{ Runs one track-insert effect over a single frame's L/R in place. Coefficient
  recomputation only happens when a parameter actually changed since the
  last call, so turning a knob is cheap and holding it still is even cheaper.
  ASidechainLevel is the current linear peak level of AEffect.SidechainSourceTrack
  - meaningless for every Kind except ekSidechain, and looked up by the
  caller (AudioEngine), since this unit has no idea Project/tracks exist. }
procedure ProcessEffect(var AState: TEffectState; const AEffect: TEffect;
  var L, R: Single; ASampleRate: Integer; ASidechainLevel: Single);

{ The pitch an ekTuner slot last heard, in Hz, or 0 for "nothing to read".
  Written by ProcessEffect on the audio thread; this is the accessor the UI
  reads it back through - see TunerFreqHz's declaration for why an
  unsynchronized read is fine. }
function TunerReadoutHz(const AState: TEffectState): Single;

{ Nearest equal-tempered semitone to a detected frequency, as a MIDI note
  number, plus how far off that note the frequency actually is in cents
  (-50..+50). False for anything outside TunerMinHz..TunerMaxHz, i.e. for a
  frequency not worth naming. Note NAME is up to the caller - TunerNoteNames
  above is indexed by AMidiNote mod 12, and the octave is AMidiNote div 12 - 1
  (the MIDI convention where note 60 is C4). }
function TunerNoteFromFreq(AFreqHz: Single; out AMidiNote: Integer;
  out ACents: Single): Boolean;

{ How many of the three off-pitch dots to light for a cents deviation:
  0 (in tune) to 3 (nearly a quarter-tone out). The SIGN of ACents picks
  which side of the note they're drawn on, flat or sharp. Because
  TunerNoteFromFreq always names the NEAREST note, drifting past 50 cents
  flips the displayed note by a semitone and the dots reappear from the
  opposite side on their own - no special case needed for "far off". }
function TunerDotCount(ACents: Single): Integer;

implementation

const
  LowpassQ = 0.707;
  EQQ = 1.0;

procedure EffectStateReset(var AState: TEffectState);
begin
  { TEffectState holds a dozen dynamic arrays (the reverb tank lines, the
    chorus/flanger/tuner buffers, and more of the same inside the QV/BBE/3630
    sub-states). FillChar zeroes their pointers WITHOUT releasing what they
    point at, so every reset - engine init, File > New, project load - simply
    orphaned the lot. That was already true; it matters more now that a tank
    line is allocated for the largest room rather than the current one.
    Finalize walks the record's managed fields and drops the references
    properly, and the FillChar below then does exactly what it always did.
    Safe on every caller: all of them pass either a global or a local, and
    FPC initialises both kinds of managed record before first use. }
  Finalize(AState);
  FillChar(AState, SizeOf(AState), 0);
  AState.LimiterGain := 1.0; { unity - no reduction until something is loud enough to need it }
  AState.ReverbLastPreset := -1; { 0 is a valid preset (Small) - must not look
    already-set-up before SetupReverb has ever actually allocated buffers }
  AState.SidechainGain := 1.0; { unity - no ducking until the source track actually hits }
  { NaN, not 0 - a real threshold/release value of exactly 0 is legal, and
    would otherwise look like "unchanged" against a zeroed Last* field on
    the very first call, leaving the paired *Lin/*Coeff field at its
    zeroed (wrong) default instead of ever actually being computed. NaN
    never compares equal to anything, including itself, so the first real
    call always recomputes regardless of what value it sees. }
  { 0% is a legal reverb mix, so this needs the NaN sentinel too - a zeroed
    LastReverbMixPercent against a 0% setting would look "unchanged" and leave
    ReverbMixFrac at its zeroed default forever }
  AState.LastReverbMixPercent := NaN;
  AState.LastLimiterThresholdDb := NaN;
  AState.LastLimiterReleaseMs := NaN;
  AState.LastSidechainThresholdDb := NaN;
  AState.LastSidechainAttackMs := NaN;
  AState.LastSidechainReleaseMs := NaN;
  AState.LastOverdriveFreq := NaN;
  AState.LastOverdriveQ := NaN;
  AState.LastOverdriveDrivePercent := NaN;
  { these do their own FillChar plus their own NaN/-1 "not built yet"
    sentinels, same reasoning as above }
  QVReverbReset(AState.QVReverb);
  QVDelayReset(AState.QVDelay);
  BBE422Reset(AState.BBE);
  A36Reset(AState.C36);
  FZ2Reset(AState.FZ2);
end;

procedure DefaultEffect(AKind: Integer; out AEffect: TEffect);
begin
  FillChar(AEffect, SizeOf(AEffect), 0);
  AEffect.Kind := AKind;
  case AKind of
    ekLowpass:
      AEffect.LowpassFreqHz := 8000;
    ekHighpass:
      AEffect.HighpassFreqHz := 100;
    ekBandpass:
      begin
        AEffect.BandpassFreqHz := 1000;
        AEffect.BandpassQ := 1.0;
      end;
    ekEQ4:
      begin
        { sane low/low-mid/high-mid/high spread, unity gain (0dB) to start }
        AEffect.EQFreqHz[0] := 100;
        AEffect.EQFreqHz[1] := 500;
        AEffect.EQFreqHz[2] := 2000;
        AEffect.EQFreqHz[3] := 8000;
      end;
    ekLimiter:
      begin
        AEffect.LimiterThresholdDb := -1.0; { ceiling just under 0dBFS }
        AEffect.LimiterReleaseMs := 150;
      end;
    ekChorus:
      begin
        AEffect.ChorusRateHz := 0.5; { classic slow, lush default sweep }
        AEffect.ChorusDepthPercent := 50;
      end;
    ekReverb:
      begin
        AEffect.ReverbPreset := ReverbPresetRoom;
        AEffect.ReverbMixPercent := 30;
      end;
    ekFlanger:
      begin
        AEffect.FlangerRateHz := 0.3;
        AEffect.FlangerDepthPercent := 60;
        AEffect.FlangerFeedbackPercent := 40;
        AEffect.FlangerMixPercent := 50;
      end;
    ekPhaser:
      begin
        AEffect.PhaserRateHz := 0.4;
        AEffect.PhaserDepthPercent := 70;
        AEffect.PhaserFeedbackPercent := 30;
        AEffect.PhaserMixPercent := 50;
      end;
    ekSidechain:
      begin
        AEffect.SidechainSourceTrack := 0;
        AEffect.SidechainThresholdDb := -20;
        AEffect.SidechainAttackMs := 5;
        AEffect.SidechainReleaseMs := 150;
        AEffect.SidechainStrengthPercent := 70;
      end;
    ekDrowning:
      begin
        { 2012-Clams-Casino-vocal-wash defaults: dark, slow-warbling, big and
          long-tailed, roughly half-drowned rather than fully submerged }
        AEffect.DrowningToneHz := 2500;
        AEffect.DrowningWarbleRateHz := 0.35;
        AEffect.DrowningWarbleDepthPercent := 55;
        AEffect.DrowningSizePercent := 65;
        AEffect.DrowningDecayPercent := 70;
        AEffect.DrowningMixPercent := 45;
      end;
    ekOverdrive:
      begin
        { a usable "add some crunch" starting point rather than a null one:
          focused on the low mids where most weight lives, driven enough to
          be audibly doing something, mostly soft-knee, fully wet }
        AEffect.OverdriveFreqHz := 800;
        AEffect.OverdriveQ := 0.7;
        AEffect.OverdriveDrivePercent := 40;
        AEffect.OverdriveColorPercent := 30;
        AEffect.OverdriveMixPercent := 100;
      end;
    ekQuadraverbReverb:
      begin
        { straight to the atmospheric-jungle setting rather than a neutral
          one: a big hall, most of the way to full decay, predelayed enough
          that a break stays defined in front of it, diffusion up so it's a
          wash rather than a set of echoes, and a hard high-frequency decay
          cut so the tail goes dark as it falls away instead of hissing on
          top of the mix. This is the Good Looking sound's home position. }
        AEffect.QVReverbType := QVReverbHall;
        AEffect.QVReverbPredelayMs := 65;
        AEffect.QVReverbPredelayMix := 70;
        AEffect.QVReverbDecay := 82;
        AEffect.QVReverbDiffusion := 8;
        AEffect.QVReverbDensity := 6;
        AEffect.QVReverbLowDecay := -10;
        AEffect.QVReverbHighDecay := -62;
        AEffect.QVReverbMixPercent := 35;
      end;
    ekQuadraverbDelay:
      begin
        { ping-pong near the top of QuadMode's 400ms ceiling, which at
          165-175bpm is roughly a dotted 1/16 - the bouncing stab/vocal
          delay the genre runs on - with enough feedback for the repeats to
          smear into whatever reverb follows }
        AEffect.QVDelayType := QVDelayPingPong;
        AEffect.QVDelayTimeLMs := 375;
        AEffect.QVDelayTimeRMs := 375;
        AEffect.QVDelayFeedbackL := 45;
        AEffect.QVDelayFeedbackR := 45;
        AEffect.QVDelayMixPercent := 30;
      end;
    ekExciter422A:
      begin
        { the master-bus setting rather than a neutral one: Definition about
          two thirds up, which is where the top of a break starts cutting
          without the box announcing itself, and Lo Contour up a few dB to
          put back the 50Hz the process's own band split thins out. Fully
          wet, because the time alignment is the point and any dry blend
          fights it - see the ekExciter422A branch in ProcessEffect. }
        AEffect.BBELoContourDb := 4;
        AEffect.BBEDefinition := 65;
        AEffect.BBEMixPercent := 100;
      end;
    ekCompressor3630:
      begin
        { straight to the break setting: Peak, hard knee, fast attack, high
          ratio, and a release short enough to pump back up before the next
          hit. Gate off - it is off on the real panel's fully
          counter-clockwise position too, and gating a break is a decision,
          not a default. }
        AEffect.C36Response := A36ResponsePeak;
        AEffect.C36Knee := A36KneeHard;
        AEffect.C36ThresholdDbu := -8;
        AEffect.C36Ratio := 8;
        AEffect.C36AttackMs := 1;
        AEffect.C36ReleaseMs := 120;
        AEffect.C36OutputDb := 4;
        AEffect.C36GateThresholdDbfs := A36GateOffDbfs;
        AEffect.C36GateRateMs := 200;
        AEffect.C36MixPercent := 100;
      end;
    ekFuzzFZ2:
      begin
        { Dopethrone, not a neutral setting. Fuzz II because the mid-scoop
          is the whole point of that record's guitar sound - Fuzz I next to
          it sounds like a distortion pedal. Gain buried, because Electric
          Wizard did not own a knob that pointed anywhere but clockwise;
          Bass most of the way up to put the weight back under a scoop that
          just removed a lot of it; Treble a little over noon, which is
          enough for the fuzz's own fizz to cut without the octave section
          turning into hiss.

          Level under half looks low for this patch and isn't: with Gain
          buried, the fuzz output is pinned near full scale before Level
          ever sees it - that is what the diodes DO - and the +9dB bass
          shelf on top of a hard-clipped square would take the peaks past
          0dBFS at anything near noon. Level here is a DAW output trim, not
          the catch-up gain it is on a pedalboard, and it is the knob to
          push by ear once the rest of the chain is set. Where the input
          came from makes no difference to this: the whole point of 66dB
          into a diode clipper is that the output level stops depending on
          the input level. }
        AEffect.FZ2Mode := FZ2ModeFuzz2;
        AEffect.FZ2Gain := 100;
        AEffect.FZ2Treble := 62;
        AEffect.FZ2Bass := 88;
        AEffect.FZ2Level := 45;
        AEffect.FZ2MixPercent := 100;
      end;
    { ekTuner has no parameters - FillChar above is the whole setup }
  end;
end;

{ Fractional-delay read from a circular buffer with linear interpolation;
  AReadPos may be (slightly) negative, since write-position minus a delay in
  samples can dip below 0 near the start of playback - wrap it back into
  range first. }
function ReadDelayInterp(const ABuf: array of Single; ALen: Integer;
  AReadPos: Double): Single;
var
  i0, i1: Integer;
  T: Int64;
  Frac: Double;
begin
  while AReadPos < 0 do
    AReadPos := AReadPos + ALen;

  { The wrap loop above leaves AReadPos in [0, ALen) for every delay this is
    actually called with, so "mod ALen" was a no-op on the hot path that still
    cost a full idiv - tens of cycles, unpipelined, and paid twice per read,
    which is four times per frame per chorus/flanger instance. Testing first
    keeps the divide reachable for any input the old form would have wrapped,
    so the result is identical either way. }
  T := Trunc(AReadPos);
  Frac := AReadPos - T;
  if T < ALen then
    i0 := T
  else
    i0 := T mod ALen;

  { i0 is now in [0, ALen), so the successor can only ever overshoot by one }
  i1 := i0 + 1;
  if i1 >= ALen then
    i1 := 0;

  Result := ABuf[i0] * (1 - Frac) + ABuf[i1] * Frac;
end;

{ One comb filter with a one-pole lowpass (damp1/damp2) inside its feedback
  path - the lowpass is what makes the decaying tail sound like it's losing
  high end naturally (air absorption) instead of ringing forever. }
function ProcessComb(var AState: TCombState; AInput, AFeedback, ADamp1,
  ADamp2: Single): Single;
var
  Output: Single;
begin
  Output := AState.Buf[AState.BufPos];
  AState.FilterStore := (Output * ADamp2) + (AState.FilterStore * ADamp1);
  AState.Buf[AState.BufPos] := AInput + AState.FilterStore * AFeedback;
  Inc(AState.BufPos);
  { Len, not Length(Buf) - the allocation is sized for the largest room, this
    room only uses the front of it. See TCombState. }
  if AState.BufPos >= AState.Len then
    AState.BufPos := 0;
  Result := Output;
end;

function ProcessAllpass(var AState: TAllpassState; AInput, AFeedback: Single): Single;
var
  BufOut: Single;
begin
  BufOut := AState.Buf[AState.BufPos];
  Result := -AInput + BufOut;
  AState.Buf[AState.BufPos] := AInput + BufOut * AFeedback;
  Inc(AState.BufPos);
  if AState.BufPos >= AState.Len then
    AState.BufPos := 0;
end;

procedure ReverbPresetParams(APreset: Integer; out ARoomScale, AFeedback,
  ADamping: Single);
begin
  case APreset of
    ReverbPresetSmall:
      begin ARoomScale := 0.5;  AFeedback := 0.60; ADamping := 0.30; end;
    ReverbPresetClub:
      begin ARoomScale := 0.9;  AFeedback := 0.78; ADamping := 0.25; end;
    ReverbPresetHall:
      begin ARoomScale := 1.4;  AFeedback := 0.86; ADamping := 0.40; end;
    ReverbPresetPlate:
      begin ARoomScale := 0.65; AFeedback := 0.80; ADamping := 0.15; end;
  else
    { ReverbPresetRoom and any unrecognized value }
    begin ARoomScale := 0.75; AFeedback := 0.70; ADamping := 0.35; end;
  end;
end;

{ (Re)allocates every comb/allpass delay line for a given room scale and
  sample rate. Only called when either actually changes - not per-sample.
  Shared by ekReverb (which resolves RoomScale from a fixed preset via
  ReverbPresetParams) and ekDrowning (which sizes its tank straight off a
  continuous Size slider instead of a preset). }
{ Sizes one comb/allpass line: the allocation covers the largest room the
  tank can ever be asked for, ALen is what this room uses. Only ever grows,
  so after the first call for a given sample rate no room change allocates
  anything - which is the point, since the caller runs on the audio thread. }
procedure SetTankLine(var ABuf: TSingleArray; var ALen, ABufPos: Integer;
  ABaseMs, ARoomScale: Single; AExtra, ASampleRate: Integer);
var
  MaxLen: Integer;
begin
  ALen := Round(ABaseMs * ARoomScale * ASampleRate / 1000);
  if ALen < 1 then
    ALen := 1;
  Inc(ALen, AExtra);

  MaxLen := Round(ABaseMs * ReverbMaxRoomScale * ASampleRate / 1000);
  if MaxLen < 1 then
    MaxLen := 1;
  Inc(MaxLen, AExtra);
  { ALen is derived from a scale this clamp guarantees is <= the max, so this
    only ever guards against a rounding edge, never a real overflow }
  if ALen > MaxLen then
    ALen := MaxLen;

  if Length(ABuf) <> MaxLen then
    SetLength(ABuf, MaxLen);
  { the whole allocation, not just ALen: a later room may expose more of the
    buffer than this one uses, and it must not surface a previous room's tail }
  FillChar(ABuf[0], MaxLen * SizeOf(Single), 0);
  ABufPos := 0;
end;

procedure SetupReverbTank(var AState: TEffectState; ARoomScale: Single; ASampleRate: Integer);
var
  c, StereoSpreadSamples: Integer;
begin
  if ARoomScale > ReverbMaxRoomScale then
    ARoomScale := ReverbMaxRoomScale;
  StereoSpreadSamples := Round(ReverbStereoSpreadSamples44k * ASampleRate / 44100);

  for c := 0 to ReverbCombCount - 1 do
  begin
    SetTankLine(AState.ReverbCombL[c].Buf, AState.ReverbCombL[c].Len,
      AState.ReverbCombL[c].BufPos, ReverbCombBaseMs[c], ARoomScale, 0,
      ASampleRate);
    SetTankLine(AState.ReverbCombR[c].Buf, AState.ReverbCombR[c].Len,
      AState.ReverbCombR[c].BufPos, ReverbCombBaseMs[c], ARoomScale,
      StereoSpreadSamples, ASampleRate);
    AState.ReverbCombL[c].FilterStore := 0;
    AState.ReverbCombR[c].FilterStore := 0;
  end;

  for c := 0 to ReverbAllpassCount - 1 do
  begin
    SetTankLine(AState.ReverbAllpassL[c].Buf, AState.ReverbAllpassL[c].Len,
      AState.ReverbAllpassL[c].BufPos, ReverbAllpassBaseMs[c], ARoomScale, 0,
      ASampleRate);
    SetTankLine(AState.ReverbAllpassR[c].Buf, AState.ReverbAllpassR[c].Len,
      AState.ReverbAllpassR[c].BufPos, ReverbAllpassBaseMs[c], ARoomScale,
      StereoSpreadSamples, ASampleRate);
  end;
end;

procedure SetupReverb(var AState: TEffectState; APreset, ASampleRate: Integer);
var
  RoomScale, Feedback, Damping: Single;
begin
  ReverbPresetParams(APreset, RoomScale, Feedback, Damping);
  SetupReverbTank(AState, RoomScale, ASampleRate);
end;

{ One first-order allpass stage (the "Regalia-Mitra" form used by most
  analog-modeled phaser plugins): a single pole/zero pair whose -90 degree
  point sits at AFreqHz. AZ1x/AZ1y are that stage's own x[n-1]/y[n-1] -
  cascading PhaserStageCount of these with a shared, LFO-swept AFreqHz is
  what produces the classic multi-notch phaser sweep. }
function ProcessAllpassFirstOrder(var AZ1x, AZ1y: Single; AInput, AFreqHz: Single;
  ASampleRate: Integer): Single;
var
  Coeff, Tan: Single;
begin
  Tan := Math.Tan(Pi * AFreqHz / ASampleRate);
  Coeff := (Tan - 1) / (Tan + 1);
  Result := Coeff * (AInput - AZ1y) + AZ1x;
  AZ1x := AInput;
  AZ1y := Result;
end;

function ClampFreq(AFreqHz: Single; ASampleRate: Integer): Single;
begin
  Result := AFreqHz;
  if Result < 20 then
    Result := 20;
  if Result > ASampleRate * 0.49 then
    Result := ASampleRate * 0.49;
end;

{ One YIN pass over the tuner's now-full analysis window, updating
  AState.TunerFreqHz. Runs once every TunerHopSamples ANALYSIS samples
  (~17 times a second), never per output frame - see the ekTuner branch of
  ProcessEffect for the decimation and windowing that feed it. }
procedure TunerDetect(var AState: TEffectState; AAnalysisRate: Double);
var
  HalfW, Tau, j, BestTau: Integer;
  Diff, Delta, RunningSum, Cmnd, BestCmnd: Double;
  Rms, dPrev, dHere, dNext, Denom, Shift, Period, Freq, Ratio: Double;
  Found: Boolean;
begin
  HalfW := TunerWindowSamples div 2;

  Rms := 0;
  for j := 0 to TunerWindowSamples - 1 do
    Rms := Rms + AState.TunerBuf[j] * AState.TunerBuf[j];
  Rms := Sqrt(Rms / TunerWindowSamples);
  if Rms < TunerGateRms then
  begin
    Inc(AState.TunerQuietHops);
    if AState.TunerQuietHops >= TunerHopsToClear then
      AState.TunerFreqHz := 0;
    Exit;
  end;

  { squared-difference function per lag, normalised on the fly by the running
    mean of every difference so far (YIN's cumulative mean normalisation).
    That normalisation is the whole trick: it kills the trivial d(0) = 0
    minimum and heavily penalises the sub-octave lags that a raw
    autocorrelation happily picks instead of the real period. }
  AState.TunerDiff[0] := 1;
  RunningSum := 0;
  BestTau := 0;
  BestCmnd := 1e30;
  Found := False;
  for Tau := 1 to HalfW do
  begin
    Diff := 0;
    for j := 0 to HalfW - 1 do
    begin
      Delta := AState.TunerBuf[j] - AState.TunerBuf[j + Tau];
      Diff := Diff + Delta * Delta;
    end;
    RunningSum := RunningSum + Diff;
    if RunningSum <= 0 then
      Cmnd := 1
    else
      Cmnd := Diff * Tau / RunningSum;
    AState.TunerDiff[Tau] := Cmnd;

    { YIN's absolute threshold: take the FIRST dip that goes below the
      threshold and has bottomed out (the next lag is no lower), not the
      global minimum - the global minimum is very often one octave down }
    if (Tau > TunerMinLag) and (AState.TunerDiff[Tau - 1] < TunerYinThreshold) and
      (Cmnd >= AState.TunerDiff[Tau - 1]) then
    begin
      BestTau := Tau - 1;
      Found := True;
      Break;
    end;
    if (Tau >= TunerMinLag) and (Cmnd < BestCmnd) then
    begin
      BestCmnd := Cmnd;
      BestTau := Tau;
    end;
  end;

  { nothing dipped under the threshold, so fall back to the best dip there
    was - but only if it's convincing. Noise, a drum hit and a chord all fail
    here, which is exactly right: a tuner should say nothing rather than
    invent a note. }
  if (BestTau < TunerMinLag) or ((not Found) and (BestCmnd > TunerMaxCmnd)) then
  begin
    Inc(AState.TunerQuietHops);
    if AState.TunerQuietHops >= TunerHopsToClear then
      AState.TunerFreqHz := 0;
    Exit;
  end;

  { parabolic interpolation through the three points around the dip - without
    it the reading quantises to whole analysis samples, which at 8.8kHz is
    tens of cents wide up in the treble and would make the dots meaningless }
  Period := BestTau;
  if (BestTau > 1) and (BestTau < HalfW) then
  begin
    dPrev := AState.TunerDiff[BestTau - 1];
    dHere := AState.TunerDiff[BestTau];
    dNext := AState.TunerDiff[BestTau + 1];
    Denom := dPrev - 2 * dHere + dNext;
    if Denom <> 0 then
    begin
      Shift := 0.5 * (dPrev - dNext) / Denom;
      if Shift > 0.5 then Shift := 0.5;
      if Shift < -0.5 then Shift := -0.5;
      Period := Period + Shift;
    end;
  end;
  if Period <= 0 then
    Exit;

  Freq := AAnalysisRate / Period;
  if (Freq < TunerMinHz) or (Freq > TunerMaxHz) then
  begin
    Inc(AState.TunerQuietHops);
    if AState.TunerQuietHops >= TunerHopsToClear then
      AState.TunerFreqHz := 0;
    Exit;
  end;

  { light smoothing, but only between readings that are already within about
    a tone of each other - a real note change has to land instantly, while
    the few-cent jitter of consecutive hops on one held note should not make
    the dots twitch }
  if AState.TunerFreqHz > 0 then
  begin
    Ratio := Freq / AState.TunerFreqHz;
    if (Ratio > 0.917) and (Ratio < 1.09) then
      Freq := AState.TunerFreqHz * 0.55 + Freq * 0.45;
  end;
  AState.TunerFreqHz := Freq;
  AState.TunerQuietHops := 0;
end;

function TunerReadoutHz(const AState: TEffectState): Single;
begin
  Result := AState.TunerFreqHz;
end;

function TunerNoteFromFreq(AFreqHz: Single; out AMidiNote: Integer;
  out ACents: Single): Boolean;
var
  MidiExact: Double;
begin
  AMidiNote := 0;
  ACents := 0;
  Result := False;
  if (AFreqHz < TunerMinHz) or (AFreqHz > TunerMaxHz) then
    Exit;
  MidiExact := 69 + 12 * Log2(AFreqHz / TunerA4Hz);
  AMidiNote := Round(MidiExact);
  if (AMidiNote < 0) or (AMidiNote > 127) then
    Exit;
  ACents := (MidiExact - AMidiNote) * 100;
  Result := True;
end;

function TunerDotCount(ACents: Single): Integer;
begin
  ACents := Abs(ACents);
  if ACents < TunerDot1Cents then
    Result := 0
  else if ACents < TunerDot2Cents then
    Result := 1
  else if ACents < TunerDot3Cents then
    Result := 2
  else
    Result := 3;
end;

{ Overdrive's waveshaper: a morph from tanh at Color 0 (soft knee - warm,
  compressing, tube-ish) to a hard clip at Color 1 (abrupt knee - buzzy,
  dense, transistor crunch). Both saturate to +/-1, so no Drive setting can
  ever push the wet path past full scale no matter what goes in. }
function OverdriveShape(AInput, AColor: Single): Single;
var
  Soft, Hard: Single;
begin
  Soft := Math.Tanh(AInput);
  if AInput > 1 then
    Hard := 1
  else if AInput < -1 then
    Hard := -1
  else
    Hard := AInput;
  Result := Soft * (1 - AColor) + Hard * AColor;
end;

{ Standard one-pole DC blocker. OverdriveAsymBias deliberately shifts the
  waveform off zero on its way into the shaper to generate even harmonics,
  and that offset has to come back off before this reaches the mix bus. }
function OverdriveDcBlock(var AX1, AY1: Single; AInput: Single): Single;
begin
  Result := AInput - AX1 + OverdriveDcBlockCoeff * AY1;
  AX1 := AInput;
  AY1 := Result;
end;

procedure ProcessEffect(var AState: TEffectState; const AEffect: TEffect;
  var L, R: Single; ASampleRate: Integer; ASidechainLevel: Single);
var
  b: Integer;
  Freq: Single;
  ThresholdLin, Peak, TargetGain, ReleaseCoeff, ReleaseMs: Single;
  ChorusBufLen: Integer;
  ModL, ModR, DelayMsL, DelayMsR, DepthFrac, WetL, WetR: Double;
  c, s: Integer;
  RvRoomScale, RvFeedback, RvDamping, RvDamp1, RvDamp2: Single;
  RvDryL, RvDryR, RvInputMono, RvWetL, RvWetR, RvMixFrac: Single;
  FlangerBufLen: Integer;
  FeedbackFrac, MixFrac: Single;
  PhFreqL, PhFreqR, PhFeedbackFrac, PhInL, PhInR, PhOutL, PhOutR: Single;
  ScAttackMs, ScAttackCoeff, ScStrengthFrac: Single;
  ToneL, ToneR: Single;
  TunerMono: Single;
  OdQ, OdColorFrac, OdBias, OdDryL, OdDryR, OdL, OdR: Single;
begin
  case AEffect.Kind of
    ekLowpass:
      begin
        Freq := ClampFreq(AEffect.LowpassFreqHz, ASampleRate);
        if (ASampleRate <> AState.LastSampleRate) or
          (Freq <> AState.LastLowpassFreq) then
        begin
          ComputeLowpassBiquad(Freq, ASampleRate, LowpassQ, AState.LowpassCoeffs);
          AState.LastLowpassFreq := Freq;
        end;
        L := ProcessBiquad(AState.Channels[0].LowpassBq, AState.LowpassCoeffs, L);
        R := ProcessBiquad(AState.Channels[1].LowpassBq, AState.LowpassCoeffs, R);
        AState.LastSampleRate := ASampleRate;
      end;
    ekHighpass:
      begin
        Freq := ClampFreq(AEffect.HighpassFreqHz, ASampleRate);
        if (ASampleRate <> AState.LastSampleRate) or
          (Freq <> AState.LastHighpassFreq) then
        begin
          ComputeHighpassBiquad(Freq, ASampleRate, LowpassQ, AState.HighpassCoeffs);
          AState.LastHighpassFreq := Freq;
        end;
        L := ProcessBiquad(AState.Channels[0].HighpassBq, AState.HighpassCoeffs, L);
        R := ProcessBiquad(AState.Channels[1].HighpassBq, AState.HighpassCoeffs, R);
        AState.LastSampleRate := ASampleRate;
      end;
    ekBandpass:
      begin
        Freq := ClampFreq(AEffect.BandpassFreqHz, ASampleRate);
        if (ASampleRate <> AState.LastSampleRate) or
          (Freq <> AState.LastBandpassFreq) or
          (AEffect.BandpassQ <> AState.LastBandpassQ) then
        begin
          ComputeBandpassBiquad(Freq, ASampleRate, AEffect.BandpassQ, AState.BandpassCoeffs);
          AState.LastBandpassFreq := Freq;
          AState.LastBandpassQ := AEffect.BandpassQ;
        end;
        L := ProcessBiquad(AState.Channels[0].BandpassBq, AState.BandpassCoeffs, L);
        R := ProcessBiquad(AState.Channels[1].BandpassBq, AState.BandpassCoeffs, R);
        AState.LastSampleRate := ASampleRate;
      end;
    ekEQ4:
      begin
        for b := 0 to MaxEQBands - 1 do
        begin
          Freq := ClampFreq(AEffect.EQFreqHz[b], ASampleRate);
          if (ASampleRate <> AState.LastSampleRate) or
            (Freq <> AState.LastEQFreq[b]) or
            (AEffect.EQGainDb[b] <> AState.LastEQGain[b]) then
          begin
            ComputePeakingBiquad(Freq, ASampleRate, EQQ, AEffect.EQGainDb[b],
              AState.EQCoeffs[b]);
            AState.LastEQFreq[b] := Freq;
            AState.LastEQGain[b] := AEffect.EQGainDb[b];
          end;
          L := ProcessBiquad(AState.Channels[0].EQBq[b], AState.EQCoeffs[b], L);
          R := ProcessBiquad(AState.Channels[1].EQBq[b], AState.EQCoeffs[b], R);
        end;
        AState.LastSampleRate := ASampleRate;
      end;
    ekLimiter:
      begin
        { zero-lookahead peak limiter, gain reduction linked across L/R so
          the stereo image never shifts. Attack is instant (the target gain
          for THIS sample is computed from THIS sample's peak and applied to
          it immediately), which is what actually guarantees the ceiling is
          never exceeded; release is a smooth one-pole climb back to unity
          to avoid audible pumping. }
        if AEffect.LimiterThresholdDb <> AState.LastLimiterThresholdDb then
        begin
          AState.LimiterThresholdLin := Power(10, AEffect.LimiterThresholdDb / 20);
          AState.LastLimiterThresholdDb := AEffect.LimiterThresholdDb;
        end;
        ThresholdLin := AState.LimiterThresholdLin;

        Peak := Abs(L);
        if Abs(R) > Peak then
          Peak := Abs(R);

        if Peak > ThresholdLin then
          TargetGain := ThresholdLin / Peak
        else
          TargetGain := 1.0;

        if TargetGain < AState.LimiterGain then
          AState.LimiterGain := TargetGain
        else
        begin
          ReleaseMs := AEffect.LimiterReleaseMs;
          if ReleaseMs < 1 then
            ReleaseMs := 1;
          { ASampleRate isn't part of this check, unlike Lowpass/EQ4's above -
            it's AudioEngine.ProjectSampleRate, a compile-time constant that
            never actually varies within a run (both the realtime and
            offline-render callers pass the same value every single call),
            so checking it here would only ever defeat this cache, never
            protect anything real }
          if ReleaseMs <> AState.LastLimiterReleaseMs then
          begin
            AState.LimiterReleaseCoeff := Exp(-1 / (0.001 * ReleaseMs * ASampleRate));
            AState.LastLimiterReleaseMs := ReleaseMs;
          end;
          ReleaseCoeff := AState.LimiterReleaseCoeff;
          AState.LimiterGain := TargetGain + (AState.LimiterGain - TargetGain) * ReleaseCoeff;
        end;

        L := L * AState.LimiterGain;
        R := R * AState.LimiterGain;
      end;
    ekChorus:
      begin
        if AState.ChorusBufL = nil then
        begin
          ChorusBufLen := Round(ASampleRate * ChorusMaxDelayMs / 1000) + 1;
          SetLength(AState.ChorusBufL, ChorusBufLen);
          SetLength(AState.ChorusBufR, ChorusBufLen);
          AState.ChorusWritePos := 0;
          AState.ChorusPhase := 0;
        end;
        ChorusBufLen := Length(AState.ChorusBufL);

        AState.ChorusBufL[AState.ChorusWritePos] := L;
        AState.ChorusBufR[AState.ChorusWritePos] := R;

        DepthFrac := AEffect.ChorusDepthPercent / 100;
        { L and R LFOs 90 degrees apart - this is what gives the classic
          "wide" stereo swirl rather than a single wobbling voice }
        ModL := Sin(2 * Pi * AState.ChorusPhase);
        ModR := Sin(2 * Pi * AState.ChorusPhase + Pi / 2);
        DelayMsL := ChorusCenterDelayMs + ModL * ChorusModRangeMs * DepthFrac;
        DelayMsR := ChorusCenterDelayMs + ModR * ChorusModRangeMs * DepthFrac;

        WetL := ReadDelayInterp(AState.ChorusBufL, ChorusBufLen,
          AState.ChorusWritePos - DelayMsL * ASampleRate / 1000);
        WetR := ReadDelayInterp(AState.ChorusBufR, ChorusBufLen,
          AState.ChorusWritePos - DelayMsR * ASampleRate / 1000);

        { fixed 50/50 dry/wet mix, no separate mix knob - matches the old,
          simpler chorus devices this is modeled on }
        L := 0.5 * L + 0.5 * WetL;
        R := 0.5 * R + 0.5 * WetR;

        { the write head only ever advances one frame, so it can overshoot by
          at most one - a compare beats an idiv per frame here }
        Inc(AState.ChorusWritePos);
        if AState.ChorusWritePos >= ChorusBufLen then
          AState.ChorusWritePos := 0;
        AState.ChorusPhase := AState.ChorusPhase + AEffect.ChorusRateHz / ASampleRate;
        if AState.ChorusPhase >= 1 then
          AState.ChorusPhase := AState.ChorusPhase - 1;
      end;
    ekReverb:
      begin
        if (AState.ReverbLastPreset <> AEffect.ReverbPreset) or
          (AState.ReverbLastSampleRate <> ASampleRate) then
        begin
          SetupReverb(AState, AEffect.ReverbPreset, ASampleRate);
          AState.ReverbLastPreset := AEffect.ReverbPreset;
          AState.ReverbLastSampleRate := ASampleRate;

          { the tank coefficients come from the preset and nothing else, so
            they belong here with the tank itself rather than being re-derived
            per sample - this was running the whole case statement in
            ReverbPresetParams, plus a subtract, 48000 times a second to
            arrive at three constants. Same caching the biquad coefficients
            and the limiter/sidechain thresholds already use. }
          ReverbPresetParams(AEffect.ReverbPreset, RvRoomScale, RvFeedback,
            RvDamping);
          AState.ReverbFeedback := RvFeedback;
          AState.ReverbDamp1 := RvDamping;
          AState.ReverbDamp2 := 1 - RvDamping;
        end;

        RvFeedback := AState.ReverbFeedback;
        RvDamp1 := AState.ReverbDamp1;
        RvDamp2 := AState.ReverbDamp2;

        RvDryL := L;
        RvDryR := R;
        RvInputMono := (L + R) * 0.5;

        RvWetL := 0;
        RvWetR := 0;
        for c := 0 to ReverbCombCount - 1 do
        begin
          RvWetL := RvWetL + ProcessComb(AState.ReverbCombL[c], RvInputMono,
            RvFeedback, RvDamp1, RvDamp2);
          RvWetR := RvWetR + ProcessComb(AState.ReverbCombR[c], RvInputMono,
            RvFeedback, RvDamp1, RvDamp2);
        end;
        RvWetL := RvWetL / ReverbCombCount;
        RvWetR := RvWetR / ReverbCombCount;

        for c := 0 to ReverbAllpassCount - 1 do
        begin
          RvWetL := ProcessAllpass(AState.ReverbAllpassL[c], RvWetL, ReverbAllpassFeedback);
          RvWetR := ProcessAllpass(AState.ReverbAllpassR[c], RvWetR, ReverbAllpassFeedback);
        end;

        { cached rather than folded into a multiply by 0.01: 100 is exactly
          representable and 0.01 is not, so "/ 100" and "* 0.01" are genuinely
          different numbers. The compare is bit-identical and still replaces a
          divide per sample with a divide per slider move. }
        if AState.LastReverbMixPercent <> AEffect.ReverbMixPercent then
        begin
          AState.ReverbMixFrac := AEffect.ReverbMixPercent / 100;
          AState.LastReverbMixPercent := AEffect.ReverbMixPercent;
        end;
        RvMixFrac := AState.ReverbMixFrac;
        L := RvDryL * (1 - RvMixFrac) + RvWetL * RvMixFrac;
        R := RvDryR * (1 - RvMixFrac) + RvWetR * RvMixFrac;
      end;
    ekFlanger:
      begin
        if AState.FlangerBufL = nil then
        begin
          FlangerBufLen := Round(ASampleRate * FlangerMaxDelayMs / 1000) + 1;
          SetLength(AState.FlangerBufL, FlangerBufLen);
          SetLength(AState.FlangerBufR, FlangerBufLen);
          AState.FlangerWritePos := 0;
          AState.FlangerPhase := 0;
        end;
        FlangerBufLen := Length(AState.FlangerBufL);

        DepthFrac := AEffect.FlangerDepthPercent / 100;
        ModL := Sin(2 * Pi * AState.FlangerPhase);
        ModR := Sin(2 * Pi * AState.FlangerPhase + Pi / 2);
        DelayMsL := FlangerCenterDelayMs + ModL * FlangerModRangeMs * DepthFrac;
        DelayMsR := FlangerCenterDelayMs + ModR * FlangerModRangeMs * DepthFrac;

        WetL := ReadDelayInterp(AState.FlangerBufL, FlangerBufLen,
          AState.FlangerWritePos - DelayMsL * ASampleRate / 1000);
        WetR := ReadDelayInterp(AState.FlangerBufR, FlangerBufLen,
          AState.FlangerWritePos - DelayMsR * ASampleRate / 1000);

        { feedback around the delay line itself (not just the output mix) is
          what makes a flanger's sweep resonant/metallic rather than sounding
          like a short chorus - clamp well under 1.0 so it can't run away }
        FeedbackFrac := AEffect.FlangerFeedbackPercent / 100;
        if FeedbackFrac > 0.95 then FeedbackFrac := 0.95;
        if FeedbackFrac < 0 then FeedbackFrac := 0;
        AState.FlangerBufL[AState.FlangerWritePos] := L + WetL * FeedbackFrac;
        AState.FlangerBufR[AState.FlangerWritePos] := R + WetR * FeedbackFrac;

        MixFrac := AEffect.FlangerMixPercent / 100;
        L := L * (1 - MixFrac) + WetL * MixFrac;
        R := R * (1 - MixFrac) + WetR * MixFrac;

        { see the chorus write head above - same one-frame advance }
        Inc(AState.FlangerWritePos);
        if AState.FlangerWritePos >= FlangerBufLen then
          AState.FlangerWritePos := 0;
        AState.FlangerPhase := AState.FlangerPhase + AEffect.FlangerRateHz / ASampleRate;
        if AState.FlangerPhase >= 1 then
          AState.FlangerPhase := AState.FlangerPhase - 1;
      end;
    ekPhaser:
      begin
        DepthFrac := AEffect.PhaserDepthPercent / 100;
        ModL := Sin(2 * Pi * AState.PhaserPhase);
        ModR := Sin(2 * Pi * AState.PhaserPhase + Pi / 2);
        { sweep range narrows around the min/max midpoint as Depth drops,
          rather than shifting the whole range up or down }
        PhFreqL := (PhaserMinFreqHz + PhaserMaxFreqHz) / 2 +
          ModL * ((PhaserMaxFreqHz - PhaserMinFreqHz) / 2) * DepthFrac;
        PhFreqR := (PhaserMinFreqHz + PhaserMaxFreqHz) / 2 +
          ModR * ((PhaserMaxFreqHz - PhaserMinFreqHz) / 2) * DepthFrac;

        PhFeedbackFrac := AEffect.PhaserFeedbackPercent / 100;
        if PhFeedbackFrac > 0.95 then PhFeedbackFrac := 0.95;
        if PhFeedbackFrac < 0 then PhFeedbackFrac := 0;

        PhInL := L + AState.PhaserFeedbackSample[0] * PhFeedbackFrac;
        PhInR := R + AState.PhaserFeedbackSample[1] * PhFeedbackFrac;

        PhOutL := PhInL;
        PhOutR := PhInR;
        for s := 0 to PhaserStageCount - 1 do
        begin
          PhOutL := ProcessAllpassFirstOrder(AState.PhaserZ1x[0, s], AState.PhaserZ1y[0, s],
            PhOutL, PhFreqL, ASampleRate);
          PhOutR := ProcessAllpassFirstOrder(AState.PhaserZ1x[1, s], AState.PhaserZ1y[1, s],
            PhOutR, PhFreqR, ASampleRate);
        end;

        AState.PhaserFeedbackSample[0] := PhOutL;
        AState.PhaserFeedbackSample[1] := PhOutR;

        MixFrac := AEffect.PhaserMixPercent / 100;
        L := L * (1 - MixFrac) + PhOutL * MixFrac;
        R := R * (1 - MixFrac) + PhOutR * MixFrac;

        AState.PhaserPhase := AState.PhaserPhase + AEffect.PhaserRateHz / ASampleRate;
        if AState.PhaserPhase >= 1 then
          AState.PhaserPhase := AState.PhaserPhase - 1;
      end;
    ekSidechain:
      begin
        { classic ducker: an envelope follower on another track's level,
          gating this track's gain down whenever that source crosses
          Threshold - mainly for keying a bass/pad track off a kick track so
          it visibly "breathes" with it. Attack/Release smoothing (not an
          instant snap like the Limiter above) is what makes the duck read
          as musical pumping rather than a click. }
        if AEffect.SidechainThresholdDb <> AState.LastSidechainThresholdDb then
        begin
          AState.SidechainThresholdLin := Power(10, AEffect.SidechainThresholdDb / 20);
          AState.LastSidechainThresholdDb := AEffect.SidechainThresholdDb;
        end;
        ThresholdLin := AState.SidechainThresholdLin;

        ScStrengthFrac := AEffect.SidechainStrengthPercent / 100;
        if ScStrengthFrac > 1 then ScStrengthFrac := 1;
        if ScStrengthFrac < 0 then ScStrengthFrac := 0;

        if ASidechainLevel > ThresholdLin then
          TargetGain := 1 - ScStrengthFrac
        else
          TargetGain := 1.0;

        if TargetGain < AState.SidechainGain then
        begin
          ScAttackMs := AEffect.SidechainAttackMs;
          if ScAttackMs < 1 then ScAttackMs := 1;
          if ScAttackMs <> AState.LastSidechainAttackMs then
          begin
            AState.SidechainAttackCoeff := Exp(-1 / (0.001 * ScAttackMs * ASampleRate));
            AState.LastSidechainAttackMs := ScAttackMs;
          end;
          ScAttackCoeff := AState.SidechainAttackCoeff;
          AState.SidechainGain := TargetGain + (AState.SidechainGain - TargetGain) * ScAttackCoeff;
        end
        else
        begin
          ReleaseMs := AEffect.SidechainReleaseMs;
          if ReleaseMs < 1 then ReleaseMs := 1;
          if ReleaseMs <> AState.LastSidechainReleaseMs then
          begin
            AState.SidechainReleaseCoeff := Exp(-1 / (0.001 * ReleaseMs * ASampleRate));
            AState.LastSidechainReleaseMs := ReleaseMs;
          end;
          ReleaseCoeff := AState.SidechainReleaseCoeff;
          AState.SidechainGain := TargetGain + (AState.SidechainGain - TargetGain) * ReleaseCoeff;
        end;

        L := L * AState.SidechainGain;
        R := R * AState.SidechainGain;
      end;
    ekDrowning:
      begin
        { tone stage: darkens the signal before it ever reaches the warble/
          tank below - an attenuated-highs signal decaying into a modulated
          wash is most of what reads as "submerged" rather than just
          "reverb with chorus on it" }
        Freq := ClampFreq(AEffect.DrowningToneHz, ASampleRate);
        if (ASampleRate <> AState.LastSampleRate) or (Freq <> AState.LastLowpassFreq) then
        begin
          ComputeLowpassBiquad(Freq, ASampleRate, LowpassQ, AState.LowpassCoeffs);
          AState.LastLowpassFreq := Freq;
        end;
        ToneL := ProcessBiquad(AState.Channels[0].LowpassBq, AState.LowpassCoeffs, L);
        ToneR := ProcessBiquad(AState.Channels[1].LowpassBq, AState.LowpassCoeffs, R);
        AState.LastSampleRate := ASampleRate;

        { warble stage: same modulated-delay recipe as Chorus, feeding 100%
          into the tank below - the overall dry/wet is controlled once, at
          the very end, not here }
        if AState.ChorusBufL = nil then
        begin
          ChorusBufLen := Round(ASampleRate * ChorusMaxDelayMs / 1000) + 1;
          SetLength(AState.ChorusBufL, ChorusBufLen);
          SetLength(AState.ChorusBufR, ChorusBufLen);
          AState.ChorusWritePos := 0;
          AState.ChorusPhase := 0;
        end;
        ChorusBufLen := Length(AState.ChorusBufL);
        AState.ChorusBufL[AState.ChorusWritePos] := ToneL;
        AState.ChorusBufR[AState.ChorusWritePos] := ToneR;

        DepthFrac := AEffect.DrowningWarbleDepthPercent / 100;
        ModL := Sin(2 * Pi * AState.ChorusPhase);
        ModR := Sin(2 * Pi * AState.ChorusPhase + Pi / 2);
        DelayMsL := ChorusCenterDelayMs + ModL * ChorusModRangeMs * DepthFrac;
        DelayMsR := ChorusCenterDelayMs + ModR * ChorusModRangeMs * DepthFrac;
        WetL := ReadDelayInterp(AState.ChorusBufL, ChorusBufLen,
          AState.ChorusWritePos - DelayMsL * ASampleRate / 1000);
        WetR := ReadDelayInterp(AState.ChorusBufR, ChorusBufLen,
          AState.ChorusWritePos - DelayMsR * ASampleRate / 1000);
        { the write head only ever advances one frame, so it can overshoot by
          at most one - a compare beats an idiv per frame here }
        Inc(AState.ChorusWritePos);
        if AState.ChorusWritePos >= ChorusBufLen then
          AState.ChorusWritePos := 0;
        AState.ChorusPhase := AState.ChorusPhase + AEffect.DrowningWarbleRateHz / ASampleRate;
        if AState.ChorusPhase >= 1 then
          AState.ChorusPhase := AState.ChorusPhase - 1;

        { blend some unmodulated tone back in under the warble - pure 100%
          warble reads as thin and watery; keeping some solid signal under
          it gives the tank something to actually decay from }
        WetL := 0.6 * ToneL + 0.4 * WetL;
        WetR := 0.6 * ToneR + 0.4 * WetR;

        { tank stage: same comb/allpass recipe as Basic Reverb, sized off
          the continuous Size slider instead of a fixed preset }
        RvRoomScale := 0.4 + (AEffect.DrowningSizePercent / 100) * 1.6;
        RvFeedback := 0.5 + (AEffect.DrowningDecayPercent / 100) * 0.45;
        RvDamping := 0.35;
        if (AState.DrowningLastSizePercent <> AEffect.DrowningSizePercent) or
          (AState.DrowningLastSampleRate <> ASampleRate) then
        begin
          SetupReverbTank(AState, RvRoomScale, ASampleRate);
          AState.DrowningLastSizePercent := AEffect.DrowningSizePercent;
          AState.DrowningLastSampleRate := ASampleRate;
        end;
        RvDamp1 := RvDamping;
        RvDamp2 := 1 - RvDamp1;
        RvInputMono := (WetL + WetR) * 0.5;

        RvWetL := 0;
        RvWetR := 0;
        for c := 0 to ReverbCombCount - 1 do
        begin
          RvWetL := RvWetL + ProcessComb(AState.ReverbCombL[c], RvInputMono,
            RvFeedback, RvDamp1, RvDamp2);
          RvWetR := RvWetR + ProcessComb(AState.ReverbCombR[c], RvInputMono,
            RvFeedback, RvDamp1, RvDamp2);
        end;
        RvWetL := RvWetL / ReverbCombCount;
        RvWetR := RvWetR / ReverbCombCount;

        for c := 0 to ReverbAllpassCount - 1 do
        begin
          RvWetL := ProcessAllpass(AState.ReverbAllpassL[c], RvWetL, ReverbAllpassFeedback);
          RvWetR := ProcessAllpass(AState.ReverbAllpassR[c], RvWetR, ReverbAllpassFeedback);
        end;

        MixFrac := AEffect.DrowningMixPercent / 100;
        L := L * (1 - MixFrac) + RvWetL * MixFrac;
        R := R * (1 - MixFrac) + RvWetR * MixFrac;
      end;
    ekTuner:
      begin
        { L and R are never written in this branch - the tuner is a pure tap.
          Everything below only feeds the analysis window. }
        if AState.TunerBuf = nil then
        begin
          SetLength(AState.TunerBuf, TunerWindowSamples);
          SetLength(AState.TunerDiff, TunerWindowSamples div 2 + 1);
        end;
        if AState.TunerLastSampleRate <> ASampleRate then
        begin
          AState.TunerDecimFactor := ASampleRate div TunerTargetRateHz;
          if AState.TunerDecimFactor < 1 then
            AState.TunerDecimFactor := 1;
          { anti-alias just under the decimated Nyquist before throwing
            samples away, otherwise everything above it folds back down into
            the search range and the detector chases ghosts }
          ComputeLowpassBiquad(0.45 * ASampleRate / AState.TunerDecimFactor,
            ASampleRate, LowpassQ, AState.LowpassCoeffs);
          AState.TunerLastSampleRate := ASampleRate;
          AState.TunerDecimPos := 0;
          AState.TunerDecimAccum := 0;
          AState.TunerFill := 0;
        end;

        TunerMono := ProcessBiquad(AState.Channels[0].LowpassBq,
          AState.LowpassCoeffs, (L + R) * 0.5);
        AState.TunerDecimAccum := AState.TunerDecimAccum + TunerMono;
        Inc(AState.TunerDecimPos);
        if AState.TunerDecimPos >= AState.TunerDecimFactor then
        begin
          { boxcar average across the decimation group on top of the biquad -
            a free extra octave of alias rejection, and it costs one divide
            per analysis sample rather than anything per frame }
          TunerMono := AState.TunerDecimAccum / AState.TunerDecimFactor;
          AState.TunerDecimAccum := 0;
          AState.TunerDecimPos := 0;

          AState.TunerBuf[AState.TunerFill] := TunerMono;
          Inc(AState.TunerFill);
          if AState.TunerFill >= TunerWindowSamples then
          begin
            TunerDetect(AState, ASampleRate / AState.TunerDecimFactor);
            { slide the window on by one hop, keeping the newest samples, so
              detection re-runs every TunerHopSamples instead of only on
              back-to-back non-overlapping windows }
            Move(AState.TunerBuf[TunerHopSamples], AState.TunerBuf[0],
              (TunerWindowSamples - TunerHopSamples) * SizeOf(Single));
            AState.TunerFill := TunerWindowSamples - TunerHopSamples;
          end;
        end;
      end;
    ekOverdrive:
      begin
        Freq := ClampFreq(AEffect.OverdriveFreqHz, ASampleRate);
        OdQ := AEffect.OverdriveQ;
        if OdQ < 0.1 then
          OdQ := 0.1;
        if (ASampleRate <> AState.LastSampleRate) or
          (Freq <> AState.LastOverdriveFreq) or (OdQ <> AState.LastOverdriveQ) then
        begin
          ComputePeakingBiquad(Freq, ASampleRate, OdQ, OverdrivePreEmphasisDb,
            AState.EQCoeffs[0]);
          ComputePeakingBiquad(Freq, ASampleRate, OdQ, -OverdrivePreEmphasisDb,
            AState.EQCoeffs[1]);
          AState.LastOverdriveFreq := Freq;
          AState.LastOverdriveQ := OdQ;
          AState.LastSampleRate := ASampleRate;
        end;
        if AEffect.OverdriveDrivePercent <> AState.LastOverdriveDrivePercent then
        begin
          AState.OverdriveDriveGain := Power(10,
            (AEffect.OverdriveDrivePercent / 100) * OverdriveMaxDriveDb / 20);
          AState.LastOverdriveDrivePercent := AEffect.OverdriveDrivePercent;
        end;

        OdColorFrac := AEffect.OverdriveColorPercent / 100;
        if OdColorFrac > 1 then OdColorFrac := 1;
        if OdColorFrac < 0 then OdColorFrac := 0;
        OdBias := OverdriveAsymBias * (1 - OdColorFrac);

        OdDryL := L;
        OdDryR := R;

        OdL := ProcessBiquad(AState.Channels[0].EQBq[0], AState.EQCoeffs[0], L);
        OdR := ProcessBiquad(AState.Channels[1].EQBq[0], AState.EQCoeffs[0], R);

        OdL := OverdriveShape(OdL * AState.OverdriveDriveGain + OdBias, OdColorFrac);
        OdR := OverdriveShape(OdR * AState.OverdriveDriveGain + OdBias, OdColorFrac);

        OdL := OverdriveDcBlock(AState.OverdriveDcX1[0], AState.OverdriveDcY1[0], OdL);
        OdR := OverdriveDcBlock(AState.OverdriveDcX1[1], AState.OverdriveDcY1[1], OdR);

        OdL := ProcessBiquad(AState.Channels[0].EQBq[1], AState.EQCoeffs[1], OdL);
        OdR := ProcessBiquad(AState.Channels[1].EQBq[1], AState.EQCoeffs[1], OdR);

        { no makeup gain: the shaper already pins the wet path's peaks near
          full scale however quiet the input was, which IS the "make it
          louder" behaviour - a compensating trim would just undo it }
        MixFrac := AEffect.OverdriveMixPercent / 100;
        L := OdDryL * (1 - MixFrac) + OdL * MixFrac;
        R := OdDryR * (1 - MixFrac) + OdR * MixFrac;
      end;
    ekQuadraverbReverb:
      QVReverbProcess(AState.QVReverb, L, R, ASampleRate,
        AEffect.QVReverbType, AEffect.QVReverbPredelayMs,
        AEffect.QVReverbPredelayMix, AEffect.QVReverbDecay,
        AEffect.QVReverbDiffusion, AEffect.QVReverbDensity,
        AEffect.QVReverbLowDecay, AEffect.QVReverbHighDecay,
        AEffect.QVReverbMixPercent);
    ekQuadraverbDelay:
      QVDelayProcess(AState.QVDelay, L, R, ASampleRate,
        AEffect.QVDelayType, AEffect.QVDelayTimeLMs, AEffect.QVDelayTimeRMs,
        AEffect.QVDelayFeedbackL, AEffect.QVDelayFeedbackR,
        AEffect.QVDelayMixPercent);
    { Worth knowing about this one's Mix: the whole point of the BBE process
      is that it moves the low and mid bands 2.5ms and 0.5ms behind the
      high band, so anything under 100% wet is summing a delayed low end
      against an undelayed one and will comb below ~200Hz. That is exactly
      what parallelling a real 422A against a dry feed does, so it is left
      alone rather than compensated for - but 100% is the setting the box
      was used at. }
    ekExciter422A:
      BBE422Process(AState.BBE, L, R, ASampleRate,
        AEffect.BBELoContourDb, AEffect.BBEDefinition,
        AEffect.BBEMixPercent);
    ekCompressor3630:
      A36Process(AState.C36, L, R, ASampleRate,
        AEffect.C36Response, AEffect.C36Knee, AEffect.C36ThresholdDbu,
        AEffect.C36Ratio, AEffect.C36AttackMs, AEffect.C36ReleaseMs,
        AEffect.C36OutputDb, AEffect.C36GateThresholdDbfs,
        AEffect.C36GateRateMs, AEffect.C36MixPercent);
    ekFuzzFZ2:
      FZ2Process(AState.FZ2, L, R, ASampleRate, AEffect.FZ2Mode,
        AEffect.FZ2Gain, AEffect.FZ2Treble, AEffect.FZ2Bass,
        AEffect.FZ2Level, AEffect.FZ2MixPercent);
  end;
end;

end.
