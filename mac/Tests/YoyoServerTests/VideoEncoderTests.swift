import XCTest
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import VideoToolbox
@testable import YoyoServer

// Offline tests for the round-3 video encoder: Annex-B packing (AVCC → start codes, parameter sets on key
// frames) and a real VTCompressionSession → VTDecompressionSession round trip (sizes, PSNR of text-like
// content, the key / delta pattern, forced key frames, a size change). No network.

/// NAL unit type of an H.264 / HEVC NAL (first header byte(s)).
func nalType(_ nal: Data, _ codec: VideoCodec) -> Int {
    codec == .h264 ? Int(nal[nal.startIndex] & 0x1F) : Int((nal[nal.startIndex] >> 1) & 0x3F)
}

/// Parameter-set NAL types: H.264 SPS 7 / PPS 8; HEVC VPS 32 / SPS 33 / PPS 34.
func isParameterSet(_ type: Int, _ codec: VideoCodec) -> Bool {
    codec == .h264 ? type == 7 || type == 8 : (32...34).contains(type)
}

/// Decodes a stream of Annex-B access units (as the parts carry them) with VTDecompressionSession.
final class AnnexBDecoder {
    let codec: VideoCodec
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private(set) var errors = 0

    init(codec: VideoCodec) { self.codec = codec }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    /// Decode one access unit; the BGRA picture, or nil (no parameter sets yet / decode error).
    func decode(_ unit: Data) -> CVPixelBuffer? {
        let nals = VideoEncoder.nalUnits(unit)
        let sets = nals.filter { isParameterSet(nalType($0, codec), codec) }
        if !sets.isEmpty { makeFormat(sets) }
        guard let format, let session = ensureSession(format) else { errors += 1; return nil }
        var avcc = Data()
        for nal in nals where !isParameterSet(nalType(nal, codec), codec) {
            var len = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return nil }
        var block: CMBlockBuffer?
        let mem = UnsafeMutableRawPointer.allocate(byteCount: avcc.count, alignment: 16)
        avcc.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: avcc.count)
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: mem, blockLength: avcc.count, blockAllocator: kCFAllocatorMalloc,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { errors += 1; return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { errors += 1; return nil }
        var out: CVPixelBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr { out = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if status != noErr || out == nil { errors += 1 }
        return out
    }

    private func makeFormat(_ sets: [Data]) {
        let ptrs = sets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { ptrs.forEach { $0.deallocate() } }
        let pointers = ptrs.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var fd: CMFormatDescription?
        let status: OSStatus = pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in
                codec == .h264
                    ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!,
                                                                          parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
                    : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!,
                                                                          parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, extensions: nil,
                                                                          formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let fd else { return }
        if let old = format, CMFormatDescriptionEqual(old, otherFormatDescription: fd) { return }
        format = fd
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    private func ensureSession(_ fd: CMVideoFormatDescription) -> VTDecompressionSession? {
        if let session { return session }
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                           imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &s) == noErr else { return nil }
        session = s
        return s
    }
}

/// Fill a BGRA buffer with a "desktop": light background, a dark title bar, lines of text scrolled by
/// `scroll` px, a coloured icon. Text-like content is the hard case for a video codec.
func paintDesktop(_ buffer: CVPixelBuffer, scroll: Int, seed: Int = 0) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
    ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 0.2, green: 0.22, blue: 0.25, alpha: 1))
    ctx.fill(CGRect(x: 0, y: h - 28, width: w, height: 28))
    ctx.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: w - 60, y: 20, width: 40, height: 40))
    let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
    ]
    for line in 0..<(h / 18 + 2) {
        let y = h - 50 - line * 18 + scroll
        guard y > 0, y < h - 30 else { continue }
        let text = "\(line + seed): The quick brown fox jumps over the lazy dog — 0123456789 {}[]()"
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = CGPoint(x: 12, y: y)
        CTLineDraw(ctLine, ctx)
    }
}

