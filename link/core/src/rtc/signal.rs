//! Signaling: the client's offer, the server's signed answer (docs/LINK.md「WebRTC」).
//!
//! - offer: `{"v":1,"offer":"<SDP>","device":{"id","name"}}` (non-trickle: every candidate is in the SDP).
//! - answer: `{"v":1,"answer":"<SDP>","fingerprint":"sha256:<hex>","binding":{id,key,sig},"sig":"<b64 r‖s>"}`.
//!   `fingerprint` is the server's DTLS certificate (lowercase hex, no colons); `sig` is ECDSA-P256-SHA256 by the
//!   identity key over `"yoyocontrol-rtc-v1:" + hex(SHA-256(offer SDP bytes)) + ":" + fingerprint`. The client
//!   checks `SHA-256(binding.key)` against the pinned identity fingerprint, `sig`, and that the answer SDP's
//!   `a=fingerprint` is `fingerprint`.

use std::net::SocketAddr;

use base64::{Engine, engine::general_purpose::STANDARD as B64};
use data_encoding::HEXLOWER;
use ring::{
    rand::SystemRandom,
    signature::{self, EcdsaKeyPair, UnparsedPublicKey},
};
use serde::{Deserialize, Serialize};

use crate::{
    binding::{self, Binding, IDENTITY_KEY_LEN},
    error::{LinkError, Result},
    session::Device,
};

/// What the identity signs (then `hex(sha256(offer)) + ":" + fingerprint`).
pub const RTC_SIGNATURE_CONTEXT: &str = "yoyocontrol-rtc-v1:";

/// The client's offer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RtcOffer {
    pub v: u32,
    /// The offer SDP, with every candidate (gathering finished).
    pub offer: String,
    #[serde(default)]
    pub device: Device,
    /// The key of this connection's next ICE restart ([`restart_key`] of a secret only the client knows): a server
    /// that takes restarts keeps it (docs/LINK.md「WebRTC」「换网络」).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rk: Option<String>,
    /// An ICE restart: the secret whose key an earlier offer of the same connection gave. The same DTLS, SCTP and
    /// channels go on over the path this offer's candidates find; `rk` is the key of the restart after it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restart: Option<String>,
}

/// The key a restart secret is known by: lowercase hex SHA-256 of its UTF-8 bytes. Only the key goes with the first
/// offer, so whoever carries it (the relay) can't restart the connection from it.
pub fn restart_key(secret: &str) -> String {
    HEXLOWER.encode(ring::digest::digest(&ring::digest::SHA256, secret.as_bytes()).as_ref())
}

/// The server's answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RtcAnswer {
    pub v: u32,
    pub answer: String,
    /// `sha256:<lowercase hex>` of the server's DTLS certificate.
    pub fingerprint: String,
    /// The link binding (the same object `/status.link` publishes): its `key` is the identity the client pins.
    pub binding: Binding,
    /// base64 of the identity's raw r‖s signature (see the module docs).
    pub sig: String,
    /// The server takes ICE restarts of this connection (offers with `restart`); absent from servers before them.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub restarts: bool,
}

