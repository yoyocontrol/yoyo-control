//! Transport-wide congestion feedback: the receiver records the arrival of every media datagram by `tseq` and
//! reports them (feedback section 1); the sender maps the report back onto its send records.

use std::collections::{BTreeMap, VecDeque};

use crate::rate::PacketResult;
use crate::time::Micros;
use crate::wire::TransportCc;

/// Extends a wrapping u32 counter to u64, relative to the newest value seen.
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Unwrapper {
    last: Option<u64>,
}

impl Unwrapper {
    pub(crate) fn unwrap(&mut self, v: u32) -> u64 {
        let Some(last) = self.last else {
            self.last = Some(v as u64);
            return v as u64;
        };
        let diff = v.wrapping_sub(last as u32) as i32 as i64;
        let out = (last as i64 + diff).max(0) as u64;
        if out > last {
            self.last = Some(out);
        }
        out
    }
}

/// Receiver side: arrivals waiting to be reported.
#[derive(Debug, Default)]
pub(crate) struct ArrivalRecorder {
    unwrap: Unwrapper,
    arrivals: BTreeMap<u64, Micros>,
    /// First tseq not reported yet.
    next: Option<u64>,
    highest: Option<u64>,
    /// Totals: received / not received at report time (pre-FEC loss on the receiver's side).
    pub(crate) received: u64,
    pub(crate) missing: u64,
    pub(crate) late: u64,
    /// (report time, received, missing) for windowed loss.
    window: VecDeque<(Micros, u32, u32)>,
}

impl ArrivalRecorder {
    /// Most tseqs one report covers (a long gap after a blackout is cut to the newest ones).
    const MAX_SPAN: u64 = 8192;

    /// Record an arrival; returns the unwrapped tseq.
    pub(crate) fn on_arrival(&mut self, tseq: u32, now: Micros) -> u64 {
        let t = self.unwrap.unwrap(tseq);
        if self.next.is_some_and(|n| t < n) {
            self.late += 1;
            return t;
        }
        self.next.get_or_insert(t);
        self.arrivals.entry(t).or_insert(now);
        self.highest = Some(self.highest.map_or(t, |h| h.max(t)));
        t
    }

    pub(crate) fn has_pending(&self) -> bool {
        !self.arrivals.is_empty()
    }

    /// Build sections for everything up to the highest arrival, each at most `max_bytes` on the wire (section
    /// header included).
    pub(crate) fn take_sections(&mut self, now: Micros, max_bytes: usize) -> Vec<TransportCc> {
        let (Some(mut next), Some(high)) = (self.next, self.highest) else { return Vec::new() };
        if high < next || self.arrivals.is_empty() {
            return Vec::new();
        }
        if high - next >= Self::MAX_SPAN {
            next = high + 1 - Self::MAX_SPAN;
            self.arrivals = self.arrivals.split_off(&next);
        }
        let per = ((max_bytes.saturating_sub(3 + 10)) / 2).clamp(1, 0xFFFF);
        let mut out = Vec::new();
        let (mut rec, mut miss) = (0u32, 0u32);
        while next <= high {
            let end = (next + per as u64 - 1).min(high);
            let reference = self.arrivals.range(next..=end).map(|(_, &a)| a).min();
            let mut deltas = Vec::with_capacity((end - next + 1) as usize);
            for t in next..=end {
                match (self.arrivals.remove(&t), reference) {
                    (Some(a), Some(r)) => {
                        let units = (a - r).0 / TransportCc::UNIT_US;
                        deltas.push(units.min(TransportCc::MAX_DELTA as u64) as u16);
                        rec += 1;
                    }
                    _ => {
                        deltas.push(TransportCc::NOT_RECEIVED);
                        miss += 1;
                    }
                }
            }
            out.push(TransportCc { base_tseq: next as u32, ref_time_us: reference.map_or(0, |r| r.0 as u32), deltas });
            next = end + 1;
        }
        self.next = Some(next);
        self.received += rec as u64;
        self.missing += miss as u64;
        self.window.push_back((now, rec, miss));
        while self.window.front().is_some_and(|e| now - e.0 > Micros::from_secs(2)) {
            self.window.pop_front();
        }
        out
    }

    /// Pre-FEC loss fraction over the last 2 s of reports.
    pub(crate) fn loss(&self) -> f64 {
        let (r, m) = self.window.iter().fold((0u64, 0u64), |a, e| (a.0 + e.1 as u64, a.1 + e.2 as u64));
        if r + m == 0 { 0.0 } else { m as f64 / (r + m) as f64 }
    }
}

/// Sender side: what went out, by tseq.
#[derive(Debug, Default)]
pub(crate) struct SendHistory {
    /// (tseq, send time, size, reported)
    records: VecDeque<(u64, Micros, u32, bool)>,
    next_tseq: u64,
    ref_unwrap: Option<u64>,
}