/// PSNR (dB) over the RGB channels of two BGRA buffers of the same size.
func psnr(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let w = min(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b)), h = min(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b))
    let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
    let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
    var se = 0.0
    for y in 0..<h {
        for x in 0..<w {
            for c in 0..<3 {
                let d = Double(pa[y * ra + x * 4 + c]) - Double(pb[y * rb + x * 4 + c])
                se += d * d
            }
        }
    }
    let mse = se / Double(w * h * 3)
    return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
}

final class VideoAnnexBTests: XCTestCase {
    func testAVCCToAnnexBWithParameterSetsFirst() throws {
        // Two NALs with 4-byte lengths.
        let nal1: [UInt8] = [0x65, 1, 2, 3], nal2: [UInt8] = [0x65, 9]
        var avcc = Data([0, 0, 0, 4] + nal1 + [0, 0, 0, 2] + nal2)
        let sps = Data([0x67, 0x42, 0x00]), pps = Data([0x68, 0xCE])
        let out = try XCTUnwrap(VideoEncoder.annexB(avcc, nalLengthSize: 4, parameterSets: [sps, pps]))
        XCTAssertEqual([UInt8](out), [0, 0, 0, 1] + [0x67, 0x42, 0x00] + [0, 0, 0, 1] + [0x68, 0xCE]
                                      + [0, 0, 0, 1] + nal1 + [0, 0, 0, 1] + nal2)
        // A delta: no parameter sets.
        XCTAssertEqual([UInt8](try XCTUnwrap(VideoEncoder.annexB(avcc, nalLengthSize: 4))), [0, 0, 0, 1] + nal1 + [0, 0, 0, 1] + nal2)
        // 2-byte lengths.
        XCTAssertEqual([UInt8](try XCTUnwrap(VideoEncoder.annexB(Data([0, 4] + nal1), nalLengthSize: 2))), [0, 0, 0, 1] + nal1)
        // Malformed: a length past the end, a zero length, a bad length size.
        avcc[3] = 9
        XCTAssertNil(VideoEncoder.annexB(avcc, nalLengthSize: 4))
        XCTAssertNil(VideoEncoder.annexB(Data([0, 0, 0, 0]), nalLengthSize: 4))
        XCTAssertNil(VideoEncoder.annexB(Data([0, 0, 0, 1, 5]), nalLengthSize: 3))
        // And back: the NAL splitter undoes it (3- and 4-byte start codes).
        XCTAssertEqual(VideoEncoder.nalUnits(Data([0, 0, 0, 1] + nal1 + [0, 0, 1] + nal2)).map { [UInt8]($0) }, [nal1, nal2])
    }
}

