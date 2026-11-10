#if os(macOS)
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Which app owns what on the screen, for automation (docs/LOCAL-API.md): `GET /windows`,
// `GET /hit` and the `visible=` / `crop=` filter of `GET /frame`. Everything comes from CoreGraphics' window list
// (`CGWindowListCopyWindowInfo`: this login session's own list, answered in a session switched away too), with two
// answers from Accessibility where it can give them (it fails in a session switched away, -25204): the real surfaces of
// a system overlay over the whole display, and which app is under a point an overlay covers (OverlayContent.swift).
// Window titles are never read: they leak content.

/// An app as the agent sees it.
struct AppRef: Equatable {
    var pid: pid_t
    var bundleId: String?
    var name: String
    /// The app's English name when it differs from `name` (the localized one; AppNames).
    var englishName: String? = nil

    var json: [String: Any] {
        var j: [String: Any] = ["pid": Int(pid), "bundleId": bundleId ?? NSNull(), "name": name]
        if let englishName, englishName != name { j["englishName"] = englishName }
        return j
    }
}

/// One on-screen window of the window list (front → back), as CoreGraphics reports it. `bounds` in global display
/// points (top-left origin).
struct WindowRecord: Equatable {
    var pid: pid_t
    var bundleId: String?
    /// The owner app's name (`NSRunningApplication.localizedName`, else the window list's owner name).
    var name: String
    var layer: Int
    var bounds: CGRect
    var alpha: Double = 1
    /// The CGWindowID (`kCGWindowNumber`; the same number as `SCWindow.windowID`); 0 when unknown (tests).
    var id: CGWindowID = 0
    /// The owner app's English name (AppNames), nil when unknown.
    var englishName: String? = nil
}

/// What a `visible=` frame does to one window's area, back → front.
enum MaskOp: Equatable {
    /// A solid block with the owner's name: an app the agent may not see.
    case mask(CGRect, label: String)
    /// The original picture again: a window the agent may see (in front of a block behind it).
    case reveal(CGRect)

    var rect: CGRect {
        switch self {
        case let .mask(r, _), let .reveal(r): return r
        }
    }
}

/// One snapshot of the window list with the displays it lies on.
struct WindowCatalog {
    static let finderBundle = "com.apple.finder"
    /// Desktop furniture that belongs to Finder for the agent: the Dock (and the wallpaper it draws). The menu bar's
    /// processes (Control Centre, SystemUIServer) are apps of their own: their status items and panels are no Finder's.
    static let foldedBundles: Set<String> = ["com.apple.dock"]
    /// The Apple menu's identity in `/hit` (MenuBar.swift): no process of its own (the frontmost app draws it), the
    /// system's commands.
    static let appleMenuBundle = "com.apple.AppleMenu"
    static let appleMenuName = "Apple menu"
    /// The menu bar is a strip at the top of a display at most this tall (points).
    static let menuBarMaxHeight: CGFloat = 80
    /// Room left of the leftmost known status item for icons of apps that did not answer (status items are packed from
    /// the right edge leftward, side by side): a point there may be one of theirs (points).
    static let unansweredItemsMargin: CGFloat = 40
    static let windowServer = "Window Server"

