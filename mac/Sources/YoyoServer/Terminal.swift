#if os(macOS)
import Darwin
import Foundation

// Terminals for paired phones (docs/PROTOCOL.md「终端」): the user's login shell on a pseudo-terminal, run by the
// service in the logged-in user's session (so `open`, `pbcopy`, the login keychain work as in Terminal.app). A terminal
// outlives the phone's connection: its output goes on into a ring of the last `ringMax` bytes, and a phone that comes
// back gets the bytes it missed (or, when they are gone, the ring with a redraw) and goes on. It ends when its shell
// exits, when it is ended (`POST /term/kill`, the menu), when remote terminals are turned off, or after
// `detachedLifetime` without a phone.

/// Where a terminal's output goes while a phone is attached (one at a time; LinkTerminal).
protocol TerminalSink: AnyObject, Sendable {
    /// Attached: what follows starts at `attached.offset`, after `attached.replay` (called on the terminal's queue,
    /// before any `terminalOutput`).
    func terminalAttached(_ attached: TerminalSession.Attached)
    /// Output, in order (called on the terminal's queue).
    func terminalOutput(_ data: Data)
    /// The terminal is over for this sink: its shell exited (`code`), it was ended, or another phone took it.
    func terminalEnded(_ end: TerminalEnd)
    /// Bytes handed to `terminalOutput` that haven't gone out yet: over `TerminalSession.backlogMax` the terminal
    /// stops reading its program (which then waits, as on a slow terminal) until `TerminalSession.drained()`.
    var terminalBacklog: Int { get }
}

enum TerminalEnd: Equatable, Sendable {
    /// The shell exited: its status (`WEXITSTATUS`), or 128 + the signal that ended it.
    case exited(Int32)
    /// Ended on purpose (`POST /term/kill`, the menu).
    case killed
    /// Remote terminals were turned off.
    case off
    /// Another connection attached to it.
    case replaced

    var reason: String {
        switch self {
        case .exited: "exit"
        case .killed: "killed"
        case .off: "off"
        case .replaced: "replaced"
        }
    }
}

/// One terminal: a shell on a pseudo-terminal.
final class TerminalSession: @unchecked Sendable {
    /// The output kept for a phone that comes back.
    static let ringMax = 1 << 20
    /// Output waiting for the phone beyond this: the program waits.
    static let backlogMax = 1 << 20
    static let readMax = 64 << 10

    let id: String
    let createdAt: Date
    let pid: pid_t
    /// Who opened it.
    let device: (id: String, name: String)?
    private let master: Int32
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let inputQueue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var readingPaused = false
    /// The last output (at most `ringMax`): bytes `[total - ring.count, total)` of all it wrote.
    private var ring = Data()
    private var total: UInt64 = 0
    private var sink: TerminalSink?
    private(set) var cols: UInt16
    private(set) var rows: UInt16
    /// Since then nobody is attached (nil: someone is).
    private var detachedSince: Date? = Date()
    private var ended: TerminalEnd?
    /// Called once, after it ended (the store forgets it).
    var onEnd: ((TerminalSession) -> Void)?

    struct Attached {
        /// The output that follows (`replay`, then what `terminalOutput` brings) starts at this byte.
        var offset: UInt64
        var replay: Data
        /// The phone's copy can't be continued (it asked for bytes that are gone, or none): it clears its screen first.
        var reset: Bool
    }

