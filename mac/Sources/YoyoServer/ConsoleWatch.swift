#if os(macOS)
import Foundation
import IOKit

// Whether the Mac's console is locked (the screen state's `console`, ScreenState.swift: a locked console's picture is
// the lock screen). Polled (~0.5 s); a change counts once it has held for `settleTime`.

/// The Mac's console.
struct ConsoleState: Equatable, Sendable, CustomStringConvertible {
    /// `IOConsoleLocked`: the lock screen.
    var locked: Bool

    var description: String { locked ? "locked" : "unlocked" }

    var json: [String: Any] { ["locked": locked] }

    /// The IORegistry root's `IOConsoleLocked` (false when it is absent).
    static func current() -> ConsoleState {
        ConsoleState(locked: lockedProperty() ?? false)
    }

    /// `IOConsoleLocked` on the registry's root entry, now: nil when the root has no such property (no console
    /// session). The root is `IORegistryGetRootEntry`, not the path `IOService:/`: that path names the IOService
    /// plane's first device (the platform expert, e.g. `J316sAP`), which has no console properties, so reading
    /// there always said "unlocked".
    static func lockedProperty() -> Bool? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return locked(fromProperty: value)
    }

    /// The property's value as a flag (a CFBoolean, or a number); nil for anything else.
    static func locked(fromProperty value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }
}

/// Debounces console states into stable changes. Pure: the clock comes in as an argument.
struct ConsoleChangeDetector: Sendable {
    /// How long a new state must hold before it counts.
    static let settleTime: TimeInterval = 1.5

    /// The last stable state (nil before the first poll).
    private(set) var settled: ConsoleState?
    /// A different state seen since `pendingSince`, not stable yet.
    private(set) var pending: ConsoleState?
    private(set) var pendingSince: TimeInterval = 0

    /// One poll. Returns the change once a new state has held for `settleTime` (once per change: going back to the
    /// settled state before that, or through other states on the way, counts nothing until a state holds).
    mutating func step(_ state: ConsoleState, now: TimeInterval) -> (from: ConsoleState, to: ConsoleState)? {
        guard let current = settled else {
            settled = state
            return nil
        }
        if state == current {
            pending = nil
            return nil
        }
        if state != pending {
            pending = state
            pendingSince = now
            return nil
        }
        guard now - pendingSince >= Self.settleTime else { return nil }
        settled = state
        pending = nil
        return (current, state)
    }
    /// A state known for sure (this process just locked or unlocked the console, ConsoleControl.swift): it counts at
    /// once, without the settle time. Returns the change, if any.
    mutating func force(_ state: ConsoleState) -> (from: ConsoleState, to: ConsoleState)? {
        pending = nil
        let before = settled
        settled = state
        guard let before, before != state else { return nil }
        return (before, state)
    }
}

/// Polls the console and reports stable changes (the screen state refreshes). `@unchecked Sendable`: every mutable
/// field is guarded by `lock` (a leaf lock; `onChange` runs outside it).
final class ConsoleWatcher: @unchecked Sendable {
    static let pollInterval: TimeInterval = 0.5

    private let read: @Sendable () -> ConsoleState
    private let clock: @Sendable () -> TimeInterval
    private let onChange: @Sendable (_ from: ConsoleState, _ to: ConsoleState) -> Void
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    // Guarded by `lock`:
    private var detector = ConsoleChangeDetector()
    private var stopped = false

    init(read: @escaping @Sendable () -> ConsoleState = { ConsoleState.current() },
         clock: @escaping @Sendable () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 },
         onChange: @escaping @Sendable (_ from: ConsoleState, _ to: ConsoleState) -> Void) {
        self.read = read
        self.clock = clock
        self.onChange = onChange
    }

    /// The last stable state.
    var state: ConsoleState? { lock.lock(); defer { lock.unlock() }; return detector.settled }

    /// Start polling. Idempotent.
    func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        stopped = false
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        lock.unlock()
        t.resume()
    }

    func stop() {
        lock.lock()
        stopped = true
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    /// The running service's watcher (ConsoleControl.swift tells it what it just did).
    nonisolated(unsafe) private static var _current: ConsoleWatcher?
    private static let currentLock = NSLock()
    static var current: ConsoleWatcher? {
        get { currentLock.lock(); defer { currentLock.unlock() }; return _current }
        set { currentLock.lock(); _current = newValue; currentLock.unlock() }
    }

    /// The console is `state` for sure (this process just locked / unlocked it): settled now, `onChange` if it differs.
    func force(_ state: ConsoleState) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let change = detector.force(state)
        lock.unlock()
        if let change { onChange(change.from, change.to) }
    }

    /// One poll. Internal for tests.
    func tick() {
        let s = read()
        let now = clock()
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let change = detector.step(s, now: now)
        lock.unlock()
        if let change { onChange(change.from, change.to) }
    }
}
#endif
