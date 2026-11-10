//! # uu Link media for browsers
//!
//! The client half of uu Link's media layer ([`uu_link_media::ClientMedia`]: FEC, NACK, frame reassembly, the
//! reference chain, input reliability, feedback) compiled to WebAssembly with wasm-bindgen, so a browser runs the
//! same state machine as the iOS app (docs/LINK.md「媒体」, 「WebRTC」). It is sans-IO like the crate it wraps: the
//! TypeScript driver in `@yoyocontrol/link-web` feeds it the `dgram` DataChannel's messages and a clock (µs as a JS
//! number), sends what [`ClientMedia::poll_transmit`] hands out, and arms one timer at [`ClientMedia::poll_timeout`].
//!
//! Copies: an incoming datagram is copied once into wasm memory (wasm-bindgen's `&[u8]`); a delivered frame's access
//! unit is copied once out of it into a fresh `Uint8Array` the caller owns; nothing else is retained.
//!
//! Events are plain JS objects with a `type` field (see [`ClientMedia::poll_event`]). Times are µs on the caller's
//! clock; `captureUs` / `timeUs` are the sender's wall clock (µs since 1970).

use js_sys::{Array, Object, Reflect, Uint8Array};
use uu_link_media::{
    ClientConfig, ClientEvent, Codec, FrameKind, InputError, InputKind, MediaStats, Micros, RxFate, RxTrace,
    client::ClientMedia as Inner,
};
use wasm_bindgen::prelude::*;

fn us(now_us: f64) -> Micros {
    Micros(if now_us.is_finite() && now_us > 0.0 { now_us.round() as u64 } else { 0 })
}

fn set(o: &Object, key: &str, value: impl Into<JsValue>) {
    // `Reflect::set` on a plain object never fails
    let _ = Reflect::set(o, &JsValue::from_str(key), &value.into());
}

fn opt_f64(v: Option<f64>) -> JsValue {
    v.map_or(JsValue::NULL, JsValue::from_f64)
}

/// A field of the config object as a number (absent / not a number: None).
fn field(config: &JsValue, key: &str) -> Option<f64> {
    if !config.is_object() {
        return None;
    }
    Reflect::get(config, &JsValue::from_str(key)).ok()?.as_f64().filter(|v| v.is_finite() && *v >= 0.0)
}

fn ms_field(config: &JsValue, key: &str) -> Option<Micros> {
    field(config, key).map(Micros::from_millis_f64)
}

/// `FrameKind` as the names the screen client uses.
fn kind_name(kind: FrameKind) -> &'static str {
    match kind {
        FrameKind::Delta => "delta",
        FrameKind::Key => "key",
        FrameKind::Refine => "refine",
        FrameKind::Keepalive => "keepalive",
        FrameKind::Recovery => "recovery",
    }
}

/// The client config from a JS object (see [`ClientMedia::new`]); the crate's defaults for what it doesn't say.
fn config_from(config: &JsValue) -> ClientConfig {
    let mut c = ClientConfig::default();
    if let Some(n) = field(config, "maxDatagram") {
        c.max_datagram = n as usize;
    }
    if let Some(t) = ms_field(config, "feedbackIntervalMs") {
        c.feedback_interval = t;
    }
    if let Some(t) = ms_field(config, "feedbackIdleMs") {
        c.feedback_idle = t;
    }
    if let Some(t) = ms_field(config, "audioReportIntervalMs") {
        c.audio_report_interval = t;
    }
    if let Some(t) = ms_field(config, "nackRepeatMs") {
        c.nack_repeat = (t > Micros::ZERO).then_some(t);
    }
    if let Some(n) = field(config, "inputMaxUnacked") {
        c.input.max_unacked = n as usize;
    }
    c
}

/// The client side of a session's media (one per rtc session). See the module docs for the calling convention.
#[wasm_bindgen]
pub struct ClientMedia {
    inner: Inner,
}

#[wasm_bindgen]
impl ClientMedia {
    /// A new media layer. `config` (every field optional, `undefined`: the defaults): `maxDatagram` (bytes),
    /// `feedbackIntervalMs`, `feedbackIdleMs`, `audioReportIntervalMs`, `nackRepeatMs` (0: NACKs go once),
    /// `inputMaxUnacked`.
    #[wasm_bindgen(constructor)]
    pub fn new(config: JsValue) -> ClientMedia {
        ClientMedia { inner: Inner::new(config_from(&config)) }
    }

