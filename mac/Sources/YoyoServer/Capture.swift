#if os(macOS)
import CoreGraphics
import CoreMedia
import IOKit.pwr_mgt
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

// MARK: - Displays (CoreGraphics; no TCC needed)

struct DisplayInfo {
    let id: CGDirectDisplayID
    let width: Double  // points
    let height: Double
    let scale: Double  // pixels per point
    let main: Bool
    let asleep: Bool
    /// The display's own name as macOS shows it (`NSScreen.localizedName`, DisplayNames.swift); nil when unknown or
    /// meaningless. Emitted only when present.
    var name: String? = nil
    /// "builtin" (the Mac's own panel) or "external" (anything else WindowServer lists).
    var kind: String = "external"

    var json: [String: Any] {
        var out: [String: Any] = ["id": Int(id), "width": width, "height": height, "scale": scale, "main": main, "asleep": asleep, "kind": kind]
        if let name { out["name"] = name }
        return out
    }
}

enum Displays {
    /// Every online display id, mirror copies included.
    static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Online displays (the active list drops displays that are asleep), minus mirror copies.
    static func active() -> [DisplayInfo] {
        online().compactMap(info)
    }

    static func info(_ id: CGDirectDisplayID) -> DisplayInfo? {
        guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
        let bounds = CGDisplayBounds(id)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let pixelWidth = CGDisplayCopyDisplayMode(id)?.pixelWidth ?? Int(bounds.width)
        return DisplayInfo(id: id, width: bounds.width, height: bounds.height,
                           scale: Double(pixelWidth) / bounds.width,
                           main: CGDisplayIsMain(id) != 0, asleep: CGDisplayIsAsleep(id) != 0,
                           name: DisplayNames.name(id), kind: kind(id))
    }

    /// `DisplayInfo.kind`.
    static func kind(_ id: CGDirectDisplayID) -> String {
        CGDisplayIsBuiltin(id) != 0 ? "builtin" : "external"
    }

    /// Why there is nothing to capture, for /status and 503s.
    static func noDisplayReason() -> String {
        if !SessionInfo.current().loggedIn { return "no GUI login session for this macOS user" }
        return "this session has no display attached"
    }

    /// Wakes a sleeping display (like a mouse nudge; needs no TCC) and waits briefly for it.
    static func wake(_ id: CGDirectDisplayID) {
        guard CGDisplayIsAsleep(id) != 0 else { return }
        var assertion = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity("\(ScreenHost.logName) capture" as CFString, kIOPMUserActiveLocal, &assertion)
        for _ in 0..<20 where CGDisplayIsAsleep(id) != 0 { usleep(100_000) }
        usleep(300_000)  // let the first frames after wake render
    }

    /// `display` query value → a known active display id (default: main). 404 if unknown.
    static func resolve(_ requested: Int?) throws -> CGDirectDisplayID {
        let displays = active()
        guard !displays.isEmpty else { throw HTTPError(503, noDisplayReason()) }
        guard let requested else { return displays.first(where: \.main)?.id ?? displays[0].id }
        guard let match = displays.first(where: { Int($0.id) == requested }) else {
            throw HTTPError(404, "unknown display \(requested)")
        }
        return match.id
    }

    /// Output pixel size: display aspect, at most `maxWidth` and at most native pixels, even numbers.
    static func targetSize(_ id: CGDirectDisplayID, maxWidth: Int) -> (width: Int, height: Int) {
        let bounds = CGDisplayBounds(id)
        let pixelWidth = CGDisplayCopyDisplayMode(id)?.pixelWidth ?? Int(bounds.width)
        let width = max(2, min(maxWidth, pixelWidth)) & ~1
        let height = max(2, Int((Double(width) * bounds.height / max(bounds.width, 1)).rounded())) & ~1
        return (width, height)
    }
}

// MARK: - Capture parameters

struct CaptureParams {
    var display: CGDirectDisplayID
    var maxWidth: Int
    let quality: Int
    /// `/frame`'s `visible=` / `crop=` (Windows.swift); nil for streams and plain frames.
    var filter: FrameFilter? = nil

    init(_ req: HTTPRequest) throws {
        display = try Displays.resolve(try req.int("display"))
        maxWidth = min(max(try req.int("maxWidth") ?? 1280, 160), 3840)
        quality = min(max(try req.int("quality") ?? 70, 10), 95)
    }

