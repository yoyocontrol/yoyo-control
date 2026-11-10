import Foundation
import YoyoClipboard
import YoyoCore

/// The jitter buffer of the Mac's sound on the Screen page (`ScreenAudio`), pure and deterministic: every time is passed
/// in. Host times are seconds of `CACurrentMediaTime()` (the output's render time when pulling); `macTime` is a packet's
/// `X-Audio-Time` in seconds (since 1970, on the Mac's clock). Samples are Float32, interleaved, `channels` per frame.
///
/// As in smooth playback (`ScreenPlayout`), each packet's delay = arrival − macTime holds the clock offset plus the
/// network delay; `base` = the smallest delay of the last `window` (the offset and its drift), the delays above it are
/// the jitter. The buffer's own need is their p99 + `margin`, within the floor…`maxDepth` (`startDepth` until
/// `minSamples` were seen); the floor is `minDepth` (by route, `route(lan:)`: 80 ms on a LAN, 120 ms on a remote path
/// (the internet, a relay)) plus an adaptive `bump`: each interruption (an underrun, or a run of late drops after sound had played)
/// raises it by `bumpStep` (at most `bumpMax`), and it falls by `bumpDecay` for every `bumpDecayEvery` without one
/// (netsim, 40 ms up / 10 ms down per 15 s: LAN 0.27 → 0.20 interruptions a minute at the same median latency, Wi-Fi
/// remote 1.30 → 0.95 for +16 ms, 5G 2.81 → 2.13 for +120 ms; 10 ms per 30 s did the same 15 ms later). The
/// depth is that need + `lead`, the output's lead (set by the output: a render callback's `now` is about one IO buffer
/// + 1.5 ms after the callback, and it renders a whole IO buffer at once, so a sample must be in up to 2 × IO + 1.5 ms
/// before its slot; netsim: without it the default 1024-frame IO buffer underran 21 times a minute on the LAN), or the
/// A/V sync depth (`setSync`) when that is more: it moves at most `syncRate` a second, so playback reaches it through
/// the cuts and the next start rather than at once. A packet's slot starts at macTime + base + depth.
///
/// Playback starts at the first packet's slot (a packet more than `lateTolerance` past its slot is late: dropped; within
/// it, it plays from where its slot is now) and then runs on sample by sample, packet after packet, without looking at
/// the clock. Packets come in `X-Audio-Seq` order (one TCP stream); a seq gap is packets the Mac dropped: that many
/// packets of silence (more than `maxConcealed`: playback starts over from the slots). Running dry is an underrun:
/// playback starts over from the next packet's slot (later ones past their slot are dropped). Sound never starts or
/// stops on a cliff: it fades in and out over `fade` (a gap, an underrun, a start). When more is buffered than the depth
/// asks for (by `excess`, held for `excessHold`: the depth shrank, or the Mac's clock runs fast against the phone's),
/// `cut` of it is dropped at the quietest spot of the next packet, crossfaded over `crossfade`, at most every `cutEvery`.
/// At most `maxQueued` waits (more: the oldest goes, and playback starts over: the output stopped pulling). A delay
/// `clockStep` below the base, or that far above it for `clockStepHold`, is a clock step: the estimate starts over.
///
/// A new stream (`newStream`: the page's sound was reopened) restarts the seq
/// tracking and the clock estimate; what of the old stream is playing plays out and fades, and the new one fades in at
/// its first slot (an old stream that just stops is not an underrun). On the same route (the same floor) the bump and
/// the jitter measured so far are kept: the new stream starts at the depth the old one had reached, not at the start
/// depth. A stream that ended by itself (`endStream`: the Mac closed it, the network dropped it) fades out over the last
/// `endFadeOut` of what it left, and the stream that reopens it fades in over `resumeFadeIn` (`newStream(fadeIn:)`).
///
/// Real-time safe once the arrays are warm: pushing and pulling allocate and free nothing (the window, the scratch for
/// the percentile and the queues are reserved up front and capped; played or dropped packets' storage goes to `spent`,
/// which the owner empties on a thread where freeing is fine: `popSpent` / `releaseSpent`). The netsim copy
/// (apps/mac-screen/Sources/netsim/ScreenAudioBuffer.swift) is a symlink to this file, so keep it Foundation-only.
struct ScreenAudioBuffer {
    struct Config: Sendable, Equatable {
        var rate: Double = 48_000
        var channels = 2
        /// Frames of one packet (`X-Audio-Frames`): a missing one is this much silence.
        var packetFrames = 960
        var window: Double = 10
        var minSamples = 10
        var startDepth: Double = 0.120
        var margin: Double = 0.020
        /// The depth floor (before the bump).
        var minDepth: Double = 0.120
        var maxDepth: Double = 0.400
        var percentile: Double = 0.99
        var lateTolerance: Double = 0.010
        var fade: Double = 0.005
        var excess: Double = 0.020
        var excessHold: Double = 1
        var cut: Double = 0.010
        var crossfade: Double = 0.0025
        var cutEvery: Double = 0.25
        var maxConcealed = 25
        var maxQueued: Double = 1
        var clockStep: Double = 0.5
        var clockStepHold: Double = 1
        /// The adaptive floor: + this per interruption (0: off), at most `bumpMax`; − `bumpDecay` per `bumpDecayEvery`
        /// without one.
        var bumpStep: Double = 0.040
        var bumpMax: Double = 0.240
        var bumpDecay: Double = 0.010
        var bumpDecayEvery: Double = 15
        /// How fast the A/V sync depth moves (seconds per second).
        var syncRate: Double = 0.020

