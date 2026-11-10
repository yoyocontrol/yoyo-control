#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Who a point of the menu bar belongs to, for `/hit` (Windows.swift, docs/LOCAL-API.md). The window list can't tell:
// on macOS 27 the whole menu bar is one Window Server window at the main-menu level (status items have no windows of
// their own; over a full-screen app on a display with a notch the same window is the black strip that reveals the
// hidden menu bar). So Accessibility says it:
// - an app's menu (a title of its `AXMenuBar`) → that app (the frontmost: operating its menus is operating it);
// - the Apple menu (the first title of every app's menu bar) → `appleMenuBundle`, an identity of its own: it is drawn by
//   the frontmost app, but its commands are the system's (restart, shut down, log out, force quit, System Settings);
// - a status item → the app whose `AXExtrasMenuBar` holds it (Control Centre's clock / Wi-Fi / battery, SystemUIServer's,
//   the input menu agent's, a third-party app's), from each app's own tree (`StatusItems`), else the system's hit test;
// - anywhere else in the bar (between the menus and the items, the hidden bar's reveal strip) → the frontmost app.
// Without Accessibility (none, or a session switched away: -25204) only an app's own status window (older macOS) is
// known; the rest has no owner (`app: null`). Never Finder.

/// What a point of the menu bar is (`/hit`'s `menuBar`).
enum MenuBarArea: String, Equatable {
    case appleMenu, appMenu, statusItem, bar
}

/// What the system's hit test (`AXUIElementCopyElementAtPosition`) finds at a point of the menu bar.
enum MenuBarAX: Equatable {
    /// No Accessibility, or it can't answer here (a session switched away).
    case unavailable
    /// No menu bar element (the hidden bar's strip, something else).
    case nothing
    /// A title of `pid`'s menu bar; `apple`: its first one, the Apple menu.
    case appMenu(pid: pid_t, apple: Bool)
    /// `pid`'s menu bar itself, between its titles.
    case appMenuBar(pid: pid_t)
    /// A status item of `pid`.
    case statusItem(pid: pid_t)
}

/// One status item: the app whose `AXExtrasMenuBar` holds it and its frame (global points, top-left origin).
struct StatusItem: Equatable {
    var pid: pid_t
    var frame: CGRect
}

/// The status items found; `complete`: every app answered (else one that did not may hold an item anywhere).
struct StatusItemList: Equatable {
    var items: [StatusItem]
    var complete: Bool
}

/// The answers `WindowCatalog.hit` needs for a point of the menu bar (live: `MenuBarSource.live`; tests: canned).
struct MenuBarSource {
    var element: (CGPoint) -> MenuBarAX
    /// Every status item on screen.
    var statusItems: () -> StatusItemList
    /// The app whose menu bar shows (the focused app); nil when unknown.
    var frontmost: () -> pid_t?
    /// A pid's bundle id and name (`NSRunningApplication`).
    var lookup: (pid_t) -> (bundleId: String?, name: String?)

    /// No Accessibility.
    static let none = MenuBarSource(element: { _ in .unavailable }, statusItems: { StatusItemList(items: [], complete: false) }, frontmost: { nil }, lookup: { _ in (nil, nil) })

    static let live = MenuBarSource(element: MenuBarAXProbe.element(at:), statusItems: StatusItems.current,
                                    frontmost: FocusProbe.focusedPID, lookup: WindowCatalog.runningApp)
}

enum MenuBarAXProbe {
    static let extrasAttribute = "AXExtrasMenuBar"
    static let menuExtraSubrole = "AXMenuExtra"

    /// The system's hit test at `point`, classified.
    static func element(at point: CGPoint) -> MenuBarAX {
        guard AXIsProcessTrusted() else { return .unavailable }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, FocusProbe.messagingTimeout)
        var found: AXUIElement?
        switch AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) {
        case .success: break
        case .cannotComplete, .apiDisabled, .notImplemented: return .unavailable
        default: return .nothing
        }
        guard var element = found else { return .nothing }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return .nothing }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, FocusProbe.messagingTimeout)
        let menuBar = AXRead.element(app, kAXMenuBarAttribute)
        let extras = AXRead.element(app, extrasAttribute)
        // the element itself or one of its ancestors (an item's image or title text)
        for _ in 0..<5 {
            AXUIElementSetMessagingTimeout(element, FocusProbe.messagingTimeout)
            let role: String? = AXRead.value(element, kAXRoleAttribute)
            if role == (kAXMenuBarItemRole as String) {
                let subrole: String? = AXRead.value(element, kAXSubroleAttribute)
                let parent = AXRead.element(element, kAXParentAttribute)
                if subrole == menuExtraSubrole || same(parent, extras) { return .statusItem(pid: pid) }
                let first = menuBar.flatMap { (AXRead.value($0, kAXChildrenAttribute) as [AXUIElement]?)?.first }
                return .appMenu(pid: pid, apple: same(first, element))
            }
            if role == (kAXMenuBarRole as String) {
                if same(element, extras) { return .statusItem(pid: pid) }
                return .appMenuBar(pid: pid)
            }
            guard let parent = AXRead.element(element, kAXParentAttribute) else { break }
            element = parent
        }
        return .nothing
    }

    private static func same(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        guard let a, let b else { return false }
        return CFEqual(a, b)
    }
}

/// Every app's status items (its `AXExtrasMenuBar`'s children), asked of the regular and accessory apps (a status item
/// needs an app's run loop), each within `appTimeout`, all within `deadline`; kept `ttl` (status items rarely move).
enum StatusItems {
    static let appTimeout: Float = 0.1
    static let deadline: TimeInterval = 0.6
    static let ttl: TimeInterval = 1

    nonisolated(unsafe) private static var cached: (at: Date, list: StatusItemList)?
    private static let lock = NSLock()

    static func current() -> StatusItemList {
        lock.lock()
        defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < ttl { return cached.list }
        let list = scan()
        cached = (Date(), list)
        return list
    }

    /// Not complete when an app did not answer (hung, or no Accessibility here) or the deadline passed.
    private static func scan() -> StatusItemList {
        guard AXIsProcessTrusted() else { return StatusItemList(items: [], complete: false) }
        let end = Date().addingTimeInterval(deadline)
        let me = getpid()
        var out: [StatusItem] = []
        var complete = true
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited && app.processIdentifier != me {
            if Date() >= end { return StatusItemList(items: out, complete: false) }
            let pid = app.processIdentifier
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, appTimeout)
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, MenuBarAXProbe.extrasAttribute as CFString, &value) {
            case .success: break
            case .cannotComplete: complete = false; continue
            default: continue  // no status items
            }
            guard let bar = value, CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
            let children: [AXUIElement] = AXRead.value(bar as! AXUIElement, kAXChildrenAttribute) ?? []
            for child in children {
                if let frame = AXRead.frame(child), frame.width > 0, frame.height > 0 { out.append(StatusItem(pid: pid, frame: frame)) }
            }
        }
        return StatusItemList(items: out, complete: complete)
    }
}

/// Small Accessibility reads.
enum AXRead {
    static func raw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        raw(element, attribute) as? T
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = raw(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Position + size (global points, top-left origin).
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = raw(element, kAXPositionAttribute), let s = raw(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
#endif
