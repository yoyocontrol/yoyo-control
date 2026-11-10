import Foundation
import Network
import Synchronization
import YoyoCore

/// A `YoyoRouting` over candidate ways to one computer (ios/README.md「YoyoConnect」), for one visit of the Screen
/// page: the backend supplies candidates and probes them (`ConnectSource`), this decides which way is current and the
/// page moves its stream and sound with it.
///
/// - **Races**, happy eyeballs (`ConnectPolicy.offsets`: `lan` at once, `direct` 150 ms later): when the page shows,
///   when a stream is about to open, every `retryInterval` while on a worse way than the network allows, and after a
///   change of network path. Only candidates better than the current way race (all of them after a path change that
///   lost the way in use). The first reached becomes current. A stream about to open waits up to `decisionWait` for a
///   race that may move it off a fallback.
/// - **Network path** (`ConnectPath`): `lan` candidates need a Wi-Fi / wired interface (in use for the default path or
///   not: Wi-Fi Assist), `direct` ones any network. Losing an interface (or going offline) leaves a shortcut at once;
///   gaining one races for something better from where the page is.
/// - **Shortcuts** (a non-fallback way while the ways have a fallback): their stream failing, `ackFailuresToLeave` acks
///   lost in a row, or a request failing on the link (`ConnectPolicy.classify`) goes back to the fallback at once (the
///   request is sent again there, so an input is late, not lost), reaching it first when none is held; then no race for
///   `retryInterval`.
/// - **Credentials**: a held supply is asked anew once when racing it reached nothing (or it is about to expire); a 401
///   on the way in use goes to the fallback and races a fresh supply at once, once (an ack that gets through allows it
///   again; a second 401 is a failure). While on a shortcut whose supply `expires`, it is renewed `renewBefore` that; a
///   renewal that no longer lists the way in use goes back to the fallback and races again.
/// - A source that answers nil (the computer has no other way) turns races off for the visit (`newVisit` on again);
///   `setShortcutsAllowed(false)` turns them off until turned on (a computer that can't have them).
/// - **Link** (`linkPossible`: the source may give a `.link` candidate, a uu Link session): it is better than every
///   other way, so races try for it from any of them (and again every `retryInterval` while on another). It starts
///   alone; the others start `ConnectPolicy.offsets` later (250 ms) only if it isn't reached by then, and one of them
///   reached first is taken meanwhile while the link may still win within `linkGrace` (the stream moves to it). A
///   stream about to open waits for a link race (`isDeciding`). A link in use outlives a change of network that stays
///   online (Wi-Fi ↔ cellular: it moves its own paths), with no race; coming back online races. A link whose session ends (`ConnectSource.ended`) is
///   left at once: the fallback when one is held, and a race of everything again.
@MainActor
public final class YoyoConnector<Link: Sendable>: YoyoRouting {
    public let ways: ConnectWays<Link>
    public let policy: ConnectPolicy
    private let source: ConnectSource<Link>

    public var onChange: (@MainActor () -> Void)?
    public var decisionWait: Duration { policy.decisionWait }
    public var openTimeout: Duration { policy.openTimeout }
    public var current: YoyoRoute { ways.current }
    /// A race (or the settling before one) that may move the page off its fallback, or onto the link, is on its way.
    public var isDeciding: Bool {
        guard (racing != nil || settling != nil) && raceWaits else { return false }
        return currentKind.isFallback || currentEnded || (linkRacing && currentKind != .link)
    }

    /// Off: the host watches the path itself (`pathUpdated`), or tests.
    public var watchesPath = true
    /// Shortcuts may be raced and used (`setShortcutsAllowed`).
    public private(set) var shortcutsAllowed = true
    /// The source has candidates (it hasn't answered nil this visit).
    public private(set) var supported = true
    /// The network path as last seen.
    public private(set) var path = ConnectPath.assumed
    /// The source may give a `.link` candidate (the computer has uu Link and the host wants it): races try for it from
    /// any other way. Set by the host before `activate`.
    public var linkPossible = false

