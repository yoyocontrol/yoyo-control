//! What a session needs from the connection under it, over either transport: QUIC (iroh) or WebRTC
//! (`rtc`, docs/LINK.md「WebRTC」). Reliable streams (the control stream, one per RPC), datagrams with a bounded send
//! buffer, the selected path and its RTT, an application close with code and reason, the end of the connection.
//!
//! The session, RPC and media code only see [`Conn`], [`SendHalf`] and [`RecvHalf`]; each variant maps them onto its
//! transport (an enum rather than a trait object: two closed variants, no boxing on the datagram path).

use std::{collections::HashSet, fmt, future::Future, net::SocketAddr, time::Duration};

use bytes::Bytes;
use data_encoding::HEXLOWER;
use iroh::endpoint::{Connection, ConnectionError, PathEvent, ReadToEndError, RecvStream, SendStream, VarInt};
use n0_future::StreamExt;
use serde::{Deserialize, Serialize};

use crate::{
    error::{CloseCode, LinkError, Result},
    path::{self, PathInfo},
    rtc::{RtcConn, RtcRecv, RtcSend},
    session::CloseInfo,
};

/// Which transport a session runs on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Transport {
    /// QUIC over iroh (the native apps).
    Quic,
    /// WebRTC data channels (browsers; docs/LINK.md「WebRTC」).
    Rtc,
}

impl Transport {
    pub fn as_str(self) -> &'static str {
        match self {
            Transport::Quic => "quic",
            Transport::Rtc => "rtc",
        }
    }
}

