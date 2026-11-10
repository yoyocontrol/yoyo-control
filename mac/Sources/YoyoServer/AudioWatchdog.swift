#if os(macOS)
import AVFoundation
import CoreAudio
import Darwin
import Foundation

// Sound that stops reaching this process: the capture's watchdog for a deaf process, and coreaudiod restarts.
//
// - Seen 2026-10-25 on the live helper with no coreaudiod restart: every client (and every new tap) got silence, a
//   fresh helper from the same binary heard at once. Also seen after a TCC refusal and after a coreaudiod restart the
//   process lived through. The watchdog is cause-agnostic.
// - Every 2 s while a capture runs (AudioDeafWatchdog): when the capture's last ≥ 4 s were exact zeros WHILE some other
//   process of this user ran output for those 4 s (Core Audio's `kAudioProcessPropertyIsRunningOutput`; this process
//   and the tap check's own afplay child left out), it asks AudioTapCheck whether this process's taps hear a fresh
//   test sound (an `afplay` child playing a -90 dBFS tone, probed by a private tap of its own). The answer is cached
//   (AudioTapCheckCache: one afplay at a time; one that heard holds 120 s, any other is asked again after 30 s), so
//   nothing playing never triggers it and a long WebAudio context playing digital silence costs one inaudible afplay
//   every 2 minutes at most.
// - `.deaf` → the host's hook (`ScreenHost.onAudioDeaf`): yoyo-control exits 75 and whoever runs it starts a fresh
//   one. At most one such exit per 15 min across processes (the stamp file `$TMPDIR/yoyo-audio-deaf-<uid>` holds
//   the last exit's wall time): inside that, log once and keep running. A fresh process that is deaf too within 15 min
//   (after a TCC refusal every process is) shows a restart doesn't help; restarting every couple of minutes would also
//   cut the phone's video stream each time for as long as something plays. No hook (a host that must keep running): the capture is torn down (its clients
//   reopen into a new one, AudioCapture.tearDown) at most once per 10 min, with a log line saying to restart the app.
// - `.hears` (e.g. a WebAudio context playing digital silence) → nothing; `.failed` (no afplay, it never played, the
//   probe failed) → nothing, logged once.
// - A coreaudiod restart (AudioServiceWatch, the end of this file) is handed to the host the same way.
// - `/audio/stats` `watchdog` / `serviceRestarts`; log lines start with `audio: watchdog:`.

/// The watchdog's decisions (see the top of this file). Pure: the clocks come in as arguments (`now`: a monotonic
/// clock in seconds, `nowWall`: seconds since 1970 for the cross-process stamp).
struct AudioDeafPolicy: Sendable {
    /// Zeros while others play for this long → ask the tap check.
    static let zeroSeconds: TimeInterval = 4
    /// At most one deaf exit per this long, across processes (a respawn deaf again within it: a restart doesn't help).
    static let exitInterval: TimeInterval = 900
    /// Without a hook: at most one teardown (and its log line) per this long.
    static let teardownInterval: TimeInterval = 600

    enum Action: Equatable, Sendable {
        case none
        /// `.failed`, the first one in a row: log it.
        case logFailed
        /// Deaf, with a hook, outside the rate limit: stamp the file, log, call the hook.
        case exit
        /// Deaf, with a hook, inside the rate limit: keep running (`log`: the first time in a row).
        case suppressed(log: Bool)
        /// Deaf, no hook: tear the capture down and log.
        case tearDown
    }

    /// Since when other processes have been running output, as the ticks saw it (nil: none now).
    private(set) var othersSince: TimeInterval?
    private(set) var checks = 0
    private(set) var deaf = 0
    private(set) var exits = 0
    private(set) var suppressed = 0
    private(set) var teardowns = 0
    private(set) var lastResult: AudioTapCheck.Result?
    private(set) var lastAt: TimeInterval?
    /// The tap check (AudioTapCheckCache serial) judged last: a cached answer is judged once.
    private var judgedSerial: Int?
    private var failedLogged = false
    private var suppressLogged = false
    private var lastTeardown: TimeInterval?

    /// A tick: `zeroSince` is when the capture's run of exact zeros began (its start, or its last sound),
    /// `othersPlaying` whether another process of this user runs output now. true = ask the tap check.
    mutating func observe(now: TimeInterval, zeroSince: TimeInterval, othersPlaying: Bool) -> Bool {
        guard othersPlaying else {
            othersSince = nil
            return false
        }
        let since = othersSince ?? now
        othersSince = since
        return now - max(zeroSince, since) >= Self.zeroSeconds
    }

