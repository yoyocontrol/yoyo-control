//! RPC streams: every client-opened bidi stream after the control stream is one request
//! (`u32 len + {"m","p","h"}`, then the body until FIN) and its response (`u32 len + {"s","h"}`, then the body until
//! FIN, streamed). The server hands requests to the app's handler, which answers through an `RpcResponder`.
//!
//! A **duplex** request (`"duplex": true` in its head, no body: a WebSocket's upgrade over the link) is answered by
//! the handler either as any request, or by `RpcResponder::accept_duplex` (status 101): from then on both directions
//! of the stream carry messages (`DuplexMessage`: `u8 type + u32 BE length + payload`, 1 text / 2 binary / 8 close
//! with `u16 BE code + reason`), each at most `MAX_DUPLEX_MESSAGE`, until either side's FIN. A server that takes them
//! says `duplex` in its `welcome` features; the client sends none to a server that doesn't (it would wait for a body).

use std::collections::BTreeMap;

use async_trait::async_trait;
use bytes::Bytes;
use serde_json::{Map, Value, json};

use crate::{
    error::{LinkError, Result},
    framing::{self, MAX_RPC_HEAD},
    session::Session,
    transport::{Conn, ReadToEnd, RecvHalf, SendHalf},
};

/// Paths that are channels or control messages on the link, never RPC: answered 404.
pub const DEFAULT_BLOCKED_PATHS: &[&str] = &["/stream", "/stream/ack", "/audio", "/input", "/control"];
/// Largest request body a server reads (bigger: 413).
pub const DEFAULT_MAX_REQUEST_BODY: usize = 8 * 1024 * 1024;
/// Largest message of a duplex stream (its payload).
pub const MAX_DUPLEX_MESSAGE: usize = 1024 * 1024;
/// Unread bytes a duplex stream over WebRTC may hold (two whole messages and some; each data-channel message waiting
/// also counts 64 bytes, so a flood of tiny ones hits it too): a data channel has no receive window, so a peer that
/// writes faster than the other side reads past this gets the stream reset, where QUIC's flow control would hold it
/// back.
pub const RTC_DUPLEX_RECV_MAX: usize = 2 * MAX_DUPLEX_MESSAGE + 64 * 1024;
/// What a request's body may run ahead of its reader over WebRTC beyond the body limit (the head, each message's
/// overhead, and what the client sends past the limit before the reader sees it: a body over the limit gets its 413
/// unless it is more than this over while the reader is held up — then the stream is reset).
pub(crate) const RTC_BODY_SLACK: usize = 2 * 1024 * 1024;
/// The bound of every other RPC stream a server takes over WebRTC, from the channel's open until its head is read
/// (then: the server's body limit and `RTC_BODY_SLACK`). A body is read as it arrives, and up to the body limit
/// anyway: what waits unread costs no more than the read body would.
pub const RTC_RPC_RECV_MAX: usize = DEFAULT_MAX_REQUEST_BODY + RTC_BODY_SLACK;
/// Without the credit window: what all of a WebRTC session's duplex streams may hold unread together (32 streams just
/// under their own bounds would be ~70 MiB): the stream whose message would go past it is reset. Under the credit
/// window: the pool that decides how big a stream's next window may be (the others' unread bytes) — fairness, not
/// the memory bound, which is each stream's window: at most 32 x `RTC_CREDIT_WINDOW` (32 MiB) unread per session.
pub const RTC_SESSION_RECV_MAX: usize = 8 * 1024 * 1024;
/// The `hello` / `welcome` feature of the credit window over WebRTC (docs/LINK.md「信用窗口」): both sides say it, and
/// every `rpc` channel's sender waits for the receiver's grants instead of being reset past the receive bounds.
pub const CREDIT_FEATURE: &str = "credit";
/// What one data-channel message costs on top of its length, for the receive bounds and the credit window alike (both
/// sides count it the same way: a flood of tiny messages costs what it takes in memory).
pub const RTC_MESSAGE_COST: usize = 64;
/// The window each stream starts with (each direction), and keeps whatever the session's pool: its messages fit
/// (≤ 16 KiB + `RTC_MESSAGE_COST`), so it always moves.
pub const RTC_CREDIT_INITIAL: usize = 64 * 1024;
/// The most a stream's receiver lets the peer have unacknowledged (sent, not yet read): with `MAX_RPC_STREAMS`, the
/// memory bound (32 x 1 MiB unread per session). Past `RTC_CREDIT_INITIAL` it is given only as far as the session's
/// pool (`RTC_SESSION_RECV_MAX`, the others' unread bytes) has room: fairness between streams.
pub const RTC_CREDIT_WINDOW: usize = 1024 * 1024;
/// The `welcome` feature of a server that takes duplex requests.
pub const DUPLEX_FEATURE: &str = "duplex";

