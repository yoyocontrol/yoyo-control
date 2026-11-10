import CoreGraphics
import Foundation
import YoyoClipboard
import YoyoCore

/// The Screen page's input to the Mac, in order, one request at a time (each `POST /input` crosses a remote path
/// in 100–155 ms, a LAN in about 15), except pointer moves: up to `maxMovesInFlight` of those are on their way at once,
/// each with the next `seq` (the Mac drops one older than a move it already applied, PROTOCOL.md「屏幕」), so the
/// pointer follows the finger at more than one move per round trip. Scrolls and pointer moves never queue up behind each
/// other: they go on a merging lane with at most one scroll request (or `maxMovesInFlight` move requests) of it on its
/// way; meanwhile two-finger moves add up (`pendingScroll`) and pointer moves (a trackpad move, a live drag's held
/// moves) keep only the latest position (`pendingMove`), and when one returns (done or failed) what waits goes at once,
/// as one. A scroll after a move (or the other way round, or a move
/// with another button) sends what waited first, so the lane keeps their order. Other input (clicks, keys, text, a
/// drag's `down` / `up`) keeps its order and first sends the moves that came before it, and waits for every move on its
/// way to return (the page scrolls into place / the pointer gets there, then the click lands); so does a scroll after
/// moves. A two-finger gesture's phases keep their order too: a `began` starts
/// a merge of its own (marked `began`, worth sending however small; leftovers of an earlier gesture go first, as their
/// own request), `changed` moves add up into it (a merge not sent yet stays `began`), and `ended` (with the velocity
/// at lift) goes with the moves that waited, as one request, so momentum starts on the Mac as soon as they are out (a
/// separate end would come a round trip after them: a stop before the glide over a remote path); only a `began` that
/// hasn't gone yet goes on its own first. The Mac paces the moves and scrolls on with that velocity (momentum happens
/// there). Scrolls without a phase add up as they always did.
/// `cancel()` (the page closed or went to the background) drops what waits: nothing more goes to the Mac, a request
/// already sent is let go. Main actor; `send` may run anywhere.
///
/// **Link mode** (the way in use is a uu Link session: `link` gives its sender): nothing waits for an answer — the link
/// orders, repeats and acknowledges input itself (discrete events exactly once, the newest move wins). What comes in one
/// turn of the main actor goes out at the end of it, in order: pointer moves merge into the latest (same display and
/// button), and so do scroll deltas of one gesture (a `changed` into the `began` / `changed` before it, an `ended` into
/// a `changed`; scrolls without a phase add up as before). A refusal comes back later (`ScreenSession.onInputError`);
/// a send that throws (too many unacknowledged events: 429) goes to `failed` at once.
@MainActor
final class ScreenInputQueue {
    typealias Send = @Sendable (ScreenInput) async throws -> Void

    /// What the merging lane carries.
    enum MergeKind: Equatable {
        case scroll
        /// A pointer move (`button`: held, a live drag).
        case move(ScreenInput.Button?)
    }

    private struct Merge {
        var kind = MergeKind.scroll
        /// Scroll: what added up (display points).
        var delta = CGVector.zero
        /// Scroll: where; move: the latest position.
        var point = CGPoint(x: 0.5, y: 0.5)
        var display: UInt32?
        /// Move: one came since the last request took it.
        var hasMove = false
        /// Scroll: the gesture's phase (nil: a scroll without one).
        var phase: ScreenInput.ScrollPhase?
        /// Scroll, `ended`: the velocity at lift (display points per second).
        var velocity = CGVector.zero

        var worthSending: Bool {
            switch kind {
            case .scroll: phase == .began || phase == .ended || ScreenInputQueue.worthSending(delta)
            case .move: hasMove
            }
        }

        var input: ScreenInput? {
            guard worthSending else { return nil }
            switch kind {
            case .scroll:
                let end = phase == .ended
                return ScreenInput(.scroll, display: display, x: Double(point.x), y: Double(point.y),
                                   dx: Double(delta.dx), dy: Double(delta.dy), phase: phase,
                                   vx: end ? Double(velocity.dx) : nil, vy: end ? Double(velocity.dy) : nil)
            case let .move(button):
                return .pointer(.move, display: display, at: point, button: button)
            }
        }

