import Foundation
import Testing
@testable import YoyoCore
@testable import YoyoScreen

/// Responsive playback while the user interacts (PROTOCOL.md「客户端的平滑播放」「操作时自动低延迟」): the interactive
/// depth, the queue catching up when a finger comes down, the gradual way back to the smooth depth, and a jittery 5G
/// path that never starves the picture. Deterministic: every time is injected, the jitter is an LCG.
@Suite("Screen interactive playout")
struct ScreenInteractivePlayoutTests {
    private static let mac = 1_761_170_000.0
    private static let host = 5_000.0
    private static let hz = 120.0

    private struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private struct Arrival { var macTime: Double; var arrival: Double }

    /// `fps` pictures for `seconds`, `network` on the way plus `jitter(t)`; in order, as on one connection (a late
    /// picture holds back the ones after it).
    private static func pictures(seconds: Double, fps: Double = 60, network: Double = 0.080, seed: UInt64 = 3,
                                 jitter: (Double, inout Noise) -> Double) -> [Arrival] {
        var noise = Noise(state: seed)
        var last = -Double.infinity
        return (0..<Int(seconds * fps)).map { i in
            let t = Double(i) / fps
            last = max(last, host + t + network + jitter(t, &noise))
            return Arrival(macTime: mac + t, arrival: last)
        }
    }

    /// 5G as measured: most pictures within ~15 ms, one in twenty 40–110 ms later.
    private static func fiveG(_ t: Double, _ n: inout Noise) -> Double {
        n.next() < 0.05 ? 0.040 + n.next() * 0.070 : n.next() * 0.015
    }

    private struct Run {
        var shown: [Double?]
        /// The hold after each refresh.
        var holds: [(at: Double, hold: Double)]
        /// The most pictures left waiting after a refresh.
        var maxWaiting = 0
        /// The last picture shown.
        var lastShown: Int?
    }

    /// A 120 Hz display: before each refresh the interactivity is set (`interactive(now)`), the pictures that arrived
    /// are pushed, then the one for the next refresh is taken. Runs until the queue drained, or until `until`.
    private static func play(_ pictures: [Arrival], core: inout ScreenPlayout<Int>, until: Double? = nil,
                             interactive: (Double) -> Bool = { _ in false }) -> Run {
        var run = Run(shown: [Double?](repeating: nil, count: pictures.count), holds: [])
        var next = 0
        let end = until ?? (pictures.last?.arrival ?? host) + 0.4
        core.lead = 1 / hz
        var tick = 0
        while true {
            let now = host + Double(tick) / hz
            if now > end { break }
            core.interactive = interactive(now)
            while next < pictures.count, pictures[next].arrival <= now {
                _ = core.push(next, macTime: pictures[next].macTime, arrival: pictures[next].arrival)
                next += 1
            }
            if let i = core.next(target: now + 1 / hz) {
                run.shown[i] = now + 1 / hz
                run.lastShown = i
            }
            run.maxWaiting = max(run.maxWaiting, core.queued)
            run.holds.append((now, core.hold))
            tick += 1
        }
        return run
    }

    /// The core off the local network (the 200 ms cap) with the touch budget of a 136 ms round trip (34 ms).
    private static func remote() -> ScreenPlayout<Int> {
        var config = ScreenPlayout<Int>.Config()
        config.cap(depth: ScreenSession.remoteMaxDepth)
        var core = ScreenPlayout<Int>(config: config)
        core.touchBudget = ScreenTouchBudget.auto(rttMinMs: 136, onLan: false)
        return core
    }

    private static func remote(learning pictures: [Arrival]) -> ScreenPlayout<Int> {
        var core = remote()
        _ = play(pictures, core: &core)
        return core
    }

    // MARK: The interactive depth

