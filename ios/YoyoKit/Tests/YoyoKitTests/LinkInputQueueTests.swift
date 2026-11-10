import CoreGraphics
import Foundation
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoScreen

/// The input queue's link mode (a uu Link session in use): nothing waits for an answer; what comes in one turn of the
/// main actor goes at the end of it, in order, with pointer moves and one gesture's scroll deltas merged; moves take
/// the next `seq`; a send that throws is a failure at once; a way that stops being a link gets the rest as requests.
@MainActor
@Suite("Screen input queue, link mode")
struct LinkInputQueueTests {
    struct Overflow: Error {}

    @MainActor
    final class Link {
        var on = true
        var sent: [ScreenInput] = []
        var throwing = false
        var failures: [Error] = []
        var requests: [ScreenInput] = []

        func queue() -> ScreenInputQueue {
            ScreenInputQueue(send: { [weak self] input in await self?.request(input) },
                             failed: { [weak self] in self?.failures.append($0) },
                             link: { [weak self] in
                                 guard let self, self.on else { return nil }
                                 return { input in
                                     if self.throwing { throw Overflow() }
                                     self.sent.append(input)
                                 }
                             }, firstSeq: 100)
        }

        private func request(_ input: ScreenInput) { requests.append(input) }
    }

    private func settle(until done: () -> Bool = { false }) async {
        for _ in 0..<50 {
            if done() { return }
            await Task.yield()
        }
    }

    @Test func everythingGoesAtOnceInOrderWithoutWaitingForAnswers() async {
        let link = Link()
        let q = link.queue()
        q.send(.pointer(.down, display: 1, at: CGPoint(x: 0.1, y: 0.1)))
        q.send(ScreenInput(.key, display: 1, key: "a"))
        q.send(.pointer(.up, display: 1, at: CGPoint(x: 0.1, y: 0.1)))
        #expect(link.sent.isEmpty && q.outbox.count == 3, "they wait for the end of this turn")
        await settle { link.sent.count == 3 }
        #expect(link.sent.map(\.type) == [.down, .key, .up])
        // the next ones don't wait for anything either
        q.send(ScreenInput(.click, display: 1, x: 0.5, y: 0.5))
        await settle { link.sent.count == 4 }
        #expect(link.sent.last?.type == .click && link.requests.isEmpty)
    }

    @Test func movesMergeIntoTheLatestAndTakeTheNextSeq() async {
        let link = Link()
        let q = link.queue()
        for i in 1...5 { q.move(to: CGPoint(x: Double(i) / 10, y: 0.5), display: 1) }
        q.send(ScreenInput(.click, display: 1, x: 0.5, y: 0.5))
        q.move(to: CGPoint(x: 0.9, y: 0.9), display: 1)
        q.move(to: CGPoint(x: 0.8, y: 0.8), display: 1, button: .left)
        q.move(to: CGPoint(x: 0.7, y: 0.7), display: 1, button: .left)
        await settle { link.sent.count == 4 }
        #expect(link.sent.map(\.type) == [.move, .click, .move, .move])
        #expect(link.sent[0].x == 0.5, "five moves before the click: the latest only")
        #expect(link.sent[2].x == 0.9 && link.sent[2].button == nil, "a move after the click doesn't merge back past it")
        #expect(link.sent[3].x == 0.7 && link.sent[3].button == .left, "another button: its own, merged with its kind")
        #expect(link.sent.compactMap(\.seq) == [100, 101, 102], "moves take the next seq; others none")
    }

    @Test func oneGesturesScrollsMergeInItsPhases() async {
        let link = Link()
        let q = link.queue()
        let p = CGPoint(x: 0.5, y: 0.5)
        q.scroll(by: CGVector(dx: 0, dy: 1), at: p, display: 1, phase: .began)
        q.scroll(by: CGVector(dx: 0, dy: 2), at: p, display: 1, phase: .changed)
        q.scroll(by: CGVector(dx: 0, dy: 3), at: CGPoint(x: 0.6, y: 0.6), display: 1, phase: .changed)
        await settle { link.sent.count == 1 }
        #expect(link.sent.map(\.phase) == [.began] && link.sent[0].dy == 6 && link.sent[0].x == 0.6,
                "the changes before it went out merged into the began")
        q.scroll(by: CGVector(dx: 0, dy: 4), at: p, display: 1, phase: .changed)
        q.scroll(by: CGVector(dx: 0, dy: 5), at: p, display: 1, phase: .ended, velocity: CGVector(dx: 0, dy: 300))
        await settle { link.sent.count == 2 }
        #expect(link.sent[1].phase == .ended && link.sent[1].dy == 9 && link.sent[1].vy == 300,
                "the end takes the changes before it, and the velocity")
        // without a phase they add up as before
        q.scroll(by: CGVector(dx: 1, dy: 1), at: p, display: 1)
        q.scroll(by: CGVector(dx: 1, dy: 1), at: p, display: 1)
        q.scroll(by: CGVector(dx: 0, dy: 1), at: p, display: 2)
        await settle { link.sent.count == 4 }
        #expect(link.sent[2].dx == 2 && link.sent[2].dy == 2 && link.sent[3].display == 2, "another display: its own")
    }

    @Test func aSendThatThrowsIsAFailureAtOnce() async {
        let link = Link()
        let q = link.queue()
        link.throwing = true
        q.send(ScreenInput(.key, display: 1, key: "a"))
        await settle { !link.failures.isEmpty }
        #expect(link.failures.count == 1 && link.failures.first is Overflow)
    }

    @Test func cancelDropsWhatWaitsAndAWayThatIsNoLinkGetsRequests() async {
        let link = Link()
        let q = link.queue()
        q.send(ScreenInput(.key, display: 1, key: "a"))
        q.cancel()
        await settle()
        #expect(link.sent.isEmpty && q.outbox.isEmpty, "cancelled before the turn ended: nothing goes")
        // queued on the link, but the way changed before the turn ended: they go as requests, in order
        q.send(ScreenInput(.key, display: 1, key: "b"))
        q.send(ScreenInput(.key, display: 1, key: "c"))
        link.on = false
        await settle { link.requests.count == 2 }
        #expect(link.requests.map(\.key) == ["b", "c"] && link.sent.isEmpty)
    }

    @Test func mergingRules() {
        let a = ScreenInput.pointer(.move, display: 1, at: CGPoint(x: 0.1, y: 0.1))
        let b = ScreenInput.pointer(.move, display: 1, at: CGPoint(x: 0.2, y: 0.2))
        #expect(ScreenInputQueue.merge(a, b)?.x == 0.2)
        #expect(ScreenInputQueue.merge(a, .pointer(.move, display: 2, at: .zero)) == nil)
        #expect(ScreenInputQueue.merge(a, ScreenInput(.click, display: 1)) == nil)
        let began = ScreenInput(.scroll, display: 1, dx: 0, dy: 1, phase: .began)
        #expect(ScreenInputQueue.merge(began, ScreenInput(.scroll, display: 1, dx: 0, dy: 1, phase: .began)) == nil,
                "a new gesture is its own")
        #expect(ScreenInputQueue.merge(began, ScreenInput(.scroll, display: 1, dx: 0, dy: 1, phase: .ended)) == nil,
                "a began that hasn't gone goes alone before the end")
        #expect(ScreenInputQueue.merge(ScreenInput(.key, display: 1, key: "a"), ScreenInput(.key, display: 1, key: "a")) == nil,
                "discrete events never merge")
    }
}
