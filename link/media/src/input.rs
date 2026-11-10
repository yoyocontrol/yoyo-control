//! Input reliability (LINK.md §5.5). Discrete events (down / up / click / key / text / scroll) arrive exactly once
//! and in order; pointer moves are latest-wins.
//!
//! The sender puts **every** unacked discrete event (oldest first, as many as fit) and the newest move into each
//! input datagram. So a datagram's discrete events are always a prefix of what the receiver still lacks: the
//! receiver applies the ones above its contiguous point in order and acks that point; seqs between them that it
//! never saw were moves.

use std::collections::VecDeque;

use crate::time::Micros;
use crate::wire::{InputDatagram, InputEventWire, InputKind};

/// Input settings.
#[derive(Clone, Debug)]
pub struct InputConfig {
    /// Unacked discrete events at most; more is refused locally (`InputError::Overflow`, report 429).
    pub max_unacked: usize,
    /// A new event goes out at once and once more after this.
    pub duplicate_after: Micros,
    /// Unacked events are re-sent every `max(min_resend, rtt / 4)` …
    pub min_resend: Micros,
    /// … for this long, then dropped with `InputFailed`.
    pub give_up_after: Micros,
}

impl Default for InputConfig {
    fn default() -> InputConfig {
        InputConfig {
            max_unacked: 64,
            duplicate_after: Micros::from_millis(5),
            min_resend: Micros::from_millis(10),
            give_up_after: Micros::from_secs(2),
        }
    }
}

/// Why an input event was refused locally.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputError {
    /// Too many unacked discrete events (answer like HTTP 429).
    Overflow,
    /// The event alone doesn't fit a datagram.
    TooLarge,
}

impl std::fmt::Display for InputError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InputError::Overflow => write!(f, "too many unacknowledged input events"),
            InputError::TooLarge => write!(f, "input event too large for a datagram"),
        }
    }
}

impl std::error::Error for InputError {}

struct Pending {
    seq: u32,
    json: Vec<u8>,
    created: Micros,
    first_sent: Option<Micros>,
}

/// What the input sender tells the app.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum InputNotice {
    Acked { through: u32 },
    Failed { seq: u32 },
}

/// The client's input sender.
pub(crate) struct InputSender {
    cfg: InputConfig,
    next_seq: u32,
    unacked: VecDeque<Pending>,
    newest_move: Option<(Pending, u8)>,
    send_now: bool,
    duplicate_at: Option<Micros>,
    resend_at: Option<Micros>,
    acked: u32,
    rtt: Micros,
    /// First send → ack, ms (recent).
    pub(crate) rtts: VecDeque<f64>,
    pub(crate) sent_events: u64,
    pub(crate) failed: u64,
    pub(crate) acked_events: u64,
    pub(crate) datagrams: u64,
}

impl InputSender {
    pub(crate) fn new(cfg: InputConfig) -> InputSender {
        InputSender {
            cfg,
            next_seq: 1,
            unacked: VecDeque::new(),
            newest_move: None,
            send_now: false,
            duplicate_at: None,
            resend_at: None,
            acked: 0,
            rtt: Micros::from_millis(100),
            rtts: VecDeque::new(),
            sent_events: 0,
            failed: 0,
            acked_events: 0,
            datagrams: 0,
        }
    }

    pub(crate) fn set_rtt(&mut self, rtt: Micros) {
        self.rtt = rtt;
    }

