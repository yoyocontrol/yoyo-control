#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

// The agent's background mode (docs/PROTOCOL.md 「屏幕」, docs/LOCAL-API.md): one app's windows, a picture of
// one window and a summary of what can be pressed in it, without touching the pointer or the keyboard, for a window
// that is covered, on another Space, or behind the lock screen (`GET /app/windows`, `/app/screenshot`, `/app/ax`).
// None of them needs control of the screen. Window titles are never read, and neither is any element's value
// (`kAXValueAttribute`: a text field's contents may be a password).

/// One window of `CGWindowListCopyWindowInfo(.optionAll)` (off-screen and minimized ones included).
struct AppWindowRecord: Equatable {
    var id: CGWindowID
    var layer: Int
    /// Global display points, top-left origin.
    var bounds: CGRect
    var alpha: Double = 1
    var onScreen: Bool
}

/// One entry of `/app/windows`.
struct AppWindowEntry: Equatable {
    var id: CGWindowID
    var display: CGDirectDisplayID
    /// Normalized on `display` (not clipped: a window reaching past its display's edge goes past 0…1).
    var rect: CGRect
    var onScreen: Bool
    var minimized: Bool

    var json: [String: Any] {
        ["id": Int(id), "display": Int(display), "x": round4(rect.minX), "y": round4(rect.minY),
         "w": round4(rect.width), "h": round4(rect.height), "onScreen": onScreen, "minimized": minimized]
    }
}

func round4(_ v: CGFloat) -> Double { (Double(v) * 10_000).rounded() / 10_000 }

enum AppWindows {
    /// Smallest side of a window worth listing: on screen (a palette, a small panel), off screen (apps keep 33 pt
    /// high menu-bar strips and other helpers off screen).
    static let minOnScreenSide: CGFloat = 40
    static let minOffScreenSide: CGFloat = 80

    /// Whether `r` is one of the app's own windows the agent could look at: not transparent, at a level from normal
    /// up to below the menu bar (no desktop, no menus or status items), big enough, not a full-display backdrop (a
    /// system overlay narrowed to its surfaces, `overlayContent`, is not one any more).
    static func keep(_ r: AppWindowRecord, bundleId: String?, displays: [(id: CGDirectDisplayID, bounds: CGRect)]) -> Bool {
        guard r.alpha > 0, r.layer >= 0, r.layer < WindowCatalog.mainMenuLevel else { return false }
        let side = r.onScreen ? minOnScreenSide : minOffScreenSide
        guard r.bounds.width >= side, r.bounds.height >= side else { return false }
        let asCatalog = WindowRecord(pid: 0, bundleId: bundleId, name: "", layer: r.layer, bounds: r.bounds, alpha: r.alpha, id: r.id)
        return !WindowCatalog.isSystemBackdrop(asCatalog, displays: displays)
    }

    static func isBackdrop(_ r: AppWindowRecord, bundleId: String?, displays: [(id: CGDirectDisplayID, bounds: CGRect)]) -> Bool {
        let asCatalog = WindowRecord(pid: 0, bundleId: bundleId, name: "", layer: r.layer, bounds: r.bounds, alpha: r.alpha, id: r.id)
        return WindowCatalog.isSystemBackdrop(asCatalog, displays: displays)
    }

    /// What is drawn in an on-screen full-display system overlay (`isBackdrop`): the bounding box of the surfaces
    /// `surfaces` finds in it (OverlaySurfaces), clipped to it; nil for any other window or when it finds none.
    static func overlayContent(_ r: AppWindowRecord, bundleId: String?, displays: [(id: CGDirectDisplayID, bounds: CGRect)],
                               surfaces: () -> [CGRect]) -> CGRect? {
        guard r.onScreen, r.alpha > 0, isBackdrop(r, bundleId: bundleId, displays: displays),
              let box = OverlaySurfaces.union(surfaces())?.intersection(r.bounds), !box.isNull, box.width >= 1, box.height >= 1 else { return nil }
        return box
    }

    /// The live `overlayContent` of window `r` of `pid`; `others`: the bounds of the process's other windows.
    static func liveOverlayContent(_ r: AppWindowRecord, pid: pid_t, bundleId: String?, others: [CGRect],
                                   displays: [(id: CGDirectDisplayID, bounds: CGRect)]) -> CGRect? {
        overlayContent(r, bundleId: bundleId, displays: displays) { OverlaySurfaces.live(pid: pid, bounds: r.bounds, others: others) }
    }

