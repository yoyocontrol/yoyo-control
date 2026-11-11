// yoyo-winwindows: the windows of the desktop for yoyo-windows (linux/windows.mjs): `GET /windows`, `GET /hit` and
// `/frame?visible=`'s covering, and the Escape watch of `POST /automation`. The Windows twin of linux/x11windows.c:
// the same JSON, the same --esc lines.
//
//   yoyo-winwindows                 one shot: the top-level windows as one JSON object on stdout, then exit 0
//   yoyo-winwindows --esc [--xtest] long-running: a line per Escape pressed (see below) until stdin ends
//
// One shot. The top-level windows in Z order, bottom → top (EnumWindows gives top → bottom), only the visible ones
// that are not cloaked (another virtual desktop's, a suspended Store app's), not click-through and have an area.
// Click-through: WS_EX_TRANSPARENT (an overlay over everything that clicks pass through), or a window the system's
// own hit test finds nowhere although nothing is in front of it there (pointer_passes below: a layered overlay whose
// pixels are fully transparent — NVIDIA's lies over the whole screen without the style — or one cut away by a window
// region). Listed, such a window would be "the app at" every point under it and hide what is really clicked.
// An app is its program:
// `class` = the executable's name without ".exe" (chrome, Code, explorer), `instance` = the window class, `pid` = the
// owning process. Never a title. `type`: "desktop" for the shell's desktop (Progman / WorkerW), "dock" for the
// taskbars, "menu" / "tooltip" for those window classes, else "normal"; `or` (a popup that isn't the app's window:
// menus, tooltips, WS_EX_TOOLWINDOW pop-ups without a caption); `above` = topmost; `hidden` = minimized. The rectangle
// is the visible frame (DWM's extended frame bounds: without the invisible resize border) in pixels of the main
// display's coordinates (0,0 = its top-left); `screen` is the main display's size.
//   {"screen":[w,h], "active":<the foreground window, 0: none>,
//    "windows":[{"id","or","class","instance","pid","type","hidden","above","x","y","w","h"}, …]}
//
// --esc. A low-level keyboard hook (nothing grabbed: the key still reaches the app in front): "H\n" once listening,
// then "E\n" per Escape pressed without Shift / Ctrl / Alt / Win that was not injected (SendInput: the server's own
// /input and the phones' keys come that way; `--xtest` counts those too, for trying it without a keyboard). Exit 0 at
// stdin's end, 1 when the hook can't be set.
//
// stderr: log lines.
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <dwmapi.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"

typedef struct {
  HWND hwnd;
} item_t;

static item_t *items;
static size_t items_n, items_cap;

static BOOL CALLBACK collect(HWND h, LPARAM unused) {
  (void)unused;
  if (items_n == items_cap) {
    items_cap = items_cap ? items_cap * 2 : 256;
    items = realloc(items, items_cap * sizeof *items);
    if (!items) exit(1);
  }
  items[items_n++].hwnd = h;
  return TRUE;
}

// The executable's name without its folder and ".exe" (UTF-8, malloc'd), NULL when the process can't be opened.
static char *program_of(DWORD pid) {
  HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!p) return NULL;
  WCHAR path[MAX_PATH * 2];
  DWORD n = sizeof path / sizeof *path;
  char *out = NULL;
  if (QueryFullProcessImageNameW(p, 0, path, &n)) {
    WCHAR *base = wcsrchr(path, L'\\');
    base = base ? base + 1 : path;
    size_t len = wcslen(base);
    if (len > 4 && !_wcsicmp(base + len - 4, L".exe")) base[len - 4] = 0;
    out = utf8_of(base, -1);
  }
  CloseHandle(p);
  return out;
}

// Whether the pointer goes through `h` (items[k]; EnumWindows' order: a smaller index is in front). The system's own
// hit test (WindowFromPoint skips what a click skips: transparent pixels of a layered window, what a window region
// cuts away, click-through styles) at a grid of points inside the frame: a point answers this window (solid: not
// through, at once), a window behind it or none (through there) or a window in front of it (covered: says nothing).
// Through = some point was and none was solid. A disabled window (behind its modal dialog) is skipped by
// WindowFromPoint although clicks stop at it: never through.
static int pointer_passes(size_t k, HWND h, const RECT *r) {
  enum { N = 8 };
  if (!IsWindowEnabled(h)) return 0;
  int through = 0;
  LONG w = r->right - r->left, ht = r->bottom - r->top;
  for (int iy = 0; iy < N; iy++) {
    for (int ix = 0; ix < N; ix++) {
      POINT p = {r->left + (LONG)(((long long)(2 * ix + 1) * w) / (2 * N)), r->top + (LONG)(((long long)(2 * iy + 1) * ht) / (2 * N))};
      HWND at = WindowFromPoint(p);
      HWND root = at ? GetAncestor(at, GA_ROOT) : NULL;
      if (root == h) return 0;
      if (!root) {
        through++;
        continue;
      }
      size_t j = 0;
      while (j < items_n && items[j].hwnd != root) j++;
      if (j < items_n && j > k) through++;
    }
  }
  return through > 0;
}

