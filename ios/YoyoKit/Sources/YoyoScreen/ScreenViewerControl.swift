import UIKit
import YoyoClipboard
import YoyoCore

// Several phones watching the same computer's screen (docs/REMOTE.md「控制权」): one controls, the others watch. The
// backend tells the computer which phone sends a request (its token, or `ScreenControlDevice.current`), and the status
// / `screen.control` say who holds it (`controllerDevice`). A phone that isn't the holder is a viewer: its touches send nothing, and a glass pill says who
// controls with a one-tap Take Over. A holder the Mac names no device for: whoever is "user" controls.

/// Who holds the screen as this phone sees it (`YoyoScreenSession.controlModel`), and what changes of it are said
/// out loud. Pure.
public struct ScreenControlModel: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        /// Nobody.
        case free
        case agent
        /// This phone (or a holder that says no device: an older server or client, as before).
        case me
        /// Another phone: this one watches (`name`: the holder's, when said).
        case other(name: String?)
    }

    enum Effect: Equatable, Sendable {
        /// Another phone took control from this one.
        case takenOver(name: String?)
    }

    public private(set) var role = Role.free
    /// `controllerSince` of this phone's last take (a status from before it that says another phone holds is stale).
    private var tookSince: Double?

    /// Another phone holds control: this one watches (only an explicit take takes it).
    public var isViewer: Bool { if case .other = role { true } else { false } }

    static func role(controller: ScreenController, device: ScreenControlDevice?, me: String?) -> Role {
        switch controller {
        case .none: .free
        case .agent: .agent
        case .user:
            if let device, let me, device.id != me { .other(name: device.name) } else { .me }
        }
    }

    /// A status (`GET /status`, a control answer): who holds it now. `me`: this phone's id (nil: it sends none).
    mutating func status(controller: ScreenController, device: ScreenControlDevice?, since: Double?, me: String?) -> Effect? {
        let new = Self.role(controller: controller, device: device, me: me)
        // a poll that left before this phone took control
        if case .other = new, let since, let tookSince, since < tookSince { return nil }
        return move(to: new)
    }

    /// This phone took control (the control request's answer).
    mutating func took(controller: ScreenController, device: ScreenControlDevice?, since: Double?, me: String?) -> Effect? {
        if controller == .user { tookSince = since }
        return status(controller: controller, device: device, since: since, me: me)
    }


    /// An input was refused: another phone holds control.
    mutating func refused(_ refusal: ScreenControlledElsewhere) -> Effect? {
        move(to: .other(name: refusal.controllerDevice.name))
    }

    private mutating func move(to new: Role) -> Effect? {
        defer { role = new }
        guard role == .me, case let .other(name) = new else { return nil }
        return .takenOver(name: name)
    }

    /// The holder's name to show: its own ("Mia's iPhone"), else "Another iPhone" / "Another iPad" for the generic
    /// name iOS gives apps without the user-assigned-name entitlement, else "Another device" when not said.
    public static func displayName(_ name: String?) -> String {
        switch name?.trimmingCharacters(in: .whitespaces) {
        case nil, "": L("Another device")
        case "iPhone": L("Another iPhone")
        case "iPad": L("Another iPad")
        case let name?: name
        }
    }
}

/// When the Screen page takes the screen: it opens as a viewer and takes control only at a real input (the first touch
/// on the trackpad, the keyboard button, a key or typed text, a paste into the computer). Opening, coming back, a
/// status or `screen.control` event, zooming or panning the picture, full screen and turning the phone are not input and
/// never ask. At an input the user wins over automation (an agent's control is taken); another phone's control is only
/// taken with the pill's button. Whenever input is possible but this page doesn't control, the pill says who holds it
/// with an explicit button ("Take Control" when nobody does, "Take Over" from the agent or another phone; in full
/// screen too, where it leaves full screen into control). Pure.
enum ScreenControlPolicy {
    enum Answer: Equatable {
        /// In control: the input goes now.
        case go
        /// Take the screen (`POST /control { controller: "user" }`), then the input goes.
        case take
        /// Watching another phone's control: the Take Over pill is nudged, nothing goes.
        case nudge
        /// Nothing can take it (full screen, no Accessibility).
        case ignore
    }

    /// A real input: `controlling` (taps and keys go), `viewer` (another phone holds control), `canTake` (input is
    /// possible here: Accessibility granted, not full screen, not a viewer).
    static func input(controlling: Bool, viewer: Bool, canTake: Bool) -> Answer {
        if controlling { return .go }
        if viewer { return .nudge }
        return canTake ? .take : .ignore
    }

