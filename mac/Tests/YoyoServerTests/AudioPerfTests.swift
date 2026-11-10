import CoreAudio
import XCTest
@testable import YoyoServer

/// The sound round-2 pieces on the Mac: the deaf-process watchdog's decisions (AudioWatchdog.swift) and its shared
/// tap-check cache and stamp file; X-Audio-Video-Offset's parts (AudioVideoOffset.swift); the IO buffer setting.
final class AudioDeafPolicyTests: XCTestCase {
    private typealias P = AudioDeafPolicy

    func testAsksOnlyAfterFourSecondsOfZerosWhileOthersPlay() {
        var p = P()
        // nothing plays: never asks, however long the zeros
        XCTAssertFalse(p.observe(now: 100, zeroSince: 0, othersPlaying: false))
        XCTAssertFalse(p.observe(now: 200, zeroSince: 0, othersPlaying: false))
        // something starts playing at 200: the zeros count from then on
        XCTAssertFalse(p.observe(now: 202, zeroSince: 0, othersPlaying: true))
        XCTAssertFalse(p.observe(now: 204, zeroSince: 0, othersPlaying: true), "only 2 s of playing seen")
        XCTAssertTrue(p.observe(now: 206, zeroSince: 0, othersPlaying: true))
        // the capture heard something at 205: 4 s of zeros from then
        XCTAssertFalse(p.observe(now: 208, zeroSince: 205, othersPlaying: true))
        XCTAssertTrue(p.observe(now: 209, zeroSince: 205, othersPlaying: true))
        // playing stopped: the run starts again when it resumes
        XCTAssertFalse(p.observe(now: 210, zeroSince: 0, othersPlaying: false))
        XCTAssertNil(p.othersSince)
        XCTAssertFalse(p.observe(now: 212, zeroSince: 0, othersPlaying: true))
        XCTAssertTrue(p.observe(now: 216, zeroSince: 0, othersPlaying: true))
    }

    func testHearsAndFailedDoNothingFailedLoggedOnce() {
        var p = P()
        XCTAssertEqual(p.judge(serial: 1, result: .hears, now: 10, nowWall: 1e9, lastExitWall: nil, hasHook: true), .none)
        XCTAssertEqual(p.judge(serial: 2, result: .failed, now: 40, nowWall: 1e9, lastExitWall: nil, hasHook: true), .logFailed)
        XCTAssertEqual(p.judge(serial: 3, result: .failed, now: 70, nowWall: 1e9, lastExitWall: nil, hasHook: true), .none, "logged once")
        XCTAssertEqual(p.judge(serial: 4, result: .hears, now: 100, nowWall: 1e9, lastExitWall: nil, hasHook: true), .none)
        XCTAssertEqual(p.judge(serial: 5, result: .failed, now: 130, nowWall: 1e9, lastExitWall: nil, hasHook: true), .logFailed,
                       "again after a different answer")
        XCTAssertEqual([p.checks, p.deaf, p.exits], [5, 0, 0])
        XCTAssertEqual(p.lastResult, .failed)
        XCTAssertEqual(p.lastAt, 130)
    }

    func testTheSameAnswerIsJudgedOnce() {
        var p = P()
        XCTAssertEqual(p.judge(serial: 7, result: .deaf, now: 10, nowWall: 1e9, lastExitWall: 1e9 - 30, hasHook: true), .suppressed(log: true))
        // the cached answer, seen again on the next ticks: nothing new
        XCTAssertEqual(p.judge(serial: 7, result: .deaf, now: 12, nowWall: 1e9 + 2, lastExitWall: 1e9 - 30, hasHook: true), .none)
        XCTAssertEqual([p.checks, p.deaf, p.suppressed], [1, 1, 1])
    }

