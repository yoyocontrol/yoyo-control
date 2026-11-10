//! The speed test (docs/LINK.md「测速」): how much picture this session's path carries, measured the way a picture
//! goes. The client opens a probe stream in its media layer and asks with the control message `link.probe`; the
//! server's session (not the app) sends filler frames on it for the asked time — each one a frame budget at the
//! encoder rate the rate control gives, only when the send gate is open, a key frame first and after every loss —
//! so FEC, NACK, pacing, the frame-rate cap and the rate control's climb all run as with a busy screen. The client's
//! media layer acknowledges them as decoded and counts them; at the end the server reports its side
//! (`link.probe.done`) and the client puts both into a [`ProbeReport`].

use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use serde::Serialize;
use serde_json::{Map, Value, json};
use tokio::sync::{Notify, mpsc};

use crate::{
    error::{LinkError, Result},
    log::info,
    media::{Codec, FrameKind, FrameMeta, SEND_BUFFER},
    path::{Iface, PathKind},
    session::{Inner, Side},
    stats::RttWindow,
    transport::Transport,
};

/// A test runs this long unless asked otherwise: the rate control's startup climb (+50 %/s from 3.5 Mbps) reaches
/// the 20 Mbps ceiling in about 4.5 s, and the last 2 s show where it settled.
pub const DEFAULT_DURATION: Duration = Duration::from_secs(8);
/// The server keeps `ms` within these.
const MIN_MS: u64 = 1000;
const MAX_MS: u64 = 20_000;
/// The filler's frame clock: a 60 Hz screen.
const TICK: Duration = Duration::from_micros(16_667);
/// A filler frame is at least this (a frame of a still screen) and at most this.
const MIN_FRAME: usize = 1000;
const MAX_FRAME: usize = 1 << 20;
/// The client gives up when `link.probe.started` hasn't come in this long (a server without the speed test hands
/// the message to its app, which ignores it).
const START_TIMEOUT: Duration = Duration::from_secs(3);
/// … and when `link.probe.done` is this late.
const DONE_GRACE: Duration = Duration::from_secs(5);
/// The client samples the path's RTT this often while the test runs.
const RTT_EVERY: Duration = Duration::from_millis(100);

/// The probe running on a session (at most one), kept by the media driver: the server's media events of its stream
/// stay in the session (a loss asks for the next filler to be a key frame).
pub(crate) struct Slot {
    pub stream: u8,
    pub key: bool,
    pub stop: Arc<Notify>,
}

/// The speed test's result (client side). Rates in Mbit/s, times in ms; `None` = not measured.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProbeReport {
    pub transport: Transport,
    pub path: PathKind,
    pub iface: Iface,
    /// How long the server sent.
    pub duration_ms: u64,
    /// The path's RTT before the test: the lowest of the last 10 s (the idle path).
    pub rtt_idle_ms: Option<f64>,
    /// The path's RTT while the test ran (under load): median and 90th percentile.
    pub rtt_p50_ms: Option<f64>,
    pub rtt_p90_ms: Option<f64>,
    /// Frames delivered, and their payload rate: over the whole test, the best second, the last two seconds.
    pub frames: u64,
    pub received_mbps: Option<f64>,
    pub peak_mbps: Option<f64>,
    pub final_mbps: Option<f64>,
    /// Frames per second over the last two seconds (the frame-rate cap follows the rate).
    pub final_fps: Option<f64>,
    /// Media datagrams lost before FEC (%), and what FEC / NACK got back.
    pub loss_pct: Option<f64>,
    pub fec_recovered: u64,
    pub nack_recovered: u64,
    /// Frames lost, skipped, and the freezes they made.
    pub lost_frames: u64,
    pub skipped_frames: u64,
    pub freezes: u64,
    pub freeze_ms: u64,
    /// The server's side (None: its `link.probe.done` didn't come).
    pub server: Option<ProbeServerReport>,
}

/// The server's half of the report (`link.probe.done`).
#[derive(Clone, Debug, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProbeServerReport {
    /// The rate control's target at the end, and the highest it reached.
    pub target_mbps: f64,
    pub max_target_mbps: f64,
    /// The encoder rate at the end (what a picture's encoder would get), and the frame-rate cap at that rate.
    pub encoder_mbps: f64,
    pub fps_cap: f64,
    /// What the server sent (everything on the wire: FEC, retransmits), and the filler payload.
    pub sent_mbps: Option<f64>,
    pub frames: u64,
    pub bytes: u64,
    /// Rate decreases: delay-based, loss-based.
    pub rate_cuts: u64,
    pub rate_loss_cuts: u64,
    pub retransmits: u64,
    /// The one-way delay jitter the rate control measured (ms).
    pub jitter_ms: Option<f64>,
    /// "done" (ran its time), "stopped" (the client asked).
    pub reason: String,
}

