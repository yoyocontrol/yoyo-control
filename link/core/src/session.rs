//! A session: one connection (QUIC or WebRTC, `transport`) after `hello` / `welcome`. Control messages both ways (JSON objects with `t`), RPC
//! requests (client → server), datagram channels, the path it runs on, its statistics.

use std::{
    collections::HashSet,
    net::SocketAddr,
    sync::{Arc, Mutex, OnceLock, Weak, atomic::Ordering},
    time::{Duration, Instant},
};

use bytes::Bytes;
use iroh::endpoint::{Connection, ConnectionError};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use tokio::sync::{mpsc, watch};

use crate::{
    cc::TargetBitrate,
    datagram::{self, Mux},
    error::{CloseCode, LinkError, Result},
    framing::{self, MAX_CONTROL_FRAME},
    guard::Permit,
    log::{debug, info},
    media::{self, ClientEvent, Driver, Engine, FrameMeta, InputKind, ServerEvent},
    path::{Iface, PathInfo, PathKind},
    probe::{self, ProbeReport},
    rpc::{self, RpcHandler, RpcRequest, RpcResponse, ServeConfig},
    stats::{MediaStats, RttWindow, StatsSnapshot},
    transport::{Conn, RecvHalf, SendHalf, Transport},
};

/// How often each side sends its `link.stats`.
pub const STATS_EVERY: Duration = Duration::from_secs(2);
/// How often the `link:` lines are logged.
pub const LOG_EVERY: Duration = Duration::from_secs(10);
/// RTT samples (stats, and the media layer's rate rules ~10 Hz).
const RTT_SAMPLE_EVERY: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Device {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppInfo {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub version: String,
}

/// The client's `hello` (without `t` / `v`).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Hello {
    /// Opaque to the link (`Bearer <token>` with the server's own device store).
    #[serde(default)]
    pub credential: String,
    #[serde(default)]
    pub device: Device,
    #[serde(default)]
    pub app: AppInfo,
    #[serde(default)]
    pub features: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerInfo {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub platform: String,
}

/// The server's `welcome` (without `t` / `v`).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Welcome {
    #[serde(default)]
    pub server: ServerInfo,
    /// Who the server says the client is (its authenticator's answer); opaque to the link.
    #[serde(default)]
    pub principal: Value,
    #[serde(default)]
    pub features: Vec<String>,
    #[serde(default)]
    pub max_datagram: u32,
}

fn tagged(v: impl Serialize, t: &str) -> Value {
    let mut v = serde_json::to_value(v).unwrap_or_default();
    if let Some(m) = v.as_object_mut() {
        m.insert("t".into(), t.into());
        m.insert("v".into(), 1.into());
    }
    v
}

pub(crate) fn hello_message(h: &Hello) -> Value {
    tagged(h, "hello")
}

pub(crate) fn welcome_message(w: &Welcome) -> Value {
    tagged(w, "welcome")
}

/// Who closed a session and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CloseInfo {
    /// The application close code; `None` for transport-level ends (idle timeout, reset, …).
    pub code: Option<CloseCode>,
    pub reason: String,
    /// The other side closed it.
    pub remote: bool,
}

impl CloseInfo {
    pub(crate) fn from_error(e: &ConnectionError, local: Option<&CloseInfo>) -> CloseInfo {
        match e {
            ConnectionError::ApplicationClosed(c) => CloseInfo {
                code: Some(CloseCode::from_code(c.error_code.into_inner())),
                reason: String::from_utf8_lossy(&c.reason).into_owned(),
                remote: true,
            },
            ConnectionError::LocallyClosed => local.cloned().unwrap_or(CloseInfo {
                code: Some(CloseCode::Normal),
                reason: String::new(),
                remote: false,
            }),
            ConnectionError::TimedOut => CloseInfo { code: None, reason: "timed out".into(), remote: false },
            ConnectionError::Reset => CloseInfo { code: None, reason: "reset".into(), remote: true },
            other => CloseInfo { code: None, reason: other.to_string(), remote: true },
        }
    }

