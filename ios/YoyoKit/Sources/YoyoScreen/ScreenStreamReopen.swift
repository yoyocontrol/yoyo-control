import Foundation
import YoyoClipboard
import YoyoCore

/// What the screen page does when its stream ends. A stream that had shown pictures and was ended by the server without
/// an error is reopened at once: the Mac ends a stream on purpose when it can't go on with it as it was (its capture
/// stopped, the display changed), and the new stream picks up from there. If that keeps happening quickly (more than
/// `quickEndsAllowed` streams in a row that lived under `quickLifetime`), reopens wait `backoff`. Anything else (an error,
/// or a stream that never showed a picture) is tried again later (`ScreenSession.retryStreamAfter`).
struct ScreenStreamReopenPolicy: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case reopen(after: Duration)
        case retryLater
    }

    static let quickLifetime: Duration = .seconds(3)
    static let quickEndsAllowed = 3
    static let backoff: Duration = .seconds(1)

    /// Consecutive streams that ended normally after less than `quickLifetime`.
    private(set) var quickEnds = 0

    /// `delivered`: the stream showed at least one picture; `failed`: it ended with an error; `lifetime`: how long it
    /// was open.
    mutating func streamEnded(delivered: Bool, failed: Bool, lifetime: Duration) -> Action {
        guard delivered, !failed else {
            quickEnds = 0
            return .retryLater
        }
        quickEnds = lifetime < Self.quickLifetime ? quickEnds + 1 : 0
        return .reopen(after: quickEnds > Self.quickEndsAllowed ? Self.backoff : .zero)
    }

    /// A new visit (or display) starts afresh.
    mutating func reset() { quickEnds = 0 }
}

/// Who draws the pointer on the screen page. Every stream asks for `cursor=client` (ScreenStreamOptions.live): the Mac
/// leaves the pointer out of the pictures and sends a cursor part before its first picture. A stream whose first
/// picture comes without one has the pointer in its pictures: the page drops the one it drew for an earlier stream,
/// else there would be two.
struct ScreenStreamCursorPolicy: Equatable, Sendable {
    private(set) var sawCursorPart = false
    private(set) var sawPicture = false

    /// A new stream: nothing seen yet.
    mutating func streamOpened() {
        sawCursorPart = false
        sawPicture = false
    }

    mutating func cursorPart() { sawCursorPart = true }

    /// A picture arrived. true = clear the pointer drawn here (this stream's first picture, with no cursor part before it).
    mutating func picture() -> Bool {
        defer { sawPicture = true }
        return !sawPicture && !sawCursorPart
    }
}