    /// Tests: a capture of `display` without resolving it.
    init(display: CGDirectDisplayID, maxWidth: Int = 1280, quality: Int = 70) {
        self.display = display
        self.maxWidth = maxWidth
        self.quality = quality
    }
}

// MARK: - Helpers

private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

/// Runs async work from a plain thread and waits for it.
/// `timeout`: stop waiting after that long (504; the work still finishes in the background, its result dropped).
func blocking<T>(timeout: TimeInterval? = nil, _ work: @escaping () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    if let timeout {
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw HTTPError(504, "no picture within \(Int(timeout * 1000)) ms")
        }
    } else {
        done.wait()
    }
    return try box.result!.get()
}

func requireScreenRecording() throws {
    guard CGPreflightScreenCaptureAccess() else {
        throw HTTPError(403, "Screen Recording permission is not granted to \(ScreenHost.appName)")
    }
}

/// Maps ScreenCaptureKit failures to HTTP errors (permission problems → 403).
func captureError(_ error: Error) -> HTTPError {
    if let http = error as? HTTPError { return http }
    let ns = error as NSError
    if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue
        || !CGPreflightScreenCaptureAccess()
    {
        return HTTPError(403, "Screen Recording permission is not granted to \(ScreenHost.appName)")
    }
    return HTTPError(500, "capture failed: \(ns.localizedDescription)")
}

func scDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    if let display = content.displays.first(where: { $0.displayID == id }) { return display }
    throw HTTPError(404, "unknown display \(id)")
}

/// `showsCursor`: ScreenCaptureKit draws the pointer into the pictures (false: a `cursor=client` video stream, whose
/// pointer goes out as cursor parts).
func streamConfiguration(_ params: CaptureParams, fps: Int = 1, showsCursor: Bool = true) -> SCStreamConfiguration {
    let size = Displays.targetSize(params.display, maxWidth: params.maxWidth)
    let config = SCStreamConfiguration()
    config.width = size.width
    config.height = size.height
    config.showsCursor = showsCursor
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.queueDepth = 3
    return config
}

func encodeJPEG(_ image: CGImage, quality: Int) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    let props = [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary
    CGImageDestinationAddImage(dest, image, props)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}

struct JPEGFrame {
    let data: Data
    let width: Int
    let height: Int
    var display: CGDirectDisplayID = 0
    /// The region a `/frame?crop=` picture shows (normalized), for `X-Crop`.
    var crop: CGRect? = nil
    /// How a `visible=` frame was filtered, for `X-Frame-Filter`; nil without `visible=`.
    var filter: FrameFilterMode? = nil
}

/// How a stream's capture went by its first frame (`FrameStream.firstFrame`).
enum FirstFrame: Equatable, Sendable {
    /// A complete frame within the wait.
    case firstFrame
    /// Started, but no complete frame within the wait (late frames still go out).
    case noFirstFrame
    /// Stopped before a frame.
    case failed
}

// MARK: - Single frame

func captureFrame(_ params: CaptureParams) throws -> JPEGFrame {
    try requireScreenRecording()
    return try captureFrameOnce(params)
}

private func captureFrameOnce(_ params: CaptureParams, timeout: TimeInterval? = nil) throws -> JPEGFrame {
    Displays.wake(params.display)
    var image: CGImage
    var catalog: WindowCatalog?
    var mode: FrameFilterMode?
    // a crop is cut from the display's full resolution, then scaled to maxWidth (`/frame?crop=`, Windows.swift)
    var shot = params
    if params.filter?.crop != nil { shot.maxWidth = Int(Int32.max) }
    // `visible=`: the compositor leaves the other apps out (NativeFilter.swift), else they are covered
    if let visible = params.filter?.visible, let native = try? nativeFilteredPicture(shot, visible: visible, hidden: params.filter?.hidden ?? HiddenApps()) {
        image = native
        mode = .native
    } else {
        do {
            (image, catalog) = try blocking(timeout: timeout) {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == params.display }) else {
                    throw HTTPError(404, "unknown display \(params.display)")
                }
                // this process's windows (the automation border, Automation.swift) are never in a picture
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows(content))
                // `visible=`: the window list for the covering, taken right before the picture
                let windows = params.filter?.visible != nil ? WindowCatalog.current() : nil
                let picture = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: streamConfiguration(shot))
                return (picture, windows)
            }
        } catch {
            throw captureError(error)
        }
        if params.filter?.visible != nil { mode = .mask }
    }
    var crop: CGRect?
    if let filter = params.filter {
        (image, crop) = filter.render(image, catalog: catalog ?? WindowCatalog(records: [], displays: [], finder: nil),
                                      display: params.display, maxWidth: params.maxWidth, covering: mode == .mask)
    }
    guard let jpeg = encodeJPEG(image, quality: params.quality) else { throw HTTPError(500, "JPEG encoding failed") }
    return JPEGFrame(data: jpeg, width: image.width, height: image.height, display: params.display, crop: crop, filter: mode)
}

