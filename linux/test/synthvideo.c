// synthvideo: yoyo-x11video without a screen — the same commands and records (x11video.c), the same encoder
// (x264enc.h), but the pictures are made up: a page of text-like marks that sits still, is typed into, scrolls, is
// replaced by another page, and has a moving picture in it. For trying the stream end to end where there is no X
// server (a Mac: `cc -O2 -I.. -o synthvideo synthvideo.c -lx264`, then YOYO_VIDEO_HELPER=<it> for server.mjs), and
// for test/x264enc.test.mjs.
//
// Arguments as yoyo-x11video's: [--fps <n>] [--cursor client] [--preset <p>] [--threads <n>]. Environment:
//   YOYO_SYNTH_SIZE    <width>x<height> (default 1280x832)
//   YOYO_SYNTH_SCENE   mixed (default: 3 s still, 3 s typing, 5 s scrolling, 2 s still, another page, 1 s still, 5 s
//                      of a moving picture, 1 s still; then again) | still | typing | scroll | video | pages (a new
//                      page every second)
//   YOYO_SYNTH_PLAIN   1: as a helper that keeps no earlier pictures (no picture numbers, `I` does nothing)
// The content changes on a 60 Hz clock ('C' once per change until the next E, as the screen's damage does).
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#define ENC_NAME "synthvideo"
#include "../videoio.h"
#include "../x264enc.h"

static int width = 1280, height = 832;
static uint8_t *bgrx, *yuv;
static int client_cursor = 0;
static const char *scene = "mixed";

// what the screen shows now
static uint32_t page = 1;     // which page of marks
static int scroll = 0;        // how far it is scrolled (pixels)
static int typed = 0;         // marks typed on the line at the top
static int movie = -1;        // the moving picture's frame (-1: none)
static int dirty = 1, told = 0;
static int plain = 0;

static uint32_t hash(uint32_t a, uint32_t b, uint32_t c) {
  uint32_t h = a * 0x9E3779B1u ^ (b + 0x7F4A7C15u) * 0x85EBCA6Bu ^ (c + 0x165667B1u) * 0xC2B2AE35u;
  h ^= h >> 15;
  h *= 0x2C1B3C6Du;
  h ^= h >> 12;
  h *= 0x297A2D39u;
  return h ^ (h >> 15);
}

// One page pixel: lines of 20 px, marks of 10 px (5x7 dots doubled, like text at 120 dpi), words and blank lines.
static uint32_t page_pixel(int x, int y) {
  int line = y / 20, row = y % 20, col = x / 10, dot = x % 10;
  uint32_t l = hash(page, (uint32_t)line, 0);
  if (l % 7 == 0) return 0xffffff;                       // a blank line
  if (col < 4 || col > (int)(40 + l % 80)) return 0xffffff;  // margins, ragged right
  uint32_t g = hash(page, (uint32_t)line, (uint32_t)col + 1);
  if (g % 6 == 0) return 0xffffff;                       // a space
  if (row < 3 || row >= 17 || dot >= 8) return 0xffffff;
  int bit = ((row - 3) / 2) * 4 + dot / 2;               // 7 rows of 4 dots
  return (g >> (bit % 28)) & 1 ? 0x202020 : 0xffffff;
}

static void paint(void) {
  for (int y = 0; y < height; y++) {
    uint8_t *d = bgrx + (size_t)y * width * 4;
    // a title bar that doesn't scroll
    if (y < 40) {
      for (int x = 0; x < width; x++, d += 4) {
        uint32_t c = (x / 10 < typed && y >= 12 && y < 28 && (hash(7, (uint32_t)(x / 10), 0) >> ((y - 12) / 2 * 4 + x % 10 / 3)) & 1) ? 0xf0f0f0 : 0x3a5fcd;
        d[0] = (uint8_t)c, d[1] = (uint8_t)(c >> 8), d[2] = (uint8_t)(c >> 16), d[3] = 0;
      }
      continue;
    }
    for (int x = 0; x < width; x++, d += 4) {
      uint32_t c = page_pixel(x, y - 40 + scroll);
      d[0] = (uint8_t)c, d[1] = (uint8_t)(c >> 8), d[2] = (uint8_t)(c >> 16), d[3] = 0;
    }
  }
  if (movie >= 0) {
    // a moving picture, 640x360 (or what fits), in the middle: soft shapes that drift
    int w = width < 680 ? width - 40 : 640, h = height < 440 ? height - 80 : 360;
    int ox = (width - w) / 2, oy = 60 + (height - 60 - h) / 2;
    for (int y = 0; y < h; y++) {
      uint8_t *d = bgrx + ((size_t)(oy + y) * width + ox) * 4;
      for (int x = 0; x < w; x++, d += 4) {
        int a = (x + movie * 3) & 255, b = (y * 2 + movie * 5) & 255, c = ((x + y) / 2 + movie * 2) & 255;
        a = a < 128 ? a * 2 : 510 - a * 2;
        b = b < 128 ? b * 2 : 510 - b * 2;
        c = c < 128 ? c * 2 : 510 - c * 2;
        d[0] = (uint8_t)((a + c) / 2), d[1] = (uint8_t)((b + c) / 2), d[2] = (uint8_t)((a + b) / 2), d[3] = 0;
      }
    }
  }
}

