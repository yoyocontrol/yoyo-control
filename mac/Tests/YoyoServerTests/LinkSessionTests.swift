#if canImport(YoyoLink)
import XCTest
import CoreVideo
import Foundation
import YoyoLink
@testable import YoyoServer

// The link listener end to end on loopback (docs/LINK.md): a YoyoLink client with a paired token dials a LinkServer,
// opens video (fake pictures through the real video loop, encoder and link sink) and decodes the frames, sends input
// (refused without control, through after control.take), makes RPC calls (/status, /clipboard; the allowlist) and
// receives audio packets. No capture, no posted input, no sound capture (LinkHooks).
//
// Through an impairment proxy (uu-link-netem, docs/LINK.md「测试工具」): the server binds `YOYO_LINK_TEST_SERVER`
// (ip:port, default 127.0.0.1:0), the client binds `YOYO_LINK_TEST_CLIENT_BIND` (default 127.0.0.1) and dials
// `YOYO_LINK_TEST_DIAL` (default the server); `YOYO_LINK_TEST_SECONDS` of video (default 3). Every run prints a
// `link test:` summary.

/// The client side's reading of a session: control messages by type, media events.
private final class ClientSide: @unchecked Sendable {
    let session: LinkSession
    private let cond = NSCondition()
    private var messages: [LinkControlMessage] = []
    private(set) var frames = 0
    private(set) var decoded = 0
    private(set) var decodeFailures = 0
    private(set) var kinds: [String: Int] = [:]
    private(set) var audio = 0
    private(set) var cursors = 0
    private(set) var acked: UInt32 = 0
    private var frameLatencies: [Double] = []
    let decoder = AnnexBDecoder(codec: .h264)

    init(_ session: LinkSession) {
        self.session = session
        Task {
            for await m in session.controlMessages {
                self.received(m)
                if m.type == "video.opened" { session.openVideo(stream: 1) }
                if m.type == "audio.opened" { session.openAudio(stream: 2) }
            }
        }
        Task {
            for await e in session.clientEvents { self.handle(e) }
        }
    }

    private func received(_ m: LinkControlMessage) {
        cond.lock(); messages.append(m); cond.broadcast(); cond.unlock()
    }

    private func handle(_ e: ClientMediaEvent) {
        switch e {
        case .frame(let f):
            let ok = decoder.decode(f.au) != nil
            try? session.frameDecoded(stream: f.stream, frame: f.frame, ok: ok)
            cond.lock()
            frames += 1
            if ok { decoded += 1 } else { decodeFailures += 1 }
            kinds["\(f.meta.kind)", default: 0] += 1
            frameLatencies.append(Date().timeIntervalSince1970 * 1000 - Double(f.meta.captureUs) / 1000)
            cond.broadcast()
            cond.unlock()
        case .audio:
            cond.lock(); audio += 1; cond.broadcast(); cond.unlock()
        case .cursor:
            cond.lock(); cursors += 1; cond.unlock()
        case .inputAcked(let through):
            cond.lock(); acked = max(acked, through); cond.broadcast(); cond.unlock()
        case .inputFailed:
            break
        }
    }

    /// The first control message of `type` (matching `where`) within `timeout`, taken off the list.
    func message(_ type: String, timeout: TimeInterval = 5, where match: ([String: Any]) -> Bool = { _ in true }) -> [String: Any]? {
        let until = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while true {
            if let i = messages.firstIndex(where: { $0.type == type && match($0.object) }) {
                return messages.remove(at: i).object
            }
            guard cond.wait(until: until) else { return nil }
        }
    }

    func wait(timeout: TimeInterval, until done: (ClientSide) -> Bool) -> Bool {
        let until = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while !done(self) { guard cond.wait(until: until) else { return done(self) } }
        return true
    }

