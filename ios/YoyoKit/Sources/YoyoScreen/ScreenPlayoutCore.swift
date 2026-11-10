import Foundation
import YoyoClipboard
import YoyoCore

/// The jitter buffer of "Smooth playback" (PROTOCOL.md「客户端的平滑播放」), pure and deterministic: every time is
/// passed in. Host times are seconds of `CACurrentMediaTime()`; `macTime` is the part's `X-Frame-Time` in seconds
/// (since 1970, on the Mac's clock). Acks and decoding don't wait for it; only showing does.
///
/// Each picture's delay = arrival − macTime holds the clock offset plus the network delay. `base` = the smallest delay
/// of the last `window` (it tracks the offset and its drift); the delays above it are the jitter. The depth is their
/// p95 plus `margin`, within 0…`maxDepth`: it grows at once, and shrinks by at most `shrinkPerSecond`; `defaultDepth`
/// until `minSamples` were seen. A picture is due at macTime + base + depth + `lead`, the display's refresh period: a
/// display link's callback comes one refresh before the refresh it draws for, so without it a picture that arrives
/// within the depth could still miss its refresh by one. Each display refresh shows the newest due picture (older ones
/// are dropped); at most `maxQueue` wait. A picture later than any depth could absorb (by more
/// than `maxDepth` + a frame interval) is shown at once and left out of the estimate: a stall would otherwise pin the
/// depth at its cap for seconds without helping. A delay `clockStep` below the base, or that far above it for
/// `clockStepHold`, is a clock step: the estimate starts over. Without a macTime (an older server) a picture is shown
/// at once; `refine` / `keepalive` pictures (their macTime is the original picture's) are due on arrival and not
/// sampled.
///
/// Even pace (`evenPace`, 「均匀节奏」): the Mac publishes at an irregular cadence (gaps of 18 / 31 / 55 ms), which a
/// 60 Hz display turns into one-refresh / two-refresh judder. With it on, a picture is shown at most every `pace`
/// refreshes: the largest n ≥ 1 with n × refresh ≤ content interval + 0.15 × refresh, so the pace is never slower
/// than the content (37 ms at 120 Hz → 4, i.e. 33 ms; 25 ms at 120 Hz → 3; 25 ms at 60 Hz → 1: there a slower pace
/// would drop a picture in four), changed only once a new value has held `paceHold`. (Rounding up instead, a 26-fps
/// source at 120 Hz got a 42 ms pace: 24 a second shown, 2–7 a second dropped.) A pace in use has a band around it
/// (`paceSlower` / `paceFaster`): a slower one needs n × refresh ≤ content interval + (0.15 − `paceSlower`) × refresh,
/// a faster one is taken once the pace is slower than content interval + (0.15 + `paceFaster`) × refresh. Content at
/// ~24 fps sits on the 4 ↔ 5 boundary at 120 Hz (33 ↔ 42 ms), and its interval wobbling across it flipped the pace (a
/// few drops and hitches each time); the band (2 ms there) holds it. The content
/// interval is the mean gap between the window's pictures (gaps over 100 ms, pauses, left out): a 17 / 33 ms
/// alternation is 40 pictures a second, whose median gap (17 ms) would ask for every refresh. A refresh at least
/// half a refresh before the next slot shows nothing; at a slot the newest due picture shows (the ones it passes
/// count as dropped) and the next slot is `pace` refreshes on. With nothing due the slot waits, so motion that
/// resumes after a pause shows at once and the cadence restarts from there. `pace` 1 is the plain behaviour.
///
/// Interactive (`interactive`: a finger on the picture or keys typed, 「操作时自动低延迟」): the depth drops to the
/// interactive depth = min(depth, `touchBudget`, `interactiveCap`, frame interval + `margin`) — about one picture's
/// interval (a picture later than that is overtaken by the next one anyway), enough to even out the small wobble of a
/// path, never the spikes the smooth depth is for. A sampled picture is due at min(macTime + base + that, arrival +
/// that) + lead; one later than that shows on the next refresh, one too late for any depth (a stall) too. Even pace is
/// off. With no `touchBudget` (the LAN), or an
/// interactive depth under `minTouchBudget` (a calm path: nothing to even out), pictures show on arrival. Turned on, it
/// takes effect at once: what waits is re-timed by the interactive rule (or due now, on arrival), so the next refresh
/// shows the newest due picture and the older ones are dropped — the queue catches up in one refresh. Only decoded
/// pictures are dropped: every part is decoded as it comes (later pictures reference earlier ones), only showing is
/// skipped. Turned off, the depth in use starts at the interactive depth and rises to the smooth depth by at most
/// `rampPerSecond` (each picture is held a little longer than the one before, the motion slows by that share: no
/// sudden freeze when the finger lifts).
///
/// A/V sync (`syncFloor`, ScreenAVSync): while watching, smooth pictures wait this much longer for the Mac's sound
/// (Bluetooth's output latency, a deeper sound buffer); the extra wait in use moves to it by at most `rampPerSecond`
/// either way, is 0 at once when interactive starts, and room is made in the queue for the pictures it holds.
struct ScreenPlayout<Picture> {
    struct Config: Sendable {
        var window: Double = 3
        var minSamples = 10
        var defaultDepth: Double = 0.025
        var margin: Double = 0.004
        /// The cap. It only binds on bad paths: elsewhere the depth is
        /// the jitter's p95 + `margin`.
        var maxDepth: Double = 0.100
        var shrinkPerSecond: Double = 0.010
        var percentile: Double = 0.95
        /// Room for `maxDepth` of pictures (4 capped the depth at 67 ms at 60 fps).
        var maxQueue = 12
        var clockStep: Double = 0.5
        var clockStepHold: Double = 1
        /// Even pace: a new number of refreshes per picture must hold this long before it is used.
        var paceHold: Double = 1
        /// Even pace: the band around the pace in use, in refreshes (see above).
        var paceSlower: Double = 0.12
        var paceFaster: Double = 0.12
        /// Back from interactive: how fast the depth in use rises to the smooth depth (seconds per second).
        var rampPerSecond: Double = 0.100
        /// An interactive depth under this shows interactive pictures on arrival (the LAN: nothing to even out).
        var minTouchBudget: Double = 0.008
        /// The interactive depth's ceiling (a 30 fps picture interval; at 60 fps the interval + margin is lower).
        var interactiveCap: Double = 0.030

