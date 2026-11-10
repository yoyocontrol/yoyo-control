//! The endpoint: one UDP socket pair (IPv4 + IPv6) with its link key, relays and port mapping, and optionally the
//! WebRTC socket(s) (`rtc`); dials sessions (client) or accepts them (server: guard, `hello`, the app's
//! authenticator, `welcome` / `denied`) over either transport.

use std::{
    collections::HashSet,
    future::Future,
    net::{IpAddr, SocketAddr},
    str::FromStr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use async_trait::async_trait;
use data_encoding::HEXLOWER;
use iroh::{
    EndpointAddr, PublicKey, RelayMode, RelayUrl, SecretKey, TransportAddr, Watcher,
    endpoint::{
        BindOpts, ConnectOptions, IdleTimeout, Incoming, IncomingAddr, PortmapperConfig, QuicTransportConfig, VarInt,
        presets,
    },
};
use n0_future::{Stream, StreamExt};
use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::{
    ALPN,
    binding::{self, Binding},
    cc::{DEFAULT_TARGET_BPS, MediaCcFactory, TargetBitrate},
    error::{CloseCode, DenyCode, LinkError, Result},
    framing::{self, MAX_CONTROL_FRAME},
    guard::{Guard, GuardConfig, Permit, Refusal},
    log::{debug, info, warn},
    media,
    path::{self, Iface, PathKind},
    rpc::{DEFAULT_BLOCKED_PATHS, DEFAULT_MAX_REQUEST_BODY, RpcHandler, ServeConfig},
    rtc::{self, Hub, IdentitySigner, RtcAnswer, RtcConfig, RtcConn, RtcOffer},
    session::{self, Hello, Parts, ServerInfo, Session, Side, Welcome},
    transport::{Conn, RecvHalf, SendHalf},
};

pub const KEEP_ALIVE: Duration = Duration::from_secs(5);
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(20);
/// A client has this long after the handshake to send `hello`.
pub const HELLO_TIMEOUT: Duration = Duration::from_secs(5);
/// The QUIC handshake of an incoming connection.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// The authenticator's answer (then `busy`).
pub const AUTH_TIMEOUT: Duration = Duration::from_secs(10);
/// RPC streams a client may have open at once (plus the control stream).
pub const MAX_RPC_STREAMS: u32 = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Server,
    Client,
}

#[derive(Debug, Clone)]
pub struct EndpointConfig {
    pub role: Role,
    /// The link secret key (Ed25519, 32 bytes): its public key is the endpoint id.
    pub secret_key: [u8; 32],
    /// UDP port on `0.0.0.0` and `[::]`; 0 = any.
    pub port: u16,
    /// Relay URLs (`https://…`); empty = direct only.
    pub relays: Vec<String>,
    /// Ask the router for a port mapping (UPnP / PCP / NAT-PMP). Default: servers yes, clients no.
    pub portmapper: Option<bool>,
    /// The server's guard.
    pub guard: GuardConfig,
    /// The target bitrate each new session starts at (until the media layer sets it).
    pub initial_target_bps: u64,
    /// Bind only these addresses (one socket each) instead of `0.0.0.0` and `[::]`: a host with several
    /// networks, or a test that must only be reachable through an impairment proxy. The rtc socket(s) too.
    pub bind_ips: Vec<IpAddr>,
    /// Also open WebRTC socket(s) (`rtc`, docs/LINK.md「WebRTC」): servers accept browsers' offers
    /// (`Listener::accept_rtc_offer`), clients can `dial_rtc`. Default: none.
    pub rtc: Option<RtcConfig>,
}

impl EndpointConfig {
    pub fn server(secret_key: [u8; 32], port: u16) -> Self {
        EndpointConfig {
            role: Role::Server,
            secret_key,
            port,
            relays: Vec::new(),
            portmapper: None,
            guard: GuardConfig::default(),
            initial_target_bps: DEFAULT_TARGET_BPS,
            bind_ips: Vec::new(),
            rtc: None,
        }
    }

    pub fn client(secret_key: [u8; 32]) -> Self {
        EndpointConfig { role: Role::Client, port: 0, ..EndpointConfig::server(secret_key, 0) }
    }
}

/// What a client needs to dial this endpoint (and what `/status` publishes beside the binding).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AddrInfo {
    /// hex of the endpoint id
    pub id: String,
    pub relays: Vec<String>,
    /// `ip:port`: LAN addresses, the router's mapping, addresses peers observed.
    pub direct: Vec<String>,
}

impl AddrInfo {
    fn from_iroh(a: &EndpointAddr) -> Self {
        AddrInfo {
            id: HEXLOWER.encode(a.id.as_bytes()),
            relays: a.relay_urls().map(|u| u.to_string()).collect(),
            direct: a.ip_addrs().map(|s| s.to_string()).collect(),
        }
    }
}

/// Where to dial: the server's id (from its verified binding), its relays and its direct addresses (advertised,
/// from the pairing link, from Bonjour…).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DialTarget {
    pub id: String,
    pub relays: Vec<String>,
    pub direct: Vec<String>,
}

impl DialTarget {
    /// A target whose id comes from `binding`, checked against the pinned fingerprint first.
    pub fn from_binding(b: &Binding, fingerprint: &str, relays: Vec<String>, direct: Vec<String>) -> Result<Self> {
        let id = binding::verify_binding(b, fingerprint)?;
        Ok(DialTarget { id: HEXLOWER.encode(&id), relays, direct })
    }
}

#[derive(Debug, Clone)]
pub struct DialOptions {
    /// Until the QUIC connection is up.
    pub connect_timeout: Duration,
    /// From `hello` sent to `welcome` / `denied`.
    pub welcome_timeout: Duration,
}

