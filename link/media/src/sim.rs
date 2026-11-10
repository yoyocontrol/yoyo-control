//! Deterministic network simulator (LINK.md §5.7): a seeded link model, a QUIC-like paced sender queue and
//! synthetic screen content, driving a [`ServerMedia`] ↔ [`ClientMedia`] pair through video, audio, cursor and
//! input. Same seed, same result.
//!
//! [`run`] plays one [`Scenario`] and returns a [`Report`]; `tests/sim.rs` asserts the acceptance targets and
//! prints one row per profile (`cargo test --release --test sim -- --nocapture`).
//!
//! How the spec's profiles are read:
//! - Delays are one way, the same profile in both directions (each its own random stream).
//! - Jitter is extra delay in `[0, jitter]`: a slow part (a third, between random knots every 200 ms) plus
//!   per-packet noise, order kept except for explicit reordering — cellular delay wanders and packets bunch,
//!   they don't overtake each other by 15 ms.
//! - Bursts are fades in time (everything sent during one is lost): `5g` has 0.16 fades/s of 5–20 ms (≈ 0.2 % of
//!   the time, i.e. bursts of 5–20 packets at ~1 packet/ms); per-packet bursts would make the sparse uplink lose
//!   100 ms at a time. `5g-harsh` reads "0.2 %" as 0.2 % of packets *starting* a burst (1.6 fades/s); it is
//!   reported, not asserted. `bad` has 30 ms fades 1 % of the time.
//! - `handover` is `5g` with the blackout 16 s in, while scrolling, so it costs frames.
//! - The sender side models the QUIC datagram path: a FIFO paced at `1.25 × cwnd / srtt` with
//!   `cwnd = max(2 × target × srtt, 16 × MTU)` and bytes in flight ≤ cwnd; `can_send_frame` sees its backlog.
//! - The input target's "base" is the one-way propagation delay (35 ms on `5g`).

use std::cmp::Reverse;
use std::collections::{BTreeMap, BinaryHeap, VecDeque};

use crate::client::{ClientConfig, ClientEvent, ClientMedia};
use crate::rate::NetworkProfile;
use crate::server::{ServerConfig, ServerEvent, ServerMedia};
use crate::stats::percentile;
use crate::time::Micros;
use crate::wire::{Codec, FrameKind, FrameMeta, InputKind};

/// SplitMix64: small, fast, deterministic.
#[derive(Clone, Debug)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed ^ 0x9E37_79B9_7F4A_7C15)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    pub fn f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }

    pub fn chance(&mut self, p: f64) -> bool {
        self.f64() < p
    }

    /// Uniform in [lo, hi].
    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.f64()
    }

    /// Exponential with this mean.
    pub fn exp(&mut self, mean: f64) -> f64 {
        -mean * (1.0 - self.f64()).max(1e-12).ln()
    }
}

/// One direction of a simulated path.
#[derive(Clone, Debug)]
pub struct LinkProfile {
    pub name: &'static str,
    /// One-way propagation delay.
    pub delay: Micros,
    /// Extra delay in `[0, jitter]`: a slow component (a third, interpolated between random knots every 200 ms)
    /// plus per-packet noise (two thirds). Order is kept (FIFO) except for `reorder`.
    pub jitter: Micros,
    /// Random loss per packet.
    pub loss: f64,
    /// Burst loss as fades: starts per second, and each fade's duration range. Everything sent during a fade is
    /// lost.
    pub fades_per_s: f64,
    pub fade: (Micros, Micros),
    /// Stalls (cellular scheduling): starts per second and each one's duration range. Nothing is lost; what is
    /// sent during one is held until it ends (an RTT spike, packets then arrive together).
    pub stalls_per_s: f64,
    pub stall: (Micros, Micros),
    /// Bottleneck rate (bits/s) with a FIFO queue of at most `queue` delay (tail drop).
    pub rate_bps: Option<u64>,
    pub queue: Micros,
    /// `(at, bits/s)` from the start: the bottleneck's rate from then on (a cell freeing up).
    pub rate_change: Option<(Micros, u64)>,
    /// Probability a packet is held back `reorder_delay` (overtaken by later ones).
    pub reorder: f64,
    pub reorder_delay: Micros,
    /// `(at, duration)` from the start: everything lost, then `after_blackout` extra delay for good.
    pub blackout: Option<(Micros, Micros)>,
    pub after_blackout: Micros,
    /// Bytes each datagram costs on the wire beyond its payload (QUIC short header + AEAD tag + UDP/IP).
    pub overhead: usize,
}

impl LinkProfile {
    /// 2 ms one way, no loss, 300 Mbps.
    pub fn lan() -> LinkProfile {
        LinkProfile {
            name: "lan",
            delay: Micros::from_millis(2),
            jitter: Micros(500),
            loss: 0.0,
            fades_per_s: 0.0,
            fade: (Micros::ZERO, Micros::ZERO),
            stalls_per_s: 0.0,
            stall: (Micros::ZERO, Micros::ZERO),
            rate_bps: Some(300_000_000),
            queue: Micros::from_millis(20),
            rate_change: None,
            reorder: 0.0,
            reorder_delay: Micros::ZERO,
            blackout: None,
            after_blackout: Micros::ZERO,
            overhead: 48,
        }
    }

    /// 35 ms one way, 15 ms jitter, 1 % random loss, fades of 5–20 ms (0.2 % of the time), 30 Mbps with a 60 ms
    /// queue, a little reordering.
    pub fn five_g() -> LinkProfile {
        LinkProfile {
            name: "5g",
            delay: Micros::from_millis(35),
            jitter: Micros::from_millis(15),
            loss: 0.01,
            fades_per_s: 0.16,
            fade: (Micros::from_millis(5), Micros::from_millis(20)),
            stalls_per_s: 0.0,
            stall: (Micros::ZERO, Micros::ZERO),
            rate_bps: Some(30_000_000),
            queue: Micros::from_millis(60),
            rate_change: None,
            reorder: 0.002,
            reorder_delay: Micros::from_millis(4),
            blackout: None,
            after_blackout: Micros::ZERO,
            overhead: 48,
        }
    }

    /// [`LinkProfile::five_g`] with fades read as "0.2 % of packets start a burst of 5–20": at ~800 packets/s
    /// that is 1.6 fades a second. Reported, not asserted.
    pub fn five_g_harsh() -> LinkProfile {
        LinkProfile { name: "5g-harsh", fades_per_s: 1.6, ..LinkProfile::five_g() }
    }

