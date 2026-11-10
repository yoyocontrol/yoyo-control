// yoyo-winclip: the clipboard of the desktop for yoyo-windows (linux/clipboard.mjs). The Windows twin of
// linux/x11clip.c — the same commands and records. Event-driven: a clipboard format listener says when the clipboard
// changed (debounced 60 ms: an app's copy is several SetClipboardData calls); this program then reads what the
// summary needs — files (CF_HDROP, as file: URIs), a PNG (the "PNG" format, else the bitmap encoded with WIC), text
// (CF_UNICODETEXT) — and reports it once. A clipboard a password manager marked
// (ExcludeClipboardContentFromMonitorProcessing, the convention Windows' own clipboard history honours) is reported by
// its formats only, never its content.
//
// No arguments.
//
// stdin, commands (a header line, then exactly the byte counts it names):
//   T <n>\n<n bytes>                         the clipboard becomes this UTF-8 text
//   F <uris> <gnome> <text> <img> <mime>\n<…> the clipboard becomes these files (CF_HDROP from the newline-separated
//                                            paths of <text>; <uris> and <gnome> are read and ignored), and with
//                                            <img> > 0 that one image too ("PNG" and CF_DIB)
//   I\n                                      the current item's PNG → an 'I' record (empty: none)
//   Q\n                                      quit (stdin's end too)
// stdout, records: one type byte, a 4-byte big-endian payload length, the payload:
//   'H' hello, once (empty)
//   'K' the clipboard changed: JSON {"own":bool, "owner":bool, "targets":[…], "uris"?, "text"?, "textSize"?,
//       "textCut"?, "png"?: {"size","width","height"}} — `own`: this program's own write; `owner` false: the
//       clipboard is empty. The first one describes the clipboard at start. Targets are MIME-like names for the
//       standard formats (text/plain;charset=utf-8, text/uri-list, image/png, image/bmp), else the format's name.
//   'W' a write's result: "ok" or why not
//   'I' the PNG asked for: u32 BE how many 'K' records this process had sent when it answered, then the PNG
// stderr: log lines. Exit 0 on Q / end of stdin, 1 when the listener can't be set up.
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wincodec.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"

#define TEXT_CAP (4u << 20)
#define PNG_CAP (64u << 20)
#define WM_COMMAND_IN (WM_APP + 1)
#define DEBOUNCE_TIMER 1

static HWND win;
static UINT CF_PNG, CF_EXCLUDE, CF_DROPEFFECT;
static DWORD own_seq = 0;          // the sequence number our last write left
static DWORD reported_seq = (DWORD)-1;
static uint32_t k_sent = 0;
static uint8_t *png = NULL;        // the current item's PNG
static size_t png_n = 0;
static IWICImagingFactory *wic;

typedef struct {
  char kind;                       // T, F, I, Q
  uint8_t *text;
  size_t text_n;
  uint8_t *img;
  size_t img_n;
  char mime[64];
} command_t;

static int open_clipboard(void) {
  for (int i = 0; i < 20; i++) {
    if (OpenClipboard(win)) return 1;
    Sleep(15);  // another program has it open
  }
  return 0;
}

// ---- PNG

static IStream *mem_stream(void) {
  IStream *s = NULL;
  CreateStreamOnHGlobal(NULL, TRUE, &s);
  return s;
}

// A WIC bitmap source → PNG bytes (malloc'd) and its size.
static uint8_t *png_of_source(IWICBitmapSource *src, size_t *n, UINT *w, UINT *h) {
  uint8_t *out = NULL;
  IStream *st = mem_stream();
  IWICBitmapEncoder *enc = NULL;
  IWICBitmapFrameEncode *fr = NULL;
  if (!st || FAILED(IWICImagingFactory_CreateEncoder(wic, &GUID_ContainerFormatPng, NULL, &enc))) goto done;
  if (FAILED(IWICBitmapEncoder_Initialize(enc, st, WICBitmapEncoderNoCache))) goto done;
  if (FAILED(IWICBitmapEncoder_CreateNewFrame(enc, &fr, NULL)) || FAILED(IWICBitmapFrameEncode_Initialize(fr, NULL))) goto done;
  IWICBitmapSource_GetSize(src, w, h);
  IWICBitmapFrameEncode_SetSize(fr, *w, *h);
  WICPixelFormatGUID fmt;
  IWICBitmapSource_GetPixelFormat(src, &fmt);
  IWICBitmapFrameEncode_SetPixelFormat(fr, &fmt);
  if (FAILED(IWICBitmapFrameEncode_WriteSource(fr, src, NULL)) || FAILED(IWICBitmapFrameEncode_Commit(fr)) || FAILED(IWICBitmapEncoder_Commit(enc))) goto done;
  STATSTG ss;
  HGLOBAL hg;
  if (FAILED(IStream_Stat(st, &ss, STATFLAG_NONAME)) || FAILED(GetHGlobalFromStream(st, &hg))) goto done;
  *n = (size_t)ss.cbSize.QuadPart;
  if (*n == 0 || *n > PNG_CAP) goto done;
  out = malloc(*n);
  if (out) memcpy(out, GlobalLock(hg), *n), GlobalUnlock(hg);
done:
  if (fr) IWICBitmapFrameEncode_Release(fr);
  if (enc) IWICBitmapEncoder_Release(enc);
  if (st) IStream_Release(st);
  return out;
}