pub type Headers = BTreeMap<String, String>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RpcRequest {
    pub method: String,
    /// Path and query, as in HTTP (`/status`, `/clipboard/file?id=3`).
    pub path: String,
    /// Lower-case names.
    pub headers: Headers,
    /// A duplex request (no body; answered by `accept_duplex`, or as any request).
    pub duplex: bool,
}

impl RpcRequest {
    pub fn new(method: impl Into<String>, path: impl Into<String>) -> Self {
        RpcRequest { method: method.into(), path: path.into(), headers: Headers::new(), duplex: false }
    }

    pub fn header(mut self, name: &str, value: impl Into<String>) -> Self {
        self.headers.insert(name.to_ascii_lowercase(), value.into());
        self
    }

    fn to_json(&self) -> Value {
        let mut v = json!({"m": self.method, "p": self.path, "h": self.headers});
        if self.duplex {
            v["duplex"] = true.into();
        }
        v
    }

    fn from_json(m: &Map<String, Value>) -> Result<Self> {
        let method = m.get("m").and_then(Value::as_str).ok_or_else(|| LinkError::protocol("request without m"))?;
        let path = m.get("p").and_then(Value::as_str).ok_or_else(|| LinkError::protocol("request without p"))?;
        Ok(RpcRequest {
            method: method.to_string(),
            path: path.to_string(),
            headers: headers_from(m.get("h")),
            duplex: m.get("duplex").and_then(Value::as_bool).unwrap_or(false),
        })
    }
}

fn headers_from(v: Option<&Value>) -> Headers {
    let mut out = Headers::new();
    if let Some(Value::Object(h)) = v {
        for (k, v) in h {
            let value = match v {
                Value::String(s) => s.clone(),
                Value::Null => continue,
                other => other.to_string(),
            };
            out.insert(k.to_ascii_lowercase(), value);
        }
    }
    out
}

/// The client's view of a response: status and headers, then the body as it streams.
#[derive(Debug)]
pub struct RpcResponse {
    pub status: u16,
    pub headers: Headers,
    pub body: RpcBody,
}

#[derive(Debug)]
pub struct RpcBody {
    recv: Option<RecvHalf>,
}

impl RpcBody {
    /// The next piece of the body; `None` at its end.
    pub async fn chunk(&mut self) -> Result<Option<Bytes>> {
        let Some(recv) = self.recv.as_mut() else { return Ok(None) };
        match recv.read_chunk(64 * 1024).await {
            Ok(Some(b)) => Ok(Some(b)),
            Ok(None) => {
                self.recv = None;
                Ok(None)
            }
            Err(e) => {
                self.recv = None;
                Err(LinkError::Closed(format!("response body: {e}")))
            }
        }
    }

    /// The whole (rest of the) body, at most `limit` bytes.
    pub async fn read_all(&mut self, limit: usize) -> Result<Bytes> {
        let mut out = Vec::new();
        while let Some(c) = self.chunk().await? {
            if out.len() + c.len() > limit {
                self.cancel();
                return Err(LinkError::Protocol(format!("response body over {limit} bytes")));
            }
            out.extend_from_slice(&c);
        }
        Ok(out.into())
    }

    /// Stops reading (the server's writes fail from now on: a streamed response ends).
    pub fn cancel(&mut self) {
        if let Some(mut r) = self.recv.take() {
            r.cancel();
        }
    }
}

