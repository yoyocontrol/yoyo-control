#if os(macOS)
import CoreGraphics
import Foundation
import ScreenCaptureKit

// `GET /frame?visible=` drawn by the compositor (docs/PROTOCOL.md 「屏幕」, docs/LOCAL-API.md): ScreenCaptureKit
// composes only the windows the agent may see, `SCContentFilter(display:including:exceptingWindows:)`, so nothing of a
// covered app is ever in the picture (no block over it either: the desktop shows where it was). When that path can't
// be taken (the API throws, an app to include has no `SCRunningApplication`, no picture within 5 s) the frame falls
// back to round 1's covering (`FrameFilter.applyMasks`); `X-Frame-Filter: native | mask` says which.
//
// Which windows show (`NativeFilterPlan.shows`), with the window list's own processes:
// - never this process's windows (the automation border, Automation.swift), this app's (`ca.sarria.yoyocontrol*`: the
//   menu bar app is another process) nor those of an app the request hides (`hide=`, `HiddenApps`);
// - always the system's menu bar (the main-menu and status levels' windows of the Window Server and Apple's processes,
//   `WindowCatalog.isSystemMenuBar`; on macOS 27 the whole bar with every status item is one Window Server window, so
//   another app's status item shows too: it is no window of its own to leave out), the wallpaper (the Window
//   Server's, the Dock's and the wallpaper agent's windows below the normal level), and the lock screen / screen
//   saver (loginwindow, com.apple.ScreenSaver*: a locked Mac's picture is its lock screen, as without `visible=`);
//   another app's window at the menu bar's levels (its status item on older macOS) only like its other windows;
// - Finder's windows, the desktop icons and the rest of the desktop layer and the Dock's bar only when
//   `com.apple.finder` is in `visible` (round 1's folding); Control Centre's and SystemUIServer's other windows (the
//   Control Centre panel…) when their own bundle id is;
// - any other window when its owner's bundle id is in `visible` (case-insensitive).
// ScreenCaptureKit takes applications, not windows: an app is included when any of its windows shows, and its other
// windows on the list are excepted.

/// The native filter for one picture: the apps to include (pids, first seen front → back) and the windows of those
/// apps to leave out.
struct NativeFilterPlan: Equatable {
    var includePids: [pid_t]
    var exceptWindows: [CGWindowID]
    /// The windows that show, front → back (ids; 0 = unknown, left out): the preferred, exact filter.
    var showWindows: [CGWindowID] = []

    /// Processes whose windows below the normal level are the wallpaper.
    static let wallpaperBundles: Set<String> = ["com.apple.dock", "com.apple.wallpaper.agent", "com.apple.wallpaperagent"]
    static func isWallpaperOwner(_ r: WindowRecord) -> Bool {
        if r.bundleId == nil && r.name == WindowCatalog.windowServer { return true }
        guard let id = r.bundleId?.lowercased() else { return false }
        return wallpaperBundles.contains(id) || id.hasPrefix("com.apple.wallpaper")
    }

    /// The lock screen and the screen saver: over everything, always in the picture (a locked Mac looks locked; the
    /// agent's clicks would land on it anyway).
    static func isLockScreen(_ r: WindowRecord) -> Bool {
        guard let id = r.bundleId?.lowercased() else { return false }
        return id == "com.apple.loginwindow" || id.hasPrefix("com.apple.screensaver")
    }

    /// Whether `r` is in the picture for `allowed` (lowercased bundle ids).
    static func shows(_ r: WindowRecord, allowed: Set<String>, hidden: HiddenApps, me: pid_t) -> Bool {
        if r.pid == me || hidden.hides(r.bundleId) { return false }
        if r.layer >= WindowCatalog.cursorLevel { return false }
        if isLockScreen(r) || WindowCatalog.isSystemMenuBar(r) { return true }
        if r.layer < 0 && isWallpaperOwner(r) { return true }
        // the Window Server's other overlays are no app's
        if r.bundleId == nil && r.name == WindowCatalog.windowServer { return false }
        if WindowCatalog.foldsIntoFinder(r) { return allowed.contains(WindowCatalog.finderBundle) }
        return r.bundleId.map { allowed.contains($0.lowercased()) } ?? false
    }