impl Default for DialOptions {
    fn default() -> Self {
        DialOptions { connect_timeout: Duration::from_secs(10), welcome_timeout: Duration::from_secs(15) }
    }
}

/// Where an incoming session comes from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    /// The remote `ip:port` (direct paths; `rtc`: the selected candidate pair's remote address).
    pub addr: Option<SocketAddr>,
    /// The relay it came through.
    pub relay: Option<String>,
    pub path: PathKind,
}

/// What the server's authenticator decides about a `hello`.
#[derive(Debug, Clone)]
pub struct AuthRequest {
    pub hello: Hello,
    /// hex of the client's link public key: bind a device token to it on first use, refuse it with another key.
    /// `rtc`: `dtls-sha256:<hex>` of the browser's DTLS certificate (stable as long as the browser keeps it).
    pub client_key: String,
    pub source: Source,
}

#[derive(Debug, Clone)]
pub enum AuthDecision {
    /// `principal` goes into `welcome` (and `Session::principal`); `features` replaces the server's list if given.
    Accept {
        principal: Value,
        features: Option<Vec<String>>,
    },
    Deny {
        code: DenyCode,
        message: String,
    },
}

#[async_trait]
pub trait Authenticator: Send + Sync + 'static {
    async fn authenticate(&self, request: AuthRequest) -> AuthDecision;
}

/// A server's listening options.
#[derive(Clone)]
pub struct ServerOptions {
    pub server: ServerInfo,
    pub features: Vec<String>,
    pub authenticator: Arc<dyn Authenticator>,
    pub rpc: Option<Arc<dyn RpcHandler>>,
    /// Paths answered 404 instead of reaching `rpc` (default: the channels' HTTP paths).
    pub rpc_blocked_paths: Vec<String>,
    pub max_request_body: usize,
    /// From the handshake to `hello` (else close with code 4).
    pub hello_timeout: Duration,
    /// Each session's media layer (`ServerMedia`): e.g. `video.recovery_on_nack` for an encoder with long-term
    /// references.
    pub media: media::ServerConfig,
    /// Signs `rtc` answers (and the binding in them): the identity key (`rtc::IdentityKey`) or the app's own
    /// signer. Without it `Listener::accept_rtc_offer` refuses.
    pub rtc_identity: Option<Arc<dyn IdentitySigner>>,
}

impl ServerOptions {
    pub fn new(server: ServerInfo, authenticator: Arc<dyn Authenticator>) -> Self {
        ServerOptions {
            server,
            features: Vec::new(),
            authenticator,
            rpc: None,
            rpc_blocked_paths: DEFAULT_BLOCKED_PATHS.iter().map(|s| s.to_string()).collect(),
            max_request_body: DEFAULT_MAX_REQUEST_BODY,
            hello_timeout: HELLO_TIMEOUT,
            media: media::ServerConfig::default(),
            rtc_identity: None,
        }
    }
}

/// Cheap to clone.
#[derive(Clone, Debug)]
pub struct Endpoint {
    inner: Arc<EndpointInner>,
}

#[derive(Debug)]
struct EndpointInner {
    ep: iroh::Endpoint,
    role: Role,
    iface: Arc<Mutex<Iface>>,
    guard: Arc<Guard>,
    initial_target_bps: u64,
    next_session: AtomicU64,
    listening: Mutex<Option<tokio::task::AbortHandle>>,
    rtc: Option<Arc<Hub>>,
}

fn transport_config(role: Role, target: TargetBitrate) -> QuicTransportConfig {
    let bidi = match role {
        Role::Server => MAX_RPC_STREAMS + 1,
        Role::Client => 0,
    };
    QuicTransportConfig::builder()
        .keep_alive_interval(KEEP_ALIVE)
        .default_path_keep_alive_interval(KEEP_ALIVE)
        .max_idle_timeout(Some(IdleTimeout::try_from(IDLE_TIMEOUT).expect("idle timeout")))
        .max_concurrent_bidi_streams(VarInt::from_u32(bidi))
        .max_concurrent_uni_streams(VarInt::from_u32(0))
        .datagram_receive_buffer_size(Some(4 << 20))
        .datagram_send_buffer_size(media::SEND_BUFFER)
        .congestion_controller_factory(Arc::new(MediaCcFactory::new(target)))
        .build()
}

/// Relay URLs as hosts give them; a `?token=<t>` on one is the relay's access token (iroh-relay's
/// `access.shared_token`, sent as `Authorization: Bearer`), not part of its address: the address is the URL without
/// the query, the same on every side (a binding's relays, the endpoint's own).
fn parse_relay_configs(relays: &[String]) -> Result<Vec<(RelayUrl, Option<String>)>> {
    relays
        .iter()
        .map(|r| {
            let given = RelayUrl::from_str(r).map_err(|e| LinkError::InvalidArgument(format!("relay {r}: {e}")))?;
            let token =
                given.query_pairs().find(|(k, _)| k == "token").map(|(_, v)| v.into_owned()).filter(|t| !t.is_empty());
            let mut bare = (*given).clone();
            bare.set_query(None);
            Ok((RelayUrl::from(bare), token))
        })
        .collect()
}

fn parse_relays(relays: &[String]) -> Result<Vec<RelayUrl>> {
    Ok(parse_relay_configs(relays)?.into_iter().map(|(u, _)| u).collect())
}

