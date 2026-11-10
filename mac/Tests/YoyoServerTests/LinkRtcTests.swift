#if canImport(YoyoLink)
import Foundation
import XCTest
import YoyoLink
@testable import YoyoServer

/// The link listener's WebRTC side (docs/LINK.md「WebRTC」): a browser's way in, here played by the core's offering
/// client (`dialRtc`). Offers go through `POST /link/rtc` on the routes (as a local program relays them) and through
/// the relay's `rtc` message; the session is a paired device's like any other.
final class LinkRtcTests: XCTestCase {
    private var home = ""
    private var server: LinkServer?

    override func tearDown() {
        server?.stop()
        RemoteControl.shared.releaseAny(why: "test over")
        if !home.isEmpty { try? FileManager.default.removeItem(atPath: home) }
    }

    /// Signals through `POST /link/rtc` (the unix socket's routes).
    private final class RouteSignaler: RtcSignaler, @unchecked Sendable {
        func signal(offerJson: String, reply: SignalReply) {
            Thread.detachNewThread {
                let r = Router.call(HTTPRequest(method: "POST", path: "/link/rtc", query: [:], headers: [:],
                                                body: Data(offerJson.utf8), remote: nil))
                if r.status == 200 {
                    try? reply.answer(answerJson: String(decoding: r.body, as: UTF8.self))
                } else {
                    try? reply.fail(message: "\(r.status) \(String(decoding: r.body, as: UTF8.self))")
                }
            }
        }
    }

