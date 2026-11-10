import Foundation
import YoyoClipboard
import YoyoCore

/// What the screen page says about the picture of the display it shows (docs/PROTOCOL.md「屏幕」「连接状态」): live,
/// reconnecting (the last picture stays, dimmed, with why) or unavailable (why, and a Retry). Pure: the page feeds it
/// what happens, with the time, and asks for the output.
///
/// Three sources, best first: the status parts of the open stream; the latest `screen.state` entry for the display
/// (by id, else the `main: true` entry while the main display is shown: its id can change under the same picture);
/// local inference (a stream ended or failed and no picture came for `gapGrace`: a generic "Reconnecting"). A state
/// that isn't `ready` shows at once, until a picture arrives after it: only a NEW DECODED PICTURE takes the overlay
/// away, never a `ready` state (that one only means the picture is on its way). Without states (the helper isn't
/// answering yet) only the inference speaks.
///
/// A reopen is held: when the page reopens a stream that showed pictures (`reopening`: the Mac ended it cleanly, or
/// the page moved it), the last picture stays as it is, live and undimmed, for up to `reopenHold` from the moment it
/// stopped being live; only then does the reconnecting overlay show (most reopens bring the next picture well within it).
struct ScreenConnectionModel: Sendable {
    typealias Instant = ContinuousClock.Instant

    enum Phase: Sendable, Equatable {
        case live
        /// `reason`: a `ScreenStateReason` code (nil = not known: generic).
        case reconnecting(reason: String?)
        /// `retryAt`: ms (Mac clock) of the Mac's next attempt.
        case unavailable(reason: String?, retryAt: Double?)

        var isLive: Bool { self == .live }
        var isUnavailable: Bool { if case .unavailable = self { true } else { false } }
    }

    struct Output: Sendable, Equatable {
        var phase: Phase
        /// The state the output stands on (nil: none known), for the stats line.
        var state: ScreenDisplayState?
        var console: ScreenConsole?
        /// A reopen is held (the phase says live while the picture is on its way back).
        var holding = false
    }

    /// An unexplained gap (the stream ended, no picture since) shows "Reconnecting" after this long: a reopen that
    /// is quick never shows it.
    static let gapGrace: Duration = .milliseconds(700)
    /// How long a reopen keeps the last picture undimmed, without an overlay.
    static let reopenHold: Duration = .milliseconds(1500)

    private struct Received: Sendable {
        var state: ScreenDisplayState
        var at: Instant
        /// The stream it came on (status parts), nil for `screen.state` entries.
        var stream: Int?
    }

    /// The display shown (nil = the server's default) and whether it is the main one.
    private(set) var display: UInt32?
    private(set) var showsMain = true
    /// The latest `screen.state` (or `GET /screen`) states, with when each entry last changed here.
    private var states: [ScreenDisplayState] = []
    private var statesAt: [UInt32: Instant] = [:]
    private(set) var console: ScreenConsole?
    /// The latest status part (of this or an earlier stream of the same display).
    private var part: Received?
    private var stream = 0
    private var streamOpen = false
    private var lastPicture: Instant?
    /// Since when the stream is gone (ended or failed) with no picture since.
    private var gapSince: Instant?
    /// The user asked to try again (and no picture came since).
    private var retried: Instant?
    /// A state that isn't `ready` came since the last picture: the reason of the last one if it was a reconnect.
    private var explained: Explained?
    private struct Explained: Sendable { var reason: String? }
    /// Since when the picture stopped being live (a stream ended, a state that isn't `ready`, a reopen), with no
    /// picture since: the hold counts from there.
    private var notLiveSince: Instant?
    /// The page is reopening a stream that showed pictures (and no picture came since).
    private var reopenSince: Instant?
    /// A state that isn't a reopen's came since the last picture (it showed at once): nothing is held after it.
    private var unheld = false

    init() {}

    // MARK: Inputs

    /// What is shown (no reset: the main display's id can change under the same picture).
    mutating func target(display: UInt32?, main: Bool) {
        self.display = display
        showsMain = main
    }

    /// Another display (or the page starts afresh): nothing of the last one counts.
    mutating func reset() {
        part = nil
        streamOpen = false
        lastPicture = nil
        gapSince = nil
        retried = nil
        explained = nil
        notLiveSince = nil
        reopenSince = nil
        unheld = false
    }

