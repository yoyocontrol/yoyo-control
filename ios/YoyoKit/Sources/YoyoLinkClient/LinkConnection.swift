import Foundation
import Synchronization
import YoyoCore
import YoyoLink

/// One uu Link session to a computer as the kits use it (docs/LINK.md「会话协议」): the Screen page's media
/// (`YoyoScreenLink`: `video.open` / `audio.open` and their datagrams, cursor positions and shapes, input through the
/// media layer, `report`), control (`control.take` / `control.release`) and the server's other routes as RPC requests
/// (`data(for:)`, `lines(for:)`: a `URLRequest` as it would go over HTTP). It reads the session's control messages and
/// media events itself and hands each to the stream it belongs to; when the session ends every open stream hears it
/// (`.failed`) and `ended()` returns. Thread-safe.
public final class YoyoLinkConnection: YoyoScreenLink, @unchecked Sendable {
    /// What this client says it takes, in `hello.features`.
    static let features = ["screen", "audio", "cursor", "input"]

    /// The answer to `control.take` / `control.release`.
    public struct ControlAnswer: Sendable, Equatable {
        public var granted: Bool
        /// Who holds control now (nil: nobody).
        public var holder: ScreenControlDevice?
    }

    public let session: LinkSession

    /// What came over the session's video streams so far (logs, tests).
    public struct FrameCounts: Sendable, Equatable {
        public var frames = 0
        public var keys = 0
        /// Deltas on an acknowledged long-term reference (the encoder's repair of a lost frame without a key frame).
        public var recoveries = 0
        public var decoded = 0
        public var decodeFailures = 0
    }

    public var frameCounts: FrameCounts { counts.withLock { $0 } }
    private let counts = Mutex(FrameCounts())

    private final class Stream: @unchecked Sendable {
        let video: (@Sendable (YoyoLinkVideoEvent) -> Void)?
        let audio: (@Sendable (YoyoLinkAudioEvent) -> Void)?
        init(video: (@Sendable (YoyoLinkVideoEvent) -> Void)? = nil, audio: (@Sendable (YoyoLinkAudioEvent) -> Void)? = nil) {
            self.video = video
            self.audio = audio
        }
    }

    private struct State {
        var streams: [UInt8: Stream] = [:]
        var next: UInt8 = 0
        var waiters: [String: CheckedContinuation<LinkControlMessage?, Never>] = [:]
        var inputError: (@Sendable (Error) -> Void)?
        /// Why the session ended (nil: it hasn't).
        var ended: String?
    }
    private let state = Mutex(State())
    private let readers = Mutex<[Task<Void, Never>]>([])

    /// `control` answers wait this long.
    static let controlTimeout: Duration = .seconds(5)

    public init(session: LinkSession) {
        self.session = session
        let control = Task.detached(priority: .userInitiated) { [weak self] in
            while let text = await session.recvControl() {
                guard let self else { return }
                if let m = LinkControlMessage(json: text) { self.control(m) }
            }
            let info = await session.closed()
            self?.end(info.description)
        }
        let media = Task.detached(priority: .high) { [weak self] in
            while let e = await session.nextClientEvent() {
                guard let self else { return }
                self.media(e)
            }
        }
        readers.withLock { $0 = [control, media] }
    }

    deinit {
        for t in readers.withLock({ $0 }) { t.cancel() }
    }

    /// Ends the session (`bye`, code 0).
    public func close() {
        let session = session
        Task { await session.close(.normal, reason: "done") }
    }

    /// Returns when the session ended (by either side, or the network).
    public func ended() async {
        _ = await session.closed()
    }

    public var isClosed: Bool { session.isClosed() }

    // MARK: YoyoScreenLink

    public var pathLabel: String { "link " + Self.name(session.path().kind) }

    public var isLocalNetwork: Bool { session.path().kind == .lan }

    public var rttMinMs: Double? {
        let ms = session.stats().rttMinMs
        return ms > 0 ? ms : nil
    }

    /// `link: …`'s body now (`lan wifi rtt 0.4/1.2/2.0 ms loss …`).
    public var statsLine: String? { session.stats().line }

    public func openVideo(query: String, onEvent: @escaping @Sendable (YoyoLinkVideoEvent) -> Void) -> any YoyoLinkVideo {
        let (id, ended) = register(Stream(video: onEvent))
        let video = Video(connection: self, id: id)
        if let ended {
            onEvent(.failed(reason: ended))
            return video
        }
        session.openVideo(stream: id)
        send(["t": "video.open", "id": Int(id), "query": query]) { onEvent(.failed(reason: $0)) }
        return video
    }

