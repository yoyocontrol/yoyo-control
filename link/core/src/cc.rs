//! `MediaCc`: the QUIC congestion controller of every path of a session (docs/LINK.md「Congestion control」).
//!
//! The media layer's rate controller owns the sending rate; QUIC must neither become the bottleneck that stalls
//! video nor build a queue of its own. So the window follows the rate controller's target:
//! `cwnd = max(2 × target × srtt, 16 × MTU)`. A loss on its own does not shrink it (FEC covers random loss; the rate
//! controller reacts to delay). Persistent congestion (noq's signal: everything in flight lost for a while) drops the
//! target to its floor, which takes the window to its minimum, and is counted so the rate controller can restart.

use std::{
    any::Any,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use iroh::endpoint::{Controller, ControllerFactory, ControllerMetrics, RttEstimator};

/// Start rate (StreamFlow's): 3.5 Mbps.
pub const DEFAULT_TARGET_BPS: u64 = 3_500_000;
/// Floor of the rate controller: 300 kbps.
pub const FLOOR_TARGET_BPS: u64 = 300_000;
/// The window never goes below this many full packets.
pub const MIN_WINDOW_PACKETS: u64 = 16;

/// The target bitrate shared by the rate controller (writer) and every path's `MediaCc` (readers) of one session.
///
/// With the media layer attached (`with_media`, every server session) the target is its rate controller's
/// `TargetRate`; `set` is then a floor beside it (`max(set, rate controller)`, e.g. for a bulk transfer; 0 by
/// default). Without it (`new`) the value is whatever `set` says.
#[derive(Debug, Clone)]
pub struct TargetBitrate(Arc<TargetInner>);

#[derive(Debug)]
struct TargetInner {
    bps: AtomicU64,
    media: Option<uu_link_media::TargetRate>,
    floor_bps: AtomicU64,
    persistent_congestion: AtomicU64,
}

impl Default for TargetBitrate {
    fn default() -> Self {
        TargetBitrate::new(DEFAULT_TARGET_BPS)
    }
}

impl TargetBitrate {
    pub fn new(bps: u64) -> Self {
        TargetBitrate(Arc::new(TargetInner {
            bps: AtomicU64::new(bps.max(1)),
            media: None,
            floor_bps: AtomicU64::new(FLOOR_TARGET_BPS),
            persistent_congestion: AtomicU64::new(0),
        }))
    }

    /// Follows the media layer's rate controller.
    pub fn with_media(rate: uu_link_media::TargetRate) -> Self {
        TargetBitrate(Arc::new(TargetInner {
            bps: AtomicU64::new(0),
            media: Some(rate),
            floor_bps: AtomicU64::new(FLOOR_TARGET_BPS),
            persistent_congestion: AtomicU64::new(0),
        }))
    }

    /// Bits per second.
    pub fn get(&self) -> u64 {
        let own = self.0.bps.load(Ordering::Relaxed);
        match &self.0.media {
            Some(m) => own.max(m.bps()).max(1),
            None => own.max(1),
        }
    }

    /// The target (without the media layer) or a floor beside the rate controller's (with it).
    pub fn set(&self, bps: u64) {
        self.0.bps.store(bps, Ordering::Relaxed);
    }

    pub fn follows_media(&self) -> bool {
        self.0.media.is_some()
    }

    pub fn floor(&self) -> u64 {
        self.0.floor_bps.load(Ordering::Relaxed)
    }

    pub fn set_floor(&self, bps: u64) {
        self.0.floor_bps.store(bps.max(1), Ordering::Relaxed);
    }

    /// How many times a path saw persistent congestion (the rate controller restarts from the floor when it grows).
    pub fn persistent_congestion_events(&self) -> u64 {
        self.0.persistent_congestion.load(Ordering::Relaxed)
    }

    fn on_persistent_congestion(&self) {
        // without the media layer: straight to the floor; with it the session tells the rate controller, and an
        // app floor is dropped
        let to = if self.0.media.is_some() { 0 } else { self.floor() };
        self.0.bps.store(to, Ordering::Relaxed);
        self.0.persistent_congestion.fetch_add(1, Ordering::Relaxed);
    }
}

/// Builds a `MediaCc` for each new path of the connections it is configured on.
#[derive(Debug)]
pub struct MediaCcFactory {
    target: TargetBitrate,
}

impl MediaCcFactory {
    pub fn new(target: TargetBitrate) -> Self {
        MediaCcFactory { target }
    }
}

impl ControllerFactory for MediaCcFactory {
    fn build(self: Arc<Self>, _now: Instant, current_mtu: u16) -> Box<dyn Controller> {
        Box::new(MediaCc::new(self.target.clone(), current_mtu))
    }
}

#[derive(Debug, Clone)]
pub struct MediaCc {
    target: TargetBitrate,
    mtu: u16,
    srtt: Duration,
}

/// Before the first RTT sample (QUIC's initial RTT).
const INITIAL_RTT: Duration = Duration::from_millis(333);

impl MediaCc {
    pub fn new(target: TargetBitrate, mtu: u16) -> Self {
        MediaCc { target, mtu, srtt: INITIAL_RTT }
    }

    /// `max(2 × target × srtt, 16 × MTU)` in bytes.
    pub fn window_for(target_bps: u64, srtt: Duration, mtu: u16) -> u64 {
        let bdp2 = (2.0 * target_bps as f64 / 8.0 * srtt.as_secs_f64()) as u64;
        bdp2.max(MIN_WINDOW_PACKETS * mtu as u64)
    }
}

impl Controller for MediaCc {
    fn on_ack(&mut self, _now: Instant, _sent: Instant, _bytes: u64, _pn: u64, _app_limited: bool, rtt: &RttEstimator) {
        self.srtt = rtt.get();
    }

    fn on_congestion_event(
        &mut self,
        _now: Instant,
        _sent: Instant,
        is_persistent_congestion: bool,
        _is_ecn: bool,
        _lost_bytes: u64,
        _largest_lost_pn: u64,
    ) {
        if is_persistent_congestion {
            self.target.on_persistent_congestion();
        }
    }

    fn on_mtu_update(&mut self, new_mtu: u16) {
        self.mtu = new_mtu;
    }

    fn window(&self) -> u64 {
        MediaCc::window_for(self.target.get(), self.srtt, self.mtu)
    }

    fn metrics(&self) -> ControllerMetrics {
        let mut m = ControllerMetrics::default();
        m.congestion_window = self.window();
        m.bandwidth_estimate = Some(self.target.get());
        m
    }

    fn clone_box(&self) -> Box<dyn Controller> {
        Box::new(self.clone())
    }

    fn initial_window(&self) -> u64 {
        MediaCc::window_for(self.target.get(), INITIAL_RTT, self.mtu)
    }

    fn into_any(self: Box<Self>) -> Box<dyn Any> {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    impl MediaCcFactory {
        fn into_arc_build(self) -> Box<dyn Controller> {
            Arc::new(self).build(Instant::now(), 1200)
        }
    }

    fn now() -> Instant {
        Instant::now()
    }

    #[test]
    fn window_follows_target_and_rtt() {
        // 8 Mbps × 50 ms × 2 = 100 kB
        assert_eq!(MediaCc::window_for(8_000_000, Duration::from_millis(50), 1200), 100_000);
        // tiny target / LAN RTT: the 16-packet floor
        assert_eq!(MediaCc::window_for(300_000, Duration::from_millis(2), 1200), 16 * 1200);
    }

    #[test]
    fn random_loss_keeps_the_window_persistent_congestion_floors_it() {
        let target = TargetBitrate::new(8_000_000);
        let factory = Arc::new(MediaCcFactory::new(target.clone()));
        let mut cc = factory.build(now(), 1200);
        let w0 = cc.window();
        cc.on_congestion_event(now(), now(), false, false, 1200, 7);
        assert_eq!(cc.window(), w0, "a random loss must not shrink the window");
        assert_eq!(target.get(), 8_000_000);

        // the rate controller lowers the target: the window follows at once
        target.set(4_000_000);
        assert!(cc.window() < w0);

        cc.on_congestion_event(now(), now(), true, false, 12_000, 9);
        assert_eq!(target.get(), FLOOR_TARGET_BPS);
        assert_eq!(target.persistent_congestion_events(), 1);
        assert_eq!(cc.window(), MediaCc::window_for(FLOOR_TARGET_BPS, INITIAL_RTT, 1200));
    }

    #[test]
    fn follows_the_media_rate_with_an_app_floor() {
        let rate = uu_link_media::TargetRate::new(6_000_000);
        let t = TargetBitrate::with_media(rate);
        assert!(t.follows_media());
        assert_eq!(t.get(), 6_000_000);
        t.set(10_000_000);
        assert_eq!(t.get(), 10_000_000, "a floor above the rate controller");
        t.set(1_000_000);
        assert_eq!(t.get(), 6_000_000);
        let mut cc = MediaCcFactory::new(t.clone()).into_arc_build();
        cc.on_congestion_event(now(), now(), true, false, 1, 1);
        assert_eq!(t.persistent_congestion_events(), 1);
        assert_eq!(t.get(), 6_000_000, "the rate controller is told by the session, not here");
    }

    #[test]
    fn every_path_shares_the_target_and_mtu_updates() {
        let target = TargetBitrate::new(2_000_000);
        let factory = Arc::new(MediaCcFactory::new(target.clone()));
        let mut a = factory.clone().build(now(), 1200);
        let b = factory.build(now(), 1200);
        target.set(20_000_000);
        assert_eq!(a.window(), b.window());
        assert_eq!(a.window(), MediaCc::window_for(20_000_000, INITIAL_RTT, 1200));
        a.on_mtu_update(1452);
        target.set(1);
        assert_eq!(a.window(), 16 * 1452);
        assert_eq!(a.metrics().congestion_window, 16 * 1452);
        assert_eq!(a.initial_window(), 16 * 1452);
    }
}
