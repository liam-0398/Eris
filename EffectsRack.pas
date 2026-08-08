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
    FLPValueLabel: TLabel;
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
  { shared sizing so every effect box lines up with the others in the rack
    and with the rest of the bottom bar's widgets }
  WidgetHeight = 180;
  EQBandWidth = 56;
  EQBandGap = 6;
  EQLeftMargin = 8;

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
  Height := WidgetHeight;

  Kind := Project.TrackEffects[ATrackIndex][AEffectIndex].Kind;

  TitleLabel := TLabel.Create(AOwner);
  TitleLabel.Parent := Self;
  TitleLabel.Left := 8;
  TitleLabel.Top := 8;
  TitleLabel.Font.Style := [fsBold];
  if Kind = Effects.ekEQ4 then
    TitleLabel.Caption := 'EQ 4'
  else
    TitleLabel.Caption := 'LP';

  DeleteButton := TButton.Create(AOwner);
  DeleteButton.Parent := Self;
  DeleteButton.Caption := 'X';
  DeleteButton.Width := 22;
  DeleteButton.Height := 22;
  DeleteButton.Top := 6;
  DeleteButton.OnClick := @DeleteClick;

  case Kind of
    Effects.ekLowpass:
      begin
        Width := 200;
        DeleteButton.Left := Width - 28;
        BuildLowpass;
      end;
    Effects.ekEQ4:
      begin
        Width := EQLeftMargin + Effects.MaxEQBands * (EQBandWidth + EQBandGap) + EQLeftMargin;
        DeleteButton.Left := Width - 28;
        BuildEQ4;
      end;
  end;
end;

procedure TEffectWidget.BuildLowpass;
var
  Lbl: TLabel;
begin
  { row 1 (title/delete) already placed by CreateFor; everything below is
    one clean top-to-bottom flow: description -> slider -> live readout }
  Lbl := TLabel.Create(Owner);
  Lbl.Parent := Self;
  Lbl.Left := 8;
  Lbl.Top := 40;
  Lbl.Caption := 'Cutoff frequency';

  FLPSlider := TTrackBar.Create(Owner);
  FLPSlider.Parent := Self;
  FLPSlider.Left := 8;
  FLPSlider.Top := 64;
  FLPSlider.Width := Width - 16;
  FLPSlider.Height := 60;
  FLPSlider.Min := 0;
  FLPSlider.Max := 100;
  FLPSlider.Position := FreqToLogSlider(Project.TrackEffects[FTrackIndex][FEffectIndex].LowpassFreqHz);
  FLPSlider.OnChange := @LPSliderChange;

  FLPValueLabel := TLabel.Create(Owner);
  FLPValueLabel.Parent := Self;
  FLPValueLabel.Left := 8;
  FLPValueLabel.Top := 132;
  FLPValueLabel.Caption := Format('%d Hz',
    [Round(Project.TrackEffects[FTrackIndex][FEffectIndex].LowpassFreqHz)]);
end;

procedure TEffectWidget.BuildEQ4;
var
  b, bx: Integer;
  FreqRowLabel, GainRowLabel: TLabel;
begin
  { logical top-to-bottom flow: a labeled row of frequency inputs, then a
    labeled row of vertical gain sliders directly below their own band }
  FreqRowLabel := TLabel.Create(Owner);
  FreqRowLabel.Parent := Self;
  FreqRowLabel.Left := EQLeftMargin;
  FreqRowLabel.Top := 38;
  FreqRowLabel.Caption := 'Freq (Hz)';

  GainRowLabel := TLabel.Create(Owner);
  GainRowLabel.Parent := Self;
  GainRowLabel.Left := EQLeftMargin;
  GainRowLabel.Top := 92;
  GainRowLabel.Caption := 'Gain (dB)';

  for b := 0 to Effects.MaxEQBands - 1 do
  begin
    bx := EQLeftMargin + b * (EQBandWidth + EQBandGap);

    FEQFreqEdit[b] := TEdit.Create(Owner);
    FEQFreqEdit[b].Parent := Self;
    FEQFreqEdit[b].Left := bx;
    FEQFreqEdit[b].Top := 58;
    FEQFreqEdit[b].Width := EQBandWidth;
    FEQFreqEdit[b].Height := 26;
    FEQFreqEdit[b].Text := IntToStr(Round(Project.TrackEffects[FTrackIndex][FEffectIndex].EQFreqHz[b]));
    FEQFreqEdit[b].Tag := b;
    FEQFreqEdit[b].OnEditingDone := @EQFreqEditDone;

    FEQGainSlider[b] := TTrackBar.Create(Owner);
    FEQGainSlider[b].Parent := Self;
    FEQGainSlider[b].Left := bx;
    FEQGainSlider[b].Top := 112;
    FEQGainSlider[b].Width := EQBandWidth;
    FEQGainSlider[b].Height := WidgetHeight - 112 - 10;
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
var
  Freq: Single;
begin
  Freq := LogSliderToFreq(FLPSlider.Position);
  Project.TrackEffects[FTrackIndex][FEffectIndex].LowpassFreqHz := Freq;
  FLPValueLabel.Caption := Format('%d Hz', [Round(Freq)]);
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
