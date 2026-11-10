import Foundation
import Synchronization
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The screen's connection state (PROTOCOL.md「屏幕」「连接状态」): lenient decoding of `ScreenStatus.states` /
/// `console`, the `screen.state` account event and `application/vnd.yoyo-control.status+json` stream parts, and the page's
/// `ScreenConnectionModel` (status part > `screen.state` entry > a 0.7 s gap).
@Suite("Screen connection")
struct ScreenConnectionTests {
    private func status(_ json: String) throws -> ScreenStatus { try JSONDecoder().decode(ScreenStatus.self, from: Data(json.utf8)) }
    private func event(_ json: String) throws -> YoyoEvent? { YoyoEvent(json: Data(json.utf8)) }

    // MARK: Decoding

    @Test func statusCarriesStatesAndConsole() throws {
        let s = try status(#"""
        {"available":true,"displays":[{"id":76,"width":1512,"height":982,"main":true}],
         "states":[{"display":76,"main":true,"phase":"ready","since":1000},
                   {"display":3,"phase":"unavailable","reason":"no-permission","since":2000,
                    "retryAt":9000,"detail":"no screen recording permission"}],
         "console":{"user":"alex","locked":true}}
        """#)
        #expect(s.states == [
            ScreenDisplayState(display: 76, main: true, phase: .ready, since: 1000),
            ScreenDisplayState(display: 3, phase: .unavailable, reason: "no-permission", since: 2000,
                               retryAt: 9000, detail: "no screen recording permission"),
        ])
        // a `user` (an older answer's) is ignored
        #expect(s.console == ScreenConsole(locked: true))
    }

    @Test func anAnswerWithoutStatesHasNone() throws {
        let s = try status(#"{"available":true,"screenRecording":true,"displays":[{"id":1,"width":10,"height":10}]}"#)
        #expect(s.states.isEmpty && s.console == nil)
        let nulls = try status(#"{"available":true,"states":null,"console":null}"#)
        #expect(nulls.states.isEmpty && nulls.console == nil)
        let junk = try status(#"{"available":true,"states":"soon","console":[1]}"#)
        #expect(junk.states.isEmpty && junk.console == nil && junk.available)
    }

    @Test func statesDecodeLeniently() throws {
        let before = Date().timeIntervalSince1970 * 1000 - 1
        let s = try status(#"""
        {"states":[{"display":1,"phase":"warp-drive","reason":"cosmic-rays","note":"aurora"},
                   {"display":2,"phase":null,"reason":null,"note":null,"since":null,"retryAt":"later","main":"yes","label":""},
                   {"phase":"ready"},{"display":-1,"phase":"ready"},{"display":1.5,"phase":"ready"},"x",
                   {"display":4,"phase":"connecting","reason":"starting","since":5}],
         "console":{"user":null}}
        """#)
        #expect(s.states.map(\.display) == [1, 2, 4])
        // unknown phase: reconnecting; unknown codes are kept (the page shows a generic text for them)
        #expect(s.states[0].phase == .reconnecting && s.states[0].reason == "cosmic-rays")
        // since missing: now
        #expect(s.states[0].since >= before)
        #expect(s.states[1].phase == .reconnecting && s.states[1].reason == nil)
        #expect(s.states[1].retryAt == nil && !s.states[1].main)
        #expect(s.states[2] == ScreenDisplayState(display: 4, phase: .connecting, reason: "starting", since: 5))
        // locked missing = false
        #expect(s.console == ScreenConsole(locked: false))
    }

    @Test func decodesScreenStateEvents() throws {
        #expect(try event(#"""
        {"type":"screen.state","ts":1,"states":[{"display":1,"main":true,"phase":"reconnecting","reason":"helper-restart","since":7}],
         "console":{"user":"sam","locked":false}}
        """#) == .state(states: [ScreenDisplayState(display: 1, main: true, phase: .reconnecting, reason: "helper-restart", since: 7)],
                              console: ScreenConsole()))
        #expect(try event(#"{"type":"screen.state","ts":1,"states":null,"console":null}"#) == .state(states: [], console: nil))
        #expect(try event(#"{"type":"screen.state"}"#) == .state(states: [], console: nil))
    }

    @Test func statusPartBodiesDecodeLeniently() throws {
        let full = try #require(ScreenStreamStatus(json: Data(#"""
        {"display":1,"main":true,"phase":"reconnecting","reason":"helper-restart","since":10,"retryAt":20,
         "console":{"user":"alex","locked":false},"extra":[1]}
        """#.utf8)))
        #expect(full.state == ScreenDisplayState(display: 1, main: true, phase: .reconnecting, reason: "helper-restart", since: 10, retryAt: 20))
        #expect(full.console == ScreenConsole())
        let bare = try #require(ScreenStreamStatus(json: Data(#"{"display":1,"phase":"elsewhere","console":"?"}"#.utf8)))
        #expect(bare.state.phase == .reconnecting && bare.console == nil)
        #expect(ScreenStreamStatus(json: Data(#"{"phase":"ready"}"#.utf8)) == nil)
        #expect(ScreenStreamStatus(json: Data("[1]".utf8)) == nil)
        #expect(ScreenStreamStatus(json: Data("nope".utf8)) == nil)
    }

    @Test func streamRequestsAskForStatusParts() {
        let live = ScreenStreamOptions.live(codecs: [.h264])
        #expect(live.status)
        var body: [String: Any] = [:]
        live.add(to: &body)
        #expect(body["status"] as? Int == 1)
        // not set, not sent
        var plain: [String: Any] = [:]
        ScreenStreamOptions().add(to: &plain)
        #expect(plain["status"] == nil)
    }

    // MARK: Status parts in the stream

    private static let video = Data([0, 0, 0, 1, 0x65, 0x88, 0x84])
    private static let statusJSON = Data(#"{"display":1,"main":true,"phase":"reconnecting","reason":"helper-restart","since":5}"#.utf8)

    private static func part(_ body: Data, type: String, seq: Int, kind: String) -> Data {
        var d = Data("--frame\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nX-Frame-Seq: \(seq)\r\nX-Frame-Kind: \(kind)\r\n\r\n".utf8)
        d.append(body)
        d.append(Data("\r\n".utf8))
        return d
    }

    private static var body: Data {
        var d = part(statusJSON, type: "application/vnd.yoyo-control.status+json", seq: 1, kind: "status")
        d.append(part(video, type: "video/h264", seq: 2, kind: "delta"))
        d.append(part(statusJSON, type: "application/vnd.yoyo-control.status+json; charset=utf-8", seq: 3, kind: "status"))
        d.append(part(video, type: "video/h264", seq: 4, kind: "delta"))
        d.append(Data("--frame--\r\n".utf8))
        return d
    }

    private func check(_ parts: [ScreenStreamPart]) {
        #expect(parts.map(\.kind) == [.status, .h264, .status, .h264])
        #expect(parts.map(\.seq) == [1, 2, 3, 4])
        #expect(parts[0].body == Self.statusJSON && parts[0].headers.kind == "status")
        #expect(parts[1].body == Self.video && parts[3].body == Self.video)
    }

    @Test func statusPartsInTheRawBody() throws {
        var a = StreamPartAssembler()
        _ = try a.receive(status: 200, contentType: "application/vnd.yoyo-control.stream; boundary=frame", expectedLength: -1)
        check(a.feed(Self.body))
        let body = Self.body
        for cut in stride(from: 1, to: body.count, by: 5) {
            var p = StreamPartParser(boundary: "frame")
            check(p.feed(body.prefix(cut)) + p.feed(body.suffix(from: cut)))
        }
    }

    @Test func statusPartsWhenURLSessionSplitsTheStream() throws {
        // the first response is the stream's own head, or already the first part (a status part comes first)
        for headFirst in [true, false] {
            var a = StreamPartAssembler()
            var parts: [ScreenStreamPart] = []
            if headFirst {
                _ = try a.receive(status: 200, contentType: "multipart/x-mixed-replace; boundary=frame", expectedLength: -1)
            }
            func response(_ body: Data, _ type: String, seq: Int, kind: String) throws {
                let fields = ["Content-Type": type, "X-Frame-Seq": String(seq), "X-Frame-Kind": kind]
                parts += try a.receive(status: 200, contentType: type, expectedLength: Int64(body.count), headers: ScreenPartHeaders { fields[$0] })
                parts += a.feed(body.prefix(3))
                parts += a.feed(body.suffix(from: 3))
            }
            try response(Self.statusJSON, "application/vnd.yoyo-control.status+json", seq: 1, kind: "status")
            try response(Self.video, "video/h264", seq: 2, kind: "delta")
            try response(Self.statusJSON, "application/vnd.yoyo-control.status+json; charset=utf-8", seq: 3, kind: "status")
            try response(Self.video, "video/h264", seq: 4, kind: "delta")
            parts += a.finish()
            #expect(a.split)
            check(parts)
        }
    }

    @Test func oversizedStatusPartsAreDropped() {
        var a = StreamPartAssembler()
        _ = try? a.receive(status: 200, contentType: "multipart/x-mixed-replace; boundary=b", expectedLength: -1)
        _ = try? a.receive(status: 200, contentType: "application/vnd.yoyo-control.status+json", expectedLength: Int64(ScreenStreamPart.maxStatusPart + 1))
        #expect(a.feed(Data(repeating: 0x7B, count: 100)).isEmpty)
        #expect(a.finish().isEmpty)
    }

    @Test func theRouterNeitherAcksNorCountsStatusParts() {
        let sent = Mutex<[ScreenStreamAck]>([])
        let acks = ScreenAckSender(stream: "s1") { ack, done in
            sent.withLock { $0.append(ack) }
            done(.ok)
        }
        let statuses = Mutex<[ScreenStreamStatus]>([])
        let pictures = Mutex(0)
        let router = ScreenStreamRouter(acks: acks, stats: nil, handlers: .init(
            makeDecoder: { _ in pictures.withLock { $0 += 1 }; return nil }, onCursor: { _ in },
            onStatus: { s in statuses.withLock { $0.append(s) } }))
        router.route(ScreenStreamPart(kind: .status, body: Self.statusJSON, headers: ScreenPartHeaders(seq: 1, kind: "status")))
        #expect(sent.withLock { $0 }.isEmpty)
        router.route(ScreenStreamPart(kind: .h264, body: Self.video, headers: ScreenPartHeaders(seq: 2, kind: "delta")))
        router.route(ScreenStreamPart(kind: .status, body: Data("garbage".utf8), headers: ScreenPartHeaders(seq: 3, kind: "status")))
        router.route(ScreenStreamPart(kind: .h264, body: Self.video, headers: ScreenPartHeaders(seq: 4, kind: "delta")))
        // only pictures are acked, none asks for a key picture (a status part's seq is no gap)
        #expect(sent.withLock { $0 } == [ScreenStreamAck(stream: "s1", seq: 2), ScreenStreamAck(stream: "s1", seq: 4)])
        #expect(pictures.withLock { $0 } == 2)
        #expect(statuses.withLock { $0.map(\.state.reason) } == ["helper-restart"])
        router.stop()
    }

    // MARK: The connection model

    private let t0 = ContinuousClock.now
    private func t(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    private static func state(_ phase: ScreenPhase, _ reason: String? = nil, display: UInt32 = 1, main: Bool = true,
                              retryAt: Double? = nil) -> ScreenDisplayState {
        ScreenDisplayState(display: display, main: main, phase: phase, reason: reason, since: 1, retryAt: retryAt)
    }

    /// A model showing display 1 (the main one) with a stream that showed a picture at 0.
    private func live() -> ScreenConnectionModel {
        var m = ScreenConnectionModel()
        m.target(display: 1, main: true)
        m.streamOpened()
        m.picture(at: t(0))
        return m
    }

    @Test func anOldServersGapShowsReconnectingAfterTheGrace() {
        var m = live()
        #expect(m.output(at: t(0)).phase == .live && m.deadline(after: t(0)) == nil)
        m.streamEnded(at: t(1000))
        #expect(m.output(at: t(1600)).phase == .live)
        #expect(m.deadline(after: t(1600)) == t(1700))
        #expect(m.output(at: t(1700)).phase == .reconnecting(reason: nil))
        #expect(m.deadline(after: t(1700)) == nil)
        // the reopened stream's first picture
        m.streamOpened()
        #expect(m.output(at: t(2000)).phase == .reconnecting(reason: nil))
        m.picture(at: t(2100))
        #expect(m.output(at: t(2100)) == .init(phase: .live))
        #expect(m.deadline(after: t(2100)) == nil)
    }

    @Test func aQuickReopenNeverShowsIt() {
        var m = live()
        m.streamEnded(at: t(1000))
        m.streamOpened()
        m.picture(at: t(1300))
        #expect(m.output(at: t(1800)).phase == .live && m.deadline(after: t(1800)) == nil)
    }

    @Test func anExplicitStatusShowsAtOnceAndOnlyANewPictureEndsIt() {
        var m = live()
        m.status(ScreenStreamStatus(state: Self.state(.reconnecting, "helper-restart"), console: ScreenConsole(locked: true)), at: t(500))
        #expect(m.output(at: t(500)).phase == .reconnecting(reason: "helper-restart"))
        #expect(m.output(at: t(500)).console == ScreenConsole(locked: true))
        m.streamEnded(at: t(1010))
        m.streamOpened()
        // the new stream waits for the picture, then says ready: still waiting for the picture
        m.status(ScreenStreamStatus(state: Self.state(.connecting, "starting")), at: t(1100))
        m.status(ScreenStreamStatus(state: Self.state(.ready)), at: t(2500))
        #expect(m.output(at: t(2600)).phase == .reconnecting(reason: "starting"))
        m.picture(at: t(2700))
        #expect(m.output(at: t(2700)).phase == .live)
    }

    @Test func aPictureAfterTheStatusWins() {
        var m = live()
        m.status(ScreenStreamStatus(state: Self.state(.connecting, "starting")), at: t(100))
        #expect(m.output(at: t(100)).phase == .reconnecting(reason: "starting"))
        m.picture(at: t(200))
        #expect(m.output(at: t(200)).phase == .live)
    }

    @Test func theEventEntryIsFoundByIdElseTheMainOne() {
        var m = live()
        // the main display under a new id (1 → 76)
        m.states([Self.state(.reconnecting, "helper-restart", display: 76)], console: nil, at: t(500))
        #expect(m.output(at: t(500)).phase == .reconnecting(reason: "helper-restart"))
        // by id first
        m.states([Self.state(.reconnecting, "helper-restart", display: 76), Self.state(.unavailable, "timeout", main: false, retryAt: 9)],
                 console: nil, at: t(600))
        #expect(m.output(at: t(600)).phase == .unavailable(reason: "timeout", retryAt: 9))
        // another display doesn't take the main entry
        var other = ScreenConnectionModel()
        other.target(display: 3, main: false)
        other.streamOpened()
        other.picture(at: t(0))
        other.states([Self.state(.reconnecting, "helper-restart", display: 76)], console: nil, at: t(500))
        #expect(other.output(at: t(500)).phase == .live)
        other.states([Self.state(.reconnecting, "helper-restart", display: 76), Self.state(.unavailable, "timeout", display: 3, main: false, retryAt: 42)],
                     console: nil, at: t(600))
        #expect(other.output(at: t(600)).phase == .unavailable(reason: "timeout", retryAt: 42))
    }

    @Test func theOpenStreamsStatusOutranksTheEvent() {
        var m = live()
        m.status(ScreenStreamStatus(state: Self.state(.ready)), at: t(100))
        m.picture(at: t(200))
        m.states([Self.state(.reconnecting, "helper-restart")], console: nil, at: t(300))
        #expect(m.output(at: t(300)).phase == .live)
        // once the stream is gone, the newer of its last part and the entry counts
        m.streamEnded(at: t(400))
        #expect(m.output(at: t(400)).phase == .reconnecting(reason: "helper-restart"))
    }

    @Test func aHelperRestartExplainsTheGapAtOnce() {
        var m = live()
        m.streamEnded(at: t(1000))
        m.states([Self.state(.reconnecting, "helper-restart")], console: nil, at: t(1050))
        #expect(m.output(at: t(1050)).phase == .reconnecting(reason: "helper-restart"))
        // the next helper's first snapshot says ready: the picture still has to come
        m.states([Self.state(.ready)], console: nil, at: t(3000))
        #expect(m.output(at: t(3000)).phase == .reconnecting(reason: "helper-restart"))
        m.picture(at: t(3200))
        #expect(m.output(at: t(3200)).phase == .live)
    }

    @Test func repeatedStatesKeepTheirTime() {
        var m = live()
        m.states([Self.state(.unavailable, "helper-down")], console: nil, at: t(100))
        #expect(m.output(at: t(100)).phase.isUnavailable)
        m.picture(at: t(200))
        #expect(m.output(at: t(200)).phase == .live)
        // the 10 s status poll repeats the same entry (only `since` / `detail` may differ): no flash of the overlay
        var same = Self.state(.unavailable, "helper-down")
        same.since = 99
        same.detail = "exited with status 1"
        m.states([same], console: nil, at: t(10_000))
        #expect(m.output(at: t(10_000)).phase == .live)
        // a change counts
        m.states([Self.state(.unavailable, "timeout")], console: nil, at: t(11_000))
        #expect(m.output(at: t(11_000)).phase == .unavailable(reason: "timeout", retryAt: nil))
    }

    @Test func retryShowsReconnectingUntilSomethingNewComes() {
        var m = live()
        m.streamEnded(at: t(100))
        m.states([Self.state(.unavailable, "helper-down", retryAt: 5000)], console: nil, at: t(110))
        #expect(m.output(at: t(110)).phase == .unavailable(reason: "helper-down", retryAt: 5000))
        m.retry(at: t(2000))
        #expect(m.output(at: t(2000)).phase == .reconnecting(reason: nil))
        m.streamOpened()
        m.status(ScreenStreamStatus(state: Self.state(.unavailable, "helper-down", retryAt: 9000)), at: t(2100))
        #expect(m.output(at: t(2100)).phase == .unavailable(reason: "helper-down", retryAt: 9000))
        m.retry(at: t(3000))
        m.picture(at: t(3100))
        #expect(m.output(at: t(3100)).phase == .live)
    }

    @Test func anUnavailableThenReadyWaitsGenerically() {
        var m = live()
        m.streamEnded(at: t(100))
        m.states([Self.state(.unavailable, "no-permission")], console: nil, at: t(110))
        m.states([Self.state(.ready)], console: nil, at: t(5000))
        // not "missing a permission" any more, but no picture yet
        #expect(m.output(at: t(5000)).phase == .reconnecting(reason: nil))
    }

    @Test func resetForgetsTheLastDisplay() {
        var m = live()
        m.status(ScreenStreamStatus(state: Self.state(.reconnecting, "helper-restart")), at: t(100))
        m.streamEnded(at: t(110))
        m.reset()
        m.target(display: 2, main: false)
        #expect(m.output(at: t(5000)).phase == .live && m.deadline(after: t(5000)) == nil)
    }

    @Test func noPictureYetIsNotAGap() {
        var m = ScreenConnectionModel()
        m.target(display: 1, main: true)
        m.streamOpened()
        #expect(m.output(at: t(5000)).phase == .live)
    }

    @Test func retryDelayFollowsTheMacsNextTry() {
        #expect(ScreenConnectionModel.retryDelay(retryAt: nil, nowMs: 0) == .seconds(5))
        #expect(ScreenConnectionModel.retryDelay(retryAt: 7000, nowMs: 1000) == .seconds(6))
        #expect(ScreenConnectionModel.retryDelay(retryAt: 0, nowMs: 1000) == .seconds(2))
        #expect(ScreenConnectionModel.retryDelay(retryAt: 1e12, nowMs: 0) == .seconds(15))
    }

    // MARK: Texts

    @Test func reasonsGetTextsAndUnknownOnesTheGenericOne() {
        #expect(ScreenConnectionText.title(.live) == nil)
        #expect(ScreenConnectionText.title(.reconnecting(reason: "starting")) == ("Connecting…"))
        #expect(ScreenConnectionText.title(.reconnecting(reason: "helper-restart")) == ("Reconnecting…"))
        #expect(ScreenConnectionText.detail(.reconnecting(reason: "helper-restart")) == ("The screen helper is restarting"))
        #expect(ScreenConnectionText.detail(.reconnecting(reason: "warp")) == nil)
        #expect(ScreenConnectionText.title(.reconnecting(reason: nil)) == ("Reconnecting…"))
        #expect(ScreenConnectionText.detail(.reconnecting(reason: nil)) == nil)
        #expect(ScreenConnectionText.detail(.unavailable(reason: "warp", retryAt: nil)) == ("The Mac’s screen can’t be shown right now."))
        for code in ["helper-restart", "timeout", "no-session", "no-permission", "helper-down"] {
            #expect(ScreenConnectionText.text(code) != nil, "\(code)")
        }
        let stats = ScreenConnectionText.stats(.init(phase: .reconnecting(reason: "helper-restart"), console: ScreenConsole(locked: true)))
        #expect(stats == "reconnecting helper-restart · locked")
        #expect(ScreenConnectionText.stats(.init(phase: .reconnecting(reason: nil), console: ScreenConsole())) == "reconnecting")
        #expect(ScreenConnectionText.stats(.init(phase: .live, state: Self.state(.reconnecting, "helper-restart"), holding: true))
            == "live reconnecting (holding)")
    }

    @Test func unknownCodesAndFieldsDecodeAndGetTheGenericWords() throws {
        // codes the page has no words of its own for, and fields it doesn't know (`note`, `label`): decoded as sent or
        // ignored, never a failure
        func decode(_ json: String) throws -> ScreenDisplayState {
            try JSONDecoder().decode(ScreenDisplayState.self, from: Data(json.utf8))
        }
        for code in ["console-changed", "console-busy", "connection-lost", "route-change"] {
            let s = try decode(#"{"display":1,"main":true,"phase":"reconnecting","reason":"\#(code)","note":"login-window","label":"frontdesk","since":5}"#)
            #expect(s == ScreenDisplayState(display: 1, main: true, phase: .reconnecting, reason: code, since: 5))
            #expect(ScreenConnectionText.text(code) == nil, "\(code)")
            #expect(ScreenConnectionText.title(.reconnecting(reason: code)) == ("Reconnecting…"))
            #expect(ScreenConnectionText.detail(.reconnecting(reason: code)) == nil)
        }
        for code in ["auth-failed", "sharing-off"] {
            let s = try decode(#"{"display":3135045633,"phase":"unavailable","reason":"\#(code)","retryAt":9000}"#)
            #expect(s.reason == code && s.phase == .unavailable && s.display == 0xBADD_0001)
            #expect(ScreenConnectionText.detail(.unavailable(reason: code, retryAt: 9000)) == ("The Mac’s screen can’t be shown right now."))
        }
        let part = try #require(ScreenStreamStatus(json: Data(#"""
        {"display":1,"main":true,"phase":"ready","note":"lock-screen","since":5,"console":{"user":null,"locked":true}}
        """#.utf8)))
        #expect(part.state == ScreenDisplayState(display: 1, main: true, phase: .ready, since: 5))
        #expect(part.console == ScreenConsole(locked: true))
        // an unknown display kind and an unknown field: the kind is nil, the field ignored
        let status = try status(#"""
        {"available":true,"onConsole":false,"displays":[{"id":9,"width":1280,"height":800,"kind":"virtual","label":"Yoyo Control"}]}
        """#)
        #expect(status.available && status.displays.count == 1 && status.displays[0].kind == nil && status.displays[0].name == nil)
    }

    // MARK: Reopen hold

    @Test func aReopenHoldsTheLastPictureUndimmedForOneAndAHalfSeconds() {
        var m = live()
        // the Mac ended the stream cleanly: the page reopens it
        m.streamEnded(at: t(1000))
        m.reopening(at: t(1000))
        // no overlay, no dim: live — past the 0.7 s an unexplained gap gets otherwise (holding from there)
        for ms in [1000, 1699, 1700, 2000, 2499] {
            let o = m.output(at: t(ms))
            #expect(o.phase == .live && o.holding == (ms >= 1700), "\(ms)")
        }
        // the page wakes when the hold is up
        #expect(m.deadline(after: t(1800)) == t(2500))
        let after = m.output(at: t(2500))
        #expect(after.phase == .reconnecting(reason: nil) && !after.holding)
        // the new stream's first picture: live again, nothing to wait for
        m.streamOpened()
        m.picture(at: t(2600))
        #expect(m.output(at: t(2600)) == .init(phase: .live))
        #expect(m.deadline(after: t(2600)) == nil)
    }

    @Test func aStateDuringAReopenIsHeldThenSaid() {
        var m = live()
        m.streamEnded(at: t(1000))
        m.reopening(at: t(1000))
        m.status(ScreenStreamStatus(state: Self.state(.connecting, "starting")), at: t(1100))
        #expect(m.output(at: t(1500)).phase == .live)
        #expect(m.output(at: t(2500)).phase == .reconnecting(reason: "starting"))
        // a picture within the hold never shows the overlay
        var quick = live()
        quick.streamEnded(at: t(1000))
        quick.reopening(at: t(1000))
        quick.status(ScreenStreamStatus(state: Self.state(.connecting, "starting")), at: t(1100))
        quick.picture(at: t(1400))
        #expect(quick.output(at: t(1400)).phase == .live && !quick.output(at: t(1400)).holding)
    }

    @Test func whatIsNotAReopenShowsAtOnceAndIsNeverHeldAfterwards() {
        // the helper restarting before any reopen: said at once
        var m = live()
        m.states([Self.state(.reconnecting, "helper-restart")], console: nil, at: t(1000))
        #expect(m.output(at: t(1000)).phase == .reconnecting(reason: "helper-restart"))
        // a reopen after it doesn't take the overlay away again
        m.streamEnded(at: t(1100))
        m.reopening(at: t(1100))
        #expect(m.output(at: t(1200)).phase == .reconnecting(reason: "helper-restart"))
        // unavailable: at once, even during a reopen
        var u = live()
        u.streamEnded(at: t(1000))
        u.reopening(at: t(1000))
        u.states([Self.state(.unavailable, "helper-down")], console: nil, at: t(1050))
        #expect(u.output(at: t(1050)).phase.isUnavailable)
        // Retry: "Reconnecting" at once
        var r = live()
        r.streamEnded(at: t(1000))
        r.reopening(at: t(1000))
        r.retry(at: t(1100))
        #expect(r.output(at: t(1100)).phase == .reconnecting(reason: nil))
        // no picture yet: nothing to hold
        var fresh = ScreenConnectionModel()
        fresh.target(display: 1, main: true)
        fresh.reopening(at: t(0))
        fresh.status(ScreenStreamStatus(state: Self.state(.reconnecting, "helper-restart")), at: t(10))
        #expect(fresh.output(at: t(10)).phase == .reconnecting(reason: "helper-restart"))
    }

    @Test func anEndThatIsNoReopenKeepsTheShortGrace() {
        // a failure (polling next): the 0.7 s grace as before
        var m = live()
        m.streamEnded(at: t(1000))
        #expect(m.output(at: t(1600)).phase == .live && !m.output(at: t(1600)).holding)
        #expect(m.output(at: t(1700)).phase == .reconnecting(reason: nil))
    }
}
