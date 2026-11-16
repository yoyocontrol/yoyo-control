//! One peer connection (str0m `Rtc`) as a session's connection: the control and datagram channels, one channel per
//! RPC stream, close with code and reason, the selected path and its RTT.
//!
//! str0m is sans-IO: every mutation of the `Rtc` (a packet, a timeout, a channel write) is followed by draining its
//! output (packets go out on the hub's socket, events update the state here). All of it happens under the peer's
//! lock, from whichever task made the mutation; a driver task per peer handles the timeouts. Waiters (stream readers
//! and writers, the accept loop) re-check their condition whenever an event changed something.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    future::Future,
    net::SocketAddr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

use bytes::Bytes;
use str0m::{
    Event, IceConnectionState, Input, Output, Rtc,
    channel::{ChannelConfig, ChannelId, Reliability},
};
use tokio::sync::{Notify, mpsc, watch};

use super::{
    CONTROL_CHANNEL_ID, CONTROL_LABEL, DGRAM_CHANNEL_ID, DGRAM_LABEL, MAX_DATAGRAM, RPC_LABEL, hub::Hub,
    signal::SdpCandidate,
};
use crate::{
    endpoint::MAX_RPC_STREAMS,
    error::{CloseCode, LinkError, Result},
    log::debug,
    media::SEND_BUFFER,
    path::{PathInfo, PathKind, is_local_ip},
    rpc::{RTC_CREDIT_INITIAL, RTC_CREDIT_WINDOW, RTC_MESSAGE_COST, RTC_RPC_RECV_MAX, RTC_SESSION_RECV_MAX},
    session::{CloseInfo, Side},
    transport::TransportCounters,
};

/// Stream writes go out in messages of at most this size (no SCTP message interleaving: a big message would hold up
/// every other channel).
const CHUNK: usize = 16 * 1024;
/// A stream writer waits while its channel holds this much (SCTP counts what is in flight too: ~44 Mbps at 95 ms).
const STREAM_HIGH: usize = 192 * 1024;
/// Datagrams move from the session's queue into SCTP while the `dgram` channel holds less than this (in flight
/// included, so at least a bandwidth-delay product: ~88 Mbps at 95 ms); the rest waits in the session's queue, where
/// the oldest give way to new ones. SCTP's window doesn't shrink on loss (vendor/sctp-proto), so what SCTP holds is
/// in flight, not queued: the free send buffer is counted from the session's queue alone.
const DGRAM_SCTP_HIGH: usize = 1 << 20;
/// Datagrams from the peer waiting for the session's reader.
const DGRAM_QUEUE: usize = 4096;
/// Finished RPC channels the server keeps open for the client to close.
const MAX_FINISHED_OPEN: usize = 64;
/// After a local close: the `bye` has this long to leave before the peer connection closes.
const CLOSE_FLUSH: Duration = Duration::from_millis(250);
/// The connection lost connectivity (ICE `disconnected`) this long: the session ends.
const LOST_GRACE: Duration = Duration::from_secs(10);
/// A closing `Rtc` that still hasn't drained its last packets after this is dropped.
const CLOSE_DRAIN: Duration = Duration::from_secs(1);
/// What one message waiting in an inbox costs on top of its bytes (its `Bytes`, its queue slot, the allocation):
/// counted against the receive limits (and the credit window, by both sides), so a peer can't get past them with a
/// flood of tiny messages.
const INBOX_ENTRY_COST: usize = RTC_MESSAGE_COST;
/// A grant goes out once it would add at least this much (no grant per message)…
const CREDIT_MIN_GRANT: u64 = 64 * 1024;
/// …or whenever the peer has less left than its largest message costs (it couldn't send at all).
const CREDIT_CHUNK_COST: u64 = (CHUNK + RTC_MESSAGE_COST) as u64;

pub(crate) fn control_config() -> ChannelConfig {
    ChannelConfig {
        label: CONTROL_LABEL.into(),
        ordered: true,
        reliability: Reliability::Reliable,
        negotiated: Some(CONTROL_CHANNEL_ID),
        protocol: String::new(),
    }
}

pub(crate) fn dgram_config() -> ChannelConfig {
    ChannelConfig {
        label: DGRAM_LABEL.into(),
        ordered: false,
        reliability: Reliability::MaxRetransmits { retransmits: 0 },
        negotiated: Some(DGRAM_CHANNEL_ID),
        protocol: String::new(),
    }
}

fn rpc_config() -> ChannelConfig {
    ChannelConfig {
        label: RPC_LABEL.into(),
        ordered: true,
        reliability: Reliability::Reliable,
        negotiated: None,
        protocol: String::new(),
    }
}

#[derive(Debug, Default)]
struct Stream {
    inbox: VecDeque<Bytes>,
    /// What `inbox` costs: its bytes plus `INBOX_ENTRY_COST` per message.
    inbox_bytes: usize,
    /// At most this much unread (`inbox_bytes`): past it the channel is reset. A data channel has no receive window of
    /// its own, so this is what keeps a peer that writes and never stops from filling memory. Every server-side RPC
    /// channel has one from its open (`RTC_RPC_RECV_MAX`), set again once its head is read (`RtcRecv::limit`: a
    /// request's body limit and some, a duplex stream's `RTC_DUPLEX_RECV_MAX`). None = no limit (the control
    /// channel; a client's RPC answers, which its app reads).
    recv_cap: Option<usize>,
    /// Its unread bytes count against the session's `St::inbox_total` (a duplex stream's).
    shared: bool,
    /// The peer's zero-length message arrived.
    fin_in: bool,
    /// The channel closed (either side).
    closed: bool,
    /// The reader is not interested in the rest.
    discard: bool,
    /// This side sent its FIN.
    fin_out: bool,
    /// Halves (`RtcSend`, `RtcRecv`) still held; at 0 the channel is closed and forgotten.
    handles: u8,
    /// The credit window (docs/LINK.md「信用窗口」): both sides took it (`St::credit` when the stream began).
    credit: Option<Credit>,
}

