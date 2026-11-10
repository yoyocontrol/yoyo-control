//! Session statistics: the snapshot both ends keep, the `link.stats` object they exchange every 2 s and the `link:`
//! log line (docs/LINK.md「Stats」). The media fields are filled by the media layer; absent ones are left out of the
//! line and the object.

use std::{collections::VecDeque, fmt::Write as _, time::Duration};

use serde::{Deserialize, Serialize};

use crate::path::{Iface, PathKind};

/// What the media layer reports (all optional: a session without media has none of it).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaStats {
    /// Pre-FEC shard loss, percent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub loss_pct: Option<f64>,
    /// Media datagrams received / missing at the receiver since the session started (pre-FEC): a peer's
    /// interval loss between two `link.stats`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_received: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media_missing: Option<u64>,
    /// Shards recovered by FEC.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fec_recovered: Option<u64>,
    /// Shards recovered by retransmission / NACKs sent.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nack_recovered: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nack_sent: Option<u64>,
    /// Frames lost at their deadline.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lost_frames: Option<u64>,
    /// Frames skipped because their reference chain broke.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skipped_frames: Option<u64>,
    /// Gaps > 200 ms between delivered frames while the sender's frame numbers advanced.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub freeze_count: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub freeze_ms: Option<u64>,
    /// Megabits per second.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rate_target_mbps: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rate_sent_mbps: Option<f64>,
    /// Rate decreases (sender): delay-based (a queue) and loss-based; the path's jitter as the rate control reads it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rate_cuts: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rate_loss_cuts: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jitter_ms: Option<f64>,
    /// Frames delivered per second.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fps: Option<f64>,
    /// Input: first send → ack.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_p50_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_p90_ms: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_n: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_loss_pct: Option<f64>,
    /// Audio redundancy level in use (0–2).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_red: Option<u32>,
}

impl MediaStats {
    /// The counters (FEC, NACK, lost, skipped, freezes, input events) as the difference from `earlier`, the rest
    /// from `self`: a peer's `link.stats` between two log lines.
    pub fn since(&self, earlier: &MediaStats) -> MediaStats {
        let d = |a: Option<u64>, b: Option<u64>| a.map(|a| a.saturating_sub(b.unwrap_or(0)));
        let (received, missing) =
            (d(self.media_received, earlier.media_received), d(self.media_missing, earlier.media_missing));
        let loss_pct = match (received, missing) {
            (Some(r), Some(m)) if r + m > 0 => Some(m as f64 * 100.0 / (r + m) as f64),
            _ => self.loss_pct,
        };
        MediaStats {
            loss_pct,
            media_received: received,
            media_missing: missing,
            fec_recovered: d(self.fec_recovered, earlier.fec_recovered),
            nack_recovered: d(self.nack_recovered, earlier.nack_recovered),
            nack_sent: d(self.nack_sent, earlier.nack_sent),
            lost_frames: d(self.lost_frames, earlier.lost_frames),
            skipped_frames: d(self.skipped_frames, earlier.skipped_frames),
            freeze_count: d(self.freeze_count, earlier.freeze_count),
            freeze_ms: d(self.freeze_ms, earlier.freeze_ms),
            input_n: d(self.input_n, earlier.input_n),
            rate_cuts: d(self.rate_cuts, earlier.rate_cuts),
            rate_loss_cuts: d(self.rate_loss_cuts, earlier.rate_loss_cuts),
            ..self.clone()
        }
    }
}

/// One end's view of a session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatsSnapshot {
    pub path: PathKind,
    pub iface: Iface,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
    /// Round-trip time over the last 10 s, milliseconds.
    pub rtt_min_ms: f64,
    pub rtt_p50_ms: f64,
    pub rtt_p90_ms: f64,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    pub packets_lost: u64,
    pub datagrams_sent: u64,
    pub datagrams_received: u64,
    /// Datagrams dropped: our receive queues overflowing, unknown channels, sends the QUIC buffer refused.
    pub datagram_drops: u64,
    #[serde(flatten)]
    pub media: MediaStats,
}

impl StatsSnapshot {
    /// The `link.stats` control message.
    pub fn to_message(&self) -> serde_json::Value {
        let mut v = serde_json::to_value(self).unwrap_or_default();
        if let Some(m) = v.as_object_mut() {
            m.insert("t".into(), "link.stats".into());
        }
        v
    }

