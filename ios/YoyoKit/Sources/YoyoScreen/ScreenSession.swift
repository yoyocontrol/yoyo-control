import CoreTelephony
import Network
import UIKit
import YoyoClipboard
import YoyoCore

/// The Screen page's view of a `ScreenSession`: what is shown (the display, whether it can be), and where the session's
/// pictures, pointer and connection state go. Main actor.
@MainActor
protocol ScreenSessionHost: AnyObject {
    /// The display shown (nil = the server's default, the main one).
    var displayId: UInt32? { get }
    /// The display shown is the main one (or none is known yet).
    var displayIsMain: Bool { get }
    /// The picture can be shown (the Mac has a screen and Screen Recording).
    var canShow: Bool { get }
    /// A decoded video picture of `size` is showing (it went straight to the video output).
    func sessionShowVideo(size: CGSize)
    /// The last video picture becomes a still (it stays while the picture is on its way back).
    func sessionFreezePicture()
    /// Another display: the picture and the pointer drawn here go.
    func sessionClearPicture()
    func sessionCursor(_ update: ScreenCursorUpdate)
    /// The pointer drawn here goes (the stream's pictures have their own).
    func sessionResetCursor()
    /// `shownConnection` or `hasFrame` changed: the overlay, the dimmed still, the note.
    func sessionConnectionChanged()
    /// `GET /screen` again (a stream or a frame said the display is gone, or the main display's id changed).
    func sessionRefreshStatus() async
    /// The sound turned out not to be there (`audioUnsupported`).
    func sessionAudioChanged()
}

extension ScreenStreamOptions {
    /// What the screen page asks for, for every display: video (HEVC where it decodes in hardware, else H.264), a fresh
    /// stream id with acks, the pointer as cursor parts (the computer leaves it out of the pictures), and status parts.
    static func live(codecs: [ScreenCodec] = ScreenVideoCodec.requestedCodecs()) -> ScreenStreamOptions {
        ScreenStreamOptions(codecs: codecs, stream: newStreamId(), ack: true, clientCursor: true, status: true)
    }
}

/// Video that can't be played on this stream (`ScreenVideoDecoderCore.Outcome.unplayable`): the stream's failure.
struct ScreenVideoUnplayable: Error {}

/// A screen stream connection as the session uses it (`ScreenStream`; tests and in-process streams fake it:
/// `YoyoStreamSource`).
public protocol ScreenStreamConnection: AnyObject, Sendable {
    func start()
    func cancel()
    /// Sends a small request (an ack) on the stream's session; `done` gets how it went.
    func send(_ request: URLRequest, done: @escaping @Sendable (ScreenStreamReply) -> Void)
}

extension ScreenStream: ScreenStreamConnection {}

/// A sound stream as the session uses it (`ScreenAudio`; tests fake it).
protocol ScreenAudioConnection: AnyObject, Sendable {
    func start()
    func stop()
    var videoOffsetMs: Double { get }
    var stats: ScreenAudio.Stats { get }
}

extension ScreenAudio: ScreenAudioConnection {}

/// A sound stream that plays nothing (`YoyoStreamSource.openAudio` → `.silent`): the speaker button shows as if the
/// computer had sound.
final class ScreenSilentAudio: ScreenAudioConnection, @unchecked Sendable {
    func start() {}
    func stop() {}
    var videoOffsetMs: Double { ScreenAudioFormat.defaultVideoOffsetMs }
    var stats: ScreenAudio.Stats { ScreenAudio.Stats(buffer: nil, kbps: 0) }
}

/// A backend whose streams are served in-process (a demo computer, UI tests) rather than over HTTP: the Screen page
/// asks it for a stream's and the sound's connection before running their requests itself.
public protocol YoyoStreamSource: Sendable {
    /// The picture stream `request` asks for: parts to `onPart` (a video part's headers say its codec, size and seq),
    /// `onOpen` once with its `X-Stream-Codec` (nil: none), `onEnd` when it ends (nil: cleanly).
    @MainActor func openStream(_ request: URLRequest, onOpen: @escaping @Sendable (String?) -> Void,
                               onPart: @escaping @Sendable (ScreenStreamPart) -> Void,
                               onEnd: @escaping @Sendable (Error?) -> Void) -> any ScreenStreamConnection
    /// The sound `request` asks for; nil: run the request over HTTP as usual.
    @MainActor func openAudio(_ request: URLRequest) -> YoyoLocalAudio?
}

/// What an in-process backend plays as sound.
public enum YoyoLocalAudio: Sendable {
    /// Nothing (silence), with the speaker button shown.
    case silent
}

/// One visit of the Screen page, without its views (docs/PROTOCOL.md「屏幕」): the way to the computer (the backend's
/// `route`, or its `YoyoRouting`: a stream waits a moment for a try on its way, moves when the way changes, and a
/// shortcut that fails goes back to the other way at once), the stream (its request, open / end / reopen,
/// ScreenStreamReopenPolicy, the retry after a failure), its acks (ScreenAckSender on the stream's own
/// session), parts (ScreenStreamRouter), decoders and smooth playback (ScreenPlayer, its touch budget from the ack
/// answers' round trip, interactive while a finger is down or keys are typed), the computer's sound (ScreenAudio into
/// the visit's ScreenAudioOutput, on the stream's way) and the A/V sync (ScreenAVSync), the playout report and the
/// network sampler (ScreenStreamStats), and the connection state (ScreenConnectionModel). Input goes through `deliver`,
/// control and focus through `control` / `focus` (the way in use; on a failure the routing may name another).
/// Pictures, the pointer and the connection state go to the `host` (the page). Main actor.
@MainActor
final class ScreenSession {
    /// How the session reaches the network (`live`; tests fake the streams).
    struct Environment {
        var openStream: @MainActor (_ request: URLRequest, _ stats: ScreenStreamStats, _ trust: YoyoTrust,
                                    _ onOpen: @escaping ScreenStream.OnOpen, _ onPart: @escaping ScreenStream.OnPart,
                                    _ onEnd: @escaping ScreenStream.OnEnd) -> any ScreenStreamConnection
        var openAudio: @MainActor (_ request: URLRequest, _ trust: YoyoTrust, _ output: ScreenAudioOutput,
                                   _ tuning: ScreenAudioTuning, _ onEnd: @escaping ScreenAudio.OnEnd) -> any ScreenAudioConnection
        /// A 401 (`YoyoHost.handleError`): true = handled, nothing more to do.
        var handle: @MainActor (Error) -> Bool
        /// The network path is watched for the network report (`NWPathMonitor`).
        var watchesPath = true

