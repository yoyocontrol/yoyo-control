// yoyo-x11clip: the clipboard of an X display for yoyo-linux (clipboard.mjs). Event-driven (no polling): XFixes says
// when the CLIPBOARD selection's owner changes (an app copied, or the owner went away); this program then asks the
// owner what it offers (TARGETS) and fetches what the summary needs — a file list (text/uri-list, else
// x-special/gnome-copied-files), a PNG (image/png), text (UTF8_STRING, text/plain;charset=utf-8, STRING, TEXT,
// text/plain) — and reports it once, as a JSON record. Large transfers use INCR, both ways. Only CLIPBOARD is watched
// (PRIMARY is every selection a mouse makes); a write (the phone's or the agent's text or files) owns CLIPBOARD and
// PRIMARY with the same content, so a paste works whichever one the app reads.
//
// Display: $DISPLAY / $XAUTHORITY. No arguments.
//
// stdin, commands (a header line, then exactly the byte counts it names):
//   T <n>\n<n bytes>                         own the selections with this UTF-8 text
//   F <uris> <gnome> <text> <img> <mime>\n<…> own them with files: text/uri-list, x-special/gnome-copied-files,
//                                            the paths as text, and (img > 0) one image's bytes under <mime>
//   I\n                                      the current item's PNG → an 'I' record (empty: none)
//   Q\n                                      quit (stdin's end too)
// stdout, records: one type byte, a 4-byte big-endian payload length, the payload:
//   'H' hello, once (empty)
//   'K' the clipboard changed: JSON {"own":bool, "owner":bool, "targets":[…], "uris"?, "text"?, "textSize"?,
//       "textCut"?, "png"?: {"size","width","height"}} — `own`: this program's own write (nothing else in it);
//       `owner` false: nobody owns CLIPBOARD (empty). The first one describes the clipboard at start.
//   'W' a write's result: "ok" or why not
//   'I' the PNG asked for: u32 BE how many 'K' records this process had sent when it answered (the item it belongs
//       to: the reader matches it to its changeCount), then the PNG (none: empty)
// stderr: log lines. Exit 0 on Q / end of stdin, 1 when the display can't be had or the X server goes (Xlib's I/O
// error handler). Protocol errors are logged and survived: a requestor window gone between its request and our answer
// (BadWindow), an owner's odd answer.
#define _GNU_SOURCE  // memmem
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/extensions/Xfixes.h>

#define TEXT_CAP (4u << 20)   // text kept for the summary (the client gets ≤ 1 MiB of it)
#define URIS_CAP (1u << 20)
#define PNG_CAP (64u << 20)
#define FETCH_TIMEOUT_MS 3000
#define XFER_TIMEOUT_MS 10000
#define MAX_XFERS 16

static Display *dpy;
static Window root, win;
static int fixes_event;
static Atom A_CLIPBOARD, A_TARGETS, A_INCR, A_UTF8, A_TEXT, A_PLAIN_UTF8, A_PLAIN, A_URIS, A_GNOME, A_PNG, A_KDE_HINT,
    A_TIMESTAMP, A_PROP, A_STAMP;
static size_t chunk_max;  // the largest property we write at once
static uint32_t reports;  // 'K' records sent

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

static void record(char type, const void *a, size_t an) {
  if (type == 'K') reports++;
  uint8_t head[5] = {(uint8_t)type, (uint8_t)(an >> 24), (uint8_t)(an >> 16), (uint8_t)(an >> 8), (uint8_t)an};
  write_all(head, 5);
  if (an) write_all(a, an);
}

// ---- a growing byte buffer (with a cap: what is beyond it is counted, not kept)
typedef struct {
  uint8_t *p;
  size_t n, cap, total, limit;
} Buf;

