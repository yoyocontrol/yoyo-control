import Foundation
import Security

/// Everything the kits' pages ask of one computer (docs/PROTOCOL.md): its status, the picture stream and its acks, the
/// sound, input, control, and optionally a single frame, the focus, the permission prompts, the clipboard and events.
/// The kits don't know how the computer is reached: Yoyo Control's own app reaches a Mac directly or through the relay
/// (YoyoDirect); another app may go through its own server. The streams are handed over as `URLRequest`s and run on the
/// kits' own data-delegate sessions (the acks on the stream's session, so they ride its connection); the rest are calls.
///
/// Errors: `YoyoError.http(code, message)` for an answer that isn't 2xx (`ScreenControlledElsewhere` for input refused
/// because another phone holds control), `YoyoError.unauthorized` for a credential that no longer works
/// (`YoyoHost.handleError` sees every error first), else the transport's.
///
/// A backend with more than one way to the computer (a shortcut on the local network next to a relay) gives the page a
/// `YoyoRouting`; every request then names the route it goes on. A backend with one way ignores `route`.
public protocol YoyoBackend: Sendable {
    /// Whose state this is (one computer): what the kits key what they remember by (its clipboard, its platform).
    var cacheScope: String { get }
    /// What the computer most likely is before its status says (`ScreenStatus.platform`). Default nil: a Mac.
    var platformHint: YoyoPlatform? { get }
    /// The way requests go when there is no `YoyoRouting`. Default: `YoyoRoute.direct`.
    var route: YoyoRoute { get }
    /// The routing of one visit of the Screen page, for a backend with more than one way. Default nil.
    @MainActor func makeRouting() -> (any YoyoRouting)?
    /// How the kits' own sessions (the streams, the sound) check the server's certificate on `route`. Default `.system`.
    func trust(for route: YoyoRoute) -> YoyoTrust
    /// An answer that means the way to the computer is down (a proxy or relay in front of it couldn't reach it), not the
    /// computer answering: the network report counts it as a failure. Default: 502, 504, 520–527, 530.
    func isUnreachable(status: Int, message: String?) -> Bool

    /// Whether there is a screen to show, the permissions, the displays, who drives it.
    func status() async throws -> ScreenStatus
    /// The request of the video stream (multipart: H.264 / HEVC pictures, cursor and status parts, as `options` asks).
    func streamRequest(display: UInt32?, maxWidth: Int?, quality: Int?, fps: Int?, options: ScreenStreamOptions,
                       route: YoyoRoute) throws -> URLRequest
    /// The request of an ack `{stream, seq, keyframe?, report?}` (404: no such stream, stop acking).
    func ackRequest(_ ack: ScreenStreamAck, route: YoyoRoute) throws -> URLRequest
    /// The request of the sound (Opus packets as parts, the format in the `X-Audio-*` response headers; 404, 403 or 501
    /// when there is none).
    func audioRequest(route: YoyoRoute) throws -> URLRequest
    /// One input. 409 when the phone is not the controller.
    func input(_ input: ScreenInput, route: YoyoRoute) async throws
    /// When `route` is a session that carries the media itself (uu Link, `YoyoScreenLink`): the page's stream, sound,
    /// pointer and input go on it instead of through `streamRequest` / `audioRequest` / `input` (their queries are still
    /// asked for: `video.open` takes `/stream`'s). Default nil.
    func screenLink(for route: YoyoRoute) -> (any YoyoScreenLink)?
    /// Take (`.user`) or release (`.none`) the screen; the status after it.
    func setControl(_ controller: ScreenController, route: YoyoRoute) async throws -> ScreenStatus

    /// Whether the focused element takes typing (the keyboard comes up by itself). Default: 404 (never asked again).
    func focus(display: UInt32?, route: YoyoRoute) async throws -> ScreenFocus
    /// One JPEG of a display (the preview row). Default: 404.
    func frame(display: UInt32?, maxWidth: Int?, quality: Int?) async throws -> Data
    /// Shows the permission prompts on the computer, if the backend can. Default: 404.
    func requestPermissions() async throws -> ScreenStatus

