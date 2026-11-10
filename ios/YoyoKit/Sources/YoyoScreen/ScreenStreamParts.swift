import Foundation
import YoyoClipboard
import YoyoCore

/// The headers of one part of the screen stream (docs/PROTOCOL.md「屏幕」). Every value is optional: a value that is
/// missing or doesn't parse is nil.
public struct ScreenPartHeaders: Sendable, Equatable {
    public var contentType: String?
    /// Picture size in pixels (the picture covers the whole display).
    public var width: Int?
    public var height: Int?
    /// `X-Frame-Seq`: monotonic per stream, counting every part (pictures, cursor and status parts).
    public var seq: Int?
    /// `X-Frame-Kind`: `key` / `delta` / `refine` / `keepalive` (video), `cursor`, `status`.
    public var kind: String?
    /// `X-Frame-Time`: ms since 1970 (Mac clock) when the content was published. Informational.
    public var time: Double?
    /// `X-Stream-Codec`: `h264` / `hevc`.
    public var codec: String?
    /// `X-Audio-Seq` of a sound part (`GET /audio`): +1 per packet, never reset within a response.
    public var audioSeq: Int?
    /// `X-Audio-Time`: ms since 1970 (Mac clock, as `X-Frame-Time`) of the packet's first sample.
    public var audioTime: Double?

    public init(contentType: String? = nil, width: Int? = nil, height: Int? = nil, seq: Int? = nil, kind: String? = nil,
         time: Double? = nil, codec: String? = nil, audioSeq: Int? = nil, audioTime: Double? = nil) {
        self.contentType = contentType; self.width = width; self.height = height; self.seq = seq; self.kind = kind
        self.time = time; self.codec = codec; self.audioSeq = audioSeq; self.audioTime = audioTime
    }

    /// From a header lookup (names as sent; the lookup decides about case).
    init(_ value: (String) -> String?) {
        func text(_ name: String) -> String? {
            value(name).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        func int(_ name: String) -> Int? { text(name).flatMap { Int($0) } }
        contentType = text("Content-Type")
        width = int("X-Frame-Width").flatMap { $0 > 0 ? $0 : nil }
        height = int("X-Frame-Height").flatMap { $0 > 0 ? $0 : nil }
        seq = int("X-Frame-Seq").flatMap { $0 >= 0 ? $0 : nil }
        kind = text("X-Frame-Kind")?.lowercased()
        time = text("X-Frame-Time").flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil }
        codec = text("X-Stream-Codec")?.lowercased()
        audioSeq = int("X-Audio-Seq").flatMap { $0 >= 0 ? $0 : nil }
        audioTime = text("X-Audio-Time").flatMap { Double($0) }.flatMap { $0.isFinite ? $0 : nil }
    }

    /// From a part's header block (`Name: value` lines).
    init(block: String) {
        var fields: [String: String] = [:]
        for line in block.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            fields[name] = String(line[line.index(after: colon)...])
        }
        self.init { fields[$0.lowercased()] }
        length = fields["content-length"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// `Content-Length` of a part read from the raw body (the split mode has it as the response's expected length).
    private(set) var length: Int?
}

/// One part of the screen stream: a picture (one H.264 / HEVC access unit), a cursor update, a connection state (`.status`, asked for with `status=1`), a sound packet (`.audio`: `audio/*`, the parts of `GET /audio`;
/// the picture stream ignores one), or a part of a type this client doesn't know (`.other`, its body dropped: it is only
/// reported so its `seq` isn't taken for a gap).
public struct ScreenStreamPart: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case h264, hevc, cursor, status, audio, other

        /// The kind of a part's `Content-Type` (none, or one this client doesn't know: `.other`).
        public init(contentType: String?) {
            let type = contentType?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            switch type {
            case "video/h264", "video/avc": self = .h264
            case "video/hevc", "video/h265": self = .hevc
            case ScreenWire.cursorType: self = .cursor
            case ScreenWire.statusType: self = .status
            default: self = type.hasPrefix("audio/") ? .audio : .other
            }
        }