static void changed(void) {
  dirty = 1;
  if (!told) {
    told = 1;
    record('C', NULL, 0, NULL, 0);
  }
}

// One tick of the 60 Hz clock, `t` ms into the scene.
static void tick(long n) {
  double t = n * 1000.0 / 60;
  const char *now = scene;
  if (!strcmp(scene, "mixed")) {
    double c = t - 20000.0 * (long)(t / 20000.0);
    now = c < 3000 ? "still" : c < 6000 ? "typing" : c < 11000 ? "scroll" : c < 13000 ? "still" : c < 14000 ? "page" : c < 19000 ? "video" : "still";
    static const char *was = "";
    if (strcmp(now, was)) {
      if (!strcmp(now, "page")) page++, scroll = 0, typed = 0, changed();
      if (!strcmp(was, "video")) movie = -1, changed();
      was = now;
    }
  }
  if (!strcmp(now, "typing") && n % 6 == 0) typed = (typed + 1) % 100, changed();
  if (!strcmp(now, "scroll")) scroll += 12, changed();
  if (!strcmp(now, "video") && n % 2 == 0) movie++, changed();
  if (!strcmp(now, "pages") && n % 60 == 0) page++, changed();
}

static void encode(int key, int kbps, float crf, int buf) {
  int was = dirty;
  double at = now_ms();
  dirty = 0;
  told = 0;
  paint();
  enc_convert(bgrx, width * 4, yuv);
  const uint8_t *au = NULL;
  int is_key = 0;
  int64_t number = 0;
  int size = enc_frame(yuv, key, kbps, crf, buf, &au, &is_key, &number);
  if (size == 0) {
    record('S', NULL, 0, NULL, 0);
    return;
  }
  record_frame(is_key, was, at, plain ? -1 : number, au, (size_t)size);
}

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--preset") && i + 1 < argc) enc_preset = argv[++i];
    else if (!strcmp(argv[i], "--threads") && i + 1 < argc) enc_threads = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--fps") && i + 1 < argc) enc_fps = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--cursor") && i + 1 < argc && !strcmp(argv[i + 1], "client")) client_cursor = 1, i++;
    else enc_die("usage: synthvideo [--preset <x264 preset>] [--threads <n>] [--fps <n>] [--cursor client]");
  }
  if (enc_fps < 1 || enc_fps > 60) enc_die("--fps must be 1…60");
  const char *size = getenv("YOYO_SYNTH_SIZE");
  if (size && sscanf(size, "%dx%d", &width, &height) != 2) enc_die("YOYO_SYNTH_SIZE must be <width>x<height>");
  width &= ~1, height &= ~1;
  if (width < 64 || height < 64 || width > 8192 || height > 8192) enc_die("YOYO_SYNTH_SIZE out of range");
  if (getenv("YOYO_SYNTH_SCENE")) scene = getenv("YOYO_SYNTH_SCENE");
  signal(SIGPIPE, SIG_IGN);
  bgrx = malloc((size_t)width * height * 4);
  yuv = malloc((size_t)width * height * 3 / 2);
  if (!bgrx || !yuv) enc_die("out of memory");
  enc_width = width;
  enc_height = height;
  plain = getenv("YOYO_SYNTH_PLAIN") != NULL;
  record_hello(width, height, !plain && enc_kept_for(width, height) > 1 ? HELLO_REFS : 0);
  if (client_cursor) {
    // the pointer, once: the client's built-in arrow in the middle
    uint8_t p[17] = {0};
    put16(p, width / 2);
    put16(p + 2, height / 2);
    p[16] = 1 | 4;
    record('P', p, sizeof p, NULL, 0);
  }
  record('C', NULL, 0, NULL, 0);
  told = 1;

  char line[256];
  size_t have = 0;
  struct pollfd fd = {.fd = 0, .events = POLLIN};
  double start = now_ms();
  long ticks = 0;
  for (;;) {
    double due = start + (ticks + 1) * 1000.0 / 60;
    double wait = due - now_ms();
    int r = poll(&fd, 1, wait > 0 ? (int)(wait + 0.999) : 0);
    if (r < 0 && errno != EINTR) enc_die("poll failed");
    while (now_ms() >= start + (ticks + 1) * 1000.0 / 60) tick(++ticks);
    if (r > 0 && fd.revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t got = read(0, line + have, sizeof line - 1 - have);
      if (got <= 0) break;
      have += (size_t)got;
      char *nl;
      while ((nl = memchr(line, '\n', have))) {
        *nl = 0;
        int key = 0, kbps = 0, buf = 0;
        float crf = 23;
        long long from = -1;
        if (line[0] == 'Q') goto done;
        if (line[0] == 'E' && sscanf(line + 1, "%d %d %f %d", &key, &kbps, &crf, &buf) >= 2) encode(key, kbps, crf, buf);
        else if (line[0] == 'I' && sscanf(line + 1, "%lld", &from) == 1) {
          if (!plain) enc_forget(from);
        } else fprintf(stderr, "synthvideo: bad command \"%s\"\n", line);
        size_t used = (size_t)(nl - line) + 1;
        memmove(line, nl + 1, have - used);
        have -= used;
      }
      if (have == sizeof line - 1) have = 0;
    }
  }
done:
  if (enc) x264_encoder_close(enc);
  return 0;
}
