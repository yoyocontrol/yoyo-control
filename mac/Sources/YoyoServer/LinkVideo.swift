#if os(macOS) && canImport(YoyoLink)
import CoreGraphics
import Foundation
import YoyoLink

// A link session's video and sound (docs/LINK.md「会话协议」「媒体」): `video.open` runs the same video loop as
// `/stream` (VideoStreamLoop.swift) into a `LinkVideoSink` — frames into the media layer (FEC, NACK, pacing), the pointer
// as cursor datagrams with its shapes as `cursor.shape`, status parts as `video.status`; `audio.open` hands the sound
// capture's Opus packets to `send_audio`.

/// The link's video sink: frames to `send_frame` instead of multipart parts, `can_send_frame` instead of the ack
/// window, the rate controller's target instead of the bit-rate steps, and recovery frames on VideoToolbox's long-term
/// references (LinkRecoveryBook) after a loss.
final class LinkVideoSink: VideoStreamSink, VideoStreamPacing, @unchecked Sendable {
    let session: LinkSession
    let stream: UInt8
    /// The stream's codec (set before the loop starts: the request decides it).
    var codec: VideoCodec = .h264
    private let lock = NSLock()
    private var book = LinkRecoveryBook<VideoLTRToken>()
    private var pendingBitrate: Int?
    private var targetBps: UInt64?
    private var closed = false
    private(set) var closeReason: String?
    private var counts = (keys: 0, recoveries: 0, sendFailures: 0)
    /// Wakes the loop (a recovery or key frame is due, the stream was closed).
    var wake: (() -> Void)?
    /// `status=1`: the display's state, sent through `onStatus` when it changes (checked on every turn of the loop).
    var status: StreamStatusFeed?
    var onStatus: ((ScreenDisplayState, ConsoleState?) -> Void)?
    /// A cursor shape the phone hasn't had yet (`cursor.shape`).
    var onShape: ((ClientCursorShape) -> Void)?
    /// The phone's reports (the stats line's tail).
    var reports: LinkReports?
    /// The session's trace (the loop's `enc` / `cap` records); nil: none.
    var trace: LinkTrace?
    /// The media layer's numbers at the last closed gate (the trace's `enc`).
    private var closedGate: SendGate?

    init(session: LinkSession, stream: UInt8, encoderBps: UInt64?) {
        self.session = session
        self.stream = stream
        if let encoderBps { setBitrate(encoderBps) }
    }

    // MARK: From the media layer and the phone

    func setBitrate(_ bps: UInt64) {
        lock.lock()
        pendingBitrate = Int(clamping: bps)
        targetBps = bps
        lock.unlock()
    }

    func delivered(_ frame: UInt32) {
        lock.lock(); book.delivered(frame); lock.unlock()
    }

    func recoveryNeeded(lastDelivered: UInt32?) {
        lock.lock(); book.recoveryNeeded(lastDelivered: lastDelivered); lock.unlock()
        wake?()
    }

    func keyNeeded() {
        lock.lock(); book.keyNeeded(); lock.unlock()
        wake?()
    }

    func close(reason: String) {
        lock.lock()
        if !closed {
            closed = true
            closeReason = reason
        }
        lock.unlock()
        wake?()
    }

    // MARK: VideoStreamSink

    func isClosed() -> Bool {
        lock.lock()
        let c = closed
        lock.unlock()
        if c || session.isClosed() { return true }
        if let status, let onStatus, !status.pump(send: { onStatus($0, $1); return true }) {
            close(reason: "the display is unavailable")
            return true
        }
        return false
    }

    var pacing: VideoStreamPacing? { self }

    func sendCursor(_ c: ClientCursor, newShape: ClientCursorShape?) -> Int? {
        if let newShape { onShape?(newShape) }
        let json = (try? JSONSerialization.data(withJSONObject: ["x": c.x, "y": c.y, "visible": c.visible, "shapeId": c.shapeId],
                                                options: [.sortedKeys])) ?? Data()
        do {
            try session.sendCursor(stream: stream, json: json)
        } catch {
            if session.isClosed() { return nil }
        }
        return json.count
    }

