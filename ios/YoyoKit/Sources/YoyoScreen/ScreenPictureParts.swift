import AVFoundation
import UIKit
import YoyoClipboard
import YoyoCore

// The parts the picture view (`YoyoScreenPictureView`) and the trackpad (`YoyoTrackpadView`) are made of.

/// The trackpad's panel (`YoyoTrackpadView`): a rounded, faintly filled panel with a hint in the middle; its rim lights
/// up while a finger is off it. Draws only (the trackpad takes the fingers).
final class ScreenTrackpadSurface: UIView {
    private let hintLabel = UILabel()
    private let icon = UIImageView(image: UIImage(systemName: "rectangle.and.hand.point.up.left"))
    private let stack: UIStackView
    /// Room kept free at the top (the page's badges).
    var topInset: CGFloat = 0 { didSet { setNeedsLayout() } }
    /// Controlling: the hint is quieter.
    var active = false { didSet { update() } }
    /// What the hint says.
    var hint: String? { didSet { hintLabel.text = hint; stack.isHidden = hint == nil } }
    /// A finger went off it: the rim lights up (clay) until every finger is back.
    var outside = false {
        didSet {
            guard outside != oldValue else { return }
            let reduce = UIAccessibility.isReduceMotionEnabled
            UIView.animate(withDuration: outside ? 0.12 : (reduce ? 0.2 : 0.35)) { self.updateRim() }
        }
    }

    override init(frame: CGRect) {
        stack = UIStackView(arrangedSubviews: [icon, hintLabel])
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        updateRim()
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2)
        icon.contentMode = .scaleAspectFit
        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.isHidden = true
        addSubview(stack)
        accessibilityIdentifier = "screen.trackpad"
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = bounds.inset(by: UIEdgeInsets(top: topInset, left: 24, bottom: 0, right: 24))
        let size = stack.systemLayoutSizeFitting(CGSize(width: r.width, height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        stack.frame = CGRect(x: r.minX, y: r.midY - size.height / 2, width: r.width, height: size.height)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateRim()
    }

    private func updateRim() {
        layer.borderWidth = outside ? 2 : 1
        layer.borderColor = (outside ? Theme.coral : UIColor.label.withAlphaComponent(0.08)).resolvedColor(with: traitCollection).cgColor
        backgroundColor = outside ? Theme.coral.withAlphaComponent(0.08) : UIColor.label.withAlphaComponent(0.05)
    }

    private func update() {
        let color = active ? Theme.tertiaryText : Theme.secondaryText
        hintLabel.textColor = color
        icon.tintColor = color
    }
}

/// What a click shows on the picture at once (`YoyoScreenPictureView.showClick`): the client-drawn pointer dips to
/// `pointerScale` and springs back while a faint ring (`ringDiameter` pt, alpha `ringAlpha` → 0) spreads from where it
/// points, over about `duration`. With Reduce Motion nothing scales: the ring only fades. Without a client-drawn pointer
/// (the pictures carry the Mac's) only the ring shows.
struct ScreenClickFeedback: Equatable, Sendable {
    static let pointerScale: CGFloat = 0.92
    /// A drag holds the pointer this small until it lets go (`YoyoScreenPictureView.setPressed`).
    static let pressedScale: CGFloat = 0.9
    static let ringDiameter: CGFloat = 22
    static let ringAlpha: Float = 0.16
    static let duration: TimeInterval = 0.12
    static let bounce: CGFloat = 0.15
    /// The ring's starting scale when it spreads (it ends at 1).
    static let ringSpreadFrom: CGFloat = 0.3

    /// The pointer dips and springs back.
    let scalesPointer: Bool
    /// The ring's starting scale (1: it doesn't spread, only fades).
    let ringFromScale: CGFloat

