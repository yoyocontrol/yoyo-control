import CoreGraphics
import CoreVideo
import Foundation
import Metal
import simd
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The Screen page's gestures as values: the three-finger drag and its lock, the trackpad's pointer and its
/// acceleration, the loupe, the page's layout, the gesture card's flag, the live playback while a finger is down, and
/// the input's wire shape.
@Suite("Screen gestures")
struct ScreenGestureTests {
    private let a = CGPoint(x: 0.3, y: 0.3)

    // MARK: Three-finger drag

    @Test func threeFingersDragFromWhereThePointerIs() {
        var drag = ScreenDrag()
        let b = CGPoint(x: 0.31, y: 0.32), c = CGPoint(x: 0.35, y: 0.35)
        // `down` at once (nothing waits for a hold), then the moves
        let v1 = drag.began(at: a)
        #expect(v1 == [.down(a)])
        #expect(drag.isPressed && drag.isDragging)
        let v2 = drag.moved(to: b)
        #expect(v2 == [.move(b)])
        let v3 = drag.moved(to: c)
        #expect(v3 == [.move(c)])
        // lifted: the button stays down for the lock's window
        let v4 = drag.ended(at: c, now: 10)
        #expect(v4 == [])
        #expect(drag.phase == .locked(at: c, until: 10 + ScreenDrag.lockWindow))
        #expect(drag.isPressed && drag.isLocked && !drag.isDragging)
        // the end again: nothing
        let v5 = drag.ended(at: c, now: 10.1)
        #expect(v5 == [])
        // not yet run out: nothing; then `up` where the pointer was
        let r1 = drag.expire(at: 10.5)
        #expect(r1 == [])
        let v6 = drag.expire(at: 10 + ScreenDrag.lockWindow)
        #expect(v6 == [.up(c)])
        #expect(drag.phase == .idle)
        let r2 = drag.expire(at: 20)
        #expect(r2 == [], "let go once")
        // idle: moves and ends do nothing
        let r3 = drag.moved(to: a)
        let r4 = drag.ended(at: a, now: 21)
        #expect(r3 == [] && r4 == [])
    }

    @Test func aTapThenATouchThatMovesDrags() {
        var t = ScreenTapToDrag()
        // a touch with no tap before it: not armed
        t.touched(at: 1)
        #expect(!t.armed)
        let r1 = t.take()
        #expect(!r1)
        // a tap, then a touch within the window: armed; it moves: it drags, once
        t.tapped(at: 2)
        t.touched(at: 2 + ScreenTapToDrag.window - 0.01)
        #expect(t.armed)
        let r2 = t.take()
        let r3 = t.take()
        #expect(r2 && !r3)
        // too late: a plain touch
        t.tapped(at: 5)
        t.touched(at: 5 + ScreenTapToDrag.window + 0.01)
        #expect(!t.armed)
        // landing far from the tap: a finger put down to move the pointer on, not a drag
        t.tapped(at: 6, location: CGPoint(x: 100, y: 100))
        t.touched(at: 6.1, location: CGPoint(x: 100 + ScreenTapToDrag.reach + 1, y: 100))
        #expect(!t.armed)
        t.tapped(at: 6.5, location: CGPoint(x: 100, y: 100))
        t.touched(at: 6.6, location: CGPoint(x: 120, y: 110))
        #expect(t.armed)
        // the tap counts once: the touch after the next one isn't armed by it
        t.tapped(at: 7)
        t.touched(at: 7.1)
        t.lifted()
        #expect(!t.armed)
        t.touched(at: 7.2)
        #expect(!t.armed)
        // a second finger (a scroll, a right-click) or three-finger drag disarms it
        t.tapped(at: 9)
        t.touched(at: 9.1)
        t.disarm()
        let r4 = t.take()
        #expect(!r4)
        // a clock running backwards: not armed
        t.tapped(at: 11)
        t.touched(at: 10)
        #expect(!t.armed)
    }

    // MARK: Drag lock

    /// A drag lifted at `now` with the pointer at `at`.
    private func lockedDrag(at: CGPoint, now: TimeInterval) -> ScreenDrag {
        var drag = ScreenDrag()
        _ = drag.began(at: a)
        _ = drag.moved(to: at)
        _ = drag.ended(at: at, now: now)
        return drag
    }

    @Test func aTouchHeldStillArmsADragThatMovingThenStarts() {
        var h = ScreenHoldToDrag()
        h.touched(at: 1)
        // not yet: the pointer may still start moving
        let early = h.check(at: 1 + ScreenHoldToDrag.delay - 0.01)
        #expect(!early)
        // a fingertip wobbling on its spot is at rest
        h.moved(CGPoint(x: 1, y: 0), at: 1.1)
        h.moved(CGPoint(x: 0, y: 1), at: 1.2)
        let armed = h.check(at: 1 + ScreenHoldToDrag.delay)
        let again = h.check(at: 2)
        #expect(armed && !again && h.armed)
        // armed, the finger may move as far as it likes: the pan begins and it drags, once
        h.moved(CGPoint(x: 80, y: 0), at: 2.1)
        let t1 = h.take()
        let t2 = h.take()
        #expect(t1 && !t2)
        // moving first: only the pointer moves, and the hold has no chance later in this touch
        h.touched(at: 10)
        h.moved(CGPoint(x: ScreenHoldToDrag.stillness + 1, y: 0), at: 10.1)
        let moved = h.check(at: 11)
        #expect(!moved && h.due == nil)
        let t3 = h.take()
        #expect(!t3)
        // the pan began before the hold: no hold this touch
        h.touched(at: 20)
        let t4 = h.take()
        let late = h.check(at: 21)
        #expect(!t4 && !late)
        // a second finger, or the lift, cancels it; nonsense offsets don't arm it
        h.touched(at: 30)
        h.cancel()
        let cancelled = h.check(at: 31)
        h.touched(at: 40)
        h.moved(CGPoint(x: CGFloat.nan, y: 0), at: 40.1)
        let nonsense = h.check(at: 41)
        #expect(!cancelled && !nonsense)
        // held and released without moving is no tap: the spotter's limit is the hold's delay
        #expect(ScreenTapSpotter.maxDuration == ScreenHoldToDrag.delay)
        // a deliberate "tap, then touch" (a double tap's tempo) still arms the tap's drag
        var t = ScreenTapToDrag()
        t.tapped(at: 50)
        t.touched(at: 50.25)
        #expect(t.armed)
    }

    @Test func aFingerCreepingSlowlyNeverArmsAHold() {
        // the start of a fine pointer move: 5 pt over 0.6 s, under the pan's start and within `stillness`
        var h = ScreenHoldToDrag()
        h.touched(at: 0)
        var armed = false
        for i in 1...60 {
            let t = Double(i) * 0.01
            h.moved(CGPoint(x: CGFloat(t) * 8, y: 0), at: t)
            armed = armed || h.check(at: t)
        }
        #expect(!armed)
        // it stops: once it has rested `restTime` the hold arms (later than `delay`)
        let due = h.due ?? 0
        #expect(due > 0.6 && due <= 0.6 + ScreenHoldToDrag.restTime)
        let notYet = h.check(at: due - 0.01)
        let now = h.check(at: due)
        #expect(!notYet && now)
        // shifting on its spot puts the moment off, then it arms
        var g = ScreenHoldToDrag()
        g.touched(at: 0)
        g.moved(CGPoint(x: 0, y: 3), at: 0.4)
        #expect(g.due == 0.4 + ScreenHoldToDrag.restTime)
        let early = g.check(at: ScreenHoldToDrag.delay)
        let later = g.check(at: 0.4 + ScreenHoldToDrag.restTime)
        #expect(!early && later)
    }

