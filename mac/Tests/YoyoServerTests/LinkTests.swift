import XCTest
import CoreVideo
import Foundation
@testable import YoyoServer

// The link listener's parts that need no session (docs/LINK.md): the long-term-reference bookkeeping of a video
// stream, VideoToolbox's tokens and refreshes, the authority channel, the route bridge, the device's link-key binding.

final class LinkRecoveryBookTests: XCTestCase {
    typealias Book = LinkRecoveryBook<String>

    /// Sends `frame` as the loop would: plan, kind, sent.
    @discardableResult
    private func send(_ book: inout Book, _ frame: UInt32, key: Bool = false, token: String? = nil, at now: TimeInterval,
                      loop: VideoPictureKind = .delta) -> (kind: LinkFrameKind, plan: (forceKey: Bool, refresh: Bool, acknowledged: String?)) {
        let p = book.plan(at: now)
        let k = book.kind(isKey: key || p.forceKey, loopKind: loop)
        book.sent(frame: frame, kind: k, token: token, at: now)
        return (k, p)
    }

    func testAcknowledgesTheNewestReferenceInTheDeliveredChain() {
        var b = Book()
        send(&b, 1, key: true, token: "t1", at: 0)
        send(&b, 2, at: 0.02)
        send(&b, 3, token: "t3", at: 0.04)
        send(&b, 4, at: 0.06)
        XCTAssertNil(b.acknowledged)
        b.delivered(2)
        XCTAssertEqual(b.acknowledged?.token, "t1")
        b.delivered(4)
        XCTAssertEqual(b.acknowledged?.token, "t3")
        // every later encode passes it
        XCTAssertEqual(b.plan(at: 0.08).acknowledged, "t3")
    }

    func testRecoveryRefreshesFromTheAcknowledgedFrameAtOnce() {
        var b = Book()
        send(&b, 1, key: true, token: "t1", at: 0)
        send(&b, 2, token: "t2", at: 0.02)
        send(&b, 3, at: 0.04)
        b.recoveryNeeded(lastDelivered: 2)
        XCTAssertTrue(b.refreshDue(at: 0.05), "a recovery frame is not held by the key frame interval")
        let (kind, plan) = send(&b, 4, at: 0.05)
        XCTAssertFalse(plan.forceKey)
        XCTAssertTrue(plan.refresh)
        XCTAssertEqual(plan.acknowledged, "t2")
        XCTAssertEqual(kind, .recovery(base: 2))
        XCTAssertFalse(b.refreshDue(at: 0.06))
    }

    func testAnIDRInsteadOfARefreshIsAKeyFrame() {
        var b = Book()
        send(&b, 1, key: true, token: "t1", at: 0)
        b.recoveryNeeded(lastDelivered: 1)
        _ = b.plan(at: 1)
        XCTAssertEqual(b.kind(isKey: true, loopKind: .delta), .key)
    }

    func testWithoutAnAcknowledgedReferenceRecoveryIsARateLimitedKeyFrame() {
        var b = Book()
        send(&b, 1, key: true, at: 0)
        b.recoveryNeeded(lastDelivered: nil)
        XCTAssertFalse(b.refreshDue(at: 0.3), "a key frame at most every 500 ms")
        XCTAssertFalse(b.plan(at: 0.3).forceKey)
        XCTAssertTrue(b.refreshDue(at: 0.5))
        let (kind, plan) = send(&b, 2, at: 0.5)
        XCTAssertTrue(plan.forceKey)
        XCTAssertEqual(kind, .key)
        XCTAssertFalse(b.refreshDue(at: 0.6))
        b.keyNeeded()
        XCTAssertFalse(b.refreshDue(at: 0.9))
        XCTAssertTrue(b.refreshDue(at: 1.0))
    }