    /// Starts `command` (nil: the user's login shell) on a new pseudo-terminal of `cols` × `rows`, in `cwd` (nil or not
    /// a directory: home).
    init(id: String, cols: UInt16, rows: UInt16, cwd: String?, device: (id: String, name: String)?,
         command: [String]? = nil, environment: [String: String]? = nil) throws {
        self.id = id
        self.device = device
        self.cols = max(cols, 2)
        self.rows = max(rows, 2)
        createdAt = Date()
        queue = DispatchQueue(label: "yoyo-control.term.\(id)", qos: .userInitiated)
        inputQueue = DispatchQueue(label: "yoyo-control.term-input.\(id)", qos: .userInitiated)
        (pid, master) = try Self.spawn(cols: self.cols, rows: self.rows, cwd: cwd, command: command, environment: environment)
        let flags = fcntl(master, F_GETFD)
        _ = fcntl(master, F_SETFD, flags | FD_CLOEXEC)
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [weak self] in self?.readOutput() }
        readSource = read
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in self?.shellExited() }
        exitSource = exit
        read.resume()
        exit.resume()
    }

    // MARK: Attaching

    /// `sink` gets the output from now on (`terminalAttached` first; another attached one is told `.replaced`).
    /// `since`: the byte the phone's copy goes up to (it continues from there when those bytes are still kept); nil: a
    /// new copy. false when it has ended.
    func attach(_ sink: TerminalSink, since: UInt64?) -> Bool {
        // on the queue: no output can come between what is replayed and what follows
        queue.sync { attachOnQueue(sink, since: since) }
    }

    private func attachOnQueue(_ sink: TerminalSink, since: UInt64?) -> Bool {
        lock.lock()
        guard ended == nil else { lock.unlock(); return false }
        let old = self.sink
        self.sink = sink
        detachedSince = nil
        let start = total - UInt64(ring.count)
        let attached: Attached
        if let since, since >= start, since <= total {
            attached = Attached(offset: since, replay: ring.suffix(Int(total - since)), reset: false)
        } else {
            // the kept output from its first line start (not inside an escape sequence or a character)
            var replay = ring
            if start > 0, let nl = replay.firstIndex(of: 0x0A) { replay = replay.suffix(from: replay.index(after: nl)) }
            attached = Attached(offset: total - UInt64(replay.count), replay: Data(replay), reset: true)
        }
        lock.unlock()
        if let old, old !== sink { old.terminalEnded(.replaced) }
        sink.terminalAttached(attached)
        // a cleared copy of a screen that had something on it: the program draws it again
        if attached.reset, total > 0 { redraw() }
        if readingPaused, sink.terminalBacklog <= Self.backlogMax / 2 { resumeReadingOnQueue() }
        return true
    }

    /// `sink` went (its phone's connection ended): the terminal goes on, kept for a while.
    func detach(_ sink: TerminalSink) {
        lock.lock()
        guard self.sink === sink else { lock.unlock(); return }
        self.sink = nil
        detachedSince = Date()
        lock.unlock()
        resumeReading()
    }

    var isAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return sink != nil
    }

    /// How long nobody has been attached (0 while someone is).
    func detachedFor(now: Date = Date()) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return detachedSince.map { now.timeIntervalSince($0) } ?? 0
    }

    // MARK: Input

    /// Bytes typed on the phone, to the program (in order; a program that doesn't read holds them back).
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let fd = master
        inputQueue.async { [weak self] in
            guard self?.hasEnded == false else { return }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard var p = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let n = Darwin.write(fd, p, left)
                    if n < 0 {
                        if errno == EINTR || errno == EAGAIN { usleep(2000); continue }
                        return
                    }
                    left -= n
                    p += n
                }
            }
        }
    }

    /// The terminal's size (the program gets SIGWINCH when it changed).
    func resize(cols: UInt16, rows: UInt16) {
        let c = max(cols, 2), r = max(rows, 2)
        lock.lock()
        self.cols = c
        self.rows = r
        lock.unlock()
        guard !hasEnded else { return }
        Self.setSize(master, cols: c, rows: r)
    }

    /// Makes full-screen programs draw everything again (a phone that came back with a cleared screen): the size one
    /// row smaller, then back, so the program gets SIGWINCH.
    private func redraw() {
        lock.lock()
        let c = cols, r = rows
        lock.unlock()
        Self.setSize(master, cols: c, rows: r > 2 ? r - 1 : r + 1)
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.hasEnded else { return }
            Self.setSize(self.master, cols: c, rows: r)
        }
    }

    static func setSize(_ fd: Int32, cols: UInt16, rows: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &ws)
    }

    // MARK: Output

    private func readOutput() {
        var buffer = [UInt8](repeating: 0, count: Self.readMax)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, Self.readMax) }
        if n <= 0 {
            if n < 0, errno == EINTR || errno == EAGAIN { return }
            // EIO: nothing has the terminal open any more (the shell and what it started are gone)
            readSource?.cancel()
            readSource = nil
            return
        }
        let data = Data(buffer[0..<n])
        lock.lock()
        ring.append(data)
        if ring.count > Self.ringMax { ring.removeFirst(ring.count - Self.ringMax) }
        total += UInt64(n)
        let sink = self.sink
        lock.unlock()
        guard let sink else { return }
        sink.terminalOutput(data)
        if sink.terminalBacklog > Self.backlogMax, !readingPaused, let readSource {
            readingPaused = true
            readSource.suspend()
        }
    }

    /// The attached sink's backlog went down: reading goes on (any thread).
    func drained() {
        queue.async { [weak self] in
            guard let self, self.readingPaused, let sink = self.currentSink, sink.terminalBacklog <= Self.backlogMax / 2 else { return }
            self.resumeReadingOnQueue()
        }
    }

    private var currentSink: TerminalSink? {
        lock.lock(); defer { lock.unlock() }
        return sink
    }

    private func resumeReading() {
        queue.async { [weak self] in self?.resumeReadingOnQueue() }
    }

    private func resumeReadingOnQueue() {
        guard readingPaused, let readSource else { return }
        readingPaused = false
        readSource.resume()
    }

    // MARK: The end

    var hasEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended != nil
    }

    private func shellExited() {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        let code: Int32
        if r == pid {
            let sig = status & 0x7f
            code = sig == 0 ? (status >> 8) & 0xff : 128 + sig
        } else {
            code = 0
        }
        // what it wrote last is still in the terminal: read it before telling the phone
        resumeReadingOnQueue()
        for _ in 0..<64 {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 0) > 0, pfd.revents & Int16(POLLIN) != 0, readSource != nil else { break }
            readOutput()
        }
        finish(.exited(code))
    }

    /// Ends it: the shell's process group gets SIGHUP (then SIGKILL if it is still there after 2 s).
    func end(_ why: TerminalEnd) {
        let pid = pid
        killpg(pid, SIGHUP)
        kill(pid, SIGHUP)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { killpg(pid, SIGKILL); kill(pid, SIGKILL) }
        }
        queue.async { [weak self] in self?.finish(why) }
    }

    private func finish(_ why: TerminalEnd) {
        lock.lock()
        guard ended == nil else { lock.unlock(); return }
        ended = why
        let sink = self.sink
        self.sink = nil
        lock.unlock()
        if readingPaused { readingPaused = false; readSource?.resume() }
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        // closed after the input already queued (which checks `hasEnded` first): no write can reach a reused fd
        let fd = master
        inputQueue.async { close(fd) }
        // reap it when it goes (an ended one may take a moment after SIGHUP)
        let pid = pid
        DispatchQueue.global().async {
            var status: Int32 = 0
            for _ in 0..<50 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
        }
        sink?.terminalEnded(why)
        onEnd?(self)
    }

    // MARK: What it runs

    /// The name of the program in the foreground of the terminal now (`zsh`, `vim`, `claude`), nil when unknown.
    var foregroundCommand: String? {
        guard !hasEnded else { return nil }
        let group = tcgetpgrp(master)
        guard group > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(group, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
    }

    var json: [String: Any] {
        lock.lock()
        var j: [String: Any] = [
            "id": id, "createdAt": createdAt.timeIntervalSince1970 * 1000, "cols": Int(cols), "rows": Int(rows),
            "attached": sink != nil,
        ]
        lock.unlock()
        if let device { j["device"] = ["id": device.id, "name": device.name] }
        if let command = foregroundCommand { j["command"] = command }
        return j
    }

    // MARK: Spawning

    struct SpawnError: Error, CustomStringConvertible {
        var description: String
    }

    /// The user's login shell (`-zsh`) or `command`, on a new pseudo-terminal: forkpty, then in the child only
    /// async-signal-safe calls on what was prepared before (the service has other threads).
    static func spawn(cols: UInt16, rows: UInt16, cwd: String?, command: [String]?, environment: [String: String]?)
        throws -> (pid_t, Int32) {
        let user = getpwuid(getuid())
        let home = user.flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let shell = user.flatMap { String(validatingCString: $0.pointee.pw_shell) }.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let name = user.flatMap { String(validatingCString: $0.pointee.pw_name) } ?? NSUserName()
        let path: String
        let args: [String]
        if let command, let first = command.first {
            path = first
            args = command
        } else {
            path = shell
            args = ["-" + (shell as NSString).lastPathComponent]  // a login shell, as Terminal.app starts it
        }
        var dir = home
        var isDir: ObjCBool = false
        if let cwd, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue { dir = cwd }
        let env = environment ?? Self.environment(home: home, shell: shell, user: name)

        let cPath = strdup(path)
        let cDir = strdup(dir)
        let cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            free(cPath)
            free(cDir)
            for p in cArgs { free(p) }
            for p in cEnv { free(p) }
        }
        let maxFd = min(Int32(getdtablesize()), 4096)
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = cArgs.withUnsafeBufferPointer { argv in
            cEnv.withUnsafeBufferPointer { envp in
                let pid = forkpty(&master, nil, nil, &ws)
                if pid == 0 {
                    // the child: the signals as a new program expects them (the service ignores SIGPIPE), no fds but 0–2
                    for s in [SIGPIPE, SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU, SIGALRM, SIGUSR1, SIGUSR2] {
                        signal(s, SIG_DFL)
                    }
                    var none = sigset_t()
                    sigprocmask(SIG_SETMASK, &none, nil)
                    var fd: Int32 = 3
                    while fd < maxFd { close(fd); fd += 1 }
                    _ = chdir(cDir)
                    execve(cPath, argv.baseAddress, envp.baseAddress)
                    _exit(127)
                }
                return pid
            }
        }
        guard pid > 0 else { throw SpawnError(description: "forkpty failed: \(String(cString: strerror(errno)))") }
        return (pid, master)
    }

    /// The shell's environment: the service's, less what is the service's own, plus what a terminal sets.
    static func environment(home: String, shell: String, user: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("YOYO_") || key.hasPrefix("__CF") || key.hasPrefix("XPC_")
            || key == "TERM_PROGRAM" || key == "TERM_PROGRAM_VERSION" || key == "TERM_SESSION_ID" || key == "PWD"
            || key == "OLDPWD" || key == "SHLVL" || key == "_" || key.hasPrefix("DYLD_") {
            env[key] = nil
        }
        env["HOME"] = home
        env["SHELL"] = shell
        env["USER"] = user
        env["LOGNAME"] = user
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        if env["LANG"] == nil, env["LC_ALL"] == nil, env["LC_CTYPE"] == nil { env["LANG"] = Self.utf8Locale() }
        return env
    }

    /// The user's locale as a UTF-8 one the system has (`zh_CN.UTF-8`), else `en_US.UTF-8`: CJK and emoji need a UTF-8
    /// locale, and a service started by launchd has none.
    static func utf8Locale() -> String {
        let id = Locale.current.identifier.split(separator: "@").first.map(String.init) ?? ""
        for candidate in [id, Locale.current.language.languageCode.map { "\($0.identifier)_\(Locale.current.region?.identifier ?? "")" } ?? ""]
        where !candidate.isEmpty {
            let name = candidate + ".UTF-8"
            if FileManager.default.fileExists(atPath: "/usr/share/locale/" + name) { return name }
        }
        return "en_US.UTF-8"
    }
}

