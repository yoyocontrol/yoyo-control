#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// H.264 / HEVC encoding for the screen streams (round 3: "video stream + ack + client cursor", see
// docs/PROTOCOL.md 「屏幕」). Fed BGRA CVPixelBuffers of real displays (ScreenCaptureKit).
//
// Latency first: one VTCompressionSession with LOW-LATENCY rate control (hardware only), RealTime, no
// frame reordering (decode order == display order, every output is one displayable picture), key frames
// only when asked (stream start, a client's key request, a size change) plus a 60 s safety. A codec whose session
// can't be made is unavailable (`isAvailable`; the stream takes the other codec, neither = 503). Each output
// access unit is converted to Annex-B (4-byte start codes); a key frame is prefixed with the parameter
// sets (H.264: SPS, PPS; HEVC: VPS, SPS, PPS) from the format description.
//
// The API is synchronous per frame: `encode` submits one picture and waits for its output (the
// low-latency encoder emits it right away; `VTCompressionSessionCompleteFrames` is the fallback if it
// has not after `flushAfter`). The session is (re)created whenever the picture size changes; its first
// output is then a key frame.
//
// Threading: an encoder is used by ONE thread at a time (a stream loop owns it). The VT output handler
// may run on VT's own thread; it hands its result back through `VideoOutputBox` (locked + semaphore).

/// A video codec the screen streams can use.
public enum VideoCodec: String, Sendable, CaseIterable {
    case h264, hevc

    var codecType: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
    /// The part `Content-Type`.
    public var contentType: String { "video/\(rawValue)" }
}

/// One encoded picture: exactly one access unit, Annex-B.
public struct VideoAccessUnit: Sendable {
    public let data: Data
    public let isKey: Bool
    public let width: Int
    public let height: Int
    /// With long-term references on (`VideoEncoder(ltr: true)`): the picture is a long-term reference, and this is
    /// what the encoder wants back once the receiver has it (`VideoEncodeOptions.acknowledgedLTR`).
    var ltrToken: VideoLTRToken? = nil
}

/// A long-term reference picture's acknowledgement token (VideoToolbox's
/// `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken`), opaque.
public final class VideoLTRToken: @unchecked Sendable {
    let value: CFTypeRef
    init(_ value: CFTypeRef) { self.value = value }
}

/// Per-picture options of a long-term-reference encoder (the link's recovery, docs/LINK.md「媒体」).
struct VideoEncodeOptions {
    /// The long-term references the receiver has: the encoder may predict from them (`AcknowledgedLTRTokens`).
    var acknowledgedLTR: [VideoLTRToken] = []
    /// Encode this picture from the newest acknowledged long-term reference (`ForceLTRRefresh`): a P-frame the receiver
    /// decodes without the frames it lost; an IDR when nothing is acknowledged.
    var forceLTRRefresh = false
}

/// What one `encodeFrame` did.
public enum VideoEncodeResult: Sendable {
    case unit(VideoAccessUnit)
    /// The rate control skipped this picture to stay within the bit rate (the coded stream is still
    /// intact: nothing references a dropped picture). Try again later with the newest picture.
    case dropped
    /// The encoder failed; the session was dropped (the next output is a key frame).
    case failed
}

public final class VideoEncoder {
    public let codec: VideoCodec
    /// Whether the session runs on the hardware encoder (nil until one is made).
    public private(set) var isHardware: Bool?
    public private(set) var encoderID: String?
    /// Target average bit rate (bits/s), applied live.
    public private(set) var bitrate: Int
    public let expectedFrameRate: Int
    /// Long-term references asked for (the link's loss recovery): VideoToolbox's `EnableLTR`.
    let ltr: Bool
    /// Whether the session took `EnableLTR` (false: recovery falls back to key frames). nil until one is made.
    private(set) var ltrEnabled: Bool?
    /// Sessions created so far (a size change makes a new one). Test-visible.
    public private(set) var sessionsCreated = 0
    /// How often an output needed `CompleteFrames` (the low-latency encoder normally emits at once).
    public private(set) var flushes = 0
    /// Pictures the rate control dropped.
    public private(set) var drops = 0

