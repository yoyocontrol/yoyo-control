#if os(macOS)
import Foundation

// A `/stream` request's video parameters (docs/PROTOCOL.md 「屏幕」「视频流、确认与客户端指针」): the options, the
// picture width and frame rate a ScreenCaptureKit video stream runs at, and `POST /stream/ack`.

/// The video-stream parameters of a `/stream` request (all optional).
struct StreamRequestOptions: Sendable, Equatable {
    /// The client's codec list (known tokens, its order); empty = none given (h264).
    var codecs: [String] = []
    var streamID: String?
    var ack = false
    var cursorClient = false
    /// The bit-rate ceiling (kbit/s, 100…100000; for testing: the clients don't send it): min(server max, this); the start rate
    /// min(server start, this).
    var maxKbps: Int?

    static func parse(_ req: HTTPRequest) throws -> StreamRequestOptions {
        let q = req.query
        var o = StreamRequestOptions()
        o.codecs = StreamCodecs.parse(q["codecs"])
        if let id = q["stream"], !id.isEmpty {
            guard StreamFlowRegistry.isValidID(id) else { throw HTTPError(400, "stream must be 8–64 characters of A-Z a-z 0-9 _ -") }
            o.streamID = id
        }
        switch q["ack"] ?? "" {
        case "", "0": o.ack = false
        case "1": o.ack = true
        default: throw HTTPError(400, "ack must be 1")
        }
        switch q["cursor"] ?? "" {
        case "": o.cursorClient = false
        case "client": o.cursorClient = true
        default: throw HTTPError(400, "cursor must be client")
        }
        if let raw = q["maxKbps"], !raw.isEmpty {
            guard let k = Int(raw), (100...100_000).contains(k) else { throw HTTPError(400, "maxKbps must be an integer 100…100000") }
            o.maxKbps = k
        }
        return o
    }

    /// The stream's codec (StreamCodecs.choose: 503 without any video encoder).
    func codec() throws -> VideoCodec { try StreamCodecs.choose(client: codecs) }
}

extension Router {
    /// YOYO_VIDEO_MAX_WIDTH: when set, the widest video picture, as is. Unset (1600): the floor of the automatic
    /// width (`videoWidthCap`).
    static let videoMaxWidth: Int = {
        let w = ProcessInfo.processInfo.environment["YOYO_VIDEO_MAX_WIDTH"].flatMap(Int.init) ?? 1600
        return min(max(w, 320), 3840)
    }()
    static let videoMaxWidthIsDefault = ProcessInfo.processInfo.environment["YOYO_VIDEO_MAX_WIDTH"] == nil
    /// The widest picture the fast-encode widening may reach.
    static let videoFastWidthLimit = 2048
    /// The widest automatic picture (encode time: 2304 px ≈ 12 ms, 2560 ≈ 14 ms, 3456 ≈ 23–33 ms on an M1 Pro).
    static let videoSharpWidthLimit = 2560

    /// A video stream's widest picture. With YOYO_VIDEO_MAX_WIDTH set: that and the client's maxWidth. Otherwise
    /// two thirds of the source's own width (a 3456-px Retina desktop → 2304: about 1.33 picture pixels per display
    /// point, sharper than a phone's landscape picture needs; 1792 measured visibly softer on text), at least 1600 and
    /// at most 2560 and the source; then, when this Mac's encoder is markedly faster above 1080p's area
    /// (`VideoEncoder.prefersAbove1080p`) and the result is under it, widened to the narrowest width past that line
    /// (within the client's maxWidth, the source and 2048 px). `size(width)` is the stream's own scaling (the real
    /// picture size for a requested width; never wider than the source).
    static func videoWidthCap(codec: VideoCodec, clientMaxWidth: Int,
                              size: (Int) -> (width: Int, height: Int),
                              prefersAbove1080p: (VideoCodec) -> Bool = VideoEncoder.prefersAbove1080p) -> Int {
        let cap: Int
        if videoMaxWidthIsDefault {
            let source = size(100_000).width
            let sharp = min(max(source * 2 / 3, videoMaxWidth), videoSharpWidthLimit, source) & ~1
            cap = min(clientMaxWidth, sharp)
        } else {
            cap = min(clientMaxWidth, videoMaxWidth)
        }
        guard videoMaxWidthIsDefault, prefersAbove1080p(codec),
              let fast = VideoEncoder.fastWidth(minWidth: cap, limit: min(clientMaxWidth, videoFastWidthLimit), size: size)
        else { return cap }
        return fast
    }

    /// A stream's frame rate: the client's `fps` (default 2), at most `maxFPS`.
    static func videoFPS(requested: Int?, tuning t: StreamTuning = .default) -> Int {
        min(max(requested ?? 2, 1), t.maxFPS)
    }

    /// `POST /stream/ack` `{stream, seq, keyframe?, report?}` → 200 `{ok: true, net}` (the stream's network grade,
    /// StreamNetQuality.swift); 404 if no open stream has that id. The report is decoded leniently (never fails the ack):
    /// the only validation it gets (a client may relay it as its phone sent it).
    static func streamAck(_ req: HTTPRequest, _ conn: Connection) throws {
        guard let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            throw HTTPError(400, "body must be a JSON object")
        }
        guard let id = obj["stream"] as? String, StreamFlowRegistry.isValidID(id) else {
            throw HTTPError(400, "stream must be a stream id")
        }
        guard let n = obj["seq"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let d = Double(exactly: n.doubleValue), d >= 0, d.rounded() == d, d < 9.0e15 else {
            throw HTTPError(400, "seq must be a non-negative integer")
        }
        var keyframe = false
        if let k = obj["keyframe"], !(k is NSNull) {
            guard let b = k as? NSNumber, CFGetTypeID(b) == CFBooleanGetTypeID() else { throw HTTPError(400, "keyframe must be a boolean") }
            keyframe = b.boolValue
        }
        // the client's playout report (optional, lenient: never fails the ack)
        let report = StreamPlayoutReport(json: obj["report"])
        guard let flow = StreamFlowRegistry.lookup(id) else { throw HTTPError(404, "no open stream \(id)") }
        flow.ack(seq: UInt64(d), keyframe: keyframe)
        if let report { flow.received(report) }
        conn.json(200, ["ok": true, "net": flow.netQuality().json])
    }
}
#endif