    private var active = false
    private var closed = false
    private var attempt = 0
    private var racing: Task<Void, Never>?
    private var raceWaits = false
    private var settling: Task<Void, Never>?
    /// No race before this (a failure's, or a race's `retryInterval`); nil: one may start now.
    private var nextTry: ContinuousClock.Instant?
    private var renewAt: ContinuousClock.Instant?
    private var renewing: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var reachingFallback: Task<ConnectCandidate?, Never>?
    private var lostAcks = 0
    /// A 401 on the way in use already got a fresh supply.
    private var reissued = false
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    /// The race in progress has a link candidate that may still win.
    private var linkRacing = false
    /// The way in use is a link whose session ended, with no fallback to go to: any candidate may replace it.
    private var currentEnded = false

    public init(ways: ConnectWays<Link>, source: ConnectSource<Link>, policy: ConnectPolicy = ConnectPolicy()) {
        self.ways = ways
        self.source = source
        self.policy = policy
    }

    isolated deinit {
        racing?.cancel()
        settling?.cancel()
        timer?.cancel()
        renewing?.cancel()
        reachingFallback?.cancel()
        pathMonitor?.cancel()
    }

    // MARK: YoyoRouting

    public func newVisit() {
        supported = true
        nextTry = nil
        reissued = false
        lostAcks = 0
    }

    public func activate() {
        guard !closed else { return }
        active = true
        startPathMonitor()
        tryBetter(wait: true)
        schedule()
    }

    public func streamWillOpen() {
        tryBetter(wait: true)
    }

    /// The page stopped: races, timers and the path monitor stop; a shortcut in use goes back to a fallback held (its
    /// link kept `keepRetired` for a last request), so the way is chosen afresh when the page shows again.
    public func leave() {
        active = false
        cancelRace()
        timer?.cancel()
        timer = nil
        renewing?.cancel()
        renewing = nil
        renewAt = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        pathSignature = nil
        if !currentKind.isFallback, let fb = ways.heldFallback() { move(to: fb) }
        changed()
    }

    public func streamFailed(on route: YoyoRoute, unauthorized: Bool) {
        guard route.id == current.id, current.isShortcut else { return }
        if unauthorized { self.unauthorized() } else { failed() }
    }

    public func ackAnswered(on route: YoyoRoute, status: Int?) {
        guard route.id == current.id, current.isShortcut else { return }
        if status == 401 {
            unauthorized()
            return
        }
        // an HTTP answer below 500 is the computer's: the link works (404: the stream is gone, not the way)
        if let status, status < 500 {
            lostAcks = 0
            reissued = false
            return
        }
        lostAcks += 1
        if lostAcks >= policy.ackFailuresToLeave { failed() }
    }

    public func fallback(from route: YoyoRoute, after error: Error) async -> YoyoRoute? {
        guard route.isShortcut, ways.hasFallback else { return nil }
        switch policy.classify(error) {
        case .answer: return nil
        case .unauthorized: if route.id == current.id { unauthorized() }
        case .link: if route.id == current.id { failed() }
        }
        return await reachFallback().map(ways.route(of:))
    }

    // MARK: The host's

    /// Whether shortcuts may be used (a computer that can't have them: off). Off leaves a shortcut in use; on races at
    /// the next chance.
    public func setShortcutsAllowed(_ on: Bool) {
        guard on != shortcutsAllowed else { return }
        shortcutsAllowed = on
        if on {
            nextTry = nil
            tryBetter(wait: true)
        } else {
            cancelRace()
            if !currentKind.isFallback { demote() }
        }
        schedule()
        changed()
    }

    /// The page is gone for good: everything stops and every link is released.
    public func close() {
        leave()
        closed = true
        for link in ways.close() { source.release(link) }
    }

