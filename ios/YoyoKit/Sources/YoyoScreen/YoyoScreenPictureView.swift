import AVFoundation
import ImageIO
import UIKit
import YoyoClipboard
import YoyoCore

/// A session's picture of the computer's screen (`YoyoScreenSession`): the video (decoded straight into a display
/// layer), the still it becomes while the picture is on its way back (dimmed), the pointer where the computer sends
/// cursor parts (drawn here: it follows this phone's input at once), the rings that show clicks. Aspect-fit in the
/// bounds less `contentInsets` (`pictureFrame`: where the display is drawn, this view's coordinates). It only zooms:
/// pinch (`ScreenZoom`; the shown part then follows the pointer as it moves), double tap to fit again (or, fitted, to
/// zoom in there), a tap is the host's (`onTap`): a touch on the picture never clicks the computer. Touches off the
/// picture aren't its (they go to what is under it), nor are any while a trackpad has a finger on it. Over the picture
/// it says when the connection is on its way back or the display can't be shown, with a Retry
/// (`showsConnectionOverlay`). A `YoyoTrackpadView` driving this picture shows a liquid drop that magnifies around the
/// pointer while its fingers work (`ScreenDrop`), and a badge by the pointer while it drags or scrolls.
///
/// The session's pictures go to the picture view made (or moved into a window) last: one shows a session at a time.
/// Moving the one that shows it to another superview or window keeps it showing (it takes nothing from its layer).
/// For a transition, `pictureContentView` is the view that draws the picture and `snapshotView()` a still of it; for
/// Picture in Picture, `videoDisplayLayer`.
@MainActor
public final class YoyoScreenPictureView: UIView, UIGestureRecognizerDelegate {
    public let session: YoyoScreenSession

    /// Room the picture leaves free at the edges of the bounds (the host's bars).
    public var contentInsets: UIEdgeInsets = .zero { didSet { if contentInsets != oldValue { setNeedsLayout() } } }
    /// Where the display is drawn, this view's coordinates (before the first picture, where a 16:10 one would be).
    public private(set) var pictureFrame: CGRect = .zero
    /// The picture's size in pixels (zero: none yet).
    public var pictureSize: CGSize { imageSize }
    /// Width over height of the picture (before the first one, a Mac's usual 16:10).
    public var pictureAspect: CGFloat {
        imageSize.width > 0 && imageSize.height > 0 ? imageSize.width / imageSize.height : 1.6
    }
    /// `pictureFrame` changed (a picture of another shape, the bounds, the insets).
    public var onPictureFrameChange: (() -> Void)?
    /// Pinch and double tap zoom (false: always fitted).
    public var zoomEnabled = true {
        didSet {
            pinch.isEnabled = zoomEnabled
            pictureDoubleTap.isEnabled = zoomEnabled
            if !zoomEnabled { resetZoom(animated: false) }
        }
    }
    /// Zoomed in.
    public var isZoomed: Bool { zoom.zoomed }
    /// A one-finger tap on the picture (it never clicks), and whether it is zoomed in.
    public var onTap: ((_ zoomed: Bool) -> Void)?
    /// The picture zoomed in (true, from fitted) or went back to fitted (false).
    public var onZoomChange: ((_ zoomed: Bool) -> Void)?
    /// Says over the picture when it is on its way back (a spinner and why) or the display can't be shown (why, and
    /// Retry), and shows a spinner before the first picture.
    public var showsConnectionOverlay = true { didSet { renderConnection() } }
    /// The view that draws the picture (it clips the zoomed picture to `pictureFrame`): for a host's transition.
    public var pictureContentView: UIView { pictureClip }
    /// The layer the session's video is decoded into, this view's for as long as it lives: for a host's Picture in
    /// Picture (`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`). While this
    /// view shows the session, every picture is enqueued into it as it is shown (off the main thread, each to be
    /// displayed at once: no timebase); the host only hands it to Picture in Picture (it doesn't enqueue, flush or set
    /// a timebase). It keeps its picture as this view moves to another superview or window or its frame changes (it
    /// stays the session's: see the class), and while the picture is a still (the stream on its way back, its view
    /// hidden then); it is emptied only for another display, and holds nothing before the first video picture.
    public var videoDisplayLayer: AVSampleBufferDisplayLayer { videoView.displayLayer }
    /// Fingers are on the picture now (a pinch, a tap).
    public var isTouched: Bool { pictureObserver.count > 0 }
    /// How many.
    var touchCount: Int { pictureObserver.count }
    /// The picture's VoiceOver label (by default, whose screen it is).
    public var pictureAccessibilityLabel: String? {
        didSet { imageView.accessibilityLabel = pictureAccessibilityLabel ?? session.computer.pictureLabel }
    }

