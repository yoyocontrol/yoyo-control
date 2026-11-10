#if os(macOS) && canImport(YoyoLink)
import Foundation
import YoyoLink

/// Test seams of the link sessions (the link tests run without Screen Recording, Accessibility or sound capture).
enum LinkHooks {
    /// Instead of a display's capture: the picture source, codec and frame rate of a `video.open`.
    nonisolated(unsafe) static var videoSource: ((HTTPRequest) throws -> (source: VideoPictureSource, codec: VideoCodec, fps: Int))?
    /// Instead of the sound capture: an `audio.open`'s client.
    nonisolated(unsafe) static var audioClient: (() throws -> AudioCapture.Client)?
    /// Instead of `POST /input` (after the link's own control check): the route's answer.
    nonisolated(unsafe) static var input: ((HTTPRequest) -> (status: Int, body: [String: Any]))?
}

/// One link session on the server (docs/LINK.md「会话协议」): its control messages (video and audio streams, the
/// phone's reports, control of the screen), its input (through `POST /input`'s handler), its RPC streams (through the
/// routes, remote access's allowlist) and the media layer's events.
final class LinkPeer: @unchecked Sendable {
    let session: LinkSession
    private weak var server: LinkServer?
    /// Who (the principal's `device`).
    let device: LinkAuthority.Device
    /// The paired device it authenticated as (default mode); nil in authority mode.
    let remote: RemoteDevice?
    /// The log prefix: `link <device name>`.
    let label: String
    let lock = NSLock()
    var videos: [UInt8: LinkVideoSink] = [:]
    var audios: [UInt8: LinkAudioStream] = [:]
    /// The media layer's latest encoder rate (new video streams start there).
    var encoderBps: UInt64?
    let reports: LinkReports
    /// The session's per-frame trace (`LinkOptions.traceDirectory`); nil: none.
    private(set) var trace: LinkTrace?
    /// The session ended: the trace's loop writes its last records.
    private let traceStop = LockedFlag()
    private let inputQueue = DispatchQueue(label: "yoyo-control.link.input", qos: .userInteractive)
    private var controlToken: Int?
    /// Authority mode: the `rid` of the last take / release, answered with the next holder change (or after 3 s).
    private var pendingRid: Any?
    /// Control messages go out in the order they were sent (one writer task).
    private let outbox: AsyncStream<String>.Continuation
    private let outboxStream: AsyncStream<String>

    init(session: LinkSession, server: LinkServer, device: LinkAuthority.Device, remote: RemoteDevice?) {
        self.session = session
        self.server = server
        self.device = device
        self.remote = remote
        label = "link \(device.name)"
        reports = LinkReports(label: label)
        (outboxStream, outbox) = AsyncStream<String>.makeStream()
    }

    var authority: LinkAuthority? { server?.authority }

    /// Runs the session until it ends, then `onEnd`.
    func start(onEnd: @escaping () -> Void) {
        if let dir = server?.options.traceDirectory {
            let path = session.path()
            trace = LinkTrace(directory: dir, device: device.name, session: [
                "device": device.name, "deviceId": device.id, "path": "\(path.kind)", "remote": path.remote ?? NSNull(),
                "pid": Int(getpid()),
            ])
            if let trace {
                log("\(label): trace \(trace.path)")
                Task { await self.traceLoop(trace) }
            }
        }
        if let authority {
            authority.session("opened", device: device)
            controlToken = authority.observe { [weak self] holder in self?.controlChanged(authorityHolder: holder) }
        } else if let server {
            controlToken = server.control.observe { [weak self] holder in self?.controlChanged(remoteHolder: holder) }
        }
        Task { await self.serverEvents() }
        let session = session, messages = outboxStream
        Task {
            for await m in messages { try? await session.sendControl(json: m) }
        }
        Task {
            await self.controlLoop()
            self.ended()
            onEnd()
        }
    }