/// One stream's credit, both directions, in what both sides count: each non-empty binary message's length plus
/// `RTC_MESSAGE_COST` (the FIN is free). Totals since the stream began.
#[derive(Debug)]
struct Credit {
    /// Receiving: what this side allowed the peer to send (`RTC_CREDIT_INITIAL` and every grant).
    granted: u64,
    /// Receiving: what came.
    received: u64,
    /// Receiving: what the reader took out of the inbox (or was dropped: `discard`).
    consumed: u64,
    /// Sending: what the peer allowed (its grants).
    peer_granted: u64,
    /// Sending: what went.
    sent: u64,
}

impl Credit {
    fn new() -> Credit {
        let initial = RTC_CREDIT_INITIAL as u64;
        Credit { granted: initial, received: 0, consumed: 0, peer_granted: initial, sent: 0 }
    }

    /// What the peer may still send plus what waits unread: this side's commitment.
    fn commitment(&self) -> u64 {
        self.granted - self.consumed
    }

    /// What came and wasn't read: what this stream holds of the session's pool.
    fn unread(&self) -> u64 {
        self.received - self.consumed
    }
}

fn message_cost(len: usize) -> u64 {
    if len == 0 { 0 } else { (len + RTC_MESSAGE_COST) as u64 }
}

struct St {
    rtc: Rtc,
    /// str0m's next timeout.
    timeout: Instant,
    /// What the driver sleeps until (app calls wake it only for something earlier).
    driver_at: Instant,
    control: Option<ChannelId>,
    dgram: Option<ChannelId>,
    open: HashSet<ChannelId>,
    streams: HashMap<ChannelId, Stream>,
    /// `inbox_bytes` of every `Stream::shared` one: at most `RTC_SESSION_RECV_MAX`, past it the stream whose message
    /// would go over is reset (32 duplex streams each just under their own cap would be ~70 MiB).
    inbox_total: usize,
    /// The credit window was negotiated (`credit` in both `hello` and `welcome`): streams from now on use it.
    credit: bool,
    /// A grant was held back for the session's pool: grants are tried again for every stream as the pool frees.
    credit_starved: bool,
    /// A grant's write was refused (the connection's buffer was full): tried again after the next input.
    grants_pending: bool,
    /// Tests (`test-hooks`): this many more grant writes are refused as if the buffer were full.
    #[cfg(feature = "test-hooks")]
    refuse_grants: u32,
    /// RPC channels the peer opened, not yet taken by `accept_stream`.
    incoming: VecDeque<ChannelId>,
    accepting: bool,
    dgram_out: VecDeque<Bytes>,
    dgram_tx: Option<mpsc::Sender<Bytes>>,
    connected: bool,
    lost_since: Option<Instant>,
    rtt: Option<Duration>,
    selected: Option<(SocketAddr, SocketAddr)>,
    heard_from: Option<SocketAddr>,
    /// The peer's candidates from its SDP (which are host ones: `direct` vs `punched`).
    remote_candidates: Vec<SdpCandidate>,
    ended: bool,
    close_at: Option<Instant>,
    closing_since: Option<Instant>,
    gone: bool,
    /// A writer waits for buffer space: wake waiters after the next input (SACKs free space).
    write_blocked: bool,
    changed: bool,
}

impl St {
    /// Drops what `id`'s inbox holds (out of the session's budget too).
    fn clear_inbox(&mut self, id: ChannelId) {
        if let Some(s) = self.streams.get_mut(&id) {
            if s.shared {
                self.inbox_total -= s.inbox_bytes;
            }
            s.inbox.clear();
            s.inbox_bytes = 0;
        }
    }

    /// Forgets the stream (its unread bytes leave the session's budget; its credit frees the pool).
    fn forget(&mut self, id: ChannelId) {
        self.clear_inbox(id);
        let credit = self.streams.remove(&id).is_some_and(|s| s.credit.is_some());
        if credit && self.credit_starved {
            self.grant_all();
        }
    }

    /// What the streams other than `except` hold of the session's pool: what came on them and wasn't read (not credit
    /// given and unused: an idle stream holds none). A closed stream counts until it is forgotten (its halves
    /// dropped). The pool is for fairness (how big a new window may be); the memory bound is each stream's window:
    /// at most `MAX_RPC_STREAMS` x `RTC_CREDIT_WINDOW` (32 MiB) unread per session.
    fn credit_pool_used(&self, except: ChannelId) -> u64 {
        self.streams
            .iter()
            .filter(|(id, _)| **id != except)
            .filter_map(|(_, s)| s.credit.as_ref())
            .map(Credit::unread)
            .sum()
    }

    /// Tops up `id`'s window: to `RTC_CREDIT_WINDOW` past what was read, as far as the session's pool allows
    /// (`RTC_SESSION_RECV_MAX` of unread bytes; every stream keeps `RTC_CREDIT_INITIAL` whatever the pool, so none
    /// starves). Once half the window is used (at least `CREDIT_MIN_GRANT` more), or at once when the peer has less
    /// left than a message costs. The grant is the new total, as a text message on the channel. Then, if grants were
    /// held back and this freed the pool, the others'.
    fn grant(&mut self, id: ChannelId) {
        self.grant_one(id);
        if self.credit_starved {
            self.grant_all();
        }
    }

    fn grant_all(&mut self) {
        self.credit_starved = false;
        let ids: Vec<ChannelId> = self.streams.keys().copied().collect();
        for id in ids {
            self.grant_one(id);
        }
    }

