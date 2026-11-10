import XCTest
@testable import YoyoServer

// A still picture's refines (VideoStreamLoop.swift `RefineSchedule`, StreamTuning `refineBitrate`): the first
// `refineIdle` after the live picture, then every `refineEvery` until two in a row come out no bigger than one live
// picture's budget (a skip is not small), at most `videoRefines`; new content re-arms. The Linux server's
// flow.mjs `RefineSchedule` / `refineKbps` run by the same rule (linux/test/refine.test.mjs).
final class RefineScheduleTests: XCTestCase {
    func testRepeatsEveryRefineEveryWhileBig() {
        var r = RefineSchedule(.default)
        XCTAssertNil(r.dueAt, "nothing sent: nothing to refine")
        r.noteLive(at: 10)
        XCTAssertEqual(r.dueAt!, 10.3, accuracy: 1e-9)
        XCTAssertFalse(r.isDue(at: 10.29))
        XCTAssertTrue(r.isDue(at: 10.3))
        for i in 1..<10 {
            r.noteRefined(at: 10 + Double(i), bytes: 5000, budget: 1000)
            XCTAssertEqual(r.dueAt!, 10 + Double(i) + 0.1, accuracy: 1e-9, "refine \(i): the next one 100 ms later")
        }
    }

    func testTwoSmallInARowStop() {
        var r = RefineSchedule(.default)
        r.noteLive(at: 0)
        r.noteRefined(at: 1, bytes: 100, budget: 1000)  // small: right after a scroll the encoder's budget may be spent
        XCTAssertNotNil(r.dueAt, "one small refine is no proof")
        r.noteRefined(at: 2, bytes: 5000, budget: 1000)  // big again: the run starts over
        r.noteRefined(at: 3, bytes: 1000, budget: 1000)  // ≤ the budget: small
        r.noteRefined(at: 4, bytes: nil, budget: 1000)  // skipped (VideoToolbox over its 1 s cap): the run starts over
        XCTAssertNotNil(r.dueAt, "a skip says nothing about the picture")
        r.noteRefined(at: 5, bytes: nil, budget: 1000)
        XCTAssertNotNil(r.dueAt, "nor do two")
        r.noteRefined(at: 6, bytes: 10, budget: 1000)
        r.noteRefined(at: 7, bytes: 0, budget: 1000)
        XCTAssertNil(r.dueAt, "two small in a row: as sharp as this rate makes it")
        XCTAssertEqual(r.sent, 7, "skips count toward videoRefines")
    }

    func testCapReArmAndCancel() {
        var r = RefineSchedule(.default)
        r.noteLive(at: 0)
        for i in 1...19 { r.noteRefined(at: Double(i), bytes: 1_000_000, budget: 1000) }
        XCTAssertNotNil(r.dueAt)
        r.noteRefined(at: 20, bytes: 1_000_000, budget: 1000)
        XCTAssertNil(r.dueAt, "20 refines: done until the next change")
        r.noteLive(at: 30)
        XCTAssertEqual(r.dueAt!, 30.3, accuracy: 1e-9, "a change re-arms")
        XCTAssertEqual(r.sent, 0)
        r.noteRefined(at: 31, bytes: 10, budget: 1000)
        r.noteLive(at: 32)
        r.noteRefined(at: 33, bytes: 10, budget: 1000)
        XCTAssertNotNil(r.dueAt, "the small run starts over after a change too")
        r.cancel()
        XCTAssertNil(r.dueAt)
        var none = RefineSchedule(idle: 0.3, every: 0.1, limit: 0, smallInARow: 2)
        none.noteLive(at: 0)
        XCTAssertNil(none.dueAt, "videoRefines 0: no refines")
    }

    func testLiveBudget() {
        XCTAssertEqual(RefineSchedule.liveBudget(bitsPerSecond: 300_000, fps: 30), 1250, accuracy: 1e-9)
        XCTAssertEqual(RefineSchedule.liveBudget(bitsPerSecond: 3_500_000, fps: 30), 3_500_000 / 8 / 30, accuracy: 1e-9)
    }

    func testRefineBitrate() {
        let t = StreamTuning.default
        XCTAssertEqual(t.refineBitrate(normal: 3_500_000, ceiling: 20_000_000, congested: false), 7_000_000)
        XCTAssertEqual(t.refineBitrate(normal: 300_000, ceiling: 20_000_000, congested: false), 4_000_000)
        XCTAssertEqual(t.refineBitrate(normal: 1_500_000, ceiling: 2_500_000, congested: false), 2_500_000, "the profile's ceiling")
        XCTAssertEqual(t.refineBitrate(normal: 3_000_000, ceiling: 2_500_000, congested: false), 3_000_000, "never below the stream's own rate")
        XCTAssertEqual(t.refineBitrate(normal: 3_500_000, ceiling: 20_000_000, congested: true), 3_500_000, "queueing: no boost")
        // a link stream: refines every 100 ms at 30 fps add up to at most its target (rate ≤ fps × refineEvery = 3×)
        XCTAssertEqual(t.refineBitrate(normal: 300_000, ceiling: 20_000_000, congested: false, linkFPS: 30), 900_000)
        XCTAssertEqual(t.refineBitrate(normal: 3_500_000, ceiling: 20_000_000, congested: false, linkFPS: 30), 7_000_000)
        XCTAssertEqual(t.refineBitrate(normal: 1_000_000, ceiling: 20_000_000, congested: false, linkFPS: 10), 1_000_000,
                       "10 fps: no room for a boost")
    }
}
