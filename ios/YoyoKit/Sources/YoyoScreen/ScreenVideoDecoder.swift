import AVFoundation
import CoreImage
import CoreMedia
import QuartzCore
import Synchronization
import UIKit
import VideoToolbox
import YoyoClipboard
import YoyoCore

/// The video codecs of the screen stream's `video/h264` / `video/hevc` parts: one access unit (one picture) per part,
/// Annex-B (start codes), parameter sets in front of every key picture, no reordering.
enum ScreenVideoCodec: Sendable, Equatable {
    case h264, hevc

    init?(_ kind: ScreenStreamPart.Kind) {
        switch kind {
        case .h264: self = .h264
        case .hevc: self = .hevc
        default: return nil
        }
    }

    var name: String { self == .h264 ? "h264" : "hevc" }

    /// The type of a NAL unit from its first header byte.
    func nalType(_ header: UInt8) -> UInt8 {
        switch self {
        case .h264: header & 0x1F
        case .hevc: (header >> 1) & 0x3F
        }
    }

    /// Rank of a parameter set in the order the format description wants them (VPS, SPS, PPS); nil for other units.
    func parameterSetRank(_ type: UInt8) -> Int? {
        switch self {
        case .h264: type == 7 ? 1 : type == 8 ? 2 : nil
        case .hevc: type == 32 ? 0 : type == 33 ? 1 : type == 34 ? 2 : nil
        }
    }

    /// A random access picture (H.264 IDR; HEVC BLA / IDR / CRA).
    func isKeyPicture(_ type: UInt8) -> Bool {
        switch self {
        case .h264: type == 5
        case .hevc: (16...21).contains(type)
        }
    }

    /// Units a sample doesn't carry: access unit delimiters (and the parameter sets, which go in the format).
    func isDelimiter(_ type: UInt8) -> Bool {
        switch self {
        case .h264: type == 9
        case .hevc: type == 35
        }
    }

    /// The codecs to ask for, in preference order (the Mac follows it): HEVC first only where it decodes in hardware.
    static func requestedCodecs(hevcInHardware: @autoclosure () -> Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) -> [ScreenCodec] {
        hevcInHardware() ? [.hevc, .h264] : [.h264]
    }
}

/// Annex-B byte streams and their length-prefixed (AVCC / HVCC) form.
enum AnnexB {
    /// The NAL units of an Annex-B byte stream (3- or 4-byte start codes), without their start codes. Emulation
    /// prevention bytes stay as they are (VideoToolbox wants them); bytes before the first start code are dropped.
    static func nalUnits(_ data: Data) -> [Data] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Data] in
            let b = raw.bindMemory(to: UInt8.self)
            guard let base = b.baseAddress else { return [] }
            let n = b.count
            var units: [Data] = []
            var start: Int?
            var i = 0
            while i + 2 < n {
                // 00 00 01 (a 4-byte code is a zero byte before it); a byte > 1 at i + 2 rules out i, i + 1 and i + 2
                if b[i + 2] > 1 { i += 3; continue }
                if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                    if let s = start {
                        var end = i
                        if end > s, b[end - 1] == 0 { end -= 1 }
                        if end > s { units.append(Data(bytes: base + s, count: end - s)) }
                    }
                    start = i + 3
                    i += 3
                } else {
                    i += 1
                }
            }
            if let s = start, s < n { units.append(Data(bytes: base + s, count: n - s)) }
            return units
        }
    }

    /// The units, each behind its 4-byte big-endian length.
    static func lengthPrefixed(_ units: [Data]) -> Data {
        var out = Data(capacity: units.reduce(0) { $0 + 4 + $1.count })
        for u in units {
            let len = UInt32(u.count)
            out.append(contentsOf: [UInt8(len >> 24), UInt8(len >> 16 & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF)])
            out.append(u)
        }
        return out
    }

    /// The format description the parameter sets describe (4-byte NAL lengths); nil when they don't make one.
    static func formatDescription(_ codec: ScreenVideoCodec, parameterSets: [Data]) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty, parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }
        let copies = parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = parameterSets.map(\.count)
        var format: CMFormatDescription?
        let status = switch codec {
        case .h264:
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        case .hevc:
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    /// One sample of the length-prefixed units, for `format`.
    static func sampleBuffer(_ lengthPrefixed: Data, format: CMFormatDescription) -> CMSampleBuffer? {
        let n = lengthPrefixed.count
        guard n > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: n, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = lengthPrefixed.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: n)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = n
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }
}