    func sendPicture(_ unit: VideoAccessUnit, kind: VideoPictureKind, publishedAt: Double?) -> VideoSinkSent? {
        lock.lock()
        let k = book.kind(isKey: unit.isKey, loopKind: kind)
        lock.unlock()
        var base: UInt32 = 0
        let ffiKind: FrameKind
        switch k {
        case .key: ffiKind = .key
        case .delta: ffiKind = .delta
        case .refine: ffiKind = .refine
        case .keepalive: ffiKind = .keepalive
        case .recovery(let b): ffiKind = .recovery; base = b
        }
        let captured = publishedAt ?? Date().timeIntervalSince1970 * 1000
        let meta = FrameMeta(codec: codec == .h264 ? .h264 : .hevc, kind: ffiKind, width: UInt16(clamping: unit.width),
                             height: UInt16(clamping: unit.height), captureUs: UInt64(max(0, captured * 1000)),
                             recoveryBase: base, auLen: UInt32(clamping: unit.data.count))
        do {
            let frame = try session.sendFrame(stream: stream, meta: meta, au: unit.data)
            lock.lock()
            book.sent(frame: frame, kind: k, token: unit.ltrToken, at: StreamClock.now())
            if case .key = k { counts.keys += 1 }
            if case .recovery = k { counts.recoveries += 1 }
            lock.unlock()
            return VideoSinkSent(seq: UInt64(frame), bytes: unit.data.count)
        } catch {
            if session.isClosed() { return nil }
            // the encoder's chain now has a picture the phone never gets: the next one must not depend on it
            lock.lock()
            counts.sendFailures += 1
            book.recoveryNeeded(lastDelivered: nil)
            lock.unlock()
            log("video: link stream \(stream): frame not sent (\(error)); recovering")
            return VideoSinkSent(seq: 0, bytes: 0)
        }
    }

    // MARK: VideoStreamPacing

    func takeBitrate() -> Int? {
        lock.lock(); defer { lock.unlock() }
        let b = pendingBitrate
        pendingBitrate = nil
        return b
    }

    func canSend() -> Bool {
        guard trace != nil else { return (try? session.canSendFrame(stream: stream)) ?? false }
        guard let g = (try? session.sendGate(stream: stream)) ?? nil else { return false }
        if !g.open {
            lock.lock(); closedGate = g; lock.unlock()
        }
        return g.open
    }

    func takeClosedGate() -> [String: Any]? {
        lock.lock()
        let g = closedGate
        closedGate = nil
        lock.unlock()
        guard let g else { return nil }
        return ["why": g.overQueue ? "queue" : g.overSpace ? "space" : "?", "own": g.ownQueued, "transport": g.transportQueued,
                "space": g.transportSpace.map { $0 as Any } ?? NSNull(), "budget": g.budget, "limit": g.limit,
                "estimate": g.estimate, "targetBps": g.targetBps, "pacingBps": g.pacingBps]
    }

    func refreshDue(at now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return book.refreshDue(at: now)
    }

    func encodeOptions(at now: TimeInterval) -> (forceKey: Bool, options: VideoEncodeOptions) {
        lock.lock(); defer { lock.unlock() }
        let p = book.plan(at: now)
        return (p.forceKey, VideoEncodeOptions(acknowledgedLTR: p.acknowledged.map { [$0] } ?? [], forceLTRRefresh: p.refresh))
    }

    /// `link target 6.2 Mbps keys 1 recoveries 3; phone smooth …`.
    func statsTail() -> String? {
        lock.lock()
        let target = targetBps
        let c = counts
        counts = (0, 0, 0)
        lock.unlock()
        var s = "link target \(target.map { String(format: "%.1f", Double($0) / 1e6) } ?? "-") Mbps keys \(c.keys) recoveries \(c.recoveries)"
        if c.sendFailures > 0 { s += " unsent \(c.sendFailures)" }
        if let tail = reports?.takeTail() { s += "; \(tail)" }
        return s
    }
}