        /// The floors by route (netsim「R1」).
        static let lanFloor = 0.080
        static let remoteFloor = 0.120

        /// The buffer for a LAN or a remote path.
        static func route(lan: Bool) -> Config {
            var c = Config()
            c.minDepth = lan ? lanFloor : remoteFloor
            c.startDepth = max(c.minDepth, 0.060)
            return c
        }

        /// A fixed depth: always `depth` (+ the lead), no bump (tests).
        mutating func fix(depth: Double) {
            minDepth = depth
            maxDepth = depth
            startDepth = depth
            bumpStep = 0
        }

        /// Another floor: `floor` instead of the route's (tests).
        mutating func set(floor: Double) {
            minDepth = floor
            startDepth = max(floor, 0.060)
            maxDepth = max(maxDepth, floor)
        }
    }

    /// The numbers of the stats line, the A/V sync and the report.
    struct Stats: Sendable, Equatable {
        /// The depth asked for (need + lead, or the sync depth), and what is buffered now (seconds).
        var depth: Double
        var buffered: Double
        /// The buffer's own need (without the lead and the sync depth), the floor of the route and the bump on it.
        var need: Double = 0
        var floor: Double = 0
        var bump: Double = 0
        var lead: Double = 0
        /// The A/V sync depth in use (nil: none).
        var sync: Double? = nil
        var jitter: Double?
        var base: Double? = nil
        var playing: Bool
        /// Playing: host time − macTime of the sample playing now (nil: not playing).
        var delay: Double? = nil
        /// When the current stream's sound started playing (host time; nil: not yet).
        var soundStartedAt: Double? = nil
        var underruns: Int
        /// Packets dropped: late (past their slot), and over `maxQueued`.
        var late: Int
        var overflow: Int
        /// Cuts made to bring the buffer back to its depth, and the frames they dropped.
        var cuts: Int
        var cutFrames: Int = 0
        /// Missing packets filled with silence.
        var concealed: Int
        /// Interruptions (what raises the bump).
        var interruptions: Int = 0
        var drops: Int { late + overflow }
    }