    pub fn describe(&self) -> String {
        let who = if self.remote { "by peer" } else { "locally" };
        match self.code {
            Some(c) if self.reason.is_empty() => format!("{} {who}", c.name()),
            Some(c) => format!("{} {who}: {}", c.name(), self.reason),
            None => format!("{} ({who})", self.reason),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Client,
    Server,
}

/// One session. Cheap to clone (all clones are the same session). When the last clone is dropped the session is
/// closed (code 0); the background tasks don't keep it open.
#[derive(Clone)]
pub struct Session {
    inner: Arc<Inner>,
    _handle: Arc<Handle>,
}

impl std::fmt::Debug for Session {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session").field("id", &self.inner.id).field("side", &self.inner.side).finish()
    }
}

/// The app's hold on a session.
struct Handle {
    conn: Conn,
}

impl Drop for Handle {
    fn drop(&mut self) {
        if !self.conn.is_closed() {
            self.conn.close(CloseCode::Normal, "");
        }
    }
}

pub(crate) struct Inner {
    id: u64,
    pub(crate) side: Side,
    pub(crate) conn: Conn,
    remote_id: String,
    hello: Hello,
    welcome: Welcome,
    control_send: tokio::sync::Mutex<SendHalf>,
    control_recv: tokio::sync::Mutex<mpsc::UnboundedReceiver<Map<String, Value>>>,
    mux: Mux,
    target: TargetBitrate,
    path: watch::Sender<PathInfo>,
    known: HashSet<SocketAddr>,
    pub(crate) iface: Arc<Mutex<Iface>>,
    /// What the app said with `set_media_stats` (overrides the media layer's numbers field by field).
    media_override: Mutex<MediaStats>,
    pub(crate) media: Driver,
    peer_stats: Mutex<Option<StatsSnapshot>>,
    /// The media stats at the last `link:` line, own and the peer's: each line covers the interval since it.
    logged_media: Mutex<Option<crate::media::RawMediaStats>>,
    logged_peer: Mutex<Option<MediaStats>>,
    rtt: Mutex<RttWindow>,
    local_close: OnceLock<CloseInfo>,
    close_info: watch::Sender<Option<CloseInfo>>,
    started: Instant,
    permit: Mutex<Option<Permit>>,
    /// The client's running speed test hears its `link.probe.*` replies here.
    pub(crate) probe_waiter: Mutex<Option<mpsc::UnboundedSender<Map<String, Value>>>>,
    /// Keeps the sockets alive as long as the session.
    _endpoint: iroh::Endpoint,
}

pub(crate) struct Parts {
    pub id: u64,
    pub side: Side,
    pub conn: Conn,
    pub hello: Hello,
    pub welcome: Welcome,
    pub control_send: SendHalf,
    pub control_recv: RecvHalf,
    pub target: TargetBitrate,
    pub known: HashSet<SocketAddr>,
    pub iface: Arc<Mutex<Iface>>,
    pub permit: Option<Permit>,
    pub rpc: Option<(Arc<dyn RpcHandler>, Arc<ServeConfig>)>,
    pub media: Engine,
    pub endpoint: iroh::Endpoint,
}

impl Session {
    pub(crate) fn start(p: Parts) -> Session {
        let (ctl_tx, ctl_rx) = mpsc::unbounded_channel();
        let initial = p.conn.path(&p.known);
        let inner = Arc::new(Inner {
            id: p.id,
            side: p.side,
            remote_id: p.conn.remote_id(),
            conn: p.conn.clone(),
            hello: p.hello,
            welcome: p.welcome,
            control_send: tokio::sync::Mutex::new(p.control_send),
            control_recv: tokio::sync::Mutex::new(ctl_rx),
            mux: Mux::new(),
            target: p.target,
            path: watch::channel(initial).0,
            known: p.known,
            iface: p.iface,
            media_override: Mutex::new(MediaStats::default()),
            media: Driver::new(p.media),
            peer_stats: Mutex::new(None),
            logged_media: Mutex::new(None),
            logged_peer: Mutex::new(None),
            rtt: Mutex::new(RttWindow::new(LOG_EVERY)),
            local_close: OnceLock::new(),
            close_info: watch::channel(None).0,
            started: Instant::now(),
            permit: Mutex::new(p.permit),
            probe_waiter: Mutex::new(None),
            _endpoint: p.endpoint,
        });
        let handle = Arc::new(Handle { conn: p.conn });
        match inner.conn.transport() {
            Transport::Quic => info!("link session opened {} {}", inner.peer_name(), inner.path().kind),
            Transport::Rtc => info!("link session opened {} {} (rtc)", inner.peer_name(), inner.path().kind),
        }
        tokio::spawn(control_reader(inner.clone(), p.control_recv, ctl_tx));
        tokio::spawn(datagram_reader(inner.clone()));
        if let Some((handler, config)) = p.rpc {
            tokio::spawn(rpc_acceptor(inner.clone(), Arc::downgrade(&handle), handler, config));
        }
        tokio::spawn(monitor(inner.clone()));
        let m = inner.clone();
        tokio::spawn(async move { media::run(&m.media, &m.conn, &m.mux.counters).await });
        Session { inner, _handle: handle }
    }

