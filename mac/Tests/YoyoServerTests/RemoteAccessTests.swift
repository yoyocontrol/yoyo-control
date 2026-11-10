import CryptoKit
import XCTest
@testable import YoyoServer

/// Remote access (RemoteDevices.swift, RemoteControl.swift, RemoteAccess.swift; docs/REMOTE.md): pairing, tokens,
/// control, and the link listener's lifecycle.
final class RemoteDevicesTests: XCTestCase {
    private var path: String!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        path = NSTemporaryDirectory() + "devices-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func make() -> RemoteDevices { RemoteDevices(path: path, now: { [unowned self] in clock }) }

    func testPairOnceWithTheLiveCode() throws {
        let d = make()
        XCTAssertThrowsError(try d.pair(code: "x", id: "phone-0001", name: "iPhone")) { XCTAssertEqual($0 as? RemoteDevices.PairError, .badCode) }
        let code = d.startPairing()
        let token = try d.pair(code: code.code, id: "phone-0001", name: "  Alex's iPhone \n")
        XCTAssertEqual(d.list.map(\.name), ["Alex's iPhone"])
        XCTAssertNil(d.pairingCode, "a code is used once")
        XCTAssertThrowsError(try d.pair(code: code.code, id: "phone-0002", name: "x"))
        XCTAssertEqual(d.authenticate(token: token)?.id, "phone-0001")
        XCTAssertNil(d.authenticate(token: token + "x"))

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let saved = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(saved.contains(token), "only the token's hash is kept")
        XCTAssertEqual(make().authenticate(token: token)?.id, "phone-0001", "read back from disk")
    }

    func testCodeExpiresAndWrongCodesEndIt() throws {
        let d = make()
        let code = d.startPairing()
        clock += RemoteDevices.codeTTL + 1
        XCTAssertNil(d.pairingCode)
        XCTAssertThrowsError(try d.pair(code: code.code, id: "phone-0001", name: "x"))

        let next = d.startPairing()
        for _ in 0..<RemoteDevices.maxCodeAttempts { XCTAssertThrowsError(try d.pair(code: "guess", id: "phone-0001", name: "x")) }
        XCTAssertNil(d.pairingCode, "too many wrong codes: the code is gone")
        XCTAssertThrowsError(try d.pair(code: next.code, id: "phone-0001", name: "x"))
    }

    func testPairingAgainReplacesTheTokenAndRemoveRevokes() throws {
        let d = make()
        let first = try d.pair(code: d.startPairing().code, id: "phone-0001", name: "a")
        let second = try d.pair(code: d.startPairing().code, id: "phone-0001", name: "b")
        XCTAssertEqual(d.list.count, 1)
        XCTAssertNil(d.authenticate(token: first))
        XCTAssertEqual(d.authenticate(token: second)?.name, "b")
        XCTAssertTrue(d.remove(id: "phone-0001"))
        XCTAssertNil(d.authenticate(token: second))
        XCTAssertFalse(d.remove(id: "phone-0001"))
    }

    func testAnInvitationPairsOnlyItsPhoneFromItsKeyOnce() throws {
        let d = make()
        let key = String(repeating: "ab", count: 32)
        let invite = try d.invite(id: "phone-0002", linkKey: key.uppercased())
        XCTAssertNil(d.pairingCode, "it isn't the shown code")
        XCTAssertThrowsError(try d.pair(code: invite.code, id: "phone-0003", name: "x", linkKey: key), "another phone")
        XCTAssertThrowsError(try d.pair(code: invite.code, id: "phone-0002", name: "x", linkKey: String(repeating: "cd", count: 32)), "another key")
        XCTAssertThrowsError(try d.pair(code: invite.code, id: "phone-0002", name: "x"), "no key")
        let token = try d.pair(code: invite.code, id: "phone-0002", name: "New iPhone", linkKey: key)
        XCTAssertEqual(d.authenticateLink(token: token, key: key), .accepted(d.list[0]))
        XCTAssertThrowsError(try d.pair(code: invite.code, id: "phone-0002", name: "x", linkKey: key), "used once")
        // the shown code goes on beside invitations; an invitation runs out
        let shown = d.startPairing()
        let late = try d.invite(id: "phone-0004", linkKey: key)
        clock += RemoteDevices.inviteTTL + 1
        XCTAssertThrowsError(try d.pair(code: late.code, id: "phone-0004", name: "x", linkKey: key), "expired")
        XCTAssertThrowsError(try d.invite(id: "phone-0004", linkKey: "nothex"))
        _ = shown
    }