    mutating func streamOpened() {
        stream += 1
        streamOpen = true
    }

    /// The stream ended or failed (pictures may still come from polling).
    mutating func streamEnded(at now: Instant) {
        streamOpen = false
        if gapSince == nil { gapSince = now }
        if notLiveSince == nil { notLiveSince = now }
    }

    /// The page reopens a stream that showed pictures (the Mac ended it cleanly, or the page moved it): held.
    mutating func reopening(at now: Instant) {
        guard lastPicture != nil else { return }
        if reopenSince == nil { reopenSince = now }
        if notLiveSince == nil { notLiveSince = now }
    }

    /// A new picture was decoded and shows.
    mutating func picture(at now: Instant) {
        lastPicture = now
        gapSince = nil
        retried = nil
        explained = nil
        notLiveSince = nil
        reopenSince = nil
        unheld = false
    }

    /// A status part of the open stream.
    mutating func status(_ s: ScreenStreamStatus, at now: Instant) {
        part = Received(state: s.state, at: now, stream: stream)
        if let c = s.console { console = c }
        noteExplained(s.state, at: now)
    }

    /// The states of a `screen.state` event or a `GET /screen` answer. An entry that shows what it showed before keeps
    /// its time (the 10 s status poll repeats them).
    mutating func states(_ list: [ScreenDisplayState], console: ScreenConsole?, at now: Instant) {
        var times: [UInt32: Instant] = [:]
        for s in list {
            let same = states.first { $0.display == s.display }.map { $0.shows(like: s) } ?? false
            times[s.display] = same ? statesAt[s.display] ?? now : now
        }
        states = list
        statesAt = times
        self.console = console
        // a change of the display's entry (the open stream's own status outranks it)
        if let e = entry, e.at == now, !hasStreamPart { noteExplained(e.state, at: now) }
    }

    /// The user asked to try again: older states no longer count; "Reconnecting" until something new comes.
    mutating func retry(at now: Instant) {
        retried = now
        explained = nil
        reopenSince = nil
        if gapSince == nil { gapSince = now }
    }

    // MARK: Output

    func output(at now: Instant) -> Output {
        let raw = rawPhase(at: now)
        var phase = raw.0
        let cur = raw.1
        var holding = false
        if case .reconnecting = phase, let until = holdUntil, now < until {
            phase = .live
            holding = true
        }
        return Output(phase: phase, state: cur?.state, console: console, holding: holding)
    }

    /// The phase before any hold, and the state it stands on.
    private func rawPhase(at now: Instant) -> (Phase, Received?) {
        let cur = current
        let after = [lastPicture, retried].compactMap { $0 }.max()
        let fresh = cur.map { c in after.map { c.at > $0 } ?? true } ?? false
        var phase = Phase.live
        if let cur, fresh, cur.state.phase == .unavailable {
            phase = .unavailable(reason: cur.state.reason, retryAt: cur.state.retryAt)
        } else if let cur, fresh, cur.state.phase != .ready {
            phase = .reconnecting(reason: cur.state.reason)
        } else if let explained {
            phase = .reconnecting(reason: explained.reason)
        } else if retried != nil {
            phase = .reconnecting(reason: nil)
        } else if let gapSince, now - gapSince >= Self.gapGrace {
            phase = .reconnecting(reason: nil)
        }
        return (phase, cur)
    }

    /// Until when a reconnect is held (nil: it isn't): a picture to hold, no Retry since, and a reopen.
    private var holdUntil: Instant? {
        guard lastPicture != nil, retried == nil, !unheld, let since = notLiveSince, reopenSince != nil else { return nil }
        return since + Self.reopenHold
    }