impl RtcOffer {
    pub fn parse(json: &str) -> Result<RtcOffer> {
        if json.len() > super::MAX_SIGNAL {
            return Err(LinkError::InvalidArgument(format!("offer over {} bytes", super::MAX_SIGNAL)));
        }
        let o: RtcOffer = serde_json::from_str(json).map_err(|e| LinkError::InvalidArgument(format!("offer: {e}")))?;
        if o.v != 1 {
            return Err(LinkError::InvalidArgument(format!("offer version {} (want 1)", o.v)));
        }
        if !o.offer.starts_with("v=0") {
            return Err(LinkError::InvalidArgument("offer is not an SDP".into()));
        }
        Ok(o)
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

impl RtcAnswer {
    pub fn parse(json: &str) -> Result<RtcAnswer> {
        if json.len() > super::MAX_SIGNAL {
            return Err(LinkError::Protocol(format!("answer over {} bytes", super::MAX_SIGNAL)));
        }
        serde_json::from_str(json).map_err(|e| LinkError::Protocol(format!("answer: {e}")))
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

/// Signs with the server's identity (ECDSA P-256). The identity key file itself ([`IdentityKey`]), or anything that
/// holds it elsewhere (a keychain, an HSM).
pub trait IdentitySigner: Send + Sync + 'static {
    /// The identity public key, X9.63 (65 bytes, `04 ‖ X ‖ Y`).
    fn public_key(&self) -> Vec<u8>;
    /// ECDSA-P256-SHA256 over `message`, raw `r ‖ s` (64 bytes).
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>>;
}

/// An [`IdentitySigner`] over the 97-byte X9.63 private key of the identity files (`04 ‖ X ‖ Y ‖ D`).
pub struct IdentityKey {
    pair: EcdsaKeyPair,
    public: Vec<u8>,
}

impl std::fmt::Debug for IdentityKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IdentityKey").field("fingerprint", &binding::fingerprint(&self.public)).finish()
    }
}

impl IdentityKey {
    pub fn new(identity_key: &[u8]) -> Result<IdentityKey> {
        if identity_key.len() != IDENTITY_KEY_LEN || identity_key[0] != 0x04 {
            return Err(LinkError::Binding(format!(
                "identity key: want {IDENTITY_KEY_LEN} bytes of X9.63 (04 ‖ X ‖ Y ‖ D), got {}",
                identity_key.len()
            )));
        }
        let (public, private) = identity_key.split_at(65);
        let pair = EcdsaKeyPair::from_private_key_and_public_key(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            private,
            public,
            &SystemRandom::new(),
        )
        .map_err(|e| LinkError::Binding(format!("identity key rejected: {e}")))?;
        Ok(IdentityKey { pair, public: public.to_vec() })
    }
}

impl IdentitySigner for IdentityKey {
    fn public_key(&self) -> Vec<u8> {
        self.public.clone()
    }

    fn sign(&self, message: &[u8]) -> Result<Vec<u8>> {
        let sig =
            self.pair.sign(&SystemRandom::new(), message).map_err(|e| LinkError::Binding(format!("sign: {e}")))?;
        Ok(sig.as_ref().to_vec())
    }
}

/// The bytes the identity signs for an answer.
pub fn signature_message(offer_sdp: &str, fingerprint: &str) -> Vec<u8> {
    let digest = ring::digest::digest(&ring::digest::SHA256, offer_sdp.as_bytes());
    format!("{RTC_SIGNATURE_CONTEXT}{}:{fingerprint}", HEXLOWER.encode(digest.as_ref())).into_bytes()
}

/// The answer JSON for `offer_sdp`: `answer_sdp` and its DTLS `fingerprint`, signed by `identity`; `binding` is the
/// identity's binding over the endpoint's link key.
pub fn sign_answer(
    identity: &dyn IdentitySigner,
    binding: Binding,
    offer_sdp: &str,
    answer_sdp: String,
    fingerprint: String,
) -> Result<RtcAnswer> {
    let sig = identity.sign(&signature_message(offer_sdp, &fingerprint))?;
    Ok(RtcAnswer { v: 1, answer: answer_sdp, fingerprint, binding, sig: B64.encode(sig), restarts: false })
}

/// The client's checks of an answer to `offer_sdp` against the pinned identity fingerprint: the binding's key,
/// the signature, the answer SDP's DTLS fingerprint. Returns the server's link id (the binding's, verified).
pub fn verify_answer(answer: &RtcAnswer, offer_sdp: &str, pinned_fingerprint: &str) -> Result<[u8; 32]> {
    if answer.v != 1 {
        return Err(LinkError::Binding(format!("answer version {}", answer.v)));
    }
    let id = binding::verify_binding(&answer.binding, pinned_fingerprint)?;
    let key = B64.decode(answer.binding.key.as_bytes()).map_err(|_| LinkError::Binding("key is not base64".into()))?;
    let sig = B64.decode(answer.sig.as_bytes()).map_err(|_| LinkError::Binding("sig is not base64".into()))?;
    UnparsedPublicKey::new(&signature::ECDSA_P256_SHA256_FIXED, &key)
        .verify(&signature_message(offer_sdp, &answer.fingerprint), &sig)
        .map_err(|_| LinkError::Binding("answer signature does not verify".into()))?;
    match sdp_fingerprint(&answer.answer) {
        Some(fp) if fp == answer.fingerprint => Ok(id),
        _ => Err(LinkError::Binding("the answer's DTLS fingerprint is not the signed one".into())),
    }
}

/// `sha256:<lowercase hex>` from bytes.
pub(crate) fn fingerprint_string(bytes: &[u8]) -> String {
    format!("sha256:{}", HEXLOWER.encode(bytes))
}

/// The SDP's `a=fingerprint:sha-256 AA:BB:…` (session or first media level) as `sha256:<lowercase hex>`.
pub fn sdp_fingerprint(sdp: &str) -> Option<String> {
    sdp.lines().find_map(|l| {
        let v = l.trim().strip_prefix("a=fingerprint:")?;
        let (alg, hex) = v.split_once(' ')?;
        if !alg.eq_ignore_ascii_case("sha-256") {
            return None;
        }
        let hex: String = hex.trim().chars().filter(|c| *c != ':').collect::<String>().to_ascii_lowercase();
        (hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_hexdigit())).then(|| format!("sha256:{hex}"))
    })
}