    /// The display a window belongs to (its center's, else the one it overlaps most, else the first) and its bounds
    /// normalized on it, unclipped.
    static func placement(_ bounds: CGRect, displays: [(id: CGDirectDisplayID, bounds: CGRect)]) -> (id: CGDirectDisplayID, rect: CGRect)? {
        let catalog = WindowCatalog(records: [], displays: displays, finder: nil)
        guard let d = catalog.display(of: bounds) ?? displays.first, d.bounds.width > 0, d.bounds.height > 0 else { return nil }
        let rect = CGRect(x: (bounds.minX - d.bounds.minX) / d.bounds.width, y: (bounds.minY - d.bounds.minY) / d.bounds.height,
                          width: bounds.width / d.bounds.width, height: bounds.height / d.bounds.height)
        return (d.id, rect)
    }

    /// The listed windows: kept ones, front → back by groups (on screen at the normal level, other on-screen
    /// levels, off screen, minimized), the window list's order inside each.
    static func entries(_ records: [AppWindowRecord], bundleId: String?, displays: [(id: CGDirectDisplayID, bounds: CGRect)],
                        minimized: (AppWindowRecord) -> Bool) -> [AppWindowEntry] {
        let listed: [(entry: AppWindowEntry, layer: Int)] = records.compactMap { r in
            guard keep(r, bundleId: bundleId, displays: displays), let p = placement(r.bounds, displays: displays) else { return nil }
            let mini = !r.onScreen && minimized(r)
            return (AppWindowEntry(id: r.id, display: p.id, rect: p.rect, onScreen: r.onScreen, minimized: mini), r.layer)
        }
        func group(_ e: (entry: AppWindowEntry, layer: Int)) -> Int {
            if e.entry.onScreen { return e.layer == 0 ? 0 : 1 }
            return e.entry.minimized ? 3 : 2
        }
        return listed.enumerated().sorted { a, b in
            let (ga, gb) = (group(a.element), group(b.element))
            return ga != gb ? ga < gb : a.offset < b.offset
        }.map(\.element.entry)
    }