    func testABrowserOverWebRTC() async throws {
        home = NSTemporaryDirectory() + "link-rtc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let devices = RemoteDevices(path: home + "/devices.json")
        let token = try devices.pair(code: devices.startPairing().code, id: "web-browser-1", name: "Safari")
        let identity = try RemoteIdentity.loadOrCreate(directory: home)

        // before the listener runs: 404
        let early = Router.call(HTTPRequest(method: "POST", path: "/link/rtc", query: [:], headers: [:], body: Data("{}".utf8), remote: nil))
        XCTAssertEqual(early.status, 404)

        let s = LinkServer(options: LinkOptions(port: 0, portMapping: false, bindAddresses: ["127.0.0.1"]),
                           mode: .devices(devices),
                           identity: .init(serverId: "rtc-test", name: "Test Mac", key: identity.signingKey), keyDirectory: home)
        server = s
        s.start()
        var status: [String: Any]?
        for _ in 0..<100 where status?["rtc"] == nil {
            status = s.statusJSON
            if status?["rtc"] == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let rtc = try XCTUnwrap(status?["rtc"] as? [String: Any], "no rtc in /status link")
        XCTAssertGreaterThan(rtc["port"] as? Int ?? 0, 0)

        // a bad offer is a 400; the routes only answer the local socket
        let bad = Router.call(HTTPRequest(method: "POST", path: "/link/rtc", query: [:], headers: [:], body: Data("{}".utf8), remote: nil))
        XCTAssertEqual(bad.status, 400)
        let wrongMethod = Router.call(HTTPRequest(method: "GET", path: "/link/rtc", query: [:], headers: [:], body: Data(), remote: nil))
        XCTAssertEqual(wrongMethod.status, 405)

        let browser = try await bindEndpoint(config: EndpointConfig(role: .client, secretKey: generateLinkKey(), port: 0, relays: [],
                                                                    portmapper: false, guard: nil, bindIps: ["127.0.0.1"],
                                                                    rtcPort: 0, rtcStunServers: [], rtcExternalOnly: false))
        defer { Task { await browser.close() } }
        func hello(_ credential: String) -> Hello {
            Hello(credential: credential, device: DeviceInfo(id: "web-browser-1", name: "Safari"), app: AppInfo(name: "uu web", version: "1"),
                  features: [])
        }
        do {
            _ = try await browser.dialRtc(signaler: RouteSignaler(), fingerprint: identity.fingerprint, hello: hello("Bearer nope"),
                                          connectTimeoutMs: 10_000)
            XCTFail("a wrong token got in")
        } catch LinkError.Denied(let code, _) {
            XCTAssertEqual(code, .unauthorized)
        }
        let session = try await browser.dialRtc(signaler: RouteSignaler(), fingerprint: identity.fingerprint,
                                                hello: hello("Bearer \(token)"), connectTimeoutMs: 10_000)
        XCTAssertEqual(session.transport(), .rtc)
        XCTAssertEqual(session.welcome().server.name, "Test Mac")
        // the token is now bound to this browser's DTLS certificate
        XCTAssertTrue(devices.list.first { $0.id == "web-browser-1" }?.linkKey?.hasPrefix("dtls-sha256:") ?? false)

        // RPC runs through the routes as on QUIC
        let r = try await session.request(request: RpcRequest(method: "GET", path: "/status", headers: [:]), body: Data())
        XCTAssertEqual(r.status(), 200)
        let body = try await r.readAll(limit: 1 << 20)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(json["displays"])

        // control messages: control.take is answered
        try await session.sendControl(json: #"{"t":"control.take","rid":1}"#)
        var granted: Any?
        for _ in 0..<50 where granted == nil {
            guard let m = await session.recvControl(),
                  let o = try? JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any] else { break }
            if o["t"] as? String == "control" { granted = o["granted"] }
        }
        XCTAssertEqual(granted as? Bool, true)
        await session.close(code: 0, reason: "done")
    }

    /// `hello.credential = "Pair <code>"` (docs/LINK.md「配对」): a browser pairs over the link itself — the same code
    /// checks as a phone's, the token bound to its DTLS certificate and handed back in `welcome.principal`.
    func testABrowserPairsOverTheLink() async throws {
        home = NSTemporaryDirectory() + "link-rtc-pair-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let devices = RemoteDevices(path: home + "/devices.json")
        let identity = try RemoteIdentity.loadOrCreate(directory: home)
        let s = LinkServer(options: LinkOptions(port: 0, portMapping: false, bindAddresses: ["127.0.0.1"]),
                           mode: .devices(devices),
                           identity: .init(serverId: "rtc-pair", name: "Pair Mac", key: identity.signingKey), keyDirectory: home)
        server = s
        s.start()
        for _ in 0..<100 where (s.statusJSON?["rtc"]) == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(s.statusJSON?["rtc"])

        let browser = try await bindEndpoint(config: EndpointConfig(role: .client, secretKey: generateLinkKey(), port: 0, relays: [],
                                                                    portmapper: false, guard: nil, bindIps: ["127.0.0.1"],
                                                                    rtcPort: 0, rtcStunServers: [], rtcExternalOnly: false))
        defer { Task { await browser.close() } }
        func dial(_ credential: String, id: String = "web-browser-2") async throws -> LinkSession {
            try await browser.dialRtc(signaler: RouteSignaler(), fingerprint: identity.fingerprint,
                                      hello: Hello(credential: credential, device: DeviceInfo(id: id, name: " Chrome\n "),
                                                   app: AppInfo(name: "uu web", version: "1"), features: []),
                                      connectTimeoutMs: 10_000)
        }
        func denied(_ credential: String, id: String = "web-browser-2") async throws -> DenyCode? {
            do {
                let session = try await dial(credential, id: id)
                await session.close(code: 0, reason: "unexpected")
                return nil
            } catch LinkError.Denied(let code, _) {
                return code
            }
        }

        // no code shown, a wrong code, a bad device id: unauthorized, nothing paired
        let none = try await denied("Pair nothing-shown")
        XCTAssertEqual(none, .unauthorized)
        let code = devices.startPairing().code
        let wrong = try await denied("Pair wrong-\(code)")
        XCTAssertEqual(wrong, .unauthorized)
        let badId = try await denied("Pair \(code)", id: "short")
        XCTAssertEqual(badId, .unauthorized)
        XCTAssertTrue(devices.isEmpty)

        let session = try await dial("Pair \(code)")
        let principal = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(session.welcome().principalJson.utf8)) as? [String: Any])
        let token = try XCTUnwrap(principal["token"] as? String)
        XCTAssertEqual(principal["server"] as? [String: String], ["id": "rtc-pair", "name": "Pair Mac"])
        XCTAssertEqual(principal["device"] as? [String: String], ["id": "web-browser-2", "name": "Chrome"])
        let paired = try XCTUnwrap(devices.list.first { $0.id == "web-browser-2" })
        XCTAssertEqual(paired.name, "Chrome")
        XCTAssertTrue(paired.linkKey?.hasPrefix("dtls-sha256:") ?? false, "the token is bound to the browser's certificate")
        XCTAssertNil(devices.pairingCode, "the code is used up")
        // the session goes on as the new device
        let r = try await session.request(request: RpcRequest(method: "GET", path: "/status", headers: [:]), body: Data())
        XCTAssertEqual(r.status(), 200)
        await session.close(code: 0, reason: "done")

