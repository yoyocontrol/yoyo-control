import CoreGraphics
import Foundation
import YoyoClipboard
import YoyoCore

// The Screen page's gestures as plain values (YoyoTrackpadView and YoyoScreenPictureView drive them, the tests check
// them): the phone is only ever a trackpad (one finger moves the pointer, relative and accelerated over the picture, at the finger's own speed;
// taps click where the pointer is), the live drag — a touch held still then moved, a tap then a moving touch, or three
// fingers — (with its drag lock and its move at the edges), which taps may click (`ScreenTapGate`), the
// two-finger scroll's phases, the gesture card's "seen" flag, the playout's switch to showing pictures at once while a
// finger is down, and the loupe that magnifies around the pointer while the fingers work.

/// A live drag: a touch held still for a moment, then moved (`ScreenHoldToDrag`, like pressing a mouse button and
/// moving), a tap then a touch that moves (`ScreenTapToDrag`, a Mac trackpad's), or three fingers that move. `down`
/// where the pointer is, then the moves. A finger that starts moving before the hold arms only moves the pointer.
///
/// Lifting the fingers mid-drag doesn't let go at once (a Mac trackpad's drag lock, without the lock that lasts until
/// the next tap): the button stays down for `lockWindow`. The same kind of touch (one finger / three) that comes back
/// within it and moves carries on with the same drag — more held moves, no new `down`; anything else lets go first: a
/// tap (`up` where the pointer is; that tap clicks nothing), the other kind of move, a two-finger scroll (`up`, then
/// they do what they do); no touch at all lets go when the window runs out. Fingers resting on the glass hold the window open until they move or lift.
/// Interrupted (the gesture cancelled, the page went away): `up` where the pointer was. Times are the caller's clock
/// (seconds), so this stays a plain value.
struct ScreenDrag: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// `down` sent; the pointer is at `at`.
        case dragging(at: CGPoint)
        /// `down` sent, the fingers lifted: the button stays down with the pointer at `at` until `until` (nil: fingers
        /// touched again within the window and are resting on the glass, so it doesn't run out).
        case locked(at: CGPoint, until: TimeInterval?)
    }

    enum Step: Equatable, Sendable {
        case down(CGPoint)
        case move(CGPoint)
        case up(CGPoint)
    }

    /// How long (seconds) the button stays down after the fingers lift mid-drag, waiting for them to come back.
    static let lockWindow: TimeInterval = 0.8

    private(set) var phase = Phase.idle

    /// The button is down (the pointer looks pressed).
    var isPressed: Bool { phase != .idle }
    /// A drag with fingers moving it now.
    var isDragging: Bool { if case .dragging = phase { true } else { false } }
    /// A drag waiting for its fingers to come back.
    var isLocked: Bool { if case .locked = phase { true } else { false } }
    /// When a lock runs out (nil: not locked, or held open by resting fingers).
    var lockedUntil: TimeInterval? { if case let .locked(_, until) = phase { until } else { nil } }

    /// The drag's touch began to move with the pointer at `point`: `down` there. A drag waiting in its lock carries on
    /// instead, from where its pointer is (nothing sent).
    mutating func began(at point: CGPoint) -> [Step] {
        if case let .locked(at, _) = phase {
            phase = .dragging(at: at)
            return []
        }
        let lifted = cancelled()
        phase = .dragging(at: point)
        return lifted + [.down(point)]
    }

    /// The fingers moved the pointer to `point`.
    mutating func moved(to point: CGPoint) -> [Step] {
        guard isDragging else { return [] }
        phase = .dragging(at: point)
        return [.move(point)]
    }

    /// The fingers lifted at `now` with the pointer at `point`: the drag locks (nothing sent: the button stays down
    /// for `lockWindow`).
    mutating func ended(at point: CGPoint, now: TimeInterval) -> [Step] {
        guard isDragging else { return [] }
        phase = .locked(at: point, until: now + Self.lockWindow)
        return []
    }

    /// A finger came down at `now`. On a lock still open it holds the lock until the fingers move (`began`) or lift
    /// (`released`); on one that ran out (its timer is late) it lets go.
    mutating func touched(at now: TimeInterval) -> [Step] {
        guard case let .locked(at, until) = phase else { return [] }
        if let until, now >= until {
            phase = .idle
            return [.up(at)]
        }
        phase = .locked(at: at, until: nil)
        return []
    }

    /// Something other than three moving fingers came of the touch on a lock (a tap, one finger moving, a two-finger
    /// scroll): it lets go where the pointer is.
    mutating func released() -> [Step] {
        guard case let .locked(at, _) = phase else { return [] }
        phase = .idle
        return [.up(at)]
    }

    /// The clock reads `now`: a lock that ran out with no finger on the glass lets go.
    mutating func expire(at now: TimeInterval) -> [Step] {
        guard case let .locked(at, until?) = phase, now >= until else { return [] }
        phase = .idle
        return [.up(at)]
    }

    /// Interrupted: a pressed button is lifted where the pointer was.
    mutating func cancelled() -> [Step] {
        defer { phase = .idle }
        switch phase {
        case let .dragging(at), let .locked(at, _): return [.up(at)]
        case .idle: return []
        }
    }
}

