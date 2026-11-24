import UIKit
import YoyoCore

/// The row over the keyboard (the terminal's `inputAccessoryView`): the keys a phone keyboard doesn't have, in the
/// order a shell and full-screen programs (vim, htop, coding agents) need them. Scrolls sideways when it doesn't fit.
///
/// - Ctrl and Alt are sticky: tapped, the next key typed on the keyboard goes with them (Ctrl-C, Alt-B…); tapped
///   twice, they stay on until tapped again. `TerminalPage` applies them (`modifiers`).
/// - The arrows repeat while held.
/// - ⌥⏎ is a new line without sending (ESC CR: Option-Return; coding agents read it as a line break).
/// - Paste sends the iPhone's clipboard (bracketed when the program asks for it); the pencil opens the composer (a
///   whole command or message in a native text field: dictation, the Chinese keyboard, autocorrect off).
@MainActor
final class TerminalKeyBar: UIInputView {
    enum Key: Sendable {
        case bytes([UInt8])
        /// Arrows: their sequences depend on the terminal's cursor key mode.
        case arrow(Character)
        case ctrl, alt, paste, compose, hide
    }

    /// What the bar does.
    var onKey: ((Key) -> Void)?

    /// Ctrl / Alt armed for the next key (`locked`: until tapped again).
    struct Modifier {
        var on = false
        var locked = false
    }
    private(set) var ctrl = Modifier() { didSet { update() } }
    private(set) var alt = Modifier() { didSet { update() } }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var ctrlButton: UIButton!
    private var altButton: UIButton!
    private var repeatTimer: Timer?
    private var lastTap: (key: String, at: Date)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 36),
        ])

        add(text: "esc", label: L("Escape"), .bytes([0x1b]))
        ctrlButton = add(text: "ctrl", label: L("Control"), .ctrl)
        altButton = add(text: "alt", label: L("Option"), .alt)
        add(symbol: "arrow.right.to.line", label: L("Tab"), .bytes([0x09]))
        add(symbol: "arrow.left.to.line", label: L("Shift-Tab"), .bytes([0x1b, 0x5b, 0x5a]))
        add(text: "^C", label: L("Interrupt (Control-C)"), .bytes([0x03]))
        add(symbol: "arrow.left", label: L("Left"), .arrow("D"), repeats: true)
        add(symbol: "arrow.up", label: L("Up"), .arrow("A"), repeats: true)
        add(symbol: "arrow.down", label: L("Down"), .arrow("B"), repeats: true)
        add(symbol: "arrow.right", label: L("Right"), .arrow("C"), repeats: true)
        add(symbol: "return", label: L("New line without sending (Option-Return)"), .bytes([0x1b, 0x0d]))
        for c in ["|", "~", "/", "-", "_", "*", "&", "$"] {
            add(text: c, label: c, .bytes(Array(c.utf8)), monospaced: true)
        }
        add(symbol: "doc.on.clipboard", label: L("Paste"), .paste)
        add(symbol: "square.and.pencil", label: L("Compose"), .compose)
        add(symbol: "keyboard.chevron.compact.down", label: L("Hide Keyboard"), .hide)
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A modifier used by a key: it goes off unless locked.
    func consumeModifiers() {
        if ctrl.on, !ctrl.locked { ctrl = Modifier() }
        if alt.on, !alt.locked { alt = Modifier() }
    }

    @discardableResult
    private func add(text: String? = nil, symbol: String? = nil, label: String, _ key: Key, repeats: Bool = false,
                     monospaced: Bool = false) -> UIButton {
        var c = UIButton.Configuration.glass()
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        if let symbol {
            c.image = UIImage(systemName: symbol)
            c.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        }
        if let text {
            c.title = text
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = monospaced ? .monospacedSystemFont(ofSize: 16, weight: .medium) : .systemFont(ofSize: 15, weight: .semibold)
                return a
            }
        }
        c.baseForegroundColor = .label
        let b = UIButton(configuration: c)
        b.accessibilityLabel = label
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        if repeats {
            b.addAction(UIAction { [weak self] _ in self?.startRepeat(key) }, for: .touchDown)
            for e: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
                b.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: e)
            }
        } else {
            b.addAction(UIAction { [weak self] _ in self?.tapped(key, name: text ?? symbol ?? "") }, for: .primaryActionTriggered)
        }
        stack.addArrangedSubview(b)
        return b
    }

    private func tapped(_ key: Key, name: String) {
        UIDevice.current.playInputClick()
        let double = lastTap.map { $0.key == name && Date().timeIntervalSince($0.at) < 0.35 } ?? false
        lastTap = (name, Date())
        switch key {
        case .ctrl:
            ctrl = double ? Modifier(on: true, locked: true) : ctrl.on ? Modifier() : Modifier(on: true)
        case .alt:
            alt = double ? Modifier(on: true, locked: true) : alt.on ? Modifier() : Modifier(on: true)
        default:
            onKey?(key)
        }
    }

    private func startRepeat(_ key: Key) {
        UIDevice.current.playInputClick()
        onKey?(key)
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onKey?(key) }
                }
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func update() {
        for (button, m) in [(ctrlButton, ctrl), (altButton, alt)] {
            guard let button, let old = button.configuration else { continue }
            var c: UIButton.Configuration = m.on ? .prominentGlass() : .glass()
            c.cornerStyle = old.cornerStyle
            c.contentInsets = old.contentInsets
            c.title = old.title
            c.titleTextAttributesTransformer = old.titleTextAttributesTransformer
            // on for one key: coral; locked on: a deeper coral
            c.baseBackgroundColor = m.locked ? Theme.coral.withAlphaComponent(1) : Theme.coral.withAlphaComponent(0.8)
            c.baseForegroundColor = m.on ? .white : .label
            button.configuration = c
            button.accessibilityTraits = m.on ? [.button, .selected] : .button
        }
    }
}

extension TerminalKeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