/// A candidate line's address and type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SdpCandidate {
    pub addr: SocketAddr,
    pub host: bool,
    /// A TURN server's relayed address (`typ relay`): a path to it goes through the TURN server.
    pub relay: bool,
}

fn parse_candidate(line: &str) -> Option<Option<SdpCandidate>> {
    let v = line.trim().strip_prefix("a=candidate:")?;
    let f: Vec<&str> = v.split_whitespace().collect();
    // foundation component transport priority address port "typ" type …
    if f.len() < 8 || !f[2].eq_ignore_ascii_case("udp") {
        return Some(None);
    }
    let ip = f[4].parse().ok();
    let port: Option<u16> = f[5].parse().ok();
    Some(match (ip, port) {
        (Some(ip), Some(port)) => {
            Some(SdpCandidate { addr: SocketAddr::new(ip, port), host: f[7] == "host", relay: f[7] == "relay" })
        }
        _ => None,
    })
}

/// The offer as str0m takes it: candidates it can't use (mDNS `.local` names, TCP) left out. Peer-reflexive
/// discovery still finds those peers (their checks arrive anyway).
pub(crate) fn usable_offer(sdp: &str) -> (String, Vec<SdpCandidate>) {
    let mut out = String::with_capacity(sdp.len());
    let mut cands = Vec::new();
    for line in sdp.split_inclusive('\n') {
        match parse_candidate(line) {
            Some(None) => continue,
            Some(Some(c)) => cands.push(c),
            None => {}
        }
        out.push_str(line);
    }
    (out, cands)
}

/// The SDP without the UDP candidate lines `keep` refuses.
pub(crate) fn filter_candidates(sdp: &str, keep: impl Fn(SocketAddr) -> bool) -> String {
    sdp.split_inclusive('\n').filter(|line| !matches!(parse_candidate(line), Some(Some(c)) if !keep(c.addr))).collect()
}

/// The well-known NAT64 prefix (RFC 6052, `64:ff9b::/96`): most carriers' DNS64 / NAT64 use it.
const NAT64_PREFIX: [u16; 6] = [0x64, 0xff9b, 0, 0, 0, 0];

/// `v4` behind the well-known NAT64 prefix.
pub(crate) fn nat64(v4: std::net::Ipv4Addr) -> std::net::Ipv6Addr {
    let o = v4.octets();
    let p = NAT64_PREFIX;
    std::net::Ipv6Addr::new(
        p[0],
        p[1],
        p[2],
        p[3],
        p[4],
        p[5],
        u16::from_be_bytes([o[0], o[1]]),
        u16::from_be_bytes([o[2], o[3]]),
    )
}