    /// A change of network path (the connector's own monitor's, or the host's with `watchesPath` off; before
    /// `activate` it only says what the first races may try).
    public func pathUpdated(_ new: ConnectPath) {
        guard active else {
            path = new
            return
        }
        let first = pathSignature == nil
        guard new.signature != pathSignature else { return }
        pathSignature = new.signature
        let old = path
        path = new
        // a link moves between interfaces itself (its paths): only going offline loses it
        let onLink = currentKind == .link && !currentEnded
        let removed = !first && !Set(old.localInterfaces).isSubset(of: Set(new.localInterfaces)) && !onLink
        let lost = !new.online || removed || !usableHere(ways.currentCandidate)
        // the first answer only says which races may start (a race on its way keeps going when it may)
        if first, !lost, old.online == new.online, old.hasLocal == new.hasLocal { return }
        // online before and after, on a live link: nothing better to race for (racing would dial a second session)
        if !first, onLink, old.online, new.online {
            changed()
            return
        }
        cancelRace()
        if lost, current.isShortcut { demote() }
        nextTry = nil
        if new.online {
            raceWaits = true
            let settle = policy.pathSettle
            // the way in use may be gone, or (nothing to fall back to) it's the one way: any candidate may replace it
            let anyRank = lost || !ways.hasFallback
            settling = Task { [weak self] in
                try? await Task.sleep(for: settle)
                guard !Task.isCancelled, let self else { return }
                self.settling = nil
                self.tryBetter(wait: true, anyRank: anyRank)
            }
        }
        schedule()
        changed()
    }

    // MARK: Racing

    private var currentKind: ConnectCandidate.Kind { ways.currentCandidate.kind }

    /// The best kind worth a race on this network (nil: none).
    private var bestRankHere: Int? {
        guard shortcutsAllowed, supported, path.online else { return nil }
        if linkPossible { return ConnectCandidate.Kind.link.rank }
        return path.hasLocal ? 0 : 1
    }

    private var canImprove: Bool { bestRankHere.map { currentEnded || $0 < currentKind.rank } ?? false }

    private func usableHere(_ c: ConnectCandidate) -> Bool {
        switch c.kind {
        case .lan: path.hasLocal
        case .direct, .link: path.online
        case .relay, .tunnel: true
        }
    }

    /// The shortcuts of `candidates` worth a race now: usable on this network and better than the way in use
    /// (`anyRank`: any, the way in use may be gone).
    private func raceable(_ candidates: [ConnectCandidate], anyRank: Bool) -> [ConnectCandidate] {
        let rank = currentKind.rank
        return candidates.filter { !$0.kind.isFallback && usableHere($0) && (anyRank || $0.kind.rank < rank) }
    }

    /// Starts a race when one may start (one at a time). `wait`: a stream about to open waits for it.
    private func tryBetter(wait: Bool, reason: ConnectRefresh = .held, anyRank: Bool = false) {
        guard active, !closed else { return }
        let anyRank = anyRank || currentEnded
        if racing != nil {
            if wait, !raceWaits {
                raceWaits = true
                changed()
            }
            return
        }
        guard shortcutsAllowed, supported, path.online, anyRank || canImprove else { return }
        if let nextTry, ContinuousClock.now < nextTry { return }
        settling?.cancel()
        settling = nil
        attempt += 1
        let a = attempt
        raceWaits = wait
        racing = Task { [weak self] in await self?.race(a, reason: reason, anyRank: anyRank) }
        changed()
    }

    private func race(_ a: Int, reason first: ConnectRefresh, anyRank: Bool) async {
        var reason = first
        for round in 0..<2 {
            let answer: ConnectSupply?
            do {
                answer = try await source.candidates(reason)
            } catch {
                guard a == attempt else { return }
                break
            }
            guard a == attempt else { return }
            guard let supply = answer else {
                supported = false
                break
            }
            let held = !supply.fresh
            let expiring = supply.expires.map { $0.timeIntervalSinceNow < policy.renewBefore.inSeconds } ?? false
            let candidates = held && expiring ? [] : raceable(supply.candidates, anyRank: anyRank)
            if !candidates.isEmpty {
                let (outcome, interim) = await reach(candidates, attempt: a, supply: supply)
                guard a == attempt, active else {
                    if case .reached(let link, _) = outcome { source.release(link) }
                    return
                }
                if case .reached(let link, let c) = outcome {
                    take(c, link: link, supply: supply)
                    break
                }
                // another way was reached while the link raced on (and became the way): that's this race's result
                if interim { break }
            }
            // what was held didn't do (nothing reached, nothing usable here, about to expire): asked anew once
            guard held, round == 0 else { break }
            reason = .stale
        }
        racing = nil
        raceWaits = false
        linkRacing = false
        nextTry = .now + policy.retryInterval
        schedule()
        changed()
    }