// A PNG's width and height from its IHDR.
static int png_size(const uint8_t *p, size_t n, UINT *w, UINT *h) {
  if (n < 24 || memcmp(p, "\x89PNG\r\n\x1a\n", 8) || memcmp(p + 12, "IHDR", 4)) return 0;
  *w = (UINT)p[16] << 24 | (UINT)p[17] << 16 | (UINT)p[18] << 8 | p[19];
  *h = (UINT)p[20] << 24 | (UINT)p[21] << 16 | (UINT)p[22] << 8 | p[23];
  return 1;
}

// ---- reading

// A path as a file: URI (UTF-8, percent-encoded but for unreserved characters, '/' and the drive's ':').
static void uri_of(buf_t *b, const wchar_t *path) {
  char *u = utf8_of(path, -1);
  if (!u) return;
  buf_str(b, path[0] == L'\\' && path[1] == L'\\' ? "file:" : "file:///");
  for (const unsigned char *c = (const unsigned char *)u; *c; c++) {
    unsigned char ch = *c == '\\' ? '/' : *c;
    if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || strchr("-._~/:", ch)) {
      char s[2] = {(char)ch, 0};
      buf_str(b, s);
    } else {
      buf_fmt(b, "%%%02X", ch);
    }
  }
  buf_str(b, "\r\n");
  free(u);
}

static const char *format_name(UINT f, char *tmp, size_t cap) {
  switch (f) {
    case CF_UNICODETEXT: return "text/plain;charset=utf-8";
    case CF_TEXT: return "TEXT";
    case CF_OEMTEXT: return "OEMTEXT";
    case CF_HDROP: return "text/uri-list";
    case CF_DIB: case CF_DIBV5: case CF_BITMAP: return "image/bmp";
    case CF_LOCALE: return "LOCALE";
    default: break;
  }
  if (f == CF_PNG) return "image/png";
  WCHAR w[128];
  if (GetClipboardFormatNameW(f, w, 128) > 0) {
    char *u = utf8_of(w, -1);
    if (u) {
      strncpy(tmp, u, cap - 1);
      tmp[cap - 1] = 0;
      free(u);
      return tmp;
    }
  }
  snprintf(tmp, cap, "CF_%u", f);
  return tmp;
}