    pub fn id(&self) -> u64 {
        self.inner.id
    }

    pub fn side(&self) -> Side {
        self.inner.side
    }

    /// The other side's endpoint id (hex of its link public key). On a server: the client key a device token is
    /// bound to (`rtc`: `dtls-sha256:<hex>` of the browser's DTLS certificate, docs/LINK.md「WebRTC」).
    pub fn remote_id(&self) -> &str {
        &self.inner.remote_id
    }

    /// The client's `hello` (on both sides).
    pub fn hello(&self) -> &Hello {
        &self.inner.hello
    }

    /// The server's `welcome` (on both sides).
    pub fn welcome(&self) -> &Welcome {
        &self.inner.welcome
    }

    pub fn principal(&self) -> &Value {
        &self.inner.welcome.principal
    }

    /// Which transport the session runs on.
    pub fn transport(&self) -> Transport {
        self.inner.conn.transport()
    }

    /// The underlying QUIC connection (`None` on `rtc`).
    pub fn connection(&self) -> Option<&Connection> {
        self.inner.conn.quic()
    }

    // MARK: control

    /// Sends a control message: a JSON object with a string `t` (not one of the handshake's).
    pub async fn send_control(&self, msg: &Value) -> Result<()> {
        let t = msg
            .get("t")
            .and_then(Value::as_str)
            .ok_or_else(|| LinkError::InvalidArgument("a control message is a JSON object with a string t".into()))?;
        if matches!(t, "hello" | "welcome" | "denied") {
            return Err(LinkError::InvalidArgument(format!("{t} is the handshake's")));
        }
        self.inner.write_control(msg).await
    }

    /// The next control message from the other side; `None` once the session ended. `link.stats` is kept by the
    /// session (`peer_stats`), not delivered here.
    pub async fn recv_control(&self) -> Option<Value> {
        self.inner.control_recv.lock().await.recv().await.map(Value::Object)
    }

    // MARK: RPC

    /// One request (client side). The response's body streams; drop or `cancel` it to stop.
    pub async fn request(&self, req: &RpcRequest, body: &[u8]) -> Result<RpcResponse> {
        if self.inner.side != Side::Client {
            return Err(LinkError::InvalidArgument("only the client sends requests".into()));
        }
        rpc::request(&self.inner.conn, req, body).await
    }

    // MARK: datagrams

    /// Sends `header(channel) ‖ payload`. Older unsent datagrams may be dropped to make room (newest wins).
    pub fn send_datagram(&self, channel: u8, payload: &[u8]) -> Result<()> {
        datagram::check_channel(channel)?;
        self.send_datagram_raw(datagram::frame(channel, payload))
    }