/// A tap, then a touch within `window` of it and near where the tap was: armed while that touch is down, and if it
/// moves (the one-finger pan begins) it drags (`take`) — a Mac trackpad's "tap to drag". The tap before it clicks
/// nothing then. A second finger disarms it.
struct ScreenTapToDrag: Equatable, Sendable {
    /// The longest from the tap's lift to the next touch (seconds): a double tap's tempo. A finger coming back later to
    /// move the pointer on after a click only moves it.
    static let window: TimeInterval = 0.3
    /// How far (points) from the tap the touch may land: about a double tap's reach. A finger put down elsewhere to
    /// move the pointer on after a click only moves it.
    static let reach: CGFloat = 44

    private var tapUp: TimeInterval?
    private var tapAt: CGPoint?
    /// The touch now down came right after a tap.
    private(set) var armed = false

    /// A one-finger tap lifted at `time`, at `location` (nil: unknown, anywhere counts).
    mutating func tapped(at time: TimeInterval, location: CGPoint? = nil) {
        tapUp = time
        tapAt = location
    }

    /// The first finger came down at `time`, at `location`.
    mutating func touched(at time: TimeInterval, location: CGPoint? = nil) {
        var near = true
        if let tapAt, let location { near = hypot(location.x - tapAt.x, location.y - tapAt.y) <= Self.reach }
        armed = near && (tapUp.map { time >= $0 && time - $0 <= Self.window } ?? false)
        tapUp = nil
        tapAt = nil
    }

    /// The touch moves (one finger): true = it drags (once).
    mutating func take() -> Bool {
        defer { armed = false }
        return armed
    }

    /// Another finger came down, or three fingers drag.
    mutating func disarm() { armed = false }

    /// The last finger lifted.
    mutating func lifted() { armed = false }
}

/// One finger down and come to rest for `delay`: armed (the page buzzes and tints the loupe); if it then moves (the
/// one-finger pan begins) it drags (`take`) with the button down, like pressing a mouse button and moving. Resting
/// means two things: the finger never rolled more than `stillness` from where it landed, and it has kept within
/// `restRadius` of one spot for the last `restTime` (a finger creeping slowly — the start of a fine pointer move —
/// never comes to rest, however short its way). A finger that moves more than `stillness` first, or a second finger,
/// disarms it for this touch; lifting an armed finger without moving does nothing (it was no tap:
/// `ScreenTapSpotter.maxDuration` is the same delay).
struct ScreenHoldToDrag: Equatable, Sendable {
    /// How long the finger rests before the drag arms (seconds): iOS's own long press.
    static let delay: TimeInterval = 0.5
    /// How far (points) the finger may roll from where it landed and still count as still: under a pan's start, so a
    /// slow pointer move never arms a drag.
    static let stillness: CGFloat = 6
    /// A finger at rest keeps within this many points of one spot (a resting fingertip wobbles about a point)...
    static let restRadius: CGFloat = 1.5
    /// ...for at least this long (seconds) before the hold arms.
    static let restTime: TimeInterval = 0.25

    /// When the finger that may arm it came down (nil: none in this touch).
    private(set) var downAt: TimeInterval?
    private(set) var armed = false
    /// Where it rests (from where it landed) and since when.
    private var rest = CGPoint.zero
    private var restSince: TimeInterval = 0

    /// The first finger came down at `time`.
    mutating func touched(at time: TimeInterval) {
        downAt = time
        armed = false
        rest = .zero
        restSince = time
    }

    /// The finger is `offset` points from where it landed at `time` (before the hold arms: too far = no hold this
    /// touch; off its resting spot = the rest starts again).
    mutating func moved(_ offset: CGPoint, at time: TimeInterval) {
        guard !armed, downAt != nil else { return }
        guard hypot(offset.x, offset.y) <= Self.stillness else { downAt = nil; return }
        if !(hypot(offset.x - rest.x, offset.y - rest.y) <= Self.restRadius) {
            rest = offset
            restSince = time
        }
    }

    /// When it may arm, if the finger stays where it is (nil: not in this touch, or armed already).
    var due: TimeInterval? {
        guard !armed, let downAt else { return nil }
        return max(downAt + Self.delay, restSince + Self.restTime)
    }

    /// The clock reads `now`: true = it arms now (once).
    mutating func check(at now: TimeInterval) -> Bool {
        guard let due, now >= due else { return false }
        armed = true
        return true
    }

    /// The finger moves (the pan began): true = it drags (once). Moving before the hold armed ends its chance.
    mutating func take() -> Bool {
        defer { downAt = nil; armed = false }
        return armed
    }

    /// Another finger came down, the pointer started moving, the last finger lifted, or a drag is already held.
    mutating func cancel() {
        downAt = nil
        armed = false
    }
}

