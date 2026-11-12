//! uu Link for Node (napi-rs): the native addon inside `@yoyocontrol/link` (packages/link). The TypeScript wrapper
//! there gives it its public shape; this layer stays close to the core.
//!
//! - Async methods return promises; they run on one tokio runtime (2 workers) handed to napi at module load.
//! - Errors are JS `Error`s whose message starts with `[kind]` or `[denied:<code>]` (the wrapper parses it).
//! - Callbacks (log sink, address watcher, authenticator, RPC handler) are thread-safe functions: called on the JS
//!   thread, never blocking the runtime. The authenticator returns a promise of its decision.

use std::{collections::HashMap, net::IpAddr, sync::Arc, time::Duration};

use async_trait::async_trait;
use bytes::Bytes;
use n0_future::StreamExt;
use napi::{
    Status,
    bindgen_prelude::{Buffer, FnArgs, Promise},
    threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode},
};
use napi_derive::napi;
use serde_json::Value;
use uu_link as core;
use uu_link::media;

type Result<T> = napi::Result<T>;

#[napi_derive::module_init]
fn init() {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("uu-link")
        .enable_all()
        .build()
        .expect("uu-link: cannot start the tokio runtime");
    napi::bindgen_prelude::create_custom_tokio_runtime(rt);
}

fn err(e: core::LinkError) -> napi::Error {
    use core::LinkError as E;
    let (kind, msg) = match e {
        E::InvalidArgument(m) => ("invalid-argument".to_string(), m),
        E::Bind(m) => ("bind".into(), m),
        E::Connect(m) => ("connect".into(), m),
        E::Timeout(m) => ("timeout".into(), m),
        E::Denied { code, message } => (format!("denied:{}", code.as_str()), message),
        E::Protocol(m) => ("protocol".into(), m),
        E::Closed(m) => ("closed".into(), m),
        E::Binding(m) => ("binding".into(), m),
        E::Datagram(m) => ("datagram".into(), m),
        E::Io(m) => ("io".into(), m),
        E::Media(m) => ("media".into(), m),
    };
    napi::Error::new(Status::GenericFailure, format!("[{kind}] {msg}"))
}

fn invalid(msg: impl Into<String>) -> napi::Error {
    napi::Error::new(Status::InvalidArg, format!("[invalid-argument] {}", msg.into()))
}

fn key32(b: &[u8]) -> Result<[u8; 32]> {
    b.try_into().map_err(|_| invalid(format!("a link key is 32 bytes, not {}", b.len())))
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

// MARK: functions

#[napi]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[napi]
pub fn generate_link_key() -> Buffer {
    core::binding::generate_link_key().to_vec().into()
}

#[napi]
pub fn link_public_key(secret_key: Buffer) -> Result<String> {
    Ok(hex(&core::binding::link_public_key(&key32(&secret_key)?)))
}

#[napi]
pub fn load_or_create_link_key(path: String) -> Result<Buffer> {
    Ok(core::binding::load_or_create_link_key(std::path::Path::new(&path)).map_err(err)?.to_vec().into())
}

#[napi]
pub fn identity_fingerprint(identity_key: Buffer) -> Result<String> {
    core::binding::identity_fingerprint(&identity_key).map_err(err)
}

#[napi(object)]
#[derive(Clone)]
pub struct Binding {
    pub id: String,
    pub key: String,
    pub sig: String,
}

#[napi]
pub fn sign_binding(identity_key: Buffer, link_public_key: String) -> Result<Binding> {
    let id = core::binding::parse_endpoint_id(&link_public_key).map_err(err)?;
    let b = core::sign_binding(&identity_key, &id).map_err(err)?;
    Ok(Binding { id: b.id, key: b.key, sig: b.sig })
}

#[napi]
pub fn verify_binding(binding: Binding, fingerprint: String) -> Result<String> {
    let b = core::Binding { id: binding.id, key: binding.key, sig: binding.sig };
    Ok(hex(&core::verify_binding(&b, &fingerprint).map_err(err)?))
}

type LogFn = ThreadsafeFunction<FnArgs<(String, String)>, (), FnArgs<(String, String)>, Status, false>;

/// `(level, message)` for every link log line; `null`: back to the default (tracing, i.e. nowhere).
#[napi]
pub fn set_log_sink(sink: Option<LogFn>) {
    core::log::set_log_sink(sink.map(|f| {
        let f = Arc::new(f);
        let s: core::log::LogSink = Arc::new(move |level, message: &str| {
            let level = match level {
                core::log::LogLevel::Debug => "debug",
                core::log::LogLevel::Info => "info",
                core::log::LogLevel::Warn => "warn",
                core::log::LogLevel::Error => "error",
            };
            f.call((level.to_string(), message.to_string()).into(), ThreadsafeFunctionCallMode::NonBlocking);
        });
        s
    }));
}

// MARK: objects

#[napi(object)]
pub struct GuardSettings {
    pub failure_limit: Option<u32>,
    pub failure_window_ms: Option<u32>,
    pub cooldown_ms: Option<u32>,
    pub max_sessions: Option<u32>,
    pub max_unauthenticated: Option<u32>,
    pub exempt: Option<Vec<String>>,
}

#[napi(object)]
pub struct EndpointConfig {
    /// "server" | "client"
    pub role: String,
    pub secret_key: Buffer,
    pub port: Option<u32>,
    pub relays: Option<Vec<String>>,
    pub portmapper: Option<bool>,
    pub guard: Option<GuardSettings>,
    /// Also open the WebRTC socket(s) on this UDP port (0 = any; uu's servers use the link port + 1); absent = no rtc.
    pub rtc_port: Option<u32>,
    /// STUN servers (`host:port`) for the server's public address in rtc answers.
    pub rtc_stun_servers: Option<Vec<String>>,
    /// rtc answers offer only the external addresses (`addRtcExternalAddr`, STUN), not the interfaces'.
    pub rtc_external_only: Option<bool>,
    /// Only these local addresses (default: every interface, IPv4 and IPv6).
    pub bind_ips: Option<Vec<String>>,
}

#[napi(object)]
pub struct AddrInfo {
    pub id: String,
    pub relays: Vec<String>,
    pub direct: Vec<String>,
}

impl From<core::AddrInfo> for AddrInfo {
    fn from(a: core::AddrInfo) -> Self {
        AddrInfo { id: a.id, relays: a.relays, direct: a.direct }
    }
}

#[napi(object)]
pub struct DialTarget {
    pub id: String,
    pub relays: Option<Vec<String>>,
    pub direct: Option<Vec<String>>,
}

#[napi(object)]
#[derive(Clone)]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
}