    /// Sends a whole datagram whose byte 0 is already the header.
    pub fn send_datagram_raw(&self, datagram: Bytes) -> Result<()> {
        if datagram::parse_header(&datagram).is_none() {
            return Err(LinkError::InvalidArgument("datagram header is not channel << 4 | 1".into()));
        }
        let c = &self.inner.mux.counters;
        let conn = &self.inner.conn;
        if conn.datagram_send_buffer_space() < datagram.len() {
            c.drop_one(); // an older one gives way
        }
        match conn.send_datagram(datagram) {
            Ok(()) => {
                c.sent.fetch_add(1, Ordering::Relaxed);
                Ok(())
            }
            Err(e) => {
                c.drop_one();
                Err(LinkError::Datagram(e))
            }
        }
    }

    /// The next datagram of `channel`, whole (byte 0 is the header; the payload is `[1..]`). `None` once the
    /// session ended.
    pub async fn recv_datagram(&self, channel: u8) -> Result<Option<Bytes>> {
        self.inner.mux.recv(channel).await
    }

    /// Like `recv_datagram` without waiting.
    pub fn try_recv_datagram(&self, channel: u8) -> Result<Option<Bytes>> {
        self.inner.mux.try_recv(channel)
    }

    /// The largest datagram (header included) the current path carries; 0 when the peer takes none.
    pub fn max_datagram_size(&self) -> usize {
        self.inner.conn.max_datagram_size()
    }

    pub fn datagram_send_buffer_space(&self) -> usize {
        self.inner.conn.datagram_send_buffer_space()
    }

    /// The target bitrate every path's congestion controller follows (the rate controller sets it).
    pub fn target_bitrate(&self) -> &TargetBitrate {
        &self.inner.target
    }

    // MARK: media (channels 1–5: video, audio, input, feedback, cursor)

    /// Opens video stream `stream` (server: per `video.open`, frames from 1; client: per `video.opened`).
    pub fn open_video(&self, stream: u8) {
        self.inner.media.with(|e, _| match e {
            Engine::Server(s) => s.open_video(stream),
            Engine::Client(c) => c.open_video(stream),
        });
    }

    pub fn close_video(&self, stream: u8) {
        self.inner.media.with(|e, _| match e {
            Engine::Server(s) => s.close_video(stream),
            Engine::Client(c) => c.close_video(stream),
        });
    }

    pub fn open_audio(&self, stream: u8) {
        self.inner.media.with(|e, _| match e {
            Engine::Server(s) => s.open_audio(stream),
            Engine::Client(c) => c.open_audio(stream),
        });
    }

    pub fn close_audio(&self, stream: u8) {
        self.inner.media.with(|e, _| match e {
            Engine::Server(s) => s.close_audio(stream),
            Engine::Client(c) => c.close_audio(stream),
        });
    }

    /// Server: whether to encode the next picture now (false: skip it, the newest picture wins).
    pub fn can_send_frame(&self, stream: u8) -> Result<bool> {
        let space = self.inner.conn.datagram_send_buffer_space();
        let queued = media::SEND_BUFFER.saturating_sub(space);
        self.inner.media.server(|s, now| s.can_send_frame(now, stream, queued, Some(space)))
    }

    /// Server: the frame-rate cap of `stream` (frames/s; None: no such stream). An encoder that budgets per frame
    /// at a fixed frame rate (x264 without VFR) should get `encoder_bps × its fps / cap`, else the frames the
    /// cap holds back leave their bits unused (`media::ServerMedia::frame_rate_cap`).
    pub fn frame_rate_cap(&self, stream: u8) -> Result<Option<f64>> {
        self.inner.media.server(|s, _| s.frame_rate_cap(stream))
    }

    /// Server: `can_send_frame` with the numbers it decided on (None: no such stream).
    pub fn send_gate(&self, stream: u8) -> Result<Option<media::SendGate>> {
        let space = self.inner.conn.datagram_send_buffer_space();
        let queued = media::SEND_BUFFER.saturating_sub(space);
        self.inner.media.server(|s, now| s.send_gate(now, stream, queued, Some(space)))
    }