        static var live: Environment {
            Environment(
                openStream: { request, stats, trust, onOpen, onPart, onEnd in
                    ScreenStream(request: request, stats: stats, trust: trust, onOpen: onOpen, onPart: onPart, onEnd: onEnd)
                },
                openAudio: { request, trust, output, tuning, onEnd in
                    ScreenAudio(request: request, trust: trust, output: output, tuning: tuning, onEnd: onEnd)
                },
                handle: { YoyoHost.current.handleError($0) })
        }

        /// `live`, with an in-process backend's streams (`YoyoStreamSource`) in place of HTTP.
        static func live(for backend: any YoyoBackend) -> Environment {
            var e = Environment.live
            guard let source = backend as? any YoyoStreamSource else { return e }
            e.openStream = { request, _, _, onOpen, onPart, onEnd in
                source.openStream(request, onOpen: onOpen, onPart: onPart, onEnd: onEnd)
            }
            let http = e.openAudio
            e.openAudio = { request, trust, output, tuning, onEnd in
                switch source.openAudio(request) {
                case .silent?: ScreenSilentAudio()
                case nil: http(request, trust, output, tuning, onEnd)
                }
            }
            return e
        }
    }

    let backend: any YoyoBackend
    weak var host: (any ScreenSessionHost)?
    /// Where decoded video pictures go (the page's display layer).
    let videoOutput: ScreenVideoOutput
    private let environment: Environment
    private let defaults: UserDefaults
    /// The backend's ways to the computer when it has more than one (nil: always `backend.route`).
    let routing: (any YoyoRouting)?

    /// Visible and in the foreground (or kept running in the background: `background`).
    private(set) var active = false
    /// Running while the app is in the background (Picture in Picture): pictures are shown as they come
    /// (`ScreenPlayer.setShowsOnArrival`).
    private(set) var background = false

    // Frames
    /// Bumped whenever what's shown changes (display, stop): frames of an older generation are dropped.
    private var generation = 0
    private(set) var stream: (any ScreenStreamConnection)?
    /// Identifies `stream` (callbacks of a replaced one are ignored).
    private var streamToken = 0
    private var streamLive = false
    /// When the current stream was opened (for how quickly it ended).
    private var streamOpenedAt: ContinuousClock.Instant?
    /// Whether an ended stream is reopened at once or tried again later (`retryStreamAfter`).
    private var reopenPolicy = ScreenStreamReopenPolicy()
    /// Whether the current stream draws the pointer itself (then the one drawn here goes).
    private var cursorPolicy = ScreenStreamCursorPolicy()
    /// The stream failed: it is tried again after `retryStreamAfter` (`retryTask`), or sooner when the display's
    /// state says it can be had again (`reopenIfReady`).
    private(set) var waitingToRetry = false
    private var retryTask: Task<Void, Never>?
    /// A picture was shown since the display was chosen (the overlay keeps a still).
    private(set) var hasFrame = false
    /// The current stream's acks, video decoder and cursor (stopped with the stream).
    private var router: ScreenStreamRouter?
    /// The current stream's smooth playback (nil: low latency, or no stream).
    private(set) var player: ScreenPlayer?
    /// The current stream, for its acks' transport (emptied with it: that breaks the stream → acks → stream cycle).
    private var streamBox: ScreenStreamBox?
    /// The current stream when it goes on a uu Link session, for the decoder's answers (emptied with it, likewise).
    private var linkRef: ScreenLinkStreamRef?
    /// The uu Link session the last stream went on (a new one on the same way is a new chance for a failed stream).
    private weak var streamLink: (any YoyoScreenLink)?
    /// Which way the current stream goes (the sound goes the same way).
    private(set) var streamRoute: YoyoRoute
    /// The current stream answered (its response headers came): a stream on a shortcut that doesn't within the
    /// routing's `openTimeout` counts as failed there.
    private var streamResponded = false
    private var openCheck: Task<Void, Never>?

    // Sound (ScreenAudio): on the stream's way while the stream is open
    /// The speaker button's setting.
    private(set) var audioOn: Bool
    private(set) var audio: (any ScreenAudioConnection)?
    /// Identifies `audio` (callbacks of a replaced one are ignored).
    private var audioToken = 0
    /// Which way `audio` goes.
    private var audioRoute: YoyoRoute?
    private var audioOpenedAt: ContinuousClock.Instant?
    /// The sound is tried again after it ended (ScreenAudioPolicy, which counts the quick ends in a row).
    private var audioRetryTask: Task<Void, Never>?
    private var audioPolicy = ScreenAudioPolicy()
    /// The sound stream ended by itself and is to be opened again (even with no picture stream open right now).
    private var audioReopening = false
    /// The server has no sound (404), or none this client plays: not asked again this visit, the button hidden.
    private var audioGaveUp = false
    /// `GET /screen` says the computer has no sound now (`features.audio == false`): not asked for, the button hidden,
    /// until a status says otherwise.
    private(set) var audioOffByServer = false
    /// No sound this visit, the speaker button hidden: found out by asking, or said by the server.
    var audioUnsupported: Bool { audioGaveUp || audioOffByServer }
    /// The sound's way out, for the visit (the sound streams come and go; ScreenAudioOutput): made with the first one,
    /// stopped (the audio session given back) when the page goes or the sound is turned off.
    private(set) var audioOutput: ScreenAudioOutput?
    /// The sound's level on this device (YoyoScreenSession.audioVolume).
    var audioVolume = 1.0 {
        didSet { audioOutput?.setVolume(audioVolume) }
    }
    /// The host keeps the audio session (YoyoScreenSession.hostManagesAudioSession): for the next output made.
    var hostManagesAudioSession = false
    /// A/V sync (ScreenAVSync), run by `syncTimer` while sound and pictures play; its last output.
    private var avSync = ScreenAVSync()
    private var syncTimer: Timer?
    /// The sync's last output for the current sound stream's reports (read on the stream's queue).
    private var audioSyncBox: ScreenAudioSyncBox?

