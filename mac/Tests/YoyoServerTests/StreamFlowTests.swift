import XCTest
import Foundation
@testable import YoyoServer

// The flow-control / latency-first adaptation controller (StreamFlow.swift), with a fake clock (plain numbers): the ack
// window, probes, dropping the window when acks stall, key-frame rate limiting, the bit rate going down on queueing
// delay (the lowest RTT of the last second − min RTT) and up when clean, resolution steps, the remembered ceiling, the
// network profile. The request parsing, part bytes and ack route are in StreamWireTests.swift.

final class StreamFlowControllerTests: XCTestCase {
    /// A controller at the rates these tests were written at (2500 / 8000; the defaults are `testDefaults`), with a
    /// fixed window of `window` (no frame interval: it doesn't grow with the RTT).
    private func controller(window: Int = 2, _ tweak: (inout StreamTuning) -> Void = { _ in }) -> StreamFlowController {
        var t = StreamTuning()
        t.startKbps = 2500
        t.maxKbps = 8000
        t.videoWindow = window
        t.maxVideoWindow = window
        tweak(&t)
        return StreamFlowController(tuning: t, widths: [1600, 1280, 1024])
    }

    func testNoWindowBeforeTheFirstAckThenWindowOfW() {
        var f = controller()
        // Before any ack: today's behaviour, however many are out.
        for s in 1...5 { f.pictureSent(seq: UInt64(s), at: Double(s) * 0.03) }
        XCTAssertEqual(f.gate(at: 0.2), .open)
        XCTAssertFalse(f.active)
        // The first ack covers 1…3: RTT from part 3's write.
        XCTAssertEqual(f.ack(seq: 3, at: 0.19), [])
        XCTAssertTrue(f.active)
        XCTAssertEqual(f.latestRTT!, 0.10, accuracy: 1e-9)
        XCTAssertEqual(f.inFlight, 2)      // 4 and 5 still out
        XCTAssertEqual(f.gate(at: 0.2), .full(until: 1.19))   // probe 1 s after the last ack
        f.noteWindowLimited()
        // Two samples: too few to judge anything (and a full window is never a reason to climb).
        XCTAssertEqual(f.ack(seq: 4, at: 0.22), [])
        XCTAssertEqual(f.gate(at: 0.22), .open)
        f.pictureSent(seq: 6, at: 0.23)
        XCTAssertEqual(f.gate(at: 0.24), .full(until: 1.23))
        // Cumulative: one ack for 6 covers 5 and 6.
        _ = f.ack(seq: 6, at: 0.30)
        XCTAssertEqual(f.inFlight, 0)
        XCTAssertEqual(f.latestRTT!, 0.07, accuracy: 1e-9)
        // A stale / repeated ack changes nothing.
        XCTAssertEqual(f.ack(seq: 5, at: 0.31), [])
        XCTAssertEqual(f.lastAckSeq, 6)
        XCTAssertEqual(f.windowLimitedCount, 1)
        XCTAssertEqual(f.bitrateKbps, 2500)
    }

    func testCursorPartsBetweenPicturesAreCoveredByTheCumulativeAck() {
        var f = controller(window: 1)
        f.pictureSent(seq: 1, at: 0)
        _ = f.ack(seq: 1, at: 0.05)
        f.pictureSent(seq: 4, at: 0.1)    // 2, 3 were cursor parts (not tracked)
        XCTAssertEqual(f.gate(at: 0.11), .full(until: 1.1))
        _ = f.ack(seq: 3, at: 0.12)       // covers only the cursor parts: still full
        XCTAssertEqual(f.inFlight, 1)
        _ = f.ack(seq: 5, at: 0.16)       // a later cursor part's seq covers the picture too
        XCTAssertEqual(f.inFlight, 0)
        XCTAssertEqual(f.gate(at: 0.16), .open)
    }

    func testProbeAfterOneSecondThenWindowDroppedAfterThree() {
        var f = controller()
        f.pictureSent(seq: 1, at: 0)
        _ = f.ack(seq: 1, at: 0.05)
        f.pictureSent(seq: 2, at: 0.1)
        f.pictureSent(seq: 3, at: 0.15)
        XCTAssertEqual(f.gate(at: 0.5), .full(until: 1.15))
        XCTAssertEqual(f.gate(at: 1.16), .probe)
        f.noteProbe()
        f.pictureSent(seq: 4, at: 1.16)
        XCTAssertEqual(f.gate(at: 1.5), .full(until: 2.16))     // next probe a second after the last
        XCTAssertEqual(f.stallDeadline()!, 3.1, accuracy: 1e-9)  // oldest un-acked (0.1) + 3 s
        XCTAssertFalse(f.checkStall(at: 3.0))
        XCTAssertTrue(f.checkStall(at: 3.1))
        XCTAssertTrue(f.disabled)
        XCTAssertFalse(f.active)
        XCTAssertEqual(f.gate(at: 3.2), .open)                  // runs as without acks
        f.pictureSent(seq: 5, at: 3.3)
        XCTAssertEqual(f.ack(seq: 4, at: 3.4), [])              // a stale ack (stuck for 2 s) is ignored
        XCTAssertTrue(f.disabled)
        XCTAssertEqual(f.gate(at: 3.5), .open)
        XCTAssertEqual(f.probes, 1)
    }

    func testFreshAcksBringTheDroppedWindowBack() {
        var f = controller()
        f.pictureSent(seq: 1, at: 0)
        _ = f.ack(seq: 1, at: 0.05)
        f.pictureSent(seq: 2, at: 0.1)
        XCTAssertTrue(f.checkStall(at: 3.1))
        for i in 0..<10 { f.pictureSent(seq: UInt64(3 + i), at: 3.2 + Double(i) * 0.033) }
        // acks flow again: an ack for a picture sent 80 ms before
        _ = f.ack(seq: 12, at: 3.2 + 9 * 0.033 + 0.08)
        XCTAssertFalse(f.disabled)
        XCTAssertTrue(f.active)
        XCTAssertEqual(f.reenables, 1)
        XCTAssertEqual(f.inFlight, 0)                           // pictures up to 12 acked; 12 was the newest
        f.pictureSent(seq: 13, at: 3.6)
        XCTAssertEqual(f.inFlight, 1)
        XCTAssertEqual(f.latestRTT!, 0.08, accuracy: 1e-9)
    }

