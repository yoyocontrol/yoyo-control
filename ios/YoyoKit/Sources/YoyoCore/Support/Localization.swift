import Foundation
import Synchronization

/// Where each kit's `L(_:)` looks its strings up: its own `Localizable.xcstrings` (each target ships one), in the host's
/// language (`YoyoHost.language`: that localization's `.lproj` of the kit's bundle) or the system's choice, with the
/// host's locale for formatters.
package enum YoyoL10n {
    private static let bundles = Mutex<[String: Bundle]>([:])

    /// `module` (a kit's resource bundle), or its `.lproj` for the host's language.
    package static func bundle(_ module: Bundle) -> Bundle {
        guard let language = YoyoHost.current.language else { return module }
        let key = module.bundlePath + "|" + language
        if let b = bundles.withLock({ $0[key] }) { return b }
        let b = module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? module
        bundles.withLock { $0[key] = b }
        return b
    }

    /// For formatters (dates, numbers, sizes).
    package static var locale: Locale { YoyoHost.current.locale ?? .current }
}

/// A UI string of YoyoCore, in the host's language. The literal is the English source and the key in
/// `Localizable.xcstrings`; interpolations become format specifiers there (`String` → `%@`, `Int` → `%lld`), e.g.
/// `L("\(n) files")` looks up `"%lld files"`. Never cached in a `static let`: it follows a language switch.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: YoyoL10n.bundle(.module), locale: YoyoL10n.locale)
}
