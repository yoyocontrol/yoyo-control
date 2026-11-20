// yoyo-broker: the secure-desktop broker of yoyo-windows (docs/BROKER.md). A LocalSystem service that starts the two
// helpers that need SYSTEM to see and drive the secure desktop — yoyo-winvideo (the picture) and yoyo-wininput (the
// pointer and keys) — inside the console user's session, and relays their stdin / stdout / stderr / exit over a named
// pipe to the user's yoyo-windows server. UAC's prompt, the sign-in screen and Ctrl+Alt+Del live on that desktop; a
// helper of the user can't see or touch it. On a Mac the Screen Recording and Accessibility grants play this part.
//
// Who may use it: a client in the active console session (not session 0), whose user is that session's user, and whose
// SID is in users.txt (written only by the elevated `install --user`: the grant). What it runs: only those two helpers,
// from its own folder under Program Files (admins only), of a version a signed manifest put there; their arguments are
// rebuilt from a fixed grammar, never passed through. No path, program or environment ever comes from a client — but
// `install <dir>`, whose files are read as the client, checked against the signed manifest and copied by their bytes.
//
//   yoyo-broker.exe install --user <SID>     elevated: this package's broker\ into Program Files, the SID allowed,
//                                            the service made (or updated) and started
//   yoyo-broker.exe uninstall [--user <SID>] elevated: the SID taken out; with none left (or no --user) the service and
//                                            its folder go
//   yoyo-broker.exe service                  what the service manager runs
//
// The pipe (\\.\pipe\yoyo-broker), one request per connection: a line of at most 512 bytes
//   yoyo-broker/1 <version> status | video <args…> | input | install <dir>
// then frames back: u8 kind, u32 BE length, bytes — 0 the answer (`ok …` or `err <reason>`), 1 the helper's stdout,
// 2 its stderr, 3 its exit (u32 BE code); after `ok`, the client's bytes are the helper's stdin. Closing the pipe ends
// the helper (a job object). Reasons: not-console, not-user, not-allowed, no-version, floor, busy, bad-request,
// signature, failed.
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <bcrypt.h>
#include <sddl.h>
#include <wincrypt.h>
#include <wtsapi32.h>
#include <ctype.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define BROKER_VERSION "1"
#define SERVICE_NAME L"YoyoBroker"
#define PIPE_NAME L"\\\\.\\pipe\\yoyo-broker"
#define MAX_VIDEO 8
#define MAX_INPUT 4
#define KEEP_VERSIONS 3
#define MAX_FILE (64u << 20)

static wchar_t base_dir[MAX_PATH];  // %ProgramFiles%\YoyoBroker
static SERVICE_STATUS_HANDLE status_handle;
static SERVICE_STATUS svc_status;
static CRITICAL_SECTION lock;

static void logf_(const char *fmt, ...) {
  // the service has no console: a small log beside it (rotated at 1 MB)
  wchar_t path[MAX_PATH];
  swprintf(path, MAX_PATH, L"%ls\\broker.log", base_dir);
  WIN32_FILE_ATTRIBUTE_DATA a;
  if (GetFileAttributesExW(path, GetFileExInfoStandard, &a) && a.nFileSizeLow > (1u << 20)) {
    wchar_t old[MAX_PATH];
    swprintf(old, MAX_PATH, L"%ls\\broker.log.1", base_dir);
    MoveFileExW(path, old, MOVEFILE_REPLACE_EXISTING);
  }
  FILE *f = _wfopen(path, L"a");
  if (!f) return;
  SYSTEMTIME t;
  GetSystemTime(&t);
  fprintf(f, "%04d-%02d-%02dT%02d:%02d:%02dZ ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
  va_list ap;
  va_start(ap, fmt);
  vfprintf(f, fmt, ap);
  va_end(ap);
  fputc('\n', f);
  fclose(f);
}

// ---- small things

static int set_base_dir(void) {
  wchar_t pf[MAX_PATH];
  DWORD n = GetEnvironmentVariableW(L"ProgramW6432", pf, MAX_PATH);
  if (!n || n >= MAX_PATH) n = GetEnvironmentVariableW(L"ProgramFiles", pf, MAX_PATH);
  if (!n || n >= MAX_PATH) wcscpy(pf, L"C:\\Program Files");
  swprintf(base_dir, MAX_PATH, L"%ls\\YoyoBroker", pf);
  return 1;
}

static int token_ok(const char *s, size_t max) {
  size_t n = strlen(s);
  if (!n || n > max) return 0;
  for (size_t i = 0; i < n; i++) {
    char c = s[i];
    if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-')) return 0;
  }
  return 1;
}

// "0.12.3" vs "0.12.10": numeric per part.
static int version_cmp(const char *a, const char *b) {
  while (*a || *b) {
    long x = strtol(a, (char **)&a, 10), y = strtol(b, (char **)&b, 10);
    if (x != y) return x < y ? -1 : 1;
    if (*a == '.') a++;
    if (*b == '.') b++;
    if (!isdigit((unsigned char)*a) && *a) a++;
    if (!isdigit((unsigned char)*b) && *b) b++;
  }
  return 0;
}

static char *read_small(const wchar_t *path, DWORD max, DWORD *len) {
  HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (f == INVALID_HANDLE_VALUE) return NULL;
  LARGE_INTEGER size;
  if (!GetFileSizeEx(f, &size) || size.QuadPart > max) {
    CloseHandle(f);
    return NULL;
  }
  char *b = malloc((size_t)size.QuadPart + 1);
  DWORD got = 0, total = 0;
  while (b && total < (DWORD)size.QuadPart && ReadFile(f, b + total, (DWORD)size.QuadPart - total, &got, NULL) && got) total += got;
  CloseHandle(f);
  if (!b || total != (DWORD)size.QuadPart) {
    free(b);
    return NULL;
  }
  b[total] = 0;
  if (len) *len = total;
  return b;
}

static int write_file(const wchar_t *path, const void *p, DWORD n) {
  HANDLE f = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (f == INVALID_HANDLE_VALUE) return 0;
  DWORD w = 0;
  BOOL ok = WriteFile(f, p, n, &w, NULL) && w == n;
  CloseHandle(f);
  return ok;
}

static wchar_t *wide(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  wchar_t *w = n > 0 ? malloc(n * sizeof *w) : NULL;
  if (w) MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
  return w;
}

// ---- signatures: ECDSA P-256 over SHA-256 (CNG), the key in trust.txt as base64 of X‖Y

static int sha256(const void *p, DWORD n, uint8_t out[32]) {
  return BCryptHash(BCRYPT_SHA256_ALG_HANDLE, NULL, 0, (PUCHAR)p, n, out, 32) == 0;
}

static void hex(const uint8_t *p, int n, char *out) {
  for (int i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", p[i]);
}

// trust.txt: "yoyo-broker-key 1\n<base64 X‖Y>\n" → 64 bytes
static int read_key(const wchar_t *path, uint8_t key[64]) {
  char *t = read_small(path, 4096, NULL);
  if (!t) return 0;
  int ok = 0;
  char *nl = strchr(t, '\n');
  if (!strncmp(t, "yoyo-broker-key 1", 17) && nl) {
    char *b64 = nl + 1;
    char *end = strchr(b64, '\n');
    if (end) *end = 0;
    DWORD n = 64;
    ok = CryptStringToBinaryA(b64, 0, CRYPT_STRING_BASE64, key, &n, NULL, NULL) && n == 64;
  }
  free(t);
  return ok;
}

static int verify(const uint8_t key[64], const void *msg, DWORD n, const uint8_t *sig, DWORD sig_n) {
  if (sig_n != 64) return 0;
  BCRYPT_ALG_HANDLE alg;
  if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_ECDSA_P256_ALGORITHM, NULL, 0)) return 0;
  uint8_t blob[sizeof(BCRYPT_ECCKEY_BLOB) + 64];
  BCRYPT_ECCKEY_BLOB *h = (BCRYPT_ECCKEY_BLOB *)blob;
  h->dwMagic = BCRYPT_ECDSA_PUBLIC_P256_MAGIC;
  h->cbKey = 32;
  memcpy(blob + sizeof *h, key, 64);
  BCRYPT_KEY_HANDLE k;
  int ok = 0;
  if (!BCryptImportKeyPair(alg, NULL, BCRYPT_ECCPUBLIC_BLOB, &k, blob, sizeof blob, 0)) {
    uint8_t digest[32];
    ok = sha256(msg, n, digest) && BCryptVerifySignature(k, NULL, digest, 32, (PUCHAR)sig, 64, 0) == 0;
    BCryptDestroyKey(k);
  }
  BCryptCloseAlgorithmProvider(alg, 0);
  return ok;
}