/// The endpoint's relay map: each relay with its access token, if its URL had one.
fn relay_map(relays: &[String]) -> Result<Option<iroh::RelayMap>> {
    let configs = parse_relay_configs(relays)?;
    if configs.is_empty() {
        return Ok(None);
    }
    Ok(Some(
        configs
            .into_iter()
            .map(|(url, token)| {
                let c = iroh::RelayConfig::from(url);
                match token {
                    Some(t) => c.with_auth_token(t),
                    None => c,
                }
            })
            .collect(),
    ))
}

fn parse_addrs(addrs: &[String]) -> Result<Vec<SocketAddr>> {
    addrs
        .iter()
        .map(|a| SocketAddr::from_str(a).map_err(|_| LinkError::InvalidArgument(format!("address {a}: not ip:port"))))
        .collect()
}

impl Endpoint {
    pub async fn bind(config: EndpointConfig) -> Result<Endpoint> {
        let relay_mode = match relay_map(&config.relays)? {
            Some(map) => RelayMode::Custom(map),
            None => RelayMode::Disabled,
        };
        let portmap = config.portmapper.unwrap_or(config.role == Role::Server);
        let alpns = match config.role {
            Role::Server => vec![ALPN.to_vec()],
            Role::Client => Vec::new(),
        };
        let bind_err = |e: iroh::endpoint::InvalidSocketAddr| LinkError::Bind(e.to_string());
        let mut builder = iroh::Endpoint::builder(presets::Minimal)
            .secret_key(SecretKey::from_bytes(&config.secret_key))
            .alpns(alpns)
            .relay_mode(relay_mode)
            .clear_address_lookup()
            .transport_config(transport_config(config.role, TargetBitrate::new(config.initial_target_bps)))
            .portmapper_config(if portmap { PortmapperConfig::default() } else { PortmapperConfig::Disabled })
            .clear_ip_transports();
        if config.bind_ips.is_empty() {
            builder = builder
                .bind_addr(SocketAddr::from(([0, 0, 0, 0], config.port)))
                .map_err(bind_err)?
                .bind_addr_with_opts(
                    SocketAddr::from(([0u16; 8], config.port)),
                    BindOpts::default().set_is_required(false),
                )
                .map_err(bind_err)?;
        } else {
            for ip in &config.bind_ips {
                let prefix = if ip.is_ipv4() { 32 } else { 128 };
                let opts = BindOpts::default().set_prefix_len(prefix).set_is_default_route(true);
                builder = builder.bind_addr_with_opts(SocketAddr::new(*ip, config.port), opts).map_err(bind_err)?;
            }
        }
        let ep = builder.bind().await.map_err(|e| LinkError::Bind(e.to_string()))?;
        let rtc = match &config.rtc {
            // the rtc port taken (another program on link port + 1): rtc alone moves to any port, the link keeps its
            // own (its port is the one phones and the router's mapping know)
            Some(c) => match Hub::bind(c, &config.bind_ips).or_else(|e| {
                if c.port == 0 {
                    return Err(e);
                }
                warn!("link: {e}; rtc on another port");
                Hub::bind(&RtcConfig { port: 0, ..c.clone() }, &config.bind_ips)
            }) {
                Ok(h) => Some(h),
                Err(e) => {
                    ep.close().await;
                    return Err(e);
                }
            },
            None => None,
        };
        Ok(Endpoint {
            inner: Arc::new(EndpointInner {
                ep,
                role: config.role,
                iface: Arc::new(Mutex::new(Iface::Other)),
                guard: Guard::new(config.guard),
                initial_target_bps: config.initial_target_bps,
                next_session: AtomicU64::new(1),
                listening: Mutex::new(None),
                rtc,
            }),
        })
    }

    pub fn role(&self) -> Role {
        self.inner.role
    }

    /// hex of the link public key.
    pub fn id(&self) -> String {
        HEXLOWER.encode(self.inner.ep.id().as_bytes())
    }

    pub fn public_key(&self) -> [u8; 32] {
        *self.inner.ep.id().as_bytes()
    }

    /// The identity's binding over this endpoint's key (`identity_key`: the 97-byte X9.63 private key).
    pub fn binding(&self, identity_key: &[u8]) -> Result<Binding> {
        binding::sign_binding(identity_key, &self.public_key())
    }

    /// The bound UDP sockets.
    pub fn bound_sockets(&self) -> Vec<SocketAddr> {
        self.inner.ep.bound_sockets()
    }

    /// The port of the IPv4 socket.
    pub fn port(&self) -> u16 {
        self.bound_sockets().iter().find(|a| a.is_ipv4()).map(|a| a.port()).unwrap_or(0)
    }

    pub fn addr_info(&self) -> AddrInfo {
        AddrInfo::from_iroh(&self.inner.ep.addr())
    }

