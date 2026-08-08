unit ClipOverwriteTests;

{$mode objfpc}{$H+}

interface

uses
  fpcunit, testregistry, SampleTypes, ClipOverwrite;

type
  TClipOverwriteTests = class(TTestCase)
  published
    procedure NoOverlapPassesThrough;
    procedure FullyInsideIsDeleted;
    procedure TailOverlapIsTrimmedFromEnd;
    procedure HeadOverlapIsTrimmedFromFront;
    procedure MiddleOverlapSplitsIntoRemainders;
  end;

implementation

function MakeClip(APosition, ALength, AOffset: Int64): TClip;
begin
  Result.SampleID := 0;
  Result.Offset := AOffset;
  Result.Length := ALength;
  Result.Position := APosition;
  Result.TrackID := 0;
  Result.PitchSemitones := 0;
  Result.Gain := 1.0;
end;

procedure TClipOverwriteTests.NoOverlapPassesThrough;
var
  Existing: TClipArray;
  Res: TClipArray;
begin
  SetLength(Existing, 1);
  Existing[0] := MakeClip(0, 100, 0);

  Res := OverwriteClips(Existing, 200, 50);

  AssertEquals('clip count', 1, Length(Res));
  AssertEquals('position unchanged', Int64(0), Res[0].Position);
  AssertEquals('length unchanged', Int64(100), Res[0].Length);
end;

procedure TClipOverwriteTests.FullyInsideIsDeleted;
var
  Existing: TClipArray;
  Res: TClipArray;
begin
  SetLength(Existing, 1);
  Existing[0] := MakeClip(100, 50, 0);

  Res := OverwriteClips(Existing, 90, 100);

  AssertEquals('clip should be deleted', 0, Length(Res));
end;

procedure TClipOverwriteTests.TailOverlapIsTrimmedFromEnd;
var
  Existing: TClipArray;
  Res: TClipArray;
begin
  SetLength(Existing, 1);
  Existing[0] := MakeClip(0, 100, 20);

  { new range starts at 60, existing (0..100) overlaps only at its tail }
  Res := OverwriteClips(Existing, 60, 100);

  AssertEquals('clip count', 1, Length(Res));
  AssertEquals('position unchanged', Int64(0), Res[0].Position);
  AssertEquals('length trimmed to end at new start', Int64(60), Res[0].Length);
  AssertEquals('offset unchanged', Int64(20), Res[0].Offset);
end;

procedure TClipOverwriteTests.HeadOverlapIsTrimmedFromFront;
var
  Existing: TClipArray;
  Res: TClipArray;
begin
  SetLength(Existing, 1);
  Existing[0] := MakeClip(50, 100, 20);

  { new range 0..80, existing (50..150) overlaps only at its head }
  Res := OverwriteClips(Existing, 0, 80);

  AssertEquals('clip count', 1, Length(Res));
  AssertEquals('position moves to new end', Int64(80), Res[0].Position);
  AssertEquals('length shrinks from the front', Int64(70), Res[0].Length);
  AssertEquals('offset advances by trimmed amount', Int64(50), Res[0].Offset);
end;

procedure TClipOverwriteTests.MiddleOverlapSplitsIntoRemainders;
var
  Existing: TClipArray;
  Res: TClipArray;
begin
  SetLength(Existing, 1);
  Existing[0] := MakeClip(0, 200, 10);

  { new range 80..120 lands entirely inside existing (0..200) }
  Res := OverwriteClips(Existing, 80, 40);

  AssertEquals('splits into two remainders', 2, Length(Res));

  AssertEquals('left position', Int64(0), Res[0].Position);
  AssertEquals('left length', Int64(80), Res[0].Length);
  AssertEquals('left offset unchanged', Int64(10), Res[0].Offset);

  AssertEquals('right position', Int64(120), Res[1].Position);
  AssertEquals('right length', Int64(80), Res[1].Length);
  AssertEquals('right offset advances', Int64(130), Res[1].Offset);
end;

initialization
  RegisterTest(TClipOverwriteTests);
end.