    fn grant_one(&mut self, id: ChannelId) {
        let used = self.credit_pool_used(id);
        let Some(s) = self.streams.get_mut(&id) else { return };
        let Some(c) = s.credit.as_mut() else { return };
        if s.closed || s.fin_in || !self.open.contains(&id) {
            return;
        }
        let room = (RTC_SESSION_RECV_MAX as u64).saturating_sub(used);
        let target = (RTC_CREDIT_INITIAL as u64 + room).min(RTC_CREDIT_WINDOW as u64);
        if target < RTC_CREDIT_WINDOW as u64 {
            self.credit_starved = true;
        }
        let granted = c.consumed + target;
        if granted <= c.granted {
            return;
        }
        let left = c.granted - c.received;
        let worth = c.commitment() <= RTC_CREDIT_WINDOW as u64 / 2 && granted - c.granted >= CREDIT_MIN_GRANT;
        if !worth && left >= CREDIT_CHUNK_COST {
            return;
        }
        // raised only once the grant is on its way: a refused write (str0m's buffer for the connection is full) is
        // tried again after the next input, or the peer would wait for credit this side thinks it has
        let grant = format!("{{\"credit\":{granted}}}");
        #[cfg(feature = "test-hooks")]
        let refused = match self.refuse_grants.checked_sub(1) {
            Some(n) => {
                self.refuse_grants = n;
                true
            }
            None => false,
        };
        #[cfg(not(feature = "test-hooks"))]
        let refused = false;
        let sent = !refused
            && self.rtc.channel(id).is_some_and(|mut ch| matches!(ch.write(false, grant.as_bytes()), Ok(true)));
        if sent {
            c.granted = granted;
        } else {
            self.grants_pending = true;
            self.write_blocked = true;
        }
    }
}

pub(crate) struct Peer {
    id: u64,
    side: Side,
    hub: Arc<Hub>,
    remote_id: String,
    st: Mutex<St>,
    changed: Notify,
    timer: Notify,
    dgram_rx: tokio::sync::Mutex<mpsc::Receiver<Bytes>>,
    path: watch::Sender<PathInfo>,
    end: watch::Sender<Option<CloseInfo>>,
    bytes_sent: AtomicU64,
    bytes_received: AtomicU64,
    /// Bytes in the session's datagram queue (read without the lock: the media layer asks per frame).
    dgram_out_bytes: AtomicUsize,
}

impl std::fmt::Debug for Peer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Peer").field("id", &self.id).field("side", &self.side).finish()
    }
}

impl Peer {
    /// Wraps a negotiated `rtc` (offer accepted or answer applied) and starts its driver. `remote_id`: who the peer
    /// is (`Session::remote_id`).
    pub(crate) fn start(
        hub: Arc<Hub>,
        side: Side,
        rtc: Rtc,
        remote_candidates: Vec<SdpCandidate>,
        remote_id: String,
    ) -> Arc<Peer> {
        let (dgram_tx, dgram_rx) = mpsc::channel(DGRAM_QUEUE);
        let now = Instant::now();
        let peer = Arc::new(Peer {
            id: hub.next_peer_id(),
            side,
            hub: hub.clone(),
            remote_id,
            st: Mutex::new(St {
                rtc,
                timeout: now,
                driver_at: now,
                control: None,
                dgram: None,
                open: HashSet::new(),
                streams: HashMap::new(),
                inbox_total: 0,
                credit: false,
                credit_starved: false,
                grants_pending: false,
                #[cfg(feature = "test-hooks")]
                refuse_grants: 0,
                incoming: VecDeque::new(),
                accepting: side == Side::Server,
                dgram_out: VecDeque::new(),
                dgram_tx: Some(dgram_tx),
                connected: false,
                lost_since: None,
                rtt: None,
                selected: None,
                heard_from: None,
                remote_candidates,
                ended: false,
                close_at: None,
                closing_since: None,
                gone: false,
                write_blocked: false,
                changed: false,
            }),
            changed: Notify::new(),
            timer: Notify::new(),
            dgram_rx: tokio::sync::Mutex::new(dgram_rx),
            path: watch::channel(PathInfo::none()).0,
            end: watch::channel(None).0,
            bytes_sent: AtomicU64::new(0),
            bytes_received: AtomicU64::new(0),
            dgram_out_bytes: AtomicUsize::new(0),
        });
        hub.add_peer(peer.clone());
        tokio::spawn(drive(peer.clone()));
        peer
    }

    pub(crate) fn id(&self) -> u64 {
        self.id
    }

    /// Creates the negotiated `control` and `dgram` channels (both sides create them: no DCEP).
    pub(crate) fn open_negotiated(&self) {
        self.with(|st| {
            let c = st.rtc.direct_api().create_data_channel(control_config());
            st.control = Some(c);
            st.streams.insert(c, Stream { handles: 2, ..Stream::default() });
        });
        self.with(|st| {
            let d = st.rtc.direct_api().create_data_channel(dgram_config());
            st.dgram = Some(d);
        });
    }

    /// Like `open_negotiated`, for channels the offer already declared (the client: str0m made them with the SDP).
    pub(crate) fn adopt_negotiated(&self, control: ChannelId, dgram: ChannelId) {
        self.with(|st| {
            st.control = Some(control);
            st.dgram = Some(dgram);
            st.streams.insert(control, Stream { handles: 2, ..Stream::default() });
        });
    }

    /// An ICE restart the client offered (`Endpoint`'s `restart_rtc`): str0m takes the new ICE credentials and
    /// candidates and checks them while the old pair, if it still works, carries on; DTLS, SCTP and the channels stay.
    /// The answer SDP and this side's DTLS fingerprint (unchanged).
    pub(crate) fn restart(
        &self,
        offer: str0m::change::SdpOffer,
        remote_candidates: Vec<SdpCandidate>,
    ) -> Result<(str0m::change::SdpAnswer, String)> {
        self.with(|st| {
            if st.ended {
                return Err(LinkError::Closed("the connection ended".into()));
            }
            let answer = st
                .rtc
                .sdp_api()
                .accept_offer(offer)
                .map_err(|e| LinkError::InvalidArgument(format!("restart: {e}")))?;
            st.remote_candidates = remote_candidates;
            // a path lost meanwhile gets its grace again from now: the restart's checks need it
            if st.lost_since.is_some() {
                st.lost_since = Some(Instant::now());
            }
            st.changed = true;
            Ok((answer, super::fingerprint_string(&st.rtc.direct_api().local_dtls_fingerprint().bytes)))
        })
    }

