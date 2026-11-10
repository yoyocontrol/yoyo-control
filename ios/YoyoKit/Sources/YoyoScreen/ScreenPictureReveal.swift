import UIKit
import YoyoClipboard
import YoyoCore

/// How the picture comes back after a reopen (the Mac switched how it serves it, the stream moved): the held still
/// stays put, the new stream's first picture crossfades in over it (ease-out, `fade`), a picture of another shape lays
/// the canvas out with a spring instead of jumping, and the dim of a reconnect lifts with the same fade. Reduce
/// Motion: a cut.
@MainActor
enum ScreenPictureReveal {
    static let fade: TimeInterval = 0.2

    static var animates: Bool { !UIAccessibility.isReduceMotionEnabled }

    /// `view` (just shown over the still) fades in.
    static func fadeIn(_ view: UIView) {
        view.layer.removeAnimation(forKey: "opacity")
        guard animates else { view.alpha = 1; return }
        view.alpha = 0
        UIView.animate(withDuration: fade, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            view.alpha = 1
        }
    }

    /// `changes` (a new picture size and the layout it brings), with a critically damped spring.
    static func layout(animated: Bool, _ changes: () -> Void) {
        guard animated, animates else { changes(); return }
        UIView.animate(springDuration: 0.35, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
    }

    /// The dim over a still goes to `alpha` (on: 0.25 s; off, the picture back: `fade`, ease-out; Reduce Motion: off
    /// at once).
    static func dim(_ view: UIView, to alpha: CGFloat, animated: Bool) {
        view.layer.removeAllAnimations()
        let on = alpha > 0
        guard animated, on || animates else { view.alpha = alpha; return }
        UIView.animate(withDuration: on ? 0.25 : fade, delay: 0, options: on ? [] : [.curveEaseOut, .allowUserInteraction]) {
            view.alpha = alpha
        }
    }
}
