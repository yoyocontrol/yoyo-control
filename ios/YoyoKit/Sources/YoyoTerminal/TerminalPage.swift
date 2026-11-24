import SwiftTerm
import UIKit
import YoyoCore

/// The kit's Terminal page.
public enum YoyoTerminal {
    /// The Terminal page for `backend`'s computer (`YoyoBackend.hasTerminal`), to push on a navigation controller (the
    /// Screen page's: `YoyoScreen.makePage(backend:host:pages:)`). It shows the navigation bar while it is on top.
    @MainActor public static func makePage(backend: any YoyoBackend) -> UIViewController {
        TerminalPage(backend: backend)
    }
}

/// "Terminal": a shell on the computer (docs/PROTOCOL.md「终端」), drawn by SwiftTerm. The terminal lives on the
/// computer: leaving the page, locking the phone or losing the network only detaches it, and the page attaches again by
/// itself (from the last byte it has, so nothing is drawn twice; a page that has no copy gets the computer's kept output
/// and the program redraws). Which terminal the page shows is remembered per computer (`<namespace>Terminal.<scope>`),
/// so the next visit, even after the app was closed, comes back to it.
///
/// The keyboard comes up with the page; over it the key row (`TerminalKeyBar`: esc, sticky ctrl / alt, tab, ⇧tab, ^C,
/// arrows that repeat, a new line that doesn't send, symbols, paste, the composer). A pinch changes the font size
/// (kept). The navigation bar's menu lists the computer's terminals (switch to one), opens a new one, or ends this one.
/// When the shell exits, a card says so and offers a new one.
@MainActor
final class TerminalPage: UIViewController, @preconcurrency TerminalViewDelegate {
    private let backend: any YoyoBackend
    private let terminal: TerminalView
    private let keyBar = TerminalKeyBar()
    private let card = TerminalCard()

    private enum State: Equatable {
        case idle, connecting, live, reconnecting
        /// The computer says no terminals (`YoyoTerminalError.off`).
        case off
        /// Its shell exited, or it was ended there.
        case ended(String)
        /// Another page or phone took it.
        case elsewhere
        case failed(String)
    }
    private var state = State.idle { didSet { stateChanged() } }

    /// The terminal shown (the computer's id for it), nil: a new one is opened.
    private var sessionId: String? {
        didSet { UserDefaults.standard.set(sessionId, forKey: Self.sessionKey(backend)) }
    }
    /// The bytes of its output this page's copy has (to attach from there); nil: no copy yet.
    private var offset: UInt64?
    private var channel: (any YoyoTerminalChannel)?
    private var task: Task<Void, Never>?
    /// Bumped by every attach: an older run that ends late leaves `task` alone.
    private var generation = 0
    private var visible = false
    private var retryDelay: Duration = .milliseconds(300)
    private var title0 = L("Terminal")
    private var draft = ""
    private var observers: [NSObjectProtocol] = []
    /// The navigation controller's own style, given back when the page goes (the bar is dark while it shows).
    private var navStyle: UIUserInterfaceStyle?

    static func sessionKey(_ backend: any YoyoBackend) -> String { YoyoHost.key("Terminal.\(backend.cacheScope)") }
    static var fontKey: String { YoyoHost.key("TerminalFontSize") }
    static let background = UIColor(red: 0.055, green: 0.055, blue: 0.063, alpha: 1)