    pub fn from_message(v: &serde_json::Value) -> Option<StatsSnapshot> {
        serde_json::from_value(v.clone()).ok()
    }

    /// `<path> <iface> rtt <min>/<p50>/<p90> ms loss … red …` (without the `link:` prefix).
    pub fn line(&self) -> String {
        let mut s = format!(
            "{} {} rtt {}/{}/{} ms",
            self.path,
            self.iface,
            ms(self.rtt_min_ms),
            ms(self.rtt_p50_ms),
            ms(self.rtt_p90_ms)
        );
        let m = &self.media;
        if let Some(l) = m.loss_pct {
            let _ = write!(s, " loss {} %", pct(l));
        }
        if let Some(f) = m.fec_recovered {
            let _ = write!(s, " fec {f}");
        }
        if m.nack_recovered.is_some() || m.nack_sent.is_some() {
            let _ = write!(s, " nack {}/{}", m.nack_recovered.unwrap_or(0), m.nack_sent.unwrap_or(0));
        }
        if let Some(l) = m.lost_frames {
            let _ = write!(s, " lost {l}");
        }
        if let Some(k) = m.skipped_frames {
            let _ = write!(s, " skip {k}");
        }
        if m.freeze_count.is_some() || m.freeze_ms.is_some() {
            let _ = write!(s, " freeze {}/{}", m.freeze_count.unwrap_or(0), m.freeze_ms.unwrap_or(0));
        }
        if m.rate_target_mbps.is_some() || m.rate_sent_mbps.is_some() {
            let _ = write!(
                s,
                " rate {}/{} Mbps",
                mbps(m.rate_target_mbps.unwrap_or(0.0)),
                mbps(m.rate_sent_mbps.unwrap_or(0.0))
            );
        }
        if m.rate_cuts.is_some() || m.rate_loss_cuts.is_some() {
            let _ = write!(s, " cuts {}/{}", m.rate_cuts.unwrap_or(0), m.rate_loss_cuts.unwrap_or(0));
        }
        if let Some(j) = m.jitter_ms {
            let _ = write!(s, " jitter {} ms", ms(j));
        }
        if let Some(f) = m.fps {
            let _ = write!(s, " fps {}", f.round() as i64);
        }
        if m.input_p50_ms.is_some() || m.input_n.is_some() {
            let _ = write!(
                s,
                " input {}/{} ms ({})",
                ms(m.input_p50_ms.unwrap_or(0.0)),
                ms(m.input_p90_ms.unwrap_or(0.0)),
                m.input_n.unwrap_or(0)
            );
        }
        if m.audio_loss_pct.is_some() || m.audio_red.is_some() {
            let _ = write!(s, " audio loss {} %", pct(m.audio_loss_pct.unwrap_or(0.0)));
            if let Some(r) = m.audio_red {
                let _ = write!(s, " red {r}");
            }
        }
        s
    }
}

fn ms(v: f64) -> String {
    if v >= 10.0 { format!("{}", v.round() as i64) } else { format!("{v:.1}") }
}

fn pct(v: f64) -> String {
    format!("{v:.1}")
}

fn mbps(v: f64) -> String {
    format!("{v:.1}")
}

/// RTT samples over a sliding window.
#[derive(Debug)]
pub(crate) struct RttWindow {
    window: Duration,
    samples: VecDeque<(std::time::Instant, f64)>,
}

impl RttWindow {
    pub(crate) fn new(window: Duration) -> Self {
        RttWindow { window, samples: VecDeque::new() }
    }

    pub(crate) fn push(&mut self, now: std::time::Instant, rtt: Duration) {
        self.samples.push_back((now, rtt.as_secs_f64() * 1e3));
        while let Some((t, _)) = self.samples.front() {
            if now.duration_since(*t) > self.window {
                self.samples.pop_front();
            } else {
                break;
            }
        }
    }

    /// (min, p50, p90) in ms; None without samples.
    pub(crate) fn summary_opt(&self) -> Option<(f64, f64, f64)> {
        (!self.samples.is_empty()).then(|| self.summary())
    }