/// Which tap recognizer answers become clicks. The one-finger pan neither prevents nor is prevented by the tap
/// recognizers (`ScreenTrackpadPan`: otherwise a pan that failed in a tap isn't reset while the double tap still waits
/// for its second tap, and the touch right after a tap can neither move the pointer nor drag), so a tap recognizer may
/// also answer for a touch that moved. Its answer counts only for touches the spotter saw as taps (`ScreenTapSpotter`):
/// a single tap for the newest tap not yet clicked (the tap before a touch that moves is still a click), a double tap
/// only when the last two touches were both taps, each tap clicked once. Times are the caller's clock (seconds).
struct ScreenTapGate: Equatable, Sendable {
    /// An answer this long after its tap is stale (the recognizers decide in about 0.35 s).
    static let maxAge: TimeInterval = 1

    private struct Touch: Equatable, Sendable {
        /// Fingers of a tap; nil: the touch was no tap (it moved, was held, the system took it).
        var tap: Int?
        var at: TimeInterval
        var used = false
    }

    /// The last few touches, oldest first.
    private var touches: [Touch] = []

    /// A touch that was a tap of `fingers` fingers lifted at `time`.
    mutating func tapped(fingers: Int, at time: TimeInterval) { append(Touch(tap: fingers, at: time)) }

    /// A touch that was no tap ended at `time` (or a tap that clicks nothing: a drag took it, it put the keyboard away).
    mutating func other(at time: TimeInterval) { append(Touch(tap: nil, at: time)) }

    /// A single tap recognizer (`fingers` fingers) answered at `now`: true = it clicks.
    mutating func single(fingers: Int, at now: TimeInterval) -> Bool {
        guard let i = touches.lastIndex(where: { $0.tap != nil && !$0.used }),
              touches[i].tap == fingers, now - touches[i].at <= Self.maxAge else { return false }
        touches[i].used = true
        return true
    }

    /// The double tap recognizer answered at `now`: true = it double-clicks.
    mutating func double(at now: TimeInterval) -> Bool {
        let n = touches.count
        guard n >= 2 else { return false }
        let a = touches[n - 2], b = touches[n - 1]
        guard a.tap == 1, b.tap == 1, !a.used, !b.used, now - b.at <= Self.maxAge else { return false }
        touches[n - 2].used = true
        touches[n - 1].used = true
        return true
    }

    /// Nothing waiting clicks any more (a drag began from the tap before it).
    mutating func drop() {
        for i in touches.indices { touches[i].used = true }
    }

    private mutating func append(_ t: Touch) {
        touches.append(t)
        if touches.count > 3 { touches.removeFirst(touches.count - 3) }
    }
}

/// The trackpad's pointer: relative moves, accelerated like a Mac's trackpad (slow = fine, fast = far), kept on the
/// display. The acceleration is relative to the picture, not to the Mac's points: at a normal speed the pointer covers
/// as much of the picture as the finger covers of the phone, so a full-width swipe crosses the whole display however
/// small the picture is drawn (a 1728-pt display drawn 870 pt wide in landscape, 440 pt wide in portrait).
enum ScreenTrackpad {
    /// The curve's speeds (phone points per second): flat at `preciseGain` below `preciseSpeed` (fine work, such as
    /// placing the pointer between two letters), exactly 1 at `normalSpeed` (the pointer tracks the finger on the
    /// picture), `fastGain` at `fastSpeed` and flat above (a flick crosses the display in a fraction of the swipe).
    static let preciseSpeed: CGFloat = 25
    static let normalSpeed: CGFloat = 150
    static let fastSpeed: CGFloat = 1400
    /// The curve's values there (dimensionless: picture points per phone point).
    static let preciseGain: CGFloat = 0.55
    static let fastGain: CGFloat = 2.6

    /// The rise is a smoothstep over the log of the speed (from `preciseSpeed` to `fastSpeed`), raised to this power so
    /// that it passes through 1 at `normalSpeed` (about 1.74 with the constants above): smooth, flat at both ends.
    static let risePower: CGFloat = {
        let s = smoothstep(logPosition(normalSpeed))
        return log((1 - preciseGain) / (fastGain - preciseGain)) / log(s)
    }()

    /// How fast the pointer goes over the picture for each phone point the finger moves, at the finger's `speed`
    /// (phone points per second). Continuous and never falling with the speed; unknown or negative speeds count as
    /// still.
    static func curve(speed: CGFloat) -> CGFloat {
        guard speed.isFinite, speed > preciseSpeed else { return preciseGain }
        guard speed < fastSpeed else { return fastGain }
        let rise = pow(smoothstep(logPosition(speed)), risePower)
        return preciseGain + (fastGain - preciseGain) * rise
    }

    /// Display points per point on the phone the picture is drawn at: the display's width over the picture's (the
    /// picture keeps the display's aspect, so one factor serves both axes). 1 when either is unknown.
    static func pictureFactor(display: CGSize, picture: CGSize) -> CGFloat {
        guard display.width.isFinite, picture.width.isFinite, display.width > 0, picture.width > 0 else { return 1 }
        return display.width / picture.width
    }

