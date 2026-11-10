import CoreVideo
import Foundation
import QuartzCore
import Synchronization
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// Smooth playback (PROTOCOL.md「客户端的平滑播放」): the jitter buffer core with injected times, the playout meter, the
/// player on its display link, and the playout report riding an ack.
@Suite("Screen playout")
struct ScreenPlayoutTests {
    // MARK: Simulation

    /// A deterministic jitter source (an LCG), 0…1.
    private struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// The Mac's clock (seconds since 1970) and the phone's host clock are unrelated: the delays carry this offset.
    private static let macEpoch = 1_761_170_000.0
    private static let host0 = 5_000.0

    private struct Arrival { var macTime: Double; var arrival: Double }

    /// 30 fps from the Mac, arriving after `network` plus `jitter(t)` (seconds).
    private static func pictures(seconds: Double, fps: Double = 30, network: Double = 0.040, seed: UInt64 = 7,
                                 jitter: (Double, inout Noise) -> Double) -> [Arrival] {
        var noise = Noise(state: seed)
        return (0..<Int(seconds * fps)).map { i in
            let t = Double(i) / fps
            return Arrival(macTime: macEpoch + t, arrival: host0 + t + network + jitter(t, &noise))
        }
    }

    /// Runs the core against a 120 Hz display: before each refresh the pictures that arrived are pushed, then the one
    /// for the refresh after it (`targetTimestamp`) is taken. Returns when each picture was shown (nil: never) and the
    /// depth after each push.
    private static func play(_ pictures: [Arrival], core: inout ScreenPlayout<Int>, hz: Double = 120)
        -> (shown: [Double?], depths: [(at: Double, depth: Double)]) {
        var shown = [Double?](repeating: nil, count: pictures.count)
        var depths: [(Double, Double)] = []
        var next = 0
        let end = (pictures.last?.arrival ?? host0) + 0.2
        var tick = 0
        core.lead = 1 / hz
        while true {
            let now = host0 + Double(tick) / hz
            if now > end { break }
            while next < pictures.count, pictures[next].arrival <= now {
                _ = core.push(next, macTime: pictures[next].macTime, arrival: pictures[next].arrival)
                depths.append((pictures[next].arrival, core.depth))
                next += 1
            }
            let target = now + 1 / hz
            if let i = core.next(target: target) { shown[i] = target }
            tick += 1
        }
        return (shown, depths)
    }

    private static func gaps(_ times: [Double]) -> [Double] { zip(times, times.dropFirst()).map { $1 - $0 } }

    // MARK: The core

