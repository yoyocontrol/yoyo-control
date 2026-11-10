import UIKit
import YoyoClipboard
import YoyoCore

/// What the fingers do on the Screen page's trackpad (`ScreenGestureRow.rows`): two columns, gesture and what it does on
/// the Mac; then the clipboard's two verbs (`ScreenGestureRow.clipboardRows`) and where photos and files go from; and
/// «Got it». A sheet sized to its content (scrolling when it is taller than the screen); opens by itself the first time
/// the page takes control, and from the «?» button any time. Without the clipboard (an older server, a desktop whose
/// helper has none) the clipboard part is left out; on a user's desktop its verbs name "the computer".
final class ScreenGestureCardController: UIViewController {
    private let stack = UIStackView()
    private let scroll = UIScrollView()
    private let showsClipboard: Bool
    private let host: YoyoComputer

    init(showsClipboard: Bool = true, host: YoyoComputer = .mac) {
        self.showsClipboard = showsClipboard
        self.host = host
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.groupedBackground
        view.accessibilityIdentifier = "screen.gestureCard"

        let title = UILabel()
        title.text = L("Trackpad gestures")
        title.font = .preferredFont(forTextStyle: .title3).withTraits(.traitBold)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Theme.text
        title.accessibilityTraits = .header
        let subtitle = UILabel()
        subtitle.text = L("The panel under the picture is a trackpad: the pointer moves with your finger, taps click where it is. While you move it, a loupe magnifies around the pointer. Pinch the picture to zoom in, double-tap it to fit.")
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = Theme.secondaryText
        subtitle.numberOfLines = 0

        let header = row(symbol: nil, gesture: L("Gesture"), action: L("Action"), header: true)
        let rows = ScreenGestureRow.rows.map { row(symbol: $0.symbol, gesture: $0.gesture, action: $0.action, header: false) }
        let table = UIStackView(arrangedSubviews: [header] + rows)
        table.axis = .vertical
        table.spacing = 10

        let clipboardTitle = UILabel()
        clipboardTitle.text = L("Clipboard")
        clipboardTitle.font = .preferredFont(forTextStyle: .headline)
        clipboardTitle.adjustsFontForContentSizeCategory = true
        clipboardTitle.textColor = Theme.text
        clipboardTitle.accessibilityTraits = .header
        let clipboardRows = ScreenGestureRow.clipboardRows(host).map { row(symbol: $0.symbol, gesture: $0.gesture, action: $0.action, header: false) }
        let send = UILabel()
        send.text = L("Send photos and files from the clipboard button or the Share sheet.")
        send.font = .preferredFont(forTextStyle: .footnote)
        send.adjustsFontForContentSizeCategory = true
        send.textColor = Theme.secondaryText
        send.numberOfLines = 0
        let clipboard = UIStackView(arrangedSubviews: [clipboardTitle] + clipboardRows + [send])
        clipboard.axis = .vertical
        clipboard.spacing = 10
        clipboard.accessibilityIdentifier = "screen.gestureCard.clipboard"

        var c = UIButton.Configuration.prominentGlass()
        c.title = L("Got it")
        c.buttonSize = .large
        let done = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        done.accessibilityIdentifier = "screen.gestureCard.done"

        stack.axis = .vertical
        stack.spacing = 18
        stack.setCustomSpacing(6, after: title)
        for v in [title, subtitle, table] + (showsClipboard ? [clipboard] : []) + [done] as [UIView] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(24, after: table)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
        ])
        if let sheet = sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.detents = [.custom(identifier: .init("content")) { [weak self] context in
                guard let self else { return context.maximumDetentValue }
                return min(self.fittingHeight(), context.maximumDetentValue)
            }, .large()]
        }
    }

    /// The card's height for the sheet's detent: the content and some room under it.
    private func fittingHeight() -> CGFloat {
        let width = max(view.bounds.width, 320) - view.layoutMargins.left - view.layoutMargins.right - 16
        let size = stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        return size.height + 28 + 24
    }

    private func row(symbol: String?, gesture: String, action: String, header: Bool) -> UIView {
        let icon = UIImageView(image: symbol.flatMap { UIImage(systemName: $0) })
        icon.tintColor = Theme.coral
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.isAccessibilityElement = false
        let g = UILabel()
        g.text = gesture
        g.numberOfLines = 0
        g.adjustsFontForContentSizeCategory = true
        let a = UILabel()
        a.text = action
        a.numberOfLines = 0
        a.adjustsFontForContentSizeCategory = true
        if header {
            g.font = .preferredFont(forTextStyle: .footnote)
            a.font = .preferredFont(forTextStyle: .footnote)
            g.textColor = Theme.secondaryText
            a.textColor = Theme.secondaryText
        } else {
            g.font = .preferredFont(forTextStyle: .body)
            a.font = .preferredFont(forTextStyle: .body)
            g.textColor = Theme.text
            a.textColor = Theme.secondaryText
        }
        let line = UIStackView(arrangedSubviews: [icon, g, a])
        line.spacing = 10
        line.alignment = .firstBaseline
        // two columns: the gesture takes the larger part
        g.widthAnchor.constraint(equalTo: a.widthAnchor, multiplier: 1.25).isActive = true
        line.isAccessibilityElement = !header
        line.accessibilityLabel = "\(gesture): \(action)"
        if header { line.isAccessibilityElement = false; g.isAccessibilityElement = false; a.isAccessibilityElement = false }
        return line
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: d, size: 0)
    }
}