static void buf_add(Buf *b, const uint8_t *d, size_t n) {
  b->total += n;
  if (b->n >= b->limit) return;
  if (n > b->limit - b->n) n = b->limit - b->n;
  if (b->n + n > b->cap) {
    size_t c = b->cap ? b->cap : 4096;
    while (c < b->n + n) c *= 2;
    uint8_t *q = realloc(b->p, c);
    if (!q) {
      fprintf(stderr, "yoyo-x11clip: out of memory\n");
      exit(1);
    }
    b->p = q;
    b->cap = c;
  }
  memcpy(b->p + b->n, d, n);
  b->n += n;
}

static void buf_free(Buf *b) {
  free(b->p);
  memset(b, 0, sizeof *b);
}

// JSON string out of bytes (UTF-8 assumed; control characters escaped, a bad byte as U+FFFD)
static void json_str(Buf *out, const uint8_t *s, size_t n) {
  buf_add(out, (const uint8_t *)"\"", 1);
  for (size_t i = 0; i < n;) {
    uint8_t c = s[i];
    char esc[8];
    if (c == '"' || c == '\\') {
      esc[0] = '\\';
      esc[1] = (char)c;
      buf_add(out, (uint8_t *)esc, 2);
      i++;
    } else if (c < 0x20) {
      snprintf(esc, sizeof esc, "\\u%04x", c);
      buf_add(out, (uint8_t *)esc, 6);
      i++;
    } else if (c < 0x80) {
      buf_add(out, &c, 1);
      i++;
    } else {
      // a whole, valid UTF-8 sequence as it is; anything else U+FFFD
      int len = (c & 0xe0) == 0xc0 ? 2 : (c & 0xf0) == 0xe0 ? 3 : (c & 0xf8) == 0xf0 ? 4 : 0;
      int ok = len && i + (size_t)len <= n;
      for (int k = 1; ok && k < len; k++) ok = (s[i + k] & 0xc0) == 0x80;
      if (ok) {
        buf_add(out, s + i, (size_t)len);
        i += (size_t)len;
      } else {
        buf_add(out, (const uint8_t *)"\xef\xbf\xbd", 3);
        i++;
      }
    }
  }
  buf_add(out, (const uint8_t *)"\"", 1);
}

static void json_raw(Buf *out, const char *s) { buf_add(out, (const uint8_t *)s, strlen(s)); }

// The PNG of the last report (kept until the clipboard changes): what 'I' answers.
static Buf last_png;

// ---- what this program owns (after a write)
static struct {
  int clipboard, primary;  // owned now
  Time at;
  Buf text, uris, gnome, img;
  Atom img_type;
} own;

static void own_free(void) {
  buf_free(&own.text);
  buf_free(&own.uris);
  buf_free(&own.gnome);
  buf_free(&own.img);
  own.img_type = None;
}

// ---- INCR transfers out (a requestor reading a large value)
static struct {
  int used;
  Window req;
  Atom prop, type;
  uint8_t *data;  // a copy: the owner's data may change meanwhile
  size_t n, off;
  double at;
} xfers[MAX_XFERS];

// A protocol error (a requestor that went away, an atom that isn't one): logged, never fatal — the default handler
// would exit and lose the clipboard a write owns.
static int on_x_error(Display *d, XErrorEvent *e) {
  char what[128] = "";
  XGetErrorText(d, e->error_code, what, sizeof what);
  // a requestor gone: its transfer goes too (its slot would be held until the timeout)
  int dropped = 0;
  for (int i = 0; i < MAX_XFERS; i++)
    if (xfers[i].used && xfers[i].req == e->resourceid) {
      free(xfers[i].data);
      xfers[i].used = 0;
      dropped++;
    }
  // (one line per kind of error at most every second: a burst of them is one event)
  static double last = 0;
  static unsigned long quiet = 0;
  double now = now_ms();
  if (now - last < 1000) {
    quiet++;
  } else {
    fprintf(stderr, "yoyo-x11clip: X error ignored: %s (request %d.%d, resource 0x%lx%s)%s\n", what, e->request_code, e->minor_code, e->resourceid,
            dropped ? ", its transfer dropped" : "", quiet ? " — and earlier ones" : "");
    last = now;
    quiet = 0;
  }
  return 0;
}


