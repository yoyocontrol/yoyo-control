//! The rtc socket(s) of an endpoint and the peer connections on them: one UDP socket per bound address (default
//! `0.0.0.0` and `[::]` on the rtc port), every packet handed to the peer connection it belongs to (str0m's
//! `accepts`: STUN by ufrag, the rest by remote address). Also the local candidates an answer offers: every
//! interface address on the port, the app's router mappings, and the STUN-learned public address.

use std::{
    collections::HashMap,
    io::IoSliceMut,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::{
        Arc, Mutex, RwLock, Weak,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use noq_udp::{RecvMeta, Transmit, UdpSocketState};
use str0m::{
    Candidate, Input, Rtc,
    crypto::{CryptoProvider, dtls::DtlsCert},
    net::{Protocol, Receive},
};
use tokio::{io::Interest, net::UdpSocket};

use super::{RtcConfig, peer::Peer, stun};
use crate::{
    error::{LinkError, Result},
    log::{debug, info, warn},
    path::is_local_ip,
};

/// Bytes SCTP may hold across all channels of one peer connection (str0m's `sctp_max_buffered_amount`).
pub(crate) const SCTP_BUFFER: usize = 4 << 20;
/// How often the selected pair's RTT and the path are read (str0m's stats interval).
const STATS_EVERY: Duration = Duration::from_millis(250);
/// ICE keepalive checks on the selected pair at least this often (the RTT samples), and the retransmits that make
/// ~10 s before a silent pair counts as failed.
const STUN_MAX_RTO: Duration = Duration::from_millis(250);
const STUN_MAX_RETRANSMITS: usize = 40;
/// The STUN query for the server's public address is repeated this often.
const STUN_EVERY: Duration = Duration::from_secs(300);
const RECV_BUF: usize = 64 * 1024;

struct Sock {
    socket: UdpSocket,
    state: UdpSocketState,
    local: SocketAddr,
}

impl Sock {
    fn bind(addr: SocketAddr) -> std::io::Result<Sock> {
        let domain = if addr.is_ipv4() { socket2::Domain::IPV4 } else { socket2::Domain::IPV6 };
        let s = socket2::Socket::new(domain, socket2::Type::DGRAM, Some(socket2::Protocol::UDP))?;
        if addr.is_ipv6() {
            s.set_only_v6(true)?;
        }
        s.set_nonblocking(true)?;
        s.bind(&addr.into())?;
        let socket = UdpSocket::from_std(s.into())?;
        let state = UdpSocketState::new((&socket).into())?;
        // room for bursts of video
        let _ = state.set_send_buffer_size((&socket).into(), 4 << 20);
        let _ = state.set_recv_buffer_size((&socket).into(), 4 << 20);
        let local = socket.local_addr()?;
        Ok(Sock { socket, state, local })
    }

    fn is_wildcard(&self) -> bool {
        self.local.ip().is_unspecified()
    }
}

/// The interface addresses a candidate may use.
fn interface_ips() -> Vec<IpAddr> {
    let mut out = Vec::new();
    for i in netdev::get_interfaces() {
        if !i.is_up() {
            continue;
        }
        for v4 in &i.ipv4 {
            let ip = v4.addr();
            if !ip.is_link_local() && !ip.is_unspecified() {
                out.push(IpAddr::V4(ip));
            }
        }
        for v6 in &i.ipv6 {
            let ip = v6.addr();
            // link-local needs a scope id that SDP can't carry
            if (ip.segments()[0] & 0xffc0) != 0xfe80 && !ip.is_unspecified() && !ip.is_multicast() {
                out.push(IpAddr::V6(ip));
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

#[derive(Default)]
struct Peers {
    all: Vec<Arc<Peer>>,
    /// remote address → the peer that took its last packet
    by_addr: HashMap<SocketAddr, Weak<Peer>>,
}

pub(crate) struct Hub {
    socks: Vec<Arc<Sock>>,
    port: u16,
    peers: Mutex<Peers>,
    crypto: Arc<CryptoProvider>,
    cert: DtlsCert,
    /// Interface addresses (refreshed at every answer / network change): the source of outgoing packets.
    local_ips: RwLock<Vec<IpAddr>>,
    external: Mutex<Vec<SocketAddr>>,
    stun_servers: Vec<String>,
    external_only: bool,
    /// STUN-learned (public, base) addresses, per family
    srflx: Mutex<Vec<(SocketAddr, SocketAddr)>>,
    stun_pending: Mutex<HashMap<[u8; 12], Instant>>,
    next_peer: AtomicU64,
    closed: AtomicBool,
    tasks: Mutex<Vec<tokio::task::AbortHandle>>,
}

impl std::fmt::Debug for Hub {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Hub").field("port", &self.port).finish()
    }
}

impl Hub {
    /// Binds `bind_ips` (or `0.0.0.0` and `[::]`) on the configured port. IPv6 that doesn't bind is not an error.
    pub(crate) fn bind(config: &RtcConfig, bind_ips: &[IpAddr]) -> Result<Arc<Hub>> {
        let mut socks = Vec::new();
        if bind_ips.is_empty() {
            let v4 = Sock::bind(SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), config.port))
                .map_err(|e| LinkError::Bind(format!("rtc udp port {}: {e}", config.port)))?;
            let port = v4.local.port();
            socks.push(Arc::new(v4));
            match Sock::bind(SocketAddr::new(Ipv6Addr::UNSPECIFIED.into(), port)) {
                Ok(s) => socks.push(Arc::new(s)),
                Err(e) => debug!("link: rtc [::]:{port} not bound: {e}"),
            }
        } else {
            let mut port = config.port;
            for ip in bind_ips {
                let s = Sock::bind(SocketAddr::new(*ip, port))
                    .map_err(|e| LinkError::Bind(format!("rtc udp {ip}:{port}: {e}")))?;
                port = s.local.port();
                socks.push(Arc::new(s));
            }
        }
        let port = socks[0].local.port();
        let crypto = Arc::new(str0m::crypto::from_feature_flags());
        let cert = crypto
            .dtls_provider
            .generate_certificate()
            .ok_or_else(|| LinkError::Bind("rtc: no DTLS certificate".into()))?;
        let hub = Arc::new(Hub {
            socks,
            port,
            peers: Mutex::new(Peers::default()),
            crypto,
            cert,
            local_ips: RwLock::new(interface_ips()),
            external: Mutex::new(Vec::new()),
            stun_servers: config.stun_servers.clone(),
            external_only: config.external_only,
            srflx: Mutex::new(Vec::new()),
            stun_pending: Mutex::new(HashMap::new()),
            next_peer: AtomicU64::new(1),
            closed: AtomicBool::new(false),
            tasks: Mutex::new(Vec::new()),
        });
        let mut tasks = Vec::new();
        for s in &hub.socks {
            tasks.push(tokio::spawn(recv_loop(Arc::downgrade(&hub), s.clone())).abort_handle());
        }
        if !hub.stun_servers.is_empty() {
            tasks.push(tokio::spawn(stun_loop(Arc::downgrade(&hub))).abort_handle());
        }
        *hub.tasks.lock().unwrap() = tasks;
        info!("link: rtc on udp port {port}");
        Ok(hub)
    }

    pub(crate) fn port(&self) -> u16 {
        self.port
    }

    pub(crate) fn bound_sockets(&self) -> Vec<SocketAddr> {
        self.socks.iter().map(|s| s.local).collect()
    }

    pub(crate) fn next_peer_id(&self) -> u64 {
        self.next_peer.fetch_add(1, Ordering::Relaxed)
    }

    /// A new str0m instance with this endpoint's certificate and the link's settings.
    pub(crate) fn new_rtc(&self, now: Instant) -> Rtc {
        let mut cfg = Rtc::builder()
            .set_crypto_provider(self.crypto.clone())
            .set_dtls_cert(self.cert.clone())
            .clear_codecs()
            .set_sctp_max_buffered_amount(SCTP_BUFFER)
            .set_stats_interval(Some(STATS_EVERY));
        cfg.set_max_stun_rto(STUN_MAX_RTO);
        cfg.set_max_stun_retransmits(STUN_MAX_RETRANSMITS);
        cfg.build(now)
    }

    pub(crate) fn add_peer(&self, p: Arc<Peer>) {
        self.peers.lock().unwrap().all.push(p);
    }

    pub(crate) fn remove_peer(&self, id: u64) {
        let mut ps = self.peers.lock().unwrap();
        ps.all.retain(|p| p.id() != id);
        ps.by_addr.retain(|_, w| w.upgrade().is_some_and(|p| p.id() != id));
    }

    pub(crate) fn peer_count(&self) -> usize {
        self.peers.lock().unwrap().all.len()
    }

    // MARK: addresses

    pub(crate) fn add_external(&self, addr: SocketAddr) {
        let mut ext = self.external.lock().unwrap();
        if !ext.contains(&addr) {
            ext.push(addr);
        }
    }

    pub(crate) fn remove_external(&self, addr: SocketAddr) -> bool {
        let mut ext = self.external.lock().unwrap();
        let before = ext.len();
        ext.retain(|a| *a != addr);
        ext.len() != before
    }

    /// What an answer announces of `candidates` (all, or only the external and STUN ones: `RtcConfig::external_only`;
    /// the interface ones stay with the peer connection, packets arrive on them).
    pub(crate) fn announces(&self, addr: SocketAddr) -> bool {
        !self.external_only
            || self.external.lock().unwrap().contains(&addr)
            || self.srflx.lock().unwrap().iter().any(|(m, _)| *m == addr)
    }

    pub(crate) fn has_external(&self) -> bool {
        !self.external.lock().unwrap().is_empty()
    }

    /// The network changed: re-read the interfaces, ask STUN again.
    pub(crate) fn network_changed(self: &Arc<Self>) {
        *self.local_ips.write().unwrap() = interface_ips();
        if !self.stun_servers.is_empty() {
            let hub = self.clone();
            tokio::spawn(async move { hub.query_stun().await });
        }
    }

    /// The local candidates of a new peer connection: host (every usable address on the port; the app's router
    /// mappings too: they are reached directly), server reflexive (STUN).
    pub(crate) fn candidates(&self) -> Vec<Candidate> {
        let ips = interface_ips();
        *self.local_ips.write().unwrap() = ips.clone();
        let mut out = Vec::new();
        let mut seen = Vec::new();
        let mut push = |c: Option<Candidate>, out: &mut Vec<Candidate>| {
            if let Some(c) = c
                && !seen.contains(&c.addr())
            {
                seen.push(c.addr());
                out.push(c);
            }
        };
        for s in &self.socks {
            let usable: Vec<IpAddr> = if s.is_wildcard() {
                ips.iter().copied().filter(|ip| ip.is_ipv4() == s.local.is_ipv4()).collect()
            } else {
                vec![s.local.ip()]
            };
            for ip in usable {
                push(Candidate::host(SocketAddr::new(ip, s.local.port()), "udp").ok(), &mut out);
            }
        }
        for e in self.external.lock().unwrap().iter() {
            push(Candidate::host(*e, "udp").ok(), &mut out);
        }
        for (mapped, base) in self.srflx.lock().unwrap().iter() {
            push(Candidate::server_reflexive(*mapped, *base, "udp").ok(), &mut out);
        }
        out
    }

    // MARK: packets

    /// Sends one packet from the candidate address `source`.
    pub(crate) fn send(&self, source: SocketAddr, destination: SocketAddr, contents: &[u8]) {
        let exact = self.socks.iter().find(|s| s.local == source);
        let sock =
            exact.or_else(|| self.socks.iter().find(|s| s.is_wildcard() && s.local.is_ipv4() == destination.is_ipv4()));
        let Some(sock) = sock else {
            debug!("link: rtc no socket for {source} → {destination}");
            return;
        };
        // a wildcard socket sends from the candidate's own address when it is one of ours (the router's mapping
        // and the STUN address are not: those leave from whatever the route says)
        let src_ip = (sock.is_wildcard() && self.local_ips.read().unwrap().contains(&source.ip())).then(|| source.ip());
        let t = Transmit { destination, ecn: None, contents, segment_size: None, src_ip };
        let r = sock.socket.try_io(Interest::WRITABLE, || sock.state.try_send((&sock.socket).into(), &t));
        if let Err(e) = r
            && e.kind() != std::io::ErrorKind::WouldBlock
        {
            debug!("link: rtc send to {destination}: {e}");
        }
    }

    fn dispatch(&self, now: Instant, source: SocketAddr, destination: SocketAddr, data: &[u8]) {
        if let Some(tid) = stun::success_tid(data)
            && self.stun_pending.lock().unwrap().remove(&tid).is_some()
        {
            if let Some(mapped) = stun::mapped_address(data) {
                self.learned_srflx(mapped, destination);
            }
            return;
        }
        let Ok(r) = Receive::new(Protocol::Udp, source, destination, data) else { return };
        let mut input = Input::Receive(now, r);
        let cached = self.peers.lock().unwrap().by_addr.get(&source).and_then(Weak::upgrade);
        if let Some(p) = cached {
            match p.offer(source, input) {
                None => return p.count_received(data.len()),
                Some(back) => input = back,
            }
        }
        let all: Vec<Arc<Peer>> = self.peers.lock().unwrap().all.clone();
        for p in all {
            match p.offer(source, input) {
                None => {
                    p.count_received(data.len());
                    self.peers.lock().unwrap().by_addr.insert(source, Arc::downgrade(&p));
                    return;
                }
                Some(back) => input = back,
            }
        }
    }

    fn learned_srflx(&self, mapped: SocketAddr, base_dst: SocketAddr) {
        if is_local_ip(mapped.ip()) {
            return;
        }
        // the response's destination is the interface address that reaches the internet
        let base = SocketAddr::new(base_dst.ip(), self.port);
        if base.ip().is_unspecified() || base.is_ipv4() != mapped.is_ipv4() {
            return;
        }
        let mut s = self.srflx.lock().unwrap();
        s.retain(|(m, _)| m.is_ipv4() != mapped.is_ipv4());
        s.push((mapped, base));
        debug!("link: rtc public address {mapped} (STUN)");
    }

    async fn query_stun(&self) {
        for server in &self.stun_servers {
            let addrs = match tokio::net::lookup_host(server.as_str()).await {
                Ok(a) => a.collect::<Vec<_>>(),
                Err(e) => {
                    debug!("link: rtc stun {server}: {e}");
                    continue;
                }
            };
            for to in addrs {
                let Some(sock) = self.socks.iter().find(|s| s.local.is_ipv4() == to.is_ipv4()) else { continue };
                let tid: [u8; 12] = rand_tid();
                {
                    let mut pending = self.stun_pending.lock().unwrap();
                    pending.retain(|_, at| at.elapsed() < Duration::from_secs(10));
                    pending.insert(tid, Instant::now());
                }
                let req = stun::request(tid);
                let t = Transmit { destination: to, ecn: None, contents: &req, segment_size: None, src_ip: None };
                let _ = sock.socket.try_io(Interest::WRITABLE, || sock.state.try_send((&sock.socket).into(), &t));
            }
        }
    }

    pub(crate) fn close(&self) {
        if self.closed.swap(true, Ordering::Relaxed) {
            return;
        }
        let peers: Vec<Arc<Peer>> = std::mem::take(&mut self.peers.lock().unwrap().all);
        for p in peers {
            p.shut_down();
        }
        for t in self.tasks.lock().unwrap().drain(..) {
            t.abort();
        }
    }
}

fn rand_tid() -> [u8; 12] {
    let mut t = [0u8; 12];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut t).expect("random");
    t
}

async fn recv_loop(hub: Weak<Hub>, sock: Arc<Sock>) {
    let batch = noq_udp::BATCH_SIZE.min(8);
    let mut storage = vec![0u8; RECV_BUF * batch];
    let mut meta = vec![RecvMeta::default(); batch];
    loop {
        if sock.socket.readable().await.is_err() {
            break;
        }
        let r = {
            let mut bufs: Vec<IoSliceMut<'_>> = storage.chunks_mut(RECV_BUF).map(IoSliceMut::new).collect();
            sock.socket.try_io(Interest::READABLE, || sock.state.recv((&sock.socket).into(), &mut bufs, &mut meta))
        };
        let n = match r {
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
            Err(e) => {
                warn!("link: rtc recv on {}: {e}", sock.local);
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            }
        };
        let Some(hub) = hub.upgrade() else { break };
        let now = Instant::now();
        for (m, buf) in meta.iter().zip(storage.chunks(RECV_BUF)).take(n) {
            let dst_ip = match m.dst_ip {
                Some(ip) => ip,
                None if !sock.is_wildcard() => sock.local.ip(),
                None => match hub.local_ips.read().unwrap().iter().find(|ip| ip.is_ipv4() == sock.local.is_ipv4()) {
                    Some(ip) => *ip,
                    None => continue,
                },
            };
            let dst_ip = match dst_ip {
                IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
                v4 => v4,
            };
            let destination = SocketAddr::new(dst_ip, sock.local.port());
            let source = SocketAddr::new(m.addr.ip().to_canonical(), m.addr.port());
            let stride = m.stride.max(1);
            for seg in buf[..m.len].chunks(stride) {
                hub.dispatch(now, source, destination, seg);
            }
        }
    }
}

async fn stun_loop(hub: Weak<Hub>) {
    loop {
        {
            let Some(h) = hub.upgrade() else { return };
            h.query_stun().await;
        }
        tokio::time::sleep(STUN_EVERY).await;
    }
}
