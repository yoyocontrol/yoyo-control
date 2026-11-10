import Foundation
import Network
import OSLog
import Security
import Synchronization
import UIKit
import YoyoConnect
import YoyoCore
import YoyoLink

/// The phone's side of uu Link (docs/LINK.md「端点、地址、路径」): one client endpoint per process, its key in the
/// keychain (one per install), the network path told to it at every change, its log lines as `link[phone]:` lines, and
/// dialing a computer from its published binding (checked against the pinned fingerprint first) to a
/// `YoyoLinkConnection`. Any backend can use it: the binding and the credential (`hello.credential`) are its own.
public final class YoyoLinkClient: Sendable {
    public enum Failure: LocalizedError, Equatable {
        /// The binding isn't the pinned computer's (`SHA-256(key) ≠ fp`, or a bad signature): never dialed.
        case binding(String)
        /// The computer refused the credential (`denied`: unauthorized; or this install's key isn't the one the device
        /// token is bound to).
        case unauthorized(String)
        /// It said busy / rate-limited.
        case refused(String)
        /// It didn't answer (in time), or the session failed.
        case unreachable(String)

        public var errorDescription: String? {
            switch self {
            case .binding(let m): "link binding: \(m)"
            case .unauthorized(let m): "link unauthorized: \(m)"
            case .refused(let m): "link refused: \(m)"
            case .unreachable(let m): "link unreachable: \(m)"
            }
        }
    }

    /// The one of this process.
    public static let shared = YoyoLinkClient()

