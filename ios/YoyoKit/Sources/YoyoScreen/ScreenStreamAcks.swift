import Foundation
import QuartzCore
import Synchronization
import YoyoClipboard
import YoyoCore

/// Acks of one screen stream (`POST /stream/ack`, docs/PROTOCOL.md「屏幕」): the server keeps at most a
/// couple of pictures unacknowledged in flight and measures the round trip from them, so it never queues up stale
/// pictures in the network. Each picture is acked as it arrives, up to `maxInFlight` acks at once; beyond that only the
/// newest seq is remembered and sent when one returns. (One ack at a time was not enough: a picture arriving while
/// the previous ack was out waited a whole round trip for its own, which the server read as queueing delay and cut
/// the bit rate and resolution for nothing.) A key picture request rides along on the next ack, and so does a playout
/// report (`attach`; one whose ack fails is not sent again).
/// A 404 (no such stream: it is gone) stops acking; other failures are ignored (the next
/// picture's receipt sends again). Thread-safe; the transport is called outside the lock.
final class ScreenAckSender: Sendable {
    enum Outcome: Sendable, Equatable {
        case ok
        /// 404: the server doesn't know the stream (stop acking it).
        case gone
        case failed
    }

    /// Sends one ack and calls back with how it went (on any thread).
    typealias Transport = @Sendable (ScreenStreamAck, @escaping @Sendable (Outcome) -> Void) -> Void

    private struct State {
        var newest: Int?
        /// Highest seq sent (in flight or acked).
        var sent: Int?
        var wantKey = false
        var report: ScreenPlayoutReport?
        var inFlight = 0
        var stopped = false
    }

    /// Acks out at once. They are tiny and share the stream's HTTP/3 connection.
    static let maxInFlight = 4

    let stream: String
    private let transport: Transport
    private let state = Mutex(State())

    init(stream: String, transport: @escaping Transport) {
        self.stream = stream
        self.transport = transport
    }

    /// A whole picture part arrived (before it is decoded).
    func received(seq: Int) {
        state.withLock { s in
            if s.newest.map({ seq > $0 }) ?? true { s.newest = seq }
        }
        pump()
    }

    /// The decoder needs a key picture: asked for with the next ack (right away when none is in flight).
    func requestKeyframe() {
        state.withLock { $0.wantKey = true }
        pump()
    }

    /// A playout report for the Mac: it goes with the next ack (a newer one replaces it while it waits).
    func attach(_ report: ScreenPlayoutReport) {
        state.withLock { $0.report = report }
    }

    /// No more acks (the stream was replaced or closed).
    func stop() { state.withLock { $0.stopped = true } }

    var isStopped: Bool { state.withLock { $0.stopped } }

    private func pump() {
        let ack = state.withLock { s -> ScreenStreamAck? in
            guard !s.stopped, s.inFlight < Self.maxInFlight, let newest = s.newest else { return nil }
            let fresh = s.sent.map { newest > $0 } ?? true
            guard fresh || s.wantKey else { return nil }
            s.inFlight += 1
            if fresh { s.sent = newest }
            let ack = ScreenStreamAck(stream: stream, seq: newest, keyframe: s.wantKey, report: s.report)
            s.wantKey = false
            s.report = nil
            return ack
        }
        guard let ack else { return }
        transport(ack) { [weak self] outcome in self?.finished(ack, outcome) }
    }

    /// After a failed ack, try again this long later: the server holds pictures back until it is acked, so waiting
    /// for the next picture could stall the stream (until the server's 1 s probe).
    static let retryAfter: TimeInterval = 0.1

    private func finished(_ ack: ScreenStreamAck, _ outcome: Outcome) {
        let (again, retry) = state.withLock { s -> (Bool, Bool) in
            s.inFlight -= 1
            switch outcome {
            case .ok:
                return (true, false)
            case .gone:
                s.stopped = true
                return (false, false)
            case .failed:
                // again shortly, not right away (a dead network would spin)
                if ack.keyframe { s.wantKey = true }
                if s.sent == ack.seq { s.sent = ack.seq - 1 }  // resend it even if nothing newer arrives
                return (false, !s.stopped)
            }
        }
        if again { pump() }
        if retry {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.retryAfter) { [weak self] in self?.pump() }
        }
    }
}