    /// Display points per phone point at the finger's `speed`, for a `display` drawn as `picture` (phone points),
    /// times `scale` (`Preferences.screenTrackpadGain`; nonsense counts as 1).
    static func gain(speed: CGFloat, display: CGSize, picture: CGSize, scale: CGFloat = 1) -> CGFloat {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        return curve(speed: speed) * pictureFactor(display: display, picture: picture) * scale
    }

    /// The pointer at `p` (0…1) moved by the finger's `finger` (points on the phone) on a display of `display` points.
    static func moved(_ p: CGPoint, by finger: CGVector, display: CGSize, gain: CGFloat) -> CGPoint {
        guard display.width > 0, display.height > 0, gain.isFinite else { return clamp(p) }
        return clamp(CGPoint(x: p.x + finger.dx * gain / display.width, y: p.y + finger.dy * gain / display.height))
    }

    static func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x.isFinite ? p.x : 0.5, 0), 1), y: min(max(p.y.isFinite ? p.y : 0.5, 0), 1))
    }

    /// Where `speed` lies between `preciseSpeed` and `fastSpeed` on a log scale, 0…1.
    private static func logPosition(_ speed: CGFloat) -> CGFloat {
        min(max(log(speed / preciseSpeed) / log(fastSpeed / preciseSpeed), 0), 1)
    }

    private static func smoothstep(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
}

/// The finger's speed (phone points per second) from its own touches (`ScreenTouchObserver`, coalesced: every sample
/// the screen took, not just one per frame): the path it travelled over the last `window` divided by the time. Faster
/// to follow than a pan recognizer's velocity. A finger that stopped
/// sends no samples; its next one, after the pause, counts the pause (it starts slow).
struct ScreenFingerSpeed: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        var time: TimeInterval
        var location: CGPoint
    }

    /// How far back the speed looks (seconds).
    static let window: TimeInterval = 0.04
    /// The shortest time the path is divided by (a first move right after the finger landed is not a flick).
    static let minSpan: TimeInterval = 0.012

    /// Newest last: the samples within `window` of the newest, and the one just before them.
    private(set) var samples: [Sample] = []
    /// The finger's speed as of the newest sample.
    private(set) var speed: CGFloat = 0

    /// Where the finger was last (nil: no sample since the reset).
    var location: CGPoint? { samples.last?.location }

    /// A finger came down at `location` (or another one did: the samples so far are someone else's).
    mutating func reset(at location: CGPoint? = nil, time: TimeInterval = 0) {
        samples = location.map { [Sample(time: time, location: $0)] } ?? []
        speed = 0
    }

    /// The finger was at `location` at `time` (samples in order; an older one is ignored).
    mutating func add(_ location: CGPoint, at time: TimeInterval) {
        guard location.x.isFinite, location.y.isFinite, time.isFinite else { return }
        if let last = samples.last, time < last.time { return }
        samples.append(Sample(time: time, location: location))
        let start = time - Self.window
        // keep one sample at or before the window's start (the path's first piece is cut at the start)
        if let firstInside = samples.firstIndex(where: { $0.time > start }), firstInside > 1 {
            samples.removeFirst(firstInside - 1)
        }
        speed = Self.speed(samples, window: Self.window)
    }

    /// The path over the last `window` of `samples` divided by the time it covers.
    static func speed(_ samples: [Sample], window: TimeInterval) -> CGFloat {
        guard let newest = samples.last, samples.count > 1 else { return 0 }
        let start = newest.time - window
        var path: CGFloat = 0
        var from = newest.time
        for (a, b) in zip(samples, samples.dropFirst()) where b.time > start {
            let piece = hypot(b.location.x - a.location.x, b.location.y - a.location.y)
            let dt = b.time - a.time
            if a.time < start, dt > 0 {
                // only the part inside the window, at the piece's own pace
                path += piece * CGFloat((b.time - start) / dt)
                from = start
            } else {
                path += piece
                from = min(from, a.time)
            }
        }
        let span = max(newest.time - from, minSpan)
        let v = path / CGFloat(span)
        return v.isFinite ? v : 0
    }
}

/// Takes the tremor out of a slow finger before it moves the pointer (a "1€ filter": a low-pass whose cutoff rises
/// with the finger's speed). A finger doing fine work wobbles by a point or so as its contact patch rolls, and the
/// trackpad's gain (about 2 display points per phone point in portrait) turns that into a pointer shaking between two
/// letters; slow, the cutoff is low and the wobble is gone at the cost of a lag under a point. Fast, the cutoff is
/// high and the lag stays under `maxLag` points however fast the finger goes.
struct ScreenFingerSmoother: Equatable, Sendable {
    /// The cutoff (Hz) of a finger at rest.
    static let restCutoff: Double = 3
    /// How much the cutoff rises (Hz) for each phone point per second of the finger's speed.
    static let cutoffPerSpeed: Double = 0.06
    /// The most the smoothed finger trails the real one (phone points), at any speed.
    static var maxLag: CGFloat { CGFloat(1 / (2 * Double.pi * cutoffPerSpeed)) }

    /// The smoothed finger (nil: nothing since the reset).
    private(set) var location: CGPoint?
    private var time: TimeInterval = 0

