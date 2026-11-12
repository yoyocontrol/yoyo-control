//! Rate control (LINK.md §5.4): a GCC-style delay-based controller (inter-group delay variation → trendline →
//! overuse / normal / underuse → AIMD) plus a loss-based one that only acts on heavy sustained loss that looks like
//! congestion (with a queue, growing with the sending rate, or beyond what FEC carries) — random loss, the same
//! at any rate, is FEC's and the NACKs' to carry ([`LossKind`]) — under the rules
//! kept from the old ack-window flow control (start rate, floor, ceilings, key-frame grace, content-limited holds,
//! a remembered ceiling after every decrease).
//!
//! Input: per-packet results from transport-wide feedback ([`PacketResult`], send time on the sender's clock,
//! arrival time on the receiver's), sent sizes, key frames, RTT and the network profile. Output: the target bit
//! rate, also published through a cheaply cloneable [`TargetRate`] the transport's congestion controller reads.

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::time::Micros;

/// The current target bit rate, shared with the transport's congestion controller
/// (`cwnd = max(2 × target × srtt, 16 × MTU)`). Clone it freely; reads are one relaxed atomic load.
#[derive(Clone, Debug)]
pub struct TargetRate(Arc<AtomicU64>);

impl TargetRate {
    pub fn new(bps: u64) -> TargetRate {
        TargetRate(Arc::new(AtomicU64::new(bps)))
    }

    /// Target in bits per second.
    pub fn bps(&self) -> u64 {
        self.0.load(Ordering::Relaxed)
    }

    pub(crate) fn set(&self, bps: u64) {
        self.0.store(bps, Ordering::Relaxed);
    }
}

/// The client's network as the rate rules see it (from the path classification and the client's interface).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum NetworkProfile {
    /// Wi-Fi / other over the internet: max 20 Mbps.
    #[default]
    Default,
    /// Wired or Wi-Fi on the same LAN: max 40 Mbps.
    Lan,
    /// Cellular: max 20 Mbps, the remembered ceiling after a decrease holds 120 s.
    Cellular,
    /// Low Data Mode / constrained path: max 2.5 Mbps.
    Constrained,
}

/// Every number the rate controller runs by.
#[derive(Clone, Debug)]
pub struct RateConfig {
    pub start_bps: u64,
    pub min_bps: u64,
    pub max_bps: u64,
    pub lan_max_bps: u64,
    pub constrained_max_bps: u64,
    /// No delay-based decrease this long after a key frame (its burst inflates delay; it isn't congestion).
    pub key_grace: Micros,
    /// Overuse → `decrease_factor × delivered rate`.
    pub decrease_factor: f64,
    /// Multiplicative increase per second far from the last decrease.
    pub increase_per_sec: f64,
    /// Startup — no decrease yet this session, so nothing is known of the path's capacity: the increase per second,
    /// and the share of the target the stream must send for it (`content_limited`'s). A screen sends in bursts
    /// (still, typing, then a scroll at the full rate): at 8 %/s and 50 % a 5g session took ~100 s from 3.5 to its
    /// 20 Mbps cap and scrolled at 11 for a minute (a field trace, docs/LINK.md「逐帧跟踪」). The first decrease
    /// (a queue, loss) ends it, and loss above `loss_threshold` pauses it; a path below the target shows a queue
    /// within about a round trip of a burst.
    pub startup_increase_per_sec: f64,
    pub startup_content_limited: f64,
    /// After a decrease, `ceiling_factor ×` the rate before it is a ceiling for `ceiling_hold` (cellular: longer).
    pub ceiling_factor: f64,
    pub ceiling_hold: Micros,
    pub cellular_ceiling_hold: Micros,
    /// `ceiling_probe` after the last decrease with no queue above the bar, a target pressing on the ceiling lifts
    /// it at `increase_per_sec` (the path may have freed up: a cell's capacity changes within seconds); a real
    /// bottleneck then shows a queue, and the next decrease sets a new ceiling.
    pub ceiling_probe: Micros,
    /// Decreases this close together are one congestion episode (one ceiling).
    pub decrease_episode: Micros,
    /// Sent less than this share of the target over `sent_window`: content-limited (no increase, no delay-based
    /// decrease — a queue then isn't this stream's).
    pub content_limited: f64,
    pub sent_window: Micros,
    /// Loss-based: loss above `loss_threshold` over `loss_window`, sustained `loss_hold`, and congestive
    /// ([`LossKind`]) → `rate × (1 − 0.5 × loss)`.
    pub loss_threshold: f64,
    pub loss_window: Micros,
    pub loss_hold: Micros,
    /// Is the loss congestion? Media datagrams are binned by send time (`loss_bin`) over `loss_history`; the bins
    /// are split at the mean sending rate (by packets) into a slower and a faster part. Loss that is congestion
    /// grows with the rate (a full queue or a policer drops what exceeds the bottleneck): the faster part loses
    /// more than the slower one by more than `loss_excess` and 3 standard errors. Random loss (a lossy long-haul
    /// path, radio) is the same at any rate: cutting the rate doesn't lower it, it only blurs the picture. The
    /// parts must differ in rate by `loss_rate_spread` and hold `loss_min_packets` each to tell; loss above
    /// `loss_congestion_max` is congestion whatever it correlates with (FEC can't carry it).
    pub loss_bin: Micros,
    pub loss_history: Micros,
    pub loss_excess: f64,
    pub loss_rate_spread: f64,
    pub loss_min_packets: u32,
    pub loss_congestion_max: f64,
    /// Heavy loss while the rate hardly varied (a steady stream: nothing to compare) is probed: the rate steps to
    /// `loss_probe_factor ×` and holds there `loss_probe_wait`, then the slower stretch tells. Random loss once
    /// told is remembered: loss up to that level (plus the margin) with no queue stays random without another
    /// probe.
    pub loss_probe_factor: f64,
    pub loss_probe_wait: Micros,
    /// Loss that spares the head of a burst is congestion too: a full queue or a policer drops only once a
    /// burst has filled it, so the first datagram after a pause of `loss_head_gap` (the queue drained, the
    /// bucket refilled) gets through, while random loss takes it as often as any. The rest of the bursts losing
    /// more than their heads by `loss_excess` (and 3 standard errors) over `loss_history` → congestion, whatever
    /// the average rate says (a policer cuts every burst paced faster than it, at any average rate).
    pub loss_head_gap: Micros,
    /// The pre-FEC loss the FEC policy reads is measured over this long.
    pub fec_loss_window: Micros,
    /// Packets sent within this span form one group for the delay gradient.
    pub group_span: Micros,
    pub trend_window: usize,
    pub trend_smoothing: f64,
    pub threshold_gain: f64,
    /// Delivered (acked) rate window, on the receiver's clock.
    pub delivered_window: Micros,
    /// Link capacity estimate: the highest delivered rate of any `capacity_bucket` of arrivals in the last
    /// `capacity_window`. A burst drains at the link's rate, so this sees the path's capacity even when the
    /// average sending is below it; a trend-based decrease goes to `decrease_factor ×` it, not to the (lower)
    /// delivered rate around the burst.
    pub capacity_bucket: Micros,
    pub capacity_window: Micros,
    /// Video is released to the transport at `pacing_factor × target`, but no faster than
    /// `bottleneck_pacing ×` the capacity measured at the last congestion decrease (for `bottleneck_hold`): a
    /// burst then waits in the sender's queue, not in the bottleneck's (where it would overflow a short queue
    /// and hold audio up).
    pub pacing_factor: f64,
    pub bottleneck_pacing: f64,
    pub bottleneck_hold: Micros,
    /// A delay-based decrease also needs a standing queue: the lowest one-way delay of the last `queue_window`
    /// above the lowest of the last `base_window` by more than `queue_threshold`. Jitter spikes don't lift a
    /// window's minimum; a real queue lifts every sample (the old flow control's rule).
    pub queue_window: Micros,
    pub base_window: Micros,
    pub queue_threshold: Micros,
    /// A standing queue above `standing_queue` for `standing_hold` is overuse even when the delay has stopped
    /// growing (a full bottleneck queue: the trendline reads flat) — unless it is draining (a burst going out
    /// over a path with little headroom). Not held by the key-frame grace.
    pub standing_queue: Micros,
    pub standing_hold: Micros,
    /// A jittery path (cellular: the delay wanders by tens of ms with no queue) lifts a short window's minimum
    /// too. The path's jitter — the median spread of one-way delays within 100 ms over `base_window`, which a
    /// queue building over seconds hardly widens — raises both thresholds to `jitter_queue ×` it.
    pub jitter_queue: f64,
    /// One-way delay is read off two clocks, the sender's and the receiver's. When they run at different rates
    /// (a virtual machine's clock being slewed: several percent, changing every few seconds) it grows by tens of ms
    /// a second with no queue at all — and a controller that believes it cuts the rate to the floor on an empty
    /// path. A queue on the way there is in every round trip as well, and the round trip is measured on one clock:
    /// with round-trip floors ([`RateController::set_rtt_floor`]) the round trip has room for a queue of its lowest
    /// floor of the last `rtt_queue_window` above its lowest of `base_window`, plus `rtt_queue_slack` (or how far
    /// the floors usually sit above their lowest, if that is more). One-way delays claiming more than
    /// `rtt_queue_margin` beyond that are the clocks: the standing queue is then what the round trip says. Within
    /// the margin the one-way delays stand as they are, so a path with steady clocks is read as before.
    pub rtt_queue_slack: Micros,
    pub rtt_queue_margin: Micros,
    pub rtt_queue_window: Micros,
}

