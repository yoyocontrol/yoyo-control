import Foundation
import QuartzCore
import Synchronization
import YoyoClipboard
import YoyoCore

/// The picture stream on a uu Link session (`YoyoScreenLink`, docs/LINK.md「会话协议」) as the session runs any stream
/// (`ScreenStreamConnection`): `video.open` with `/stream`'s query, its pictures handed to the router as parts (no
/// multipart parser, no acks: the link's media layer repairs, orders and paces them), its status and cursor updates
/// likewise. The decoder's answers go back (`decoded`, through `ScreenVideoDecoder`'s `onDecoded`), and so do the
/// playout report every `ScreenStreamStats.reportEvery` and a key picture request. The link's round trip stands in for
/// the ack answers' (the touch budget, `ScreenStreamStats.freshRttMin`). Callbacks on the link's threads, in order.
final class ScreenLinkStream: ScreenStreamConnection, @unchecked Sendable {
    private let link: any YoyoScreenLink
    private let query: String
    private let stats: ScreenStreamStats
    private let onOpen: ScreenStream.OnOpen
    private let onPart: ScreenStream.OnPart
    private let onEnd: ScreenStream.OnEnd
    /// The link's round trip changed (the touch budget follows it).
    private let onRtt: @Sendable () -> Void
    private struct State {
        var video: (any YoyoLinkVideo)?
        var done = false
        var rttAt: Double?
    }
    private let state = Mutex(State())

    /// The round trip goes into the stats this often (seconds).
    static let rttEvery: Double = 1

    /// Where a stream cancelled from the main thread (the page stops, the stream moves) is closed on the link: the
    /// close calls into the link's core (its media lock, the stream's buffers let go) and needn't hold up the page.
    /// In order (one queue for the pictures and the sound).
    static let closing = DispatchQueue(label: "ca.sarria.yoyocontrol.screen-link-close", qos: .userInitiated)

    init(link: any YoyoScreenLink, query: String, stats: ScreenStreamStats, onOpen: @escaping ScreenStream.OnOpen,
         onPart: @escaping ScreenStream.OnPart, onEnd: @escaping ScreenStream.OnEnd, onRtt: @escaping @Sendable () -> Void = {}) {
        self.link = link
        self.query = query
        self.stats = stats
        self.onOpen = onOpen
        self.onPart = onPart
        self.onEnd = onEnd
        self.onRtt = onRtt
    }

    func start() {
        let video = link.openVideo(query: query) { [weak self] event in self?.handle(event) }
        let closeNow = state.withLock { s -> Bool in
            if s.done { return true }
            s.video = video
            return false
        }
        if closeNow { video.close() }
    }

    func cancel() {
        let video = state.withLock { s -> (any YoyoLinkVideo)? in
            s.done = true
            defer { s.video = nil }
            return s.video
        }
        // its events are ignored from here on (`done`)
        if let video { Self.closing.async { video.close() } }
    }

    /// Acks don't exist here: an ack request "fails" as a gone stream.
    func send(_ request: URLRequest, done: @escaping @Sendable (ScreenStreamReply) -> Void) { done(ScreenStreamReply(status: 404)) }

    /// The decoder took or failed on a picture of this stream.
    func decoded(_ part: ScreenStreamPart, ok: Bool) {
        guard let frame = part.linkFrame else { return }
        state.withLock { $0.video }?.decoded(frame: frame, ok: ok)
    }

    func requestKeyframe() { state.withLock { $0.video }?.requestKeyframe() }

    private func handle(_ event: YoyoLinkVideoEvent) {
        guard !state.withLock({ $0.done }) else { return }
        switch event {
        case let .opened(codec, _, _, headers):
            onOpen(codec ?? headers.first { $0.key.lowercased() == "x-stream-codec" }?.value)
        case .frame(let frame):
            let arrival = CACurrentMediaTime()
            stats.received(bytes: frame.au.count, at: arrival)
            stats.traceArrived(frame: frame.number, kind: frame.kind, bytes: frame.au.count, captureMs: frame.captureMs, at: arrival)
            onPart(ScreenStreamPart(link: frame))
            tick(at: arrival)
        case .status(let json):
            onPart(ScreenStreamPart(kind: .status, body: json, headers: ScreenPartHeaders(contentType: ScreenWire.statusType)))
        case .cursor(let json):
            onPart(ScreenStreamPart(kind: .cursor, body: json, headers: ScreenPartHeaders(contentType: ScreenWire.cursorType)))
        case let .error(status, message):
            finish(status == 401 ? YoyoError.unauthorized : YoyoError.http(status, message))
        case .closed:
            finish(nil)
        case .failed(let reason):
            finish(URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: reason]))
        }
    }

    /// With a picture: the playout report when one is due, and the link's round trip now and then.
    private func tick(at now: Double) {
        if let report = stats.takeReport(at: now) {
            // with every picture's way through this phone since the last one (the Mac's trace)
            var object = report.json
            object["frames"] = stats.takeFrameTrace(at: now)
            object["clock"] = ["hostMs": (now * 1e6).rounded() / 1000, "wallMs": Date().timeIntervalSince1970 * 1000]
            if let json = try? JSONSerialization.data(withJSONObject: object) { state.withLock { $0.video }?.report(json) }
        }
        let due = state.withLock { s -> Bool in
            guard s.rttAt.map({ now - $0 >= Self.rttEvery }) ?? true else { return false }
            s.rttAt = now
            return true
        }
        guard due, let rtt = link.rttMinMs else { return }
        stats.netQuality(ScreenNetQuality(grade: .unknown, rttMs: ScreenNetQuality.Rtt(min: rtt)), at: now)
        onRtt()
    }

    private func finish(_ error: Error?) {
        let first = state.withLock { s -> Bool in
            defer { s.done = true; s.video = nil }
            return !s.done
        }
        if first { onEnd(error) }
    }
}

