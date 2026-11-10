import XCTest
@testable import YoyoServer

/// Input from elsewhere (InputElsewhere.swift): whose events count, the rate rule, the JSON.
final class InputElsewhereTests: XCTestCase {
    func testThisProcessesEventsDoNotCount() {
        XCTAssertNil(InputOrigin.of(sourcePid: 4242, me: 4242), "posted by this process (/input)")
        XCTAssertEqual(InputOrigin.of(sourcePid: 0, me: 4242), .hardware, "no posting process: the HID system")
        XCTAssertEqual(InputOrigin.of(sourcePid: 77, me: 4242), .process(77))
        XCTAssertEqual(InputOrigin.of(sourcePid: -1, me: 4242), .hardware)
        XCTAssertEqual(InputOrigin.of(sourcePid: Int64(Int32.max) + 1, me: 4242), .hardware, "out of pid range")
    }

    func testFirstAtOnceThenAtMostOncePerSecond() {
        var core = InputElsewhereCore()
        XCTAssertNil(core.latest)
        XCTAssertTrue(core.note(InputSighting(at: 10_000, origin: .hardware)), "the first one at once")
        XCTAssertFalse(core.note(InputSighting(at: 10_400, origin: .hardware)))
        XCTAssertFalse(core.note(InputSighting(at: 10_999, origin: .process(5))), "still within the second")
        XCTAssertEqual(core.latest, InputSighting(at: 10_999, origin: .process(5)), "latest is always the newest")
        XCTAssertTrue(core.note(InputSighting(at: 11_000, origin: .hardware)), "a second later: again")
        XCTAssertTrue(core.note(InputSighting(at: 20_000, origin: .hardware)), "after a quiet spell: at once")
        XCTAssertTrue(core.note(InputSighting(at: 15_000, origin: .hardware)), "the clock went back: reported, not stuck")
    }

    func testJSON() {
        let hw = InputSighting(at: 1_761_170_000_123, origin: .hardware).json(app: nil)
        XCTAssertEqual(hw["source"] as? String, "hardware")
        XCTAssertEqual(hw["at"] as? Int64, 1_761_170_000_123)
        XCTAssertNil(hw["pid"])
        let p = InputSighting(at: 5, origin: .process(321)).json(app: (name: "Script Editor", bundleId: "com.apple.ScriptEditor2"))
        XCTAssertEqual(p["source"] as? String, "process")
        XCTAssertEqual(p["pid"] as? Int, 321)
        XCTAssertEqual(p["app"] as? String, "Script Editor")
        XCTAssertEqual(p["bundleId"] as? String, "com.apple.ScriptEditor2")
        let plain = InputSighting(at: 5, origin: .process(321)).json(app: nil)
        XCTAssertEqual(Set(plain.keys), ["at", "source", "pid"], "a plain process: no app fields")
    }

    func testTheMaskHasTheWatchedTypes() {
        let mask = InputElsewhereWatch.mask
        for type: CGEventType in [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseUp, .otherMouseDragged, .mouseMoved, .scrollWheel] {
            XCTAssertNotEqual(mask & (CGEventMask(1) << CGEventMask(type.rawValue)), 0, "\(type.rawValue)")
        }
        XCTAssertEqual(mask & (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue)), 0, "key-ups are not needed")
    }
}

/// `ServiceHost`'s command line.
final class ServiceHostTests: XCTestCase {
    func testParse() throws {
        XCTAssertEqual(try ServiceHost.parse(["x", "--socket", "/tmp/s.sock"], allowsRemote: false),
                       .init(socketPath: "/tmp/s.sock"))
        XCTAssertEqual(try ServiceHost.parse(["x", "--exit-on-stdin-eof", "--socket", "/a", "--remote"], allowsRemote: true),
                       .init(socketPath: "/a", exitOnStdinEOF: true, remote: true))
        XCTAssertThrowsError(try ServiceHost.parse(["x", "--socket", "/a", "--remote"], allowsRemote: false), "remote not offered")
        XCTAssertThrowsError(try ServiceHost.parse(["x"], allowsRemote: true), "no socket")
        XCTAssertThrowsError(try ServiceHost.parse(["x", "--socket"], allowsRemote: true), "socket without a path")
        XCTAssertThrowsError(try ServiceHost.parse(["x", "--socket", "/a", "--bogus"], allowsRemote: true))
        XCTAssertEqual(try ServiceHost.parse(["x", "--socket", "/a", "--remote", "--no-link"], allowsRemote: true),
                       .init(socketPath: "/a", remote: true, noLink: true))
    }

    func testUsage() {
        XCTAssertEqual(ServiceHost.usage(program: "svc", allowsRemote: false), "usage: svc --socket <path> [--exit-on-stdin-eof]")
        XCTAssertTrue(ServiceHost.usage(program: "svc", allowsRemote: true).hasSuffix("[--remote]"))
    }
}