    /// (min, p50, p90) in ms; zeros without samples.
    pub(crate) fn summary(&self) -> (f64, f64, f64) {
        if self.samples.is_empty() {
            return (0.0, 0.0, 0.0);
        }
        let mut v: Vec<f64> = self.samples.iter().map(|(_, r)| *r).collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let at = |p: f64| v[((v.len() - 1) as f64 * p).round() as usize];
        (v[0], at(0.5), at(0.9))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snap() -> StatsSnapshot {
        StatsSnapshot {
            path: PathKind::Direct,
            iface: Iface::Cellular,
            remote: Some("93.184.216.34:47820".into()),
            rtt_min_ms: 61.2,
            rtt_p50_ms: 66.0,
            rtt_p90_ms: 131.4,
            bytes_sent: 10,
            bytes_received: 20,
            packets_lost: 1,
            datagrams_sent: 3,
            datagrams_received: 4,
            datagram_drops: 0,
            media: MediaStats::default(),
        }
    }

    #[test]
    fn since_takes_the_interval_of_the_counters() {
        let earlier =
            MediaStats { fec_recovered: Some(10), lost_frames: Some(2), input_n: Some(5), ..Default::default() };
        let now = MediaStats {
            fec_recovered: Some(14),
            lost_frames: Some(2),
            input_n: Some(9),
            fps: Some(60.0),
            loss_pct: Some(1.5),
            ..Default::default()
        };
        let d = now.since(&earlier);
        assert_eq!((d.fec_recovered, d.lost_frames, d.input_n), (Some(4), Some(0), Some(4)));
        assert_eq!((d.fps, d.loss_pct, d.skipped_frames), (Some(60.0), Some(1.5), None));
        // with the datagram counters: the interval's loss, not the snapshot's 2 s window
        let a = MediaStats {
            media_received: Some(1000),
            media_missing: Some(10),
            loss_pct: Some(0.0),
            ..Default::default()
        };
        let b = MediaStats {
            media_received: Some(1990),
            media_missing: Some(20),
            loss_pct: Some(0.0),
            ..Default::default()
        };
        let d = b.since(&a);
        assert_eq!((d.media_received, d.media_missing), (Some(990), Some(10)));
        assert!((d.loss_pct.unwrap() - 1.0).abs() < 1e-9);
    }

    #[test]
    fn line_without_media() {
        assert_eq!(snap().line(), "direct cellular rtt 61/66/131 ms");
    }

    #[test]
    fn line_with_media() {
        let mut s = snap();
        s.rtt_min_ms = 1.26;
        s.media = MediaStats {
            loss_pct: Some(1.04),
            fec_recovered: Some(12),
            nack_recovered: Some(3),
            nack_sent: Some(4),
            lost_frames: Some(1),
            skipped_frames: Some(2),
            freeze_count: Some(1),
            freeze_ms: Some(240),
            rate_target_mbps: Some(8.0),
            rate_sent_mbps: Some(7.43),
            rate_cuts: Some(2),
            rate_loss_cuts: Some(0),
            jitter_ms: Some(21.4),
            fps: Some(59.6),
            input_p50_ms: Some(33.0),
            input_p90_ms: Some(48.0),
            input_n: Some(120),
            audio_loss_pct: Some(0.5),
            audio_red: Some(1),
            ..Default::default()
        };
        assert_eq!(
            s.line(),
            "direct cellular rtt 1.3/66/131 ms loss 1.0 % fec 12 nack 3/4 lost 1 skip 2 freeze 1/240 \
             rate 8.0/7.4 Mbps cuts 2/0 jitter 21 ms fps 60 input 33/48 ms (120) audio loss 0.5 % red 1"
        );
        let msg = s.to_message();
        assert_eq!(msg["t"], "link.stats");
        assert_eq!(msg["fecRecovered"], 12);
        assert_eq!(StatsSnapshot::from_message(&msg).unwrap(), s);
        // absent media fields stay out of the object
        let bare = snap().to_message();
        assert!(bare.get("fecRecovered").is_none());
        assert_eq!(StatsSnapshot::from_message(&bare).unwrap(), snap());
    }

    #[test]
    fn rtt_window() {
        let mut w = RttWindow::new(Duration::from_secs(10));
        let t0 = std::time::Instant::now();
        for i in 1..=10u64 {
            w.push(t0 + Duration::from_secs(i), Duration::from_millis(i * 10));
        }
        assert_eq!(w.summary(), (10.0, 60.0, 90.0));
        w.push(t0 + Duration::from_secs(25), Duration::from_millis(5));
        assert_eq!(w.summary(), (5.0, 5.0, 5.0));
    }
}
