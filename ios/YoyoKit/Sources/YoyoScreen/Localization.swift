import Foundation
import YoyoClipboard
import YoyoCore

/// A UI string of YoyoScreen, in the host's language (`YoyoHost.language`): its own `Localizable.xcstrings`. The
/// literal is the English source and the key; interpolations become format specifiers there (`String` → `%@`, `Int` →
/// `%lld`). Never cached in a `static let`: it follows a language switch.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: YoyoL10n.bundle(.module), locale: YoyoL10n.locale)
}
