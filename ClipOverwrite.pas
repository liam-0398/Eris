unit ClipOverwrite;

{$mode objfpc}{$H+}

interface

uses
  SampleTypes;

function OverwriteClips(const AExisting: TClipArray; ANewPosition,
  ANewLength: Int64): TClipArray;

implementation

function OverwriteClips(const AExisting: TClipArray; ANewPosition,
  ANewLength: Int64): TClipArray;
var
  i, OutCount: Integer;
  Existing, Left, Right: TClip;
  ExistingStart, ExistingEnd, NewEnd: Int64;

  procedure Append(const AClip: TClip);
  begin
    SetLength(Result, OutCount + 1);
    Result[OutCount] := AClip;
    Inc(OutCount);
  end;

begin
  SetLength(Result, 0);
  OutCount := 0;
  NewEnd := ANewPosition + ANewLength;

  for i := 0 to High(AExisting) do
  begin
    Existing := AExisting[i];
    ExistingStart := Existing.Position;
    ExistingEnd := Existing.Position + Existing.Length;

    if (ExistingEnd <= ANewPosition) or (ExistingStart >= NewEnd) then
    begin
      { no overlap - unchanged }
      Append(Existing);
    end
    else if (ExistingStart >= ANewPosition) and (ExistingEnd <= NewEnd) then
    begin
      { fully inside new range - delete }
    end
    else if (ExistingStart < ANewPosition) and (ExistingEnd <= NewEnd) then
    begin
      { overlaps only at its tail - trim length from the end }
      Existing.Length := ANewPosition - ExistingStart;
      Append(Existing);
    end
    else if (ExistingStart >= ANewPosition) and (ExistingEnd > NewEnd) then
    begin
      { overlaps only at its head - trim from the front }
      Existing.Offset := Existing.Offset + (NewEnd - ExistingStart);
      Existing.Position := NewEnd;
      Existing.Length := ExistingEnd - NewEnd;
      Append(Existing);
    end
    else
    begin
      { new range lands entirely inside existing - split into left/right remainders }
      Left := Existing;
      Left.Length := ANewPosition - ExistingStart;

      Right := Existing;
      Right.Offset := Existing.Offset + (NewEnd - ExistingStart);
      Right.Position := NewEnd;
      Right.Length := ExistingEnd - NewEnd;

      if Left.Length > 0 then
        Append(Left);
      if Right.Length > 0 then
        Append(Right);
    end;
  end;
end;

end.
