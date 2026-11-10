import Foundation
import YoyoCore

// MARK: - Actions (pure logic; the Clipboard page, a preview row and the Screen page's keys ask it)

/// What the clipboard UI may do with a status and what a move builds, without UIKit (tested on its own).
public enum ClipboardActions {
    /// The buttons under the "On your Mac" card, and whether the phone may send anything.
    package struct Enabled: Equatable {
        package var copy = false
        package var share = false
        package var save = false
        package var send = false

        package init(copy: Bool = false, share: Bool = false, save: Bool = false, send: Bool = false) {
            self.copy = copy; self.share = share; self.save = save; self.send = send
        }
    }

    package static func enabled(_ status: ClipboardStatus?) -> Enabled {
        guard let status, status.available else { return Enabled() }
        var e = Enabled(send: true)
        switch status.kind {
        case .text: e.copy = true; e.share = true
        case .image: e.copy = true; e.share = true; e.save = true
        case .files:
            // nothing sensible goes on the phone's clipboard; sharing / saving downloads the regular files first
            let regular = status.item?.summary.files.contains { !$0.dir } ?? false
            e.share = regular; e.save = regular
        case .concealed, .empty, .other: break
        }
        return e
    }

    /// The My Computer row's second line: the live summary (`dimmed`: the Mac can't do clipboard, the reason shows).
    public static func summaryLine(_ status: ClipboardStatus) -> (text: String, dimmed: Bool) {
        guard status.available else { return (status.reason ?? L("Clipboard unavailable"), true) }
        guard let s = status.item?.summary, s.kind != .empty else { return (L("Empty"), false) }
        return (previewLine(s), false)
    }

    /// One line for a summary: the text's preview, "Image · 1280×720", "3 files · a.pdf, b.jpg", "Hidden (password manager)".
    public static func previewLine(_ s: ClipboardSummary) -> String {
        switch s.kind {
        case .text: return s.preview.isEmpty ? L("Text") : s.preview
        case .image:
            if let w = s.width, let h = s.height, w > 0, h > 0 { return L("Image · \(String(w))×\(String(h))") }
            return L("Image")
        case .files:
            let n = s.files.count + s.moreFiles
            let names = s.files.map(\.name).joined(separator: ", ")
            return names.isEmpty ? L("\(n) files") : L("\(n) files · \(names)")
        case .concealed: return L("Hidden (password manager)")
        case .empty: return L("Empty")
        case .other: return L("Something that can’t be shown here")
        }
    }

    /// The card's footer: who copied it and how long ago (`now` for tests).
    package static func footer(_ s: ClipboardSummary, host: YoyoComputer = .mac, now: Date = Date()) -> String {
        let when = s.date.map { relative($0, now: now) } ?? ""
        switch s.source {
        case .phone: return when.isEmpty ? L("Sent from this iPhone") : L("Sent from this iPhone · \(when)")
        case .agent:
            if let name = YoyoHost.current.agentName {
                return when.isEmpty ? L("Copied by \(name)") : L("Copied by \(name) · \(when)")
            }
            return when.isEmpty ? L("Copied by an agent") : L("Copied by an agent · \(when)")
        case .mac: return host.copiedOn(when)
        }
    }

