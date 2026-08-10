unit AudioBackend;

{$mode objfpc}{$H+}

interface

type
  TAudioOpenFunc = function(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
  TAudioWriteBlockFunc = function(ABuffer: PSingle; AFrameCount: Integer): Boolean;
  TAudioCloseProc = procedure;

  { Line-in capture, mirroring Open/WriteBlock/Close above but for input: a
    backend that can't capture (DirectSoundBackend, for now) sets these to a
    stub that always returns False rather than nil, so AudioEngine never has
    to guard the call itself - see that stub for the exact contract. }
  TAudioCaptureOpenFunc = function(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
  TAudioCaptureReadFunc = function(ABuffer: PSingle; AFrameCount: Integer): Boolean;
  TAudioCaptureCloseProc = procedure;

  TAudioBackend = record
    Open: TAudioOpenFunc;
    WriteBlock: TAudioWriteBlockFunc;
    Close: TAudioCloseProc;
    CaptureOpen: TAudioCaptureOpenFunc;
    CaptureRead: TAudioCaptureReadFunc;
    CaptureClose: TAudioCaptureCloseProc;
  end;

implementation

end.