/// The stream an ack transport sends on, until emptied (the stream holds the acks: emptying it breaks the cycle).
final class ScreenStreamBox: Sendable {
    private let value = Mutex<(any ScreenStreamConnection)?>(nil)
    init() {}
    var stream: (any ScreenStreamConnection)? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Counters for the stats line (codec, pictures shown per second, bytes received per second, decode time), fed from
/// the stream's and the decoders' queues; `take()` reads and restarts the window. Video pictures also feed a sliding
/// `ScreenPlayoutMeter` (host times: `CACurrentMediaTime()`): the stats line's second line, and the playout report
/// that rides an ack about every `reportEvery` seconds (`takeReport`). The report carries the page's
/// `ScreenNetSampler` (`net`), fed by the page (route, path, input round trips, failed requests) and the stream
/// (bytes); the server's grade from the ack answers (`netQuality`) is the stats line's third line, and its round trip
/// the touch budget's source (`freshRttMin`). While a sound stream is open the report also carries the sound's
/// (`setAudioReport`: `ScreenAudioReport`, asked for only when a report goes).
final class ScreenStreamStats: Sendable {
    struct Snapshot: Sendable, Equatable {
        var codec: String
        var fps: Double
        var kilobytesPerSecond: Double
        /// Average decode time of the window's pictures (nil: none decoded).
        var decodeMs: Double?
        /// The video playout of the last few seconds (nil: no video picture shown).
        var playout: ScreenPlayoutReport? = nil
        /// Smooth playback is interactive right now (a finger on the picture, keys typed).
        var interactive = false
        /// The server's latest grade of this stream's network (nil: none yet).
        var net: ScreenNetQuality? = nil

        /// `h264 · 30 fps · 412 KB/s · 2.1 ms` (`· live` while interactive; numbers and units only: not localized).
        var line: String {
            var parts = [codec, String(format: "%.0f fps", fps), String(format: "%.0f KB/s", kilobytesPerSecond)]
            if let decodeMs { parts.append(String(format: "%.1f ms", decodeMs)) }
            if interactive { parts.append("live") }
            return parts.joined(separator: " · ")
        }
    }

    /// The stream's state now (the stats line, the A/V sync, the latency estimate).
    struct Live: Sendable, Equatable {
        var codec: String?
        var mode: ScreenPlayoutMode
        var interactive: Bool
        var playout: Playout?
        var net: ScreenNetReport?
        var quality: ScreenNetQuality?
        /// Average decode time of the playout window's pictures (nil: none decoded).
        var decodeMs: Double? = nil
    }

    private struct State {
        var codec = ""
        var bytes = 0
        var pictures = 0
        var decodeTotal = 0.0
        var decodes = 0
        var since = ContinuousClock.now
        var mode = ScreenPlayoutMode.latency
        /// Smooth playback is showing pictures at once (ScreenPlayer.setInteractive): reported as `latency`.
        var interactive = false
        var meter = ScreenPlayoutMeter()
        /// The smooth playback's state (nil: none).
        var playout: Playout?
        var reportedAt: Double?
        var net = ScreenNetSampler()
        var quality: ScreenNetQuality?
        /// When `quality` came (host time).
        var qualityAt: Double?
        var audioReport: (@Sendable () -> ScreenAudioReport?)?
        /// A link stream's pictures by frame number, until shown (or old), and the finished ones (`takeFrameTrace`).
        var frames: [UInt32: FrameTrace] = [:]
        var framesDone: [FrameTrace] = []

        func report(at now: Double) -> ScreenPlayoutReport? {
            let shownAs = interactive ? .latency : mode
            var report = meter.report(mode: shownAs, bufferMs: playout.map { $0.hold * 1000 },
                                      refreshHz: playout?.refreshHz, paceMs: playout?.pace.map { $0 * 1000 },
                                      bufferCapMs: playout?.cap.map { $0 * 1000 }, at: now)
            report?.jitterP95Ms = playout?.jitter.map { $0 * 1000 }
            // interactive: the touch buffer's cap (0: on arrival); «Always on arrival» too
            if shownAs == .latency { report?.touchBufferMs = (playout?.touch ?? 0) * 1000 }
            report?.net = net.report(at: now)
            return report
        }
    }
    private let state = Mutex(State())

    /// A playout report goes to the Mac this often.
    static let reportEvery: Double = 2

    /// One link picture on this phone (host times, s; `wallMs`: this phone's clock at arrival, ms since 1970), for the
    /// Mac's trace (docs/LINK.md「逐帧跟踪」).
    struct FrameTrace: Sendable {
        var frame: UInt32
        var kind: String
        var bytes: Int
        var captureMs: Double?
        var arrival: Double
        var wallMs: Double
        var decodedAt: Double?
        var decodeOk: Bool?
        var decodeMs: Double?
        var shownAt: Double?