    /// The first of `candidates` reached (`ConnectRace.first`); with a link among them, the link alone first, then the
    /// others too after its head start (`ConnectPolicy.offsets`). One of the others reached first is taken at once
    /// (`interim`) while the link may still be reached within `linkGrace` of the start: then the link is the outcome
    /// (and the way moves on to it). Cancelling the race cancels every probe.
    private func reach(_ candidates: [ConnectCandidate], attempt a: Int,
                       supply: ConnectSupply) async -> (outcome: ConnectRace.Outcome<Link>, interim: Bool) {
        let (offsets, source, grace) = (policy.offsets, source, policy.linkGrace)
        let links = candidates.filter { $0.kind == .link }
        let others = candidates.filter { $0.kind != .link }
        guard !links.isEmpty else {
            return (await ConnectRace.first(candidates, offsets: offsets, probe: source.probe, release: source.release), false)
        }
        let started = ContinuousClock.now
        linkRacing = true
        changed()
        defer { linkRacing = false }
        let linkTask = Task { await ConnectRace.first(links, offsets: offsets, probe: source.probe, release: source.release) }
        let othersBox = TaskBox<ConnectRace.Outcome<Link>>()
        return await withTaskCancellationHandler {
            guard !others.isEmpty else { return (await linkTask.value, false) }
            // the link alone for its head start
            let linkAt = offsets[.link] ?? .zero
            let head = max((others.map { offsets[$0.kind] ?? .zero }.min() ?? .zero) - linkAt, .zero)
            if let early = await Await.value(linkTask, orAfter: head) {
                if case .reached = early { return (early, false) }
                return (await ConnectRace.first(others, offsets: offsets, probe: source.probe, release: source.release), false)
            }
            let othersRace = Task { await ConnectRace.first(others, offsets: offsets, probe: source.probe, release: source.release) }
            othersBox.set(othersRace)
            if Task.isCancelled { othersRace.cancel() }
            let (isLink, outcome) = await Await.either(linkTask, othersRace)
            if isLink {
                guard case .reached = outcome else { return (await othersRace.value, false) }
                othersRace.cancel()
                return (outcome, false)
            }
            guard case .reached(let link, let c) = outcome else { return (await linkTask.value, false) }
            // another way first: it is the way now, and the link may still win within its grace
            guard a == attempt, active else { return (outcome, false) }
            take(c, link: link, supply: supply)
            if let late = await Await.value(linkTask, until: started + grace), case .reached = late { return (late, false) }
            linkTask.cancel()
            Task {
                if case .reached(let l, _) = await linkTask.value { source.release(l) }
            }
            return (.unreachable, true)
        } onCancel: {
            linkTask.cancel()
            othersBox.cancel()
        }
    }

    /// `candidate` was reached: it becomes the way in use.
    private func take(_ candidate: ConnectCandidate, link: Link, supply: ConnectSupply) {
        guard shortcutsAllowed, usableHere(candidate) else {
            source.release(link)
            return
        }
        let old = ways.currentCandidate
        if old == candidate, !currentEnded {
            // the way in use, as it is: keep its link
            source.release(link)
        } else {
            guard let put = ways.put(candidate, link: link, current: true) else {
                source.release(link)
                return
            }
            if let replaced = put.replaced { retire(link: replaced) }
            if old.id != candidate.id, !old.kind.isFallback { retire(old.id) }
            watchEnd(of: candidate.id, token: put.token, link: link)
        }
        currentEnded = false
        lostAcks = 0
        renewAt = supply.expires.map(renewDeadline)
        changed()
    }

    /// `renewBefore` the expiry, and no sooner than `retryInterval` (a credential that is always about to expire isn't
    /// renewed in a loop).
    private func renewDeadline(_ expires: Date) -> ContinuousClock.Instant {
        .now + .seconds(max(expires.timeIntervalSinceNow - policy.renewBefore.inSeconds, policy.retryInterval.inSeconds))
    }

    private func cancelRace() {
        attempt += 1
        racing?.cancel()
        racing = nil
        settling?.cancel()
        settling = nil
        raceWaits = false
    }