extension Router {
    /// A link session's `video.open`: `/stream`'s request (the same query, parsed the same way) into `sink` until it is
    /// closed, the session ends or the capture stops. `opened` gets what the HTTP response head would say. Throws an
    /// HTTPError for what `/stream` answers with an error status.
    static func linkStream(_ req: HTTPRequest, sink: LinkVideoSink, label: String,
                           opened: (_ headers: [String: String], _ width: Int, _ height: Int, _ codec: VideoCodec) -> Void) throws {
        PointerHolds.shared.streamOpened()
        defer { PointerHolds.shared.streamClosed() }
        let options = try StreamRequestOptions.parse(req)
        var cleanup: [() -> Void] = []
        defer { cleanup.reversed().forEach { $0() } }
        let source: VideoPictureSource
        var o: VideoStreamOptions
        var headers: [String: String]
        var size = (width: 0, height: 0)
        if let hook = LinkHooks.videoSource {
            let made = try hook(req)
            source = made.source
            o = VideoStreamOptions(codec: made.codec, label: label)
            o.interval = 1 / Double(made.fps)
            headers = ["X-Stream-Codec": made.codec.rawValue]
        } else {
            _ = try options.codec()  // no video encoder at all is a 503 before anything else happens
            let wantsStatus = try statusRequested(req)
            let setup = try captureSetup(req)
            let display = setup.params.display
            let frames = FrameStream(setup.params, fps: setup.fps, showsCursor: !setup.options.cursorClient)
            if let trace = sink.trace {
                frames.onTrace = { status, gated, seq, latencyMs in
                    trace.write("cap", ["st": status, "gated": gated, "seq": seq,
                                        "latMs": latencyMs.map { LinkTrace.round3($0) as Any } ?? NSNull()])
                }
            }
            cleanup.append { frames.stop() }
            try frames.start(fps: setup.fps)
            let why = "no ScreenCaptureKit frame in \(Int((firstFrameWait * 1000).rounded())) ms"
            switch frames.firstFrame(within: firstFrameWait) {
            case .firstFrame: break
            case .noFirstFrame: log("display \(display): \(why); keeping ScreenCaptureKit")
            case .failed: throw HTTPError(503, "display \(display): \(why)")
            }
            log("display \(display): \(label) open (\(setupLine(setup, frames)))")
            o = VideoStreamOptions(codec: setup.codec, label: label)
            o.interval = 1 / Double(setup.fps)
            o.tuning = StreamTuning.current.limited(toKbps: setup.options.maxKbps)
            if !frames.showsCursor {
                let tracker = DisplayPointerTracker(display: display)
                tracker.start()
                frames.pointer = tracker
                cleanup.append { tracker.stop() }
            }
            if wantsStatus, let feed = try statusFeed(req, display: display) {
                feed.tracker.refresh()
                sink.status = feed
            }
            source = frames
            headers = ["X-Display": "\(display)", "X-Stream-Codec": setup.codec.rawValue]
            size = Displays.targetSize(display, maxWidth: setup.params.maxWidth)
        }
        if let id = options.streamID { headers["X-Stream-Id"] = id }
        o.statsInterval = 10
        o.ltr = true
        if let trace = sink.trace {
            o.trace = { trace.write($0, $1) }
        }
        sink.codec = o.codec
        sink.wake = { [weak source] in source?.wake() }
        opened(headers, size.width, size.height, o.codec)
        videoStreamLoop(source, sink: sink, o)
    }
}

/// One `audio.open` of a link session: the shared sound capture's packets into `send_audio` until closed.
final class LinkAudioStream: @unchecked Sendable {
    let stream: UInt8
    private let flag = LockedFlag()
    init(stream: UInt8) { self.stream = stream }
    func close() { flag.set() }
    var isClosed: Bool { flag.value }
}

