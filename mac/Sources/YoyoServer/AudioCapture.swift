#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation

// The capture behind `GET /audio` (AudioStream.swift): this login session's system sound through a Core Audio process
// tap, encoded to Opus once for every client.
//
// - ScreenCaptureKit's `capturesAudio` delivers only zeros in a fast-user-switched (background) session; a process tap
//   does not. A global stereo tap of every process but this one (`CATapDescription(stereoGlobalTapButExcludeProcesses:)`,
//   unmuted: the session still plays as before), in a private TAP-ONLY aggregate device: an aggregate with the real
//   speaker as a sub-device hangs `AudioDeviceStart` forever in a background session. The samples are pre-volume: a
//   muted session still gives its sound.
// - macOS runs the tap's IO only while something plays (measured: its first buffer ~0.2–0.3 s after a sound starts,
//   and it stops a few seconds after the last one). Meanwhile the encode thread fills in silence (AudioRing.fillSilence),
//   so a client gets its 50 packets/s whatever plays (a long-idle stream doesn't look dead to the phone).
// - The IOProc only copies into a ring (no allocation, no client); a separate thread encodes 960-frame chunks with
//   AVAudioConverter (Opus, 48 kHz stereo, 96 kbit/s; one 20 ms packet per chunk, 3-byte packets for silence) and hands
//   each packet to every client's bounded queue (AudioClientQueue: a slow client loses its oldest packets).
// - Started by the first client, stopped 3 s after the last one leaves (a reopen right after a route switch reuses it).
// - Timestamps (`X-Audio-Time`): AudioTimeline — t0 + samples / rate, anchored on the IO's host times. Each response
//   also says how much later a real display's picture of the same instant is stamped (`X-Audio-Video-Offset`,
//   AudioVideoOffset.swift: the output device's latency, read at the start, + ScreenCaptureKit's capture latency).
// - The private aggregate keeps the device's default IO buffer (512 frames = 10.7 ms here). Measured 2026-10-25 at the
//   helper's socket (music) against smaller ones (an experiment switch, since removed), arrival − X-Audio-Time:
//   default min 41 / p50 47 / p95 53 ms, jitter p95 11.5; 256 frames min 26 / p50 29 / p95 33, jitter p95 6.8. But a
//   buffer smaller than the output device's (128 and 256 alike) moves the tap's time stamps ~16.7 ms later
//   (X-Audio-Time ~2.3 ms before the speaker instead of ~19, avsync clicks): the real gain is ~1–5 ms, the jitter gain
//   doesn't matter behind the phone's playout floor, it costs ~+0.8 % CPU, and AudioOutputLatency (X-Audio-Video-
//   Offset) would no longer describe X-Audio-Time → speaker. Hence the default.
// - Stats in `GET /audio/stats`; a log line every 10 s while clients are connected.
// - A coreaudiod restart is the host's call (AudioServiceWatch: yoyo-control exits, a host without the hook rebuilds the capture);
//   while it runs, AudioDeafWatchdog (AudioWatchdog.swift, both) notices when this process's taps hear nothing at all (exact zeros while
//   others play, and a fresh test sound unheard) and hands over the same way.
// - TCC (kTCCServiceAudioCapture, NSAudioCaptureUsageDescription in the host app's Info.plist): the first
//   `AudioDeviceStart` of an app asks, and blocks until it is answered. In a background session nobody sees the prompt:
//   it is cancelled after ~10 s and tccd records a refusal (auth reason 13). On macOS 27 (2026-10-24) the tap still
//   delivers the session's sound after that, for Yoyo Control.app as for a plain binary; a later macOS may enforce it, so
//   a grant (System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only)
//   is the safe state.

final class AudioCapture: @unchecked Sendable {
    /// One `/audio` response's handle.
    final class Client: @unchecked Sendable {
        let queue = AudioClientQueue()
        /// The encoder's magic cookie (`X-Audio-Cookie`).
        let cookie: Data?
        /// `X-Audio-Video-Offset`'s parts, as they were when it subscribed.
        let videoOffset: AudioVideoOffset
        init(cookie: Data?, videoOffset: AudioVideoOffset) {
            self.cookie = cookie
            self.videoOffset = videoOffset
        }
    }