    /// The tap check's answer (`serial`: AudioTapCheckCache's, the same answer is judged once).
    /// `lastExitWall`: the stamp file's time (nil: none, unreadable).
    mutating func judge(serial: Int, result: AudioTapCheck.Result, now: TimeInterval, nowWall: TimeInterval,
                        lastExitWall: TimeInterval?, hasHook: Bool) -> Action {
        guard serial != judgedSerial else { return .none }
        judgedSerial = serial
        checks += 1
        lastResult = result
        lastAt = now
        switch result {
        case .hears:
            failedLogged = false
            suppressLogged = false
            return .none
        case .failed:
            defer { failedLogged = true }
            return failedLogged ? .none : .logFailed
        case .deaf:
            failedLogged = false
            deaf += 1
            guard hasHook else {
                if let t = lastTeardown, now - t < Self.teardownInterval { return .none }
                lastTeardown = now
                teardowns += 1
                return .tearDown
            }
            // a stamp in the future (the clock went back) doesn't hold an exit back
            if let last = lastExitWall, nowWall - last >= 0, nowWall - last < Self.exitInterval {
                suppressed += 1
                defer { suppressLogged = true }
                return .suppressed(log: !suppressLogged)
            }
            exits += 1
            return .exit
        }
    }
}

/// The cross-process stamp of the last deaf exit: `$TMPDIR/yoyo-audio-deaf-<uid>`, the wall time (seconds since 1970)
/// as text.
enum AudioDeafStamp {
    static var path: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("yoyo-audio-deaf-\(getuid())")
    }

    static func read(_ path: String = path) -> TimeInterval? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isFinite ? $0 : nil }
    }

    static func write(_ wall: TimeInterval, to path: String = path) {
        try? String(format: "%.3f\n", wall).write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// AudioTapCheck's answer for AudioDeafWatchdog: one check at a time (a second caller waits
/// for the running one and takes its answer); one that heard holds `valid`, any other is asked again after `retry`.
/// A new capture forgets it (`reset`: its taps are checked afresh).
final class AudioTapCheckCache: @unchecked Sendable {
    static let shared = AudioTapCheckCache()
    static let valid: TimeInterval = 120
    static let retry: TimeInterval = 30

    struct Entry: Equatable, Sendable {
        var result: AudioTapCheck.Result
        var at: Date
        var detail: String
        /// Counts the checks run (1, 2, …): the same answer seen twice has the same serial.
        var serial: Int
    }

    private let lock = NSLock()
    /// Held while a check runs (up to ~7 s).
    private let running = NSLock()
    private var entry: Entry?
    private var serial = 0

    /// The answer: the cached one while it holds, else a check run now (`run`; blocks). `ran`: this call ran it.
    func current(now: () -> Date = Date.init, run: () -> (AudioTapCheck.Result, String)) -> (entry: Entry, ran: Bool) {
        running.lock()
        defer { running.unlock() }
        if let e = cached(at: now()) { return (e, false) }
        let (result, detail) = run()
        lock.lock()
        defer { lock.unlock() }
        serial += 1
        let e = Entry(result: result, at: now(), detail: detail, serial: serial)
        entry = e
        return (e, true)
    }

    @available(macOS 14.2, *)
    func current() -> (entry: Entry, ran: Bool) { current(run: AudioTapCheck.run) }

    /// The cached answer if it still holds at `now`.
    func cached(at now: Date) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let e = entry, now.timeIntervalSince(e.at) < (e.result == .hears ? Self.valid : Self.retry) else { return nil }
        return e
    }

    /// The latest answer, held or not (stats).
    var latest: Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entry
    }

    /// Checks run so far.
    var checks: Int {
        lock.lock()
        defer { lock.unlock() }
        return serial
    }

    func reset() {
        lock.lock()
        entry = nil
        lock.unlock()
    }
}

/// Runs while the capture does (AudioCapture starts and stops it): every `interval` it applies AudioDeafPolicy (see
/// the top of this file). Its bookkeeping outlives a capture.
final class AudioDeafWatchdog: @unchecked Sendable {
    static let shared = AudioDeafWatchdog()
    static let interval: TimeInterval = 2
    static let deafMessage = "audio: this process's taps are deaf; restart the app if the sound does not come back"

    private let queue = DispatchQueue(label: "yoyo-audio-watchdog", qos: .utility)
    private let lock = NSLock()
    // Guarded by `lock`:
    private var timer: DispatchSourceTimer?
    private var owner: ObjectIdentifier?
    /// The running capture's zero run start (monotonic seconds; nil once it is gone).
    private var zeroSince: (@Sendable () -> TimeInterval?)?
    private var policy = AudioDeafPolicy()

