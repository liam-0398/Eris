unit AudioBackend;

{$mode objfpc}{$H+}

interface

type
  TAudioOpenFunc = function(ASampleRate, AChannels, ABufferFrames: Integer): Boolean;
  TAudioWriteBlockFunc = function(ABuffer: PSingle; AFrameCount: Integer): Boolean;
  TAudioCloseProc = procedure;

  TAudioBackend = record
    Open: TAudioOpenFunc;
    WriteBlock: TAudioWriteBlockFunc;
    Close: TAudioCloseProc;
  end;

implementation

end.
