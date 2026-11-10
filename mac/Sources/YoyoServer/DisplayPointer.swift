#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import ImageIO

// The pointer of a REAL display's ScreenCaptureKit video stream with `cursor=client` (docs/PROTOCOL.md 「屏幕」,
// "视频流、确认与客户端指针"): the pictures leave it out (`SCStreamConfiguration.showsCursor = false`) and the stream
// sends cursor parts instead, so the phone draws the pointer itself and moves it the moment a
// finger lands, without waiting for the round trip.
//
// Where the pointer is, normalized to the display (the space of `/input` x/y):
//   - our own input: `/input` knows where it put the pointer as soon as it handled the request (`noteInput`);
//   - someone at the Mac (or the system) moving it: `CGEvent(source: nil).location` polled every 50 ms; only a CHANGE
//     of that location moves the stream's pointer, so a location that doesn't follow our input (a background session)
//     never pulls it back. Off this display: invisible.
// Its shape: the system's current cursor (`NSCursor.currentSystem`, compared every 100 ms), else the built-in arrow.

/// The system cursor's image as the probe saw it: points (not pixels) for the size and the hotspot.
struct SystemCursorImage: Sendable, Equatable {
    /// Same image, same key (a hash of its pixels and hotspot).
    let key: Int
    let png: Data
    let hotX: Double
    let hotY: Double
    let width: Double
    let height: Double
}

/// Where the pointer is and what it looks like, system-wide (a fake in tests).
protocol SystemPointerProbe: AnyObject, Sendable {
    /// The pointer in global display coordinates (CGDisplayBounds' space), nil when unknown.
    func location() -> CGPoint?
    /// The system's current cursor, nil when it can't be had.
    func cursorImage() -> SystemCursorImage?
}

/// The real probe: CGEvent for the location, `NSCursor.currentSystem` (on the main queue, cached) for the shape.
final class SystemPointer: SystemPointerProbe, @unchecked Sendable {
    static let shared = SystemPointer()

    private let lock = NSLock()
    // Guarded by `lock`:
    private var cached: SystemCursorImage?
    private var cachedOnce = false
    private var refreshing = false
    /// The last image's identity and key: the same NSImage needs no new hash.
    private var lastImage: ObjectIdentifier?

    func location() -> CGPoint? { CGEvent(source: nil)?.location }

    /// The latest shape; asks the main queue for a fresh one (AppKit) and, the first time, waits up to 100 ms for it.
    func cursorImage() -> SystemCursorImage? {
        lock.lock()
        let first = !cachedOnce
        let start = !refreshing
        if start { refreshing = true }
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        if start {
            DispatchQueue.main.async { [self] in
                let image = Self.readSystemCursor(previous: lastIdentity())
                lock.lock()
                if let image { cached = image.value; lastImage = image.identity } else { cached = nil; lastImage = nil }
                cachedOnce = true
                refreshing = false
                lock.unlock()
                done.signal()
            }
        }
        if first, start, !Thread.isMainThread { _ = done.wait(timeout: .now() + 0.1) }
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    private func lastIdentity() -> (ObjectIdentifier, SystemCursorImage)? {
        lock.lock(); defer { lock.unlock() }
        guard let id = lastImage, let c = cached else { return nil }
        return (id, c)
    }

    /// Logged once per process (main thread only).
    nonisolated(unsafe) private static var loggedBadPNG = false

    /// The PNG decodes to an image with pixels.
    static func pngReadsBack(_ png: Data) -> Bool {
        guard !png.isEmpty, let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        return image.width > 0 && image.height > 0
    }

    /// `NSCursor.currentSystem` (deprecated, "will be nil in a future macOS": asked by selector so that day it is just
    /// nil) as PNG + geometry. Main thread.
    private static func readSystemCursor(previous: (ObjectIdentifier, SystemCursorImage)?)
        -> (value: SystemCursorImage, identity: ObjectIdentifier)? {
        let selector = NSSelectorFromString("currentSystemCursor")
        guard (NSCursor.self as AnyObject).responds(to: selector),
              let cursor = (NSCursor.self as AnyObject).perform(selector)?.takeUnretainedValue() as? NSCursor else { return nil }
        let image = cursor.image
        let identity = ObjectIdentifier(image)
        if let previous, previous.0 == identity { return (previous.1, identity) }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        var rect = CGRect(origin: .zero, size: size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let pixels = cg.dataProvider?.data as Data? else { return nil }
        var hasher = Hasher()
        hasher.combine(pixels)
        hasher.combine(cg.width)
        hasher.combine(cg.height)
        hasher.combine(Double(cursor.hotSpot.x))
        hasher.combine(Double(cursor.hotSpot.y))
        let key = hasher.finalize()
        if let previous, previous.1.key == key { return (previous.1, identity) }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        // a PNG that doesn't read back (empty, no pixels) would leave the phone without a pointer: the built-in arrow
        guard let png = bitmap.representation(using: .png, properties: [:]), pngReadsBack(png) else {
            if !loggedBadPNG {
                loggedBadPNG = true
                let reps = image.representations.map { "\(type(of: $0)) \($0.pixelsWide)x\($0.pixelsHigh)" }.joined(separator: ", ")
                log("pointer: the system cursor (\(Int(size.width))x\(Int(size.height)) pt, \(cg.width)x\(cg.height) px, reps [\(reps)]) "
                    + "didn't make a readable PNG; the built-in arrow stands in")
            }
            return nil
        }
        return (SystemCursorImage(key: key, png: png, hotX: Double(cursor.hotSpot.x), hotY: Double(cursor.hotSpot.y),
                                  width: Double(size.width), height: Double(size.height)), identity)
    }
}

/// A display stream's pointer (`cursor=client`), what `Router.videoStreamLoop` sends as cursor parts.
protocol DisplayCursorFeed: AnyObject, Sendable {
    /// The pointer now; `shape` is the image of `cursor.shapeId` (nil: none to send).
    func current() -> (cursor: ClientCursor, shape: ClientCursorShape?)
    /// Called (any thread) whenever `current()` changed.
    func observe(_ onChange: @escaping @Sendable () -> Void)
}

enum DisplayPointerGeometry {
    /// A global point on the display with `bounds`: normalized (the inverse of `Input.globalPoint`), and whether it is
    /// on that display at all.
    static func normalize(_ p: CGPoint, in bounds: CGRect) -> (x: Double, y: Double, onDisplay: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0, false) }
        let x = (p.x - bounds.minX) / bounds.width
        let y = (p.y - bounds.minY) / bounds.height
        let on = p.x >= bounds.minX && p.x < bounds.maxX && p.y >= bounds.minY && p.y < bounds.maxY
        return (min(max(x, 0), 1), min(max(y, 0), 1), on)
    }

