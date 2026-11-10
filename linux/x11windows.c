// yoyo-x11windows: the windows of an X display for yoyo-linux (windows.mjs): `GET /windows`, `GET /hit` and
// `/frame?visible=`'s covering, and the Escape watch of `POST /automation`.
//
//   yoyo-x11windows                one shot: the top-level windows as one JSON object on stdout, then exit 0
//   yoyo-x11windows --esc [--xtest]  long-running: a line per Escape pressed (see below) until stdin ends
//
// Display: $DISPLAY / $XAUTHORITY.
//
// One shot. The root window's children in the X stacking order (bottom → top: what is drawn over what, compositor or
// not), only the viewable InputOutput ones: a window manager's frame is reported with its client's identity (the
// descendant carrying WM_STATE), an override-redirect window (a menu, a tooltip, a popup) with its own. Never a title.
//   {"screen":[w,h], "active":<the client window _NET_ACTIVE_WINDOW names, 0: none>,
//    "windows":[{"id":<client window>, "or":<override-redirect>, "class":"<WM_CLASS class>"|null,
//                "instance":"<WM_CLASS instance>"|null, "pid":<_NET_WM_PID, 0: none>,
//                "type":"<_NET_WM_WINDOW_TYPE_* lowercased: normal, desktop, dock, dialog, menu, …>"|null,
//                "hidden":<_NET_WM_STATE_HIDDEN>, "above":<_NET_WM_STATE_ABOVE>,
//                "x","y","w","h":<root pixels: the frame's outer rectangle, less a client-side-decorated window's
//                                 invisible shadow (_GTK_FRAME_EXTENTS)>}, …]}
// Strings are the property's bytes with JSON's escapes (WM_CLASS is Latin-1 by the ICCCM; apps put UTF-8 there too:
// the reader decodes UTF-8). Windows going away during the walk are skipped (BadWindow is survived).
//
// --esc. XInput 2 raw key presses on the root (every keyboard, nothing grabbed: the key still reaches the app in
// front): "H\n" once listening, then "E\n" per Escape pressed without Shift / Control / Alt / Super that does not come
// from an XTEST device (xdotool, so the server's own /input and the phones' keys, posts through XTEST; `--xtest` counts
// those too: for trying it on a display without a keyboard). Exit 0 at stdin's end, 1 without the display or XInput
// 2, or when the X server goes.
//
// stderr: log lines.
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <X11/extensions/XInput2.h>

static Display *dpy;
static Window root;
static Atom A_WM_STATE, A_PID, A_TYPE, A_STATE, A_HIDDEN, A_ABOVE, A_ACTIVE, A_GTK_EXTENTS;

static int on_x_error(Display *d, XErrorEvent *e) {
  (void)d;
  (void)e;  // a window gone between the tree and its properties: skipped
  return 0;
}

static int on_io_error(Display *d) {
  (void)d;
  fprintf(stderr, "yoyo-x11windows: the X server went away\n");
  exit(1);
}

/** A property of 32-bit items: their count (0: none / wrong type); `*out` to XFree. */
static unsigned long prop32(Window w, Atom name, Atom type, unsigned char **out) {
  Atom got;
  int fmt;
  unsigned long n = 0, after;
  *out = NULL;
  if (XGetWindowProperty(dpy, w, name, 0, 1024, False, type, &got, &fmt, &n, &after, out) != Success) return 0;
  if (!*out || fmt != 32 || got != type) {
    if (*out) XFree(*out);
    *out = NULL;
    return 0;
  }
  return n;
}

static int has_prop(Window w, Atom name) {
  Atom got;
  int fmt;
  unsigned long n, after;
  unsigned char *data = NULL;
  if (XGetWindowProperty(dpy, w, name, 0, 0, False, AnyPropertyType, &got, &fmt, &n, &after, &data) != Success) return 0;
  if (data) XFree(data);
  return got != None;
}

/** The client window inside a frame: the first descendant (breadth-first, depth ≤ 3) carrying WM_STATE; 0 if none. */
static Window client_of(Window w, int depth) {
  if (has_prop(w, A_WM_STATE)) return w;
  if (depth >= 3) return 0;
  Window r, parent, *kids = NULL;
  unsigned int n = 0;
  if (!XQueryTree(dpy, w, &r, &parent, &kids, &n)) return 0;
  Window found = 0;
  for (unsigned int i = 0; i < n && !found; i++)
    if (has_prop(kids[i], A_WM_STATE)) found = kids[i];
  for (unsigned int i = n; i-- > 0 && !found;) found = client_of(kids[i], depth + 1);
  if (kids) XFree(kids);
  return found;
}

