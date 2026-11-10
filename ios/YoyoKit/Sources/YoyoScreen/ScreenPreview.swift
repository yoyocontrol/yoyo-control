import UIKit
import YoyoCore

/// A computer's screen as a row of an app's list (docs/PROTOCOL.md「屏幕」): whether it has one, who drives it, and a
/// small frame of the main display, asked again every few seconds while the row is on screen (`YoyoBackend.frame`). A
/// sleeping display is left asleep (a frame would wake it). The app draws the row from `state`, `image` and `computer`;
/// one per list, shared by the levels that show the row.
@MainActor
public final class YoyoScreenPreview {
    public enum State: Equatable, Sendable {
        /// Not answered yet (or only failures so far).
        case unknown
        /// The computer has no screen (404): no row.
        case absent
        case unavailable(reason: String?)
        /// The screen can't be shown and the backend offers something to do about it (`ScreenStatus.unavailableAction`).
        case action(YoyoUnavailableAction)
        case needsPermission
        case asleep
        case live(ScreenController)
    }

    /// What a status says the row shows.
    public nonisolated static func state(for s: ScreenStatus) -> State {
        if !s.available, let action = s.unavailableAction { return .action(action) }
        guard s.available else { return .unavailable(reason: s.reason) }
        guard s.screenRecording else { return .needsPermission }
        if s.mainDisplay?.asleep == true { return .asleep }
        return .live(s.controller)
    }

    public static let every: Duration = .seconds(5)
    static let maxWidth = 320
    static let quality = 50

    public private(set) var state = State.unknown
    /// The latest frame of the main display (kept while it can't be refreshed).
    public private(set) var image: UIImage?
    /// Whose screen it is (the backend's hint until a status says its `platform`).
    public private(set) var computer: YoyoComputer
    /// The row's level, told of every change (the level that showed it last).
    private weak var owner: AnyObject?
    private var onChange: (() -> Void)?
    private let backend: any YoyoBackend
    private var task: Task<Void, Never>?
    private var events: Task<Void, Never>?
    /// Wanted by a level on screen (paused in the background).
    private var running = false
    private var observers: [NSObjectProtocol] = []
    /// Per computer: it answered a status before, so the row shows at once next time (no jump).
    private static var known: [String: Bool] = [:]

    public init(backend: any YoyoBackend) {
        self.backend = backend
        computer = YoyoComputer.of(platform: YoyoCapabilities.platform(scope: backend.cacheScope), hint: backend.platformHint)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
    }

    isolated deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        task?.cancel()
        events?.cancel()
    }

    /// The computer has a clipboard (its row under the screen's): what it said (`features`), else the Mac only.
    public var hasClipboard: Bool { computer.hasClipboard(YoyoCapabilities.features(scope: backend.cacheScope)) }

    /// The row shows: the computer has a screen, or had one the last time it was asked.
    public var showsRow: Bool {
        switch state {
        case .absent: false
        case .unknown: Self.known[backend.cacheScope] == true
        default: true
        }
    }

    /// `owner`'s row is on screen: keep it current (a level taking over from another one replaces it).
    public func start(for owner: AnyObject, onChange: @escaping () -> Void) {
        self.owner = owner
        self.onChange = onChange
        running = true
        resume()
    }

    /// `owner`'s row went away (a level that was taken over from doesn't stop the newer one).
    public func stop(for owner: AnyObject) {
        guard self.owner === owner else { return }
        running = false
        pause()
    }

    private func resume() {
        guard running, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.every)
            }
        }
        // who drives it, at once (`screen.control` events)
        if events == nil, let stream = backend.events() {
            events = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    if case .control(let controller, _, _) = event, case .live = self.state { self.set(.live(controller)) }
                }
            }
        }
    }

    private func pause() {
        task?.cancel()
        task = nil
        events?.cancel()
        events = nil
    }

    private func tick() async {
        let scope = backend.cacheScope
        let s: ScreenStatus
        let before = (computer, hasClipboard)
        do {
            let known = YoyoCapabilities.note(try await backend.status(), scope: scope)
            computer = computer.resolved(known.platform)
            s = computer.normalized(known)
        } catch {
            if YoyoHost.current.handleError(error) { return }
            // only a 404 says there is no screen; other failures keep what is shown
            if (error as? YoyoError)?.isNotFound == true, !Task.isCancelled {
                Self.known[scope] = false
                set(.absent)
            }
            return
        }
        guard !Task.isCancelled else { return }
        Self.known[scope] = true
        // the platform or the clipboard changed: the rows follow (the clipboard's row comes or goes)
        if before != (computer, hasClipboard), Self.state(for: s) == state { onChange?() }
        set(Self.state(for: s))
        // a frame that fails keeps the last one
        guard case .live = state, let display = s.mainDisplay,
              let data = try? await backend.frame(display: display.id, maxWidth: Self.maxWidth, quality: Self.quality),
              let decoded = UIImage(data: data) else { return }
        let image = await decoded.byPreparingForDisplay() ?? decoded
        guard !Task.isCancelled else { return }
        self.image = image
        onChange?()
    }

    private func set(_ s: State) {
        guard s != state else { return }
        state = s
        onChange?()
    }
}