    func testAWindowThatKeepsStallingStaysOffAfterAFewReturns() {
        var f = controller()
        var t = 0.0
        var seq: UInt64 = 0
        func sendAndAck() { seq += 1; f.pictureSent(seq: seq, at: t); _ = f.ack(seq: seq, at: t + 0.05); t += 0.1 }
        sendAndAck()
        for _ in 0..<(f.tuning.maxReenables + 1) {
            seq += 1; f.pictureSent(seq: seq, at: t)
            t += 3.5
            XCTAssertTrue(f.checkStall(at: t))
            sendAndAck()
        }
        XCTAssertEqual(f.reenables, f.tuning.maxReenables)
        XCTAssertTrue(f.disabled)
    }

    func testIdleTimeDoesNotCountAsAStall() {
        var f = controller()
        f.pictureSent(seq: 1, at: 0)
        _ = f.ack(seq: 1, at: 0.05)
        // 30 s idle (nothing outstanding), then a picture: the stall clock starts at that picture.
        f.pictureSent(seq: 2, at: 30)
        XCTAssertFalse(f.checkStall(at: 31))
        XCTAssertEqual(f.stallDeadline()!, 33, accuracy: 1e-9)
        _ = f.ack(seq: 2, at: 30.1)
        XCTAssertNil(f.stallDeadline())
    }

    func testKeyFrameRequestsAreRateLimited() {
        var f = controller()
        XCTAssertFalse(f.keyDue(at: 0))
        f.requestKey(at: 1)
        XCTAssertTrue(f.keyDue(at: 1))     // none sent yet: at once
        f.noteKeySent(at: 1)
        XCTAssertFalse(f.keyDue(at: 1.1))
        _ = f.ack(seq: 0, keyframe: true, at: 1.2)   // a request via the ack
        XCTAssertEqual(f.keyDueAt!, 1.5, accuracy: 1e-9)
        XCTAssertFalse(f.keyDue(at: 1.4))
        XCTAssertTrue(f.keyDue(at: 1.5))
        f.noteKeySent(at: 1.5)
        XCTAssertNil(f.keyDueAt)
        XCTAssertEqual(f.keyRequests, 2)
    }

    /// Feed RTT samples every `step` from `from` to `to` (seconds), returning every action.
    private func feed(_ f: inout StreamFlowController, rtt: (Double) -> Double, from: Double, to: Double,
                      step: Double = 0.033) -> [(Double, StreamFlowAction)] {
        var out: [(Double, StreamFlowAction)] = []
        var t = from
        while t < to {
            for a in f.rttSample(rtt(t), at: t) { out.append((t, a)) }
            t += step
        }
        return out
    }