    /// Server: the per-frame traces finished since the last call (session clock).
    pub fn take_tx_traces(&self) -> Result<Vec<media::TxTrace>> {
        self.inner.media.server(|s, now| s.take_tx_traces(now))
    }

    /// Client: every frame's fate since the last call (session clock).
    pub fn take_rx_traces(&self) -> Result<Vec<media::RxTrace>> {
        self.inner.media.client(|c, _| c.take_rx_traces())
    }

    /// The session clock now (µs; the traces' times).
    pub fn media_now_us(&self) -> u64 {
        self.inner.media.now().0
    }

    /// Server: one encoded frame (Annex-B access unit); returns its frame number.
    pub fn send_frame(&self, stream: u8, meta: FrameMeta, au: &[u8]) -> Result<u32> {
        self.inner
            .media
            .server(|s, now| s.send_frame(now, stream, meta, au))?
            .map_err(|e| LinkError::Media(format!("send_frame: {e:?}")))
    }

    /// Server: one Opus packet; returns its `aseq`.
    pub fn send_audio(&self, stream: u8, time_us: u64, opus: &[u8]) -> Result<u32> {
        self.inner
            .media
            .server(|s, now| s.send_audio(now, stream, time_us, opus))?
            .map_err(|e| LinkError::Media(format!("send_audio: {e:?}")))
    }

    /// Server: the newest cursor position (JSON `{x,y,visible,shapeId}`).
    pub fn send_cursor(&self, stream: u8, json: &[u8]) -> Result<()> {
        self.inner.media.server(|s, _| s.send_cursor(stream, json))
    }

    /// Server: the encoder makes the next frame a key frame anyway (e.g. after a `keyframe` control message).
    /// Client: asks the server for one.
    pub fn request_keyframe(&self, stream: u8) {
        self.inner.media.with(|e, now| match e {
            Engine::Server(s) => s.request_keyframe(now, stream),
            Engine::Client(c) => c.request_keyframe(stream),
        });
    }

    /// Server: the next media event (target bitrate, frame delivered, recovery / key frame needed, input);
    /// `None` once the session ended.
    pub async fn recv_server_event(&self) -> Option<ServerEvent> {
        let mut rx = self.inner.media.server_rx.lock().await;
        tokio::select! {
            ev = rx.recv() => ev,
            _ = self.inner.conn.closed() => rx.try_recv().ok(),
        }
    }

    /// Client: one input event (`/input` JSON); returns its `seq`. `Err(Media("…Overflow"))` is a local 429.
    pub fn send_input(&self, kind: InputKind, json: &[u8]) -> Result<u32> {
        self.inner
            .media
            .client(|c, now| c.send_input(now, kind, json))?
            .map_err(|e| LinkError::Media(format!("send_input: {e:?}")))
    }

    /// Client: the decoder took (`ok`) or failed on a frame from `recv_client_event`.
    pub fn frame_decoded(&self, stream: u8, frame: u32, ok: bool) -> Result<()> {
        self.inner.media.client(|c, _| c.frame_decoded(stream, frame, ok))
    }

    /// Client: the next media event (frame, audio packet, cursor, input acked / failed); `None` once the session
    /// ended.
    pub async fn recv_client_event(&self) -> Option<ClientEvent> {
        let mut rx = self.inner.media.client_rx.lock().await;
        tokio::select! {
            ev = rx.recv() => ev,
            _ = self.inner.conn.closed() => rx.try_recv().ok(),
        }
    }

    // MARK: speed test

    /// Client: the speed test (docs/LINK.md「测速」) — the server sends filler frames through this session's video
    /// path for `duration` (it keeps it within 1–20 s; [`probe::DEFAULT_DURATION`] is a good one) and the result
    /// says what a picture would get. Needs a server with the speed test (else `Timeout` after 3 s). One at a time
    /// per session; dropping the future stops it.
    pub async fn probe(&self, duration: Duration) -> Result<ProbeReport> {
        probe::run(&self.inner, duration).await
    }

