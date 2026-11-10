import AVFoundation
import OSLog
import QuartzCore
import Synchronization
import YoyoClipboard
import YoyoCore

/// The Mac's sound on the Screen page (PROTOCOL.md「声音」, `GET /audio`): one stream of Opus packets, 20 ms
/// each, in the video stream's framing (`ScreenStream`, `.audio` parts with `X-Audio-Seq` / `X-Audio-Time`), its format
/// in the response's `X-Audio-*` headers (and `X-Audio-Video-Offset`, the A/V sync's same-instant offset). The packets
/// are decoded as they come (`ScreenAudioDecoder`) and go to the page's `ScreenAudioOutput`, which outlives the stream:
/// the page opens a new one when its sound ends or is turned on (its certificate checked like the video stream's, `trust`) and the
/// output plays on, starting the new stream in its jitter buffer (`tuning`: the route's). `stop()` ends the stream
/// (not the output); `onEnd` (on the stream's queue) says why the stream ended by itself.
final class ScreenAudio: Sendable {
    typealias OnEnd = @Sendable (Error?) -> Void

    /// The speaker button's setting (on unless turned off).
    /// `<namespace>Audio`.
    static var defaultsKey: String { YoyoHost.key("Audio") }

    static func isOn(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: defaultsKey) as? Bool ?? true }

    /// The stats line's numbers.
    struct Stats: Sendable, Equatable {
        var buffer: ScreenAudioBuffer.Stats?
        var kbps: Double

        /// For the stats line (not localized).
        var line: String {
            guard let b = buffer else { return String(format: "audio · %.0f kbps", kbps) }
            return String(format: "audio %.0f ms (buf %.0f) · %d underruns · %d drops · %.0f kbps",
                          b.depth * 1000, b.buffered * 1000, b.underruns, b.drops, kbps)
        }
    }

    private struct State {
        var format: ScreenAudioFormat?
        var decoder: ScreenAudioDecoder?
        /// The output's token for this stream (nil until its head came).
        var token: Int?
        var offsetMs = ScreenAudioFormat.defaultVideoOffsetMs
        var stopped = false
    }

    private let state = Mutex(State())
    private let stream = Mutex<ScreenStream?>(nil)
    private let request: URLRequest
    private let trust: YoyoTrust
    private let output: ScreenAudioOutput
    private let tuning: ScreenAudioTuning
    private let onEnd: OnEnd

    fileprivate static let log = Logger(subsystem: "ca.sarria.yoyocontrol", category: "screen-audio")

    init(request: URLRequest, trust: YoyoTrust = .system, output: ScreenAudioOutput,
         tuning: ScreenAudioTuning = ScreenAudioTuning(), onEnd: @escaping OnEnd) {
        self.request = request
        self.trust = trust
        self.output = output
        self.tuning = tuning
        self.onEnd = onEnd
    }

    func start() {
        let s = ScreenStream(request: request, trust: trust, onHead: { [weak self] fields in
            self?.opened(ScreenAudioFormat { fields[$0.lowercased()] },
                         offsetMs: ScreenAudioFormat.videoOffsetMs { fields[$0.lowercased()] })
        }, onOpen: { _ in }, onPart: { [weak self] part in
            self?.received(part, at: CACurrentMediaTime())
        }, onEnd: { [weak self] error in
            guard let self else { return }
            let (stopped, token) = self.state.withLock { ($0.stopped, $0.token) }
            self.end()
            guard !stopped else { return }
            // no more packets of this stream: what it left in the buffer fades out (`ScreenAudioOutput.end`)
            if let token { self.output.end(token: token) }
            self.onEnd(error)
        })
        stream.withLock { $0 = s }
        s.start()
    }

    /// Ends the stream (the output plays out what it has); nothing fires after it.
    func stop() {
        state.withLock { $0.stopped = true }
        end()
    }

    /// `X-Audio-Video-Offset` of this stream (ms; 31 until its head came, or when it has none).
    var videoOffsetMs: Double { state.withLock { $0.offsetMs } }

    var stats: Stats {
        let snap = output.snapshot()
        return Stats(buffer: snap.buffer, kbps: snap.kbps)
    }

    private func end() {
        stream.withLock { $0?.cancel(); $0 = nil }
        state.withLock { $0.decoder = nil }
    }

    /// The response's headers: the format (a codec this client can't play ends the stream); the output starts a new
    /// stream in its buffer.
    private func opened(_ format: ScreenAudioFormat?, offsetMs: Double) {
        let decoder = format.flatMap(ScreenAudioDecoder.init)
        let go = state.withLock { s -> Bool? in
            guard !s.stopped else { return nil }
            s.format = format
            s.decoder = decoder
            s.offsetMs = offsetMs
            return decoder != nil
        }
        guard let go else { return }
        guard go, let format else {
            Self.log.error("audio format not playable: \(String(describing: format), privacy: .public)")
            stream.withLock { $0 }?.cancel()
            // the stream's own end doesn't fire after a cancel: say it here
            end()
            onEnd(YoyoError.decoding("screen audio"))
            return
        }
        let token = output.begin(format: format, config: tuning.config(for: format),
                                 fadeIn: tuning.resumed ? ScreenAudioBuffer.resumeFadeIn : nil)
        state.withLock { $0.token = token }
    }

    private func received(_ part: ScreenStreamPart, at arrival: Double) {
        guard part.kind == .audio, let seq = part.headers.audioSeq, let ms = part.headers.audioTime else { return }
        let (decoder, token) = state.withLock { s -> (ScreenAudioDecoder?, Int?) in
            guard !s.stopped else { return (nil, nil) }
            return (s.decoder, s.token)
        }
        guard let decoder, let token else { return }
        // decoded on the stream's queue (a 20 ms packet takes a fraction of a millisecond)
        guard let samples = decoder.decode(part.body) else { return }
        output.push(token: token, seq: seq, macTime: ms / 1000, arrival: arrival, samples: samples, bytes: part.body.count)
    }
}

