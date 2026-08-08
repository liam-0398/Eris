unit ClipOverwrite;

{$mode objfpc}{$H+}

interface

uses
  SampleTypes, Waveform;

function OverwriteClips(const AExisting: TClipArray; ANewPosition,
  ANewLength: Int64): TClipArray;

implementation

function OverwriteClips(const AExisting: TClipArray; ANewPosition,
  ANewLength: Int64): TClipArray;
var
  i, OutCount: Integer;
  Existing, Left, Right: TClip;
  ExistingStart, ExistingEnd, NewEnd, SplitRel, SplitRel2: Int64;
  DiscardMarkers, KeptMarkers: TWarpMarkerArray;

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
        Offset/Position are unchanged, so this is exactly the left half of a
        split at the trim point - carry over the matching warp markers
        instead of discarding them. }
      { the returned split frame may differ slightly from the requested one
        (see SplitWarpMarkers) - use it for the clip's own geometry too so
        length and markers stay consistent }
      SplitRel := SplitWarpMarkers(Existing.WarpMarkers,
        ANewPosition - ExistingStart, KeptMarkers, DiscardMarkers, Existing.WarpMode);
      Existing.WarpMarkers := KeptMarkers;
      Existing.Length := SplitRel;
      Append(Existing);
    end
    else if (ExistingStart >= ANewPosition) and (ExistingEnd > NewEnd) then
    begin
      { overlaps only at its head - trim from the front. Offset/Position
        move forward, so this is exactly the right half of a split at the
        trim point - carry over the matching (rebased) warp markers. }
      SplitRel := SplitWarpMarkers(Existing.WarpMarkers,
        NewEnd - ExistingStart, DiscardMarkers, KeptMarkers, Existing.WarpMode);
      Existing.WarpMarkers := KeptMarkers;
      Existing.Offset := Existing.Offset + SplitRel;
      Existing.Position := ExistingStart + SplitRel;
      Existing.Length := ExistingEnd - (ExistingStart + SplitRel);
      Append(Existing);
    end
    else
    begin
      { new range lands entirely inside existing - split into left/right
        remainders, each keeping its own matching half of the warp markers }
      Left := Existing;
      SplitRel := SplitWarpMarkers(Existing.WarpMarkers,
        ANewPosition - ExistingStart, Left.WarpMarkers, DiscardMarkers, Existing.WarpMode);
      Left.Length := SplitRel;

      Right := Existing;
      SplitRel2 := SplitWarpMarkers(Existing.WarpMarkers,
        NewEnd - ExistingStart, DiscardMarkers, Right.WarpMarkers, Existing.WarpMode);
      Right.Offset := Existing.Offset + SplitRel2;
      Right.Position := ExistingStart + SplitRel2;
      Right.Length := ExistingEnd - (ExistingStart + SplitRel2);

      if Left.Length > 0 then
        Append(Left);
      if Right.Length > 0 then
        Append(Right);
    end;
  end;
end;

end.