// ---- the fetch of a new owner's content (one conversion at a time)
enum { WANT_NONE, WANT_TARGETS, WANT_URIS, WANT_PNG, WANT_TEXT };
static struct {
  int active;
  Time ts;
  int want;
  Atom want_atom;
  double deadline;
  int incr;  // reading an INCR transfer
  Buf data;  // what the current conversion gave
  Atom data_type;  // its property type and format
  int data_format;
  // the results
  Atom *targets;
  int ntargets;
  Buf uris, text, png;
  int got_uris, got_text, got_png;
} f;

static Atom pick(const Atom *prefs, int n) {
  for (int i = 0; i < n; i++)
    for (int k = 0; k < f.ntargets; k++)
      if (f.targets[k] == prefs[i]) return prefs[i];
  return None;
}

static int has(Atom a) {
  for (int k = 0; k < f.ntargets; k++)
    if (f.targets[k] == a) return 1;
  return 0;
}

static void fetch_reset(void) {
  buf_free(&f.data);
  buf_free(&f.uris);
  buf_free(&f.text);
  buf_free(&f.png);
  free(f.targets);
  memset(&f, 0, sizeof f);
}

static int png_dims(const Buf *b, uint32_t *w, uint32_t *h) {
  static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a};
  if (b->n < 24 || memcmp(b->p, sig, 8) || memcmp(b->p + 12, "IHDR", 4)) return 0;
  *w = (uint32_t)b->p[16] << 24 | (uint32_t)b->p[17] << 16 | (uint32_t)b->p[18] << 8 | b->p[19];
  *h = (uint32_t)b->p[20] << 24 | (uint32_t)b->p[21] << 16 | (uint32_t)b->p[22] << 8 | b->p[23];
  return *w > 0 && *h > 0;
}

// The summary of what was fetched: a 'K' record.
static void report(int owner) {
  Buf j = {0};
  j.limit = (size_t)-1;
  json_raw(&j, "{\"own\":false,\"owner\":");
  json_raw(&j, owner ? "true" : "false");
  json_raw(&j, ",\"targets\":[");
  for (int i = 0; i < f.ntargets; i++) {
    char *name = XGetAtomName(dpy, f.targets[i]);
    if (!name) continue;
    if (i) json_raw(&j, ",");
    json_str(&j, (uint8_t *)name, strlen(name));
    XFree(name);
  }
  json_raw(&j, "]");
  if (f.got_uris) {
    json_raw(&j, ",\"uris\":");
    json_str(&j, f.uris.p, f.uris.n);
  }
  if (f.got_text) {
    char num[64];
    json_raw(&j, ",\"text\":");
    json_str(&j, f.text.p, f.text.n);
    snprintf(num, sizeof num, ",\"textSize\":%zu,\"textCut\":%s", f.text.total, f.text.total > f.text.n ? "true" : "false");
    json_raw(&j, num);
  }
  uint32_t w, h;
  buf_free(&last_png);
  if (f.got_png && f.png.total <= f.png.limit && png_dims(&f.png, &w, &h)) {
    char num[96];
    snprintf(num, sizeof num, ",\"png\":{\"size\":%zu,\"width\":%u,\"height\":%u}", f.png.n, w, h);
    json_raw(&j, num);
    last_png = f.png;  // kept for 'I'
    memset(&f.png, 0, sizeof f.png);
    f.got_png = 0;
  } else if (f.got_png) {
    buf_free(&f.png);
    f.got_png = 0;
  }
  json_raw(&j, "}");
  record('K', j.p, j.n);
  buf_free(&j);
}

static void convert(int want, Atom target) {
  f.want = want;
  f.want_atom = target;
  f.incr = 0;
  buf_free(&f.data);
  f.data.limit = want == WANT_PNG ? PNG_CAP : want == WANT_URIS ? URIS_CAP : want == WANT_TEXT ? TEXT_CAP : (1u << 20);
  f.deadline = now_ms() + FETCH_TIMEOUT_MS;
  XDeleteProperty(dpy, win, A_PROP);
  XConvertSelection(dpy, A_CLIPBOARD, target, A_PROP, win, f.ts);
}

