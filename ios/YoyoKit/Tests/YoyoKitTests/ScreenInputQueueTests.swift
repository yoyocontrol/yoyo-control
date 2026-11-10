import CoreGraphics
import Foundation
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The Screen page's input queue: one request at a time, scrolls added up while one is on its way, other input in
/// order after the moves before it, nothing after `cancel()`.
@MainActor
@Suite("Screen input queue")
struct ScreenInputQueueTests {
    struct Failure: Error {}

    /// Records each request and holds it "on its way" until `finish`.
    @MainActor
    final class Sender {
        private(set) var sent: [ScreenInput] = []
        private var waiting: [CheckedContinuation<Void, Error>] = []
        private(set) var failures = 0

        nonisolated var send: ScreenInputQueue.Send { { [self] input in try await self.receive(input) } }

        private func receive(_ input: ScreenInput) async throws {
            sent.append(input)
            try await withCheckedThrowingContinuation { waiting.append($0) }
        }

        var inFlight: Int { waiting.count }

        func finish(_ error: Error? = nil) {
            let c = waiting.removeFirst()
            if let error { c.resume(throwing: error) } else { c.resume() }
        }

        func failed(_ error: Error) { failures += 1 }

        func queue() -> ScreenInputQueue {
            ScreenInputQueue(send: send, failed: { [weak self] in self?.failed($0) })
        }
    }

    /// Lets the queue's tasks run until `done` (or gives up).
    private func settle(until done: () -> Bool = { false }) async {
        for _ in 0..<200 {
            if done() { return }
            await Task.yield()
        }
    }

    private func dy(_ input: ScreenInput) -> Double? { input.type == .scroll ? input.dy : nil }

