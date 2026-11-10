#if os(macOS)
import CoreVideo
import Foundation

// The video stream loop (docs/PROTOCOL.md 「屏幕」「视频流、确认与客户端指针」) over a `VideoPictureSource`: a real
// display's ScreenCaptureKit capture (`FrameStream`, Capture.swift).
//
// Multipart parts (`--frame`: StreamWire.swift): one H.264 / HEVC access unit per picture
// part (`video/h264|hevc`, Annex-B; kinds key / delta / refine / keepalive) and, with `cursor=client`, small cursor JSON
// parts (one before
// the first picture, then on every change, coalesced, outside the ack window). With acks (`POST /stream/ack`) at most
// W pictures are in flight: while the window is full nothing is encoded, and when it opens the NEWEST picture is (a
// delta against the last ENCODED picture — the coded stream never skips; intermediate states just collapse). The
// queueing delay steers the bit rate (and, for a source with `widths`, the resolution): StreamFlow.swift. A change is
// encoded at most every `interval` (counted from the START of the previous picture's work); an unchanged picture gets
// sharper re-encodes until it is as sharp as the rate makes it (`RefineSchedule`) and a keepalive every `keepalive`.

/// One picture for the encoder.
struct VideoSourceFrame {
    let buffer: CVPixelBuffer
    /// What it shows.
    let id: VideoPictureID
    /// When its content was published (ms since 1970), for `X-Frame-Time`; nil: too old to be remembered.
    let publishedAt: Double?
}

/// What a picture shows: the source's frame, an overlay drawn onto it, at a width. A newer picture,
/// or the same content at another width, has a different id.
struct VideoPictureID: Equatable, Sendable {
    var frame: UInt64
    var overlay: UInt64 = 0
    var width: Int = 0
}

/// Where a video stream gets its pictures.
protocol VideoPictureSource: AnyObject {
    /// Read at the top of every pass, before looking for work: `waitForFrame(after:)` with it returns as soon as
    /// anything changed since (a new picture, a pointer change, `wake()`), so a change in between is never lost.
    var changeToken: UInt64 { get }
    /// Block until something changed since `token`, or `deadline`. false = the source stopped (the stream ends).
    func waitForFrame(after token: UInt64, until deadline: Date) -> Bool
    /// End a wait early (an ack may have opened the window, the pointer moved).
    func wake()
    /// What the newest picture would show, without producing it; nil: none yet.
    func newestID() -> VideoPictureID?
    /// The newest picture; a source that copies its pixels takes the buffer from `make(width, height)` (the encoder's
    /// pool). nil: not available right now (its wake-up retries).
    func latest(make: (Int, Int) -> CVPixelBuffer?) -> VideoSourceFrame?
    /// The picture width the stream is at (stats); nil: the last encoded picture's.
    var width: Int? { get }
    /// Resolution steps, best first; empty: the size is fixed for the stream (congestion only lowers the bit rate).
    var widths: [Int] { get }
    /// Go to one of `widths` (the next picture is a key frame at the new size).
    func resize(width: Int)
    /// `cursor=client`: the pointer, sent as cursor parts (the pictures leave it out). nil: baked in, no parts.
    var cursorFeed: DisplayCursorFeed? { get }
    /// The capture's callbacks since the last call (ScreenCaptureKit), for the periodic stats line. nil: none.
    func captureWindow() -> CaptureActivityWindow?
}

extension VideoPictureSource {
    var width: Int? { nil }
    var widths: [Int] { [] }
    func resize(width: Int) {}
    var cursorFeed: DisplayCursorFeed? { nil }
    func captureWindow() -> CaptureActivityWindow? { nil }
}