    /// How long the page waits before asking again for a display the Mac called unavailable: until the Mac's own next
    /// try (`retryAt`, ms on the Mac's clock, so only roughly), within 2…15 s; 5 s when not given.
    static func retryDelay(retryAt: Double?, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> Duration {
        guard let retryAt, retryAt.isFinite else { return .seconds(5) }
        return .milliseconds(Int(min(max(retryAt - nowMs, 2000), 15000)))
    }

    /// When the output changes by itself (an unexplained gap turning into "Reconnecting"); nil = only on input.
    func deadline(after now: Instant) -> Instant? {
        var at: [Instant] = []
        if let gapSince { at.append(gapSince + Self.gapGrace) }
        // a hold ends by itself: when one runs now, or will once the gap's grace is up
        if let until = holdUntil { at.append(until) }
        return at.filter { $0 > now }.min()
    }

    // MARK: Internals

    /// The `screen.state` entry of the display shown: by id, else (the main display) the `main: true` one.
    private var entry: Received? {
        let byId = display.flatMap { id in states.first { $0.display == id } }
        guard let s = byId ?? (showsMain ? states.first(where: \.main) : nil) else { return nil }
        return Received(state: s, at: statesAt[s.display] ?? .now, stream: nil)
    }

    private var hasStreamPart: Bool { streamOpen && part?.stream == stream }

    /// The state that counts: the open stream's status part; else the newer of an earlier stream's last part and the
    /// `screen.state` entry.
    private var current: Received? {
        if hasStreamPart { return part }
        guard let e = entry else { return part }
        guard let p = part else { return e }
        return p.at > e.at ? p : e
    }

    private mutating func noteExplained(_ s: ScreenDisplayState, at now: Instant) {
        guard s.phase != .ready else { return }
        explained = Explained(reason: s.phase == .unavailable ? nil : s.reason)
        if notLiveSince == nil { notLiveSince = now }
        // shown at once (unless it comes during a reopen): a later reopen must not take the overlay away again
        if s.phase == .unavailable || reopenSince == nil { unheld = true }
    }
}

/// The page's words for the connection codes (the server sends codes only). Unknown codes get the generic text.
enum ScreenConnectionText {
    /// The overlay's headline.
    static func title(_ phase: ScreenConnectionModel.Phase, host: YoyoComputer = .mac) -> String? {
        switch phase {
        case .live: nil
        case .reconnecting(let reason):
            reason == "starting" ? L("Connecting…") : L("Reconnecting…")
        case .unavailable: host.unavailableTitle
        }
    }

    /// The line under it: why (nil = nothing to add). A computer other than a Mac words its codes itself
    /// (`YoyoComputer.reasonText`).
    static func detail(_ phase: ScreenConnectionModel.Phase, host: YoyoComputer = .mac) -> String? {
        switch phase {
        case .live: nil
        case .reconnecting(let reason): reason.flatMap(host.reasonText)
        case .unavailable(let reason, _): reason.flatMap(host.reasonText) ?? host.unavailableDetail
        }
    }

    /// A reason code's text; nil for codes without one (`starting`, unknown ones).
    static func text(_ reason: String) -> String? {
        switch reason {
        case "helper-restart": L("The screen helper is restarting")
        case "timeout": L("The Mac’s screen isn’t responding")
        case "no-session": L("This account isn’t logged in on the Mac")
        case "no-permission": L("Yoyo Control is missing a permission on the Mac")
        case "helper-down": L("The screen helper can’t start")
        default: nil
        }
    }

    /// The stats line's part (codes, not localized): `reconnecting helper-restart · locked`.
    static func stats(_ o: ScreenConnectionModel.Output) -> String {
        var parts: [String] = []
        switch o.phase {
        case .live:
            parts.append(o.state.map { "live \($0.phase.rawValue)" } ?? "live")
            if o.holding { parts[parts.count - 1] += " (holding)" }
        case .reconnecting(let reason): parts.append("reconnecting" + (reason.map { " \($0)" } ?? ""))
        case .unavailable(let reason, _): parts.append("unavailable" + (reason.map { " \($0)" } ?? ""))
        }
        if o.console?.locked == true { parts.append("locked") }
        return parts.joined(separator: " · ")
    }
}

extension YoyoComputer {
    /// A connection reason code's words: the Mac's codes as `ScreenConnectionText.text`; another computer has no login
    /// session or macOS permission to miss (those get the generic text), and its screen's server is the desktop itself.
    func reasonText(_ reason: String) -> String? {
        guard !isMac else { return ScreenConnectionText.text(reason) }
        switch reason {
        case "helper-restart": return L("The desktop is restarting")
        case "timeout": return L("The desktop isn’t responding")
        case "helper-down": return L("The desktop can’t start")
        default: return nil
        }
    }
}