final class VideoEncoderRoundTripTests: XCTestCase {
    private func roundTrip(_ codec: VideoCodec) throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(codec), "\(codec) low-latency hardware encoder not available")
        let enc = VideoEncoder(codec: codec, bitrate: 3_000_000)
        let dec = AnnexBDecoder(codec: codec)
        let (w, h) = (800, 500)
        var kinds: [Bool] = []
        var sizes: [Int] = []
        var lastPSNR = 0.0
        var t = 0.0
        for i in 0..<8 {
            let buffer = try XCTUnwrap(enc.makeInputBuffer(width: w, height: h))
            paintDesktop(buffer, scroll: i < 6 ? i * 6 : 30)   // scrolling, then still (6 and 7 re-encode the same picture)
            t += i < 6 ? 1.0 / 30 : 0.3
            let unit = try XCTUnwrap(enc.encode(buffer, time: t, forceKey: i == 4), "frame \(i)")
            XCTAssertEqual(unit.width, w); XCTAssertEqual(unit.height, h)
            kinds.append(unit.isKey)
            sizes.append(unit.data.count)
            // Annex-B: starts with a start code; a key frame starts with the parameter sets.
            XCTAssertEqual([UInt8](unit.data.prefix(4)), [0, 0, 0, 1])
            let types = VideoEncoder.nalUnits(unit.data).map { nalType($0, codec) }
            if unit.isKey {
                XCTAssertEqual(Array(types.prefix(codec == .h264 ? 2 : 3)), codec == .h264 ? [7, 8] : [32, 33, 34], "frame \(i) NALs \(types)")
            } else {
                XCTAssertFalse(types.contains { isParameterSet($0, codec) }, "frame \(i) NALs \(types)")
            }
            let picture = try XCTUnwrap(dec.decode(unit.data), "decode \(i)")
            XCTAssertEqual(CVPixelBufferGetWidth(picture), w)
            XCTAssertEqual(CVPixelBufferGetHeight(picture), h)
            lastPSNR = psnr(buffer, picture)
            if i == 0 || i == 5 { XCTAssertGreaterThan(lastPSNR, 28, "frame \(i) PSNR") }
        }
        // Key only at the start and where forced; everything else is a delta.
        XCTAssertEqual(kinds, [true, false, false, false, true, false, false, false])
        XCTAssertEqual(dec.errors, 0)
        // Re-encoding the unchanged picture (6, 7) refines it and costs little once settled.
        XCTAssertGreaterThan(lastPSNR, 32)
        XCTAssertLessThan(sizes[7], sizes[0])
        print("\(codec): sizes \(sizes) bytes, final PSNR \(String(format: "%.1f", lastPSNR)) dB, hw \(enc.isHardware.map(String.init) ?? "?") \(enc.encoderID ?? "?"), flushes \(enc.flushes)")

        // A size change: a new session, whose first picture is a key frame the decoder accepts.
        let small = try XCTUnwrap(enc.makeInputBuffer(width: 640, height: 400))
        paintDesktop(small, scroll: 0)
        let resized = try XCTUnwrap(enc.encode(small, time: t + 0.1))
        XCTAssertTrue(resized.isKey)
        XCTAssertEqual(enc.sessionsCreated, 2)
        let picture = try XCTUnwrap(dec.decode(resized.data))
        XCTAssertEqual(CVPixelBufferGetWidth(picture), 640)
        XCTAssertGreaterThan(psnr(small, picture), 26)
    }

    func testTimingBreakdownAndCalibration() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        let enc = VideoEncoder(codec: .h264, bitrate: 2_500_000)
        for i in 0..<4 {
            let b = try XCTUnwrap(enc.makeInputBuffer(width: 1600, height: 1000))
            VideoEncoder.fillCalibrationPicture(b, shift: i * 12)
            XCTAssertNotNil(enc.encode(b, time: Double(i) / 30))
            let t = enc.lastTiming
            // The submit returns at once; the time is the wait for the hardware; packing is negligible.
            XCTAssertLessThan(t.submitMs, 5)
            XCTAssertLessThan(t.packMs, 3)
            if i > 0 { XCTAssertFalse(t.flushed) }  // (a brand-new session may need one for its first frame)
            print(String(format: "timing: submit %.2f wait %.2f pack %.2f ms", t.submitMs, t.waitMs, t.packMs))
        }
        let prefers = VideoEncoder.prefersAbove1080p(.h264)
        XCTAssertEqual(VideoEncoder.prefersAbove1080p(.h264), prefers)  // cached
        print("prefers pictures above 1080p's area: \(prefers)")
    }

    func testH264RoundTrip() throws { try roundTrip(.h264) }
    func testHEVCRoundTrip() throws { try roundTrip(.hevc) }

    func testBitrateChangesLive() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        let enc = VideoEncoder(codec: .h264, bitrate: 300_000)
        var t = 0.0
        func run(_ n: Int) throws -> Int {
            var total = 0
            for i in 0..<n {
                let b = try XCTUnwrap(enc.makeInputBuffer(width: 800, height: 500))
                paintDesktop(b, scroll: (i * 7) % 90, seed: i)
                t += 1.0 / 30
                switch enc.encodeFrame(b, time: t) {
                case let .unit(u): total += u.data.count
                case .dropped: break  // the low-latency rate control skips pictures it can't afford
                case .failed: XCTFail("encode failed")
                }
            }
            return total
        }
        _ = try run(10)
        let low = try run(20)
        enc.setBitrate(6_000_000)
        _ = try run(5)
        let high = try run(20)
        XCTAssertEqual(enc.sessionsCreated, 1)  // retuned live, not rebuilt
        XCTAssertGreaterThan(high, low * 2, "low \(low) high \(high)")
        print("bitrate: 20 frames at 300 kbps \(low) B, at 6 Mbps \(high) B; drops \(enc.drops)")
    }
}

