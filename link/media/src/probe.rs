//! The receiving half of a speed test (docs/LINK.md「测速」): the server sends filler frames on a video stream the
//! client opened with [`crate::ClientMedia::open_probe`], through the same FEC, NACK, pacing and rate control as a
//! picture; the client media layer takes them itself (no decoder: each delivered frame is acknowledged as decoded
//! at once, so the reports and the rate control behave as with a real one) and counts them here.

use crate::time::Micros;
use crate::video_rx::ReceivedFrame;

/// The delivered-bytes time series is kept in buckets this long.
const BUCKET: Micros = Micros::from_millis(250);
/// The "peak" rate is the best window of this many buckets (1 s).
const PEAK_BUCKETS: usize = 4;
/// The "final" rate and frame rate are the last this many buckets (2 s).
const FINAL_BUCKETS: usize = 8;

/// One probe stream's receive counters.
#[derive(Clone, Debug, Default)]
pub struct ProbeReceiver {
    opened_at: Option<Micros>,
    first_at: Option<Micros>,
    last_at: Option<Micros>,
    frames: u64,
    bytes: u64,
    /// (bucket start, bytes, frames), oldest first, no gaps after the first.
    buckets: Vec<(Micros, u64, u64)>,
}

/// What a probe stream received, for the app's report.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ProbeRxStats {
    /// Frames delivered (complete, in order or recovered).
    pub frames: u64,
    /// Their access-unit bytes (the payload a picture would have; no headers, FEC or retransmits).
    pub bytes: u64,
    /// From the first frame's delivery to the last's (µs; 0 with fewer than two frames).
    pub span_us: u64,
    /// Mean delivered rate over `span_us` (bits/s).
    pub mean_bps: Option<u64>,
    /// The best 1 s window's delivered rate (bits/s).
    pub peak_bps: Option<u64>,
    /// The last 2 s's delivered rate (bits/s): where the rate control settled.
    pub final_bps: Option<u64>,
    /// Frames per second over the last 2 s.
    pub final_fps: Option<f64>,
}

impl ProbeReceiver {
    pub(crate) fn new(now: Micros) -> ProbeReceiver {
        ProbeReceiver { opened_at: Some(now), ..Default::default() }
    }

    pub(crate) fn on_frame(&mut self, f: &ReceivedFrame) {
        let at = f.delivered_at;
        self.first_at.get_or_insert(at);
        self.last_at = Some(at);
        self.frames += 1;
        self.bytes += f.au.len() as u64;
        let origin = self.opened_at.unwrap_or(at);
        let index = (at.0.saturating_sub(origin.0)) / BUCKET.0;
        let start = Micros(origin.0 + index * BUCKET.0);
        match self.buckets.last_mut() {
            Some(b) if b.0 == start => {
                b.1 += f.au.len() as u64;
                b.2 += 1;
            }
            Some(b) if b.0 > start => {} // never: delivery times are monotonic
            last => {
                // fill the empty buckets in between, so windows count silence as silence
                let mut next = last.map_or(start, |b| Micros(b.0.0 + BUCKET.0));
                while next < start {
                    self.buckets.push((next, 0, 0));
                    next = Micros(next.0 + BUCKET.0);
                }
                self.buckets.push((start, f.au.len() as u64, 1));
            }
        }
    }

    /// The counters at `now` (buckets after the last frame up to `now` count as empty).
    pub fn stats(&self, now: Micros) -> ProbeRxStats {
        let span_us = match (self.first_at, self.last_at) {
            (Some(a), Some(b)) if self.frames >= 2 => b.0.saturating_sub(a.0),
            _ => 0,
        };
        let mean_bps = (span_us > 0).then(|| (self.bytes as f64 * 8.0 / (span_us as f64 / 1e6)) as u64);
        let mut buckets = self.buckets.clone();
        if let Some(&(last, _, _)) = buckets.last() {
            let mut next = Micros(last.0 + BUCKET.0);
            // only whole buckets: the one `now` is in hasn't finished
            while next.0 + BUCKET.0 <= now.0 {
                buckets.push((next, 0, 0));
                next = Micros(next.0 + BUCKET.0);
            }
        }
        let rate = |w: &[(Micros, u64, u64)]| {
            let secs = w.len() as f64 * BUCKET.0 as f64 / 1e6;
            (w.iter().map(|b| b.1).sum::<u64>() as f64 * 8.0 / secs) as u64
        };
        let peak_bps = (buckets.len() >= PEAK_BUCKETS).then(|| buckets.windows(PEAK_BUCKETS).map(rate).max().unwrap());
        let tail = &buckets[buckets.len().saturating_sub(FINAL_BUCKETS)..];
        let full = tail.len() == FINAL_BUCKETS;
        let final_bps = full.then(|| rate(tail));
        let final_fps =
            full.then(|| tail.iter().map(|b| b.2).sum::<u64>() as f64 / (FINAL_BUCKETS as f64 * BUCKET.0 as f64 / 1e6));
        ProbeRxStats { frames: self.frames, bytes: self.bytes, span_us, mean_bps, peak_bps, final_bps, final_fps }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{Codec, FrameKind, FrameMeta};

    fn frame(at_ms: u64, bytes: usize) -> ReceivedFrame {
        ReceivedFrame {
            stream: 9,
            frame: 1,
            meta: FrameMeta {
                codec: Codec::H264,
                kind: FrameKind::Delta,
                width: 0,
                height: 0,
                capture_us: 0,
                recovery_base: 0,
                au_len: bytes as u32,
            },
            au: vec![0; bytes],
            first_arrival: Micros::from_millis(at_ms),
            delivered_at: Micros::from_millis(at_ms),
        }
    }

    #[test]
    fn rates_over_the_whole_the_best_second_and_the_last_two() {
        let mut p = ProbeReceiver::new(Micros::ZERO);
        // 1 s at 10 kB per 10 ms (8 Mbps), then 3 s at 5 kB per 10 ms (4 Mbps)
        for i in 0..100 {
            p.on_frame(&frame(i * 10, 10_000));
        }
        for i in 100..400 {
            p.on_frame(&frame(i * 10, 5_000));
        }
        let s = p.stats(Micros::from_millis(4000));
        assert_eq!(s.frames, 400);
        assert_eq!(s.bytes, 2_500_000);
        assert_eq!(s.span_us, 3_990_000);
        assert_eq!(s.peak_bps, Some(8_000_000));
        assert_eq!(s.final_bps, Some(4_000_000));
        assert_eq!(s.final_fps, Some(100.0));
        assert!(s.mean_bps.unwrap().abs_diff(5_012_531) < 10);
    }

    #[test]
    fn silence_after_the_last_frame_counts() {
        let mut p = ProbeReceiver::new(Micros::ZERO);
        for i in 0..100 {
            p.on_frame(&frame(i * 10, 10_000));
        }
        // a 2 s stall at the end
        let s = p.stats(Micros::from_millis(3000));
        assert_eq!(s.final_bps, Some(0));
        assert_eq!(s.final_fps, Some(0.0));
        assert_eq!(s.peak_bps, Some(8_000_000));
    }

    #[test]
    fn too_short_for_windows() {
        let mut p = ProbeReceiver::new(Micros::ZERO);
        p.on_frame(&frame(10, 1000));
        let s = p.stats(Micros::from_millis(100));
        assert_eq!((s.frames, s.span_us, s.mean_bps, s.peak_bps, s.final_bps), (1, 0, None, None, None));
    }
}