    func testDeafExitsAtMostOncePerFifteenMinutesAcrossProcesses() {
        var p = P()
        let wall = 1_800_000_000.0
        // no stamp: exit
        XCTAssertEqual(p.judge(serial: 1, result: .deaf, now: 10, nowWall: wall, lastExitWall: nil, hasHook: true), .exit)
        // a fresh process, a helper exited 60 s ago: keep running, log once
        var q = P()
        XCTAssertEqual(q.judge(serial: 1, result: .deaf, now: 10, nowWall: wall, lastExitWall: wall - 60, hasHook: true), .suppressed(log: true))
        XCTAssertEqual(q.judge(serial: 2, result: .deaf, now: 40, nowWall: wall + 30, lastExitWall: wall - 60, hasHook: true), .suppressed(log: false))
        XCTAssertEqual(q.judge(serial: 3, result: .deaf, now: 850, nowWall: wall + 839, lastExitWall: wall - 60, hasHook: true), .suppressed(log: false),
                       "still inside 15 min")
        // 15 min after that exit: exit
        XCTAssertEqual(q.judge(serial: 4, result: .deaf, now: 851, nowWall: wall + 840, lastExitWall: wall - 60, hasHook: true), .exit)
        XCTAssertEqual([q.deaf, q.suppressed, q.exits], [4, 3, 1])
        // a stamp in the future (the clock went back) doesn't hold it back
        var r = P()
        XCTAssertEqual(r.judge(serial: 1, result: .deaf, now: 10, nowWall: wall, lastExitWall: wall + 3600, hasHook: true), .exit)
        // hearing again re-arms the suppressed log line
        var s = P()
        XCTAssertEqual(s.judge(serial: 1, result: .deaf, now: 10, nowWall: wall, lastExitWall: wall - 1, hasHook: true), .suppressed(log: true))
        XCTAssertEqual(s.judge(serial: 2, result: .hears, now: 40, nowWall: wall + 30, lastExitWall: wall - 1, hasHook: true), .none)
        XCTAssertEqual(s.judge(serial: 3, result: .deaf, now: 70, nowWall: wall + 60, lastExitWall: wall - 1, hasHook: true), .suppressed(log: true))
    }

    func testNoHookTearsDownAtMostEveryTenMinutes() {
        var p = P()
        XCTAssertEqual(p.judge(serial: 1, result: .deaf, now: 100, nowWall: 1e9, lastExitWall: nil, hasHook: false), .tearDown)
        XCTAssertEqual(p.judge(serial: 2, result: .deaf, now: 130, nowWall: 1e9, lastExitWall: nil, hasHook: false), .none)
        XCTAssertEqual(p.judge(serial: 3, result: .deaf, now: 699, nowWall: 1e9, lastExitWall: nil, hasHook: false), .none)
        XCTAssertEqual(p.judge(serial: 4, result: .deaf, now: 700, nowWall: 1e9, lastExitWall: nil, hasHook: false), .tearDown)
        XCTAssertEqual([p.deaf, p.teardowns, p.exits], [4, 2, 0])
    }

    func testStampFileRoundTrip() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("yoyo-audio-deaf-test-\(getpid())")
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(AudioDeafStamp.read(path))
        AudioDeafStamp.write(1_800_000_123.25, to: path)
        XCTAssertEqual(try XCTUnwrap(AudioDeafStamp.read(path)), 1_800_000_123.25, accuracy: 0.001)
        try "garbage".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(AudioDeafStamp.read(path))
        XCTAssertTrue(AudioDeafStamp.path.hasSuffix("yoyo-audio-deaf-\(getuid())"))
    }

    func testTapCheckCacheHoldsHearsLongerAndRunsOneAtATime() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1000) }
        let clock = Clock(), cache = AudioTapCheckCache()
        var runs = 0
        func get(_ r: AudioTapCheck.Result) -> (AudioTapCheckCache.Entry, Bool) {
            let x = cache.current(now: { clock.now }, run: { runs += 1; return (r, "afplay") })
            return (x.entry, x.ran)
        }
        var (e, ran) = get(.hears)
        XCTAssertEqual([e.serial, runs], [1, 1]); XCTAssertTrue(ran)
        clock.now += 119
        (e, ran) = get(.deaf)
        XCTAssertEqual(e.result, .hears, "holds 120 s"); XCTAssertFalse(ran)
        clock.now += 1
        (e, ran) = get(.deaf)
        XCTAssertEqual([e.serial, runs], [2, 2]); XCTAssertEqual(e.result, .deaf)
        clock.now += 29
        (e, _) = get(.hears)
        XCTAssertEqual(e.serial, 2, "a deaf answer holds 30 s")
        clock.now += 1
        (e, _) = get(.hears)
        XCTAssertEqual([e.serial, cache.checks], [3, 3])
        cache.reset()
        XCTAssertNil(cache.cached(at: clock.now))
        XCTAssertEqual(cache.latest, nil)
        (e, _) = get(.failed)
        XCTAssertEqual(e.serial, 4, "the serial keeps counting after a reset")
    }
}

