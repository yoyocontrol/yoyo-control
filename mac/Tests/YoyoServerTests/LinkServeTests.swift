#if canImport(YoyoLink)
import XCTest
import CoreVideo
import Foundation
import Network
import YoyoLink
@testable import YoyoServer

// A LinkServer for another process's client (the iOS kit's end-to-end check, ios/YoyoKit's `LinkSmokeTests`): the real
// listener, devices, control, video loop, encoder (LTR) and link sink, with fake pictures (a scrolling desktop at
// 30 fps: an unbundled test binary has no Screen Recording) and recorded input (nothing is posted to this Mac).
// Skipped unless `YOYO_LINK_SERVE=<info.json>`: it pairs a test phone, writes `{fingerprint, binding, token}` there and
// serves for `YOYO_LINK_SERVE_SECONDS` (default 60). The server binds `YOYO_LINK_TEST_SERVER` (ip:port, default
// 127.0.0.1:0); `YOYO_LINK_SERVE_DIRECT` replaces the binding's addresses (`[::1]:47952`: a client behind netem).
//
//   cd mac && YOYO_LINK_SERVE=$TMPDIR/link-serve.json YOYO_LINK_TEST_SERVER=127.0.0.1:47942 swift test --filter LinkServeTests
//
// A browser instead (the web app, docs/LINK.md「WebRTC」): `YOYO_LINK_SERVE_WEB=<port>` serves the relay's signaling
// contract on 127.0.0.1:<port> (`POST /v1/rtc/<fp hex>` → the listener's answer, CORS open) and shows a pairing code
// instead of pairing a phone: the info file then has `pairing` = the web pairing link's fragment (`v=1&id=&n=&fp=&c=`),
// for a browser to pair over the link (`Pair <code>`). Point the web app's dev relay at it
// (`VITE_YOYO_RELAY=http://127.0.0.1:<port>`).
/// One line on stderr at once (`swift test` holds stdout back).
private func say(_ line: String) {
    FileHandle.standardError.write(Data(("link serve: " + line + "\n").utf8))
}

final class LinkServeTests: XCTestCase {
    private final class Feeder: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var isStopped: Bool { lock.withLock { stopped } }
        func stop() { lock.withLock { stopped = true } }
    }

    func testServeAPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let infoPath = env["YOYO_LINK_SERVE"], !infoPath.isEmpty else { throw XCTSkip("YOYO_LINK_SERVE not set") }
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        let home = NSTemporaryDirectory() + "link-serve-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        // the service's log (the link's sessions, `link[server]:` / `link[phone]:` lines) as it comes
        let previousSink = ScreenHost.logSink
        ScreenHost.logSink = { say("log: " + $0) }
        defer { ScreenHost.logSink = previousSink }
        let devices = RemoteDevices(path: home + "/devices.json")
        let webPort = env["YOYO_LINK_SERVE_WEB"].flatMap { UInt16($0) }
        let token = webPort == nil ? try devices.pair(code: devices.startPairing().code, id: "e2e-test-phone", name: "E2E Phone") : nil
        let identity = try RemoteIdentity.loadOrCreate(directory: home)

        let source = FakeVideoSource()
        let feeder = Feeder()
        defer { feeder.stop() }
        Thread.detachNewThread {
            var i = 0
            while !feeder.isStopped {
                source.push(fakeDesktopPicture(i * 4, width: 960, height: 600))
                i += 1
                Thread.sleep(forTimeInterval: 1.0 / 30)
            }
            source.stop()
        }
        LinkHooks.videoSource = { _ in (source, .h264, 30) }
        defer { LinkHooks.videoSource = nil; LinkHooks.input = nil }
        let applied = NSLock()
        var inputs: [String: Int] = [:]
        LinkHooks.input = { req in
            do {
                try RemoteControl.shared.admitInput(from: req.remote)
            } catch let e as HTTPError {
                return (e.status, e.extra.merging(["error": e.message]) { a, _ in a })
            } catch {
                return (500, [:])
            }
            let type = ((try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any])?["type"] as? String ?? "?"
            applied.withLock { inputs[type, default: 0] += 1 }
            return (200, ["ok": true])
        }

        let serverAddr = env["YOYO_LINK_TEST_SERVER"] ?? "127.0.0.1:0"
        let (bindIP, bindPort) = (String(serverAddr.split(separator: ":")[0]), UInt16(serverAddr.split(separator: ":")[1]) ?? 0)
        let server = LinkServer(options: LinkOptions(port: bindPort, portMapping: false, bindAddresses: [bindIP]),
                                mode: .devices(devices),
                                identity: .init(serverId: "link-serve-0001", name: "Link Serve", key: identity.signingKey),
                                keyDirectory: home)
        server.start()
        // `/events` reads the screen state (read-only: which displays, locked or not)
        let tracker = ScreenStateTracker()
        tracker.start()
        defer {
            tracker.stop()
            server.stop()
            RemoteControl.shared.releaseAny(why: "test over")
        }
        var status: [String: Any]?
        for _ in 0..<100 where status == nil {
            status = server.statusJSON
            if status == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        var binding = try XCTUnwrap(status, "the listener did not come up")
        if let direct = env["YOYO_LINK_SERVE_DIRECT"], !direct.isEmpty {
            binding["direct"] = direct.split(separator: ",").map(String.init)
        }
        var info: [String: Any] = ["fingerprint": identity.fingerprint, "binding": binding]
        var signaling: RtcSignalingServer?
        if let token { info["token"] = token }
        if let webPort {
            signaling = try RtcSignalingServer(port: webPort, server: server)
            // the code lives as long as the serving does (a fresh one each run)
            let code = devices.startPairing().code
            var c = URLComponents()
            c.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "id", value: "link-serve-0001"),
                            URLQueryItem(name: "n", value: "Link Serve"), URLQueryItem(name: "fp", value: identity.fingerprint),
                            URLQueryItem(name: "c", value: code)]
            info["pairing"] = c.percentEncodedQuery ?? ""
            info["signal"] = "http://127.0.0.1:\(webPort)"
        }
        defer { signaling?.stop() }
        try JSONSerialization.data(withJSONObject: info).write(to: URL(fileURLWithPath: infoPath))
        say("\(bindIP):\(binding["port"] ?? "?") direct \(binding["direct"] ?? []), info in \(infoPath)")

        let seconds = Double(env["YOYO_LINK_SERVE_SECONDS"] ?? "60") ?? 60
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        say("inputs applied \(applied.withLock { inputs }), devices \(devices.list.map(\.name))")
    }
}

