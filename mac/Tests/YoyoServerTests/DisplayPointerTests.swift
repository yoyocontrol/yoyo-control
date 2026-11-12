import XCTest
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
@testable import YoyoServer

// cursor=client on a real display's ScreenCaptureKit video stream (DisplayPointer.swift, VideoStreamLoop.swift):
// cursor parts before the first picture, after input, with the shape when it changed, none without `cursor=client`;
// the tracker's positions (input, polled location, other displays) and shapes; the capture configuration.

final class FakeCursorFeed: DisplayCursorFeed, @unchecked Sendable {
    private let lock = NSLock()
    private var cursor = ClientCursor(x: 0.5, y: 0.5, visible: true, shapeId: 0)
    private var shapes: [Int: ClientCursorShape] = [:]
    private var onChange: (@Sendable () -> Void)?

    init() { shapes[0] = Self.shape(0) }

    static func shape(_ id: Int) -> ClientCursorShape {
        ClientCursorShape(id: id, png: Data([0x89, 0x50, 0x4E, 0x47, UInt8(id)]), hotX: 0.001, hotY: 0.002, width: 0.01, height: 0.02)
    }

    func current() -> (cursor: ClientCursor, shape: ClientCursorShape?) {
        lock.lock(); defer { lock.unlock() }
        return (cursor, shapes[cursor.shapeId])
    }
    func observe(_ onChange: @escaping @Sendable () -> Void) { lock.lock(); self.onChange = onChange; lock.unlock() }
    func set(x: Double, y: Double, shapeId: Int? = nil) {
        lock.lock()
        cursor.x = x
        cursor.y = y
        if let shapeId { cursor.shapeId = shapeId; if shapes[shapeId] == nil { shapes[shapeId] = Self.shape(shapeId) } }
        let f = onChange
        lock.unlock()
        f?()
    }
}

final class FakePointerProbe: SystemPointerProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _location: CGPoint?
    private var _image: SystemCursorImage?
    var locationValue: CGPoint? {
        get { lock.lock(); defer { lock.unlock() }; return _location }
        set { lock.lock(); _location = newValue; lock.unlock() }
    }
    var imageValue: SystemCursorImage? {
        get { lock.lock(); defer { lock.unlock() }; return _image }
        set { lock.lock(); _image = newValue; lock.unlock() }
    }
    func location() -> CGPoint? { locationValue }
    func cursorImage() -> SystemCursorImage? { imageValue }
}

final class DisplayPointerTests: XCTestCase {
    // MARK: the stream