/// How a `visible=` frame left the other apps out (`X-Frame-Filter`).
enum FrameFilterMode: String {
    /// ScreenCaptureKit composed only the visible apps' windows and the desktop furniture (NativeFilter.swift).
    case native
    /// The whole display, the other apps' windows covered with blocks (round 1, Windows.swift).
    case mask
}

/// How long the native path may take before the frame falls back to covering.
let nativeFilterTimeout: TimeInterval = 5

/// The display composed with only `visible`'s windows and the desktop furniture (NativeFilterPlan); throws (logged)
/// when the native path is unavailable.
private func nativeFilteredPicture(_ shot: CaptureParams, visible: Set<String>, hidden: HiddenApps) throws -> CGImage {
    do {
        return try blocking(timeout: nativeFilterTimeout) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == shot.display }) else {
                throw NativeFilterUnavailable(description: "display \(shot.display) is not in the shareable content")
            }
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let records = WindowCatalog.records(from: list, lookup: WindowCatalog.runningApp)
            let plan = NativeFilterPlan.make(records: records, visible: visible, hidden: hidden)
            let filter = try nativeContentFilter(plan, display: display, content: content)
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: streamConfiguration(shot))
        }
    } catch {
        log("frame: native visible filter unavailable (\(error)); covering instead")
        throw error
    }
}

// MARK: - Stream