    private(set) var config: Config
    /// The depth asked for (seconds).
    private(set) var depth: Double
    /// The buffer's own need (see above).
    private(set) var need: Double
    /// The adaptive floor's bump (seconds).
    private(set) var bump: Double = 0
    /// The output's lead (`setLead`).
    private(set) var lead: Double = 0
    /// The A/V sync depth in use (nil: none).
    private(set) var syncLevel: Double?
    /// The smallest recent delay (nil until the first packet).
    private(set) var base: Double?
    /// The p99 of the window's delays above the base (nil until `minSamples` were seen).
    private(set) var jitter: Double?
    /// Sound is coming out (else waiting for the next packet's slot).
    private(set) var playing = false
    private(set) var underruns = 0
    private(set) var late = 0
    private(set) var overflow = 0
    private(set) var cuts = 0
    private(set) var cutFrames = 0
    private(set) var concealed = 0
    private(set) var interruptions = 0
    /// Clock steps seen.
    private(set) var resets = 0
    /// Streams begun after the first (`newStream`).
    private(set) var streams = 0
    /// When the current stream's sound started playing (host time).
    private(set) var soundStartedAt: Double?
    /// Playing: host time − macTime of the next sample, at the end of the last pull.
    private(set) var delay: Double?

    private struct Packet {
        var seq: Int
        var macTime: Double
        var samples: [Float]
        var frames: Int
    }
    /// In seq order; the first is the one playing (from `cursor`).
    private var packets: [Packet] = []
    private var cursor = 0
    /// The seq that follows the one playing.
    private var expected: Int?
    /// Frames of silence to play first (a gap).
    private var silence = 0
    /// The gain now (0…1): it moves by one `fade` step per frame, and is never more than the frames left before the
    /// sound runs out allow (so it is 0 when it does).
    private var level: Float = 0
    private var excessSince: Double?
    private var lastCut: Double?
    /// Frames from the cursor to the planned cut.
    private var cutAt: Int?
    /// Added to every seq pushed (a new stream counts from 1 again), and the highest seq so far with it.
    private var seqBase = 0
    private var topSeq: Int?
    /// Sound has played since the last interruption (the next one counts).
    private var armed = false
    /// What plays is the end of a stream that was replaced: running out is not an underrun.
    private var ending = false
    /// The current stream ended by itself (`endStream`): no more packets come; what's left fades over `endFadeOut`.
    private var ended = false
    /// Frames the tail of an ended stream fades over (nil: the usual `fade` at a run's end).
    private var tailFade: Int?
    /// The next start's fade-in, frames (nil: `fade`), and the gain step of the start playing now.
    private var nextRise: Int?
    private var rise: Float = 0
    private var bumpAt: Double?
    private var syncAt: Double?

    private struct Sample { var arrival: Double; var delay: Double }
    private var samples: [Sample] = []
    /// The percentile's working copy (reserved: no allocation per packet).
    private var scratch: [Double] = []
    private var seen = 0
    private var highSince: Double?
    /// Played or dropped packets' storage, to be let go off the output's thread (`popSpent` / `releaseSpent`).
    private var spent: [[Float]] = []

    /// A stream that ended by itself fades out over this much of what it left; the one that reopens it fades in over
    /// `resumeFadeIn` (seconds).
    static let endFadeOut = 0.080
    static let resumeFadeIn = 0.120

    /// At most this many packets wait, window samples are kept, and spent packets are held (the reserved sizes).
    static let maxPackets = 256
    static let maxSamples = 2_048
    static let spentCapacity = 1_024

    init(config: Config = Config()) {
        self.config = config
        need = config.startDepth
        depth = config.startDepth
        packets.reserveCapacity(Self.maxPackets + 1)
        samples.reserveCapacity(Self.maxSamples + 1)
        scratch.reserveCapacity(Self.maxSamples + 1)
        spent.reserveCapacity(Self.spentCapacity)
    }

    var stats: Stats {
        Stats(depth: depth, buffered: Double(queuedFrames) / config.rate, need: need, floor: config.minDepth, bump: bump,
              lead: lead, sync: syncLevel, jitter: jitter, base: base, playing: playing, delay: delay,
              soundStartedAt: soundStartedAt, underruns: underruns, late: late, overflow: overflow, cuts: cuts,
              cutFrames: cutFrames, concealed: concealed, interruptions: interruptions)
    }