    @Test func onlyTapsTheSpotterSawClick() {
        var g = ScreenTapGate()
        // a tap: its recognizer's answer clicks, once
        g.tapped(fingers: 1, at: 1)
        let a1 = g.single(fingers: 1, at: 1.3)
        let a2 = g.single(fingers: 1, at: 1.31)
        #expect(a1 && !a2)
        // a quick short move the single-tap recognizer took for a tap: no click
        g.other(at: 2)
        let b = g.single(fingers: 1, at: 2.3)
        #expect(!b)
        // a tap, then a touch that moved: the tap still clicks (its answer comes while the second touch goes on)
        g.tapped(fingers: 1, at: 3)
        g.other(at: 3.4)
        let c = g.single(fingers: 1, at: 3.45)
        #expect(c)
        // two taps: a double click (each tap once: no single click after it)
        g.tapped(fingers: 1, at: 4)
        g.tapped(fingers: 1, at: 4.2)
        let d1 = g.double(at: 4.25)
        let d2 = g.single(fingers: 1, at: 4.3)
        #expect(d1 && !d2)
        // a tap and a touch that moved: no double click
        g.tapped(fingers: 1, at: 5)
        g.other(at: 5.2)
        let e = g.double(at: 5.25)
        #expect(!e)
        // two fingers: only the two-finger recognizer's answer
        g.tapped(fingers: 2, at: 6)
        let f1 = g.single(fingers: 1, at: 6.1)
        let f2 = g.single(fingers: 2, at: 6.1)
        #expect(!f1 && f2)
        // a drag took the tap before it; a stale answer doesn't click
        g.tapped(fingers: 1, at: 7)
        g.drop()
        let h = g.single(fingers: 1, at: 7.3)
        #expect(!h)
        g.tapped(fingers: 1, at: 8)
        let i = g.single(fingers: 1, at: 8 + ScreenTapGate.maxAge + 0.1)
        #expect(!i)
    }

    @Test func threeFingersBackWithinTheWindowCarryOnTheSameDrag() {
        let b = CGPoint(x: 0.5, y: 0.4), c = CGPoint(x: 0.7, y: 0.45)
        var drag = lockedDrag(at: b, now: 10)
        // touched again in time: the lock holds while the fingers rest, however long
        let r1 = drag.touched(at: 10.5)
        #expect(r1 == [])
        #expect(drag.phase == .locked(at: b, until: nil))
        #expect(drag.lockedUntil == nil)
        let r2 = drag.expire(at: 15)
        #expect(r2 == [], "resting fingers hold it open")
        // they move: the same drag from where its pointer is, no new `down`
        let v1 = drag.began(at: a)
        #expect(v1 == [])
        #expect(drag.phase == .dragging(at: b))
        let v2 = drag.moved(to: c)
        #expect(v2 == [.move(c)])
        // and lift again: another window
        let v3 = drag.ended(at: c, now: 16)
        #expect(v3 == [])
        #expect(drag.lockedUntil == 16 + ScreenDrag.lockWindow)
    }

    @Test func anythingElseOnALockedDragLetsGoWhereThePointerIs() {
        let b = CGPoint(x: 0.5, y: 0.4)
        // a tap (touched, lifted) / a one-finger move / a scroll
        var drag = lockedDrag(at: b, now: 10)
        _ = drag.touched(at: 10.2)
        let v1 = drag.released()
        #expect(v1 == [.up(b)])
        #expect(drag.phase == .idle)
        let r1 = drag.released()
        #expect(r1 == [], "let go once")
        // a lock still running down (no touch seen): a release lets go too
        drag = lockedDrag(at: b, now: 10)
        let r2 = drag.released()
        #expect(r2 == [.up(b)])
        // locked: moves without three fingers beginning do nothing
        drag = lockedDrag(at: b, now: 10)
        let r3 = drag.moved(to: a)
        #expect(r3 == [])
    }

    @Test func aLockRunsOutWhenNoFingerComesBack() {
        let b = CGPoint(x: 0.5, y: 0.4)
        var drag = lockedDrag(at: b, now: 10)
        let r1 = drag.expire(at: 10.79)
        #expect(r1 == [])
        let r2 = drag.expire(at: 10.81)
        #expect(r2 == [.up(b)])
        // a touch after the window (the timer was late) lets go first, then is an ordinary touch
        drag = lockedDrag(at: b, now: 10)
        let r3 = drag.touched(at: 11)
        #expect(r3 == [.up(b)])
        #expect(drag.phase == .idle)
        let r4 = drag.touched(at: 11)
        #expect(r4 == [], "nothing locked: a touch does nothing")
        // three fingers after that start a new drag
        let r5 = drag.began(at: a)
        #expect(r5 == [.down(a)])
    }

    @Test func anInterruptedDragLiftsTheButtonWhereThePointerWas() {
        var drag = ScreenDrag()
        let r1 = drag.cancelled()
        #expect(r1 == [], "nothing pressed: nothing to lift")
        let b = CGPoint(x: 0.4, y: 0.4)
        _ = drag.began(at: a)
        _ = drag.moved(to: b)
        let v1 = drag.cancelled()
        #expect(v1 == [.up(b)])
        let v2 = drag.cancelled()
        #expect(v2 == [])
        // a locked one, and one held open by resting fingers
        drag = lockedDrag(at: b, now: 10)
        let v3 = drag.cancelled()
        #expect(v3 == [.up(b)])
        drag = lockedDrag(at: b, now: 10)
        _ = drag.touched(at: 10.1)
        let v4 = drag.cancelled()
        #expect(v4 == [.up(b)])
        // a new drag while one was dragging lifts the old one first
        _ = drag.began(at: a)
        _ = drag.moved(to: b)
        let v5 = drag.began(at: a)
        #expect(v5 == [.up(b), .down(a)])
    }

    // MARK: Trackpad

    @Test func theTrackpadMovesThePointerByTheGainInDisplayPoints() {
        let display = CGSize(width: 1500, height: 1000)
        let p = ScreenTrackpad.moved(CGPoint(x: 0.5, y: 0.5), by: CGVector(dx: 100, dy: -40), display: display, gain: 1.5)
        #expect(abs(p.x - 0.6) < 1e-9 && abs(p.y - 0.44) < 1e-9)
        // kept on the display
        let edge = ScreenTrackpad.moved(CGPoint(x: 0.95, y: 0.02), by: CGVector(dx: 500, dy: -500), display: display, gain: 1.5)
        #expect(edge == CGPoint(x: 1, y: 0))
        // no display size: it stays put
        #expect(ScreenTrackpad.moved(a, by: CGVector(dx: 10, dy: 10), display: .zero, gain: 1.5) == a)
        #expect(ScreenTrackpad.clamp(CGPoint(x: CGFloat.nan, y: 2)) == CGPoint(x: 0.5, y: 1))
    }

    @Test func theCurveIsPreciseSlowOneAtANormalSpeedAndFarFast() {
        // slow: fine, flat below the precise speed
        #expect(ScreenTrackpad.curve(speed: 0) == ScreenTrackpad.preciseGain)
        #expect(ScreenTrackpad.curve(speed: ScreenTrackpad.preciseSpeed) == ScreenTrackpad.preciseGain)
        #expect(abs(ScreenTrackpad.curve(speed: 20) - 0.55) < 1e-9)
        // the pointer tracks the finger over the picture at a normal speed
        #expect(abs(ScreenTrackpad.curve(speed: ScreenTrackpad.normalSpeed) - 1) < 1e-9)
        // far when fast, flat above the top
        #expect(abs(ScreenTrackpad.curve(speed: ScreenTrackpad.fastSpeed) - ScreenTrackpad.fastGain) < 1e-9)
        #expect(ScreenTrackpad.curve(speed: 5000) == ScreenTrackpad.fastGain)
        #expect(abs(ScreenTrackpad.fastGain - 2.6) < 1e-9)
        // unknown or negative speeds count as still
        #expect(ScreenTrackpad.curve(speed: .nan) == ScreenTrackpad.preciseGain)
        #expect(ScreenTrackpad.curve(speed: -300) == ScreenTrackpad.preciseGain)
        #expect(ScreenTrackpad.curve(speed: .infinity) == ScreenTrackpad.preciseGain)
    }

    @Test func theCurveRisesSmoothlyAndNeverFalls() {
        let speeds = stride(from: 26.0, through: 1399.0, by: 1.0).map { CGFloat($0) }
        let gains = speeds.map { ScreenTrackpad.curve(speed: $0) }
        #expect(zip(gains, gains.dropFirst()).allSatisfy { $0 < $1 })
        // continuous: no jump between neighbouring speeds, nor at either end of the rise
        #expect(zip(gains, gains.dropFirst()).allSatisfy { $1 - $0 < 0.01 })
        #expect(ScreenTrackpad.curve(speed: 25.5) - ScreenTrackpad.preciseGain < 0.001)
        #expect(ScreenTrackpad.fastGain - ScreenTrackpad.curve(speed: 1399) < 0.001)
    }

