#if os(macOS)
import CoreGraphics
import Foundation

// Scrolls posted as pixel CGEvents (the HID tap on the console), the way a trackpad's would come: evenly paced, in a
// phased two-finger gesture, with momentum after the fingers lift.
//
// The phone has at most one scroll request on its way (one round trip apart: ~15 ms on the LAN, 130–250 ms over the
// tunnel) and adds up the finger moves meanwhile. Each request's pixels used to go out in ≤ 8 steps 8 ms apart and
// then nothing until the next one: "move, stop, move", and ScreenCaptureKit saw the content change ~10 times a
// second. Without a phase the apps took it for an old wheel: no gesture, no momentum, a dead stop when the fingers
// lifted. Now every request's pixels are spread over about the time until the next one is expected, and with a
// `phase` they carry the gesture's scroll phase, and its `ended` the velocity that `ScrollMotion` scrolls on with on
// the Mac (UIScrollView's normal deceleration), frame by frame, with no further request.

/// The pacing, phases and momentum of one event stream's scrolls, as a value: requests come in through `submit`, the
/// events to post come out of `tick` (about 120 times a second while `nextWake` asks for it). Times are seconds on
/// any monotonic clock, passed in. Pixel deltas use the request's signs (positive `dy` = content further down; the
/// driver turns them into wheel deltas). No fraction is lost: the whole pixels emitted over a gesture add up to what
/// was asked, within one.
struct ScrollMotion {
    /// A request's place in a two-finger gesture (`POST /input`'s `phase`).
    enum Phase: String, Sendable { case began, changed, ended }

    /// `CGScrollPhase` (the event's `scrollWheelEventScrollPhase`); `none`: not part of a gesture.
    enum ScrollPhase: Int64, Sendable { case none = 0, began = 1, changed = 2, ended = 4 }

    /// `CGMomentumScrollPhase` (the event's `scrollWheelEventMomentumPhase`).
    enum MomentumPhase: Int64, Sendable { case none = 0, begin = 1, `continue` = 2, end = 3 }

    /// One scroll event to post: whole pixels (request signs), its phases, where (nil: where the pointer is), the
    /// modifiers held.
    struct Emit: Equatable, Sendable {
        var dx: Int
        var dy: Int
        var scrollPhase: ScrollPhase = .none
        var momentumPhase: MomentumPhase = .none
        var point: CGPoint?
        var flags: CGEventFlags = []
    }

    /// One gesture, measured (logged when it is over, momentum included).
    struct Summary: Sendable, CustomStringConvertible {
        var requests = 0
        /// Mean time between the gesture's requests (s); nil: one request.
        var meanInterval: Double?
        /// Pixels emitted while the fingers moved (request signs).
        var px = (x: 0, y: 0)
        /// From the first request to the `ended` event (s).
        var duration = 0.0
        /// Ended by `gestureTimeout` without an `ended` request (the phone went away), or by `interrupt`.
        var timedOut = false
        var interrupted = false
        /// The velocity at lift (pt/s, after the cap); nil: no `ended` request.
        var liftSpeed: Double?
        /// Momentum: its first velocity (pt/s), the pixels it scrolled and how long (s); nil: none.
        var momentumV0: Double?
        var momentumPx = (x: 0, y: 0)
        var momentumDuration = 0.0
        var momentumInterrupted = false

        var description: String {
            var s = "scroll gesture: \(requests) request\(requests == 1 ? "" : "s")"
            if let meanInterval { s += " every \(Int((meanInterval * 1000).rounded())) ms" }
            s += ", (\(px.x), \(px.y)) px in \(Int((duration * 1000).rounded())) ms"
            if timedOut { s += ", no ended request for \(Int(ScrollMotion.gestureTimeout)) s" }
            if interrupted { s += ", interrupted" }
            if let v0 = momentumV0 {
                s += "; momentum \(Int(v0.rounded())) pt/s → (\(momentumPx.x), \(momentumPx.y)) px in "
                    + "\(Int((momentumDuration * 1000).rounded())) ms\(momentumInterrupted ? " (interrupted)" : "")"
            } else if let liftSpeed {
                s += "; no momentum (\(Int(liftSpeed.rounded())) pt/s at lift)"
            }
            return s
        }
    }