impl Default for RateConfig {
    fn default() -> RateConfig {
        RateConfig {
            start_bps: 3_500_000,
            min_bps: 300_000,
            max_bps: 20_000_000,
            lan_max_bps: 40_000_000,
            constrained_max_bps: 2_500_000,
            key_grace: Micros::from_millis(1500),
            decrease_factor: 0.85,
            increase_per_sec: 0.08,
            startup_increase_per_sec: 0.5,
            startup_content_limited: 0.25,
            ceiling_factor: 0.9,
            ceiling_hold: Micros::from_secs(30),
            cellular_ceiling_hold: Micros::from_secs(120),
            ceiling_probe: Micros::from_secs(10),
            decrease_episode: Micros::from_secs(2),
            content_limited: 0.5,
            sent_window: Micros::from_secs(1),
            loss_threshold: 0.10,
            loss_window: Micros::from_secs(1),
            loss_hold: Micros::from_secs(1),
            loss_bin: Micros::from_millis(500),
            loss_history: Micros::from_secs(20),
            loss_excess: 0.05,
            loss_rate_spread: 1.2,
            loss_min_packets: 40,
            loss_congestion_max: 0.4,
            loss_probe_factor: 0.75,
            loss_probe_wait: Micros::from_secs(5),
            loss_head_gap: Micros::from_millis(5),
            fec_loss_window: Micros::from_secs(2),
            group_span: Micros::from_millis(5),
            trend_window: 20,
            trend_smoothing: 0.9,
            threshold_gain: 4.0,
            delivered_window: Micros::from_millis(500),
            capacity_bucket: Micros::from_millis(200),
            capacity_window: Micros::from_secs(3),
            pacing_factor: 1.8,
            bottleneck_pacing: 1.1,
            bottleneck_hold: Micros::from_secs(30),
            queue_window: Micros::from_millis(200),
            base_window: Micros::from_secs(10),
            queue_threshold: Micros::from_millis(15),
            standing_queue: Micros::from_millis(30),
            standing_hold: Micros::from_millis(250),
            jitter_queue: 1.5,
            rtt_queue_slack: Micros::from_millis(5),
            rtt_queue_margin: Micros::from_millis(10),
            rtt_queue_window: Micros::from_millis(100),
        }
    }
}

/// One media datagram's fate, from transport-wide feedback.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PacketResult {
    pub tseq: u64,
    /// Sender clock.
    pub send_time: Micros,
    /// Bytes on the wire (datagram size).
    pub size: u32,
    /// Receiver clock (unwrapped); None = not received.
    pub arrival: Option<Micros>,
}

/// The delay detector's verdict.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum BandwidthUsage {
    #[default]
    Normal,
    Overuse,
    Underuse,
}

/// What sustained heavy loss looks like ([`RateConfig::loss_bin`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LossKind {
    /// With a standing / growing queue, growing with the sending rate, or above `loss_congestion_max`: cut.
    Congestion,
    /// The same at a clearly lower and a clearly higher sending rate, with no queue: FEC and NACKs carry it, the
    /// rate stays (and may grow: a real bottleneck shows a queue or rate-dependent loss).
    Random,
    /// Not enough to tell (the rate hardly varied, few packets): probed (`loss_probe_factor`).
    Unknown,
}

/// Why the target last changed (stats / logs).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RateChange {
    Increase,
    DelayDecrease,
    LossDecrease,
    Profile,
    PersistentCongestion,
}

#[derive(Clone, Copy, Debug)]
struct Group {
    first_send: Micros,
    last_send: Micros,
    last_arrival: Micros,
}

/// Packets → groups → (send delta, arrival delta) between consecutive complete groups.
#[derive(Debug, Default)]
struct InterArrival {
    current: Option<Group>,
    prev: Option<Group>,
}

impl InterArrival {
    /// A received packet (in send order). Returns `(send_delta_ms, arrival_delta_ms, arrival_ms)` when it completed
    /// a group.
    fn packet(&mut self, span: Micros, send: Micros, arrival: Micros) -> Option<(f64, f64, Micros)> {
        let Some(cur) = self.current.as_mut() else {
            self.current = Some(Group { first_send: send, last_send: send, last_arrival: arrival });
            return None;
        };
        if send < cur.first_send {
            return None; // reordered from an older group
        }
        let in_span = send - cur.first_send <= span;
        // An arrival burst (queued packets released together) belongs to the group too.
        let arrival_gap = arrival.signed_since(cur.last_arrival);
        let send_gap = send.signed_since(cur.last_send);
        let burst = arrival_gap >= 0 && arrival_gap <= span.0 as i64 && arrival_gap - send_gap < 0;
        if in_span || burst {
            cur.last_send = cur.last_send.max(send);
            cur.last_arrival = cur.last_arrival.max(arrival);
            return None;
        }
        let done = *cur;
        self.current = Some(Group { first_send: send, last_send: send, last_arrival: arrival });
        let prev = self.prev.replace(done);
        let prev = prev?;
        let send_delta = done.last_send.signed_since(prev.last_send) as f64 / 1000.0;
        let arrival_delta = done.last_arrival.signed_since(prev.last_arrival) as f64 / 1000.0;
        if (arrival_delta - send_delta).abs() > 3000.0 || arrival_delta < 0.0 {
            // a clock jump or a long blackout: start over
            self.prev = None;
            return None;
        }
        Some((send_delta, arrival_delta, done.last_arrival))
    }
}

/// Trendline estimator + adaptive-threshold overuse detector (WebRTC's, with the spec's constants).
#[derive(Debug)]
struct Trendline {
    window_size: usize,
    smoothing: f64,
    gain: f64,
    window: VecDeque<(f64, f64)>,
    accumulated: f64,
    smoothed: f64,
    first_arrival: Option<Micros>,
    num_deltas: usize,
    prev_trend: f64,
    threshold: f64,
    last_threshold_update: Option<Micros>,
    time_over_using: f64,
    overuse_counter: usize,
    state: BandwidthUsage,
    modified: f64,
}

impl Trendline {
    fn new(cfg: &RateConfig) -> Trendline {
        Trendline {
            window_size: cfg.trend_window.max(2),
            smoothing: cfg.trend_smoothing,
            gain: cfg.threshold_gain,
            window: VecDeque::new(),
            accumulated: 0.0,
            smoothed: 0.0,
            first_arrival: None,
            num_deltas: 0,
            prev_trend: 0.0,
            threshold: 12.5,
            last_threshold_update: None,
            time_over_using: -1.0,
            overuse_counter: 0,
            state: BandwidthUsage::Normal,
            modified: 0.0,
        }
    }

    fn update(&mut self, send_delta_ms: f64, arrival_delta_ms: f64, arrival: Micros) {
        let delta = arrival_delta_ms - send_delta_ms;
        self.num_deltas = (self.num_deltas + 1).min(1000);
        self.accumulated += delta;
        self.smoothed = self.smoothing * self.smoothed + (1.0 - self.smoothing) * self.accumulated;
        let first = *self.first_arrival.get_or_insert(arrival);
        let x = arrival.signed_since(first) as f64 / 1000.0;
        self.window.push_back((x, self.smoothed));
        while self.window.len() > self.window_size {
            self.window.pop_front();
        }
        let mut trend = self.prev_trend;
        if self.window.len() == self.window_size
            && let Some(slope) = linear_fit_slope(&self.window)
        {
            trend = slope;
        }
        self.detect(trend, send_delta_ms, arrival);
    }

