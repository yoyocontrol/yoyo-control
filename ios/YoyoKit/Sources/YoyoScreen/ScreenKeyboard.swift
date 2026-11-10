import UIKit
import YoyoClipboard
import YoyoCore

/// An invisible text view that brings up the system keyboard for typing on the Mac. Any keyboard works, Chinese pinyin
/// and other input methods included: what they compose stays here (the candidates show in the keyboard) and only
/// committed text is passed on, then the view empties again. Backspace with nothing here (and nothing being composed)
/// is passed on as a delete; return comes as "\n". No autocorrection, capitalization or smart punctuation, which would
/// type things the user didn't.
final class ScreenKeyInputView: UITextView, UITextViewDelegate {
    var onText: ((String) -> Void)?
    var onDelete: (() -> Void)?
    /// It became first responder (the keyboard came up: true) / resigned (false).
    var onFocusChange: ((Bool) -> Void)?
    var accessoryBar: UIView?

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        keyboardType = .default
        returnKeyType = .default
        // nothing of it shows: no text, no caret, no background
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        isEditable = true
        isSelectable = true
    }
    required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let was = isFirstResponder
        let resigned = super.resignFirstResponder()
        if was, resigned { onFocusChange?(false) }
        return resigned
    }

    override var inputAccessoryView: UIView? {
        get { accessoryBar }
        set { accessoryBar = newValue }
    }
    /// No three-finger undo / copy gestures: there's nothing to undo here, and three fingers toggle the stats line.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func deleteBackward() {
        // composing (or something not yet passed on): the input method edits it
        if markedTextRange != nil || !text.isEmpty { super.deleteBackward(); return }
        onDelete?()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard markedTextRange == nil, let typed = text, !typed.isEmpty else { return }
        text = ""
        onText?(typed)
    }
}

/// The remote-desktop clipboard moves of the key bar and the clipboard menu (PROTOCOL.md「剪贴板」). Two verbs
/// everywhere: Paste on Mac (what the iPhone has → the Mac) and Copy from Mac (the Mac → the iPhone); on a user's
/// Linux desktop, Paste on Computer and Copy from Computer.
enum ScreenClipboardKey: String, Sendable, Equatable, CaseIterable {
    /// The phone's clipboard onto the Mac's, then ⌘V.
    case pasteOnMac
    /// The Mac's clipboard onto the phone's.
    case copyFromMac

    var symbol: String {
        switch self {
        case .pasteOnMac: "arrow.right.doc.on.clipboard"  // (there is no arrow.down… variant)
        case .copyFromMac: "arrow.up.doc.on.clipboard"
        }
    }

    func label(_ host: YoyoComputer) -> String {
        switch self {
        case .pasteOnMac: host.pasteLabel
        case .copyFromMac: host.copyLabel
        }
    }
}

/// The bar above the keyboard: sticky modifiers (⌘ ⇧ ⌥ ⌃, lit while armed; they apply to the next key or click),
/// the keys a phone keyboard lacks (Esc, Tab, arrows), the clipboard moves (Paste on Mac — a long press offers Photos… /
/// Files… —, Copy from Mac; with their names, hidden on a server without the clipboard), then a button that hides the
/// keyboard.
final class ScreenKeyBar: UIInputView {
    var onModifier: ((ScreenModifier) -> Void)?
    /// A key name of `POST /screen/input` ("escape", "tab", "left"…).
    var onKey: ((String) -> Void)?
    var onClipboard: ((ScreenClipboardKey) -> Void)?
    /// Paste on Mac's long press: Photos… / Files….
    var onClipboardPick: ((ClipboardPicker.Source) -> Void)?
    var onDismiss: (() -> Void)?
    /// Whose computer the clipboard keys name ("Paste on Mac" / "Paste on Computer").
    var host: YoyoComputer = .mac {
        didSet { if host != oldValue { relabelClipboard() } }
    }