    /// The transport's largest datagram now (bytes).
    #[wasm_bindgen(js_name = setMaxDatagram)]
    pub fn set_max_datagram(&mut self, n: u32) {
        self.inner.set_max_datagram(n as usize);
    }

    /// A round-trip sample from the transport (the selected candidate pair's RTT, ~every 100 ms).
    #[wasm_bindgen(js_name = setRtt)]
    pub fn set_rtt(&mut self, now_us: f64, rtt_us: f64) {
        self.inner.set_rtt(us(now_us), us(rtt_us));
    }

    /// Start receiving video stream `stream` (before `video.open` goes: pictures may beat `video.opened`).
    #[wasm_bindgen(js_name = openVideo)]
    pub fn open_video(&mut self, stream: u8) {
        self.inner.open_video(stream);
    }

    #[wasm_bindgen(js_name = closeVideo)]
    pub fn close_video(&mut self, stream: u8) {
        self.inner.close_video(stream);
    }

    /// Whether video stream `stream` is open (by `openVideo`, `openProbe` or an early datagram).
    #[wasm_bindgen(js_name = hasVideo)]
    pub fn has_video(&self, stream: u8) -> bool {
        self.inner.has_video(stream)
    }

    /// Opens `stream` for a speed test (docs/LINK.md「测速」): its frames never become `frame` events — each one is
    /// acknowledged as decoded at once and counted (`probeStats`). `closeVideo` ends it.
    #[wasm_bindgen(js_name = openProbe)]
    pub fn open_probe(&mut self, stream: u8, now_us: f64) {
        self.inner.open_probe(us(now_us), stream);
    }

    /// A speed-test stream's counters (`undefined`: not one): `{frames, bytes, spanUs, meanBps, peakBps, finalBps,
    /// finalFps}` (rates in bits/s; `null` = not enough yet).
    #[wasm_bindgen(js_name = probeStats)]
    pub fn probe_stats(&self, stream: u8, now_us: f64) -> JsValue {
        let Some(p) = self.inner.probe_stats(us(now_us), stream) else { return JsValue::UNDEFINED };
        let o = Object::new();
        let n = |v: Option<u64>| v.map_or(JsValue::NULL, |v| JsValue::from(v as f64));
        set(&o, "frames", p.frames as f64);
        set(&o, "bytes", p.bytes as f64);
        set(&o, "spanUs", p.span_us as f64);
        set(&o, "meanBps", n(p.mean_bps));
        set(&o, "peakBps", n(p.peak_bps));
        set(&o, "finalBps", n(p.final_bps));
        set(&o, "finalFps", p.final_fps.map_or(JsValue::NULL, JsValue::from));
        o.into()
    }

    #[wasm_bindgen(js_name = openAudio)]
    pub fn open_audio(&mut self, stream: u8) {
        self.inner.open_audio(stream);
    }

    #[wasm_bindgen(js_name = closeAudio)]
    pub fn close_audio(&mut self, stream: u8) {
        self.inner.close_audio(stream);
    }

    /// One datagram of channels 1–5 from the server (the `dgram` channel's message). False: malformed or not for
    /// this side (counted in `malformed`).
    #[wasm_bindgen(js_name = onDatagram)]
    pub fn on_datagram(&mut self, bytes: &[u8], now_us: f64) -> bool {
        self.inner.handle_datagram(us(now_us), bytes).is_ok()
    }

    /// The next datagram to send on `dgram`, or `undefined`. Call until `undefined` after every other call.
    #[wasm_bindgen(js_name = pollTransmit)]
    pub fn poll_transmit(&mut self, now_us: f64) -> Option<Vec<u8>> {
        self.inner.poll_transmit(us(now_us))
    }