    fn detect(&mut self, trend: f64, send_delta_ms: f64, now: Micros) {
        if self.num_deltas < 2 {
            self.state = BandwidthUsage::Normal;
            return;
        }
        let modified = self.num_deltas.min(60) as f64 * trend * self.gain;
        self.modified = modified;
        if modified > self.threshold {
            if self.time_over_using < 0.0 {
                self.time_over_using = send_delta_ms / 2.0;
            } else {
                self.time_over_using += send_delta_ms;
            }
            self.overuse_counter += 1;
            if self.time_over_using > 10.0 && self.overuse_counter > 1 && trend >= self.prev_trend {
                self.time_over_using = 0.0;
                self.overuse_counter = 0;
                self.state = BandwidthUsage::Overuse;
            }
        } else if modified < -self.threshold {
            self.time_over_using = -1.0;
            self.overuse_counter = 0;
            self.state = BandwidthUsage::Underuse;
        } else {
            self.time_over_using = -1.0;
            self.overuse_counter = 0;
            self.state = BandwidthUsage::Normal;
        }
        self.prev_trend = trend;
        self.update_threshold(modified, now);
    }

    fn update_threshold(&mut self, modified: f64, now: Micros) {
        let last = *self.last_threshold_update.get_or_insert(now);
        if modified.abs() > self.threshold + 15.0 {
            // a sudden spike (e.g. a route change) shouldn't drag the threshold up
            self.last_threshold_update = Some(now);
            return;
        }
        let k = if modified.abs() < self.threshold { 0.039 } else { 0.0087 };
        let dt = (now.signed_since(last).max(0) as f64 / 1000.0).min(100.0);
        self.threshold = (self.threshold + k * (modified.abs() - self.threshold) * dt).clamp(6.0, 600.0);
        self.last_threshold_update = Some(now);
    }
}

fn linear_fit_slope(points: &VecDeque<(f64, f64)>) -> Option<f64> {
    let n = points.len() as f64;
    let (sx, sy) = points.iter().fold((0.0, 0.0), |(a, b), p| (a + p.0, b + p.1));
    let (mx, my) = (sx / n, sy / n);
    let (mut num, mut den) = (0.0, 0.0);
    for (x, y) in points {
        num += (x - mx) * (y - my);
        den += (x - mx) * (x - mx);
    }
    (den != 0.0).then(|| num / den)
}

/// Link capacity estimate from the delivered rate at overuse (WebRTC's), in kbps.
#[derive(Debug, Default)]
struct LinkCapacity {
    estimate_kbps: Option<f64>,
    var: f64,
}

impl LinkCapacity {
    fn on_overuse(&mut self, delivered_bps: f64) {
        let x = delivered_bps / 1000.0;
        let alpha = 0.05;
        let est = match self.estimate_kbps {
            None => x,
            Some(e) => (1.0 - alpha) * e + alpha * x,
        };
        let norm = est.max(1.0);
        let err = est - x;
        self.var = ((1.0 - alpha) * self.var + alpha * err * err / norm).clamp(0.4, 2.5);
        self.estimate_kbps = Some(est);
    }

    fn dev_kbps(&self) -> f64 {
        self.estimate_kbps.map_or(0.0, |e| (self.var * e).sqrt())
    }

    /// The target is within 3 deviations of the estimate.
    fn near(&self, bps: f64) -> bool {
        self.estimate_kbps.is_some_and(|e| {
            let k = bps / 1000.0;
            (k - e).abs() <= 3.0 * self.dev_kbps()
        })
    }

    fn above(&self, bps: f64) -> bool {
        self.estimate_kbps.is_some_and(|e| bps / 1000.0 > e + 3.0 * self.dev_kbps())
    }
}

/// The rate controller. Sans-IO: every call carries `now`.
#[derive(Debug)]
pub struct RateController {
    cfg: RateConfig,
    target: f64,
    handle: TargetRate,
    profile: NetworkProfile,
    inter: InterArrival,
    trend: Trendline,
    capacity: LinkCapacity,
    rtt: Micros,
    /// Round-trip floors over `base_window`: (when, the lowest round trip of the acks since the one before), on
    /// the sender's clock.
    rtts: VecDeque<(Micros, Micros)>,
    last_update: Option<Micros>,
    last_decrease: Option<Micros>,
    last_key: Option<Micros>,
    ceiling: Option<(f64, Micros)>,
    loss_high_since: Option<Micros>,
    /// (feedback time, received, lost) per feedback.
    loss: VecDeque<(Micros, u32, u32)>,
    /// Every feedback's received / lost media datagrams so far (the stats' interval loss).
    loss_totals: (u64, u64),
    /// Per `loss_bin` of send time: (bin start, bytes handed to the transport, received, lost).
    loss_bins: VecDeque<(Micros, u64, u32, u32)>,
    /// The verdict on the current heavy loss (None: loss isn't heavy).
    loss_kind: Option<LossKind>,
    /// Per feedback: (time, burst heads, lost of those, the rest, lost of those) over `loss_history`; and the
    /// previous result's (tseq, send time).
    loss_heads: VecDeque<(Micros, u32, u32, u32, u32)>,
    prev_result: Option<(u64, Micros)>,
    /// The loss last told random (the pooled loss of the history then).
    random_loss: Option<f64>,
    /// A probe for unknown loss holds the rate until then.
    loss_probe_until: Option<Micros>,
    /// (arrival on receiver clock, bytes).
    delivered: VecDeque<(Micros, u32)>,
    delivered_bytes: u64,
    /// (send time, bytes).
    sent: VecDeque<(Micros, u32)>,
    sent_bytes: u64,
    /// One-way delay (arrival − send, µs, offset unknown) per 100 ms bucket of arrival time: (bucket, lowest, highest).
    owd: VecDeque<(Micros, i64, i64)>,
    standing_since: Option<Micros>,
    /// Delivered bytes per `capacity_bucket` of arrival time (receiver clock), oldest first.
    capacity_buckets: VecDeque<(Micros, u64)>,
    /// The capacity measured at the last congestion decrease, and until when it bounds pacing.
    bottleneck: Option<(f64, Micros)>,
    /// A delay-based decrease answered the current overuse verdict.
    overuse_answered: bool,
    last_change: Option<RateChange>,
    decreases: u64,
    loss_decreases: u64,
    held_decreases: u64,
    jitter_holds: u64,
    random_loss_holds: u64,
}

impl RateController {
    pub fn new(cfg: RateConfig) -> RateController {
        let start = cfg.start_bps.clamp(cfg.min_bps, cfg.max_bps) as f64;
        RateController {
            trend: Trendline::new(&cfg),
            handle: TargetRate::new(start as u64),
            target: start,
            cfg,
            profile: NetworkProfile::Default,
            inter: InterArrival::default(),
            capacity: LinkCapacity::default(),
            rtt: Micros::from_millis(100),
            rtts: VecDeque::new(),
            last_update: None,
            last_decrease: None,
            last_key: None,
            ceiling: None,
            loss_high_since: None,
            loss: VecDeque::new(),
            loss_totals: (0, 0),
            loss_bins: VecDeque::new(),
            loss_kind: None,
            loss_heads: VecDeque::new(),
            prev_result: None,
            random_loss: None,
            loss_probe_until: None,
            delivered: VecDeque::new(),
            delivered_bytes: 0,
            sent: VecDeque::new(),
            sent_bytes: 0,
            owd: VecDeque::new(),
            standing_since: None,
            capacity_buckets: VecDeque::new(),
            bottleneck: None,
            overuse_answered: false,
            last_change: None,
            decreases: 0,
            loss_decreases: 0,
            held_decreases: 0,
            jitter_holds: 0,
            random_loss_holds: 0,
        }
    }

    pub fn config(&self) -> &RateConfig {
        &self.cfg
    }

    /// The shared handle for the transport's congestion controller.
    pub fn handle(&self) -> TargetRate {
        self.handle.clone()
    }

    pub fn target_bps(&self) -> u64 {
        self.target as u64
    }

    pub fn profile(&self) -> NetworkProfile {
        self.profile
    }

    pub fn usage(&self) -> BandwidthUsage {
        self.trend.state
    }

    /// Decreases so far (all causes), loss-based ones among them, delay-based ones held back (key-frame grace or
    /// content-limited), and overuse verdicts ignored for want of a standing queue (jitter).
    pub fn decreases(&self) -> (u64, u64, u64, u64) {
        (self.decreases, self.loss_decreases, self.held_decreases, self.jitter_holds)
    }

    /// Loss-based decreases not made because the loss was random (once per `loss_hold`).
    pub fn random_loss_holds(&self) -> u64 {
        self.random_loss_holds
    }

    /// The verdict on the current heavy loss (None: loss is below `loss_threshold`).
    pub fn loss_kind(&self) -> Option<LossKind> {
        self.loss_kind
    }