    func testRateDownOnASustainedQueueThenResolutionAtTheFloor() {
        // close to the floor: the resolution steps come within the 10 s min window; no climbs past the start meanwhile
        var f = controller { $0.startKbps = 600; $0.climbHold = 100 }
        XCTAssertEqual(f.bitrateKbps, 600)
        _ = feed(&f, rtt: { _ in 0.040 }, from: 0, to: 2)   // base RTT 40 ms
        XCTAssertEqual(f.queueDelayMin!, 0, accuracy: 1e-6)
        // A spike shorter than the window: its minimum stays at the base, no step.
        let blip = feed(&f, rtt: { _ in 0.300 }, from: 2, to: 2.1)
        XCTAssertTrue(blip.isEmpty, "\(blip)")
        _ = feed(&f, rtt: { _ in 0.040 }, from: 2.1, to: 4)
        // Sustained queueing: once every sample of the last second is high, ×0.85 every ~500 ms while it lasts.
        let down = feed(&f, rtt: { _ in 0.200 }, from: 4, to: 7)
        let rates = down.compactMap { if case let .bitrate(k) = $0.1 { return k } else { return nil } }
        XCTAssertEqual(Array(rates.prefix(3)), [510, 434, 369])
        XCTAssertGreaterThanOrEqual(down.first!.0, 5.5 - 0.05)    // a full second of queued samples, held 500 ms
        let times = down.map(\.0)
        for (a, b) in zip(times, times.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 0.49) }
        // Down to the floor, then the resolution steps: 1600 → 1280 → 1024, then nothing lower.
        let more = feed(&f, rtt: { _ in 0.200 }, from: 7, to: 12)
        XCTAssertEqual(f.bitrateKbps, 300)
        let res = (down + more).compactMap { if case let .resolution(i) = $0.1 { return i } else { return nil } }
        XCTAssertEqual(res, [1, 2])
        XCTAssertEqual(f.width, 1024)
    }

    func testResolutionStepsBackUpOnlyAfterSixCleanSeconds() {
        var f = controller { $0.startKbps = 600 }
        _ = feed(&f, rtt: { _ in 0.040 }, from: 0, to: 1)
        _ = feed(&f, rtt: { _ in 0.300 }, from: 1, to: 8)    // to the floor and 1024
        XCTAssertEqual(f.resolutionIndex, 2)
        // The RTT recovers: the window's minimum is the base again a second later; then six clean seconds per step.
        let clean = feed(&f, rtt: { _ in 0.040 }, from: 8, to: 40)
        let res = clean.compactMap { a -> (Double, Int)? in if case let .resolution(i) = a.1 { return (a.0, i) } else { return nil } }
        XCTAssertEqual(res.map(\.1), [1, 0])
        XCTAssertGreaterThanOrEqual(res[0].0, 8 + 6 - 1e-6)
        XCTAssertGreaterThanOrEqual(res[1].0 - res[0].0, 6 - 1e-6)
    }

    func testMinRTTForgetsOldSamples() {
        var f = controller()
        _ = f.rttSample(0.020, at: 0)
        _ = f.rttSample(0.080, at: 5)
        XCTAssertEqual(f.minRTT!, 0.020, accuracy: 1e-9)
        _ = f.rttSample(0.080, at: 10.5)
        XCTAssertEqual(f.minRTT!, 0.080, accuracy: 1e-9)
    }

    func testFastEncodeWidth() {
        // A 3456×2234 display. Scaling: even sizes, source aspect.
        let mirror = { (w: Int) in scaledSize(sourceWidth: 3456, sourceHeight: 2234, maxWidth: w) }
        // The narrowest width past 1080p's pixel count: 1790×1156 (2 069 240) is not, 1792×1158 (2 075 136) is.
        let fast = VideoEncoder.fastWidth(minWidth: 1600, limit: 2048, size: mirror)
        XCTAssertEqual(fast, 1792)
        let s = mirror(fast!)
        XCTAssertGreaterThan(s.width * s.height, VideoEncoder.fastModePixels)
        let below = mirror(fast! - 2)
        XCTAssertLessThanOrEqual(below.width * below.height, VideoEncoder.fastModePixels)
        // Already past it: unchanged. Beyond the limit, or a source too small to get there: nil.
        XCTAssertEqual(VideoEncoder.fastWidth(minWidth: 2000, limit: 2048, size: mirror), 2000)
        XCTAssertNil(VideoEncoder.fastWidth(minWidth: 1600, limit: 1700, size: mirror))
        XCTAssertNil(VideoEncoder.fastWidth(minWidth: 1600, limit: 2048) { scaledSize(sourceWidth: 1680, sourceHeight: 1050, maxWidth: $0) })
        // The cap: two thirds of the source (3456 → 2304) when the client allows it…
        XCTAssertEqual(Router.videoWidthCap(codec: .h264, clientMaxWidth: 3840, size: mirror, prefersAbove1080p: { _ in true }), 2304)
        XCTAssertEqual(Router.videoWidthCap(codec: .h264, clientMaxWidth: 3840, size: mirror, prefersAbove1080p: { _ in false }), 2304)
        // …a client asking less (an older iOS: 2048) gets that, already past 1080p's area…
        XCTAssertEqual(Router.videoWidthCap(codec: .h264, clientMaxWidth: 2048, size: mirror, prefersAbove1080p: { _ in true }), 2048)
        // …and less still, that.
        XCTAssertEqual(Router.videoWidthCap(codec: .h264, clientMaxWidth: 1600, size: mirror, prefersAbove1080p: { _ in true }), 1600)
        XCTAssertEqual(Router.videoWidthCap(codec: .h264, clientMaxWidth: 1280, size: mirror, prefersAbove1080p: { _ in true }), 1280)
        // At most 2560 (a 5K source); at least 1600, never past the source, and widened past 1080p's area only when
        // the encoder prefers it (a 1920-px display: 1600, or 1824×1140).
        let fiveK = { (w: Int) in scaledSize(sourceWidth: 5120, sourceHeight: 2880, maxWidth: w) }
        XCTAssertEqual(Router.videoWidthCap(codec: .h264, clientMaxWidth: 3840, size: fiveK, prefersAbove1080p: { _ in true }), 2560)
        let hd = { (w: Int) in scaledSize(sourceWidth: 1920, sourceHeight: 1200, maxWidth: w) }
        XCTAssertEqual(Router.videoWidthCap(codec: .h264, clientMaxWidth: 3840, size: hd, prefersAbove1080p: { _ in false }), 1600)
        XCTAssertEqual(Router.videoWidthCap(codec: .h264, clientMaxWidth: 3840, size: hd, prefersAbove1080p: { _ in true }), 1824)
    }

    func testVideoWindowCoversOneRTTAtTheFrameRate() {
        // 60 fps over a 140 ms path: a fixed 4 in flight would cap it at ~28/s; the window covers the RTT instead.
        var f = StreamFlowController(widths: [1600], frameInterval: 1.0 / 60)
        XCTAssertEqual(f.window, 4)                       // no RTT yet: the base
        f.pictureSent(seq: 1, at: 0)
        _ = f.ack(seq: 1, at: 0.14)
        XCTAssertEqual(f.window, 19)                      // ceil(2 × 0.14 × 60) + 2
        for s in 2...9 { f.pictureSent(seq: UInt64(s), at: 0.14 + Double(s) * 0.001) }
        XCTAssertEqual(f.gate(at: 0.16), .open)           // 8 out < 19
        // 50 ms at 30 fps: ceil(2 × 0.05 × 30) + 2
        var mid = StreamFlowController(widths: [1600], frameInterval: 1.0 / 30)
        mid.pictureSent(seq: 1, at: 0)
        _ = mid.ack(seq: 1, at: 0.05)
        XCTAssertEqual(mid.window, 5)
        // A fast path: never below the base.
        var fast = StreamFlowController(widths: [1600], frameInterval: 1.0 / 60)
        fast.pictureSent(seq: 1, at: 0)
        _ = fast.ack(seq: 1, at: 0.01)
        XCTAssertEqual(fast.window, 4)
        // A very slow path: capped.
        var slow = StreamFlowController(widths: [1600], frameInterval: 1.0 / 60)
        slow.pictureSent(seq: 1, at: 0)
        _ = slow.ack(seq: 1, at: 1.0)
        XCTAssertEqual(slow.window, 24)
        // A window fixed by the tuning (videoWindow = maxVideoWindow), or an unknown frame rate: as configured.
        var fixedTuning = StreamTuning()
        fixedTuning.videoWindow = 3
        fixedTuning.maxVideoWindow = 3
        var fixed = StreamFlowController(tuning: fixedTuning, frameInterval: 1.0 / 60)
        fixed.pictureSent(seq: 1, at: 0)
        _ = fixed.ack(seq: 1, at: 0.14)
        XCTAssertEqual(fixed.window, 3)
        var unknown = StreamFlowController()
        unknown.pictureSent(seq: 1, at: 0)
        _ = unknown.ack(seq: 1, at: 0.14)
        XCTAssertEqual(unknown.window, 4)
    }

    func testVideoWindowCoversTheHighRTTNotTheMinimum() {
        // A 5G path: min 80 ms, most round trips 100–170 ms. Twice the min RTT gave 12; the p90 (170 ms) gives 23.
        var f = StreamFlowController(widths: [1600], frameInterval: 1.0 / 60)
        let rtts = [0.08, 0.09, 0.10, 0.10, 0.11, 0.12, 0.13, 0.15, 0.17, 0.44]
        for (i, rtt) in rtts.enumerated() {
            let sent = Double(i) * 0.5
            f.pictureSent(seq: UInt64(i + 1), at: sent)
            _ = f.ack(seq: UInt64(i + 1), at: sent + rtt)
        }
        XCTAssertEqual(f.minRTT, 0.08)
        XCTAssertEqual(f.windowRTT ?? 0, 0.17, accuracy: 1e-9)   // one 440 ms spike in ten is above the p90
        XCTAssertEqual(f.window, 23)                       // ceil(2 × 0.17 × 60) + 2
        // A LAN: still the base.
        var lan = StreamFlowController(widths: [1600], frameInterval: 1.0 / 60)
        for i in 0..<10 {
            lan.pictureSent(seq: UInt64(i + 1), at: Double(i) * 0.1)
            _ = lan.ack(seq: UInt64(i + 1), at: Double(i) * 0.1 + 0.008)
        }
        XCTAssertEqual(lan.window, 4)
    }

    func testTuningFromEnvironment() {
        // YOYO_VIDEO_MAX_KBPS is the one operational switch left: the ceiling (100…100000), the start follows it down.
        let low = StreamTuning.fromEnvironment(["YOYO_VIDEO_MAX_KBPS": "4000"])
        XCTAssertEqual(low.maxKbps, 4000)
        XCTAssertEqual(low.startKbps, 3500)
        let lower = StreamTuning.fromEnvironment(["YOYO_VIDEO_MAX_KBPS": "2000"])
        XCTAssertEqual(lower.startKbps, 2000)
        XCTAssertEqual(StreamTuning.fromEnvironment(["YOYO_VIDEO_MAX_KBPS": "5"]).maxKbps, 100)
        XCTAssertEqual(StreamTuning.fromEnvironment(["YOYO_VIDEO_MAX_KBPS": "x"]).maxKbps, 20000)
        // The removed tuning knobs change nothing.
        let ignored = StreamTuning.fromEnvironment(["YOYO_STREAM_WINDOW": "3", "YOYO_VIDEO_KBPS": "50000",
                                                    "YOYO_QD_WINDOW_MS": "1500", "YOYO_CLIMB_HOLD_MS": "4000",
                                                    "YOYO_CEILING_HOLD_S": "60", "YOYO_CELLULAR_MAX_KBPS": "6000"])
        XCTAssertEqual(ignored.videoWindow, 4)
        XCTAssertEqual(ignored.startKbps, 3500)
        XCTAssertEqual(ignored.qdWindow, 1)
        XCTAssertEqual(ignored.climbHold, 2)
        XCTAssertEqual(ignored.ceilingHold, 30)
        XCTAssertNil(ignored.cellularMaxKbps)
    }
}