#[napi(object)]
#[derive(Clone)]
pub struct AppInfo {
    pub name: String,
    pub version: String,
}

#[napi(object)]
#[derive(Clone)]
pub struct Hello {
    pub credential: String,
    pub device: DeviceInfo,
    pub app: AppInfo,
    pub features: Option<Vec<String>>,
}

impl From<Hello> for core::Hello {
    fn from(h: Hello) -> Self {
        core::Hello {
            credential: h.credential,
            device: core::Device { id: h.device.id, name: h.device.name },
            app: core::AppInfo { name: h.app.name, version: h.app.version },
            features: h.features.unwrap_or_default(),
        }
    }
}

impl From<&core::Hello> for Hello {
    fn from(h: &core::Hello) -> Self {
        Hello {
            credential: h.credential.clone(),
            device: DeviceInfo { id: h.device.id.clone(), name: h.device.name.clone() },
            app: AppInfo { name: h.app.name.clone(), version: h.app.version.clone() },
            features: Some(h.features.clone()),
        }
    }
}

#[napi(object)]
pub struct ServerInfo {
    pub id: String,
    pub name: String,
    pub platform: String,
}

#[napi(object)]
pub struct Welcome {
    pub server: ServerInfo,
    pub principal: Value,
    pub features: Vec<String>,
    pub max_datagram: u32,
}

#[napi(object)]
pub struct ServerSettings {
    pub server: ServerInfo,
    pub features: Option<Vec<String>>,
    pub rpc_blocked_paths: Option<Vec<String>>,
    pub max_request_body: Option<u32>,
    /// Every NACK also asks for a recovery frame at once (an encoder with cheap recovery frames). Default off.
    pub recovery_on_nack: Option<bool>,
    /// The identity private key (97-byte X9.63) that signs rtc answers; absent = `acceptRtcOffer` refuses.
    pub identity_key: Option<Buffer>,
}

#[napi(object)]
pub struct AuthRequest {
    pub hello: Hello,
    pub client_key: String,
    pub source_addr: Option<String>,
    pub source_relay: Option<String>,
    /// "relay" | "lan" | "direct" | "punched" | "none"
    pub path: String,
}

/// `{ ok: true, principal, features? }` or `{ ok: false, code: "unauthorized" | "rate-limited" | "busy", message? }`.
#[napi(object)]
pub struct AuthAnswer {
    pub ok: bool,
    pub principal: Option<Value>,
    pub features: Option<Vec<String>>,
    pub code: Option<String>,
    pub message: Option<String>,
}

#[napi(object)]
pub struct RpcRequest {
    pub method: String,
    pub path: String,
    pub headers: Option<HashMap<String, String>>,
}

#[napi(object)]
pub struct PathInfo {
    pub kind: String,
    pub remote: Option<String>,
}

#[napi(object)]
pub struct CloseInfo {
    pub code: Option<u32>,
    pub reason: String,
    pub remote: bool,
    pub description: String,
}

impl From<core::CloseInfo> for CloseInfo {
    fn from(c: core::CloseInfo) -> Self {
        let description = c.describe();
        CloseInfo { code: c.code.map(|c| c.code() as u32), reason: c.reason, remote: c.remote, description }
    }
}

fn stats_value(s: core::StatsSnapshot) -> Value {
    let line = s.line();
    let mut v = serde_json::to_value(&s).unwrap_or_default();
    if let Some(m) = v.as_object_mut() {
        m.insert("line".into(), line.into());
    }
    v
}

// MARK: endpoint

#[napi]
pub struct LinkEndpoint {
    inner: core::Endpoint,
    /// The `watch_addr` tasks: ended by `close` (an address watcher holds the endpoint open, and its callback the
    /// Node event loop).
    watchers: std::sync::Mutex<Vec<tokio::task::JoinHandle<()>>>,
}

