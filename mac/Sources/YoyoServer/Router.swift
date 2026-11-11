#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

enum Router {
    static func handle(_ req: HTTPRequest, _ conn: Connection) throws {
        switch (req.method, req.path) {
        case ("GET", "/status"): status(conn)
        case ("GET", "/frame"): try frame(req, conn)
        case ("GET", "/stream"): try stream(req, conn)
        case ("POST", "/input"): try input(req, conn)
        case ("POST", "/permissions/request"): requestPermissions(conn)
        case ("POST", "/stream/ack"): try streamAck(req, conn)
        case ("GET", "/events"): try events(conn)
        case ("GET", "/focus"): try focus(req, conn)
        case ("GET", "/audio"): try audio(req, conn)
        case ("GET", "/audio/stats"): audioStats(conn)
        case ("GET", "/clipboard"): try clipboard(req, conn)
        case ("POST", "/clipboard"): try clipboardWrite(req, conn)
        case ("GET", "/clipboard/image"): try clipboardImage(conn)
        case ("GET", "/clipboard/file"): try clipboardFile(req, conn)
        case ("GET", "/windows"): try windows(req, conn)
        case ("GET", "/hit"): try hit(req, conn)
        case ("GET", "/app/windows"): try appWindows(req, conn)
        case ("GET", "/app/screenshot"): try appScreenshot(req, conn)
        case ("GET", "/app/ax"): conn.json(200, try AXSummary.answer(req))
        case ("POST", "/automation"), ("POST", "/agent-control"): try automation(req, conn)
        case ("POST", "/control"): try control(req, conn)
        case ("POST", "/console/unlock"): try consoleUnlock(req, conn)
        case ("POST", "/console/lock"): try consoleLock(req, conn)
        case ("GET", "/remote"): conn.json(200, try remoteAccess(req).json)
        case ("POST", "/remote/pairing"): conn.json(200, try remoteAccess(req).startPairing())
        case ("POST", "/remote/pairing/stop"): try remoteAccess(req).stopPairing(); conn.json(200, try remoteAccess(req).json)
        case ("POST", "/remote/enabled"): try remoteEnabled(req, conn)
        case ("POST", "/remote/direct"): try remoteDirect(req, conn)
        case ("POST", "/remote/devices/remove"): try remoteRemove(req, conn)
        case ("POST", "/remote/disconnect"): try remoteDisconnect(req, conn)
        case ("POST", "/remote/account/leave"): try remoteAccountLeave(req, conn)
        case ("GET", "/account"): try account(req, conn)
        case ("POST", "/account/join"): try accountJoin(req, conn)
        case ("POST", "/account/invite"): try accountInvite(req, conn)
        case ("GET", "/link/authority"): try linkAuthority(req, conn)
        case ("POST", "/link/authority/answer"): try linkAuthorityAnswer(req, conn)
        case ("POST", "/link/control"): try linkControl(req, conn)
        case ("POST", "/link/rtc"): try linkRtc(req, conn)
        case (_, "/link/rtc"):
            guard req.remote == nil else { throw HTTPError(404, "no such endpoint \(req.path)") }
            throw HTTPError(405, "method \(req.method) not allowed on \(req.path)")
        case (_, "/link/authority"), (_, "/link/authority/answer"), (_, "/link/control"):
            guard req.remote == nil, LinkAuthority.current != nil else { throw HTTPError(404, "no such endpoint \(req.path)") }
            throw HTTPError(405, "method \(req.method) not allowed on \(req.path)")
        case (_, "/console/unlock"), (_, "/console/lock"):
            guard req.remote == nil else { throw HTTPError(404, "no such endpoint \(req.path)") }
            throw HTTPError(405, "method \(req.method) not allowed on \(req.path)")
        case (_, "/control"), (_, "/remote"), (_, "/remote/pairing"), (_, "/remote/pairing/stop"), (_, "/remote/enabled"),
             (_, "/remote/direct"), (_, "/remote/devices/remove"), (_, "/remote/disconnect"), (_, "/remote/account/leave"),
             (_, "/account"), (_, "/account/join"), (_, "/account/invite"):
            throw HTTPError(405, "method \(req.method) not allowed on \(req.path)")
        case (_, "/status"), (_, "/frame"), (_, "/stream"), (_, "/input"), (_, "/permissions/request"),
             (_, "/stream/ack"), (_, "/events"), (_, "/focus"), (_, "/audio"), (_, "/audio/stats"), (_, "/clipboard"),
             (_, "/clipboard/image"), (_, "/clipboard/file"),
             (_, "/windows"), (_, "/hit"), (_, "/app/windows"), (_, "/app/screenshot"), (_, "/app/ax"), (_, "/automation"), (_, "/agent-control"):
            throw HTTPError(405, "method \(req.method) not allowed on \(req.path)")
        default:
            throw HTTPError(404, "no such endpoint \(req.path)")
        }
    }

