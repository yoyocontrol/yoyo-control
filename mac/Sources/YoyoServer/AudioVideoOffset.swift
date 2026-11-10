#if os(macOS)
import CoreAudio
import Foundation

// `X-Audio-Video-Offset` (docs/PROTOCOL.md「声音」): how much later a real display's video picture of an instant is
// stamped (`X-Frame-Time`) than the sound of the same instant (`X-Audio-Time`), in ms. The phone adds it to
// `X-Audio-Time` to line the sound up with the picture.
//
// - Measured 2026-10-25 (audio-perf-research.md in the research notes under data/tools): `X-Audio-Time` is 18.4 ms BEFORE the sample reaches
//   the Mac's speaker (avsync.swift, ±0.2 over 24 clicks): the tap sees a sample when it is mixed, the output device
//   plays it its latency later. `X-Frame-Time` of a ScreenCaptureKit display is later than the content appeared (the
//   stamp is `Date()` in the SCK callback): 13.7 ms by `SCStreamFrameInfo.displayTime` (median of 74 frames; a
//   coarser window-flip estimate said ~30). So the same instant is stamped ≈ 31 ms later on the picture.
// - tapToSpeaker (AudioOutputLatency): the default output device's `kAudioDevicePropertyLatency` + `SafetyOffset`
//   (output scope) + its first output stream's `kAudioStreamPropertyLatency`, frames → ms at its nominal rate; read
//   when a capture starts (logged then). 18 when unreadable (the built-in speakers' value). No `BufferFrameSize` term:
//   the tap stamps a sample at the output cycle's time, a buffer ahead of "now" already (on this Mac: latency 70 +
//   safety 74 + stream 690 = 834 frames = 17.4 ms against 18.1–19.0 measured; with the buffer it would be 28.0). Only
//   with the tap aggregate's default IO buffer: a smaller one shifts X-Audio-Time (AudioCapture.swift).
// - captureLatency (VideoCaptureLatency): running median of the last 120 (callback wall time − the frame's
//   `SCStreamFrameInfo.displayTime`) of the newest real-display ScreenCaptureKit stream (FrameStream); 14 (the value
//   measured on this Mac) before any in this process — the phone opens the sound with the picture, so the first
//   response usually comes before the first frame.
// - The header is fixed per `/audio` response (taken at subscribe).

/// The default output device's latency, in its parts (frames) — `ms` is what a sample takes from the tap to the
/// speaker.
struct AudioOutputLatency: Equatable, Sendable {
    var device: String
    var sampleRate: Double
    var latencyFrames: UInt32
    var safetyFrames: UInt32
    var streamFrames: UInt32

    /// The built-in speakers' measured value, when the properties can't be read.
    static let fallbackMs = 18.0

    var totalFrames: UInt32 { latencyFrames &+ safetyFrames &+ streamFrames }

    var ms: Double { sampleRate > 0 ? Double(totalFrames) / sampleRate * 1000 : Self.fallbackMs }

    /// `"MacBook Pro Speakers" 17.4 ms (latency 70 + safety 74 + stream 690 frames at 48000 Hz)`.
    var line: String {
        "\"\(device)\" " + String(format: "%.1f ms (latency %u + safety %u + stream %u frames at %.0f Hz)",
                                  ms, latencyFrames, safetyFrames, streamFrames, sampleRate)
    }

    /// The default output device's; nil when there is none or its rate / latency can't be read.
    static func readDefault() -> AudioOutputLatency? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        let out = kAudioObjectPropertyScopeOutput
        guard let rate: Float64 = property(device, kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal),
              rate > 0, let latency: UInt32 = property(device, kAudioDevicePropertyLatency, scope: out) else { return nil }
        let safety: UInt32 = property(device, kAudioDevicePropertySafetyOffset, scope: out) ?? 0
        var stream: UInt32 = 0
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: out, mElement: kAudioObjectPropertyElementMain)
        size = 0
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr, let first = ids.first {
                stream = property(first, kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal) ?? 0
            }
        }
        return AudioOutputLatency(device: name(device) ?? "device \(device)", sampleRate: rate, latencyFrames: latency,
                                  safetyFrames: safety, streamFrames: stream)
    }

    private static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr, size == UInt32(MemoryLayout<T>.size) else { return nil }
        return value.pointee
    }

    private static func name(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// The median of the last `capacity` samples (a ring; the median is computed when asked).
struct RunningMedian: Equatable, Sendable {
    let capacity: Int
    private(set) var samples: [Double] = []
    private var next = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        samples.reserveCapacity(self.capacity)
    }

    var count: Int { samples.count }

    mutating func add(_ v: Double) {
        if samples.count < capacity {
            samples.append(v)
        } else {
            samples[next] = v
        }
        next = (next + 1) % capacity
    }

    mutating func removeAll() {
        samples.removeAll(keepingCapacity: true)
        next = 0
    }

    /// nil without samples; the mean of the middle two for an even count.
    var median: Double? {
        guard !samples.isEmpty else { return nil }
        let s = samples.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

/// How long a ScreenCaptureKit frame takes from the display to our callback (where `X-Frame-Time` is stamped): the
/// newest real-display stream's (FrameStream) last 120 complete frames, median. A stream that starts becomes the one;
/// its first sample replaces the previous stream's.
final class VideoCaptureLatency: @unchecked Sendable {
    static let shared = VideoCaptureLatency()
    static let window = 120
    /// Before any real display was captured in this process.
    static let fallbackMs = 14.0
    /// Samples outside 0…this are ignored (a stale displayTime, a clock oddity).
    static let maxSampleMs = 1000.0

    private let lock = NSLock()
    private var owner: ObjectIdentifier?
    private var ownerSampled = false
    private var median = RunningMedian(capacity: window)

    /// A real-display stream started: from its first sample on, only its frames count.
    func begin(_ stream: ObjectIdentifier) {
        lock.lock()
        owner = stream
        ownerSampled = false
        lock.unlock()
    }

    /// A complete frame of `stream` (callback thread): `ms` = callback wall time − its displayTime.
    func note(_ stream: ObjectIdentifier, ms: Double) {
        guard ms.isFinite, ms >= 0, ms <= Self.maxSampleMs else { return }
        lock.lock()
        defer { lock.unlock() }
        guard stream == owner else { return }
        if !ownerSampled {
            ownerSampled = true
            median.removeAll()
        }
        median.add(ms)
    }

    /// The median (nil: no real display captured yet) and its sample count.
    var current: (ms: Double?, samples: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (median.median, median.count)
    }

    /// The median, or `fallbackMs`.
    var ms: Double { current.ms ?? Self.fallbackMs }
}

/// The parts of `X-Audio-Video-Offset`.
struct AudioVideoOffset: Equatable, Sendable {
    var tapToSpeakerMs: Double
    var captureLatencyMs: Double

    /// The header's integer (ms; may be negative in principle).
    var totalMs: Int { Int((tapToSpeakerMs + captureLatencyMs).rounded()) }

    var json: [String: Any] {
        ["tapToSpeakerMs": (tapToSpeakerMs * 10).rounded() / 10, "captureLatencyMs": (captureLatencyMs * 10).rounded() / 10,
         "totalMs": totalMs]
    }
}
#endif
