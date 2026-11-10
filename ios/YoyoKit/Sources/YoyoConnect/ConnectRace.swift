import Foundation
import Synchronization
import YoyoCore

/// What came of probing one candidate.
public enum ConnectProbe<Link: Sendable>: Sendable {
    /// It answered: what requests on it go through (a session, a base URL, a forwarder…). `as`: the candidate that
    /// answered, when the one probed stood for several (all of a computer's local addresses, say); default the one probed.
    case reached(Link, as: ConnectCandidate? = nil)
    /// It answered 401: the credential isn't (or no longer) known there.
    case unauthorized
    /// Nothing answered (in time, with the trusted certificate).
    case unreachable
}

/// Why a `YoyoConnector` asks its source for candidates.
public enum ConnectRefresh: Sendable, Equatable {
    /// A new race: what the source holds will do.
    case held
    /// What it held failed (nothing reached, a 401) or is about to expire, or none of it is usable here: ask anew.
    case stale
    /// A 401 on the way in use: a fresh credential.
    case unauthorized
    /// The way in use's credential expires soon (`ConnectSupply.expires`): renew it.
    case renew
}

/// The candidates a source gives.
public struct ConnectSupply: Sendable {
    /// The shortcuts (`lan` / `direct`); fallbacks are the `ConnectWays`'.
    public var candidates: [ConnectCandidate]
    /// Just asked for, not held from before: a race failing with them isn't asked again at once.
    public var fresh: Bool
    /// When their credential expires: renewed `ConnectPolicy.renewBefore` it while one of them is in use, and asked
    /// anew instead of raced when held that close to it.
    public var expires: Date?

    public init(candidates: [ConnectCandidate], fresh: Bool, expires: Date? = nil) {
        self.candidates = candidates
        self.fresh = fresh
        self.expires = expires
    }
}

/// What a `YoyoConnector` does on the network, from its host.
public struct ConnectSource<Link: Sendable>: Sendable {
    /// The candidates now. nil: the computer has no other way (no more races this visit); a throw: couldn't ask now
    /// (tried again after `retryInterval`).
    public var candidates: @Sendable (_ why: ConnectRefresh) async throws -> ConnectSupply?
    /// Probes one candidate (a fallback too). Cancelled when another wins.
    public var probe: @Sendable (_ candidate: ConnectCandidate) async -> ConnectProbe<Link>
    /// A link no longer in use (a probe that won too late, a way left behind, the page closed).
    public var release: @Sendable (_ link: Link) -> Void
    /// Returns true when a link in use stopped working by itself (a connection's session ended: a uu Link one); the
    /// connector then leaves its way and races again. false at once: this link doesn't end by itself (requests on it
    /// fail instead). nil: none do.
    public var ended: (@Sendable (_ link: Link) async -> Bool)?

    public init(candidates: @escaping @Sendable (_ why: ConnectRefresh) async throws -> ConnectSupply?,
                probe: @escaping @Sendable (_ candidate: ConnectCandidate) async -> ConnectProbe<Link>,
                release: @escaping @Sendable (_ link: Link) -> Void = { _ in },
                ended: (@Sendable (_ link: Link) async -> Bool)? = nil) {
        self.candidates = candidates
        self.probe = probe
        self.release = release
        self.ended = ended
    }
}

/// What a failed request on a shortcut means for the route.
public enum ConnectFailure: Sendable, Equatable {
    /// The computer's own answer (bad request, not the controller, no such display…): the other way would give it too,
    /// so the request isn't sent again and the way is kept.
    case answer
    /// 401 on the way: its credential isn't known (any more).
    case unauthorized
    /// The link or the server in front of it (no connection, a timeout, TLS, a 5xx…): back to the fallback.
    case link