impl fmt::Display for Transport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Byte and packet counters of the connection (the stats object's transport half).
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct TransportCounters {
    pub bytes_sent: u64,
    pub bytes_received: u64,
    pub packets_lost: u64,
}

/// How a connection ended, before the session's own close info is folded in.
pub(crate) enum Ended {
    Quic(ConnectionError),
    Rtc(CloseInfo),
}

impl Ended {
    /// `local`: what this side said when it closed (QUIC only reports "locally closed").
    pub(crate) fn info(&self, local: Option<&CloseInfo>) -> CloseInfo {
        match self {
            Ended::Quic(e) => CloseInfo::from_error(e, local),
            Ended::Rtc(i) => i.clone(),
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) enum Conn {
    Quic(Connection),
    Rtc(RtcConn),
}

impl Conn {
    pub(crate) fn transport(&self) -> Transport {
        match self {
            Conn::Quic(_) => Transport::Quic,
            Conn::Rtc(_) => Transport::Rtc,
        }
    }

    pub(crate) fn quic(&self) -> Option<&Connection> {
        match self {
            Conn::Quic(c) => Some(c),
            Conn::Rtc(_) => None,
        }
    }

    /// hex of the peer's link key (QUIC), or the peer's DTLS certificate id (`rtc`, see `RtcConn::remote_id`).
    pub(crate) fn remote_id(&self) -> String {
        match self {
            Conn::Quic(c) => HEXLOWER.encode(c.remote_id().as_bytes()),
            Conn::Rtc(c) => c.remote_id(),
        }
    }

    pub(crate) async fn open_bi(&self) -> Result<(SendHalf, RecvHalf)> {
        match self {
            Conn::Quic(c) => {
                let (s, r) = c.open_bi().await.map_err(|e| LinkError::Closed(e.to_string()))?;
                Ok((SendHalf::Quic(s), RecvHalf::Quic(r)))
            }
            Conn::Rtc(c) => {
                let (s, r) = c.open_stream()?;
                Ok((SendHalf::Rtc(s), RecvHalf::Rtc(r)))
            }
        }
    }

    /// The next stream the peer opened; `None` once the connection ended.
    pub(crate) async fn accept_bi(&self) -> Option<(SendHalf, RecvHalf)> {
        match self {
            Conn::Quic(c) => c.accept_bi().await.ok().map(|(s, r)| (SendHalf::Quic(s), RecvHalf::Quic(r))),
            Conn::Rtc(c) => c.accept_stream().await.map(|(s, r)| (SendHalf::Rtc(s), RecvHalf::Rtc(r))),
        }
    }

    pub(crate) fn send_datagram(&self, d: Bytes) -> std::result::Result<(), String> {
        match self {
            Conn::Quic(c) => c.send_datagram(d).map_err(|e| e.to_string()),
            Conn::Rtc(c) => c.send_datagram(d),
        }
    }

    /// The next datagram from the peer; `None` once the connection ended.
    pub(crate) async fn read_datagram(&self) -> Option<Bytes> {
        match self {
            Conn::Quic(c) => c.read_datagram().await.ok(),
            Conn::Rtc(c) => c.read_datagram().await,
        }
    }

    pub(crate) fn datagram_send_buffer_space(&self) -> usize {
        match self {
            Conn::Quic(c) => c.datagram_send_buffer_space(),
            Conn::Rtc(c) => c.datagram_send_buffer_space(),
        }
    }

    /// The largest datagram (header included); 0 when the peer takes none.
    pub(crate) fn max_datagram_size(&self) -> usize {
        match self {
            Conn::Quic(c) => c.max_datagram_size().unwrap_or(0),
            Conn::Rtc(c) => c.max_datagram_size(),
        }
    }

    /// The RTT of the selected path.
    pub(crate) fn rtt(&self) -> Option<Duration> {
        match self {
            Conn::Quic(c) => c.paths().iter().find(|p| p.is_selected()).map(|p| p.rtt()),
            Conn::Rtc(c) => c.rtt(),
        }
    }

    /// The selected path; `known` = the public addresses that count as `direct` (QUIC).
    pub(crate) fn path(&self, known: &HashSet<SocketAddr>) -> PathInfo {
        match self {
            Conn::Quic(c) => match c.paths().iter().find(|p| p.is_selected()) {
                Some(p) => path::classify(p.remote_addr(), known),
                None => PathInfo::none(),
            },
            Conn::Rtc(c) => c.path(),
        }
    }

    pub(crate) fn path_events(&self) -> PathEvents {
        match self {
            Conn::Quic(c) => PathEvents::Quic(c.path_events()),
            Conn::Rtc(c) => PathEvents::Rtc(c.watch_path()),
        }
    }

    pub(crate) fn counters(&self) -> TransportCounters {
        match self {
            Conn::Quic(c) => {
                let st = c.stats();
                TransportCounters {
                    bytes_sent: st.udp_tx.bytes,
                    bytes_received: st.udp_rx.bytes,
                    packets_lost: st.lost_packets,
                }
            }
            Conn::Rtc(c) => c.counters(),
        }
    }

    /// Closes now with `code`. QUIC: the CONNECTION_CLOSE frame (stream data in flight is discarded). `rtc`: `bye`
    /// with the code on the control channel, then the peer connection a moment later.
    pub(crate) fn close(&self, code: CloseCode, reason: &str) {
        match self {
            Conn::Quic(c) => c.close(VarInt::from_u64(code.code()).unwrap_or(VarInt::from_u32(0)), reason.as_bytes()),
            Conn::Rtc(c) => c.close(code, reason),
        }
    }

    pub(crate) fn is_closed(&self) -> bool {
        match self {
            Conn::Quic(c) => c.close_reason().is_some(),
            Conn::Rtc(c) => c.is_closed(),
        }
    }

    /// How it ended, if it did.
    pub(crate) fn ended(&self) -> Option<Ended> {
        match self {
            Conn::Quic(c) => c.close_reason().map(Ended::Quic),
            Conn::Rtc(c) => c.close_info().map(Ended::Rtc),
        }
    }

    /// Resolves at the end of the connection (independent of `self`).
    pub(crate) fn closed(&self) -> impl Future<Output = Ended> + Send + 'static {
        let c = self.clone();
        async move {
            match c {
                Conn::Quic(c) => Ended::Quic(c.closed().await),
                Conn::Rtc(c) => Ended::Rtc(c.closed().await),
            }
        }
    }
}

/// Path changes of a connection.
pub(crate) enum PathEvents {
    Quic(iroh::endpoint::PathEventStream),
    Rtc(tokio::sync::watch::Receiver<PathInfo>),
}

impl PathEvents {
    /// The next change worth re-reading the path for; `None` when there will be none.
    pub(crate) async fn next(&mut self) -> Option<()> {
        match self {
            PathEvents::Quic(s) => loop {
                match s.next().await? {
                    PathEvent::Opened { .. } => {}
                    _ => return Some(()),
                }
            },
            PathEvents::Rtc(w) => w.changed().await.ok(),
        }
    }
}

/// The sending half of a reliable stream.
#[derive(Debug)]
pub(crate) enum SendHalf {
    Quic(SendStream),
    Rtc(RtcSend),
}

impl SendHalf {
    pub(crate) async fn write_all(&mut self, data: &[u8]) -> Result<()> {
        match self {
            SendHalf::Quic(s) => s.write_all(data).await.map_err(|e| LinkError::Closed(e.to_string())),
            SendHalf::Rtc(s) => s.write_all(data).await,
        }
    }

    /// The end of what this side sends (QUIC FIN, `rtc` a zero-length message).
    pub(crate) async fn finish(&mut self) -> Result<()> {
        match self {
            SendHalf::Quic(s) => s.finish().map_err(|e| LinkError::Closed(e.to_string())),
            SendHalf::Rtc(s) => s.finish().await,
        }
    }

    /// Abandons the stream: the peer sees an error, not an end.
    pub(crate) fn reset(&mut self) {
        match self {
            SendHalf::Quic(s) => {
                let _ = s.reset(VarInt::from_u32(1));
            }
            SendHalf::Rtc(s) => s.reset(),
        }
    }

    /// Resolves when the peer stopped reading (or the connection ended).
    pub(crate) fn stopped(&self) -> impl Future<Output = ()> + Send + 'static {
        enum F<A, B> {
            A(A),
            B(B),
        }
        let f = match self {
            SendHalf::Quic(s) => F::A(s.stopped()),
            SendHalf::Rtc(s) => F::B(s.stopped()),
        };
        async move {
            match f {
                F::A(f) => {
                    let _ = f.await;
                }
                F::B(f) => f.await,
            }
        }
    }

    /// QUIC: waits (bounded by the caller) until the peer has everything sent so far.
    pub(crate) async fn flushed(&mut self) {
        match self {
            SendHalf::Quic(s) => {
                if s.finish().is_ok() {
                    let _ = s.stopped().await;
                }
            }
            SendHalf::Rtc(s) => s.flushed().await,
        }
    }
}

/// Why reading a stream to its end failed.
pub(crate) enum ReadToEnd {
    TooLong,
    Failed,
}

/// The receiving half of a reliable stream.
#[derive(Debug)]
pub(crate) enum RecvHalf {
    Quic(RecvStream),
    Rtc(RtcRecv),
}

impl RecvHalf {
    /// Up to `buf.len()` bytes; `None` at the end of the stream.
    pub(crate) async fn read(&mut self, buf: &mut [u8]) -> Result<Option<usize>> {
        match self {
            RecvHalf::Quic(r) => r.read(buf).await.map_err(|e| LinkError::Closed(e.to_string())),
            RecvHalf::Rtc(r) => r.read(buf).await,
        }
    }

    pub(crate) async fn read_exact(&mut self, buf: &mut [u8]) -> Result<()> {
        match self {
            RecvHalf::Quic(r) => r.read_exact(buf).await.map_err(|e| LinkError::Closed(e.to_string())),
            RecvHalf::Rtc(r) => {
                let mut at = 0;
                while at < buf.len() {
                    match r.read(&mut buf[at..]).await? {
                        Some(n) => at += n,
                        None => return Err(LinkError::Closed("stream ended early".into())),
                    }
                }
                Ok(())
            }
        }
    }

    /// The next piece (≤ `max` bytes); `None` at the end.
    pub(crate) async fn read_chunk(&mut self, max: usize) -> Result<Option<Bytes>> {
        match self {
            RecvHalf::Quic(r) => match r.read_chunk(max).await {
                Ok(c) => Ok(c),
                Err(e) => Err(LinkError::Closed(e.to_string())),
            },
            RecvHalf::Rtc(r) => r.read_chunk(max).await,
        }
    }

    pub(crate) async fn read_to_end(&mut self, limit: usize) -> std::result::Result<Vec<u8>, ReadToEnd> {
        match self {
            RecvHalf::Quic(r) => r.read_to_end(limit).await.map_err(|e| match e {
                ReadToEndError::TooLong => ReadToEnd::TooLong,
                _ => ReadToEnd::Failed,
            }),
            RecvHalf::Rtc(r) => {
                let mut out = Vec::new();
                loop {
                    match r.read_chunk(64 * 1024).await {
                        Ok(Some(c)) => {
                            if out.len() + c.len() > limit {
                                return Err(ReadToEnd::TooLong);
                            }
                            out.extend_from_slice(&c);
                        }
                        Ok(None) => return Ok(out),
                        Err(_) => return Err(ReadToEnd::Failed),
                    }
                }
            }
        }
    }

    /// The server is not going to read the rest (QUIC STOP_SENDING; `rtc`: what still comes is dropped, the stream
    /// stays open for the response).
    pub(crate) fn stop(&mut self) {
        match self {
            RecvHalf::Quic(r) => {
                let _ = r.stop(VarInt::from_u32(0));
            }
            RecvHalf::Rtc(r) => r.discard(),
        }
    }

    /// The client gives up on the exchange (QUIC STOP_SENDING; `rtc`: the channel closes, the server's writes fail).
    pub(crate) fn cancel(&mut self) {
        match self {
            RecvHalf::Quic(r) => {
                let _ = r.stop(VarInt::from_u32(0));
            }
            RecvHalf::Rtc(r) => r.cancel(),
        }
    }
}
