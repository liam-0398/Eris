unit DysRemoteServer;

{ DAW-side half of the socket link described in tui.md's Tracker section.
  One accept-loop thread plus one handler thread per connected client
  (currently only DysTrackerApp connects). GET_STATE replies are read-only
  snapshots taken directly off Project/AudioEngine from the client thread -
  safe the same way the audio thread's own concurrent reads already are,
  no new locking needed for reads. Every command that WRITES project state
  (notes, effect add/remove, render) is queued here and only actually
  applied once per TDysnomiaApp.Idle tick by DysRemoteDrainQueue, running
  on the main thread, through the same calls the UI itself already uses -
  never applied directly from a socket thread, which would race the UI
  thread's own writes.

  Uses FPC's Sockets unit (packages/rtl-extra/src/unix) - its string-address
  Bind/Connect/Accept overloads are Unix-domain sockets specifically
  (Str2UnixSockAddr, sockovl.inc), and the OS-specific sockaddr layout
  difference between Linux and BSD/Darwin (the extra sa_len byte on the
  BSD family, SOCK_HAS_SINLEN) is already handled inside that unit per
  target - nothing Dysnomia has to special-case itself, same shape as the
  MaxCols DARWIN ifdef story in tui.md's Terminal geometry section. }

{$mode objfpc}{$H+}

interface

uses
  DysRemoteProtocol;

type
  TDysRemoteCommandKind = (rcNoteOn, rcNoteOff, rcAddEffect, rcRemoveEffect,
    rcSetEffectParam, rcRender, rcPlay, rcStop, rcRecord);

{ Started from TDysnomiaApp.Init, stopped from Done. A bind failure (socket
  path already held - another DAW instance, or a stale file left behind by
  a crash) is reported via DysRemoteServerRunning=False and
  DysRemoteServerLastError, never an exception: the DAW must run standalone
  with no Tracker/Control Station attached just as well as with one. }
procedure DysRemoteServerStart;
procedure DysRemoteServerStop;
function DysRemoteServerRunning: Boolean;
function DysRemoteServerLastError: string;

{ Drains every command a client thread queued since the last call and
  applies it via the DAW's own existing calls. Call once per
  TDysnomiaApp.Idle tick, main thread only. }
procedure DysRemoteDrainQueue;

implementation

uses
  SysUtils, Classes, Math, Sockets, BaseUnix,
  Project, AudioEngine, Resample, SampleTypes,
  DysTrackPane, DysTimeline, DysWidgets, DysEffectsRack;

type
  TDysRemoteCommand = record
    Kind: TDysRemoteCommandKind;
    Semitone: Integer;         { rcNoteOn/rcNoteOff }
    EffectSlot: Integer;       { rcRemoveEffect/rcSetEffectParam }
    EffectKind: Integer;       { rcAddEffect }
    LengthBars, StepsPerBar: Integer; { rcRender }
    Notes: TDysTrackerNoteArray;      { rcRender }
    Done: PRTLEvent;           { rcRender only - client thread blocks on
                                  this until the main thread's Idle tick
                                  has actually rendered and committed the
                                  clip, since only that thread can safely
                                  touch Project }
    ResultOK: Boolean;
    ResultSampleID: Integer;
    ResultReason: string;
  end;

var
  ListenSock: cint = -1;
  AcceptThread: TThread = nil;
  Running: Boolean = False;
  LastError: string = '';
  QueueLock: TRTLCriticalSection;
  Queue: array of TDysRemoteCommand;

procedure PushCommand(const ACmd: TDysRemoteCommand);
begin
  EnterCriticalSection(QueueLock);
  try
    SetLength(Queue, Length(Queue) + 1);
    Queue[High(Queue)] := ACmd;
  finally
    LeaveCriticalSection(QueueLock);
  end;
end;

{ Read-only - safe from any thread, see unit doc comment. }
function BuildRemoteState: TDysRemoteState;
var
  Track, i: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Valid := True;
  Result.TempoBPM := Project.TempoBPM;
  Result.Playing := AudioEngineIsPlaying;
  Result.Recording := AudioEngineRecordState = RecordStateRecording;
  Result.PlayheadFrame := AudioEngineGetPosition;
  Track := SelectedTrackIndex;
  Result.TrackIndex := Track;
  if (Track >= 0) and (Track <= High(Project.TrackInstrument)) then
  begin
    Result.IsInstrumentTrack := Project.TrackInstrument[Track] >= 0;
    Result.TrackName := 'Track ' + IntToStr(Track + 1);
    SetLength(Result.Effects, Project.TrackEffectCount[Track]);
    for i := 0 to Project.TrackEffectCount[Track] - 1 do
    begin
      Result.Effects[i].Kind := Project.TrackEffects[Track, i].Kind;
      Result.Effects[i].Name := DysEffectKindName(Project.TrackEffects[Track, i].Kind);
    end;
  end
  else
  begin
    Result.TrackIndex := -1;
    Result.TrackName := '';
  end;
end;

{ One TClip covering [ARow, ANextRow) worth of a single note, synthesized
  offline into ADest starting at AWriteFrame - same resample primitive
  (Resample.SemitonesToRate + Resample.Interpolate) AudioEngineTriggerNoteRT
  uses for the realtime instrument keyboard, just walked by hand into a
  buffer instead of into the live output. Mirrors TriggerDysKeyboardNote's
  (DysEffectsRack.pas) own instrument-sample/gain/octave field reads so a
  rendered note matches what playing it live would have sounded like. }
procedure RenderNoteInto(ADest: PSingle; ADestFrameCount: Integer;
  AWriteFrame, ASustainFrames: Int64; ATrackIndex, ASemitone: Integer);
var
  Sample: TSample;
  StartFrame, EndFrame, TrimmedCount: Int64;
  Rate, Pos: Double;
  Gain: Single;
  TotalOffset: Integer;
  OutFrame: Int64;
  Ch: Integer;
  SrcPtr: PSingle;
begin
  if (ATrackIndex < 0) or (ATrackIndex > High(Project.TrackInstrument)) then
    Exit;
  if Project.TrackInstrument[ATrackIndex] < 0 then
    Exit;
  Sample := Project.SamplePool[Project.TrackInstrument[ATrackIndex]];
  StartFrame := Project.TrackInstrumentStart[ATrackIndex];
  EndFrame := Project.TrackInstrumentEnd[ATrackIndex];
  if StartFrame < 0 then StartFrame := 0;
  if (EndFrame <= 0) or (EndFrame > Sample.FrameCount) then
    EndFrame := Sample.FrameCount;
  TrimmedCount := EndFrame - StartFrame;
  if TrimmedCount <= 0 then Exit;

  TotalOffset := ASemitone + Project.TrackOctave[ATrackIndex] * 12;
  Rate := SemitonesToRate(TotalOffset);
  Gain := Power(10, Project.TrackInstrumentGainDb[ATrackIndex] / 20);
  SrcPtr := @Sample.Data[StartFrame * Sample.Channels];

  Pos := 0;
  OutFrame := AWriteFrame;
  while (OutFrame < AWriteFrame + ASustainFrames) and (OutFrame < ADestFrameCount)
    and (Pos < TrimmedCount) do
  begin
    if OutFrame >= 0 then
      for Ch := 0 to 1 do
        ADest[OutFrame * 2 + Ch] := ADest[OutFrame * 2 + Ch] +
          Gain * Interpolate(SrcPtr, TrimmedCount, Sample.Channels,
            Ch mod Sample.Channels, Pos);
    Pos := Pos + Rate;
    Inc(OutFrame);
  end;
end;

{ Applies rcRender: synthesizes the whole pattern into one offline buffer,
  pools it and commits a TClip at the DAW timeline's cursor on the
  DAW-selected track - same field set/call sequence DysTimeline.
  DysFinalizeRecording already uses to turn a live take into a clip
  (AddSampleToPool -> fill TClip -> CommitClipToTrack -> PushTrackToEngine),
  just fed synthesized audio instead of a captured recording. Main thread
  only - touches Project. }
procedure ApplyRender(var ACmd: TDysRemoteCommand);
var
  Track: Integer;
  BeatFrames, TotalFrames: Int64;
  StepFrames: Int64;
  Buffer: PSingle;
  Sample: TSample;
  NewClip: TClip;
  i, NextRow, SustainSteps: Integer;
  WriteFrame, SustainFrames: Int64;
  CursorFrame: Int64;
begin
  Track := SelectedTrackIndex;
  ACmd.ResultOK := False;
  if (Track < 0) or (Project.TrackInstrument[Track] < 0) then
  begin
    ACmd.ResultReason := 'no instrument on selected track';
    Exit;
  end;
  if Length(ACmd.Notes) = 0 then
  begin
    ACmd.ResultReason := 'empty pattern';
    Exit;
  end;
  if ACmd.StepsPerBar <= 0 then ACmd.StepsPerBar := 16;
  if ACmd.LengthBars <= 0 then ACmd.LengthBars := 4;

  BeatFrames := Round((AudioEngine.ProjectSampleRate * 60) / Project.TempoBPM);
  { 4/4 throughout this codebase - see tui.md's own note on 'w'/'l' using
    the same assumption, there is no time-signature field anywhere. }
  StepFrames := (BeatFrames * 4) div ACmd.StepsPerBar;
  TotalFrames := StepFrames * ACmd.StepsPerBar * ACmd.LengthBars;
  if TotalFrames <= 0 then
  begin
    ACmd.ResultReason := 'zero-length pattern';
    Exit;
  end;

  Buffer := GetMem(TotalFrames * 2 * SizeOf(Single));
  FillChar(Buffer^, TotalFrames * 2 * SizeOf(Single), 0);

  for i := 0 to High(ACmd.Notes) do
  begin
    WriteFrame := ACmd.Notes[i].Row * StepFrames;
    { Sustain to the next note-on in the pattern (regardless of row order
      in the wire message - find the nearest strictly-later row), or to
      the pattern's own end if this is the last note. }
    NextRow := ACmd.StepsPerBar * ACmd.LengthBars;
    for SustainSteps := 0 to High(ACmd.Notes) do
      if (ACmd.Notes[SustainSteps].Row > ACmd.Notes[i].Row) and
         (ACmd.Notes[SustainSteps].Row < NextRow) then
        NextRow := ACmd.Notes[SustainSteps].Row;
    SustainFrames := (NextRow * StepFrames) - WriteFrame;
    if SustainFrames > 0 then
      RenderNoteInto(Buffer, TotalFrames, WriteFrame, SustainFrames,
        Track, ACmd.Notes[i].Semitone);
  end;

  FillChar(Sample, SizeOf(Sample), 0);
  Sample.Data := Buffer;
  Sample.FrameCount := TotalFrames;
  Sample.Channels := 2;
  Sample.SampleRate := AudioEngine.ProjectSampleRate;
  Sample.BaseNote := 60.0;

  FillChar(NewClip, SizeOf(NewClip), 0);
  NewClip.SampleID := Project.AddSampleToPool(Sample,
    'Tracker ' + IntToStr(Length(Project.SamplePool)), '');
  NewClip.Offset := 0;
  NewClip.Length := TotalFrames;
  CursorFrame := 0;
  if ActiveTimelineContent <> nil then
    CursorFrame := ActiveTimelineContent^.CursorFrame;
  NewClip.Position := CursorFrame;
  NewClip.TrackID := Track;
  NewClip.Gain := 1.0;
  NewClip.PitchSemitones := 0;
  NewClip.WarpMode := WarpModeBeats;

  Project.PushUndoSnapshot(Track);
  Project.CommitClipToTrack(Track, NewClip);
  PushTrackToEngine(Track);

  ACmd.ResultOK := True;
  ACmd.ResultSampleID := NewClip.SampleID;
end;

procedure DysRemoteDrainQueue;
var
  Local: array of TDysRemoteCommand;
  i: Integer;
begin
  EnterCriticalSection(QueueLock);
  try
    Local := Queue;
    SetLength(Queue, 0);
  finally
    LeaveCriticalSection(QueueLock);
  end;
  for i := 0 to High(Local) do
  begin
    case Local[i].Kind of
      rcNoteOn:
        if Assigned(TriggerKeyboardNoteProc) then
          TriggerKeyboardNoteProc(Local[i].Semitone);
      rcNoteOff: ; { no note-off concept on the realtime keyboard path -
                      notes are one-shot triggers, same as the instrument
                      keyboard itself (see DysKeyToSemitoneOffset callers) }
      rcAddEffect:
        if SelectedTrackIndex >= 0 then
          Project.AddTrackEffect(SelectedTrackIndex, Local[i].EffectKind);
      rcRemoveEffect:
        if SelectedTrackIndex >= 0 then
          Project.RemoveTrackEffect(SelectedTrackIndex, Local[i].EffectSlot);
      rcSetEffectParam: ; { not implemented yet - see tui.md's Tracker
                             section: needs TDysEffectBox.BuildParams'
                             per-effect-kind field table factored out into
                             something both the local UI and this remote
                             path can share, future work }
      rcRender: ApplyRender(Local[i]);
      rcPlay:
        begin
          if ActiveTimelineContent <> nil then
            AudioEngineSeek(ActiveTimelineContent^.CursorFrame);
          AudioEnginePlay;
        end;
      rcStop: AudioEngineStop;
      rcRecord: DysStartRecording;
    end;
    if Assigned(Local[i].Done) then
      RTLEventSetEvent(Local[i].Done);
  end;
end;

{ One handler thread per connected client - blocking line loop. }
type
  TDysRemoteClientThread = class(TThread)
  private
    FSockIn, FSockOut: Text;
  protected
    procedure Execute; override;
  end;

procedure TDysRemoteClientThread.Execute;
var
  Line: string;
  State: TDysRemoteState;
  Semitone, Kind, Slot, LengthBars, StepsPerBar, Code: Integer;
  Notes: TDysTrackerNoteArray;
  Cmd: TDysRemoteCommand;
  Word: string;
begin
  while not Terminated do
  begin
    {$I-}
    ReadLn(FSockIn, Line);
    {$I+}
    if IOResult <> 0 then
      Break;
    Word := RemoteCommandWord(Line);
    if Word = 'GET_STATE' then
    begin
      State := BuildRemoteState;
      WriteLn(FSockOut, EncodeState(State));
      Flush(FSockOut);
    end
    else if (Word = 'NOTE_ON') or (Word = 'NOTE_OFF') then
    begin
      if DecodeNoteCmd(Line, Semitone) then
      begin
        FillChar(Cmd, SizeOf(Cmd), 0);
        if Word = 'NOTE_ON' then Cmd.Kind := rcNoteOn else Cmd.Kind := rcNoteOff;
        Cmd.Semitone := Semitone;
        PushCommand(Cmd);
      end;
      WriteLn(FSockOut, EncodeOK);
      Flush(FSockOut);
    end
    else if Word = 'ADD_TRACK_EFFECT' then
    begin
      Val(Copy(Line, Length('ADD_TRACK_EFFECT ') + 1, Length(Line)), Kind, Code);
      if Code = 0 then
      begin
        FillChar(Cmd, SizeOf(Cmd), 0);
        Cmd.Kind := rcAddEffect;
        Cmd.EffectKind := Kind;
        PushCommand(Cmd);
      end;
      WriteLn(FSockOut, EncodeOK);
      Flush(FSockOut);
    end
    else if Word = 'REMOVE_TRACK_EFFECT' then
    begin
      Val(Copy(Line, Length('REMOVE_TRACK_EFFECT ') + 1, Length(Line)), Slot, Code);
      if Code = 0 then
      begin
        FillChar(Cmd, SizeOf(Cmd), 0);
        Cmd.Kind := rcRemoveEffect;
        Cmd.EffectSlot := Slot;
        PushCommand(Cmd);
      end;
      WriteLn(FSockOut, EncodeOK);
      Flush(FSockOut);
    end
    else if (Word = RemoteCmdPlay) or (Word = RemoteCmdStop) or (Word = RemoteCmdRecord) then
    begin
      FillChar(Cmd, SizeOf(Cmd), 0);
      if Word = RemoteCmdPlay then Cmd.Kind := rcPlay
      else if Word = RemoteCmdStop then Cmd.Kind := rcStop
      else Cmd.Kind := rcRecord;
      PushCommand(Cmd);
      WriteLn(FSockOut, EncodeOK);
      Flush(FSockOut);
    end
    else if Word = 'SET_TRACK_EFFECT_PARAM' then
    begin
      { Acknowledged but not yet applied - see DysRemoteDrainQueue's
        rcSetEffectParam comment. }
      WriteLn(FSockOut, EncodeErr('not_implemented'));
      Flush(FSockOut);
    end
    else if Word = 'RENDER' then
    begin
      if DecodeRender(Line, LengthBars, StepsPerBar, Notes) then
      begin
        FillChar(Cmd, SizeOf(Cmd), 0);
        Cmd.Kind := rcRender;
        Cmd.LengthBars := LengthBars;
        Cmd.StepsPerBar := StepsPerBar;
        Cmd.Notes := Notes;
        Cmd.Done := RTLEventCreate;
        PushCommand(Cmd);
        { Block until the main thread's Idle tick actually renders and
          commits the clip - only that thread may touch Project, and the
          client needs the real sample id before it can report success. }
        RTLEventWaitFor(Cmd.Done);
        RTLEventDestroy(Cmd.Done);
        if Cmd.ResultOK then
          WriteLn(FSockOut, EncodeRenderOK(Cmd.ResultSampleID))
        else
          WriteLn(FSockOut, EncodeRenderFail(Cmd.ResultReason));
      end
      else
        WriteLn(FSockOut, EncodeRenderFail('bad_request'));
      Flush(FSockOut);
    end
    else
    begin
      WriteLn(FSockOut, EncodeErr('unknown_command'));
      Flush(FSockOut);
    end;
  end;
  {$I-}
  Close(FSockIn);
  Close(FSockOut);
  {$I+}
  IOResult;
end;

type
  TDysRemoteAcceptThread = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TDysRemoteAcceptThread.Execute;
var
  ClientSock: cint;
  Client: TDysRemoteClientThread;
begin
  while not Terminated do
  begin
    ClientSock := fpAccept(ListenSock, nil, nil);
    if Terminated then Break;
    if ClientSock < 0 then Continue;
    Client := TDysRemoteClientThread.Create(True);
    Client.FreeOnTerminate := True;
    Sock2Text(ClientSock, Client.FSockIn, Client.FSockOut);
    Client.Start;
  end;
end;

procedure DysRemoteServerStart;
begin
  InitCriticalSection(QueueLock);
  SetLength(Queue, 0);
  LastError := '';
  Running := False;

  ListenSock := fpsocket(AF_UNIX, SOCK_STREAM, 0);
  if ListenSock < 0 then
  begin
    LastError := 'socket() failed';
    Exit;
  end;

  { Remove a stale socket file from a previous crashed instance - a fresh
    Bind on an existing path fails EADDRINUSE otherwise. Harmless if the
    path doesn't exist (FpUnlink's error is simply ignored). }
  FpUnlink(RemoteSocketPath);

  if not Sockets.Bind(ListenSock, RemoteSocketPath) then
  begin
    LastError := 'bind() failed - another DAW instance running?';
    CloseSocket(ListenSock);
    ListenSock := -1;
    Exit;
  end;

  if fplisten(ListenSock, 8) <> 0 then
  begin
    LastError := 'listen() failed';
    CloseSocket(ListenSock);
    ListenSock := -1;
    Exit;
  end;

  Running := True;
  AcceptThread := TDysRemoteAcceptThread.Create(False);
end;

procedure DysRemoteServerStop;
var
  WakeSock: cint;
  WakeIn: Text;
  WakeOut: Text;
begin
  if not Running then Exit;
  Running := False;
  if Assigned(AcceptThread) then
  begin
    AcceptThread.Terminate;
    { fpAccept is blocked in the accept thread - CloseSocket(ListenSock)
      alone does not reliably unblock a concurrent blocking accept() on
      Linux (POSIX leaves a close() racing another thread's blocking call
      on the same fd undefined; this hung indefinitely in practice, which
      is what made Alt+X/File>Exit look broken - the main loop had already
      exited cleanly and was stuck here in shutdown). Waking it with a
      throwaway self-connect is the portable fix: Execute already checks
      Terminated immediately after fpAccept returns and breaks before ever
      touching the connection, so this dummy client is simply dropped. }
    WakeSock := fpsocket(AF_UNIX, SOCK_STREAM, 0);
    if WakeSock >= 0 then
    begin
      if Sockets.Connect(WakeSock, RemoteSocketPath, WakeIn, WakeOut) then
      begin
        CloseFile(WakeIn);
        CloseFile(WakeOut);
      end
      else
        CloseSocket(WakeSock);
    end;
    AcceptThread.WaitFor;
    AcceptThread.Free;
    AcceptThread := nil;
  end;
  if ListenSock >= 0 then
    CloseSocket(ListenSock);
  ListenSock := -1;
  FpUnlink(RemoteSocketPath);
  DoneCriticalSection(QueueLock);
end;

function DysRemoteServerRunning: Boolean;
begin
  Result := Running;
end;

function DysRemoteServerLastError: string;
begin
  Result := LastError;
end;

end.
