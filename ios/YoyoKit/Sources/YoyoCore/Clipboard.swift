import Foundation

// The computer's clipboard (docs/PROTOCOL.md「剪贴板」; a computer without one answers 404 and its entries hide): what it
// has copied, fetched on demand, and what the phone sends it. Its event (`YoyoEvent.clipboard`) carries a summary only
// (kind, preview, sizes, names); content leaves the computer when a client asks for it.

/// What the Mac's clipboard holds. Unknown values are `.other`.
public enum ClipboardKind: String, Sendable, Equatable, Hashable, Codable {
    case text, image, files
    /// A password manager marked the item hidden (`org.nspasteboard.ConcealedType` / `TransientType`): no preview, no content.
    case concealed
    case other, empty

    public init(lenient raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .other }
}

/// One file of a `files` item. `size` nil = unknown, or a folder.
public struct ClipboardFile: Sendable, Equatable, Hashable {
    public var name: String
    public var size: Int?
    public var dir: Bool

    public init(name: String, size: Int? = nil, dir: Bool = false) {
        self.name = name
        self.size = size
        self.dir = dir
    }
}

extension ClipboardFile: Codable {
    private enum K: String, CodingKey { case name, size, dir }

    /// Lenient: a missing name is "file"; size / dir fall back.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } ?? "file"
        size = ((try? c.decodeIfPresent(Double.self, forKey: .size)) ?? nil).map { Int(saturating: $0) }
        dir = c.flag(.dir)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encode(dir, forKey: .dir)
    }
}

/// Who put the item on the Mac's clipboard. Unknown / missing = `.mac`.
public enum ClipboardSource: String, Sendable, Equatable, Codable {
    case mac, phone, agent
}

/// The summary every client may see (the event, a preview row): never the text or the bytes.
public struct ClipboardSummary: Sendable, Equatable {
    /// `NSPasteboard.changeCount`: identifies the item (an ETag).
    public var changeCount: Int
    public var kind: ClipboardKind
    /// text: its first 160 characters; files: names joined by ", "; else "".
    public var preview: String
    /// text: UTF-8 bytes; image: PNG bytes; files: the regular files' sizes summed; else nil.
    public var size: Int?
    /// Image pixels.
    public var width: Int?
    public var height: Int?
    /// `files` only (at most 20 listed; `moreFiles` says how many weren't).
    public var files: [ClipboardFile]
    public var moreFiles: Int
    /// When the Mac first saw this `changeCount` (unix ms).
    public var at: Double
    public var source: ClipboardSource

    public init(changeCount: Int, kind: ClipboardKind, preview: String = "", size: Int? = nil, width: Int? = nil, height: Int? = nil,
         files: [ClipboardFile] = [], moreFiles: Int = 0, at: Double = 0, source: ClipboardSource = .mac) {
        self.changeCount = changeCount; self.kind = kind; self.preview = preview; self.size = size; self.width = width
        self.height = height; self.files = files; self.moreFiles = moreFiles; self.at = at; self.source = source
    }

    public var date: Date? { at > 0 ? Date(timeIntervalSince1970: at / 1000) : nil }
}

extension ClipboardSummary: Codable {
    public enum K: String, CodingKey { case changeCount, kind, preview, size, width, height, files, moreFiles, at, source, text, truncated }

