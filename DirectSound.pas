unit DirectSound;

{$mode objfpc}{$H+}

{ Minimal hand-written binding for just the slice of DirectSound this app
  needs (create a device, make one looping streaming secondary buffer, lock/
  write/unlock it, track the play cursor). Self-contained - no dependency on
  any external DirectX package - so it can't break a build that doesn't have
  one installed. Only ever pulled in under {$IFDEF WINDOWS} by AudioEngine,
  so none of this is compiled on other platforms. }

interface

{$IFDEF WINDOWS}
uses
  Windows;

const
  WAVE_FORMAT_PCM = 1;

  DSSCL_NORMAL = $00000001;
  DSSCL_PRIORITY = $00000002;

  DSBCAPS_CTRLPOSITIONNOTIFY = $00000010;
  DSBCAPS_CTRLVOLUME = $00000080;
  DSBCAPS_GLOBALFOCUS = $00008000;
  DSBCAPS_GETCURRENTPOSITION2 = $00010000;

  DSBPLAY_LOOPING = $00000001;

  DS_OK = 0;

type
  TWaveFormatEx = packed record
    wFormatTag: Word;
    nChannels: Word;
    nSamplesPerSec: DWord;
    nAvgBytesPerSec: DWord;
    nBlockAlign: Word;
    wBitsPerSample: Word;
    cbSize: Word;
  end;
  PWaveFormatEx = ^TWaveFormatEx;

  TDSBufferDesc = packed record
    dwSize: DWord;
    dwFlags: DWord;
    dwBufferBytes: DWord;
    dwReserved: DWord;
    lpwfxFormat: PWaveFormatEx;
    guid3DAlgorithm: TGUID;
  end;

  IDirectSoundBuffer = interface(IUnknown)
    ['{279AFA85-4981-11CE-A521-0020AF0BE560}']
    function GetCaps(out lpDSBufferCaps: TDSBufferDesc): HRESULT; stdcall;
    function GetCurrentPosition(out lpdwCurrentPlayCursor,
      lpdwCurrentWriteCursor: DWord): HRESULT; stdcall;
    function GetFormat(lpwfxFormat: PWaveFormatEx; dwSizeAllocated: DWord;
      out lpdwSizeWritten: DWord): HRESULT; stdcall;
    function GetVolume(out lplVolume: LongInt): HRESULT; stdcall;
    function GetPan(out lplPan: LongInt): HRESULT; stdcall;
    function GetFrequency(out lpdwFrequency: DWord): HRESULT; stdcall;
    function GetStatus(out lpdwStatus: DWord): HRESULT; stdcall;
    function Initialize(lpDirectSound: IUnknown;
      const lpcDSBufferDesc: TDSBufferDesc): HRESULT; stdcall;
    function Lock(dwOffset, dwBytes: DWord; out lplpvAudioPtr1: Pointer;
      out lpdwAudioBytes1: DWord; out lplpvAudioPtr2: Pointer;
      out lpdwAudioBytes2: DWord; dwFlags: DWord): HRESULT; stdcall;
    function Play(dwReserved1, dwReserved2, dwFlags: DWord): HRESULT; stdcall;
    function SetCurrentPosition(dwNewPosition: DWord): HRESULT; stdcall;
    function SetFormat(const lpcfxFormat: TWaveFormatEx): HRESULT; stdcall;
    function SetVolume(lVolume: LongInt): HRESULT; stdcall;
    function SetPan(lPan: LongInt): HRESULT; stdcall;
    function SetFrequency(dwFrequency: DWord): HRESULT; stdcall;
    function Stop: HRESULT; stdcall;
    function Unlock(lpvAudioPtr1: Pointer; dwAudioBytes1: DWord;
      lpvAudioPtr2: Pointer; dwAudioBytes2: DWord): HRESULT; stdcall;
    function Restore: HRESULT; stdcall;
  end;

  IDirectSound = interface(IUnknown)
    ['{279AFA83-4981-11CE-A521-0020AF0BE560}']
    function CreateSoundBuffer(const lpcDSBufferDesc: TDSBufferDesc;
      out lplpDirectSoundBuffer: IDirectSoundBuffer;
      pUnkOuter: IUnknown): HRESULT; stdcall;
    function GetCaps(out lpDSCaps: Pointer): HRESULT; stdcall;
    function DuplicateSoundBuffer(lpDsbOriginal: IDirectSoundBuffer;
      out lplpDsbDuplicate: IDirectSoundBuffer): HRESULT; stdcall;
    function SetCooperativeLevel(hwnd: HWND; dwLevel: DWord): HRESULT; stdcall;
    function Compact: HRESULT; stdcall;
    function GetSpeakerConfig(out lpdwSpeakerConfig: DWord): HRESULT; stdcall;
    function SetSpeakerConfig(dwSpeakerConfig: DWord): HRESULT; stdcall;
    function Initialize(lpGuid: PGUID): HRESULT; stdcall;
  end;

function DirectSoundCreate(pcGuidDevice: PGUID; out ppDS: IDirectSound;
  pUnkOuter: IUnknown): HRESULT; stdcall; external 'dsound.dll';

{$ENDIF}

implementation

end.
