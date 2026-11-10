#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// `GET /app/ax?window=&max=60`: what can be pressed in one window, from its Accessibility tree, for the agent to click
// by element (AppWindows.swift has the other background-mode endpoints). Depth-first from the window, only the
// actionable roles, each element's frame in the window's own picture (normalized 0…1 on the window, clipped to it and
// to the scroll areas around it). The label is the title, else the description, else the placeholder: never the value
// (`kAXValueAttribute`: a text field's contents may be a password). At most `max` elements (60, ≤ 200), depth 15,
// 0.3 s per Accessibility call, 2 s for the whole walk (then `truncated: true` with what was collected).

/// What the walk needs of one element (one `AXUIElementCopyMultipleAttributeValues`).
struct AXNodeInfo: Equatable {
    var role: String?
    var subrole: String?
    var title: String?
    var description: String?
    var placeholder: String?
    /// Global points, top-left origin; nil when the element has no position or size.
    var frame: CGRect?
    var enabled: Bool = true
    var focused: Bool = false
    /// Rows and cells: `kAXSelectedAttribute` can be set (asked only for those roles).
    var selectable: Bool = false
    /// A group with a label that offers `AXPress` (a notification banner, a card): pressed as a whole (asked only of
    /// labelled groups).
    var pressable: Bool = false

    /// title → description → placeholder, trimmed, ≤ 200 characters; nil when all are empty.
    var label: String? {
        for s in [title, description, placeholder] {
            if let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return String(t.prefix(200)) }
        }
        return nil
    }
}

/// Where the walk reads elements from: Accessibility (`LiveAXSource`) or a test's tree.
protocol AXElementSource {
    associatedtype Element
    func info(_ element: Element) -> AXNodeInfo?
    func children(_ element: Element) -> [Element]
    func same(_ a: Element, _ b: Element) -> Bool
}

/// One `/app/ax` element.
struct AXSummaryElement: Equatable {
    /// 1-based, in walk order (the agent's `[N]`).
    var i: Int
    var role: String
    var subrole: String?
    var title: String?
    /// Normalized on the window.
    var rect: CGRect
    var enabled: Bool
    var focused: Bool

    var json: [String: Any] {
        var out: [String: Any] = ["i": i, "role": role, "x": round4(rect.minX), "y": round4(rect.minY),
                                  "w": round4(rect.width), "h": round4(rect.height), "enabled": enabled, "focused": focused]
        if let subrole { out["subrole"] = subrole }
        if let title { out["title"] = title }
        return out
    }
}

enum AXSummary {
    static let defaultMax = 60
    static let maxLimit = 200
    static let maxDepth = 15
    static let walkTimeout: TimeInterval = 2
    /// Children read of one element at most (a table with thousands of rows).
    static let maxChildren = 400

