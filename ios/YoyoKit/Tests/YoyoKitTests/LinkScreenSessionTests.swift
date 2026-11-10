import AVFoundation
import Foundation
import Testing
import UIKit
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoScreen

/// The Screen page's session on a uu Link way (`YoyoBackend.screenLink(for:)`), with a fake link: `video.open` with
/// `/stream`'s query (no acks), its pictures straight to the decoder and the page (no multipart parser), each one's
/// outcome back to the link (`decoded`), a key picture asked for when the decoder fails, the playout report, the
/// cursor, the sound into the output, input sent at once and refusals to the page's handling, the stats line's way.
@MainActor
@Suite("Screen session on a link")
struct LinkScreenSessionTests {
    /// A link the test drives: what was opened and answered, and the handlers to push events into.
    final class FakeLink: YoyoScreenLink, @unchecked Sendable {
        private let lock = NSLock()
        var pathLabel: String { "link punched" }
        var isLocalNetwork: Bool { false }
        var rttMinMs: Double? { 42 }

        final class Video: YoyoLinkVideo, @unchecked Sendable {
            let lock = NSLock()
            let query: String
            let onEvent: @Sendable (YoyoLinkVideoEvent) -> Void
            var decodedFrames: [(UInt32, Bool)] = []
            var keyframes = 0
            var reports: [Data] = []
            var closed = false
            init(query: String, onEvent: @escaping @Sendable (YoyoLinkVideoEvent) -> Void) {
                self.query = query
                self.onEvent = onEvent
            }
            func decoded(frame: UInt32, ok: Bool) { lock.withLock { decodedFrames.append((frame, ok)) } }
            func requestKeyframe() { lock.withLock { keyframes += 1 } }
            func report(_ json: Data) { lock.withLock { reports.append(json) } }
            func close() { lock.withLock { closed = true } }
            var outcomes: [(UInt32, Bool)] { lock.withLock { decodedFrames } }
            var keys: Int { lock.withLock { keyframes } }
        }

        final class Audio: YoyoLinkAudio, @unchecked Sendable {
            let query: String
            let onEvent: @Sendable (YoyoLinkAudioEvent) -> Void
            init(query: String, onEvent: @escaping @Sendable (YoyoLinkAudioEvent) -> Void) {
                self.query = query
                self.onEvent = onEvent
            }
            func close() {}
        }

        private var _videos: [Video] = []
        private var _audios: [Audio] = []
        private var _inputs: [(Data, Bool)] = []
        private var _inputError: (@Sendable (Error) -> Void)?
        var videos: [Video] { lock.withLock { _videos } }
        var audios: [Audio] { lock.withLock { _audios } }
        var inputs: [(json: Data, move: Bool)] { lock.withLock { _inputs.map { ($0.0, $0.1) } } }

        func openVideo(query: String, onEvent: @escaping @Sendable (YoyoLinkVideoEvent) -> Void) -> any YoyoLinkVideo {
            let v = Video(query: query, onEvent: onEvent)
            lock.withLock { _videos.append(v) }
            return v
        }

        func openAudio(query: String, onEvent: @escaping @Sendable (YoyoLinkAudioEvent) -> Void) -> any YoyoLinkAudio {
            let a = Audio(query: query, onEvent: onEvent)
            lock.withLock { _audios.append(a) }
            return a
        }

        func sendInput(_ json: Data, move: Bool) throws { lock.withLock { _inputs.append((json, move)) } }

        func setInputErrorHandler(_ handler: (@Sendable (Error) -> Void)?) { lock.withLock { _inputError = handler } }

        func reject(_ error: Error) { lock.withLock { _inputError }?(error) }
    }

    /// A backend whose one way is the link (its HTTP requests are only asked for their queries).
    final class Backend: YoyoBackend, @unchecked Sendable {
        let link = FakeLink()
        let cacheScope = "link-session-tests:\(UUID().uuidString)"
        var route: YoyoRoute { YoyoRoute(id: "link", isLocalNetwork: false, label: "link") }
        func screenLink(for route: YoyoRoute) -> (any YoyoScreenLink)? { link }
        func status() async throws -> ScreenStatus { throw YoyoError.http(404, nil) }
        func streamRequest(display: UInt32?, maxWidth: Int?, quality: Int?, fps: Int?, options: ScreenStreamOptions,
                           route: YoyoRoute) throws -> URLRequest {
            var fields: [String: Any] = ["display": Int(display ?? 0), "fps": fps ?? 0]
            options.add(to: &fields)
            var c = URLComponents(string: "https://link.invalid/stream")!
            c.queryItems = fields.keys.sorted().map { URLQueryItem(name: $0, value: "\(fields[$0]!)") }
            return URLRequest(url: c.url!)
        }
        func ackRequest(_ ack: ScreenStreamAck, route: YoyoRoute) throws -> URLRequest {
            Issue.record("no acks on a link")
            return URLRequest(url: URL(string: "https://link.invalid/stream/ack")!)
        }
        func audioRequest(route: YoyoRoute) throws -> URLRequest { URLRequest(url: URL(string: "https://link.invalid/audio")!) }
        func input(_ input: ScreenInput, route: YoyoRoute) async throws { Issue.record("input goes on the link") }
        func setControl(_ controller: ScreenController, route: YoyoRoute) async throws -> ScreenStatus { throw YoyoError.http(404, nil) }
    }

    @MainActor
    struct Setup {
        let backend = Backend()
        let host = ScreenSessionTests.Host()
        let net = ScreenSessionTests.Net()
        let session: ScreenSession

