#if os(macOS)
import CoreGraphics
import Foundation

/// This process's GUI login session, as WindowServer sees it.
struct SessionInfo {
    /// The user has a finished GUI login.
    let loggedIn: Bool

    var json: [String: Any] { ["loggedIn": loggedIn] }

    /// `CGSessionCopyCurrentDictionary` is nil without a GUI session (e.g. ssh, or a LaunchDaemon).
    static func current() -> SessionInfo {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return SessionInfo(loggedIn: false)
        }
        let done = (dict[kCGSessionLoginDoneKey] as? Bool) ?? (dict[kCGSessionLoginDoneKey] as? NSNumber)?.boolValue
        // LoginDone is absent on some systems while the session is fine: a dictionary means a session
        return SessionInfo(loggedIn: done ?? true)
    }
}
#endif
