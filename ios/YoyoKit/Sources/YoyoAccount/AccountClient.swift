import AuthenticationServices
import CryptoKit
import Foundation
import Security

/// A device's side of an account server (docs/ACCOUNT-LIB.md; @yoyocontrol/account-server): sign in (the app's native
/// Sign in with Apple, or email and password), the account's computers and a ticket into each, a one-use join key for a computer this phone
/// is paired with, App Store purchases kept with the account, the account's devices, signing out, deleting the
/// account, approving another device's sign-in by QR code and a computer's join code. The session is kept in the keychain under `keychainService` (this device only, after the first unlock).
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
        /// Who it signs in with: Apple's issuer, the account server's own `<server>/password` (email and password), or
        /// an OpenID provider's (nil: not said).
        public var issuer: String? = nil
        /// It signs in with Apple (deleting it asks Apple to confirm).
        public var viaApple: Bool { issuer == "https://appleid.apple.com" }
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

    /// What asks to be signed in with a sign-in code (another device's QR code): for the person to check first.
    public struct SignInRequest: Sendable, Equatable {
        /// The code as the server takes it (8 letters).
        public let code: String
        public let deviceName: String
        /// `web`, `windows`, `macos`, … as the device says.
        public let platform: String
        public let requestedAt: Date?
        /// The address it asked from.
        public let from: String?
        /// Seconds left.
        public let expiresIn: Int
        /// The account it would sign in to (this device's), by name.
        public let account: String
    }

    /// What a computer's join code stands for: for the person to check before approving (the computer then asks its own
    /// person).
    public struct JoinRequest: Sendable, Equatable {
        public let code: String
        public let linkId: String
        public let name: String
        public let requestedAt: Date?
        public let from: String?
        /// `pending`, or `approved` (by this account: only the computer's own yes is missing).
        public let status: String
        /// The computer said beforehand which account it expects; false = not this one.
        public let matchesExpected: Bool?
        public let account: String
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

    // MARK: Email and password

    /// Email and password (the server's `ACCOUNT_PASSWORD`; docs/ACCOUNT-LIB.md「邮箱和密码」). Refusals are `Failure`s
    /// with the server's `code`: `invalid_email`, `weak_password` (8–256 characters), `invalid_code`, `code_expired`,
    /// `invalid_credentials` (a wrong email or password: one answer), `already_registered`, `access_denied`,
    /// `mail_failed`, `slow_down` (429).
    ///
    /// Mails a sign-up code to `email` (`locale`: the mail's language, "zh-Hans" / "en"). The same answer for an email
    /// that has a login already (its mail says so instead of a code).
    public func registerEmail(_ email: String, password: String, locale: String? = nil) async throws {
        var body: [String: Any] = ["email": email, "password": password]
        if let locale { body["locale"] = locale }
        _ = try await call("POST", "v1/auth/password/register", body: body, auth: false)
    }

    /// The mailed code: the account is made, and this device signed in to it.
    @discardableResult
    public func verifyEmail(_ email: String, code: String, deviceName: String, platform: String = "ios") async throws -> Account {
        try await emailSession("v1/auth/password/verify", ["email": email, "code": code], deviceName: deviceName, platform: platform)
    }

    /// Signs in with email and password.
    @discardableResult
    public func signIn(email: String, password: String, deviceName: String, platform: String = "ios") async throws -> Account {
        try await emailSession("v1/auth/password", ["email": email, "password": password], deviceName: deviceName, platform: platform)
    }

    /// Mails a reset code when `email` has a login (the same answer when it has none).
    public func requestPasswordReset(_ email: String, locale: String? = nil) async throws {
        var body: [String: Any] = ["email": email]
        if let locale { body["locale"] = locale }
        _ = try await call("POST", "v1/auth/password/reset", body: body, auth: false)
    }

    /// The reset code and the new password: the account's other sessions end, this device is signed in.
    @discardableResult
    public func resetPassword(_ email: String, code: String, password: String, deviceName: String, platform: String = "ios") async throws -> Account {
        try await emailSession("v1/auth/password/reset/confirm", ["email": email, "code": code, "password": password], deviceName: deviceName, platform: platform)
    }

    private func emailSession(_ path: String, _ fields: [String: Any], deviceName: String, platform: String) async throws -> Account {
        var body = fields
        body["device"] = ["name": deviceName, "platform": platform]
        let j = try await call("POST", path, body: body, auth: false)
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
        return Account(id: a?["id"] as? String ?? "", name: a?["name"] as? String, entitlements: ents, issuer: a?["iss"] as? String)
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

    // MARK: Approving what another screen shows

    /// The 8 letters of the codes (RFC 8628's consonants).
    static let codeAlphabet = Set("BCDFGHJKLMNPQRSTVWXZ")

    private static func letters(_ s: Substring) -> String? {
        let c = s.uppercased().filter { $0.isLetter }
        return c.count == 8 && c.allSatisfy { codeAlphabet.contains($0) } ? c : nil
    }

    /// A sign-in code as scanned or typed: its link (`…#BCDFGHJK`), `BCDF-GHJK`, lower case, spaces. nil: none.
    public static func signInCode(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = t.firstIndex(of: "#") { return letters(t[t.index(after: hash)...]) }
        return letters(Substring(t))
    }

    /// A computer's join code as scanned or typed: the account server's QR text (`HTTPS://HOST/C/BCDFGHJK`), a link with
    /// the code after `#`, `BCDF-GHJK`, lower case. nil: none.
    public static func joinCode(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "/C/", options: [.caseInsensitive, .backwards]) {
            return letters(t[r.upperBound...].prefix { $0 != "/" })
        }
        if let hash = t.firstIndex(of: "#") { return letters(t[t.index(after: hash)...]) }
        return letters(Substring(t))
    }

    /// What asks to be signed in with `code` (`GET /v1/auth/qr/lookup`). 404: wrong, used or run out.
    public func lookupSignIn(code: String) async throws -> SignInRequest {
        let c = Self.signInCode(code) ?? ""
        let j = try await call("GET", "v1/auth/qr/lookup", query: ["code": c])
        let d = j["device"] as? [String: Any] ?? [:]
        return SignInRequest(code: c, deviceName: d["name"] as? String ?? "", platform: d["platform"] as? String ?? "web",
                             requestedAt: Self.date(j["requestedAt"]), from: j["from"] as? String,
                             expiresIn: (j["expiresIn"] as? NSNumber)?.intValue ?? 0, account: Self.accountName(j["account"]))
    }

    /// Signs the device of `code` in to this account (it gets its session, bound to its own key, at its next poll).
    public func approveSignIn(code: String) async throws {
        _ = try await call("POST", "v1/auth/qr/approve", body: ["code": Self.signInCode(code) ?? ""])
    }

    /// Refuses the sign-in of `code`.
    public func declineSignIn(code: String) async throws {
        _ = try await call("POST", "v1/auth/qr/decline", body: ["code": Self.signInCode(code) ?? ""])
    }

    /// What a computer's join code stands for (`GET /v1/computers/lookup`).
    public func lookupJoin(code: String) async throws -> JoinRequest {
        let c = Self.joinCode(code) ?? ""
        let j = try await call("GET", "v1/computers/lookup", query: ["code": c])
        let pc = j["computer"] as? [String: Any] ?? [:]
        guard let linkId = pc["linkId"] as? String else { throw Failure(status: 0, code: "unreadable", message: "The account server's answer was not readable.") }
        return JoinRequest(code: c, linkId: linkId, name: pc["name"] as? String ?? "", requestedAt: Self.date(j["requestedAt"]),
                           from: j["from"] as? String, status: j["status"] as? String ?? "pending",
                           matchesExpected: j["matchesExpected"] as? Bool, account: Self.accountName(j["account"]))
    }

    /// Puts the computer of a join code into this account; it then shows who approved and asks its own person.
    public func approveJoin(code: String) async throws {
        _ = try await call("POST", "v1/computers/approve", body: ["user_code": Self.joinCode(code) ?? ""])
    }

    private static func date(_ any: Any?) -> Date? {
        (any as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    private static func accountName(_ any: Any?) -> String {
        let a = any as? [String: Any] ?? [:]
        if let n = a["name"] as? String, !n.isEmpty { return n }
        return a["id"] as? String ?? ""
    }

    /// Forgets the session here only (the server said it is no good).
    public func forget() { setSession(nil) }

    // MARK: HTTP

    private func call(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil, auth: Bool = true) async throws -> [String: Any] {
        var url = server.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }) }
        var request = URLRequest(url: url, timeoutInterval: 15)
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
