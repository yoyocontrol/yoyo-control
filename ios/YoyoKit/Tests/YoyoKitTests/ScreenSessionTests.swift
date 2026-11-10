import AVFoundation
import Foundation
import Testing
import UIKit
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The Screen page's session without its views: a fake backend, fake streams and sound streams, a fake page. The
/// stream opens, shows a picture, is ended by the server and reopens; an error is tried again later (no other
/// picture meanwhile); a stream head naming a codec this client didn't ask for is a failure; the backend's trust goes
/// with the stream and the sound; a backend with a routing moves its stream between ways.
@MainActor
@Suite("Screen session")
struct ScreenSessionTests {
    nonisolated static let mac = URL(string: "https://192.168.1.20:8723")!

    /// The screen requests, recorded (with the route each went on).
    final class Backend: YoyoBackend, @unchecked Sendable {
        let cacheScope = "screen-session-tests:\(UUID().uuidString)|alex"
        private let lock = NSLock()
        private var _options: [ScreenStreamOptions] = []
        private var _inputs: [ScreenInput] = []
        private var _routes: [String] = []
        private var _pinned = false
        private var _routing: (any YoyoRouting)?
        private var _failInputOn: String?

        var options: [ScreenStreamOptions] { lock.withLock { _options } }
        var inputs: [ScreenInput] { lock.withLock { _inputs } }
        /// "stream@lan", "audio@tunnel", "input@lan"…
        var routes: [String] { lock.withLock { _routes } }
        var pinned: Bool {
            get { lock.withLock { _pinned } }
            set { lock.withLock { _pinned = newValue } }
        }
        var routing: (any YoyoRouting)? {
            get { lock.withLock { _routing } }
            set { lock.withLock { _routing = newValue } }
        }
        /// Input on this route fails on the way.
        var failInputOn: String? {
            get { lock.withLock { _failInputOn } }
            set { lock.withLock { _failInputOn = newValue } }
        }

        private func note(_ what: String, _ route: YoyoRoute) { lock.withLock { _routes.append("\(what)@\(route.id)") } }

        @MainActor func makeRouting() -> (any YoyoRouting)? { routing }
        func trust(for route: YoyoRoute) -> YoyoTrust { pinned ? .custom { _, host in host == "192.168.1.20" } : .system }

        func status() async throws -> ScreenStatus { throw YoyoError.http(404, nil) }

        func streamRequest(display: UInt32?, maxWidth: Int?, quality: Int?, fps: Int?, options: ScreenStreamOptions,
                           route: YoyoRoute) throws -> URLRequest {
            lock.withLock { _options.append(options) }
            note("stream", route)
            return URLRequest(url: ScreenSessionTests.mac.appending(path: "stream"))
        }
        func ackRequest(_ ack: ScreenStreamAck, route: YoyoRoute) throws -> URLRequest {
            URLRequest(url: ScreenSessionTests.mac.appending(path: "stream/ack"))
        }
        func audioRequest(route: YoyoRoute) throws -> URLRequest {
            note("audio", route)
            return URLRequest(url: ScreenSessionTests.mac.appending(path: "audio"))
        }
        func input(_ input: ScreenInput, route: YoyoRoute) async throws {
            note("input", route)
            if failInputOn == route.id { throw URLError(.timedOut) }
            lock.withLock { _inputs.append(input) }
        }
        func setControl(_ controller: ScreenController, route: YoyoRoute) async throws -> ScreenStatus { throw YoyoError.http(404, nil) }
    }

