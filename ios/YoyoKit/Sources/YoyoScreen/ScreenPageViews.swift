import UIKit
import YoyoClipboard
import YoyoCore

/// "Agent is using the screen" / "You have control" / "View only", as a small glass capsule over the picture.
final class ScreenBadgeView: UIView {
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let icon = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        icon.contentMode = .scaleAspectFit
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -7),
        ])
        isAccessibilityElement = true
        accessibilityIdentifier = "screen.badge"
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ controller: ScreenController) {
        let (symbol, text, tint): (String, String, UIColor) = switch controller {
        case .agent: ("sparkle", L("Agent is using the screen"), Theme.coral)
        case .user: ("hand.tap", L("You have control"), Theme.success)
        case .none: ("eye", L("View only"), Theme.secondaryText)
        }
        icon.image = UIImage(systemName: symbol)
        icon.tintColor = tint
        label.text = text
        label.textColor = controller == .none ? Theme.secondaryText : Theme.text
        accessibilityLabel = text
    }
}

/// Over the dimmed still while the picture is on its way back (a spinner, "Reconnecting…", why), or when the display
/// can't be shown (why, and Retry).
final class ScreenConnectionOverlay: UIView {
    var onRetry: (() -> Void)?
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let title = UILabel()
    private let detail = UILabel()
    private var retry: UIButton!

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.cornerConfiguration = .uniformCorners(radius: 22)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        spinner.hidesWhenStopped = true
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Theme.text
        title.textAlignment = .center
        title.numberOfLines = 0
        title.accessibilityIdentifier = "screen.connection.title"
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = Theme.secondaryText
        detail.textAlignment = .center
        detail.numberOfLines = 0
        detail.accessibilityIdentifier = "screen.connection.detail"
        var c = UIButton.Configuration.prominentGlass()
        c.title = L("Retry")
        c.buttonSize = .small
        let retry = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.onRetry?() })
        retry.accessibilityIdentifier = "screen.connection.retry"
        self.retry = retry
        let stack = UIStackView(arrangedSubviews: [spinner, title, detail, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(14, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -16),
        ])
        accessibilityIdentifier = "screen.connection"
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ phase: ScreenConnectionModel.Phase, host: YoyoComputer = .mac) {
        title.text = ScreenConnectionText.title(phase, host: host)
        let why = ScreenConnectionText.detail(phase, host: host)
        detail.text = why
        detail.isHidden = why == nil
        let unavailable = phase.isUnavailable
        if unavailable { spinner.stopAnimating() } else { spinner.startAnimating() }
        retry.isHidden = !unavailable
    }
}

/// A glass note over the picture's bottom edge with a button (the missing Accessibility permission).
final class ScreenNoteView: UIView {
    var onRequest: (() -> Void)?
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let label = UILabel()

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.cornerConfiguration = .uniformCorners(radius: 20)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.secondaryText
        label.numberOfLines = 0
        var c = UIButton.Configuration.prominentGlass()
        c.title = L("Request permissions")
        c.buttonSize = .small
        let button = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.onRequest?() })
        button.accessibilityIdentifier = "screen.requestPermissions"
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -12),
        ])
        accessibilityIdentifier = "screen.accessNote"
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The Screen page's navigation controller: the page decides about the system's edge swipes, the Home indicator and
/// the status bar (it is a trackpad edge to edge).
final class ScreenNavigationController: UINavigationController {
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { topViewController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
    override var childForStatusBarHidden: UIViewController? { topViewController }
    override var childForStatusBarStyle: UIViewController? { topViewController }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        topViewController?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
    }
}

/// A round Liquid Glass button of the Screen page (a capsule with its title, when it shows one). `isOn` = a toggle that
/// is on: prominent, tinted.
final class ScreenGlassButton: UIButton {
    var symbol: String { didSet { if symbol != oldValue { update() } } }
    /// The title, shown when `showsTitle`.
    var title: String? { didSet { update() } }
    var showsTitle = true { didSet { if showsTitle != oldValue { update() } } }
    var isOn = false { didSet { if isOn != oldValue { update() } } }
    /// A small clay dot at the top right: something new behind the button (the clipboard's).
    var showsDot = false {
        didSet {
            guard showsDot != oldValue else { return }
            dot.isHidden = !showsDot
            accessibilityValue = showsDot ? L("New") : nil
        }
    }
    private let dot = UIView()

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        dot.backgroundColor = Theme.coral
        dot.layer.cornerRadius = 4.5
        dot.layer.borderWidth = 1.5
        dot.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        dot.isUserInteractionEnabled = false
        dot.isHidden = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 9), dot.heightAnchor.constraint(equalToConstant: 9),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 3), dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
        heightAnchor.constraint(equalToConstant: 44).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        var c: UIButton.Configuration = isOn ? .prominentGlass() : .glass()
        c.image = UIImage(systemName: symbol)
        c.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body)
        c.cornerStyle = .capsule
        let text = showsTitle ? title : nil
        c.title = text
        c.imagePadding = 6
        c.contentInsets = text == nil ? NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            : NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 16)
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
            return a
        }
        if isOn { c.baseBackgroundColor = Theme.coral; c.baseForegroundColor = .white }
        configuration = c
        accessibilityTraits = isOn ? [.button, .selected] : .button
        bringSubviewToFront(dot)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bringSubviewToFront(dot)
    }
}

/// A hint over the picture, glass like the controller badge but tappable ("iPhone clipboard: text — Paste on Mac"):
/// slides in from the top (fades with Reduce Motion), goes after a while or when told. One at a time: `show` replaces
/// what it says.
final class ScreenHintPill: UIControl {
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let icon = UIImageView()
    private let label = UILabel()
    private var hideTask: Task<Void, Never>?
    /// Tapped (the page does what the hint says, then hides it).
    var onTap: (() -> Void)?
    private(set) var shown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.cornerConfiguration = .capsule()
        glass.isUserInteractionEnabled = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        icon.tintColor = Theme.coral
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.text
        label.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 6
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -9),
        ])
        // as narrow as its words (the page only caps the width)
        let hug = widthAnchor.constraint(equalToConstant: 0)
        hug.priority = .fittingSizeLevel
        hug.isActive = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "screen.hint"
        alpha = 0
        isHidden = true
        addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { UIView.animate(withDuration: 0.12) { self.glass.alpha = self.isHighlighted ? 0.7 : 1 } }
    }

    /// Says `text` (with `symbol`) for `duration`, replacing whatever it said.
    func show(_ text: String, symbol: String, for duration: Duration) {
        label.text = text
        icon.image = UIImage(systemName: symbol)
        accessibilityLabel = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
        guard !shown else { return }
        shown = true
        isHidden = false
        let reduce = UIAccessibility.isReduceMotionEnabled
        transform = reduce ? .identity : CGAffineTransform(translationX: 0, y: -14)
        UIView.animate(springDuration: reduce ? 0.25 : 0.4, bounce: reduce ? 0 : 0.2) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard shown else { return }
        shown = false
        let reduce = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: 0.2, animations: {
            self.alpha = 0
            if !reduce { self.transform = CGAffineTransform(translationX: 0, y: -10) }
        }, completion: { _ in
            if !self.shown { self.isHidden = true; self.transform = .identity }
        })
    }
}
