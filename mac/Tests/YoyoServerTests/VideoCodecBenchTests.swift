import XCTest
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
@testable import YoyoServer

// Round-5 codec comparison (OPT-IN). Two tests:
//
// testCodecBench (YOYO_CODEC_BENCH_DIR = a directory of captured frames, `w1792/`, `w1600/`): encodes the frames
// with the production VideoEncoder (low-latency hardware session, the stream's settings) for H.264 and HEVC at a
// ladder of bit rates (YOYO_CODEC_BENCH_KBPS, default 1000,2000,3000,4000,6000,8000), fed at the captured pace with
// the captured times as presentation times; then decodes every access unit with VideoToolbox and compares it with
// its source: luma PSNR and SSIM (BT.709 luma, 8x8 windows). Prints per (width, codec, kbps): bytes/frame, the
// achieved kbps, encode ms p50/p90 (wall, submit → output), PSNR mean / p10, SSIM mean, drops; then the HEVC bit rate
// that matches H.264's quality at each ladder step (interpolated on log-bitrate), and the effect of
// PrioritizeEncodingSpeedOverQuality / MaximizePowerEfficiency (set on a production session).
//
// testEncoderCapabilities (YOYO_VT_CAPS=1): the encoder list, each low-latency / regular hardware session's
// supported ProfileLevel values, and whether 4:2:2 / 4:4:4 (profiles or Y'CbCr input formats) can be encoded:
// the chroma format the bitstream's SPS actually signals.
//
//   YOYO_CODEC_BENCH_DIR=$TMPDIR/frames swift test -c release -Xswiftc -enable-testing --filter VideoCodecBenchTests

final class VideoCodecBenchTests: XCTestCase {
    private func env(_ k: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[k], !v.isEmpty else { return nil }
        return v
    }

    private func line(_ s: String) { FileHandle.standardError.write(Data(("[codec] " + s + "\n").utf8)) }