    @Test func theGainIsRelativeToThePicture() {
        let display = CGSize(width: 1728, height: 1117)
        let landscape = CGSize(width: 870, height: 562), portrait = CGSize(width: 440, height: 284)
        #expect(abs(ScreenTrackpad.pictureFactor(display: display, picture: landscape) - 1728.0 / 870) < 1e-9)
        #expect(ScreenTrackpad.pictureFactor(display: display, picture: .zero) == 1)
        #expect(ScreenTrackpad.pictureFactor(display: .zero, picture: landscape) == 1)
        // at a normal speed one phone point is one picture point
        let normal = ScreenTrackpad.gain(speed: ScreenTrackpad.normalSpeed, display: display, picture: portrait)
        #expect(abs(normal - 1728.0 / 440) < 1e-9)
        // the setting scales it all; nonsense counts as 1
        let base = ScreenTrackpad.gain(speed: 300, display: display, picture: landscape)
        #expect(abs(ScreenTrackpad.gain(speed: 300, display: display, picture: landscape, scale: 2) - 2 * base) < 1e-9)
        #expect(ScreenTrackpad.gain(speed: 300, display: display, picture: landscape, scale: -1) == base)
        #expect(ScreenTrackpad.gain(speed: 300, display: display, picture: landscape, scale: .nan) == base)
    }

    @Test func aSwipeAcrossThePhoneCrossesTheDisplay() {
        let display = CGSize(width: 1728, height: 1117)
        // landscape: a 900-pt swipe at 300 pt/s over an 870-pt picture reaches across the whole display
        let landscape = ScreenTrackpad.gain(speed: 300, display: display, picture: CGSize(width: 870, height: 562))
        #expect(900 * landscape >= display.width)
        let crossed = ScreenTrackpad.moved(CGPoint(x: 0, y: 0.5), by: CGVector(dx: 900, dy: 0), display: display, gain: landscape)
        #expect(crossed.x == 1)
        // portrait: a 400-pt swipe over the pad at 300 pt/s, a 440-pt picture: at least 90 % of it
        let portrait = ScreenTrackpad.gain(speed: 300, display: display, picture: CGSize(width: 440, height: 284))
        #expect(400 * portrait >= 0.9 * display.width)
        // slow still means fine: under one picture point per phone point
        #expect(ScreenTrackpad.curve(speed: 20) * 870 < 870)
    }

    // MARK: Finger speed

    @Test func theFingersSpeedIsItsPathOverTheLastMoment() {
        var f = ScreenFingerSpeed()
        f.reset(at: CGPoint(x: 100, y: 100), time: 1)
        #expect(f.speed == 0, "just down: at rest")
        #expect(f.location == CGPoint(x: 100, y: 100))
        // 300 pt/s to the right, a sample every 1/120 s
        for i in 1...12 { f.add(CGPoint(x: 100 + 2.5 * CGFloat(i), y: 100), at: 1 + Double(i) / 120) }
        #expect(abs(f.speed - 300) < 1)
        #expect(f.samples.count <= 7, "only the last moment is kept")
        // the path, not the displacement: a zigzag counts every leg
        var z = ScreenFingerSpeed()
        z.reset(at: .zero, time: 0)
        for i in 1...8 { z.add(CGPoint(x: i % 2 == 0 ? 0 : 3, y: 0), at: Double(i) / 200) }
        #expect(abs(z.speed - 600) < 1)
        // sub-point moves keep their precision
        var s = ScreenFingerSpeed()
        s.reset(at: .zero, time: 0)
        for i in 1...10 { s.add(CGPoint(x: 0.1 * CGFloat(i), y: 0), at: Double(i) / 240) }
        #expect(abs(s.speed - 24) < 0.5)
    }

    @Test func aFingerThatPausedStartsSlowAndBadSamplesAreIgnored() {
        var f = ScreenFingerSpeed()
        f.reset(at: .zero, time: 0)
        for i in 1...10 { f.add(CGPoint(x: 10 * CGFloat(i), y: 0), at: Double(i) / 100) }
        #expect(abs(f.speed - 1000) < 1)
        // still for a second (no samples), then a point: the pause is in the path's time
        f.add(CGPoint(x: 101, y: 0), at: 1.1)
        #expect(f.speed < 2)
        // out of order, NaN: ignored
        let before = f.speed
        f.add(CGPoint(x: 500, y: 0), at: 0.5)
        f.add(CGPoint(x: CGFloat.nan, y: 0), at: 1.2)
        #expect(f.speed == before && f.location == CGPoint(x: 101, y: 0))
        // a first move right after landing isn't taken for a flick
        var g = ScreenFingerSpeed()
        g.reset(at: .zero, time: 0)
        g.add(CGPoint(x: 2, y: 0), at: 0.002)
        #expect(g.speed <= 2 / ScreenFingerSpeed.minSpan + 1e-6)
        // reset: nothing known
        g.reset()
        #expect(g.speed == 0 && g.location == nil)
        g.add(CGPoint(x: 5, y: 5), at: 3)
        #expect(g.speed == 0, "one sample: at rest")
    }

    // MARK: Finger smoothing

    @Test func aSlowFingersTremorIsSmoothedAway() {
        var f = ScreenFingerSmoother()
        f.reset(at: CGPoint(x: 100, y: 100), time: 0)
        // creeping right at 10 pt/s with a ±1 pt wobble across, a sample every 1/120 s
        var worst: CGFloat = 0
        for i in 1...240 {
            let t = Double(i) / 120
            let wobble: CGFloat = i % 2 == 0 ? 1 : -1
            let p = f.add(CGPoint(x: 100 + 10 * CGFloat(t), y: 100 + wobble), at: t, speed: 10)
            if i > 60 { worst = max(worst, abs(p.y - 100)) }
        }
        #expect(worst < 0.2, "the wobble mostly gone: \(worst)")
        // and it keeps up: under a point behind
        let lag = 100 + 10 * 2 - f.location!.x
        #expect(lag > 0 && lag < 1, "lag \(lag)")
    }

    @Test func aFastFingerIsSmoothedLittle() {
        var f = ScreenFingerSmoother()
        f.reset(at: .zero, time: 0)
        // 1400 pt/s for a quarter second
        var p = CGPoint.zero
        for i in 1...30 { p = f.add(CGPoint(x: 1400 * Double(i) / 120, y: 0), at: Double(i) / 120, speed: 1400) }
        let lag = 1400 * 30 / 120 - p.x
        #expect(lag > 0 && lag <= ScreenFingerSmoother.maxLag + 0.5, "lag \(lag)")
        #expect(ScreenFingerSmoother.maxLag < 3)
    }

    @Test func theSmootherIgnoresBadSamplesAndStartsAfresh() {
        var f = ScreenFingerSmoother()
        // nothing yet: the first sample is taken as it is
        #expect(f.add(CGPoint(x: 5, y: 6), at: 1, speed: 0) == CGPoint(x: 5, y: 6))
        let before = f.add(CGPoint(x: 6, y: 6), at: 1.01, speed: 0)
        // same time, older, NaN, unknown speed: nothing moves (or a still finger's cutoff)
        #expect(f.add(CGPoint(x: 50, y: 50), at: 1.01, speed: 0) == before)
        #expect(f.add(CGPoint(x: 50, y: 50), at: 0.5, speed: 0) == before)
        #expect(f.add(CGPoint(x: CGFloat.nan, y: 0), at: 2, speed: 0) == before)
        let slow = f
        var nanSpeed = f
        _ = f.add(CGPoint(x: 7, y: 6), at: 1.02, speed: 0)
        _ = nanSpeed.add(CGPoint(x: 7, y: 6), at: 1.02, speed: .nan)
        #expect(nanSpeed == f && slow != f)
        // a long pause: the next sample is (nearly) taken as it is
        let late = f.add(CGPoint(x: 20, y: 6), at: 10, speed: 0)
        #expect(abs(late.x - 20) < 0.1)
        f.reset(at: CGPoint(x: 1, y: 1), time: 11)
        #expect(f.location == CGPoint(x: 1, y: 1))
    }

    @MainActor @Test func everyPointerShapeGrowsByTheArrowsFactor() {
        // a 1117-pt-tall display drawn 252 pt tall: the 40-pt arrow image comes out exactly `minPointerHeight` tall
        let display: CGFloat = 1117, screen: CGFloat = 252
        let g = YoyoScreenPictureView.pointerGrow(shapeHeight: 40 / 1117, screenHeight: screen, displayHeight: display)
        #expect(abs(40 / display * screen * g - YoyoScreenPictureView.minPointerHeight) < 1e-9)
        // the 22-pt I-beam grows by the same factor: about half the arrow, not as tall as it
        let ibeam = YoyoScreenPictureView.pointerGrow(shapeHeight: 22 / 1117, screenHeight: screen, displayHeight: display)
        #expect(ibeam == g)
        #expect(22 / display * screen * ibeam < 12)
        // drawn big enough already: as it is
        #expect(YoyoScreenPictureView.pointerGrow(shapeHeight: 40 / 1117, screenHeight: 1117, displayHeight: display) == 1)
        // the display's size unknown: each shape on its own
        let alone = YoyoScreenPictureView.pointerGrow(shapeHeight: 0.02, screenHeight: 250, displayHeight: nil)
        #expect(abs(0.02 * 250 * alone - YoyoScreenPictureView.minPointerHeight) < 1e-9)
        #expect(YoyoScreenPictureView.pointerGrow(shapeHeight: 0, screenHeight: 250, displayHeight: nil) == 1)
    }