/// A `sourceWidth` × `sourceHeight` picture scaled to at most `maxWidth` (even sizes, source aspect; never upscaled),
/// as a stream's `size(width)` would be.
func scaledSize(sourceWidth: Int, sourceHeight: Int, maxWidth: Int) -> (width: Int, height: Int) {
    guard maxWidth > 0, sourceWidth > maxWidth else { return (sourceWidth, sourceHeight) }
    let w = max(2, maxWidth) & ~1
    let h = max(2, Int((Double(w) * Double(sourceHeight) / Double(sourceWidth)).rounded())) & ~1
    return (w, h)
}

/// The adaptation: the queue delay is the lowest RTT of the last second − min RTT, so tunnel jitter (spikes) neither
/// steps the rate down nor keeps it from climbing; a real queue lifts every sample.
final class StreamFlowAdaptationTests: XCTestCase {
    private func controller(_ tweak: (inout StreamTuning) -> Void = { _ in }) -> StreamFlowController {
        var t = StreamTuning()
        t.startKbps = 2500   // the rates these tests were written at (defaults since raised: `testDefaults`)
        t.maxKbps = 8000
        tweak(&t)
        return StreamFlowController(tuning: t, widths: [1600, 1280, 1024])
    }

    /// Deterministic noise in 0…1 (an LCG), so the jittery paths are the same every run.
    private struct Noise {
        var state: UInt64 = 0x2545F4914F6CDD1D
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// RTT samples every `step` (an ack every 30 ms) from `from` to `to`; every action with its time.
    private func feed(_ f: inout StreamFlowController, from: Double, to: Double, step: Double = 0.03,
                      until stop: ((StreamFlowAction) -> Bool)? = nil, untilDown: Bool = false,
                      rtt: (Double) -> Double) -> [(Double, StreamFlowAction)] {
        var out: [(Double, StreamFlowAction)] = []
        let downs = f.decreases
        var t = from
        while t < to {
            for a in f.rttSample(rtt(t), at: t) {
                out.append((t, a))
                if stop?(a) == true { return out }
            }
            if untilDown, f.decreases > downs { return out }
            t += step
        }
        return out
    }

    private func rates(_ actions: [(Double, StreamFlowAction)]) -> [(Double, Int)] {
        actions.compactMap { if case let .bitrate(k) = $0.1 { return ($0.0, k) } else { return nil } }
    }

    func testDefaults() {
        let t = StreamTuning.default
        XCTAssertEqual(t.qdWindow, 1)
        XCTAssertEqual(t.climbHold, 2)
        XCTAssertEqual(t.ceilingHold, 30)
        XCTAssertEqual(t.cellularCeilingHold, 120)
        XCTAssertEqual(t.cellularIncreaseFactor, 1.05)
        XCTAssertEqual(t.cellularClimbEvery, 2)
        XCTAssertEqual(t.climbInterval, 1)   // a step is judged by a full window of samples before the next
        XCTAssertEqual(t.startKbps, 3500)
        XCTAssertEqual(t.minKbps, 300)
        XCTAssertEqual(t.maxKbps, 20000)
        XCTAssertEqual(t.holdBelowUtilization, 0.5)
        XCTAssertEqual(t.videoWindow, 4)
        XCTAssertEqual(t.maxVideoWindow, 24)
        XCTAssertEqual(t.windowRTTPercentile, 0.9)
        XCTAssertEqual(t.refineIdle, 0.3)
        XCTAssertEqual(t.refineEvery, 0.1)
        XCTAssertEqual(t.videoRefines, 20)
        XCTAssertEqual(t.refineSmallInARow, 2)
        XCTAssertEqual(t.refineMinBitrate, 4_000_000)
        XCTAssertEqual(t.keepalive, 5)
        XCTAssertEqual(t.maxFPS, 60)
    }

    func testJitterIsNotCongestionAndTheRateClimbsPastTheStart() {
        // The tunnel path: min RTT 70 ms, every sample 70–130 ms at random, no trend.
        var noise = Noise()
        var f = controller()
        let up = rates(feed(&f, from: 0, to: 40) { _ in 0.070 + 0.060 * noise.next() })
        XCTAssertEqual(f.decreases, 0)
        XCTAssertTrue(up.allSatisfy { $0.1 > 2500 })               // only steps up
        XCTAssertGreaterThanOrEqual(up.first!.0, 2 - 1e-9)          // after `climbHold` clean
        XCTAssertEqual(up.first!.1, 2750)
        for (a, b) in zip(up, up.dropFirst()) { XCTAssertGreaterThanOrEqual(b.0 - a.0, 1 - 1e-9) }
        XCTAssertEqual(f.bitrateKbps, 8000)                         // up to the maximum
        XCTAssertEqual(f.climbs, up.count)
        XCTAssertNil(f.ceilingKbps)
        XCTAssertLessThan(f.queueDelayMin!, 0.010)
        XCTAssertGreaterThan(f.srtt! - f.minRTT!, 0.020)            // the smoothed RTT sits well above the minimum

        // Alternating 70 / 130 ms: the same.
        var alt = controller()
        var odd = false
        _ = feed(&alt, from: 0, to: 40) { _ in odd.toggle(); return odd ? 0.070 : 0.130 }
        XCTAssertEqual(alt.decreases, 0)
        XCTAssertEqual(alt.bitrateKbps, 8000)
    }

