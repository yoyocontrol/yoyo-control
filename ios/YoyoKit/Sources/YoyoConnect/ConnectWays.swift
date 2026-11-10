import Foundation
import Network
import Synchronization
import YoyoCore

/// The ways of one backend to its computer, shared by the backend (any thread: which link a request on a route goes
/// through, how its server is trusted) and its `YoyoConnector` (main actor: which way is current). It starts with the
/// way requests go before anything better is found (`initial`) and knows the fallbacks the connector may go back to.
public final class ConnectWays<Link: Sendable>: Sendable {
    private struct Way {
        var candidate: ConnectCandidate
        var link: Link
        /// Which put this is (a way retired, then put again, isn't removed by the old retirement).
        var token: Int
    }

    private struct State {
        var ways: [String: Way] = [:]
        var current: ConnectCandidate
        var hosts: Set<String> = []
        var next = 0
        var closed = false
    }

    private let state: Mutex<State>
    /// The ways that always work once reached (`relay`, `tunnel`), in order: what a failing shortcut goes back to.
    public let fallbacks: [ConnectCandidate]
    /// A non-fallback way has somewhere to go back to (it's a shortcut, `YoyoRoute.isShortcut`).
    public let hasFallback: Bool

    /// `initial`: the way in use until something better is found, and its link. `fallbacks`: the fallback candidates
    /// the connector may reach when a shortcut fails (only fallback kinds are kept; `initial` counts when it is one).
    public init(initial: ConnectCandidate, link: Link, fallbacks: [ConnectCandidate] = []) {
        let fb = fallbacks.filter { $0.kind.isFallback && $0.id != initial.id }
        self.fallbacks = fb
        hasFallback = initial.kind.isFallback || !fb.isEmpty
        var s = State(current: initial)
        s.ways[initial.id] = Way(candidate: initial, link: link, token: 0)
        if let h = initial.host { s.hosts.insert(h) }
        state = Mutex(s)
    }

    /// The way requests go now.
    public var current: YoyoRoute { route(of: currentCandidate) }

    public var currentCandidate: ConnectCandidate { state.withLock { $0.current } }

    /// The current way's link (nil once closed).
    public var currentLink: Link? { state.withLock { s in s.ways[s.current.id]?.link } }

    /// The route the kits know `candidate` by.
    public func route(of candidate: ConnectCandidate) -> YoyoRoute { candidate.route(shortcut: hasFallback) }

    /// The link of `route` (nil: no such way any more).
    public func link(for route: YoyoRoute) -> Link? { state.withLock { $0.ways[route.id]?.link } }

    public func candidate(for route: YoyoRoute) -> ConnectCandidate? { state.withLock { $0.ways[route.id]?.candidate } }

    /// How the kits' sessions check the server on `route`: its candidate's trust at its host (`.system` for a route
    /// that isn't one of these ways).
    public func trust(for route: YoyoRoute) -> YoyoTrust { candidate(for: route)?.yoyoTrust ?? .system }

    /// Every host a way was held at (for one session shared by all ways).
    public var hosts: Set<String> { state.withLock { $0.hosts } }

    public var isClosed: Bool { state.withLock { $0.closed } }

    // MARK: The connector's

    /// Adds (or replaces) a way, making it current when `current`. nil when closed (the link is the caller's to
    /// release); else the link it replaced, if any.
    func put(_ candidate: ConnectCandidate, link: Link, current: Bool) -> (token: Int, replaced: Link?)? {
        state.withLock { s in
            guard !s.closed else { return nil }
            s.next += 1
            let replaced = s.ways[candidate.id]?.link
            s.ways[candidate.id] = Way(candidate: candidate, link: link, token: s.next)
            if let h = candidate.host { s.hosts.insert(h) }
            if current { s.current = candidate }
            return (s.next, replaced)
        }
    }

    func token(of id: String) -> Int? { state.withLock { $0.ways[id]?.token } }

    /// Makes the way of `id` current (false: there's none).
    @discardableResult
    func setCurrent(_ id: String) -> Bool {
        state.withLock { s in
            guard let w = s.ways[id] else { return false }
            s.current = w.candidate
            return true
        }
    }

    /// The best fallback way held (the earliest of `fallbacks`, else `initial` when it is one).
    func heldFallback() -> ConnectCandidate? {
        state.withLock { s in
            let held = s.ways.values.map(\.candidate).filter(\.kind.isFallback)
            for f in fallbacks { if let c = held.first(where: { $0.id == f.id }) { return c } }
            return held.first
        }
    }

    /// Removes the way of `id` put as `token`, unless it is current; its link (the caller releases it).
    func remove(_ id: String, token: Int) -> Link? {
        state.withLock { s in
            guard s.current.id != id, let w = s.ways[id], w.token == token else { return nil }
            s.ways[id] = nil
            return w.link
        }
    }

    /// No more ways (the page is gone): every link held, to release. `current` stays what it was.
    public func close() -> [Link] {
        state.withLock { s in
            s.closed = true
            let links = s.ways.values.map(\.link)
            s.ways = [:]
            return links
        }
    }
}

/// What of the network path decides which candidates are worth a try: online at all (any interface: a `direct`
/// candidate, 5G too), and the phone's Wi-Fi / wired interfaces (a `lan` one), whichever interface iOS sends its
/// internet traffic through: with Wi-Fi Assist (weak Wi-Fi) or a Wi-Fi without internet the default path is cellular
/// while the computer on the same Wi-Fi is still a few ms away (an address of that subnet goes out on the Wi-Fi).
public struct ConnectPath: Sendable, Equatable {
    public var online: Bool
    /// The phone's Wi-Fi / wired interfaces, in use for the default path or not (sorted; none when offline).
    public var localInterfaces: [String]

    public init(online: Bool, localInterfaces: [String]) {
        self.online = online
        self.localInterfaces = online ? localInterfaces.sorted() : []
    }

    /// A `lan` candidate is worth a try.
    public var hasLocal: Bool { online && !localInterfaces.isEmpty }

    /// What counts as "it changed": online or not, and the Wi-Fi / wired interfaces. Not the default path's interface
    /// or gateways: those flip with Wi-Fi Assist while the local network stays as good as it was.
    public var signature: String { "\(online)|\(localInterfaces.joined(separator: ","))" }

    public static func of(_ path: NWPath) -> ConnectPath {
        ConnectPath(online: path.status == .satisfied,
                    localInterfaces: path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }.map(\.name))
    }

    /// Before the path monitor answered: everything may be tried.
    public static let assumed = ConnectPath(online: true, localInterfaces: ["?"])
}
