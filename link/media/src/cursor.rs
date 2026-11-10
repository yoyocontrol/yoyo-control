//! Cursor positions (datagram channel 5): latest `cseq` wins. The sender keeps only the newest unsent position and
//! repeats the last one once after it settled (a lost final position would otherwise stick until the next move).

use crate::time::Micros;
use crate::wire::CursorDatagram;

pub(crate) struct CursorSender {
    pub(crate) id: u8,
    next_cseq: u32,
    pending: Option<Vec<u8>>,
    last: Option<(u32, Vec<u8>)>,
    repeat_at: Option<Micros>,
}

impl CursorSender {
    /// The settled position is sent once more after this.
    const REPEAT_AFTER: Micros = Micros::from_millis(50);

    pub(crate) fn new(id: u8) -> CursorSender {
        CursorSender { id, next_cseq: 1, pending: None, last: None, repeat_at: None }
    }

    pub(crate) fn update(&mut self, json: &[u8]) {
        self.pending = Some(json.to_vec());
    }

    pub(crate) fn poll(&mut self, now: Micros) -> Option<Vec<u8>> {
        let (cseq, json) = if let Some(json) = self.pending.take() {
            let c = self.next_cseq;
            self.next_cseq = self.next_cseq.wrapping_add(1).max(1);
            self.repeat_at = Some(now + Self::REPEAT_AFTER);
            self.last = Some((c, json.clone()));
            (c, json)
        } else if self.repeat_at.is_some_and(|t| t <= now) {
            self.repeat_at = None;
            self.last.clone()?
        } else {
            return None;
        };
        let mut out = Vec::with_capacity(CursorDatagram::HEADER_LEN + json.len());
        CursorDatagram { stream: self.id, tseq: 0, cseq, json: &json }.write(&mut out);
        Some(out)
    }

    pub(crate) fn poll_timeout(&self, now: Micros) -> Option<Micros> {
        if self.pending.is_some() { Some(now) } else { self.repeat_at }
    }
}

#[derive(Default)]
pub(crate) struct CursorReceiver {
    last: u32,
}

impl CursorReceiver {
    /// True if this position is newer than the last one shown.
    pub(crate) fn accept(&mut self, cseq: u32) -> bool {
        if cseq > self.last {
            self.last = cseq;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn latest_wins_and_repeats_once() {
        let mut tx = CursorSender::new(0);
        let mut rx = CursorReceiver::default();
        tx.update(b"1");
        tx.update(b"2");
        let d = tx.poll(Micros::ZERO).unwrap();
        let c = CursorDatagram::parse(&d).unwrap();
        assert_eq!((c.cseq, c.json), (1, &b"2"[..]));
        assert!(rx.accept(1));
        assert!(tx.poll(Micros::from_millis(10)).is_none());
        let r = tx.poll(Micros::from_millis(50)).unwrap();
        assert_eq!(CursorDatagram::parse(&r).unwrap().cseq, 1);
        assert!(!rx.accept(1));
        assert!(tx.poll(Micros::from_millis(200)).is_none());
    }
}
