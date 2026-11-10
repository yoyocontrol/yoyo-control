//! The media side of the `link:` stats line (LINK.md §8).

/// Media stats of one side. Counters are cumulative since the session started (use [`MediaStats::since`] for an
/// interval); rates and percentiles are the current windowed values. Fields a side doesn't know stay `None` / 0
/// (the server knows rate and redundancy, the client knows frames, freezes, FEC, NACK and input).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MediaStats {
    /// When the snapshot was taken (the caller's clock, µs).
    pub at_us: u64,
    /// Server: media bytes handed to the transport so far (the interval's sent rate comes from it).
    pub sent_bytes: u64,
    pub rtt_min_ms: Option<f64>,
    pub rtt_p50_ms: Option<f64>,
    pub rtt_p90_ms: Option<f64>,
    /// Pre-FEC loss of media datagrams (%): the last 2 s in a snapshot, the interval's after `since`.
    pub loss_pct: Option<f64>,
    /// Media datagrams received / missing at the receiver so far (pre-FEC; the server's from feedback): the
    /// interval's loss comes from them.
    pub media_received: u64,
    pub media_missing: u64,
    /// Data shards restored by FEC.
    pub fec_recovered: u64,
    /// Retransmitted shards that arrived in time / shards asked for by NACK.
    pub nack_recovered: u64,
    pub nack_sent: u64,
    /// Sender: shards re-sent for NACKs.
    pub retransmits: u64,
    pub frames_sent: u64,
    pub frames_delivered: u64,
    pub frames_lost: u64,
    pub frames_skipped: u64,
    pub key_frames: u64,
    pub recovery_frames: u64,
    pub freezes: u64,
    pub freeze_ms: u64,
    pub target_bps: Option<u64>,
    /// Rate decreases so far (server): delay-based (a queue) and loss-based.
    pub rate_cuts: u64,
    pub rate_loss_cuts: u64,
    /// The path's jitter as the rate control reads it (server, ms).
    pub jitter_ms: Option<f64>,
    /// In a snapshot: the last second's sending; after [`MediaStats::since`]: the interval's average.
    pub sent_bps: Option<u64>,
    /// Delivered frames per second: the last 2 s in a snapshot, the interval's average after `since`.
    pub fps: Option<f64>,
    /// Input first send → ack (ms) over the recent events.
    pub input_p50_ms: Option<f64>,
    pub input_p90_ms: Option<f64>,
    pub input_events: u64,
    pub input_failed: u64,
    /// Pre-redundancy audio loss (%), last ≈ 2 s.
    pub audio_loss_pct: Option<f64>,
    /// Audio packets never received after redundancy.
    pub audio_lost: u64,
    pub audio_recovered: u64,
    /// Audio redundancy in use (server).
    pub redundancy: Option<u8>,
}

fn opt(v: Option<f64>, digits: usize) -> String {
    v.map_or_else(|| "-".to_string(), |v| format!("{v:.digits$}"))
}

impl MediaStats {
    /// Counters as the difference from `earlier`; the sent rate, fps and pre-FEC loss as the interval's; the rest
    /// (rtt, target, input percentiles) from `self`. (The 2 s loss window read every 10 s showed 0 % for an
    /// interval in which NACKs and FEC recovered shards.)
    pub fn since(&self, earlier: &MediaStats) -> MediaStats {
        let d = |a: u64, b: u64| a.saturating_sub(b);
        let (received, missing) =
            (d(self.media_received, earlier.media_received), d(self.media_missing, earlier.media_missing));
        let loss_pct = if received + missing > 0 {
            Some(missing as f64 * 100.0 / (received + missing) as f64)
        } else {
            self.loss_pct
        };
        let secs = d(self.at_us, earlier.at_us) as f64 / 1e6;
        let sent_bps = if secs > 0.0 && self.sent_bps.is_some() {
            Some((d(self.sent_bytes, earlier.sent_bytes) as f64 * 8.0 / secs) as u64)
        } else {
            self.sent_bps
        };
        let fps = if secs > 0.0 && self.fps.is_some() {
            Some(d(self.frames_delivered, earlier.frames_delivered) as f64 / secs)
        } else {
            self.fps
        };
        MediaStats {
            sent_bps,
            fps,
            loss_pct,
            media_received: received,
            media_missing: missing,
            fec_recovered: d(self.fec_recovered, earlier.fec_recovered),
            nack_recovered: d(self.nack_recovered, earlier.nack_recovered),
            nack_sent: d(self.nack_sent, earlier.nack_sent),
            retransmits: d(self.retransmits, earlier.retransmits),
            frames_sent: d(self.frames_sent, earlier.frames_sent),
            frames_delivered: d(self.frames_delivered, earlier.frames_delivered),
            frames_lost: d(self.frames_lost, earlier.frames_lost),
            frames_skipped: d(self.frames_skipped, earlier.frames_skipped),
            key_frames: d(self.key_frames, earlier.key_frames),
            recovery_frames: d(self.recovery_frames, earlier.recovery_frames),
            freezes: d(self.freezes, earlier.freezes),
            freeze_ms: d(self.freeze_ms, earlier.freeze_ms),
            input_events: d(self.input_events, earlier.input_events),
            input_failed: d(self.input_failed, earlier.input_failed),
            audio_lost: d(self.audio_lost, earlier.audio_lost),
            audio_recovered: d(self.audio_recovered, earlier.audio_recovered),
            rate_cuts: d(self.rate_cuts, earlier.rate_cuts),
            rate_loss_cuts: d(self.rate_loss_cuts, earlier.rate_loss_cuts),
            ..self.clone()
        }
    }