        var json: [String: Any] {
            func ms(_ t: Double?) -> Any { t.map { (($0 - arrival) * 1e6).rounded() / 1000 } ?? NSNull() }
            var o: [String: Any] = ["frame": Int(frame), "kind": kind, "bytes": bytes,
                                    "arrivalMs": (arrival * 1e6).rounded() / 1000, "wallMs": (wallMs * 1000).rounded() / 1000,
                                    "decodedMs": ms(decodedAt), "shownMs": ms(shownAt),
                                    "decodeMs": decodeMs.map { ($0 * 1000).rounded() / 1000 } ?? NSNull(),
                                    "ok": decodeOk ?? NSNull()]
            if let captureMs { o["captureMs"] = captureMs; o["e2eMs"] = ((wallMs - captureMs) * 1000).rounded() / 1000 }
            return o
        }
    }
    /// A picture not shown this long after it arrived is finished anyway (dropped by the playout, or never decoded).
    static let frameTraceKeep: Double = 2

    init() {}

    func set(codec: String) { state.withLock { $0.codec = codec } }
    func received(bytes: Int, at t: Double = CACurrentMediaTime()) {
        state.withLock { s in
            s.bytes += bytes
            s.net.received(bytes: bytes, at: t)
        }
    }

    /// A new stream, shown in `mode`, going `route`: the playout window starts over, and so do the input round trips
    /// when the route changed and the server's grade.
    func streamStarted(mode: ScreenPlayoutMode, route: ScreenNetReport.Route? = nil, at now: Double) {
        state.withLock { s in
            s.mode = mode
            s.interactive = false
            s.meter.reset(at: now)
            s.playout = nil
            s.reportedAt = now
            s.net.streamStarted(at: now)
            s.net.setRoute(route)
            s.quality = nil
            s.qualityAt = nil
        }
    }

    // MARK: Network (ScreenNetSampler)

    /// The phone's network path changed.
    func netPath(_ path: ScreenNetSampler.Path) { state.withLock { $0.net.path = path } }

    /// The cellular radio changed (kept only while the path is cellular).
    func netRadio(_ radio: ScreenNetReport.Radio?) { state.withLock { $0.net.path?.radio = radio } }

    /// An input was answered after `ms` on `route`.
    func inputAnswered(route: ScreenNetReport.Route, ms: Double, at now: Double = CACurrentMediaTime()) {
        state.withLock { $0.net.inputAnswered(route: route, ms: ms, at: now) }
    }

    /// An input or ack request failed on the way (`ScreenNetSampler.isNetworkFailure`).
    func requestFailed(at now: Double = CACurrentMediaTime()) { state.withLock { $0.net.failed(at: now) } }

    /// The server's grade from an ack answer (`at`: when it came, host time).
    func netQuality(_ q: ScreenNetQuality, at now: Double = CACurrentMediaTime()) {
        state.withLock { s in
            s.quality = q
            s.qualityAt = now
        }
    }

    /// A grade at most this old gives the touch budget its round trip (seconds).
    static let freshQuality: Double = 10

    /// The stream's own ack round trip, min (ms), of the latest grade if it is `freshQuality` old at most.
    func freshRttMin(at now: Double = CACurrentMediaTime()) -> Double? {
        state.withLock { s in
            guard let at = s.qualityAt, now - at <= Self.freshQuality else { return nil }
            return s.quality?.rttMs?.min
        }
    }

    /// The `net` the next report would carry.
    func netReport(at now: Double = CACurrentMediaTime()) -> ScreenNetReport? { state.withLock { $0.net.report(at: now) } }

    /// A whole video picture part arrived (host time).
    func arrived(at t: Double) { state.withLock { $0.meter.arrived(at: t) } }

    /// A whole video picture part arrived at `t` (host time): `live` ones feed the meter.
    func picture(live: Bool, at t: Double) {
        guard live else { return }
        state.withLock { $0.meter.arrived(at: t) }
    }

    /// A picture was shown; `decodeMs`: how long it took to decode; `at`: when (host time); `macTime`: a live
    /// picture's `X-Frame-Time` (seconds: the meter's stalls).
    func shown(decodeMs: Double?, at t: Double? = nil, macTime: Double? = nil) {
        state.withLock { s in
            s.pictures += 1
            if let decodeMs, decodeMs.isFinite, decodeMs >= 0 { s.decodeTotal += decodeMs; s.decodes += 1 }
            if let t { s.meter.shown(at: t, decodeMs: decodeMs, macTime: macTime) }
        }
    }

    /// The stream's state now.
    func live(at now: Double = CACurrentMediaTime()) -> Live {
        state.withLock { s in
            Live(codec: s.codec.isEmpty ? nil : s.codec, mode: s.mode, interactive: s.interactive, playout: s.playout,
                 net: s.net.report(at: now), quality: s.quality,
                 decodeMs: s.meter.report(mode: s.mode, bufferMs: nil, at: now)?.decodeMs)
        }
    }

    /// Decoded pictures that were never shown.
    func dropped(_ count: Int, at t: Double) { state.withLock { $0.meter.dropped(count, at: t) } }

