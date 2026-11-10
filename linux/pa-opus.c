// yoyo-pa-opus: the sound source of yoyo-linux (audio.mjs). Records a PulseAudio source (the desktop sink's monitor),
// 48 kHz stereo, and encodes it with libopus: one 20 ms packet (960 frames) per record, 96 kbit/s VBR — the reference
// server's AudioCapture.swift in C. Silence is encoded too (3-byte packets): a packet every 20 ms whatever plays.
//
// Each packet's time is the wall clock (ms since 1970) of its first decoded sample, after AudioTimeline: the input
// chunks are counted from 0 on a timeline (t0 + chunks × 20 ms: packets exactly 20 ms apart) anchored on the wall
// clock. A chunk's own time is when its read returned, less its 20 ms and 20 ms more for each chunk that came in the
// same burst behind it (a burst's chunks are consecutive sound, the last one is the newest). The timeline only ever
// moves FORWARD: five chunks in a row more than 20 ms ahead of it move it, by the least of them (one read that
// returned late is only scheduling; the sound was late, or the clock runs fast); a chunk
// more than 20 ms behind it is sound the timeline has already covered (with silence, see below) and is dropped — so
// X-Audio-Time never goes back. The encoder's output runs its lookahead (312 frames) behind its input, so packet i
// decodes from input chunk sample i × 960 − 312. (pa_simple_get_latency is not used: it is junk for the first ~0.2 s
// of a record stream, and a monitor's samples are in the future of its sink — negative latency, reported as 0.)
//
// A null sink with nothing playing renders in 2 s blocks, so a new reader's first samples can take up to 2 s (and
// come as a burst); until then — and whenever the samples are more than 60 ms late later on — the encoder is given
// silence on the wall clock (10 ms behind it before the first samples: the first real chunk then lands within the
// timeline's ±20 ms and the times run on without a jump): the first packet comes ~30 ms after the start, and a stall
// never stops the packets.
//
// Arguments: [--device <source>] (default: the default sink's monitor, @DEFAULT_MONITOR@) [--kbps <n>] (default 96)
// [--complexity <0…10>] (default 5) [--probe] (connect, make the encoder, say hello, exit 0: "can it start?").
// PulseAudio is found the usual way ($PULSE_SERVER, else $XDG_RUNTIME_DIR/pulse/native).
//
// stdout, records: one type byte, a 4-byte big-endian payload length, the payload:
//   'H' hello, once: u32 BE sample rate, u16 BE channels, u16 BE frames per packet, u16 BE the encoder's lookahead
//   'A' a packet: f64 LE time of its first decoded sample (ms since 1970), u8 flags (1 = filled silence), then the
//       Opus packet
// stderr: log lines. Exit 0 on the end of stdin (or --probe), 1 when PulseAudio or the encoder can't be had, 2 when a
// read fails (PulseAudio went away).
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <opus/opus.h>
#include <pulse/error.h>
#include <pulse/simple.h>

#define RATE 48000
#define CHANNELS 2
#define FRAMES 960
#define PACKET_MS (FRAMES * 1000.0 / RATE)
#define MAX_DRIFT_MS 20.0
/** Read chunks waiting for the encoder at most: the worst burst (a null sink's 2 s block) and then some. */
#define RING 128
/** How late the samples may be before silence stands in: before the first samples, and after. */
#define FILL_FIRST_MS 10.0
#define FILL_LATER_MS 60.0
/** Chunks in a row more than MAX_DRIFT_MS ahead of the timeline before it moves (100 ms). */
#define AHEAD_RUN 5
/** Chunks whose reads returned within this of each other came in one burst. */
#define BURST_MS 3.0