    init(backend: any YoyoBackend) {
        self.backend = backend
        let saved = UserDefaults.standard.double(forKey: Self.fontKey)
        let size = saved >= 7 && saved <= 28 ? saved : 12
        terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480),
                                font: .monospacedSystemFont(ofSize: size, weight: .regular))
        sessionId = UserDefaults.standard.string(forKey: Self.sessionKey(backend))
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        channel?.close()
        task?.cancel()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Self.background
        navigationItem.title = title0
        navigationItem.largeTitleDisplayMode = .never
        view.accessibilityIdentifier = "terminal"

        terminal.terminalDelegate = self
        terminal.nativeBackgroundColor = Self.background
        terminal.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        terminal.caretColor = Theme.coral
        terminal.optionAsMetaKey = true
        terminal.keyboardAppearance = .dark
        terminal.inputAccessoryView = keyBar
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.accessibilityIdentifier = "terminal.view"
        view.addSubview(terminal)
        keyBar.onKey = { [weak self] key in self?.key(key) }
        terminal.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))

        card.translatesAutoresizingMaskIntoConstraints = false
        card.isHidden = true
        view.addSubview(card)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 4),
            terminal.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -4),
            terminal.topAnchor.constraint(equalTo: safe.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            card.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: terminal.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -40),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        let menu = UIBarButtonItem(title: nil, image: UIImage(systemName: "rectangle.stack"), primaryAction: nil, menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in
                let reply = MenuReply(done)
                Task { @MainActor in reply.done(await self?.sessionsMenu() ?? []) }
            },
        ]))
        menu.accessibilityLabel = L("Terminals")
        menu.accessibilityIdentifier = "terminal.menu"
        navigationItem.rightBarButtonItem = menu

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let nav = navigationController {
            if navStyle == nil { navStyle = nav.overrideUserInterfaceStyle }
            nav.overrideUserInterfaceStyle = .dark
            nav.setNavigationBarHidden(false, animated: animated)
        }
        visible = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resume()
        if card.isHidden { _ = terminal.becomeFirstResponder() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        _ = terminal.resignFirstResponder()
        // back on the Screen page, which draws its own buttons
        if isMovingFromParent, let nav = navigationController {
            nav.setNavigationBarHidden(true, animated: animated)
            nav.overrideUserInterfaceStyle = navStyle ?? .unspecified
            navStyle = nil
        }
    }

    // MARK: Attaching

    /// Attaches when it isn't (and may: shown, not ended, not off).
    private func resume() {
        guard visible, task == nil else { return }
        switch state {
        case .idle, .reconnecting, .failed: attach()
        default: break
        }
    }

    private func attach() {
        task?.cancel()
        generation += 1
        let gen = generation
        let reconnecting = offset != nil
        state = reconnecting ? .reconnecting : .connecting
        task = Task { [weak self] in
            await self?.run(gen)
        }
    }

    private func run(_ gen: Int) async {
        let dims = terminal.getTerminal().getDims()
        do {
            let ch: any YoyoTerminalChannel
            do {
                ch = try await backend.openTerminal(session: sessionId, since: sessionId == nil ? nil : offset,
                                                    cols: dims.cols, rows: dims.rows, cwd: nil)
            } catch YoyoTerminalError.gone where sessionId != nil {
                // its shell exited while the page was away: a new one
                sessionId = nil
                offset = nil
                ch = try await backend.openTerminal(session: nil, since: nil, cols: dims.cols, rows: dims.rows, cwd: nil)
            }
            guard !Task.isCancelled, gen == generation else { ch.close(); return }
            channel = ch
            for await e in ch.events {
                handle(e, of: ch)
            }
        } catch YoyoTerminalError.off {
            state = .off
        } catch YoyoTerminalError.tooMany {
            state = .failed(L("This computer has as many terminals open as it takes. End one from the menu."))
        } catch {
            if case YoyoError.unauthorized? = error as? YoyoError, YoyoHost.current.handleError(error) { return }
            state = .failed(error.localizedDescription)
        }
        guard gen == generation else { return }
        task = nil
        if !Task.isCancelled, visible, state == .reconnecting || isFailed {
            // the network went (or isn't back yet): again soon, then less often
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, .seconds(5))
            try? await Task.sleep(for: delay)
            if visible, task == nil, state == .reconnecting || isFailed { attach() }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func handle(_ e: YoyoTerminalEvent, of ch: any YoyoTerminalChannel) {
        guard ch === channel else { return }
        switch e {
        case .attached(let session, let at, let reset):
            sessionId = session
            if reset || offset == nil {
                terminal.getTerminal().resetToInitialState()
                terminal.setNeedsDisplay()
            }
            offset = at
            retryDelay = .milliseconds(300)
            state = .live
            sendSize()
        case .output(let data):
            terminal.feed(byteArray: ArraySlice([UInt8](data)))
            offset = (offset ?? 0) + UInt64(data.count)
        case .exited(let code):
            ended(code == 0 ? L("The shell exited.") : L("The shell exited with code \(code)."))
        case .detached(let reason):
            channel = nil
            switch reason {
            case "replaced": state = .elsewhere
            case "off": state = .off
            default: ended(L("This terminal was ended on the computer."))
            }
        case .lost:
            channel = nil
            state = .reconnecting
        }
    }

    private func ended(_ text: String) {
        channel = nil
        sessionId = nil
        offset = nil
        state = .ended(text)
    }

    /// Detach from this one and show another (nil: a new one).
    private func switchTo(_ id: String?) {
        task?.cancel()
        task = nil
        generation += 1
        channel?.close()
        channel = nil
        sessionId = id
        offset = nil
        terminal.getTerminal().resetToInitialState()
        terminal.setNeedsDisplay()
        attach()
        _ = terminal.becomeFirstResponder()
    }

    private func sendSize() {
        let d = terminal.getTerminal().getDims()
        channel?.resize(cols: d.cols, rows: d.rows)
    }

    // MARK: What the page says

    private func stateChanged() {
        switch state {
        case .connecting: navigationItem.subtitle = L("Connecting…")
        case .reconnecting: navigationItem.subtitle = L("Reconnecting…")
        case .failed where offset != nil: navigationItem.subtitle = L("Reconnecting…")
        default: navigationItem.subtitle = nil
        }
        switch state {
        case .off:
            showCard(L("Terminals are off on this computer"),
                     L("Turn on Allow Terminals in Yoyo Control’s menu on the Mac."), button: L("Try Again")) { [weak self] in
                self?.attach()
            }
        case .ended(let text):
            showCard(text, nil, button: L("New Terminal")) { [weak self] in self?.switchTo(nil) }
        case .elsewhere:
            showCard(L("This terminal opened somewhere else"), nil, button: L("Continue Here")) { [weak self] in
                self?.attach()
            }
        case .failed(let text) where offset == nil:
            showCard(L("Can’t open a terminal"), text, button: L("Try Again")) { [weak self] in self?.attach() }
        default:
            card.isHidden = true
        }
    }

    private func showCard(_ title: String, _ detail: String?, button: String, action: @escaping () -> Void) {
        card.set(title: title, detail: detail, button: button, action: action)
        card.isHidden = false
        _ = terminal.resignFirstResponder()
    }

    // MARK: The menu

    private func sessionsMenu() async -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if let list = try? await backend.terminals(), !list.isEmpty {
            let current = sessionId
            let rows = list.map { t -> UIAction in
                let name = t.command ?? L("Terminal")
                let when = t.createdAt.formatted(date: .omitted, time: .shortened)
                let a = UIAction(title: name, subtitle: t.deviceName.map { "\($0) · \(when)" } ?? when,
                                 image: UIImage(systemName: "apple.terminal")) { [weak self] _ in
                    guard t.id != self?.sessionId else { return }
                    self?.switchTo(t.id)
                }
                if t.id == current { a.state = .on }
                return a
            }
            items.append(UIMenu(title: L("On the computer"), options: .displayInline, children: rows))
        }
        items.append(UIAction(title: L("New Terminal"), image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.switchTo(nil)
        })
        if let id = sessionId {
            items.append(UIAction(title: L("End This Terminal"), image: UIImage(systemName: "xmark.circle"),
                                  attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                Task { try? await self.backend.endTerminal(id: id) }
            })
        }
        return items
    }

    // MARK: Keys

    private func key(_ key: TerminalKeyBar.Key) {
        switch key {
        case .bytes(let b):
            typed(b)
        case .arrow(let c):
            let app = terminal.getTerminal().applicationCursor
            typed([0x1b] + Array((app ? "O" : "[").utf8) + Array(String(c).utf8))
        case .paste:
            guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
            paste(text)
        case .compose:
            let composer = TerminalComposer(draft: draft)
            composer.onSend = { [weak self] text, enter in
                guard let self else { return }
                self.draft = ""
                self.paste(text)
                if enter { self.channel?.send(Data([0x0d])) }
                _ = self.terminal.becomeFirstResponder()
            }
            let nav = UINavigationController(rootViewController: composer)
            nav.overrideUserInterfaceStyle = .dark
            if let sheet = nav.sheetPresentationController { sheet.detents = [.medium(), .large()] }
            present(nav, animated: true)
        case .hide:
            _ = terminal.resignFirstResponder()
        case .ctrl, .alt:
            break
        }
    }

    /// Bytes from the key row, with the armed modifiers.
    private func typed(_ bytes: [UInt8]) {
        var out = bytes
        if keyBar.alt.on { out = [0x1b] + out }
        keyBar.consumeModifiers()
        channel?.send(Data(out))
    }

    /// Text as one piece: a bracketed paste when the program asked for it.
    private func paste(_ text: String) {
        let t = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if terminal.getTerminal().bracketedPasteMode {
            channel?.send(Data("\u{1b}[200~".utf8) + Data(t.utf8) + Data("\u{1b}[201~".utf8))
        } else {
            channel?.send(Data(t.utf8))
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed || g.state == .ended else { return }
        let size = min(28, max(7, terminal.font.pointSize * g.scale))
        g.scale = 1
        guard abs(size - terminal.font.pointSize) >= 0.5 || g.state == .ended else { return }
        terminal.font = .monospacedSystemFont(ofSize: size.rounded(), weight: .regular)
        UserDefaults.standard.set(Double(size.rounded()), forKey: Self.fontKey)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        var bytes = Array(data)
        // the key row's ctrl / alt on what the keyboard typed
        if keyBar.ctrl.on, bytes.count == 1 {
            let b = bytes[0]
            switch b {
            case 0x61...0x7a: bytes = [b - 0x60]        // a–z
            case 0x40...0x5f: bytes = [b - 0x40]        // @, A–Z, [ \ ] ^ _
            case 0x20: bytes = [0x00]                  // space
            case 0x3f: bytes = [0x7f]                  // ?
            default: break
            }
        }
        if keyBar.alt.on { bytes = [0x1b] + bytes }
        if keyBar.ctrl.on || keyBar.alt.on { keyBar.consumeModifiers() }
        channel?.send(Data(bytes))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        channel?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        navigationItem.title = t.isEmpty ? title0 : t
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        UIApplication.shared.open(url)
    }

    func bell(source: TerminalView) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }
}