    private func ended() {
        lock.lock()
        let v = Array(videos.values), a = Array(audios.values)
        lock.unlock()
        v.forEach { $0.close(reason: "the session ended") }
        a.forEach { $0.close() }
        if let token = controlToken {
            if let authority { authority.removeObserver(token) } else { server?.control.removeObserver(token) }
        }
        authority?.session("closed", device: device)
        traceStop.set()
        outbox.finish()
    }

    // MARK: Control messages

    private func controlLoop() async {
        for await m in session.controlMessages {
            let o = m.object
            switch m.type {
            case "video.open": openVideo(o)
            case "video.close": video(o)?.close(reason: "closed by the phone")
            case "keyframe": video(o)?.keyNeeded()
            case "audio.open": openAudio(o)
            case "audio.close": audio(o)?.close()
            case "report":
                // today's ack `report` object, as the message's `report` or its own fields
                let raw = o["report"] ?? o
                if let r = StreamPlayoutReport(json: raw) { reports.received(r, rtt: rttSummary()) }
                if let trace { Self.tracePhone(trace, message: o) }
            case "control.take", "control.release": controlRequest(take: m.type == "control.take", rid: o["rid"])
            default: break  // unknown messages are ignored (newer phones)
            }
        }
    }

    /// The `id` of a stream message: 1…255 (the datagrams' stream byte).
    static func streamID(_ value: Any?) -> UInt8? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let i = Int(exactly: n.doubleValue),
              (1...255).contains(i) else { return nil }
        return UInt8(i)
    }

    private func video(_ o: [String: Any]) -> LinkVideoSink? {
        guard let id = Self.streamID(o["id"]) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return videos[id]
    }

    private func audio(_ o: [String: Any]) -> LinkAudioStream? {
        guard let id = Self.streamID(o["id"]) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return audios[id]
    }

    /// Sends a control message (in order with every other; failures mean the session ended).
    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        outbox.yield(String(decoding: data, as: UTF8.self))
    }

    func rttSummary() -> StreamRTTSummary? {
        let s = session.stats()
        guard s.rttP50Ms > 0 else { return nil }
        return StreamRTTSummary(minMs: s.rttMinMs, p50Ms: s.rttP50Ms, p90Ms: s.rttP90Ms, samples: 40)
    }

    // MARK: Control of the screen

    private func controlRequest(take: Bool, rid: Any?) {
        if let authority {
            lock.lock()
            pendingRid = rid
            lock.unlock()
            authority.control(take ? "take" : "release", device: device)
            DispatchQueue.global().asyncAfter(deadline: .now() + LinkAuthority.answerTimeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let still = self.pendingRid.map { "\($0)" } == rid.map { "\($0)" }
                if still { self.pendingRid = nil }
                self.lock.unlock()
                if still { self.send(self.controlMessage(holder: authority.holder.map { ($0.id, $0.name) }, rid: rid)) }
            }
            return
        }
        guard let server, let device = server.pairedDevice(device.id) else { return }
        if take { server.control.take(device) } else { server.control.release(device) }
        send(controlMessage(holder: server.control.holder.map { ($0.id, $0.name) }, rid: rid))
    }

    private func controlChanged(remoteHolder h: RemoteControl.Holder?) {
        send(controlMessage(holder: h.map { ($0.id, $0.name) }, rid: nil))
    }

    private func controlChanged(authorityHolder h: LinkAuthority.Device?) {
        lock.lock()
        let rid = pendingRid
        pendingRid = nil
        lock.unlock()
        send(controlMessage(holder: h.map { ($0.id, $0.name) }, rid: rid))
    }

    /// `{"t":"control","rid"?,"granted","holder":{id,name}|null}`.
    func controlMessage(holder: (id: String, name: String)?, rid: Any?) -> [String: Any] {
        var m: [String: Any] = ["t": "control", "granted": holder?.id == device.id,
                                "holder": holder.map { ["id": $0.id, "name": $0.name] as [String: Any] } ?? NSNull()]
        if let rid, !(rid is NSNull) { m["rid"] = rid }
        return m
    }

    // MARK: Media events and input

    private func serverEvents() async {
        for await e in session.serverEvents {
            switch e {
            case let .targetBitrate(target, encoder):
                trace?.write("rate", ["targetBps": target, "encoderBps": encoder])
                setEncoderBps(encoder)
            case let .frameDelivered(stream, frame):
                sink(stream)?.delivered(frame)
            case let .recoveryNeeded(stream, last):
                trace?.write("need", ["stream": Int(stream), "what": "recovery", "lastDelivered": last.map { Int($0) } ?? NSNull()])
                sink(stream)?.recoveryNeeded(lastDelivered: last)
            case let .keyframeNeeded(stream):
                trace?.write("need", ["stream": Int(stream), "what": "key"])
                sink(stream)?.keyNeeded()
            case let .input(event):
                inputQueue.async { [weak self] in self?.handleInput(event) }
            }
        }
    }

    // MARK: Trace

    /// While the session runs: the media layer's finished frame traces every 250 ms, the session's stats every second,
    /// the clock pairing every 5 s.
    private func traceLoop(_ trace: LinkTrace) async {
        var tick = 0
        trace.syncClock(mediaNowUs: session.mediaNowUs())
        while !traceStop.value, !session.isClosed() {
            try? await Task.sleep(nanoseconds: 250_000_000)
            tick += 1
            if tick % 20 == 0 { trace.syncClock(mediaNowUs: session.mediaNowUs()) }
            for t in (try? session.takeTxTraces()) ?? [] { trace.write("tx", Self.txRecord(t, trace)) }
            if tick % 4 == 0 {
                var o = Self.statsRecord(session.stats())
                if let p = session.peerStats() { o["phone"] = Self.statsRecord(p) }
                trace.write("stats", o)
            }
        }
        for t in (try? session.takeTxTraces()) ?? [] { trace.write("tx", Self.txRecord(t, trace)) }
        trace.write("end", ["records": trace.records])
    }

    static func txRecord(_ t: TxTrace, _ trace: LinkTrace) -> [String: Any] {
        func opt<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
        return ["stream": Int(t.stream), "frame": Int(t.frame), "kind": Int(t.kind), "au": Int(t.auBytes),
                "wire": Int(t.wireBytes), "dgrams": Int(t.datagrams), "parity": Int(t.parity),
                "enq": trace.mediaMs(t.enqueuedUs), "ahead": Int(t.queuedAhead), "firstOut": trace.mediaMs(t.firstOutUs),
                "lastOut": trace.mediaMs(t.lastOutUs), "retx": Int(t.retransmits), "acked": trace.mediaMs(t.deliveredUs),
                "lost": t.lost, "targetBps": t.targetBps, "pacingBps": t.pacingBps,
                "fec": LinkTrace.round3(Double(t.fecRatio)), "queueDelayMs": opt(t.queueDelayUs.map { Double($0) / 1000 }),
                "rttMs": opt(t.rttUs.map { Double($0) / 1000 })]
    }

    static func statsRecord(_ s: LinkStats) -> [String: Any] {
        func opt<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
        let m = s.media
        return ["path": "\(s.path)", "iface": "\(s.iface)", "rttMin": s.rttMinMs, "rttP50": s.rttP50Ms, "rttP90": s.rttP90Ms,
                "bytesSent": s.bytesSent, "bytesReceived": s.bytesReceived, "packetsLost": s.packetsLost,
                "dgramsSent": s.datagramsSent, "dgramsReceived": s.datagramsReceived, "dgramDrops": s.datagramDrops,
                "lossPct": opt(m.lossPct), "fecRecovered": opt(m.fecRecovered), "nackRecovered": opt(m.nackRecovered),
                "nackSent": opt(m.nackSent), "lostFrames": opt(m.lostFrames), "skippedFrames": opt(m.skippedFrames),
                "freezes": opt(m.freezeCount), "freezeMs": opt(m.freezeMs), "targetMbps": opt(m.rateTargetMbps),
                "sentMbps": opt(m.rateSentMbps), "fps": opt(m.fps), "inputP50": opt(m.inputP50Ms), "inputP90": opt(m.inputP90Ms)]
    }

    /// A phone `report`: its playout summary (`phone`), and each per-frame record it carried (`rx`: the phone's media
    /// layer, `ph`: its decoder and display), as they came (the phone's clocks).
    static func tracePhone(_ trace: LinkTrace, message o: [String: Any]) {
        var report = (o["report"] as? [String: Any]) ?? [:]
        let rx = report.removeValue(forKey: "rx") as? [[String: Any]] ?? []
        let ph = report.removeValue(forKey: "frames") as? [[String: Any]] ?? []
        report["stream"] = o["id"] ?? NSNull()
        trace.write("phone", report)
        for r in rx { trace.write("rx", r) }
        for r in ph { trace.write("ph", r) }
    }

    private func setEncoderBps(_ bps: UInt64) {
        lock.lock()
        encoderBps = bps
        let all = Array(videos.values)
        lock.unlock()
        all.forEach { $0.setBitrate(bps) }
    }

    private func sink(_ stream: UInt8) -> LinkVideoSink? {
        lock.lock(); defer { lock.unlock() }
        return videos[stream]
    }

    /// One input event through `POST /input`'s handler (control, `PointerMoveGate`, the display mapping); a refusal
    /// goes back as `input.rejected`.
    private func handleInput(_ event: YoyoLink.InputEvent) {
        let answer: (status: Int, body: [String: Any])
        var who: RemoteDevice?
        if let authority {
            if let refusal = authority.admitInput(from: device) {
                reject(event.seq, refusal.status, refusal.code, refusal.message,
                       controller: refusal.code == RemoteControl.controlledElsewhere ? authority.holder?.json : nil)
                return
            }
        } else {
            guard let d = server?.pairedDevice(device.id) else {
                reject(event.seq, 401, "unauthorized", "the device is no longer paired")
                return
            }
            who = d
        }
        // authority mode: the host decided; to the routes it is the local socket's input (no phone identity)
        let req = Router.linkRequest(method: "POST", path: "/input", headers: ["content-type": "application/json"],
                                     body: event.json, remote: who)
        if let hook = LinkHooks.input {
            answer = hook(req)
        } else {
            let r = Router.call(req)
            answer = (r.status, (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:])
        }
        guard answer.status == 200 else {
            let message = answer.body["error"] as? String ?? "refused"
            let code = answer.body["code"] as? String ?? Self.rejectCode(answer.status)
            reject(event.seq, answer.status, code, message, controller: answer.body["controllerDevice"])
            return
        }
        authority?.activity(device)
    }

    static func rejectCode(_ status: Int) -> String {
        switch status {
        case 400: "bad-event"
        case 401: "unauthorized"
        case 403: "no-permission"
        case 409: "no-control"
        case 429: "rate-limited"
        default: "error"
        }
    }

    /// `input.rejected {seq, status, code, message, controllerDevice?}` (`controllerDevice`: who controls, with
    /// `controlled-elsewhere`, as `/input`'s 409 body).
    private func reject(_ seq: UInt32, _ status: Int, _ code: String, _ message: String, controller: Any? = nil) {
        var m: [String: Any] = ["t": "input.rejected", "seq": Int(seq), "status": status, "code": code, "message": message]
        if let controller, !(controller is NSNull) { m["controllerDevice"] = controller }
        send(m)
    }

    // MARK: RPC

    /// One RPC stream through the routes, as remote access serves a paired phone: its allowlist, the session's
    /// principal as the device (the channels' paths never get here: the core answers them 404).
    func rpc(_ request: RpcRequest, _ body: Data, _ responder: RpcResponder) async {
        func fail(_ status: UInt16, _ message: String) async {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
            try? await responder.respond(status: status, headers: ["content-type": "application/json"], body: data)
        }
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        guard RemoteAccess.allowed.contains("\(request.method.uppercased()) \(path)") else {
            return await fail(404, "no such endpoint \(path)")
        }
        let who: RemoteDevice
        if authority != nil {
            who = RemoteDevice(id: device.id, name: device.name, pairedAt: Date(), lastSeenAt: nil, tokenHash: "")
        } else {
            guard let d = server?.pairedDevice(device.id) else { return await fail(401, "unauthorized") }
            who = d
        }
        let req = Router.linkRequest(method: request.method, path: request.path, headers: request.headers, body: body, remote: who)
        let transport = LinkRPCTransport(responder: responder, session: session)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            // the routes block (a stream's loop, `/events`): their own thread, as remote access's connections have
            let t = Thread {
                let conn = Connection(transport: transport)
                do {
                    try Router.handle(req, conn)
                } catch let err as HTTPError {
                    conn.error(err)
                } catch {
                    conn.error(HTTPError(500, "\(error)"))
                }
                transport.finish()
                c.resume()
            }
            t.qualityOfService = .userInteractive
            t.start()
        }
    }
}