static double now_ms(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

static void write_all(const void *p, size_t n) {
  const uint8_t *b = p;
  while (n) {
    ssize_t w = write(1, b, n);
    if (w < 0) {
      if (errno == EINTR) continue;
      exit(0);  // the server went away
    }
    b += w;
    n -= (size_t)w;
  }
}

static void record(char type, const void *a, size_t an, const void *b, size_t bn) {
  uint8_t head[5];
  uint32_t len = (uint32_t)(an + bn);
  head[0] = (uint8_t)type;
  head[1] = (uint8_t)(len >> 24);
  head[2] = (uint8_t)(len >> 16);
  head[3] = (uint8_t)(len >> 8);
  head[4] = (uint8_t)len;
  write_all(head, 5);
  if (an) write_all(a, an);
  if (bn) write_all(b, bn);
}

// The end of stdin (the server closed it, or went away): exit.
static void *watch_stdin(void *arg) {
  (void)arg;
  char buf[64];
  for (;;) {
    ssize_t n = read(0, buf, sizeof buf);
    if (n == 0 || (n < 0 && errno != EINTR)) exit(0);
  }
  return NULL;
}

// The reader: 20 ms chunks from PulseAudio into the ring, with when each read returned.
static pa_simple *pa;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv;
static int16_t ring[RING][FRAMES * CHANNELS];
static double ring_at[RING];
static int ring_head = 0, ring_count = 0, read_error = 0, dropped = 0;

static void *reader(void *arg) {
  (void)arg;
  int16_t chunk[FRAMES * CHANNELS];
  for (;;) {
    int err = 0;
    if (pa_simple_read(pa, chunk, sizeof chunk, &err) < 0) {
      pthread_mutex_lock(&mu);
      read_error = err ? err : -1;
      pthread_cond_signal(&cv);
      pthread_mutex_unlock(&mu);
      return NULL;
    }
    double at = now_ms();
    pthread_mutex_lock(&mu);
    if (ring_count == RING) {
      ring_head = (ring_head + 1) % RING;
      ring_count--;
      dropped++;
    }
    int slot = (ring_head + ring_count) % RING;
    memcpy(ring[slot], chunk, sizeof chunk);
    ring_at[slot] = at;
    ring_count++;
    pthread_cond_signal(&cv);
    pthread_mutex_unlock(&mu);
  }
}

int main(int argc, char **argv) {
  const char *device = "@DEFAULT_MONITOR@";
  int kbps = 96, complexity = 5, probe = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--device") && i + 1 < argc) device = argv[++i];
    else if (!strcmp(argv[i], "--kbps") && i + 1 < argc) kbps = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--complexity") && i + 1 < argc) complexity = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--probe")) probe = 1;
    else {
      fprintf(stderr, "usage: yoyo-pa-opus [--device <source>] [--kbps <n>] [--complexity <0-10>] [--probe]\n");
      return 1;
    }
  }
  signal(SIGPIPE, SIG_IGN);  // a write to a server that went away: EPIPE, an exit(0), not a signal
  if (kbps < 6 || kbps > 510 || complexity < 0 || complexity > 10) {
    fprintf(stderr, "yoyo-pa-opus: --kbps 6…510, --complexity 0…10\n");
    return 1;
  }
  pa_sample_spec ss = {.format = PA_SAMPLE_S16LE, .rate = RATE, .channels = CHANNELS};
  // reads of one packet: the server hands the samples over every 20 ms
  pa_buffer_attr attr = {.maxlength = (uint32_t)-1, .tlength = (uint32_t)-1, .prebuf = (uint32_t)-1, .minreq = (uint32_t)-1,
                         .fragsize = FRAMES * CHANNELS * 2};
  int err = 0;
  double started = now_ms();
  pa = pa_simple_new(NULL, "yoyo-linux", PA_STREAM_RECORD, device, "desktop sound", &ss, NULL, &attr, &err);
  if (!pa) {
    fprintf(stderr, "yoyo-pa-opus: PulseAudio: %s\n", pa_strerror(err));
    return 1;
  }
  OpusEncoder *enc = opus_encoder_create(RATE, CHANNELS, OPUS_APPLICATION_AUDIO, &err);
  if (!enc || err != OPUS_OK) {
    fprintf(stderr, "yoyo-pa-opus: opus_encoder_create: %s\n", opus_strerror(err));
    return 1;
  }
  opus_encoder_ctl(enc, OPUS_SET_BITRATE(kbps * 1000));
  opus_encoder_ctl(enc, OPUS_SET_VBR(1));
  opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(complexity));
  opus_int32 lookahead = 0;
  opus_encoder_ctl(enc, OPUS_GET_LOOKAHEAD(&lookahead));
  uint8_t hello[10] = {(uint8_t)((uint32_t)RATE >> 24), (uint8_t)((uint32_t)RATE >> 16), (uint8_t)(RATE >> 8), (uint8_t)RATE, 0,
                       CHANNELS, (uint8_t)(FRAMES >> 8), (uint8_t)FRAMES, (uint8_t)(lookahead >> 8), (uint8_t)lookahead};
  record('H', hello, sizeof hello, NULL, 0);
  if (probe) return 0;

  pthread_condattr_t ca;
  pthread_condattr_init(&ca);
  pthread_condattr_setclock(&ca, CLOCK_REALTIME);
  pthread_cond_init(&cv, &ca);
  pthread_t t;
  pthread_create(&t, NULL, watch_stdin, NULL);
  pthread_detach(t);
  pthread_create(&t, NULL, reader, NULL);
  pthread_detach(t);

  int16_t pcm[FRAMES * CHANNELS];
  static const int16_t zeros[FRAMES * CHANNELS];
  uint8_t packet[1500];
  // the wall clock (ms) of input chunk 0's first sample: before any samples, the start
  double origin = started;
  int64_t index = 0;  // packets (and input chunks) so far
  int got = 0, jumps = 0, fills = 0, covered = 0, logged_drops = 0, ahead_run = 0;
  double ahead_min = 0;
  for (;;) {
    double slack = got ? FILL_LATER_MS : FILL_FIRST_MS;
    double due = origin + (index + 1) * PACKET_MS + slack;  // when silence stands in for chunk `index`
    pthread_mutex_lock(&mu);
    while (!ring_count && !read_error) {
      double now = now_ms();
      if (now >= due) break;
      struct timespec ts = {.tv_sec = (time_t)(due / 1000), .tv_nsec = (long)(fmod(due, 1000.0) * 1e6)};
      pthread_cond_timedwait(&cv, &mu, &ts);
    }
    if (read_error) {
      fprintf(stderr, "yoyo-pa-opus: read: %s\n", read_error > 0 ? pa_strerror(read_error) : "failed");
      return 2;
    }
    const int16_t *in;
    int fill = !ring_count;
    if (!fill) {
      memcpy(pcm, ring[ring_head], sizeof pcm);
      double at = ring_at[ring_head];
      ring_head = (ring_head + 1) % RING;
      ring_count--;
      // the chunks of the same burst still behind it: it is that many chunks older
      int behind = 0;
      for (int i = 0; i < ring_count; i++)
        if (fabs(ring_at[(ring_head + i) % RING] - at) <= BURST_MS) behind++;
      if (dropped > logged_drops) {
        fprintf(stderr, "yoyo-pa-opus: %d chunks dropped (the encoder fell behind)\n", dropped - logged_drops);
        logged_drops = dropped;
      }
      pthread_mutex_unlock(&mu);
      in = pcm;
      double start = at - PACKET_MS * (1 + behind);  // its first sample's wall clock
      double expected = origin + (double)index * PACKET_MS;
      if (start < expected - MAX_DRIFT_MS) {
        // already covered (the silence that stood in for it went out): never back in time
        if (++covered <= 3 || covered % 500 == 0) fprintf(stderr, "yoyo-pa-opus: a chunk %.0f ms behind the timeline dropped (%d so far)\n", expected - start, covered);
        continue;
      }
      // ahead: a read that returned late looks ahead too (scheduling), so only a run of AHEAD_RUN chunks all ahead moves
      // the timeline, by the least of them (the truest: lateness only ever adds)
      if (start > expected + MAX_DRIFT_MS) {
        ahead_min = ahead_run ? fmin(ahead_min, start - expected) : start - expected;
        if (++ahead_run >= AHEAD_RUN) {
          origin += ahead_min;
          if (++jumps <= 5 || jumps % 100 == 0) fprintf(stderr, "yoyo-pa-opus: the timeline moved forward %.0f ms (%d so far)\n", ahead_min, jumps);
          ahead_run = 0;
        }
      } else {
        ahead_run = 0;
      }
      if (!got) fprintf(stderr, "yoyo-pa-opus: first samples after %.0f ms (%d silent packets before, %d in the burst)\n", at - started, fills, behind + 1);
      got = 1;
    } else {
      pthread_mutex_unlock(&mu);
      in = zeros;
      if (++fills == 1 && got) fprintf(stderr, "yoyo-pa-opus: no samples for %.0f ms: silence stands in\n", slack);
    }
    int n = opus_encode(enc, in, FRAMES, packet, sizeof packet);
    if (n < 0) {
      fprintf(stderr, "yoyo-pa-opus: opus_encode: %s\n", opus_strerror(n));
      return 1;
    }
    double t = origin + ((double)index * FRAMES - lookahead) * 1000.0 / RATE;
    uint8_t head[9];
    memcpy(head, &t, 8);  // little-endian on every target this runs on (x86-64, arm64)
    head[8] = fill ? 1 : 0;
    record('A', head, sizeof head, packet, (size_t)n);
    index++;
  }
}