    func testARealQueueStepsDownAndTheCeilingHoldsForThirtySeconds() {
        var noise = Noise()
        var f = controller()
        // Clean at 70 ms: past the start rate, 2500 → 2750 → 3025 → 3328 → 3661.
        _ = feed(&f, from: 0, to: 5.5) { _ in 0.070 }
        XCTAssertEqual(f.bitrateKbps, 3661)
        // Then a queue builds: the RTT rises 70 → 130 ms over a second and stays there, until the step down.
        var last = f.bitrateKbps
        let ramp = rates(feed(&f, from: 5.5, to: 12, until: { a in
            guard case let .bitrate(k) = a else { return false }
            defer { last = k }
            return k < last
        }) { t in 0.070 + 0.060 * min(1, t - 5.5) })
        // The window still held clean samples at 6 s: one more step (the minimum is slow to rise, by design)…
        XCTAssertEqual(ramp.map(\.1), [4027, 3423])
        XCTAssertEqual(ramp[0].0, 6.1, accuracy: 0.1)   // a step per second after 2 s, on the 30 ms ack grid
        // …then every sample of the last second is above 120 ms (qd > 50) from 7.33 on, held 500 ms: ×0.85.
        XCTAssertEqual(ramp[1].0, 7.83, accuracy: 0.05)
        let hit = ramp[1].0
        XCTAssertEqual(f.ceilingKbps, 3624)                         // ×0.9 of the rate before
        XCTAssertEqual(f.ceilingKbps(at: hit + 29.9), 3624)
        XCTAssertNil(f.ceilingKbps(at: hit + 30))
        // The queue drains; the path is quiet again (70–90 ms): back up, but not past the ceiling for 30 s…
        let back = rates(feed(&f, from: hit + 0.03, to: hit + 29.9) { _ in 0.070 + 0.020 * noise.next() })
        XCTAssertEqual(f.decreases, 1)                              // one step down, no second while draining
        XCTAssertEqual(back.map(\.1), [3624])
        XCTAssertGreaterThanOrEqual(back[0].0, hit + 2 - 1e-9)      // `climbHold` clean first
        XCTAssertEqual(f.bitrateKbps, 3624)
        // …then past it.
        let later = rates(feed(&f, from: hit + 29.9, to: hit + 40) { _ in 0.070 + 0.020 * noise.next() })
        XCTAssertGreaterThanOrEqual(later.first!.0, hit + 30)
        XCTAssertEqual(later.first!.1, 3986)
        XCTAssertNil(f.ceilingKbps)
    }

    func testAnotherHitRenewsTheCeiling() {
        var f = controller { $0.climbHold = 5 }
        _ = feed(&f, from: 0, to: 1) { _ in 0.070 }
        _ = feed(&f, from: 1, to: 10, untilDown: true) { _ in 0.150 }
        XCTAssertEqual(f.bitrateKbps, 2125)
        XCTAssertEqual(f.ceilingKbps, 2250)
        _ = feed(&f, from: 10, to: 20) { _ in 0.070 }               // min RTT forgets the queue
        XCTAssertEqual(f.bitrateKbps, 2250)                          // recovery stops at the ceiling
        _ = feed(&f, from: 20, to: 30, untilDown: true) { _ in 0.150 }
        XCTAssertEqual(f.bitrateKbps, 1913)
        XCTAssertEqual(f.ceilingKbps, 2025)
    }

    func testRecoveryBelowTheStartRateHappensOnAJitteryPath() {
        // A real queue pushed the rate down; the path is jittery.
        var f = controller { $0.ceilingHold = 0; $0.climbHold = 100 }   // just the recovery: no ceiling, no climb
        _ = feed(&f, from: 0, to: 2) { _ in 0.070 }
        _ = feed(&f, from: 2, to: 6) { _ in 0.200 }
        XCTAssertLessThanOrEqual(f.bitrateKbps, 1806)
        let low = f.bitrateKbps
        var noise = Noise()
        let back = rates(feed(&f, from: 6, to: 10) { _ in 0.070 + 0.060 * noise.next() })
        XCTAssertEqual(back.first?.1, Int((Double(low) * 1.25).rounded()))   // ×1.25 per 500 ms…
        XCTAssertTrue(back.contains { $0.1 == 2500 })                        // …to the start rate
        XCTAssertLessThan(back.first { $0.1 == 2500 }!.0, 8)
    }

    func testNoStepDownRightAfterAKeyFrame() {
        var f = controller()
        _ = feed(&f, from: 0, to: 1) { _ in 0.040 }
        // Queueing from 1 s: without a key frame it would step down at 2.5 s. A key frame went out at 2 s.
        _ = feed(&f, from: 1, to: 2) { _ in 0.200 }
        f.noteKeySent(at: 2)
        XCTAssertTrue(feed(&f, from: 2, to: 3.45) { _ in 0.200 }.isEmpty)
        XCTAssertEqual(f.bitrateKbps, 2500)
        // Still queueing after the grace: congestion.
        XCTAssertEqual(rates(feed(&f, from: 3.45, to: 4.2) { _ in 0.200 }).map(\.1), [2125])
    }

    func testTooFewSamplesInTheWindowDecideNothing() {
        // An ack every 600 ms: at most two samples in any second.
        var f = controller()
        XCTAssertTrue(feed(&f, from: 0, to: 30, step: 0.6) { $0 < 3 ? 0.070 : 0.400 }.isEmpty)
        XCTAssertNil(f.queueDelayMin)
        XCTAssertEqual(f.bitrateKbps, 2500)
        // Down below the start rate, sparse clean samples don't move it either.
        var g = controller { $0.climbHold = 100 }
        _ = feed(&g, from: 0, to: 2) { _ in 0.070 }
        _ = feed(&g, from: 2, to: 4, untilDown: true) { _ in 0.200 }
        XCTAssertEqual(g.bitrateKbps, 2125)
        XCTAssertTrue(feed(&g, from: 5, to: 20, step: 0.6) { _ in 0.070 }.isEmpty)
        XCTAssertEqual(g.bitrateKbps, 2125)
    }

