import CoreGraphics
import XCTest
@testable import YoyoServer

/// `POST /automation` (Automation.swift): the state machine, the stop key, the border's geometry, the body, and
/// the abort line on `/events`.
final class AutomationTests: XCTestCase {
    func testStartAndStopRunTheirEffectsOnce() {
        var core = AutomationCore()
        XCTAssertEqual(core.set(active: true, label: "Claude"), [.installTap, .showBorder])
        core.tapInstalled(true)
        XCTAssertEqual(core.json["active"] as? Bool, true)
        XCTAssertEqual(core.json["esc"] as? Bool, true)
        XCTAssertEqual(core.set(active: true, label: "Claude"), [], "already active, same label: nothing")
        XCTAssertEqual(core.set(active: true, label: "Script"), [.showBorder], "a new label while active: redrawn")
        XCTAssertEqual(core.label, "Script")
        XCTAssertEqual(core.json["label"] as? String, "Script")
        XCTAssertEqual(core.set(active: false, label: ""), [.removeTap, .hideBorder])
        XCTAssertFalse(core.active)
        XCTAssertFalse(core.esc)
        XCTAssertEqual(core.set(active: false, label: ""), [], "already inactive")
        XCTAssertEqual(core.set(active: true, label: "x"), [.installTap, .showBorder], "every false → true shows the border")
    }

    func testNoTapMeansNoEsc() {
        var core = AutomationCore()
        _ = core.set(active: true, label: "")
        core.tapInstalled(false)
        XCTAssertTrue(core.active)
        XCTAssertFalse(core.esc)
    }

    func testEscapeStopsAndEmitsAbort() {
        var core = AutomationCore()
        _ = core.set(active: true, label: "t")
        core.tapInstalled(true)
        XCTAssertEqual(core.escape(), [.removeTap, .hideBorder, .emitAbort])
        XCTAssertFalse(core.active)
        XCTAssertFalse(core.esc)
        XCTAssertEqual(core.escape(), [], "a late Escape from a tap being removed does nothing")
        XCTAssertEqual(core.set(active: false, label: ""), [], "the client's release after the Esc is a no-op")
    }

    func testTapInstalledAfterStopIsNotEsc() {
        var core = AutomationCore()
        core.tapInstalled(true)
        XCTAssertFalse(core.esc, "never esc while inactive")
    }

    func testStopKeyIsBareEscapeFromSomeoneElse() {
        let me: pid_t = 4242
        XCTAssertTrue(AutomationStopKey.isStop(keyCode: 53, flags: [], sourcePid: 0, me: me))
        XCTAssertTrue(AutomationStopKey.isStop(keyCode: 53, flags: [.maskNonCoalesced], sourcePid: 77, me: me))
        XCTAssertFalse(AutomationStopKey.isStop(keyCode: 53, flags: [.maskCommand], sourcePid: 0, me: me), "⌘Esc is not a stop")
        XCTAssertFalse(AutomationStopKey.isStop(keyCode: 53, flags: [.maskShift], sourcePid: 0, me: me))
        XCTAssertFalse(AutomationStopKey.isStop(keyCode: 53, flags: [], sourcePid: Int64(me), me: me), "our own /input Escape passes")
        XCTAssertFalse(AutomationStopKey.isStop(keyCode: 36, flags: [], sourcePid: 0, me: me), "Return")
    }

    func testBorderAndCapsuleGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(AutomationOverlayGeometry.borderRect(bounds), CGRect(x: 3, y: 3, width: 1506, height: 976))
        let capsule = AutomationOverlayGeometry.capsuleFrame(in: bounds, menuBar: 37, text: CGSize(width: 300.4, height: 16))
        XCTAssertEqual(capsule.width, 329)  // 300.4 + 28, rounded up
        XCTAssertEqual(capsule.height, 28)
        XCTAssertEqual(capsule.midX, bounds.midX, accuracy: 1)
        XCTAssertEqual(capsule.maxY, 982 - 37 - 10)
        let noMenuBar = AutomationOverlayGeometry.capsuleFrame(in: bounds, menuBar: -5, text: CGSize(width: 100, height: 16))
        XCTAssertEqual(noMenuBar.maxY, 972)
    }

    func testCapsuleTextOffersEscOnlyWithTheTap() {
        XCTAssertTrue(AutomationOverlayGeometry.capsuleText(label: "", esc: true, chinese: false).contains("Esc"))
        XCTAssertFalse(AutomationOverlayGeometry.capsuleText(label: "", esc: false, chinese: false).contains("Esc"))
        XCTAssertEqual(AutomationOverlayGeometry.capsuleText(label: "Claude", esc: true, chinese: true), "Claude 正在使用这台电脑 · 按 Esc 停止")
        XCTAssertEqual(AutomationOverlayGeometry.capsuleText(label: "Claude", esc: true, chinese: false),
                       "Claude is using this computer · press Esc to stop")
        XCTAssertEqual(AutomationOverlayGeometry.capsuleText(label: "", esc: false, chinese: false), "Automation is using this computer",
                       "no label: neutral")
        XCTAssertEqual(AutomationOverlayGeometry.capsuleText(label: "", esc: false, chinese: true), "自动化程序正在使用这台电脑")
    }

    func testParseBody() throws {
        let a = try Automation.parse(Data(#"{"active":true,"label":"  Claude\n Code ","title":"Fix it"}"#.utf8))
        XCTAssertEqual(a.active, true)
        XCTAssertEqual(a.label, "Claude Code", "one line; the title is not shown")
        XCTAssertEqual(try Automation.parse(Data(#"{"active":false}"#.utf8)).label, "")
        XCTAssertEqual(try Automation.parse(Data(#"{"active":true,"title":"older client"}"#.utf8)).label, "")
        XCTAssertThrowsError(try Automation.parse(Data(#"{"active":true,"label":3}"#.utf8)))
        XCTAssertThrowsError(try Automation.parse(Data(#"{"active":1}"#.utf8)))
        XCTAssertThrowsError(try Automation.parse(Data(#"{"title":"x"}"#.utf8)))
        XCTAssertThrowsError(try Automation.parse(Data(#"{"active":true,"title":3}"#.utf8)))
        XCTAssertThrowsError(try Automation.parse(Data("nope".utf8)))
        XCTAssertEqual(try Automation.parse(Data(#"{"active":true,"label":"\#(String(repeating: "x", count: 500))"}"#.utf8)).label.count, Automation.maxLabel)
    }

    func testAbortLineAndPostedEvents() throws {
        let line = try XCTUnwrap(String(data: Automation.abortLine, encoding: .utf8))
        XCTAssertEqual(line, "{\"type\":\"abort\",\"reason\":\"esc\"}\n")
        let tracker = ScreenStateTracker()
        let start = tracker.postedSeq
        let version = tracker.version
        tracker.post(Automation.abortLine)
        XCTAssertGreaterThan(tracker.version, version, "wakes /events")
        XCTAssertEqual(tracker.posted(after: start).map(\.line), [Automation.abortLine])
        XCTAssertEqual(tracker.posted(after: tracker.postedSeq).count, 0)
        for _ in 0..<40 { tracker.post(Data("{}\n".utf8)) }
        XCTAssertEqual(tracker.posted(after: 0).count, ScreenStateTracker.postedKept)
    }
}