    // MARK: Constants

    /// The driver's tick (120 Hz).
    static let tick: Double = 1.0 / 120
    /// Requests further apart than this start the interval afresh.
    static let idleAfter: Double = 0.5
    /// The pixels of a request with no interval yet (a gesture's first, one after a pause) go out within this.
    static let fastWindow: Double = 0.030
    /// Otherwise within this share of the expected interval, `tick`…`maxWindow`.
    static let windowShare = 0.9
    static let maxWindow: Double = 0.140
    /// The interval's smoothing: the newest gap's weight.
    static let intervalWeight = 0.3
    /// A gesture open this long without a request is ended (no momentum).
    static let gestureTimeout: Double = 3
    /// Momentum: from this speed at lift (pt/s), capped at `momentumMax`, until it is under `momentumStop`; the speed
    /// is multiplied by `deceleration` every millisecond (UIScrollView's `.normal`).
    static let momentumMin = 120.0
    static let momentumMax = 8000.0
    static let momentumStop = 20.0
    static let deceleration = 0.998

    // MARK: State

    private struct Vec: Equatable {
        var x = 0.0, y = 0.0
        static let zero = Vec()
        var isZero: Bool { x == 0 && y == 0 }
        var length: Double { hypot(x, y) }
    }

    private struct Gesture {
        var beganSent = false
        /// The `ended` request came: the velocity at lift (after the cap). The gesture ends once `remaining` is out.
        var ending: Vec?
        var lastRequest: Double
    }

    private struct Momentum {
        var v: Vec
        var begun = false
        var carry = Vec.zero
    }

    /// A gesture's numbers while it lasts.
    private struct Stats {
        var summary = Summary()
        var first: Double
        var lastPaced: Double
        var paced = 0
        var momentumStart = 0.0
    }

    /// Pixels asked for and not released yet; they all go by `deadline`.
    private var remaining = Vec.zero
    /// Released and not emitted yet (the sub-pixel part, |·| ≤ 0.5 after a tick).
    private var carry = Vec.zero
    private var deadline = 0.0
    /// The last tick (nil: idle, nothing being paced or decelerating).
    private var lastTick: Double?
    /// The last request that moved (for the interval) and the smoothed time between requests.
    private var lastArrival: Double?
    private(set) var interval: Double?
    private var point: CGPoint?
    private var flags: CGEventFlags = []
    private var gesture: Gesture?
    private var momentum: Momentum?
    private var stats: Stats?
    /// Events made outside a tick (a momentum ended by a new gesture, an interrupt): the next tick's first.
    private var pending: [Emit] = []
    /// Gestures that are over, oldest first (`takeSummaries`).
    private var finished: [Summary] = []

    init() {}

    /// Whether a gesture is open (its `ended` event not posted yet).
    var isGestureOpen: Bool { gesture != nil }
    /// Whether momentum is scrolling.
    var isDecelerating: Bool { momentum != nil }

    // MARK: Input

