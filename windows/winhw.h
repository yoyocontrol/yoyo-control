// The GPU path of yoyo-winvideo: the desktop picture never leaves the graphics card. The duplication's texture is
// converted to NV12 by the card's video processor (BT.709, limited range — what the x264 path's convert() makes) and
// encoded by the card's own H.264 encoder (NVIDIA NVENC, AMD AMF, Intel Quick Sync), reached through Media Foundation's
// hardware encoder transform: one way in for every vendor, nothing to ship. A 2560 × 1440 picture takes a few
// milliseconds and no CPU to speak of, where the CPU path (read back, convert, x264) takes 20–30 ms of every core.
//
// What the server asks of an encoder (winvideo.c's head) maps like this:
//   a key frame when asked         CODECAPI_AVEncVideoForceKeyFrame before that picture; no key frames otherwise (one GOP)
//   kbps, buf                      the rate control's mean / peak rate and its buffer, changed on the fly
//   crf                            no encoder here has x264's CRF: it becomes the lowest QP the rate control may use
//                                  (crf − 3), so a simple picture doesn't spend the whole rate, and a refine (a lower
//                                  crf, a higher rate) may go sharper
//   one access unit per E, at once low-latency mode, no B-frames: every picture comes out before the next goes in
// Access unit delimiters and filler are dropped; a key frame that comes without its SPS / PPS gets the stream's.
//
// Media Foundation is loaded at run time (LoadLibrary): Windows N and Server without the media features have no
// mfplat.dll, and there the program must still start and encode with x264. Any failure here — no hardware encoder, a
// driver that refuses the types, an encode that doesn't come back — ends the GPU path for this process: hw_open /
// hw_encode return 0 / -1, a line goes to stderr and the caller carries on with x264 (a key frame first).
#include <d3d10.h>
#include <d3d11.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <mftransform.h>
#include <codecapi.h>
#include <icodecapi.h>

#define HW_RING 3  // NV12 pictures in turn: an encoder may still hold the previous one

// the codec properties, as GUIDs of our own (the SDK's names need a library some toolchains lack)
static const GUID HW_RC_MODE = {STATIC_CODECAPI_AVEncCommonRateControlMode};
static const GUID HW_MEAN_RATE = {STATIC_CODECAPI_AVEncCommonMeanBitRate};
static const GUID HW_MAX_RATE = {STATIC_CODECAPI_AVEncCommonMaxBitRate};
static const GUID HW_BUFFER = {STATIC_CODECAPI_AVEncCommonBufferSize};
static const GUID HW_LOW_LATENCY = {STATIC_CODECAPI_AVLowLatencyMode};
static const GUID HW_GOP = {STATIC_CODECAPI_AVEncMPVGOPSize};
static const GUID HW_BFRAMES = {STATIC_CODECAPI_AVEncMPVDefaultBPictureCount};
static const GUID HW_CABAC = {STATIC_CODECAPI_AVEncH264CABACEnable};
static const GUID HW_MIN_QP = {STATIC_CODECAPI_AVEncVideoMinQP};
static const GUID HW_FORCE_KEY = {STATIC_CODECAPI_AVEncVideoForceKeyFrame};

static struct {
  HMODULE dll;
  HRESULT(WINAPI *Startup)(ULONG, DWORD);
  HRESULT(WINAPI *TEnumEx)(GUID, UINT32, const MFT_REGISTER_TYPE_INFO *, const MFT_REGISTER_TYPE_INFO *, IMFActivate ***, UINT32 *);
  HRESULT(WINAPI *CreateDXGIDeviceManager)(UINT *, IMFDXGIDeviceManager **);
  HRESULT(WINAPI *CreateDXGISurfaceBuffer)(REFIID, IUnknown *, UINT, BOOL, IMFMediaBuffer **);
  HRESULT(WINAPI *CreateSample)(IMFSample **);
  HRESULT(WINAPI *CreateMediaType)(IMFMediaType **);
  HRESULT(WINAPI *CreateMemoryBuffer)(DWORD, IMFMediaBuffer **);
} mf;

