#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers

// The Mac's clipboard for the phone and the agent (docs/PROTOCOL.md 「剪贴板」): `GET /clipboard` reads NSPasteboard.general
// once, `GET /clipboard/image` / `GET /clipboard/file` give the content, `POST /clipboard` sets it, and `/events` carries a
// `{"type":"clipboard",…}` summary line whenever `changeCount` moves (ClipboardMonitor, a 0.5 s poll). Only this native
// code touches the pasteboard; a client relays it (saving a phone's files first for `POST /clipboard { files }`).

/// Files the phone (or the agent) put on this Mac's clipboard through `POST /clipboard`: a host may post a
/// notification for them and reveal them in Finder (`ScreenHost.onClipboardReceived`); yoyo-control only logs. A text put does not notify.
public struct ClipboardReceipt: Sendable {
    public let names: [String]
    public let paths: [String]
    /// "phone" / "agent".
    public let source: String
}

/// `ClipboardKind` of the protocol.
enum ClipboardKind: String {
    case text, image, files, concealed, other, empty
}

/// One entry of a `files` item (`ClipboardFile`). `size` nil = a directory, or unknown.
struct ClipboardFileInfo: Equatable {
    var name: String
    var size: Int?
    var dir: Bool

    var json: [String: Any] { ["name": name, "size": size ?? NSNull(), "dir": dir] }
}

/// What the pasteboard holds, as `GET /clipboard` answers it (`ClipboardItem`; `summaryJSON` is the `ClipboardSummary`
/// the `/events` line carries: never the text).
struct ClipboardItem {
    var changeCount: Int
    var kind: ClipboardKind
    var preview = ""
    var size: Int?
    var width: Int?
    var height: Int?
    var files: [ClipboardFileInfo]?
    var moreFiles: Int?
    /// When this changeCount was first seen (unix ms).
    var at: Double
    /// "phone" / "agent" when the helper's own `POST /clipboard` produced this changeCount; nil = the Mac.
    var source: String?
    var text: String?
    var truncated = false
    /// Every file URL of a `files` item (not only the listed ones): `GET /clipboard/file?index=` serves from here.
    var fileURLs: [URL] = []

    var summaryJSON: [String: Any] {
        var j: [String: Any] = ["changeCount": changeCount, "kind": kind.rawValue, "preview": preview, "size": size ?? NSNull(), "at": at]
        if let width { j["width"] = width }
        if let height { j["height"] = height }
        if let files { j["files"] = files.map(\.json) }
        if let moreFiles { j["moreFiles"] = moreFiles }
        if let source { j["source"] = source }
        return j
    }

    var json: [String: Any] {
        var j = summaryJSON
        if let text { j["text"] = text }
        if truncated { j["truncated"] = true }
        return j
    }
}