    /// The finger starts afresh at `location` (no smoothing across it).
    mutating func reset(at location: CGPoint?, time: TimeInterval) {
        self.location = location
        self.time = time
    }

    /// The finger was at `p` at `time`, moving at `speed` (phone points per second): where the smoothed finger is now.
    /// A sample from before the last one, or at the same time, leaves it where it is.
    mutating func add(_ p: CGPoint, at time: TimeInterval, speed: CGFloat) -> CGPoint {
        guard p.x.isFinite, p.y.isFinite, time.isFinite else { return location ?? .zero }
        guard let last = location else {
            reset(at: p, time: time)
            return p
        }
        let dt = time - self.time
        guard dt > 0 else { return last }
        let v = speed.isFinite ? max(Double(speed), 0) : 0
        let tau = 1 / (2 * Double.pi * (Self.restCutoff + Self.cutoffPerSpeed * v))
        let a = CGFloat(dt / (dt + tau))
        let next = CGPoint(x: last.x + a * (p.x - last.x), y: last.y + a * (p.y - last.y))
        reset(at: next, time: time)
        return next
    }
}

/// While dragging, a finger resting near the edge of the trackpad (its panel) keeps the pointer moving
/// that way, faster the closer it is to the edge: so a selection can go on past what one swipe covers (a Mac app
/// scrolls by itself when a selection's drag reaches its window's edge).
enum ScreenEdgeMove {
    /// How deep (points) the band along each edge is.
    static let band: CGFloat = 36
    /// The speed at the very edge, in picture widths per second (the same on both axes).
    static let maxRate: CGFloat = 1.2

    /// The pointer's velocity (phone points per second over the picture; the caller turns it into display points with
    /// `ScreenTrackpad.pictureFactor`) for a finger at `finger` in `bounds`, with the picture `pictureWidth` points
    /// wide. Each axis on its own: zero outside the band, rising with the depth into it to `maxRate` at the edge.
    static func velocity(finger: CGPoint, bounds: CGRect, pictureWidth: CGFloat) -> CGVector {
        guard finger.x.isFinite, finger.y.isFinite, pictureWidth.isFinite, pictureWidth > 0,
              bounds.width > 2 * band, bounds.height > 2 * band else { return .zero }
        let top = maxRate * pictureWidth
        func axis(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            if v < lo + band { return -top * depth(v - lo) }
            if v > hi - band { return top * depth(hi - v) }
            return 0
        }
        return CGVector(dx: axis(finger.x, bounds.minX, bounds.maxX), dy: axis(finger.y, bounds.minY, bounds.maxY))
    }

    /// 0 at the band's inner side, 1 at the edge (and beyond it).
    private static func depth(_ distance: CGFloat) -> CGFloat {
        min(max((band - distance) / band, 0), 1)
    }
}

/// The loupe over the pointer (`YoyoTrackpadView` on the picture, drawn as a liquid drop: `ScreenDrop`): how big, how much it
/// magnifies, how it moves.
enum ScreenLoupe {
    /// The size the loupe aims for: this many phone points per display point (a 1728-pt display on a 440-pt-wide
    /// phone: about 1.8×).
    static let targetScale: CGFloat = 0.45
    static let minMagnification: CGFloat = 1.6
    static let maxMagnification: CGFloat = 4
    /// Following the pointer: stiff, a touch of overshoot (it keeps up with the finger and still feels elastic).
    static let follow = ScreenSpring.Parameters(response: 0.11, dampingRatio: 0.72)
    /// Popping in on a touch: quick, springy.
    static let appear = ScreenSpring.Parameters(response: 0.30, dampingRatio: 0.58)
    /// Collapsing when the last finger lifts: quick, no bounce.
    static let disappear = ScreenSpring.Parameters(response: 0.20, dampingRatio: 1)

    /// How much it magnifies a picture drawn at `pictureScale` phone points per display point (1: none needed).
    static func magnification(pictureScale: CGFloat) -> CGFloat {
        guard pictureScale.isFinite, pictureScale > 0 else { return minMagnification }
        return min(max(targetScale / pictureScale, minMagnification), maxMagnification)
    }

    /// Its diameter (points) over a picture of `picture` points: half the picture's short side, 100…150 (the drop is
    /// `ScreenDrop.sizeScale` of it in radius).
    static func diameter(picture: CGSize) -> CGFloat {
        min(max(min(picture.width, picture.height) * 0.5, 100), 150)
    }
}

/// A damped spring toward a target, stepped by the frame (the loupe's position and its presence): Apple's
/// response / damping-ratio parameters, unit mass. Retargets keep the velocity, so a move or a new touch never jumps.
struct ScreenSpring: Equatable, Sendable {
    struct Parameters: Equatable, Sendable {
        /// Seconds for one undamped oscillation.
        var response: Double
        /// 1 = no overshoot, below 1 = bouncier.
        var dampingRatio: Double
        var stiffness: Double { pow(2 * .pi / max(response, 0.01), 2) }
        var damping: Double { 4 * .pi * dampingRatio / max(response, 0.01) }
    }

