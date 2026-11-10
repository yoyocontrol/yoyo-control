import Foundation
import QuartzCore
import Synchronization
import YoyoClipboard
import YoyoCore

/// Sorts one stream's parts (on the stream's queue, in order): video pictures to a `ScreenVideoDecoder` (made on the first video part, for its codec), cursor parts to `onCursor`, status parts to
/// `onStatus`. Acks every whole picture part on receipt (before decoding; cursor and status parts only take a seq),
/// and tells the decoder about a gap in `X-Frame-Seq` (a lost part), so it waits for a key picture. A due playout
/// report (`ScreenStreamStats.takeReport`) rides the ack. `stop()` ends it all: no more acks, the decoder is
/// invalidated.
final class ScreenStreamRouter: Sendable {
    struct Handlers: Sendable {
        /// A video decoder for `codec` (nil: video isn't possible, the part is dropped).
        var makeDecoder: @Sendable (ScreenVideoCodec) -> ScreenVideoDecoder?
        var onCursor: @Sendable (ScreenCursorUpdate) -> Void
        /// A status part (the connection state of the stream's display); a malformed one is dropped.
        var onStatus: @Sendable (ScreenStreamStatus) -> Void = { _ in }
    }

    private struct State {
        var lastSeq: Int?
        var decoder: ScreenVideoDecoder?
        var stopped = false
    }

    let acks: ScreenAckSender?
    private let stats: ScreenStreamStats?
    private let handlers: Handlers
    private let state = Mutex(State())

    init(acks: ScreenAckSender?, stats: ScreenStreamStats?, handlers: Handlers) {
        self.acks = acks
        self.stats = stats
        self.handlers = handlers
    }

    /// `arrival`: when the part was complete (host time), before anything decodes it: the playout times pictures by it.
    func route(_ part: ScreenStreamPart, arrival: Double = CACurrentMediaTime()) {
        let (gap, stopped) = state.withLock { s -> (Bool, Bool) in
            guard !s.stopped else { return (false, true) }
            var gap = false
            if let seq = part.seq {
                if let last = s.lastSeq, seq != last + 1, seq > last { gap = true }
                if s.lastSeq.map({ seq > $0 }) ?? true { s.lastSeq = seq }
            }
            return (gap, false)
        }
        guard !stopped else { return }
        if gap { state.withLock { $0.decoder }?.gap() }
        if part.kind.isPicture, let seq = part.seq {
            if let acks, let report = stats?.takeReport(at: arrival) { acks.attach(report) }
            acks?.received(seq: seq)
        }
        switch part.kind {
        case .h264, .hevc:
            guard let codec = ScreenVideoCodec(part.kind), let decoder = decoder(for: codec) else { return }
            stats?.set(codec: codec.name)
            stats?.picture(live: part.isLivePicture, at: arrival)
            decoder.submit(part, arrival: arrival)
        case .cursor:
            if let update = ScreenCursorUpdate(json: part.body) { handlers.onCursor(update) }
        case .status:
            if let status = ScreenStreamStatus(json: part.body) { handlers.onStatus(status) }
        case .audio, .other:
            // sound comes on its own stream (`ScreenAudio`)
            break
        }
    }

    func stop() {
        let decoder = state.withLock { s -> ScreenVideoDecoder? in
            s.stopped = true
            defer { s.decoder = nil }
            return s.decoder
        }
        decoder?.invalidate()
        acks?.stop()
    }

    /// The decoder for `codec`; a part of another codec (the server switched) gets a fresh one.
    private func decoder(for codec: ScreenVideoCodec) -> ScreenVideoDecoder? {
        let (current, old) = state.withLock { s -> (ScreenVideoDecoder?, ScreenVideoDecoder?) in
            if let d = s.decoder, d.codec == codec { return (d, nil) }
            let old = s.decoder
            s.decoder = nil
            return (nil, old)
        }
        if let current { return current }
        old?.invalidate()
        guard let made = handlers.makeDecoder(codec) else { return nil }
        let kept = state.withLock { s -> Bool in
            guard !s.stopped else { return false }
            s.decoder = made
            return true
        }
        if !kept { made.invalidate(); return nil }
        return made
    }
}