    /// A phone on 5G as measured (RTT 63–90 ms with spikes past 110, almost no loss, plenty of capacity): 32 ms one
    /// way, 30 ms jitter, stalls of 20–60 ms 0.3 times a second, 0.2 % random loss, no fades, 100 Mbps. The delay
    /// wanders with no queue behind it.
    pub fn five_g_jitter() -> LinkProfile {
        LinkProfile {
            name: "5g-jitter",
            delay: Micros::from_millis(32),
            jitter: Micros::from_millis(30),
            loss: 0.002,
            fades_per_s: 0.0,
            stalls_per_s: 0.3,
            stall: (Micros::from_millis(40), Micros::from_millis(150)),
            rate_bps: Some(100_000_000),
            reorder: 0.0,
            ..LinkProfile::five_g()
        }
    }

    /// 60 ms one way, 40 ms jitter, 5 % random loss, 30 ms fades (1 % of the time), 10 Mbps with a 100 ms queue.
    pub fn bad() -> LinkProfile {
        LinkProfile {
            name: "bad",
            delay: Micros::from_millis(60),
            jitter: Micros::from_millis(40),
            loss: 0.05,
            fades_per_s: 0.33,
            fade: (Micros::from_millis(30), Micros::from_millis(30)),
            stalls_per_s: 0.0,
            stall: (Micros::ZERO, Micros::ZERO),
            rate_bps: Some(10_000_000),
            queue: Micros::from_millis(100),
            rate_change: None,
            reorder: 0.01,
            reorder_delay: Micros::from_millis(10),
            blackout: None,
            after_blackout: Micros::ZERO,
            overhead: 48,
        }
    }

    /// [`LinkProfile::five_g`] with a 300 ms blackout 16 s in (while scrolling), then 20 ms more delay.
    pub fn handover() -> LinkProfile {
        LinkProfile {
            name: "handover",
            blackout: Some((Micros::from_secs(16), Micros::from_millis(300))),
            after_blackout: Micros::from_millis(20),
            ..LinkProfile::five_g()
        }
    }

    /// A long international path with heavy random loss and plenty of capacity (a field case: RTT ~280 ms, 9–23 %
    /// loss even when idle and on 1 kbit/s of audio, no queue as the rate rises): 140 ms one way, 15 ms jitter,
    /// 15 % random loss each way, no fades, 100 Mbps with a 100 ms queue. The loss isn't congestion: the rate
    /// must not fall to the floor.
    pub fn long_loss() -> LinkProfile {
        LinkProfile {
            name: "long-loss",
            delay: Micros::from_millis(140),
            jitter: Micros::from_millis(15),
            loss: 0.15,
            fades_per_s: 0.0,
            fade: (Micros::ZERO, Micros::ZERO),
            stalls_per_s: 0.0,
            stall: (Micros::ZERO, Micros::ZERO),
            rate_bps: Some(100_000_000),
            queue: Micros::from_millis(100),
            rate_change: None,
            reorder: 0.0,
            reorder_delay: Micros::ZERO,
            blackout: None,
            after_blackout: Micros::ZERO,
            overhead: 48,
        }
    }

    /// [`LinkProfile::long_loss`] without the random loss (0.5 %) behind a real bottleneck: 2 Mbps with a deep
    /// (250 ms) queue. The rate must back off.
    pub fn long_bottleneck() -> LinkProfile {
        LinkProfile {
            name: "long-2mbps",
            loss: 0.005,
            rate_bps: Some(2_000_000),
            queue: Micros::from_millis(250),
            ..LinkProfile::long_loss()
        }
    }

    /// Both at once: 15 % random loss and a 2 Mbps bottleneck with a 250 ms queue. The random loss must not
    /// hide the queue (the rate backs off to the bottleneck) nor cut the rate below it.
    pub fn long_loss_bottleneck() -> LinkProfile {
        LinkProfile { name: "long-l-2m", loss: 0.15, ..LinkProfile::long_bottleneck() }
    }

    /// A policer (a 2 Mbps bottleneck with almost no queue, 5 ms, tail drop) on the long path, no random loss:
    /// sending above it shows as loss alone, growing with the rate, with no delay to warn — the loss-based
    /// decrease must still act.
    pub fn long_policer() -> LinkProfile {
        LinkProfile { name: "long-police", queue: Micros::from_millis(5), loss: 0.0, ..LinkProfile::long_bottleneck() }
    }

    /// The profile with another bottleneck rate.
    pub fn with_rate(self, name: &'static str, bps: u64) -> LinkProfile {
        LinkProfile { name, rate_bps: Some(bps), ..self }
    }
}

/// What happened on a link.
#[derive(Clone, Debug, Default)]
pub struct LinkStats {
    pub sent: u64,
    pub delivered: u64,
    pub lost_random: u64,
    pub lost_fade: u64,
    pub lost_queue: u64,
    pub lost_blackout: u64,
    /// Bottleneck queueing delay seen by each packet: (send time, ms).
    pub queue_ms: Vec<(Micros, f64)>,
}

/// One simulated direction.
pub struct Link {
    p: LinkProfile,
    rng: Rng,
    stall_rng: Rng,
    start: Micros,
    free_at: Micros,
    last_arrival: Micros,
    heap: BinaryHeap<Reverse<(Micros, u64, Vec<u8>)>>,
    seq: u64,
    fade_start: Micros,
    fade_end: Micros,
    stall_start: Micros,
    stall_end: Micros,
    knot_at: Micros,
    knots: (f64, f64),
    pub stats: LinkStats,
}

impl Link {
    const KNOT: Micros = Micros::from_millis(200);

    pub fn new(p: LinkProfile, seed: u64, start: Micros) -> Link {
        let mut rng = Rng::new(seed);
        let first_fade = start + Self::next_fade_gap(&p, &mut rng);
        let k = (rng.f64(), rng.f64());
        // its own stream: profiles without stalls draw the same numbers as before
        let mut stall_rng = Rng::new(seed ^ 0x0051_7411);
        let first_stall = start + Self::next_gap(p.stalls_per_s, &mut stall_rng);
        Link {
            stall_start: first_stall,
            stall_end: first_stall,
            stall_rng,
            fade_end: first_fade,
            fade_start: first_fade,
            p,
            rng,
            start,
            free_at: start,
            last_arrival: start,
            heap: BinaryHeap::new(),
            seq: 0,
            knot_at: start,
            knots: k,
            stats: LinkStats::default(),
        }
    }