    /// The roles an agent can act on (the usual computer-use set).
    static let actionableRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXLink", "AXRadioButton", "AXCheckBox",
        "AXPopUpButton", "AXMenuButton", "AXTab", "AXDisclosureTriangle", "AXMenuItem",
    ]
    /// Roles whose text children are their own label (a static text inside is skipped).
    static let pressableRoles: Set<String> = ["AXButton", "AXLink", "AXMenuButton", "AXPopUpButton", "AXRadioButton", "AXCheckBox", "AXMenuItem", "AXTab"]
    /// Containers that clip what is inside to their frame.
    static let clippingRoles: Set<String> = ["AXScrollArea"]

    /// Whether the walk lists `info`: an actionable role; a row or cell that can be selected; a labelled group that can
    /// be pressed; a static text with a label that is not part of a pressable element.
    static func isListed(_ info: AXNodeInfo, insidePressable: Bool) -> Bool {
        guard let role = info.role else { return false }
        if actionableRoles.contains(role) { return true }
        if role == "AXRow" || role == "AXCell" { return info.selectable }
        if role == "AXGroup" { return info.pressable && info.label != nil }
        if role == "AXStaticText" { return !insidePressable && info.label != nil }
        return false
    }

    /// `rect` (global points) clipped to `clip` and normalized on `window`; nil when nothing of it is left.
    static func normalized(_ rect: CGRect, clip: CGRect, window: CGRect) -> CGRect? {
        let r = rect.intersection(clip).intersection(window)
        guard !r.isNull, r.width >= 1, r.height >= 1, window.width > 0, window.height > 0 else { return nil }
        return CGRect(x: (r.minX - window.minX) / window.width, y: (r.minY - window.minY) / window.height,
                      width: r.width / window.width, height: r.height / window.height)
    }

    struct Result<Element> {
        var elements: [AXSummaryElement]
        /// The elements' handles, by `i - 1`.
        var handles: [Element]
        /// The walk stopped early: `max` reached or out of time.
        var truncated: Bool
    }

    /// Depth-first, pre-order from `root` (the window) through `source`. `expired` is asked before every element.
    static func collect<S: AXElementSource>(root: S.Element, source: S, window: CGRect, max: Int = defaultMax,
                                            maxDepth: Int = maxDepth, expired: () -> Bool) -> Result<S.Element> {
        var out: [AXSummaryElement] = []
        var handles: [S.Element] = []
        var stack: [(element: S.Element, depth: Int, clip: CGRect, insidePressable: Bool)] = [(root, 0, window, false)]
        var truncated = false
        while let next = stack.popLast() {
            if out.count >= max || expired() {
                truncated = true
                break
            }
            guard let info = source.info(next.element) else { continue }
            if next.depth > 0, isListed(info, insidePressable: next.insidePressable), let role = info.role, let frame = info.frame,
               let rect = normalized(frame, clip: next.clip, window: window) {
                out.append(AXSummaryElement(i: out.count + 1, role: role, subrole: info.subrole, title: info.label, rect: rect,
                                            enabled: info.enabled, focused: info.focused))
                handles.append(next.element)
            }
            guard next.depth < maxDepth else { continue }
            var clip = next.clip
            if let role = info.role, clippingRoles.contains(role), let frame = info.frame {
                clip = clip.intersection(frame)
                if clip.isNull || clip.isEmpty { continue }  // nothing inside can show
            }
            let pressable = next.insidePressable || info.role.map(pressableRoles.contains) == true || (info.role == "AXGroup" && info.pressable)
            for child in source.children(next.element).reversed() {
                stack.append((child, next.depth + 1, clip, pressable))
            }
        }
        return Result(elements: out, handles: handles, truncated: truncated)
    }

    /// The `i` of the focused element: one that says so, else the one that is `focusedElement`.
    static func focusedIndex<S: AXElementSource>(_ result: Result<S.Element>, focusedElement: S.Element?, source: S) -> Int? {
        if let e = result.elements.first(where: \.focused) { return e.i }
        guard let focusedElement else { return nil }
        return result.handles.firstIndex(where: { source.same($0, focusedElement) }).map { $0 + 1 }
    }

    // MARK: The endpoint

    /// `GET /app/ax?window=&max=` → `{ app, window, focused, truncated, elements }`. 403 without Accessibility.
    static func answer(_ req: HTTPRequest) throws -> [String: Any] {
        let limit = min(max(try req.int("max") ?? defaultMax, 1), maxLimit)
        guard AXIsProcessTrusted() else {
            throw HTTPError(403, "Accessibility permission is not granted to \(ScreenHost.appName)")
        }
        let target = try AppWindows.requireWindow(req)
        if target.content != nil { return try overlayAnswer(target, limit: limit) }
        let windows = AXWindows.list(pid: target.pid)
        guard let index = AXWindowMatch.best(target: target.record.bounds, candidates: windows.map(\.frame)) else {
            let b = target.record.bounds
            let seen = windows.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))" }.joined(separator: "; ")
            log("ax: window \(target.record.id) at \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height)) matches none of \(windows.count) AX windows [\(seen)]")
            throw HTTPError(404, "window \(target.record.id) has no Accessibility window right now: the Mac is locked or the window is on another Space (the app answers no window elements); the picture still works")
        }
        let window = windows[index]
        if window.minimized { throw HTTPError(409, "window \(target.record.id) is minimized") }
        let source = LiveAXSource()
        let deadline = Date().addingTimeInterval(walkTimeout)
        let result = collect(root: window.element, source: source, window: target.record.bounds, max: limit) { Date() >= deadline }
        return json(target, result, source: source)
    }

    /// A system overlay's window (`Target.content`): the AX windows making it up (OverlaySurfaces.axWindows), one
    /// after the other, normalized on and clipped to what is drawn in it.
    private static func overlayAnswer(_ target: AppWindows.Target, limit: Int) throws -> [String: Any] {
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let others = AppWindows.records(from: all, pids: [target.pid]).filter { $0.id != target.record.id }.map(\.bounds)
        let windows = OverlaySurfaces.axWindows(pid: target.pid, bounds: target.record.bounds, others: others)
        guard !windows.isEmpty else {
            throw HTTPError(404, "window \(target.record.id) has no Accessibility window right now")
        }
        let source = LiveAXSource()
        let deadline = Date().addingTimeInterval(walkTimeout)
        var result = Result<AXUIElement>(elements: [], handles: [], truncated: false)
        for w in windows {
            if result.elements.count >= limit || Date() >= deadline {
                result.truncated = true
                break
            }
            let more = collect(root: w.element, source: source, window: target.frame, max: limit - result.elements.count) { Date() >= deadline }
            let offset = result.elements.count
            result.elements += more.elements.map { var e = $0; e.i += offset; return e }
            result.handles += more.handles
            if more.truncated {
                result.truncated = true
                break
            }
        }
        return json(target, result, source: source)
    }

    private static func json(_ target: AppWindows.Target, _ result: Result<AXUIElement>, source: LiveAXSource) -> [String: Any] {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, FocusProbe.messagingTimeout)
        var focused: CFTypeRef?
        let focusedElement: AXUIElement? = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success
            && focused.map({ CFGetTypeID($0) == AXUIElementGetTypeID() }) == true ? (focused as! AXUIElement) : nil
        return [
            "app": target.app.json,
            "window": Int(target.record.id),
            "focused": focusedIndex(result, focusedElement: focusedElement, source: source) ?? NSNull(),
            "truncated": result.truncated,
            "elements": result.elements.map(\.json),
        ]
    }
}

