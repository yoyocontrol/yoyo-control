import CryptoKit
import XCTest
@testable import YoyoServer

/// The Mac's half of an account (AccountMembership.swift) against the real account server: the library's harness,
/// run by `packages/account-server/scripts/interop.mjs` (needs node and `npm run build` there; skipped without them).
final class AccountMembershipTests: XCTestCase {
    private var server: Process?
    private var stdin: Pipe?
    private var dir: String!

    override func setUp() {
        dir = NSTemporaryDirectory() + "account-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? stdin?.fileHandleForWriting.close()
        server?.waitUntilExit()
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// The interop server's `{ url, key, account, control }`.
    private func startServer() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("packages/account-server/scripts/interop.mjs").path
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("packages/account-server/dist/testing/index.js").path) else {
            throw XCTSkip("build the account server first: npm --prefix packages/account-server run build")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", script]
        let out = Pipe()
        let input = Pipe()
        p.standardOutput = out
        p.standardInput = input
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw XCTSkip("no node: \(error)") }
        server = p
        stdin = input
        var line = Data()
        while !line.contains(0x0a) {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        let json = try XCTUnwrap((try? JSONSerialization.jsonObject(with: line)) as? [String: String])
        return json
    }

    private func call(_ url: String, _ method: String = "GET") throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: [String: Any] = [:]
        URLSession.shared.dataTask(with: req) { data, _, _ in
            out = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    private func wait(_ what: String, _ ok: () -> Bool) {
        let end = Date().addingTimeInterval(10)
        while !ok(), Date() < end { usleep(50_000) }
        XCTAssertTrue(ok(), what)
    }

    func testJoinsWithAKeyTakesTicketsOnceFollowsTheListAndLeaves() async throws {
        let s = try startServer()
        let seed = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        FileManager.default.createFile(atPath: dir + "/link-key", contents: seed)
        let linkId = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let m = AccountMembership(path: dir + "/account.json", linkKeyPath: dir + "/link-key") {
            .init(linkId: linkId, name: "Studio", relays: ["https://relay.example.com"], direct: ["192.168.1.5:47820"],
                  info: ["id": "server-1", "platform": "mac", "fp": "sha256:" + String(repeating: "0", count: 64)])
        }
        m.waitS = 1
        m.retryMin = 0.1
        let changes = NSLock()
        nonisolated(unsafe) var changed = 0
        m.onChange = { changes.withLock { changed += 1 } }

        try await m.joinWithKey(server: s["url"]!, key: s["key"]!)
        XCTAssertTrue(m.joined)
        XCTAssertEqual(((m.json["account"] as? [String: Any])?["id"] as? String), s["account"])
        let mode = try FileManager.default.attributesOfItem(atPath: dir + "/account.json")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        do {
            try await m.joinWithKey(server: s["url"]!, key: s["key"]!)
            XCTFail("one account at a time")
        } catch AccountMembership.Failure.join(let status, _) { XCTAssertEqual(status, 409) }
        m.start()
        defer { m.stop() }

        // listed, with what the app needs
        let computers = try XCTUnwrap(try call(s["control"]! + "/computers")["computers"] as? [[String: Any]])
        XCTAssertEqual(computers.first?["linkId"] as? String, linkId)
        XCTAssertEqual((computers.first?["info"] as? [String: Any])?["id"] as? String, "server-1")
        XCTAssertEqual(computers.first?["direct"] as? [String], ["192.168.1.5:47820"])

        // a ticket: taken once
        let t = try call(s["control"]! + "/ticket?computer=\(linkId)&device=iPad")
        let claims = try await m.redeem(try XCTUnwrap(t["ticket"] as? String))
        XCTAssertEqual(claims.account, s["account"])
        XCTAssertEqual(claims.deviceId, t["device"] as? String)
        XCTAssertEqual(claims.deviceName, "iPad")
        do {
            _ = try await m.redeem(t["ticket"] as! String)
            XCTFail("a ticket is taken once")
        } catch AccountMembership.Failure.ticket(let code) { XCTAssertEqual(code, "replayed") }
        // another computer's ticket is not this one's
        let other = try call(s["control"]! + "/ticket?computer=\(String(repeating: "ab", count: 32))&device=iPad")
        XCTAssertNotNil(other["error"], "the server gives none for a computer not in the account")
        do {
            _ = try await m.redeem("e30.e30.AAAA")
            XCTFail()
        } catch AccountMembership.Failure.ticket(let code) { XCTAssertEqual(code, "malformed") }

        let grant = AccountGrant(acc: claims.account, dev: claims.deviceId, tat: claims.iat, sx: claims.sx)
        XCTAssertTrue(m.ticketValid(grant))
        // removed from the account: out within the list's wait
        _ = try call(s["control"]! + "/remove?device=iPad", "POST")
        wait("the removed device no longer counts") { !m.ticketValid(grant) }
        XCTAssertGreaterThan(changes.withLock { changed }, 0)
        // a device signed in later is not touched by the removal of another
        let t2 = try call(s["control"]! + "/ticket?computer=\(linkId)&device=iPhone")
        let c2 = try await m.redeem(t2["ticket"] as! String)
        XCTAssertTrue(m.ticketValid(AccountGrant(acc: c2.account, dev: c2.deviceId, tat: c2.iat, sx: c2.sx)))

        // kept across a restart
        let again = AccountMembership(path: dir + "/account.json", linkKeyPath: dir + "/link-key") { nil }
        XCTAssertTrue(again.joined)
        XCTAssertFalse(again.ticketValid(grant))

        let left = await m.leave()
        XCTAssertTrue(left)
        XCTAssertFalse(m.joined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/account.json"))
        XCTAssertFalse(m.ticketValid(AccountGrant(acc: c2.account, dev: c2.deviceId, tat: c2.iat, sx: c2.sx)))
        wait("the account no longer lists it") { ((try? self.call(s["control"]! + "/computers")["computers"] as? [Any]) ?? [1]).isEmpty }
    }
}