    // MARK: path, stats

    pub fn path(&self) -> PathInfo {
        self.inner.path()
    }

    pub fn watch_path(&self) -> watch::Receiver<PathInfo> {
        self.inner.path.subscribe()
    }

    /// The media layer's numbers for the stats object and the `link:` line.
    pub fn set_media_stats(&self, m: MediaStats) {
        *self.inner.media_override.lock().unwrap() = m;
    }

    pub fn stats(&self) -> StatsSnapshot {
        self.inner.stats()
    }

    /// The other side's latest `link.stats`.
    pub fn peer_stats(&self) -> Option<StatsSnapshot> {
        self.inner.peer_stats.lock().unwrap().clone()
    }

    // MARK: close

    /// Sends `bye` and closes with `code`. QUIC: waits (≤ 250 ms) for the peer to have the `bye` (a QUIC close
    /// discards stream data still in flight). `rtc`: the `bye` carries the code and the peer connection closes once it
    /// left.
    pub async fn close(&self, code: CloseCode, reason: &str) {
        if self.is_closed() {
            return;
        }
        if self.inner.conn.transport() == Transport::Quic {
            let bye = json!({"t": "bye", "reason": reason});
            let _ = tokio::time::timeout(Duration::from_millis(250), async {
                let mut send = self.inner.control_send.lock().await;
                if framing::write_frame(&mut send, &bye, MAX_CONTROL_FRAME).await.is_ok() {
                    send.flushed().await;
                }
            })
            .await;
        }
        self.inner.close_now(code, reason);
    }

    pub fn is_closed(&self) -> bool {
        self.inner.conn.is_closed()
    }

    /// Waits for the end of the session.
    pub async fn closed(&self) -> CloseInfo {
        let e = self.inner.conn.closed().await;
        e.info(self.inner.local_close.get())
    }

    /// How the session ended, once it did (and its final stats were logged).
    pub fn close_info(&self) -> Option<CloseInfo> {
        self.inner.close_info.borrow().clone()
    }
}

impl Inner {
    /// The session's RTT window (last 10 s): (min, p50, p90) ms, None without samples.
    pub(crate) fn rtt_summary(&self) -> Option<(f64, f64, f64)> {
        self.rtt.lock().unwrap().summary_opt()
    }

    pub(crate) fn path(&self) -> PathInfo {
        self.path.borrow().clone()
    }

    pub(crate) fn peer_name(&self) -> String {
        match self.side {
            Side::Server => {
                let d = &self.hello.device;
                if d.name.is_empty() { d.id.clone() } else { d.name.clone() }
            }
            Side::Client => self.welcome.server.name.clone(),
        }
    }

    pub(crate) async fn write_control(&self, msg: &Value) -> Result<()> {
        let mut send = self.control_send.lock().await;
        framing::write_frame(&mut send, msg, MAX_CONTROL_FRAME).await
    }

    fn close_now(&self, code: CloseCode, reason: &str) {
        let _ = self.local_close.set(CloseInfo { code: Some(code), reason: reason.into(), remote: false });
        self.conn.close(code, reason);
    }

    fn stats(&self) -> StatsSnapshot {
        self.snapshot(self.media.stats())
    }

    fn snapshot(&self, media: Option<MediaStats>) -> StatsSnapshot {
        let path = self.path();
        let (rtt_min_ms, rtt_p50_ms, rtt_p90_ms) = self.rtt.lock().unwrap().summary();
        let st = self.conn.counters();
        let c = &self.mux.counters;
        StatsSnapshot {
            path: path.kind,
            iface: *self.iface.lock().unwrap(),
            remote: path.remote,
            rtt_min_ms,
            rtt_p50_ms,
            rtt_p90_ms,
            bytes_sent: st.bytes_sent,
            bytes_received: st.bytes_received,
            packets_lost: st.packets_lost,
            datagrams_sent: c.sent.load(Ordering::Relaxed),
            datagrams_received: c.received.load(Ordering::Relaxed),
            datagram_drops: c.drops.load(Ordering::Relaxed),
            media: self.media_stats(media),
        }
    }

