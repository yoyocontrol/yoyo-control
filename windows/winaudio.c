// yoyo-winaudio: the sound source of yoyo-windows (linux/audio.mjs). The Windows twin of linux/pa-opus.c — the same
// arguments and records: what the computer plays (WASAPI loopback of the default output device), 48 kHz stereo,
// encoded with libopus, one 20 ms packet (960 frames) per record, 96 kbit/s VBR. Silence is encoded too: a packet
// every 20 ms whatever plays (a loopback capture gives nothing while nothing plays).
//
// The packets run on a timeline anchored on the wall clock at start: packet i is due at t0 + (i + 1) × 20 ms (and
// 10 ms more, for the capture's burst), takes the next 960 captured frames, and is padded with silence when fewer have
// come (flag 1 when it is all silence). Its time is t0 + i × 20 ms less the encoder's lookahead (the wall clock of its
// first decoded sample, as pa-opus.c says it). More than 60 ms captured and not yet sent is a late capture: the oldest
// is dropped, so the sound never drifts behind. The device's own rate (44.1 kHz, 96 kHz…) is resampled to 48 kHz
// (linear), its channels are taken as stereo (mono doubled, more: the front pair). The default device changing
// (headphones plugged in) or going away is followed: captured again from the new default, silence meanwhile.
//
// Arguments: [--device <ignored>] [--kbps <n>] (default 96) [--complexity <0…10>] (default 5) [--probe] (open the
// device, make the encoder, say hello, exit 0: "can it start?").
//
// stdout, records: one type byte, a 4-byte big-endian payload length, the payload:
//   'H' hello, once: u32 BE sample rate, u16 BE channels, u16 BE frames per packet, u16 BE the encoder's lookahead
//   'A' a packet: f64 LE time of its first decoded sample (ms since 1970), u8 flags (1 = filled silence), then the
//       Opus packet
// stderr: log lines. Exit 0 on the end of stdin (or --probe), 1 when no output device or the encoder can be had.
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <initguid.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <ksmedia.h>
#include <timeapi.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <opus/opus.h>

#include "common.h"

#define RATE 48000
#define CHANNELS 2
#define FRAMES 960
#define FIFO_FRAMES (RATE * 2)

static IAudioClient *client;
static IAudioCaptureClient *capture;
static int dev_rate, dev_channels, dev_float, dev_bits;
static float fifo[FIFO_FRAMES * CHANNELS];  // 48 kHz stereo, captured and not yet sent
static size_t fifo_n = 0;
// the resampler: position in the device's frames between `prev` and the next frame
static double rs_pos = 0;
static float rs_prev[CHANNELS] = {0, 0};
static volatile LONG quit = 0;

static void close_device(void) {
  if (capture) IAudioCaptureClient_Release(capture), capture = NULL;
  if (client) {
    IAudioClient_Stop(client);
    IAudioClient_Release(client);
    client = NULL;
  }
}

static HRESULT open_device(void) {
  close_device();
  IMMDeviceEnumerator *en = NULL;
  IMMDevice *dev = NULL;
  WAVEFORMATEX *wf = NULL;
  HRESULT hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &IID_IMMDeviceEnumerator, (void **)&en);
  if (FAILED(hr)) goto done;
  hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &dev);
  if (FAILED(hr)) goto done;
  hr = IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
  if (FAILED(hr)) goto done;
  hr = IAudioClient_GetMixFormat(client, &wf);
  if (FAILED(hr)) goto done;
  dev_rate = (int)wf->nSamplesPerSec;
  dev_channels = wf->nChannels;
  dev_bits = wf->wBitsPerSample;
  dev_float = wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ||
              (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE && IsEqualGUID(&((WAVEFORMATEXTENSIBLE *)wf)->SubFormat, &KSDATAFORMAT_SUBTYPE_IEEE_FLOAT));
  if (!(dev_float && dev_bits == 32) && !(!dev_float && (dev_bits == 16 || dev_bits == 32))) {
    fprintf(stderr, "yoyo-winaudio: the device's format (%d-bit%s) is not supported\n", dev_bits, dev_float ? " float" : "");
    hr = E_FAIL;
    goto done;
  }
  hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 2000000 /* 200 ms */, 0, wf, NULL);
  if (FAILED(hr)) goto done;
  hr = IAudioClient_GetService(client, &IID_IAudioCaptureClient, (void **)&capture);
  if (FAILED(hr)) goto done;
  hr = IAudioClient_Start(client);
  rs_pos = 0;
