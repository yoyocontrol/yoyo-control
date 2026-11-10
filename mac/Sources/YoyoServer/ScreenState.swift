#if os(macOS)
import CoreGraphics
import Foundation

// Screen connection state (docs/PROTOCOL.md 「屏幕」「连接状态」): what each display's picture is doing right now, as
// codes (phase + reason) that a client turns into its own text. Published three ways: `GET /status` (`states`,
// `console`), `GET /events` (NDJSON, a line on every change) and, for a `/stream?status=1`, status
// parts on the stream itself (StreamStatus.swift).
//
// One entry: the main display (`main: true`; its id is the current main display's). Its pictures come from
// ScreenCaptureKit: ready, or unavailable with no-session / no-permission. `console` is the Mac's console as
// ConsoleWatcher last settled it (whether it is locked: a locked console's picture is the lock screen).
// `since` changes only when phase / reason change; a publish happens only when something differs.

enum ScreenPhase: String, Sendable {
    case connecting, reconnecting, ready, unavailable
}

/// Why the phase is what it is (an open set on the wire; these are the helper's).
enum ScreenStateReason: String, Sendable {
    case starting
    case noSession = "no-session"
    case noPermission = "no-permission"
}

/// One display's state (`ScreenDisplayState` in docs/PROTOCOL.md).
struct ScreenDisplayState: Equatable, Sendable {
    var display: CGDirectDisplayID
    var main = false
    var phase: ScreenPhase
    var reason: ScreenStateReason?
    /// ms since 1970: when this phase + reason began.
    var since: Double = 0
    /// English, technical (logs / debug overlays only).
    var detail: String?

    var json: [String: Any] {
        var out: [String: Any] = ["display": Int(display), "phase": phase.rawValue, "since": Int64(since.rounded())]
        if main { out["main"] = true }
        if let reason { out["reason"] = reason.rawValue }
        if let detail { out["detail"] = detail }
        return out
    }

    /// Phase and reason: what `since` dates.
    fileprivate func sameEpisode(_ o: ScreenDisplayState) -> Bool {
        phase == o.phase && reason == o.reason
    }
}

/// Everything the states are computed from (gathered by `ScreenService`; set directly in tests).
struct ScreenStateInputs: Equatable, Sendable {
    var loggedIn = true
    var screenRecording = true
    var mainDisplay: CGDirectDisplayID = 1
    /// ConsoleWatcher's settled state (nil: not read yet).
    var console: ConsoleState?
}

/// Inputs → states, with `since` bookkeeping. Pure: the time comes in as an argument.
struct ScreenStateCore: Sendable {
    /// The main display's entry.
    private(set) var states: [ScreenDisplayState] = []
    /// The ScreenCaptureKit path's state for the main display (the status parts of a stream it serves).
    private(set) var capture = ScreenDisplayState(display: 0, phase: .connecting, reason: .starting)
    private(set) var console: ConsoleState?
    /// The last state, for `since`.
    private var last: ScreenDisplayState?

    /// Recompute. true = the states or the console changed (`since` alone never changes without them).
    @discardableResult
    mutating func update(_ i: ScreenStateInputs, now: Date) -> Bool {
        let ms = (now.timeIntervalSince1970 * 1000).rounded()
        let before = (states, console)
        var cap = Self.captureState(i)
        cap.display = i.mainDisplay
        cap.main = true
        if let prev = last, prev.sameEpisode(cap) { cap.since = prev.since } else { cap.since = ms }
        last = cap
        capture = cap
        states = [cap]
        console = i.console
        return before.0 != states || before.1 != console
    }

    /// The ScreenCaptureKit path: a GUI login and Screen Recording.
    static func captureState(_ i: ScreenStateInputs) -> ScreenDisplayState {
        if !i.loggedIn { return ScreenDisplayState(display: 0, phase: .unavailable, reason: .noSession, detail: "no GUI login session for this macOS user") }
        if !i.screenRecording {
            return ScreenDisplayState(display: 0, phase: .unavailable, reason: .noPermission,
                                      detail: "Screen Recording permission is not granted to \(ScreenHost.appName)")
        }
        return ScreenDisplayState(display: 0, phase: .ready)
    }
}

/// The published states: recomputed on every console change (`setNeedsRefresh`, off the caller's thread) and every
/// `pollInterval` (a permission granted, the main display changing), deduplicated, then fanned out to `/events`
/// subscribers (`waitForChange`) and the stream status parts. One per service (`current`).
/// `@unchecked Sendable`: `cond` guards the published fields; `computeLock` serializes recomputes (never taken while
/// `cond` is held).
final class ScreenStateTracker: @unchecked Sendable {
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var _current: ScreenStateTracker?
    static var current: ScreenStateTracker? {
        currentLock.lock(); defer { currentLock.unlock() }; return _current
    }

    static let pollInterval: TimeInterval = 0.5

    private let clock: @Sendable () -> Date
    private let cond = NSCondition()
    private let computeLock = NSLock()
    private let queue = DispatchQueue(label: "yoyo-control-state", qos: .userInitiated)
    // Guarded by `cond`:
    private var inputs: (@Sendable () -> ScreenStateInputs)?
    private var onPublish: (@Sendable () -> Void)?
    private var states: [ScreenDisplayState] = []
    private var capture = ScreenDisplayState(display: 0, phase: .ready)
    private var console: ConsoleState?
    private var _version: UInt64 = 0
    /// Bumped with `_version` on every published state change, but not by `noteSideChange`: `/events` writes a state
    /// line only when this moved.
    private var _stateVersion: UInt64 = 0
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var refreshQueued = false
    // Guarded by `computeLock`:
    private var core = ScreenStateCore()

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Where the inputs come from, and who to tell after a change.
    func configure(inputs: @escaping @Sendable () -> ScreenStateInputs, onPublish: (@Sendable () -> Void)? = nil) {
        cond.lock(); self.inputs = inputs; self.onPublish = onPublish; cond.unlock()
    }

