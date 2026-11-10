import XCTest
import CoreVideo
import Darwin
import Foundation
@testable import YoyoServer

// The one video loop (VideoStreamLoop.swift) over a fake picture source, as a real display's ScreenCaptureKit stream
// drives it: key frame first, the idle refine, the ack window (no encode while full; the newest picture after an ack),
// a key frame on request, the periodic stats, the source's resolution steps, the end after repeated encode failures.

/// A `VideoPictureSource` whose pictures the test pushes (fixed size, like ScreenCaptureKit).
final class FakeVideoSource: VideoPictureSource, @unchecked Sendable {
    private let cond = NSCondition()
    private var frame: VideoSourceFrame?
    private var seq: UInt64 = 0
    private var changes: UInt64 = 0
    private var stopped = false
    /// `cursor=client`: the pointer feed (set before the loop starts).
    var cursorFeed: DisplayCursorFeed?
    /// The capture window the loop's stats line reads (nil: none).
    var window: CaptureActivityWindow?

    func push(_ buffer: CVPixelBuffer) {
        cond.lock()
        seq += 1
        changes &+= 1
        frame = VideoSourceFrame(buffer: buffer, id: VideoPictureID(frame: seq), publishedAt: Date().timeIntervalSince1970 * 1000)
        cond.broadcast()
        cond.unlock()
    }
    /// The capture stops: the loop's wait returns false.
    func stop() { cond.lock(); stopped = true; cond.broadcast(); cond.unlock() }

    var changeToken: UInt64 { cond.lock(); defer { cond.unlock() }; return changes }
    func waitForFrame(after token: UInt64, until deadline: Date) -> Bool {
        cond.lock(); defer { cond.unlock() }
        while changes == token, !stopped, Date() < deadline { _ = cond.wait(until: deadline) }
        return !stopped
    }
    func wake() { cond.lock(); changes &+= 1; cond.broadcast(); cond.unlock() }
    func newestID() -> VideoPictureID? { cond.lock(); defer { cond.unlock() }; return frame?.id }
    func latest(make: (Int, Int) -> CVPixelBuffer?) -> VideoSourceFrame? { cond.lock(); defer { cond.unlock() }; return frame }
    func captureWindow() -> CaptureActivityWindow? { window }
}

extension StreamFlow {
    /// Ack `seq` as a client would, but only once the loop has recorded that part (it does so right after the write,
    /// so a test that reads a part and acks at once can otherwise beat it and ack nothing).
    func ackOnceSent(seq: UInt64, keyframe: Bool = false) {
        let until = Date().addingTimeInterval(2)
        while with({ $0.lastSentSeq }) < seq, Date() < until { usleep(200) }
        ack(seq: seq, keyframe: keyframe)
    }
}

func fakeDesktopPicture(_ scroll: Int, width: Int = 640, height: Int = 400) -> CVPixelBuffer {
    var b: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
    paintDesktop(b!, scroll: scroll)
    return b!
}

