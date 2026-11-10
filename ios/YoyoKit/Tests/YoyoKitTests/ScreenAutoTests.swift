import Foundation
import QuartzCore
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The Screen page's automatic mode under network jitter (PROTOCOL.md「客户端的平滑播放」「操作时自动低延迟」): the touch
/// buffer and the ramp back of the playout core, its 100 ms cap and 12-picture queue, the stall metric and the new report
/// fields, the touch budget's source, keys as interaction, the retired settings.
@Suite("Screen auto mode")
struct ScreenAutoTests {
    private static let mac = 1_761_170_000.0
    private static let host = 5_000.0

    /// 30 fps for `count` pictures, 40 ms on the way, every other one `late` later; each pushed and the display asked
    /// a while after (so nothing stays queued). Returns the next picture's time offset.
    @discardableResult
    private static func learn(_ core: inout ScreenPlayout<Int>, count: Int = 40, late: Double = 0.030) -> Double {
        core.lead = 1.0 / 120
        for i in 0..<count {
            let t = Double(i) / 30
            _ = core.push(i, macTime: mac + t, arrival: host + t + 0.040 + (i % 2 == 0 ? 0 : late))
            _ = core.next(target: host + t + 0.5)
        }
        return Double(count) / 30
    }

    // MARK: The core

    @Test func theDefaultsAre100msAnd12Pictures() {
        let config = ScreenPlayout<Int>.Config()
        #expect(config.maxDepth == 0.100 && config.maxQueue == 12)
        #expect(config.rampPerSecond == 0.100 && config.minTouchBudget == 0.008 && config.interactiveCap == 0.030)
    }

    @Test func interactivePicturesWaitAtMostTheTouchBudget() throws {
        var core = ScreenPlayout<Int>()
        let t = Self.learn(&core)
        let base = try #require(core.base)
        #expect(core.depth > 0.030 && core.depth < 0.040)
        #expect(abs(try #require(core.jitter) - 0.030) < 1e-6, "the p95 of the delays above the base")
        core.touchBudget = 0.020
        core.interactive = true
        #expect(core.touchBuffer == 0.020)
        #expect(abs(core.hold - (0.020 + core.lead)) < 1e-9)
        #expect(core.paceInterval == nil)
        // on time: due at macTime + base + min(depth, budget) + lead
        let onTime = Self.host + t + 0.040
        #expect(core.push(100, macTime: Self.mac + t, arrival: onTime) == .queued)
        let due = Self.mac + t + base + 0.020 + core.lead
        #expect(core.next(target: due - 0.001) == nil)
        #expect(core.next(target: due + 0.0001) == 100)
        // late by 30 ms: at most the budget after it arrived (here already due: the next refresh)
        let t2 = t + 1.0 / 30
        let late = Self.host + t2 + 0.070
        #expect(core.push(101, macTime: Self.mac + t2, arrival: late) == .queued)
        #expect(core.next(target: late + 0.001) == 101)
        // a stall (too late for any depth): the next refresh, no extra wait
        let t3 = t2 + 1.0 / 30
        let stalled = Self.host + t3 + 0.6
        #expect(core.push(102, macTime: Self.mac + t3, arrival: stalled) == .queued)
        #expect(core.next(target: stalled + core.lead) == 102)
    }

    @Test func noTouchBudgetOrATinyOneShowsOnArrival() {
        for budget in [nil, 0.005] as [Double?] {
            var core = ScreenPlayout<Int>()
            let t = Self.learn(&core)
            core.touchBudget = budget
            core.interactive = true
            #expect(core.touchBuffer == nil && core.hold == 0)
            #expect(core.push(100, macTime: Self.mac + t, arrival: Self.host + t + 0.04) == .now)
        }
    }

    @Test func refinesWhileInteractiveAreDueOnArrival() {
        var core = ScreenPlayout<Int>()
        let t = Self.learn(&core)
        core.touchBudget = 0.030
        core.interactive = true
        let arrival = Self.host + t + 0.3
        #expect(core.push(7, macTime: Self.mac, sample: false, arrival: arrival) == .queued)
        #expect(core.next(target: arrival) == 7)
    }