    /// `kCGWindowListOptionAll` entries of the processes `pids` → records.
    static func records(from list: [[String: Any]], pids: Set<pid_t>) -> [AppWindowRecord] {
        list.compactMap { w in
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return AppWindowRecord(id: id, layer: (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0, bounds: bounds,
                                   alpha: (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                                   onScreen: (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
        }
    }

    static func onlineDisplays() -> [(id: CGDirectDisplayID, bounds: CGRect)] {
        Displays.online().filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.map { (id: $0, bounds: CGDisplayBounds($0)) }
    }

    /// The running processes with this bundle id (case-insensitive).
    static func runningApps(bundleId: String) -> [NSRunningApplication] {
        let want = bundleId.lowercased()
        return NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.lowercased() == want }
    }

    // MARK: Endpoints

    /// `GET /app/windows?bundleId=` → `{ app: AppRef | null, windows: [AppWindowEntry] }`.
    static func list(bundleId: String) -> [String: Any] {
        let apps = runningApps(bundleId: bundleId)
        guard let first = apps.first else { return ["app": NSNull(), "windows": [Any]()] }
        let pids = Set(apps.map(\.processIdentifier))
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let displays = onlineDisplays()
        // minimized: what Accessibility says of the window with the same frame (no Accessibility: never)
        var axWindows: [pid_t: [AXWindowInfo]] = [:]
        let trusted = AXIsProcessTrusted()
        let found = list.compactMap { w -> (AppWindowRecord, pid_t)? in
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  let r = records(from: [w], pids: pids).first else { return nil }
            return (r, pid)
        }
        let owners = Dictionary(found.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        // a system overlay over the whole display is listed by what is drawn in it (its bounds = that), when anything is
        let narrowed = found.map { r, pid -> AppWindowRecord in
            let others = found.filter { $0.1 == pid && $0.0.id != r.id && $0.0.onScreen }.map(\.0.bounds)
            guard let box = liveOverlayContent(r, pid: pid, bundleId: first.bundleIdentifier, others: others, displays: displays) else { return r }
            var piece = r
            piece.bounds = box
            return piece
        }
        let listed = entries(narrowed, bundleId: first.bundleIdentifier, displays: displays) { r in
            guard trusted, let pid = owners[r.id] else { return false }
            if axWindows[pid] == nil { axWindows[pid] = AXWindows.list(pid: pid) }
            let frames = axWindows[pid]!.map(\.frame)
            guard let i = AXWindowMatch.best(target: r.bounds, candidates: frames) else { return false }
            return axWindows[pid]![i].minimized
        }
        let app = AppRef(pid: first.processIdentifier, bundleId: first.bundleIdentifier, name: first.localizedName ?? bundleId,
                         englishName: AppNames.english(bundleId: first.bundleIdentifier))
        return ["app": app.json, "windows": listed.map(\.json)]
    }

    /// The window `id` of any process: its owner and bounds (`kCGWindowListOptionIncludingWindow`, else the whole
    /// list: that option alone misses some off-screen windows, seen with a system overlay's); nil when gone.
    static func window(_ id: CGWindowID) -> (pid: pid_t, record: AppWindowRecord)? {
        func find(_ list: [[String: Any]]) -> [String: Any]? { list.first { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id } }
        let one = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
        guard let w = find(one) ?? find(CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []),
              let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let r = records(from: [w], pids: [pid]).first else { return nil }
        return (pid, r)
    }

    /// A window a request names, with its owner and, for a system overlay over the whole display, what is drawn in it
    /// (`content`, global points: the picture and the element list are of that part only).
    struct Target {
        var pid: pid_t
        var record: AppWindowRecord
        var app: AppRef
        var content: CGRect?
        /// The part of the window the answer is about.
        var frame: CGRect { content ?? record.bounds }
    }

    /// 404 for an unknown window, 403 for this helper's own or a hidden app's (`hide=`, `HiddenApps`).
    static func requireWindow(_ req: HTTPRequest) throws -> Target {
        guard let raw = try req.int("window") else { throw HTTPError(400, "window is required") }
        guard raw > 0, raw <= Int(UInt32.max), let found = window(CGWindowID(raw)) else { throw HTTPError(404, "no window \(raw)") }
        let info = WindowCatalog.runningApp(found.pid)
        let hidden = try HiddenApps.parse(req.query["hide"])
        if found.pid == getpid() || hidden.hides(info.bundleId) {
            throw HTTPError(403, "window \(raw) belongs to a hidden app")
        }
        let app = AppRef(pid: found.pid, bundleId: info.bundleId, name: info.name ?? "pid \(found.pid)", englishName: AppNames.english(bundleId: info.bundleId))
        var content: CGRect?
        if isBackdrop(found.record, bundleId: info.bundleId, displays: onlineDisplays()) {
            let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let others = records(from: all, pids: [found.pid]).filter { $0.id != found.record.id }.map(\.bounds)
            content = liveOverlayContent(found.record, pid: found.pid, bundleId: info.bundleId, others: others, displays: onlineDisplays())
            guard content != nil else { throw HTTPError(409, "window \(raw) shows nothing right now (a system overlay with nothing drawn in it)") }
        }
        return Target(pid: found.pid, record: found.record, app: app, content: content)
    }

    /// `GET /app/screenshot?window=&maxWidth=&quality=`: the window alone (`SCContentFilter(desktopIndependentWindow:)`:
    /// also covered, on another Space or behind the lock screen), no shadow, no pointer. A system overlay's: only what is
    /// drawn in it (`Target.content`), cut from the window's picture at full resolution.
    static func screenshot(_ req: HTTPRequest) throws -> (frame: JPEGFrame, window: CGWindowID, bounds: (CGDirectDisplayID, CGRect)?) {
        let maxWidth = min(max(try req.int("maxWidth") ?? 1280, 160), 3840)
        let quality = min(max(try req.int("quality") ?? 70, 10), 95)
        let target = try requireWindow(req)
        try requireScreenRecording()
        let id = target.record.id
        let displays = onlineDisplays()
        let place = placement(target.frame, displays: displays)
        if !target.record.onScreen, AXIsProcessTrusted(),
           let ax = AXWindows.list(pid: target.pid).first(where: { AXWindowMatch.same($0.frame, target.record.bounds) }), ax.minimized {
            throw HTTPError(409, "window \(id) is minimized")
        }
        let scale = place.map { d in Displays.info(d.id)?.scale ?? 2 } ?? 2
        let part = target.content
        let windowBounds = target.record.bounds
        var image: CGImage
        do {
            image = try blocking(timeout: 5) {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let window = content.windows.first(where: { $0.windowID == id }) else {
                    throw HTTPError(409, "ScreenCaptureKit has no picture of window \(id)")
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                // a part of the window: the whole of it at full resolution first, cut and scaled below
                let size = windowPictureSize(window.frame.size, scale: scale, maxWidth: part == nil ? maxWidth : Int(Int32.max))
                config.width = size.width
                config.height = size.height
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
        } catch let error as HTTPError where error.status == 409 || error.status == 504 {
            throw HTTPError(409, error.status == 504 ? "no picture of window \(id) within 5 s" : error.message)
        } catch {
            let mapped = captureError(error)
            throw mapped.status == 403 ? mapped : HTTPError(409, "no picture of window \(id): \(mapped.message)")
        }
        if let part {
            guard let piece = cut(image, part: part, of: windowBounds) else { throw HTTPError(409, "no picture of window \(id): its content is outside it") }
            image = FrameFilter.downscale(piece, maxWidth: maxWidth)
        }
        guard let jpeg = encodeJPEG(image, quality: quality) else { throw HTTPError(500, "JPEG encoding failed") }
        return (JPEGFrame(data: jpeg, width: image.width, height: image.height, display: place?.id ?? 0), id, place)
    }

    /// `part` (global points) of a picture of the window `bounds`, rounded outward to whole pixels; nil when outside it.
    static func cut(_ image: CGImage, part: CGRect, of bounds: CGRect) -> CGImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let sx = CGFloat(image.width) / bounds.width, sy = CGFloat(image.height) / bounds.height
        let px = CGRect(x: (part.minX - bounds.minX) * sx, y: (part.minY - bounds.minY) * sy, width: part.width * sx, height: part.height * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !px.isNull, px.width >= 2, px.height >= 2 else { return nil }
        return image.cropping(to: px)  // CGImage counts from the top-left
    }

    /// A window picture's pixel size: its points × the display's scale, at most `maxWidth` wide, even.
    static func windowPictureSize(_ points: CGSize, scale: Double, maxWidth: Int) -> (width: Int, height: Int) {
        let pw = max(2, Double(points.width) * scale), ph = max(2, Double(points.height) * scale)
        let width = max(2, min(Int(pw.rounded()), maxWidth)) & ~1
        let height = max(2, Int((Double(width) * ph / pw).rounded())) & ~1
        return (width, height)
    }

    /// `X-Window-Bounds`'s value.
    static func boundsHeader(_ r: CGRect) -> String {
        [r.minX, r.minY, r.width, r.height].map { String(format: "%.4f", Double($0)) }.joined(separator: ",")
    }
}

// MARK: - Accessibility windows

/// A window as Accessibility sees it.
struct AXWindowInfo {
    var element: AXUIElement
    /// Global points, top-left origin (the window list's space).
    var frame: CGRect
    var minimized: Bool
}

/// Which Accessibility window is a window of the window list. `_AXUIElementGetWindow` (the CGWindowID of an AX
/// window) is private API, so the match is by frame: the AX window whose position and size are closest, within
/// `tolerance` points on every edge (the frontmost one in Accessibility's order on a tie).
enum AXWindowMatch {
    static let tolerance: CGFloat = 4

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func best(target: CGRect, candidates: [CGRect]) -> Int? {
        var best: (i: Int, d: CGFloat)?
        for (i, c) in candidates.enumerated() where same(c, target) {
            let d = abs(c.minX - target.minX) + abs(c.minY - target.minY) + abs(c.width - target.width) + abs(c.height - target.height)
            if best == nil || d < best!.d { best = (i, d) }
        }
        return best?.i
    }
}

enum AXWindows {
    /// The app's Accessibility windows (`kAXWindowsAttribute`: the current Space's and the minimized ones). `quiet`:
    /// no log lines (asked of the system overlays on every window list, OverlaySurfaces).
    static func list(pid: pid_t, quiet: Bool = false) -> [AXWindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, FocusProbe.messagingTimeout)
        FocusProbe.enableAccessibility(app)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID() else {
            if !quiet { log("ax: windows of pid \(pid): error \(err.rawValue)") }
            return []
        }
        // a CFArray of AXUIElementRef: bridge each entry by hand (`as? [AXUIElement]` is not a reliable cast)
        let array = value as! CFArray
        let windows = (0..<CFArrayGetCount(array)).compactMap { i -> AXUIElement? in
            guard let raw = CFArrayGetValueAtIndex(array, i) else { return nil }
            let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            return CFGetTypeID(object) == AXUIElementGetTypeID() ? (object as! AXUIElement) : nil
        }
        let infos = windows.compactMap { w -> AXWindowInfo? in
            AXUIElementSetMessagingTimeout(w, FocusProbe.messagingTimeout)
            guard let frame = LiveAXSource.frame(w, quiet: quiet) else { return nil }
            var mini: CFTypeRef?
            let minimized = AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &mini) == .success && (mini as? Bool) == true
            return AXWindowInfo(element: w, frame: frame, minimized: minimized)
        }
        if !quiet, infos.count != windows.count || infos.isEmpty {
            log("ax: windows of pid \(pid): \(windows.count) listed, \(infos.count) with a frame")
        }
        return infos
    }
}
#endif