    /// A capture started. `zeroSince`: since when (ProcessInfo.systemUptime) its samples have all been zeros.
    func start(for capture: ObjectIdentifier, zeroSince: @escaping @Sendable () -> TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        owner = capture
        self.zeroSince = zeroSince
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// A capture stopped: the watchdog stops if it ran for that one.
    func stop(for capture: ObjectIdentifier) {
        lock.lock()
        guard owner == capture else { lock.unlock(); return }
        owner = nil
        zeroSince = nil
        let t = timer
        timer = nil
        lock.unlock()
        t?.cancel()
    }

    private func current() -> (owner: ObjectIdentifier, zeroSince: TimeInterval)? {
        lock.lock()
        let o = owner, z = zeroSince
        lock.unlock()
        guard let o, let since = z?() else { return nil }
        return (o, since)
    }

    private func tick() {
        guard #available(macOS 14.2, *), let (capture, zeroSince) = current() else { return }
        let me = getpid(), uid = getuid(), child = AudioTapCheck.childPID
        let othersPlaying = AudioClientProcess.list().contains { c in
            c.runningOutput && c.pid != me && c.pid != child && ProcessFacts.of(c.pid)?.uid == uid
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let ask = policy.observe(now: now, zeroSince: zeroSince, othersPlaying: othersPlaying)
        lock.unlock()
        guard ask else { return }
        let (entry, _) = AudioTapCheckCache.shared.current()
        // the capture may have stopped meanwhile (a check takes seconds)
        lock.lock()
        guard owner == capture else { lock.unlock(); return }
        let hook = ScreenHost.onAudioDeaf
        let action = policy.judge(serial: entry.serial, result: entry.result, now: ProcessInfo.processInfo.systemUptime,
                                  nowWall: Date().timeIntervalSince1970, lastExitWall: AudioDeafStamp.read(), hasHook: hook != nil)
        lock.unlock()
        let zeros = String(format: "%.0f", now - zeroSince)
        switch action {
        case .none:
            break
        case .logFailed:
            log("audio: watchdog: the capture read \(zeros) s of zeros while others play, but no tap check (\(entry.detail)); doing nothing")
        case .exit:
            AudioDeafStamp.write(Date().timeIntervalSince1970)
            log("audio: watchdog: this process's taps are deaf (\(zeros) s of zeros while others play; \(entry.detail));"
                + " handing over to the host (a fresh process)")
            hook?()
        case .suppressed(let first):
            if first {
                log("audio: watchdog: this process's taps are deaf (\(entry.detail)), but a helper already exited for that"
                    + " less than \(Int(AudioDeafPolicy.exitInterval / 60)) min ago, so a restart does not help; keeping on")
            }
        case .tearDown:
            log("audio: watchdog: the capture read \(zeros) s of zeros while others play and a fresh test sound is not heard"
                + " (\(entry.detail)); tearing it down")
            log(Self.deafMessage)
            AudioCapture.tearDown(reason: "the watchdog found this process's taps deaf")
        }
    }

    /// `/audio/stats` `watchdog`.
    func statsJSON() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        return [
            "running": timer != nil,
            "checks": policy.checks,
            "deaf": policy.deaf,
            "lastResult": policy.lastResult?.rawValue ?? NSNull(),
            "lastAgoSeconds": policy.lastAt.map { ((now - $0) * 10).rounded() / 10 } ?? NSNull(),
            "exits": policy.exits,
            "suppressed": policy.suppressed,
            "teardowns": policy.teardowns,
        ]
    }
}

/// One Core Audio client process of the Mac (Core Audio's process object).
struct AudioClientProcess: Equatable, Sendable {
    var object: AudioObjectID
    var pid: pid_t
    /// "" when Core Audio has none.
    var bundleID: String
    var runningOutput: Bool

    /// Every process object, with its pid, bundle id and whether it runs output now.
    static func list() -> [AudioClientProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { id in
            guard let pid: pid_t = scalar(id, kAudioProcessPropertyPID) else { return nil }
            let output: UInt32 = scalar(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioClientProcess(object: id, pid: pid, bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                                      runningOutput: output != 0)
        }
    }

    private static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// A process as the kernel knows it (sysctl KERN_PROC: works for every process).
struct ProcessFacts: Equatable, Sendable {
    var pid: pid_t
    var uid: uid_t

    static func of(_ pid: pid_t) -> ProcessFacts? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return ProcessFacts(pid: info.kp_proc.p_pid, uid: info.kp_eproc.e_ucred.cr_uid)
    }
}

/// A short private tap of one process's output (pre-volume), counting its frames and the peak (AudioTapCheck's probe).
final class AudioTapProbe: @unchecked Sendable {
    let pid: pid_t
    let sampleRate: Double
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let meter = AudioProbeMeter()