    let imageView = UIImageView()
    /// The picture's frame, clipping what's in it: the picture (zoomed: bigger than this, `zoom`), the loupe and the
    /// pointer.
    private let pictureClip = UIView()
    /// The video picture (decoded pictures are enqueued straight into its renderer, off the main thread). It lies over
    /// the still image, so layout and touch mapping are the same for both.
    let videoView = ScreenVideoLayerView()
    /// The pointer and the click rings, over the picture and the loupe (same bounds as the picture).
    private let overlay = UIView()
    let loupe = ScreenDropView()
    /// By the pointer while a drag holds the button or two fingers scroll.
    let pointerBadge = ScreenPointerBadge()
    private let connectionOverlay = ScreenConnectionOverlay()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let pictureGuide = UILayoutGuide()
    private var pictureGuideConstraints: [NSLayoutConstraint] = []
    // pinch to zoom, double tap to fit (or zoom in), a tap (the host says how), and the fingers on it
    private let pinch = UIPinchGestureRecognizer()
    private let pictureDoubleTap = UITapGestureRecognizer()
    private let pictureTap = UITapGestureRecognizer()
    private let pictureObserver = ScreenTouchObserver()
    /// The zoom (1 = fitted) and the part of the display shown (`ScreenZoom`).
    private(set) var zoom = ScreenZoom()
    /// The pinch's zoom as it began, and the display's point (normalized) under its fingers.
    private var pinchStart: (scale: CGFloat, anchor: CGPoint)?
    /// The pointer the shown part last followed (it moves only when the pointer does: a pinch elsewhere stays there).
    private var followedPointer: CGPoint?
    private var imageSize: CGSize = .zero
    /// The trackpad that drives the pointer here (the loupe, the badge).
    weak var driver: YoyoTrackpadView?
    /// Where this phone has the pointer (normalized; the trackpad moves it).
    var pointer = CGPoint(x: 0.5, y: 0.5)
    /// The display's size in points (the pointer's size, the trackpad's moves); zero: the picture's.
    private(set) var displaySize: CGSize = .zero
    private var observation: YoyoScreenObservation?
    /// The loupe's sink of the session's pictures (active while it shows).
    private var loupeSink: Int?

    public init(session: YoyoScreenSession) {
        self.session = session
        super.init(frame: .zero)
        clipsToBounds = true
        pictureClip.clipsToBounds = true
        addSubview(pictureClip)
        imageView.contentMode = .scaleToFill
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = session.computer.pictureLabel
        imageView.accessibilityIdentifier = "screen.image"
        imageView.layer.minificationFilter = .trilinear
        pictureClip.addSubview(imageView)
        videoView.frame = imageView.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.isHidden = true
        imageView.addSubview(videoView)
        dimView.frame = imageView.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.backgroundColor = .black
        dimView.alpha = 0
        dimView.isUserInteractionEnabled = false
        imageView.addSubview(dimView)
        pictureClip.addSubview(loupe)
        loupe.onMagnification = { [weak self] m in self?.setLensScale(m) }
        overlay.isUserInteractionEnabled = false
        pictureClip.addSubview(overlay)
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 1
        cursorLayer.contentsGravity = .resize
        cursorLayer.magnificationFilter = .linear
        overlay.layer.addSublayer(cursorLayer)
        overlay.addSubview(pointerBadge)

        addLayoutGuide(pictureGuide)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        connectionOverlay.translatesAutoresizingMaskIntoConstraints = false
        connectionOverlay.isHidden = true
        connectionOverlay.onRetry = { [weak session] in session?.retryConnection() }
        addSubview(connectionOverlay)
        pictureGuideConstraints = [
            pictureGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            pictureGuide.topAnchor.constraint(equalTo: topAnchor),
            pictureGuide.widthAnchor.constraint(equalToConstant: 0),
            pictureGuide.heightAnchor.constraint(equalToConstant: 0),
        ]
        NSLayoutConstraint.activate(pictureGuideConstraints + [
            spinner.centerXAnchor.constraint(equalTo: pictureGuide.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: pictureGuide.centerYAnchor),
            connectionOverlay.centerXAnchor.constraint(equalTo: pictureGuide.centerXAnchor),
            connectionOverlay.centerYAnchor.constraint(equalTo: pictureGuide.centerYAnchor),
            connectionOverlay.widthAnchor.constraint(lessThanOrEqualTo: pictureGuide.widthAnchor, constant: -24),
            connectionOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            connectionOverlay.heightAnchor.constraint(lessThanOrEqualTo: pictureGuide.heightAnchor, constant: -8),
        ])

        pinch.addTarget(self, action: #selector(pinched(_:)))
        pictureDoubleTap.numberOfTapsRequired = 2
        pictureDoubleTap.addTarget(self, action: #selector(pictureDoubleTapped(_:)))
        pictureTap.addTarget(self, action: #selector(pictureTapped(_:)))
        // a double tap fits (or zooms): its first tap says nothing
        pictureTap.require(toFail: pictureDoubleTap)
        for g in [pinch, pictureDoubleTap, pictureTap, pictureObserver] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }

        loupeSink = session.videoOutput.addSink(active: false) { [frames = loupe.frames] in frames.receive($0) }
        attach()
        observation = session.observe { [weak self] update in
            guard let self, case let .changed(c) = update else { return }
            if !c.isDisjoint(with: [.status, .connection, .computer]) { self.sessionChanged(c) }
        }
        sessionChanged([.status, .computer])
    }
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        session.videoOutput.detach(videoView.displayLayer.sampleBufferRenderer)
        if let loupeSink { session.videoOutput.removeSink(loupeSink) }
    }

    /// This view shows the session's pictures from now on (the one made, or moved into a window, last does). Not
    /// again for the one that shows them already: a move to another superview or window leaves its layer as it is.
    private func attach() {
        session.picture = self
        session.videoOutput.attach(videoView.displayLayer.sampleBufferRenderer)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, session.picture !== self { attach() }
    }

    private func sessionChanged(_ c: YoyoScreenSession.Changes) {
        if c.contains(.computer), pictureAccessibilityLabel == nil { imageView.accessibilityLabel = session.computer.pictureLabel }
        if c.contains(.status), let d = session.currentDisplay, d.width.isFinite, d.height.isFinite {
            displaySize = CGSize(width: d.width, height: d.height)
        }
        renderConnection()
    }

    /// Only the picture takes a touch (or any while a finger is on it); none while a trackpad has a finger on it.
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if pictureObserver.count > 0 { return true }
        if driver?.isTouched == true { return false }
        return pictureFrame.contains(point)
    }

