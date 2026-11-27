import Foundation
import Testing
@testable import YoyoAccount

/// `AccountClient` approving what another screen shows, against a stand-in account server (a URLProtocol): a device's
/// sign-in code (its QR code's link) and a computer's join code — the codes read out of what was scanned or typed, the
/// lookups' paths, queries and answers, the approvals' bodies, the server's refusals as `Failure` codes.
@Suite("Account approvals", .serialized)
struct AccountApproveTests {
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requests: [(method: String, path: String, query: String?, body: [String: Any], auth: String?)] = []
        nonisolated(unsafe) static var answer: (String) -> (Int, [String: Any]) = { _ in (200, [:]) }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var data = request.httpBody
            if data == nil, let s = request.httpBodyStream {
                s.open()
                var d = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
                s.close()
                data = d
            }
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let path = request.url!.path
            Self.requests.append((request.httpMethod ?? "GET", path, request.url!.query, body, request.value(forHTTPHeaderField: "Authorization")))
            let (status, json) = Self.answer(path)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// A client signed in (by email, through the stand-in) with `yoyo_as_s`.
    private func client() async throws -> AccountClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let c = AccountClient(server: URL(string: "https://account.example.com")!, keychainService: "yoyo-tests-\(UUID().uuidString)", urlSession: URLSession(configuration: config))
        Stub.answer = { path in path == "/v1/me" ? (200, ["account": ["id": "a_1", "name": "Alex"]]) : (200, ["session": "yoyo_as_s"]) }
        try await c.signIn(email: "a@example.com", password: "long enough", deviceName: "iPhone")
        Stub.requests = []
        return c
    }

    @Test func codesAreReadOutOfLinksQRTextAndTyping() {
        #expect(AccountClient.signInCode("https://example.com/app/login#BCDFGHJK") == "BCDFGHJK")
        #expect(AccountClient.signInCode(" bcdf-ghjk ") == "BCDFGHJK")
        #expect(AccountClient.signInCode("https://example.com/app/login#AEIOUAEI") == nil)
        #expect(AccountClient.signInCode("BCDFGHJ") == nil)
        #expect(AccountClient.joinCode("HTTPS://ACCOUNT.EXAMPLE.COM/C/BCDFGHJK") == "BCDFGHJK")
        #expect(AccountClient.joinCode("https://example.com/app/join#bcdf-ghjk") == "BCDFGHJK")
        #expect(AccountClient.joinCode("BCDF GHJK") == "BCDFGHJK")
        #expect(AccountClient.joinCode("https://example.com/") == nil)
    }

    @Test func aSignInIsLookedUpThenApprovedOrDeclined() async throws {
        let c = try await client()
        Stub.answer = { path in
            switch path {
            case "/v1/auth/qr/lookup":
                return (200, ["device": ["name": "Chrome on Windows", "platform": "web"], "requestedAt": 1_764_000_000_000, "from": "203.0.113.7", "expiresIn": 120, "status": "pending", "account": ["id": "a_1", "name": "Alex"]])
            case "/v1/auth/qr/approve": return (200, ["status": "approved"])
            case "/v1/auth/qr/decline": return (200, ["ok": true])
            default: return (404, ["error": "not_found"])
            }
        }
        let r = try await c.lookupSignIn(code: "https://example.com/app/login#BCDFGHJK")
        #expect(Stub.requests[0].method == "GET" && Stub.requests[0].path == "/v1/auth/qr/lookup" && Stub.requests[0].query == "code=BCDFGHJK")
        #expect(Stub.requests[0].auth == "Bearer yoyo_as_s")
        #expect(r.code == "BCDFGHJK" && r.deviceName == "Chrome on Windows" && r.platform == "web" && r.from == "203.0.113.7" && r.expiresIn == 120 && r.account == "Alex")
        #expect(r.requestedAt == Date(timeIntervalSince1970: 1_764_000_000))
        try await c.approveSignIn(code: r.code)
        #expect(Stub.requests[1].path == "/v1/auth/qr/approve" && Stub.requests[1].body["code"] as? String == "BCDFGHJK")
        try await c.declineSignIn(code: "bcdf-ghjk")
        #expect(Stub.requests[2].path == "/v1/auth/qr/decline" && Stub.requests[2].body["code"] as? String == "BCDFGHJK")
        Stub.answer = { _ in (404, ["error": "not_found", "error_description": "no such code (or it expired, or it was used)"]) }
        do {
            _ = try await c.lookupSignIn(code: "BCDFGHJK")
            Issue.record("no refusal")
        } catch let f as AccountClient.Failure {
            #expect(f.status == 404 && f.code == "not_found")
        }
        c.forget()
    }

    @Test func aJoinCodeIsLookedUpThenApproved() async throws {
        let c = try await client()
        Stub.answer = { path in
            switch path {
            case "/v1/computers/lookup":
                return (200, ["computer": ["linkId": String(repeating: "ab", count: 32), "name": "Studio"], "requestedAt": 1_764_000_000_000, "from": "198.51.100.2", "status": "pending", "expectsAccount": true, "matchesExpected": false, "account": ["id": "a_1", "name": ""]])
            case "/v1/computers/approve": return (403, ["error": "wrong_account"])
            default: return (404, ["error": "not_found"])
            }
        }
        let j = try await c.lookupJoin(code: "HTTPS://ACCOUNT.EXAMPLE.COM/C/BCDFGHJK")
        #expect(Stub.requests[0].path == "/v1/computers/lookup" && Stub.requests[0].query == "code=BCDFGHJK")
        #expect(j.name == "Studio" && j.linkId.count == 64 && j.from == "198.51.100.2" && j.status == "pending" && j.matchesExpected == false && j.account == "a_1")
        do {
            try await c.approveJoin(code: j.code)
            Issue.record("no refusal")
        } catch let f as AccountClient.Failure {
            #expect(f.code == "wrong_account" && f.status == 403)
        }
        #expect(Stub.requests[1].path == "/v1/computers/approve" && Stub.requests[1].body["user_code"] as? String == "BCDFGHJK")
        c.forget()
    }
}