    /// The address info now and at every change, until the endpoint is closed.
    pub fn watch_addr_info(&self) -> impl Stream<Item = AddrInfo> + Send + Unpin + 'static {
        let closed = self.inner.ep.clone();
        self.inner.ep.watch_addr().stream().map(|a| AddrInfo::from_iroh(&a)).take_while(move |_| !closed.is_closed())
    }

    /// An address this endpoint is directly reachable on that it can't see itself (a router's port mapping made by
    /// the app): advertised to peers with the rest (`addr_info().direct`, NAT traversal) until removed.
    pub async fn add_external_addr(&self, addr: SocketAddr) {
        self.inner.ep.add_external_addr(addr).await;
    }

    /// Takes back an `add_external_addr` address (the mapping is gone or changed); false if it wasn't there.
    pub async fn remove_external_addr(&self, addr: SocketAddr) -> bool {
        self.inner.ep.remove_external_addr(&addr).await
    }

    /// The network changed (interface up / down, Wi-Fi ↔ cellular): re-probe addresses and paths now.
    pub async fn network_changed(&self, iface: Option<Iface>) {
        if let Some(i) = iface {
            *self.inner.iface.lock().unwrap() = i;
        }
        if let Some(h) = &self.inner.rtc {
            h.network_changed();
        }
        self.inner.ep.network_change().await;
    }

    // MARK: rtc

    /// The rtc UDP port (`None`: no rtc socket).
    pub fn rtc_port(&self) -> Option<u16> {
        self.inner.rtc.as_ref().map(|h| h.port())
    }

    /// The bound rtc sockets.
    pub fn rtc_bound_sockets(&self) -> Vec<SocketAddr> {
        self.inner.rtc.as_ref().map(|h| h.bound_sockets()).unwrap_or_default()
    }

    /// Like `add_external_addr`, for the rtc port's router mapping: answers offer it as a host candidate (reached
    /// directly) until removed. False without an rtc socket.
    pub fn add_rtc_external_addr(&self, addr: SocketAddr) -> bool {
        match &self.inner.rtc {
            Some(h) => {
                h.add_external(addr);
                true
            }
            None => false,
        }
    }

    /// Takes back an `add_rtc_external_addr` address; false if it wasn't there.
    pub fn remove_rtc_external_addr(&self, addr: SocketAddr) -> bool {
        self.inner.rtc.as_ref().is_some_and(|h| h.remove_external(addr))
    }

    /// Peer connections on the rtc socket right now (pending offers and sessions).
    pub fn rtc_peer_count(&self) -> usize {
        self.inner.rtc.as_ref().map_or(0, |h| h.peer_count())
    }

    pub fn iface(&self) -> Iface {
        *self.inner.iface.lock().unwrap()
    }

    pub fn guard(&self) -> &Arc<Guard> {
        &self.inner.guard
    }

    pub async fn close(&self) {
        if let Some(h) = self.inner.listening.lock().unwrap().take() {
            h.abort();
        }
        if let Some(h) = &self.inner.rtc {
            h.close();
        }
        self.inner.ep.close().await;
    }

    pub fn is_closed(&self) -> bool {
        self.inner.ep.is_closed()
    }

    // MARK: client

    pub async fn dial(&self, target: &DialTarget, hello: &Hello, opts: &DialOptions) -> Result<Session> {
        let id = PublicKey::from_bytes(&binding::parse_endpoint_id(&target.id)?)
            .map_err(|e| LinkError::InvalidArgument(format!("endpoint id: {e}")))?;
        let relays = parse_relays(&target.relays)?;
        let direct = parse_addrs(&target.direct)?;
        if relays.is_empty() && direct.is_empty() {
            return Err(LinkError::InvalidArgument("no address to dial".into()));
        }
        let addr = EndpointAddr::from_parts(
            id,
            relays.into_iter().map(TransportAddr::Relay).chain(direct.iter().copied().map(TransportAddr::Ip)),
        );
        let target_bps = TargetBitrate::new(self.inner.initial_target_bps);
        let options = ConnectOptions::new().with_transport_config(transport_config(Role::Client, target_bps.clone()));
        let started = Instant::now();
        let conn = tokio::time::timeout(opts.connect_timeout, async {
            let connecting = self
                .inner
                .ep
                .connect_with_opts(addr, ALPN, options)
                .await
                .map_err(|e| LinkError::Connect(e.to_string()))?;
            connecting.await.map_err(|e| LinkError::Connect(e.to_string()))
        })
        .await
        .map_err(|_| LinkError::Timeout("connect".into()))??;
        debug!("link: connected in {} ms", started.elapsed().as_millis());

        let (send, recv) = conn.open_bi().await.map_err(|e| LinkError::Connect(e.to_string()))?;
        let known = direct.into_iter().collect();
        self.client_handshake(
            Conn::Quic(conn),
            SendHalf::Quic(send),
            RecvHalf::Quic(recv),
            hello,
            opts,
            known,
            target_bps,
        )
        .await
    }

    /// Dials a server over WebRTC, as a browser does (docs/LINK.md「WebRTC」): makes the offer, hands its JSON to
    /// `signal` (whatever path reaches the server's `accept_rtc_offer`), checks the answer against the pinned identity
    /// `fingerprint`, connects, `hello`. Needs `EndpointConfig::rtc`.
    pub async fn dial_rtc<F, Fut>(
        &self,
        signal: F,
        fingerprint: &str,
        hello: &Hello,
        opts: &DialOptions,
    ) -> Result<Session>
    where
        F: FnOnce(String) -> Fut,
        Fut: Future<Output = Result<String>>,
    {
        let hub = self.inner.rtc.clone().ok_or_else(|| LinkError::InvalidArgument("no rtc socket".into()))?;
        let mut r = hub.new_rtc(Instant::now());
        for c in hub.candidates() {
            r.add_local_candidate(c);
        }
        let mut api = r.sdp_api();
        let control = api.add_channel_with_config(rtc::peer_control_config());
        let dgram = api.add_channel_with_config(rtc::peer_dgram_config());
        let (offer, pending) = api.apply().ok_or_else(|| LinkError::Connect("rtc: no offer".into()))?;
        let offer_sdp = offer.to_sdp_string();
        let offer_json =
            RtcOffer { v: 1, offer: offer_sdp.clone(), device: hello.device.clone(), rk: None, restart: None }
                .to_json();
        let started = Instant::now();
        let answer_json = tokio::time::timeout(opts.connect_timeout, signal(offer_json))
            .await
            .map_err(|_| LinkError::Timeout("rtc signaling".into()))??;
        let answer = RtcAnswer::parse(&answer_json)?;
        let server_id = rtc::verify_answer(&answer, &offer_sdp, fingerprint)?;
        let (usable, remote_candidates) = rtc::usable_sdp(&answer.answer);
        let sdp = str0m::change::SdpAnswer::from_sdp_string(&usable)
            .map_err(|e| LinkError::Protocol(format!("answer SDP: {e}")))?;
        r.sdp_api().accept_answer(pending, sdp).map_err(|e| LinkError::Protocol(format!("answer: {e}")))?;
        let peer = rtc::Peer::start(hub, Side::Client, r, remote_candidates, HEXLOWER.encode(&server_id));
        peer.adopt_negotiated(control, dgram);
        let conn = RtcConn::new(peer);
        let left = opts.connect_timeout.saturating_sub(started.elapsed());
        let (send, recv) = match tokio::time::timeout(left, conn.control()).await {
            Ok(Some(c)) => c,
            Ok(None) => return Err(LinkError::Connect("rtc: closed while connecting".into())),
            Err(_) => {
                conn.close(CloseCode::Normal, "connect timeout");
                return Err(LinkError::Timeout("rtc connect".into()));
            }
        };
        debug!("link: rtc connected in {} ms", started.elapsed().as_millis());
        let target_bps = TargetBitrate::new(self.inner.initial_target_bps);
        self.client_handshake(
            Conn::Rtc(conn),
            SendHalf::Rtc(send),
            RecvHalf::Rtc(recv),
            hello,
            opts,
            HashSet::new(),
            target_bps,
        )
        .await
    }

    /// `hello` → `welcome` / `denied` on a fresh control stream.
    #[allow(clippy::too_many_arguments)]
    async fn client_handshake(
        &self,
        conn: Conn,
        mut send: SendHalf,
        mut recv: RecvHalf,
        hello: &Hello,
        opts: &DialOptions,
        known: HashSet<SocketAddr>,
        target_bps: TargetBitrate,
    ) -> Result<Session> {
        let media = media::Engine::Client(Box::new(media::ClientMedia::new(media::ClientConfig::default())));
        let answer = tokio::time::timeout(opts.welcome_timeout, async {
            framing::write_frame(&mut send, &session::hello_message(hello), MAX_CONTROL_FRAME).await?;
            framing::read_frame(&mut recv, MAX_CONTROL_FRAME).await
        })
        .await;
        let reply = match answer {
            Ok(Ok(Some(m))) => m,
            Err(_) => {
                conn.close(CloseCode::Normal, "no welcome");
                return Err(LinkError::Timeout("welcome".into()));
            }
            Ok(Ok(None)) | Ok(Err(_)) => return Err(denied_by_close(&conn)),
        };
        match reply.get("t").and_then(Value::as_str) {
            Some("welcome") => {
                let welcome: Welcome = serde_json::from_value(Value::Object(reply))
                    .map_err(|e| LinkError::protocol(format!("welcome: {e}")))?;
                Ok(Session::start(Parts {
                    id: self.inner.next_session.fetch_add(1, Ordering::Relaxed),
                    side: Side::Client,
                    conn,
                    hello: hello.clone(),
                    welcome,
                    control_send: send,
                    control_recv: recv,
                    target: target_bps,
                    known,
                    iface: self.inner.iface.clone(),
                    permit: None,
                    rpc: None,
                    endpoint: self.inner.ep.clone(),
                    media,
                }))
            }
            Some("denied") => {
                let code = DenyCode::parse(reply.get("code").and_then(Value::as_str).unwrap_or(""));
                let message = reply.get("message").and_then(Value::as_str).unwrap_or("").to_string();
                conn.close(code.close_code(), code.as_str());
                Err(LinkError::Denied { code, message })
            }
            _ => {
                conn.close(CloseCode::Protocol, "expected welcome");
                Err(LinkError::protocol("expected welcome or denied"))
            }
        }
    }

    // MARK: server

    /// Starts accepting sessions (servers; once per endpoint).
    pub fn listen(&self, options: ServerOptions) -> Result<Listener> {
        if self.inner.role != Role::Server {
            return Err(LinkError::InvalidArgument("only a server endpoint listens".into()));
        }
        let mut listening = self.inner.listening.lock().unwrap();
        if listening.is_some() {
            return Err(LinkError::InvalidArgument("already listening".into()));
        }
        let (tx, rx) = mpsc::channel(8);
        let rpc = options.rpc.clone().map(|h| {
            let cfg =
                ServeConfig { blocked_paths: options.rpc_blocked_paths.clone(), max_body: options.max_request_body };
            (h, Arc::new(cfg))
        });
        let shared =
            Arc::new(Accepting { ep: self.clone(), options: Arc::new(options), rpc, tx, restarts: Default::default() });
        let weak = Arc::downgrade(&shared);
        // the accept loop holds the options (and the app's callbacks) until the endpoint closes
        let task = tokio::spawn(accept_loop(shared));
        *listening = Some(task.abort_handle());
        Ok(Listener { rx: tokio::sync::Mutex::new(rx), shared: weak })
    }
}