    init(reduceMotion: Bool, pointerShown: Bool) {
        scalesPointer = pointerShown && !reduceMotion
        ringFromScale = reduceMotion ? 1 : Self.ringSpreadFrom
    }
}

/// Watches the fingers without taking part in any gesture: the first one down, the last one up (a finger down makes
/// playback show pictures at once, and shows the loupe). Never begins, never prevents or delays another recognizer or
/// the touches.
final class ScreenTouchObserver: UIGestureRecognizer {
    var onFirstDown: (() -> Void)?
    var onAllUp: (() -> Void)?
    /// The fingers lifted and it was a tap (`ScreenTapSpotter`): how many fingers.
    var onTap: ((Int) -> Void)?
    /// The fingers lifted and it was no tap (it moved, was held, the system took it, or `spoil` said so).
    var onOtherTouch: (() -> Void)?
    /// More fingers came down: how many are down now.
    var onFingerCount: ((Int) -> Void)?
    /// The one finger down is this far (points) from where it landed (every move while only one is down).
    var onFingerMoved: ((CGPoint) -> Void)?
    /// Where the first finger of this touch landed, and where the last one of the touch before lifted.
    private(set) var landed: CGPoint?
    private(set) var liftedAt: CGPoint?
    /// The finger's speed and where it is, while exactly one is down (every coalesced sample).
    private(set) var finger = ScreenFingerSpeed()
    private var down = 0
    /// How many fingers are down now.
    var count: Int { down }
    private var spotter = ScreenTapSpotter()
    private var starts: [ObjectIdentifier: CGPoint] = [:]
    /// Where each finger is now.
    private var positions: [ObjectIdentifier: CGPoint] = [:]
    /// The area the fingers belong in (nil: anywhere), and whether one is out of it now.
    var area: ((CGPoint) -> Bool)?
    private var outside = false
    /// A finger went out of `area` (true) / every finger is back in it, or all lifted (false).
    var onLeftArea: ((Bool) -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if down == 0 {
            landed = touches.first?.location(in: view)
            onFirstDown?()
        }
        down += touches.count
        for t in touches {
            starts[ObjectIdentifier(t)] = t.location(in: view)
            positions[ObjectIdentifier(t)] = t.location(in: view)
        }
        updateOutside()
        spotter.down(fingers: down, at: event.timestamp)
        // a new single finger starts from rest; with more there is no one finger to follow
        if down == 1, let t = touches.first { finger.reset(at: t.location(in: view), time: t.timestamp) } else { finger.reset() }
        onFingerCount?(down)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches {
            guard let start = starts[ObjectIdentifier(t)] else { continue }
            let p = t.location(in: view)
            positions[ObjectIdentifier(t)] = p
            let distance = hypot(p.x - start.x, p.y - start.y)
            spotter.moved(distance)
            guard down == 1 else { continue }
            onFingerMoved?(CGPoint(x: p.x - start.x, y: p.y - start.y))
            for c in event.coalescedTouches(for: t) ?? [t] { finger.add(c.location(in: view), at: c.timestamp) }
        }
        updateOutside()
    }

