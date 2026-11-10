#if os(macOS)
import CryptoKit
import Foundation

/// The signaling server (docs/RELAY.md; `relay/signal` is one): keeps this Mac registered in its
/// room (a WebSocket, signed in with the identity key, so only this Mac can hold the room). Through it browsers hand
/// their WebRTC offers to the link listener, and phones and browsers find the link binding (`/v1/candidates`).
///
/// Reconnects after a drop (1 s, doubling to 60 s); a `ping` every 30 s, and no `pong` for 45 s counts as a drop (a
/// network change, the Mac waking up). Run by `RemoteAccess` while the link listener runs.
///
/// The link listener's binding and addresses (docs/LINK.md) go to the room as `{ type: "link", id, key, sig, relays,
/// direct }` after `ready` and whenever they change.
///
/// A browser's WebRTC offer (docs/RELAY.md「WebRTC」) arrives as `{ type: "rtc", id, offer, from? }`; the link
/// listener answers it (`LinkRtcSignaling`) and the answer goes back as `{ type: "rtc-answer", id, answer }`, or
/// `{ type: "rtc-error", id, status, message }`.
///
/// The account this Mac is in (docs/ACCOUNT.md, nil: none) goes as `{ type: "account", id }` after `ready` and when
/// it changes; the room answers `{ type: "account", state: "linked" | "unlinked" }` (and says "unlinked" whenever a
/// phone takes the Mac out of the account's directory): `onUnlinked` then.
final class RemoteSignal: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    static let pingInterval: TimeInterval = 30
    static let pongTimeout: TimeInterval = 45
    static let maxBackoff: TimeInterval = 60

    /// The signaling server (`YOYO_SIGNAL_URL`, `wss://…`; docs/RELAY.md「信令服务」, `relay/signal` is one); none is
    /// built in: unset = no signaling (no browser pairing, no lookup by fingerprint; LAN / direct paths still work).
    static var baseURL: URL? {
        let env = (ProcessInfo.processInfo.environment["YOYO_SIGNAL_URL"] ?? "").trimmingCharacters(in: .whitespaces)
        return env.isEmpty || env == "off" ? nil : URL(string: env)
    }

    let base: URL
    /// The room: the key's fingerprint as 64 lowercase hex digits.
    let room: String
    private let key: P256.Signing.PrivateKey
    private let queue = DispatchQueue(label: "yoyo-control.signal")
    private var session: URLSession!
    private var control: URLSessionWebSocketTask?
    private var running = false
    /// Read from any thread (`GET /remote`), written on `queue`.
    private let registeredLock = NSLock()
    private var registered = false
    private var backoff: TimeInterval = 1
    private var lastPong = Date()
    private var pinger: DispatchSourceTimer?
    private var _link: [String: Any]?
    private var _account: String?
    /// Called on the queue when `isRegistered` changes.
    var onChange: (() -> Void)?
    /// Called on the queue when the room says this Mac isn't in the account it named.
    var onUnlinked: (() -> Void)?

    init(key: P256.Signing.PrivateKey, base: URL) {
        self.key = key
        self.base = base
        room = Self.room(of: key.publicKey)
        super.init()
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: ops)
    }

    var isRegistered: Bool {
        registeredLock.lock()
        defer { registeredLock.unlock() }
        return registered
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            connect()
        }
    }

    /// Leaves the room (from any thread, `queue` included).
    func stop() {
        queue.async { [self] in
            running = false
            pinger?.cancel()
            pinger = nil
            control?.cancel(with: .goingAway, reason: nil)
            control = nil
            setRegistered(false)
            queue.async { self.session.invalidateAndCancel() }
        }
    }

    /// The link listener's `{ id, key, sig, relays, direct }` told to the room (nil: none); sent again when it changes.
    var link: [String: Any]? {
        get { queue.sync { _link } }
        set {
            queue.async { [self] in
                guard Self.linkMessage(_link) != Self.linkMessage(newValue) else { return }
                _link = newValue
                if isRegistered, let task = control, let m = Self.linkMessage(newValue) { task.send(.string(m)) { _ in } }
            }
        }
    }

    /// The account told to the room (nil: none); sent again when it changes.
    var account: String? {
        get { queue.sync { _account } }
        set {
            queue.async { [self] in
                guard _account != newValue else { return }
                _account = newValue
                if isRegistered, let task = control { sendAccount(task) }
            }
        }
    }

    private func sendAccount(_ task: URLSessionWebSocketTask) {
        task.send(.string(Self.accountMessage(_account))) { _ in }
    }

    /// `{"id":…,"type":"account"}` (`"id":null` for none).
    static func accountMessage(_ id: String?) -> String {
        let body: [String: Any] = ["type": "account", "id": id ?? NSNull()]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// `{"direct":[…],"id":…,"key":…,"relays":[…],"sig":…,"type":"link"}` (keys sorted); nil without a link.
    static func linkMessage(_ link: [String: Any]?) -> String? {
        guard var body = link else { return nil }
        body["type"] = "link"
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func sendLink(_ task: URLSessionWebSocketTask) {
        if let m = Self.linkMessage(_link) { task.send(.string(m)) { _ in } }
    }

    // MARK: The room (the control connection)

    private func connect() {
        guard running else { return }
        let task = session.webSocketTask(with: Self.roomURL(base, room))
        control = task
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.control === task else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text, task)
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure(let error):
                    self.dropped(task, "\(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ text: String, _ task: URLSessionWebSocketTask) {
        if text == "pong" {
            lastPong = Date()
            return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "challenge":
            guard let nonce = json["nonce"] as? String, let hello = try? Self.hello(nonce: nonce, key: key) else {
                dropped(task, "a challenge it can't answer")
                return
            }
            task.send(.string(hello)) { _ in }
        case "ready":
            backoff = 1
            lastPong = Date()
            setRegistered(true)
            startPinging(task)
            sendLink(task)
            sendAccount(task)
            log("remote: signal: registered (\(base.host() ?? "?"))")
        case "rtc":
            guard let id = json["id"] as? String, id.count == 32, id.allSatisfy(\.isHexDigit) else { return }
            answerRtc(id: id, offer: json["offer"], from: json["from"] as? String, task)
        case "account":
            if json["state"] as? String == "unlinked", _account != nil {
                _account = nil
                onUnlinked?()
            }
        default:
            break
        }
    }

    private func startPinging(_ task: URLSessionWebSocketTask) {
        pinger?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        t.setEventHandler { [weak self, weak task] in
            guard let self, let task, self.control === task else { return }
            if Date().timeIntervalSince(self.lastPong) > Self.pingInterval + Self.pongTimeout {
                self.dropped(task, "no pong")
            } else {
                task.send(.string("ping")) { _ in }
            }
        }
        pinger = t
        t.resume()
    }

    private func dropped(_ task: URLSessionWebSocketTask, _ why: String) {
        guard control === task else { return }
        control = nil
        pinger?.cancel()
        pinger = nil
        let how = Self.closeDetail(task)
        task.cancel(with: .goingAway, reason: nil)
        if isRegistered || backoff == 1 { log("remote: signal: disconnected from \(base.host() ?? "?") (\(why)\(how)); again in \(Int(backoff)) s") }
        setRegistered(false)
        guard running else { return }
        let wait = backoff
        backoff = min(backoff * 2, Self.maxBackoff)
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.running, self.control == nil else { return }
            self.connect()
        }
    }

    /// The close frame the server sent, if any (", closed 1011 reason"): tells the server closing it from the network
    /// dropping it, which only says "Socket is not connected".
    static func closeDetail(_ task: URLSessionWebSocketTask) -> String {
        closeDetail(code: task.closeCode, reason: task.closeReason)
    }

    static func closeDetail(code: URLSessionWebSocketTask.CloseCode, reason: Data?) -> String {
        guard code != .invalid else { return "" }
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        return ", closed \(code.rawValue)" + (text.map { " \($0)" } ?? "")
    }

    private func setRegistered(_ on: Bool) {
        registeredLock.lock()
        let changed = registered != on
        registered = on
        registeredLock.unlock()
        if changed { onChange?() }
    }

    // MARK: Browsers' offers

    /// A browser's offer → `rtc-answer` / `rtc-error` on the control connection.
    private func answerRtc(id: String, offer: Any?, from: String?, _ task: URLSessionWebSocketTask) {
        Task { [weak self] in
            let reply = await Self.rtcReply(id: id, offer: offer, from: from)
            self?.queue.async {
                guard let self, self.control === task else { return }
                task.send(.string(reply)) { _ in }
            }
        }
    }

    /// The reply to an `rtc` message (keys sorted).
    static func rtcReply(id: String, offer: Any?, from: String?,
                         answerer: ((String, String?) async throws -> String)? = LinkRtcSignaling.answer) async -> String {
        var reply: [String: Any] = ["id": id]
        do {
            guard let offer = offer as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: offer) else {
                throw LinkRtcSignaling.Failure(status: 400, message: "offer must be a JSON object")
            }
            guard let answerer else { throw LinkRtcSignaling.Failure(status: 404, message: "uu Link's WebRTC is not running") }
            let answer = try await answerer(String(decoding: data, as: UTF8.self), from)
            guard let object = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) else {
                throw LinkRtcSignaling.Failure(status: 500, message: "answer is not JSON")
            }
            reply["type"] = "rtc-answer"
            reply["answer"] = object
        } catch {
            let f = error as? LinkRtcSignaling.Failure ?? LinkRtcSignaling.Failure(status: 503, message: "\(error)")
            reply["type"] = "rtc-error"
            reply["status"] = f.status
            reply["message"] = f.message
        }
        let data = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Helpers

    /// Where the Mac registers: `/v1/mac/<room>`.
    static func roomURL(_ base: URL, _ room: String) -> URL { base.appending(path: "v1/mac/\(room)") }

    /// The room of a public key: 64 lowercase hex digits of SHA-256 over its X9.63 bytes (`RemoteIdentity.fingerprint`
    /// without "sha256:").
    static func room(of key: P256.Signing.PublicKey) -> String {
        SHA256.hash(data: key.x963Representation).map { String(format: "%02x", $0) }.joined()
    }

    /// The answer to the room's challenge: `{ type: "hello", v: 1, key, sig }`, `sig` over "yoyocontrol-relay-v1:" + nonce.
    static func hello(nonce: String, key: P256.Signing.PrivateKey) throws -> String {
        let signature = try key.signature(for: Data(("yoyocontrol-relay-v1:" + nonce).utf8))
        let body: [String: Any] = [
            "type": "hello", "v": 1,
            "key": key.publicKey.x963Representation.base64EncodedString(),
            "sig": signature.rawRepresentation.base64EncodedString(),
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
    }
}

#endif
