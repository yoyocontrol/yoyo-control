//! Datagram channels: byte 0 of every datagram is `channel << 4 | version` (version 1). Each channel has its own
//! receive queue; what is in the rest of the datagram is the channel's business (the media layer's codecs).

use std::sync::atomic::{AtomicU64, Ordering};

use bytes::{BufMut, Bytes, BytesMut};
use tokio::sync::{Mutex, mpsc};

use crate::error::{LinkError, Result};

pub const DATAGRAM_VERSION: u8 = 1;

/// The channels of the media layer.
pub mod channel {
    pub const VIDEO: u8 = 1;
    pub const AUDIO: u8 = 2;
    pub const INPUT: u8 = 3;
    pub const FEEDBACK: u8 = 4;
    pub const CURSOR: u8 = 5;
}

/// Channels are 1…15 (0 is reserved).
pub const MAX_CHANNEL: u8 = 15;
/// Datagrams held per channel before new ones are dropped (the reader is late).
pub const QUEUE_DEPTH: usize = 2048;

pub fn header(channel: u8) -> u8 {
    channel << 4 | DATAGRAM_VERSION
}

/// The channel of a datagram, or `None` when its version or channel is not ours.
pub fn parse_header(datagram: &[u8]) -> Option<u8> {
    let b = *datagram.first()?;
    let channel = b >> 4;
    (b & 0x0f == DATAGRAM_VERSION && channel >= 1).then_some(channel)
}

pub(crate) fn check_channel(channel: u8) -> Result<()> {
    if (1..=MAX_CHANNEL).contains(&channel) {
        Ok(())
    } else {
        Err(LinkError::InvalidArgument(format!("datagram channel {channel} is not 1…15")))
    }
}

/// `header(channel)` then `payload`.
pub fn frame(channel: u8, payload: &[u8]) -> Bytes {
    let mut b = BytesMut::with_capacity(1 + payload.len());
    b.put_u8(header(channel));
    b.put_slice(payload);
    b.freeze()
}

#[derive(Debug, Default)]
pub(crate) struct Counters {
    pub sent: AtomicU64,
    pub received: AtomicU64,
    pub drops: AtomicU64,
}

impl Counters {
    pub(crate) fn drop_one(&self) {
        self.drops.fetch_add(1, Ordering::Relaxed);
    }
}

#[derive(Debug)]
pub(crate) struct Mux {
    tx: std::sync::RwLock<Vec<mpsc::Sender<Bytes>>>,
    rx: Vec<Mutex<mpsc::Receiver<Bytes>>>,
    pub counters: Counters,
}

impl Mux {
    pub(crate) fn new() -> Self {
        let mut tx = Vec::new();
        let mut rx = Vec::new();
        for _ in 0..=MAX_CHANNEL {
            let (t, r) = mpsc::channel(QUEUE_DEPTH);
            tx.push(t);
            rx.push(Mutex::new(r));
        }
        Mux { tx: std::sync::RwLock::new(tx), rx, counters: Counters::default() }
    }

    /// Routes one received datagram to its channel's queue.
    pub(crate) fn deliver(&self, datagram: Bytes) {
        self.counters.received.fetch_add(1, Ordering::Relaxed);
        let Some(ch) = parse_header(&datagram) else {
            self.counters.drop_one();
            return;
        };
        let tx = self.tx.read().unwrap();
        if tx.get(ch as usize).is_none_or(|t| t.try_send(datagram).is_err()) {
            self.counters.drop_one();
        }
    }

    /// The next datagram of `channel` (whole, byte 0 included); `None` when the session is gone.
    pub(crate) async fn recv(&self, channel: u8) -> Result<Option<Bytes>> {
        check_channel(channel)?;
        Ok(self.rx[channel as usize].lock().await.recv().await)
    }

    /// Like `recv` without waiting: `Ok(None)` when the queue is empty.
    pub(crate) fn try_recv(&self, channel: u8) -> Result<Option<Bytes>> {
        check_channel(channel)?;
        let Ok(mut rx) = self.rx[channel as usize].try_lock() else { return Ok(None) };
        Ok(rx.try_recv().ok())
    }

    /// Ends every queue (readers get `None` after what is queued).
    pub(crate) fn close(&self) {
        self.tx.write().unwrap().clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn routes_by_channel_and_counts_drops() {
        let mux = Mux::new();
        mux.deliver(frame(channel::VIDEO, b"v1"));
        mux.deliver(frame(channel::INPUT, b"i1"));
        mux.deliver(Bytes::from_static(&[0x12, 0])); // version 2
        mux.deliver(Bytes::from_static(&[0x01])); // channel 0
        mux.deliver(Bytes::new());
        assert_eq!(&mux.recv(channel::INPUT).await.unwrap().unwrap()[..], &[0x31, b'i', b'1']);
        assert_eq!(&mux.recv(channel::VIDEO).await.unwrap().unwrap()[1..], b"v1");
        assert!(mux.try_recv(channel::AUDIO).unwrap().is_none());
        assert_eq!(mux.counters.drops.load(Ordering::Relaxed), 3);
        assert!(mux.recv(0).await.is_err());
        assert!(mux.recv(16).await.is_err());
        for _ in 0..QUEUE_DEPTH + 5 {
            mux.deliver(frame(channel::CURSOR, b"c"));
        }
        assert_eq!(mux.counters.drops.load(Ordering::Relaxed), 8);
        mux.close();
        assert!(mux.recv(channel::CURSOR).await.unwrap().is_some(), "queued datagrams are still read");
        let mut n = 1;
        while mux.recv(channel::CURSOR).await.unwrap().is_some() {
            n += 1;
        }
        assert_eq!(n, QUEUE_DEPTH);
    }

    #[test]
    fn headers() {
        assert_eq!(header(channel::VIDEO), 0x11);
        assert_eq!(header(channel::CURSOR), 0x51);
        assert_eq!(parse_header(&[0x41, 9]), Some(4));
        assert_eq!(parse_header(&[0x40]), None);
    }
}
