#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// Process-wide settings of the host (`ServiceHost` sets them from its options; Yoyo Control's `yoyo-control` is one host).
public enum ScreenHost {
    /// The app Screen Recording / Accessibility are granted to, named in error messages: the bundle this runs in
    /// (`CFBundleDisplayName`, else `CFBundleName`), else "Yoyo Control".
    nonisolated(unsafe) public static var appName = bundleName ?? "Yoyo Control"
    /// The log prefix (`<logName>[pid]: …`) and the name of this process's power assertions.
    nonisolated(unsafe) public static var logName = "yoyo-control"
    /// Where log lines go (default: stderr, `<logName>[pid]: …`).
    nonisolated(unsafe) public static var logSink: (String) -> Void = { message in
        FileHandle.standardError.write(Data("\(ScreenHost.logName)[\(getpid())]: \(message)\n".utf8))
    }

    /// The name of the app bundle this process runs in; nil outside one.
    static var bundleName: String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = Bundle.main.object(forInfoDictionaryKey: key) as? String, !name.isEmpty { return name }
        }
        return nil
    }

    /// coreaudiod restarted after this process started capturing sound: from then on its taps read silence for other
    /// apps (AudioServiceWatch, AudioWatchdog.swift), which only a new process fixes. `ServiceHost` exits here (its
    /// parent starts a fresh service); nil (a host that must keep running): the capture is rebuilt
    /// in-process, which may not bring the sound back. Called on a Core Audio notification queue.
    nonisolated(unsafe) public static var onAudioServiceRestart: (() -> Void)?
    /// The sound capture's watchdog found this process deaf (AudioWatchdog.swift): its taps read zeros even for a fresh
    /// test sound while other processes play, whatever the cause (a TCC refusal, a coreaudiod restart, none known).
    /// Only a new process has been seen to fix it. `ServiceHost` exits here with 75 (its parent starts a fresh
    /// service); at most once per 15 min across processes (the watchdog keeps the stamp). nil (no hook): the
    /// capture is torn down and rebuilt in-process, and the log says to restart the app. Called on the watchdog's queue.
    nonisolated(unsafe) public static var onAudioDeaf: (() -> Void)?
    /// Files the phone (or the agent) put on this Mac's clipboard through `POST /clipboard` (Clipboard.swift), already
    /// saved by the caller: a host may post a notification that reveals them in Finder.
    /// nil (`ServiceHost`): a log line. Called on the request's thread; a text put does not call it.
    nonisolated(unsafe) public static var onClipboardReceived: ((ClipboardReceipt) -> Void)?
}

func log(_ message: String) {
    ScreenHost.logSink(message)
}

/// The screen service: plain HTTP/1.1 over a unix socket (see README.md「HTTP API」) for local clients.
///
///     let service = ScreenService(socketPath: "/path/screen.sock")
///     try service.start()   // listening
///     service.stop()        // socket removed
///
/// Capture and input run with the hosting process's TCC grants (Yoyo Control.app).
public final class ScreenService: @unchecked Sendable {
    public let socketPath: String
    private let lock = NSLock()
    private var server: HTTPServer?
    /// Whether the console is locked (the screen state's `console`).
    private let consoleWatcher: ConsoleWatcher
    /// The connection state of the displays (ScreenState.swift): `/status`, `/events`, stream status parts.
    private let stateTracker: ScreenStateTracker
    /// The pasteboard's changeCount poll (Clipboard.swift): its changes wake `/events` through the tracker.
    private let clipboard: ClipboardMonitor
    /// The remote listener for paired phones (RemoteAccess.swift), with `remoteHome`.
    public let remote: RemoteAccess?
    /// Input from elsewhere (InputElsewhere.swift), unless the host turned it off.
    private let inputElsewhere: InputElsewhereWatch?
    /// The link listener's options (LinkOptions); default mode runs with remote access, authority mode on its own.
    public let link: LinkOptions?
    #if canImport(YoyoLink)
    private var authorityLink: LinkServer?
    #endif

    /// Called when the listening socket fails for good after `start()` (the service is stopped then).
    public var onFatal: ((String) -> Void)?