// What the clipboard holds now → a 'K' record (own: our own write).
static void report(int own) {
  DWORD seq = GetClipboardSequenceNumber();
  if (!own && (seq == reported_seq || seq == own_seq)) return;
  buf_t j = {0};
  free(png);
  png = NULL;
  png_n = 0;
  if (!open_clipboard()) {
    fprintf(stderr, "yoyo-winclip: the clipboard is held open by another program; reported as other\n");
    buf_str(&j, "{\"own\":false,\"owner\":true,\"targets\":[\"busy\"]}");
    goto send;
  }
  int count = CountClipboardFormats();
  buf_fmt(&j, "{\"own\":%s,\"owner\":%s,\"targets\":[", own ? "true" : "false", count > 0 ? "true" : "false");
  int concealed = 0, has_png = 0, has_bmp = 0, has_drop = 0, has_text = 0, first = 1;
  for (UINT f = 0; (f = EnumClipboardFormats(f));) {
    char tmp[160];
    if (!first) buf_str(&j, ",");
    first = 0;
    buf_json(&j, format_name(f, tmp, sizeof tmp));
    if (f == CF_EXCLUDE) concealed = 1;
    if (f == CF_PNG) has_png = 1;
    if (f == CF_BITMAP || f == CF_DIB || f == CF_DIBV5) has_bmp = 1;
    if (f == CF_HDROP) has_drop = 1;
    if (f == CF_UNICODETEXT) has_text = 1;
  }
  buf_str(&j, "]");
  if (!own && !concealed && count > 0) {
    HANDLE h;
    if (has_drop && (h = GetClipboardData(CF_HDROP))) {
      HDROP d = (HDROP)h;
      UINT n = DragQueryFileW(d, 0xFFFFFFFF, NULL, 0);
      buf_t u = {0};
      for (UINT i = 0; i < n; i++) {
        UINT len = DragQueryFileW(d, i, NULL, 0);
        wchar_t *p = malloc(((size_t)len + 1) * sizeof *p);
        if (!p) continue;
        DragQueryFileW(d, i, p, len + 1);
        uri_of(&u, p);
        free(p);
      }
      if (u.n) {
        buf_str(&j, ",\"uris\":");
        buf_json(&j, u.p);
      }
      free(u.p);
    }
    if (has_png && (h = GetClipboardData(CF_PNG))) {
      size_t n = GlobalSize(h);
      const uint8_t *p = GlobalLock(h);
      UINT w, hh;
      if (p && n <= PNG_CAP && png_size(p, n, &w, &hh) && (png = malloc(n))) {
        memcpy(png, p, n);
        png_n = n;
      }
      if (p) GlobalUnlock(h);
    }
    if (!png && has_bmp && (h = GetClipboardData(CF_BITMAP))) {
      IWICBitmap *bm = NULL;
      HPALETTE pal = IsClipboardFormatAvailable(CF_PALETTE) ? GetClipboardData(CF_PALETTE) : NULL;
      if (SUCCEEDED(IWICImagingFactory_CreateBitmapFromHBITMAP(wic, (HBITMAP)h, pal, WICBitmapIgnoreAlpha, &bm))) {
        UINT w, hh;
        png = png_of_source((IWICBitmapSource *)bm, &png_n, &w, &hh);
        IWICBitmap_Release(bm);
      }
    }
    if (png) {
      UINT w = 0, hh = 0;
      png_size(png, png_n, &w, &hh);
      buf_fmt(&j, ",\"png\":{\"size\":%zu,\"width\":%u,\"height\":%u}", png_n, w, hh);
    }
    if (has_text && (h = GetClipboardData(CF_UNICODETEXT))) {
      const wchar_t *w = GlobalLock(h);
      if (w) {
        size_t units = wcsnlen(w, GlobalSize(h) / sizeof(wchar_t));
        char *t = utf8_of(w, (int)units);
        if (t || units == 0) {
          size_t total = t ? strlen(t) : 0, keep = total;
          if (keep > TEXT_CAP) {
            keep = TEXT_CAP;
            while (keep > 0 && ((unsigned char)t[keep] & 0xC0) == 0x80) keep--;
            t[keep] = 0;
          }
          buf_str(&j, ",\"text\":");
          buf_json(&j, t ? t : "");
          buf_fmt(&j, ",\"textSize\":%zu,\"textCut\":%s", total, total > keep ? "true" : "false");
          free(t);
        }
        GlobalUnlock(h);
      }
    }
  }
  CloseClipboard();
  buf_str(&j, "}");
send:
  reported_seq = seq;
  k_sent++;
  record('K', j.p, j.n, NULL, 0);
  free(j.p);
}

// ---- writing

static HGLOBAL global_of(const void *p, size_t n) {
  HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE, n ? n : 1);
  if (!g) return NULL;
  void *d = GlobalLock(g);
  if (n) memcpy(d, p, n);
  GlobalUnlock(g);
  return g;
}

