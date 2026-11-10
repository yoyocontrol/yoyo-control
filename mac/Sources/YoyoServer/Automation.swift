#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import QuartzCore

// A local program is driving this Mac (`POST /automation { active, label? }`; the older `POST /agent-control` is the
// same request): an orange glow around every display with a small capsule at the top ("Claude is using this computer ·
// press Esc to stop" with `label` "Claude"; "Automation is using this computer" without) and, only while active, a
// keyboard tap that turns a bare Escape into `{"type":"abort","reason":"esc"}` on `/events` (the key itself is
// swallowed). The border windows ignore the mouse, sit on every Space, and are never in a picture
// (`sharingType = .none`, and every capture leaves this process's windows out: Capture.swift, NativeFilter.swift). The
// state machine (`AutomationCore`) and the geometry are pure; `Automation.shared` runs their effects.

/// What a state change does.
enum AutomationEffect: Equatable {
    /// Install the Escape tap (before the border, whose text depends on it).
    case installTap
    case removeTap
    /// Show the border, or redraw it with a new label.
    case showBorder
    case hideBorder
    /// `{"type":"abort","reason":"esc"}` on `/events`.
    case emitAbort
}

/// active / label (who is driving, shown in the capsule) / whether the Escape tap is in. Pure.
struct AutomationCore: Equatable {
    private(set) var active = false
    private(set) var label = ""
    /// The Escape tap is installed (only ever while active).
    private(set) var esc = false

    /// `POST /automation`. Effects on a change of `active`, and a redraw for a new label while active.
    mutating func set(active: Bool, label: String) -> [AutomationEffect] {
        let relabel = self.active && active && label != self.label
        self.label = active ? label : ""
        switch (self.active, active) {
        case (false, true):
            self.active = true
            return [.installTap, .showBorder]
        case (true, false):
            self.active = false
            esc = false
            return [.removeTap, .hideBorder]
        default:
            return relabel ? [.showBorder] : []
        }
    }

    /// The tap's installation went this way (after `.installTap`).
    mutating func tapInstalled(_ ok: Bool) {
        esc = ok && active
    }

    /// Escape seen by the tap: stop. Nothing when not active (a late key from a tap being removed).
    mutating func escape() -> [AutomationEffect] {
        guard active else { return [] }
        active = false
        esc = false
        label = ""
        return [.removeTap, .hideBorder, .emitAbort]
    }

    /// `/status`'s `automation` (and, without `label`, the older `agentControl`).
    var json: [String: Any] {
        var out: [String: Any] = ["active": active, "esc": esc]
        if !label.isEmpty { out["label"] = label }
        return out
    }
}

/// The keys that stop the automation: Escape (keycode 53) without ⌘ ⇧ ⌥ ⌃, not posted by this process (the
/// automation's own keys and a phone's go out through `/input`).
enum AutomationStopKey {
    static let escapeKeyCode: Int64 = 53
    static let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    static func isStop(keyCode: Int64, flags: CGEventFlags, sourcePid: Int64, me: pid_t = getpid()) -> Bool {
        keyCode == escapeKeyCode && flags.intersection(modifiers).isEmpty && sourcePid != Int64(me)
    }
}

/// The border's and capsule's geometry, in a display's window coordinates (bottom-left origin). Pure.
enum AutomationOverlayGeometry {
    static let lineWidth: CGFloat = 6
    static let glowRadius: CGFloat = 14
    static let capsulePadding = CGSize(width: 14, height: 6)
    /// Below the menu bar.
    static let capsuleGap: CGFloat = 10

    /// The stroke's path rect: the line's outer edge on the display's edge.
    static func borderRect(_ bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    }