    @Test func turnedInteractiveWhatWaitsIsDueNoLaterThanTheTouchRule() throws {
        var core = ScreenPlayout<Int>()
        let t = Self.learn(&core)
        let base = try #require(core.base)
        let smoothDue = Self.mac + t + base + core.depth + core.lead
        #expect(core.push(100, macTime: Self.mac + t, arrival: Self.host + t + 0.040) == .queued)
        let touchDue = Self.mac + t + base + 0.020 + core.lead
        #expect(touchDue < smoothDue - 0.010)
        core.touchBudget = 0.020
        core.interactive = true
        #expect(core.next(target: touchDue + 0.0001) == 100, "at once, not at the smooth time")
    }

    @Test func evenPaceIsOffWhileInteractive() {
        var core = ScreenPlayout<Int>()
        core.evenPace = true
        let t = Self.learn(&core)
        #expect(core.pace > 1)
        core.touchBudget = 0.030
        core.interactive = true
        // two pictures due a refresh apart both show (smooth would hold the second to the next slot)
        _ = core.push(100, macTime: Self.mac + t, arrival: Self.host + t)
        let first = Self.host + t + 0.2
        #expect(core.next(target: first) == 100)
        _ = core.push(101, macTime: Self.mac + t + 0.001, arrival: Self.host + t + 0.001)
        #expect(core.next(target: first + core.lead) == 101)
    }

    @Test func backToSmoothTheHoldRampsUpAtMost100msASecond() throws {
        var core = ScreenPlayout<Int>()
        // jitter up to 75 ms: a deep smooth buffer
        var t = Self.learn(&core, count: 60, late: 0.075)
        let depth = core.depth
        #expect(depth > 0.075)
        core.touchBudget = 0.020
        core.interactive = true
        // interactive takes effect at once
        #expect(abs(core.hold - (0.020 + core.lead)) < 1e-9)
        for _ in 0..<10 {
            _ = core.push(0, macTime: Self.mac + t, arrival: Self.host + t + 0.040)
            _ = core.next(target: Self.host + t + 0.5)
            t += 1.0 / 30
        }
        core.interactive = false
        // the finger lifted: the hold starts at the touch hold, not the smooth depth
        #expect(abs(core.hold - (0.020 + core.lead)) < 1e-9)
        var holds: [(at: Double, hold: Double)] = []
        var dues: [Double] = []
        for i in 0..<45 {
            let arrival = Self.host + t + 0.040
            _ = core.push(i, macTime: Self.mac + t, arrival: arrival)
            holds.append((arrival, core.hold))
            dues.append(Self.mac + t + core.base! + core.hold)
            _ = core.next(target: Self.host + t + 0.5)
            t += 1.0 / 30
        }
        for (a, b) in zip(holds, holds.dropFirst()) {
            #expect(b.hold - a.hold <= 0.100 * (b.at - a.at) + 1e-9)
            #expect(b.hold >= a.hold - 1e-9)
        }
        // pictures stay in order (each due after the one before)
        #expect(zip(dues, dues.dropFirst()).allSatisfy { $0 < $1 })
        // and it is back at the smooth depth well within a second
        #expect(abs(holds.last!.hold - (core.depth + core.lead)) < 1e-9)
        let first = try #require(holds.first)
        let reached = try #require(holds.first { abs($0.hold - (core.depth + core.lead)) < 1e-9 })
        #expect(reached.at - first.at < 0.8)
        #expect(reached.at - first.at >= (core.depth - 0.020) / 0.100 - 1.0 / 30 - 1e-9)
    }

    @Test func aDeepBufferAt60fpsIsNotCappedByTheQueue() {
        // 60 fps with jitter up to 85 ms: the depth goes past 67 ms (four pictures at 60 fps), and every picture shows
        var noise: UInt64 = 11
        func next() -> Double {
            noise = noise &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(noise >> 11) / Double(1 << 53)
        }
        let arrivals = (0..<480).map { i in (mac: Self.mac + Double(i) / 60, at: Self.host + Double(i) / 60 + 0.04 + next() * 0.085) }
        var core = ScreenPlayout<Int>()
        core.lead = 1.0 / 120
        var shown = Set<Int>()
        var pushed = 0
        var tick = 0
        while pushed < arrivals.count || core.queued > 0 {
            let now = Self.host + Double(tick) / 120
            while pushed < arrivals.count, arrivals[pushed].at <= now {
                _ = core.push(pushed, macTime: arrivals[pushed].mac, arrival: arrivals[pushed].at)
                pushed += 1
            }
            if let i = core.next(target: now + 1.0 / 120) { shown.insert(i) }
            tick += 1
            if tick > 120 * 20 { break }
        }
        #expect(core.depth > 0.067)
        let settled = (180..<480).filter(shown.contains).count
        #expect(Double(settled) / 300 > 0.9)
    }

