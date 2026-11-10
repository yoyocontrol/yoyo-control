//! RPC streams: every client-opened bidi stream after the control stream is one request
//! (`u32 len + {"m","p","h"}`, then the body until FIN) and its response (`u32 len + {"s","h"}`, then the body until
//! FIN, streamed). The server hands requests to the app's handler, which answers through an `RpcResponder`.

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

pub type Headers = BTreeMap<String, String>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RpcRequest {
    pub method: String,
    /// Path and query, as in HTTP (`/status`, `/clipboard/file?id=3`).
    pub path: String,
    /// Lower-case names.
    pub headers: Headers,
}

impl RpcRequest {
    pub fn new(method: impl Into<String>, path: impl Into<String>) -> Self {
        RpcRequest { method: method.into(), path: path.into(), headers: Headers::new() }
    }

    pub fn header(mut self, name: &str, value: impl Into<String>) -> Self {
        self.headers.insert(name.to_ascii_lowercase(), value.into());
        self
    }

    fn to_json(&self) -> Value {
        json!({"m": self.method, "p": self.path, "h": self.headers})
    }

    fn from_json(m: &Map<String, Value>) -> Result<Self> {
        let method = m.get("m").and_then(Value::as_str).ok_or_else(|| LinkError::protocol("request without m"))?;
        let path = m.get("p").and_then(Value::as_str).ok_or_else(|| LinkError::protocol("request without p"))?;
        Ok(RpcRequest { method: method.to_string(), path: path.to_string(), headers: headers_from(m.get("h")) })
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
    framing::write_frame(&mut send, &req.to_json(), MAX_RPC_HEAD).await?;
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

/// The server's side of an RPC: `head`, then `write` the body (as often as needed), then `finish`.
/// Dropped before `finish`: the stream is reset (the client sees an error, not a short body).
#[derive(Debug)]
pub struct RpcResponder {
    send: Option<SendHalf>,
    head_sent: bool,
}

impl RpcResponder {
    pub(crate) fn new(send: SendHalf) -> Self {
        RpcResponder { send: Some(send), head_sent: false }
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
