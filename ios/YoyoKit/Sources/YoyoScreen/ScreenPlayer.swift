import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore
import YoyoClipboard
import YoyoCore

/// The playout numbers of the last `window` seconds (the stats line and the report to the Mac), from host times
/// (seconds): picture parts arriving, pictures shown, pictures dropped. Gaps longer than `pause` are the content
/// standing still, not hitches: they are left out. A hitch is a shown gap over twice the median one and over
/// `minHitch` (a 60 Hz display showing most pictures a refresh apart would otherwise call every 33 ms gap one). A stall
/// is a gap between two shown live pictures (`macTime`: their `X-Frame-Time`, seconds) that is longer than the gap
/// between their macTimes by 150 / 300 ms or more (`stalls`): the picture froze while the Mac's content moved (a pause of the content
/// is not one). Pure (`ScreenStreamStats` holds one under its lock).
struct ScreenPlayoutMeter {
    var window: Double = 3
    var pause: Double = 0.25
    var minHitch: Double = 0.050
    /// The two stall lengths reported (`stall150PerSec` / `stall300PerSec`).
    static let stalls = (short: 0.150, long: 0.300)
    private var since: Double?
    private var arrivals: [Double] = []
    private var shown: [(at: Double, decodeMs: Double?, macTime: Double?)] = []
    private var drops: [(at: Double, count: Int)] = []

    init(window: Double = 3, pause: Double = 0.25) { self.window = window; self.pause = pause }

    /// Starts over (a new stream).
    mutating func reset(at now: Double) {
        since = now
        arrivals.removeAll(); shown.removeAll(); drops.removeAll()
    }

    mutating func arrived(at t: Double) {
        if since == nil { since = t }
        arrivals.append(t)
        prune(t)
    }

    /// `macTime`: a live picture's `X-Frame-Time` (seconds; nil for refine / keepalive pictures and without one).
    mutating func shown(at t: Double, decodeMs: Double?, macTime: Double? = nil) {
        if since == nil { since = t }
        shown.append((t, decodeMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, macTime.flatMap { $0.isFinite ? $0 : nil }))
        prune(t)
    }

    mutating func dropped(_ count: Int, at t: Double) {
        guard count > 0 else { return }
        drops.append((t, count))
        prune(t)
    }

    /// The window's report; nil when nothing was shown in it. `bufferMs`: the buffer's depth now; `refreshHz` /
    /// `paceMs`: the display's refresh rate and the even pace (nil: unknown / off); `bufferCapMs`: the buffer's cap.
    func report(mode: ScreenPlayoutMode, bufferMs: Double?, refreshHz: Double? = nil, paceMs: Double? = nil,
                bufferCapMs: Double? = nil, at now: Double) -> ScreenPlayoutReport? {
        let from = now - window
        let shownTimes = shown.filter { $0.at > from }
        guard !shownTimes.isEmpty, let since else { return nil }
        let span = max(min(window, now - since), 0.5)
        let gaps = Self.gaps(shownTimes.map(\.at), pause: pause)
        let arrivalGaps = Self.gaps(arrivals.filter { $0 > from }, pause: pause)
        let p50 = ScreenPlayout<Void>.percentile(gaps, 0.5)
        let hitches = p50.map { m in Double(gaps.filter { $0 > max(2 * m, minHitch) }.count) / span }
        let decodes = shownTimes.compactMap(\.decodeMs)
        // shown live pictures in a row: the time shown between them beyond the Mac's
        let live = shownTimes.compactMap { s in s.macTime.map { (at: s.at, mac: $0) } }
        let excess = zip(live, live.dropFirst()).map { a, b in (b.at - a.at) - (b.mac - a.mac) }
        func stalls(_ over: Double) -> Double? {
            live.count < 2 ? nil : Double(excess.filter { $0 >= over - 1e-9 }.count) / span
        }
        return ScreenPlayoutReport(
            mode: mode, fps: Double(shownTimes.count) / span,
            gapP50Ms: p50.map { $0 * 1000 }, gapP90Ms: ScreenPlayout<Void>.percentile(gaps, 0.9).map { $0 * 1000 },
            arrivalGapP50Ms: ScreenPlayout<Void>.percentile(arrivalGaps, 0.5).map { $0 * 1000 },
            arrivalGapP90Ms: ScreenPlayout<Void>.percentile(arrivalGaps, 0.9).map { $0 * 1000 },
            hitchesPerSec: hitches, bufferMs: bufferMs,
            droppedPerSec: Double(drops.filter { $0.at > from }.reduce(0) { $0 + $1.count }) / span,
            decodeMs: decodes.isEmpty ? nil : decodes.reduce(0, +) / Double(decodes.count),
            refreshHz: refreshHz, paceMs: paceMs, bufferCapMs: bufferCapMs,
            stall150PerSec: stalls(Self.stalls.short), stall300PerSec: stalls(Self.stalls.long))
    }