    /// "just now" under a minute, else "2 min. ago" in the app's language.
    package static func relative(_ date: Date, now: Date = Date()) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return L("just now") }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated).locale(YoyoL10n.locale))
    }

    /// Text that reads as code or a path: shown monospaced.
    package static func looksLikeCode(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") { return !t.contains(" ") || t.contains("\n") }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
        let codey = lines.filter { l in
            let s = l.trimmingCharacters(in: .whitespaces)
            return s.hasSuffix(";") || s.hasSuffix("{") || s.hasSuffix("}") || s.hasPrefix("#") || s.hasPrefix("//")
                || s.contains("=>") || s.contains("()") || s.hasPrefix("$ ") || s.hasPrefix("import ") || s.hasPrefix("let ") || s.hasPrefix("const ")
        }
        return lines.count > 1 ? codey.count * 2 >= lines.count : !codey.isEmpty
    }

    // MARK: Paste on Mac

    /// What the phone's pasteboard holds, read once (`UIPasteboard.general`): the richest of it goes to the Mac.
    package struct PhoneContent: Equatable, Sendable {
        package var string: String?
        package var url: URL?
        /// Image bytes (PNG / JPEG as the pasteboard has them) with a file name.
        package var image: YoyoUpload?
        package var files: [YoyoUpload] = []

        package init(string: String? = nil, url: URL? = nil, image: YoyoUpload? = nil, files: [YoyoUpload] = []) {
            self.string = string; self.url = url; self.image = image; self.files = files
        }
    }

    /// What `PUT /clipboard` gets.
    package enum Payload: Equatable, Sendable {
        case text(String)
        case files([YoyoUpload])
    }

    package enum PayloadError: Error, Equatable, LocalizedError {
        /// Nothing on the phone's clipboard the Mac can take.
        case nothing
        case textTooLong
        case tooManyFiles
        case fileTooLarge(String, limit: Int)

        package var errorDescription: String? {
            switch self {
            case .nothing: L("Nothing to paste: copy something on this iPhone first.")
            case .textTooLong: L("Too long to copy (max 1 MB).")
            case .tooManyFiles: L("At most \(ClipboardLimits.filesPerItem) files at a time.")
            case .fileTooLarge(let name, let limit): L("\(name) is too large (max \(ClipboardActions.sizeText(limit))).")
            }
        }
    }

    /// An image beats text (a copied picture rarely has a string), files beat both; a URL stands in for a missing string.
    package static func payload(_ c: PhoneContent, limit: Int = 95_000_000) throws(PayloadError) -> Payload {
        if !c.files.isEmpty { return .files(try checked(c.files, limit: limit)) }
        if let image = c.image { return .files(try checked([image], limit: limit)) }
        let text = c.string?.isEmpty == false ? c.string! : c.url?.absoluteString
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .nothing }
        return .text(try checkedText(text))
    }

    package static func checkedText(_ text: String) throws(PayloadError) -> String {
        guard text.utf8.count <= ClipboardLimits.textBytes else { throw .textTooLong }
        return text
    }

    package static func checked(_ files: [YoyoUpload], limit: Int) throws(PayloadError) -> [YoyoUpload] {
        guard files.count <= ClipboardLimits.filesPerItem else { throw .tooManyFiles }
        if let big = files.first(where: { $0.size > limit }) { throw .fileTooLarge(big.filename, limit: limit) }
        return files
    }

    // MARK: Copy from Mac

    /// What the Screen page's "Copy from Mac" does with a status.
    package enum CopyMove: Equatable {
        /// Onto the phone's clipboard as a string.
        case text(String)
        /// Fetch `GET /clipboard/image?changeCount=` and put the picture on the phone's clipboard.
        case image(changeCount: Int)
        /// Nothing sensible for the phone's clipboard: open the Clipboard page (share / save the files there).
        case openFiles
        case concealed
        case empty
        case unavailable(reason: String?)
        /// Not something the phone can take ("other", or text the server didn't include).
        case nothing
    }

    package static func copyFromMac(_ status: ClipboardStatus) -> CopyMove {
        guard status.available else { return .unavailable(reason: status.reason) }
        guard let item = status.item, item.kind != .empty else { return .empty }
        switch item.kind {
        case .text: return item.text.map { .text($0) } ?? .nothing
        case .image: return .image(changeCount: item.changeCount)
        case .files: return .openFiles
        case .concealed: return .concealed
        case .empty: return .empty
        case .other: return .nothing
        }
    }
}

// MARK: - The Screen page's entries (the bar's menu, the keys, the hints on the picture)

extension ClipboardActions {
    /// What the phone's pasteboard holds, as far as can be told without reading it (`hasImages` / `hasURLs` /
    /// `hasStrings`: no paste notice): the richest of them.
    package enum PhoneKind: Equatable, Sendable {
        case text, link, image

        package init?(hasStrings: Bool, hasURLs: Bool, hasImages: Bool) {
            if hasImages { self = .image } else if hasURLs { self = .link } else if hasStrings { self = .text } else { return nil }
        }

        /// "Text" / "Link" / "Image" (a menu item's subtitle).
        package var title: String {
            switch self {
            case .text: L("Text")
            case .link: L("Web link")
            case .image: L("Image")
            }
        }

        /// "text" / "link" / "image" (inside a sentence: the hint on the picture).
        package var word: String {
            switch self {
            case .text: L("text")
            case .link: L("link")
            case .image: L("image")
            }
        }
    }

