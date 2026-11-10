import CoreGraphics
import XCTest
@testable import YoyoServer

/// `ScrollMotion` (ScrollSynth.swift) on an injected clock: even pacing over the expected interval, no lost
/// fractions, a two-finger gesture's phases, momentum after the fingers lift, and what stops it.
final class ScrollMotionTests: XCTestCase {
    typealias M = ScrollMotion
    static let tick = M.tick

    /// Drives `m` like the driver does: a tick at `from` (right after a request), then on the 1/120 s grid whenever
    /// `nextWake` asks, up to `to`; `log` collects (time, event).
    @discardableResult
    private func run(_ m: inout M, from: Double, to: Double, into log: inout [(t: Double, e: M.Emit)]) -> [M.Emit] {
        var out: [M.Emit] = []
        var due: Double? = from
        var t = from
        while t <= to + 1e-9 {
            if let d = due, t >= d - 1e-9 {
                for e in m.tick(now: t) { out.append(e); log.append((t, e)) }
                due = m.nextWake(now: t)
            }
            t += Self.tick
        }
        return out
    }

    private func run(_ m: inout M, from: Double, to: Double) -> [M.Emit] {
        var log: [(t: Double, e: M.Emit)] = []
        return run(&m, from: from, to: to, into: &log)
    }

    private func sum(_ es: [M.Emit]) -> (x: Int, y: Int) {
        es.reduce((0, 0)) { ($0.0 + $1.dx, $0.1 + $1.dy) }
    }

    private let p = CGPoint(x: 100, y: 200)

    // MARK: Pacing

