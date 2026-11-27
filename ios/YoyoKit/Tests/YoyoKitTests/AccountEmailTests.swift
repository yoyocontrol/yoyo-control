import Foundation
import Testing
@testable import YoyoAccount

/// `AccountClient`'s email and password against a stand-in account server (a URLProtocol): the paths and bodies it
/// sends, the session it keeps from them (then `GET /v1/me` with it), the issuer it reads, and the server's refusals as
/// `Failure` codes.
@Suite("Account email", .serialized)
struct AccountEmailTests {
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var requests: [(method: String, path: String, body: [String: Any], auth: String?)] = []
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
            Self.requests.append((request.httpMethod ?? "GET", path, body, request.value(forHTTPHeaderField: "Authorization")))
            let (status, json) = Self.answer(path)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client() -> AccountClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        Stub.requests = []
        let c = AccountClient(server: URL(string: "https://account.example.com")!, keychainService: "yoyo-tests-\(UUID().uuidString)", urlSession: URLSession(configuration: config))
        return c
    }

    @Test func signUpThenSignInKeepTheSessionAndReadTheIssuer() async throws {
        let c = client()
        Stub.answer = { path in
            switch path {
            case "/v1/auth/password/register": return (200, ["sent": true])
            case "/v1/auth/password/verify", "/v1/auth/password": return (200, ["session": "yoyo_as_abc", "account": ["id": "a_1", "name": "a@example.com"]])
            case "/v1/me": return (200, ["account": ["id": "a_1", "name": "a@example.com", "iss": "https://account.example.com/password"], "entitlements": [:]])
            default: return (404, ["error": "not_found"])
            }
        }
        try await c.registerEmail("a@example.com", password: "long enough", locale: "zh-Hans")
        #expect(Stub.requests[0].path == "/v1/auth/password/register")
        #expect(Stub.requests[0].body["email"] as? String == "a@example.com")
        #expect(Stub.requests[0].body["locale"] as? String == "zh-Hans")
        #expect(Stub.requests[0].auth == nil)
        #expect(!c.signedIn)
        let a = try await c.verifyEmail("a@example.com", code: "123456", deviceName: "Test iPhone")
        #expect(c.signedIn)
        #expect(Stub.requests[1].path == "/v1/auth/password/verify")
        #expect((Stub.requests[1].body["device"] as? [String: Any])?["name"] as? String == "Test iPhone")
        #expect(Stub.requests[2].path == "/v1/me" && Stub.requests[2].auth == "Bearer yoyo_as_abc")
        #expect(a.id == "a_1" && a.issuer == "https://account.example.com/password" && !a.viaApple)
        _ = try await c.signIn(email: "a@example.com", password: "long enough", deviceName: "Test iPhone")
        #expect(Stub.requests[3].path == "/v1/auth/password")
        c.forget()
    }

    @Test func refusalsComeBackAsTheirCodes() async throws {
        let c = client()
        Stub.answer = { _ in (401, ["error": "invalid_credentials", "error_description": "the email or the password is not right"]) }
        do {
            try await c.signIn(email: "a@example.com", password: "wrong", deviceName: "x")
            Issue.record("no refusal")
        } catch let f as AccountClient.Failure {
            #expect(f.code == "invalid_credentials" && f.status == 401)
        }
        #expect(!c.signedIn)
        Stub.answer = { _ in (200, ["sent": true]) }
        try await c.requestPasswordReset("a@example.com")
        #expect(Stub.requests.last?.path == "/v1/auth/password/reset")
        Stub.answer = { path in path == "/v1/me" ? (200, ["account": ["id": "a_2", "iss": "https://appleid.apple.com"]]) : (200, ["session": "yoyo_as_x"]) }
        let a = try await c.resetPassword("a@example.com", code: "654321", password: "a new one!", deviceName: "x")
        #expect(Stub.requests.contains { $0.path == "/v1/auth/password/reset/confirm" && $0.body["code"] as? String == "654321" })
        #expect(a.viaApple)
        c.forget()
    }
}
