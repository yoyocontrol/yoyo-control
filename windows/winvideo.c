// yoyo-winvideo: the video source of yoyo-windows (the shared server, linux/server.mjs with the Windows platform). The
// Windows twin of linux/x11video.c — the same arguments, commands and records, so the server's stream loop (video.mjs)
// runs unchanged: it watches the main display for changes (DXGI Desktop Duplication: a frame comes when something
// was drawn or the pointer moved) and, when told to, takes the latest picture, draws the pointer in and encodes it as
// one Annex-B access unit (BT.709, limited range): a key frame (SPS + PPS + IDR) when asked, else a delta; no
// B-frames, no lookahead, no reordering, no delay. The server decides when to encode (pace, flow-control window,
// refine, keepalive: linux/README.md「视频流」); this program only reports changes and encodes on command.
//
// Two encoders. The graphics card's own (winhw.h: the picture stays on the card — its video processor makes NV12, its
// H.264 encoder the access unit; a few ms a picture at any size, no CPU) is used wherever there is one; without (no
// hardware encoder, a driver that refuses, a Windows without Media Foundation) or when it fails mid-stream, x264 on
// the CPU: the picture read back, converted to I420 here and encoded as on Linux (x11video.c). `--encoder` /
// YOYO_VIDEO_ENCODER (`gpu` | `x264`) picks one; a line on stderr says which runs.
//
// While a stream runs the display is kept awake (a display asleep presents nothing: there would be no picture), and
// one found asleep at the start is woken (a pointer move of no distance).
//
// With `--cursor client` the pointer is the client's to draw (the protocol's `cursor=client`): it is never drawn into
// the pictures, its moves and shape changes are no picture change, and it is reported as 'P' records instead — where
// it is (at most every 8 ms, only when it moved), and its shape (the duplication's pointer shape; the pixels the
// first time this process sees that shape). A pointer that changes its shape more than 10 times a second (an animated
// busy cursor) keeps its last reported shape until it has been still for 0.5 s.
//
// The display: the main monitor (the one at 0,0) of the desktop this process runs on — an interactive session's
// (the console's, or a remote one's); a service in session 0 has none (exit 1). The picture is in physical pixels
// (the process is per-monitor DPI aware). While the desktop can't be duplicated (the secure desktop: UAC, the lock
// screen, Ctrl+Alt+Del; a mode change in progress) the last picture stands and duplication is tried again every
// 250 ms; a new size ends the stream (exit 3).
//
// Arguments: [--preset <x264 preset>] [--threads <n>] [--fps <n>] [--cursor client] [--encoder gpu|x264].
//   --bench <pictures> [--size <w> <h>] [--kbps <n>]
//       no desktop needed (a service's session will do): a moving test picture of w × h (default 2560 × 1440) encoded
//       that many times as fast as it goes (a key frame halfway, a refine every --fps pictures, as a stream asks);
//       the raw H.264 on stdout, the encoder and its times on stderr.
//   --jpeg <quality 10…95> --size <w> <h> [--crop <x> <y> <w> <h>] [--box <x> <y> <w> <h>]…
//       one picture instead (GET /frame): the pointer drawn in, the boxes (screen pixels) painted over in the mask
//       colour, the crop (screen pixels) cut out, scaled to w × h (area averaging), a JPEG (WIC) on stdout; exit 0.
//       The picture is the composed desktop as GDI hands it over (gdi_grab); the duplication only when that fails.
//
// stdin, one command per line:
//   E <key 0|1> <kbps> [<crf> [<buf>]]   grab and encode now: quality-targeted (x264's CRF, default 23) under a cap
//                                 of kbps over 1 s (VBV); a refine asks for a lower crf and a higher cap. buf: the VBV
//                                 buffer in kbit (default kbps): kbps per --fps pictures may be scaled up for fewer
//                                 pictures (the link's frame-rate cap) while a key frame still fits ~1 s of real rate
//   T <ms> <id>                   a timer: a 'T' record with this id after ms (one at a time: a new T replaces the
//                                 pending one). Windows' own timers tick every 15.6 ms for the server; this process
//                                 runs at 1 ms, so the server paces its pictures with these
//   Q                             quit (stdin's end too)
// stdout, records: one type byte, a 4-byte big-endian payload length, the payload:
//   'H' hello, once at start: u16 BE width, u16 BE height (even: an odd edge is left out), u8 flags (1 = T timers)
//   'T' a timer is due: u32 BE id
//   'C' the screen (or the pointer) changed since the last grab; once per change until the next E
//   'F' a frame: u8 flags (1 = key, 2 = the picture changed since the previous grab), f64 LE capture time (ms since
//       1970), then the access unit
//   'S' skipped: the encoder gave no picture for that E (rate control)
//   'P' the pointer (--cursor client only; one right after the hello, then on every move or shape change): i16 BE x,
//       i16 BE y (pixels), u32 BE shape serial, u16 BE xhot, yhot, width, height, u8 flags (1 = visible, 2 = the
//       shape's pixels follow, 4 = no shape could be read: the client's built-in arrow), then, with flag 2,
//       width × height × 4 bytes of premultiplied RGBA
// stderr: log lines. Exit 0 on Q / end of stdin, 1 when the display or the encoder can't be had, 3 when the screen
// changed size.
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>
#include <mmsystem.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wincodec.h>
#include <fcntl.h>
#include <io.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <x264.h>

#include "common.h"

static int width, height;          // the picture (even)
static int out_w, out_h;           // the output's own size (odd edges included)
static ID3D11Device *dev;
static ID3D11DeviceContext *ctx;
static IDXGIOutput1 *output;
static IDXGIOutputDuplication *dupl;
static ID3D11Texture2D *latest;    // the newest desktop picture (GPU)
static ID3D11Texture2D *staging;   // read back from here
static ID3D11Texture2D *shown;     // GPU path, pointer drawn in: `latest` with the pointer over it
static ID3D11Texture2D *ptr_staging;  // what is under the pointer, read back to blend (256 x 256)
static UINT adapter_vendor;        // the card's PCI vendor (its own encoder is tried first)
static int have_image = 0;
static int fresh_dupl = 0;         // a duplication's first frame is the whole picture, whatever its present time
static int encoder_mode = 0;       // 0: the GPU's when it has one, 1: the GPU's or none, 2: x264
static int hw_on = 0, hw_tried = 0;
static int bench = 0;              // --bench: no desktop, a test picture
// Two threads while a stream runs: one takes the desktop's frames as they come (the newest picture, the pointer),
// the other obeys the server (commands, the timer) at once — a wait for a frame can't be cut short by a command.
// `state` guards what both touch: dirty / told, the pointer (`cur`, its shapes, pending_move), have_image. The
// graphics context is multithread-protected (open_output), so its calls need no lock of ours.
static CRITICAL_SECTION state;
static int capturing = 0;          // the capture thread runs
static uint8_t *bgra;              // the picture on the CPU (width x height x 4), the pointer drawn in
static int dirty = 1, told = 0;
static uint8_t *yuv;
static x264_t *enc;
static x264_param_t par;
static int cur_kbps = 0;
static int cur_buf = 0;
static float cur_crf = 0;
static int64_t pts = 0;
static const char *preset = "superfast";
static int threads = 0;
static int fps = 30;
static int client_cursor = 0;

