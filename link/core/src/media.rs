//! The media layer (`uu-link-media`) inside a session: one `ServerMedia` (computer) or `ClientMedia` (phone) per
//! session, owning datagram channels 1–5. The session's driver task runs its loop: datagrams from the peer in,
//! `poll_transmit` out to the QUIC datagram queue, events to the app, one timer. App calls (`send_frame`,
//! `send_input`, `frame_decoded`, …) take the lock, call, and wake the driver.

use std::{
    sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use tokio::sync::{Notify, mpsc};
pub use uu_link_media::{
    AudioPacket, ClientConfig, ClientEvent, ClientMedia, Codec, FrameKind, FrameMeta, InputEvent, InputKind, Micros,
    NetworkProfile, ReceivedFrame, RxFate, RxTrace, SendGate, ServerConfig, ServerEvent, ServerMedia, TxTrace,
};

use crate::{datagram, error::LinkError, path::Iface, path::PathKind, probe, stats::MediaStats, transport::Conn};

/// The media layer's own stats type (the `link:` line's intervals are made from two of them).
pub(crate) type RawMediaStats = uu_link_media::MediaStats;

/// The datagram send buffer of either transport (QUIC: the endpoint's transport config; `rtc`: the session's own
/// queue plus what SCTP holds): queued bytes = this − free space.
pub(crate) const SEND_BUFFER: usize = 1 << 20;

pub(crate) enum Engine {
    Server(Box<ServerMedia>),
    Client(Box<ClientMedia>),
}

pub(crate) struct Driver {
    engine: Mutex<Engine>,
    epoch: Instant,
    pub(crate) wake: Notify,
    server_tx: mpsc::UnboundedSender<ServerEvent>,
    pub(crate) server_rx: tokio::sync::Mutex<mpsc::UnboundedReceiver<ServerEvent>>,
    client_tx: mpsc::UnboundedSender<ClientEvent>,
    pub(crate) client_rx: tokio::sync::Mutex<mpsc::UnboundedReceiver<ClientEvent>>,
    /// Media flowed (a stream opened, a frame / input / datagram): the `link:` line gets the media fields.
    used: AtomicBool,
    /// The speed test running on this session (docs/LINK.md「测速」). Lock order: the engine, then this.
    pub(crate) probe: Mutex<Option<probe::Slot>>,
}

impl Driver {
    pub(crate) fn new(engine: Engine) -> Driver {
        let (server_tx, server_rx) = mpsc::unbounded_channel();
        let (client_tx, client_rx) = mpsc::unbounded_channel();
        Driver {
            engine: Mutex::new(engine),
            epoch: Instant::now(),
            wake: Notify::new(),
            server_tx,
            server_rx: tokio::sync::Mutex::new(server_rx),
            client_tx,
            client_rx: tokio::sync::Mutex::new(client_rx),
            used: AtomicBool::new(false),
            probe: Mutex::new(None),
        }
    }

    pub(crate) fn now(&self) -> Micros {
        Micros(self.epoch.elapsed().as_micros() as u64)
    }

    fn instant(&self, t: Micros) -> Instant {
        self.epoch + Duration::from_micros(t.0)
    }

    /// Runs `f` on the engine, then wakes the driver (there may be datagrams or events now).
    pub(crate) fn with<R>(&self, f: impl FnOnce(&mut Engine, Micros) -> R) -> R {
        let now = self.now();
        let r = f(&mut self.engine.lock().unwrap(), now);
        self.wake.notify_one();
        r
    }

    pub(crate) fn server<R>(&self, f: impl FnOnce(&mut ServerMedia, Micros) -> R) -> Result<R, LinkError> {
        self.used.store(true, Ordering::Relaxed);
        self.with(|e, now| match e {
            Engine::Server(s) => Ok(f(s, now)),
            Engine::Client(_) => Err(LinkError::InvalidArgument("a server-side media call on a client session".into())),
        })
    }

    pub(crate) fn client<R>(&self, f: impl FnOnce(&mut ClientMedia, Micros) -> R) -> Result<R, LinkError> {
        self.used.store(true, Ordering::Relaxed);
        self.with(|e, now| match e {
            Engine::Client(c) => Ok(f(c, now)),
            Engine::Server(_) => Err(LinkError::InvalidArgument("a client-side media call on a server session".into())),
        })
    }

    /// A datagram of channels 1–5 from the peer. False when the engine refused it (malformed / wrong channel).
    pub(crate) fn handle_datagram(&self, d: &[u8]) -> bool {
        self.used.store(true, Ordering::Relaxed);
        self.with(|e, now| match e {
            Engine::Server(s) => s.handle_datagram(now, d).is_ok(),
            Engine::Client(c) => c.handle_datagram(now, d).is_ok(),
        })
    }

    pub(crate) fn set_transport(&self, rtt: Option<Duration>, max_datagram: usize) {
        let mut e = self.engine.lock().unwrap();
        let now = self.now();
        let rtt = rtt.map(|r| Micros(r.as_micros() as u64));
        match &mut *e {
            Engine::Server(s) => {
                if let Some(r) = rtt {
                    s.set_rtt(now, r);
                }
                s.set_max_datagram(max_datagram);
            }
            Engine::Client(c) => {
                if let Some(r) = rtt {
                    c.set_rtt(now, r);
                }
                c.set_max_datagram(max_datagram);
            }
        }
    }

    /// The client's network as the rate rules see it (server side, from the client's `link.stats`).
    pub(crate) fn set_network(&self, path: PathKind, iface: Iface) {
        let profile = match (path, iface) {
            (PathKind::Lan, _) => NetworkProfile::Lan,
            (_, Iface::Cellular) => NetworkProfile::Cellular,
            _ => NetworkProfile::Default,
        };
        self.with(|e, now| {
            if let Engine::Server(s) = e {
                s.set_network(now, profile);
            }
        });
    }

    pub(crate) fn on_persistent_congestion(&self) {
        self.with(|e, now| {
            if let Engine::Server(s) = e {
                s.on_persistent_congestion(now);
            }
        });
    }

    /// The media half of the stats (None until media flowed): counters since the session started.
    pub(crate) fn stats(&self) -> Option<MediaStats> {
        self.raw_stats().map(|m| Self::convert(&m))
    }

    /// The media half of the stats over the interval since `previous` (counters, fps and the sent rate as the
    /// interval's), and `previous` moved to now: the periodic `link:` lines. The first call covers the session so far
    /// (since the media clock's zero, the driver's start).
    pub(crate) fn interval_stats(&self, previous: &mut Option<uu_link_media::MediaStats>) -> Option<MediaStats> {
        let now = self.raw_stats()?;
        let m = now.since(previous.as_ref().unwrap_or(&uu_link_media::MediaStats::default()));
        *previous = Some(now);
        Some(Self::convert(&m))
    }

    /// The media layer's counters now (marks media as used: the speed test reads them before anything flowed).
    pub(crate) fn raw_stats_now(&self) -> Option<uu_link_media::MediaStats> {
        self.used.store(true, Ordering::Relaxed);
        self.raw_stats()
    }

    fn raw_stats(&self) -> Option<uu_link_media::MediaStats> {
        if !self.used.load(Ordering::Relaxed) {
            return None;
        }
        let mut e = self.engine.lock().unwrap();
        let now = self.now();
        Some(match &mut *e {
            Engine::Server(s) => s.stats(now),
            Engine::Client(c) => c.stats(now),
        })
    }

    fn convert(m: &uu_link_media::MediaStats) -> MediaStats {
        let mbps = |b: Option<u64>| b.map(|b| b as f64 / 1e6);
        MediaStats {
            loss_pct: m.loss_pct,
            media_received: Some(m.media_received),
            media_missing: Some(m.media_missing),
            fec_recovered: Some(m.fec_recovered),
            nack_recovered: Some(m.nack_recovered),
            nack_sent: Some(m.nack_sent),
            lost_frames: Some(m.frames_lost),
            skipped_frames: Some(m.frames_skipped),
            freeze_count: Some(m.freezes),
            freeze_ms: Some(m.freeze_ms),
            rate_target_mbps: mbps(m.target_bps),
            rate_sent_mbps: mbps(m.sent_bps),
            rate_cuts: m.target_bps.map(|_| m.rate_cuts),
            rate_loss_cuts: m.target_bps.map(|_| m.rate_loss_cuts),
            jitter_ms: m.jitter_ms,
            fps: m.fps,
            input_p50_ms: m.input_p50_ms,
            input_p90_ms: m.input_p90_ms,
            input_n: Some(m.input_events),
            audio_loss_pct: m.audio_loss_pct,
            audio_red: m.redundancy.map(u32::from),
        }
    }
}

/// The driver loop, until the connection ends.
pub(crate) async fn run(d: &Driver, conn: &Conn, sent: &datagram::Counters) {
    let closed = conn.closed();
    tokio::pin!(closed);
    loop {
        let (out, timeout) = {
            let mut e = d.engine.lock().unwrap();
            let now = d.now();
            let mut out = Vec::new();
            match &mut *e {
                Engine::Server(s) => {
                    while let Some(x) = s.poll_transmit(now) {
                        out.push(x);
                    }
                    while let Some(ev) = s.poll_event() {
                        // a speed test's stream stays in the session: a loss makes its next filler a key frame
                        if let Some(p) = d.probe.lock().unwrap().as_mut() {
                            match ev {
                                ServerEvent::FrameDelivered { stream, .. } if stream == p.stream => continue,
                                ServerEvent::RecoveryNeeded { stream, .. } | ServerEvent::KeyframeNeeded { stream }
                                    if stream == p.stream =>
                                {
                                    p.key = true;
                                    continue;
                                }
                                _ => {}
                            }
                        }
                        let _ = d.server_tx.send(ev);
                    }
                }
                Engine::Client(c) => {
                    while let Some(x) = c.poll_transmit(now) {
                        out.push(x);
                    }
                    while let Some(ev) = c.poll_event() {
                        let _ = d.client_tx.send(ev);
                    }
                }
            }
            let t = match &*e {
                Engine::Server(s) => s.poll_timeout(now),
                Engine::Client(c) => c.poll_timeout(now),
            };
            // everything queued went out above: a timer at or before now would only spin
            (out, t.map(|t| t.max(now + Micros(1000))))
        };
        for x in out {
            if conn.datagram_send_buffer_space() < x.len() {
                sent.drop_one();
            }
            match conn.send_datagram(x.into()) {
                Ok(()) => {
                    sent.sent.fetch_add(1, Ordering::Relaxed);
                }
                Err(_) => sent.drop_one(),
            }
        }
        let deadline = timeout.map(|t| tokio::time::Instant::from_std(d.instant(t)));
        tokio::select! {
            _ = &mut closed => break,
            _ = d.wake.notified() => {}
            _ = async { tokio::time::sleep_until(deadline.unwrap()).await }, if deadline.is_some() => {
                let mut e = d.engine.lock().unwrap();
                let now = d.now();
                match &mut *e {
                    Engine::Server(s) => s.handle_timeout(now),
                    Engine::Client(c) => c.handle_timeout(now),
                }
            }
        }
    }
}