#[napi]
pub async fn bind_endpoint(config: EndpointConfig) -> Result<LinkEndpoint> {
    let secret = key32(&config.secret_key)?;
    let port = config.port.unwrap_or(0);
    let port = u16::try_from(port).map_err(|_| invalid(format!("port {port}")))?;
    let mut cfg = match config.role.as_str() {
        "server" => core::EndpointConfig::server(secret, port),
        "client" => core::EndpointConfig::client(secret),
        r => return Err(invalid(format!("role {r}: server or client"))),
    };
    cfg.port = port;
    cfg.relays = config.relays.unwrap_or_default();
    cfg.portmapper = config.portmapper;
    cfg.bind_ips = config
        .bind_ips
        .unwrap_or_default()
        .iter()
        .map(|s| s.parse::<IpAddr>().map_err(|_| invalid(format!("bindIps: {s}"))))
        .collect::<Result<Vec<_>>>()?;
    if let Some(p) = config.rtc_port {
        let port = u16::try_from(p).map_err(|_| invalid(format!("rtcPort {p}")))?;
        cfg.rtc = Some(core::RtcConfig {
            port,
            stun_servers: config.rtc_stun_servers.unwrap_or_default(),
            external_only: config.rtc_external_only.unwrap_or(false),
        });
    }
    if let Some(g) = config.guard {
        let d = core::GuardConfig::default();
        let exempt = g
            .exempt
            .unwrap_or_default()
            .iter()
            .map(|s| s.parse::<IpAddr>().map_err(|_| invalid(format!("guard exempt: {s}"))))
            .collect::<Result<Vec<_>>>()?;
        cfg.guard = core::GuardConfig {
            failure_limit: g.failure_limit.unwrap_or(d.failure_limit),
            failure_window: g.failure_window_ms.map(|m| Duration::from_millis(m as u64)).unwrap_or(d.failure_window),
            cooldown: g.cooldown_ms.map(|m| Duration::from_millis(m as u64)).unwrap_or(d.cooldown),
            max_sessions: g.max_sessions.map(|m| m as usize).unwrap_or(d.max_sessions),
            max_unauthenticated: g.max_unauthenticated.map(|m| m as usize).unwrap_or(d.max_unauthenticated),
            exempt,
            exempt_loopback: true,
        };
    }
    let ep = core::Endpoint::bind(cfg).await.map_err(err)?;
    Ok(LinkEndpoint { inner: ep, watchers: Default::default() })
}

type AddrFn = ThreadsafeFunction<AddrInfo, (), AddrInfo, Status, false>;
type SignalFn = ThreadsafeFunction<String, Promise<String>, String, Status, false>;
type AuthFn = ThreadsafeFunction<AuthRequest, Promise<AuthAnswer>, AuthRequest, Status, false>;
type RpcArgs = FnArgs<(LinkSession, RpcRequest, Buffer, RpcResponder)>;
type RpcFn = ThreadsafeFunction<RpcArgs, (), RpcArgs, Status, false>;

#[napi]
impl LinkEndpoint {
    #[napi(getter)]
    pub fn id(&self) -> String {
        self.inner.id()
    }

    #[napi(getter)]
    pub fn port(&self) -> u32 {
        self.inner.port() as u32
    }

    #[napi]
    pub fn addr_info(&self) -> AddrInfo {
        self.inner.addr_info().into()
    }

    /// The rtc UDP port; `null` without rtc.
    #[napi(getter)]
    pub fn rtc_port(&self) -> Option<u32> {
        self.inner.rtc_port().map(u32::from)
    }

    /// The rtc port's router mapping (`ip:port`): rtc answers offer it until removed. False without rtc.
    #[napi]
    pub fn add_rtc_external_addr(&self, addr: String) -> Result<bool> {
        let a = addr.parse().map_err(|_| err(core::LinkError::InvalidArgument(format!("{addr} is not ip:port"))))?;
        Ok(self.inner.add_rtc_external_addr(a))
    }

    #[napi]
    pub fn remove_rtc_external_addr(&self, addr: String) -> Result<bool> {
        let a = addr.parse().map_err(|_| err(core::LinkError::InvalidArgument(format!("{addr} is not ip:port"))))?;
        Ok(self.inner.remove_rtc_external_addr(a))
    }

    /// Calls `cb(info)` now and at every change of the address info, until the endpoint is closed.
    #[napi]
    pub fn watch_addr(&self, cb: AddrFn) {
        let mut stream = self.inner.watch_addr_info();
        let task = napi::bindgen_prelude::spawn(async move {
            while let Some(a) = stream.next().await {
                cb.call(a.into(), ThreadsafeFunctionCallMode::NonBlocking);
            }
        });
        self.watchers.lock().unwrap().push(task);
    }

    #[napi]
    pub fn binding(&self, identity_key: Buffer) -> Result<Binding> {
        let b = self.inner.binding(&identity_key).map_err(err)?;
        Ok(Binding { id: b.id, key: b.key, sig: b.sig })
    }