    private static func gaps(_ times: [Double], pause: Double) -> [Double] {
        zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 >= 0 && $0 <= pause }
    }

    private mutating func prune(_ now: Double) {
        let from = now - window
        if let i = arrivals.firstIndex(where: { $0 > from }) { arrivals.removeFirst(i) } else { arrivals.removeAll() }
        if let i = shown.firstIndex(where: { $0.at > from }) { shown.removeFirst(i) } else { shown.removeAll() }
        if let i = drops.firstIndex(where: { $0.at > from }) { drops.removeFirst(i) } else { drops.removeAll() }
    }
}

/// Smooth playback of one stream's video: decoded pictures wait in a `ScreenPlayout` and a CADisplayLink shows each at
/// its time. The link runs on a thread of its own (`ScreenPlayoutThread`; work on the main thread would add jitter)
/// at up to 120 Hz while pictures come, and pauses after `idleAfter` without one. Pictures go to the
/// `ScreenVideoOutput` (whose snapshot is therefore the last one shown); `onShown` is called after each, on the
/// playout thread. After `stop()` nothing more is shown and the waiting pictures are let go. Thread-safe.
final class ScreenPlayer: @unchecked Sendable {
    /// A decoded picture: the pixel buffer, its size in pixels (as the decoder reports it) and its decode time (ms).
    struct Picture: @unchecked Sendable {
        var image: CVPixelBuffer
        var size: CGSize
        var decodeMs: Double
        /// A live picture's `X-Frame-Time` (seconds), set by `push` (the meter's stalls).
        var macTime: Double? = nil
        /// A link picture's frame number (the per-frame trace).
        var frame: UInt32? = nil
    }

    typealias OnShown = @Sendable (CGSize, Double) -> Void

    /// The link pauses after this long without a picture (power).
    static let idleAfter: Double = 1

    private let output: ScreenVideoOutput?
    private let stats: ScreenStreamStats?
    private let onShown: OnShown
    private let lock = NSLock()
    // Guarded by `lock`:
    private var core = ScreenPlayout<Picture>()
    /// The display link's recent refresh periods (their median is the core's `lead`).
    private var periods: [Double] = []
    private var periodsMeasured = false
    private var lastPush: Double = 0
    /// The link runs (or is about to).
    private var running = false
    private var stopped = false
    /// Every picture is shown as it comes, nothing waits (`setShowsOnArrival`).
    private var onArrival = false
    // Only on the playout thread:
    private var link: CADisplayLink?