    func testAReferenceBeforeARecoveryGapIsNotAcknowledged() {
        var b = Book()
        send(&b, 1, key: true, token: "t1", at: 0)
        send(&b, 2, token: "t2", at: 0.02)
        send(&b, 3, token: "t3", at: 0.04)  // lost on the way
        b.recoveryNeeded(lastDelivered: 2)
        XCTAssertEqual(send(&b, 4, at: 0.06).kind, .recovery(base: 2))
        send(&b, 5, at: 0.08)
        // 5 is delivered, through 4 → 2: frame 3 (and its reference) was skipped
        b.delivered(5)
        XCTAssertEqual(b.acknowledged?.token, "t2")
        XCTAssertTrue(b.inChain(1, of: 5))
        XCTAssertFalse(b.inChain(3, of: 5))
        XCTAssertTrue(b.inChain(4, of: 5))
    }

    func testAKeyFrameDropsTheOlderReferences() {
        var b = Book()
        send(&b, 1, key: true, token: "t1", at: 0)
        b.delivered(1)
        XCTAssertEqual(b.acknowledged?.token, "t1")
        b.keyNeeded()
        send(&b, 2, at: 1)
        XCTAssertNil(b.acknowledged)
        XCTAssertTrue(b.references.isEmpty)
        XCTAssertFalse(b.inChain(1, of: 3))
    }

    func testLoopKindsMapToFrameKinds() {
        var b = Book()
        send(&b, 1, key: true, at: 0)
        XCTAssertEqual(b.kind(isKey: false, loopKind: .refine), .refine)
        XCTAssertEqual(b.kind(isKey: false, loopKind: .keepalive), .keepalive)
        XCTAssertEqual(b.kind(isKey: false, loopKind: .delta), .delta)
    }
}

final class VideoEncoderLTRTests: XCTestCase {
    /// VideoToolbox with EnableLTR (the prototype's finding, on this Mac's hardware encoder): outputs carry tokens, and
    /// a ForceLTRRefresh with an acknowledged token is a P-frame that decodes after the frames in between are dropped.
    func testTokensAndARefreshThatDecodesWithoutTheLostFrames() throws {
        for codec in VideoCodec.allCases {
            guard VideoEncoder.isAvailable(codec) else { continue }
            let enc = VideoEncoder(codec: codec, bitrate: 4_000_000, expectedFrameRate: 30, ltr: true)
            let dec = AnnexBDecoder(codec: codec)
            var tokens: [(Int, VideoLTRToken)] = []
            var units: [VideoAccessUnit] = []
            for i in 0..<24 {
                let b = try XCTUnwrap(enc.makeInputBuffer(width: 640, height: 400))
                paintDesktop(b, scroll: i * 6)
                // the phone has frames 0…9; 10… are "lost" from 12 on
                let ack = tokens.last { $0.0 <= 9 }.map { [$0.1] } ?? []
                let refresh = i == 20
                guard case let .unit(u) = enc.encodeFrame(b, time: Double(i) / 30, forceKey: i == 0,
                                                          options: VideoEncodeOptions(acknowledgedLTR: ack, forceLTRRefresh: refresh)) else {
                    return XCTFail("\(codec) frame \(i) not encoded")
                }
                if let t = u.ltrToken { tokens.append((i, t)) }
                units.append(u)
            }
            XCTAssertEqual(enc.ltrEnabled, true, "\(codec)")
            XCTAssertFalse(tokens.isEmpty, "\(codec): no long-term reference tokens")
            XCTAssertFalse(units[20].isKey, "\(codec): the refresh should be a P-frame, not an IDR")
            // the decoder sees 0…9 (with an acknowledged reference among them), then the refresh
            guard tokens.contains(where: { $0.0 <= 9 }) else { continue }
            for u in units[0...9] { XCTAssertNotNil(dec.decode(u.data)) }
            XCTAssertNotNil(dec.decode(units[20].data), "\(codec): the refresh decodes without frames 10…19")
        }
    }
}