    // Route (the routing's, when the backend has one)
    /// When the try on its way began: a stream about to open waits up to the routing's `decisionWait` for it.
    private var routeTrySince: ContinuousClock.Instant?
    /// A stream waits for the try on its way (`openStream` runs again when it settles or the wait is up).
    private var pendingOpen = false
    private var routeWaitTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    /// The cellular radio for the network report (made the first time the path is cellular).
    private var telephony: CTTelephonyNetworkInfo?

    // Connection state (live / reconnecting / unavailable)
    private var connection = ScreenConnectionModel()
    /// What the page shows of it now.
    private(set) var shownConnection = ScreenConnectionModel.Output(phase: .live)
    /// Wakes the page when an unexplained gap turns into "Reconnecting".
    private var connectionTimer: Task<Void, Never>?
    private var connectionDeadline: ContinuousClock.Instant?
    /// The display can't be shown: the stream isn't reopened until its state changes, Retry, or the Mac's next try.
    private var waitingOnUnavailable = false

    /// The stats line's and the playout report's counters (codec, fps, KB/s, decode ms; the playout; the network).
    let stats = ScreenStreamStats()

    /// A finger on the picture: smooth playback shows pictures at once (back 800 ms after the last one lifts).
    private var interactivity = ScreenInteractivity()
    private var interactivityTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    static let retryStreamAfter: Duration = .seconds(15)
    static let quality = 60
    /// Every display: as smooth as the Mac can deliver. With the video stream a frame costs a few KB and only changes
    /// are sent, so asking for 60 is cheap; the Mac's screen sharing, its encoder and the ack window cap the real
    /// rate.
    static let fps = 60
    /// The jitter buffer's depth before it has measured anything, on the local network (elsewhere the default 25 ms).
    static let lanDefaultDepth = 0.010
    /// The smooth playback's cap off the local network (the local network keeps `ScreenPlayout.Config`'s 100 ms): on 5G
    /// the jitter's p95 runs past 100 ms, and at the cap the phone hitched twice a second while watching. Interactive
    /// pictures go by the interactive depth (≤ 30 ms), not this.
    nonisolated static let remoteMaxDepth = 0.200
    /// The release of control gets this long (seconds).
    static let releaseTimeout: Double = 5
    static let syncEvery: TimeInterval = 0.25

    private var displayId: UInt32? { host?.displayId }
    private var canShow: Bool { host?.canShow ?? false }

