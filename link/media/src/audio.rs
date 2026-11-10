//! Audio (LINK.md §5.6): one datagram per Opus packet, carrying `r` older packets as redundancy; `r` follows the
//! receiver's audio report. The receiver dedups by `aseq` and hands packets on in order with the gap before each.

use std::collections::{BTreeSet, VecDeque};

use crate::time::Micros;
use crate::wire::AudioDatagram;

/// Redundancy for a reported loss: 0 below 0.5 %, 1 below 5 %, else 2.
pub fn redundancy_for(loss_permille: u16) -> u8 {
    match loss_permille {
        0..5 => 0,
        5..50 => 1,
        _ => 2,
    }
}

pub(crate) struct AudioStreamSender {
    pub(crate) id: u8,
    next_aseq: u32,
    /// The last two packets (aseq, opus), newest last.
    recent: VecDeque<(u32, Vec<u8>)>,
    pub(crate) redundancy: u8,
    pub(crate) packets: u64,
    /// Bytes handed out over the last couple of seconds, for the encoder budget.
    sent: VecDeque<(Micros, usize)>,
}

impl AudioStreamSender {
    pub(crate) fn new(id: u8) -> AudioStreamSender {
        AudioStreamSender {
            id,
            next_aseq: 0,
            recent: VecDeque::new(),
            redundancy: 0,
            packets: 0,
            sent: VecDeque::new(),
        }
    }

    /// One Opus packet → a datagram (tseq stamped later). Redundant packets that don't fit `max_datagram` are left
    /// out. Returns (aseq, datagram).
    pub(crate) fn packet(&mut self, now: Micros, time_us: u64, opus: &[u8], max_datagram: usize) -> (u32, Vec<u8>) {
        let aseq = self.next_aseq;
        self.next_aseq = self.next_aseq.wrapping_add(1);
        let mut size = AudioDatagram::HEADER_LEN + opus.len();
        let mut redundant = Vec::new();
        for (a, d) in self.recent.iter().rev().take(self.redundancy as usize) {
            if size + 4 + d.len() > max_datagram {
                break;
            }
            size += 4 + d.len();
            redundant.push((aseq.wrapping_sub(*a) as u16, &d[..]));
        }
        let mut out = Vec::with_capacity(size);
        AudioDatagram { stream: self.id, flags: 0, tseq: 0, aseq, time_us, data: opus, redundant }.write(&mut out);
        self.recent.push_back((aseq, opus.to_vec()));
        if self.recent.len() > 2 {
            self.recent.pop_front();
        }
        self.packets += 1;
        self.sent.push_back((now, out.len()));
        while self.sent.front().is_some_and(|s| now - s.0 > Micros::from_secs(2)) {
            self.sent.pop_front();
        }
        (aseq, out)
    }

    /// Bits per second sent over the last 2 s.
    pub(crate) fn rate_bps(&self) -> u64 {
        self.sent.iter().map(|s| s.1 as u64).sum::<u64>() * 8 / 2
    }
}

/// An Opus packet for the jitter buffer, in `aseq` order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioPacket {
    pub stream: u8,
    pub aseq: u32,
    /// Capture time (µs). For a packet recovered from redundancy it is estimated from the packet duration.
    pub time_us: u64,
    pub data: Vec<u8>,
    /// Came from a later datagram's redundancy.
    pub recovered: bool,
    /// Packets lost right before this one (to conceal).
    pub gap_before: u32,
}

/// Per-stream receiver counters.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AudioRxStats {
    pub packets: u64,
    pub recovered: u64,
    /// Packets never received (after redundancy).
    pub lost: u64,
    pub late: u64,
}

pub(crate) struct AudioStreamReceiver {
    pub(crate) id: u8,
    next: Option<u32>,
    last_time: Option<(u32, u64)>,
    packet_us: u64,
    /// Primary aseqs seen among the last `LOSS_SPAN` (pre-redundancy loss for the report).
    primaries: BTreeSet<u32>,
    highest: Option<u32>,
    pub(crate) stats: AudioRxStats,
}

impl AudioStreamReceiver {
    /// The audio report's window in packets (≈ 2 s of 20 ms packets).
    const LOSS_SPAN: u32 = 100;

    pub(crate) fn new(id: u8) -> AudioStreamReceiver {
        AudioStreamReceiver {
            id,
            next: None,
            last_time: None,
            packet_us: 20_000,
            primaries: BTreeSet::new(),
            highest: None,
            stats: AudioRxStats::default(),
        }
    }