    fn next_fade_gap(p: &LinkProfile, rng: &mut Rng) -> Micros {
        Self::next_gap(p.fades_per_s, rng)
    }

    fn next_gap(per_s: f64, rng: &mut Rng) -> Micros {
        if per_s <= 0.0 { Micros::MAX } else { Micros::from_secs_f64(rng.exp(1.0 / per_s)) }
    }

    /// When a stall going on at `now` ends.
    fn stall_until(&mut self, now: Micros) -> Option<Micros> {
        while now >= self.stall_end {
            let gap = Self::next_gap(self.p.stalls_per_s, &mut self.stall_rng);
            if gap == Micros::MAX {
                return None;
            }
            self.stall_start = self.stall_end + gap;
            let d = self.stall_rng.range(self.p.stall.0.as_secs_f64(), self.p.stall.1.as_secs_f64());
            self.stall_end = self.stall_start + Micros::from_secs_f64(d);
        }
        (now >= self.stall_start).then_some(self.stall_end)
    }

    fn in_blackout(&self, now: Micros) -> bool {
        self.p.blackout.is_some_and(|(at, d)| now >= self.start + at && now < self.start + at + d)
    }

    fn after_blackout(&self, now: Micros) -> bool {
        self.p.blackout.is_some_and(|(at, d)| now >= self.start + at + d)
    }

    fn in_fade(&mut self, now: Micros) -> bool {
        while now >= self.fade_end {
            let gap = Self::next_fade_gap(&self.p, &mut self.rng);
            self.fade_start = self.fade_end + gap;
            let d = self.rng.range(self.p.fade.0.as_secs_f64(), self.p.fade.1.as_secs_f64());
            self.fade_end = self.fade_start + Micros::from_secs_f64(d);
        }
        now >= self.fade_start
    }

    /// Propagation + the slow jitter component at `now` (no queue, no per-packet noise).
    pub fn path_delay(&mut self, now: Micros) -> Micros {
        while now >= self.knot_at + Self::KNOT {
            self.knot_at += Self::KNOT;
            self.knots = (self.knots.1, self.rng.f64());
        }
        let frac = (now - self.knot_at).as_secs_f64() / Self::KNOT.as_secs_f64();
        let slow = self.knots.0 + (self.knots.1 - self.knots.0) * frac;
        let extra = if self.after_blackout(now) { self.p.after_blackout } else { Micros::ZERO };
        self.p.delay + extra + self.p.jitter.mul_f64(slow / 3.0)
    }

    /// The bottleneck's current backlog.
    pub fn queue_delay(&self, now: Micros) -> Micros {
        self.free_at - now
    }

    /// Send a datagram at `now`; returns its arrival time if it gets through.
    pub fn send(&mut self, now: Micros, d: Vec<u8>) -> Option<Micros> {
        self.stats.sent += 1;
        if self.in_blackout(now) {
            self.stats.lost_blackout += 1;
            return None;
        }
        if self.in_fade(now) {
            self.stats.lost_fade += 1;
            return None;
        }
        if self.rng.chance(self.p.loss) {
            self.stats.lost_random += 1;
            return None;
        }
        let mut leave = now;
        let rate = match self.p.rate_change {
            Some((at, r)) if now >= self.start + at => Some(r),
            _ => self.p.rate_bps,
        };
        if let Some(rate) = rate {
            let start = self.free_at.max(now);
            let wait = start - now;
            if wait > self.p.queue {
                self.stats.lost_queue += 1;
                return None;
            }
            self.stats.queue_ms.push((now, wait.as_millis_f64()));
            let tx = Micros::from_secs_f64((d.len() + self.p.overhead) as f64 * 8.0 / rate as f64);
            self.free_at = start + tx;
            leave = self.free_at;
        }
        let noise = self.p.jitter.mul_f64(self.rng.f64() * 2.0 / 3.0);
        let mut arrival = leave + self.path_delay(now) + noise;
        if let Some(end) = self.stall_until(leave) {
            arrival = arrival.max(end + self.p.delay);
        }
        if self.rng.chance(self.p.reorder) {
            arrival += self.p.reorder_delay;
        } else {
            arrival = arrival.max(self.last_arrival);
            self.last_arrival = arrival;
        }
        self.seq += 1;
        self.stats.delivered += 1;
        self.heap.push(Reverse((arrival, self.seq, d)));
        Some(arrival)
    }

    pub fn next_arrival(&self) -> Option<Micros> {
        self.heap.peek().map(|r| r.0.0)
    }

    pub fn poll(&mut self, now: Micros) -> Option<Vec<u8>> {
        if self.heap.peek().is_some_and(|r| r.0.0 <= now) {
            return self.heap.pop().map(|r| r.0.2);
        }
        None
    }
}

/// The transport's datagram send path as the media layer sees it: a FIFO drained by a pacer at
/// `1.25 × cwnd / srtt` with `cwnd = max(2 × target × srtt, 16 × MTU)`, bytes in flight ≤ cwnd.
pub struct QuicPacer {
    queue: VecDeque<(Micros, Vec<u8>)>,
    pub queued_bytes: usize,
    tokens: f64,
    last: Micros,
    in_flight: VecDeque<(Micros, usize)>,
    in_flight_bytes: usize,
    /// Time each datagram waited in this queue (ms).
    pub wait_ms: Vec<f64>,
}

impl QuicPacer {
    const MTU: f64 = 1200.0;

    pub fn new(now: Micros) -> QuicPacer {
        QuicPacer {
            queue: VecDeque::new(),
            queued_bytes: 0,
            tokens: 10.0 * Self::MTU,
            last: now,
            in_flight: VecDeque::new(),
            in_flight_bytes: 0,
            wait_ms: Vec::new(),
        }
    }

    fn cwnd(target_bps: u64, srtt: Micros) -> f64 {
        (2.0 * target_bps as f64 / 8.0 * srtt.as_secs_f64()).max(16.0 * Self::MTU)
    }

    fn rate(target_bps: u64, srtt: Micros) -> f64 {
        1.25 * Self::cwnd(target_bps, srtt) / srtt.as_secs_f64().max(0.001)
    }