static int one_shot(void) {
  EnumWindows(collect, 0);
  int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
  HWND fg = GetForegroundWindow();
  buf_t b = {0};
  buf_fmt(&b, "{\"screen\":[%d,%d],\"active\":%llu,\"windows\":[", sw, sh, (unsigned long long)(uintptr_t)fg);
  int first = 1;
  // cache of pid → program (a window list has many windows of few programs)
  struct { DWORD pid; char *name; } cache[256];
  int cached = 0;
  for (size_t k = items_n; k-- > 0;) {
    HWND h = items[k].hwnd;
    if (!IsWindowVisible(h)) continue;
    int cloaked = 0;
    if (SUCCEEDED(DwmGetWindowAttribute(h, DWMWA_CLOAKED, &cloaked, sizeof cloaked)) && cloaked) continue;
    RECT r;
    if (FAILED(DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, &r, sizeof r)) && !GetWindowRect(h, &r)) continue;
    if (r.right - r.left <= 0 || r.bottom - r.top <= 0) continue;
    LONG style = GetWindowLongW(h, GWL_STYLE), ex = GetWindowLongW(h, GWL_EXSTYLE);
    // click-through windows (a game overlay, a screen dimmer over everything) take no part of the screen
    if (ex & WS_EX_TRANSPARENT) continue;
    // …and so do the ones that let the pointer through without saying so in their style
    if (!IsIconic(h) && pointer_passes(k, h, &r)) continue;
    DWORD pid = 0;
    GetWindowThreadProcessId(h, &pid);
    WCHAR wcls[256] = {0};
    GetClassNameW(h, wcls, 256);
    char *cls = utf8_of(wcls, -1);
    const char *type = "normal";
    int popup = 0;
    if (!wcscmp(wcls, L"Progman") || !wcscmp(wcls, L"WorkerW")) type = "desktop";
    else if (!wcscmp(wcls, L"Shell_TrayWnd") || !wcscmp(wcls, L"Shell_SecondaryTrayWnd")) type = "dock";
    else if (!wcscmp(wcls, L"#32768")) type = "menu", popup = 1;
    else if (!wcscmp(wcls, L"tooltips_class32") || !wcscmp(wcls, L"Xaml_WindowedPopupClass")) type = "tooltip", popup = 1;
    else if ((ex & WS_EX_TOOLWINDOW) && (style & WS_POPUP) && !(style & WS_CAPTION)) popup = 1;
    char *prog = NULL;
    int c;
    for (c = 0; c < cached; c++)
      if (cache[c].pid == pid) break;
    if (c < cached) prog = cache[c].name;
    else {
      prog = program_of(pid);
      if (cached < 256) cache[cached].pid = pid, cache[cached].name = prog, cached++;
    }
    if (!first) buf_str(&b, ",");
    first = 0;
    buf_fmt(&b, "{\"id\":%llu,\"or\":%s,\"class\":", (unsigned long long)(uintptr_t)h, popup ? "true" : "false");
    if (prog) buf_json(&b, prog);
    else buf_str(&b, "null");
    buf_str(&b, ",\"instance\":");
    if (cls) buf_json(&b, cls);
    else buf_str(&b, "null");
    buf_fmt(&b, ",\"pid\":%lu,\"type\":\"%s\",\"hidden\":%s,\"above\":%s,\"x\":%ld,\"y\":%ld,\"w\":%ld,\"h\":%ld}", (unsigned long)pid, type,
            IsIconic(h) ? "true" : "false", (ex & WS_EX_TOPMOST) ? "true" : "false", r.left, r.top, r.right - r.left, r.bottom - r.top);
    free(cls);
  }
  buf_str(&b, "]}\n");
  write_all(b.p, b.n);
  return 0;
}

// ---- --esc

static int count_injected = 0;

static LRESULT CALLBACK on_key(int code, WPARAM wp, LPARAM lp) {
  if (code == HC_ACTION && (wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN)) {
    const KBDLLHOOKSTRUCT *k = (const KBDLLHOOKSTRUCT *)lp;
    int injected = (k->flags & LLKHF_INJECTED) != 0;
    int mods = (GetAsyncKeyState(VK_SHIFT) | GetAsyncKeyState(VK_CONTROL) | GetAsyncKeyState(VK_MENU) | GetAsyncKeyState(VK_LWIN) | GetAsyncKeyState(VK_RWIN)) & 0x8000;
    if (k->vkCode == VK_ESCAPE && !mods && (!injected || count_injected)) write_all("E\n", 2);
  }
  return CallNextHookEx(NULL, code, wp, lp);
}

static DWORD main_thread;

static DWORD WINAPI watch_stdin(LPVOID unused) {
  (void)unused;
  while (in_byte() >= 0) {
  }
  PostThreadMessageW(main_thread, WM_QUIT, 0, 0);
  return 0;
}

static int esc_watch(void) {
  main_thread = GetCurrentThreadId();
  HHOOK hook = SetWindowsHookExW(WH_KEYBOARD_LL, on_key, GetModuleHandleW(NULL), 0);
  if (!hook) {
    fprintf(stderr, "yoyo-winwindows: the keyboard hook can't be set (error %lu)\n", GetLastError());
    return 1;
  }
  CreateThread(NULL, 0, watch_stdin, NULL, 0, NULL);
  write_all("H\n", 2);
  MSG m;
  while (GetMessageW(&m, NULL, 0, 0) > 0) {
    TranslateMessage(&m);
    DispatchMessageW(&m);
  }
  UnhookWindowsHookEx(hook);
  return 0;
}

int main(int argc, char **argv) {
  helper_init();
  int esc = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--esc")) esc = 1;
    else if (!strcmp(argv[i], "--xtest")) count_injected = 1;
    else {
      fprintf(stderr, "usage: yoyo-winwindows [--esc [--xtest]]\n");
      return 2;
    }
  }
  return esc ? esc_watch() : one_shot();
}