/// An RPC stream under a `Connection`: the route's HTTP/1.1 response becomes the RPC head (status, headers) and body.
/// Blocking for the route's thread: each write waits until the link took it (a slow phone holds the writer back).
final class LinkRPCTransport: ByteTransport, @unchecked Sendable {
    let responder: RpcResponder
    let session: LinkSession
    private var parser = HTTPResponseParser()
    private var headSent = false
    private var failed = false

    init(responder: RpcResponder, session: LinkSession) {
        self.responder = responder
        self.session = session
    }

    func receive(max: Int) -> Data { Data() }  // the request's body came whole

    func send(_ data: Data) -> Bool {
        guard !failed else { return false }
        let body = parser.feed(data)
        if !headSent, let status = parser.status {
            headSent = true
            let headers = parser.headers
            guard wait({ try await self.responder.head(status: UInt16(clamping: status), headers: headers) }) else { return false }
        }
        if !body.isEmpty {
            guard wait({ try await self.responder.write(data: body) }) else { return false }
        }
        return true
    }

    func hungUp() -> Bool { failed || session.isClosed() }
    func close() {}

    /// The route is done: the body ends (FIN).
    func finish() {
        guard !failed else { return }
        _ = wait { try await self.responder.finish() }
    }

    private func wait(_ op: @escaping @Sendable () async throws -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let ok = LockedFlag()
        Task {
            do { try await op(); ok.set() } catch {}
            done.signal()
        }
        done.wait()
        if !ok.value { failed = true }
        return ok.value
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.lock(); on = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}

/// The phone's `report`s of one session (today's ack report: playout, net, audio): its network grade, logged when it
/// changes, and the stats line's tail, as the HTTP path's StreamFlow keeps them.
final class LinkReports: @unchecked Sendable {
    let label: String
    private let lock = NSLock()
    private var report: StreamPlayoutReport?
    private var audioWindow: StreamAudioReport?
    private var gradedAt = -Double.infinity
    private var loggedGrade = StreamNetQuality.Grade.unknown
    private(set) var lastQuality: StreamNetQuality?

    init(label: String) { self.label = label }

    func received(_ r: StreamPlayoutReport, rtt: StreamRTTSummary?, now: TimeInterval = StreamClock.now()) {
        lock.lock()
        report = r
        if let a = r.audio { audioWindow = audioWindow.map { $0.merged(with: a) } ?? a }
        var line: String?
        if now - gradedAt >= StreamFlow.qualityInterval {
            gradedAt = now
            let q = StreamNetQuality.grade(acks: rtt, client: r.net)
            lastQuality = q
            if q.grade != loggedGrade {
                loggedGrade = q.grade
                line = q.line(client: r.net)
            }
        }
        lock.unlock()
        if let line { log("\(label) \(line)") }
    }

    /// `phone smooth … ; audio …` since the last call (nil before the first report).
    func takeTail() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let audio = audioWindow
        audioWindow = nil
        guard let report else { return nil }
        return "phone \(report.compactLine)" + (audio.map { "; audio \($0.compactLine)" } ?? "")
    }
}
#endif