    pub fn last_change(&self) -> Option<RateChange> {
        self.last_change
    }

    /// The highest rate the profile allows.
    pub fn max_bps(&self) -> u64 {
        match self.profile {
            NetworkProfile::Lan => self.cfg.lan_max_bps,
            NetworkProfile::Constrained => self.cfg.constrained_max_bps.min(self.cfg.max_bps),
            NetworkProfile::Default | NetworkProfile::Cellular => self.cfg.max_bps,
        }
        .max(self.cfg.min_bps)
    }

    /// The remembered ceiling, if it still holds.
    pub fn ceiling_bps(&self, now: Micros) -> Option<u64> {
        self.ceiling.filter(|c| now < c.1).map(|c| c.0 as u64)
    }

    pub fn set_rtt(&mut self, rtt: Micros) {
        self.rtt = rtt.max(Micros(1000));
    }

    /// A round-trip floor: the lowest round trip among the transport's acks since the last call (QUIC's
    /// `now − sent` of every acked packet; before each feedback, when there were acks). The lowest of a stretch
    /// leaves delayed acks out and follows a queue within that stretch, which a smoothed round trip does not. It
    /// tells a queue from clocks running at different rates ([`RateConfig::rtt_queue_slack`]). Not for a round
    /// trip probed now and then (ICE's): a stale value would hide a real queue.
    pub fn set_rtt_floor(&mut self, now: Micros, rtt: Micros) {
        self.rtts.push_back((now, rtt));
        while self.rtts.front().is_some_and(|r| now - r.0 > self.cfg.base_window) {
            self.rtts.pop_front();
        }
    }

    /// A (new) network profile; a lower cap steps the rate down at once.
    pub fn set_profile(&mut self, now: Micros, profile: NetworkProfile) {
        self.profile = profile;
        if self.target > self.max_bps() as f64 {
            self.target = self.max_bps() as f64;
            self.last_change = Some(RateChange::Profile);
        }
        self.publish(now);
    }

    /// A key frame went out (starts the grace period for delay-based decreases).
    pub fn on_key_frame(&mut self, now: Micros) {
        self.last_key = Some(now);
    }

    /// A media datagram of `size` bytes was handed to the transport.
    pub fn on_sent(&mut self, now: Micros, size: u32) {
        self.sent.push_back((now, size));
        self.sent_bytes += size as u64;
        self.trim_sent(now);
        self.loss_bin_mut(now).1 += size as u64;
    }

    /// The loss bin of send time `at` (created if new; a time older than the oldest kept bin gets the oldest).
    fn loss_bin_mut(&mut self, at: Micros) -> &mut (Micros, u64, u32, u32) {
        let b = self.cfg.loss_bin.0.max(1);
        let bin = Micros(at.0 / b * b);
        if self.loss_bins.back().is_none_or(|last| last.0 < bin) {
            self.loss_bins.push_back((bin, 0, 0, 0));
            while self.loss_bins.front().is_some_and(|f| bin - f.0 > self.cfg.loss_history) {
                self.loss_bins.pop_front();
            }
        }
        let i = self.loss_bins.iter().rposition(|e| e.0 <= bin).unwrap_or(0);
        &mut self.loss_bins[i]
    }

    /// Is the loss now more than it was at a clearly lower sending rate? The recent bins (the newest two done and
    /// with feedback) against the older ones of `loss_history`. `Some((true, _))`: more by more than `loss_excess`
    /// and 3 standard errors — congestion; `Some((false, loss))`: no more than at a clearly lower rate, or no
    /// less than at a clearly higher one — random (the loss of both); None: can't tell (only higher rates in the
    /// history, and they lost more: a congestion that may be over, or one still going on — probe).
    fn loss_grows_with_rate(&self, now: Micros) -> Option<(bool, f64)> {
        let secs = self.cfg.loss_bin.as_secs_f64();
        // bins whose sending is over (a younger one's rate reads low) and with feedback
        let mut bins = self.loss_bins.iter().rev().filter(|e| e.0 + self.cfg.loss_bin <= now && e.2 + e.3 > 0);
        // (bytes, received, lost)
        let add = |a: (u64, u32, u32), e: &(Micros, u64, u32, u32)| (a.0 + e.1, a.1 + e.2, a.2 + e.3);
        let recent = bins.by_ref().take(2).fold((0, 0, 0), add);
        let n_cur = recent.1 + recent.2;
        if n_cur < self.cfg.loss_min_packets {
            return None;
        }
        let rate_cur = recent.0 as f64 * 8.0 / (2.0 * secs);
        let spread = self.cfg.loss_rate_spread;
        let (mut lower, mut higher) = ((0, 0, 0), (0, 0, 0));
        for e in bins {
            let rate = e.1 as f64 * 8.0 / secs;
            if rate * spread <= rate_cur {
                lower = add(lower, e);
            } else if rate >= spread * rate_cur {
                higher = add(higher, e);
            }
        }
        let l_cur = recent.2 as f64 / n_cur as f64;
        let compare = |other: (u64, u32, u32)| -> Option<(f64, f64, f64)> {
            let n = other.1 + other.2;
            if n < self.cfg.loss_min_packets {
                return None;
            }
            let l = other.2 as f64 / n as f64;
            let pooled = (recent.2 + other.2) as f64 / (n_cur + n) as f64;
            let se = (pooled * (1.0 - pooled) * (1.0 / n_cur as f64 + 1.0 / n as f64)).sqrt();
            Some((l, pooled, self.cfg.loss_excess.max(3.0 * se)))
        };
        if let Some((l_lo, pooled, margin)) = compare(lower) {
            return Some((l_cur - l_lo > margin, pooled));
        }
        match compare(higher) {
            Some((l_hi, pooled, margin)) if l_hi - l_cur <= margin => Some((false, pooled)),
            _ => None,
        }
    }

    /// The loss spares the bursts' heads (`loss_head_gap`) over the history.
    fn loss_spares_heads(&self) -> bool {
        let (h, h_lost, r, r_lost) =
            self.loss_heads.iter().fold((0, 0, 0, 0), |a, e| (a.0 + e.1, a.1 + e.2, a.2 + e.3, a.3 + e.4));
        if h < self.cfg.loss_min_packets || r < self.cfg.loss_min_packets {
            return false;
        }
        let (l_h, l_r) = (h_lost as f64 / h as f64, r_lost as f64 / r as f64);
        let p = (h_lost + r_lost) as f64 / (h + r) as f64;
        let se = (p * (1.0 - p) * (1.0 / h as f64 + 1.0 / r as f64)).sqrt();
        l_r - l_h > self.cfg.loss_excess.max(3.0 * se)
    }

    /// The current heavy loss (above `loss_threshold` over `loss_window`) and what it looks like; with
    /// `Some(pooled)` when the history just told it random.
    fn classify_loss(&self, now: Micros) -> Option<(f64, LossKind, Option<f64>)> {
        let (r, l) = self.loss_over(now, self.cfg.loss_window);
        let n = r + l;
        let loss = if n >= 10 { l as f64 / n as f64 } else { 0.0 };
        if loss <= self.cfg.loss_threshold {
            return None;
        }
        if loss > self.cfg.loss_congestion_max || self.loss_spares_heads() {
            return Some((loss, LossKind::Congestion, None));
        }
        // a queue is the delay rule's to answer; it makes loss congestion only when the loss isn't told random
        let queued = self.queue_delay().is_some_and(|q| q > self.queue_bar(self.cfg.queue_threshold))
            || self.trend.state == BandwidthUsage::Overuse;
        Some(match self.loss_grows_with_rate(now) {
            Some((true, _)) => (loss, LossKind::Congestion, None),
            Some((false, pooled)) => (loss, LossKind::Random, Some(pooled)),
            None => {
                let margin = self.cfg.loss_excess.max(3.0 * (loss * (1.0 - loss) / n as f64).sqrt());
                let known = self.random_loss.is_some_and(|known| loss <= known + margin);
                let kind = if known && !queued {
                    LossKind::Random
                } else if queued {
                    LossKind::Congestion
                } else {
                    LossKind::Unknown
                };
                (loss, kind, None)
            }
        })
    }

    fn trim_sent(&mut self, now: Micros) {
        while let Some(&(at, b)) = self.sent.front() {
            if now - at > self.cfg.sent_window {
                self.sent.pop_front();
                self.sent_bytes -= b as u64;
            } else {
                break;
            }
        }
    }

    /// What was handed to the transport over the last second (bits/s).
    pub fn sent_bps(&mut self, now: Micros) -> u64 {
        self.trim_sent(now);
        (self.sent_bytes as f64 * 8.0 / self.cfg.sent_window.as_secs_f64()) as u64
    }