    /// Who the peer is (`dtls-sha256:<hex>`, its DTLS certificate).
    pub(crate) fn remote_id(&self) -> &str {
        &self.remote_id
    }

    /// The session over this connection ended (closing or closed).
    pub(crate) fn is_ended(&self) -> bool {
        self.st.lock().unwrap().ended
    }

    // MARK: the state machine

    /// Runs `f`, drains str0m, wakes whoever waits on what changed.
    fn with<R>(&self, f: impl FnOnce(&mut St) -> R) -> R {
        let (r, changed, wake_driver) = {
            let mut st = self.st.lock().unwrap();
            let r = f(&mut st);
            self.drain(&mut st);
            let changed = std::mem::take(&mut st.changed);
            let next = st.close_at.map_or(st.timeout, |c| c.min(st.timeout));
            (r, changed, next < st.driver_at)
        };
        if changed {
            self.changed.notify_waiters();
        }
        if wake_driver {
            self.timer.notify_one();
        }
        r
    }

    /// A packet from the hub (from `source`): taken (`None`) or given back for another peer.
    pub(crate) fn offer<'a>(&self, source: SocketAddr, input: Input<'a>) -> Option<Input<'a>> {
        let mut back = None;
        self.with(|st| {
            if st.gone || !st.rtc.accepts(&input) {
                back = Some(input);
                return;
            }
            // until the first stats name the selected pair, the peer is where its packets come from
            if st.selected.is_none() && st.heard_from != Some(source) {
                st.heard_from = Some(source);
                self.path.send_replace(self.classify(st, source));
            }
            if let Err(e) = st.rtc.handle_input(input) {
                debug!("link: rtc input: {e}");
            }
            if st.write_blocked {
                st.write_blocked = false;
                st.changed = true;
            }
            if std::mem::take(&mut st.grants_pending) {
                st.grant_all();
            }
        });
        back
    }

    pub(crate) fn count_received(&self, n: usize) {
        self.bytes_received.fetch_add(n as u64, Ordering::Relaxed);
    }

    fn drain(&self, st: &mut St) {
        loop {
            loop {
                match st.rtc.poll_output() {
                    Ok(Output::Timeout(t)) => {
                        st.timeout = t;
                        break;
                    }
                    Ok(Output::Transmit(t)) => {
                        self.bytes_sent.fetch_add(t.contents.len() as u64, Ordering::Relaxed);
                        self.hub.send(t.source, t.destination, &t.contents);
                    }
                    Ok(Output::Event(e)) => self.on_event(st, e),
                    Err(e) => {
                        debug!("link: rtc: {e}");
                        self.finish(st, CloseInfo { code: None, reason: format!("rtc: {e}"), remote: false });
                        st.gone = true;
                        st.timeout = Instant::now() + Duration::from_secs(3600);
                        return;
                    }
                }
            }
            if !self.pump_one(st) {
                break;
            }
        }
    }

    /// Moves one queued datagram into SCTP; false when there is nothing to move or no room.
    fn pump_one(&self, st: &mut St) -> bool {
        let Some(d) = st.dgram else { return false };
        if st.ended || !st.open.contains(&d) || st.dgram_out.is_empty() {
            return false;
        }
        let Some(mut ch) = st.rtc.channel(d) else { return false };
        if ch.buffered_amount() >= DGRAM_SCTP_HIGH {
            return false;
        }
        let front = st.dgram_out.front().expect("not empty");
        match ch.write(true, front) {
            Ok(true) => {
                let b = st.dgram_out.pop_front().expect("not empty");
                self.dgram_out_bytes.fetch_sub(b.len(), Ordering::Relaxed);
                true
            }
            Ok(false) => false,
            Err(e) => {
                debug!("link: rtc dgram write: {e}");
                let b = st.dgram_out.pop_front().expect("not empty");
                self.dgram_out_bytes.fetch_sub(b.len(), Ordering::Relaxed);
                true
            }
        }
    }

    fn on_event(&self, st: &mut St, e: Event) {
        match e {
            Event::Connected => {
                st.connected = true;
                st.changed = true;
            }
            Event::IceConnectionStateChange(s) => match s {
                IceConnectionState::Disconnected => {
                    st.lost_since.get_or_insert_with(Instant::now);
                }
                IceConnectionState::Connected | IceConnectionState::Completed => st.lost_since = None,
                _ => {}
            },
            Event::ChannelOpen(id, label) => {
                st.changed = true;
                if Some(id) == st.control || Some(id) == st.dgram || st.streams.contains_key(&id) {
                    st.open.insert(id);
                    let low = if Some(id) == st.dgram { DGRAM_SCTP_HIGH / 2 } else { STREAM_HIGH / 2 };
                    if let Some(mut ch) = st.rtc.channel(id) {
                        ch.set_buffered_amount_low_threshold(low);
                    }
                    return;
                }
                // RPC channels in use (a finished one waits for the client's close without counting)
                let rpc_streams = st.streams.values().filter(|s| s.handles > 0).count().saturating_sub(1);
                if st.accepting && !st.ended && label == RPC_LABEL && rpc_streams < MAX_RPC_STREAMS as usize {
                    // bounded from the start: what arrives before `serve_one` reads (or limits) it counts
                    let credit = st.credit.then(Credit::new);
                    st.streams.insert(
                        id,
                        Stream { handles: 2, recv_cap: Some(RTC_RPC_RECV_MAX), credit, ..Stream::default() },
                    );
                    st.open.insert(id);
                    st.incoming.push_back(id);
                    if let Some(mut ch) = st.rtc.channel(id) {
                        ch.set_buffered_amount_low_threshold(STREAM_HIGH / 2);
                    }
                } else {
                    debug!("link: rtc channel {label:?} refused");
                    st.rtc.direct_api().close_data_channel(id);
                }
            }
            Event::ChannelData(d) => {
                if Some(d.id) == st.dgram {
                    if let Some(tx) = &st.dgram_tx {
                        let _ = tx.try_send(Bytes::from(d.data));
                    }
                    return;
                }
                let mut regrant = false;
                if let Some(s) = st.streams.get_mut(&d.id) {
                    if let Some(c) = s.credit.as_mut() {
                        if !d.binary {
                            // a grant (text: the stream's bytes are binary)
                            match serde_json::from_slice::<serde_json::Value>(&d.data)
                                .ok()
                                .and_then(|v| v.get("credit").and_then(serde_json::Value::as_u64))
                            {
                                Some(n) => c.peer_granted = c.peer_granted.max(n),
                                None => debug!("link: rtc stream: a text message that is no grant, dropped"),
                            }
                            st.changed = true;
                            return;
                        }
                        if !d.data.is_empty() && !s.fin_in && !s.closed {
                            let cost = message_cost(d.data.len());
                            c.received += cost;
                            if c.received > c.granted {
                                // past the window the peer was given: it broke the protocol; reset (the data still on
                                // its way is dropped by SCTP: vendor/sctp-proto)
                                debug!("link: rtc stream past its credit ({} > {}): reset", c.received, c.granted);
                                s.inbox.clear();
                                s.inbox_bytes = 0;
                                s.closed = true;
                                st.rtc.direct_api().close_data_channel(d.id);
                            } else if s.discard {
                                c.consumed += cost;
                                regrant = true;
                            } else {
                                s.inbox_bytes += cost as usize;
                                s.inbox.push_back(Bytes::from(d.data));
                            }
                            st.changed = true;
                            if regrant {
                                st.grant(d.id);
                            }
                            return;
                        }
                    }
                    if d.data.is_empty() {
                        s.fin_in = true;
                    } else if !s.discard && !s.fin_in && !s.closed {
                        let cost = d.data.len() + INBOX_ENTRY_COST;
                        let over_stream = s.recv_cap.is_some_and(|cap| s.inbox_bytes + cost > cap);
                        let over_session = s.shared && st.inbox_total + cost > RTC_SESSION_RECV_MAX;
                        if over_stream || over_session {
                            // more unread than it (or the session) may hold: reset (the peer did not wait for the
                            // reader)
                            debug!(
                                "link: rtc stream over its {} receive limit: reset",
                                if over_stream { "stream's" } else { "session's" }
                            );
                            if s.shared {
                                st.inbox_total -= s.inbox_bytes;
                            }
                            s.inbox.clear();
                            s.inbox_bytes = 0;
                            s.closed = true;
                            st.rtc.direct_api().close_data_channel(d.id);
                        } else {
                            s.inbox_bytes += cost;
                            if s.shared {
                                st.inbox_total += cost;
                            }
                            s.inbox.push_back(Bytes::from(d.data));
                        }
                    }
                    st.changed = true;
                }
            }
            Event::ChannelClose(id) => {
                st.changed = true;
                st.open.remove(&id);
                if Some(id) == st.control {
                    self.finish(st, CloseInfo { code: None, reason: "closed".into(), remote: true });
                    st.close_at.get_or_insert_with(Instant::now);
                    return;
                }
                if let Some(s) = st.streams.get_mut(&id) {
                    s.closed = true;
                    if s.handles == 0 {
                        st.forget(id);
                    } else if st.credit_starved {
                        // its window frees the pool
                        st.grant_all();
                    }
                }
            }
            Event::ChannelBufferedAmountLow(_) => {
                st.changed = true;
                if std::mem::take(&mut st.grants_pending) {
                    st.grant_all();
                }
            }
            Event::PeerStats(ps) => {
                if let Some(pair) = ps.selected_candidate_pair {
                    if pair.current_round_trip_time.is_some() {
                        st.rtt = pair.current_round_trip_time;
                    }
                    let sel = (pair.local.addr, pair.remote.addr);
                    if st.selected != Some(sel) {
                        st.selected = Some(sel);
                        let info = self.classify(st, sel.1);
                        self.path.send_replace(info);
                    }
                }
            }
            Event::Closed => {
                self.finish(st, CloseInfo { code: None, reason: "closed".into(), remote: true });
                st.close_at.get_or_insert_with(Instant::now);
            }
            _ => {}
        }
    }

    /// `lan` (private remote address), `relay` (the peer's TURN relayed address: the browser relays through TURN),
    /// `direct` (the client reached an address the server announced as its own: an interface or the router's
    /// mapping), `punched` (reflexive addresses).
    fn classify(&self, st: &St, remote: SocketAddr) -> PathInfo {
        let kind = if st.remote_candidates.iter().any(|c| c.relay && c.addr == remote) {
            PathKind::Relay
        } else if is_local_ip(remote.ip()) {
            PathKind::Lan
        } else {
            let announced_host = st.remote_candidates.iter().any(|c| c.host && c.addr == remote);
            match self.side {
                Side::Client if announced_host => PathKind::Direct,
                Side::Server if announced_host || self.hub.has_external() => PathKind::Direct,
                _ => PathKind::Punched,
            }
        };
        PathInfo { kind, remote: Some(remote.to_string()) }
    }

    /// The session's end (once): who and why; datagram readers see the end.
    fn finish(&self, st: &mut St, info: CloseInfo) {
        if st.ended {
            return;
        }
        st.ended = true;
        st.changed = true;
        st.dgram_tx = None;
        st.accepting = false;
        self.end.send_replace(Some(info));
    }

    /// The driver's step: timeouts, the close sequence. Returns when to come back, or `None` when the peer is done.
    fn tick(&self) -> Option<Instant> {
        let mut st = self.st.lock().unwrap();
        let now = Instant::now();
        if let Some(since) = st.lost_since
            && now.duration_since(since) >= LOST_GRACE
        {
            self.finish(&mut st, CloseInfo { code: None, reason: "timed out".into(), remote: false });
            st.close_at.get_or_insert(now);
        }
        if let Some(at) = st.close_at
            && now >= at
            && st.closing_since.is_none()
        {
            st.closing_since = Some(now);
            let _ = st.rtc.close();
        }
        if let Some(since) = st.closing_since
            && (!st.rtc.is_alive() || now.duration_since(since) >= CLOSE_DRAIN)
        {
            st.rtc.disconnect();
            st.gone = true;
        }
        if !st.gone {
            if let Err(e) = st.rtc.handle_input(Input::Timeout(now)) {
                debug!("link: rtc timeout: {e}");
            }
            self.drain(&mut st);
        }
        let changed = std::mem::take(&mut st.changed);
        let gone = st.gone;
        let mut next = st.timeout;
        if let Some(at) = st.close_at.filter(|_| st.closing_since.is_none()) {
            next = next.min(at);
        }
        if let Some(since) = st.lost_since {
            next = next.min(since + LOST_GRACE);
        }
        if let Some(since) = st.closing_since {
            next = next.min(since + CLOSE_DRAIN).min(now + Duration::from_millis(20));
        }
        let next = next.max(now + Duration::from_millis(1));
        st.driver_at = next;
        drop(st);
        if changed {
            self.changed.notify_waiters();
        }
        (!gone).then_some(next)
    }

    /// Waits until `f` gives an answer (re-checked at every relevant change).
    async fn wait<R>(&self, mut f: impl FnMut(&mut St) -> Option<R>) -> R {
        loop {
            let n = self.changed.notified();
            tokio::pin!(n);
            n.as_mut().enable();
            if let Some(r) = self.with(&mut f) {
                return r;
            }
            n.await;
        }
    }

    /// The hub closed: end now.
    pub(crate) fn shut_down(&self) {
        self.with(|st| {
            self.finish(st, CloseInfo { code: Some(CloseCode::ShuttingDown), reason: String::new(), remote: false });
            st.close_at.get_or_insert_with(Instant::now);
        });
        self.timer.notify_one();
    }
}