    var latencyP50: Double {
        cond.lock(); defer { cond.unlock() }
        let s = frameLatencies.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
}

/// Pictures into a FakeVideoSource at `fps` (a scrolling desktop) until stopped.
private final class PictureFeeder: @unchecked Sendable {
    private let flag = LockedFlag()
    func start(_ source: FakeVideoSource, fps: Double) {
        Thread.detachNewThread { [flag] in
            var i = 0
            while !flag.value {
                source.push(fakeDesktopPicture(i * 4, width: 960, height: 600))
                i += 1
                Thread.sleep(forTimeInterval: 1 / fps)
            }
            source.stop()
        }
    }
    func stop() { flag.set() }
}

final class LinkSessionTests: XCTestCase {
    private var home = ""
    private var server: LinkServer?

    override func tearDown() {
        LinkHooks.videoSource = nil
        LinkHooks.audioClient = nil
        LinkHooks.input = nil
        server?.stop()
        RemoteControl.shared.releaseAny(why: "test over")
        if !home.isEmpty { try? FileManager.default.removeItem(atPath: home) }
    }

    private func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    func testAPairedPhoneOverTheLink() async throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        home = NSTemporaryDirectory() + "link-session-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let devices = RemoteDevices(path: home + "/devices.json")
        let token = try devices.pair(code: devices.startPairing().code, id: "phone-link-test", name: "Link Test Phone")
        let identity = try RemoteIdentity.loadOrCreate(directory: home)

        // the hooks: fake pictures, fake sound, recorded input (after the real control check)
        let source = FakeVideoSource()
        let feeder = PictureFeeder()
        defer { feeder.stop() }
        LinkHooks.videoSource = { _ in (source, .h264, 30) }
        let audioClient = AudioCapture.Client(cookie: nil, videoOffset: AudioVideoOffset(tapToSpeakerMs: 10, captureLatencyMs: 20))
        LinkHooks.audioClient = { audioClient }
        let inputs = NSCondition()
        var applied: [[String: Any]] = []
        LinkHooks.input = { req in
            do {
                try RemoteControl.shared.admitInput(from: req.remote)
            } catch let e as HTTPError {
                return (e.status, e.extra.merging(["error": e.message]) { a, _ in a })
            } catch {
                return (500, [:])
            }
            inputs.lock()
            applied.append((try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:])
            inputs.broadcast()
            inputs.unlock()
            return (200, ["ok": true])
        }