    /// An `ip:port` the endpoint is reachable on that it can't see itself (the app's router port mapping).
    #[napi]
    pub async fn add_external_addr(&self, addr: String) -> Result<()> {
        let a = addr.parse().map_err(|_| err(core::LinkError::InvalidArgument(format!("{addr} is not ip:port"))))?;
        self.inner.add_external_addr(a).await;
        Ok(())
    }

    #[napi]
    pub async fn remove_external_addr(&self, addr: String) -> Result<bool> {
        let a = addr.parse().map_err(|_| err(core::LinkError::InvalidArgument(format!("{addr} is not ip:port"))))?;
        Ok(self.inner.remove_external_addr(a).await)
    }

    /// `iface`: "wifi" | "cellular" | "wired" | "other".
    #[napi]
    pub async fn network_changed(&self, iface: Option<String>) {
        self.inner.network_changed(iface.as_deref().map(core::Iface::parse)).await;
    }

    #[napi]
    pub async fn dial(&self, target: DialTarget, hello: Hello, connect_timeout_ms: Option<u32>) -> Result<LinkSession> {
        let mut opts = core::DialOptions::default();
        if let Some(ms) = connect_timeout_ms {
            opts.connect_timeout = Duration::from_millis(ms as u64);
        }
        let t = core::DialTarget {
            id: target.id,
            relays: target.relays.unwrap_or_default(),
            direct: target.direct.unwrap_or_default(),
        };
        let s = self.inner.dial(&t, &hello.into(), &opts).await.map_err(err)?;
        Ok(LinkSession { inner: s })
    }

    /// Dials a server over WebRTC as a browser does: `signal(offerJson)` carries the offer to the server's
    /// `acceptRtcOffer` and resolves with its answer JSON, checked against the pinned identity `fingerprint`. Needs
    /// `rtcPort` in the endpoint config.
    #[napi]
    pub async fn dial_rtc(
        &self,
        signal: SignalFn,
        fingerprint: String,
        hello: Hello,
        connect_timeout_ms: Option<u32>,
    ) -> Result<LinkSession> {
        let mut opts = core::DialOptions::default();
        if let Some(ms) = connect_timeout_ms {
            opts.connect_timeout = Duration::from_millis(ms as u64);
        }
        let signal = |offer: String| async move {
            match signal.call_async_catch(offer).await {
                Ok(p) => p.await.map_err(|e| core::LinkError::Connect(format!("signal: {}", e.reason))),
                Err(e) => Err(core::LinkError::Connect(format!("signal: {}", e.reason))),
            }
        };
        let s = self.inner.dial_rtc(signal, &fingerprint, &hello.into(), &opts).await.map_err(err)?;
        Ok(LinkSession { inner: s })
    }

    /// Starts accepting sessions. `authenticate(request)` resolves to an `AuthAnswer`; `rpc(session, request, body,
    /// responder)` answers through the responder.
    #[napi]
    pub fn listen(&self, settings: ServerSettings, authenticate: AuthFn, rpc: Option<RpcFn>) -> Result<LinkListener> {
        let s = settings.server;
        let mut opts = core::ServerOptions::new(
            core::ServerInfo { id: s.id, name: s.name, platform: s.platform },
            Arc::new(JsAuthenticator(Arc::new(authenticate))),
        );
        opts.features = settings.features.unwrap_or_default();
        if let Some(p) = settings.rpc_blocked_paths {
            opts.rpc_blocked_paths = p;
        }
        if let Some(m) = settings.max_request_body {
            opts.max_request_body = m as usize;
        }
        opts.media.video.recovery_on_nack = settings.recovery_on_nack.unwrap_or(false);
        if let Some(k) = settings.identity_key {
            opts.rtc_identity = Some(Arc::new(core::IdentityKey::new(&k).map_err(err)?));
        }
        opts.rpc = rpc.map(|f| Arc::new(JsRpc(Arc::new(f))) as Arc<dyn core::RpcHandler>);
        let ep = self.inner.clone();
        let listener = napi::bindgen_prelude::block_on(async move { ep.listen(opts) }).map_err(err)?;
        Ok(LinkListener { inner: Arc::new(listener) })
    }

    #[napi]
    pub async fn close(&self) {
        for t in self.watchers.lock().unwrap().drain(..) {
            t.abort();
        }
        self.inner.close().await;
    }
}

struct JsAuthenticator(Arc<AuthFn>);

#[async_trait]
impl core::Authenticator for JsAuthenticator {
    async fn authenticate(&self, r: core::AuthRequest) -> core::AuthDecision {
        let busy = |m: &str| core::AuthDecision::Deny { code: core::DenyCode::Busy, message: m.into() };
        let req = AuthRequest {
            hello: (&r.hello).into(),
            client_key: r.client_key,
            source_addr: r.source.addr.map(|a| a.to_string()),
            source_relay: r.source.relay,
            path: r.source.path.as_str().into(),
        };
        let answer = match self.0.call_async_catch(req).await {
            Ok(p) => p.await,
            Err(e) => Err(e),
        };
        match answer {
            Ok(a) if a.ok => {
                core::AuthDecision::Accept { principal: a.principal.unwrap_or(Value::Null), features: a.features }
            }
            Ok(a) => core::AuthDecision::Deny {
                code: core::DenyCode::parse(a.code.as_deref().unwrap_or("unauthorized")),
                message: a.message.unwrap_or_default(),
            },
            Err(e) => busy(&format!("authenticator failed: {}", e.reason)),
        }
    }
}