// the pointer: its shape (premultiplied RGBA), where its hot spot is, whether it shows
static struct {
  uint32_t serial;  // a number per distinct shape (this process)
  int xhot, yhot, w, h, visible, none;
  int x, y;         // the hot spot (pixels)
  uint8_t *rgba;
  uint32_t hash;
} cur = {0, 0, 0, 0, 0, 0, 1, -1, -1, NULL, 0};
static double sent_at = 0;
static int pending_move = 0;
// shapes this process has seen: hash → serial, and whether its pixels went out
static struct { uint32_t hash, serial; int sent; } *shapes;
static size_t shapes_n, shapes_cap;
static uint32_t next_serial = 1;
// animated pointers: shape changes in the current 1 s window; while `animating`, shapes are held until 0.5 s of quiet
static double anim_window_at = 0, last_shape_at = 0;
static int anim_count = 0, animating = 0, anim_logged = 0, held_shape = 0;
static uint8_t *ptr_buf;           // the duplication's pointer shape buffer
static UINT ptr_buf_size;

static void die(const char *what) {
  fprintf(stderr, "yoyo-winvideo: %s\n", what);
  exit(1);
}

#include "winhw.h"

static void put16(uint8_t *p, int v) {
  p[0] = (uint8_t)((unsigned)v >> 8);
  p[1] = (uint8_t)v;
}

static void put32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
}

static int jpeg_mode = 0;          // --jpeg: stdout is the picture alone, no records

static void mark_dirty(void) {
  dirty = 1;
  if (!told && !jpeg_mode) {
    told = 1;
    record('C', NULL, 0, NULL, 0);
  }
}

// ---- the pointer

static uint32_t fnv(const uint8_t *p, size_t n, uint32_t h) {
  for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 16777619u;
  return h;
}

// One 'P' record: the pointer as `cur` has it, its pixels when they haven't gone out yet.
static void send_pointer(int with_pixels) {
  uint8_t head[17];
  put16(head, cur.x);
  put16(head + 2, cur.y);
  put32(head + 4, cur.none ? 0 : cur.serial);
  put16(head + 8, cur.none ? 0 : cur.xhot);
  put16(head + 10, cur.none ? 0 : cur.yhot);
  put16(head + 12, cur.none ? 0 : cur.w);
  put16(head + 14, cur.none ? 0 : cur.h);
  int px = with_pixels && !cur.none && cur.rgba;
  head[16] = (uint8_t)((cur.visible ? 1 : 0) | (px ? 2 : 0) | (cur.none ? 4 : 0));
  record('P', head, sizeof head, px ? cur.rgba : NULL, px ? (size_t)cur.w * cur.h * 4 : 0);
  sent_at = now_ms();
  pending_move = 0;
}

// The shape now `cur`'s: reported (client cursor) with its pixels the first time this process sees it.
static void report_shape(void) {
  size_t i;
  for (i = 0; i < shapes_n; i++)
    if (shapes[i].hash == cur.hash) break;
  if (i == shapes_n) {
    if (shapes_n == shapes_cap) {
      shapes_cap = shapes_cap ? shapes_cap * 2 : 64;
      shapes = realloc(shapes, shapes_cap * sizeof *shapes);
      if (!shapes) die("out of memory");
    }
    shapes[i].hash = cur.hash;
    shapes[i].serial = next_serial++;
    shapes[i].sent = 0;
    shapes_n++;
  }
  cur.serial = shapes[i].serial;
  int first = !shapes[i].sent;
  shapes[i].sent = 1;
  send_pointer(first);
}

// The duplication's shape buffer → premultiplied RGBA in `cur`. Monochrome and masked-colour shapes have no true
// colours for XOR pixels (they invert what is under them): drawn as black with a white edge would need the picture;
// an inverting pixel becomes opaque black, a transparent one transparent.
static void take_shape(const DXGI_OUTDUPL_POINTER_SHAPE_INFO *si) {
  int w = (int)si->Width, h = (int)si->Height;
  if (si->Type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME) h /= 2;
  if (w <= 0 || h <= 0 || w > 256 || h > 256) {
    cur.none = 1;
    return;
  }
  uint8_t *rgba = malloc((size_t)w * h * 4);
  if (!rgba) die("out of memory");
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      uint8_t *d = rgba + ((size_t)y * w + x) * 4;
      if (si->Type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME) {
        const uint8_t *androw = ptr_buf + (size_t)y * si->Pitch, *xorrow = ptr_buf + (size_t)(y + h) * si->Pitch;
        int a = (androw[x / 8] >> (7 - x % 8)) & 1, xo = (xorrow[x / 8] >> (7 - x % 8)) & 1;
        if (a && !xo) d[0] = d[1] = d[2] = d[3] = 0;                 // transparent
        else if (!a && !xo) d[0] = d[1] = d[2] = 0, d[3] = 255;       // black
        else if (!a && xo) d[0] = d[1] = d[2] = d[3] = 255;           // white
        else d[0] = d[1] = d[2] = 0, d[3] = 255;                      // inverted: black
      } else {
        const uint8_t *s = ptr_buf + (size_t)y * si->Pitch + (size_t)x * 4;  // BGRA
        unsigned b = s[0], g = s[1], r = s[2], a = s[3];
        if (si->Type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR) {
          // alpha 0: the colour replaces the screen; 0xFF: XOR with it (black: no change)
          if (a == 0) a = 255;
          else a = (r | g | b) ? 255 : 0, r = g = b = 0;
          d[0] = (uint8_t)r, d[1] = (uint8_t)g, d[2] = (uint8_t)b, d[3] = (uint8_t)a;
        } else {
          // colour: straight alpha → premultiplied
          d[0] = (uint8_t)(r * a / 255), d[1] = (uint8_t)(g * a / 255), d[2] = (uint8_t)(b * a / 255), d[3] = (uint8_t)a;
        }
      }
    }
  }
  free(cur.rgba);
  cur.rgba = rgba;
  cur.w = w;
  cur.h = h;
  cur.xhot = (int)si->HotSpot.x;
  cur.yhot = (int)si->HotSpot.y;
  cur.none = 0;
  uint32_t hsh = fnv(rgba, (size_t)w * h * 4, 2166136261u);
  uint8_t dims[8];
  put16(dims, w), put16(dims + 2, h), put16(dims + 4, cur.xhot), put16(dims + 6, cur.yhot);
  cur.hash = fnv(dims, 8, hsh);
}

