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
  Math, AudioEngine, SampleTypes;

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

  { The bottom dock: hosts TDysEffectsContent above. Lives here rather than
    in DysWidgets.pas (which every other docked pane's type does) because
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
    constructor InitPane(Bounds: TRect);
    { Rebuilds the rack from whatever track DysTrackPane's cursor is on NOW,
      every time Tab/Shift+Tab brings focus into this pane - see
      TDysEffectsContent.RebuildBoxes's own comment on why this and
      HandleEvent's per-event check are the two places that trigger a
      rebuild, instead of a track-changed broadcast this app has no
      equivalent of yet. }
    procedure FocusPane; virtual;
  end;

function DysEffectKindName(AKind: Integer): string;

{ Set once, by TDysEffectsContent.Init - there is exactly one effects
  content view in this single-window app, same "global points at the one
  instance" pattern ActiveTrackPane/ActiveToolBar already use. TDysEffectBox
  reaches through this to request its own removal (see RequestRemoval's own
  comment for why that can't just Dispose(Self) directly). }
var
  ActiveEffectsContent: PDysEffectsContent = nil;

implementation

{ Deliberately not SysUtils - see DysWidgets.pas's own top-of-implementation
  note: SysUtils redeclares Objects.NewStr, and this unit's TInputLine field
  assignments rely on the plain ShortString-typed Objects.NewStr staying in
  scope unshadowed. Str()/Val() (System, no unit needed) cover every number
  <-> string conversion this file needs. }

{ Rudimentary dual-octave QWERTY tracker keyboard - moved here from
  DysWidgets.pas along with TDysEffectsContent itself, unchanged: same key
  table as MainForm.KeyToSemitoneOffset (src/ui), ported by hand since this
  object has no access to Eris's LCL form. Only lives in the bottom
  (effects) pane per tui.md's Bindings: Esc here leaves it. }
function DysKeyToSemitoneOffset(AChar: Char; out AOffset: Integer): Boolean;
begin
  Result := True;
  case UpCase(AChar) of
    'Z': AOffset := 0;
    'S': AOffset := 1;
    'X': AOffset := 2;
    'D': AOffset := 3;
    'C': AOffset := 4;
    'V': AOffset := 5;
    'G': AOffset := 6;
    'B': AOffset := 7;
    'H': AOffset := 8;
    'N': AOffset := 9;
    'J': AOffset := 10;
    'M': AOffset := 11;
    'Q': AOffset := 12;
    '2': AOffset := 13;
    'W': AOffset := 14;
    '3': AOffset := 15;
    'E': AOffset := 16;
    'R': AOffset := 17;
    '5': AOffset := 18;
    'T': AOffset := 19;
    '6': AOffset := 20;
    'Y': AOffset := 21;
    '7': AOffset := 22;
    'U': AOffset := 23;
    'I': AOffset := 24;
    '9': AOffset := 25;
    'O': AOffset := 26;
    '0': AOffset := 27;
    'P': AOffset := 28;
  else
    Result := False;
  end;
end;

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
  if EndFrame > Sample.FrameCount then
    EndFrame := Sample.FrameCount;
  TrimmedCount := EndFrame - StartFrame;
  if TrimmedCount <= 0 then
    Exit;
  TotalOffset := ASemitoneOffset + Project.TrackOctave[Track] * 12;
  AudioEngineTriggerNote(Track, @Sample.Data[StartFrame * Sample.Channels],
    TrimmedCount, Sample.Channels, TotalOffset,
    Power(10, Project.TrackInstrumentGainDb[Track] / 20));
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
procedure TDysEffectsContent.RebuildBoxes;
var
  V: PView;
  I, X, H, RowCount, Trk, Count: Integer;
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
  for I := 0 to Count - 1 do
  begin
    if X + EffBoxWidth > Size.X then
      Break; { no horizontal scroll yet - later boxes just don't fit }
    RowCount := EffectRowCounts[Project.TrackEffects[Trk][I].Kind];
    H := RowCount + 2;
    if H > Size.Y - 1 then
      H := Size.Y - 1;
    if H < 2 then
      H := 2;
    R.Assign(X, 1, X + EffBoxWidth, 1 + H);
    Box := New(PDysEffectBox, Init(R, Trk, I));
    Insert(Box);
    X := X + EffBoxWidth + 1;
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
  Offset: Integer;
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
  if Event.What = evKeyDown then
  begin
    if Event.KeyCode = kbEsc then
    begin
      if ActiveTrackPane <> nil then
        ActiveTrackPane^.FocusPane;
      ClearEvent(Event);
      Exit;
    end;
    if DysKeyToSemitoneOffset(Event.CharCode, Offset) then
    begin
      TriggerDysKeyboardNote(Offset);
      ClearEvent(Event);
      Exit;
    end;
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
  Focusable := Content;
end;

procedure TDysBottomPane.FocusPane;
begin
  Content^.RebuildBoxes;
  inherited FocusPane;
end;

end.