    /// Poll (the first computation at once, on the tracker's queue: the caller may hold the locks the inputs take) and
    /// register as `current`. Idempotent.
    func start() {
        cond.lock()
        guard timer == nil else { cond.unlock(); return }
        stopped = false
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.refresh() }
        timer = t
        cond.unlock()
        Self.currentLock.lock(); Self._current = self; Self.currentLock.unlock()
        t.resume()
    }

    /// Stop polling; `/events` subscribers end (`waitForChange` returns nil).
    func stop() {
        cond.lock()
        stopped = true
        let t = timer
        timer = nil
        cond.broadcast()
        cond.unlock()
        t?.cancel()
        Self.currentLock.lock(); if Self._current === self { Self._current = nil }; Self.currentLock.unlock()
    }

    var isStopped: Bool { cond.lock(); defer { cond.unlock() }; return stopped }

    /// Something changed: recompute soon, on the tracker's queue (coalesced). Any thread, any lock held but `cond`'s.
    func setNeedsRefresh() {
        cond.lock()
        let queued = refreshQueued
        refreshQueued = true
        cond.unlock()
        guard !queued else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.cond.lock(); self.refreshQueued = false; self.cond.unlock()
            self.refresh()
        }
    }

    /// Recompute now on the caller's thread (a stream about to write a status part). Holds no lock of the caller's.
    func refresh() {
        cond.lock()
        let inputs = self.inputs
        cond.unlock()
        guard let inputs else { return }
        computeLock.lock()
        let i = inputs()
        let changed = core.update(i, now: clock())
        let (states, capture, console) = (core.states, core.capture, core.console)
        computeLock.unlock()
        publish(states: states, capture: capture, console: console, changed: changed)
    }

    /// Tests: compute from `inputs` directly.
    func update(_ i: ScreenStateInputs) {
        computeLock.lock()
        let changed = core.update(i, now: clock())
        let (states, capture, console) = (core.states, core.capture, core.console)
        computeLock.unlock()
        publish(states: states, capture: capture, console: console, changed: changed)
    }

    private func publish(states: [ScreenDisplayState], capture: ScreenDisplayState, console: ConsoleState?, changed: Bool) {
        cond.lock()
        self.capture = capture
        guard changed || _version == 0 else { cond.unlock(); return }
        self.states = states
        self.console = console
        _version &+= 1
        _stateVersion &+= 1
        let notify = onPublish
        cond.broadcast()
        cond.unlock()
        notify?()
    }

    /// Bumped on every published change, and by `noteSideChange`.
    var version: UInt64 { cond.lock(); defer { cond.unlock() }; return _version }

    /// Something else `/events` reports changed (the clipboard, Clipboard.swift): wakes `waitForChange` without a new
    /// state (`stateVersion` stays). Any thread.
    func noteSideChange() {
        cond.lock()
        _version &+= 1
        cond.broadcast()
        cond.unlock()
    }

    /// One-off `/events` lines (`{"type":"abort",…}`, Automation.swift), numbered; the last few kept for subscribers
    /// still writing the previous change. Guarded by `cond`.
    private var posted: [(seq: UInt64, line: Data)] = []
    private var _postedSeq: UInt64 = 0
    static let postedKept = 32

    /// Write `line` (one NDJSON line, newline included) to every `/events` subscriber connected now. Any thread.
    func post(_ line: Data) {
        cond.lock()
        _postedSeq &+= 1
        posted.append((_postedSeq, line))
        if posted.count > Self.postedKept { posted.removeFirst(posted.count - Self.postedKept) }
        _version &+= 1
        cond.broadcast()
        cond.unlock()
    }

    /// The number of the last posted line (a new subscriber starts after it).
    var postedSeq: UInt64 { cond.lock(); defer { cond.unlock() }; return _postedSeq }

    /// The posted lines after `seq`, oldest first.
    func posted(after seq: UInt64) -> [(seq: UInt64, line: Data)] {
        cond.lock(); defer { cond.unlock() }
        return posted.filter { $0.seq > seq }
    }

    var snapshot: (states: [ScreenDisplayState], console: ConsoleState?, version: UInt64, stateVersion: UInt64) {
        cond.lock(); defer { cond.unlock() }
        return (states, console, _version, _stateVersion)
    }

    /// The main entry, else the main display's ScreenCaptureKit state (a service without one yet).
    func mainState() -> (state: ScreenDisplayState, console: ConsoleState?) {
        cond.lock(); defer { cond.unlock() }
        return (states.first { $0.main } ?? capture, console)
    }

    /// The ScreenCaptureKit path's state (for a stream it serves).
    func captureState() -> (state: ScreenDisplayState, console: ConsoleState?) {
        cond.lock(); defer { cond.unlock() }
        return (capture, console)
    }

    /// Block until the version moves past `after` or `deadline`. nil = stopped.
    func waitForChange(after: UInt64, until deadline: Date) -> UInt64? {
        cond.lock(); defer { cond.unlock() }
        while !stopped, _version == after, Date() < deadline { _ = cond.wait(until: deadline) }
        return stopped ? nil : _version
    }

    /// One `/events` line: `{"type":"state","states":[…],"console":{…}|null}`.
    static func eventLine(states: [ScreenDisplayState], console: ConsoleState?) -> Data {
        let body: [String: Any] = ["type": "state", "states": states.map(\.json), "console": console?.json ?? NSNull()]
        var data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{\"type\":\"state\"}".utf8)
        data.append(10)
        return data
    }

    static let pingLine = Data("{\"type\":\"ping\"}\n".utf8)
}
#endif