/// The answer with each public IPv4 UDP candidate also given as its NAT64 address (`64:ff9b::<v4>`, the same port,
/// a little lower priority), right after the candidates. A browser on an IPv6-only network (5G with NAT64, e.g. Safari
/// on iPhone: it doesn't synthesize IPv6 for IPv4 candidates as the system does for apps) can't use an IPv4 candidate
/// at all; through the carrier's NAT64 this one reaches the same IPv4 address and port (the router's mapping or the
/// interface), its checks arrive as IPv4 from the NAT64's address, and ICE learns that as a peer-reflexive candidate.
/// Only in the SDP: the server never sends from it (str0m doesn't know it). Where there's no NAT64 the pair just fails.
pub(crate) fn with_nat64(sdp: &str) -> String {
    let mut extra = String::new();
    let mut seen = Vec::new();
    for line in sdp.split_inclusive('\n') {
        let Some(Some(c)) = parse_candidate(line) else { continue };
        let std::net::IpAddr::V4(v4) = c.addr.ip() else { continue };
        // private, loopback, link-local, and the shared 100.64/10 (carrier NAT, Tailscale): nothing a NAT64 reaches
        let shared = v4.octets()[0] == 100 && (v4.octets()[1] & 0xc0) == 64;
        if crate::path::is_local_ip(c.addr.ip()) || shared || seen.contains(&c.addr) {
            continue;
        }
        seen.push(c.addr);
        let f: Vec<&str> = line.trim().split_whitespace().collect();
        let priority: u32 = f[3].parse::<u32>().unwrap_or(1).saturating_sub(1).max(1);
        extra.push_str(&format!(
            "a=candidate:n64{} 1 udp {priority} {} {} typ host\r\n",
            seen.len(),
            nat64(v4),
            c.addr.port()
        ));
    }
    if extra.is_empty() {
        return sdp.to_string();
    }
    let mut out = String::with_capacity(sdp.len() + extra.len());
    let last =
        sdp.split_inclusive('\n').enumerate().filter(|(_, l)| l.starts_with("a=candidate:")).map(|(i, _)| i).last();
    for (i, line) in sdp.split_inclusive('\n').enumerate() {
        out.push_str(line);
        if Some(i) == last {
            out.push_str(&extra);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn public_ipv4_candidates_are_also_given_behind_nat64() {
        let sdp = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n\
            a=candidate:1 1 udp 2130706431 192.168.50.151 52520 typ host\r\n\
            a=candidate:2 1 udp 2130706431 93.184.216.34 52520 typ host\r\n\
            a=candidate:3 1 udp 1694498815 93.184.216.34 52520 typ srflx raddr 192.168.50.151 rport 52520\r\n\
            a=end-of-candidates\r\n";
        let out = with_nat64(sdp);
        assert!(
            out.contains("a=candidate:n641 1 udp 2130706430 64:ff9b::5db8:d822 52520 typ host\r\na=end-of-candidates"),
            "{out}"
        );
        assert_eq!(out.matches("64:ff9b").count(), 1, "one per address: {out}");
        assert!(!out.contains("64:ff9b::c0a8"), "no private ones");
        let (_, cands) = usable_offer(&out);
        assert!(cands.iter().any(|c| c.addr == "[64:ff9b::5db8:d822]:52520".parse().unwrap()));
        assert_eq!(nat64("93.184.216.34".parse().unwrap()).to_string(), "64:ff9b::5db8:d822");
        let lan_only = "a=candidate:1 1 udp 2130706431 192.168.50.151 52520 typ host\r\na=candidate:2 1 udp 2130706431 100.93.131.5 52520 typ host\r\n";
        assert_eq!(with_nat64(lan_only), lan_only);
    }
    use crate::binding::{identity_fingerprint, sign_binding};

    /// A P-256 identity key in the 97-byte file format.
    pub(crate) fn test_identity() -> Vec<u8> {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let pair = EcdsaKeyPair::from_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap();
        use ring::signature::KeyPair;
        // ring's PKCS#8 v1 document for P-256: the private scalar follows `04 20` inside the ECPrivateKey
        let doc = pkcs8.as_ref();
        let at = doc.windows(2).position(|w| w == [0x04, 0x20]).unwrap() + 2;
        [pair.public_key().as_ref(), &doc[at..at + 32]].concat()
    }

    const OFFER: &str = "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\n\
        a=candidate:1 1 udp 2113937151 3f1c0a2e-7c4f.local 54321 typ host\r\n\
        a=candidate:2 1 udp 2113937151 192.168.1.20 54321 typ host\r\n\
        a=candidate:3 1 udp 1677729535 203.0.113.9 40000 typ srflx raddr 0.0.0.0 rport 0\r\n\
        a=candidate:4 1 tcp 1518280447 192.168.1.20 9 typ host tcptype active\r\n";

    #[test]
    fn sign_and_verify() {
        let id_key = test_identity();
        let fp = identity_fingerprint(&id_key).unwrap();
        let signer = IdentityKey::new(&id_key).unwrap();
        assert_eq!(binding::fingerprint(&signer.public_key()), fp);
        let link = [7u8; 32];
        let b = sign_binding(&id_key, &link).unwrap();
        let dtls = format!("sha256:{}", "ab".repeat(32));
        let answer_sdp = format!("v=0\r\na=fingerprint:sha-256 {}\r\n", vec!["AB"; 32].join(":"));
        let a = sign_answer(&signer, b.clone(), OFFER, answer_sdp.clone(), dtls.clone()).unwrap();
        let a = RtcAnswer::parse(&a.to_json()).unwrap();
        assert_eq!(verify_answer(&a, OFFER, &fp).unwrap(), link);
        // another offer, another pin, a swapped fingerprint: all hard failures
        assert!(verify_answer(&a, "v=0\r\nother", &fp).is_err());
        assert!(verify_answer(&a, OFFER, &format!("sha256:{}", "00".repeat(32))).is_err());
        let mut swapped = a.clone();
        swapped.answer = format!("v=0\r\na=fingerprint:sha-256 {}\r\n", vec!["CD"; 32].join(":"));
        assert!(verify_answer(&swapped, OFFER, &fp).is_err());
        let mut forged = a.clone();
        forged.fingerprint = format!("sha256:{}", "cd".repeat(32));
        forged.answer = swapped.answer.clone();
        assert!(verify_answer(&forged, OFFER, &fp).is_err());
    }

    #[test]
    fn offers() {
        let json = RtcOffer {
            v: 1,
            offer: OFFER.into(),
            device: Device { id: "d".into(), name: "n".into() },
            rk: None,
            restart: None,
        }
        .to_json();
        assert_eq!(RtcOffer::parse(&json).unwrap().offer, OFFER);
        assert!(RtcOffer::parse(r#"{"v":2,"offer":"v=0"}"#).is_err());
        assert!(RtcOffer::parse(r#"{"v":1,"offer":"hello"}"#).is_err());
        assert!(RtcOffer::parse(&"x".repeat(70_000)).is_err());
        let (clean, cands) = usable_offer(OFFER);
        assert!(!clean.contains(".local") && !clean.contains("tcp"));
        assert!(clean.contains("192.168.1.20 54321") && clean.ends_with("rport 0\r\n"));
        assert_eq!(cands.len(), 2);
        assert!(cands[0].host && !cands[1].host);
        let only_public = filter_candidates(OFFER, |a| !crate::path::is_local_ip(a.ip()));
        assert!(!only_public.contains("192.168.1.20 54321") && only_public.contains("203.0.113.9"));
    }

    #[test]
    fn fingerprints() {
        let sdp =
            "v=0\r\nm=application 9\r\na=fingerprint:SHA-256 0A:1b:".to_string() + &vec!["FF"; 30].join(":") + "\r\n";
        assert_eq!(sdp_fingerprint(&sdp).unwrap(), format!("sha256:0a1b{}", "ff".repeat(30)));
        assert!(sdp_fingerprint("v=0\r\na=fingerprint:sha-1 00:11\r\n").is_none());
    }

    #[test]
    fn a_turn_candidate_is_marked_relay() {
        let sdp = "v=0\r\na=candidate:1 1 udp 2122260223 192.168.1.20 54321 typ host\r\n\
                   a=candidate:2 1 udp 41885439 198.51.100.20 49200 typ relay raddr 0.0.0.0 rport 0\r\n";
        let (_, cands) = usable_offer(sdp);
        assert_eq!(cands.iter().map(|c| (c.host, c.relay)).collect::<Vec<_>>(), vec![(true, false), (false, true)]);
    }
}
