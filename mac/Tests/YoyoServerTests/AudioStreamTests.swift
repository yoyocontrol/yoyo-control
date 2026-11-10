import CoreAudio
import XCTest
@testable import YoyoServer

/// `GET /audio`'s pure parts (AudioStream.swift, AudioCapture.swift): the framing, a client's bounded queue, the
/// timestamps, the IO ring; and the Opus encoder (needs AudioComponent: skipped where the lookup fails, e.g. a sandbox).
final class AudioStreamTests: XCTestCase {
    private func packet(_ i: Int64, _ bytes: [UInt8] = [1, 2, 3]) -> AudioPacket {
        AudioPacket(index: i, timeMs: 1_000 + i * 20, data: Data(bytes), silent: false)
    }

    func testPartFramingMatchesTheVideoStream() {
        let part = AudioWire.part(Data([0xAA, 0xBB, 0xCC]), seq: 7, timeMs: 1_792_725_383_971)
        let expected = "--frame\r\nContent-Type: audio/opus\r\nContent-Length: 3\r\nX-Audio-Seq: 7\r\nX-Audio-Time: 1792725383971\r\n\r\n"
        XCTAssertEqual(part.prefix(expected.utf8.count), Data(expected.utf8))
        XCTAssertEqual(part.suffix(5), Data([0xAA, 0xBB, 0xCC, 13, 10]))
        XCTAssertEqual(part.count, expected.utf8.count + 5)
    }

    func testResponseHeaders() {
        let plain = AudioWire.responseHeaders(cookie: nil)
        XCTAssertEqual(plain.map(\.0), ["Content-Type", "Cache-Control", "X-Audio-Codec", "X-Audio-Rate", "X-Audio-Channels", "X-Audio-Frames"])
        XCTAssertEqual(plain.map(\.1), ["application/vnd.yoyo-control.audio; boundary=frame", "no-cache", "opus", "48000", "2", "960"])
        XCTAssertFalse(AudioWire.responseHeaders(cookie: Data()).contains { $0.0 == "X-Audio-Cookie" })
        let withCookie = AudioWire.responseHeaders(cookie: Data([0, 0, 8, 0]))
        XCTAssertEqual(withCookie.last?.0, "X-Audio-Cookie")
        XCTAssertEqual(withCookie.last?.1, "AAAIAA==")
    }

    func testAudioOff() {
        XCTAssertTrue(AudioWire.enabled(environment: [:]))
        XCTAssertTrue(AudioWire.enabled(environment: ["YOYO_AUDIO": "on"]))
        for off in ["off", "OFF", " 0", "false", "no"] { XCTAssertFalse(AudioWire.enabled(environment: ["YOYO_AUDIO": off]), off) }
    }

    func testQueueDropsTheOldestAndSeqShowsTheGap() {
        let q = AudioClientQueue(capacity: 3)
        for i in 0..<5 { q.push(packet(Int64(i))) }
        XCTAssertEqual(q.count, 3)
        XCTAssertEqual(q.droppedCount, 2)
        let items = q.popAll(until: Date())
        XCTAssertEqual(items.map(\.seq), [3, 4, 5], "seq counts every packet pushed, dropped ones too")
        XCTAssertEqual(items.map(\.packet.index), [2, 3, 4])
        XCTAssertEqual(q.count, 0)
        q.push(packet(5))
        XCTAssertEqual(q.popAll(until: Date()).map(\.seq), [6], "never reset within a response")
    }

    func testQueueStaysBoundedOverALongRun() {
        let q = AudioClientQueue(capacity: 25)
        for i in 0..<1_000 { q.push(packet(Int64(i))) }
        let items = q.popAll(until: Date())
        XCTAssertEqual(items.count, 25)
        XCTAssertEqual(items.first?.seq, 976)
        XCTAssertEqual(items.last?.seq, 1_000)
        XCTAssertEqual(q.droppedCount, 975)
    }