    static let lingerSeconds: TimeInterval = 3
    static let statsInterval: TimeInterval = 10
    static let ioWatchdog: TimeInterval = 5
    /// After a coreaudiod restart a new capture waits this long from the notification (the server is still coming up).
    static let serviceRestartSettle: TimeInterval = 1
    // MARK: - The shared capture

    private static let registry = NSLock()
    nonisolated(unsafe) private static var current: AudioCapture?
    nonisolated(unsafe) private static var pendingStop: DispatchWorkItem?
    nonisolated(unsafe) private static var starts = 0
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var lastError: String?
    nonisolated(unsafe) private static var lastStats: [String: Any]?
    /// The latest capture's output latency (`videoOffset` in the stats after it stopped).
    nonisolated(unsafe) private static var lastTapToSpeakerMs: Double?
    /// No new capture before this (a coreaudiod restart just tore one down).
    nonisolated(unsafe) private static var holdUntil: Date?

    /// A new client of the shared capture, starting it if needed (on this thread; concurrent first clients wait for the
    /// one start). Throws a 503 HTTPError when it can't start.
    static func subscribe() throws -> Client {
        registry.lock()
        let hold = holdUntil.map { $0.timeIntervalSinceNow } ?? 0
        registry.unlock()
        if hold > 0 { Thread.sleep(forTimeInterval: hold) }
        registry.lock()
        defer { registry.unlock() }
        pendingStop?.cancel()
        pendingStop = nil
        if current == nil {
            do {
                current = try AudioCapture()
                starts += 1
                lastError = nil
                AudioServiceWatch.install()
                lastTapToSpeakerMs = current!.tapToSpeakerMs
            } catch let e as HTTPError {
                failures += 1
                lastError = e.message
                log("audio: cannot start: \(e.message)")
                throw e
            }
        }
        return current!.add()
    }