extension LinkPeer {
    /// `video.open {id, query}` → `video.opened` (or `video.error`), frames, `video.closed` at the end.
    func openVideo(_ o: [String: Any]) {
        guard let id = Self.streamID(o["id"]) else {
            send(["t": "video.error", "id": o["id"] ?? NSNull(), "status": 400, "message": "id must be a stream number 1…255"])
            return
        }
        lock.lock()
        if videos[id] != nil {
            lock.unlock()
            send(["t": "video.error", "id": Int(id), "status": 409, "message": "video stream \(id) is open"])
            return
        }
        let sink = LinkVideoSink(session: session, stream: id, encoderBps: encoderBps)
        sink.trace = trace
        videos[id] = sink
        lock.unlock()
        sink.reports = reports
        sink.onShape = { [weak self] shape in
            self?.send(["t": "cursor.shape", "id": Int(id), "shapeId": shape.id, "shape": shape.json])
        }
        sink.onStatus = { [weak self] state, console in
            var j = state.json
            j["console"] = console?.json ?? NSNull()
            self?.send(["t": "video.status", "id": Int(id), "json": j])
        }
        let req = HTTPRequest(method: "GET", path: "/stream", query: Router.queryItems(o["query"] as? String ?? ""), headers: [:],
                              body: Data(), remote: remote)
        let label = "video: \(self.label) stream \(id)"
        // as `/stream`'s handler threads: the hardware encoder inherits the QoS
        let t = Thread { [self] in
            var reason = "ended"
            do {
                try Router.linkStream(req, sink: sink, label: label) { headers, width, height, codec in
                    session.openVideo(stream: id)
                    send(["t": "video.opened", "id": Int(id), "codec": codec.rawValue, "width": width, "height": height,
                          "headers": headers])
                }
                reason = sink.closeReason ?? (session.isClosed() ? "the session ended" : "the capture stopped")
            } catch let err as HTTPError {
                send(["t": "video.error", "id": Int(id), "status": err.status, "message": err.message])
                reason = err.message
            } catch {
                send(["t": "video.error", "id": Int(id), "status": 500, "message": "\(error)"])
                reason = "\(error)"
            }
            session.closeVideo(stream: id)
            lock.lock()
            if videos[id] === sink { videos[id] = nil }
            lock.unlock()
            send(["t": "video.closed", "id": Int(id), "reason": reason])
        }
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// `audio.open {id, query}` → `audio.opened {id, codec, rate, channels, frames, cookie?, videoOffsetMs}`, packets,
    /// `audio.closed {id, reason}` at the end; `audio.error {id, status, message}` instead when it can't start (what
    /// `/audio` would have answered).
    func openAudio(_ o: [String: Any]) {
        guard let id = Self.streamID(o["id"]) else {
            send(["t": "audio.error", "id": o["id"] ?? NSNull(), "status": 400, "message": "id must be a stream number 1…255"])
            return
        }
        lock.lock()
        if audios[id] != nil {
            lock.unlock()
            send(["t": "audio.error", "id": Int(id), "status": 409, "message": "audio stream \(id) is open"])
            return
        }
        let stream = LinkAudioStream(stream: id)
        audios[id] = stream
        lock.unlock()
        let t = Thread { [self] in
            defer {
                lock.lock()
                if audios[id] === stream { audios[id] = nil }
                lock.unlock()
            }
            let client: AudioCapture.Client
            do {
                if let hook = LinkHooks.audioClient {
                    client = try hook()
                } else {
                    guard Router.audioEnabled else { throw HTTPError(503, "audio off") }
                    client = try AudioCapture.subscribe()
                }
            } catch let err as HTTPError {
                send(["t": "audio.error", "id": Int(id), "status": err.status, "message": err.message])
                return
            } catch {
                send(["t": "audio.error", "id": Int(id), "status": 500, "message": "\(error)"])
                return
            }
            defer { AudioCapture.unsubscribe(client) }
            session.openAudio(stream: id)
            var opened: [String: Any] = ["t": "audio.opened", "id": Int(id), "codec": "opus", "rate": AudioWire.sampleRate,
                                         "channels": AudioWire.channels, "frames": AudioWire.framesPerPacket,
                                         "videoOffsetMs": client.videoOffset.totalMs]
            if let cookie = client.cookie, !cookie.isEmpty { opened["cookie"] = cookie.base64EncodedString() }
            send(opened)
            var reason = "closed by the phone"
            while !stream.isClosed {
                if session.isClosed() { reason = "the session ended"; break }
                let items = client.queue.popAll(until: Date().addingTimeInterval(0.25))
                if items.isEmpty, client.queue.isClosed { reason = "the capture stopped"; break }
                for item in items {
                    _ = try? session.sendAudio(stream: id, timeUs: UInt64(max(0, item.packet.timeMs)) * 1000, opus: item.packet.data)
                }
            }
            session.closeAudio(stream: id)
            send(["t": "audio.closed", "id": Int(id), "reason": reason])
        }
        t.qualityOfService = .userInteractive
        t.start()
    }
}
#endif