        // the code worked once; the token is the credential from now on
        let again = try await denied("Pair \(code)")
        XCTAssertEqual(again, .unauthorized)
        let next = try await dial("Bearer \(token)")
        let nextPrincipal = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(next.welcome().principalJson.utf8)) as? [String: Any])
        XCTAssertNil(nextPrincipal["token"], "the token is only handed out when pairing")
        await next.close(code: 0, reason: "done")
    }

    /// `GET /remote`'s `pairing.webUrl` (docs/REMOTE.md「配对」): the browser's link, all in the fragment, only while a
    /// browser can get in (the link takes WebRTC and the Mac is registered at a signaling server).
    func testTheWebPairingLinkNeedsWebRTCAndTheSignalingServer() throws {
        home = NSTemporaryDirectory() + "link-rtc-web-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        setenv("YOYO_WEBAPP_URL", "http://localhost:5173/app", 1)
        defer { unsetenv("YOYO_WEBAPP_URL") }
        try Data(#"{"enabled": true, "direct": false}"#.utf8).write(to: URL(fileURLWithPath: home + "/remote.json"))
        func start(signal: URL?) -> RemoteAccess {
            let access = RemoteAccess(home: home, control: RemoteControl(idle: 600))
            access.linkOptions = LinkOptions(port: 0, portMapping: false, bindAddresses: ["127.0.0.1"])
            access.signalURL = signal
            access.start()
            _ = access.startPairing()
            let deadline = Date().addingTimeInterval(10)
            while ((access.json["link"] as? [String: Any])?["rtc"]) == nil && Date() < deadline { usleep(20_000) }
            XCTAssertNotNil((access.json["link"] as? [String: Any])?["rtc"], "the link takes WebRTC")
            return access
        }
        let alone = start(signal: nil)
        XCTAssertNil((alone.json["pairing"] as? [String: Any])?["webUrl"], "no signaling server: a browser has no way in")
        alone.stop()

        // the signaling server goes nowhere: only that the Mac would register there matters here
        let access = start(signal: URL(string: "ws://127.0.0.1:9")!)
        defer { access.stop() }
        func pairing() -> [String: Any]? { access.json["pairing"] as? [String: Any] }
        let raw = try XCTUnwrap(pairing()?["webUrl"] as? String)
        XCTAssertTrue(raw.hasPrefix("http://localhost:5173/app/pair#v=1&"), raw)
        var parts = URLComponents()
        parts.percentEncodedQuery = String(raw[raw.index(after: raw.firstIndex(of: "#")!)...])
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(Set(items.keys), ["v", "id", "n", "fp", "c"])
        XCTAssertEqual(items["c"], pairing()?["code"] as? String)
        XCTAssertEqual(items["fp"], access.json["fingerprint"] as? String)
        XCTAssertEqual(items["id"], access.json["serverId"] as? String)
    }

    /// The signaling server's `rtc` message → `rtc-answer` / `rtc-error` (docs/RELAY.md「WebRTC」).
    func testSignalRtcReplies() async throws {
        let id = String(repeating: "ab", count: 16)
        let ok = await RemoteSignal.rtcReply(id: id, offer: ["v": 1, "offer": "v=0"], from: "198.51.100.7") { offer, from in
            XCTAssertEqual(from, "198.51.100.7")
            XCTAssertTrue(offer.contains("\"offer\""))
            return #"{"v":1,"answer":"v=0"}"#
        }
        let okJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(ok.utf8)) as? [String: Any])
        XCTAssertEqual(okJSON["type"] as? String, "rtc-answer")
        XCTAssertEqual(okJSON["id"] as? String, id)
        XCTAssertEqual((okJSON["answer"] as? [String: Any])?["answer"] as? String, "v=0")

        let refused = await RemoteSignal.rtcReply(id: id, offer: ["v": 1], from: nil) { _, _ in
            throw LinkRtcSignaling.Failure(status: 429, message: "blocked")
        }
        let refusedJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(refused.utf8)) as? [String: Any])
        XCTAssertEqual(refusedJSON["type"] as? String, "rtc-error")
        XCTAssertEqual(refusedJSON["status"] as? Int, 429)
        XCTAssertEqual(refusedJSON["message"] as? String, "blocked")

        let notRunning = await RemoteSignal.rtcReply(id: id, offer: ["v": 1], from: nil, answerer: nil)
        XCTAssertTrue(notRunning.contains(#""status":404"#), notRunning)
        let notAnObject = await RemoteSignal.rtcReply(id: id, offer: "v=0", from: nil) { _, _ in "{}" }
        XCTAssertTrue(notAnObject.contains(#""status":400"#), notAnObject)
    }

    func testRtcOptions() {
        XCTAssertEqual(LinkOptions().rtcPort(forLinkPort: 47_820), 47_821)
        XCTAssertEqual(LinkOptions().rtcPort(forLinkPort: 0), 0)
        XCTAssertEqual(LinkOptions(rtcPort: 50_000).rtcPort(forLinkPort: 47_820), 50_000)
        XCTAssertFalse(LinkOptions.fromEnvironment(["YOYO_LINK_RTC_PORT": "off"]).rtc)
        XCTAssertEqual(LinkOptions.fromEnvironment(["YOYO_LINK_RTC_PORT": "40001"]).rtcPort, 40_001)
    }
}
#endif