final class LinkAuthorityTests: XCTestCase {
    private func lines(_ host: LinkAuthority.Host) -> [[String: Any]] {
        host.take(until: Date().addingTimeInterval(0.5)).compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    func testOneHostAuthorizesAndAnUnansweredHelloIsBusy() throws {
        let a = LinkAuthority(timeout: 0.3)
        var decisions: [LinkAuthority.Decision] = []
        let got = expectation(description: "busy without a host")
        a.authorize(credential: "x", device: ["id": "d1"], source: nil) { decisions.append($0); got.fulfill() }
        wait(for: [got], timeout: 1)
        XCTAssertEqual(decisions.last, .deny(code: "busy", message: "no authority is connected"))

        let host = try XCTUnwrap(a.attach())
        XCTAssertNil(a.attach(), "a second host is refused (409)")
        let accepted = expectation(description: "accepted")
        a.authorize(credential: "Bearer abc", device: ["id": "d1", "name": "Phone"], source: "10.0.0.2:5000") { d in
            decisions.append(d); accepted.fulfill()
        }
        let auth = try XCTUnwrap(lines(host).first)
        XCTAssertEqual(auth["type"] as? String, "auth")
        XCTAssertEqual(auth["credential"] as? String, "Bearer abc")
        XCTAssertEqual(auth["source"] as? String, "10.0.0.2:5000")
        try a.answer(["id": auth["id"]!, "ok": true, "principal": ["device": ["id": "u1", "name": "Ann"], "role": "owner"]])
        wait(for: [accepted], timeout: 1)
        guard case let .accept(principal, device)? = decisions.last else { return XCTFail() }
        XCTAssertEqual(device, LinkAuthority.Device(id: "u1", name: "Ann"))
        XCTAssertTrue(principal.contains("\"role\":\"owner\""))
        XCTAssertThrowsError(try a.answer(["id": auth["id"]!, "ok": false])) { XCTAssertEqual(($0 as? HTTPError)?.status, 404) }

        let late = expectation(description: "timed out")
        a.authorize(credential: "y", device: [:], source: nil) { decisions.append($0); late.fulfill() }
        wait(for: [late], timeout: 2)
        guard case .deny(code: "busy", _)? = decisions.last else { return XCTFail("\(decisions)") }
        a.detach(host)
    }

    func testControlHolderAndHostGone() throws {
        let a = LinkAuthority()
        let host = try XCTUnwrap(a.attach())
        let ann = LinkAuthority.Device(id: "u1", name: "Ann"), bob = LinkAuthority.Device(id: "u2", name: "Bob")
        var seen: [LinkAuthority.Device?] = []
        let token = a.observe { seen.append($0) }
        XCTAssertEqual(a.admitInput(from: ann)?.code, "no-control")
        a.control("take", device: ann)
        let line = try XCTUnwrap(lines(host).first)
        XCTAssertEqual(line["type"] as? String, "control")
        XCTAssertEqual(line["want"] as? String, "take")
        a.setHolder(ann)
        XCTAssertNil(a.admitInput(from: ann))
        XCTAssertEqual(a.admitInput(from: bob)?.code, "controlled-elsewhere")
        a.activity(ann)
        a.activity(ann)  // within a second: no second line
        XCTAssertEqual(lines(host).filter { $0["type"] as? String == "activity" }.count, 1)
        a.detach(host)
        XCTAssertNil(a.holder)
        XCTAssertEqual(seen, [ann, nil])
        a.removeObserver(token)
    }

    func testRoutesAreTheUnixSocketsOnlyAndNeedAuthorityMode() {
        let old = LinkAuthority.current
        defer { LinkAuthority.current = old }
        LinkAuthority.current = nil
        let r = Router.call(HTTPRequest(method: "POST", path: "/link/control", query: [:], headers: [:], body: Data("{\"holder\":null}".utf8)))
        XCTAssertEqual(r.status, 404)
        LinkAuthority.current = LinkAuthority()
        let ok = Router.call(HTTPRequest(method: "POST", path: "/link/control", query: [:], headers: [:],
                                         body: Data(#"{"holder":{"id":"u1","name":"Ann"}}"#.utf8)))
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(LinkAuthority.current?.holder?.id, "u1")
        let remote = RemoteDevice(id: "phone-1234", name: "P", pairedAt: Date(), lastSeenAt: nil, tokenHash: "")
        XCTAssertEqual(Router.call(HTTPRequest(method: "POST", path: "/link/control", query: [:], headers: [:], body: Data("{}".utf8),
                                               remote: remote)).status, 404, "never for a phone")
        XCTAssertEqual(Router.call(HTTPRequest(method: "POST", path: "/link/authority/answer", query: [:], headers: [:],
                                               body: Data(#"{"id":"nope","ok":false}"#.utf8))).status, 404)
    }
}

final class LinkHTTPTests: XCTestCase {
    func testTheResponseParserSplitsHeadAndBody() {
        var p = HTTPResponseParser()
        XCTAssertEqual(p.feed(Data("HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nConn".utf8)), Data())
        XCTAssertNil(p.status)
        let body = p.feed(Data("ection: close\r\n\r\n{\"a\":1}".utf8))
        XCTAssertEqual(p.status, 409)
        XCTAssertEqual(p.headers["content-type"], "application/json")
        XCTAssertNil(p.headers["connection"])
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(p.feed(Data("more".utf8)), Data("more".utf8))
    }

    func testCallRunsARouteAndQueriesParseAsStreamDoes() {
        let r = Router.call(HTTPRequest(method: "GET", path: "/nope", query: [:], headers: [:], body: Data()))
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(Router.queryItems("display=2&codecs=hevc,h264&cursor=client"), ["display": "2", "codecs": "hevc,h264", "cursor": "client"])
        let req = Router.linkRequest(method: "get", path: "/clipboard/file?index=3", headers: ["X-A": "b"], body: Data(), remote: nil)
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/clipboard/file")
        XCTAssertEqual(req.query["index"], "3")
        XCTAssertEqual(req.headers["x-a"], "b")
    }
}

final class LinkDeviceKeyTests: XCTestCase {
    func testTheFirstKeyBindsTheTokenUntilTheDevicePairsAgain() throws {
        let dir = NSTemporaryDirectory() + "link-devices-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let devices = RemoteDevices(path: dir + "/devices.json")
        let code = devices.startPairing()
        let token = try devices.pair(code: code.code, id: "phone-abcdef", name: "Phone")
        XCTAssertEqual(devices.authenticateLink(token: "wrong", key: "aa"), .unknownToken)
        guard case .accepted(let d) = devices.authenticateLink(token: token, key: "AABB") else { return XCTFail() }
        XCTAssertEqual(d.linkKey, "aabb")
        guard case .accepted = devices.authenticateLink(token: token, key: "aabb") else { return XCTFail() }
        guard case .otherKey = devices.authenticateLink(token: token, key: "ccdd") else { return XCTFail() }
        // kept on disk
        let again = RemoteDevices(path: dir + "/devices.json")
        guard case .otherKey = again.authenticateLink(token: token, key: "ccdd") else { return XCTFail() }
        // pairing again: a new token without a key
        let token2 = try again.pair(code: again.startPairing().code, id: "phone-abcdef", name: "Phone")
        guard case .accepted(let d2) = again.authenticateLink(token: token2, key: "ccdd") else { return XCTFail() }
        XCTAssertEqual(d2.linkKey, "ccdd")
    }

    func testPairingOverTheLinkBindsTheKeyAtOnce() throws {
        let dir = NSTemporaryDirectory() + "link-devices-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let devices = RemoteDevices(path: dir + "/devices.json")
        let token = try devices.pair(code: devices.startPairing().code, id: "browser-abcdef", name: "Safari", linkKey: "dtls-sha256:AABB")
        guard case .otherKey = devices.authenticateLink(token: token, key: "dtls-sha256:ccdd") else { return XCTFail() }
        guard case .accepted(let d) = devices.authenticateLink(token: token, key: "dtls-sha256:aabb") else { return XCTFail() }
        XCTAssertEqual(d.linkKey, "dtls-sha256:aabb")
        XCTAssertEqual(RemoteDevices(path: dir + "/devices.json").list.first?.linkKey, "dtls-sha256:aabb", "kept on disk")
    }
}