    /// The system cursor's image as a part's shape on a display of `bounds` (points), with the stream's `id` for it.
    static func shape(_ image: SystemCursorImage, id: Int, bounds: CGRect) -> ClientCursorShape? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return ClientCursorShape(id: id, png: image.png, hotX: image.hotX / bounds.width, hotY: image.hotY / bounds.height,
                                 width: image.width / bounds.width, height: image.height / bounds.height)
    }

    /// Where an `/input` event leaves the pointer (normalized), nil when it doesn't move it (type / key, scroll without x/y).
    /// A live drag's `down` / held `move` / `up` move it too.
    static func position(after e: InputEvent) -> (x: Double, y: Double)? {
        guard let x = e.x, let y = e.y, x.isFinite, y.isFinite else { return nil }
        let clamp = { (v: Double) in min(max(v, 0), 1) }
        switch e.type {
        case "click", "doubleClick", "rightClick", "move", "scroll", "down", "up":
            return (clamp(x), clamp(y))
        case "drag":
            guard let dx = e.dx, let dy = e.dy, dx.isFinite, dy.isFinite else { return nil }
            return (clamp(x + dx), clamp(y + dy))
        default:
            return nil
        }
    }
}

/// One display's pointer for one stream: polls the probe while it runs and takes `/input`'s positions.
final class DisplayPointerTracker: DisplayCursorFeed, @unchecked Sendable {
    let display: CGDirectDisplayID
    private let bounds: @Sendable () -> CGRect
    private let probe: SystemPointerProbe
    private let pollInterval: TimeInterval
    private let shapeEvery: Int

    private let lock = NSLock()
    // Guarded by `lock`:
    private var cursor = ClientCursor(x: 0, y: 0, visible: false, shapeId: 0)
    /// The shapes this tracker made, by id (0 is the built-in arrow).
    private var shapes: [Int: ClientCursorShape] = [:]
    /// The system images seen (keys), for the log.
    private var systemKeys = Set<Int>()
    private var lastLocation: CGPoint?
    private var onChange: (@Sendable () -> Void)?
    private var timer: DispatchSourceTimer?
    private var ticks = 0

    /// `pollInterval`: the location; the shape every `shapeEvery` polls (100 ms).
    init(display: CGDirectDisplayID, bounds: (@Sendable () -> CGRect)? = nil, probe: SystemPointerProbe = SystemPointer.shared,
         pollInterval: TimeInterval = 0.05, shapeEvery: Int = 2) {
        self.display = display
        self.bounds = bounds ?? { CGDisplayBounds(display) }
        self.probe = probe
        self.pollInterval = pollInterval
        self.shapeEvery = max(1, shapeEvery)
    }