    /// The client's response ended; the last one out stops the capture `lingerSeconds` later (unless a client comes).
    static func unsubscribe(_ client: Client) {
        registry.lock()
        defer { registry.unlock() }
        client.queue.close()
        guard let capture = current, capture.remove(client) == 0 else { return }
        let work = DispatchWorkItem {
            registry.lock()
            guard current === capture, capture.clientCount == 0 else { registry.unlock(); return }
            current = nil
            pendingStop = nil
            registry.unlock()
            capture.stop()
            registry.lock()
            lastStats = capture.statsJSON()
            registry.unlock()
        }
        pendingStop = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + lingerSeconds, execute: work)
    }

    static func statsJSON() -> [String: Any] {
        registry.lock()
        let capture = current
        var body: [String: Any] = ["running": capture != nil, "starts": starts, "failures": failures,
                                   "lastError": lastError ?? NSNull()]
        let last = lastStats
        registry.unlock()
        if let capture { body["capture"] = capture.statsJSON() } else if let last { body["last"] = last }
        body["serviceRestarts"] = AudioServiceWatch.restarts
        body["watchdog"] = AudioDeafWatchdog.shared.statsJSON()
        registry.lock()
        let tapToSpeaker = capture?.tapToSpeakerMs ?? lastTapToSpeakerMs
        registry.unlock()
        body["videoOffset"] = AudioVideoOffset(tapToSpeakerMs: tapToSpeaker ?? AudioOutputLatency.fallbackMs,
                                               captureLatencyMs: VideoCaptureLatency.shared.ms).json
        return body
    }

    /// coreaudiod restarted and the host has no hook (AudioServiceWatch): the capture's tap and device
    /// are gone with the old server, so stop it now. Its clients' responses end and they reopen at once (the phone does,
    /// after a stream that lived a while); their `subscribe` builds a new capture `serviceRestartSettle` after this.
    static func serviceRestarted() {
        tearDown(reason: "a Core Audio restart")
    }

    /// Stop the running capture now (`reason` for the log): a coreaudiod restart, or the watchdog found this process
    /// deaf (no hook). Its clients reopen into a new one, built `serviceRestartSettle` after this.
    static func tearDown(reason: String) {
        registry.lock()
        let capture = current
        current = nil
        pendingStop?.cancel()
        pendingStop = nil
        holdUntil = Date().addingTimeInterval(serviceRestartSettle)
        registry.unlock()
        guard let capture else { return }
        let n = capture.clientCount
        capture.stop()
        registry.lock()
        lastStats = capture.statsJSON()
        registry.unlock()
        log("audio: capture torn down after \(reason) (\(n) client\(n == 1 ? "" : "s") will reopen)")
    }

    // MARK: - One capture

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ring: AudioRing
    private let wake: DispatchSemaphore
    private let encoder: OpusPacketEncoder
    private let inputRate: Double
    let tapFormat: String
    /// The default output device's latency at the start (nil: unreadable; then `AudioOutputLatency.fallbackMs`).
    let output: AudioOutputLatency?
    var tapToSpeakerMs: Double { output?.ms ?? AudioOutputLatency.fallbackMs }

    private let lock = NSLock()
    private var clients: [Client] = []
    private var running = true
    private var stats = Stats()
    private let startedAt = Date()
    private let startedUptime = ProcessInfo.processInfo.systemUptime

    private struct Stats {
        var packets = 0
        var bytes = 0
        var silentPackets = 0
        /// Packets dropped from clients that have left (the live ones' are in their queues).
        var leftDrops = 0
        var peak: Float = 0
        var peakWindow: Float = 0
        var firstIOAt: Date?
        var firstSoundAt: Date?
        /// The latest packet with a sample that wasn't zero (ProcessInfo.systemUptime), for the watchdog.
        var lastSoundUptime: TimeInterval?
        var reanchors = 0
        // the last 10 s, for the log line
        var windowPackets = 0
        var windowBytes = 0
    }

    private init() throws {
        guard #available(macOS 14.2, *) else { throw HTTPError(503, "audio needs macOS 14.2 or later (Core Audio process taps)") }
        var tap = AudioObjectID(kAudioObjectUnknown), aggregate = AudioObjectID(kAudioObjectUnknown)
        var proc: AudioDeviceIOProcID?
        let wake = DispatchSemaphore(value: 0)
        let format: AudioStreamBasicDescription, encoder: OpusPacketEncoder, ring: AudioRing
        do {
            let made = try Self.makeTap()
            tap = made.id
            format = try Self.tapFormat(tap)
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
                throw HTTPError(503, "unsupported tap format \(Self.describe(format))")
            }
            guard let e = OpusPacketEncoder(inputRate: format.mSampleRate) else {
                throw HTTPError(503, "no Opus encoder for \(Self.describe(format))")
            }
            encoder = e
            ring = AudioRing(capacityFrames: Int(format.mSampleRate), sampleRate: format.mSampleRate)  // 1 s
            ring.wake = wake
            aggregate = try Self.makeAggregate(tapUID: made.uid)
            var status = AudioDeviceCreateIOProcID(aggregate, audioIOProc, Unmanaged.passUnretained(ring).toOpaque(), &proc)
            guard status == noErr, let proc else { throw HTTPError(503, "AudioDeviceCreateIOProcID failed (\(Self.osStatus(status)))") }
            status = AudioDeviceStart(aggregate, proc)
            guard status == noErr else { throw HTTPError(503, "AudioDeviceStart failed (\(Self.osStatus(status)))") }
        } catch {
            Self.destroy(tap: tap, aggregate: aggregate, proc: proc)
            throw error
        }
        tapID = tap
        aggregateID = aggregate
        procID = proc
        self.wake = wake
        self.encoder = encoder
        self.ring = ring
        inputRate = format.mSampleRate
        tapFormat = Self.describe(format)
        output = AudioOutputLatency.readDefault()
        log("audio: capture started (tap \(tapFormat), Opus \(AudioWire.bitRate / 1000) kbit/s, priming \(encoder.primingFrames))")
        let capture = VideoCaptureLatency.shared.current
        let offset = AudioVideoOffset(tapToSpeakerMs: output?.ms ?? AudioOutputLatency.fallbackMs,
                                      captureLatencyMs: capture.ms ?? VideoCaptureLatency.fallbackMs)
        log("audio: A/V offset \(offset.totalMs) ms = tap→speaker "
            + (output.map { $0.line } ?? String(format: "%.0f ms (default: the output device's latency is unreadable)", AudioOutputLatency.fallbackMs))
            + " + capture " + (capture.ms.map { String(format: "%.1f ms (median of %d frames)", $0, capture.samples) }
                ?? String(format: "%.0f ms (default: no real display captured yet)", VideoCaptureLatency.fallbackMs)))
        AudioTapCheckCache.shared.reset()  // a new capture's taps are checked afresh
        AudioDeafWatchdog.shared.start(for: ObjectIdentifier(self)) { [weak self] in self?.zeroSince }
        let thread = Thread { [self] in encodeLoop() }
        thread.name = "yoyo-audio-encode"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        Self.destroy(tap: tapID, aggregate: aggregateID, proc: procID)
    }

    var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }

    /// Since when (ProcessInfo.systemUptime) every sample has been zero: the start, or the latest sound.
    var zeroSince: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return max(startedUptime, stats.lastSoundUptime ?? 0)
    }

    private func add() -> Client {
        let c = Client(cookie: encoder.cookie,
                       videoOffset: AudioVideoOffset(tapToSpeakerMs: tapToSpeakerMs, captureLatencyMs: VideoCaptureLatency.shared.ms))
        lock.lock()
        clients.append(c)
        let n = clients.count
        lock.unlock()
        log("audio: client connected (\(n) now)")
        return c
    }

    /// The clients left.
    private func remove(_ client: Client) -> Int {
        lock.lock()
        clients.removeAll { $0 === client }
        stats.leftDrops += client.queue.droppedCount
        let n = clients.count
        lock.unlock()
        log("audio: client left (\(n) now; it lost \(client.queue.droppedCount) packets)")
        return n
    }

    private func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        let left = clients
        clients = []
        lock.unlock()
        guard wasRunning else { return }
        AudioDeafWatchdog.shared.stop(for: ObjectIdentifier(self))
        wake.signal()
        if let procID { AudioDeviceStop(aggregateID, procID) }
        Self.destroy(tap: tapID, aggregate: aggregateID, proc: procID)
        procID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        for c in left { c.queue.close() }
        log("audio: capture stopped after \(Int(Date().timeIntervalSince(startedAt))) s")
    }

    // MARK: - Encoding

    private func encodeLoop() {
        let chunk = AudioWire.framesPerPacket
        var timeline = AudioTimeline(sampleRate: inputRate)
        var left = [Float](repeating: 0, count: chunk), right = [Float](repeating: 0, count: chunk)
        var packetIndex: Int64 = 0
        var lastLog = Date()
        var sawIO = false, warnedNoIO = false
        while true {
            // the IO wakes this every buffer (~10 ms) while something plays; else every 10 ms, for the silence
            _ = wake.wait(timeout: .now() + 0.01)
            lock.lock()
            let live = running
            lock.unlock()
            guard live else { break }
            ring.fillSilence(nowHost: mach_absolute_time())
            if let anchor = ring.takeAnchor(),
               timeline.note(sample: anchor.frame, wallMs: HostClock.wallMs(hostTime: anchor.hostTime)), timeline.reanchors > 0 {
                lock.lock()
                stats.reanchors = timeline.reanchors
                lock.unlock()
            }
            if !sawIO, ring.callbacks > 0 {
                sawIO = true
                lock.lock()
                stats.firstIOAt = Date()
                lock.unlock()
                let layout = ring.layout
                log("audio: first IO after \(String(format: "%.2f", Date().timeIntervalSince(startedAt))) s (\(layout.buffers) buffer(s) × \(layout.channels) ch)")
            }
            while ring.read(left: &left, right: &right, frames: chunk) {
                var peak: Float = 0
                for i in 0..<chunk { peak = max(peak, abs(left[i]), abs(right[i])) }
                for data in encoder.encode(left: left, right: right) {
                    guard let timeMs = timeline.packetTimeMs(index: packetIndex, framesPerPacket: AudioWire.framesPerPacket,
                                                             primingFrames: encoder.primingFrames,
                                                             outputRate: Double(AudioWire.sampleRate)) else { continue }
                    let packet = AudioPacket(index: packetIndex, timeMs: timeMs, data: data, silent: peak == 0)
                    packetIndex += 1
                    deliver(packet, peak: peak)
                }
            }
            let now = Date()
            if !sawIO, !warnedNoIO, now.timeIntervalSince(startedAt) > Self.ioWatchdog {
                warnedNoIO = true
                log("audio: no samples from the tap \(Int(Self.ioWatchdog)) s after start (macOS runs it only while something"
                    + " plays); sending silence meanwhile")
            }
            if now.timeIntervalSince(lastLog) >= Self.statsInterval {
                logWindow(seconds: now.timeIntervalSince(lastLog))
                lastLog = now
            }
        }
    }

    private func deliver(_ packet: AudioPacket, peak: Float) {
        lock.lock()
        stats.packets += 1
        stats.bytes += packet.data.count
        stats.windowPackets += 1
        stats.windowBytes += packet.data.count
        if packet.silent { stats.silentPackets += 1 }
        stats.peak = max(stats.peak, peak)
        stats.peakWindow = max(stats.peakWindow, peak)
        if peak > 0 { stats.lastSoundUptime = ProcessInfo.processInfo.systemUptime }
        if peak > 0, stats.firstSoundAt == nil {
            stats.firstSoundAt = Date()
            log("audio: first sound \(String(format: "%.2f", Date().timeIntervalSince(startedAt))) s after start")
        }
        let targets = clients
        lock.unlock()
        for c in targets { c.queue.push(packet) }
    }

    private func logWindow(seconds: TimeInterval) {
        lock.lock()
        let n = clients.count
        let drops = stats.leftDrops + clients.reduce(0) { $0 + $1.queue.droppedCount }
        let packets = stats.windowPackets, bytes = stats.windowBytes, peak = stats.peakWindow
        stats.windowPackets = 0
        stats.windowBytes = 0
        stats.peakWindow = 0
        lock.unlock()
        guard n > 0 else { return }
        log("audio: \(n) client\(n == 1 ? "" : "s"), \(packets) packets in \(Int(seconds.rounded())) s"
            + " (\(String(format: "%.1f", Double(bytes) * 8 / seconds / 1000)) kbit/s), \(drops) dropped,"
            + " peak \(String(format: "%.1f", audioDBFS(peak))) dBFS, ring overflow \(ring.overflowFrames) frames")
    }

    func statsJSON() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let drops = stats.leftDrops + clients.reduce(0) { $0 + $1.queue.droppedCount }
        let uptime = Date().timeIntervalSince(startedAt)
        return [
            "clients": clients.count,
            "packets": stats.packets,
            "bytes": stats.bytes,
            "silentPackets": stats.silentPackets,
            "drops": drops,
            "queued": clients.map(\.queue.count),
            "peakDBFS": audioDBFS(stats.peak),
            "peakLast10sDBFS": audioDBFS(stats.peakWindow),
            "kbps": uptime > 0 ? Double(stats.bytes) * 8 / uptime / 1000 : 0,
            "uptimeSeconds": uptime,
            "firstIOSeconds": stats.firstIOAt.map { $0.timeIntervalSince(startedAt) } ?? NSNull(),
            "firstSoundSeconds": stats.firstSoundAt.map { $0.timeIntervalSince(startedAt) } ?? NSNull(),
            "reanchors": stats.reanchors,
            "ringOverflowFrames": ring.overflowFrames,
            "ioCallbacks": ring.callbacks,
            "silenceFrames": ring.silenceFrames,
            "tapFormat": tapFormat,
            "primingFrames": encoder.primingFrames,
            "bitRate": AudioWire.bitRate,
            "zeroSeconds": ((ProcessInfo.processInfo.systemUptime - max(startedUptime, stats.lastSoundUptime ?? 0)) * 10).rounded() / 10,
            "outputDevice": output?.device ?? NSNull(),
        ]
    }

    // MARK: - Core Audio

    @available(macOS 14.2, *)
    private static func makeTap() throws -> (id: AudioObjectID, uid: String) {
        var exclude: [AudioObjectID] = []
        if let me = ownProcessObject() { exclude.append(me) }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.name = "Yoyo Control audio"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw HTTPError(503, "cannot create the audio tap (\(osStatus(status)))")
        }
        return (id, description.uuid.uuidString)
    }

    /// This process's Core Audio process object (nil while it has none: it never touched audio).
    private static func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw HTTPError(503, "cannot read the tap's format (\(osStatus(status)))") }
        return asbd
    }

    /// A private aggregate device with only the tap in it (no main / sub device: see the top of this file).
    static func makeAggregate(tapUID: String, name: String = "Yoyo Control audio tap",
                              uidPrefix: String = "ca.sarria.yoyocontrol.audio-tap") throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "\(uidPrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw HTTPError(503, "cannot create the tap's aggregate device (\(osStatus(status)))")
        }
        return id
    }

    static func destroy(tap: AudioObjectID, aggregate: AudioObjectID, proc: AudioDeviceIOProcID?) {
        if aggregate != kAudioObjectUnknown {
            if let proc { AudioDeviceDestroyIOProcID(aggregate, proc) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown, #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
    }

    static func describe(_ d: AudioStreamBasicDescription) -> String {
        let interleaved = d.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let float = d.mFormatFlags & kAudioFormatFlagIsFloat != 0
        return "\(Int(d.mSampleRate)) Hz \(d.mChannelsPerFrame) ch \(float ? "float" : "int")\(d.mBitsPerChannel)\(interleaved ? " interleaved" : "")"
    }

    /// An OSStatus as its four-character code when it is one, else the number.
    static func osStatus(_ s: OSStatus) -> String {
        let u = UInt32(bitPattern: s)
        let bytes = [UInt8(u >> 24 & 0xff), UInt8(u >> 16 & 0xff), UInt8(u >> 8 & 0xff), UInt8(u & 0xff)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) { return "'\(String(decoding: bytes, as: UTF8.self))'" }
        return "\(s)"
    }
}

/// The IOProc: copy the tap's samples into the ring and wake the encode thread. Runs on Core Audio's real-time thread:
/// no allocation, no lock but the ring's short one, no client.
private func audioIOProc(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>, _ input: UnsafePointer<AudioBufferList>,
                         _ inputTime: UnsafePointer<AudioTimeStamp>, _ output: UnsafeMutablePointer<AudioBufferList>,
                         _ outputTime: UnsafePointer<AudioTimeStamp>, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { return noErr }
    let ring = Unmanaged<AudioRing>.fromOpaque(context).takeUnretainedValue()
    let host = inputTime.pointee.mFlags.contains(.hostTimeValid) ? inputTime.pointee.mHostTime : mach_absolute_time()
    ring.write(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), hostTime: host)
    ring.wake?.signal()
    return noErr
}

