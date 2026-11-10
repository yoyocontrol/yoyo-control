import XCTest
import Darwin
import Foundation
@testable import YoyoServer

/// A live drag (`down` … `move` with `button: "left"` … `up`): the input checks, and the stall guard that lifts a
/// button nobody moved or lifted (PointerHold.swift), on an injected clock.
final class PointerHoldTests: XCTestCase {
    func testOnlyTheLeftButtonAndDownUpNeedAPoint() {
        for bad in [InputEvent(type: "move", x: 0.5, y: 0.5, button: "right"), InputEvent(type: "down", x: 0.5),
                    InputEvent(type: "up", y: 0.5)] {
            XCTAssertThrowsError(try Input.plan(bad)) { error in
                XCTAssertEqual((error as? HTTPError)?.status, 400, "\(bad)")
            }
        }
        XCTAssertThrowsError(try Input.heldButton(InputEvent(type: "move", x: 0.5, y: 0.5, button: "middle")))
        XCTAssertEqual(try Input.heldButton(InputEvent(type: "move", x: 0.5, y: 0.5, button: "left")), true)
        XCTAssertEqual(try Input.heldButton(InputEvent(type: "move", x: 0.5, y: 0.5)), false)
    }

    func testADragMovesTheStreamPointer() {
        for (type, button) in [("down", nil), ("move", "left"), ("up", nil)] as [(String, String?)] {
            let p = DisplayPointerGeometry.position(after: InputEvent(type: type, x: 0.3, y: 1.4, button: button))
            XCTAssertEqual(p?.x, 0.3, type)
            XCTAssertEqual(p?.y, 1, type)
        }
    }

    // MARK: The stall guard

    /// A clock the test moves.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
    }

    /// Records the releases.
    private final class Lifts: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(String, Double, Double)] = []
        var list: [(String, Double, Double)] { lock.lock(); defer { lock.unlock() }; return all }
        func release(_ name: String) -> PointerHolds.Release { { x, y in self.lock.lock(); self.all.append((name, x, y)); self.lock.unlock() } }
    }

    func testAPressNobodyMovesOrLiftsIsReleasedAfterTenSeconds() {
        let clock = Clock()
        let lifts = Lifts()
        let holds = PointerHolds(now: { clock.now }, timer: false)
        holds.pressed(display: 91, route: "cg", x: 0.3, y: 0.3, release: lifts.release("cg"))
        clock.advance(6)
        holds.moved(display: 91, x: 0.34, y: 0.35)  // a held move keeps it alive…
        clock.advance(9.9)
        XCTAssertEqual(holds.expire(), [])
        XCTAssertTrue(holds.isHeld(91))
        clock.advance(0.1)  // …until 10 s after the last one
        XCTAssertEqual(holds.expire(), [91])
        XCTAssertFalse(holds.isHeld(91))
        XCTAssertEqual(lifts.list.map(\.0), ["cg"])
        XCTAssertEqual(lifts.list.first?.1, 0.34)
        XCTAssertEqual(lifts.list.first?.2, 0.35)
        clock.advance(20)
        XCTAssertEqual(holds.expire(), [], "released once")
    }

    func testUpForgetsThePressAndLiftsItOnThePathThatPressedIt() {
        let lifts = Lifts()
        let holds = PointerHolds(timer: false)
        holds.pressed(display: 1, route: "cg", x: 0.1, y: 0.1, release: lifts.release("cg"))
        holds.released(display: 1, route: "cg", x: 0.2, y: 0.2)
        XCTAssertTrue(lifts.list.isEmpty, "the up itself lifted it")
        // an up on another path: the press is lifted on the path that pressed it too
        holds.pressed(display: 1, route: "cg", x: 0.1, y: 0.1, release: lifts.release("cg"))
        holds.released(display: 1, route: "other", x: 0.4, y: 0.5)
        XCTAssertEqual(lifts.list.map(\.0), ["cg"])
        XCTAssertEqual(lifts.list.first?.1, 0.4)
        XCTAssertFalse(holds.isHeld(1))
    }

    func testPressesAreKeptPerDisplayAndTheLastStreamClosingReleasesThem() {
        let lifts = Lifts()
        let holds = PointerHolds(timer: false)
        holds.streamOpened()
        holds.streamOpened()
        holds.pressed(display: 1, route: "cg", x: 0.1, y: 0.1, release: lifts.release("one"))
        holds.pressed(display: 2, route: "cg", x: 0.2, y: 0.2, release: lifts.release("two"))
        holds.released(display: 2, route: "cg", x: 0.2, y: 0.2)
        XCTAssertTrue(holds.isHeld(1))
        holds.streamClosed()
        XCTAssertTrue(lifts.list.isEmpty, "another stream is still open")
        holds.streamClosed()
        XCTAssertEqual(lifts.list.map(\.0), ["one"])
        XCTAssertFalse(holds.isHeld(1))
    }

    func testRouterFeedsTheGuardOnlyWithADragsSteps() {
        let lifts = Lifts()
        let holds = PointerHolds(timer: false)
        let rel = lifts.release("x")
        Router.noteHold(InputEvent(type: "click", x: 0.5, y: 0.5), display: 5, route: "cg", holds: holds, release: rel)
        Router.noteHold(InputEvent(type: "move", x: 0.5, y: 0.5), display: 5, route: "cg", holds: holds, release: rel)
        XCTAssertFalse(holds.isHeld(5))
        Router.noteHold(InputEvent(type: "down", x: 0.5, y: 0.5), display: 5, route: "cg", holds: holds, release: rel)
        XCTAssertTrue(holds.isHeld(5))
        Router.noteHold(InputEvent(type: "move", x: 0.6, y: 0.6, button: "left"), display: 5, route: "cg", holds: holds, release: rel)
        Router.noteHold(InputEvent(type: "up", x: 0.6, y: 0.6), display: 5, route: "cg", holds: holds, release: rel)
        XCTAssertFalse(holds.isHeld(5))
        XCTAssertTrue(lifts.list.isEmpty)
    }

    func testTheTimerReleasesOnItsOwn() {
        let lifts = Lifts()
        let holds = PointerHolds(timeout: 0.2)
        holds.pressed(display: 9, route: "cg", x: 0.5, y: 0.5, release: lifts.release("cg"))
        let deadline = Date().addingTimeInterval(3)
        while holds.isHeld(9), Date() < deadline { usleep(20_000) }
        XCTAssertFalse(holds.isHeld(9))
        XCTAssertEqual(lifts.list.count, 1)
    }
}