struct VideoStreamOptions {
    var codec: VideoCodec
    /// The stream's log prefix (`video: display stream <id>`).
    var label: String
    var streamID: String?
    /// Minimum interval between live pictures (1 / fps).
    var interval: TimeInterval = 1.0 / 30
    var tuning = StreamTuning.default
    /// A stats line (capture callbacks, pictures sent, encode, flow) this often, also handed to `onStats`; nil: none.
    var statsInterval: TimeInterval?
    /// The latest stats (tests).
    var onStats: (([String: Any]) -> Void)?
    /// Long-term reference pictures in the encoder (a link sink's recovery frames, `VideoStreamPacing`).
    var ltr = false
    /// A link session's trace: one `enc` record per encoded picture, `drop` per one the encoder dropped; nil: none.
    var trace: ((_ type: String, _ fields: [String: Any]) -> Void)?

    init(codec: VideoCodec, label: String = "video: stream") {
        self.codec = codec
        self.label = label
    }
}

/// One stats window of a video stream: what was sent and how long encodes took.
struct VideoStreamWindow {
    var live = 0
    var refines = 0
    var keepalives = 0
    var keys = 0
    var drops = 0
    var encodeMs: [Double] = []
    /// Cursor parts sent (`cursor=client`); nil: not a cursor=client stream.
    var cursorParts: Int?
    /// A paced (link) stream: captured pictures never encoded because a newer one came first, while the link's queue
    /// held pictures back (`held`) or while the loop was busy encoding / waiting for the fps cap (`busy`); and how long
    /// the queue held them back (ms). nil: not a paced stream.
    var missed: (held: Int, busy: Int, heldMs: Double)?
    /// Encoded picture sizes (bytes), for a paced stream's line.
    var bytes: [Int] = []

    /// "sent 33.0 pics/s (live 330 refine 1 keepalive 0 key 1 dropped 0); encode 7.5/12.0 ms (mean/max)"
    /// (paced: "; missed held 40 busy 3, held 812 ms; size p50/90/max 31/52/120 KB")
    func line(seconds: TimeInterval) -> String {
        let pics = Double(live + refines + keepalives) / max(seconds, 0.001)
        let mean = encodeMs.isEmpty ? 0 : encodeMs.reduce(0, +) / Double(encodeMs.count)
        var s = String(format: "sent %.1f pics/s (live %d refine %d keepalive %d key %d dropped %d); encode %.1f/%.1f ms (mean/max)",
                       pics, live, refines, keepalives, keys, drops, mean, encodeMs.max() ?? 0)
            + (cursorParts.map { "; cursor parts \($0)" } ?? "")
        if let m = missed {
            s += String(format: "; missed held %d busy %d, held %.0f ms", m.held, m.busy, m.heldMs)
            if !bytes.isEmpty {
                let sorted = bytes.sorted()
                func kb(_ q: Double) -> Double { Double(sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))]) / 1000 }
                s += String(format: "; size p50/90/max %.0f/%.0f/%.0f KB", kb(0.5), kb(0.9), Double(sorted.last!) / 1000)
            }
        }
        return s
    }

    func json(seconds: TimeInterval) -> [String: Any] {
        let mean = encodeMs.isEmpty ? 0 : encodeMs.reduce(0, +) / Double(encodeMs.count)
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        var out: [String: Any] = ["picsPerSecond": r(Double(live + refines + keepalives) / max(seconds, 0.001)), "live": live,
                                  "refines": refines, "keepalives": keepalives, "keys": keys, "drops": drops,
                                  "encodeMeanMs": r(mean), "encodeMaxMs": r(encodeMs.max() ?? 0)]
        if let cursorParts { out["cursorParts"] = cursorParts }
        return out
    }
}

/// When to send the sharper "refine" re-encodes of an unchanged picture, and when to stop (StreamTuning「refine」):
/// the first `idle` after its live part went out, then every `every` while the content stays the same, until
/// `smallInARow` refines in a row came out no bigger than one live picture's budget (one small refine alone is no
/// proof: right after a scroll the encoder's budget may be spent), or after `limit`. A refine the encoder skipped
/// counts toward `limit` but is not small: it is the rate control over budget, not a settled picture (VideoToolbox
/// drops pictures for about a second after a scroll at 300 kbit/s, while the picture is still blurry). Any new content
/// re-arms it, which also cancels a refine that was not yet due.
struct RefineSchedule: Sendable {
    let idle: TimeInterval
    let every: TimeInterval
    let limit: Int
    let smallInARow: Int
    /// When the next refine is due; nil: nothing to refine (done / nothing sent).
    private(set) var dueAt: TimeInterval?
    /// Refines since the last live part, and how many of the latest in a row were small.
    private(set) var sent = 0
    private(set) var smallRun = 0