    /// Where the last `encodeFrame` spent its time (ms): the EncodeFrame call, the wait for the output handler
    /// after it returned, the Annex-B packing inside the handler, and whether CompleteFrames was needed.
    struct Timing: Sendable {
        var submitMs = 0.0
        var waitMs = 0.0
        var packMs = 0.0
        var flushed = false
    }
    private(set) var lastTiming = Timing()

    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var lastPTS: CMTime = .invalid
    /// Wait this long for the output handler before forcing it out with CompleteFrames.
    static let flushAfter: TimeInterval = 0.04

    public convenience init(codec: VideoCodec, bitrate: Int, expectedFrameRate: Int = 30) {
        self.init(codec: codec, bitrate: bitrate, expectedFrameRate: expectedFrameRate, ltr: false)
    }

    /// `ltr`: long-term reference pictures (`EnableLTR`): outputs carry acknowledgement tokens, and
    /// `VideoEncodeOptions` acknowledge them and force a refresh from them (the link's recovery frames).
    init(codec: VideoCodec, bitrate: Int, expectedFrameRate: Int = 30, ltr: Bool) {
        self.codec = codec
        self.bitrate = max(50_000, bitrate)
        self.expectedFrameRate = expectedFrameRate
        self.ltr = ltr
    }

    deinit { invalidate() }

    public var size: (width: Int, height: Int) { (width, height) }

    /// An IOSurface-backed BGRA buffer of this size from the session's pool ((re)creating the session for a
    /// new size), to fill and pass to `encode`. nil if no session can be made.
    public func makeInputBuffer(width w: Int, height h: Int) -> CVPixelBuffer? {
        guard let session = ensureSession(width: w, height: h),
              let pool = VTCompressionSessionGetPixelBufferPool(session) else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        VideoEncoder.tagColor(buffer)
        return buffer
    }