    /// Lenient: every field may be missing, null or of an unknown value (an unknown kind still decodes, as `.other`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        self.init(container: c)
    }

    public init(container c: KeyedDecodingContainer<K>) {
        func num(_ k: K) -> Double? { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil }
        func int(_ k: K) -> Int? { num(k).map { Int(saturating: $0) } }
        changeCount = int(.changeCount) ?? 0
        kind = ClipboardKind(lenient: (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil)
        preview = ((try? c.decodeIfPresent(String.self, forKey: .preview)) ?? nil) ?? ""
        size = int(.size)
        width = int(.width)
        height = int(.height)
        files = c.lenientList(ClipboardFile.self, forKey: .files)
        moreFiles = max(0, int(.moreFiles) ?? 0)
        at = num(.at) ?? 0
        source = ((try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil).flatMap(ClipboardSource.init(rawValue:)) ?? .mac
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try encode(into: &c)
    }

    public func encode(into c: inout KeyedEncodingContainer<K>) throws {
        try c.encode(changeCount, forKey: .changeCount)
        try c.encode(kind.rawValue, forKey: .kind)
        try c.encode(preview, forKey: .preview)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        if !files.isEmpty { try c.encode(files, forKey: .files) }
        if moreFiles > 0 { try c.encode(moreFiles, forKey: .moreFiles) }
        try c.encode(at, forKey: .at)
        try c.encode(source.rawValue, forKey: .source)
    }
}

/// `GET /clipboard`'s item: the summary plus, for text, the string itself (cut at 1 MiB, `truncated`).
public struct ClipboardItem: Sendable, Equatable {
    public var summary: ClipboardSummary
    /// `kind == .text`: the text (nil when only the summary is known — the event carries none — and the page refetches).
    public var text: String?
    public var truncated: Bool

    public init(summary: ClipboardSummary, text: String? = nil, truncated: Bool = false) {
        self.summary = summary
        self.text = text
        self.truncated = truncated
    }

    public var kind: ClipboardKind { summary.kind }
    public var changeCount: Int { summary.changeCount }
}

extension ClipboardItem: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ClipboardSummary.K.self)
        summary = ClipboardSummary(container: c)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil
        truncated = c.flag(.truncated)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ClipboardSummary.K.self)
        try summary.encode(into: &c)
        try c.encodeIfPresent(text, forKey: .text)
        if truncated { try c.encode(true, forKey: .truncated) }
    }
}

/// `GET /clipboard` (and what `PUT /clipboard` answers). `available: false` = this Mac can't do clipboard right now
/// (`reason` says why: no GUI session, helper down…); `item` nil = unavailable or empty.
public struct ClipboardStatus: Sendable, Equatable {
    public var available: Bool
    public var reason: String?
    public var item: ClipboardItem?

    public init(available: Bool = false, reason: String? = nil, item: ClipboardItem? = nil) {
        self.available = available
        self.reason = reason
        self.item = item
    }

    /// The item's kind, `.empty` when there is none (or `.other` while unavailable — nothing to act on).
    public var kind: ClipboardKind { item?.kind ?? (available ? .empty : .other) }
}

extension ClipboardStatus: Codable {
    public enum K: String, CodingKey { case available, reason, item, saved }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        self.init(container: c)
    }

    public init(container c: KeyedDecodingContainer<K>) {
        available = c.flag(.available)
        reason = ((try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        item = (try? c.decodeIfPresent(ClipboardItem.self, forKey: .item)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try encode(into: &c)
    }

    public func encode(into c: inout KeyedEncodingContainer<K>) throws {
        try c.encode(available, forKey: .available)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(item, forKey: .item)
    }
}

/// `PUT /clipboard`: the new status, and the files written to the Mac's drop folder (empty for a text put).
public struct ClipboardPutResponse: Sendable, Equatable {
    public struct Saved: Sendable, Equatable, Codable {
        public var name: String
        public var path: String
        public var size: Int

        private enum K: String, CodingKey { case name, path, size }
        public init(name: String, path: String, size: Int) { self.name = name; self.path = path; self.size = size }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            path = ((try? c.decodeIfPresent(String.self, forKey: .path)) ?? nil) ?? ""
            name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? (path as NSString).lastPathComponent
            size = ((try? c.decodeIfPresent(Double.self, forKey: .size)) ?? nil).map { Int(saturating: $0) } ?? 0
        }
    }

    public var status: ClipboardStatus
    public var saved: [Saved]

    public init(status: ClipboardStatus, saved: [Saved] = []) {
        self.status = status
        self.saved = saved
    }

    /// The folder the files landed in (the first one's), for the toast.
    public var savedFolderName: String? {
        saved.first.map { ($0.path as NSString).deletingLastPathComponent }.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension ClipboardPutResponse: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ClipboardStatus.K.self)
        status = ClipboardStatus(container: c)
        saved = c.lenientList(Saved.self, forKey: .saved)
    }
}

/// What the clipboard takes in one go.
public enum ClipboardLimits {
    /// Text (UTF-8 bytes).
    public static let textBytes = 1_048_576
    /// Files at once.
    public static let filesPerItem = 20
}

extension Int {
    /// `d` clamped to Int's range (NaN: 0): a JSON number that doesn't fit never traps.
    package init(saturating d: Double) {
        if d.isNaN { self = 0 }
        else if d >= 0x1p63 { self = .max }
        else if d <= -0x1p63 { self = .min }
        else { self = Int(d) }
    }
}