async fn drive(peer: Arc<Peer>) {
    loop {
        let n = peer.timer.notified();
        tokio::pin!(n);
        n.as_mut().enable();
        let Some(next) = peer.tick() else { break };
        tokio::select! {
            _ = tokio::time::sleep_until(tokio::time::Instant::from_std(next)) => {}
            _ = n => {}
        }
    }
    peer.hub.remove_peer(peer.id);
}

/// A peer connection as a session's connection (cheap to clone).
#[derive(Clone, Debug)]
pub(crate) struct RtcConn {
    peer: Arc<Peer>,
}

impl RtcConn {
    pub(crate) fn new(peer: Arc<Peer>) -> RtcConn {
        RtcConn { peer }
    }

    /// Client: `hex(link id)` of the server (from its verified binding). Server: `dtls-sha256:<hex>` of the client's
    /// DTLS certificate (what the offer's `a=fingerprint` says and DTLS checked).
    pub(crate) fn remote_id(&self) -> String {
        self.peer.remote_id.clone()
    }

    /// The control channel's halves, once it is open (`None`: the connection ended first).
    pub(crate) async fn control(&self) -> Option<(RtcSend, RtcRecv)> {
        let id = self
            .peer
            .wait(|st| {
                if st.ended {
                    return Some(None);
                }
                let c = st.control?;
                st.open.contains(&c).then_some(Some(c))
            })
            .await?;
        Some((RtcSend { peer: self.peer.clone(), id }, RtcRecv::new(self.peer.clone(), id)))
    }

