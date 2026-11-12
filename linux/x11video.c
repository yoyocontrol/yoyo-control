// yoyo-x11video: the video source of yoyo-linux (server.mjs). Watches an X display for changes (XDamage, the pointer)
// and, when told to, grabs the screen (MIT-SHM), draws the pointer in (XFixes), converts it to I420 (BT.709, limited
// range) and encodes it with x264 as one Annex-B access unit: a key frame (SPS + PPS + IDR) when asked, else a delta;
// no B-frames, no lookahead, no reordering, no delay. The server decides when to encode (pace, flow-control window,
// refine, keepalive: README.md「视频流」); this program only reports changes and encodes on command.
//
// The encoder is x264enc.h (the rate, and recovery from a lost picture without a key frame), the records videoio.h.
//
// With `--cursor client` the pointer is the client's to draw (the protocol's `cursor=client`): it is never drawn into
// the pictures, its moves and shape changes are no picture change, and it is reported as 'P' records instead — where
// it is (polled every 33 ms, sent only when it moved), and its shape (XFixes cursor notify; the pixels the first time
// this process sees a cursor serial). A cursor that changes its serial more than 10 times a second (an animated busy
// cursor) keeps its last reported shape until it has been still for 0.5 s.
//
// Display: $DISPLAY / $XAUTHORITY. Arguments: [--preset <x264 preset>] [--threads <n>] [--fps <n>] (the stream's
// pace: what the rate control's per-picture budget assumes) [--cursor client].
//
// stdin, one command per line:
//   E <key 0|1> <kbps> [<crf> [<buf>]]   grab and encode now: quality-targeted (x264's CRF, default 23) under a cap
//                                 of kbps (VBV); a refine asks for a lower crf and a higher cap. buf: the VBV buffer
//                                 in kbit (default kbps, one second): what one picture may take at most, so the
//                                 server gives a few pictures' worth (kbps / --fps is one picture's share)
//   I <n>                         the pictures numbered n and later never reached the viewer: the next picture
//                                 references the newest kept one before n (a key frame when none is kept any more)
//   Q                             quit (stdin's end too)
// stdout, records: one type byte, a 4-byte big-endian payload length, the payload:
//   'H' hello, once at start: u16 BE width, u16 BE height (even: an odd edge is left out), u8 flags (2 = earlier
//       pictures are kept: `I` works, 'F' records carry their number)
//   'C' the screen (or the pointer) changed since the last grab; once per change until the next E
//   'F' a frame: u8 flags (1 = key, 2 = the picture changed since the previous grab, 4 = its number follows the
//       time), f64 LE capture time (ms since 1970), u32 BE picture number (0, 1, …: one per E), then the access unit
//   'S' skipped: the encoder gave no picture for that E (rate control)
//   'P' the pointer (--cursor client only; one right after the hello, then on every move or shape change): i16 BE x,
//       i16 BE y (pixels), u32 BE cursor serial, u16 BE xhot, yhot, width, height, u8 flags (1 = visible, 2 = the
//       shape's pixels follow, 4 = no shape could be read: the client's built-in arrow), then, with flag 2,
//       width × height × 4 bytes of premultiplied RGBA
// stderr: log lines. Exit 0 on Q / end of stdin, 1 when the display or the encoder can't be had (an X error, the X
// server gone, included: Xlib's default handlers exit), 3 when the screen changed size.
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <unistd.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/Xdamage.h>
#include <X11/extensions/Xfixes.h>
#include "videoio.h"
#include "x264enc.h"

static Display *dpy;
static Window root;
static int width, height;
static XImage *img;
static XShmSegmentInfo shm;
static int damage_event, fixes_event;
static Damage damage;
static int dirty = 1;              // changed since the last grab
static int told = 0;               // a 'C' went out for this change
static int ptr_x = -1, ptr_y = -1; // the pointer at the last grab / look
static uint8_t *yuv;               // I420, width x height
static int client_cursor = 0;      // --cursor client: the pointer as 'P' records, never in the picture
// the pointer last reported ('P'): its shape (serial, hotspot, size, visible, no image) and position
static struct {
  uint32_t serial;
  int xhot, yhot, w, h, visible, none;
  int x, y;
} cur = {0, 0, 0, 0, 0, 0, 1, -1, -1};
static uint32_t *seen_serials;     // serials whose pixels went out already (this process)
static size_t seen_n, seen_cap;
// animated cursors: new serials in the current 1 s window; while `animating`, shapes are held until 0.5 s of quiet
static double anim_window_at = 0;
static int anim_count = 0, animating = 0, anim_logged = 0;
static double last_serial_at = 0;
static uint32_t pending_serial = 0;