// ---- the manifest: "yoyo-broker-manifest 1\nversion <v>\nfloor <v>\n<sha256> <size> <name>\n…"

#define MAX_ENTRIES 3
static const char *ALLOWED[MAX_ENTRIES] = {"yoyo-broker.exe", "yoyo-winvideo.exe", "yoyo-wininput.exe"};

typedef struct {
  char version[17], floor[17];
  int n;
  struct {
    char name[32];
    char sha[65];
    DWORD size;
  } e[MAX_ENTRIES];
} manifest_t;

static int parse_manifest(char *t, manifest_t *m) {
  memset(m, 0, sizeof *m);
  char *save = NULL;
  char *line = strtok_s(t, "\n", &save);
  if (!line || strcmp(line, "yoyo-broker-manifest 1")) return 0;
  while ((line = strtok_s(NULL, "\n", &save))) {
    char a[80] = {0}, b[80] = {0}, c[80] = {0};
    int k = sscanf(line, "%79s %79s %79s", a, b, c);
    if (k == 2 && !strcmp(a, "version") && token_ok(b, 16)) strcpy(m->version, b);
    else if (k == 2 && !strcmp(a, "floor") && token_ok(b, 16)) strcpy(m->floor, b);
    else if (k == 3 && strlen(a) == 64 && m->n < MAX_ENTRIES) {
      int known = 0;
      for (int i = 0; i < MAX_ENTRIES; i++) known |= !strcmp(c, ALLOWED[i]);
      for (int i = 0; i < m->n; i++)
        if (!strcmp(m->e[i].name, c)) known = 0;
      if (!known) return 0;
      strcpy(m->e[m->n].name, c);
      strcpy(m->e[m->n].sha, a);
      m->e[m->n].size = (DWORD)strtoul(b, NULL, 10);
      m->n++;
    } else
      return 0;
  }
  return m->version[0] && m->floor[0] && m->n == MAX_ENTRIES;
}

static void read_floor(char floor[17]) {
  wchar_t p[MAX_PATH];
  swprintf(p, MAX_PATH, L"%ls\\floor.txt", base_dir);
  char *t = read_small(p, 64, NULL);
  floor[0] = 0;
  if (t) {
    char *nl = strpbrk(t, "\r\n");
    if (nl) *nl = 0;
    if (token_ok(t, 16)) strcpy(floor, t);
    free(t);
  }
}

static void write_floor(const char *v) {
  char cur[17];
  read_floor(cur);
  if (cur[0] && version_cmp(v, cur) <= 0) return;
  wchar_t p[MAX_PATH];
  swprintf(p, MAX_PATH, L"%ls\\floor.txt", base_dir);
  write_file(p, v, (DWORD)strlen(v));
}

