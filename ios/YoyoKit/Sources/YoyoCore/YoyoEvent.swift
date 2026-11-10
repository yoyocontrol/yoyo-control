import Foundation

/// One event of the computer that the kits' pages follow (`YoyoBackend.events()`).
public enum YoyoEvent: Sendable, Equatable {
    /// Who drives the screen changed (`since` ms since epoch, nil when `.none`; `device` the phone holding control).
    case control(controller: ScreenController, since: Double?, device: ScreenControlDevice? = nil)
    /// How the pictures of the computer's displays are doing, and who is on its console.
    case state(states: [ScreenDisplayState], console: ScreenConsole?)
    /// The computer's clipboard changed: its summary only (`available` false: it can't do clipboard now; nil: not said).
    case clipboard(available: Bool?, summary: ClipboardSummary?)

    /// One event as JSON: `{"type":"screen.control", controller, controllerSince?, controllerDevice?}`,
    /// `{"type":"screen.state", states, console?}`, `{"type":"clipboard.changed", available, item?}`. nil: not one of
    /// these (or unreadable).
    public init?(json data: Data) {
        guard let e = try? JSONDecoder().decode(Wire.self, from: data), let event = e.event else { return nil }
        self = event
    }

    private struct Wire: Decodable {
        var event: YoyoEvent?

        private enum K: String, CodingKey { case type, controller, controllerSince, controllerDevice, states, console, available, item }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            switch (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil {
            case "screen.control":
                let controller = ScreenController(lenient: (try? c.decodeIfPresent(String.self, forKey: .controller)) ?? nil)
                let device = controller == .user ? (try? c.decodeIfPresent(ScreenControlDevice.self, forKey: .controllerDevice)) ?? nil : nil
                event = .control(controller: controller, since: (try? c.decodeIfPresent(Double.self, forKey: .controllerSince)) ?? nil,
                                 device: device)
            case "screen.state":
                event = .state(states: c.lenientList(ScreenDisplayState.self, forKey: .states),
                               console: (try? c.decodeIfPresent(ScreenConsole.self, forKey: .console)) ?? nil)
            case "clipboard.changed":
                event = .clipboard(available: (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? nil,
                                   summary: (try? c.decodeIfPresent(ClipboardSummary.self, forKey: .item)) ?? nil)
            default:
                event = nil
            }
        }
    }
}

/// Several readers of one backend's events (each subscriber gets every event from when it subscribed): what a backend
/// that reads its events from one place hands out as `YoyoBackend.events()`.
public final class YoyoEventHub: Sendable {
    private let subscribers = YoyoLocked<[UUID: AsyncStream<YoyoEvent>.Continuation]>([:])

    public init() {}

    /// A new subscription.
    public func subscribe() -> AsyncStream<YoyoEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<YoyoEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { [weak self] _ in self?.subscribers.withLock { $0[id] = nil } }
        subscribers.withLock { $0[id] = continuation }
        return stream
    }

    /// Hands `event` to every subscriber.
    public func post(_ event: YoyoEvent) {
        for c in subscribers.withLock({ Array($0.values) }) { c.yield(event) }
    }

    /// Whether anyone is subscribed.
    public var hasSubscribers: Bool { subscribers.withLock { !$0.isEmpty } }
}

/// A value behind a lock (Synchronization's `Mutex` isn't usable from every context a `Sendable` class needs).
package final class YoyoLocked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    package init(_ value: Value) { self.value = value }

    package func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