    /// `evenPace`: show at most one picture every few refreshes, evenly (`ScreenPlayout.evenPace`). `maxDepth`: the
    /// jitter buffer's cap (seconds; nil: the default).
    /// `defaultDepth`: the depth before enough pictures were measured (seconds; nil: the default 25 ms; the LAN, where
    /// arrivals hardly jitter, starts at 10). `touchBudget`: `ScreenPlayout.touchBudget` (nil: shown on arrival while
    /// interactive).
    init(output: ScreenVideoOutput?, stats: ScreenStreamStats?, evenPace: Bool = false, maxDepth: Double? = nil,
         defaultDepth: Double? = nil, touchBudget: Double? = nil, onShown: @escaping OnShown) {
        self.output = output
        self.stats = stats
        self.onShown = onShown
        var config = ScreenPlayout<Picture>.Config()
        if let maxDepth, maxDepth > 0 { config.cap(depth: maxDepth) }
        if let defaultDepth, defaultDepth >= 0 { config.defaultDepth = min(defaultDepth, config.maxDepth) }
        core = ScreenPlayout(config: config)
        core.evenPace = evenPace
        core.touchBudget = touchBudget
    }

    /// The core's state for the stats (under `lock`).
    private var playout: ScreenStreamStats.Playout {
        ScreenStreamStats.Playout(hold: core.hold, refreshHz: periodsMeasured ? 1 / core.lead : nil,
                                  pace: core.paceInterval, cap: core.config.maxDepth, touch: core.touchBuffer,
                                  jitter: core.jitter, base: core.base, smoothDepth: core.depth, lead: core.lead,
                                  syncFloor: core.syncHold)
    }

    /// The A/V sync's extra wait for smooth pictures (`ScreenPlayout.syncFloor`; seconds, 0: none).
    func setSyncFloor(_ floor: Double) {
        let playout = lock.withLock { () -> ScreenStreamStats.Playout? in
            guard !stopped, core.syncFloor != floor else { return nil }
            core.syncFloor = floor
            return self.playout
        }
        if let playout { stats?.playout(playout) }
    }

    /// A decoded picture (on the decoder's queue). `arrival`: when its part was complete (host time).
    func push(_ picture: Picture, macTime: Double?, sample: Bool, arrival: Double) {
        var picture = picture
        picture.macTime = sample ? macTime : nil
        let (placement, dropped, playout, wake) = lock.withLock {
            () -> (ScreenPlayout<Picture>.Placement?, Int, ScreenStreamStats.Playout, Bool) in
            guard !stopped else { return (nil, 0, .init(hold: 0), false) }
            if onArrival {
                lastPush = CACurrentMediaTime()
                return (.now, 0, self.playout, false)
            }
            let before = core.dropped
            let placement = core.push(picture, macTime: macTime, sample: sample, arrival: arrival)
            lastPush = CACurrentMediaTime()
            let wake = placement == .queued && !running
            if wake { running = true }
            return (placement, core.dropped - before, self.playout, wake)
        }
        guard let placement else { return }
        if dropped > 0 { stats?.dropped(dropped, at: arrival) }
        stats?.playout(playout)
        switch placement {
        case .now:
            show(picture, at: CACurrentMediaTime())
        case .queued:
            if wake { ScreenPlayoutThread.shared.perform { [self] in startLink() } }
        }
    }

    /// Every picture is shown as it comes (on: what waits is dropped, the next picture shows at once) or at its time
    /// again (off). For while the app is in the background with the stream still on (Picture in Picture): the display
    /// link doesn't run there, so nothing would wait its turn.
    func setShowsOnArrival(_ on: Bool) {
        lock.withLock {
            guard !stopped, onArrival != on else { return }
            onArrival = on
            if on { core.flush() }
        }
    }

    /// Even pace on or off for the playing stream.
    func setEvenPace(_ on: Bool) {
        lock.withLock { core.evenPace = on }
    }

    /// The touch budget for the playing stream (`ScreenPlayout.touchBudget`), as ack answers update the path's round
    /// trip. Cheap: call it with every answer.
    func setTouchBudget(_ budget: Double?) {
        let playout = lock.withLock { () -> ScreenStreamStats.Playout? in
            guard !stopped, core.touchBudget != budget else { return nil }
            core.touchBudget = budget
            return self.playout
        }
        if let playout { stats?.playout(playout) }
    }