    /// The next event, or `undefined`:
    /// - `{type: "frame", stream, frame, codec: "h264"|"hevc", kind, width, height, captureUs, recoveryBase,
    ///   firstArrivalUs, deliveredUs, au: Uint8Array}` — decode it, then `frameDecoded`;
    /// - `{type: "audio", stream, seq, timeUs, data: Uint8Array, recovered, gapBefore}`;
    /// - `{type: "cursor", stream, cseq, json: string}`;
    /// - `{type: "inputAcked", through}`, `{type: "inputFailed", seq}`.
    #[wasm_bindgen(js_name = pollEvent)]
    pub fn poll_event(&mut self) -> JsValue {
        let Some(e) = self.inner.poll_event() else { return JsValue::UNDEFINED };
        let o = Object::new();
        match e {
            ClientEvent::Frame(f) => {
                set(&o, "type", "frame");
                set(&o, "stream", f.stream);
                set(&o, "frame", f.frame);
                set(&o, "codec", if f.meta.codec == Codec::Hevc { "hevc" } else { "h264" });
                set(&o, "kind", kind_name(f.meta.kind));
                set(&o, "width", f.meta.width);
                set(&o, "height", f.meta.height);
                set(&o, "captureUs", f.meta.capture_us as f64);
                set(&o, "recoveryBase", f.meta.recovery_base);
                set(&o, "firstArrivalUs", f.first_arrival.0 as f64);
                set(&o, "deliveredUs", f.delivered_at.0 as f64);
                set(&o, "au", Uint8Array::from(&f.au[..]));
            }
            ClientEvent::Audio(p) => {
                set(&o, "type", "audio");
                set(&o, "stream", p.stream);
                set(&o, "seq", p.aseq);
                set(&o, "timeUs", p.time_us as f64);
                set(&o, "data", Uint8Array::from(&p.data[..]));
                set(&o, "recovered", p.recovered);
                set(&o, "gapBefore", p.gap_before);
            }
            ClientEvent::Cursor { stream, cseq, json } => {
                set(&o, "type", "cursor");
                set(&o, "stream", stream);
                set(&o, "cseq", cseq);
                set(&o, "json", String::from_utf8_lossy(&json).into_owned());
            }
            ClientEvent::InputAcked { through } => {
                set(&o, "type", "inputAcked");
                set(&o, "through", through);
            }
            ClientEvent::InputFailed { seq } => {
                set(&o, "type", "inputFailed");
                set(&o, "seq", seq);
            }
        }
        o.into()
    }

    /// When to call `handleTimeout` next (µs on the caller's clock; `undefined`: no timer needed).
    #[wasm_bindgen(js_name = pollTimeout)]
    pub fn poll_timeout(&self, now_us: f64) -> Option<f64> {
        self.inner.poll_timeout(us(now_us)).map(|t| t.0 as f64)
    }

    #[wasm_bindgen(js_name = handleTimeout)]
    pub fn handle_timeout(&mut self, now_us: f64) {
        self.inner.handle_timeout(us(now_us));
    }

    /// Queues an input event (`/input`'s JSON): `move` = a pointer move (newest wins), else discrete (exactly once,
    /// in order). Returns its seq; throws `"overflow"` (too many unacked: answer like HTTP 429) or `"too-large"`.
    #[wasm_bindgen(js_name = sendInput)]
    pub fn send_input(&mut self, now_us: f64, json: &str, r#move: bool) -> Result<u32, JsValue> {
        let kind = if r#move { InputKind::Move } else { InputKind::Discrete };
        self.inner.send_input(us(now_us), kind, json.as_bytes()).map_err(|e| {
            JsValue::from_str(match e {
                InputError::Overflow => "overflow",
                InputError::TooLarge => "too-large",
            })
        })
    }

    /// The decoder's verdict on a delivered frame; `ok = false` asks for a key frame.
    #[wasm_bindgen(js_name = frameDecoded)]
    pub fn frame_decoded(&mut self, stream: u8, frame: u32, ok: bool) {
        self.inner.frame_decoded(stream, frame, ok);
    }

    /// The decoder can't continue: a key frame.
    #[wasm_bindgen(js_name = requestKeyframe)]
    pub fn request_keyframe(&mut self, stream: u8) {
        self.inner.request_keyframe(stream);
    }

    /// Discrete input events waiting for an ack.
    #[wasm_bindgen(js_name = inputUnacked)]
    pub fn input_unacked(&self) -> u32 {
        self.inner.input_unacked() as u32
    }