    /// The credit window was negotiated (`hello` and `welcome` both say `credit`): every `rpc` channel from now on
    /// uses it (both sides call this before any can be opened: the server before its `welcome`, the client on it).
    pub(crate) fn enable_credit(&self) {
        self.peer.with(|st| st.credit = true);
    }

    /// Tests (`test-hooks`): this connection's next `n` grant writes are refused as if its buffer were full.
    #[cfg(feature = "test-hooks")]
    pub(crate) fn refuse_grant_writes(&self, n: u32) {
        self.peer.with(|st| st.refuse_grants = n);
    }

    /// Tests (`test-hooks`): grant writes still to refuse.
    #[cfg(feature = "test-hooks")]
    pub(crate) fn grant_writes_to_refuse(&self) -> u32 {
        self.peer.with(|st| st.refuse_grants)
    }

    /// Client: a new `rpc` channel.
    pub(crate) fn open_stream(&self) -> Result<(RtcSend, RtcRecv)> {
        let id = self.peer.with(|st| {
            if st.ended {
                return Err(LinkError::Closed("session ended".into()));
            }
            let id = st.rtc.direct_api().create_data_channel(rpc_config());
            let credit = st.credit.then(Credit::new);
            st.streams.insert(id, Stream { handles: 2, credit, ..Stream::default() });
            Ok(id)
        })?;
        Ok((RtcSend { peer: self.peer.clone(), id }, RtcRecv::new(self.peer.clone(), id)))
    }

    /// Server: the next `rpc` channel the client opened; `None` once the connection ended.
    pub(crate) async fn accept_stream(&self) -> Option<(RtcSend, RtcRecv)> {
        let id = self
            .peer
            .wait(|st| {
                if let Some(id) = st.incoming.pop_front() {
                    return Some(Some(id));
                }
                st.ended.then_some(None)
            })
            .await?;
        Some((RtcSend { peer: self.peer.clone(), id }, RtcRecv::new(self.peer.clone(), id)))
    }

