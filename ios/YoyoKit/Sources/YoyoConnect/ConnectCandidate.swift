import CryptoKit
import Foundation
import Security
import YoyoCore

/// One way to reach a computer that a `YoyoConnector` may race and use (ios/README.md「YoyoConnect」): a uu Link
/// session (`link`: UDP, its own paths — local, direct, punched or relayed — under one connection), straight to it on
/// the phone's local network (`lan`), straight to it across the internet (`direct`: a public address its router
/// forwards, a VPN address), or through something in between that always works (`relay`, `tunnel`: the fallbacks).
/// What it is for the kits (`route(shortcut:)`), where it is (`host`, `port`), how its server is trusted (`trust`) and
/// the credential its requests carry (`credential`, opaque here: a candidate with another credential is another one,
/// so a renewed credential is noticed). The backend that supplies it builds the requests on it.
public struct ConnectCandidate: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case lan, direct, relay, tunnel
        /// A uu Link session (docs/LINK.md): it finds its own paths, so it is better than any of the others wherever it
        /// connects. Its link carries the media itself (`YoyoScreenLink`).
        case link

        /// A way that always works once reached (the shortcuts fall back to it).
        public var isFallback: Bool { self == .relay || self == .tunnel }

        /// Lower is better: the link, the local network, then straight across the internet, then a fallback.
        public var rank: Int {
            switch self {
            case .link: -1
            case .lan: 0
            case .direct: 1
            case .relay, .tunnel: 2
            }
        }
    }

    /// The route's id (`YoyoRoute.id`): a backend tells its ways apart by it. Default `<kind>:<host>:<port>`.
    public var id: String
    public var kind: Kind
    /// For the stats line ("LAN", "direct"…; the host's words, the kits don't localize it).
    public var label: String
    /// The computer is on this phone's local network (the playout's tighter local values). Default: `kind == .lan`.
    public var isLocalNetwork: Bool
    /// Where it is reached: the host its server's certificate is checked for (nil: any).
    public var host: String?
    public var port: Int?
    public var trust: ConnectTrust
    /// What its requests authenticate with (a token, a ticket), if the backend wants changes of it noticed.
    public var credential: String?
    /// What the network report says about it. Default: `lan` for `lan`, `direct` for `direct` and `link`, `tunnel`
    /// otherwise.
    public var report: ScreenNetReport.Route

    public init(id: String? = nil, kind: Kind, host: String? = nil, port: Int? = nil, label: String? = nil,
                isLocalNetwork: Bool? = nil, trust: ConnectTrust = .system, credential: String? = nil,
                report: ScreenNetReport.Route? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.id = id ?? ([kind.rawValue] + [host, port.map(String.init)].compactMap { $0 }).joined(separator: ":")
        self.label = label ?? Self.defaultLabel(kind)
        self.isLocalNetwork = isLocalNetwork ?? (kind == .lan)
        self.trust = trust
        self.credential = credential
        self.report = report ?? Self.defaultReport(kind)
    }

    static func defaultLabel(_ kind: Kind) -> String {
        switch kind {
        case .lan: "LAN"
        case .direct: "direct"
        case .relay: "relay"
        case .tunnel: "tunnel"
        case .link: "link"
        }
    }

    static func defaultReport(_ kind: Kind) -> ScreenNetReport.Route {
        switch kind {
        case .lan: .lan
        case .direct, .link: .direct
        case .relay, .tunnel: .tunnel
        }
    }

    /// `https://<host>:<port>` (an IPv6 host in brackets); nil without both or with a port outside 1…65535.
    public var baseURL: URL? {
        guard let host, let port, (1...65535).contains(port) else { return nil }
        return URL(string: "https://\(host.contains(":") ? "[\(host)]" : host):\(port)")
    }

    /// The route the kits know it by. `shortcut`: there is a fallback to go back to when it fails (a fallback itself is
    /// never a shortcut).
    public func route(shortcut: Bool) -> YoyoRoute {
        YoyoRoute(id: id, isLocalNetwork: isLocalNetwork, isDirect: !kind.isFallback, isShortcut: shortcut && !kind.isFallback,
                  label: label, report: report)
    }

    /// Its trust for the kits' sessions: `trust` at `host`.
    public var yoyoTrust: YoyoTrust { trust.yoyoTrust(hosts: host.map { [$0] }) }
}

