import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// A device's side of an account server (docs/ACCOUNT-LIB.md; @yoyocontrol/account-server): sign in (the app's native
/// Sign in with Apple), the account's computers and a ticket into each, a one-use join key for a computer this phone
/// is paired with, App Store purchases kept with the account, the account's devices, signing out, deleting the
/// account. The session is kept in the keychain under `keychainService` (this device only, after the first unlock).
///
/// Nothing here is a way into a computer by itself: a ticket only says "this device of the account may come in"; the
/// computer checks it against the keys it pinned when it joined and gives the device a token of its own.
public final class AccountClient: @unchecked Sendable {
    public struct Failure: LocalizedError, Sendable, Equatable {
        /// The HTTP status (0: not reached).
        public let status: Int
        /// The server's `error` code (`invalid_token`, `too_many_devices`, …) or a sentence.
        public let code: String
        public let message: String
        public var errorDescription: String? { message }
        /// The session is no good any more (signed out elsewhere, removed, the account deleted): sign in again.
        public var signedOut: Bool { status == 401 }
    }

    /// The account as the server says it is.
    public struct Account: Sendable, Equatable {
        public let id: String
        public let name: String?
        /// What the account bought, by source (`appstore`): active, its product, until when (unix ms), sandbox.
        public let entitlements: [String: Entitlement]
    }

    public struct Entitlement: Sendable, Equatable {
        public let active: Bool
        public let productId: String
        public let expiresAt: Double?
        public let sandbox: Bool
    }

    /// One of the account's computers: its Link id, name, where it listens, and what it says of itself for the app
    /// (`info`, the product's own object).
    public struct Computer: @unchecked Sendable, Identifiable {
        public var id: String { linkId }
        public let linkId: String
        public let name: String
        public let relays: [String]
        public let direct: [String]
        public let info: [String: Any]
    }

    /// A device signed in to the account.
    public struct Device: Sendable, Identifiable, Equatable {
        public let id: String
        public let name: String
        public let platform: String?
        public let current: Bool
    }

    public let server: URL
    private let keychainService: String
    private let lock = NSLock()
    private var _session: String?
    private let urlSession: URLSession

    /// `server`: the account server's origin; `keychainService`: where the session is kept.
    public init(server: URL, keychainService: String, urlSession: URLSession = .shared) {
        self.server = server
        self.keychainService = keychainService
        self.urlSession = urlSession
        _session = Self.loadSession(keychainService)
    }

    public var signedIn: Bool { lock.withLock { _session != nil } }

    // MARK: Signing in with Apple

