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
                    st.streams.insert(id, Stream { handles: 2, ..Stream::default() });
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
                if let Some(s) = st.streams.get_mut(&d.id) {
                    if d.data.is_empty() {
                        s.fin_in = true;
                    } else if !s.discard && !s.fin_in {
                        s.inbox.push_back(Bytes::from(d.data));
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
                        st.streams.remove(&id);
                    }
                }
            }
            Event::ChannelBufferedAmountLow(_) => st.changed = true,
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

    /// Client: a new `rpc` channel.
    pub(crate) fn open_stream(&self) -> Result<(RtcSend, RtcRecv)> {
        let id = self.peer.with(|st| {
            if st.ended {
                return Err(LinkError::Closed("session ended".into()));
            }
            let id = st.rtc.direct_api().create_data_channel(rpc_config());
            st.streams.insert(id, Stream { handles: 2, ..Stream::default() });
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
            st.streams.remove(&id);
        } else if !keep && Some(id) != st.control && !st.ended {
            st.streams.remove(&id);
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
                let mut ch = st.rtc.channel(id)?;
                if ch.buffered_amount() >= STREAM_HIGH {
                    st.write_blocked = true;
                    return None;
                }
                match ch.write(true, data) {
                    Ok(true) => Some(Write::Done),
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
            if let Some(s) = st.streams.get_mut(&id) {
                s.discard = true;
                s.inbox.clear();
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
