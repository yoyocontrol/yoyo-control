import Foundation
import YoyoCore

/// Whether the Screen page's computer has a clipboard (`YoyoComputer.hasClipboard`, which can change as `GET /screen`
/// answers), and which observer of the `clipboard` resource is the current one: an observer can't be removed, so one
/// from before the clipboard went away (or came back) is told apart by its epoch and ignored.
public struct ScreenClipboardGate: Equatable, Sendable {
    package enum Change: Equatable, Sendable {
        /// Observe the resource now, as `epoch`.
        case start(epoch: Int)
        /// Hide the keys, the button and the hints (`wasOn`: they may be showing).
        case stop(wasOn: Bool)
    }

    /// nil: not decided yet.
    package private(set) var on: Bool?
    package private(set) var epoch = 0

    package init() {}

    /// What the page does for a (new) answer; nil: nothing changed.
    package mutating func update(_ has: Bool) -> Change? {
        guard has != on else { return nil }
        let was = on == true
        on = has
        epoch += 1
        return has ? .start(epoch: epoch) : .stop(wasOn: was)
    }

    /// An observer started as `epoch` still speaks for the page.
    package func isCurrent(_ epoch: Int) -> Bool { on == true && epoch == self.epoch }

    /// A state of the `clipboard` resource says the clipboard can be used: it has a value, or it failed for a reason other
    /// than "not there" (404: `unsupported`) or "not this account's" (403, e.g. a server that no longer gives a user's
    /// desktop its clipboard): those hide the keys and the button instead of failing on every tap.
    public static func supported(value: Bool, error: Error?) -> Bool {
        if value { return true }
        guard let error else { return false }
        if case YoyoError.http(403, _) = error { return false }
        return true
    }
}

/// What the Screen page has shown or done with either clipboard, for this run of the app: the clipboard button's dot and
/// the hints over the picture come from it (plain values; the page feeds them `UIPasteboard.general.changeCount` and the
/// `clipboard` resource). Nothing is read from the phone's pasteboard but its change count and whether it has strings /
/// links / images, so no paste notice ever shows for a hint.
package struct ScreenClipboardMarks: Equatable, Sendable {
    /// The phone's `changeCount` last pasted on the Mac, put there by Copy from Mac, or seen in the open menu (nil: none
    /// this run, so whatever the phone holds counts as new).
    package var phone: Int?
    /// The Mac's `changeCount` last copied to the phone, or seen (the menu opened, the page first knew it).
    package var mac: Int?

    package init(phone: Int? = nil, mac: Int? = nil) {
        self.phone = phone
        self.mac = mac
    }

    /// The phone holds something the page hasn't acted on.
    package func phoneIsNew(count: Int, kind: ClipboardActions.PhoneKind?) -> Bool {
        kind != nil && phone != count
    }

    /// The Mac holds something new since it was last copied or seen (not what this phone sent, not something it can't
    /// copy). Before the page knew the Mac's clipboard at all, nothing is new (`knowMac` sets the start).
    package func macIsNew(_ s: ClipboardSummary?) -> Bool {
        guard let s, let mac, s.changeCount != mac, s.source != .phone else { return false }
        return ClipboardActions.macHint(s) != nil
    }

    /// The clipboard button's dot.
    package func dot(phoneCount: Int, phoneKind: ClipboardActions.PhoneKind?, mac: ClipboardSummary?) -> Bool {
        phoneIsNew(count: phoneCount, kind: phoneKind) || macIsNew(mac)
    }

    /// The page learned what the Mac holds: the first time this run, that is where "new" starts.
    package mutating func knowMac(_ s: ClipboardSummary?) {
        if mac == nil, let s { mac = s.changeCount }
    }

    /// The menu opened: both sides count as seen (the dot goes).
    package mutating func sawMenu(phoneCount: Int, mac s: ClipboardSummary?) {
        phone = phoneCount
        if let s { mac = s.changeCount }
    }
}

/// The hint pills over the picture (one at a time: the newer replaces the older; each goes after `duration` or at any
/// input). Which one a moment calls for.
package enum ScreenClipboardHint: Equatable, Sendable {
    /// "iPhone clipboard: text — Paste on Mac": tap = Paste on Mac.
    case phone(ClipboardActions.PhoneKind)
    /// "Copied on Mac: “…” — Copy to iPhone": tap = Copy from Mac.
    case mac(changeCount: Int)

    package static let duration: Duration = .seconds(6)

    /// The page appeared (or came back to the foreground): the phone's clipboard, if it holds something not acted on.
    package static func onAppear(marks: ScreenClipboardMarks, phoneCount: Int, phoneKind: ClipboardActions.PhoneKind?) -> Self? {
        guard let phoneKind, marks.phoneIsNew(count: phoneCount, kind: phoneKind) else { return nil }
        return .phone(phoneKind)
    }

    /// The Mac's clipboard changed while the page is open (`previous`: the change count the page knew before; nil: this
    /// is the first it hears, not a change): the Mac's new item, unless this phone put it there or it can't be copied.
    package static func onMacChange(_ s: ClipboardSummary?, previous: Int?) -> Self? {
        guard let s, let previous, s.changeCount != previous, s.source != .phone, ClipboardActions.macHint(s) != nil else { return nil }
        return .mac(changeCount: s.changeCount)
    }
}