static void put_json_string(const char *s) {
  if (!s) {
    fputs("null", stdout);
    return;
  }
  putchar('"');
  for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
    if (*p == '"' || *p == '\\') printf("\\%c", *p);
    else if (*p < 0x20) printf("\\u%04x", *p);
    else putchar(*p);
  }
  putchar('"');
}

static int list_windows(void) {
  A_WM_STATE = XInternAtom(dpy, "WM_STATE", False);
  A_PID = XInternAtom(dpy, "_NET_WM_PID", False);
  A_TYPE = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
  A_STATE = XInternAtom(dpy, "_NET_WM_STATE", False);
  A_HIDDEN = XInternAtom(dpy, "_NET_WM_STATE_HIDDEN", False);
  A_ABOVE = XInternAtom(dpy, "_NET_WM_STATE_ABOVE", False);
  A_ACTIVE = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
  A_GTK_EXTENTS = XInternAtom(dpy, "_GTK_FRAME_EXTENTS", False);

  unsigned char *data;
  unsigned long active = 0;
  if (prop32(root, A_ACTIVE, XA_WINDOW, &data)) active = ((unsigned long *)data)[0];
  if (data) XFree(data);

  printf("{\"screen\":[%d,%d],\"active\":%lu,\"windows\":[", DisplayWidth(dpy, DefaultScreen(dpy)), DisplayHeight(dpy, DefaultScreen(dpy)), active);
  Window r, parent, *kids = NULL;
  unsigned int n = 0;
  if (!XQueryTree(dpy, root, &r, &parent, &kids, &n)) n = 0;
  int first = 1;
  for (unsigned int i = 0; i < n; i++) {
    XWindowAttributes a;
    if (!XGetWindowAttributes(dpy, kids[i], &a) || a.map_state != IsViewable || a.class != InputOutput) continue;
    Window client = a.override_redirect ? kids[i] : client_of(kids[i], 0);
    if (!client) client = kids[i];  // no window manager: the window itself
    XClassHint hint = { NULL, NULL };
    int classed = XGetClassHint(dpy, client, &hint);
    unsigned long pid = 0;
    if (prop32(client, A_PID, XA_CARDINAL, &data)) pid = ((unsigned long *)data)[0];
    if (data) XFree(data);
    if (!classed && !pid) continue;  // nobody's: a window manager's own, an input sink
    char *type = NULL;
    if (prop32(client, A_TYPE, XA_ATOM, &data)) {
      char *name = XGetAtomName(dpy, ((Atom *)data)[0]);
      const char *pre = "_NET_WM_WINDOW_TYPE_";
      if (name && !strncmp(name, pre, strlen(pre))) {
        type = strdup(name + strlen(pre));
        for (char *c = type; *c; c++) *c = (*c >= 'A' && *c <= 'Z') ? *c - 'A' + 'a' : *c;
      }
      if (name) XFree(name);
    }
    if (data) XFree(data);
    int hidden = 0, above = 0;
    unsigned long ns = prop32(client, A_STATE, XA_ATOM, &data);
    for (unsigned long k = 0; k < ns; k++) {
      Atom s = ((Atom *)data)[k];
      if (s == A_HIDDEN) hidden = 1;
      if (s == A_ABOVE) above = 1;
    }
    if (data) XFree(data);
    // the frame's outer rectangle (root's children: root coordinates), less a client-side shadow
    long x = a.x, y = a.y, w = a.width + 2L * a.border_width, h = a.height + 2L * a.border_width;
    if (prop32(client, A_GTK_EXTENTS, XA_CARDINAL, &data) >= 4) {
      unsigned long *e = (unsigned long *)data;  // left, right, top, bottom
      if ((long)(e[0] + e[1]) < w && (long)(e[2] + e[3]) < h) {
        x += e[0];
        y += e[2];
        w -= e[0] + e[1];
        h -= e[2] + e[3];
      }
    }
    if (data) XFree(data);
    printf("%s{\"id\":%lu,\"or\":%s,\"class\":", first ? "" : ",", client, a.override_redirect ? "true" : "false");
    put_json_string(classed ? hint.res_class : NULL);
    fputs(",\"instance\":", stdout);
    put_json_string(classed ? hint.res_name : NULL);
    printf(",\"pid\":%lu,\"type\":", pid);
    put_json_string(type);
    printf(",\"hidden\":%s,\"above\":%s,\"x\":%ld,\"y\":%ld,\"w\":%ld,\"h\":%ld}", hidden ? "true" : "false", above ? "true" : "false", x, y, w, h);
    first = 0;
    free(type);
    if (hint.res_name) XFree(hint.res_name);
    if (hint.res_class) XFree(hint.res_class);
  }
  if (kids) XFree(kids);
  fputs("]}\n", stdout);
  return fflush(stdout) == 0 ? 0 : 1;
}

