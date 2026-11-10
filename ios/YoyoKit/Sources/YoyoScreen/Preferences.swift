import UIKit
import YoyoClipboard
import YoyoCore

/// Device-wide settings the Screen page keeps, under the host's namespace (`YoyoHost.preferencesNamespace`).
@MainActor
enum Preferences {
    /// The Screen page showed its gesture card (the first time it took control). `-<namespace>TrackpadHintShown NO`
    /// shows it again (`YES`: never); that key was also the card's first version (before its clipboard section), whose
    /// "seen" doesn't count for this one.
    static var screenGestureHints: ScreenGestureHints {
        get {
            if let arg = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[YoyoHost.key("TrackpadHintShown")] {
                return ScreenGestureHints(seen: (arg as? NSString)?.boolValue ?? (arg as? Bool) ?? false)
            }
            return ScreenGestureHints(seen: UserDefaults.standard.bool(forKey: YoyoHost.key("GestureCard2Shown")))
        }
        set { UserDefaults.standard.set(newValue.seen, forKey: YoyoHost.key("GestureCard2Shown")) }
    }

    /// The Screen page's trackpad: scales its acceleration curve (`ScreenTrackpad.gain`; 1, no UI: a launch argument
    /// `-<namespace>TrackpadGain 1.5` tries another, 0.3…3).
    static var screenTrackpadGain: CGFloat {
        let v = UserDefaults.standard.double(forKey: YoyoHost.key("TrackpadGain"))
        return v >= 0.3 && v <= 3 ? CGFloat(v) : 1
    }
}