/// The relay's browser signaling (`POST /v1/rtc/<fp>`, docs/RELAY.md「WebRTC」) on a local port, answered by `server`:
/// enough HTTP/1.1 for a browser's `fetch` (one request per connection, CORS preflight, JSON bodies).
private final class RtcSignalingServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "link-serve.signal")

    init(port: UInt16, server: LinkServer) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [queue] conn in
            conn.start(queue: queue)
            Self.read(conn, Data()) { head, body in
                let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
                let parts = line.split(separator: " ")
                let method = parts.first.map(String.init) ?? ""
                if method == "OPTIONS" { return Self.reply(conn, 204, Data()) }
                guard method == "POST", parts.count > 1, parts[1].hasPrefix("/v1/rtc/") else {
                    return Self.reply(conn, 404, Data(#"{"error":"not found"}"#.utf8))
                }
                Task {
                    do {
                        let answer = try await server.acceptRtcOffer(String(decoding: body, as: UTF8.self), sourceIP: "127.0.0.1")
                        Self.reply(conn, 200, Data(answer.utf8))
                    } catch let f as LinkRtcSignaling.Failure {
                        Self.reply(conn, f.status, (try? JSONSerialization.data(withJSONObject: ["error": f.message])) ?? Data())
                    } catch {
                        Self.reply(conn, 503, Data(#"{"error":"no answer"}"#.utf8))
                    }
                }
            }
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    /// The head and the `Content-Length` body.
    private static func read(_ conn: NWConnection, _ buffer: Data, _ done: @escaping (String, Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, end, error in
            var b = buffer
            if let data { b.append(data) }
            if let split = b.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: b[..<split.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").compactMap { h -> Int? in
                    let kv = h.split(separator: ":", maxSplits: 1)
                    return kv.count == 2 && kv[0].lowercased() == "content-length" ? Int(kv[1].trimmingCharacters(in: .whitespaces)) : nil
                }.first ?? 0
                let body = b[split.upperBound...]
                if body.count >= length { return done(head, Data(body.prefix(length))) }
            }
            if end || error != nil { return conn.cancel() }
            read(conn, b, done)
        }
    }

    private static func reply(_ conn: NWConnection, _ status: Int, _ body: Data) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\ncontent-type: application/json\r\n"
            + "access-control-allow-origin: *\r\naccess-control-allow-methods: POST, OPTIONS\r\n"
            + "access-control-allow-headers: content-type\r\ncontent-length: \(body.count)\r\nconnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}
#endif