    /// The computer's clipboard (`GET /clipboard`). Default: 404 (no clipboard: its keys and pages hide).
    func clipboard() async throws -> ClipboardStatus
    /// Its image item (`changeCount`'s), PNG. Default: 404.
    func clipboardImage(changeCount: Int) async throws -> Data
    /// File `index` of its files item. Default: 404.
    func clipboardFile(index: Int, changeCount: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> YoyoDownload
    /// Text onto its clipboard. Default: 404.
    func putClipboard(text: String) async throws -> ClipboardPutResponse
    /// Whether `putClipboard(files:)` works (photos and files from this phone). Default false: those entries hide.
    var sendsClipboardFiles: Bool { get }
    /// The largest file `putClipboard(files:)` takes (bytes). Default 95 MB.
    var clipboardFileLimit: Int { get }
    /// Files onto its clipboard (and into its downloads). Default: 404.
    func putClipboard(files: [YoyoUpload], progress: @escaping @Sendable (Double) -> Void) async throws -> ClipboardPutResponse

    /// The computer's events while a page shows (who controls, the displays' states, its clipboard). Each call is a new
    /// subscription, ended when the caller stops reading. Default nil: none (the pages poll).
    func events() -> AsyncStream<YoyoEvent>?
}

extension YoyoBackend {
    public var platformHint: YoyoPlatform? { nil }
    public var route: YoyoRoute { .direct }
    @MainActor public func makeRouting() -> (any YoyoRouting)? { nil }
    public func trust(for route: YoyoRoute) -> YoyoTrust { .system }
    public func isUnreachable(status: Int, message: String?) -> Bool { YoyoRoute.isUnreachable(status: status) }
    public func focus(display: UInt32?, route: YoyoRoute) async throws -> ScreenFocus { throw YoyoError.http(404, nil) }
    public func frame(display: UInt32?, maxWidth: Int?, quality: Int?) async throws -> Data { throw YoyoError.http(404, nil) }
    public func requestPermissions() async throws -> ScreenStatus { throw YoyoError.http(404, nil) }
    public func clipboard() async throws -> ClipboardStatus { throw YoyoError.http(404, nil) }
    public func clipboardImage(changeCount: Int) async throws -> Data { throw YoyoError.http(404, nil) }
    public func clipboardFile(index: Int, changeCount: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> YoyoDownload {
        throw YoyoError.http(404, nil)
    }
    public func putClipboard(text: String) async throws -> ClipboardPutResponse { throw YoyoError.http(404, nil) }
    public var sendsClipboardFiles: Bool { false }
    public var clipboardFileLimit: Int { 95_000_000 }
    public func putClipboard(files: [YoyoUpload], progress: @escaping @Sendable (Double) -> Void) async throws -> ClipboardPutResponse {
        throw YoyoError.http(404, nil)
    }
    public func events() -> AsyncStream<YoyoEvent>? { nil }
}

/// One way a backend's requests reach the computer.
public struct YoyoRoute: Sendable, Hashable {
    /// The backend's name for it (it tells its routes apart by it).
    public var id: String
    /// The computer is on this phone's local network: the playout's touch budget, its smooth buffer and the sound's
    /// jitter floor use the local network's tighter values; false keeps the ones for a path that may cross the internet.
    public var isLocalNetwork: Bool
    /// The phone reaches the computer itself (`lan` in the network report), not through a tunnel / relay (`tunnel`).
    public var isDirect: Bool
    /// A shortcut that may stop working (a direct path next to a relay): a stream on it that fails, or ends before its
    /// first picture, goes back to the routing's other way at once (`YoyoRouting.streamFailed`) instead of retrying.
    public var isShortcut: Bool
    /// For the stats line ("LAN", "direct", "tunnel"); not localized.
    public var label: String
    /// What the network report says about it (`ScreenNetReport.route`). Default: `lan` when `isDirect`, else `tunnel`.
    public var report: ScreenNetReport.Route

    public init(id: String, isLocalNetwork: Bool, isDirect: Bool = true, isShortcut: Bool = false, label: String? = nil,
                report: ScreenNetReport.Route? = nil) {
        self.id = id
        self.isLocalNetwork = isLocalNetwork
        self.isDirect = isDirect
        self.isShortcut = isShortcut
        self.label = label ?? id
        self.report = report ?? (isDirect ? .lan : .tunnel)
    }

    /// The one way of a backend without routing: straight to the computer, which may be across the internet.
    public static let direct = YoyoRoute(id: "direct", isLocalNetwork: false)

