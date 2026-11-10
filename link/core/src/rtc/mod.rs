//! uu Link over WebRTC ("rtc", docs/LINK.md「WebRTC」): the same session protocol v1 and media layer on one
//! RTCPeerConnection, so browsers can dial a server.
//!
//! | session piece | WebRTC |
//! | --- | --- |
//! | control stream | data channel `control`, negotiated id 0, ordered, reliable; same frames |
//! | each RPC stream | a data channel `rpc` the client opens (DCEP), ordered, reliable; a zero-length message = FIN, closing the channel without one = reset |
//! | datagrams | data channel `dgram`, negotiated id 1, unordered, `maxRetransmits: 0`; one message = one datagram |
//! | close code + reason | `{"t":"bye","code","reason"}` on `control`, then the peer connection closes |
//!
//! Signaling is one offer → answer exchange carried by whatever path the host has ([`signal`]); the answer is
//! signed by the server's identity key so the client pins it like the QUIC binding. The peer connections run on
//! [str0m](https://github.com/algesten/str0m) (sans-IO ICE, DTLS, SCTP) over the endpoint's own UDP socket(s)
//! ([`RtcConfig`]).

mod hub;
mod peer;
pub mod signal;
mod stun;

pub(crate) use hub::Hub;
pub(crate) use peer::{
    Peer, RtcConn, RtcRecv, RtcSend, control_config as peer_control_config, dgram_config as peer_dgram_config,
};
pub use signal::{
    IdentityKey, IdentitySigner, RtcAnswer, RtcOffer, restart_key, sdp_fingerprint, sign_answer, verify_answer,
};
pub(crate) use signal::{filter_candidates, fingerprint_string, usable_offer as usable_sdp, with_nat64};

use std::time::Duration;

/// Label and negotiated SCTP stream id of the control channel.
pub const CONTROL_LABEL: &str = "control";
pub const CONTROL_CHANNEL_ID: u16 = 0;
/// Label and negotiated SCTP stream id of the datagram channel.
pub const DGRAM_LABEL: &str = "dgram";
pub const DGRAM_CHANNEL_ID: u16 = 1;
/// Label of the channels the client opens for RPC requests.
pub const RPC_LABEL: &str = "rpc";
/// The largest datagram (one `dgram` message, header byte included): fits one SCTP packet on every path.
pub const MAX_DATAGRAM: usize = 1200;
/// From the offer until the control channel is open (ICE, DTLS, SCTP).
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Largest signaling message (offer or answer JSON).
pub const MAX_SIGNAL: usize = 64 * 1024;

/// The endpoint's WebRTC socket(s).
#[derive(Debug, Clone, Default)]
pub struct RtcConfig {
    /// UDP port on every bound address; 0 = any. uu's own servers use the link port + 1 (47821).
    pub port: u16,
    /// STUN servers (`host:port`) a server asks for its public address (a server-reflexive candidate); empty =
    /// none. Clients don't need one: the server answers with every address it has.
    pub stun_servers: Vec<String>,
    /// Answers offer only the external addresses (`add_rtc_external_addr`) and the STUN one, not the interfaces':
    /// a server in a container whose own addresses nobody reaches, or a test that must go through an impairment proxy.
    pub external_only: bool,
}

impl RtcConfig {
    /// The rtc port for a link port: the next one (0 stays 0).
    pub fn default_port(link_port: u16) -> u16 {
        if link_port == 0 { 0 } else { link_port.wrapping_add(1) }
    }
}