// A new shape from the duplication. More than 10 in a second: an animated pointer — its shape is held (positions
// still go out) until it has been quiet for 0.5 s (hold_check).
static void shape_changed(void) {
  double now = now_ms();
  last_shape_at = now;
  if (now - anim_window_at >= 1000) {
    anim_window_at = now;
    anim_count = 0;
  }
  if (++anim_count > 10 && !animating) {
    animating = 1;
    if (!anim_logged) {
      anim_logged = 1;
      fprintf(stderr, "yoyo-winvideo: the pointer changes its shape more than 10 times a second (animated); holding its shape while it does\n");
    }
  }
  if (animating) {
    held_shape = 1;
    return;
  }
  report_shape();
}

static void hold_check(void) {
  if (!animating || now_ms() - last_shape_at < 500) return;
  animating = 0;
  anim_count = 0;
  if (held_shape) {
    held_shape = 0;
    report_shape();
  }
}

// A frame's pointer news: where it is, whether it shows, a new shape.
static void pointer_update(const DXGI_OUTDUPL_FRAME_INFO *fi) {
  if (fi->LastMouseUpdateTime.QuadPart == 0) return;
  int vis = fi->PointerPosition.Visible ? 1 : 0;
  int new_shape = 0;
  if (fi->PointerShapeBufferSize > 0) {
    if (fi->PointerShapeBufferSize > ptr_buf_size) {
      free(ptr_buf);
      ptr_buf = malloc(fi->PointerShapeBufferSize);
      if (!ptr_buf) die("out of memory");
      ptr_buf_size = fi->PointerShapeBufferSize;
    }
    UINT need = 0;
    DXGI_OUTDUPL_POINTER_SHAPE_INFO si;
    if (SUCCEEDED(IDXGIOutputDuplication_GetFramePointerShape(dupl, ptr_buf_size, ptr_buf, &need, &si))) {
      uint32_t before = cur.hash;
      int was_none = cur.none;
      take_shape(&si);
      new_shape = cur.hash != before || was_none != cur.none;
    }
  }
  // the position is the shape's top-left corner; the hot spot is where it points
  int x = fi->PointerPosition.Position.x + cur.xhot, y = fi->PointerPosition.Position.y + cur.yhot;
  int moved = x != cur.x || y != cur.y || vis != cur.visible;
  if (vis) cur.x = x, cur.y = y;
  cur.visible = vis;
  if (client_cursor) {
    if (new_shape) shape_changed();
    // a move goes out at once, at most every 8 ms (the server sends on at most 60 a second); one held back is sent
    // by the main loop when its time comes
    if (moved && now_ms() - sent_at >= 8) send_pointer(0);
    else if (moved) pending_move = 1;
    if ((pending_move || animating) && lineq_event) SetEvent(lineq_event);
  } else if (moved || new_shape) {
    mark_dirty();
  }
}

// The pointer drawn over the picture (premultiplied RGBA over BGRA).
static void draw_pointer(void) {
  if (!cur.visible || cur.none || !cur.rgba) return;
  int ox = cur.x - cur.xhot, oy = cur.y - cur.yhot;
  for (int j = 0; j < cur.h; j++) {
    int y = oy + j;
    if (y < 0 || y >= height) continue;
    for (int i = 0; i < cur.w; i++) {
      int x = ox + i;
      if (x < 0 || x >= width) continue;
      const uint8_t *p = cur.rgba + ((size_t)j * cur.w + i) * 4;
      unsigned a = p[3];
      if (!a) continue;
      uint8_t *d = bgra + ((size_t)y * width + x) * 4;
      d[0] = (uint8_t)(p[2] + d[0] * (255 - a) / 255);
      d[1] = (uint8_t)(p[1] + d[1] * (255 - a) / 255);
      d[2] = (uint8_t)(p[0] + d[2] * (255 - a) / 255);
    }
  }
}

// ---- the desktop

static void protect_context(void);

// The main monitor's output (DesktopCoordinates at 0,0) and a device on its adapter.
static void open_output(void) {
  IDXGIFactory1 *factory;
  if (FAILED(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&factory))) die("CreateDXGIFactory1 failed");
  IDXGIAdapter1 *adapter = NULL;
  IDXGIOutput *out = NULL;
  // any failure ends a list (a session without a desktop answers DXGI_ERROR_NOT_CURRENTLY_AVAILABLE, not NOT_FOUND)
  for (UINT a = 0; !out && SUCCEEDED(IDXGIFactory1_EnumAdapters1(factory, a, &adapter)); a++) {
    IDXGIOutput *o;
    for (UINT i = 0; SUCCEEDED(IDXGIAdapter1_EnumOutputs(adapter, i, &o)); i++) {
      DXGI_OUTPUT_DESC d;
      IDXGIOutput_GetDesc(o, &d);
      if (d.AttachedToDesktop && d.DesktopCoordinates.left == 0 && d.DesktopCoordinates.top == 0) {
        out = o;
        break;
      }
      IDXGIOutput_Release(o);
    }
    if (!out) IDXGIAdapter1_Release(adapter);
  }
  IDXGIFactory1_Release(factory);
  if (!out) die("no display attached to this desktop (a service's session has none: run in the user's session)");
  if (FAILED(IDXGIOutput_QueryInterface(out, &IID_IDXGIOutput1, (void **)&output))) die("no IDXGIOutput1 (Windows 8 or later is needed)");
  IDXGIOutput_Release(out);
  D3D_FEATURE_LEVEL fl;
  DXGI_ADAPTER_DESC1 ad;
  if (SUCCEEDED(IDXGIAdapter1_GetDesc1(adapter, &ad))) adapter_vendor = ad.VendorId;
  // video support: the card's video processor and encoder (winhw.h); a device without still captures
  if (FAILED(D3D11CreateDevice((IDXGIAdapter *)adapter, D3D_DRIVER_TYPE_UNKNOWN, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, NULL, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx)) &&
      FAILED(D3D11CreateDevice((IDXGIAdapter *)adapter, D3D_DRIVER_TYPE_UNKNOWN, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx)))
    die("D3D11CreateDevice failed");
  IDXGIAdapter1_Release(adapter);
  protect_context();
  DXGI_OUTPUT_DESC d;
  IDXGIOutput1_GetDesc(output, &d);
  out_w = d.DesktopCoordinates.right - d.DesktopCoordinates.left;
  out_h = d.DesktopCoordinates.bottom - d.DesktopCoordinates.top;
  width = out_w & ~1;
  height = out_h & ~1;
  if (width < 16 || height < 16) die("the screen is too small");
}

// The context is used from two threads here, and from the encoder's own.
static void protect_context(void) {
  ID3D10Multithread *mt;
  if (SUCCEEDED(ID3D11DeviceContext_QueryInterface(ctx, &IID_ID3D10Multithread, (void **)&mt))) {
    ID3D10Multithread_SetMultithreadProtected(mt, TRUE);
    ID3D10Multithread_Release(mt);
  }
}