final class VideoStreamLoopTests: XCTestCase {
    /// Run the loop for `source` on a socketpair: the reader and a done signal.
    private func start(_ source: VideoPictureSource, _ o: VideoStreamOptions) -> (StreamPartReader, Int32, DispatchSemaphore) {
        var http = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &http), 0)
        let done = DispatchSemaphore(value: 0)
        let serverFD = http[0]
        Thread.detachNewThread {
            Router.videoStreamLoop(source, Connection(fd: serverFD), o)
            done.signal()
        }
        return (StreamPartReader(fd: http[1]), http[1], done)
    }

    private func registered(_ id: String) throws -> StreamFlow {
        var flow: StreamFlow?
        let until = Date().addingTimeInterval(2)
        while flow == nil, Date() < until { flow = StreamFlowRegistry.lookup(id); usleep(1000) }
        return try XCTUnwrap(flow)
    }

    func testKeyRefineWindowAndKeyRequest() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        let source = FakeVideoSource()
        var o = VideoStreamOptions(codec: .h264)
        o.streamID = "display-test-1"
        o.tuning.videoWindow = 2
        o.tuning.maxVideoWindow = 2  // not grown by the test's RTT
        o.interval = 0.02
        o.tuning.keepalive = 60
        o.tuning.videoRefines = 1
        o.tuning.refineIdle = 0.3
        let (reader, fd, done) = start(source, o)
        let flow = try registered("display-test-1")

        let dec = AnnexBDecoder(codec: .h264)
        source.push(fakeDesktopPicture(0))
        let key = try XCTUnwrap(reader.part())
        XCTAssertEqual(key.kind, "key")
        XCTAssertEqual(key.headers["content-type"], "video/h264")
        XCTAssertEqual(key.headers["x-stream-codec"], "h264")
        XCTAssertEqual(key.headers["x-frame-width"], "640")
        XCTAssertNotNil(dec.decode(key.body))
        // The refine of the still picture, ~300 ms later.
        let r = try XCTUnwrap(reader.part())
        XCTAssertEqual(r.kind, "refine")
        XCTAssertNotNil(dec.decode(r.body))
        flow.ackOnceSent(seq: r.seq, keyframe: false)
        // Two changes fill the window (W = 2); a third waits for an ack.
        source.push(fakeDesktopPicture(10))
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "delta")
        StrictTiming.sleep(0.03)
        source.push(fakeDesktopPicture(20))
        let d2 = try XCTUnwrap(reader.part())
        XCTAssertEqual(d2.kind, "delta")
        StrictTiming.sleep(0.03)
        source.push(fakeDesktopPicture(30))
        reader.setTimeout(0.3)
        XCTAssertNil(reader.part(), "nothing while the window is full")
        reader.setTimeout(2)
        flow.ackOnceSent(seq: d2.seq, keyframe: false)
        let d3 = try XCTUnwrap(reader.part())
        XCTAssertEqual(d3.kind, "delta")
        XCTAssertNotNil(dec.decode(d3.body))
        // A key request: the same picture as a key frame.
        flow.ackOnceSent(seq: d3.seq, keyframe: true)
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "key")
        XCTAssertEqual(dec.errors, 0)
        close(fd)
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertNil(StreamFlowRegistry.lookup("display-test-1"), "unregistered when the stream ends")
    }

    /// A still picture: refines every `refineEvery` after `refineIdle`, until two in a row are small (a settled picture
    /// at 3.5 Mbit/s costs a few hundred bytes), not all `videoRefines`; then nothing until the keepalive.
    func testRefinesUntilSettled() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        let source = FakeVideoSource()
        var o = VideoStreamOptions(codec: .h264)
        o.interval = 1.0 / 30
        o.tuning.keepalive = 60
        let (reader, fd, done) = start(source, o)
        source.push(fakeDesktopPicture(0))
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "key")
        StrictTiming.sleep(0.05)
        source.push(fakeDesktopPicture(40))
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "delta")
        let still = Date()
        var refines: [(TimeInterval, Int)] = []
        reader.setTimeout(1.0)
        while let p = reader.part() {
            XCTAssertEqual(p.kind, "refine")
            refines.append((Date().timeIntervalSince(still), p.body.count))
        }
        XCTAssertGreaterThanOrEqual(refines.count, 2, "\(refines)")
        XCTAssertLessThan(refines.count, o.tuning.videoRefines, "stops once settled: \(refines)")
        XCTAssertGreaterThan(refines[0].0, 0.25, "the first after refineIdle")
        for i in 1..<refines.count {
            let gap = refines[i].0 - refines[i - 1].0
            XCTAssertTrue(gap > 0.07 && gap < 0.3, "then every refineEvery: \(refines)")
        }
        let budget = RefineSchedule.liveBudget(bitsPerSecond: o.tuning.startKbps * 1000, fps: 30)
        XCTAssertTrue(refines.suffix(2).allSatisfy { Double($0.1) <= budget }, "the last two were small: \(refines)")
        close(fd)
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    }

    /// The periodic stats (`statsInterval`): the capture's callbacks, the pictures sent, encode times, the flow.
    func testPeriodicStats() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _stats: [[String: Any]] = []
            func add(_ s: [String: Any]) { lock.lock(); _stats.append(s); lock.unlock() }
            var stats: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _stats }
        }
        let source = FakeVideoSource()
        source.window = CaptureActivityWindow(seconds: 0.3, complete: 9, idle: 6, other: 0, gated: 0, completeGapsMs: [33, 34])
        let box = Box()
        var o = VideoStreamOptions(codec: .h264)
        o.interval = 0.02
        o.statsInterval = 0.3
        o.onStats = { box.add($0) }
        let (reader, fd, done) = start(source, o)
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 400, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
        for i in 0..<5 {
            paintDesktop(b!, scroll: i * 10)
            source.push(b!)
            XCTAssertNotNil(reader.part())
            StrictTiming.sleep(0.03)
        }
        let until = Date().addingTimeInterval(2)
        while box.stats.isEmpty, Date() < until { usleep(10_000) }
        close(fd)
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        let s = try XCTUnwrap(box.stats.first)
        let sent = try XCTUnwrap(s["sent"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(sent["live"] as? Int ?? 0, 1)
        XCTAssertGreaterThanOrEqual(sent["keys"] as? Int ?? 0, 1)
        XCTAssertGreaterThan(sent["encodeMaxMs"] as? Double ?? 0, 0)
        let capture = try XCTUnwrap(s["capture"] as? [String: Any])
        XCTAssertEqual(capture["completePerSecond"] as? Double, 30)
        XCTAssertEqual(capture["idlePerSecond"] as? Double, 20)
        let flow = try XCTUnwrap(s["flow"] as? [String: Any])
        XCTAssertEqual(flow["codec"] as? String, "h264")
        XCTAssertEqual(flow["width"] as? Int, 640)
        XCTAssertNil(flow["signal"], "the ewma controller is gone")
        XCTAssertNil(flow["queueDelayMs"])
        XCTAssertNotNil(flow["queueDelayMinMs"])
    }

    /// A source with resolution steps: a congestion step at the bit-rate floor resizes it, and the
    /// next picture is a key frame at the new size.
    func testResolutionStepsResizeTheSource() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        final class Steps: VideoPictureSource, @unchecked Sendable {
            let inner = FakeVideoSource()
            private let lock = NSLock()
            private var _width = 640
            var resized: [Int] { lock.lock(); defer { lock.unlock() }; return _resized }
            private var _resized: [Int] = []
            var changeToken: UInt64 { inner.changeToken }
            func waitForFrame(after token: UInt64, until deadline: Date) -> Bool { inner.waitForFrame(after: token, until: deadline) }
            func wake() { inner.wake() }
            func newestID() -> VideoPictureID? { inner.newestID().map { VideoPictureID(frame: $0.frame, width: width ?? 0) } }
            func latest(make: (Int, Int) -> CVPixelBuffer?) -> VideoSourceFrame? {
                guard inner.newestID() != nil else { return nil }
                let w = width ?? 0
                let picture = fakeDesktopPicture(0, width: w, height: w * 5 / 8)
                return VideoSourceFrame(buffer: picture, id: VideoPictureID(frame: inner.newestID()!.frame, width: w), publishedAt: nil)
            }
            var width: Int? { lock.lock(); defer { lock.unlock() }; return _width }
            var widths: [Int] { [640, 320] }
            func resize(width: Int) { lock.lock(); _width = width; _resized.append(width); lock.unlock() }
        }
        let source = Steps()
        var o = VideoStreamOptions(codec: .h264)
        o.streamID = "display-test-steps"
        o.interval = 0.02
        o.tuning.keepalive = 60
        o.tuning.videoRefines = 0
        // At the bit-rate floor, and a hair trigger: one late ack is congestion, and congestion steps the resolution.
        o.tuning.startKbps = 300
        o.tuning.qdWindow = 0.01
        o.tuning.qdMinSamples = 1
        o.tuning.congestedHold = 0
        o.tuning.keyGrace = 0
        o.tuning.holdBelowUtilization = 0   // two tiny pictures would read as a still screen, which holds its rate
        let (reader, fd, done) = start(source, o)
        let flow = try registered("display-test-steps")
        source.inner.push(fakeDesktopPicture(0))
        let first = try XCTUnwrap(reader.part())
        XCTAssertEqual(first.kind, "key")
        XCTAssertEqual(first.headers["x-frame-width"], "640")
        flow.ackOnceSent(seq: first.seq, keyframe: false)              // at once: the min RTT
        StrictTiming.sleep(0.05)
        source.inner.push(fakeDesktopPicture(10))
        let delta = try XCTUnwrap(reader.part())
        XCTAssertEqual(delta.kind, "delta")
        StrictTiming.sleep(0.2)
        flow.ackOnceSent(seq: delta.seq, keyframe: false)              // 200 ms later: a queue → the next resolution step
        let resized = try XCTUnwrap(reader.part())
        XCTAssertEqual(resized.kind, "key", "a new size starts with a key frame")
        XCTAssertEqual(resized.headers["x-frame-width"], "320")
        XCTAssertEqual(source.resized, [320])
        XCTAssertNotNil(AnnexBDecoder(codec: .h264).decode(resized.body))
        close(fd)
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
    }

    func testTheStreamEndsWhenTheSourceStops() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        let source = FakeVideoSource()
        var o = VideoStreamOptions(codec: .h264)
        o.interval = 0.02
        let (reader, fd, done) = start(source, o)
        defer { close(fd) }
        source.push(fakeDesktopPicture(0))
        XCTAssertEqual(try XCTUnwrap(reader.part()).kind, "key")
        source.stop()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    }
}