    @Test func theInteractiveDepthIsAboutOnePictureInterval() throws {
        // 5G at 60 fps: a deep smooth buffer, an interactive depth of one picture interval + the margin
        var core = Self.remote(learning: Self.pictures(seconds: 4, jitter: Self.fiveG))
        #expect(core.depth > 0.060)
        #expect(core.touchBudget == 0.034)
        let d = try #require(core.interactiveDepth)
        #expect(abs(d - (1.0 / 60 + core.config.margin)) < 0.001)
        #expect(core.touchBuffer == nil, "not interactive yet")
        core.interactive = true
        #expect(core.touchBuffer == d && abs(core.hold - (d + core.lead)) < 1e-9)
        // 30 fps: the interval + margin is over the 30 ms ceiling
        let slow = Self.remote(learning: Self.pictures(seconds: 4, fps: 30, jitter: Self.fiveG))
        #expect(slow.interactiveDepth == slow.config.interactiveCap)
        // a short round trip: the touch budget binds
        var near = Self.remote(learning: Self.pictures(seconds: 4, jitter: Self.fiveG))
        near.touchBudget = 0.012
        #expect(near.interactiveDepth == 0.012)
        // a calm path: the smooth depth itself is under 8 ms, nothing to even out (on arrival)
        var calm = Self.remote(learning: Self.pictures(seconds: 4) { _, n in n.next() * 0.002 })
        #expect(calm.depth < 0.008 && calm.interactiveDepth == nil)
        calm.interactive = true
        #expect(calm.hold == 0)
        #expect(calm.push(0, macTime: Self.mac + 4, arrival: Self.host + 4.08) == .now)
        // the LAN: no touch budget, on arrival
        var lan = ScreenPlayout<Int>()
        lan.touchBudget = ScreenTouchBudget.auto(rttMinMs: 8, onLan: true)
        #expect(lan.interactiveDepth == nil)
    }

    // MARK: Catching up