    /// The kit's setting: try uu Link before the other ways (`<namespace>Link`, default on; `-<namespace>Link NO` at
    /// launch turns it off). A host may show it as a switch.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: YoyoHost.key("Link")) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: YoyoHost.key("Link")) }
    }

    /// Every log line of the link (`link[phone]: …` stats every 10 s, sessions, paths), besides the system log.
    public static var logHandler: (@Sendable (String) -> Void)? {
        get { logs.withLock { $0 } }
        set { logs.withLock { $0 = newValue } }
    }
    private static let logs = Mutex<(@Sendable (String) -> Void)?>(nil)
    static let log = Logger(subsystem: "ca.sarria.yoyocontrol", category: "link")

    private struct State {
        var endpoint: Task<LinkEndpoint, Error>?
        var monitor: NWPathMonitor?
        var iface: Iface?
    }
    private let state = Mutex(State())

    init() {}

    /// The iroh relays this endpoint uses (docs/LINK.md「中继」): the road to a computer when no direct path works, and what
    /// hole punching goes through; a computer's own relays (its binding) are dialed too, but only when this endpoint uses
    /// relays at all. None by default (no relay is built in); a host sets its own before the first `endpoint()`;
    /// `YOYO_LINK_RELAYS` (comma list, `off` = none) overrides for tests. A `?token=` on one is that relay's access token,
    /// not part of its address.
    public static var relays: [String] {
        get { relayList.withLock { $0 } }
        set { relayList.withLock { $0 = newValue } }
    }
    private static let relayList = Mutex<[String]>([])

    /// The endpoint, bound on first use (UDP on any port; no router mapping; `relays` as its relays).
    public func endpoint() async throws -> LinkEndpoint {
        let task = state.withLock { s -> Task<LinkEndpoint, Error> in
            if let t = s.endpoint { return t }
            let t = Task { () throws -> LinkEndpoint in
                Self.installLog()
                let key = LinkClientKey.load()
                // `YOYO_LINK_BIND=::1` (tests): only these local addresses, e.g. behind netem on one Mac (docs/LINK.md「测试工具」)
                let env = ProcessInfo.processInfo.environment
                let bind = (env["YOYO_LINK_BIND"] ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let relays = env["YOYO_LINK_RELAYS"].map { r in
                    r == "off" ? [] : r.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                } ?? Self.relays
                return try await bindEndpoint(config: EndpointConfig(role: .client, secretKey: key, port: 0, relays: relays,
                                                                     portmapper: false, guard: nil, bindIps: bind))
            }
            s.endpoint = t
            return t
        }
        do {
            let endpoint = try await task.value
            watchPath(endpoint)
            return endpoint
        } catch {
            // a later call tries again
            state.withLock { if $0.endpoint == task { $0.endpoint = nil } }
            throw error
        }
    }

    /// This install's uu Link id: hex of its client key's public key, which a computer binds this phone's token to
    /// (docs/LINK.md「身份与信任」). nil only if the key can't be read.
    public static var linkId: String? { try? linkPublicKey(secretKey: LinkClientKey.load()) }

    /// The interface the phone's traffic goes out on now (nil: not known yet).
    public var iface: Iface? { state.withLock { $0.iface } }

    /// Dials the computer of `binding`, which must be the one pinned as `fingerprint` (`Failure.binding` otherwise, and
    /// nothing is sent). `hints`: more of its addresses (`ip:port`: the pairing link's, Bonjour's) next to the binding's
    /// own; `credential`: what `hello` carries (opaque: `Bearer <token>` for a paired phone, `Pair <code>` to pair);
    /// `device`: who `hello` says this phone is (nil: `ScreenControlDevice.current`). Returns once `welcome` came.
    public func dial(_ binding: ConnectLinkBinding, fingerprint: String, hints: [String] = [], credential: String,
                     device: ScreenControlDevice? = nil, timeout: Duration = .seconds(6)) async throws -> YoyoLinkConnection {
        let id: String
        do {
            id = try binding.verified(fingerprint: fingerprint)
        } catch {
            let message = Self.describe(error)
            Self.emit("link[phone]: binding refused for \(fingerprint.prefix(15))…: \(message)", level: .error)
            throw Failure.binding(message)
        }
        let endpoint: LinkEndpoint
        do { endpoint = try await self.endpoint() } catch { throw Failure.unreachable(Self.describe(error)) }
        var direct: [String] = []
        for a in binding.direct + hints where !direct.contains(a) { direct.append(a) }
        let device = device ?? ScreenControlDevice.current
        let info = Bundle.main.infoDictionary
        let hello = Hello(credential: credential,
                          device: DeviceInfo(id: device.id, name: device.name ?? Self.deviceName),
                          app: AppInfo(name: info?["CFBundleName"] as? String ?? "app",
                                       version: info?["CFBundleShortVersionString"] as? String ?? "0"),
                          features: YoyoLinkConnection.features)
        let target = DialTarget(id: id, relays: binding.relays, direct: direct)
        let started = ContinuousClock.now
        do {
            let session = try await endpoint.dial(target: target, hello: hello,
                                                  connectTimeoutMs: UInt64(max(timeout.components.seconds * 1000, 500)))
            let connection = YoyoLinkConnection(session: session)
            Self.emit("link[phone]: connected in \(Self.ms(since: started)) ms, \(connection.pathLabel) "
                      + "\(session.path().remote ?? "?") (\(direct.count) hints)")
            return connection
        } catch let LinkError.Denied(code, message) {
            Self.emit("link[phone]: denied \(code): \(message)", level: .error)
            throw code == .unauthorized ? Failure.unauthorized(message) : Failure.refused(message)
        } catch {
            let message = Self.describe(error)
            Self.emit("link[phone]: dial failed after \(Self.ms(since: started)) ms: \(message)")
            throw Failure.unreachable(message)
        }
    }

    // MARK: The network path

    private func watchPath(_ endpoint: LinkEndpoint) {
        let monitor = state.withLock { s -> NWPathMonitor? in
            guard s.monitor == nil else { return nil }
            let m = NWPathMonitor()
            s.monitor = m
            return m
        }
        guard let monitor else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let iface = Self.iface(of: path)
            self?.state.withLock { $0.iface = iface }
            Task { await endpoint.networkChanged(iface: iface) }
        }
        monitor.start(queue: DispatchQueue(label: "ca.sarria.yoyocontrol.link-path", qos: .utility))
    }

    static func iface(of path: NWPath) -> Iface? {
        guard path.status == .satisfied else { return nil }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }

    // MARK: Logs

    private static let logInstalled = Mutex(false)

    /// The core's lines (`link: …` are this phone's stats: `link[phone]: …`, as the server logs the ones it gets).
    static func installLog() {
        guard logInstalled.withLock({ s -> Bool in defer { s = true }; return !s }) else { return }
        LinkLog.setHandler { level, message in
            let line = message.hasPrefix("link: ") ? "link[phone]: " + message.dropFirst("link: ".count) : message
            emit(line, level: level)
        }
    }

    static func emit(_ line: String, level: LogLevel = .info) {
        switch level {
        case .error: log.error("\(line, privacy: .public)")
        case .warn: log.warning("\(line, privacy: .public)")
        case .debug: log.debug("\(line, privacy: .public)")
        case .info: log.info("\(line, privacy: .public)")
        }
        logHandler?(line)
    }

    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? LinkError else { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        switch e {
        case .InvalidArgument(let m), .Bind(let m), .Connect(let m), .Timeout(let m), .Protocol(let m), .Closed(let m),
             .Binding(let m), .Datagram(let m), .Io(let m), .Media(let m), .Internal(let m):
            return m
        case let .Denied(code, m):
            return "\(code): \(m)"
        }
    }

    private static var deviceName: String {
        MainActor.assumeIsolatedIfMain { UIDevice.current.name } ?? "iPhone"
    }
}

extension ConnectLinkBinding {
    /// The endpoint id it vouches for, when its identity key is the pinned one (`SHA-256(key) == fingerprint`) and the
    /// signature over the link key holds; throws otherwise (a hard failure: don't dial).
    public func verified(fingerprint: String) throws -> String {
        try verifyBinding(binding: Binding(id: id, key: key, sig: sig), fingerprint: fingerprint)
    }
}

extension MainActor {
    /// `body` when on the main thread, else nil.
    static func assumeIsolatedIfMain<T: Sendable>(_ body: @MainActor () -> T) -> T? {
        Thread.isMainThread ? MainActor.assumeIsolated(body) : nil
    }
}

/// This install's link key: 32 random bytes in the keychain (this device only, not synced), made on first use. When the
/// keychain can't be used (a test runner without one), a key for this process.
enum LinkClientKey {
    static var account: String { YoyoHost.key("LinkClientKey") }
    static let service = "YoyoLink"
    private static let fallback = Mutex<Data?>(nil)

    static func load() -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 {
            return data
        }
        if let key = fallback.withLock({ $0 }) { return key }
        let key = generateLinkKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            YoyoLinkClient.emit("link[phone]: keychain unavailable (\(status)): a key for this process only", level: .warn)
            fallback.withLock { $0 = key }
        }
        return key
    }
}
