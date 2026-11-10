import Foundation
import Synchronization
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The Screen page's sound, round 2 (data/tools/vnc/audio-perf-spec.md B1–B7): the jitter buffer's output lead, p99 over
/// 10 s, route floors and the adaptive bump, a new stream into the same buffer, the A/V sync depth; the A/V sync's
/// decisions and the playout's sync floor; the lock-free ring and the published numbers; the report and
/// `X-Audio-Video-Offset`.
@Suite("Screen audio performance")
struct ScreenAudioPerfTests {
    private static let rate = 48_000.0
    private static let mac0 = 1_761_170_000.0
    private static let host0 = 5_000.0
    private static let packet = 0.020

    private static func samples(_ value: Float = 0.5) -> [Float] { [Float](repeating: value, count: 960 * 2) }

    /// Pushes packets `range` (20 ms apart on the Mac, arriving `network` + `jitter(i)` later, in order) and pulls 256
    /// frames at a time up to `until` (host seconds after host0), starting at `from`. Returns the left channel.
    @discardableResult
    private static func run(_ b: inout ScreenAudioBuffer, packets range: Range<Int>, seqBase: Int = 0, macBase: Double = mac0,
                            hostBase: Double = host0, network: Double = 0.030, jitter: (Int) -> Double = { _ in 0 },
                            from: Double, until: Double, value: Float = 0.5) -> [Float] {
        var last = -Double.infinity
        let arrivals = range.map { i -> (Int, Double, Double) in
            last = max(last, hostBase + Double(i - range.lowerBound) * packet + network + jitter(i))
            return (i, macBase + Double(i - range.lowerBound) * packet, last)
        }
        var next = 0
        var out: [Float] = []
        var t = host0 + from
        while t < host0 + until {
            while next < arrivals.count, arrivals[next].2 <= t {
                let a = arrivals[next]
                b.push(seq: a.0 - range.lowerBound + seqBase, macTime: a.1, arrival: a.2, samples: samples(value))
                next += 1
            }
            let pulled = b.pull(frames: 256, at: t)
            for f in 0..<256 { out.append(pulled[f * 2]) }
            t += 256 / rate
        }
        return out
    }

    // MARK: Depth

    @Test func theLeadIsAddedToTheDepthAndTheStartDepth() {
        var b = ScreenAudioBuffer(config: .route(lan: true))
        #expect(b.depth == 0.080)
        b.setLead(0.012)
        #expect(abs(b.depth - 0.092) < 1e-12 && b.need == 0.080 && b.lead == 0.012)
        b.push(seq: 0, macTime: Self.mac0, arrival: Self.host0, samples: Self.samples())
        // the slot: arrival + the start depth + the lead
        #expect(b.slot(macTime: Self.mac0).map { abs($0 - (Self.host0 + 0.092)) < 1e-9 } == true)
        // calm: the floor + the lead
        var calm = ScreenAudioBuffer(config: .route(lan: false))
        calm.setLead(0.012)
        Self.run(&calm, packets: 0..<100, from: 0, until: 2)
        #expect(abs(calm.depth - 0.132) < 1e-9 && calm.need == 0.120)
        #expect(calm.underruns == 0 && calm.stats.lead == 0.012)
    }

    @Test func routeFloorsAndTheBufferConfig() {
        let lan = ScreenAudioBuffer.Config.route(lan: true)
        let tunnel = ScreenAudioBuffer.Config.route(lan: false)
        #expect(lan.minDepth == 0.080 && lan.startDepth == 0.080)
        #expect(tunnel.minDepth == 0.120 && tunnel.startDepth == 0.120)
        #expect(lan.percentile == 0.99 && lan.window == 10 && lan.margin == 0.020 && lan.excess == 0.020)
        #expect(lan.maxDepth == 0.400 && lan.bumpStep == 0.040 && lan.bumpMax == 0.240)
        var low = tunnel
        low.set(floor: 0.040)
        #expect(low.minDepth == 0.040 && low.startDepth == 0.060)
        var fixed = lan
        fixed.fix(depth: 0.200)
        #expect(fixed.minDepth == 0.200 && fixed.maxDepth == 0.200 && fixed.startDepth == 0.200 && fixed.bumpStep == 0)
        // the tuning the page passes
        let format = ScreenAudioFormat(rate: 24_000, channels: 1, framesPerPacket: 480)
        let c = ScreenAudioTuning(lan: true).config(for: format)
        #expect(c.minDepth == lan.minDepth && c.rate == 24_000 && c.channels == 1 && c.packetFrames == 480)
        #expect(ScreenAudioTuning(lan: false).config(for: ScreenAudioFormat()).minDepth == tunnel.minDepth)
    }

