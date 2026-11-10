import CoreGraphics
import XCTest
@testable import YoyoServer

/// The agent's view of the window list (Windows.swift): `/windows`, `/hit` and `/frame?visible=&crop=`.
final class WindowsTests: XCTestCase {
    private let finder = AppRef(pid: 100, bundleId: "com.apple.finder", name: "Finder")
    private let main = CGRect(x: 0, y: 0, width: 1000, height: 500)
    private let side = CGRect(x: 1000, y: 0, width: 800, height: 600)

    private func w(_ pid: pid_t, _ bundle: String?, _ name: String, layer: Int = 0, _ rect: CGRect, alpha: Double = 1) -> WindowRecord {
        WindowRecord(pid: pid, bundleId: bundle, name: name, layer: layer, bounds: rect, alpha: alpha)
    }

    /// Front → back: a menu bar, a Terminal over Safari, the Dock, the wallpaper, a Notes window on the side display.
    private func catalog() -> WindowCatalog {
        WindowCatalog(records: [
            w(1, nil, "Window Server", layer: WindowCatalog.mainMenuLevel, CGRect(x: 0, y: 0, width: 1000, height: 25)),
            w(2, "com.apple.systemuiserver", "SystemUIServer", layer: WindowCatalog.statusLevel, CGRect(x: 900, y: 0, width: 30, height: 25)),
            w(3, nil, "Window Server", layer: WindowCatalog.cursorLevel, CGRect(x: 440, y: 260, width: 32, height: 32)),
            w(4, "com.apple.Terminal", "Terminal", CGRect(x: 100, y: 100, width: 400, height: 200)),
            w(5, "com.apple.Safari", "Safari", CGRect(x: 0, y: 50, width: 800, height: 400)),
            w(5, "com.apple.Safari", "Safari", CGRect(x: 50, y: 60, width: 10, height: 10), alpha: 0),
            w(6, "com.apple.dock", "Dock", layer: 20, CGRect(x: 200, y: 450, width: 600, height: 50)),
            w(1, nil, "Window Server", layer: 1000, CGRect(x: 0, y: 0, width: 1000, height: 500)),  // an overlay: left out
            w(7, "com.apple.Notes", "Notes", CGRect(x: 1100, y: 100, width: 400, height: 300)),
            w(6, "com.apple.dock", "Dock", layer: WindowCatalog.desktopIconLevel - 20, main),
        ], displays: [(1, main), (2, side)], finder: finder)
    }

    func testOverlaysAndTransparentWindowsAreLeftOut() {
        let c = catalog()
        XCTAssertEqual(c.records.count, 7)
        XCTAssertFalse(c.records.contains { $0.layer >= WindowCatalog.cursorLevel || $0.alpha == 0 || $0.layer == 1000 })
    }

    /// The Dock's and WindowManager's full-display windows above the apps (layers 20 / 18) are backdrops: not listed,
    /// not hit, not masked; the Dock's bar and a loginwindow's full screen stay.
    func testFullDisplaySystemBackdropsAreLeftOut() {
        let c = WindowCatalog(records: [
            w(6, "com.apple.dock", "Dock", layer: 20, main),
            w(8, "com.apple.WindowManager", "WindowManager", layer: 18, main),
            w(9, "com.apple.notificationcenterui", "Notification Centre", layer: 18, main.insetBy(dx: 2, dy: 2)),
            w(6, "com.apple.dock", "Dock", layer: 20, CGRect(x: 200, y: 450, width: 600, height: 50)),
            w(10, "com.apple.loginwindow", "loginwindow", layer: 2001, main),
            w(5, "com.apple.Safari", "Safari", CGRect(x: 0, y: 50, width: 800, height: 400)),
        ], displays: [(1, main)], finder: finder)
        XCTAssertEqual(c.records.map(\.name), ["Dock", "loginwindow", "Safari"])
        XCTAssertEqual(c.hit(display: 1, x: 0.5, y: 0.5)?.app.name, "loginwindow")
        let noLock = WindowCatalog(records: Array(c.records.filter { $0.name != "loginwindow" }), displays: [(1, main)], finder: finder)
        XCTAssertEqual(noLock.hit(display: 1, x: 0.5, y: 0.5)?.app.name, "Safari")
        XCTAssertEqual(noLock.hit(display: 1, x: 0.5, y: 0.95)?.app, finder)  // the Dock's bar
        XCTAssertEqual(noLock.maskOps(display: 1, visible: ["com.apple.safari"]).count, 1)  // only the Dock's bar is covered
    }

