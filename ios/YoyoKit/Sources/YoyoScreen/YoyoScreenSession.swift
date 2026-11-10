import AVFoundation
import UIKit
import YoyoClipboard
import YoyoCore

/// When a `YoyoScreenSession` takes the screen (docs/PROTOCOL.md「客户端什么时候拿控制权」).
public enum YoyoControlPolicy: Sendable, Equatable {
    /// The first real input takes it (a finger on the trackpad, the keyboard, a key, typed text, a paste into the
    /// computer), then goes: the user wins over automation. Another phone's control is only taken with `takeControl()`.
    /// The kit's Screen page works so.
    case takeOnInput
    /// Only `takeControl()` takes it. Until then input is dropped (nothing is sent, nothing asks for control): a page
    /// that lets someone watch automation at work without a stray touch stopping it.
    case explicit
}

/// Why this session no longer controls the screen (`YoyoScreenSession.Notice.lostControl`).
public enum YoyoScreenControlLoss: Sendable, Equatable {
    /// Another phone took control (its name as shown: "Mia's iPhone", "Another iPhone"…).
    case takenOver(by: String)
    /// The computer refused an input: this phone doesn't control any more (409; e.g. it let go after a while).
    case refused
    /// A status or `screen.control` event says the agent or nobody holds it now.
    case ended

    /// What to tell the user (nil: nothing needs saying).
    public var message: String? {
        switch self {
        case let .takenOver(name): L("\(name) took over")
        case .refused: L("You no longer have control of the screen.")
        case .ended: nil
        }
    }
}