/// Wraps an SCStream for a video stream: keeps the newest complete frame's pixel buffer (throttled to fps), which the
/// stream's loop encodes (`VideoPictureSource`, VideoStreamLoop.swift).
final class FrameStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let params: CaptureParams
    let interval: TimeInterval
    /// ScreenCaptureKit draws the pointer into the pictures (false: `cursor=client`, DisplayPointer.swift).
    let showsCursor: Bool
    /// `cursor=client`: the pointer the stream sends as cursor parts (set before the stream's loop starts).
    var pointer: DisplayCursorFeed?
    /// Every callback, for a link session's trace (set before the capture starts): its `SCFrameStatus` (-1: none),
    /// whether the fps gate dropped it, the newest accepted picture's number, and display → callback (ms).
    var onTrace: (@Sendable (_ status: Int, _ gated: Bool, _ seq: Int, _ latencyMs: Double?) -> Void)?
    private let queue = DispatchQueue(label: "yoyo-control.stream")
    private let cond = NSCondition()
    private var stream: SCStream?
    private var lastEncode: TimeInterval = 0
    /// A complete frame sooner than this fraction of the interval after the last one kept is dropped.
    static let gateFraction = 0.5
    private var sleepAssertion = IOPMAssertionID(0)
    // Guarded by cond:
    private var seq = 0
    private var stopped = false
    /// The newest complete frame and when it arrived (ms since 1970).
    private var latestPixels: (buffer: CVPixelBuffer, at: Double)?
    /// Bumped by every new frame and by `wake()`: ends a `waitForFrame` (VideoPictureSource.changeToken).
    private var changes: UInt64 = 0
    /// What the callbacks have been doing (stall detection, the stream's stats line; `CaptureActivity`).
    private var activity = CaptureActivity()
    /// When the first complete frame was taken (`systemUptime`).
    private var firstFrameAt: TimeInterval?

    init(_ params: CaptureParams, fps: Int, showsCursor: Bool = true) {
        self.params = params
        self.interval = 1 / Double(fps)
        self.showsCursor = showsCursor
    }

    func start(fps: Int) throws {
        try requireScreenRecording()
        Displays.wake(params.display)
        // Keep the display awake while someone is watching.
        IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "\(ScreenHost.logName) stream" as CFString, &sleepAssertion)
        cond.lock(); activity = CaptureActivity(startedAt: ProcessInfo.processInfo.systemUptime); cond.unlock()
        // the newest stream's frames measure the capture latency (X-Audio-Video-Offset)
        VideoCaptureLatency.shared.begin(ObjectIdentifier(self))
        do {
            let stream = try blocking { [self] () -> SCStream in
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == params.display }) else {
                    throw HTTPError(404, "unknown display \(params.display)")
                }
                // this process's windows on screen now (the automation border; it is also `sharingType = .none`)
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows(content))
                let stream = SCStream(filter: filter, configuration: streamConfiguration(params, fps: fps, showsCursor: showsCursor), delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                return stream
            }
            self.stream = stream
        } catch {
            throw captureError(error)
        }
    }

    func stop() {
        if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        guard let stream else { return }
        self.stream = nil
        _ = try? blocking { try await stream.stopCapture() }
    }

    /// Whether the first complete frame came within `seconds` of the capture starting (counted from after the display
    /// was woken, so the time `start` itself takes counts). Waits until then at most.
    func firstFrame(within seconds: TimeInterval) -> FirstFrame {
        cond.lock()
        defer { cond.unlock() }
        let deadline = activity.startedAt + seconds
        while firstFrameAt == nil, !stopped {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            if left <= 0 || !cond.wait(until: Date().addingTimeInterval(left)) { break }
        }
        if let at = firstFrameAt { return at <= deadline ? .firstFrame : .noFirstFrame }
        return stopped ? .failed : .noFirstFrame
    }

    /// The callbacks since the last call (the stream's periodic stats line).
    func takeActivityWindow() -> CaptureActivityWindow {
        cond.lock(); defer { cond.unlock() }
        return activity.takeWindow(at: ProcessInfo.processInfo.systemUptime)
    }

    // SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let attachments = buffer.isValid
            ? CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] : nil
        let status = (attachments?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        let now = ProcessInfo.processInfo.systemUptime
        // ScreenCaptureKit already paces frames (`minimumFrameInterval`); callbacks then jitter by several ms around it.
        // The gate only drops what really comes twice in one frame interval: at 0.9 × it dropped ~11 % of a 60 fps
        // capture (callbacks 9–15 ms after the last, the next one ~18 ms later; a link field trace, docs/LINK.md
        // 「逐帧跟踪」). The stream's loop caps the rate itself and takes the newest picture.
        let gated = status == .complete && now - lastEncode < interval * Self.gateFraction
        cond.lock(); activity.note(status, at: now, gated: gated); cond.unlock()
        var latencyMs: Double?
        if status == .complete, let display = (attachments?.first?[.displayTime] as? NSNumber)?.uint64Value, display > 0 {
            // display → this callback (where X-Frame-Time is stamped), for X-Audio-Video-Offset (AudioVideoOffset.swift)
            let nowHost = mach_absolute_time()
            if nowHost >= display {
                latencyMs = HostClock.nanos(nowHost - display) / 1e6
                VideoCaptureLatency.shared.note(ObjectIdentifier(self), ms: latencyMs!)
            }
        }
        defer {
            if let onTrace {
                cond.lock(); let n = seq; cond.unlock()
                onTrace(status.map { $0.rawValue } ?? -1, gated, n, latencyMs)
            }
        }
        guard status == .complete, !gated, let pixels = buffer.imageBuffer else { return }
        lastEncode = now

        cond.lock()
        latestPixels = (pixels, Date().timeIntervalSince1970 * 1000)
        seq += 1
        changes &+= 1
        if firstFrameAt == nil { firstFrameAt = now }
        cond.broadcast()
        cond.unlock()
    }

    // SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error.localizedDescription)")
        cond.lock()
        stopped = true
        cond.broadcast()
        cond.unlock()
    }
}

/// A `FrameStream`'s callbacks by `SCFrameStatus`: when ScreenCaptureKit was last alive (a complete or an idle
/// callback), and counts per stats window. Times are `systemUptime` seconds.
struct CaptureActivity: Sendable {
    var startedAt: TimeInterval = 0
    /// The last complete or idle callback.
    private(set) var lastAliveAt: TimeInterval?
    private var window = CaptureActivityWindow()
    private var windowStart: TimeInterval?
    /// The last complete callback (gated ones included).
    private(set) var lastCompleteAt: TimeInterval?

    init(startedAt: TimeInterval = 0) { self.startedAt = startedAt }

