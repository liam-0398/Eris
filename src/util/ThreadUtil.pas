unit ThreadUtil;

{$mode objfpc}{$H+}

interface

{ Worker-thread fan-out cap for CPU-bound background jobs (sample decode,
  project load/save/render): hardware thread count minus one, so the UI
  thread and the realtime audio callback thread each keep a core free,
  with a floor of 2 so a dual-core machine (2-1=1) still gets to run work
  in parallel rather than falling back to serial. }
function WorkerThreadCap: Integer;

implementation

uses
  Classes;

function WorkerThreadCap: Integer;
begin
  Result := TThread.ProcessorCount - 1;
  if Result < 2 then
    Result := 2;
end;

end.