/// What both transports' accept paths share.
struct Accepting {
    ep: Endpoint,
    options: Arc<ServerOptions>,
    rpc: Option<(Arc<dyn RpcHandler>, Arc<ServeConfig>)>,
    tx: mpsc::Sender<Session>,
    /// rtc connections by the key of their next ICE restart (`RtcOffer::rk`).
    restarts: std::sync::Mutex<std::collections::HashMap<String, std::sync::Weak<rtc::Peer>>>,
}

/// Restart keys and secrets: 64 lowercase hex digits (SHA-256), a secret at most this long.
const MAX_RESTART_SECRET: usize = 128;

fn valid_restart_key(k: &str) -> bool {
    k.len() == 64 && k.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// Sessions that passed authentication, in order (QUIC and `rtc` alike).
pub struct Listener {
    rx: tokio::sync::Mutex<mpsc::Receiver<Session>>,
    shared: std::sync::Weak<Accepting>,
}

impl std::fmt::Debug for Listener {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Listener").finish()
    }
}

impl Listener {
    /// The next session; `None` once the endpoint is closed.
    pub async fn accept(&self) -> Option<Session> {
        self.rx.lock().await.recv().await
    }

    /// A browser's WebRTC offer (`{"v":1,"offer","device"}`, docs/LINK.md「WebRTC」) → the signed answer JSON. The
    /// peer connection it starts becomes a session through `accept` once ICE connected (≤ 10 s), `hello` arrived
    /// (≤ `hello_timeout`) and the authenticator accepted it. `source`: the signaling request's IP when the host knows
    /// it (the guard counts its failures and refuses it while blocked).
    ///
    /// Errors: `InvalidArgument` (no rtc socket or identity, a bad offer), `Denied { RateLimited }` (the source is
    /// blocked), `Denied { Busy }` (too many sessions or pending offers).
    pub async fn accept_rtc_offer(&self, offer_json: &str, source: Option<IpAddr>) -> Result<String> {
        let a = &self.shared.upgrade().ok_or_else(|| LinkError::Closed("not listening".into()))?;
        let hub = a.ep.inner.rtc.clone().ok_or_else(|| LinkError::InvalidArgument("rtc is not enabled".into()))?;
        let identity = a
            .options
            .rtc_identity
            .clone()
            .ok_or_else(|| LinkError::InvalidArgument("rtc needs the identity (rtc_identity)".into()))?;
        let offer = RtcOffer::parse(offer_json)?;
        let source = source.map(|ip| ip.to_canonical());
        if let Some(secret) = &offer.restart {
            return restart_rtc(a, &hub, identity.as_ref(), &offer, secret, source);
        }
        let permit = a.ep.inner.guard.admit(source).map_err(|r| match r {
            Refusal::Blocked => LinkError::Denied { code: DenyCode::RateLimited, message: "blocked".into() },
            _ => LinkError::Denied { code: DenyCode::Busy, message: "too many sessions".into() },
        })?;
        let client_fp = rtc::sdp_fingerprint(&offer.offer)
            .ok_or_else(|| LinkError::InvalidArgument("offer without a sha-256 DTLS fingerprint".into()))?;
        let (usable, remote_candidates) = rtc::usable_sdp(&offer.offer);
        let sdp = str0m::change::SdpOffer::from_sdp_string(&usable)
            .map_err(|e| LinkError::InvalidArgument(format!("offer SDP: {e}")))?;
        let mut r = hub.new_rtc(Instant::now());
        for c in hub.candidates() {
            r.add_local_candidate(c);
        }
        let answer = r.sdp_api().accept_offer(sdp).map_err(|e| LinkError::InvalidArgument(format!("offer: {e}")))?;
        let fingerprint = rtc::fingerprint_string(&r.direct_api().local_dtls_fingerprint().bytes);
        let binding = binding::sign_binding_with(identity.as_ref(), &a.ep.public_key())?;
        let answer_sdp = rtc::with_nat64(&rtc::filter_candidates(&answer.to_sdp_string(), |a| hub.announces(a)));
        let mut signed = rtc::sign_answer(identity.as_ref(), binding, &offer.offer, answer_sdp, fingerprint)?;
        let peer = rtc::Peer::start(hub, Side::Server, r, remote_candidates, format!("dtls-{client_fp}"));
        peer.open_negotiated();
        if let Some(rk) = offer.rk.as_deref().filter(|k| valid_restart_key(k)) {
            let mut map = a.restarts.lock().unwrap();
            map.retain(|_, w| w.upgrade().is_some_and(|p| !p.is_ended()));
            map.insert(rk.to_string(), Arc::downgrade(&peer));
            signed.restarts = true;
        }
        tokio::spawn(handle_rtc(a.clone(), RtcConn::new(peer), source, permit));
        Ok(signed.to_json())
    }
}