    /// One callback (`gated`: a complete frame the fps gate drops).
    mutating func note(_ status: SCFrameStatus?, at now: TimeInterval, gated: Bool = false) {
        if windowStart == nil { windowStart = startedAt > 0 ? startedAt : now }
        switch status {
        case .complete?:
            lastAliveAt = now
            window.complete += 1
            if gated { window.gated += 1 }
            if let last = lastCompleteAt { window.completeGapsMs.append((now - last) * 1000) }
            lastCompleteAt = now
        case .idle?:
            lastAliveAt = now
            window.idle += 1
        default:
            window.other += 1  // blank / suspended / started / stopped / no status: not a sign of a live picture
        }
    }

    /// The window since the last take; a new one starts.
    mutating func takeWindow(at now: TimeInterval) -> CaptureActivityWindow {
        var out = window
        out.seconds = max(0, now - (windowStart ?? now))
        window = CaptureActivityWindow()
        windowStart = now
        return out
    }
}

/// Callbacks over one stats window.
struct CaptureActivityWindow: Sendable, Equatable {
    var seconds: TimeInterval = 0
    var complete = 0
    var idle = 0
    var other = 0
    /// Complete frames the fps gate dropped.
    var gated = 0
    /// Gaps between consecutive complete callbacks (ms).
    var completeGapsMs: [Double] = []

    func perSecond(_ n: Int) -> Double { seconds > 0 ? Double(n) / seconds : 0 }

    /// The `q` quantile of the complete-frame gaps (ms), nil without any.
    func gapMs(_ q: Double) -> Double? {
        guard !completeGapsMs.isEmpty else { return nil }
        let sorted = completeGapsMs.sorted()
        return sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))]
    }

    /// "complete 33.1/s idle 22.0/s other 0.0/s gated 0, complete gap p50/90/99 33/51/55 ms"
    var line: String {
        var s = String(format: "complete %.1f/s idle %.1f/s other %.1f/s gated %d", perSecond(complete), perSecond(idle),
                       perSecond(other), gated)
        if let p50 = gapMs(0.5), let p90 = gapMs(0.9), let p99 = gapMs(0.99) {
            s += String(format: ", complete gap p50/90/99 %.0f/%.0f/%.0f ms", p50, p90, p99)
        }
        return s
    }

    var json: [String: Any] {
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return ["seconds": r(seconds), "completePerSecond": r(perSecond(complete)), "idlePerSecond": r(perSecond(idle)),
                "otherPerSecond": r(perSecond(other)), "gated": gated,
                "completeGapMs": [gapMs(0.5), gapMs(0.9), gapMs(0.99)].map { $0.map { r($0) as Any } ?? NSNull() }]
    }
}

/// A real display's pictures for the video loop: the newest captured frame as is (fixed size; congestion only lowers
/// the bit rate), the pointer from `pointer` (`cursor=client`), the capture's callbacks for the stats line.
extension FrameStream: VideoPictureSource {
    var changeToken: UInt64 { cond.lock(); defer { cond.unlock() }; return changes }

    func waitForFrame(after token: UInt64, until deadline: Date) -> Bool {
        // A strict timer ends the wait on time (the condition's own timeout is coalesced; see StrictTiming).
        let timer = StrictTiming.strictTimer(at: deadline) { [cond] in cond.lock(); cond.broadcast(); cond.unlock() }
        defer { timer.cancel() }
        cond.lock()
        defer { cond.unlock() }
        while changes == token, !stopped, Date() < deadline { _ = cond.wait(until: deadline) }
        return !stopped
    }

    func wake() {
        cond.lock(); changes &+= 1; cond.broadcast(); cond.unlock()
    }

    func newestID() -> VideoPictureID? {
        cond.lock(); defer { cond.unlock() }
        return latestPixels == nil ? nil : VideoPictureID(frame: UInt64(seq))
    }

    func latest(make: (Int, Int) -> CVPixelBuffer?) -> VideoSourceFrame? {
        cond.lock(); defer { cond.unlock() }
        guard let p = latestPixels else { return nil }
        return VideoSourceFrame(buffer: p.buffer, id: VideoPictureID(frame: UInt64(seq)), publishedAt: p.at)
    }

    var cursorFeed: DisplayCursorFeed? { pointer }

    func captureWindow() -> CaptureActivityWindow? { takeActivityWindow() }
}
#endif