    private func cursorJSON(_ p: StreamPartReader.Part) throws -> [String: Any] {
        XCTAssertEqual(p.kind, "cursor")
        XCTAssertEqual(p.headers["content-type"], "application/vnd.yoyo-control.cursor+json")
        XCTAssertNil(p.headers["x-frame-width"])
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: p.body) as? [String: Any])
    }

    private func picture(_ scroll: Int) -> CVPixelBuffer {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 400, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
        paintDesktop(b!, scroll: scroll)
        return b!
    }

    func testCursorPartsBeforeThePictureAndOnChanges() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        let source = FakeVideoSource()
        let feed = FakeCursorFeed()
        var http = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &http), 0)
        var o = VideoStreamOptions(codec: .h264)
        o.streamID = "display-cursor-1"
        o.tuning.videoWindow = 1
        o.tuning.maxVideoWindow = 1
        o.interval = 0.02
        o.tuning.keepalive = 60
        o.tuning.videoRefines = 0
        source.cursorFeed = feed
        let done = DispatchSemaphore(value: 0)
        let serverFD = http[0]
        source.push(picture(0))  // a picture is already waiting: the cursor part still comes first
        Thread.detachNewThread {
            Router.videoStreamLoop(source, Connection(fd: serverFD), o)
            done.signal()
        }
        let reader = StreamPartReader(fd: http[1])
        let first = try XCTUnwrap(reader.part())
        let c0 = try cursorJSON(first)
        XCTAssertEqual(c0["x"] as? Double, 0.5)
        XCTAssertEqual(c0["visible"] as? Bool, true)
        XCTAssertEqual(c0["shapeId"] as? Int, 0)
        let shape0 = try XCTUnwrap(c0["shape"] as? [String: Any], "the first part carries the shape")
        XCTAssertEqual(shape0["id"] as? Int, 0)
        XCTAssertEqual(shape0["width"] as? Double, 0.01)
        let key = try XCTUnwrap(reader.part())
        XCTAssertEqual(key.kind, "key")
        XCTAssertGreaterThan(key.seq, first.seq)

        // The window (W = 1) is full, no ack: input still moves the pointer at once (cursor parts are outside it).
        feed.set(x: 0.3, y: 0.3)
        let moved = try cursorJSON(try XCTUnwrap(reader.part()))
        XCTAssertEqual(moved["x"] as? Double, 0.3)
        XCTAssertEqual(moved["y"] as? Double, 0.3)
        XCTAssertNil(moved["shape"], "same shape: not sent again")

        // A new shape: sent with the part that switches to it.
        feed.set(x: 0.31, y: 0.3, shapeId: 1)
        let reshaped = try cursorJSON(try XCTUnwrap(reader.part()))
        XCTAssertEqual(reshaped["shapeId"] as? Int, 1)
        XCTAssertEqual((reshaped["shape"] as? [String: Any])?["id"] as? Int, 1)
        // Back to the arrow this stream already sent: no payload.
        feed.set(x: 0.32, y: 0.3, shapeId: 0)
        let back = try cursorJSON(try XCTUnwrap(reader.part()))
        XCTAssertEqual(back["shapeId"] as? Int, 0)
        XCTAssertNil(back["shape"])
        close(http[1])
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    }

    func testNoCursorPartsWithoutCursorClient() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        let source = FakeVideoSource()
        var http = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &http), 0)
        var o = VideoStreamOptions(codec: .h264)
        o.interval = 0.02
        o.tuning.keepalive = 60
        o.tuning.videoRefines = 1
        o.tuning.refineIdle = 0.1
        let done = DispatchSemaphore(value: 0)
        let serverFD = http[0]
        source.push(picture(0))
        Thread.detachNewThread {
            Router.videoStreamLoop(source, Connection(fd: serverFD), o)
            done.signal()
        }
        let reader = StreamPartReader(fd: http[1])
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "key")
        StrictTiming.sleep(0.03)
        source.push(picture(10))
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "delta")
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "refine")
        close(http[1])
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    }

    /// The stats line counts the cursor parts.
    func testCursorPartsInStats() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _stats: [[String: Any]] = []
            func add(_ s: [String: Any]) { lock.lock(); _stats.append(s); lock.unlock() }
            var stats: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _stats }
        }
        let source = FakeVideoSource()
        let feed = FakeCursorFeed()
        let box = Box()
        var http = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &http), 0)
        var o = VideoStreamOptions(codec: .h264)
        o.interval = 0.02
        o.tuning.keepalive = 60
        o.tuning.videoRefines = 0
        o.statsInterval = 0.3
        source.cursorFeed = feed
        o.onStats = { box.add($0) }
        let done = DispatchSemaphore(value: 0)
        let serverFD = http[0]
        source.push(picture(0))
        Thread.detachNewThread {
            Router.videoStreamLoop(source, Connection(fd: serverFD), o)
            done.signal()
        }
        let reader = StreamPartReader(fd: http[1])
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "cursor")
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "key")
        feed.set(x: 0.2, y: 0.2)
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "cursor")
        let until = Date().addingTimeInterval(2)
        while box.stats.isEmpty, Date() < until { usleep(10_000) }
        close(http[1])
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        let s = try XCTUnwrap(box.stats.first)
        XCTAssertEqual((s["sent"] as? [String: Any])?["cursorParts"] as? Int, 2)
        let flow = try XCTUnwrap(s["flow"] as? [String: Any])
        XCTAssertEqual(flow["cursor"] as? String, "client")
        XCTAssertEqual(flow["cursorParts"] as? Int, 2)
        XCTAssertTrue(VideoStreamWindow(cursorParts: 3).line(seconds: 10).hasSuffix("; cursor parts 3"))
        XCTAssertFalse(VideoStreamWindow().line(seconds: 10).contains("cursor"))
    }

    // MARK: the capture

    func testCaptureLeavesThePointerOutOnlyForCursorClientVideo() throws {
        let main = CGMainDisplayID()
        XCTAssertTrue(streamConfiguration(CaptureParams(display: main), fps: 30).showsCursor)
        XCTAssertFalse(streamConfiguration(CaptureParams(display: main), fps: 30, showsCursor: false).showsCursor)
        XCTAssertTrue(FrameStream(CaptureParams(display: main), fps: 30).showsCursor)
    }

    // MARK: geometry

    func testNormalizeOnAndOffTheDisplay() {
        // main 1728×1117 at the origin; a second display to its right, one to its left (negative x), one above
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let right = CGRect(x: 1728, y: 100, width: 1920, height: 1080)
        let left = CGRect(x: -2560, y: -300, width: 2560, height: 1440)
        let n = DisplayPointerGeometry.normalize(CGPoint(x: 864, y: 558.5), in: main)
        XCTAssertEqual(n.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(n.y, 0.5, accuracy: 1e-9)
        XCTAssertTrue(n.onDisplay)
        let r = DisplayPointerGeometry.normalize(CGPoint(x: 1728 + 480, y: 100 + 270), in: right)
        XCTAssertEqual(r.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0.25, accuracy: 1e-9)
        XCTAssertTrue(r.onDisplay)
        let l = DisplayPointerGeometry.normalize(CGPoint(x: -640, y: 420), in: left)
        XCTAssertEqual(l.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(l.y, 0.5, accuracy: 1e-9)
        XCTAssertTrue(l.onDisplay)
        // on the right display, seen from main: off (clamped to main's edge)
        let off = DisplayPointerGeometry.normalize(CGPoint(x: 2000, y: 300), in: main)
        XCTAssertFalse(off.onDisplay)
        XCTAssertEqual(off.x, 1)
        // the far edge belongs to the next display
        XCTAssertFalse(DisplayPointerGeometry.normalize(CGPoint(x: 1728, y: 10), in: main).onDisplay)
        XCTAssertTrue(DisplayPointerGeometry.normalize(CGPoint(x: 1727.5, y: 10), in: main).onDisplay)
        // the inverse of /input's mapping
        for (x, y) in [(0.3, 0.3), (0.0, 1.0), (0.999, 0.42)] {
            let g = Input.globalPoint(CGMainDisplayID(), x: x, y: y)
            let b = CGDisplayBounds(CGMainDisplayID())
            guard b.width > 1 else { continue }
            let back = DisplayPointerGeometry.normalize(g, in: b)
            XCTAssertEqual(back.x, x, accuracy: 1.5 / b.width)
            XCTAssertEqual(back.y, y, accuracy: 1.5 / b.height)
        }
    }

    func testShapeInDisplayUnitsAndInputPositions() throws {
        let image = SystemCursorImage(key: 7, png: Data([1]), hotX: 5, hotY: 5, width: 28, height: 40)
        let s = try XCTUnwrap(DisplayPointerGeometry.shape(image, id: 3, bounds: CGRect(x: 100, y: 0, width: 1400, height: 1000)))
        XCTAssertEqual(s.id, 3)
        XCTAssertEqual(s.hotX, 5.0 / 1400, accuracy: 1e-12)
        XCTAssertEqual(s.hotY, 5.0 / 1000, accuracy: 1e-12)
        XCTAssertEqual(s.width, 0.02, accuracy: 1e-12)
        XCTAssertEqual(s.height, 0.04, accuracy: 1e-12)

        func event(_ type: String, x: Double? = nil, y: Double? = nil, dx: Double? = nil, dy: Double? = nil) -> InputEvent {
            InputEvent(type: type, display: nil, x: x, y: y, dx: dx, dy: dy, text: nil, key: nil, modifiers: nil)
        }
        for t in ["click", "doubleClick", "rightClick", "move", "scroll"] {
            let p = try XCTUnwrap(DisplayPointerGeometry.position(after: event(t, x: 0.3, y: 0.4)), t)
            XCTAssertEqual(p.x, 0.3); XCTAssertEqual(p.y, 0.4)
        }
        let drag = try XCTUnwrap(DisplayPointerGeometry.position(after: event("drag", x: 0.2, y: 0.2, dx: 0.1, dy: 0.9)))
        XCTAssertEqual(drag.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(drag.y, 1)
        XCTAssertNil(DisplayPointerGeometry.position(after: event("scroll", dx: 0, dy: 10)))
        XCTAssertNil(DisplayPointerGeometry.position(after: event("key")))
        XCTAssertNil(DisplayPointerGeometry.position(after: event("type")))
    }

    // MARK: the tracker

    func testTrackerTakesInputAndOnlyLocationChanges() {
        let probe = FakePointerProbe()
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        probe.locationValue = CGPoint(x: 500, y: 250)
        let t = DisplayPointerTracker(display: 4242, bounds: { bounds }, probe: probe, pollInterval: 3600)
        final class Count: @unchecked Sendable { let lock = NSLock(); var n = 0; func add() { lock.lock(); n += 1; lock.unlock() } }
        let changes = Count()
        t.observe { changes.add() }
        t.start()
        defer { t.stop() }
        var c = t.current().cursor
        XCTAssertEqual(c.x, 0.5); XCTAssertEqual(c.y, 0.5); XCTAssertTrue(c.visible)
        XCTAssertEqual(c.shapeId, 0, "no system cursor: the built-in arrow")
        XCTAssertEqual(t.current().shape?.id, 0)

        // our input: taken at once, by display
        let move = InputEvent(type: "move", display: nil, x: 0.3, y: 0.3, dx: nil, dy: nil, text: nil, key: nil, modifiers: nil)
        DisplayPointerTracker.noteInput(move, display: 4243)  // another display: untouched
        XCTAssertEqual(t.current().cursor.x, 0.5)
        DisplayPointerTracker.noteInput(move, display: 4242)
        c = t.current().cursor
        XCTAssertEqual(c.x, 0.3); XCTAssertEqual(c.y, 0.3)
        XCTAssertGreaterThanOrEqual(changes.n, 1)
        // a location that didn't change (a background session's, not following our input) doesn't pull it back
        t.sample(shape: false)
        XCTAssertEqual(t.current().cursor.x, 0.3)
        // our input read back in whole points: no news (no extra part)
        let before = changes.n
        probe.locationValue = CGPoint(x: 300.4, y: 149.6)
        t.sample(shape: false)
        XCTAssertEqual(t.current().cursor.x, 0.3)
        XCTAssertEqual(changes.n, before)
        // someone moved the mouse: followed
        probe.locationValue = CGPoint(x: 100, y: 400)
        t.sample(shape: false)
        c = t.current().cursor
        XCTAssertEqual(c.x, 0.1, accuracy: 1e-9); XCTAssertEqual(c.y, 0.8, accuracy: 1e-9); XCTAssertTrue(c.visible)
        // onto another display: invisible
        probe.locationValue = CGPoint(x: 1200, y: 100)
        t.sample(shape: false)
        XCTAssertFalse(t.current().cursor.visible)
        // input brings it back
        DisplayPointerTracker.noteInput(move, display: 4242)
        XCTAssertTrue(t.current().cursor.visible)
    }

    /// Someone at the Mac moving the mouse all the time (5 pt a reading: more than the 1.5 pt that is no news): the tracker follows it ~120 times a second (it was 20, which
    /// a phone showed as steps against 60 fps pictures), and still looks at the shape only every 100 ms.
    func testTrackerFollowsAMovingMouseAt120Hz() {
        XCTAssertEqual(DisplayPointerTracker.defaultPollInterval, 1.0 / 120, accuracy: 1e-9)
        XCTAssertEqual(DisplayPointerTracker.defaultPollInterval * Double(DisplayPointerTracker.defaultShapeEvery), 0.1, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(StreamTuning().cursorMinInterval, DisplayPointerTracker.defaultPollInterval)

        final class Moving: SystemPointerProbe, @unchecked Sendable {
            let lock = NSLock()
            var x: CGFloat = 0
            var shapeLooks = 0
            func location() -> CGPoint? { lock.lock(); defer { lock.unlock() }; x += 5; return CGPoint(x: 10 + x.truncatingRemainder(dividingBy: 900), y: 100) }
            func cursorImage() -> SystemCursorImage? { lock.lock(); shapeLooks += 1; lock.unlock(); return nil }
        }
        final class Count: @unchecked Sendable { let lock = NSLock(); var n = 0; func add() { lock.lock(); n += 1; lock.unlock() } }
        let probe = Moving()
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let t = DisplayPointerTracker(display: 4246, bounds: { bounds }, probe: probe)
        let changes = Count()
        t.observe { changes.add() }
        t.start()
        Thread.sleep(forTimeInterval: 1)
        t.stop()
        // ~120 in the second; a loaded machine's timer slips, so only well above the old 20
        XCTAssertGreaterThan(changes.n, 80, "positions followed in 1 s")
        XCTAssertLessThan(probe.shapeLooks, 15, "the shape still only every 100 ms")
    }

    func testTrackerShapesFromTheSystemCursor() throws {
        let probe = FakePointerProbe()
        let bounds = CGRect(x: 0, y: 0, width: 1400, height: 1000)
        probe.locationValue = CGPoint(x: 10, y: 10)
        let arrow = SystemCursorImage(key: 11, png: Data([1]), hotX: 5, hotY: 5, width: 28, height: 40)
        let ibeam = SystemCursorImage(key: 22, png: Data([2]), hotX: 8, hotY: 12, width: 16, height: 24)
        probe.imageValue = arrow
        let t = DisplayPointerTracker(display: 4244, bounds: { bounds }, probe: probe, pollInterval: 3600)
        t.start()
        defer { t.stop() }
        let first = t.current()
        let arrowID = first.cursor.shapeId
        XCTAssertGreaterThan(arrowID, 0, "system shapes have their own ids (0 is the built-in arrow)")
        XCTAssertEqual(try XCTUnwrap(first.shape).width, 0.02, accuracy: 1e-12)
        XCTAssertEqual(t.systemShapes, 1)
        probe.imageValue = ibeam
        t.sample(shape: false)
        XCTAssertEqual(t.current().cursor.shapeId, arrowID, "the shape is only looked at when due")
        t.sample(shape: true)
        let ibeamID = t.current().cursor.shapeId
        XCTAssertNotEqual(ibeamID, arrowID)
        XCTAssertEqual(t.current().shape?.hotX ?? 0, 8.0 / 1400, accuracy: 1e-12)
        probe.imageValue = arrow
        t.sample(shape: true)
        XCTAssertEqual(t.current().cursor.shapeId, arrowID, "the same image keeps its id")
        // ids are process-wide: another stream's tracker gives the same image the same id (a phone caches by id)
        let other = DisplayPointerTracker(display: 4245, bounds: { bounds }, probe: probe, pollInterval: 3600)
        other.sample(shape: true)
        XCTAssertEqual(other.current().cursor.shapeId, arrowID)
        XCTAssertGreaterThan(arrowID, 1_000_000, "clear of small shape ids")
        probe.imageValue = nil
        t.sample(shape: true)
        XCTAssertEqual(t.current().cursor.shapeId, 0, "no system cursor any more: the built-in arrow")
        XCTAssertEqual(t.current().shape?.id, 0)
    }
    func testOnlyAPNGThatReadsBackCounts() throws {
        let arrow = try XCTUnwrap(ClientCursorShape.builtinArrow(width: 1728, height: 1117))
        XCTAssertTrue(SystemPointer.pngReadsBack(arrow.png))
        XCTAssertFalse(SystemPointer.pngReadsBack(Data()))
        XCTAssertFalse(SystemPointer.pngReadsBack(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])))
        XCTAssertFalse(SystemPointer.pngReadsBack(Data(arrow.png.prefix(20))))
    }
}