static HRESULT duplicate(void) {
  if (dupl) {
    IDXGIOutputDuplication_Release(dupl);
    dupl = NULL;
  }
  // the secure desktop (UAC, the lock screen) is its own desktop: follow the input desktop when allowed
  HDESK in = OpenInputDesktop(0, FALSE, GENERIC_ALL);
  if (in) {
    SetThreadDesktop(in);
    CloseDesktop(in);
  }
  HRESULT hr = IDXGIOutput1_DuplicateOutput(output, (IUnknown *)dev, &dupl);
  if (FAILED(hr)) return hr;
  fresh_dupl = 1;
  DXGI_OUTDUPL_DESC dd;
  IDXGIOutputDuplication_GetDesc(dupl, &dd);
  int w = (int)dd.ModeDesc.Width, h = (int)dd.ModeDesc.Height;
  if (dd.Rotation == DXGI_MODE_ROTATION_ROTATE90 || dd.Rotation == DXGI_MODE_ROTATION_ROTATE270) {
    int t = w;
    w = h;
    h = t;
  }
  if ((w & ~1) != width || (h & ~1) != height) {
    fprintf(stderr, "yoyo-winvideo: the screen is now %dx%d\n", w, h);
    exit(3);
  }
  return S_OK;
}

static void make_textures(void) {
  D3D11_TEXTURE2D_DESC td = {0};
  td.Width = (UINT)out_w;
  td.Height = (UINT)out_h;
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  // a render target: what the card's video processor takes as its input (winhw.h)
  td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  if (FAILED(ID3D11Device_CreateTexture2D(dev, &td, NULL, &latest))) die("CreateTexture2D failed");
  if (!client_cursor && FAILED(ID3D11Device_CreateTexture2D(dev, &td, NULL, &shown))) die("CreateTexture2D failed");
  td.BindFlags = 0;
  td.Usage = D3D11_USAGE_STAGING;
  td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  if (FAILED(ID3D11Device_CreateTexture2D(dev, &td, NULL, &staging))) die("CreateTexture2D (staging) failed");
  td.Width = td.Height = 256;
  if (FAILED(ID3D11Device_CreateTexture2D(dev, &td, NULL, &ptr_staging))) die("CreateTexture2D (staging) failed");
}

static double lost_at = 0;
static int lost_logged = 0;

// Waits up to `ms` for the next desktop frame and takes its news: a new picture (kept on the GPU), the pointer.
// Returns 1 when a frame came.
static int pump(UINT ms) {
  if (!dupl) {
    if (now_ms() - lost_at < 250) {
      Sleep(ms);
      return 0;
    }
    lost_at = now_ms();
    HRESULT hr = duplicate();
    if (FAILED(hr)) {
      if (!lost_logged) fprintf(stderr, "yoyo-winvideo: the desktop can't be duplicated now (0x%08lx; the secure desktop?); the last picture stands\n", (unsigned long)hr);
      lost_logged = 1;
      Sleep(ms);
      return 0;
    }
    if (lost_logged) fprintf(stderr, "yoyo-winvideo: the desktop is back\n");
    lost_logged = 0;
  }
  DXGI_OUTDUPL_FRAME_INFO fi;
  IDXGIResource *res = NULL;
  HRESULT hr = IDXGIOutputDuplication_AcquireNextFrame(dupl, ms, &fi, &res);
  if (hr == DXGI_ERROR_WAIT_TIMEOUT) return 0;
  if (FAILED(hr)) {
    // ACCESS_LOST: a desktop switch, a mode change, a full-screen app; made again on the next turn
    IDXGIOutputDuplication_Release(dupl);
    dupl = NULL;
    lost_at = 0;
    return 0;
  }
  EnterCriticalSection(&state);
  // a new duplication's first frame holds the whole desktop even when nothing was presented since (a still screen)
  if (fi.LastPresentTime.QuadPart != 0 || fresh_dupl) {
    fresh_dupl = 0;
    ID3D11Texture2D *tex;
    if (SUCCEEDED(IDXGIResource_QueryInterface(res, &IID_ID3D11Texture2D, (void **)&tex))) {
      ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)latest, (ID3D11Resource *)tex);
      ID3D11Texture2D_Release(tex);
      have_image = 1;
      mark_dirty();
    }
  }
  pointer_update(&fi);
  LeaveCriticalSection(&state);
  IDXGIResource_Release(res);
  IDXGIOutputDuplication_ReleaseFrame(dupl);
  return 1;
}

// The first picture comes with the duplication's first frame: waited for once (≤ 0.5 s; black until it comes).
static void wait_first_picture(void) {
  static int waited = 0;
  if (have_image || waited || bench) return;
  waited = 1;
  for (int i = 0; !have_image && i < 50; i++) {
    if (capturing) Sleep(10);
    else pump(10);
  }
}

// The desktop's frames, looked for without waiting inside the duplication: a wait there holds the graphics context's
// lock, and the encoding thread would stand still for as long. Every ms while frames come, every 4 ms on a still desktop.
static DWORD WINAPI capture_thread(LPVOID unused) {
  (void)unused;
  double frame_at = 0;
  for (;;) {
    if (pump(0)) frame_at = now_ms();
    else Sleep(now_ms() - frame_at < 250 ? 1 : 4);
  }
  return 0;
}

static void cpu_buffers(void) {
  if (bgra) return;
  bgra = malloc((size_t)width * height * 4);
  yuv = malloc((size_t)width * height * 3 / 2);
  if (!bgra || !yuv) die("out of memory");
}

// The latest picture → `bgra` (the pointer drawn in unless the client draws it).
static void grab(int draw) {
  cpu_buffers();
  wait_first_picture();
  if (!have_image) {
    memset(bgra, 0, (size_t)width * height * 4);
  } else {
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)latest);
    D3D11_MAPPED_SUBRESOURCE m;
    if (FAILED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m))) die("Map failed");
    for (int y = 0; y < height; y++) memcpy(bgra + (size_t)y * width * 4, (uint8_t *)m.pData + (size_t)y * m.RowPitch, (size_t)width * 4);
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
  }
  if (draw) {
    EnterCriticalSection(&state);
    draw_pointer();
    LeaveCriticalSection(&state);
  }
}