static const Atom *text_prefs(int *n) {
  static Atom prefs[5];
  prefs[0] = A_UTF8;
  prefs[1] = A_PLAIN_UTF8;
  prefs[2] = XA_STRING;
  prefs[3] = A_TEXT;
  prefs[4] = A_PLAIN;
  *n = 5;
  return prefs;
}

// The next thing to fetch, by what came so far: files, else a PNG, else text; then the report.
static void next_step(void) {
  int nt;
  const Atom *tp = text_prefs(&nt);
  if (f.want == WANT_TARGETS) {
    if (has(A_KDE_HINT)) goto done;  // a password manager's item: nothing of it is read
    Atom u = has(A_URIS) ? A_URIS : has(A_GNOME) ? A_GNOME : None;
    if (u) return convert(WANT_URIS, u);
    f.want = WANT_URIS;
  }
  if (f.want == WANT_URIS) {
    if (f.got_uris && f.uris.n && memmem(f.uris.p, f.uris.n, "file:", 5)) goto done;
    if (has(A_PNG)) return convert(WANT_PNG, A_PNG);
    f.want = WANT_PNG;
  }
  if (f.want == WANT_PNG) {
    uint32_t w, h;
    if (f.got_png && f.png.total <= f.png.limit && png_dims(&f.png, &w, &h)) goto done;
    Atom t = pick(tp, nt);
    if (t) return convert(WANT_TEXT, t);
  }
done:
  report(1);
  fetch_reset();
}

// What a finished conversion gave (`ok` 0: refused or timed out).
static void conversion_done(int ok) {
  if (f.want == WANT_TARGETS) {
    // atoms only as atoms (ICCCM: type ATOM, format 32): anything else would be read as garbage atom ids
    if (ok && (f.data_type != XA_ATOM || f.data_format != 32)) {
      fprintf(stderr, "yoyo-x11clip: the owner answered TARGETS with format %d of another type: no targets\n", f.data_format);
      ok = 0;
    }
    if (ok && f.data.n >= sizeof(Atom)) {
      f.ntargets = (int)(f.data.n / sizeof(Atom));
      f.targets = malloc(f.data.n);
      memcpy(f.targets, f.data.p, f.data.n);
    }
  } else if (f.want == WANT_URIS && ok) {
    f.uris = f.data;
    memset(&f.data, 0, sizeof f.data);
    f.got_uris = 1;
  } else if (f.want == WANT_PNG && ok) {
    f.png = f.data;
    memset(&f.data, 0, sizeof f.data);
    f.got_png = 1;
  } else if (f.want == WANT_TEXT && ok) {
    f.text = f.data;
    memset(&f.data, 0, sizeof f.data);
    f.got_text = 1;
  }
  buf_free(&f.data);
  next_step();
}

// Read (and delete) our property: append to f.data. Returns the type, or None when there was nothing.
static Atom take_property(unsigned long *items_out) {
  Atom type = None;
  int format = 0;
  unsigned long items = 0, after = 0;
  unsigned char *data = NULL;
  long offset = 0;
  *items_out = 0;
  for (;;) {
    if (XGetWindowProperty(dpy, win, A_PROP, offset, 1 << 20, False, AnyPropertyType, &type, &format, &items, &after, &data) != Success)
      return None;
    if (type == None) {
      if (data) XFree(data);
      return None;
    }
    size_t unit = format == 32 ? sizeof(long) : format == 16 ? sizeof(short) : 1;
    if (type == A_INCR) {
      if (data) XFree(data);
      XDeleteProperty(dpy, win, A_PROP);
      return A_INCR;
    }
    if (format == 32 && type == XA_ATOM) {
      // atoms come as longs; keep them as Atom
      for (unsigned long i = 0; i < items; i++) {
        Atom a = (Atom)((long *)data)[i];
        buf_add(&f.data, (uint8_t *)&a, sizeof a);
      }
    } else {
      buf_add(&f.data, data, items * unit);
    }
    *items_out += items;
    f.data_type = type;
    f.data_format = format;
    XFree(data);
    if (!after) break;
    // the offset counts 32-bit units: format 32 one per item, 16 half, 8 a quarter
    offset += (long)(items * (unsigned long)format / 32);
  }
  XDeleteProperty(dpy, win, A_PROP);
  return type;
}