/// How a stream's jitter buffer is set up: the route's floor (`ScreenAudioBuffer.Config.route`).
struct ScreenAudioTuning: Sendable, Equatable {
    var lan = false
    /// The stream follows one that ended by itself: its sound fades in over `ScreenAudioBuffer.resumeFadeIn`.
    var resumed = false

    init(lan: Bool = false) {
        self.lan = lan
    }

    func config(for format: ScreenAudioFormat) -> ScreenAudioBuffer.Config {
        var c = ScreenAudioBuffer.Config.route(lan: lan)
        c.rate = format.rate
        c.channels = format.channels
        c.packetFrames = format.framesPerPacket
        return c
    }
}

/// The format of the sound stream, from its response's `X-Audio-*` headers. Missing or garbled values take the
/// defaults (Opus, 48 kHz, stereo, 960 frames a packet); nil when the codec or the channel count is one this client
/// doesn't play.
struct ScreenAudioFormat: Sendable, Equatable {
    var codec = "opus"
    var rate: Double = 48_000
    var channels = 2
    var framesPerPacket = 960
    /// `X-Audio-Cookie` (base64), the encoder's magic cookie; nil when absent or not base64.
    var cookie: Data?

    init(rate: Double = 48_000, channels: Int = 2, framesPerPacket: Int = 960, cookie: Data? = nil) {
        self.rate = rate
        self.channels = channels
        self.framesPerPacket = framesPerPacket
        self.cookie = cookie
    }

    /// From a header lookup (names as sent; the lookup decides about case).
    init?(_ value: (String) -> String?) {
        func text(_ name: String) -> String? {
            value(name).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func int(_ name: String) -> Int? { text(name).flatMap { Int($0) } }
        let codec = text("X-Audio-Codec")?.lowercased() ?? "opus"
        guard codec == "opus" else { return nil }
        if let r = int("X-Audio-Rate"), (8_000...192_000).contains(r) { rate = Double(r) }
        if let c = int("X-Audio-Channels"), c > 0 {
            guard c <= 2 else { return nil }
            channels = c
        }
        if let f = int("X-Audio-Frames"), (60...5_760).contains(f) { framesPerPacket = f }
        cookie = text("X-Audio-Cookie").flatMap { Data(base64Encoded: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `X-Audio-Video-Offset` when the header is missing or garbled: this Mac's measured 17.4 ms tap → speaker +
    /// 13.7 ms ScreenCaptureKit capture latency.
    static let defaultVideoOffsetMs: Double = 31

    /// `X-Audio-Video-Offset` (ms, may be negative: add it to `X-Audio-Time` to get the `X-Frame-Time` a real
    /// display's picture of the same instant carries); missing, garbled or beyond ±2 s: `defaultVideoOffsetMs`.
    static func videoOffsetMs(_ value: (String) -> String?) -> Double {
        guard let text = value("X-Audio-Video-Offset")?.trimmingCharacters(in: .whitespaces), let v = Double(text),
              v.isFinite, abs(v) <= 2_000 else { return defaultVideoOffsetMs }
        return v
    }

    /// The jitter buffer for this format.
    var bufferConfig: ScreenAudioBuffer.Config {
        var c = ScreenAudioBuffer.Config()
        c.rate = rate
        c.channels = channels
        c.packetFrames = framesPerPacket
        return c
    }
}

/// When the page opens the sound again after its stream ended (on its own: it doesn't wait for the pictures' stream):
/// - 404: no sound on this computer: not again this visit (nor a stream this client can't play); 403 (not this
///   client's) and 501 (not implemented) likewise, never retried in a loop;
/// - 503: the Mac can't capture its sound now (no permission, sound off, the tap failed): in `unavailableRetry`;
/// - any other end (clean, or a failure): at once; when that keeps happening (more than `quickEndsAllowed` streams in a
///   row that lived under `quickLifetime`), in `failedRetry`.
struct ScreenAudioPolicy: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case giveUp
        case retry(after: Duration)
    }

    static let unavailableRetry: Duration = .seconds(30)
    static let failedRetry: Duration = .seconds(5)
    static let quickLifetime: Duration = .seconds(5)
    static let quickEndsAllowed = 1

    /// Streams in a row that ended within `quickLifetime`.
    private(set) var quickEnds = 0

    mutating func ended(error: Error?, lifetime: Duration) -> Action {
        switch error {
        case YoyoError.http(404, _)?, YoyoError.http(403, _)?, YoyoError.http(501, _)?, YoyoError.decoding?:
            return .giveUp
        case YoyoError.http(503, _)?:
            quickEnds = 0
            return .retry(after: Self.unavailableRetry)
        default:
            quickEnds = lifetime < Self.quickLifetime ? quickEnds + 1 : 0
            return .retry(after: quickEnds > Self.quickEndsAllowed ? Self.failedRetry : .zero)
        }
    }

    /// A new visit, or the sound turned on again.
    mutating func reset() { quickEnds = 0 }
}

/// Opus packets to Float32 PCM, interleaved (AVAudioConverter; no priming trimmed, so every packet keeps its length
/// and its place in time). Used on one queue at a time.
final class ScreenAudioDecoder: @unchecked Sendable {
    let format: ScreenAudioFormat
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter
    private let compressed: AVAudioCompressedBuffer
    private let pcm: AVAudioPCMBuffer
    /// The largest Opus packet (120 ms).
    private static let maxFrames: AVAudioFrameCount = 5_760
    private static let maxPacketBytes = 4_096

    init?(format: ScreenAudioFormat) {
        var asbd = AudioStreamBasicDescription(mSampleRate: format.rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: UInt32(format.framesPerPacket),
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(format.channels),
                                               mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.rate,
                                         channels: AVAudioChannelCount(format.channels), interleaved: true),
              let converter = AVAudioConverter(from: input, to: output),
              let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: Self.maxFrames) else { return nil }
        if let cookie = format.cookie { converter.magicCookie = cookie }
        converter.primeMethod = .none
        self.format = format
        self.input = input
        self.output = output
        self.converter = converter
        self.pcm = pcm
        compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: Self.maxPacketBytes)
    }

