#if os(macOS)
import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

// External displays (docs/LOCAL-API.md「外部显示器」): displays that are not WindowServer's. The program that embeds
// the service supplies their pictures (`ExternalDisplay.publish`), and they are served like any display: listed in
// `/status`'s `displays`, streamed by `/stream?display=<id>` and a link session's `video.open` (the one video loop,
// the same rate control and recovery), a still by `/frame?display=<id>`. They take no input, have no pointer, no
// windows and no console: a stream's status part says `ready` for as long as it runs. Nothing here needs Screen
// Recording or a GUI session.

/// A display whose pictures the embedder supplies.
public final class ExternalDisplay: @unchecked Sendable {
    /// Its `display` id on the wire: unique among the external displays and not a display of WindowServer's.
    public let id: UInt32
    /// As `/status` names it (`displays[].name`); nil: none.
    public let name: String?
    /// `displays[].kind`: an open set on the wire; whatever the embedder's clients know it by.
    public let kind: String
    /// Pixels per point (`displays[].scale`; the listed size is the picture's in points).
    public let scale: Double

    fileprivate let cond = NSCondition()
    fileprivate var buffer: CVPixelBuffer?
    /// The picture's number: another one with every `publish` / `changed`.
    fileprivate var seq: UInt64 = 0
    /// When it was published (ms since 1970).
    fileprivate var at: Double = 0
    fileprivate var removed = false

    public init(id: UInt32, name: String? = nil, kind: String = "virtual", scale: Double = 1) {
        self.id = id
        self.name = name
        self.kind = kind
        self.scale = scale > 0 ? scale : 1
    }

    /// The display's picture from now on (any pixel format VideoToolbox converts; BGRA is the usual). It may be a
    /// live surface that goes on changing: it is copied (and scaled) each time it is encoded. Any thread.
    public func publish(_ buffer: CVPixelBuffer) {
        cond.lock()
        self.buffer = buffer
        note()
        cond.unlock()
    }

    /// The published buffer's content changed (a live surface was drawn into). Any thread.
    public func changed() {
        cond.lock()
        if buffer != nil { note() }
        cond.unlock()
    }

    /// The lock is held.
    private func note() {
        seq &+= 1
        at = Date().timeIntervalSince1970 * 1000
        cond.broadcast()
    }

    /// The picture's size in pixels; nil before the first one.
    public var pixelSize: (width: Int, height: Int)? {
        cond.lock(); defer { cond.unlock() }
        return buffer.map { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) }
    }

    /// `displays[]`'s entry; nil before the first picture.
    var json: [String: Any]? {
        guard let size = pixelSize else { return nil }
        var out: [String: Any] = ["id": Int(id), "width": Double(size.width) / scale, "height": Double(size.height) / scale,
                                  "scale": scale, "main": false, "asleep": false, "kind": kind]
        if let name { out["name"] = name }
        return out
    }

    /// The size a picture at most `maxWidth` wide has: the display's shape, never larger than it, even numbers.
    static func targetSize(width: Int, height: Int, maxWidth: Int) -> (width: Int, height: Int) {
        let w = max(2, min(maxWidth, width)) & ~1
        let h = max(2, Int((Double(w) * Double(height) / Double(max(width, 1))).rounded())) & ~1
        return (w, h)
    }

    /// A video stream's pictures (503 before the display's first one).
    func source(maxWidth: Int) throws -> ExternalDisplaySource {
        guard pixelSize != nil else { throw HTTPError(503, "display \(id) has no picture yet") }
        return ExternalDisplaySource(self, maxWidth: maxWidth)
    }

    /// `/frame`: the picture as it is now, at most `maxWidth` wide.
    func still(maxWidth: Int, quality: Int) throws -> JPEGFrame {
        cond.lock()
        let buffer = self.buffer
        cond.unlock()
        guard let buffer else { throw HTTPError(503, "display \(id) has no picture yet") }
        var full: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &full)
        guard let full else { throw HTTPError(503, "display \(id): the picture can't be read") }
        let size = (width: full.width, height: full.height)
        let w = max(1, min(maxWidth, size.width))
        var image = full
        if w < size.width {
            let h = max(1, Int((Double(w) * Double(size.height) / Double(size.width)).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
            else { throw HTTPError(503, "display \(id): the picture can't be scaled") }
            ctx.interpolationQuality = .medium
            ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { throw HTTPError(503, "display \(id): the picture can't be scaled") }
            image = scaled
        }
        guard let data = encodeJPEG(image, quality: quality) else { throw HTTPError(503, "display \(id): the picture can't be encoded") }
        return JPEGFrame(data: data, width: image.width, height: image.height, display: id)
    }

    fileprivate func remove() {
        cond.lock()
        removed = true
        buffer = nil
        cond.broadcast()
        cond.unlock()
    }
}

/// The external displays the service serves now.
public enum ExternalDisplays {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var displays: [UInt32: ExternalDisplay] = [:]

    /// Serve `display` from now on. false: its id is taken (another external display's, or a display of WindowServer's).
    @discardableResult
    public static func add(_ display: ExternalDisplay) -> Bool {
        guard !Displays.online().contains(display.id) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard displays[display.id] == nil else { return false }
        displays[display.id] = display
        return true
    }

    /// The display is gone: its streams end, and its id is unknown again.
    public static func remove(id: UInt32) {
        lock.lock()
        let d = displays.removeValue(forKey: id)
        lock.unlock()
        d?.remove()
    }

    public static var all: [ExternalDisplay] {
        lock.lock(); defer { lock.unlock() }
        return displays.values.sorted { $0.id < $1.id }
    }

    static func find(_ id: Int?) -> ExternalDisplay? {
        guard let id, let key = UInt32(exactly: id) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return displays[key]
    }