// Only the newest KEEP_VERSIONS stay (an older one in use stays until it isn't).
static void prune_versions(void) {
  wchar_t pat[MAX_PATH];
  swprintf(pat, MAX_PATH, L"%ls\\versions\\*", base_dir);
  char names[64][17];
  int n = 0;
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(pat, &fd);
  if (h == INVALID_HANDLE_VALUE) return;
  do {
    if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || fd.cFileName[0] == '.' || n >= 64) continue;
    char v[64];
    WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, v, sizeof v, NULL, NULL);
    if (token_ok(v, 16)) strcpy(names[n++], v);
  } while (FindNextFileW(h, &fd));
  FindClose(h);
  for (int i = 0; i < n; i++) {
    int newer = 0;
    for (int j = 0; j < n; j++) newer += version_cmp(names[j], names[i]) > 0;
    if (newer < KEEP_VERSIONS) continue;
    for (int k = 0; k < MAX_ENTRIES; k++) {
      wchar_t f[MAX_PATH];
      swprintf(f, MAX_PATH, L"%ls\\versions\\%hs\\%hs", base_dir, names[i], ALLOWED[k]);
      DeleteFileW(f);
    }
    wchar_t d[MAX_PATH];
    swprintf(d, MAX_PATH, L"%ls\\versions\\%hs", base_dir, names[i]);
    RemoveDirectoryW(d);
  }
}

static int version_installed(const char *v) {
  wchar_t p[MAX_PATH];
  for (int k = 1; k < MAX_ENTRIES; k++) {
    swprintf(p, MAX_PATH, L"%ls\\versions\\%hs\\%hs", base_dir, v, ALLOWED[k]);
    if (GetFileAttributesW(p) == INVALID_FILE_ATTRIBUTES) return 0;
  }
  return 1;
}

// Install the package in `dir` (its manifest.txt, manifest.sig and the three exes) as versions\<v>. `as_client`:
// reading happens while impersonating the pipe's client (the files are what the client may read). Each file is read
// whole, its size and hash checked on the bytes in memory, and those bytes written: what is checked is what is kept.
// `*restart`: a newer broker was put in place (the service exits so the manager starts it again). Returns NULL or a
// reason.
static const char *install_from(const wchar_t *dir, HANDLE as_client, int *restart, char version_out[17]) {
  *restart = 0;
  wchar_t trust[MAX_PATH], p[MAX_PATH];
  swprintf(trust, MAX_PATH, L"%ls\\trust.txt", base_dir);
  uint8_t key[64];
  if (!read_key(trust, key)) return "failed";
  if (as_client && !ImpersonateNamedPipeClient(as_client)) return "failed";
  DWORD mlen = 0, slen = 0;
  swprintf(p, MAX_PATH, L"%ls\\manifest.txt", dir);
  char *mtext = read_small(p, 65536, &mlen);
  swprintf(p, MAX_PATH, L"%ls\\manifest.sig", dir);
  char *sig = read_small(p, 256, &slen);
  uint8_t *data[MAX_ENTRIES] = {0};
  DWORD sizes[MAX_ENTRIES] = {0};
  manifest_t m;
  const char *why = NULL;
  if (!mtext || !sig) why = "failed";
  else if (!verify(key, mtext, mlen, (uint8_t *)sig, slen)) why = "signature";
  else {
    char *copy = _strdup(mtext);
    if (!parse_manifest(copy, &m)) why = "signature";
    free(copy);
  }
  if (!why) {
    char floor[17];
    read_floor(floor);
    if (floor[0] && version_cmp(m.version, floor) < 0) why = "floor";
  }
  for (int i = 0; !why && i < m.n; i++) {
    swprintf(p, MAX_PATH, L"%ls\\%hs", dir, m.e[i].name);
    data[i] = (uint8_t *)read_small(p, MAX_FILE, &sizes[i]);
    uint8_t d[32];
    char h[65];
    if (!data[i] || sizes[i] != m.e[i].size || !sha256(data[i], sizes[i], d)) why = "signature";
    else {
      hex(d, 32, h);
      if (_stricmp(h, m.e[i].sha)) why = "signature";
    }
  }
  if (as_client) RevertToSelf();
  if (!why) {
    // a staging folder of our own, then renamed into place
    wchar_t versions[MAX_PATH], stage[MAX_PATH], final_[MAX_PATH];
    swprintf(versions, MAX_PATH, L"%ls\\versions", base_dir);
    CreateDirectoryW(versions, NULL);
    swprintf(final_, MAX_PATH, L"%ls\\%hs", versions, m.version);
    if (!version_installed(m.version)) {
      swprintf(stage, MAX_PATH, L"%ls\\staging-%08lx%08lx", versions, GetTickCount(), GetCurrentThreadId());
      if (!CreateDirectoryW(stage, NULL)) why = "failed";
      for (int i = 0; !why && i < m.n; i++) {
        if (!strcmp(m.e[i].name, "yoyo-broker.exe")) continue;
        swprintf(p, MAX_PATH, L"%ls\\%hs", stage, m.e[i].name);
        if (!write_file(p, data[i], sizes[i])) why = "failed";
      }
      if (!why && !MoveFileExW(stage, final_, 0) && !version_installed(m.version)) why = "failed";
    }
    if (!why) {
      write_floor(m.floor);
      strcpy(version_out, m.version);
      prune_versions();
      // the broker itself: newer than the one running → in place, and a restart
      for (int i = 0; i < m.n; i++) {
        if (strcmp(m.e[i].name, "yoyo-broker.exe")) continue;
        wchar_t self[MAX_PATH], aside[MAX_PATH], staged[MAX_PATH];
        swprintf(self, MAX_PATH, L"%ls\\yoyo-broker.exe", base_dir);
        DWORD cur_n = 0;
        char *cur = read_small(self, MAX_FILE, &cur_n);
        int same = cur && cur_n == sizes[i] && !memcmp(cur, data[i], cur_n);
        if (same) {
          free(cur);
          break;
        }
        swprintf(staged, MAX_PATH, L"%ls\\yoyo-broker.exe.new", base_dir);
        swprintf(aside, MAX_PATH, L"%ls\\yoyo-broker.exe.old", base_dir);
        DeleteFileW(aside);
        if (!write_file(staged, data[i], sizes[i])) why = "failed";
        else if (!cur) MoveFileExW(staged, self, 0);  // a first install: nothing running to replace
        else if (MoveFileExW(self, aside, MOVEFILE_REPLACE_EXISTING) && MoveFileExW(staged, self, 0)) *restart = 1;
        free(cur);
      }
    }
  }
  for (int i = 0; i < MAX_ENTRIES; i++) free(data[i]);
  free(mtext);
  free(sig);
  return why;
}