static void die(const char *what) {
  fprintf(stderr, "yoyo-x11video: %s\n", what);
  exit(1);
}

static void mark_dirty(void) {
  dirty = 1;
  if (!told) {
    told = 1;
    record('C', NULL, 0, NULL, 0);
  }
}

// One 'P' record: the pointer as `cur` has it, with `rgba` (w × h × 4) when given.
static void send_pointer(const uint8_t *rgba) {
  uint8_t head[17];
  put16(head, cur.x);
  put16(head + 2, cur.y);
  put32(head + 4, cur.serial);
  put16(head + 8, cur.xhot);
  put16(head + 10, cur.yhot);
  put16(head + 12, cur.w);
  put16(head + 14, cur.h);
  head[16] = (uint8_t)((cur.visible ? 1 : 0) | (rgba ? 2 : 0) | (cur.none ? 4 : 0));
  record('P', head, sizeof head, rgba, rgba ? (size_t)cur.w * cur.h * 4 : 0);
}

static int serial_seen(uint32_t serial) {
  for (size_t i = 0; i < seen_n; i++)
    if (seen_serials[i] == serial) return 1;
  return 0;
}

static void note_serial(uint32_t serial) {
  if (seen_n == seen_cap) {
    seen_cap = seen_cap ? seen_cap * 2 : 64;
    seen_serials = realloc(seen_serials, seen_cap * sizeof *seen_serials);
    if (!seen_serials) die("out of memory");
  }
  seen_serials[seen_n++] = serial;
}

// Read the current cursor (XFixes) and report it: its pixels the first time this serial is seen. The position comes
// with it. No image (XFixes gave none): the built-in arrow (flag 4).
static void read_shape(void) {
  XFixesCursorImage *ci = XFixesGetCursorImage(dpy);
  if (!ci) {
    if (!cur.none) fprintf(stderr, "yoyo-x11video: the cursor image can't be read; the client's arrow stands in\n");
    cur.serial = 0;
    cur.none = 1;
    cur.visible = 1;
    cur.xhot = cur.yhot = cur.w = cur.h = 0;
    send_pointer(NULL);
    return;
  }
  cur.serial = (uint32_t)ci->cursor_serial;
  cur.none = 0;
  cur.x = ci->x;
  cur.y = ci->y;
  cur.xhot = ci->xhot;
  cur.yhot = ci->yhot;
  cur.w = ci->width;
  cur.h = ci->height;
  size_t n = (size_t)ci->width * ci->height;
  // a cursor this large is no cursor: its position only (and taken as visible)
  int any = n > 256 * 256;
  for (size_t i = 0; !any && i < n; i++)
    if ((ci->pixels[i] >> 24) & 0xff) any = 1;
  cur.visible = any;
  if (serial_seen(cur.serial) || n == 0 || n > 256 * 256) {
    send_pointer(NULL);
  } else {
    // premultiplied ARGB, one pixel per unsigned long → premultiplied RGBA bytes
    uint8_t *rgba = malloc(n * 4);
    if (!rgba) die("out of memory");
    for (size_t i = 0; i < n; i++) {
      unsigned long p = ci->pixels[i];
      rgba[i * 4] = (uint8_t)(p >> 16);
      rgba[i * 4 + 1] = (uint8_t)(p >> 8);
      rgba[i * 4 + 2] = (uint8_t)p;
      rgba[i * 4 + 3] = (uint8_t)(p >> 24);
    }
    note_serial(cur.serial);
    send_pointer(rgba);
    free(rgba);
  }
  XFree(ci);
}