    /// The default: another phone holding control, a `YoyoError` that isn't an HTTP status, and 400 / 403 / 404 / 409 /
    /// 413 are answers; `YoyoError.http(401, _)` is `.unauthorized` (`YoyoError.unauthorized` is the host's credential,
    /// passed on); anything else (other statuses, the transport's errors) is the link.
    public static func classify(_ error: Error) -> ConnectFailure {
        if error is ScreenControlledElsewhere { return .answer }
        guard let e = error as? YoyoError else { return .link }
        guard case .http(let code, _) = e else { return .answer }
        switch code {
        case 401: return .unauthorized
        case 400, 403, 404, 409, 413: return .answer
        default: return .link
        }
    }
}

/// How a `YoyoConnector` races and moves.
public struct ConnectPolicy: Sendable {
    /// Happy eyeballs: when each kind's probes start after a race begins, relative to the best kind present (so with
    /// no `lan` candidate the `direct` ones start at once). A `link` candidate starts 250 ms ahead of the others (they
    /// start only when it isn't reached by then; `linkGrace`).
    public var offsets: [ConnectCandidate.Kind: Duration] = [
        .link: .milliseconds(-250), .lan: .zero, .direct: .milliseconds(150), .relay: .milliseconds(300),
        .tunnel: .milliseconds(300),
    ]
    /// A `link` candidate reached within this long of its race's start still becomes the way when another one won
    /// meanwhile (the stream moves to it); later, it is let go and tried again after `retryInterval`. While it may
    /// still win, a stream about to open waits for it (`decisionWait`).
    public var linkGrace: Duration = .milliseconds(1500)
    /// A stream about to open while a race may give a better way waits this long for it (`YoyoRouting.decisionWait`).
    public var decisionWait: Duration = .milliseconds(600)
    /// A stream on a shortcut whose response hasn't come by then counts as failed there.
    public var openTimeout: Duration = .seconds(3)
    /// After a race that left a better way untried or unreached, or a failure on a shortcut, the next race waits this
    /// long; while on a worse way than the network allows, races run this often.
    public var retryInterval: Duration = .seconds(30)
    /// Acks lost in a row on a shortcut that make it fail.
    public var ackFailuresToLeave = 3
    /// A credential is renewed this long before it expires.
    public var renewBefore: Duration = .seconds(10 * 60)
    /// After a change of network path, the race waits this long for it to settle.
    public var pathSettle: Duration = .milliseconds(300)
    /// A shortcut left behind keeps its link this long (a request may still be on it, e.g. a release of control).
    public var keepRetired: Duration = .seconds(5)
    /// What a failed request on a shortcut means.
    public var classify: @Sendable (Error) -> ConnectFailure = ConnectFailure.classify

    public init() {}
}

/// Racing candidates happy-eyeballs style: each kind starts at its offset, the first to be reached wins, the rest are
/// cancelled (and a link reached too late is released).
public enum ConnectRace {
    public enum Outcome<Link: Sendable>: Sendable {
        case reached(Link, ConnectCandidate)
        /// None reached, one answered 401.
        case unauthorized
        case unreachable
    }

    /// When each candidate starts: ordered by its kind's offset (then as given), relative to the earliest.
    public static func plan(_ candidates: [ConnectCandidate], offsets: [ConnectCandidate.Kind: Duration])
        -> [(candidate: ConnectCandidate, delay: Duration)] {
        let start = candidates.map { offsets[$0.kind] ?? .zero }.min() ?? .zero
        return candidates.enumerated()
            .sorted { (offsets[$0.element.kind] ?? .zero, $0.offset) < (offsets[$1.element.kind] ?? .zero, $1.offset) }
            .map { ($0.element, max((offsets[$0.element.kind] ?? .zero) - start, .zero)) }
    }