        /// Another cap: `depth` (seconds), with room in the queue for that much at 60 fps (as 12 is for the default).
        mutating func cap(depth: Double) {
            maxDepth = depth
            maxQueue = Int((depth * 60).rounded(.up)) + 6
        }
    }

    enum Placement: Equatable {
        /// No timing (no macTime): show it now. Pictures that were waiting are dropped.
        case now
        /// Waits for its time (`next(target:)`).
        case queued
    }

    let config: Config
    /// The buffer's depth (seconds).
    private(set) var depth: Double
    /// The smallest recent delay (nil until the first sample).
    private(set) var base: Double?
    /// Pictures dropped (never shown), in all.
    private(set) var dropped = 0
    /// Clock steps seen.
    private(set) var resets = 0
    /// The usual gap between the Mac's pictures (median of the window's, 1/120…1/10 s).
    private(set) var frameInterval: Double = 1.0 / 30
    /// The Mac's pictures per second, as an interval: the mean of the window's gaps up to 100 ms (1/120…1/10 s).
    private(set) var contentInterval: Double = 1.0 / 30
    /// Even pace: refreshes per shown picture (1 = every refresh may show one).
    private(set) var pace = 1
    /// The p95 of the window's delays above the base: what the buffer would need (nil until `minSamples` were seen).
    private(set) var jitter: Double?

    /// Show at most one picture every `pace` refreshes (see above). Turned on mid-stream (the content interval
    /// measured), it takes the pace for the content at once (no hysteresis wait).
    var evenPace = false {
        didSet {
            guard evenPace != oldValue else { return }
            paceCandidate = nil
            nextShowAt = nil
            pace = evenPace && seen >= config.minSamples ? Self.pace(contentInterval: contentInterval, refresh: lead) : 1
        }
    }
    /// The pace that would be used now, and since when it has been (hysteresis).
    private var paceCandidate: (n: Int, since: Double)?
    /// Even pace: the earliest refresh the next picture may show on.
    private var nextShowAt: Double?

