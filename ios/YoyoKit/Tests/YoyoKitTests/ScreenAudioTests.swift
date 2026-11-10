import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The Mac's sound on the Screen page (`POST /screen/audio`): its parts in the stream framing (and the picture stream
/// ignoring them), the `X-Audio-*` headers, when the page tries again, and the jitter buffer with injected times.
@Suite("Screen audio")
struct ScreenAudioTests {
    // MARK: Parts

    private static func part(_ body: Data, type: String = "audio/opus", seq: String? = "7",
                             time: String? = "1761170000123") -> Data {
        var head = "--frame\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        if let seq { head += "X-Audio-Seq: \(seq)\r\n" }
        if let time { head += "X-Audio-Time: \(time)\r\n" }
        var d = Data((head + "\r\n").utf8)
        d.append(body)
        d.append(Data("\r\n".utf8))
        return d
    }

    @Test func audioContentTypesAreAudioParts() {
        #expect(ScreenStreamPart.Kind(contentType: "audio/opus") == .audio)
        #expect(ScreenStreamPart.Kind(contentType: "Audio/Opus; rate=48000") == .audio)
        #expect(ScreenStreamPart.Kind(contentType: "audio/aac") == .audio)
        #expect(ScreenStreamPart.Kind(contentType: "application/vnd.yoyo-control.audio") == .other)
        #expect(!ScreenStreamPart.Kind.audio.isPicture)
    }

    @Test func theAudioStreamParsesIntoAudioPartsWithTheirSeqAndTime() throws {
        var a = StreamPartAssembler()
        // the stream's own head: not multipart/x-mixed-replace (URLSession would split that), the boundary all the same
        _ = try a.receive(status: 200, contentType: "application/vnd.yoyo-control.audio; boundary=frame", expectedLength: -1)
        var body = Self.part(Data([1, 2, 3]), seq: "7", time: "1761170000123")
        body.append(Self.part(Data([4, 5]), seq: "8", time: "1761170000143"))
        var parts: [ScreenStreamPart] = []
        // split anywhere
        for byte in body { parts += a.feed(Data([byte])) }
        #expect(parts.map(\.kind) == [.audio, .audio])
        #expect(parts.map(\.body) == [Data([1, 2, 3]), Data([4, 5])])
        #expect(parts.map(\.headers.audioSeq) == [7, 8])
        #expect(parts.map(\.headers.audioTime) == [1_761_170_000_123, 1_761_170_000_143])
        // the picture headers aren't the sound's
        #expect(parts[0].seq == nil && parts[0].headers.time == nil)
        #expect(!a.split)
    }

    @Test func garbledAudioPartHeadersAreNil() {
        for (seq, time) in [("abc", "nan"), ("-1", "1e400"), ("", " "), ("1.5", "x1")] {
            let h = ScreenPartHeaders(block: "Content-Type: audio/opus\r\nX-Audio-Seq: \(seq)\r\nX-Audio-Time: \(time)")
            #expect(h.audioSeq == nil && h.audioTime == nil, "\(seq) / \(time)")
        }
        let ok = ScreenPartHeaders(block: "content-type: audio/opus\r\nx-audio-seq:  42 \r\nx-audio-time: 1761170000123.5")
        #expect(ok.audioSeq == 42 && ok.audioTime == 1_761_170_000_123.5)
        #expect(ScreenPartHeaders(block: "Content-Type: audio/opus").audioSeq == nil)
    }

    @Test func aHugeAudioPartIsSkippedAndTheNextStillParses() {
        var p = StreamPartParser(boundary: "frame")
        var body = Self.part(Data(count: ScreenStreamPart.maxAudioPart + 1), seq: "1")
        body.append(Self.part(Data([9]), seq: "2"))
        let parts = p.feed(body)
        #expect(parts.map(\.headers.audioSeq) == [2])
    }