/// Two channels of Float32 PCM between the IOProc (writer) and the encode thread (reader). Interleaved or not, mono or
/// more channels on the way in; always stereo planes on the way out. A reader more than a second behind loses the
/// oldest samples (`overflowFrames`). Each write also leaves where it started (an anchor for the timeline: the frame in
/// the reader's count, and its host time).
///
/// macOS runs a tap's IO only while something plays. While it is idle the encode thread fills in silence
/// (`fillSilence`), trailing the clock by 25 ms (the IO hands its buffers over ~10 ms after their first sample) so that
/// IO resuming lands after it (a forward jump the timeline re-anchors on), not on top of it: the stream keeps its 50
/// packets/s whatever plays, and silence arrives about as late as sound.
final class AudioRing: @unchecked Sendable {
    let capacity: Int
    /// Host ticks per frame.
    let ticksPerFrame: Double
    private let ticksPerSecond: Double
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var lockStorage = os_unfair_lock_s()
    private var written: Int64 = 0  // frames ever written
    private var readPos: Int64 = 0  // frames ever consumed or skipped
    private var skipped: Int64 = 0
    private var anchor: (frame: Int64, hostTime: UInt64)?
    /// Host time where the data written so far ends (nil before the first write).
    private var endHost: UInt64?
    /// Host time of the latest IO buffer.
    private var lastIOHost: UInt64 = 0
    private var _callbacks = 0
    private var _silenceFrames: Int64 = 0
    private var _layout = (buffers: 0, channels: 0)
    var wake: DispatchSemaphore?