    /// A request: `dx` / `dy` (points, positive `dy` = content further down), its `phase` (nil: a plain scroll),
    /// on `ended` the velocity at lift (`vx` / `vy`, pt/s, same signs), where (nil: keep the last point) and the
    /// modifiers held.
    mutating func submit(dx: Double, dy: Double, phase: Phase?, vx: Double? = nil, vy: Double? = nil,
                         point: CGPoint?, flags: CGEventFlags = [], now: Double) {
        let d = Vec(x: dx.isFinite ? dx : 0, y: dy.isFinite ? dy : 0)
        if let point { self.point = point }
        self.flags = flags
        // a scroll that moves stops the momentum (fingers on the trackpad again); a stray `ended` does not
        if momentum != nil, phase != .ended, phase != nil || !d.isZero { endMomentum(now: now, interrupted: true) }
        switch phase {
        case nil:
            guard !d.isZero else { return }
            noteArrival(now: now, fresh: false)
            pace(d, now: now)
        case .began?, .changed?:
            if gesture == nil {
                gesture = Gesture(lastRequest: now)
                stats = Stats(first: now, lastPaced: now)
                carry = .zero
                noteArrival(now: now, fresh: true)
            } else if phase == .began {
                // the fingers came back before the last gesture was out: it goes on (no ended, no momentum)
                gesture?.ending = nil
                noteArrival(now: now, fresh: true)
            } else {
                noteArrival(now: now, fresh: false)
            }
            gesture?.lastRequest = now
            noteRequest(now: now, paced: true)
            pace(d, now: now)
        case .ended?:
            // nothing open: a gesture whose start was lost moves as a plain scroll; a bare `ended` is nothing
            guard gesture != nil else {
                if !d.isZero { noteArrival(now: now, fresh: false); pace(d, now: now) }
                return
            }
            var v = Vec(x: (vx ?? 0).isFinite ? vx ?? 0 : 0, y: (vy ?? 0).isFinite ? vy ?? 0 : 0)
            if v.length > Self.momentumMax { let k = Self.momentumMax / v.length; v = Vec(x: v.x * k, y: v.y * k) }
            gesture?.ending = v
            gesture?.lastRequest = now
            noteRequest(now: now, paced: false)
            if !d.isZero { pace(d, now: now) } else { wake(now: now) }
        }
    }

    /// Other pointer input on this path (a click, a press, a move): what is left of the scroll goes at once, an open
    /// gesture ends (no momentum), momentum stops — before that input goes out.
    mutating func interrupt(now: Double) {
        if !remaining.isZero || abs(carry.x) >= 0.5 || abs(carry.y) >= 0.5 {
            carry.x += remaining.x; carry.y += remaining.y
            remaining = .zero
            let n = takeCarry()
            if let g = gesture {
                if !g.beganSent || n.x != 0 || n.y != 0 { pending.append(make(n, g.beganSent ? .changed : .began)) }
                gesture?.beganSent = true
                stats?.summary.px.x += n.x; stats?.summary.px.y += n.y
            } else if n.x != 0 || n.y != 0 {
                pending.append(make(n, .none))
            }
        }
        if gesture != nil {
            if gesture?.beganSent == false { pending.append(make((0, 0), .began)) }
            pending.append(make((0, 0), .ended))
            stats?.summary.interrupted = true
            closeGesture(now: now, momentum: nil)
        }
        if momentum != nil { endMomentum(now: now, interrupted: true) }
        wake(now: now)
    }

    // MARK: Output

    /// The events due at `now`, in order.
    mutating func tick(now: Double) -> [Emit] {
        var out = pending
        pending = []
        let previous = lastTick ?? (now - Self.tick)
        let dt = max(0, now - previous)
        lastTick = now

        // momentum (it never runs alongside a gesture: a request stops it)
        if var m = momentum {
            let decay = pow(Self.deceleration, dt * 1000)
            // the distance of an exponentially slowing scroll over dt
            let k = dt > 0 ? (1 - decay) / (-log(Self.deceleration) * 1000) : 0
            m.carry.x += m.v.x * k; m.carry.y += m.v.y * k
            m.v = Vec(x: m.v.x * decay, y: m.v.y * decay)
            let n = (x: Int(m.carry.x.rounded()), y: Int(m.carry.y.rounded()))
            m.carry.x -= Double(n.x); m.carry.y -= Double(n.y)
            if !m.begun || n.x != 0 || n.y != 0 {
                out.append(make(n, .none, m.begun ? .continue : .begin))
                stats?.summary.momentumPx.x += n.x; stats?.summary.momentumPx.y += n.y
                m.begun = true
            }
            momentum = m
            if m.v.length < Self.momentumStop {
                out.append(make((0, 0), .none, .end))
                momentum = nil
                finishStats(momentumEnd: now)
            }
        }

        // pacing: what is left goes out linearly by the deadline
        if !remaining.isZero {
            let span = deadline - previous
            if span <= dt || span <= 0 {
                carry.x += remaining.x; carry.y += remaining.y
                remaining = .zero
            } else {
                let share = dt / span
                carry.x += remaining.x * share; carry.y += remaining.y * share
                remaining.x -= remaining.x * share; remaining.y -= remaining.y * share
            }
        }
        let n = takeCarry()
        if var g = gesture {
            if !g.beganSent || n.x != 0 || n.y != 0 {
                out.append(make(n, g.beganSent ? .changed : .began))
                g.beganSent = true
                stats?.summary.px.x += n.x; stats?.summary.px.y += n.y
            }
            gesture = g
            if remaining.isZero, let v = g.ending {
                out.append(make((0, 0), .ended))
                closeGesture(now: now, momentum: v)
            } else if remaining.isZero, g.ending == nil, now - g.lastRequest >= Self.gestureTimeout {
                out.append(make((0, 0), .ended))
                stats?.summary.timedOut = true
                closeGesture(now: now, momentum: nil)
            }
        } else if n.x != 0 || n.y != 0 {
            out.append(make(n, .none))
        }

        if nextWake(now: now) != now + Self.tick { lastTick = nil }
        return out
    }