impl ProbeServerReport {
    fn from_message(m: &Map<String, Value>) -> ProbeServerReport {
        let f = |k: &str| m.get(k).and_then(Value::as_f64);
        let u = |k: &str| m.get(k).and_then(Value::as_u64).unwrap_or(0);
        ProbeServerReport {
            target_mbps: f("targetMbps").unwrap_or(0.0),
            max_target_mbps: f("maxTargetMbps").unwrap_or(0.0),
            encoder_mbps: f("encoderMbps").unwrap_or(0.0),
            fps_cap: f("fpsCap").unwrap_or(0.0),
            sent_mbps: f("sentMbps"),
            frames: u("frames"),
            bytes: u("bytes"),
            rate_cuts: u("rateCuts"),
            rate_loss_cuts: u("rateLossCuts"),
            retransmits: u("retransmits"),
            jitter_ms: f("jitterMs"),
            reason: m.get("reason").and_then(Value::as_str).unwrap_or("done").to_string(),
        }
    }
}

fn mbps(bps: u64) -> f64 {
    (bps as f64 / 1e4).round() / 100.0
}

fn wall_us() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_micros() as u64).unwrap_or(0)
}

// MARK: server

/// `link.probe` from the client (server side): start sending, or answer `link.probe.error`.
pub(crate) fn serve(s: Arc<Inner>, m: Map<String, Value>) {
    let id = m.get("id").cloned().unwrap_or(Value::Null);
    let ms = m.get("ms").and_then(Value::as_u64).unwrap_or(DEFAULT_DURATION.as_millis() as u64).clamp(MIN_MS, MAX_MS);
    let stream = m.get("stream").and_then(Value::as_u64).filter(|n| (1..=255).contains(n)).map(|n| n as u8);
    let stop = Arc::new(Notify::new());
    let claimed: std::result::Result<u8, &str> = match stream {
        None => Err("stream must be 1–255"),
        Some(stream) => s
            .media
            .server(|sm, _| {
                // engine, then the slot: the driver's order
                let mut slot = s.media.probe.lock().unwrap();
                if slot.is_some() {
                    Err("a speed test is running")
                } else if sm.has_video(stream) {
                    Err("that stream is open")
                } else {
                    sm.open_video(stream);
                    *slot = Some(Slot { stream, key: true, stop: stop.clone() });
                    Ok(stream)
                }
            })
            .unwrap_or(Err("not a server session")),
    };
    match claimed {
        Ok(stream) => {
            tokio::spawn(send_filler(s, id, stream, Duration::from_millis(ms), stop));
        }
        Err(message) => {
            let msg = json!({"t": "link.probe.error", "id": id, "message": message});
            tokio::spawn(async move { s.write_control(&msg).await });
        }
    }
}

/// `link.probe.stop` (server side): end the running test now.
pub(crate) fn stop(s: &Inner) {
    if let Some(slot) = s.media.probe.lock().unwrap().as_ref() {
        slot.stop.notify_one();
    }
}