// BGRX → I420, BT.709 limited range (the VUI says so); chroma from each 2x2 block's sum (as x11video.c).
static void convert(void) {
  const uint8_t *src = bgra;
  int stride = width * 4;
  uint8_t *Y = yuv, *U = yuv + width * height, *V = U + (width / 2) * (height / 2);
  for (int y = 0; y < height; y += 2) {
    const uint8_t *r0 = src + (size_t)y * stride, *r1 = r0 + stride;
    uint8_t *y0 = Y + (size_t)y * width, *y1 = y0 + width;
    uint8_t *u = U + (size_t)(y / 2) * (width / 2), *v = V + (size_t)(y / 2) * (width / 2);
    for (int x = 0; x < width; x += 2) {
      int b00 = r0[x * 4], g00 = r0[x * 4 + 1], R00 = r0[x * 4 + 2];
      int b01 = r0[x * 4 + 4], g01 = r0[x * 4 + 5], R01 = r0[x * 4 + 6];
      int b10 = r1[x * 4], g10 = r1[x * 4 + 1], R10 = r1[x * 4 + 2];
      int b11 = r1[x * 4 + 4], g11 = r1[x * 4 + 5], R11 = r1[x * 4 + 6];
      y0[x] = (uint8_t)(16 + ((47 * R00 + 157 * g00 + 16 * b00 + 128) >> 8));
      y0[x + 1] = (uint8_t)(16 + ((47 * R01 + 157 * g01 + 16 * b01 + 128) >> 8));
      y1[x] = (uint8_t)(16 + ((47 * R10 + 157 * g10 + 16 * b10 + 128) >> 8));
      y1[x + 1] = (uint8_t)(16 + ((47 * R11 + 157 * g11 + 16 * b11 + 128) >> 8));
      int R = R00 + R01 + R10 + R11, G = g00 + g01 + g10 + g11, B = b00 + b01 + b10 + b11;
      u[x / 2] = (uint8_t)(128 + ((-26 * R - 87 * G + 112 * B + 512) >> 10));
      v[x / 2] = (uint8_t)(128 + ((112 * R - 102 * G - 10 * B + 512) >> 10));
    }
  }
}

// ---- x264 (the same settings as x11video.c)

static void open_encoder(int kbps, int buf, float crf) {
  if (x264_param_default_preset(&par, preset, "zerolatency") < 0) die("unknown x264 preset");
  par.i_width = width;
  par.i_height = height;
  par.i_csp = X264_CSP_I420;
  par.i_threads = threads;
  par.b_vfr_input = 0;
  par.i_fps_num = (uint32_t)fps;
  par.i_fps_den = 1;
  par.i_bframe = 0;
  par.i_keyint_max = X264_KEYINT_MAX_INFINITE;
  par.i_scenecut_threshold = 0;
  par.b_repeat_headers = 1;
  par.b_annexb = 1;
  par.b_aud = 0;
  par.i_log_level = X264_LOG_WARNING;
  par.vui.i_colorprim = 1;
  par.vui.i_transfer = 1;
  par.vui.i_colmatrix = 1;
  par.vui.b_fullrange = 0;
  par.rc.i_rc_method = X264_RC_CRF;
  par.rc.f_rf_constant = crf;
  par.rc.i_vbv_max_bitrate = kbps;
  par.rc.i_vbv_buffer_size = buf;
  if (x264_param_apply_profile(&par, "high") < 0) die("x264 profile");
  enc = x264_encoder_open(&par);
  if (!enc) die("x264_encoder_open failed");
  if (x264_encoder_maximum_delayed_frames(enc) != 0) die("x264 would delay pictures");
  cur_kbps = kbps;
  cur_buf = buf;
  cur_crf = crf;
}

static void set_rate(int kbps, int buf, float crf) {
  if (kbps == cur_kbps && buf == cur_buf && crf == cur_crf) return;
  par.rc.f_rf_constant = crf;
  par.rc.i_vbv_max_bitrate = kbps;
  par.rc.i_vbv_buffer_size = buf;
  if (x264_encoder_reconfig(enc, &par) < 0) fprintf(stderr, "yoyo-winvideo: rate %d kbps crf %.1f refused\n", kbps, crf);
  cur_kbps = kbps;
  cur_buf = buf;
  cur_crf = crf;
}

// GPU path, pointer drawn in: `latest` → `shown` with the pointer blended over it (what is under it read back: a
// patch of at most 256 x 256).
static void hw_draw_pointer(void) {
  static uint8_t patch[256 * 256 * 4];
  ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)shown, (ID3D11Resource *)latest);
  if (!cur.visible || cur.none || !cur.rgba) return;
  int ox = cur.x - cur.xhot, oy = cur.y - cur.yhot;
  int x0 = ox < 0 ? 0 : ox, y0 = oy < 0 ? 0 : oy;
  int x1 = ox + cur.w > out_w ? out_w : ox + cur.w, y1 = oy + cur.h > out_h ? out_h : oy + cur.h;
  if (x1 <= x0 || y1 <= y0) return;
  int w = x1 - x0, h = y1 - y0;
  D3D11_BOX box = {(UINT)x0, (UINT)y0, 0, (UINT)x1, (UINT)y1, 1};
  ID3D11DeviceContext_CopySubresourceRegion(ctx, (ID3D11Resource *)ptr_staging, 0, 0, 0, 0, (ID3D11Resource *)latest, 0, &box);
  D3D11_MAPPED_SUBRESOURCE m;
  if (FAILED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)ptr_staging, 0, D3D11_MAP_READ, 0, &m))) return;
  for (int j = 0; j < h; j++) {
    const uint8_t *under = (uint8_t *)m.pData + (size_t)j * m.RowPitch;
    const uint8_t *p = cur.rgba + ((size_t)(y0 - oy + j) * cur.w + (x0 - ox)) * 4;
    uint8_t *d = patch + (size_t)j * w * 4;
    for (int i = 0; i < w; i++, under += 4, p += 4, d += 4) {
      unsigned a = p[3];
      d[0] = (uint8_t)(p[2] + under[0] * (255 - a) / 255);
      d[1] = (uint8_t)(p[1] + under[1] * (255 - a) / 255);
      d[2] = (uint8_t)(p[0] + under[2] * (255 - a) / 255);
      d[3] = 255;
    }
  }
  ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)ptr_staging, 0);
  ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)shown, 0, &box, patch, (UINT)w * 4, 0);
}

