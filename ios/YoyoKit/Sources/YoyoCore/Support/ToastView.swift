import UIKit

/// A brief glass notice above the composer ("Couldn’t read this file", "5 attachments max"…). Materializes by animating the glass
/// effect (never the glass view's alpha) and goes away on its own.
package final class ToastView: UIView {
    private let glass = UIVisualEffectView(effect: nil)
    private let label = UILabel()
    private var hideWork: DispatchWorkItem?

    package override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        glass.cornerConfiguration = .capsule()
        addSubview(glass)
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.text
        label.numberOfLines = 2
        label.textAlignment = .center
        label.alpha = 0
        glass.contentView.addSubview(label)
        accessibilityIdentifier = "toast"
    }
    package required init?(coder: NSCoder) { fatalError() }

    package override var intrinsicContentSize: CGSize {
        let s = label.sizeThatFits(CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: ceil(s.width) + 32, height: max(40, ceil(s.height) + 20))
    }

    package override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        label.frame = bounds.insetBy(dx: 16, dy: 8)
    }

    /// Shows `text` for `seconds`, then fades it.
    package func show(_ text: String, for seconds: TimeInterval = 2.8) {
        label.text = text
        invalidateIntrinsicContentSize()
        superview?.layoutIfNeeded()
        UIAccessibility.post(notification: .announcement, argument: text)
        hideWork?.cancel()
        setShown(true)
        let work = DispatchWorkItem { [weak self] in self?.setShown(false) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func setShown(_ shown: Bool) {
        let changes = {
            self.glass.effect = shown ? UIGlassEffect(style: .regular) : nil
            self.label.alpha = shown ? 1 : 0
            if !UIAccessibility.isReduceMotionEnabled {
                self.transform = shown ? .identity : CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.96, y: 0.96)
            }
        }
        if UIAccessibility.isReduceMotionEnabled { UIView.animate(withDuration: Motion.reducedFade, animations: changes) }
        else { Motion.animate(Motion.quickResponse, changes) }
    }
}