    pub fn push(&mut self, now: Micros, d: Vec<u8>) {
        self.queued_bytes += d.len();
        self.queue.push_back((now, d));
    }

    fn refill(&mut self, now: Micros, target_bps: u64, srtt: Micros) {
        let burst = (Self::cwnd(target_bps, srtt) * 0.002 / srtt.as_secs_f64().max(0.001))
            .clamp(10.0 * Self::MTU, 64.0 * Self::MTU);
        self.tokens = (self.tokens + (now - self.last).as_secs_f64() * Self::rate(target_bps, srtt)).min(burst);
        self.last = now;
        while self.in_flight.front().is_some_and(|f| f.0 <= now) {
            if let Some((_, b)) = self.in_flight.pop_front() {
                self.in_flight_bytes -= b;
            }
        }
    }

    /// The next datagram allowed out at `now`.
    pub fn poll(&mut self, now: Micros, target_bps: u64, srtt: Micros) -> Option<Vec<u8>> {
        self.refill(now, target_bps, srtt);
        let len = self.queue.front()?.1.len();
        if self.tokens < len as f64 || (self.in_flight_bytes + len) as f64 > Self::cwnd(target_bps, srtt) {
            return None;
        }
        self.tokens -= len as f64;
        let (at, d) = self.queue.pop_front()?;
        self.queued_bytes -= d.len();
        self.wait_ms.push((now - at).as_millis_f64());
        Some(d)
    }

    /// The datagram left; it counts in flight until `acked_at`.
    pub fn sent(&mut self, size: usize, acked_at: Micros) {
        self.in_flight_bytes += size;
        let at = self.in_flight.partition_point(|f| f.0 <= acked_at);
        self.in_flight.insert(at, (acked_at, size));
    }

    pub fn next_time(&self, now: Micros, target_bps: u64, srtt: Micros) -> Option<Micros> {
        let len = self.queue.front()?.1.len() as f64;
        let need = (len - self.tokens).max(0.0);
        let mut t = now + Micros::from_secs_f64(need / Self::rate(target_bps, srtt));
        if (self.in_flight_bytes as f64 + len) > Self::cwnd(target_bps, srtt)
            && let Some(f) = self.in_flight.front()
        {
            t = t.max(f.0);
        }
        Some(t.max(now + Micros(1)))
    }
}

/// Synthetic screen content.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Content {
    /// Cycles idle (small deltas, 2 fps) → typing (12 fps, 1–3 KB) → scrolling (60 fps at the encoder budget) →
    /// two refines; a large frame (6 budgets) every 7 s.
    Mixed,
    /// Scrolling all the time (60 fps at the encoder budget): fills the rate.
    Scrolling,
    /// Scrolling plus a heavy key frame (25 budgets, ≥ 60 KB) every 2 s: audio and cursor must not wait behind it.
    Keyframes,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    Idle,
    Typing,
    Scrolling,
}

#[derive(Clone, Copy, Debug)]
struct SentFrame {
    kind: FrameKind,
    base: u32,
    at: Micros,
    /// Access-unit bytes, and whether it was a scrolling delta (the picture's sharpness while it moves).
    bytes: usize,
    scroll: bool,
}

struct Encoder {
    rng: Rng,
    content: Content,
    phase: Phase,
    phase_end: Micros,
    next_due: Micros,
    stop_at: Micros,
    last_key: Option<Micros>,
    encoder_bps: u64,
    /// The server's frame-rate cap.
    fps: f64,
    want_key: bool,
    want_recovery: bool,
    newest_delivered: Option<u32>,
    refines: u32,
    next_large: Micros,
    sent: BTreeMap<u32, SentFrame>,
    skips: u64,
}

impl Encoder {
    /// One frame's bytes: the encoder rate over the frames it may send (an encoder told the rate for the
    /// frame-rate cap, as the Linux sender is; VideoToolbox budgets by time and comes to the same).
    fn budget(&self) -> f64 {
        self.encoder_bps as f64 / 8.0 / self.fps
    }

    fn advance_phase(&mut self, now: Micros) {
        if self.content != Content::Mixed {
            self.phase = Phase::Scrolling;
            return;
        }
        while now >= self.phase_end {
            let (next, len) = match self.phase {
                Phase::Idle => (Phase::Typing, 3.0),
                Phase::Typing => (Phase::Scrolling, 4.0),
                Phase::Scrolling => {
                    self.refines = 2;
                    (Phase::Idle, 3.0)
                }
            };
            self.phase = next;
            self.phase_end += Micros::from_secs_f64(len);
        }
    }

    fn tick(&mut self, now: Micros, server: &mut ServerMedia, queued: usize) {
        self.advance_phase(now);
        if now >= self.stop_at {
            self.next_due = Micros::MAX;
            return;
        }
        self.fps = server.frame_rate_cap(1).unwrap_or(60.0);
        if !server.can_send_frame(now, 1, queued, None) {
            self.skips += 1;
            self.next_due = now + Micros::from_millis(4);
            return;
        }
        let key_ok = self.last_key.is_none_or(|k| now - k >= Micros::from_millis(500));
        // ordinary frames get the per-frame budget; key, recovery, large and refine frames stay sized by time
        // (as at 60 fps: an encoder caps those by its 1 s buffer of the real rate, not by the frame budget)
        let b = self.budget();
        let bt = self.encoder_bps as f64 / 8.0 / 60.0;
        let mut base = 0;
        let heavy =
            self.content == Content::Keyframes && self.last_key.is_some_and(|k| now - k >= Micros::from_secs(2));
        let (kind, size) = if heavy {
            (FrameKind::Key, (25.0 * bt).max(60_000.0))
        } else if self.want_key && key_ok {
            (FrameKind::Key, (8.0 * bt).max(20_000.0))
        } else if self.want_recovery {
            match self.newest_delivered {
                Some(d) => {
                    base = d;
                    (FrameKind::Recovery, 2.0 * bt.max(3000.0))
                }
                None if key_ok => (FrameKind::Key, (8.0 * bt).max(20_000.0)),
                None => (FrameKind::Delta, 1000.0),
            }
        } else if now >= self.next_large {
            self.next_large = now + Micros::from_secs(7);
            (FrameKind::Delta, 6.0 * bt)
        } else if self.refines > 0 && self.phase == Phase::Idle {
            self.refines -= 1;
            (FrameKind::Refine, 2.0 * bt)
        } else {
            let s = match self.phase {
                Phase::Idle => self.rng.range(300.0, 900.0),
                Phase::Typing => self.rng.range(800.0, 3000.0),
                Phase::Scrolling => b * self.rng.range(0.6, 1.4),
            };
            (FrameKind::Delta, s)
        };
        let au = vec![0x5Au8; (size as usize).max(16)];
        let meta = FrameMeta {
            codec: Codec::H264,
            kind,
            width: 2304,
            height: 1440,
            capture_us: now.0,
            recovery_base: base,
            au_len: 0,
        };
        let Ok(frame) = server.send_frame(now, 1, meta, &au) else { return };
        match kind {
            FrameKind::Key => {
                self.last_key = Some(now);
                self.want_key = false;
                self.want_recovery = false;
            }
            FrameKind::Recovery => self.want_recovery = false,
            _ => {}
        }
        let scroll = kind == FrameKind::Delta && self.phase == Phase::Scrolling;
        self.sent.insert(frame, SentFrame { kind, base, at: now, bytes: au.len(), scroll });
        self.next_due = now
            + match self.phase {
                Phase::Idle if self.refines > 0 => Micros::from_millis(300),
                Phase::Idle => Micros::from_millis(500),
                Phase::Typing => Micros::from_secs_f64(self.rng.range(0.06, 0.11)),
                Phase::Scrolling => Micros::from_secs_f64(1.0 / self.fps.min(60.0)),
            };
        if self.want_key || self.want_recovery {
            // answer the request with the next frame, not a whole idle interval later
            self.next_due = self.next_due.min(now + Micros(16_667));
        }
    }
}