    /// A finger is on the picture or keys are typed (on) / not for a moment (off): pictures wait at most the
    /// interactive depth and what waits catches up at once (`ScreenPlayout.interactive`), and the stats and the playout
    /// report say so (`responsive` / `latency`, `· live`).
    func setInteractive(_ on: Bool) {
        let playout = lock.withLock { () -> ScreenStreamStats.Playout? in
            guard !stopped, core.interactive != on else { return nil }
            core.interactive = on
            return self.playout
        }
        guard let playout else { return }
        stats?.setInteractive(on)
        stats?.playout(playout)
    }

    func stop() {
        lock.withLock {
            stopped = true
            running = false
            core.flush()
        }
        ScreenPlayoutThread.shared.perform { [self] in
            link?.invalidate()
            link = nil
        }
    }

    private func show(_ picture: Picture, at time: Double) {
        output?.show(picture.image)
        stats?.shown(decodeMs: picture.decodeMs, at: time, macTime: picture.macTime)
        if let frame = picture.frame { stats?.traceShown(frame: frame, decodeMs: picture.decodeMs, at: time) }
        onShown(picture.size, picture.decodeMs)
    }

    /// On the playout thread.
    private func startLink() {
        guard !lock.withLock({ stopped }) else { return }
        if link == nil {
            let l = CADisplayLink(target: ScreenPlayerTarget(self), selector: #selector(ScreenPlayerTarget.tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .current, forMode: .default)
            link = l
        }
        link?.isPaused = false
    }

    /// On the playout thread, every refresh while the link runs.
    fileprivate func tick(_ link: CADisplayLink) {
        let target = link.targetTimestamp
        let period = target - link.timestamp
        let now = CACurrentMediaTime()
        let (picture, dropped, idle) = lock.withLock { () -> (Picture?, Int, Bool) in
            guard !stopped else { return (nil, 0, true) }
            if period > 0.004, period < 0.05 {
                periods.append(period)
                if periods.count > 31 { periods.removeFirst() }
                core.lead = ScreenPlayout<Void>.percentile(periods, 0.5) ?? period
                periodsMeasured = true
            }
            let before = core.dropped
            let picture = core.next(target: target)
            let idle = core.queued == 0 && now - lastPush > Self.idleAfter
            if idle { running = false }
            return (picture, core.dropped - before, idle)
        }
        if dropped > 0 { stats?.dropped(dropped, at: now) }
        if let picture { show(picture, at: target) }
        if idle { link.isPaused = true }
    }
}

/// The display link's target: holds the player weakly (a link retains its target until invalidated).
private final class ScreenPlayerTarget: NSObject {
    weak var player: ScreenPlayer?
    init(_ player: ScreenPlayer) { self.player = player }
    @objc func tick(_ link: CADisplayLink) {
        guard let player else { link.invalidate(); return }
        player.tick(link)
    }
}

/// The thread the players' display links run on, with its own run loop: a busy main thread never delays a picture.
/// Made on first use and kept.
final class ScreenPlayoutThread: Thread, @unchecked Sendable {
    static let shared: ScreenPlayoutThread = {
        let t = ScreenPlayoutThread()
        t.name = "ca.sarria.yoyocontrol.screen-playout"
        t.qualityOfService = .userInteractive
        t.start()
        t.started.wait()
        return t
    }()

    private let started = DispatchSemaphore(value: 0)
    /// Set once, before `started` is signalled.
    private var loop: CFRunLoop?

    override func main() {
        loop = CFRunLoopGetCurrent()
        // a port keeps the run loop running while no display link is attached
        RunLoop.current.add(NSMachPort(), forMode: .default)
        started.signal()
        while true { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    /// Runs `block` on this thread.
    func perform(_ block: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
    }
}
