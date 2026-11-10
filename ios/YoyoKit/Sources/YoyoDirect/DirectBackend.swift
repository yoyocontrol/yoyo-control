import Foundation
import UIKit
import YoyoConnect
import YoyoCore
import YoyoScreen
import YoyoLinkClient

/// Yoyo Control's own `YoyoBackend`: a Mac over uu Link (docs/REMOTE.md, docs/LINK.md): the Mac's own routes
/// (`/status`, `/stream`, `/input`, `/control`, `/clipboard`…) as RPC over the session, the paired token in its
/// `hello`, the Screen page's media on the session itself (`screenLink(for:)`). Its answers are mapped onto the kits'
/// models:
/// - `/status` → `ScreenStatus`: `available` = `ok`; a paired phone holding control (`control.controller == "remote"`)
///   is `controller: user` with that phone as `controllerDevice` (this one or another: the page tells which by id);
///   otherwise automation driving the Mac (`automation.active`; an older Mac: `agentControl.active`) is `agent`.
/// - `POST /control` answers `{ ok, control }`: the status is read again after it.
/// - `GET /clipboard` answers the item itself (`ok` + `ClipboardItem`; 503 without a GUI session): a `ClipboardStatus`
///   with it. A paired phone sends only text (`POST /clipboard { text }`: files are paths on the Mac).
/// - `/events` lines (read by `DirectEvents` while the page shows, streamed over RPC) → `YoyoEvent`s for every
///   subscriber of `events()`.
/// - Control is the session's `control.take` / `control.release`.
struct DirectBackend: YoyoBackend {
    let token: String
    let serverId: String
    let fingerprint: String
    /// The link session to the Mac; shared with the page's routing (a `YoyoConnector`, `DirectConnect`). nil: none
    /// (tests of the mapping).
    let ways: DirectWays?
    /// What `DirectEvents` read, for every subscriber.
    let hub = YoyoEventHub()
    /// What the computer said it is last time (the page's words before its status comes).
    let platformHint: YoyoPlatform?

    init(ways: DirectWays?, token: String, serverId: String, fingerprint: String, platform: YoyoPlatform? = nil) {
        self.ways = ways
        platformHint = platform
        self.token = token
        self.serverId = serverId
        self.fingerprint = fingerprint
    }

    /// The base of the requests' URLs: never dialed (they go over the session as RPC: method, path, query).
    static let linkBase = URL(string: "https://link.invalid")!

    var cacheScope: String { "yoyocontrol:\(serverId)" }

    /// The way in use (the routing's `current`).
    var route: YoyoRoute { ways?.current ?? DirectConnect.link(YoyoMac(id: serverId, name: "", fingerprint: fingerprint, token: token)).route(shortcut: false) }
    var onLan: Bool { route.isLocalNetwork }

    /// YoyoConnect over the Mac's link (`DirectConnect`): a new session when one ends.
    @MainActor func makeRouting() -> (any YoyoRouting)? {
        guard let ways else { return nil }
        let connector = YoyoConnector(ways: ways.connect, source: DirectConnect.source(ways: ways, probes: .live),
                                      policy: DirectConnect.policy)
        connector.linkPossible = true
        return connector
    }

    /// The way's link session, which carries the page's media.
    func screenLink(for route: YoyoRoute) -> (any YoyoScreenLink)? { ways?.connection(for: route) }

    func events() -> AsyncStream<YoyoEvent>? { hub.subscribe() }