/// A computer's screen without any views (docs/PROTOCOL.md「屏幕」): what a page shows and drives it with. The stream,
/// its acks and smooth playback, the sound and the A/V sync, the way to the computer and the connection state
/// (`ScreenSession`); the status (`GET /screen`, every 10 s while active, and the backend's events: `screen.control`,
/// the displays' states, the clipboard), the displays and the one shown, whose computer it is (`YoyoComputer`); who
/// controls it (`controlModel`, `isControlling`, `takeControl()`, `releaseControl()`) and when it is taken
/// (`YoyoControlPolicy`); the input (`send`, clicks, scrolls, drags, keys, the armed modifiers; one queue,
/// `ScreenInputQueue`), and after a click whether the focus takes typing (a `YoyoScreenKeyboard` comes up); the
/// clipboard's moves.
///
/// Views attach to it: a `YoyoScreenPictureView` shows its pictures, a `YoyoTrackpadView` and a `YoyoScreenKeyboard`
/// make input; any number of observers hear what changes (`observe`). `start()` when the page shows, `stop()` when it
/// goes; in between the app going to the background stops it (control this session took is given back) and coming
/// back starts it again, unless `continuesInBackground` (Picture in Picture). The kit's Screen page
/// (`YoyoScreen.makePage`) is made of these. Main actor.
@MainActor
public final class YoyoScreenSession {
    /// What changed (an observer's `Update.changed`).
    public struct Changes: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// The status: the displays, the display shown, whether the picture can be shown (`canShow`) and controlled.
        public static let status = Changes(rawValue: 1 << 0)
        /// Who holds the screen, `isControlling`, `isTakingControl`.
        public static let control = Changes(rawValue: 1 << 1)
        /// The connection (live / on its way back / unavailable) or the first picture (`hasPicture`).
        public static let connection = Changes(rawValue: 1 << 2)
        /// The sound: on / off, or found not to be there (`hasAudio`).
        public static let audio = Changes(rawValue: 1 << 3)
        /// Whose computer it is (`computer`: a status said its platform).
        public static let computer = Changes(rawValue: 1 << 4)
        /// The clipboard: whether the computer has one (`hasClipboard`), what it holds.
        public static let clipboard = Changes(rawValue: 1 << 5)
        /// The armed modifiers (`modifiers`).
        public static let modifiers = Changes(rawValue: 1 << 6)
        /// Started or stopped (`isActive`).
        public static let activity = Changes(rawValue: 1 << 7)
    }

    /// Something that happened once (an observer's `Update.notice`).
    public enum Notice: Sendable, Equatable {
        /// A short notice for the user (a toast): an error, "Pasted on Mac"…
        case message(String)
        /// This session took the screen (a haptic; the first time, the gestures).
        case tookControl
        /// This session no longer controls the screen, and why.
        case lostControl(YoyoScreenControlLoss)
        /// An input came that doesn't take the screen: another phone holds it (`.takeOnInput`), or the policy is
        /// `.explicit` and this session doesn't control it. A host's take button may say how to take it.
        case nudge
    }

    public enum Update: Sendable, Equatable {
        case changed(Changes)
        case notice(Notice)
    }

    public let backend: any YoyoBackend
    public let controlPolicy: YoyoControlPolicy

    /// Whose screen this is: a Mac's or another computer's (the backend's hint until a status says its `platform`).
    public private(set) var computer: YoyoComputer
    /// The last `GET /screen` answer (nil: none yet, or it failed: `statusError`).
    public private(set) var status: ScreenStatus?
    /// Why there is no status.
    public private(set) var statusError: Error?
    /// The display shown (nil = the server's default, the main one).
    public private(set) var displayId: UInt32?
    /// Who holds the screen as this phone sees it.
    public private(set) var controlModel = ScreenControlModel()
    /// A take of control is on its way.
    public private(set) var isTakingControl = false
    /// The host shows the picture alone, view only (a full-screen player): no input, nothing takes the screen, and
    /// control this session took is given back as it turns on.
    public var viewOnly = false {
        didSet {
            guard viewOnly != oldValue else { return }
            if viewOnly {
                dropFocusLook()
                liftDrag()
                releaseControl()
            }
            changed(.control)
        }
    }

    /// Keeps the session running while the app is in the background (false, the default: the background stops it, as
    /// the kit's Screen page wants). For a host that shows the picture in Picture in Picture
    /// (`YoyoScreenPictureView.videoDisplayLayer`): going to the background, the stream, the sound, the status, the
    /// events and the way to the computer go on, and coming back nothing starts again or chooses the way afresh. Control
    /// this session took is still given back as the app goes (nothing can drive the computer from there; a drag under
    /// way is lifted, input still queued dropped, a take on its way given straight back), and in the background
    /// pictures show as they come (smooth playback's display link doesn't run there). The audio session is the sound's
    /// as ever (`.playback`); keeping the app running in the background (the Audio, AirPlay and Picture in Picture
    /// background mode, Picture in Picture actually showing) is the host's. Turned off while in the background, the
    /// session stops there as it would have.
    public var continuesInBackground = false {
        didSet {
            guard !continuesInBackground, oldValue, inBackground else { return }
            inBackground = false
            inner.setBackground(false)
            deactivate(release: true)
        }
    }
    /// Running in the background (`continuesInBackground`).
    private(set) var inBackground = false

    /// The internal session: the stream, the sound, the way, the connection state.
    let inner: ScreenSession
    let videoOutput = ScreenVideoOutput()
    /// The picture view that shows the session now (its pictures, the pointer drawn, the stills).
    weak var picture: YoyoScreenPictureView?
    /// The keyboard that comes up for an editable focus.
    weak var keyboard: YoyoScreenKeyboard?
    /// Where the session presents what it must (the photo / file picker, the Clipboard page): nil = the view
    /// controller of the keyboard or the picture view.
    public weak var presenter: UIViewController?

    /// This session took control (given back when it stops).
    private(set) var heldByMe = false
    /// What the real inputs that asked for control wait to do once the take is through (in order; dropped if it fails).
    private var afterTake: [() -> Void] = []
    private var takeTask: Task<Void, Error>?
    /// `start()` was called and not `stop()`: the session runs while the app is in the foreground.
    public private(set) var isStarted = false
    private var statusTimer: Timer?
    /// The backend's events while active (who controls, the displays' states, the clipboard).
    private var eventsTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var watchers: [Int: @MainActor (Update) -> Void] = [:]
    private var nextWatcher = 0

    // Input: in order; scrolls added up and pointer moves merged while they are on their way (ScreenInputQueue).
    // Cancelled when the session stops: input still queued behind a slow send is dropped. On a uu Link session it goes
    // at once (the link orders it; refusals come back through `inner.onInputError`).
    private lazy var input = ScreenInputQueue(
        send: { [weak self] input in try await self?.inner.deliver(input) },
        failed: { [weak self] error in self?.inputFailed(error) },
        link: { [weak self] in self?.inner.linkInput() })
    /// A live drag pressed the computer's left button (its display and where the pointer is): lifted on `endDrag`, or
    /// straight away (past the queue) when the session stops.
    private var dragHeld: (display: UInt32?, point: CGPoint)?
    /// Armed modifiers: they apply to the next key or click.
    public private(set) var modifiers: Set<ScreenModifier> = []
    /// After a click: whether the computer's focused element takes typing (then the keyboard comes up). Dropped at the
    /// next touch.
    private var focusTask: Task<Void, Never>?
    /// The server can't tell (404): not asked again this visit.
    private var focusUnsupported = false
    /// A key or text went out (the page puts its hints away).
    var onKeySent: (() -> Void)?

    // Clipboard (YoyoScreenSession+Clipboard.swift)
    var clipboardGate = ScreenClipboardGate()
    /// The computer has the clipboard (the clipboard keys show).
    public internal(set) var hasClipboard = false
    /// The computer's clipboard as last known (the `clipboard` resource).
    var clipboardStatus: ClipboardStatus?
    /// The computer's change count known before the latest (nil: not heard yet: the first answer is no change).
    var macCountKnown: Int?
    /// A clipboard move is on its way (a second tap waits).
    var clipboardBusy = false
    let clipboardPicker = ClipboardPicker()
    /// The clipboard resource changed (the page's hints and dot): the hint the computer's change calls for.
    var onClipboardChange: ((ScreenClipboardHint?) -> Void)?

    static let statusEvery: TimeInterval = 10
    /// When the focus is looked at after a click is sent (later looks for apps slow to move it, or a browser building
    /// its accessibility tree for the first time, which takes a few seconds).
    static let focusLooks: [Duration] = [.milliseconds(250), .milliseconds(650), .milliseconds(1500)]

    /// A session for `backend`'s computer, taking the screen as `controlPolicy` says. Nothing runs until `start()`.
    public convenience init(backend: any YoyoBackend, controlPolicy: YoyoControlPolicy = .takeOnInput) {
        self.init(backend: backend, controlPolicy: controlPolicy, inner: nil)
    }

    /// `inner`: tests' (else the live one over `backend`).
    init(backend: any YoyoBackend, controlPolicy: YoyoControlPolicy, inner: ScreenSession?) {
        self.backend = backend
        self.controlPolicy = controlPolicy
        // what the computer said before, if it did (else the backend's hint)
        computer = YoyoComputer.of(platform: YoyoCapabilities.platform(scope: backend.cacheScope), hint: backend.platformHint)
        self.inner = inner ?? ScreenSession(backend: backend, videoOutput: videoOutput)
        self.inner.host = self
        self.inner.onInputError = { [weak self] error in self?.inputFailed(error) }
        updateClipboardCapability(YoyoCapabilities.features(scope: backend.cacheScope))
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] note in
            let scene = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.ownsScene(scene) else { return }
                self.appDidEnterBackground()
            }
        })
        observers.append(nc.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] note in
            let scene = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, self.ownsScene(scene) else { return }
                self.appWillEnterForeground()
            }
        })
    }

    isolated deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        eventsTask?.cancel()
        input.cancel()
        focusTask?.cancel()
        statusTimer?.invalidate()
    }

    /// A scene's background / foreground is this session's: the picture view's (or the keyboard's) scene, else any.
    private func ownsScene(_ scene: ObjectIdentifier?) -> Bool {
        guard let mine = picture?.window?.windowScene ?? keyboard?.window?.windowScene else { return true }
        return scene == ObjectIdentifier(mine)
    }

    // MARK: Observing

    /// `handler` hears every change and notice from now on, until the returned observation is cancelled or released.
    /// Any number of observers (a picture view, a trackpad, the page); in the order they were added.
    public func observe(_ handler: @escaping @MainActor (Update) -> Void) -> YoyoScreenObservation {
        let id = nextWatcher
        nextWatcher += 1
        watchers[id] = handler
        return YoyoScreenObservation(session: self, id: id)
    }

    func removeWatcher(_ id: Int) { watchers[id] = nil }

    private func publish(_ update: Update) {
        for (_, w) in watchers.sorted(by: { $0.key < $1.key }) { w(update) }
    }

    func notice(_ n: Notice) { publish(.notice(n)) }

    /// Tells the observers; out of control, playback is smooth again and no modifier stays armed.
    func changed(_ c: Changes) {
        var c = c
        if !isControlling {
            inner.endInteractive()
            if !modifiers.isEmpty {
                modifiers = []
                c.insert(.modifiers)
            }
        }
        publish(.changed(c))
    }

    // MARK: Lifecycle

    /// The session runs: the stream, the sound, the status and events (a new visit: video and the sound are tried
    /// again, the way chosen afresh). Again after the app comes back from the background, until `stop()`.
    public func start() {
        isStarted = true
        if !inner.active {
            focusUnsupported = false
            inner.newVisit()
            changed(.audio)
        }
        activate()
    }

    /// The session stops (the page goes): the stream, the sound, the input still queued; `release`: control this
    /// session took is given back.
    public func stop(release: Bool = true) {
        let timer = ScreenStepTimer("stop")
        isStarted = false
        if inBackground {
            inBackground = false
            inner.setBackground(false)
            timer.mark("foreground")
        }
        deactivate(release: release, timer: timer)
        timer.end()
    }

    /// The session's scene went to the background: it stops, or (`continuesInBackground`) runs on without control.
    func appDidEnterBackground() {
        guard isStarted else { return }
        guard continuesInBackground else { deactivate(release: true); return }
        guard isActive, !inBackground else { return }
        inBackground = true
        inner.setBackground(true)
        liftDrag()
        input.cancel()
        dropFocusLook()
        releaseControl()
    }

    /// The session's scene is coming back: it starts again (it stopped), or picks up where it was (it ran on).
    func appWillEnterForeground() {
        guard isStarted else { return }
        if inBackground {
            inBackground = false
            inner.setBackground(false)
            return
        }
        activate()
    }

    /// Running now (started, and the app in the foreground, or in the background with `continuesInBackground`).
    public var isActive: Bool { inner.active }

    private func activate() {
        guard !inner.active else { return }
        statusTimer?.invalidate()
        let t = Timer(timeInterval: Self.statusEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.refreshStatus() } }
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
        inner.activate()
        followEvents()
        Task { await refreshStatus() }
        changed(.activity)
    }

    /// `timer`: each step's time (the stop's log line).
    private func deactivate(release: Bool, timer: ScreenStepTimer? = nil) {
        // the stream, the sound, playback's interactivity
        inner.deactivate(timer: timer)
        eventsTask?.cancel()
        eventsTask = nil
        statusTimer?.invalidate()
        statusTimer = nil
        // a drag under way: its button is lifted now, past the queue (best effort; the Mac lifts it after 10 s anyway)
        liftDrag()
        input.cancel()
        dropFocusLook()
        timer?.mark("events+input")
        if release { releaseControl() }
        timer?.mark("release")
        // back from the background, the way is chosen again (the release above still goes out on the way it was sent on)
        inner.leaveRoute()
        timer?.mark("route")
        changed(.activity)
        timer?.mark("observers")
    }

    // MARK: Status

    /// `GET /screen` now (the session asks every 10 s while active).
    public func refreshStatus() async {
        do {
            apply(try await backend.status())
        } catch {
            if YoyoHost.current.handleError(error) { return }
            // a status poll that fails keeps the last answer
            if status == nil || (error as? YoyoError)?.isNotFound == true {
                status = nil
                statusError = error
                inner.stopFrames()
                changed([.status, .control])
            }
        }
    }

    func apply(_ answer: ScreenStatus) {
        // what the computer is and can do (an answer that doesn't say keeps what an earlier one said)
        let known = YoyoCapabilities.note(answer, scope: backend.cacheScope)
        let was = computer
        computer = computer.resolved(known.platform)
        if computer != was { changed(.computer) }
        updateClipboardCapability(known.features)
        // a computer without the macOS permissions: none to ask for (whatever the fields say)
        let s = computer.normalized(known)
        let wasMain = inner.showsMain
        let held = heldByMe
        status = s
        statusError = nil
        if let id = displayId, !s.displays.contains(where: { $0.id == id }) {
            if wasMain, let main = s.mainDisplay, main.main {
                // the main display under a new id (displays reconfigured): the same picture, on its way back
                displayId = main.id
                inner.syncConnectionTarget()
                inner.stopFrames()
            } else {
                displayId = nil
                inner.restartFrames()
            }
        }
        if displayId == nil { displayId = s.mainDisplay?.id }
        let effect = controlModel.status(controller: s.controller, device: s.controllerDevice, since: s.controllerSince, me: me)
        if s.controller != .user || controlModel.isViewer { heldByMe = false }
        inner.statusChanged(s)
        changed([.status, .control])
        controlEffect(effect, held: held)
        inner.updateFrames()
        inner.updateConnection()
    }

    private var me: String { ScreenControlDevice.currentId }

    /// The backend's events while active: who controls, the displays' states, the clipboard (to its state,
    /// `YoyoClipboardState`, which the session observes).
    private func followEvents() {
        guard eventsTask == nil, let events = backend.events() else { return }
        let clipboard = YoyoClipboardState.of(backend)
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .control(let controller, let since, let device):
                    self.controllerChanged(controller, since: since, device: device)
                case .state(let states, let console):
                    self.statesChanged(states, console: console)
                case .clipboard(let available, let summary):
                    clipboard.apply(available: available, summary: summary)
                }
            }
        }
    }

    private func controllerChanged(_ controller: ScreenController, since: Double?, device: ScreenControlDevice?) {
        guard status != nil else { return }
        let held = heldByMe
        status?.controller = controller
        status?.controllerSince = since
        status?.controllerDevice = controller == .user ? device : nil
        let effect = controlModel.status(controller: controller, device: device, since: since, me: me)
        if controller != .user || controlModel.isViewer { heldByMe = false }
        changed(.control)
        controlEffect(effect, held: held)
    }

    /// Another phone took over (`effect`), or control this session held ended otherwise: said once.
    private func controlEffect(_ effect: ScreenControlModel.Effect?, held: Bool) {
        if case let .takenOver(name)? = effect {
            notice(.lostControl(.takenOver(by: ScreenControlModel.displayName(name))))
        } else if held, !heldByMe {
            notice(.lostControl(.ended))
        }
    }

    /// A `screen.state` event.
    private func statesChanged(_ states: [ScreenDisplayState], console: ScreenConsole?) {
        guard status != nil else { return }
        status?.states = states
        status?.console = console
        inner.statesChanged(states, console: console)
        changed(.status)
    }

    /// The displays the computer has.
    public var displays: [ScreenDisplay] { status?.displays ?? [] }

    /// The display shown (the main one until another is picked).
    public var currentDisplay: ScreenDisplay? {
        guard let status else { return nil }
        return status.displays.first(where: { $0.id == displayId }) ?? status.mainDisplay
    }

    /// Shows another display.
    public func selectDisplay(_ id: UInt32) {
        guard id != displayId else { return }
        displayId = id
        inner.restartFrames()
        changed(.status)
    }

    /// The picture can be shown (the computer has a screen and, a Mac, Screen Recording).
    public var canShow: Bool { status?.available == true && status?.screenRecording == true }
    /// Input is possible (the picture shows and, a Mac, Accessibility is granted).
    public var canControl: Bool { canShow && status?.accessibility == true }
    /// Taps and keys go to the computer now: it says this phone holds the screen (under `.explicit`: this session
    /// took it), and the host isn't `viewOnly`.
    public var isControlling: Bool {
        canControl && !viewOnly && status?.controller == .user && !controlModel.isViewer
            && (controlPolicy == .takeOnInput || heldByMe)
    }
    /// A take would work without anything else in the way: input is possible, not `viewOnly`, no other phone holds
    /// it (`takeControl()` takes that too).
    public var canTakeControl: Bool { canControl && !viewOnly && !controlModel.isViewer }

    /// Asks the computer to show its permission prompts (the macOS ones: Screen Recording, Accessibility); says so,
    /// and asks for the status again a moment later.
    public func requestPermissions() {
        Task {
            do {
                apply(try await backend.requestPermissions())
                notice(.message(L("Check your Mac and allow Yoyo Control there.")))
                // the user answers at the Mac; look again soon (the 10 s poll keeps going too)
                try? await Task.sleep(for: .seconds(3))
                await refreshStatus()
            } catch {
                if YoyoHost.current.handleError(error) { return }
                notice(.message(ScreenSession.message(error)))
            }
        }
    }

    // MARK: Connection, sound, stats

    /// The picture is live (not on its way back, not unavailable).
    public var isLive: Bool { inner.shownConnection.phase.isLive }
    /// A picture was shown since the display was chosen.
    public var hasPicture: Bool { inner.hasFrame }

    /// Retry (the display was unavailable): asks again now, keeping the still.
    public func retryConnection() {
        inner.retryConnection()
        Task { await refreshStatus() }
    }

    /// The computer's sound plays (kept in `<namespace>Audio`).
    public var audioOn: Bool { inner.audioOn }
    /// The computer has sound this visit (else a speaker button hides).
    public var hasAudio: Bool { !inner.audioUnsupported }

    public func setAudioOn(_ on: Bool) {
        inner.setAudioOn(on)
        changed(.audio)
    }

    /// The computer's sound's level on this device, 0…1 (1, the default: as it comes), e.g. lowered under a voice of
    /// the host's own and raised again after it. It glides there (down in about 80 ms, back up in about 350 ms), with
    /// no gap in the sound; it holds for this session's later sound streams. Not kept anywhere.
    public var audioVolume: Double {
        get { inner.audioVolume }
        set { inner.audioVolume = min(max(newValue, 0), 1) }
    }

    /// The host keeps the audio session as it set it (false, the default: the sound sets `.playback` /
    /// `.moviePlayback`, its IO buffer, and gives the session back when it stops). For a host with a microphone of its
    /// own in the session (`.playAndRecord`, e.g. a voice chat): the sound then only activates the session and plays in
    /// it. Set it before the sound starts (it holds from the next sound output made: after `setAudioOn(false)` / a new
    /// session).
    public var hostManagesAudioSession: Bool {
        get { inner.hostManagesAudioSession }
        set { inner.hostManagesAudioSession = newValue }
    }

    /// The stats line (each call takes the counters since the last): codec, fps, KB/s, decode time, the way, the
    /// connection; the playout and the latency estimate; the network; the sound.
    public func statsText() -> String { inner.statsText() }

    /// Clears the stats line's counters (it is about to show).
    func resetStats() { _ = inner.stats.take() }

    /// Every decoded picture goes to `sink` too (on the decoder's or the playout's thread), starting with the newest:
    /// a second view of the screen (Picture in Picture…). Until the returned sink is cancelled or released.
    public func addVideoSink(_ sink: @escaping @Sendable (CVPixelBuffer) -> Void) -> YoyoScreenVideoSink {
        YoyoScreenVideoSink(output: videoOutput, id: videoOutput.addSink(active: true, sink))
    }

    // MARK: Control

    /// Takes the screen (`POST /control { controller: "user" }`; another phone's control and the agent's too), whatever
    /// the policy. Returns once it controls (`isControlling`; given back at once if the session stopped or turned
    /// `viewOnly` meanwhile). A take already on its way is waited for. Throws the request's error (unhandled: the host
    /// passes it to `YoyoHost.handleError` and says it); the status is asked again then.
    public func takeControl() async throws {
        if let takeTask { return try await takeTask.value }
        let task = Task { try await performTake() }
        takeTask = task
        defer { if takeTask == task { takeTask = nil } }
        try await task.value
    }

    private func performTake() async throws {
        isTakingControl = true
        changed(.control)
        defer {
            isTakingControl = false
            afterTake = []
            changed(.control)
        }
        let held = heldByMe
        let s: ScreenStatus
        do {
            s = try await inner.control(.user)
        } catch {
            Task { await refreshStatus() }
            throw error
        }
        let effect = controlModel.took(controller: s.controller, device: s.controllerDevice, since: s.controllerSince, me: me)
        heldByMe = s.controller == .user && !controlModel.isViewer
        apply(s)
        controlEffect(effect, held: held)
        // view only (or stopped) while the take was on its way: give it straight back
        if viewOnly || !isActive || inBackground { releaseControl(); return }
        notice(.tookControl)
        // what asked for control goes now (a key typed while the take was on its way)
        let waiting = afterTake
        afterTake = []
        if isControlling { waiting.forEach { $0() } }
    }

    /// Gives the screen back if this session took it (also as it stops, so it isn't held for a moment).
    public func releaseControl() {
        guard heldByMe else { return }
        heldByMe = false
        // the way in use now (the session may be leaving it), else what the routing falls back to
        let route = inner.way
        let inner = self.inner
        let background = AppBackgroundTask()
        let release = Task {
            _ = try? await inner.control(.none, on: route)
            background.end()
        }
        background.id = UIApplication.shared.beginBackgroundTask(withName: "screen.release") {
            release.cancel()
            background.end()
        }
        // a few seconds at most: not worth holding the app open for (the server drops a stale controller anyway)
        Task {
            try? await Task.sleep(for: .seconds(ScreenSession.releaseTimeout))
            release.cancel()
        }
        if status?.controller == .user { status?.controller = .none }
        changed(.control)
    }

    /// A real input is about to happen (a finger on the trackpad, the keyboard, a key, a paste into the computer): in
    /// control, `then` runs now. Else `.takeOnInput` takes the screen if it can (over the agent too: the user wins) and
    /// runs `then` once it controls; watching another phone's control it only nudges (`Notice.nudge`). `.explicit`
    /// nudges and drops `then`.
    public func requestInput(then: (() -> Void)? = nil) {
        if isControlling { then?(); return }
        switch controlPolicy {
        case .explicit:
            if !viewOnly { notice(.nudge) }
        case .takeOnInput:
            switch ScreenControlPolicy.input(controlling: false, viewer: controlModel.isViewer, canTake: canTakeControl) {
            case .go: then?()
            case .nudge: notice(.nudge)
            case .take: take(then: then)
            case .ignore: break
            }
        }
    }

    /// An input would go now, or a take for it would be made (`requestInput`).
    var inputWouldGo: Bool { isControlling || (controlPolicy == .takeOnInput && canTakeControl) }

    /// The take an input asked for: its failure is said here.
    private func take(then: (() -> Void)?) {
        if let then { afterTake.append(then) }
        guard takeTask == nil else { return }
        Task {
            do { try await takeControl() } catch {
                if YoyoHost.current.handleError(error) { return }
                notice(.message(ScreenSession.message(error)))
            }
        }
    }

    // MARK: Input

    /// One input to the computer (its display, when it names none, the one shown). In control it goes now; else as
    /// `requestInput` says (`.takeOnInput`: after the take; `.explicit`: dropped).
    public func send(_ input: ScreenInput) {
        guard isControlling else { requestInput { [weak self] in self?.send(input) }; return }
        enqueue(input)
    }

    private func enqueue(_ event: ScreenInput) {
        var event = event
        if event.display == nil { event.display = displayId }
        input.send(event)
    }

    /// The pointer to `point` (normalized, the display shown); moves merge while one is on its way. In control only.
    @discardableResult
    public func movePointer(to point: CGPoint) -> Bool {
        guard isControlling else { return false }
        input.move(to: point, display: displayId)
        return true
    }

    /// A click at `point` (normalized) with the armed modifiers; a click (not a right click) then looks at the focus
    /// (a keyboard may come up). In control only.
    @discardableResult
    public func click(_ kind: ScreenInput.Kind = .click, at point: CGPoint) -> Bool {
        guard isControlling else { return false }
        enqueue(.click(kind, display: displayId, at: point, modifiers: takeModifiers()))
        if kind != .rightClick { lookAtFocus() }
        return true
    }

    /// A scroll by `delta` (display points, positive = see content further right / down) at `point`, with its gesture's
    /// `phase` (`ended`: the velocity at lift, display points per second; the computer glides on). Added up while one
    /// is on its way. In control only.
    @discardableResult
    public func scroll(by delta: CGVector, at point: CGPoint, phase: ScreenInput.ScrollPhase? = nil,
                       velocity: CGVector = .zero) -> Bool {
        guard isControlling else { return false }
        input.scroll(by: delta, at: point, display: displayId, phase: phase, velocity: velocity)
        return true
    }

    /// A live drag: the left button goes down at `point` (with the armed modifiers). In control only.
    @discardableResult
    public func beginDrag(at point: CGPoint) -> Bool {
        guard isControlling else { return false }
        dragHeld = (displayId, point)
        enqueue(.pointer(.down, display: displayId, at: point, modifiers: takeModifiers()))
        return true
    }

    /// The drag's held move (only the latest position waits while one is on its way).
    @discardableResult
    public func moveDrag(to point: CGPoint) -> Bool {
        guard dragHeld != nil else { return false }
        dragHeld?.point = point
        input.move(to: point, display: dragHeld?.display ?? displayId, button: .left)
        return true
    }

    /// The drag's button goes up at `point`.
    @discardableResult
    public func endDrag(at point: CGPoint) -> Bool {
        guard let held = dragHeld else { return false }
        dragHeld = nil
        enqueue(.pointer(.up, display: held.display, at: point))
        return true
    }

    /// The session stops mid-drag: `up` goes now, past the queue (which is about to be dropped). Best effort.
    private func liftDrag() {
        guard let held = dragHeld else { return }
        dragHeld = nil
        let up = ScreenInput.pointer(.up, display: held.display ?? displayId, at: held.point)
        Task { [weak self] in try? await self?.inner.deliver(up) }
    }

    /// Text typed on the phone: lines as text, the line breaks as return; with a modifier armed one character is a
    /// shortcut (⌘C). Watching: as `requestInput` says.
    public func type(_ text: String) {
        guard isControlling else { requestInput { [weak self] in self?.type(text) }; return }
        keySent()
        if !modifiers.isEmpty, text.count == 1, text != "\n" {
            let (name, shifted) = Self.keyName(for: text)
            var m = takeModifiers()
            if shifted, !m.contains(.shift) { m.append(.shift) }
            enqueue(ScreenInput(.key, key: name, modifiers: m))
            return
        }
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { enqueue(ScreenInput(.key, key: "return", modifiers: takeModifiers())) }
            if !line.isEmpty { enqueue(ScreenInput(.type, text: line)) }
        }
    }

    /// A key ("escape", "tab", "left", "delete"… of `POST /screen/input`) with the armed modifiers. Watching: as
    /// `requestInput` says.
    public func pressKey(_ name: String) {
        guard isControlling else { requestInput { [weak self] in self?.pressKey(name) }; return }
        keySent()
        enqueue(ScreenInput(.key, key: name, modifiers: takeModifiers()))
    }

    /// Arms a modifier for the next key or click, or disarms it.
    public func toggleModifier(_ m: ScreenModifier) {
        if modifiers.contains(m) { modifiers.remove(m) } else { modifiers.insert(m) }
        changed(.modifiers)
    }

    /// The armed modifiers, disarmed.
    private func takeModifiers() -> [ScreenModifier] {
        guard !modifiers.isEmpty else { return [] }
        let m = ScreenModifier.allCases.filter(modifiers.contains)
        modifiers = []
        changed(.modifiers)
        return m
    }

    /// The key name of one typed character: letters lowercased (an uppercase one adds ⇧), " " is "space", digits and
    /// punctuation as they are.
    nonisolated static func keyName(for character: String) -> (name: String, shifted: Bool) {
        if character == " " { return ("space", false) }
        if character == "\t" { return ("tab", false) }
        let lower = character.lowercased()
        let isUpperLetter = lower != character && character.uppercased() == character
        return (lower, isUpperLetter)
    }

    /// A key or text went to the computer: interactive for a moment too (its echo shouldn't wait in the smooth buffer).
    func keySent() {
        inner.keySent()
        onKeySent?()
    }

    /// The paste shortcut (⌘V on a Mac, Shift+Insert on Linux), as a key the user typed.
    func sendPasteShortcut() {
        keySent()
        enqueue(computer.pasteShortcut)
    }

    /// A finger came down on the picture's controls (a trackpad): smooth playback shows pictures at once while it is
    /// down (and a moment after), so what the finger does shows without the smooth buffer's delay. In control.
    public func beginInteraction() {
        guard isControlling else { return }
        inner.touchBegan()
    }

    /// The last finger lifted: back to smooth playback after a moment.
    public func endInteraction() { inner.touchEnded() }

    private func inputFailed(_ error: Error) {
        if YoyoHost.current.handleError(error) { return }
        // another phone took control: watching now
        if let refusal = error as? ScreenControlledElsewhere {
            let held = heldByMe
            let effect = controlModel.refused(refusal)
            heldByMe = false
            changed(.control)
            controlEffect(effect, held: held)
            Task { await refreshStatus() }
            return
        }
        if case YoyoError.http(409, _) = error {
            heldByMe = false
            if status?.controller == .user { status?.controller = .none }
            changed(.control)
            notice(.lostControl(.refused))
            Task { await refreshStatus() }
            return
        }
        notice(.message(ScreenSession.message(error)))
    }

    // MARK: Focus (the keyboard comes up for a text field)

    /// A click went out: a moment later the computer is asked whether what has the focus takes typing, and if so the
    /// keyboard comes up (one that wants it: `YoyoScreenKeyboard.showsForFocus`). Later looks catch slower apps. Any
    /// touch drops it.
    private func lookAtFocus() {
        dropFocusLook()
        guard !focusUnsupported, isControlling, keyboard?.wantsFocusLook == true else { return }
        let display = displayId
        focusTask = Task { [weak self] in
            var waited: Duration = .zero
            for at in Self.focusLooks {
                try? await Task.sleep(for: at - waited)
                waited = at
                guard !Task.isCancelled, let focus = await self?.focus(display: display), !Task.isCancelled, let self else { return }
                if focus.editable {
                    self.focusTask = nil
                    self.keyboard?.showForFocus()
                    return
                }
            }
            self?.focusTask = nil
        }
    }

    func dropFocusLook() {
        focusTask?.cancel()
        focusTask = nil
    }

    /// The focus, the way in use; nil when it can't be had (404, or 403 / 501 from a desktop that can't tell: not
    /// asked again this visit).
    private func focus(display: UInt32?) async -> ScreenFocus? {
        do {
            return try await inner.focus(display: display)
        } catch {
            switch error {
            case YoyoError.http(404, _), YoyoError.http(403, _), YoyoError.http(501, _): focusUnsupported = true
            default: break
            }
            return nil
        }
    }

    /// Where the session presents what it must.
    var presentingController: UIViewController? {
        presenter ?? keyboard?.hostController ?? picture?.hostController
    }
}