    pub(crate) fn send_datagram(&self, d: Bytes) -> std::result::Result<(), String> {
        if d.len() > MAX_DATAGRAM {
            return Err(format!("datagram of {} bytes is over {MAX_DATAGRAM}", d.len()));
        }
        self.peer.with(|st| {
            if st.ended {
                return Err("session ended".to_string());
            }
            let queued = &self.peer.dgram_out_bytes;
            queued.fetch_add(d.len(), Ordering::Relaxed);
            st.dgram_out.push_back(d);
            // the oldest unsent give way (newest wins), as on QUIC
            while queued.load(Ordering::Relaxed) > SEND_BUFFER && st.dgram_out.len() > 1 {
                let old = st.dgram_out.pop_front().expect("not empty");
                queued.fetch_sub(old.len(), Ordering::Relaxed);
            }
            Ok(())
        })
    }

    pub(crate) async fn read_datagram(&self) -> Option<Bytes> {
        self.peer.dgram_rx.lock().await.recv().await
    }

    pub(crate) fn datagram_send_buffer_space(&self) -> usize {
        SEND_BUFFER.saturating_sub(self.peer.dgram_out_bytes.load(Ordering::Relaxed))
    }

    pub(crate) fn max_datagram_size(&self) -> usize {
        MAX_DATAGRAM
    }

    pub(crate) fn rtt(&self) -> Option<Duration> {
        self.peer.st.lock().unwrap().rtt
    }

    pub(crate) fn path(&self) -> PathInfo {
        self.peer.path.borrow().clone()
    }

    pub(crate) fn watch_path(&self) -> watch::Receiver<PathInfo> {
        self.peer.path.subscribe()
    }

    /// The selected pair's remote address, once there is one.
    pub(crate) fn remote_addr(&self) -> Option<SocketAddr> {
        let st = self.peer.st.lock().unwrap();
        st.selected.map(|s| s.1).or(st.heard_from)
    }

    pub(crate) fn counters(&self) -> TransportCounters {
        TransportCounters {
            bytes_sent: self.peer.bytes_sent.load(Ordering::Relaxed),
            bytes_received: self.peer.bytes_received.load(Ordering::Relaxed),
            packets_lost: 0,
        }
    }

    /// Local close: `bye` with the code on the control channel, the peer connection closes a moment later.
    pub(crate) fn close(&self, code: CloseCode, reason: &str) {
        self.peer.with(|st| {
            if st.ended {
                return;
            }
            if let Some(c) = st.control.filter(|c| st.open.contains(c)) {
                let bye = serde_json::json!({"t": "bye", "code": code.code(), "reason": reason});
                if let Ok(frame) = crate::framing::encode(&bye, crate::framing::MAX_CONTROL_FRAME)
                    && let Some(mut ch) = st.rtc.channel(c)
                {
                    let _ = ch.write(true, &frame);
                }
            }
            self.peer.finish(st, CloseInfo { code: Some(code), reason: reason.into(), remote: false });
            st.close_at = Some(Instant::now() + CLOSE_FLUSH);
        });
    }

    /// The peer's `bye`.
    pub(crate) fn peer_closed(&self, code: Option<CloseCode>, reason: &str) {
        self.peer.with(|st| {
            self.peer.finish(st, CloseInfo { code, reason: reason.into(), remote: true });
            st.close_at.get_or_insert_with(|| Instant::now() + Duration::from_millis(50));
        });
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.peer.end.borrow().is_some()
    }

    pub(crate) fn close_info(&self) -> Option<CloseInfo> {
        self.peer.end.borrow().clone()
    }

    pub(crate) fn closed(&self) -> impl Future<Output = CloseInfo> + Send + 'static {
        let mut rx = self.peer.end.subscribe();
        async move {
            loop {
                if let Some(i) = rx.borrow_and_update().clone() {
                    return i;
                }
                if rx.changed().await.is_err() {
                    return CloseInfo { code: None, reason: "closed".into(), remote: false };
                }
            }
        }
    }
}

/// A half let go of its channel. With both gone the channel closes — except on the server after a complete answer:
/// the client closes it once it read the end (the side that closes is the one that reuses the SCTP stream id; a
/// server-side close would race the client's next channel on the same id).
fn release(peer: &Peer, id: ChannelId) {
    let server = peer.side == Side::Server;
    peer.with(|st| {
        let Some(s) = st.streams.get_mut(&id) else { return };
        s.handles = s.handles.saturating_sub(1);
        if s.handles > 0 {
            return;
        }
        let waiting = st.streams.values().filter(|s| s.handles == 0 && !s.closed).count();
        let s = st.streams.get(&id).expect("just looked up");
        // a client that never closes finished channels doesn't get to pile them up
        let keep = server && s.fin_out && waiting <= MAX_FINISHED_OPEN;
        if s.closed {
            st.forget(id);
        } else if !keep && Some(id) != st.control && !st.ended {
            st.forget(id);
            st.rtc.direct_api().close_data_channel(id);
        }
    });
}

/// The sending half of a channel.
#[derive(Debug)]
pub(crate) struct RtcSend {
    peer: Arc<Peer>,
    id: ChannelId,
}

enum Write {
    Done,
    Failed(String),
}

impl RtcSend {
    async fn write_message(&self, data: &[u8]) -> Result<()> {
        let id = self.id;
        let r = self
            .peer
            .wait(|st| {
                let state = st.streams.get(&id).map(|s| s.closed);
                if st.ended || state != Some(false) {
                    return Some(Write::Failed("stream closed".into()));
                }
                if !st.open.contains(&id) {
                    return None;
                }
                // the peer's window: wait for its grant (a FIN is free)
                let cost = message_cost(data.len());
                if let Some(c) = st.streams.get(&id).and_then(|s| s.credit.as_ref())
                    && c.sent + cost > c.peer_granted
                {
                    return None;
                }
                let mut ch = st.rtc.channel(id)?;
                if ch.buffered_amount() >= STREAM_HIGH {
                    st.write_blocked = true;
                    return None;
                }
                match ch.write(true, data) {
                    Ok(true) => {
                        if let Some(c) = st.streams.get_mut(&id).and_then(|s| s.credit.as_mut()) {
                            c.sent += cost;
                        }
                        Some(Write::Done)
                    }
                    Ok(false) => {
                        st.write_blocked = true;
                        None
                    }
                    Err(e) => Some(Write::Failed(e.to_string())),
                }
            })
            .await;
        match r {
            Write::Done => Ok(()),
            Write::Failed(e) => Err(LinkError::Closed(e)),
        }
    }