    static func status(_ conn: Connection) {
        let session = SessionInfo.current()
        let displays = session.loggedIn ? Displays.active() : []
        var body: [String: Any] = [
            "ok": !displays.isEmpty,
            "session": session.json,
            "screenRecording": CGPreflightScreenCaptureAccess(),
            "accessibility": AXIsProcessTrusted(),
            // WindowServer's, then the embedder's (ExternalDisplay.swift: listed whatever the session and permissions are)
            "displays": displays.map(\.json) + ExternalDisplays.json,
        ]
        if displays.isEmpty { body["error"] = Displays.noDisplayReason() }
        // the connection state (ScreenState.swift), as the latest `/events` line has it
        if let tracker = ScreenStateTracker.current {
            let snap = tracker.snapshot
            body["states"] = snap.states.map(\.json)
            body["console"] = snap.console?.json ?? NSNull()
        }
        let automation = Automation.shared.json
        body["automation"] = automation
        body["agentControl"] = automation.filter { $0.key != "label" }  // the older name
        body["control"] = RemoteControl.shared.json
        // input this process did not post (InputElsewhere.swift): the latest, and whether the tap is in
        let elsewhere = InputElsewhereWatch.current
        body["inputElsewhere"] = elsewhere?.statusJSON ?? NSNull()
        var features: [String: Any] = ["inputElsewhere": elsewhere?.installed ?? false]
        // uu Link (docs/LINK.md): the listener's binding, port and addresses while it runs
        let link = LinkStatus.current?()
        if let link { body["link"] = link }
        features["link"] = link != nil
        body["features"] = features
        body.merge(ServerIdentity.json) { _, identity in identity }
        conn.json(200, body)
    }

    /// `GET /focus[?display=]`: whether the focused element takes typing (FocusProbe). This session's: `display` is
    /// accepted (and validated) but does not change the answer.
    static func focus(_ req: HTTPRequest, _ conn: Connection) throws {
        _ = try req.int("display")
        conn.json(200, FocusProbe.current().json)
    }

    /// `GET /windows[?display=]`: the apps with on-screen windows, the windows front → back (normalized on their
    /// display; only `display`'s when given) and the focused app (Windows.swift). No titles.
    static func windows(_ req: HTTPRequest, _ conn: Connection) throws {
        let requested = try req.int("display")
        let display = try requested.map { try Displays.resolve($0) }
        let catalog = WindowCatalog.current()
        conn.json(200, catalog.json(display: display, focused: catalog.focusedApp()))
    }