    var value: Double
    var velocity: Double = 0
    var target: Double

    init(_ value: Double) {
        self.value = value
        target = value
    }

    /// At rest on its target (within `epsilon`, nearly still).
    func settled(epsilon: Double = 0.001) -> Bool {
        abs(target - value) < epsilon && abs(velocity) < epsilon * 10
    }

    /// Advances `dt` seconds (in sub-steps of at most 1/480 s, so a slow frame stays stable).
    mutating func step(_ dt: Double, _ p: Parameters) {
        guard dt > 0, dt.isFinite else { return }
        let k = p.stiffness, c = p.damping
        let n = max(1, Int((dt * 480).rounded(.up)))
        let h = dt / Double(n)
        for _ in 0..<n {
            velocity += (k * (target - value) - c * velocity) * h
            value += velocity * h
        }
    }
}

/// One step of a two-finger scroll (`YoyoTrackpadView`). `delta`: fractions of the picture's width / height
/// (positive = see content further right / down: the content moves with the fingers); `velocity`, on `ended`: the
/// fingers' at lift, in fractions per second, same signs (the Mac scrolls on with it: momentum).
struct ScreenScrollStep: Equatable, Sendable {
    var delta: CGVector
    var phase: ScreenInput.ScrollPhase
    var velocity: CGVector = .zero
}

/// A two-finger pan as scroll steps, from the pan recognizer's translation (view points, cumulative) over a picture of
/// `size`: `began` carries the movement the recognizer needed to start, `changed` the moves since, `ended` the velocity
/// at lift (zero when cancelled). While not `reporting` (not controlling) the translation is followed but nothing is
/// reported; a move reported first after that begins the gesture, and only a gesture that began ends.
struct ScreenTwoFingerScroll: Equatable, Sendable {
    /// The axis a gesture keeps to (UIScrollView's directional lock): decided once the fingers have travelled
    /// `lockDistance`; one axis when its travel is at least `lockRatio` times the other's, else both (a diagonal).
    /// Nothing is reported before that (like UIScrollView, which doesn't move before it decides): the travel so far
    /// goes as the gesture's `began`, on the axis decided, so a vertical scroll never nudges sideways first.
    enum Axis: Equatable, Sendable { case vertical, horizontal, both }

    static let lockDistance: CGFloat = 8
    static let lockRatio: CGFloat = 2
    /// The velocity at lift is kept under this (display points per second): a hard flick on a small picture would
    /// otherwise send the Mac's momentum several screens away.
    static let maxLiftSpeed: CGFloat = 6000

    private var last = CGPoint.zero
    /// A gesture was reported as begun (an `ended` is owed).
    private(set) var active = false
    /// nil: not decided yet (the fingers haven't travelled `lockDistance`).
    private(set) var axis: Axis?

    mutating func began(translation t: CGPoint, size: CGSize, reporting: Bool) -> ScreenScrollStep? {
        last = .zero
        active = false
        axis = nil
        return changed(translation: t, size: size, reporting: reporting)
    }

    mutating func changed(translation t: CGPoint, size: CGSize, reporting: Bool) -> ScreenScrollStep? {
        if axis == nil, hypot(t.x, t.y) >= Self.lockDistance { axis = Self.axis(for: t) }
        // not decided yet: the travel waits (`last` stays put), then goes as one step on the axis
        guard axis != nil else { return nil }
        let step = Self.locked(CGVector(dx: t.x - last.x, dy: t.y - last.y), to: axis)
        last = t
        guard reporting, size.width > 0, size.height > 0 else { return nil }
        // fingers moving up = content moving up = see further down (a trackpad's natural scrolling)
        let delta = CGVector(dx: -step.dx / size.width, dy: -step.dy / size.height)
        defer { active = true }
        return ScreenScrollStep(delta: delta, phase: active ? .changed : .began)
    }

    /// The fingers lifted (`velocity` in view points per second) or the gesture was cancelled (nil).
    mutating func ended(velocity v: CGPoint?, size: CGSize) -> ScreenScrollStep? {
        defer { active = false; last = .zero; axis = nil }
        guard active else { return nil }
        guard let v, size.width > 0, size.height > 0, v.x.isFinite, v.y.isFinite else {
            return ScreenScrollStep(delta: .zero, phase: .ended)
        }
        let locked = Self.locked(CGVector(dx: v.x, dy: v.y), to: axis)
        return ScreenScrollStep(delta: .zero, phase: .ended, velocity: CGVector(dx: -locked.dx / size.width, dy: -locked.dy / size.height))
    }

    /// The axis a travel of `t` keeps to.
    static func axis(for t: CGPoint) -> Axis {
        let ax = abs(t.x), ay = abs(t.y)
        if ay >= lockRatio * ax { return .vertical }
        if ax >= lockRatio * ay { return .horizontal }
        return .both
    }

    /// `v` with the other axis dropped (nil / `both`: as it is).
    static func locked(_ v: CGVector, to axis: Axis?) -> CGVector {
        switch axis {
        case .vertical?: CGVector(dx: 0, dy: v.dy)
        case .horizontal?: CGVector(dx: v.dx, dy: 0)
        case .both?, nil: v
        }
    }