static struct {
  int w, h, fps;
  ID3D11Device *dev;
  ID3D11DeviceContext *ctx;
  ID3D11VideoDevice *vdev;
  ID3D11VideoContext *vctx;
  ID3D11VideoProcessorEnumerator *vpe;
  ID3D11VideoProcessor *vp;
  ID3D11Texture2D *src;  // the BGRA picture the input view is of
  ID3D11VideoProcessorInputView *in_view;
  ID3D11Texture2D *nv12[HW_RING];
  ID3D11VideoProcessorOutputView *out_view[HW_RING];
  int ring;
  IMFDXGIDeviceManager *mgr;
  IMFTransform *mft;
  IMFMediaEventGenerator *events;
  ICodecAPI *codec;
  int need_input, have_output;  // the transform's events not yet answered
  int provides_samples;
  DWORD out_size;
  uint8_t *header;  // SPS + PPS (Annex B), for a key frame that comes without
  UINT32 header_n;
  uint8_t *au;
  size_t au_cap;
  int kbps, buf;
  float crf;
  int64_t pts;
  char name[160];
} hw;

static void hw_log(const char *what, HRESULT hr) {
  fprintf(stderr, "yoyo-winvideo: GPU encoder: %s (0x%08lx)\n", what, (unsigned long)hr);
}

static int hw_load_mf(void) {
  if (mf.dll) return 1;
  HMODULE m = LoadLibraryW(L"mfplat.dll");
  if (!m) return 0;
  mf.Startup = (void *)GetProcAddress(m, "MFStartup");
  mf.TEnumEx = (void *)GetProcAddress(m, "MFTEnumEx");
  mf.CreateDXGIDeviceManager = (void *)GetProcAddress(m, "MFCreateDXGIDeviceManager");
  mf.CreateDXGISurfaceBuffer = (void *)GetProcAddress(m, "MFCreateDXGISurfaceBuffer");
  mf.CreateSample = (void *)GetProcAddress(m, "MFCreateSample");
  mf.CreateMediaType = (void *)GetProcAddress(m, "MFCreateMediaType");
  mf.CreateMemoryBuffer = (void *)GetProcAddress(m, "MFCreateMemoryBuffer");
  if (!mf.Startup || !mf.TEnumEx || !mf.CreateDXGIDeviceManager || !mf.CreateDXGISurfaceBuffer || !mf.CreateSample || !mf.CreateMediaType || !mf.CreateMemoryBuffer) return 0;
  if (FAILED(mf.Startup(MF_VERSION, MFSTARTUP_LITE))) return 0;
  mf.dll = m;
  return 1;
}

static HRESULT hw_set_u32(const GUID *prop, ULONG v) {
  VARIANT var;
  VariantInit(&var);
  var.vt = VT_UI4;
  var.ulVal = v;
  return ICodecAPI_SetValue(hw.codec, prop, &var);
}

static HRESULT hw_set_bool(const GUID *prop, int on) {
  VARIANT var;
  VariantInit(&var);
  var.vt = VT_BOOL;
  var.boolVal = on ? VARIANT_TRUE : VARIANT_FALSE;
  return ICodecAPI_SetValue(hw.codec, prop, &var);
}

static UINT64 hw_pair(UINT32 hi, UINT32 lo) { return ((UINT64)hi << 32) | lo; }

// The rate (kbps, the buffer in kbit) and the quality floor, as they change.
static void hw_set_rate(int kbps, int buf, float crf) {
  if (kbps != hw.kbps) {
    hw_set_u32(&HW_MEAN_RATE, (ULONG)kbps * 1000);
    hw_set_u32(&HW_MAX_RATE, (ULONG)kbps * 1000);
  }
  if (buf != hw.buf) hw_set_u32(&HW_BUFFER, (ULONG)buf * 1000);
  if (crf != hw.crf) {
    int qp = (int)(crf + 0.5f) - 3;
    hw_set_u32(&HW_MIN_QP, (ULONG)(qp < 1 ? 1 : qp > 40 ? 40 : qp));
  }
  hw.kbps = kbps;
  hw.buf = buf;
  hw.crf = crf;
}