        let serverAddr = env("YOYO_LINK_TEST_SERVER") ?? "127.0.0.1:0"
        let (bindIP, bindPort) = (String(serverAddr.split(separator: ":")[0]), UInt16(serverAddr.split(separator: ":")[1]) ?? 0)
        let traceDir = home + "/link-trace"
        let options = LinkOptions(port: bindPort, portMapping: false, bindAddresses: [bindIP], traceDirectory: traceDir)
        let s = LinkServer(options: options, mode: .devices(devices),
                           identity: .init(serverId: "test-server-id-0001", name: "Test Mac", key: identity.signingKey),
                           keyDirectory: home)
        server = s
        s.start()
        var status: [String: Any]?
        for _ in 0..<100 where status == nil {
            status = s.statusJSON
            if status == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let link = try XCTUnwrap(status, "the listener did not come up")
        let port = try XCTUnwrap(link["port"] as? Int)
        let binding = Binding(id: link["id"] as! String, key: link["key"] as! String, sig: link["sig"] as! String)
        XCTAssertEqual(try verifyBinding(binding: binding, fingerprint: identity.fingerprint), binding.id)
        XCTAssertEqual(FileManager.default.contents(atPath: home + "/link-key")?.count, 32)
        let keyMode = (try FileManager.default.attributesOfItem(atPath: home + "/link-key")[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(keyMode, 0o600)

        let clientBind = env("YOYO_LINK_TEST_CLIENT_BIND") ?? "127.0.0.1"
        let dialAddr = env("YOYO_LINK_TEST_DIAL") ?? "\(bindIP):\(port)"
        func client() async throws -> LinkEndpoint {
            try await bindEndpoint(config: EndpointConfig(role: .client, secretKey: generateLinkKey(), port: 0, relays: [],
                                                          portmapper: false, guard: nil, bindIps: [clientBind]))
        }
        let target = DialTarget(id: binding.id, relays: [], direct: [dialAddr])
        func hello(_ credential: String) -> Hello {
            Hello(credential: credential, device: DeviceInfo(id: "phone-link-test", name: "Link Test Phone"),
                  app: AppInfo(name: "link-test", version: "1"), features: [])
        }

        // a wrong token is unauthorized
        let stranger = try await client()
        do {
            _ = try await stranger.dial(target: target, hello: hello("Bearer nope"), connectTimeoutMs: 10_000)
            XCTFail("a wrong token got in")
        } catch LinkError.Denied(let code, _) {
            XCTAssertEqual(code, .unauthorized)
        }
        await stranger.close()

        let phoneEndpoint = try await client()
        let t0 = Date()
        let session = try await phoneEndpoint.dial(target: target, hello: hello("Bearer \(token)"), connectTimeoutMs: 10_000)
        let welcomeMs = Date().timeIntervalSince(t0) * 1000
        let principal = session.principal as? [String: Any]
        XCTAssertEqual((principal?["device"] as? [String: Any])?["id"] as? String, "phone-link-test")
        XCTAssertEqual(devices.list.first?.linkKey, phoneEndpoint.id(), "the token is bound to this installation's key")
        let phone = ClientSide(session)

        // the same token from another installation (another key) is refused
        let other = try await client()
        do {
            _ = try await other.dial(target: target, hello: hello("Bearer \(token)"), connectTimeoutMs: 10_000)
            XCTFail("another key got in with the bound token")
        } catch LinkError.Denied(let code, _) {
            XCTAssertEqual(code, .unauthorized)
        }
        await other.close()

        // RPC: the routes, remote access's allowlist
        var rpcMs: [Double] = []
        for _ in 0..<5 {
            let r0 = Date()
            let st = try await session.request(request: RpcRequest("GET", "/status"), body: Data())
            let body = try await st.readAll(limit: 1 << 20)
            rpcMs.append(Date().timeIntervalSince(r0) * 1000)
            XCTAssertEqual(st.status(), 200)
            let json = try XCTUnwrap((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            XCTAssertEqual(json["app"] as? String, "YoyoControl")
            XCTAssertEqual((json["link"] as? [String: Any])?["id"] as? String, binding.id)
        }
        let clip = try await session.request(request: RpcRequest("GET", "/clipboard?text=0"), body: Data())
        _ = try await clip.readAll(limit: 1 << 20)
        XCTAssertTrue([200, 503].contains(clip.status()), "\(clip.status())")
        let windows = try await session.request(request: RpcRequest("GET", "/windows"), body: Data())
        XCTAssertEqual(windows.status(), 404, "not on the remote allowlist")
        let stream = try await session.request(request: RpcRequest("GET", "/stream"), body: Data())
        XCTAssertEqual(stream.status(), 404, "a channel, not an RPC")

        // input: refused without control, applied with it
        _ = try session.sendInput(kind: .discrete, json: Data(#"{"type":"click","x":0.5,"y":0.5}"#.utf8))
        let rejected = try XCTUnwrap(phone.message("input.rejected"))
        XCTAssertEqual(rejected["status"] as? Int, 409)
        XCTAssertEqual(rejected["code"] as? String, "no-control")
        // what a phone's report looks like (`{t, id, report}`): graded, never answered; its per-frame records go to the trace
        try await session.send(controlObject: ["t": "report", "id": 1, "report": [
            "fps": 60, "net": ["iface": "wifi"], "rx": [["frame": 1, "fate": "delivered"]], "frames": [["frame": 1, "shownMs": 9.5]],
        ]])
        try await session.send(controlObject: ["t": "control.take", "rid": 7])
        let granted = try XCTUnwrap(phone.message("control") { $0["rid"] as? Int == 7 })
        XCTAssertEqual(granted["granted"] as? Bool, true)
        XCTAssertEqual((granted["holder"] as? [String: Any])?["id"] as? String, "phone-link-test")
        var inputMs: [Double] = []
        for i in 0..<10 {
            let i0 = Date()
            let seq = try session.sendInput(kind: .discrete, json: Data(#"{"type":"key","key":"a","n":\#(i)}"#.utf8))
            XCTAssertTrue(phone.wait(timeout: 3) { $0.acked >= seq }, "input \(seq) not acked")
            inputMs.append(Date().timeIntervalSince(i0) * 1000)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try session.sendInput(kind: .move, json: Data(#"{"type":"move","x":0.25,"y":0.75}"#.utf8))
        func waitApplied() -> (keys: [Int], moves: Int) {
            inputs.lock()
            defer { inputs.unlock() }
            let until = Date().addingTimeInterval(3)
            while applied.count < 11, inputs.wait(until: until) {}
            return (applied.compactMap { $0["n"] as? Int }, applied.filter { $0["type"] as? String == "move" }.count)
        }
        let (appliedKeys, moves) = waitApplied()
        XCTAssertEqual(appliedKeys, Array(0..<10), "discrete input exactly once, in order")
        XCTAssertEqual(moves, 1)

        // video: frames through the loop, the encoder (LTR on) and the sink; the client decodes them
        feeder.start(source, fps: 30)
        try await session.send(controlObject: ["t": "video.open", "id": 1, "query": "codecs=h264&fps=30&cursor=client"])
        let opened = try XCTUnwrap(phone.message("video.opened"))
        XCTAssertEqual(opened["codec"] as? String, "h264")
        XCTAssertEqual((opened["headers"] as? [String: Any])?["X-Stream-Codec"] as? String, "h264")
        let seconds = Double(env("YOYO_LINK_TEST_SECONDS") ?? "3") ?? 3
        let v0 = Date()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        let videoSeconds = Date().timeIntervalSince(v0)
        XCTAssertTrue(phone.wait(timeout: 5) { $0.decoded >= 20 }, "only \(phone.decoded) frames decoded")
        XCTAssertGreaterThan(phone.kinds["key", default: 0], 0)

        // audio
        try await session.send(controlObject: ["t": "audio.open", "id": 2, "query": ""])
        let aopened = try XCTUnwrap(phone.message("audio.opened"))
        XCTAssertEqual(aopened["codec"] as? String, "opus")
        XCTAssertEqual(aopened["videoOffsetMs"] as? Int, 30)
        for i in 0..<25 {
            audioClient.queue.push(AudioPacket(index: Int64(i), timeMs: Int64(Date().timeIntervalSince1970 * 1000), data: Data(repeating: UInt8(i), count: 120),
                                               silent: false))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(phone.wait(timeout: 3) { $0.audio >= 20 }, "only \(phone.audio) audio packets")

        try await session.send(controlObject: ["t": "video.close", "id": 1])
        XCTAssertNotNil(phone.message("video.closed") { $0["id"] as? Int == 1 })
        try await session.send(controlObject: ["t": "audio.close", "id": 2])
        XCTAssertNotNil(phone.message("audio.closed") { $0["id"] as? Int == 2 })

        let stats = session.stats()
        func p(_ v: [Double], _ q: Double) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * q))] }
        print(String(format: "link test: welcome %.1f ms; rpc /status p50 %.2f ms; input ack p50 %.1f / p90 %.1f ms; "
                     + "video %d frames in %.1f s (%.1f fps), %d decoded, %d decode failures, kinds %@, capture→decode p50 %.1f ms; "
                     + "audio %d packets; path %@ rtt %.1f/%.1f ms",
                     welcomeMs, p(rpcMs, 0.5), p(inputMs, 0.5), p(inputMs, 0.9), phone.frames, videoSeconds,
                     Double(phone.frames) / max(videoSeconds, 0.1), phone.decoded, phone.decodeFailures, "\(phone.kinds)", phone.latencyP50,
                     phone.audio, "\(stats.path)", stats.rttMinMs, stats.rttP50Ms))
        print("link test: \(stats.line)")
        await session.close(.normal, reason: "test over")
        await phoneEndpoint.close()

        // the session's trace: one JSON object per line, every kind of record there
        var records: [[String: Any]] = []
        for _ in 0..<150 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: traceDir)) ?? []
            guard let name = files.first(where: { $0.hasSuffix(".jsonl") }),
                  let text = try? String(contentsOfFile: traceDir + "/" + name, encoding: .utf8) else { continue }
            records = text.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
            if records.contains(where: { $0["t"] as? String == "end" }) {
                // YOYO_LINK_TEST_TRACE_COPY=<path>: keep it (scripts/link-trace.py)
                if let copy = env("YOYO_LINK_TEST_TRACE_COPY") { try? FileManager.default.copyItem(atPath: traceDir + "/" + name, toPath: copy) }
                break
            }
        }
        let types = Set(records.compactMap { $0["t"] as? String })
        for t in ["session", "clock", "enc", "tx", "stats", "phone", "rx", "ph", "rate", "end"] {
            XCTAssertTrue(types.contains(t), "no \(t) record in the trace (\(types.sorted()))")
        }
        let tx = records.filter { $0["t"] as? String == "tx" }
        XCTAssertTrue(tx.contains { $0["acked"] is Double && $0["lastOut"] is Double }, "no acknowledged frame in \(tx.prefix(2))")
        let enc = records.filter { $0["t"] as? String == "enc" }
        XCTAssertTrue(enc.allSatisfy { $0["bytes"] is Int && $0["encMs"] is Double && $0["frame"] is Int })
        print("link test: trace \(records.count) records, \(enc.count) enc, \(tx.count) tx")
    }

    /// The router forwards a public UDP port to the listener (the TLS door's port mapper, UDP): the public address is
    /// in the binding's `direct` (the core advertises it), and goes again when the listener stops.
    func testThePublicMappingIsAdvertisedAndDeletedOnStop() async throws {
        home = NSTemporaryDirectory() + "link-portmap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let identity = try RemoteIdentity.loadOrCreate(directory: home)
        let router = FakeRouter(upnp: true)
        let s = LinkServer(options: LinkOptions(port: 0, portMapping: true, bindAddresses: ["127.0.0.1"]),
                           mode: .devices(RemoteDevices(path: home + "/devices.json")),
                           identity: .init(serverId: "portmap-test", name: "Test Mac", key: identity.signingKey), keyDirectory: home)
        s.portMapNetwork = router
        server = s
        s.start()
        var port = 0
        var direct: [String] = []
        let until = Date().addingTimeInterval(10)
        while Date() < until {
            if let j = s.statusJSON {
                port = j["port"] as? Int ?? 0
                direct = j["direct"] as? [String] ?? []
                if direct.contains("93.184.216.34:\(port)") { break }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(direct.contains("93.184.216.34:\(port)"), "\(direct)")
        XCTAssertNotNil(router.upnpTable["UDP:\(port)"])
        XCTAssertEqual(s.mappingJSON["status"] as? String, "mapped")
        s.stop()
        server = nil
        let gone = Date().addingTimeInterval(5)
        while !router.upnpTable.isEmpty, Date() < gone { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(router.upnpTable.isEmpty, "stop deletes the mapping")
    }

    /// Authority mode: the host's answer lets the session in (its principal in `welcome`), `control.take` reaches the
    /// host, `POST /link/control` decides who may send input.
    func testAuthorityMode() async throws {
        home = NSTemporaryDirectory() + "link-authority-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let identity = try RemoteIdentity.loadOrCreate(directory: home)
        let authority = LinkAuthority()
        let previous = LinkAuthority.current
        LinkAuthority.current = authority
        defer { LinkAuthority.current = previous }
        let inputs = LockedFlag()
        LinkHooks.input = { req in
            XCTAssertNil(req.remote, "the host decided: the routes see the local socket's input")
            inputs.set()
            return (200, ["ok": true])
        }
        let s = LinkServer(options: LinkOptions(port: 0, authority: true, portMapping: false, bindAddresses: ["127.0.0.1"]),
                           mode: .authority(authority),
                           identity: .init(serverId: "authority-test", name: "Test Mac", key: identity.signingKey), keyDirectory: home)
        server = s
        s.start()
        var link: [String: Any]?
        for _ in 0..<100 where link == nil {
            link = s.statusJSON
            if link == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let status = try XCTUnwrap(link)
        let target = DialTarget(id: status["id"] as! String, relays: [], direct: ["127.0.0.1:\(status["port"] as! Int)"])
        let ep = try await bindEndpoint(config: EndpointConfig(role: .client, secretKey: generateLinkKey(), port: 0, relays: [],
                                                               portmapper: false, guard: nil, bindIps: ["127.0.0.1"]))
        let hello = Hello(credential: "host-ticket-42", device: DeviceInfo(id: "dev-1", name: "Phone"),
                          app: AppInfo(name: "link-test", version: "1"), features: [])

        // no host yet: busy
        do {
            _ = try await ep.dial(target: target, hello: hello, connectTimeoutMs: 10_000)
            XCTFail("in without a host")
        } catch LinkError.Denied(let code, _) {
            XCTAssertEqual(code, .busy)
        }

        let host = try XCTUnwrap(authority.attach())
        func line(_ type: String) -> [String: Any]? {
            let until = Date().addingTimeInterval(5)
            while Date() < until {
                for data in host.take(until: Date().addingTimeInterval(0.2)) {
                    if let l = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], l["type"] as? String == type { return l }
                }
            }
            return nil
        }
        // the host answers the auth line (from another thread, as a local program's POST would)
        Thread.detachNewThread {
            guard let auth = line("auth") else { return }
            XCTAssertEqual(auth["credential"] as? String, "host-ticket-42")
            let r = Router.call(HTTPRequest(method: "POST", path: "/link/authority/answer", query: [:], headers: [:],
                                            body: try! JSONSerialization.data(withJSONObject: [
                                                "id": auth["id"]!, "ok": true,
                                                "principal": ["device": ["id": "user-7", "name": "Ann's phone"], "role": "guest"],
                                            ])))
            XCTAssertEqual(r.status, 200)
        }
        let session = try await ep.dial(target: target, hello: hello, connectTimeoutMs: 10_000)
        XCTAssertEqual((session.principal as? [String: Any])?["role"] as? String, "guest")
        let phone = ClientSide(session)
        XCTAssertNotNil(line("session"))

        _ = try session.sendInput(kind: .discrete, json: Data(#"{"type":"click","x":0.5,"y":0.5}"#.utf8))
        XCTAssertEqual(phone.message("input.rejected")?["code"] as? String, "no-control")
        try await session.send(controlObject: ["t": "control.take", "rid": "r1"])
        let want = try XCTUnwrap(line("control"))
        XCTAssertEqual(want["want"] as? String, "take")
        XCTAssertEqual((want["device"] as? [String: Any])?["id"] as? String, "user-7")
        let r = Router.call(HTTPRequest(method: "POST", path: "/link/control", query: [:], headers: [:],
                                        body: Data(#"{"holder":{"id":"user-7","name":"Ann's phone"}}"#.utf8)))
        XCTAssertEqual(r.status, 200)
        let granted = try XCTUnwrap(phone.message("control") { $0["rid"] as? String == "r1" })
        XCTAssertEqual(granted["granted"] as? Bool, true)
        let seq = try session.sendInput(kind: .discrete, json: Data(#"{"type":"click","x":0.5,"y":0.5}"#.utf8))
        XCTAssertTrue(phone.wait(timeout: 3) { $0.acked >= seq })
        let until = Date().addingTimeInterval(2)
        while !inputs.value, Date() < until { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(inputs.value)
        XCTAssertNotNil(line("activity"))

        // the host goes: nobody holds control, the session keeps running
        authority.detach(host)
        let released = try XCTUnwrap(phone.message("control") { $0["holder"] is NSNull })
        XCTAssertEqual(released["granted"] as? Bool, false)
        XCTAssertFalse(session.isClosed())
        await session.close(.normal, reason: "test over")
        await ep.close()
    }
}
#endif