async fn send_filler(s: Arc<Inner>, id: Value, stream: u8, duration: Duration, stop: Arc<Notify>) {
    let _ = s
        .write_control(
            &json!({"t": "link.probe.started", "id": id, "stream": stream, "ms": duration.as_millis() as u64}),
        )
        .await;
    info!("link probe for {}: {} ms on stream {stream}", s.peer_name(), duration.as_millis());
    let before = s.media.raw_stats_now();
    let zeros = vec![0u8; MAX_FRAME];
    let started = Instant::now();
    let deadline = tokio::time::Instant::from_std(started + duration);
    let mut tick = tokio::time::interval(TICK);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let (mut frames, mut bytes, mut max_target) = (0u64, 0u64, 0u64);
    let closed = s.conn.closed();
    tokio::pin!(closed);
    let stopped = stop.notified();
    tokio::pin!(stopped);
    let (reason, gone) = loop {
        tokio::select! {
            _ = &mut closed => break ("closed", true),
            _ = &mut stopped => break ("stopped", false),
            _ = tokio::time::sleep_until(deadline) => break ("done", false),
            _ = tick.tick() => {}
        }
        let space = s.conn.datagram_send_buffer_space();
        let queued = SEND_BUFFER.saturating_sub(space);
        let sent = s.media.server(|sm, now| {
            let gate = sm.send_gate(now, stream, queued, Some(space))?;
            max_target = max_target.max(gate.target_bps);
            if !gate.open {
                return None;
            }
            let enc = sm.encoder_target_bps().unwrap_or(gate.target_bps);
            let cap = sm.frame_rate_cap(stream).unwrap_or(60.0).max(1.0);
            let size = ((enc as f64 / 8.0 / cap) as usize).clamp(MIN_FRAME, MAX_FRAME);
            let mut slot = s.media.probe.lock().unwrap();
            let key = slot.as_ref().is_some_and(|p| p.key);
            let meta = FrameMeta {
                codec: Codec::H264,
                kind: if key { FrameKind::Key } else { FrameKind::Delta },
                width: 0,
                height: 0,
                capture_us: wall_us(),
                recovery_base: 0,
                au_len: 0,
            };
            let ok = sm.send_frame(now, stream, meta, &zeros[..size]).is_ok();
            if ok && let Some(p) = slot.as_mut() {
                p.key = false;
            }
            ok.then_some(size)
        });
        if let Ok(Some(size)) = sent {
            frames += 1;
            bytes += size as u64;
        }
    };
    // the stream's counters go with it: read them first
    let after = s.media.raw_stats_now();
    let end = s
        .media
        .server(|sm, _| {
            let enc = sm.encoder_target_bps().unwrap_or(0);
            let cap = sm.frame_rate_cap(stream).unwrap_or(0.0);
            sm.close_video(stream);
            *s.media.probe.lock().unwrap() = None;
            (enc, cap)
        })
        .unwrap_or((0, 0.0));
    let elapsed = started.elapsed();
    let (before, after) = (before.unwrap_or_default(), after.unwrap_or_default());
    let d = after.since(&before);
    let target = after.target_bps.unwrap_or(0);
    let msg = json!({
        "t": "link.probe.done",
        "id": id,
        "stream": stream,
        "ms": elapsed.as_millis() as u64,
        "reason": reason,
        "frames": frames,
        "bytes": bytes,
        "targetMbps": mbps(target),
        "maxTargetMbps": mbps(max_target.max(target)),
        "encoderMbps": mbps(end.0),
        "fpsCap": end.1,
        "sentMbps": d.sent_bps.map(mbps),
        "rateCuts": d.rate_cuts,
        "rateLossCuts": d.rate_loss_cuts,
        "retransmits": d.retransmits,
        "jitterMs": after.jitter_ms,
    });
    info!(
        "link probe for {} {reason} after {} ms: {frames} frames, {:.1} MB, target {:.1} (max {:.1}) Mbps, cuts {}/{}",
        s.peer_name(),
        elapsed.as_millis(),
        bytes as f64 / 1e6,
        mbps(target),
        mbps(max_target.max(target)),
        d.rate_cuts,
        d.rate_loss_cuts
    );
    if !gone {
        let _ = s.write_control(&msg).await;
    }
}

// MARK: client

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// The client's hold on its test: on drop (done, failed or cancelled) the stream closes, the waiter goes, and a
/// test still running on the server is stopped.
struct Running {
    s: Arc<Inner>,
    id: u64,
    stream: u8,
    finished: bool,
}

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.s.media.client(|c, _| c.close_video(self.stream));
        self.s.probe_waiter.lock().unwrap().take();
        if !self.finished && !self.s.conn.is_closed() {
            let s = self.s.clone();
            let msg = json!({"t": "link.probe.stop", "id": self.id});
            tokio::spawn(async move { s.write_control(&msg).await });
        }
    }
}