    /// Two ways: a shortcut ("lan") that may come and go, and the one that always works ("tunnel").
    @MainActor
    final class Routing: YoyoRouting {
        static let tunnel = YoyoRoute(id: "tunnel", isLocalNetwork: false, isDirect: false, label: "tunnel")
        static let lan = YoyoRoute(id: "lan", isLocalNetwork: true, isDirect: true, isShortcut: true, label: "LAN")
        var current = Routing.tunnel
        var isDeciding = false
        var decisionWait: Duration = .milliseconds(200)
        var openTimeout: Duration = .seconds(3)
        var onChange: (@MainActor () -> Void)?
        var failures: [(route: String, unauthorized: Bool)] = []
        var acks: [Int?] = []
        var willOpen = 0
        func newVisit() {}
        func activate() {}
        func streamWillOpen() { willOpen += 1 }
        func leave() {}
        func streamFailed(on route: YoyoRoute, unauthorized: Bool) {
            failures.append((route.id, unauthorized))
            set(Self.tunnel)
        }
        func ackAnswered(on route: YoyoRoute, status: Int?) { acks.append(status) }
        func fallback(from route: YoyoRoute, after error: Error) async -> YoyoRoute? {
            route == Self.lan ? Self.tunnel : nil
        }
        func set(_ route: YoyoRoute, deciding: Bool = false) {
            current = route
            isDeciding = deciding
            onChange?()
        }
    }

    /// A stream the test drives (open, parts, end).
    final class Stream: ScreenStreamConnection, @unchecked Sendable {
        let request: URLRequest
        let trust: YoyoTrust
        let onOpen: ScreenStream.OnOpen
        let onPart: ScreenStream.OnPart
        let onEnd: ScreenStream.OnEnd
        private(set) var started = false
        private(set) var cancelled = false

        init(request: URLRequest, trust: YoyoTrust, onOpen: @escaping ScreenStream.OnOpen,
             onPart: @escaping ScreenStream.OnPart, onEnd: @escaping ScreenStream.OnEnd) {
            self.request = request; self.trust = trust; self.onOpen = onOpen; self.onPart = onPart; self.onEnd = onEnd
        }

        func start() { started = true }
        func cancel() { cancelled = true }
        func send(_ request: URLRequest, done: @escaping @Sendable (ScreenStreamReply) -> Void) { done(.init(status: 200)) }

        /// A real H.264 key picture: it goes through the router, the decoder and the player to the page
        /// (`Host.videoShown`).
        func picture() { onPart(TestVideo.part(Self.keyPicture, key: true)) }

        nonisolated static let keyPicture: Data = (try? TestVideo.h264(frames: 1))?.first ?? Data()
    }

    final class Audio: ScreenAudioConnection, @unchecked Sendable {
        let request: URLRequest
        let trust: YoyoTrust
        private(set) var started = false
        private(set) var stopped = false
        init(request: URLRequest, trust: YoyoTrust = .system) { self.request = request; self.trust = trust }
        func start() { started = true }
        func stop() { stopped = true }
        var videoOffsetMs: Double { ScreenAudioFormat.defaultVideoOffsetMs }
        var stats: ScreenAudio.Stats { ScreenAudio.Stats(buffer: nil, kbps: 0) }
    }

    @MainActor
    final class Host: ScreenSessionHost {
        var displayId: UInt32? = 1
        var displayIsMain = true
        var canShow = true
        var refreshes = 0
        var videoShown = 0
        var resets = 0
        var audioChanges = 0
        func sessionShowVideo(size: CGSize) { videoShown += 1 }
        func sessionFreezePicture() {}
        func sessionClearPicture() {}
        func sessionCursor(_ update: ScreenCursorUpdate) {}
        func sessionResetCursor() { resets += 1 }
        func sessionConnectionChanged() {}
        func sessionRefreshStatus() async { refreshes += 1 }
        func sessionAudioChanged() { audioChanges += 1 }
    }

    /// What the session opened.
    @MainActor
    final class Net {
        var streams: [Stream] = []
        var audios: [Audio] = []

        var environment: ScreenSession.Environment {
            ScreenSession.Environment(
                openStream: { [unowned self] request, _, trust, onOpen, onPart, onEnd in
                    let s = Stream(request: request, trust: trust, onOpen: onOpen, onPart: onPart, onEnd: onEnd)
                    streams.append(s)
                    return s
                },
                openAudio: { [unowned self] request, trust, _, _, _ in
                    let a = Audio(request: request, trust: trust)
                    audios.append(a)
                    return a
                },
                handle: { _ in false },
                watchesPath: false)
        }
    }

    @MainActor
    struct Setup {
        let backend = Backend()
        let host = Host()
        let net = Net()
        let defaults: UserDefaults
        let session: ScreenSession