/// A deferred menu's completion, handed to the main actor's task.
private struct MenuReply: @unchecked Sendable {
    let done: ([UIMenuElement]) -> Void
    init(_ done: @escaping ([UIMenuElement]) -> Void) { self.done = done }
}

/// The card over the terminal when it can't go on (ended, off, elsewhere): what happened and the one thing to do.
@MainActor
final class TerminalCard: UIView {
    private let effect = UIVisualEffectView(effect: UIGlassEffect())
    private let title = UILabel()
    private let detail = UILabel()
    private let button = UIButton(configuration: .prominentGlass())
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.layer.cornerRadius = 24
        effect.clipsToBounds = true
        addSubview(effect)
        title.font = .preferredFont(forTextStyle: .headline)
        title.numberOfLines = 0
        title.textAlignment = .center
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center
        var c = UIButton.Configuration.prominentGlass()
        c.baseBackgroundColor = Theme.coral
        c.cornerStyle = .capsule
        button.configuration = c
        button.accessibilityIdentifier = "terminal.card.button"
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [title, detail, button])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: effect.contentView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: effect.contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: effect.contentView.bottomAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, detail d: String?, button b: String, action a: @escaping () -> Void) {
        title.text = t
        detail.text = d
        detail.isHidden = d == nil
        var c = button.configuration
        c?.title = b
        button.configuration = c
        action = a
    }
}