/// "Video keeps failing": `limit` failures within `window` seconds.
struct VideoFailureTracker {
    var limit = 3
    var window: Duration = .seconds(10)
    private var times: [ContinuousClock.Instant] = []

    init(limit: Int = 3, window: Duration = .seconds(10)) { self.limit = limit; self.window = window }

    /// Records a failure; true when that makes `limit` within the window.
    mutating func record(_ now: ContinuousClock.Instant = .now) -> Bool {
        times.append(now)
        times.removeAll { now - $0 > window }
        return times.count >= limit
    }
}

/// The decoding itself, synchronous and single-threaded (`ScreenVideoDecoder` runs it on its queue; tests call it
/// directly). Builds the format from the parameter sets of key pictures (again when they change), converts each
/// access unit to a length-prefixed sample and decodes it with a real-time VTDecompressionSession, synchronously (no
/// frames queue up inside VideoToolbox). Until a key picture arrives, and after a decode error or a gap, deltas are
/// dropped and a key picture is asked for.
final class ScreenVideoDecoderCore {
    enum Outcome {
        /// A decoded picture and how long decoding took (ms).
        case picture(CVPixelBuffer, Double)
        /// Dropped: waiting for a key picture (`requestKey`: ask for one now).
        case waitingForKey(requestKey: Bool)
        /// The decoder failed on this part; a key picture is needed (and asked for).
        case failed
        /// Video doesn't work here (the format can't be made, key pictures never come, decoding keeps failing): the
        /// stream ends and is tried again later.
        case unplayable
    }

    let codec: ScreenVideoCodec
    private(set) var needKey = true
    private var parameterSets: [Data] = []
    private(set) var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var failures = VideoFailureTracker()
    /// Since when deltas are dropped waiting for a key picture, and when one was last asked for.
    private var waitingSince: ContinuousClock.Instant?
    private var askedAt: ContinuousClock.Instant?

    /// Ask again for a key picture after this long without one; give up on video after `giveUpAfter`.
    static let askAgainAfter: Duration = .seconds(1)
    static let giveUpAfter: Duration = .seconds(5)

    init(codec: ScreenVideoCodec) { self.codec = codec }

    deinit { invalidate() }

    /// Parts were lost: the next delta can't be decoded.
    func gap() { needKey = true }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    func decode(_ part: ScreenStreamPart, now: ContinuousClock.Instant = .now) -> Outcome {
        let units = AnnexB.nalUnits(part.body)
        var sets: [(rank: Int, data: Data)] = []
        var slices: [Data] = []
        var keyUnit = false
        for u in units {
            guard let header = u.first else { continue }
            let type = codec.nalType(header)
            if let rank = codec.parameterSetRank(type) { sets.append((rank, u)); continue }
            if codec.isDelimiter(type) { continue }
            if codec.isKeyPicture(type) { keyUnit = true }
            slices.append(u)
        }
        let isKey = part.headers.kind == "key" || keyUnit
        // a uu Link recovery picture: a delta on a reference the decoder still holds (the link checked its chain)
        let startsChain = isKey || part.headers.kind == "recovery"
        if isKey, !sets.isEmpty {
            let ordered = sets.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element.data)
            if ordered != parameterSets || format == nil {
                guard let f = AnnexB.formatDescription(codec, parameterSets: ordered) else { return .unplayable }
                if let session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: f) { invalidate() }
                format = f
                parameterSets = ordered
            }
        }
        guard !slices.isEmpty else { return .waitingForKey(requestKey: false) }
        if needKey, !startsChain || format == nil { return waiting(now) }
        guard let format else { return waiting(now) }
        if session == nil {
            session = Self.makeSession(format)
            guard session != nil else { return .unplayable }
        }
        guard let session, let sample = AnnexB.sampleBuffer(AnnexB.lengthPrefixed(slices), format: format) else {
            return failure(now)
        }
        let started = ContinuousClock.now
        let result = DecodeResult()
        // synchronous (no asynchronous-decompression flag), and no 1x-playback hint: that one lets the decoder slow
        // down to save power
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: nil) { status, _, image, _, _ in
            result.set(status, image)
        }
        if status == noErr { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        let (decodeStatus, image) = result.get()
        guard status == noErr, decodeStatus == noErr, let image else {
            // a session the system tore down (the app was in the background) is made again on the next key picture
            if status == kVTInvalidSessionErr { invalidate() }
            return failure(now)
        }
        needKey = false
        waitingSince = nil
        askedAt = nil
        return .picture(image, (ContinuousClock.now - started).milliseconds)
    }

    private func waiting(_ now: ContinuousClock.Instant) -> Outcome {
        needKey = true
        let since = waitingSince ?? now
        waitingSince = since
        if now - since > Self.giveUpAfter { return .unplayable }
        if let askedAt, now - askedAt < Self.askAgainAfter { return .waitingForKey(requestKey: false) }
        askedAt = now
        return .waitingForKey(requestKey: true)
    }

    private func failure(_ now: ContinuousClock.Instant) -> Outcome {
        needKey = true
        if failures.record(now) { return .unplayable }
        waitingSince = waitingSince ?? now
        askedAt = now
        return .failed
    }

    private static func makeSession(_ format: CMVideoFormatDescription) -> VTDecompressionSession? {
        // the decoder's own pixel format (no conversion), IOSurface-backed for the display layer (the loupe's Metal
        // reads it too). Not "Metal compatible": with that the decoder hands out compressed `&8v0` pictures instead.
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return nil }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        return session
    }

    /// The output handler's result (it runs before a synchronous decode returns).
    private final class DecodeResult: @unchecked Sendable {
        private let lock = NSLock()
        private var status: OSStatus = -1
        private var image: CVImageBuffer?
        func set(_ s: OSStatus, _ i: CVImageBuffer?) { lock.withLock { status = s; image = i } }
        func get() -> (OSStatus, CVImageBuffer?) { lock.withLock { (status, image) } }
    }
}