    // MARK: Stalls and the report

    @Test func aStallIsAShownGapLongerThanTheMacsBy150or300ms() throws {
        var meter = ScreenPlayoutMeter()
        meter.reset(at: 0)
        let shown: [(Double, Double?)] = [
            (0, 0), (0.033, 0.033), (0.066, 0.066),
            (0.150, nil),                       // a refine: not a live picture
            (0.266, 0.099),                     // 200 ms shown for 33 of content: a 150 ms stall
            (0.299, 0.132), (0.699, 0.165),     // 400 ms for 33: both
            (1.699, 1.165),                     // the content stood still a second: none
        ]
        for (at, mac) in shown { meter.shown(at: at, decodeMs: 1, macTime: mac.map { Self.mac + $0 }) }
        let r = try #require(meter.report(mode: .smooth, bufferMs: 30, at: 2))
        #expect(abs(try #require(r.stall150PerSec) - 1.0) < 1e-9)
        #expect(abs(try #require(r.stall300PerSec) - 0.5) < 1e-9)
        // without macTimes (an older server): no stall numbers
        var plain = ScreenPlayoutMeter()
        plain.reset(at: 0)
        for t in [0.0, 0.5, 1.0] { plain.shown(at: t, decodeMs: nil) }
        let p = try #require(plain.report(mode: .smooth, bufferMs: nil, at: 1.5))
        #expect(p.stall150PerSec == nil && p.stall300PerSec == nil)
    }