    /// Datagrams refused as malformed or on a channel this side doesn't receive.
    pub fn malformed(&self) -> f64 {
        self.inner.malformed() as f64
    }

    /// The media layer's counters since the session started (camelCase [`MediaStats`]: `atUs`, `rttMinMs`,
    /// `rttP50Ms`, `rttP90Ms`, `lossPct`, `mediaReceived`, `mediaMissing`, `fecRecovered`, `nackRecovered`, `nackSent`,
    /// `framesDelivered`, `framesLost`, `framesSkipped`, `freezes`, `freezeMs`, `fps`, `inputP50Ms`, `inputP90Ms`,
    /// `inputEvents`, `inputFailed`, `audioLossPct`, `audioLost`, `audioRecovered`; unknown values `null`).
    pub fn stats(&self, now_us: f64) -> JsValue {
        stats_object(&self.inner.stats(us(now_us))).into()
    }

    /// Every frame's fate since the last call (for the playout report's `rx`, the server's per-frame trace):
    /// `[{stream, frame, fate: "delivered"|"skipped"|"lost", kind, au, captureMs, firstMs, lastMs, completeMs,
    /// decidedMs, shards, fec, retx, nacks}]` (ms on the media clock; `captureMs` the sender's wall clock).
    #[wasm_bindgen(js_name = takeRxTraces)]
    pub fn take_rx_traces(&mut self) -> Array {
        self.inner.take_rx_traces().iter().map(|t| JsValue::from(rx_object(t))).collect()
    }
}

fn stats_object(m: &MediaStats) -> Object {
    let o = Object::new();
    set(&o, "atUs", m.at_us as f64);
    set(&o, "rttMinMs", opt_f64(m.rtt_min_ms));
    set(&o, "rttP50Ms", opt_f64(m.rtt_p50_ms));
    set(&o, "rttP90Ms", opt_f64(m.rtt_p90_ms));
    set(&o, "lossPct", opt_f64(m.loss_pct));
    set(&o, "mediaReceived", m.media_received as f64);
    set(&o, "mediaMissing", m.media_missing as f64);
    set(&o, "fecRecovered", m.fec_recovered as f64);
    set(&o, "nackRecovered", m.nack_recovered as f64);
    set(&o, "nackSent", m.nack_sent as f64);
    set(&o, "framesDelivered", m.frames_delivered as f64);
    set(&o, "framesLost", m.frames_lost as f64);
    set(&o, "framesSkipped", m.frames_skipped as f64);
    set(&o, "freezes", m.freezes as f64);
    set(&o, "freezeMs", m.freeze_ms as f64);
    set(&o, "fps", opt_f64(m.fps));
    set(&o, "inputP50Ms", opt_f64(m.input_p50_ms));
    set(&o, "inputP90Ms", opt_f64(m.input_p90_ms));
    set(&o, "inputEvents", m.input_events as f64);
    set(&o, "inputFailed", m.input_failed as f64);
    set(&o, "audioLossPct", opt_f64(m.audio_loss_pct));
    set(&o, "audioLost", m.audio_lost as f64);
    set(&o, "audioRecovered", m.audio_recovered as f64);
    o
}

fn rx_object(t: &RxTrace) -> Object {
    let ms = |v: Option<Micros>| opt_f64(v.map(|v| v.0 as f64 / 1000.0));
    let o = Object::new();
    set(&o, "stream", t.stream);
    set(&o, "frame", t.frame);
    set(
        &o,
        "fate",
        match t.fate {
            RxFate::Delivered => "delivered",
            RxFate::Skipped => "skipped",
            RxFate::Lost => "lost",
        },
    );
    set(&o, "kind", t.kind.map_or(JsValue::NULL, JsValue::from));
    set(&o, "au", t.au_bytes);
    set(&o, "captureMs", opt_f64(t.capture_us.map(|v| v as f64 / 1000.0)));
    set(&o, "firstMs", ms(t.first_arrival));
    set(&o, "lastMs", ms(t.last_arrival));
    set(&o, "completeMs", ms(t.completed_at));
    set(&o, "decidedMs", t.decided_at.0 as f64 / 1000.0);
    set(&o, "shards", t.shards);
    set(&o, "fec", t.fec);
    set(&o, "retx", t.retx);
    set(&o, "nacks", t.nack_items);
    o
}
