// yoyo-control.exe: Yoyo Control on Windows for the signed-in user — what the menu bar app is on a Mac. It runs the
// service (node server.mjs, hidden, its helpers with it in one job: they all end with this process) and keeps it
// running (started again after 1 s, then up to 30 s apart while it keeps failing; a minute of running resets that),
// and shows an icon in the notification area: Pair iPhone… (the pairing code as a page in the browser), Open Log,
// Quit. The log is <home>\yoyo-control.log (8 MB, then one older file).
//
//   yoyo-control.exe [--no-tray] [<server arguments>…]   the service; without arguments: --remote <home>
//   yoyo-control.exe --pair [--remote <home>]            the pairing page now (the service must be running), then exit
//
// <home> is the value of --remote, else %LOCALAPPDATA%\YoyoControl. node.exe is the one beside this program (the
// release ships one), else the one in PATH; server.mjs is beside this program. One service per user session
// (a second start exits at once).
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

#define WM_TRAY (WM_APP + 1)
#define WM_STATE (WM_APP + 2)
#define ID_PAIR 101
#define ID_LOG 102
#define ID_QUIT 103
#define LOG_MAX (8u << 20)

static WCHAR dir[MAX_PATH], node[MAX_PATH], server[MAX_PATH], home[MAX_PATH], logpath[MAX_PATH];
static WCHAR *server_args;  // what follows `server.mjs` on the service's command line
static HANDLE job;
static HWND win;
static NOTIFYICONDATAW nid;
static UINT taskbar_created;
static volatile LONG quitting = 0;
static int state_running = 0;

static int exists(const WCHAR *p) { return GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES; }