    /// The external display a request's `display` names; nil: none, or a display of WindowServer's.
    static func requested(_ req: HTTPRequest) throws -> ExternalDisplay? {
        find(try req.int("display"))
    }

    /// `/status`'s entries (those with a picture).
    static var json: [[String: Any]] { all.compactMap(\.json) }
}

/// An external display's pictures for the video loop: the published buffer copied into one of the encoder's, at the
/// stream's width. The size is fixed for the stream (congestion only lowers the bit rate); no pointer.
final class ExternalDisplaySource: VideoPictureSource, @unchecked Sendable {
    let display: ExternalDisplay
    let maxWidth: Int
    /// Ends of waits asked for (`wake`); with the display's lock.
    private var wakes: UInt64 = 0
    private var transfer: VTPixelTransferSession?

    fileprivate init(_ display: ExternalDisplay, maxWidth: Int) {
        self.display = display
        self.maxWidth = maxWidth
    }

    /// The picture size this stream has now (0 × 0 once the display is gone).
    var size: (width: Int, height: Int) {
        guard let s = display.pixelSize else { return (0, 0) }
        return ExternalDisplay.targetSize(width: s.width, height: s.height, maxWidth: maxWidth)
    }

    var changeToken: UInt64 {
        display.cond.lock(); defer { display.cond.unlock() }
        return display.seq &+ wakes
    }

    func waitForFrame(after token: UInt64, until deadline: Date) -> Bool {
        let cond = display.cond
        // A strict timer ends the wait on time (the condition's own timeout is coalesced; see StrictTiming).
        let timer = StrictTiming.strictTimer(at: deadline) { cond.lock(); cond.broadcast(); cond.unlock() }
        defer { timer.cancel() }
        cond.lock()
        defer { cond.unlock() }
        while display.seq &+ wakes == token, !display.removed, Date() < deadline { _ = cond.wait(until: deadline) }
        return !display.removed
    }

    func wake() {
        display.cond.lock(); wakes &+= 1; display.cond.broadcast(); display.cond.unlock()
    }

    func newestID() -> VideoPictureID? {
        display.cond.lock(); defer { display.cond.unlock() }
        return display.buffer == nil ? nil : VideoPictureID(frame: display.seq)
    }

    func latest(make: (Int, Int) -> CVPixelBuffer?) -> VideoSourceFrame? {
        display.cond.lock()
        let buffer = display.buffer
        let seq = display.seq
        let at = display.at
        display.cond.unlock()
        guard let buffer else { return nil }
        let size = ExternalDisplay.targetSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                              maxWidth: maxWidth)
        guard let out = make(size.width, size.height) else { return nil }
        if transfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
            if let session {
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
            }
            transfer = session
        }
        guard let transfer, VTPixelTransferSessionTransferImage(transfer, from: buffer, to: out) == noErr else { return nil }
        return VideoSourceFrame(buffer: out, id: VideoPictureID(frame: seq), publishedAt: at)
    }

    deinit {
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }
}

extension Router {
    /// `maxWidth` as `/frame` and `/stream` read it (default 1280, 160…3840).
    static func maxWidthParameter(_ req: HTTPRequest) throws -> Int {
        min(max(try req.int("maxWidth") ?? 1280, 160), 3840)
    }

    /// An external display's video stream from the request: its source, the loop's options and the response's
    /// headers. The same for `GET /stream` and a link session's `video.open`.
    static func externalStream(_ req: HTTPRequest, _ display: ExternalDisplay, label: String)
        throws -> (source: ExternalDisplaySource, options: VideoStreamOptions, headers: [(String, String)]) {
        let options = try StreamRequestOptions.parse(req)
        let codec = try options.codec()
        let fps = videoFPS(requested: try req.int("fps"))
        let source = try display.source(maxWidth: try maxWidthParameter(req))
        var o = VideoStreamOptions(codec: codec, label: label)
        o.streamID = options.streamID
        o.interval = 1 / Double(fps)
        o.tuning = StreamTuning.current.limited(toKbps: options.maxKbps)
        o.statsInterval = 10
        var headers = [("X-Display", "\(display.id)"), ("X-Stream-Codec", codec.rawValue)]
        if let id = options.streamID { headers.append(("X-Stream-Id", id)) }
        let size = source.size
        log("display \(display.id) (external): \(label) open (\(size.width)x\(size.height) \(codec.rawValue) @\(fps) fps"
            + "\(options.streamID.map { " stream \($0)" } ?? ""))")
        return (source, o, headers)
    }

    /// `GET /stream?display=<an external display>`.
    static func streamExternal(_ req: HTTPRequest, _ conn: Connection, _ display: ExternalDisplay) throws {
        let status = try statusRequested(req)
        let made = try externalStream(req, display, label: "video: display \(display.id) stream")
        guard conn.writeHead(status: 200, headers: [("Content-Type", conn.wire.stream), ("Cache-Control", "no-store")] + made.headers)
        else { return }
        if status, !startStatus(StreamStatusFeed(ready: display.id), conn) { return }
        videoStreamLoop(made.source, conn, made.options)
    }

    /// `GET /frame?display=<an external display>` (no `visible=` / `crop=`: it has no windows).
    static func frameExternal(_ req: HTTPRequest, _ display: ExternalDisplay) throws -> JPEGFrame {
        guard req.query["visible"] == nil, req.query["crop"] == nil else {
            throw HTTPError(400, "display \(display.id) is an external display: no visible= or crop=")
        }
        let quality = min(max(try req.int("quality") ?? 70, 10), 95)
        return try display.still(maxWidth: try maxWidthParameter(req), quality: quality)
    }
}
#endif