/// The client side of a test of `duration` (clamped by the server to 1–20 s).
pub(crate) async fn run(s: &Arc<Inner>, duration: Duration) -> Result<ProbeReport> {
    if s.side != Side::Client {
        return Err(LinkError::InvalidArgument("the speed test runs from the client".into()));
    }
    let (tx, mut rx) = mpsc::unbounded_channel::<Map<String, Value>>();
    {
        let mut w = s.probe_waiter.lock().unwrap();
        if w.is_some() {
            return Err(LinkError::InvalidArgument("a speed test is running".into()));
        }
        *w = Some(tx);
    }
    let rtt_idle_ms = s.rtt_summary().map(|r| r.0);
    let opened = s.media.client(|c, now| {
        let stream = (1..=255u8).rev().find(|n| !c.has_video(*n))?;
        c.open_probe(now, stream);
        Some(stream)
    });
    let Ok(Some(stream)) = opened else {
        s.probe_waiter.lock().unwrap().take();
        return Err(LinkError::InvalidArgument("no free video stream".into()));
    };
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let mut running = Running { s: s.clone(), id, stream, finished: false };
    let before = s.media.raw_stats_now().unwrap_or_default();
    let ms = duration.as_millis() as u64;
    s.write_control(&json!({"t": "link.probe", "id": id, "stream": stream, "ms": ms})).await?;

    let reply = |m: &Map<String, Value>| m.get("id").and_then(Value::as_u64) == Some(id);
    // started (or an error)
    let started = tokio::time::timeout(START_TIMEOUT, async {
        while let Some(m) = rx.recv().await {
            if !reply(&m) {
                continue;
            }
            match m.get("t").and_then(Value::as_str) {
                Some("link.probe.started") => return Ok(m.get("ms").and_then(Value::as_u64).unwrap_or(ms)),
                Some("link.probe.error") => {
                    let message = m.get("message").and_then(Value::as_str).unwrap_or("refused");
                    return Err(LinkError::Media(format!("speed test: {message}")));
                }
                _ => {}
            }
        }
        Err(LinkError::Closed("the session ended".into()))
    })
    .await
    .map_err(|_| LinkError::Timeout("the computer doesn't answer the speed test (an older version?)".into()))??;

    // until done, sampling the RTT
    let mut rtts = RttWindow::new(Duration::from_secs(60));
    let mut tick = tokio::time::interval(RTT_EVERY);
    let wait = tokio::time::sleep(Duration::from_millis(started) + DONE_GRACE);
    tokio::pin!(wait);
    let closed = s.conn.closed();
    tokio::pin!(closed);
    let done: Option<Map<String, Value>> = loop {
        tokio::select! {
            _ = &mut wait => break None,
            _ = &mut closed => return Err(LinkError::Closed("the session ended during the speed test".into())),
            m = rx.recv() => match m {
                Some(m) if reply(&m) && m.get("t").and_then(Value::as_str) == Some("link.probe.done") => break Some(m),
                Some(_) => {}
                None => return Err(LinkError::Closed("the session ended during the speed test".into())),
            },
            _ = tick.tick() => {
                if let Some(r) = s.conn.rtt() {
                    rtts.push(Instant::now(), r);
                }
            }
        }
    };
    running.finished = done.is_some();
    let after = s.media.raw_stats_now().unwrap_or_default();
    let rx_stats = s.media.client(|c, now| c.probe_stats(now, stream)).ok().flatten().unwrap_or_default();
    let d = after.since(&before);
    let loaded = rtts.summary_opt();
    let path = s.path();
    let report = ProbeReport {
        transport: s.conn.transport(),
        path: path.kind,
        iface: *s.iface.lock().unwrap(),
        duration_ms: done.as_ref().and_then(|m| m.get("ms").and_then(Value::as_u64)).unwrap_or(started),
        rtt_idle_ms,
        rtt_p50_ms: loaded.map(|r| r.1),
        rtt_p90_ms: loaded.map(|r| r.2),
        frames: rx_stats.frames,
        received_mbps: rx_stats.mean_bps.map(mbps),
        peak_mbps: rx_stats.peak_bps.map(mbps),
        final_mbps: rx_stats.final_bps.map(mbps),
        final_fps: rx_stats.final_fps.map(|f| (f * 10.0).round() / 10.0),
        loss_pct: d.loss_pct.map(|l| (l * 100.0).round() / 100.0),
        fec_recovered: d.fec_recovered,
        nack_recovered: d.nack_recovered,
        lost_frames: d.frames_lost,
        skipped_frames: d.frames_skipped,
        freezes: d.freezes,
        freeze_ms: d.freeze_ms,
        server: done.as_ref().map(ProbeServerReport::from_message),
    };
    drop(running);
    Ok(report)
}

/// A client-side `link.probe.*` reply: to the waiting test, if any.
pub(crate) fn deliver(waiter: &Mutex<Option<mpsc::UnboundedSender<Map<String, Value>>>>, m: Map<String, Value>) {
    if let Some(tx) = waiter.lock().unwrap().as_ref() {
        let _ = tx.send(m);
    }
}
