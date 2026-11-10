// yoyo-wininput: the input of yoyo-windows. Stands where `xdotool -` stands on Linux: it reads the very lines the
// server's input layer (linux/input.mjs) writes, one command per line, and plays them with SendInput — so the scroll
// pacing, the drag steps, the move gate and the typing backlog are the same code on both. Nothing typed is ever in an
// argv. The subset of xdotool's commands it knows:
//
//   mousemove <x> <y>                         the pointer to these pixels of the main display
//   click [--repeat <n>] [--delay <ms>] <b>   button b: 1 left, 2 middle, 3 right; 4 / 5 the wheel up / down,
//                                             6 / 7 left / right (one notch each)
//   mousedown <b> | mouseup <b>
//   keydown <key> | keyup <key>
//   key [--clearmodifiers] [--delay <ms>] <combo>…   each combo `ctrl+shift+a` pressed and released in turn
//   sleep <seconds>
//
// Keys are X keysym names (Return, BackSpace, Prior, F5, a, minus…, linux/input.mjs KEYS), the modifiers ctrl, alt,
// shift, super; `U<hex>` is a Unicode character, typed as itself (KEYEVENTF_UNICODE: any language, no keyboard layout
// or IME in between). The ⌘ of a Mac keyboard arrives as ctrl (input.mjs).
//
// Runs in the signed-in user's session; input to a window of an elevated program needs this process elevated too
// (Windows' UIPI), and the secure desktop (UAC, the lock screen) takes none. Exit 0 at stdin's end. stderr: log lines.
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"

static void send(INPUT *in, UINT n) {
  if (SendInput(n, in, sizeof *in) != n) {
    static int logged = 0;
    if (!logged++) fprintf(stderr, "yoyo-wininput: SendInput was blocked (error %lu; the secure desktop, or an elevated window)\n", GetLastError());
  }
}

static void move_to(int x, int y) {
  int w = GetSystemMetrics(SM_CXSCREEN), h = GetSystemMetrics(SM_CYSCREEN);
  if (w < 2 || h < 2) return;
  INPUT in = {0};
  in.type = INPUT_MOUSE;
  in.mi.dx = (LONG)(((long long)x * 65535 + (w - 1) / 2) / (w - 1));
  in.mi.dy = (LONG)(((long long)y * 65535 + (h - 1) / 2) / (h - 1));
  in.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
  send(&in, 1);
}

static void button(int b, int down) {
  INPUT in = {0};
  in.type = INPUT_MOUSE;
  switch (b) {
    case 1: in.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP; break;
    case 2: in.mi.dwFlags = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP; break;
    case 3: in.mi.dwFlags = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP; break;
    case 4: case 5:
      if (!down) return;
      in.mi.dwFlags = MOUSEEVENTF_WHEEL;
      in.mi.mouseData = (DWORD)(b == 4 ? WHEEL_DELTA : -WHEEL_DELTA);
      break;
    case 6: case 7:
      if (!down) return;
      in.mi.dwFlags = MOUSEEVENTF_HWHEEL;
      in.mi.mouseData = (DWORD)(b == 7 ? WHEEL_DELTA : -WHEEL_DELTA);
      break;
    default:
      fprintf(stderr, "yoyo-wininput: no button %d\n", b);
      return;
  }
  send(&in, 1);
}