    /// The sound setting is read from `defaults`. `routing`: the backend's (`makeRouting()`, by default).
    init(backend: any YoyoBackend, videoOutput: ScreenVideoOutput, routing: (any YoyoRouting)?? = nil,
         defaults: UserDefaults = .standard, environment: Environment? = nil) {
        self.backend = backend
        self.videoOutput = videoOutput
        self.routing = routing ?? backend.makeRouting()
        self.defaults = defaults
        self.environment = environment ?? .live(for: backend)
        streamRoute = backend.route
        audioOn = ScreenAudio.isOn(defaults)
        // `ScreenControlDevice.current` names this phone (a backend may send it with input and control)
        ScreenControlDevice.prime()
        // what counts as the way being down, for the network report
        ScreenNetSampler.setUnreachable { [backend] status, message in backend.isUnreachable(status: status, message: message) }
        self.routing?.onChange = { [weak self] in self?.routeChanged() }
        observers.append(NotificationCenter.default.addObserver(forName: .CTServiceRadioAccessTechnologyDidChange, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let telephony = self.telephony else { return }
                self.stats.netRadio(ScreenNetPath.currentRadio(telephony))
            }
        })
    }

    isolated deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        stream?.cancel()
        router?.stop()
        streamBox?.stream = nil
        audio?.stop()
        audioOutput?.stop()
        syncTimer?.invalidate()
        audioRetryTask?.cancel()
        retryTask?.cancel()
        interactivityTask?.cancel()
        connectionTimer?.cancel()
        routeWaitTask?.cancel()
        openCheck?.cancel()
        pathMonitor?.cancel()
    }

    // MARK: Lifecycle

    /// A new visit: the sound is tried again, the way chosen afresh.
    func newVisit() {
        audioGaveUp = false
        audioPolicy.reset()
        reopenPolicy.reset()
        routing?.newVisit()
    }

    /// The page shows (it appeared, or came back from the background).
    func activate() {
        active = true
        startPathMonitor()
        routing?.activate()
        updateFrames()
        updateConnection()
    }

    /// The page stops: the stream, the sound, playback's interactivity. The way stays until `leaveRoute` (control may
    /// still be given back on it).
    /// `timer`: each step's time (the stop's log line).
    func deactivate(timer: ScreenStepTimer? = nil) {
        active = false
        stopFrames(timer: timer)
        stopAudio(releasingOutput: true)
        timer?.mark("audio")
        connectionTimer?.cancel()
        connectionTimer = nil
        connectionDeadline = nil
        endInteractive()
        timer?.mark("interactive")
    }

    /// The app went to the background (true) with the session still running, or came back (false).
    func setBackground(_ on: Bool) {
        guard background != on else { return }
        background = on
        player?.setShowsOnArrival(on)
    }

    /// After `deactivate` (and the release of control went out): back from the background, the way is chosen again.
    func leaveRoute() {
        pathMonitor?.cancel()
        pathMonitor = nil
        routing?.leave()
    }

    // MARK: Status (from the page)

    /// The connection model shows the main display.
    var showsMain: Bool { connection.showsMain }

    /// The model's idea of what is shown.
    func syncConnectionTarget() {
        connection.target(display: displayId, main: host?.displayIsMain ?? true)
    }

    /// A `GET /screen` answer: the model's target and the displays' states; the sound as the server says it is.
    func statusChanged(_ s: ScreenStatus) {
        syncConnectionTarget()
        connection.states(s.states, console: s.console, at: .now)
        soundFeatureChanged(ScreenFeatures.soundOff(s.features))
    }

    /// `features.audio == false`: the sound stops (if it was on its way) and isn't asked for; anything else (true, not
    /// said) asks again as before (404 / 503 decide, `ScreenAudioPolicy`).
    private func soundFeatureChanged(_ off: Bool) {
        guard off != audioOffByServer else { return }
        audioOffByServer = off
        if off {
            stopAudio(releasingOutput: true)
        } else {
            audioPolicy.reset()
            syncAudio()
        }
        host?.sessionAudioChanged()
    }

    /// A `screen.state` event (the page's status already has them).
    func statesChanged(_ states: [ScreenDisplayState], console: ScreenConsole?) {
        let before = connection.output(at: .now).state
        connection.states(states, console: console, at: .now)
        // the main display's id changed (displays reconfigured): `GET /screen` has its new id
        if connection.showsMain, let main = states.first(where: \.main), let id = displayId, main.display != id,
           !states.contains(where: { $0.display == id }) {
            Task { [weak self] in await self?.host?.sessionRefreshStatus() }
        }
        updateConnection()
        reopenIfReady(changedFrom: before)
    }

    /// The stream is closed (waiting to retry after a failure, or waiting on an unavailable display) and the display's state
    /// just changed to one it can be had in: reopen now rather than at the next try.
    private func reopenIfReady(changedFrom before: ScreenDisplayState?) {
        guard active, canShow, stream == nil else { return }
        let o = connection.output(at: .now)
        guard let s = o.state, before.map({ !$0.shows(like: s) }) ?? true else { return }
        guard waitingOnUnavailable ? !o.phase.isUnavailable : waitingToRetry && s.phase == .ready else { return }
        retryTask?.cancel()
        retryTask = nil
        waitingOnUnavailable = false
        waitingToRetry = false
        openStream()
    }

    /// Retry (the display was unavailable): ask again now, keeping the still. (The page asks for the status too.)
    func retryConnection() {
        connection.retry(at: .now)
        reopenPolicy.reset()
        stopFrames()
        updateFrames()
        updateConnection()
    }

    // MARK: Frames

    /// Starts showing when it can and isn't already; stops when it can't.
    func updateFrames() {
        guard active, canShow else { stopFrames(); stopAudio(); return }
        if stream == nil, !waitingToRetry { openStream() }
    }

    /// Another display: the picture goes, and what was known of the last one's connection.
    func restartFrames() {
        stopFrames(keepingPicture: false)
        host?.sessionClearPicture()
        hasFrame = false
        connection.reset()
        syncConnectionTarget()
        updateFrames()
        updateConnection()
        host?.sessionConnectionChanged()
    }

    /// `keepingPicture`: a video picture becomes a still (it stays while the picture is on its way back).
    func stopFrames(keepingPicture: Bool = true, timer: ScreenStepTimer? = nil) {
        generation += 1
        dropStream(keepingPicture: keepingPicture, timer: timer)
        waitingToRetry = false
        retryTask?.cancel()
        retryTask = nil
        waitingOnUnavailable = false
        pendingOpen = false
        routeWaitTask?.cancel()
        routeWaitTask = nil
        timer?.mark("frames")
    }

    /// The current stream ends here (its acks and video decoder too). `keepingPicture`: its last video picture is
    /// kept as a still first (the next stream's first picture replaces it).
    private func dropStream(keepingPicture: Bool = true, timer: ScreenStepTimer? = nil) {
        if stream != nil {
            if keepingPicture { host?.sessionFreezePicture() }
            connection.streamEnded(at: .now)
        }
        timer?.mark("freeze")
        stream?.cancel()
        stream = nil
        timer?.mark("stream")
        router?.stop()
        router = nil
        timer?.mark("decoder")
        player?.stop()
        player = nil
        timer?.mark("player")
        streamBox?.stream = nil
        streamBox = nil
        linkRef?.stream = nil
        linkRef = nil
        streamLive = false
        openCheck?.cancel()
        openCheck = nil
    }

    private func openStream() {
        pendingOpen = false
        // a stream with pictures replaced (moved to another way): the last picture is held meanwhile
        if stream != nil, streamLive { connection.reopening(at: .now) }
        dropStream()
        // every stream asks which way to go first: a try may start here, and the stream waits a moment for it
        routing?.streamWillOpen()
        if let routing, routing.isDeciding {
            let since = routeTrySince ?? .now
            routeTrySince = since
            let wait = routing.decisionWait
            if ContinuousClock.now - since < wait {
                pendingOpen = true
                if routeWaitTask == nil {
                    routeWaitTask = Task { [weak self] in
                        try? await Task.sleep(until: since + wait, clock: .continuous)
                        guard !Task.isCancelled, let self else { return }
                        self.routeWaitTask = nil
                        if self.pendingOpen, self.active, self.canShow { self.openStream() }
                    }
                }
                return
            }
        }
        pendingOpen = false
        waitingToRetry = false
        routeWaitTask?.cancel()
        routeWaitTask = nil
        streamToken += 1
        let token = streamToken
        let generation = self.generation
        let route = currentRoute
        streamRoute = route
        // a way that carries the media itself (uu Link): the same query, without acks (its media layer paces the stream)
        let link = backend.screenLink(for: route)
        streamLink = link
        var options = ScreenStreamOptions.live()
        if link != nil { options.ack = false }
        let width = ScreenStreamOptions.videoMaxWidth
        let request: URLRequest
        do {
            request = try backend.streamRequest(display: displayId, maxWidth: width, quality: Self.quality, fps: Self.fps,
                                                options: options, route: route)
        } catch { streamFailed(token, error); return }
        streamResponded = false
        streamOpenedAt = .now
        cursorPolicy.streamOpened()
        connection.streamOpened()

        let backend = self.backend
        let stats = self.stats
        let output = self.videoOutput
        let onLan = link?.isLocalNetwork ?? route.isLocalNetwork
        stats.streamStarted(mode: .smooth, route: route.report, at: CACurrentMediaTime())
        // the touch budget from the latest ack answer's round trip (else the route's default)
        let touchBudget: @Sendable () -> Double? = { ScreenTouchBudget.auto(rttMinMs: stats.freshRttMin(), onLan: onLan) }
        let streamRef = ScreenStreamBox()
        let linkRef = ScreenLinkStreamRef()
        let main: @Sendable (@escaping @MainActor @Sendable (ScreenSession) -> Void) -> Void = { [weak self] work in
            DispatchQueue.main.async { MainActor.assumeIsolated { if let self { work(self) } } }
        }
        let player = ScreenPlayer(output: output, stats: stats, evenPace: true,
                                  maxDepth: onLan ? nil : Self.remoteMaxDepth, defaultDepth: onLan ? Self.lanDefaultDepth : nil,
                                  touchBudget: touchBudget(), onShown: { size, _ in
            main { $0.showVideo(size, token: token, generation: generation) }
        })
        // a stream opened while a finger is on the picture (or keys are typed) starts interactive
        if interactivity.interactive { player.setInteractive(true) }
        // one opened in the background (a reopen while in Picture in Picture) shows pictures as they come
        if background { player.setShowsOnArrival(true) }
        let reportsAcks = routing != nil && route.isShortcut
        let acks = (link == nil ? options.stream : nil).map { id in
            ScreenAckSender(stream: id) { ack, done in
                let request = try? backend.ackRequest(ack, route: route)
                guard let s = streamRef.stream, let request else {
                    done(.failed)
                    return
                }
                s.send(request) { reply in
                    let status = reply.status
                    let ok = status.map { (200..<300).contains($0) } == true
                    done(status == 404 ? .gone : ok ? .ok : .failed)
                    // the network's grade (only while this is still the page's stream), and acks lost on the way
                    if let q = reply.netQuality, streamRef.stream != nil { stats.netQuality(q) }
                    if reply.isNetworkFailure { stats.requestFailed() }
                    // the touch budget follows the round trip (and falls back once the last one is too old)
                    if streamRef.stream != nil { player.setTouchBudget(touchBudget()) }
                    // on a shortcut, acks failing in a row (or a 401) may send the stream back to the other way
                    if reportsAcks { main { $0.ackAnswered(status: status, route: route, token: token) } }
                }
            }
        }
        // on a link: every picture's outcome goes back (what the computer's encoder may reference next)
        let decodedOnLink: @Sendable (ScreenStreamPart, Bool) -> Void = { part, ok in
            if let frame = part.linkFrame { stats.traceDecoded(frame: frame, ok: ok) }
            linkRef.stream?.decoded(part, ok: ok)
        }
        let onDecoded = link == nil ? nil : decodedOnLink
        let router = ScreenStreamRouter(acks: acks, stats: stats, handlers: .init(
            makeDecoder: { codec in
                ScreenVideoDecoder(codec: codec, output: output, playout: player,
                                   onKeyframeNeeded: {
                                       acks?.requestKeyframe()
                                       linkRef.stream?.requestKeyframe()
                                   },
                                   onPicture: { size, ms, part in
                                       stats.shown(decodeMs: ms, at: CACurrentMediaTime(), macTime: part.macTime)
                                       main { $0.showVideo(size, token: token, generation: generation) }
                                   },
                                   onUnplayable: { main { $0.videoFailed(token) } },
                                   onDecoded: onDecoded)
            },
            onCursor: { update in main { $0.cursorChanged(update, token: token) } },
            onStatus: { status in main { $0.streamStatus(status, token: token) } }))
        let onOpen: ScreenStream.OnOpen = { codec in
            // the head names the stream's video codec; one this client didn't ask for isn't a stream it can play. A head
            // without one is a stream URLSession splits itself (its first response is already the first part, e.g. a
            // status part): its video parts say their codec.
            if let codec {
                guard ScreenCodec(rawValue: codec) != nil else {
                    main { $0.streamFailed(token, YoyoError.decoding("screen stream codec \(codec)")) }
                    return
                }
                stats.set(codec: codec)
            }
            main { $0.streamOpened(token) }
        }
        let onPart: ScreenStream.OnPart = { part in router.route(part) }
        let onEnd: ScreenStream.OnEnd = { error in main { $0.streamFailed(token, error) } }
        let s: any ScreenStreamConnection
        if let link {
            let ls = ScreenLinkStream(link: link, query: request.url?.query(percentEncoded: true) ?? "", stats: stats,
                                      onOpen: onOpen, onPart: onPart, onEnd: onEnd,
                                      onRtt: { player.setTouchBudget(touchBudget()) })
            linkRef.stream = ls
            self.linkRef = linkRef
            s = ls
        } else {
            s = environment.openStream(request, stats, backend.trust(for: route), onOpen, onPart, onEnd)
        }
        streamRef.stream = s
        stream = s
        streamBox = streamRef
        self.router = router
        self.player = player
        s.start()
        // the sound is asked for now, on the same way (not after the stream's answer: it starts sooner)
        syncAudio()
        if let routing, route.isShortcut {
            let timeout = routing.openTimeout
            openCheck = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self, token == self.streamToken, self.stream != nil, !self.streamResponded else { return }
                // the shortcut answered its try but the stream doesn't come: the other way
                self.routing?.streamFailed(on: route, unauthorized: false)
            }
        }
    }

    /// The way requests go now.
    var currentRoute: YoyoRoute { routing?.current ?? backend.route }

    /// The current stream's response came.
    private func streamOpened(_ token: Int) {
        guard token == streamToken else { return }
        streamResponded = true
        openCheck?.cancel()
        openCheck = nil
        syncAudio()
    }

    /// A decoded video picture is showing (it went straight to the display layer).
    private func showVideo(_ size: CGSize, token: Int, generation: Int) {
        guard token == streamToken, generation == self.generation, active else { return }
        host?.sessionShowVideo(size: size)
        pictureShown()
        streamDelivered(token)
    }

    /// A new picture shows: the still and the overlay go.
    private func pictureShown() {
        connection.picture(at: .now)
        if !hasFrame {
            hasFrame = true
            host?.sessionConnectionChanged()
        }
        updateConnection()
    }

    /// A status part of the current stream.
    private func streamStatus(_ status: ScreenStreamStatus, token: Int) {
        guard token == streamToken, active else { return }
        connection.status(status, at: .now)
        updateConnection()
    }

    // MARK: Connection state

    /// Shows what the connection model says now, and wakes up when that changes by itself.
    func updateConnection() {
        let now = ContinuousClock.now
        let o = connection.output(at: now)
        scheduleConnectionUpdate(at: connection.deadline(after: now))
        guard o != shownConnection else { return }
        let wasLive = shownConnection.phase.isLive
        shownConnection = o
        if wasLive, !o.phase.isLive { host?.sessionFreezePicture() }
        host?.sessionConnectionChanged()
    }

    private func scheduleConnectionUpdate(at deadline: ContinuousClock.Instant?) {
        guard deadline != connectionDeadline else { return }
        connectionDeadline = deadline
        connectionTimer?.cancel()
        connectionTimer = nil
        guard let deadline, active else { return }
        connectionTimer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.connectionTimer = nil
            self.connectionDeadline = nil
            self.updateConnection()
        }
    }

    /// Video doesn't work on this stream (it kept failing, or its format can't be made): the stream ends as a failure
    /// (its last picture stays as a still) and is tried again later.
    private func videoFailed(_ token: Int) {
        guard token == streamToken, active else { return }
        streamFailed(token, ScreenVideoUnplayable())
    }

    private func cursorChanged(_ update: ScreenCursorUpdate, token: Int) {
        guard token == streamToken, active else { return }
        cursorPolicy.cursorPart()
        host?.sessionCursor(update)
    }

    /// The stream shows a picture. The first time: a retry waiting is no longer needed, and a pointer drawn here for an
    /// earlier stream goes if this one has the pointer in its pictures.
    private func streamDelivered(_ token: Int) {
        guard token == streamToken, stream != nil else { return }
        if cursorPolicy.picture() { host?.sessionResetCursor() }
        guard !streamLive else { return }
        streamLive = true
        waitingToRetry = false
        retryTask?.cancel()
        retryTask = nil
    }

    /// The stream failed or ended: reopen it at once when the server ended a working stream (ScreenStreamReopenPolicy),
    /// else try it again after `retryStreamAfter` (the last picture stays as a still, the connection state says why).
    private func streamFailed(_ token: Int, _ error: Error?) {
        guard token == streamToken, active else { return }
        let delivered = streamLive
        let lifetime = streamOpenedAt.map { ContinuousClock.now - $0 } ?? .zero
        let route = streamRoute
        let shortcut = routing != nil && route.isShortcut
        dropStream()
        // a shortcut's credential the computer doesn't know (any more): the routing gets a fresh one or goes the other way
        // (never a sign-out)
        if shortcut, Self.isUnauthorized(error) {
            routing?.streamFailed(on: route, unauthorized: true)
            openStream()
            return
        }
        if let error, environment.handle(error) { return }
        updateConnection()
        // the Mac says the display can't be shown: wait for its state to change, a Retry, or the Mac's next try
        if case let .unavailable(_, retryAt) = connection.output(at: .now).phase {
            stopAudio()
            waitingOnUnavailable = true
            retryTask?.cancel()
            let wait = ScreenConnectionModel.retryDelay(retryAt: retryAt)
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self, self.active, self.canShow, self.stream == nil else { return }
                self.retryTask = nil
                self.waitingOnUnavailable = false
                self.openStream()
            }
            return
        }
        // a stream on a shortcut that failed, or ended before a picture: the other way at once (not counted as a quick
        // end). A clean end after pictures is the computer switching how it captures: reopened on the same way below.
        if shortcut, error != nil || !delivered {
            routing?.streamFailed(on: route, unauthorized: false)
            openStream()
            return
        }
        if case let .reopen(delay) = reopenPolicy.streamEnded(delivered: delivered, failed: error != nil, lifetime: lifetime) {
            // the Mac switching how it serves the picture: the last one stays, undimmed, while the next stream opens
            connection.reopening(at: .now)
            updateConnection()
            retryTask?.cancel()
            retryTask = nil
            guard delay > .zero else { openStream(); return }
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.active, self.canShow, self.stream == nil else { return }
                self.retryTask = nil
                self.openStream()
            }
            return
        }
        if case YoyoError.http(let code, _)? = error, code == 403 || code == 503 || code == 404 {
            Task { [weak self] in await self?.host?.sessionRefreshStatus() }
        }
        waitingToRetry = true
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.retryStreamAfter)
            guard !Task.isCancelled, let self, self.active, self.canShow, self.stream == nil else { return }
            self.retryTask = nil
            self.openStream()
        }
    }

    // MARK: Sound

    /// The speaker button: the sound on (now, not after a try that was waiting) or off (the audio session goes back).
    func setAudioOn(_ on: Bool) {
        audioOn = on
        defaults.set(on, forKey: ScreenAudio.defaultsKey)
        if on {
            audioRetryTask?.cancel()
            audioRetryTask = nil
            audioPolicy.reset()
            syncAudio()
        } else {
            stopAudio(releasingOutput: true)
        }
    }

    /// The sound plays on the stream's way (asked for as the first stream's request goes out, not after its answer):
    /// started, or moved when the stream moved (a LAN stream, back to the tunnel…): a new sound stream into the same
    /// output, which fades out and in. The sound has a stream of its own: a reopen of the pictures on the same way, a
    /// stream between two (a reopen after a pause, a retry) leave it playing, and a sound stream that ended reopens
    /// without waiting for the pictures. Only a display that can't be shown stops it (`waitingOnUnavailable`).
    private func syncAudio() {
        guard active, canShow, audioOn, !audioUnsupported, !waitingOnUnavailable, audioRetryTask == nil,
              stream != nil || audio != nil || audioReopening else { return }
        if audio != nil, audioRoute == streamRoute { return }
        startAudio()
    }

    private func startAudio() {
        let resumed = audioReopening
        audioReopening = false
        audio?.stop()
        audio = nil
        audioToken += 1
        let token = audioToken
        let route = stream != nil ? streamRoute : currentRoute
        let link = backend.screenLink(for: route)
        let request: URLRequest
        do {
            request = try backend.audioRequest(route: route)
        } catch {
            audioEnded(token, error)
            return
        }
        let output: ScreenAudioOutput
        if let audioOutput {
            output = audioOutput
        } else {
            var settings = ScreenAudioOutput.Settings()
            settings.managesSession = !hostManagesAudioSession
            output = ScreenAudioOutput(settings: settings)
            output.setVolume(audioVolume)
            audioOutput = output
        }
        // the local network's floor when the computer is on it, else the one for a path that may cross the internet
        var tuning = ScreenAudioTuning(lan: link?.isLocalNetwork ?? route.isLocalNetwork)
        // after a sound stream that ended by itself: the next one fades in slowly (the last one faded out)
        tuning.resumed = resumed
        let onEnd: ScreenAudio.OnEnd = { [weak self] error in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.audioEnded(token, error) } }
        }
        // on a uu Link session: `audio.open` with `/audio`'s query, its packets into the same output
        let a: any ScreenAudioConnection = if let link {
            ScreenLinkAudio(link: link, query: request.url?.query(percentEncoded: true) ?? "", output: output, tuning: tuning,
                            onEnd: onEnd)
        } else {
            environment.openAudio(request, backend.trust(for: route), output, tuning, onEnd)
        }
        audio = a
        audioRoute = route
        audioOpenedAt = .now
        // the playout report carries the sound's while this stream is open (the A/V numbers as the sync last had them)
        let sync = ScreenAudioSyncBox()
        audioSyncBox = sync
        stats.setAudioReport { [weak output] in
            let s = sync.value
            return output?.report(skewMs: s.skew.map { $0 * 1000 }, floorMs: s.videoFloor * 1000)
        }
        a.start()
        updateSyncTimer()
    }

    /// The sound stops (no stream, the page, the setting); a try waiting goes too. `releasingOutput`: the engine stops
    /// and the audio session goes back (the page goes, the sound is turned off or not there); else the output stays for
    /// the next sound stream of this visit.
    private func stopAudio(releasingOutput: Bool = false) {
        audioRetryTask?.cancel()
        audioRetryTask = nil
        audioReopening = false
        audio?.stop()
        audio = nil
        audioRoute = nil
        endAudioStream()
        if releasingOutput {
            audioOutput?.stop()
            audioOutput = nil
        }
    }

    /// No sound stream open: no report, no sync.
    private func endAudioStream() {
        stats.setAudioReport(nil)
        audioSyncBox = nil
        avSync = ScreenAVSync()
        player?.setSyncFloor(0)
        audioOutput?.setSyncDepth(nil)
        updateSyncTimer()
    }

    /// The sound's stream ended by itself (its last ~80 ms fade out in the output, `ScreenAudio`): again at once, or a
    /// little later when that keeps failing (ScreenAudioPolicy), or not this visit. The buffer keeps its depth for the
    /// next stream, which fades in.
    private func audioEnded(_ token: Int, _ error: Error?) {
        guard token == audioToken else { return }
        let lifetime = audioOpenedAt.map { ContinuousClock.now - $0 } ?? .zero
        audio?.stop()
        audio = nil
        endAudioStream()
        switch audioPolicy.ended(error: error, lifetime: lifetime) {
        case .giveUp:
            audioRoute = nil
            audioGaveUp = true
            audioOutput?.stop()
            audioOutput = nil
            host?.sessionAudioChanged()
        case .retry(let delay):
            audioRoute = nil
            audioReopening = true
            audioRetryTask?.cancel()
            audioRetryTask = nil
            guard delay > .zero else { syncAudio(); return }
            audioRetryTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.audioRetryTask = nil
                self.syncAudio()
            }
        }
    }

    // MARK: A/V sync

    /// The sync runs while a sound stream and smooth pictures play (and the page is active).
    private func updateSyncTimer() {
        guard active, audio != nil else {
            syncTimer?.invalidate()
            syncTimer = nil
            return
        }
        guard syncTimer == nil else { return }
        let t = Timer(timeInterval: Self.syncEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        syncTimer = t
    }

    /// Sound and picture delays → the playout's sync floor, the sound's sync depth, the numbers of the report
    /// (ScreenAVSync).
    private func syncTick() {
        guard let output = audioOutput, let audio else { return }
        let now = CACurrentMediaTime()
        let snap = output.snapshot(at: now)
        let offset = audio.videoOffsetMs / 1000
        let outLatency = snap.outputLatency ?? 0
        let video = player != nil ? stats.live(at: now).playout.flatMap(ScreenAVSync.videoDelays) : nil
        var input = ScreenAVSync.Input()
        if let b = snap.buffer {
            input.audioDelay = ScreenAVSync.audioDelay(b, outputLatency: outLatency, offset: offset)
            input.audioOwnDelay = ScreenAVSync.audioOwnDelay(b, outputLatency: outLatency, offset: offset)
        }
        input.videoDelay = video?.smooth
        input.shownDelay = video?.shown
        input.interactive = interactivity.interactive
        input.soundRecent = snap.lastSoundAt.map { now - $0 < ScreenAVSync.silentAfter } ?? false
        let out = avSync.update(input)
        audioSyncBox?.value = out
        player?.setSyncFloor(out.videoFloor)
        if let goal = out.audioDelayGoal, let base = snap.buffer?.base {
            output.setSyncDepth(ScreenAVSync.syncDepth(goal: goal, base: base, outputLatency: outLatency, offset: offset))
        } else {
            output.setSyncDepth(nil)
        }
    }

    // MARK: Route (the backend's, or its routing's)

    /// Which way requests go now (the stream's while one is open).
    var way: YoyoRoute { stream != nil ? streamRoute : currentRoute }

    /// The routing's way or its tries changed: a stream waiting for a try that is over opens; a stream on another way
    /// than the current one moves there (the sound with it).
    private func routeChanged() {
        guard let routing else { return }
        if !routing.isDeciding {
            routeTrySince = nil
            if pendingOpen, active, canShow {
                openStream()
                return
            }
        }
        if stream != nil, streamRoute != routing.current, active, canShow, !pendingOpen { openStream() }
        // a stream that failed on a way left behind, or on a link whose session ended (a new session on the same way),
        // needn't wait for its retry
        let newLink = backend.screenLink(for: routing.current).map { $0 !== streamLink } ?? false
        if stream == nil, waitingToRetry, !waitingOnUnavailable, streamRoute != routing.current || newLink, active, canShow,
           !pendingOpen, !routing.isDeciding {
            retryTask?.cancel()
            retryTask = nil
            openStream()
        }
    }

    /// An ack of the current stream on a shortcut came back (`status` nil: it failed on the way).
    private func ackAnswered(status: Int?, route: YoyoRoute, token: Int) {
        guard token == streamToken, streamRoute == route else { return }
        routing?.ackAnswered(on: route, status: status)
    }

    /// `op` on the way in use; when it fails, the routing may name another way to send the same request on (once).
    private func run<T: Sendable>(_ route: YoyoRoute, _ op: @escaping @Sendable (YoyoRoute) async throws -> T) async throws -> T {
        do {
            return try await op(route)
        } catch {
            if Task.isCancelled { throw error }
            guard let routing, let next = await routing.fallback(from: route, after: error), next != route else { throw error }
            return try await op(next)
        }
    }

    /// Take or release control, the way in use.
    func control(_ controller: ScreenController) async throws -> ScreenStatus {
        try await control(controller, on: way)
    }

    /// Take or release control on `route` (a release as the page goes still goes out on the way it was on).
    func control(_ controller: ScreenController, on route: YoyoRoute) async throws -> ScreenStatus {
        let backend = self.backend
        return try await run(route) { route in try await backend.setControl(controller, route: route) }
    }

    /// The focus, the way in use.
    func focus(display: UInt32?) async throws -> ScreenFocus {
        let backend = self.backend
        return try await run(way) { route in try await backend.focus(display: display, route: route) }
    }

    /// A 401 (`YoyoError.unauthorized`, or an HTTP 401 a backend passed on as it is).
    nonisolated static func isUnauthorized(_ error: Error?) -> Bool {
        switch error {
        case YoyoError.unauthorized?, YoyoError.http(401, _)?: true
        default: false
        }
    }

    /// Watches the network path while the page is active, for the network report.
    private func startPathMonitor() {
        guard pathMonitor == nil, environment.watchesPath else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let net = ScreenNetPath.from(path, radio: nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.netPathUpdated(net) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "ca.sarria.yoyocontrol.screen-path", qos: .utility))
        pathMonitor = monitor
    }

    /// The network report's path (on cellular with the data service's radio).
    private func netPathUpdated(_ path: ScreenNetSampler.Path) {
        var path = path
        if path.iface == .cellular {
            let telephony = self.telephony ?? CTTelephonyNetworkInfo()
            self.telephony = telephony
            path.radio = ScreenNetPath.currentRadio(telephony)
        }
        stats.netPath(path)
    }

    // MARK: Input

    /// One input to the computer, the way in use; when that fails and the routing names another way, the same input at
    /// once there (a click is never lost). Each try is timed for the network report: an answered one is a round trip of
    /// the way it went, one that failed on the way a failure.
    func deliver(_ input: ScreenInput) async throws {
        if let send = linkInput() {
            try send(input)
            return
        }
        let backend = self.backend
        let stats = self.stats
        try await run(way) { route in
            let start = CACurrentMediaTime()
            do {
                try await backend.input(input, route: route)
                let end = CACurrentMediaTime()
                stats.inputAnswered(route: route.report, ms: (end - start) * 1000, at: end)
            } catch {
                if ScreenNetSampler.isNetworkFailure(error) { stats.requestFailed() }
                throw error
            }
        }
        noteDelivered(input)
    }

    private func noteDelivered(_ input: ScreenInput) {
        if let onDelivered {
            delivered.append(input.type.rawValue)
            onDelivered(delivered)
        }
    }

    /// Input refused on a uu Link session (`input.rejected`), or never acknowledged there: the page's error handling
    /// (`ScreenControlledElsewhere`, a 409 that ends control…), as for a failed `POST /input`.
    var onInputError: (@MainActor (Error) -> Void)?
    /// The link whose input errors come here.
    private weak var inputLink: (any YoyoScreenLink)?

    /// When the way in use is a uu Link session: how one input goes there at once (in order, nothing waits for an
    /// answer; a refusal comes later to `onInputError`). nil: `deliver`'s requests.
    func linkInput() -> (@MainActor (ScreenInput) throws -> Void)? {
        guard let link = backend.screenLink(for: way) else { return nil }
        if inputLink !== link {
            inputLink = link
            link.setInputErrorHandler { [weak self] error in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onInputError?(error) } }
            }
        }
        return { [weak self] input in
            let json = try JSONSerialization.data(withJSONObject: input.json)
            try link.sendInput(json, move: input.type == .move)
            self?.noteDelivered(input)
        }
    }

    /// UI tests (`-<namespace>InputLog YES`): every input the computer took, by kind, in order.
    var onDelivered: (([String]) -> Void)?
    private var delivered: [String] = []
    // MARK: Interactive playback (a finger on the picture, keys)

    /// The first finger came down on the picture (in control).
    func touchBegan() {
        interactivityTask?.cancel()
        interactivityTask = nil
        if interactivity.began() { setPlayerInteractive(true) }
    }

    /// The last finger lifted: back to smooth after the linger.
    func touchEnded() {
        guard let until = interactivity.ended(at: .now) else { return }
        endInteractive(at: until)
    }

    /// A key or text went to the Mac: interactive for a moment too (its echo shouldn't wait in the smooth buffer).
    func keySent() {
        let (became, until) = interactivity.key(at: .now)
        if became { setPlayerInteractive(true) }
        if let until { endInteractive(at: until) }
    }

    /// Back to smooth at `until`, unless a finger or a key comes first.
    private func endInteractive(at until: ContinuousClock.Instant) {
        interactivityTask?.cancel()
        interactivityTask = Task { [weak self] in
            try? await Task.sleep(until: until, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.interactivityTask = nil
            if self.interactivity.expire(at: .now) { self.setPlayerInteractive(false) }
        }
    }

    /// The playing stream's player turns interactive or back.
    private func setPlayerInteractive(_ on: Bool) {
        player?.setInteractive(on)
    }

    /// Back to smooth now (control gone, the page stops).
    func endInteractive() {
        interactivityTask?.cancel()
        interactivityTask = nil
        if interactivity.reset() { setPlayerInteractive(false) }
    }

    // MARK: Stats line

    /// The client-side latency estimate now (ScreenLatencyEstimate; ms, nil: no round trip known). `decodeMs`: the
    /// stats line's (nil: the last few seconds').
    func latencyEstimate(decodeMs: Double? = nil, at now: Double = CACurrentMediaTime()) -> Double? {
        let live = stats.live(at: now)
        return ScreenLatencyEstimate.estimate(inputRttP50Ms: live.net?.inputRttMs?.p50, ackRttMinMs: stats.freshRttMin(at: now),
                                              holdMs: live.playout.map { $0.hold * 1000 },
                                              decodeMs: decodeMs ?? live.decodeMs, refreshHz: live.playout?.refreshHz)
    }

    /// The stats line (a tick takes the window's counters): codec, fps, KB/s, decode ms, the way, the connection; the
    /// playout and the latency estimate; the server's grade (on a uu Link session: the link's own numbers); the sound.
    func statsText() -> String {
        let connection = ScreenConnectionText.stats(self.connection.output(at: .now))
        let snap = stats.take()
        let link = backend.screenLink(for: self.way)
        let way = link?.pathLabel ?? self.way.label
        let second = [snap.playout?.line, latencyEstimate(decodeMs: snap.decodeMs).map(ScreenLatencyEstimate.text)]
            .compactMap { $0 }.joined(separator: " · ")
        let net = link.map { $0.statsLine } ?? snap.net.map(\.line)
        return " \(snap.line) · \(way) · \(connection) " + (second.isEmpty ? "" : "\n \(second) ")
            + (net.map { "\n \($0) " } ?? "") + (audio.map { "\n \($0.stats.line) " } ?? "")
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