final class AudioVideoOffsetTests: XCTestCase {
    func testOutputLatencyParts() {
        // this Mac's built-in speakers (2026-10-25): no IO buffer term
        let l = AudioOutputLatency(device: "MacBook Pro Speakers", sampleRate: 48_000, latencyFrames: 70, safetyFrames: 74,
                                   streamFrames: 690)
        XCTAssertEqual(l.totalFrames, 834)
        XCTAssertEqual(l.ms, 17.375, accuracy: 0.001)
        XCTAssertEqual(l.line, #""MacBook Pro Speakers" 17.4 ms (latency 70 + safety 74 + stream 690 frames at 48000 Hz)"#)
        XCTAssertEqual(AudioOutputLatency(device: "x", sampleRate: 0, latencyFrames: 1, safetyFrames: 0, streamFrames: 0).ms,
                       AudioOutputLatency.fallbackMs)
    }

    func testOffsetIsTheSumRounded() {
        XCTAssertEqual(AudioVideoOffset(tapToSpeakerMs: 18.4, captureLatencyMs: 30).totalMs, 48)
        XCTAssertEqual(AudioVideoOffset(tapToSpeakerMs: 18.4, captureLatencyMs: -40).totalMs, -22)
        let j = AudioVideoOffset(tapToSpeakerMs: 18.42, captureLatencyMs: 31.06).json
        XCTAssertEqual(j["tapToSpeakerMs"] as? Double, 18.4)
        XCTAssertEqual(j["captureLatencyMs"] as? Double, 31.1)
        XCTAssertEqual(j["totalMs"] as? Int, 49)
    }

    func testRunningMedian() {
        var m = RunningMedian(capacity: 3)
        XCTAssertNil(m.median)
        m.add(10)
        XCTAssertEqual(m.median, 10)
        m.add(30)
        XCTAssertEqual(m.median, 20, "even: the middle two's mean")
        m.add(20)
        XCTAssertEqual(m.median, 20)
        m.add(100)  // replaces 10: 100, 30, 20
        XCTAssertEqual(m.median, 30)
        XCTAssertEqual(m.count, 3)
    }

    func testCaptureLatencyFollowsTheNewestStream() {
        let v = VideoCaptureLatency()
        XCTAssertNil(v.current.ms)
        XCTAssertEqual(v.ms, VideoCaptureLatency.fallbackMs)
        let a = NSObject(), b = NSObject()
        v.note(ObjectIdentifier(a), ms: 25)
        XCTAssertNil(v.current.ms, "not begun: ignored")
        v.begin(ObjectIdentifier(a))
        for ms in [28.0, 30, 32, 5000, -1, .nan] { v.note(ObjectIdentifier(a), ms: ms) }
        XCTAssertEqual(v.current.ms, 30)
        XCTAssertEqual(v.current.samples, 3, "out-of-range samples dropped")
        v.begin(ObjectIdentifier(b))
        v.note(ObjectIdentifier(a), ms: 90)
        XCTAssertEqual(v.current.ms, 30, "the older stream no longer counts; the median stays until the new one samples")
        v.note(ObjectIdentifier(b), ms: 40)
        XCTAssertEqual(v.current.ms, 40)
        XCTAssertEqual(v.current.samples, 1)
    }

    func testHeader() {
        XCTAssertFalse(AudioWire.responseHeaders(cookie: nil).contains { $0.0 == "X-Audio-Video-Offset" })
        let h = AudioWire.responseHeaders(cookie: nil, videoOffsetMs: 48)
        XCTAssertEqual(h.first { $0.0 == "X-Audio-Video-Offset" }?.1, "48")
        XCTAssertEqual(AudioWire.responseHeaders(cookie: nil, videoOffsetMs: -7).first { $0.0 == "X-Audio-Video-Offset" }?.1, "-7")
    }

    func testDefaultOutputDeviceReads() throws {
        guard let l = AudioOutputLatency.readDefault() else { throw XCTSkip("no default output device here") }
        XCTAssertGreaterThan(l.sampleRate, 0)
        XCTAssertGreaterThan(l.ms, 0)
        XCTAssertLessThan(l.ms, 500)
    }
}