    /// A packet's start on the host clock (nil before any delay was seen).
    func slot(macTime: Double) -> Double? { base.map { macTime + $0 + depth } }

    // MARK: In

    /// A decoded packet (`samples` interleaved; any whole number of frames, none too).
    mutating func push(seq rawSeq: Int, macTime: Double, arrival: Double, samples: [Float]) {
        let seq = rawSeq &+ seqBase
        observe(delay: arrival - macTime, arrival: arrival)
        // its place already played (or a repeat)
        if playing, let expected, seq < expected { late += 1; spent(samples); return }
        if let last = packets.last, seq <= last.seq { late += 1; spent(samples); return }
        topSeq = max(topSeq ?? seq, seq)
        let frames = samples.count / max(config.channels, 1)
        packets.append(Packet(seq: seq, macTime: macTime, samples: samples, frames: frames))
        let limit = Int(config.maxQueued * config.rate)
        while queuedFrames > limit || packets.count > Self.maxPackets, !packets.isEmpty {
            // the output stopped pulling: start over from the slots
            if playing { stopPlaying() }
            spent(packets.removeFirst().samples)
            cursor = 0
            overflow += 1
        }
    }

    /// Drops what waits (the output's route changed): playback starts over from the next packet's slot.
    mutating func flush() {
        while !packets.isEmpty { spent(packets.removeFirst().samples) }
        stopPlaying()
        armed = false
        ending = false
    }

    /// A new stream of the same sound (see above); `config` (same rate and channels): the new route's; `fadeIn`: its
    /// first sound fades in over that long (seconds; nil: `fade`).
    mutating func newStream(config new: Config? = nil, fadeIn: Double? = nil) {
        var sameRoute = true
        if let new {
            if new.minDepth != config.minDepth { bump = 0; bumpAt = nil; sameRoute = false }
            config = new
        }
        if let topSeq { seqBase = topSeq &+ config.maxConcealed &+ 2 }
        if playing {
            ending = true
        } else {
            while !packets.isEmpty { spent(packets.removeFirst().samples) }
            cursor = 0
            tailFade = nil
        }
        ended = false
        nextRise = fadeIn.map { max(Int($0 * config.rate), 1) }
        samples.removeAll(keepingCapacity: true)
        seen = 0
        base = nil
        // the jitter measured on this route stands until the new stream has its own
        if !sameRoute { jitter = nil }
        highSince = nil
        armed = false
        excessSince = nil
        soundStartedAt = nil
        streams += 1
        updateDepth(at: nil)
    }

    /// The current stream ended by itself: no more of its packets come. What it left plays out, its last `endFadeOut`
    /// fading to silence, and running out of it is not an underrun.
    mutating func endStream() {
        ended = true
        if playing { ending = true }
        tailFade = max(Int(Self.endFadeOut * config.rate), 1)
    }

    /// The output's lead (seconds).
    mutating func setLead(_ lead: Double) {
        guard lead != self.lead, lead.isFinite else { return }
        self.lead = max(lead, 0)
        updateDepth(at: nil)
    }

    /// The A/V sync depth wanted at `t` (the whole depth, lead included; nil: none): the depth in use moves towards
    /// it by at most `syncRate` a second, and never below the buffer's own need + lead.
    mutating func setSync(_ target: Double?, at t: Double) {
        let own = min(need, config.maxDepth) + lead
        let dt = max(t - (syncAt ?? t), 0)
        syncAt = t
        guard target != nil || syncLevel != nil else { return }
        let goal = max(min(target ?? own, config.maxDepth + lead), own)
        var level = syncLevel ?? own
        let step = config.syncRate * dt
        level = goal > level ? min(goal, level + step) : max(goal, level - step)
        syncLevel = level > own + 1e-9 ? level : nil
        updateDepth(at: t)
    }

    /// The newest spent packet's storage, taken out (nil: none).
    mutating func popSpent() -> [Float]? { spent.popLast() }