// A keysym name → a virtual key (0: unknown); `ext`: an extended key (the arrows and the block above them, …).
static WORD vk_of(const char *k, int *ext) {
  static const struct { const char *name; WORD vk; int ext; } map[] = {
    {"Return", VK_RETURN, 0}, {"KP_Enter", VK_RETURN, 1}, {"Escape", VK_ESCAPE, 0}, {"Tab", VK_TAB, 0},
    {"space", VK_SPACE, 0}, {"BackSpace", VK_BACK, 0}, {"Delete", VK_DELETE, 1}, {"Insert", VK_INSERT, 1},
    {"Up", VK_UP, 1}, {"Down", VK_DOWN, 1}, {"Left", VK_LEFT, 1}, {"Right", VK_RIGHT, 1},
    {"Home", VK_HOME, 1}, {"End", VK_END, 1}, {"Prior", VK_PRIOR, 1}, {"Next", VK_NEXT, 1},
    {"minus", VK_OEM_MINUS, 0}, {"equal", VK_OEM_PLUS, 0}, {"bracketleft", VK_OEM_4, 0},
    {"bracketright", VK_OEM_6, 0}, {"semicolon", VK_OEM_1, 0}, {"apostrophe", VK_OEM_7, 0},
    {"comma", VK_OEM_COMMA, 0}, {"period", VK_OEM_PERIOD, 0}, {"slash", VK_OEM_2, 0},
    {"backslash", VK_OEM_5, 0}, {"grave", VK_OEM_3, 0},
    {"ctrl", VK_CONTROL, 0}, {"Control_L", VK_CONTROL, 0}, {"alt", VK_MENU, 0}, {"Alt_L", VK_MENU, 0},
    {"shift", VK_SHIFT, 0}, {"Shift_L", VK_SHIFT, 0}, {"super", VK_LWIN, 1}, {"Super_L", VK_LWIN, 1},
  };
  *ext = 0;
  for (size_t i = 0; i < sizeof map / sizeof *map; i++)
    if (!strcmp(map[i].name, k)) {
      *ext = map[i].ext;
      return map[i].vk;
    }
  if (k[0] && !k[1]) {
    if (k[0] >= 'a' && k[0] <= 'z') return (WORD)toupper(k[0]);
    if (k[0] >= 'A' && k[0] <= 'Z') return (WORD)k[0];
    if (k[0] >= '0' && k[0] <= '9') return (WORD)k[0];
  }
  if ((k[0] == 'F' || k[0] == 'f') && k[1]) {
    int n = atoi(k + 1);
    if (n >= 1 && n <= 24) return (WORD)(VK_F1 + n - 1);
  }
  return 0;
}

static void vkey(WORD vk, int ext, int down) {
  INPUT in = {0};
  in.type = INPUT_KEYBOARD;
  in.ki.wVk = vk;
  in.ki.wScan = (WORD)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
  in.ki.dwFlags = (ext ? KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : KEYEVENTF_KEYUP);
  send(&in, 1);
}

// One Unicode character typed as itself (a surrogate pair beyond the BMP).
static void unicode(unsigned cp) {
  WCHAR u[2];
  int n = 1;
  if (cp > 0xFFFF) {
    cp -= 0x10000;
    u[0] = (WCHAR)(0xD800 + (cp >> 10));
    u[1] = (WCHAR)(0xDC00 + (cp & 0x3FF));
    n = 2;
  } else {
    u[0] = (WCHAR)cp;
  }
  INPUT in[4] = {0};
  for (int i = 0; i < n; i++) {
    in[i].type = in[n + i].type = INPUT_KEYBOARD;
    in[i].ki.wScan = in[n + i].ki.wScan = u[i];
    in[i].ki.dwFlags = KEYEVENTF_UNICODE;
    in[n + i].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
  }
  send(in, (UINT)(2 * n));
}

// keydown / keyup of one key name; 0 when unknown.
static int key_edge(const char *k, int down) {
  int ext;
  WORD vk = vk_of(k, &ext);
  if (!vk) return 0;
  vkey(vk, ext, down);
  return 1;
}

