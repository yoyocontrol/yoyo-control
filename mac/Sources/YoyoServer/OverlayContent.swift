#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// What really shows in a system overlay, for automation (`/windows`, `/hit`, `/frame?visible=`, `/app/*`): some system
// processes draw their surfaces inside one transparent window over the whole display above the apps (seen on macOS 27:
// Notification Centre's banners and panel in one full-display window at level 21). The window list only knows the
// whole window, so its real surfaces come from Accessibility: the elements of the matching AX window that are smaller
// than the display (`OverlaySurfaces`). An overlay with none (the Dock's, WindowManager's invisible backdrops, or no
// Accessibility) stays left out, as `WindowCatalog.isSystemBackdrop` says. And `/hit` asks Accessibility which app is
// under the point when an overlay is in front there (`AXHit`): the system's own hit test knows the clear parts of a
// window let the click through.

enum OverlaySurfaces {
    /// An element at most this share of the overlay's width and height is a surface (a banner, a panel's widget);
    /// a bigger one is a container to look inside.
    static let maxShare: CGFloat = 0.6
    static let maxDepth = 8
    static let maxNodes = 150
    static let maxSurfaces = 16
    static let walkTimeout: TimeInterval = 0.5

    /// The surfaces under `root`, depth-first: the first element down each branch whose frame (clipped to `area`) is
    /// small enough, taken whole; elements without a frame or too big are looked inside. Ones inside another are
    /// dropped. Global points.
    static func collect<S: AXElementSource>(root: S.Element, source: S, area: CGRect, maxDepth: Int = maxDepth,
                                            maxNodes: Int = maxNodes, expired: () -> Bool) -> [CGRect] {
        var out: [CGRect] = []
        var stack: [(element: S.Element, depth: Int)] = [(root, 0)]
        var nodes = 0
        while let next = stack.popLast(), nodes < maxNodes, out.count < maxSurfaces, !expired() {
            nodes += 1
            guard let info = source.info(next.element) else { continue }
            if let frame = info.frame {
                let clipped = frame.intersection(area)
                if clipped.isNull || clipped.width < 1 || clipped.height < 1 { continue }  // nothing of it shows
                if next.depth > 0, isSurface(clipped, of: area) {
                    if !out.contains(clipped) { out.append(clipped) }
                    continue
                }
            }
            guard next.depth < maxDepth else { continue }
            for child in source.children(next.element).reversed() { stack.append((child, next.depth + 1)) }
        }
        return out.filter { r in !out.contains { $0 != r && $0.contains(r) } }
    }

    static func isSurface(_ r: CGRect, of area: CGRect) -> Bool {
        r.width <= maxShare * area.width && r.height <= maxShare * area.height
    }

    /// The bounding box of `surfaces`; nil when there are none.
    static func union(_ surfaces: [CGRect]) -> CGRect? {
        surfaces.dropFirst().reduce(surfaces.first) { $0?.union($1) }
    }

    /// The AX windows of `pid` that make up the window `bounds`: the one with that frame (`AXWindowMatch`), else the
    /// ones lying inside it that are not one of `others` (the process's other windows of the window list).
    static func axWindows(pid: pid_t, bounds: CGRect, others: [CGRect]) -> [AXWindowInfo] {
        let windows = AXWindows.list(pid: pid, quiet: true)
        if let i = AXWindowMatch.best(target: bounds, candidates: windows.map(\.frame)) { return [windows[i]] }
        return windows.filter { w in
            bounds.insetBy(dx: -AXWindowMatch.tolerance, dy: -AXWindowMatch.tolerance).contains(w.frame)
                && !others.contains { AXWindowMatch.same($0, w.frame) }
        }
    }

    /// The live surfaces of the overlay window `bounds` of `pid` (none without Accessibility).
    static func live(pid: pid_t, bounds: CGRect, others: [CGRect]) -> [CGRect] {
        guard AXIsProcessTrusted() else { return [] }
        let deadline = Date().addingTimeInterval(walkTimeout)
        var out: [CGRect] = []
        for w in axWindows(pid: pid, bounds: bounds, others: others) {
            out += collect(root: w.element, source: LiveAXSource(), area: bounds) { Date() >= deadline }
        }
        return out
    }
}

/// The system's own hit test: the app owning the Accessibility element at a point (global points, top-left origin).
/// Nil without Accessibility, in a session switched away (-25204) or when nothing answers.
enum AXHit {
    static func pid(at point: CGPoint) -> pid_t? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, FocusProbe.messagingTimeout)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success, let element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return nil }
        return pid
    }
}

/// An app's English name (its bundle's `en` InfoPlist strings, else its Info.plist names), for callers that know apps
/// by their English names when the system speaks another language (`name` is the localized one). Cached by bundle id.
enum AppNames {
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func english(bundleId: String?) -> String? {
        guard let bundleId, !bundleId.isEmpty else { return nil }
        let key = bundleId.lowercased()
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let name = lookup(bundleId)
        lock.lock()
        cache[key] = name
        lock.unlock()
        return name
    }

    private static func lookup(_ bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId), let bundle = Bundle(url: url) else { return nil }
        if #available(macOS 15.4, *) {
            let missing = "\u{1}"
            let en = [Locale.Language(identifier: "en")]
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                let s = bundle.localizedString(forKey: key, value: missing, table: "InfoPlist", localizations: en)
                if s != missing, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
            }
        }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let s = bundle.infoDictionary?[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        return nil
    }
}
#endif
