//! Per-frame trace records (field tests): every video frame's way out on the server ([`TxTrace`], taken with
//! [`crate::ServerMedia::take_tx_traces`]) and its fate on the client ([`RxTrace`],
//! [`crate::ClientMedia::take_rx_traces`]). Cheap bookkeeping; the app decides whether to write them anywhere.

use std::collections::VecDeque;

use crate::time::Micros;

/// At most this many finished records wait to be taken (the oldest go first).
pub(crate) const MAX_DONE: usize = 4096;

/// One sent video frame, from the moment it was queued until the receiver reported it (or 3 s passed).
#[derive(Clone, Debug, PartialEq)]
pub struct TxTrace {
    pub stream: u8,
    pub frame: u32,
    /// [`crate::FrameKind`] as its wire value.
    pub kind: u8,
    /// The access unit's bytes.
    pub au_bytes: u32,
    /// Its datagrams (data and parity shards, headers included).
    pub wire_bytes: u32,
    pub datagrams: u16,
    pub parity: u16,
    pub enqueued_at: Micros,
    /// Video and retransmit bytes waiting in this crate's queues ahead of it when it was queued.
    pub queued_ahead: u32,
    /// When its first / last original datagram left `poll_transmit` (paced).
    pub first_out: Option<Micros>,
    pub last_out: Option<Micros>,
    /// Its shards re-sent for NACKs.
    pub retransmits: u16,
    /// The frame report that first said it (or a later one) was delivered: decoded OK on the receiver.
    pub delivered_at: Option<Micros>,
    /// The receiver reported it lost.
    pub lost: bool,
    pub target_bps: u64,
    pub pacing_bps: u64,
    pub fec_ratio: f32,
    /// The rate controller's standing queue and the transport's RTT when it was queued.
    pub queue_delay_us: Option<u64>,
    pub rtt_us: Option<u64>,
}

/// How a frame ended on the receiver.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RxFate {
    /// Handed to the decoder.
    Delivered,
    /// Complete (or known) but not usable: the chain was broken, or a later key / recovery frame overtook it.
    Skipped,
    /// It could not complete in time.
    Lost,
}

/// One frame on the receiver, from its first shard to its fate.
#[derive(Clone, Debug, PartialEq)]
pub struct RxTrace {
    pub stream: u8,
    pub frame: u32,
    pub fate: RxFate,
    /// [`crate::FrameKind`] as its wire value (complete frames only).
    pub kind: Option<u8>,
    /// The access unit's bytes (complete frames only).
    pub au_bytes: u32,
    /// The sender's capture time (complete frames only; the sender's clock, µs since 1970).
    pub capture_us: Option<u64>,
    /// None: no shard of it ever came (known only from a later frame).
    pub first_arrival: Option<Micros>,
    pub last_arrival: Option<Micros>,
    pub completed_at: Option<Micros>,
    pub decided_at: Micros,
    /// Shards that arrived and were used (originals and retransmits).
    pub shards: u16,
    /// Data shards Reed-Solomon restored.
    pub fec: u16,
    /// Retransmitted shards that arrived in time.
    pub retx: u16,
    /// NACK items sent for it (a shard, a whole block or "this block and later" each count once).
    pub nack_items: u16,
}

/// Finished records waiting for the app, bounded.
pub(crate) struct TraceQueue<T> {
    items: VecDeque<T>,
    pub(crate) dropped: u64,
}

impl<T> Default for TraceQueue<T> {
    fn default() -> Self {
        TraceQueue { items: VecDeque::new(), dropped: 0 }
    }
}

impl<T> TraceQueue<T> {
    pub(crate) fn push(&mut self, t: T) {
        if self.items.len() >= MAX_DONE {
            self.items.pop_front();
            self.dropped += 1;
        }
        self.items.push_back(t);
    }

    pub(crate) fn take(&mut self) -> Vec<T> {
        self.items.drain(..).collect()
    }
}
