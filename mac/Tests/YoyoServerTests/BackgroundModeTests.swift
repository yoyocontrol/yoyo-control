import CoreGraphics
import XCTest
@testable import YoyoServer

/// The native `visible=` filter (NativeFilter.swift) and the background-mode endpoints' pure parts (AppWindows.swift,
/// AppAX.swift).
final class BackgroundModeTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1000, height: 500)
    private let me: pid_t = 999

    private func w(_ id: CGWindowID, _ pid: pid_t, _ bundle: String?, _ name: String, layer: Int = 0,
                   _ rect: CGRect = CGRect(x: 100, y: 100, width: 300, height: 200)) -> WindowRecord {
        WindowRecord(pid: pid, bundleId: bundle, name: name, layer: layer, bounds: rect, id: id)
    }

    /// Front → back, as the window server lists them.
    private var records: [WindowRecord] {
        [
            w(1, 1, nil, "Window Server", layer: WindowCatalog.mainMenuLevel, CGRect(x: 0, y: 0, width: 1000, height: 25)),
            w(2, 2, "com.apple.systemuiserver", "SystemUIServer", layer: WindowCatalog.statusLevel),
            w(3, 30, "com.example.menuextra", "Extra", layer: WindowCatalog.statusLevel),
            w(4, 30, "com.example.menuextra", "Extra", layer: 101),  // its dropdown
            w(5, me, "ca.sarria.yoyocontrol.mac", "Yoyo Control", layer: 1999),  // the border
            w(6, 40, "com.example.client", "Client", layer: 0),
            w(7, 1, nil, "Window Server", layer: 1000, main),  // an overlay
            w(8, 4, "com.apple.Terminal", "Terminal"),
            w(9, 5, "com.apple.Safari", "Safari"),
            w(10, 5, "com.apple.Safari", "Safari", layer: 3),
            w(11, 6, "com.apple.dock", "Dock", layer: 20, CGRect(x: 200, y: 450, width: 600, height: 50)),
            w(12, 6, "com.apple.dock", "Dock", layer: 20, main),  // the full-display backdrop
            w(13, 7, "com.apple.notificationcenterui", "Notification Centre", layer: WindowCatalog.desktopIconLevel + 2),
            w(14, 1, nil, "Window Server", layer: WindowCatalog.desktopIconLevel + 1, CGRect(x: 0, y: 0, width: 1000, height: 94)),
            w(15, 100, "com.apple.finder", "Finder", layer: WindowCatalog.desktopIconLevel, main),  // the icons
            w(16, 100, "com.apple.finder", "Finder"),
            w(17, 8, "com.apple.WindowManager", "WindowManager", layer: WindowCatalog.desktopIconLevel - 21, main),
            w(18, 1, nil, "Window Server", layer: WindowCatalog.desktopIconLevel - 23, main),  // the wallpaper
        ]
    }

    func testNativePlanWithoutFinderKeepsOnlyMenuBarAndWallpaper() {
        let plan = NativeFilterPlan.make(records: records, visible: ["com.apple.Safari"], me: me)
        // Window Server (menu bar, wallpaper), Apple's menu bar process, Safari; another app's status item is that app's
        XCTAssertEqual(plan.includePids, [1, 2, 5])
        // the Window Server's overlay is not wallpaper (its strip above the icons is)
        XCTAssertEqual(Set(plan.exceptWindows), [7])
        XCTAssertFalse(plan.includePids.contains(30), "a status item of an app that is not visible")
        XCTAssertFalse(plan.includePids.contains(me), "the helper's border is never composed")
        XCTAssertFalse(plan.includePids.contains(40), "nor an app that is not visible")
        XCTAssertFalse(plan.includePids.contains(100), "no Finder: no icons, no Finder windows")
        XCTAssertFalse(plan.includePids.contains(4), "Terminal is not visible")
        XCTAssertEqual(Set(plan.showWindows), Set(records.filter { NativeFilterPlan.shows($0, allowed: ["com.apple.safari"], hidden: HiddenApps(), me: me) && $0.id != 0 }.map(\.id)))
        XCTAssertFalse(plan.showWindows.contains(4) || plan.showWindows.contains(7), "hidden windows are not shown")
    }

    func testNativePlanWithFinderAddsTheDesktopAndTheDock() {
        let plan = NativeFilterPlan.make(records: records, visible: ["COM.APPLE.FINDER"], me: me)
        XCTAssertEqual(plan.includePids, [1, 2, 6, 100, 8])
        XCTAssertEqual(Set(plan.exceptWindows), [7], "the menu extra and its dropdown are its own app's, not visible")
        XCTAssertFalse(plan.includePids.contains(7), "desktop widgets are Notification Centre's (above the icon level)")
    }

    func testNativePlanWithNothingVisible() {
        let plan = NativeFilterPlan.make(records: records, visible: [], me: me)
        XCTAssertEqual(plan.includePids, [1, 2])
        XCTAssertTrue(NativeFilterPlan.shows(w(0, 6, "com.apple.dock", "Dock", layer: -2147483626), allowed: [], hidden: HiddenApps(), me: me),
                      "an older macOS's wallpaper is the Dock's")
        XCTAssertFalse(NativeFilterPlan.shows(w(0, 6, "com.apple.dock", "Dock", layer: 20), allowed: [], hidden: HiddenApps(), me: me), "the Dock's bar is Finder's")
    }

    func testAnotherAppsStatusItemShowsOnlyWithTheApp() {
        let plan = NativeFilterPlan.make(records: records, visible: ["com.example.MenuExtra"], me: me)
        XCTAssertEqual(plan.includePids, [1, 2, 30])
        XCTAssertTrue(plan.showWindows.contains(3) && plan.showWindows.contains(4), "its status item and its dropdown")
        XCTAssertTrue(NativeFilterPlan.shows(w(0, 9, "com.apple.TextInputMenuAgent", "TextInputMenuAgent", layer: WindowCatalog.statusLevel),
                                             allowed: [], hidden: HiddenApps(), me: me), "Apple's are the system's menu bar")
    }

    func testTheLockScreenIsAlwaysComposed() {
        let lock = w(30, 50, "com.apple.loginwindow", "loginwindow", layer: 2001, main)
        let saver = w(31, 51, "com.apple.ScreenSaver.Engine", "ScreenSaverEngine", layer: 1000, main)
        let plan = NativeFilterPlan.make(records: [lock, saver] + records, visible: ["com.apple.Safari"], me: me)
        XCTAssertEqual(Array(plan.includePids.prefix(2)), [50, 51])
    }

    func testHiddenAppsAreNeverVisibleEvenWhenAsked() throws {
        let menuBarApp = w(13, 41, "ca.sarria.yoyocontrol.mac", "Yoyo Control", layer: 0)
        let visible: Set<String> = ["com.example.client", "ca.sarria.yoyocontrol.mac", "com.apple.Safari"]
        let open = NativeFilterPlan.make(records: records + [menuBarApp], visible: visible, me: me)
        XCTAssertTrue(open.includePids.contains(40), "a client app is shown when asked and not hidden")
        XCTAssertFalse(open.includePids.contains(41), "this app's menu bar process, another process: never")
        XCTAssertFalse(open.includePids.contains(me))
        let hidden = NativeFilterPlan.make(records: records + [menuBarApp], visible: visible, hidden: try .parse("COM.EXAMPLE.*"), me: me)
        XCTAssertFalse(hidden.includePids.contains(40), "hide= wins over visible=")
        XCTAssertTrue(hidden.includePids.contains(5), "Safari is not hidden")
    }

    func testHiddenAppsPatterns() throws {
        let h = try HiddenApps.parse(" com.example.app , org.example.* ,,")
        XCTAssertTrue(h.hides("ca.sarria.yoyocontrol.mac"), "this app, always")
        XCTAssertTrue(h.hides("COM.example.APP"))
        XCTAssertFalse(h.hides("com.example.app.helper"), "no * : exact")
        XCTAssertTrue(h.hides("org.example.one"))
        XCTAssertFalse(h.hides("com.apple.Safari"))
        XCTAssertFalse(h.hides(nil))
        XCTAssertEqual(try HiddenApps.parse(nil), HiddenApps())
        for bad in ["*", "com.*.app", "a b", "com.example/x", "é.app"] {
            XCTAssertThrowsError(try HiddenApps.parse(bad), bad)
        }
        XCTAssertThrowsError(try HiddenApps.parse(Array(repeating: "a", count: HiddenApps.maxPatterns + 1).joined(separator: ",")))
    }

    // MARK: /app/windows

    private let displays: [(id: CGDirectDisplayID, bounds: CGRect)] = [(1, CGRect(x: 0, y: 0, width: 1000, height: 500)),
                                                                        (2, CGRect(x: 1000, y: 0, width: 800, height: 600))]

    func testAppWindowsKeepsRealWindowsInGroups() {
        let rs = [
            AppWindowRecord(id: 1, layer: 3, bounds: CGRect(x: 10, y: 10, width: 84, height: 77), onScreen: true),  // a palette
            AppWindowRecord(id: 2, layer: 0, bounds: CGRect(x: 100, y: 50, width: 500, height: 400), onScreen: true),
            AppWindowRecord(id: 3, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 33), onScreen: false),  // menu strip
            AppWindowRecord(id: 4, layer: 0, bounds: CGRect(x: 1100, y: 100, width: 400, height: 300), onScreen: false),  // minimized
            AppWindowRecord(id: 5, layer: 0, bounds: CGRect(x: 1200, y: 100, width: 400, height: 300), onScreen: false),  // other Space
            AppWindowRecord(id: 6, layer: 0, bounds: CGRect(x: 100, y: 50, width: 500, height: 400), alpha: 0, onScreen: true),
            AppWindowRecord(id: 7, layer: 24, bounds: CGRect(x: 100, y: 50, width: 500, height: 400), onScreen: true),  // a menu
            AppWindowRecord(id: 8, layer: -20, bounds: CGRect(x: 100, y: 50, width: 500, height: 400), onScreen: true),
            AppWindowRecord(id: 9, layer: 0, bounds: CGRect(x: 600, y: 50, width: 300, height: 300), onScreen: true),
        ]
        let entries = AppWindows.entries(rs, bundleId: "com.example.app", displays: displays) { $0.id == 4 }
        XCTAssertEqual(entries.map(\.id), [2, 9, 1, 5, 4])
        XCTAssertEqual(entries.map(\.minimized), [false, false, false, false, true])
        XCTAssertEqual(entries.map(\.onScreen), [true, true, true, false, false])
        XCTAssertEqual(entries[0].display, 1)
        XCTAssertEqual(entries[0].rect, CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.8))
        XCTAssertEqual(entries[3].display, 2)
        XCTAssertEqual(entries[3].rect.minX, 0.25, accuracy: 1e-9)
    }

    func testPlacementIsUnclipped() throws {
        let p = try XCTUnwrap(AppWindows.placement(CGRect(x: 850, y: -50, width: 200, height: 100), displays: displays))
        XCTAssertEqual(p.id, 1)
        XCTAssertEqual(p.rect, CGRect(x: 0.85, y: -0.1, width: 0.2, height: 0.2))
        XCTAssertEqual(AppWindows.boundsHeader(p.rect), "0.8500,-0.1000,0.2000,0.2000")
        XCTAssertEqual(AppWindows.placement(CGRect(x: 5000, y: 5000, width: 10, height: 10), displays: displays)?.id, 1, "off every display: the first")
    }

    func testWindowPictureSize() {
        XCTAssertTrue(AppWindows.windowPictureSize(CGSize(width: 500, height: 400), scale: 2, maxWidth: 1280) == (1000, 800))
        XCTAssertTrue(AppWindows.windowPictureSize(CGSize(width: 1500, height: 1001), scale: 2, maxWidth: 1280) == (1280, 854))
        XCTAssertTrue(AppWindows.windowPictureSize(CGSize(width: 301, height: 201), scale: 1, maxWidth: 3840) == (300, 200))
    }

    func testAXWindowMatchByFrame() {
        let target = CGRect(x: 100, y: 50, width: 500, height: 400)
        let candidates = [CGRect(x: 0, y: 0, width: 500, height: 400), CGRect(x: 102, y: 50, width: 500, height: 398),
                          CGRect(x: 100, y: 50, width: 500, height: 400)]
        XCTAssertEqual(AXWindowMatch.best(target: target, candidates: candidates), 2)
        XCTAssertEqual(AXWindowMatch.best(target: target, candidates: Array(candidates.prefix(2))), 1)
        XCTAssertNil(AXWindowMatch.best(target: target, candidates: [CGRect(x: 110, y: 50, width: 500, height: 400)]))
        XCTAssertNil(AXWindowMatch.best(target: target, candidates: []))
    }

    // MARK: /app/ax

    /// A tree of `AXNodeInfo`s by name.
    private struct FakeSource: AXElementSource {
        var nodes: [String: AXNodeInfo]
        var tree: [String: [String]]
        var reads: Counter = Counter()
        final class Counter { var n = 0 }

        func info(_ e: String) -> AXNodeInfo? { reads.n += 1; return nodes[e] }
        func children(_ e: String) -> [String] { tree[e] ?? [] }
        func same(_ a: String, _ b: String) -> Bool { a == b }
    }

    private let window = CGRect(x: 100, y: 100, width: 400, height: 200)

    private func node(_ role: String, _ rect: CGRect?, title: String? = nil, description: String? = nil, placeholder: String? = nil,
                      subrole: String? = nil, enabled: Bool = true, focused: Bool = false, selectable: Bool = false) -> AXNodeInfo {
        AXNodeInfo(role: role, subrole: subrole, title: title, description: description, placeholder: placeholder, frame: rect,
                   enabled: enabled, focused: focused, selectable: selectable)
    }

    private func source() -> FakeSource {
        FakeSource(nodes: [
            "win": node("AXWindow", window, title: "Secret document title"),
            "toolbar": node("AXToolbar", CGRect(x: 100, y: 100, width: 400, height: 40)),
            "back": node("AXButton", CGRect(x: 110, y: 110, width: 20, height: 20), description: "Back"),
            "backText": node("AXStaticText", CGRect(x: 110, y: 110, width: 20, height: 20), title: "Back"),
            "search": node("AXTextField", CGRect(x: 200, y: 110, width: 200, height: 20), placeholder: "Search", subrole: "AXSearchField", focused: true),
            "scroll": node("AXScrollArea", CGRect(x: 100, y: 140, width: 400, height: 160)),
            "label": node("AXStaticText", CGRect(x: 110, y: 150, width: 100, height: 20), description: "Results"),
            "silent": node("AXStaticText", CGRect(x: 110, y: 170, width: 100, height: 20)),
            "row1": node("AXRow", CGRect(x: 100, y: 200, width: 400, height: 20), selectable: true),
            "row2": node("AXRow", CGRect(x: 100, y: 280, width: 400, height: 40), selectable: true),  // half out of the scroll area
            "row3": node("AXRow", CGRect(x: 100, y: 400, width: 400, height: 20), selectable: true),  // scrolled away
            "group": node("AXGroup", CGRect(x: 100, y: 200, width: 400, height: 20)),
            "off": node("AXButton", CGRect(x: 600, y: 600, width: 20, height: 20), title: "Elsewhere", enabled: false),
            "noframe": node("AXButton", nil, title: "No frame"),
        ], tree: [
            "win": ["toolbar", "scroll", "off", "noframe"],
            "toolbar": ["back", "search"],
            "back": ["backText"],
            "scroll": ["label", "silent", "row1", "row2", "row3", "group"],
        ])
    }

    func testSummaryWalksActionableElementsInOrder() {
        let s = source()
        let r = AXSummary.collect(root: "win", source: s, window: window) { false }
        XCTAssertEqual(r.elements.map(\.role), ["AXButton", "AXTextField", "AXStaticText", "AXRow", "AXRow"])
        XCTAssertEqual(r.handles, ["back", "search", "label", "row1", "row2"])
        XCTAssertEqual(r.elements.map(\.i), [1, 2, 3, 4, 5])
        XCTAssertEqual(r.elements.map(\.title), ["Back", "Search", "Results", nil, nil])
        XCTAssertFalse(r.elements.contains { $0.title == "Secret document title" }, "the window itself is not listed")
        XCTAssertEqual(r.elements[1].subrole, "AXSearchField")
        XCTAssertFalse(r.truncated)
        // normalized on the window
        XCTAssertEqual(r.elements[0].rect, CGRect(x: 0.025, y: 0.05, width: 0.05, height: 0.1))
        // clipped to the scroll area (bottom at 300 = the window's bottom)
        XCTAssertEqual(r.elements[4].rect.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(r.elements[4].rect.height, 0.1, accuracy: 1e-9)
        XCTAssertEqual(AXSummary.focusedIndex(r, focusedElement: nil, source: s), 2)
    }

    func testSummaryLimitsAndTimeout() {
        let s = source()
        let two = AXSummary.collect(root: "win", source: s, window: window, max: 2) { false }
        XCTAssertEqual(two.elements.count, 2)
        XCTAssertTrue(two.truncated)
        var calls = 0
        let timed = AXSummary.collect(root: "win", source: s, window: window) { calls += 1; return calls > 4 }
        XCTAssertTrue(timed.truncated)
        XCTAssertEqual(timed.handles, ["back"])
        let shallow = AXSummary.collect(root: "win", source: s, window: window, maxDepth: 1) { false }
        XCTAssertEqual(shallow.elements.count, 0, "the toolbar's children are at depth 2")
    }

    func testFocusedFallsBackToTheAppsFocusedElement() {
        var s = source()
        s.nodes["search"]?.focused = false
        let r = AXSummary.collect(root: "win", source: s, window: window) { false }
        XCTAssertEqual(AXSummary.focusedIndex(r, focusedElement: "row1", source: s), 4)
        XCTAssertNil(AXSummary.focusedIndex(r, focusedElement: "silent", source: s))
    }

    func testListedRolesAndLabels() {
        XCTAssertTrue(AXSummary.isListed(node("AXCheckBox", nil), insidePressable: false))
        XCTAssertTrue(AXSummary.isListed(node("AXMenuItem", nil), insidePressable: true))
        XCTAssertFalse(AXSummary.isListed(node("AXCell", nil), insidePressable: false), "not selectable")
        XCTAssertTrue(AXSummary.isListed(node("AXCell", nil, selectable: true), insidePressable: false))
        XCTAssertFalse(AXSummary.isListed(node("AXStaticText", nil, title: "OK"), insidePressable: true))
        XCTAssertFalse(AXSummary.isListed(node("AXGroup", nil, title: "x"), insidePressable: false))
        XCTAssertEqual(node("AXButton", nil, title: "  ", description: "Close", placeholder: "p").label, "Close")
        XCTAssertNil(node("AXButton", nil).label)
        XCTAssertEqual(node("AXButton", nil, title: String(repeating: "a", count: 300)).label?.count, 200)
    }

    func testPressableGroupsAreListedAsAWhole() {
        XCTAssertTrue(AXSummary.isListed(AXNodeInfo(role: "AXGroup", description: "Messages, Anna: lunch?", pressable: true), insidePressable: false))
        XCTAssertFalse(AXSummary.isListed(AXNodeInfo(role: "AXGroup", pressable: true), insidePressable: false), "no label")
        let banner = CGRect(x: 640, y: 35, width: 350, height: 70)
        let s = FakeSource(nodes: [
            "win": node("AXWindow", CGRect(x: 0, y: 0, width: 1000, height: 500)),
            "banner": AXNodeInfo(role: "AXGroup", subrole: "AXNotificationCenterBanner", description: "Messages, Anna: lunch?", frame: banner, pressable: true),
            "text": node("AXStaticText", CGRect(x: 690, y: 45, width: 200, height: 20), title: "Anna"),
            "close": node("AXButton", CGRect(x: 632, y: 27, width: 18, height: 18), description: "Close"),
        ], tree: ["win": ["banner"], "banner": ["text", "close"]])
        let r = AXSummary.collect(root: "win", source: s, window: banner.insetBy(dx: -10, dy: -10)) { false }
        XCTAssertEqual(r.handles, ["banner", "close"], "the banner's text is its label")
        XCTAssertEqual(r.elements.first?.subrole, "AXNotificationCenterBanner")
    }

    // MARK: system overlays

    func testOverlaySurfacesAreTheFirstSmallElementsDown() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let s = FakeSource(nodes: [
            "win": node("AXWindow", area),
            "full": node("AXGroup", area),
            "column": node("AXScrollArea", CGRect(x: 620, y: 0, width: 380, height: 500)),  // too tall: looked inside
            "stack": node("AXGroup", nil),
            "b1": node("AXGroup", CGRect(x: 640, y: 35, width: 350, height: 70)),
            "b1text": node("AXStaticText", CGRect(x: 690, y: 45, width: 200, height: 20)),
            "b2": node("AXGroup", CGRect(x: 640, y: 110, width: 350, height: 70)),
            "inside": node("AXGroup", CGRect(x: 650, y: 40, width: 100, height: 30)),
            "off": node("AXGroup", CGRect(x: 1200, y: 40, width: 100, height: 30)),
        ], tree: ["win": ["full"], "full": ["column", "off"], "column": ["stack"], "stack": ["b1", "b2", "inside"], "b1": ["b1text"]])
        XCTAssertEqual(OverlaySurfaces.collect(root: "win", source: s, area: area) { false },
                       [CGRect(x: 640, y: 35, width: 350, height: 70), CGRect(x: 640, y: 110, width: 350, height: 70)])
        XCTAssertEqual(OverlaySurfaces.collect(root: "win", source: s, area: area, maxNodes: 3) { false }, [], "out of nodes")
        XCTAssertEqual(OverlaySurfaces.union([CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 20, y: 20, width: 10, height: 10)]),
                       CGRect(x: 0, y: 0, width: 30, height: 30))
        XCTAssertNil(OverlaySurfaces.union([]))
    }

    func testOverlayContentOfAppWindows() {
        let full = AppWindowRecord(id: 70, layer: 21, bounds: CGRect(x: 0, y: 0, width: 1000, height: 500), onScreen: true)
        let nc = "com.apple.notificationcenterui"
        let banner = CGRect(x: 640, y: 35, width: 350, height: 70)
        XCTAssertFalse(AppWindows.keep(full, bundleId: nc, displays: displays), "a backdrop as it is")
        let box = AppWindows.overlayContent(full, bundleId: nc, displays: displays) { [banner] }
        XCTAssertEqual(box, banner)
        var narrowed = full
        narrowed.bounds = banner
        XCTAssertTrue(AppWindows.keep(narrowed, bundleId: nc, displays: displays))
        XCTAssertNil(AppWindows.overlayContent(full, bundleId: nc, displays: displays) { [] })
        var off = full
        off.onScreen = false
        XCTAssertNil(AppWindows.overlayContent(off, bundleId: nc, displays: displays) { XCTFail("not asked"); return [banner] })
        let normal = AppWindowRecord(id: 2, layer: 0, bounds: CGRect(x: 100, y: 50, width: 500, height: 400), onScreen: true)
        XCTAssertNil(AppWindows.overlayContent(normal, bundleId: "com.example.app", displays: displays) { [banner] })
    }

    func testCutAPartOfAWindowPicture() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(ctx.makeImage())  // a 100 × 50 pt window at 2×
        let part = try XCTUnwrap(AppWindows.cut(image, part: CGRect(x: 160, y: 210, width: 30.2, height: 20), of: CGRect(x: 100, y: 200, width: 100, height: 50)))
        XCTAssertEqual(part.width, 61)
        XCTAssertEqual(part.height, 40)
        XCTAssertNil(AppWindows.cut(image, part: CGRect(x: 0, y: 0, width: 10, height: 10), of: CGRect(x: 100, y: 200, width: 100, height: 50)))
    }

    func testTheValueIsNeverRead() {
        XCTAssertFalse(LiveAXSource.attributes.contains("AXValue"))
        XCTAssertFalse(LiveAXSource.attributes.contains(kAXValueAttribute as String))
    }

    func testElementJSON() {
        let e = AXSummaryElement(i: 3, role: "AXButton", subrole: nil, title: "OK", rect: CGRect(x: 0.123456, y: 0.5, width: 0.1, height: 0.05),
                                 enabled: false, focused: false)
        let j = e.json
        XCTAssertEqual(j["i"] as? Int, 3)
        XCTAssertEqual(j["x"] as? Double, 0.1235)
        XCTAssertEqual(j["title"] as? String, "OK")
        XCTAssertNil(j["subrole"])
        XCTAssertEqual(j["enabled"] as? Bool, false)
    }
}