/// Where decoded pictures go: an `AVSampleBufferDisplayLayer`'s renderer, fed from the decoder's queue or the playout
/// thread (`ScreenPlayer`; the renderer is made for enqueueing from a background thread), each picture marked to
/// display immediately. Keeps the newest picture shown for `snapshot()`. The renderer is the picture view's that shows
/// the session now (`attach`; none: the pictures are only kept); a renderer attached later gets the newest picture at
/// once. Any number of sinks get the pictures too (`addSink`: the loupe, which draws them with Metal, only while it
/// shows; a host's own, e.g. for Picture in Picture), each the newest one at once when it starts.
final class ScreenVideoOutput: @unchecked Sendable {
    typealias Sink = @Sendable (CVPixelBuffer) -> Void

    /// Guards everything below (pictures come from the decoders' queues or the playout thread, the rest from main).
    private let lock = NSLock()
    private var renderer: AVSampleBufferVideoRenderer?
    private var format: CMVideoFormatDescription?
    private var last: CVPixelBuffer?
    private var sinks: [Int: (sink: Sink, active: Bool)] = [:]
    private var nextSink = 1
    /// The sink `init`'s `mirror` is (`setMirroring`).
    private static let mirrorSink = 0

    init(renderer: AVSampleBufferVideoRenderer? = nil, mirror: Sink? = nil) {
        self.renderer = renderer
        if let mirror { sinks[Self.mirrorSink] = (mirror, false) }
    }