    /// The picture's recognizers take a touch that lands on the picture as it shows.
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        pictureObserver.count > 0 || isOnPicture(touch.location(in: self))
    }

    /// The pinch and the tap work on their own touches: they never wait for one another.
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === pictureTap && other === pinch) || (g === pinch && other === pictureTap)
    }

    /// On the picture as it shows.
    func isOnPicture(_ p: CGPoint) -> Bool { imageSize.width > 0 && pictureFrame.contains(p) }

    // MARK: Coordinates

    /// Where a point of the display (normalized, 0…1) is drawn now, this view's coordinates (zoomed: maybe outside the
    /// picture's frame).
    public func viewPoint(fromNormalized p: CGPoint) -> CGPoint {
        let f = imageView.frame.width > 0 ? imageView.frame : CGRect(origin: .zero, size: pictureFrame.size)
        return CGPoint(x: pictureFrame.minX + f.minX + p.x * f.width, y: pictureFrame.minY + f.minY + p.y * f.height)
    }

    /// The display's point (normalized) drawn at `p` (this view's coordinates); nil off the picture.
    public func normalizedPoint(fromView p: CGPoint) -> CGPoint? {
        guard pictureFrame.contains(p) else { return nil }
        let size = pictureClip.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        return zoom.point(at: CGPoint(x: p.x - pictureFrame.minX, y: p.y - pictureFrame.minY), in: size)
    }

    /// A click somewhere else made (automation's, another device's) shows at `normalized`: the click ring this
    /// phone's own clicks show.
    public func showRipple(at normalized: CGPoint) { showClick(at: normalized, dipsPointer: false) }

    /// A still of the picture as it shows now, in `pictureFrame` (nil: no picture yet).
    public func snapshotView() -> UIView? {
        let image = showsVideo ? session.videoOutput.snapshot() : imageView.image
        guard let image, pictureFrame.width > 0 else { return nil }
        let still = UIImageView(image: image)
        still.contentMode = .scaleToFill
        still.frame = pictureFrame
        return still
    }

    // MARK: Pictures

    /// A still picture (it also hides the video picture; nil: none, another display is coming). One of another shape
    /// lays the picture out afresh.
    var image: UIImage? {
        get { imageView.image }
        set {
            pictureChanges &+= 1
            imageView.image = newValue
            loupe.image = newValue
            if !videoView.isHidden { videoView.isHidden = true; loupe.showsVideo = false }
            setPictureSize(newValue?.size ?? .zero)
        }
    }

    /// Bumped whenever what the picture shows changes (a video picture, a still): a still made off the main thread is
    /// only put up if nothing came in the meantime (`freezeVideo(from:)`).
    private var pictureChanges = 0

    /// A video picture of `size` pixels is showing (the part's frame size: it covers the whole display). Back over a
    /// still (a reopen): it crossfades in, and another shape lays out smoothly (`ScreenPictureReveal`).
    func showVideo(size: CGSize) {
        pictureChanges &+= 1
        let returning = videoView.isHidden && imageView.image != nil
        if videoView.isHidden { videoView.isHidden = false; loupe.showsVideo = true }
        guard returning else { setPictureSize(size); return }
        ScreenPictureReveal.fadeIn(videoView)
        ScreenPictureReveal.layout(animated: size != imageSize) { setPictureSize(size); superview?.layoutIfNeeded() }
    }

    var showsVideo: Bool { !videoView.isHidden }

    /// The video picture becomes `still` (its last picture, as an image), laid out as it was (the image's size may
    /// differ from the frame size by the decoder's padding). The next picture replaces it.
    func freezeVideo(as still: UIImage) {
        pictureChanges &+= 1
        imageView.image = still
        loupe.image = still
        videoView.isHidden = true
        loupe.showsVideo = false
    }

    /// The video picture becomes a still of `output`'s newest picture, made off the main thread (a GPU conversion and a
    /// copy of a full-size picture: tens of ms, `ScreenVideoOutput.still(of:)`). Meanwhile the display layer keeps
    /// showing that same picture; a picture or still that comes first (the next stream's, another display) wins, and
    /// the still is dropped. `done` (tests): on the main thread once it is decided.
    func freezeVideo(from output: ScreenVideoOutput, done: (@MainActor @Sendable () -> Void)? = nil) {
        guard showsVideo, let last = output.newest() else { done?(); return }
        let changes = pictureChanges
        ScreenVideoOutput.stills.async { [weak self] in
            let still = ScreenVideoOutput.still(of: last)?.preparingForDisplay()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    defer { done?() }
                    guard let self, let still, self.showsVideo, self.pictureChanges == changes else { return }
                    self.freezeVideo(as: still)
                }
            }
        }
    }

    /// Another display: the picture and the pointer drawn here go.
    func clearPicture() {
        image = nil
        resetCursor()
    }

    /// Over the picture (the pointer stays above it): dims it while it is a still.
    private let dimView = UIView()
    nonisolated static let dimAlpha: CGFloat = 0.45

    /// The picture is a still (the connection is on its way back, or gone): dimmed.
    private(set) var dimmed = false

    func setDimmed(_ on: Bool, animated: Bool) {
        guard on != dimmed else { return }
        dimmed = on
        let alpha = on ? Self.dimAlpha : 0
        loupe.dim = alpha
        // the first new picture lifts it as it crossfades in
        ScreenPictureReveal.dim(dimView, to: alpha, animated: animated)
    }

    private func setPictureSize(_ size: CGSize) {
        guard size != imageSize else { return }
        let sameAspect = imageSize.width > 0 && size.width > 0
            && abs(imageSize.width / imageSize.height - size.width / size.height) < 0.002
        imageSize = size
        if !sameAspect {
            // another display: fitted again
            setZoom(ScreenZoom(), animated: false)
            setNeedsLayout(); layoutIfNeeded()
            onPictureFrameChange?()
        } else { layoutCursor() }
    }

    /// The overlay, the dimmed still and the plain spinner (no picture yet), from the session's connection state.
    private func renderConnection() {
        let o = session.inner.shownConnection
        let hasFrame = session.hasPicture
        let showing = session.canShow
        // a reconnect nobody explained, before any picture, is just the spinner
        let overlay = showsConnectionOverlay && showing && !o.phase.isLive && (hasFrame || o.phase != .reconnecting(reason: nil))
        setDimmed(showing && hasFrame && !o.phase.isLive, animated: true)
        if overlay { connectionOverlay.set(o.phase, host: session.computer) }
        connectionOverlay.isHidden = !overlay
        if showsConnectionOverlay, showing, !hasFrame, !overlay { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    // MARK: Layout

    /// The picture's frame for a picture of `aspect` (width / height) in `area`: aspect-fit and centered (an area of
    /// the picture's own shape, to the point, is filled).
    nonisolated static func fit(area: CGRect, aspect: CGFloat) -> CGRect {
        guard area.width > 0, area.height > 0, aspect.isFinite, aspect > 0 else { return .zero }
        if abs(area.width / aspect - area.height) < 1 { return area }
        let s = min(area.width / aspect, area.height)
        let size = CGSize(width: floor(s * aspect), height: floor(s))
        return CGRect(x: area.minX + floor((area.width - size.width) / 2), y: area.minY + floor((area.height - size.height) / 2),
                      width: size.width, height: size.height)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let picture = Self.fit(area: bounds.inset(by: contentInsets), aspect: pictureAspect)
        let changed = picture != pictureFrame
        pictureFrame = picture
        pictureClip.frame = picture
        let values = [picture.minX, picture.minY, picture.width, picture.height]
        for (c, v) in zip(pictureGuideConstraints, values) where c.constant != v { c.constant = v }
        layoutZoom()
        layoutCursor()
        if changed { onPictureFrameChange?() }
    }

    // MARK: Zoom

    /// The picture at the zoom, in the clip (fitted: the clip's bounds); the pointer's overlay over it.
    private func layoutZoom() {
        let frame = imageSize.width > 0 ? zoom.frame(in: pictureClip.bounds.size) : .zero
        guard imageView.frame != frame else { return }
        imageView.frame = frame
        overlay.frame = frame
    }

    /// The picture as it shows now (zoomed: bigger than `pictureFrame`): the trackpad moves at its scale.
    var shownPicture: CGSize {
        imageView.frame.width > 0 ? imageView.frame.size : pictureFrame.size
    }

    /// Changes the zoom (springing to it when `animated`); `onZoomChange` hears when it goes in or back to fitted.
    func setZoom(_ z: ScreenZoom, animated: Bool) { setZoom(z, animated: animated, cursor: true) }

    /// `cursor`: lays the pointer out again (the pointer's own layout passes false: it goes on to do that).
    private func setZoom(_ z: ScreenZoom, animated: Bool, cursor: Bool) {
        let was = zoom.zoomed
        zoom = z
        // VoiceOver (and the UI tests) hear how far it is zoomed
        imageView.accessibilityValue = z.zoomed ? String(format: "%.1f×", z.scale) : nil
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(springDuration: 0.35, bounce: 0, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.layoutZoom()
            }
        } else {
            layoutZoom()
        }
        if cursor { layoutCursor() }
        if was != zoom.zoomed { onZoomChange?(zoom.zoomed) }
    }

    /// Back to the picture fitted.
    public func resetZoom(animated: Bool) {
        guard zoom != ScreenZoom() else { return }
        setZoom(ScreenZoom(), animated: animated)
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        let size = pictureClip.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let at = g.location(in: pictureClip)
        switch g.state {
        case .began:
            pinchStart = (zoom.scale, zoom.point(at: at, in: size))
        case .changed:
            guard let start = pinchStart else { return }
            // the display's point that was under the fingers stays under them, as they spread and move
            var z = zoom
            z.scale = ScreenZoom.clampedScale(start.scale * g.scale, rubber: true)
            z.place(start.anchor, at: at, in: size)
            setZoom(z, animated: false)
        case .ended, .cancelled, .failed:
            pinchStart = nil
            // past the limits it springs back; nearly fitted is fitted
            var z = zoom
            z.scale = ScreenZoom.clampedScale(z.scale, rubber: false)
            if z.scale < ScreenZoom.snapToFit { z = ScreenZoom() } else { z.clampCenter() }
            setZoom(z, animated: true)
            // the shown part follows the pointer from where it is now
            followedPointer = followPoint
        default:
            break
        }
    }

    @objc private func pictureDoubleTapped(_ g: UITapGestureRecognizer) {
        let size = pictureClip.bounds.size
        guard size.width > 0 else { return }
        if zoom.zoomed {
            setZoom(ScreenZoom(), animated: true)
        } else {
            var z = ScreenZoom()
            z.scale = ScreenZoom.doubleTapScale
            z.center = zoom.point(at: g.location(in: pictureClip), in: size)
            z.clampCenter()
            setZoom(z, animated: true)
            followedPointer = followPoint
        }
        UIImpactFeedbackGenerator(style: .light, view: self).impactOccurred(intensity: 0.7)
    }

    @objc private func pictureTapped(_ g: UITapGestureRecognizer) {
        onTap?(zoom.zoomed)
    }

    /// The pointer the shown part follows: the one drawn here, else (controlling) where this phone has it.
    private var followPoint: CGPoint? {
        currentPointer ?? (session.isControlling ? pointer : nil)
    }

    /// Zoomed in, the shown part moves when the pointer does, just enough to keep it clear of the edges
    /// (`ScreenZoom.follow`); a jump far off springs there. Not while a pinch is under way.
    private func followPointer() {
        guard zoom.zoomed, pinchStart == nil, let p = followPoint, p != followedPointer else { return }
        followedPointer = p
        var z = zoom
        z.follow(p)
        guard z != zoom else { return }
        let jump = hypot((z.center.x - zoom.center.x) * zoom.scale, (z.center.y - zoom.center.y) * zoom.scale) > 0.5
        setZoom(z, animated: jump, cursor: false)
    }

    // MARK: Cursor (drawn here when the server sends cursor parts instead of drawing the pointer into the picture)

    private let cursorLayer = CALayer()
    private var cursor = ScreenCursorState()
    /// The loupe's magnification at the pointer now (1: none): the pointer grows as much around its hotspot.
    private var lensScale: CGFloat = 1
    /// The pointer's size before `lensScale`.
    private var cursorSize: CGSize = .zero
    /// Decoded cursor images by shape id.
    private var cursorImages: [Int: CGImage] = [:]
    /// Shape ids whose PNG didn't decode (the built-in arrow stands in).
    private var undecodableShapes = Set<Int>()
    /// Where this phone last sent the pointer, and when: shown until the server's cursor catches up.
    private var localCursor: (point: CGPoint, at: ContinuousClock.Instant)?

    /// A server cursor part.
    func applyCursor(_ update: ScreenCursorUpdate) {
        // a shape sent again under an id (another stream, another helper run) replaces the decoded one
        if let s = update.shape { cursorImages[s.id] = nil; undecodableShapes.remove(s.id) }
        cursor.apply(update)
        if let local = localCursor {
            // Handed back once the computer is where this phone last sent it. A position on the way there (the
            // answer to an earlier move) is only a few points behind while the pointer moves slowly: shown, it would
            // make the pointer jump back and forth.
            let caughtUp = Self.caughtUp(server: CGPoint(x: cursor.x, y: cursor.y), local: local.point, display: trackpadDisplay)
            if caughtUp || ContinuousClock.now - local.at > Self.localCursorHold { localCursor = nil }
        }
        layoutCursor()
    }

    /// The pointer goes to `point` (normalized) right away: this phone just sent it there.
    func moveCursor(to point: CGPoint) {
        pointer = point
        if cursor.received { localCursor = (point, .now) }
        layoutCursor()
    }

    /// Where the pointer is drawn now (normalized), nil when none is (the pictures carry the computer's own).
    var currentPointer: CGPoint? {
        if cursor.received, let local = localCursor { return local.point }
        guard cursor.received, cursor.visible else { return nil }
        return CGPoint(x: cursor.x, y: cursor.y)
    }

    /// Whether a client-drawn pointer shows now.
    var pointerDrawn: Bool { !cursorLayer.isHidden }

    /// The display's size the trackpad moves in (its points; before the status says, the picture's pixels).
    var trackpadDisplay: CGSize {
        displaySize.width > 0 && displaySize.height > 0 ? displaySize : imageSize
    }

    /// The pointer looks pressed (a drag: it stays at `ScreenClickFeedback.pressedScale` until released, then
    /// springs back). Without a client-drawn pointer a ring marks the spot instead.
    func setPressed(_ on: Bool, at point: CGPoint) {
        let reduce = UIAccessibility.isReduceMotionEnabled
        let to: CGFloat = on ? ScreenClickFeedback.pressedScale : 1
        if cursorLayer.isHidden {
            if on { showClick(at: point) }
            cursorLayer.transform = CATransform3DMakeScale(to, to, 1)
            return
        }
        let from = (cursorLayer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? (on ? 1 : ScreenClickFeedback.pressedScale)
        cursorLayer.transform = CATransform3DMakeScale(to, to, 1)
        guard !reduce else { return }
        let spring = CASpringAnimation(perceptualDuration: ScreenClickFeedback.duration, bounce: on ? 0 : ScreenClickFeedback.bounce)
        spring.keyPath = "transform.scale"
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        cursorLayer.add(spring, forKey: "press")
    }

    /// No pointer drawn (another stream, another display).
    func resetCursor() {
        cursor = ScreenCursorState()
        localCursor = nil
        layoutCursor()
    }

    /// How long after its last move a locally moved pointer ignores the server's (older) positions, at most: it is
    /// handed back as soon as the server's position gets there (the computer sends one as soon as it has handled the
    /// input).
    nonisolated static let localCursorHold: Duration = .milliseconds(600)
    /// How close (display points) the server's pointer must be to where this phone sent it to count as there (the
    /// computer rounds it to its pixels).
    nonisolated static let caughtUpTolerance: CGFloat = 2

    /// The server's pointer `server` is where this phone sent it, `local` (both normalized on a `display` of that
    /// many points; unknown: taken as 1000).
    nonisolated static func caughtUp(server: CGPoint, local: CGPoint, display: CGSize) -> Bool {
        let w = display.width.isFinite && display.width > 0 ? display.width : 1000
        let h = display.height.isFinite && display.height > 0 ? display.height : 1000
        return abs(server.x - local.x) * w <= caughtUpTolerance && abs(server.y - local.y) * h <= caughtUpTolerance
    }
    /// A cursor image wider or taller than this isn't a pointer.
    nonisolated static let maxCursorPixels = 512
    /// The pointer is drawn at least this tall on screen (points), whatever the picture's scale.
    nonisolated static let minPointerHeight: CGFloat = 20
    /// The Mac's arrow image is this tall (display points; 28 × 40 with its shadow): every shape grows by the factor
    /// that brings it to `minPointerHeight`, so the others keep their size next to it (the 23 × 22 I-beam was drawn as
    /// tall as the arrow, far bigger than the text it sits in).
    nonisolated static let referencePointerHeight: CGFloat = 40

    /// How much a pointer shape `shapeHeight` tall (0…1 of the display) grows on a picture `screenHeight` points tall
    /// showing a display `displayHeight` points tall (unknown: each shape on its own reaches `minPointerHeight`).
    nonisolated static func pointerGrow(shapeHeight: Double, screenHeight: CGFloat, displayHeight: CGFloat?) -> CGFloat {
        let onScreen: CGFloat
        if let displayHeight, displayHeight > 0, displayHeight.isFinite {
            onScreen = referencePointerHeight / displayHeight * screenHeight
        } else {
            onScreen = CGFloat(shapeHeight) * screenHeight
        }
        return onScreen > 0 && onScreen.isFinite ? max(1, minPointerHeight / onScreen) : 1
    }

    func layoutCursor() {
        followPointer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        defer { updateLoupe() }
        defer { updatePointerBadge() }
        let b = overlay.bounds
        guard cursor.received, cursor.visible, b.width > 0, b.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let p = localCursor?.point ?? CGPoint(x: cursor.x, y: cursor.y)
        // The image, its size in the display's 0…1 space and its hotspot as a fraction of it. No shape yet, or one that
        // doesn't decode: the built-in arrow at the minimum size, so a pointer the computer reports is never undrawn.
        let image: CGImage
        let w0: Double, h0: Double, hotFX: Double, hotFY: Double
        // The Mac's pointer at the display's own scale is ~6 pt tall once a whole 1792-px screen fits a phone: it grows
        // (around its hotspot) so the arrow is never smaller on screen than `minPointerHeight`, the other shapes alike.
        var grow: CGFloat = 1
        if let shape = cursor.shape, let decoded = cursorImage(shape) {
            image = decoded
            // not given: the image's pixels at the picture's scale
            w0 = shape.width > 0 ? shape.width : Double(decoded.width) / imageSize.width
            h0 = shape.height > 0 ? shape.height : Double(decoded.height) / imageSize.height
            hotFX = w0 > 0 ? shape.hotX / w0 : 0
            hotFY = h0 > 0 ? shape.hotY / h0 : 0
            grow = Self.pointerGrow(shapeHeight: h0, screenHeight: b.height,
                                    displayHeight: displaySize.height > 0 ? displaySize.height : nil)
        } else if let arrow = ScreenFallbackPointer.image {
            image = arrow
            h0 = Self.minPointerHeight / b.height
            w0 = h0 * ScreenFallbackPointer.aspect * b.height / b.width
            (hotFX, hotFY) = (ScreenFallbackPointer.hotspot.x, ScreenFallbackPointer.hotspot.y)
        } else {
            cursorLayer.isHidden = true
            return
        }
        let (w, h) = (w0 * grow, h0 * grow)
        cursorLayer.contents = image
        // anchored at the hotspot: a click's dip (`showClick`) shrinks the pointer towards where it points
        let anchor = CGPoint(x: min(max(hotFX, 0), 1), y: min(max(hotFY, 0), 1))
        cursorLayer.anchorPoint = anchor
        cursorSize = CGSize(width: w * b.width, height: h * b.height)
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: cursorSize.width * lensScale, height: cursorSize.height * lensScale)
        cursorLayer.position = CGPoint(x: (p.x - hotFX * w) * b.width + anchor.x * w * b.width,
                                       y: (p.y - hotFY * h) * b.height + anchor.y * h * b.height)
        cursorLayer.isHidden = false
    }

    private func cursorImage(_ shape: ScreenCursorUpdate.Shape) -> CGImage? {
        if let image = cursorImages[shape.id] { return image }
        guard !undecodableShapes.contains(shape.id) else { return nil }
        guard let source = CGImageSourceCreateWithData(shape.png as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0, w <= Self.maxCursorPixels, h <= Self.maxCursorPixels,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            // not tried again until the shape is sent again (`applyCursor`)
            if undecodableShapes.count >= ScreenCursorState.maxShapes { undecodableShapes.removeAll() }
            undecodableShapes.insert(shape.id)
            return nil
        }
        if cursorImages.count >= ScreenCursorState.maxShapes { cursorImages.removeAll() }
        cursorImages[shape.id] = image
        return image
    }

    // MARK: Loupe and badge (the trackpad drives them)

    private func updateLoupe() {
        if let driver { driver.updateLoupe() } else { hideLoupe(animated: false) }
    }

    private func updatePointerBadge() {
        if let driver { driver.updatePointerBadge() } else { pointerBadge.show(nil) }
    }

    /// The pointer's overlay's bounds (the badge is placed in them).
    var overlayBounds: CGRect { overlay.bounds }

    /// The loupe shows (aimed by the trackpad); its pictures come from the session while it does.
    func showLoupe() {
        loupe.setVisible(true, animated: true)
        if let loupeSink { session.videoOutput.setSink(loupeSink, active: true) }
    }

    func hideLoupe(animated: Bool) {
        guard loupe.visible else { return }
        loupe.setVisible(false, animated: animated)
        if let loupeSink { session.videoOutput.setSink(loupeSink, active: false) }
    }

    /// The loupe magnified this much at the pointer this frame: the pointer, anchored at its hotspot, grows as much
    /// (its place doesn't change).
    private func setLensScale(_ m: CGFloat) {
        lensScale = m
        guard !cursorLayer.isHidden, cursorSize.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.bounds = CGRect(x: 0, y: 0, width: cursorSize.width * m, height: cursorSize.height * m)
        CATransaction.commit()
    }

    /// Whether the loupe shows now.
    var loupeShown: Bool { loupe.visible }

    // MARK: Click feedback

    /// A click at `point` (normalized) right now: the pointer dips and springs back (`dipsPointer`), a faint ring
    /// spreads from where it points (Reduce Motion: the ring only fades). Before the computer answers, so a tap feels
    /// taken at once.
    func showClick(at point: CGPoint, dipsPointer: Bool = true) {
        let b = overlay.bounds
        guard b.width > 0, b.height > 0 else { return }
        let plan = ScreenClickFeedback(reduceMotion: UIAccessibility.isReduceMotionEnabled, pointerShown: !cursorLayer.isHidden && dipsPointer)
        if plan.scalesPointer {
            let dip = CASpringAnimation(perceptualDuration: ScreenClickFeedback.duration, bounce: ScreenClickFeedback.bounce)
            dip.keyPath = "transform.scale"
            dip.fromValue = ScreenClickFeedback.pointerScale
            dip.toValue = 1
            dip.duration = dip.settlingDuration
            cursorLayer.add(dip, forKey: "click")
        }
        let d = ScreenClickFeedback.ringDiameter
        let ring = CAShapeLayer()
        ring.zPosition = 2
        ring.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        ring.position = CGPoint(x: point.x * b.width, y: point.y * b.height)
        ring.path = UIBezierPath(ovalIn: ring.bounds.insetBy(dx: 1, dy: 1)).cgPath
        ring.fillColor = UIColor.white.withAlphaComponent(0.25).cgColor
        ring.strokeColor = UIColor.white.cgColor
        ring.lineWidth = 1.5
        ring.shadowColor = UIColor.black.cgColor
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 1.5
        ring.shadowOffset = .zero
        ring.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = ScreenClickFeedback.ringAlpha
        fade.toValue = 0
        fade.duration = ScreenClickFeedback.duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(fade, forKey: "fade")
        if plan.ringFromScale != 1 {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = plan.ringFromScale
            grow.toValue = 1
            grow.duration = ScreenClickFeedback.duration
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(grow, forKey: "grow")
        }
        overlay.layer.addSublayer(ring)
        CATransaction.commit()
    }
}

extension UIView {
    /// The view controller this view is the view of, or inside.
    var hostController: UIViewController? {
        var r: UIResponder? = self
        while let next = r?.next {
            if let vc = next as? UIViewController { return vc }
            r = next
        }
        return nil
    }
}
