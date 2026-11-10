#if os(macOS)
import AppKit
import Foundation

/// Runs the screen service as a process of its own: the command line, the TCC-responsibility re-launch, signals,
/// the stdin-EOF watch, the restart exit code, the audio hooks and AppKit's run loop. Yoyo Control's `yoyo-control`
/// is one caller; any other app can build its own service executable from this library the same way:
///
///     // main.swift of an executable inside the embedding app's bundle
///     import YoyoServer
///     ServiceHost.main(options: .init(logName: "my-screen"))
///
/// and run it as `<executable> --socket <path> [--exit-on-stdin-eof]` (docs/LOCAL-API.md「自己拉起服务」). Never returns.
public enum ServiceHost {
    /// What the embedder decides; the defaults are Yoyo Control's.
    public struct Options: Sendable {
        /// The log prefix (`<logName>[pid]: …` on stderr) and the name of this process's power assertions.
        public var logName: String
        /// The app named in permission errors ("… is not granted to <appName>"); nil = the bundle this runs in
        /// (`CFBundleDisplayName`, else `CFBundleName`), else "Yoyo Control".
        public var appName: String?
        /// Whether `--remote` is accepted (remote access for paired phones, state next to the socket: Yoyo Control's
        /// own app). false: `--remote` is an unknown argument.
        public var allowsRemote: Bool
        /// Watch for input from elsewhere (`/events` `input-elsewhere`, `/status.inputElsewhere`; InputElsewhere.swift).
        public var watchInputElsewhere: Bool
        /// The environment variable that marks the re-launched, responsibility-disclaimed child.
        public var disclaimedEnvironmentKey: String
        /// The link listener (docs/LINK.md, LinkOptions): nil = Yoyo Control's default (with `--remote`: port 47820 in
        /// the remote home, relay1; without: none). `--no-link` turns it off either way (and with it remote access).
        public var link: LinkOptions?

        public init(logName: String = "yoyo-control", appName: String? = nil, allowsRemote: Bool = false,
                    watchInputElsewhere: Bool = true, disclaimedEnvironmentKey: String = "YOYO_DISCLAIMED",
                    link: LinkOptions? = nil) {
            self.logName = logName
            self.appName = appName
            self.allowsRemote = allowsRemote
            self.watchInputElsewhere = watchInputElsewhere
            self.disclaimedEnvironmentKey = disclaimedEnvironmentKey
            self.link = link
        }
    }

    /// The parsed command line.
    public struct Arguments: Equatable, Sendable {
        public var socketPath: String
        public var exitOnStdinEOF = false
        public var remote = false
        /// `--no-link`: no link listener.
        public var noLink = false

        public init(socketPath: String, exitOnStdinEOF: Bool = false, remote: Bool = false, noLink: Bool = false) {
            self.socketPath = socketPath
            self.exitOnStdinEOF = exitOnStdinEOF
            self.remote = remote
            self.noLink = noLink
        }
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// `--socket <path> [--exit-on-stdin-eof] [--remote] [--no-link]` (the program name first, as in
    /// `CommandLine.arguments`).
    public static func parse(_ arguments: [String], allowsRemote: Bool) throws -> Arguments {
        var socketPath: String?
        var exitOnStdinEOF = false, remote = false, noLink = false
        var args = arguments.dropFirst()
        while let arg = args.popFirst() {
            switch arg {
            case "--socket": socketPath = args.popFirst()
            case "--exit-on-stdin-eof": exitOnStdinEOF = true
            case "--remote" where allowsRemote: remote = true
            case "--no-link": noLink = true
            default: throw UsageError(message: "unknown argument \(arg)")
            }
        }
        guard let socketPath, !socketPath.isEmpty else { throw UsageError(message: "--socket <path> is required") }
        return Arguments(socketPath: socketPath, exitOnStdinEOF: exitOnStdinEOF, remote: remote, noLink: noLink)
    }

    /// The usage line for `program`.
    public static func usage(program: String, allowsRemote: Bool) -> String {
        "usage: \(program) --socket <path> [--exit-on-stdin-eof]\(allowsRemote ? " [--remote]" : "")"
    }

    /// Parses `arguments` (exit 2 on a bad command line), then `run`. Never returns.
    public static func main(arguments: [String] = CommandLine.arguments, options: Options = Options()) -> Never {
        configure(options)
        let parsed: Arguments
        do {
            parsed = try parse(arguments, allowsRemote: options.allowsRemote)
        } catch {
            log("\(error)")
            log(usage(program: (arguments.first as NSString?)?.lastPathComponent ?? options.logName, allowsRemote: options.allowsRemote))
            exit(2)
        }
        run(parsed, options: options)
    }