enum Clipboard {
    static let previewMax = 160
    static let filesMax = 20
    /// 1 MiB of text either way (CLIPBOARD_TEXT_MAX).
    static let textMax = 1_048_576
    /// Password managers mark their items so (nspasteboard.org): reported as `concealed`, never read.
    static let concealedTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]

    /// Reads `pb` once. Kind detection in order: a concealed / transient marker → `concealed`; file URLs → `files`;
    /// an image → `image`; a string → `text` (`includeText: false` leaves the string out: the poll / summary path);
    /// no items → `empty`; else `other`. `monitor`: the item's `at` and `source`, and the PNG cache (nil in tests: now,
    /// no source, the PNG made here).
    static func read(_ pb: NSPasteboard, includeText: Bool, monitor: ClipboardMonitor? = nil) -> ClipboardItem {
        let changeCount = pb.changeCount
        var item = ClipboardItem(changeCount: changeCount, kind: .other,
                                 at: (monitor?.firstSeen(changeCount) ?? Date()).timeIntervalSince1970 * 1000,
                                 source: monitor?.source(for: changeCount))
        item.at = item.at.rounded()
        let items = pb.pasteboardItems ?? []
        let types = Set(items.flatMap { $0.types.map(\.rawValue) })
        if !types.isDisjoint(with: concealedTypes) {
            item.kind = .concealed
            return item
        }
        let urls = items.compactMap { $0.string(forType: .fileURL).flatMap { URL(string: $0) } }.filter(\.isFileURL)
        if !urls.isEmpty {
            item.kind = .files
            item.fileURLs = urls
            let infos = urls.prefix(filesMax).map(fileInfo)
            item.files = Array(infos)
            if urls.count > filesMax { item.moreFiles = urls.count - filesMax }
            let sizes = urls.map(fileInfo).compactMap(\.size)
            item.size = sizes.isEmpty ? nil : sizes.reduce(0, +)
            item.preview = filesPreview(infos.map(\.name))
            return item
        }
        // A bitmap wins; anything else NSImage could read (a PDF, say) only when there is no text: a copy from Pages or
        // a browser carries a PDF / rich rendering of the *text*, which the user thinks of as text.
        let hasString = pb.string(forType: .string) != nil
        if types.contains(NSPasteboard.PasteboardType.png.rawValue) || types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
            || (!hasString && NSImage.canInit(with: pb)) {
            if let png = monitor?.png(for: changeCount, make: { pngData(pb) }) ?? pngData(pb) {
                item.kind = .image
                item.size = png.data.count
                item.width = png.width
                item.height = png.height
                return item
            }
            // an image type whose data AppKit cannot read: not an image for our purposes
        }
        if let string = pb.string(forType: .string) {
            item.kind = .text
            item.size = string.utf8.count
            item.preview = preview(string)
            if includeText {
                let (text, truncated) = clipText(string, maxBytes: textMax)
                item.text = text
                item.truncated = truncated
            }
            return item
        }
        item.kind = items.isEmpty ? .empty : .other
        return item
    }

    /// The first `previewMax` characters of `text`, newline runs shown as "⏎ ", "…" when cut (≤ previewMax in all).
    static func preview(_ text: String) -> String {
        // only the head is needed; a long text's rest is never looked at
        let head = String(text.prefix(previewMax * 8))
        let lines = head.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let flat = lines.filter { !$0.isEmpty }.joined(separator: "⏎ ")
        return clipPreview(flat, longer: head.count < text.count)
    }

    /// The file names joined ", " (≤ previewMax).
    static func filesPreview(_ names: [String]) -> String {
        clipPreview(names.joined(separator: ", "), longer: false)
    }

    private static func clipPreview(_ s: String, longer: Bool) -> String {
        if s.count > previewMax { return String(s.prefix(previewMax - 1)) + "…" }
        return s
    }

    /// `text` cut to `maxBytes` of UTF-8 at a character boundary; `truncated` when it was longer.
    static func clipText(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        var cut = text.utf8.index(text.utf8.startIndex, offsetBy: maxBytes)
        while cut > text.utf8.startIndex, cut.samePosition(in: text) == nil { cut = text.utf8.index(before: cut) }
        return (String(text[..<cut]), true)
    }

    /// The PNG of the pasteboard's image (its own PNG when it has one, else re-encoded from what NSImage reads) and
    /// its pixel size. nil when AppKit cannot read it.
    static func pngData(_ pb: NSPasteboard) -> (data: Data, width: Int, height: Int)? {
        if let png = pb.data(forType: .png), let rep = NSBitmapImageRep(data: png) {
            return (png, rep.pixelsWide, rep.pixelsHigh)
        }
        guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, rep.pixelsWide, rep.pixelsHigh)
    }

    static func fileInfo(_ url: URL) -> ClipboardFileInfo {
        let name = url.lastPathComponent
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return ClipboardFileInfo(name: name, size: nil, dir: false)
        }
        let dir = (attrs[.type] as? FileAttributeType) == .typeDirectory
        let size = dir ? nil : (attrs[.size] as? NSNumber)?.intValue
        return ClipboardFileInfo(name: name, size: size, dir: dir)
    }

    /// `Content-Type` for a file by its extension (best effort).
    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// The pasteboard type that carries an image file's data on the same item as its URL (so ⌘V into an image-taking
    /// app pastes the picture), by extension; nil = not an image we know.
    static func imageType(forExtension ext: String) -> NSPasteboard.PasteboardType? {
        switch ext.lowercased() {
        case "png": .png
        case "jpg", "jpeg": NSPasteboard.PasteboardType("public.jpeg")
        case "gif": NSPasteboard.PasteboardType("com.compuserve.gif")
        case "webp": NSPasteboard.PasteboardType("org.webmproject.webp")
        case "heic": NSPasteboard.PasteboardType("public.heic")
        default: nil
        }
    }

    /// Replaces the pasteboard's contents with `text` → the resulting changeCount.
    @discardableResult
    static func write(_ pb: NSPasteboard, text: String) -> Int {
        pb.clearContents()
        pb.setString(text, forType: .string)
        return pb.changeCount
    }

    /// Replaces the pasteboard's contents with the files: one item per URL (`public.file-url`); a single image file also
    /// carries its data under its image type → the resulting changeCount.
    @discardableResult
    static func write(_ pb: NSPasteboard, files: [URL]) -> Int {
        pb.clearContents()
        let items = files.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if files.count == 1, let type = imageType(forExtension: url.pathExtension), let data = try? Data(contentsOf: url) {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(items)
        return pb.changeCount
    }

    /// One `/events` line: `{"type":"clipboard", …ClipboardSummary}` (no text).
    static func eventLine(_ item: ClipboardItem) -> Data {
        var body = item.summaryJSON
        body["type"] = "clipboard"
        var data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{\"type\":\"clipboard\"}".utf8)
        data.append(10)
        return data
    }
}

