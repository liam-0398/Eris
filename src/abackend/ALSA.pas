unit ALSA;

{$mode objfpc}{$H+}

interface

uses
  ctypes;

const
  SND_PCM_STREAM_PLAYBACK = 0;
  SND_PCM_STREAM_CAPTURE = 1;
  SND_PCM_ACCESS_RW_INTERLEAVED = 3;
  SND_PCM_FORMAT_S16_LE = 2;

type
  Psnd_pcm_t = Pointer;
  PPsnd_pcm_t = ^Psnd_pcm_t;

function snd_pcm_open(APcm: PPsnd_pcm_t; AName: PChar; AStream: cint;
  AMode: cint): cint; cdecl; external 'libasound.so.2';
function snd_pcm_set_params(APcm: Psnd_pcm_t; AFormat: cint; AAccess: cint;
  AChannels: cuint; ARate: cuint; ASoftResample: cint;
  ALatency: cuint): cint; cdecl; external 'libasound.so.2';
function snd_pcm_prepare(APcm: Psnd_pcm_t): cint; cdecl;
  external 'libasound.so.2';
function snd_pcm_writei(APcm: Psnd_pcm_t; ABuffer: Pointer;
  ASize: culong): clong; cdecl; external 'libasound.so.2';
function snd_pcm_readi(APcm: Psnd_pcm_t; ABuffer: Pointer;
  ASize: culong): clong; cdecl; external 'libasound.so.2';
function snd_pcm_close(APcm: Psnd_pcm_t): cint; cdecl;
  external 'libasound.so.2';

implementation

end.