// ---- who is asking

static int sid_allowed(const char *sid) {
  wchar_t p[MAX_PATH];
  swprintf(p, MAX_PATH, L"%ls\\users.txt", base_dir);
  char *t = read_small(p, 65536, NULL);
  if (!t) return 0;
  int ok = 0;
  char *save = NULL;
  for (char *l = strtok_s(t, "\r\n", &save); l && !ok; l = strtok_s(NULL, "\r\n", &save)) ok = !strcmp(l, sid);
  free(t);
  return ok;
}

static int token_user_sid(HANDLE tok, char *out, size_t cap) {
  uint8_t buf[256];
  DWORD n = 0;
  if (!GetTokenInformation(tok, TokenUser, buf, sizeof buf, &n)) return 0;
  char *s = NULL;
  if (!ConvertSidToStringSidA(((TOKEN_USER *)buf)->User.Sid, &s)) return 0;
  int ok = strlen(s) < cap;
  if (ok) strcpy(out, s);
  LocalFree(s);
  return ok;
}

// The client's user and session (impersonating it: never by its process id). NULL or a reason.
static const char *check_client(HANDLE pipe, DWORD *session_out) {
  if (!ImpersonateNamedPipeClient(pipe)) return "not-allowed";
  HANDLE tok = NULL;
  BOOL got = OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &tok);
  RevertToSelf();
  if (!got) return "not-allowed";
  char sid[128] = {0}, console_sid[128] = {0};
  DWORD session = 0, n = 0;
  int ok = token_user_sid(tok, sid, sizeof sid) && GetTokenInformation(tok, TokenSessionId, &session, sizeof session, &n);
  CloseHandle(tok);
  if (!ok) return "not-allowed";
  DWORD console = WTSGetActiveConsoleSessionId();
  if (session == 0 || session != console) return "not-console";
  HANDLE ut = NULL;
  if (!WTSQueryUserToken(console, &ut)) return "not-console";
  ok = token_user_sid(ut, console_sid, sizeof console_sid);
  CloseHandle(ut);
  if (!ok || strcmp(sid, console_sid)) return "not-user";
  if (!sid_allowed(sid)) return "not-allowed";
  *session_out = session;
  return NULL;
}

// ---- the pipe, overlapped (a synchronous pipe serialises one thread's read against another's write)

typedef struct {
  HANDLE pipe;
  CRITICAL_SECTION wlock;
  HANDLE job;
  DWORD session;
  int role;  // 1 video, 2 input
  volatile LONG gone;
} conn_t;

static int pipe_io(HANDLE h, void *p, DWORD n, int write, DWORD *done) {
  OVERLAPPED o = {0};
  o.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
  BOOL ok = write ? WriteFile(h, p, n, NULL, &o) : ReadFile(h, p, n, NULL, &o);
  if (!ok && GetLastError() != ERROR_IO_PENDING) {
    CloseHandle(o.hEvent);
    return 0;
  }
  ok = GetOverlappedResult(h, &o, done, TRUE);
  CloseHandle(o.hEvent);
  return ok;
}