    /// The plan for the on-screen window list `records` (front → back, unfiltered) and `visible`.
    static func make(records: [WindowRecord], visible: Set<String>, hidden: HiddenApps = HiddenApps(),
                     me: pid_t = getpid()) -> NativeFilterPlan {
        let allowed = Set(visible.map { $0.lowercased() })
        var include: [pid_t] = []
        var included = Set<pid_t>()
        var left: [WindowRecord] = []
        var show: [CGWindowID] = []
        for r in records {
            if shows(r, allowed: allowed, hidden: hidden, me: me) {
                if included.insert(r.pid).inserted { include.append(r.pid) }
                if r.id != 0 { show.append(r.id) }
            } else {
                left.append(r)
            }
        }
        let except = left.filter { included.contains($0.pid) && $0.id != 0 }.map(\.id)
        return NativeFilterPlan(includePids: include, exceptWindows: except, showWindows: show)
    }
}

/// Apps a caller never gets to see (`/frame?visible=`, `/app/screenshot`, `/app/ax`): this app (its menu bar process
/// is not the service's) and the ones the request names in `hide=` (comma-separated bundle ids, case-insensitive; a
/// trailing `*` matches every id with that prefix; at most `maxPatterns`). A hidden app beats `visible=`. A local client
/// hides its own apps this way: `hide=com.example.mine*`.
struct HiddenApps: Equatable, Sendable {
    /// This app, whatever its suffix (`ca.sarria.yoyocontrol.mac`, a fork's build).
    static let own = "ca.sarria.yoyocontrol*"

    /// Lowercased patterns, `own` first.
    private(set) var patterns: [String]

    static let maxPatterns = 64

    init(_ extra: [String] = []) {
        patterns = ([Self.own] + extra).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// `hide=`'s value (nil: only this app); 400 for an entry that is not a bundle id (letters, digits, `.`, `-`, `_`)
    /// with an optional trailing `*`, or for more than `maxPatterns` of them.
    static func parse(_ raw: String?) throws -> HiddenApps {
        let entries = (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard entries.count <= maxPatterns else { throw HTTPError(400, "hide names more than \(maxPatterns) apps") }
        for e in entries {
            let id = e.hasSuffix("*") ? e.dropLast() : Substring(e)
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else {
                throw HTTPError(400, "hide: \(e.prefix(80)) is not a bundle id (a trailing * matches a prefix)")
            }
        }
        return HiddenApps(entries)
    }

    func hides(_ bundleId: String?) -> Bool {
        guard let id = bundleId?.lowercased() else { return false }
        return patterns.contains { p in p.hasSuffix("*") ? id.hasPrefix(p.dropLast()) : id == p }
    }
}

/// Why the native path was not taken (logged; the frame is then covered instead).
struct NativeFilterUnavailable: Error, CustomStringConvertible {
    var description: String
}

/// The ScreenCaptureKit filter for `plan` on `display` from `content`; throws when an app to include is not in
/// `content` (it quit, or ScreenCaptureKit doesn't list it).
func nativeContentFilter(_ plan: NativeFilterPlan, display: SCDisplay, content: SCShareableContent) throws -> SCContentFilter {
    // By window first: the exact list (the menu bar's and the wallpaper's windows belong to the Window Server, which
    // is no SCRunningApplication, so an app-based filter would drop the menu bar). Only when ScreenCaptureKit lists
    // every window to show; else by app, and the menu bar may be missing.
    let byId = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
    let shown = plan.showWindows.compactMap { byId[$0] }
    if !plan.showWindows.isEmpty, shown.count == plan.showWindows.count {
        return SCContentFilter(display: display, including: shown)
    }
    log("frame: native filter by app (\(plan.showWindows.count - shown.count) of \(plan.showWindows.count) windows to show are not in the shareable content)")
    var apps: [SCRunningApplication] = []
    for pid in plan.includePids {
        guard let app = content.applications.first(where: { $0.processID == pid }) else {
            throw NativeFilterUnavailable(description: "no SCRunningApplication for pid \(pid)")
        }
        apps.append(app)
    }
    let except = Set(plan.exceptWindows)
    let windows = content.windows.filter { except.contains($0.windowID) }
    return SCContentFilter(display: display, including: apps, exceptingWindows: windows)
}

/// This process's on-screen windows in `content` (the automation border): left out of every picture.
func ownWindows(_ content: SCShareableContent) -> [SCWindow] {
    let me = getpid()
    return content.windows.filter { $0.owningApplication?.processID == me }
}
#endif
