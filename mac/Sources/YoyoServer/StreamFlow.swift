#if os(macOS)
import Foundation

// Flow control + latency-first adaptation for the screen video streams (docs/PROTOCOL.md 「屏幕」「视频流、确认与客户端指针」).
// The client POSTs cumulative acks (`/stream/ack`: "I have every part up to seq"); the server keeps at most W picture
// parts un-acked, measures RTT on its own clock (part written → its covering ack) and steers the video bit rate /
// resolution by the queueing delay — the lowest RTT of the last second − the min RTT over 10 s: jitter is spikes and
// doesn't lift a window's minimum, a real queue lifts every sample. Stability beats frame rate beats latency beats
// sharpness.
//
// Every number is in `StreamTuning` (static defaults, injectable in tests). `StreamFlowController` is a
// pure value type: every decision is a function of the calls made on it with their own timestamps (any monotonic
// clock, seconds), so it is unit-tested with a fake clock. `StreamFlow` wraps one in a lock for a live stream (acks
// arrive on HTTP threads, the stream loop reads it) and `StreamFlowRegistry` finds it by the client's stream id.

/// Codec negotiation for `/stream?codecs=…`: h264 / hevc.
public enum StreamCodecs {
    /// The video codecs this server allows: YOYO_VIDEO_CODECS (comma list of h264 / hevc), default both (also when
    /// the list names neither). A whitelist only — its order means nothing; the client's order decides (`choose`).
    static func serverAllowed(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Set<VideoCodec> {
        guard let raw = env["YOYO_VIDEO_CODECS"] else { return [.h264, .hevc] }
        let listed = Set(raw.split(separator: ",").compactMap { VideoCodec(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) })
        return listed.isEmpty ? [.h264, .hevc] : listed
    }

    /// The client's list: known tokens (hevc, h264) in its order; unknown ones dropped.
    static func parse(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var out: [String] = []
        for token in raw.split(separator: ",") {
            let t = token.trimmingCharacters(in: .whitespaces).lowercased()
            if ["hevc", "h264"].contains(t), !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// The stream's codec. The client's order decides: walking its list, the first video codec the server allows and
    /// this Mac can encode (`VideoEncoder.isAvailable`: its low-latency hardware session). When nothing on the list fits
    /// (or there is no list): h264, else hevc, whichever is allowed and available. 503 when no video codec can be
    /// encoded at all.
    static func choose(client: [String], allowed: Set<VideoCodec> = serverAllowed(),
                       available: (VideoCodec) -> Bool = VideoEncoder.isAvailable) throws -> VideoCodec {
        for codec in client.compactMap(VideoCodec.init(rawValue:)) + [.h264, .hevc]
        where allowed.contains(codec) && available(codec) {
            return codec
        }
        throw HTTPError(503, "this Mac can't encode h264 or hevc video (VideoToolbox)")
    }
}

/// Every number the video streams run by: the ack window, the bit-rate / resolution adaptation, and the stream loop's
/// timers. One value with static defaults (`StreamTuning.default`, all measured — docs/PROTOCOL.md 「屏幕」 says why
/// each is what it is); tests inject their own. The only environment switch left is
/// YOYO_VIDEO_MAX_KBPS (`fromEnvironment`, an operational ceiling): an env var is never a tuning constant.
struct StreamTuning: Sendable {
    // MARK: ack window
    /// Picture parts sent but not yet acked: at least `videoWindow`, growing with the path's high RTT (`windowRTTPercentile`
    /// of the last `minRTTWindow`) to cover two RTTs of pictures at the stream's frame rate
    /// (`StreamFlowController.window`), up to `maxVideoWindow`: a fixed 4 capped the rate at 4 / RTT — 21 pictures/s over
    /// a 140 ms phone path. Its parts are a few KB, and queueing is held down by the queue-delay bit-rate control, not by
    /// the window.
    var videoWindow = 4
    var maxVideoWindow = 24
    /// The RTT the window covers: this percentile of the last `minRTTWindow`'s samples. With the min RTT a 5G path
    /// (min 80 ms, p90 170 ms, spikes to 440 ms) got 12 and held pictures back 6–9 times every 10 s of motion.
    var windowRTTPercentile = 0.9
    /// Window full and no ack for this long: one probe picture goes out anyway.
    var probeAfter: TimeInterval = 1
    /// Acks had started, but none for this long while pictures are outstanding: drop the window.
    var disableAfter: TimeInterval = 3
    /// A dropped window comes back when acks flow again: an ack for a picture sent at most this long ago (a stale
    /// ack that was stuck somewhere doesn't count), at most `maxReenables` times per stream (acks that keep
    /// stalling would otherwise cost a stall each time).
    var reenableWithin: TimeInterval = 1
    var maxReenables = 5
    /// Key frames on request at most this often.
    var keyMinInterval: TimeInterval = 0.5
    /// Un-acked pictures remembered before acks start (for the first RTT sample); older ones are forgotten.
    var maxTracked = 64

    // MARK: adaptation
    /// Min RTT is the minimum over this long.
    var minRTTWindow: TimeInterval = 10
    /// srtt EWMA gain per sample (the RTT shown in stats; it steers nothing).
    var srttGain = 0.125
    /// The queue delay is the lowest RTT of this long − min RTT …
    var qdWindow: TimeInterval = 1
    /// … judged only with at least this many samples in it (fewer: no decision, the last one stands).
    var qdMinSamples = 3
    /// Queue delay above this, sustained `congestedHold`, is congestion: step down.
    var congestedDelay: TimeInterval = 0.050
    var congestedHold: TimeInterval = 0.500
    /// Queue delay below this is clean: the bit rate climbs back to the start rate every `increaseInterval`; past it
    /// after `climbHold` clean, a step per `climbInterval` while the stream uses its target.
    var cleanDelay: TimeInterval = 0.025
    var increaseInterval: TimeInterval = 0.5
    /// Clean this long before climbing past the start rate.
    var climbHold: TimeInterval = 2
    /// A congestion step down remembers `ceilingFactor` × the rate before it as a ceiling no step up passes for
    /// `ceilingHold` (another hit renews it), so a path that carries 3000 settles at 2700–3000 instead of hitting the
    /// queue every few seconds.
    var ceilingHold: TimeInterval = 30
    var ceilingFactor = 0.9
    /// On a cellular client (`StreamNetProfile` `cellular`) the ceiling holds `cellularCeilingHold`, and climbs past the
    /// start rate are ×`cellularIncreaseFactor` at most every `cellularClimbEvery`: a 5G path that carried 6–10 Mbps
    /// steadily was climbed ×1.1 a second into 15–20 Mbps whenever the 30 s ceiling ran out, 10 steps down in 3 min,
    /// each one a queue that took the RTT from 90 to 200–330 ms (and the phone's touch playout to 3–5 hitches a second).
    var cellularCeilingHold: TimeInterval = 120
    var cellularIncreaseFactor = 1.05
    var cellularClimbEvery: TimeInterval = 2
    /// A climb past the start rate needs the stream to have sent at least this share of the target over the last
    /// `utilizationWindow` (0 = off). A target the encoder doesn't use proves nothing about the path, and a static
    /// desktop would otherwise drift up to the maximum and queue the moment something moves. Only counted when the
    /// stream reports part sizes. A full window is no evidence either: on a 5G path RTT spikes over ~270 ms fill the
    /// 16-picture window while it sends 0.4–3 Mbps, and counting that as room to climb took the rate 3500 → 12000
    /// kbps, so the path queued the moment the content used it.
    var climbUtilization = 0.8
    var utilizationWindow: TimeInterval = 2
    /// Steps past the start rate at most this often — a step is judged by a full `qdWindow` of samples before the next.
    var climbInterval: TimeInterval { max(increaseInterval, qdWindow) }
    var decreaseFactor = 0.85
    var increaseFactor = 1.1
    /// Below the start rate the climb back is faster (a dip from a burst shouldn't take 10 s to undo).
    var recoverFactor = 1.25
    /// A key frame is a burst (tens of KB, vs a few for a delta): its RTT inflation is not congestion, so no
    /// step down for this long after one.
    var keyGrace: TimeInterval = 1.5
    /// Video bit rate (kbit/s): start, floor, ceiling (YOYO_VIDEO_MAX_KBPS).
    var startKbps = 3500
    var minKbps = 300
    var maxKbps = 20000
    /// The ceiling on a cellular client (`report.net.iface`; nil = the max, as on Wi-Fi: the screen is the owner's,
    /// data is not rationed, and the delay-based steps keep the queue short) and on a constrained path (Low Data
    /// Mode, the phone's own setting): `StreamNetProfile`.
    var cellularMaxKbps: Int? = nil
    var constrainedMaxKbps = 2500
    /// No congestion step down while the stream sends less than this share of its target over `utilizationWindow`
    /// and its window was not full lately (0 = off): the queue is then not this stream's, and a lower target only
    /// makes the next motion blurry. A still 5G screen sending 39 kbit/s was cut 3500 → 300 in 23 s by RTT spikes
    /// and the user's first 20 s of scrolling afterwards went out at 300–900 kbit/s.
    var holdBelowUtilization = 0.5
    /// The stream's `maxKbps` parameter (testing only), already applied to `startKbps` / `maxKbps`
    /// (`limited(toKbps:)`); kept to name the profile.
    var requestMaxKbps: Int?
    /// Resolution steps back up only after this long without congestion.
    var resolutionUpHold: TimeInterval = 6

    // MARK: the stream loop
    /// Highest frame rate a stream is served at (only changes are encoded, so a high cap costs little).
    var maxFPS = 60
    /// An unchanged picture is re-encoded this often (a tiny delta) so proxies keep the connection.
    var keepalive: TimeInterval = 5
    /// A still picture's sharper re-encodes (`refine`, `RefineSchedule`): the first `refineIdle` after its last live
    /// picture, then one every `refineEvery` while it stays unchanged, until `refineSmallInARow` in a row came out no
    /// bigger than one live picture's budget (the target rate / 8 / fps bytes): the encoder has nothing left to add at
    /// this rate. At most `videoRefines` (skipped ones included). New content re-arms them. (Two refines left text
    /// blurry after a scroll: with x264's per-picture budget each refine adds about one picture's worth, so at 1 Mbit/s
    /// the picture needs about ten and at 3.5 Mbit/s about six; VideoToolbox settles in 2–7 above 600 kbit/s and uses
    /// all 20 at 300 kbit/s.)
    var refineIdle: TimeInterval = 0.3
    var refineEvery: TimeInterval = 0.1
    var videoRefines = 20
    var refineSmallInARow = 2
    /// A refine's temporary bit rate (`refineBitrate`): twice the target, at least this (bits/s), never past the
    /// profile's ceiling; none while the path is queueing.
    var refineMinBitrate = 4_000_000
    /// Cursor parts at most this often (coalesced).
    var cursorMinInterval: TimeInterval = 1.0 / 60
    /// Consecutive encode failures before the stream ends (the client reopens).
    var maxEncodeFailures = 3
    /// The loop re-checks for a hung-up client at least this often.
    var idleCheck: TimeInterval = 0.25

    static let `default` = StreamTuning()

    /// The defaults with YOYO_VIDEO_MAX_KBPS (100…100000) as the ceiling, if set (the start and floor follow it down).
    static func fromEnvironment(_ env: [String: String]) -> StreamTuning {
        var t = StreamTuning.default
        if let k = env["YOYO_VIDEO_MAX_KBPS"].flatMap(Int.init) { t.maxKbps = min(max(k, 100), 100_000) }
        t.minKbps = min(t.minKbps, t.maxKbps)
        t.startKbps = min(max(t.startKbps, t.minKbps), t.maxKbps)
        return t
    }

    /// The encoder's bit rate (bits/s) for a refine of a stream at `normal`: twice that, at least `refineMinBitrate`,
    /// never past `ceiling`; `normal` itself while the path is queueing. A link stream (`linkFPS`: its frame rate) also
    /// gets no more than normal × fps × `refineEvery`: refines one every `refineEvery` then add up to at most the rate
    /// the link's media layer set (a refine's size is about the encoder's per-picture budget, rate / fps).
    func refineBitrate(normal: Int, ceiling: Int, congested: Bool, linkFPS: Double? = nil) -> Int {
        guard !congested else { return normal }
        var b = min(ceiling, max(normal * 2, refineMinBitrate))
        if let fps = linkFPS { b = min(b, Int(Double(normal) * fps * refineEvery)) }
        return max(normal, b)
    }

    /// What live streams use.
    static let current = StreamTuning.fromEnvironment(ProcessInfo.processInfo.environment)

    /// This tuning for a stream that asked for `maxKbps` (nil: as is): its ceiling is min(max, maxKbps), its start
    /// min(start, maxKbps).
    func limited(toKbps kbps: Int?) -> StreamTuning {
        guard let kbps else { return self }
        var t = self
        t.requestMaxKbps = kbps
        t.maxKbps = min(t.maxKbps, kbps)
        t.minKbps = min(t.minKbps, t.maxKbps)
        t.startKbps = min(max(t.startKbps, t.minKbps), t.maxKbps)
        return t
    }
}

/// A video stream's bit-rate ceiling from the client's network (its latest fresh `report.net`): a constrained path
/// (Low Data Mode) → `constrainedMaxKbps`; else a cellular interface → `cellularMaxKbps` (on 5G a 12000 target queued
/// the path whenever the content used it; the picture barely gets sharper between 4 and 16 Mbps); else (Wi-Fi, wired,
/// other, no report) the tuning's max. The stream's `maxKbps` parameter (testing only) replaces the profile: the
/// ceiling is then min(max, maxKbps) on any network (12000 can be tried on 5G), and the profile is `test`.
struct StreamNetProfile: Sendable, Equatable {
    /// "wifi" (anything else), "cellular", "constrained" or "test".
    var name: String
    var maxKbps: Int

    static func choose(client: StreamNetReport?, tuning t: StreamTuning) -> StreamNetProfile {
        if t.requestMaxKbps != nil { return StreamNetProfile(name: "test", maxKbps: t.maxKbps) }
        let base: (name: String, kbps: Int?) = client?.constrained == true ? ("constrained", t.constrainedMaxKbps)
            : client?.iface == "cellular" ? ("cellular", t.cellularMaxKbps ?? t.maxKbps) : ("wifi", nil)
        return StreamNetProfile(name: base.name, maxKbps: max(t.minKbps, min(base.kbps ?? t.maxKbps, t.maxKbps)))
    }
}

/// What the controller wants the stream to change.
enum StreamFlowAction: Equatable, Sendable {
    /// The new target bit rate (kbit/s).
    case bitrate(Int)
    /// The new resolution step (index into the widths, 0 = best); needs a new key frame.
    case resolution(Int)
}

/// Whether a picture may go out now.
enum StreamFlowGate: Equatable, Sendable {
    case open
    /// The window is full but acks stalled: one picture goes out anyway.
    case probe
    /// The window is full: wait for an ack (or until the probe is due at `until`).
    case full(until: TimeInterval)
}

struct StreamFlowController: Sendable {
    let tuning: StreamTuning
    /// Video widths, best first (e.g. 2304, 1792, 1280, 1024; capped by the client's maxWidth). [0]: one fixed size.
    let widths: [Int]

    private(set) var bitrateKbps: Int
    private(set) var resolutionIndex = 0
    private(set) var acksStarted = false
    private(set) var disabled = false
    /// Times the window came back after being dropped.
    private(set) var reenables = 0

    private var outstanding: [(seq: UInt64, sentAt: TimeInterval)] = []
    private(set) var lastAckSeq: UInt64 = 0
    /// The newest picture part recorded (`pictureSent`: after its write).
    private(set) var lastSentSeq: UInt64 = 0
    private var lastAckAt: TimeInterval?
    private var lastPictureAt: TimeInterval?
    private(set) var srtt: TimeInterval?
    private(set) var latestRTT: TimeInterval?
    private var rttSamples: [(at: TimeInterval, rtt: TimeInterval)] = []
    private var congestedSince: TimeInterval?
    private var cleanSince: TimeInterval?
    private var lastIncreaseAt: TimeInterval?
    private var lastDecreaseAt: TimeInterval?
    private var lastResolutionChangeAt: TimeInterval?
    /// The remembered ceiling and until when it holds.
    private var ceiling: (kbps: Int, until: TimeInterval)?
    /// The network profile's ceiling in force (`apply(_:)`); nil = the tuning's max.
    private(set) var profile: StreamNetProfile?
    /// Part sizes sent lately (the climb's utilization check); nil until the stream reports one.
    private var sentBytes: [(at: TimeInterval, bytes: Int)]?
    /// When the newest RTT sample came.
    private var lastSampleAt: TimeInterval?
    // Key frames.
    private var keyPending = false
    private var lastKeyAt: TimeInterval?

    // Counters (stats).
    private(set) var windowLimitedCount = 0
    /// When the window last held a picture back.
    private var lastWindowLimitedAt: TimeInterval?
    /// Congestion step downs skipped because the stream was content-limited (stats).
    private(set) var heldSteps = 0
    private(set) var probes = 0
    private(set) var keyRequests = 0
    private(set) var decreases = 0
    private(set) var increases = 0
    /// Bit rate steps up that went past the start rate.
    private(set) var climbs = 0
    private(set) var acks = 0

    /// The stream's minimum interval between pictures (1 / fps); nil = unknown (the window stays at its base).
    let frameInterval: TimeInterval?

    init(tuning: StreamTuning = .default, widths: [Int] = [], frameInterval: TimeInterval? = nil) {
        self.tuning = tuning
        self.widths = widths.isEmpty ? [0] : widths
        self.frameInterval = frameInterval
        bitrateKbps = tuning.startKbps
    }

    /// Pictures allowed in flight: enough to cover twice the path's high RTT (`windowRTT`) at the frame rate (plus two),
    /// within `videoWindow`…`maxVideoWindow`. One min RTT was not enough: real round trips run above the minimum, acks
    /// go out a few at a time and pictures come in bursts — over a 130 ms path a window of 9 held pictures back hundreds
    /// of times a minute and caused most of the hitches the phone saw; 16 caused none. Twice the min RTT was not enough
    /// on 5G either, whose round trips run at twice the minimum and more (the tuning's `windowRTTPercentile`).
    var window: Int {
        guard let rtt = windowRTT, let interval = frameInterval, interval > 0 else { return tuning.videoWindow }
        let cover = Int((2 * rtt / interval).rounded(.up)) + 2
        return min(max(tuning.videoWindow, cover), max(tuning.videoWindow, tuning.maxVideoWindow))
    }

    /// The window is in force (acks started, not dropped).
    var active: Bool { acksStarted && !disabled }
    var inFlight: Int { outstanding.count }
    var width: Int { widths[min(resolutionIndex, widths.count - 1)] }

    /// The lowest RTT over the last `minRTTWindow`.
    var minRTT: TimeInterval? { rttSamples.map(\.rtt).min() }
    /// The RTT the window covers: the `windowRTTPercentile` of the last `minRTTWindow` (nearest rank).
    var windowRTT: TimeInterval? {
        guard !rttSamples.isEmpty else { return nil }
        let s = rttSamples.map(\.rtt).sorted()
        let rank = Int((Double(s.count) * tuning.windowRTTPercentile).rounded(.up)) - 1
        return s[min(max(rank, 0), s.count - 1)]
    }
    /// The RTT samples of the last `window` (at most `minRTTWindow`) up to `now`, summarized (ms); nil without any.
    func rttSummary(at now: TimeInterval, window: TimeInterval) -> StreamRTTSummary? {
        StreamRTTSummary(ms: rttSamples.filter { now - $0.at <= window }.map { $0.rtt * 1000 })
    }
    /// The queue delay the adaptation goes by: the lowest RTT of the last `qdWindow` (up to the newest sample) − min
    /// RTT; nil with fewer than `qdMinSamples` samples in that window.
    var queueDelayMin: TimeInterval? {
        guard let last = lastSampleAt, let m = minRTT else { return nil }
        var n = 0
        var low = TimeInterval.infinity
        for s in rttSamples.reversed() {
            guard last - s.at <= tuning.qdWindow else { break }
            n += 1
            low = Swift.min(low, s.rtt)
        }
        guard n >= Swift.max(1, tuning.qdMinSamples) else { return nil }
        return Swift.max(0, low - m)
    }
    /// The remembered ceiling (kbit/s) if it still holds at `now`.
    func ceilingKbps(at now: TimeInterval) -> Int? {
        guard let c = ceiling, now < c.until else { return nil }
        return c.kbps
    }
    /// The remembered ceiling as of the newest RTT sample (stats).
    var ceilingKbps: Int? { lastSampleAt.flatMap { ceilingKbps(at: $0) } }
    /// The highest bit rate allowed now: the tuning's max, under the network profile's.
    var maxKbpsNow: Int { min(tuning.maxKbps, profile?.maxKbps ?? .max) }
    /// The client is on a cellular network (the `cellular` profile): slower climbs, a longer-held ceiling.
    var onCellular: Bool { profile?.name == "cellular" }

    /// A (new) network profile: a ceiling under the current rate steps it down at once; a higher one only lets later
    /// climbs go further.
    mutating func apply(_ p: StreamNetProfile) -> [StreamFlowAction] {
        profile = p
        guard bitrateKbps > maxKbpsNow else { return [] }
        bitrateKbps = maxKbpsNow
        return [.bitrate(bitrateKbps)]
    }
    /// What the stream sent over the last `utilizationWindow` up to `now` (kbit/s); nil when it doesn't report sizes.
    func sentKbps(at now: TimeInterval) -> Double? {
        guard let sent = sentBytes else { return nil }
        let bytes = sent.reduce(0) { now - $1.at <= tuning.utilizationWindow ? $0 + $1.bytes : $0 }
        return Double(bytes) * 8 / 1000 / tuning.utilizationWindow
    }

    // MARK: window

    /// A picture part (of `bytes`, if known) finished writing at `at`.
    mutating func pictureSent(seq: UInt64, at now: TimeInterval, bytes: Int? = nil) {
        lastPictureAt = now
        lastSentSeq = max(lastSentSeq, seq)
        if let bytes {
            var sent = sentBytes ?? []
            sentBytes = nil
            sent.append((now, bytes))
            if let first = sent.first, now - first.at > tuning.utilizationWindow {
                sent.removeAll { now - $0.at > tuning.utilizationWindow }
            }
            sentBytes = sent
        }
        outstanding.append((seq, now))
        // before acks start, and while the window is dropped (for an ack that brings it back), only the newest count
        if !acksStarted || disabled, outstanding.count > tuning.maxTracked {
            outstanding.removeFirst(outstanding.count - tuning.maxTracked)
        }
    }

    /// Whether a picture may be sent at `now`. Drops the window first if acks stalled (`disabled` turns true).
    mutating func gate(at now: TimeInterval) -> StreamFlowGate {
        checkStall(at: now)
        guard active, outstanding.count >= window else { return .open }
        let since = max(lastAckAt ?? -.infinity, lastPictureAt ?? -.infinity)
        if now - since >= tuning.probeAfter { return .probe }
        return .full(until: since + tuning.probeAfter)
    }

    /// The stream wanted to send a picture but the window was full (stats only: a full window is no reason to climb).
    mutating func noteWindowLimited(at now: TimeInterval? = nil) {
        windowLimitedCount += 1
        if let now { lastWindowLimitedAt = now }
    }

    /// The stream sends well under its target because the content needs no more (not because the window held it
    /// back): a queue on the path then is not its own (`holdBelowUtilization`).
    func contentLimited(at now: TimeInterval) -> Bool {
        guard tuning.holdBelowUtilization > 0, let sent = sentKbps(at: now),
              sent < tuning.holdBelowUtilization * Double(bitrateKbps) else { return false }
        return lastWindowLimitedAt.map { now - $0 > tuning.utilizationWindow } ?? true
    }

    mutating func noteProbe() { probes += 1 }

    /// When the next stall check could change something (for the loop's wait), or nil.
    func stallDeadline() -> TimeInterval? {
        guard active, let first = outstanding.first else { return nil }
        return max(lastAckAt ?? -.infinity, first.sentAt) + tuning.disableAfter
    }

    /// Acks had started but none came for `disableAfter` while pictures are outstanding: run as without acks.
    /// Returns true when it just dropped the window.
    @discardableResult
    mutating func checkStall(at now: TimeInterval) -> Bool {
        guard active, let deadline = stallDeadline(), now >= deadline else { return false }
        disabled = true
        outstanding.removeAll()
        return true
    }

    // MARK: acks

    /// A cumulative ack for `seq` (and maybe a key request) arrived at `now`. Returns what to change.
    mutating func ack(seq: UInt64, keyframe: Bool = false, at now: TimeInterval) -> [StreamFlowAction] {
        if keyframe { requestKey(at: now) }
        if disabled {
            var newest: (seq: UInt64, sentAt: TimeInterval)?
            while let first = outstanding.first, first.seq <= seq {
                newest = first
                outstanding.removeFirst()
            }
            guard reenables < tuning.maxReenables, let newest, now - newest.sentAt <= tuning.reenableWithin else { return [] }
            disabled = false
            reenables += 1
            lastAckAt = now
            lastAckSeq = max(lastAckSeq, seq)
            acks += 1
            return rttSample(max(0, now - newest.sentAt), at: now)
        }
        acks += 1
        acksStarted = true
        lastAckAt = now
        guard seq > lastAckSeq else { return [] }
        lastAckSeq = seq
        var newest: (seq: UInt64, sentAt: TimeInterval)?
        while let first = outstanding.first, first.seq <= seq {
            newest = first
            outstanding.removeFirst()
        }
        guard let newest else { return [] }
        return rttSample(max(0, now - newest.sentAt), at: now)
    }

    /// One RTT sample: update srtt / min RTT, then adapt.
    mutating func rttSample(_ rtt: TimeInterval, at now: TimeInterval) -> [StreamFlowAction] {
        latestRTT = rtt
        srtt = srtt.map { $0 + tuning.srttGain * (rtt - $0) } ?? rtt
        rttSamples.append((now, rtt))
        rttSamples.removeAll { now - $0.at > tuning.minRTTWindow }
        lastSampleAt = now
        // too few samples in the window: no judgement, the last one stands
        guard let qd = queueDelayMin else { return [] }

        if qd > tuning.congestedDelay {
            cleanSince = nil
            if let k = lastKeyAt, now - k < tuning.keyGrace { congestedSince = nil; return [] }
            let since = congestedSince ?? now
            congestedSince = since
            guard now - since >= tuning.congestedHold else { return [] }
            congestedSince = now  // the next step needs another sustained stretch
            if contentLimited(at: now) { heldSteps += 1; return [] }
            return decrease(at: now)
        }
        congestedSince = nil
        guard qd < tuning.cleanDelay else { cleanSince = nil; return [] }
        let clean = cleanSince ?? now
        cleanSince = clean
        var out: [StreamFlowAction] = []
        if let kbps = increase(cleanSince: clean, at: now) { out.append(.bitrate(kbps)) }
        if resolutionIndex > 0, now - clean >= tuning.resolutionUpHold,
           now - (lastResolutionChangeAt ?? -.infinity) >= tuning.resolutionUpHold {
            resolutionIndex -= 1
            lastResolutionChangeAt = now
            cleanSince = now
            out.append(.resolution(resolutionIndex))
        }
        return out
    }

    /// Clean since `clean`: the bit rate step up, if one is due. Below the start rate it climbs back (×1.25, to the
    /// start rate); past it after `climbHold` clean, a step per `climbInterval` while the stream uses its target — a
    /// full window alone is not enough. Never past the network profile's ceiling nor the remembered one.
    private mutating func increase(cleanSince clean: TimeInterval, at now: TimeInterval) -> Int? {
        guard now - (lastIncreaseAt ?? -.infinity) >= tuning.increaseInterval,
              now - (lastDecreaseAt ?? -.infinity) >= tuning.increaseInterval else { return nil }
        let cap = min(maxKbpsNow, ceilingKbps(at: now) ?? .max)
        let climbEvery = onCellular ? max(tuning.climbInterval, tuning.cellularClimbEvery) : tuning.climbInterval
        let factor = onCellular ? tuning.cellularIncreaseFactor : tuning.increaseFactor
        let next: Int
        if bitrateKbps < tuning.startKbps {
            next = min(tuning.startKbps, cap, Int((Double(bitrateKbps) * tuning.recoverFactor).rounded()))
        } else {
            let climbDue = now - clean >= tuning.climbHold
                && now - (lastIncreaseAt ?? -.infinity) >= climbEvery
                && (sentKbps(at: now).map { $0 >= tuning.climbUtilization * Double(bitrateKbps) } ?? true)
            guard climbDue else { return nil }
            next = min(cap, Int((Double(bitrateKbps) * factor).rounded()))
        }
        guard next > bitrateKbps else { return nil }
        if next > tuning.startKbps { climbs += 1 }
        bitrateKbps = next
        lastIncreaseAt = now
        increases += 1
        return next
    }

    private mutating func decrease(at now: TimeInterval) -> [StreamFlowAction] {
        lastDecreaseAt = now
        decreases += 1
        let hold = onCellular ? tuning.cellularCeilingHold : tuning.ceilingHold
        ceiling = (max(tuning.minKbps, Int((Double(bitrateKbps) * tuning.ceilingFactor).rounded())), now + hold)
        if bitrateKbps > tuning.minKbps {
            bitrateKbps = max(tuning.minKbps, Int((Double(bitrateKbps) * tuning.decreaseFactor).rounded()))
            return [.bitrate(bitrateKbps)]
        }
        guard resolutionIndex < widths.count - 1 else { return [] }
        resolutionIndex += 1
        lastResolutionChangeAt = now
        return [.resolution(resolutionIndex)]
    }

    // MARK: key frames

    /// The client's decoder needs a key frame.
    mutating func requestKey(at now: TimeInterval) {
        keyRequests += 1
        keyPending = true
    }

    /// When the pending key request may be answered, or nil if none is pending.
    var keyDueAt: TimeInterval? {
        guard keyPending else { return nil }
        return (lastKeyAt ?? -.infinity) + tuning.keyMinInterval
    }

    func keyDue(at now: TimeInterval) -> Bool { keyDueAt.map { now >= $0 } ?? false }

    /// A key frame went out (asked for or not): answers a pending request.
    mutating func noteKeySent(at now: TimeInterval) {
        lastKeyAt = now
        keyPending = false
    }
}

/// A snapshot of one stream's flow + codec state, for the periodic log line.
struct StreamFlowSummary: Sendable {
    var id: String?
    var codec: String
    var cursorClient: Bool
    /// The stream has a flow (a stream id: it may be acked); the window's state is below.
    var acks = false
    var windowActive = false
    var windowDisabled = false
    var window = StreamTuning.default.videoWindow
    var inFlight = 0
    var bitrateKbps: Int?
    var width = 0
    var rttMinMs: Double?
    var srttMs: Double?
    var windowLimited = 0
    var probes = 0
    var keyFrames = 0
    var keyRequests = 0
    var bytesPerSecond = 0
    var partsPerSecond = 0.0
    var encodeMs: Double?
    var lastKeyBytes: Int?
    /// Video pictures the encoder's rate control skipped.
    var drops = 0
    /// The client's latest playout report (from its acks).
    var phone: StreamPlayoutReport? = nil
    /// The stream's network grade (StreamNetQuality.swift), and the client's latest `report.net` behind it.
    var net: StreamNetQuality? = nil
    var netClient: StreamNetReport? = nil
    /// Cursor parts this stream sent (`cursor=client`).
    var cursorParts = 0
    /// `adapt(from:)` ran (the stream has a controller): the adaptation's state below is in the line.
    var adapted = false
    /// The adaptation's state: the windowed-minimum queue delay, the remembered ceiling, steps up past the start rate
    /// and congestion steps down.
    var queueDelayMinMs: Double? = nil
    var ceilingKbps: Int? = nil
    var climbs = 0
    var decreases = 0
    /// Congestion steps skipped while the stream was content-limited.
    var heldSteps = 0
    /// The network profile in force (StreamNetProfile).
    var profile: StreamNetProfile? = nil

    /// Copy the window's and the adaptation's state from the stream's controller.
    mutating func adapt(from c: StreamFlowController) {
        acks = true
        windowActive = c.active
        windowDisabled = c.disabled
        window = c.window
        inFlight = c.inFlight
        rttMinMs = c.minRTT.map { $0 * 1000 }
        srttMs = c.srtt.map { $0 * 1000 }
        windowLimited = c.windowLimitedCount
        probes = c.probes
        keyRequests = c.keyRequests
        adapted = true
        queueDelayMinMs = c.queueDelayMin.map { $0 * 1000 }
        ceilingKbps = c.ceilingKbps
        climbs = c.climbs
        decreases = c.decreases
        heldSteps = c.heldSteps
        profile = c.profile
    }

    var json: [String: Any] {
        func ms(_ v: Double?) -> Any { v.map { ($0 * 10).rounded() / 10 as Any } ?? NSNull() }
        return [
            "id": id.map { $0 as Any } ?? NSNull(), "codec": codec, "cursor": cursorClient ? "client" : "composited",
            "acks": acks, "windowActive": windowActive, "windowDisabled": windowDisabled, "window": window,
            "inFlight": inFlight, "bitrateKbps": bitrateKbps.map { $0 as Any } ?? NSNull(), "width": width,
            "rttMinMs": ms(rttMinMs), "srttMs": ms(srttMs),
            "windowLimited": windowLimited, "probes": probes, "keyFrames": keyFrames, "keyRequests": keyRequests,
            "bytesPerSecond": bytesPerSecond, "partsPerSecond": (partsPerSecond * 10).rounded() / 10,
            "encodeMs": ms(encodeMs), "lastKeyBytes": lastKeyBytes.map { $0 as Any } ?? NSNull(), "drops": drops,
            "phone": phone.map { $0.json as Any } ?? NSNull(), "cursorParts": cursorParts,
            "queueDelayMinMs": ms(queueDelayMinMs),
            "ceilingKbps": ceilingKbps.map { $0 as Any } ?? NSNull(), "climbs": climbs, "decreases": decreases, "heldSteps": heldSteps,
            "profile": profile.map { ["name": $0.name, "maxKbps": $0.maxKbps] as Any } ?? NSNull(),
            "net": net.map { q -> Any in
                var d = q.json
                d["client"] = netClient.map { $0.json as Any } ?? NSNull()
                return d
            } ?? NSNull(),
        ]
    }

    var line: String {
        var s = "\(codec) \(width)px"
        if let b = bitrateKbps { s += " \(b)kbps" }
        s += " \(bytesPerSecond / 1024)KB/s \(String(format: "%.1f", partsPerSecond))p/s"
        if let e = encodeMs { s += String(format: " enc %.1fms", e) }
        if let r = srttMs, let m = rttMinMs { s += String(format: " rtt %.0f/%.0fms", r, m) }
        if adapted {
            s += queueDelayMinMs.map { String(format: " qdmin %.0fms", $0) } ?? " qdmin -"
            if bitrateKbps != nil { s += " cap \(ceilingKbps.map(String.init) ?? "-") climbs \(climbs)" }
            s += " downs \(decreases)"
            if heldSteps > 0 { s += " held \(heldSteps)" }
            if let profile, profile.name != "wifi" { s += " profile \(profile.name) \(profile.maxKbps)" }
        }
        s += windowDisabled ? " window off" : windowActive ? " win \(inFlight)/\(window) limited \(windowLimited)" : ""
        s += " keys \(keyFrames)"
        if drops > 0 { s += " drops \(drops)" }
        return s
    }
}

/// One live stream's flow state, shared between its loop and the ack route.
final class StreamFlow: @unchecked Sendable {
    let id: String
    /// The stream's log prefix (`video: display stream <id>`).
    let label: String
    private let lock = NSLock()
    // Guarded by `lock`:
    private var controller: StreamFlowController
    private var pending: [StreamFlowAction] = []
    private var report: StreamPlayoutReport?
    /// The client's latest `report.net` and when it came; the grade, when it was computed, and the grade last logged.
    private var clientNet: (report: StreamNetReport, at: TimeInterval)?
    private var quality: (value: StreamNetQuality, at: TimeInterval)?
    private var loggedGrade = StreamNetQuality.Grade.unknown
    /// The client's `report.audio`s since the last stats line (counts summed).
    private var audioWindow: StreamAudioReport?
    private let clock: @Sendable () -> TimeInterval
    /// Wakes the stream loop (an ack may open the window).
    private let wake: @Sendable () -> Void

    /// The network grade looks this far back (ack round trips; a client report older than this is ignored) and is
    /// recomputed at most every `qualityInterval`.
    static let qualityWindow: TimeInterval = 10
    static let qualityInterval: TimeInterval = 1

    init(id: String, label: String? = nil, controller: StreamFlowController,
         clock: @escaping @Sendable () -> TimeInterval = StreamClock.now, wake: @escaping @Sendable () -> Void) {
        self.id = id
        self.label = label ?? "stream \(id)"
        self.controller = controller
        self.clock = clock
        self.wake = wake
        _ = self.controller.apply(StreamNetProfile.choose(client: nil, tuning: controller.tuning))
    }

    /// The client's latest playout report.
    var playoutReport: StreamPlayoutReport? {
        lock.lock(); defer { lock.unlock() }
        return report
    }

    /// A playout report arrived with an ack (route thread): kept for the stats line, its `audio` summed into the
    /// stats window. Not logged by itself.
    func received(_ r: StreamPlayoutReport) {
        let now = clock()
        lock.lock()
        report = r
        if let net = r.net { clientNet = (net, now) }
        if let a = r.audio { audioWindow = audioWindow.map { $0.merged(with: a) } ?? a }
        let profileLines = updateProfile(at: now)
        lock.unlock()
        for line in profileLines { log("\(label) \(line)") }
        if profileLines.count > 1 { wake() }  // a step down for the loop to apply
    }

    /// The stats line's tail (stream thread, every stats line): `phone smooth 59.6 fps hitch 0.4/s stall 0.1/s buf 52
    /// ms jit 48 ms`, then `; audio delay 118 ms underruns 0` when sound reports came since the last call (their counts
    /// summed; the window starts afresh). nil before the first report.
    func takePhoneTail() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let audio = audioWindow
        audioWindow = nil
        guard let report else { return nil }
        return "phone \(report.compactLine)" + (audio.map { "; audio \($0.compactLine)" } ?? "")
    }

    /// The network profile from the client's fresh `report.net` (lock held): when it changed, apply it (a lower
    /// ceiling steps the rate down, through `pending`). Returns the lines to log — `profile cellular: max 8000 kbps`,
    /// then `bitrate 12000 → 8000 kbps (profile cellular)` when it stepped the rate down.
    private func updateProfile(at now: TimeInterval) -> [String] {
        let p = StreamNetProfile.choose(client: freshClientNet(at: now), tuning: controller.tuning)
        guard p != controller.profile else { return [] }
        let before = controller.bitrateKbps
        let actions = controller.apply(p)
        pending += actions
        var lines = ["profile \(p.name): max \(p.maxKbps) kbps"]
        if !actions.isEmpty { lines.append("bitrate \(before) → \(controller.bitrateKbps) kbps (profile \(p.name))") }
        return lines
    }

    /// The network profile in force (stats, tests).
    var profile: StreamNetProfile? {
        lock.lock(); defer { lock.unlock() }
        return controller.profile
    }

    /// The client's latest `report.net`, if it is still within the grading window.
    var clientNetReport: StreamNetReport? {
        lock.lock(); defer { lock.unlock() }
        return freshClientNet(at: clock())
    }

    private func freshClientNet(at now: TimeInterval) -> StreamNetReport? {
        guard let c = clientNet, now - c.at <= Self.qualityWindow else { return nil }
        return c.report
    }

    /// The stream's network grade (for an ack's answer; route thread): recomputed at most every `qualityInterval`,
    /// logged when the grade changes (from `unknown` at the start; only while acks come).
    func netQuality() -> StreamNetQuality {
        let now = clock()
        lock.lock()
        if let q = quality, now - q.at < Self.qualityInterval {
            lock.unlock()
            return q.value
        }
        let client = freshClientNet(at: now)
        let value = StreamNetQuality.grade(acks: controller.rttSummary(at: now, window: Self.qualityWindow), client: client)
        quality = (value, now)
        let changed = value.grade != loggedGrade
        if changed { loggedGrade = value.grade }
        lock.unlock()
        if changed { log("\(label) \(value.line(client: client))") }
        return value
    }

    /// The stream ended (stream thread): its last grade, with its reasons, in one line (none if acks never came).
    func finish() {
        lock.lock()
        let last = quality?.value
        let client = clientNet?.report
        lock.unlock()
        if let last { log("\(label) ended; last \(last.line(client: client))") }
    }

    /// The latest grade without recomputing it (stats).
    var lastNetQuality: StreamNetQuality? {
        lock.lock(); defer { lock.unlock() }
        return quality?.value
    }

    /// An ack arrived (route thread).
    func ack(seq: UInt64, keyframe: Bool) {
        let now = clock()
        lock.lock()
        let wasDisabled = controller.disabled
        let rateBefore = controller.bitrateKbps
        let actions = controller.ack(seq: seq, keyframe: keyframe, at: now)
        pending += actions
        let back = wasDisabled && !controller.disabled
        // A bit rate change: a line for a step down (congestion) and for a climb that reached its ceiling; other climbs
        // are only counted (the stats line's `climbs`).
        let rateChanged = actions.contains { if case .bitrate = $0 { return true } else { return false } }
        let rateLine: String? = rateChanged && Self.logsRateChange(controller, from: rateBefore, at: now)
            ? Self.rateLine(controller, from: rateBefore, at: now) : nil
        // The client's net may have gone stale (no report for 10 s): back to the default profile.
        let profileLines = updateProfile(at: now)
        lock.unlock()
        if let rateLine { log("\(label) \(rateLine)") }
        for line in profileLines { log("\(label) \(line)") }
        if back { log("\(label): acks are back; flow-control window on again") }
        if wasDisabled, !back, !keyframe, profileLines.count < 2 { return }
        wake()
    }

    /// A rate change worth a line: down, or up to the ceiling in force (the profile's, or the remembered one).
    static func logsRateChange(_ c: StreamFlowController, from before: Int, at now: TimeInterval) -> Bool {
        c.bitrateKbps < before || c.bitrateKbps >= min(c.maxKbpsNow, c.ceilingKbps(at: now) ?? .max)
    }

    /// `bitrate 2500 → 2750 kbps (qdmin 3 rtt 92/70 ms cap - sent 2410 kbps)`.
    static func rateLine(_ c: StreamFlowController, from before: Int, at now: TimeInterval) -> String {
        func ms(_ v: TimeInterval?) -> String { v.map { String(format: "%.0f", $0 * 1000) } ?? "-" }
        var s = "bitrate \(before) → \(c.bitrateKbps) kbps (qdmin \(ms(c.queueDelayMin))"
            + " rtt \(ms(c.srtt))/\(ms(c.minRTT)) ms cap \(c.ceilingKbps(at: now).map(String.init) ?? "-")"
        if let sent = c.sentKbps(at: now) { s += String(format: " sent %.0f kbps", sent) }
        return s + ")"
    }

    /// Run `body` on the controller under the lock (stream thread).
    func with<T>(_ body: (inout StreamFlowController) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&controller)
    }

    /// Actions produced by acks since the last call.
    func takeActions() -> [StreamFlowAction] {
        lock.lock(); defer { lock.unlock() }
        let out = pending
        pending.removeAll()
        return out
    }
}

/// Open streams with a client-chosen id, for `POST /stream/ack`. A new stream with the same id replaces the old one.
enum StreamFlowRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var flows: [String: StreamFlow] = [:]  // guarded by `lock`