struct JsRpc(Arc<RpcFn>);

#[async_trait]
impl core::RpcHandler for JsRpc {
    async fn handle(
        &self,
        session: core::Session,
        request: core::RpcRequest,
        body: Bytes,
        responder: core::RpcResponder,
    ) {
        let req = RpcRequest {
            method: request.method,
            path: request.path,
            headers: Some(request.headers.into_iter().collect()),
        };
        let args = (
            LinkSession { inner: session },
            req,
            Buffer::from(body.to_vec()),
            RpcResponder { inner: Arc::new(tokio::sync::Mutex::new(Some(responder))) },
        );
        self.0.call(args.into(), ThreadsafeFunctionCallMode::NonBlocking);
    }
}

#[napi]
pub struct LinkListener {
    inner: Arc<core::Listener>,
}

#[napi]
impl LinkListener {
    /// The next authenticated session; `null` once the endpoint is closed.
    #[napi]
    pub async fn accept(&self) -> Option<LinkSession> {
        self.inner.accept().await.map(|s| LinkSession { inner: s })
    }

    /// A browser's WebRTC offer JSON → the signed answer JSON (docs/LINK.md「WebRTC」); the session comes out of
    /// `accept`. `sourceIp`: the signaling request's address when known (the guard counts its failures).
    #[napi]
    pub async fn accept_rtc_offer(&self, offer_json: String, source_ip: Option<String>) -> Result<String> {
        let ip = match source_ip {
            Some(s) => Some(s.parse::<IpAddr>().map_err(|_| invalid(format!("sourceIp {s}")))?),
            None => None,
        };
        self.inner.accept_rtc_offer(&offer_json, ip).await.map_err(err)
    }
}

// MARK: session

#[napi]
pub struct LinkSession {
    inner: core::Session,
}

#[napi]
impl LinkSession {
    #[napi(getter)]
    pub fn id(&self) -> f64 {
        self.inner.id() as f64
    }

    #[napi(getter)]
    pub fn is_server(&self) -> bool {
        self.inner.side() == core::Side::Server
    }

    /// hex of the other side's link key (an rtc client: `dtls-sha256:<hex>` of its DTLS certificate).
    #[napi(getter)]
    pub fn remote_id(&self) -> String {
        self.inner.remote_id().to_string()
    }

    /// "quic" | "rtc".
    #[napi(getter)]
    pub fn transport(&self) -> String {
        self.inner.transport().as_str().into()
    }

    #[napi]
    pub fn hello(&self) -> Hello {
        self.inner.hello().into()
    }

    #[napi]
    pub fn welcome(&self) -> Welcome {
        let w = self.inner.welcome();
        Welcome {
            server: ServerInfo {
                id: w.server.id.clone(),
                name: w.server.name.clone(),
                platform: w.server.platform.clone(),
            },
            principal: w.principal.clone(),
            features: w.features.clone(),
            max_datagram: w.max_datagram,
        }
    }

    #[napi]
    pub async fn send_control(&self, message: Value) -> Result<()> {
        self.inner.send_control(&message).await.map_err(err)
    }

    /// The next control message; `null` once the session ended.
    #[napi]
    pub async fn recv_control(&self) -> Option<Value> {
        self.inner.recv_control().await
    }

    #[napi]
    pub async fn request(&self, request: RpcRequest, body: Option<Buffer>) -> Result<RpcResponse> {
        let req = core::RpcRequest {
            method: request.method,
            path: request.path,
            headers: request
                .headers
                .unwrap_or_default()
                .into_iter()
                .map(|(k, v)| (k.to_ascii_lowercase(), v))
                .collect(),
        };
        let body = body.map(|b| b.to_vec()).unwrap_or_default();
        let r = self.inner.request(&req, &body).await.map_err(err)?;
        Ok(RpcResponse {
            status: r.status as u32,
            headers: r.headers.into_iter().collect(),
            body: Arc::new(tokio::sync::Mutex::new(r.body)),
        })
    }

    #[napi]
    pub fn send_datagram(&self, channel: u32, payload: Buffer) -> Result<()> {
        let ch = u8::try_from(channel).map_err(|_| invalid(format!("channel {channel}")))?;
        self.inner.send_datagram(ch, &payload).map_err(err)
    }

    #[napi]
    pub fn send_datagram_raw(&self, datagram: Buffer) -> Result<()> {
        self.inner.send_datagram_raw(Bytes::copy_from_slice(&datagram)).map_err(err)
    }

    /// The next datagram of `channel`, whole (byte 0 = header); `null` once the session ended.
    #[napi]
    pub async fn recv_datagram(&self, channel: u32) -> Result<Option<Buffer>> {
        let ch = u8::try_from(channel).map_err(|_| invalid(format!("channel {channel}")))?;
        Ok(self.inner.recv_datagram(ch).await.map_err(err)?.map(|b| b.to_vec().into()))
    }

    #[napi(getter)]
    pub fn max_datagram_size(&self) -> u32 {
        self.inner.max_datagram_size() as u32
    }

