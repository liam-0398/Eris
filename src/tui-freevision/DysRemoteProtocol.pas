unit DysRemoteProtocol;

{ Shared wire format between the DAW (DysRemoteServer, DysnomiaApp) and any
  client process (currently only DysTrackerApp) talking to it over the Unix
  domain socket at RemoteSocketPath. Plain-text, one message per line,
  request/response (every client line gets exactly one reply line) - the
  simplest thing that works identically on Linux, the BSDs and Tiger/
  Leopard PPC, and needs no serialization library, just Str/Val. Pure
  string encode/decode only - no socket I/O in this unit, see
  DysRemoteServer.pas (server) and DysTrackerApp.pas (client) for that. }

{$mode objfpc}{$H+}

interface

const
  { Short enough to fit both Linux's 108-byte and BSD/Darwin's 104-byte
    sun_path, and /tmp exists on all three targets. One DAW instance is
    the supported model - "multiple Trackers/Control Stations, one DAW". }
  RemoteSocketPath = '/tmp/dysnomia.sock';

type
  { One note-on at a pattern row, mapped to an absolute frame + sustain by
    the server (see DysRemoteServer's RENDER handler) - the wire form only
    carries Row/Semitone, matching what the Tracker grid actually stores. }
  TDysTrackerNote = record
    Row: Integer;
    Semitone: Integer;
  end;
  TDysTrackerNoteArray = array of TDysTrackerNote;

  TDysRemoteEffectInfo = record
    Kind: Integer;
    Name: string;
  end;
  TDysRemoteEffectArray = array of TDysRemoteEffectInfo;

  { Parsed form of a STATE reply - what DysTrackerApp polls into once per
    Idle tick and renders from, instead of ever touching Project directly
    (it can't - separate process). }
  TDysRemoteState = record
    Valid: Boolean; { False until the first successful GET_STATE round-trip }
    TempoBPM: Single;
    Playing: Boolean;
    Recording: Boolean;
    PlayheadFrame: Int64;
    TrackIndex: Integer;
    IsInstrumentTrack: Boolean;
    TrackName: string;
    Effects: TDysRemoteEffectArray;
  end;

function EncodeGetState: string;
function DecodeState(const ALine: string; out AState: TDysRemoteState): Boolean;
function EncodeState(const AState: TDysRemoteState): string;

function EncodeNoteOn(ASemitone: Integer): string;
function EncodeNoteOff(ASemitone: Integer): string;
function DecodeNoteCmd(const ALine: string; out ASemitone: Integer): Boolean;

function EncodeAddEffect(AKind: Integer): string;
function EncodeRemoveEffect(ASlot: Integer): string;
function EncodeSetEffectParam(ASlot, AParamIndex: Integer; AValue: Single): string;

function EncodeRender(ALengthBars, AStepsPerBar: Integer;
  const ANotes: TDysTrackerNoteArray): string;
function DecodeRender(const ALine: string; out ALengthBars, AStepsPerBar: Integer;
  out ANotes: TDysTrackerNoteArray): Boolean;

function EncodeRenderOK(ASampleID: Integer): string;
function EncodeRenderFail(const AReason: string): string;
function EncodeOK: string;
function EncodeErr(const AReason: string): string;

{ Bare, no-payload transport commands - the Tracker's Play/Record buttons
  send the same start/stop intent the DAW's own transport bar does. No
  encode/decode needed beyond the command word itself, see
  RemoteCommandWord. }
const
  RemoteCmdPlay = 'PLAY';
  RemoteCmdStop = 'STOP';
  RemoteCmdRecord = 'RECORD';

{ First whitespace-delimited word of ALine, uppercased - the command tag
  every handler switches on. }
function RemoteCommandWord(const ALine: string): string;

implementation

uses
  SysUtils;

function RemoteCommandWord(const ALine: string): string;
var
  P: Integer;
begin
  P := Pos(' ', ALine);
  if P = 0 then
    Result := UpperCase(Trim(ALine))
  else
    Result := UpperCase(Copy(ALine, 1, P - 1));
end;

{ Splits ALine on single spaces into AParts, skipping the leading command
  word (ASkipWords fields, e.g. 1 to drop just the tag). Empty fields from
  runs of spaces are dropped - none of this protocol's payloads ever need
  an intentionally-empty field. }
procedure SplitWords(const ALine: string; out AParts: TStringArray);
var
  Raw: TStringArray;
  i, n: Integer;
begin
  Raw := ALine.Split([' ']);
  SetLength(AParts, Length(Raw));
  n := 0;
  for i := 0 to High(Raw) do
    if Raw[i] <> '' then
    begin
      AParts[n] := Raw[i];
      Inc(n);
    end;
  SetLength(AParts, n);
end;

function EncodeGetState: string;
begin
  Result := 'GET_STATE';
end;

function EncodeState(const AState: TDysRemoteState): string;
var
  i: Integer;
  TempoStr, PlayheadStr: string;
begin
  Str(AState.TempoBPM: 0: 3, TempoStr);
  Str(AState.PlayheadFrame, PlayheadStr);
  Result := Format('STATE %s %d %d %s %d %d %s %d', [TempoStr,
    Ord(AState.Playing), Ord(AState.Recording), PlayheadStr,
    AState.TrackIndex, Ord(AState.IsInstrumentTrack),
    StringReplace(AState.TrackName, ' ', '_', [rfReplaceAll]),
    Length(AState.Effects)]);
  for i := 0 to High(AState.Effects) do
    Result := Result + Format(' %d:%s', [AState.Effects[i].Kind,
      StringReplace(AState.Effects[i].Name, ' ', '_', [rfReplaceAll])]);
end;

function DecodeState(const ALine: string; out AState: TDysRemoteState): Boolean;
var
  Parts: TStringArray;
  i, EffCount, ColonPos, Code: Integer;
  EffPart: string;
begin
  FillChar(AState, SizeOf(AState), 0);
  Result := False;
  if RemoteCommandWord(ALine) <> 'STATE' then
    Exit;
  SplitWords(ALine, Parts);
  if Length(Parts) < 8 then
    Exit;
  Val(Parts[1], AState.TempoBPM, Code);
  if Code <> 0 then
    Exit;
  AState.Playing := Parts[2] = '1';
  AState.Recording := Parts[3] = '1';
  Val(Parts[4], AState.PlayheadFrame, Code);
  Val(Parts[5], AState.TrackIndex, Code);
  AState.IsInstrumentTrack := Parts[6] = '1';
  AState.TrackName := StringReplace(Parts[7], '_', ' ', [rfReplaceAll]);
  if Length(Parts) < 9 then
  begin
    AState.Valid := True;
    Result := True;
    Exit;
  end;
  Val(Parts[8], EffCount, Code);
  if Code <> 0 then
    Exit;
  SetLength(AState.Effects, EffCount);
  for i := 0 to EffCount - 1 do
  begin
    if 9 + i > High(Parts) then
      Break;
    EffPart := Parts[9 + i];
    ColonPos := Pos(':', EffPart);
    if ColonPos = 0 then
      Continue;
    Val(Copy(EffPart, 1, ColonPos - 1), AState.Effects[i].Kind, Code);
    AState.Effects[i].Name := StringReplace(Copy(EffPart, ColonPos + 1,
      Length(EffPart)), '_', ' ', [rfReplaceAll]);
  end;
  AState.Valid := True;
  Result := True;
end;

function EncodeNoteOn(ASemitone: Integer): string;
begin
  Result := Format('NOTE_ON %d', [ASemitone]);
end;

function EncodeNoteOff(ASemitone: Integer): string;
begin
  Result := Format('NOTE_OFF %d', [ASemitone]);
end;

function DecodeNoteCmd(const ALine: string; out ASemitone: Integer): Boolean;
var
  Parts: TStringArray;
  Code: Integer;
begin
  Result := False;
  SplitWords(ALine, Parts);
  if Length(Parts) < 2 then
    Exit;
  Val(Parts[1], ASemitone, Code);
  Result := Code = 0;
end;

function EncodeAddEffect(AKind: Integer): string;
begin
  Result := Format('ADD_TRACK_EFFECT %d', [AKind]);
end;

function EncodeRemoveEffect(ASlot: Integer): string;
begin
  Result := Format('REMOVE_TRACK_EFFECT %d', [ASlot]);
end;

function EncodeSetEffectParam(ASlot, AParamIndex: Integer; AValue: Single): string;
var
  ValStr: string;
begin
  Str(AValue: 0: 6, ValStr);
  Result := Format('SET_TRACK_EFFECT_PARAM %d %d %s', [ASlot, AParamIndex, ValStr]);
end;

function EncodeRender(ALengthBars, AStepsPerBar: Integer;
  const ANotes: TDysTrackerNoteArray): string;
var
  i: Integer;
begin
  Result := Format('RENDER %d %d %d', [ALengthBars, AStepsPerBar, Length(ANotes)]);
  for i := 0 to High(ANotes) do
    Result := Result + Format(' %d:%d', [ANotes[i].Row, ANotes[i].Semitone]);
end;

function DecodeRender(const ALine: string; out ALengthBars, AStepsPerBar: Integer;
  out ANotes: TDysTrackerNoteArray): Boolean;
var
  Parts: TStringArray;
  i, NoteCount, ColonPos, Code: Integer;
  NotePart: string;
begin
  Result := False;
  SetLength(ANotes, 0);
  SplitWords(ALine, Parts);
  if Length(Parts) < 4 then
    Exit;
  Val(Parts[1], ALengthBars, Code);
  if Code <> 0 then Exit;
  Val(Parts[2], AStepsPerBar, Code);
  if Code <> 0 then Exit;
  Val(Parts[3], NoteCount, Code);
  if Code <> 0 then Exit;
  SetLength(ANotes, NoteCount);
  for i := 0 to NoteCount - 1 do
  begin
    if 4 + i > High(Parts) then
      Break;
    NotePart := Parts[4 + i];
    ColonPos := Pos(':', NotePart);
    if ColonPos = 0 then
      Continue;
    Val(Copy(NotePart, 1, ColonPos - 1), ANotes[i].Row, Code);
    Val(Copy(NotePart, ColonPos + 1, Length(NotePart)), ANotes[i].Semitone, Code);
  end;
  Result := True;
end;

function EncodeRenderOK(ASampleID: Integer): string;
begin
  Result := Format('RENDER_OK %d', [ASampleID]);
end;

function EncodeRenderFail(const AReason: string): string;
begin
  Result := 'RENDER_FAIL ' + StringReplace(AReason, ' ', '_', [rfReplaceAll]);
end;

function EncodeOK: string;
begin
  Result := 'OK';
end;

function EncodeErr(const AReason: string): string;
begin
  Result := 'ERR ' + StringReplace(AReason, ' ', '_', [rfReplaceAll]);
end;

end.
