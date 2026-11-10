import XCTest
import Darwin
import Foundation
@testable import YoyoServer

// Pipelined pointer moves (docs/PROTOCOL.md 「屏幕」, `ScreenInput.seq`): the phone has up to 3 moves in flight, so one
// may overtake another; a move older than one already applied is answered `stale` and not applied — before any routing.

final class PointerMoveGateTests: XCTestCase {
    func testAnOlderMoveIsStaleANewerOrEqualOneApplies() {
        var g = PointerMoveGate()
        XCTAssertTrue(g.admit(seq: 10, at: 0))
        XCTAssertTrue(g.admit(seq: 12, at: 0.01))
        XCTAssertFalse(g.admit(seq: 11, at: 0.02), "overtaken by 12")
        XCTAssertEqual(g.last?.seq, 12, "a stale move doesn't change the count")
        XCTAssertTrue(g.admit(seq: 12, at: 0.03), "a repeat of the newest applies")
        XCTAssertTrue(g.admit(seq: 13, at: 0.04))
        XCTAssertFalse(g.admit(seq: 0, at: 0.05))
    }

    func testTwoSecondsWithoutAMoveStartOver() {
        var g = PointerMoveGate()
        XCTAssertTrue(g.admit(seq: 500, at: 10))
        XCTAssertFalse(g.admit(seq: 499, at: 11.99))
        XCTAssertTrue(g.admit(seq: 1, at: 12), "2 s after the last applied move: a new count")
        XCTAssertTrue(g.admit(seq: 2, at: 12.1))
        XCTAssertFalse(g.admit(seq: 1, at: 12.2))
    }

    /// The phone starts its count at the wall clock in ms (~1.76e12): 64-bit, and a later visit continues above.
    func testWallClockSizedSeqs() {
        var g = PointerMoveGate()
        let start: Int64 = 1_761_400_000_123
        XCTAssertTrue(g.admit(seq: start, at: 0))
        XCTAssertTrue(g.admit(seq: start + 2, at: 0.01))
        XCTAssertFalse(g.admit(seq: start + 1, at: 0.02))
        XCTAssertEqual(g.last?.seq, start + 2)
        // Another device / page visit a minute of wall clock later: above the old values, applies.
        XCTAssertTrue(g.admit(seq: start + 60_000, at: 0.5))
        XCTAssertFalse(g.admit(seq: start + 59_999, at: 0.55))
        // An old page's late move, ≥ 1000 below: it starts the count over (as written; the phone's counts don't mix).
        XCTAssertTrue(g.admit(seq: start + 3, at: 0.6))
    }

    func testAFarLowerSeqStartsOver() {
        var g = PointerMoveGate()
        XCTAssertTrue(g.admit(seq: 5000, at: 0))
        XCTAssertFalse(g.admit(seq: 4001, at: 0.1), "999 below: stale")
        XCTAssertTrue(g.admit(seq: 4000, at: 0.2), "1000 below: a new client / queue")
        XCTAssertTrue(g.admit(seq: 4001, at: 0.3))
        XCTAssertFalse(g.admit(seq: 4000, at: 0.4))
    }

    /// `POST /input` on a socketpair: the status and the JSON body.
    private func post(_ body: String) throws -> (Int, [String: Any]?) {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[1]) }
        let conn = Connection(fd: fds[0])
        do {
            try Router.handle(HTTPRequest(method: "POST", path: "/input", query: [:], headers: [:], body: Data(body.utf8)), conn)
        } catch let e as HTTPError {
            conn.error(e)
        }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fds[1], &buf, buf.count)
        let text = String(decoding: buf[0..<max(n, 0)], as: UTF8.self)
        let status = Int(text.split(separator: " ")[1]) ?? 0
        let json = text.range(of: "\r\n\r\n").flatMap {
            (try? JSONSerialization.jsonObject(with: Data(text[$0.upperBound...].utf8))) as? [String: Any]
        }
        return (status, json)
    }

    func testTheRouteAnswersAStaleMoveBeforeAnyRouting() throws {
        let display = 0x7FFF_0001  // no such display: a move that is routed fails (404; 503 on a Mac without displays)
        // A wall-clock-sized count (the phone's), clear of other tests' counts.
        let base = Int64(Date().timeIntervalSince1970 * 1000) + Int64.random(in: 1..<1000) * 10_000
        let (applied, appliedBody) = try post(#"{"type":"move","display":\#(display),"x":0.5,"y":0.5,"seq":\#(base + 5)}"#)
        XCTAssertTrue([404, 503].contains(applied), "applied: routed to the (missing) display, got \(applied)")
        XCTAssertNil(appliedBody?["stale"])
        let (stale, body) = try post(#"{"type":"move","display":\#(display),"x":0.4,"y":0.4,"seq":\#(base + 3)}"#)
        XCTAssertEqual(stale, 200)
        XCTAssertEqual(body?["ok"] as? Bool, true)
        XCTAssertEqual(body?["stale"] as? Bool, true)
        // Without seq (an older client), and on another type: routed as always.
        XCTAssertEqual(try post(#"{"type":"move","display":\#(display),"x":0.4,"y":0.4}"#).0, applied)
        XCTAssertEqual(try post(#"{"type":"click","display":\#(display),"x":0.4,"y":0.4,"seq":1}"#).0, applied)
        // Not a non-negative integer: 400.
        XCTAssertEqual(try post(#"{"type":"move","display":\#(display),"x":0.4,"y":0.4,"seq":-1}"#).0, 400)
        XCTAssertEqual(try post(#"{"type":"move","display":\#(display),"x":0.4,"y":0.4,"seq":1.5}"#).0, 400)
        XCTAssertEqual(try post(#"{"type":"move","display":\#(display),"x":0.4,"y":0.4,"seq":"7"}"#).0, 400)
    }
}
