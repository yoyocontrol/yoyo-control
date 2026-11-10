import Foundation

/// A way to the computer that carries the Screen page's media itself (uu Link, docs/LINK.md): the pictures, the sound,
/// the pointer and input go over it as datagrams and control messages, not as `/stream`, `/audio` and `/input`
/// requests. A backend whose route is such a session hands it to the page (`YoyoBackend.screenLink(for:)`); the kits
/// don't know what is underneath (YoyoLinkClient's `YoyoLinkConnection` is the one over the Rust core). Thread-safe;
/// the handlers run on any thread, in order for one stream.
public protocol YoyoScreenLink: AnyObject, Sendable {
    /// For the stats line: `link lan`, `link direct`, `link punched`, `link relay` (not localized).
    var pathLabel: String { get }
    /// The path in use is on the phone's local network now (the playout's and the sound's tighter local values).
    var isLocalNetwork: Bool { get }
    /// The path's smallest round trip of the last seconds (ms; nil: not measured yet): the touch budget's source.
    var rttMinMs: Double? { get }
    /// The link's own numbers for the stats line, in place of the server's network grade (the `link:` line's body:
    /// `lan wifi rtt 0.4/1.2/2.0 ms loss 0.0 % …`; not localized). nil: none.
    var statsLine: String? { get }

    /// Opens a video stream (`video.open`): `query` is exactly the query `/stream` would get. Its events go to `onEvent`
    /// until it is closed (by `close()`, the server, or the session's end: `.closed`).
    func openVideo(query: String, onEvent: @escaping @Sendable (YoyoLinkVideoEvent) -> Void) -> any YoyoLinkVideo
    /// Opens the sound (`audio.open`), `query` as `/audio` would get it.
    func openAudio(query: String, onEvent: @escaping @Sendable (YoyoLinkAudioEvent) -> Void) -> any YoyoLinkAudio
    /// One input, `/input`'s JSON body, sent at once (the link orders and repeats it; nothing waits for an answer).
    /// `move`: a pointer move (the newest wins), else a discrete event (exactly once, in order). Throws
    /// `YoyoError.http(429, _)` when too many discrete events wait for their ack, or the session's error once it ended.
    func sendInput(_ json: Data, move: Bool) throws
    /// Where input the computer refused (`input.rejected`: 409 not in control, `ScreenControlledElsewhere`, 400…) and
    /// input never acknowledged (a network failure) are reported. One handler; nil removes it.
    func setInputErrorHandler(_ handler: (@Sendable (Error) -> Void)?)
}

/// What a link's video stream delivers.
public enum YoyoLinkVideoEvent: Sendable {
    /// `video.opened`: its codec and size, and what `/stream`'s response headers would have said (`X-Display`…).
    case opened(codec: String?, width: Int?, height: Int?, headers: [String: String])
    /// A picture for the decoder: in order, its reference chain intact (answer with `YoyoLinkVideo.decoded`).
    case frame(YoyoLinkFrame)
    /// `video.status`: a status part's JSON (`ScreenStreamStatus`).
    case status(Data)
    /// A cursor part's JSON (`ScreenCursorUpdate`): a position from the datagrams, or a shape (`cursor.shape`).
    case cursor(Data)
    /// `video.error`: what the HTTP stream would have answered (401: the credential is no longer known).
    case error(status: Int, message: String?)
    /// The computer ended the stream (`video.closed`). Nothing comes after it.
    case closed(reason: String?)
    /// The session under it ended or failed (`reason` says how). Nothing comes after it.
    case failed(reason: String)
}

/// One picture of a link's video stream.
public struct YoyoLinkFrame: Sendable, Equatable {
    /// The stream's frame number (from 1).
    public var number: UInt32
    /// `h264` / `hevc`.
    public var codec: String
    /// `key` / `delta` / `refine` / `keepalive` / `recovery` (a delta on an acknowledged long-term reference).
    public var kind: String
    public var width: Int
    public var height: Int
    /// When the computer captured it: ms since 1970 (its clock; nil: not said).
    public var captureMs: Double?
    /// One Annex-B access unit.
    public var au: Data

    public init(number: UInt32, codec: String, kind: String, width: Int, height: Int, captureMs: Double?, au: Data) {
        self.number = number; self.codec = codec; self.kind = kind; self.width = width; self.height = height
        self.captureMs = captureMs; self.au = au
    }
}

/// An open video stream of a link.
public protocol YoyoLinkVideo: AnyObject, Sendable {
    /// The decoder took (`ok`) or failed on `frame`: what the computer's encoder references next (and a key picture
    /// after a failure).
    func decoded(frame: UInt32, ok: Bool)
    /// The decoder can't go on: a key picture.
    func requestKeyframe()
    /// The playout report (`ScreenPlayoutReport.json`, what rode the HTTP stream's acks), as JSON.
    func report(_ json: Data)
    func close()
}

/// What a link's sound delivers.
public enum YoyoLinkAudioEvent: Sendable {
    /// `audio.opened`: its format by the names of `/audio`'s response headers (`X-Audio-Codec`, `X-Audio-Rate`,
    /// `X-Audio-Channels`, `X-Audio-Frames`, `X-Audio-Cookie`, `X-Audio-Video-Offset`).
    case opened(format: [String: String])
    /// One Opus packet: its sequence number (+1 a packet; a gap is a lost one) and the time of its first sample (ms since
    /// 1970, the computer's clock as the pictures' `captureMs`).
    case packet(seq: Int, timeMs: Double, data: Data)
    /// `/audio`'s answer (404 / 403 / 501: none; 503: not now).
    case error(status: Int, message: String?)
    /// The computer ended it (`audio.closed`).
    case closed(reason: String?)
    /// The session under it ended or failed.
    case failed(reason: String)
}

/// An open sound stream of a link.
public protocol YoyoLinkAudio: AnyObject, Sendable {
    func close()
}

extension YoyoScreenLink {
    public var statsLine: String? { nil }
}

extension YoyoBackend {
    public func screenLink(for route: YoyoRoute) -> (any YoyoScreenLink)? { nil }
}