    /// The capsule around `text` (its size), centered at the top, below the menu bar (`menuBar`: the screen's frame
    /// top minus its visible frame top; 0 when the menu bar hides). Whole points.
    static func capsuleFrame(in bounds: CGRect, menuBar: CGFloat, text: CGSize) -> CGRect {
        let w = (text.width + 2 * capsulePadding.width).rounded(.up)
        let h = (text.height + 2 * capsulePadding.height).rounded(.up)
        let x = (bounds.midX - w / 2).rounded()
        let y = (bounds.maxY - max(menuBar, 0) - capsuleGap - h).rounded()
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// "<label> is using this computer · press Esc to stop"; "Automation" without a label; no Esc part without the tap.
    static func capsuleText(label: String, esc: Bool, chinese: Bool) -> String {
        if chinese {
            let who = label.isEmpty ? "自动化程序" : "\(label) "
            return "\(who)正在使用这台电脑" + (esc ? " · 按 Esc 停止" : "")
        }
        let who = label.isEmpty ? "Automation" : label
        return "\(who) is using this computer" + (esc ? " · press Esc to stop" : "")
    }

    static var systemIsChinese: Bool { Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true }
}

/// The live automation state: `POST /automation` (and `/agent-control`), the Escape tap, `/status`'s `automation`.
final class Automation: @unchecked Sendable {
    static let shared = Automation()

    private let lock = NSLock()
    private var core = AutomationCore()
    private let tap = EscapeTap()

    var json: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return core.json
    }

    /// Apply a request; the state after it.
    @discardableResult
    func set(active: Bool, label: String) -> AutomationCore {
        lock.lock()
        let effects = core.set(active: active, label: label)
        lock.unlock()
        let who = label.isEmpty ? "" : " (\(label))"
        log("automation: \(active ? "active\(who)" : "inactive")\(effects.isEmpty ? " (unchanged)" : "")")
        run(effects)
        lock.lock(); defer { lock.unlock() }
        return core
    }

    /// The tap saw Escape.
    private func escape() {
        lock.lock()
        let effects = core.escape()
        lock.unlock()
        guard !effects.isEmpty else { return }
        log("automation: Esc pressed, stopping")
        run(effects)
    }

    private func run(_ effects: [AutomationEffect]) {
        for effect in effects {
            switch effect {
            case .installTap:
                let ok = tap.install { [weak self] in self?.escape() }
                if !ok { log("automation: no Escape tap (Accessibility not granted?)") }
                lock.lock(); core.tapInstalled(ok); lock.unlock()
            case .removeTap:
                tap.remove()
            case .showBorder:
                lock.lock(); let (esc, label) = (core.esc, core.label); lock.unlock()
                let text = AutomationOverlayGeometry.capsuleText(label: label, esc: esc, chinese: AutomationOverlayGeometry.systemIsChinese)
                DispatchQueue.main.async { AutomationOverlay.shared.show(text: text) }
            case .hideBorder:
                DispatchQueue.main.async { AutomationOverlay.shared.hide() }
            case .emitAbort:
                if let tracker = ScreenStateTracker.current {
                    tracker.post(Automation.abortLine)
                } else {
                    log("automation: no /events to tell about the Esc")
                }
            }
        }
    }

    static let abortLine = Data("{\"type\":\"abort\",\"reason\":\"esc\"}\n".utf8)

    /// Longest label kept (characters).
    static let maxLabel = 40

    /// `POST /automation` (or `/agent-control`) body `{ active, label?, title? }` → (active, label); 400 when
    /// malformed. `title` (the older field: what the automation is doing) is accepted and not shown.
    static func parse(_ body: Data) throws -> (active: Bool, label: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw HTTPError(400, "body must be a JSON object")
        }
        guard let active = json["active"] as? Bool, CFGetTypeID(json["active"] as CFTypeRef) == CFBooleanGetTypeID() else {
            throw HTTPError(400, "active must be a boolean")
        }
        switch json["title"] {
        case nil, is NSNull, is String: break
        default: throw HTTPError(400, "title must be a string")
        }
        let label: String
        switch json["label"] {
        case nil, is NSNull: label = ""
        case let s as String:
            // one line of printable text: control characters (newlines too) become spaces, runs of them one
            let words = String(String.UnicodeScalarView(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
                .split(separator: " ", omittingEmptySubsequences: true)
            label = String(words.joined(separator: " ").prefix(maxLabel))
        default: throw HTTPError(400, "label must be a string")
        }
        return (active, label)
    }
}

// MARK: - The Escape tap

/// A session event tap for key-downs on its own thread's run loop, installed only while automation is active.
final class EscapeTap: @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var onEscape: (() -> Void)?