    /// `remoteHome`: where remote access keeps its state (the Yoyo Control home); nil = no remote access (a service
    /// another program spawns). `watchInputElsewhere`: report input this process did not post (`/events`
    /// `input-elsewhere`, `/status.inputElsewhere`; needs Accessibility). `link`: the link listener (docs/LINK.md):
    /// default mode beside remote access (needs `remoteHome`), authority mode for a local host (needs `remoteHome`
    /// or `link.keyDirectory` for its keys); nil: none.
    public init(socketPath: String, remoteHome: String? = nil, watchInputElsewhere: Bool = true, link: LinkOptions? = nil) {
        self.socketPath = socketPath
        self.link = link
        remote = remoteHome.map { RemoteAccess(home: $0) }
        if let link, !link.authority { remote?.linkOptions = link }
        inputElsewhere = watchInputElsewhere ? InputElsewhereWatch() : nil
        let tracker = ScreenStateTracker()
        stateTracker = tracker
        clipboard = ClipboardMonitor(onChange: { tracker.noteSideChange() })
        consoleWatcher = ConsoleWatcher { from, to in
            log("console changed (\(from) → \(to))")
            tracker.setNeedsRefresh()
        }
        let watcher = consoleWatcher
        stateTracker.configure(inputs: {
            let session = SessionInfo.current()
            var i = ScreenStateInputs()
            i.loggedIn = session.loggedIn
            i.screenRecording = CGPreflightScreenCaptureAccess()
            i.mainDisplay = CGMainDisplayID()
            i.console = watcher.state
            return i
        })
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return server != nil
    }

    /// Starts listening on `socketPath` (a stale socket file there is replaced). No-op while running.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard server == nil else { return }
        let session = SessionInfo.current()
        log("session: loggedIn=\(session.loggedIn)")
        let s: HTTPServer
        do {
            s = try HTTPServer(path: socketPath, handler: Router.handle)
        } catch let error as HTTPError {
            throw ScreenServiceError(message: "cannot listen on \(socketPath): \(error.message)")
        }
        s.onFatal = { [weak self] why in
            guard let self else { return }
            self.lock.lock()
            if self.server === s { self.server = nil }
            self.lock.unlock()
            self.onFatal?(why)
        }
        consoleWatcher.start()
        ConsoleWatcher.current = consoleWatcher
        stateTracker.start()
        if session.loggedIn { clipboard.start() }  // no pasteboard without a GUI session
        s.start()
        server = s
        log("listening on \(socketPath)")
        remote?.start()
        startAuthorityLink()
        inputElsewhere?.start()
        // Probe the video encoders and measure their size/latency trade-off now, not when the first stream opens.
        VideoEncoder.calibrateInBackground()
    }

    /// Stops listening and removes the socket file.
    public func stop() {
        lock.lock()
        let s = server
        server = nil
        lock.unlock()
        remote?.stop()
        #if canImport(YoyoLink)
        lock.lock()
        let l = authorityLink
        authorityLink = nil
        lock.unlock()
        l?.stop()
        LinkAuthority.current = nil
        #endif
        inputElsewhere?.stop()
        consoleWatcher.stop()
        if ConsoleWatcher.current === consoleWatcher { ConsoleWatcher.current = nil }
        clipboard.stop()
        stateTracker.stop()  // `/events` subscribers end
        guard let s else { return }
        s.stop()
        log("stopped")
    }
}

extension ScreenService {
    /// Authority mode: the link listener with its own identity (in `keyDirectory`, else the remote home) and the
    /// host's channel (LinkAuthority). Called with `lock` held.
    private func startAuthorityLink() {
        guard let link, link.authority else {
            if link != nil, remote == nil { log("link: off: default mode needs remote access (--remote)") }
            return
        }
        #if canImport(YoyoLink)
        guard let dir = link.keyDirectory ?? remote?.home else {
            log("link: off: authority mode needs a key directory (LinkOptions.keyDirectory)")
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let identity = try RemoteIdentity.loadOrCreate(directory: dir)
            let authority = LinkAuthority()
            LinkAuthority.current = authority
            let id = String(identity.fingerprint.dropFirst("sha256:".count).prefix(32))
            let server = LinkServer(options: link, mode: .authority(authority),
                                    identity: .init(serverId: id, name: RemoteAccess.macName, key: identity.signingKey),
                                    keyDirectory: dir)
            authorityLink = server
            server.start()
        } catch {
            log("link: off: no identity in \(dir) (\(error))")
        }
        #else
        log("link: off: this build has no YoyoLink (scripts/link-apple.sh build)")
        #endif
    }
}

public struct ScreenServiceError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// The two TCC grants capture and input need, for the current process.
public enum ScreenPermissions {
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    public static var accessibility: Bool { AXIsProcessTrusted() }

    /// Shows the Screen Recording prompt (first time) or nothing; true when granted.
    @discardableResult
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// Shows the Accessibility prompt (adds the app to the list, switched off); true when granted.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Both prompts (POST /permissions/request).
    public static func requestAll() {
        _ = requestScreenRecording()
        _ = requestAccessibility()
    }

    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    public static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    /// System Settings → Privacy & Security → Accessibility.
    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
#endif