    /// A velocity at lift (display points per second) kept under `maxLiftSpeed`, its direction unchanged.
    static func capped(_ v: CGVector) -> CGVector {
        guard v.dx.isFinite, v.dy.isFinite else { return .zero }
        let speed = hypot(v.dx, v.dy)
        guard speed > maxLiftSpeed else { return v }
        let k = maxLiftSpeed / speed
        return CGVector(dx: v.dx * k, dy: v.dy * k)
    }
}

/// Tells a tap from the touches alone, the moment the last finger lifts (`ScreenTouchObserver`): quick, still, and how
/// many fingers were down at most. The tap recognizers answer later (a single tap waits to see whether a second one
/// follows); this lets the click's feedback show at once.
struct ScreenTapSpotter: Equatable, Sendable {
    /// Down at most this long: a longer hold arms a drag (`ScreenHoldToDrag.delay`), it doesn't click.
    static let maxDuration: TimeInterval = ScreenHoldToDrag.delay
    /// No finger moves farther than this (points).
    static let slop: CGFloat = 10

    private var start: TimeInterval?
    private var fingers = 0
    private var spoiled = false

    /// `count` fingers are down now (the first one at `time` starts a sequence).
    mutating func down(fingers count: Int, at time: TimeInterval) {
        if start == nil { start = time; spoiled = false; fingers = 0 }
        fingers = max(fingers, count)
    }

    /// A finger is `distance` points from where it came down.
    mutating func moved(_ distance: CGFloat) {
        if !(distance <= Self.slop) { spoiled = true }
    }

    /// The system took the touches.
    mutating func cancel() { spoiled = true }

    /// The last finger lifted at `time`: the tap's finger count, or nil when it wasn't one.
    mutating func allUp(at time: TimeInterval) -> Int? {
        defer { start = nil; fingers = 0; spoiled = false }
        guard let start, !spoiled, time - start <= Self.maxDuration, fingers > 0 else { return nil }
        return fingers
    }
}

/// The gesture card shows once: the first time the page takes control (`Preferences.screenGestureCardSeen`).
struct ScreenGestureHints: Equatable, Sendable {
    var seen: Bool

    /// Whether to show the card now; it counts as seen from here on.
    mutating func take() -> Bool {
        guard !seen else { return false }
        seen = true
        return true
    }
}

/// A finger on the picture while controlling (a tap, a drag on the trackpad, a scroll, a pinch: from the first finger
/// down, before any gesture is recognized), or a key / text sent to the Mac: smooth playback is interactive (the
/// interactive depth, `ScreenPlayer.setInteractive`), and goes back to smooth `linger` after the last finger lifts or
/// the last key (the buffer ramps up from what it measured meanwhile). A finger down keeps it on whatever the keys do.
/// 600 ms covers the Mac's answer to the last input (a round trip and an encode, ~250 ms on 5G) with room for a
/// second tap or key; longer would keep showing a calm screen without its smoothing.
struct ScreenInteractivity: Equatable, Sendable {
    static let linger: Duration = .milliseconds(600)

    private(set) var touching = false
    /// When it goes back to smooth (nil: not lingering).
    private(set) var until: ContinuousClock.Instant?

    var interactive: Bool { touching || until != nil }

    /// A finger came down; true = it just became interactive.
    mutating func began() -> Bool {
        let was = interactive
        touching = true
        until = nil
        return !was
    }

    /// The last finger lifted at `now`: the time it goes back (nil: it wasn't interactive).
    mutating func ended(at now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard touching else { return until }
        touching = false
        until = now + Self.linger
        return until
    }

    /// A key or text went to the Mac at `now`: interactive until `linger` from now (with a finger down, until it lifts
    /// and lingers). `became`: it just became interactive; `until`: when it goes back (nil: a finger is down).
    mutating func key(at now: ContinuousClock.Instant) -> (became: Bool, until: ContinuousClock.Instant?) {
        let was = interactive
        guard !touching else { return (false, nil) }
        until = now + Self.linger
        return (!was, until)
    }

    /// True = it just went back to smooth (the linger is over and no finger came down meanwhile).
    mutating func expire(at now: ContinuousClock.Instant) -> Bool {
        guard !touching, let until, now >= until else { return false }
        self.until = nil
        return true
    }

    /// Off at once (control lost, the page stops); true = it was on.
    mutating func reset() -> Bool {
        let was = interactive
        touching = false
        until = nil
        return was
    }
}

/// One row of the gesture card.
struct ScreenGestureRow: Equatable, Sendable {
    var symbol: String
    var gesture: String
    var action: String

