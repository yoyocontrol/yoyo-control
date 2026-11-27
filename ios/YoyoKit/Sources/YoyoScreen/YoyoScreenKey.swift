import YoyoCore

/// A key of the key bar above the keyboard (`YoyoScreenKeyboard.keys`) or of the Screen page's key row in trackpad mode:
/// what it shows and what it presses (a key name of `POST /input`, docs/PROTOCOL.md「输入」, with modifiers of its own).
/// The armed modifiers apply too. A host picks the keys its users need (Esc and the arrows; Page Up / Page Down and F5
/// for slides; ⌘Tab…); `standard` is what the kit's bar has without one.
public struct YoyoScreenKey: Sendable, Equatable, Hashable {
    /// What the button says: a glyph ("←", "⇞") or a short word ("esc", "F5"). Shown when there is no `symbol`.
    public var title: String
    /// An SF Symbol instead of the title (nil: the title).
    public var symbol: String?
    /// What VoiceOver says.
    public var label: String
    /// The key name sent (`escape`, `left`, `pageDown`, `f5`…: docs/PROTOCOL.md「输入」).
    public var key: String
    /// Held with it (⌘ for ⌘Tab…).
    public var modifiers: [ScreenModifier]

    public init(_ title: String, key: String, modifiers: [ScreenModifier] = [], label: String? = nil, symbol: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.label = label ?? title
        self.key = key
        self.modifiers = modifiers
    }

    /// The identifier of its button (`screen.key.<key>`, with the modifiers: `screen.key.cmd-tab`).
    var identifier: String {
        "screen.key." + (modifiers.map(\.rawValue) + [key]).joined(separator: "-")
    }

    public static var escape: YoyoScreenKey { YoyoScreenKey("esc", key: "escape", label: L("Escape")) }
    public static var tab: YoyoScreenKey { YoyoScreenKey("tab", key: "tab", label: L("Tab")) }
    public static var left: YoyoScreenKey { YoyoScreenKey("←", key: "left", label: L("Left arrow")) }
    public static var up: YoyoScreenKey { YoyoScreenKey("↑", key: "up", label: L("Up arrow")) }
    public static var down: YoyoScreenKey { YoyoScreenKey("↓", key: "down", label: L("Down arrow")) }
    public static var right: YoyoScreenKey { YoyoScreenKey("→", key: "right", label: L("Right arrow")) }
    public static var pageUp: YoyoScreenKey { YoyoScreenKey("⇞", key: "pageUp", label: L("Page Up")) }
    public static var pageDown: YoyoScreenKey { YoyoScreenKey("⇟", key: "pageDown", label: L("Page Down")) }
    public static var home: YoyoScreenKey { YoyoScreenKey("↖", key: "home", label: L("Home")) }
    public static var end: YoyoScreenKey { YoyoScreenKey("↘", key: "end", label: L("End")) }
    public static var space: YoyoScreenKey { YoyoScreenKey("␣", key: "space", label: L("Space")) }
    public static var enter: YoyoScreenKey { YoyoScreenKey("⏎", key: "return", label: L("Return")) }
    /// F1…F12.
    public static func function(_ n: Int) -> YoyoScreenKey { YoyoScreenKey("F\(n)", key: "f\(n)") }

    /// The kit's key bar: Esc, Tab, the arrows.
    public static var standard: [YoyoScreenKey] { [.escape, .tab, .left, .up, .down, .right] }
}
