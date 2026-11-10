#if os(macOS)
import CoreGraphics
import Foundation

// Status parts of a `/stream?status=1` (docs/PROTOCOL.md 「屏幕」「连接状态」): status JSON parts (`StreamWire.status`)
// (a ScreenDisplayState of the stream's display, plus `console`) in the same multipart body as the pictures. Part
// headers: Content-Type, Content-Length, X-Frame-Seq (one number of the stream's sequence, like a cursor part; never
// in the ack window) and X-Frame-Kind: status. Without `status=1` nothing here runs and a stream is byte-identical to
// before.
//
// - The first part right after the response head; then one whenever the state changes (checked on every turn of the
//   stream loop, `Connection.betweenParts`).
// - A stream reports the ScreenCaptureKit path (ready while it can capture); an unavailable state ends it cleanly
//   after its part.

extension Router {
    /// The `status` query: "1" / "true" → status parts; absent / "" / "0" / "false" → none. Else 400.
    static func statusRequested(_ req: HTTPRequest) throws -> Bool {
        switch req.query["status"] ?? "" {
        case "", "0", "false": return false
        case "1", "true": return true
        default: throw HTTPError(400, "status must be 1")
        }
    }

    /// The bytes of one status part.
    static func statusPart(_ state: ScreenDisplayState, console: ConsoleState?, seq: UInt64, wire: StreamWire = .current) -> Data {
        var body = state.json
        body["console"] = console?.json ?? NSNull()
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        return streamPart(contentType: wire.status, body: json, size: nil, seq: seq, publishedAt: nil,
                          kind: "status", codec: nil, boundary: wire.boundary)
    }

    /// The status feed of a `status=1` request (nil without it, or without a state tracker).
    static func statusFeed(_ req: HTTPRequest, display: CGDirectDisplayID) throws -> StreamStatusFeed? {
        guard try statusRequested(req), let tracker = ScreenStateTracker.current else { return nil }
        return StreamStatusFeed(tracker: tracker, display: display)
    }

    /// Install `feed` on `conn` and write the first status part. false = end (client gone / unavailable).
    static func startStatus(_ feed: StreamStatusFeed, _ conn: Connection) -> Bool {
        conn.betweenParts = { feed.pump($0) }
        return feed.start(conn)
    }
}

/// The status parts of one `status=1` stream. Used on the stream's handler thread only.
final class StreamStatusFeed {
    let tracker: ScreenStateTracker
    /// The stream's display (`X-Display`): every part names it, whatever id the entry has.
    let display: CGDirectDisplayID
    private var sent: ScreenDisplayState?
    private var seen: UInt64?

    init(tracker: ScreenStateTracker, display: CGDirectDisplayID) {
        self.tracker = tracker
        self.display = display
    }

    /// The state this stream reports now: the ScreenCaptureKit path's.
    func current() -> (state: ScreenDisplayState, console: ConsoleState?) {
        var out = tracker.captureState()
        // the entry's own id is the main display's (also for a stream of another display)
        out.state.main = out.state.display == display
        out.state.display = display
        return out
    }

    /// The first part: the state as of now.
    func start(_ conn: Connection) -> Bool {
        tracker.refresh()
        return pump(conn)
    }

    /// Between two parts: a status part when the state changed. false = end the response (the client is gone, or the
    /// display is unavailable — its part written).
    func pump(_ conn: Connection) -> Bool {
        pump { self.write(conn, $0, $1) }
    }

    /// `pump` with any writer (the link's `video.status` messages): `send` false = end.
    func pump(send: (ScreenDisplayState, ConsoleState?) -> Bool) -> Bool {
        let version = tracker.version
        if version != seen {
            seen = version
            let (state, console) = current()
            if state != sent {
                sent = state
                if !send(state, console) { return false }
            }
            if state.phase == .unavailable {
                log("stream of display \(display): \(state.reason?.rawValue ?? "unavailable"); ending it (status part sent)")
                return false
            }
        }
        return true
    }

    private func write(_ conn: Connection, _ state: ScreenDisplayState, _ console: ConsoleState?) -> Bool {
        sent = state
        return conn.write(Router.statusPart(state, console: console, seq: conn.nextPartSeq(), wire: conn.wire))
    }
}
#endif