// XFixes says the cursor changed (to `serial`). More than 10 new serials in a second: an animated cursor — its shape
// is held (positions still go out) until it has been quiet for 0.5 s (hold_check).
static void shape_changed(uint32_t serial) {
  double now = now_ms();
  last_serial_at = now;
  if (now - anim_window_at >= 1000) {
    anim_window_at = now;
    anim_count = 0;
  }
  if (++anim_count > 10 && !animating) {
    animating = 1;
    if (!anim_logged) {
      anim_logged = 1;
      fprintf(stderr, "yoyo-x11video: the cursor changes its shape more than 10 times a second (animated); holding its shape while it does\n");
    }
  }
  if (animating) {
    pending_serial = serial;
    return;
  }
  if (serial != cur.serial || cur.none) read_shape();
}

// An animated cursor that has been still for 0.5 s: its shape now.
static void hold_check(void) {
  if (!animating || now_ms() - last_serial_at < 500) return;
  animating = 0;
  anim_count = 0;
  if (pending_serial != cur.serial) read_shape();
}

// X events: damage (the screen changed), a new pointer shape. Drained without blocking.
static void drain_x(void) {
  while (XPending(dpy)) {
    XEvent ev;
    XNextEvent(dpy, &ev);
    if (ev.type == damage_event + XDamageNotify) mark_dirty();
    else if (ev.type == fixes_event + XFixesCursorNotify) {
      if (client_cursor) shape_changed(((XFixesCursorNotifyEvent *)&ev)->cursor_serial);
      else mark_dirty();
    }
    // the screen changed size (xrandr): this picture size is fixed for the stream, so it ends (exit 3) and the client's
    // next stream starts at the new size
    else if (ev.type == ConfigureNotify && ev.xconfigure.window == root &&
             ((ev.xconfigure.width & ~1) != width || (ev.xconfigure.height & ~1) != height)) {
      fprintf(stderr, "yoyo-x11video: the screen is now %dx%d\n", ev.xconfigure.width, ev.xconfigure.height);
      exit(3);
    }
  }
}

// The pointer moved since the last look (Xvfb's software cursor is no damage).
static void poll_pointer(void) {
  Window r, c;
  int rx, ry, wx, wy;
  unsigned int mask;
  if (client_cursor) {
    hold_check();
    // a move of the pointer: a 'P' (its shape as last reported), never a picture change
    if (XQueryPointer(dpy, root, &r, &c, &rx, &ry, &wx, &wy, &mask) && (rx != cur.x || ry != cur.y)) {
      cur.x = rx;
      cur.y = ry;
      send_pointer(NULL);
    }
    return;
  }
  if (XQueryPointer(dpy, root, &r, &c, &rx, &ry, &wx, &wy, &mask) && (rx != ptr_x || ry != ptr_y)) {
    ptr_x = rx;
    ptr_y = ry;
    mark_dirty();
  }
}

// The pointer drawn over the grabbed picture (premultiplied ARGB, one pixel per unsigned long).
static void draw_pointer(void) {
  XFixesCursorImage *ci = XFixesGetCursorImage(dpy);
  if (!ci) return;
  int ox = ci->x - ci->xhot, oy = ci->y - ci->yhot;
  uint8_t *dst = (uint8_t *)img->data;
  for (int j = 0; j < ci->height; j++) {
    int y = oy + j;
    if (y < 0 || y >= height) continue;
    for (int i = 0; i < ci->width; i++) {
      int x = ox + i;
      if (x < 0 || x >= width) continue;
      unsigned long p = ci->pixels[j * ci->width + i];
      unsigned a = (p >> 24) & 0xff;
      if (!a) continue;
      uint8_t *d = dst + (size_t)y * img->bytes_per_line + (size_t)x * 4;
      d[0] = (uint8_t)((p & 0xff) + d[0] * (255 - a) / 255);
      d[1] = (uint8_t)(((p >> 8) & 0xff) + d[1] * (255 - a) / 255);
      d[2] = (uint8_t)(((p >> 16) & 0xff) + d[2] * (255 - a) / 255);
    }
  }
  ptr_x = ci->x;
  ptr_y = ci->y;
  XFree(ci);
}