    @Test func thePictureStreamIgnoresAudioParts() {
        let sent = Mutex<[ScreenStreamAck]>([])
        let acks = ScreenAckSender(stream: "s1", transport: { ack, done in
            sent.withLock { $0.append(ack) }
            done(.ok)
        })
        let cursors = Mutex(0)
        let router = ScreenStreamRouter(acks: acks, stats: nil, handlers: .init(
            makeDecoder: { _ in Issue.record("no decoder for sound"); return nil },
            onCursor: { _ in cursors.withLock { $0 += 1 } }))
        router.route(ScreenStreamPart(kind: .audio, body: Data([1, 2, 3]),
                                      headers: ScreenPartHeaders(contentType: "audio/opus", seq: 1, audioSeq: 1, audioTime: 1)))
        #expect(sent.withLock { $0 }.isEmpty && cursors.withLock { $0 } == 0)
        router.stop()
    }

    // MARK: Format

    @Test func theFormatComesFromTheHeaders() throws {
        let cookie = Data([0x4F, 0x70, 0x75, 0x73])
        let headers = ["x-audio-codec": "Opus", "x-audio-rate": "24000", "x-audio-channels": "1", "x-audio-frames": "480",
                       "x-audio-cookie": cookie.base64EncodedString()]
        let f = try #require(ScreenAudioFormat { headers[$0.lowercased()] })
        #expect(f.rate == 24_000 && f.channels == 1 && f.framesPerPacket == 480 && f.cookie == cookie)
        #expect(f.bufferConfig.rate == 24_000 && f.bufferConfig.channels == 1 && f.bufferConfig.packetFrames == 480)
    }

    @Test func missingOrGarbledFormatHeadersTakeTheDefaults() throws {
        let none = try #require(ScreenAudioFormat { _ in nil })
        #expect(none == ScreenAudioFormat())
        #expect(none.rate == 48_000 && none.channels == 2 && none.framesPerPacket == 960 && none.cookie == nil)
        let garbage = ["x-audio-rate": "fast", "x-audio-channels": "-2", "x-audio-frames": "99999999999999999999",
                       "x-audio-cookie": "!!not base64!!", "x-audio-codec": "  "]
        #expect(ScreenAudioFormat { garbage[$0.lowercased()] } == ScreenAudioFormat())
        let odd = ["x-audio-rate": "0", "x-audio-channels": "0", "x-audio-frames": "1", "x-audio-cookie": ""]
        #expect(ScreenAudioFormat { odd[$0.lowercased()] } == ScreenAudioFormat())
    }

    @Test func aFormatThisClientDoesNotPlayIsNil() {
        #expect(ScreenAudioFormat { $0 == "X-Audio-Codec" ? "aac" : nil } == nil)
        #expect(ScreenAudioFormat { $0 == "X-Audio-Channels" ? "6" : nil } == nil)
    }

    @Test func theDecoderIsMadeForTheDefaultFormat() throws {
        // AudioToolbox has an Opus decoder on iOS; a packet that isn't Opus doesn't crash it
        let decoder = try #require(ScreenAudioDecoder(format: ScreenAudioFormat()))
        _ = decoder.decode(Data([0xFF, 0x00, 0x13]))
        #expect(decoder.decode(Data()) == nil)
    }