    /// The first of `candidates` to be reached. `sequential`: one after another in the plan's order (the next only
    /// when the one before failed) instead of the offsets. Returns as soon as one is reached (the others are cancelled,
    /// not waited for); cancelling the caller cancels them all.
    public static func first<Link: Sendable>(_ candidates: [ConnectCandidate], offsets: [ConnectCandidate.Kind: Duration],
                                             sequential: Bool = false,
                                             probe: @escaping @Sendable (ConnectCandidate) async -> ConnectProbe<Link>,
                                             release: @escaping @Sendable (Link) -> Void) async -> Outcome<Link> {
        let plan = plan(candidates, offsets: offsets)
        guard !plan.isEmpty else { return .unreachable }
        if sequential {
            var unauthorized = false
            for (c, _) in plan {
                if Task.isCancelled { break }
                switch await probe(c) {
                case .reached(let link, let reached):
                    if Task.isCancelled {
                        release(link)
                        return .unreachable
                    }
                    return .reached(link, reached ?? c)
                case .unauthorized: unauthorized = true
                case .unreachable: break
                }
            }
            return unauthorized ? .unauthorized : .unreachable
        }
        let race = Race<Link>(count: plan.count, release: release)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Outcome<Link>, Never>) in
                race.wait(cont)
                for (c, delay) in plan {
                    race.add(Task {
                        if delay > .zero { try? await Task.sleep(for: delay) }
                        if Task.isCancelled {
                            race.finish(c, .unreachable)
                            return
                        }
                        race.finish(c, await probe(c))
                    })
                }
            }
        } onCancel: {
            race.cancel()
        }
    }

    /// One race's state, from any thread.
    private final class Race<Link: Sendable>: Sendable {
        private struct State {
            var cont: CheckedContinuation<Outcome<Link>, Never>?
            var tasks: [Task<Void, Never>] = []
            var pending: Int
            var unauthorized = false
            var done = false
            var outcome: Outcome<Link>?
        }

        private let state: Mutex<State>
        private let release: @Sendable (Link) -> Void

        init(count: Int, release: @escaping @Sendable (Link) -> Void) {
            state = Mutex(State(pending: count))
            self.release = release
        }

        func wait(_ cont: CheckedContinuation<Outcome<Link>, Never>) {
            let ready: Outcome<Link>? = state.withLock { s in
                if let o = s.outcome { return o }
                s.cont = cont
                return nil
            }
            if let ready { cont.resume(returning: ready) }
        }

        func add(_ task: Task<Void, Never>) {
            let done = state.withLock { s in
                if !s.done { s.tasks.append(task) }
                return s.done
            }
            if done { task.cancel() }
        }

        func finish(_ candidate: ConnectCandidate, _ probe: ConnectProbe<Link>) {
            let (cont, outcome, cancel, late): (CheckedContinuation<Outcome<Link>, Never>?, Outcome<Link>?, [Task<Void, Never>], Link?) =
                state.withLock { s in
                    s.pending -= 1
                    if s.done {
                        if case .reached(let link, _) = probe { return (nil, nil, [], link) }
                        return (nil, nil, [], nil)
                    }
                    var outcome: Outcome<Link>?
                    switch probe {
                    case .reached(let link, let reached): outcome = .reached(link, reached ?? candidate)
                    case .unauthorized: s.unauthorized = true
                    case .unreachable: break
                    }
                    if outcome == nil, s.pending == 0 { outcome = s.unauthorized ? .unauthorized : .unreachable }
                    guard let outcome else { return (nil, nil, [], nil) }
                    s.done = true
                    s.outcome = outcome
                    let tasks = s.tasks
                    s.tasks = []
                    let c = s.cont
                    s.cont = nil
                    return (c, outcome, tasks, nil)
                }
            if let late { release(late) }
            for t in cancel { t.cancel() }
            if let cont, let outcome { cont.resume(returning: outcome) }
        }

        func cancel() {
            let (cont, tasks): (CheckedContinuation<Outcome<Link>, Never>?, [Task<Void, Never>]) = state.withLock { s in
                guard !s.done else { return (nil, []) }
                s.done = true
                s.outcome = .unreachable
                let t = s.tasks
                s.tasks = []
                let c = s.cont
                s.cont = nil
                return (c, t)
            }
            for t in tasks { t.cancel() }
            cont?.resume(returning: .unreachable)
        }
    }
}