    @available(macOS 14.2, *)
    init(pid: pid_t, object: AudioObjectID) throws {
        self.pid = pid
        var tap = AudioObjectID(kAudioObjectUnknown), aggregate = AudioObjectID(kAudioObjectUnknown)
        var proc: AudioDeviceIOProcID?
        let rate: Double
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: [object])
            description.name = "Yoyo Control audio probe"
            description.isPrivate = true
            description.muteBehavior = CATapMuteBehavior.unmuted
            var status = AudioHardwareCreateProcessTap(description, &tap)
            guard status == noErr, tap != kAudioObjectUnknown else {
                throw HTTPError(503, "cannot create a probe tap (\(AudioCapture.osStatus(status)))")
            }
            rate = try AudioCapture.tapFormat(tap).mSampleRate
            aggregate = try AudioCapture.makeAggregate(tapUID: description.uuid.uuidString, name: "Yoyo Control audio probe",
                                                       uidPrefix: "ca.sarria.yoyocontrol.audio-probe")
            status = AudioDeviceCreateIOProcID(aggregate, audioProbeIOProc, Unmanaged.passUnretained(meter).toOpaque(), &proc)
            guard status == noErr, let proc else { throw HTTPError(503, "AudioDeviceCreateIOProcID failed (\(AudioCapture.osStatus(status)))") }
            status = AudioDeviceStart(aggregate, proc)
            guard status == noErr else { throw HTTPError(503, "AudioDeviceStart failed (\(AudioCapture.osStatus(status)))") }
        } catch {
            if let proc, aggregate != kAudioObjectUnknown { AudioDeviceStop(aggregate, proc) }
            AudioCapture.destroy(tap: tap, aggregate: aggregate, proc: proc)
            throw error
        }
        tapID = tap
        aggregateID = aggregate
        procID = proc
        sampleRate = rate > 0 ? rate : Double(AudioWire.sampleRate)
    }

    deinit { close() }

    /// Frames seen so far and their peak.
    var reading: (seconds: Double, peak: Float) {
        let r = meter.reading
        return (Double(r.frames) / sampleRate, r.peak)
    }

