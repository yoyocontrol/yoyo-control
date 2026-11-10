#if os(macOS)
import Foundation

// `GET /audio` (docs/PROTOCOL.md 「屏幕」「声音」): this login session's sound as Opus, one 20 ms packet per part, in the
// same multipart framing as the video stream (`--frame`: StreamWire.swift; Content-Type,
// Content-Length, then part headers):
//
//     --frame\r\nContent-Type: audio/opus\r\nContent-Length: N\r\nX-Audio-Seq: 7\r\nX-Audio-Time: 1792725383971\r\n\r\n<N bytes>\r\n
//
// `X-Audio-Seq` counts the packets handed to this response (1, 2, …); one the client lost because it fell behind (its
// queue dropped the oldest) leaves a gap. `X-Audio-Time` is the Mac's wall clock (ms since 1970, the clock of the video
// stream's `X-Frame-Time`) of the packet's first decoded sample; the response head's `X-Audio-Video-Offset` (ms) added
// to it gives the `X-Frame-Time` a real display's picture of the same instant carries (AudioVideoOffset.swift). The
// capture itself (Core Audio process tap, one for every client) is AudioCapture.swift.

/// One encoded Opus packet (20 ms) as the capture hands it to the clients.
struct AudioPacket: Sendable, Equatable {
    /// The capture's packet number (0, 1, … since it started); not on the wire.
    var index: Int64
    /// Wall clock of its first sample, ms since 1970.
    var timeMs: Int64
    var data: Data
    /// The PCM it was encoded from was all zeros (no sound playing).
    var silent: Bool
}

enum AudioWire {
    static let sampleRate = 48_000
    static let channels = 2
    static let framesPerPacket = 960
    static let bitRate = 96_000

    /// The response head's headers (besides `Connection: close`). `cookie`: the encoder's magic cookie, if it has one;
    /// `videoOffsetMs`: `X-Audio-Video-Offset` (AudioVideoOffset.swift), fixed for the response.
    static func responseHeaders(cookie: Data?, videoOffsetMs: Int? = nil, wire: StreamWire = .current) -> [(String, String)] {
        var h: [(String, String)] = [
            ("Content-Type", wire.audio),
            ("Cache-Control", "no-cache"),
            ("X-Audio-Codec", "opus"),
            ("X-Audio-Rate", "\(sampleRate)"),
            ("X-Audio-Channels", "\(channels)"),
            ("X-Audio-Frames", "\(framesPerPacket)"),
        ]
        if let cookie, !cookie.isEmpty { h.append(("X-Audio-Cookie", cookie.base64EncodedString())) }
        if let videoOffsetMs { h.append(("X-Audio-Video-Offset", "\(videoOffsetMs)")) }
        return h
    }

    /// The bytes of one part.
    static func part(_ body: Data, seq: UInt64, timeMs: Int64, boundary: String = StreamWire.current.boundary) -> Data {
        let head = "--\(boundary)\r\nContent-Type: audio/opus\r\nContent-Length: \(body.count)\r\nX-Audio-Seq: \(seq)\r\nX-Audio-Time: \(timeMs)\r\n\r\n"
        var part = Data(head.utf8)
        part.reserveCapacity(part.count + body.count + 2)
        part.append(body)
        part.append(contentsOf: [13, 10])
        return part
    }

    /// `YOYO_AUDIO=off` (or 0 / false / no) turns `/audio` off: 503 "audio off".
    static func enabled(environment env: [String: String]) -> Bool {
        guard let v = env["YOYO_AUDIO"]?.trimmingCharacters(in: .whitespaces).lowercased() else { return true }
        return !["off", "0", "false", "no"].contains(v)
    }
}

/// One `/audio` client's packets, waiting for its (blocking) writes: at most `capacity` (~500 ms); a client that falls
/// behind loses its OLDEST packets. `X-Audio-Seq` is given here, on the way in, so a dropped packet leaves a gap.
/// `push` never blocks on the reader (the capture's encode thread calls it).
final class AudioClientQueue: @unchecked Sendable {
    struct Item: Equatable {
        var seq: UInt64
        var packet: AudioPacket
    }

    static let defaultCapacity = 25  // 25 × 20 ms

    let capacity: Int
    private let cond = NSCondition()
    private var items: [Item] = []
    private var head = 0  // items[head...] are queued (popped ones stay until compacted)
    private var nextSeq: UInt64 = 0
    private var closed = false
    private(set) var dropped = 0

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
        items.reserveCapacity(self.capacity * 2)
    }

    var count: Int {
        cond.lock()
        defer { cond.unlock() }
        return items.count - head
    }

    var droppedCount: Int {
        cond.lock()
        defer { cond.unlock() }
        return dropped
    }

    func push(_ packet: AudioPacket) {
        cond.lock()
        defer { cond.unlock() }
        guard !closed else { return }
        nextSeq &+= 1
        if items.count - head >= capacity {
            head += 1
            dropped += 1
        }
        if head >= capacity {
            items.removeFirst(head)
            head = 0
        }
        items.append(Item(seq: nextSeq, packet: packet))
        cond.signal()
    }

    /// Everything queued, oldest first; waits until `deadline` while empty ([] = nothing came, or closed).
    func popAll(until deadline: Date) -> [Item] {
        cond.lock()
        defer { cond.unlock() }
        while items.count == head && !closed {
            if !cond.wait(until: deadline) { break }
        }
        let out = Array(items[head...])
        items.removeAll(keepingCapacity: true)
        head = 0
        return out
    }

    /// Wakes a waiting reader for good (the capture stopped).
    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    var isClosed: Bool {
        cond.lock()
        defer { cond.unlock() }
        return closed
    }
}