    @Test func movesWhileAScrollIsOnItsWayGoAsOneWhenItReturns() async {
        let sender = Sender()
        let q = sender.queue()
        q.scroll(by: CGVector(dx: 0, dy: 10), at: CGPoint(x: 0.2, y: 0.2), display: 1)
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.map(dy) == [10])
        q.scroll(by: CGVector(dx: 0, dy: 5), at: CGPoint(x: 0.3, y: 0.3), display: 1)
        q.scroll(by: CGVector(dx: 2, dy: 7.5), at: CGPoint(x: 0.4, y: 0.4), display: 1)
        await settle()
        // still one on its way; the moves wait
        #expect(sender.sent.count == 1 && sender.inFlight == 1)
        #expect(q.pendingScroll == CGVector(dx: 2, dy: 12.5))
        sender.finish()
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.count == 2)
        let merged = sender.sent[1]
        #expect(merged.type == .scroll && merged.dx == 2 && merged.dy == 12.5 && merged.display == 1)
        #expect(merged.x == 0.4 && merged.y == 0.4)   // where the last move was
        #expect(q.pendingScroll == .zero)
        sender.finish()
        await settle()
        #expect(sender.sent.count == 2 && sender.inFlight == 0 && q.mergesOutstanding == 0)
    }

    @Test func lessThanHalfAPointWaitsForMore() async {
        let sender = Sender()
        let q = sender.queue()
        q.scroll(by: CGVector(dx: 0, dy: 0.3), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        await settle()
        #expect(sender.sent.isEmpty)
        q.scroll(by: CGVector(dx: 0, dy: 0.3), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.count == 1 && abs((sender.sent[0].dy ?? 0) - 0.6) < 1e-9)
        sender.finish()
    }

    @Test func aFailedScrollStillLetsTheMovesThatAddedUpGo() async {
        let sender = Sender()
        let q = sender.queue()
        q.scroll(by: CGVector(dx: 0, dy: 10), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        await settle { sender.inFlight == 1 }
        q.scroll(by: CGVector(dx: 0, dy: -4), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        sender.finish(Failure())
        await settle { sender.inFlight == 1 }
        #expect(sender.failures == 1)
        #expect(sender.sent.map(dy) == [10, -4])
        sender.finish()
        await settle()
        #expect(sender.failures == 1 && q.mergesOutstanding == 0)
    }

    @Test func otherInputGoesInOrderAfterTheMovesBeforeIt() async {
        let sender = Sender()
        let q = sender.queue()
        q.scroll(by: CGVector(dx: 0, dy: 10), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        await settle { sender.inFlight == 1 }
        q.scroll(by: CGVector(dx: 0, dy: 4), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        q.send(.click(display: nil, at: CGPoint(x: 0.1, y: 0.1)))
        // a move after the click goes after it
        q.scroll(by: CGVector(dx: 0, dy: 6), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        for _ in 0..<3 {
            sender.finish()
            await settle { sender.inFlight == 1 }
        }
        sender.finish()
        await settle()
        #expect(sender.sent.map(\.type) == [.scroll, .scroll, .click, .scroll])
        #expect(sender.sent.map(dy) == [10, 4, nil, 6])
        #expect(sender.inFlight == 0 && q.mergesOutstanding == 0)
    }

    @Test func aScrollWaitingInLineTakesMovesUntilSomethingQueuesBehindIt() async {
        let sender = Sender()
        let q = sender.queue()
        q.send(ScreenInput(.key, key: "a"))
        await settle { sender.inFlight == 1 }
        // the key is on its way: the scroll waits in line and takes every move…
        q.scroll(by: CGVector(dx: 0, dy: 5), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        q.scroll(by: CGVector(dx: 0, dy: 3), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        // …until another key queues behind it
        q.send(ScreenInput(.key, key: "b"))
        q.scroll(by: CGVector(dx: 0, dy: 2), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        for _ in 0..<3 {
            sender.finish()
            await settle { sender.inFlight == 1 }
        }
        sender.finish()
        await settle()
        #expect(sender.sent.map(\.type) == [.key, .scroll, .key, .scroll])
        #expect(sender.sent.map(dy) == [nil, 8, nil, 2])
        #expect(sender.sent.map(\.key) == ["a", nil, "b", nil])
    }

    @Test func nothingGoesAfterCancel() async {
        let sender = Sender()
        let q = sender.queue()
        q.scroll(by: CGVector(dx: 0, dy: 10), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        await settle { sender.inFlight == 1 }
        q.scroll(by: CGVector(dx: 0, dy: 5), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        q.send(ScreenInput(.key, key: "return"))
        q.cancel()
        #expect(q.pendingScroll == .zero)
        // the request already sent comes back (failed, even): nothing more goes, no error shown
        sender.finish(Failure())
        await settle()
        #expect(sender.sent.count == 1 && sender.inFlight == 0 && sender.failures == 0)
        // the page back: input goes again
        q.scroll(by: CGVector(dx: 0, dy: 3), at: CGPoint(x: 0.5, y: 0.5), display: nil)
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.map(dy) == [10, 3])
        sender.finish()
    }

    // MARK: A two-finger gesture's phases

    private func phase(_ input: ScreenInput) -> ScreenInput.ScrollPhase? { input.phase }

    @Test func aGestureBeginsAtOnceItsMovesAddUpAndItsEndGoesWithThemAndTheVelocity() async {
        let sender = Sender()
        let q = sender.queue()
        let p = CGPoint(x: 0.5, y: 0.5)
        // a began goes however small it is
        q.scroll(by: CGVector(dx: 0, dy: 0.2), at: p, display: 1, phase: .began)
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.map(phase) == [.began])
        q.scroll(by: CGVector(dx: 0, dy: 5), at: p, display: 1, phase: .changed)
        q.scroll(by: CGVector(dx: 1, dy: 7), at: CGPoint(x: 0.6, y: 0.6), display: 1, phase: .changed)
        // the fingers lift while the began is on its way: the moves go with the end, as one request
        q.scroll(by: .zero, at: CGPoint(x: 0.6, y: 0.6), display: 1, phase: .ended, velocity: CGVector(dx: -30, dy: 2400))
        #expect(q.pendingScroll == .zero)
        sender.finish()
        await settle { sender.inFlight == 1 }
        sender.finish()
        await settle()
        #expect(sender.sent.map(phase) == [.began, .ended])
        #expect(sender.sent.map(dy) == [0.2, 12])
        let end = sender.sent[1]
        #expect(end.dx == 1 && end.vx == -30 && end.vy == 2400 && end.x == 0.6 && end.y == 0.6 && end.display == 1)
        #expect(sender.sent[0].vx == nil && sender.sent[0].vy == nil)
        #expect(sender.inFlight == 0 && q.mergesOutstanding == 0)
    }

    @Test func aBeganThatHasNotGoneYetTakesTheMovesAndStaysBegan() async {
        let sender = Sender()
        let q = sender.queue()
        let p = CGPoint(x: 0.5, y: 0.5)
        q.send(ScreenInput(.key, key: "a"))
        await settle { sender.inFlight == 1 }
        q.scroll(by: CGVector(dx: 0, dy: 3), at: p, display: nil, phase: .began)
        q.scroll(by: CGVector(dx: 0, dy: 4), at: p, display: nil, phase: .changed)
        q.scroll(by: .zero, at: p, display: nil, phase: .ended, velocity: CGVector(dx: 0, dy: 50))
        for _ in 0..<2 {
            sender.finish()
            await settle { sender.inFlight == 1 }
        }
        sender.finish()
        await settle()
        #expect(sender.sent.map(\.type) == [.key, .scroll, .scroll])
        #expect(sender.sent.map(phase) == [nil, .began, .ended])
        #expect(sender.sent.map(dy) == [nil, 7, 0])
    }

    @Test func aNewGestureNeverMergesIntoTheLastOne() async {
        let sender = Sender()
        let q = sender.queue()
        let p = CGPoint(x: 0.5, y: 0.5)
        q.scroll(by: CGVector(dx: 0, dy: 10), at: p, display: nil, phase: .began)
        await settle { sender.inFlight == 1 }
        q.scroll(by: CGVector(dx: 0, dy: 6), at: p, display: nil, phase: .changed)
        q.scroll(by: .zero, at: p, display: nil, phase: .ended, velocity: CGVector(dx: 0, dy: 900))
        // a quick second flick while the first is still going out
        q.scroll(by: CGVector(dx: 0, dy: 4), at: p, display: nil, phase: .began)
        q.scroll(by: CGVector(dx: 0, dy: 2), at: p, display: nil, phase: .changed)
        for _ in 0..<2 {
            sender.finish()
            await settle { sender.inFlight == 1 }
        }
        sender.finish()
        await settle()
        #expect(sender.sent.map(phase) == [.began, .ended, .began])
        #expect(sender.sent.map(dy) == [10, 6, 6])
        #expect(sender.inFlight == 0 && q.mergesOutstanding == 0)
    }

    @Test func aBeganSendsAnEarlierGesturesLeftoversFirst() async {
        let sender = Sender()
        let q = sender.queue()
        let p = CGPoint(x: 0.5, y: 0.5)
        q.scroll(by: CGVector(dx: 0, dy: 10), at: p, display: nil)
        await settle { sender.inFlight == 1 }
        // a plain scroll waits (its end never came); a gesture begins
        q.scroll(by: CGVector(dx: 0, dy: 5), at: p, display: nil)
        q.scroll(by: CGVector(dx: 0, dy: -3), at: p, display: nil, phase: .began)
        q.scroll(by: CGVector(dx: 0, dy: -2), at: p, display: nil, phase: .changed)
        for _ in 0..<2 {
            sender.finish()
            await settle { sender.inFlight == 1 }
        }
        sender.finish()
        await settle()
        #expect(sender.sent.map(phase) == [nil, nil, .began])
        #expect(sender.sent.map(dy) == [10, 5, -5])
    }

    @Test func anEndWithNothingWaitingGoesOnItsOwn() async {
        let sender = Sender()
        let q = sender.queue()
        let p = CGPoint(x: 0.5, y: 0.5)
        q.scroll(by: CGVector(dx: 0, dy: 9), at: p, display: nil, phase: .began)
        await settle { sender.inFlight == 1 }
        sender.finish()
        await settle()
        q.scroll(by: .zero, at: p, display: nil, phase: .ended, velocity: CGVector(dx: 0, dy: 40))
        await settle { sender.inFlight == 1 }
        sender.finish()
        await settle()
        #expect(sender.sent.map(phase) == [.began, .ended])
        #expect(sender.sent.map(dy) == [9, 0])
        #expect(sender.sent[1].vy == 40 && sender.inFlight == 0 && q.mergesOutstanding == 0)
    }

    @Test func aChangedWithoutABeganIsSentAsChangedAndNoEndGoesAfterCancel() async {
        let sender = Sender()
        let q = sender.queue()
        let p = CGPoint(x: 0.5, y: 0.5)
        q.scroll(by: CGVector(dx: 0, dy: 8), at: p, display: nil, phase: .changed)
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.map(phase) == [.changed])
        q.scroll(by: CGVector(dx: 0, dy: 4), at: p, display: nil, phase: .changed)
        q.scroll(by: .zero, at: p, display: nil, phase: .ended, velocity: CGVector(dx: 0, dy: 900))
        q.cancel()
        sender.finish()
        await settle()
        #expect(sender.sent.count == 1 && sender.inFlight == 0 && q.mergesOutstanding == 0)
    }

    // MARK: Pointer moves (trackpad, a live drag's held moves): the merging lane, latest position only

    private func point(_ input: ScreenInput) -> CGPoint? {
        guard let x = input.x, let y = input.y else { return nil }
        return CGPoint(x: x, y: y)
    }

    @Test func threeMovesGoAtOnceAndTheFourthWaitsWithOnlyTheLatestPosition() async {
        let sender = Sender()
        let made = Int(Date().timeIntervalSince1970 * 1000)
        let q = sender.queue()
        q.move(to: CGPoint(x: 0.1, y: 0.1), display: 1, button: .left)
        await settle { sender.inFlight == 1 }
        q.move(to: CGPoint(x: 0.2, y: 0.2), display: 1, button: .left)
        await settle { sender.inFlight == 2 }
        q.move(to: CGPoint(x: 0.3, y: 0.3), display: 1, button: .left)
        await settle { sender.inFlight == 3 }
        // three on their way: the next ones wait, only the latest position
        q.move(to: CGPoint(x: 0.4, y: 0.4), display: 1, button: .left)
        q.move(to: CGPoint(x: 0.45, y: 0.35), display: 1, button: .left)
        await settle()
        #expect(sender.sent.count == 3 && sender.inFlight == 3 && q.movesInFlight == 3)
        #expect(q.pendingMove == CGPoint(x: 0.45, y: 0.35))
        sender.finish()
        await settle { sender.inFlight == 3 }
        #expect(sender.sent.count == 4)
        #expect(sender.sent.map(\.type) == [.move, .move, .move, .move])
        #expect(sender.sent.map(\.button) == [.left, .left, .left, .left])
        #expect(point(sender.sent[3]) == CGPoint(x: 0.45, y: 0.35) && sender.sent[3].display == 1)
        // each with the next seq, from the wall clock in ms when the queue was made
        let seqs = sender.sent.compactMap(\.seq)
        #expect(seqs.count == 4 && zip(seqs, seqs.dropFirst()).allSatisfy { $1 == $0 + 1 })
        #expect(seqs[0] >= made)
        for _ in 0..<3 { sender.finish() }
        await settle()
        #expect(sender.sent.count == 4 && sender.inFlight == 0 && q.mergesOutstanding == 0 && q.pendingMove == nil)
        #expect(q.movesInFlight == 0 && q.movesOutstanding == 0)
    }

    @Test func aClickWaitsForEveryMoveOnItsWay() async {
        let sender = Sender()
        let q = sender.queue()
        for i in 1...3 {
            q.move(to: CGPoint(x: 0.1 * Double(i), y: 0.1), display: nil)
            await settle { sender.inFlight == i }
        }
        q.send(.click(display: nil, at: CGPoint(x: 0.3, y: 0.1)))
        await settle()
        #expect(sender.sent.map(\.type) == [.move, .move, .move])
        // the moves come back in any order; the click goes once the last one is back
        sender.finish()
        await settle()
        sender.finish()
        await settle()
        #expect(sender.sent.count == 3 && sender.inFlight == 1)
        sender.finish()
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.map(\.type) == [.move, .move, .move, .click])
        #expect(sender.sent[3].seq == nil)
        sender.finish()
        await settle()
        #expect(sender.inFlight == 0 && q.mergesOutstanding == 0)
    }

    @Test func movesAfterAClickWaitForItAndTheSeqKeepsGoingUp() async {
        let sender = Sender()
        let q = sender.queue()
        q.move(to: CGPoint(x: 0.1, y: 0.1), display: nil)
        await settle { sender.inFlight == 1 }
        q.send(.click(display: nil, at: CGPoint(x: 0.1, y: 0.1)))
        q.move(to: CGPoint(x: 0.2, y: 0.2), display: nil)
        q.move(to: CGPoint(x: 0.25, y: 0.2), display: nil)
        await settle()
        // the click waits for the move, the moves for the click
        #expect(sender.sent.map(\.type) == [.move])
        sender.finish()
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.map(\.type) == [.move, .click])
        sender.finish()
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.map(\.type) == [.move, .click, .move])
        #expect(point(sender.sent[2]) == CGPoint(x: 0.25, y: 0.2))
        sender.finish()
        await settle()
        // after a cancel the count goes on (the Mac keeps the highest it applied for a while)
        q.cancel()
        q.move(to: CGPoint(x: 0.3, y: 0.3), display: nil)
        await settle { sender.inFlight == 1 }
        sender.finish()
        await settle()
        let seqs = sender.sent.compactMap(\.seq)
        #expect(seqs.count == 3 && zip(seqs, seqs.dropFirst()).allSatisfy { $1 == $0 + 1 })
        #expect(sender.sent.filter { $0.type != .move }.allSatisfy { $0.seq == nil })
    }

    @Test func aScrollWaitsForTheMovesOnTheirWayAndMovesWaitForAScroll() async {
        let sender = Sender()
        let q = sender.queue()
        q.move(to: CGPoint(x: 0.1, y: 0.1), display: nil)
        await settle { sender.inFlight == 1 }
        q.move(to: CGPoint(x: 0.2, y: 0.2), display: nil)
        await settle { sender.inFlight == 2 }
        q.scroll(by: CGVector(dx: 0, dy: 5), at: CGPoint(x: 0.2, y: 0.2), display: nil)
        await settle()
        #expect(sender.sent.map(\.type) == [.move, .move] && q.pendingScroll == CGVector(dx: 0, dy: 5))
        sender.finish()
        await settle()
        #expect(sender.sent.count == 2)
        sender.finish()
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.map(\.type) == [.move, .move, .scroll])
        // one scroll at a time, and a move after it waits for it
        q.scroll(by: CGVector(dx: 0, dy: 2), at: CGPoint(x: 0.2, y: 0.2), display: nil)
        q.move(to: CGPoint(x: 0.3, y: 0.3), display: nil)
        q.move(to: CGPoint(x: 0.35, y: 0.3), display: nil)
        await settle()
        #expect(sender.sent.count == 3)
        sender.finish()
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.map(\.type) == [.move, .move, .scroll, .scroll])
        #expect(sender.sent[3].dy == 2)
        sender.finish()
        await settle { sender.inFlight == 1 }
        #expect(sender.sent.map(\.type) == [.move, .move, .scroll, .scroll, .move])
        #expect(point(sender.sent[4]) == CGPoint(x: 0.35, y: 0.3))
        sender.finish()
        await settle()
        #expect(sender.inFlight == 0 && q.mergesOutstanding == 0 && q.movesOutstanding == 0)
    }

    @Test func aFailedMoveLetsTheNextGoAndIsReportedOnce() async {
        let sender = Sender()
        let q = sender.queue()
        for i in 1...3 {
            q.move(to: CGPoint(x: 0.1 * Double(i), y: 0.1), display: nil)
            await settle { sender.inFlight == i }
        }
        q.move(to: CGPoint(x: 0.9, y: 0.9), display: nil)
        sender.finish(Failure())
        await settle { sender.inFlight == 3 }
        #expect(sender.failures == 1 && sender.sent.count == 4 && point(sender.sent[3]) == CGPoint(x: 0.9, y: 0.9))
        for _ in 0..<3 { sender.finish() }
        await settle()
        #expect(sender.failures == 1 && sender.inFlight == 0 && q.mergesOutstanding == 0)
    }

    @Test func failedMovesInABurstAreReportedOnceAClickAlways() async {
        let sender = Sender()
        var now = ContinuousClock.now
        let q = ScreenInputQueue(send: sender.send, failed: { [weak sender] in sender?.failed($0) }, firstSeq: 7,
                                 clock: { now })
        for i in 1...3 {
            q.move(to: CGPoint(x: 0.1 * Double(i), y: 0.1), display: nil)
            await settle { sender.inFlight == i }
        }
        #expect(sender.sent.map(\.seq) == [7, 8, 9])
        // a dead path: all three fail at once, one is reported
        for _ in 0..<3 { sender.finish(Failure()) }
        await settle { q.movesInFlight == 0 }
        #expect(sender.failures == 1)
        // a click that fails right after is reported all the same (a 409 must show)
        q.send(.click(display: nil, at: CGPoint(x: 0.5, y: 0.5)))
        await settle { sender.inFlight == 1 }
        sender.finish(Failure())
        await settle { sender.failures == 2 }
        #expect(sender.failures == 2)
        // a move failing within a second of that is quiet; one later is reported
        q.move(to: CGPoint(x: 0.6, y: 0.6), display: nil)
        await settle { sender.inFlight == 1 }
        now += .milliseconds(900)
        sender.finish(Failure())
        await settle { q.movesInFlight == 0 }
        #expect(sender.failures == 2)
        q.move(to: CGPoint(x: 0.7, y: 0.7), display: nil)
        await settle { sender.inFlight == 1 }
        now += .milliseconds(200)
        sender.finish(Failure())
        await settle { sender.failures == 3 }
        #expect(sender.failures == 3 && sender.sent.compactMap(\.seq) == [7, 8, 9, 10, 11])
    }

    @Test func aMoveCarriesItsSeqOnlyAsAMove() {
        var move = ScreenInput.pointer(.move, display: nil, at: CGPoint(x: 0.5, y: 0.5))
        #expect(move.json["seq"] == nil)
        move.seq = 41
        #expect(move.json["seq"] as? Int == 41)
        var click = ScreenInput.click(display: nil, at: CGPoint(x: 0.5, y: 0.5))
        click.seq = 3
        #expect(click.json["seq"] == nil)
    }

    @Test func aDragsDownMovesAndUpKeepTheirOrderAndClicksWaitBehindThem() async {
        let sender = Sender()
        let q = sender.queue()
        q.send(.pointer(.down, display: nil, at: CGPoint(x: 0.3, y: 0.3)))
        await settle { sender.inFlight == 1 }
        // the down is on its way: the moves wait (one slot, the latest position) …
        q.move(to: CGPoint(x: 0.31, y: 0.31), display: nil, button: .left)
        q.move(to: CGPoint(x: 0.33, y: 0.33), display: nil, button: .left)
        // … the up goes after them, a click after the up
        q.send(.pointer(.up, display: nil, at: CGPoint(x: 0.35, y: 0.35)))
        q.send(.click(display: nil, at: CGPoint(x: 0.9, y: 0.9)))
        for _ in 0..<3 {
            sender.finish()
            await settle { sender.inFlight == 1 }
        }
        sender.finish()
        await settle()
        #expect(sender.sent.map(\.type) == [.down, .move, .up, .click])
        #expect(point(sender.sent[1]) == CGPoint(x: 0.33, y: 0.33) && sender.sent[1].button == .left)
        #expect(sender.sent[2].button == nil && sender.sent[0].button == nil)
        #expect(sender.inFlight == 0 && q.mergesOutstanding == 0)
    }

    @Test func aScrollAfterMovesSendsTheMoveFirst() async {
        let sender = Sender()
        let q = sender.queue()
        q.move(to: CGPoint(x: 0.1, y: 0.1), display: nil)
        await settle { sender.inFlight == 1 }
        q.move(to: CGPoint(x: 0.2, y: 0.2), display: nil)
        q.scroll(by: CGVector(dx: 0, dy: 12), at: CGPoint(x: 0.2, y: 0.2), display: nil)
        q.scroll(by: CGVector(dx: 0, dy: 3), at: CGPoint(x: 0.2, y: 0.2), display: nil)
        for _ in 0..<2 {
            sender.finish()
            await settle { sender.inFlight == 1 }
        }
        sender.finish()
        await settle()
        #expect(sender.sent.map(\.type) == [.move, .move, .scroll])
        #expect(sender.sent.map(\.button) == [nil, nil, nil])
        #expect(sender.sent[2].dy == 15)
        #expect(sender.inFlight == 0 && q.mergesOutstanding == 0)
    }

    @Test func noMoveGoesAfterCancel() async {
        let sender = Sender()
        let q = sender.queue()
        q.move(to: CGPoint(x: 0.1, y: 0.1), display: nil, button: .left)
        await settle { sender.inFlight == 1 }
        q.move(to: CGPoint(x: 0.2, y: 0.2), display: nil, button: .left)
        q.send(.pointer(.up, display: nil, at: CGPoint(x: 0.2, y: 0.2)))
        q.cancel()
        #expect(q.pendingMove == nil)
        sender.finish()
        await settle()
        #expect(sender.sent.count == 1 && sender.inFlight == 0 && q.mergesOutstanding == 0)
    }
}
