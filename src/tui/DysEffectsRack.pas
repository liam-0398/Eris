unit DysEffectsRack;

{ Effects rack widgets for the bottom pane (tui.md's "Bottom effects pane
  has no widgets" note, now addressed). Binds Free Vision controls straight
  to fields inside Project.TrackEffects[track][slot] - the same thing the
  LCL rack (EffectsRack.pas, src/ui) does via its own EffectPtr: there is no
  AudioEngineSetEffectParam and none is needed, AudioEngine's block loop
  reads Project.TrackEffects directly every block, so writing a field here
  is already "live". Range constants are read straight off Effects.pas and
  the individual pedal units (Quadraverb/BBE422A/Alesis3630/BossFZ2, all
  src/aengine, none of them isolated) rather than duplicated by hand; a
  handful with no importable constant (Q, EQ gain, chorus/flanger/phaser
  rate/depth/feedback, sidechain, drowning, overdrive) are hardcoded to
  match EffectsRack.pas's own sliders, since src/ui is excluded from
  Dysnomia's build by the Isolation rule and can't be imported. Nothing in
  src/aengine, src/project or src/ui is modified by this unit. }

{$mode objfpc}{$H+}

interface

uses
  Objects, Drivers, Views, Dialogs, Menus, App, DysWidgets,
  Effects, Project, Quadraverb, BBE422A, Alesis3630, BossFZ2, DysTrackPane,
  Math, AudioEngine, SampleTypes, Waveform;

const
  { cmAddEffectBase + Effects.ekXxx is the popup menu's command for adding
    that kind (ekXxx are 1..18, see Effects.pas) - can't collide with any
    other Dysnomia command constant (DysWidgets.pas's are all in the 2000s). }
  cmAddEffectBase = 3000;

  EffBoxWidth = 32;
  ParamSliderX = 12;
  ParamSliderW = 12;
  ParamValueX = 25;
  ParamValueW = 6;

  { Row count per Effects.ekXxx kind (1..18, matching TDysEffectBox.
    BuildParams below exactly) - needed up front so TDysEffectsContent.
    RebuildBoxes can size each box correctly before constructing it. }
  EffectRowCounts: array[1..18] of Integer =
    (1, 8, 2, 2, 2, 4, 4, 5, 6, 1, 2, 0, 5, 9, 6, 3, 10, 6);

type
  PEffect = ^Effects.TEffect;

  PDysParamBinding = ^TDysParamBinding;
  PDysParamSlider = ^TDysParamSlider;
  PDysParamEdit = ^TDysParamEdit;
  PDysEffectFrame = ^TDysEffectFrame;
  PDysEffectBox = ^TDysEffectBox;
  PDysEffectsContent = ^TDysEffectsContent;

  { One parameter's live binding: FloatPtr for a Single field, IntPtr for an
    Integer/enum one (Effects.TEffect is one flat record with a field per
    parameter per Kind, not a generic model, so there is nothing to bind to
    but a raw field address) - Scale converts the field's real units to the
    slider's integer Value, e.g. a 0.05..5.0 Hz rate uses Scale=100 so the
    bar's own range is 5..500, same *X100 convention EffectsRack.pas's
    sliders already use for the identical fields. }
  TDysParamBinding = record
    FloatPtr: PSingle;
    IntPtr: PInteger;
    Min, Max, Scale: Single;
    UnitStr: string[4];
    Slider: PDysParamSlider;
    Edit: PDysParamEdit;
  end;

  { A plain TScrollBar doubles as the slider: TScrollBar.HandleEvent already
    handles Left/Right (step), Ctrl+Left/Right (page) and Home/End (min/
    max) for a horizontal bar with no help from us - see views.pas, it
    isn't gated on focus, just State/sfVisible - so this override only
    needs to resync the field and the companion edit box after whatever
    inherited did (mouse drag/click or one of those keys). }
  TDysParamSlider = object(TScrollBar)
    Binding: PDysParamBinding;
    constructor Init(Bounds: TRect; ABinding: PDysParamBinding);
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  { Numeric readout / typed-entry field for the same parameter - Enter
    commits a typed value (Val, clamped to the param's own Min/Max), Esc
    reverts to whatever the field last held. }
  TDysParamEdit = object(TInputLine)
    Binding: PDysParamBinding;
    constructor Init(Bounds: TRect; ABinding: PDysParamBinding);
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  { Decorative border/title/close-glyph only - drawn separately from the
    Slider/Edit views so those can just draw their own cells on top of it,
    same "skip GetColor, use raw attribute bytes" approach DysTimeline
    already uses for its own hand-drawn grid. }
  TDysEffectFrame = object(TView)
    Box: PDysEffectBox;
    constructor Init(Bounds: TRect; ABox: PDysEffectBox);
    procedure Draw; virtual;
  end;

  { One effect instance's rack widget: bordered box, title = effect name, a
    '[x]' glyph at the top-right (mouse click, or Ctrl+X while any control
    inside has focus, removes it - Ctrl+X is a genuinely distinct byte,
    Drivers.kbCtrlX, same reasoning tui.md's Bindings section already gives
    for Ctrl+T/Ctrl+S). Up/Down cycles keyboard focus across this box's own
    Slider/Edit pairs, same SelectNext pattern TDysToolBar uses for its
    Tempo+four buttons - Tab stays reserved for pane-switching. }
  TDysEffectBox = object(TGroup)
    TrackIndex, EffectIndex, Kind: Integer;
    Title: string[20];
    ParamNames: array[0..23] of string[9];
    NextRow: Integer;
    Bindings: array[0..23] of PDysParamBinding;
    BindingCount: Integer;
    Frame: PDysEffectFrame;
    constructor Init(Bounds: TRect; ATrackIndex, AEffectIndex: Integer);
    destructor Done; virtual;
    procedure BuildParams(EffectPtr: PEffect);
    procedure AddParamF(const AName, AUnitStr: string; AMin, AMax, AScale: Single;
      AFieldPtr: PSingle);
    procedure AddParamI(const AName, AUnitStr: string; AMin, AMax: Integer;
      AFieldPtr: PInteger);
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  { The bottom pane's content: one row of per-effect boxes for whatever
    track DysTrackPane's cursor is currently on, rebuilt whenever that
    track, or its effect chain, changes (see RebuildBoxes and its two
    callers: this unit's own add/remove handling, and DysWidgets.
    TDysBottomPane.FocusPane on every Tab/Shift+Tab into this pane). Row 0
    stays the track-badge/hint line the old stub used to fill the whole
    pane with; rows below it belong entirely to the boxes. }
  TDysEffectsContent = object(TGroup)
    TrackIndex, EffectCount: Integer;
    PendingRemoveTrack, PendingRemoveIndex: Integer;
    constructor Init(Bounds: TRect);
    procedure RebuildBoxes;
    procedure RequestRemoval(ATrackIndex, AEffectIndex: Integer);
    procedure OpenAddEffectMenu(AGlobalPos: TPoint);
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  { The bottom pane's other content: a hand-rolled ASCII waveform (min/max
    peaks, same source Waveform.ComputeWaveformPeaks already provides -
    WaveformDraw.pas's own rendering is src/ui/LCL and unreachable here,
    see the Isolation rule, so this is a fresh raw-attribute renderer, same
    "skip GetColor, build a TDrawBuffer per row" convention DysTimeline's
    grid already uses) of whatever clip the timeline's 'k' key last marked
    (DysTimeline.TDysTimelineContent.MarkClipUnderCursor, via
    SetWaveformClipProc - DysWidgets.pas's own comment explains why that's
    a callback and not a direct call). Peaks are computed once per mark
    (SetClip), not per Draw - ComputeWaveformPeaks walks the whole clip
    span, and Draw can run far more often than the marked clip changes.

    Row 0 is the info header (unchanged); row 1 is now a time ruler (tick
    marks plus mm:ss labels, see DrawRuler); the wave itself starts at
    WaveTopRow. A left-drag over the wave rows (SelStartFrame/SelEndFrame,
    absolute source-domain frame positions - same domain as ClipOffset,
    ComputeWaveformPeaks' own input) marks a span to chop; Delete is caught
    by DysnomiaApp's cmEditDelete handler instead of a HandleEvent case
    here (Free Vision's menu-bar hotkey interception means the raw kbDel
    byte never reaches this or any focused subview - see that handler's own
    comment), which reads SelStartFrame/SelEndFrame off this view and calls
    DysWidgets.ChopWaveformSelectionProc - see that var's comment for why
    the actual clip surgery happens in DysTimeline.pas instead of here.
    During playback, PlayheadActive/PlayheadFrame (see UpdatePlayhead,
    polled from TDysnomiaApp.Idle the same way DysTimeline's own transport
    playhead is) track where AudioEngine's absolute playback position
    lands inside the MARKED clip - MarkedTrackIdx/MarkedClipIdx (set by
    SetClip's caller, DysTimeline.MarkClipUnderCursor) are what let this
    view re-resolve the clip's live Position/Offset/Length straight from
    Project.Tracks each poll, rather than caching a Position that a ripple
    chop elsewhere could move out from under it. }
  PDysWaveformContent = ^TDysWaveformContent;
  TDysWaveformContent = object(TView)
    SampleID: Integer; { -1 = nothing marked yet }
    ClipOffset, ClipLength: Int64;
    ClipGain, ClipDetune: Single;
    ClipWarpMode: Integer;
    Peaks: TWaveformPeaks;
    SelActive: Boolean;
    SelStartFrame, SelEndFrame: Int64; { absolute source-domain frames }
    { The paste/insertion point - a plain click (no drag) outside any
      existing selection sets this instead, so Ctrl+V has somewhere
      unambiguous to land. Mutually exclusive with SelActive: a real
      drag-selection clears this, and a plain click clears SelActive - see
      HandleEvent. Also absolute source-domain, same as SelStartFrame. }
    CursorActive: Boolean;
    CursorFrame: Int64;
    { Which Project.Tracks[MarkedTrackIdx].Clips[MarkedClipIdx] this is -
      see SetWaveformClipProc's own comment on why the playhead needs this
      instead of a cached Position. -1/-1 = nothing marked. }
    MarkedTrackIdx, MarkedClipIdx: Integer;
    PlayheadActive: Boolean;
    PlayheadFrame: Int64; { absolute source-domain frame, when PlayheadActive }
    constructor Init(Bounds: TRect);
    procedure SetClip(ASampleID: Integer; AOffset, ALength: Int64;
      AGain, ADetune: Single; AWarpMode, ATrack, AClipIdx: Integer);
    function ColToSourceFrame(ACol: Integer): Int64;
    function FrameToCol(AFrame: Int64): Integer;
    procedure DrawRuler(var B: TDrawBuffer; AAttr: Word);
    procedure UpdatePlayhead;
    procedure Draw; virtual;
    procedure HandleEvent(var Event: TEvent); virtual;
  end;

  { The bottom dock: hosts TDysEffectsContent and TDysWaveformContent,
    Ctrl+W (app-wide - see TDysnomiaApp.HandleEvent) toggling which one is
    actually shown/focusable, one hides while the other shows rather than
    both existing side by side - there's only the one dock's worth of
    screen space this pane ever had. Lives here rather than in DysWidgets.
    pas (which every other docked pane's type does) because
    TDysEffectsContent itself needs DysTrackPane (for SelectedTrackIndex/
    ActiveTrackPane) and DysTrackPane needs DysWidgets (for its own base
    class, TDysPane) - putting TDysBottomPane in DysWidgets too would close
    a DysWidgets -> DysEffectsRack -> DysTrackPane -> DysWidgets loop, which
    FPC's unit system flatly refuses ("Circular unit reference"). This unit
    already needs DysWidgets (for TDysPane, TDysBottomPane's own ancestor)
    and DysTrackPane, so it's the one free spot for it. }
  PDysBottomPane = ^TDysBottomPane;
  TDysBottomPane = object(TDysPane)
    Content: PDysEffectsContent;
    WaveformView: PDysWaveformContent;
    ShowingWaveform: Boolean;
    constructor InitPane(Bounds: TRect);
    { Rebuilds the rack from whatever track DysTrackPane's cursor is on NOW,
      every time Tab/Shift+Tab brings focus into this pane - see
      TDysEffectsContent.RebuildBoxes's own comment on why this and
      HandleEvent's per-event check are the two places that trigger a
      rebuild, instead of a track-changed broadcast this app has no
      equivalent of yet. }
    procedure FocusPane; virtual;
    { Ctrl+W. Public so TDysnomiaApp.HandleEvent (DysnomiaApp.pas, which
      already `uses DysEffectsRack` directly - no callback needed for this
      direction) can call it straight from its own app-wide key check. }
    procedure ToggleContent;
  end;

function DysEffectKindName(AKind: Integer): string;

{ Ctrl+C/Ctrl+V/Ctrl+D on the waveform pane's own drag-selection - see
  tui.md's Bindings. Like Delete (DysnomiaApp.pas's cmEditDelete case),
  Ctrl+C/V/D are Free Vision menu-bar hotkeys (see InitMenuBar) that
  TMenuBar intercepts in phPreProcess BEFORE any focused subview - here,
  TDysWaveformContent - ever sees the raw key, so there is no HandleEvent
  case for them in this unit; DysnomiaApp's own cmEditCopy/cmEditPaste/
  cmEditDuplicate route here (or to DysTimeline's clip-level equivalents)
  depending on whether the waveform pane is showing AND has a selection,
  same precedence Delete already established.

  Copy needs no Project mutation - just remembers which sample/span was
  selected - so it lives here, entirely local to this unit, unlike
  Duplicate/Paste (DysTimeline.DysDuplicateWaveformSelection/
  DysPasteWaveformClipboard) which have to splice the marked clip and so
  belong where the rest of that clip-surgery machinery
  (DysChopMarkedClipRegion) already lives. Returns False (does nothing) if
  there's no active selection to copy. }
function DysCopyWaveformSelection: Boolean;

{ The other half of DysCopyWaveformSelection - DysTimeline.
  DysPasteWaveformClipboard reads the clipboard through this rather than
  reaching into this unit's own private vars directly. Returns False (and
  leaves the out params untouched) if nothing has been copied yet. }
function DysGetWaveClipboard(out ASampleID: Integer;
  out AOffset, ALength: Int64): Boolean;

{ Made public for DysTrackerApp's own effects pane - a second legitimate
  caller now exists (the Tracker's "add effect" popup wants the exact same
  categorized menu the DAW's own effects rack shows, see tui.md's Tracker
  section), so this needs to be reachable outside this unit. }
function BuildAddEffectMenu: PMenu;

{ Set once, by TDysEffectsContent.Init - there is exactly one effects
  content view in this single-window app, same "global points at the one
  instance" pattern ActiveTrackPane/ActiveToolBar already use. TDysEffectBox
  reaches through this to request its own removal (see RequestRemoval's own
  comment for why that can't just Dispose(Self) directly). }
var
  ActiveEffectsContent: PDysEffectsContent = nil;

{ Set once, by TDysBottomPane.InitPane - there is exactly one bottom dock
  in this single-window app. TDysnomiaApp.HandleEvent's Ctrl+W handling
  reaches through this to call ToggleContent. }
var
  ActiveBottomPane: PDysBottomPane = nil;

implementation

{ Deliberately not SysUtils - see DysWidgets.pas's own top-of-implementation
  note: SysUtils redeclares Objects.NewStr, and this unit's TInputLine field
  assignments rely on the plain ShortString-typed Objects.NewStr staying in
  scope unshadowed. Str()/Val() (System, no unit needed) cover every number
  <-> string conversion this file needs. }

{ Mirrors MainForm.TriggerKeyboardNote (src/ui), targeting DysTrackPane's
  SelectedTrackIndex rather than ArrangementView.KeyboardTrack - moved here
  unchanged from DysWidgets.pas. }
procedure TriggerDysKeyboardNote(ASemitoneOffset: Integer);
var
  Track, SampleID, TotalOffset: Integer;
  Sample: TSample;
  StartFrame, EndFrame, TrimmedCount: Int64;
begin
  Track := SelectedTrackIndex;
  SampleID := Project.TrackInstrument[Track];
  if SampleID < 0 then
    Exit;
  Sample := Project.SamplePool[SampleID];
  StartFrame := Project.TrackInstrumentStart[Track];
  EndFrame := Project.TrackInstrumentEnd[Track];
  if StartFrame < 0 then
    StartFrame := 0;
  if (EndFrame <= 0) or (EndFrame > Sample.FrameCount) then
    EndFrame := Sample.FrameCount;
  TrimmedCount := EndFrame - StartFrame;
  if TrimmedCount <= 0 then
    Exit;
  TotalOffset := ASemitoneOffset + Project.TrackOctave[Track] * 12;
  AudioEngineTriggerNote(Track, @Sample.Data[StartFrame * Sample.Channels],
    TrimmedCount, Sample.Channels, TotalOffset,
    Power(10, Project.TrackInstrumentGainDb[Track] / 20));
end;

{ Ctrl+Z/Ctrl+X on the transport pane (see TDysToolBar.HandleEvent,
  DysWidgets.pas) - -4..4 matches MainForm.SamplerOctaveDownClick/
  UpClick's own clamp (src/ui), the only other place TrackOctave is
  ever adjusted. }
procedure AdjustDysKeyboardOctave(ADelta: Integer);
var
  Track: Integer;
begin
  Track := SelectedTrackIndex;
  if ADelta < 0 then
  begin
    if Project.TrackOctave[Track] > -4 then
      Dec(Project.TrackOctave[Track]);
  end
  else
  begin
    if Project.TrackOctave[Track] < 4 then
      Inc(Project.TrackOctave[Track]);
  end;
end;

{ The A/I/S-plus-number badge at the very left of row 0 - moved here
  unchanged from DysWidgets.pas (see DysTimeline.TrackTypeChar for the
  canonical version this duplicates; kept private/display-only here too). }
function DysBottomTrackLabel(ATrack: Integer): string;
var
  NumStr: string;
begin
  if (ATrack < 0) or (ATrack > High(Project.TrackIsSampler)) then
  begin
    Result := 'A';
    Exit;
  end;
  if Project.TrackIsSampler[ATrack] then
    Result := 'S'
  else if Project.TrackInstrument[ATrack] >= 0 then
    Result := 'I'
  else
    Result := 'A';
  Str(ATrack + 1, NumStr);
  Result := Result + NumStr;
end;

function DysEffectKindName(AKind: Integer): string;
begin
  case AKind of
    Effects.ekLowpass: Result := 'Lowpass';
    Effects.ekHighpass: Result := 'Highpass';
    Effects.ekBandpass: Result := 'Bandpass';
    Effects.ekEQ4: Result := '4-Band EQ';
    Effects.ekLimiter: Result := 'Limiter';
    Effects.ekChorus: Result := 'Chorus';
    Effects.ekReverb: Result := 'Reverb';
    Effects.ekFlanger: Result := 'Flanger';
    Effects.ekPhaser: Result := 'Phaser';
    Effects.ekSidechain: Result := 'Sidechain';
    Effects.ekDrowning: Result := 'Drowning';
    Effects.ekTuner: Result := 'Tuner';
    Effects.ekOverdrive: Result := 'Overdrive';
    Effects.ekQuadraverbReverb: Result := 'QV Reverb';
    Effects.ekQuadraverbDelay: Result := 'QV Delay';
    Effects.ekExciter422A: Result := 'Exciter 422A';
    Effects.ekCompressor3630: Result := 'Comp 3630';
    Effects.ekFuzzFZ2: Result := 'Fuzz FZ-2';
  else
    Result := 'Effect';
  end;
end;

{ See the interface declarations' own comments. -1/0/0 = nothing copied. }
var
  WaveClipboardSampleID: Integer = -1;
  WaveClipboardOffset: Int64 = 0;
  WaveClipboardLength: Int64 = 0;

function DysCopyWaveformSelection: Boolean;
begin
  Result := False;
  if (ActiveBottomPane = nil) or (ActiveBottomPane^.WaveformView = nil) then
    Exit;
  with ActiveBottomPane^.WaveformView^ do
  begin
    if (not SelActive) or (SampleID < 0) then
      Exit;
    WaveClipboardSampleID := SampleID;
    WaveClipboardOffset := SelStartFrame;
    WaveClipboardLength := SelEndFrame - SelStartFrame;
  end;
  Result := True;
end;

function DysGetWaveClipboard(out ASampleID: Integer;
  out AOffset, ALength: Int64): Boolean;
begin
  Result := (WaveClipboardSampleID >= 0) and (WaveClipboardLength > 0);
  if Result then
  begin
    ASampleID := WaveClipboardSampleID;
    AOffset := WaveClipboardOffset;
    ALength := WaveClipboardLength;
  end;
end;

function DysWarpModeName(AMode: Integer): string;
begin
  case AMode of
    SampleTypes.WarpModeBeats: Result := 'Beats';
    SampleTypes.WarpModeRePitch: Result := 'RePitch';
    SampleTypes.WarpModeTones: Result := 'Tones';
    SampleTypes.WarpModeAudio: Result := 'Audio';
  else
    Result := '?';
  end;
end;

{ TDysWaveformContent }

const
  { Row layout - see the type's own comment. }
  WaveTopRow = 2;
  { Reverse-video byte for the drag-selection overlay: light-grey bg,
    black fg, no blink - fvdoc.md's own "Palette cascade" note on why a
    hand-picked background nibble needs bit 7 checked explicitly ($70, not
    $F0). Skips GetColor entirely, same "hand-rolled view, raw attribute
    bytes" convention as DysTimeline's grid (see fvdoc.md). }
  WaveSelectionAttr = $70;
  { Red bg, bright white fg - same byte DysTimeline.PlayheadAttr already
    uses for its own transport playhead, kept identical so both panes read
    as "the same concept" rather than two different conventions. }
  WavePlayheadAttr = $4F;
  WavePlayheadChar = '|';
  { A faint marker, not the bright '|' ruler tick a real playhead/selection
    gets - see DysWaveGridStepFrames/DrawGridCols below. Dark grey on black,
    same byte as DysTimeline.ClipStartAttr, so both read as "a quiet
    structural line" rather than anything carrying its own meaning. Drawn
    only where the waveform itself is otherwise blank (silence) - see
    Draw's own row loop - so it never competes with the actual signal. }
  WaveGridAttr = $08;
  WaveGridChar = ':';
  { The "you are here" paste point - see CursorActive/CursorFrame. Bright
    cyan so it's unmistakably a DIFFERENT thing from the selection (grey
    reverse-video), the playhead (red) and the grid (dark grey). }
  WaveCursorAttr = $0B;
  WaveCursorChar = '^';

{ Same grid the toolbar's interval button drives for the timeline's own
  Left/Right nudge (DysTimeline.TDysTimelineContent.GridStepFrames) -
  duplicated here rather than exported from DysTimeline, since DysTimeline
  already `uses DysEffectsRack` (for the waveform-selection edit commands -
  see DysTimeline.DysCopyWaveformSelection and friends) and the reverse
  import would be circular. BarFrames' own formula (4/4 only, no time
  signature in Project.pas) is copied alongside it for the same reason. }
function DysWaveGridStepFrames: Int64;
var
  BarFrames: Int64;
begin
  if Project.TempoBPM <= 0 then
  begin
    Result := 0;
    Exit;
  end;
  BarFrames := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM) * 4;
  if ActiveToolBar = nil then
  begin
    Result := BarFrames div 4;
    Exit;
  end;
  case ActiveToolBar^.IntervalIdx of
    0: Result := BarFrames div 4;  { 1/4 }
    1: Result := BarFrames div 8;  { 1/8 }
    2: Result := BarFrames div 16; { 1/16 }
    3: Result := BarFrames;        { 1 bar }
  else
    Result := BarFrames div 4;
  end;
  if Result <= 0 then
    Result := 0;
end;

constructor TDysWaveformContent.Init(Bounds: TRect);
begin
  inherited Init(Bounds);
  GrowMode := 0;
  EventMask := EventMask or evKeyDown or evMouseDown;
  Options := Options or (ofSelectable + ofFirstClick);
  SampleID := -1;
  ClipOffset := 0;
  ClipLength := 0;
  ClipGain := 1.0;
  ClipDetune := 0;
  ClipWarpMode := SampleTypes.WarpModeBeats;
  SelActive := False;
  SelStartFrame := 0;
  SelEndFrame := 0;
  CursorActive := False;
  CursorFrame := 0;
  MarkedTrackIdx := -1;
  MarkedClipIdx := -1;
  PlayheadActive := False;
  PlayheadFrame := 0;
end;

{ Col is a column within the wave rows (0-based, same X the row-drawing
  loop in Draw uses); Result is the absolute source-domain frame position
  (ClipOffset's own domain) that column represents - the inverse of
  FrameToCol below. }
function TDysWaveformContent.ColToSourceFrame(ACol: Integer): Int64;
begin
  if (ClipLength <= 0) or (Size.X <= 0) then
    Exit(ClipOffset);
  if ACol < 0 then
    ACol := 0
  else if ACol > Size.X - 1 then
    ACol := Size.X - 1;
  Result := ClipOffset + (Int64(ACol) * ClipLength) div Size.X;
end;

{ Inverse of ColToSourceFrame, for turning SelStartFrame/SelEndFrame back
  into columns to paint the selection overlay in Draw. }
function TDysWaveformContent.FrameToCol(AFrame: Int64): Integer;
begin
  if ClipLength <= 0 then
    Exit(0);
  Result := ((AFrame - ClipOffset) * Size.X) div ClipLength;
  if Result < 0 then
    Result := 0
  else if Result > Size.X then
    Result := Size.X;
end;

{ Called from DysSetWaveformClip (this unit's own callback target for
  DysWidgets.SetWaveformClipProc - see that var's comment). Computes peaks
  once, over just the CLIP's own played span rather than the whole
  underlying sample file (a clip's Offset/Length can be a small slice of a
  much longer recording), by handing ComputeWaveformPeaks a windowed copy
  of the TSample header pointing at the clip's own first frame - the
  function only reads Data/FrameCount/Channels, never writes, so aliasing
  the original buffer this way is safe. }
procedure TDysWaveformContent.SetClip(ASampleID: Integer; AOffset, ALength: Int64;
  AGain, ADetune: Single; AWarpMode, ATrack, AClipIdx: Integer);
var
  Windowed: TSample;
  Avail: Int64;
begin
  SampleID := ASampleID;
  ClipOffset := AOffset;
  ClipLength := ALength;
  ClipGain := AGain;
  ClipDetune := ADetune;
  ClipWarpMode := AWarpMode;
  MarkedTrackIdx := ATrack;
  MarkedClipIdx := AClipIdx;
  PlayheadActive := False;
  { A previous selection's column mapping is only valid against the OLD
    ClipOffset/ClipLength/Size.X - clear it (and the paste cursor, same
    reasoning) rather than let a stale SelStartFrame/SelEndFrame/
    CursorFrame appear to point somewhere in a different clip's own data. }
  SelActive := False;
  CursorActive := False;

  Peaks.Mins := nil;
  Peaks.Maxs := nil;
  if (SampleID < 0) or (SampleID > High(Project.SamplePool)) then
  begin
    DrawView;
    Exit;
  end;

  Windowed := Project.SamplePool[SampleID];
  Avail := Windowed.FrameCount - AOffset;
  if Avail < 0 then
    Avail := 0;
  if ALength < Avail then
    Avail := ALength;
  if (Windowed.Data = nil) or (Avail <= 0) then
  begin
    DrawView;
    Exit;
  end;
  Windowed.Data := @Windowed.Data[AOffset * Windowed.Channels];
  Windowed.FrameCount := Avail;
  Peaks := ComputeWaveformPeaks(Windowed);
  DrawView;
end;

{ WaveRowGlyph moved to DysWidgets.pas (this unit already `uses DysWidgets`)
  so DysTimeline's inline per-clip waveform can share it too - see that
  unit for the CP437/half-block reasoning. }

{ Row 1's ruler: a tick ('|') at every DysWaveGridStepFrames boundary - the
  SAME grid the toolbar's interval button drives everywhere else (the
  timeline's own Left/Right nudge, GridStepFrames) - instead of the old
  fixed-every-10-columns mm:ss ruler. An mm:ss label (relative to the
  clip's OWN start, not the underlying sample file's) rides along at
  whichever of those ticks have room for one; at a fine grid (1/16 at a
  fast tempo, low zoom) most ticks are only a column or two apart, far too
  close for text, so labels are throttled to whenever enough columns have
  passed since the last one - every tick still gets its own '|', just not
  every tick gets a label. Falls back to the old fixed-StepCols behaviour
  when DysWaveGridStepFrames can't be computed (no tempo yet). }
procedure TDysWaveformContent.DrawRuler(var B: TDrawBuffer; AAttr: Word);
const
  StepCols = 10;
var
  Col, LastLabelCol, k, IterCap: Integer;
  Step: Int64;
  SecPerCol, Seconds: Double;
  Mins, Secs: Integer;
  MinStr, SecStr, Lbl: string;
begin
  MoveChar(B, ' ', AAttr, Size.X);
  if (ClipLength <= 0) or (Size.X <= 0) then
    Exit;
  SecPerCol := (ClipLength / AudioEngine.ProjectSampleRate) / Size.X;
  Step := DysWaveGridStepFrames;
  LastLabelCol := -1000;

  if Step <= 0 then
  begin
    Col := 0;
    while Col < Size.X do
    begin
      MoveChar(B[Col], '|', AAttr, 1);
      Seconds := Col * SecPerCol;
      Mins := Trunc(Seconds) div 60;
      Secs := Trunc(Seconds) mod 60;
      Str(Mins, MinStr);
      Str(Secs, SecStr);
      if Length(SecStr) < 2 then
        SecStr := '0' + SecStr;
      Lbl := MinStr + ':' + SecStr;
      if Col + 1 + Length(Lbl) <= Size.X then
        MoveStr(B[Col + 1], Lbl, AAttr);
      Inc(Col, Max(StepCols, 2 + Length(Lbl)));
    end;
    Exit;
  end;

  { A fine grid (1/16 at a fast tempo, zoomed out) can pack far more grid
    steps into ClipLength than there are columns to put them in - many k's
    then land on the same Col, and without a cap the loop would keep
    grinding through every one of them for no visible change. Size.X*4 is
    generous headroom (each column could still get a handful of steps
    before this kicks in) while keeping the worst case a small multiple of
    the terminal width instead of ClipLength/Step. }
  IterCap := Size.X * 4 + 16;
  k := 0;
  Col := FrameToCol(ClipOffset);
  while (Col < Size.X) and (k < IterCap) do
  begin
    MoveChar(B[Col], '|', AAttr, 1);
    Seconds := Col * SecPerCol;
    Mins := Trunc(Seconds) div 60;
    Secs := Trunc(Seconds) mod 60;
    Str(Mins, MinStr);
    Str(Secs, SecStr);
    if Length(SecStr) < 2 then
      SecStr := '0' + SecStr;
    Lbl := MinStr + ':' + SecStr;
    if (Col - LastLabelCol >= 2 + Length(Lbl)) and
       (Col + 1 + Length(Lbl) <= Size.X) then
    begin
      MoveStr(B[Col + 1], Lbl, AAttr);
      LastLabelCol := Col;
    end;
    Inc(k);
    Col := FrameToCol(ClipOffset + k * Step);
  end;
end;

{ Polled from TDysnomiaApp.Idle (DysnomiaApp.pas), same "no timer, poll on
  Idle instead" convention DysTimeline.TDysTimelineContent.UpdatePlayhead
  already established for the main timeline's own playhead.
  AudioEngineGetPosition is an ABSOLUTE timeline-domain frame (same domain
  as TClip.Position); re-fetching Project.Tracks[MarkedTrackIdx].
  Clips[MarkedClipIdx] fresh every poll (rather than trusting a cached
  Position) is what keeps this correct across a ripple chop that moved the
  clip since it was marked - see SetWaveformClipProc's own comment. Only
  an UNWARPED clip maps 1:1 timeline<->source, same restriction
  DysChopMarkedClipRegion's own guard already applies, so no attempt is
  made to show a playhead inside a time-warped clip. }
procedure TDysWaveformContent.UpdatePlayhead;
var
  NewActive: Boolean;
  NewFrame, Pos: Int64;
  Clip: TClip;
begin
  NewActive := False;
  NewFrame := 0;
  if (SampleID >= 0) and (MarkedTrackIdx >= 0) and
    (MarkedTrackIdx <= High(Project.Tracks)) and
    (MarkedClipIdx >= 0) and (MarkedClipIdx <= High(Project.Tracks[MarkedTrackIdx].Clips)) and
    AudioEngineIsPlaying then
  begin
    Clip := Project.Tracks[MarkedTrackIdx].Clips[MarkedClipIdx];
    if Length(Clip.WarpMarkers) < 2 then
    begin
      Pos := AudioEngineGetPosition;
      if (Pos >= Clip.Position) and (Pos < Clip.Position + Clip.Length) then
      begin
        NewActive := True;
        NewFrame := Clip.Offset + (Pos - Clip.Position);
      end;
    end;
  end;
  if (NewActive <> PlayheadActive) or (NewActive and (NewFrame <> PlayheadFrame)) then
  begin
    PlayheadActive := NewActive;
    PlayheadFrame := NewFrame;
    DrawView;
  end;
end;

procedure TDysWaveformContent.Draw;
var
  B: TDrawBuffer;
  Row, Col, WaveRows, BinCount, BinLo, BinHi, i, k, IterCap: Integer;
  MidRow, MinV, MaxV, Top, Bot: Double;
  Hdr, IdStr, GainStr, DetuneStr: string;
  C, SelC: Word;
  SelColStart, SelColEnd, PlayheadCol, CursorCol: Integer;
  GridStep: Int64;
  GridCols: array of Boolean;
begin
  C := GetColor(1);
  SelC := WaveSelectionAttr;
  WaveRows := Size.Y - WaveTopRow;
  if WaveRows < 1 then
    WaveRows := 1;

  MoveChar(B, ' ', C, Size.X);
  if SampleID < 0 then
    Hdr := ' waveform: (none marked - press k on a clip in the timeline) '
  else
  begin
    Str(SampleID, IdStr);
    Str(ClipGain:0:2, GainStr);
    Str(ClipDetune:0:1, DetuneStr);
    Hdr := ' waveform: sample ' + IdStr + '  gain ' + GainStr +
      '  detune ' + DetuneStr + 'st  warp ' + DysWarpModeName(ClipWarpMode) + ' ';
  end;
  MoveStr(B, Hdr, C);
  WriteLine(0, 0, Size.X, 1, B);

  DrawRuler(B, C);
  PlayheadCol := -1;
  if PlayheadActive and (ClipLength > 0) then
  begin
    PlayheadCol := FrameToCol(PlayheadFrame);
    if (PlayheadCol >= 0) and (PlayheadCol < Size.X) then
      MoveChar(B[PlayheadCol], WavePlayheadChar, WavePlayheadAttr, 1);
  end;
  WriteLine(0, 1, Size.X, 1, B);

  SelColStart := -1;
  SelColEnd := -1;
  if SelActive and (ClipLength > 0) then
  begin
    SelColStart := FrameToCol(SelStartFrame);
    SelColEnd := FrameToCol(SelEndFrame);
    if SelColEnd <= SelColStart then
      SelColEnd := SelColStart + 1;
  end;

  { Faint grid columns through the wave rows themselves, same
    DysWaveGridStepFrames the ruler ticks off - computed once here (not
    per-row) since it's the same set of columns on every row. Same
    IterCap safety as DrawRuler: a fine grid at low zoom can pack far more
    steps into ClipLength than there are columns for. }
  SetLength(GridCols, Size.X);
  for Col := 0 to Size.X - 1 do
    GridCols[Col] := False;
  GridStep := DysWaveGridStepFrames;
  if (GridStep > 0) and (ClipLength > 0) then
  begin
    IterCap := Size.X * 4 + 16;
    k := 0;
    Col := FrameToCol(ClipOffset);
    while (Col < Size.X) and (k < IterCap) do
    begin
      if (Col >= 0) and (Col < Size.X) then
        GridCols[Col] := True;
      Inc(k);
      Col := FrameToCol(ClipOffset + k * GridStep);
    end;
  end;

  BinCount := Length(Peaks.Maxs);
  MidRow := WaveRows / 2;
  for Row := 0 to WaveRows - 1 do
  begin
    MoveChar(B, ' ', C, Size.X);
    if BinCount > 0 then
      for Col := 0 to Size.X - 1 do
      begin
        { Group whichever peak bins land in this column (there are
          typically far more bins - up to MaxWaveformBins - than terminal
          columns) exactly like DrawSpan's own column mapping, min-of-mins/
          max-of-maxs across the group so a transient inside the group is
          never averaged away. }
        BinLo := (Col * BinCount) div Size.X;
        BinHi := ((Col + 1) * BinCount) div Size.X - 1;
        if BinHi < BinLo then
          BinHi := BinLo;
        if BinHi > BinCount - 1 then
          BinHi := BinCount - 1;
        MinV := Peaks.Mins[BinLo];
        MaxV := Peaks.Maxs[BinLo];
        for i := BinLo + 1 to BinHi do
        begin
          if Peaks.Mins[i] < MinV then
            MinV := Peaks.Mins[i];
          if Peaks.Maxs[i] > MaxV then
            MaxV := Peaks.Maxs[i];
        end;
        Top := MidRow - MaxV * MidRow;
        Bot := MidRow - MinV * MidRow;
        if Bot < Top + 0.02 then
          Bot := Top + 0.02; { silence still shows a hairline, not nothing }
        if (WaveRowGlyph(Top - Row, Bot - Row) = ' ') and GridCols[Col] then
        begin
          { Blank cell on a grid column - show the faint grid tick instead
            of empty space, still tinted with the selection colour if
            selected so the grid doesn't visually poke through a selection. }
          if (Col >= SelColStart) and (Col < SelColEnd) then
            MoveChar(B[Col], WaveGridChar, SelC, 1)
          else
            MoveChar(B[Col], WaveGridChar, WaveGridAttr, 1);
        end
        else if (Col >= SelColStart) and (Col < SelColEnd) then
          MoveChar(B[Col], WaveRowGlyph(Top - Row, Bot - Row), SelC, 1)
        else
          MoveChar(B[Col], WaveRowGlyph(Top - Row, Bot - Row), C, 1);
      end;
    if (PlayheadCol >= 0) and (PlayheadCol < Size.X) then
      MoveChar(B[PlayheadCol], WavePlayheadChar, WavePlayheadAttr, 1);
    if (not SelActive) and CursorActive and (ClipLength > 0) then
    begin
      CursorCol := FrameToCol(CursorFrame);
      if (CursorCol >= 0) and (CursorCol < Size.X) then
        MoveChar(B[CursorCol], WaveCursorChar, WaveCursorAttr, 1);
    end;
    WriteLine(0, WaveTopRow + Row, Size.X, 1, B);
  end;
end;

{ Left-drag over the wave rows marks a chop selection (Free Vision's own
  TView.MouseEvent drag-poll loop, same "repeat ... until not MouseEvent"
  shape editors.pas's own TEditor.HandleEvent uses for text selection -
  see fvdoc.md's grep gotcha note on why that method doesn't show up in a
  plain `grep -n` of views.pas). Delete then hands the selection off to
  DysWidgets.ChopWaveformSelectionProc - see that var's own comment for why
  the actual clip surgery happens in DysTimeline.pas, not here. A plain
  click with no movement (F1 = F2 at MouseUp) clears any existing
  selection rather than leaving a stale one-column sliver selected. }
procedure TDysWaveformContent.HandleEvent(var Event: TEvent);
var
  Local: TPoint;
  F1, F2, Tmp: Int64;
begin
  if (Event.What = evMouseDown) and (SampleID >= 0) then
  begin
    MakeLocal(Event.Where, Local);
    if Local.Y >= WaveTopRow then
    begin
      F1 := ColToSourceFrame(Local.X);
      SelStartFrame := F1;
      SelEndFrame := F1;
      repeat
        MakeLocal(Event.Where, Local);
        F2 := ColToSourceFrame(Local.X);
        if F2 <> SelEndFrame then
        begin
          SelEndFrame := F2;
          DrawView;
        end;
      until not MouseEvent(Event, evMouseMove + evMouseAuto);
      if SelEndFrame < SelStartFrame then
      begin
        Tmp := SelStartFrame;
        SelStartFrame := SelEndFrame;
        SelEndFrame := Tmp;
      end;
      SelActive := SelEndFrame > SelStartFrame;
      { A plain click (no drag - SelActive came out False above) sets the
        paste cursor instead, so Ctrl+V has somewhere unambiguous to land -
        see CursorActive's own field comment. A real drag-selection clears
        it, so the two markers are never both showing at once. }
      CursorActive := not SelActive;
      if CursorActive then
        CursorFrame := SelStartFrame;
      DrawView;
    end;
    ClearEvent(Event);
    Exit;
  end;
  { Delete is NOT handled here - see DysnomiaApp.pas's cmEditDelete case for
    why: the Edit menu's "Del" hotkey intercepts the raw kbDel byte in
    TMenuBar's own phPreProcess pass before it can ever reach this (or any)
    focused subview, so a local kbDel case here would be dead code. That
    command handler reads/clears SelActive/SelStartFrame/SelEndFrame
    straight off this view instead. }
  inherited HandleEvent(Event);
end;

{ Wired to DysWidgets.SetWaveformClipProc from this unit's own
  `initialization` section - see that var's own comment. }
procedure DysSetWaveformClip(ASampleID: Integer; AOffset, ALength: Int64;
  AGain, ADetune: Single; AWarpMode, ATrack, AClipIdx: Integer);
begin
  if ActiveBottomPane = nil then
    Exit;
  ActiveBottomPane^.WaveformView^.SetClip(ASampleID, AOffset, ALength,
    AGain, ADetune, AWarpMode, ATrack, AClipIdx);
  if not ActiveBottomPane^.ShowingWaveform then
    ActiveBottomPane^.ToggleContent;
end;

{ Builds the Ctrl+Enter/right-click "add effect" popup, categories mirroring
  MainForm.BuildEffectsMenu's own grouping (src/ui) - only the grouping is
  reused, not the code, since that method builds LCL TMenuItems. Assembled
  bottom-up (each NewSubMenu prepends itself via Cats' own Next), so the
  insertion order below is the REVERSE of the on-screen order. }
function BuildAddEffectMenu: PMenu;
var
  Cats: PMenuItem;
begin
  Cats := nil;
  Cats := NewSubMenu('Experimental', 0, NewMenu(
    NewItem('Drowning', '', 0, cmAddEffectBase + Effects.ekDrowning, 0, nil)), Cats);
  Cats := NewSubMenu('Mastering', 0, NewMenu(
    NewItem('Limiter', '', 0, cmAddEffectBase + Effects.ekLimiter, 0, nil)), Cats);
  Cats := NewSubMenu('Utility', 0, NewMenu(
    NewItem('Sidechain', '', 0, cmAddEffectBase + Effects.ekSidechain, 0,
    NewItem('Tuner', '', 0, cmAddEffectBase + Effects.ekTuner, 0, nil))), Cats);
  Cats := NewSubMenu('Pedals', 0, NewMenu(
    NewItem('Fuzz FZ-2', '', 0, cmAddEffectBase + Effects.ekFuzzFZ2, 0, nil)), Cats);
  Cats := NewSubMenu('Exciter', 0, NewMenu(
    NewItem('Exciter 422A', '', 0, cmAddEffectBase + Effects.ekExciter422A, 0, nil)), Cats);
  Cats := NewSubMenu('Dynamics', 0, NewMenu(
    NewItem('Compressor 3630', '', 0, cmAddEffectBase + Effects.ekCompressor3630, 0, nil)), Cats);
  Cats := NewSubMenu('Delay', 0, NewMenu(
    NewItem('QuadraVerb Delay', '', 0, cmAddEffectBase + Effects.ekQuadraverbDelay, 0, nil)), Cats);
  Cats := NewSubMenu('Reverb', 0, NewMenu(
    NewItem('Basic Reverb', '', 0, cmAddEffectBase + Effects.ekReverb, 0,
    NewItem('QuadraVerb Reverb', '', 0, cmAddEffectBase + Effects.ekQuadraverbReverb, 0, nil))), Cats);
  Cats := NewSubMenu('Distortion', 0, NewMenu(
    NewItem('Overdrive', '', 0, cmAddEffectBase + Effects.ekOverdrive, 0, nil)), Cats);
  Cats := NewSubMenu('Modulation', 0, NewMenu(
    NewItem('Chorus', '', 0, cmAddEffectBase + Effects.ekChorus, 0,
    NewItem('Flanger', '', 0, cmAddEffectBase + Effects.ekFlanger, 0,
    NewItem('Phaser', '', 0, cmAddEffectBase + Effects.ekPhaser, 0, nil)))), Cats);
  Cats := NewSubMenu('EQ', 0, NewMenu(
    NewItem('4-Band EQ', '', 0, cmAddEffectBase + Effects.ekEQ4, 0, nil)), Cats);
  Cats := NewSubMenu('Filters', 0, NewMenu(
    NewItem('LP', '', 0, cmAddEffectBase + Effects.ekLowpass, 0,
    NewItem('HP', '', 0, cmAddEffectBase + Effects.ekHighpass, 0,
    NewItem('BP', '', 0, cmAddEffectBase + Effects.ekBandpass, 0, nil)))), Cats);
  Result := NewMenu(Cats);
end;

{ Shared by the slider and the edit field: recompute the displayed text from
  whichever field the binding actually points at (the field itself, not
  either widget's own cached state, is the source of truth). Scale >= 10
  means the field carries fractional resolution (a *X10/*X100-style param,
  see TDysParamBinding's own comment) so the readout keeps one decimal;
  otherwise it's whole-number already. }
procedure DysFormatParamValue(ABinding: PDysParamBinding; out S: string);
var
  RealVal: Single;
  NumStr: string;
begin
  if ABinding^.FloatPtr <> nil then
    RealVal := ABinding^.FloatPtr^
  else if ABinding^.IntPtr <> nil then
    RealVal := ABinding^.IntPtr^
  else
    RealVal := 0;
  if ABinding^.Scale >= 10 then
    Str(RealVal:0:1, NumStr)
  else
    Str(Round(RealVal), NumStr);
  S := NumStr + ABinding^.UnitStr;
end;

{ TDysParamSlider }

constructor TDysParamSlider.Init(Bounds: TRect; ABinding: PDysParamBinding);
begin
  inherited Init(Bounds);
  GrowMode := 0;
  Options := Options or ofSelectable;
  Binding := ABinding;
end;

procedure TDysParamSlider.HandleEvent(var Event: TEvent);
var
  RealVal: Single;
  S: string;
begin
  inherited HandleEvent(Event);
  if (Binding = nil) or (Binding^.Edit = nil) then
    Exit;
  RealVal := Value / Binding^.Scale;
  if Binding^.FloatPtr <> nil then
    Binding^.FloatPtr^ := RealVal
  else if Binding^.IntPtr <> nil then
    Binding^.IntPtr^ := Round(RealVal);
  DysFormatParamValue(Binding, S);
  Binding^.Edit^.Data^ := S;
  if Binding^.Edit^.State and sfVisible <> 0 then
    Binding^.Edit^.DrawView;
end;

{ TDysParamEdit }

constructor TDysParamEdit.Init(Bounds: TRect; ABinding: PDysParamBinding);
begin
  inherited Init(Bounds, 8);
  GrowMode := 0;
  Options := Options or ofSelectable;
  Binding := ABinding;
end;

{ Enter has no meaning to a plain TInputLine outside a TDialog (see
  DysWidgets.TDysToolBar.CommitTempo's identical note) - has to be caught
  here explicitly. Esc likewise does nothing on its own; caught here so it
  reverts the typed text instead of bubbling up and, e.g., leaving the
  keyboard-instrument pane (TDysEffectsContent.HandleEvent's own kbEsc
  case) while the user only meant to cancel an edit. }
procedure TDysParamEdit.HandleEvent(var Event: TEvent);
var
  Parsed: Double;
  Code: Word;
  Clamped: Single;
  S: string;
begin
  inherited HandleEvent(Event);
  if Binding = nil then
    Exit;
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEnter) then
  begin
    S := Data^;
    Val(S, Parsed, Code);
    if Code = 0 then
    begin
      Clamped := Parsed;
      if Clamped < Binding^.Min then
        Clamped := Binding^.Min;
      if Clamped > Binding^.Max then
        Clamped := Binding^.Max;
      if Binding^.FloatPtr <> nil then
        Binding^.FloatPtr^ := Clamped
      else if Binding^.IntPtr <> nil then
        Binding^.IntPtr^ := Round(Clamped);
      if Binding^.Slider <> nil then
        Binding^.Slider^.SetValue(Round(Clamped * Binding^.Scale));
    end;
    DysFormatParamValue(Binding, S);
    Data^ := S;
    DrawView;
    ClearEvent(Event);
  end
  else if (Event.What = evKeyDown) and (Event.KeyCode = kbEsc) then
  begin
    DysFormatParamValue(Binding, S);
    Data^ := S;
    DrawView;
    ClearEvent(Event);
  end;
end;

{ TDysEffectFrame }

constructor TDysEffectFrame.Init(Bounds: TRect; ABox: PDysEffectBox);
begin
  inherited Init(Bounds);
  GrowMode := 0;
  Box := ABox;
end;

{ Plain ASCII border ('+'/'-'/'|') rather than CP437 line-drawing - tui.md
  says not to worry about Unicode, but there's no benefit to it here either,
  and ASCII sidesteps any doubt about the close glyph's own column math
  under a wide-glyph font. Slider/Edit are inserted after this view, so they
  draw on top of whatever cells they occupy every time either redraws -
  this only ever needs to paint the labels and the frame itself. }
procedure TDysEffectFrame.Draw;
var
  B: TDrawBuffer;
  C: Word;
  Row, I: Integer;
  S: string;
begin
  C := $70; { light-grey bg, black fg - see fvdoc's bit-7-is-blink note on
              why this can't just be a hand-picked $Fx/$Cx/$Ex byte }
  for Row := 0 to Size.Y - 1 do
  begin
    MoveChar(B, ' ', C, Size.X);
    if Row = 0 then
    begin
      MoveChar(B, '-', C, Size.X);
      MoveStr(B[1], ' ' + Box^.Title + ' ', C);
      if Size.X > 6 then
        MoveStr(B[Size.X - 4], '[x]', C);
    end
    else if Row = Size.Y - 1 then
      MoveChar(B, '-', C, Size.X)
    else
    begin
      MoveStr(B, '|', C);
      MoveStr(B[Size.X - 1], '|', C);
      I := Row - 1;
      if I < Box^.NextRow then
      begin
        S := Box^.ParamNames[I] + ':';
        MoveStr(B[1], S, C);
      end;
    end;
    WriteLine(0, Row, Size.X, 1, B);
  end;
end;

{ TDysEffectBox }

constructor TDysEffectBox.Init(Bounds: TRect; ATrackIndex, AEffectIndex: Integer);
var
  EffectPtr: PEffect;
  R: TRect;
begin
  inherited Init(Bounds);
  GrowMode := 0;
  TrackIndex := ATrackIndex;
  EffectIndex := AEffectIndex;
  NextRow := 0;
  BindingCount := 0;
  EffectPtr := @Project.TrackEffects[ATrackIndex][AEffectIndex];
  Kind := EffectPtr^.Kind;
  Title := DysEffectKindName(Kind);
  GetExtent(R);
  Frame := New(PDysEffectFrame, Init(R, @Self));
  Insert(Frame);
  BuildParams(EffectPtr);
end;

destructor TDysEffectBox.Done;
var
  I: Integer;
begin
  for I := 0 to BindingCount - 1 do
    Dispose(Bindings[I]);
  inherited Done;
end;

{ One case per Effects.ekXxx kind (1..18) - EffectRowCounts above has to be
  kept in sync with how many AddParamF/AddParamI calls each branch makes;
  there's no way to derive one from the other short of calling this twice,
  which would double-allocate every TScrollBar/TInputLine, so it isn't. }
procedure TDysEffectBox.BuildParams(EffectPtr: PEffect);
var
  I, MaxSrcTrack: Integer;
begin
  case Kind of
    Effects.ekLowpass:
      AddParamF('Freq', 'Hz', 20, 20000, 1, @EffectPtr^.LowpassFreqHz);
    Effects.ekHighpass:
      AddParamF('Freq', 'Hz', 20, 20000, 1, @EffectPtr^.HighpassFreqHz);
    Effects.ekBandpass:
      begin
        AddParamF('Freq', 'Hz', 20, 20000, 1, @EffectPtr^.BandpassFreqHz);
        AddParamF('Q', '', 0.1, 10, 10, @EffectPtr^.BandpassQ);
      end;
    Effects.ekEQ4:
      for I := 0 to Effects.MaxEQBands - 1 do
      begin
        AddParamF('F' + Chr(Ord('1') + I), 'Hz', 20, 20000, 1, @EffectPtr^.EQFreqHz[I]);
        AddParamF('G' + Chr(Ord('1') + I), 'dB', -12, 12, 1, @EffectPtr^.EQGainDb[I]);
      end;
    Effects.ekLimiter:
      begin
        AddParamF('Thresh', 'dB', -24, 0, 1, @EffectPtr^.LimiterThresholdDb);
        AddParamF('Release', 'ms', 10, 500, 1, @EffectPtr^.LimiterReleaseMs);
      end;
    Effects.ekChorus:
      begin
        AddParamF('Rate', 'Hz', 0.05, 5.0, 100, @EffectPtr^.ChorusRateHz);
        AddParamF('Depth', '%', 0, 100, 1, @EffectPtr^.ChorusDepthPercent);
      end;
    Effects.ekReverb:
      begin
        AddParamI('Preset', '', 0, Effects.ReverbPresetCount - 1, @EffectPtr^.ReverbPreset);
        AddParamF('Mix', '%', 0, 100, 1, @EffectPtr^.ReverbMixPercent);
      end;
    Effects.ekFlanger:
      begin
        AddParamF('Rate', 'Hz', 0.05, 5.0, 100, @EffectPtr^.FlangerRateHz);
        AddParamF('Depth', '%', 0, 100, 1, @EffectPtr^.FlangerDepthPercent);
        AddParamF('Feedback', '%', 0, 95, 1, @EffectPtr^.FlangerFeedbackPercent);
        AddParamF('Mix', '%', 0, 100, 1, @EffectPtr^.FlangerMixPercent);
      end;
    Effects.ekPhaser:
      begin
        AddParamF('Rate', 'Hz', 0.05, 5.0, 100, @EffectPtr^.PhaserRateHz);
        AddParamF('Depth', '%', 0, 100, 1, @EffectPtr^.PhaserDepthPercent);
        AddParamF('Feedback', '%', 0, 95, 1, @EffectPtr^.PhaserFeedbackPercent);
        AddParamF('Mix', '%', 0, 100, 1, @EffectPtr^.PhaserMixPercent);
      end;
    Effects.ekSidechain:
      begin
        MaxSrcTrack := Project.TrackCount - 1;
        if MaxSrcTrack < 0 then
          MaxSrcTrack := 0;
        AddParamI('SrcTrk', '', 0, MaxSrcTrack, @EffectPtr^.SidechainSourceTrack);
        AddParamF('Thresh', 'dB', -60, 0, 1, @EffectPtr^.SidechainThresholdDb);
        AddParamF('Attack', 'ms', 1, 200, 1, @EffectPtr^.SidechainAttackMs);
        AddParamF('Release', 'ms', 10, 1000, 1, @EffectPtr^.SidechainReleaseMs);
        AddParamF('Strength', '%', 0, 100, 1, @EffectPtr^.SidechainStrengthPercent);
      end;
    Effects.ekDrowning:
      begin
        AddParamF('Tone', 'Hz', 20, 20000, 1, @EffectPtr^.DrowningToneHz);
        AddParamF('WRate', 'Hz', 0.05, 5.0, 100, @EffectPtr^.DrowningWarbleRateHz);
        AddParamF('WDepth', '%', 0, 100, 1, @EffectPtr^.DrowningWarbleDepthPercent);
        AddParamF('Size', '%', 0, 100, 1, @EffectPtr^.DrowningSizePercent);
        AddParamF('Decay', '%', 0, 100, 1, @EffectPtr^.DrowningDecayPercent);
        AddParamF('Mix', '%', 0, 100, 1, @EffectPtr^.DrowningMixPercent);
      end;
    Effects.ekTuner:
      ; { read-only - no user parameters at all, see Effects.pas's own note
          on TEffectState.TunerFreqHz vs TEffect }
    Effects.ekOverdrive:
      begin
        AddParamF('Freq', 'Hz', 20, 20000, 1, @EffectPtr^.OverdriveFreqHz);
        AddParamF('Q', '', 0.1, 5.0, 20, @EffectPtr^.OverdriveQ);
        AddParamF('Drive', '%', 0, 100, 1, @EffectPtr^.OverdriveDrivePercent);
        AddParamF('Color', '%', 0, 100, 1, @EffectPtr^.OverdriveColorPercent);
        AddParamF('Mix', '%', 0, 100, 1, @EffectPtr^.OverdriveMixPercent);
      end;
    Effects.ekQuadraverbReverb:
      begin
        AddParamI('Type', '', 0, Quadraverb.QVReverbTypeCount - 1, @EffectPtr^.QVReverbType);
        AddParamF('Predelay', 'ms', Quadraverb.QVPredelayMinMs, Quadraverb.QVPredelayMaxMs, 1,
          @EffectPtr^.QVReverbPredelayMs);
        AddParamF('PreMix', '%', Quadraverb.QVPredelayMixMin, Quadraverb.QVPredelayMixMax, 1,
          @EffectPtr^.QVReverbPredelayMix);
        AddParamF('Decay', '%', Quadraverb.QVDecayMin, Quadraverb.QVDecayMax, 1,
          @EffectPtr^.QVReverbDecay);
        AddParamF('Diffuse', '', Quadraverb.QVDiffusionMin, Quadraverb.QVDiffusionMax, 1,
          @EffectPtr^.QVReverbDiffusion);
        AddParamF('Density', '', Quadraverb.QVDensityMin, Quadraverb.QVDensityMax, 1,
          @EffectPtr^.QVReverbDensity);
        AddParamF('LowDecay', 'dB', Quadraverb.QVBandDecayMin, Quadraverb.QVBandDecayMax, 1,
          @EffectPtr^.QVReverbLowDecay);
        AddParamF('HiDecay', 'dB', Quadraverb.QVBandDecayMin, Quadraverb.QVBandDecayMax, 1,
          @EffectPtr^.QVReverbHighDecay);
        AddParamF('Mix', '%', 0, 100, 1, @EffectPtr^.QVReverbMixPercent);
      end;
    Effects.ekQuadraverbDelay:
      begin
        AddParamI('Type', '', 0, Quadraverb.QVDelayTypeCount - 1, @EffectPtr^.QVDelayType);
        AddParamF('TimeL', 'ms', 0, Quadraverb.QVDelayMonoMaxMs, 1, @EffectPtr^.QVDelayTimeLMs);
        AddParamF('TimeR', 'ms', 0, Quadraverb.QVDelayStereoMaxMs, 1, @EffectPtr^.QVDelayTimeRMs);
        AddParamF('FbkL', '%', 0, Quadraverb.QVDelayFeedbackMax, 1, @EffectPtr^.QVDelayFeedbackL);
        AddParamF('FbkR', '%', 0, Quadraverb.QVDelayFeedbackMax, 1, @EffectPtr^.QVDelayFeedbackR);
        AddParamF('Mix', '%', 0, 100, 1, @EffectPtr^.QVDelayMixPercent);
      end;
    Effects.ekExciter422A:
      begin
        AddParamF('LoContour', 'dB', BBE422A.BBELoContourMinDb, BBE422A.BBELoContourMaxDb, 1,
          @EffectPtr^.BBELoContourDb);
        AddParamF('Definitn', '%', BBE422A.BBEDefinitionMin, BBE422A.BBEDefinitionMax, 1,
          @EffectPtr^.BBEDefinition);
        AddParamF('Mix', '%', 0, 100, 1, @EffectPtr^.BBEMixPercent);
      end;
    Effects.ekCompressor3630:
      begin
        AddParamI('Response', '', 0, Alesis3630.A36ResponseCount - 1, @EffectPtr^.C36Response);
        AddParamI('Knee', '', 0, Alesis3630.A36KneeCount - 1, @EffectPtr^.C36Knee);
        AddParamF('Thresh', 'dBu', Alesis3630.A36ThresholdMinDbu, Alesis3630.A36ThresholdMaxDbu, 1,
          @EffectPtr^.C36ThresholdDbu);
        AddParamF('Ratio', 'x', 1, Alesis3630.A36RatioMaxFinite, 10, @EffectPtr^.C36Ratio);
        AddParamF('Attack', 'ms', Alesis3630.A36AttackMinMs, Alesis3630.A36AttackMaxMs, 10,
          @EffectPtr^.C36AttackMs);
        AddParamF('Release', 'ms', Alesis3630.A36ReleaseMinMs, Alesis3630.A36ReleaseMaxMs, 1,
          @EffectPtr^.C36ReleaseMs);
        AddParamF('Output', 'dB', Alesis3630.A36OutputMinDb, Alesis3630.A36OutputMaxDb, 1,
          @EffectPtr^.C36OutputDb);
        AddParamF('GateThr', 'dBfs', Alesis3630.A36GateThresholdMinDbfs,
          Alesis3630.A36GateThresholdMaxDbfs, 10, @EffectPtr^.C36GateThresholdDbfs);
        AddParamF('GateRate', 'ms', Alesis3630.A36GateRateMinMs, Alesis3630.A36GateRateMaxMs, 1,
          @EffectPtr^.C36GateRateMs);
        AddParamF('Mix', '%', 0, 100, 1, @EffectPtr^.C36MixPercent);
      end;
    Effects.ekFuzzFZ2:
      begin
        AddParamI('Mode', '', 0, BossFZ2.FZ2ModeCount - 1, @EffectPtr^.FZ2Mode);
        AddParamF('Gain', '%', BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, 1, @EffectPtr^.FZ2Gain);
        AddParamF('Treble', '%', BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, 1, @EffectPtr^.FZ2Treble);
        AddParamF('Bass', '%', BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, 1, @EffectPtr^.FZ2Bass);
        AddParamF('Level', '%', BossFZ2.FZ2KnobMin, BossFZ2.FZ2KnobMax, 1, @EffectPtr^.FZ2Level);
        AddParamF('Mix', '%', 0, 100, 1, @EffectPtr^.FZ2MixPercent);
      end;
  end;
end;

procedure TDysEffectBox.AddParamF(const AName, AUnitStr: string; AMin, AMax, AScale: Single;
  AFieldPtr: PSingle);
var
  Binding: PDysParamBinding;
  R: TRect;
  Y, ScaledMin, ScaledMax, ScaledVal, Step: Integer;
  S: string;
begin
  if NextRow + 3 > Size.Y then
    Exit; { no room left - see EffectRowCounts, this should never trip }
  New(Binding);
  Binding^.FloatPtr := AFieldPtr;
  Binding^.IntPtr := nil;
  Binding^.Min := AMin;
  Binding^.Max := AMax;
  Binding^.Scale := AScale;
  Binding^.UnitStr := Copy(AUnitStr, 1, 4);
  Binding^.Slider := nil;
  Binding^.Edit := nil;
  Bindings[BindingCount] := Binding;
  Inc(BindingCount);
  ParamNames[NextRow] := Copy(AName, 1, 8);
  Y := 1 + NextRow;

  R.Assign(ParamSliderX, Y, ParamSliderX + ParamSliderW, Y + 1);
  Binding^.Slider := New(PDysParamSlider, Init(R, Binding));
  Insert(Binding^.Slider);

  R.Assign(ParamValueX, Y, ParamValueX + ParamValueW, Y + 1);
  Binding^.Edit := New(PDysParamEdit, Init(R, Binding));
  Insert(Binding^.Edit);

  ScaledMin := Round(AMin * AScale);
  ScaledMax := Round(AMax * AScale);
  Step := (ScaledMax - ScaledMin) div 10;
  if Step < 1 then
    Step := 1;
  Binding^.Slider^.SetRange(ScaledMin, ScaledMax);
  Binding^.Slider^.SetStep(Step, 1);

  ScaledVal := Round(AFieldPtr^ * AScale);
  if ScaledVal < ScaledMin then
    ScaledVal := ScaledMin;
  if ScaledVal > ScaledMax then
    ScaledVal := ScaledMax;
  Binding^.Slider^.SetValue(ScaledVal);
  DysFormatParamValue(Binding, S);
  Binding^.Edit^.Data^ := S;

  Inc(NextRow);
end;

procedure TDysEffectBox.AddParamI(const AName, AUnitStr: string; AMin, AMax: Integer;
  AFieldPtr: PInteger);
var
  Binding: PDysParamBinding;
  R: TRect;
  Y, ScaledVal, Step: Integer;
  S: string;
begin
  if NextRow + 3 > Size.Y then
    Exit;
  New(Binding);
  Binding^.FloatPtr := nil;
  Binding^.IntPtr := AFieldPtr;
  Binding^.Min := AMin;
  Binding^.Max := AMax;
  Binding^.Scale := 1;
  Binding^.UnitStr := Copy(AUnitStr, 1, 4);
  Binding^.Slider := nil;
  Binding^.Edit := nil;
  Bindings[BindingCount] := Binding;
  Inc(BindingCount);
  ParamNames[NextRow] := Copy(AName, 1, 8);
  Y := 1 + NextRow;

  R.Assign(ParamSliderX, Y, ParamSliderX + ParamSliderW, Y + 1);
  Binding^.Slider := New(PDysParamSlider, Init(R, Binding));
  Insert(Binding^.Slider);

  R.Assign(ParamValueX, Y, ParamValueX + ParamValueW, Y + 1);
  Binding^.Edit := New(PDysParamEdit, Init(R, Binding));
  Insert(Binding^.Edit);

  Step := (AMax - AMin) div 10;
  if Step < 1 then
    Step := 1;
  Binding^.Slider^.SetRange(AMin, AMax);
  Binding^.Slider^.SetStep(Step, 1);

  ScaledVal := AFieldPtr^;
  if ScaledVal < AMin then
    ScaledVal := AMin;
  if ScaledVal > AMax then
    ScaledVal := AMax;
  Binding^.Slider^.SetValue(ScaledVal);
  DysFormatParamValue(Binding, S);
  Binding^.Edit^.Data^ := S;

  Inc(NextRow);
end;

{ Removal is deferred to TDysEffectsContent (see RequestRemoval/HandleEvent
  there) rather than Dispose(Self)'d right here: this method runs INSIDE
  Self's own HandleEvent call, on Self's own stack frame - freeing Self
  before returning from it would be a use-after-free the instant control
  unwinds back through TGroup's own dispatch machinery. Content's post-
  inherited check runs one call level up, strictly after this box's
  HandleEvent has already returned, which is the same reason MainForm's
  own DeleteClick defers its rebuild (Application.QueueAsyncCall, see
  tui.md) rather than freeing a control mid-click. }
procedure TDysEffectBox.HandleEvent(var Event: TEvent);
var
  Local: TPoint;
begin
  if (Event.What = evKeyDown) and ((Event.KeyCode = kbUp) or (Event.KeyCode = kbDown)) then
  begin
    SelectNext(Event.KeyCode = kbDown);
    ClearEvent(Event);
    Exit;
  end;
  if (Event.What = evKeyDown) and (Event.KeyCode = kbCtrlX) then
  begin
    if ActiveEffectsContent <> nil then
      ActiveEffectsContent^.RequestRemoval(TrackIndex, EffectIndex);
    ClearEvent(Event);
    Exit;
  end;
  if Event.What = evMouseDown then
  begin
    MakeLocal(Event.Where, Local);
    if (Local.Y = 0) and (Local.X >= Size.X - 4) and (Local.X <= Size.X - 2) then
    begin
      if ActiveEffectsContent <> nil then
        ActiveEffectsContent^.RequestRemoval(TrackIndex, EffectIndex);
      ClearEvent(Event);
      Exit;
    end;
  end;
  inherited HandleEvent(Event);
end;

{ TDysEffectsContent }

constructor TDysEffectsContent.Init(Bounds: TRect);
begin
  inherited Init(Bounds);
  GrowMode := 0;
  EventMask := EventMask or evMouseDown or evKeyDown;
  Options := Options or (ofSelectable + ofFirstClick);
  TrackIndex := -1;
  EffectCount := 0;
  PendingRemoveTrack := 0;
  PendingRemoveIndex := -1;
  ActiveEffectsContent := @Self;
  RebuildBoxes;
end;

{ The single source of truth for what's on screen: always fully rebuilt
  from Project.TrackEffects[track] rather than patched incrementally, same
  "unconditional full resync beats a partial/delta step" reasoning
  DysnomiaApp.RefreshAfterProjectChange's own engine-slot clear settled on
  (see tui.md) - there are at most 24 effects on a track, so the cost is
  irrelevant next to correctness. }
{ Shelf packing, one column of width EffBoxWidth at a time: a box is
  stacked under whatever's already in the current column as long as it
  still fits there; once it doesn't (either the column's already full, or
  this one box alone is taller than the column has room left for), a new
  column starts to its right and the box goes at the top of THAT one
  instead. A box's own height is always clamped to fit within a single
  column (Size.Y - 1, see H below) before this decision is made, so "one
  box alone is taller than the column" can only happen for the SECOND-plus
  box in a column, never the first - a lone box that's tall always gets
  its own column outright rather than being squeezed or clipped. This is
  what makes two short effects stack one above the other while a tall one
  pushes over to the right instead of overlapping either of them. }
procedure TDysEffectsContent.RebuildBoxes;
var
  V: PView;
  I, X, Y, H, RowCount, Trk, Count: Integer;
  Box: PDysEffectBox;
  R: TRect;
begin
  while First <> nil do
  begin
    V := First;
    Delete(V);
    Dispose(PDysEffectBox(V), Done);
  end;
  Trk := SelectedTrackIndex;
  TrackIndex := Trk;
  if (Trk < 0) or (Trk > High(Project.TrackEffectCount)) then
  begin
    EffectCount := 0;
    DrawView;
    Exit;
  end;
  Count := Project.TrackEffectCount[Trk];
  EffectCount := Count;
  X := 0;
  Y := 1; { row 0 is the track-badge/hint line, boxes start below it }
  for I := 0 to Count - 1 do
  begin
    RowCount := EffectRowCounts[Project.TrackEffects[Trk][I].Kind];
    H := RowCount + 2;
    if H > Size.Y - 1 then
      H := Size.Y - 1;
    if H < 2 then
      H := 2;
    if (Y > 1) and (Y + H > Size.Y) then
    begin
      X := X + EffBoxWidth + 1;
      Y := 1;
    end;
    if X + EffBoxWidth > Size.X then
      Break; { no horizontal scroll yet - later boxes just don't fit }
    R.Assign(X, Y, X + EffBoxWidth, Y + H);
    Box := New(PDysEffectBox, Init(R, Trk, I));
    Insert(Box);
    Y := Y + H;
  end;
  DrawView;
end;

procedure TDysEffectsContent.RequestRemoval(ATrackIndex, AEffectIndex: Integer);
begin
  PendingRemoveTrack := ATrackIndex;
  PendingRemoveIndex := AEffectIndex;
end;

procedure TDysEffectsContent.OpenAddEffectMenu(AGlobalPos: TPoint);
var
  MenuData: PMenu;
  MenuBoxPtr: PMenuBox;
  DeskR, R: TRect;
  Local: TPoint;
  Cmd: Word;
  Kind: Integer;
begin
  Desktop^.GetExtent(DeskR);
  Desktop^.MakeLocal(AGlobalPos, Local);
  R.Assign(Local.X, Local.Y, DeskR.B.X, DeskR.B.Y);
  MenuData := BuildAddEffectMenu;
  MenuBoxPtr := New(PMenuBox, Init(R, MenuData, nil));
  Cmd := Desktop^.ExecView(MenuBoxPtr);
  Dispose(MenuBoxPtr, Done);
  DisposeMenu(MenuData);
  if Cmd >= cmAddEffectBase then
  begin
    Kind := Cmd - cmAddEffectBase;
    if Project.AddTrackEffect(TrackIndex, Kind) then
      RebuildBoxes;
  end;
end;

procedure TDysEffectsContent.Draw;
var
  B: TDrawBuffer;
  C: Word;
  S, Lbl: string;
  Row: Integer;
begin
  C := GetColor(1);
  Lbl := DysBottomTrackLabel(SelectedTrackIndex);
  if EffectCount = 0 then
    S := ' effects: (none - Ctrl+Enter or right-click to add) '
  else
    S := ' effects: (Ctrl+Enter/right-click adds, [x] or Ctrl+X removes) ';
  for Row := 0 to Size.Y - 1 do
  begin
    MoveChar(B, ' ', C, Size.X);
    if Row = 0 then
    begin
      MoveStr(B, Lbl, C);
      MoveStr(B[Length(Lbl) + 1], S, C);
    end;
    WriteLine(0, Row, Size.X, 1, B);
  end;
  { This override replaces TGroup.Draw's own body wholesale (background +
    header text instead of TGroup's default blank fill) - but TGroup.Draw
    is also what calls DrawSubViews to actually paint this group's
    children (DrawSubViews itself is `private` to views.pas, not callable
    from here - `inherited Draw` is the public entry point that reaches it).
    Skipping that meant every full redraw of Content itself (any time
    something else forces it to re-expose - a dismissed MessageBox/menu, a
    Tab focus change elsewhere redrawing the desktop, etc.) blanked this
    whole rect and never repainted the effect boxes sitting in it, since a
    child box's OWN Draw only runs when something targets that specific
    child (e.g. a click on it) - not as a side effect of its parent's Draw.
    Symptom: boxes only "appeared" piecemeal, as whichever child got
    directly interacted with repainted itself, and a plain click elsewhere
    (forcing Content to redraw as a whole again with no interaction on any
    one child) blanked them all straight back out. Background must be
    painted first, then `inherited Draw` layers the children on top - the
    other order would let the background wipe them right back out again. }
  inherited Draw;
end;

{ Checks run BEFORE inherited, not after - TGroup.HandleEvent's own mouse
  dispatch (DoHandleEvent(FirstThat(@ContainsMouse))) or a focused-event
  pass to Current can otherwise consume/clear the event on its way through
  before this override ever sees it back. Same "intercept first, inherited
  last" shape TDysPane already uses for Tab and TDysEffectBox uses for its
  own mouse/Ctrl+X close check - this view's own first pass at Ctrl+Enter/
  right-click checked AFTER inherited instead, which is the bug report this
  is fixing (see tui.md's session note). }
procedure TDysEffectsContent.HandleEvent(var Event: TEvent);
var
  Pt: TPoint;
begin
  { A mouse click doesn't grant keyboard focus by itself (see fvdoc's
    "Nothing is focused by default") - without this, Ctrl+Enter typed right
    after clicking into this pane would still route to whatever Current
    actually is, e.g. the timeline the app started focused on. }
  if (Event.What = evMouseDown) and (State and sfFocused = 0) then
    Focus;
  if SelectedTrackIndex <> TrackIndex then
    RebuildBoxes;
  if PendingRemoveIndex >= 0 then
  begin
    Project.RemoveTrackEffect(PendingRemoveTrack, PendingRemoveIndex);
    PendingRemoveIndex := -1;
    RebuildBoxes;
  end;
  if ((Event.What = evKeyDown) and
      ((Event.KeyCode = kbCtrlEnter) or (Event.KeyCode = kbDropdownKey))) or
     ((Event.What = evMouseDown) and (Event.Buttons and mbActualRightButton <> 0)) then
  begin
    if Event.What = evMouseDown then
      Pt := Event.Where
    else
    begin
      Pt.X := 0;
      Pt.Y := 0;
      MakeGlobal(Pt, Pt); { this view's own top-left, in global coords - a
                            reasonable default position for a keyboard-
                            triggered Ctrl+Enter (no mouse position to use) }
    end;
    OpenAddEffectMenu(Pt);
    ClearEvent(Event);
    Exit;
  end;
  { Esc: back to the track list. The instrument keyboard itself no longer
    lives on this pane at all - see DysWidgets.TDysToolBar.HandleEvent -
    typing here (naming things, editing a param's numeric readout, etc.)
    used to also risk triggering notes as a side effect of whatever pane
    happened to be focused; now only the transport pane's own keystrokes
    ever reach TriggerKeyboardNoteProc. }
  if (Event.What = evKeyDown) and (Event.KeyCode = kbEsc) then
  begin
    if ActiveTrackPane <> nil then
      ActiveTrackPane^.FocusPane;
    ClearEvent(Event);
    Exit;
  end;
  inherited HandleEvent(Event);
end;

{ TDysBottomPane }

constructor TDysBottomPane.InitPane(Bounds: TRect);
var
  R: TRect;
begin
  inherited InitPane(Bounds, 'Effects');
  R := ContentRect;
  Content := New(PDysEffectsContent, Init(R));
  Insert(Content);
  WaveformView := New(PDysWaveformContent, Init(R));
  Insert(WaveformView);
  WaveformView^.Hide; { Effects is the default view - see ShowingWaveform }
  Focusable := Content;
  ShowingWaveform := False;
  ActiveBottomPane := @Self;
end;

procedure TDysBottomPane.FocusPane;
begin
  { Nothing to rebuild for WaveformView - its content only ever changes via
    SetClip (the 'k' key), not by which track/pane last had focus. }
  if not ShowingWaveform then
    Content^.RebuildBoxes;
  inherited FocusPane;
end;

{ Ctrl+W, app-wide - see TDysnomiaApp.HandleEvent. Swaps which of Content/
  WaveformView is visible/focusable and relabels the pane's own title
  (DisposeStr/NewStr - same pattern TDysToolBar.SetTitle already uses for a
  button's Title - followed by Frame^.DrawView, since TFrame, not this
  view itself, is what actually paints the title text; see views.pas'
  TFrame.Draw). If this pane currently holds keyboard focus, hands it to
  whichever view just became visible so Ctrl+W's own effect is immediately
  usable rather than leaving focus on a now-hidden view. }
procedure TDysBottomPane.ToggleContent;
begin
  ShowingWaveform := not ShowingWaveform;
  if ShowingWaveform then
  begin
    Content^.Hide;
    WaveformView^.Show;
    Focusable := WaveformView;
    if Title <> nil then
      DisposeStr(Title);
    Title := NewStr('Waveform');
  end
  else
  begin
    WaveformView^.Hide;
    Content^.Show;
    Focusable := Content;
    if Title <> nil then
      DisposeStr(Title);
    Title := NewStr('Effects');
  end;
  if Frame <> nil then
    Frame^.DrawView;
  if State and sfFocused <> 0 then
    FocusPane;
end;

initialization
  { Wires DysWidgets.TDysToolBar.HandleEvent's two callback vars to the
    real implementations - see DysWidgets.pas's own comment on why it
    can't `uses DysEffectsRack` directly to call these itself. }
  TriggerKeyboardNoteProc := @TriggerDysKeyboardNote;
  AdjustKeyboardOctaveProc := @AdjustDysKeyboardOctave;
  SetWaveformClipProc := @DysSetWaveformClip;

end.