    func testAPlainScrollGoesOutEvenlyWithinTheFastWindowWithoutPhases() {
        var m = M()
        m.submit(dx: 0, dy: 100, phase: nil, point: p, now: 0)
        var log: [(t: Double, e: M.Emit)] = []
        run(&m, from: 0, to: 1, into: &log)
        XCTAssertEqual(sum(log.map(\.e)).y, 100)
        XCTAssertTrue(log.allSatisfy { $0.e.scrollPhase == .none && $0.e.momentumPhase == .none && $0.e.point == p })
        // the first tick at once, the last by the fast window
        XCTAssertEqual(log.first?.t ?? -1, 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(log.last!.t, M.fastWindow + Self.tick + 1e-9)
        // even: no step more than twice another
        let steps = log.map { Double($0.e.dy) }
        XCTAssertLessThanOrEqual(steps.max()! / steps.min()!, 2)
        XCTAssertNil(m.nextWake(now: 1))
    }

    func testRequestsOneIntervalApartKeepThePictureMovingBetweenThem() {
        // the tunnel: a request every 100 ms, 50 px each
        var m = M()
        var log: [(t: Double, e: M.Emit)] = []
        for i in 0..<10 {
            let t0 = Double(i) * 0.1
            m.submit(dx: 0, dy: 50, phase: nil, point: p, now: t0)
            run(&m, from: t0, to: t0 + 0.1 - Self.tick / 2, into: &log)
        }
        run(&m, from: 1.0, to: 2.0, into: &log)
        XCTAssertEqual(sum(log.map(\.e)).y, 500)
        XCTAssertEqual(m.interval ?? 0, 0.1, accuracy: 1e-6)
        // once the interval is known, the pixels go out over 90 ms of every 100: about 9 px every 1/120 s tick
        let steady = log.filter { $0.t >= 0.3 && $0.t < 1.0 }.map(\.e.dy)
        XCTAssertGreaterThanOrEqual(steady.count, 75)
        XCTAssertTrue(steady.allSatisfy { (3...8).contains($0) }, "\(steady)")
        // the fingers stop: what was left is out by its deadline, no tail
        XCTAssertLessThanOrEqual(log.last!.t, 0.9 + 0.09 + Self.tick + 1e-6)
    }

    func testFractionsAreNeverLost() {
        var m = M()
        var all: [M.Emit] = []
        var t = 0.0
        for _ in 0..<200 {
            m.submit(dx: -0.3, dy: 0.7, phase: nil, point: p, now: t)
            all += run(&m, from: t, to: t + 0.016 - Self.tick / 2)
            t += 0.016
        }
        all += run(&m, from: t, to: t + 1)
        let s = sum(all)
        XCTAssertEqual(Double(s.x), -60, accuracy: 1)
        XCTAssertEqual(Double(s.y), 140, accuracy: 1)
    }

    func testAPauseStartsTheIntervalAfresh() {
        var m = M()
        m.submit(dx: 0, dy: 10, phase: nil, point: p, now: 0)
        m.submit(dx: 0, dy: 10, phase: nil, point: p, now: 0.1)
        XCTAssertEqual(m.interval ?? 0, 0.1, accuracy: 1e-9)
        m.submit(dx: 0, dy: 10, phase: nil, point: p, now: 0.7)
        XCTAssertNil(m.interval)
    }

    func testTheWindowIsCappedOnASlowPath() {
        // 400 ms apart: the pixels still go out within 140 ms
        var m = M()
        var log: [(t: Double, e: M.Emit)] = []
        m.submit(dx: 0, dy: 10, phase: nil, point: p, now: 0)
        run(&m, from: 0, to: 0.39, into: &log)
        m.submit(dx: 0, dy: 200, phase: nil, point: p, now: 0.4)
        log = []
        run(&m, from: 0.4, to: 1, into: &log)
        XCTAssertEqual(sum(log.map(\.e)).y, 200)
        XCTAssertLessThanOrEqual(log.last!.t, 0.4 + M.maxWindow + Self.tick + 1e-6)
        XCTAssertGreaterThan(log.last!.t, 0.4 + M.maxWindow - 2 * Self.tick)
    }

    // MARK: Phases

    func testAGestureBeginsChangesAndEndsWithoutMomentumWhenSlow() {
        var m = M()
        var log: [(t: Double, e: M.Emit)] = []
        m.submit(dx: 0, dy: 8, phase: .began, point: p, now: 0)
        run(&m, from: 0, to: 0.049, into: &log)
        m.submit(dx: 0, dy: 20, phase: .changed, point: p, now: 0.05)
        run(&m, from: 0.05, to: 0.099, into: &log)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 60, point: p, now: 0.1)
        run(&m, from: 0.1, to: 2, into: &log)
        let es = log.map(\.e)
        XCTAssertEqual(es.first?.scrollPhase, .began)
        XCTAssertEqual(es.filter { $0.scrollPhase == .began }.count, 1)
        XCTAssertEqual(es.last, M.Emit(dx: 0, dy: 0, scrollPhase: .ended, point: p))
        XCTAssertTrue(es.dropFirst().dropLast().allSatisfy { $0.scrollPhase == .changed && $0.dy != 0 })
        XCTAssertTrue(es.allSatisfy { $0.momentumPhase == .none })
        XCTAssertEqual(sum(es).y, 28)
        XCTAssertNil(m.nextWake(now: 2))
        let s = m.takeSummaries()
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.requests, 3)
        XCTAssertNil(s.first?.momentumV0)
        XCTAssertTrue(s.first?.description.contains("no momentum (60 pt/s at lift)") ?? false, s.first?.description ?? "")
    }

    func testTheEndedWaitsForWhatIsLeft() {
        var m = M()
        var log: [(t: Double, e: M.Emit)] = []
        m.submit(dx: 0, dy: 300, phase: .began, point: p, now: 0)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 0, point: p, now: 0.001)
        run(&m, from: 0.001, to: 1, into: &log)
        let ended = log.firstIndex { $0.e.scrollPhase == .ended }!
        XCTAssertEqual(ended, log.count - 1)
        XCTAssertEqual(sum(log.map(\.e)).y, 300)
    }

    func testAChangedWithNoOpenGestureBeginsOne() {
        var m = M()
        m.submit(dx: 5, dy: 0, phase: .changed, point: p, now: 0)
        let es = run(&m, from: 0, to: 0.1)
        XCTAssertEqual(es.first?.scrollPhase, .began)
        XCTAssertTrue(m.isGestureOpen)
    }

    func testABareEndedIsNothing() {
        var m = M()
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 3000, point: p, now: 0)
        XCTAssertNil(m.nextWake(now: 0))
        XCTAssertTrue(run(&m, from: 0, to: 1).isEmpty)
    }

    func testABeganWithLessThanAPixelStillBegins() {
        var m = M()
        m.submit(dx: 0, dy: 0.2, phase: .began, point: p, now: 0)
        let es = run(&m, from: 0, to: 0.1)
        XCTAssertEqual(es, [M.Emit(dx: 0, dy: 0, scrollPhase: .began, point: p)])
    }

    func testAGestureThePhoneLeftOpenEndsAfterThreeSecondsWithoutMomentum() {
        var m = M()
        m.submit(dx: 0, dy: 30, phase: .began, point: p, now: 0)
        _ = run(&m, from: 0, to: 0.2)
        // waiting for the next request: no ticks meanwhile
        XCTAssertEqual(m.nextWake(now: 0.2) ?? 0, M.gestureTimeout, accuracy: 1e-9)
        XCTAssertTrue(run(&m, from: 0.2, to: 2.9).isEmpty)
        let es = run(&m, from: 3.0, to: 6)
        XCTAssertEqual(es, [M.Emit(dx: 0, dy: 0, scrollPhase: .ended, point: p)])
        XCTAssertFalse(m.isGestureOpen || m.isDecelerating)
        XCTAssertEqual(m.takeSummaries().first?.timedOut, true)
    }

    func testFingersBackBeforeTheGestureWasOutContinueIt() {
        // a quick second flick: began while the first's ended still waits for its pixels
        var m = M()
        m.submit(dx: 0, dy: 200, phase: .began, point: p, now: 0)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 2000, point: p, now: 0.002)
        var es = run(&m, from: 0, to: 0.01)
        m.submit(dx: 0, dy: 40, phase: .began, point: p, now: 0.015)
        es += run(&m, from: 0.015, to: 0.2)
        XCTAssertEqual(es.filter { $0.scrollPhase == .began }.count, 1)
        XCTAssertFalse(es.contains { $0.scrollPhase == .ended || $0.momentumPhase != .none })
        XCTAssertTrue(m.isGestureOpen)
        XCTAssertEqual(sum(es).y, 240)
    }

    // MARK: Momentum

    func testAFlickScrollsOnWithMomentumThatSlowsLikeUIScrollView() {
        var m = M()
        var log: [(t: Double, e: M.Emit)] = []
        m.submit(dx: 0, dy: 40, phase: .began, point: p, now: 0)
        run(&m, from: 0, to: 0.05, into: &log)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 2000, point: p, now: 0.06)
        run(&m, from: 0.06, to: 6, into: &log)
        let es = log.map(\.e)
        let ended = es.firstIndex { $0.scrollPhase == .ended }!
        let momentum = Array(es[(ended + 1)...])
        XCTAssertEqual(momentum.first?.momentumPhase, .begin)
        XCTAssertEqual(momentum.last, M.Emit(dx: 0, dy: 0, momentumPhase: .end, point: p))
        XCTAssertTrue(momentum.dropFirst().dropLast().allSatisfy { $0.momentumPhase == .continue && $0.scrollPhase == .none })
        // distance: v0 / (-ln 0.998 · 1000 / s) ≈ 0.4995 s · v0, less the tail under 20 pt/s
        let distance = Double(sum(momentum).y)
        let expected = (2000.0 - M.momentumStop) / (-Foundation.log(M.deceleration) * 1000)
        XCTAssertEqual(distance, expected, accuracy: 2)
        // duration: until 2000 · 0.998^ms < 20, about 2.3 s
        let start = log[ended].t, end = log.last!.t
        XCTAssertEqual(end - start, Foundation.log(100) / -Foundation.log(M.deceleration) / 1000, accuracy: 0.03)
        // each step smaller than the one before (or equal, rounding)
        let steps = momentum.map(\.dy)
        XCTAssertTrue(zip(steps.dropLast(), steps.dropFirst()).allSatisfy { $0 + 1 >= $1 })
        XCTAssertNil(m.nextWake(now: 6))
        let s = m.takeSummaries().first!
        XCTAssertEqual(s.momentumV0 ?? 0, 2000, accuracy: 1e-9)
        XCTAssertEqual(s.momentumPx.y, Int(distance))
        XCTAssertTrue(s.description.contains("momentum 2000 pt/s"), s.description)
    }

    func testTheLiftSpeedIsCapped() {
        var m = M()
        m.submit(dx: 0, dy: 10, phase: .began, point: p, now: 0)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: -60_000, vy: 80_000, point: p, now: 0.01)
        _ = run(&m, from: 0, to: 6)
        XCTAssertEqual(m.takeSummaries().first?.momentumV0 ?? 0, M.momentumMax, accuracy: 1e-6)
    }

    func testANewGestureStopsTheMomentumFirst() {
        var m = M()
        m.submit(dx: 0, dy: 10, phase: .began, point: p, now: 0)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 3000, point: p, now: 0.01)
        _ = run(&m, from: 0, to: 0.3)
        XCTAssertTrue(m.isDecelerating)
        m.submit(dx: 0, dy: -12, phase: .began, point: p, now: 0.31)
        let es = run(&m, from: 0.31, to: 0.4)
        XCTAssertEqual(es.first, M.Emit(dx: 0, dy: 0, momentumPhase: .end, point: p))
        XCTAssertEqual(es.dropFirst().first?.scrollPhase, .began)
        XCTAssertFalse(es.dropFirst().contains { $0.momentumPhase != .none })
        XCTAssertFalse(m.isDecelerating)
        XCTAssertEqual(m.takeSummaries().first?.momentumInterrupted, true)
    }

    func testAStrayEndedDoesNotStopTheMomentum() {
        var m = M()
        m.submit(dx: 0, dy: 10, phase: .began, point: p, now: 0)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 3000, point: p, now: 0.01)
        _ = run(&m, from: 0, to: 0.3)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 0, point: p, now: 0.31)
        XCTAssertTrue(m.isDecelerating)
    }

    func testAPlainScrollStopsTheMomentumToo() {
        var m = M()
        m.submit(dx: 0, dy: 10, phase: .began, point: p, now: 0)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 3000, point: p, now: 0.01)
        _ = run(&m, from: 0, to: 0.3)
        m.submit(dx: 0, dy: 40, phase: nil, point: p, now: 0.31)
        let es = run(&m, from: 0.31, to: 1)
        XCTAssertEqual(es.first?.momentumPhase, .end)
        XCTAssertEqual(sum(es).y, 40)
    }

    // MARK: Interrupt

    func testOtherPointerInputFlushesTheRestEndsTheGestureAndStopsMomentum() {
        var m = M()
        m.submit(dx: 0, dy: 300, phase: .began, point: p, now: 0)
        var es = run(&m, from: 0, to: 0.01)
        m.interrupt(now: 0.012)
        es += m.tick(now: 0.012)
        XCTAssertEqual(sum(es).y, 300)
        XCTAssertEqual(es.last, M.Emit(dx: 0, dy: 0, scrollPhase: .ended, point: p))
        XCTAssertFalse(m.isGestureOpen)
        XCTAssertNil(m.nextWake(now: 0.02))
        XCTAssertEqual(m.takeSummaries().first?.interrupted, true)

        // decelerating: a zero-delta momentum end at once, nothing after it
        m.submit(dx: 0, dy: 10, phase: .began, point: p, now: 1)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 3000, point: p, now: 1.01)
        _ = run(&m, from: 1, to: 1.3)
        m.interrupt(now: 1.31)
        XCTAssertEqual(m.tick(now: 1.31), [M.Emit(dx: 0, dy: 0, momentumPhase: .end, point: p)])
        XCTAssertNil(m.nextWake(now: 1.32))

        // a plain scroll's rest goes at once, no phases
        m.submit(dx: 0, dy: 100, phase: nil, point: p, now: 2)
        _ = m.tick(now: 2)
        m.interrupt(now: 2.001)
        let rest = m.tick(now: 2.001)
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(rest.first?.scrollPhase, M.ScrollPhase.none)
        XCTAssertNil(m.nextWake(now: 2.01))
    }

    func testEventsUseTheLatestPointAndFlags() {
        var m = M()
        let q = CGPoint(x: 300, y: 400)
        m.submit(dx: 0, dy: 10, phase: .began, point: p, now: 0)
        m.submit(dx: 0, dy: 10, phase: .changed, point: q, flags: .maskCommand, now: 0.001)
        m.submit(dx: 0, dy: 0, phase: .ended, vx: 0, vy: 1000, point: nil, flags: .maskCommand, now: 0.002)
        let es = run(&m, from: 0.002, to: 4)
        XCTAssertTrue(es.allSatisfy { $0.point == q && $0.flags == .maskCommand })
    }
}