    // MARK: Per-frame trace (link streams)

    /// A link picture arrived (host time).
    func traceArrived(frame: UInt32, kind: String, bytes: Int, captureMs: Double?, at t: Double) {
        let wall = Date().timeIntervalSince1970 * 1000
        state.withLock { s in
            s.frames[frame] = FrameTrace(frame: frame, kind: kind, bytes: bytes, captureMs: captureMs, arrival: t, wallMs: wall)
            if s.frames.count > 600 { Self.finishFrames(&s, before: .infinity) }
        }
    }

    /// The decoder took (or failed on) a link picture.
    func traceDecoded(frame: UInt32, ok: Bool, at t: Double = CACurrentMediaTime()) {
        state.withLock { s in
            s.frames[frame]?.decodedAt = t
            s.frames[frame]?.decodeOk = ok
        }
    }

    /// A link picture was shown (`at`: the refresh it went out with).
    func traceShown(frame: UInt32, decodeMs: Double?, at t: Double) {
        state.withLock { s in
            guard var f = s.frames.removeValue(forKey: frame) else { return }
            f.shownAt = t
            f.decodeMs = decodeMs
            s.framesDone.append(f)
        }
    }

    /// The finished per-frame records since the last call, oldest first (JSON objects).
    func takeFrameTrace(at now: Double) -> [[String: Any]] {
        state.withLock { s in
            Self.finishFrames(&s, before: now - Self.frameTraceKeep)
            defer { s.framesDone = [] }
            return s.framesDone.sorted { $0.arrival < $1.arrival }.map(\.json)
        }
    }

    private static func finishFrames(_ s: inout State, before t: Double) {
        let old = s.frames.values.filter { $0.arrival < t || t == .infinity }
        for f in old { s.frames[f.frame] = nil }
        s.framesDone += old
        if s.framesDone.count > 4000 { s.framesDone.removeFirst(s.framesDone.count - 4000) }
    }

    /// Smooth playback now: how long an on-time picture waits, the display's refresh rate (nil: not measured yet), the
    /// even pace (nil: off), the buffer's cap, the touch buffer's cap in use (nil: not interactive, or shown on
    /// arrival) and the jitter's p95 (nil: not measured yet). Seconds.
    /// For the A/V sync: the playout's base delay, its smooth depth (not the touch hold, not the sync floor), its lead
    /// (one refresh) and the sync floor in use.
    struct Playout: Sendable, Equatable {
        var hold: Double
        var refreshHz: Double? = nil
        var pace: Double? = nil
        var cap: Double? = nil
        var touch: Double? = nil
        var jitter: Double? = nil
        var base: Double? = nil
        var smoothDepth: Double? = nil
        var lead: Double? = nil
        var syncFloor: Double = 0
    }

    func playout(_ p: Playout) { state.withLock { $0.playout = p } }

    /// Smooth playback shows pictures at once (on) or is back to smooth (off).
    func setInteractive(_ on: Bool) { state.withLock { $0.interactive = on } }

    /// The playout report, when one is due (`reportEvery` since the last, and something was shown), with the sound's
    /// (`audioReport`, asked outside the lock) while a sound stream is open.
    func takeReport(at now: Double) -> ScreenPlayoutReport? {
        let (report, audio) = state.withLock { s -> (ScreenPlayoutReport?, (@Sendable () -> ScreenAudioReport?)?) in
            if let at = s.reportedAt, now - at < Self.reportEvery { return (nil, nil) }
            guard let report = s.report(at: now) else { return (nil, nil) }
            s.reportedAt = now
            return (report, s.audioReport)
        }
        guard var report else { return nil }
        report.audio = audio?()
        return report
    }

    /// Where the report's `audio` comes from (nil: no sound stream open).
    func setAudioReport(_ source: (@Sendable () -> ScreenAudioReport?)?) {
        state.withLock { $0.audioReport = source }
    }

    func take(now: ContinuousClock.Instant = .now, host: Double = CACurrentMediaTime()) -> Snapshot {
        state.withLock { s in
            let seconds = max((now - s.since).milliseconds / 1000, 0.001)
            let snap = Snapshot(codec: s.codec.isEmpty ? "-" : s.codec, fps: Double(s.pictures) / seconds,
                                kilobytesPerSecond: Double(s.bytes) / 1024 / seconds,
                                decodeMs: s.decodes > 0 ? s.decodeTotal / Double(s.decodes) : nil,
                                playout: s.report(at: host), interactive: s.interactive, net: s.quality)
            s.bytes = 0; s.pictures = 0; s.decodeTotal = 0; s.decodes = 0; s.since = now
            return snap
        }
    }
}