static void on_selection_notify(XSelectionEvent *ev) {
  if (!f.active || ev->requestor != win || ev->selection != A_CLIPBOARD || ev->target != f.want_atom) return;
  if (ev->property == None) return conversion_done(0);
  unsigned long items;
  Atom type = take_property(&items);
  if (type == A_INCR) {
    f.incr = 1;
    f.deadline = now_ms() + FETCH_TIMEOUT_MS;
    return;
  }
  conversion_done(type != None);
}

static void on_property(XPropertyEvent *ev) {
  if (ev->window == win && ev->atom == A_PROP && ev->state == PropertyNewValue && f.active && f.incr) {
    unsigned long items;
    size_t before = f.data.total;
    Atom type = take_property(&items);
    f.deadline = now_ms() + FETCH_TIMEOUT_MS;
    if (type == None || f.data.total == before) {
      f.incr = 0;
      conversion_done(1);  // the zero-length chunk: done
    }
    return;
  }
  // a requestor deleted what we gave it: the next chunk of its INCR transfer
  if (ev->state != PropertyDelete) return;
  for (int i = 0; i < MAX_XFERS; i++) {
    if (!xfers[i].used || xfers[i].req != ev->window || xfers[i].prop != ev->atom) continue;
    size_t left = xfers[i].n - xfers[i].off;
    size_t n = left < chunk_max ? left : chunk_max;
    XChangeProperty(dpy, xfers[i].req, xfers[i].prop, xfers[i].type, 8, PropModeReplace, xfers[i].data + xfers[i].off, (int)n);
    xfers[i].off += n;
    xfers[i].at = now_ms();
    if (n == 0) {
      // the zero-length chunk went out: done
      XSelectInput(dpy, xfers[i].req, NoEventMask);
      free(xfers[i].data);
      xfers[i].used = 0;
    }
    return;
  }
}

// An owner change (XFixes): a new fetch, unless it is us.
static void on_owner_change(XFixesSelectionNotifyEvent *ev) {
  if (ev->selection != A_CLIPBOARD) return;
  if (ev->owner == win) return;  // our own write (reported when made)
  fetch_reset();
  if (ev->owner == None) {
    report(0);
    return;
  }
  f.active = 1;
  f.ts = ev->selection_timestamp;
  convert(WANT_TARGETS, A_TARGETS);
}

// ---- serving what we own
static int own_value(Atom target, const Buf **b, Atom *type) {
  int nt;
  const Atom *tp = text_prefs(&nt);
  for (int i = 0; i < nt; i++)
    if (target == tp[i] && own.text.n) {
      *b = &own.text;
      *type = target == A_TEXT ? A_UTF8 : target;
      return 1;
    }
  if (target == A_URIS && own.uris.n) return *b = &own.uris, *type = A_URIS, 1;
  if (target == A_GNOME && own.gnome.n) return *b = &own.gnome, *type = A_GNOME, 1;
  if (own.img_type != None && target == own.img_type && own.img.n) return *b = &own.img, *type = own.img_type, 1;
  return 0;
}