    private struct Sample { var arrival: Double; var delay: Double; var macTime: Double }
    private var samples: [Sample] = []
    /// Samples since the estimate (re)started.
    private var seen = 0
    private var depthAt: Double?
    /// Since when delays have been a clock step above the base.
    private var highSince: Double?
    private struct Waiting {
        var picture: Picture
        var due: Double
        /// Sampled pictures only (the interactive rule re-times them).
        var macTime: Double?
        var arrival: Double
    }
    private var queue: [Waiting] = []
    /// Back from interactive: the depth in use (`level`) rises from the interactive depth to `depth`; `at`: when it was
    /// last advanced (nil until the first picture after).
    private var ramp: (level: Double, at: Double?)?

    init(config: Config = Config()) {
        self.config = config
        depth = config.defaultDepth
    }

    /// The display's refresh period (the player sets it from its display link).
    var lead: Double = 1.0 / 120

    /// The A/V sync's extra wait for smooth pictures (seconds, 0…`maxSyncFloor`; see above).
    var syncFloor: Double = 0 {
        didSet { if !(syncFloor >= 0 && syncFloor <= Self.maxSyncFloor) { syncFloor = syncFloor > 0 ? Self.maxSyncFloor : 0 } }
    }
    static var maxSyncFloor: Double { 0.300 }
    /// The sync wait in use, and when it was last advanced.
    private var syncLevel: Double = 0
    private var syncAt: Double?

    /// The sync wait in use now (0 while interactive).
    var syncHold: Double { interactive ? 0 : syncLevel }

    /// The sync wait at `t`, moved towards `syncFloor` by at most `rampPerSecond`.
    private mutating func syncDepth(at t: Double) -> Double {
        let dt = syncAt.map { max(t - $0, 0) } ?? 0
        syncAt = max(t, syncAt ?? t)
        let step = config.rampPerSecond * dt
        syncLevel = syncFloor > syncLevel ? min(syncFloor, syncLevel + step) : max(syncFloor, syncLevel - step)
        return syncLevel
    }

    /// A finger is on the picture or keys are typed (「操作时自动低延迟」): pictures wait at most the interactive depth
    /// (see above), or without one are shown as soon as they come (`.now`; what waited is dropped); even pace is off.
    /// The delays are still sampled, so turned off again the buffer carries on from what it measured (no fresh 25 ms
    /// start; it ramps up from the interactive depth) and even pace from its content interval.
    var interactive = false {
        didSet {
            guard interactive != oldValue else { return }
            // the cadence restarts from the next picture shown
            nextShowAt = nil
            paceCandidate = nil
            if interactive {
                ramp = nil
                syncLevel = 0
                syncAt = nil
                // at once: what waits is due no later than the interactive rule says (on arrival without one), so the
                // next refresh shows the newest due picture and drops the ones before it
                let touch = interactiveDepth
                for i in queue.indices {
                    if let touch, let base, let macTime = queue[i].macTime {
                        queue[i].due = min(queue[i].due, touchDue(macTime: macTime, arrival: queue[i].arrival, base: base,
                                                                  depth: touch))
                    } else {
                        queue[i].due = min(queue[i].due, queue[i].arrival)
                    }
                }
            } else {
                let from = touchDepth
                ramp = from < depth ? (from, nil) : nil
            }
        }
    }

    /// The most an interactive picture waits for its time (seconds; nil: shown on arrival). Set from the path's round
    /// trip (`ScreenTouchBudget`); applies from the next picture.
    var touchBudget: Double?

    /// The interactive depth (see above; nil: shown on arrival — no touch budget, or under `minTouchBudget`).
    var interactiveDepth: Double? {
        guard let touchBudget, touchBudget.isFinite, touchBudget >= config.minTouchBudget else { return nil }
        let d = min(depth, touchBudget, config.interactiveCap, frameInterval + config.margin)
        return d >= config.minTouchBudget ? d : nil
    }

    /// The interactive depth in use now (nil: not interactive, or shown on arrival).
    var touchBuffer: Double? { interactive ? interactiveDepth : nil }

    /// The depth an interactive picture that came on time waits (0: shown on arrival).
    private var touchDepth: Double { interactiveDepth ?? 0 }

    private func touchDue(macTime: Double, arrival: Double, base: Double, depth: Double) -> Double {
        min(macTime + base + depth, arrival + depth) + lead
    }

