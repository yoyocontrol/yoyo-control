import XCTest
import CoreGraphics
import Darwin
import Foundation
@testable import YoyoServer

// Screen connection state (ScreenState.swift, StreamStatus.swift, ConsoleWatch.swift): the pure mapping (the main
// display's ScreenCaptureKit path, `since` only moving with the episode, dedupe), the console debounce, the tracker
// (versions, `/events` lines, waits), the capture callbacks' stats and the Router side: `/status`, `/events` and the
// status parts of a `status=1` stream.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func ms(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }

/// Inputs the test sets; the tracker reads them.
private final class InputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ScreenStateInputs()
    var value: ScreenStateInputs {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

final class ScreenStateTests: XCTestCase {
    // MARK: the pure core

    func testMainDisplay() throws {
        var core = ScreenStateCore()
        var i = ScreenStateInputs()
        i.mainDisplay = 5
        core.update(i, now: t0)
        XCTAssertEqual(core.states.count, 1)
        XCTAssertEqual(core.states[0].display, 5)
        XCTAssertTrue(core.states[0].main)
        XCTAssertEqual(core.states[0].phase, .ready)
        XCTAssertNil(core.states[0].detail)
        i.screenRecording = false
        core.update(i, now: t0 + 1)
        XCTAssertEqual(core.states[0].phase, .unavailable)
        XCTAssertEqual(core.states[0].reason, .noPermission)
        i.loggedIn = false
        core.update(i, now: t0 + 2)
        XCTAssertEqual(core.states[0].reason, .noSession)
        XCTAssertEqual(core.capture.reason, .noSession)
    }

    func testMainDisplayIDCanChangeWithinAnEpisode() {
        var core = ScreenStateCore()
        var i = ScreenStateInputs()
        i.mainDisplay = 1
        core.update(i, now: t0)
        i.mainDisplay = 76
        XCTAssertTrue(core.update(i, now: t0 + 1))
        XCTAssertEqual(core.states[0].display, 76)
        XCTAssertEqual(core.states[0].since, ms(t0), "same phase: same since")
    }

    func testAConsoleChangeIsAChangeButKeepsSince() {
        var core = ScreenStateCore()
        var i = ScreenStateInputs()
        i.console = ConsoleState(locked: false)
        core.update(i, now: t0)
        XCTAssertFalse(core.update(i, now: t0 + 1), "nothing changed")
        i.console = ConsoleState(locked: true)
        XCTAssertTrue(core.update(i, now: t0 + 2))
        XCTAssertEqual(core.console, ConsoleState(locked: true))
        XCTAssertEqual(core.states[0].since, ms(t0), "the display's episode goes on")
    }

    func testStateJSON() throws {
        let s = ScreenDisplayState(display: 7, main: true, phase: .unavailable, reason: .noPermission, since: 1234.4, detail: "d")
        let j = s.json
        XCTAssertEqual(j["display"] as? Int, 7)
        XCTAssertEqual(j["main"] as? Bool, true)
        XCTAssertEqual(j["phase"] as? String, "unavailable")
        XCTAssertEqual(j["reason"] as? String, "no-permission")
        XCTAssertEqual(j["since"] as? Int64, 1234)
        XCTAssertEqual(j["detail"] as? String, "d")
        XCTAssertNil(j["note"])
        XCTAssertNil(j["label"])
        let plain = ScreenDisplayState(display: 1, phase: .ready).json
        XCTAssertNil(plain["main"], "main only when true")
        XCTAssertEqual(Set(plain.keys), ["display", "phase", "since"])
    }

    // MARK: the console

    func testConsoleDetectorDebouncesAndReportsOncePerStableChange() throws {
        let me = ConsoleState(locked: false)
        let locked = ConsoleState(locked: true)
        var d = ConsoleChangeDetector()
        XCTAssertNil(d.step(me, now: 0), "the first poll is the baseline")
        XCTAssertEqual(d.settled, me)
        XCTAssertNil(d.step(me, now: 1))

        XCTAssertNil(d.step(locked, now: 10))      // locked: not before 1.5 s
        XCTAssertNil(d.step(locked, now: 11.4))
        let c1 = try XCTUnwrap(d.step(locked, now: 11.5))
        XCTAssertEqual(c1.from, me)
        XCTAssertEqual(c1.to, locked)
        XCTAssertNil(d.step(locked, now: 12))      // once
        XCTAssertNil(d.step(locked, now: 30))
        XCTAssertEqual(locked.description, "locked")

        // a blip that comes back before it settles: nothing
        XCTAssertNil(d.step(me, now: 50))
        XCTAssertNil(d.step(locked, now: 51))
        XCTAssertNil(d.step(locked, now: 60))
        XCTAssertNil(d.pending)
    }

    // MARK: capture callbacks

    func testCaptureActivityCountsAliveCallbacksAndGaps() throws {
        var a = CaptureActivity(startedAt: 100)
        XCTAssertNil(a.lastAliveAt)
        a.note(.complete, at: 100.1)
        a.note(.idle, at: 100.12)
        a.note(.complete, at: 100.133, gated: true)
        a.note(.blank, at: 100.2)
        a.note(nil, at: 100.25)
        XCTAssertEqual(try XCTUnwrap(a.lastAliveAt), 100.133, accuracy: 1e-9, "blank / no status are not signs of life")
        XCTAssertEqual(try XCTUnwrap(a.lastCompleteAt), 100.133, accuracy: 1e-9, "gated frames count")
        a.note(.idle, at: 101)
        XCTAssertEqual(try XCTUnwrap(a.lastAliveAt), 101, accuracy: 1e-9, "a still picture is alive")
        let w = a.takeWindow(at: 102)
        XCTAssertEqual(w.seconds, 2, accuracy: 1e-9)
        XCTAssertEqual(w.complete, 2)
        XCTAssertEqual(w.idle, 2)
        XCTAssertEqual(w.other, 2)
        XCTAssertEqual(w.gated, 1)
        XCTAssertEqual(w.completeGapsMs.count, 1)
        XCTAssertEqual(try XCTUnwrap(w.gapMs(0.5)), 33, accuracy: 0.01)
        XCTAssertEqual(w.perSecond(w.complete), 1)
        XCTAssertEqual(w.line, "complete 1.0/s idle 1.0/s other 1.0/s gated 1, complete gap p50/90/99 33/33/33 ms")
        let next = a.takeWindow(at: 104)
        XCTAssertEqual(next.complete, 0)
        XCTAssertEqual(next.seconds, 2, accuracy: 1e-9)
        XCTAssertNil(next.gapMs(0.5))
        XCTAssertEqual((next.json["completeGapMs"] as? [Any])?.count, 3)
    }

    // MARK: the tracker

    func testTrackerPublishesOnlyChangesAndWakesWaiters() throws {
        let box = InputBox()
        let tracker = ScreenStateTracker()
        let published = Counter()
        tracker.configure(inputs: { box.value }, onPublish: { published.bump() })
        tracker.refresh()
        let v1 = tracker.version
        XCTAssertEqual(v1, 1)
        tracker.refresh()
        XCTAssertEqual(tracker.version, v1, "same inputs: no new version")
        XCTAssertEqual(published.value, 1)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            var i = box.value
            i.screenRecording = false
            box.value = i
            tracker.setNeedsRefresh()
        }
        let start = Date()
        let v2 = tracker.waitForChange(after: v1, until: Date().addingTimeInterval(3))
        XCTAssertEqual(v2, v1 + 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(tracker.mainState().state.reason, .noPermission)

        let line = ScreenStateTracker.eventLine(states: tracker.snapshot.states, console: ConsoleState(locked: true))
        XCTAssertEqual(line.last, 10)
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(j["type"] as? String, "state")
        let console = try XCTUnwrap(j["console"] as? [String: Any])
        XCTAssertEqual(console as NSDictionary, ["locked": true])
        XCTAssertEqual((j["states"] as? [[String: Any]])?.first?["reason"] as? String, "no-permission")
        let none = try XCTUnwrap(JSONSerialization.jsonObject(with: ScreenStateTracker.eventLine(states: [], console: nil).dropLast()) as? [String: Any])
        XCTAssertTrue(none["console"] is NSNull)

        tracker.start()
        tracker.stop()
        XCTAssertNil(tracker.waitForChange(after: tracker.version, until: Date().addingTimeInterval(1)), "stopped")
    }

    // MARK: Router: /status, /events, status=1 streams

    private var tracker: ScreenStateTracker?

    override func tearDown() {
        tracker?.stop()
        tracker = nil
        super.tearDown()
    }

    /// The main display the streams below are of.
    private let display: CGDirectDisplayID = 76

    /// A tracker registered as `current`, reading `box` (the main display `display`, the console "me").
    private func startTracker(_ box: InputBox = InputBox()) -> ScreenStateTracker {
        var i = box.value
        i.console = ConsoleState(locked: false)
        i.mainDisplay = display
        box.value = i
        let t = ScreenStateTracker()
        t.configure(inputs: { box.value })
        t.start()
        tracker = t
        let deadline = Date().addingTimeInterval(2)
        while t.version == 0, Date() < deadline { usleep(1000) }
        return t
    }

    func testStatusQueryParsing() throws {
        func req(_ v: String?) -> HTTPRequest {
            HTTPRequest(method: "GET", path: "/stream", query: v.map { ["status": $0] } ?? [:], headers: [:], body: Data())
        }
        XCTAssertFalse(try Router.statusRequested(req(nil)))
        XCTAssertFalse(try Router.statusRequested(req("")))
        XCTAssertFalse(try Router.statusRequested(req("0")))
        XCTAssertTrue(try Router.statusRequested(req("1")))
        XCTAssertTrue(try Router.statusRequested(req("true")))
        XCTAssertThrowsError(try Router.statusRequested(req("yes")))
        XCTAssertEqual(try StreamRequestOptions.parse(req("1")), StreamRequestOptions(), "status is no video parameter")
    }

    func testEventsEndpoint() throws {
        let box = InputBox()
        let t = ScreenStateTracker()
        t.configure(inputs: { box.value })
        t.start()
        tracker = t
        // the first computation runs on the tracker's queue: wait for it, or the first line may be the empty snapshot
        let computed = Date().addingTimeInterval(2)
        while t.version == 0, Date() < computed { usleep(1000) }
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let serverFD = fds[0]
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let conn = Connection(fd: serverFD)
            try? Router.events(conn, pingInterval: 0.4)
            done.signal()
        }
        let reader = LineReader(fd: fds[1])
        defer { close(fds[1]) }
        let head = try XCTUnwrap(reader.head())
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"), head)
        XCTAssertTrue(head.contains("Content-Type: application/x-ndjson\r\n"), head)
        XCTAssertTrue(head.contains("Cache-Control: no-cache\r\n"), head)
        let first = try XCTUnwrap(reader.json())
        XCTAssertEqual(first["type"] as? String, "state")
        XCTAssertEqual((first["states"] as? [[String: Any]])?.first?["phase"] as? String, "ready")

        var i = box.value
        i.screenRecording = false
        box.value = i
        t.setNeedsRefresh()
        let second = try XCTUnwrap(reader.json())
        XCTAssertEqual(second["type"] as? String, "state")
        XCTAssertEqual((second["states"] as? [[String: Any]])?.first?["reason"] as? String, "no-permission")
        let ping = try XCTUnwrap(reader.json())
        XCTAssertEqual(ping["type"] as? String, "ping", "nothing changed for the ping interval")

        t.stop()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success, "the service stopping ends the subscription")
    }

    private func status(_ p: StreamPartReader.Part?) throws -> [String: Any] {
        let p = try XCTUnwrap(p)
        XCTAssertEqual(p.headers["content-type"], "application/vnd.yoyo-control.status+json")
        XCTAssertEqual(p.kind, "status")
        XCTAssertEqual(p.names, ["content-type", "content-length", "x-frame-seq", "x-frame-kind"])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: p.body) as? [String: Any])
    }

    /// A `status=1` stream's feed (StreamStatus.swift): the first part at once, a part per change, and an unavailable
    /// state ends the stream after its part.
    func testStatusPartsOfAStream() throws {
        let box = InputBox()
        let t = startTracker(box)
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[1]) }
        let conn = Connection(fd: fds[0])
        let req = HTTPRequest(method: "GET", path: "/stream", query: ["status": "1"], headers: [:], body: Data())
        let feed = try XCTUnwrap(try Router.statusFeed(req, display: display))
        XCTAssertNil(try Router.statusFeed(HTTPRequest(method: "GET", path: "/stream", query: [:], headers: [:], body: Data()),
                                           display: display), "no status=1: no feed")
        let reader = StreamPartReader(fd: fds[1])
        XCTAssertTrue(Router.startStatus(feed, conn))
        let first = try status(reader.part())
        XCTAssertEqual(first["phase"] as? String, "ready")
        XCTAssertEqual(first["display"] as? Int, Int(display))
        XCTAssertEqual(first["main"] as? Bool, true)
        XCTAssertEqual((first["console"] as? [String: Any])?["locked"] as? Bool, false)
        XCTAssertFalse(conn.peerClosed(), "nothing changed: no part, the stream goes on")

        var i = box.value
        i.screenRecording = false
        box.value = i
        t.refresh()
        XCTAssertTrue(conn.peerClosed(), "unavailable: the stream ends")
        let last = try status(reader.part())
        XCTAssertEqual(last["phase"] as? String, "unavailable")
        XCTAssertEqual(last["reason"] as? String, "no-permission")
    }

    func testStatusInStatusJSON() throws {
        _ = startTracker()
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[1]) }
        do { Router.status(Connection(fd: fds[0])) }  // the connection closes: read to EOF
        var all = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let r = read(fds[1], &chunk, chunk.count)
            guard r > 0 else { break }
            all.append(contentsOf: chunk[0..<r])
        }
        let split = try XCTUnwrap(all.range(of: Data("\r\n\r\n".utf8)))
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: all[split.upperBound...]) as? [String: Any])
        let states = try XCTUnwrap(j["states"] as? [[String: Any]])
        XCTAssertEqual(states.count, 1, "the main display's entry only")
        XCTAssertEqual(states[0]["main"] as? Bool, true)
        XCTAssertEqual(states[0]["display"] as? Int, Int(display))
        XCTAssertNil(states[0]["label"])
        XCTAssertEqual((j["console"] as? [String: Any])?["locked"] as? Bool, false)
    }
}

// MARK: - helpers

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Reads an HTTP head, then NDJSON lines.
private final class LineReader {
    let fd: Int32
    private var buffer = [UInt8]()
    init(fd: Int32) {
        self.fd = fd
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }
    func head() -> String? {
        while true {
            if buffer.count >= 4, let i = (0...(buffer.count - 4)).first(where: { Array(buffer[$0..<$0 + 4]) == [13, 10, 13, 10] }) {
                let s = String(decoding: buffer[0..<i + 4], as: UTF8.self)
                buffer.removeFirst(i + 4)
                return s
            }
            guard fill() else { return nil }
        }
    }
    func json() -> [String: Any]? {
        while true {
            if let i = buffer.firstIndex(of: 10) {
                let line = Data(buffer[0..<i])
                buffer.removeFirst(i + 1)
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            }
            guard fill() else { return nil }
        }
    }
}