    /// `GET /hit?display=&x=&y=`: the owner of the topmost on-screen window at the normalized point (Windows.swift); the
    /// system's hit test decides when an overlay is in front there, Accessibility whose part of the menu bar it is
    /// (MenuBar.swift; `menuBar` says which part).
    static func hit(_ req: HTTPRequest, _ conn: Connection) throws {
        let x = try unitParameter(req, "x"), y = try unitParameter(req, "y")
        let display = try Displays.resolve(try req.int("display"))
        let found = WindowCatalog.current().hit(display: display, x: x, y: y, axPid: AXHit.pid(at:), menuBar: .live)
        var body: [String: Any] = ["app": found?.app.json ?? NSNull(), "layer": found.map { $0.layer as Any } ?? NSNull()]
        if let area = found?.menuBar { body["menuBar"] = area.rawValue }
        conn.json(200, body)
    }

    // MARK: Background mode and automation (AppWindows.swift, AppAX.swift, Automation.swift)

    /// `GET /app/windows?bundleId=`: the app's windows, off-screen and minimized ones too.
    static func appWindows(_ req: HTTPRequest, _ conn: Connection) throws {
        guard let id = req.query["bundleId"]?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            throw HTTPError(400, "bundleId is required")
        }
        conn.json(200, AppWindows.list(bundleId: id))
    }

    /// `GET /app/screenshot?window=&maxWidth=&quality=`: one window's picture.
    static func appScreenshot(_ req: HTTPRequest, _ conn: Connection) throws {
        let shot = try AppWindows.screenshot(req)
        var headers: [(String, String)] = [
            ("X-Frame-Width", "\(shot.frame.width)"),
            ("X-Frame-Height", "\(shot.frame.height)"),
            ("X-Window", "\(shot.window)"),
            ("Cache-Control", "no-store"),
        ]
        if let (display, rect) = shot.bounds {
            headers.append(("X-Display", "\(display)"))
            headers.append(("X-Window-Bounds", AppWindows.boundsHeader(rect)))
        }
        conn.respond(status: 200, contentType: "image/jpeg", body: shot.frame.data, extraHeaders: headers)
    }

    /// `POST /automation { active, label? }` (or the older `POST /agent-control`) → `{ ok: true, active, esc, label? }`.
    static func automation(_ req: HTTPRequest, _ conn: Connection) throws {
        let (active, label) = try Automation.parse(req.body)
        var answer = Automation.shared.set(active: active, label: label).json
        answer["ok"] = true
        conn.json(200, answer)
    }

    // MARK: Remote access (RemoteAccess.swift, RemoteControl.swift; docs/REMOTE.md)

    /// `POST /control { controller: "user" | "none" }` from a paired phone → `{ ok: true, control }`: takes control
    /// (always succeeds) or lets go of its own.
    static func control(_ req: HTTPRequest, _ conn: Connection) throws {
        guard let device = req.remote else { throw HTTPError(404, "POST /control is for paired devices (over the link)") }
        let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
        switch body?["controller"] as? String {
        case "user": RemoteControl.shared.take(device)
        case "none": RemoteControl.shared.release(device)
        default: throw HTTPError(400, "controller must be \"user\" or \"none\"")
        }
        conn.json(200, ["ok": true, "control": RemoteControl.shared.json])
    }

    /// The `/remote*` management routes: the unix socket's only (the menu bar app), and only with `--remote`.
    private static func remoteAccess(_ req: HTTPRequest) throws -> RemoteAccess {
        guard req.remote == nil else { throw HTTPError(404, "no such endpoint \(req.path)") }
        guard let access = RemoteAccess.current else { throw HTTPError(404, "remote access is not on in this process (no --remote)") }
        return access
    }

    /// `POST /remote/enabled { enabled }` → `GET /remote`'s answer.
    static func remoteEnabled(_ req: HTTPRequest, _ conn: Connection) throws {
        let access = try remoteAccess(req)
        guard let on = (try jsonBody(req))["enabled"] as? Bool else { throw HTTPError(400, "enabled must be a boolean") }
        access.setEnabled(on)
        conn.json(200, access.json)
    }

    /// `POST /remote/direct { enabled }` → `GET /remote`'s answer (docs/REMOTE.md「外网直连」).
    static func remoteDirect(_ req: HTTPRequest, _ conn: Connection) throws {
        let access = try remoteAccess(req)
        guard let on = (try jsonBody(req))["enabled"] as? Bool else { throw HTTPError(400, "enabled must be a boolean") }
        access.setDirect(on)
        conn.json(200, access.json)
    }

    /// `POST /remote/devices/remove { id }` → `GET /remote`'s answer; 404 for a device not paired.
    static func remoteRemove(_ req: HTTPRequest, _ conn: Connection) throws {
        let access = try remoteAccess(req)
        guard let id = (try jsonBody(req))["id"] as? String else { throw HTTPError(400, "id is required") }
        guard access.devices.remove(id: id) else { throw HTTPError(404, "no paired device \(id)") }
        log("remote: removed device \(id)")
        conn.json(200, access.json)
    }

    /// `POST /remote/disconnect`: the phone holding control loses it (it stays paired) → `GET /remote`'s answer.
    static func remoteDisconnect(_ req: HTTPRequest, _ conn: Connection) throws {
        let access = try remoteAccess(req)
        RemoteControl.shared.releaseAny(why: "disconnected from the Mac's menu")
        conn.json(200, access.json)
    }

    /// A required normalized coordinate (0…1).
    static func unitParameter(_ req: HTTPRequest, _ name: String) throws -> Double {
        guard let raw = req.query[name], !raw.isEmpty else { throw HTTPError(400, "\(name) is required") }
        guard let v = Double(raw), v.isFinite, v >= 0, v <= 1 else { throw HTTPError(400, "\(name) must be a number in 0…1") }
        return v
    }

    /// `/frame`'s capture parameters with its `visible=` / `crop=` filter (streams take neither).
    static func frameCaptureParams(_ req: HTTPRequest) throws -> CaptureParams {
        var params = try CaptureParams(req)
        params.filter = try FrameFilter.parse(req.query)
        return params
    }

    /// How often `/events` writes a ping line while nothing changes.
    static let eventsPingInterval: TimeInterval = 15

    /// `GET /events`: NDJSON, close-delimited. `{"type":"state","states":[…],"console":…}` at once and after every
    /// change, `{"type":"clipboard",…}` (the clipboard's summary, Clipboard.swift) right after it and on every change
    /// of the pasteboard, one-off lines posted meanwhile (`{"type":"abort","reason":"esc"}`, Automation.swift),
    /// `{"type":"ping"}` every 15 s otherwise. Ends when the client hangs up or the service stops.
    static func events(_ conn: Connection, pingInterval: TimeInterval = eventsPingInterval) throws {
        guard let tracker = ScreenStateTracker.current else { throw HTTPError(503, "the screen state is not running") }
        guard conn.writeHead(status: 200, headers: [
            ("Content-Type", "application/x-ndjson"),
            ("Cache-Control", "no-cache"),
        ]) else { return }
        var posted = tracker.postedSeq  // one-off lines (an Esc's abort) only from now on
        var snap = tracker.snapshot
        guard conn.write(ScreenStateTracker.eventLine(states: snap.states, console: snap.console)) else { return }
        var stateVersion = snap.stateVersion
        var clipboardChange: Int?
        /// The clipboard line when the monitor saw a count this response has not written yet.
        func writeClipboard() -> Bool {
            guard let item = ClipboardMonitor.current?.latestSummary, item.changeCount != clipboardChange else { return true }
            clipboardChange = item.changeCount
            return conn.write(Clipboard.eventLine(item))
        }
        guard writeClipboard() else { return }
        var lastWrite = Date()
        while !conn.peerClosed() {
            // wake at least once a second to notice a hung-up client
            let deadline = min(lastWrite.addingTimeInterval(pingInterval), Date().addingTimeInterval(1))
            guard let version = tracker.waitForChange(after: snap.version, until: deadline) else { return }  // stopped
            if version != snap.version {
                snap = tracker.snapshot
                if snap.stateVersion != stateVersion {
                    stateVersion = snap.stateVersion
                    guard conn.write(ScreenStateTracker.eventLine(states: snap.states, console: snap.console)) else { return }
                }
                guard writeClipboard() else { return }
                for line in tracker.posted(after: posted) {
                    posted = line.seq
                    guard conn.write(line.line) else { return }
                }
                lastWrite = Date()
            } else if Date().timeIntervalSince(lastWrite) >= pingInterval {
                guard conn.write(ScreenStateTracker.pingLine) else { return }
                lastWrite = Date()
            }
        }
    }

    /// `GET /frame`: one ScreenCaptureKit picture as JPEG.
    static func frame(_ req: HTTPRequest, _ conn: Connection) throws {
        if let external = try ExternalDisplays.requested(req) { return respondFrame(try frameExternal(req, external), conn) }
        respondFrame(try captureFrame(frameCaptureParams(req)), conn)
    }

    private static func respondFrame(_ frame: JPEGFrame, _ conn: Connection) {
        conn.respond(status: 200, contentType: "image/jpeg", body: frame.data, extraHeaders: [
            ("X-Frame-Width", "\(frame.width)"),
            ("X-Frame-Height", "\(frame.height)"),
            ("X-Display", "\(frame.display)"),
            ("Cache-Control", "no-store"),
        ] + (frame.crop.map { [("X-Crop", FrameFilter.cropHeader($0))] } ?? [])
          + (frame.filter.map { [("X-Frame-Filter", $0.rawValue)] } ?? []))
    }

    /// `GET /stream`: a ScreenCaptureKit video stream of a display.
    static func stream(_ req: HTTPRequest, _ conn: Connection) throws {
        if let external = try ExternalDisplays.requested(req) { return try streamExternal(req, conn, external) }
        // the last stream closing lifts a button a live drag left down (PointerHold.swift)
        PointerHolds.shared.streamOpened()
        defer { PointerHolds.shared.streamClosed() }
        // No video encoder at all is a 503 before anything else happens.
        _ = try StreamRequestOptions.parse(req).codec()
        let status = try statusRequested(req)
        let setup = try captureSetup(req)
        let fps = setup.fps
        let display = setup.params.display
        let frames = FrameStream(setup.params, fps: fps, showsCursor: !setup.options.cursorClient)
        defer { frames.stop() }
        try frames.start(fps: fps)
        // a capture that stops before its first frame is an error; a slow one keeps going (late frames still go out)
        let why = "no ScreenCaptureKit frame in \(Int((firstFrameWait * 1000).rounded())) ms"
        switch frames.firstFrame(within: firstFrameWait) {
        case .firstFrame: break
        case .noFirstFrame: log("display \(display): \(why); keeping ScreenCaptureKit")
        case .failed: throw HTTPError(503, "display \(display): \(why)")
        }
        log("display \(display): stream open (\(setupLine(setup, frames)))")
        try serveCapture(req, conn, frames, setup, status: status)
    }

    /// How long a new stream waits for ScreenCaptureKit's first complete frame before its head goes out.
    static let firstFrameWait: TimeInterval = 1.5

    /// A ScreenCaptureKit stream's setup from the request.
    struct CaptureSetup {
        /// The capture parameters, the video width cap applied.
        var params: CaptureParams
        var options: StreamRequestOptions
        var codec: VideoCodec
        var fps: Int
    }

    static func captureSetup(_ req: HTTPRequest) throws -> CaptureSetup {
        var params = try CaptureParams(req)
        let options = try StreamRequestOptions.parse(req)
        let codec = try options.codec()
        let display = params.display
        params.maxWidth = videoWidthCap(codec: codec, clientMaxWidth: params.maxWidth) {
            Displays.targetSize(display, maxWidth: $0)
        }
        let fps = videoFPS(requested: try req.int("fps"))
        return CaptureSetup(params: params, options: options, codec: codec, fps: fps)
    }

    /// `h264 @60 fps stream <id>, cursor client, maxKbps 3000` for a stream's open line.
    static func setupLine(_ s: CaptureSetup, _ frames: FrameStream) -> String {
        "\(s.codec.rawValue) @\(s.fps) fps"
            + "\(s.options.streamID.map { " stream \($0)" } ?? "")\(frames.showsCursor ? "" : ", cursor client")"
            + "\(s.options.maxKbps.map { ", maxKbps \($0)" } ?? "")"
    }

    /// Serve a started ScreenCaptureKit capture as the response: head, status parts, then video parts until the client
    /// hangs up.
    private static func serveCapture(_ req: HTTPRequest, _ conn: Connection, _ frames: FrameStream, _ setup: CaptureSetup,
                                     status: Bool) throws {
        let display = setup.params.display
        let id = setup.options.streamID
        var head: [(String, String)] = [
            ("Content-Type", conn.wire.stream),
            ("Cache-Control", "no-store"),
            ("X-Display", "\(display)"),
            ("X-Stream-Codec", setup.codec.rawValue),
        ]
        if let id { head.append(("X-Stream-Id", id)) }
        guard conn.writeHead(status: 200, headers: head) else { return }
        if status, let feed = try statusFeed(req, display: display) {
            guard startStatus(feed, conn) else { return }
        }
        var o = VideoStreamOptions(codec: setup.codec, label: "video: display stream\(id.map { " \($0)" } ?? "")")
        o.streamID = id
        o.interval = 1 / Double(setup.fps)
        o.tuning = StreamTuning.current.limited(toKbps: setup.options.maxKbps)
        o.statsInterval = 10
        // cursor=client (the pictures leave the pointer out): the pointer as cursor parts.
        var pointer: DisplayPointerTracker?
        if !frames.showsCursor {
            let tracker = DisplayPointerTracker(display: display)
            tracker.start()
            pointer = tracker
            frames.pointer = tracker
        }
        defer {
            if let pointer {
                pointer.stop()
                log("display \(display): stream\(id.map { " \($0)" } ?? "") pointer: "
                    + (pointer.systemShapes > 0 ? "\(pointer.systemShapes) system cursor shape(s)" : "built-in arrow"))
            }
        }
        videoStreamLoop(frames, conn, o)
    }

    static func input(_ req: HTTPRequest, _ conn: Connection) throws {
        let event: InputEvent
        do {
            event = try JSONDecoder().decode(InputEvent.self, from: req.body)
        } catch {
            throw HTTPError(400, "invalid JSON body: \(error.localizedDescription)")
        }
        // a paired phone needs control; the unix socket's input waits while a phone holds it (RemoteControl.swift)
        try RemoteControl.shared.admitInput(from: req.remote)
        // A pointer move older than one already applied (the phone pipelines moves; they may overtake each other): not
        // applied, whatever path it would take (PointerMoveGate, Input.swift).
        if event.type == "move", let seq = event.seq {
            guard seq >= 0 else { throw HTTPError(400, "seq must be a non-negative integer") }
            guard PointerMoveGate.shared.admit(seq: seq) else {
                conn.json(200, ["ok": true, "stale": true])
                return
            }
        }
        let tap: CGEventTapLocation = .cghidEventTap
        let action = try Input.plan(event, tap: tap)  // validate first: bad input is 400 even without permission
        guard AXIsProcessTrusted() else {
            throw HTTPError(403, "Accessibility permission is not granted to \(ScreenHost.appName)")
        }
        notePointer(event, display: nil)
        if Input.interruptsScroll(event.type) { ScrollSynth.for(tap).interrupt() }
        action()
        if isHoldEvent(event), let display = try? Displays.resolve(event.display) {
            noteHold(event, display: display, route: "cg") { x, y in
                Input.release(at: Input.globalPoint(display, x: x, y: y), tap: tap)
            }
        }
        conn.json(200, ["ok": true])
    }

    /// Whether `event` is part of a live drag (`down`, `up`, a held `move`).
    static func isHoldEvent(_ e: InputEvent) -> Bool {
        e.type == "down" || e.type == "up" || (e.type == "move" && e.button != nil)
    }

    /// A live drag's step went out on `route` for `display`: the stall guard (PointerHold.swift) learns of it. `release`
    /// lifts the button on that path.
    static func noteHold(_ e: InputEvent, display: CGDirectDisplayID, route: String, holds: PointerHolds = .shared,
                         release: @escaping PointerHolds.Release) {
        guard isHoldEvent(e), let x = e.x, let y = e.y else { return }
        let (cx, cy) = (min(max(x, 0), 1), min(max(y, 0), 1))
        switch e.type {
        case "down": holds.pressed(display: display, route: route, x: cx, y: cy, release: release)
        case "up": holds.released(display: display, route: route, x: cx, y: cy)
        default: holds.moved(display: display, x: cx, y: cy)
        }
    }

    /// A `cursor=client` ScreenCaptureKit stream of the display takes the position the input leaves the pointer at,
    /// before the pictures show it (DisplayPointer.swift).
    private static func notePointer(_ event: InputEvent, display: CGDirectDisplayID?) {
        guard DisplayPointerTracker.anyRunning, let id = display ?? (try? Displays.resolve(event.display)) else { return }
        DisplayPointerTracker.noteInput(event, display: id)
    }

    // MARK: Clipboard (Clipboard.swift; docs/PROTOCOL.md 「剪贴板」)

    /// The pasteboard needs a GUI session (so does `ClipboardMonitor`, started only with one).
    private static func clipboardSession() throws -> ClipboardMonitor? {
        guard SessionInfo.current().loggedIn else {
            throw HTTPError(503, "this macOS account has no GUI login session, so it has no clipboard")
        }
        return ClipboardMonitor.current
    }

    /// `GET /clipboard[?text=0]`: what the pasteboard holds now (`ClipboardItem` + `ok`); `text=0` leaves the text out.
    static func clipboard(_ req: HTTPRequest, _ conn: Connection) throws {
        let monitor = try clipboardSession()
        let item = Clipboard.read(.general, includeText: req.query["text"] != "0", monitor: monitor)
        var body = item.json
        body["ok"] = true
        conn.json(200, body)
    }

    /// `GET /clipboard/image`: the image item as PNG; 404 for anything else (a concealed item included).
    static func clipboardImage(_ conn: Connection) throws {
        let monitor = try clipboardSession()
        let item = Clipboard.read(.general, includeText: false, monitor: monitor)
        guard item.kind == .image, let png = monitor?.png(for: item.changeCount, make: { Clipboard.pngData(.general) }) ?? Clipboard.pngData(.general) else {
            throw HTTPError(404, "the clipboard holds no image")
        }
        conn.respond(status: 200, contentType: "image/png", body: png.data, extraHeaders: [
            ("X-Clipboard-Change-Count", "\(item.changeCount)"),
            ("Cache-Control", "no-store"),
        ])
    }

    /// `GET /clipboard/file?index=N`: file N of a `files` item, streamed in chunks (never whole in memory); its name in
    /// `Content-Disposition` (`filename*`, RFC 6266). 400 a folder,
    /// 404 not a files item / out of range / gone.
    static func clipboardFile(_ req: HTTPRequest, _ conn: Connection) throws {
        let monitor = try clipboardSession()
        guard let index = try req.int("index"), index >= 0 else { throw HTTPError(400, "index is required") }
        let item = Clipboard.read(.general, includeText: false, monitor: monitor)
        guard item.kind == .files else { throw HTTPError(404, "the clipboard holds no files") }
        guard index < item.fileURLs.count else { throw HTTPError(404, "no file \(index) on the clipboard") }
        let url = item.fileURLs[index]
        let info = Clipboard.fileInfo(url)
        if info.dir { throw HTTPError(400, "\(info.name) is a folder; copy its contents") }
        guard let size = info.size, let handle = try? FileHandle(forReadingFrom: url) else {
            throw HTTPError(404, "\(info.name) is no longer there")
        }
        defer { try? handle.close() }
        let encodedName = info.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
        guard conn.writeHead(status: 200, headers: [
            ("Content-Type", Clipboard.mimeType(for: url)),
            ("Content-Length", "\(size)"),
            ("Content-Disposition", "attachment; filename*=UTF-8''\(encodedName)"),
            ("X-Clipboard-Change-Count", "\(item.changeCount)"),
            ("Cache-Control", "no-store"),
        ]) else { return }
        var remaining = size
        while remaining > 0 {
            let chunk = handle.readData(ofLength: min(256 * 1024, remaining))
            if chunk.isEmpty { return }  // shrank meanwhile: the client sees a short body
            guard conn.write(chunk) else { return }
            remaining -= chunk.count
        }
    }

    /// `POST /clipboard` `{ text }` or `{ files: ["/abs/path"…], source?: "phone" | "agent" }` (default "phone"):
    /// replaces the pasteboard's contents, remembers who did it (`source` of that changeCount), tells the host about
    /// files (`ScreenHost.onClipboardReceived`), answers like `GET /clipboard`.
    static func clipboardWrite(_ req: HTTPRequest, _ conn: Connection) throws {
        let monitor = try clipboardSession()
        guard let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            throw HTTPError(400, "body must be a JSON object")
        }
        let source = req.remote == nil ? body["source"] as? String ?? "phone" : "phone"
        guard source == "phone" || source == "agent" else { throw HTTPError(400, "source must be \"phone\" or \"agent\"") }
        // a paired phone's paths would be this Mac's files it named: text only from there
        if req.remote != nil && body["text"] == nil { throw HTTPError(400, "body needs text (a string)") }
        let changeCount: Int
        if let text = body["text"] as? String {
            guard !text.isEmpty else { throw HTTPError(400, "text is empty") }
            guard text.utf8.count <= Clipboard.textMax else { throw HTTPError(413, "text is too long (max \(Clipboard.textMax) bytes)") }
            changeCount = Clipboard.write(.general, text: text)
            log("clipboard: \(text.utf8.count) bytes of text from the \(source)")
        } else if let paths = body["files"] as? [String], !paths.isEmpty {
            guard paths.count <= Clipboard.filesMax else { throw HTTPError(400, "at most \(Clipboard.filesMax) files") }
            var urls: [URL] = []
            for path in paths {
                guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
                    throw HTTPError(400, "\(path) is not an existing file or folder")
                }
                urls.append(URL(fileURLWithPath: path))
            }
            changeCount = Clipboard.write(.general, files: urls)
            let receipt = ClipboardReceipt(names: urls.map(\.lastPathComponent), paths: urls.map(\.path), source: source)
            log("clipboard: \(urls.count) file(s) from the \(source): \(receipt.names.joined(separator: ", "))")
            ScreenHost.onClipboardReceived?(receipt)
        } else {
            throw HTTPError(400, "body needs text (a string) or files (paths)")
        }
        monitor?.noteOwnWrite(changeCount: changeCount, source: source)
        monitor?.poll()  // `/events` subscribers learn of it now, not at the next tick
        var answer = Clipboard.read(.general, includeText: true, monitor: monitor).json
        answer["ok"] = true
        conn.json(200, answer)
    }

    static func jsonBody(_ req: HTTPRequest) throws -> [String: Any] {
        guard let body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            throw HTTPError(400, "body must be a JSON object")
        }
        return body
    }

    static func requestPermissions(_ conn: Connection) {
        ScreenPermissions.requestAll()
        conn.json(200, [
            "ok": true,
            "screenRecording": CGPreflightScreenCaptureAccess(),
            "accessibility": AXIsProcessTrusted(),
        ])
    }
}
#endif