// An image's bytes → a CF_DIB (32-bit BGRA, bottom-up), NULL when WIC can't read it.
static HGLOBAL dib_of(const uint8_t *img, size_t n) {
  HGLOBAL out = NULL;
  IWICStream *st = NULL;
  IWICBitmapDecoder *dec = NULL;
  IWICBitmapFrameDecode *fr = NULL;
  IWICFormatConverter *conv = NULL;
  if (FAILED(IWICImagingFactory_CreateStream(wic, &st)) || FAILED(IWICStream_InitializeFromMemory(st, (BYTE *)img, (DWORD)n))) goto done;
  if (FAILED(IWICImagingFactory_CreateDecoderFromStream(wic, (IStream *)st, NULL, WICDecodeMetadataCacheOnDemand, &dec))) goto done;
  if (FAILED(IWICBitmapDecoder_GetFrame(dec, 0, &fr))) goto done;
  if (FAILED(IWICImagingFactory_CreateFormatConverter(wic, &conv))) goto done;
  if (FAILED(IWICFormatConverter_Initialize(conv, (IWICBitmapSource *)fr, &GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, NULL, 0, WICBitmapPaletteTypeCustom))) goto done;
  UINT w, h;
  IWICFormatConverter_GetSize(conv, &w, &h);
  if (!w || !h || (size_t)w * h > (64u << 20) / 4) goto done;
  size_t stride = (size_t)w * 4, size = sizeof(BITMAPINFOHEADER) + stride * h;
  out = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!out) goto done;
  uint8_t *d = GlobalLock(out);
  BITMAPINFOHEADER *bi = (BITMAPINFOHEADER *)d;
  memset(bi, 0, sizeof *bi);
  bi->biSize = sizeof *bi;
  bi->biWidth = (LONG)w;
  bi->biHeight = (LONG)h;  // bottom-up
  bi->biPlanes = 1;
  bi->biBitCount = 32;
  bi->biCompression = BI_RGB;
  bi->biSizeImage = (DWORD)(stride * h);
  uint8_t *pix = d + sizeof *bi;
  uint8_t *rows = malloc(stride * h);
  if (rows && SUCCEEDED(IWICFormatConverter_CopyPixels(conv, NULL, (UINT)stride, (UINT)(stride * h), rows))) {
    for (UINT y = 0; y < h; y++) memcpy(pix + (size_t)(h - 1 - y) * stride, rows + (size_t)y * stride, stride);
  }
  free(rows);
  GlobalUnlock(out);
done:
  if (conv) IWICFormatConverter_Release(conv);
  if (fr) IWICBitmapFrameDecode_Release(fr);
  if (dec) IWICBitmapDecoder_Release(dec);
  if (st) IWICStream_Release(st);
  return out;
}

static const char *write_text(const uint8_t *t, size_t n) {
  int units;
  wchar_t *w = utf16_of((const char *)t, (int)n, &units);
  if (!w) return "the text is not UTF-8";
  // a Windows program pastes \r\n line ends
  size_t lf = 0;
  for (int i = 0; i < units; i++) lf += w[i] == L'\n' && (i == 0 || w[i - 1] != L'\r');
  wchar_t *crlf = malloc(((size_t)units + lf + 1) * sizeof *crlf);
  if (!crlf) return free(w), "out of memory";
  size_t k = 0;
  for (int i = 0; i < units; i++) {
    if (w[i] == L'\n' && (i == 0 || w[i - 1] != L'\r')) crlf[k++] = L'\r';
    crlf[k++] = w[i];
  }
  crlf[k++] = 0;
  free(w);
  HGLOBAL g = global_of(crlf, k * sizeof *crlf);
  free(crlf);
  if (!g) return "out of memory";
  if (!open_clipboard()) return GlobalFree(g), "another program holds the clipboard";
  EmptyClipboard();
  if (!SetClipboardData(CF_UNICODETEXT, g)) {
    GlobalFree(g);
    CloseClipboard();
    return "the clipboard refused the text";
  }
  CloseClipboard();
  return NULL;
}

static const char *write_files(const uint8_t *text, size_t n, const uint8_t *img, size_t img_n, const char *mime) {
  int units;
  wchar_t *w = utf16_of((const char *)text, (int)n, &units);
  if (!w) return "the paths are not UTF-8";
  // DROPFILES, then each path (\n-separated in, NUL-separated out), then one more NUL
  size_t size = sizeof(DROPFILES) + ((size_t)units + 2) * sizeof(wchar_t);
  HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size);
  if (!g) return free(w), "out of memory";
  DROPFILES *df = GlobalLock(g);
  df->pFiles = sizeof(DROPFILES);
  df->fWide = TRUE;
  wchar_t *list = (wchar_t *)((uint8_t *)df + sizeof(DROPFILES));
  size_t k = 0;
  for (int i = 0; i < units; i++) {
    if (w[i] == L'\r') continue;
    list[k++] = w[i] == L'\n' ? 0 : (w[i] == L'/' ? L'\\' : w[i]);
  }
  list[k++] = 0;
  list[k] = 0;
  GlobalUnlock(g);
  free(w);
  DWORD copy = DROPEFFECT_COPY;
  HGLOBAL effect = global_of(&copy, sizeof copy);
  HGLOBAL pngg = img_n && !strcmp(mime, "image/png") ? global_of(img, img_n) : NULL;
  HGLOBAL dib = img_n ? dib_of(img, img_n) : NULL;
  if (!open_clipboard()) {
    GlobalFree(g);
    if (effect) GlobalFree(effect);
    if (pngg) GlobalFree(pngg);
    if (dib) GlobalFree(dib);
    return "another program holds the clipboard";
  }
  EmptyClipboard();
  const char *err = SetClipboardData(CF_HDROP, g) ? NULL : (GlobalFree(g), "the clipboard refused the files");
  if (effect && !SetClipboardData(CF_DROPEFFECT, effect)) GlobalFree(effect);
  if (pngg && !SetClipboardData(CF_PNG, pngg)) GlobalFree(pngg);
  if (dib && !SetClipboardData(CF_DIB, dib)) GlobalFree(dib);
  CloseClipboard();
  return err;
}

