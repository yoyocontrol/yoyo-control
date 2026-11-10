import Foundation

/// `ScreenStatus.platform`: what kind of computer the screen is. An open set: "mac", "linux" and "windows" are known; any other
/// value is kept as it is (a computer the kits name generically).
public struct YoyoPlatform: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let mac = YoyoPlatform(rawValue: "mac")
    public static let linux = YoyoPlatform(rawValue: "linux")
    public static let windows = YoyoPlatform(rawValue: "windows")
}

/// Whose screen the pages show, for their words and the few things that differ by platform: a Mac ("Screen", "Mac",
/// ⌘V, the macOS permissions) or any other computer ("Desktop", "the computer", Shift+Insert on Linux, Ctrl+V
/// elsewhere, no macOS permissions to grant). Which one: `ScreenStatus.platform` once a status said it, else the
/// backend's `platformHint`, else the Mac.
public struct YoyoComputer: Sendable, Equatable {
    public var platform: YoyoPlatform

    public init(_ platform: YoyoPlatform) { self.platform = platform }

    public static let mac = YoyoComputer(.mac)
    public static let linux = YoyoComputer(.linux)
    public static let windows = YoyoComputer(.windows)

    /// The platform a status said, else `hint`, else the Mac.
    public static func of(platform: YoyoPlatform?, hint: YoyoPlatform? = nil) -> YoyoComputer {
        YoyoComputer(platform ?? hint ?? .mac)
    }

    /// This computer, or what a status says it is (`platform`; not said: this one).
    public func resolved(_ platform: YoyoPlatform?) -> YoyoComputer { platform.map(YoyoComputer.init) ?? self }

    public var isMac: Bool { platform == .mac }

    /// The macOS permission prompts (Screen Recording, Accessibility).
    public var hasMacPermissions: Bool { isMac }

    /// This computer's clipboard: as the status says (`features.clipboard`); not said, the Mac's only (a computer that
    /// doesn't say may not have one).
    public func hasClipboard(_ features: ScreenFeatures?) -> Bool { features?.clipboard ?? isMac }

    /// What Paste presses once the phone's clipboard is there: ⌘V on the Mac; Shift+Insert on Linux, which terminals and
    /// GTK / Chromium apps all paste with (Ctrl+V does nothing in some terminals; `insert` is a key name of the Linux
    /// server); Ctrl+V elsewhere (Windows).
    public var pasteShortcut: ScreenInput {
        switch platform {
        case .mac: ScreenInput(.key, key: "v", modifiers: [.cmd])
        case .linux: ScreenInput(.key, key: "insert", modifiers: [.shift])
        default: ScreenInput(.key, key: "v", modifiers: [.ctrl])
        }
    }

    /// The status as the pages read it: a computer without the macOS permissions can be shown and controlled once it is
    /// available, whatever those fields say (stubbed, missing). A Mac's is untouched.
    public func normalized(_ s: ScreenStatus) -> ScreenStatus {
        guard !hasMacPermissions else { return s }
        var s = s
        s.screenRecording = true
        s.accessibility = true
        return s
    }

    // MARK: Words

    /// The page's title (and a list's section header).
    public var title: String { isMac ? L("Screen") : L("Desktop") }
    /// The picture, for VoiceOver.
    public var pictureLabel: String { isMac ? L("Mac screen") : L("Desktop") }
    /// Nothing more is said about why it can't be shown.
    public var unavailableTitle: String { isMac ? L("Screen unavailable") : L("Desktop unavailable") }
    public var unavailableDetail: String {
        isMac ? L("The Mac’s screen can’t be shown right now.") : L("The desktop can’t be shown right now.")
    }
    /// A preview row's line while nobody drives it.
    public var watchLine: String { isMac ? L("Watch the Mac, or take control") : L("Watch the desktop, or take control") }
    /// The sound button's label (it mutes / plays).
    public func soundLabel(on: Bool) -> String {
        switch (isMac, on) {
        case (true, true): L("Mute Mac sound")
        case (true, false): L("Play Mac sound")
        case (false, true): L("Mute sound")
        case (false, false): L("Play sound")
        }
    }

    // MARK: The clipboard's words (the rest of the clipboard's words are the same for every computer)

    public var pasteLabel: String { isMac ? L("Paste on Mac") : L("Paste on Computer") }
    public var copyLabel: String { isMac ? L("Copy from Mac") : L("Copy from Computer") }
    public var sendTitle: String { isMac ? L("Send to Mac") : L("Send to Computer") }
    /// The Clipboard page's first section.
    public var onYourComputer: String { isMac ? L("On your Mac") : L("On your computer") }