/// One simulated session.
#[derive(Clone, Debug)]
pub struct Scenario {
    pub profile: LinkProfile,
    pub seed: u64,
    pub duration: Micros,
    pub content: Content,
    pub network: NetworkProfile,
    /// The sender asks for a recovery frame with every NACK ([`crate::VideoSendConfig::recovery_on_nack`]);
    /// off by default, like the crate.
    pub recovery_on_nack: bool,
}

impl Scenario {
    pub fn new(profile: LinkProfile, seed: u64) -> Scenario {
        let network = if profile.name == "lan" { NetworkProfile::Lan } else { NetworkProfile::Cellular };
        Scenario {
            profile,
            seed,
            duration: Micros::from_secs(30),
            content: Content::Mixed,
            network,
            recovery_on_nack: false,
        }
    }
}

/// What a run measured.
#[derive(Clone, Debug, Default)]
pub struct Report {
    pub name: String,
    pub seed: u64,
    pub frames_sent: u64,
    pub frames_delivered: u64,
    pub frames_lost: u64,
    pub frames_skipped: u64,
    /// Frames handed to the decoder whose reference wasn't decoded (must be 0).
    pub chain_violations: u64,
    pub fec_recovered: u64,
    pub nack_sent: u64,
    pub nack_recovered: u64,
    pub freezes: u64,
    pub freeze_ms: u64,
    /// Pictures the encoder skipped on backpressure.
    pub encoder_skips: u64,
    pub key_frames: u64,
    pub recovery_frames: u64,
    /// Capture → delivery (ms).
    pub latency_p50_ms: f64,
    pub latency_p95_ms: f64,
    /// Bottleneck queueing delay of downlink datagrams, and the time they waited in the pacer (ms).
    pub queue_p95_ms: f64,
    /// The same from 5 s on (after the rate had time to converge).
    pub queue_p95_after5_ms: f64,
    pub pacer_p95_ms: f64,
    /// Bottleneck queueing delay of uplink datagrams (ms, p95), and the uplink's rate (Mbps over the run).
    pub up_queue_p95_ms: f64,
    pub up_mbps: f64,
    /// Rate decreases (all, loss-based), delay-based ones held back, overuse ignored as jitter.
    pub rate_decreases: (u64, u64, u64, u64),
    pub rate_mean_mbps: f64,
    pub rate_final_mbps: f64,
    /// When the target got (and stayed, 95 % of samples) below the bottleneck rate.
    pub rate_converged_s: Option<f64>,
    pub down_loss_pct: f64,
    pub input_discrete: u64,
    pub input_moves_applied: u64,
    /// Discrete events applied exactly once and in send order.
    pub input_exact: bool,
    pub input_failed: u64,
    /// One-way, first send → applied (ms).
    pub input_p50_ms: f64,
    pub input_p99_ms: f64,
    /// Input one-way minus the path's delay at send time (ms): what the reliability layer added.
    pub input_excess_p99_ms: f64,
    pub audio_packets: u64,
    /// Pre-redundancy loss over the last 2 s, and packets missing after redundancy over the run (%).
    pub audio_loss_pct: f64,
    pub audio_residual_pct: f64,
    pub audio_lost_after_redundancy: u64,
    /// Skipped frames per lost frame, and the mean gap (ms) between the last frame shown before a loss and the
    /// first one after it (the picture's stall per loss).
    pub skip_per_loss: f64,
    pub resume_gap_ms: f64,
    /// How many times the picture resumed after frames were lost or skipped (the gaps averaged above).
    pub resumes: u64,
    /// Mean target over the last 10 s of encoding (Mbps), and the lowest target from 5 s on.
    pub rate_settled_mbps: f64,
    pub rate_min_after5_mbps: f64,
    /// Frames shown per second (over the encoding time), and the median size of the scrolling delta frames shown
    /// (kbit: how sharp a moving picture is at the rate).
    pub fps_shown: f64,
    pub scroll_kbit_p50: f64,
    /// Audio and cursor one-way delay, send → client event (ms).
    pub audio_p99_ms: f64,
    pub audio_max_ms: f64,
    pub cursor_p99_ms: f64,
    pub cursor_max_ms: f64,
    /// What the server really handed to the transport from 5 s to the end of encoding (Mbps), and what its
    /// stats line said for that interval.
    pub true_sent_mbps: f64,
    pub line_sent_mbps: f64,
    /// The `link:` line of each side: the server's for 5 s … end of encoding, the client's at the end.
    pub server_line: String,
    pub client_line: String,
}

impl Report {
    pub fn delivered_pct(&self) -> f64 {
        if self.frames_sent == 0 { 100.0 } else { 100.0 * self.frames_delivered as f64 / self.frames_sent as f64 }
    }