pub(crate) async fn request(conn: &Conn, req: &RpcRequest, body: &[u8]) -> Result<RpcResponse> {
    let (mut send, mut recv) = conn.open_bi().await?;
    // (a duplex request goes through `request_duplex` only: it checks the server takes them)
    let mut head = req.to_json();
    if let Some(m) = head.as_object_mut() {
        m.remove("duplex");
    }
    framing::write_frame(&mut send, &head, MAX_RPC_HEAD).await?;
    if !body.is_empty() {
        send.write_all(body).await?;
    }
    let _ = send.finish().await;
    let head = framing::read_frame(&mut recv, MAX_RPC_HEAD)
        .await?
        .ok_or_else(|| LinkError::protocol("stream ended without a response"))?;
    let status = head
        .get("s")
        .and_then(Value::as_u64)
        .filter(|s| (100..=999).contains(s))
        .ok_or_else(|| LinkError::protocol("response without s"))? as u16;
    Ok(RpcResponse { status, headers: headers_from(head.get("h")), body: RpcBody { recv: Some(recv) } })
}

// MARK: duplex

/// One message of a duplex stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DuplexMessage {
    Text(String),
    Binary(Bytes),
    /// A WebSocket's close: its code and reason (the stream goes on until FIN).
    Close {
        code: u16,
        reason: String,
    },
}

const DUPLEX_TEXT: u8 = 1;
const DUPLEX_BINARY: u8 = 2;
const DUPLEX_CLOSE: u8 = 8;

impl DuplexMessage {
    fn encode(&self) -> Result<Vec<u8>> {
        let (t, payload): (u8, std::borrow::Cow<[u8]>) = match self {
            DuplexMessage::Text(s) => (DUPLEX_TEXT, s.as_bytes().into()),
            DuplexMessage::Binary(b) => (DUPLEX_BINARY, b.as_ref().into()),
            DuplexMessage::Close { code, reason } => {
                let mut p = code.to_be_bytes().to_vec();
                p.extend_from_slice(reason.as_bytes());
                (DUPLEX_CLOSE, p.into())
            }
        };
        if payload.len() > MAX_DUPLEX_MESSAGE {
            return Err(LinkError::InvalidArgument(format!(
                "message of {} bytes is over {MAX_DUPLEX_MESSAGE}",
                payload.len()
            )));
        }
        let mut out = Vec::with_capacity(5 + payload.len());
        out.push(t);
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        out.extend_from_slice(&payload);
        Ok(out)
    }

    fn decode(t: u8, payload: Vec<u8>) -> Result<Self> {
        match t {
            DUPLEX_TEXT => String::from_utf8(payload)
                .map(DuplexMessage::Text)
                .map_err(|_| LinkError::protocol("duplex text is not UTF-8")),
            DUPLEX_BINARY => Ok(DuplexMessage::Binary(payload.into())),
            DUPLEX_CLOSE => {
                if payload.len() < 2 {
                    return Err(LinkError::protocol("duplex close without a code"));
                }
                let code = u16::from_be_bytes([payload[0], payload[1]]);
                let reason = String::from_utf8(payload[2..].to_vec())
                    .map_err(|_| LinkError::protocol("duplex close reason is not UTF-8"))?;
                Ok(DuplexMessage::Close { code, reason })
            }
            t => Err(LinkError::protocol(format!("duplex message of type {t}"))),
        }
    }
}

/// Sends a duplex stream's messages. `finish` ends this direction; dropped before it: the stream is reset.
#[derive(Debug)]
pub struct DuplexSender {
    send: Option<SendHalf>,
}

impl DuplexSender {
    pub async fn send(&mut self, message: &DuplexMessage) -> Result<()> {
        let bytes = message.encode()?;
        let s = self.send.as_mut().ok_or_else(|| LinkError::Closed("duplex stream finished".into()))?;
        s.write_all(&bytes).await
    }

    /// Ends this direction (FIN): the other side's `recv` ends.
    pub async fn finish(&mut self) -> Result<()> {
        match self.send.take() {
            Some(mut s) => s.finish().await,
            None => Ok(()),
        }
    }

