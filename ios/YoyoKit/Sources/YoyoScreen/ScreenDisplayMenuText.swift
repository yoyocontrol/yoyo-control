import Foundation
import YoyoClipboard
import YoyoCore

/// The display menu's words (`ScreenViewController.updateDisplayMenu`), kept out of UIKit so they can be tested: the
/// menu (titled `Display`) lists the displays by name with their size in pixels.
enum ScreenDisplayMenuText {
    /// A display's name: what macOS calls it, else its kind; when neither is said, the main display or a number
    /// (`index` is its place in the list).
    static func title(_ d: ScreenDisplay, index: Int) -> String {
        if let name = d.name { return name }
        switch d.kind {
        case .builtin: return L("Built-in display")
        case .external: return L("External display")
        case nil: return d.main ? L("Main display") : L("Display \(index + 1)")
        }
    }

    /// The line under the name: its size in pixels (points × scale), the scale when it is a whole multiple, and
    /// whether it is the main display: `3456 × 2234 @2x · Main`.
    static func subtitle(_ d: ScreenDisplay) -> String {
        var s = "\(pixels(d.width * d.scale)) × \(pixels(d.height * d.scale))"
        if d.scale > 1, d.scale.isFinite, d.scale == d.scale.rounded(), d.scale < 100 { s += " @\(Int(d.scale))x" }
        if d.main { s += " · \(L("Main"))" }
        return s
    }

    /// A dimension as whole pixels (never traps on a bad value).
    static func pixels(_ v: Double) -> String {
        v.isFinite && abs(v) < 1e9 ? String(Int(v.rounded())) : "?"
    }
}