    /// The receiver's delivered rate over the last `delivered_window` of arrivals (bits/s).
    pub fn delivered_bps(&self) -> u64 {
        (self.delivered_bytes as f64 * 8.0 / self.cfg.delivered_window.as_secs_f64()) as u64
    }

    /// Pre-FEC loss over the last `window` of feedback.
    fn loss_over(&self, now: Micros, window: Micros) -> (u32, u32) {
        self.loss.iter().rev().take_while(|e| now - e.0 <= window).fold((0, 0), |(r, l), e| (r + e.1, l + e.2))
    }

    /// Media datagrams the receiver reported received / lost, since the start.
    pub fn loss_totals(&self) -> (u64, u64) {
        self.loss_totals
    }

    /// Pre-FEC loss fraction over the last 2 s (the FEC policy's `L`).
    pub fn fec_loss(&self, now: Micros) -> f64 {
        let (r, l) = self.loss_over(now, self.cfg.fec_loss_window);
        if r + l == 0 { 0.0 } else { l as f64 / (r + l) as f64 }
    }

    fn note_owd(&mut self, arrival: Micros, owd: i64) {
        const BUCKET: u64 = 100_000;
        let bucket = Micros(arrival.0 / BUCKET * BUCKET);
        let note = |e: &mut (Micros, i64, i64)| {
            e.1 = e.1.min(owd);
            e.2 = e.2.max(owd);
        };
        match self.owd.back_mut() {
            Some(b) if b.0 == bucket => note(b),
            Some(b) if b.0 > bucket => {
                // reordered into an older bucket
                if let Some(e) = self.owd.iter_mut().rev().find(|e| e.0 <= bucket) {
                    note(e);
                }
            }
            _ => self.owd.push_back((bucket, owd, owd)),
        }
        while self.owd.front().is_some_and(|b| bucket - b.0 > self.cfg.base_window) {
            self.owd.pop_front();
        }
    }

    fn note_capacity(&mut self, arrival: Micros, size: u32) {
        let b = self.cfg.capacity_bucket.0.max(1);
        let bucket = Micros(arrival.0 / b * b);
        match self.capacity_buckets.back_mut() {
            Some(last) if last.0 == bucket => last.1 += size as u64,
            Some(last) if last.0 > bucket => {
                if let Some(e) = self.capacity_buckets.iter_mut().rev().find(|e| e.0 == bucket) {
                    e.1 += size as u64;
                }
            }
            _ => self.capacity_buckets.push_back((bucket, size as u64)),
        }
        while self.capacity_buckets.front().is_some_and(|e| bucket - e.0 > self.cfg.capacity_window) {
            self.capacity_buckets.pop_front();
        }
    }

    /// The link capacity estimate (bits/s): the best complete bucket of the last `capacity_window`. (A higher
    /// one also lifts the bottleneck bound on pacing: see `on_feedback`.)
    pub fn capacity_bps(&self) -> Option<u64> {
        let n = self.capacity_buckets.len();
        let secs = self.cfg.capacity_bucket.as_secs_f64();
        self.capacity_buckets.iter().take(n.saturating_sub(1)).map(|e| (e.1 as f64 * 8.0 / secs) as u64).max()
    }

    /// The path's jitter: the median spread of one-way delays within a 100 ms bucket over `base_window`.
    pub fn jitter(&self) -> Micros {
        let mut spreads: Vec<i64> = self.owd.iter().map(|b| b.2 - b.1).collect();
        if spreads.is_empty() {
            return Micros::ZERO;
        }
        let mid = spreads.len() / 2;
        Micros(*spreads.select_nth_unstable(mid).1 as u64)
    }

    /// `threshold`, raised on a jittery path.
    fn queue_bar(&self, threshold: Micros) -> Micros {
        threshold.max(self.jitter().mul_f64(self.cfg.jitter_queue))
    }

    /// The queue is going down: the newest 100 ms of one-way delays sit clearly below those 300 ms earlier.
    fn queue_draining(&self) -> bool {
        let n = self.owd.len();
        if n < 4 {
            return false;
        }
        let (newest, earlier) = (self.owd[n - 1], self.owd[n - 4]);
        newest.0 - earlier.0 <= Micros::from_millis(300) && newest.1 + 3_000 < earlier.1
    }

    /// How fast video should be released to the transport (bits/s).
    pub fn pacing_bps(&self, now: Micros) -> u64 {
        let mut rate = self.cfg.pacing_factor * self.target;
        if let Some((cap, until)) = self.bottleneck
            && now < until
        {
            rate = rate.min(self.cfg.bottleneck_pacing * cap);
        }
        rate.max(1.1 * self.target) as u64
    }

    /// The standing queue: lowest one-way delay over the last `queue_window` − lowest over `base_window`; what the
    /// round trip has room for instead, when the one-way delays claim clearly more ([`RateConfig::rtt_queue_slack`]).
    pub fn queue_delay(&self) -> Option<Micros> {
        let q = self.owd_queue()?;
        // the one-way delays claim clearly more than the round trip has room for: the clocks, not a queue
        Some(self.rtt_queue().filter(|&r| q > r + self.cfg.rtt_queue_margin).unwrap_or(q))
    }

    /// The standing queue as the one-way delays have it (two clocks).
    fn owd_queue(&self) -> Option<Micros> {
        let newest = self.owd.back()?.0;
        let base = self.owd.iter().map(|b| b.1).min()?;
        let recent = self.owd.iter().rev().take_while(|b| newest - b.0 < self.cfg.queue_window).map(|b| b.1).min()?;
        Some(Micros((recent - base).max(0) as u64))
    }

    /// The most the round trip (one clock) allows the standing queue to be: the lowest floor of the last
    /// `rtt_queue_window` − the lowest of `base_window`, plus a slack — `rtt_queue_slack`, or how far the floors
    /// usually sit above their lowest (their median: on a path whose delay wanders the lowest round trip is rarer
    /// than the lowest one-way delay, both directions have to be at their best at once). None without round-trip
    /// floors, or when the newest is older than a second.
    fn rtt_queue(&self) -> Option<Micros> {
        let at = self.rtts.back()?.0;
        if self.last_update.is_some_and(|t| t > at + Micros::from_secs(1)) {
            return None;
        }
        let recent = self.rtts.iter().rev().take_while(|r| at - r.0 < self.cfg.rtt_queue_window).map(|r| r.1).min()?;
        let mut floors: Vec<Micros> = self.rtts.iter().map(|r| r.1).collect();
        let mid = floors.len() / 2;
        let median = *floors.select_nth_unstable(mid).1;
        let base = *floors.iter().min()?;
        Some(recent - base + self.cfg.rtt_queue_slack.max(median - base))
    }

    fn content_limited(&mut self, now: Micros) -> bool {
        (self.sent_bps(now) as f64) < self.cfg.content_limited * self.target
    }

    /// No congestion seen yet this session (no decrease, no remembered ceiling): the startup increase applies.
    pub fn in_startup(&self) -> bool {
        self.last_decrease.is_none() && self.ceiling.is_none()
    }

    /// Transport-wide feedback: results in tseq order.
    pub fn on_feedback(&mut self, now: Micros, results: &[PacketResult]) {
        let (mut received, mut lost) = (0u32, 0u32);
        // (heads, lost heads, rest, lost rest)
        let mut heads = (0u32, 0u32, 0u32, 0u32);
        for r in results {
            let is_lost = r.arrival.is_none() as u32;
            if let Some((prev, at)) = self.prev_result
                && r.tseq == prev + 1
            {
                if r.send_time.signed_since(at) >= self.cfg.loss_head_gap.0 as i64 {
                    heads.0 += 1;
                    heads.1 += is_lost;
                } else {
                    heads.2 += 1;
                    heads.3 += is_lost;
                }
            }
            self.prev_result = Some((r.tseq, r.send_time));
            let Some(arrival) = r.arrival else {
                lost += 1;
                self.loss_bin_mut(r.send_time).3 += 1;
                continue;
            };
            received += 1;
            self.loss_bin_mut(r.send_time).2 += 1;
            self.note_owd(arrival, arrival.signed_since(r.send_time));
            self.delivered.push_back((arrival, r.size));
            self.note_capacity(arrival, r.size);
            self.delivered_bytes += r.size as u64;
            if let Some((sd, ad, at)) = self.inter.packet(self.cfg.group_span, r.send_time, arrival) {
                self.trend.update(sd, ad, at);
            }
        }
        if let Some(&(newest, _)) = self.delivered.back() {
            while let Some(&(at, b)) = self.delivered.front() {
                if newest - at > self.cfg.delivered_window {
                    self.delivered.pop_front();
                    self.delivered_bytes -= b as u64;
                } else {
                    break;
                }
            }
        }
        if received + lost > 0 {
            self.loss_heads.push_back((now, heads.0, heads.1, heads.2, heads.3));
            while self.loss_heads.front().is_some_and(|e| now - e.0 > self.cfg.loss_history) {
                self.loss_heads.pop_front();
            }
            self.loss.push_back((now, received, lost));
            self.loss_totals.0 += received as u64;
            self.loss_totals.1 += lost as u64;
        }
        if let (Some((cap, until)), Some(measured)) = (self.bottleneck, self.capacity_bps())
            && measured as f64 > cap
        {
            self.bottleneck = Some((measured as f64, until));
        }
        let keep = self.cfg.fec_loss_window.max(self.cfg.loss_window);
        while self.loss.front().is_some_and(|e| now - e.0 > keep) {
            self.loss.pop_front();
        }
        self.update(now);
    }