// Grab the screen and encode it (x264enc.h enc_frame: `buf` the VBV buffer in kbit).
static void encode(int key, int kbps, float crf, int buf) {
  drain_x();
  int changed = dirty;
  double at = now_ms();
  // the damage is cleared first: a change while grabbing is reported again
  XDamageSubtract(dpy, damage, None, None);
  dirty = 0;
  told = 0;
  if (!XShmGetImage(dpy, root, img, 0, 0, AllPlanes)) die("XShmGetImage failed");
  if (!client_cursor) draw_pointer();
  enc_convert((const uint8_t *)img->data, img->bytes_per_line, yuv);
  const uint8_t *au = NULL;
  int is_key = 0;
  int64_t number = 0;
  int size = enc_frame(yuv, key, kbps, crf, buf, &au, &is_key, &number);
  if (size == 0) {
    record('S', NULL, 0, NULL, 0);
    return;
  }
  record_frame(is_key, changed, at, number, au, (size_t)size);
}

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--preset") && i + 1 < argc) enc_preset = argv[++i];
    else if (!strcmp(argv[i], "--threads") && i + 1 < argc) enc_threads = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--fps") && i + 1 < argc) enc_fps = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--cursor") && i + 1 < argc && !strcmp(argv[i + 1], "client")) client_cursor = 1, i++;
    else die("usage: yoyo-x11video [--preset <x264 preset>] [--threads <n>] [--fps <n>] [--cursor client]");
  }
  if (enc_fps < 1 || enc_fps > 60) die("--fps must be 1…60");
  signal(SIGPIPE, SIG_IGN);  // a write to a server that went away: EPIPE, an exit(0), not a signal
  dpy = XOpenDisplay(NULL);
  if (!dpy) die("cannot open the display ($DISPLAY / $XAUTHORITY)");
  root = DefaultRootWindow(dpy);
  XWindowAttributes wa;
  XGetWindowAttributes(dpy, root, &wa);
  width = wa.width & ~1;
  height = wa.height & ~1;
  if (width < 16 || height < 16) die("the screen is too small");
  int err;
  if (!XShmQueryExtension(dpy)) die("no MIT-SHM");
  if (!XDamageQueryExtension(dpy, &damage_event, &err)) die("no DAMAGE");
  if (!XFixesQueryExtension(dpy, &fixes_event, &err)) die("no XFIXES");
  img = XShmCreateImage(dpy, wa.visual, (unsigned)wa.depth, ZPixmap, NULL, &shm, (unsigned)width, (unsigned)height);
  if (!img || img->bits_per_pixel != 32) die("the screen is not 32 bits per pixel");
  shm.shmid = shmget(IPC_PRIVATE, (size_t)img->bytes_per_line * img->height, IPC_CREAT | 0600);
  if (shm.shmid < 0) die("shmget failed");
  shm.shmaddr = img->data = shmat(shm.shmid, NULL, 0);
  shm.readOnly = False;
  if (!XShmAttach(dpy, &shm)) die("XShmAttach failed");
  XSync(dpy, False);
  shmctl(shm.shmid, IPC_RMID, NULL);  // gone once both sides detach
  damage = XDamageCreate(dpy, root, XDamageReportNonEmpty);
  XSelectInput(dpy, root, StructureNotifyMask);
  XFixesSelectCursorInput(dpy, root, XFixesDisplayCursorNotifyMask);
  yuv = malloc((size_t)width * height * 3 / 2);
  if (!yuv) die("out of memory");
  enc_width = width;
  enc_height = height;
  record_hello(width, height, enc_kept_for(width, height) > 1 ? HELLO_REFS : 0);
  // the pointer before any picture (the client draws it from the first part on)
  if (client_cursor) read_shape();
  record('C', NULL, 0, NULL, 0);
  told = 1;

  char line[256];
  size_t have = 0;
  struct pollfd fds[2] = {{.fd = 0, .events = POLLIN}, {.fd = ConnectionNumber(dpy), .events = POLLIN}};
  for (;;) {
    XFlush(dpy);
    // the pointer is looked at every 33 ms (it moves without damage)
    int r = poll(fds, 2, 33);
    if (r < 0 && errno != EINTR) die("poll failed");
    drain_x();
    poll_pointer();
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
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
        else if (line[0] == 'I' && sscanf(line + 1, "%lld", &from) == 1) enc_forget(from);
        else fprintf(stderr, "yoyo-x11video: bad command \"%s\"\n", line);
        size_t used = (size_t)(nl - line) + 1;
        memmove(line, nl + 1, have - used);
        have -= used;
      }
      if (have == sizeof line - 1) have = 0;  // a line that long is no command
    }
  }
done:
  if (enc) x264_encoder_close(enc);
  return 0;
}