/// The link stream the decoder answers to, until emptied (the stream holds the decoder: emptying it breaks the cycle).
final class ScreenLinkStreamRef: Sendable {
    private let value = Mutex<ScreenLinkStream?>(nil)
    init() {}
    var stream: ScreenLinkStream? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

extension ScreenStreamPart {
    /// A link's picture as the decoder takes a part: its codec, size, kind and capture time (`X-Frame-Time`), no seq
    /// (the link delivers them in order with their references intact: no gap to look for).
    init(link frame: YoyoLinkFrame) {
        let kind: Kind = frame.codec.lowercased() == "hevc" ? .hevc : .h264
        self.init(kind: kind, body: frame.au,
                  headers: ScreenPartHeaders(contentType: kind == .hevc ? "video/hevc" : "video/h264",
                                             width: frame.width > 0 ? frame.width : nil,
                                             height: frame.height > 0 ? frame.height : nil,
                                             kind: frame.kind, time: frame.captureMs, codec: frame.codec.lowercased()))
        linkFrame = frame.number
    }
}

/// The computer's sound on a uu Link session (`audio.open`): the format from `audio.opened` (as `/audio`'s headers),
/// each Opus packet decoded into the page's `ScreenAudioOutput` like `ScreenAudio`'s (a gap in `seq` is a lost packet,
/// filled as there). `onEnd` says why it ended by itself.
final class ScreenLinkAudio: ScreenAudioConnection, @unchecked Sendable {
    private struct State {
        var stream: (any YoyoLinkAudio)?
        var decoder: ScreenAudioDecoder?
        var token: Int?
        var offsetMs = ScreenAudioFormat.defaultVideoOffsetMs
        var stopped = false
    }

    private let link: any YoyoScreenLink
    private let query: String
    private let output: ScreenAudioOutput
    private let tuning: ScreenAudioTuning
    private let onEnd: ScreenAudio.OnEnd
    private let state = Mutex(State())

    init(link: any YoyoScreenLink, query: String, output: ScreenAudioOutput, tuning: ScreenAudioTuning,
         onEnd: @escaping ScreenAudio.OnEnd) {
        self.link = link
        self.query = query
        self.output = output
        self.tuning = tuning
        self.onEnd = onEnd
    }

    func start() {
        let stream = link.openAudio(query: query) { [weak self] event in self?.handle(event) }
        let closeNow = state.withLock { s -> Bool in
            if s.stopped { return true }
            s.stream = stream
            return false
        }
        if closeNow { stream.close() }
    }

    func stop() {
        let stream = state.withLock { s -> (any YoyoLinkAudio)? in
            s.stopped = true
            s.decoder = nil
            defer { s.stream = nil }
            return s.stream
        }
        // off the caller's thread, as the pictures' (`ScreenLinkStream.closing`)
        if let stream { ScreenLinkStream.closing.async { stream.close() } }
    }

    var videoOffsetMs: Double { state.withLock { $0.offsetMs } }

    var stats: ScreenAudio.Stats {
        let snap = output.snapshot()
        return ScreenAudio.Stats(buffer: snap.buffer, kbps: snap.kbps)
    }

    private func handle(_ event: YoyoLinkAudioEvent) {
        switch event {
        case .opened(let fields):
            let lookup: (String) -> String? = { name in fields.first { $0.key.lowercased() == name.lowercased() }?.value }
            let format = ScreenAudioFormat(lookup)
            let offset = ScreenAudioFormat.videoOffsetMs(lookup)
            let decoder = format.flatMap(ScreenAudioDecoder.init)
            guard let format, let decoder else {
                end(YoyoError.decoding("screen audio"))
                return
            }
            let go = state.withLock { s -> Bool in
                guard !s.stopped else { return false }
                s.decoder = decoder
                s.offsetMs = offset
                return true
            }
            guard go else { return }
            let token = output.begin(format: format, config: tuning.config(for: format),
                                     fadeIn: tuning.resumed ? ScreenAudioBuffer.resumeFadeIn : nil)
            state.withLock { $0.token = token }
        case let .packet(seq, timeMs, data):
            let (decoder, token) = state.withLock { s -> (ScreenAudioDecoder?, Int?) in
                s.stopped ? (nil, nil) : (s.decoder, s.token)
            }
            guard let decoder, let token, let samples = decoder.decode(data) else { return }
            output.push(token: token, seq: seq, macTime: timeMs / 1000, arrival: CACurrentMediaTime(), samples: samples,
                        bytes: data.count)
        case let .error(status, message):
            end(status == 401 ? YoyoError.unauthorized : YoyoError.http(status, message))
        case .closed:
            end(nil)
        case .failed(let reason):
            end(URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey: reason]))
        }
    }

    /// The stream ended by itself: what it left in the buffer fades out, and the session hears why.
    private func end(_ error: Error?) {
        let (first, token, stream) = state.withLock { s -> (Bool, Int?, (any YoyoLinkAudio)?) in
            defer { s.stopped = true; s.decoder = nil; s.stream = nil }
            return (!s.stopped, s.token, s.stream)
        }
        guard first else { return }
        stream?.close()
        if let token { output.end(token: token) }
        onEnd(error)
    }
}