        /// Taken by a request: the next one starts empty (same kind; a gesture that began goes on as `changed`).
        mutating func clear() {
            delta = .zero
            hasMove = false
            if phase == .began { phase = .changed }
        }
    }

    /// A merged request in line that hasn't started: until something else is queued behind it, it takes everything of
    /// its kind that comes (it is bound to what waited when it stops being the last in line).
    private final class Slot {
        var bound: Merge?
    }

    /// Pointer moves on their way at once (each with its `seq`; the Mac drops a stale one).
    nonisolated static let maxMovesInFlight = 3

    /// The link's sender for one input (it goes at once).
    typealias LinkSend = @MainActor (ScreenInput) throws -> Void

    private let send: Send
    private let failed: @MainActor (Error) -> Void
    /// The way in use's link sender (nil: HTTP requests, one at a time as above).
    private let link: @MainActor () -> LinkSend?
    /// Link mode: what goes out at the end of this turn of the main actor (merged as it comes).
    private(set) var outbox: [ScreenInput] = []
    private var flushScheduled = false
    /// The last request in line (each waits for the one before; a move's only until it has gone out).
    private var tail: Task<Void, Never>?
    /// Bumped by `cancel()`: what was queued before doesn't go.
    private var generation = 0
    /// Scrolls / moves not given to a request yet.
    private var pending = Merge()
    /// The merged request that is last in line and not started (what comes goes to it).
    private var openSlot: Slot?
    /// Merged requests (scrolls, moves) queued or on their way.
    private(set) var mergesOutstanding = 0
    /// Of those, pointer moves.
    private(set) var movesOutstanding = 0
    /// Pointer move requests sent and not answered yet.
    private(set) var movesInFlight = 0
    /// Requests waiting for moves on their way to return (resumed whenever one does, and by `cancel()`).
    private var moveWaiters: [CheckedContinuation<Void, Never>] = []
    /// The next move's `seq`: from the wall clock in ms when the queue is made, then one up per move (never reset), so
    /// a new visit's or another device's moves go on above the ones the Mac applied last.
    private(set) var nextSeq: Int
    /// When a failure was last reported (`failed`), and the clock.
    private var reportedAt: ContinuousClock.Instant?
    private let clock: @MainActor () -> ContinuousClock.Instant
    /// A failed move this soon after a reported failure isn't reported (up to `maxMovesInFlight` fail at once on a dead
    /// path: one toast); other input always is (a 409 on a click shows).
    nonisolated static let moveFailureQuiet: Duration = .seconds(1)

    /// Less than this (points, on both axes) is kept for the next move.
    nonisolated static let minScroll: CGFloat = 0.5

    /// `firstSeq`: the first move's `seq` (nil: the wall clock in ms); `clock`: for `moveFailureQuiet`.
    init(send: @escaping Send, failed: @escaping @MainActor (Error) -> Void,
         link: @escaping @MainActor () -> LinkSend? = { nil }, firstSeq: Int? = nil,
         clock: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.send = send
        self.failed = failed
        self.link = link
        nextSeq = firstSeq ?? Int(Date().timeIntervalSince1970 * 1000)
        self.clock = clock
    }

    /// Two-finger moves not sent yet (display points).
    var pendingScroll: CGVector { pending.kind == .scroll ? pending.delta : .zero }

    /// The pointer move not sent yet (nil: none).
    var pendingMove: CGPoint? {
        if case .move = pending.kind, pending.hasMove { return pending.point }
        return nil
    }

    /// Input other than a scroll or a move: in order, after the scrolls / moves that came before it.
    func send(_ input: ScreenInput) {
        if link() != nil {
            linkEnqueue(input)
            return
        }
        bindPending()
        enqueue(merged: false) { _ in input }
    }

