#if os(macOS)
import Foundation

/// The media types and boundary of `/stream` and `/audio` (README.md「HTTP API」), whatever the request's `Accept`
/// says. Every part carries a `Content-Length`; the boundary only delimits.
struct StreamWire: Equatable, Sendable {
    let boundary: String
    /// The response's `Content-Type` (`/stream`): never `multipart/*` (Router.streamContentType says why).
    let stream: String
    /// The response's `Content-Type` (`/audio`).
    let audio: String
    /// A cursor part's `Content-Type` (`cursor=client`).
    let cursor: String
    /// A status part's `Content-Type` (`status=1`).
    let status: String

    static let streamType = "application/vnd.yoyo-control.stream"
    static let audioType = "application/vnd.yoyo-control.audio"

    static let current = StreamWire(
        boundary: "frame",
        stream: "\(streamType); boundary=frame",
        audio: "\(audioType); boundary=frame",
        cursor: "application/vnd.yoyo-control.cursor+json",
        status: "application/vnd.yoyo-control.status+json")
}
#endif