    /// The packet's samples (none: a packet that decodes to nothing yet); nil when it doesn't decode.
    func decode(_ packet: Data) -> [Float]? {
        guard !packet.isEmpty, packet.count <= Self.maxPacketBytes else { return nil }
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                               mDataByteSize: UInt32(packet.count))
        pcm.frameLength = 0
        var given = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { [compressed] _, outStatus in
            if given {
                outStatus.pointee = .noDataNow
                return nil
            }
            given = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error else {
            ScreenAudio.log.error("opus decode failed: \(error?.localizedDescription ?? "?", privacy: .public)")
            return nil
        }
        let count = Int(pcm.frameLength) * format.channels
        guard count > 0, let data = pcm.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: count))
    }
}

/// A bounded single-producer / single-consumer queue without locks: a ring of `capacity` pre-allocated slots and two
/// atomic counters (the producer only writes `tail`, the consumer only `head`; release / acquire order the slot's
/// contents). Neither side allocates or frees: an element is moved into its slot and moved out again (`push` copies
/// it in and leaves the caller its own reference; a full ring takes nothing). Elements left at the end are let go
/// in `deinit`, on whichever thread drops the ring. One thread pushes and one pops at a time (the users serialize
/// their side).
final class ScreenAudioRing<Element>: @unchecked Sendable {
    let capacity: Int
    private let slots: UnsafeMutablePointer<Element>
    /// Elements taken out / put in, in all.
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        slots = .allocate(capacity: self.capacity)
    }

    deinit {
        var h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .relaxed)
        while h < t {
            (slots + h % capacity).deinitialize(count: 1)
            h += 1
        }
        slots.deallocate()
    }

    /// Waiting now (exact on either side for its own end).
    var count: Int { tail.load(ordering: .acquiring) - head.load(ordering: .acquiring) }

    /// Producer: room for one more.
    var hasRoom: Bool { tail.load(ordering: .relaxed) - head.load(ordering: .acquiring) < capacity }

    /// Producer: false when full (nothing taken).
    @discardableResult
    func push(_ element: Element) -> Bool {
        let t = tail.load(ordering: .relaxed)
        guard t - head.load(ordering: .acquiring) < capacity else { return false }
        (slots + t % capacity).initialize(to: element)
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    /// Consumer: the oldest element (nil: empty).
    func pop() -> Element? {
        let h = head.load(ordering: .relaxed)
        guard h < tail.load(ordering: .acquiring) else { return nil }
        let element = (slots + h % capacity).move()
        head.store(h + 1, ordering: .releasing)
        return element
    }
}

/// The render thread's numbers for everyone else: a sequence lock over atomic words (the writer makes the count odd,
/// writes, makes it even; a reader retries while it is odd or changed), so a reader gets one callback's numbers whole
/// and the writer never waits. Doubles as their bits (NaN = none).
final class ScreenAudioPublished: @unchecked Sendable {
    enum Field: Int, CaseIterable {
        case depth, buffered, need, floor, bump, lead, leadFormula, leadMeasured, sync, jitter, base, playing, delay,
             soundStartedAt, underruns, late, overflow, cuts, cutFrames, concealed, interruptions, renderedAt, callbacks
    }