    /// When to tick next: nil = nothing to do until a request comes.
    func nextWake(now: Double) -> Double? {
        if !pending.isEmpty || !remaining.isZero || momentum != nil { return now + Self.tick }
        if let g = gesture {
            if !g.beganSent || g.ending != nil { return now + Self.tick }
            return max(now, g.lastRequest + Self.gestureTimeout)
        }
        return nil
    }

    /// The gestures that are over since the last call (to log).
    mutating func takeSummaries() -> [Summary] {
        defer { finished = [] }
        return finished
    }

    // MARK: Internals

    private func make(_ n: (x: Int, y: Int), _ scroll: ScrollPhase, _ m: MomentumPhase = .none) -> Emit {
        Emit(dx: n.x, dy: n.y, scrollPhase: scroll, momentumPhase: m, point: point, flags: flags)
    }

    /// The whole pixels of `carry` (to the nearest), taken out of it.
    private mutating func takeCarry() -> (x: Int, y: Int) {
        let n = (x: Int(carry.x.rounded()), y: Int(carry.y.rounded()))
        carry.x -= Double(n.x); carry.y -= Double(n.y)
        return n
    }

    /// A request that moves: the interval learns the gap since the last one (`fresh`: starts afresh).
    private mutating func noteArrival(now: Double, fresh: Bool) {
        if !fresh, let last = lastArrival, now - last >= 0, now - last < Self.idleAfter {
            let gap = now - last
            interval = interval.map { (1 - Self.intervalWeight) * $0 + Self.intervalWeight * gap } ?? gap
        } else {
            interval = nil
        }
        lastArrival = now
    }

    private mutating func noteRequest(now: Double, paced: Bool) {
        guard var s = stats else { return }
        s.summary.requests += 1
        if paced {
            s.paced += 1
            s.lastPaced = now
            if s.paced > 1 { s.summary.meanInterval = (now - s.first) / Double(s.paced - 1) }
        }
        stats = s
    }

    /// `d` more to go out, with what is left, by a deadline set from now.
    private mutating func pace(_ d: Vec, now: Double) {
        remaining.x += d.x; remaining.y += d.y
        let window = interval.map { min(max(Self.windowShare * $0, Self.tick), Self.maxWindow) } ?? Self.fastWindow
        deadline = now + window
        wake(now: now)
    }

    /// Ticks resume from now (the first one releases one tick's share).
    private mutating func wake(now: Double) {
        if lastTick == nil { lastTick = now - Self.tick }
    }

    /// The `ended` event went out: momentum from `v` if fast enough.
    private mutating func closeGesture(now: Double, momentum v: Vec?) {
        gesture = nil
        if let first = stats?.first { stats?.summary.duration = now - first }
        if let v { stats?.summary.liftSpeed = v.length }
        if let v, v.length >= Self.momentumMin {
            momentum = Momentum(v: v)
            stats?.summary.momentumV0 = v.length
            stats?.momentumStart = now
        } else {
            finishStats(momentumEnd: nil)
        }
    }

    private mutating func endMomentum(now: Double, interrupted: Bool) {
        guard let m = momentum else { return }
        if m.begun {
            pending.append(make((0, 0), .none, .end))
        }
        momentum = nil
        if interrupted { stats?.summary.momentumInterrupted = true }
        finishStats(momentumEnd: now)
    }