impl SendHistory {
    const KEEP: Micros = Micros::from_secs(5);

    /// Allocate the next tseq for a datagram of `size` sent at `now`.
    pub(crate) fn on_send(&mut self, now: Micros, size: u32) -> u32 {
        let t = self.next_tseq;
        self.next_tseq += 1;
        self.records.push_back((t, now, size, false));
        while self.records.front().is_some_and(|r| now - r.1 > Self::KEEP) {
            self.records.pop_front();
        }
        t as u32
    }

    /// Overwrite a send time (the transport knows a better one).
    pub(crate) fn set_send_time(&mut self, tseq: u32, at: Micros) {
        if let Some(i) = self.index(self.unwrap(tseq)) {
            self.records[i].1 = at;
        }
    }

    fn unwrap(&self, v: u32) -> u64 {
        // relative to the newest allocated tseq
        let newest = self.next_tseq.saturating_sub(1);
        (newest as i64 + v.wrapping_sub(newest as u32) as i32 as i64).max(0) as u64
    }

    fn index(&self, t: u64) -> Option<usize> {
        let first = self.records.front()?.0;
        let i = t.checked_sub(first)? as usize;
        (i < self.records.len()).then_some(i)
    }

    /// Map one feedback section to packet results (tseq order). Already-reported or forgotten tseqs are skipped.
    pub(crate) fn on_feedback(&mut self, tcc: &TransportCc) -> Vec<PacketResult> {
        // receiver clock: unwrap the 32-bit reference relative to the previous one
        let reference = match self.ref_unwrap {
            None => tcc.ref_time_us as u64,
            Some(prev) => (prev as i64 + tcc.ref_time_us.wrapping_sub(prev as u32) as i32 as i64).max(0) as u64,
        };
        if self.ref_unwrap.is_none_or(|p| reference > p) {
            self.ref_unwrap = Some(reference);
        }
        let base = self.unwrap(tcc.base_tseq);
        let mut out = Vec::with_capacity(tcc.deltas.len());
        for (i, &d) in tcc.deltas.iter().enumerate() {
            let t = base + i as u64;
            let Some(idx) = self.index(t) else { continue };
            let rec = &mut self.records[idx];
            if rec.3 {
                continue;
            }
            rec.3 = true;
            let arrival = (d != TransportCc::NOT_RECEIVED).then(|| Micros(reference + d as u64 * TransportCc::UNIT_US));
            out.push(PacketResult { tseq: t, send_time: rec.1, size: rec.2, arrival });
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwrapper_handles_wrap() {
        let mut u = Unwrapper::default();
        assert_eq!(u.unwrap(u32::MAX - 1), (u32::MAX - 1) as u64);
        assert_eq!(u.unwrap(u32::MAX), u32::MAX as u64);
        assert_eq!(u.unwrap(1), (1u64 << 32) + 1);
        assert_eq!(u.unwrap(u32::MAX), u32::MAX as u64); // late one from before the wrap
        assert_eq!(u.unwrap(2), (1u64 << 32) + 2);
    }

    #[test]
    fn report_round_trip() {
        let mut h = SendHistory::default();
        let mut r = ArrivalRecorder::default();
        for i in 0..10u64 {
            let t = h.on_send(Micros::from_millis(i), 1000);
            if i != 3 && i != 7 {
                r.on_arrival(t, Micros::from_millis(50 + i * 2));
            }
        }
        let sections = r.take_sections(Micros::from_millis(80), 1200);
        assert_eq!(sections.len(), 1);
        // tseq 9 arrived, so 0..=9 are covered; 3 and 7 not received
        assert_eq!(sections[0].deltas.len(), 10);
        let res = h.on_feedback(&sections[0]);
        assert_eq!(res.len(), 10);
        assert!(res[3].arrival.is_none() && res[7].arrival.is_none());
        assert_eq!(res[1].arrival.unwrap() - res[0].arrival.unwrap(), Micros::from_millis(2));
        assert_eq!(res[5].send_time, Micros::from_millis(5));
        // reported once only
        assert!(h.on_feedback(&sections[0]).is_empty());
        assert!((r.loss() - 0.2).abs() < 1e-9);
        // a late arrival of an already-reported tseq is counted, not reported
        r.on_arrival(3, Micros::from_millis(90));
        assert_eq!(r.late, 1);
        assert!(r.take_sections(Micros::from_millis(95), 1200).is_empty());
    }

    #[test]
    fn splits_long_reports() {
        let mut r = ArrivalRecorder::default();
        for i in 0..1000u32 {
            r.on_arrival(i, Micros::from_millis(i as u64));
        }
        let s = r.take_sections(Micros::from_secs(1), 200);
        assert!(s.len() > 1);
        assert_eq!(s.iter().map(|x| x.deltas.len()).sum::<usize>(), 1000);
        assert!(s.iter().all(|x| 3 + 10 + 2 * x.deltas.len() <= 200));
    }
}