    /// A link that may end by itself (`ConnectSource.ended`): its way is left when it does.
    private func watchEnd(of id: String, token: Int, link: Link) {
        guard let ended = source.ended else { return }
        Task { [weak self] in
            guard await ended(link) else { return }
            self?.wayEnded(id, token: token)
        }
    }

    /// The link of a way ended by itself: the way goes (its link released); when it was the way in use, the fallback
    /// (one held, else reached; with none it stays the way, marked ended, until something replaces it), and a race at
    /// once (of every candidate when the way in use is gone; now, or when the page shows again).
    private func wayEnded(_ id: String, token: Int) {
        guard !closed, ways.token(of: id) == token else { return }
        if ways.currentCandidate.id == id {
            lostAcks = 0
            renewAt = nil
            if let fb = ways.heldFallback() { move(to: fb) } else if ways.hasFallback { demote() }
            currentEnded = ways.currentCandidate.id == id
        }
        if let link = ways.remove(id, token: token) { source.release(link) }
        cancelRace()
        nextTry = nil
        tryBetter(wait: true)
        schedule()
        changed()
    }

    // MARK: Failures

    /// Something failed on the shortcut in use: the fallback, and no race for `retryInterval`.
    private func failed() {
        guard current.isShortcut else { return }
        nextTry = .now + policy.retryInterval
        demote()
        schedule()
        changed()
    }

    /// A 401 on the shortcut in use: the fallback, and a race of a fresh supply at once (once).
    private func unauthorized() {
        guard current.isShortcut else { return }
        if reissued {
            failed()
            return
        }
        reissued = true
        demote()
        cancelRace()
        nextTry = nil
        tryBetter(wait: true, reason: .unauthorized, anyRank: true)
        schedule()
    }

    /// Back to the fallback: one held at once, else the fallbacks are reached first (the shortcut stays meanwhile).
    private func demote() {
        lostAcks = 0
        renewAt = nil
        renewing?.cancel()
        renewing = nil
        guard !currentKind.isFallback else { return }
        if let fb = ways.heldFallback() {
            move(to: fb)
            return
        }
        guard !ways.fallbacks.isEmpty else { return }
        let from = ways.currentCandidate.id
        Task { [weak self] in
            guard let self, let fb = await self.reachFallback(), self.ways.currentCandidate.id == from else { return }
            self.move(to: fb)
            self.schedule()
        }
    }

    /// A fallback held, or the first of the fallbacks reached (put next to the way in use, not current).
    private func reachFallback() async -> ConnectCandidate? {
        if let fb = ways.heldFallback() { return fb }
        if let reaching = reachingFallback { return await reaching.value }
        guard !closed, !ways.fallbacks.isEmpty else { return nil }
        let (fallbacks, offsets, source, ways) = (ways.fallbacks, policy.offsets, source, ways)
        let task = Task { () -> ConnectCandidate? in
            let outcome = await ConnectRace.first(fallbacks, offsets: offsets, probe: source.probe, release: source.release)
            guard case .reached(let link, let c) = outcome else { return nil }
            guard ways.put(c, link: link, current: false) != nil else {
                source.release(link)
                return nil
            }
            return c
        }
        reachingFallback = task
        let fb = await task.value
        reachingFallback = nil
        return fb
    }

    private func move(to candidate: ConnectCandidate) {
        let old = ways.currentCandidate
        guard old.id != candidate.id, ways.setCurrent(candidate.id) else { return }
        currentEnded = false
        if !old.kind.isFallback { retire(old.id) }
        changed()
    }

    /// A way left behind keeps its link `keepRetired` (a request may still be on it), then lets it go.
    private func retire(_ id: String) {
        guard let token = ways.token(of: id) else { return }
        let (ways, source, keep) = (ways, source, policy.keepRetired)
        Task {
            try? await Task.sleep(for: keep)
            if let link = ways.remove(id, token: token) { source.release(link) }
        }
    }

    private func retire(link: Link) {
        let (source, keep) = (source, policy.keepRetired)
        Task {
            try? await Task.sleep(for: keep)
            source.release(link)
        }
    }

    // MARK: Renewal and timers

