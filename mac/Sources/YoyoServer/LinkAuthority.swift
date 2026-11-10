#if os(macOS)
import Foundation

/// Authority mode of the link listener (docs/LOCAL-API.md「Link 的主人」, LinkOptions.authority): one local program, the
/// host, decides who may open a link session and who may send input; the service only asks and obeys. Generic: the
/// host's credentials and principals are opaque here.
///
/// - The host holds `GET /link/authority` open (NDJSON; a second one is a 409). Lines to it: `{"type":"auth","id",
///   "credential","device","source"}` per `hello`, `{"type":"control","id","device","want":"take"|"release"}` per
///   `control.take` / `control.release`, `{"type":"session","event":"opened"|"closed","device"}`,
///   `{"type":"activity","device"}` (≤ 1/s per device while its input flows).
/// - `POST /link/authority/answer {id, ok: true, principal: {device: {id, name}, …}}` / `{id, ok: false, code}`;
///   an `auth` unanswered for `answerTimeout` is denied `busy`.
/// - `POST /link/control {holder: {id, name} | null}`: who may send input now; input from anyone else is refused
///   (`input.rejected` `controlled-elsewhere` / `no-control`); every change reaches every session as `control`.
/// - No host: new sessions are denied `busy`; existing ones keep running; the host leaving sets the holder to null.
final class LinkAuthority: @unchecked Sendable {
    static let answerTimeout: TimeInterval = 3
    static let activityEvery: TimeInterval = 1

    /// A device as the host names it (`principal.device`, a holder).
    struct Device: Equatable, Sendable {
        var id: String
        var name: String

        var json: [String: Any] { ["id": id, "name": name] }

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        init?(json: Any?) {
            guard let j = json as? [String: Any], let id = j["id"] as? String, !id.isEmpty else { return nil }
            self.init(id: id, name: j["name"] as? String ?? id)
        }
    }

    /// The host's answer to an `auth`.
    enum Decision: Equatable {
        /// `principal`: the JSON of `welcome.principal` (as the host gave it), `device`: its `device`.
        case accept(principalJSON: String, device: Device)
        /// `code`: unauthorized / rate-limited / busy.
        case deny(code: String, message: String)
    }

    /// The connected host's lines, for its `GET /link/authority` response.
    final class Host: @unchecked Sendable {
        private let cond = NSCondition()
        private var lines: [Data] = []
        private var gone = false

        func push(_ line: Data) {
            cond.lock(); lines.append(line); cond.broadcast(); cond.unlock()
        }

        /// Everything queued; waits until `deadline` while empty ([] = nothing, or gone).
        func take(until deadline: Date) -> [Data] {
            cond.lock(); defer { cond.unlock() }
            while lines.isEmpty, !gone, cond.wait(until: deadline) {}
            let out = lines
            lines.removeAll()
            return out
        }

        func end() { cond.lock(); gone = true; cond.broadcast(); cond.unlock() }
    }

    /// The one in this process (the Router's `/link/*` routes).
    nonisolated(unsafe) static var current: LinkAuthority?