    func testAClimbNeedsTheStreamToUseItsTarget() {
        // Pictures of `bytes` every 33 ms, each acked 70 ms later.
        func run(bytes: Int, limited: Bool = false, _ tweak: (inout StreamTuning) -> Void = { _ in }) -> StreamFlowController {
            var f = controller(tweak)
            var seq: UInt64 = 0
            var t = 0.0
            while t < 10 {
                seq += 1
                f.pictureSent(seq: seq, at: t, bytes: bytes)
                if limited { f.noteWindowLimited() }
                _ = f.ack(seq: seq, at: t + 0.070)
                t += 0.033
            }
            return f
        }
        // 1 KB a picture ≈ 240 kbps of a 2500 target: an idle-ish desktop proves nothing about the path.
        let idle = run(bytes: 1000)
        XCTAssertEqual(idle.bitrateKbps, 2500)
        XCTAssertEqual(idle.sentKbps(at: 10)!, 242, accuracy: 5)
        // 12 KB a picture ≈ 2900 kbps: it climbs while that is 80 % of the target or more — 3328 → 3661, then no further.
        let busy = run(bytes: 12_000)
        XCTAssertGreaterThan(busy.bitrateKbps, 2500)
        XCTAssertEqual(busy.bitrateKbps, 3661)
        // A full window is no evidence on its own (it was: the 5G log below); a utilization of 0 turns the check off.
        let limited = run(bytes: 1000, limited: true)
        XCTAssertEqual(limited.bitrateKbps, 2500)
        XCTAssertEqual(limited.climbs, 0)
        XCTAssertGreaterThan(run(bytes: 1000) { $0.climbUtilization = 0 }.bitrateKbps, 2500)
    }

    func testAFullWindowAloneNeverClimbsPastTheStart() {
        // Clean and window-limited from the first sample: a step past the start rate waits for `climbHold` clean and
        // comes once per `climbInterval`, like any other (the old rule stepped up at once, every 500 ms).
        var f = controller()
        var ups: [(Double, Int)] = []
        var t = 0.0
        while t < 6 {
            f.noteWindowLimited()
            for case let .bitrate(k) in f.rttSample(0.070, at: t) { ups.append((t, k)) }
            t += 0.03
        }
        XCTAssertGreaterThanOrEqual(ups.first!.0, 2 - 1e-9)
        for (a, b) in zip(ups, ups.dropFirst()) { XCTAssertGreaterThanOrEqual(b.0 - a.0, 1 - 1e-9) }
        XCTAssertEqual(ups.count, 4)   // 2, 3, 4, 5 s (it was 12 steps, one per 500 ms)
    }

    func testAStillScreenIsNotCutWhileThePathQueues() {
        // Stream A8C04851 (2026-10-25, 5G over the tunnel): a still screen sending 39 kbit/s, RTT 135 → 300–600 ms
        // for ~25 s. Every 0.5 s of it cut the target ×0.85: 3500 → 300 kbit/s, and the scrolling that followed went
        // out at 300–900 kbit/s. The queue was not the stream's; the target now holds while the content uses little.
        func run(bytes: Int, pps: Double, windowLimited: Bool = false, _ tweak: (inout StreamTuning) -> Void = { _ in })
            -> StreamFlowController {
            var tuning = StreamTuning()
            tweak(&tuning)
            var f = StreamFlowController(tuning: tuning, widths: [2304, 1792, 1280, 1024], frameInterval: 1.0 / 60)
            var seq: UInt64 = 0
            var t = 0.0
            while t < 30 {
                seq += 1
                f.pictureSent(seq: seq, at: t, bytes: bytes)
                let queued = t >= 5 && t < 28
                if queued, windowLimited { f.noteWindowLimited(at: t) }
                _ = f.rttSample(queued ? 0.540 : 0.140, at: t)
                t += 1 / pps
            }
            return f
        }
        // Cursor parts / keepalives: 1 KB at 6 a second ≈ 48 kbit/s of a 3500 target.
        let still = run(bytes: 1000, pps: 6)
        XCTAssertEqual(still.decreases, 0)
        XCTAssertGreaterThan(still.heldSteps, 10)
        XCTAssertEqual(still.bitrateKbps, 3500)
        XCTAssertNil(still.ceilingKbps)
        // The old rule (hold off): cut nearly to the floor.
        let old = run(bytes: 1000, pps: 6) { $0.holdBelowUtilization = 0 }
        XCTAssertGreaterThan(old.decreases, 10)
        XCTAssertLessThan(old.bitrateKbps, 500)
        // Little sent because the window held pictures back: that may be this stream's own queue — steps down.
        let held = run(bytes: 1000, pps: 6, windowLimited: true)
        XCTAssertGreaterThan(held.decreases, 10)
        XCTAssertEqual(held.heldSteps, 0)
        // Content that uses the target (6.5 KB at 60 fps ≈ 3.1 Mbit/s): steps down as before.
        let busy = run(bytes: 6500, pps: 60)
        XCTAssertGreaterThan(busy.decreases, 3)
        XCTAssertLessThan(busy.bitrateKbps, 3500)
    }

    func testThe5GCaseAFullWindowDuringRTTSpikesWithLowUtilizationDoesNotClimb() {
        // Stream E77FB1E3 (2026-10-24, 5G over the tunnel): min RTT ~136 ms, and spikes past ~270 ms that fill the
        // 16-picture window for a while, every few seconds; the content used 0.4–3 Mbps. The old rule took that as
        // room to climb: 3500 → 12000 kbps, and the path queued (qdmin 173 ms) once the content used 10 Mbps.
        func run(bytesPerPicture bytes: Int) -> (StreamFlowController, [(Double, Int)]) {
            var f = StreamFlowController(widths: [2304, 1792, 1280, 1024], frameInterval: 1.0 / 60)
            var noise = Noise()
            var ups: [(Double, Int)] = []
            var seq: UInt64 = 0
            var t = 0.0
            while t < 60 {
                seq += 1
                f.pictureSent(seq: seq, at: t, bytes: bytes)
                let phase = t.truncatingRemainder(dividingBy: 3)
                let spike = phase >= 2.4   // 0.6 s of 280–360 ms in every 3 s
                if spike { f.noteWindowLimited() }
                let rtt = spike ? 0.280 + 0.080 * noise.next() : 0.136 + 0.040 * noise.next()
                for case let .bitrate(k) in f.rttSample(rtt, at: t) { ups.append((t, k)) }
                t += 1.0 / 60
            }
            return (f, ups)
        }
        // 1 KB a picture at 60 fps ≈ 480 kbps of a 3500 target: no climb, however often the window fills.
        let (idle, idleUps) = run(bytesPerPicture: 1000)
        XCTAssertEqual(idle.decreases, 0)                 // the spikes are jitter, not a queue
        XCTAssertGreaterThan(idle.windowLimitedCount, 500)
        XCTAssertTrue(idleUps.isEmpty, "\(idleUps)")
        XCTAssertEqual(idle.bitrateKbps, 3500)
        XCTAssertEqual(idle.climbs, 0)
        // Content that uses the target (≈ 3.1 Mbps) still climbs on the same path, while it sends ≥ 80 % of the target:
        // 3500 → 3850 → 4235, not further (80 % of 4235 is 3388).
        let (busy, busyUps) = run(bytesPerPicture: 6500)
        XCTAssertEqual(busyUps.map(\.1), [3850, 4235])
        XCTAssertGreaterThanOrEqual(busyUps.first!.0, 2 - 1e-9)
        XCTAssertEqual(busy.decreases, 0)
    }

