#if os(macOS)
import Foundation

/// What a link video frame is (the frame meta's `kind`, docs/LINK.md「数据报」).
enum LinkFrameKind: Equatable, Sendable {
    case delta, key, refine, keepalive
    /// Predicted from an acknowledged long-term reference (`base`) instead of the previous frame.
    case recovery(base: UInt32)
}

/// A link video stream's loss recovery on long-term references (docs/LINK.md「媒体」, VideoToolbox LTR): which frames
/// the receiver has (from `FrameDelivered`), which long-term reference to acknowledge to the encoder, and what the next
/// picture must be after a loss (`RecoveryNeeded`) or a decoder failure (`KeyframeNeeded`). Pure: the clock is passed
/// in; `Token` is VideoToolbox's opaque token (`VideoLTRToken`), anything in tests.
///
/// - A long-term reference counts as received when the newest delivered frame's reference chain runs through it: frames
///   are delivered in order and never with a broken chain, so with no chain restart after it the frame was decoded; a
///   recovery frame after it continues the chain at its base, a key frame ends it (the decoder drops its long-term
///   references at an IDR).
/// - Recovery: the next picture is encoded with ForceLTRRefresh and sent as kind recovery with base = the acknowledged
///   frame (at once); without one, or when VideoToolbox emits an IDR anyway, it is a key frame.
/// - Key frames at most one per `keyMinInterval` (as the HTTP path); a recovery frame is not one.
struct LinkRecoveryBook<Token> {
    static var keyMinInterval: TimeInterval { 0.5 }
    /// Long-term references remembered (the newest).
    static var maxTokens: Int { 32 }

    /// Long-term references sent since the last key frame, oldest first.
    private(set) var references: [(frame: UInt32, token: Token)] = []
    /// Where the chain restarts: key frames (base 0) and recovery frames (their base), oldest first.
    private var restarts: [(frame: UInt32, base: UInt32)] = []
    /// The newest long-term reference the receiver has: passed to every encode (`AcknowledgedLTRTokens`).
    private(set) var acknowledged: (frame: UInt32, token: Token)?
    private(set) var newestDelivered: UInt32 = 0
    private(set) var keyWanted = false
    private(set) var recoveryWanted = false
    private var lastKeyAt = -Double.infinity
    /// The picture being encoded was asked to refresh from `acknowledged` (its frame).
    private var refreshing: UInt32?

    /// The receiver decoded `frame` (the newest so far).
    mutating func delivered(_ frame: UInt32) {
        guard frame > newestDelivered else { return }
        newestDelivered = frame
        if let r = references.last(where: { $0.frame <= frame && inChain($0.frame, of: frame) }),
           r.frame > acknowledged?.frame ?? 0 {
            acknowledged = r
        }
    }

    /// The receiver lost a frame (`last`: its newest delivered one, if any).
    mutating func recoveryNeeded(lastDelivered last: UInt32?) {
        if let last { delivered(last) }
        recoveryWanted = true
    }

    /// The receiver's decoder can't go on (or a frame could not be sent): a key frame.
    mutating func keyNeeded() {
        keyWanted = true
    }

    /// The next picture must be encoded now even when unchanged: a recovery frame (any time), or a key frame (once the
    /// last one is `keyMinInterval` old).
    func refreshDue(at now: TimeInterval) -> Bool {
        if wantsKey { return now - lastKeyAt >= Self.keyMinInterval }
        return recoveryWanted
    }

    private var wantsKey: Bool { keyWanted || (recoveryWanted && acknowledged == nil) }

    /// The encode about to happen: a forced key frame, a refresh from the acknowledged reference, the tokens to
    /// acknowledge.
    mutating func plan(at now: TimeInterval) -> (forceKey: Bool, refresh: Bool, acknowledged: Token?) {
        refreshing = nil
        let ack = acknowledged?.token
        if wantsKey {
            return (now - lastKeyAt >= Self.keyMinInterval, false, ack)
        }
        if recoveryWanted, let a = acknowledged {
            refreshing = a.frame
            return (false, true, ack)
        }
        return (false, false, ack)
    }

    /// The kind of the picture just encoded (`kind`: what the loop made of it).
    func kind(isKey: Bool, loopKind: VideoPictureKind) -> LinkFrameKind {
        if isKey { return .key }
        if let base = refreshing { return .recovery(base: base) }
        switch loopKind {
        case .key, .delta: return .delta
        case .refine: return .refine
        case .keepalive: return .keepalive
        }
    }

    /// The picture went out as `frame`; `token`: it is a long-term reference.
    mutating func sent(frame: UInt32, kind: LinkFrameKind, token: Token?, at now: TimeInterval) {
        refreshing = nil
        switch kind {
        case .key:
            lastKeyAt = now
            keyWanted = false
            recoveryWanted = false
            references.removeAll()
            acknowledged = nil
            restarts = [(frame, 0)]
        case .recovery(let base):
            recoveryWanted = false
            restarts.append((frame, base))
            if restarts.count > Self.maxTokens { restarts.removeFirst(restarts.count - Self.maxTokens) }
        default:
            break
        }
        if let token {
            references.append((frame, token))
            if references.count > Self.maxTokens { references.removeFirst(references.count - Self.maxTokens) }
        }
    }

    /// Whether the decoder that showed `newest` also decoded `frame` (≤ newest), by the chain restarts in between.
    func inChain(_ frame: UInt32, of newest: UInt32) -> Bool {
        var current = newest
        while let r = restarts.last(where: { $0.frame > frame && $0.frame <= current }) {
            // a key frame after it (the chain starts afresh), or a recovery past it (frames between its base and it
            // may be gone)
            guard r.base != 0, r.base >= frame else { return false }
            current = r.base
        }
        // the oldest restart known: anything before the stream's first key frame is not
        return restarts.first.map { $0.frame <= frame } ?? false
    }
}
#endif
