//! uu Link for Swift (UniFFI, proc-macro style). The generated bindings live in
//! `ios/YoyoKit/Sources/YoyoLink/Generated/` and the idiomatic wrapper beside them (target `YoyoLink`).
//!
//! Every async call runs on the core's one tokio runtime (`uu_link::runtime`) and is awaited through its join
//! handle, so a panic inside becomes an `Internal` error instead of unwinding into Swift. Callbacks into Swift
//! (log sink, address observer, authenticator, RPC handler) are plain synchronous calls from runtime threads;
//! answers that take time come back through a reply object (`AuthReply`, `RpcResponder`).

use std::{
    collections::HashMap,
    future::Future,
    net::{IpAddr, SocketAddr},
    sync::{Arc, Mutex},
    time::Duration,
};

use async_trait::async_trait;
use bytes::Bytes;
use n0_future::StreamExt;
use tokio::sync::oneshot;
use uu_link as core;
use uu_link::media;

uniffi::setup_scaffolding!("uu_link_ffi");

// MARK: errors

#[derive(Debug, Clone, thiserror::Error, uniffi::Error)]
pub enum LinkError {
    #[error("invalid argument: {message}")]
    InvalidArgument { message: String },
    #[error("bind failed: {message}")]
    Bind { message: String },
    #[error("connect failed: {message}")]
    Connect { message: String },
    #[error("timed out: {message}")]
    Timeout { message: String },
    #[error("denied ({code:?}): {message}")]
    Denied { code: DenyCode, message: String },
    #[error("protocol error: {message}")]
    Protocol { message: String },
    #[error("session closed: {message}")]
    Closed { message: String },
    #[error("binding: {message}")]
    Binding { message: String },
    #[error("datagram: {message}")]
    Datagram { message: String },
    #[error("{message}")]
    Io { message: String },
    #[error("media: {message}")]
    Media { message: String },
    #[error("internal error: {message}")]
    Internal { message: String },
}

impl From<core::LinkError> for LinkError {
    fn from(e: core::LinkError) -> Self {
        use core::LinkError as E;
        match e {
            E::InvalidArgument(message) => LinkError::InvalidArgument { message },
            E::Bind(message) => LinkError::Bind { message },
            E::Connect(message) => LinkError::Connect { message },
            E::Timeout(message) => LinkError::Timeout { message },
            E::Denied { code, message } => LinkError::Denied { code: code.into(), message },
            E::Protocol(message) => LinkError::Protocol { message },
            E::Closed(message) => LinkError::Closed { message },
            E::Binding(message) => LinkError::Binding { message },
            E::Datagram(message) => LinkError::Datagram { message },
            E::Io(message) => LinkError::Io { message },
            E::Media(message) => LinkError::Media { message },
        }
    }
}

type Result<T> = std::result::Result<T, LinkError>;

fn invalid(message: impl Into<String>) -> LinkError {
    LinkError::InvalidArgument { message: message.into() }
}

/// Runs `fut` on the core's runtime; a panic in it is an `Internal` error.
async fn on_runtime<F, T>(fut: F) -> Result<T>
where
    F: Future<Output = Result<T>> + Send + 'static,
    T: Send + 'static,
{
    match core::runtime::runtime().spawn(fut).await {
        Ok(r) => r,
        Err(e) if e.is_panic() => Err(LinkError::Internal { message: panic_message(e.into_panic()) }),
        Err(e) => Err(LinkError::Internal { message: e.to_string() }),
    }
}

fn panic_message(p: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = p.downcast_ref::<&str>() {
        format!("panic: {s}")
    } else if let Some(s) = p.downcast_ref::<String>() {
        format!("panic: {s}")
    } else {
        "panic".into()
    }
}

/// A synchronous call with panics turned into errors (debug builds; release builds abort on panic).
fn guarded<T>(f: impl FnOnce() -> Result<T>) -> Result<T> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f))
        .unwrap_or_else(|p| Err(LinkError::Internal { message: panic_message(p) }))
}

