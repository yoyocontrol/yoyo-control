// What every yoyo-windows helper shares: the wall clock, the records on stdout (one type byte, a 4-byte big-endian
// length, the payload: the same framing as the Linux helpers), stdin read on a thread of its own (Windows can't wait on
// a pipe and a window or a duplication at once), the process set up for the server's pipes (binary, no error boxes,
// per-monitor DPI aware: pixels are physical pixels everywhere).
#pragma once
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ms since 1970 (UTC), sub-millisecond
static double now_ms(void) {
  FILETIME ft;
  GetSystemTimePreciseAsFileTime(&ft);
  ULARGE_INTEGER u;
  u.LowPart = ft.dwLowDateTime;
  u.HighPart = ft.dwHighDateTime;
  return (double)(u.QuadPart - 116444736000000000ULL) / 10000.0;
}

static HANDLE out_handle;
static CRITICAL_SECTION out_lock;

static void write_all(const void *p, size_t n) {
  const uint8_t *b = p;
  while (n) {
    DWORD w = 0;
    DWORD chunk = n > (1u << 30) ? (1u << 30) : (DWORD)n;
    if (!WriteFile(out_handle, b, chunk, &w, NULL) || w == 0) exit(0);  // the server went away
    b += w;
    n -= w;
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
  EnterCriticalSection(&out_lock);
  write_all(head, 5);
  if (an) write_all(a, an);
  if (bn) write_all(b, bn);
  LeaveCriticalSection(&out_lock);
}

static void helper_init(void) {
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
  _setmode(_fileno(stdin), _O_BINARY);
  _setmode(_fileno(stdout), _O_BINARY);
  setvbuf(stderr, NULL, _IONBF, 0);
  out_handle = GetStdHandle(STD_OUTPUT_HANDLE);
  InitializeCriticalSection(&out_lock);
  // physical pixels: without this a 150 % display is captured, listed and clicked at two thirds of its size
  HMODULE u = GetModuleHandleW(L"user32.dll");
  typedef BOOL(WINAPI * SetCtx)(HANDLE);
  SetCtx set = u ? (SetCtx)(void *)GetProcAddress(u, "SetProcessDpiAwarenessContext") : NULL;
  if (!set || !set((HANDLE)-4 /* DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 */)) SetProcessDPIAware();
}

// ---- stdin, blocking (for a thread of the helper's own)

static HANDLE in_handle;
static uint8_t in_buf[65536];
static size_t in_have = 0, in_pos = 0;

// One byte; -1 at the end of stdin.
static int in_byte(void) {
  if (in_pos == in_have) {
    DWORD got = 0;
    if (!in_handle) in_handle = GetStdHandle(STD_INPUT_HANDLE);
    if (!ReadFile(in_handle, in_buf, sizeof in_buf, &got, NULL) || got == 0) return -1;
    in_have = got;
    in_pos = 0;
  }
  return in_buf[in_pos++];
}

// A line (without its \n, \r dropped) into `line`; 0 at the end of stdin. Too long a line is cut.
static int in_line(char *line, size_t cap) {
  size_t n = 0;
  int c;
  while ((c = in_byte()) >= 0) {
    if (c == '\n') break;
    if (c != '\r' && n + 1 < cap) line[n++] = (char)c;
  }
  line[n] = 0;
  return c >= 0 || n > 0;
}

// Exactly n bytes; 0 when stdin ended first.
static int in_exact(uint8_t *dst, size_t n) {
  for (size_t i = 0; i < n; i++) {
    int c = in_byte();
    if (c < 0) return 0;
    dst[i] = (uint8_t)c;
  }
  return 1;
}

// ---- stdin as queued lines (a reader thread; the main loop polls)

#define LINEQ 64
static char lineq[LINEQ][256];
static int lineq_head = 0, lineq_n = 0, lineq_eof = 0;
static CRITICAL_SECTION lineq_lock;
static HANDLE lineq_event;

static DWORD WINAPI line_reader(LPVOID unused) {
  (void)unused;
  char line[256];
  while (in_line(line, sizeof line)) {
    for (;;) {
      EnterCriticalSection(&lineq_lock);
      if (lineq_n < LINEQ) {
        strcpy(lineq[(lineq_head + lineq_n) % LINEQ], line);
        lineq_n++;
        LeaveCriticalSection(&lineq_lock);
        break;
      }
      LeaveCriticalSection(&lineq_lock);
      Sleep(1);
    }
    SetEvent(lineq_event);
  }
  EnterCriticalSection(&lineq_lock);
  lineq_eof = 1;
  LeaveCriticalSection(&lineq_lock);
  SetEvent(lineq_event);
  return 0;
}

static void start_stdin_reader(void) {
  InitializeCriticalSection(&lineq_lock);
  lineq_event = CreateEventW(NULL, FALSE, FALSE, NULL);
  CreateThread(NULL, 0, line_reader, NULL, 0, NULL);
}

// 1: a line in `line`; 0: none now; -1: stdin ended (and nothing is left).
static int next_line(char *line, size_t cap) {
  int r = 0;
  EnterCriticalSection(&lineq_lock);
  if (lineq_n) {
    strncpy(line, lineq[lineq_head], cap - 1);
    line[cap - 1] = 0;
    lineq_head = (lineq_head + 1) % LINEQ;
    lineq_n--;
    r = 1;
  } else if (lineq_eof) {
    r = -1;
  }
  LeaveCriticalSection(&lineq_lock);
  return r;
}

// ---- JSON strings

// `s` (UTF-8) as a JSON string, quotes included, into a growing buffer.
typedef struct {
  char *p;
  size_t n, cap;
} buf_t;

static void buf_put(buf_t *b, const char *s, size_t n) {
  if (b->n + n + 1 > b->cap) {
    b->cap = (b->n + n + 1) * 2;
    b->p = realloc(b->p, b->cap);
    if (!b->p) exit(1);
  }
  memcpy(b->p + b->n, s, n);
  b->n += n;
  b->p[b->n] = 0;
}

static void buf_str(buf_t *b, const char *s) { buf_put(b, s, strlen(s)); }

static void buf_fmt(buf_t *b, const char *fmt, ...) {
  char tmp[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
  va_end(ap);
  if (n > 0) buf_put(b, tmp, (size_t)n < sizeof tmp ? (size_t)n : sizeof tmp - 1);
}

static void buf_json(buf_t *b, const char *s) {
  buf_put(b, "\"", 1);
  for (const unsigned char *c = (const unsigned char *)s; *c; c++) {
    if (*c == '"' || *c == '\\') {
      char e[2] = {'\\', (char)*c};
      buf_put(b, e, 2);
    } else if (*c < 0x20) {
      char e[8];
      snprintf(e, sizeof e, "\\u%04x", *c);
      buf_put(b, e, 6);
    } else {
      buf_put(b, (const char *)c, 1);
    }
  }
  buf_put(b, "\"", 1);
}

// UTF-16 → UTF-8 (malloc'd; NULL on failure). `n` UTF-16 units, or -1: up to the terminator.
static char *utf8_of(const wchar_t *w, int n) {
  int len = WideCharToMultiByte(CP_UTF8, 0, w, n, NULL, 0, NULL, NULL);
  if (len <= 0) return NULL;
  char *s = malloc((size_t)len + 1);
  if (!s) return NULL;
  WideCharToMultiByte(CP_UTF8, 0, w, n, s, len, NULL, NULL);
  s[len] = 0;
  return s;
}

// UTF-8 (n bytes) → UTF-16, terminated (malloc'd; NULL on failure); `units` gets the length without the terminator.
static wchar_t *utf16_of(const char *s, int n, int *units) {
  int len = n ? MultiByteToWideChar(CP_UTF8, 0, s, n, NULL, 0) : 0;
  if (n && len <= 0) return NULL;
  wchar_t *w = malloc(((size_t)len + 1) * sizeof *w);
  if (!w) return NULL;
  if (n) MultiByteToWideChar(CP_UTF8, 0, s, n, w, len);
  w[len] = 0;
  if (units) *units = len;
  return w;
}
