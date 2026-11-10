import CoreGraphics
import XCTest
@testable import YoyoServer

/// `/hit` in the menu bar (MenuBar.swift, `WindowCatalog.menuBarHit`): Accessibility says whose part of the bar a point
/// is; never Finder for the bar itself.
final class MenuBarTests: XCTestCase {
    private let finder = AppRef(pid: 100, bundleId: "com.apple.finder", name: "Finder")
    private let main = CGRect(x: 0, y: 0, width: 1000, height: 500)
    private let chrome: pid_t = 5
    private let controlCentre: pid_t = 20
    private let extra: pid_t = 21

    private func w(_ pid: pid_t, _ bundle: String?, _ name: String, layer: Int = 0, _ rect: CGRect) -> WindowRecord {
        WindowRecord(pid: pid, bundleId: bundle, name: name, layer: layer, bounds: rect)
    }

    /// macOS 27: the whole menu bar is one Window Server window; Chrome below it; the desktop.
    private func catalog(_ extra: [WindowRecord] = []) -> WindowCatalog {
        WindowCatalog(records: extra + [
            w(1, nil, "Window Server", layer: WindowCatalog.mainMenuLevel, CGRect(x: 0, y: 0, width: 1000, height: 25)),
            w(chrome, "com.google.Chrome", "Google Chrome", CGRect(x: 0, y: 25, width: 1000, height: 475)),
            w(100, "com.apple.finder", "Finder", layer: WindowCatalog.desktopIconLevel, main),
        ], displays: [(1, main)], finder: finder)
    }

    private func names(_ pid: pid_t) -> (bundleId: String?, name: String?) {
        switch pid {
        case controlCentre: return ("com.apple.controlcenter", "Control Centre")
        case extra: return ("com.example.extra", "Extra")
        case 22: return ("com.apple.systemuiserver", "SystemUIServer")
        default: return (nil, nil)
        }
    }

    private let clock = StatusItem(pid: 20, frame: CGRect(x: 900, y: 0, width: 80, height: 25))
    private let thirdParty = StatusItem(pid: 21, frame: CGRect(x: 800, y: 0, width: 30, height: 25))

    /// `incomplete`: an app did not answer for its status items.
    private func source(_ ax: MenuBarAX, incomplete: Bool = false, frontmost: pid_t? = 5) -> MenuBarSource {
        MenuBarSource(element: { _ in ax }, statusItems: { StatusItemList(items: [self.clock, self.thirdParty], complete: !incomplete) }, frontmost: { frontmost },
                      lookup: names)
    }

    private func hit(_ x: Double, _ source: MenuBarSource, in c: WindowCatalog? = nil) -> (app: AppRef, layer: Int, menuBar: MenuBarArea?)? {
        (c ?? catalog()).hit(display: 1, x: x, y: 0.02, menuBar: source)
    }

    func testAnAppsMenusAreThatApps() {
        let menu = hit(0.1, source(.appMenu(pid: chrome, apple: false)))
        XCTAssertEqual(menu?.app.bundleId, "com.google.Chrome")
        XCTAssertEqual(menu?.menuBar, .appMenu)
        XCTAssertEqual(menu?.layer, WindowCatalog.mainMenuLevel)
    }

    func testTheAppleMenuIsAnIdentityOfItsOwn() {
        let apple = hit(0.01, source(.appMenu(pid: chrome, apple: true)))
        XCTAssertEqual(apple?.app.bundleId, WindowCatalog.appleMenuBundle)
        XCTAssertEqual(apple?.app.name, "Apple menu")
        XCTAssertEqual(apple?.menuBar, .appleMenu)
    }

    func testAStatusItemIsItsOwnersFromTheAppsOwnTrees() {
        // the apps' own status items win over whatever the hit test says there
        for ax: MenuBarAX in [.appMenuBar(pid: chrome), .nothing, .statusItem(pid: controlCentre), .appMenu(pid: chrome, apple: false)] {
            let third = hit(0.81, source(ax))
            XCTAssertEqual(third?.app.bundleId, "com.example.extra", "\(ax)")
            XCTAssertEqual(third?.menuBar, .statusItem)
        }
        let clockHit = hit(0.95, source(.nothing))
        XCTAssertEqual(clockHit?.app.bundleId, "com.apple.controlcenter")
        XCTAssertEqual(clockHit?.app.name, "Control Centre")
        XCTAssertEqual(clockHit?.app.pid, controlCentre)
        // not in the list (it moved): the hit test's item
        XCTAssertEqual(hit(0.7, source(.statusItem(pid: 22)))?.app.bundleId, "com.apple.systemuiserver")
    }

    func testTheRestOfTheBarIsTheFrontmostAppsNeverFinders() {
        let bar = hit(0.5, source(.nothing))
        XCTAssertEqual(bar?.app.bundleId, "com.google.Chrome", "the hidden bar's strip over a full-screen app: its menus show")
        XCTAssertEqual(bar?.menuBar, .bar)
        XCTAssertEqual(hit(0.5, source(.appMenuBar(pid: chrome), frontmost: nil))?.app.bundleId, "com.google.Chrome")
        XCTAssertEqual(hit(0.5, source(.nothing, frontmost: nil))?.app.bundleId, "com.google.Chrome", "else the frontmost window's")
        XCTAssertEqual(hit(0.5, source(.nothing, frontmost: 100))?.app, finder, "Finder only when its menus show")
    }

