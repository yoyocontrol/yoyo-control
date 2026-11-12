//! The media layer (`uu-link-media`) inside a session: one `ServerMedia` (computer) or `ClientMedia` (phone) per
//! session, owning datagram channels 1–5. The session's driver task runs its loop: datagrams from the peer in,
//! `poll_transmit` out to the QUIC datagram queue, events to the app, one timer. App calls (`send_frame`,
//! `send_input`, `frame_decoded`, …) take the lock, call, and wake the driver.

use std::{
    sync::{
        Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
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
    /// When the server's engine last got a round-trip floor (the driver's clock, µs).
    floor_at: AtomicU64,
    /// A test's clock ([`TEST_CLOCK`]).
    slew: Option<Slew>,
}

/// A test hook (docs/LINK.md「测试工具」): `UU_LINK_TEST_CLOCK=4:1.07,8:1.04,3:0.98` runs the media clock of every
/// session of this process at those rates for that many seconds each, in turn and over again — a virtual machine's
/// clock being slewed, which the other side's rate controller has to tell from a queue.
const TEST_CLOCK: &str = "UU_LINK_TEST_CLOCK";

/// `(seconds, rate)` stretches, repeated.
struct Slew(Vec<(f64, f64)>);

impl Slew {
    fn from_env() -> Option<Slew> {
        let v = std::env::var(TEST_CLOCK).ok()?;
        let stretches: Vec<(f64, f64)> = v
            .split(',')
            .filter_map(|s| {
                let (len, rate) = s.split_once(':')?;
                Some((len.trim().parse().ok()?, rate.trim().parse().ok()?))
            })
            .filter(|&(len, rate): &(f64, f64)| len > 0.0 && rate > 0.1 && rate < 10.0)
            .collect();
        (!stretches.is_empty()).then_some(Slew(stretches))
    }

    /// The clock's time after `real` seconds.
    fn at(&self, real: f64) -> f64 {
        let (cycle, cycle_clock) = self.0.iter().fold((0.0, 0.0), |a, s| (a.0 + s.0, a.1 + s.0 * s.1));
        let mut left = real % cycle;
        let mut t = (real / cycle).floor() * cycle_clock;
        for &(len, rate) in &self.0 {
            t += left.min(len) * rate;
            left -= left.min(len);
        }
        t
    }
}

/// The transport's ack round trips go to the server's engine as the lowest of a stretch at least this long (a
/// delayed ack is rarely the only one in 20 ms of traffic).
const RTT_FLOOR_EVERY: Micros = Micros::from_millis(20);

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
            floor_at: AtomicU64::new(0),
            slew: Slew::from_env(),
        }
    }

    pub(crate) fn now(&self) -> Micros {
        let real = self.epoch.elapsed();
        match &self.slew {
            Some(s) => Micros((s.at(real.as_secs_f64()) * 1e6) as u64),
            None => Micros(real.as_micros() as u64),
        }
    }

    fn instant(&self, t: Micros) -> Instant {
        match &self.slew {
            // early rather than late (the loop asks again): the fastest rate a test may give
            Some(_) => Instant::now() + Duration::from_micros(t.0.saturating_sub(self.now().0) / 10),
            None => self.epoch + Duration::from_micros(t.0),
        }
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
    /// `rtt_floor`: the transport's lowest ack round trip since it was last taken (QUIC's; asked for when a floor is
    /// due, `RTT_FLOOR_EVERY`) — given to the server's engine first, so the feedback in `d` is read with it.
    pub(crate) fn handle_datagram(&self, d: &[u8], rtt_floor: impl FnOnce() -> Option<Duration>) -> bool {
        self.used.store(true, Ordering::Relaxed);
        self.with(|e, now| match e {
            Engine::Server(s) => {
                let last = self.floor_at.load(Ordering::Relaxed);
                if now.0 >= last + RTT_FLOOR_EVERY.0
                    && let Some(f) = rtt_floor()
                {
                    self.floor_at.store(now.0, Ordering::Relaxed);
                    s.set_rtt_floor(now, Micros(f.as_micros() as u64));
                }
                s.handle_datagram(now, d).is_ok()
            }
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