    func testBadDeviceIds() {
        let d = make()
        let code = d.startPairing().code
        for bad in ["short", "has space 123", String(repeating: "a", count: 65), "slash/1234"] {
            XCTAssertThrowsError(try d.pair(code: code, id: bad, name: "x"), bad)
        }
        XCTAssertNotNil(d.pairingCode, "a bad device is not a wrong code")
    }
}

final class RemoteControlTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let a = RemoteDevice(id: "phone-aaaa", name: "A", pairedAt: Date(), lastSeenAt: nil, tokenHash: "")
    private let b = RemoteDevice(id: "phone-bbbb", name: "B", pairedAt: Date(), lastSeenAt: nil, tokenHash: "")

    private func make() -> (RemoteControl, Box) {
        let c = RemoteControl(idle: 600, now: { [unowned self] in clock })
        let lifts = Box()
        c.liftHeldButtons = { lifts.items.append($0) }
        return (c, lifts)
    }

    final class Box { var items: [String] = [] }

    func testPhoneNeedsControlAndLocalInputWaitsWhileOneHoldsIt() throws {
        let (c, _) = make()
        XCTAssertNoThrow(try c.admitInput(from: nil), "nobody holds it: a local client's input goes through")
        XCTAssertThrowsError(try c.admitInput(from: a)) { XCTAssertEqual(($0 as? HTTPError)?.status, 409) }
        c.take(a)
        XCTAssertNoThrow(try c.admitInput(from: a))
        XCTAssertThrowsError(try c.admitInput(from: nil)) { err in
            let e = err as? HTTPError
            XCTAssertEqual(e?.status, 409)
            XCTAssertEqual(e?.extra["code"] as? String, "controlled-elsewhere")
            XCTAssertEqual((e?.extra["controllerDevice"] as? [String: String])?["id"], "phone-aaaa")
        }
        XCTAssertThrowsError(try c.admitInput(from: b))
        XCTAssertEqual(c.json["controller"] as? String, "remote")
    }

    func testLatestTakerHoldsItAndOnlyItsReleaseCounts() {
        let (c, lifts) = make()
        c.take(a)
        c.take(b)
        XCTAssertEqual(c.holder?.id, "phone-bbbb")
        XCTAssertEqual(lifts.items.count, 1, "held buttons lifted on the handover")
        c.release(a)
        XCTAssertEqual(c.holder?.id, "phone-bbbb", "another phone's release changes nothing")
        c.release(b)
        XCTAssertNil(c.holder)
        XCTAssertEqual(c.json["controller"] as? String, "none")
    }

    func testIdleReleaseAndRemoval() throws {
        let (c, _) = make()
        c.take(a)
        clock += 599
        try c.admitInput(from: a)
        clock += 599
        c.checkIdle()
        XCTAssertEqual(c.holder?.id, "phone-aaaa", "input counts as activity")
        clock += 2
        c.checkIdle()
        XCTAssertNil(c.holder)
        c.take(b)
        c.deviceRemoved("phone-aaaa")
        XCTAssertNotNil(c.holder)
        c.deviceRemoved("phone-bbbb")
        XCTAssertNil(c.holder)
    }
}

