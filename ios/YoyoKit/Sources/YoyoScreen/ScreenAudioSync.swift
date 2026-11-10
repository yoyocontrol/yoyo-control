import Foundation
import Synchronization
import YoyoClipboard
import YoyoCore

/// The A/V sync's last output, for the reports made on the stream's queue.
final class ScreenAudioSyncBox: Sendable {
    private let box = Mutex(ScreenAVSync.Output())
    init() {}
    var value: ScreenAVSync.Output {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}

/// A/V sync on the Screen page (pure; the page runs it a few times a second). Every delay is phone clock − Mac clock
/// (seconds), for the same Mac instant: the sound's `X-Audio-Time` + `X-Audio-Video-Offset` is the `X-Frame-Time` a
/// real display's picture of that instant carries (the sound is stamped ~18 ms before it leaves the Mac's speaker, a
/// ScreenCaptureKit picture ~30 ms after it was on screen: 31 ms without the header).
///
/// - Sound: what plays now (`ScreenAudioBuffer.Stats.delay`; waiting: base + depth) + the output latency − the offset.
///   Its own delay leaves the A/V sync depth out (base + need + lead + output latency − offset).
/// - Picture: base + smooth depth + the playout's lead + one refresh (the display's own). `videoDelay` is the smooth
///   delay without the sync floor (what the video would do by itself); `shownDelay` the one in use (touch, floor).
/// - Skew = sound − picture (+ = the sound comes later; the report's `skewMs`).
///
/// The video waits for the sound while watching: not interactive, sound in the last 5 s and the sound
/// more than `videoEnter` later than the picture: the playout's `syncFloor` = that − `soundLater`, capped at
/// `maxVideoFloor` (the playout ramps to it). It stays engaged (following the skew) until the skew is under
/// `soundLater`, the sound has been silent, or it is turned off; interactive pictures get no floor (the playout drops it
/// at once) but it comes back with smooth playback. The sound never chases the video's touch drops: only when the
/// SMOOTH video delay is above the sound's own does the sound's delay goal become video + `soundLater` (the buffer
/// moves its depth there by at most 20 ms/s).
struct ScreenAVSync {
    static let videoEnter = 0.045
    static let soundLater = 0.015
    static let maxVideoFloor = 0.300
    /// Sound is "playing" when a packet with sound came this recently (seconds).
    static let silentAfter: Double = 5

    struct Input: Equatable {
        var audioDelay: Double?
        var audioOwnDelay: Double?
        var videoDelay: Double?
        var shownDelay: Double?
        var interactive = false
        var soundRecent = true
        /// Off: no A/V sync at all / the video never waits for the sound (both on in the app; tests turn them off).
        var enabled = true
        var videoFloorEnabled = true
    }

    struct Output: Equatable {
        /// The playout's `syncFloor` (seconds, 0: none).
        var videoFloor: Double = 0
        /// The sound's delay goal (nil: its own).
        var audioDelayGoal: Double?
        /// Sound − picture as shown (nil: not both known, or no sync here).
        var skew: Double?
    }

    /// The video floor is engaged.
    private(set) var engaged = false

    mutating func update(_ i: Input) -> Output {
        guard i.enabled, let a = i.audioDelay, let v = i.videoDelay else {
            engaged = false
            return Output()
        }
        var out = Output(skew: i.shownDelay.map { a - $0 } ?? a - v)
        let skew = a - v
        if !i.videoFloorEnabled || !i.soundRecent || skew <= Self.soundLater {
            engaged = false
        } else if !i.interactive, skew > Self.videoEnter {
            engaged = true
        }
        if engaged, !i.interactive { out.videoFloor = min(max(skew - Self.soundLater, 0), Self.maxVideoFloor) }
        if let own = i.audioOwnDelay, v > own { out.audioDelayGoal = v + Self.soundLater }
        return out
    }

    // MARK: Delays

    /// The sound's delay for the aligned time (nil: nothing known yet).
    static func audioDelay(_ b: ScreenAudioBuffer.Stats, outputLatency: Double, offset: Double) -> Double? {
        if let d = b.delay { return d + outputLatency - offset }
        return b.base.map { $0 + b.depth + outputLatency - offset }
    }

    /// The sound's own delay (without the sync depth) for the aligned time.
    static func audioOwnDelay(_ b: ScreenAudioBuffer.Stats, outputLatency: Double, offset: Double) -> Double? {
        b.base.map { $0 + b.need + b.lead + outputLatency - offset }
    }

    /// The buffer depth (lead included) that gives the sound `goal` as its delay.
    static func syncDepth(goal: Double, base: Double, outputLatency: Double, offset: Double) -> Double {
        goal + offset - outputLatency - base
    }

    /// The smooth video delay without the floor, and the one in use (nil: no smooth playout measured yet).
    static func videoDelays(_ p: ScreenStreamStats.Playout) -> (smooth: Double, shown: Double)? {
        guard let base = p.base, let depth = p.smoothDepth, let lead = p.lead else { return nil }
        return (base + depth + 2 * lead, base + p.hold + lead)
    }
}

/// The playout report's `audio` from the output's snapshots: counts since the previous report (a buffer that started
/// over counts from its own zero).
struct ScreenAudioReporter {
    private struct Counts: Equatable { var underruns = 0, late = 0, concealed = 0, cuts = 0, cutFrames = 0 }
    private var last: Counts?

    mutating func report(_ s: ScreenAudioOutput.Snapshot, skewMs: Double?, floorMs: Double?) -> ScreenAudioReport? {
        guard let b = s.buffer else { return nil }
        let now = Counts(underruns: b.underruns, late: b.late, concealed: b.concealed, cuts: b.cuts, cutFrames: b.cutFrames)
        var from = last ?? Counts()
        if now.underruns < from.underruns || now.late < from.late || now.concealed < from.concealed
            || now.cuts < from.cuts || now.cutFrames < from.cutFrames { from = Counts() }
        last = now
        let out = s.outputLatency ?? 0
        let playout = b.delay.flatMap { d in b.base.map { d - $0 } } ?? b.depth
        let cutMs = Double(now.cutFrames - from.cutFrames) / max(s.rate, 1) * 1000
        return ScreenAudioReport(
            outputMs: out * 1000, ioMs: (s.io ?? 0) * 1000, bluetooth: s.bluetooth, depthMs: b.need * 1000,
            bufferedMs: b.buffered * 1000, addedMs: (playout + out) * 1000, skewMs: skewMs, floorMs: floorMs,
            underruns: now.underruns - from.underruns, late: now.late - from.late,
            concealed: now.concealed - from.concealed, cuts: now.cuts - from.cuts,
            stretchMs: cutMs > 0 ? -cutMs : nil, kbps: s.kbps)
    }
}