    /// Runs the service on `arguments.socketPath` until a signal, stdin EOF (with `exitOnStdinEOF`), a fatal socket
    /// error (exit 1) or an audio failure only a new process fixes (exit 75, `restartExitCode`). Never returns.
    ///
    /// Spawned by another program (node, a shell), this process would be attributed to that program for TCC: it first
    /// re-launches itself with responsibility disclaimed, so Screen Recording / Accessibility are checked against the
    /// app bundle this executable is in; the parent only relays signals and the exit status. The child is this
    /// executable again with the same command line (and `disclaimedEnvironmentKey=1`), so `main.swift` must come back
    /// to the same call.
    public static func run(_ arguments: Arguments, options: Options = Options()) -> Never {
        configure(options)
        if ProcessInfo.processInfo.environment[options.disclaimedEnvironmentKey] != "1" {
            if let status = Respawn.runDisclaimedChild(environmentKey: options.disclaimedEnvironmentKey) {
                exit(status)
            }
            log("running in-process (responsibility_spawnattrs_setdisclaim unavailable or spawn failed)")
        } else {
            log("running as disclaimed child (responsible for its own TCC grants)")
        }

        // --remote (Yoyo Control's menu bar app's service): paired phones reach it over the link; its state lives next
        // to the socket
        // the link listener (docs/LINK.md): the embedder's options, else with --remote Yoyo Control's defaults
        let link = arguments.noLink ? nil : options.link ?? (arguments.remote ? LinkOptions.fromEnvironment() : nil)
        let service = ScreenService(socketPath: arguments.socketPath,
                                    remoteHome: arguments.remote ? (arguments.socketPath as NSString).deletingLastPathComponent : nil,
                                    watchInputElsewhere: options.watchInputElsewhere, link: link)

        Lifecycle.install(socketPath: arguments.socketPath)
        if arguments.exitOnStdinEOF { Lifecycle.watchStdin() }

        service.onFatal = { _ in Lifecycle.cleanupAndExit(1) }
        // coreaudiod restarted while this process captured sound: its taps would read silence from now on, so exit with
        // EX_TEMPFAIL (75); the parent starts a fresh service at once, without its failure backoff.
        ScreenHost.onAudioServiceRestart = { Lifecycle.cleanupAndExit(Lifecycle.restartExitCode) }
        // The sound capture's watchdog found this process's taps deaf (zeros even for a fresh test sound while others
        // play): the same way out (the watchdog rate-limits it to one exit per 15 min across helpers).
        ScreenHost.onAudioDeaf = { Lifecycle.cleanupAndExit(Lifecycle.restartExitCode) }
        do {
            try service.start()
        } catch {
            log("\(error)")
            exit(1)
        }

        // An accessory app (no Dock icon, no menu bar; LSUIElement): AppKit's run loop serves the main queue and draws
        // the automation border (POST /automation, Automation.swift).
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    /// The exit status that asks the parent for a fresh service at once, without counting a failure (EX_TEMPFAIL).
    public static let restartExitCode = Lifecycle.restartExitCode

    /// Ends the serving process (for an embedder's own hooks): the remote listener's port mapping removed (bounded), the
    /// socket file deleted. A second call while the first runs exits at once.
    public static func cleanupAndExit(_ code: Int32) -> Never {
        Lifecycle.cleanupAndExit(code)
    }

    private static func configure(_ options: Options) {
        ScreenHost.logName = options.logName
        if let appName = options.appName { ScreenHost.appName = appName }
    }
}

/// Signal handling, stdin-EOF watching and socket cleanup for the serving process.
enum Lifecycle {
    nonisolated(unsafe) static var socketPathC: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []
    private static let exitLock = NSLock()
    nonisolated(unsafe) private static var exiting = false
    /// "Start me again" (EX_TEMPFAIL): the parent (the app, or a client that spawned it) starts
    /// a fresh service without counting a failure.
    static let restartExitCode: Int32 = 75

    static func install(socketPath: String) {
        socketPathC = strdup(socketPath)
        signal(SIGPIPE, SIG_IGN)
        // SIGTERM / SIGINT: off the signal handler, so the work before exiting may run (the router's port mapping is
        // deleted, bounded); a second signal while that runs exits at once
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler { cleanupAndExit(0) }
            source.resume()
            signalSources.append(source)
        }
    }

    static func cleanupAndExit(_ code: Int32) -> Never {
        exitLock.lock()
        let again = exiting
        exiting = true
        exitLock.unlock()
        if again {
            if let p = socketPathC { unlink(p) }
            _exit(code)
        }
        #if canImport(YoyoLink)
        // the link's UDP mappings go first (within 2 s)
        LinkServer.current?.prepareForExit(timeout: 2)
        #endif
        if let p = socketPathC { unlink(p) }
        exit(code)
    }

    static func watchStdin() {
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 256)
            while true {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n > 0 { continue }
                if n < 0 && errno == EINTR { continue }
                log("stdin closed, exiting")
                cleanupAndExit(0)
            }
        }
    }
}

/// Re-spawns this executable with TCC responsibility disclaimed.
enum Respawn {
    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    nonisolated(unsafe) static var childPid: pid_t = 0

    /// Returns the exit status to use, or nil if we should keep running in-process.
    static func runDisclaimedChild(environmentKey: String) -> Int32? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        let setDisclaim = unsafeBitCast(sym, to: SetDisclaim.self)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        guard setDisclaim(&attr, 1) == 0 else { return nil }

        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var env = ProcessInfo.processInfo.environment
        env[environmentKey] = "1"
        let argv = CommandLine.arguments.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        // Install forwarding before spawning so no signal slips through.
        let forward: @convention(c) (Int32) -> Void = { sig in
            if Respawn.childPid > 0 { kill(Respawn.childPid, sig) }
        }
        signal(SIGTERM, forward)
        signal(SIGINT, forward)

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, nil, &attr, argv, envp)
        guard rc == 0 else {
            log("posix_spawn failed: \(String(cString: strerror(rc)))")
            signal(SIGTERM, SIG_DFL)
            signal(SIGINT, SIG_DFL)
            return nil
        }
        childPid = pid
        log("spawned disclaimed child pid \(pid); relaying signals")

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return 1 }
        }
        let termSig = status & 0x7f
        return termSig == 0 ? (status >> 8) & 0xff : 128 + termSig
    }
}
#endif