    /// The 5G log: a path that carries ~10 Mbps (above it a queue builds and the RTT climbs), 3 minutes of content that
    /// uses whatever it gets. Wi-Fi rules climb back into the queue every time the 30 s ceiling runs out; on cellular
    /// the ceiling holds 2 min and the climb is slower, so the rate sits under the path's capacity.
    func testOnCellularTheRateStopsHittingThePathsCapacity() {
        func run(cellular: Bool) -> (downs: Int, congestedSeconds: Double, final: Int) {
            var t = StreamTuning()
            t.startKbps = 3500
            t.maxKbps = 20000
            var f = StreamFlowController(tuning: t, widths: [2304])
            if cellular { _ = f.apply(StreamNetProfile(name: "cellular", maxKbps: 20000)) }
            var noise = Noise()
            var queue = 0.0
            var congested = 0.0
            var now = 0.0
            let step = 0.03
            while now < 180 {
                // the queue grows with what is sent past 10 Mbps and drains at the path's rate below it
                queue = max(0, queue + step * (Double(f.bitrateKbps) - 10000) / 10000)
                if queue > 0.050 { congested += step }
                _ = f.rttSample(0.070 + queue + 0.020 * noise.next(), at: now)
                now += step
            }
            return (f.decreases, congested, f.bitrateKbps)
        }
        let wifi = run(cellular: false)
        let cell = run(cellular: true)
        XCTAssertGreaterThanOrEqual(wifi.downs, 5, "\(wifi)")
        XCTAssertLessThanOrEqual(cell.downs, 3, "\(cell)")
        XCTAssertLessThan(cell.congestedSeconds, wifi.congestedSeconds / 2, "\(cell) vs \(wifi)")
        XCTAssertGreaterThan(cell.final, 6000, "still close to what the path carries: \(cell)")
        XCTAssertLessThanOrEqual(cell.final, 10000)
    }

    func testTheNetworkProfileCapsTheRate() {
        let t = StreamTuning()
        XCTAssertNil(t.cellularMaxKbps)   // no data rationing on cellular: the owner's own screen
        XCTAssertEqual(t.constrainedMaxKbps, 2500)
        XCTAssertNil(t.requestMaxKbps)
        func choose(_ net: StreamNetReport?, _ tuning: StreamTuning = StreamTuning()) -> StreamNetProfile {
            StreamNetProfile.choose(client: net, tuning: tuning)
        }
        XCTAssertEqual(choose(nil), StreamNetProfile(name: "wifi", maxKbps: 20000))
        XCTAssertEqual(choose(StreamNetReport(route: "lan", iface: "wifi")), StreamNetProfile(name: "wifi", maxKbps: 20000))
        XCTAssertEqual(choose(StreamNetReport(iface: "wired")), StreamNetProfile(name: "wifi", maxKbps: 20000))
        XCTAssertEqual(choose(StreamNetReport(iface: "cellular", radio: "5g", expensive: true)), StreamNetProfile(name: "cellular", maxKbps: 20000))
        XCTAssertEqual(choose(StreamNetReport(iface: "cellular", constrained: true)), StreamNetProfile(name: "constrained", maxKbps: 2500))
        XCTAssertEqual(choose(StreamNetReport(iface: "wifi", constrained: true)), StreamNetProfile(name: "constrained", maxKbps: 2500))
        XCTAssertEqual(choose(StreamNetReport(iface: "cellular", constrained: false)), StreamNetProfile(name: "cellular", maxKbps: 20000))
        // A cellular ceiling, when set, still binds there only.
        var capped = StreamTuning()
        capped.cellularMaxKbps = 8000
        XCTAssertEqual(choose(StreamNetReport(iface: "cellular"), capped), StreamNetProfile(name: "cellular", maxKbps: 8000))
        XCTAssertEqual(choose(StreamNetReport(iface: "wifi"), capped), StreamNetProfile(name: "wifi", maxKbps: 20000))
        // The server's own max is lower: it caps the profile.
        var low = StreamTuning()
        low.maxKbps = 6000
        XCTAssertEqual(choose(StreamNetReport(iface: "cellular"), low), StreamNetProfile(name: "cellular", maxKbps: 6000))
        // The stream's maxKbps (the test panel) replaces the profile on any network: `test`.
        let test = StreamTuning().limited(toKbps: 3000)
        XCTAssertEqual(test.maxKbps, 3000)
        XCTAssertEqual(test.startKbps, 3000)
        XCTAssertEqual(test.requestMaxKbps, 3000)
        XCTAssertEqual(choose(nil, test), StreamNetProfile(name: "test", maxKbps: 3000))
        XCTAssertEqual(choose(StreamNetReport(iface: "cellular"), test), StreamNetProfile(name: "test", maxKbps: 3000))
        XCTAssertEqual(choose(StreamNetReport(constrained: true), test), StreamNetProfile(name: "test", maxKbps: 3000))
        let high = StreamTuning().limited(toKbps: 50_000)
        XCTAssertEqual(high.maxKbps, 20000)
        XCTAssertEqual(high.startKbps, 3500)
        XCTAssertEqual(choose(StreamNetReport(iface: "cellular"), high), StreamNetProfile(name: "test", maxKbps: 20000))
        XCTAssertEqual(choose(nil, high), StreamNetProfile(name: "test", maxKbps: 20000))   // asked above the max: the max
        XCTAssertEqual(StreamTuning().limited(toKbps: 100).minKbps, 100)
        XCTAssertEqual(StreamTuning().limited(toKbps: nil).maxKbps, 20000)

        // The controller: a lower ceiling steps the rate down at once; a higher one only lets later climbs go further.
        var f = controller { $0.startKbps = 2500; $0.maxKbps = 12000 }
        _ = feed(&f, from: 0, to: 16) { _ in 0.070 }
        XCTAssertGreaterThan(f.bitrateKbps, 8000)
        XCTAssertEqual(f.apply(StreamNetProfile(name: "cellular", maxKbps: 8000)), [.bitrate(8000)])
        XCTAssertEqual(f.bitrateKbps, 8000)
        XCTAssertEqual(f.maxKbpsNow, 8000)
        XCTAssertTrue(rates(feed(&f, from: 16, to: 30) { _ in 0.070 }).isEmpty)   // clean, but at the ceiling
        XCTAssertEqual(f.apply(StreamNetProfile(name: "wifi", maxKbps: 12000)), [])
        XCTAssertEqual(f.bitrateKbps, 8000)
        XCTAssertEqual(rates(feed(&f, from: 30, to: 31.5) { _ in 0.070 }).map(\.1), [8800, 9680])
        // Below the start rate (constrained 2500 < start 3500) the recovery stops at the profile's ceiling.
        var g = controller { $0.startKbps = 3500 }
        XCTAssertEqual(g.apply(StreamNetProfile(name: "constrained", maxKbps: 2500)), [.bitrate(2500)])
        XCTAssertTrue(feed(&g, from: 0, to: 20) { _ in 0.070 }.isEmpty)
        XCTAssertEqual(g.bitrateKbps, 2500)
    }