    init(capacityFrames: Int, sampleRate: Double = Double(AudioWire.sampleRate)) {
        capacity = max(1, capacityFrames)
        ticksPerSecond = 1e9 / HostClock.nanos(1)
        ticksPerFrame = ticksPerSecond / sampleRate
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lockStorage)
        defer { os_unfair_lock_unlock(&lockStorage) }
        return body()
    }

    var overflowFrames: Int64 { withLock { skipped } }
    var callbacks: Int { withLock { _callbacks } }
    var silenceFrames: Int64 { withLock { _silenceFrames } }
    var layout: (buffers: Int, channels: Int) { withLock { _layout } }

    /// Float32 buffers as the IO delivers them: one interleaved buffer of n channels, or one buffer per channel.
    func write(_ buffers: UnsafeMutableAudioBufferListPointer, hostTime: UInt64) {
        guard buffers.count > 0 else { return }
        let first = buffers[0]
        let firstChannels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * firstChannels)
        guard frames > 0, let base0 = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        // where L and R come from: (buffer pointer, stride)
        let l: (UnsafeMutablePointer<Float>, Int), r: (UnsafeMutablePointer<Float>, Int)
        if firstChannels >= 2 {
            l = (base0, firstChannels)
            r = (base0 + 1, firstChannels)
        } else if buffers.count >= 2, let base1 = buffers[1].mData?.assumingMemoryBound(to: Float.self),
                  Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size >= frames {
            l = (base0, 1)
            r = (base1, 1)
        } else {
            l = (base0, 1)
            r = (base0, 1)  // mono: both sides
        }
        os_unfair_lock_lock(&lockStorage)
        _callbacks += 1
        _layout = (buffers.count, firstChannels)
        lastIOHost = hostTime
        let start = written
        var w = Int(written % Int64(capacity))
        for i in 0..<frames {
            left[w] = l.0[i * l.1]
            right[w] = r.0[i * r.1]
            w += 1
            if w == capacity { w = 0 }
        }
        appended(frames, from: start, hostTime: hostTime)
        os_unfair_lock_unlock(&lockStorage)
    }

    /// After `frames` frames went in at write position `start` (lock held): count them, drop what overflows, anchor.
    private func appended(_ frames: Int, from start: Int64, hostTime: UInt64) {
        written += Int64(frames)
        if written - readPos > Int64(capacity) {
            let lost = written - readPos - Int64(capacity)
            readPos += lost
            skipped += lost
        }
        anchor = (start - skipped, hostTime)
        endHost = hostTime &+ UInt64(Double(frames) * ticksPerFrame)
    }

    /// While the IO is idle (no buffer yet, or none for `idle` seconds): zeros from where the data ends up to `trail`
    /// seconds before `nowHost` (after a gap of more than half the ring, or at the start: only the last 20 ms of that).
    /// Returns the frames written.
    @discardableResult
    func fillSilence(nowHost: UInt64, idle: TimeInterval = 0.1, trail: TimeInterval = 0.025) -> Int {
        os_unfair_lock_lock(&lockStorage)
        defer { os_unfair_lock_unlock(&lockStorage) }
        if _callbacks > 0, nowHost < lastIOHost &+ UInt64(idle * ticksPerSecond) { return 0 }
        let trailTicks = UInt64(trail * ticksPerSecond), chunkTicks = UInt64(0.02 * ticksPerSecond)
        guard nowHost > trailTicks + chunkTicks else { return 0 }
        let limit = nowHost - trailTicks
        var start = endHost ?? (limit - chunkTicks)
        guard limit > start else { return 0 }
        if Double(limit - start) / ticksPerFrame > Double(capacity) / 2 { start = limit - chunkTicks }
        let frames = Int(Double(limit - start) / ticksPerFrame)
        guard frames > 0 else { return 0 }
        let first = written
        var w = Int(written % Int64(capacity))
        for _ in 0..<frames {
            left[w] = 0
            right[w] = 0
            w += 1
            if w == capacity { w = 0 }
        }
        _silenceFrames += Int64(frames)
        appended(frames, from: first, hostTime: start)
        return frames
    }

    /// The newest write's first frame (in the reader's count: frames read, not counting overflow) and its host time,
    /// once per write.
    func takeAnchor() -> (frame: Int64, hostTime: UInt64)? {
        withLock {
            defer { anchor = nil }
            return anchor
        }
    }

    /// `frames` frames into `left` / `right` when that many are there; false (nothing read) otherwise.
    func read(left outL: inout [Float], right outR: inout [Float], frames: Int) -> Bool {
        os_unfair_lock_lock(&lockStorage)
        defer { os_unfair_lock_unlock(&lockStorage) }
        guard written - readPos >= Int64(frames) else { return false }
        var p = Int(readPos % Int64(capacity))
        outL.withUnsafeMutableBufferPointer { dl in
            outR.withUnsafeMutableBufferPointer { dr in
                for i in 0..<frames {
                    dl[i] = left[p]
                    dr[i] = right[p]
                    p += 1
                    if p == capacity { p = 0 }
                }
            }
        }
        readPos += Int64(frames)
        return true
    }
}

