#if os(macOS)
import CryptoKit
import Foundation

/// Remote access's identity (docs/REMOTE.md「身份」): an EC P-256 key kept as a file in the Yoyo Control home
/// (`tls-key.der`, the key's X9.63 bytes, 0600; the name is from when it served TLS) and never in a keychain. Phones and
/// browsers pin it by `fingerprint` (from the pairing code); it signs the uu Link binding (docs/LINK.md「身份与信任」),
/// the rtc answers and the sign-in at the signaling server (RemoteSignal).
public struct RemoteIdentity {
    /// "sha256:" + lowercase hex of SHA-256(the public key's X9.63 bytes: 04 ‖ X ‖ Y).
    public let fingerprint: String
    let signingKey: P256.Signing.PrivateKey

    static let keyFile = "tls-key.der"

    /// The key in `directory`; a missing or unreadable one means a new key (the phones must pair again).
    public static func loadOrCreate(directory: String) throws -> RemoteIdentity {
        let path = directory + "/" + keyFile
        if let data = FileManager.default.contents(atPath: path), let key = try? P256.Signing.PrivateKey(x963Representation: data) {
            return RemoteIdentity(key: key)
        }
        let key = P256.Signing.PrivateKey()
        try writePrivate(key.x963Representation, to: path)
        return RemoteIdentity(key: key)
    }

    init(key: P256.Signing.PrivateKey) {
        signingKey = key
        fingerprint = Self.fingerprint(ofKey: key.publicKey.x963Representation)
    }

    /// The pin of a public key given as X9.63 bytes.
    public static func fingerprint(ofKey x963: Data) -> String {
        "sha256:" + SHA256.hash(data: x963).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `data` to `path` as 0600 (through a temporary file: a reader never sees half of it).
    static func writePrivate(_ data: Data, to path: String) throws {
        let tmp = path + ".tmp"
        FileManager.default.createFile(atPath: tmp, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: URL(fileURLWithPath: tmp))
        chmod(tmp, 0o600)
        guard rename(tmp, path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(tmp)
            throw ScreenServiceError(message: "cannot write \(path): \(why)")
        }
    }
}
#endif