static void on_selection_request(XSelectionRequestEvent *rq) {
  XSelectionEvent ev = {.type = SelectionNotify, .display = rq->display, .requestor = rq->requestor, .selection = rq->selection,
                        .target = rq->target, .property = None, .time = rq->time};
  Atom prop = rq->property != None ? rq->property : rq->target;  // an obsolete client: the target names the property
  int ours = (rq->selection == A_CLIPBOARD && own.clipboard) || (rq->selection == XA_PRIMARY && own.primary);
  if (ours && rq->owner == win && (rq->time == CurrentTime || rq->time >= own.at)) {
    if (rq->target == A_TARGETS) {
      Atom list[12];
      int n = 0;
      list[n++] = A_TARGETS;
      list[n++] = A_TIMESTAMP;
      if (own.text.n) list[n++] = A_UTF8, list[n++] = A_PLAIN_UTF8, list[n++] = XA_STRING, list[n++] = A_TEXT, list[n++] = A_PLAIN;
      if (own.uris.n) list[n++] = A_URIS;
      if (own.gnome.n) list[n++] = A_GNOME;
      if (own.img_type != None && own.img.n) list[n++] = own.img_type;
      XChangeProperty(dpy, rq->requestor, prop, XA_ATOM, 32, PropModeReplace, (unsigned char *)list, n);
      ev.property = prop;
    } else if (rq->target == A_TIMESTAMP) {
      long t = (long)own.at;
      XChangeProperty(dpy, rq->requestor, prop, XA_INTEGER, 32, PropModeReplace, (unsigned char *)&t, 1);
      ev.property = prop;
    } else {
      const Buf *b;
      Atom type;
      if (own_value(rq->target, &b, &type)) {
        if (b->n <= chunk_max) {
          XChangeProperty(dpy, rq->requestor, prop, type, 8, PropModeReplace, b->p, (int)b->n);
          ev.property = prop;
        } else {
          int slot = -1;
          for (int i = 0; i < MAX_XFERS && slot < 0; i++)
            if (!xfers[i].used) slot = i;
          // all taken (readers that never finish): the oldest gives way
          if (slot < 0) {
            slot = 0;
            for (int i = 1; i < MAX_XFERS; i++)
              if (xfers[i].at < xfers[slot].at) slot = i;
            XSelectInput(dpy, xfers[slot].req, NoEventMask);
            free(xfers[slot].data);
            xfers[slot].used = 0;
          }
          if (slot >= 0) {
            xfers[slot].used = 1;
            xfers[slot].req = rq->requestor;
            xfers[slot].prop = prop;
            xfers[slot].type = type;
            xfers[slot].data = malloc(b->n);
            memcpy(xfers[slot].data, b->p, b->n);
            xfers[slot].n = b->n;
            xfers[slot].off = 0;
            xfers[slot].at = now_ms();
            XSelectInput(dpy, rq->requestor, PropertyChangeMask);
            long size = (long)b->n;
            XChangeProperty(dpy, rq->requestor, prop, A_INCR, 32, PropModeReplace, (unsigned char *)&size, 1);
            ev.property = prop;
          }
        }
      }
    }
  }
  XSendEvent(dpy, rq->requestor, False, NoEventMask, (XEvent *)&ev);
}

static void on_selection_clear(XSelectionClearEvent *ev) {
  if (ev->selection == A_CLIPBOARD) own.clipboard = 0;
  if (ev->selection == XA_PRIMARY) own.primary = 0;
  if (!own.clipboard && !own.primary) own_free();
}

// A server timestamp for owning a selection (ICCCM: not CurrentTime): a zero-length append to our own property.
static Time server_time(void) {
  XChangeProperty(dpy, win, A_STAMP, XA_STRING, 8, PropModeAppend, (unsigned char *)"", 0);
  XEvent ev;
  for (;;) {
    XWindowEvent(dpy, win, PropertyChangeMask, &ev);
    if (ev.xproperty.atom == A_STAMP) return ev.xproperty.time;
    on_property(&ev.xproperty);
  }
}

static void own_selections(void) {
  Time t = server_time();
  own.at = t;
  XSetSelectionOwner(dpy, A_CLIPBOARD, win, t);
  XSetSelectionOwner(dpy, XA_PRIMARY, win, t);
  own.clipboard = XGetSelectionOwner(dpy, A_CLIPBOARD) == win;
  own.primary = XGetSelectionOwner(dpy, XA_PRIMARY) == win;
  if (own.clipboard) {
    fetch_reset();
    buf_free(&last_png);
    record('K', "{\"own\":true,\"owner\":true}", 25);
    record('W', "ok", 2);
  } else {
    record('W', "another program holds the clipboard", 35);
  }
}