    /// A two-finger move by `delta` (display points) at `point` (0…1), in its gesture's `phase` (nil: none);
    /// `velocity` (display points per second): the fingers' at lift, for `ended`.
    func scroll(by delta: CGVector, at point: CGPoint, display: UInt32?, phase: ScreenInput.ScrollPhase? = nil,
                velocity: CGVector = .zero) {
        if link() != nil {
            let end = phase == .ended
            linkEnqueue(ScreenInput(.scroll, display: display, x: Double(point.x), y: Double(point.y), dx: Double(delta.dx),
                                    dy: Double(delta.dy), phase: phase, vx: end ? Double(velocity.dx) : nil,
                                    vy: end ? Double(velocity.dy) : nil))
            return
        }
        switchLane(to: .scroll)
        switch phase {
        case .began?:
            // an earlier gesture's leftovers go first, as their own request; this one starts a merge of its own
            if pending.worthSending { bindPending() }
            pending.phase = .began
        case .changed?:
            if pending.phase == nil { pending.phase = .changed }
        case .ended?, nil:
            break
        }
        pending.delta.dx += delta.dx
        pending.delta.dy += delta.dy
        pending.point = point
        pending.display = display
        guard phase == .ended else {
            kick()
            return
        }
        // the fingers lifted
        if pending.phase == .began {
            // the gesture's start hasn't gone: it goes as it is (the Mac sees the gesture begin), then the end
            bindPending()
            let end = ScreenInput(.scroll, display: display, x: Double(point.x), y: Double(point.y), dx: 0, dy: 0,
                                  phase: .ended, vx: Double(velocity.dx), vy: Double(velocity.dy))
            enqueue(merged: false) { _ in end }
        } else {
            // the moves that waited go with the end, as one request (its open slot's, or one of its own)
            pending.phase = .ended
            pending.velocity = velocity
            bindPending()
        }
        pending = Merge()
    }

    /// The pointer to `point` (0…1); `button`: held (a live drag). Only the latest position waits.
    func move(to point: CGPoint, display: UInt32?, button: ScreenInput.Button? = nil) {
        if link() != nil {
            linkEnqueue(.pointer(.move, display: display, at: point, button: button))
            return
        }
        switchLane(to: .move(button))
        pending.point = point
        pending.display = display
        pending.hasMove = true
        kick()
    }

    /// Drops everything not sent yet (the page stopped).
    func cancel() {
        outbox = []
        flushScheduled = false
        generation += 1
        tail?.cancel()
        tail = nil
        pending = Merge()
        openSlot = nil
        mergesOutstanding = 0
        movesOutstanding = 0
        movesInFlight = 0
        wakeMoveWaiters()
    }

    nonisolated private static func worthSending(_ v: CGVector) -> Bool { abs(v.dx) >= minScroll || abs(v.dy) >= minScroll }

    // MARK: Link mode