    private let lock = NSLock()
    private var host: Host?
    private var pending: [String: (DispatchWorkItem, (Decision) -> Void)] = [:]
    private var _holder: Device?
    private var lastActivity: [String: Date] = [:]
    private var observers: [Int: (Device?) -> Void] = [:]
    private var nextObserver = 0
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "yoyo-control.link.authority")

    init(timeout: TimeInterval = LinkAuthority.answerTimeout) {
        self.timeout = timeout
    }

    var hasHost: Bool {
        lock.lock(); defer { lock.unlock() }
        return host != nil
    }

    /// Who may send input now.
    var holder: Device? {
        lock.lock(); defer { lock.unlock() }
        return _holder
    }

    // MARK: The host

    /// A host connects; nil while another one is (the route's 409).
    func attach() -> Host? {
        lock.lock()
        defer { lock.unlock() }
        guard host == nil else { return nil }
        let h = Host()
        host = h
        log("link: authority host connected")
        return h
    }

    /// The host went away: what it was asked is denied `busy`, nobody holds control.
    func detach(_ h: Host) {
        lock.lock()
        guard host === h else { lock.unlock(); return }
        host = nil
        let waiting = pending.values
        pending.removeAll()
        lock.unlock()
        h.end()
        log("link: authority host gone")
        for (timer, done) in waiting {
            timer.cancel()
            done(.deny(code: "busy", message: "the authority went away"))
        }
        setHolder(nil)
    }

    private func send(_ object: [String: Any]) -> Bool {
        lock.lock()
        let h = host
        lock.unlock()
        guard let h else { return false }
        var line = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        line.append(0x0a)
        h.push(line)
        return true
    }

    // MARK: Asking

    /// A `hello`: the host's decision (on any thread; within `timeout`, else `busy`; no host: `busy` at once).
    func authorize(credential: String, device: [String: Any], source: String?, done: @escaping (Decision) -> Void) {
        let id = UUID().uuidString.lowercased()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, let d = self.takePending(id) else { return }
            d(.deny(code: "busy", message: "the authority did not answer in \(Int(self.timeout)) s"))
        }
        lock.lock()
        let attached = host != nil
        if attached { pending[id] = (timer, done) }
        lock.unlock()
        guard attached else {
            done(.deny(code: "busy", message: "no authority is connected"))
            return
        }
        var line: [String: Any] = ["type": "auth", "id": id, "credential": credential, "device": device]
        line["source"] = source ?? NSNull()
        _ = send(line)
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
    }

    private func takePending(_ id: String) -> ((Decision) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard let (timer, done) = pending.removeValue(forKey: id) else { return nil }
        timer.cancel()
        return done
    }

    /// `POST /link/authority/answer`'s body. 400 bad body, 404 unknown (or late) id.
    func answer(_ body: [String: Any]) throws {
        guard let id = body["id"] as? String, let ok = body["ok"] as? Bool else {
            throw HTTPError(400, "body must be { id, ok, principal | code }")
        }
        let decision: Decision
        if ok {
            guard let principal = body["principal"] as? [String: Any], let device = Device(json: principal["device"]),
                  let data = try? JSONSerialization.data(withJSONObject: principal, options: [.sortedKeys]) else {
                throw HTTPError(400, "principal must be an object with device: { id, name }")
            }
            decision = .accept(principalJSON: String(decoding: data, as: UTF8.self), device: device)
        } else {
            let code = body["code"] as? String ?? "unauthorized"
            guard ["unauthorized", "rate-limited", "busy"].contains(code) else {
                throw HTTPError(400, "code must be unauthorized, rate-limited or busy")
            }
            decision = .deny(code: code, message: body["message"] as? String ?? "refused by the authority")
        }
        guard let done = takePending(id) else { throw HTTPError(404, "no pending request \(id)") }
        done(decision)
    }

    /// A session asks for control (`want` take / release): the host decides by `POST /link/control`.
    func control(_ want: String, device: Device) {
        _ = send(["type": "control", "id": UUID().uuidString.lowercased(), "device": device.json, "want": want])
    }

    /// A session opened / closed.
    func session(_ event: String, device: Device) {
        _ = send(["type": "session", "event": event, "device": device.json])
    }

    /// Input from `device` went through (at most one line per `activityEvery` per device).
    func activity(_ device: Device, now: Date = Date()) {
        lock.lock()
        let due = lastActivity[device.id].map { now.timeIntervalSince($0) >= Self.activityEvery } ?? true
        if due {
            if lastActivity.count > 256 { lastActivity.removeAll() }
            lastActivity[device.id] = now
        }
        lock.unlock()
        if due { _ = send(["type": "activity", "device": device.json]) }
    }

    // MARK: Control

    /// `POST /link/control`'s holder (nil: nobody); observers hear every change.
    func setHolder(_ device: Device?) {
        lock.lock()
        guard _holder != device else { lock.unlock(); return }
        _holder = device
        let callbacks = Array(observers.values)
        lock.unlock()
        log("link: authority: control \(device.map { "given to \($0.name)" } ?? "released")")
        callbacks.forEach { $0(device) }
    }

    /// Calls `onChange` (any thread) after every holder change; the token removes it.
    func observe(_ onChange: @escaping (Device?) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        nextObserver += 1
        observers[nextObserver] = onChange
        return nextObserver
    }

    func removeObserver(_ token: Int) {
        lock.lock(); observers[token] = nil; lock.unlock()
    }

    /// Whether `device`'s input may go through now; the refusal's status, code and message otherwise.
    func admitInput(from device: Device) -> (status: Int, code: String, message: String)? {
        guard let h = holder else { return (409, "no-control", "the authority gave control to nobody") }
        guard h.id == device.id else { return (409, RemoteControl.controlledElsewhere, "\(h.name) controls the screen") }
        return nil
    }
}

extension Router {
    /// `GET /link/authority`: the host's NDJSON channel (unix socket only; 404 without authority mode, 409 while
    /// another host is connected). Ends when the host hangs up or the service stops.
    static func linkAuthority(_ req: HTTPRequest, _ conn: Connection) throws {
        let authority = try linkAuthorityOrThrow(req)
        guard let host = authority.attach() else { throw HTTPError(409, "another authority host is connected") }
        defer { authority.detach(host) }
        guard conn.writeHead(status: 200, headers: [
            ("Content-Type", "application/x-ndjson"),
            ("Cache-Control", "no-cache"),
        ]) else { return }
        while !conn.peerClosed() {
            for line in host.take(until: Date().addingTimeInterval(0.5)) {
                guard conn.write(line) else { return }
            }
        }
    }

    /// `POST /link/authority/answer` → `{ ok: true }`.
    static func linkAuthorityAnswer(_ req: HTTPRequest, _ conn: Connection) throws {
        let authority = try linkAuthorityOrThrow(req)
        guard let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            throw HTTPError(400, "body must be a JSON object")
        }
        try authority.answer(body)
        conn.json(200, ["ok": true])
    }

    /// `POST /link/control { holder: { id, name } | null }` → `{ ok: true, holder }`.
    static func linkControl(_ req: HTTPRequest, _ conn: Connection) throws {
        let authority = try linkAuthorityOrThrow(req)
        guard let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any], body.keys.contains("holder") else {
            throw HTTPError(400, "body must be { holder: { id, name } | null }")
        }
        let holder = LinkAuthority.Device(json: body["holder"])
        if holder == nil, !(body["holder"] is NSNull) { throw HTTPError(400, "holder must be { id, name } or null") }
        authority.setHolder(holder)
        conn.json(200, ["ok": true, "holder": holder?.json ?? NSNull()])
    }

    private static func linkAuthorityOrThrow(_ req: HTTPRequest) throws -> LinkAuthority {
        guard req.remote == nil, let a = LinkAuthority.current else { throw HTTPError(404, "no such endpoint \(req.path)") }
        return a
    }
}
#endif
