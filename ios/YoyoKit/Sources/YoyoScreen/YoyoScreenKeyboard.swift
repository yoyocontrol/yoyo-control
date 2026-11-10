import UIKit
import YoyoClipboard
import YoyoCore

/// The system keyboard for typing on a session's computer (`YoyoScreenSession`), any input method (what it composes
/// stays here; committed text goes), with a bar above it: sticky ⌘ ⇧ ⌥ ⌃ (lit while armed: they apply to the next key
/// or click), the keys a phone keyboard lacks (Esc, Tab, arrows), the clipboard's moves (Paste on Mac — a long press
/// offers Photos… / Files… —, Copy from Mac: while the computer has a clipboard), and a button that puts it away.
///
/// A small invisible view: add it to the view hierarchy where it should belong (its first responder is its own hidden
/// text view; the keyboard covers whatever is under it). `show()` brings it up (an input: under `.takeOnInput` it
/// takes the screen first), and it comes up by itself when a click focuses something that takes typing
/// (`showsForFocus`). It goes when the session stops controlling the screen or stops.
@MainActor
public final class YoyoScreenKeyboard: UIView {
    public let session: YoyoScreenSession
    /// It may come up (false: never, e.g. a landscape layout without room for it; it goes now).
    public var isEnabled = true { didSet { if !isEnabled { hide() } } }
    /// It comes up by itself when a click focuses something that takes typing.
    public var showsForFocus = true
    /// It came up (true) / went (false).
    public var onShownChange: ((Bool) -> Void)?

    let keyInput = ScreenKeyInputView()
    let keyBar = ScreenKeyBar()
    private var observation: YoyoScreenObservation?

    public init(session: YoyoScreenSession) {
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        isAccessibilityElement = false
        keyInput.frame = bounds
        keyInput.isAccessibilityElement = false
        keyInput.accessoryBar = keyBar
        keyInput.onFocusChange = { [weak self] shown in self?.onShownChange?(shown) }
        addSubview(keyInput)
        keyInput.onText = { [weak session] text in session?.type(text) }
        keyInput.onDelete = { [weak session] in session?.pressKey("delete") }
        keyBar.onModifier = { [weak session] m in session?.toggleModifier(m) }
        keyBar.onKey = { [weak session] name in session?.pressKey(name) }
        keyBar.onDismiss = { [weak self] in self?.hide() }
        keyBar.onClipboard = { [weak session] k in session?.clipboardKey(k) }
        keyBar.onClipboardPick = { [weak session] source in session?.pickForComputer(source) }
        keyBar.setSendsFiles(session.backend.sendsClipboardFiles)
        session.keyboard = self
        observation = session.observe { [weak self] update in
            guard let self, case let .changed(c) = update else { return }
            self.sessionChanged(c)
        }
        sessionChanged([.computer, .clipboard, .modifiers])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func sessionChanged(_ c: YoyoScreenSession.Changes) {
        if c.contains(.computer) { keyBar.host = session.computer }
        if c.contains(.clipboard) { keyBar.setClipboardShown(session.hasClipboard) }
        if c.contains(.modifiers) { keyBar.setActive(session.modifiers) }
        if !session.isControlling || !session.isActive { hide() }
    }

    /// It shows now.
    public var isShown: Bool { keyInput.isFirstResponder }

    /// Brings it up: an input (watching, as `YoyoScreenSession.requestInput` says: `.takeOnInput` takes the screen
    /// first).
    public func show() {
        guard isEnabled else { return }
        session.requestInput { [weak self] in
            guard let self, self.isEnabled, self.hostController?.presentedViewController == nil else { return }
            self.keyInput.becomeFirstResponder()
        }
    }

    /// Puts it away.
    public func hide() {
        if keyInput.isFirstResponder { keyInput.resignFirstResponder() }
    }

    /// Up, or away when it is up.
    public func toggle() {
        if isShown { hide() } else { show() }
    }

    /// It would come up for an editable focus (the session looks at the focus after a click only then).
    var wantsFocusLook: Bool { isEnabled && showsForFocus && !isShown && window != nil }

    /// A click focused something that takes typing.
    func showForFocus() {
        guard session.isActive, session.isControlling, wantsFocusLook, hostController?.presentedViewController == nil else { return }
        keyInput.becomeFirstResponder()
    }
}