    private let sequence = Atomic<UInt64>(0)
    private let words: UnsafeMutablePointer<Atomic<UInt64>>

    init() {
        words = .allocate(capacity: Field.allCases.count)
        for i in 0..<Field.allCases.count { (words + i).initialize(to: Atomic(0)) }
    }

    deinit {
        words.deinitialize(count: Field.allCases.count)
        words.deallocate()
    }

    /// Writer (the render thread): `write` stores with `set`.
    func publish(_ write: (_ set: (Field, Double) -> Void) -> Void) {
        let s = sequence.load(ordering: .relaxed)
        sequence.store(s &+ 1, ordering: .relaxed)
        atomicMemoryFence(ordering: .releasing)
        write { field, value in words[field.rawValue].store(value.bitPattern, ordering: .relaxed) }
        sequence.store(s &+ 2, ordering: .releasing)
    }

    /// Reader: one consistent set of values (nil: never published, or the writer never let go: it writes once per
    /// render callback, a few microseconds every few milliseconds, so a reader nearly always gets them at once).
    func read() -> [Field: Double]? {
        var values = [Field: Double](minimumCapacity: Field.allCases.count)
        for attempt in 0..<100_000 {
            let s1 = sequence.load(ordering: .acquiring)
            guard s1 != 0 else { return nil }
            if s1 & 1 == 1 {
                if attempt % 64 == 63 { sched_yield() }
                continue
            }
            for f in Field.allCases { values[f] = Double(bitPattern: words[f.rawValue].load(ordering: .relaxed)) }
            atomicMemoryFence(ordering: .acquiring)
            if sequence.load(ordering: .relaxed) == s1 { return values }
        }
        return nil
    }
}

/// An item from the stream's queue to the render thread, in stream order.
enum ScreenAudioInboxItem {
    case packet(seq: Int, macTime: Double, arrival: Double, samples: [Float])
    /// A new stream begins (its buffer config; `fadeIn`: its first sound fades in over that long, seconds).
    case newStream(ScreenAudioBuffer.Config, fadeIn: Double?)
    /// The stream ended by itself: no more of its packets come (what's left fades out).
    case endStream
}

/// What one render callback does, and everything it touches: the jitter buffer (owned by the render thread while the
/// output is enabled), the inbox from the stream's queue, the ring that takes spent packets' storage back to the
/// stream's queue (to be freed there), the published numbers, and the atomics the control queue sets. No locks, no
/// allocation, no freeing (see `render`). Made per format; the control queue takes the buffer over only after
/// `disable()` (the callback in progress, if any, has finished).
final class ScreenAudioRender: @unchecked Sendable {
    let format: ScreenAudioFormat
    let inbox = ScreenAudioRing<ScreenAudioInboxItem>(capacity: 512)
    let returns = ScreenAudioRing<[Float]>(capacity: 4_096)
    let published = ScreenAudioPublished()
    /// Interleaved frames handed out per pull (larger render requests take several).
    static let chunk = 1_024

    private let buffer: UnsafeMutablePointer<ScreenAudioBuffer>
    private let scratch: UnsafeMutablePointer<Float>
    private let enabled = Atomic<Bool>(false)
    private let busy = Atomic<Bool>(false)
    /// Bumped by the control queue: the next callback drops what waits (the way out changed).
    private let flushes = Atomic<Int>(0)
    private let io = Atomic<UInt64>(0.005.bitPattern)
    /// The A/V sync depth wanted (NaN: none).
    private let sync = Atomic<UInt64>(Double.nan.bitPattern)
    /// The level wanted (0…1, `setGain`); the render thread glides to it.
    private let gainTarget = Atomic<UInt64>(1.0.bitPattern)
    /// Seconds per host tick.
    private let tick: Double
    /// The format's, plain (the render thread reads no struct with references in it).
    private let channels: Int
    private let rate: Double
    // render thread only
    private var flushesSeen = 0
    private var maxAhead = 0.0
    private var callbacks = 0.0
    /// The level applied now, and the glide's per-frame steps: down quickly, back up more slowly.
    private var gain = 1.0
    private let gainDown: Double
    private let gainUp: Double
    /// A level down this quickly (seconds, time constant) and back up this slowly: a voice over the sound starts clear
    /// at once and the sound comes back gently after it.
    static let gainDownTime = 0.08
    static let gainUpTime = 0.35

    init(format: ScreenAudioFormat) {
        self.format = format
        channels = format.channels
        rate = format.rate
        buffer = .allocate(capacity: 1)
        buffer.initialize(to: ScreenAudioBuffer(config: format.bufferConfig))
        scratch = .allocate(capacity: Self.chunk * max(format.channels, 1))
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        tick = Double(info.numer) / Double(info.denom) / 1e9
        let r = max(format.rate, 1)
        gainDown = 1 - exp(-1 / (r * Self.gainDownTime))
        gainUp = 1 - exp(-1 / (r * Self.gainUpTime))
    }

