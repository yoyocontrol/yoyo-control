// The x264 side of yoyo-x11video (and of test/synthvideo.c, which encodes made-up pictures the same way): one I420
// picture in, one Annex-B access unit out, at once — no B-frames, no lookahead, no reordering, no delay.
//
// Rate: quality-targeted (CRF) under a cap of `kbps` (VBV), with a VBV buffer of `buf` kbit. The buffer is what bounds
// one picture's size: a picture may take what the buffer holds, so a buffer of a few pictures' worth (the server's
// choice, README.md「视频流」) keeps every picture near its share of the rate — the link paces what it is given at
// about the rate, and a picture ten times its share is a picture ten frames late.
//
// Recovery without a key frame: the encoder keeps `enc_kept` earlier pictures (the stream's `max_num_ref_frames`: the
// decoder keeps the same ones) while each picture still searches only one of them. `enc_forget(n)` says the pictures
// numbered n and later never reached the decoder: the next picture then references the newest kept one before n (by
// an explicit reference list, so the decoder needs nothing it didn't get) — or is a key frame when none is left.
// x264's "reference invalidation", made for this.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <x264.h>

#ifndef ENC_NAME
#define ENC_NAME "yoyo-x11video"
#endif

static x264_t *enc;
static x264_param_t enc_par;
static int enc_width, enc_height;
static int enc_fps = 30;
static const char *enc_preset = "superfast";
static int enc_threads = 0;
static int enc_kbps = 0, enc_buf = 0;
static float enc_crf = 0;
/** The number of the next picture (0, 1, …: every enc_frame call takes one, also one that gave no picture). */
static int64_t enc_next = 0;
/** Earlier pictures kept as possible references (1: only the previous one, no enc_forget). */
static int enc_kept = 1;

static void enc_die(const char *what) {
  fprintf(stderr, ENC_NAME ": %s\n", what);
  exit(1);
}

// How many decoded pictures a stream of this size may ask a decoder to keep: level 5's limit (MaxDpbMbs 110400: every
// hardware decoder this is played on takes it), at most 16.
static int enc_kept_for(int width, int height) {
  long mbs = (long)((width + 15) / 16) * ((height + 15) / 16);
  long n = 110400 / (mbs > 0 ? mbs : 1);
  return n > 16 ? 16 : n < 1 ? 1 : (int)n;
}

static void enc_open(int kbps, int buf, float crf) {
  x264_param_t *par = &enc_par;
  if (x264_param_default_preset(par, enc_preset, "zerolatency") < 0) enc_die("unknown x264 preset");
  par->i_width = enc_width;
  par->i_height = enc_height;
  par->i_csp = X264_CSP_I420;
  par->i_threads = enc_threads;
  // constant-rate input as far as x264 knows: VFR input costs a picture of delay (it needs the next picture's time)
  par->b_vfr_input = 0;
  par->i_fps_num = (uint32_t)enc_fps;
  par->i_fps_den = 1;
  par->i_bframe = 0;
  par->i_keyint_max = X264_KEYINT_MAX_INFINITE;  // key frames only when asked
  par->i_scenecut_threshold = 0;
  par->b_repeat_headers = 1;  // SPS + PPS in front of every IDR
  par->b_annexb = 1;
  par->b_aud = 0;
  par->i_log_level = X264_LOG_WARNING;
  par->vui.i_colorprim = 1;  // BT.709
  par->vui.i_transfer = 1;
  par->vui.i_colmatrix = 1;
  par->vui.b_fullrange = 0;
  // one reference a picture (the search's cost stays), `enc_kept` pictures kept for enc_forget
  enc_kept = enc_kept_for(enc_width, enc_height);
  par->i_frame_reference = 1;
  par->i_dpb_size = enc_kept;
  // quality-targeted, capped: pictures come only when the screen changes, so an average-rate target would starve a
  // still screen's few pictures; the cap is what the server's flow control steers
  par->rc.i_rc_method = X264_RC_CRF;
  par->rc.f_rf_constant = crf;
  par->rc.i_vbv_max_bitrate = kbps;
  par->rc.i_vbv_buffer_size = buf;
  // the buffer starts full: the first picture (a key frame) may take all of it
  par->rc.f_vbv_buffer_init = 1.0f;
  if (x264_param_apply_profile(par, "high") < 0) enc_die("x264 profile");
  enc = x264_encoder_open(par);
  if (!enc) enc_die("x264_encoder_open failed");
  if (x264_encoder_maximum_delayed_frames(enc) != 0) enc_die("x264 would delay pictures");
  enc_kbps = kbps;
  enc_buf = buf;
  enc_crf = crf;
}