    pub fn header() -> String {
        format!(
            "{:<10} {:>6} {:>8} {:>4} {:>4} {:>6} {:>6} {:>11} {:>5} {:>9} {:>6} {:>5} {:>14} {:>5} {:>6} {:>11}",
            "profile",
            "frames",
            "deliv %",
            "lost",
            "skip",
            "skip/l",
            "gap ms",
            "freeze n/ms",
            "fec",
            "nack r/s",
            "q p95",
            "lat95",
            "rate mean/10s",
            "conv",
            "in p99",
            "aud/cur p99"
        )
    }

    pub fn row(&self) -> String {
        format!(
            "{:<10} {:>6} {:>7.2}% {:>4} {:>4} {:>6.1} {:>6.0} {:>11} {:>5} {:>9} {:>6.1} {:>5.0} {:>14} {:>5} {:>6.1} {:>11}",
            self.name,
            self.frames_sent,
            self.delivered_pct(),
            self.frames_lost,
            self.frames_skipped,
            self.skip_per_loss,
            self.resume_gap_ms,
            format!("{}/{}", self.freezes, self.freeze_ms),
            self.fec_recovered,
            format!("{}/{}", self.nack_recovered, self.nack_sent),
            self.queue_p95_ms,
            self.latency_p95_ms,
            format!("{:.2}/{:.2}", self.rate_mean_mbps, self.rate_settled_mbps),
            self.rate_converged_s.map_or("-".to_string(), |s| format!("{s:.1}")),
            self.input_p99_ms,
            format!("{:.0}/{:.0}", self.audio_p99_ms, self.cursor_p99_ms),
        )
    }
}

struct InputTruth {
    sent_at: BTreeMap<u32, (Micros, Micros, InputKind)>,
    discrete_sent: Vec<u32>,
    discrete_applied: Vec<u32>,
    one_way: Vec<f64>,
    excess: Vec<f64>,
    moves: u64,
    last_move: u32,
    move_order_ok: bool,
}