    pub(crate) fn send(
        &mut self,
        now: Micros,
        kind: InputKind,
        json: &[u8],
        max_datagram: usize,
    ) -> Result<u32, InputError> {
        if InputDatagram::HEADER_LEN + 7 + json.len() > max_datagram || json.len() > u16::MAX as usize {
            return Err(InputError::TooLarge);
        }
        if kind == InputKind::Discrete && self.unacked.len() >= self.cfg.max_unacked {
            return Err(InputError::Overflow);
        }
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1).max(1);
        let p = Pending { seq, json: json.to_vec(), created: now, first_sent: None };
        match kind {
            InputKind::Discrete => self.unacked.push_back(p),
            InputKind::Move => self.newest_move = Some((p, 0)),
        }
        self.sent_events += 1;
        self.send_now = true;
        self.duplicate_at = Some(now + self.cfg.duplicate_after);
        Ok(seq)
    }

    fn resend_interval(&self) -> Micros {
        self.cfg.min_resend.max(Micros(self.rtt.0 / 4))
    }

    /// Drop events older than `give_up_after`.
    fn expire(&mut self, now: Micros, notices: &mut Vec<InputNotice>) {
        while self.unacked.front().is_some_and(|p| now - p.created >= self.cfg.give_up_after) {
            if let Some(p) = self.unacked.pop_front() {
                self.failed += 1;
                notices.push(InputNotice::Failed { seq: p.seq });
            }
        }
        if self.newest_move.as_ref().is_some_and(|(p, _)| now - p.created >= self.cfg.give_up_after) {
            self.newest_move = None;
        }
    }

    pub(crate) fn poll_transmit(
        &mut self,
        now: Micros,
        max_datagram: usize,
        notices: &mut Vec<InputNotice>,
    ) -> Option<Vec<u8>> {
        self.expire(now, notices);
        let dup = self.duplicate_at.is_some_and(|t| t <= now);
        let resend = self.resend_at.is_some_and(|t| t <= now) && !self.unacked.is_empty();
        if !(self.send_now || dup || resend) {
            return None;
        }
        self.send_now = false;
        if dup {
            self.duplicate_at = None;
        }
        // the newest move: in its first two datagrams, and in resends while discrete events are unacked
        let include_move = self.newest_move.as_ref().is_some_and(|(_, n)| *n < 2 || !self.unacked.is_empty());
        let mut budget = max_datagram.saturating_sub(InputDatagram::HEADER_LEN);
        let move_len = self.newest_move.as_ref().filter(|_| include_move).map_or(0, |(p, _)| 7 + p.json.len());
        budget = budget.saturating_sub(move_len);
        let mut events = Vec::new();
        for p in self.unacked.iter_mut() {
            let len = 7 + p.json.len();
            if len > budget {
                break;
            }
            budget -= len;
            p.first_sent.get_or_insert(now);
            events.push(InputEventWire { seq: p.seq, kind: InputKind::Discrete, json: &p.json });
        }
        if include_move && let Some((p, n)) = self.newest_move.as_mut() {
            *n = n.saturating_add(1);
            p.first_sent.get_or_insert(now);
            let at = events.partition_point(|e| e.seq < p.seq);
            events.insert(at, InputEventWire { seq: p.seq, kind: InputKind::Move, json: &p.json });
        }
        if events.is_empty() {
            return None;
        }
        let mut out = Vec::with_capacity(max_datagram);
        InputDatagram { flags: 0, events }.write(&mut out);
        self.resend_at = (!self.unacked.is_empty()).then(|| now + self.resend_interval());
        self.datagrams += 1;
        Some(out)
    }

    pub(crate) fn on_ack(&mut self, now: Micros, through: u32, notices: &mut Vec<InputNotice>) {
        if through <= self.acked && self.acked != 0 {
            return;
        }
        let mut any = false;
        while self.unacked.front().is_some_and(|p| p.seq <= through) {
            if let Some(p) = self.unacked.pop_front() {
                if let Some(t) = p.first_sent {
                    self.rtts.push_back((now - t).as_millis_f64());
                    if self.rtts.len() > 512 {
                        self.rtts.pop_front();
                    }
                }
                self.acked_events += 1;
                any = true;
            }
        }
        self.acked = self.acked.max(through);
        if self.unacked.is_empty() {
            self.resend_at = None;
        }
        if any {
            notices.push(InputNotice::Acked { through });
        }
    }

    pub(crate) fn poll_timeout(&self, now: Micros) -> Option<Micros> {
        if self.send_now {
            return Some(now);
        }
        let mut t = self.duplicate_at;
        if !self.unacked.is_empty() {
            t = crate::time::earliest(t, self.resend_at);
            t = crate::time::earliest(t, self.unacked.front().map(|p| p.created + self.cfg.give_up_after));
        }
        t
    }

    pub(crate) fn unacked(&self) -> usize {
        self.unacked.len()
    }
}

/// One input event for the server's input handler, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InputEvent {
    pub seq: u32,
    pub kind: InputKind,
    /// Today's `/input` JSON body.
    pub json: Vec<u8>,
}

/// The server's input receiver.
#[derive(Default)]
pub(crate) struct InputReceiver {
    /// Every discrete event up to here was applied.
    applied: u32,
    last_move: u32,
    pub(crate) ack_due: bool,
    pub(crate) events: u64,
    pub(crate) duplicates: u64,
}

impl InputReceiver {
    pub(crate) fn on_datagram(&mut self, d: &InputDatagram<'_>, out: &mut Vec<InputEvent>) {
        let mut events: Vec<&InputEventWire<'_>> = d.events.iter().collect();
        events.sort_by_key(|e| e.seq);
        for e in events {
            match e.kind {
                InputKind::Discrete => {
                    self.ack_due = true;
                    if e.seq <= self.applied {
                        self.duplicates += 1;
                        continue;
                    }
                    self.applied = e.seq;
                    self.events += 1;
                    out.push(InputEvent { seq: e.seq, kind: e.kind, json: e.json.to_vec() });
                }
                InputKind::Move => {
                    if e.seq <= self.last_move || e.seq <= self.applied {
                        continue;
                    }
                    self.last_move = e.seq;
                    self.events += 1;
                    out.push(InputEvent { seq: e.seq, kind: e.kind, json: e.json.to_vec() });
                }
            }
        }
    }