/** The device's name says it is an XTEST one (the server's own xdotool input). */
static int is_xtest(int deviceid) {
  int n = 0;
  XIDeviceInfo *info = XIQueryDevice(dpy, deviceid, &n);
  int xtest = info && n > 0 && info[0].name && strstr(info[0].name, "XTEST") != NULL;
  if (info) XIFreeDeviceInfo(info);
  return xtest;
}

static int watch_escape(int count_xtest) {
  int opcode, ev, err, major = 2, minor = 0;
  if (!XQueryExtension(dpy, "XInputExtension", &opcode, &ev, &err) || XIQueryVersion(dpy, &major, &minor) != Success) {
    fprintf(stderr, "yoyo-x11windows: no XInput 2\n");
    return 1;
  }
  unsigned char bits[XIMaskLen(XI_LASTEVENT)] = { 0 };
  XISetMask(bits, XI_RawKeyPress);
  XIEventMask mask = { XIAllMasterDevices, sizeof bits, bits };
  XISelectEvents(dpy, root, &mask, 1);
  XSync(dpy, False);
  KeyCode esc = XKeysymToKeycode(dpy, XK_Escape);
  fputs("H\n", stdout);
  fflush(stdout);
  struct pollfd fds[2] = { { 0, POLLIN, 0 }, { ConnectionNumber(dpy), POLLIN, 0 } };
  for (;;) {
    while (XPending(dpy)) {
      XEvent e;
      XNextEvent(dpy, &e);
      if (e.xcookie.type != GenericEvent || e.xcookie.extension != opcode || !XGetEventData(dpy, &e.xcookie)) continue;
      if (e.xcookie.evtype == XI_RawKeyPress) {
        XIRawEvent *raw = e.xcookie.data;
        if ((KeyCode)raw->detail == esc && (count_xtest || !is_xtest(raw->sourceid))) {
          Window rr, cr;
          int rx, ry, wx, wy;
          unsigned int mods = 0;
          XQueryPointer(dpy, root, &rr, &cr, &rx, &ry, &wx, &wy, &mods);
          if (!(mods & (ShiftMask | ControlMask | Mod1Mask | Mod4Mask))) {
            fputs("E\n", stdout);
            if (fflush(stdout) != 0) return 0;
          }
        }
      }
      XFreeEventData(dpy, &e.xcookie);
    }
    if (poll(fds, 2, -1) < 0) continue;
    if (fds[0].revents) {
      char buf[256];
      if (read(0, buf, sizeof buf) <= 0) return 0;  // stdin's end: the server is done with us
    }
  }
}

int main(int argc, char **argv) {
  int esc = 0, xtest = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--esc")) esc = 1;
    else if (!strcmp(argv[i], "--xtest")) xtest = 1;
    else {
      fprintf(stderr, "usage: yoyo-x11windows [--esc [--xtest]]\n");
      return 2;
    }
  }
  XSetErrorHandler(on_x_error);
  XSetIOErrorHandler(on_io_error);
  dpy = XOpenDisplay(NULL);
  if (!dpy) {
    fprintf(stderr, "yoyo-x11windows: cannot open the display ($DISPLAY / $XAUTHORITY)\n");
    return 1;
  }
  root = DefaultRootWindow(dpy);
  return esc ? watch_escape(xtest) : list_windows();
}