extension YoyoScreenSession: ScreenSessionHost {
    var displayIsMain: Bool { currentDisplay?.main ?? true }

    func sessionShowVideo(size: CGSize) { picture?.showVideo(size: size) }

    /// A video picture becomes a still in the picture view (the display layer may lose it when its decoder goes, or go
    /// black in the background). The still is made off the main thread (a stop is a frame's work or less here).
    func sessionFreezePicture() {
        picture?.freezeVideo(from: videoOutput)
    }

    func sessionClearPicture() {
        picture?.clearPicture()
        videoOutput.clear()
    }

    func sessionCursor(_ update: ScreenCursorUpdate) { picture?.applyCursor(update) }

    func sessionResetCursor() { picture?.resetCursor() }

    func sessionConnectionChanged() { changed(.connection) }

    func sessionRefreshStatus() async { await refreshStatus() }

    func sessionAudioChanged() { changed(.audio) }
}

/// An observer of a `YoyoScreenSession` (`observe`): it hears until `cancel()` or until this is released.
@MainActor
public final class YoyoScreenObservation {
    private weak var session: YoyoScreenSession?
    private let id: Int

    init(session: YoyoScreenSession, id: Int) {
        self.session = session
        self.id = id
    }

    public func cancel() {
        session?.removeWatcher(id)
        session = nil
    }

    isolated deinit { cancel() }
}

/// A sink of a session's pictures (`YoyoScreenSession.addVideoSink`): it gets them until `cancel()` or until this is
/// released.
public final class YoyoScreenVideoSink: Sendable {
    private let output: ScreenVideoOutput
    private let id: Int

    init(output: ScreenVideoOutput, id: Int) {
        self.output = output
        self.id = id
    }

    public func cancel() { output.removeSink(id) }

    deinit { cancel() }
}