    #[napi(getter)]
    pub fn target_bitrate(&self) -> f64 {
        self.inner.target_bitrate().get() as f64
    }

    #[napi(setter)]
    pub fn set_target_bitrate(&self, bps: f64) {
        self.inner.target_bitrate().set(bps.max(1.0) as u64)
    }

    #[napi]
    pub fn path(&self) -> PathInfo {
        let p = self.inner.path();
        PathInfo { kind: p.kind.as_str().into(), remote: p.remote }
    }

    #[napi]
    pub fn stats(&self) -> Value {
        stats_value(self.inner.stats())
    }

    #[napi]
    pub fn peer_stats(&self) -> Option<Value> {
        self.inner.peer_stats().map(stats_value)
    }

    /// The media layer's numbers (`MediaStats` fields, camelCase).
    #[napi]
    pub fn set_media_stats(&self, stats: Value) -> Result<()> {
        let m: core::MediaStats = serde_json::from_value(stats).map_err(|e| invalid(format!("media stats: {e}")))?;
        self.inner.set_media_stats(m);
        Ok(())
    }

    #[napi]
    pub async fn close(&self, code: Option<u32>, reason: Option<String>) {
        let code = core::CloseCode::from_code(code.unwrap_or(0) as u64);
        self.inner.close(code, reason.as_deref().unwrap_or("")).await;
    }

    #[napi(getter)]
    pub fn is_closed(&self) -> bool {
        self.inner.is_closed()
    }

    #[napi]
    pub async fn closed(&self) -> CloseInfo {
        self.inner.closed().await.into()
    }
}

// MARK: media (channels 1–5)

/// `codec`: "h264" | "hevc"; `kind`: "delta" | "key" | "refine" | "keepalive" | "recovery".
#[napi(object)]
pub struct FrameMeta {
    pub codec: String,
    pub kind: String,
    pub width: u32,
    pub height: u32,
    /// µs since the Unix epoch (latency stats only)
    pub capture_us: Option<f64>,
    /// recovery frames: the frame they reference
    pub recovery_base: Option<u32>,
}

fn frame_kind_name(k: media::FrameKind) -> &'static str {
    match k {
        media::FrameKind::Delta => "delta",
        media::FrameKind::Key => "key",
        media::FrameKind::Refine => "refine",
        media::FrameKind::Keepalive => "keepalive",
        media::FrameKind::Recovery => "recovery",
    }
}

impl FrameMeta {
    fn to_core(&self) -> Result<media::FrameMeta> {
        let codec = match self.codec.as_str() {
            "h264" => media::Codec::H264,
            "hevc" => media::Codec::Hevc,
            c => return Err(invalid(format!("codec {c}: h264 or hevc"))),
        };
        let kind = match self.kind.as_str() {
            "delta" => media::FrameKind::Delta,
            "key" => media::FrameKind::Key,
            "refine" => media::FrameKind::Refine,
            "keepalive" => media::FrameKind::Keepalive,
            "recovery" => media::FrameKind::Recovery,
            k => return Err(invalid(format!("frame kind {k}"))),
        };
        Ok(media::FrameMeta {
            codec,
            kind,
            width: self.width as u16,
            height: self.height as u16,
            capture_us: self.capture_us.unwrap_or(0.0) as u64,
            recovery_base: self.recovery_base.unwrap_or(0),
            au_len: 0,
        })
    }

    fn from_core(m: &media::FrameMeta) -> FrameMeta {
        FrameMeta {
            codec: match m.codec {
                media::Codec::H264 => "h264".into(),
                media::Codec::Hevc => "hevc".into(),
            },
            kind: frame_kind_name(m.kind).into(),
            width: m.width as u32,
            height: m.height as u32,
            capture_us: Some(m.capture_us as f64),
            recovery_base: Some(m.recovery_base),
        }
    }
}

#[napi(object)]
pub struct VideoFrame {
    pub stream: u32,
    pub frame: u32,
    pub meta: FrameMeta,
    /// the Annex-B access unit
    pub au: Buffer,
    pub first_arrival_us: f64,
    pub delivered_at_us: f64,
}

#[napi(object)]
pub struct AudioPacket {
    pub stream: u32,
    pub aseq: u32,
    pub time_us: f64,
    pub data: Buffer,
    pub recovered: bool,
    pub gap_before: u32,
}

/// `kind`: "discrete" | "move"; `json`: the `/input` body.
#[napi(object)]
pub struct InputEvent {
    pub seq: u32,
    pub kind: String,
    pub json: Buffer,
}

/// `type`: "targetBitrate" | "frameDelivered" | "recoveryNeeded" | "keyframeNeeded" | "input".
#[napi(object)]
pub struct ServerMediaEvent {
    #[napi(js_name = "type")]
    pub kind: String,
    pub target_bps: Option<f64>,
    pub encoder_bps: Option<f64>,
    pub stream: Option<u32>,
    pub frame: Option<u32>,
    pub last_delivered: Option<u32>,
    pub input: Option<InputEvent>,
}