    @Test func theJitterIsTheP99OfTheLastTenSeconds() {
        var config = ScreenAudioBuffer.Config.route(lan: true)
        config.set(floor: 0)
        config.bumpStep = 0
        var b = ScreenAudioBuffer(config: config)
        // 200 ms late for 10 packets early on (2 %), then calm: it holds the p99 for 10 s, then leaves the window
        for i in 0..<1_000 {
            let t = Double(i) * Self.packet
            b.push(seq: i, macTime: Self.mac0 + t, arrival: Self.host0 + t + 0.030 + ((20..<30).contains(i) ? 0.2 : 0), samples: [])
            if i == 400 { #expect(abs((b.jitter ?? 0) - 0.2) < 1e-5, "8 s in: \(String(describing: b.jitter))") }
        }
        #expect((b.jitter ?? 1) < 1e-6, "20 s in")
        #expect(abs(b.depth - 0.020) < 1e-5)
        // two late packets in 200 are over the p99, three are not
        var p = ScreenAudioBuffer(config: config)
        for i in 0..<200 {
            let t = Double(i) * Self.packet
            let spike = i == 50 || (i == 150) ? 0.1 : 0
            p.push(seq: i, macTime: Self.mac0 + t, arrival: Self.host0 + t + 0.030 + spike, samples: [])
        }
        #expect((p.jitter ?? 1) < 1e-6)
        p.push(seq: 200, macTime: Self.mac0 + 4, arrival: Self.host0 + 4 + 0.130, samples: [])
        #expect(abs((p.jitter ?? 0) - 0.1) < 1e-6)
    }

    @Test func theSelectionIsTheSortedRank() {
        var state: UInt64 = 7
        for n in [1, 2, 3, 10, 99, 100, 101, 500, 2_000] {
            var values = (0..<n).map { _ -> Double in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double((state >> 40) % 50) / 7  // repeats included
            }
            for p in [0, 0.5, 0.95, 0.99, 1] {
                let sorted = ScreenPlayout<Void>.percentile(values, p)
                var copy = values
                #expect(ScreenAudioBuffer.percentile(&copy, p) == sorted, "n \(n) p \(p)")
            }
            values.removeAll()
            #expect(ScreenAudioBuffer.percentile(&values, 0.99) == 0)
        }
    }

    // MARK: Adaptive floor

    @Test func anUnderrunBumpsTheFloorAndItDecays() {
        var b = ScreenAudioBuffer(config: .route(lan: true))
        Self.run(&b, packets: 0..<50, from: 0, until: 1.5)
        // ran dry after the last packet: one interruption
        #expect(b.underruns == 1 && b.interruptions == 1)
        #expect(abs(b.bump - 0.040) < 1e-12 && abs(b.need - 0.120) < 1e-12)
        // the next stretch plays at the new depth; each further underrun adds 40 ms, up to 240
        for k in 1...8 {
            let from = 1.5 + Double(k - 1) * 2
            Self.run(&b, packets: 0..<50, seqBase: k * 100, macBase: Self.mac0 + from, hostBase: Self.host0 + from,
                     from: from, until: from + 2)
        }
        #expect(b.interruptions == 9)
        #expect(abs(b.bump - 0.240) < 1e-12, "\(b.bump)")
        #expect(abs(b.need - 0.320) < 1e-12)
        // 15 s without one: −10 ms (decayed as time passes in, here with a packet)
        #expect(b.config.bumpDecayEvery == 15 && b.config.bumpDecay == 0.010)
        let t = 17.5 + 15.5
        b.push(seq: 2_000, macTime: Self.mac0 + t, arrival: Self.host0 + t + 0.030, samples: [])
        #expect(abs(b.bump - 0.230) < 1e-9, "\(b.bump)")
        // another 3 minutes: −120 more
        b.push(seq: 2_001, macTime: Self.mac0 + t + 180, arrival: Self.host0 + t + 180.030, samples: [])
        #expect(abs(b.bump - 0.110) < 1e-9, "\(b.bump)")
    }

    @Test func lateDropsAfterAnUnderrunAreOneInterruptionAndNoneBeforeAnySound() {
        var config = ScreenAudioBuffer.Config.route(lan: true)
        config.minSamples = 1_000  // the start depth throughout
        var b = ScreenAudioBuffer(config: config)
        // a first packet far too late for its slot: dropped, but nothing had played: no bump
        b.push(seq: 0, macTime: Self.mac0, arrival: Self.host0, samples: Self.samples())
        _ = b.pull(frames: 256, at: Self.host0 + 0.5)
        #expect(b.late == 1 && b.interruptions == 0 && b.bump == 0)
        // playing, then a 400 ms stall (in order: the ones behind it come with it): the underrun counts, the late drops
        // after it don't count again
        var s = ScreenAudioBuffer(config: config)
        Self.run(&s, packets: 0..<60, jitter: { $0 == 20 ? 0.400 : 0 }, from: 0, until: 1.3)
        #expect(s.underruns == 1 && s.late >= 3, "\(s.stats)")
        #expect(s.interruptions == 1 && abs(s.bump - 0.040) < 1e-12)
        // bumpStep 0: counted, no bump
        var off = config
        off.bumpStep = 0
        var o = ScreenAudioBuffer(config: off)
        Self.run(&o, packets: 0..<20, from: 0, until: 1)
        #expect(o.interruptions == 1 && o.bump == 0)
    }

    // MARK: New stream

    @Test func aNewStreamPlaysOnWithoutAnUnderrunAndFadesIn() {
        var b = ScreenAudioBuffer(config: .route(lan: true))
        // stream A: 40 packets; then the page switches routes: stream B counts from 1 again, on another clock offset
        var out = Self.run(&b, packets: 0..<40, from: 0, until: 0.5, value: 0.5)
        #expect(b.playing)
        let buffered = b.stats.buffered
        #expect(buffered > 0.05)
        b.newStream(config: .route(lan: false))
        #expect(b.playing && b.base == nil && b.streams == 1 && b.config.minDepth == 0.120)
        // A's tail plays out (its last packets came already), fading at its end: no underrun, no interruption
        out += Self.run(&b, packets: 1..<120, seqBase: 0, macBase: Self.mac0 + 50, hostBase: Self.host0 + 0.6,
                        network: 0.045, from: Double(out.count) / Self.rate, until: 3, value: 0.25)
        #expect(b.underruns == 0 && b.interruptions == 0 && b.late == 0, "\(b.stats)")
        #expect(b.playing && b.soundStartedAt != nil)
        // B's first sound at its slot: arrival (0.6 + 0.045) + the tunnel's start depth
        let bStart = Int((0.6 + 0.045 + 0.120) * Self.rate)
        let soundStart = b.soundStartedAt.map { Int((($0 - Self.host0) * Self.rate).rounded()) } ?? 0
        #expect(abs(soundStart - bStart) <= 1, "\(soundStart) vs \(bStart)")
        // no cliff anywhere: the gain moves by at most one fade step a frame
        let step: Float = 0.5 / 240 + 1e-6
        var cliffs = 0
        for i in 1..<out.count where abs(out[i] - out[i - 1]) > step { cliffs += 1 }
        #expect(cliffs == 0)
        #expect(out[bStart + 400] == 0.25)
        // what played of A ended in a fade before B
        let aEnd = out[..<bStart].lastIndex(where: { $0 == 0.5 }) ?? 0
        #expect(aEnd > Int(0.5 * Self.rate) && out[(aEnd + 241)..<bStart].allSatisfy { $0 == 0 })
    }

    @Test func aNewStreamWhileWaitingDropsTheOldPacketsAndKeepsTheBumpOnTheSameRoute() {
        var b = ScreenAudioBuffer(config: .route(lan: true))
        Self.run(&b, packets: 0..<20, from: 0, until: 1)
        #expect(b.bump > 0 && !b.playing)
        let bump = b.bump
        b.push(seq: 20, macTime: Self.mac0 + 5, arrival: Self.host0 + 1.01, samples: Self.samples())
        b.newStream(config: .route(lan: true))
        #expect(b.stats.buffered == 0 && b.bump == bump)
        b.newStream(config: .route(lan: false))
        #expect(b.bump == 0)
        // the spent storage is held for the owner to let go
        #expect(b.spentCount > 0)
        let count = b.spentCount
        #expect(b.popSpent() != nil && b.spentCount == count - 1)
        b.releaseSpent()
        #expect(b.spentCount == 0)
    }

    // MARK: Sync depth

    @Test func theSyncDepthMovesAtTwentyMillisecondsASecond() {
        var b = ScreenAudioBuffer(config: .route(lan: true))
        b.setLead(0.010)
        #expect(abs(b.depth - 0.090) < 1e-12)
        b.setSync(0.300, at: 0)
        #expect(b.syncLevel == nil, "no time passed")
        b.setSync(0.300, at: 1)
        #expect(abs(b.depth - 0.110) < 1e-9 && b.syncLevel != nil)
        for t in stride(from: 1.25, through: 20, by: 0.25) { b.setSync(0.300, at: t) }
        #expect(abs(b.depth - 0.300) < 1e-9)
        // never past the cap + lead
        b.setSync(5, at: 100)
        #expect(abs(b.depth - 0.410) < 1e-9)
        // a goal under the own need is the own need; gone, it moves back down at the same rate
        b.setSync(nil, at: 101)
        #expect(abs(b.depth - 0.390) < 1e-9)
        for t in stride(from: 101.5, through: 130, by: 0.5) { b.setSync(nil, at: t) }
        #expect(b.syncLevel == nil && abs(b.depth - 0.090) < 1e-12)
    }

    // MARK: A/V sync

    @Test func thePictureWaitsForLateSoundWhileWatching() {
        var sync = ScreenAVSync()
        func up(_ i: ScreenAVSync.Input) -> ScreenAVSync.Output { sync.update(i) }
        var i = ScreenAVSync.Input(audioDelay: 0.300, audioOwnDelay: 0.300, videoDelay: 0.080, shownDelay: 0.080)
        // Bluetooth-like: the sound 220 ms later → the picture waits 205 ms
        var out = sync.update(i)
        #expect(sync.engaged && abs(out.videoFloor - 0.205) < 1e-12 && out.audioDelayGoal == nil)
        #expect(abs((out.skew ?? 0) - 0.220) < 1e-12)
        // as shown (with the floor): the skew is what is left
        i.shownDelay = 0.285
        #expect(abs((up(i).skew ?? 0) - 0.015) < 1e-12)
        // capped
        i.audioDelay = 0.700
        #expect(up(i).videoFloor == ScreenAVSync.maxVideoFloor)
        // interactive: none (the playout drops it at once), but it comes back after
        i.audioDelay = 0.300
        i.interactive = true
        #expect(up(i).videoFloor == 0 && sync.engaged)
        i.interactive = false
        #expect(up(i).videoFloor > 0.2)
        // silent for 5 s: released
        i.soundRecent = false
        #expect(up(i).videoFloor == 0 && !sync.engaged)
        // only past 45 ms does it engage; once engaged it follows down to 15 ms
        i.soundRecent = true
        i.audioDelay = 0.120
        #expect(up(i).videoFloor == 0 && !sync.engaged)
        i.audioDelay = 0.130
        #expect(abs(up(i).videoFloor - 0.035) < 1e-12)
        i.audioDelay = 0.110
        #expect(abs(up(i).videoFloor - 0.015) < 1e-12)
        i.audioDelay = 0.090
        #expect(up(i).videoFloor == 0 && !sync.engaged)
        // a touch never engages it
        i.audioDelay = 0.300
        i.interactive = true
        #expect(up(i).videoFloor == 0 && !sync.engaged)
    }

    @Test func theSoundRisesToASlowerSmoothPicture() {
        var sync = ScreenAVSync()
        func up(_ i: ScreenAVSync.Input) -> ScreenAVSync.Output { sync.update(i) }
        var i = ScreenAVSync.Input(audioDelay: 0.100, audioOwnDelay: 0.100, videoDelay: 0.180, shownDelay: 0.050,
                                   interactive: true)
        // the smooth video (not the touch one) is later than the sound: the sound goes to video + 15
        let out = sync.update(i)
        #expect(out.audioDelayGoal.map { abs($0 - 0.195) < 1e-12 } == true && out.videoFloor == 0)
        #expect(abs((out.skew ?? 0) - 0.050) < 1e-12)
        i.enabled = false
        #expect(up(i) == ScreenAVSync.Output())
        // the panel's «Picture waits for sound» off: the sound still rises, the picture never waits
        i.enabled = true
        i.videoFloorEnabled = false
        i.interactive = false
        i.audioDelay = 0.500
        #expect(up(i).videoFloor == 0)
    }

    @Test func theDelaysComeFromTheBufferAndThePlayout() {
        var b = ScreenAudioBuffer.Stats(depth: 0.132, buffered: 0.1, need: 0.120, lead: 0.012, jitter: nil, base: 0.040,
                                        playing: false, underruns: 0, late: 0, overflow: 0, cuts: 0, concealed: 0)
        // waiting: base + depth + output latency − offset
        #expect(ScreenAVSync.audioDelay(b, outputLatency: 0.010, offset: 0.031).map { abs($0 - 0.151) < 1e-12 } == true)
        b.delay = 0.200
        #expect(ScreenAVSync.audioDelay(b, outputLatency: 0.010, offset: 0.031).map { abs($0 - 0.179) < 1e-12 } == true)
        b.sync = 0.300
        #expect(ScreenAVSync.audioOwnDelay(b, outputLatency: 0.010, offset: 0.031).map { abs($0 - 0.151) < 1e-12 } == true)
        // the depth that gives a goal
        let depth = ScreenAVSync.syncDepth(goal: 0.195, base: 0.040, outputLatency: 0.010, offset: 0.031)
        #expect(abs(depth - 0.176) < 1e-12)
        let p = ScreenStreamStats.Playout(hold: 0.058, base: 0.020, smoothDepth: 0.050, lead: 1.0 / 120)
        let v = ScreenAVSync.videoDelays(p)
        #expect(v.map { abs($0.smooth - (0.070 + 2.0 / 120)) < 1e-12 && abs($0.shown - (0.078 + 1.0 / 120)) < 1e-12 } == true)
        #expect(ScreenAVSync.videoDelays(ScreenStreamStats.Playout(hold: 0)) == nil)
    }

    @Test func thePlayoutsSyncFloorRampsAndDropsAtATouch() {
        var p = ScreenPlayout<Int>()
        p.lead = 1.0 / 60
        var t = 0.0
        var seq = 0
        func push() {
            _ = p.push(seq, macTime: 100 + t, arrival: t + 0.020)
            seq += 1
            t += 1.0 / 30
        }
        for _ in 0..<30 { push() }
        let hold = p.hold
        p.syncFloor = 0.200
        for _ in 0..<30 { push() }
        // a second at 100 ms/s
        #expect(abs(p.syncHold - 0.100) < 0.004, "\(p.syncHold)")
        #expect(p.hold > hold && p.hold > p.syncHold)
        for _ in 0..<60 { push() }
        #expect(abs(p.syncHold - 0.200) < 1e-9)
        // room for the pictures it holds (12 + 200 ms of 30 fps)
        #expect(p.queued > 12)
        p.interactive = true
        #expect(p.syncHold == 0)
        p.interactive = false
        push()
        #expect(p.syncHold < 0.01, "from 0 again")
        for _ in 0..<90 { push() }
        p.syncFloor = 0
        for _ in 0..<15 { push() }
        #expect(abs(p.syncHold - 0.150) < 0.004, "down at the same rate: \(p.syncHold)")
        p.syncFloor = 9
        #expect(p.syncFloor == ScreenPlayout<Int>.maxSyncFloor)
        p.syncFloor = -.infinity
        #expect(p.syncFloor == 0)
    }

    // MARK: Lock-free ring and published numbers

    private final class Tracked: @unchecked Sendable {
        static let alive = Atomic<Int>(0)
        let value: Int
        init(_ v: Int) { value = v; Self.alive.add(1, ordering: .relaxed) }
        deinit { Self.alive.subtract(1, ordering: .relaxed) }
    }

    @Test func theRingKeepsOrderAcrossTwoThreadsAndRefusesWhenFull() async {
        let ring = ScreenAudioRing<Int>(capacity: 64)
        let n = 200_000
        let producer = Task.detached {
            var i = 0
            while i < n { if ring.push(i) { i += 1 } }
        }
        let consumer = Task.detached { () -> Bool in
            var expected = 0
            while expected < n {
                if let v = ring.pop() {
                    if v != expected { return false }
                    expected += 1
                }
            }
            return true
        }
        await producer.value
        #expect(await consumer.value)
        #expect(ring.pop() == nil && ring.count == 0)
        // full: nothing taken
        let small = ScreenAudioRing<Int>(capacity: 3)
        #expect(small.push(1) && small.push(2) && small.push(3))
        #expect(!small.hasRoom && !small.push(4) && small.count == 3)
        #expect(small.pop() == 1 && small.hasRoom && small.push(5))
        #expect([small.pop(), small.pop(), small.pop(), small.pop()] == [2, 3, 5, nil])
    }

    @Test func theRingLetsGoOfWhatIsLeftAndMovesWithoutCopies() {
        let before = Tracked.alive.load(ordering: .relaxed)
        do {
            let ring = ScreenAudioRing<Tracked>(capacity: 8)
            for i in 0..<5 { ring.push(Tracked(i)) }
            #expect(ring.pop()?.value == 0)
            #expect(Tracked.alive.load(ordering: .relaxed) == before + 4)
        }
        #expect(Tracked.alive.load(ordering: .relaxed) == before)
        // an array's storage goes in and comes out the same (no copy)
        let ring = ScreenAudioRing<[Float]>(capacity: 2)
        var a: [Float] = [1, 2, 3]
        let address = a.withUnsafeBufferPointer { $0.baseAddress }
        ring.push(a)
        a = []
        let back = ring.pop()
        #expect(back == [1, 2, 3] && back?.withUnsafeBufferPointer({ $0.baseAddress }) == address)
    }

    @Test func publishedNumbersReadWhole() async {
        let p = ScreenAudioPublished()
        #expect(p.read() == nil)
        p.publish { set in set(.depth, 0.1); set(.sync, .nan); set(.underruns, 3) }
        let v = p.read()
        #expect(v?[.depth] == 0.1 && v?[.underruns] == 3 && v?[.sync]?.isNaN == true)
        // a writer that keeps all fields equal: a reader never sees them mixed
        let writer = Task.detached {
            for k in 0..<50_000 {
                p.publish { set in for f in ScreenAudioPublished.Field.allCases { set(f, Double(k)) } }
            }
        }
        let reader = Task.detached { () -> Bool in
            for _ in 0..<5_000 {
                guard let v = p.read() else { continue }
                if Set(v.values).count != 1 { return false }
            }
            return true
        }
        await writer.value
        #expect(await reader.value)
    }

    // MARK: Report, header

    @Test func theReportCountsSinceTheLastAndClamps() throws {
        var r = ScreenAudioReporter()
        var buffer = ScreenAudioBuffer.Stats(depth: 0.132, buffered: 0.052, need: 0.120, lead: 0.012, jitter: 0.03,
                                             base: 0.040, playing: true, delay: 0.150, underruns: 2, late: 5, overflow: 0,
                                             cuts: 3, cutFrames: 1_440, concealed: 1)
        var snap = ScreenAudioOutput.Snapshot(buffer: buffer, io: 0.0053, outputLatency: 0.008, bluetooth: false, kbps: 64.4)
        let firstReport = r.report(snap, skewMs: 8, floorMs: 0)
        let first = try #require(firstReport)
        #expect(first.underruns == 2 && first.late == 5 && first.cuts == 3 && first.concealed == 1)
        #expect(abs(first.addedMs - 118) < 1e-9 && abs(first.depthMs - 120) < 1e-9)
        #expect(first.stretchMs.map { abs($0 + 30) < 1e-9 } == true)
        buffer.underruns = 3
        buffer.delay = nil
        snap.buffer = buffer
        let secondReport = r.report(snap, skewMs: nil, floorMs: 140)
        let second = try #require(secondReport)
        #expect(second.underruns == 1 && second.late == 0 && second.cuts == 0 && second.stretchMs == nil)
        #expect(abs(second.addedMs - 140) < 1e-9, "waiting: depth + output")
        let json = second.json
        #expect(json["underruns"] as? Int == 1 && json["floorMs"] as? Double == 140 && json["skewMs"] == nil)
        #expect(json["bluetooth"] == nil && json["kbps"] as? Double == 64 && json["ioMs"] as? Double == 5.3)
        // a buffer that started over counts from its own zero
        buffer.underruns = 0
        snap.buffer = buffer
        let restarted = r.report(snap, skewMs: nil, floorMs: nil)
        #expect(restarted?.underruns == 0)
        let empty = r.report(ScreenAudioOutput.Snapshot(), skewMs: nil, floorMs: nil)
        #expect(empty == nil)
        // the ranges; floor 0 left out; the same keys through Codable
        let wild = ScreenAudioReport(outputMs: 5_000, ioMs: -3, bluetooth: true, depthMs: .nan, bufferedMs: 10_000,
                                     addedMs: 9_999, skewMs: -9_000, floorMs: 0, underruns: -1, late: 1_000_000,
                                     concealed: 0, cuts: 0, stretchMs: nil, kbps: .infinity)
        let w = wild.json
        #expect(w["outputMs"] as? Double == 1_000 && w["ioMs"] as? Double == 0 && w["depthMs"] as? Double == 0)
        #expect(w["bufferedMs"] as? Double == 3_000 && w["addedMs"] as? Double == 5_000 && w["skewMs"] as? Double == -3_000)
        #expect(w["floorMs"] == nil && w["underruns"] as? Int == 0 && w["late"] as? Int == 100_000)
        #expect(w["bluetooth"] as? Bool == true && w["kbps"] as? Double == 0)
        let coded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(wild)) as? [String: Any])
        #expect(Set(coded.keys) == Set(w.keys))
        #expect(coded["addedMs"] as? Double == 5_000)
        // it rides the playout report
        var report = ScreenPlayoutReport(mode: .smooth)
        report.audio = second
        #expect((report.json["audio"] as? [String: Any])?["underruns"] as? Int == 1)
        #expect(ScreenPlayoutReport(mode: .smooth).json["audio"] == nil)
    }

    @Test func theStreamStatsAttachTheSoundsReportToADueReport() {
        let stats = ScreenStreamStats()
        stats.streamStarted(mode: .smooth, at: 0)
        stats.shown(decodeMs: 1, at: 0.5)
        let calls = Mutex(0)
        stats.setAudioReport {
            calls.withLock { $0 += 1 }
            return ScreenAudioReport(outputMs: 8, ioMs: 5, depthMs: 80, bufferedMs: 60, addedMs: 100, kbps: 64)
        }
        #expect(stats.takeReport(at: 1) == nil && calls.withLock { $0 } == 0, "not due yet: not asked")
        stats.shown(decodeMs: 1, at: 2.5)
        #expect(stats.takeReport(at: 3)?.audio?.depthMs == 80)
        stats.setAudioReport(nil)
        stats.shown(decodeMs: 1, at: 5.5)
        let later = stats.takeReport(at: 6)
        #expect(later != nil && later?.audio == nil)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func theAudioVideoOffsetHeader() {
        func offset(_ v: String?) -> Double { ScreenAudioFormat.videoOffsetMs { $0 == "X-Audio-Video-Offset" ? v : nil } }
        #expect(ScreenAudioFormat.defaultVideoOffsetMs == 31)
        #expect(offset(nil) == 31)
        #expect(offset("garbage") == 31 && offset("") == 31 && offset("nan") == 31 && offset("inf") == 31)
        #expect(offset("5000") == 31 && offset("-2001") == 31)
        #expect(offset("48") == 48 && offset(" -12 ") == -12 && offset("0") == 0 && offset("18.5") == 18.5)
    }
}