    @Test func theMacsPointerCountsAsCaughtUpOnlyWhenItIsWhereThePhoneSentIt() {
        let display = CGSize(width: 1728, height: 1117)
        let sent = CGPoint(x: 0.5, y: 0.5)
        // within a pixel or two (the Mac rounds): there
        #expect(YoyoScreenPictureView.caughtUp(server: CGPoint(x: 0.5 + 1.5 / 1728, y: 0.5 - 1 / 1117), local: sent, display: display))
        // a few points behind (its answer to an earlier, slow move): not yet
        #expect(!YoyoScreenPictureView.caughtUp(server: CGPoint(x: 0.5 - 5 / 1728, y: 0.5), local: sent, display: display))
        #expect(!YoyoScreenPictureView.caughtUp(server: CGPoint(x: 0.5, y: 0.5 + 4 / 1117), local: sent, display: display))
        // display unknown: taken as 1000 points
        #expect(YoyoScreenPictureView.caughtUp(server: CGPoint(x: 0.5005, y: 0.5), local: sent, display: .zero))
        #expect(!YoyoScreenPictureView.caughtUp(server: CGPoint(x: 0.504, y: 0.5), local: sent, display: .zero))
    }

    // MARK: Edge move

    @Test func aDraggingFingerNearAnEdgeKeepsThePointerGoing() {
        let bounds = CGRect(x: 0, y: 0, width: 932, height: 430)
        let w: CGFloat = 870
        // the middle: nothing
        #expect(ScreenEdgeMove.velocity(finger: CGPoint(x: 466, y: 215), bounds: bounds, pictureWidth: w) == .zero)
        #expect(ScreenEdgeMove.velocity(finger: CGPoint(x: ScreenEdgeMove.band, y: 215), bounds: bounds, pictureWidth: w) == .zero)
        // into the right band: rightwards, faster the deeper
        let shallow = ScreenEdgeMove.velocity(finger: CGPoint(x: 932 - 30, y: 215), bounds: bounds, pictureWidth: w)
        let deep = ScreenEdgeMove.velocity(finger: CGPoint(x: 932 - 5, y: 215), bounds: bounds, pictureWidth: w)
        #expect(shallow.dx > 0 && deep.dx > shallow.dx && shallow.dy == 0)
        // at the edge (and past it): the top speed
        let edge = ScreenEdgeMove.velocity(finger: CGPoint(x: 932, y: 215), bounds: bounds, pictureWidth: w)
        #expect(abs(edge.dx - ScreenEdgeMove.maxRate * w) < 1e-9)
        #expect(ScreenEdgeMove.velocity(finger: CGPoint(x: 940, y: 215), bounds: bounds, pictureWidth: w) == edge)
        // the top-left corner: both axes, each on its own
        let corner = ScreenEdgeMove.velocity(finger: CGPoint(x: 10, y: 20), bounds: bounds, pictureWidth: w)
        #expect(corner.dx < 0 && corner.dy < 0 && corner.dx < corner.dy)
        // nonsense: nothing
        #expect(ScreenEdgeMove.velocity(finger: CGPoint(x: CGFloat.nan, y: 0), bounds: bounds, pictureWidth: w) == .zero)
        #expect(ScreenEdgeMove.velocity(finger: CGPoint(x: 0, y: 0), bounds: bounds, pictureWidth: 0) == .zero)
        #expect(ScreenEdgeMove.velocity(finger: .zero, bounds: CGRect(x: 0, y: 0, width: 50, height: 50), pictureWidth: w) == .zero)
        // in display points (the picture's factor): 1.2 display widths a second at the edge
        let factor = ScreenTrackpad.pictureFactor(display: CGSize(width: 1728, height: 1117), picture: CGSize(width: w, height: 562))
        #expect(abs(edge.dx * factor - 1.2 * 1728) < 1e-6)
    }

    // MARK: Loupe and layout

    @Test func theLoupeMagnifiesTowardsTheMacsOwnSize() {
        // a 1728-pt display drawn 390 pt wide (portrait): 2×
        let portrait = ScreenLoupe.magnification(pictureScale: 390.0 / 1728)
        #expect(abs(portrait * 390 / 1728 - ScreenLoupe.targetScale) < 1e-9)
        #expect(abs(portrait - 1.99) < 0.01)
        // drawn big already: at least the minimum; drawn tiny: at most the maximum; unknown: the minimum
        #expect(ScreenLoupe.magnification(pictureScale: 1) == ScreenLoupe.minMagnification)
        #expect(ScreenLoupe.magnification(pictureScale: 0.05) == ScreenLoupe.maxMagnification)
        #expect(ScreenLoupe.magnification(pictureScale: 0) == ScreenLoupe.minMagnification)
        #expect(ScreenLoupe.diameter(picture: CGSize(width: 390, height: 252)) == 126)
        #expect(ScreenLoupe.diameter(picture: CGSize(width: 100, height: 60)) == 100)
        #expect(ScreenLoupe.diameter(picture: CGSize(width: 1000, height: 700)) == 150)
    }