    func show(_ image: CVPixelBuffer) {
        let (format, renderer, sinks) = lock.withLock { () -> (CMVideoFormatDescription?, AVSampleBufferVideoRenderer?, [Sink]) in
            last = image
            let active = self.sinks.values.filter(\.active).map(\.sink)
            if let f = self.format, CMVideoFormatDescriptionMatchesImageBuffer(f, imageBuffer: image) { return (f, self.renderer, active) }
            var f: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &f)
            self.format = f
            return (f, self.renderer, active)
        }
        if let renderer, let format, let sample = Self.sample(image, format: format) { Self.enqueue(sample, into: renderer) }
        for sink in sinks { sink(image) }
    }

    /// The pictures go to `renderer` from now on (nil: to none), starting with the newest.
    func attach(_ renderer: AVSampleBufferVideoRenderer?) {
        let (image, format) = lock.withLock { () -> (CVPixelBuffer?, CMVideoFormatDescription?) in
            self.renderer = renderer
            attaches += 1
            return (last, self.format)
        }
        guard let renderer, let image, let format, let sample = Self.sample(image, format: format) else { return }
        Self.enqueue(sample, into: renderer)
    }

    /// The renderer the pictures go to now, and how many times one was attached (the tests: a picture view that
    /// moves isn't attached again).
    var attachedRenderer: AVSampleBufferVideoRenderer? { lock.withLock { renderer } }
    var attachCount: Int { lock.withLock { attaches } }
    private var attaches = 0

    /// `renderer` goes, if it is the one attached.
    func detach(_ renderer: AVSampleBufferVideoRenderer) {
        lock.withLock { if self.renderer === renderer { self.renderer = nil } }
    }

    /// A sink of every picture while `active` (`setSink`); its id.
    func addSink(active: Bool, _ sink: @escaping Sink) -> Int {
        let (id, image) = lock.withLock { () -> (Int, CVPixelBuffer?) in
            let id = nextSink
            nextSink += 1
            sinks[id] = (sink, active)
            return (id, active ? last : nil)
        }
        if let image { sink(image) }
        return id
    }

    /// The sink gets every picture from now on (true, starting with the newest) / none (false).
    func setSink(_ id: Int, active on: Bool) {
        let started = lock.withLock { () -> (Sink, CVPixelBuffer)? in
            guard let s = sinks[id], s.active != on else { return nil }
            sinks[id] = (s.sink, on)
            guard on, let last else { return nil }
            return (s.sink, last)
        }
        if let (sink, image) = started { sink(image) }
    }

    func removeSink(_ id: Int) { lock.withLock { _ = sinks.removeValue(forKey: id) } }

    /// The mirror (`init`'s) gets every picture from now on (true, starting with the newest) / none (false).
    func setMirroring(_ on: Bool) { setSink(Self.mirrorSink, active: on) }

    private static func sample(_ image: CVPixelBuffer, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private static func enqueue(_ sample: CMSampleBuffer, into renderer: AVSampleBufferVideoRenderer) {
        // a renderer that failed (e.g. while the app was in the background) or holds a backlog starts over
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding || !renderer.isReadyForMoreMediaData {
            renderer.flush()
        }
        renderer.enqueue(sample)
    }

    /// Drops what's shown (another display).
    func clear() {
        let renderer = lock.withLock { () -> AVSampleBufferVideoRenderer? in
            last = nil
            return self.renderer
        }
        renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// The newest picture as an image (for whatever needs a still: a stream that ended, or video that failed, keeps it
    /// on screen). The pixel buffer outlives the decoder that made it.
    func snapshot() -> UIImage? {
        newest().flatMap(Self.still(of:))
    }

    /// The newest picture, for `still(of:)` elsewhere (nil: none yet).
    func newest() -> Picture? {
        lock.withLock { last }.map(Picture.init)
    }

    /// A picture handed to another thread to be made a still (only read there).
    struct Picture: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// `picture` as an image: a GPU conversion and a copy of the whole picture (tens of ms at full size): off the main
    /// thread where it can be (`stills`). Any thread.
    static func still(of picture: Picture) -> UIImage? {
        let image = CIImage(cvPixelBuffer: picture.buffer)
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Where stills are made off the main thread (the picture view's freeze).
    static let stills = DispatchQueue(label: "ca.sarria.yoyocontrol.screen-still", qos: .userInitiated)

    /// Made once (a context is costly to make; a snapshot is taken on every stream end). Thread-safe.
    private static let context = CIContext(options: [.cacheIntermediates: false])
}

/// Decodes one stream's video parts off the main thread and shows them. Parts are decoded in order on a private
/// queue, as soon as they arrive. Low latency (no `playout`): when several wait, all are decoded (deltas depend on each
/// other) but only the newest picture is shown (`ScreenVideoOutput`), so a slow moment never builds a lag. Smooth
/// playback: every picture goes to the `ScreenPlayer` with its `X-Frame-Time` and arrival, which shows each at its
/// time (and drops what it must); `onPicture` is then not called (the player reports what it shows). After
/// `invalidate()` nothing more is shown or reported. Thread-safe: the core is only touched on `queue`.
final class ScreenVideoDecoder: @unchecked Sendable {
    /// A picture was shown: its size in pixels (the part's `X-Frame-Width/Height`, else the decoded size), the decode
    /// time (ms) and its part. Called on the decoder's queue.
    typealias OnPicture = @Sendable (CGSize, Double, Shown) -> Void

    /// The part of a shown picture: its `X-Frame-Seq`, and a live picture's `X-Frame-Time` (seconds; nil for refine /
    /// keepalive pictures, whose time is the original's).
    struct Shown: Sendable, Equatable {
        var seq: Int?
        var macTime: Double?

        init(_ part: ScreenStreamPart) {
            seq = part.seq
            macTime = part.isLivePicture ? part.headers.time.map { $0 / 1000 } : nil
        }
    }

    private enum Item { case part(ScreenStreamPart, arrival: Double?), gap }
    private struct State {
        var pending: [Item] = []
        var busy = false
        var invalidated = false
        var failed = false
    }

    let codec: ScreenVideoCodec
    private let core: ScreenVideoDecoderCore
    private let output: ScreenVideoOutput?
    private let playout: ScreenPlayer?
    private let onKeyframeNeeded: @Sendable () -> Void
    private let onPicture: OnPicture
    private let onUnplayable: @Sendable () -> Void
    /// Each part's outcome: decoded (true) or not (dropped waiting for a key picture, failed). On the decoder's queue.
    private let onDecoded: (@Sendable (ScreenStreamPart, Bool) -> Void)?
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "ca.sarria.yoyocontrol.screen-video", qos: .userInteractive)

    /// More waiting parts than this: decoding can't keep up; they are dropped and a key picture asked for.
    static let maxBacklog = 16

    init(codec: ScreenVideoCodec, output: ScreenVideoOutput?, playout: ScreenPlayer? = nil,
         onKeyframeNeeded: @escaping @Sendable () -> Void, onPicture: @escaping OnPicture,
         onUnplayable: @escaping @Sendable () -> Void, onDecoded: (@Sendable (ScreenStreamPart, Bool) -> Void)? = nil) {
        self.onDecoded = onDecoded
        self.codec = codec
        core = ScreenVideoDecoderCore(codec: codec)
        self.output = output
        self.playout = playout
        self.onKeyframeNeeded = onKeyframeNeeded
        self.onPicture = onPicture
        self.onUnplayable = onUnplayable
    }

    /// `arrival`: when the part was complete (host time; the playout times pictures by it).
    func submit(_ part: ScreenStreamPart, arrival: Double? = nil) { enqueue(.part(part, arrival: arrival)) }

    /// Parts were lost (a seq gap): deltas wait for the next key picture.
    func gap() { enqueue(.gap) }

    func invalidate() {
        state.withLock { $0.invalidated = true; $0.pending = [] }
        queue.async { [self] in core.invalidate() }
    }

    private func enqueue(_ item: Item) {
        let (start, overflow) = state.withLock { s -> (Bool, Bool) in
            guard !s.invalidated, !s.failed else { return (false, false) }
            var overflow = false
            if s.pending.count >= Self.maxBacklog {
                s.pending = [.gap]
                overflow = true
            }
            s.pending.append(item)
            if s.busy { return (false, overflow) }
            s.busy = true
            return (true, overflow)
        }
        if overflow { onKeyframeNeeded() }
        if start { queue.async { [self] in drain() } }
    }

    /// On `queue`: decodes everything waiting, shows the newest picture (or hands each to the player), repeats until
    /// nothing waits.
    private func drain() {
        while true {
            let items = state.withLock { s -> [Item]? in
                if s.pending.isEmpty || s.invalidated { s.busy = false; s.pending = []; return nil }
                defer { s.pending = [] }
                return s.pending
            }
            guard let items else { return }
            var newest: (CVPixelBuffer, CGSize, Double, Shown)?
            var askKey = false
            var unplayable = false
            for item in items {
                switch item {
                case .gap:
                    core.gap()
                case .part(let part, let arrival):
                    let outcome = core.decode(part)
                    if let onDecoded {
                        if case .picture = outcome { onDecoded(part, true) } else { onDecoded(part, false) }
                    }
                    switch outcome {
                    case .picture(let image, let ms):
                        let size = if let w = part.width, let h = part.height { CGSize(width: w, height: h) }
                            else { CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image)) }
                        if let playout {
                            guard !state.withLock({ $0.invalidated }) else { break }
                            playout.push(ScreenPlayer.Picture(image: image, size: size, decodeMs: ms, frame: part.linkFrame),
                                         macTime: part.headers.time.map { $0 / 1000 }, sample: part.isLivePicture,
                                         arrival: arrival ?? CACurrentMediaTime())
                        } else {
                            newest = (image, size, ms, Shown(part))
                        }
                    case .waitingForKey(let ask):
                        askKey = askKey || ask
                    case .failed:
                        askKey = true
                    case .unplayable:
                        unplayable = true
                    }
                }
                if unplayable { break }
            }
            if unplayable {
                let first = state.withLock { s -> Bool in
                    defer { s.failed = true; s.pending = [] }
                    return !s.failed && !s.invalidated
                }
                core.invalidate()
                if first { onUnplayable() }
                state.withLock { $0.busy = false }
                return
            }
            if askKey, !state.withLock({ $0.invalidated }) { onKeyframeNeeded() }
            if let (image, size, ms, shown) = newest, !state.withLock({ $0.invalidated }) {
                output?.show(image)
                onPicture(size, ms, shown)
            }
        }
    }
}
