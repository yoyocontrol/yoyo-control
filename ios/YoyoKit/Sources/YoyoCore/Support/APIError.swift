import Foundation

/// A request to the computer that failed with an answer (or one that couldn't be read). What a `YoyoBackend` throws
/// for those; anything else it throws is taken as the transport's (a timeout, no connection).
public enum YoyoError: Error, LocalizedError, Equatable, Sendable {
    /// The credential no longer works (the computer forgot this phone, the account signed out): `YoyoHost.handleError`
    /// decides what happens.
    case unauthorized
    /// An answer that isn't 2xx, with the body's `error` when it had one.
    case http(Int, String?)
    case badServerURL
    case decoding(String)

    /// The endpoint does not exist on this server (an older one).
    public var isNotFound: Bool { if case .http(404, _) = self { return true } else { return false } }

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return L("Your session has expired. Please sign in again.")
        case .http(let code, let msg): return msg.map { L("\($0) (HTTP \(code))") } ?? L("The server returned HTTP \(code).")
        case .badServerURL: return L("Invalid server address.")
        case .decoding(let what): return L("Couldn’t read the server’s response: \(what)")
        }
    }
}

extension KeyedDecodingContainer {
    /// Lenient boolean: accepts true/false, 0/1, or absence.
    package func flag(_ key: Key) -> Bool {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let n = try? decodeIfPresent(Int.self, forKey: key) { return n != 0 }
        return false
    }

    /// A list whose undecodable elements are dropped (one bad entry must not cost the rest); absent / null / not a
    /// list = `[]`.
    package func lenientList<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        ((try? decodeIfPresent([Lenient<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}

/// One element of a list, decoded on its own: `value` is nil when it can't be.
package struct Lenient<T: Decodable>: Decodable {
    package let value: T?
    package init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