    fn update(&mut self, now: Micros) {
        let dt = self.last_update.map_or(Micros::ZERO, |t| now - t).min(Micros::from_secs(1));
        self.last_update = Some(now);
        let before = self.target;
        if self.trend.state != BandwidthUsage::Overuse {
            self.overuse_answered = false;
        }
        let standing =
            self.queue_delay().is_some_and(|q| q > self.queue_bar(self.cfg.standing_queue)) && !self.queue_draining();
        if !standing {
            self.standing_since = None;
        }
        let verdict = self.classify_loss(now);
        self.loss_kind = verdict.map(|c| c.1);
        match verdict {
            Some((_, LossKind::Random, told)) => {
                if told.is_some() {
                    self.random_loss = told;
                }
                self.loss_probe_until = None;
            }
            Some((_, LossKind::Congestion, _)) => self.random_loss = None,
            _ => {}
        }
        let since = if standing { *self.standing_since.get_or_insert(now) } else { now };
        if standing && now - since >= self.cfg.standing_hold {
            self.standing_decrease(now);
        } else {
            // The trendline alone reads a jittery path as over- or underuse most of the time; without a queue
            // above the (jitter-raised) bar it isn't one, and the rate may grow.
            let queued = self.queue_delay().is_some_and(|q| q > self.queue_bar(self.cfg.queue_threshold));
            match self.trend.state {
                BandwidthUsage::Overuse => self.delay_decrease(now),
                BandwidthUsage::Underuse if !queued && !standing => self.increase(now, dt),
                BandwidthUsage::Underuse => {}
                // a standing queue that isn't growing: no increase either
                BandwidthUsage::Normal if !standing => self.increase(now, dt),
                BandwidthUsage::Normal => {}
            }
        }
        self.loss_decrease(now);
        self.target = self.target.clamp(self.cfg.min_bps as f64, self.max_bps() as f64);
        if self.target > before {
            self.last_change = Some(RateChange::Increase);
        }
        self.publish(now);
    }

    fn in_key_grace(&self, now: Micros) -> bool {
        self.last_key.is_some_and(|k| now - k < self.cfg.key_grace)
    }

    fn delay_decrease(&mut self, now: Micros) {
        let interval = self.rtt.clamp(Micros::from_millis(10), Micros::from_millis(200));
        let delivered = self.delivered_bps() as f64;
        let collapsed = self.capacity.estimate_kbps.is_some_and(|e| delivered / 1000.0 < 0.5 * e);
        // one decrease per overuse episode: the detector has to leave overuse (the queue drained) first
        let spaced = self.last_decrease.is_none_or(|t| now - t >= interval);
        let due = spaced && (!self.overuse_answered || collapsed);
        if !due {
            return;
        }
        let queued = self.queue_delay().is_some_and(|q| q > self.queue_bar(self.cfg.queue_threshold));
        if queued && let Some(c) = self.capacity_bps() {
            // a real queue, even if its cause (a key frame) is forgiven: don't release bursts faster than the
            // bottleneck drains them
            let c = (c as f64).max(delivered);
            let until = now + self.cfg.bottleneck_hold;
            self.bottleneck = Some((self.bottleneck.filter(|b| now < b.1).map_or(c, |b| b.0.max(c)), until));
        }
        if self.in_key_grace(now) || self.content_limited(now) {
            self.held_decreases += 1;
            return;
        }
        if !queued {
            self.jitter_holds += 1;
            return;
        }
        // toward the measured capacity: right after a burst the delivered rate is the sending rate, not the link's
        let capacity = self.capacity_bps().map_or(delivered, |c| (c as f64).max(delivered));
        self.overuse_answered = true;
        let new = self.target_for(now, self.cfg.decrease_factor * capacity);
        if new >= self.target {
            // the target already sits below the capacity: the queue was a burst's (a standing one is caught below)
            self.held_decreases += 1;
            return;
        }
        self.capacity.on_overuse(capacity);
        self.bottleneck = Some((capacity, now + self.cfg.bottleneck_hold));
        self.apply_decrease(now, new, capacity, RateChange::DelayDecrease);
    }

    /// The target that makes the stream *send* `goal` (bits/s): what goes out runs above the target when the
    /// encoder overshoots (large, key and recovery frames), parity rounds up on small blocks, retransmits and
    /// audio come on top — measured as the sent / target ratio over the last second (never below 1).
    fn target_for(&mut self, now: Micros, goal: f64) -> f64 {
        let overshoot = (self.sent_bps(now) as f64 / self.target.max(1.0)).max(1.0);
        goal / overshoot
    }

    fn standing_decrease(&mut self, now: Micros) {
        if self.content_limited(now) {
            self.held_decreases += 1;
            return;
        }
        self.standing_since = Some(now); // the next one needs another sustained stretch
        // a standing queue keeps the link busy: the delivered rate is its capacity now
        let delivered = self.delivered_bps() as f64;
        self.capacity.on_overuse(delivered);
        self.bottleneck = Some((delivered, now + self.cfg.bottleneck_hold));
        let new = self.target_for(now, self.cfg.decrease_factor * delivered);
        self.apply_decrease(now, new, delivered, RateChange::DelayDecrease);
    }

    fn loss_decrease(&mut self, now: Micros) {
        let Some((loss, kind, _)) = self.classify_loss(now) else {
            self.loss_high_since = None;
            return;
        };
        let since = *self.loss_high_since.get_or_insert(now);
        if now - since < self.cfg.loss_hold {
            return;
        }
        self.loss_high_since = Some(now);
        match kind {
            LossKind::Random => {
                self.random_loss_holds += 1;
                return;
            }
            LossKind::Unknown if self.loss_probing(now) => return,
            LossKind::Unknown => {
                // step down once and hold: the slower stretch then tells random from congestion
                self.loss_probe_until = Some(now + self.cfg.loss_probe_wait);
                self.loss_decreases += 1;
                let new = self.target * self.cfg.loss_probe_factor.min(1.0 - 0.5 * loss);
                self.apply_decrease(now, new, 0.0, RateChange::LossDecrease);
                return;
            }
            LossKind::Congestion => {}
        }
        self.loss_decreases += 1;
        self.apply_decrease(now, self.target * (1.0 - 0.5 * loss), 0.0, RateChange::LossDecrease);
    }

    /// A probe for unknown loss is holding the rate.
    fn loss_probing(&self, now: Micros) -> bool {
        self.loss_probe_until.is_some_and(|t| now < t)
    }

    /// `capacity`: the measured link capacity behind a delay-based decrease (0: none).
    fn apply_decrease(&mut self, now: Micros, new: f64, capacity: f64, why: RateChange) {
        let new = new.max(self.cfg.min_bps as f64);
        if new >= self.target {
            return;
        }
        let overshoot = (self.sent_bps(now) as f64 / self.target.max(1.0)).max(1.0);
        self.set_ceiling(now, new, capacity / overshoot);
        self.target = new;
        self.last_decrease = Some(now);
        self.last_change = Some(why);
        self.decreases += 1;
    }

    /// The remembered ceiling after a decrease to `new`: `ceiling_factor ×` the rate before it, or the measured
    /// capacity if that is higher (a path that carries 2 Mbps settles at 1.7–1.8, whatever the rate was when a
    /// burst hit the queue). Decreases within `episode` of the previous one belong to the same congestion episode
    /// and keep its (higher) ceiling, so a cascade of steps doesn't ratchet the ceiling down for minutes.
    fn set_ceiling(&mut self, now: Micros, new: f64, capacity: f64) {
        let hold = if self.profile == NetworkProfile::Cellular {
            self.cfg.cellular_ceiling_hold
        } else {
            self.cfg.ceiling_hold
        };
        let episode = self.last_decrease.is_some_and(|t| now - t < self.cfg.decrease_episode);
        let ceiling = match self.ceiling {
            Some((c, until)) if episode && now < until => c,
            _ => (self.cfg.ceiling_factor * self.target.max(capacity)).max(new),
        };
        self.ceiling = Some((ceiling, now + hold));
    }