// The latest picture as one access unit: 1 with it in *au (valid until the next call), 0 when the encoder gave none.
// buf: the VBV buffer (kbit; <= 0: kbps, 1 s): kbps may be the per-picture rate scaled for fewer pictures than --fps
// (the link's frame-rate cap), while a key frame should still fit about 1 s of the real rate
static int encode_picture(int key, int kbps, float crf, int buf, uint8_t **au, size_t *n, int *is_key) {
  if (kbps < 100) kbps = 100;
  if (kbps > 100000) kbps = 100000;
  if (buf <= 0 || buf > kbps) buf = kbps;
  if (buf < 100) buf = 100;
  if (!(crf >= 0 && crf <= 51)) crf = 23;
  wait_first_picture();
  if (!hw_tried && encoder_mode != 2) {
    hw_tried = 1;
    hw_on = hw_open(dev, ctx, client_cursor ? latest : shown, out_w, out_h, width, height, fps, adapter_vendor, kbps, buf, crf);
    if (hw_on) fprintf(stderr, "yoyo-winvideo: encoding on the graphics card (%s)\n", hw.name[0] ? hw.name : "hardware H.264");
    else if (encoder_mode == 1) die("no GPU encoder (--encoder gpu)");
    else fprintf(stderr, "yoyo-winvideo: encoding with x264 on the CPU\n");
  }
  if (hw_on) {
    if (!client_cursor) {
      EnterCriticalSection(&state);
      hw_draw_pointer();
      LeaveCriticalSection(&state);
    }
    int r = hw_encode(key, kbps, buf, crf, au, n, is_key);
    if (r >= 0) return r;
    hw_on = 0;
    if (encoder_mode == 1) die("the GPU encoder failed (--encoder gpu)");
    fprintf(stderr, "yoyo-winvideo: the GPU encoder failed; going on with x264 on the CPU\n");
    key = 1;
  }
  if (!enc) open_encoder(kbps, buf, crf);
  else set_rate(kbps, buf, crf);
  grab(!client_cursor);
  convert();
  x264_picture_t in, out;
  x264_picture_init(&in);
  in.img.i_csp = X264_CSP_I420;
  in.img.i_plane = 3;
  in.img.plane[0] = yuv;
  in.img.plane[1] = yuv + width * height;
  in.img.plane[2] = in.img.plane[1] + (width / 2) * (height / 2);
  in.img.i_stride[0] = width;
  in.img.i_stride[1] = in.img.i_stride[2] = width / 2;
  in.i_type = key ? X264_TYPE_IDR : X264_TYPE_AUTO;
  in.i_pts = pts++;
  x264_nal_t *nals;
  int count;
  int size = x264_encoder_encode(enc, &nals, &count, &in, &out);
  if (size < 0) die("x264_encoder_encode failed");
  if (size == 0) return 0;
  *au = nals[0].p_payload;
  *n = (size_t)size;
  *is_key = out.b_keyframe ? 1 : 0;
  return 1;
}

static void encode(int key, int kbps, float crf, int buf) {
  EnterCriticalSection(&state);
  int changed = dirty;
  double at = now_ms();
  dirty = 0;
  told = 0;
  LeaveCriticalSection(&state);
  uint8_t *au;
  size_t n;
  int is_key;
  if (!encode_picture(key, kbps, crf, buf, &au, &n, &is_key)) {
    record('S', NULL, 0, NULL, 0);
    return;
  }
  uint8_t head[9];
  head[0] = (uint8_t)((is_key ? 1 : 0) | (changed ? 2 : 0));
  memcpy(head + 1, &at, 8);  // little-endian (x86-64, arm64)
  record('F', head, sizeof head, au, n);
}

// ---- --bench: a moving test picture through the encoder, no desktop needed

static int bench_run(int frames, int bw, int bh, int kbps) {
  D3D_FEATURE_LEVEL fl;
  if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, NULL, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx)))
    die("D3D11CreateDevice failed");
  IDXGIDevice *xd;
  if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&xd))) {
    IDXGIAdapter *ad;
    DXGI_ADAPTER_DESC d;
    if (SUCCEEDED(IDXGIDevice_GetAdapter(xd, &ad))) {
      if (SUCCEEDED(IDXGIAdapter_GetDesc(ad, &d))) {
        adapter_vendor = d.VendorId;
        fprintf(stderr, "yoyo-winvideo: bench on %ls\n", d.Description);
      }
      IDXGIAdapter_Release(ad);
    }
    IDXGIDevice_Release(xd);
  }
  out_w = bw;
  out_h = bh;
  width = bw & ~1;
  height = bh & ~1;
  if (width < 16 || height < 16) die("--size is too small");
  make_textures();
  have_image = 1;
  // the picture: a grey ramp, five colour patches (white, black, red, green, blue: 64 x 64 from 0,0), a block that moves
  uint8_t *pic = malloc((size_t)out_w * out_h * 4);
  if (!pic) die("out of memory");
  static const uint8_t patches[5][3] = {{255, 255, 255}, {0, 0, 0}, {0, 0, 255}, {0, 255, 0}, {255, 0, 0}};  // BGR
  for (int y = 0; y < out_h; y++)
    for (int x = 0; x < out_w; x++) {
      uint8_t *d = pic + ((size_t)y * out_w + x) * 4;
      if (y < 64 && x < 320) memcpy(d, patches[x / 64], 3);
      else d[0] = d[1] = d[2] = (uint8_t)(x * 255 / out_w);
      d[3] = 255;
    }
  ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)latest, 0, NULL, pic, (UINT)out_w * 4, 0);
  static uint8_t block[200 * 200 * 4];
  double sum = 0, worst = 0, first = 0;
  size_t bytes = 0;
  int keys = 0, skipped = 0;
  for (int i = 0; i < frames; i++) {
    // the block: its old place repainted, its new one drawn
    int bx = 100 + (i * 7) % (out_w - 400), by = 200 + (i * 3) % (out_h - 500);
    ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)latest, 0, NULL, pic, (UINT)out_w * 4, 0);
    for (size_t k = 0; k < sizeof block; k += 4) block[k] = (uint8_t)(k + i * 5), block[k + 1] = (uint8_t)(k >> 3), block[k + 2] = (uint8_t)(255 - i), block[k + 3] = 255;
    D3D11_BOX box = {(UINT)bx, (UINT)by, 0, (UINT)bx + 200, (UINT)by + 200, 1};
    ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)latest, 0, &box, block, 200 * 4, 0);
    uint8_t *au;
    size_t n;
    int is_key;
    double t0 = now_ms();
    // what a stream does on the way: a key frame asked for halfway, a refine (sharper, twice the rate) once a second
    int refine = i % fps == fps - 1;
    int r = encode_picture(i == 0 || i == frames / 2, refine ? kbps * 2 : kbps, refine ? 17 : 23, 0, &au, &n, &is_key);
    double ms = now_ms() - t0;
    if (!r) {
      skipped++;
      continue;
    }
    if (i == 0) first = ms;
    else {
      sum += ms;
      if (ms > worst) worst = ms;
    }
    bytes += n;
    keys += is_key;
    write_all(au, n);
  }
  int timed = frames - 1 - skipped;
  fprintf(stderr, "yoyo-winvideo: bench %dx%d, %d pictures (%d key, %d skipped): the first %.1f ms (the encoder opens), then mean %.2f ms, max %.2f ms; %.0f kbit/s at %d fps; %s\n", width,
          height, frames, keys, skipped, first, timed > 0 ? sum / timed : 0, worst, frames ? (double)bytes * 8 * fps / frames / 1000 : 0, fps, hw_on ? hw.name : "x264");
  return 0;
}

// ---- --jpeg: one picture for GET /frame

#define MAX_BOXES 512
static const uint8_t MASK_B = 0x3a, MASK_G = 0x3a, MASK_R = 0x3a;  // windows.mjs WINDOWS.maskColor