    /// One item of the Screen page's clipboard menu: whether it can be chosen, and the line under its title.
    package struct MenuItem: Equatable, Sendable {
        package var enabled: Bool
        package var subtitle: String?

        package init(enabled: Bool, subtitle: String? = nil) {
            self.enabled = enabled
            self.subtitle = subtitle
        }
    }

    /// "Paste on Mac": what the phone holds ("Text"), or "Nothing copied on iPhone"; the Mac's reason while it can't
    /// take anything.
    package static func pasteItem(phone: PhoneKind?, mac: ClipboardStatus?) -> MenuItem {
        if let mac, !mac.available { return MenuItem(enabled: false, subtitle: mac.reason ?? L("Clipboard unavailable")) }
        guard let phone else { return MenuItem(enabled: false, subtitle: L("Nothing copied on iPhone")) }
        return MenuItem(enabled: true, subtitle: phone.title)
    }

    /// "Photos…" / "Files…": while the Mac can take them.
    package static func sendItem(mac: ClipboardStatus?) -> MenuItem {
        if let mac, !mac.available { return MenuItem(enabled: false, subtitle: nil) }
        return MenuItem(enabled: true, subtitle: nil)
    }

    /// "Copy from Mac": what the Mac holds ("Text · “npm run…”", "Image · 1280×720", "3 files"), or why there is nothing
    /// to copy (unavailable, empty, hidden by a password manager). Unknown yet (nil): enabled, it asks.
    package static func copyItem(mac: ClipboardStatus?, host: YoyoComputer = .mac) -> MenuItem {
        guard let mac else { return MenuItem(enabled: true, subtitle: nil) }
        guard mac.available else { return MenuItem(enabled: false, subtitle: mac.reason ?? L("Clipboard unavailable")) }
        guard let s = mac.item?.summary, s.kind != .empty else { return MenuItem(enabled: false, subtitle: host.clipboardEmpty) }
        switch s.kind {
        case .concealed: return MenuItem(enabled: false, subtitle: L("Hidden by a password manager"))
        case .other: return MenuItem(enabled: false, subtitle: previewLine(s))
        default: return MenuItem(enabled: true, subtitle: macLine(s))
        }
    }

    /// The Mac's item in a few words: "Text · “npm run…”", "Image · 1280×720", "3 files".
    package static func macLine(_ s: ClipboardSummary) -> String {
        switch s.kind {
        case .text: return s.preview.isEmpty ? L("Text") : L("Text · “\(middleTruncated(oneLine(s.preview), to: 24))”")
        case .files: return L("\(s.files.count + s.moreFiles) files")
        default: return previewLine(s)
        }
    }

    /// The hint over the picture when the Mac has just copied something: "Copied on Mac: “…” — Copy to iPhone"
    /// (text: ≤ 24 characters, middle-truncated; an image: "Image"; files: "3 files"). nil: nothing to copy.
    package static func macHint(_ s: ClipboardSummary, host: YoyoComputer = .mac) -> String? {
        let what: String
        switch s.kind {
        case .text: what = s.preview.isEmpty ? L("Text") : "“\(middleTruncated(oneLine(s.preview), to: 24))”"
        case .image: what = L("Image")
        case .files: what = L("\(s.files.count + s.moreFiles) files")
        case .concealed, .empty, .other: return nil
        }
        return host.copiedHint(what)
    }

    /// The hint over the picture when the phone holds something: "iPhone clipboard: text — Paste on Mac" (the kind only,
    /// never the content).
    package static func phoneHint(_ kind: PhoneKind, host: YoyoComputer = .mac) -> String {
        host.phoneHint(kind.word)
    }

    /// The preview's "⏎ " line breaks as spaces (one line).
    package static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "⏎ ", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// `s` at most `max` characters, the middle replaced by "…".
    package static func middleTruncated(_ s: String, to max: Int) -> String {
        guard s.count > max, max > 1 else { return s }
        let keep = max - 1
        let head = (keep + 1) / 2, tail = keep / 2
        return String(s.prefix(head)) + "…" + String(s.suffix(tail))
    }
}

extension ClipboardActions {
    /// "95 MB" (a size limit, in the host's locale).
    package static func sizeText(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(YoyoL10n.locale))
    }
}