    pub(crate) fn ack(&mut self) -> u32 {
        self.ack_due = false;
        self.applied
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn deliver(tx_out: &[u8], rx: &mut InputReceiver) -> Vec<InputEvent> {
        let mut out = Vec::new();
        rx.on_datagram(&InputDatagram::parse(tx_out).unwrap(), &mut out);
        out
    }

    #[test]
    fn exactly_once_in_order_with_losses() {
        let mut tx = InputSender::new(InputConfig::default());
        let mut rx = InputReceiver::default();
        let mut n = Vec::new();
        let mut applied = Vec::new();
        let mut t = Micros::ZERO;
        let mut lost = 0;
        for i in 0..50u32 {
            let kind = if i % 3 == 0 { InputKind::Move } else { InputKind::Discrete };
            tx.send(t, kind, format!("{{\"i\":{i}}}").as_bytes(), 1200).unwrap();
            for _ in 0..4 {
                if let Some(d) = tx.poll_transmit(t, 1200, &mut n) {
                    lost += 1;
                    // drop every other datagram
                    if lost % 2 == 0 {
                        applied.extend(deliver(&d, &mut rx));
                        if rx.ack_due {
                            let a = rx.ack();
                            tx.on_ack(t + Micros::from_millis(5), a, &mut n);
                        }
                    }
                }
                t += Micros::from_millis(6);
            }
        }
        let discrete: Vec<u32> = applied.iter().filter(|e| e.kind == InputKind::Discrete).map(|e| e.seq).collect();
        let want: Vec<u32> = (0..50u32).filter(|i| i % 3 != 0).map(|i| i + 1).collect();
        assert_eq!(discrete, want);
        let moves: Vec<u32> = applied.iter().filter(|e| e.kind == InputKind::Move).map(|e| e.seq).collect();
        assert!(moves.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(tx.unacked(), 0);
    }

    #[test]
    fn overflow_and_give_up() {
        let mut tx = InputSender::new(InputConfig::default());
        let mut n = Vec::new();
        for _ in 0..64 {
            tx.send(Micros::ZERO, InputKind::Discrete, b"{}", 1200).unwrap();
        }
        assert_eq!(tx.send(Micros::ZERO, InputKind::Discrete, b"{}", 1200), Err(InputError::Overflow));
        assert!(tx.send(Micros::ZERO, InputKind::Move, b"{}", 1200).is_ok());
        assert_eq!(tx.send(Micros::ZERO, InputKind::Move, &[b' '; 1200], 1200), Err(InputError::TooLarge));
        // 64 events × 9 bytes don't fit one 300-byte datagram: the oldest go first
        let d = tx.poll_transmit(Micros::ZERO, 300, &mut n).unwrap();
        let p = InputDatagram::parse(&d).unwrap();
        assert!(p.events.len() < 65 && p.events[0].seq == 1);
        assert!(tx.poll_transmit(Micros::from_secs(2), 1200, &mut n).is_none() || !n.is_empty());
        assert_eq!(n.iter().filter(|x| matches!(x, InputNotice::Failed { .. })).count(), 64);
    }

    #[test]
    fn timing() {
        let mut tx = InputSender::new(InputConfig::default());
        tx.set_rtt(Micros::from_millis(80));
        let mut n = Vec::new();
        tx.send(Micros::ZERO, InputKind::Discrete, b"{}", 1200).unwrap();
        assert_eq!(tx.poll_timeout(Micros::ZERO), Some(Micros::ZERO));
        assert!(tx.poll_transmit(Micros::ZERO, 1200, &mut n).is_some());
        // duplicate after 5 ms
        assert_eq!(tx.poll_timeout(Micros::ZERO), Some(Micros::from_millis(5)));
        assert!(tx.poll_transmit(Micros::from_millis(5), 1200, &mut n).is_some());
        // then every rtt/4 = 20 ms
        assert_eq!(tx.poll_timeout(Micros::from_millis(5)), Some(Micros::from_millis(25)));
        tx.on_ack(Micros::from_millis(40), 1, &mut n);
        assert_eq!(tx.poll_timeout(Micros::from_millis(40)), None);
        assert_eq!(tx.rtts.back().copied(), Some(40.0));
    }
}