/// Where the capture's samples are on the wall clock: anchored on the IO's host timestamps, then counted forward
/// (t0 + samples / rate) so packets are evenly spaced; re-anchored when the count and the host time disagree by more
/// than `maxDrift` (a dropped IO cycle, a clock that runs a little fast or slow).
struct AudioTimeline: Equatable {
    var sampleRate: Double
    var maxDriftMs: Double = 20
    /// Wall clock (ms) of input sample 0; nil before the first anchor.
    private(set) var originMs: Double?
    private(set) var reanchors = 0

    init(sampleRate: Double, maxDriftMs: Double = 20) {
        self.sampleRate = sampleRate
        self.maxDriftMs = maxDriftMs
    }

    /// The IO says input sample `sample` (counted from 0) was captured at `wallMs`. true = the timeline moved.
    @discardableResult
    mutating func note(sample: Int64, wallMs: Double) -> Bool {
        let origin = wallMs - Double(sample) / sampleRate * 1000
        guard let current = originMs else {
            originMs = origin
            return true
        }
        guard abs(origin - current) > maxDriftMs else { return false }
        originMs = origin
        reanchors += 1
        return true
    }

    /// Wall clock (ms) of input sample `sample`; nil before the first anchor.
    func wallMs(ofSample sample: Double) -> Double? {
        originMs.map { $0 + sample / sampleRate * 1000 }
    }

    /// `X-Audio-Time` of encoder packet `index`: the time of its first decoded sample. The encoder's output runs
    /// `primingFrames` behind its input (Opus: 312), so packet i decodes from output-rate sample i × frames − priming;
    /// in the input's time base that is the same instant.
    func packetTimeMs(index: Int64, framesPerPacket: Int, primingFrames: Int, outputRate: Double) -> Int64? {
        guard let originMs else { return nil }
        let firstSample = Double(index) * Double(framesPerPacket) - Double(primingFrames)
        return Int64((originMs + firstSample / outputRate * 1000).rounded())
    }
}

/// Host time (mach ticks, an AudioTimeStamp's mHostTime) → wall clock ms since 1970.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    static func nanos(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    }

    /// `hostTime` is in the past (or the near future) of `now`: the wall clock then.
    static func wallMs(hostTime: UInt64, nowHost: UInt64 = mach_absolute_time(), nowWallMs: Double = Date().timeIntervalSince1970 * 1000) -> Double {
        let ageMs = (nanos(nowHost) - nanos(hostTime)) / 1e6
        return nowWallMs - ageMs
    }
}

/// Peak level in dBFS (`-inf` for silence → -160), for the stats.
func audioDBFS(_ peak: Float) -> Double {
    peak > 0 ? max(-160, 20 * log10(Double(peak))) : -160
}

extension Router {
    static let audioEnabled = AudioWire.enabled(environment: ProcessInfo.processInfo.environment)

    /// `GET /audio`: the session's sound (see the top of this file). 503 before the head when the capture can't start
    /// (`YOYO_AUDIO=off`, no process-tap API, the tap or its device refused). Ends when the client hangs up.
    static func audio(_ req: HTTPRequest, _ conn: Connection) throws {
        guard audioEnabled else { throw HTTPError(503, "audio off") }
        let client = try AudioCapture.subscribe()
        defer { AudioCapture.unsubscribe(client) }
        guard conn.writeHead(status: 200, headers: AudioWire.responseHeaders(cookie: client.cookie,
                                                                                 videoOffsetMs: client.videoOffset.totalMs,
                                                                                 wire: conn.wire)) else { return }
        while !conn.peerClosed() {
            // wake at least every 0.5 s to notice a hung-up client
            let items = client.queue.popAll(until: Date().addingTimeInterval(0.5))
            if items.isEmpty && client.queue.isClosed { return }
            for item in items {
                guard conn.write(AudioWire.part(item.packet.data, seq: item.seq, timeMs: item.packet.timeMs, boundary: conn.wire.boundary)) else { return }
            }
        }
    }

    /// `GET /audio/stats`: the shared capture's counters (JSON).
    static func audioStats(_ conn: Connection) {
        var body = AudioCapture.statsJSON()
        body["enabled"] = audioEnabled
        conn.json(200, body)
    }
}
#endif