    init(idle: TimeInterval, every: TimeInterval, limit: Int, smallInARow: Int) {
        self.idle = idle
        self.every = every
        self.limit = limit
        self.smallInARow = smallInARow
    }

    init(_ t: StreamTuning) {
        self.init(idle: t.refineIdle, every: t.refineEvery, limit: t.videoRefines, smallInARow: t.refineSmallInARow)
    }

    /// One live picture's share of the target rate (bytes): bits/s / 8 / fps.
    static func liveBudget(bitsPerSecond: Int, fps: Double) -> Double { Double(bitsPerSecond) / 8 / max(fps, 1) }

    /// A live (changed-content) part went out at `time`: refines again from the start.
    mutating func noteLive(at time: TimeInterval) {
        sent = 0
        smallRun = 0
        dueAt = limit > 0 ? time + idle : nil
    }

    func isDue(at now: TimeInterval) -> Bool { dueAt.map { now >= $0 } ?? false }

    /// A refine went out at `time` with `bytes` (nil: the encoder skipped it); `budget`: one live picture's bytes.
    mutating func noteRefined(at time: TimeInterval, bytes: Int?, budget: Double) {
        sent += 1
        if let bytes, Double(bytes) <= budget { smallRun += 1 } else { smallRun = 0 }
        dueAt = sent >= limit || smallRun >= smallInARow ? nil : time + every
    }

    /// No refine until the next live part (the picture can't be had now).
    mutating func cancel() { dueAt = nil }
}

/// What a picture is on the wire (`X-Frame-Kind` / the link's frame meta).
enum VideoPictureKind: String {
    case key, delta, refine, keepalive
}

/// Where a video stream's pictures and pointer go: an HTTP response (`HTTPVideoSink`, multipart parts, the ack
/// window of StreamFlow) or a link session (LinkVideo.swift: datagrams, its own pacing). The loop's cadence (changes,
/// refines, keepalives, the cursor's coalescing) is the same for both.
protocol VideoStreamSink: AnyObject {
    /// The client is gone or the stream was closed: the loop ends.
    func isClosed() -> Bool
    /// The pointer; `newShape`: its image, when this stream hasn't sent that one yet. The bytes sent, nil = gone.
    func sendCursor(_ c: ClientCursor, newShape: ClientCursorShape?) -> Int?
    /// One encoded picture. nil = gone.
    func sendPicture(_ unit: VideoAccessUnit, kind: VideoPictureKind, publishedAt: Double?) -> VideoSinkSent?
    /// The sink's own pacing instead of the ack window (a link session); nil: StreamFlow, for a stream with an id.
    var pacing: VideoStreamPacing? { get }
}

/// One picture handed to a sink: its part / frame number and size.
struct VideoSinkSent {
    var seq: UInt64
    var bytes: Int
}

/// A sink that paces the stream itself (the link: `can_send_frame` and the rate controller's target replace the ack
/// window and the bit-rate steps; recovery frames on long-term references). Called on the stream's thread.
protocol VideoStreamPacing: AnyObject {
    /// The encoder's bit rate (bits/s) when it changed since the last call.
    func takeBitrate() -> Int?
    /// Whether a picture may be encoded now (false: skip it; the newest picture goes once it may).
    func canSend() -> Bool
    /// The next picture must be a key or a recovery frame (it is encoded even when the picture is unchanged).
    func refreshDue(at now: TimeInterval) -> Bool
    /// The options of the picture about to be encoded, and whether it must be a key frame.
    func encodeOptions(at now: TimeInterval) -> (forceKey: Bool, options: VideoEncodeOptions)
    /// More for the stream's stats line (the rate controller's target, the phone's report).
    func statsTail() -> String?
    /// The numbers behind the last `canSend() == false` since the last call (the trace); nil: none.
    func takeClosedGate() -> [String: Any]?
}