// The main display as it is composed now → `bgra`, the pointer drawn in: a BitBlt from the screen. Not the
// duplication: a new one has a picture only once something is presented to the display, and on a still desktop
// nothing is — its first frame came black (every GET /frame of a PC nobody was using, while a stream beside it, whose
// duplication had seen the desktop drawn, showed it). 1 = `bgra` holds the picture.
static int gdi_grab(void) {
  cpu_buffers();
  HDC screen = GetDC(NULL);
  if (!screen) return 0;
  HDC mem = CreateCompatibleDC(screen);
  BITMAPINFO bi = {0};
  bi.bmiHeader.biSize = sizeof bi.bmiHeader;
  bi.bmiHeader.biWidth = width;
  bi.bmiHeader.biHeight = -height;  // top row first
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void *bits = NULL;
  HBITMAP bmp = mem ? CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, NULL, 0) : NULL;
  int ok = 0;
  if (bmp && bits) {
    HGDIOBJ old = SelectObject(mem, bmp);
    ok = BitBlt(mem, 0, 0, width, height, screen, 0, 0, SRCCOPY | CAPTUREBLT) != 0;
    if (ok) {
      CURSORINFO ci = {0};
      ci.cbSize = sizeof ci;
      ICONINFO ii;
      if (GetCursorInfo(&ci) && (ci.flags & CURSOR_SHOWING) && GetIconInfo(ci.hCursor, &ii)) {
        DrawIconEx(mem, ci.ptScreenPos.x - (int)ii.xHotspot, ci.ptScreenPos.y - (int)ii.yHotspot, ci.hCursor, 0, 0, 0, NULL, DI_NORMAL);
        if (ii.hbmMask) DeleteObject(ii.hbmMask);
        if (ii.hbmColor) DeleteObject(ii.hbmColor);
      }
      GdiFlush();
      memcpy(bgra, bits, (size_t)width * height * 4);
    }
    SelectObject(mem, old);
  }
  if (bmp) DeleteObject(bmp);
  if (mem) DeleteDC(mem);
  ReleaseDC(NULL, screen);
  return ok;
}

// `grabbed`: `bgra` already holds the picture (gdi_grab); else the duplication's latest.
static int jpeg_frame(int quality, int ow, int oh, const int crop[4], int (*boxes)[4], int nboxes, int grabbed) {
  if (!grabbed) grab(1);
  for (int b = 0; b < nboxes; b++) {
    int x0 = boxes[b][0], y0 = boxes[b][1], x1 = x0 + boxes[b][2], y1 = y0 + boxes[b][3];
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > width) x1 = width;
    if (y1 > height) y1 = height;
    for (int y = y0; y < y1; y++)
      for (int x = x0; x < x1; x++) {
        uint8_t *d = bgra + ((size_t)y * width + x) * 4;
        d[0] = MASK_B, d[1] = MASK_G, d[2] = MASK_R;
      }
  }
  int cx = crop[0], cy = crop[1], cw = crop[2], ch = crop[3];
  if (cw <= 0 || ch <= 0) cx = 0, cy = 0, cw = width, ch = height;
  if (cx < 0) cx = 0;
  if (cy < 0) cy = 0;
  if (cx + cw > width) cw = width - cx;
  if (cy + ch > height) ch = height - cy;
  if (ow < 2 || oh < 2 || cw < 1 || ch < 1) die("--jpeg: empty picture");
  // area averaging: each output pixel is the mean of the source pixels it covers (whole-pixel bounds)
  uint8_t *rgb = malloc((size_t)ow * oh * 3);
  if (!rgb) die("out of memory");
  for (int oy = 0; oy < oh; oy++) {
    int sy0 = cy + (int)((int64_t)oy * ch / oh), sy1 = cy + (int)((int64_t)(oy + 1) * ch / oh);
    if (sy1 <= sy0) sy1 = sy0 + 1;
    for (int ox = 0; ox < ow; ox++) {
      int sx0 = cx + (int)((int64_t)ox * cw / ow), sx1 = cx + (int)((int64_t)(ox + 1) * cw / ow);
      if (sx1 <= sx0) sx1 = sx0 + 1;
      unsigned sb = 0, sg = 0, sr = 0, n = 0;
      for (int y = sy0; y < sy1; y++) {
        const uint8_t *p = bgra + ((size_t)y * width + sx0) * 4;
        for (int x = sx0; x < sx1; x++, p += 4) sb += p[0], sg += p[1], sr += p[2], n++;
      }
      uint8_t *d = rgb + ((size_t)oy * ow + ox) * 3;
      d[0] = (uint8_t)(sb / n), d[1] = (uint8_t)(sg / n), d[2] = (uint8_t)(sr / n);  // BGR (WIC's 24bppBGR)
    }
  }
  IWICImagingFactory *wic;
  if (FAILED(CoCreateInstance(&CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &IID_IWICImagingFactory, (void **)&wic))) die("WIC is not available");
  IStream *stream;
  if (FAILED(CreateStreamOnHGlobal(NULL, TRUE, &stream))) die("CreateStreamOnHGlobal failed");
  IWICBitmapEncoder *encoder;
  IWICBitmapFrameEncode *frame;
  IPropertyBag2 *props;
  if (FAILED(IWICImagingFactory_CreateEncoder(wic, &GUID_ContainerFormatJpeg, NULL, &encoder))) die("no JPEG encoder");
  if (FAILED(IWICBitmapEncoder_Initialize(encoder, stream, WICBitmapEncoderNoCache))) die("JPEG encoder: Initialize");
  if (FAILED(IWICBitmapEncoder_CreateNewFrame(encoder, &frame, &props))) die("JPEG encoder: CreateNewFrame");
  PROPBAG2 opt = {0};
  opt.pstrName = L"ImageQuality";
  VARIANT v;
  VariantInit(&v);
  v.vt = VT_R4;
  v.fltVal = (float)quality / 100.0f;
  IPropertyBag2_Write(props, 1, &opt, &v);
  if (FAILED(IWICBitmapFrameEncode_Initialize(frame, props))) die("JPEG encoder: frame Initialize");
  IWICBitmapFrameEncode_SetSize(frame, (UINT)ow, (UINT)oh);
  WICPixelFormatGUID fmt = GUID_WICPixelFormat24bppBGR;
  IWICBitmapFrameEncode_SetPixelFormat(frame, &fmt);
  if (FAILED(IWICBitmapFrameEncode_WritePixels(frame, (UINT)oh, (UINT)ow * 3, (UINT)ow * oh * 3, rgb))) die("JPEG encoder: WritePixels");
  IWICBitmapFrameEncode_Commit(frame);
  IWICBitmapEncoder_Commit(encoder);
  HGLOBAL hg;
  GetHGlobalFromStream(stream, &hg);
  STATSTG st;
  IStream_Stat(stream, &st, STATFLAG_NONAME);
  void *bytes = GlobalLock(hg);
  write_all(bytes, (size_t)st.cbSize.QuadPart);
  GlobalUnlock(hg);
  return 0;
}

// ---- main