    /// A fresh nonce for Sign in with Apple: `raw` goes to the server with the token, `hashed` into the request
    /// (`ASAuthorizationAppleIDRequest.nonce`).
    public static func appleNonce() -> (raw: String, hashed: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let raw = Data(bytes).base64EncodedString()
        return (raw, SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// Signs in with Sign in with Apple's credential (`nonce`: the raw one its request was made with): the session is
    /// this device's from now on. `deviceName`, `platform`: how the account's lists show this device.
    @discardableResult
    public func signIn(apple credential: ASAuthorizationAppleIDCredential, nonce: String, deviceName: String, platform: String = "ios") async throws -> Account {
        guard let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw Failure(status: 0, code: "no_token", message: "Sign in with Apple gave no identity token.")
        }
        // (Apple says the name only the first time: the server keeps it)
        let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        return try await signIn(identityToken: token, nonce: nonce, name: name, deviceName: deviceName, platform: platform)
    }

    @discardableResult
    public func signIn(identityToken: String, nonce: String, name: String?, deviceName: String, platform: String = "ios") async throws -> Account {
        var body: [String: Any] = ["identityToken": identityToken, "nonce": nonce, "device": ["name": deviceName, "platform": platform]]
        if let name { body["name"] = name }
        let j = try await call("POST", "v1/auth/apple", body: body, auth: false)
        guard let s = j["session"] as? String else { throw Failure(status: 0, code: "no_session", message: "The account server gave no session.") }
        setSession(s)
        return try await me()
    }

    // MARK: The account

    public func me() async throws -> Account {
        let j = try await call("GET", "v1/me")
        let a = j["account"] as? [String: Any]
        var ents: [String: Entitlement] = [:]
        for (source, any) in j["entitlements"] as? [String: Any] ?? [:] {
            guard let e = any as? [String: Any] else { continue }
            ents[source] = Entitlement(active: e["active"] as? Bool ?? false, productId: e["productId"] as? String ?? "",
                                       expiresAt: e["expiresAt"] as? Double, sandbox: e["sandbox"] as? Bool ?? false)
        }
        return Account(id: a?["id"] as? String ?? "", name: a?["name"] as? String, entitlements: ents)
    }

    public func computers() async throws -> [Computer] {
        let j = try await call("GET", "v1/computers")
        return (j["computers"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["linkId"] as? String else { return nil }
            return Computer(linkId: id, name: c["name"] as? String ?? "Computer", relays: c["relays"] as? [String] ?? [],
                            direct: c["direct"] as? [String] ?? [], info: c["info"] as? [String: Any] ?? [:])
        }
    }

    /// A ticket into one of the account's computers (120 s, once): `hello.credential = "Ticket <ticket>"`.
    public func ticket(computer linkId: String) async throws -> String {
        let j = try await call("POST", "v1/tickets", body: ["computer": linkId])
        guard let t = j["ticket"] as? String else { throw Failure(status: 0, code: "no_ticket", message: "The account server gave no ticket.") }
        return t
    }

    /// A one-use join key for this account (10 minutes): what this phone hands a computer it is paired with, which
    /// then joins the account by itself. `server`: the account server's origin, as the computer pins it.
    public func joinKey() async throws -> (key: String, server: String) {
        let j = try await call("POST", "v1/join-keys")
        guard let key = j["key"] as? String, let server = j["server"] as? String else {
            throw Failure(status: 0, code: "no_key", message: "The account server gave no join key.")
        }
        return (key, server)
    }

    public func removeComputer(_ linkId: String) async throws {
        _ = try await call("DELETE", "v1/computers/\(linkId)")
    }

    public func devices() async throws -> [Device] {
        let j = try await call("GET", "v1/devices")
        return (j["devices"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            return Device(id: id, name: d["name"] as? String ?? "Device", platform: d["platform"] as? String, current: d["current"] as? Bool ?? false)
        }
    }

    /// Another device signed out of the account: the computers stop letting it in within seconds.
    public func removeDevice(_ id: String) async throws {
        _ = try await call("DELETE", "v1/devices/\(id)")
    }

    /// A StoreKit 2 transaction (`Transaction.jwsRepresentation`) kept with the account: what it has now.
    @discardableResult
    public func reportAppStore(transaction jws: String) async throws -> [String: Entitlement] {
        _ = try await call("POST", "v1/entitlements/appstore", body: ["jws": jws])
        return try await me().entitlements
    }

    /// Signs this device out (the computers stop letting it in); the session is forgotten whatever the server says.
    public func signOut() async {
        _ = try? await call("POST", "v1/signout")
        setSession(nil)
    }

    /// Deletes the account: every device signed out, every computer out of it. `authorizationCode`: a fresh one from
    /// Sign in with Apple, so the server revokes the app's grant (Apple's rule). Whether Apple took the revocation.
    @discardableResult
    public func deleteAccount(authorizationCode: String?) async throws -> Bool {
        let j = try await call("DELETE", "v1/me", body: authorizationCode.map { ["authorizationCode": $0] } ?? [:])
        setSession(nil)
        return j["revoked"] as? Bool ?? false
    }

    /// Forgets the session here only (the server said it is no good).
    public func forget() { setSession(nil) }

    // MARK: HTTP

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil, auth: Bool = true) async throws -> [String: Any] {
        var request = URLRequest(url: server.appending(path: path), timeoutInterval: 15)
        request.httpMethod = method
        if auth {
            guard let s = lock.withLock({ _session }) else { throw Failure(status: 401, code: "invalid_token", message: "Sign in first.") }
            request.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Failure(status: 0, code: "unreachable", message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let code = json["error"] as? String ?? "http_\(status)"
            throw Failure(status: status, code: code, message: json["error_description"] as? String ?? code)
        }
        return json
    }

    // MARK: The keychain

    private func setSession(_ s: String?) {
        lock.withLock { _session = s }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                   kSecAttrAccount as String: "session"]
        SecItemDelete(base as CFDictionary)
        guard let s else { return }
        var item = base
        item[kSecValueData as String] = Data(s.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func loadSession(_ service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "session", kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