/// An ICE restart (docs/LINK.md「WebRTC」「换网络」): the connection whose key is `restart_key(secret)` takes the new
/// offer (its candidates, new ICE credentials) and goes on over the path it finds: the same DTLS, SCTP, channels and
/// session. The offer must be the same client's (its DTLS fingerprint). An unknown secret counts as a failure with
/// the guard; it is a `NotFound`-like refusal (`InvalidArgument`), so the client dials again.
fn restart_rtc(
    a: &Arc<Accepting>,
    hub: &Arc<Hub>,
    identity: &dyn IdentitySigner,
    offer: &RtcOffer,
    secret: &str,
    source: Option<IpAddr>,
) -> Result<String> {
    if source.is_some_and(|ip| a.ep.inner.guard.is_blocked(ip)) {
        return Err(LinkError::Denied { code: DenyCode::RateLimited, message: "blocked".into() });
    }
    let key = (secret.len() <= MAX_RESTART_SECRET).then(|| rtc::restart_key(secret));
    let peer =
        key.and_then(|k| a.restarts.lock().unwrap().remove(&k)).and_then(|w| w.upgrade()).filter(|p| !p.is_ended());
    let client_fp = rtc::sdp_fingerprint(&offer.offer);
    let Some(peer) = peer.filter(|p| client_fp.as_ref().is_some_and(|fp| p.remote_id() == format!("dtls-{fp}"))) else {
        failed(&a.ep, source, "unknown rtc restart");
        return Err(LinkError::InvalidArgument("no connection to restart".into()));
    };
    let (usable, remote_candidates) = rtc::usable_sdp(&offer.offer);
    let sdp = str0m::change::SdpOffer::from_sdp_string(&usable)
        .map_err(|e| LinkError::InvalidArgument(format!("offer SDP: {e}")))?;
    let (answer, fingerprint) = peer.restart(sdp, remote_candidates)?;
    let binding = binding::sign_binding_with(identity, &a.ep.public_key())?;
    let answer_sdp = rtc::with_nat64(&rtc::filter_candidates(&answer.to_sdp_string(), |x| hub.announces(x)));
    let mut signed = rtc::sign_answer(identity, binding, &offer.offer, answer_sdp, fingerprint)?;
    if let Some(rk) = offer.rk.as_deref().filter(|k| valid_restart_key(k)) {
        a.restarts.lock().unwrap().insert(rk.to_string(), Arc::downgrade(&peer));
        signed.restarts = true;
    }
    info!("link: rtc restart of {} ({} candidates)", peer.remote_id(), offer.offer.matches("a=candidate").count());
    Ok(signed.to_json())
}