static void run_command(command_t *c) {
  if (c->kind == 'I') {
    uint8_t head[4] = {(uint8_t)(k_sent >> 24), (uint8_t)(k_sent >> 16), (uint8_t)(k_sent >> 8), (uint8_t)k_sent};
    record('I', head, 4, png, png_n);
    return;
  }
  const char *err = c->kind == 'T' ? write_text(c->text, c->text_n) : write_files(c->text, c->text_n, c->img, c->img_n, c->mime);
  if (err) {
    record('W', err, strlen(err), NULL, 0);
    return;
  }
  own_seq = GetClipboardSequenceNumber();
  free(png);
  png = NULL;
  png_n = 0;
  record('W', "ok", 2, NULL, 0);
  report(1);
}

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM wp, LPARAM lp) {
  switch (m) {
    case WM_CLIPBOARDUPDATE:
      SetTimer(h, DEBOUNCE_TIMER, 60, NULL);
      return 0;
    case WM_TIMER:
      if (wp == DEBOUNCE_TIMER) {
        KillTimer(h, DEBOUNCE_TIMER);
        report(0);
      }
      return 0;
    case WM_COMMAND_IN:
      run_command((command_t *)lp);
      return 0;
    case WM_CLOSE:
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(h, m, wp, lp);
}

// stdin: a command at a time, run on the window's thread (SendMessage waits for it).
static DWORD WINAPI read_commands(LPVOID unused) {
  (void)unused;
  char line[256];
  while (in_line(line, sizeof line)) {
    command_t c = {0};
    size_t uris = 0, gnome = 0;
    if (line[0] == 'Q') break;
    if (line[0] == 'I') {
      c.kind = 'I';
    } else if (line[0] == 'T' && sscanf(line + 1, "%zu", &c.text_n) == 1) {
      c.kind = 'T';
      c.text = malloc(c.text_n + 1);
      if (!c.text || !in_exact(c.text, c.text_n)) break;
    } else if (line[0] == 'F' && sscanf(line + 1, "%zu %zu %zu %zu %63s", &uris, &gnome, &c.text_n, &c.img_n, c.mime) == 5) {
      c.kind = 'F';
      uint8_t *skip = malloc(uris + gnome + 1);
      c.text = malloc(c.text_n + 1);
      c.img = malloc(c.img_n + 1);
      if (!skip || !c.text || !c.img || !in_exact(skip, uris + gnome) || !in_exact(c.text, c.text_n) || !in_exact(c.img, c.img_n)) break;
      free(skip);
    } else {
      fprintf(stderr, "yoyo-winclip: bad command \"%s\"\n", line);
      continue;
    }
    SendMessageW(win, WM_COMMAND_IN, 0, (LPARAM)&c);
    free(c.text);
    free(c.img);
  }
  PostMessageW(win, WM_CLOSE, 0, 0);
  return 0;
}

int main(void) {
  helper_init();
  if (FAILED(CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)) ||
      FAILED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, (void **)&wic))) {
    fprintf(stderr, "yoyo-winclip: WIC is not available\n");
    return 1;
  }
  CF_PNG = RegisterClipboardFormatW(L"PNG");
  CF_EXCLUDE = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
  CF_DROPEFFECT = RegisterClipboardFormatW(L"Preferred DropEffect");
  WNDCLASSW wc = {0};
  wc.lpfnWndProc = wndproc;
  wc.hInstance = GetModuleHandleW(NULL);
  wc.lpszClassName = L"yoyo-winclip";
  RegisterClassW(&wc);
  win = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, wc.hInstance, NULL);
  if (!win || !AddClipboardFormatListener(win)) {
    fprintf(stderr, "yoyo-winclip: the clipboard listener can't be set up (error %lu)\n", GetLastError());
    return 1;
  }
  record('H', NULL, 0, NULL, 0);
  report(0);
  CreateThread(NULL, 0, read_commands, NULL, 0, NULL);
  MSG m;
  while (GetMessageW(&m, NULL, 0, 0) > 0) {
    TranslateMessage(&m);
    DispatchMessageW(&m);
  }
  return 0;
}
