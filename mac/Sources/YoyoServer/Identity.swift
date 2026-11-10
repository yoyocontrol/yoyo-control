#if os(macOS)
import Foundation

/// Who answers on the socket: `/status`'s `app`, `version`, `build` and `api` (docs/LOCAL-API.md). A local client
/// should attach only to an answer with `app == "YoyoControl"` and an `api` it supports.
public enum ServerIdentity {
    /// `/status`'s `app`.
    public static let app = "YoyoControl"
    /// The HTTP API's version: +1 on an incompatible change (a new field or endpoint keeps it).
    public static let api = 1
    /// The bundle id: TCC grants are keyed by it, local clients may find the installed app by it (build.sh can override it for a fork).
    public static let defaultBundleId = "ca.sarria.yoyocontrol.mac"

    /// CFBundleShortVersionString of the app this runs in; "dev" unbundled (`swift build`'s binary).
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// CFBundleVersion of the app this runs in; nil unbundled.
    public static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static var json: [String: Any] {
        var j: [String: Any] = ["app": app, "version": version, "api": api]
        if let build { j["build"] = build }
        return j
    }
}
#endif
