import UIKit

// The palette and motion constants the kits' pages use. The colours come from the host (`YoyoHost.theme`); the default
// is Yoyo Control's own.

extension UIColor {
    package convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    package static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    package static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> UIColor {
        .dynamic(light: UIColor(hex: light, alpha: alpha), dark: UIColor(hex: dark, alpha: alpha))
    }
}

/// The colours of the kits' pages (every one a light / dark pair, or dynamic). `YoyoTheme()` is Yoyo Control's: neutrals
/// with coral as the single accent.
public struct YoyoTheme: @unchecked Sendable {
    /// The accent: the "agent is driving" badge, the trackpad's edge, prominent buttons.
    public var accent: UIColor
    public var background: UIColor
    /// The page's ground (the Screen page, the Clipboard page's grouped table).
    public var groupedBackground: UIColor
    /// A cell on the grouped ground.
    public var cellBackground: UIColor
    /// Ink over the ground: capsules, keys, controls.
    public var fill: UIColor
    /// A fainter fill (an image's placeholder).
    public var fillFaint: UIColor
    public var text: UIColor
    public var secondaryText: UIColor
    public var tertiaryText: UIColor
    public var success: UIColor
    /// A neutral prominent fill where the accent would be too loud.
    public var graphite: UIColor

    /// Yoyo Control's palette; change what differs (`var t = YoyoTheme(); t.accent = …`).
    public init() {
        accent = UIColor(hex: 0xD97757)
        background = .dynamic(0xFFFFFF, 0x000000)
        groupedBackground = .dynamic(0xF2F2F4, 0x0F0F10)
        cellBackground = .dynamic(0xFFFFFF, 0x1C1C1E)
        fill = Self.ink(0.06, 0.09)
        fillFaint = Self.ink(0.04, 0.08)
        text = .dynamic(0x0D0D0D, 0xF5F5F5)
        secondaryText = .dynamic(0x6B6B6B, 0xA6A6A8)
        tertiaryText = .dynamic(0x9A9A9A, 0x6E6E72)
        success = .dynamic(0x3F8F5A, 0x6CC28A)
        graphite = .dynamic(0x3A3A3C, 0x48484A)
    }

    /// Near-black ink in light mode, white in dark, at these alphas.
    package static func ink(_ light: CGFloat, _ dark: CGFloat) -> UIColor {
        .dynamic(light: UIColor(hex: 0x0D0D0D, alpha: light), dark: UIColor(white: 1, alpha: dark))
    }
}

/// The host's palette (`YoyoHost.current.theme`), by role.
package enum Theme {
    private static var t: YoyoTheme { YoyoHost.current.theme }
    /// The accent.
    package static var coral: UIColor { t.accent }
    package static var background: UIColor { t.background }
    package static var groupedBackground: UIColor { t.groupedBackground }
    package static var cellBackground: UIColor { t.cellBackground }
    package static var fill: UIColor { t.fill }
    package static var fillFaint: UIColor { t.fillFaint }
    package static var sheetControl: UIColor { t.fill }
    package static var text: UIColor { t.text }
    package static var secondaryText: UIColor { t.secondaryText }
    package static var tertiaryText: UIColor { t.tertiaryText }
    package static var success: UIColor { t.success }
    package static var graphite: UIColor { t.graphite }
}

/// Motion constants, named once (apple-motion-feel): tap-driven → critically damped; nothing here is thrown.
package enum Motion {
    /// Tap-driven reveals: damping 1.0, response 0.35 s.
    package static let tapResponse: TimeInterval = 0.35
    /// Small state changes.
    package static let quickResponse: TimeInterval = 0.3
    /// Reduce Motion substitute: short crossfade, no travel.
    package static let reducedFade: TimeInterval = 0.15

    @MainActor
    package static func animate(_ response: TimeInterval = tapResponse, _ changes: @escaping () -> Void,
                                completion: ((Bool) -> Void)? = nil) {
        UIView.animate(springDuration: response, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState], animations: changes, completion: completion)
    }
}