    func testUnknownWhenItCantBeTold() {
        // an app did not answer: unknown only where one of its icons may be (among the status items or next to them)
        XCTAssertNil(hit(0.85, source(.nothing, incomplete: true)), "between known items")
        XCTAssertNil(hit(0.99, source(.nothing, incomplete: true)), "right of them")
        XCTAssertNil(hit(0.78, source(.nothing, incomplete: true)), "just left of the leftmost (800): room for one icon")
        let gap = hit(0.5, source(.nothing, incomplete: true))
        XCTAssertEqual(gap?.app.bundleId, "com.google.Chrome", "the empty middle of the bar: the frontmost app's")
        XCTAssertEqual(gap?.menuBar, .bar)
        XCTAssertEqual(hit(0.5, source(.appMenuBar(pid: chrome), incomplete: true))?.app.bundleId, "com.google.Chrome")
        XCTAssertEqual(hit(0.75, source(.nothing, incomplete: true))?.app.bundleId, "com.google.Chrome", "past the margin")
        let none = MenuBarSource(element: { _ in .nothing }, statusItems: { StatusItemList(items: [], complete: false) }, frontmost: { 5 }, lookup: names)
        XCTAssertNil(hit(0.5, none), "no item known: any point may be an unanswered app's")
        let elsewhere = MenuBarSource(element: { _ in .nothing }, statusItems: { StatusItemList(items: [StatusItem(pid: 20, frame: CGRect(x: 1500, y: 0, width: 30, height: 25))], complete: false) },
                                      frontmost: { 5 }, lookup: names)
        XCTAssertNil(hit(0.5, elsewhere), "items of another display's bar don't bound this one")
        XCTAssertEqual(hit(0.81, source(.nothing, incomplete: true))?.app.bundleId, "com.example.extra", "the items found still count")
        XCTAssertEqual(hit(0.1, source(.appMenu(pid: chrome, apple: false), incomplete: true))?.app.bundleId, "com.google.Chrome")
        XCTAssertNil(hit(0.5, .none), "no Accessibility")
        XCTAssertNil(hit(0.5, source(.unavailable)), "a session switched away")
        // the apps' items are not asked without Accessibility
        var asked = 0
        let s = MenuBarSource(element: { _ in .unavailable }, statusItems: { asked += 1; return StatusItemList(items: [], complete: true) }, frontmost: { 5 }, lookup: names)
        XCTAssertNil(hit(0.81, s))
        XCTAssertEqual(asked, 0)
        // an app's own status window (older macOS) is known without it
        let own = catalog([w(extra, "com.example.extra", "Extra", layer: WindowCatalog.statusLevel, CGRect(x: 800, y: 0, width: 30, height: 25))])
        XCTAssertEqual(hit(0.81, .none, in: own)?.app.bundleId, "com.example.extra")
        XCTAssertEqual(hit(0.81, .none, in: own)?.menuBar, .statusItem)
    }

    func testOnlyTheStripAtTheTopIsTheMenuBar() {
        // an input method's candidates at the main-menu level, mid-screen: its own window
        let ime = w(30, "com.apple.inputmethod.SCIM", "Pinyin", layer: WindowCatalog.mainMenuLevel, CGRect(x: 400, y: 200, width: 200, height: 28))
        var asked = 0
        let s = MenuBarSource(element: { _ in asked += 1; return .nothing }, statusItems: { StatusItemList(items: [], complete: true) }, frontmost: { 5 }, lookup: names)
        XCTAssertEqual(catalog([ime]).hit(display: 1, x: 0.5, y: 0.42, menuBar: s)?.app.name, "Pinyin")
        XCTAssertNil(catalog([ime]).hit(display: 1, x: 0.5, y: 0.42, menuBar: s)?.menuBar)
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(WindowCatalog.isMenuBarStrip(w(1, nil, "Window Server", layer: WindowCatalog.mainMenuLevel, CGRect(x: 0, y: 0, width: 1000, height: 33)), display: main))
        XCTAssertFalse(WindowCatalog.isMenuBarStrip(w(1, nil, "Window Server", layer: 0, CGRect(x: 0, y: 0, width: 1000, height: 33)), display: main))
        // a window above the bar (an open menu, Control Centre's panel) is hit as itself
        let panel = w(controlCentre, "com.apple.controlcenter", "Control Centre", layer: 101, CGRect(x: 700, y: 0, width: 300, height: 300))
        XCTAssertEqual(catalog([panel]).hit(display: 1, x: 0.8, y: 0.02, menuBar: s)?.app.bundleId, "com.apple.controlcenter", "no Finder's")
    }

    func testSystemMenuBarWindowsShowAnotherAppsAreCovered() {
        let status = w(extra, "com.example.extra", "Extra", layer: WindowCatalog.statusLevel, CGRect(x: 800, y: 0, width: 30, height: 25))
        XCTAssertTrue(WindowCatalog.isSystemMenuBar(w(1, nil, "Window Server", layer: WindowCatalog.mainMenuLevel, main)))
        XCTAssertTrue(WindowCatalog.isSystemMenuBar(w(2, "com.apple.systemuiserver", "SystemUIServer", layer: WindowCatalog.statusLevel, main)))
        XCTAssertFalse(WindowCatalog.isSystemMenuBar(status))
        XCTAssertFalse(WindowCatalog.isSystemMenuBar(w(2, "com.apple.Terminal", "Terminal", main)))
        let c = catalog([status])
        let ops = c.maskOps(display: 1, visible: ["com.google.Chrome"])
        XCTAssertTrue(ops.contains(.mask(CGRect(x: 0.8, y: 0, width: 0.03, height: 0.05), label: "Extra")))
        XCTAssertFalse(c.maskOps(display: 1, visible: ["com.google.Chrome", "com.example.extra"]).contains { if case .mask = $0 { return true } else { return false } })
    }
}