    @Test func jitteryArrivalsAreShownAtAnEvenPace() {
        let pictures = Self.pictures(seconds: 8) { _, n in n.next() * 0.030 }
        var core = ScreenPlayout<Int>()
        let (shown, _) = Self.play(pictures, core: &core)
        // past the first few seconds (the estimate settled): every picture shown, at 30 fps give or take a refresh
        let settled = Array(shown[90...])
        #expect(settled.allSatisfy { $0 != nil })
        let shownGaps = Self.gaps(settled.compactMap { $0 })
        let even = shownGaps.filter { abs($0 - 1.0 / 30) < 0.001 }.count
        #expect(Double(even) / Double(shownGaps.count) > 0.9)
        #expect(shownGaps.allSatisfy { $0 > 0.024 && $0 < 0.043 })
        // while the arrivals themselves were all over the place
        let arrivalGaps = Self.gaps(pictures[90...].map(\.arrival))
        #expect(arrivalGaps.max()! - arrivalGaps.min()! > 0.040)
        #expect(core.depth > 0.025 && core.depth <= 0.040)
        // no picture waited longer than the depth for its time
        for (i, t) in shown.enumerated() where i >= 90 { #expect(t! - pictures[i].arrival <= core.config.maxDepth + 1.0 / 60) }
    }

    @Test func theRemoteCapAbsorbs5GJitter() {
        // 5G: arrivals up to 150 ms above the base. The default 100 ms cap leaves the latest pictures off the pace; the
        // remote path's 200 ms holds them all, with room in the queue for them.
        let pictures = Self.pictures(seconds: 10) { _, n in n.next() * 0.150 }
        func evenShare(_ core: inout ScreenPlayout<Int>) -> Double {
            let (shown, _) = Self.play(pictures, core: &core)
            let gaps = Self.gaps(Array(shown[120...]).compactMap { $0 })
            return Double(gaps.filter { abs($0 - 1.0 / 30) < 0.001 }.count) / Double(gaps.count)
        }
        var lan = ScreenPlayout<Int>()
        var config = ScreenPlayout<Int>.Config()
        config.cap(depth: ScreenSession.remoteMaxDepth)
        #expect(config.maxDepth == 0.200 && config.maxQueue == 18)
        var remote = ScreenPlayout<Int>(config: config)
        let lanEven = evenShare(&lan)
        let remoteEven = evenShare(&remote)
        #expect(lan.depth == 0.100, "pinned at the default cap")
        #expect(remote.depth > 0.130 && remote.depth < 0.160)
        #expect(remoteEven > 0.9)
        #expect(lanEven < remoteEven - 0.1)
    }

    @Test func depthGrowsAtOnceOnJitterAndShrinksBackSlowly() {
        // calm (0–2 ms) for 4 s, jittery (0–40 ms) for 3 s, calm again for 10 s
        let pictures = Self.pictures(seconds: 17) { t, n in n.next() * (t >= 4 && t < 7 ? 0.040 : 0.002) }
        var core = ScreenPlayout<Int>()
        var depth: [(at: Double, depth: Double)] = []
        for p in pictures {
            _ = core.push(0, macTime: p.macTime, arrival: p.arrival)
            depth.append((p.arrival - Self.host0, core.depth))
        }
        func at(_ t: Double) -> Double { depth.last { $0.at <= t }!.depth }
        #expect(at(3.9) < 0.010)
        // a fraction of a second of jitter is enough to grow it…
        #expect(at(4.6) > 0.020)
        #expect(at(6.9) > 0.035 && at(6.9) <= 0.060)
        // …it shrinks back by at most 10 ms a second…
        for (a, b) in zip(depth, depth.dropFirst()) where b.depth < a.depth {
            #expect(a.depth - b.depth <= 0.010 * (b.at - a.at) + 1e-9)
        }
        // …and is small again once the jitter is out of the window
        #expect(at(16.9) < 0.010)
        #expect(core.resets == 0)
    }

    @Test func theQueueNeverGrowsPastItsCapAndOnlyTheNewestDuePictureShows() {
        var core = ScreenPlayout<Int>()
        // twenty pictures at once (a burst), not yet due: at most twelve wait, the oldest are dropped
        for i in 0..<20 {
            #expect(core.push(i, macTime: Self.macEpoch + Double(i) * 0.001, arrival: Self.host0) == .queued)
            #expect(core.queued <= core.config.maxQueue)
        }
        #expect(core.queued == 12 && core.dropped == 8)
        #expect(core.next(target: Self.host0) == nil)  // not due yet (the default depth)
        // when they're due (the default depth plus a refresh), the newest shows and the ones before it are dropped
        #expect(core.next(target: Self.host0 + 0.060) == 19)
        #expect(core.dropped == 19 && core.queued == 0)
        #expect(core.next(target: Self.host0 + 1) == nil)
    }

    @Test func noFrameTimeMeansShowAtOnce() {
        var core = ScreenPlayout<Int>()
        #expect(core.push(1, macTime: Self.macEpoch, arrival: Self.host0) == .queued)
        // an older server's picture has no X-Frame-Time: shown now, and what waited is dropped
        #expect(core.push(2, macTime: nil, arrival: Self.host0 + 0.01) == .now)
        #expect(core.queued == 0 && core.dropped == 1)
    }

    @Test func aClockStepStartsTheEstimateOver() {
        var core = ScreenPlayout<Int>()
        var mac = Self.macEpoch
        var host = Self.host0
        func feed(seconds: Double, offset: Double = 0) {
            for _ in 0..<Int(seconds * 30) {
                mac += 1.0 / 30; host += 1.0 / 30
                _ = core.push(0, macTime: mac, arrival: host + 0.040 + offset)
            }
        }
        feed(seconds: 3)
        let base = core.base!
        #expect(core.resets == 0)
        // the Mac's clock jumps 2 s ahead (delays drop by 2 s): at once
        feed(seconds: 0.1, offset: -2)
        #expect(core.resets == 1)
        #expect(abs(core.base! - (base - 2)) < 0.001)
        // and back: delays 2 s above the base; held for a second before it counts
        feed(seconds: 0.5)
        #expect(core.resets == 1)
        feed(seconds: 0.6)
        #expect(core.resets == 2)
        #expect(abs(core.base! - base) < 0.001)
        // a one-off stall (one picture 600 ms late) is not a clock step
        feed(seconds: 3)
        mac += 1.0 / 30; host += 1.0 / 30
        _ = core.push(0, macTime: mac, arrival: host + 0.640)
        feed(seconds: 1)
        #expect(core.resets == 2)
    }

    @Test func aPictureTooLateForAnyDepthShowsAtOnceAndLeavesTheDepthAlone() {
        var core = ScreenPlayout<Int>()
        var mac = Self.macEpoch
        var host = Self.host0
        for _ in 0..<90 {
            mac += 1.0 / 30; host += 1.0 / 30
            _ = core.push(0, macTime: mac, arrival: host + 0.040)
            _ = core.next(target: host + 1)
        }
        let depth = core.depth
        #expect(depth < 0.010)
        // 150 ms late: beyond the cap plus a frame
        mac += 1.0 / 30; host += 1.0 / 30
        let late = host + 0.190
        #expect(core.push(1, macTime: mac, arrival: late) == .queued)
        #expect(core.next(target: late) == 1)
        #expect(core.depth == depth)
    }

    @Test func aLastinglySlowerPathIsLearnedAfterAHold() {
        var core = ScreenPlayout<Int>()
        var mac = Self.macEpoch
        var host = Self.host0
        func feed(seconds: Double, network: Double) {
            for _ in 0..<Int(seconds * 30) {
                mac += 1.0 / 30; host += 1.0 / 30
                _ = core.push(0, macTime: mac, arrival: host + network)
            }
        }
        feed(seconds: 3, network: 0.040)
        let base = core.base!
        // the path gets 150 ms slower for good (Wi-Fi to cellular): beyond any depth, but no clock step
        feed(seconds: 0.5, network: 0.190)
        #expect(core.resets == 0 && core.base == base)
        feed(seconds: 0.6, network: 0.190)
        #expect(core.resets == 1)
        #expect(abs(core.base! - (base + 0.150)) < 0.001)
        // and pictures wait for their time again
        mac += 1.0 / 30; host += 1.0 / 30
        _ = core.next(target: host + 1)
        _ = core.push(1, macTime: mac, arrival: host + 0.190)
        #expect(core.next(target: host + 0.190) == nil)
    }

    @Test func refinesAreDueOnArrivalAndNotSampled() {
        var core = ScreenPlayout<Int>()
        var mac = Self.macEpoch
        var host = Self.host0
        for _ in 0..<60 {
            mac += 1.0 / 30; host += 1.0 / 30
            _ = core.push(0, macTime: mac, arrival: host + 0.040)
        }
        _ = core.next(target: host + 1)
        let (base, depth) = (core.base, core.depth)
        // a refine 300 ms after the last change carries that change's time
        #expect(core.push(7, macTime: mac, sample: false, arrival: host + 0.340) == .queued)
        #expect(core.next(target: host + 0.340) == 7)
        #expect(core.base == base && core.depth == depth)
    }

    // MARK: Even pace

    /// The Mac's irregular cadence: gaps alternating 17 / 33 ms (40 pictures a second), arriving with 0–2 ms of jitter.
    private static func alternating(seconds: Double, from start: Double = 0) -> [Arrival] {
        var noise = Noise(state: 11)
        var t = start
        var out: [Arrival] = []
        var short = true
        while t < start + seconds {
            out.append(Arrival(macTime: macEpoch + t, arrival: host0 + t + 0.040 + noise.next() * 0.002))
            t += short ? 0.017 : 0.033
            short.toggle()
        }
        return out
    }

    @Test func paceIsNeverSlowerThanTheContent() {
        #expect(ScreenPlayout<Int>.pace(contentInterval: 0.025, refresh: 1.0 / 60) == 1)
        #expect(ScreenPlayout<Int>.pace(contentInterval: 0.037, refresh: 1.0 / 120) == 4)   // 26 fps → 33 ms, not 42
        #expect(ScreenPlayout<Int>.pace(contentInterval: 0.042, refresh: 1.0 / 120) == 5)
        #expect(ScreenPlayout<Int>.pace(contentInterval: 0.018, refresh: 1.0 / 60) == 1)
        #expect(ScreenPlayout<Int>.pace(contentInterval: 0.025, refresh: 1.0 / 120) == 3)
        #expect(ScreenPlayout<Int>.pace(contentInterval: 1.0 / 30, refresh: 1.0 / 60) == 2)
        #expect(ScreenPlayout<Int>.pace(contentInterval: 1.0 / 30, refresh: 1.0 / 120) == 4)
        #expect(ScreenPlayout<Int>.pace(contentInterval: 0.005, refresh: 1.0 / 60) == 1)
    }

    @Test func anIrregularSourceIsShownEvenlyAt120Hz() {
        // at 60 Hz a slower pace than 40 a second would drop pictures: none there
        var at60 = ScreenPlayout<Int>()
        at60.evenPace = true
        _ = Self.play(Self.alternating(seconds: 4), core: &at60, hz: 60)
        #expect(at60.pace == 1)
        for (hz, n) in [(120.0, 3)] {
            let pictures = Self.alternating(seconds: 8)
            var paced = ScreenPlayout<Int>()
            paced.evenPace = true
            let (shown, _) = Self.play(pictures, core: &paced, hz: hz)
            #expect(paced.pace == n, "\(hz) Hz")
            #expect(paced.paceInterval.map { abs($0 - Double(n) / hz) < 1e-9 } == true)
            // past the first seconds (estimate and pace settled): one picture every n refreshes
            let settled = zip(pictures, shown).filter { $0.0.arrival - Self.host0 > 3 }.compactMap(\.1)
            let gaps = Self.gaps(settled)
            let even = gaps.filter { abs($0 - Double(n) / hz) < 0.001 }.count
            #expect(Double(even) / Double(gaps.count) > 0.9, "\(hz) Hz: \(gaps.map { Int(($0 * 1000).rounded()) })")
            #expect(gaps.allSatisfy { $0 > Double(n) / hz - 0.001 }, "\(hz) Hz: never closer than the pace")
            // without it the same source judders between one and more refreshes
            var plain = ScreenPlayout<Int>()
            let (plainShown, _) = Self.play(pictures, core: &plain, hz: hz)
            let plainGaps = Self.gaps(zip(pictures, plainShown).filter { $0.0.arrival - Self.host0 > 3 }.compactMap(\.1))
            #expect(Set(plainGaps.map { Int(($0 * hz).rounded()) }).count > 1)
            // the buffer is the same; pictures wait at most one pace more; skipped ones count as dropped
            #expect(paced.depth == plain.depth)
            for (p, t) in zip(pictures, shown) {
                if let t { #expect(t - p.arrival <= paced.hold + Double(n) / hz + 1 / hz + 1e-9) }
            }
            #expect(paced.dropped == shown.filter { $0 == nil }.count)
            // a 25 ms pace keeps all 40 a second
            #expect(paced.dropped >= plain.dropped)
        }
    }

    @Test func paceOneIsThePlainBehaviour() {
        // a steady 60 fps source at 60 Hz: n = 1, exactly what showing without even pace does
        let pictures = Self.pictures(seconds: 5, fps: 60) { _, n in n.next() * 0.010 }
        var paced = ScreenPlayout<Int>()
        paced.evenPace = true
        var plain = ScreenPlayout<Int>()
        let a = Self.play(pictures, core: &paced, hz: 60).shown
        let b = Self.play(pictures, core: &plain, hz: 60).shown
        #expect(paced.pace == 1)
        #expect(a == b)
        #expect(paced.dropped == plain.dropped)
    }

    @Test func aNewPaceIsTakenOnlyOnceItHeldASecond() {
        // 40 pictures a second (pace 3 at 120 Hz), then 60 a second (pace 2)
        let slow = Self.alternating(seconds: 5)
        let fast = (0..<Int(6 * 60)).map { i -> Arrival in
            let t = 5 + Double(i) / 60
            return Arrival(macTime: Self.macEpoch + t, arrival: Self.host0 + t + 0.040)
        }
        let pictures = slow + fast
        var core = ScreenPlayout<Int>()
        core.evenPace = true
        core.lead = 1.0 / 120
        var next = 0
        var wantedSince: Double?
        var switchedAt: Double?
        for tick in 0..<Int(11 * 120) {
            let now = Self.host0 + Double(tick) / 120
            while next < pictures.count, pictures[next].arrival <= now {
                _ = core.push(next, macTime: pictures[next].macTime, arrival: pictures[next].arrival)
                next += 1
            }
            let target = now + 1.0 / 120
            let before = core.pace
            _ = core.next(target: target)
            let wanted = ScreenPlayout<Int>.pace(contentInterval: core.contentInterval, refresh: 1.0 / 120, current: before)
            if before == 3, wanted == 2 { wantedSince = wantedSince ?? target } else if before == 3 { wantedSince = nil }
            if before == 3, core.pace == 2 { switchedAt = target }
            if tick == 4 * 120 { #expect(core.pace == 3) }
        }
        #expect(core.pace == 2)
        #expect(wantedSince != nil && switchedAt != nil)
        if let since = wantedSince, let at = switchedAt { #expect(at - since >= core.config.paceHold - 1.0 / 120 && at - since <= core.config.paceHold + 0.05) }
    }

    @Test func thePaceInUseHoldsInABandAroundIt() {
        let r = 1.0 / 120
        func pace(_ ms: Double, from current: Int) -> Int {
            ScreenPlayout<Int>.pace(contentInterval: ms / 1000, refresh: r, current: current)
        }
        // ~24 fps sits on the 4 ↔ 5 boundary (40.4 ms without a band): from 4, slower only at 41.4 ms
        #expect(ScreenPlayout<Int>.pace(contentInterval: 0.0405, refresh: r) == 5)
        #expect(pace(40.5, from: 4) == 4)
        #expect(pace(41.3, from: 4) == 4)
        #expect(pace(41.5, from: 4) == 5)
        // from 5, faster once 5 refreshes are slower than the content + 0.27 refresh (39.4 ms)
        #expect(pace(40.5, from: 5) == 5)
        #expect(pace(39.7, from: 5) == 5)
        #expect(pace(39.3, from: 5) == 4)
        // far from the band: straight to the right pace
        #expect(pace(60, from: 4) == 7)
        #expect(pace(1000.0 / 60, from: 4) == 2)
        #expect(pace(25.2, from: 1) == 3)
        #expect(pace(25.2, from: 4) == 3)
        // never slower than the content
        for ms in stride(from: 8.0, through: 100, by: 0.7) {
            for current in 1...12 { #expect(Double(pace(ms, from: current)) * r <= ms / 1000 + 0.27 * r + 1e-9) }
        }
    }

    @Test func contentWobblingAcrossTheBoundaryDoesNotFlipThePace() {
        // ~24.7 fps whose mean interval drifts 40.0…41.0 ms over 10 s (the 40.4 ms boundary crossed again and
        // again), each gap ±2 ms of noise
        var noise = Noise(state: 5)
        var pictures: [Arrival] = []
        var t = 0.0
        while t < 30 {
            pictures.append(Arrival(macTime: Self.macEpoch + t, arrival: Self.host0 + t + 0.040 + noise.next() * 0.002))
            t += 0.0405 + 0.0005 * sin(2 * .pi * t / 10) + (noise.next() - 0.5) * 0.004
        }
        var core = ScreenPlayout<Int>()
        core.evenPace = true
        core.lead = 1.0 / 120
        var next = 0
        var paces: [Int] = []
        var plainWanted: [Int] = []
        for tick in 0..<Int(30 * 120) {
            let now = Self.host0 + Double(tick) / 120
            while next < pictures.count, pictures[next].arrival <= now {
                _ = core.push(next, macTime: pictures[next].macTime, arrival: pictures[next].arrival)
                next += 1
            }
            _ = core.next(target: now + 1.0 / 120)
            guard now - Self.host0 > 5 else { continue }   // the estimate settled
            paces.append(core.pace)
            plainWanted.append(ScreenPlayout<Int>.pace(contentInterval: core.contentInterval, refresh: 1.0 / 120))
        }
        func flips(_ v: [Int]) -> Int { zip(v, v.dropFirst()).filter { $0 != $1 }.count }
        // without the band the pace would want 4 and 5 by turns
        #expect(Set(plainWanted) == [4, 5])
        #expect(flips(plainWanted) >= 4)
        #expect(flips(paces) == 0)
        #expect(paces.first == 4 || paces.first == 5)
    }

    @Test func theBufferCapIsAConfiguration() {
        // jitter up to 50 ms: the default cap lets the depth follow it, a 40 ms cap holds it there
        let pictures = Self.pictures(seconds: 6) { _, n in n.next() * 0.050 }
        var plain = ScreenPlayout<Int>()
        _ = Self.play(pictures, core: &plain)
        var config = ScreenPlayout<Int>.Config()
        config.maxDepth = 0.040
        var capped = ScreenPlayout<Int>(config: config)
        let (_, depths) = Self.play(pictures, core: &capped)
        #expect(plain.depth > 0.045)
        #expect(depths.allSatisfy { $0.depth <= 0.040 + 1e-9 })
        #expect(abs(capped.depth - 0.040) < 1e-9)
    }

    @Test func theReportCarriesTheBufferCap() throws {
        let stats = ScreenStreamStats()
        stats.streamStarted(mode: .smooth, at: 100)
        stats.playout(.init(hold: 0.032, refreshHz: 120, pace: nil, cap: 0.040))
        stats.shown(decodeMs: 1, at: 100.5)
        let r = try #require(stats.takeReport(at: 102.1))
        #expect(r.bufferCapMs == 40 && r.bufferMs == 32)
        #expect(r.json["bufferCapMs"] as? Double == 40)
        #expect(r.line.contains("buf 32 ms · cap 40"))
        #expect(ScreenPlayoutReport(mode: .latency).json["bufferCapMs"] == nil)
    }

    @Test func motionResumingAfterAPauseShowsAtOnce() {
        var core = ScreenPlayout<Int>()
        core.evenPace = true
        let pictures = Self.alternating(seconds: 4) + Self.alternating(seconds: 2, from: 6)
        let (shown, _) = Self.play(pictures, core: &core, hz: 120)
        #expect(core.pace == 3)
        // the first picture after the pause shows on the first refresh it is due for, not at a slot from before
        let first = pictures.firstIndex { $0.macTime - Self.macEpoch >= 6 }!
        let due = pictures[first].macTime + core.base! + core.depth + core.lead
        #expect(shown[first]! - due < 1.0 / 120 + 0.002)
        // and the cadence picks up from there
        let after = Self.gaps(zip(pictures, shown).filter { $0.0.macTime - Self.macEpoch >= 6.5 }.compactMap(\.1))
        #expect(Double(after.filter { abs($0 - 3.0 / 120) < 0.001 }.count) / Double(after.count) > 0.9)
    }

    @Test func turnedOnMidStreamThePaceIsTakenAtOnce() {
        let pictures = Self.alternating(seconds: 4)
        var core = ScreenPlayout<Int>()
        _ = Self.play(pictures, core: &core, hz: 120)
        #expect(core.pace == 1)
        core.evenPace = true
        #expect(core.pace == 3)
        core.evenPace = false
        #expect(core.pace == 1 && core.paceInterval == nil)
    }

    @Test func theQueueCapHoldsWhilePacing() {
        var core = ScreenPlayout<Int>()
        core.evenPace = true
        core.lead = 1.0 / 60
        for i in 0..<20 { _ = core.push(i, macTime: Self.macEpoch + Double(i) * 0.001, arrival: Self.host0) }
        #expect(core.queued == core.config.maxQueue)
    }

    // MARK: Meter

    @Test func aHitchIsOverTwiceTheMedianAndOver50ms() throws {
        // a 60 Hz display showing most pictures a refresh apart: the 33 ms gaps are not hitches, the 67 ms one is
        var meter = ScreenPlayoutMeter()
        meter.reset(at: 0)
        var t = 0.0
        for gap in [1.0, 1, 2, 1, 1, 2, 1, 1, 4, 1, 1, 2].map({ $0 / 60 }) {
            meter.shown(at: t, decodeMs: nil)
            t += gap
        }
        let r = try #require(meter.report(mode: .smooth, bufferMs: nil, refreshHz: 60, paceMs: nil, at: t))
        #expect(abs(r.gapP50Ms! - 1000.0 / 60) < 0.1)
        #expect(abs(r.hitchesPerSec! - 1 / max(t, 0.5)) < 0.01)
        #expect(r.refreshHz == 60 && r.paceMs == nil)
    }

    @Test func theMeterReportsGapsHitchesDropsAndFPS() throws {
        var meter = ScreenPlayoutMeter()
        meter.reset(at: 0)
        // 30 fps with one 100 ms hitch, then the content stands still for a second (not a hitch)
        for t in [0.0, 0.033, 0.066, 0.099, 0.199, 0.232, 1.232] { meter.shown(at: t, decodeMs: 2) }
        for t in [0.0, 0.040, 0.060, 0.099, 0.199, 0.232, 1.232] { meter.arrived(at: t) }
        meter.dropped(3, at: 0.5)
        let r = try #require(meter.report(mode: .smooth, bufferMs: 28, at: 1.5))
        #expect(r.mode == .smooth && r.bufferMs == 28 && r.decodeMs == 2)
        #expect(abs(r.fps! - 7 / 1.5) < 0.01)
        #expect(abs(r.gapP50Ms! - 33) < 0.5 && abs(r.gapP90Ms! - 100) < 0.5)
        #expect(abs(r.hitchesPerSec! - 1 / 1.5) < 0.01)
        #expect(abs(r.droppedPerSec! - 2) < 0.01)
        #expect(abs(r.arrivalGapP50Ms! - 39) < 0.5 && abs(r.arrivalGapP90Ms! - 100) < 0.5)
        // three seconds on, the window is empty: nothing to report
        #expect(meter.report(mode: .smooth, bufferMs: nil, at: 5) == nil)
        #expect(r.line == "smooth · gap 33/100 · arr 39/100 · hitch 0.7/s · buf 28 ms · drop 2.0/s")
    }

    @Test func statsGiveAReportEveryTwoSeconds() {
        let stats = ScreenStreamStats()
        stats.streamStarted(mode: .latency, at: 100)
        stats.shown(decodeMs: 1, at: 100.5)
        #expect(stats.takeReport(at: 101) == nil)
        let r = stats.takeReport(at: 102.1)
        #expect(r?.mode == .latency && r?.bufferMs == nil)
        #expect(stats.takeReport(at: 103) == nil)
        #expect(stats.take(host: 103).playout?.mode == .latency)
    }

    // MARK: Acks

    private final class Sent: Sendable {
        private let state = Mutex<(acks: [ScreenStreamAck], done: [@Sendable (ScreenAckSender.Outcome) -> Void])>(([], []))
        var acks: [ScreenStreamAck] { state.withLock { $0.acks } }
        var transport: ScreenAckSender.Transport { { [self] ack, done in state.withLock { $0.acks.append(ack); $0.done.append(done) } } }
        func finish(_ outcome: ScreenAckSender.Outcome) {
            let done = state.withLock { s in s.done.isEmpty ? nil : s.done.removeFirst() }
            done?(outcome)
        }
    }

    @Test func aReportRidesTheNextAckOnce() {
        let sent = Sent()
        let acks = ScreenAckSender(stream: "s1", transport: sent.transport)
        let report = ScreenPlayoutReport(mode: .smooth, fps: 30, bufferMs: 28)
        acks.attach(report)
        // nothing goes out for a report alone
        #expect(sent.acks.isEmpty)
        acks.received(seq: 1)
        #expect(sent.acks == [ScreenStreamAck(stream: "s1", seq: 1, report: report)])
        acks.received(seq: 2)
        #expect(sent.acks.last == ScreenStreamAck(stream: "s1", seq: 2))
        // a failed ack's report is not sent again
        acks.attach(report)
        acks.received(seq: 3)
        sent.finish(.ok); sent.finish(.ok)
        sent.finish(.failed)
        acks.received(seq: 4)
        #expect(sent.acks.last == ScreenStreamAck(stream: "s1", seq: 4))
        #expect(sent.acks.filter { $0.report != nil }.count == 2)
    }

    @Test func theRouterAttachesADueReport() {
        let sent = Sent()
        let acks = ScreenAckSender(stream: "s1", transport: sent.transport)
        let stats = ScreenStreamStats()
        stats.streamStarted(mode: .smooth, at: 100)
        stats.shown(decodeMs: 2, at: 100.5)
        let router = ScreenStreamRouter(acks: acks, stats: stats, handlers: .init(
            makeDecoder: { _ in nil }, onCursor: { _ in }))
        let video = Data([0, 0, 0, 1, 0x65, 0x88])
        router.route(ScreenStreamPart(kind: .h264, body: video, headers: ScreenPartHeaders(seq: 1)), arrival: 101)
        router.route(ScreenStreamPart(kind: .h264, body: video, headers: ScreenPartHeaders(seq: 2)), arrival: 102.2)
        #expect(sent.acks.map(\.seq) == [1, 2])
        #expect(sent.acks[0].report == nil)
        #expect(sent.acks[1].report?.mode == .smooth)
        router.stop()
    }

    @Test func ackJSONWithAndWithoutAReport() throws {
        let plain = ScreenStreamAck(stream: "stream-0001", seq: 3).json
        #expect(plain["report"] == nil && plain["keyframe"] == nil)
        let ack = ScreenStreamAck(stream: "stream-0001", seq: 4, keyframe: true,
                                  report: ScreenPlayoutReport(mode: .smooth, fps: 29.84, gapP90Ms: 41.26, bufferMs: 28.04,
                                                              droppedPerSec: .nan))
        let data = try JSONSerialization.data(withJSONObject: ack.json)
        let back = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(back["seq"] as? Int == 4 && back["keyframe"] as? Bool == true)
        let report = try #require(back["report"] as? [String: Any])
        #expect(report["mode"] as? String == "smooth")
        #expect(report["fps"] as? Double == 29.8 && report["gapP90Ms"] as? Double == 41.3 && report["bufferMs"] as? Double == 28)
        // nil and non-finite numbers are left out
        #expect(report["gapP50Ms"] == nil && report["droppedPerSec"] == nil)
        #expect(Set(report.keys) == ["mode", "fps", "gapP90Ms", "bufferMs"])
    }

    // MARK: The player

    private static func pixelBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        return try #require(pb)
    }

    @Test func thePlayerShowsQueuedPicturesFromItsDisplayLinkAndNothingAfterStop() async throws {
        let shown = Mutex<[CGSize]>([])
        let player = ScreenPlayer(output: nil, stats: nil) { size, _ in shown.withLock { $0.append(size) } }
        let picture = ScreenPlayer.Picture(image: try Self.pixelBuffer(), size: CGSize(width: 16, height: 16), decodeMs: 1)
        // no X-Frame-Time: shown right away, on the caller's thread
        player.push(picture, macTime: nil, sample: true, arrival: CACurrentMediaTime())
        #expect(shown.withLock { $0.count } == 1)
        // timed: the display link shows it a little later
        let now = CACurrentMediaTime()
        player.push(ScreenPlayer.Picture(image: try Self.pixelBuffer(), size: CGSize(width: 32, height: 32), decodeMs: 1),
                    macTime: Self.macEpoch, sample: true, arrival: now)
        let deadline = ContinuousClock.now + .seconds(3)
        while shown.withLock({ $0.count }) < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(shown.withLock { $0.last } == CGSize(width: 32, height: 32))
        player.stop()
        player.push(picture, macTime: nil, sample: true, arrival: CACurrentMediaTime())
        player.push(picture, macTime: Self.macEpoch + 1, sample: true, arrival: CACurrentMediaTime())
        try await Task.sleep(for: .milliseconds(200))
        #expect(shown.withLock { $0.count } == 2)
    }
}