    public var pasted: String { isMac ? L("Pasted on the Mac") : L("Pasted on the computer") }
    public var copiedTakeControl: String {
        isMac ? L("Copied to the Mac. Take control to paste.") : L("Copied to the computer. Take control to paste.")
    }
    public var copiedFrom: String { isMac ? L("Copied from the Mac") : L("Copied from the computer") }
    public var clipboardConcealed: String {
        isMac ? L("The Mac’s clipboard is hidden by a password manager.")
            : L("The computer’s clipboard is hidden by a password manager.")
    }
    public var clipboardEmptyMessage: String { isMac ? L("The Mac’s clipboard is empty.") : L("The computer’s clipboard is empty.") }
    /// A menu item's subtitle (no full stop).
    public var clipboardEmpty: String { isMac ? L("The Mac’s clipboard is empty") : L("The computer’s clipboard is empty") }
    public var clipboardNothing: String {
        isMac ? L("Nothing the iPhone can take from the Mac’s clipboard.")
            : L("Nothing the iPhone can take from the computer’s clipboard.")
    }
    public func sendingFiles(_ n: Int) -> String {
        isMac ? L("Sending \(n) files to the Mac…") : L("Sending \(n) files to the computer…")
    }
    /// After text went onto the clipboard.
    public var copiedTo: String { isMac ? L("Copied to the Mac") : L("Copied to the computer") }
    /// After files were sent (and saved in `folder`).
    public func sent(savedIn folder: String?) -> String {
        switch (isMac, folder) {
        case (true, let f?): L("Sent to the Mac · saved in \(f)")
        case (true, nil): L("Sent to the Mac")
        case (false, let f?): L("Sent to the computer · saved in \(f)")
        case (false, nil): L("Sent to the computer")
        }
    }
    /// The card's footer for what the computer itself copied; `when` is "2 min. ago" or "".
    public func copiedOn(_ when: String) -> String {
        switch (isMac, when.isEmpty) {
        case (true, true): L("Copied on the Mac")
        case (true, false): L("Copied on the Mac · \(when)")
        case (false, true): L("Copied on the computer")
        case (false, false): L("Copied on the computer · \(when)")
        }
    }
    /// The hint over the picture: the computer has just copied `what`.
    public func copiedHint(_ what: String) -> String {
        isMac ? L("Copied on Mac: \(what) — Copy to iPhone") : L("Copied on computer: \(what) — Copy to iPhone")
    }
    /// The hint over the picture: the phone holds `kind`.
    public func phoneHint(_ kind: String) -> String {
        isMac ? L("iPhone clipboard: \(kind) — Paste on Mac") : L("iPhone clipboard: \(kind) — Paste on Computer")
    }
    /// The gesture card's clipboard rows: what each verb does.
    public var pasteExplained: String {
        isMac ? L("What you copied on this iPhone goes to the Mac and is pasted there")
            : L("What you copied on this iPhone goes to the computer and is pasted there")
    }
    public var copyExplained: String {
        isMac ? L("What the Mac copied comes to this iPhone’s clipboard")
            : L("What the computer copied comes to this iPhone’s clipboard")
    }
    /// The Clipboard page's footer under Send.
    public var sendFooter: String {
        isMac ? L("Text and links go onto the Mac’s clipboard. Photos and files are saved to its Downloads folder and copied there too.")
            : L("Text and links go onto the computer’s clipboard. Photos and files are saved to its Downloads folder and copied there too.")
    }
    public var folderOnComputer: String {
        isMac ? L("Folder · copy its contents on the Mac") : L("Folder · copy its contents on the computer")
    }
    public var copySomething: String {
        isMac ? L("Copy something on the Mac and it shows up here.") : L("Copy something on the computer and it shows up here.")
    }
}

/// `ScreenStatus.platform` / `features` as a computer last said them (per `cacheScope`), for the pages: an answer that
/// doesn't say (the computer's server restarting, a control answer built without them) keeps what an earlier one
/// said, so the clipboard button and the speaker don't come and go; a value that is said replaces the old one.
/// For this run of the app.
@MainActor
public enum YoyoCapabilities {
    private static var known: [String: (platform: YoyoPlatform?, features: ScreenFeatures?)] = [:]

    /// `s` with what the computer is known to be filled in (and that remembered).
    public static func note(_ s: ScreenStatus, scope: String) -> ScreenStatus {
        var k = known[scope] ?? (nil, nil)
        if let p = s.platform { k.platform = p }
        if let f = s.features { k.features = f }
        if k.platform != nil || k.features != nil { known[scope] = k }
        var s = s
        s.platform = k.platform
        s.features = k.features
        return s
    }

    public static func platform(scope: String) -> YoyoPlatform? { known[scope]?.platform }
    public static func features(scope: String) -> ScreenFeatures? { known[scope]?.features }

    /// Tests.
    public static func forget() { known = [:] }
}