    /// Resolves when the other side stopped reading or the session ended. Doesn't borrow the sender.
    pub fn stopped(&self) -> impl std::future::Future<Output = ()> + Send + 'static {
        let f = self.send.as_ref().map(|s| s.stopped());
        async move {
            if let Some(f) = f {
                f.await;
            }
        }
    }
}

impl Drop for DuplexSender {
    fn drop(&mut self) {
        if let Some(mut s) = self.send.take() {
            s.reset();
        }
    }
}

/// Receives a duplex stream's messages.
#[derive(Debug)]
pub struct DuplexReceiver {
    recv: Option<RecvHalf>,
}

impl DuplexReceiver {
    /// The next message; `None` once the other side finished (FIN).
    pub async fn recv(&mut self) -> Result<Option<DuplexMessage>> {
        let Some(r) = self.recv.as_mut() else { return Ok(None) };
        let mut head = [0u8; 5];
        match r.read(&mut head[..1]).await {
            Ok(None) => {
                self.recv = None;
                return Ok(None);
            }
            Ok(Some(0)) => return Err(LinkError::protocol("empty read")),
            Ok(Some(_)) => {}
            Err(e) => {
                self.recv = None;
                return Err(e);
            }
        }
        let rest = async {
            r.read_exact(&mut head[1..]).await?;
            let n = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
            if n > MAX_DUPLEX_MESSAGE {
                return Err(LinkError::protocol(format!("duplex message of {n} bytes is over {MAX_DUPLEX_MESSAGE}")));
            }
            let mut payload = vec![0u8; n];
            r.read_exact(&mut payload).await?;
            DuplexMessage::decode(head[0], payload)
        };
        match rest.await {
            Ok(m) => Ok(Some(m)),
            Err(e) => {
                self.cancel();
                Err(e)
            }
        }
    }

    /// Stops reading (the other side's sends fail from now on).
    pub fn cancel(&mut self) {
        if let Some(mut r) = self.recv.take() {
            r.cancel();
        }
    }
}

/// The two directions of an accepted duplex stream.
#[derive(Debug)]
pub struct Duplex {
    pub sender: DuplexSender,
    pub receiver: DuplexReceiver,
}

/// The client's view of a duplex request's answer: accepted (101, `duplex`), or any other response (`body`).
#[derive(Debug)]
pub struct DuplexResponse {
    pub status: u16,
    pub headers: Headers,
    /// Accepted (status 101).
    pub duplex: Option<Duplex>,
    /// Not accepted: the response's body (empty when accepted).
    pub body: RpcBody,
}

pub(crate) async fn request_duplex(conn: &Conn, req: &RpcRequest) -> Result<DuplexResponse> {
    let mut req = req.clone();
    req.duplex = true;
    let (mut send, mut recv) = conn.open_bi().await?;
    framing::write_frame(&mut send, &req.to_json(), MAX_RPC_HEAD).await?;
    let head = framing::read_frame(&mut recv, MAX_RPC_HEAD)
        .await?
        .ok_or_else(|| LinkError::protocol("stream ended without a response"))?;
    let status = head
        .get("s")
        .and_then(Value::as_u64)
        .filter(|s| (100..=999).contains(s))
        .ok_or_else(|| LinkError::protocol("response without s"))? as u16;
    let headers = headers_from(head.get("h"));
    if status == 101 {
        recv.limit(RTC_DUPLEX_RECV_MAX, true);
        let duplex =
            Duplex { sender: DuplexSender { send: Some(send) }, receiver: DuplexReceiver { recv: Some(recv) } };
        return Ok(DuplexResponse { status, headers, duplex: Some(duplex), body: RpcBody { recv: None } });
    }
    // refused: nothing more to send
    let _ = send.finish().await;
    Ok(DuplexResponse { status, headers, duplex: None, body: RpcBody { recv: Some(recv) } })
}