    pub(crate) async fn write_all(&mut self, data: &[u8]) -> Result<()> {
        for chunk in data.chunks(CHUNK) {
            self.write_message(chunk).await?;
        }
        Ok(())
    }

    /// FIN: a zero-length message.
    pub(crate) async fn finish(&mut self) -> Result<()> {
        self.write_message(&[]).await?;
        let id = self.id;
        self.peer.with(|st| {
            if let Some(s) = st.streams.get_mut(&id) {
                s.fin_out = true;
            }
        });
        Ok(())
    }

    /// Closes the channel without FIN.
    pub(crate) fn reset(&mut self) {
        let id = self.id;
        self.peer.with(|st| {
            if let Some(s) = st.streams.get_mut(&id)
                && !s.closed
            {
                s.closed = true;
                st.rtc.direct_api().close_data_channel(id);
            }
        });
    }

    /// Resolves when the channel closed (the peer cancelled or the exchange is over) or the session ended.
    pub(crate) fn stopped(&self) -> impl Future<Output = ()> + Send + 'static {
        let peer = self.peer.clone();
        let id = self.id;
        async move {
            peer.wait(|st| (st.ended || st.streams.get(&id).is_none_or(|s| s.closed)).then_some(())).await;
        }
    }

    /// Until SCTP sent everything queued on the channel.
    pub(crate) async fn flushed(&mut self) {
        let id = self.id;
        self.peer
            .wait(|st| {
                if st.ended {
                    return Some(());
                }
                let mut ch = st.rtc.channel(id)?;
                (ch.buffered_amount() == 0).then_some(())
            })
            .await;
    }
}

impl Drop for RtcSend {
    fn drop(&mut self) {
        release(&self.peer, self.id);
    }
}

/// The receiving half of a channel: its messages as a byte stream, ending at the zero-length one.
#[derive(Debug)]
pub(crate) struct RtcRecv {
    peer: Arc<Peer>,
    id: ChannelId,
    buf: Bytes,
}

enum Read {
    Data(Bytes),
    End,
    Reset,
}

impl RtcRecv {
    fn new(peer: Arc<Peer>, id: ChannelId) -> RtcRecv {
        RtcRecv { peer, id, buf: Bytes::new() }
    }

    async fn next(&mut self) -> Read {
        let id = self.id;
        self.peer
            .wait(|st| {
                let ended = st.ended;
                let Some(s) = st.streams.get_mut(&id) else { return Some(Read::Reset) };
                if let Some(m) = s.inbox.pop_front() {
                    s.inbox_bytes -= m.len() + INBOX_ENTRY_COST;
                    if s.shared {
                        st.inbox_total -= m.len() + INBOX_ENTRY_COST;
                    }
                    let credit = if let Some(c) = s.credit.as_mut() {
                        // read: the peer may send as much again
                        c.consumed += message_cost(m.len());
                        true
                    } else {
                        false
                    };
                    if credit {
                        st.grant(id);
                    }
                    return Some(Read::Data(m));
                }
                if s.fin_in {
                    return Some(Read::End);
                }
                (s.closed || ended).then_some(Read::Reset)
            })
            .await
    }

    pub(crate) async fn read(&mut self, buf: &mut [u8]) -> Result<Option<usize>> {
        if buf.is_empty() {
            return Ok(Some(0));
        }
        match self.read_chunk(buf.len()).await? {
            Some(b) => {
                buf[..b.len()].copy_from_slice(&b);
                Ok(Some(b.len()))
            }
            None => Ok(None),
        }
    }

    pub(crate) async fn read_chunk(&mut self, max: usize) -> Result<Option<Bytes>> {
        while self.buf.is_empty() {
            match self.next().await {
                Read::Data(b) => self.buf = b,
                Read::End => return Ok(None),
                Read::Reset => return Err(LinkError::Closed("stream reset".into())),
            }
        }
        let n = max.min(self.buf.len()).max(1);
        Ok(Some(self.buf.split_to(n)))
    }

    /// The rest of what arrives is dropped; the channel stays open.
    pub(crate) fn discard(&mut self) {
        let id = self.id;
        self.buf.clear();
        self.peer.with(|st| {
            st.clear_inbox(id);
            if let Some(s) = st.streams.get_mut(&id) {
                s.discard = true;
                // what is dropped counts as read: a peer that goes on sending gets its credit
                if let Some(c) = s.credit.as_mut() {
                    c.consumed = c.received;
                }
            }
            st.grant(id);
        });
    }

    /// From now on at most `cap` unread bytes (`Stream::recv_cap`); `shared`: they count against the session's
    /// budget too (`Stream::shared`). What is already waiting counts.
    pub(crate) fn limit(&mut self, cap: usize, shared: bool) {
        let id = self.id;
        self.peer.with(|st| {
            if let Some(s) = st.streams.get_mut(&id) {
                // under the credit window the peer can't send more than it was given: no other bound applies
                if s.credit.is_some() {
                    return;
                }
                if shared && !s.shared {
                    st.inbox_total += s.inbox_bytes;
                } else if !shared && s.shared {
                    st.inbox_total -= s.inbox_bytes;
                }
                s.shared = shared;
                s.recv_cap = Some(cap);
            }
        });
    }

    /// Gives up on the exchange: the channel closes.
    pub(crate) fn cancel(&mut self) {
        let id = self.id;
        self.peer.with(|st| {
            if let Some(s) = st.streams.get_mut(&id)
                && !s.closed
            {
                s.closed = true;
                st.rtc.direct_api().close_data_channel(id);
            }
        });
    }
}

impl Drop for RtcRecv {
    fn drop(&mut self) {
        release(&self.peer, self.id);
    }
}