/// Run one scenario.
pub fn run(s: &Scenario) -> Report {
    let start = Micros::from_secs(1);
    let end = start + s.duration;
    let mut now = start;
    let mut cfg = ServerConfig::default();
    cfg.video.recovery_on_nack = s.recovery_on_nack;
    let mut server = ServerMedia::new(cfg);
    let mut client = ClientMedia::new(ClientConfig::default());
    server.open_video(1);
    client.open_video(1);
    server.open_audio(1);
    client.open_audio(1);
    server.set_network(now, s.network);
    let mut down = Link::new(s.profile.clone(), s.seed.wrapping_mul(31).wrapping_add(1), start);
    let mut up = Link::new(s.profile.clone(), s.seed.wrapping_mul(31).wrapping_add(2), start);
    let mut pacer = QuicPacer::new(start);
    let mut rng = Rng::new(s.seed.wrapping_mul(31).wrapping_add(3));
    let mut enc = Encoder {
        rng: Rng::new(s.seed.wrapping_mul(31).wrapping_add(4)),
        content: s.content,
        phase: if s.content == Content::Mixed { Phase::Idle } else { Phase::Scrolling },
        phase_end: start + Micros::from_secs(2),
        next_due: start,
        // stop encoding a second early so the tail drains
        stop_at: end - Micros::from_secs(1),
        last_key: None,
        encoder_bps: server.target_rate().bps() * 85 / 100,
        fps: 60.0,
        want_key: true,
        want_recovery: false,
        newest_delivered: None,
        refines: 0,
        next_large: start + Micros::from_secs(7),
        sent: BTreeMap::new(),
        skips: 0,
    };
    let base_rtt = s.profile.delay + s.profile.delay;
    let mut srtt = base_rtt;
    let mut next_rtt = start;
    let mut next_audio = start;
    let mut next_input = start + Micros::from_millis(100);
    let mut next_cursor = start;
    let mut next_rate_sample = start;
    let mut targets: Vec<(Micros, u64)> = Vec::new();
    let mut decoded: std::collections::BTreeSet<u32> = Default::default();
    let mut chain_violations = 0u64;
    let mut latencies: Vec<f64> = Vec::new();
    let mut scroll_kbit: Vec<f64> = Vec::new();
    let mut audio_packets = 0u64;
    let mut audio_ms: Vec<f64> = Vec::new();
    let mut cursor_ms: Vec<f64> = Vec::new();
    let mut gaps_ms: Vec<f64> = Vec::new();
    let mut last_shown: Option<(u32, Micros)> = None;
    let stats_from = start + Micros::from_secs(5);
    let mut server_from: Option<crate::stats::MediaStats> = None;
    let mut server_to: Option<crate::stats::MediaStats> = None;
    let mut handed_bytes = 0u64;
    let mut up_bytes = 0u64;
    let mut input_failed = 0u64;
    let mut truth = InputTruth {
        sent_at: BTreeMap::new(),
        discrete_sent: Vec::new(),
        discrete_applied: Vec::new(),
        one_way: Vec::new(),
        excess: Vec::new(),
        moves: 0,
        last_move: 0,
        move_order_ok: true,
    };
    let mut same_now = 0u32;
    let mut last_now = now;
    let input_stop = end - Micros::from_millis(2500);

    loop {
        // next event
        let target = server.target_rate().bps();
        // the timers as armed now (sans-IO convention: fire handle_timeout when they pass)
        let server_timer = server.poll_timeout(now);
        let client_timer = client.poll_timeout(now);
        let mut t = end;
        for c in [
            Some(enc.next_due),
            Some(next_rtt),
            Some(next_audio),
            Some(next_input),
            Some(next_cursor),
            Some(next_rate_sample),
            server_timer,
            client_timer,
            pacer.next_time(now, target, srtt),
            down.next_arrival(),
            up.next_arrival(),
        ]
        .into_iter()
        .flatten()
        {
            t = t.min(c);
        }
        now = now.max(t);
        if now >= end {
            break;
        }
        if now == last_now {
            same_now += 1;
            assert!(same_now < 10_000, "simulation stuck at {now:?}");
        } else {
            same_now = 0;
            last_now = now;
        }

        // arrivals
        while let Some(d) = down.poll(now) {
            let _ = client.handle_datagram(now, &d);
        }
        while let Some(d) = up.poll(now) {
            let _ = server.handle_datagram(now, &d);
        }
        if server_timer.is_some_and(|t| t <= now) || server.poll_timeout(now).is_some_and(|t| t <= now) {
            server.handle_timeout(now);
        }
        if client_timer.is_some_and(|t| t <= now) || client.poll_timeout(now).is_some_and(|t| t <= now) {
            client.handle_timeout(now);
        }

        // transport RTT (QUIC-like smoothed): both paths + the downlink queue
        if now >= next_rtt {
            next_rtt = now + Micros::from_millis(50);
            let sample =
                down.path_delay(now) + up.path_delay(now) + down.queue_delay(now) + s.profile.jitter.mul_f64(1.0 / 3.0);
            srtt = Micros(srtt.0 - srtt.0 / 8 + sample.0 / 8);
            server.set_rtt(now, srtt);
            client.set_rtt(now, srtt);
        }
        if now >= next_rate_sample {
            next_rate_sample = now + Micros::from_millis(100);
            targets.push((now, server.target_rate().bps()));
        }

        // app: server events
        while let Some(e) = server.poll_event() {
            match e {
                ServerEvent::TargetBitrate { encoder_bps, .. } => enc.encoder_bps = encoder_bps,
                ServerEvent::FrameDelivered { frame, .. } => enc.newest_delivered = Some(frame),
                // a real encoder answers with the next frame, not at the next change
                ServerEvent::RecoveryNeeded { .. } => {
                    enc.want_recovery = true;
                    enc.next_due = enc.next_due.min(now);
                }
                ServerEvent::KeyframeNeeded { .. } => {
                    enc.want_key = true;
                    enc.next_due = enc.next_due.min(now);
                }
                ServerEvent::Input(ev) => {
                    let Some(&(sent, path, kind)) = truth.sent_at.get(&ev.seq) else { continue };
                    match kind {
                        InputKind::Discrete => {
                            truth.discrete_applied.push(ev.seq);
                            let ow = (now - sent).as_millis_f64();
                            truth.one_way.push(ow);
                            truth.excess.push(ow - path.as_millis_f64());
                        }
                        InputKind::Move => {
                            truth.moves += 1;
                            if ev.seq <= truth.last_move {
                                truth.move_order_ok = false;
                            }
                            truth.last_move = ev.seq;
                        }
                    }
                }
            }
        }
        // app: client events
        while let Some(e) = client.poll_event() {
            match e {
                ClientEvent::Frame(f) => {
                    let Some(info) = enc.sent.get(&f.frame) else {
                        chain_violations += 1;
                        continue;
                    };
                    let ok = match info.kind {
                        FrameKind::Key => true,
                        FrameKind::Recovery => decoded.contains(&info.base),
                        _ => decoded.contains(&(f.frame - 1)),
                    };
                    if !ok || f.meta.kind != info.kind {
                        chain_violations += 1;
                    }
                    decoded.insert(f.frame);
                    if let Some((prev, at)) = last_shown
                        && f.frame > prev + 1
                    {
                        gaps_ms.push((now - at).as_millis_f64());
                    }
                    last_shown = Some((f.frame, now));
                    latencies.push((f.delivered_at - info.at).as_millis_f64());
                    if info.scroll {
                        scroll_kbit.push(info.bytes as f64 * 8.0 / 1000.0);
                    }
                    client.frame_decoded(f.stream, f.frame, true);
                }
                ClientEvent::Audio(a) => {
                    audio_packets += 1;
                    if !a.recovered {
                        audio_ms.push((now - (start + Micros(a.time_us))).as_millis_f64());
                    }
                }
                ClientEvent::InputFailed { .. } => input_failed += 1,
                ClientEvent::Cursor { json, .. } => {
                    // the position carries its send time: {"t":µs,…}
                    let t = std::str::from_utf8(&json)
                        .ok()
                        .and_then(|j| j.strip_prefix(r#"{"t":"#))
                        .and_then(|j| j.split(',').next())
                        .and_then(|v| v.parse::<u64>().ok());
                    if let Some(t) = t {
                        cursor_ms.push((now - Micros(t)).as_millis_f64());
                    }
                }
                ClientEvent::InputAcked { .. } => {}
            }
        }

        // app: sources
        if now >= enc.next_due {
            enc.tick(now, &mut server, pacer.queued_bytes);
        }
        if now >= next_audio {
            let _ = server.send_audio(now, 1, (now - start).0, &[0x33; 120]);
            next_audio += Micros::from_millis(20);
        }
        if now >= next_cursor {
            next_cursor = now + if enc.phase == Phase::Idle { Micros(16_667) } else { Micros::from_millis(200) };
            let json = format!(r#"{{"t":{},"x":0.5,"y":0.5,"visible":true,"shapeId":"arrow"}}"#, now.0);
            server.send_cursor(1, json.as_bytes());
        }
        if now >= next_input {
            if now < input_stop {
                let path = up.path_delay(now);
                let (kind, json, gap): (InputKind, &[u8], Micros) = match enc.phase {
                    Phase::Scrolling => (
                        InputKind::Discrete,
                        br#"{"type":"scroll","dx":0,"dy":-12.5,"phase":"changed"}"#,
                        Micros(16_667),
                    ),
                    Phase::Typing => (
                        InputKind::Discrete,
                        br#"{"type":"key","key":"a"}"#,
                        Micros::from_secs_f64(rng.range(0.05, 0.2)),
                    ),
                    Phase::Idle => {
                        if rng.chance(0.04) {
                            (InputKind::Discrete, br#"{"type":"click","x":0.4,"y":0.6}"#, Micros(16_667))
                        } else {
                            (InputKind::Move, br#"{"type":"move","x":0.41,"y":0.62}"#, Micros(16_667))
                        }
                    }
                };
                match client.send_input(now, kind, json) {
                    Ok(seq) => {
                        truth.sent_at.insert(seq, (now, path, kind));
                        if kind == InputKind::Discrete {
                            truth.discrete_sent.push(seq);
                        }
                    }
                    Err(_) => input_failed += 1,
                }
                next_input = now + gap;
            } else {
                next_input = Micros::MAX;
            }
        }

        // transmit
        while let Some(d) = server.poll_transmit(now) {
            if now >= stats_from && now < enc.stop_at {
                handed_bytes += d.len() as u64;
            }
            pacer.push(now, d);
        }
        if server_from.is_none() && now >= stats_from {
            server_from = Some(server.stats(now));
        }
        if server_to.is_none() && now >= enc.stop_at {
            server_to = Some(server.stats(now));
        }
        let target = server.target_rate().bps();
        while let Some(d) = pacer.poll(now, target, srtt) {
            let size = d.len();
            let acked = match down.send(now, d) {
                Some(arrival) => arrival + s.profile.delay + Micros::from_millis(5),
                None => now + srtt.mul_f64(1.125),
            };
            pacer.sent(size + s.profile.overhead, acked);
        }
        while let Some(d) = client.poll_transmit(now) {
            up_bytes += (d.len() + s.profile.overhead) as u64;
            up.send(now, d);
        }
    }

    // the report
    let ss = match (&server_to, &server_from) {
        (Some(to), Some(from)) => to.since(from),
        _ => server.stats(now),
    };
    let interval = (enc.stop_at - stats_from).as_secs_f64();
    let settled: Vec<f64> = targets
        .iter()
        .filter(|t| t.0 >= enc.stop_at - Micros::from_secs(10) && t.0 < enc.stop_at)
        .map(|t| t.1 as f64)
        .collect();
    let cs = client.stats(now);
    let rx = client.video_stats(1).unwrap_or_default();
    let tx = server.video_stats(1).unwrap_or_default();
    let cap = s.profile.rate_bps.unwrap_or(u64::MAX);
    let converged = (0..targets.len()).find_map(|i| {
        if targets[i].1 >= cap {
            return None;
        }
        let rest = &targets[i..];
        let below = rest.iter().filter(|t| t.1 < cap).count();
        (below as f64 >= 0.95 * rest.len() as f64).then(|| (targets[i].0 - start).as_secs_f64())
    });
    let exact = truth.discrete_applied == truth.discrete_sent && truth.move_order_ok;
    let lost_down = down.stats.lost_random + down.stats.lost_fade + down.stats.lost_queue + down.stats.lost_blackout;
    Report {
        name: s.profile.name.to_string(),
        seed: s.seed,
        frames_sent: tx.frames,
        frames_delivered: rx.frames_delivered,
        frames_lost: rx.frames_lost,
        frames_skipped: rx.frames_skipped,
        chain_violations,
        fec_recovered: rx.fec_recovered,
        nack_sent: rx.nack_sent,
        nack_recovered: rx.nack_recovered,
        freezes: rx.freezes,
        freeze_ms: rx.freeze_us / 1000,
        encoder_skips: enc.skips,
        key_frames: tx.key_frames,
        recovery_frames: tx.recovery_frames,
        latency_p50_ms: percentile(latencies.iter().copied(), 0.5).unwrap_or(0.0),
        latency_p95_ms: percentile(latencies.iter().copied(), 0.95).unwrap_or(0.0),
        queue_p95_ms: percentile(down.stats.queue_ms.iter().map(|q| q.1), 0.95).unwrap_or(0.0),
        queue_p95_after5_ms: percentile(
            down.stats.queue_ms.iter().filter(|q| q.0 >= start + Micros::from_secs(5)).map(|q| q.1),
            0.95,
        )
        .unwrap_or(0.0),
        rate_decreases: server.rate_controller().decreases(),
        pacer_p95_ms: percentile(pacer.wait_ms.iter().copied(), 0.95).unwrap_or(0.0),
        up_queue_p95_ms: percentile(up.stats.queue_ms.iter().map(|q| q.1), 0.95).unwrap_or(0.0),
        up_mbps: up_bytes as f64 * 8.0 / s.duration.as_secs_f64() / 1e6,
        rate_mean_mbps: targets.iter().map(|t| t.1 as f64).sum::<f64>() / targets.len().max(1) as f64 / 1e6,
        rate_final_mbps: targets.last().map_or(0.0, |t| t.1 as f64 / 1e6),
        rate_converged_s: converged,
        down_loss_pct: 100.0 * lost_down as f64 / down.stats.sent.max(1) as f64,
        input_discrete: truth.discrete_applied.len() as u64,
        input_moves_applied: truth.moves,
        input_exact: exact,
        input_failed,
        input_p50_ms: percentile(truth.one_way.iter().copied(), 0.5).unwrap_or(0.0),
        input_p99_ms: percentile(truth.one_way.iter().copied(), 0.99).unwrap_or(0.0),
        input_excess_p99_ms: percentile(truth.excess.iter().copied(), 0.99).unwrap_or(0.0),
        audio_packets,
        audio_loss_pct: cs.audio_loss_pct.unwrap_or(0.0),
        audio_residual_pct: 100.0 * cs.audio_lost as f64 / (audio_packets + cs.audio_lost).max(1) as f64,
        audio_lost_after_redundancy: cs.audio_lost,
        skip_per_loss: if rx.frames_lost == 0 { 0.0 } else { rx.frames_skipped as f64 / rx.frames_lost as f64 },
        resume_gap_ms: if gaps_ms.is_empty() { 0.0 } else { gaps_ms.iter().sum::<f64>() / gaps_ms.len() as f64 },
        resumes: gaps_ms.len() as u64,
        rate_settled_mbps: settled.iter().sum::<f64>() / settled.len().max(1) as f64 / 1e6,
        rate_min_after5_mbps: targets
            .iter()
            .filter(|t| t.0 >= stats_from && t.0 < enc.stop_at)
            .map(|t| t.1 as f64 / 1e6)
            .fold(f64::MAX, f64::min),
        fps_shown: rx.frames_delivered as f64 / (enc.stop_at - start).as_secs_f64(),
        scroll_kbit_p50: percentile(scroll_kbit.iter().copied(), 0.5).unwrap_or(0.0),
        audio_p99_ms: percentile(audio_ms.iter().copied(), 0.99).unwrap_or(0.0),
        audio_max_ms: audio_ms.iter().copied().fold(0.0, f64::max),
        cursor_p99_ms: percentile(cursor_ms.iter().copied(), 0.99).unwrap_or(0.0),
        cursor_max_ms: cursor_ms.iter().copied().fold(0.0, f64::max),
        true_sent_mbps: handed_bytes as f64 * 8.0 / interval / 1e6,
        line_sent_mbps: ss.sent_bps.unwrap_or(0) as f64 / 1e6,
        server_line: ss.line("sim", s.profile.name),
        client_line: cs.line("sim", s.profile.name),
    }
}