    @Test func theNewReportFieldsOnTheWireAndInTheStatsLine() throws {
        let r = ScreenPlayoutReport(mode: .latency, fps: 60, hitchesPerSec: 0.31, bufferMs: 28.3, stall150PerSec: 1.04,
                                    stall300PerSec: 0, jitterP95Ms: 23.46, touchBufferMs: 30)
        let data = try JSONSerialization.data(withJSONObject: r.json)
        let back = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(back["stall150PerSec"] as? Double == 1 && back["stall300PerSec"] as? Double == 0)
        #expect(back["jitterP95Ms"] as? Double == 23.5 && back["touchBufferMs"] as? Double == 30)
        #expect(back["overrides"] == nil)
        #expect(r.line == "responsive · gap -/- · arr -/- · hitch 0.3/s · stall 1.0/0.0/s · buf 28 ms · jit 23 · touch 30 ms")
        // left out when nil
        let plain = ScreenPlayoutReport(mode: .smooth).json
        for key in ["stall150PerSec", "stall300PerSec", "jitterP95Ms", "touchBufferMs"] { #expect(plain[key] == nil, "\(key)") }
    }

    @Test func theStatsReportTheTouchBufferAndJitter() throws {
        let stats = ScreenStreamStats()
        stats.streamStarted(mode: .smooth, route: .tunnel, at: 100)
        stats.playout(.init(hold: 0.028, refreshHz: 120, cap: 0.1, touch: nil, jitter: 0.0246))
        stats.shown(decodeMs: 1, at: 100.5, macTime: Self.mac)
        let smooth = try #require(stats.takeReport(at: 102.1))
        #expect(smooth.mode == .smooth && smooth.touchBufferMs == nil)
        #expect(abs(try #require(smooth.jitterP95Ms) - 24.6) < 1e-9)
        stats.setInteractive(true)
        stats.playout(.init(hold: 0.028, cap: 0.1, touch: 0.02, jitter: 0.0246))
        stats.shown(decodeMs: 1, at: 103, macTime: Self.mac + 2.5)
        let live = try #require(stats.takeReport(at: 104.2))
        let touch = try #require(live.touchBufferMs)
        #expect(live.mode == .latency && abs(touch - 20) < 1e-9)
        let snap = stats.take(host: 104.3)
        #expect(snap.line.hasSuffix(" · live"))
        // on arrival (no smooth playback at all): latency with no touch buffer
        stats.streamStarted(mode: .latency, at: 200)
        stats.shown(decodeMs: 1, at: 200.5)
        let arrival = try #require(stats.takeReport(at: 202.1))
        #expect(arrival.touchBufferMs == 0 && arrival.jitterP95Ms == nil)
    }

    // MARK: The touch budget's source

    @Test func theTouchBudgetIsAQuarterOfTheMinimumRoundTrip() {
        #expect(ScreenTouchBudget.auto(rttMinMs: 136, onLan: false) == 0.034)
        #expect(ScreenTouchBudget.auto(rttMinMs: 240, onLan: false) == 0.045, "capped")
        #expect(ScreenTouchBudget.auto(rttMinMs: 32, onLan: false) == 0.008)
        #expect(ScreenTouchBudget.auto(rttMinMs: 30, onLan: false) == nil, "under 8 ms: on arrival")
        #expect(ScreenTouchBudget.auto(rttMinMs: 8, onLan: true) == nil, "the LAN")
        // without a round trip: none on the LAN, 30 ms through the tunnel
        #expect(ScreenTouchBudget.auto(rttMinMs: nil, onLan: true) == nil)
        #expect(ScreenTouchBudget.auto(rttMinMs: nil, onLan: false) == 0.030)
        #expect(ScreenTouchBudget.auto(rttMinMs: .nan, onLan: false) == 0.030)
    }

    @Test func onlyAFreshAckAnswerGivesTheRoundTrip() {
        let stats = ScreenStreamStats()
        stats.streamStarted(mode: .smooth, at: 90)
        #expect(stats.freshRttMin(at: 100) == nil)
        stats.netQuality(ScreenNetQuality(grade: .fair, rttMs: .init(min: 136, p50: 167, p90: 201)), at: 100)
        #expect(stats.freshRttMin(at: 105) == 136)
        #expect(stats.freshRttMin(at: 110) == 136)
        #expect(stats.freshRttMin(at: 110.5) == nil, "older than 10 s")
        // an answer without round trips (few samples): none
        stats.netQuality(ScreenNetQuality(grade: .unknown, reasons: [.fewSamples]), at: 111)
        #expect(stats.freshRttMin(at: 111) == nil)
        // a new stream starts over
        stats.netQuality(ScreenNetQuality(grade: .good, rttMs: .init(min: 8, p50: 14, p90: 22)), at: 112)
        stats.streamStarted(mode: .smooth, at: 113)
        #expect(stats.freshRttMin(at: 113) == nil)
    }

    @Test func thePlayerTakesTheTouchBudgetLive() {
        let stats = ScreenStreamStats()
        stats.streamStarted(mode: .smooth, at: CACurrentMediaTime())
        let player = ScreenPlayer(output: nil, stats: stats, touchBudget: 0.012) { _, _ in }
        player.setInteractive(true)
        #expect(stats.live().playout?.touch == 0.012)
        player.setTouchBudget(0.020)
        #expect(stats.live().playout?.touch == 0.020)
        // the interactive depth is at most the (starting) smooth depth, 25 ms
        player.setTouchBudget(0.040)
        #expect(stats.live().playout?.touch == 0.025)
        player.setTouchBudget(nil)
        #expect(stats.live().playout?.touch == nil && stats.live().playout?.hold == 0)
        player.stop()
    }

    // MARK: Keys

    @Test func keysAreInteractionWithTheSameTail() {
        var i = ScreenInteractivity()
        let t0 = ContinuousClock.now
        let first = i.key(at: t0)
        #expect(first.became && first.until == t0 + ScreenInteractivity.linger && i.interactive)
        let again = i.key(at: t0 + .milliseconds(500))
        #expect(!again.became && again.until == t0 + .milliseconds(1100))
        let early = i.expire(at: t0 + .milliseconds(1099))
        #expect(!early)
        let over = i.expire(at: t0 + .milliseconds(1100))
        #expect(over && !i.interactive)
        // a finger down keeps it on whatever the keys do; the tail runs from its lift
        _ = i.began()
        let typed = i.key(at: t0 + .seconds(2))
        #expect(!typed.became && typed.until == nil)
        let lifted = i.ended(at: t0 + .seconds(3))
        #expect(lifted == t0 + .seconds(3) + ScreenInteractivity.linger)
        let stillOn = i.expire(at: t0 + .seconds(2) + ScreenInteractivity.linger)
        #expect(!stillOn)
    }
}