    /// Lets go of the spent packets' storage (call it where freeing is fine).
    mutating func releaseSpent() { spent.removeAll(keepingCapacity: true) }

    var spentCount: Int { spent.count }

    // MARK: Out

    /// `frames` frames for the output, interleaved, the first heard at `now` (host seconds).
    mutating func pull(into out: UnsafeMutablePointer<Float>, frames n: Int, at now: Double) {
        let ch = config.channels
        let step = 1 / Float(fadeFrames)
        planCut(at: now)
        var i = 0
        var runLeft = run()
        while i < n {
            guard playing else {
                let t = now + Double(i) / config.rate
                dropLate(at: t)
                guard let head = packets.first, let due = slot(macTime: head.macTime) else {
                    out.advanced(by: i * ch).update(repeating: 0, count: (n - i) * ch)
                    break
                }
                if due - t > 0.5 / config.rate {
                    let wait = min(max(Int(((due - t) * config.rate).rounded(.up)), 1), n - i)
                    out.advanced(by: i * ch).update(repeating: 0, count: wait * ch)
                    i += wait
                    continue
                }
                // its slot is now (or just passed: from where it is now)
                playing = true
                armed = true
                ending = ended
                if !ended { tailFade = nil }
                // the first start after a reopen fades in slowly; any other start (an underrun, a gap) at `fade`
                rise = 1 / Float(soundStartedAt == nil ? nextRise ?? fadeFrames : fadeFrames)
                if soundStartedAt == nil { nextRise = nil }
                if soundStartedAt == nil { soundStartedAt = t }
                expected = head.seq
                cursor = min(max(Int(((t - due) * config.rate).rounded()), 0), max(head.frames - 1, 0))
                level = 0
                runLeft = run()
                continue
            }
            if silence > 0 {
                let z = min(silence, n - i)
                out.advanced(by: i * ch).update(repeating: 0, count: z * ch)
                silence -= z
                i += z
                level = 0
                continue
            }
            if cutAt == 0 {
                cutAt = nil
                performCut()
                runLeft = run()
                continue
            }
            guard !packets.isEmpty else {
                // ran dry (the end of a replaced or ended stream is no underrun)
                let wasEnding = ending
                stopPlaying()
                if wasEnding {
                    ending = false
                } else {
                    underruns += 1
                    interrupted(at: now + Double(i) / config.rate)
                }
                continue
            }
            if cursor >= packets[0].frames {
                advance()
                runLeft = run()
                continue
            }
            let k = min(n - i, packets[0].frames - cursor, cutAt ?? .max)
            let rise = self.rise
            let tail = tailFade.map(Float.init)
            packets[0].samples.withUnsafeBufferPointer { src in
                var o = out.advanced(by: i * ch)
                var s = cursor * ch
                for _ in 0..<k {
                    var l = min(level + rise, 1, Float(runLeft - 1) * step)
                    // an ended stream's last `endFadeOut`: down from where the gain is to nothing at its last frame
                    if let tail, Float(runLeft) <= tail { l = min(l, level * Float(runLeft - 1) / Float(max(runLeft, 1))) }
                    level = max(l, 0)
                    for c in 0..<ch { o[c] = src[s + c] * level }
                    o = o.advanced(by: ch)
                    s += ch
                    runLeft -= 1
                }
            }
            cursor += k
            i += k
            if let at = cutAt { cutAt = at - k }
        }
        if playing, silence == 0, let head = packets.first {
            delay = now + Double(n) / config.rate - (head.macTime + Double(cursor) / config.rate)
        } else if !playing {
            delay = nil
        }
    }

    /// For tests: `frames` frames, interleaved.
    mutating func pull(frames: Int, at now: Double) -> [Float] {
        var out = [Float](repeating: .nan, count: frames * config.channels)
        out.withUnsafeMutableBufferPointer { pull(into: $0.baseAddress!, frames: frames, at: now) }
        return out
    }

    // MARK: Playback

    private var fadeFrames: Int { max(Int(config.fade * config.rate), 1) }