// The video types of both sides: what is the same in them.
static void hw_common_type(IMFMediaType *t, const GUID *subtype) {
  IMFMediaType_SetGUID(t, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
  IMFMediaType_SetGUID(t, &MF_MT_SUBTYPE, subtype);
  IMFMediaType_SetUINT64(t, &MF_MT_FRAME_SIZE, hw_pair((UINT32)hw.w, (UINT32)hw.h));
  IMFMediaType_SetUINT64(t, &MF_MT_FRAME_RATE, hw_pair((UINT32)hw.fps, 1));
  IMFMediaType_SetUINT64(t, &MF_MT_PIXEL_ASPECT_RATIO, hw_pair(1, 1));
  IMFMediaType_SetUINT32(t, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  IMFMediaType_SetUINT32(t, &MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
  IMFMediaType_SetUINT32(t, &MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
  IMFMediaType_SetUINT32(t, &MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709);
  IMFMediaType_SetUINT32(t, &MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
}

// The stream's SPS + PPS, from the output type (kept for key frames that come without).
static void hw_take_header(void) {
  IMFMediaType *t;
  free(hw.header);
  hw.header = NULL;
  hw.header_n = 0;
  if (FAILED(IMFTransform_GetOutputCurrentType(hw.mft, 0, &t))) return;
  UINT32 n = 0;
  if (SUCCEEDED(IMFMediaType_GetBlobSize(t, &MF_MT_MPEG_SEQUENCE_HEADER, &n)) && n > 0 && n < 4096) {
    hw.header = malloc(n);
    if (hw.header && SUCCEEDED(IMFMediaType_GetBlob(t, &MF_MT_MPEG_SEQUENCE_HEADER, hw.header, n, &n))) hw.header_n = n;
  }
  IMFMediaType_Release(t);
}

static void hw_drop_transform(void) {
  if (hw.codec) ICodecAPI_Release(hw.codec);
  if (hw.events) IMFMediaEventGenerator_Release(hw.events);
  if (hw.mft) IMFTransform_Release(hw.mft);
  hw.codec = NULL;
  hw.events = NULL;
  hw.mft = NULL;
  hw.need_input = hw.have_output = 0;
}

// One hardware encoder set up for our pictures; 0 when it won't do (and nothing of it is kept).
static int hw_setup_transform(IMFTransform *mft, int kbps, int buf, float crf) {
  HRESULT hr;
  hw.mft = mft;
  IMFTransform_AddRef(mft);
  IMFAttributes *a = NULL;
  if (FAILED(IMFTransform_GetAttributes(mft, &a)) || !a) goto no;
  UINT32 aware = 0;
  IMFAttributes_SetUINT32(a, &MF_TRANSFORM_ASYNC_UNLOCK, 1);
  IMFAttributes_SetUINT32(a, &MF_LOW_LATENCY, 1);
  IMFAttributes_GetUINT32(a, &MF_SA_D3D11_AWARE, &aware);
  IMFAttributes_Release(a);
  if (!aware) goto no;
  if (FAILED(IMFTransform_QueryInterface(mft, &IID_IMFMediaEventGenerator, (void **)&hw.events))) goto no;
  if (FAILED(IMFTransform_QueryInterface(mft, &IID_ICodecAPI, (void **)&hw.codec))) goto no;
  if (FAILED(IMFTransform_ProcessMessage(mft, MFT_MESSAGE_SET_D3D_MANAGER, (ULONG_PTR)hw.mgr))) goto no;
  // a steady low-delay rate where the encoder has one, else constant
  if (FAILED(hw_set_u32(&HW_RC_MODE, eAVEncCommonRateControlMode_LowDelayVBR))) hw_set_u32(&HW_RC_MODE, eAVEncCommonRateControlMode_CBR);
  hw.kbps = hw.buf = 0;
  hw.crf = -1;
  hw_set_rate(kbps, buf, crf);
  hw_set_bool(&HW_LOW_LATENCY, 1);
  hw_set_u32(&HW_BFRAMES, 0);
  hw_set_bool(&HW_CABAC, 1);
  // one GOP: key frames only when the server asks (an encoder that wants a bound takes the largest it knows)
  if (FAILED(hw_set_u32(&HW_GOP, 0x7fffffff))) hw_set_u32(&HW_GOP, 0xffff);

  IMFMediaType *t;
  if (FAILED(mf.CreateMediaType(&t))) goto no;
  hw_common_type(t, &MFVideoFormat_H264);
  IMFMediaType_SetUINT32(t, &MF_MT_AVG_BITRATE, (UINT32)kbps * 1000);
  IMFMediaType_SetUINT32(t, &MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
  hr = IMFTransform_SetOutputType(mft, 0, t, 0);
  IMFMediaType_Release(t);
  if (FAILED(hr)) goto no;
  if (FAILED(mf.CreateMediaType(&t))) goto no;
  hw_common_type(t, &MFVideoFormat_NV12);
  hr = IMFTransform_SetInputType(mft, 0, t, 0);
  IMFMediaType_Release(t);
  if (FAILED(hr)) goto no;

  MFT_OUTPUT_STREAM_INFO osi = {0};
  IMFTransform_GetOutputStreamInfo(mft, 0, &osi);
  hw.provides_samples = (osi.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
  hw.out_size = osi.cbSize;
  if (FAILED(IMFTransform_ProcessMessage(mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0))) goto no;
  if (FAILED(IMFTransform_ProcessMessage(mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0))) goto no;
  hw_take_header();
  return 1;
no:
  hw_drop_transform();
  return 0;
}

// The card's H.264 encoder: the one of the vendor whose card shows the desktop first, then any other.
static int hw_find_encoder(int kbps, int buf, float crf, UINT vendor) {
  MFT_REGISTER_TYPE_INFO in = {MFMediaType_Video, MFVideoFormat_NV12}, out = {MFMediaType_Video, MFVideoFormat_H264};
  IMFActivate **acts = NULL;
  UINT32 n = 0;
  if (FAILED(mf.TEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, &in, &out, &acts, &n)) || !n) {
    if (acts) CoTaskMemFree(acts);
    return 0;
  }
  WCHAR want[16];
  _snwprintf(want, 16, L"VEN_%04X", vendor);
  int found = 0;
  for (int pass = 0; pass < 2 && !found; pass++) {
    for (UINT32 i = 0; i < n && !found; i++) {
      WCHAR ven[64] = L"";
      IMFActivate_GetString(acts[i], &MFT_ENUM_HARDWARE_VENDOR_ID_Attribute, ven, 64, NULL);
      int same = _wcsicmp(ven, want) == 0;
      if ((pass == 0) != same) continue;
      IMFTransform *mft = NULL;
      if (FAILED(IMFActivate_ActivateObject(acts[i], &IID_IMFTransform, (void **)&mft)) || !mft) continue;
      if (hw_setup_transform(mft, kbps, buf, crf)) {
        WCHAR name[128] = L"";
        IMFActivate_GetString(acts[i], &MFT_FRIENDLY_NAME_Attribute, name, 128, NULL);
        WideCharToMultiByte(CP_UTF8, 0, name, -1, hw.name, sizeof hw.name - 1, NULL, NULL);
        found = 1;
      } else {
        IMFActivate_ShutdownObject(acts[i]);
      }
      IMFTransform_Release(mft);
    }
  }
  for (UINT32 i = 0; i < n; i++) IMFActivate_Release(acts[i]);
  CoTaskMemFree(acts);
  return found;
}

// The video processor: `src` (BGRA, full range) → NV12 (BT.709, limited range), the odd edge left out.
static int hw_open_processor(ID3D11Texture2D *src, int src_w, int src_h) {
  if (FAILED(ID3D11Device_QueryInterface(hw.dev, &IID_ID3D11VideoDevice, (void **)&hw.vdev))) return 0;
  if (FAILED(ID3D11DeviceContext_QueryInterface(hw.ctx, &IID_ID3D11VideoContext, (void **)&hw.vctx))) return 0;
  D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd = {0};
  cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
  cd.InputFrameRate.Numerator = (UINT)hw.fps;
  cd.InputFrameRate.Denominator = 1;
  cd.InputWidth = (UINT)src_w;
  cd.InputHeight = (UINT)src_h;
  cd.OutputFrameRate = cd.InputFrameRate;
  cd.OutputWidth = (UINT)hw.w;
  cd.OutputHeight = (UINT)hw.h;
  cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
  if (FAILED(ID3D11VideoDevice_CreateVideoProcessorEnumerator(hw.vdev, &cd, &hw.vpe))) return 0;
  if (FAILED(ID3D11VideoDevice_CreateVideoProcessor(hw.vdev, hw.vpe, 0, &hw.vp))) return 0;
  D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd = {0};
  ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
  if (FAILED(ID3D11VideoDevice_CreateVideoProcessorInputView(hw.vdev, (ID3D11Resource *)src, hw.vpe, &ivd, &hw.in_view))) return 0;
  hw.src = src;
  D3D11_TEXTURE2D_DESC td = {0};
  td.Width = (UINT)hw.w;
  td.Height = (UINT)hw.h;
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT_NV12;
  td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_RENDER_TARGET;
  D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd = {0};
  ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
  for (int i = 0; i < HW_RING; i++) {
    if (FAILED(ID3D11Device_CreateTexture2D(hw.dev, &td, NULL, &hw.nv12[i]))) return 0;
    if (FAILED(ID3D11VideoDevice_CreateVideoProcessorOutputView(hw.vdev, (ID3D11Resource *)hw.nv12[i], hw.vpe, &ovd, &hw.out_view[i]))) return 0;
  }
  RECT r = {0, 0, hw.w, hw.h};
  ID3D11VideoContext_VideoProcessorSetStreamSourceRect(hw.vctx, hw.vp, 0, TRUE, &r);
  ID3D11VideoContext_VideoProcessorSetStreamDestRect(hw.vctx, hw.vp, 0, TRUE, &r);
  ID3D11VideoContext_VideoProcessorSetOutputTargetRect(hw.vctx, hw.vp, TRUE, &r);
  ID3D11VideoContext_VideoProcessorSetStreamFrameFormat(hw.vctx, hw.vp, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
  D3D11_VIDEO_PROCESSOR_COLOR_SPACE in_cs = {0}, out_cs = {0};
  in_cs.RGB_Range = 0;  // 0…255
  in_cs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255;
  out_cs.YCbCr_Matrix = 1;  // BT.709
  out_cs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
  ID3D11VideoContext_VideoProcessorSetStreamColorSpace(hw.vctx, hw.vp, 0, &in_cs);
  ID3D11VideoContext_VideoProcessorSetOutputColorSpace(hw.vctx, hw.vp, &out_cs);
  // the picture as it is: no driver "enhancements"
  ID3D11VideoContext_VideoProcessorSetStreamAutoProcessingMode(hw.vctx, hw.vp, 0, FALSE);
  return 1;
}

static void hw_close(void) {
  if (hw.mft) {
    IMFTransform_ProcessMessage(hw.mft, MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    IMFTransform_ProcessMessage(hw.mft, MFT_MESSAGE_COMMAND_FLUSH, 0);
  }
  hw_drop_transform();
  for (int i = 0; i < HW_RING; i++) {
    if (hw.out_view[i]) ID3D11VideoProcessorOutputView_Release(hw.out_view[i]);
    if (hw.nv12[i]) ID3D11Texture2D_Release(hw.nv12[i]);
    hw.out_view[i] = NULL;
    hw.nv12[i] = NULL;
  }
  if (hw.in_view) ID3D11VideoProcessorInputView_Release(hw.in_view);
  if (hw.vp) ID3D11VideoProcessor_Release(hw.vp);
  if (hw.vpe) ID3D11VideoProcessorEnumerator_Release(hw.vpe);
  if (hw.vctx) ID3D11VideoContext_Release(hw.vctx);
  if (hw.vdev) ID3D11VideoDevice_Release(hw.vdev);
  if (hw.mgr) IMFDXGIDeviceManager_Release(hw.mgr);
  hw.in_view = NULL;
  hw.vp = NULL;
  hw.vpe = NULL;
  hw.vctx = NULL;
  hw.vdev = NULL;
  hw.mgr = NULL;
}

// The GPU path for `src` (a BGRA texture of src_w × src_h on `dev`) as w × h pictures; 1 when it stands. `vendor`:
// the PCI vendor of the card (its own encoder is tried first).
static int hw_open(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11Texture2D *src, int src_w, int src_h, int w, int h, int fps, UINT vendor, int kbps, int buf, float crf) {
  hw.dev = dev;
  hw.ctx = ctx;
  hw.w = w;
  hw.h = h;
  hw.fps = fps;
  hw.pts = 0;
  hw.ring = 0;
  if (!hw_load_mf()) {
    fprintf(stderr, "yoyo-winvideo: GPU encoder: Media Foundation is not on this Windows\n");
    return 0;
  }
  // the encoder works on threads of its own with this device
  ID3D10Multithread *mt;
  if (SUCCEEDED(ID3D11DeviceContext_QueryInterface(ctx, &IID_ID3D10Multithread, (void **)&mt))) {
    ID3D10Multithread_SetMultithreadProtected(mt, TRUE);
    ID3D10Multithread_Release(mt);
  }
  UINT token = 0;
  HRESULT hr = mf.CreateDXGIDeviceManager(&token, &hw.mgr);
  if (SUCCEEDED(hr)) hr = IMFDXGIDeviceManager_ResetDevice(hw.mgr, (IUnknown *)dev, token);
  if (FAILED(hr)) {
    hw_log("no device manager", hr);
    hw_close();
    return 0;
  }
  if (!hw_open_processor(src, src_w, src_h)) {
    fprintf(stderr, "yoyo-winvideo: GPU encoder: this card has no video processor for BGRA → NV12\n");
    hw_close();
    return 0;
  }
  if (!hw_find_encoder(kbps, buf, crf, vendor)) {
    fprintf(stderr, "yoyo-winvideo: GPU encoder: no hardware H.264 encoder takes %dx%d on this card\n", w, h);
    hw_close();
    return 0;
  }
  return 1;
}

// The transform's next event, waited for until `deadline` (now_ms's clock); 0 when none came or it reports an error.
static int hw_event(double deadline) {
  for (;;) {
    IMFMediaEvent *ev = NULL;
    HRESULT hr = IMFMediaEventGenerator_GetEvent(hw.events, MF_EVENT_FLAG_NO_WAIT, &ev);
    if (hr == MF_E_NO_EVENTS_AVAILABLE) {
      if (now_ms() >= deadline) return 0;
      Sleep(1);
      continue;
    }
    if (FAILED(hr)) return 0;
    MediaEventType type = MEUnknown;
    IMFMediaEvent_GetType(ev, &type);
    IMFMediaEvent_Release(ev);
    if (type == METransformNeedInput) hw.need_input++;
    else if (type == METransformHaveOutput) hw.have_output++;
    else if (type == MEError) return 0;
    return 1;
  }
}

// One output sample's bytes into hw.au without access unit delimiters and filler; a key frame without parameter sets
// gets the stream's in front. Returns the length (0: nothing of use).
static size_t hw_take_au(const uint8_t *p, size_t n, int *is_key) {
  size_t need = n + hw.header_n + 16;
  if (need > hw.au_cap) {
    free(hw.au);
    hw.au = malloc(need);
    if (!hw.au) die("out of memory");
    hw.au_cap = need;
  }
  // the units: [start, end) of each, start code included
  size_t out = hw.header_n, i = 0, unit = (size_t)-1;
  int key = 0, sps = 0, type = -1;
  for (;;) {
    size_t sc = (size_t)-1, body = 0;
    for (; i + 2 < n; i++) {
      if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) {
        sc = i > 0 && p[i - 1] == 0 ? i - 1 : i;
        body = i + 3;
        break;
      }
    }
    size_t end = sc == (size_t)-1 ? n : sc;
    if (unit != (size_t)-1 && type != 9 && type != 12) {
      if (type == 5) key = 1;
      if (type == 7) sps = 1;
      memcpy(hw.au + out, p + unit, end - unit);
      out += end - unit;
    }
    if (sc == (size_t)-1) break;
    unit = sc;
    type = body < n ? p[body] & 0x1f : -1;
    i = body;
  }
  *is_key = key;
  if (key && !sps && hw.header_n) {
    memcpy(hw.au, hw.header, hw.header_n);
    return out;
  }
  // no header in front: the units alone
  memmove(hw.au, hw.au + hw.header_n, out - hw.header_n);
  return out - hw.header_n;
}

// The picture now in `src` encoded: 1 with the access unit in *au (*n bytes, valid until the next call), 0 when the
// encoder gave none, -1 when the GPU path failed (it is closed: the caller goes on without).
static int hw_encode(int key, int kbps, int buf, float crf, uint8_t **au, size_t *n, int *is_key) {
  hw_set_rate(kbps, buf, crf);
  int slot = hw.ring;
  hw.ring = (hw.ring + 1) % HW_RING;
  D3D11_VIDEO_PROCESSOR_STREAM st = {0};
  st.Enable = TRUE;
  st.pInputSurface = hw.in_view;
  HRESULT hr = ID3D11VideoContext_VideoProcessorBlt(hw.vctx, hw.vp, hw.out_view[slot], 0, 1, &st);
  if (FAILED(hr)) {
    hw_log("the video processor failed", hr);
    goto fail;
  }
  double deadline = now_ms() + 1000;
  while (!hw.need_input)
    if (!hw_event(deadline)) {
      hw_log("the encoder takes no picture", 0);
      goto fail;
    }
  if (key) hw_set_u32(&HW_FORCE_KEY, 1);
  IMFSample *sample = NULL;
  IMFMediaBuffer *mb = NULL;
  hr = mf.CreateSample(&sample);
  if (SUCCEEDED(hr)) hr = mf.CreateDXGISurfaceBuffer(&IID_ID3D11Texture2D, (IUnknown *)hw.nv12[slot], 0, FALSE, &mb);
  if (SUCCEEDED(hr)) hr = IMFSample_AddBuffer(sample, mb);
  if (SUCCEEDED(hr)) {
    IMFSample_SetSampleTime(sample, hw.pts * 10000000LL / hw.fps);
    IMFSample_SetSampleDuration(sample, 10000000LL / hw.fps);
    hw.pts++;
    hr = IMFTransform_ProcessInput(hw.mft, 0, sample, 0);
  }
  if (mb) IMFMediaBuffer_Release(mb);
  if (sample) IMFSample_Release(sample);
  if (FAILED(hr)) {
    hw_log("the encoder refused a picture", hr);
    goto fail;
  }
  hw.need_input--;
  while (!hw.have_output)
    if (!hw_event(deadline)) {
      hw_log("the encoder gave no picture back within a second", 0);
      goto fail;
    }
  hw.have_output--;
  for (int tries = 0;; tries++) {
    MFT_OUTPUT_DATA_BUFFER ob = {0};
    DWORD status = 0;
    IMFSample *mine = NULL;
    if (!hw.provides_samples) {
      IMFMediaBuffer *b = NULL;
      DWORD cap = hw.out_size ? hw.out_size : (DWORD)(hw.w * hw.h * 2);
      if (FAILED(mf.CreateSample(&mine)) || FAILED(mf.CreateMemoryBuffer(cap, &b))) {
        if (mine) IMFSample_Release(mine);
        goto fail;
      }
      IMFSample_AddBuffer(mine, b);
      IMFMediaBuffer_Release(b);
      ob.pSample = mine;
    }
    hr = IMFTransform_ProcessOutput(hw.mft, 0, 1, &ob, &status);
    if (ob.pEvents) IMFCollection_Release(ob.pEvents);
    if (hr == MF_E_TRANSFORM_STREAM_CHANGE && tries < 2) {
      // the encoder settled its output type (its parameter sets): taken, and the picture asked for again
      if (ob.pSample) IMFSample_Release(ob.pSample);
      IMFMediaType *t;
      if (SUCCEEDED(IMFTransform_GetOutputAvailableType(hw.mft, 0, 0, &t))) {
        IMFTransform_SetOutputType(hw.mft, 0, t, 0);
        IMFMediaType_Release(t);
      }
      hw_take_header();
      continue;
    }
    if (FAILED(hr) || !ob.pSample) {
      if (ob.pSample) IMFSample_Release(ob.pSample);
      hw_log("no output", hr);
      goto fail;
    }
    IMFMediaBuffer *b = NULL;
    size_t got = 0;
    if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(ob.pSample, &b))) {
      BYTE *p = NULL;
      DWORD len = 0;
      if (SUCCEEDED(IMFMediaBuffer_Lock(b, &p, NULL, &len))) {
        got = hw_take_au(p, len, is_key);
        IMFMediaBuffer_Unlock(b);
      }
      IMFMediaBuffer_Release(b);
    }
    IMFSample_Release(ob.pSample);
    *au = hw.au;
    *n = got;
    return got ? 1 : 0;
  }
fail:
  hw_close();
  return -1;
}