    // MARK: live trackers (for `/input`)

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: Weak] = [:]  // guarded by `registryLock`
    private struct Weak { weak var tracker: DisplayPointerTracker? }

    /// `/input` moved the pointer on `display` (an event of the type that moves it): every running tracker of that
    /// display takes the position at once.
    static func noteInput(_ e: InputEvent, display: CGDirectDisplayID) {
        guard let p = DisplayPointerGeometry.position(after: e) else { return }
        registryLock.lock()
        let trackers = live.values.compactMap(\.tracker).filter { $0.display == display }
        registryLock.unlock()
        for t in trackers { t.noteInput(x: p.x, y: p.y) }
    }

    /// Whether any tracker is running (`/input` needn't resolve displays otherwise).
    static var anyRunning: Bool {
        registryLock.lock(); defer { registryLock.unlock() }
        return live.values.contains { $0.tracker != nil }
    }

    // MARK: running

    /// Take the first sample (so the first part, before any picture, has a position and a shape) and poll until `stop`.
    func start() {
        sample(shape: true)
        Self.registryLock.lock(); Self.live[ObjectIdentifier(self)] = Weak(tracker: self); Self.registryLock.unlock()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }

    func stop() {
        Self.registryLock.lock(); Self.live[ObjectIdentifier(self)] = nil; Self.registryLock.unlock()
        lock.lock(); let t = timer; timer = nil; onChange = nil; lock.unlock()
        t?.cancel()
    }

    deinit { timer?.cancel() }

    func observe(_ onChange: @escaping @Sendable () -> Void) {
        lock.lock(); self.onChange = onChange; lock.unlock()
    }

    func current() -> (cursor: ClientCursor, shape: ClientCursorShape?) {
        lock.lock(); defer { lock.unlock() }
        return (cursor, shapes[cursor.shapeId])
    }

    /// How many shapes came from the system cursor (0: the built-in arrow all along), for the log.
    var systemShapes: Int { lock.lock(); defer { lock.unlock() }; return systemKeys.count }

    /// `/input` put the pointer at (x, y).
    func noteInput(x: Double, y: Double) {
        update { c in
            c.x = x
            c.y = y
            c.visible = true
        }
    }

    private func tick() {
        lock.lock()
        ticks += 1
        let shapeDue = ticks % shapeEvery == 0
        lock.unlock()
        sample(shape: shapeDue)
    }

    /// One poll: the location (only a change of it moves the pointer) and, when due, the shape.
    func sample(shape: Bool) {
        let b = bounds()
        let location = probe.location()
        let image = shape ? probe.cursorImage() : nil
        let arrow = shape && image == nil
            ? ClientCursorShape.builtinArrow(width: Int(b.width.rounded()), height: Int(b.height.rounded())) : nil
        update { c in
            if let location, location != lastLocation {
                lastLocation = location
                let n = DisplayPointerGeometry.normalize(location, in: b)
                // within a point of where it is (our input, read back rounded to whole points): no news
                let same = c.visible && n.onDisplay && abs(n.x - c.x) * b.width < 1.5 && abs(n.y - c.y) * b.height < 1.5
                if !same {
                    c.x = n.x
                    c.y = n.y
                    c.visible = n.onDisplay
                }
            }
            guard shape else { return }
            if let image {
                let id = SystemCursorShapeIDs.id(for: image.key)
                systemKeys.insert(image.key)
                if shapes[id] == nil {
                    if shapes.count >= ScreenCursorShapes.maxRemembered { shapes = shapes.filter { $0.key == c.shapeId } }
                    if let s = DisplayPointerGeometry.shape(image, id: id, bounds: b) { shapes[id] = s }
                }
                if shapes[id] != nil { c.shapeId = id }
            } else if let arrow {
                shapes[0] = arrow
                c.shapeId = 0
            }
        }
    }

    /// Change the cursor under the lock; tell the observer when it changed.
    private func update(_ change: (inout ClientCursor) -> Void) {
        lock.lock()
        let before = cursor
        change(&cursor)
        let changed = cursor != before
        let notify = changed ? onChange : nil
        lock.unlock()
        notify?()
    }
}

/// Ids of the system cursor's images, process-wide: an id always means the same image (a phone caches decoded shapes
/// by id across streams), never 0 (the built-in arrow) nor a small number, never reused.
enum SystemCursorShapeIDs {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ids: [Int: Int] = [:]  // guarded by `lock`
    /// Starts at a random point per process, so another run of the helper doesn't reuse an id for another image either.
    nonisolated(unsafe) private static var next = 1_000_000 + Int.random(in: 0..<1_000) * 1_000  // guarded by `lock`

    static func id(for key: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        if let id = ids[key] { return id }
        if ids.count >= 1024 { ids.removeAll() }  // (a new id for an image seen long ago is harmless)
        next += 1
        ids[key] = next
        return next
    }
}

enum ScreenCursorShapes {
    /// The phone remembers at most this many shapes (ScreenCursorState.maxShapes on iOS): a stream resends a shape
    /// it already sent once that many others came after it.
    static let maxRemembered = 32
}
#endif
