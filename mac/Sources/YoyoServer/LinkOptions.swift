#if os(macOS)
import Foundation

/// uu Link's listener (docs/LINK.md): remote access's door (UDP / QUIC, WebRTC for browsers), with the same routes as
/// the unix socket. What an embedder chooses. No relay is built in: whoever runs the service names its own
/// (`relays`, `YOYO_LINK_RELAYS`), or there is none and phones reach it directly only.
///
/// - Default mode (`authority == false`): remote access itself (`--remote`): pairs phones (`Pair <code>`),
///   authenticates `Bearer <token>` against its paired devices and binds each token to the first link key it is used
///   with.
/// - Authority mode: a local program (the host) decides who enters and who controls, over the unix socket
///   (`GET /link/authority`, docs/LOCAL-API.md「Link 的主人」); runs as long as the service, with or without remote access.
public struct LinkOptions: Sendable, Equatable {
    public static let defaultPort: UInt16 = 47_820
    /// UDP port on every interface (0 = any).
    public var port: UInt16
    /// Relay URLs (`https://…`, iroh relays), published to phones in the binding; empty = direct only (no relay path,
    /// and no hole punching: that needs a relay on both ends).
    public var relays: [String]
    /// Where `link-key` lives (and, without remote access, the P-256 identity it is bound to: `tls-key.der`); nil = the
    /// remote access home.
    public var keyDirectory: String?
    /// Authority mode: a local host authorizes sessions and control (see above).
    public var authority: Bool
    /// Ask the router for a UDP port mapping (UPnP / PCP / NAT-PMP); nil = yes, unless `YOYO_PORTMAP=off`.
    public var portMapping: Bool?
    /// Bind only these IP addresses instead of every interface (a host with several networks, tests); empty = all.
    public var bindAddresses: [String]
    /// Write a per-frame trace of every session here (`LinkTrace`, docs/LINK.md「逐帧跟踪」); nil = none.
    public var traceDirectory: String?
    /// The WebRTC socket for browsers (docs/LINK.md「WebRTC」: offers through `POST /link/rtc` and the signaling server); false =
    /// none.
    public var rtc: Bool
    /// Its UDP port; nil = the link port + 1 (47821 with the default; any when the link port is any).
    public var rtcPort: UInt16?
    /// STUN servers (`host:port`) for this Mac's public address in rtc answers; empty = none (the router's mapping and
    /// the interfaces' addresses).
    public var stunServers: [String]

    public init(port: UInt16 = LinkOptions.defaultPort, relays: [String] = [], keyDirectory: String? = nil,
                authority: Bool = false, portMapping: Bool? = nil, bindAddresses: [String] = [], traceDirectory: String? = nil,
                rtc: Bool = true, rtcPort: UInt16? = nil, stunServers: [String] = []) {
        self.port = port
        self.relays = relays
        self.keyDirectory = keyDirectory
        self.authority = authority
        self.portMapping = portMapping
        self.bindAddresses = bindAddresses
        self.traceDirectory = traceDirectory
        self.rtc = rtc
        self.rtcPort = rtcPort
        self.stunServers = stunServers
    }

    /// The rtc port for a link port (`rtcPort`, else the next one).
    func rtcPort(forLinkPort port: UInt16) -> UInt16 {
        rtcPort ?? (port == 0 || port == .max ? 0 : port + 1)
    }

    /// The defaults (no relay), with `YOYO_LINK_RELAYS` (a comma list of iroh relay URLs, `?token=` an access token;
    /// `off` or unset = none) and the test switches `YOYO_LINK_PORT` (another UDP port, beside a
    /// running app), `YOYO_LINK_BIND` (a comma list of addresses to bind instead of every interface, e.g. behind an
    /// impairment proxy), and `YOYO_LINK_TRACE` (a directory for per-frame session traces; the app sets it to its log directory's
    /// `link-trace`, `off` = none); `YOYO_LINK_RTC_PORT` (the WebRTC socket's port, `off` = none).
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LinkOptions {
        var o = LinkOptions()
        if let p = env["YOYO_LINK_PORT"].flatMap(UInt16.init) { o.port = p }
        if let r = env["YOYO_LINK_RELAYS"] {
            o.relays = r == "off" ? [] : r.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let b = env["YOYO_LINK_BIND"], !b.isEmpty {
            o.bindAddresses = b.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let t = env["YOYO_LINK_TRACE"], !t.isEmpty, t != "off" { o.traceDirectory = t }
        if let r = env["YOYO_LINK_RTC_PORT"] {
            if r == "off" { o.rtc = false } else if let p = UInt16(r) { o.rtcPort = p }
        }
        return o
    }
}

/// The running link listener's `/status` `link` (`{ id, key, sig, port, relays, direct, rtc? }`), set while it runs.
enum LinkStatus {
    nonisolated(unsafe) static var current: (() -> [String: Any]?)?
}

/// The link listener's WebRTC signaling (docs/LINK.md「WebRTC」): a browser's offer JSON → the signed answer JSON. Set
/// while the listener runs with rtc; used by `POST /link/rtc` (the unix socket) and the relay's `rtc` messages.
enum LinkRtcSignaling {
    /// Why an offer got no answer, as the HTTP status `POST /link/rtc` answers.
    struct Failure: Error, Equatable {
        let status: Int
        let message: String
    }

    nonisolated(unsafe) static var answer: ((_ offer: String, _ sourceIP: String?) async throws -> String)?

    /// `answer` for the synchronous routes (the caller's thread waits; at most 15 s).
    static func answerBlocking(_ offer: String, sourceIP: String?) throws -> String {
        guard let answer else { throw Failure(status: 404, message: "uu Link's WebRTC is not running") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<String, Error> = .failure(Failure(status: 504, message: "no answer"))
        Task {
            do { result = .success(try await answer(offer, sourceIP)) } catch { result = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 15) == .success else { throw Failure(status: 504, message: "no answer") }
        return try result.get()
    }
}

extension Router {
    /// `POST /link/rtc` (the unix socket only): body = a browser's offer JSON → the answer JSON (docs/LOCAL-API.md); 404
    /// while uu Link (or its WebRTC socket) isn't running, 400 a bad offer, 429 / 503 the guard's refusals.
    static func linkRtc(_ req: HTTPRequest, _ conn: Connection) throws {
        guard req.remote == nil else { throw HTTPError(404, "no such endpoint \(req.path)") }
        let offer = String(decoding: req.body, as: UTF8.self)
        do {
            let answer = try LinkRtcSignaling.answerBlocking(offer, sourceIP: nil)
            conn.respond(status: 200, contentType: "application/json", body: Data(answer.utf8))
        } catch let f as LinkRtcSignaling.Failure {
            throw HTTPError(f.status, f.message)
        }
    }
}
#endif