    /// The card's rows.
    static var rows: [ScreenGestureRow] {
        [ScreenGestureRow(symbol: "cursorarrow.motionlines", gesture: L("Drag with one finger"), action: L("Move the pointer")),
         ScreenGestureRow(symbol: "hand.tap", gesture: L("Tap"), action: L("Click")),
         ScreenGestureRow(symbol: "hand.tap.fill", gesture: L("Double tap"), action: L("Double-click")),
         ScreenGestureRow(symbol: "cursorarrow.click.2", gesture: L("Tap with two fingers"), action: L("Right-click")),
         ScreenGestureRow(symbol: "character.cursor.ibeam", gesture: L("Touch and hold, then drag — or tap, then touch and drag"),
                          action: L("Select or drag")),
         ScreenGestureRow(symbol: "hand.draw", gesture: L("Drag with three fingers"),
                          action: L("Drag — lift and touch again to keep going")),
         ScreenGestureRow(symbol: "arrow.up.arrow.down", gesture: L("Drag with two fingers"), action: L("Scroll"))]
    }

    /// The card's clipboard section: the two verbs (the clipboard button, the keys above the keyboard, the hints on the
    /// picture all use them).
    static func clipboardRows(_ host: YoyoComputer = .mac) -> [ScreenGestureRow] {
        [ScreenGestureRow(symbol: "arrow.right.doc.on.clipboard", gesture: host.pasteLabel, action: host.pasteExplained),
         ScreenGestureRow(symbol: "arrow.up.doc.on.clipboard", gesture: host.copyLabel, action: host.copyExplained)]
    }
}

/// The Screen page's picture zoom: `scale` (1 = fitted) and the display's point (normalized) in the middle of what
/// shows. Zoomed in, the picture always covers its frame (`clampCenter`); below 1 (a pinch's rubber band) it is
/// centered.
struct ScreenZoom: Equatable, Sendable {
    var scale: CGFloat = 1
    var center = CGPoint(x: 0.5, y: 0.5)

    static let maxScale: CGFloat = 5
    /// A double tap on the fitted picture zooms in this far.
    static let doubleTapScale: CGFloat = 2.5
    /// A pinch let go below this is fitted.
    static let snapToFit: CGFloat = 1.05
    /// How close the pointer may come to the edge of what shows (a fraction of it) before the shown part follows.
    static let followMargin: CGFloat = 0.18
    /// Past the limits a pinch moves the scale this much of the way (a rubber band).
    static let rubber: CGFloat = 0.3

    var zoomed: Bool { scale > 1.001 }

    /// `s` within 1…`maxScale`; `rubber`: past them it gives way slowly instead (while the fingers are down).
    static func clampedScale(_ s: CGFloat, rubber: Bool) -> CGFloat {
        guard s.isFinite, s > 0 else { return 1 }
        guard rubber else { return min(max(s, 1), maxScale) }
        if s < 1 { return max(1 - (1 - s) * Self.rubber, 0.5) }
        if s > maxScale { return maxScale + (s - maxScale) * Self.rubber }
        return s
    }

    /// The picture's frame in a frame of `size` (the fitted picture's).
    func frame(in size: CGSize) -> CGRect {
        let w = size.width * scale, h = size.height * scale
        guard scale > 1 else { return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h) }
        func origin(_ length: CGFloat, _ zoomed: CGFloat, _ c: CGFloat) -> CGFloat {
            min(max(length / 2 - c * zoomed, length - zoomed), 0)
        }
        return CGRect(x: origin(size.width, w, center.x), y: origin(size.height, h, center.y), width: w, height: h)
    }

    /// The display's point (normalized, 0…1) at `p` in a frame of `size`.
    func point(at p: CGPoint, in size: CGSize) -> CGPoint {
        let f = frame(in: size)
        guard f.width > 0, f.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max((p.x - f.minX) / f.width, 0), 1), y: min(max((p.y - f.minY) / f.height, 0), 1))
    }

    /// Moves what shows so the display's point `anchor` is at `p` in a frame of `size` (as far as the edges let it).
    mutating func place(_ anchor: CGPoint, at p: CGPoint, in size: CGSize) {
        let w = size.width * scale, h = size.height * scale
        guard w > 0, h > 0 else { return }
        center = CGPoint(x: (size.width / 2 - (p.x - anchor.x * w)) / w, y: (size.height / 2 - (p.y - anchor.y * h)) / h)
        clampCenter()
    }

    /// Keeps the picture covering its frame (fitted or less: centered).
    mutating func clampCenter() {
        guard scale > 1 else { center = CGPoint(x: 0.5, y: 0.5); return }
        let half = 0.5 / scale
        center = CGPoint(x: min(max(center.x, half), 1 - half), y: min(max(center.y, half), 1 - half))
    }

    /// Moves what shows just enough to keep the pointer `p` (normalized) `followMargin` clear of its edges.
    mutating func follow(_ p: CGPoint) {
        guard zoomed, p.x.isFinite, p.y.isFinite else { return }
        let half = 0.5 / scale
        let margin = Self.followMargin / scale
        func axis(_ c: CGFloat, _ v: CGFloat) -> CGFloat {
            let lo = c - half + margin, hi = c + half - margin
            if v < lo { return c - (lo - v) }
            if v > hi { return c + (v - hi) }
            return c
        }
        center = CGPoint(x: axis(center.x, p.x), y: axis(center.y, p.y))
        clampCenter()
    }
}