    private func renew() {
        let from = ways.currentCandidate
        let source = source
        renewing = Task { [weak self] in
            var result: Result<ConnectSupply?, Error>
            do { result = .success(try await source.candidates(.renew)) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self else { return }
            self.renewing = nil
            guard self.ways.currentCandidate.id == from.id else { return }
            switch result {
            case .failure:
                self.renewAt = .now + self.policy.retryInterval
            case .success(nil):
                self.supported = false
                self.demote()
            case .success(let supply?):
                if supply.candidates.contains(from) {
                    self.renewAt = supply.expires.map(self.renewDeadline)
                } else {
                    // another credential, address or certificate: back to the fallback, and a race with it
                    self.demote()
                    self.nextTry = nil
                    self.tryBetter(wait: true, anyRank: true)
                }
            }
            self.schedule()
            self.changed()
        }
    }

    /// Wakes up for the next race (`nextTry`, while a better way is possible) or renewal.
    private func schedule() {
        timer?.cancel()
        timer = nil
        guard active, !closed else { return }
        var next: ContinuousClock.Instant?
        if racing == nil, settling == nil, canImprove, let nextTry { next = nextTry }
        if current.isShortcut, renewing == nil, let renewAt { next = min(next ?? renewAt, renewAt) }
        guard let next else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(until: next, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.fire()
        }
    }

    private func fire() {
        let now = ContinuousClock.now
        if let renewAt, now >= renewAt, current.isShortcut, renewing == nil {
            self.renewAt = nil
            renew()
        }
        if let nextTry, now >= nextTry { tryBetter(wait: false) }
        schedule()
    }

    private func changed() { onChange?() }

    // MARK: The network path

    private func startPathMonitor() {
        guard pathMonitor == nil, watchesPath else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] p in
            let state = ConnectPath.of(p)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pathUpdated(state) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "yoyokit.connect.path", qos: .utility))
        pathMonitor = monitor
    }
}

/// The first of a few results, from any thread (later ones are dropped).
private final class FirstOf<T: Sendable>: Sendable {
    private let state = Mutex<(cont: CheckedContinuation<T, Never>?, value: T?)>((nil, nil))

    func offer(_ value: T) {
        let cont = state.withLock { s -> CheckedContinuation<T, Never>? in
            guard s.value == nil else { return nil }
            s.value = value
            defer { s.cont = nil }
            return s.cont
        }
        cont?.resume(returning: value)
    }

    func wait() async -> T {
        await withCheckedContinuation { cont in
            let ready = state.withLock { s -> T? in
                if let v = s.value { return v }
                s.cont = cont
                return nil
            }
            if let ready { cont.resume(returning: ready) }
        }
    }

}

private enum Await {
    /// `task`'s value, or nil when `wait` passes first (the task goes on).
    static func value<V: Sendable>(_ task: Task<V, Never>, orAfter wait: Duration) async -> V? {
        await value(task, until: .now + wait)
    }

    static func value<V: Sendable>(_ task: Task<V, Never>, until deadline: ContinuousClock.Instant) async -> V? {
        let f = FirstOf<V?>()
        Task { f.offer(await task.value) }
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            f.offer(nil)
        }
        defer { timer.cancel() }
        return await f.wait()
    }

    /// Which of two tasks finished first (true: `a`), and its value.
    static func either<V: Sendable>(_ a: Task<V, Never>, _ b: Task<V, Never>) async -> (Bool, V) {
        let f = FirstOf<(Bool, V)>()
        Task { f.offer((true, await a.value)) }
        Task { f.offer((false, await b.value)) }
        return await f.wait()
    }
}

/// A task set later, cancellable from any thread (also before it is set: it is cancelled as it comes).
private final class TaskBox<V: Sendable>: Sendable {
    private let state = Mutex<(task: Task<V, Never>?, cancelled: Bool)>((nil, false))

    func set(_ task: Task<V, Never>) {
        if state.withLock({ s -> Bool in s.task = task; return s.cancelled }) { task.cancel() }
    }

    func cancel() {
        state.withLock { s -> Task<V, Never>? in s.cancelled = true; return s.task }?.cancel()
    }
}

extension Duration {
    /// Seconds, as a `Double`.
    var inSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