    /// `link: <path> <iface> rtt <min>/<p50>/<p90> ms loss <%> fec <n> nack <rec>/<sent> lost <n> skip <n>
    /// freeze <count>/<ms> rate <target>/<sent> Mbps fps <n> input <p50>/<p90> ms (<n>) audio loss <%> red <r>`.
    /// Unknown values are `-`.
    pub fn line(&self, path: &str, iface: &str) -> String {
        let mbps = |v: Option<u64>| opt(v.map(|b| b as f64 / 1e6), 1);
        format!(
            "link: {path} {iface} rtt {}/{}/{} ms loss {} fec {} nack {}/{} lost {} skip {} freeze {}/{} rate {}/{} Mbps fps {} input {}/{} ms ({}) audio loss {} red {}",
            opt(self.rtt_min_ms, 0),
            opt(self.rtt_p50_ms, 0),
            opt(self.rtt_p90_ms, 0),
            opt(self.loss_pct, 1),
            self.fec_recovered,
            self.nack_recovered,
            self.nack_sent,
            self.frames_lost,
            self.frames_skipped,
            self.freezes,
            self.freeze_ms,
            mbps(self.target_bps),
            mbps(self.sent_bps),
            opt(self.fps, 0),
            opt(self.input_p50_ms, 0),
            opt(self.input_p90_ms, 0),
            self.input_events,
            opt(self.audio_loss_pct, 1),
            self.redundancy.map_or_else(|| "-".to_string(), |r| r.to_string()),
        )
    }
}

/// Nearest-rank percentile of unsorted samples.
pub(crate) fn percentile(samples: impl Iterator<Item = f64>, p: f64) -> Option<f64> {
    let mut v: Vec<f64> = samples.collect();
    if v.is_empty() {
        return None;
    }
    v.sort_by(|a, b| a.total_cmp(b));
    let rank = ((v.len() as f64 * p).ceil() as usize).clamp(1, v.len()) - 1;
    Some(v[rank])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_format() {
        let s = MediaStats {
            rtt_min_ms: Some(61.2),
            rtt_p50_ms: Some(70.0),
            rtt_p90_ms: Some(130.4),
            loss_pct: Some(1.23),
            fec_recovered: 40,
            nack_recovered: 3,
            nack_sent: 4,
            frames_lost: 1,
            frames_skipped: 5,
            freezes: 1,
            freeze_ms: 240,
            target_bps: Some(6_500_000),
            sent_bps: Some(3_200_000),
            fps: Some(58.4),
            input_p50_ms: Some(72.0),
            input_p90_ms: Some(95.0),
            input_events: 120,
            audio_loss_pct: Some(0.8),
            redundancy: Some(1),
            ..Default::default()
        };
        assert_eq!(
            s.line("direct", "cellular"),
            "link: direct cellular rtt 61/70/130 ms loss 1.2 fec 40 nack 3/4 lost 1 skip 5 freeze 1/240 rate 6.5/3.2 Mbps fps 58 input 72/95 ms (120) audio loss 0.8 red 1"
        );
        let d = s.since(&MediaStats { fec_recovered: 10, ..Default::default() });
        assert_eq!(d.fec_recovered, 30);
        // the interval's sent rate and fps, not the last second's
        let a = MediaStats {
            at_us: 1_000_000,
            sent_bytes: 1_000_000,
            sent_bps: Some(9_000_000),
            fps: Some(10.0),
            frames_delivered: 100,
            ..Default::default()
        };
        let b = MediaStats {
            at_us: 11_000_000,
            sent_bytes: 4_750_000,
            sent_bps: Some(100_000),
            fps: Some(0.0),
            frames_delivered: 700,
            ..Default::default()
        };
        let i = b.since(&a);
        assert_eq!(i.sent_bps, Some(3_000_000));
        assert_eq!(i.fps, Some(60.0));
        // pre-FEC loss: the interval's, from the datagram counters (the snapshot's 2 s window may hold none)
        let a = MediaStats { media_received: 5_000, media_missing: 40, loss_pct: Some(0.0), ..Default::default() };
        let b = MediaStats { media_received: 9_950, media_missing: 90, loss_pct: Some(0.0), ..Default::default() };
        assert_eq!(b.since(&a).loss_pct, Some(1.0));
        assert_eq!(b.since(&b).loss_pct, Some(0.0), "nothing in the interval: the snapshot's value");
        assert!(MediaStats::default().line("lan", "wifi").contains("rtt -/-/- ms"));
    }
}