// The log, appended to (inheritable: the service writes its stdout and stderr there).
static HANDLE open_log(void) {
  WIN32_FILE_ATTRIBUTE_DATA a;
  if (GetFileAttributesExW(logpath, GetFileExInfoStandard, &a) && a.nFileSizeLow > LOG_MAX) {
    WCHAR old[MAX_PATH + 4];
    swprintf(old, MAX_PATH + 4, L"%ls.1", logpath);
    MoveFileExW(logpath, old, MOVEFILE_REPLACE_EXISTING);
  }
  SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
  HANDLE h = CreateFileW(logpath, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, &sa, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  return h;
}

static void log_line(const char *s) {
  HANDLE h = open_log();
  if (h == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME t;
  GetSystemTime(&t);
  char line[600];
  int n = snprintf(line, sizeof line, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ yoyo-control: %s\r\n", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, s);
  DWORD w;
  WriteFile(h, line, (DWORD)n, &w, NULL);
  CloseHandle(h);
}

// node "server.mjs" <args>, hidden, in the job, its output into the log; the process handle (NULL on failure).
static HANDLE start_node(const WCHAR *args, int in_job) {
  size_t n = wcslen(node) + wcslen(server) + wcslen(args) + 16;
  WCHAR *cmd = malloc(n * sizeof *cmd);
  if (!cmd) return NULL;
  swprintf(cmd, n, L"\"%ls\" \"%ls\" %ls", node, server, args);
  HANDLE logh = open_log();
  STARTUPINFOW si = {0};
  si.cb = sizeof si;
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = NULL;
  si.hStdOutput = logh;
  si.hStdError = logh;
  PROCESS_INFORMATION pi;
  BOOL ok = CreateProcessW(exists(node) ? node : NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED, NULL, dir, &si, &pi);
  free(cmd);
  if (logh != INVALID_HANDLE_VALUE) CloseHandle(logh);
  if (!ok) return NULL;
  if (in_job) AssignProcessToJobObject(job, pi.hProcess);
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  return pi.hProcess;
}

static void set_state(int running) {
  state_running = running;
  if (win) PostMessageW(win, WM_STATE, 0, 0);
}

// The service, kept running.
static DWORD WINAPI supervise(LPVOID unused) {
  (void)unused;
  DWORD backoff = 1000;
  while (!quitting) {
    ULONGLONG started = GetTickCount64();
    HANDLE p = start_node(server_args, 1);
    if (!p) {
      char m[128];
      snprintf(m, sizeof m, "can't start node.exe (error %lu): is Node.js installed?", GetLastError());
      log_line(m);
    } else {
      set_state(1);
      WaitForSingleObject(p, INFINITE);
      DWORD code = 0;
      GetExitCodeProcess(p, &code);
      CloseHandle(p);
      if (quitting) break;
      char m[128];
      snprintf(m, sizeof m, "the service exited (code %lu); starting it again in %lu s", code, backoff / 1000);
      log_line(m);
    }
    set_state(0);
    if (GetTickCount64() - started > 60000) backoff = 1000;
    Sleep(backoff);
    backoff = backoff * 2 > 30000 ? 30000 : backoff * 2;
  }
  return 0;
}

// Pair iPhone…: the pair command (it opens the page), its failure told in a box.
static DWORD WINAPI pair(LPVOID unused) {
  (void)unused;
  WCHAR args[MAX_PATH + 64];
  swprintf(args, MAX_PATH + 64, L"pair --page --remote \"%ls\"", home);
  HANDLE p = start_node(args, 0);
  DWORD code = 1;
  if (p) {
    WaitForSingleObject(p, 30000);
    GetExitCodeProcess(p, &code);
    CloseHandle(p);
  }
  if (code != 0)
    MessageBoxW(NULL, L"No pairing code could be made: the service may still be starting. Try again in a moment, or see the log.", L"Yoyo Control", MB_OK | MB_ICONWARNING);
  return 0;
}

static void tray_add(void) {
  nid.cbSize = sizeof nid;
  nid.hWnd = win;
  nid.uID = 1;
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = WM_TRAY;
  nid.hIcon = LoadIconW(GetModuleHandleW(NULL), MAKEINTRESOURCEW(1));
  if (!nid.hIcon) nid.hIcon = LoadIconW(NULL, (LPCWSTR)IDI_APPLICATION);
  wcscpy(nid.szTip, L"Yoyo Control");
  Shell_NotifyIconW(NIM_ADD, &nid);
}

static void tray_tip(void) {
  wcscpy(nid.szTip, state_running ? L"Yoyo Control" : L"Yoyo Control — starting…");
  nid.uFlags = NIF_TIP;
  Shell_NotifyIconW(NIM_MODIFY, &nid);
}

static void menu(void) {
  HMENU m = CreatePopupMenu();
  AppendMenuW(m, MF_STRING | MF_DISABLED, 0, state_running ? L"Yoyo Control is on" : L"Yoyo Control is starting…");
  AppendMenuW(m, MF_SEPARATOR, 0, NULL);
  AppendMenuW(m, MF_STRING, ID_PAIR, L"Pair iPhone…");
  AppendMenuW(m, MF_STRING, ID_LOG, L"Open Log");
  AppendMenuW(m, MF_SEPARATOR, 0, NULL);
  AppendMenuW(m, MF_STRING, ID_QUIT, L"Quit Yoyo Control");
  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(win);
  int cmd = TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, win, NULL);
  DestroyMenu(m);
  if (cmd == ID_PAIR) CloseHandle(CreateThread(NULL, 0, pair, NULL, 0, NULL));
  else if (cmd == ID_LOG) ShellExecuteW(NULL, L"open", L"notepad.exe", logpath, NULL, SW_SHOWNORMAL);
  else if (cmd == ID_QUIT) DestroyWindow(win);
}

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
  if (m == taskbar_created && taskbar_created) {
    tray_add();  // Explorer started again: the icon is gone with it
    return 0;
  }
  switch (m) {
    case WM_TRAY:
      if (LOWORD(lp) == WM_RBUTTONUP || LOWORD(lp) == WM_LBUTTONUP || LOWORD(lp) == WM_CONTEXTMENU) menu();
      return 0;
    case WM_STATE:
      tray_tip();
      return 0;
    case WM_DESTROY:
      Shell_NotifyIconW(NIM_DELETE, &nid);
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(h, m, wp, lp);
}

// The value after `--remote` in a command line (quoted or not), into `out`; 0 when there is none.
static int remote_of(int argc, WCHAR **argv, WCHAR *out) {
  for (int i = 0; i + 1 < argc; i++)
    if (!wcscmp(argv[i], L"--remote")) {
      wcsncpy(out, argv[i + 1], MAX_PATH - 1);
      out[MAX_PATH - 1] = 0;
      return 1;
    }
  return 0;
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmdline, int show) {
  (void)prev;
  (void)cmdline;
  (void)show;
  int argc;
  WCHAR **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  GetModuleFileNameW(NULL, dir, MAX_PATH);
  *wcsrchr(dir, L'\\') = 0;
  swprintf(node, MAX_PATH, L"%ls\\node.exe", dir);
  if (!exists(node)) wcscpy(node, L"node.exe");
  swprintf(server, MAX_PATH, L"%ls\\server.mjs", dir);
  if (!remote_of(argc, argv, home)) {
    WCHAR *local = NULL;
    SHGetKnownFolderPath(&FOLDERID_LocalAppData, 0, NULL, &local);
    swprintf(home, MAX_PATH, L"%ls\\YoyoControl", local ? local : L".");
    CoTaskMemFree(local);
  }
  CreateDirectoryW(home, NULL);
  swprintf(logpath, MAX_PATH, L"%ls\\yoyo-control.log", home);

  int tray = 1, pair_only = 0, first = 1;
  for (; first < argc; first++) {
    if (!wcscmp(argv[first], L"--no-tray")) tray = 0;
    else if (!wcscmp(argv[first], L"--pair")) pair_only = 1;
    else break;
  }
  if (pair_only) {
    pair(NULL);
    return 0;
  }
  // the service's arguments: the ones given, else remote access in <home>
  size_t len = 64 + wcslen(home);
  for (int i = first; i < argc; i++) len += wcslen(argv[i]) + 3;
  server_args = calloc(len, sizeof *server_args);
  if (first < argc) {
    for (int i = first; i < argc; i++) {
      wcscat(server_args, i > first ? L" \"" : L"\"");
      wcscat(server_args, argv[i]);
      wcscat(server_args, L"\"");
    }
  } else {
    swprintf(server_args, len, L"--remote \"%ls\"", home);
  }

  CreateMutexW(NULL, TRUE, L"Local\\YoyoControlService");
  if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;
  job = CreateJobObjectW(NULL, NULL);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = {0};
  li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  SetInformationJobObject(job, JobObjectExtendedLimitInformation, &li, sizeof li);
  log_line("starting");

  if (tray) {
    taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = wndproc;
    wc.hInstance = inst;
    wc.lpszClassName = L"YoyoControlTray";
    RegisterClassW(&wc);
    win = CreateWindowExW(0, wc.lpszClassName, L"Yoyo Control", 0, 0, 0, 0, 0, NULL, NULL, inst, NULL);
    tray_add();
  }
  HANDLE sup = CreateThread(NULL, 0, supervise, NULL, 0, NULL);
  if (tray) {
    MSG m;
    while (GetMessageW(&m, NULL, 0, 0) > 0) {
      TranslateMessage(&m);
      DispatchMessageW(&m);
    }
    InterlockedExchange(&quitting, 1);
    log_line("quit");
    TerminateJobObject(job, 0);
  } else {
    WaitForSingleObject(sup, INFINITE);
  }
  return 0;
}