    private func pct(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * q + 0.5))]
    }

    struct Clip {
        let width: Int, height: Int
        let frames: [Data]       // BGRA, stride width*4
        let timesMs: [Double]
        let luma: [[Float]]      // per frame
    }

    private func loadClip(_ dir: String) throws -> Clip {
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(dir)/index.json"))) as! [String: Any]
        let w = index["width"] as! Int, h = index["height"] as! Int, n = index["count"] as! Int
        let times = index["timesMs"] as! [Double]
        var frames: [Data] = [], luma: [[Float]] = []
        for i in 0..<n {
            let d = try Data(contentsOf: URL(fileURLWithPath: String(format: "%@/f%03d.bgra", dir, i)))
            frames.append(d)
            luma.append(d.withUnsafeBytes { VideoCodecBenchTests.luma(bgra: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), width: w, height: h, stride: w * 4) })
        }
        return Clip(width: w, height: h, frames: frames, timesMs: times, luma: luma)
    }

    /// BT.709 luma (0…255, full range) of a BGRA image.
    static func luma(bgra p: UnsafePointer<UInt8>, width w: Int, height h: Int, stride: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = p + y * stride
            for x in 0..<w {
                let b = Float(row[x * 4]), g = Float(row[x * 4 + 1]), r = Float(row[x * 4 + 2])
                out[y * w + x] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        return out
    }

    static func psnr(_ a: [Float], _ b: [Float]) -> Double {
        var se = 0.0
        for i in 0..<a.count { let d = Double(a[i] - b[i]); se += d * d }
        let mse = se / Double(a.count)
        return mse <= 1e-10 ? 99 : 10 * log10(255 * 255 / mse)
    }

    /// Mean SSIM over non-overlapping 8x8 windows.
    static func ssim(_ a: [Float], _ b: [Float], width w: Int, height h: Int) -> Double {
        let c1: Double = (0.01 * 255) * (0.01 * 255), c2: Double = (0.03 * 255) * (0.03 * 255)
        var total = 0.0, n = 0
        var y = 0
        while y + 8 <= h {
            var x = 0
            while x + 8 <= w {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                for yy in y..<(y + 8) {
                    for xx in x..<(x + 8) {
                        let va = Double(a[yy * w + xx]), vb = Double(b[yy * w + xx])
                        sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb
                    }
                }
                let ma = sa / 64, mb = sb / 64
                let va = saa / 64 - ma * ma, vb = sbb / 64 - mb * mb, cov = sab / 64 - ma * mb
                total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                n += 1
                x += 8
            }
            y += 8
        }
        return n > 0 ? total / Double(n) : 0
    }

    // MARK: decode

    /// Decodes an Annex-B stream (one access unit per call, parameter sets on key frames) to BGRA.
    final class Decoder {
        let codec: VideoCodec
        private var format: CMVideoFormatDescription?
        private var session: VTDecompressionSession?
        init(codec: VideoCodec) { self.codec = codec }
        deinit { if let session { VTDecompressionSessionInvalidate(session) } }

        func nalType(_ n: Data) -> Int { codec == .h264 ? Int(n[n.startIndex] & 0x1F) : Int((n[n.startIndex] >> 1) & 0x3F) }
        func isParameterSet(_ t: Int) -> Bool { codec == .h264 ? (t == 7 || t == 8) : (t >= 32 && t <= 34) }

        func decode(_ au: Data) -> CVPixelBuffer? {
            let nals = VideoEncoder.nalUnits(au)
            let sets = nals.filter { isParameterSet(nalType($0)) }
            if !sets.isEmpty { makeSession(sets) }
            guard let session, let format else { return nil }
            var avcc = Data()
            for n in nals where !isParameterSet(nalType(n)) {
                var len = UInt32(n.count).bigEndian
                avcc.append(Data(bytes: &len, count: 4)); avcc.append(n)
            }
            var block: CMBlockBuffer?
            let count = avcc.count
            let mem = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
            defer { mem.deallocate() }  // decoding is synchronous (waited for below)
            avcc.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: count)
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: mem, blockLength: count, blockAllocator: kCFAllocatorNull,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: count, flags: 0, blockBufferOut: &block) == noErr,
                  let block else { return nil }
            var sample: CMSampleBuffer?
            var size = count
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                            sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
                  let sample else { return nil }
            var out: CVPixelBuffer?
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
                if st == noErr { out = image }
            }
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            return status == noErr ? out : nil
        }

        private func makeSession(_ sets: [Data]) {
            var desc: CMVideoFormatDescription?
            let bytes = sets.map { [UInt8]($0) }
            let ptrs = bytes.map { b -> UnsafePointer<UInt8> in
                let p = UnsafeMutablePointer<UInt8>.allocate(capacity: b.count); p.initialize(from: b, count: b.count); return UnsafePointer(p)
            }
            defer { ptrs.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
            let sizes = bytes.map(\.count)
            let st: OSStatus = codec == .h264
                ? CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                                                                      parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
                : CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                                                                      parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
            guard st == noErr, let desc else { return }
            if let format, CMFormatDescriptionEqual(format, otherFormatDescription: desc), session != nil { return }
            if let session { VTDecompressionSessionInvalidate(session) }
            format = desc
            let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
            var s: VTDecompressionSession?
            VTDecompressionSessionCreate(allocator: nil, formatDescription: desc, decoderSpecification: nil, imageBufferAttributes: attrs,
                                         outputCallback: nil, decompressionSessionOut: &s)
            session = s
        }
    }

    // MARK: encode

    struct RunResult {
        var bytes: [Int] = []
        var encodeMs: [Double] = []
        var psnr: [Double] = []
        var ssim: [Double] = []
        /// PSNR over R, G and B together (shows chroma loss, which luma PSNR does not).
        var psnrRGB: [Double] = []
        var drops = 0
        var keys = 0
        var seconds = 0.0
        var kbps: Double { seconds > 0 ? Double(bytes.reduce(0, +)) * 8 / seconds / 1000 : 0 }
    }

    /// Encode `clip` at `kbps` through `encode` (one picture → Annex-B or nil = dropped), paced like the capture, then
    /// decode + compare.
    private func run(_ clip: Clip, codec: VideoCodec, encode: (CVPixelBuffer, Double, Bool) -> (Data?, Bool, Double),
                     makeBuffer: () -> CVPixelBuffer?) -> RunResult {
        var r = RunResult()
        var units: [(i: Int, data: Data)] = []
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<clip.frames.count {
            let due = t0 + UInt64(clip.timesMs[i] * 1e6)
            let now = DispatchTime.now().uptimeNanoseconds
            if due > now { StrictTiming.sleep(Double(due - now) / 1e9) }
            guard let buf = makeBuffer() else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!, stride = CVPixelBufferGetBytesPerRow(buf)
            clip.frames[i].withUnsafeBytes { src in
                for y in 0..<clip.height { (base + y * stride).copyMemory(from: src.baseAddress! + y * clip.width * 4, byteCount: clip.width * 4) }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            let (data, key, ms) = encode(buf, clip.timesMs[i] / 1000, i == 0)
            r.encodeMs.append(ms)
            if let data { units.append((i, data)); r.bytes.append(data.count); if key { r.keys += 1 } } else { r.drops += 1 }
        }
        r.seconds = (clip.timesMs.last! - clip.timesMs.first!) / 1000 + (clip.timesMs.count > 1 ? (clip.timesMs.last! - clip.timesMs.first!) / 1000 / Double(clip.timesMs.count - 1) : 0)
        let dec = Decoder(codec: codec)
        for (i, d) in units {
            guard let img = dec.decode(d) else { continue }
            CVPixelBufferLockBaseAddress(img, .readOnly)
            let p = CVPixelBufferGetBaseAddress(img)!.assumingMemoryBound(to: UInt8.self)
            let y = VideoCodecBenchTests.luma(bgra: p, width: min(clip.width, CVPixelBufferGetWidth(img)), height: min(clip.height, CVPixelBufferGetHeight(img)),
                                              stride: CVPixelBufferGetBytesPerRow(img))
            if CVPixelBufferGetWidth(img) >= clip.width, CVPixelBufferGetHeight(img) >= clip.height {
                let stride = CVPixelBufferGetBytesPerRow(img)
                r.psnrRGB.append(clip.frames[i].withUnsafeBytes { src -> Double in
                    let a = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    var se = 0.0
                    for yy in 0..<clip.height {
                        let ra = a + yy * clip.width * 4, rb = p + yy * stride
                        for x in 0..<(clip.width * 4) where x & 3 != 3 { let d = Double(ra[x]) - Double(rb[x]); se += d * d }
                    }
                    let mse = se / Double(clip.width * clip.height * 3)
                    return mse <= 1e-10 ? 99 : 10 * log10(255 * 255 / mse)
                })
            }
            CVPixelBufferUnlockBaseAddress(img, .readOnly)
            guard y.count == clip.luma[i].count else { continue }
            r.psnr.append(VideoCodecBenchTests.psnr(clip.luma[i], y))
            r.ssim.append(VideoCodecBenchTests.ssim(clip.luma[i], y, width: clip.width, height: clip.height))
        }
        return r
    }

    private func productionRun(_ clip: Clip, codec: VideoCodec, kbps: Int) -> RunResult {
        let enc = VideoEncoder(codec: codec, bitrate: kbps * 1000, expectedFrameRate: 60)
        return run(clip, codec: codec, encode: { buf, t, key in
            let t0 = DispatchTime.now().uptimeNanoseconds
            let res = enc.encodeFrame(buf, time: t, forceKey: key)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if case let .unit(u) = res { return (u.data, u.isKey, ms) }
            return (nil, false, ms)
        }, makeBuffer: { enc.makeInputBuffer(width: clip.width, height: clip.height) })
    }

    /// A production session (`VideoEncoder.makeSession`) with `extra` properties set on top, driven synchronously.
    private func tweakedRun(_ clip: Clip, codec: VideoCodec, kbps: Int, extra: [(CFString, CFTypeRef)]) -> (RunResult, [String]) {
        guard let s = VideoEncoder.makeSession(codec: codec, width: clip.width, height: clip.height, bitrate: kbps * 1000, frameRate: 60) else {
            return (RunResult(), ["no session"])
        }
        defer { VTCompressionSessionInvalidate(s) }
        var notes: [String] = []
        for (k, v) in extra {
            let st = VTSessionSetProperty(s, key: k, value: v)
            var got: CFTypeRef?
            let rs = VTSessionCopyProperty(s, key: k, allocator: nil, valueOut: &got)
            notes.append("\(k)=\(v) set \(st) read \(rs == noErr ? "\(got.map { "\($0)" } ?? "nil")" : "\(rs)")")
        }
        let pool = VTCompressionSessionGetPixelBufferPool(s)
        let r = run(clip, codec: codec, encode: { buf, t, key in
            var out: (Data?, Bool) = (nil, false)
            let sem = DispatchSemaphore(value: 0)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(s, imageBuffer: buf, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 1_000_000),
                                            duration: .invalid, frameProperties: props, infoFlagsOut: nil) { st, _, sample in
                if st == noErr, let sample, let au = VideoEncoder.accessUnit(sample, codec: codec) { out = (au.data, au.isKey) }
                sem.signal()
            }
            if sem.wait(timeout: .now() + 0.04) == .timedOut {
                VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
                _ = sem.wait(timeout: .now() + 0.5)
            }
            return (out.0, out.1, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }, makeBuffer: {
            var b: CVPixelBuffer?
            guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b) == kCVReturnSuccess, let b else { return nil }
            VideoEncoder.tagColor(b)
            return b
        })
        return (r, notes)
    }

    private func describe(_ r: RunResult) -> String {
        let mean = r.bytes.isEmpty ? 0 : r.bytes.reduce(0, +) / r.bytes.count
        let psnr = r.psnr.isEmpty ? Double.nan : r.psnr.reduce(0, +) / Double(r.psnr.count)
        let ssim = r.ssim.isEmpty ? Double.nan : r.ssim.reduce(0, +) / Double(r.ssim.count)
        let rgb = r.psnrRGB.isEmpty ? Double.nan : r.psnrRGB.reduce(0, +) / Double(r.psnrRGB.count)
        return String(format: "%6d B/frame, %5.0f kbps, encode p50 %.1f p90 %.1f ms, PSNR-Y %.2f (p10 %.2f), PSNR-RGB %.2f, SSIM %.4f, drops %d, keys %d, decoded %d",
                      mean, r.kbps, pct(r.encodeMs, 0.5), pct(r.encodeMs, 0.9), psnr, pct(r.psnr, 0.1), rgb, ssim, r.drops, r.keys, r.psnr.count)
    }

    /// Run `body` on a `.userInteractive` thread, like the stream loops (VT's encoder service inherits the QoS).
    private func onInteractiveThread(_ body: @escaping () throws -> Void) throws {
        final class Box: @unchecked Sendable { var error: Error? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let t = Thread { do { try body() } catch { box.error = error }; done.signal() }
        t.qualityOfService = .userInteractive
        t.stackSize = 8 << 20
        t.start()
        done.wait()
        if let e = box.error { throw e }
    }

    func testCodecBench() throws {
        guard let dir = env("YOYO_CODEC_BENCH_DIR") else { throw XCTSkip("set YOYO_CODEC_BENCH_DIR (a frame capture)") }
        try onInteractiveThread { try self.codecBench(dir) }
    }

    private func codecBench(_ dir: String) throws {
        let ladder = (env("YOYO_CODEC_BENCH_KBPS") ?? "1000,2000,3000,4000,6000,8000").split(separator: ",").compactMap { Int($0) }
        let widths = (env("YOYO_CODEC_BENCH_WIDTHS") ?? "1792,1600").split(separator: ",").compactMap { Int($0) }
        for w in widths {
            let clip = try loadClip("\(dir)/w\(w)")
            line("clip \(clip.width)x\(clip.height), \(clip.frames.count) frames over \(Int(clip.timesMs.last!)) ms")
            var curves: [VideoCodec: [(kbps: Double, psnr: Double, ssim: Double)]] = [:]
            for codec in VideoCodec.allCases {
                _ = productionRun(clip, codec: codec, kbps: 4000)  // warm the hardware path
                for kbps in ladder {
                    let r = productionRun(clip, codec: codec, kbps: kbps)
                    line("\(w) \(codec.rawValue) @\(kbps): \(describe(r))")
                    if !r.psnr.isEmpty {
                        curves[codec, default: []].append((r.kbps, r.psnr.reduce(0, +) / Double(r.psnr.count), r.ssim.reduce(0, +) / Double(r.ssim.count)))
                    }
                }
            }
            // HEVC kbps for H.264's quality at each step (log-linear interpolation on HEVC's PSNR curve).
            if let h = curves[.h264], let e = curves[.hevc]?.sorted(by: { $0.psnr < $1.psnr }), e.count >= 2 {
                for p in h {
                    var match: Double?
                    for (a, b) in zip(e, e.dropFirst()) where p.psnr >= a.psnr && p.psnr <= b.psnr && b.psnr > a.psnr {
                        let t = (p.psnr - a.psnr) / (b.psnr - a.psnr)
                        match = exp(log(a.kbps) + t * (log(b.kbps) - log(a.kbps)))
                    }
                    line("\(w) equal PSNR \(String(format: "%.2f", p.psnr)) dB: h264 \(Int(p.kbps)) kbps vs hevc \(match.map { "\(Int($0)) kbps (\(Int(($0 / p.kbps - 1) * 100))%)" } ?? "out of range")")
                }
            }
            if w == widths.first, env("YOYO_CODEC_BENCH_TWEAKS") != "0" {
                for codec in VideoCodec.allCases {
                    let base = tweakedRun(clip, codec: codec, kbps: 4000, extra: [])
                    line("\(w) \(codec.rawValue) @4000 production session: \(describe(base.0))")
                    for (name, extra) in [("PrioritizeEncodingSpeedOverQuality=true", [(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue as CFTypeRef)]),
                                          ("MaximizePowerEfficiency=true", [(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanTrue as CFTypeRef)]),
                                          ("MaximizePowerEfficiency=false", [(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse as CFTypeRef)])] {
                        let (r, notes) = tweakedRun(clip, codec: codec, kbps: 4000, extra: extra)
                        line("\(w) \(codec.rawValue) @4000 \(name): \(describe(r)) [\(notes.joined(separator: "; "))]")
                    }
                }
            }
        }
    }

    // MARK: 4:4:4 cost

    /// A REGULAR (not low-latency) hardware session, real time, no reordering, the stream's bit rate rules; `yuv444`
    /// = 4:4:4 8-bit Y'CbCr input (the encoder then codes 4:4:4: HEVC RExt / H.264 High 4:4:4).
    private func regularSession(codec: VideoCodec, width w: Int, height h: Int, kbps: Int, yuv444: Bool) -> VTCompressionSession? {
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        let attrs = [kCVPixelBufferPixelFormatTypeKey: yuv444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
                     kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        var s: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: codec.codecType, encoderSpecification: spec,
                                         imageBufferAttributes: attrs, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                         compressionSessionOut: &s) == noErr, let s else { return nil }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: 1_000_000))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 60))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VideoEncoder.applyBitrate(s, kbps * 1000)
        guard VTCompressionSessionPrepareToEncodeFrames(s) == noErr else { VTCompressionSessionInvalidate(s); return nil }
        return s
    }

    private func sessionRun(_ clip: Clip, codec: VideoCodec, session s: VTCompressionSession, yuv444: Bool) -> (RunResult, Double) {
        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        var convertMs: [Double] = []
        let pool = VTCompressionSessionGetPixelBufferPool(s)
        var pending: CVPixelBuffer?
        let r = run(clip, codec: codec, encode: { buf, t, key in
            var input = buf
            if yuv444, let transfer, let pool {
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                if let out {
                    VideoEncoder.tagColor(out)
                    let c0 = DispatchTime.now().uptimeNanoseconds
                    VTPixelTransferSessionTransferImage(transfer, from: buf, to: out)
                    convertMs.append(Double(DispatchTime.now().uptimeNanoseconds - c0) / 1e6)
                    input = out
                }
            }
            var result: (Data?, Bool) = (nil, false)
            let sem = DispatchSemaphore(value: 0)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            VTCompressionSessionEncodeFrame(s, imageBuffer: input, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 1_000_000),
                                            duration: .invalid, frameProperties: props, infoFlagsOut: nil) { st, _, sample in
                if st == noErr, let sample, let au = VideoEncoder.accessUnit(sample, codec: codec) { result = (au.data, au.isKey) }
                sem.signal()
            }
            if sem.wait(timeout: .now() + 0.04) == .timedOut {
                VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
                _ = sem.wait(timeout: .now() + 0.5)
            }
            return (result.0, result.1, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }, makeBuffer: {
            // BGRA source buffers (converted above for 4:4:4)
            if !yuv444, let pool { var b: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &b); if let b { VideoEncoder.tagColor(b) }; return b }
            if pending == nil {
                var b: CVPixelBuffer?
                CVPixelBufferCreate(nil, clip.width, clip.height, kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &b)
                if let b { VideoEncoder.tagColor(b) }
                pending = b
            }
            return pending
        })
        return (r, pct(convertMs, 0.5))
    }

    func testChroma444Cost() throws {
        guard let dir = env("YOYO_CODEC_BENCH_DIR"), env("YOYO_CODEC_444") == "1" else { throw XCTSkip("YOYO_CODEC_BENCH_DIR + YOYO_CODEC_444=1") }
        try onInteractiveThread {
            let clip = try self.loadClip("\(dir)/w1792")
            let kbps = Int(self.env("YOYO_CODEC_444_KBPS") ?? "") ?? 4000
            for codec in VideoCodec.allCases {
                self.line("444 \(codec.rawValue) @\(kbps) production low-latency 4:2:0: \(self.describe(self.productionRun(clip, codec: codec, kbps: kbps)))")
                for yuv444 in [false, true] {
                    guard let s = self.regularSession(codec: codec, width: clip.width, height: clip.height, kbps: kbps, yuv444: yuv444) else {
                        self.line("444 \(codec.rawValue) regular \(yuv444 ? "4:4:4" : "4:2:0"): no session"); continue
                    }
                    var id: CFTypeRef?
                    VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &id)
                    let (r, conv) = self.sessionRun(clip, codec: codec, session: s, yuv444: yuv444)
                    VTCompressionSessionInvalidate(s)
                    self.line("444 \(codec.rawValue) @\(kbps) regular \(id.map { "\($0)" } ?? "?") \(yuv444 ? "4:4:4 (BGRA→444v \(String(format: "%.1f", conv)) ms)" : "4:2:0"): \(self.describe(r))")
                }
            }
        }
    }

    // MARK: capabilities

    /// Exp-Golomb reader over an RBSP (emulation-prevention bytes removed).
    struct Bits {
        let b: [UInt8]; var i = 0
        init(_ nal: Data, skip: Int) {
            var out: [UInt8] = []; var zeros = 0
            for (k, x) in nal.enumerated() where k >= skip {
                if zeros >= 2 && x == 3 { zeros = 0; continue }
                zeros = x == 0 ? zeros + 1 : 0
                out.append(x)
            }
            b = out
        }
        mutating func bit() -> Int { defer { i += 1 }; return i / 8 < b.count ? Int(b[i / 8] >> (7 - UInt8(i % 8))) & 1 : 0 }
        mutating func bits(_ n: Int) -> Int { (0..<n).reduce(0) { a, _ in (a << 1) | bit() } }
        mutating func ue() -> Int { var z = 0; while bit() == 0 && z < 32 { z += 1 }; return (1 << z) - 1 + bits(z) }
    }

    /// (profile_idc, chroma_format_idc) from a key frame's SPS.
    static func spsInfo(_ au: Data, codec: VideoCodec) -> (profile: Int, chroma: Int)? {
        for n in VideoEncoder.nalUnits(au) {
            if codec == .h264, n[n.startIndex] & 0x1F == 7 {
                var r = Bits(n, skip: 1)
                let profile = r.bits(8); _ = r.bits(16); _ = r.ue()
                let chroma = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) ? r.ue() : 1
                return (profile, chroma)
            }
            if codec == .hevc, (n[n.startIndex] >> 1) & 0x3F == 33 {
                var r = Bits(n, skip: 2)
                _ = r.bits(4); let subLayers = r.bits(3); _ = r.bit()
                _ = r.bits(2); _ = r.bit(); let profile = r.bits(5)
                _ = r.bits(32); _ = r.bits(48); _ = r.bits(8)   // compatibility flags, constraint flags, level
                if subLayers > 0 { return (profile, -1) }       // (not parsed: sub-layer PTL)
                _ = r.ue()
                return (profile, r.ue())
            }
        }
        return nil
    }

    func testEncoderCapabilities() throws {
        try XCTSkipUnless(env("YOYO_VT_CAPS") == "1", "set YOYO_VT_CAPS=1")
        var list: CFArray?
        VTCopyVideoEncoderList(nil, &list)
        for e in (list as? [[String: Any]]) ?? [] {
            let type = (e[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value ?? 0
            guard [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha].contains(type) else { continue }
            line("encoder \(e[kVTVideoEncoderList_EncoderID as String] ?? "?") hw=\(e[kVTVideoEncoderList_IsHardwareAccelerated as String] ?? "-")"
                 + " name=\(e[kVTVideoEncoderList_DisplayName as String] ?? "?")")
        }
        let (w, h) = (1792, 1158)
        for codec in VideoCodec.allCases {
            for lowLatency in [true, false] {
                var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
                if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
                var s: VTCompressionSession?
                let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: codec.codecType,
                                                    encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                    outputCallback: nil, refcon: nil, compressionSessionOut: &s)
                guard st == noErr, let s else { line("\(codec.rawValue) lowLatency=\(lowLatency): create failed \(st)"); continue }
                var dict: CFDictionary?
                VTSessionCopySupportedPropertyDictionary(s, supportedPropertyDictionaryOut: &dict)
                let d = (dict as? [String: Any]) ?? [:]
                let profiles = ((d[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any])?[kVTPropertySupportedValueListKey as String] as? [String]) ?? []
                var id: CFTypeRef?
                VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &id)
                line("\(codec.rawValue) lowLatency=\(lowLatency) encoder \(id.map { "\($0)" } ?? "?"): ProfileLevel values \(profiles)")
                let interesting = ["PrioritizeEncodingSpeedOverQuality", "MaximizePowerEfficiency", "ConstantBitRate", "SpatialAdaptiveQPLevel",
                                   "MinAllowedFrameQP", "MaxAllowedFrameQP", "EnableLTR", "ReferenceBufferCount", "SuggestedLookAheadFrameCount"]
                line("  supports: " + interesting.map { k in "\(k)=\(d.keys.contains { $0.hasSuffix(k) } ? "yes" : "no")" }.joined(separator: ", "))
                VTCompressionSessionInvalidate(s)
            }
        }
        // Try 4:2:2 / 4:4:4: profiles and Y'CbCr input formats, on the low-latency and the regular hardware encoder.
        let formats: [(String, OSType)] = [("BGRA", kCVPixelFormatType_32BGRA),
                                           ("420v", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                           ("422v", kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange),
                                           ("444v", kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange),
                                           ("x422", kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
                                           ("x444", kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)]
        let profiles: [VideoCodec: [(String, CFString?)]] = [
            .h264: [("default", nil), ("High", kVTProfileLevel_H264_High_AutoLevel)],
            .hevc: [("default", nil), ("Main", kVTProfileLevel_HEVC_Main_AutoLevel), ("Main10", kVTProfileLevel_HEVC_Main10_AutoLevel),
                    ("Main42210", kVTProfileLevel_HEVC_Main42210_AutoLevel)],
        ]
        for codec in VideoCodec.allCases {
            for lowLatency in [true, false] {
                for (pname, profile) in profiles[codec]! {
                    for (fname, fmt) in formats {
                        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
                        if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
                        let attrs = [kCVPixelBufferPixelFormatTypeKey: fmt, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                     kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
                        var s: VTCompressionSession?
                        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: codec.codecType,
                                                            encoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs, compressedDataAllocator: nil,
                                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
                        guard st == noErr, let s else { line("  \(codec.rawValue) ll=\(lowLatency) \(pname) \(fname): create \(st)"); continue }
                        defer { VTCompressionSessionInvalidate(s) }
                        var pst: OSStatus = noErr
                        if let profile { pst = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: profile) }
                        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
                        guard VTCompressionSessionPrepareToEncodeFrames(s) == noErr, let pool = VTCompressionSessionGetPixelBufferPool(s) else {
                            line("  \(codec.rawValue) ll=\(lowLatency) \(pname) \(fname): prepare failed"); continue
                        }
                        var buf: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buf)
                        guard let buf else { line("  \(codec.rawValue) ll=\(lowLatency) \(pname) \(fname): no buffer"); continue }
                        CVPixelBufferLockBaseAddress(buf, [])
                        for p in 0..<max(1, CVPixelBufferGetPlaneCount(buf)) {
                            let planar = CVPixelBufferIsPlanar(buf)
                            if let a = planar ? CVPixelBufferGetBaseAddressOfPlane(buf, p) : CVPixelBufferGetBaseAddress(buf) {
                                memset(a, Int32(0x60 + p * 0x10), (planar ? CVPixelBufferGetBytesPerRowOfPlane(buf, p) * CVPixelBufferGetHeightOfPlane(buf, p)
                                                                   : CVPixelBufferGetBytesPerRow(buf) * h))
                            }
                        }
                        CVPixelBufferUnlockBaseAddress(buf, [])
                        var au: Data?
                        let sem = DispatchSemaphore(value: 0)
                        let est = VTCompressionSessionEncodeFrame(s, imageBuffer: buf, presentationTimeStamp: .zero, duration: .invalid,
                                                                  frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary,
                                                                  infoFlagsOut: nil) { st, _, sample in
                            if st == noErr, let sample { au = VideoEncoder.accessUnit(sample, codec: codec)?.data }
                            sem.signal()
                        }
                        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
                        _ = sem.wait(timeout: .now() + 2)
                        var id: CFTypeRef?
                        VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &id)
                        let info = au.flatMap { VideoCodecBenchTests.spsInfo($0, codec: codec) }
                        line("  \(codec.rawValue) ll=\(lowLatency) \(pname) \(fname): profile set \(pst), encode \(est), "
                             + "SPS profile_idc \(info.map { "\($0.profile)" } ?? "-") chroma_format_idc \(info.map { "\($0.chroma)" } ?? "-") (1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4)"
                             + " encoder \(id.map { "\($0)" } ?? "?")")
                    }
                }
            }
        }
    }
}