    private var modifierButtons: [ScreenModifier: UIButton] = [:]
    private var clipboardButtons: [UIButton] = []
    private var clipboardKeys: [ScreenClipboardKey] = []
    private let scroll = UIScrollView()
    private let stack = UIStackView()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 38),
        ])

        let modifiers: [(ScreenModifier, String, String)] = [
            (.cmd, "⌘", L("Command key")), (.shift, "⇧", L("Shift key")), (.alt, "⌥", L("Option key")), (.ctrl, "⌃", L("Control key")),
        ]
        for (m, glyph, name) in modifiers {
            let b = key(glyph, name: name, id: "screen.mod.\(m.rawValue)") { [weak self] in self?.onModifier?(m) }
            modifierButtons[m] = b
            stack.addArrangedSubview(b)
        }
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        let keys: [(String, String, String)] = [
            ("esc", "escape", L("Escape")), ("tab", "tab", L("Tab")),
            ("←", "left", L("Left arrow")), ("↑", "up", L("Up arrow")), ("↓", "down", L("Down arrow")), ("→", "right", L("Right arrow")),
        ]
        for (glyph, name, label) in keys {
            stack.addArrangedSubview(key(glyph, name: label, id: "screen.key.\(name)") { [weak self] in self?.onKey?(name) })
        }
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        for k in ScreenClipboardKey.allCases {
            var c = Self.style(selected: false)
            c.image = UIImage(systemName: k.symbol)
            c.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            c.imagePadding = 5
            c.attributedTitle = Self.clipboardTitle(k.label(host))
            let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in
                UIDevice.current.playInputClick()
                self?.onClipboard?(k)
            })
            b.accessibilityIdentifier = "screen.clipboard.\(k.rawValue)"
            if k == .pasteOnMac {
                // a long press: photos or files instead of what the phone has copied
                b.menu = UIMenu(children: [
                    UIAction(title: L("Photos…"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.onClipboardPick?(.photos) },
                    UIAction(title: L("Files…"), image: UIImage(systemName: "folder")) { [weak self] _ in self?.onClipboardPick?(.files) },
                ])
                b.showsMenuAsPrimaryAction = false
                b.accessibilityHint = L("Touch and hold to send photos or files instead.")
            }
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            if k == .pasteOnMac { pasteButton = b }
            clipboardButtons.append(b)
            clipboardKeys.append(k)
            stack.addArrangedSubview(b)
        }
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        let hide = UIButton(configuration: Self.style(selected: false), primaryAction: UIAction { [weak self] _ in self?.onDismiss?() })
        hide.configuration?.image = UIImage(systemName: "keyboard.chevron.compact.down")
        hide.accessibilityLabel = L("Hide keyboard")
        hide.accessibilityIdentifier = "screen.key.hide"
        hide.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        stack.addArrangedSubview(hide)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func style(selected: Bool) -> UIButton.Configuration {
        var c = UIButton.Configuration.filled()
        c.cornerStyle = .medium
        c.baseBackgroundColor = selected ? Theme.coral : Theme.sheetControl
        c.baseForegroundColor = selected ? .white : Theme.text
        c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        return c
    }

    private func key(_ glyph: String, name: String, id: String, action: @escaping () -> Void) -> UIButton {
        var c = Self.style(selected: false)
        var title = AttributedString(glyph)
        title.font = UIFont.systemFont(ofSize: glyph.count > 1 ? 15 : 18, weight: .medium)
        c.attributedTitle = title
        let b = UIButton(configuration: c, primaryAction: UIAction { _ in
            UIDevice.current.playInputClick()
            action()
        })
        b.accessibilityLabel = name
        b.accessibilityIdentifier = id
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return b
    }

    private weak var pasteButton: UIButton?
    private var pickMenu: UIMenu?

    /// Paste's long press offers Photos… / Files… only when the backend sends files (`YoyoBackend.sendsClipboardFiles`).
    func setSendsFiles(_ on: Bool) {
        guard let b = pasteButton else { return }
        if pickMenu == nil { pickMenu = b.menu }
        b.menu = on ? pickMenu : nil
        b.accessibilityHint = on ? L("Touch and hold to send photos or files instead.") : nil
    }

    /// The clipboard keys show only on a server with the clipboard feature.
    func setClipboardShown(_ shown: Bool) {
        for b in clipboardButtons { b.isHidden = !shown }
    }

    private static func clipboardTitle(_ text: String) -> AttributedString {
        var title = AttributedString(text)
        title.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        return title
    }

    private func relabelClipboard() {
        for (b, k) in zip(clipboardButtons, clipboardKeys) { b.configuration?.attributedTitle = Self.clipboardTitle(k.label(host)) }
    }

    /// Lights the armed modifiers.
    func setActive(_ active: Set<ScreenModifier>) {
        for (m, b) in modifierButtons {
            let on = active.contains(m)
            let title = b.configuration?.attributedTitle
            var c = Self.style(selected: on)
            c.attributedTitle = title
            b.configuration = c
            b.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }
}

extension ScreenKeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