/// Why a client's handshake failed: from the close code when no `denied` was read.
fn denied_by_close(conn: &Conn) -> LinkError {
    match conn.ended() {
        Some(e) => {
            let info = e.info(None);
            match info.code.and_then(|c| c.deny_code()) {
                Some(code) => LinkError::Denied { code, message: info.reason },
                None => LinkError::Closed(info.describe()),
            }
        }
        None => LinkError::protocol("control stream ended before welcome"),
    }
}

async fn accept_loop(a: Arc<Accepting>) {
    while let Some(incoming) = a.ep.inner.ep.accept().await {
        let remote = incoming.remote_addr();
        let ip = match &remote {
            IncomingAddr::Ip(sa) => Some(sa.ip().to_canonical()),
            _ => None,
        };
        let permit = match a.ep.inner.guard.admit(ip) {
            Ok(p) => p,
            Err(r) => {
                if r != Refusal::Blocked {
                    debug!("link: refused {remote:?}: {r:?}");
                }
                incoming.refuse();
                continue;
            }
        };
        tokio::spawn(handle_incoming(a.clone(), incoming, remote, ip, permit));
    }
}

/// Counts a failure from `ip` with the guard (and says when it starts a cooldown).
fn failed(ep: &Endpoint, ip: Option<IpAddr>, why: &str) {
    if let Some(ip) = ip
        && ep.inner.guard.failed(ip)
    {
        warn!(
            "link: {ip} blocked for {} s after repeated failures ({why})",
            ep.inner.guard.config().cooldown.as_secs()
        );
    }
}

async fn handle_incoming(
    a: Arc<Accepting>,
    incoming: Incoming,
    remote: IncomingAddr,
    ip: Option<IpAddr>,
    permit: Permit,
) {
    let server_media = media::ServerMedia::new(a.options.media.clone());
    let target = TargetBitrate::with_media(server_media.target_rate());
    let server_config =
        a.ep.inner
            .ep
            .create_server_config_builder(vec![ALPN.to_vec()])
            .set_transport_config(transport_config(Role::Server, target.clone()))
            .build();
    let accepting = match incoming.accept_with(Arc::new(server_config)) {
        Ok(a) => a,
        Err(e) => {
            debug!("link: incoming failed: {e}");
            return;
        }
    };
    let conn = match tokio::time::timeout(HANDSHAKE_TIMEOUT, accepting).await {
        Ok(Ok(c)) => c,
        Ok(Err(e)) => {
            debug!("link: handshake from {remote:?} failed: {e}");
            failed(&a.ep, ip, "handshake");
            return;
        }
        Err(_) => {
            failed(&a.ep, ip, "handshake timeout");
            return;
        }
    };
    let known: HashSet<SocketAddr> = match &remote {
        IncomingAddr::Ip(sa) => [*sa].into_iter().collect(),
        _ => HashSet::new(),
    };
    let source = Source {
        addr: match &remote {
            IncomingAddr::Ip(sa) => Some(*sa),
            _ => None,
        },
        relay: match &remote {
            IncomingAddr::Relay { url, .. } => Some(url.to_string()),
            _ => None,
        },
        path: path::classify(&TransportAddr::from(remote.clone()), &known).kind,
    };
    let control = {
        let conn = conn.clone();
        async move {
            let (s, r) = conn.accept_bi().await.map_err(|e| LinkError::Closed(e.to_string()))?;
            Ok((SendHalf::Quic(s), RecvHalf::Quic(r)))
        }
    };
    let pending = Pending { conn: Conn::Quic(conn), source, known, ip, permit, target, media: server_media };
    serve(a, pending, control).await;
}

async fn handle_rtc(a: Arc<Accepting>, conn: RtcConn, signal_ip: Option<IpAddr>, permit: Permit) {
    let server_media = media::ServerMedia::new(a.options.media.clone());
    let target = TargetBitrate::with_media(server_media.target_rate());
    let control = match tokio::time::timeout(rtc::CONNECT_TIMEOUT, conn.control()).await {
        Ok(Some((s, r))) => (SendHalf::Rtc(s), RecvHalf::Rtc(r)),
        Ok(None) => return,
        Err(_) => {
            debug!("link: rtc offer from {signal_ip:?}: not connected within {} s", rtc::CONNECT_TIMEOUT.as_secs());
            failed(&a.ep, signal_ip, "rtc connect timeout");
            conn.close(CloseCode::Protocol, "not connected in time");
            return;
        }
    };
    let remote = conn.remote_addr();
    let path = conn.path();
    let ip = signal_ip.or_else(|| remote.map(|r| r.ip().to_canonical()));
    let source = Source { addr: remote, relay: None, path: path.kind };
    let pending =
        Pending { conn: Conn::Rtc(conn), source, known: HashSet::new(), ip, permit, target, media: server_media };
    serve(a, pending, async move { Ok(control) }).await;
}