    func testQueueWaitsThenWakesOnPushOrClose() {
        let q = AudioClientQueue()
        let start = Date()
        XCTAssertEqual(q.popAll(until: start.addingTimeInterval(0.05)).count, 0)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.04)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { q.push(self.packet(0)) }
        XCTAssertEqual(q.popAll(until: Date().addingTimeInterval(2)).map(\.seq), [1])

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { q.close() }
        let t = Date()
        XCTAssertEqual(q.popAll(until: Date().addingTimeInterval(2)).count, 0)
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
        XCTAssertTrue(q.isClosed)
        q.push(packet(1))
        XCTAssertEqual(q.count, 0, "closed: nothing more is queued")
    }

    func testTimelineStampsPacketsBySampleCountMinusPriming() {
        var t = AudioTimeline(sampleRate: 48_000)
        XCTAssertNil(t.packetTimeMs(index: 0, framesPerPacket: 960, primingFrames: 312, outputRate: 48_000))
        XCTAssertTrue(t.note(sample: 0, wallMs: 10_000))
        // packet 0 decodes from sample -312 (6.5 ms early), then 20 ms apart
        XCTAssertEqual(t.packetTimeMs(index: 0, framesPerPacket: 960, primingFrames: 312, outputRate: 48_000), 9_994)
        XCTAssertEqual(t.packetTimeMs(index: 1, framesPerPacket: 960, primingFrames: 312, outputRate: 48_000), 10_014)
        XCTAssertEqual(t.packetTimeMs(index: 50, framesPerPacket: 960, primingFrames: 0, outputRate: 48_000), 11_000)
    }

    func testTimelineIgnoresJitterAndReanchorsOnDrift() {
        var t = AudioTimeline(sampleRate: 48_000)
        t.note(sample: 0, wallMs: 10_000)
        // IO host times jitter by a few ms: the count wins, packets stay evenly spaced
        XCTAssertFalse(t.note(sample: 48_000, wallMs: 11_004))
        XCTAssertFalse(t.note(sample: 96_000, wallMs: 11_985))
        XCTAssertEqual(t.originMs, 10_000)
        XCTAssertEqual(t.reanchors, 0)
        // an IO gap (samples missing: the wall clock ran 100 ms ahead of the count) moves the timeline
        XCTAssertTrue(t.note(sample: 144_000, wallMs: 13_100))
        XCTAssertEqual(t.originMs, 10_100)
        XCTAssertEqual(t.reanchors, 1)
        XCTAssertEqual(t.wallMs(ofSample: 144_000), 13_100)
    }

    func testTimelineAtAnotherInputRate() {
        var t = AudioTimeline(sampleRate: 44_100)
        t.note(sample: 44_100, wallMs: 5_000)  // sample 0 was a second earlier
        XCTAssertEqual(t.originMs, 4_000)
        // output packets are counted at 48 kHz whatever the tap's rate
        XCTAssertEqual(t.packetTimeMs(index: 100, framesPerPacket: 960, primingFrames: 0, outputRate: 48_000), 6_000)
    }

    func testHostClockToWallClock() {
        let now = mach_absolute_time()
        let tenMsTicks = UInt64(10_000_000 / HostClock.nanos(1))
        XCTAssertEqual(HostClock.wallMs(hostTime: now - tenMsTicks, nowHost: now, nowWallMs: 1_000), 990, accuracy: 0.01)
        XCTAssertEqual(HostClock.wallMs(hostTime: now, nowHost: now, nowWallMs: 1_000), 1_000, accuracy: 0.001)
    }

    func testDBFS() {
        XCTAssertEqual(audioDBFS(0), -160)
        XCTAssertEqual(audioDBFS(1), 0, accuracy: 1e-9)
        XCTAssertEqual(audioDBFS(0.1), -20, accuracy: 1e-6)
    }

    // MARK: - The IO ring

    /// Calls `body` with an AudioBufferList of `buffers` (each Float32, `channels` interleaved channels).
    private func withBufferList(_ buffers: [[Float]], channels: Int, _ body: (UnsafeMutableAudioBufferListPointer) -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        defer { free(list.unsafeMutablePointer) }
        var storage = buffers
        storage.withUnsafeMutableBufferPointer { all in
            for i in 0..<all.count {
                all[i].withUnsafeMutableBufferPointer { b in
                    list[i] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(b.count * 4), mData: b.baseAddress)
                }
            }
            body(list)
        }
    }

    func testRingDeinterleavesAndHandsOutWholeChunks() {
        let ring = AudioRing(capacityFrames: 100)
        // 6 interleaved stereo frames: L = 1…6, R = -1…-6
        withBufferList([[1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6]], channels: 2) { ring.write($0, hostTime: 42) }
        var l = [Float](repeating: 0, count: 4), r = [Float](repeating: 0, count: 4)
        XCTAssertTrue(ring.read(left: &l, right: &r, frames: 4))
        XCTAssertEqual(l, [1, 2, 3, 4])
        XCTAssertEqual(r, [-1, -2, -3, -4])
        XCTAssertFalse(ring.read(left: &l, right: &r, frames: 4), "only 2 left")
        XCTAssertEqual(ring.takeAnchor()?.frame, 0)
        XCTAssertEqual(ring.takeAnchor()?.frame, nil, "once per write")
        XCTAssertEqual(ring.layout.channels, 2)
    }

    func testRingTakesPlanarAndMonoBuffers() {
        let ring = AudioRing(capacityFrames: 100)
        withBufferList([[1, 2], [10, 20]], channels: 1) { ring.write($0, hostTime: 1) }
        withBufferList([[7, 8]], channels: 1) { ring.write($0, hostTime: 2) }
        var l = [Float](repeating: 0, count: 4), r = [Float](repeating: 0, count: 4)
        XCTAssertTrue(ring.read(left: &l, right: &r, frames: 4))
        XCTAssertEqual(l, [1, 2, 7, 8])
        XCTAssertEqual(r, [10, 20, 7, 8], "mono goes to both sides")
        let anchor = ring.takeAnchor()
        XCTAssertEqual(anchor?.frame, 2)
        XCTAssertEqual(anchor?.hostTime, 2)
    }

    func testRingOverflowLosesTheOldestAndShiftsTheAnchor() {
        let ring = AudioRing(capacityFrames: 4)
        withBufferList([[1, 2, 3]], channels: 1) { ring.write($0, hostTime: 1) }
        withBufferList([[4, 5, 6]], channels: 1) { ring.write($0, hostTime: 2) }  // 6 written, room for 4: 1 and 2 lost
        XCTAssertEqual(ring.overflowFrames, 2)
        XCTAssertEqual(ring.takeAnchor()?.frame, 1, "frame 4 is the reader's 2nd (it gets 3 first)")
        var l = [Float](repeating: 0, count: 4), r = [Float](repeating: 0, count: 4)
        XCTAssertTrue(ring.read(left: &l, right: &r, frames: 4))
        XCTAssertEqual(l, [3, 4, 5, 6])
        withBufferList([[7]], channels: 1) { ring.write($0, hostTime: 3) }
        XCTAssertEqual(ring.takeAnchor()?.frame, 4, "frame 7 is the reader's 5th (index 4)")
    }

    func testRingFillsSilenceWhileTheIOIsIdleTrailingTheClock() {
        let ring = AudioRing(capacityFrames: 48_000, sampleRate: 48_000)
        let tpf = ring.ticksPerFrame
        func ticks(_ seconds: Double) -> UInt64 { UInt64((seconds * 48_000 * tpf).rounded()) }
        let t0 = ticks(100)  // some host time
        var l = [Float](repeating: 1, count: 960), r = l

        // no IO yet: 20 ms of silence ending 25 ms before now, then on from there
        XCTAssertEqual(ring.fillSilence(nowHost: t0), 960)
        XCTAssertEqual(ring.takeAnchor()?.hostTime, t0 - ticks(0.045))
        XCTAssertTrue(ring.read(left: &l, right: &r, frames: 960))
        XCTAssertEqual(l, [Float](repeating: 0, count: 960))
        XCTAssertEqual(ring.fillSilence(nowHost: t0 + ticks(0.02)), 960)
        XCTAssertEqual(ring.takeAnchor()?.frame, 960)
        XCTAssertEqual(ring.fillSilence(nowHost: t0 + ticks(0.02)), 0, "nothing new to fill")

        // IO arrives (a 10 ms buffer stamped 10 ms ago): no silence while it runs
        withBufferList([[Float](repeating: 0.5, count: 480)], channels: 1) { ring.write($0, hostTime: t0 + ticks(0.03)) }
        XCTAssertEqual(ring.fillSilence(nowHost: t0 + ticks(0.04)), 0)
        XCTAssertEqual(ring.fillSilence(nowHost: t0 + ticks(0.12)), 0, "IO 90 ms ago: not idle yet")
        // idle for > 100 ms: from where the IO's data ended (t0 + 40 ms) to now − 25 ms
        XCTAssertEqual(ring.fillSilence(nowHost: t0 + ticks(0.2)), 6_480)
        XCTAssertEqual(ring.takeAnchor()?.hostTime, t0 + ticks(0.04))
        XCTAssertEqual(ring.silenceFrames, 960 * 2 + 6_480)

        // a gap of more than half the ring (a stall): only the last 20 ms, a fresh anchor
        XCTAssertEqual(ring.fillSilence(nowHost: t0 + ticks(5)), 960)
        XCTAssertEqual(ring.takeAnchor()?.hostTime, t0 + ticks(5 - 0.045))
    }

    // MARK: - The encoder

    func testOpusEncoderGivesOnePacketPerChunkTinyForSilence() throws {
        guard let encoder = OpusPacketEncoder(inputRate: 48_000) else {
            throw XCTSkip("no Opus encoder here (AudioComponent lookups fail inside a sandbox)")
        }
        XCTAssertEqual(encoder.primingFrames, 312)
        XCTAssertNotNil(encoder.cookie)
        let silence = [Float](repeating: 0, count: 960)
        var tone = [Float](repeating: 0, count: 960)
        var sizes: [Int] = []
        for chunk in 0..<10 {
            if chunk >= 5 { for i in 0..<960 { tone[i] = 0.5 * sin(Float(chunk * 960 + i) * 2 * .pi * 440 / 48_000) } }
            let packets = encoder.encode(left: chunk < 5 ? silence : tone, right: chunk < 5 ? silence : tone)
            XCTAssertEqual(packets.count, 1, "chunk \(chunk)")
            sizes += packets.map(\.count)
        }
        XCTAssertTrue(sizes.prefix(5).allSatisfy { $0 < 10 }, "silence: \(sizes)")
        XCTAssertTrue(sizes.suffix(4).allSatisfy { $0 > 100 && $0 < 600 }, "a tone at 96 kbit/s ≈ 240 bytes / 20 ms: \(sizes)")
    }
}
