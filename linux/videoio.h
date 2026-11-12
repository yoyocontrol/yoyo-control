// The records a video helper writes to the server (video.mjs reads them, wire.mjs RecordReader): one type byte, a
// 4-byte big-endian payload length, the payload. Shared by yoyo-x11video and test/synthvideo.c.
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

/** The hello's flags byte: 1 = the helper keeps time ('T'; yoyo-winvideo), 2 = it keeps earlier pictures and takes
 * `I <n>` (its 'F' records carry their picture number). */
#define HELLO_TIMER 1
#define HELLO_REFS 2
/** An 'F' record's flags: a key frame, the picture changed since the previous grab, a u32 BE picture number follows
 * the capture time. */
#define FRAME_KEY 1
#define FRAME_CHANGED 2
#define FRAME_NUMBER 4

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

static void put16(uint8_t *p, int v) {
  p[0] = (uint8_t)((unsigned)v >> 8);
  p[1] = (uint8_t)v;
}

static void put32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
}

// The hello: the picture size and what this helper can do.
static void record_hello(int width, int height, int flags) {
  uint8_t hello[5];
  put16(hello, width);
  put16(hello + 2, height);
  hello[4] = (uint8_t)flags;
  record('H', hello, 5, NULL, 0);
}

// One 'F' record: `number` < 0 leaves the picture number out (a helper without HELLO_REFS).
static void record_frame(int key, int changed, double at, int64_t number, const uint8_t *au, size_t size) {
  uint8_t head[13];
  head[0] = (uint8_t)((key ? FRAME_KEY : 0) | (changed ? FRAME_CHANGED : 0) | (number >= 0 ? FRAME_NUMBER : 0));
  memcpy(head + 1, &at, 8);  // little-endian on every target this runs on (x86-64, arm64)
  if (number >= 0) put32(head + 9, (uint32_t)number);
  record('F', head, number >= 0 ? 13 : 9, au, size);
}