static void enc_rate(int kbps, int buf, float crf) {
  if (kbps == enc_kbps && buf == enc_buf && crf == enc_crf) return;
  enc_par.rc.f_rf_constant = crf;
  enc_par.rc.i_vbv_max_bitrate = kbps;
  enc_par.rc.i_vbv_buffer_size = buf;
  if (x264_encoder_reconfig(enc, &enc_par) < 0) fprintf(stderr, ENC_NAME ": rate %d kbps crf %.1f refused\n", kbps, crf);
  enc_kbps = kbps;
  enc_buf = buf;
  enc_crf = crf;
}

// The pictures numbered `from` and later did not reach the decoder: none of them is referenced again. With nothing
// older kept, x264 makes the next picture a key frame by itself.
static void enc_forget(int64_t from) {
  if (!enc || from < 0 || from >= enc_next) return;
  if (x264_encoder_invalidate_reference(enc, from) < 0) fprintf(stderr, ENC_NAME ": forgetting the pictures from %lld on failed\n", (long long)from);
}

// Encode one I420 picture (`yuv`: Y, then U, then V, enc_width x enc_height). `buf`: the VBV buffer in kbit (<= 0 or
// more than kbps: kbps, one second). Returns the access unit's size (0: the encoder gave no picture), `*au` its
// bytes (x264's, good until the next call), `*key` whether it is a key frame, `*number` its picture number.
static int enc_frame(const uint8_t *yuv, int key, int kbps, float crf, int buf, const uint8_t **au, int *is_key, int64_t *number) {
  if (kbps < 100) kbps = 100;
  if (kbps > 100000) kbps = 100000;
  if (buf <= 0 || buf > kbps) buf = kbps;
  // (x264 wants the buffer to hold one picture's share of the rate at least)
  int floor_buf = kbps / enc_fps + 1;
  if (buf < floor_buf) buf = floor_buf;
  if (!(crf >= 0 && crf <= 51)) crf = 23;
  if (!enc) enc_open(kbps, buf, crf);
  else enc_rate(kbps, buf, crf);
  x264_picture_t in, out;
  x264_picture_init(&in);
  in.img.i_csp = X264_CSP_I420;
  in.img.i_plane = 3;
  in.img.plane[0] = (uint8_t *)yuv;
  in.img.plane[1] = (uint8_t *)yuv + enc_width * enc_height;
  in.img.plane[2] = in.img.plane[1] + (enc_width / 2) * (enc_height / 2);
  in.img.i_stride[0] = enc_width;
  in.img.i_stride[1] = in.img.i_stride[2] = enc_width / 2;
  in.i_type = key ? X264_TYPE_IDR : X264_TYPE_AUTO;
  *number = enc_next;
  in.i_pts = enc_next++;
  x264_nal_t *nals;
  int n;
  int size = x264_encoder_encode(enc, &nals, &n, &in, &out);
  if (size < 0) enc_die("x264_encoder_encode failed");
  if (size == 0) return 0;
  // the NAL payloads are contiguous in x264's buffer: one access unit
  *au = nals[0].p_payload;
  *is_key = out.b_keyframe ? 1 : 0;
  return size;
}

// BGRX (`stride` bytes a row) → I420 into `yuv`, BT.709 limited range (the VUI says so); chroma from each 2x2 block's
// sum.
static void enc_convert(const uint8_t *src, int stride, uint8_t *yuv) {
  int width = enc_width, height = enc_height;
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
      // Y = 16 + (47 R + 157 G + 16 B) / 256: 0.2126, 0.7152, 0.0722 scaled to 219 levels
      y0[x] = (uint8_t)(16 + ((47 * R00 + 157 * g00 + 16 * b00 + 128) >> 8));
      y0[x + 1] = (uint8_t)(16 + ((47 * R01 + 157 * g01 + 16 * b01 + 128) >> 8));
      y1[x] = (uint8_t)(16 + ((47 * R10 + 157 * g10 + 16 * b10 + 128) >> 8));
      y1[x + 1] = (uint8_t)(16 + ((47 * R11 + 157 * g11 + 16 * b11 + 128) >> 8));
      int R = R00 + R01 + R10 + R11, G = g00 + g01 + g10 + g11, B = b00 + b01 + b10 + b11;
      // Cb = 128 + (-26 R - 87 G + 112 B) / 256, Cr = 128 + (112 R - 102 G - 10 B) / 256, on the 4-pixel sums
      u[x / 2] = (uint8_t)(128 + ((-26 * R - 87 * G + 112 * B + 512) >> 10));
      v[x / 2] = (uint8_t)(128 + ((112 * R - 102 * G - 10 * B + 512) >> 10));
    }
  }
}