static int send_frame(conn_t *c, uint8_t kind, const void *p, DWORD n) {
  uint8_t head[5] = {kind, (uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n};
  EnterCriticalSection(&c->wlock);
  DWORD w = 0;
  int ok = pipe_io(c->pipe, head, 5, 1, &w) && w == 5;
  const uint8_t *b = p;
  while (ok && n) {
    ok = pipe_io(c->pipe, (void *)b, n, 1, &w) && w > 0;
    b += w;
    n -= w;
  }
  LeaveCriticalSection(&c->wlock);
  return ok;
}

static void answer(conn_t *c, const char *s) { send_frame(c, 0, s, (DWORD)strlen(s)); }

// The request line: up to 512 bytes and a \n.
static int read_line(HANDLE h, char *line, size_t cap) {
  size_t n = 0;
  while (n + 1 < cap) {
    char ch;
    DWORD got = 0;
    if (!pipe_io(h, &ch, 1, 0, &got) || !got) return 0;
    if (ch == '\n') break;
    line[n++] = ch;
  }
  line[n] = 0;
  return n + 1 < cap;
}

// ---- the helpers: their command lines from a fixed grammar

static const char *PRESETS[] = {"ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"};

static int int_in(const char *s, long lo, long hi, long *out) {
  if (!s || !*s || strlen(s) > 6) return 0;
  for (const char *p = s; *p; p++)
    if (*p < '0' || *p > '9') return 0;
  long v = strtol(s, NULL, 10);
  if (v < lo || v > hi) return 0;
  *out = v;
  return 1;
}

// `video` arguments → the helper's (appended to `cmd`); 0 on anything outside the grammar.
static int video_args(char **a, int n, wchar_t *cmd, size_t cap) {
  int boxes = 0;
  wchar_t part[96];
  for (int i = 0; i < n; i++) {
    long v[4];
    if (!strcmp(a[i], "--fps") && i + 1 < n && int_in(a[i + 1], 1, 240, v)) swprintf(part, 96, L" --fps %ld", v[0]), i++;
    else if (!strcmp(a[i], "--cursor") && i + 1 < n && !strcmp(a[i + 1], "client")) wcscpy(part, L" --cursor client"), i++;
    else if (!strcmp(a[i], "--encoder") && i + 1 < n && (!strcmp(a[i + 1], "gpu") || !strcmp(a[i + 1], "x264"))) swprintf(part, 96, L" --encoder %hs", a[i + 1]), i++;
    else if (!strcmp(a[i], "--threads") && i + 1 < n && int_in(a[i + 1], 1, 64, v)) swprintf(part, 96, L" --threads %ld", v[0]), i++;
    else if (!strcmp(a[i], "--jpeg") && i + 1 < n && int_in(a[i + 1], 10, 95, v)) swprintf(part, 96, L" --jpeg %ld", v[0]), i++;
    else if (!strcmp(a[i], "--preset") && i + 1 < n) {
      int ok = 0;
      for (size_t k = 0; k < sizeof PRESETS / sizeof *PRESETS; k++) ok |= !strcmp(a[i + 1], PRESETS[k]);
      if (!ok) return 0;
      swprintf(part, 96, L" --preset %hs", a[i + 1]), i++;
    } else if (!strcmp(a[i], "--size") && i + 2 < n && int_in(a[i + 1], 1, 65535, v) && int_in(a[i + 2], 1, 65535, v + 1))
      swprintf(part, 96, L" --size %ld %ld", v[0], v[1]), i += 2;
    else if ((!strcmp(a[i], "--crop") || !strcmp(a[i], "--box")) && i + 4 < n && int_in(a[i + 1], 0, 65535, v) && int_in(a[i + 2], 0, 65535, v + 1) &&
             int_in(a[i + 3], 0, 65535, v + 2) && int_in(a[i + 4], 0, 65535, v + 3)) {
      if (a[i][2] == 'b' && ++boxes > 64) return 0;
      swprintf(part, 96, L" %hs %ld %ld %ld %ld", a[i], v[0], v[1], v[2], v[3]), i += 4;
    } else
      return 0;
    if (wcslen(cmd) + wcslen(part) + 1 >= cap) return 0;
    wcscat(cmd, part);
  }
  return 1;
}

static LONG counts[64][3];  // per session % 64: [role]

typedef struct {
  conn_t *c;
  HANDLE from;
  uint8_t kind;
} pump_t;

static DWORD WINAPI pump_out(LPVOID p) {
  pump_t *t = p;
  uint8_t buf[65536];
  DWORD got = 0;
  while (ReadFile(t->from, buf, sizeof buf, &got, NULL) && got)
    if (!send_frame(t->c, t->kind, buf, got)) break;
  return 0;
}

typedef struct {
  conn_t *c;
  HANDLE to;
} feed_t;

static DWORD WINAPI pump_in(LPVOID p) {
  feed_t *t = p;
  uint8_t buf[16384];
  DWORD got = 0, w = 0;
  while (pipe_io(t->c->pipe, buf, sizeof buf, 0, &got) && got)
    if (!WriteFile(t->to, buf, got, &w, NULL)) break;
  // the client went away (or the helper stopped reading): the helper ends with the job
  InterlockedExchange(&t->c->gone, 1);
  CloseHandle(t->to);
  if (t->c->job) TerminateJobObject(t->c->job, 0);
  return 0;
}

// SYSTEM, in the client's session, without the privileges the helpers have no use for.
static HANDLE helper_token(DWORD session) {
  HANDLE self = NULL, dup = NULL, restricted = NULL;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, &self)) return NULL;
  if (DuplicateTokenEx(self, MAXIMUM_ALLOWED, NULL, SecurityIdentification, TokenPrimary, &dup) &&
      SetTokenInformation(dup, TokenSessionId, &session, sizeof session))
    CreateRestrictedToken(dup, DISABLE_MAX_PRIVILEGE, 0, NULL, 0, NULL, 0, NULL, &restricted);
  if (dup) CloseHandle(dup);
  CloseHandle(self);
  return restricted;
}

