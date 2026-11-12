//! uu Link core: the phone ↔ computer transport of uu (Yoyo Control). docs/LINK.md is the protocol and API reference.
//!
//! - [`Endpoint`]: the UDP sockets, the link key, relays, port mapping; `dial` (client) and `listen` (server).
//! - [`Session`]: control messages, RPC, datagram channels, path, stats — over QUIC or WebRTC ([`rtc`], browsers).
//! - [`binding`]: the identity's signature over the link key.
//! - [`cc::MediaCc`]: the congestion controller every path uses, following the media layer's target bitrate.

pub mod binding;
pub mod cc;
mod clock;
pub mod datagram;
pub mod endpoint;
pub mod error;
mod framing;
pub mod guard;
pub mod log;
pub mod media;
pub mod path;
pub mod probe;
pub mod rpc;
pub mod rtc;
pub mod runtime;
pub mod session;
pub mod stats;
pub mod transport;

/// The QUIC ALPN of the link.
pub const ALPN: &[u8] = b"yoyo-link/1";
/// `v` of `hello` / `welcome`.
pub const PROTOCOL_VERSION: u32 = 1;

pub use binding::{Binding, fingerprint, sign_binding, verify_binding};
pub use cc::TargetBitrate;
pub use endpoint::{
    AddrInfo, AuthDecision, AuthRequest, Authenticator, DialOptions, DialTarget, Endpoint, EndpointConfig, Listener,
    Role, ServerOptions, Source,
};
pub use error::{CloseCode, DenyCode, LinkError, Result};
pub use framing::{MAX_CONTROL_FRAME, MAX_RPC_HEAD};
pub use guard::GuardConfig;
pub use path::{Iface, PathInfo, PathKind};
pub use probe::{ProbeReport, ProbeServerReport};
pub use rpc::{Headers, RpcBody, RpcHandler, RpcRequest, RpcResponder, RpcResponse};
pub use rtc::{IdentityKey, IdentitySigner, RtcConfig};
pub use session::{AppInfo, CloseInfo, Device, Hello, ServerInfo, Session, Side, Welcome};
pub use stats::{MediaStats, StatsSnapshot};
pub use transport::Transport;