    fn probe_ceiling(&mut self, now: Micros, dt: Micros) {
        let Some((c, until)) = self.ceiling.filter(|c| now < c.1) else { return };
        let clean = self.queue_delay().is_none_or(|q| q <= self.queue_bar(self.cfg.queue_threshold));
        let settled = self.last_decrease.is_none_or(|t| now - t >= self.cfg.ceiling_probe);
        if clean && settled && self.target >= 0.95 * c {
            self.ceiling = Some((c * (1.0 + self.cfg.increase_per_sec).powf(dt.as_secs_f64()), until));
        }
    }

    fn increase(&mut self, now: Micros, dt: Micros) {
        // heavy loss that may be congestion isn't a path to probe faster (the loss rule decides after
        // `loss_hold`); random loss is no reason to hold back
        let lossy = self.loss_kind.is_some_and(|k| k != LossKind::Random);
        if self.loss_probing(now) {
            return;
        }
        let startup = self.in_startup() && !lossy;
        let share = if startup { self.cfg.startup_content_limited } else { self.cfg.content_limited };
        if dt == Micros::ZERO || (self.sent_bps(now) as f64) < share * self.target {
            return;
        }
        self.probe_ceiling(now, dt);
        let cap = (self.max_bps() as f64).min(self.ceiling_bps(now).map_or(f64::MAX, |c| c as f64));
        if self.target >= cap {
            return;
        }
        if self.capacity.above(self.target) {
            self.capacity = LinkCapacity::default(); // the estimate is stale: probe multiplicatively again
        }
        let next = if self.capacity.near(self.target) {
            // additive: about one packet per response time
            let bits_per_frame = self.target / 30.0;
            let packets = (bits_per_frame / (1200.0 * 8.0)).ceil().max(1.0);
            let packet_bits = bits_per_frame / packets;
            let response = (self.rtt + Micros::from_millis(100)).as_secs_f64();
            self.target + (packet_bits / response).max(4000.0) * dt.as_secs_f64()
        } else {
            let per_sec = if startup { self.cfg.startup_increase_per_sec } else { self.cfg.increase_per_sec };
            self.target * (1.0 + per_sec).powf(dt.as_secs_f64())
        };
        self.target = next.min(cap).max(self.target);
    }

    /// The transport saw persistent congestion: straight to the floor.
    pub fn on_persistent_congestion(&mut self, now: Micros) {
        let floor = self.cfg.min_bps as f64;
        if self.target > floor {
            self.set_ceiling(now, floor, 0.0);
            self.target = floor;
            self.last_decrease = Some(now);
            self.last_change = Some(RateChange::PersistentCongestion);
            self.decreases += 1;
        }
        self.publish(now);
    }