static void run_helper(conn_t *c, const char *version, const char *exe, const wchar_t *args) {
  wchar_t dir[MAX_PATH], cmd[4096];
  swprintf(dir, MAX_PATH, L"%ls\\versions\\%hs", base_dir, version);
  swprintf(cmd, 4096, L"\"%ls\\%hs\"%ls", dir, exe, args);
  SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, TRUE};
  HANDLE in_r, in_w, out_r, out_w, err_r, err_w;
  if (!CreatePipe(&in_r, &in_w, &sa, 0) || !CreatePipe(&out_r, &out_w, &sa, 0) || !CreatePipe(&err_r, &err_w, &sa, 0)) return answer(c, "err failed");
  SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(err_r, HANDLE_FLAG_INHERIT, 0);
  HANDLE tok = helper_token(c->session);
  // only the three pipe ends are inherited
  SIZE_T asize = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &asize);
  LPPROC_THREAD_ATTRIBUTE_LIST attrs = malloc(asize);
  HANDLE inherit[3] = {in_r, out_w, err_w};
  InitializeProcThreadAttributeList(attrs, 1, 0, &asize);
  UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherit, sizeof inherit, NULL, NULL);
  STARTUPINFOEXW si = {0};
  si.StartupInfo.cb = sizeof si;
  si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  si.StartupInfo.hStdInput = in_r;
  si.StartupInfo.hStdOutput = out_w;
  si.StartupInfo.hStdError = err_w;
  si.StartupInfo.lpDesktop = L"winsta0\\Default";
  si.lpAttributeList = attrs;
  PROCESS_INFORMATION pi = {0};
  c->job = CreateJobObjectW(NULL, NULL);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION li = {0};
  li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  SetInformationJobObject(c->job, JobObjectExtendedLimitInformation, &li, sizeof li);
  BOOL made = tok && CreateProcessAsUserW(tok, NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT, NULL, dir, &si.StartupInfo, &pi);
  DWORD err = GetLastError();
  DeleteProcThreadAttributeList(attrs);
  free(attrs);
  if (tok) CloseHandle(tok);
  CloseHandle(in_r);
  CloseHandle(out_w);
  CloseHandle(err_w);
  if (!made) {
    logf_("start %s failed: %lu", exe, err);
    CloseHandle(in_w), CloseHandle(out_r), CloseHandle(err_r);
    return answer(c, "err failed");
  }
  AssignProcessToJobObject(c->job, pi.hProcess);
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  answer(c, "ok");
  pump_t po = {c, out_r, 1}, pe = {c, err_r, 2};
  feed_t fi = {c, in_w};
  HANDLE t[3] = {CreateThread(NULL, 0, pump_out, &po, 0, NULL), CreateThread(NULL, 0, pump_out, &pe, 0, NULL), CreateThread(NULL, 0, pump_in, &fi, 0, NULL)};
  WaitForSingleObject(pi.hProcess, INFINITE);
  WaitForMultipleObjects(2, t, TRUE, 5000);  // its last output first
  DWORD code = 0;
  GetExitCodeProcess(pi.hProcess, &code);
  uint8_t ec[4] = {(uint8_t)(code >> 24), (uint8_t)(code >> 16), (uint8_t)(code >> 8), (uint8_t)code};
  if (!c->gone) send_frame(c, 3, ec, 4);
  CloseHandle(pi.hProcess);
  // pump_in ends when the client closes (CancelIoEx below wakes it if it doesn't)
  CancelIoEx(c->pipe, NULL);
  WaitForSingleObject(t[2], 2000);
  for (int i = 0; i < 3; i++) CloseHandle(t[i]);
  CloseHandle(out_r);
  CloseHandle(err_r);
}

// ---- one connection

typedef struct conn_node {
  conn_t *c;
  struct conn_node *next;
} conn_node;
static conn_node *conns;

static DWORD WINAPI serve(LPVOID p) {
  conn_t *c = p;
  char line[520];
  char *a[160];
  int n = 0;
  DWORD session = 0;
  const char *why = NULL;
  if (!read_line(c->pipe, line, sizeof line)) why = "bad-request";
  if (!why) why = check_client(c->pipe, &session);
  if (!why) {
    char *save = NULL;
    for (char *t = strtok_s(line, " ", &save); t && n < 160; t = strtok_s(NULL, " ", &save)) a[n++] = t;
    if (n < 3 || strcmp(a[0], "yoyo-broker/1") || !token_ok(a[1], 16)) why = "bad-request";
  }
  c->session = session;
  if (why) {
    char s[64];
    snprintf(s, sizeof s, "err %s", why);
    answer(c, s);
  } else if (!strcmp(a[2], "status")) {
    char floor[17], s[200];
    read_floor(floor);
    snprintf(s, sizeof s, "ok broker %s floor %s installed %s", BROKER_VERSION, floor[0] ? floor : "-", version_installed(a[1]) ? "yes" : "no");
    answer(c, s);
  } else if (!strcmp(a[2], "install") && n >= 4) {
    // the rest of the line is the folder (it may hold spaces)
    char *dir = a[3];
    for (int i = 4; i < n; i++) a[i][-1] = ' ';
    wchar_t *wdir = wide(dir);
    int restart = 0;
    char v[17] = {0};
    const char *r = wdir ? install_from(wdir, c->pipe, &restart, v) : "bad-request";
    free(wdir);
    char s[80];
    snprintf(s, sizeof s, r ? "err %s" : restart ? "ok %s restart" : "ok %s", r ? r : v);
    logf_("install from a client: %s", s);
    answer(c, s);
    if (restart) {
      FlushFileBuffers(c->pipe);
      Sleep(200);
      logf_("restarting into the new broker");
      ExitProcess(1);  // the service manager's recovery starts it again
    }
  } else if (!version_installed(a[1])) {
    char floor[17];
    read_floor(floor);
    answer(c, floor[0] && version_cmp(a[1], floor) < 0 ? "err floor" : "err no-version");
  } else if (!strcmp(a[2], "video") || (!strcmp(a[2], "input") && n == 3)) {
    int role = a[2][0] == 'v' ? 1 : 2;
    char floor[17];
    read_floor(floor);
    wchar_t args[3000] = {0};
    if (floor[0] && version_cmp(a[1], floor) < 0) answer(c, "err floor");
    else if (role == 1 && !video_args(a + 3, n - 3, args, 3000)) answer(c, "err bad-request");
    else {
      LONG *count = &counts[session % 64][role];
      if (InterlockedIncrement(count) > (role == 1 ? MAX_VIDEO : MAX_INPUT)) answer(c, "err busy");
      else {
        c->role = role;
        run_helper(c, a[1], role == 1 ? "yoyo-winvideo.exe" : "yoyo-wininput.exe", role == 1 ? args : L" -");
      }
      InterlockedDecrement(count);
    }
  } else {
    answer(c, "err bad-request");
  }
  EnterCriticalSection(&lock);
  for (conn_node **pp = &conns; *pp; pp = &(*pp)->next)
    if ((*pp)->c == c) {
      conn_node *dead = *pp;
      *pp = dead->next;
      free(dead);
      break;
    }
  LeaveCriticalSection(&lock);
  FlushFileBuffers(c->pipe);
  DisconnectNamedPipe(c->pipe);
  CloseHandle(c->pipe);
  if (c->job) CloseHandle(c->job);  // kills what is left
  DeleteCriticalSection(&c->wlock);
  free(c);
  return 0;
}