    static func register(_ flow: StreamFlow) {
        lock.lock(); flows[flow.id] = flow; lock.unlock()
    }

    static func unregister(_ flow: StreamFlow) {
        lock.lock()
        if flows[flow.id] === flow { flows[flow.id] = nil }
        lock.unlock()
    }

    static func lookup(_ id: String) -> StreamFlow? {
        lock.lock(); defer { lock.unlock() }
        return flows[id]
    }

    /// A valid client stream id: 8–64 of [A-Za-z0-9_-].
    static func isValidID(_ s: String) -> Bool {
        (8...64).contains(s.utf8.count) && s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
        }
    }
}

/// The monotonic clock the streams use (seconds).
enum StreamClock {
    @Sendable static func now() -> TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

/// A sliding byte / part rate over the last couple of seconds (stats only).
struct StreamRateMeter: Sendable {
    let span: TimeInterval
    private var events: [(at: TimeInterval, bytes: Int)] = []
    init(span: TimeInterval = 2) { self.span = span }

    mutating func add(_ bytes: Int, at now: TimeInterval) {
        events.append((now, bytes))
        events.removeAll { now - $0.at > span }
    }

    func rate(at now: TimeInterval) -> (bytesPerSecond: Int, partsPerSecond: Double) {
        let recent = events.filter { now - $0.at <= span }
        return (Int(Double(recent.reduce(0) { $0 + $1.bytes }) / span), Double(recent.count) / span)
    }
}
#endif