    /// `kCGDesktopIconWindowLevel` and below: the wallpaper and the desktop icons.
    static let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
    static let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
    static let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
    static let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))

    /// Front → back; overlays without an owner the agent could act on are already left out (`include`).
    var records: [WindowRecord]
    var displays: [(id: CGDirectDisplayID, bounds: CGRect)]
    /// Finder, which the desktop, the Dock and the menu bar report as (nil: not running; their own owner then).
    var finder: AppRef?

    /// `records`: front → back; a system overlay over a whole display stays only when it was already narrowed to its
    /// surfaces (`resolvingOverlays`).
    init(records: [WindowRecord], displays: [(id: CGDirectDisplayID, bounds: CGRect)], finder: AppRef?) {
        self.records = records.filter { WindowCatalog.include($0) && !WindowCatalog.isSystemBackdrop($0, displays: displays) }
        self.displays = displays
        self.finder = finder
    }

    /// Desktop-management processes that keep an invisible window over the whole display above the apps (seen on
    /// macOS 27: the Dock at its own level 20, WindowManager at 18, Notification Centre's overlay). Such a window is
    /// no picture and no click target: it would mask the whole screen and catch every hit test.
    static let backdropBundles: Set<String> = ["com.apple.dock", "com.apple.windowmanager", "com.apple.notificationcenterui", "com.apple.controlcenter"]

    /// One of `backdropBundles`' windows that covers (nearly) a whole display above the normal level: left out, unless
    /// Accessibility shows what is drawn in it (`resolvingOverlays`: Notification Centre's banners). Their other real
    /// surfaces (the Dock's bar, the Control Centre panel) are windows of their own and stay.
    static func isSystemBackdrop(_ r: WindowRecord, displays: [(id: CGDirectDisplayID, bounds: CGRect)]) -> Bool {
        guard r.layer > 0, !isMenuBarLayer(r.layer), let id = r.bundleId?.lowercased(), backdropBundles.contains(id) else { return false }
        return displays.contains { d in
            let i = d.bounds.intersection(r.bounds)
            return !i.isNull && i.width * i.height >= 0.98 * d.bounds.width * d.bounds.height
        }
    }

    /// Each full-display system overlay of `records` (`isSystemBackdrop`) replaced by one record per surface that
    /// `surfaces` finds in it (same pid, layer, id; bounds = the surface), or left as it is (then left out) when it finds
    /// none. `surfaces` gets the overlay and the bounds of its process's other windows.
    static func resolvingOverlays(_ records: [WindowRecord], displays: [(id: CGDirectDisplayID, bounds: CGRect)],
                                  surfaces: (WindowRecord, [CGRect]) -> [CGRect]) -> [WindowRecord] {
        records.flatMap { r -> [WindowRecord] in
            guard include(r), isSystemBackdrop(r, displays: displays) else { return [r] }
            let others = records.filter { $0.pid == r.pid && $0.id != r.id }.map(\.bounds)
            let found = surfaces(r, others).compactMap { s -> CGRect? in
                let c = s.intersection(r.bounds)
                return c.isNull || c.width < 1 || c.height < 1 ? nil : c
            }
            guard !found.isEmpty else { return [r] }
            return found.map { var piece = r; piece.bounds = $0; return piece }
        }
    }

    // MARK: Rules (pure)

    static func isDesktopLayer(_ layer: Int) -> Bool { layer <= desktopIconLevel }
    static func isMenuBarLayer(_ layer: Int) -> Bool { layer == mainMenuLevel || layer == statusLevel }

    /// A window at the menu bar's levels that is the system's: the Window Server's menu bar, Apple's processes' (their
    /// status items on older macOS, an input method's candidates). Always in the picture. Another app's window at these
    /// levels (its status item on older macOS, a panel it raised that high) is that app's like any other.
    static func isSystemMenuBar(_ r: WindowRecord) -> Bool {
        guard isMenuBarLayer(r.layer) else { return false }
        if r.bundleId == nil && r.name == windowServer { return true }
        return r.bundleId?.lowercased().hasPrefix("com.apple.") == true
    }

    /// A window making up the menu bar of `display`: at the menu bar's levels, along the display's top edge, a strip.
    static func isMenuBarStrip(_ r: WindowRecord, display: CGRect) -> Bool {
        isMenuBarLayer(r.layer) && abs(r.bounds.minY - display.minY) < 1 && r.bounds.height <= menuBarMaxHeight
    }

    /// Windows that are part of the picture someone could act on: not fully transparent, not the pointer (and the
    /// levels above it), not one of the Window Server's own overlays other than the menu bar and the desktop.
    static func include(_ r: WindowRecord) -> Bool {
        guard r.alpha > 0, r.bounds.width > 0, r.bounds.height > 0, r.layer < cursorLevel else { return false }
        if r.bundleId == nil && r.name == windowServer { return isMenuBarLayer(r.layer) || isDesktopLayer(r.layer) }
        return true
    }

    /// Whether a window counts as Finder's (`/windows`, the pictures; not `/hit` in the menu bar): the desktop layer, the
    /// Dock, the Window Server's menu bar.
    static func foldsIntoFinder(_ r: WindowRecord) -> Bool {
        if isDesktopLayer(r.layer) { return true }
        if let id = r.bundleId?.lowercased(), foldedBundles.contains(id) { return true }
        return r.bundleId == nil && r.name == windowServer
    }

    /// The app the agent sees for `r`.
    func owner(_ r: WindowRecord) -> AppRef {
        if WindowCatalog.foldsIntoFinder(r), let finder { return finder }
        return AppRef(pid: r.pid, bundleId: r.bundleId, name: r.name, englishName: r.englishName)
    }

    /// The app the agent sees for a pid (the focused app): Finder for the folded processes.
    func appRef(pid: pid_t, bundleId: String?, name: String, englishName: String? = nil) -> AppRef {
        if let id = bundleId?.lowercased(), WindowCatalog.foldedBundles.contains(id), let finder { return finder }
        return AppRef(pid: pid, bundleId: bundleId, name: name, englishName: englishName)
    }

    /// A window the system's hit test may see through where it is clear (`hit`'s `axPid`): above the normal level, not
    /// the menu bar, the lock screen / screen saver or one of the Window Server's own.
    static func isOverlay(_ r: WindowRecord) -> Bool {
        guard r.layer > 0, !isMenuBarLayer(r.layer), !NativeFilterPlan.isLockScreen(r) else { return false }
        return !(r.bundleId == nil && r.name == windowServer)
    }

    /// The display a window is listed on: the one holding its center, else the one it overlaps most.
    func display(of bounds: CGRect) -> (id: CGDirectDisplayID, bounds: CGRect)? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if let d = displays.first(where: { $0.bounds.contains(center) }) { return d }
        let overlaps = displays.map { d -> (CGFloat, (id: CGDirectDisplayID, bounds: CGRect)) in
            let i = d.bounds.intersection(bounds)
            return (i.isNull ? 0 : i.width * i.height, d)
        }
        guard let best = overlaps.max(by: { $0.0 < $1.0 }), best.0 > 0 else { return nil }
        return best.1
    }

    /// `rect` (global points) clipped to `display` and normalized 0…1 on it; nil when they don't overlap.
    static func normalized(_ rect: CGRect, on display: CGRect) -> CGRect? {
        let clipped = rect.intersection(display)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0, display.width > 0, display.height > 0 else { return nil }
        return CGRect(x: (clipped.minX - display.minX) / display.width, y: (clipped.minY - display.minY) / display.height,
                      width: clipped.width / display.width, height: clipped.height / display.height)
    }

    // MARK: Answers

    /// Apps with an on-screen window, deduplicated (folded) in front → back order, with how many windows each has (an
    /// overlay's surfaces count as its one window).
    var apps: [(app: AppRef, windows: Int)] {
        var out: [(app: AppRef, windows: Int)] = []
        var index: [pid_t: Int] = [:]
        var seen = Set<CGWindowID>()
        for r in records {
            if r.id != 0, !seen.insert(r.id).inserted { continue }
            let app = owner(r)
            if let i = index[app.pid] {
                out[i].windows += 1
            } else {
                index[app.pid] = out.count
                out.append((app, 1))
            }
        }
        return out
    }

    struct Placed: Equatable {
        var pid: pid_t
        var display: CGDirectDisplayID
        var rect: CGRect
        var layer: Int
    }

    /// The windows front → back, each on its display (normalized, clipped to it); only `display`'s when given.
    func placed(display only: CGDirectDisplayID? = nil) -> [Placed] {
        records.compactMap { r in
            guard let d = display(of: r.bounds), only == nil || d.id == only,
                  let rect = WindowCatalog.normalized(r.bounds, on: d.bounds) else { return nil }
            return Placed(pid: owner(r).pid, display: d.id, rect: rect, layer: r.layer)
        }
    }

    /// The topmost window holding the normalized point (`x`, `y`) of `display`, and its owner. When that window is an
    /// overlay (`isOverlay`: a banner, a popover, an app's floating panel), `axPid` (the system's hit test, global
    /// points; nil = no answer) may say the point is clear there: the answer is then the first window under the point
    /// owned by that pid, looking only through overlays (never past a normal window, the menu bar or the lock screen);
    /// when no such window is found, the topmost one stays. When it is the menu bar (`isMenuBarStrip`), `menuBar` says
    /// whose part of it the point is (`menuBarHit`); nil when it can't.
    func hit(display id: CGDirectDisplayID, x: Double, y: Double, axPid: (CGPoint) -> pid_t? = { _ in nil },
             menuBar: MenuBarSource = .none) -> (app: AppRef, layer: Int, menuBar: MenuBarArea?)? {
        guard let d = displays.first(where: { $0.id == id }) else { return nil }
        // x = 1 / y = 1 is the display's last point, not the next display's first
        let px = d.bounds.minX + min(x * d.bounds.width, d.bounds.width - 0.5)
        let py = d.bounds.minY + min(y * d.bounds.height, d.bounds.height - 0.5)
        let point = CGPoint(x: px, y: py)
        let under = records.filter { $0.bounds.contains(point) }
        guard let top = under.first else { return nil }
        if WindowCatalog.isMenuBarStrip(top, display: d.bounds) {
            return menuBarHit(point, top: top, source: menuBar).map { ($0.app, top.layer, $0.area) }
        }
        if WindowCatalog.isOverlay(top), let pid = axPid(point) {
            for r in under {
                if r.pid == pid { return (owner(r), r.layer, nil) }
                if !WindowCatalog.isOverlay(r) { break }
            }
        }
        return (owner(top), top.layer, nil)
    }

    /// Whose part of the menu bar `point` is (MenuBar.swift): a status item's app (from every app's own status items
    /// first, else the system's hit test), the Apple menu (`appleMenuBundle`), an app's menu → that app, the rest of the
    /// bar (the hidden bar's strip too) → the frontmost app. Without Accessibility only another app's own window there
    /// (`top`, older macOS' status items) is known. When an app did not answer for its status items, a point of the bar
    /// is unknown only from `unansweredItemsMargin` left of the leftmost item found on this strip rightward (none found:
    /// all of it). Never Finder unless Finder is the frontmost app.
    func menuBarHit(_ point: CGPoint, top: WindowRecord, source: MenuBarSource) -> (app: AppRef, area: MenuBarArea)? {
        let ownWindow = WindowCatalog.isSystemMenuBar(top) ? nil : top.pid
        let ax = source.element(point)
        if ax == .unavailable { return ownWindow.map { (app(pid: $0, source: source), .statusItem) } }
        let items = source.statusItems()
        if let item = items.items.first(where: { $0.frame.contains(point) }) { return (app(pid: item.pid, source: source), .statusItem) }
        switch ax {
        case let .statusItem(pid):
            return (app(pid: pid, source: source), .statusItem)
        case let .appMenu(pid, apple: true):
            return (AppRef(pid: pid, bundleId: WindowCatalog.appleMenuBundle, name: WindowCatalog.appleMenuName), .appleMenu)
        case let .appMenu(pid, apple: false):
            return (app(pid: pid, source: source), .appMenu)
        case .appMenuBar, .nothing, .unavailable:
            if let ownWindow { return (app(pid: ownWindow, source: source), .statusItem) }
            // an app that did not answer may hold an icon among the status items (they are packed from the right edge
            // leftward), or just left of them: the bar left of that is the bar all the same
            if !items.complete {
                let strip = top.bounds
                let onStrip = items.items.filter { $0.frame.intersects(strip) }
                guard let leftmost = onStrip.map(\.frame.minX).min(), point.x < leftmost - WindowCatalog.unansweredItemsMargin else { return nil }
            }
            let pid: pid_t?
            if case let .appMenuBar(owner) = ax { pid = owner } else { pid = source.frontmost() ?? records.first(where: { $0.layer == 0 })?.pid }
            return pid.map { (app(pid: $0, source: source), .bar) }
        }
    }

    /// The app the agent sees for a pid, named from the window list when it has a window, else by `source`.
    private func app(pid: pid_t, source: MenuBarSource) -> AppRef {
        if let r = records.first(where: { $0.pid == pid && !($0.bundleId == nil && $0.name == WindowCatalog.windowServer) }) {
            return appRef(pid: pid, bundleId: r.bundleId, name: r.name, englishName: r.englishName)
        }
        let info = source.lookup(pid)
        return appRef(pid: pid, bundleId: info.bundleId, name: info.name ?? "pid \(pid)", englishName: AppNames.english(bundleId: info.bundleId))
    }

    /// What a `visible=` frame of `display` paints, back → front: a block over every window of an app not in
    /// `visible` (bundle ids, case-insensitive), the picture again over every window in front of one that the caller
    /// may see. A hidden app's block (`hidden`) carries no name. The desktop and the system's menu bar
    /// (`isSystemMenuBar`) are never covered. Empty
    /// when nothing is covered.
    func maskOps(display id: CGDirectDisplayID, visible: Set<String>, hidden: HiddenApps = HiddenApps()) -> [MaskOp] {
        guard let d = displays.first(where: { $0.id == id }) else { return [] }
        let allowed = Set(visible.map { $0.lowercased() })
        var ops: [MaskOp] = []
        var masked = false
        for r in records.reversed() {
            guard !WindowCatalog.isDesktopLayer(r.layer), let rect = WindowCatalog.normalized(r.bounds, on: d.bounds) else { continue }
            let app = owner(r)
            if WindowCatalog.isSystemMenuBar(r) || app.bundleId.map({ allowed.contains($0.lowercased()) }) == true {
                if masked { ops.append(.reveal(rect)) }  // nothing to reveal before the first block
            } else {
                ops.append(.mask(rect, label: hidden.hides(app.bundleId) ? "" : app.name))
                masked = true
            }
        }
        return ops
    }

    func json(display only: CGDirectDisplayID?, focused: AppRef?) -> [String: Any] {
        func r(_ v: CGFloat) -> Double { (Double(v) * 10_000).rounded() / 10_000 }
        return [
            "apps": apps.map { a -> [String: Any] in
                var j = a.app.json
                j["windows"] = a.windows
                return j
            },
            "windows": placed(display: only).map { w -> [String: Any] in
                ["pid": Int(w.pid), "display": Int(w.display), "x": r(w.rect.minX), "y": r(w.rect.minY),
                 "w": r(w.rect.width), "h": r(w.rect.height), "layer": w.layer]
            },
            "focused": focused?.json ?? NSNull(),
        ]
    }

    // MARK: The live list

    /// `CGWindowListCopyWindowInfo` entries → records (this process's own windows left out; no titles read).
    static func records(from list: [[String: Any]], me: pid_t = getpid(), lookup: (pid_t) -> (bundleId: String?, name: String?),
                        english: (String?) -> String? = AppNames.english(bundleId:)) -> [WindowRecord] {
        var cache: [pid_t: (bundleId: String?, name: String?)] = [:]
        return list.compactMap { w in
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let info: (bundleId: String?, name: String?)
            if let cached = cache[pid] { info = cached } else { info = lookup(pid); cache[pid] = info }
            let name = info.name ?? (w[kCGWindowOwnerName as String] as? String) ?? "pid \(pid)"
            let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            return WindowRecord(pid: pid, bundleId: info.bundleId, name: name, layer: layer, bounds: bounds, alpha: alpha, id: id,
                                englishName: english(info.bundleId))
        }
    }

    static func runningApp(_ pid: pid_t) -> (bundleId: String?, name: String?) {
        let app = NSRunningApplication(processIdentifier: pid)
        return (app?.bundleIdentifier, app?.localizedName)
    }

    /// The window list now: on-screen windows of every online display (mirror copies left out), the system overlays
    /// narrowed to what Accessibility shows in them (OverlaySurfaces).
    static func current() -> WindowCatalog {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let displays = Displays.online().filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .map { (id: $0, bounds: CGDisplayBounds($0)) }
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundle).first.map {
            AppRef(pid: $0.processIdentifier, bundleId: finderBundle, name: $0.localizedName ?? "Finder", englishName: AppNames.english(bundleId: finderBundle))
        }
        let resolved = resolvingOverlays(records(from: list, lookup: runningApp), displays: displays) { r, others in
            OverlaySurfaces.live(pid: r.pid, bounds: r.bounds, others: others)
        }
        return WindowCatalog(records: resolved, displays: displays, finder: finder)
    }

    /// The app taking keyboard input (FocusProbe), as the agent sees it; nil without Accessibility.
    func focusedApp() -> AppRef? {
        guard let pid = FocusProbe.focusedPID() else { return nil }
        let info = WindowCatalog.runningApp(pid)
        let name = info.name ?? records.first(where: { $0.pid == pid })?.name ?? "pid \(pid)"
        return appRef(pid: pid, bundleId: info.bundleId, name: name, englishName: AppNames.english(bundleId: info.bundleId))
    }
}

