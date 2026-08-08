unit EffectsRack;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, StdCtrls, ComCtrls, ExtCtrls, Graphics, Effects,
  Project;

type
  TEffectRackChangedEvent = procedure(Sender: TObject) of object;

  { one effect's widget box - a plain TPanel populated with whichever native
    controls its Kind needs, wired directly to Project.TrackEffects }
  TEffectWidget = class(TPanel)
  private
    FTrackIndex: Integer;
    FEffectIndex: Integer;
    FOnRackChanged: TEffectRackChangedEvent;
    FLPSlider: TTrackBar;
    FEQFreqEdit: array[0..Effects.MaxEQBands - 1] of TEdit;
    FEQGainSlider: array[0..Effects.MaxEQBands - 1] of TTrackBar;
    procedure DeleteClick(Sender: TObject);
    procedure LPSliderChange(Sender: TObject);
    procedure EQFreqEditDone(Sender: TObject);
    procedure EQGainSliderChange(Sender: TObject);
    procedure BuildLowpass;
    procedure BuildEQ4;
  public
    constructor CreateFor(AOwner: TComponent; AParent: TWinControl;
      ATrackIndex, AEffectIndex: Integer; AOnRackChanged: TEffectRackChangedEvent);
  end;

const
  LPMinHz = 20.0;
  LPMaxHz = 20000.0;
  EQMinGainDb = -12;
  EQMaxGainDb = 12;

implementation

function FreqToLogSlider(AFreqHz: Single): Integer;
begin
  Result := Round(100 * (Ln(AFreqHz / LPMinHz) / Ln(LPMaxHz / LPMinHz)));
  if Result < 0 then Result := 0;
  if Result > 100 then Result := 100;
end;

function LogSliderToFreq(APos: Integer): Single;
begin
  Result := LPMinHz * Exp((APos / 100) * Ln(LPMaxHz / LPMinHz));
end;

constructor TEffectWidget.CreateFor(AOwner: TComponent; AParent: TWinControl;
  ATrackIndex, AEffectIndex: Integer; AOnRackChanged: TEffectRackChangedEvent);
var
  DeleteButton: TButton;
  TitleLabel: TLabel;
  Kind: Integer;
begin
  inherited Create(AOwner);
  FTrackIndex := ATrackIndex;
  FEffectIndex := AEffectIndex;
  FOnRackChanged := AOnRackChanged;
  Parent := AParent;
  BevelOuter := bvRaised;
  Height := 144;

  Kind := Project.TrackEffects[ATrackIndex][AEffectIndex].Kind;

  TitleLabel := TLabel.Create(AOwner);
  TitleLabel.Parent := Self;
  TitleLabel.Left := 6;
  TitleLabel.Top := 6;
  if Kind = Effects.ekEQ4 then
    TitleLabel.Caption := '4'
  else
    TitleLabel.Caption := 'LP';

  DeleteButton := TButton.Create(AOwner);
  DeleteButton.Parent := Self;
  DeleteButton.Caption := 'X';
  DeleteButton.Width := 20;
  DeleteButton.Height := 20;
  DeleteButton.Top := 4;
  DeleteButton.OnClick := @DeleteClick;

  case Kind of
    Effects.ekLowpass:
      begin
        Width := 140;
        DeleteButton.Left := Width - 24;
        BuildLowpass;
      end;
    Effects.ekEQ4:
      begin
        Width := 200;
        DeleteButton.Left := Width - 24;
        BuildEQ4;
      end;
  end;
end;

procedure TEffectWidget.BuildLowpass;
var
  Lbl: TLabel;
begin
  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := 8;
  Lbl.Top := 32;
  Lbl.Caption := 'Cutoff';

  FLPSlider := TTrackBar.Create(Owner);
  FLPSlider.Parent := Self;
  FLPSlider.Left := 4;
  FLPSlider.Top := 52;
  FLPSlider.Width := Width - 12;
  FLPSlider.Height := 40;
  FLPSlider.Min := 0;
  FLPSlider.Max := 100;
  FLPSlider.Position := FreqToLogSlider(Project.TrackEffects[FTrackIndex][FEffectIndex].LowpassFreqHz);
  FLPSlider.ShowHint := True;
  FLPSlider.Hint := 'Lowpass cutoff frequency';
  FLPSlider.OnChange := @LPSliderChange;
end;

procedure TEffectWidget.BuildEQ4;
var
  b, bx: Integer;
begin
  for b := 0 to Effects.MaxEQBands - 1 do
  begin
    bx := 6 + b * 46;

    FEQFreqEdit[b] := TEdit.Create(Owner);
    FEQFreqEdit[b].Parent := Self;
    FEQFreqEdit[b].Left := bx;
    FEQFreqEdit[b].Top := 30;
    FEQFreqEdit[b].Width := 42;
    FEQFreqEdit[b].Text := IntToStr(Round(Project.TrackEffects[FTrackIndex][FEffectIndex].EQFreqHz[b]));
    FEQFreqEdit[b].Tag := b;
    FEQFreqEdit[b].OnEditingDone := @EQFreqEditDone;

    FEQGainSlider[b] := TTrackBar.Create(Owner);
    FEQGainSlider[b].Parent := Self;
    FEQGainSlider[b].Left := bx;
    FEQGainSlider[b].Top := 56;
    FEQGainSlider[b].Width := 42;
    FEQGainSlider[b].Height := 84;
    FEQGainSlider[b].Orientation := trVertical;
    FEQGainSlider[b].Min := EQMinGainDb;
    FEQGainSlider[b].Max := EQMaxGainDb;
    FEQGainSlider[b].Position := Round(Project.TrackEffects[FTrackIndex][FEffectIndex].EQGainDb[b]);
    FEQGainSlider[b].Tag := b;
    FEQGainSlider[b].ShowHint := True;
    FEQGainSlider[b].Hint := 'Band gain (dB)';
    FEQGainSlider[b].OnChange := @EQGainSliderChange;
  end;
end;

procedure TEffectWidget.DeleteClick(Sender: TObject);
begin
  Project.RemoveTrackEffect(FTrackIndex, FEffectIndex);
  if Assigned(FOnRackChanged) then
    FOnRackChanged(Self);
end;

procedure TEffectWidget.LPSliderChange(Sender: TObject);
begin
  Project.TrackEffects[FTrackIndex][FEffectIndex].LowpassFreqHz :=
    LogSliderToFreq(FLPSlider.Position);
end;

procedure TEffectWidget.EQFreqEditDone(Sender: TObject);
var
  b: Integer;
  Value: Integer;
begin
  b := (Sender as TEdit).Tag;
  if not TryStrToInt(Trim((Sender as TEdit).Text), Value) then
    Value := Round(Project.TrackEffects[FTrackIndex][FEffectIndex].EQFreqHz[b]);
  if Value < Round(LPMinHz) then Value := Round(LPMinHz);
  if Value > Round(LPMaxHz) then Value := Round(LPMaxHz);
  (Sender as TEdit).Text := IntToStr(Value);
  Project.TrackEffects[FTrackIndex][FEffectIndex].EQFreqHz[b] := Value;
end;

procedure TEffectWidget.EQGainSliderChange(Sender: TObject);
var
  b: Integer;
begin
  b := (Sender as TTrackBar).Tag;
  Project.TrackEffects[FTrackIndex][FEffectIndex].EQGainDb[b] :=
    (Sender as TTrackBar).Position;
end;

end.