    fn publish(&mut self, _now: Micros) {
        self.handle.set(self.target as u64);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(v: u64) -> Micros {
        Micros::from_millis(v)
    }

    /// Feeds a constant-rate stream through a bottleneck of `cap_bps` with an unbounded queue, feedback every 25 ms.
    fn run(cap_bps: f64, secs: u64, ctl: &mut RateController) -> (Vec<u64>, f64) {
        let mut tseq = 0u64;
        let mut link_free = 0.0f64; // seconds
        let mut pending: Vec<PacketResult> = Vec::new();
        let mut targets = Vec::new();
        let mut max_queue: f64 = 0.0;
        let frame = Micros::from_secs_f64(1.0 / 60.0);
        let mut t = Micros::ZERO;
        let mut next_fb = ms(25);
        while t < Micros::from_secs(secs) {
            let bytes = (ctl.target_bps() as f64 / 60.0 / 8.0) as usize;
            let n = bytes.div_ceil(1200).max(1);
            for _ in 0..n {
                let now_s = t.as_secs_f64();
                let start = link_free.max(now_s);
                max_queue = max_queue.max(start - now_s);
                link_free = start + 1200.0 * 8.0 / cap_bps;
                let arrival = Micros::from_secs_f64(link_free + 0.02);
                ctl.on_sent(t, 1200);
                pending.push(PacketResult { tseq, send_time: t, size: 1200, arrival: Some(arrival) });
                tseq += 1;
            }
            t += frame;
            while next_fb <= t {
                let ready: Vec<PacketResult> =
                    pending.iter().copied().filter(|p| p.arrival.unwrap() + ms(20) <= next_fb).collect();
                pending.retain(|p| p.arrival.unwrap() + ms(20) > next_fb);
                ctl.on_feedback(next_fb, &ready);
                targets.push(ctl.target_bps());
                next_fb += ms(25);
            }
        }
        (targets, max_queue)
    }

    #[test]
    fn converges_below_a_bottleneck() {
        let mut c = RateController::new(RateConfig::default());
        c.set_rtt(ms(40));
        let (targets, _) = run(2_000_000.0, 10, &mut c);
        // below the cap within 5 s and mostly staying there
        let after5: Vec<u64> = targets[200..].to_vec();
        let below = after5.iter().filter(|&&t| t < 2_000_000).count();
        assert!(below as f64 > 0.9 * after5.len() as f64, "{:?}", &after5[..20]);
        assert!(c.decreases > 0);
    }

    #[test]
    fn a_full_queue_is_overuse_even_when_flat() {
        let mut c = RateController::new(RateConfig::default());
        c.set_rtt(ms(80));
        let mut t = Micros::ZERO;
        let mut tseq = 0;
        // 1 s clean at 20 ms one way, then 2 s at a flat 70 ms (a full queue) while sending at the target
        while t < ms(3000) {
            let delay = if t < ms(1000) { ms(20) } else { ms(70) };
            let mut r = Vec::new();
            for _ in 0..9 {
                c.on_sent(t, 1200);
                r.push(PacketResult { tseq, send_time: t, size: 1200, arrival: Some(t + delay) });
                tseq += 1;
            }
            c.on_feedback(t + delay, &r);
            t += ms(25);
        }
        assert!(c.decreases().0 >= 1, "{:?}", c.decreases());
        assert!(c.queue_delay().unwrap() >= ms(45));
    }

    /// A burst over a 2 Mbps link while sending well under it: the capacity estimate sees the link's rate in the
    /// burst's drain, so no cut toward the (low) delivered rate around it; the overshoot-aware decrease only
    /// trims when what is *sent* runs past 85 % of the capacity.
    #[test]
    fn a_burst_decreases_toward_capacity_not_delivered() {
        let cfg = RateConfig { start_bps: 1_500_000, ..RateConfig::default() };
        let mut c = RateController::new(cfg);
        c.set_rtt(ms(80));
        let link = 2_000_000.0;
        let mut free = 0.0f64;
        let mut tseq = 0;
        let mut pending: Vec<PacketResult> = Vec::new();
        let mut t = Micros::ZERO;
        let mut next_fb = ms(25);
        let mut min_after_burst = u64::MAX;
        while t < ms(6000) {
            // 0.9 Mbps of 1200-byte datagrams; at 3 s a 36 KB burst
            let n = if t == ms(3000) {
                30
            } else if t.0 % 10_667 < 1000 {
                1
            } else {
                0
            };
            for _ in 0..n {
                let start = free.max(t.as_secs_f64());
                free = start + 1200.0 * 8.0 / link;
                c.on_sent(t, 1200);
                pending.push(PacketResult {
                    tseq,
                    send_time: t,
                    size: 1200,
                    arrival: Some(Micros::from_secs_f64(free + 0.04)),
                });
                tseq += 1;
            }
            t += ms(1);
            if t >= next_fb {
                let ready: Vec<PacketResult> = pending.iter().copied().filter(|p| p.arrival.unwrap() <= t).collect();
                pending.retain(|p| p.arrival.unwrap() > t);
                c.on_feedback(t, &ready);
                next_fb += ms(25);
                if t > ms(3000) {
                    min_after_burst = min_after_burst.min(c.target_bps());
                }
            }
        }
        let cap = c.capacity_bps().unwrap();
        assert!(cap > 1_600_000 && cap <= 2_100_000, "{cap}");
        assert!(min_after_burst >= 1_450_000, "{min_after_burst}");
    }

    /// 8 s of an empty path whose receiver clock runs 5 % fast: one-way delay grows 50 ms a second. Feedback
    /// comes back 40 ms after each send; `floor`: the acks' round trip, if the transport reports it.
    fn slewed(c: &mut RateController, floor: Option<Micros>) {
        let (mut t, mut tseq) = (Micros::ZERO, 0);
        while t < ms(8000) {
            let delay = ms(20) + t.mul_f64(0.05);
            let mut r = Vec::new();
            for _ in 0..9 {
                c.on_sent(t, 1200);
                r.push(PacketResult { tseq, send_time: t, size: 1200, arrival: Some(t + delay) });
                tseq += 1;
            }
            if let Some(f) = floor {
                c.set_rtt_floor(t + ms(40), f);
            }
            c.on_feedback(t + ms(40), &r);
            t += ms(25);
        }
    }

    #[test]
    fn clocks_at_different_rates_are_not_a_queue() {
        // one-way delay alone: a queue growing without end, the rate at the floor
        let mut blind = RateController::new(RateConfig::default());
        blind.set_rtt(ms(40));
        slewed(&mut blind, None);
        assert!(blind.decreases().0 >= 3, "{:?}", blind.decreases());
        assert!(blind.target_bps() < 1_000_000, "{}", blind.target_bps());
        // the round trip never moved: no queue, no decrease
        let mut c = RateController::new(RateConfig::default());
        c.set_rtt(ms(40));
        slewed(&mut c, Some(ms(40)));
        assert_eq!(c.decreases().0, 0, "{:?}", c.decreases());
        assert!(c.target_bps() >= 3_500_000, "{}", c.target_bps());
        assert!(c.queue_delay().unwrap() <= ms(5), "{:?}", c.queue_delay());
    }

    /// 1 s clean at 20 ms one way, then 2 s at a flat 70 ms while sending at the target; `floor(t)`: the acks'
    /// round trip at `t`, if reported then.
    fn full_queue(c: &mut RateController, floor: impl Fn(Micros) -> Option<Micros>) {
        let (mut t, mut tseq) = (Micros::ZERO, 0);
        while t < ms(3000) {
            let delay = if t < ms(1000) { ms(20) } else { ms(70) };
            let mut r = Vec::new();
            for _ in 0..9 {
                c.on_sent(t, 1200);
                r.push(PacketResult { tseq, send_time: t, size: 1200, arrival: Some(t + delay) });
                tseq += 1;
            }
            if let Some(f) = floor(t) {
                c.set_rtt_floor(t + delay, f);
            }
            c.on_feedback(t + delay, &r);
            t += ms(25);
        }
    }

    #[test]
    fn a_queue_the_round_trip_has_too_is_a_queue() {
        let mut c = RateController::new(RateConfig::default());
        c.set_rtt(ms(80));
        full_queue(&mut c, |t| Some(if t < ms(1000) { ms(40) } else { ms(90) }));
        assert!(c.decreases().0 >= 1, "{:?}", c.decreases());
        assert!(c.queue_delay().unwrap() >= ms(45));
    }

    #[test]
    fn a_wandering_round_trip_leaves_the_queue_as_read() {
        // the way back wanders between 20 and 50 ms with no pattern; the queue's 50 ms come on top
        let mut c = RateController::new(RateConfig::default());
        c.set_rtt(ms(80));
        full_queue(&mut c, |t| Some(ms(40 + (t.0 / 25_000 * 7) % 31 + if t < ms(1000) { 0 } else { 50 })));
        assert!(c.decreases().0 >= 1, "{:?}", c.decreases());
        assert!(c.queue_delay().unwrap() >= ms(45));
    }

    #[test]
    fn round_trips_gone_stale_say_nothing() {
        // floors for the first half second only (the acks stopped coming through this path's reports)
        let mut c = RateController::new(RateConfig::default());
        c.set_rtt(ms(80));
        full_queue(&mut c, |t| (t < ms(500)).then_some(ms(40)));
        assert!(c.decreases().0 >= 1, "{:?}", c.decreases());
        assert!(c.queue_delay().unwrap() >= ms(45));
    }

    #[test]
    fn climbs_on_a_clean_path() {
        let mut c = RateController::new(RateConfig::default());
        c.set_rtt(ms(20));
        let (targets, _) = run(100_000_000.0, 12, &mut c);
        let last = *targets.last().unwrap();
        assert!(last > 7_000_000, "{last}");
        assert!(last <= 20_000_000);
    }

    #[test]
    fn profile_caps_and_floor() {
        let mut c = RateController::new(RateConfig::default());
        let h = c.handle();
        c.set_profile(ms(1), NetworkProfile::Constrained);
        assert_eq!(h.bps(), 2_500_000);
        c.on_persistent_congestion(ms(2));
        assert_eq!(h.bps(), 300_000);
        c.set_profile(ms(3), NetworkProfile::Lan);
        assert_eq!(c.max_bps(), 40_000_000);
    }

    #[test]
    fn no_increase_while_content_limited() {
        let mut c = RateController::new(RateConfig::default());
        let mut t = Micros::ZERO;
        for i in 0..400u64 {
            c.on_sent(t, 200);
            c.on_feedback(t, &[PacketResult { tseq: i, send_time: t, size: 200, arrival: Some(t + ms(20)) }]);
            t += ms(25);
        }
        assert_eq!(c.target_bps(), 3_500_000);
    }

    #[test]
    fn startup_climbs_fast_until_the_first_decrease() {
        let mut c = RateController::new(RateConfig::default());
        let mut t = Micros::ZERO;
        let mut tseq = 0;
        // a clean path; the stream sends a third of the target (a screen that is mostly still)
        while t < ms(5000) {
            let packets = ((c.target_bps() as f64 * 0.025 / 8.0 / 3.0) / 1200.0).ceil() as u64;
            let mut r = Vec::new();
            for _ in 0..packets {
                c.on_sent(t, 1200);
                r.push(PacketResult { tseq, send_time: t, size: 1200, arrival: Some(t + ms(30)) });
                tseq += 1;
            }
            c.on_feedback(t, &r);
            t += ms(25);
        }
        assert!(c.in_startup());
        assert!(c.target_bps() >= 15_000_000, "{}", c.target_bps());
    }

    /// 15 % loss, the same at every rate, no queue (the stream alternates 1.5 and 3 Mbps): random — the rate isn't
    /// cut for it. The same path with loss that grows with the rate (all above 2 Mbps dropped): cut.
    #[test]
    fn random_loss_keeps_the_rate_congestive_loss_cuts_it() {
        for congestive in [false, true] {
            let mut c = RateController::new(RateConfig::default());
            c.set_rtt(ms(280));
            let mut rng = crate::sim::Rng::new(7);
            let (mut t, mut tseq) = (Micros::ZERO, 0);
            while t < ms(20_000) {
                // 25 ms of sending at 1.5 or 3 Mbps (by the second), 1200-byte datagrams
                let fast = (t.0 / 1_000_000) % 2 == 1;
                let n = if fast { 8 } else { 4 };
                let mut r = Vec::new();
                for i in 0..n {
                    c.on_sent(t, 1200);
                    let lost = if congestive { fast && i % 3 == 2 } else { rng.chance(0.15) };
                    r.push(PacketResult { tseq, send_time: t, size: 1200, arrival: (!lost).then_some(t + ms(140)) });
                    tseq += 1;
                }
                c.on_feedback(t + ms(140), &r);
                t += ms(25);
            }
            if congestive {
                assert!(c.loss_decreases >= 3, "{:?}", c.decreases());
            } else {
                // at most the probe at the start (nothing to compare yet)
                assert!(c.loss_decreases <= 1, "{:?}", c.decreases());
                assert!(c.random_loss_holds() > 0);
                assert_eq!(c.loss_kind(), Some(LossKind::Random));
            }
        }
    }

    #[test]
    fn heavy_loss_decreases_after_a_second() {
        let mut c = RateController::new(RateConfig::default());
        let mut t = Micros::ZERO;
        let mut tseq = 0;
        while t < ms(3000) {
            let mut r = Vec::new();
            for i in 0..20 {
                c.on_sent(t, 1200);
                // 20 % loss, constant delay
                r.push(PacketResult { tseq, send_time: t, size: 1200, arrival: (i % 5 != 0).then_some(t + ms(20)) });
                tseq += 1;
            }
            c.on_feedback(t, &r);
            t += ms(25);
        }
        assert!(c.loss_decreases >= 1, "{}", c.loss_decreases);
        assert!(c.target_bps() < 3_500_000);
        assert!((c.fec_loss(t) - 0.2).abs() < 0.01);
    }
}