    // MARK: Requests

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: Any]? = nil,
                 timeout: TimeInterval, route: YoyoRoute? = nil) throws -> URLRequest {
        var url = Self.linkBase.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    /// The answer's body for a 2xx; a 409 `controlled-elsewhere` as `ScreenControlledElsewhere`, a 401 as
    /// `YoyoError.unauthorized` (this phone was removed on the Mac), anything else as `YoyoError.http`.
    func send(_ req: URLRequest, route: YoyoRoute? = nil) async throws -> Data {
        try await sendWithResponse(req, route: route).0
    }

    /// As RPC on the way's link session (`route`: the way the request was made for; nil: the one in use).
    func sendWithResponse(_ req: URLRequest, route: YoyoRoute? = nil) async throws -> (Data, HTTPURLResponse?) {
        let (data, resp) = try await transport(req, route: route)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { throw YoyoError.unauthorized }
            if code == 409, let refusal = ScreenControlledElsewhere(json: data) { throw refusal }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw YoyoError.http(code, message)
        }
        return (data, http)
    }

    private func transport(_ req: URLRequest, route: YoyoRoute?) async throws -> (Data, URLResponse) {
        // none: between sessions (the routing dials a new one)
        guard let link = ways?.connection(for: route) else { throw URLError(.networkConnectionLost) }
        return try await link.data(for: req)
    }

    /// `/events`-like answers, line by line (NDJSON), over the link: the status and the lines.
    func lines(_ req: URLRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        guard let link = ways?.connection() else { throw URLError(.networkConnectionLost) }
        let (resp, lines) = try await link.lines(for: req)
        return (resp.statusCode, lines)
    }

    func status() async throws -> ScreenStatus {
        let data = try await send(request("GET", "status", timeout: 4))
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw YoyoError.decoding("status")
        }
        return try Self.status(fromMac: json)
    }

    /// `GET /stream?…`: `display`, `maxWidth`, `quality`, `fps` and the options as the query.
    func streamRequest(display: UInt32?, maxWidth: Int?, quality: Int?, fps: Int?, options: ScreenStreamOptions,
                       route: YoyoRoute) throws -> URLRequest {
        var fields: [String: Any] = [:]
        if let display { fields["display"] = Int(display) }
        if let maxWidth { fields["maxWidth"] = maxWidth }
        if let quality { fields["quality"] = quality }
        if let fps { fields["fps"] = fps }
        options.add(to: &fields)
        let query = fields.keys.sorted().map { URLQueryItem(name: $0, value: "\(fields[$0]!)") }
        // an idle timeout: the Mac resends the last picture every few seconds
        var req = try request("GET", "stream", query: query, timeout: 20, route: route)
        req.setValue(ScreenWire.streamAccept, forHTTPHeaderField: "Accept")  // the Yoyo part names (an older Mac ignores it)
        return req
    }

    func ackRequest(_ ack: ScreenStreamAck, route: YoyoRoute) throws -> URLRequest {
        // a late ack is worthless (a newer one covers it), and one stuck in the network holds one of the few in-flight
        // slots: give up soon, so a fresh ack goes out before the Mac drops the window (3 s without one)
        try request("POST", "stream/ack", json: ack.json, timeout: 1.5, route: route)
    }

    func audioRequest(route: YoyoRoute) throws -> URLRequest {
        var req = try request("GET", "audio", timeout: 20, route: route)
        req.setValue(ScreenWire.audioAccept, forHTTPHeaderField: "Accept")
        return req
    }

    func input(_ input: ScreenInput, route: YoyoRoute) async throws {
        _ = try await send(request("POST", "input", json: input.json, timeout: 3, route: route), route: route)
    }

    /// The session's `control.take` / `control.release`, then the status as it is now.
    func setControl(_ controller: ScreenController, route: YoyoRoute) async throws -> ScreenStatus {
        guard let link = ways?.connection(for: route) else { throw URLError(.networkConnectionLost) }
        let answer = try await link.control(take: controller == .user)
        if controller == .user, !answer.granted {
            if let holder = answer.holder, holder.id != ScreenControlDevice.currentId {
                throw ScreenControlledElsewhere(controllerDevice: holder)
            }
            throw YoyoError.http(409, nil)
        }
        return try await status()
    }

    func focus(display: UInt32?, route: YoyoRoute) async throws -> ScreenFocus {
        let query = display.map { [URLQueryItem(name: "display", value: String($0))] } ?? []
        return ScreenFocus(json: try await send(request("GET", "focus", query: query, timeout: 1.5, route: route), route: route))
    }

    /// `GET /frame?display=&maxWidth=&quality=`: one JPEG.
    func frame(display: UInt32?, maxWidth: Int?, quality: Int?) async throws -> Data {
        var query: [URLQueryItem] = []
        if let display { query.append(URLQueryItem(name: "display", value: String(display))) }
        if let maxWidth { query.append(URLQueryItem(name: "maxWidth", value: String(maxWidth))) }
        if let quality { query.append(URLQueryItem(name: "quality", value: String(quality))) }
        return try await send(request("GET", "frame", query: query, timeout: 6))
    }

    /// The prompts are the Mac's to show: a paired phone can't ask for them.
    func requestPermissions() async throws -> ScreenStatus {
        throw YoyoError.http(403, L("Grant the permissions from Yoyo Control’s menu on the Mac."))
    }

    // MARK: Clipboard

    /// `GET /clipboard` as a `ClipboardStatus` (503: the Mac can't do clipboard now, its reason kept).
    func clipboard() async throws -> ClipboardStatus {
        do {
            return try Self.clipboardStatus(fromMac: try await send(request("GET", "clipboard", timeout: 10)))
        } catch YoyoError.http(503, let message) {
            return ClipboardStatus(available: false, reason: message)
        }
    }

    func clipboardImage(changeCount: Int) async throws -> Data {
        try await send(request("GET", "clipboard/image", timeout: 30))
    }

    func clipboardFile(index: Int, changeCount: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> YoyoDownload {
        let (data, resp) = try await sendWithResponse(request("GET", "clipboard/file", query: [URLQueryItem(name: "index", value: String(index))],
                                                              timeout: 120))
        progress(1)
        let name = resp.flatMap { Self.filename(contentDisposition: $0.value(forHTTPHeaderField: "Content-Disposition")) }
        return YoyoDownload(data: data, name: name, mime: resp?.value(forHTTPHeaderField: "Content-Type"))
    }

    func putClipboard(text: String) async throws -> ClipboardPutResponse {
        let data = try await send(request("POST", "clipboard", json: ["text": text], timeout: 30))
        return ClipboardPutResponse(status: try Self.clipboardStatus(fromMac: data))
    }

    // MARK: Mapping

    /// The Mac's `/status` as the page's `ScreenStatus`.
    static func status(fromMac mac: [String: Any]) throws -> ScreenStatus {
        var fields: [String: Any] = [
            "available": mac["ok"] as? Bool ?? false,
            "screenRecording": mac["screenRecording"] as? Bool ?? false,
            "accessibility": mac["accessibility"] as? Bool ?? false,
            "displays": mac["displays"] ?? [],
            "states": mac["states"] ?? [],
        ]
        if let error = mac["error"] as? String { fields["reason"] = error }
        if let console = mac["console"], !(console is NSNull) { fields["console"] = console }
        // a Mac that says what it is and can do (a newer one): as it says
        for key in ["platform", "features"] { if let v = mac[key], !(v is NSNull) { fields[key] = v } }
        fields.merge(controlFields(mac["control"] as? [String: Any], agentActive: agentActive(mac))) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: fields)
        do { return try JSONDecoder().decode(ScreenStatus.self, from: data) } catch { throw YoyoError.decoding("status") }
    }

    static func agentActive(_ mac: [String: Any]) -> Bool {
        ((mac["automation"] ?? mac["agentControl"]) as? [String: Any])?["active"] as? Bool ?? false
    }

    /// `controller`, `controllerSince`, `controllerDevice` from the Mac's `control`.
    static func controlFields(_ control: [String: Any]?, agentActive: Bool) -> [String: Any] {
        if control?["controller"] as? String == "remote", let device = control?["device"] as? [String: Any] {
            var f: [String: Any] = ["controller": "user", "controllerDevice": device]
            if let since = control?["since"] as? Double { f["controllerSince"] = since }
            return f
        }
        return ["controller": agentActive ? "agent" : "none"]
    }

    /// The Mac's `GET /clipboard` (the item itself, with `ok`) as a `ClipboardStatus`.
    static func clipboardStatus(fromMac data: Data) throws -> ClipboardStatus {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw YoyoError.decoding("clipboard") }
        var item = json
        item["ok"] = nil
        let body = try JSONSerialization.data(withJSONObject: ["available": true, "item": item])
        do { return try JSONDecoder().decode(ClipboardStatus.self, from: body) } catch { throw YoyoError.decoding("clipboard") }
    }

    /// `filename*=UTF-8''<percent-encoded>` (or a plain `filename="…"`) of a `Content-Disposition`.
    static func filename(contentDisposition value: String?) -> String? {
        guard let value else { return nil }
        for part in value.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.lowercased().hasPrefix("filename*="), let i = part.range(of: "''") {
                return String(part[i.upperBound...]).removingPercentEncoding
            }
        }
        for part in value.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where part.lowercased().hasPrefix("filename=") {
            return String(part.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// One `/events` line of the Mac as the kits' event, nil for the others.
    static func event(fromMacLine line: [String: Any]) -> [String: Any]? {
        switch line["type"] as? String {
        case "state":
            var e: [String: Any] = ["type": "screen.state", "states": line["states"] ?? []]
            if let console = line["console"], !(console is NSNull) { e["console"] = console }
            return e
        case "control":
            var e = controlFields(line["control"] as? [String: Any], agentActive: false)
            e["type"] = "screen.control"
            return e
        case "clipboard":
            var item = line
            item["type"] = nil
            return ["type": "clipboard.changed", "available": true, "item": item]
        default:
            return nil
        }
    }
}

/// The Mac's `/events` (NDJSON), read while the page shows, handed to the backend's subscribers (`YoyoEventHub`).
/// Reconnects 1 s → 10 s after an end; a 401 goes to `unauthorized` and stops.
final class DirectEvents: @unchecked Sendable {
    private let backend: DirectBackend
    private var task: Task<Void, Never>?
    private let unauthorized: @MainActor () -> Void

    init(backend: DirectBackend, unauthorized: @escaping @MainActor () -> Void) {
        self.backend = backend
        self.unauthorized = unauthorized
    }

    func start() {
        guard task == nil else { return }
        let backend = backend
        let unauthorized = unauthorized
        task = Task.detached(priority: .utility) {
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    let req = try backend.request("GET", "events", timeout: 40)
                    let (code, lines) = try await backend.lines(req)
                    if code == 401 {
                        await MainActor.run { unauthorized() }
                        return
                    }
                    if (200..<300).contains(code) {
                        delay = 1
                        for try await line in lines {
                            guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                                  var event = DirectBackend.event(fromMacLine: json) else { continue }
                            // nobody's phone holds control any more: an agent may be using the Mac (only /status says)
                            if json["type"] as? String == "control", event["controller"] as? String == "none",
                               let status = try? await backend.status(), status.controller == .agent {
                                event["controller"] = "agent"
                            }
                            guard let data = try? JSONSerialization.data(withJSONObject: event),
                                  let e = YoyoEvent(json: data) else { continue }
                            backend.hub.post(e)
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 10)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The page is gone for good.
    func close() { stop() }
}

/// What the app presents for a Mac: the kit's page, plus the Mac's event reader for as long as it shows.
final class DirectScreenContainer: UIViewController {
    private let page: UIViewController
    private let events: DirectEvents
    /// The way to the Mac (its link session): closed as the page closes.
    var ways: DirectWays?
    var onClose: (() -> Void)?

    init(page: UIViewController, events: DirectEvents) {
        self.page = page
        self.events = events
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(page)
        page.view.frame = view.bounds
        page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(page.view)
        page.didMove(toParent: self)
        events.start()
    }

    override var childForStatusBarHidden: UIViewController? { page }
    override var childForHomeIndicatorAutoHidden: UIViewController? { page }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { page }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { page.supportedInterfaceOrientations }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            events.close()
            ways?.close()
            ways = nil
            onClose?()
        }
    }
}

/// The page shown for a Mac, for the 401 handler (one at a time).
@MainActor
private final class ShownPage {
    weak var container: DirectScreenContainer?
    var fired = false
}

extension YoyoClient {
    /// Reaches `mac` over its link, and makes the page that shows and controls it (present it full screen). `mac` comes
    /// back as it said it is now (its binding, its platform: save it). `unpaired`: the Mac stopped knowing this phone
    /// while the page showed (it closes itself first). `pro`: whether this phone has Yoyo Control Pro; without it a
    /// session must be on the local network, else `Failure.needsPro` (`RemoteAccess`; a page already showing isn't
    /// affected). `host`: the app's settings for the page (its `deviceId` and `handleError` are set here).
    @MainActor
    public static func connect(_ mac: YoyoMac, deviceId: String, pro: Bool = true, host: YoyoHost = YoyoHost(),
                               unpaired: @escaping @MainActor () -> Void) async throws -> (mac: YoyoMac, controller: UIViewController) {
        let located = try await locate(mac, pro: pro)
        let ways = DirectWays(mac: located.mac, pro: pro, link: located.link)
        let backend = DirectBackend(ways: ways, token: mac.token, serverId: mac.id, fingerprint: mac.fingerprint,
                                    platform: located.mac.platform.map(YoyoPlatform.init(rawValue:)))
        let shown = ShownPage()
        // a 401 may come from the event reader and a page request at once: close and tell once
        let gone: @MainActor () -> Void = {
            guard !shown.fired else { return }
            shown.fired = true
            if let c = shown.container, c.presentingViewController != nil, !c.isBeingDismissed {
                c.dismiss(animated: true) { unpaired() }
            } else {
                unpaired()
            }
        }
        var host = host
        host.deviceId = deviceId
        host.handleError = { error in
            guard case YoyoError.unauthorized? = error as? YoyoError else { return false }
            gone()
            return true
        }
        let container = DirectScreenContainer(page: YoyoScreen.makePage(backend: backend, host: host),
                                              events: DirectEvents(backend: backend, unauthorized: gone))
        container.ways = ways
        shown.container = container
        return (located.mac, container)
    }
}