// One combo (`ctrl+shift+a`, `U4F60`): its keys pressed in order, released in reverse.
static void combo(char *c) {
  if ((c[0] == 'U' || c[0] == 'u') && c[1] && !strchr(c, '+')) {
    char *end;
    unsigned long cp = strtoul(c + 1, &end, 16);
    if (!*end && cp > 0 && cp <= 0x10FFFF) {
      unicode((unsigned)cp);
      return;
    }
  }
  char *parts[8];
  int n = 0;
  for (char *t = strtok(c, "+"); t && n < 8; t = strtok(NULL, "+")) parts[n++] = t;
  int ok[8] = {0};
  for (int i = 0; i < n; i++) {
    ok[i] = key_edge(parts[i], 1);
    if (!ok[i]) fprintf(stderr, "yoyo-wininput: unknown key \"%s\"\n", parts[i]);
  }
  for (int i = n - 1; i >= 0; i--)
    if (ok[i]) key_edge(parts[i], 0);
}

// The modifiers the user holds on the real keyboard, released before a `key --clearmodifiers` (xdotool's flag).
static void clear_modifiers(void) {
  static const WORD mods[] = {VK_LCONTROL, VK_RCONTROL, VK_LMENU, VK_RMENU, VK_LSHIFT, VK_RSHIFT, VK_LWIN, VK_RWIN};
  for (size_t i = 0; i < sizeof mods / sizeof *mods; i++)
    if (GetAsyncKeyState(mods[i]) & 0x8000) vkey(mods[i], mods[i] == VK_RCONTROL || mods[i] == VK_RMENU || mods[i] == VK_LWIN || mods[i] == VK_RWIN, 0);
}

static void run(char *line) {
  char *argv[80];
  int argc = 0;
  for (char *t = strtok(line, " \t"); t && argc < 80; t = strtok(NULL, " \t")) argv[argc++] = t;
  if (!argc) return;
  const char *cmd = argv[0];
  if (!strcmp(cmd, "mousemove") && argc >= 3) {
    move_to(atoi(argv[1]), atoi(argv[2]));
  } else if (!strcmp(cmd, "click")) {
    int repeat = 1, delay = 12, i = 1;
    for (; i < argc - 1; i++) {
      if (!strcmp(argv[i], "--repeat")) repeat = atoi(argv[++i]);
      else if (!strcmp(argv[i], "--delay")) delay = atoi(argv[++i]);
      else break;
    }
    if (i >= argc) return;
    int b = atoi(argv[i]);
    if (repeat < 1) repeat = 1;
    if (repeat > 200) repeat = 200;
    for (int r = 0; r < repeat; r++) {
      if (r && delay > 0) Sleep((DWORD)delay);
      button(b, 1);
      button(b, 0);
    }
  } else if ((!strcmp(cmd, "mousedown") || !strcmp(cmd, "mouseup")) && argc >= 2) {
    button(atoi(argv[1]), cmd[5] == 'd');
  } else if ((!strcmp(cmd, "keydown") || !strcmp(cmd, "keyup")) && argc >= 2) {
    if (!key_edge(argv[1], cmd[3] == 'd')) fprintf(stderr, "yoyo-wininput: unknown key \"%s\"\n", argv[1]);
  } else if (!strcmp(cmd, "key")) {
    int delay = 12, i = 1, first = 1;
    for (; i < argc; i++) {
      if (!strcmp(argv[i], "--clearmodifiers")) clear_modifiers();
      else if (!strcmp(argv[i], "--delay") && i + 1 < argc) delay = atoi(argv[++i]);
      else break;
    }
    // strtok is not reentrant: copy each combo first
    for (; i < argc; i++) {
      char c[64];
      strncpy(c, argv[i], sizeof c - 1);
      c[sizeof c - 1] = 0;
      if (!first && delay > 0) Sleep((DWORD)delay);
      first = 0;
      combo(c);
    }
  } else if (!strcmp(cmd, "sleep") && argc >= 2) {
    double s = atof(argv[1]);
    if (s > 0 && s < 10) Sleep((DWORD)(s * 1000));
  } else {
    fprintf(stderr, "yoyo-wininput: unknown command \"%s\"\n", cmd);
  }
}

int main(void) {
  helper_init();
  char line[4096];
  while (in_line(line, sizeof line)) run(line);
  return 0;
}