impl From<media::ServerEvent> for ServerMediaEvent {
    fn from(e: media::ServerEvent) -> Self {
        let mut out = ServerMediaEvent {
            kind: String::new(),
            target_bps: None,
            encoder_bps: None,
            stream: None,
            frame: None,
            last_delivered: None,
            input: None,
        };
        match e {
            media::ServerEvent::TargetBitrate { target_bps, encoder_bps } => {
                out.kind = "targetBitrate".into();
                out.target_bps = Some(target_bps as f64);
                out.encoder_bps = Some(encoder_bps as f64);
            }
            media::ServerEvent::FrameDelivered { stream, frame } => {
                out.kind = "frameDelivered".into();
                out.stream = Some(stream as u32);
                out.frame = Some(frame);
            }
            media::ServerEvent::RecoveryNeeded { stream, last_delivered } => {
                out.kind = "recoveryNeeded".into();
                out.stream = Some(stream as u32);
                out.last_delivered = last_delivered;
            }
            media::ServerEvent::KeyframeNeeded { stream } => {
                out.kind = "keyframeNeeded".into();
                out.stream = Some(stream as u32);
            }
            media::ServerEvent::Input(i) => {
                out.kind = "input".into();
                out.input = Some(InputEvent {
                    seq: i.seq,
                    kind: match i.kind {
                        media::InputKind::Discrete => "discrete".into(),
                        media::InputKind::Move => "move".into(),
                    },
                    json: i.json.into(),
                });
            }
        }
        out
    }
}

/// `type`: "frame" | "audio" | "cursor" | "inputAcked" | "inputFailed".
#[napi(object)]
pub struct ClientMediaEvent {
    #[napi(js_name = "type")]
    pub kind: String,
    pub frame: Option<VideoFrame>,
    pub audio: Option<AudioPacket>,
    pub stream: Option<u32>,
    pub cseq: Option<u32>,
    /// cursor JSON `{x,y,visible,shapeId}`
    pub json: Option<Buffer>,
    pub through: Option<u32>,
    pub seq: Option<u32>,
}

impl From<media::ClientEvent> for ClientMediaEvent {
    fn from(e: media::ClientEvent) -> Self {
        let mut out = ClientMediaEvent {
            kind: String::new(),
            frame: None,
            audio: None,
            stream: None,
            cseq: None,
            json: None,
            through: None,
            seq: None,
        };
        match e {
            media::ClientEvent::Frame(f) => {
                out.kind = "frame".into();
                out.frame = Some(VideoFrame {
                    stream: f.stream as u32,
                    frame: f.frame,
                    meta: FrameMeta::from_core(&f.meta),
                    au: f.au.into(),
                    first_arrival_us: f.first_arrival.0 as f64,
                    delivered_at_us: f.delivered_at.0 as f64,
                });
            }
            media::ClientEvent::Audio(a) => {
                out.kind = "audio".into();
                out.audio = Some(AudioPacket {
                    stream: a.stream as u32,
                    aseq: a.aseq,
                    time_us: a.time_us as f64,
                    data: a.data.into(),
                    recovered: a.recovered,
                    gap_before: a.gap_before,
                });
            }
            media::ClientEvent::Cursor { stream, cseq, json } => {
                out.kind = "cursor".into();
                out.stream = Some(stream as u32);
                out.cseq = Some(cseq);
                out.json = Some(json.into());
            }
            media::ClientEvent::InputAcked { through } => {
                out.kind = "inputAcked".into();
                out.through = Some(through);
            }
            media::ClientEvent::InputFailed { seq } => {
                out.kind = "inputFailed".into();
                out.seq = Some(seq);
            }
        }
        out
    }
}

fn stream_id(s: u32) -> Result<u8> {
    u8::try_from(s).map_err(|_| invalid(format!("stream {s}")))
}

#[napi]
impl LinkSession {
    #[napi]
    pub fn open_video(&self, stream: u32) -> Result<()> {
        self.inner.open_video(stream_id(stream)?);
        Ok(())
    }

    #[napi]
    pub fn close_video(&self, stream: u32) -> Result<()> {
        self.inner.close_video(stream_id(stream)?);
        Ok(())
    }

    #[napi]
    pub fn open_audio(&self, stream: u32) -> Result<()> {
        self.inner.open_audio(stream_id(stream)?);
        Ok(())
    }

    #[napi]
    pub fn close_audio(&self, stream: u32) -> Result<()> {
        self.inner.close_audio(stream_id(stream)?);
        Ok(())
    }

    /// Server: whether to encode the next picture now (false: skip it).
    #[napi]
    pub fn can_send_frame(&self, stream: u32) -> Result<bool> {
        self.inner.can_send_frame(stream_id(stream)?).map_err(err)
    }

    /// Server: the frame-rate cap of `stream` (frames/s, follows the encoder rate; null: no such stream). An
    /// encoder that budgets per frame at a fixed frame rate should be given `encoderBps × its fps / cap`.
    #[napi]
    pub fn frame_rate_cap(&self, stream: u32) -> Result<Option<f64>> {
        self.inner.frame_rate_cap(stream_id(stream)?).map_err(err)
    }

    /// Server: one encoded frame; returns its frame number.
    #[napi]
    pub fn send_frame(&self, stream: u32, meta: FrameMeta, au: Buffer) -> Result<u32> {
        self.inner.send_frame(stream_id(stream)?, meta.to_core()?, &au).map_err(err)
    }

