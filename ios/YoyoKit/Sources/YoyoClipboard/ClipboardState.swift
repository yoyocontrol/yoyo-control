import Foundation
import YoyoCore

/// One computer's clipboard as the kits know it (`GET /clipboard`, its events): one per `cacheScope`, shared by every
/// page that shows it (the Clipboard page, the Screen page's keys and hints, an app's preview row). Loaded on demand,
/// kept for `ttl` (a `refresh` within it doesn't ask again), patched in place by the computer's clipboard events while
/// anyone observes it (`YoyoBackend.events()`). Never kept on disk: what a computer copied is live data and may be
/// private. Main actor.
@MainActor
public final class YoyoClipboardState {
    /// The last answer (nil: none yet, or the last load failed before any answer).
    public private(set) var status: ClipboardStatus?
    /// The last load's failure (nil after an answer).
    public private(set) var error: Error?
    /// A load is on its way.
    public private(set) var isLoading = false

    /// An answer this young isn't asked again by `refresh`.
    public static let ttl: Duration = .seconds(15)

    private let backend: any YoyoBackend
    private var loadedAt: ContinuousClock.Instant?
    private var loading: Task<ClipboardStatus, Error>?
    private var observers: [(owner: Weak, onChange: @MainActor (YoyoClipboardState) -> Void)] = []
    private var events: Task<Void, Never>?

    private static var states: [String: YoyoClipboardState] = [:]

    /// The state of `backend`'s computer (the same object for the same `cacheScope`).
    public static func of(_ backend: any YoyoBackend) -> YoyoClipboardState {
        if let s = states[backend.cacheScope] { return s }
        let s = YoyoClipboardState(backend: backend)
        states[backend.cacheScope] = s
        return s
    }

    /// The state of the computer `scope` names, if a page made one (an app's event that comes while no page follows
    /// the computer's events lands here).
    public static func existing(scope: String) -> YoyoClipboardState? { states[scope] }

    /// Tests: every state forgotten.
    public static func forgetAll() {
        for s in states.values { s.events?.cancel() }
        states = [:]
    }

    private init(backend: any YoyoBackend) {
        self.backend = backend
    }

    /// The computer has no clipboard (an answer 404): its entries hide.
    public var isUnsupported: Bool { (error as? YoyoError)?.isNotFound == true && status == nil }

    /// `onChange` runs at once when something is known already (another page loaded it), then after every change while
    /// `owner` lives (a page, a row's controller); the computer's clipboard events are followed meanwhile.
    public func observe(_ owner: AnyObject, _ onChange: @escaping @MainActor (YoyoClipboardState) -> Void) {
        observers.removeAll { $0.owner.value == nil || $0.owner.value === owner }
        observers.append((Weak(owner), onChange))
        followEvents()
        if status != nil || error != nil { onChange(self) }
    }

    /// Stops `owner`'s observation.
    public func stopObserving(_ owner: AnyObject) {
        observers.removeAll { $0.owner.value == nil || $0.owner.value === owner }
        if observers.isEmpty { stopEvents() }
    }

    /// Loads when the last answer is older than `ttl` (or there is none).
    public func refresh() {
        if let loadedAt, status != nil, ContinuousClock.now - loadedAt < Self.ttl { return }
        Task { _ = try? await load(force: true) }
    }

    /// The computer's clipboard now (`force`: asked even if the last answer is young).
    @discardableResult
    public func load(force: Bool = false) async throws -> ClipboardStatus {
        if !force, let status, let loadedAt, ContinuousClock.now - loadedAt < Self.ttl { return status }
        if let loading { return try await loading.value }
        let backend = self.backend
        let task = Task { try await backend.clipboard() }
        loading = task
        isLoading = true
        notify()
        defer {
            loading = nil
            isLoading = false
        }
        do {
            let s = try await task.value
            status = s
            error = nil
            loadedAt = .now
            notify()
            return s
        } catch {
            if !(error is CancellationError) {
                self.error = error
                if (error as? YoyoError)?.isNotFound == true { status = nil }
                notify()
            }
            throw error
        }
    }

    /// What is known may be old (its events were missed, a reconnect): asked again at once while observed, else at the
    /// next `refresh`.
    public func invalidate() {
        loadedAt = nil
        observers.removeAll { $0.owner.value == nil }
        if !observers.isEmpty { refresh() }
    }

    /// An answer that came another way (`POST /clipboard`'s).
    public func set(_ status: ClipboardStatus) {
        self.status = status
        error = nil
        loadedAt = .now
        notify()
    }

    /// A clipboard event: the summary replaces the item's (its `text` is dropped — the event carries none, so a page
    /// that needs it loads again). The same `changeCount` again changes nothing; a flip of `available` is always
    /// applied. Nothing known yet: taken as the status (unless the computer has no clipboard).
    public func apply(available: Bool?, summary: ClipboardSummary?) {
        guard let current = status else {
            if !isUnsupported, let available {
                set(ClipboardStatus(available: available, item: summary.map { ClipboardItem(summary: $0) }))
            }
            return
        }
        let available = available ?? current.available
        if current.available == available, current.item?.changeCount == summary?.changeCount, (current.item == nil) == (summary == nil) { return }
        var next = current
        next.available = available
        next.reason = available ? nil : current.reason
        next.item = summary.map { ClipboardItem(summary: $0) }
        status = next
        notify()
    }

    private func notify() {
        observers.removeAll { $0.owner.value == nil }
        for o in observers { o.onChange(self) }
        if observers.isEmpty { stopEvents() }
    }

    private func followEvents() {
        guard events == nil, let stream = backend.events() else { return }
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if case .clipboard(let available, let summary) = event { self.apply(available: available, summary: summary) }
                self.observers.removeAll { $0.owner.value == nil }
                if self.observers.isEmpty { break }
            }
            self?.events = nil
        }
    }

    private func stopEvents() {
        events?.cancel()
        events = nil
    }
}

/// A weak reference.
final class Weak {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
}
