#if os(macOS)
import Foundation

// A live drag (docs/PROTOCOL.md「输入」, `POST /input`): `down` presses the left button, `move` with
// `button: "left"` moves with it held, `up` lifts it. A phone that goes away mid-drag (the app killed, the network gone)
// would leave the Mac's button down, and the next click anywhere would drag instead. So every press is remembered per
// display, with how to lift it on the path that pressed it (CGEvent), and lifted:
//   - when nothing moved or lifted it for `timeout` (10 s; a log line says so);
//   - when the last open stream closes (nobody is looking any more);
//   - by the client when its control goes back to "none" (it sends `up`).
// An `up` that arrives on another path than the press lifts it on the pressing path too.

/// The pressed left buttons, by display. Thread-safe; `now` is injectable for tests (no timer then: call `expire`).
final class PointerHolds: @unchecked Sendable {
    /// Lifts the button at (x, y), normalized (best effort; never throws).
    typealias Release = @Sendable (_ x: Double, _ y: Double) -> Void

    struct Hold {
        /// Which injection path pressed it ("cg").
        var route: String
        var x: Double
        var y: Double
        /// The press, or the last held move.
        var lastActivity: Date
        var release: Release
    }

    static let shared = PointerHolds()

    /// A press with no held move or `up` for this long is lifted.
    static let defaultTimeout: TimeInterval = 10

    let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private let usesTimer: Bool
    private let lock = NSLock()
    // Guarded by `lock`:
    private var holds: [UInt32: Hold] = [:]
    private var openStreams = 0
    private var timer: DispatchSourceTimer?

    init(timeout: TimeInterval = PointerHolds.defaultTimeout, now: @escaping @Sendable () -> Date = { Date() },
         timer: Bool = true) {
        self.timeout = timeout
        self.now = now
        usesTimer = timer
    }

    /// `down` on `display` through `route`. A press already held there (a second `down`) is replaced (the new path
    /// lifts what it pressed; an older press on another path is lifted now).
    func pressed(display: UInt32, route: String, x: Double, y: Double, release: @escaping Release) {
        lock.lock()
        let previous = holds[display]
        holds[display] = Hold(route: route, x: x, y: y, lastActivity: now(), release: release)
        startTimerLocked()
        lock.unlock()
        if let previous, previous.route != route { previous.release(previous.x, previous.y) }
    }

    /// A held `move` on `display`: the press is alive, and where to lift it moved.
    func moved(display: UInt32, x: Double, y: Double) {
        lock.lock(); defer { lock.unlock() }
        guard var h = holds[display] else { return }
        h.x = x
        h.y = y
        h.lastActivity = now()
        holds[display] = h
    }

    /// `up` on `display` through `route`: forgets the press; when another path pressed it, lifts it there too.
    @discardableResult
    func released(display: UInt32, route: String, x: Double, y: Double) -> Hold? {
        lock.lock()
        let h = holds.removeValue(forKey: display)
        stopTimerIfIdleLocked()
        lock.unlock()
        if let h, h.route != route { h.release(x, y) }
        return h
    }

    func isHeld(_ display: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return holds[display] != nil
    }

    /// Lifts the presses idle for `timeout` (the timer calls it every half second); returns their displays.
    @discardableResult
    func expire() -> [UInt32] {
        let t = now()
        lock.lock()
        let due = holds.filter { t.timeIntervalSince($0.value.lastActivity) >= timeout }
        for d in due.keys { holds[d] = nil }
        stopTimerIfIdleLocked()
        lock.unlock()
        for (display, h) in due.sorted(by: { $0.key < $1.key }) {
            log("input: left button held on display \(display) for \(Int(timeout)) s without a move or up; releasing it (\(h.route))")
            h.release(h.x, h.y)
        }
        return due.keys.sorted()
    }

    /// Lifts every press (`why` for the log); returns their displays.
    @discardableResult
    func releaseAll(_ why: String) -> [UInt32] {
        lock.lock()
        let all = holds
        holds.removeAll()
        stopTimerIfIdleLocked()
        lock.unlock()
        for (display, h) in all.sorted(by: { $0.key < $1.key }) {
            log("input: \(why) with the left button held on display \(display); releasing it (\(h.route))")
            h.release(h.x, h.y)
        }
        return all.keys.sorted()
    }

    /// A `/stream` opened.
    func streamOpened() {
        lock.lock(); openStreams += 1; lock.unlock()
    }

    /// A `/stream` closed: the last one closing lifts what is still pressed (the phone that was dragging is gone).
    func streamClosed() {
        lock.lock()
        openStreams = max(0, openStreams - 1)
        let last = openStreams == 0 && !holds.isEmpty
        lock.unlock()
        if last { releaseAll("the last stream closed") }
    }

    private func startTimerLocked() {
        guard usesTimer, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.expire() }
        timer = t
        t.resume()
    }

    private func stopTimerIfIdleLocked() {
        guard holds.isEmpty, let t = timer else { return }
        timer = nil
        t.cancel()
    }
}
#endif