// ---- stdin commands
static Buf in = {.limit = (size_t)-1};
static size_t in_off = 0;

static void handle_commands(void) {
  for (;;) {
    uint8_t *start = in.p + in_off;
    size_t have = in.n - in_off;
    uint8_t *nl = memchr(start, '\n', have);
    if (!nl) break;
    size_t head_n = (size_t)(nl - start);
    char head[256];
    if (head_n >= sizeof head) {
      fprintf(stderr, "yoyo-x11clip: a command line too long\n");
      exit(1);
    }
    memcpy(head, start, head_n);
    head[head_n] = 0;
    uint8_t *body = nl + 1;
    size_t body_have = have - head_n - 1;
    if (head[0] == 'Q') exit(0);
    if (head[0] == 'I') {
      in_off += head_n + 1;
      uint8_t ord[4] = {(uint8_t)(reports >> 24), (uint8_t)(reports >> 16), (uint8_t)(reports >> 8), (uint8_t)reports};
      uint8_t *msg = malloc(4 + last_png.n);
      if (!msg) {
        fprintf(stderr, "yoyo-x11clip: out of memory\n");
        exit(1);
      }
      memcpy(msg, ord, 4);
      if (last_png.n) memcpy(msg + 4, last_png.p, last_png.n);
      record('I', msg, 4 + last_png.n);
      free(msg);
      continue;
    }
    if (head[0] == 'T') {
      size_t n = strtoul(head + 1, NULL, 10);
      if (body_have < n) break;
      own_free();
      own.text.limit = (size_t)-1;
      buf_add(&own.text, body, n);
      in_off += head_n + 1 + n;
      own_selections();
      continue;
    }
    if (head[0] == 'F') {
      size_t nu = 0, ng = 0, ntx = 0, ni = 0;
      char mime[128] = "-";
      if (sscanf(head + 1, "%zu %zu %zu %zu %127s", &nu, &ng, &ntx, &ni, mime) < 4) {
        fprintf(stderr, "yoyo-x11clip: bad command \"%s\"\n", head);
        exit(1);
      }
      size_t n = nu + ng + ntx + ni;
      if (body_have < n) break;
      own_free();
      own.uris.limit = own.gnome.limit = own.text.limit = own.img.limit = (size_t)-1;
      buf_add(&own.uris, body, nu);
      buf_add(&own.gnome, body + nu, ng);
      buf_add(&own.text, body + nu + ng, ntx);
      if (ni && strcmp(mime, "-")) {
        buf_add(&own.img, body + nu + ng + ntx, ni);
        own.img_type = XInternAtom(dpy, mime, False);
      }
      in_off += head_n + 1 + n;
      own_selections();
      continue;
    }
    fprintf(stderr, "yoyo-x11clip: bad command \"%s\"\n", head);
    exit(1);
  }
  if (in_off == in.n) {
    in.n = 0;
    in_off = 0;
  }
}