    pub(crate) fn on_datagram(&mut self, d: &AudioDatagram<'_>, out: &mut Vec<AudioPacket>) {
        // packet duration from consecutive primaries
        if let Some((a, t)) = self.last_time
            && d.aseq > a
            && d.time_us > t
        {
            let per = (d.time_us - t) / (d.aseq - a) as u64;
            if (2_500..=120_000).contains(&per) {
                self.packet_us = per;
            }
        }
        if self.last_time.is_none_or(|(a, _)| d.aseq > a) {
            self.last_time = Some((d.aseq, d.time_us));
        }
        self.note_primary(d.aseq);

        let mut cands: Vec<(u32, u64, &[u8], bool)> = d
            .redundant
            .iter()
            .map(|(delta, data)| {
                let a = d.aseq.wrapping_sub(*delta as u32);
                (a, d.time_us.saturating_sub(*delta as u64 * self.packet_us), *data, true)
            })
            .collect();
        cands.push((d.aseq, d.time_us, d.data, false));
        cands.sort_by_key(|c| c.0);
        let next = *self.next.get_or_insert(d.aseq);
        let mut next = next;
        for (aseq, time_us, data, recovered) in cands {
            if aseq < next {
                if !recovered && aseq.saturating_add(1) < next {
                    self.stats.late += 1;
                }
                continue;
            }
            let gap = aseq - next;
            self.stats.lost += gap as u64;
            self.stats.packets += 1;
            if recovered {
                self.stats.recovered += 1;
            }
            out.push(AudioPacket { stream: self.id, aseq, time_us, data: data.to_vec(), recovered, gap_before: gap });
            next = aseq.saturating_add(1);
        }
        self.next = Some(next);
    }

    fn note_primary(&mut self, aseq: u32) {
        self.primaries.insert(aseq);
        let high = self.highest.map_or(aseq, |h| h.max(aseq));
        self.highest = Some(high);
        let floor = high.saturating_sub(Self::LOSS_SPAN - 1);
        while self.primaries.first().is_some_and(|&a| a < floor) {
            self.primaries.pop_first();
        }
    }

    /// Pre-redundancy loss over the last ≈ 2 s, per mille.
    pub(crate) fn loss_permille(&self) -> u16 {
        let (Some(high), Some(&low)) = (self.highest, self.primaries.first()) else { return 0 };
        let expected = (high - low + 1) as usize;
        let got = self.primaries.len();
        ((expected.saturating_sub(got)) * 1000 / expected.max(1)) as u16
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redundancy_steps() {
        assert_eq!(redundancy_for(0), 0);
        assert_eq!(redundancy_for(4), 0);
        assert_eq!(redundancy_for(5), 1);
        assert_eq!(redundancy_for(49), 1);
        assert_eq!(redundancy_for(50), 2);
    }

    #[test]
    fn recovers_from_redundancy_in_order() {
        let mut tx = AudioStreamSender::new(0);
        tx.redundancy = 2;
        let mut rx = AudioStreamReceiver::new(0);
        let mut out = Vec::new();
        for i in 0..10u32 {
            let (_, d) = tx.packet(Micros(0), i as u64 * 20_000, &[i as u8; 10], 1200);
            if i == 3 || i == 4 || i == 7 {
                continue;
            }
            rx.on_datagram(&AudioDatagram::parse(&d).unwrap(), &mut out);
        }
        let seqs: Vec<u32> = out.iter().map(|p| p.aseq).collect();
        assert_eq!(seqs, (0..10).collect::<Vec<_>>());
        assert!(out[3].recovered && out[4].recovered && out[7].recovered);
        assert_eq!(out[3].time_us, 60_000);
        assert!(out.iter().all(|p| p.gap_before == 0));
        assert_eq!(rx.stats.recovered, 3);
        assert_eq!(rx.loss_permille(), 300);
    }

    #[test]
    fn gaps_without_redundancy() {
        let mut tx = AudioStreamSender::new(0);
        let mut rx = AudioStreamReceiver::new(0);
        let mut out = Vec::new();
        let mut late = None;
        for i in 0..6u32 {
            let (_, d) = tx.packet(Micros(0), i as u64 * 20_000, &[1], 1200);
            if i == 2 {
                late = Some(d);
                continue;
            }
            rx.on_datagram(&AudioDatagram::parse(&d).unwrap(), &mut out);
        }
        // the late one is dropped, not delivered out of order
        rx.on_datagram(&AudioDatagram::parse(late.as_ref().unwrap()).unwrap(), &mut out);
        let seqs: Vec<(u32, u32)> = out.iter().map(|p| (p.aseq, p.gap_before)).collect();
        assert_eq!(seqs, vec![(0, 0), (1, 0), (3, 1), (4, 0), (5, 0)]);
        assert_eq!(rx.stats.lost, 1);
    }
}
