#if os(macOS)
import Foundation

/// Who controls the screen, as far as this service knows (docs/REMOTE.md「控制权」): nobody, or one paired phone
/// (`POST /control`). The unix socket's clients (whatever they relay: their own phones, automation) carry no identity here, so they
/// are not a controller: their `/input` goes through while no phone holds control, and is a 409
/// `controlled-elsewhere` while one does. A phone always gets control when it asks (the latest taker holds it); its
/// input is accepted only while it holds it. Control is released after `idle` without input, when the holder lets go,
/// is removed, or the Mac's menu disconnects it. Every change is an `/events` line `{"type":"control",…}`.
public final class RemoteControl: @unchecked Sendable {
    public static let shared = RemoteControl()
    /// A phone that stopped touching the screen lets go after this.
    public static let defaultIdle: TimeInterval = 10 * 60
    static let controlledElsewhere = "controlled-elsewhere"

    public struct Holder: Equatable, Sendable {
        public let id: String
        public let name: String
        public let since: Date
    }

    private let lock = NSLock()
    private var _holder: Holder?
    private var lastActivity = Date.distantPast
    private var idleTimer: DispatchWorkItem?
    let idle: TimeInterval
    private let now: () -> Date
    /// Called (outside the lock) after every change, with the new holder; besides the `/events` line.
    public var onChange: ((Holder?) -> Void)?
    /// More listeners of every change (the link sessions' `control` messages), by token.
    private var observers: [Int: (Holder?) -> Void] = [:]
    private var nextObserver = 0
    /// Lifts held buttons when control changes hands (PointerHolds); replaced in tests.
    var liftHeldButtons: (String) -> Void = { PointerHolds.shared.releaseAll($0) }

    init(idle: TimeInterval = defaultIdle, now: @escaping () -> Date = Date.init) {
        self.idle = idle
        self.now = now
    }

    public var holder: Holder? {
        lock.lock(); defer { lock.unlock() }
        return _holder
    }

    /// `/status`'s and the `/events` line's `control`.
    var json: [String: Any] {
        guard let h = holder else { return ["controller": "none"] }
        return ["controller": "remote", "since": h.since.timeIntervalSince1970 * 1000, "device": ["id": h.id, "name": h.name]]
    }

    // MARK: Changes

    /// The phone takes control (from nobody or from another phone). Counts as activity.
    func take(_ device: RemoteDevice) {
        lock.lock()
        lastActivity = now()
        if let h = _holder, h.id == device.id {
            if h.name != device.name { _holder = Holder(id: h.id, name: device.name, since: h.since) }
            armIdleLocked()
            lock.unlock()
            return
        }
        let previous = _holder
        _holder = Holder(id: device.id, name: device.name, since: now())
        armIdleLocked()
        let new = _holder
        lock.unlock()
        changed(new, previous: previous, why: "control taken by \(device.name)")
    }

    /// The phone lets go (only its own control: another's release changes nothing).
    func release(_ device: RemoteDevice) {
        release(where: { $0.id == device.id }, why: "control released by \(device.name)")
    }

    /// The holder is let go whoever it is (the Mac's menu, remote access turned off). false when nobody held it.
    @discardableResult
    public func releaseAny(why: String) -> Bool {
        release(where: { _ in true }, why: why)
    }

    /// That device was removed: it loses control if it held it.
    func deviceRemoved(_ id: String) {
        release(where: { $0.id == id }, why: "the controlling device was removed")
    }

    @discardableResult
    private func release(where match: (Holder) -> Bool, why: String) -> Bool {
        lock.lock()
        guard let h = _holder, match(h) else {
            lock.unlock()
            return false
        }
        _holder = nil
        idleTimer?.cancel()
        idleTimer = nil
        lock.unlock()
        changed(nil, previous: h, why: why)
        return true
    }

    // MARK: Input

    /// `/input` from `device` (nil: the unix socket) may go through; throws the 409 otherwise. A phone's accepted
    /// input counts as activity.
    func admitInput(from device: RemoteDevice?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let device else {
            if let h = _holder { throw Self.elsewhere(h) }
            return
        }
        guard let h = _holder else { throw HTTPError(409, "take control of the screen first (POST /control)") }
        guard h.id == device.id else { throw Self.elsewhere(h) }
        lastActivity = now()
    }

    static func elsewhere(_ h: Holder) -> HTTPError {
        HTTPError(409, "\(h.name) controls the screen", extra: [
            "code": controlledElsewhere,
            "controllerDevice": ["id": h.id, "name": h.name],
        ])
    }

    /// Releases control that has been idle too long (the timer calls it; tests with a fake clock too).
    func checkIdle() {
        lock.lock()
        guard _holder != nil else { lock.unlock(); return }
        if now().timeIntervalSince(lastActivity) >= idle {
            lock.unlock()
            releaseAny(why: "control idle for \(Int(idle / 60)) min")
        } else {
            armIdleLocked()
            lock.unlock()
        }
    }

    private func armIdleLocked() {
        idleTimer?.cancel()
        let wait = max(0, lastActivity.addingTimeInterval(idle).timeIntervalSince(now())) + 0.05
        let item = DispatchWorkItem { [weak self] in self?.checkIdle() }
        idleTimer = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait, execute: item)
    }

    private func changed(_ holder: Holder?, previous: Holder?, why: String) {
        log("remote: \(why)")
        if previous != nil { liftHeldButtons(why) }
        ScreenStateTracker.current?.post(Self.eventLine(json))
        onChange?(holder)
        lock.lock()
        let more = Array(observers.values)
        lock.unlock()
        more.forEach { $0(holder) }
    }

    /// Calls `onChange` (outside the lock, any thread) after every change, besides `onChange`; the token removes it.
    func observe(_ onChange: @escaping (Holder?) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextObserver += 1
        observers[nextObserver] = onChange
        return nextObserver
    }

    func removeObserver(_ token: Int) {
        lock.lock(); observers[token] = nil; lock.unlock()
    }

    /// `{"type":"control","control":{…}}` + newline.
    static func eventLine(_ control: [String: Any]) -> Data {
        var line = (try? JSONSerialization.data(withJSONObject: ["type": "control", "control": control], options: [.sortedKeys])) ?? Data()
        line.append(0x0a)
        return line
    }
}
#endif
