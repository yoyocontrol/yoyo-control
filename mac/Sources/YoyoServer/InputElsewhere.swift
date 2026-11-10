#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

// Input from elsewhere: somebody other than this service is typing, clicking, moving the pointer or scrolling on this
// Mac (a person at the keyboard, a remote-desktop tool, another automation). A pass-through session event tap (the
// same kind as the Escape tap, Automation.swift: it needs Accessibility, not Input Monitoring) sees key-downs,
// modifier changes, every button's down / up / drag, pointer moves and scrolls. Events this process posted (`/input`,
// the phones' and the local automation's) carry its pid in `eventSourceUnixProcessID` and are not counted; anything
// else is `hardware` (no posting process: the HID system, physical devices and virtual-HID drivers alike) or
// `process` (another process posted it). Reported as `{"type":"input-elsewhere",…}` on `/events` (the first at once,
// then at most one per second while it goes on) and as `/status`'s `inputElsewhere` (the latest);
// `/status.features.inputElsewhere` says whether the tap is in. What to do about it is the client's call.

/// Where an input event came from, when not from this process.
enum InputOrigin: Equatable {
    case hardware
    case process(pid_t)

    /// `eventSourceUnixProcessID` → the origin; nil for this process's own events.
    static func of(sourcePid: Int64, me: pid_t = getpid()) -> InputOrigin? {
        if sourcePid == Int64(me) { return nil }
        if sourcePid <= 0 || sourcePid > Int64(Int32.max) { return .hardware }
        return .process(pid_t(sourcePid))
    }
}

/// One sighting: when (ms since 1970) and from where. No allocation: the tap's callback makes these.
struct InputSighting: Equatable {
    var at: Int64
    var origin: InputOrigin

    /// The `/events` line's / `/status` fields; `app` / `bundleId` when the posting process is an app.
    func json(app: (name: String?, bundleId: String?)?) -> [String: Any] {
        var out: [String: Any] = ["at": at]
        switch origin {
        case .hardware:
            out["source"] = "hardware"
        case .process(let pid):
            out["source"] = "process"
            out["pid"] = Int(pid)
            if let name = app?.name { out["app"] = name }
            if let id = app?.bundleId { out["bundleId"] = id }
        }
        return out
    }
}

/// The rate rule: the first sighting after a quiet second is reported at once, then at most one per `interval` while
/// input goes on; `latest` is always the newest. Pure.
struct InputElsewhereCore: Equatable {
    static let interval: Int64 = 1000
    private(set) var latest: InputSighting?
    private var lastReported: Int64?

    /// Note a sighting; true when it is to be reported now.
    mutating func note(_ s: InputSighting) -> Bool {
        latest = s
        if let last = lastReported, s.at - last < Self.interval, s.at >= last { return false }
        lastReported = s.at
        return true
    }
}

/// The live watch: the tap (installed while Accessibility is granted, retried until it is), the latest sighting, the
/// `/events` lines. One per service.
final class InputElsewhereWatch: @unchecked Sendable {
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var _current: InputElsewhereWatch?
    /// The running service's watch (nil when the host turned it off or the service is stopped).
    static var current: InputElsewhereWatch? {
        currentLock.lock(); defer { currentLock.unlock() }; return _current
    }

    /// The events looked at.
    static let mask: CGEventMask = {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
                                    .otherMouseDragged, .mouseMoved, .scrollWheel]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()
    /// How often a missing tap is retried (Accessibility granted later) and a present one checked (revoked).
    static let recheck: DispatchTimeInterval = .seconds(3)

    private let core = OSAllocatedUnfairLock(initialState: InputElsewhereCore())
    private let me = getpid()
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "input-elsewhere", qos: .utility)
    /// pid → (name, bundle id) of apps seen posting; only touched on `queue`.
    private var apps: [pid_t: (name: String?, bundleId: String?)] = [:]

    /// The tap is in.
    var installed: Bool {
        lock.lock(); defer { lock.unlock() }
        return port != nil
    }

    /// `/status`'s `inputElsewhere`: the latest sighting, or NSNull.
    var statusJSON: Any {
        guard let s = core.withLock({ $0.latest }) else { return NSNull() }
        return s.json(app: Self.app(of: s.origin))
    }

    func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.recheck)
        t.setEventHandler { [weak self] in self?.check() }
        timer = t
        lock.unlock()
        Self.currentLock.lock(); Self._current = self; Self.currentLock.unlock()
        t.resume()
    }

    func stop() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
        remove()
        Self.currentLock.lock(); if Self._current === self { Self._current = nil }; Self.currentLock.unlock()
    }

    /// On `queue`: install the tap once Accessibility is granted; remove it when the grant goes (its events stop).
    private func check() {
        let trusted = AXIsProcessTrusted()
        if trusted && !installed {
            if install() { log("input-elsewhere: watching") }
        } else if !trusted && installed {
            remove()
            log("input-elsewhere: Accessibility gone, not watching")
        }
    }

    private func install() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let thread = Thread { [self] in
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: Self.mask, callback: inputElsewhereTapCallback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            lock.lock(); self.port = port; self.runLoop = loop; lock.unlock()
            ok = true
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "input-elsewhere tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return ok
    }

    private func remove() {
        lock.lock()
        let port = self.port, loop = runLoop
        self.port = nil
        runLoop = nil
        lock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// The tap's callback, on its thread: trivial (a field read, a clock read, an unfair lock); the event always
    /// passes on unchanged.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let port = self.port; lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        guard let origin = InputOrigin.of(sourcePid: event.getIntegerValueField(.eventSourceUnixProcessID), me: me) else { return }
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        let sighting = InputSighting(at: Int64(now.tv_sec) * 1000 + Int64(now.tv_nsec) / 1_000_000, origin: origin)
        guard core.withLock({ $0.note(sighting) }) else { return }
        queue.async { [weak self] in self?.report(sighting) }
    }

    /// On `queue`: the `/events` line.
    private func report(_ s: InputSighting) {
        var app: (name: String?, bundleId: String?)?
        if case .process(let pid) = s.origin {
            if let known = apps[pid] {
                app = known
            } else {
                app = Self.app(of: s.origin)
                if apps.count > 64 { apps.removeAll() }
                apps[pid] = app
            }
        }
        var json = s.json(app: app)
        json["type"] = "input-elsewhere"
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let tracker = ScreenStateTracker.current else { return }
        tracker.post(data + Data("\n".utf8))
    }

    /// The app that posted, when the process is one (NSRunningApplication); nil for hardware or a plain process.
    static func app(of origin: InputOrigin) -> (name: String?, bundleId: String?)? {
        guard case .process(let pid) = origin, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return (app.localizedName, app.bundleIdentifier)
    }
}

private func inputElsewhereTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                       userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo { Unmanaged<InputElsewhereWatch>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event) }
    return Unmanaged.passUnretained(event)
}
#endif