        init(audio: Bool = false) {
            let name = "link-session-tests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            defaults.set(audio, forKey: ScreenAudio.defaultsKey)
            let output = ScreenVideoOutput(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer)
            session = ScreenSession(backend: backend, videoOutput: output, defaults: defaults, environment: net.environment)
            session.host = host
        }
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    nonisolated static let pictures: [Data] = (try? TestVideo.h264(frames: 3)) ?? []

    nonisolated static func frame(_ n: UInt32, _ au: Data, kind: String) -> YoyoLinkFrame {
        YoyoLinkFrame(number: n, codec: "h264", kind: kind, width: TestVideo.width, height: TestVideo.height,
                      captureMs: Date().timeIntervalSince1970 * 1000, au: au)
    }

    @Test func picturesGoStraightToTheDecoderAndEachOutcomeBack() async throws {
        let t = Setup()
        t.session.activate()
        #expect(t.net.streams.isEmpty, "no HTTP stream on a link way")
        let video = try #require(t.backend.link.videos.first)
        #expect(video.query.contains("codecs=") && video.query.contains("stream=") && !video.query.contains("ack="),
                "`/stream`'s query, without acks")
        #expect(video.query.contains("cursor=client") && video.query.contains("status=1"))
        video.onEvent(.opened(codec: "h264", width: TestVideo.width, height: TestVideo.height, headers: ["X-Display": "1"]))
        try #require(Self.pictures.count == 3)
        video.onEvent(.frame(Self.frame(1, Self.pictures[0], kind: "key")))
        video.onEvent(.frame(Self.frame(2, Self.pictures[1], kind: "delta")))
        await settle { t.host.videoShown > 0 && video.outcomes.count == 2 }
        #expect(t.host.videoShown > 0 && t.session.hasFrame)
        #expect(video.outcomes.map(\.0) == [1, 2] && video.outcomes.allSatisfy(\.1), "both decoded: frame_decoded(ok)")
        // a picture the decoder can't take: not ok, and a key picture asked for
        video.onEvent(.frame(Self.frame(3, Data([0, 0, 0, 1, 0x41, 0xFF, 0xFF, 0xFF]), kind: "delta")))
        await settle { video.outcomes.count == 3 && video.keys > 0 }
        #expect(video.outcomes.last.map { $0 == (3, false) } == true)
        #expect(video.keys > 0)
        // the stats line names the link's path
        #expect(t.session.statsText().contains("link punched"))
        t.session.deactivate()
        // closed on the link off the main thread
        await settle { video.lock.withLock { video.closed } }
        #expect(video.lock.withLock { video.closed })
    }

    @Test func aStatusAndTheCursorReachThePageAndTheLinkRoundTripTheStats() async throws {
        let t = Setup()
        t.session.activate()
        let video = try #require(t.backend.link.videos.first)
        video.onEvent(.opened(codec: "h264", width: nil, height: nil, headers: [:]))
        video.onEvent(.cursor(Data(#"{"x":0.25,"y":0.75,"visible":true,"shapeId":7}"#.utf8)))
        video.onEvent(.frame(Self.frame(1, Self.pictures[0], kind: "key")))
        await settle { t.host.videoShown > 0 }
        #expect(t.session.stats.freshRttMin() == 42, "the link's round trip stands in for the acks'")
        t.session.deactivate()
    }

    @Test func aStreamErrorIsAFailureAndAnEndedSessionToo() async throws {
        let t = Setup()
        t.session.activate()
        let video = try #require(t.backend.link.videos.first)
        video.onEvent(.error(status: 503, message: "no screen"))
        await settle { t.session.waitingToRetry }
        #expect(t.session.waitingToRetry && t.session.stream == nil)
        t.session.deactivate()
        // a session that ends under a stream: a failure as well
        let u = Setup()
        u.session.activate()
        let v2 = try #require(u.backend.link.videos.first)
        v2.onEvent(.failed(reason: "idle timeout"))
        await settle { u.session.waitingToRetry }
        #expect(u.session.waitingToRetry)
        u.session.deactivate()
    }

    @Test func inputGoesOnTheLinkAndARefusalReachesThePage() async throws {
        let t = Setup()
        var errors: [Error] = []
        t.session.onInputError = { errors.append($0) }
        t.session.activate()
        let send = try #require(t.session.linkInput())
        try send(.pointer(.move, display: 1, at: CGPoint(x: 0.5, y: 0.5)))
        try send(ScreenInput(.click, display: 1, x: 0.5, y: 0.5))
        try await t.session.deliver(ScreenInput(.key, display: 1, key: "a"))
        let inputs = t.backend.link.inputs
        #expect(inputs.map(\.move) == [true, false, false])
        let first = try JSONSerialization.jsonObject(with: inputs[0].json) as? [String: Any]
        #expect(first?["type"] as? String == "move" && first?["x"] as? Double == 0.5, "`/input`'s JSON body")
        t.backend.link.reject(YoyoError.http(409, "not in control"))
        await settle { !errors.isEmpty }
        guard case YoyoError.http(409, _)? = errors.first as? YoyoError else {
            Issue.record("the refusal reaches the page as a 409")
            return
        }
        t.session.deactivate()
    }

    @Test func theSoundGoesOnTheLinkIntoTheOutput() async throws {
        let t = Setup(audio: true)
        t.session.activate()
        #expect(t.net.audios.isEmpty, "no HTTP sound on a link way")
        let audio = try #require(t.backend.link.audios.first)
        #expect(audio.query.isEmpty)
        // no sound there: not asked again this visit
        audio.onEvent(.error(status: 404, message: nil))
        await settle { t.session.audioUnsupported }
        #expect(t.session.audioUnsupported)
        t.session.deactivate()
    }
}