    /// The default of `YoyoBackend.isUnreachable`: a proxy couldn't reach the computer (502) or gave up waiting (504), or
    /// a CDN in front of it couldn't reach its origin (520–527, 530). A computer's own server never answers these.
    public static func isUnreachable(status: Int) -> Bool {
        switch status {
        case 502, 504, 520...527, 530: true
        default: false
        }
    }
}

/// How a session checks the server's certificate.
public enum YoyoTrust: Sendable {
    /// The system's evaluation (a server with a certificate a CA vouches for); redirects followed as usual.
    case system
    /// The server is trusted when this says so for the host it was reached at (a pinned key or certificate of a
    /// self-signed server); redirects are never followed.
    case custom(@Sendable (_ trust: SecTrust, _ host: String) -> Bool)

    /// What to answer a challenge.
    public func disposition(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard case .custom(let evaluate) = self else { return (.performDefaultHandling, nil) }
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else { return (.performDefaultHandling, nil) }
        guard let trust = space.serverTrust, evaluate(trust, space.host) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    public var followsRedirects: Bool { if case .system = self { return true } else { return false } }
}

/// A session delegate that checks the server's certificate with a `YoyoTrust` (and doesn't follow redirects when it is
/// custom): for a backend's own requests to a server the streams pin too.
public final class YoyoTrustDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    public let trust: YoyoTrust

    public init(_ trust: YoyoTrust) {
        self.trust = trust
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (d, c) = trust.disposition(challenge)
        completionHandler(d, c)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (d, c) = trust.disposition(challenge)
        completionHandler(d, c)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        trust.followsRedirects ? request : nil
    }
}

/// The ways of a backend with more than one (a shortcut that may come and go, next to one that always works), for one
/// visit of the Screen page. The page asks it which way a stream goes, moves its stream (and the sound) when the way
/// changes, and reports what happened on a way; the routing decides. Main actor.
@MainActor
public protocol YoyoRouting: AnyObject {
    /// The way requests go now.
    var current: YoyoRoute { get }
    /// A better way is being tried: a stream about to open waits up to `decisionWait` for it.
    var isDeciding: Bool { get }
    /// How long a stream about to open waits for a try on its way (then it opens on `current`, and moves when the way
    /// changes).
    var decisionWait: Duration { get }
    /// A stream on a shortcut whose response hasn't come by then counts as failed there.
    var openTimeout: Duration { get }
    /// Set by the page: call it whenever `current` or `isDeciding` changed.
    var onChange: (@MainActor () -> Void)? { get set }

    /// A new visit of the page (tries are allowed again).
    func newVisit()
    /// The page shows (it appeared, or came back from the foreground).
    func activate()
    /// A stream is about to open: a try may start now.
    func streamWillOpen()
    /// The page stopped and its last requests went out: what was found may be let go (a release of control still goes
    /// out on the way it was sent on).
    func leave()
    /// A stream on `route` failed, ended before its first picture or didn't answer within `openTimeout`; `unauthorized`:
    /// it was refused with 401. Only for a shortcut (`YoyoRoute.isShortcut`).
    func streamFailed(on route: YoyoRoute, unauthorized: Bool)
    /// An ack of a stream on `route` came back: its HTTP status, nil when it failed on the way.
    func ackAnswered(on route: YoyoRoute, status: Int?)
    /// A request on `route` failed with `error`: the way to send the same request on now, or nil to give up (an answer
    /// the other way would give too, a way without another).
    func fallback(from route: YoyoRoute, after error: Error) async -> YoyoRoute?
}

/// What `clipboardFile` downloads.
public struct YoyoDownload: Sendable {
    public var data: Data
    /// The file's name as the server gave it.
    public var name: String?
    public var mime: String?

    public init(data: Data, name: String? = nil, mime: String? = nil) {
        self.data = data
        self.name = name
        self.mime = mime
    }
}

/// A file going to the computer's clipboard: its bytes in memory or in a file this phone owns.
public struct YoyoUpload: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case data(Data)
        /// A file to read the bytes from (a temporary copy the kit made, or the host's).
        case file(URL)
    }

    public var source: Source
    public var filename: String
    public var mime: String
    /// Bytes.
    public var size: Int

    public init(data: Data, filename: String, mime: String) {
        source = .data(data)
        self.filename = filename
        self.mime = mime
        size = data.count
    }

    public init(file: URL, filename: String? = nil, mime: String, size: Int) {
        source = .file(file)
        self.filename = filename ?? file.lastPathComponent
        self.mime = mime
        self.size = size
    }

    /// The bytes (read from the file for `.file`).
    public func data() throws -> Data {
        switch source {
        case .data(let d): d
        case .file(let url): try Data(contentsOf: url, options: .mappedIfSafe)
        }
    }
}