    /// Frames waiting to be played (gap silence included).
    private var queuedFrames: Int {
        packets.reduce(0) { $0 + $1.frames } - (packets.isEmpty ? 0 : min(cursor, packets[0].frames)) + silence
    }

    /// Frames of sound from the cursor before it runs out (a gap, or nothing more).
    private func run() -> Int {
        guard let first = packets.first else { return 0 }
        var total = max(first.frames - cursor, 0)
        var last = first.seq
        for p in packets.dropFirst() {
            guard p.seq == last + 1 else { break }
            total += p.frames
            last = p.seq
        }
        return total
    }

    private mutating func spent(_ samples: [Float]) {
        spent.append(samples)
    }

    private mutating func stopPlaying() {
        playing = false
        cursor = 0
        silence = 0
        cutAt = nil
        excessSince = nil
        level = 0
        delay = nil
        // a tail that faded is over (an ended stream that hasn't been replaced keeps it for what's left)
        if !ended { tailFade = nil }
    }

    /// The packet playing is done: the next one, or silence for the ones missing before it.
    private mutating func advance() {
        let done = packets.removeFirst()
        spent(done.samples)
        cursor = 0
        expected = done.seq + 1
        guard let head = packets.first, let expected, head.seq > expected else { return }
        let missing = head.seq - expected
        guard missing <= config.maxConcealed else {
            // too long a gap to fill (or the next stream): the slots again
            stopPlaying()
            ending = false
            return
        }
        silence = missing * config.packetFrames
        concealed += missing
        self.expected = head.seq
    }

    /// Waiting: packets past their slot (by more than `lateTolerance`) at `t` go.
    private mutating func dropLate(at t: Double) {
        while let head = packets.first, let due = slot(macTime: head.macTime), t - due > config.lateTolerance {
            spent(packets.removeFirst().samples)
            late += 1
            interrupted(at: t)
        }
    }

    /// An underrun, or a late drop after sound had played: one interruption until sound plays again; the floor rises.
    private mutating func interrupted(at t: Double) {
        guard armed else { return }
        armed = false
        interruptions += 1
        decayBump(at: t)
        if config.bumpStep > 0 {
            bump = min(bump + config.bumpStep, config.bumpMax)
            bumpAt = t
        }
        updateDepth(at: t)
    }

    /// The bump falls by `bumpDecay` for every `bumpDecayEvery` since it last changed.
    private mutating func decayBump(at t: Double) {
        guard bump > 0, config.bumpDecayEvery > 0 else { return }
        let at = bumpAt ?? t
        let steps = ((t - at) / config.bumpDecayEvery).rounded(.down)
        guard steps >= 1 else { return }
        bump = max(bump - steps * config.bumpDecay, 0)
        bumpAt = at + steps * config.bumpDecayEvery
    }

    /// The need from the jitter (or the start depth) within the floor + bump and the cap, + the lead; the sync depth
    /// when more. `t`: now (the bump's decay; nil: not now).
    private mutating func updateDepth(at t: Double?) {
        if let t { decayBump(at: t) }
        let floor = min(config.minDepth + bump, config.maxDepth)
        if let jitter {
            need = min(max(jitter + config.margin, floor), config.maxDepth)
        } else {
            need = max(config.startDepth, floor)
        }
        var d = need + lead
        if let syncLevel { d = max(d, syncLevel) }
        depth = d
    }