/// How a candidate's server is trusted.
public enum ConnectTrust: Sendable, Hashable {
    /// The system's evaluation (a certificate a CA vouches for).
    case system
    /// The leaf certificate's public key: "sha256:<hex>" of `SecKeyCopyExternalRepresentation` (the certificate may be
    /// renewed with the same key).
    case publicKey(String)
    /// The leaf certificate itself: "sha256:<hex>" of its DER.
    case certificate(String)

    /// Whether `trust` passes.
    public func evaluate(_ trust: SecTrust) -> Bool {
        switch self {
        case .system: SecTrustEvaluateWithError(trust, nil)
        case .publicKey(let fp): ConnectPin.matchesKey(trust: trust, fp)
        case .certificate(let fp): ConnectPin.matchesCertificate(trust: trust, fp)
        }
    }

    /// As the kits' `YoyoTrust`, for the hosts listed (nil: any host).
    public func yoyoTrust(hosts: Set<String>?) -> YoyoTrust {
        if case .system = self { return .system }
        let pin = self
        return .custom { trust, host in (hosts?.contains(host) ?? true) && pin.evaluate(trust) }
    }

    /// A session for requests to one candidate: ephemeral (no cache, no cookies), this trust at `hosts`, redirects not
    /// followed when pinned.
    public func session(hosts: Set<String>?, configure: (URLSessionConfiguration) -> Void = { _ in }) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.waitsForConnectivity = false
        configure(config)
        return URLSession(configuration: config, delegate: YoyoTrustDelegate(yoyoTrust(hosts: hosts)), delegateQueue: nil)
    }
}

/// SHA-256 fingerprints of a server's leaf certificate ("sha256:<hex>"; case, the prefix and colons between bytes don't
/// matter): of its public key, or of the whole certificate.
public enum ConnectPin {
    /// 64 lowercase hex digits, or nil when `fingerprint` isn't a SHA-256.
    public static func normalized(_ fingerprint: String) -> String? {
        var s = fingerprint.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("sha256:") { s.removeFirst("sha256:".count) }
        s.removeAll { $0 == ":" }
        guard s.count == 64, s.allSatisfy(\.isHexDigit), s.allSatisfy(\.isASCII) else { return nil }
        return s
    }

    /// "sha256:<hex>" of `der`.
    public static func fingerprint(der: Data) -> String {
        "sha256:" + SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// `der` hashes to `fingerprint`.
    public static func matches(der: Data, _ fingerprint: String) -> Bool {
        guard let want = normalized(fingerprint) else { return false }
        return normalized(Self.fingerprint(der: der)) == want
    }

    /// "sha256:<hex>" of the certificate's public key (`SecKeyCopyExternalRepresentation(SecCertificateCopyKey(_))`);
    /// nil when the key can't be had.
    public static func keyFingerprint(certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return fingerprint(der: data)
    }

    /// The leaf certificate of `trust` carries the pinned public key.
    public static func matchesKey(trust: SecTrust, _ fingerprint: String) -> Bool {
        guard let want = normalized(fingerprint), let leaf = leaf(of: trust),
              let have = keyFingerprint(certificate: leaf) else { return false }
        return normalized(have) == want
    }

    /// The leaf certificate of `trust` is the pinned one.
    public static func matchesCertificate(trust: SecTrust, _ fingerprint: String) -> Bool {
        guard let leaf = leaf(of: trust) else { return false }
        return matches(der: SecCertificateCopyData(leaf) as Data, fingerprint)
    }

    private static func leaf(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }
}
