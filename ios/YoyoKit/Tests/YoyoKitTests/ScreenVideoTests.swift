import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import Testing
import UIKit
import VideoToolbox
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The screen stream's round 3 additions (PROTOCOL.md「屏幕」): part routing by type with the new part headers, Annex-B
/// handling and hardware video decoding (on a real H.264 stream made here with VideoToolbox), acks, the stream request's
/// new fields, the client-drawn cursor, and video that can't be played ending the stream.
@Suite("Screen video")
struct ScreenVideoTests {
    // MARK: Annex-B

    @Test func splitsAnnexBWithThreeAndFourByteStartCodes() {
        // junk before the first start code; a 4-byte code, a 3-byte code, a 4-byte code; emulation prevention (00 00 03)
        let data = Data([0x09, 0x09,
                         0, 0, 0, 1, 0x67, 0x42, 0x00, 0x00, 0x03, 0x01, 0x1E,
                         0, 0, 1, 0x68, 0xCE, 0x3C,
                         0, 0, 0, 1, 0x65, 0x88, 0x00, 0x00, 0x03, 0x00, 0x84])
        let units = AnnexB.nalUnits(data)
        #expect(units == [Data([0x67, 0x42, 0x00, 0x00, 0x03, 0x01, 0x1E]),
                          Data([0x68, 0xCE, 0x3C]),
                          Data([0x65, 0x88, 0x00, 0x00, 0x03, 0x00, 0x84])])
        #expect(AnnexB.nalUnits(Data()).isEmpty)
        #expect(AnnexB.nalUnits(Data([1, 2, 3, 4])).isEmpty)
        // a start code at the very end has no unit after it
        #expect(AnnexB.nalUnits(Data([0, 0, 1, 0x41, 0x9A, 0, 0, 1])) == [Data([0x41, 0x9A])])
    }

    @Test func lengthPrefixesUnits() {
        let out = AnnexB.lengthPrefixed([Data([0x65, 0x01, 0x02]), Data(repeating: 0x41, count: 300)])
        #expect(out.prefix(7) == Data([0, 0, 0, 3, 0x65, 0x01, 0x02]))
        #expect(out[7..<11] == Data([0, 0, 0x01, 0x2C]))
        #expect(out.count == 7 + 4 + 300)
    }

    @Test func nalTypesOfBothCodecs() {
        #expect(ScreenVideoCodec.h264.nalType(0x67) == 7)
        #expect(ScreenVideoCodec.h264.parameterSetRank(7) == 1 && ScreenVideoCodec.h264.parameterSetRank(8) == 2)
        #expect(ScreenVideoCodec.h264.isKeyPicture(5) && !ScreenVideoCodec.h264.isKeyPicture(1))
        // HEVC: VPS 0x40 01, SPS 0x42 01, PPS 0x44 01, IDR_W_RADL 0x26 01
        #expect(ScreenVideoCodec.hevc.nalType(0x40) == 32 && ScreenVideoCodec.hevc.nalType(0x42) == 33)
        #expect(ScreenVideoCodec.hevc.nalType(0x44) == 34 && ScreenVideoCodec.hevc.isKeyPicture(ScreenVideoCodec.hevc.nalType(0x26)))
        #expect(!ScreenVideoCodec.hevc.isKeyPicture(ScreenVideoCodec.hevc.nalType(0x02)))
    }

    // MARK: Decoding a real stream

    @Test func formatDescriptionFromRealParameterSets() throws {
        let stream = try TestVideo.h264(frames: 1)
        let units = AnnexB.nalUnits(stream[0])
        let sets = units.filter { [7, 8].contains($0[0] & 0x1F) }
        #expect(sets.count == 2)
        let format = try #require(AnnexB.formatDescription(.h264, parameterSets: sets))
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dims.width == Int32(TestVideo.width) && dims.height == Int32(TestVideo.height))
        let slices = units.filter { ($0[0] & 0x1F) == 5 }
        #expect(AnnexB.sampleBuffer(AnnexB.lengthPrefixed(slices), format: format) != nil)
        // garbage isn't a format
        #expect(AnnexB.formatDescription(.h264, parameterSets: [Data([0x67, 0xFF]), Data([0x68])]) == nil)
        #expect(AnnexB.formatDescription(.h264, parameterSets: []) == nil)
    }

    @Test func decodesKeyThenDeltasAndDropsDeltasBeforeAKey() throws {
        let stream = try TestVideo.h264(frames: 4)
        let core = ScreenVideoDecoderCore(codec: .h264)
        let t0 = ContinuousClock.now
        // a delta first: dropped, a key picture asked for
        guard case .waitingForKey(requestKey: true) = core.decode(TestVideo.part(stream[1], key: false), now: t0) else {
            Issue.record("a delta before the key must wait"); return
        }
        // asked again only after a while
        guard case .waitingForKey(requestKey: false) = core.decode(TestVideo.part(stream[2], key: false), now: t0 + .milliseconds(100)) else {
            Issue.record("no second request right away"); return
        }
        guard case .picture(let first, let ms) = core.decode(TestVideo.part(stream[0], key: true), now: t0 + .milliseconds(200)) else {
            Issue.record("the key picture decodes"); return
        }
        #expect(CVPixelBufferGetWidth(first) == TestVideo.width && CVPixelBufferGetHeight(first) == TestVideo.height)
        #expect(ms >= 0)
        #expect(!core.needKey)
        for i in 1..<4 {
            guard case .picture = core.decode(TestVideo.part(stream[i], key: false)) else {
                Issue.record("delta \(i) decodes"); return
            }
        }
        // a gap: deltas wait for the next key picture again
        core.gap()
        guard case .waitingForKey(requestKey: true) = core.decode(TestVideo.part(stream[3], key: false)) else {
            Issue.record("after a gap deltas wait"); return
        }
        guard case .picture = core.decode(TestVideo.part(stream[0], key: true)) else {
            Issue.record("the next key picture decodes"); return
        }
        core.invalidate()
    }

    @Test func aKeyIsRecognisedWithoutTheKindHeader() throws {
        let stream = try TestVideo.h264(frames: 2)
        let core = ScreenVideoDecoderCore(codec: .h264)
        var part = TestVideo.part(stream[0], key: true)
        part.headers.kind = nil
        guard case .picture = core.decode(part) else { Issue.record("an IDR without X-Frame-Kind is a key"); return }
    }

    @Test func aFormatThatCantBeMadeIsUnplayable() {
        let core = ScreenVideoDecoderCore(codec: .h264)
        let bogus = Data([0, 0, 0, 1, 0x67, 0xFF, 0xFF, 0, 0, 0, 1, 0x68, 0xFF, 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00])
        guard case .unplayable = core.decode(TestVideo.part(bogus, key: true)) else { Issue.record("no format, no video"); return }
    }

    @Test func waitingTooLongForAKeyIsUnplayable() throws {
        let stream = try TestVideo.h264(frames: 2)
        let core = ScreenVideoDecoderCore(codec: .h264)
        let t0 = ContinuousClock.now
        _ = core.decode(TestVideo.part(stream[1], key: false), now: t0)
        guard case .waitingForKey(requestKey: true) = core.decode(TestVideo.part(stream[1], key: false), now: t0 + .milliseconds(1500)) else {
            Issue.record("asked again after a second"); return
        }
        guard case .unplayable = core.decode(TestVideo.part(stream[1], key: false), now: t0 + .seconds(6)) else {
            Issue.record("no key for 5 s: video doesn't work"); return
        }
    }

    @Test func repeatedFailuresWithinTenSecondsMeanUnplayable() {
        let t0 = ContinuousClock.now
        var t = VideoFailureTracker()
        let close = [0, 4, 8].map { t.record(t0 + .seconds($0)) }
        #expect(close == [false, false, true])
        // spread out, they don't add up
        var u = VideoFailureTracker()
        let spread = [0, 6, 12, 13].map { u.record(t0 + .seconds($0)) }
        #expect(spread == [false, false, false, true])
    }

    /// The decoder on its queue: a stream whose video can't work says so once and takes nothing more.
    @Test func theDecoderReportsUnplayableOnceThenIgnoresParts() async throws {
        let fallbacks = Mutex(0)
        let keys = Mutex(0)
        let decoder = ScreenVideoDecoder(codec: .h264, output: nil, onKeyframeNeeded: { keys.withLock { $0 += 1 } },
                                         onPicture: { _, _, _ in }, onUnplayable: { fallbacks.withLock { $0 += 1 } })
        let bogus = Data([0, 0, 0, 1, 0x67, 0xFF, 0xFF, 0, 0, 0, 1, 0x68, 0xFF, 0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00])
        decoder.submit(TestVideo.part(bogus, key: true))
        decoder.submit(TestVideo.part(bogus, key: true))
        try await waitUntil { fallbacks.withLock { $0 } > 0 }
        decoder.submit(TestVideo.part(bogus, key: true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fallbacks.withLock { $0 } == 1)
    }

    @Test func theDecoderShowsPicturesAndAsksForKeysOnAGap() async throws {
        let stream = try TestVideo.h264(frames: 3)
        let pictures = Mutex<[CGSize]>([])
        let keys = Mutex(0)
        let decoder = ScreenVideoDecoder(codec: .h264, output: nil, onKeyframeNeeded: { keys.withLock { $0 += 1 } },
                                         onPicture: { size, _, _ in pictures.withLock { $0.append(size) } }, onUnplayable: {})
        decoder.submit(TestVideo.part(stream[0], key: true, seq: 1))
        try await waitUntil { !pictures.withLock { $0 }.isEmpty }
        #expect(pictures.withLock { $0.first } == CGSize(width: TestVideo.width, height: TestVideo.height))
        decoder.gap()
        decoder.submit(TestVideo.part(stream[2], key: false, seq: 3))
        try await waitUntil { keys.withLock { $0 } > 0 }
        decoder.invalidate()
    }

    // MARK: Routing parts (raw body and URLSession's per-part split)

    private static let still = Data([0xFF, 0xD8, 0x01, 0x0D, 0x0A, 0x2D, 0x2D, 0xFF, 0xD9])
    private static let video = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE, 0, 0, 0, 1, 0x65, 0x88, 0x84])
    private static let cursorJSON = Data(#"{"x":0.25,"y":0.5,"visible":true,"shapeId":0,"shape":{"id":0,"png":"iVBORw0KGgo=","hotX":0.001,"hotY":0.002,"width":0.01,"height":0.02}}"#.utf8)

    private static func part(_ body: Data, type: String, seq: Int, kind: String, codec: String? = nil, size: (Int, Int)? = nil) -> Data {
        var h = "--frame\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nX-Frame-Seq: \(seq)\r\nX-Frame-Kind: \(kind)\r\nX-Frame-Time: 1761170000123\r\n"
        if let codec { h += "X-Stream-Codec: \(codec)\r\n" }
        if let size { h += "X-Frame-Width: \(size.0)\r\nX-Frame-Height: \(size.1)\r\n" }
        var d = Data((h + "\r\n").utf8)
        d.append(body)
        d.append(Data("\r\n".utf8))
        return d
    }

    private static var mixedBody: Data {
        var d = part(cursorJSON, type: "application/vnd.yoyo-control.cursor+json", seq: 1, kind: "cursor")
        d.append(part(video, type: "video/h264", seq: 2, kind: "key", codec: "h264", size: (1600, 1000)))
        d.append(part(Data("{\"future\":1}".utf8), type: "application/vnd.yoyo-control.something", seq: 3, kind: "x"))
        d.append(part(video, type: "video/hevc", seq: 4, kind: "delta", codec: "hevc", size: (1600, 1000)))
        // an image part (no longer a kind of its own): reported bodiless for its seq, like any unknown type
        d.append(part(still, type: "image/jpeg", seq: 5, kind: "live", size: (1280, 800)))
        d.append(Data("--frame--\r\n".utf8))
        return d
    }

    private func checkMixed(_ parts: [ScreenStreamPart]) {
        #expect(parts.map(\.kind) == [.cursor, .h264, .other, .hevc, .other])
        #expect(parts.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(parts[0].body == Self.cursorJSON)
        #expect(parts[1].body == Self.video && parts[1].headers.kind == "key" && parts[1].headers.codec == "h264")
        #expect(parts[1].width == 1600 && parts[1].height == 1000)
        #expect(parts[1].headers.time == 1_761_170_000_123)
        #expect(parts[2].body.isEmpty)  // unknown: reported for its seq only
        #expect(parts[3].headers.kind == "delta")
        #expect(parts[4].body.isEmpty && parts[4].width == 1280)
    }

    @Test func routesPartsByTypeInTheRawBody() throws {
        var a = StreamPartAssembler()
        _ = try a.receive(status: 200, contentType: "application/vnd.yoyo-control.stream; boundary=frame", expectedLength: -1,
                          headers: ScreenPartHeaders(codec: "h264"))
        #expect(a.streamCodec == "h264")
        checkMixed(a.feed(Self.mixedBody))
        // and chunked anywhere
        let body = Self.mixedBody
        for cut in stride(from: 1, to: body.count, by: 7) {
            var p = StreamPartParser(boundary: "frame")
            checkMixed(p.feed(body.prefix(cut)) + p.feed(body.suffix(from: cut)))
        }
    }

    @Test func routesPartsByTypeWhenURLSessionSplitsTheStream() throws {
        var a = StreamPartAssembler()
        _ = try a.receive(status: 200, contentType: "multipart/x-mixed-replace; boundary=frame", expectedLength: -1)
        var parts: [ScreenStreamPart] = []
        func response(_ body: Data, _ type: String, seq: Int, kind: String, codec: String? = nil, size: (Int, Int)? = nil, length: Bool = true) throws {
            var fields = ["Content-Type": type, "X-Frame-Seq": String(seq), "X-Frame-Kind": kind, "X-Frame-Time": "1761170000123"]
            if let codec { fields["X-Stream-Codec"] = codec }
            if let size { fields["X-Frame-Width"] = String(size.0); fields["X-Frame-Height"] = String(size.1) }
            parts += try a.receive(status: 200, contentType: type, expectedLength: length ? Int64(body.count) : -1,
                                   headers: ScreenPartHeaders { fields[$0] })
            parts += a.feed(body.prefix(2))
            parts += a.feed(body.suffix(from: 2))
        }
        try response(Self.cursorJSON, "application/vnd.yoyo-control.cursor+json", seq: 1, kind: "cursor")
        try response(Self.video, "video/h264", seq: 2, kind: "key", codec: "h264", size: (1600, 1000))
        try response(Data("{\"future\":1}".utf8), "application/vnd.yoyo-control.something", seq: 3, kind: "x")
        try response(Self.video, "video/hevc", seq: 4, kind: "delta", codec: "hevc", size: (1600, 1000), length: false)
        try response(Self.still, "image/jpeg", seq: 5, kind: "live", size: (1280, 800))
        parts += a.finish()
        #expect(a.split)
        checkMixed(parts)
    }

    @Test func oversizedVideoAndCursorPartsAreSkippedUnbuffered() {
        var p = StreamPartParser(boundary: "b")
        let huge = ScreenStreamPart.maxVideoPart + 1
        _ = p.feed(Data("--b\r\nContent-Type: video/h264\r\nContent-Length: \(huge)\r\nX-Frame-Seq: 1\r\n\r\n".utf8))
        var left = huge
        while left > 0 {
            let n = min(left, 65536)
            #expect(p.feed(Data(repeating: 0x41, count: n)).isEmpty)
            #expect(p.bufferedCount == 0)
            left -= n
        }
        // after the skipped body the next part comes through
        let next = Data("\r\n--b\r\nContent-Type: video/h264\r\nContent-Length: \(Self.video.count)\r\nX-Frame-Seq: 2\r\n\r\n".utf8) + Self.video + Data("\r\n".utf8)
        let parts = p.feed(next)
        #expect(parts.map(\.kind) == [.h264] && parts.first?.seq == 2)
        // a split cursor part over its limit is dropped
        var a = StreamPartAssembler()
        _ = try? a.receive(status: 200, contentType: "multipart/x-mixed-replace; boundary=b", expectedLength: -1)
        _ = try? a.receive(status: 200, contentType: "application/vnd.yoyo-control.cursor+json", expectedLength: Int64(ScreenStreamPart.maxCursorPart + 1))
        #expect(a.feed(Data(repeating: 0x7B, count: 100)).isEmpty)
        #expect(a.finish().isEmpty)
    }

    // MARK: The stream request

    @Test func streamOptionsBody() {
        var body: [String: Any] = [:]
        ScreenStreamOptions(codecs: [.hevc, .h264], stream: "0F8C2C1E-5A4B-4E7A-9B1C-3D2E1F0A9B8C", ack: true, clientCursor: true)
            .add(to: &body)
        #expect(body["codecs"] as? String == "hevc,h264")
        #expect(body["stream"] as? String == "0F8C2C1E-5A4B-4E7A-9B1C-3D2E1F0A9B8C")
        #expect(body["ack"] as? Int == 1)
        #expect(body["cursor"] as? String == "client")
        // without clientCursor nothing asks for cursor parts; nothing set, nothing sent
        var plain: [String: Any] = [:]
        ScreenStreamOptions(codecs: [.h264], stream: "abcdefgh", ack: true).add(to: &plain)
        #expect(plain["cursor"] == nil && plain["codecs"] as? String == "h264")
        var empty: [String: Any] = [:]
        ScreenStreamOptions().add(to: &empty)
        #expect(empty.isEmpty)
    }

    @Test func liveOptionsAskForTheClientCursorOnEveryDisplay() {
        let video = ScreenStreamOptions.live(codecs: [.hevc, .h264])
        #expect(video.clientCursor && video.ack && video.status && video.codecs == [.hevc, .h264])
        #expect(video.stream.map(ScreenStreamOptions.isValidStreamId) == true)
        var body: [String: Any] = [:]
        video.add(to: &body)
        #expect(body["cursor"] as? String == "client")
        #expect(ScreenStreamOptions.live().stream != video.stream)
    }

    @Test func streamIdsFollowTheSpec() {
        let id = ScreenStreamOptions.newStreamId()
        #expect(ScreenStreamOptions.isValidStreamId(id))
        #expect(ScreenStreamOptions.newStreamId() != id)
        #expect(!ScreenStreamOptions.isValidStreamId("short"))
        #expect(!ScreenStreamOptions.isValidStreamId("has a space in it"))
        #expect(!ScreenStreamOptions.isValidStreamId(String(repeating: "a", count: 65)))
        #expect(ScreenStreamOptions.isValidStreamId("abc_DEF-123"))
    }

    @Test func requestedCodecsPreferHEVCOnlyInHardware() {
        #expect(ScreenVideoCodec.requestedCodecs(hevcInHardware: true) == [.hevc, .h264])
        #expect(ScreenVideoCodec.requestedCodecs(hevcInHardware: false) == [.h264])
    }

    @Test func streamRequestCarriesTheOptions() throws {
        var body: [String: Any] = [:]
        ScreenStreamOptions(codecs: [.h264], stream: "stream-0001", ack: true, clientCursor: true).add(to: &body)
        #expect(body["codecs"] as? String == "h264" && body["stream"] as? String == "stream-0001")
        #expect(body["ack"] as? Int == 1 && body["cursor"] as? String == "client" && body["status"] == nil)
        let api = DirectBackend(ways: nil, token: "t", serverId: "s", fingerprint: "sha256:00")
        let ack = try api.ackRequest(ScreenStreamAck(stream: "stream-0001", seq: 42, keyframe: true), route: api.route)
        #expect(ack.httpMethod == "POST" && ack.url?.path() == "/stream/ack")
        let ackBody = try #require(try JSONSerialization.jsonObject(with: ack.httpBody ?? Data()) as? [String: Any])
        #expect(ackBody["stream"] as? String == "stream-0001" && ackBody["seq"] as? Int == 42 && ackBody["keyframe"] as? Bool == true)
        let plain = ScreenStreamAck(stream: "s", seq: 1).json
        #expect(plain["keyframe"] == nil)
    }

    // MARK: Acks

    /// Records acks; the test finishes them when it wants.
    private final class FakeTransport: Sendable {
        private let state = Mutex<(sent: [ScreenStreamAck], pending: [@Sendable (ScreenAckSender.Outcome) -> Void])>(([], []))
        var sent: [ScreenStreamAck] { state.withLock { $0.sent } }
        var inFlight: Int { state.withLock { $0.pending.count } }
        var transport: ScreenAckSender.Transport {
            { [self] ack, done in state.withLock { $0.sent.append(ack); $0.pending.append(done) } }
        }
        func finish(_ outcome: ScreenAckSender.Outcome) {
            let done = state.withLock { s -> (@Sendable (ScreenAckSender.Outcome) -> Void)? in
                s.pending.isEmpty ? nil : s.pending.removeFirst()
            }
            done?(outcome)
        }
    }

    @Test func eachPictureIsAckedAtOnceUpToTheInFlightLimit() {
        let fake = FakeTransport()
        let acks = ScreenAckSender(stream: "s1", transport: fake.transport)
        // up to maxInFlight acks go out right away (one per picture): none waits for the previous one's round trip
        for seq in 1...ScreenAckSender.maxInFlight { acks.received(seq: seq) }
        #expect(fake.sent.map(\.seq) == Array(1...ScreenAckSender.maxInFlight))
        #expect(fake.inFlight == ScreenAckSender.maxInFlight)
        // beyond the limit only the newest is remembered…
        let n = ScreenAckSender.maxInFlight
        acks.received(seq: n + 2)
        acks.received(seq: n + 1)
        #expect(fake.sent.count == n)
        // …and goes out when one returns
        fake.finish(.ok)
        #expect(fake.sent.last == ScreenStreamAck(stream: "s1", seq: n + 2))
        // everything acked, nothing new: nothing more
        for _ in 0..<n { fake.finish(.ok) }
        #expect(fake.inFlight == 0 && fake.sent.count == n + 1)
        acks.received(seq: n + 2)
        #expect(fake.sent.count == n + 1)
    }

    @Test func aKeyframeRequestRidesTheNextAck() {
        let fake = FakeTransport()
        let acks = ScreenAckSender(stream: "s1", transport: fake.transport)
        // no seq yet: nothing to send it with
        acks.requestKeyframe()
        #expect(fake.sent.isEmpty)
        acks.received(seq: 7)
        #expect(fake.sent == [ScreenStreamAck(stream: "s1", seq: 7, keyframe: true)])
        acks.requestKeyframe()
        fake.finish(.ok)
        // asked again with the same seq
        #expect(fake.sent.last == ScreenStreamAck(stream: "s1", seq: 7, keyframe: true))
        // a failed request goes again shortly (or with the next ack, whichever is first)
        fake.finish(.failed)
        #expect(fake.sent.count == 2)
        acks.received(seq: 8)
        #expect(fake.sent.last == ScreenStreamAck(stream: "s1", seq: 8, keyframe: true))
        fake.finish(.ok)
        acks.received(seq: 9)
        #expect(fake.sent.last == ScreenStreamAck(stream: "s1", seq: 9, keyframe: false))
    }

    @Test func aFailedAckIsRetriedShortly() async throws {
        let fake = FakeTransport()
        let acks = ScreenAckSender(stream: "s1", transport: fake.transport)
        acks.received(seq: 3)
        fake.finish(.failed)
        #expect(fake.sent.count == 1)
        // the server may be holding pictures back until this ack: it goes again without waiting for a new picture
        try await Task.sleep(for: .milliseconds(400))
        #expect(fake.sent.count == 2)
        #expect(fake.sent.last == ScreenStreamAck(stream: "s1", seq: 3, keyframe: false))
    }

    @Test func a404StopsAcking() {
        let fake = FakeTransport()
        let acks = ScreenAckSender(stream: "s1", transport: fake.transport)
        acks.received(seq: 1)
        fake.finish(.gone)
        #expect(acks.isStopped)
        acks.received(seq: 2)
        acks.requestKeyframe()
        #expect(fake.sent.count == 1)
        // stop() does the same
        let other = FakeTransport()
        let b = ScreenAckSender(stream: "s2", transport: other.transport)
        b.stop()
        b.received(seq: 1)
        #expect(other.sent.isEmpty)
    }

    @Test func theRouterAcksPicturesAndRoutesCursorAndVideo() {
        let fake = FakeTransport()
        let acks = ScreenAckSender(stream: "s1", transport: fake.transport)
        let decoders = Mutex<[ScreenVideoCodec]>([])
        let cursors = Mutex<[ScreenCursorUpdate]>([])
        let router = ScreenStreamRouter(acks: acks, stats: nil, handlers: .init(
            makeDecoder: { codec in decoders.withLock { $0.append(codec) }; return nil },
            onCursor: { u in cursors.withLock { $0.append(u) } }))
        router.route(ScreenStreamPart(kind: .cursor, body: Self.cursorJSON, headers: ScreenPartHeaders(seq: 1, kind: "cursor")))
        // cursor parts aren't acked
        #expect(fake.sent.isEmpty)
        // a picture is acked on receipt, before it goes to a decoder (none could be made here)
        router.route(ScreenStreamPart(kind: .h264, body: Self.video, headers: ScreenPartHeaders(seq: 2, kind: "key")))
        #expect(fake.sent == [ScreenStreamAck(stream: "s1", seq: 2)])
        router.route(ScreenStreamPart(kind: .other, body: Data(), headers: ScreenPartHeaders(seq: 3)))
        #expect(decoders.withLock { $0 } == [.h264])
        #expect(cursors.withLock { $0.first?.x } == 0.25)
        router.stop()
        router.route(ScreenStreamPart(kind: .h264, body: Self.video, headers: ScreenPartHeaders(seq: 4)))
        #expect(decoders.withLock { $0 } == [.h264] && acks.isStopped)
    }

    // MARK: Cursor

    @Test func cursorPartsDecodeLeniently() throws {
        let full = try #require(ScreenCursorUpdate(json: Self.cursorJSON))
        #expect(full.x == 0.25 && full.y == 0.5 && full.visible == true && full.shapeId == 0)
        let shape = try #require(full.shape)
        #expect(shape.id == 0 && shape.png == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(shape.hotX == 0.001 && shape.width == 0.01 && shape.height == 0.02)
        // nulls, wrong types and unknown fields: those fields are nil, the rest counts
        let odd = try #require(ScreenCursorUpdate(json: Data(#"{"x":null,"y":"0.3","visible":1,"shapeId":2.5,"extra":[1],"shape":{"png":"!!"}}"#.utf8)))
        #expect(odd.x == nil && odd.y == nil && odd.visible == nil && odd.shapeId == nil && odd.shape == nil)
        // a shape without its own id takes the part's shapeId
        let bare = try #require(ScreenCursorUpdate(json: Data(#"{"shapeId":5,"shape":{"png":"iVBORw0KGgo="}}"#.utf8)))
        #expect(bare.shape?.id == 5 && bare.shape?.width == 0)
        #expect(ScreenCursorUpdate(json: Data("[1,2]".utf8)) == nil)
        #expect(ScreenCursorUpdate(json: Data("nope".utf8)) == nil)
    }

    /// A system cursor's shape (the Mac's ScreenCaptureKit streams) has an id ≥ 1000000: it isn't a coordinate, so it
    /// isn't dropped like an out-of-range one.
    @Test func aSystemCursorsLargeShapeIdDecodes() throws {
        let json = #"{"x":0.59,"y":0.99,"visible":true,"shapeId":1290001,"shape":{"id":1290001,"png":"iVBORw0KGgo=","hotX":0.0029,"hotY":0.0045,"width":0.0162,"height":0.0358}}"#
        let u = try #require(ScreenCursorUpdate(json: Data(json.utf8)))
        #expect(u.shapeId == 1_290_001 && u.shape?.id == 1_290_001 && u.shape?.height == 0.0358)
        var state = ScreenCursorState()
        state.apply(u)
        #expect(state.shape?.id == 1_290_001)
        // a fraction or a non-number is still no id
        let odd = try #require(ScreenCursorUpdate(json: Data(#"{"shapeId":1290001.5,"shape":{"id":"7","png":"iVBORw0KGgo="}}"#.utf8)))
        #expect(odd.shapeId == nil && odd.shape == nil)
    }

    /// The Mac reports a visible pointer: one is drawn whether its shape decodes or not (else only the click rings show).
    @Test @MainActor func aVisiblePointerIsDrawnEvenWhenItsShapeDoesNotDecode() throws {
        let session = YoyoScreenSession(backend: ScreenViewerFirstTests.Backend(controller: .none))
        func canvas() -> YoyoScreenPictureView {
            let c = YoyoScreenPictureView(session: session)
            c.frame = CGRect(x: 0, y: 0, width: 390, height: 300)
            c.layoutIfNeeded()
            c.showVideo(size: CGSize(width: 1792, height: 1158))
            return c
        }
        func part(id: Int, png: Data?) -> ScreenCursorUpdate {
            ScreenCursorUpdate(x: 0.5, y: 0.5, visible: true, shapeId: id,
                               shape: png.map { .init(id: id, png: $0, hotX: 0.003, hotY: 0.0045, width: 0.0162, height: 0.0358) })
        }
        // a real PNG
        let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 28, height: 40)).pngData { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        })
        let good = canvas()
        good.applyCursor(part(id: 1_290_001, png: png))
        #expect(good.pointerDrawn)
        // a PNG that doesn't decode, no shape at all, a shape id never sent: the built-in arrow
        #expect(ScreenFallbackPointer.image != nil)
        for update in [part(id: 1_290_002, png: Data([0x89, 0x50, 0x4E, 0x47])), part(id: 1_290_003, png: nil)] {
            let c = canvas()
            c.applyCursor(update)
            #expect(c.pointerDrawn)
        }
        // hidden stays hidden
        let hidden = canvas()
        hidden.applyCursor(ScreenCursorUpdate(x: 0.5, y: 0.5, visible: false, shapeId: 0))
        #expect(!hidden.pointerDrawn)
    }

    @Test func aCursorPartWithoutAShapeKeepsThePreviousOne() throws {
        var state = ScreenCursorState()
        #expect(!state.received && state.shape == nil)
        state.apply(try #require(ScreenCursorUpdate(json: Self.cursorJSON)))
        #expect(state.received && state.visible && state.shapeId == 0 && state.shape?.id == 0)
        // moved, shape omitted, shapeId omitted: same shape
        state.apply(ScreenCursorUpdate(x: 0.7, y: 0.1))
        #expect(state.x == 0.7 && state.y == 0.1 && state.shapeId == 0 && state.shape?.id == 0 && state.visible)
        // a new shape, then back to the first by id only
        state.apply(ScreenCursorUpdate(shapeId: 3, shape: .init(id: 3, png: Data([1]), hotX: 0, hotY: 0, width: 0.02, height: 0.02)))
        #expect(state.shape?.id == 3)
        state.apply(ScreenCursorUpdate(shapeId: 0))
        #expect(state.shapeId == 0 && state.shape?.id == 0)
        // an id never seen keeps the last image; hidden; out-of-range positions are clamped
        state.apply(ScreenCursorUpdate(x: 1.5, y: -2, visible: false, shapeId: 99))
        #expect(state.shapeId == 99 && state.shape?.id == 0 && !state.visible && state.x == 1 && state.y == 0)
    }

    // MARK: Stats

    @Test func statsLine() {
        let stats = ScreenStreamStats()
        let t0 = ContinuousClock.now
        _ = stats.take(now: t0)
        stats.set(codec: "h264")
        stats.received(bytes: 2048 * 10)
        for _ in 0..<20 { stats.shown(decodeMs: 2) }
        let snap = stats.take(now: t0 + .seconds(2))
        #expect(snap.codec == "h264" && snap.fps == 10 && snap.kilobytesPerSecond == 10 && snap.decodeMs == 2)
        #expect(snap.line == "h264 · 10 fps · 10 KB/s · 2.0 ms")
        // the window restarts
        #expect(stats.take(now: t0 + .seconds(3)).fps == 0)
    }

    // MARK: Helpers

    private func waitUntil(_ condition: @Sendable () -> Bool, timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A real H.264 stream, as the Mac sends it: one Annex-B access unit per picture, SPS + PPS before the key picture.
enum TestVideo {
    static let width = 320
    static let height = 240

    struct EncodeError: Error {}

    static func part(_ data: Data, key: Bool, seq: Int? = nil) -> ScreenStreamPart {
        ScreenStreamPart(kind: .h264, body: data, headers: ScreenPartHeaders(contentType: "video/h264", width: width, height: height,
                                                                            seq: seq, kind: key ? "key" : "delta", codec: "h264"))
    }

    private final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var samples: [CMSampleBuffer] = []
        var failed = false
    }

    static func h264(frames: Int) throws -> [Data] {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { throw EncodeError() }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1000 as CFNumber)
        let collected = Collected()
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            guard let pb else { throw EncodeError() }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let row = CVPixelBufferGetBytesPerRow(pb)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let o = y * row + x * 4
                        p[o] = UInt8((x + i * 16) & 0xFF); p[o + 1] = UInt8((y * 2) & 0xFF); p[o + 2] = UInt8((x ^ y) & 0xFF); p[o + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let props: CFDictionary? = i == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30),
                                                         duration: .invalid, frameProperties: props, infoFlagsOut: nil) { status, _, sample in
                collected.lock.withLock {
                    if status == noErr, let sample { collected.samples.append(sample) } else { collected.failed = true }
                }
            }
            guard status == noErr else { throw EncodeError() }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let samples = collected.lock.withLock { collected.samples }
        guard samples.count == frames, !collected.lock.withLock({ collected.failed }) else { throw EncodeError() }
        return try samples.enumerated().map { i, s in try annexB(s, key: i == 0) }
    }

    private static func annexB(_ sample: CMSampleBuffer, key: Bool) throws -> Data {
        let startCode = Data([0, 0, 0, 1])
        var out = Data()
        if key {
            guard let format = CMSampleBufferGetFormatDescription(sample) else { throw EncodeError() }
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard let ptr else { throw EncodeError() }
                out.append(startCode)
                out.append(ptr, count: size)
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw EncodeError() }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
        var i = 0
        while i + 4 <= length {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            guard n > 0, i + n <= length else { throw EncodeError() }
            out.append(startCode)
            out.append(contentsOf: bytes[i..<i + n])
            i += n
        }
        return out
    }
}