        /// A video picture (acked as it arrives).
        var isPicture: Bool { self == .h264 || self == .hevc }
    }

    public var kind: Kind
    public var body: Data
    public var headers = ScreenPartHeaders()
    /// A uu Link picture's frame number (`ScreenLinkStream`: the decoder's answer names it); nil on HTTP.
    var linkFrame: UInt32?

    public init(kind: Kind, body: Data, headers: ScreenPartHeaders = ScreenPartHeaders()) {
        self.kind = kind
        self.body = body
        self.headers = headers
    }

    var width: Int? { headers.width }
    var height: Int? { headers.height }
    var seq: Int? { headers.seq }
    /// A picture that moves the picture on, not a re-encode of an unchanged one (`refine` / `keepalive`: their
    /// `X-Frame-Time` is the original picture's).
    var isLivePicture: Bool { headers.kind != "refine" && headers.kind != "keepalive" }

    /// Largest accepted body of each kind (never above `limit`, the stream's own); bigger parts are skipped unread.
    static func maxBody(_ kind: Kind, limit: Int) -> Int {
        switch kind {
        case .h264, .hevc: min(limit, maxVideoPart)
        case .cursor: min(limit, maxCursorPart)
        case .status: min(limit, maxStatusPart)
        case .audio: min(limit, maxAudioPart)
        case .other: 0
        }
    }
    static let maxVideoPart = 8 * 1024 * 1024
    static let maxCursorPart = 1024 * 1024
    static let maxStatusPart = 64 * 1024
    /// One Opus packet is a few hundred bytes.
    static let maxAudioPart = 64 * 1024
}

/// Incremental parser of the screen stream's multipart body (`GET /stream`, `GET /audio`; the framing
/// the boundary from the response's `Content-Type`, `frame` today). Pure and synchronous: feed it
/// the bytes as they arrive, in chunks split anywhere, and it returns the parts completed so far. A part is
/// `--<boundary>\r\n<headers>\r\n\r\n<body>`; with `Content-Length` the body is taken by length, without it the body
/// ends at the next `\r\n--<boundary>`. A preamble before the first boundary and the closing `--<boundary>--` are
/// skipped. Parts are told apart by their `Content-Type` (`ScreenStreamPart.Kind`); one of an unknown type, or larger
/// than its kind allows, is skipped without being buffered (an unknown one is still reported, bodiless, for its seq).
/// Memory stays bounded: a buffer that grows past `maxBuffer` without completing a part is dropped.
struct StreamPartParser {
    static let defaultMaxBuffer = 20 * 1024 * 1024
    /// A part's headers (and a boundary line's padding) larger than this are not a frame: dropped.
    static let maxHeaderBytes = 8 * 1024

    private enum State {
        /// Looking for the next `--<boundary>` line.
        case boundary
        /// Right after the boundary line: the part's headers.
        case headers
        case body(ScreenPartHeaders)
        /// Dropping a part's body of known length unread.
        case skip(remaining: Int)
    }

    let boundary: String
    private let delimiter: Data
    private let bodyEnd: Data
    private let maxBuffer: Int
    private var buffer = Data()
    private var state = State.boundary
    /// How much of a length-less body was already searched for its end (the search resumes there).
    private var scanned = 0

    private static let crlf = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let dashes = Data("--".utf8)

    init(boundary: String, maxBuffer: Int = StreamPartParser.defaultMaxBuffer) {
        self.boundary = boundary
        delimiter = Data(("--" + boundary).utf8)
        bodyEnd = Data(("\r\n--" + boundary).utf8)
        self.maxBuffer = maxBuffer
    }