    fn media_stats(&self, media: Option<MediaStats>) -> MediaStats {
        let o = self.media_override.lock().unwrap().clone();
        let m = media.unwrap_or_default();
        MediaStats {
            loss_pct: o.loss_pct.or(m.loss_pct),
            media_received: o.media_received.or(m.media_received),
            media_missing: o.media_missing.or(m.media_missing),
            fec_recovered: o.fec_recovered.or(m.fec_recovered),
            nack_recovered: o.nack_recovered.or(m.nack_recovered),
            nack_sent: o.nack_sent.or(m.nack_sent),
            lost_frames: o.lost_frames.or(m.lost_frames),
            skipped_frames: o.skipped_frames.or(m.skipped_frames),
            freeze_count: o.freeze_count.or(m.freeze_count),
            freeze_ms: o.freeze_ms.or(m.freeze_ms),
            rate_target_mbps: o.rate_target_mbps.or(m.rate_target_mbps),
            rate_sent_mbps: o.rate_sent_mbps.or(m.rate_sent_mbps),
            rate_cuts: o.rate_cuts.or(m.rate_cuts),
            rate_loss_cuts: o.rate_loss_cuts.or(m.rate_loss_cuts),
            jitter_ms: o.jitter_ms.or(m.jitter_ms),
            fps: o.fps.or(m.fps),
            input_p50_ms: o.input_p50_ms.or(m.input_p50_ms),
            input_p90_ms: o.input_p90_ms.or(m.input_p90_ms),
            input_n: o.input_n.or(m.input_n),
            audio_loss_pct: o.audio_loss_pct.or(m.audio_loss_pct),
            audio_red: o.audio_red.or(m.audio_red),
        }
    }

    /// The `link:` line(s): the media counters and rates over the interval since the previous line.
    fn log_stats(&self) {
        let media = self.media.interval_stats(&mut self.logged_media.lock().unwrap());
        let own = self.snapshot(media);
        match self.side {
            Side::Client => info!("link: {}", own.line()),
            Side::Server => {
                info!("link[server]: {}", own.line());
                if let Some(mut p) = self.peer_stats.lock().unwrap().clone() {
                    let mut logged = self.logged_peer.lock().unwrap();
                    let now = p.media.clone();
                    if let Some(earlier) = logged.as_ref() {
                        p.media = now.since(earlier);
                    }
                    *logged = Some(now);
                    info!("link[phone]: {}", p.line());
                }
            }
        }
    }