        init(routing: Routing? = nil, configure: (UserDefaults) -> Void = { _ in }) {
            let name = "screen-session-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            configure(defaults)
            backend.routing = routing
            let output = ScreenVideoOutput(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer)
            session = ScreenSession(backend: backend, videoOutput: output, defaults: defaults,
                                    environment: net.environment)
            session.host = host
        }
    }

    /// Lets the main queue and the session's tasks run until `done` (or about a second).
    private func settle(until done: () -> Bool) async {
        for _ in 0..<100 {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aStreamThatShowedPicturesAndWasEndedByTheServerReopensAtOnce() async {
        let t = Setup()
        t.session.activate()
        #expect(t.net.streams.count == 1 && t.net.streams[0].started)
        #expect(t.net.streams[0].request.url == Self.mac.appending(path: "stream"))
        #expect(t.backend.options.first?.codecs.isEmpty == false)
        let first = t.net.streams[0]
        first.onOpen("h264")
        first.picture()
        // a picture went to the page: the stream is live (a later end is the Mac switching how it captures)
        await settle { t.host.videoShown > 0 }
        #expect(t.host.videoShown > 0 && t.session.hasFrame)
        first.onEnd(nil)
        await settle { t.net.streams.count == 2 }
        #expect(t.net.streams.count == 2 && t.net.streams[1].started)
        #expect(first.cancelled)
        #expect(!t.session.waitingToRetry)
        t.session.deactivate()
        #expect(t.net.streams[1].cancelled)
    }

    @Test func aStreamThatFailsBeforeAPictureIsTriedAgainLater() async {
        let t = Setup()
        t.session.activate()
        t.net.streams[0].onEnd(URLError(.networkConnectionLost))
        await settle { t.session.waitingToRetry }
        #expect(t.session.waitingToRetry && t.session.stream == nil)
        // the stream is tried again later (15 s), not at once, and nothing else is asked for meanwhile
        t.session.updateFrames()
        #expect(t.net.streams.count == 1)
        t.session.deactivate()
        #expect(!t.session.waitingToRetry)
    }

    @Test func aStreamHeadNamingAnotherCodecIsAFailure() async {
        let t = Setup()
        t.session.activate()
        let first = t.net.streams[0]
        first.onOpen("mjpeg")
        await settle { t.session.waitingToRetry }
        #expect(first.cancelled && t.session.stream == nil && t.session.waitingToRetry)
        t.session.deactivate()
        // a head that names none (URLSession split the stream: its first response was a part): its pictures play
        let u = Setup()
        u.session.activate()
        let split = u.net.streams[0]
        split.onOpen(nil)
        split.picture()
        await settle { u.host.videoShown > 0 }
        #expect(u.host.videoShown > 0 && !split.cancelled && !u.session.waitingToRetry)
        u.session.deactivate()
    }

    @Test func theBackendsTrustGoesWithTheStreamAndTheSound() async throws {
        let t = Setup()
        t.backend.pinned = true
        t.session.activate()
        #expect(t.net.streams.count == 1 && !t.net.streams[0].trust.followsRedirects)
        #expect(t.net.streams[0].request.url?.host() == "192.168.1.20")
        #expect(t.net.audios.count == 1 && !t.net.audios[0].trust.followsRedirects)
        t.session.deactivate()
        // a backend that leaves it to the system
        let u = Setup()
        u.session.activate()
        #expect(u.net.streams[0].trust.followsRedirects && u.net.audios[0].trust.followsRedirects)
        u.session.deactivate()
    }

    @Test func theSoundOpensWithTheStreamAndLivesThroughAReopen() async {
        let t = Setup()
        t.session.activate()
        // asked for as the stream's request goes out
        #expect(t.net.audios.count == 1 && t.net.audios[0].started)
        #expect(t.net.audios[0].request.url == Self.mac.appending(path: "audio"))
        let first = t.net.streams[0]
        first.onOpen("h264")
        first.picture()
        await settle { t.host.videoShown > 0 }
        first.onEnd(nil)
        await settle { t.net.streams.count == 2 }
        #expect(t.net.streams.count == 2)
        #expect(t.net.audios.count == 1 && !t.net.audios[0].stopped)
        // turned off: it stops; on again: a new one
        t.session.setAudioOn(false)
        #expect(t.net.audios[0].stopped && t.session.audioOutput == nil)
        #expect(t.defaults.object(forKey: ScreenAudio.defaultsKey) as? Bool == false)
        t.session.setAudioOn(true)
        #expect(t.net.audios.count == 2 && t.net.audios[1].started)
        t.session.deactivate()
        #expect(t.net.audios[1].stopped)
    }

    @Test func soundOffStaysOffAcrossStreams() async {
        let t = Setup { $0.set(false, forKey: ScreenAudio.defaultsKey) }
        t.session.activate()
        #expect(t.net.streams.count == 1 && t.net.audios.isEmpty && !t.session.audioOn)
        t.session.deactivate()
    }

    @Test func aFingerMakesSmoothPlaybackInteractive() async {
        let t = Setup()
        t.session.activate()
        #expect(!t.session.stats.live().interactive)
        t.session.touchBegan()
        #expect(t.session.stats.live().interactive)
        // the linger after the finger lifts, then back
        t.session.touchEnded()
        #expect(t.session.stats.live().interactive)
        t.session.endInteractive()
        #expect(!t.session.stats.live().interactive)
        t.session.deactivate()
    }

    @Test func theLatencyEstimateFollowsTheInputRoundTrip() async {
        let t = Setup()
        t.session.activate()
        #expect(t.session.latencyEstimate() == nil, "no round trip yet")
        t.session.stats.inputAnswered(route: .lan, ms: 100)
        let estimate = t.session.latencyEstimate()
        // 50 there + 30 on the Mac + 50 back + one 60 Hz refresh (no playout yet)
        #expect(estimate.map { abs($0 - (50 + 30 + 50 + 1000.0 / 60)) < 0.01 } == true)
        #expect(t.session.statsText().contains("~147 ms"))
        t.session.deactivate()
    }

    @Test func inputGoesToTheMacAndIsTimed() async throws {
        let t = Setup()
        t.session.activate()
        try await t.session.deliver(.pointer(.move, display: 1, at: CGPoint(x: 0.5, y: 0.5)))
        #expect(t.backend.inputs.map(\.type) == [.move])
        #expect(t.session.stats.netReport()?.inputRttMs?.n == 1)
        t.session.deactivate()
    }

    // MARK: Routing (a backend with more than one way)

    @Test func aStreamWaitsAMomentForATryOnItsWayThenMovesWithTheWay() async {
        let routing = Routing()
        routing.isDeciding = true
        let t = Setup(routing: routing)
        t.session.activate()
        // a try is on its way: the stream waits for it
        #expect(t.net.streams.isEmpty && routing.willOpen == 1)
        routing.set(Routing.lan)
        #expect(t.net.streams.count == 1 && t.backend.routes.prefix(2) == ["stream@lan", "audio@lan"])
        #expect(t.session.way == Routing.lan)
        // the way changes back: the stream (and the sound) move
        routing.set(Routing.tunnel)
        #expect(t.net.streams.count == 2 && t.net.streams[0].cancelled)
        #expect(t.backend.routes.suffix(2) == ["stream@tunnel", "audio@tunnel"])
        #expect(t.net.audios.count == 2 && t.net.audios[0].stopped)
        t.session.deactivate()
    }

    @Test func aWaitingStreamOpensOnTheCurrentWayWhenTheTryTakesTooLong() async {
        let routing = Routing()
        routing.isDeciding = true
        routing.decisionWait = .milliseconds(30)
        let t = Setup(routing: routing)
        t.session.activate()
        #expect(t.net.streams.isEmpty)
        await settle { !t.net.streams.isEmpty }
        #expect(t.net.streams.count == 1 && t.backend.routes.first == "stream@tunnel")
        t.session.deactivate()
    }

    @Test func aShortcutStreamThatFailsGoesTheOtherWayAtOnce() async {
        let routing = Routing()
        routing.current = Routing.lan
        let t = Setup(routing: routing)
        t.session.activate()
        #expect(t.backend.routes.first == "stream@lan")
        t.net.streams[0].onEnd(URLError(.networkConnectionLost))
        await settle { t.net.streams.count == 2 }
        #expect(routing.failures.map(\.route) == ["lan"] && routing.failures[0].unauthorized == false)
        #expect(t.net.streams.count == 2 && t.backend.routes.contains("stream@tunnel"))
        #expect(!t.session.waitingToRetry, "not counted as a failure to retry later")
        t.session.deactivate()
    }

    @Test func aShortcutRefusingTheCredentialIsTheRoutingsNotASignOut() async {
        let routing = Routing()
        routing.current = Routing.lan
        let t = Setup(routing: routing)
        t.session.activate()
        t.net.streams[0].onEnd(YoyoError.http(401, nil))
        await settle { t.net.streams.count == 2 }
        #expect(routing.failures.first?.unauthorized == true)
        t.session.deactivate()
    }

    @Test func inputThatFailsOnTheShortcutGoesTheOtherWay() async throws {
        let routing = Routing()
        routing.current = Routing.lan
        let t = Setup(routing: routing)
        t.session.activate()
        t.backend.failInputOn = "lan"
        try await t.session.deliver(ScreenInput(.click, x: 0.5, y: 0.5))
        #expect(t.backend.routes.filter { $0.hasPrefix("input") } == ["input@lan", "input@tunnel"])
        #expect(t.backend.inputs.count == 1)
        t.session.deactivate()
    }

    @Test func aBackendWithoutRoutingUsesItsOneWay() async {
        let t = Setup()
        t.session.activate()
        #expect(t.backend.routes.first == "stream@direct" && t.session.way == .direct)
        #expect(t.session.statsText().contains("direct"))
        t.session.deactivate()
    }
}

@Suite("Screen latency estimate")
struct ScreenLatencyEstimateTests {
    @Test func nothingWithoutARoundTrip() {
        #expect(ScreenLatencyEstimate.estimate(inputRttP50Ms: nil, ackRttMinMs: nil, holdMs: 30, decodeMs: 2, refreshHz: 120) == nil)
        #expect(ScreenLatencyEstimate.estimate(inputRttP50Ms: .nan, ackRttMinMs: -1, holdMs: 30, decodeMs: 2, refreshHz: 120) == nil)
    }

    @Test func theWayThereTheMacTheWayBackThePlayoutAndARefresh() throws {
        let e = try #require(ScreenLatencyEstimate.estimate(inputRttP50Ms: 100, ackRttMinMs: 80, holdMs: 30, decodeMs: 2,
                                                            refreshHz: 120))
        #expect(abs(e - (50 + 30 + 40 + 30 + 2 + 1000.0 / 120)) < 1e-9)
        #expect(ScreenLatencyEstimate.text(e) == "~160 ms")
    }

    @Test func oneRoundTripStandsInForTheOther() throws {
        // no input answered yet: the ack round trip both ways
        let ack = try #require(ScreenLatencyEstimate.estimate(inputRttP50Ms: nil, ackRttMinMs: 60, holdMs: nil, decodeMs: nil,
                                                              refreshHz: nil))
        #expect(abs(ack - (30 + 30 + 30 + 1000.0 / 60)) < 1e-9)
        // no grade from the server yet: the input round trip both ways
        let input = try #require(ScreenLatencyEstimate.estimate(inputRttP50Ms: 40, ackRttMinMs: nil, holdMs: 0, decodeMs: 1,
                                                                refreshHz: 60))
        #expect(abs(input - (20 + 30 + 20 + 1 + 1000.0 / 60)) < 1e-9)
    }

    @Test func badNumbersAreLeftOut() throws {
        let e = try #require(ScreenLatencyEstimate.estimate(inputRttP50Ms: 20, ackRttMinMs: 20, holdMs: .infinity, decodeMs: -3,
                                                            refreshHz: 0))
        #expect(abs(e - (10 + 30 + 10 + 1000.0 / 60)) < 1e-9)
    }
}