    /// Stop and destroy the tap (idempotent; the IOProc is gone before the meter can be).
    func close() {
        guard aggregateID != kAudioObjectUnknown || tapID != kAudioObjectUnknown else { return }
        if let procID { AudioDeviceStop(aggregateID, procID) }
        AudioCapture.destroy(tap: tapID, aggregate: aggregateID, proc: procID)
        procID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// The probe IOProc's counters (real-time thread: no allocation, one short lock).
final class AudioProbeMeter: @unchecked Sendable {
    private var lockStorage = os_unfair_lock_s()
    private var frames = 0
    private var peak: Float = 0

    func add(_ buffers: UnsafeMutableAudioBufferListPointer) {
        guard buffers.count > 0 else { return }
        let channels = max(1, Int(buffers[0].mNumberChannels))
        let count = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
        var p: Float = 0
        for b in buffers {
            guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<(Int(b.mDataByteSize) / MemoryLayout<Float>.size) { p = max(p, abs(data[i])) }
        }
        os_unfair_lock_lock(&lockStorage)
        frames += count
        peak = max(peak, p)
        os_unfair_lock_unlock(&lockStorage)
    }

    var reading: (frames: Int, peak: Float) {
        os_unfair_lock_lock(&lockStorage)
        defer { os_unfair_lock_unlock(&lockStorage) }
        return (frames, peak)
    }
}

private func audioProbeIOProc(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>, _ input: UnsafePointer<AudioBufferList>,
                              _ inputTime: UnsafePointer<AudioTimeStamp>, _ output: UnsafeMutablePointer<AudioBufferList>,
                              _ outputTime: UnsafePointer<AudioTimeStamp>, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { return noErr }
    Unmanaged<AudioProbeMeter>.fromOpaque(context).takeUnretainedValue()
        .add(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
    return noErr
}

/// Whether this process's taps hear anything: a fresh child (`afplay`, started now, so not stale) plays a 1 kHz tone at
/// -90 dBFS (inaudible) for 4 s and gets a probe. Blocks up to ~7 s.
enum AudioTapCheck {
    enum Result: String, Sendable {
        case hears
        /// The probe ran and read zeros: this process's taps are deaf.
        case deaf
        /// No answer (afplay missing, never played, the probe failed).
        case failed
    }

    static let amplitude: Float = 3e-5

    private static let childLock = NSLock()
    nonisolated(unsafe) private static var _childPID: pid_t = 0
    /// The afplay child of a check under way (0: none), which the watchdog doesn't count as another process playing.
    static var childPID: pid_t {
        childLock.lock()
        defer { childLock.unlock() }
        return _childPID
    }

    private static func setChild(_ pid: pid_t) {
        childLock.lock()
        _childPID = pid
        childLock.unlock()
    }

    @available(macOS 14.2, *)
    static func run() -> (Result, String) {
        guard let file = toneFile() else { return (.failed, "cannot write the test sound") }
        defer { try? FileManager.default.removeItem(at: file) }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "1", file.path]
        player.standardOutput = FileHandle.nullDevice
        player.standardError = FileHandle.nullDevice
        do { try player.run() } catch { return (.failed, "afplay: \(error.localizedDescription)") }
        let pid = player.processIdentifier
        setChild(pid)
        defer {
            if player.isRunning { player.terminate() }
            player.waitUntilExit()
            setChild(0)
        }
        var object: AudioObjectID?
        let appear = Date().addingTimeInterval(3)
        while object == nil, Date() < appear, player.isRunning {
            object = AudioClientProcess.list().first { $0.pid == pid && $0.runningOutput }?.object
            if object == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard let object else { return (.failed, "the test sound never played") }
        let probe: AudioTapProbe
        do { probe = try AudioTapProbe(pid: pid, object: object) } catch {
            return (.failed, (error as? HTTPError)?.message ?? "\(error)")
        }
        defer { probe.close() }
        let until = Date().addingTimeInterval(3)
        while Date() < until, probe.reading.peak == 0 { Thread.sleep(forTimeInterval: 0.1) }
        let r = probe.reading
        let detail = "afplay pid \(pid): \(String(format: "%.1f", r.seconds)) s, peak \(String(format: "%.1f", audioDBFS(r.peak))) dBFS"
        if r.peak > 0 { return (.hears, detail) }
        return (r.seconds >= 1 ? .deaf : .failed, detail)
    }

    /// `$TMPDIR/yoyo-audio-check-<pid>.caf` (4 s mono 48 kHz float; removed after the check).
    private static func toneFile() -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yoyo-audio-check-\(getpid()).caf")
        let rate = 48_000.0, frames = AVAudioFrameCount(4 * rate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        for i in 0..<Int(frames) { samples[i] = amplitude * Float(sin(2 * Double.pi * 1_000 * Double(i) / rate)) }
        buffer.frameLength = frames
        do {
            let out = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try out.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }
}

/// coreaudiod restarted (`kAudioHardwarePropertyServiceRestarted`: a driver install, `killall coreaudiod`). A process
/// that lived through it kept creating taps that read zeros for other apps (measured 2026-10-24; a freshly started
/// helper read real sound at the same moment). The host decides what happens (`ScreenHost.onAudioServiceRestart`):
/// yoyo-control exits so that whoever runs it (the app) starts a fresh one; without a hook (a host that must not
/// quit) the capture is torn down here and rebuilt by its clients' reopen.
enum AudioServiceWatch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var _restarts = 0

    static var restarts: Int {
        lock.lock()
        defer { lock.unlock() }
        return _restarts
    }

    /// Listen on the system object (once per process; the first capture start calls it: before that this process has
    /// no Core Audio state to go stale). Returns the listener's status.
    @discardableResult
    static func install() -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return noErr }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyServiceRestarted,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                         DispatchQueue.global(qos: .userInitiated)) { _, _ in
            serviceRestarted()
        }
        if status == noErr { installed = true } else { log("audio: cannot watch for Core Audio restarts (\(AudioCapture.osStatus(status)))") }
        return status
    }

    /// The notification: the host's hook, else rebuild in-process. Internal for tests (`hook` / `rebuild` injected).
    static func serviceRestarted(hook: (() -> Void)? = ScreenHost.onAudioServiceRestart,
                                 rebuild: () -> Void = { AudioCapture.serviceRestarted() }) {
        lock.lock()
        _restarts += 1
        lock.unlock()
        if let hook {
            log("audio: Core Audio restarted; this process's taps would read silence from now on, handing over to the host")
            hook()
        } else {
            log("audio: Core Audio restarted; rebuilding the capture")
            rebuild()
        }
    }
}
#endif