    deinit {
        buffer.deinitialize(count: 1)
        buffer.deallocate()
        scratch.deallocate()
    }

    // MARK: Control queue

    func enable() { enabled.store(true, ordering: .sequentiallyConsistent) }

    /// No callback touches the buffer after this returns (one in progress is waited for).
    func disable() {
        enabled.store(false, ordering: .sequentiallyConsistent)
        while busy.load(ordering: .sequentiallyConsistent) { usleep(200) }
    }

    func flush() { flushes.add(1, ordering: .releasing) }

    func setIO(_ seconds: Double) { io.store(seconds.bitPattern, ordering: .relaxed) }

    func setSync(_ depth: Double?) { sync.store((depth ?? .nan).bitPattern, ordering: .relaxed) }

    /// The level to glide to (0…1).
    func setGain(_ level: Double) { gainTarget.store(min(max(level, 0), 1).bitPattern, ordering: .relaxed) }

    // MARK: Render thread

    /// One callback: `frames` frames into `data` (deinterleaved Float32), the first heard at the timestamp's host time.
    /// Allocation-free: the inbox's items are moved out of pre-allocated slots into the buffer's reserved arrays, spent
    /// packets' storage is moved into `returns` (freed by the stream's queue), the published numbers are atomic words;
    /// no locks, no Objective-C or Swift runtime calls that allocate.
    func render(frames frameCount: UInt32, timestamp: UnsafePointer<AudioTimeStamp>,
                data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let list = UnsafeMutableAudioBufferListPointer(data)
        let n = Int(frameCount)
        busy.store(true, ordering: .sequentiallyConsistent)
        defer { busy.store(false, ordering: .sequentiallyConsistent) }
        guard enabled.load(ordering: .sequentiallyConsistent) else {
            for b in list { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
            return noErr
        }
        let entry = CACurrentMediaTime()
        let ts = timestamp.pointee
        let now = ts.mFlags.contains(.hostTimeValid) ? Double(ts.mHostTime) * tick : entry
        let b = buffer
        let flushed = flushes.load(ordering: .acquiring)
        let drop = flushed != flushesSeen
        if drop {
            flushesSeen = flushed
            maxAhead = 0
        }
        while let item = inbox.pop() {
            switch item {
            case let .packet(seq, macTime, arrival, samples):
                if drop { _ = returns.push(samples) } else {
                    b.pointee.push(seq: seq, macTime: macTime, arrival: arrival, samples: samples)
                }
            case let .newStream(config, fadeIn):
                b.pointee.newStream(config: config, fadeIn: fadeIn)
            case .endStream:
                b.pointee.endStream()
            }
        }
        if drop { b.pointee.flush() }
        // the lead: the formula, or what this output shows (its render time's lead on the callback, + one IO buffer)
        let ioSeconds = Double(bitPattern: io.load(ordering: .relaxed))
        maxAhead = max(maxAhead, min(max(now - entry, 0), 0.1))
        let formula = 2 * ioSeconds + 0.0015
        let measured = maxAhead + ioSeconds
        b.pointee.setLead(max(formula, measured))
        let target = Double(bitPattern: sync.load(ordering: .relaxed))
        b.pointee.setSync(target.isNaN ? nil : target, at: now)
        let channels = self.channels
        let rate = self.rate
        let level = Double(bitPattern: gainTarget.load(ordering: .relaxed))
        var done = 0
        while done < n {
            let k = min(n - done, Self.chunk)
            b.pointee.pull(into: scratch, frames: k, at: now + Double(done) / rate)
            if gain != level || level != 1 { applyGain(level, frames: k) }
            for c in 0..<min(channels, list.count) {
                guard let out = list[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<k { out[done + f] = scratch[f * channels + c] }
            }
            done += k
        }
        // the played packets' storage goes back to be freed off this thread
        while b.pointee.spentCount > 0, returns.hasRoom {
            if let s = b.pointee.popSpent() { returns.push(s) }
        }
        callbacks += 1
        let st = b.pointee.stats
        published.publish { set in
            set(.depth, st.depth); set(.buffered, st.buffered); set(.need, st.need); set(.floor, st.floor)
            set(.bump, st.bump); set(.lead, st.lead); set(.leadFormula, formula); set(.leadMeasured, measured)
            set(.sync, st.sync ?? .nan); set(.jitter, st.jitter ?? .nan); set(.base, st.base ?? .nan)
            set(.playing, st.playing ? 1 : 0); set(.delay, st.delay ?? .nan); set(.soundStartedAt, st.soundStartedAt ?? .nan)
            set(.underruns, Double(st.underruns)); set(.late, Double(st.late)); set(.overflow, Double(st.overflow))
            set(.cuts, Double(st.cuts)); set(.cutFrames, Double(st.cutFrames)); set(.concealed, Double(st.concealed))
            set(.interruptions, Double(st.interruptions)); set(.renderedAt, now); set(.callbacks, callbacks)
        }
        return noErr
    }

    /// `frames` interleaved frames of `scratch` at the level gliding to `target` (render thread).
    private func applyGain(_ target: Double, frames: Int) {
        let channels = max(self.channels, 1)
        var g = gain
        for f in 0..<frames {
            let d = target - g
            g = abs(d) < 0.0005 ? target : g + d * (d < 0 ? gainDown : gainUp)
            let gf = Float(g)
            for c in 0..<channels { scratch[f * channels + c] *= gf }
        }
        gain = g
    }
}

/// The sound's way out, for the whole Screen page visit: an AVAudioEngine whose source node pulls from the jitter
/// buffer on the output's render thread (`ScreenAudioRender`: no lock, no allocation there), fed by the sound streams
/// the page opens one after another (`begin` starts a new stream in the buffer: a route switch fades out and in instead
/// of stopping the engine). The audio session is `.playback` / `.moviePlayback`, not mixed with other apps' sound
/// unless `mixWithOthers` (`mixWithOthersDefault`: off), with a 5 ms IO buffer asked for (`ioBuffer`), taken
/// once the first packet is there and given back (`notifyOthersOnDeactivation`) only by `stop()`. An interruption (a
/// call, Siri) pauses it and its end restarts it; a route change (headphones, AirPlay, Bluetooth) or a configuration
/// change restarts the engine (the IO buffer, output latency and Bluetooth are read again), and the buffer starts over
/// from the next packet's slot (no burst of what waited meanwhile). Engine and session work happens on one queue
/// shared by every instance (a stopping one gives the session back before the next takes it).
final class ScreenAudioOutput: @unchecked Sendable {
    /// Whether the Mac's sound mixes with the phone's other sound (the user decided 2026-10-25: no, it stops the
    /// phone's music as video players do).
    static let mixWithOthersDefault = false

    struct Settings: Sendable, Equatable {
        /// The IO buffer asked for (seconds; the system may give another).
        var ioBuffer: Double = 0.005
        var mixWithOthers = ScreenAudioOutput.mixWithOthersDefault
        /// The output sets the audio session's category (`.playback`), IO buffer and activation, and gives it back when
        /// it stops. false: the host keeps the session as it set it (e.g. `.playAndRecord` for a microphone of its own):
        /// the output only activates it.
        var managesSession = true
    }

    /// The output's state for the stats, the A/V sync and the report.
    struct Snapshot: Sendable, Equatable {
        var buffer: ScreenAudioBuffer.Stats?
        var leadFormula: Double?
        var leadMeasured: Double?
        /// The session's IO buffer and output latency (seconds), and whether the way out is Bluetooth / AirPlay.
        var io: Double?
        var outputLatency: Double?
        var bluetooth = false
        var kbps: Double = 0
        var rate: Double = 48_000
        /// Host times: the current stream began (`begin`), its first packet came, the last packet with sound came.
        var streamBeganAt: Double?
        var firstPacketAt: Double?
        var lastSoundAt: Double?
        /// The engine runs.
        var running = false
    }

    private static let queue = DispatchQueue(label: "ca.sarria.yoyocontrol.screen-audio", qos: .userInitiated)
    /// Bytes of the last `rateWindow` make the kbps.
    static let rateWindow: Double = 3
    /// A packet whose samples all stay under this is silence (−60 dBFS).
    static let silent: Float = 0.001

    private struct Producer {
        var render: ScreenAudioRender
        var token = 0
        /// A new stream whose marker didn't fit in the inbox yet (and its fade-in).
        var pending: ScreenAudioBuffer.Config?
        var pendingFadeIn: Double?
        /// The end of the current stream, not in the inbox yet.
        var pendingEnd = false
        var arrivals: [(at: Double, bytes: Int)] = []
        var streamBeganAt: Double?
        var firstPacketAt: Double?
        var lastSoundAt: Double?
        var dropped = 0
    }

    private struct Session: Sendable {
        var io: Double?
        var outputLatency: Double?
        var bluetooth = false
        var running = false
    }

    private let producer: Mutex<Producer>
    private let session = Mutex(Session())
    private let reporter = Mutex(ScreenAudioReporter())
    private let settingsBox: Mutex<Settings>
    /// The level (`setVolume`), for a render made later (another format).
    private let volume = Mutex(1.0)
    // on `queue`
    private var render: ScreenAudioRender
    private var engine: AVAudioEngine?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var stopped = false
    private var interrupted = false
    /// No more than one start attempt a second after a failure.
    private var lastFailure: Double?

    init(format: ScreenAudioFormat = ScreenAudioFormat(), settings: Settings = Settings()) {
        let r = ScreenAudioRender(format: format)
        render = r
        producer = Mutex(Producer(render: r))
        settingsBox = Mutex(settings)
    }

    var settings: Settings { settingsBox.withLock { $0 } }

    /// The sound's level, 0…1 (1: as it comes): it glides there (down in about 80 ms, up in about 350 ms).
    func setVolume(_ level: Double) {
        let v = min(max(level, 0), 1)
        volume.withLock { $0 = v }
        producer.withLock { $0.render.setGain(v) }
    }

    /// A new stream of `format` begins (its buffer: `config`; `fadeIn`: its sound fades in over that long, seconds,
    /// nil: the buffer's usual); its packets come with the token returned. Another format (rate, channels) gets a new
    /// buffer and engine.
    func begin(format: ScreenAudioFormat, config: ScreenAudioBuffer.Config, fadeIn: Double? = nil) -> Int {
        let (token, replaced) = producer.withLock { p -> (Int, ScreenAudioRender?) in
            var replaced: ScreenAudioRender?
            if p.render.format.rate != format.rate || p.render.format.channels != format.channels {
                p.render = ScreenAudioRender(format: format)
                p.render.setGain(volume.withLock { $0 })
                replaced = p.render
            }
            p.token += 1
            p.streamBeganAt = CACurrentMediaTime()
            p.firstPacketAt = nil
            p.pending = config
            p.pendingFadeIn = fadeIn
            p.pendingEnd = false
            drainReturns(&p)
            sendPending(&p)
            return (p.token, replaced)
        }
        if let replaced {
            Self.queue.async { [self] in
                render.disable()
                render = replaced
                if started, !interrupted, !buildEngine(flush: false) {
                    started = false
                    lastFailure = CACurrentMediaTime()
                }
            }
        }
        return token
    }

    /// A decoded packet of the stream `token` (an older stream's are dropped).
    func push(token: Int, seq: Int, macTime: Double, arrival: Double, samples: [Float], bytes: Int) {
        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        let sound = peak >= Self.silent
        let ok = producer.withLock { p -> Bool in
            guard token == p.token else { return false }
            drainReturns(&p)
            p.arrivals.append((arrival, bytes))
            while let first = p.arrivals.first, arrival - first.at > Self.rateWindow { p.arrivals.removeFirst() }
            if p.firstPacketAt == nil { p.firstPacketAt = arrival }
            if sound { p.lastSoundAt = arrival }
            sendPending(&p)
            if !p.render.inbox.push(.packet(seq: seq, macTime: macTime, arrival: arrival, samples: samples)) { p.dropped += 1 }
            return true
        }
        guard ok else { return }
        Self.queue.async { [self] in
            guard !started, !stopped, !interrupted else { return }
            let now = CACurrentMediaTime()
            if let lastFailure, now - lastFailure < 1 { return }
            if !startEngine(flush: false) { lastFailure = now }
        }
    }

    /// Spent packets' storage, freed here (the stream's queue).
    private func drainReturns(_ p: inout Producer) {
        while p.render.returns.pop() != nil {}
    }

    private func sendPending(_ p: inout Producer) {
        if let config = p.pending {
            guard p.render.inbox.push(.newStream(config, fadeIn: p.pendingFadeIn)) else { return }
            p.pending = nil
            p.pendingFadeIn = nil
        }
        if p.pendingEnd, p.render.inbox.push(.endStream) { p.pendingEnd = false }
    }

    /// The stream `token` ended by itself (no more of its packets): what it left in the buffer plays out and fades
    /// over its last `ScreenAudioBuffer.endFadeOut`, without counting as an underrun. A newer stream's token: nothing.
    func end(token: Int) {
        producer.withLock { p in
            guard token == p.token else { return }
            drainReturns(&p)
            p.pendingEnd = true
            sendPending(&p)
        }
    }

    /// The A/V sync depth the buffer should move to (the whole depth, seconds; nil: none).
    func setSyncDepth(_ depth: Double?) {
        producer.withLock { $0.render }.setSync(depth)
    }

    func snapshot(at now: Double = CACurrentMediaTime()) -> Snapshot {
        let (values, kbps, began, first, sound, rate) = producer.withLock { p in
            let from = now - Self.rateWindow
            let bytes = p.arrivals.reduce(0) { $0 + ($1.at >= from ? $1.bytes : 0) }
            let span = min(max(now - (p.arrivals.first?.at ?? now), 1), Self.rateWindow)
            return (p.render.published.read(), Double(bytes) * 8 / 1000 / span, p.streamBeganAt, p.firstPacketAt,
                    p.lastSoundAt, p.render.format.rate)
        }
        let s = session.withLock { $0 }
        var snap = Snapshot(io: s.io, outputLatency: s.outputLatency, bluetooth: s.bluetooth, kbps: kbps,
                            streamBeganAt: began, firstPacketAt: first, lastSoundAt: sound, running: s.running)
        snap.rate = rate
        if let v = values {
            func d(_ f: ScreenAudioPublished.Field) -> Double { v[f] ?? .nan }
            func opt(_ f: ScreenAudioPublished.Field) -> Double? { d(f).isNaN ? nil : d(f) }
            func int(_ f: ScreenAudioPublished.Field) -> Int { Int(opt(f) ?? 0) }
            snap.buffer = ScreenAudioBuffer.Stats(
                depth: d(.depth), buffered: d(.buffered), need: d(.need), floor: d(.floor), bump: d(.bump), lead: d(.lead),
                sync: opt(.sync), jitter: opt(.jitter), base: opt(.base), playing: d(.playing) == 1, delay: opt(.delay),
                soundStartedAt: opt(.soundStartedAt), underruns: int(.underruns), late: int(.late),
                overflow: int(.overflow), cuts: int(.cuts), cutFrames: int(.cutFrames), concealed: int(.concealed),
                interruptions: int(.interruptions))
            snap.leadFormula = opt(.leadFormula)
            snap.leadMeasured = opt(.leadMeasured)
        }
        return snap
    }

    /// The playout report's `audio` (counts since the last one), with the page's A/V sync numbers (ms).
    func report(skewMs: Double?, floorMs: Double?, at now: Double = CACurrentMediaTime()) -> ScreenAudioReport? {
        let snap = snapshot(at: now)
        return reporter.withLock { $0.report(snap, skewMs: skewMs, floorMs: floorMs) }
    }

    /// The session goes back; the engine stops. (The page is going, or its sound was turned off.)
    func stop() {
        Self.queue.async { [self] in
            stopped = true
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            let wasStarted = started
            teardown()
            if wasStarted, settings.managesSession {
                let mix = settings.mixWithOthers
                do { try AVAudioSession.sharedInstance().setActive(false, options: mix ? [] : .notifyOthersOnDeactivation) }
                catch { ScreenAudio.log.error("audio session deactivate: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    // MARK: On `queue`

    /// The session, the engine, the observers. false: it didn't start.
    private func startEngine(flush: Bool = true) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let settings = self.settings
        do {
            if settings.managesSession {
                try session.setCategory(.playback, mode: .moviePlayback, options: settings.mixWithOthers ? [.mixWithOthers] : [])
                // before activating (a smaller IO buffer: a smaller lead; netsim: 5 ms)
                try? session.setPreferredIOBufferDuration(settings.ioBuffer)
            }
            try session.setActive(true)
        } catch {
            ScreenAudio.log.error("audio session: \(error.localizedDescription, privacy: .public)")
            return false
        }
        if observers.isEmpty { observe() }
        readSession()
        guard buildEngine(flush: flush) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return false
        }
        started = true
        return true
    }

    /// The IO buffer, output latency and way out, as the session has them now.
    private func readSession() {
        let s = AVAudioSession.sharedInstance()
        let bt: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay]
        let bluetooth = s.currentRoute.outputs.contains { bt.contains($0.portType) }
        let io = s.ioBufferDuration
        let out = s.outputLatency
        render.setIO(io.isFinite && io > 0 ? io : 0.005)
        session.withLock { $0.io = io; $0.outputLatency = out; $0.bluetooth = bluetooth }
        ScreenAudio.log.info("audio output: io \(io * 1000, format: .fixed(precision: 1)) ms, latency \(out * 1000, format: .fixed(precision: 1)) ms\(bluetooth ? ", bluetooth" : "", privacy: .public)")
    }

    private func buildEngine(flush: Bool = true) -> Bool {
        teardown()
        let format = render.format
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: format.rate,
                                      channels: AVAudioChannelCount(format.channels)) else { return false }
        let engine = AVAudioEngine()
        let render = self.render
        let node = AVAudioSourceNode(format: pcm) { _, timestamp, frameCount, data -> OSStatus in
            render.render(frames: frameCount, timestamp: timestamp, data: data)
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: pcm)
        // a restart: what waited while no callback ran goes (its slots are past); the first start plays it
        if flush { render.flush() }
        render.setIO(self.session.withLock { $0.io }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0.005)
        render.enable()
        let begun = CACurrentMediaTime()
        do {
            try engine.start()
        } catch {
            ScreenAudio.log.error("audio engine: \(error.localizedDescription, privacy: .public)")
            render.disable()
            engine.stop()
            return false
        }
        ScreenAudio.log.info("audio engine started in \((CACurrentMediaTime() - begun) * 1000, format: .fixed(precision: 0)) ms")
        self.engine = engine
        session.withLock { $0.running = true }
        return true
    }

    private func teardown() {
        render.disable()
        engine?.stop()
        engine = nil
        session.withLock { $0.running = false }
    }

    private func observe() {
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            Self.queue.async { [weak self] in self?.interruption(type) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            // our own category change isn't a new way out
            guard reason != .categoryChange else { return }
            Self.queue.async { [weak self] in self?.restart() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            Self.queue.async { [weak self] in
                guard let self, self.started, !self.stopped else { return }
                self.teardown()
                self.started = false
                _ = self.startEngine()
            }
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
            Self.queue.async { [weak self] in
                guard let self, let engine = self.engine, sender == ObjectIdentifier(engine) else { return }
                self.restart()
            }
        })
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?) {
        guard !stopped else { return }
        switch type {
        case .began?:
            interrupted = true
            teardown()
            started = false
        case .ended?:
            interrupted = false
            if !startEngine() { lastFailure = CACurrentMediaTime() }
        default:
            break
        }
    }

    /// A new way out: the session's numbers again, the engine again, the buffer from the next slot.
    private func restart() {
        guard !stopped, started, !interrupted else { return }
        readSession()
        if !buildEngine() {
            started = false
            lastFailure = CACurrentMediaTime()
        }
    }
}