extension VideoStreamPacing {
    func takeClosedGate() -> [String: Any]? { nil }
}

/// Today's sink: multipart parts on an HTTP response.
final class HTTPVideoSink: VideoStreamSink {
    let conn: Connection
    let codec: VideoCodec

    init(_ conn: Connection, codec: VideoCodec) {
        self.conn = conn
        self.codec = codec
    }

    func isClosed() -> Bool { conn.peerClosed() }
    var pacing: VideoStreamPacing? { nil }

    func sendCursor(_ c: ClientCursor, newShape: ClientCursorShape?) -> Int? {
        let body = StreamCursorPart.body(c, shape: newShape)
        guard Router.writeStreamPart(conn, contentType: conn.wire.cursor, body: body, size: nil, seq: conn.nextPartSeq(),
                                     publishedAt: Date().timeIntervalSince1970 * 1000, kind: "cursor", codec: nil) else { return nil }
        return body.count
    }

    func sendPicture(_ unit: VideoAccessUnit, kind: VideoPictureKind, publishedAt: Double?) -> VideoSinkSent? {
        let seq = conn.nextPartSeq()
        let part = Router.streamPart(contentType: codec.contentType, body: unit.data, size: (unit.width, unit.height),
                                     seq: seq, publishedAt: publishedAt, kind: kind.rawValue, codec: codec.rawValue,
                                     boundary: conn.wire.boundary)
        guard conn.write(part) else { return nil }
        return VideoSinkSent(seq: seq, bytes: part.count)
    }
}

extension Router {
    /// The `Content-Type` of every stream (video or not, the same multipart bytes), NOT `multipart/x-mixed-replace`:
    /// URLSession (iOS/macOS, seen over HTTP/3) splits that type itself — one `didReceive response` per part with the
    /// boundaries stripped — and the iOS ScreenStream, which parses the raw bytes, treats the second response as a
    /// failure. Its parser only needs the `boundary` parameter. The type itself is negotiated (`StreamWire.stream`).

    /// Write one part (any type), numbered and stamped. false = client gone.
    static func writeStreamPart(_ conn: Connection, contentType: String, body: Data, size: (Int, Int)?, seq: UInt64,
                                publishedAt: Double?, kind: String, codec: String?) -> Bool {
        conn.write(streamPart(contentType: contentType, body: body, size: size, seq: seq, publishedAt: publishedAt,
                              kind: kind, codec: codec, boundary: conn.wire.boundary))
    }

    /// The bytes of one part: `--<boundary>`, the headers, the body, CRLF.
    static func streamPart(contentType: String, body: Data, size: (Int, Int)?, seq: UInt64, publishedAt: Double?,
                           kind: String, codec: String?, boundary: String = StreamWire.current.boundary) -> Data {
        var head = "--\(boundary)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        if let (w, h) = size { head += "X-Frame-Width: \(w)\r\nX-Frame-Height: \(h)\r\n" }
        head += "X-Frame-Seq: \(seq)\r\n"
        if let publishedAt { head += "X-Frame-Time: \(Int64(publishedAt.rounded()))\r\n" }
        head += "X-Frame-Kind: \(kind)\r\n"
        if let codec { head += "X-Stream-Codec: \(codec)\r\n" }
        head += "\r\n"
        var part = Data(head.utf8)
        part.reserveCapacity(part.count + body.count + 2)
        part.append(body)
        part.append(contentsOf: [13, 10])
        return part
    }

    /// Send `source`'s pictures as video parts until the client hangs up, the source stops, or the encoder fails
    /// `maxEncodeFailures` times in a row (the client reopens).
    static func videoStreamLoop(_ source: VideoPictureSource, _ conn: Connection, _ o: VideoStreamOptions) {
        videoStreamLoop(source, sink: HTTPVideoSink(conn, codec: o.codec), o)
    }