    /// Even pace: how far apart shown pictures are (nil: off, or interactive).
    var paceInterval: Double? { evenPace && !interactive ? Double(pace) * lead : nil }

    var queued: Int { queue.count }

    /// How long a picture that came on time waits: depth + lead (interactive: the interactive depth + lead, 0 when
    /// shown on arrival; back from it, the ramp's depth + lead).
    var hold: Double {
        if interactive { return interactiveDepth.map { $0 + lead } ?? 0 }
        return min(ramp?.level ?? depth, depth) + syncLevel + lead
    }

    /// The smooth depth in use at `t`: `depth`, or on the ramp back from interactive (advanced to `t`).
    private mutating func smoothDepth(at t: Double) -> Double {
        guard var r = ramp else { return depth }
        if let at = r.at { r.level += config.rampPerSecond * max(t - at, 0) }
        r.at = max(t, r.at ?? t)
        guard r.level < depth else { ramp = nil; return depth }
        ramp = r
        return r.level
    }

    /// A decoded picture. `sample`: false for re-encodes of an unchanged picture (refine / keepalive).
    mutating func push(_ picture: Picture, macTime: Double?, sample: Bool = true, arrival: Double) -> Placement {
        guard let macTime else {
            dropped += queue.count
            queue.removeAll()
            return .now
        }
        if interactive {
            // the estimate keeps learning (the interactive depth follows it)
            let onTime = sample && observe(delay: arrival - macTime, macTime: macTime, arrival: arrival)
            guard let touch = interactiveDepth else {
                // shown now
                dropped += queue.count
                queue.removeAll()
                return .now
            }
            // late, a stall, refine / keepalive: the next refresh
            var due = arrival
            if onTime, let base { due = touchDue(macTime: macTime, arrival: arrival, base: base, depth: touch) }
            return enqueue(picture, due: due, macTime: sample ? macTime : nil, arrival: arrival)
        }
        var due = arrival
        if sample, observe(delay: arrival - macTime, macTime: macTime, arrival: arrival), let base {
            let sync = syncDepth(at: arrival)
            due = min(macTime + base + smoothDepth(at: arrival) + sync, arrival + config.maxDepth + sync) + lead
        }
        return enqueue(picture, due: due, macTime: sample ? macTime : nil, arrival: arrival)
    }

    private mutating func enqueue(_ picture: Picture, due: Double, macTime: Double?, arrival: Double) -> Placement {
        queue.append(Waiting(picture: picture, due: due, macTime: macTime, arrival: arrival))
        // the sync wait holds more pictures
        let limit = config.maxQueue + (interactive ? 0 : Int((syncLevel / max(frameInterval, 1.0 / 120)).rounded(.up)))
        if queue.count > limit {
            queue.removeFirst(queue.count - limit)
            dropped += 1
        }
        return .queued
    }

    /// The picture to show on a display refresh that appears at `target`: the newest one due by then (the older ones
    /// are dropped); nil = keep what's shown.
    mutating func next(target: Double) -> Picture? {
        if evenPace {
            updatePace(at: target)
            if !interactive, pace > 1, let nextShowAt, target < nextShowAt - lead / 2 { return nil }
        }
        guard let i = queue.lastIndex(where: { $0.due <= target }) else { return nil }
        let picture = queue[i].picture
        dropped += i
        queue.removeFirst(i + 1)
        nextShowAt = target + Double(pace) * lead
        return picture
    }

    /// The largest n ≥ 1 with n × refresh ≤ the content interval + 0.15 × refresh: never slower than the content.
    static func pace(contentInterval: Double, refresh: Double) -> Int {
        guard refresh > 0 else { return 1 }
        return max(1, Int(((contentInterval + 0.15 * refresh) / refresh).rounded(.down)))
    }

    /// The pace to move to from `current` (hysteresis): `current` unless the content interval is past the band around
    /// it — slower when n × refresh ≤ content + (0.15 − `slower`) × refresh (a bigger n), faster when the pace is
    /// slower than content + (0.15 + `faster`) × refresh.
    static func pace(contentInterval: Double, refresh: Double, current: Int, slower: Double = 0.12,
                     faster: Double = 0.12) -> Int {
        guard refresh > 0 else { return 1 }
        let lenient = pace(contentInterval: contentInterval + faster * refresh, refresh: refresh)
        if lenient < current { return lenient }
        let strict = pace(contentInterval: contentInterval - slower * refresh, refresh: refresh)
        if strict > current { return strict }
        return current
    }