// MARK: - `/frame?visible=&hide=&crop=`

/// A caller's filter on a single picture: which apps' windows show (the rest covered), and a region to zoom into.
struct FrameFilter: Equatable {
    /// Bundle ids whose windows show, hidden apps already taken out (`hidden`); nil = no covering.
    var visible: Set<String>?
    /// Normalized 0…1 region, already clipped to the picture.
    var crop: CGRect?
    /// Apps that never show, even when `visible` names them (this app, `hide=`).
    var hidden = HiddenApps()

    static let maskColor = CGColor(srgbRed: 0x3a / 255, green: 0x3a / 255, blue: 0x3a / 255, alpha: 1)
    /// The block's label: the app name in 12 pt (display points) white.
    static let labelPoints: CGFloat = 12

    /// nil when the request has neither `visible` nor `crop` (`hide` only narrows `visible`).
    static func parse(_ query: [String: String]) throws -> FrameFilter? {
        let hidden = try HiddenApps.parse(query["hide"])
        let visible = query["visible"].map(parseVisible)?.filter { !hidden.hides($0) }
        let crop = try query["crop"].map(parseCrop)
        guard visible != nil || crop != nil else { return nil }
        return FrameFilter(visible: visible, crop: crop, hidden: hidden)
    }

    static func parseVisible(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// `x,y,w,h` (normalized) → the region inside 0…1; 400 when malformed or empty after clipping.
    static func parseCrop(_ raw: String) throws -> CGRect {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
              [x, y, w, h].allSatisfy(\.isFinite) else {
            throw HTTPError(400, "crop must be x,y,w,h (normalized 0…1)")
        }
        let x0 = min(max(x, 0), 1), y0 = min(max(y, 0), 1)
        let x1 = min(max(x + w, 0), 1), y1 = min(max(y + h, 0), 1)
        guard x1 > x0, y1 > y0 else { throw HTTPError(400, "crop is empty inside the picture") }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Normalized → this picture's pixel rect (CoreGraphics' bottom-left origin), rounded outward.
    static func pixelRect(_ r: CGRect, width: Int, height: Int) -> CGRect {
        let W = CGFloat(width), H = CGFloat(height)
        // outward, but a hair of floating-point error (0.6 × 50 = 30.000000000000004) is not a pixel
        func down(_ v: CGFloat) -> CGFloat { (v + 1e-6).rounded(.down) }
        func up(_ v: CGFloat) -> CGFloat { (v - 1e-6).rounded(.up) }
        let x0 = down(r.minX * W), x1 = up(r.maxX * W)
        let top = down(r.minY * H), bottom = up(r.maxY * H)
        return CGRect(x: x0, y: H - bottom, width: x1 - x0, height: bottom - top)
            .intersection(CGRect(x: 0, y: 0, width: W, height: H))
    }

    /// Covers per `ops` (normalized to the whole picture); `pixelsPerPoint` sizes the labels.
    static func applyMasks(_ image: CGImage, ops: [MaskOp], pixelsPerPoint: CGFloat) -> CGImage {
        guard !ops.isEmpty else { return image }
        let W = image.width, H = image.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        ctx.draw(image, in: full)
        let fontSize = max(10, labelPoints * pixelsPerPoint)
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        for op in ops {
            let px = pixelRect(op.rect, width: W, height: H)
            guard !px.isEmpty else { continue }
            ctx.saveGState()
            ctx.clip(to: px)
            switch op {
            case let .mask(_, label):
                ctx.setFillColor(maskColor)
                ctx.fill(px)
                let attributed = CFAttributedStringCreate(nil, label as CFString, [
                    kCTFontAttributeName: font, kCTForegroundColorAttributeName: white,
                ] as CFDictionary)!
                let line = CTLineCreateWithAttributedString(attributed)
                let pad = 4 * pixelsPerPoint
                ctx.textPosition = CGPoint(x: px.minX + pad, y: px.maxY - pad - CTFontGetAscent(font))
                CTLineDraw(line, ctx)
            case .reveal:
                ctx.draw(image, in: full)
            }
            ctx.restoreGState()
        }
        return ctx.makeImage() ?? image
    }

    /// The picture of `display` filtered: covered (with `catalog`'s geometry; not when `covering` is false: the
    /// compositor already left the other apps out, NativeFilter.swift), then cropped, then scaled to `maxWidth`.
    /// Also the crop actually used (normalized, after rounding to whole pixels).
    func render(_ image: CGImage, catalog: WindowCatalog, display: CGDirectDisplayID, maxWidth: Int,
                covering: Bool = true) -> (image: CGImage, crop: CGRect?) {
        var out = image
        if let visible, covering {
            let points = catalog.displays.first(where: { $0.id == display })?.bounds.width ?? CGFloat(image.width)
            out = FrameFilter.applyMasks(out, ops: catalog.maskOps(display: display, visible: visible, hidden: hidden),
                                         pixelsPerPoint: CGFloat(image.width) / max(points, 1))
        }
        var used: CGRect?
        if let crop {
            let px = FrameFilter.pixelRect(crop, width: out.width, height: out.height)
            // CGImage.cropping counts from the top-left
            let topLeft = CGRect(x: px.minX, y: CGFloat(out.height) - px.maxY, width: px.width, height: px.height)
            if let cut = out.cropping(to: topLeft) {
                used = CGRect(x: topLeft.minX / CGFloat(out.width), y: topLeft.minY / CGFloat(out.height),
                              width: topLeft.width / CGFloat(out.width), height: topLeft.height / CGFloat(out.height))
                out = cut
            }
        }
        return (FrameFilter.downscale(out, maxWidth: maxWidth), used)
    }

    /// Downscale a CGImage so its width is at most `maxWidth` (never upscales). Even pixel size.
    static func downscale(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard maxWidth > 0, image.width > maxWidth else { return image }
        let targetW = max(2, maxWidth) & ~1
        let targetH = max(2, Int((Double(targetW) * Double(image.height) / Double(image.width)).rounded())) & ~1
        guard let ctx = CGContext(data: nil, width: targetW, height: targetH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        return ctx.makeImage() ?? image
    }

    /// `X-Crop`'s value.
    static func cropHeader(_ r: CGRect) -> String {
        [r.minX, r.minY, r.width, r.height].map { String(format: "%.4f", Double($0)) }.joined(separator: ",")
    }
}
#endif