    func testDesktopDockAndMenuBarFoldIntoFinder() {
        let apps = catalog().apps
        XCTAssertEqual(apps.map(\.app.name), ["Finder", "SystemUIServer", "Terminal", "Safari", "Notes"])
        XCTAssertEqual(apps.map(\.windows), [3, 1, 1, 1, 1])  // menu bar, Dock, wallpaper; SystemUIServer is its own
        XCTAssertEqual(apps[0].app, finder)
        // without Finder running they keep their own owner
        let lone = WindowCatalog(records: [w(6, "com.apple.dock", "Dock", layer: 20, CGRect(x: 200, y: 450, width: 600, height: 50))], displays: [(1, main)], finder: nil)
        XCTAssertEqual(lone.apps.first?.app.bundleId, "com.apple.dock")
        // a focused Dock / SystemUIServer is Finder too
        XCTAssertEqual(catalog().appRef(pid: 6, bundleId: "com.apple.dock", name: "Dock"), finder)
        XCTAssertEqual(catalog().appRef(pid: 4, bundleId: "com.apple.Terminal", name: "Terminal").name, "Terminal")
    }

    func testWindowsAreNormalizedOnTheirDisplay() throws {
        let c = catalog()
        let all = c.placed()
        XCTAssertEqual(all.count, 7)
        let terminal = try XCTUnwrap(all.first { $0.pid == 4 })
        XCTAssertEqual(terminal.display, 1)
        XCTAssertEqual(terminal.rect, CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.4))
        let notes = try XCTUnwrap(all.first { $0.pid == 7 })
        XCTAssertEqual(notes.display, 2)
        XCTAssertEqual(notes.rect, CGRect(x: 0.125, y: 100.0 / 600, width: 0.5, height: 0.5))
        XCTAssertEqual(c.placed(display: 2).map(\.pid), [7])
        // a window across two displays is listed on the one holding its center, clipped to it
        let wide = WindowCatalog(records: [w(8, "x", "X", CGRect(x: 600, y: 0, width: 600, height: 100))],
                                 displays: [(1, main), (2, side)], finder: nil)
        XCTAssertEqual(wide.placed().first?.display, 1)
        XCTAssertEqual(wide.placed().first?.rect, CGRect(x: 0.6, y: 0, width: 0.4, height: 0.2))
    }

    func testWindowsJSONHasNoTitles() throws {
        let c = catalog()
        let j = c.json(display: nil, focused: AppRef(pid: 4, bundleId: "com.apple.Terminal", name: "Terminal"))
        let data = try JSONSerialization.data(withJSONObject: j)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apps = try XCTUnwrap(back["apps"] as? [[String: Any]])
        XCTAssertEqual(Set(apps[0].keys), ["pid", "bundleId", "name", "windows"])
        let windows = try XCTUnwrap(back["windows"] as? [[String: Any]])
        XCTAssertEqual(Set(windows[0].keys), ["pid", "display", "x", "y", "w", "h", "layer"])
        XCTAssertEqual((back["focused"] as? [String: Any])?["bundleId"] as? String, "com.apple.Terminal")
        XCTAssertTrue(c.json(display: nil, focused: nil)["focused"] is NSNull)
    }

    func testHitIsTheTopmostWindowAtThePoint() {
        let c = catalog()
        XCTAssertEqual(c.hit(display: 1, x: 0.2, y: 0.3)?.app.name, "Terminal")
        XCTAssertEqual(c.hit(display: 1, x: 0.7, y: 0.3)?.app.name, "Safari")
        XCTAssertEqual(c.hit(display: 1, x: 0.45, y: 0.55)?.app.name, "Terminal")  // the pointer's window is not a hit
        XCTAssertNil(c.hit(display: 1, x: 0.5, y: 0.01), "the menu bar is never Finder's: without Accessibility it has no owner (MenuBarTests)")
        XCTAssertEqual(c.hit(display: 1, x: 0.5, y: 0.95)?.app, finder)  // the Dock
        XCTAssertEqual(c.hit(display: 1, x: 0.95, y: 0.5)?.app, finder)  // the desktop
        XCTAssertEqual(c.hit(display: 1, x: 0.95, y: 0.5)?.layer, WindowCatalog.desktopIconLevel - 20)
        XCTAssertEqual(c.hit(display: 2, x: 0.3, y: 0.3)?.app.name, "Notes")
        XCTAssertNil(c.hit(display: 2, x: 0.9, y: 0.9))  // nothing there
        XCTAssertEqual(c.hit(display: 1, x: 1, y: 1)?.app, finder)  // x = 1 is display 1's last point (its wallpaper)
        XCTAssertNil(c.hit(display: 9, x: 0.5, y: 0.5))
    }

    func testMaskOpsCoverUnlistedAppsBackToFront() throws {
        let c = catalog()
        // nothing visible: the Dock (Finder's), then Safari, then Terminal are covered; the menu bar shows again
        let none = c.maskOps(display: 1, visible: [])
        XCTAssertEqual(none, [
            .mask(CGRect(x: 0.2, y: 0.9, width: 0.6, height: 0.1), label: "Finder"),
            .mask(CGRect(x: 0, y: 0.1, width: 0.8, height: 0.8), label: "Safari"),
            .mask(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.4), label: "Terminal"),
            .reveal(CGRect(x: 0.9, y: 0, width: 0.03, height: 0.05)),
            .reveal(CGRect(x: 0, y: 0, width: 1, height: 0.05)),
        ])
        // Terminal allowed: revealed over the Safari block behind it
        let terminal = c.maskOps(display: 1, visible: ["com.apple.terminal"])
        XCTAssertEqual(terminal.map(\.isMask), [true, true, false, false, false])
        // everything on display 1 allowed: nothing to paint
        XCTAssertEqual(c.maskOps(display: 1, visible: ["com.apple.Terminal", "com.apple.Safari", "com.apple.finder"]), [])
        // the side display only has Notes
        XCTAssertEqual(c.maskOps(display: 2, visible: []), [.mask(CGRect(x: 0.125, y: 100.0 / 600, width: 0.5, height: 0.5), label: "Notes")])
        // a hidden app's block carries no name
        XCTAssertEqual(try c.maskOps(display: 2, visible: [], hidden: .parse("com.apple.notes")),
                       [.mask(CGRect(x: 0.125, y: 100.0 / 600, width: 0.5, height: 0.5), label: "")])
    }

    // MARK: System overlays

    private let nc = "com.apple.notificationcenterui"

    /// Notification Centre's full-display window at level 21 over a full-screen Chrome, with a banner at the top right.
    private func bannerRecords() -> [WindowRecord] {
        [
            w(1, nil, "Window Server", layer: WindowCatalog.mainMenuLevel, CGRect(x: 0, y: 0, width: 1000, height: 25)),
            WindowRecord(pid: 9, bundleId: nc, name: "Notification Centre", layer: 21, bounds: main, id: 70, englishName: "Notification Center"),
            w(6, "com.apple.dock", "Dock", layer: 20, main),
            w(5, "com.google.Chrome", "Google Chrome", CGRect(x: 0, y: 25, width: 1000, height: 475)),
        ]
    }

    private let banner = CGRect(x: 640, y: 35, width: 350, height: 70)

    func testAnOverlayIsNarrowedToItsSurfaces() throws {
        var asked: [pid_t] = []
        let resolved = WindowCatalog.resolvingOverlays(bannerRecords(), displays: [(1, main)]) { r, _ in
            asked.append(r.pid)
            return r.pid == 9 ? [self.banner, CGRect(x: 640, y: 110, width: 350, height: 70), CGRect(x: 2000, y: 0, width: 10, height: 10)] : []
        }
        XCTAssertEqual(asked, [9, 6], "only the full-display system overlays are asked")
        let c = WindowCatalog(records: resolved, displays: [(1, main)], finder: finder)
        XCTAssertEqual(c.records.filter { $0.pid == 9 }.map(\.bounds), [banner, CGRect(x: 640, y: 110, width: 350, height: 70)],
                       "one record per surface on the display; the Dock's empty backdrop stays out")
        XCTAssertFalse(c.records.contains { $0.pid == 6 })
        XCTAssertEqual(c.records.first { $0.pid == 9 }?.id, 70)
        let apps = c.apps
        XCTAssertEqual(apps.map(\.app.bundleId), ["com.apple.finder", nc, "com.google.Chrome"])
        XCTAssertEqual(apps[1].windows, 1, "two surfaces of one window")
        XCTAssertEqual(apps[1].app.englishName, "Notification Center")
        // the banner is hit, Chrome beside it
        XCTAssertEqual(c.hit(display: 1, x: 0.8, y: 0.1)?.app.bundleId, nc)
        XCTAssertEqual(c.hit(display: 1, x: 0.8, y: 0.1)?.layer, 21)
        XCTAssertEqual(c.hit(display: 1, x: 0.3, y: 0.1)?.app.bundleId, "com.google.Chrome")
        // masking: a granted banner shows over a covered Chrome, a banner not granted is covered too
        let granted = c.maskOps(display: 1, visible: [nc])
        XCTAssertEqual(granted.first, .mask(CGRect(x: 0, y: 0.05, width: 1, height: 0.95), label: "Google Chrome"))
        XCTAssertTrue(granted.contains(.reveal(CGRect(x: 0.64, y: 0.07, width: 0.35, height: 0.14))))
        let chrome = c.maskOps(display: 1, visible: ["com.google.chrome"])
        XCTAssertTrue(chrome.contains(.mask(CGRect(x: 0.64, y: 0.07, width: 0.35, height: 0.14), label: "Notification Centre")))
        // nothing found in it: left out as before
        let empty = WindowCatalog(records: WindowCatalog.resolvingOverlays(bannerRecords(), displays: [(1, main)]) { _, _ in [] },
                                  displays: [(1, main)], finder: finder)
        XCTAssertFalse(empty.records.contains { $0.pid == 9 })
        XCTAssertEqual(empty.hit(display: 1, x: 0.8, y: 0.1)?.app.bundleId, "com.google.Chrome")
    }

    func testTheSystemHitTestSeesThroughOverlaysOnly() {
        let panel = CGRect(x: 100, y: 100, width: 300, height: 200)
        let c = WindowCatalog(records: [
            w(1, nil, "Window Server", layer: WindowCatalog.mainMenuLevel, CGRect(x: 0, y: 0, width: 1000, height: 25)),
            w(3, "com.example.palette", "Palette", layer: 3, panel),  // a floating panel, clear in parts
            w(4, "com.apple.Terminal", "Terminal", CGRect(x: 50, y: 50, width: 500, height: 400)),
            w(5, "com.apple.Safari", "Safari", CGRect(x: 0, y: 25, width: 1000, height: 475)),
        ], displays: [(1, main)], finder: finder)
        let inPanel = (x: 0.2, y: 0.4)
        XCTAssertEqual(c.hit(display: 1, x: inPanel.x, y: inPanel.y)?.app.name, "Palette")
        XCTAssertEqual(c.hit(display: 1, x: inPanel.x, y: inPanel.y) { _ in 4 }?.app.name, "Terminal", "the panel is clear there")
        XCTAssertEqual(c.hit(display: 1, x: inPanel.x, y: inPanel.y) { _ in 3 }?.app.name, "Palette")
        XCTAssertEqual(c.hit(display: 1, x: inPanel.x, y: inPanel.y) { _ in 5 }?.app.name, "Palette", "never past a normal window")
        XCTAssertEqual(c.hit(display: 1, x: inPanel.x, y: inPanel.y) { _ in 99 }?.app.name, "Palette", "an unknown pid changes nothing")
        // not asked when no overlay is in front
        var asked = 0
        XCTAssertEqual(c.hit(display: 1, x: 0.9, y: 0.5) { _ in asked += 1; return 3 }?.app.name, "Safari")
        XCTAssertNil(c.hit(display: 1, x: 0.5, y: 0.01) { _ in asked += 1; return 5 }, "the menu bar is no overlay (and no Finder)")
        XCTAssertEqual(asked, 0)
        // the lock screen is no overlay either
        let locked = WindowCatalog(records: [w(10, "com.apple.loginwindow", "loginwindow", layer: 2001, main), w(5, "com.apple.Safari", "Safari", main)],
                                   displays: [(1, main)], finder: finder)
        XCTAssertEqual(locked.hit(display: 1, x: 0.5, y: 0.5) { _ in 5 }?.app.name, "loginwindow")
        XCTAssertTrue(WindowCatalog.isOverlay(w(9, nc, "Notification Centre", layer: 21, banner)))
        XCTAssertFalse(WindowCatalog.isOverlay(w(1, nil, "Window Server", layer: 1000, main)))
    }

    func testEnglishNameIsInTheJSONOnlyWhenItDiffers() {
        XCTAssertEqual(AppRef(pid: 1, bundleId: nc, name: "Notification Centre", englishName: "Notification Center").json["englishName"] as? String,
                       "Notification Center")
        XCTAssertNil(AppRef(pid: 1, bundleId: "com.apple.finder", name: "Finder", englishName: "Finder").json["englishName"])
        XCTAssertNil(AppRef(pid: 1, bundleId: nil, name: "x").json["englishName"])
    }

    func testFilterParsing() throws {
        XCTAssertNil(try FrameFilter.parse(["maxWidth": "800"]))
        XCTAssertEqual(try FrameFilter.parse(["visible": ""]), FrameFilter(visible: [], crop: nil))
        XCTAssertEqual(try FrameFilter.parse(["visible": "com.apple.Safari,com.example.app", "hide": "com.example.*"]),
                       FrameFilter(visible: ["com.apple.Safari"], crop: nil, hidden: try .parse("com.example.*")), "hide= narrows visible=")
        XCTAssertNil(try FrameFilter.parse(["hide": "com.example.*"]), "hide= alone filters nothing")
        XCTAssertEqual(try FrameFilter.parse(["visible": "com.apple.finder, com.apple.Notes,,"])?.visible,
                       ["com.apple.finder", "com.apple.Notes"])
        XCTAssertEqual(try FrameFilter.parseCrop("0.25,0.5,0.5,0.25"), CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        XCTAssertEqual(try FrameFilter.parseCrop("0.75,-0.5,0.5,1"), CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5))
        for bad in ["", "1,2,3", "a,0,1,1", "0,0,0,1", "1,1,0.5,0.5", "nan,0,1,1"] {
            XCTAssertThrowsError(try FrameFilter.parseCrop(bad), bad) { XCTAssertEqual(($0 as? HTTPError)?.status, 400) }
        }
        XCTAssertEqual(FrameFilter.cropHeader(CGRect(x: 0.25, y: 0, width: 0.5, height: 1)), "0.2500,0.0000,0.5000,1.0000")
    }

    func testPixelRectFlipsAndRoundsOutward() {
        XCTAssertEqual(FrameFilter.pixelRect(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.4), width: 100, height: 50),
                       CGRect(x: 10, y: 20, width: 40, height: 20))
        XCTAssertEqual(FrameFilter.pixelRect(CGRect(x: 0.005, y: 0, width: 0.01, height: 0.5), width: 100, height: 10),
                       CGRect(x: 0, y: 5, width: 2, height: 5))
    }

    // MARK: Pictures

    /// A `width`×`height` picture filled with one color.
    private func solid(_ width: Int, _ height: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// The RGB of pixel (`x`, `y`) counted from the top-left.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return px.prefix(3).map(Int.init)
    }

    private func near(_ a: [Int], _ b: [Int], _ tolerance: Int = 6) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    func testMasksPaintBlocksAndRevealFrontWindows() {
        let image = solid(1000, 500, r: 0, g: 0, b: 1)
        let out = FrameFilter.applyMasks(image, ops: catalog().maskOps(display: 1, visible: ["com.apple.Terminal"]),
                                         pixelsPerPoint: 1)
        XCTAssertEqual(out.width, 1000)
        XCTAssertTrue(near(pixel(out, 700, 400), [0x3a, 0x3a, 0x3a]), "\(pixel(out, 700, 400))")  // Safari: covered
        XCTAssertTrue(near(pixel(out, 450, 250), [0, 0, 255]))       // Terminal: shown over Safari's block
        XCTAssertTrue(near(pixel(out, 950, 300), [0, 0, 255]))       // the desktop
        XCTAssertTrue(near(pixel(out, 500, 10), [0, 0, 255]))        // the menu bar
        XCTAssertTrue(near(pixel(out, 700, 480), [0x3a, 0x3a, 0x3a])) // the Dock (Finder not allowed)
        // the label: some white-ish text near the block's top-left corner
        let label = (2..<70).flatMap { x in (52..<70).map { y in pixel(out, x, y) } }
        XCTAssertTrue(label.contains { $0.allSatisfy { $0 > 180 } })
        // nothing to cover: the very same picture
        XCTAssertTrue(FrameFilter.applyMasks(image, ops: [], pixelsPerPoint: 1) === image)
    }

    func testRenderMasksThenCropsThenScales() throws {
        // left half red, right half green
        let ctx = CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 1000, y: 0, width: 1000, height: 1000))
        let image = ctx.makeImage()!
        let c = WindowCatalog(records: [w(4, "com.apple.Terminal", "Terminal", CGRect(x: 0, y: 0, width: 250, height: 500))],
                              displays: [(1, CGRect(x: 0, y: 0, width: 1000, height: 500))], finder: nil)
        let filter = FrameFilter(visible: [], crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let (out, crop) = filter.render(image, catalog: c, display: 1, maxWidth: 400)
        XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 200)
        XCTAssertTrue(near(pixel(out, 100, 100), [0x3a, 0x3a, 0x3a]))  // Terminal covered (the left half of the crop)
        XCTAssertTrue(near(pixel(out, 399, 199), [255, 0, 0]))
        // a crop of the right side, no covering, smaller than maxWidth: native pixels
        let (zoom, used) = FrameFilter(visible: nil, crop: CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.5))
            .render(image, catalog: c, display: 1, maxWidth: 3840)
        XCTAssertEqual(used, CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.5))
        XCTAssertEqual(zoom.width, 500)
        XCTAssertEqual(zoom.height, 500)
        XCTAssertTrue(near(pixel(zoom, 10, 10), [0, 255, 0]))
    }

    func testRecordsFromTheWindowList() {
        let list: [[String: Any]] = [
            [kCGWindowOwnerPID as String: NSNumber(value: 42), kCGWindowLayer as String: NSNumber(value: 0),
             kCGWindowOwnerName as String: "Notes", kCGWindowName as String: "Secret plans",
             kCGWindowBounds as String: CGRect(x: 1, y: 2, width: 3, height: 4).dictionaryRepresentation],
            [kCGWindowOwnerPID as String: NSNumber(value: 7), kCGWindowLayer as String: NSNumber(value: 0),
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 1, height: 1).dictionaryRepresentation],  // this process
            [kCGWindowOwnerPID as String: NSNumber(value: 43), kCGWindowLayer as String: NSNumber(value: 25),
             kCGWindowOwnerName as String: "Window Server", kCGWindowAlpha as String: NSNumber(value: 0.5),
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 10, height: 10).dictionaryRepresentation],
        ]
        let records = WindowCatalog.records(from: list, me: 7, lookup: { pid in pid == 42 ? ("com.apple.Notes", "Notes app") : (nil, nil) },
                                            english: { _ in nil })
        XCTAssertEqual(records, [
            WindowRecord(pid: 42, bundleId: "com.apple.Notes", name: "Notes app", layer: 0, bounds: CGRect(x: 1, y: 2, width: 3, height: 4)),
            WindowRecord(pid: 43, bundleId: nil, name: "Window Server", layer: 25, bounds: CGRect(x: 0, y: 0, width: 10, height: 10), alpha: 0.5),
        ])
    }

    // MARK: Endpoints

    private func request(_ method: String, _ path: String, _ query: [String: String] = [:]) -> (status: Int, body: [String: Any]?) {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[1]) }
        do {  // the connection closes its end when it goes, so the read below ends
            let conn = Connection(fd: fds[0])
            do {
                try Router.handle(HTTPRequest(method: method, path: path, query: query, headers: [:], body: Data()), conn)
            } catch let e as HTTPError {
                conn.error(e)
            } catch {
                XCTFail("\(error)")
            }
        }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fds[1], &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: data, as: UTF8.self)
        let status = Int(text.split(separator: " ")[1]) ?? 0
        let body = text.range(of: "\r\n\r\n").flatMap {
            try? JSONSerialization.jsonObject(with: Data(text[$0.upperBound...].utf8)) as? [String: Any]
        }
        return (status, body)
    }

    func testWindowsEndpoint() throws {
        let r = request("GET", "/windows")
        XCTAssertEqual(r.status, 200)
        let body = try XCTUnwrap(r.body)
        XCTAssertNotNil(body["apps"] as? [[String: Any]])
        XCTAssertNotNil(body["windows"] as? [[String: Any]])
        XCTAssertNotNil(body["focused"])
        XCTAssertEqual(request("POST", "/windows").status, 405)
        XCTAssertEqual(request("GET", "/windows", ["display": "x"]).status, 400)
    }

    func testHitEndpointValidatesThePoint() {
        XCTAssertEqual(request("GET", "/hit", ["y": "0.5"]).status, 400)
        XCTAssertEqual(request("GET", "/hit", ["x": "1.5", "y": "0.5"]).status, 400)
        XCTAssertEqual(request("GET", "/hit", ["x": "0.5", "y": "nan"]).status, 400)
        XCTAssertEqual(request("POST", "/hit").status, 405)
    }
}

private extension MaskOp {
    var isMask: Bool { if case .mask = self { return true } else { return false } }
}