/// The server's side of an RPC: `head`, then `write` the body (as often as needed), then `finish`.
/// Dropped before `finish`: the stream is reset (the client sees an error, not a short body).
#[derive(Debug)]
pub struct RpcResponder {
    send: Option<SendHalf>,
    head_sent: bool,
    /// A duplex request's other direction, until `accept_duplex` takes it.
    recv: Option<RecvHalf>,
}

impl RpcResponder {
    pub(crate) fn new(send: SendHalf) -> Self {
        RpcResponder { send: Some(send), head_sent: false, recv: None }
    }

    /// Whether this answers a duplex request (and `accept_duplex` can take it).
    pub fn is_duplex(&self) -> bool {
        self.recv.is_some()
    }

    /// Accepts a duplex request: head 101 with `headers`, then the stream's two directions. Only for a duplex request
    /// (`RpcRequest::duplex`) whose head isn't sent yet.
    pub async fn accept_duplex(&mut self, headers: &Headers) -> Result<Duplex> {
        if self.recv.is_none() {
            return Err(LinkError::InvalidArgument("not a duplex request".into()));
        }
        self.head(101, headers).await?;
        let send = self.send.take().ok_or_else(|| LinkError::Closed("response already finished".into()))?;
        let recv = self.recv.take().expect("checked");
        Ok(Duplex { sender: DuplexSender { send: Some(send) }, receiver: DuplexReceiver { recv: Some(recv) } })
    }

    fn stream(&mut self) -> Result<&mut SendHalf> {
        self.send.as_mut().ok_or_else(|| LinkError::Closed("response already finished".into()))
    }

    pub fn head_sent(&self) -> bool {
        self.head_sent
    }

    pub async fn head(&mut self, status: u16, headers: &Headers) -> Result<()> {
        if self.head_sent {
            return Err(LinkError::InvalidArgument("response head already sent".into()));
        }
        let msg = json!({"s": status, "h": headers});
        framing::write_frame(self.stream()?, &msg, MAX_RPC_HEAD).await?;
        self.head_sent = true;
        Ok(())
    }

    pub async fn write(&mut self, data: &[u8]) -> Result<()> {
        if !self.head_sent {
            return Err(LinkError::InvalidArgument("send the response head first".into()));
        }
        self.stream()?.write_all(data).await
    }

    /// Ends the body (a head of 200 first if none was sent).
    pub async fn finish(&mut self) -> Result<()> {
        if !self.head_sent {
            self.head(200, &Headers::new()).await?;
        }
        let mut s = self.send.take().ok_or_else(|| LinkError::Closed("response already finished".into()))?;
        s.finish().await
    }

    /// Head, whole body, finish.
    pub async fn respond(&mut self, status: u16, headers: &Headers, body: &[u8]) -> Result<()> {
        self.head(status, headers).await?;
        if !body.is_empty() {
            self.write(body).await?;
        }
        self.finish().await
    }

    /// Resolves when the client stopped reading (cancelled the request) or the session ended. Doesn't borrow the
    /// responder: wait on it while writing.
    pub fn stopped(&self) -> impl std::future::Future<Output = ()> + Send + 'static {
        let f = self.send.as_ref().map(|s| s.stopped());
        async move {
            if let Some(f) = f {
                f.await;
            }
        }
    }
}

impl Drop for RpcResponder {
    fn drop(&mut self) {
        if let Some(mut s) = self.send.take() {
            s.reset();
        }
    }
}

/// What a server does with requests. Called once per request, on its own task.
#[async_trait]
pub trait RpcHandler: Send + Sync + 'static {
    async fn handle(&self, session: Session, request: RpcRequest, body: Bytes, responder: RpcResponder);
}

pub(crate) struct ServeConfig {
    pub blocked_paths: Vec<String>,
    pub max_body: usize,
    /// Takes duplex requests (over WebRTC too, each stream's unread bytes bounded: RTC_DUPLEX_RECV_MAX).
    pub duplex: bool,
}