    /// What the pill says (with its button) while this page doesn't control.
    enum Pill: Equatable {
        /// Nobody holds it: "View only · Take Control".
        case free
        /// The agent: "Agent is using the screen · Take Over".
        case agent
        /// Another phone: "<name> is controlling · Take Over".
        case other(name: String?)
    }

    /// The pill: nil in control (the badge says "You have control") or when input isn't possible (`canControl`: the
    /// picture shows and Accessibility is granted; the badge alone then). Full screen counts as not in control.
    static func pill(controlling: Bool, canControl: Bool, role: ScreenControlModel.Role) -> Pill? {
        guard !controlling, canControl else { return nil }
        return switch role {
        case .free, .me: .free
        case .agent: .agent
        case let .other(name): .other(name: name)
        }
    }
}

/// A compact glass capsule while this page doesn't control: who holds it and a button to take it ("View only · Take
/// Control", "Agent is using the screen · Take Over", "<name> is controlling · Take Over").
final class ScreenControlPill: UIView {
    var onTakeOver: (() -> Void)?
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let icon = UIImageView(image: UIImage(systemName: "iphone"))
    private let label = UILabel()
    private var button: UIButton!
    private var shown = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        icon.tintColor = Theme.secondaryText
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var c = UIButton.Configuration.plain()
        c.title = L("Take Over")
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
            return a
        }
        c.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        let button = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.takeOver() })
        button.accessibilityIdentifier = "screen.takeOver"
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.button = button
        let dot = UILabel()
        dot.text = "·"
        dot.font = .preferredFont(forTextStyle: .footnote)
        dot.textColor = Theme.tertiaryText
        dot.isAccessibilityElement = false
        let stack = UIStackView(arrangedSubviews: [icon, label, dot, button])
        stack.spacing = 6
        stack.setCustomSpacing(2, after: dot)
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -3),
        ])
        accessibilityIdentifier = "screen.viewer"
        label.accessibilityIdentifier = "screen.viewer.label"
    }
    required init?(coder: NSCoder) { fatalError() }

    private(set) var state: ScreenControlPolicy.Pill?

    func set(_ state: ScreenControlPolicy.Pill) {
        guard state != self.state else { return }
        self.state = state
        let (symbol, text, title, tint) = Self.content(state)
        label.text = text
        icon.image = UIImage(systemName: symbol)
        icon.tintColor = tint
        button.configuration?.title = title
        button.accessibilityHint = text
    }

    /// The icon, the words, the button's title and the icon's tint for a state.
    private static func content(_ state: ScreenControlPolicy.Pill) -> (String, String, String, UIColor) {
        switch state {
        case .free:
            return ("eye", L("View only"), L("Take Control"), Theme.secondaryText)
        case .agent:
            return ("sparkle", L("Agent is using the screen"), L("Take Over"), Theme.coral)
        case let .other(name):
            let holder = ScreenControlModel.displayName(name)
            // the holder's kind of device when its name says it
            return (holder.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone", L("\(holder) is controlling"),
                    L("Take Over"), Theme.secondaryText)
        }
    }

    /// The button's title (tests).
    var buttonTitle: String? { button.configuration?.title }

    /// Shows (springs in from a little smaller) or goes (fades); Reduce Motion: a fade.
    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        guard window != nil else { isHidden = !on; alpha = 1; transform = .identity; return }
        let motion = !UIAccessibility.isReduceMotionEnabled
        if on {
            isHidden = false
            alpha = 0
            if motion { transform = CGAffineTransform(scaleX: 0.9, y: 0.9) }
            UIView.animate(springDuration: 0.35, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction]) {
                self.alpha = 1
                self.transform = .identity
            }
        } else {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.alpha = 0
            } completion: { _ in
                guard !self.shown else { return }
                self.isHidden = true
                self.alpha = 1
            }
        }
    }

    /// A touch that does nothing while watching: the pill swells a little and settles, with a soft tap.
    func nudge() {
        guard shown else { return }
        UIImpactFeedbackGenerator(style: .soft, view: self).impactOccurred(intensity: 0.7)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(springDuration: 0.15, bounce: 0, initialSpringVelocity: 0, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
        } completion: { _ in
            UIView.animate(springDuration: 0.4, bounce: 0.35, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = .identity
            }
        }
    }

    private func takeOver() {
        UIImpactFeedbackGenerator(style: .light, view: self).impactOccurred()
        onTakeOver?()
    }
}