done:
  if (wf) CoTaskMemFree(wf);
  if (dev) IMMDevice_Release(dev);
  if (en) IMMDeviceEnumerator_Release(en);
  if (FAILED(hr)) close_device();
  return hr;
}

static void fifo_push(float l, float r) {
  if (fifo_n == FIFO_FRAMES) {
    memmove(fifo, fifo + CHANNELS * (FIFO_FRAMES / 2), sizeof(float) * CHANNELS * (FIFO_FRAMES / 2));
    fifo_n = FIFO_FRAMES / 2;
  }
  fifo[fifo_n * 2] = l;
  fifo[fifo_n * 2 + 1] = r;
  fifo_n++;
}

// One device frame (as stereo floats) into the resampler; 48 kHz frames out into the FIFO.
static void resample_in(float l, float r) {
  if (dev_rate == RATE) {
    fifo_push(l, r);
    return;
  }
  // output frames fall every dev_rate / RATE device frames; each lands between prev (0) and this frame (1)
  double step = (double)dev_rate / RATE;
  while (rs_pos <= 1.0) {
    float t = (float)rs_pos;
    fifo_push(rs_prev[0] + (l - rs_prev[0]) * t, rs_prev[1] + (r - rs_prev[1]) * t);
    rs_pos += step;
  }
  rs_pos -= 1.0;
  rs_prev[0] = l;
  rs_prev[1] = r;
}

static float sample(const BYTE *p, int i) {
  if (dev_float) return ((const float *)p)[i];
  if (dev_bits == 16) return ((const int16_t *)p)[i] / 32768.0f;
  return (float)(((const int32_t *)p)[i] / 2147483648.0);
}

// Everything the capture has now → the FIFO. 0 when the device went away (invalidated).
static int drain_capture(void) {
  if (!capture) return 0;
  for (;;) {
    UINT32 next = 0;
    HRESULT hr = IAudioCaptureClient_GetNextPacketSize(capture, &next);
    if (FAILED(hr)) return 0;
    if (!next) return 1;
    BYTE *data;
    UINT32 frames;
    DWORD flags;
    hr = IAudioCaptureClient_GetBuffer(capture, &data, &frames, &flags, NULL, NULL);
    if (FAILED(hr)) return 0;
    int silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
    for (UINT32 f = 0; f < frames; f++) {
      float l = 0, r = 0;
      if (!silent) {
        l = sample(data, (int)(f * dev_channels));
        r = dev_channels > 1 ? sample(data, (int)(f * dev_channels + 1)) : l;
      }
      resample_in(l, r);
    }
    IAudioCaptureClient_ReleaseBuffer(capture, frames);
  }
}

static DWORD WINAPI watch_stdin(LPVOID unused) {
  (void)unused;
  while (in_byte() >= 0) {
  }
  InterlockedExchange(&quit, 1);
  return 0;
}