    /// Tag a BGRA buffer as BT.709 (what the session converts with and signals in the VUI).
    public static func tagColor(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// Change the target bit rate (bits/s) on the live session (and for sessions made later).
    public func setBitrate(_ bps: Int) {
        let b = max(50_000, bps)
        guard b != bitrate else { return }
        bitrate = b
        if let session { VideoEncoder.applyBitrate(session, b) }
    }

    /// Encode one picture. `time` is any monotonic clock in seconds (the presentation time: the low-latency
    /// rate control spends bits by it, so a picture after an idle gap gets more). `forceKey` asks for a key
    /// frame. nil on failure (the session is dropped and rebuilt next time, so the next output is a key).
    public func encode(_ buffer: CVPixelBuffer, time: TimeInterval, forceKey: Bool = false,
                       timeout: TimeInterval = 0.5) -> VideoAccessUnit? {
        if case let .unit(u) = encodeFrame(buffer, time: time, forceKey: forceKey, timeout: timeout) { return u }
        return nil
    }

    /// `encode`, telling a rate-control drop apart from a failure.
    public func encodeFrame(_ buffer: CVPixelBuffer, time: TimeInterval, forceKey: Bool = false,
                            timeout: TimeInterval = 0.5) -> VideoEncodeResult {
        encodeFrame(buffer, time: time, forceKey: forceKey, options: VideoEncodeOptions(), timeout: timeout)
    }

    /// `encodeFrame` with long-term-reference options (an encoder made with `ltr: true`; ignored otherwise).
    func encodeFrame(_ buffer: CVPixelBuffer, time: TimeInterval, forceKey: Bool = false, options: VideoEncodeOptions,
                     timeout: TimeInterval = 0.5) -> VideoEncodeResult {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard let session = ensureSession(width: w, height: h) else { return .failed }
        var pts = CMTime(seconds: time, preferredTimescale: 1_000_000)
        if lastPTS.isValid, pts <= lastPTS { pts = lastPTS + CMTime(value: 1, timescale: 1_000_000) }
        lastPTS = pts
        let box = VideoOutputBox()
        let codec = self.codec
        var frameProps: [CFString: Any] = [:]
        if forceKey { frameProps[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue }
        if ltrEnabled == true {
            if !options.acknowledgedLTR.isEmpty {
                frameProps[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = options.acknowledgedLTR.map(\.value) as CFArray
            }
            if options.forceLTRRefresh, !forceKey { frameProps[kVTEncodeFrameOptionKey_ForceLTRRefresh] = kCFBooleanTrue }
        }
        let props: CFDictionary? = frameProps.isEmpty ? nil : frameProps as CFDictionary
        func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1e6 }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { status, flags, sample in
            if status == noErr, sample == nil || flags.contains(.frameDropped) { box.deliver(.dropped, packMs: 0); return }
            let p0 = DispatchTime.now().uptimeNanoseconds
            guard status == noErr, let sample, let au = VideoEncoder.accessUnit(sample, codec: codec) else { box.deliver(.failed, packMs: 0); return }
            let packMs = Double(DispatchTime.now().uptimeNanoseconds &- p0) / 1e6
            box.deliver(.unit(VideoAccessUnit(data: au.data, isKey: au.isKey, width: w, height: h, ltrToken: VideoEncoder.ltrToken(sample))),
                        packMs: packMs)
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        lastTiming = Timing(submitMs: ms(t0, t1))
        guard status == noErr else {
            log("video: \(codec.rawValue) encode failed (\(status)); rebuilding the session")
            invalidate()
            return .failed
        }
        var result = box.wait(timeout: VideoEncoder.flushAfter)
        if result == nil {
            flushes += 1
            lastTiming.flushed = true
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
            result = box.wait(timeout: timeout)
        }
        lastTiming.waitMs = ms(t1, DispatchTime.now().uptimeNanoseconds)
        lastTiming.packMs = box.packMs
        switch result {
        case let .unit(u)?:
            return .unit(u)
        case .dropped?:
            drops += 1
            return .dropped
        case .failed?, nil:
            // Failed or timed out: rebuild, so the next picture starts a fresh, decodable stream.
            log("video: \(codec.rawValue) produced no output for a frame\(result == nil ? " (timeout)" : ""); rebuilding the session")
            invalidate()
            return .failed
        }
    }

    /// Drop the session (the next `makeInputBuffer` / `encode` makes a new one, starting with a key frame).
    public func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        width = 0
        height = 0
        lastPTS = .invalid
    }

    // MARK: session

    private func ensureSession(width w: Int, height h: Int) -> VTCompressionSession? {
        if let session, w == width, h == height { return session }
        invalidate()
        guard w >= 16, h >= 16 else { return nil }
        guard let created = VideoEncoder.makeSession(codec: codec, width: w, height: h, bitrate: bitrate,
                                                     frameRate: expectedFrameRate, ltr: ltr) else { return nil }
        if ltr {
            ltrEnabled = (VideoEncoder.copyProperty(created, kVTCompressionPropertyKey_EnableLTR) as? Bool) == true
            if ltrEnabled != true { log("video: \(codec.rawValue) session without long-term references (recovery = key frames)") }
        }
        session = created
        width = w
        height = h
        sessionsCreated += 1
        let (hw, id) = VideoEncoder.detectHardware(created)
        encoderID = id
        // The low-latency encoder (`….h264.rtvc` / `….hevc.rtvc`) doesn't answer UsingHardwareAcceleratedVideoEncoder
        // and has no IsHardwareAccelerated in the encoder list; the session was created with hardware REQUIRED, and
        // its software twin is `….rtvc.sw`, so: hardware unless VT says otherwise or handed us the `.sw` one.
        isHardware = id?.hasSuffix(".sw") == true ? false : (hw == true || id?.hasSuffix(".rtvc") == true || hw == nil)
        return created
    }

    /// A session for `codec` at w × h: hardware required, low-latency rate control, RealTime, no frame reordering;
    /// nil when it can't be made (the codec is then unavailable on this Mac).
    ///
    /// Encode latency (measured on an M1 Pro, 1600×1034 desktop, both codecs): ~16 ms, almost all of it the wait
    /// for the hardware (EncodeFrame returns in 0.1 ms, Annex-B packing 0.1 ms, CompleteFrames never needed). None
    /// of MaxFrameDelayCount 0, PrioritizeEncodingSpeedOverQuality, ExpectedFrameRate 60…240,
    /// MaximumRealTimeFrameRate, MaximizePowerEfficiency off, RealTime with a lower Quality, explicit levels,
    /// slices, one reference frame, CAVLC, a regular (non-low-latency) session or NV12 input changed it. What
    /// does: the picture's AREA. Above 1080p's pixel count the encoder switches to a faster configuration
    /// (1792×1158: ~9 ms; 1760×1138: ~19 ms) — see `prefersAbove1080p` and `fastWidth`.
    static func makeSession(codec: VideoCodec, width w: Int, height h: Int, bitrate: Int, frameRate: Int,
                            ltr: Bool = false) -> VTCompressionSession? {
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue,
                    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(w), height: Int32(h), codecType: codec.codecType,
            encoderSpecification: spec, imageBufferAttributes: attrs, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let s = created else {
            log("video: \(codec.rawValue) low-latency session create failed (\(status)) at \(w)x\(h)")
            return nil
        }
        func set(_ key: CFString, _ value: CFTypeRef) -> Bool { VTSessionSetProperty(s, key: key, value: value) == noErr }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        switch codec {
        case .h264:
            if !set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel) {
                _ = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            }
        case .hevc:
            _ = set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        }
        // Key frames only on demand (start, key request, resize); a 60 s safety net.
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 1_000_000))
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 60))
        _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate))
        _ = set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        // Long-term references (the link's loss recovery): verified on Apple silicon for both codecs with low-latency
        // rate control: outputs carry tokens, and ForceLTRRefresh on an acknowledged one gives a P-frame, not an IDR.
        if ltr { _ = set(kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue) }
        applyBitrate(s, bitrate)
        guard VTCompressionSessionPrepareToEncodeFrames(s) == noErr else {
            VTCompressionSessionInvalidate(s)
            return nil
        }
        return s
    }

    /// AverageBitRate plus a 1 s data-rate cap at 1.5x (bounds a burst after an idle gap / a key frame).
    static func applyBitrate(_ s: VTCompressionSession, _ bps: Int) {
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bps))
        let bytesPerSecond = Double(bps) * 1.5 / 8
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: bytesPerSecond), NSNumber(value: 1.0)] as CFArray)
    }

    // MARK: availability

    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var probed: [VideoCodec: Bool] = [:]  // guarded by `probeLock`

    /// Whether this Mac's low-latency hardware session for `codec` actually produces a key frame. Probed once per
    /// process (a 640x360 frame), then cached.
    public static func isAvailable(_ codec: VideoCodec) -> Bool {
        probeLock.lock(); defer { probeLock.unlock() }
        if let known = probed[codec] { return known }
        let enc = VideoEncoder(codec: codec, bitrate: 1_000_000)
        var ok = false
        if let buffer = enc.makeInputBuffer(width: 640, height: 360) {
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0x40, CVPixelBufferGetBytesPerRow(buffer) * 360)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            ok = enc.encode(buffer, time: 0, forceKey: true)?.isKey == true
        }
        log("video: \(codec.rawValue) \(ok ? "available" : "unavailable") (encoder \(enc.encoderID ?? "?"), hardware \(enc.isHardware.map(String.init) ?? "?"))")
        probed[codec] = ok
        return ok
    }

    // MARK: picture size vs encode latency

    /// 1920×1080 in pixels. Pictures with MORE pixels than this encode much faster on the M1 Pro's hardware
    /// encoder (a different internal configuration): 1600×1034 ≈ 16 ms, 1792×1158 (2 075 136 px) ≈ 9 ms, but
    /// 1786×1154 (2 061 044 px, the same macroblock count) ≈ 19 ms — it is the pixel count, not macroblocks.
    static let fastModePixels = 1920 * 1080

    /// The narrowest width from `minWidth` up to `limit` whose picture (`size(width)`: the stream's own scaling,
    /// so the real height) has more than `fastModePixels` pixels; nil if none does (or the source is too
    /// small: `size` returns less than asked).
    static func fastWidth(minWidth: Int, limit: Int, size: (Int) -> (width: Int, height: Int)) -> Int? {
        var w = max(16, minWidth) & ~1
        while w <= limit {
            let s = size(w)
            guard s.width >= w else { return nil }
            if s.width * s.height > fastModePixels { return s.width }
            w += 2
        }
        return nil
    }

    private static let calibrationLock = NSLock()
    nonisolated(unsafe) private static var calibrated: [VideoCodec: Bool] = [:]  // guarded by `calibrationLock`

    /// Measured once per codec and process (~0.5 s): whether a picture just above 1080p's area (1824×1144) encodes
    /// at least 20% faster than a 1600×1000 one on this Mac. If so, streams widen their pictures past that line
    /// (`fastWidth`): lower latency AND a sharper picture, for ~20% more bytes per picture.
    public static func prefersAbove1080p(_ codec: VideoCodec) -> Bool {
        calibrationLock.lock(); defer { calibrationLock.unlock() }
        if let known = calibrated[codec] { return known }
        func median(_ w: Int, _ h: Int) -> Double? {
            let enc = VideoEncoder(codec: codec, bitrate: 2_500_000)
            var times: [Double] = []
            for i in 0..<9 {
                guard let b = enc.makeInputBuffer(width: w, height: h) else { return nil }
                fillCalibrationPicture(b, shift: i * 12)
                let t0 = DispatchTime.now().uptimeNanoseconds
                guard case .unit = enc.encodeFrame(b, time: Double(i) / 30) else { continue }
                if i >= 3 { times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
            }
            guard times.count >= 3 else { return nil }
            return times.sorted()[times.count / 2]
        }
        var result = false
        if let small = median(1600, 1000), let large = median(1824, 1144) {
            result = large < small * 0.8
            log("video: \(codec.rawValue) encode 1600x1000 \(String(format: "%.1f", small)) ms, 1824x1144 \(String(format: "%.1f", large)) ms"
                + (result ? ": streams use pictures above 1080p's area" : ""))
        }
        calibrated[codec] = result
        return result
    }

    /// Start the calibration of both codecs on a background thread (at helper start), so the first stream does
    /// not wait for it. `prefersAbove1080p` blocks only while it is still running.
    public static func calibrateInBackground() {
        Thread.detachNewThread {
            for codec in VideoCodec.allCases where isAvailable(codec) { _ = prefersAbove1080p(codec) }
        }
    }

    /// A desktop-like test picture (light background, rows of dark text-like strokes), scrolled by `shift` rows.
    /// Built from 7 × 18 precomputed rows (cheap even in a debug build).
    static func fillCalibrationPicture(_ buffer: CVPixelBuffer, shift: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var rows = [[UInt32]](repeating: [], count: 7 * 18)
        for line in 0..<7 {
            for inLine in 0..<18 {
                var row = [UInt32](repeating: 0xFFF2_F2F4, count: w)
                if inLine > 3, inLine < 14 {
                    for x in 12..<max(12, w - 40) {
                        let hsh = UInt32(truncatingIfNeeded: (x / 3) &* 2_654_435_761 ^ line &* 40_503 ^ inLine &* 97)
                        if hsh % 5 < 2 { row[x] = 0xFF20_2020 }
                    }
                }
                rows[line * 18 + inLine] = row
            }
        }
        for y in 0..<h {
            let v = y + shift
            rows[((v / 18) % 7) * 18 + v % 18].withUnsafeBytes { src in
                (base + y * stride).copyMemory(from: src.baseAddress!, byteCount: w * 4)
            }
        }
    }

    // MARK: Annex-B

    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// One VT output sample → Annex-B (+ parameter sets on a key frame). nil if malformed.
    static func accessUnit(_ sample: CMSampleBuffer, codec: VideoCodec) -> (data: Data, isKey: Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        guard let (sets, nalLength) = parameterSets(format, codec: codec) else { return nil }
        guard let data = annexB(avcc, nalLengthSize: nalLength, parameterSets: isKey ? sets : []) else { return nil }
        return (data, isKey)
    }

    /// The long-term reference token VideoToolbox attached to an output (nil: not a long-term reference).
    static func ltrToken(_ sample: CMSampleBuffer) -> VideoLTRToken? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let token = attachments.first?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] else { return nil }
        return VideoLTRToken(token as CFTypeRef)
    }

    /// The format description's parameter sets (H.264: SPS, PPS; HEVC: VPS, SPS, PPS) and its NAL length size.
    static func parameterSets(_ format: CMFormatDescription, codec: VideoCodec) -> (sets: [Data], nalLength: Int)? {
        var count = 0
        var nalLength: Int32 = 0
        func get(_ i: Int, _ ptr: UnsafeMutablePointer<UnsafePointer<UInt8>?>?, _ size: UnsafeMutablePointer<Int>?,
                 _ countOut: UnsafeMutablePointer<Int>?, _ nalOut: UnsafeMutablePointer<Int32>?) -> OSStatus {
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: ptr,
                                                                          parameterSetSizeOut: size, parameterSetCountOut: countOut,
                                                                          nalUnitHeaderLengthOut: nalOut)
            case .hevc:
                return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: ptr,
                                                                          parameterSetSizeOut: size, parameterSetCountOut: countOut,
                                                                          nalUnitHeaderLengthOut: nalOut)
            }
        }
        guard get(0, nil, nil, &count, &nalLength) == noErr, count > 0 else { return nil }
        var sets: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard get(i, &ptr, &size, nil, nil) == noErr, let ptr, size > 0 else { return nil }
            sets.append(Data(bytes: ptr, count: size))
        }
        return (sets, Int(nalLength))
    }

    /// Length-prefixed NAL units (`nalLengthSize`-byte big-endian lengths, AVCC / HVCC) → Annex-B with 4-byte
    /// start codes, `parameterSets` first. nil if a length runs past the end (or the size is not 1, 2 or 4).
    public static func annexB(_ avcc: Data, nalLengthSize: Int, parameterSets: [Data] = []) -> Data? {
        guard [1, 2, 4].contains(nalLengthSize) else { return nil }
        var out = Data(capacity: avcc.count + parameterSets.reduce(0) { $0 + $1.count + 4 } + 64)
        for ps in parameterSets {
            out.append(contentsOf: startCode)
            out.append(ps)
        }
        let ok = avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                guard i + nalLengthSize <= bytes.count else { return false }
                var n = 0
                for k in 0..<nalLengthSize { n = (n << 8) | Int(bytes[i + k]) }
                i += nalLengthSize
                guard n > 0, i + n <= bytes.count else { return false }
                out.append(contentsOf: startCode)
                out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[i..<(i + n)]))
                i += n
            }
            return true
        }
        return ok ? out : nil
    }

    /// The NAL units of an Annex-B stream (start codes of 3 or 4 bytes), without their start codes.
    public static func nalUnits(_ annexB: Data) -> [Data] {
        let b = [UInt8](annexB)
        var starts: [(at: Int, len: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 4 <= b.count, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        var out: [Data] = []
        for (k, s) in starts.enumerated() {
            let begin = s.at + s.len
            let end = k + 1 < starts.count ? starts[k + 1].at : b.count
            if end > begin { out.append(Data(b[begin..<end])) }
        }
        return out
    }
}

/// Carries one VT output from the handler to `encode`.
private final class VideoOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var value: VideoEncodeResult?  // guarded by `lock`; nil = nothing yet
    private var pack = 0.0                 // guarded by `lock`

    func deliver(_ v: VideoEncodeResult, packMs: Double) {
        lock.lock(); value = v; pack = packMs; lock.unlock()
        ready.signal()
    }

    var packMs: Double { lock.lock(); defer { lock.unlock() }; return pack }

    /// The output, waiting up to `timeout`; nil = not delivered yet.
    func wait(timeout: TimeInterval) -> VideoEncodeResult? {
        _ = ready.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

extension VideoEncoder {
    /// Whether the session runs on hardware, and its encoder id. An encoder that doesn't answer
    /// `UsingHardwareAcceleratedVideoEncoder` (kVTPropertyNotSupportedErr) is looked up by its EncoderID in the
    /// encoder list.
    static func detectHardware(_ session: VTCompressionSession) -> (Bool?, String?) {
        let encoderID = copyProperty(session, kVTCompressionPropertyKey_EncoderID) as? String
        if let hw = copyProperty(session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) as? Bool {
            return (hw, encoderID)
        }
        guard let encoderID else { return (nil, nil) }
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return (nil, encoderID) }
        let entry = encoders.first { ($0[kVTVideoEncoderList_EncoderID as String] as? String) == encoderID }
        return ((entry?[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) ?? false, encoderID)
    }

    /// A session property, or nil if unsupported. VTSessionCopyProperty hands back a +1 CFTypeRef.
    static func copyProperty(_ session: VTCompressionSession, _ key: CFString) -> CFTypeRef? {
        var raw: UnsafeRawPointer?
        guard VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &raw) == noErr, let raw else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(raw).takeRetainedValue()
    }
}
#endif