pub(crate) async fn serve_one(
    session: Session,
    handler: std::sync::Arc<dyn RpcHandler>,
    config: std::sync::Arc<ServeConfig>,
    send: SendHalf,
    mut recv: RecvHalf,
) {
    let mut responder = RpcResponder::new(send);
    let head = match framing::read_frame(&mut recv, MAX_RPC_HEAD).await {
        Ok(Some(h)) => h,
        _ => return,
    };
    let req = match RpcRequest::from_json(&head) {
        Ok(r) => r,
        Err(e) => {
            // (its incoming side stopped: whatever the peer goes on sending is dropped, not kept)
            recv.stop();
            let _ = respond_error(&mut responder, 400, &e.to_string()).await;
            return;
        }
    };
    let route = req.path.split('?').next().unwrap_or("");
    if config.blocked_paths.iter().any(|p| p == route) {
        recv.stop();
        let _ = respond_error(&mut responder, 404, "not available over RPC").await;
        return;
    }
    if req.duplex {
        // only where they are taken: else refused, the stream's incoming side stopped (the peer's sends fail instead
        // of piling up)
        if !config.duplex {
            recv.stop();
            let _ = respond_error(&mut responder, 400, "duplex requests are not taken here").await;
            return;
        }
        // no body: the stream stays open both ways for `accept_duplex`; over WebRTC with a bound on what may wait
        // unread (no receive window there)
        recv.limit(RTC_DUPLEX_RECV_MAX, true);
        responder.recv = Some(recv);
        handler.handle(session, req, Bytes::new(), responder).await;
        return;
    }
    // over WebRTC: unread, at most what the body may be (and some)
    recv.limit(config.max_body.saturating_add(RTC_BODY_SLACK), false);
    let body = match recv.read_to_end(config.max_body).await {
        Ok(b) => Bytes::from(b),
        Err(ReadToEnd::TooLong) => {
            recv.stop();
            let _ = respond_error(&mut responder, 413, "request body too large").await;
            return;
        }
        Err(ReadToEnd::Failed) => return,
    };
    handler.handle(session, req, body, responder).await;
}

async fn respond_error(r: &mut RpcResponder, status: u16, message: &str) -> Result<()> {
    let mut h = Headers::new();
    h.insert("content-type".into(), "application/json".into());
    let body = serde_json::to_vec(&json!({"error": message})).unwrap_or_default();
    r.respond(status, &h, &body).await
}

#[cfg(test)]
mod duplex_tests {
    use super::*;

    fn round(m: DuplexMessage) -> DuplexMessage {
        let b = m.encode().unwrap();
        let n = u32::from_be_bytes([b[1], b[2], b[3], b[4]]) as usize;
        assert_eq!(n, b.len() - 5);
        DuplexMessage::decode(b[0], b[5..].to_vec()).unwrap()
    }

    #[test]
    fn messages_round_trip_and_limits() {
        for m in [
            DuplexMessage::Text("hé".into()),
            DuplexMessage::Text(String::new()),
            DuplexMessage::Binary(Bytes::from_static(&[0, 1, 2, 255])),
            DuplexMessage::Close { code: 1000, reason: "bye".into() },
            DuplexMessage::Close { code: 4001, reason: String::new() },
        ] {
            assert_eq!(round(m.clone()), m);
        }
        assert!(DuplexMessage::Binary(vec![0u8; MAX_DUPLEX_MESSAGE].into()).encode().is_ok());
        assert!(DuplexMessage::Binary(vec![0u8; MAX_DUPLEX_MESSAGE + 1].into()).encode().is_err());
        assert!(DuplexMessage::decode(1, vec![0xff]).is_err(), "text must be UTF-8");
        assert!(DuplexMessage::decode(8, vec![3]).is_err(), "close needs its code");
        assert!(DuplexMessage::decode(9, vec![]).is_err(), "unknown type");
    }

    #[test]
    fn the_request_head_says_duplex_only_when_it_is() {
        let mut r = RpcRequest::new("GET", "/sessions/s1/voice");
        assert!(r.to_json().get("duplex").is_none());
        r.duplex = true;
        let v = r.to_json();
        assert_eq!(v["duplex"], true);
        assert!(RpcRequest::from_json(v.as_object().unwrap()).unwrap().duplex);
    }
}