    @Test func theDropMagnifiesItsMiddleEvenlyAndItsBevelRefractsWhatIsAroundIt() {
        // the bevel's pull: 0 where it starts (level: no crease against the flat middle), 1 at the rim, only rising,
        // steeper and steeper outwards, but finite at the rim
        #expect(ScreenDrop.profile(0) == 0)
        #expect(abs(ScreenDrop.profile(1) - 1) < 1e-12)
        #expect(ScreenDrop.profile(1e-4) < 1e-6)
        var last = -1.0, lastStep = 0.0
        for i in 0...100 {
            let v = ScreenDrop.profile(Double(i) / 100)
            #expect(v > last)
            if i > 0 { #expect(v - last >= lastStep - 1e-12); lastStep = v - last }
            last = v
        }
        #expect(lastStep < 0.1)
        #expect(ScreenDrop.bevelPosition(ScreenDrop.flatRadius) == 0 && abs(ScreenDrop.bevelPosition(1) - 1) < 1e-9)
        // the shape agrees: the middle shows what is under the pointer, evenly magnified out to the bevel
        var motion = ScreenDropMotion()
        motion.aim(at: CGPoint(x: 100, y: 80))
        motion.setVisible(true, animated: false)
        let r = 70.0, m = 3.5
        let shape = motion.shape(radius: CGFloat(r), magnification: CGFloat(m))
        #expect(shape.refraction == ScreenDrop.refraction(magnification: m) && shape.presence == 1)
        #expect(shape.source(at: CGPoint(x: 100, y: 80)) == CGPoint(x: 100, y: 80))
        let near = shape.source(at: CGPoint(x: 120, y: 80))
        #expect(abs(near.x - (100 + 20 / m)) < 1e-9)
        let flatEdge = shape.source(at: CGPoint(x: 100 + ScreenDrop.flatRadius * r, y: 80))
        #expect(abs(flatEdge.x - (100 + ScreenDrop.flatRadius * r / m)) < 1e-9)
        // the rim shows the picture from beyond the drop (squeezed into the bevel); outside, the picture itself
        let rim = shape.source(at: CGPoint(x: 100 + r * 0.999999, y: 80))
        let rimError = abs(rim.x - (100 + r * (1 + ScreenDrop.rimReach)))
        #expect(rimError < 0.01, "\(rimError)")
        #expect(abs(shape.rho(at: CGPoint(x: 170, y: 80)) - 1) < 1e-9)
        #expect(shape.source(at: CGPoint(x: 171, y: 80)) == CGPoint(x: 171, y: 80))
        // a point never folds over another along a ray: the source only moves outwards
        var x0 = -1.0
        for i in 0..<200 {
            let src = shape.source(at: CGPoint(x: 100 + r * Double(i) / 200, y: 80)).x
            #expect(src > x0)
            x0 = src
        }
        // it refracts as it swells: nothing while it is a point
        var popping = ScreenDropMotion()
        popping.aim(at: CGPoint(x: 100, y: 80))
        popping.setVisible(true, animated: true)
        #expect(popping.shape(radius: 70, magnification: 3.5).refraction == 0)
        for m in [1.6, 2.0, 4.0] { #expect(abs(1 / m + ScreenDrop.refraction(magnification: m) - 1 - ScreenDrop.rimReach) < 1e-12) }
        #expect(ScreenDrop.radius(picture: CGSize(width: 390, height: 252)) == 126 * ScreenDrop.sizeScale / 2)
    }

    @Test func atThePicturesEdgeThePointerStaysInTheMiddleAndTheDropMergesWithTheEdge() {
        let picture = CGRect(x: 0, y: 40, width: 400, height: 250)
        let r: CGFloat = 70, m: CGFloat = 2
        func shape(at p: CGPoint) -> ScreenDropShape {
            var motion = ScreenDropMotion()
            motion.aim(at: p)
            motion.setVisible(true, animated: false)
            return motion.shape(radius: r, magnification: m, inside: picture)
        }
        // in the middle: the drop is where the pointer is, round, untouched by the edge
        let mid = shape(at: CGPoint(x: 200, y: 160))
        #expect(mid.center == CGPoint(x: 200, y: 160))
        for p in [CGPoint(x: 200, y: 160), CGPoint(x: 240, y: 190), CGPoint(x: 200 + r, y: 160)] {
            #expect(abs(mid.rho(at: p) - mid.dropRho(at: p)) < 1e-12)
        }
        // the top-left corner: the drop stays on the pointer, fully magnified around it
        let corner = CGPoint(x: 2, y: 41)
        let s = shape(at: corner)
        #expect(s.center == corner)
        #expect(s.source(at: corner) == corner)
        let by1 = s.source(at: CGPoint(x: corner.x + 1, y: corner.y + 1))
        #expect(abs(by1.x - (corner.x + 1 / m)) < 1e-9 && abs(by1.y - (corner.y + 1 / m)) < 1e-9)
        // at the left edge: everything the evenly magnified part shows is on the picture
        let edge = shape(at: CGPoint(x: 2, y: 160))
        #expect(edge.center == CGPoint(x: 2, y: 160))
        for i in 0..<36 {
            let angle = Double(i) * .pi / 18
            for f in stride(from: 0.0, to: 1.0, by: 0.05) {
                let p = CGPoint(x: edge.center.x + CGFloat(cos(angle) * f) * r, y: edge.center.y + CGFloat(sin(angle) * f) * r)
                guard edge.rho(at: p) < ScreenDrop.flatRadius, picture.contains(p) else { continue }
                let src = edge.source(at: p)
                #expect(picture.contains(src))
                #expect(abs(src.x - (edge.center.x + (p.x - edge.center.x) / m)) < 1e-9)
            }
        }
        // across the edge: its rim curves out into the edge (a fillet) instead of crossing it...
        let across = shape(at: CGPoint(x: 30, y: 160))
        let fillet = CGPoint(x: 0.5, y: 160 + 66)
        #expect(across.dropRho(at: fillet) > 1 && across.rho(at: fillet) < 1)
        // ...and the edge away from it is no glass
        #expect(across.rho(at: CGPoint(x: 0.5, y: 45)) > 1)
        // coming close, it reaches out and joins the edge; further off it doesn't
        let close = shape(at: CGPoint(x: r * 1.1, y: 160))
        let off = shape(at: CGPoint(x: r * 1.3, y: 160))
        #expect(close.rho(at: CGPoint(x: 0.5, y: 160)) < 1)
        #expect(off.rho(at: CGPoint(x: 0.5, y: 160)) > 1)
        // no edge: just the drop
        var free = ScreenDropMotion()
        free.aim(at: CGPoint(x: 2, y: 160))
        free.setVisible(true, animated: false)
        let unbounded = free.shape(radius: r, magnification: m)
        #expect(unbounded.area == nil && unbounded.rho(at: CGPoint(x: 0, y: 160)) == unbounded.dropRho(at: CGPoint(x: 0, y: 160)))
        // it never folds the picture: the map's Jacobian stays positive all over the drop on the picture, at the edge too
        let h: CGFloat = 0.01
        for d in [mid, s, edge, across, close] {
            for i in 0..<48 {
                let angle = Double(i) * .pi / 24
                for k in 1..<26 {
                    let f = Double(k) / 20
                    let p = CGPoint(x: d.center.x + CGFloat(cos(angle) * f) * r, y: d.center.y + CGFloat(sin(angle) * f) * r)
                    guard d.rho(at: p) < 0.999, picture.insetBy(dx: 1, dy: 1).contains(p) else { continue }
                    let sx = d.source(at: CGPoint(x: p.x + h, y: p.y)), sx0 = d.source(at: CGPoint(x: p.x - h, y: p.y))
                    let sy = d.source(at: CGPoint(x: p.x, y: p.y + h)), sy0 = d.source(at: CGPoint(x: p.x, y: p.y - h))
                    let det = (sx.x - sx0.x) * (sy.y - sy0.y) - (sx.y - sx0.y) * (sy.x - sy0.x)
                    #expect(det > 0, "folds at \(p) for a drop at \(d.center)")
                }
            }
        }
    }

    @Test func theDropShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try device.makeLibrary(source: ScreenDropShader.source, options: nil)
        #expect(library.makeFunction(name: "dropFragment") != nil && library.makeFunction(name: "dropVertex") != nil)
    }

    @Test func theDropStretchesAlongAFastMoveWithATailAndWobblesWhenItStops() {
        // at rest: round
        #expect(ScreenDrop.deformation(velocity: .zero) == (0, 0, .zero))
        #expect(ScreenDrop.deformation(velocity: CGVector(dx: CGFloat.nan, dy: 0)) == (0, 0, .zero))
        // the stretch keeps the area
        let a = ScreenDrop.stretch(xx: 0.2, xy: 0.1)
        #expect(abs(simd_determinant(a) - 1) < 1e-12)
        // moving fast to the right: longer across, narrower up and down, the trailing (left) side the longer one
        var motion = ScreenDropMotion()
        motion.aim(at: CGPoint(x: 0, y: 0))
        motion.setVisible(true, animated: false)
        var peak = 0.0
        for i in 1...30 {
            motion.aim(at: CGPoint(x: Double(i) * 30, y: 0))  // 3600 pt/s at 120 Hz
            motion.step(1.0 / 120, reduceMotion: false)
            peak = max(peak, motion.xx.value)
        }
        var shape = motion.shape(radius: 70, magnification: 3)
        let c = shape.center
        #expect(shape.rho(at: CGPoint(x: c.x + 78, y: c.y)) < 1, "longer along the move")
        #expect(shape.rho(at: CGPoint(x: c.x, y: c.y + 62)) > 1, "narrower across it")
        #expect(shape.rho(at: CGPoint(x: c.x - 95, y: c.y)) < 1, "the tail trails behind")
        #expect(shape.rho(at: CGPoint(x: c.x + 95, y: c.y)) > 1, "the front is rounder")
        #expect(peak > 0.1)
        // a dead stop: the stretch overshoots into a squash along the move (and the tail sloshes forward), then settles round
        var squash = 0.0, slosh = 0.0
        for _ in 0..<240 {
            motion.step(1.0 / 120, reduceMotion: false)
            squash = min(squash, motion.xx.value)
            slosh = max(slosh, motion.tailX.value)
        }
        #expect(squash < -0.02, "it wobbles")
        #expect(slosh > 0.01, "it sloshes forward")
        for _ in 0..<600 { motion.step(1.0 / 120, reduceMotion: false) }
        #expect(motion.settled)
        shape = motion.shape(radius: 70, magnification: 3)
        #expect(abs(shape.rho(at: CGPoint(x: shape.center.x, y: shape.center.y + 70)) - 1) < 0.01)
        // Reduce Motion: never deformed
        var calm = ScreenDropMotion()
        calm.aim(at: .zero)
        calm.setVisible(true, animated: false)
        for i in 1...30 {
            calm.aim(at: CGPoint(x: Double(i) * 30, y: 0))
            calm.step(1.0 / 120, reduceMotion: true)
        }
        #expect(calm.xx.value == 0 && calm.tailX.value == 0)
    }

    @Test func theDropSwellsFromAPointAndShrinksAway() {
        var motion = ScreenDropMotion()
        motion.aim(at: CGPoint(x: 50, y: 50))
        #expect(motion.shape(radius: 70, magnification: 3).radius == 0)
        motion.setVisible(true)
        var biggest: CGFloat = 0
        for _ in 0..<120 {
            motion.step(1.0 / 120, reduceMotion: false)
            biggest = max(biggest, motion.shape(radius: 70, magnification: 3).radius)
        }
        #expect(biggest > 72, "it pops a little past its size")
        #expect(biggest <= 70 * ScreenDrop.maxPresence)
        let full = motion.shape(radius: 70, magnification: 3)
        #expect(abs(full.radius - 70) < 0.5 && abs(full.magnification - 3) < 0.01)
        motion.setVisible(false)
        for _ in 0..<240 { motion.step(1.0 / 120, reduceMotion: false) }
        #expect(motion.shape(radius: 70, magnification: 3).radius < 0.5 && motion.settled)
    }

    @Test func theDropPopsInLikeJellyAndFadesInAndOut() {
        // popping up: drawn tall first, then a squash flat, then round (the area stays all along)
        var motion = ScreenDropMotion()
        motion.aim(at: CGPoint(x: 50, y: 50))
        motion.setVisible(true)
        var tallest = 0.0, flattest = 0.0, firstOpacity: Double?
        for i in 0..<120 {
            motion.step(1.0 / 120, reduceMotion: false)
            let shape = motion.shape(radius: 70, magnification: 3)
            if firstOpacity == nil { firstOpacity = shape.opacity }
            let s = motion.xx.value + motion.pop.value
            if i < 40 { tallest = min(tallest, s) } else { flattest = max(flattest, s) }
        }
        #expect(tallest < -0.1, "taller than wide as it pops up")
        #expect(flattest > 0.03, "then a squash")
        #expect(firstOpacity! < 0.5, "it fades in")
        for _ in 0..<240 { motion.step(1.0 / 120, reduceMotion: false) }
        #expect(motion.settled && motion.shape(radius: 70, magnification: 3).opacity == 1)
        // going: it squashes flat as it shrinks and fades out
        motion.setVisible(false)
        var squash = 0.0, faded = false
        for _ in 0..<30 {
            motion.step(1.0 / 120, reduceMotion: false)
            squash = max(squash, motion.pop.value)
            faded = faded || motion.shape(radius: 70, magnification: 3).opacity < 0.5
        }
        #expect(squash > 0.05 && faded)
        // Reduce Motion: no wobble
        var calm = ScreenDropMotion()
        calm.aim(at: .zero)
        calm.setVisible(true, reduceMotion: true)
        for _ in 0..<60 { calm.step(1.0 / 120, reduceMotion: true) }
        #expect(calm.pop.value == 0)
    }

    @Test func aTapIsSpottedTheMomentTheFingersLift() {
        var s = ScreenTapSpotter()
        // one finger, quick and still
        s.down(fingers: 1, at: 10)
        s.moved(3)
        #expect(s.allUp(at: 10.12) == 1)
        // two fingers (the second a moment later)
        s.down(fingers: 1, at: 20)
        s.down(fingers: 2, at: 20.03)
        #expect(s.allUp(at: 20.15) == 2)
        // held: a press (it arms a drag), not a tap
        s.down(fingers: 1, at: 30)
        #expect(s.allUp(at: 30 + ScreenHoldToDrag.delay + 0.01) == nil)
        // moved: a drag
        s.down(fingers: 1, at: 40)
        s.moved(25)
        #expect(s.allUp(at: 40.1) == nil)
        // taken by the system; nonsense distances spoil it too
        s.down(fingers: 1, at: 50)
        s.cancel()
        #expect(s.allUp(at: 50.1) == nil)
        s.down(fingers: 1, at: 60)
        s.moved(.nan)
        #expect(s.allUp(at: 60.1) == nil)
        // each sequence starts afresh
        s.down(fingers: 1, at: 70)
        #expect(s.allUp(at: 70.1) == 1)
        #expect(s.allUp(at: 70.2) == nil)
    }

    @MainActor @Test func theDropReadsTheDecodersPictures() throws {
        // the decoder's usual output (420v / 420f), BGRA, and a format the shader doesn't read (converted first)
        let renderer = try #require(ScreenDropRenderer.shared)
        let formats: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                 kCVPixelFormatType_32BGRA, kCVPixelFormatType_422YpCbCr8]
        for format in formats {
            var buffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, format, attributes as CFDictionary, &buffer) == kCVReturnSuccess)
            let made = try #require(buffer)
            let source = try #require(renderer.source(made), "format \(format)")
            #expect(source.planes.count == (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 2 : 1))
            #expect(source.uv == SIMD4(0, 0, 1, 1))
        }
    }

    @Test func videoPicturesConvertToTheRightColors() {
        func rgb(_ y: Float, _ cb: Float, _ cr: Float, full: Bool, matrix: String? = nil) -> SIMD3<Float> {
            let k = ScreenDrop.lumaWeights(matrix: matrix)
            let (rows, offset) = ScreenDrop.yuvToRGB(kr: k.kr, kb: k.kb, fullRange: full)
            let v = SIMD3(y, cb, cr) - offset
            return SIMD3(simd_dot(rows[0], v), simd_dot(rows[1], v), simd_dot(rows[2], v))
        }
        func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_length(a - b) < 0.01 }
        // video range: 16 is black, 235 white; full range: 0 and 255
        #expect(close(rgb(16 / 255, 128 / 255, 128 / 255, full: false), .zero))
        #expect(close(rgb(235 / 255, 128 / 255, 128 / 255, full: false), SIMD3(1, 1, 1)))
        #expect(close(rgb(1, 128 / 255, 128 / 255, full: true), SIMD3(1, 1, 1)))
        // BT.709 red (video range 63, 102, 240)
        #expect(close(rgb(63 / 255, 102 / 255, 240 / 255, full: false), SIMD3(1, 0, 0)))
        // BT.601 red (81, 90, 240)
        #expect(close(rgb(81 / 255, 90 / 255, 240 / 255, full: false, matrix: "ITU_R_601_4"), SIMD3(1, 0, 0)))
    }

    @Test func theLoupesSpringsSettleBounceAndKeepTheirSpeedWhenRetargeted() {
        // a bouncy spring overshoots, then settles on its target
        var s = ScreenSpring(0)
        s.target = 1
        var peak = 0.0
        for _ in 0..<120 { s.step(1.0 / 120, ScreenLoupe.appear); peak = max(peak, s.value) }
        #expect(peak > 1.02, "springy: it overshoots")
        #expect(s.settled(epsilon: 0.01))
        // critically damped: never past the target
        var c = ScreenSpring(1)
        c.target = 0
        var low = 1.0
        for _ in 0..<120 { c.step(1.0 / 120, ScreenLoupe.disappear); low = min(low, c.value) }
        #expect(low > -0.001 && c.settled(epsilon: 0.01))
        // the follow spring is most of the way there within a tenth of a second
        var f = ScreenSpring(0)
        f.target = 100
        for _ in 0..<12 { f.step(1.0 / 120, ScreenLoupe.follow) }
        #expect(f.value > 70)
        // retargeting keeps the velocity (no jump, no stop)
        let v = f.velocity
        f.target = 200
        #expect(f.velocity == v)
        // a long frame stays stable; nonsense is ignored
        var big = ScreenSpring(0)
        big.target = 1
        big.step(0.5, ScreenLoupe.follow)
        #expect(abs(big.value - 1) < 0.1)
        big.step(.nan, ScreenLoupe.follow)
        #expect(big.value.isFinite)
    }

    @MainActor @Test func thePictureSitsOnTopOfATrackpadAndFullScreenFillsTheScreen() {
        // portrait: full width at the top, the surface below it down to the area's bottom
        let tall = CGRect(x: 0, y: 59, width: 390, height: 700)
        let (picture, pad) = ScreenPageLayout.layout(area: tall, aspect: 1.6)
        #expect(picture == CGRect(x: 0, y: 59, width: 390, height: 243))
        let p = pad
        #expect(p?.minY == picture.maxY + ScreenPageLayout.padGap && p?.maxY == tall.maxY)
        #expect(p?.minX == ScreenPageLayout.padGap && p?.width == 390 - 2 * ScreenPageLayout.padGap)
        // full screen (no surface): aspect-fit, centered
        let wide = CGRect(x: 120, y: 0, width: 612, height: 372)
        let (fit, none) = ScreenPageLayout.layout(area: wide, aspect: 1.6, pad: false)
        #expect(none == nil && fit.height == 372 && fit.width == 595 && fit.midX.rounded() == wide.midX.rounded())
        // wide with the surface (an iPad in landscape): the picture narrows, centered, to leave the surface its height
        let (narrow, under) = ScreenPageLayout.layout(area: wide, aspect: 1.6)
        #expect(narrow.minY == 0 && narrow.height == 372 - ScreenPageLayout.minPadHeight - ScreenPageLayout.padGap)
        #expect(narrow.midX.rounded() == wide.midX.rounded() && under?.height == ScreenPageLayout.minPadHeight)
        // not enough room under a full-width picture: it narrows too
        let short = CGRect(x: 0, y: 0, width: 390, height: 243 + 12 + 150)
        #expect(ScreenPageLayout.layout(area: short, aspect: 1.6).pad?.height == ScreenPageLayout.minPadHeight)
        // too little room for both: the picture alone
        let tiny = CGRect(x: 0, y: 0, width: 390, height: ScreenPageLayout.minPadHeight + 12 + 100)
        #expect(ScreenPageLayout.layout(area: tiny, aspect: 1.6).pad == nil)
        #expect(ScreenPageLayout.layout(area: .zero, aspect: 1.6).picture == .zero)
    }

    // MARK: Zoom

    @Test func fittedThePictureFillsItsFrame() {
        let size = CGSize(width: 400, height: 250)
        let z = ScreenZoom()
        #expect(!z.zoomed)
        #expect(z.frame(in: size) == CGRect(origin: .zero, size: size))
        #expect(z.point(at: CGPoint(x: 100, y: 125), in: size) == CGPoint(x: 0.25, y: 0.5))
    }

    @Test func zoomedInThePictureAlwaysCoversItsFrame() {
        let size = CGSize(width: 400, height: 250)
        var z = ScreenZoom(scale: 2, center: CGPoint(x: 0, y: 1))
        z.clampCenter()
        #expect(z.center == CGPoint(x: 0.25, y: 0.75))
        let f = z.frame(in: size)
        #expect(f == CGRect(x: 0, y: -250, width: 800, height: 500))
        // a center past the edge (not clamped) still keeps the picture over the frame
        let loose = ScreenZoom(scale: 2, center: CGPoint(x: 1.2, y: -0.3)).frame(in: size)
        #expect(loose.minX == 400 - 800 && loose.minY == 0)
    }

    @Test func aPinchKeepsTheSpotUnderTheFingers() {
        let size = CGSize(width: 400, height: 250)
        var z = ScreenZoom()
        let at = CGPoint(x: 300, y: 100)
        let anchor = z.point(at: at, in: size)
        z.scale = 3
        z.place(anchor, at: at, in: size)
        let back = z.point(at: at, in: size)
        #expect(abs(back.x - anchor.x) < 1e-9 && abs(back.y - anchor.y) < 1e-9)
    }

    @Test func thePinchsScaleGivesWayPastItsLimits() {
        #expect(ScreenZoom.clampedScale(0.5, rubber: false) == 1)
        #expect(ScreenZoom.clampedScale(9, rubber: false) == ScreenZoom.maxScale)
        let under = ScreenZoom.clampedScale(0.5, rubber: true)
        #expect(under < 1 && under > 0.5)
        let over = ScreenZoom.clampedScale(ScreenZoom.maxScale + 2, rubber: true)
        #expect(over > ScreenZoom.maxScale && over < ScreenZoom.maxScale + 2)
        #expect(ScreenZoom.clampedScale(.nan, rubber: true) == 1)
    }

    @Test func zoomedInWhatShowsFollowsThePointerOnlyNearItsEdges() {
        var z = ScreenZoom(scale: 2, center: CGPoint(x: 0.5, y: 0.5))
        // shows 0.25…0.75; the pointer well inside: nothing moves
        z.follow(CGPoint(x: 0.5, y: 0.6))
        #expect(z.center == CGPoint(x: 0.5, y: 0.5))
        // past the margin on the right: just enough to keep it that far in
        z.follow(CGPoint(x: 0.8, y: 0.5))
        let right = z.center.x + 0.5 / z.scale - ScreenZoom.followMargin / z.scale
        #expect(abs(right - 0.8) < 1e-9 && z.center.y == 0.5)
        // to the corner: as far as the edges let it
        z.follow(CGPoint(x: 1, y: 1))
        #expect(z.center == CGPoint(x: 0.75, y: 0.75))
        // fitted: never moves
        var fitted = ScreenZoom()
        fitted.follow(CGPoint(x: 0.9, y: 0.1))
        #expect(fitted == ScreenZoom())
    }

    // MARK: Gesture card

    @Test func theCardShowsOnceThenNotAgain() {
        var hints = ScreenGestureHints(seen: false)
        let first = hints.take()
        let second = hints.take()
        #expect(first && !second)
        #expect(hints == ScreenGestureHints(seen: true))
    }

    @Test func theCardListsTheTrackpadsGestures() {
        let rows = ScreenGestureRow.rows
        #expect(rows.count == 7)
        #expect(rows.allSatisfy { !$0.gesture.isEmpty && !$0.action.isEmpty && !$0.symbol.isEmpty })
        #expect(rows.first?.symbol == "cursorarrow.motionlines")
        #expect(rows.map(\.symbol).contains("hand.draw") && rows.map(\.symbol).contains("cursorarrow.click.2"))
        #expect(rows.map(\.symbol).contains("character.cursor.ibeam"))
        // nothing zooms any more
        #expect(!rows.map(\.symbol).contains("arrow.up.left.and.arrow.down.right"))
    }

    // MARK: Live playback while a finger is down

    @Test func aFingerDownIsLiveAndItLingersAfterTheLastLifts() {
        var i = ScreenInteractivity()
        let t0 = ContinuousClock.now
        let v18 = i.began()
        #expect(v18)
        let v19 = i.began()
        #expect(!v19, "already live")
        let until = i.ended(at: t0)
        #expect(until == t0 + ScreenInteractivity.linger)
        #expect(i.interactive)
        let v20 = i.expire(at: t0 + .milliseconds(599))
        #expect(!v20)
        // a finger back within the linger: still live, no switch
        let v21 = i.began()
        #expect(!v21)
        let v22 = i.expire(at: t0 + .seconds(5))
        #expect(!v22, "a finger is down")
        _ = i.ended(at: t0 + .seconds(5))
        let v23 = i.expire(at: t0 + .seconds(5) + .milliseconds(600))
        #expect(v23)
        #expect(!i.interactive)
        let v24 = i.ended(at: t0)
        #expect(v24 == nil, "not live: nothing to end")
        _ = i.began()
        let v25 = i.reset()
        let v26 = i.reset()
        #expect(v25 && !i.interactive && !v26)
    }

    @Test func liveShowsEachPictureAtOnceAndKeepsMeasuring() {
        var core = ScreenPlayout<Int>()
        core.evenPace = true
        let mac = 1_761_170_000.0, host = 5_000.0
        for i in 0..<20 {
            let v27 = core.push(i, macTime: mac + Double(i) / 30, arrival: host + Double(i) / 30 + 0.04 + (i % 3 == 0 ? 0.012 : 0))
            #expect(v27 == .queued)
            _ = core.next(target: host + Double(i) / 30 + 0.2)
        }
        let depth = core.depth, base = core.base
        #expect(core.hold > 0 && core.paceInterval != nil)
        #expect(abs(core.contentInterval - 1.0 / 30) < 0.002)
        core.interactive = true
        #expect(core.hold == 0 && core.paceInterval == nil)
        // shown on arrival (what waited is dropped), sampled all the same: the Mac speeding up to 60 fps is seen
        _ = core.push(99, macTime: mac + 0.7, arrival: host + 0.74)
        for i in 0..<20 {
            let t = 0.7 + Double(i + 1) / 60
            let v28 = core.push(100 + i, macTime: mac + t, arrival: host + t + 0.04)
            #expect(v28 == .now)
        }
        #expect(core.queued == 0)
        #expect(core.contentInterval < 1.0 / 30 - 0.003)
        #expect(core.base == base)
        core.interactive = false
        // back to smooth: the buffer carries on from what it measured (not the 25 ms start)
        #expect(abs(core.depth - depth) < 0.01 && core.hold > 0 && core.paceInterval != nil)
        let v29 = core.push(200, macTime: mac + 1.1, arrival: host + 1.14)
        #expect(v29 == .queued)
    }

    @Test func theStatsSayLiveAndTheReportSaysLatency() {
        let stats = ScreenStreamStats()
        stats.streamStarted(mode: .smooth, at: 100)
        stats.shown(decodeMs: 2, at: 100.1)
        stats.shown(decodeMs: 2, at: 100.2)
        stats.setInteractive(true)
        let live = stats.take(host: 100.3)
        #expect(live.interactive && live.line.hasSuffix(" · live"))
        #expect(live.playout?.mode == .latency)
        stats.setInteractive(false)
        let smooth = stats.take(host: 100.4)
        #expect(!smooth.interactive && !smooth.line.contains("live") && smooth.playout?.mode == .smooth)
    }

    // MARK: Wire

    @Test func aLiveDragsInputOnTheWire() {
        let down = ScreenInput.pointer(.down, display: 91, at: CGPoint(x: 0.3, y: 0.3), modifiers: [.alt])
        #expect(down.json["type"] as? String == "down" && down.json["display"] as? Int == 91)
        #expect(down.json["modifiers"] as? [String] == ["alt"] && down.json["button"] == nil)
        let move = ScreenInput.pointer(.move, display: nil, at: CGPoint(x: 0.32, y: 0.33), button: .left)
        #expect(move.json["type"] as? String == "move" && move.json["button"] as? String == "left")
        #expect(move.json["x"] as? Double == Double(CGFloat(0.32)))
        let up = ScreenInput.pointer(.up, display: nil, at: CGPoint(x: 0.35, y: 0.35))
        #expect(up.json["type"] as? String == "up" && up.json["button"] == nil && up.json["display"] == nil)
        // a plain move as before: no button
        #expect(ScreenInput(.move, x: 0.5, y: 0.5).json["button"] == nil)
    }

    // MARK: Two-finger scroll

    private let picture = CGSize(width: 400, height: 250)

    @Test func aTwoFingerPanBeginsWithItsFirstMovementChangesAndEndsWithTheVelocityAtLift() {
        var scroll = ScreenTwoFingerScroll()
        // the recognizer needed 10 points up to start: that is the began's delta (content further down)
        let began = scroll.began(translation: CGPoint(x: 0, y: -10), size: picture, reporting: true)
        #expect(began == ScreenScrollStep(delta: CGVector(dx: 0, dy: 10.0 / 250), phase: .began))
        // it started straight up: locked to the vertical axis, the fingers' sideways drift is dropped
        #expect(scroll.axis == .vertical)
        let changed = scroll.changed(translation: CGPoint(x: 8, y: -35), size: picture, reporting: true)
        #expect(changed == ScreenScrollStep(delta: CGVector(dx: 0, dy: 25.0 / 250), phase: .changed))
        #expect(scroll.active)
        // lifted moving up at 1000 pt/s: content goes on further down at 4 pictures a second (no sideways glide)
        let ended = scroll.ended(velocity: CGPoint(x: -200, y: -1000), size: picture)
        #expect(ended == ScreenScrollStep(delta: .zero, phase: .ended, velocity: CGVector(dx: 0, dy: 4)))
        #expect(!scroll.active)
        // nothing more to end
        #expect(scroll.ended(velocity: CGPoint(x: 0, y: 100), size: picture) == nil)
    }

    @Test func aPanKeepsToTheAxisItStartedAlongOrMovesFreelyOnADiagonal() {
        #expect(ScreenTwoFingerScroll.axis(for: CGPoint(x: 3, y: -20)) == .vertical)
        #expect(ScreenTwoFingerScroll.axis(for: CGPoint(x: -20, y: 10)) == .horizontal)
        #expect(ScreenTwoFingerScroll.axis(for: CGPoint(x: 12, y: 14)) == .both)
        var scroll = ScreenTwoFingerScroll()
        // too short to tell: undecided, nothing goes yet (no sideways nudge before the lock)
        #expect(scroll.began(translation: CGPoint(x: 3, y: 4), size: picture, reporting: true) == nil)
        #expect(scroll.axis == nil && !scroll.active)
        // decided sideways: the whole travel so far goes as the began, on the horizontal axis; at lift too
        let next = scroll.changed(translation: CGPoint(x: 30, y: 8), size: picture, reporting: true)
        #expect(scroll.axis == .horizontal && next == ScreenScrollStep(delta: CGVector(dx: -30.0 / 400, dy: 0), phase: .began))
        let more = scroll.changed(translation: CGPoint(x: 50, y: 20), size: picture, reporting: true)
        #expect(more == ScreenScrollStep(delta: CGVector(dx: -20.0 / 400, dy: 0), phase: .changed))
        let ended = scroll.ended(velocity: CGPoint(x: 800, y: 300), size: picture)
        #expect(ended?.velocity == CGVector(dx: -2, dy: 0))
        // a diagonal keeps both
        _ = scroll.began(translation: CGPoint(x: 10, y: 10), size: picture, reporting: true)
        #expect(scroll.axis == .both)
        let diag = scroll.changed(translation: CGPoint(x: 30, y: 20), size: picture, reporting: true)
        #expect(diag?.delta == CGVector(dx: -20.0 / 400, dy: -10.0 / 250))
    }

    @Test func aHardFlickIsCappedKeepingItsDirection() {
        let slow = CGVector(dx: 300, dy: -2000)
        #expect(ScreenTwoFingerScroll.capped(slow) == slow)
        let hard = ScreenTwoFingerScroll.capped(CGVector(dx: 0, dy: 9000))
        #expect(hard == CGVector(dx: 0, dy: ScreenTwoFingerScroll.maxLiftSpeed))
        let diag = ScreenTwoFingerScroll.capped(CGVector(dx: 8000, dy: -6000))
        #expect(abs(hypot(diag.dx, diag.dy) - ScreenTwoFingerScroll.maxLiftSpeed) < 0.001)
        #expect(abs(diag.dx / diag.dy - 8000.0 / -6000.0) < 0.0001)
        #expect(ScreenTwoFingerScroll.capped(CGVector(dx: CGFloat.nan, dy: 10)) == .zero)
    }

    @Test func aCancelledPanEndsWithoutVelocityAndOneThatNeverReportedDoesNotEnd() {
        var scroll = ScreenTwoFingerScroll()
        _ = scroll.began(translation: CGPoint(x: 0, y: 10), size: picture, reporting: true)
        #expect(scroll.ended(velocity: nil, size: picture) == ScreenScrollStep(delta: .zero, phase: .ended))
        // lifted before the axis was decided: nothing was reported, nothing ends
        #expect(scroll.began(translation: CGPoint(x: 0, y: 5), size: picture, reporting: true) == nil)
        #expect(scroll.ended(velocity: CGPoint(x: 0, y: 300), size: picture) == nil)
        // not controlling: followed, not reported; control taken mid-pan: the next move begins the gesture
        #expect(scroll.began(translation: CGPoint(x: 0, y: 5), size: picture, reporting: false) == nil)
        #expect(scroll.changed(translation: CGPoint(x: 0, y: 15), size: picture, reporting: false) == nil)
        #expect(scroll.ended(velocity: CGPoint(x: 0, y: 500), size: picture) == nil)
        _ = scroll.began(translation: .zero, size: picture, reporting: false)
        _ = scroll.changed(translation: CGPoint(x: 0, y: 20), size: picture, reporting: false)
        let first = scroll.changed(translation: CGPoint(x: 0, y: 45), size: picture, reporting: true)
        #expect(first == ScreenScrollStep(delta: CGVector(dx: 0, dy: -25.0 / 250), phase: .began))
        // no picture yet: nothing reported, and no velocity at the end
        #expect(scroll.changed(translation: CGPoint(x: 0, y: 50), size: .zero, reporting: true) == nil)
        #expect(scroll.ended(velocity: CGPoint(x: 0, y: 500), size: .zero) == ScreenScrollStep(delta: .zero, phase: .ended))
    }

    @Test func aScrollsPhaseAndVelocityGoOnTheWireOnlyWhenSet() {
        let ended = ScreenInput(.scroll, display: 2, x: 0.5, y: 0.25, dx: 0, dy: 0, phase: .ended, vx: -12.5, vy: 1800)
        let j = ended.json
        #expect(j["type"] as? String == "scroll" && j["phase"] as? String == "ended")
        #expect(j["dx"] as? Double == 0 && j["dy"] as? Double == 0)
        #expect(j["vx"] as? Double == -12.5 && j["vy"] as? Double == 1800)
        let began = ScreenInput(.scroll, x: 0.5, y: 0.5, dx: 0, dy: 3, phase: .began).json
        #expect(began["phase"] as? String == "began" && began["vx"] == nil && began["vy"] == nil)
        // a plain scroll as before
        let plain = ScreenInput(.scroll, x: 0.5, y: 0.5, dx: 0, dy: 3).json
        #expect(plain.keys.sorted() == ["dx", "dy", "type", "x", "y"])
    }
}
