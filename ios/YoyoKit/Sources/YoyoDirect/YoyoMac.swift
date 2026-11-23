import Foundation
import Network
import YoyoConnect
import YoyoCore

/// A Mac this phone paired with (docs/REMOTE.md「配对」): who it is (`id` = its server id), the key it is pinned to,
/// this phone's token for it, and its uu Link binding (how it is reached, docs/LINK.md). The app keeps it in the
/// keychain.
public struct YoyoMac: Codable, Sendable, Equatable, Identifiable {
    /// The Mac's `serverId`.
    public let id: String
    public var name: String
    /// IPv4 addresses on its local network (the pairing code's), hints for the link next to the binding's own.
    public var addresses: [String]
    /// "sha256:<hex>" of the Mac's identity key (RemoteIdentity on the Mac).
    public let fingerprint: String
    public let token: String
    /// What kind of computer it is (`server.platform` at pairing, `/status`'s `platform`: "mac", "linux", …): nil
    /// when it never said (a Mac).
    public var platform: String?
    /// Its uu Link binding as it last said (the pairing code's, `/status`'s `link`, the signaling server's): nil in a
    /// record from before the code carried it (asked for at the signaling server). Checked against `fingerprint`
    /// before every dial.
    public var link: ConnectLinkBinding?

    public init(id: String, name: String, addresses: [String] = [], fingerprint: String, token: String,
                platform: String? = nil, link: ConnectLinkBinding? = nil) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.fingerprint = fingerprint
        self.token = token
        self.platform = platform
        self.link = link
    }

    /// The computer's platform (not said: a Mac).
    public var computerPlatform: YoyoPlatform { platform.map(YoyoPlatform.init(rawValue:)) ?? .mac }

    /// "192.168.1.5" or "192.168.1.5 + 2 more", for the list.
    public var addressSummary: String {
        guard let first = addresses.first else { return "" }
        return addresses.count > 1 ? "\(first) + \(addresses.count - 1)" : first
    }

    /// The link's hints: its local addresses on the binding's port (`ip:port`).
    var linkHints: [String] {
        guard let port = link?.port else { return [] }
        return addresses.compactMap { ConnectLinkBinding.socketAddress(host: $0, port: port) }
    }
}

/// The pairing QR code's URL: `yoyocontrol://pair?v=2&id=&n=&fp=&l=&lk=&ls=[&lp=][&a=]&c=` (docs/REMOTE.md「配对」).
public struct YoyoInvite: Sendable, Equatable {
    public let id: String
    public let name: String
    /// The Mac's local IPv4 addresses (`a`).
    public let addresses: [String]
    public let fingerprint: String
    public let code: String
    /// The uu Link binding (`l` hex id, `lk` / `ls` base64url identity key and signature, `lp` UDP port): checked
    /// against `fingerprint` before it is dialed.
    public let link: ConnectLinkBinding

    /// An invitation from its parts (docs/ACCOUNT.md「批准」: a code another phone asked the computer for, the computer
    /// as the account's directory and the signaling server have it).
    public init(id: String, name: String, addresses: [String] = [], fingerprint: String, code: String, link: ConnectLinkBinding) {
        self.id = id
        self.name = name
        self.addresses = addresses
        self.fingerprint = fingerprint
        self.code = code
        self.link = link
    }

    /// A computer of the phone's account as the account server lists it (docs/ACCOUNT.md): its Link id, name, relays
    /// and addresses, and what it said of itself (`info`: `{ id, platform, fp, link: { id, key, sig, port } }`, the
    /// Mac's and the Linux server's). nil when `info` doesn't say how to reach it (an older computer). No code: a
    /// ticket goes in instead (`YoyoClient.admit`).
    public init?(accountComputer linkId: String, name: String, relays: [String], direct: [String], info: [String: Any]) {
        guard let serverId = info["id"] as? String, !serverId.isEmpty, let fp = info["fp"] as? String, fp.hasPrefix("sha256:"),
              let l = info["link"] as? [String: Any], let id = l["id"] as? String, id == linkId,
              let key = l["key"] as? String, let sig = l["sig"] as? String else { return nil }
        let port = (l["port"] as? Int).flatMap { UInt16(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil }
        self.init(id: serverId, name: name, fingerprint: fp, code: "",
                  link: ConnectLinkBinding(id: id, key: key, sig: sig, port: port, relays: relays, direct: direct))
    }

    public init?(url: URL) {
        guard url.scheme == "yoyocontrol", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard value("v") == "2", let id = value("id"), let code = value("c"), let fp = value("fp"), fp.hasPrefix("sha256:"),
              let l = value("l"), let key = value("lk").map(Self.base64), let sig = value("ls").map(Self.base64) else { return nil }
        self.id = id
        name = value("n") ?? "Mac"
        // dotted IPv4 only (what the Mac lists): anything else in a scanned code is dropped
        addresses = (value("a") ?? "").split(separator: ",").map(String.init).filter { IPv4Address($0) != nil }
        fingerprint = fp
        self.code = code
        link = ConnectLinkBinding(id: l, key: key, sig: sig, port: value("lp").flatMap { UInt16($0) }.flatMap { $0 > 0 ? $0 : nil })
    }

    /// base64url (no padding) → base64.
    static func base64(_ url64: String) -> String {
        var s = url64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return s
    }
}
