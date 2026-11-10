import Foundation
import YoyoConnect
import YoyoCore
import YoyoLinkClient

/// The way to a Mac: a uu Link session (docs/LINK.md). Requests go over it as RPC, the Screen page's media on it.
struct DirectLink: Sendable {
    let connection: YoyoLinkConnection

    /// The session's path is on the local network now.
    var onLocalNetwork: Bool { connection.isLocalNetwork }

    func release() { connection.close() }

    /// Returns when the session ended by itself (`ConnectSource.ended`).
    func ended() async -> Bool {
        await connection.ended()
        return true
    }
}

/// The way one Screen page reaches a Mac, shared by the backend (the session its requests go over) and the page's
/// routing (a `YoyoConnector` over `DirectConnect`): one link session at a time, a new one when it ends. Thread-safe.
final class DirectWays: @unchecked Sendable {
    let connect: ConnectWays<DirectLink>
    /// Whether a path off the local network may be used (Pro, `RemoteAccess`).
    let pro: Bool
    private let lock = NSLock()
    private var _mac: YoyoMac

    init(mac: YoyoMac, pro: Bool, link: DirectLink) {
        _mac = mac
        self.pro = pro
        connect = ConnectWays(initial: DirectConnect.link(mac, onLan: link.onLocalNetwork), link: link)
    }

    var mac: YoyoMac {
        lock.lock()
        defer { lock.unlock() }
        return _mac
    }

    func updateMac(_ m: YoyoMac) {
        lock.lock()
        _mac = m
        lock.unlock()
    }

    var current: YoyoRoute { connect.current }

    /// The page is gone: the session ends.
    func close() {
        for link in connect.close() { link.release() }
    }

    /// The link session of `route` (the current one's for nil; nil: none now).
    func connection(for route: YoyoRoute? = nil) -> YoyoLinkConnection? {
        connect.link(for: route ?? current)?.connection
    }
}

/// What the routing does on the network, as a closure (tests replace it).
struct DirectProbes: Sendable {
    /// A link session to the Mac (its binding checked against its pin, `Bearer <token>` in `hello`); `pro`: whether
    /// a path off the local network counts.
    var link: @Sendable (YoyoMac, _ pro: Bool) async -> YoyoClient.Dialed

    static let live = DirectProbes(link: { await YoyoClient.dial($0, pro: $1) })
}

/// Yoyo Control's one candidate for YoyoConnect: the Mac's link session, whatever its path (the stats line says it).
enum DirectConnect {
    static let linkId = "link"

    /// How the page's routing races and moves: YoyoConnect's defaults (a stream waits 600 ms for a try; 30 s between
    /// tries).
    static let policy = ConnectPolicy()

    /// The Mac's link session. `onLan`: its path is on the local network now (the playout's local values).
    static func link(_ mac: YoyoMac, onLan: Bool = false) -> ConnectCandidate {
        ConnectCandidate(id: linkId, kind: .link, label: "link", isLocalNetwork: onLan, trust: .publicKey(mac.fingerprint),
                         report: onLan ? .lan : .direct)
    }

    static func probe(mac: YoyoMac, pro: Bool, probes: DirectProbes) async -> ConnectProbe<DirectLink> {
        switch await probes.link(mac, pro) {
        case .reached(let l): .reached(l, as: link(mac, onLan: l.onLocalNetwork))
        case .unauthorized: .unauthorized
        case .needsPro, .unreachable: .unreachable
        }
    }

    /// The page's candidate and probe.
    static func source(ways: DirectWays, probes: DirectProbes) -> ConnectSource<DirectLink> {
        ConnectSource(
            candidates: { _ in ConnectSupply(candidates: [link(ways.mac)], fresh: true) },
            probe: { _ in await probe(mac: ways.mac, pro: ways.pro, probes: probes) },
            release: { $0.release() },
            ended: { await $0.ended() })
    }
}