    /// true when the tap is in (creating it needs Accessibility).
    func install(onEscape: @escaping () -> Void) -> Bool {
        lock.lock()
        if port != nil { lock.unlock(); return true }
        self.onEscape = onEscape
        lock.unlock()
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let thread = Thread { [self] in
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: escapeTapCallback,
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
        thread.name = "yoyo-control escape tap"
        thread.start()
        ready.wait()
        return ok
    }

    func remove() {
        lock.lock()
        let port = self.port, loop = runLoop
        self.port = nil
        runLoop = nil
        onEscape = nil
        lock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// From the callback: re-enable after the system disabled the tap; Escape → nil (swallowed) and `onEscape`.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let port = self.port; lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              AutomationStopKey.isStop(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                                  sourcePid: event.getIntegerValueField(.eventSourceUnixProcessID)) else {
            return Unmanaged.passUnretained(event)
        }
        lock.lock(); let callback = onEscape; lock.unlock()
        guard let callback else { return Unmanaged.passUnretained(event) }
        DispatchQueue.global(qos: .userInitiated).async(execute: callback)
        return nil
    }
}

private func escapeTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EscapeTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}

// MARK: - The border

/// The glow windows, one per display. Main thread only.
final class AutomationOverlay {
    nonisolated(unsafe) static let shared = AutomationOverlay()

    private var windows: [NSWindow] = []
    private var text = ""
    private var screensObserver: NSObjectProtocol?

    static let orange = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.16, alpha: 1)
    /// Above everything but the screen saver.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    func show(text: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.text = text
        rebuild()
        if screensObserver == nil {
            screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.windows.isEmpty else { return }
                self.rebuild()
            }
        }
    }

    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        screensObserver = nil
    }

    private func rebuild() {
        _ = NSApplication.shared  // AppKit's connection to the window server
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map(makeWindow)
        windows.forEach { $0.orderFrontRegardless() }
    }

    private func makeWindow(_ screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = Self.level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)

        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let view = NSView(frame: bounds)
        view.wantsLayer = true
        let root = view.layer!

        let border = CAShapeLayer()
        border.frame = bounds
        border.path = CGPath(rect: AutomationOverlayGeometry.borderRect(bounds), transform: nil)
        border.fillColor = nil
        border.strokeColor = Self.orange.cgColor
        border.lineWidth = AutomationOverlayGeometry.lineWidth
        border.shadowColor = Self.orange.cgColor
        border.shadowOpacity = 1
        border.shadowRadius = AutomationOverlayGeometry.glowRadius
        border.shadowOffset = .zero
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1.0
        breathe.toValue = 0.55
        breathe.duration = 1.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        border.add(breathe, forKey: "breathe")
        root.addSublayer(border)

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let capsule = NSView(frame: AutomationOverlayGeometry.capsuleFrame(in: bounds, menuBar: menuBar, text: label.frame.size))
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = Self.orange.withAlphaComponent(0.92).cgColor
        capsule.layer?.cornerRadius = capsule.frame.height / 2
        label.setFrameOrigin(CGPoint(x: AutomationOverlayGeometry.capsulePadding.width, y: AutomationOverlayGeometry.capsulePadding.height))
        capsule.addSubview(label)
        view.addSubview(capsule)

        window.contentView = view
        return window
    }
}
#endif