    /// Server: one Opus packet; returns its aseq.
    #[napi]
    pub fn send_audio(&self, stream: u32, time_us: f64, opus: Buffer) -> Result<u32> {
        self.inner.send_audio(stream_id(stream)?, time_us as u64, &opus).map_err(err)
    }

    /// Server: the newest cursor position (JSON).
    #[napi]
    pub fn send_cursor(&self, stream: u32, json: Buffer) -> Result<()> {
        self.inner.send_cursor(stream_id(stream)?, &json).map_err(err)
    }

    /// Server: force a key frame next; client: ask for one.
    #[napi]
    pub fn request_keyframe(&self, stream: u32) -> Result<()> {
        self.inner.request_keyframe(stream_id(stream)?);
        Ok(())
    }

    /// Server: the next media event; `null` once the session ended.
    #[napi]
    pub async fn next_server_event(&self) -> Option<ServerMediaEvent> {
        self.inner.recv_server_event().await.map(Into::into)
    }

    /// Client: one input event (`kind` "discrete" | "move", the `/input` JSON); returns its seq.
    #[napi]
    pub fn send_input(&self, kind: String, json: Buffer) -> Result<u32> {
        let k = match kind.as_str() {
            "discrete" => media::InputKind::Discrete,
            "move" => media::InputKind::Move,
            k => return Err(invalid(format!("input kind {k}: discrete or move"))),
        };
        self.inner.send_input(k, &json).map_err(err)
    }

    /// Client: the decoder took (`ok`) or failed on a frame.
    #[napi]
    pub fn frame_decoded(&self, stream: u32, frame: u32, ok: bool) -> Result<()> {
        self.inner.frame_decoded(stream_id(stream)?, frame, ok).map_err(err)
    }

    /// Client: the next media event; `null` once the session ended.
    #[napi]
    pub async fn next_client_event(&self) -> Option<ClientMediaEvent> {
        self.inner.recv_client_event().await.map(Into::into)
    }
}

// MARK: RPC

#[napi]
pub struct RpcResponse {
    status: u32,
    headers: HashMap<String, String>,
    body: Arc<tokio::sync::Mutex<core::RpcBody>>,
}

#[napi]
impl RpcResponse {
    #[napi(getter)]
    pub fn status(&self) -> u32 {
        self.status
    }

    #[napi(getter)]
    pub fn headers(&self) -> HashMap<String, String> {
        self.headers.clone()
    }

    /// The next piece of the body; `null` at its end.
    #[napi]
    pub async fn chunk(&self) -> Result<Option<Buffer>> {
        Ok(self.body.lock().await.chunk().await.map_err(err)?.map(|c| c.to_vec().into()))
    }

    #[napi]
    pub async fn read_all(&self, limit: Option<u32>) -> Result<Buffer> {
        let limit = limit.map(|l| l as usize).unwrap_or(64 << 20);
        Ok(self.body.lock().await.read_all(limit).await.map_err(err)?.to_vec().into())
    }

    #[napi]
    pub fn cancel(&self) {
        let b = self.body.clone();
        napi::bindgen_prelude::spawn(async move { b.lock().await.cancel() });
    }
}

#[napi]
pub struct RpcResponder {
    inner: Arc<tokio::sync::Mutex<Option<core::RpcResponder>>>,
}

fn finished() -> napi::Error {
    napi::Error::new(Status::GenericFailure, "[closed] response already finished")
}

fn lower(h: Option<HashMap<String, String>>) -> core::Headers {
    h.unwrap_or_default().into_iter().map(|(k, v)| (k.to_ascii_lowercase(), v)).collect()
}

#[napi]
impl RpcResponder {
    #[napi]
    pub async fn head(&self, status: u32, headers: Option<HashMap<String, String>>) -> Result<()> {
        let mut g = self.inner.lock().await;
        g.as_mut().ok_or_else(finished)?.head(status as u16, &lower(headers)).await.map_err(err)
    }

    #[napi]
    pub async fn write(&self, data: Buffer) -> Result<()> {
        let data = data.to_vec();
        let mut g = self.inner.lock().await;
        g.as_mut().ok_or_else(finished)?.write(&data).await.map_err(err)
    }

    #[napi]
    pub async fn finish(&self) -> Result<()> {
        let mut r = self.inner.lock().await.take().ok_or_else(finished)?;
        r.finish().await.map_err(err)
    }

    #[napi]
    pub async fn respond(
        &self,
        status: u32,
        headers: Option<HashMap<String, String>>,
        body: Option<Buffer>,
    ) -> Result<()> {
        let body = body.map(|b| b.to_vec()).unwrap_or_default();
        let mut r = self.inner.lock().await.take().ok_or_else(finished)?;
        r.respond(status as u16, &lower(headers), &body).await.map_err(err)
    }

    /// Resolves when the client stopped reading (cancelled) or the session ended.
    #[napi]
    pub async fn stopped(&self) {
        let f = self.inner.lock().await.as_ref().map(|r| r.stopped());
        if let Some(f) = f {
            f.await;
        }
    }
}