/// A connection up to its `hello`.
struct Pending {
    conn: Conn,
    source: Source,
    known: HashSet<SocketAddr>,
    /// Whose failures count with the guard.
    ip: Option<IpAddr>,
    permit: Permit,
    target: TargetBitrate,
    media: media::ServerMedia,
}

/// `hello` (the control stream within `hello_timeout`), the authenticator, `welcome` / `denied`, the session.
async fn serve(a: Arc<Accepting>, p: Pending, control: impl Future<Output = Result<(SendHalf, RecvHalf)>>) {
    let Pending { conn, source, known, ip, mut permit, target, media: server_media } = p;
    let fail = |why: &str| failed(&a.ep, ip, why);
    let hello_read = tokio::time::timeout(a.options.hello_timeout, async {
        let (send, mut recv) = control.await?;
        let m = framing::read_frame(&mut recv, MAX_CONTROL_FRAME).await?;
        Ok::<_, LinkError>((send, recv, m))
    })
    .await;
    let (mut send, recv, hello) = match hello_read {
        Ok(Ok((s, r, Some(m)))) if m.get("t").and_then(Value::as_str) == Some("hello") => (s, r, m),
        Ok(Ok(_)) | Ok(Err(LinkError::Protocol(_))) => {
            fail("bad hello");
            conn.close(CloseCode::Protocol, "expected hello");
            return;
        }
        Ok(Err(_)) => {
            fail("closed before hello");
            return;
        }
        Err(_) => {
            fail("no hello");
            conn.close(CloseCode::Protocol, "no hello within 5 s");
            return;
        }
    };
    if hello.get("v").and_then(Value::as_u64) != Some(1) {
        conn.close(CloseCode::Protocol, "unsupported version");
        return;
    }
    let hello: Hello = match serde_json::from_value(Value::Object(hello)) {
        Ok(h) => h,
        Err(e) => {
            fail("bad hello");
            conn.close(CloseCode::Protocol, &format!("hello: {e}"));
            return;
        }
    };

    let request = AuthRequest { hello: hello.clone(), client_key: conn.remote_id(), source };
    let decision = match tokio::time::timeout(AUTH_TIMEOUT, a.options.authenticator.authenticate(request)).await {
        Ok(d) => d,
        Err(_) => AuthDecision::Deny { code: DenyCode::Busy, message: "no answer".into() },
    };
    match decision {
        AuthDecision::Deny { code, message } => {
            if code == DenyCode::Unauthorized {
                fail("unauthorized");
            }
            info!("link: denied {} ({}): {code} {message}", hello.device.name, hello.device.id);
            let msg = json!({"t": "denied", "code": code.as_str(), "message": message});
            deny(conn, send, &msg, code).await;
        }
        AuthDecision::Accept { principal, features } => {
            let welcome = Welcome {
                server: a.options.server.clone(),
                principal,
                features: features.unwrap_or_else(|| a.options.features.clone()),
                max_datagram: conn.max_datagram_size() as u32,
            };
            if let Err(e) =
                framing::write_frame(&mut send, &session::welcome_message(&welcome), MAX_CONTROL_FRAME).await
            {
                debug!("link: welcome not sent: {e}");
                return;
            }
            permit.authenticated();
            let session = Session::start(Parts {
                id: a.ep.inner.next_session.fetch_add(1, Ordering::Relaxed),
                side: Side::Server,
                conn,
                hello,
                welcome,
                control_send: send,
                control_recv: recv,
                target,
                known,
                iface: a.ep.inner.iface.clone(),
                permit: Some(permit),
                rpc: a.rpc.clone(),
                endpoint: a.ep.inner.ep.clone(),
                media: media::Engine::Server(Box::new(server_media)),
            });
            if a.tx.send(session.clone()).await.is_err() {
                session.close(CloseCode::ShuttingDown, "not listening").await;
            }
        }
    }
}

/// `denied`, then the close: the client closes when it read it; we close after 2 s at the latest.
async fn deny(conn: Conn, mut send: SendHalf, msg: &Value, code: DenyCode) {
    if framing::write_frame(&mut send, msg, MAX_CONTROL_FRAME).await.is_ok() {
        if let SendHalf::Quic(s) = &mut send {
            let _ = s.finish();
        }
        let _ = tokio::time::timeout(Duration::from_secs(2), conn.closed()).await;
    }
    conn.close(code.close_code(), code.as_str());
}

#[cfg(test)]
mod relay_url_tests {
    use super::*;

    #[test]
    fn a_relay_token_is_not_part_of_its_address() {
        let c = parse_relay_configs(&["https://relay1.example.com/?token=abc".into(), "https://r2.example.com".into()])
            .unwrap();
        assert_eq!(c[0].0.as_str(), "https://relay1.example.com/");
        assert_eq!(c[0].1.as_deref(), Some("abc"));
        assert_eq!(c[1].1, None);
        assert_eq!(
            parse_relays(&["https://relay1.example.com/?token=abc".into()]).unwrap()[0].as_str(),
            "https://relay1.example.com/"
        );
        assert!(relay_map(&[]).unwrap().is_none());
        assert!(parse_relays(&["not a url".into()]).is_err());
    }
}