    fn update_path(&self) {
        let new = self.conn.path(&self.known);
        let old = self.path();
        if new.kind != PathKind::None && (new.kind != old.kind || new.remote != old.remote) {
            if new.kind != old.kind {
                info!("link path {} → {} ({})", old.kind, new.kind, new.remote.as_deref().unwrap_or("?"));
            }
            self.path.send_replace(new);
            self.log_stats();
        }
    }
}

async fn control_reader(s: Arc<Inner>, mut recv: RecvHalf, tx: mpsc::UnboundedSender<Map<String, Value>>) {
    loop {
        match framing::read_frame(&mut recv, MAX_CONTROL_FRAME).await {
            Ok(Some(m)) => match m.get("t").and_then(Value::as_str) {
                Some("link.stats") => {
                    if let Some(st) = StatsSnapshot::from_message(&Value::Object(m)) {
                        if s.side == Side::Server {
                            s.media.set_network(st.path, st.iface);
                        }
                        *s.peer_stats.lock().unwrap() = Some(st);
                    }
                }
                Some("link.probe") if s.side == Side::Server => probe::serve(s.clone(), m),
                Some("link.probe.stop") if s.side == Side::Server => probe::stop(&s),
                Some("link.probe.started" | "link.probe.done" | "link.probe.error") if s.side == Side::Client => {
                    probe::deliver(&s.probe_waiter, m)
                }
                Some("bye") if matches!(s.conn, Conn::Rtc(_)) => {
                    // on rtc the `bye` is the close itself (code + reason)
                    if let Conn::Rtc(c) = &s.conn {
                        let code = m.get("code").and_then(Value::as_u64).map(CloseCode::from_code);
                        c.peer_closed(code, m.get("reason").and_then(Value::as_str).unwrap_or(""));
                    }
                    let _ = tx.send(m);
                }
                Some(_) => {
                    if tx.send(m).is_err() {
                        break;
                    }
                }
                None => debug!("link: control message without t ignored"),
            },
            Ok(None) => break,
            Err(LinkError::Protocol(e)) => {
                s.close_now(CloseCode::Protocol, &e);
                break;
            }
            Err(_) => break,
        }
    }
}

async fn datagram_reader(s: Arc<Inner>) {
    while let Some(d) = s.conn.read_datagram().await {
        // channels 1–5 are the media layer's
        match datagram::parse_header(&d) {
            Some(1..=5) => {
                s.mux.counters.received.fetch_add(1, Ordering::Relaxed);
                if !s.media.handle_datagram(&d, || s.target.take_rtt_floor()) {
                    s.mux.counters.drop_one();
                }
            }
            _ => s.mux.deliver(d),
        }
    }
    s.mux.close();
}

async fn rpc_acceptor(s: Arc<Inner>, handle: Weak<Handle>, handler: Arc<dyn RpcHandler>, config: Arc<ServeConfig>) {
    while let Some((send, recv)) = s.conn.accept_bi().await {
        let Some(h) = handle.upgrade() else { break };
        let session = Session { inner: s.clone(), _handle: h };
        tokio::spawn(rpc::serve_one(session, handler.clone(), config.clone(), send, recv));
    }
}

/// RTT samples, path changes, the `link.stats` exchange and the `link:` lines, until the connection ends.
async fn monitor(s: Arc<Inner>) {
    let conn = s.conn.clone();
    let mut events = conn.path_events();
    let mut tick = tokio::time::interval(RTT_SAMPLE_EVERY);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut last_stats = Instant::now();
    let mut last_log = Instant::now();
    let mut clock = crate::clock::SlewWatch::default();
    clock.check();
    let mut congestion_seen = 0;
    let closed = conn.closed();
    tokio::pin!(closed);
    let mut events_done = false;
    let end = loop {
        tokio::select! {
            e = &mut closed => break e,
            ev = events.next(), if !events_done => match ev {
                Some(()) => s.update_path(),
                None => events_done = true,
            },
            _ = tick.tick() => {
                let now = Instant::now();
                let rtt = conn.rtt();
                if let Some(r) = rtt {
                    s.rtt.lock().unwrap().push(now, r);
                }
                s.media.set_transport(rtt, conn.max_datagram_size());
                let c = s.target.persistent_congestion_events();
                if c != congestion_seen {
                    congestion_seen = c;
                    s.media.on_persistent_congestion();
                }
                if s.path().kind == PathKind::None {
                    s.update_path();
                }
                if now.duration_since(last_stats) >= STATS_EVERY {
                    last_stats = now;
                    let msg = s.stats().to_message();
                    let s2 = s.clone();
                    tokio::spawn(async move { let _ = s2.write_control(&msg).await; });
                }
                if now.duration_since(last_log) >= LOG_EVERY {
                    last_log = now;
                    s.log_stats();
                    clock.check();
                }
            }
        }
    };
    let info = end.info(s.local_close.get());
    s.log_stats();
    info!("link session closed {} after {} s: {}", s.peer_name(), s.started.elapsed().as_secs(), info.describe());
    let local = !info.remote;
    s.close_info.send_replace(Some(info));
    s.mux.close();
    s.permit.lock().unwrap().take();
    if local {
        // keep the endpoint (held by `s`) a moment, so the close frame leaves even when this was its last session
        tokio::time::sleep(Duration::from_millis(150)).await;
    }
}