    /// Too much buffered for long enough: a cut is planned at the quietest spot of the next packet's worth.
    private mutating func planCut(at now: Double) {
        guard playing, silence == 0 else { excessSince = nil; return }
        guard Double(queuedFrames) / config.rate > depth + config.excess else { excessSince = nil; return }
        let since = excessSince ?? now
        excessSince = since
        guard cutAt == nil, now - since >= config.excessHold, lastCut.map({ now - $0 >= config.cutEvery }) ?? true else { return }
        let cut = Int(config.cut * config.rate)
        let fade = Int(config.crossfade * config.rate)
        let span = cut + fade
        let available = run()
        guard available > span else { return }
        // energy of `span` frames from each candidate (every 1 ms, over the next packet's worth)
        let stride = max(Int(config.rate / 1000), 1)
        let last = min(config.packetFrames, available - span - 1)
        var best = 0
        var bestEnergy = Float.infinity
        var offset = 0
        while offset <= last {
            var e: Float = 0
            var f = offset
            while f < offset + span {
                let (p, frame) = locate(f)
                for c in 0..<config.channels {
                    let v = packets[p].samples[frame * config.channels + c]
                    e += v * v
                }
                f += 4
            }
            if e < bestEnergy { bestEnergy = e; best = offset }
            offset += stride
        }
        cutAt = best
        lastCut = now
    }

    /// Drops `cut` frames at the cursor, the sound after them crossfaded in over `crossfade`.
    private mutating func performCut() {
        let cut = Int(config.cut * config.rate)
        let fade = Int(config.crossfade * config.rate)
        guard run() > cut + fade else { return }
        let ch = config.channels
        for k in 0..<fade {
            let w = (Float(k) + 0.5) / Float(fade)
            let (pa, fa) = locate(k)
            let (pb, fb) = locate(cut + k)
            for c in 0..<ch {
                let a = packets[pa].samples[fa * ch + c]
                let b = packets[pb].samples[fb * ch + c]
                packets[pb].samples[fb * ch + c] = a * (1 - w) + b * w
            }
        }
        var left = cut
        while left > 0, !packets.isEmpty {
            let available = packets[0].frames - cursor
            if available > left {
                cursor += left
                left = 0
            } else {
                left -= available
                advance()
            }
        }
        cuts += 1
        cutFrames += cut
    }

    /// The packet and frame `offset` frames after the cursor (within the run).
    private func locate(_ offset: Int) -> (Int, Int) {
        var left = offset + cursor
        var p = 0
        while p < packets.count - 1, left >= packets[p].frames {
            left -= packets[p].frames
            p += 1
        }
        return (p, left)
    }

    // MARK: Estimate

    private mutating func observe(delay: Double, arrival: Double) {
        guard delay.isFinite else { return }
        if let base {
            if delay < base - config.clockStep {
                restart()
            } else if delay > base + config.clockStep {
                // a stall (left out) — or, held this long, a clock step or a slower path
                let since = highSince ?? arrival
                highSince = since
                guard arrival - since >= config.clockStepHold else { return }
                restart()
            } else {
                highSince = nil
            }
        }
        samples.append(Sample(arrival: arrival, delay: delay))
        seen += 1
        while samples.count > config.minSamples, let first = samples.first,
              arrival - first.arrival > config.window || samples.count > Self.maxSamples {
            samples.removeFirst()
        }
        var base = delay
        for s in samples where s.delay < base { base = s.delay }
        self.base = base
        guard seen >= config.minSamples else {
            updateDepth(at: arrival)
            return
        }
        scratch.removeAll(keepingCapacity: true)
        for s in samples { scratch.append(s.delay - base) }
        jitter = Self.percentile(&scratch, config.percentile)
        updateDepth(at: arrival)
    }

    private mutating func restart() {
        samples.removeAll(keepingCapacity: true)
        seen = 0
        base = nil
        jitter = nil
        highSince = nil
        resets += 1
        updateDepth(at: nil)
    }

    /// Nearest-rank percentile (`p` in 0…1) of `values`, reordering them in place (a selection: no allocation); 0 for
    /// none. The same value as sorting and taking the rank (`ScreenPlayout.percentile`).
    static func percentile(_ values: inout [Double], _ p: Double) -> Double {
        let n = values.count
        guard n > 0 else { return 0 }
        let k = min(max(Int((p * Double(n)).rounded(.up)) - 1, 0), n - 1)
        var lo = 0
        var hi = n - 1
        while lo < hi {
            let pivot = values[(lo + hi) / 2]
            var i = lo
            var j = hi
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return values[k] }
        }
        return values[k]
    }
}