    public func openAudio(query: String, onEvent: @escaping @Sendable (YoyoLinkAudioEvent) -> Void) -> any YoyoLinkAudio {
        let (id, ended) = register(Stream(audio: onEvent))
        let audio = Audio(connection: self, id: id)
        if let ended {
            onEvent(.failed(reason: ended))
            return audio
        }
        session.openAudio(stream: id)
        send(["t": "audio.open", "id": Int(id), "query": query]) { onEvent(.failed(reason: $0)) }
        return audio
    }

    public func sendInput(_ json: Data, move: Bool) throws {
        do {
            _ = try session.sendInput(kind: move ? .move : .discrete, json: json)
        } catch let LinkError.Media(message) where message.lowercased().contains("overflow") {
            throw YoyoError.http(429, "too many input events waiting")
        } catch {
            throw URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: YoyoLinkClient.describe(error)])
        }
    }

    public func setInputErrorHandler(_ handler: (@Sendable (Error) -> Void)?) {
        state.withLock { $0.inputError = handler }
    }

    // MARK: Control

    /// `control.take` (`take`) or `control.release`, and the server's answer (`control` with the same `rid`).
    public func control(take: Bool) async throws -> ControlAnswer {
        let rid = UUID().uuidString
        let answer: LinkControlMessage? = await withCheckedContinuation { cont in
            state.withLock { $0.waiters[rid] = cont }
            send(["t": take ? "control.take" : "control.release", "rid": rid]) { [weak self] _ in self?.answer(rid, nil) }
            Task { [weak self] in
                try? await Task.sleep(for: Self.controlTimeout)
                self?.answer(rid, nil)
            }
        }
        guard let answer else { throw URLError(.timedOut) }
        let o = answer.object
        let holder = (o["holder"] as? [String: Any]).flatMap(Self.device)
        return ControlAnswer(granted: o["granted"] as? Bool ?? false, holder: holder)
    }

    private func answer(_ rid: String, _ message: LinkControlMessage?) {
        state.withLock { $0.waiters.removeValue(forKey: rid) }?.resume(returning: message)
    }

    // MARK: RPC

    /// One RPC request (docs/LINK.md「RPC 流」): `path` with its query, header names lowercase.
    public func request(_ method: String, _ path: String, headers: [String: String] = [:], body: Data = Data()) async throws
        -> RpcResponse {
        do {
            return try await session.request(request: RpcRequest(method, path, headers: headers), body: body)
        } catch {
            throw URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: YoyoLinkClient.describe(error)])
        }
    }

    /// `request` as RPC (its method, path and query, headers, body), its whole answer (at most `limit` bytes): what
    /// `URLSession.data(for:)` would give over HTTP.
    public func data(for request: URLRequest, limit: Int = 128 << 20) async throws -> (Data, HTTPURLResponse) {
        let response = try await self.request(for: request)
        let body: Data
        do { body = try await response.readAll(limit: UInt64(limit)) } catch {
            throw URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: YoyoLinkClient.describe(error)])
        }
        return (body, Self.http(response, for: request))
    }

    /// `request` as RPC with a streamed answer (`/events`' NDJSON): its head, and its lines as they come.
    public func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let response = try await self.request(for: request)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                var buffer = Data()
                do {
                    while let chunk = try await response.chunk() {
                        buffer.append(chunk)
                        while let nl = buffer.firstIndex(of: 0x0A) {
                            let line = buffer[buffer.startIndex..<nl]
                            buffer.removeSubrange(buffer.startIndex...nl)
                            continuation.yield(String(decoding: line, as: UTF8.self))
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                response.cancel()
            }
        }
        return (Self.http(response, for: request), lines)
    }

    private func request(for request: URLRequest) async throws -> RpcResponse {
        guard let url = request.url else { throw URLError(.badURL) }
        var path = url.path(percentEncoded: true)
        if path.isEmpty { path = "/" }
        if let q = url.query(percentEncoded: true), !q.isEmpty { path += "?" + q }
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] where k.lowercased() != "host" { headers[k.lowercased()] = v }
        return try await self.request(request.httpMethod ?? "GET", path, headers: headers, body: request.httpBody ?? Data())
    }

    private static func http(_ response: RpcResponse, for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url ?? URL(string: "https://link.invalid/")!, statusCode: Int(response.status()),
                        httpVersion: "link/1", headerFields: response.headers())
            ?? HTTPURLResponse()
    }

    // MARK: Streams

    fileprivate final class Video: YoyoLinkVideo, @unchecked Sendable {
        weak var connection: YoyoLinkConnection?
        let id: UInt8
        init(connection: YoyoLinkConnection, id: UInt8) {
            self.connection = connection
            self.id = id
        }
        func decoded(frame: UInt32, ok: Bool) {
            guard let connection else { return }
            connection.counts.withLock { if ok { $0.decoded += 1 } else { $0.decodeFailures += 1 } }
            try? connection.session.frameDecoded(stream: id, frame: frame, ok: ok)
        }
        func requestKeyframe() { connection?.session.requestKeyframe(stream: id) }
        func report(_ json: Data) {
            guard var object = try? JSONSerialization.jsonObject(with: json), let connection else { return }
            // every frame's fate in this phone's media layer since the last report (the Mac's trace; session clock µs,
            // paired with the host clock in `clock`)
            if var o = object as? [String: Any] {
                let rx = (try? connection.session.takeRxTraces()) ?? []
                if !rx.isEmpty || o["frames"] != nil {
                    o["rx"] = rx.map(Self.rxRecord)
                    var clock = o["clock"] as? [String: Any] ?? [:]
                    clock["mediaUs"] = connection.session.mediaNowUs()
                    clock["hostNowMs"] = (ProcessInfo.processInfo.systemUptime * 1e6).rounded() / 1000
                    o["clock"] = clock
                    object = o
                }
            }
            connection.send(["t": "report", "id": Int(id), "report": object])
        }

        static func rxRecord(_ t: RxTrace) -> [String: Any] {
            func us(_ v: UInt64?) -> Any { v.map { Double($0) / 1000 } ?? NSNull() }
            return ["stream": Int(t.stream), "frame": Int(t.frame), "fate": "\(t.fate)", "kind": t.kind.map { Int($0) } ?? NSNull(),
                    "au": Int(t.auBytes), "captureMs": us(t.captureUs), "firstMs": us(t.firstArrivalUs),
                    "lastMs": us(t.lastArrivalUs), "completeMs": us(t.completedUs), "decidedMs": Double(t.decidedUs) / 1000,
                    "shards": Int(t.shards), "fec": Int(t.fec), "retx": Int(t.retx), "nacks": Int(t.nackItems)]
        }
        func close() { connection?.closeStream(id, video: true) }
    }

    fileprivate final class Audio: YoyoLinkAudio, @unchecked Sendable {
        weak var connection: YoyoLinkConnection?
        let id: UInt8
        init(connection: YoyoLinkConnection, id: UInt8) {
            self.connection = connection
            self.id = id
        }
        func close() { connection?.closeStream(id, video: false) }
    }

    /// A new stream id (1…255, the oldest reused after a wrap), or why the session is over.
    private func register(_ stream: Stream) -> (UInt8, String?) {
        state.withLock { s in
            if let ended = s.ended { return (0, ended) }
            for _ in 0..<255 {
                s.next = s.next == 255 ? 1 : s.next + 1
                if s.streams[s.next] == nil { break }
            }
            s.streams[s.next] = stream
            return (s.next, nil)
        }
    }

    fileprivate func closeStream(_ id: UInt8, video: Bool) {
        guard state.withLock({ $0.streams.removeValue(forKey: id) }) != nil else { return }
        if video { session.closeVideo(stream: id) } else { session.closeAudio(stream: id) }
        send(["t": video ? "video.close" : "audio.close", "id": Int(id)])
    }

    private func stream(_ id: Any?) -> Stream? {
        guard let n = (id as? NSNumber)?.intValue, let id = UInt8(exactly: n) else { return nil }
        return state.withLock { $0.streams[id] }
    }

    private func drop(_ id: Any?, video: Bool) {
        guard let n = (id as? NSNumber)?.intValue, let id = UInt8(exactly: n),
              state.withLock({ $0.streams.removeValue(forKey: id) }) != nil else { return }
        if video { session.closeVideo(stream: id) } else { session.closeAudio(stream: id) }
    }

    /// Sends a control message; `failed` hears why it couldn't.
    fileprivate func send(_ object: [String: Any], failed: (@Sendable (String) -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let session = session
        Task {
            do { try await session.sendControl(json: text) } catch { failed?(YoyoLinkClient.describe(error)) }
        }
    }

    // MARK: From the server

    private func control(_ m: LinkControlMessage) {
        let o = m.object
        switch m.type {
        case "video.opened":
            var headers: [String: String] = [:]
            for (k, v) in o["headers"] as? [String: Any] ?? [:] { headers[k] = "\(v)" }
            stream(o["id"])?.video?(.opened(codec: o["codec"] as? String, width: o["width"] as? Int, height: o["height"] as? Int,
                                            headers: headers))
        case "video.error":
            let s = stream(o["id"])
            drop(o["id"], video: true)
            s?.video?(.error(status: o["status"] as? Int ?? 500, message: o["message"] as? String))
        case "video.closed":
            let s = stream(o["id"])
            drop(o["id"], video: true)
            s?.video?(.closed(reason: o["reason"] as? String))
        case "video.status":
            guard let json = Self.json(o["json"]) else { return }
            stream(o["id"])?.video?(.status(json))
        case "cursor.shape":
            var cursor: [String: Any] = [:]
            if let id = o["shapeId"] { cursor["shapeId"] = id }
            if let shape = o["shape"] { cursor["shape"] = shape }
            guard let json = try? JSONSerialization.data(withJSONObject: cursor) else { return }
            stream(o["id"])?.video?(.cursor(json))
        case "audio.opened":
            var format: [String: String] = [:]
            let names = ["codec": "X-Audio-Codec", "rate": "X-Audio-Rate", "channels": "X-Audio-Channels",
                         "frames": "X-Audio-Frames", "cookie": "X-Audio-Cookie", "videoOffsetMs": "X-Audio-Video-Offset"]
            for (field, header) in names { if let v = o[field], !(v is NSNull) { format[header] = "\(v)" } }
            stream(o["id"])?.audio?(.opened(format: format))
        case "audio.error":
            let s = stream(o["id"])
            drop(o["id"], video: false)
            s?.audio?(.error(status: o["status"] as? Int ?? 500, message: o["message"] as? String))
        case "audio.closed":
            let s = stream(o["id"])
            drop(o["id"], video: false)
            s?.audio?(.closed(reason: o["reason"] as? String))
        case "control":
            if let rid = o["rid"] as? String { answer(rid, m) }
        case "input.rejected":
            inputError(Self.rejection(o))
        default:
            break
        }
    }

    private func media(_ e: ClientMediaEvent) {
        switch e {
        case .frame(let f):
            counts.withLock { c in
                c.frames += 1
                if f.meta.kind == .key { c.keys += 1 }
                if f.meta.kind == .recovery { c.recoveries += 1 }
            }
            guard let s = state.withLock({ $0.streams[f.stream] }) else { return }
            s.video?(.frame(YoyoLinkFrame(number: f.frame, codec: f.meta.codec == .hevc ? "hevc" : "h264",
                                          kind: Self.name(f.meta.kind), width: Int(f.meta.width), height: Int(f.meta.height),
                                          captureMs: f.meta.captureUs > 0 ? Double(f.meta.captureUs) / 1000 : nil, au: f.au)))
        case .audio(let p):
            state.withLock { $0.streams[p.stream] }?.audio?(.packet(seq: Int(p.aseq), timeMs: Double(p.timeUs) / 1000, data: p.data))
        case let .cursor(stream, _, json):
            state.withLock { $0.streams[stream] }?.video?(.cursor(json))
        case .inputAcked:
            break
        case .inputFailed:
            inputError(URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "input not acknowledged"]))
        }
    }

    private func inputError(_ error: Error) {
        state.withLock { $0.inputError }?(error)
    }

    /// The session is over: every open stream hears it, and every wait for an answer ends.
    private func end(_ reason: String) {
        let c = frameCounts
        if c.frames > 0 {
            YoyoLinkClient.emit("link[phone]: frames \(c.frames) (\(c.keys) key, \(c.recoveries) recovery), decoded \(c.decoded), "
                                + "decode failures \(c.decodeFailures)")
        }
        let (streams, waiters) = state.withLock { s -> ([Stream], [CheckedContinuation<LinkControlMessage?, Never>]) in
            s.ended = reason
            defer { s.streams = [:]; s.waiters = [:] }
            return (Array(s.streams.values), Array(s.waiters.values))
        }
        for w in waiters { w.resume(returning: nil) }
        for s in streams {
            s.video?(.failed(reason: reason))
            s.audio?(.failed(reason: reason))
        }
    }

    // MARK: Mapping

    /// `input.rejected {seq, status, code, message, controllerDevice?}` as the error `POST /input` would have thrown.
    static func rejection(_ o: [String: Any]) -> Error {
        let status = o["status"] as? Int ?? 400
        let message = o["message"] as? String
        if status == 401 { return YoyoError.unauthorized }
        if o["code"] as? String == ScreenControlledElsewhere.code,
           let device = (o["controllerDevice"] as? [String: Any] ?? o["holder"] as? [String: Any]).flatMap(device) {
            return ScreenControlledElsewhere(controllerDevice: device, message: message)
        }
        return YoyoError.http(status, message)
    }

    static func device(_ o: [String: Any]) -> ScreenControlDevice? {
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        return ScreenControlDevice(id: id, name: o["name"] as? String)
    }

    /// A JSON value given as an object or as its text.
    static func json(_ value: Any?) -> Data? {
        if let s = value as? String { return Data(s.utf8) }
        guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value)
    }

    static func name(_ kind: PathKind) -> String {
        switch kind {
        case .relay: "relay"
        case .lan: "lan"
        case .direct: "direct"
        case .punched: "punched"
        case .none: "none"
        }
    }

    static func name(_ kind: FrameKind) -> String {
        switch kind {
        case .delta: "delta"
        case .key: "key"
        case .refine: "refine"
        case .keepalive: "keepalive"
        case .recovery: "recovery"
        }
    }
}