    @Test func aFingerDownCatchesTheQueueUpOnTheNextRefresh() throws {
        // watching 5G for 4 s: the deep buffer holds several pictures when the finger comes down
        let pictures = Self.pictures(seconds: 5, jitter: Self.fiveG)
        let now = Self.host + 4
        func waiting(_ run: Run) -> [Int] {
            pictures.indices.filter { $0 > (run.lastShown ?? -1) && pictures[$0].arrival <= now }
        }
        var core = Self.remote()
        let run = Self.play(pictures, core: &core, until: now)
        let queued = waiting(run)
        #expect(core.queued == queued.count && queued.count >= 4, "\(core.depth * 1000) ms of pictures wait")
        let d = try #require(core.interactiveDepth)
        let base = try #require(core.base)
        core.interactive = true
        // the next refresh shows the newest picture due by the interactive rule; the ones before it are dropped
        let target = now + 2 / Self.hz
        let expected = try #require(queued.last { i in
            min(pictures[i].macTime + base + d, pictures[i].arrival + d) + core.lead <= target
        })
        let droppedBefore = core.dropped
        #expect(core.next(target: target) == expected)
        #expect(core.dropped - droppedBefore == queued.firstIndex(of: expected)!)
        // smooth playback would have shown a picture about a buffer's depth older
        #expect(target - (pictures[expected].macTime + base) < d + core.lead + 1.0 / 60 + 1e-9)
        #expect(core.queued == queued.count - queued.firstIndex(of: expected)! - 1)
        // without a touch budget (on arrival): the newest one shows at once, nothing waits
        var lan = Self.remote()
        let lanRun = Self.play(pictures, core: &lan, until: now)
        lan.touchBudget = nil
        lan.interactive = true
        #expect(lan.next(target: now + 1 / Self.hz) == waiting(lanRun).last && lan.queued == 0)
    }

    @Test func aStallWhileInteractiveShowsOnTheNextRefresh() {
        var core = Self.remote(learning: Self.pictures(seconds: 3, jitter: Self.fiveG))
        core.interactive = true
        let arrival = Self.host + 3.0 + 0.9
        #expect(core.push(1, macTime: Self.mac + 3.0, arrival: arrival) == .queued)
        #expect(core.next(target: arrival + 1 / Self.hz) == 1)
    }

    // MARK: Interactive on a jittery path

    @Test func interactiveOn5GShowsWithinTheInteractiveDepthAndNeverStarves() throws {
        let pictures = Self.pictures(seconds: 12, jitter: Self.fiveG)
        // watching for 4 s, then a finger on the picture for 8 s
        let touchAt = Self.host + 4
        var core = Self.remote()
        let run = Self.play(pictures, core: &core) { $0 >= touchAt }
        let d = try #require(core.interactiveDepth)
        #expect(d < 0.025)
        let touching = pictures.indices.filter { pictures[$0].arrival > touchAt + 0.5 }
        var waits: [Double] = []
        for i in touching {
            guard let at = run.shown[i] else { continue }
            let wait = at - pictures[i].arrival
            // no picture waits past the interactive depth (plus the lead and a refresh's rounding)
            #expect(wait <= d + 2 / Self.hz + 1e-9)
            waits.append(wait)
        }
        // most pictures are shown (late ones overtaken by a newer one are dropped: that is the point)
        #expect(Double(waits.count) / Double(touching.count) > 0.7)
        // the median wait is far under the smooth one
        let median = try #require(ScreenPlayout<Void>.percentile(waits, 0.5))
        #expect(median < 0.030)
        // the picture never freezes longer than the path's own gaps (no starvation)
        let shownTimes = touching.compactMap { run.shown[$0] }
        let arrivals = touching.map { pictures[$0].arrival }
        let longestShown = zip(shownTimes, shownTimes.dropFirst()).map { $1 - $0 }.max()!
        let longestArrival = zip(arrivals, arrivals.dropFirst()).map { $1 - $0 }.max()!
        #expect(longestShown <= longestArrival + d + 2 / Self.hz + 1e-9)
        // while watching (the first 4 s) the smooth buffer held pictures much longer
        let watching = pictures.indices.filter { pictures[$0].arrival > Self.host + 2 && pictures[$0].arrival < touchAt }
        let smoothWaits = watching.compactMap { i in run.shown[i].map { $0 - pictures[i].arrival } }
        let smoothMedian = try #require(ScreenPlayout<Void>.percentile(smoothWaits, 0.5))
        #expect(smoothMedian > 2 * median)
    }

    @Test func extremeJitterWhileInteractiveKeepsShowingTheNewest() {
        // half the pictures up to 300 ms late, a 600 ms stall now and then (the estimate even starts over): nothing is
        // shown out of order, and nothing waits past the interactive cap after it arrived
        let pictures = Self.pictures(seconds: 10, seed: 99) { t, n in
            Int(t * 60) % 97 == 0 ? 0.6 : (n.next() < 0.5 ? n.next() * 0.300 : 0)
        }
        var core = Self.remote()
        let run = Self.play(pictures, core: &core) { _ in true }
        #expect(run.maxWaiting <= core.config.maxQueue)
        let order = pictures.indices.compactMap { i in run.shown[i].map { (i, $0) } }.sorted { $0.1 < $1.1 }
        #expect(order.count > 100)
        #expect(zip(order, order.dropFirst()).allSatisfy { $0.0 < $1.0 })
        for (i, at) in order { #expect(at - pictures[i].arrival <= core.config.interactiveCap + 2 / Self.hz + 1e-9) }
        // the newest picture always shows within two refreshes of arriving once the backlog is through
        #expect(run.shown.last! != nil)
    }

    // MARK: Back to smooth

    @Test func afterTheTailTheDepthEasesBackWithoutAFreeze() throws {
        // 5G, 60 fps: interactive from 3 s to 6 s, then smooth again
        let pictures = Self.pictures(seconds: 12, jitter: Self.fiveG)
        let (on, off) = (Self.host + 3, Self.host + 6)
        var core = Self.remote()
        let run = Self.play(pictures, core: &core) { $0 >= on && $0 < off }
        // the buffer is deep: jumping straight back to it would freeze the picture for most of its depth
        #expect(core.depth > 0.060)
        let smoothHold = core.depth + core.lead
        let after = run.holds.filter { $0.at >= off }
        let first = try #require(after.first)
        #expect(first.hold < 0.035, "it starts at the interactive depth")
        // the hold rises by at most 100 ms a second from there and reaches the smooth depth; on the way it only falls
        // where the smooth depth itself shrinks below the ramp (by its own rule: 10 ms a second, stepped at arrivals)
        for b in after { #expect(b.hold <= first.hold + 0.100 * (b.at - off) + 1e-6) }
        let back = try #require(after.first { $0.hold >= smoothHold - 0.002 })
        let ramp = after.filter { $0.at <= back.at }
        for (a, b) in zip(ramp, ramp.dropFirst()) { #expect(b.hold >= a.hold - 0.010 * (b.at - a.at) - 0.002) }
        #expect(back.at - off <= (smoothHold - first.hold) / 0.100 + 0.3)
        // no freeze on the way back: pictures keep coming at about the content's pace
        let window = pictures.indices.filter { pictures[$0].arrival >= off && pictures[$0].arrival < off + 1.5 }
        let shown = window.compactMap { run.shown[$0] }.sorted()
        #expect(Double(shown.count) / Double(window.count) > 0.7)
        let gaps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        #expect(try #require(ScreenPlayout<Void>.percentile(gaps, 0.9)) < 0.030)
        #expect(gaps.max()! < 0.120)
    }

    // MARK: The stats line

    @Test func theStatsLineSaysResponsiveAndTheDepth() {
        let r = ScreenPlayoutReport(mode: .latency, bufferMs: 29, touchBufferMs: 21)
        #expect(r.line.hasPrefix("responsive · ") && r.line.contains("buf 29 ms") && r.line.hasSuffix("touch 21 ms"))
        #expect(r.json["mode"] as? String == "latency", "the wire keeps its value")
        #expect(ScreenPlayoutReport(mode: .smooth).line.hasPrefix("smooth · "))
    }

    @Test func theTailIs600ms() {
        #expect(ScreenInteractivity.linger == .milliseconds(600))
    }
}
