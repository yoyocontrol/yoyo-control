import CryptoKit
import XCTest
@testable import YoyoServer

/// The signaling client (RemoteSignal.swift, docs/RELAY.md): signing in to the room with the identity key.
final class RemoteSignalTests: XCTestCase {
    func testHelloSignsTheNonceWithTheIdentityKey() throws {
        let key = P256.Signing.PrivateKey()
        let hello = try RemoteSignal.hello(nonce: "bm9uY2U=", key: key)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hello.utf8)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "hello")
        XCTAssertEqual(json["v"] as? Int, 1)
        let point = try XCTUnwrap((json["key"] as? String).flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(point, key.publicKey.x963Representation)
        let raw = try XCTUnwrap((json["sig"] as? String).flatMap { Data(base64Encoded: $0) })
        XCTAssertEqual(raw.count, 64, "r ‖ s, what WebCrypto verifies")
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: Data("yoyocontrol-relay-v1:bm9uY2U=".utf8)))
        XCTAssertFalse(key.publicKey.isValidSignature(sig, for: Data("yoyocontrol-relay-v1:other".utf8)))
    }

    func testTheRoomIsTheKeysFingerprint() throws {
        let home = NSTemporaryDirectory() + "relay-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let identity = try RemoteIdentity.loadOrCreate(directory: home)
        XCTAssertEqual("sha256:" + RemoteSignal.room(of: identity.signingKey.publicKey), identity.fingerprint)
    }

    func testTheRoomsPath() {
        let base = URL(string: "wss://signal.example.com")!
        XCTAssertEqual(RemoteSignal.roomURL(base, "ab12").absoluteString, "wss://signal.example.com/v1/mac/ab12")
        // none built in
        if ProcessInfo.processInfo.environment["YOYO_SIGNAL_URL"] == nil { XCTAssertNil(RemoteSignal.baseURL) }
    }

    func testTheDropSaysHowTheServerClosedIt() {
        XCTAssertEqual(RemoteSignal.closeDetail(code: .invalid, reason: nil), "")
        XCTAssertEqual(RemoteSignal.closeDetail(code: .internalServerError, reason: nil), ", closed 1011")
        XCTAssertEqual(RemoteSignal.closeDetail(code: .goingAway, reason: Data("replaced".utf8)), ", closed 1001 replaced")
        XCTAssertEqual(RemoteSignal.closeDetail(code: .goingAway, reason: Data()), ", closed 1001")
    }

    func testTheLinkMessage() {
        XCTAssertNil(RemoteSignal.linkMessage(nil))
        XCTAssertEqual(RemoteSignal.linkMessage(["id": "ab", "direct": ["1.2.3.4:47820"]]),
                       #"{"direct":["1.2.3.4:47820"],"id":"ab","type":"link"}"#)
    }
}