    private mutating func updatePace(at now: Double) {
        let n = Self.pace(contentInterval: contentInterval, refresh: lead, current: pace,
                          slower: config.paceSlower, faster: config.paceFaster)
        guard n != pace else { paceCandidate = nil; return }
        if let c = paceCandidate, c.n == n {
            if now - c.since >= config.paceHold { pace = n; paceCandidate = nil }
        } else {
            paceCandidate = (n, now)
        }
    }

    /// Drops what waits (the stream ended); not counted as dropped.
    mutating func flush() { queue.removeAll() }

    /// Takes one delay into the estimate; false = this picture is too late for any depth (show it on arrival).
    private mutating func observe(delay: Double, macTime: Double, arrival: Double) -> Bool {
        if let base {
            if delay < base - config.clockStep {
                restart()
            } else if delay > base + config.clockStep || delay - base - depth > config.maxDepth + frameInterval {
                // too late for any depth: a stall (left out) — or, held this long, a clock step or a slower path
                let since = highSince ?? arrival
                highSince = since
                guard arrival - since >= config.clockStepHold else { return false }
                restart()
            } else {
                highSince = nil
            }
        }
        samples.append(Sample(arrival: arrival, delay: delay, macTime: macTime))
        seen += 1
        while samples.count > config.minSamples, let first = samples.first, arrival - first.arrival > config.window {
            samples.removeFirst()
        }
        let base = samples.map(\.delay).min() ?? delay
        self.base = base
        var gaps: [Double] = []
        for (a, b) in zip(samples, samples.dropFirst()) where b.macTime > a.macTime { gaps.append(b.macTime - a.macTime) }
        if let median = Self.percentile(gaps, 0.5) { frameInterval = min(max(median, 1.0 / 120), 0.1) }
        let moving = gaps.filter { $0 <= 0.1 }
        if !moving.isEmpty { contentInterval = min(max(moving.reduce(0, +) / Double(moving.count), 1.0 / 120), 0.1) }

        guard seen >= config.minSamples else {
            depth = config.defaultDepth
            depthAt = arrival
            return true
        }
        let jitter = Self.percentile(samples.map { $0.delay - base }, config.percentile) ?? 0
        self.jitter = jitter
        let target = min(max(jitter + config.margin, 0), config.maxDepth)
        if target >= depth {
            depth = target
        } else {
            let elapsed = max(arrival - (depthAt ?? arrival), 0)
            depth = max(target, depth - config.shrinkPerSecond * elapsed)
        }
        depthAt = arrival
        return true
    }

    /// A clock step: the estimate starts over (what waits stays; the newest due one still wins).
    private mutating func restart() {
        samples.removeAll()
        seen = 0
        base = nil
        depth = config.defaultDepth
        depthAt = nil
        highSince = nil
        jitter = nil
        ramp = nil
        resets += 1
    }

    /// Nearest-rank percentile (`p` in 0…1); nil for no values.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

/// The automatic touch budget (`ScreenPlayout.touchBudget`, one bound of the interactive depth): a quarter of the
/// path's minimum round trip, at most 45 ms (from the latest ack answer's `net.rttMs.min`,
/// `ScreenStreamStats.freshRttMin`); without one, none on a LAN and 30 ms on a remote path. Under 8 ms it is none: the
/// LAN keeps showing on arrival.
enum ScreenTouchBudget {
    static let share = 0.25
    static let cap = 0.045
    static let remoteDefault = 0.030
    static let minimum = 0.008

    /// Seconds (nil: show on arrival). `rttMinMs`: the stream's minimum ack round trip (ms; nil: none known).
    static func auto(rttMinMs: Double?, onLan: Bool) -> Double? {
        let budget: Double
        if let rttMinMs, rttMinMs.isFinite, rttMinMs >= 0 {
            budget = min(share * rttMinMs / 1000, cap)
        } else {
            guard !onLan else { return nil }
            budget = remoteDefault
        }
        return budget < minimum ? nil : budget
    }
}
