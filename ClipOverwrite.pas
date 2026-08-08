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
      { overlaps only at its tail - trim length from the end.
        Offset/Position are unchanged but Length shrinks, which can
        invalidate warp marker positions, so the trimmed clip reverts
        to unwarped (1:1) playback. }
      Existing.Length := ANewPosition - ExistingStart;
      Existing.WarpMarkers := nil;
      Append(Existing);
    end
    else if (ExistingStart >= ANewPosition) and (ExistingEnd > NewEnd) then
    begin
      { overlaps only at its head - trim from the front. Offset changes, so
        any warp markers (relative to the old Offset) no longer apply. }
      Existing.Offset := Existing.Offset + (NewEnd - ExistingStart);
      Existing.Position := NewEnd;
      Existing.Length := ExistingEnd - NewEnd;
      Existing.WarpMarkers := nil;
      Append(Existing);
    end
    else
    begin
      { new range lands entirely inside existing - split into left/right
        remainders, both unwarped for the same reason as above }
      Left := Existing;
      Left.Length := ANewPosition - ExistingStart;
      Left.WarpMarkers := nil;

      Right := Existing;
      Right.Offset := Existing.Offset + (NewEnd - ExistingStart);
      Right.Position := NewEnd;
      Right.Length := ExistingEnd - NewEnd;
      Right.WarpMarkers := nil;

      if Left.Length > 0 then
        Append(Left);
      if Right.Length > 0 then
        Append(Right);
    end;
  end;
end;

end.