int main(int argc, char **argv) {
  int jpeg = 0, quality = 70, ow = 0, oh = 0, crop[4] = {0, 0, 0, 0}, nboxes = 0, bench_kbps = 8000;
  const char *which = getenv("YOYO_VIDEO_ENCODER");
  static int boxes[MAX_BOXES][4];
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--preset") && i + 1 < argc) preset = argv[++i];
    else if (!strcmp(argv[i], "--threads") && i + 1 < argc) threads = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--cursor") && i + 1 < argc && !strcmp(argv[i + 1], "client")) client_cursor = 1, i++;
    else if (!strcmp(argv[i], "--encoder") && i + 1 < argc) which = argv[++i];
    else if (!strcmp(argv[i], "--bench") && i + 1 < argc) bench = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--kbps") && i + 1 < argc) bench_kbps = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--jpeg") && i + 1 < argc) jpeg = 1, quality = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--size") && i + 2 < argc) ow = atoi(argv[i + 1]), oh = atoi(argv[i + 2]), i += 2;
    else if (!strcmp(argv[i], "--crop") && i + 4 < argc) {
      for (int k = 0; k < 4; k++) crop[k] = atoi(argv[i + 1 + k]);
      i += 4;
    } else if (!strcmp(argv[i], "--box") && i + 4 < argc && nboxes < MAX_BOXES) {
      for (int k = 0; k < 4; k++) boxes[nboxes][k] = atoi(argv[i + 1 + k]);
      nboxes++;
      i += 4;
    } else
      die("usage: yoyo-winvideo [--preset <x264 preset>] [--threads <n>] [--fps <n>] [--cursor client] [--encoder gpu|x264] | --jpeg <q> --size <w> <h> [--crop x y w h] [--box x y w h]… | --bench <pictures> [--size <w> <h>] [--kbps <n>]");
  }
  if (fps < 1 || fps > 60) die("--fps must be 1…60");
  if (quality < 10) quality = 10;
  if (quality > 95) quality = 95;
  if (which && *which) {
    if (!strcmp(which, "gpu")) encoder_mode = 1;
    else if (!strcmp(which, "x264")) encoder_mode = 2;
    else if (strcmp(which, "auto")) die("the encoder is gpu, x264 or auto");
  }
  helper_init();
  InitializeCriticalSection(&state);
  // this process's timers and waits at 1 ms (Windows' default tick is 15.6 ms)
  timeBeginPeriod(1);
  CoInitializeEx(NULL, COINIT_MULTITHREADED);
  if (bench > 0) {
    jpeg_mode = 1;  // stdout is the stream alone
    return bench_run(bench, ow > 0 ? ow : 2560, oh > 0 ? oh : 1440, bench_kbps);
  }
  open_output();
  jpeg_mode = jpeg;
  // one picture: the composed desktop from GDI (a still desktop gives a new duplication nothing to show)
  if (jpeg && gdi_grab()) return jpeg_frame(quality, ow, oh, crop, boxes, nboxes, 1);
  make_textures();
  HRESULT hr = duplicate();
  if (FAILED(hr)) {
    // E_ACCESSDENIED: the secure desktop now, or no interactive desktop at all (session 0); at start this is fatal
    fprintf(stderr, "yoyo-winvideo: the desktop can't be duplicated (0x%08lx): run in the signed-in user's session\n", (unsigned long)hr);
    return 1;
  }
  if (jpeg) return jpeg_frame(quality, ow, oh, crop, boxes, nboxes, 0);

  uint8_t hello[5] = {(uint8_t)(width >> 8), (uint8_t)width, (uint8_t)(height >> 8), (uint8_t)height, 1};
  record('H', hello, 5, NULL, 0);
  // someone is watching: the display stays awake, and one asleep (it presents nothing: no picture) is woken
  SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
  // the first frame carries the picture and the pointer's shape: the client draws the pointer from the first part on
  for (int i = 0; i < 25 && !have_image; i++) pump(10);
  if (!have_image) {
    fprintf(stderr, "yoyo-winvideo: no picture from the desktop yet (the display is asleep?); waking it\n");
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    in.mi.dwFlags = MOUSEEVENTF_MOVE;
    SendInput(1, &in, sizeof in);
    for (int i = 0; i < 100 && !have_image; i++) pump(10);
    if (have_image) fprintf(stderr, "yoyo-winvideo: the desktop shows again\n");
  }
  if (client_cursor) {
    if (cur.hash) report_shape();
    else send_pointer(0);
  }
  record('C', NULL, 0, NULL, 0);
  told = 1;

  start_stdin_reader();
  char line[256];
  // from here the desktop's frames are taken on a thread of their own
  capturing = 1;
  CreateThread(NULL, 0, capture_thread, NULL, 0, NULL);
  double timer_due = 0;
  uint32_t timer_id = 0;
  // the timer to a fraction of a millisecond where Windows has such timers (10 1803 on), else to the millisecond
  HANDLE fine = CreateWaitableTimerExW(NULL, NULL, 2 /* CREATE_WAITABLE_TIMER_HIGH_RESOLUTION */, TIMER_ALL_ACCESS);
  for (;;) {
    if (timer_due > 0 && now_ms() >= timer_due) {
      uint8_t id[4];
      put32(id, timer_id);
      timer_due = 0;
      record('T', id, 4, NULL, 0);
    }
    // the pointer: a move held back by the 8 ms pace, a shape held while it animates
    int soon = 0;
    if (client_cursor) {
      EnterCriticalSection(&state);
      hold_check();
      if (pending_move && now_ms() - sent_at >= 8) send_pointer(0);
      soon = pending_move || animating;
      LeaveCriticalSection(&state);
    }
    int r;
    while ((r = next_line(line, sizeof line)) > 0) {
      int key = 0, kbps = 0, buf = 0;
      float crf = 23;
      double ms = 0;
      unsigned id = 0;
      if (line[0] == 'Q') goto done;
      if (line[0] == 'E' && sscanf(line + 1, "%d %d %f %d", &key, &kbps, &crf, &buf) >= 2) encode(key, kbps, crf, buf);
      else if (line[0] == 'T' && sscanf(line + 1, "%lf %u", &ms, &id) == 2) timer_due = now_ms() + (ms > 0 ? ms : 0) + 1e-6, timer_id = id;
      else fprintf(stderr, "yoyo-winvideo: bad command \"%s\"\n", line);
    }
    if (r < 0) break;
    // until a command comes, the timer is due, or the pointer wants another look
    HANDLE hs[2] = {lineq_event, fine};
    DWORD n = 1, until = soon ? 4 : 250;
    if (timer_due > 0) {
      double left = timer_due - now_ms();
      if (left <= 0) continue;
      if (fine) {
        LARGE_INTEGER due;
        due.QuadPart = -(LONGLONG)(left * 10000);
        SetWaitableTimer(fine, &due, 0, NULL, NULL, FALSE);
        n = 2;
      } else if (left < until) {
        until = (DWORD)left + 1;
      }
    }
    WaitForMultipleObjects(n, hs, FALSE, until);
  }
done:
  if (hw_on) hw_close();
  if (enc) x264_encoder_close(enc);
  return 0;
}
