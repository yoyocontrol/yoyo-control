import Foundation

/// A computer's uu Link binding as it publishes it (docs/LINK.md「身份与信任」): its link key (`id`, the endpoint id)
/// signed by its identity key (`key`, `sig`), with where it listens: the UDP `port`, its relays and its `direct`
/// addresses. `GET /status` answers it as `link`, and so does the relay's `GET /v1/candidates/<fp>`. Not trusted until
/// checked against the pinned fingerprint (YoyoLinkClient's `verified(fingerprint:)`); kept as it came (Codable: a
/// backend may remember it with the computer).
public struct ConnectLinkBinding: Codable, Sendable, Hashable {
    /// hex of the Ed25519 link public key.
    public var id: String
    /// base64 of the 65-byte P-256 identity public key.
    public var key: String
    /// base64 of the ECDSA-P256-SHA256 signature (r‖s) over `"yoyocontrol-link-v1:"` ‖ the link key.
    public var sig: String
    /// The UDP port it listens on (nil: not said).
    public var port: UInt16?
    /// Its relays' URLs (empty: direct only).
    public var relays: [String]
    /// Its addresses as `ip:port` (`[v6]:port`): local, the router's mapping, IPv6.
    public var direct: [String]

    public init(id: String, key: String, sig: String, port: UInt16? = nil, relays: [String] = [], direct: [String] = []) {
        self.id = id
        self.key = key
        self.sig = sig
        self.port = port
        self.relays = relays
        self.direct = direct
    }

    /// From the `link` object of `/status` or the relay (`{id, key, sig, port?, relays?, direct?}`); nil without the
    /// three strings. `direct` takes `ip:port` strings and `{host, port}` objects; anything else is left out.
    public init?(json: Any?) {
        guard let o = json as? [String: Any], let id = o["id"] as? String, let key = o["key"] as? String,
              let sig = o["sig"] as? String, !id.isEmpty, !key.isEmpty, !sig.isEmpty else { return nil }
        self.id = id
        self.key = key
        self.sig = sig
        port = (o["port"] as? Int).flatMap { UInt16(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil }
        relays = (o["relays"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        direct = (o["direct"] as? [Any] ?? []).compactMap { item -> String? in
            if let s = item as? String { return Self.socketAddress(s) }
            if let d = item as? [String: Any], let host = d["host"] as? String,
               let port = (d["port"] as? Int).flatMap({ UInt16(exactly: $0) }), port > 0 {
                return Self.socketAddress(host: host, port: port)
            }
            return nil
        }
    }

    /// `host:port` for an IP address (`[v6]:port`); nil for anything else.
    public static func socketAddress(host: String, port: UInt16) -> String? {
        let h = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard isIP(h), port > 0 else { return nil }
        return h.contains(":") ? "[\(h)]:\(port)" : "\(h):\(port)"
    }

    /// An `ip:port` / `[v6]:port` as it should be (normalized), nil when it isn't one.
    static func socketAddress(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            let host = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return socketAddress(host: host, port: port)
        }
        guard let colon = t.lastIndex(of: ":"), let port = UInt16(t[t.index(after: colon)...]) else { return nil }
        return socketAddress(host: String(t[..<colon]), port: port)
    }

    private static func isIP(_ s: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return s.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}