/// Accessibility itself. Every element gets the 0.3 s messaging timeout; one batched read per element.
struct LiveAXSource: AXElementSource {
    /// Read together, in this order. `kAXValueAttribute` is deliberately not among them.
    static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
    ] as [String]

    func info(_ element: AXUIElement) -> AXNodeInfo? {
        AXUIElementSetMessagingTimeout(element, FocusProbe.messagingTimeout)
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, Self.attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let array = values as? [AnyObject], array.count == Self.attributes.count else { return nil }
        func string(_ i: Int) -> String? { array[i] as? String }
        func bool(_ i: Int) -> Bool? { (array[i] as? NSNumber)?.boolValue }
        var info = AXNodeInfo(role: string(0), subrole: string(1), title: string(2), description: string(3), placeholder: string(4))
        if let p = Self.point(array[5]), let s = Self.size(array[6]) { info.frame = CGRect(origin: p, size: s) }
        info.enabled = bool(7) ?? true
        info.focused = bool(8) ?? false
        if info.role == "AXRow" || info.role == "AXCell" {
            var settable: DarwinBoolean = false
            info.selectable = AXUIElementIsAttributeSettable(element, kAXSelectedAttribute as CFString, &settable) == .success && settable.boolValue
        }
        if info.role == "AXGroup", info.label != nil {
            var names: CFArray?
            info.pressable = AXUIElementCopyActionNames(element, &names) == .success
                && ((names as? [String])?.contains(kAXPressAction as String) ?? false)
        }
        return info
    }

    func children(_ element: AXUIElement) -> [AXUIElement] {
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, AXSummary.maxChildren, &values) == .success,
              let children = values as? [AXUIElement] else { return [] }
        return children
    }

    func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

    static func point(_ value: AnyObject) -> CGPoint? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let v = value as! AXValue
        var p = CGPoint.zero
        return AXValueGetType(v) == .cgPoint && AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    static func size(_ value: AnyObject) -> CGSize? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let v = value as! AXValue
        var s = CGSize.zero
        return AXValueGetType(v) == .cgSize && AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    /// An element's frame by two reads (position, size).
    static func frame(_ element: AXUIElement, quiet: Bool = false) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        let ep = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p)
        let es = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s)
        guard ep == .success, es == .success, let p, let s else {
            if quiet { return nil }
            log("ax: frame read failed: position \(ep.rawValue), size \(es.rawValue)")
            return nil
        }
        guard let point = point(p as AnyObject), let size = size(s as AnyObject) else {
            if quiet { return nil }
            log("ax: frame values not decodable: position type \(CFGetTypeID(p)) (AXValue is \(AXValueGetTypeID())), size type \(CFGetTypeID(s))")
            return nil
        }
        return CGRect(origin: point, size: size)
    }
}
#endif