/// Remote access around the link listener (RemoteAccess.swift) on an ephemeral home and port: when it listens, the
/// pairing code, the switches. Sessions over the link: LinkSessionTests.
final class RemoteListenerTests: XCTestCase {
    private var home: String!
    private var access: RemoteAccess!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "remote-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        access = RemoteAccess(home: home, control: RemoteControl(idle: 600))
        access.linkOptions = LinkOptions(port: 0, portMapping: false, bindAddresses: ["127.0.0.1"])
        access.signalURL = nil
        access.start()
    }

    override func tearDown() {
        access.stop()
        try? FileManager.default.removeItem(atPath: home)
    }

    /// The pairing code's items once a code is shown and the link listens (nothing listens before).
    private func listen() throws -> [String: String] {
        XCTAssertEqual(access.json["listening"] as? Bool, false, "no device, no code: no listener")
        let info = access.startPairing()
        XCTAssertNotNil(info["serverId"])
        let deadline = Date().addingTimeInterval(10)
        while access.json["listening"] as? Bool != true && Date() < deadline { usleep(20_000) }
        let pairing = try XCTUnwrap(access.json["pairing"] as? [String: Any])
        let url = try XCTUnwrap(URLComponents(string: try XCTUnwrap(pairing["url"] as? String)))
        XCTAssertEqual(url.scheme, "yoyocontrol")
        XCTAssertEqual(url.host, "pair")
        let items = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["c"], pairing["code"] as? String)
        return items
    }

    func testTheCodeCarriesTheLinkBinding() throws {
        let items = try listen()
        let link = try XCTUnwrap(access.json["link"] as? [String: Any])
        XCTAssertEqual(items["v"], "2")
        XCTAssertEqual(items["id"], access.json["serverId"] as? String)
        XCTAssertEqual(items["fp"], access.json["fingerprint"] as? String)
        XCTAssertEqual(items["l"], link["id"] as? String)
        XCTAssertEqual(items["lk"], RemoteAccess.base64url(link["key"] as! String))
        XCTAssertEqual(items["ls"], RemoteAccess.base64url(link["sig"] as! String))
        XCTAssertEqual(items["lp"], "\(link["port"] as! Int)")
        XCTAssertNil(items["p"], "no TLS port any more")
        XCTAssertEqual((access.json["direct"] as? [String: Any])?["status"] as? String, "off")
    }

    func testTheListenerLingersAfterTheLastDeviceThenGoes() throws {
        _ = try listen()
        _ = try access.devices.pair(code: access.devices.pairingCode!.code, id: "test-phone-1", name: "Test Phone")
        access.stopPairing()
        XCTAssertEqual(access.json["listening"] as? Bool, true, "a paired device keeps it up")
        XCTAssertTrue(access.devices.remove(id: "test-phone-1"))
        usleep(300_000)
        XCTAssertEqual(access.json["listening"] as? Bool, true, "lingering after the last device")
        access.setEnabled(false)
        let deadline = Date().addingTimeInterval(5)
        while access.json["listening"] as? Bool != false && Date() < deadline { usleep(20_000) }
        XCTAssertEqual(access.json["listening"] as? Bool, false)
    }

    func testJoiningAnAccountSignsForItAndIsRemembered() throws {
        XCTAssertTrue(access.json["account"] is NSNull)
        XCTAssertThrowsError(try access.join(account: "not-an-account"))
        let account = String(repeating: "0a", count: 16)
        let statement = try access.join(account: account)
        let fp = try XCTUnwrap(access.json["fingerprint"] as? String)
        XCTAssertEqual(statement["fp"] as? String, String(fp.dropFirst("sha256:".count)))
        XCTAssertEqual(statement["account"] as? String, account)
        XCTAssertEqual(statement["serverId"] as? String, access.json["serverId"] as? String)
        let key = try P256.Signing.PublicKey(x963Representation: try XCTUnwrap(Data(base64Encoded: statement["key"] as! String)))
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: try XCTUnwrap(Data(base64Encoded: statement["sig"] as! String)))
        XCTAssertTrue(key.isValidSignature(sig, for: Data("yoyocontrol-account-v1:\(account):\(statement["fp"] as! String)".utf8)))
        XCTAssertEqual(RemoteIdentity.fingerprint(ofKey: key.x963Representation), fp)
        XCTAssertEqual(RemoteSettings.load(home + "/remote.json").account, account, "remembered")
        XCTAssertEqual((access.json["account"] as? [String: Any])?["id"] as? String, account)
        access.leaveAccount()
        XCTAssertNil(RemoteSettings.load(home + "/remote.json").account)
        XCTAssertTrue(access.json["account"] is NSNull)
    }

    func testTurningItOffStopsTheListenerAndDirectIsRemembered() throws {
        _ = try listen()
        access.setDirect(false)
        XCTAssertEqual(RemoteSettings.load(home + "/remote.json").direct, false)
        XCTAssertEqual((access.json["direct"] as? [String: Any])?["enabled"] as? Bool, false)
        access.setEnabled(false)
        XCTAssertNil(access.devices.pairingCode)
        let deadline = Date().addingTimeInterval(5)
        while access.json["listening"] as? Bool != false && Date() < deadline { usleep(20_000) }
        XCTAssertEqual(access.json["listening"] as? Bool, false)
        XCTAssertEqual(RemoteSettings.load(home + "/remote.json").enabled, false, "remembered")
    }
}
