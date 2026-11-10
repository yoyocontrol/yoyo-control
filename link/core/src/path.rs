//! Which road a session's packets take, for logs and the UI: `relay`, `lan`, `direct` or `punched`, and the client's
//! network interface.

use std::{
    collections::HashSet,
    fmt,
    net::{IpAddr, SocketAddr},
};

use iroh::TransportAddr;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PathKind {
    /// Through a relay server.
    Relay,
    /// The remote address is private, link-local, loopback or ULA.
    Lan,
    /// A public address the client dialed (the server's advertised one) — on the server: the address the
    /// connection came from.
    Direct,
    /// A public address learned by NAT traversal.
    Punched,
    /// No path selected (yet).
    None,
}

impl PathKind {
    pub fn as_str(self) -> &'static str {
        match self {
            PathKind::Relay => "relay",
            PathKind::Lan => "lan",
            PathKind::Direct => "direct",
            PathKind::Punched => "punched",
            PathKind::None => "none",
        }
    }

    pub fn parse(s: &str) -> PathKind {
        match s {
            "relay" => PathKind::Relay,
            "lan" => PathKind::Lan,
            "direct" => PathKind::Direct,
            "punched" => PathKind::Punched,
            _ => PathKind::None,
        }
    }
}

impl fmt::Display for PathKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The client's network interface (the app knows it, e.g. from `NWPathMonitor`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Iface {
    Wifi,
    Cellular,
    Wired,
    #[default]
    Other,
}

impl Iface {
    pub fn as_str(self) -> &'static str {
        match self {
            Iface::Wifi => "wifi",
            Iface::Cellular => "cellular",
            Iface::Wired => "wired",
            Iface::Other => "other",
        }
    }

    pub fn parse(s: &str) -> Iface {
        match s {
            "wifi" => Iface::Wifi,
            "cellular" => Iface::Cellular,
            "wired" => Iface::Wired,
            _ => Iface::Other,
        }
    }
}

impl fmt::Display for Iface {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The selected path of a session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathInfo {
    pub kind: PathKind,
    /// `ip:port`, or the relay URL.
    pub remote: Option<String>,
}

impl PathInfo {
    pub fn none() -> Self {
        PathInfo { kind: PathKind::None, remote: None }
    }
}

/// Private (RFC 1918), loopback, link-local, ULA (fc00::/7), IPv4-mapped forms of those.
pub fn is_local_ip(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(v4) => v4.is_private() || v4.is_loopback() || v4.is_link_local(),
        IpAddr::V6(v6) => {
            v6.is_loopback() || (v6.segments()[0] & 0xfe00) == 0xfc00 || (v6.segments()[0] & 0xffc0) == 0xfe80
        }
    }
}

/// Classifies a remote transport address. `known` = public addresses that count as `direct` (the client's dial
/// hints; the server's first remote address); every other public one was punched.
pub fn classify(remote: &TransportAddr, known: &HashSet<SocketAddr>) -> PathInfo {
    match remote {
        TransportAddr::Relay(url) => PathInfo { kind: PathKind::Relay, remote: Some(url.to_string()) },
        TransportAddr::Ip(addr) => {
            let kind = if is_local_ip(addr.ip()) {
                PathKind::Lan
            } else if known.contains(addr) || known.iter().any(|k| k.ip().to_canonical() == addr.ip().to_canonical()) {
                PathKind::Direct
            } else {
                PathKind::Punched
            };
            PathInfo { kind, remote: Some(addr.to_string()) }
        }
        other => PathInfo { kind: PathKind::Direct, remote: Some(format!("{other:?}")) },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> TransportAddr {
        TransportAddr::Ip(s.parse().unwrap())
    }

    #[test]
    fn kinds() {
        let hints: HashSet<SocketAddr> = ["93.184.216.34:47820".parse().unwrap()].into_iter().collect();
        assert_eq!(classify(&ip("192.168.50.10:47820"), &hints).kind, PathKind::Lan);
        assert_eq!(classify(&ip("10.1.2.3:1"), &hints).kind, PathKind::Lan);
        assert_eq!(classify(&ip("169.254.1.1:1"), &hints).kind, PathKind::Lan);
        assert_eq!(classify(&ip("[fd7a:115c::1]:1"), &hints).kind, PathKind::Lan);
        assert_eq!(classify(&ip("[fe80::1]:1"), &hints).kind, PathKind::Lan);
        assert_eq!(classify(&ip("[::ffff:192.168.0.2]:1"), &hints).kind, PathKind::Lan);
        assert_eq!(classify(&ip("93.184.216.34:47820"), &hints).kind, PathKind::Direct);
        // same public address, another port (the router's mapping changed): still the address we dialed
        assert_eq!(classify(&ip("93.184.216.34:40000"), &hints).kind, PathKind::Direct);
        assert_eq!(classify(&ip("198.51.100.7:5000"), &hints).kind, PathKind::Punched);
        let relay = TransportAddr::Relay("https://r1.example.com./".parse().unwrap());
        assert_eq!(classify(&relay, &hints).kind, PathKind::Relay);
    }
}
