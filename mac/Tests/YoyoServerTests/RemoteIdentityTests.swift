import CryptoKit
import XCTest
@testable import YoyoServer

/// Remote access's identity (RemoteIdentity.swift): made once, reused, a new one only when the key is gone.
final class RemoteIdentityTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "identity-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testMadeOnceThenReused() throws {
        let first = try RemoteIdentity.loadOrCreate(directory: dir)
        XCTAssertTrue(first.fingerprint.hasPrefix("sha256:"))
        XCTAssertEqual(first.fingerprint.count, 7 + 64)
        XCTAssertEqual(try RemoteIdentity.loadOrCreate(directory: dir).fingerprint, first.fingerprint)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/" + RemoteIdentity.keyFile)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testANewKeyWhenTheKeyIsGoneOrGarbage() throws {
        let old = try RemoteIdentity.loadOrCreate(directory: dir)
        try Data("junk".utf8).write(to: URL(fileURLWithPath: dir + "/" + RemoteIdentity.keyFile))
        XCTAssertNotEqual(try RemoteIdentity.loadOrCreate(directory: dir).fingerprint, old.fingerprint)
    }

    func testTheFingerprintIsThePublicKeys() throws {
        let id = try RemoteIdentity.loadOrCreate(directory: dir)
        XCTAssertEqual(RemoteIdentity.fingerprint(ofKey: id.signingKey.publicKey.x963Representation), id.fingerprint)
        let stored = try Data(contentsOf: URL(fileURLWithPath: dir + "/" + RemoteIdentity.keyFile))
        XCTAssertEqual(try P256.Signing.PrivateKey(x963Representation: stored).publicKey.x963Representation,
                       id.signingKey.publicKey.x963Representation, "the X9.63 key on disk")
    }
}