    /// The boundary of a `multipart/...; boundary=<b>` Content-Type (quotes removed); nil when there is none.
    static func boundary(fromContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        for param in contentType.split(separator: ";").dropFirst() {
            let kv = param.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else { continue }
            var value = kv[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Bytes waiting for the rest of their part.
    var bufferedCount: Int { buffer.count }

    mutating func feed(_ data: Data) -> [ScreenStreamPart] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var parts: [ScreenStreamPart] = []
        while step(into: &parts) {}
        if buffer.count > maxBuffer {
            buffer = Data()
            state = .boundary
            scanned = 0
        }
        return parts
    }

    /// One state transition; false when more bytes are needed.
    private mutating func step(into parts: inout [ScreenStreamPart]) -> Bool {
        let start = buffer.startIndex
        switch state {
        case .boundary:
            guard let r = buffer.range(of: delimiter) else {
                // keep only what could be the start of a delimiter
                let keep = delimiter.count - 1
                if buffer.count > keep { buffer = Data(buffer.suffix(keep)) }
                return false
            }
            // the closing `--<b>--`, or transport padding up to the line's CRLF
            let after = r.upperBound
            guard buffer.endIndex - after >= 2 else { return false }
            if buffer[after..<after + 2] == Self.dashes {
                buffer = Data(buffer[(after + 2)...])
                return true
            }
            guard let eol = buffer.range(of: Self.crlf, in: after..<buffer.endIndex) else {
                // padding after a boundary is a few bytes; this much isn't a boundary line
                guard buffer.endIndex - after > Self.maxHeaderBytes else { return false }
                buffer = Data(buffer[after...])
                return true
            }
            buffer = Data(buffer[eol.upperBound...])
            state = .headers
            return true
        case .headers:
            // no headers at all: the blank line comes first
            if buffer.count >= 2, buffer[start..<start + 2] == Self.crlf {
                buffer = Data(buffer[(start + 2)...])
                state = .body(ScreenPartHeaders())
                return true
            }
            // resume where the last search stopped; headers that never end are dropped (look for the next part)
            let from = start + max(0, scanned - (Self.headerEnd.count - 1))
            guard let r = buffer.range(of: Self.headerEnd, in: from..<buffer.endIndex) else {
                if buffer.count > Self.maxHeaderBytes {
                    buffer = Data()
                    state = .boundary
                    scanned = 0
                } else {
                    scanned = buffer.count
                }
                return false
            }
            scanned = 0
            let headers = ScreenPartHeaders(block: String(decoding: buffer[start..<r.lowerBound], as: UTF8.self))
            buffer = Data(buffer[r.upperBound...])
            let kind = ScreenStreamPart.Kind(contentType: headers.contentType)
            if let length = headers.length, length > ScreenStreamPart.maxBody(kind, limit: maxBuffer) {
                // not kept: an unknown part is still reported (its seq is no gap), an oversized one is lost
                if kind == .other { parts.append(ScreenStreamPart(kind: .other, body: Data(), headers: headers)) }
                state = .skip(remaining: length)
            } else {
                state = .body(headers)
            }
            return true
        case .skip(let remaining):
            let n = min(remaining, buffer.count)
            buffer = Data(buffer[(start + n)...])
            guard n == remaining else {
                state = .skip(remaining: remaining - n)
                return false
            }
            state = .boundary
            return true
        case .body(let headers):
            let end: Int
            let resume: Int
            if let length = headers.length {
                guard buffer.count >= length else { return false }
                end = start + length
                resume = end
            } else {
                let from = start + max(0, scanned - (bodyEnd.count - 1))
                guard let r = buffer.range(of: bodyEnd, in: from..<buffer.endIndex) else {
                    scanned = buffer.count
                    return false
                }
                end = r.lowerBound
                // leave `--<b>` for the boundary state
                resume = r.lowerBound + 2
            }
            let kind = ScreenStreamPart.Kind(contentType: headers.contentType)
            if kind == .other {
                parts.append(ScreenStreamPart(kind: .other, body: Data(), headers: headers))
            } else if end > start, end - start <= ScreenStreamPart.maxBody(kind, limit: maxBuffer) {
                parts.append(ScreenStreamPart(kind: kind, body: Data(buffer[start..<end]), headers: headers))
            }
            buffer = Data(buffer[resume...])
            state = .boundary
            scanned = 0
            return true
        }
    }
}

/// What `ScreenStream` makes of the responses and bytes URLSession hands it. Two shapes arrive: the raw multipart body
/// under one response (read by `StreamPartParser`), or, when URLSession recognises `multipart/x-mixed-replace` and splits
/// the stream itself (seen over HTTP/3), one response per part (the part's headers as the response's headers,
/// boundaries stripped) followed by that part's bytes. Pure and synchronous, like the parser.
struct StreamPartAssembler {
    /// A part bigger than this is not a frame: dropped (memory stays bounded, as in the parser). Video and cursor
    /// parts have lower limits (`ScreenStreamPart.maxBody`).
    let maxPart: Int
    private var parser: StreamPartParser?
    private var part: (data: Data, length: Int?, kind: ScreenStreamPart.Kind, headers: ScreenPartHeaders)?
    private var responses = 0

    init(maxPart: Int = StreamPartParser.defaultMaxBuffer) { self.maxPart = maxPart }

    /// Whether URLSession is splitting the stream into one response per part.
    private(set) var split = false
    /// The stream's `X-Stream-Codec` from its own response head (nil: none; the video stream treats that as a failure).
    private(set) var streamCodec: String?

    /// A response: the stream's own (the first) or, once URLSession splits, the next part's. Throws when the first is
    /// not a stream; returns the parts a new response completes (a split part of unknown length ends at the next one).
    mutating func receive(status: Int, contentType: String?, expectedLength: Int64,
                          headers: ScreenPartHeaders = ScreenPartHeaders()) throws -> [ScreenStreamPart] {
        responses += 1
        if responses == 1 {
            if status == 401 { throw YoyoError.unauthorized }
            guard (200..<300).contains(status) else { throw YoyoError.http(status, nil) }
            streamCodec = headers.codec
            if let boundary = StreamPartParser.boundary(fromContentType: contentType) {
                parser = StreamPartParser(boundary: boundary, maxBuffer: maxPart)
                return []
            }
            guard let contentType, !contentType.isEmpty, ScreenStreamPart.Kind(contentType: contentType) != .other else {
                throw YoyoError.decoding("screen stream")
            }
        }
        // A later response (or a first one that is already a part): URLSession splits the stream.
        split = true
        parser = nil
        var done = flush()
        guard (200..<300).contains(status) else { return done }
        var headers = headers
        if headers.contentType == nil { headers.contentType = contentType }
        // a split part without a type isn't one of ours
        let kind = contentType.map { ScreenStreamPart.Kind(contentType: $0) } ?? .other
        let length = expectedLength > 0 ? Int(expectedLength) : nil
        if kind == .other {
            done.append(ScreenStreamPart(kind: .other, body: Data(), headers: headers))
        } else if (length ?? 0) <= ScreenStreamPart.maxBody(kind, limit: maxPart) {
            part = (Data(), length, kind, headers)
        }
        return done
    }

    mutating func feed(_ data: Data) -> [ScreenStreamPart] {
        guard split else { return parser?.feed(data) ?? [] }
        guard var p = part else { return [] }
        p.data.append(data)
        if let length = p.length, p.data.count >= length {
            part = nil
            return [ScreenStreamPart(kind: p.kind, body: Data(p.data.prefix(length)), headers: p.headers)]
        }
        part = p.data.count > ScreenStreamPart.maxBody(p.kind, limit: maxPart) ? nil : p
        return []
    }

    /// The stream ended: a split part of unknown length is complete; one short of its length is dropped.
    mutating func finish() -> [ScreenStreamPart] { split ? flush() : [] }

    private mutating func flush() -> [ScreenStreamPart] {
        defer { part = nil }
        guard let p = part, p.length == nil, !p.data.isEmpty else { return [] }
        return [ScreenStreamPart(kind: p.kind, body: p.data, headers: p.headers)]
    }
}