/// The terminals of this service (remote access's).
final class TerminalStore: @unchecked Sendable {
    static let shared = TerminalStore()
    /// At most this many at once.
    static let max = 16
    /// A terminal nobody has been attached to for this long ends.
    static let detachedLifetime: TimeInterval = 24 * 3600

    private let lock = NSLock()
    private var sessions: [String: TerminalSession] = [:]
    private var reaper: DispatchSourceTimer?
    /// Called (any thread) when one started or ended.
    var onChange: (() -> Void)?

    struct Full: Error {}

    func open(cols: UInt16, rows: UInt16, cwd: String?, device: (id: String, name: String)?,
              command: [String]? = nil, environment: [String: String]? = nil) throws -> TerminalSession {
        lock.lock()
        guard sessions.count < Self.max else { lock.unlock(); throw Full() }
        lock.unlock()
        let s = try TerminalSession(id: RemoteDevices.random(12), cols: cols, rows: rows, cwd: cwd, device: device,
                                    command: command, environment: environment)
        s.onEnd = { [weak self] s in self?.ended(s) }
        lock.lock()
        sessions[s.id] = s
        startReaper()
        let count = sessions.count
        lock.unlock()
        log("terminal: \(s.id) started for \(device?.name ?? "?") (pid \(s.pid), \(count) open)")
        onChange?()
        return s
    }

    func session(_ id: String) -> TerminalSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    var all: [TerminalSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.sorted { $0.createdAt < $1.createdAt }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count
    }

    /// Ends every terminal (`why`: `.killed` from the menu, `.off` when terminals were turned off).
    func endAll(_ why: TerminalEnd) {
        for s in all { s.end(why) }
    }

    private func ended(_ s: TerminalSession) {
        lock.lock()
        sessions[s.id] = nil
        let count = sessions.count
        lock.unlock()
        log("terminal: \(s.id) ended (\(count) open)")
        onChange?()
    }

    private func startReaper() {
        guard reaper == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 600, repeating: 600)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for s in self.all where s.detachedFor() > Self.detachedLifetime {
                log("terminal: \(s.id) ends: nobody attached for a day")
                s.end(.killed)
            }
        }
        reaper = t
        t.resume()
    }
}
#endif
