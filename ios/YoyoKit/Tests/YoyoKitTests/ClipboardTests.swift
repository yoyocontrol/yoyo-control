import Foundation
import Testing
import UIKit
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The computer's clipboard (PROTOCOL.md「剪贴板」): lenient decoding of the status and the event, what the UI may do per
/// kind (`ClipboardActions`), what the phone's pasteboard becomes, and how a clipboard event lands in the shared state
/// (`YoyoClipboardState`).
@Suite("Clipboard")
struct ClipboardTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }

    // MARK: Decoding

    @Test func decodesTheFullShape() throws {
        let s = try decode(ClipboardStatus.self, #"""
        {"available":true,"item":{"changeCount":42,"kind":"text","preview":"hello⏎ world","size":11,"at":1760000000000,
          "source":"phone","text":"hello\nworld","truncated":false}}
        """#)
        #expect(s.available && s.reason == nil)
        let item = try #require(s.item)
        #expect(item.changeCount == 42 && item.kind == .text && item.text == "hello\nworld" && !item.truncated)
        #expect(item.summary.preview == "hello⏎ world" && item.summary.size == 11 && item.summary.source == .phone)
        #expect(item.summary.date == Date(timeIntervalSince1970: 1_760_000_000))

        let files = try decode(ClipboardStatus.self, #"""
        {"available":true,"item":{"changeCount":43,"kind":"files","preview":"a.pdf, b","size":1200,"at":1,
          "files":[{"name":"a.pdf","size":1200,"dir":false},{"name":"b","size":null,"dir":true},{"name":null}],"moreFiles":2}}
        """#)
        let f = try #require(files.item?.summary)
        #expect(f.kind == .files && f.files.count == 3 && f.moreFiles == 2)
        #expect(f.files[0] == ClipboardFile(name: "a.pdf", size: 1200))
        #expect(f.files[1] == ClipboardFile(name: "b", size: nil, dir: true))
        #expect(f.files[2].name == "file", "a nameless entry keeps its place")

        let image = try decode(ClipboardStatus.self, #"{"available":true,"item":{"changeCount":44,"kind":"image","width":1280,"height":720,"size":340000,"at":1}}"#)
        #expect(image.item?.summary.width == 1280 && image.item?.summary.height == 720 && image.item?.text == nil)
    }

    @Test func anOlderServerShapeAndNullsDecode() throws {
        // no `source`, no `files`, no `truncated`
        let s = try decode(ClipboardStatus.self, #"{"available":true,"item":{"changeCount":5,"kind":"text","preview":"x","size":1,"at":1,"text":"x"}}"#)
        #expect(s.item?.summary.source == .mac && s.item?.summary.files == [] && s.item?.summary.moreFiles == 0 && s.item?.truncated == false)
        let empty = try decode(ClipboardStatus.self, #"{"available":true,"item":null}"#)
        #expect(empty.available && empty.item == nil && empty.kind == .empty)
        let down = try decode(ClipboardStatus.self, #"{"available":false,"reason":"no GUI session","item":null}"#)
        #expect(!down.available && down.reason == "no GUI session" && down.kind == .other)
        let bare = try decode(ClipboardStatus.self, "{}")
        #expect(bare == ClipboardStatus())
        let nulls = try decode(ClipboardStatus.self, #"{"available":null,"reason":"","item":{"changeCount":null,"kind":null,"preview":null,"size":"big","at":null}}"#)
        #expect(!nulls.available && nulls.reason == nil)
        #expect(nulls.item?.summary == ClipboardSummary(changeCount: 0, kind: .other))
    }

    @Test func anUnknownKindIsOther() throws {
        let s = try decode(ClipboardStatus.self, #"{"available":true,"item":{"changeCount":9,"kind":"hologram","preview":"","at":1}}"#)
        #expect(s.item?.kind == .other && s.kind == .other)
        #expect(ClipboardKind(lenient: nil) == .other && ClipboardKind(lenient: "image") == .image)
    }

    @Test func putResponseListsSavedFiles() throws {
        let r = try decode(ClipboardPutResponse.self, #"""
        {"available":true,"item":{"changeCount":50,"kind":"files","preview":"a.png","at":1,"source":"phone","files":[{"name":"a.png","size":3}]},
         "saved":[{"name":"a.png","path":"/Users/alex/Downloads/a.png","size":3},{"path":"/Users/alex/Downloads/b 2.txt"}]}
        """#)
        #expect(r.status.item?.summary.source == .phone)
        #expect(r.saved.count == 2 && r.saved[1].name == "b 2.txt" && r.saved[1].size == 0)
        #expect(r.savedFolderName == "Downloads")
        let text = try decode(ClipboardPutResponse.self, #"{"available":true,"item":{"changeCount":51,"kind":"text","preview":"hi","at":1,"text":"hi"},"saved":[]}"#)
        #expect(text.saved.isEmpty && text.savedFolderName == nil)
    }

    @Test func clipboardChangedEventDecodes() throws {
        let e = YoyoEvent(json: Data(#"{"type":"clipboard.changed","ts":1,"available":true,"item":{"changeCount":7,"kind":"image","width":10,"height":20,"at":1}}"#.utf8))
        guard case .clipboard(let available, let item)? = e else { Issue.record("not a clipboard event: \(String(describing: e))"); return }
        #expect(available == true && item?.changeCount == 7 && item?.kind == .image)
        #expect(YoyoEvent(json: Data(#"{"type":"clipboard.changed","ts":1,"available":false,"item":null}"#.utf8))
            == .clipboard(available: false, summary: nil))
        // nothing said: nil (the state keeps what it knew)
        #expect(YoyoEvent(json: Data(#"{"type":"clipboard.changed","ts":1}"#.utf8)) == .clipboard(available: nil, summary: nil))
    }

    @Test func statusRoundTripsThroughCodable() throws {
        let s = ClipboardStatus(available: true, item: ClipboardItem(summary: ClipboardSummary(changeCount: 3, kind: .files, preview: "a", size: 5,
                                                                                                  files: [ClipboardFile(name: "a", size: 5)], moreFiles: 1, at: 99, source: .agent),
                                                                     text: nil, truncated: true))
        let back = try JSONDecoder().decode(ClipboardStatus.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    // MARK: Actions

    private func status(_ kind: ClipboardKind, text: String? = nil, files: [ClipboardFile] = [], available: Bool = true, reason: String? = nil) -> ClipboardStatus {
        let item: ClipboardItem? = kind == .empty ? nil
            : ClipboardItem(summary: ClipboardSummary(changeCount: 1, kind: kind, preview: text ?? "", size: text?.utf8.count, width: kind == .image ? 1280 : nil,
                                                      height: kind == .image ? 720 : nil, files: files, at: 1), text: text)
        return ClipboardStatus(available: available, reason: reason, item: item)
    }

    @Test func buttonsFollowTheKind() {
        typealias E = ClipboardActions.Enabled
        #expect(ClipboardActions.enabled(nil) == E())
        #expect(ClipboardActions.enabled(status(.text, available: false, reason: "down")) == E(), "nothing while unavailable, sending included")
        #expect(ClipboardActions.enabled(status(.text, text: "hi")) == E(copy: true, share: true, save: false, send: true))
        #expect(ClipboardActions.enabled(status(.image)) == E(copy: true, share: true, save: true, send: true))
        #expect(ClipboardActions.enabled(status(.files, files: [ClipboardFile(name: "a", size: 1)])) == E(copy: false, share: true, save: true, send: true))
        #expect(ClipboardActions.enabled(status(.files, files: [ClipboardFile(name: "d", dir: true)])) == E(copy: false, share: false, save: false, send: true),
                "folders alone: nothing to download")
        #expect(ClipboardActions.enabled(status(.concealed)) == E(send: true))
        #expect(ClipboardActions.enabled(status(.empty)) == E(send: true))
        #expect(ClipboardActions.enabled(status(.other)) == E(send: true))
    }

    @Test func summaryLinePerKind() {
        #expect(ClipboardActions.summaryLine(status(.text, text: "hello world")) == ("hello world", false))
        #expect(ClipboardActions.summaryLine(status(.image)) == ("Image · 1280×720", false))
        #expect(ClipboardActions.summaryLine(status(.files, files: [ClipboardFile(name: "a.pdf", size: 1), ClipboardFile(name: "b.jpg", size: 1)])) == ("2 files · a.pdf, b.jpg", false))
        var many = status(.files, files: [ClipboardFile(name: "a", size: 1)])
        many.item?.summary.moreFiles = 4
        #expect(ClipboardActions.summaryLine(many).text == "5 files · a")
        #expect(ClipboardActions.summaryLine(status(.concealed)) == ("Hidden (password manager)", false))
        #expect(ClipboardActions.summaryLine(status(.empty)) == ("Empty", false))
        #expect(ClipboardActions.summaryLine(status(.text, available: false, reason: "Yoyo Control is not running")) == ("Yoyo Control is not running", true))
        #expect(ClipboardActions.summaryLine(status(.text, available: false)) == ("Clipboard unavailable", true))
    }

    @Test func footerNamesTheSourceAndTheAge() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var s = ClipboardSummary(changeCount: 1, kind: .text, at: (2_000_000 - 20) * 1000)
        #expect(ClipboardActions.footer(s, now: now) == "Copied on the Mac · just now")
        s.source = .phone
        s.at = (2_000_000 - 300) * 1000
        let phone = ClipboardActions.footer(s, now: now)
        #expect(phone.hasPrefix("Sent from this iPhone · ") && phone.contains("5") && phone.hasSuffix("ago"), "\(phone)")
        s.source = .agent
        s.at = 0
        #expect(ClipboardActions.footer(s, now: now) == "Copied by an agent", "no time known: no age; no agent name from the host: generic")
    }

    @Test func codeAndPathsReadMonospaced() {
        #expect(ClipboardActions.looksLikeCode("/Users/alex/dev/project"))
        #expect(ClipboardActions.looksLikeCode("let x = 1;\nprint(x)"))
        #expect(ClipboardActions.looksLikeCode("$ npm run typecheck"))
        #expect(!ClipboardActions.looksLikeCode("Meeting at 3 pm, bring the slides."))
        #expect(!ClipboardActions.looksLikeCode(""))
    }

    @Test func pasteFromPhoneBuildsTextOrFiles() throws {
        typealias C = ClipboardActions.PhoneContent
        #expect(try ClipboardActions.payload(C(string: "hello")) == .text("hello"))
        #expect(try ClipboardActions.payload(C(url: URL(string: "https://example.com")!)) == .text("https://example.com"), "a URL alone is its string")
        #expect(try ClipboardActions.payload(C(string: "Example", url: URL(string: "https://example.com")!)) == .text("Example"), "the string wins over the URL")
        let image = YoyoUpload(data: Data([1, 2, 3]), filename: "Pasted image.png", mime: "image/png")
        #expect(try ClipboardActions.payload(C(string: "caption", image: image)) == .files([image]), "an image beats text")
        let file = YoyoUpload(data: Data([9]), filename: "a.pdf", mime: "application/pdf")
        #expect(try ClipboardActions.payload(C(image: image, files: [file])) == .files([file]), "files beat the image")
        #expect(throws: ClipboardActions.PayloadError.nothing) { try ClipboardActions.payload(C()) }
        #expect(throws: ClipboardActions.PayloadError.nothing) { try ClipboardActions.payload(C(string: "  \n")) }
        #expect(throws: ClipboardActions.PayloadError.textTooLong) {
            try ClipboardActions.payload(C(string: String(repeating: "x", count: ClipboardLimits.textBytes + 1)))
        }
        #expect(throws: ClipboardActions.PayloadError.tooManyFiles) {
            try ClipboardActions.payload(C(files: Array(repeating: file, count: ClipboardLimits.filesPerItem + 1)))
        }
        let big = YoyoUpload(data: Data(count: 1001), filename: "big.bin", mime: "application/octet-stream")
        #expect(throws: ClipboardActions.PayloadError.fileTooLarge("big.bin", limit: 1000)) { try ClipboardActions.payload(C(files: [big]), limit: 1000) }
        #expect(try ClipboardActions.payload(C(files: [big]), limit: 2000) == .files([big]))
    }

    @Test func copyFromMacPerKind() {
        typealias M = ClipboardActions.CopyMove
        #expect(ClipboardActions.copyFromMac(status(.text, text: "hi")) == M.text("hi"))
        #expect(ClipboardActions.copyFromMac(status(.text)) == M.nothing, "a summary without the text: nothing to put on the phone yet")
        #expect(ClipboardActions.copyFromMac(status(.image)) == M.image(changeCount: 1))
        #expect(ClipboardActions.copyFromMac(status(.files, files: [ClipboardFile(name: "a")])) == M.openFiles)
        #expect(ClipboardActions.copyFromMac(status(.concealed)) == M.concealed)
        #expect(ClipboardActions.copyFromMac(status(.empty)) == M.empty)
        #expect(ClipboardActions.copyFromMac(status(.other)) == M.nothing)
        #expect(ClipboardActions.copyFromMac(status(.text, text: "hi", available: false, reason: "down")) == M.unavailable(reason: "down"))
    }

    // MARK: The shared state

    @MainActor
    @Test func aClipboardEventReplacesTheSummaryAndDropsTheText() async throws {
        let backend = ClipboardBackend()
        let state = YoyoClipboardState.of(backend)
        #expect(YoyoClipboardState.of(backend) === state, "one per computer")
        // nothing known yet: the event is the status
        state.apply(available: true, summary: ClipboardSummary(changeCount: 1, kind: .text))
        #expect(state.status?.item?.changeCount == 1)

        let first = ClipboardStatus(available: true, item: ClipboardItem(summary: ClipboardSummary(changeCount: 1, kind: .text, preview: "hi", at: 5), text: "hi"))
        state.set(first)
        // the same changeCount again: untouched (the text stays)
        state.apply(available: true, summary: ClipboardSummary(changeCount: 1, kind: .text, preview: "hi", at: 5))
        #expect(state.status == first)
        // a new one: the summary, with no text (the page loads again)
        let next = ClipboardSummary(changeCount: 2, kind: .text, preview: "bye", size: 3, at: 9)
        state.apply(available: true, summary: next)
        #expect(state.status?.item?.summary == next && state.status?.item?.text == nil && state.status?.available == true)
        // the computer can't be read any more: available flips, the item goes
        state.apply(available: false, summary: nil)
        #expect(state.status?.available == false && state.status?.item == nil)
        state.apply(available: true, summary: nil)
        #expect(state.status == ClipboardStatus(available: true, item: nil), "empty now")
        // a load asks the backend
        let loaded = try await state.load(force: true)
        #expect(loaded == backend.answer && state.status == backend.answer)
    }

    @MainActor
    @Test func aComputerWithoutAClipboardIsUnsupported() async {
        let state = YoyoClipboardState.of(NoClipboardBackend())
        _ = try? await state.load(force: true)
        #expect(state.isUnsupported && state.status == nil)
        // an event changes nothing for it
        state.apply(available: true, summary: ClipboardSummary(changeCount: 1, kind: .text))
        #expect(state.status == nil)
    }

    @MainActor
    @Test func observersHearEveryChangeWhileTheyLive() {
        let state = YoyoClipboardState.of(ClipboardBackend())
        final class Owner {}
        var owner: Owner? = Owner()
        var heard = 0
        state.observe(owner!) { _ in heard += 1 }
        state.set(ClipboardStatus(available: true))
        #expect(heard == 1)
        owner = nil
        state.set(ClipboardStatus(available: false))
        #expect(heard == 1, "a gone owner hears nothing")
    }

    // MARK: The Screen page's entries

    private func text(_ n: Int, _ preview: String, source: ClipboardSource = .mac) -> ClipboardSummary {
        ClipboardSummary(changeCount: n, kind: .text, preview: preview, size: preview.utf8.count, at: 1, source: source)
    }

    @Test func thePhonesKindComesFromWhatItHasNotWhatItSays() {
        #expect(ClipboardActions.PhoneKind(hasStrings: true, hasURLs: false, hasImages: false) == .text)
        // a copied link has a string too; a copied picture may have both
        #expect(ClipboardActions.PhoneKind(hasStrings: true, hasURLs: true, hasImages: false) == .link)
        #expect(ClipboardActions.PhoneKind(hasStrings: true, hasURLs: true, hasImages: true) == .image)
        #expect(ClipboardActions.PhoneKind(hasStrings: false, hasURLs: false, hasImages: false) == nil)
        #expect(ClipboardActions.PhoneKind.text.title == "Text" && ClipboardActions.PhoneKind.image.word == "image")
        #expect(ClipboardActions.phoneHint(.text) == "iPhone clipboard: text — Paste on Mac")
    }

    @Test func theMenuSaysWhatEachSideHoldsAndWhyNot() {
        let ready = ClipboardStatus(available: true, item: ClipboardItem(summary: text(5, "npm run build && npm test")))
        let down = ClipboardStatus(available: false, reason: "No GUI session")
        // Paste on Mac: the phone's kind, or nothing copied; the Mac's reason while it can't take it
        #expect(ClipboardActions.pasteItem(phone: .link, mac: ready) == .init(enabled: true, subtitle: "Web link"))
        #expect(ClipboardActions.pasteItem(phone: nil, mac: ready) == .init(enabled: false, subtitle: "Nothing copied on iPhone"))
        #expect(ClipboardActions.pasteItem(phone: .text, mac: down) == .init(enabled: false, subtitle: "No GUI session"))
        #expect(ClipboardActions.pasteItem(phone: .text, mac: nil).enabled)
        #expect(ClipboardActions.sendItem(mac: ready).enabled && !ClipboardActions.sendItem(mac: down).enabled)
        // Copy from Mac: a short summary, or why there's nothing
        #expect(ClipboardActions.copyItem(mac: ready) == .init(enabled: true, subtitle: "Text · “npm run buil…&& npm test”"))
        let image = ClipboardStatus(available: true, item: ClipboardItem(summary: ClipboardSummary(changeCount: 6, kind: .image, width: 1280, height: 720)))
        #expect(ClipboardActions.copyItem(mac: image).subtitle == "Image · 1280×720")
        let files = ClipboardStatus(available: true, item: ClipboardItem(summary: ClipboardSummary(
            changeCount: 7, kind: .files, files: [ClipboardFile(name: "a.pdf"), ClipboardFile(name: "b.png")], moreFiles: 1)))
        #expect(ClipboardActions.copyItem(mac: files) == .init(enabled: true, subtitle: "3 files"))
        #expect(ClipboardActions.copyItem(mac: ClipboardStatus(available: true)) == .init(enabled: false, subtitle: "The Mac’s clipboard is empty"))
        let hidden = ClipboardStatus(available: true, item: ClipboardItem(summary: ClipboardSummary(changeCount: 8, kind: .concealed)))
        #expect(ClipboardActions.copyItem(mac: hidden) == .init(enabled: false, subtitle: "Hidden by a password manager"))
        #expect(ClipboardActions.copyItem(mac: down) == .init(enabled: false, subtitle: "No GUI session"))
        // not known yet: it asks
        #expect(ClipboardActions.copyItem(mac: nil).enabled)
    }

    @Test func theMacsHintQuotesAShortPreview() {
        #expect(ClipboardActions.macHint(text(1, "hello")) == "Copied on Mac: “hello” — Copy to iPhone")
        // middle-truncated to 24 characters, one line
        let hint = ClipboardActions.macHint(text(2, "The quick brown fox⏎ jumps over the lazy dog"))
        #expect(hint == "Copied on Mac: “The quick br…he lazy dog” — Copy to iPhone")
        #expect(ClipboardActions.middleTruncated("abcdefghij", to: 5) == "ab…ij" && ClipboardActions.middleTruncated("abc", to: 5) == "abc")
        #expect(ClipboardActions.macHint(ClipboardSummary(changeCount: 3, kind: .image)) == "Copied on Mac: Image — Copy to iPhone")
        #expect(ClipboardActions.macHint(ClipboardSummary(changeCount: 4, kind: .files, files: [ClipboardFile(name: "a")], moreFiles: 2))
            == "Copied on Mac: 3 files — Copy to iPhone")
        // nothing to copy: no hint
        #expect(ClipboardActions.macHint(ClipboardSummary(changeCount: 5, kind: .concealed)) == nil)
        #expect(ClipboardActions.macHint(ClipboardSummary(changeCount: 6, kind: .empty)) == nil)
    }

    @Test func theDotAndTheHintsShowWhatIsNewOnce() {
        var m = ScreenClipboardMarks()
        // a fresh run: what the phone holds is news, the Mac's first item is where news starts
        #expect(m.phoneIsNew(count: 10, kind: .text) && !m.phoneIsNew(count: 10, kind: nil))
        #expect(ScreenClipboardHint.onAppear(marks: m, phoneCount: 10, phoneKind: .text) == .phone(.text))
        m.knowMac(text(50, "a"))
        #expect(!m.macIsNew(text(50, "a")))
        #expect(m.dot(phoneCount: 10, phoneKind: .text, mac: text(50, "a")))
        // pasted (or seen in the menu): not news any more
        m.phone = 10
        #expect(ScreenClipboardHint.onAppear(marks: m, phoneCount: 10, phoneKind: .text) == nil)
        #expect(!m.dot(phoneCount: 10, phoneKind: .text, mac: text(50, "a")))
        // the Mac copies something: the dot, and a hint while the page is open
        #expect(m.dot(phoneCount: 10, phoneKind: .text, mac: text(51, "b")))
        #expect(ScreenClipboardHint.onMacChange(text(51, "b"), previous: 50) == .mac(changeCount: 51))
        // not what this phone sent, not the page's first answer, not the same item again, not something hidden
        #expect(ScreenClipboardHint.onMacChange(text(52, "c", source: .phone), previous: 51) == nil)
        #expect(!m.macIsNew(text(52, "c", source: .phone)))
        #expect(ScreenClipboardHint.onMacChange(text(51, "b"), previous: nil) == nil)
        #expect(ScreenClipboardHint.onMacChange(text(51, "b"), previous: 51) == nil)
        #expect(ScreenClipboardHint.onMacChange(ClipboardSummary(changeCount: 53, kind: .concealed), previous: 52) == nil)
        // an agent's copy counts
        #expect(ScreenClipboardHint.onMacChange(text(54, "d", source: .agent), previous: 53) == .mac(changeCount: 54))
        // the menu opened: both seen, the dot goes; the phone copies something else: news again
        m.sawMenu(phoneCount: 11, mac: text(54, "d"))
        #expect(!m.dot(phoneCount: 11, phoneKind: .text, mac: text(54, "d")))
        #expect(m.dot(phoneCount: 12, phoneKind: .image, mac: text(54, "d")))
        // the first Mac item seen sets the start only once
        m.knowMac(text(99, "z"))
        #expect(m.mac == 54)
    }

    @Test func theGestureCardHasTheClipboardsTwoVerbs() {
        let rows = ScreenGestureRow.clipboardRows()
        #expect(rows.map(\.gesture) == ["Paste on Mac", "Copy from Mac"])
        #expect(rows.map(\.symbol) == [ScreenClipboardKey.pasteOnMac.symbol, ScreenClipboardKey.copyFromMac.symbol])
        #expect(ScreenClipboardKey.allCases.map { $0.label(.mac) } == ["Paste on Mac", "Copy from Mac"])
        // a user's desktop: the same verbs, naming the computer
        #expect(ScreenGestureRow.clipboardRows(.linux).map(\.gesture) == ["Paste on Computer", "Copy from Computer"])
        #expect(ScreenClipboardKey.allCases.map { $0.label(.linux) } == ["Paste on Computer", "Copy from Computer"])
        // every symbol exists (an unknown name draws nothing)
        for name in rows.map(\.symbol) + ["doc.on.clipboard", "photo.on.rectangle", "folder"] {
            #expect(UIImage(systemName: name) != nil, "\(name)")
        }
    }
}

/// A computer with a clipboard (its answer fixed).
final class ClipboardBackend: YoyoBackend, @unchecked Sendable {
    let cacheScope = "clipboard-tests:\(UUID().uuidString)"
    let answer = ClipboardStatus(available: true, item: ClipboardItem(summary: ClipboardSummary(changeCount: 9, kind: .text, preview: "x"), text: "x"))
    func status() async throws -> ScreenStatus { ScreenStatus() }
    func streamRequest(display: UInt32?, maxWidth: Int?, quality: Int?, fps: Int?, options: ScreenStreamOptions, route: YoyoRoute) throws -> URLRequest {
        throw YoyoError.badServerURL
    }
    func ackRequest(_ ack: ScreenStreamAck, route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
    func audioRequest(route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
    func input(_ input: ScreenInput, route: YoyoRoute) async throws {}
    func setControl(_ controller: ScreenController, route: YoyoRoute) async throws -> ScreenStatus { ScreenStatus() }
    func clipboard() async throws -> ClipboardStatus { answer }
}

/// A computer without one (the protocol's defaults: 404).
final class NoClipboardBackend: YoyoBackend, @unchecked Sendable {
    let cacheScope = "no-clipboard-tests:\(UUID().uuidString)"
    func status() async throws -> ScreenStatus { ScreenStatus() }
    func streamRequest(display: UInt32?, maxWidth: Int?, quality: Int?, fps: Int?, options: ScreenStreamOptions, route: YoyoRoute) throws -> URLRequest {
        throw YoyoError.badServerURL
    }
    func ackRequest(_ ack: ScreenStreamAck, route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
    func audioRequest(route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
    func input(_ input: ScreenInput, route: YoyoRoute) async throws {}
    func setControl(_ controller: ScreenController, route: YoyoRoute) async throws -> ScreenStatus { ScreenStatus() }
}