/// PCM (Float32 stereo at the tap's rate) → Opus packets (48 kHz stereo, 960 frames = 20 ms, 96 kbit/s), one
/// AVAudioConverter for the capture's life. Feed it 960-frame chunks; each yields one packet (the converter resamples
/// first when the tap is not at 48 kHz, so then not exactly one each). Its output runs `primingFrames` (312) behind.
final class OpusPacketEncoder {
    private let converter: AVAudioConverter
    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let input: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer
    let cookie: Data?
    let primingFrames: Int

    init?(inputRate: Double, bitRate: Int = AudioWire.bitRate) {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 2, interleaved: false) else { return nil }
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(AudioWire.sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: UInt32(AudioWire.framesPerPacket), mBytesPerFrame: 0,
                                               mChannelsPerFrame: UInt32(AudioWire.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd), let converter = AVAudioConverter(from: pcm, to: opus),
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(AudioWire.framesPerPacket)) else { return nil }
        converter.bitRate = bitRate
        self.converter = converter
        pcmFormat = pcm
        opusFormat = opus
        self.input = input
        output = AVAudioCompressedBuffer(format: opus, packetCapacity: 8,
                                         maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
        cookie = converter.magicCookie
        primingFrames = Int(converter.primeInfo.leadingFrames)
    }

    /// One chunk (`left.count` == `right.count` ≤ 960 frames) in, the packets it completed out.
    func encode(left: [Float], right: [Float]) -> [Data] {
        let frames = min(left.count, right.count, Int(input.frameCapacity))
        guard let planes = input.floatChannelData else { return [] }
        left.withUnsafeBufferPointer { planes[0].update(from: $0.baseAddress!, count: frames) }
        right.withUnsafeBufferPointer { planes[1].update(from: $0.baseAddress!, count: frames) }
        input.frameLength = AVAudioFrameCount(frames)
        var packets: [Data] = []
        var given = false
        while true {
            output.packetCount = 0
            output.byteLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [input] _, outStatus in
                if given {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                given = true
                outStatus.pointee = .haveData
                return input
            }
            if status == .error {
                log("audio: Opus encode failed: \(error?.localizedDescription ?? "unknown")")
                return packets
            }
            if let descriptions = output.packetDescriptions {
                for i in 0..<Int(output.packetCount) {
                    let d = descriptions[i]
                    packets.append(Data(bytes: output.data + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
                }
            }
            // a full output buffer may leave more behind; anything else means the chunk is used up
            guard status == .haveData, output.packetCount == output.packetCapacity else { return packets }
        }
    }
}
#endif
