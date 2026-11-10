import CryptoKit
import Foundation
import Testing
@testable import YoyoConnect
@testable import YoyoDirect
#if canImport(YoyoLinkClient)
import YoyoLink
@testable import YoyoLinkClient
#endif

/// A computer's uu Link binding: read from `/status` / the relay leniently, remembered with the Mac, and — with the
/// link's core — checked against the pinned fingerprint before any dial (a mismatch is a hard failure, never dialed).
@Suite("Link binding")
struct LinkBindingTests {
    @Test func theBindingIsReadLeniently() throws {
        let b = try #require(ConnectLinkBinding(json: [
            "id": "ab", "key": "Kk==", "sig": "Ss==", "port": 47820, "relays": ["https://r1.example", 3],
            "direct": ["192.168.50.10:47820", "[fd00::1]:47820", ["host": "93.184.216.34", "port": 47820], "nonsense", "10.0.0.1:0"],
        ]))
        #expect(b.port == 47820 && b.relays == ["https://r1.example"])
        #expect(b.direct == ["192.168.50.10:47820", "[fd00::1]:47820", "93.184.216.34:47820"])
        #expect(ConnectLinkBinding(json: ["id": "ab", "key": "Kk=="]) == nil, "without its signature it isn't one")
        #expect(ConnectLinkBinding(json: NSNull()) == nil && ConnectLinkBinding(json: nil) == nil)
        #expect(ConnectLinkBinding.socketAddress(host: "fe80::1", port: 1) == "[fe80::1]:1")
        #expect(ConnectLinkBinding.socketAddress(host: "mac.local", port: 1) == nil, "addresses only")
    }

    @Test func theMacRemembersItsBinding() throws {
        var mac = YoyoMac(id: "m", name: "Mac", addresses: ["192.168.50.10"], fingerprint: "sha256:00", token: "t")
        let old = try JSONEncoder().encode(mac)
        #expect(try JSONDecoder().decode(YoyoMac.self, from: old).link == nil, "a record from before has none")
        mac.link = ConnectLinkBinding(id: "ab", key: "k", sig: "s", port: 47820)
        let back = try JSONDecoder().decode(YoyoMac.self, from: JSONEncoder().encode(mac))
        #expect(back.link == mac.link)
        // `/status`'s link goes into the Mac
        #expect(YoyoClient.updated(mac, status: ["ok": true, "link": ["id": "cd", "key": "k", "sig": "s", "port": 1]]).link?.id == "cd")
    }

    #if canImport(YoyoLinkClient)
    /// A computer's identity (X9.63 private key: 04‖X‖Y‖D) and a binding it signed over a fresh link key.
    static func signed() throws -> (fp: String, binding: ConnectLinkBinding) {
        let identity = P256.Signing.PrivateKey().x963Representation
        let link = try linkPublicKey(secretKey: generateLinkKey())
        let b = try signBinding(identityKey: identity, linkPublicKey: link)
        return (try identityFingerprint(identityKey: identity), ConnectLinkBinding(id: b.id, key: b.key, sig: b.sig, port: 47820))
    }

    @Test func aBindingOfThePinnedComputerIsTrusted() throws {
        let (fp, b) = try Self.signed()
        #expect(try b.verified(fingerprint: fp) == b.id)
        #expect(try b.verified(fingerprint: "  " + fp.uppercased().replacingOccurrences(of: "SHA256:", with: "sha256:")) == b.id,
                "case and blanks don't matter")
    }

    @Test func anotherComputersOrATamperedBindingIsRefused() throws {
        let (fp, b) = try Self.signed()
        let (otherFp, other) = try Self.signed()
        #expect(throws: (any Error).self, "another computer's identity") { try other.verified(fingerprint: fp) }
        var swapped = b
        swapped.id = other.id
        #expect(throws: (any Error).self, "a link key its identity didn't sign") { try swapped.verified(fingerprint: fp) }
        var forged = other
        forged.key = b.key
        #expect(throws: (any Error).self, "the pinned key with someone else's signature") { try forged.verified(fingerprint: fp) }
        #expect(throws: (any Error).self, "a fingerprint that isn't one") { try b.verified(fingerprint: "sha256:00") }
        _ = otherFp
    }

    @Test func aMismatchIsNeverDialed() async throws {
        let (_, b) = try Self.signed()
        let (otherFp, _) = try Self.signed()
        do {
            _ = try await YoyoLinkClient.shared.dial(b, fingerprint: otherFp, hints: ["127.0.0.1:9"], credential: "Bearer x",
                                                     timeout: .seconds(1))
            Issue.record("dialed a binding of another computer")
        } catch let YoyoLinkClient.Failure.binding(message) {
            #expect(!message.isEmpty)
        }
    }
    #endif
}