    func testTheStreamFollowsTheClientsNetworkLive() {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
        let clock = Clock()
        var tuning = StreamTuning()
        tuning.startKbps = 10_000   // above the cellular ceiling from the start
        tuning.cellularMaxKbps = 8000   // none by default; set here to watch a ceiling follow the network
        let flow = StreamFlow(id: "stream-0001", controller: StreamFlowController(tuning: tuning),
                              clock: { clock.now }, wake: {})
        XCTAssertEqual(flow.profile, StreamNetProfile(name: "wifi", maxKbps: 20000))
        XCTAssertTrue(flow.takeActions().isEmpty)
        // A report without net changes nothing.
        flow.received(StreamPlayoutReport(mode: "smooth"))
        XCTAssertTrue(flow.takeActions().isEmpty)
        // The phone is on cellular: down to 8000 at once.
        flow.received(StreamPlayoutReport(mode: "smooth", net: StreamNetReport(route: "tunnel", iface: "cellular", radio: "5g")))
        XCTAssertEqual(flow.profile, StreamNetProfile(name: "cellular", maxKbps: 8000))
        XCTAssertEqual(flow.takeActions(), [.bitrate(8000)])
        flow.received(StreamPlayoutReport(mode: "smooth", net: StreamNetReport(iface: "cellular")))
        XCTAssertTrue(flow.takeActions().isEmpty)   // the same profile: nothing again
        // Low Data Mode: 2500.
        clock.now += 2
        flow.received(StreamPlayoutReport(mode: "latency", net: StreamNetReport(iface: "cellular", constrained: true)))
        XCTAssertEqual(flow.takeActions(), [.bitrate(2500)])
        XCTAssertEqual(flow.with { $0.bitrateKbps }, 2500)
        // No report for over 10 s: the client's net is stale, an ack brings the default back (no step: it only lets
        // later climbs go further).
        clock.now += 10.5
        flow.ack(seq: 0, keyframe: false)
        XCTAssertEqual(flow.profile, StreamNetProfile(name: "wifi", maxKbps: 20000))
        XCTAssertTrue(flow.takeActions().isEmpty)
        XCTAssertEqual(flow.with { $0.bitrateKbps }, 2500)
        // A stream that asked for maxKbps: `test`, whatever the network says, while it binds.
        let test = StreamFlow(id: "stream-0002", controller: StreamFlowController(tuning: StreamTuning().limited(toKbps: 6000)),
                              clock: { clock.now }, wake: {})
        XCTAssertEqual(test.profile, StreamNetProfile(name: "test", maxKbps: 6000))
        test.received(StreamPlayoutReport(mode: "smooth", net: StreamNetReport(iface: "cellular")))
        XCTAssertEqual(test.profile, StreamNetProfile(name: "test", maxKbps: 6000))
        XCTAssertTrue(test.takeActions().isEmpty)
        // The summary carries it (stats line and JSON) when it isn't the default.
        var s = StreamFlowSummary(id: "stream-0001", codec: "hevc", cursorClient: false)
        s.bitrateKbps = 6000
        s.width = 2304
        test.with { s.adapt(from: $0) }
        XCTAssertTrue(s.line.contains(" downs 0 profile test 6000"), s.line)
        XCTAssertEqual(s.json["profile"] as? [String: AnyHashable], ["name": "test", "maxKbps": 6000])
        flow.with { s.adapt(from: $0) }
        XCTAssertFalse(s.line.contains("profile"), s.line)
    }

    func testSummaryCarriesTheAdaptation() {
        var f = controller()
        _ = feed(&f, from: 0, to: 2.5) { _ in 0.070 }
        _ = feed(&f, from: 2.5, to: 10, untilDown: true) { _ in 0.150 }
        var s = StreamFlowSummary(id: "abcdefgh", codec: "h264", cursorClient: false)
        s.bitrateKbps = f.bitrateKbps
        s.width = 1792
        s.keyFrames = 1
        s.bytesPerSecond = 300_000
        s.partsPerSecond = 60
        s.encodeMs = 5
        XCTAssertFalse(s.line.contains("qdmin"))   // no controller: none of it
        s.adapt(from: f)
        XCTAssertEqual(f.bitrateKbps, 2571)   // 2500 → 2750 (2 s) → 3025 (3 s, the window still clean) → ×0.85
        XCTAssertEqual(s.line, "h264 1792px 2571kbps 292KB/s 60.0p/s enc 5.0ms rtt \(Int(s.srttMs!.rounded()))/70ms"
                       + " qdmin 80ms cap 2723 climbs 2 downs 1 keys 1")
        let j = s.json
        XCTAssertNil(j["signal"])
        XCTAssertNil(j["queueDelayMs"])
        XCTAssertEqual(j["queueDelayMinMs"] as? Double, 80)
        XCTAssertEqual(j["ceilingKbps"] as? Int, 2723)
        XCTAssertEqual(j["climbs"] as? Int, 2)
        XCTAssertEqual(j["decreases"] as? Int, 1)
        XCTAssertEqual(j["acks"] as? Bool, true)
        XCTAssertEqual(j["windowActive"] as? Bool, false)   // samples fed straight in: no ack has started the window
    }
}
