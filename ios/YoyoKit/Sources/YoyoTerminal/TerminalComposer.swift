import UIKit
import YoyoCore

/// A whole command or message written in a native text field, then sent to the terminal at once: what a phone
/// keyboard does well (dictation, the Chinese keyboard's candidates, editing the text before it goes) and a terminal's
/// key-by-key input doesn't. "Send" types it and Return; "Insert" types it only. More than one line goes as a
/// bracketed paste when the program asked for it (shells and coding agents then take it as one piece).
@MainActor
final class TerminalComposer: UIViewController, UITextViewDelegate {
    private let text = UITextView()
    /// The text and whether Return follows.
    var onSend: ((String, Bool) -> Void)?
    private var draft: String

    init(draft: String) {
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Compose")
        view.backgroundColor = .systemBackground
        text.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        text.autocorrectionType = .no
        text.autocapitalizationType = .none
        text.smartQuotesType = .no
        text.smartDashesType = .no
        text.spellCheckingType = .no
        text.text = draft
        text.delegate = self
        text.backgroundColor = .clear
        text.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.accessibilityIdentifier = "terminal.compose.text"
        view.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            text.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            text.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        let send = UIBarButtonItem(title: L("Send"), image: nil, primaryAction: UIAction { [weak self] _ in self?.finish(enter: true) }, menu: nil)
        send.style = .prominent
        send.accessibilityIdentifier = "terminal.compose.send"
        let insert = UIBarButtonItem(title: L("Insert"), image: nil, primaryAction: UIAction { [weak self] _ in self?.finish(enter: false) }, menu: nil)
        navigationItem.rightBarButtonItems = [send, insert]
        updateButtons()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        text.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) { updateButtons() }

    private func updateButtons() {
        let empty = text.text.isEmpty
        navigationItem.rightBarButtonItems?.last?.isEnabled = !empty
    }

    private func finish(enter: Bool) {
        let t = text.text ?? ""
        dismiss(animated: true) { [onSend] in onSend?(t, enter) }
    }
}