    private func updateOutside() {
        guard let area else { return }
        let out = positions.values.contains { !area($0) }
        guard out != outside else { return }
        outside = out
        onLeftArea?(out)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lifted(touches, at: event.timestamp, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lifted(touches, at: event.timestamp, cancelled: true) }

    private func lifted(_ touches: Set<UITouch>, at time: TimeInterval, cancelled: Bool) {
        down = max(0, down - touches.count)
        for t in touches {
            if down == 0 { liftedAt = t.location(in: view) }
            starts[ObjectIdentifier(t)] = nil
            positions[ObjectIdentifier(t)] = nil
        }
        updateOutside()
        // the finger left on the glass starts afresh (its last samples were taken with another one down)
        if down == 1 { finger.reset() }
        if cancelled { spotter.cancel() }
        guard down == 0 else { return }
        let tap = spotter.allUp(at: time)
        onAllUp?()
        if let tap { onTap?(tap) } else { onOtherTouch?() }
        state = .failed  // done with this sequence (reset() follows)
    }

    override func reset() {
        super.reset()
        if down > 0 { onAllUp?() }
        down = 0
        starts = [:]
        positions = [:]
        if outside { outside = false; onLeftArea?(false) }
        spotter = ScreenTapSpotter()
    }

    /// This touch is no tap whatever it does next (a pan began in it).
    func spoil() { spotter.cancel() }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// The trackpad's one-finger pan, on its own: it neither prevents nor is prevented by the tap recognizers. UIKit resets
/// a recognizer that failed only once every recognizer it is tied to has finished: a plain pan fails in a tap, and while
/// the double tap still waits for a second tap (about 0.35 s) it stays failed, so the touch right after a tap could
/// neither move the pointer nor drag ("tap, then touch and drag" never armed). Unbound, it is reset with each touch.
/// Taps that moved are kept from clicking by `ScreenTapGate` instead.
final class ScreenTrackpadPan: UIPanGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// A small glass badge just below and right of the pointer (`YoyoTrackpadView.updatePointerBadge`) saying what the
/// fingers are doing, the way a Mac badges its pointer while dragging: a hand while a drag holds the button, arrows
/// along the scroll's axis while two fingers scroll (both ways until the axis is decided), leaning the way the fingers
/// go (`lean`). The glass materializes (its effect animates, never its alpha); the pointer itself stays as it is.
final class ScreenPointerBadge: UIView {
    enum Kind: Equatable {
        case drag
        case scroll(ScreenTwoFingerScroll.Axis?)

        var symbol: String {
            switch self {
            case .drag: "hand.draw.fill"
            case .scroll(.vertical?): "arrow.up.and.down"
            case .scroll(.horizontal?): "arrow.left.and.right"
            case .scroll: "arrow.up.and.down.and.arrow.left.and.right"
            }
        }
    }

    static let diameter: CGFloat = 26
    /// Its middle from where the pointer points (points): clear of the 20-pt arrow's body, just past its tail.
    static let offset = CGPoint(x: 20, y: 24)
    /// How far the arrows lean the fingers' way (points).
    static let leanDistance: CGFloat = 2.5

    private let glass = UIVisualEffectView(effect: nil)
    private let icon = UIImageView()
    private(set) var kind: Kind?
    private var straighten: DispatchWorkItem?

    init() {
        let d = Self.diameter
        super.init(frame: CGRect(x: 0, y: 0, width: d, height: d))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.zPosition = 3
        glass.frame = bounds
        glass.cornerConfiguration = .capsule()
        addSubview(glass)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        icon.tintColor = .white
        icon.contentMode = .center
        icon.frame = bounds
        icon.alpha = 0
        glass.contentView.addSubview(icon)
        accessibilityIdentifier = "screen.pointerBadge"
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `kind` (nil: goes away).
    func show(_ kind: Kind?) {
        guard kind != self.kind else { return }
        let was = self.kind
        self.kind = kind
        if let kind { icon.image = UIImage(systemName: kind.symbol) }
        guard (was == nil) != (kind == nil) else { return }
        let shown = kind != nil
        let reduce = UIAccessibility.isReduceMotionEnabled
        if shown, !reduce { transform = CGAffineTransform(scaleX: 0.6, y: 0.6) }
        let changes = {
            if shown {
                let g = UIGlassEffect(style: .regular)
                g.tintColor = UIColor.black.withAlphaComponent(0.35)
                self.glass.effect = g
            } else {
                self.glass.effect = nil
            }
            self.icon.alpha = shown ? 1 : 0
            if !reduce { self.transform = shown ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8) }
        }
        if reduce { UIView.animate(withDuration: Motion.reducedFade, animations: changes) }
        else {
            UIView.animate(springDuration: shown ? 0.32 : 0.22, bounce: shown ? 0.25 : 0, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
        }
        if !shown { icon.transform = .identity }
    }

    /// The fingers moved along `v` (any length): the arrows lean that way, and straighten a moment after they stop.
    func lean(_ v: CGVector) {
        let n = hypot(v.dx, v.dy)
        guard n > 0, n.isFinite, !UIAccessibility.isReduceMotionEnabled else { return }
        let to = CGAffineTransform(translationX: v.dx / n * Self.leanDistance, y: v.dy / n * Self.leanDistance)
        UIView.animate(springDuration: 0.18, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) { self.icon.transform = to }
        straighten?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(springDuration: 0.35, bounce: 0.3, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) { self.icon.transform = .identity }
        }
        straighten = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}

/// The pointer drawn when the Mac's shape is missing or doesn't decode: a black arrow with a white edge, like the Mac's.
enum ScreenFallbackPointer {
    /// The arrow's box (points) and its tip, the hotspot, as a fraction of it.
    static let size = CGSize(width: 13, height: 20)
    static let hotspot = CGPoint(x: 1.5 / 13, y: 1.5 / 20)
    /// Width over height.
    static var aspect: Double { size.width / size.height }

    static let image: CGImage? = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 1.5, y: 1.5))
            path.addLine(to: CGPoint(x: 1.5, y: 16.5))
            path.addLine(to: CGPoint(x: 5, y: 13))
            path.addLine(to: CGPoint(x: 7.5, y: 18.5))
            path.addLine(to: CGPoint(x: 10, y: 17.5))
            path.addLine(to: CGPoint(x: 7.5, y: 12))
            path.addLine(to: CGPoint(x: 12, y: 12))
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 1.5
            UIColor.white.setStroke()
            path.stroke()
            UIColor.black.setFill()
            path.fill()
        }.cgImage
    }()
}

/// A view whose layer is an `AVSampleBufferDisplayLayer` stretched over its bounds (the picture covers the display).
final class ScreenVideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        displayLayer.videoGravity = .resize
        // watching doesn't keep the phone awake
        displayLayer.preventsDisplaySleepDuringVideoPlayback = false
    }
    required init?(coder: NSCoder) { fatalError() }
}