    /// The loop over any sink (an HTTP response's, a link session's).
    static func videoStreamLoop(_ source: VideoPictureSource, sink: VideoStreamSink, _ o: VideoStreamOptions) {
        let clock = StreamClock.now
        let t = o.tuning
        let encoder = VideoEncoder(codec: o.codec, bitrate: t.startKbps * 1000, expectedFrameRate: Int((1 / o.interval).rounded()),
                                   ltr: o.ltr)
        let codecName = o.codec.rawValue
        let label = o.label
        let feed = source.cursorFeed
        let pacing = sink.pacing
        let flow = pacing != nil ? nil : o.streamID.map { id in
            StreamFlow(id: id, label: label,
                       controller: StreamFlowController(tuning: t, widths: source.widths, frameInterval: o.interval),
                       wake: { [weak source] in source?.wake() })
        }
        if let flow { StreamFlowRegistry.register(flow) }
        defer {
            if let flow {
                StreamFlowRegistry.unregister(flow)
                flow.finish()
            }
        }

        var seq: UInt64 = 0
        /// What the last picture showed.
        var shown: VideoPictureID?
        var lastPictureAt = -Double.infinity
        /// When the last picture's work (copy + encode) began: the fps cap counts from there. (Counting from its send
        /// capped a 30 fps stream with a 15 ms encode at ~21 pictures/s, and a frame arriving in that gap waited.)
        var lastPictureStart = -Double.infinity
        var refine = RefineSchedule(t)
        var needKey = true
        var failures = 0
        var meter = StreamRateMeter()
        var keyFrames = 0
        var lastKeyBytes: Int?
        var encodeEWMA: Double?
        /// The newest picture the window last held back (counted once).
        var limitedID: VideoPictureID?
        func newWindow() -> VideoStreamWindow {
            var w = VideoStreamWindow(cursorParts: feed != nil ? 0 : nil)
            if pacing != nil { w.missed = (0, 0, 0) }
            return w
        }
        var window = newWindow()
        var windowStart = clock()
        // A paced stream's missed pictures: the capture number of the last encoded picture, and since then how often
        // and how long the link's queue held pictures back, the fps cap's sleeps, the gate's numbers.
        var encodedSeq: UInt64?
        var heldChecks = 0
        var heldSince: TimeInterval?
        var heldMs = 0.0
        var capSleepMs = 0.0
        var heldGate: [String: Any]?
        var latestWidth = 0
        _ = source.captureWindow()  // the first window starts with the stream
        // cursor=client: what the last cursor part said, the shapes this stream sent, when.
        var sentCursor: ClientCursor?
        var sentShapes = Set<Int>()
        var lastCursorAt = -Double.infinity
        var cursorParts = 0
        feed?.observe { [weak source] in source?.wake() }

        func summary(_ now: TimeInterval) -> StreamFlowSummary {
            let rate = meter.rate(at: now)
            var s = StreamFlowSummary(id: o.streamID, codec: codecName, cursorClient: feed != nil)
            s.window = t.videoWindow
            s.bitrateKbps = encoder.bitrate / 1000
            s.width = source.width ?? latestWidth
            s.keyFrames = keyFrames
            s.bytesPerSecond = rate.bytesPerSecond
            s.partsPerSecond = rate.partsPerSecond
            s.encodeMs = encodeEWMA
            s.lastKeyBytes = lastKeyBytes
            s.drops = encoder.drops
            s.cursorParts = cursorParts
            if let flow {
                flow.with { s.adapt(from: $0) }
                s.phone = flow.playoutReport
                s.net = flow.lastNetQuality
                s.netClient = flow.clientNetReport
            }
            return s
        }

        /// Every `statsInterval`: one line (capture callbacks, pictures, encode, flow), and `onStats`.
        func statsIfDue(_ now: TimeInterval) {
            guard let every = o.statsInterval else { return }
            let seconds = now - windowStart
            guard seconds >= every else { return }
            let capture = source.captureWindow()
            let s = summary(now)
            let tail = flow?.takePhoneTail() ?? pacing?.statsTail()
            log("\(label) stats: last \(String(format: "%.1f", seconds)) s \(capture.map { "capture \($0.line); " } ?? "")"
                + "\(window.line(seconds: seconds)); flow \(s.line)" + (tail.map { "; \($0)" } ?? ""))
            if let onStats = o.onStats {
                var body: [String: Any] = ["seconds": (seconds * 10).rounded() / 10, "sent": window.json(seconds: seconds),
                                           "flow": s.json]
                if let capture { body["capture"] = capture.json }
                onStats(body)
            }
            window = newWindow()
            windowStart = now
        }

        /// Apply what acks asked for.
        func apply(_ actions: [StreamFlowAction]) {
            for a in actions {
                switch a {
                case let .bitrate(kbps):
                    encoder.setBitrate(kbps * 1000)
                case let .resolution(i):
                    let widths = source.widths
                    guard !widths.isEmpty else { continue }
                    let w = widths[min(max(i, 0), widths.count - 1)]
                    log("\(label) \(codecName) resolution → \(w)px (queue delay)")
                    source.resize(width: w)  // the encoder's session follows the picture size: a key frame
                }
            }
        }

        /// One cursor part; its shape when this stream hasn't sent that one yet. false = client gone.
        func sendCursor(_ c: ClientCursor, shape: ClientCursorShape?, at now: TimeInterval) -> Bool {
            let withShape = shape.flatMap { sentShapes.contains($0.id) ? nil : $0 }
            guard let bytes = sink.sendCursor(c, newShape: withShape) else { return false }
            if let withShape {
                if sentShapes.count >= ScreenCursorShapes.maxRemembered { sentShapes.removeAll() }
                sentShapes.insert(withShape.id)
            }
            sentCursor = c
            lastCursorAt = now
            meter.add(bytes, at: now)
            cursorParts += 1
            window.cursorParts? += 1
            return true
        }

        enum Want { case live, refine, keepalive }

        while !sink.isClosed() {
            let token = source.changeToken  // before looking for work: a change in between ends the wait below
            var now = clock()
            statsIfDue(now)
            var deadline = now + t.idleCheck
            /// While the window is full, no picture can go out before an ack (a wake-up) or the probe time.
            var blockedUntil: TimeInterval?
            if let bps = pacing?.takeBitrate() { encoder.setBitrate(bps) }
            if let flow {
                apply(flow.takeActions())
                if flow.with({ $0.checkStall(at: now) }) {
                    log("\(label): no ack for \(Int(t.disableAfter)) s; flow-control window off for this stream")
                }
            }

            // 1. The pointer (cursor=client): before the first picture, then on changes, coalesced; never held by the window.
            if let feed {
                let (c, shape) = feed.current()
                let newShape = shape.map { !sentShapes.contains($0.id) } ?? false
                if c != sentCursor || newShape {
                    if now - lastCursorAt >= t.cursorMinInterval {
                        guard sendCursor(c, shape: shape, at: now) else { return }
                    } else {
                        deadline = min(deadline, lastCursorAt + t.cursorMinInterval)
                    }
                }
            }

            // 2. Pictures: a change (or a key frame due), else a refine, else a keepalive.
            let newest = source.newestID()
            let wantKey = needKey || (flow?.with { $0.keyDue(at: now) } ?? false) || (pacing?.refreshDue(at: now) ?? false)
            var want: Want?
            if newest != nil, newest != shown || (wantKey && shown != nil) {
                want = .live
            } else if refine.isDue(at: now) {
                want = .refine
            } else if shown != nil, now - lastPictureAt >= t.keepalive {
                want = .keepalive
            }

            if let wanted = want {
                // fps cap for live pictures (a strict timer: plain sleeps oversleep ~20 ms here)
                let gap = o.interval - (now - lastPictureStart)
                if wanted == .live, gap > 0 {
                    let nap = min(gap, max(0.001, deadline - now))
                    StrictTiming.sleep(nap)
                    capSleepMs += nap * 1000
                    continue
                }
                var gate = StreamFlowGate.open
                if let flow {
                    gate = flow.with { c -> StreamFlowGate in
                        let g = c.gate(at: now)
                        if case .full = g, limitedID != newest { c.noteWindowLimited(at: now) }
                        if case .probe = g { c.noteProbe() }
                        return g
                    }
                }
                if let pacing, !pacing.canSend() {
                    // the link's queue is full: no picture now; the newest one once it drained (looked at every 4 ms)
                    let until = now + 0.004
                    blockedUntil = until
                    deadline = min(deadline, until)
                    heldChecks += 1
                    if heldSince == nil { heldSince = now }
                    if let g = pacing.takeClosedGate(), heldGate == nil { heldGate = g }
                } else if case let .full(until) = gate {
                    limitedID = newest
                    blockedUntil = until
                    deadline = min(deadline, until)
                } else {
                    // A refine goes out at a temporarily higher rate, unless the path is queueing; never above the
                    // network profile's ceiling (a cellular / constrained path gets no 4 Mbps bursts above it). A link
                    // sink (its queue is open, or we would not be here): the refines together stay within the rate
                    // its media layer set (`StreamTuning.refineBitrate`).
                    let congested = flow?.with { $0.queueDelayMin.map { $0 > t.congestedDelay } } ?? false
                    let normal = encoder.bitrate
                    let ceiling = flow?.with { $0.maxKbpsNow } ?? t.maxKbps
                    let refineBitrate = t.refineBitrate(normal: normal, ceiling: ceiling * 1000, congested: congested,
                                                        linkFPS: pacing != nil ? 1 / o.interval : nil)
                    let boost = wanted == .refine && refineBitrate != normal
                    /// One live picture's bytes at the stream's own rate: what a refine has to stay under to count as small.
                    let budget = RefineSchedule.liveBudget(bitsPerSecond: normal, fps: 1 / o.interval)
                    if boost { encoder.setBitrate(refineBitrate) }
                    let encodeStart = clock()
                    let encodeStartWall = o.trace != nil ? Date().timeIntervalSince1970 * 1000 : 0
                    let previousStart = lastPictureStart
                    if let since = heldSince {
                        heldMs += (encodeStart - since) * 1000
                        heldSince = nil
                    }
                    var frame: VideoSourceFrame?
                    var result: VideoEncodeResult?
                    if let f = source.latest(make: { encoder.makeInputBuffer(width: $0, height: $1) }) {
                        frame = f
                        if let pacing {
                            let (key, options) = pacing.encodeOptions(at: encodeStart)
                            result = encoder.encodeFrame(f.buffer, time: encodeStart, forceKey: needKey || key, options: options)
                        } else {
                            result = encoder.encodeFrame(f.buffer, time: encodeStart, forceKey: wantKey)
                        }
                    }
                    if boost { encoder.setBitrate(normal) }
                    now = clock()
                    switch result {
                    case let .unit(unit)?:
                        let f = frame!
                        failures = 0
                        let encodeMs = (now - encodeStart) * 1000
                        encodeEWMA = encodeEWMA.map { $0 + 0.2 * (encodeMs - $0) } ?? encodeMs
                        window.encodeMs.append(encodeMs)
                        latestWidth = unit.width
                        let isNew = f.id != shown
                        let kind: VideoPictureKind = unit.isKey ? .key : isNew ? .delta : wanted == .refine ? .refine
                            : wanted == .keepalive ? .keepalive : .delta
                        guard let sent = sink.sendPicture(unit, kind: kind, publishedAt: f.publishedAt) else { return }
                        seq = sent.seq
                        let done = clock()
                        flow?.with { $0.pictureSent(seq: seq, at: done, bytes: sent.bytes) }
                        meter.add(sent.bytes, at: done)
                        lastPictureAt = done
                        lastPictureStart = encodeStart
                        if unit.isKey {
                            needKey = false
                            keyFrames += 1
                            window.keys += 1
                            lastKeyBytes = unit.data.count
                            flow?.with { $0.noteKeySent(at: done) }
                        }
                        if isNew { window.live += 1 } else if wanted == .refine { window.refines += 1 } else { window.keepalives += 1 }
                        if pacing != nil {
                            // pictures captured since the last encoded one that never got encoded
                            var missed = 0
                            if isNew, let last = encodedSeq, f.id.frame > last + 1 { missed = Int(f.id.frame - last - 1) }
                            if isNew { encodedSeq = f.id.frame }
                            let cause = heldChecks > 0 ? "held" : "busy"
                            if missed > 0 {
                                if heldChecks > 0 { window.missed?.held += missed } else { window.missed?.busy += missed }
                            }
                            window.missed?.heldMs += heldMs
                            window.bytes.append(unit.data.count)
                            if let trace = o.trace {
                                var r: [String: Any] = [
                                    "seq": Int(f.id.frame), "frame": Int(seq), "kind": kind.rawValue, "want": "\(wanted)",
                                    "w": unit.width, "h": unit.height, "bytes": unit.data.count,
                                    "encMs": LinkTrace.round3(encodeMs), "bitrate": encoder.bitrate,
                                    "sinceLastMs": previousStart.isFinite ? LinkTrace.round3((encodeStart - previousStart) * 1000) : NSNull(),
                                    "missed": missed, "cause": missed > 0 ? cause : NSNull(), "heldChecks": heldChecks,
                                    "heldMs": LinkTrace.round3(heldMs), "capSleepMs": LinkTrace.round3(capSleepMs),
                                    "sendMs": LinkTrace.round3((done - now) * 1000),
                                ]
                                // capture callback → encode start / → handed to the link
                                if let at = f.publishedAt {
                                    r["capWaitMs"] = LinkTrace.round3(encodeStartWall - at)
                                    r["capToSentMs"] = LinkTrace.round3(Date().timeIntervalSince1970 * 1000 - at)
                                }
                                if let heldGate { r["gate"] = heldGate }
                                trace("enc", r)
                            }
                            heldChecks = 0
                            heldMs = 0
                            capSleepMs = 0
                            heldGate = nil
                        }
                        if isNew || wanted == .live {
                            shown = f.id
                            refine.noteLive(at: done)
                        } else if wanted == .refine {
                            refine.noteRefined(at: done, bytes: unit.data.count, budget: budget)
                        }
                        continue
                    case .dropped?:
                        // The rate control skipped it (over budget): retry with the newest picture a frame later.
                        window.drops += 1
                        o.trace?("drop", ["seq": frame.map { Int($0.id.frame) as Any } ?? NSNull(),
                                          "encMs": LinkTrace.round3((now - encodeStart) * 1000)])
                        lastPictureAt = now
                        lastPictureStart = now
                        // a skipped refine: one fewer left, and the picture is not settled yet
                        if wanted == .refine { refine.noteRefined(at: now, bytes: nil, budget: budget) }
                        continue
                    case .failed?:
                        failures += 1
                        needKey = true
                        if failures >= t.maxEncodeFailures {
                            log("\(label): \(codecName) failed \(failures)x in a row; ending the stream (the client reopens)")
                            return
                        }
                        continue
                    case nil:
                        // Not available right now (the mirror is being rebuilt at a new width): its wake-up retries.
                        if wanted == .refine { refine.cancel() }
                    }
                }
            }

            now = clock()
            // Picture deadlines (keepalive, refine, a deferred key frame) can't fire before the window reopens.
            let floor = blockedUntil ?? now
            if shown != nil { deadline = min(deadline, max(floor, lastPictureAt + t.keepalive)) }
            if let due = refine.dueAt { deadline = min(deadline, max(floor, due)) }
            if let flow {
                if let k = flow.with({ $0.keyDueAt }) { deadline = min(deadline, max(floor, k)) }
                if let s = flow.with({ $0.stallDeadline() }) { deadline = min(deadline, s) }
            }
            // Never a hot spin, whatever is pending: at least 2 ms (a change still ends the wait at once).
            guard source.waitForFrame(after: token, until: Date().addingTimeInterval(max(0.002, deadline - now))) else { return }
        }
    }
}
#endif