// MARK: enums

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Role {
    Server,
    Client,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DenyCode {
    Unauthorized,
    RateLimited,
    Busy,
}

impl From<core::DenyCode> for DenyCode {
    fn from(c: core::DenyCode) -> Self {
        match c {
            core::DenyCode::Unauthorized => DenyCode::Unauthorized,
            core::DenyCode::RateLimited => DenyCode::RateLimited,
            core::DenyCode::Busy => DenyCode::Busy,
        }
    }
}

impl From<DenyCode> for core::DenyCode {
    fn from(c: DenyCode) -> Self {
        match c {
            DenyCode::Unauthorized => core::DenyCode::Unauthorized,
            DenyCode::RateLimited => core::DenyCode::RateLimited,
            DenyCode::Busy => core::DenyCode::Busy,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PathKind {
    Relay,
    Lan,
    Direct,
    Punched,
    None,
}

impl From<core::PathKind> for PathKind {
    fn from(k: core::PathKind) -> Self {
        match k {
            core::PathKind::Relay => PathKind::Relay,
            core::PathKind::Lan => PathKind::Lan,
            core::PathKind::Direct => PathKind::Direct,
            core::PathKind::Punched => PathKind::Punched,
            core::PathKind::None => PathKind::None,
        }
    }
}

impl From<PathKind> for core::PathKind {
    fn from(k: PathKind) -> Self {
        match k {
            PathKind::Relay => core::PathKind::Relay,
            PathKind::Lan => core::PathKind::Lan,
            PathKind::Direct => core::PathKind::Direct,
            PathKind::Punched => core::PathKind::Punched,
            PathKind::None => core::PathKind::None,
        }
    }
}

/// Which transport a session runs on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Transport {
    /// QUIC over iroh (the native apps).
    Quic,
    /// WebRTC data channels (browsers; docs/LINK.md「WebRTC」).
    Rtc,
}

impl From<core::Transport> for Transport {
    fn from(t: core::Transport) -> Self {
        match t {
            core::Transport::Quic => Transport::Quic,
            core::Transport::Rtc => Transport::Rtc,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Iface {
    Wifi,
    Cellular,
    Wired,
    Other,
}

impl From<Iface> for core::Iface {
    fn from(i: Iface) -> Self {
        match i {
            Iface::Wifi => core::Iface::Wifi,
            Iface::Cellular => core::Iface::Cellular,
            Iface::Wired => core::Iface::Wired,
            Iface::Other => core::Iface::Other,
        }
    }
}

impl From<core::Iface> for Iface {
    fn from(i: core::Iface) -> Self {
        match i {
            core::Iface::Wifi => Iface::Wifi,
            core::Iface::Cellular => Iface::Cellular,
            core::Iface::Wired => Iface::Wired,
            core::Iface::Other => Iface::Other,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

/// QUIC application close codes.
#[uniffi::export]
pub fn close_code_name(code: u64) -> String {
    core::CloseCode::from_code(code).name().to_string()
}

// MARK: records

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Binding {
    pub id: String,
    pub key: String,
    pub sig: String,
}

impl From<core::Binding> for Binding {
    fn from(b: core::Binding) -> Self {
        Binding { id: b.id, key: b.key, sig: b.sig }
    }
}

impl From<Binding> for core::Binding {
    fn from(b: Binding) -> Self {
        core::Binding { id: b.id, key: b.key, sig: b.sig }
    }
}

/// The server's guard (defaults: 10 failures / 60 s → 5 min; 32 sessions, 4 unauthenticated).
#[derive(Debug, Clone, uniffi::Record)]
pub struct GuardSettings {
    pub failure_limit: u32,
    pub failure_window_ms: u64,
    pub cooldown_ms: u64,
    pub max_sessions: u32,
    pub max_unauthenticated: u32,
    /// IP addresses never limited (besides loopback).
    pub exempt: Vec<String>,
}

#[uniffi::export]
pub fn default_guard_settings() -> GuardSettings {
    let g = core::GuardConfig::default();
    GuardSettings {
        failure_limit: g.failure_limit,
        failure_window_ms: g.failure_window.as_millis() as u64,
        cooldown_ms: g.cooldown.as_millis() as u64,
        max_sessions: g.max_sessions as u32,
        max_unauthenticated: g.max_unauthenticated as u32,
        exempt: vec![],
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EndpointConfig {
    pub role: Role,
    /// The link secret key (32 bytes).
    pub secret_key: Vec<u8>,
    /// UDP port (0 = any).
    pub port: u16,
    /// Relay URLs; empty = direct only.
    pub relays: Vec<String>,
    /// Router port mapping; nil = servers yes, clients no.
    pub portmapper: Option<bool>,
    pub guard: Option<GuardSettings>,
    /// Bind only these IP addresses (one socket each) instead of `0.0.0.0` and `[::]`; empty = both wildcards. A
    /// host with several networks, or a test that must only be reachable through an impairment proxy.
    #[uniffi(default)]
    pub bind_ips: Vec<String>,
    /// Also open the WebRTC socket(s) on this UDP port (0 = any; uu's servers use the link port + 1); nil = no rtc.
    /// Servers then answer browsers' offers (`LinkListener.accept_rtc_offer`).
    #[uniffi(default)]
    pub rtc_port: Option<u16>,
    /// STUN servers (`host:port`) for the server's public address in rtc answers; empty = none.
    #[uniffi(default)]
    pub rtc_stun_servers: Vec<String>,
    /// rtc answers offer only the external addresses (`add_rtc_external_addr`, STUN), not the interfaces'.
    #[uniffi(default)]
    pub rtc_external_only: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
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

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DialTarget {
    pub id: String,
    pub relays: Vec<String>,
    pub direct: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeviceInfo {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AppInfo {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Hello {
    pub credential: String,
    pub device: DeviceInfo,
    pub app: AppInfo,
    pub features: Vec<String>,
}

impl From<Hello> for core::Hello {
    fn from(h: Hello) -> Self {
        core::Hello {
            credential: h.credential,
            device: core::Device { id: h.device.id, name: h.device.name },
            app: core::AppInfo { name: h.app.name, version: h.app.version },
            features: h.features,
        }
    }
}

impl From<&core::Hello> for Hello {
    fn from(h: &core::Hello) -> Self {
        Hello {
            credential: h.credential.clone(),
            device: DeviceInfo { id: h.device.id.clone(), name: h.device.name.clone() },
            app: AppInfo { name: h.app.name.clone(), version: h.app.version.clone() },
            features: h.features.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerInfo {
    pub id: String,
    pub name: String,
    pub platform: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Welcome {
    pub server: ServerInfo,
    /// JSON text.
    pub principal_json: String,
    pub features: Vec<String>,
    pub max_datagram: u32,
}

impl From<&core::Welcome> for Welcome {
    fn from(w: &core::Welcome) -> Self {
        Welcome {
            server: ServerInfo {
                id: w.server.id.clone(),
                name: w.server.name.clone(),
                platform: w.server.platform.clone(),
            },
            principal_json: w.principal.to_string(),
            features: w.features.clone(),
            max_datagram: w.max_datagram,
        }
    }
}

/// The listening options of a server.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ServerSettings {
    pub server: ServerInfo,
    pub features: Vec<String>,
    /// nil = the defaults (the channels' HTTP paths answer 404).
    pub rpc_blocked_paths: Option<Vec<String>>,
    pub max_request_body: Option<u64>,
    /// Every NACK also asks the app for a recovery frame at once (`RecoveryNeeded`), beside the retransmit: for an
    /// encoder whose recovery frames are cheap P-frames (VideoToolbox long-term references). Default off.
    #[uniffi(default)]
    pub recovery_on_nack: bool,
    /// The identity private key (97-byte X9.63, the identity files' format) that signs rtc answers and the binding
    /// in them; nil = `accept_rtc_offer` refuses.
    #[uniffi(default)]
    pub identity_key: Option<Vec<u8>>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AuthRequest {
    pub hello: Hello,
    /// hex of the client's link public key (rtc: `dtls-sha256:<hex>` of the browser's DTLS certificate).
    pub client_key: String,
    pub source_addr: Option<String>,
    pub source_relay: Option<String>,
    pub path: PathKind,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RpcRequest {
    pub method: String,
    pub path: String,
    pub headers: HashMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PathInfo {
    pub kind: PathKind,
    pub remote: Option<String>,
}

impl From<core::PathInfo> for PathInfo {
    fn from(p: core::PathInfo) -> Self {
        PathInfo { kind: p.kind.into(), remote: p.remote }
    }
}

#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct MediaStats {
    pub loss_pct: Option<f64>,
    pub fec_recovered: Option<u64>,
    pub nack_recovered: Option<u64>,
    pub nack_sent: Option<u64>,
    pub lost_frames: Option<u64>,
    pub skipped_frames: Option<u64>,
    pub freeze_count: Option<u64>,
    pub freeze_ms: Option<u64>,
    pub rate_target_mbps: Option<f64>,
    pub rate_sent_mbps: Option<f64>,
    pub fps: Option<f64>,
    pub input_p50_ms: Option<f64>,
    pub input_p90_ms: Option<f64>,
    pub input_n: Option<u64>,
    pub audio_loss_pct: Option<f64>,
    pub audio_red: Option<u32>,
}

impl From<MediaStats> for core::MediaStats {
    fn from(m: MediaStats) -> Self {
        core::MediaStats {
            loss_pct: m.loss_pct,
            fec_recovered: m.fec_recovered,
            nack_recovered: m.nack_recovered,
            nack_sent: m.nack_sent,
            lost_frames: m.lost_frames,
            skipped_frames: m.skipped_frames,
            freeze_count: m.freeze_count,
            freeze_ms: m.freeze_ms,
            rate_target_mbps: m.rate_target_mbps,
            rate_sent_mbps: m.rate_sent_mbps,
            fps: m.fps,
            input_p50_ms: m.input_p50_ms,
            input_p90_ms: m.input_p90_ms,
            input_n: m.input_n,
            audio_loss_pct: m.audio_loss_pct,
            audio_red: m.audio_red,
            ..Default::default()
        }
    }
}

impl From<core::MediaStats> for MediaStats {
    fn from(m: core::MediaStats) -> Self {
        MediaStats {
            loss_pct: m.loss_pct,
            fec_recovered: m.fec_recovered,
            nack_recovered: m.nack_recovered,
            nack_sent: m.nack_sent,
            lost_frames: m.lost_frames,
            skipped_frames: m.skipped_frames,
            freeze_count: m.freeze_count,
            freeze_ms: m.freeze_ms,
            rate_target_mbps: m.rate_target_mbps,
            rate_sent_mbps: m.rate_sent_mbps,
            fps: m.fps,
            input_p50_ms: m.input_p50_ms,
            input_p90_ms: m.input_p90_ms,
            input_n: m.input_n,
            audio_loss_pct: m.audio_loss_pct,
            audio_red: m.audio_red,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LinkStats {
    pub path: PathKind,
    pub iface: Iface,
    pub remote: Option<String>,
    pub rtt_min_ms: f64,
    pub rtt_p50_ms: f64,
    pub rtt_p90_ms: f64,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    pub packets_lost: u64,
    pub datagrams_sent: u64,
    pub datagrams_received: u64,
    pub datagram_drops: u64,
    pub media: MediaStats,
    /// The `link:` line's body (`<path> <iface> rtt …`).
    pub line: String,
}

impl From<core::StatsSnapshot> for LinkStats {
    fn from(s: core::StatsSnapshot) -> Self {
        let line = s.line();
        LinkStats {
            path: s.path.into(),
            iface: s.iface.into(),
            remote: s.remote,
            rtt_min_ms: s.rtt_min_ms,
            rtt_p50_ms: s.rtt_p50_ms,
            rtt_p90_ms: s.rtt_p90_ms,
            bytes_sent: s.bytes_sent,
            bytes_received: s.bytes_received,
            packets_lost: s.packets_lost,
            datagrams_sent: s.datagrams_sent,
            datagrams_received: s.datagrams_received,
            datagram_drops: s.datagram_drops,
            media: s.media.into(),
            line,
        }
    }
}

/// The speed test's result (`LinkSession.probe`, docs/LINK.md「测速」). Rates in Mbit/s, times in ms; nil = not
/// measured.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ProbeReport {
    pub transport: Transport,
    pub path: PathKind,
    pub iface: Iface,
    pub duration_ms: u64,
    /// The idle path's RTT (lowest of the 10 s before), and the RTT under the test's load.
    pub rtt_idle_ms: Option<f64>,
    pub rtt_p50_ms: Option<f64>,
    pub rtt_p90_ms: Option<f64>,
    /// Frames delivered; their payload rate over the whole test, the best second, the last two seconds.
    pub frames: u64,
    pub received_mbps: Option<f64>,
    pub peak_mbps: Option<f64>,
    pub final_mbps: Option<f64>,
    pub final_fps: Option<f64>,
    /// Media datagrams lost before FEC (%), and what FEC / NACK got back.
    pub loss_pct: Option<f64>,
    pub fec_recovered: u64,
    pub nack_recovered: u64,
    pub lost_frames: u64,
    pub skipped_frames: u64,
    pub freezes: u64,
    pub freeze_ms: u64,
    pub server: Option<ProbeServerReport>,
    /// All of the above as JSON (camelCase, the shape docs/LINK.md「测速」 lists).
    pub json: String,
}

/// The server's half of the report (`link.probe.done`).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ProbeServerReport {
    pub target_mbps: f64,
    pub max_target_mbps: f64,
    pub encoder_mbps: f64,
    pub fps_cap: f64,
    pub sent_mbps: Option<f64>,
    pub frames: u64,
    pub bytes: u64,
    pub rate_cuts: u64,
    pub rate_loss_cuts: u64,
    pub retransmits: u64,
    pub jitter_ms: Option<f64>,
    pub reason: String,
}

impl From<core::ProbeReport> for ProbeReport {
    fn from(r: core::ProbeReport) -> Self {
        let json = serde_json::to_string(&r).unwrap_or_default();
        ProbeReport {
            transport: r.transport.into(),
            path: r.path.into(),
            iface: r.iface.into(),
            duration_ms: r.duration_ms,
            rtt_idle_ms: r.rtt_idle_ms,
            rtt_p50_ms: r.rtt_p50_ms,
            rtt_p90_ms: r.rtt_p90_ms,
            frames: r.frames,
            received_mbps: r.received_mbps,
            peak_mbps: r.peak_mbps,
            final_mbps: r.final_mbps,
            final_fps: r.final_fps,
            loss_pct: r.loss_pct,
            fec_recovered: r.fec_recovered,
            nack_recovered: r.nack_recovered,
            lost_frames: r.lost_frames,
            skipped_frames: r.skipped_frames,
            freezes: r.freezes,
            freeze_ms: r.freeze_ms,
            server: r.server.map(|s| ProbeServerReport {
                target_mbps: s.target_mbps,
                max_target_mbps: s.max_target_mbps,
                encoder_mbps: s.encoder_mbps,
                fps_cap: s.fps_cap,
                sent_mbps: s.sent_mbps,
                frames: s.frames,
                bytes: s.bytes,
                rate_cuts: s.rate_cuts,
                rate_loss_cuts: s.rate_loss_cuts,
                retransmits: s.retransmits,
                jitter_ms: s.jitter_ms,
                reason: s.reason,
            }),
            json,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CloseInfo {
    /// The application close code (0 normal, 1 unauthorized, 2 rate-limited, 3 busy, 4 protocol, 5 shutting down,
    /// 6 replaced); nil for transport-level ends (idle timeout, reset).
    pub code: Option<u64>,
    pub reason: String,
    pub remote: bool,
    pub description: String,
}

impl From<core::CloseInfo> for CloseInfo {
    fn from(c: core::CloseInfo) -> Self {
        let description = c.describe();
        CloseInfo { code: c.code.map(|c| c.code()), reason: c.reason, remote: c.remote, description }
    }
}

// MARK: free functions

#[uniffi::export]
pub fn link_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[uniffi::export]
pub fn generate_link_key() -> Vec<u8> {
    core::binding::generate_link_key().to_vec()
}

fn key32(bytes: &[u8]) -> Result<[u8; 32]> {
    bytes.try_into().map_err(|_| invalid(format!("a link key is 32 bytes, not {}", bytes.len())))
}

/// hex of the public key (the endpoint id) of a link secret key.
#[uniffi::export]
pub fn link_public_key(secret_key: Vec<u8>) -> Result<String> {
    let k = key32(&secret_key)?;
    Ok(hex(&core::binding::link_public_key(&k)))
}

/// The link secret key in `path` (32 bytes, 0600), made on first use.
#[uniffi::export]
pub fn load_or_create_link_key(path: String) -> Result<Vec<u8>> {
    guarded(|| Ok(core::binding::load_or_create_link_key(std::path::Path::new(&path))?.to_vec()))
}

/// `"sha256:" + hex(SHA-256(public key))` of a 97-byte X9.63 identity key.
#[uniffi::export]
pub fn identity_fingerprint(identity_key: Vec<u8>) -> Result<String> {
    guarded(|| Ok(core::binding::identity_fingerprint(&identity_key)?))
}

/// The identity's binding over a link public key (hex).
#[uniffi::export]
pub fn sign_binding(identity_key: Vec<u8>, link_public_key: String) -> Result<Binding> {
    guarded(|| {
        let id = core::binding::parse_endpoint_id(&link_public_key)?;
        Ok(core::sign_binding(&identity_key, &id)?.into())
    })
}

/// Checks a binding against the pinned fingerprint; returns the endpoint id (hex) it vouches for.
#[uniffi::export]
pub fn verify_binding(binding: Binding, fingerprint: String) -> Result<String> {
    guarded(|| Ok(hex(&core::verify_binding(&binding.into(), &fingerprint)?)))
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

// MARK: callbacks

#[uniffi::export(foreign)]
pub trait LogSink: Send + Sync {
    fn log(&self, level: LogLevel, message: String);
}

/// Sends the link's log lines (`link:` stats, sessions, paths, guard) to `sink`; nil: back to the default.
#[uniffi::export]
pub fn set_log_sink(sink: Option<Arc<dyn LogSink>>) {
    core::log::set_log_sink(sink.map(|s| {
        let f: core::log::LogSink = Arc::new(move |level, message: &str| {
            let level = match level {
                core::log::LogLevel::Debug => LogLevel::Debug,
                core::log::LogLevel::Info => LogLevel::Info,
                core::log::LogLevel::Warn => LogLevel::Warn,
                core::log::LogLevel::Error => LogLevel::Error,
            };
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| s.log(level, message.to_string())));
        });
        f
    }));
}

#[uniffi::export(foreign)]
pub trait AddrObserver: Send + Sync {
    fn on_addr(&self, info: AddrInfo);
}

/// Decides about each `hello`: call `reply.accept(…)` or `reply.deny(…)` (once, from any thread, now or later;
/// no answer within 10 s is `busy`).
#[uniffi::export(foreign)]
pub trait Authenticator: Send + Sync {
    fn authenticate(&self, request: AuthRequest, reply: Arc<AuthReply>);
}

/// Handles one RPC request: answer through `responder` (now or later, from any thread).
#[uniffi::export(foreign)]
pub trait RpcHandler: Send + Sync {
    fn handle(&self, session: Arc<LinkSession>, request: RpcRequest, body: Vec<u8>, responder: Arc<RpcResponder>);
}

#[derive(uniffi::Object)]
pub struct AuthReply {
    tx: Mutex<Option<oneshot::Sender<core::AuthDecision>>>,
}

#[uniffi::export]
impl AuthReply {
    /// `principal_json`: a JSON value (what `welcome.principal` says); `features`: nil = the server's list.
    pub fn accept(&self, principal_json: String, features: Option<Vec<String>>) -> Result<()> {
        let principal: serde_json::Value =
            serde_json::from_str(&principal_json).map_err(|e| invalid(format!("principal_json: {e}")))?;
        self.send(core::AuthDecision::Accept { principal, features })
    }

    pub fn deny(&self, code: DenyCode, message: String) -> Result<()> {
        self.send(core::AuthDecision::Deny { code: code.into(), message })
    }
}

impl AuthReply {
    fn send(&self, d: core::AuthDecision) -> Result<()> {
        let tx = self.tx.lock().unwrap().take().ok_or_else(|| invalid("already answered"))?;
        let _ = tx.send(d);
        Ok(())
    }
}

struct ForeignAuthenticator(Arc<dyn Authenticator>);

#[async_trait]
impl core::Authenticator for ForeignAuthenticator {
    async fn authenticate(&self, request: core::AuthRequest) -> core::AuthDecision {
        let (tx, rx) = oneshot::channel();
        let reply = Arc::new(AuthReply { tx: Mutex::new(Some(tx)) });
        let req = AuthRequest {
            hello: (&request.hello).into(),
            client_key: request.client_key,
            source_addr: request.source.addr.map(|a| a.to_string()),
            source_relay: request.source.relay,
            path: request.source.path.into(),
        };
        let inner = self.0.clone();
        if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| inner.authenticate(req, reply))).is_err() {
            return core::AuthDecision::Deny { code: core::DenyCode::Busy, message: "authenticator failed".into() };
        }
        rx.await.unwrap_or(core::AuthDecision::Deny { code: core::DenyCode::Busy, message: "no answer".into() })
    }
}

/// Carries an rtc offer to the server (`LinkEndpoint.dial_rtc`): call `reply.answer(json)` with the server's answer
/// JSON or `reply.fail(message)` (once, from any thread).
#[uniffi::export(foreign)]
pub trait RtcSignaler: Send + Sync {
    fn signal(&self, offer_json: String, reply: Arc<SignalReply>);
}

#[derive(uniffi::Object)]
pub struct SignalReply {
    tx: Mutex<Option<oneshot::Sender<std::result::Result<String, String>>>>,
}

#[uniffi::export]
impl SignalReply {
    pub fn answer(&self, answer_json: String) -> Result<()> {
        self.send(Ok(answer_json))
    }

    pub fn fail(&self, message: String) -> Result<()> {
        self.send(Err(message))
    }
}

impl SignalReply {
    fn send(&self, r: std::result::Result<String, String>) -> Result<()> {
        let tx = self.tx.lock().unwrap().take().ok_or_else(|| invalid("already answered"))?;
        let _ = tx.send(r);
        Ok(())
    }
}

struct ForeignRpc(Arc<dyn RpcHandler>);

#[async_trait]
impl core::RpcHandler for ForeignRpc {
    async fn handle(
        &self,
        session: core::Session,
        request: core::RpcRequest,
        body: Bytes,
        responder: core::RpcResponder,
    ) {
        let req =
            RpcRequest { method: request.method, path: request.path, headers: request.headers.into_iter().collect() };
        let responder = Arc::new(RpcResponder { inner: tokio::sync::Mutex::new(Some(responder)) });
        let session = Arc::new(LinkSession { inner: session });
        let inner = self.0.clone();
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            inner.handle(session, req, body.to_vec(), responder)
        }));
    }
}

// MARK: endpoint

#[derive(uniffi::Object)]
pub struct LinkEndpoint {
    inner: core::Endpoint,
}

/// Binds an endpoint (UDP on `0.0.0.0:port` and `[::]:port`).
#[uniffi::export]
pub async fn bind_endpoint(config: EndpointConfig) -> Result<Arc<LinkEndpoint>> {
    let secret = key32(&config.secret_key)?;
    let mut cfg = match config.role {
        Role::Server => core::EndpointConfig::server(secret, config.port),
        Role::Client => core::EndpointConfig::client(secret),
    };
    cfg.port = config.port;
    cfg.relays = config.relays;
    cfg.portmapper = config.portmapper;
    cfg.rtc = config.rtc_port.map(|port| core::RtcConfig {
        port,
        stun_servers: config.rtc_stun_servers.clone(),
        external_only: config.rtc_external_only,
    });
    cfg.bind_ips = config
        .bind_ips
        .iter()
        .map(|s| s.parse::<IpAddr>().map_err(|_| invalid(format!("bind_ips: {s} is not an IP address"))))
        .collect::<Result<Vec<_>>>()?;
    if let Some(g) = config.guard {
        let exempt = g
            .exempt
            .iter()
            .map(|s| s.parse::<IpAddr>().map_err(|_| invalid(format!("guard exempt: {s} is not an IP address"))))
            .collect::<Result<Vec<_>>>()?;
        cfg.guard = core::GuardConfig {
            failure_limit: g.failure_limit,
            failure_window: Duration::from_millis(g.failure_window_ms),
            cooldown: Duration::from_millis(g.cooldown_ms),
            max_sessions: g.max_sessions as usize,
            max_unauthenticated: g.max_unauthenticated as usize,
            exempt,
            exempt_loopback: true,
        };
    }
    on_runtime(async move {
        let ep = core::Endpoint::bind(cfg).await?;
        Ok(Arc::new(LinkEndpoint { inner: ep }))
    })
    .await
}

#[uniffi::export]
impl LinkEndpoint {
    /// hex of the link public key.
    pub fn id(&self) -> String {
        self.inner.id()
    }

    /// An `ip:port` the endpoint is reachable on that it can't see itself (the app's router port mapping):
    /// advertised with its own addresses (`addr_info().direct`) until `remove_external_addr`.
    pub async fn add_external_addr(&self, addr: String) -> Result<()> {
        let a = addr.parse::<SocketAddr>().map_err(|_| invalid(format!("{addr} is not ip:port")))?;
        let ep = self.inner.clone();
        on_runtime(async move {
            ep.add_external_addr(a).await;
            Ok(())
        })
        .await
    }

    /// Takes back an `add_external_addr` address; false if it wasn't there.
    pub async fn remove_external_addr(&self, addr: String) -> Result<bool> {
        let a = addr.parse::<SocketAddr>().map_err(|_| invalid(format!("{addr} is not ip:port")))?;
        let ep = self.inner.clone();
        on_runtime(async move { Ok(ep.remove_external_addr(a).await) }).await
    }

    pub fn port(&self) -> u16 {
        self.inner.port()
    }

    /// The rtc UDP port; nil without rtc.
    pub fn rtc_port(&self) -> Option<u16> {
        self.inner.rtc_port()
    }

    /// The rtc port's router mapping (`ip:port`): rtc answers offer it until `remove_rtc_external_addr`. False
    /// without rtc.
    pub fn add_rtc_external_addr(&self, addr: String) -> Result<bool> {
        let a = addr.parse::<SocketAddr>().map_err(|_| invalid(format!("{addr} is not ip:port")))?;
        Ok(self.inner.add_rtc_external_addr(a))
    }

    /// Takes back an `add_rtc_external_addr` address; false if it wasn't there.
    pub fn remove_rtc_external_addr(&self, addr: String) -> Result<bool> {
        let a = addr.parse::<SocketAddr>().map_err(|_| invalid(format!("{addr} is not ip:port")))?;
        Ok(self.inner.remove_rtc_external_addr(a))
    }

    pub fn addr_info(&self) -> AddrInfo {
        self.inner.addr_info().into()
    }

    /// Calls `observer.on_addr` now and at every change of the address info, until the endpoint is closed.
    pub fn watch_addr(&self, observer: Arc<dyn AddrObserver>) {
        let mut stream = self.inner.watch_addr_info();
        core::runtime::runtime().spawn(async move {
            while let Some(a) = stream.next().await {
                let o = observer.clone();
                if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| o.on_addr(a.into()))).is_err() {
                    break;
                }
            }
        });
    }

    /// The identity's binding over this endpoint's key (97-byte X9.63 identity private key).
    pub fn binding(&self, identity_key: Vec<u8>) -> Result<Binding> {
        guarded(|| Ok(self.inner.binding(&identity_key)?.into()))
    }

    /// The network changed (call on every path-monitor update); `iface` = the interface now in use.
    pub async fn network_changed(&self, iface: Option<Iface>) {
        let ep = self.inner.clone();
        let _ = on_runtime(async move {
            ep.network_changed(iface.map(Into::into)).await;
            Ok(())
        })
        .await;
    }

    /// Dials a server and runs the handshake. `connect_timeout_ms`: nil = 10 s.
    pub async fn dial(
        &self,
        target: DialTarget,
        hello: Hello,
        connect_timeout_ms: Option<u64>,
    ) -> Result<Arc<LinkSession>> {
        let ep = self.inner.clone();
        on_runtime(async move {
            let mut opts = core::DialOptions::default();
            if let Some(ms) = connect_timeout_ms {
                opts.connect_timeout = Duration::from_millis(ms);
            }
            let t = core::DialTarget { id: target.id, relays: target.relays, direct: target.direct };
            let s = ep.dial(&t, &hello.into(), &opts).await?;
            Ok(Arc::new(LinkSession { inner: s }))
        })
        .await
    }

    /// Dials a server over WebRTC the way a browser does (docs/LINK.md「WebRTC」): `signaler` carries the offer to the
    /// server's `accept_rtc_offer`; the answer is checked against the pinned identity `fingerprint`. Needs `rtc_port`.
    pub async fn dial_rtc(
        &self,
        signaler: Arc<dyn RtcSignaler>,
        fingerprint: String,
        hello: Hello,
        connect_timeout_ms: Option<u64>,
    ) -> Result<Arc<LinkSession>> {
        let ep = self.inner.clone();
        on_runtime(async move {
            let mut opts = core::DialOptions::default();
            if let Some(ms) = connect_timeout_ms {
                opts.connect_timeout = Duration::from_millis(ms);
            }
            let signal = |offer: String| async move {
                let (tx, rx) = oneshot::channel();
                let reply = Arc::new(SignalReply { tx: Mutex::new(Some(tx)) });
                if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| signaler.signal(offer, reply))).is_err() {
                    return Err(core::LinkError::Connect("signaler failed".into()));
                }
                match rx.await {
                    Ok(Ok(a)) => Ok(a),
                    Ok(Err(m)) => Err(core::LinkError::Connect(format!("signal: {m}"))),
                    Err(_) => Err(core::LinkError::Connect("signal: no answer".into())),
                }
            };
            let s = ep.dial_rtc(signal, &fingerprint, &hello.into(), &opts).await?;
            Ok(Arc::new(LinkSession { inner: s }))
        })
        .await
    }

    /// Starts accepting sessions (server endpoints, once).
    pub fn listen(
        &self,
        settings: ServerSettings,
        authenticator: Arc<dyn Authenticator>,
        rpc: Option<Arc<dyn RpcHandler>>,
    ) -> Result<Arc<LinkListener>> {
        let s = settings.server;
        let mut opts = core::ServerOptions::new(
            core::ServerInfo { id: s.id, name: s.name, platform: s.platform },
            Arc::new(ForeignAuthenticator(authenticator)),
        );
        opts.features = settings.features;
        if let Some(p) = settings.rpc_blocked_paths {
            opts.rpc_blocked_paths = p;
        }
        if let Some(m) = settings.max_request_body {
            opts.max_request_body = m as usize;
        }
        opts.media.video.recovery_on_nack = settings.recovery_on_nack;
        if let Some(k) = settings.identity_key {
            opts.rtc_identity = Some(Arc::new(guarded(|| Ok(core::IdentityKey::new(&k)?))?));
        }
        opts.rpc = rpc.map(|r| Arc::new(ForeignRpc(r)) as Arc<dyn core::RpcHandler>);
        let ep = self.inner.clone();
        let _enter = core::runtime::runtime().enter();
        let listener = guarded(|| Ok(ep.listen(opts)?))?;
        Ok(Arc::new(LinkListener { inner: Arc::new(listener) }))
    }

    pub async fn close(&self) {
        let ep = self.inner.clone();
        let _ = on_runtime(async move {
            ep.close().await;
            Ok(())
        })
        .await;
    }
}

#[derive(uniffi::Object)]
pub struct LinkListener {
    inner: Arc<core::Listener>,
}

#[uniffi::export]
impl LinkListener {
    /// The next authenticated session; nil once the endpoint is closed.
    pub async fn accept(&self) -> Option<Arc<LinkSession>> {
        let l = self.inner.clone();
        on_runtime(async move { Ok(l.accept().await.map(|s| Arc::new(LinkSession { inner: s }))) }).await.ok().flatten()
    }

    /// A browser's WebRTC offer (`{"v":1,"offer","device"}`) → the signed answer JSON (docs/LINK.md「WebRTC」); the
    /// session comes out of `accept` once it connected and said hello. `source_ip`: the signaling request's address
    /// when known (the guard counts its failures). Errors: `InvalidArgument` (no rtc / identity, bad offer),
    /// `Denied` (`RateLimited`: the source is blocked; `Busy`: too many sessions or pending offers).
    pub async fn accept_rtc_offer(&self, offer_json: String, source_ip: Option<String>) -> Result<String> {
        let ip = match source_ip {
            Some(s) => Some(s.parse::<IpAddr>().map_err(|_| invalid(format!("source_ip: {s} is not an IP address")))?),
            None => None,
        };
        let l = self.inner.clone();
        on_runtime(async move { Ok(l.accept_rtc_offer(&offer_json, ip).await?) }).await
    }
}

// MARK: session

#[derive(uniffi::Object)]
pub struct LinkSession {
    inner: core::Session,
}

#[uniffi::export]
impl LinkSession {
    pub fn id(&self) -> u64 {
        self.inner.id()
    }

    pub fn is_server(&self) -> bool {
        self.inner.side() == core::Side::Server
    }

    /// hex of the other side's link public key (an rtc client: `dtls-sha256:<hex>` of its DTLS certificate).
    pub fn remote_id(&self) -> String {
        self.inner.remote_id().to_string()
    }

    /// QUIC or WebRTC.
    pub fn transport(&self) -> Transport {
        self.inner.transport().into()
    }

    pub fn hello(&self) -> Hello {
        self.inner.hello().into()
    }

    pub fn welcome(&self) -> Welcome {
        self.inner.welcome().into()
    }

    /// Sends a control message (JSON text of an object with a string `t`).
    pub async fn send_control(&self, json: String) -> Result<()> {
        let v: serde_json::Value = serde_json::from_str(&json).map_err(|e| invalid(format!("control message: {e}")))?;
        let s = self.inner.clone();
        on_runtime(async move { Ok(s.send_control(&v).await?) }).await
    }

    /// The next control message (JSON text); nil once the session ended.
    pub async fn recv_control(&self) -> Option<String> {
        let s = self.inner.clone();
        on_runtime(async move { Ok(s.recv_control().await.map(|v| v.to_string())) }).await.ok().flatten()
    }

    /// One RPC request; the response's body streams (`RpcResponse.chunk`).
    pub async fn request(&self, request: RpcRequest, body: Vec<u8>) -> Result<Arc<RpcResponse>> {
        let s = self.inner.clone();
        on_runtime(async move {
            let req = core::RpcRequest {
                method: request.method,
                path: request.path,
                headers: request.headers.into_iter().map(|(k, v)| (k.to_ascii_lowercase(), v)).collect(),
            };
            let r = s.request(&req, &body).await?;
            Ok(Arc::new(RpcResponse {
                status: r.status,
                headers: r.headers.into_iter().collect(),
                body: Arc::new(tokio::sync::Mutex::new(r.body)),
            }))
        })
        .await
    }

    /// Sends `channel << 4 | 1` then `payload`.
    pub fn send_datagram(&self, channel: u8, payload: Vec<u8>) -> Result<()> {
        Ok(self.inner.send_datagram(channel, &payload)?)
    }

    /// Sends a whole datagram (byte 0 already the header).
    pub fn send_datagram_raw(&self, datagram: Vec<u8>) -> Result<()> {
        Ok(self.inner.send_datagram_raw(Bytes::from(datagram))?)
    }

    /// The next datagram of `channel`, whole (byte 0 = header); nil once the session ended.
    pub async fn recv_datagram(&self, channel: u8) -> Result<Option<Vec<u8>>> {
        let s = self.inner.clone();
        on_runtime(async move { Ok(s.recv_datagram(channel).await?.map(|b| b.to_vec())) }).await
    }

    pub fn max_datagram_size(&self) -> u32 {
        self.inner.max_datagram_size() as u32
    }

    /// Bits per second that every path's congestion window follows.
    pub fn target_bitrate(&self) -> u64 {
        self.inner.target_bitrate().get()
    }

    pub fn set_target_bitrate(&self, bps: u64) {
        self.inner.target_bitrate().set(bps)
    }

    pub fn path(&self) -> PathInfo {
        self.inner.path().into()
    }

    pub fn stats(&self) -> LinkStats {
        self.inner.stats().into()
    }

    pub fn peer_stats(&self) -> Option<LinkStats> {
        self.inner.peer_stats().map(Into::into)
    }

    /// Client: the speed test (docs/LINK.md「测速」): the server sends filler frames through this session's video
    /// path for `duration_ms` (it keeps it within 1000–20000; 8000 is a good one) and the report says what a picture
    /// would get. Run it on a session that shows no picture (open streams share the rate). A server without it:
    /// `Timeout` after 3 s. Cancelling the task stops it.
    pub async fn probe(&self, duration_ms: u64) -> Result<ProbeReport> {
        let s = self.inner.clone();
        // a cancelled Swift task drops this future: the spawned test goes with it (its drop stops the server)
        let task = core::runtime::runtime().spawn(async move { s.probe(Duration::from_millis(duration_ms)).await });
        struct AbortOnDrop(tokio::task::AbortHandle);
        impl Drop for AbortOnDrop {
            fn drop(&mut self) {
                self.0.abort();
            }
        }
        let _abort = AbortOnDrop(task.abort_handle());
        match task.await {
            Ok(r) => r.map(Into::into).map_err(Into::into),
            Err(e) if e.is_panic() => Err(LinkError::Internal { message: panic_message(e.into_panic()) }),
            Err(e) => Err(LinkError::Internal { message: e.to_string() }),
        }
    }

    pub fn set_media_stats(&self, stats: MediaStats) {
        self.inner.set_media_stats(stats.into())
    }

    /// Sends `bye` and closes with `code` (0 normal … 6 replaced).
    pub async fn close(&self, code: u64, reason: String) {
        let s = self.inner.clone();
        let _ = on_runtime(async move {
            s.close(core::CloseCode::from_code(code), &reason).await;
            Ok(())
        })
        .await;
    }

    pub fn is_closed(&self) -> bool {
        self.inner.is_closed()
    }

    /// Waits for the end of the session.
    pub async fn closed(&self) -> CloseInfo {
        let s = self.inner.clone();
        on_runtime(async move { Ok(s.closed().await.into()) }).await.unwrap_or(CloseInfo {
            code: None,
            reason: "internal".into(),
            remote: false,
            description: "internal".into(),
        })
    }
}

// MARK: media (channels 1–5)

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Codec {
    H264,
    Hevc,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FrameKind {
    Delta,
    Key,
    Refine,
    Keepalive,
    Recovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum InputKind {
    /// down / up / click / key / text / scroll: exactly once, in order
    Discrete,
    /// pointer moves (drags too): latest wins
    Move,
}

/// The frame meta in front of every access unit (`au_len` is filled in by `send_frame`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FrameMeta {
    pub codec: Codec,
    pub kind: FrameKind,
    pub width: u16,
    pub height: u16,
    /// Capture time, µs since the Unix epoch (latency stats only).
    pub capture_us: u64,
    /// Recovery frames: the frame they reference (0 = none).
    pub recovery_base: u32,
    pub au_len: u32,
}

impl From<FrameMeta> for media::FrameMeta {
    fn from(m: FrameMeta) -> Self {
        media::FrameMeta {
            codec: match m.codec {
                Codec::H264 => media::Codec::H264,
                Codec::Hevc => media::Codec::Hevc,
            },
            kind: match m.kind {
                FrameKind::Delta => media::FrameKind::Delta,
                FrameKind::Key => media::FrameKind::Key,
                FrameKind::Refine => media::FrameKind::Refine,
                FrameKind::Keepalive => media::FrameKind::Keepalive,
                FrameKind::Recovery => media::FrameKind::Recovery,
            },
            width: m.width,
            height: m.height,
            capture_us: m.capture_us,
            recovery_base: m.recovery_base,
            au_len: m.au_len,
        }
    }
}

impl From<media::FrameMeta> for FrameMeta {
    fn from(m: media::FrameMeta) -> Self {
        FrameMeta {
            codec: match m.codec {
                media::Codec::H264 => Codec::H264,
                media::Codec::Hevc => Codec::Hevc,
            },
            kind: match m.kind {
                media::FrameKind::Delta => FrameKind::Delta,
                media::FrameKind::Key => FrameKind::Key,
                media::FrameKind::Refine => FrameKind::Refine,
                media::FrameKind::Keepalive => FrameKind::Keepalive,
                media::FrameKind::Recovery => FrameKind::Recovery,
            },
            width: m.width,
            height: m.height,
            capture_us: m.capture_us,
            recovery_base: m.recovery_base,
            au_len: m.au_len,
        }
    }
}

fn input_kind(k: InputKind) -> media::InputKind {
    match k {
        InputKind::Discrete => media::InputKind::Discrete,
        InputKind::Move => media::InputKind::Move,
    }
}

/// A frame for the decoder: in order, its reference chain intact. Answer with `frame_decoded`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VideoFrame {
    pub stream: u8,
    pub frame: u32,
    pub meta: FrameMeta,
    /// The Annex-B access unit.
    pub au: Vec<u8>,
    /// Session clock (µs) when its first shard arrived / when it was complete.
    pub first_arrival_us: u64,
    pub delivered_at_us: u64,
}

/// An Opus packet for the jitter buffer (`gap_before` packets are missing before it).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AudioPacket {
    pub stream: u8,
    pub aseq: u32,
    pub time_us: u64,
    pub data: Vec<u8>,
    pub recovered: bool,
    pub gap_before: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct InputEvent {
    pub seq: u32,
    pub kind: InputKind,
    /// The `/input` JSON body.
    pub json: Vec<u8>,
}

/// Why `can_send_frame` says what it says (bytes, bits/s).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SendGate {
    pub open: bool,
    /// Closed: the bytes waiting exceed `limit`.
    pub over_queue: bool,
    /// Closed: the transport's free buffer can't hold `estimate`.
    pub over_space: bool,
    pub own_queued: u64,
    pub transport_queued: u64,
    pub transport_space: Option<u64>,
    pub budget: u64,
    pub limit: u64,
    pub estimate: u64,
    pub target_bps: u64,
    pub pacing_bps: u64,
}

impl From<media::SendGate> for SendGate {
    fn from(g: media::SendGate) -> Self {
        SendGate {
            open: g.open,
            over_queue: g.over_queue,
            over_space: g.over_space,
            own_queued: g.own_queued,
            transport_queued: g.transport_queued,
            transport_space: g.transport_space,
            budget: g.budget,
            limit: g.limit,
            estimate: g.estimate,
            target_bps: g.target_bps,
            pacing_bps: g.pacing_bps,
        }
    }
}

/// One sent video frame's way out (server; session clock µs).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TxTrace {
    pub stream: u8,
    pub frame: u32,
    /// `FrameKind`'s wire value (0 delta, 1 key, 2 refine, 3 keepalive, 4 recovery).
    pub kind: u8,
    pub au_bytes: u32,
    pub wire_bytes: u32,
    pub datagrams: u16,
    pub parity: u16,
    pub enqueued_us: u64,
    pub queued_ahead: u32,
    pub first_out_us: Option<u64>,
    pub last_out_us: Option<u64>,
    pub retransmits: u16,
    /// When a frame report said it was decoded OK.
    pub delivered_us: Option<u64>,
    pub lost: bool,
    pub target_bps: u64,
    pub pacing_bps: u64,
    pub fec_ratio: f32,
    pub queue_delay_us: Option<u64>,
    pub rtt_us: Option<u64>,
}

impl From<media::TxTrace> for TxTrace {
    fn from(t: media::TxTrace) -> Self {
        TxTrace {
            stream: t.stream,
            frame: t.frame,
            kind: t.kind,
            au_bytes: t.au_bytes,
            wire_bytes: t.wire_bytes,
            datagrams: t.datagrams,
            parity: t.parity,
            enqueued_us: t.enqueued_at.0,
            queued_ahead: t.queued_ahead,
            first_out_us: t.first_out.map(|m| m.0),
            last_out_us: t.last_out.map(|m| m.0),
            retransmits: t.retransmits,
            delivered_us: t.delivered_at.map(|m| m.0),
            lost: t.lost,
            target_bps: t.target_bps,
            pacing_bps: t.pacing_bps,
            fec_ratio: t.fec_ratio,
            queue_delay_us: t.queue_delay_us,
            rtt_us: t.rtt_us,
        }
    }
}

/// How a frame ended on the client.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RxFate {
    Delivered,
    Skipped,
    Lost,
}

/// One frame on the client, first shard to fate (session clock µs).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RxTrace {
    pub stream: u8,
    pub frame: u32,
    pub fate: RxFate,
    pub kind: Option<u8>,
    pub au_bytes: u32,
    /// The server's capture time (µs since 1970, its clock).
    pub capture_us: Option<u64>,
    pub first_arrival_us: Option<u64>,
    pub last_arrival_us: Option<u64>,
    pub completed_us: Option<u64>,
    pub decided_us: u64,
    pub shards: u16,
    pub fec: u16,
    pub retx: u16,
    pub nack_items: u16,
}

impl From<media::RxTrace> for RxTrace {
    fn from(t: media::RxTrace) -> Self {
        RxTrace {
            stream: t.stream,
            frame: t.frame,
            fate: match t.fate {
                media::RxFate::Delivered => RxFate::Delivered,
                media::RxFate::Skipped => RxFate::Skipped,
                media::RxFate::Lost => RxFate::Lost,
            },
            kind: t.kind,
            au_bytes: t.au_bytes,
            capture_us: t.capture_us,
            first_arrival_us: t.first_arrival.map(|m| m.0),
            last_arrival_us: t.last_arrival.map(|m| m.0),
            completed_us: t.completed_at.map(|m| m.0),
            decided_us: t.decided_at.0,
            shards: t.shards,
            fec: t.fec,
            retx: t.retx,
            nack_items: t.nack_items,
        }
    }
}

/// What the server's media layer reports.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ServerMediaEvent {
    /// Set the encoder to `encoder_bps` (per video stream).
    TargetBitrate {
        target_bps: u64,
        encoder_bps: u64,
    },
    /// The client decoded `frame` (LTR acknowledgement).
    FrameDelivered {
        stream: u8,
        frame: u32,
    },
    /// Next frame: a recovery frame on the newest acknowledged LTR, or a key frame.
    RecoveryNeeded {
        stream: u8,
        last_delivered: Option<u32>,
    },
    KeyframeNeeded {
        stream: u8,
    },
    Input {
        event: InputEvent,
    },
}

impl From<media::ServerEvent> for ServerMediaEvent {
    fn from(e: media::ServerEvent) -> Self {
        match e {
            media::ServerEvent::TargetBitrate { target_bps, encoder_bps } => {
                ServerMediaEvent::TargetBitrate { target_bps, encoder_bps }
            }
            media::ServerEvent::FrameDelivered { stream, frame } => ServerMediaEvent::FrameDelivered { stream, frame },
            media::ServerEvent::RecoveryNeeded { stream, last_delivered } => {
                ServerMediaEvent::RecoveryNeeded { stream, last_delivered }
            }
            media::ServerEvent::KeyframeNeeded { stream } => ServerMediaEvent::KeyframeNeeded { stream },
            media::ServerEvent::Input(i) => ServerMediaEvent::Input {
                event: InputEvent {
                    seq: i.seq,
                    kind: match i.kind {
                        media::InputKind::Discrete => InputKind::Discrete,
                        media::InputKind::Move => InputKind::Move,
                    },
                    json: i.json,
                },
            },
        }
    }
}

/// What the client's media layer delivers.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ClientMediaEvent {
    Frame {
        frame: VideoFrame,
    },
    Audio {
        packet: AudioPacket,
    },
    /// A newer cursor position (JSON `{x,y,visible,shapeId}`).
    Cursor {
        stream: u8,
        cseq: u32,
        json: Vec<u8>,
    },
    /// Every discrete input event up to `through` arrived.
    InputAcked {
        through: u32,
    },
    /// A discrete input event was not acknowledged within 2 s and was dropped.
    InputFailed {
        seq: u32,
    },
}

impl From<media::ClientEvent> for ClientMediaEvent {
    fn from(e: media::ClientEvent) -> Self {
        match e {
            media::ClientEvent::Frame(f) => ClientMediaEvent::Frame {
                frame: VideoFrame {
                    stream: f.stream,
                    frame: f.frame,
                    meta: f.meta.into(),
                    au: f.au,
                    first_arrival_us: f.first_arrival.0,
                    delivered_at_us: f.delivered_at.0,
                },
            },
            media::ClientEvent::Audio(a) => ClientMediaEvent::Audio {
                packet: AudioPacket {
                    stream: a.stream,
                    aseq: a.aseq,
                    time_us: a.time_us,
                    data: a.data,
                    recovered: a.recovered,
                    gap_before: a.gap_before,
                },
            },
            media::ClientEvent::Cursor { stream, cseq, json } => ClientMediaEvent::Cursor { stream, cseq, json },
            media::ClientEvent::InputAcked { through } => ClientMediaEvent::InputAcked { through },
            media::ClientEvent::InputFailed { seq } => ClientMediaEvent::InputFailed { seq },
        }
    }
}

#[uniffi::export]
impl LinkSession {
    /// Opens video stream `stream` (server: per `video.open`; client: per `video.opened`).
    pub fn open_video(&self, stream: u8) {
        self.inner.open_video(stream)
    }

    pub fn close_video(&self, stream: u8) {
        self.inner.close_video(stream)
    }

    pub fn open_audio(&self, stream: u8) {
        self.inner.open_audio(stream)
    }

    pub fn close_audio(&self, stream: u8) {
        self.inner.close_audio(stream)
    }

    /// Server: whether to encode the next picture now (false: skip it).
    pub fn can_send_frame(&self, stream: u8) -> Result<bool> {
        Ok(self.inner.can_send_frame(stream)?)
    }

    /// Server: `can_send_frame` with its numbers (nil: no such stream).
    pub fn send_gate(&self, stream: u8) -> Result<Option<SendGate>> {
        Ok(self.inner.send_gate(stream)?.map(Into::into))
    }

    /// Server: the per-frame traces finished since the last call.
    pub fn take_tx_traces(&self) -> Result<Vec<TxTrace>> {
        Ok(self.inner.take_tx_traces()?.into_iter().map(Into::into).collect())
    }

    /// Client: every frame's fate since the last call.
    pub fn take_rx_traces(&self) -> Result<Vec<RxTrace>> {
        Ok(self.inner.take_rx_traces()?.into_iter().map(Into::into).collect())
    }

    /// The session clock now (µs): the traces' times.
    pub fn media_now_us(&self) -> u64 {
        self.inner.media_now_us()
    }

    /// Server: one encoded frame; returns its frame number.
    pub fn send_frame(&self, stream: u8, meta: FrameMeta, au: Vec<u8>) -> Result<u32> {
        Ok(self.inner.send_frame(stream, meta.into(), &au)?)
    }

    /// Server: one Opus packet; returns its aseq.
    pub fn send_audio(&self, stream: u8, time_us: u64, opus: Vec<u8>) -> Result<u32> {
        Ok(self.inner.send_audio(stream, time_us, &opus)?)
    }

    /// Server: the newest cursor position (JSON).
    pub fn send_cursor(&self, stream: u8, json: Vec<u8>) -> Result<()> {
        Ok(self.inner.send_cursor(stream, &json)?)
    }

    /// Server: force a key frame next; client: ask for one.
    pub fn request_keyframe(&self, stream: u8) {
        self.inner.request_keyframe(stream)
    }

    /// Server: the next media event; nil once the session ended.
    pub async fn next_server_event(&self) -> Option<ServerMediaEvent> {
        let s = self.inner.clone();
        on_runtime(async move { Ok(s.recv_server_event().await.map(Into::into)) }).await.ok().flatten()
    }

    /// Client: one input event (`/input` JSON); returns its seq. A `Media` error with "Overflow" is a local 429.
    pub fn send_input(&self, kind: InputKind, json: Vec<u8>) -> Result<u32> {
        Ok(self.inner.send_input(input_kind(kind), &json)?)
    }

    /// Client: the decoder took (`ok`) or failed on a frame.
    pub fn frame_decoded(&self, stream: u8, frame: u32, ok: bool) -> Result<()> {
        Ok(self.inner.frame_decoded(stream, frame, ok)?)
    }

    /// Client: the next media event; nil once the session ended.
    pub async fn next_client_event(&self) -> Option<ClientMediaEvent> {
        let s = self.inner.clone();
        on_runtime(async move { Ok(s.recv_client_event().await.map(Into::into)) }).await.ok().flatten()
    }
}

// MARK: RPC objects

#[derive(uniffi::Object)]
pub struct RpcResponse {
    status: u16,
    headers: HashMap<String, String>,
    body: Arc<tokio::sync::Mutex<core::RpcBody>>,
}

#[uniffi::export]
impl RpcResponse {
    pub fn status(&self) -> u16 {
        self.status
    }

    pub fn headers(&self) -> HashMap<String, String> {
        self.headers.clone()
    }

    /// The next piece of the body; nil at its end.
    pub async fn chunk(&self) -> Result<Option<Vec<u8>>> {
        let b = self.body.clone();
        on_runtime(async move { Ok(b.lock().await.chunk().await?.map(|c| c.to_vec())) }).await
    }

    /// The rest of the body (at most `limit` bytes).
    pub async fn read_all(&self, limit: u64) -> Result<Vec<u8>> {
        let b = self.body.clone();
        on_runtime(async move { Ok(b.lock().await.read_all(limit as usize).await?.to_vec()) }).await
    }

    /// Stops reading (a streamed response ends).
    pub fn cancel(&self) {
        if let Ok(mut b) = self.body.try_lock() {
            b.cancel();
        } else {
            let b = self.body.clone();
            core::runtime::runtime().spawn(async move { b.lock().await.cancel() });
        }
    }
}

#[derive(uniffi::Object)]
pub struct RpcResponder {
    inner: tokio::sync::Mutex<Option<core::RpcResponder>>,
}

fn finished() -> LinkError {
    LinkError::Closed { message: "response already finished".into() }
}

fn lower_headers(headers: HashMap<String, String>) -> core::Headers {
    headers.into_iter().map(|(k, v)| (k.to_ascii_lowercase(), v)).collect()
}

#[uniffi::export]
impl RpcResponder {
    pub async fn head(self: Arc<Self>, status: u16, headers: HashMap<String, String>) -> Result<()> {
        on_runtime(async move {
            let mut g = self.inner.lock().await;
            Ok(g.as_mut().ok_or_else(finished)?.head(status, &lower_headers(headers)).await?)
        })
        .await
    }

    pub async fn write(self: Arc<Self>, data: Vec<u8>) -> Result<()> {
        on_runtime(async move {
            let mut g = self.inner.lock().await;
            Ok(g.as_mut().ok_or_else(finished)?.write(&data).await?)
        })
        .await
    }

    /// Ends the body (a 200 head first if none was sent).
    pub async fn finish(self: Arc<Self>) -> Result<()> {
        on_runtime(async move {
            let mut g = self.inner.lock().await;
            let mut r = g.take().ok_or_else(finished)?;
            Ok(r.finish().await?)
        })
        .await
    }

    /// Head, body, finish.
    pub async fn respond(self: Arc<Self>, status: u16, headers: HashMap<String, String>, body: Vec<u8>) -> Result<()> {
        on_runtime(async move {
            let mut g = self.inner.lock().await;
            let mut r = g.take().ok_or_else(finished)?;
            Ok(r.respond(status, &lower_headers(headers), &body).await?)
        })
        .await
    }

    /// Resolves when the client stopped reading (cancelled) or the session ended.
    pub async fn stopped(self: Arc<Self>) {
        let _ = on_runtime(async move {
            let f = self.inner.lock().await.as_ref().map(|r| r.stopped());
            if let Some(f) = f {
                f.await;
            }
            Ok(())
        })
        .await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Allow;
    impl Authenticator for Allow {
        fn authenticate(&self, request: AuthRequest, reply: Arc<AuthReply>) {
            // answer later, from another thread, like a Swift Task would
            std::thread::spawn(move || {
                if request.hello.credential == "Bearer ok" {
                    reply.accept(r#"{"who":"phone"}"#.into(), None).unwrap();
                    assert!(reply.deny(DenyCode::Busy, "twice".into()).is_err());
                } else {
                    reply.deny(DenyCode::Unauthorized, "no".into()).unwrap();
                }
            });
        }
    }

    struct Echo;
    impl RpcHandler for Echo {
        fn handle(&self, session: Arc<LinkSession>, request: RpcRequest, body: Vec<u8>, responder: Arc<RpcResponder>) {
            core::runtime::runtime().spawn(async move {
                let mut h = HashMap::new();
                h.insert("x-path".into(), request.path);
                h.insert("x-who".into(), session.welcome().principal_json);
                responder.respond(200, h, body).await.unwrap();
            });
        }
    }

    fn meta_key() -> FrameMeta {
        FrameMeta {
            codec: Codec::Hevc,
            kind: FrameKind::Key,
            width: 1,
            height: 1,
            capture_us: 0,
            recovery_base: 0,
            au_len: 0,
        }
    }

    fn hello(credential: &str) -> Hello {
        Hello {
            credential: credential.into(),
            device: DeviceInfo { id: "d1".into(), name: "iPhone".into() },
            app: AppInfo { name: "uu".into(), version: "1".into() },
            features: vec![],
        }
    }

    // Driven from a plain thread with a separate executor, as Swift drives the futures.
    #[test]
    fn end_to_end_through_the_ffi_types() {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async {
            let server = bind_endpoint(EndpointConfig {
                role: Role::Server,
                secret_key: generate_link_key(),
                port: 0,
                relays: vec![],
                portmapper: Some(false),
                guard: None,
                bind_ips: vec![],
                rtc_port: Some(0),
                rtc_stun_servers: vec![],
                rtc_external_only: false,
            })
            .await
            .unwrap();
            let listener = server
                .listen(
                    ServerSettings {
                        server: ServerInfo { id: "s".into(), name: "Mac".into(), platform: "macos".into() },
                        features: vec!["link".into()],
                        rpc_blocked_paths: None,
                        max_request_body: None,
                        recovery_on_nack: false,
                        identity_key: None,
                    },
                    Arc::new(Allow),
                    Some(Arc::new(Echo)),
                )
                .unwrap();
            let client = bind_endpoint(EndpointConfig {
                role: Role::Client,
                secret_key: generate_link_key(),
                port: 0,
                relays: vec![],
                portmapper: None,
                guard: None,
                bind_ips: vec![],
                rtc_port: None,
                rtc_stun_servers: vec![],
                rtc_external_only: false,
            })
            .await
            .unwrap();
            let target =
                DialTarget { id: server.id(), relays: vec![], direct: vec![format!("127.0.0.1:{}", server.port())] };
            // rtc: the socket is there, offers need the identity (none given here)
            assert!(server.rtc_port().is_some_and(|p| p > 0));
            assert!(client.rtc_port().is_none());
            assert!(server.add_rtc_external_addr("203.0.113.7:47821".into()).unwrap());
            assert!(server.remove_rtc_external_addr("203.0.113.7:47821".into()).unwrap());
            match listener.accept_rtc_offer(r#"{"v":1,"offer":"v=0"}"#.into(), Some("127.0.0.1".into())).await {
                Err(LinkError::InvalidArgument { .. }) => {}
                other => panic!("{:?}", other.map(|_| ())),
            }
            assert!(listener.accept_rtc_offer("{}".into(), Some("no-ip".into())).await.is_err());

            match client.dial(target.clone(), hello("Bearer nope"), None).await {
                Err(LinkError::Denied { code: DenyCode::Unauthorized, .. }) => {}
                Err(e) => panic!("{e}"),
                Ok(_) => panic!("expected denied"),
            }
            let c = client.dial(target, hello("Bearer ok"), None).await.unwrap();
            let s = listener.accept().await.unwrap();
            assert_eq!(c.welcome().principal_json, r#"{"who":"phone"}"#);
            assert!(s.is_server());
            assert_eq!(s.transport(), Transport::Quic);
            assert_eq!(s.remote_id().len(), 64);
            assert_eq!(c.remote_id(), server.id());

            let r = c
                .request(
                    RpcRequest { method: "POST".into(), path: "/x".into(), headers: HashMap::new() },
                    b"abc".to_vec(),
                )
                .await
                .unwrap();
            assert_eq!(r.status(), 200);
            assert_eq!(r.headers()["x-path"], "/x");
            assert_eq!(r.read_all(100).await.unwrap(), b"abc");

            c.send_control(r#"{"t":"keyframe","id":1}"#.into()).await.unwrap();
            assert_eq!(s.recv_control().await.unwrap(), r#"{"id":1,"t":"keyframe"}"#);
            assert!(c.send_control("[1]".into()).await.is_err());

            s.send_datagram(9, vec![1, 2, 3]).unwrap();
            assert_eq!(c.recv_datagram(9).await.unwrap().unwrap(), vec![0x91, 1, 2, 3]);

            // media: a frame through, its delivery back
            s.open_video(1);
            c.open_video(1);
            let meta = FrameMeta {
                codec: Codec::H264,
                kind: FrameKind::Key,
                width: 64,
                height: 64,
                capture_us: 0,
                recovery_base: 0,
                au_len: 0,
            };
            assert!(s.can_send_frame(1).unwrap());
            assert_eq!(s.send_frame(1, meta, vec![0, 0, 0, 1, 0x65, 7, 7, 7]).unwrap(), 1);
            loop {
                if let ClientMediaEvent::Frame { frame } = c.next_client_event().await.unwrap() {
                    assert_eq!(frame.au, vec![0, 0, 0, 1, 0x65, 7, 7, 7]);
                    assert_eq!(frame.meta.kind, FrameKind::Key);
                    c.frame_decoded(1, frame.frame, true).unwrap();
                    break;
                }
            }
            c.send_input(InputKind::Discrete, br#"{"type":"click"}"#.to_vec()).unwrap();
            let mut saw_input = false;
            let mut saw_delivered = false;
            while !(saw_input && saw_delivered) {
                match s.next_server_event().await.unwrap() {
                    ServerMediaEvent::Input { event } => saw_input = event.json == br#"{"type":"click"}"#,
                    ServerMediaEvent::FrameDelivered { frame, .. } => saw_delivered = frame == 1,
                    _ => {}
                }
            }
            assert!(matches!(c.send_frame(1, meta_key(), vec![1]), Err(LinkError::InvalidArgument { .. })));
            assert!(matches!(c.send_datagram(0, vec![]), Err(LinkError::InvalidArgument { .. })));

            c.set_target_bitrate(5_000_000);
            assert_eq!(c.target_bitrate(), 5_000_000);
            assert_eq!(c.path().kind, PathKind::Lan);
            assert!(c.stats().line.starts_with("lan "));

            s.close(6, "replaced".into()).await;
            let end = c.closed().await;
            assert_eq!(end.code, Some(6));
            assert!(end.remote);
            assert_eq!(close_code_name(6), "replaced");
            client.close().await;
            server.close().await;
        });
    }

    #[test]
    fn binding_helpers() {
        let secret = generate_link_key();
        let id = link_public_key(secret.clone()).unwrap();
        assert_eq!(id.len(), 64);
        assert!(link_public_key(vec![1, 2]).is_err());
        assert!(sign_binding(vec![4; 97], id.clone()).is_err());
        assert!(verify_binding(Binding { id, key: "x".into(), sig: "y".into() }, "sha256:00".into()).is_err());
    }
}