// The console went to another session (fast user switching, a disconnect): helpers of other sessions end.
static void console_changed(void) {
  DWORD console = WTSGetActiveConsoleSessionId();
  EnterCriticalSection(&lock);
  for (conn_node *n = conns; n; n = n->next)
    if (n->c->session && n->c->session != console && n->c->job) {
      logf_("session %lu left the console: its helpers end", n->c->session);
      TerminateJobObject(n->c->job, 0);
    }
  LeaveCriticalSection(&lock);
}

static void serve_pipe(void) {
  // the console's interactive users may connect (read / write); nobody over the network; SYSTEM all
  SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, FALSE};
  ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:(D;;GA;;;NU)(A;;GA;;;SY)(A;;GRGW;;;IU)", SDDL_REVISION_1, &sa.lpSecurityDescriptor, NULL);
  int first = 1;
  for (;;) {
    HANDLE h = CreateNamedPipeW(PIPE_NAME, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | (first ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0),
                                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, &sa);
    if (h == INVALID_HANDLE_VALUE) {
      logf_("CreateNamedPipe failed: %lu", GetLastError());
      if (first) ExitProcess(2);  // someone else holds the name
      Sleep(1000);
      continue;
    }
    first = 0;
    OVERLAPPED o = {0};
    o.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    BOOL ok = ConnectNamedPipe(h, &o);
    DWORD e = GetLastError();
    DWORD dummy;
    if (!ok && e == ERROR_IO_PENDING) ok = GetOverlappedResult(h, &o, &dummy, TRUE);
    else if (!ok && e == ERROR_PIPE_CONNECTED) ok = TRUE;
    CloseHandle(o.hEvent);
    if (!ok) {
      CloseHandle(h);
      continue;
    }
    conn_t *c = calloc(1, sizeof *c);
    c->pipe = h;
    InitializeCriticalSection(&c->wlock);
    conn_node *node = malloc(sizeof *node);
    node->c = c;
    EnterCriticalSection(&lock);
    node->next = conns;
    conns = node;
    LeaveCriticalSection(&lock);
    HANDLE t = CreateThread(NULL, 0, serve, c, 0, NULL);
    if (t) CloseHandle(t);
  }
}

// ---- the service

static void set_state(DWORD s) {
  svc_status.dwCurrentState = s;
  SetServiceStatus(status_handle, &svc_status);
}

static DWORD WINAPI handler(DWORD control, DWORD type, LPVOID data, LPVOID ctx) {
  (void)data, (void)ctx;
  if (control == SERVICE_CONTROL_STOP || control == SERVICE_CONTROL_SHUTDOWN) {
    set_state(SERVICE_STOP_PENDING);
    set_state(SERVICE_STOPPED);
    ExitProcess(0);
  }
  if (control == SERVICE_CONTROL_SESSIONCHANGE && (type == WTS_CONSOLE_CONNECT || type == WTS_CONSOLE_DISCONNECT || type == WTS_SESSION_LOGOFF)) console_changed();
  return NO_ERROR;
}

static void WINAPI service_main(DWORD argc, LPWSTR *argv) {
  (void)argc, (void)argv;
  status_handle = RegisterServiceCtrlHandlerExW(SERVICE_NAME, handler, NULL);
  svc_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  svc_status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN | SERVICE_ACCEPT_SESSIONCHANGE;
  set_state(SERVICE_RUNNING);
  logf_("started (broker %s)", BROKER_VERSION);
  serve_pipe();
}

// ---- install / uninstall (elevated, from the package's broker\ folder)

static int sid_valid(const char *s) {
  PSID sid = NULL;
  if (!ConvertStringSidToSidA(s, &sid)) return 0;
  LocalFree(sid);
  return 1;
}

static void users_edit(const char *add, const char *remove, int *left) {
  wchar_t p[MAX_PATH];
  swprintf(p, MAX_PATH, L"%ls\\users.txt", base_dir);
  char *t = read_small(p, 65536, NULL);
  char out[65536] = {0};
  int n = 0, has = 0;
  if (t) {
    char *save = NULL;
    for (char *l = strtok_s(t, "\r\n", &save); l; l = strtok_s(NULL, "\r\n", &save)) {
      if (remove && !strcmp(l, remove)) continue;
      if (add && !strcmp(l, add)) has = 1;
      if (strlen(out) + strlen(l) + 2 < sizeof out) strcat(out, l), strcat(out, "\n"), n++;
    }
    free(t);
  }
  if (add && !has) strcat(out, add), strcat(out, "\n"), n++;
  write_file(p, out, (DWORD)strlen(out));
  if (left) *left = n;
}

static int stop_service(SC_HANDLE s) {
  SERVICE_STATUS st;
  ControlService(s, SERVICE_CONTROL_STOP, &st);
  for (int i = 0; i < 50; i++) {
    if (QueryServiceStatus(s, &st) && st.dwCurrentState == SERVICE_STOPPED) return 1;
    Sleep(100);
  }
  return 0;
}