    private mutating func finishStats(momentumEnd: Double?) {
        guard var s = stats else { return }
        if let momentumEnd { s.summary.momentumDuration = momentumEnd - s.momentumStart }
        finished.append(s.summary)
        stats = nil
    }
}

/// Posts one event stream's scrolls (`ScrollMotion`) as pixel CGEvents into `tap`: on its own serial queue, ticked by
/// a strict timer (timeouts are coalesced to ~20 ms under launchd, StrictTiming.swift) about 120 times a second while
/// there is work, idle otherwise. `hid`: the console's CGEvent path (`/input`); `session`: this login session's own
/// event stream.
final class ScrollSynth: @unchecked Sendable {
    static let session = ScrollSynth(tap: .cgSessionEventTap, name: "session")
    static let hid = ScrollSynth(tap: .cghidEventTap, name: "hid")

    /// The one posting into `tap`.
    static func `for`(_ tap: CGEventTapLocation) -> ScrollSynth { tap == .cgSessionEventTap ? session : hid }

    let name: String
    private let tap: CGEventTapLocation
    private let queue: DispatchQueue
    // on `queue`
    private var motion = ScrollMotion()
    private var timer: DispatchSourceTimer?
    /// Where the last scroll was (nil after other pointer input: the next scroll moves the pointer again).
    private var lastPoint: CGPoint?

    init(tap: CGEventTapLocation, name: String) {
        self.tap = tap
        self.name = name
        queue = DispatchQueue(label: "yoyo-scroll-\(name)", qos: .userInteractive)
    }

    private static func clock() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// A scroll request (`ScrollMotion.submit`), answered at once. `movePointer` runs first when the point changed
    /// since the last scroll, or the gesture begins (the pointer goes there before its events do).
    func submit(dx: Double, dy: Double, phase: ScrollMotion.Phase?, vx: Double?, vy: Double?, at point: CGPoint?,
                flags: CGEventFlags, movePointer: (CGPoint) throws -> Void) rethrows {
        try queue.sync {
            if let point, point != lastPoint || phase == .began {
                try movePointer(point)
                lastPoint = point
            }
            motion.submit(dx: dx, dy: dy, phase: phase, vx: vx, vy: vy, point: point, flags: flags, now: Self.clock())
            step()
        }
    }

    /// Other pointer input on this path is about to go out: the scroll's rest at once, momentum stopped, first.
    func interrupt() {
        queue.sync {
            lastPoint = nil
            guard motion.isGestureOpen || motion.isDecelerating || motion.nextWake(now: Self.clock()) != nil else { return }
            motion.interrupt(now: Self.clock())
            step()
        }
    }

    /// One tick: post what is due, log the gestures that ended, set the timer for the next.
    private func step() {
        let now = Self.clock()
        for e in motion.tick(now: now) { Self.post(e, tap: tap) }
        for s in motion.takeSummaries() { log("\(name) \(s)") }
        let timer = self.timer ?? makeTimer()
        if let wake = motion.nextWake(now: now) {
            timer.schedule(deadline: .now() + max(0, wake - now), leeway: .nanoseconds(0))
        } else {
            timer.schedule(deadline: .distantFuture, leeway: .nanoseconds(0))
        }
    }

    private func makeTimer() -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.setEventHandler { [weak self] in self?.step() }
        t.schedule(deadline: .distantFuture, leeway: .nanoseconds(0))
        t.resume()
        timer = t
        return t
    }

    static func post(_ e: ScrollMotion.Emit, tap: CGEventTapLocation) {
        // wheel deltas: positive = content moves down = see further up, so the request's signs flip
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(clamping: -e.dy), wheel2: Int32(clamping: -e.dx), wheel3: 0)
        else { return }
        if let p = e.point { event.location = p }
        event.flags = e.flags
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if e.scrollPhase != .none { event.setIntegerValueField(.scrollWheelEventScrollPhase, value: e.scrollPhase.rawValue) }
        if e.momentumPhase != .none {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: e.momentumPhase.rawValue)
        }
        event.post(tap: tap)
    }
}
#endif