    /// Into the outbox (merged with the last one when it can be), sent at the end of this turn.
    private func linkEnqueue(_ input: ScreenInput) {
        // what the request lane still holds goes first
        if let waiting = pending.input { outbox.append(waiting) }
        pending.clear()
        openSlot = nil
        if let last = outbox.last, let merged = Self.merge(last, input) {
            outbox[outbox.count - 1] = merged
        } else {
            outbox.append(input)
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        let generation = self.generation
        Task { [weak self] in
            guard let self, self.generation == generation else { return }
            self.flushLink()
        }
    }

    /// `next` folded into `last`, when both are of one move or one scroll gesture (nil: they go as two).
    nonisolated static func merge(_ last: ScreenInput, _ next: ScreenInput) -> ScreenInput? {
        guard last.display == next.display, last.type == next.type else { return nil }
        switch next.type {
        case .move:
            return last.button == next.button && last.modifiers == next.modifiers ? next : nil
        case .scroll:
            var m = last
            switch (last.phase, next.phase) {
            case (nil, nil), (.began?, .changed?), (.changed?, .changed?): break
            case (.changed?, .ended?):
                m.phase = .ended
                m.vx = next.vx
                m.vy = next.vy
            default: return nil
            }
            m.dx = (last.dx ?? 0) + (next.dx ?? 0)
            m.dy = (last.dy ?? 0) + (next.dy ?? 0)
            m.x = next.x
            m.y = next.y
            return m
        default:
            return nil
        }
    }

    /// Sends what waits, in order (moves take the next `seq`). A way that stopped being a link meanwhile gets them as
    /// requests instead.
    private func flushLink() {
        flushScheduled = false
        let items = outbox
        outbox = []
        guard !items.isEmpty else { return }
        guard let sendNow = link() else {
            for input in items { enqueue(merged: false) { _ in input } }
            return
        }
        for var input in items {
            if input.type == .move {
                input.seq = nextSeq
                nextSeq += 1
            }
            do { try sendNow(input) } catch { report(error, move: input.type == .move) }
        }
    }

    /// What waits goes into the line now (the open slot takes it, else a request of its own): what comes next is
    /// ordered after it.
    private func bindPending() {
        if let slot = openSlot {
            slot.bound = pending
            openSlot = nil
        } else if pending.worthSending {
            enqueueMerge(bound: pending)
        }
        pending.clear()
    }

    /// Another kind on the lane: what waited of the previous kind goes first.
    private func switchLane(to kind: MergeKind) {
        guard pending.kind != kind else { return }
        if pending.worthSending || openSlot != nil { bindPending() }
        pending = Merge()
        pending.kind = kind
    }

    /// Starts a merged request when none is in line or on its way (moves: while fewer than `maxMovesInFlight` are, and
    /// no scroll).
    private func kick() {
        guard openSlot == nil, pending.worthSending else { return }
        switch pending.kind {
        case .scroll:
            guard mergesOutstanding == 0 else { return }
        case .move:
            guard mergesOutstanding == movesOutstanding, movesOutstanding < Self.maxMovesInFlight else { return }
        }
        enqueueMerge(bound: nil)
    }

    /// `bound` nil: an open slot, which takes what waits when its turn comes.
    private func enqueueMerge(bound: Merge?) {
        let slot = Slot()
        slot.bound = bound
        if bound == nil { openSlot = slot }
        mergesOutstanding += 1
        let move = (bound ?? pending).kind != .scroll
        if move { movesOutstanding += 1 }
        enqueue(merged: true, move: move) { queue in
            var m: Merge
            if let bound = slot.bound {
                m = bound
            } else {
                m = queue.pending
                queue.pending.clear()
            }
            if queue.openSlot === slot { queue.openSlot = nil }
            return m.input
        }
    }

    /// One request in line. `make` runs when its turn comes (on the main actor) and returns what to send (nil: none).
    /// A move's turn comes once the request before it has gone out and fewer than `maxMovesInFlight` moves are on their
    /// way (the next in line may go as soon as it is sent); anything else's once every move on its way has returned.
    private func enqueue(merged: Bool, move: Bool = false, _ make: @escaping @MainActor (ScreenInputQueue) -> ScreenInput?) {
        let previous = tail
        let generation = self.generation
        let send = self.send
        tail = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            while self.generation == generation, self.movesInFlight >= (move ? Self.maxMovesInFlight : 1) {
                await withCheckedContinuation { self.moveWaiters.append($0) }
            }
            guard !Task.isCancelled, self.generation == generation else { return }
            var input = make(self)
            if move, input?.type == .move {
                input?.seq = self.nextSeq
                self.nextSeq += 1
            }
            guard move, let input else {
                await self.finish(input, merged: merged, move: move, generation: generation, send: send)
                return
            }
            // on its way: the next request in line may go
            self.movesInFlight += 1
            Task { await self.finish(input, merged: merged, move: true, generation: generation, send: send) }
        }
    }

    /// Sends `input` (nil: nothing) and, unless the page stopped meanwhile, lets what waited go.
    private func finish(_ input: ScreenInput?, merged: Bool, move: Bool, generation: Int, send: Send) async {
        var error: Error?
        if let input {
            do { try await send(input) } catch let e { error = e }
        }
        // the page stopped meanwhile: nothing more, not even the error
        guard self.generation == generation else { return }
        if move, input != nil {
            movesInFlight -= 1
            wakeMoveWaiters()
        }
        if merged {
            mergesOutstanding -= 1
            if move { movesOutstanding -= 1 }
            // what added up while it was on its way goes now, as one
            kick()
        }
        if let error { report(error, move: input?.type == .move) }
    }

    /// `failed`, unless a move fails within `moveFailureQuiet` of a reported failure.
    private func report(_ error: Error, move: Bool) {
        let now = clock()
        if move, let reportedAt, now - reportedAt < Self.moveFailureQuiet { return }
        reportedAt = now
        failed(error)
    }

    private func wakeMoveWaiters() {
        let waiters = moveWaiters
        moveWaiters = []
        for w in waiters { w.resume() }
    }
}