static int cli_install(const char *sid) {
  if (!sid_valid(sid)) return fprintf(stderr, "yoyo-broker: %s is not a SID\n", sid), 2;
  wchar_t here[MAX_PATH], pkg[MAX_PATH], p[MAX_PATH], q[MAX_PATH];
  GetModuleFileNameW(NULL, here, MAX_PATH);
  wcscpy(pkg, here);
  *wcsrchr(pkg, L'\\') = 0;
  // the package's own key and manifest must agree before anything is copied
  swprintf(p, MAX_PATH, L"%ls\\trust.txt", pkg);
  uint8_t key[64];
  if (!read_key(p, key)) return fprintf(stderr, "yoyo-broker: no trust.txt beside it\n"), 1;
  CreateDirectoryW(base_dir, NULL);
  swprintf(q, MAX_PATH, L"%ls\\trust.txt", base_dir);
  uint8_t old[64];
  if (read_key(q, old) && memcmp(old, key, 64)) fprintf(stderr, "yoyo-broker: a new signing key replaces the installed one (an elevated install may)\n");
  if (!CopyFileW(p, q, FALSE)) return fprintf(stderr, "yoyo-broker: cannot write %ls (%lu)\n", q, GetLastError()), 1;
  SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_ALL_ACCESS);
  if (!scm) return fprintf(stderr, "yoyo-broker: not elevated (%lu)\n", GetLastError()), 1;
  SC_HANDLE s = OpenServiceW(scm, SERVICE_NAME, SERVICE_ALL_ACCESS);
  if (s) stop_service(s);
  int restart = 0;
  char v[17] = {0};
  const char *why = install_from(pkg, NULL, &restart, v);
  if (why) return fprintf(stderr, "yoyo-broker: the package does not check out (%s)\n", why), 1;
  // the broker itself (install_from puts a newer one in place; a first install has none yet)
  swprintf(q, MAX_PATH, L"%ls\\yoyo-broker.exe", base_dir);
  if (GetFileAttributesW(q) == INVALID_FILE_ATTRIBUTES && !CopyFileW(here, q, FALSE)) return fprintf(stderr, "yoyo-broker: cannot copy itself (%lu)\n", GetLastError()), 1;
  users_edit(sid, NULL, NULL);
  wchar_t bin[MAX_PATH + 16];
  swprintf(bin, MAX_PATH + 16, L"\"%ls\" service", q);
  if (!s) s = CreateServiceW(scm, SERVICE_NAME, L"Yoyo Control secure desktop", SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL, bin, NULL, NULL, NULL, NULL, NULL);
  else ChangeServiceConfigW(s, SERVICE_NO_CHANGE, SERVICE_AUTO_START, SERVICE_NO_CHANGE, bin, NULL, NULL, NULL, NULL, NULL, NULL);
  if (!s) return fprintf(stderr, "yoyo-broker: cannot make the service (%lu)\n", GetLastError()), 1;
  SERVICE_DESCRIPTIONW d = {L"Lets the signed-in user's Yoyo Control see and use the secure desktop (UAC prompts, the sign-in screen)."};
  ChangeServiceConfig2W(s, SERVICE_CONFIG_DESCRIPTION, &d);
  SC_ACTION acts[3] = {{SC_ACTION_RESTART, 2000}, {SC_ACTION_RESTART, 2000}, {SC_ACTION_RESTART, 10000}};
  SERVICE_FAILURE_ACTIONSW fa = {86400, NULL, NULL, 3, acts};
  ChangeServiceConfig2W(s, SERVICE_CONFIG_FAILURE_ACTIONS, &fa);
  SERVICE_FAILURE_ACTIONS_FLAG ff = {TRUE};
  ChangeServiceConfig2W(s, SERVICE_CONFIG_FAILURE_ACTIONS_FLAG, &ff);
  if (!StartServiceW(s, 0, NULL) && GetLastError() != ERROR_SERVICE_ALREADY_RUNNING) return fprintf(stderr, "yoyo-broker: cannot start the service (%lu)\n", GetLastError()), 1;
  CloseServiceHandle(s);
  CloseServiceHandle(scm);
  printf("yoyo-broker: installed %s for %s in %ls\n", v, sid, base_dir);
  return 0;
}

static void remove_tree(const wchar_t *dir) {
  wchar_t pat[MAX_PATH], p[MAX_PATH];
  swprintf(pat, MAX_PATH, L"%ls\\*", dir);
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(pat, &fd);
  if (h != INVALID_HANDLE_VALUE) {
    do {
      if (!wcscmp(fd.cFileName, L".") || !wcscmp(fd.cFileName, L"..")) continue;
      swprintf(p, MAX_PATH, L"%ls\\%ls", dir, fd.cFileName);
      if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) RemoveDirectoryW(p), DeleteFileW(p);
      else if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) remove_tree(p);
      else DeleteFileW(p);
    } while (FindNextFileW(h, &fd));
    FindClose(h);
  }
  RemoveDirectoryW(dir);
}

static int cli_uninstall(const char *sid) {
  int left = 0;
  if (sid) users_edit(NULL, sid, &left);
  if (sid && left) return printf("yoyo-broker: %s removed; %d user(s) left\n", sid, left), 0;
  SC_HANDLE scm = OpenSCManagerW(NULL, NULL, SC_MANAGER_ALL_ACCESS);
  if (!scm) return fprintf(stderr, "yoyo-broker: not elevated (%lu)\n", GetLastError()), 1;
  SC_HANDLE s = OpenServiceW(scm, SERVICE_NAME, SERVICE_ALL_ACCESS);
  if (s) {
    stop_service(s);
    DeleteService(s);
    CloseServiceHandle(s);
  }
  CloseServiceHandle(scm);
  remove_tree(base_dir);
  printf("yoyo-broker: removed\n");
  return 0;
}

int main(int argc, char **argv) {
  set_base_dir();
  InitializeCriticalSection(&lock);
  if (argc >= 2 && !strcmp(argv[1], "service")) {
    SERVICE_TABLE_ENTRYW table[] = {{SERVICE_NAME, service_main}, {NULL, NULL}};
    return StartServiceCtrlDispatcherW(table) ? 0 : 1;
  }
  if (argc >= 4 && !strcmp(argv[1], "install") && !strcmp(argv[2], "--user")) return cli_install(argv[3]);
  if (argc >= 2 && !strcmp(argv[1], "uninstall")) return cli_uninstall(argc >= 4 && !strcmp(argv[2], "--user") ? argv[3] : NULL);
  fprintf(stderr, "usage: yoyo-broker install --user <SID> | uninstall [--user <SID>] | service\n");
  return 2;
}