    /// Opus packets as the Mac makes them (AVAudioConverter, 960 frames, 48 kHz stereo) of a 440 Hz tone; nil where
    /// this system has no Opus encoder.
    private static func opusPackets(_ count: Int) -> (packets: [Data], cookie: Data?)? {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)
        else { return nil }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd), let encoder = AVAudioConverter(from: pcm, to: opus) else {
            return nil
        }
        encoder.bitRate = 96_000
        var packets: [Data] = []
        var frame = 0
        for _ in 0..<(count * 4) where packets.count < count {
            let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 1,
                                              maximumPacketSize: max(encoder.maximumOutputPacketSize, 1_500))
            var error: NSError?
            let status = encoder.convert(to: out, error: &error) { _, inStatus in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 960) else {
                    inStatus.pointee = .noDataNow
                    return nil
                }
                buffer.frameLength = 960
                for f in 0..<960 {
                    let v = Float(sin(2 * Double.pi * 440 * Double(frame + f) / 48_000) * 0.5)
                    buffer.floatChannelData![0][f] = v
                    buffer.floatChannelData![1][f] = v
                }
                frame += 960
                inStatus.pointee = .haveData
                return buffer
            }
            guard status != .error else { return nil }
            if out.packetCount > 0, out.byteLength > 0 { packets.append(Data(bytes: out.data, count: Int(out.byteLength))) }
        }
        return (packets, encoder.magicCookie)
    }

    @Test func opusPacketsDecodeToTheirFrames() throws {
        // (the simulator has one, as the Mac does)
        guard let (packets, cookie) = Self.opusPackets(25), packets.count == 25 else { return }
        let decoder = try #require(ScreenAudioDecoder(format: ScreenAudioFormat(cookie: cookie)))
        var energy: Float = 0
        var frames: [Int] = []
        for packet in packets {
            let samples = try #require(decoder.decode(packet))
            frames.append(samples.count / 2)
            energy += samples.reduce(0) { $0 + $1 * $1 }
        }
        // the first packet comes out a little short (840 frames here: the codec's delay), then every one is 20 ms
        #expect((1...960).contains(frames[0]))
        #expect(frames.dropFirst().allSatisfy { $0 == 960 }, "\(frames)")
        // the tone comes back (0.5 amplitude: 0.125 a sample)
        #expect(energy / Float(frames.reduce(0, +) * 2) > 0.1)
    }

    // MARK: Policy

    @Test func whenTheSoundIsTriedAgain() {
        typealias P = ScreenAudioPolicy
        var p = P()
        #expect(p.ended(error: YoyoError.http(404, nil), lifetime: .zero) == .giveUp)
        #expect(p.ended(error: YoyoError.decoding("screen audio"), lifetime: .zero) == .giveUp)
        #expect(p.ended(error: YoyoError.http(503, "audio off"), lifetime: .zero) == .retry(after: .seconds(30)))
        // any other end reopens at once: a clean one, a failure, after a long or a short life
        #expect(p.ended(error: nil, lifetime: .seconds(60)) == .retry(after: .zero))
        #expect(p.ended(error: URLError(.networkConnectionLost), lifetime: .seconds(60)) == .retry(after: .zero))
        #expect(p.ended(error: YoyoError.http(500, nil), lifetime: .seconds(1)) == .retry(after: .zero))
        // the second quick end in a row waits; a stream that lived resets the count
        #expect(p.ended(error: nil, lifetime: .seconds(1)) == .retry(after: P.failedRetry))
        #expect(p.ended(error: URLError(.timedOut), lifetime: .zero) == .retry(after: P.failedRetry))
        #expect(p.ended(error: nil, lifetime: .seconds(10)) == .retry(after: .zero))
        #expect(p.ended(error: nil, lifetime: .seconds(1)) == .retry(after: .zero))
        #expect(p.ended(error: nil, lifetime: .seconds(1)) == .retry(after: P.failedRetry))
        p.reset()
        #expect(p.ended(error: nil, lifetime: .seconds(1)) == .retry(after: .zero))
    }

    @Test func theSpeakerIsOnUnlessTurnedOff() throws {
        let defaults = try #require(UserDefaults(suiteName: "ScreenAudioTests.\(UUID().uuidString)"))
        #expect(ScreenAudio.isOn(defaults))
        defaults.set(false, forKey: ScreenAudio.defaultsKey)
        #expect(!ScreenAudio.isOn(defaults))
        defaults.set(true, forKey: ScreenAudio.defaultsKey)
        #expect(ScreenAudio.isOn(defaults))
    }

    // MARK: Jitter buffer

    private static let rate = 48_000.0
    private static let mac0 = 1_761_170_000.0
    private static let host0 = 5_000.0
    private static let packet = 0.020

    private struct Arrival { var seq: Int; var macTime: Double; var arrival: Double; var value: Float = 0.5 }

    /// A deterministic jitter source (an LCG), 0…1.
    private struct Noise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// `count` packets, 20 ms apart on the Mac, arriving `network` + `jitter(i)` later, in order (one TCP stream: a
    /// late packet holds up the ones after it).
    private static func packets(_ count: Int, network: Double = 0.030, jitter: (Int) -> Double = { _ in 0 }) -> [Arrival] {
        var last = -Double.infinity
        return (0..<count).map { i in
            last = max(last, host0 + Double(i) * packet + network + jitter(i))
            return Arrival(seq: i, macTime: mac0 + Double(i) * packet, arrival: last)
        }
    }

    /// Runs the buffer against an output pulling `chunk` frames at a time from `host0`, pushing each packet as it
    /// arrives. Returns the left channel of what came out.
    private static func play(_ arrivals: [Arrival], _ b: inout ScreenAudioBuffer, seconds: Double, chunk: Int = 256)
        -> [Float] {
        var out: [Float] = []
        let ordered = arrivals.sorted { $0.arrival < $1.arrival }
        var next = 0
        var frame = 0
        var unequal = 0
        while Double(frame) / rate < seconds {
            let now = host0 + Double(frame) / rate
            while next < ordered.count, ordered[next].arrival <= now {
                let a = ordered[next]
                b.push(seq: a.seq, macTime: a.macTime, arrival: a.arrival,
                       samples: [Float](repeating: a.value, count: 960 * 2))
                next += 1
            }
            let pulled = b.pull(frames: chunk, at: now)
            for f in 0..<chunk {
                if pulled[f * 2] != pulled[f * 2 + 1] { unequal += 1 }
                out.append(pulled[f * 2])
            }
            frame += chunk
        }
        #expect(unequal == 0, "both channels alike")
        return out
    }

    @Test func theFirstPacketPlaysAtItsSlotFadingIn() {
        var b = ScreenAudioBuffer()
        let out = Self.play(Self.packets(20), &b, seconds: 0.3)
        // arrives at 30 ms; its slot is arrival + the starting depth (60 ms): frame 4320
        let start = Int((0.030 + b.config.startDepth) * Self.rate)
        #expect(out[..<(start - 1)].allSatisfy { $0 == 0 })
        #expect(out[start + 1] > 0 && out[start + 1] < 0.05, "fading in")
        #expect(out[start + 120] > 0.2 && out[start + 120] < 0.3)
        #expect(out[(start + 241)...].allSatisfy { $0 == 0.5 })
        #expect(b.underruns == 0 && b.late == 0 && b.concealed == 0)
        #expect(b.playing)
    }

    @Test func theDepthIsTheJittersP99PlusMarginWithinItsBounds() {
        var noise = Noise(state: 11)
        let jitter = (0..<500).map { _ in noise.next() * 0.030 }
        // a low floor, so the jitter decides
        var config = ScreenAudioBuffer.Config()
        config.set(floor: 0.020)
        var b = ScreenAudioBuffer(config: config)
        let out = Self.play(Self.packets(500) { jitter[$0] }, &b, seconds: 10)
        // p99 of 0…30 ms is about 29.7 ms, + 20 ms
        #expect(b.depth > 0.048 && b.depth < 0.050, "\(b.depth)")
        #expect(b.need == b.depth && b.lead == 0)
        #expect(b.underruns == 0 && b.late == 0 && b.concealed == 0, "\(b.stats)")
        let start = Int(0.2 * Self.rate)
        #expect(out[start..<Int(9.9 * Self.rate)].allSatisfy { $0 == 0.5 }, "no hole once playing")
        // the bounds: no jitter → the floor; a lot → the cap
        var calm = ScreenAudioBuffer()
        _ = Self.play(Self.packets(100), &calm, seconds: 2)
        #expect(calm.depth == calm.config.minDepth)
        var stormy = ScreenAudioBuffer()
        _ = Self.play(Self.packets(100) { $0 % 2 == 0 ? 0 : 0.4 }, &stormy, seconds: 2.5)
        #expect(stormy.depth == stormy.config.maxDepth)
    }

    @Test func aMissingPacketIsSilenceWithFades() {
        var b = ScreenAudioBuffer()
        var arrivals = Self.packets(40)
        arrivals.remove(at: 20)
        // (stopping before the last packet has played: running out at the end is an underrun)
        let out = Self.play(arrivals, &b, seconds: 0.8)
        #expect(b.concealed == 1 && b.underruns == 0 && b.late == 0, "\(b.stats)")
        let start = Int((0.030 + b.config.startDepth) * Self.rate)
        let gap = start + 20 * 960
        // fading out over the last 5 ms before it, silent through it, fading in after it
        #expect(out[gap - 300] == 0.5)
        #expect(out[gap - 120] > 0.2 && out[gap - 120] < 0.3)
        #expect(out[(gap - 1)...(gap + 960 - 1)].allSatisfy { $0 < 0.01 })
        #expect(out[gap + 960 + 120] > 0.2 && out[gap + 960 + 120] < 0.3)
        #expect(out[gap + 960 + 241] == 0.5)
    }

    @Test func aStallUnderrunsThenPlaysOnDroppingWhatCameTooLate() {
        var b = ScreenAudioBuffer()
        // packets 50…79 are held up (600 ms: more than the deepest buffer) and all come with 80
        let arrivals = Self.packets(200).map { a -> Arrival in
            var a = a
            if (50...79).contains(a.seq) { a.arrival = Self.host0 + 80 * Self.packet + 0.030 }
            return a
        }
        let out = Self.play(arrivals, &b, seconds: 4)
        #expect(b.underruns >= 1)
        #expect(b.late >= 1, "the held-up packets past their slots are dropped")
        #expect(b.playing)
        #expect(out[out.count - 2_000] == 0.5, "playing again")
        #expect(b.stats.drops == b.late + b.overflow)
    }

    @Test func aPacketPastItsSlotIsDropped() {
        var b = ScreenAudioBuffer()
        let arrival = Self.host0
        b.push(seq: 0, macTime: Self.mac0, arrival: arrival, samples: [Float](repeating: 0.5, count: 960 * 2))
        let slot = arrival + b.config.startDepth
        #expect(b.slot(macTime: Self.mac0).map { abs($0 - slot) < 1e-6 } == true)
        // pulled well after its slot: late, silence
        let out = b.pull(frames: 256, at: slot + 0.050)
        #expect(out.allSatisfy { $0 == 0 })
        #expect(b.late == 1 && !b.playing)
        // a packet within the tolerance plays from where its slot is now
        b.push(seq: 1, macTime: Self.mac0 + Self.packet, arrival: arrival + Self.packet,
               samples: [Float](repeating: 0.25, count: 960 * 2))
        _ = b.pull(frames: 256, at: slot + Self.packet + 0.005)
        #expect(b.playing && b.late == 1)
        #expect(b.stats.buffered < 0.015 + 0.001, "5 ms of it were skipped, 256 frames played")
        // one whose place already played is late too
        b.push(seq: 0, macTime: Self.mac0, arrival: arrival + 0.1, samples: [Float](repeating: 0.5, count: 960 * 2))
        #expect(b.late == 2)
    }

    @Test func tooMuchBufferedIsCutDownCrossfaded() {
        var b = ScreenAudioBuffer()
        // the Mac's clock runs 1 % fast against the phone's: 10 ms more sound every second
        let arrivals = (0..<1_000).map { i in
            Arrival(seq: i, macTime: Self.mac0 + Double(i) * Self.packet,
                    arrival: Self.host0 + Double(i) * Self.packet * 0.99 + 0.030)
        }
        let out = Self.play(arrivals, &b, seconds: 19.5)
        #expect(b.cuts > 0)
        #expect(b.underruns == 0 && b.late == 0)
        #expect(b.stats.buffered < b.depth + b.config.excess + 0.030, "\(b.stats.buffered) for \(b.depth)")
        // a cut of a steady sound is seamless
        let start = Int(0.2 * Self.rate)
        #expect(out[start...].allSatisfy { abs($0 - 0.5) < 1e-5 })
    }

    @Test func aCutLandsOnTheQuietestSpot() {
        var config = ScreenAudioBuffer.Config()
        config.excessHold = 0
        var b = ScreenAudioBuffer(config: config)
        // 300 ms buffered at once (no jitter: depth + excess = 100 ms); 15 ms quiet from the middle of the second packet
        for i in 0..<15 {
            var samples = [Float](repeating: 0.5, count: 960 * 2)
            let quiet = i == 1 ? 480..<960 : i == 2 ? 0..<240 : 0..<0
            for f in quiet { samples[f * 2] = 0.001; samples[f * 2 + 1] = 0.001 }
            b.push(seq: i, macTime: Self.mac0 + Double(i) * Self.packet, arrival: Self.host0 + Double(i) * Self.packet,
                   samples: samples)
        }
        #expect(b.depth == b.config.minDepth)
        let slot = b.slot(macTime: Self.mac0)!
        _ = b.pull(frames: 480, at: slot)
        let before = b.stats.buffered
        // the next pull plans the cut within the next packet's worth, and makes it
        var out: [Float] = []
        for k in 0..<8 { out += b.pull(frames: 240, at: slot + 0.010 + Double(k) * 0.005) }
        #expect(b.cuts == 1)
        #expect(abs(before - b.stats.buffered - (0.040 + b.config.cut)) < 0.0005)
        // the 10 ms cut were quiet ones (at the start of the quiet stretch: the first spot with the least energy), the
        // crossfade too; the loud sound around it all played
        let left = stride(from: 0, to: out.count, by: 2).map { out[$0] }
        #expect(left.count == 1_920)
        #expect(left[..<960].allSatisfy { $0 == 0.5 })
        #expect(left[960..<1_200].allSatisfy { $0 < 0.01 })
        #expect(left[1_200...].allSatisfy { $0 == 0.5 })
    }

    @Test func overTheQueueLimitTheOldestGo() {
        var b = ScreenAudioBuffer()
        for a in Self.packets(60) {
            b.push(seq: a.seq, macTime: a.macTime, arrival: a.arrival, samples: [Float](repeating: 0.5, count: 960 * 2))
        }
        #expect(b.overflow == 10)
        #expect(abs(b.stats.buffered - 1.0) < 0.001)
        #expect(b.stats.drops == 10)
    }

    @Test func aFlushStartsOverFromTheNextSlot() {
        var b = ScreenAudioBuffer()
        _ = Self.play(Self.packets(20), &b, seconds: 0.2)
        #expect(b.playing)
        b.flush()
        #expect(!b.playing && b.stats.buffered == 0)
        #expect(b.pull(frames: 64, at: Self.host0 + 0.21).allSatisfy { $0 == 0 })
    }

    @Test func aClockStepStartsTheEstimateOver() {
        var b = ScreenAudioBuffer()
        for a in Self.packets(20) {
            b.push(seq: a.seq, macTime: a.macTime, arrival: a.arrival, samples: [])
        }
        let base = b.base
        // the Mac's clock jumped a second ahead
        b.push(seq: 20, macTime: Self.mac0 + 20 * Self.packet + 1, arrival: Self.host0 + 20 * Self.packet + 0.030, samples: [])
        #expect(b.resets == 1)
        #expect(b.base.map { abs($0 - (base! - 1)) < 1e-9 } == true)
    }
}