int main(void) {
  signal(SIGPIPE, SIG_IGN);  // a write to a server that went away: EPIPE, an exit(0), not a signal
  XSetErrorHandler(on_x_error);
  dpy = XOpenDisplay(NULL);
  if (!dpy) {
    fprintf(stderr, "yoyo-x11clip: cannot open the display ($DISPLAY / $XAUTHORITY)\n");
    return 1;
  }
  int err;
  if (!XFixesQueryExtension(dpy, &fixes_event, &err)) {
    fprintf(stderr, "yoyo-x11clip: no XFIXES\n");
    return 1;
  }
  root = DefaultRootWindow(dpy);
  win = XCreateSimpleWindow(dpy, root, -10, -10, 1, 1, 0, 0, 0);
  XSelectInput(dpy, win, PropertyChangeMask);
  A_CLIPBOARD = XInternAtom(dpy, "CLIPBOARD", False);
  A_TARGETS = XInternAtom(dpy, "TARGETS", False);
  A_INCR = XInternAtom(dpy, "INCR", False);
  A_UTF8 = XInternAtom(dpy, "UTF8_STRING", False);
  A_TEXT = XInternAtom(dpy, "TEXT", False);
  A_PLAIN_UTF8 = XInternAtom(dpy, "text/plain;charset=utf-8", False);
  A_PLAIN = XInternAtom(dpy, "text/plain", False);
  A_URIS = XInternAtom(dpy, "text/uri-list", False);
  A_GNOME = XInternAtom(dpy, "x-special/gnome-copied-files", False);
  A_PNG = XInternAtom(dpy, "image/png", False);
  A_KDE_HINT = XInternAtom(dpy, "x-kde-passwordManagerHint", False);
  A_TIMESTAMP = XInternAtom(dpy, "TIMESTAMP", False);
  A_PROP = XInternAtom(dpy, "YOYO_CLIP", False);
  A_STAMP = XInternAtom(dpy, "YOYO_CLIP_STAMP", False);
  long max = XExtendedMaxRequestSize(dpy);
  if (!max) max = XMaxRequestSize(dpy);
  chunk_max = (size_t)max * 4 - 1024;
  if (chunk_max > 256 * 1024) chunk_max = 256 * 1024;
  XFixesSelectSelectionInput(dpy, root, A_CLIPBOARD,
                             XFixesSetSelectionOwnerNotifyMask | XFixesSelectionWindowDestroyNotifyMask | XFixesSelectionClientCloseNotifyMask);
  record('H', NULL, 0);
  // the clipboard as it is now: as if its owner had just changed
  {
    XFixesSelectionNotifyEvent ev = {.selection = A_CLIPBOARD, .owner = XGetSelectionOwner(dpy, A_CLIPBOARD), .selection_timestamp = CurrentTime};
    on_owner_change(&ev);
  }
  struct pollfd fds[2] = {{.fd = 0, .events = POLLIN}, {.fd = ConnectionNumber(dpy), .events = POLLIN}};
  for (;;) {
    XFlush(dpy);
    while (XPending(dpy)) {
      XEvent ev;
      XNextEvent(dpy, &ev);
      if (ev.type == fixes_event + XFixesSelectionNotify) {
        on_owner_change((XFixesSelectionNotifyEvent *)&ev);
      } else if (ev.type == SelectionNotify) {
        on_selection_notify(&ev.xselection);
      } else if (ev.type == SelectionRequest) {
        on_selection_request(&ev.xselectionrequest);
      } else if (ev.type == SelectionClear) {
        on_selection_clear(&ev.xselectionclear);
      } else if (ev.type == PropertyNotify) {
        on_property(&ev.xproperty);
      }
    }
    XFlush(dpy);
    // a wake-up every 200 ms only while there are deadlines (an owner that never answers, a requestor that never
    // reads); otherwise asleep until X or stdin has something (an idle clipboard costs nothing)
    int busy = f.active;
    for (int i = 0; i < MAX_XFERS && !busy; i++) busy = xfers[i].used;
    int r = poll(fds, 2, busy ? 200 : -1);
    if (r < 0 && errno != EINTR) return 1;
    double now = now_ms();
    if (f.active && now > f.deadline) {
      fprintf(stderr, "yoyo-x11clip: the clipboard's owner did not answer in %d s\n", FETCH_TIMEOUT_MS / 1000);
      f.incr = 0;
      conversion_done(0);
    }
    for (int i = 0; i < MAX_XFERS; i++)
      if (xfers[i].used && now - xfers[i].at > XFER_TIMEOUT_MS) {
        XSelectInput(dpy, xfers[i].req, NoEventMask);
        free(xfers[i].data);
        xfers[i].used = 0;
      }
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      uint8_t buf[65536];
      ssize_t n = read(0, buf, sizeof buf);
      if (n <= 0) return 0;
      buf_add(&in, buf, (size_t)n);
      handle_commands();
    }
  }
}