/// Watches a pasteboard's `changeCount` (every `pollInterval`, on its own queue), remembers when each count was first
/// seen and which counts this helper wrote itself (`source`), caches the PNG of an image item (made once per count, not
/// on every poll), keeps the latest summary for `/events`, and tells `onChange` (the state tracker's side-change wake) on
/// every change. One per service (`current`).
final class ClipboardMonitor: @unchecked Sendable {
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var _current: ClipboardMonitor?
    static var current: ClipboardMonitor? {
        currentLock.lock(); defer { currentLock.unlock() }; return _current
    }

    static let pollInterval: TimeInterval = 0.5

    let pasteboard: NSPasteboard
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    /// Serializes polls (the timer's and `POST /clipboard`'s) and the pasteboard reads they do.
    private let pollLock = NSLock()
    private let queue = DispatchQueue(label: "yoyo-control-clipboard", qos: .utility)
    // Guarded by `lock`:
    private var timer: DispatchSourceTimer?
    private var seen: (changeCount: Int, at: Date)?
    private var own: [(changeCount: Int, source: String)] = []
    private var pngCache: (changeCount: Int, png: (data: Data, width: Int, height: Int))?
    private var latest: ClipboardItem?
    private var lastPolled = -1

    init(pasteboard: NSPasteboard = .general, onChange: @escaping @Sendable () -> Void) {
        self.pasteboard = pasteboard
        self.onChange = onChange
    }

    /// Poll (the first read now, on the caller's thread) and register as `current`. Idempotent.
    func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        lock.unlock()
        Self.currentLock.lock(); Self._current = self; Self.currentLock.unlock()
        poll()
        t.resume()
    }

    func stop() {
        lock.lock()
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
        Self.currentLock.lock(); if Self._current === self { Self._current = nil }; Self.currentLock.unlock()
    }

    /// Reads the pasteboard if its changeCount moved since the last poll: the new summary becomes `latestSummary` and
    /// `onChange` runs. Any thread.
    func poll() {
        pollLock.lock()
        defer { pollLock.unlock() }
        let changeCount = pasteboard.changeCount
        lock.lock()
        let changed = changeCount != lastPolled
        lastPolled = changeCount
        lock.unlock()
        guard changed else { return }
        let item = Clipboard.read(pasteboard, includeText: false, monitor: self)
        lock.lock()
        latest = item
        lock.unlock()
        onChange()
    }

    /// The summary of the last change seen (no text); nil before the first poll.
    var latestSummary: ClipboardItem? {
        lock.lock(); defer { lock.unlock() }; return latest
    }

    /// When `changeCount` was first seen (registered now when it is new).
    func firstSeen(_ changeCount: Int) -> Date {
        lock.lock(); defer { lock.unlock() }
        if let seen, seen.changeCount == changeCount { return seen.at }
        let now = Date()
        seen = (changeCount, now)
        pngCache = nil
        return now
    }

    /// `POST /clipboard` produced `changeCount` on behalf of `source` ("phone" / "agent").
    func noteOwnWrite(changeCount: Int, source: String) {
        lock.lock()
        own.append((changeCount, source))
        if own.count > 8 { own.removeFirst(own.count - 8) }
        seen = (changeCount, Date())
        pngCache = nil
        lock.unlock()
    }

    func source(for changeCount: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return own.last { $0.changeCount == changeCount }?.source
    }

    /// The PNG of the image item with `changeCount`, made by `make` once and kept until the count moves.
    func png(for changeCount: Int, make: () -> (data: Data, width: Int, height: Int)?) -> (data: Data, width: Int, height: Int)? {
        lock.lock()
        if let pngCache, pngCache.changeCount == changeCount {
            lock.unlock()
            return pngCache.png
        }
        lock.unlock()
        guard let made = make() else { return nil }
        lock.lock()
        pngCache = (changeCount, made)
        lock.unlock()
        return made
    }
}
#endif