int main(int argc, char **argv) {
  int kbps = 96, complexity = 5, probe = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--device") && i + 1 < argc) i++;
    else if (!strcmp(argv[i], "--kbps") && i + 1 < argc) kbps = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--complexity") && i + 1 < argc) complexity = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--probe")) probe = 1;
    else {
      fprintf(stderr, "usage: yoyo-winaudio [--kbps <n>] [--complexity <0…10>] [--probe]\n");
      return 1;
    }
  }
  if (kbps < 6 || kbps > 510) kbps = 96;
  if (complexity < 0 || complexity > 10) complexity = 5;
  helper_init();
  CoInitializeEx(NULL, COINIT_MULTITHREADED);
  HRESULT hr = open_device();
  if (FAILED(hr)) {
    fprintf(stderr, "yoyo-winaudio: no output device to capture (0x%08lx)\n", (unsigned long)hr);
    return 1;
  }
  int err;
  OpusEncoder *enc = opus_encoder_create(RATE, CHANNELS, OPUS_APPLICATION_AUDIO, &err);
  if (err != OPUS_OK) {
    fprintf(stderr, "yoyo-winaudio: opus_encoder_create: %s\n", opus_strerror(err));
    return 1;
  }
  opus_encoder_ctl(enc, OPUS_SET_BITRATE(kbps * 1000));
  opus_encoder_ctl(enc, OPUS_SET_VBR(1));
  opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity));
  opus_int32 lookahead = 0;
  opus_encoder_ctl(enc, OPUS_GET_LOOKAHEAD(&lookahead));
  uint8_t hello[10] = {0, 0, (uint8_t)(RATE >> 8), (uint8_t)RATE, 0, CHANNELS, (uint8_t)(FRAMES >> 8), (uint8_t)FRAMES, (uint8_t)(lookahead >> 8), (uint8_t)lookahead};
  hello[0] = (uint8_t)(RATE >> 24);
  hello[1] = (uint8_t)(RATE >> 16);
  record('H', hello, sizeof hello, NULL, 0);
  fprintf(stderr, "yoyo-winaudio: capturing the default output (%d Hz, %d ch, %d-bit%s)\n", dev_rate, dev_channels, dev_bits, dev_float ? " float" : "");
  if (probe) return 0;
  CreateThread(NULL, 0, watch_stdin, NULL, 0, NULL);
  timeBeginPeriod(1);

  double t0 = now_ms(), lost_at = 0;
  uint64_t index = 0;
  float pcm[FRAMES * CHANNELS];
  uint8_t packet[1500];
  while (!quit) {
    if (!drain_capture()) {
      // the device changed or went away: the new default, tried every 500 ms; silence meanwhile
      if (now_ms() - lost_at > 500) {
        lost_at = now_ms();
        if (SUCCEEDED(open_device())) fprintf(stderr, "yoyo-winaudio: capturing the default output again (%d Hz, %d ch)\n", dev_rate, dev_channels);
      }
    }
    double now = now_ms();
    while (now >= t0 + (double)(index + 1) * 20.0 + 10.0) {
      size_t take = fifo_n < FRAMES ? fifo_n : FRAMES;
      memcpy(pcm, fifo, take * CHANNELS * sizeof(float));
      memset(pcm + take * CHANNELS, 0, (FRAMES - take) * CHANNELS * sizeof(float));
      memmove(fifo, fifo + take * CHANNELS, (fifo_n - take) * CHANNELS * sizeof(float));
      fifo_n -= take;
      // a late capture: what is beyond 60 ms behind the timeline goes
      if (fifo_n > (size_t)FRAMES * 3) {
        size_t drop = fifo_n - FRAMES;
        memmove(fifo, fifo + drop * CHANNELS, (fifo_n - drop) * CHANNELS * sizeof(float));
        fifo_n -= drop;
      }
      int n = opus_encode_float(enc, pcm, FRAMES, packet, sizeof packet);
      if (n < 0) {
        fprintf(stderr, "yoyo-winaudio: opus_encode_float: %s\n", opus_strerror(n));
        return 1;
      }
      double t = t0 + ((double)index * FRAMES - lookahead) * 1000.0 / RATE;
      uint8_t head[9];
      memcpy(head, &t, 8);
      head[8] = take == 0 ? 1 : 0;
      record('A', head, sizeof head, packet, (size_t)n);
      index++;
      // asleep (the PC slept, the process was stopped): the timeline starts again from now
      if (now - (t0 + (double)index * 20.0) > 1000) {
        t0 = now - 20.0;
        index = 0;
      }
    }
    Sleep(5);
  }
  return 0;
}
