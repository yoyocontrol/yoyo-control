import UIKit
import YoyoClipboard
import YoyoCore

/// The kit's Screen page.
public enum YoyoScreen {
    /// The Screen page for `backend`'s computer, in a navigation controller of its own (`ScreenNavigationController`:
    /// orientation, the status bar, the home indicator and the deferred edge gestures are the page's), its bars hidden:
    /// the page draws its own buttons. `host` becomes `YoyoHost.current`; how the page is presented follows its
    /// `presentation` (full screen by default; a host's own transition can ask the page which touches it may take for a
    /// swipe to close: `YoyoPageSwipeGate`). A page of one's own: `YoyoScreenSession` with `YoyoScreenPictureView`,
    /// `YoyoTrackpadView` and `YoyoScreenKeyboard`, which this page is made of.
    @MainActor public static func makePage(backend: any YoyoBackend, host: YoyoHost? = nil) -> UINavigationController {
        if let host { YoyoHost.current = host }
        let nav = ScreenNavigationController(rootViewController: ScreenViewController(backend: backend))
        nav.isNavigationBarHidden = true
        nav.isToolbarHidden = true
        switch YoyoHost.current.presentation {
        case .fullScreen: nav.modalPresentationStyle = .fullScreen
        case .custom(let configure): configure(nav)
        }
        return nav
    }
}

/// "Screen": a computer's screen, live (docs/PROTOCOL.md「屏幕」), made of the kit's layers: a `YoyoScreenSession`
/// (`.takeOnInput`: the stream, the sound, the status, control and input; no views), its `YoyoScreenPictureView` at
/// the top, full width, the `YoyoTrackpadView` under it and a `YoyoScreenKeyboard`. A three-finger tap shows a stats
/// line (codec, fps, KB/s, decode time; shown and arrival gaps, hitches, stalls, buffer depth, jitter, drops; the way;
/// the network grade; the sound). The page opens as a viewer and takes the screen only at a real input: the first touch
/// on the trackpad, the keyboard button, a key or typed text, a paste into the computer (ScreenControlPolicy; the user
/// wins over automation then). Opening, coming back, zooming or panning the picture, full screen and turning the phone
/// never take it, so an agent working between short idle gaps isn't stopped by someone who only watches; the trackpad
/// says what takes it, and while the page doesn't control a pill at the top says who holds it with an explicit button
/// ("View only · Take Control", "Agent is using the screen · Take Over", "<name> is controlling · Take Over": another
/// phone's control only goes this way; in full screen the button leaves full screen into control). Only the trackpad's
/// panel under the picture takes trackpad touches; the picture pinches to zoom (the shown part follows the pointer), a
/// double tap fits it again, a tap on it says so; a sideways swipe that starts under the picture, off the trackpad (the
/// buttons' row), takes the page off (a host transition that honours `YoyoPageSwipeGate`). The full-screen button on
/// the picture's corner turns the page to landscape with the picture alone, view only like a video player
/// (`viewOnly`): control is given back, the buttons go (a tap on the picture brings the button back for a moment).
/// Otherwise a phone keeps the page in portrait. In control: taps click, touch-and-hold right-clicks or (moved on from)
/// drags, two fingers scroll, the keyboard types in portrait (it comes up by itself when a click focuses something that
/// takes typing; it covers the page rather than pushing it up, a touch on the trackpad puts it away, and landscape has
/// none); its «?» shows the gestures (a card that also opens by itself the first time the page takes control). A badge
/// says who drives the screen (automation on the computer can too). The speaker button turns the computer's sound off
/// (kept in `<namespace>Audio`), and a computer without sound hides it.
///
/// Whose computer it is (`YoyoComputer`) follows the status's `platform` once said (before: the backend's hint): a Mac
/// ("Screen", the macOS permission prompts, ⌘V), or another computer ("Desktop", "the computer", no macOS
/// permissions); everything else is the same page. The clipboard button, keys and hints show when that computer has a
/// clipboard (`YoyoComputer.hasClipboard`: `features.clipboard`, else the Mac only). While the screen can't be shown the
/// backend may offer something to do about it (`ScreenStatus.unavailableAction`: a button that opens a link).
final class ScreenViewController: UIViewController {
    let session: YoyoScreenSession
    private let picture: YoyoScreenPictureView
    private let trackpad: YoyoTrackpadView
    private let keyboard: YoyoScreenKeyboard
    private var observation: YoyoScreenObservation?

    /// Full screen, view only (like a video player): no control, landscape, the picture alone with its button (faded
    /// after a moment).
    private(set) var fullScreen = false
    private var chromeFadeTask: Task<Void, Never>?

    private let badge = ScreenBadgeView()
    /// Who holds the screen while this page doesn't, with the button that takes it (ScreenControlPolicy.pill).
    private let pill = ScreenControlPill()
    private let accessNote = ScreenNoteView()
    private let toast = ToastView()
    /// Over the page, edge to edge, taking no touches: the toast, the one thing that keeps clear of the keyboard, is laid
    /// out in here on constraints of its own (this layer and its keyboard guide), so a keyboard showing, hiding or
    /// changing height (another input method) can never move anything of the page.
    private let floatLayer = UIView()
    /// How far up from the bottom the toast stays at least (over the buttons; set in `layoutPage`).
    private var toastClearance: NSLayoutConstraint!
    // The page's buttons, glass, over the page (no navigation bar or toolbar: the picture and the trackpad get the room).
    // Portrait: one row at the bottom (close, gestures, display | clipboard, sound, keyboard); landscape (an iPad): a
    // column on each side (no keyboard). Full screen: none (only the full-screen button on the picture).
    private let closeButton = ScreenGlassButton(symbol: "xmark")
    private let helpButton = ScreenGlassButton(symbol: "questionmark")
    /// The displays (with an external one): a menu to pick which shows. Hidden with one display.
    private let displayButton = ScreenGlassButton(symbol: "display.2")
    private let keyboardButton = ScreenGlassButton(symbol: "keyboard")
    private let audioButton = ScreenGlassButton(symbol: "speaker.wave.2.fill")
    /// The clipboard: a menu (Paste on Mac, Photos…, Files…, Copy from Mac, Open clipboard), a dot when either side has
    /// something new. Hidden on a server without the clipboard and in full screen.
    private let clipboardButton = ScreenGlassButton(symbol: "doc.on.clipboard")
    /// The hint over the picture ("iPhone clipboard: text — Paste on Mac", "Copied on Mac: … — Copy to iPhone").
    private let hintPill = ScreenHintPill()
    private var hint: ScreenClipboardHint?
    /// On the picture's bottom trailing corner: full screen (landscape, view only) and back.
    private let fullScreenButton = ScreenGlassButton(symbol: "arrow.up.left.and.arrow.down.right")
    /// What the picture does, said when it is tapped ("Pinch to zoom", zoomed: "Double-tap to fit").
    private let zoomHint = ScreenHintPill()
    private let leadingButtons = UIStackView()
    private let trailingButtons = UIStackView()
    private let badges = UIStackView()
    /// Where the picture is (kept in step with the picture view in `layoutPage`).
    private let pictureGuide = UILayoutGuide()
    private var pictureGuideConstraints: [NSLayoutConstraint] = []
    private var portraitConstraints: [NSLayoutConstraint] = []
    private var landscapeConstraints: [NSLayoutConstraint] = []
    private var badgesTop: NSLayoutConstraint!
    private var badgesCenterX: NSLayoutConstraint!
    /// The layout in force (nil: none yet).
    private var landscape: Bool?

    // Stats line (three-finger tap): codec, fps, KB/s, decode ms; the playout and the latency estimate; the server's
    // network grade (YoyoScreenSession.statsText)
    private let statsLabel = UILabel()
    private var statsTimer: Timer?

    /// The clipboard keys and button show (the computer has a clipboard).
    private var clipboardShown = false
    /// The phone's hint was considered on this visit (once the server's clipboard is known).
    private var phoneHintAsked = false

    init(backend: any YoyoBackend) {
        session = YoyoScreenSession(backend: backend, controlPolicy: .takeOnInput)
        picture = YoyoScreenPictureView(session: session)
        trackpad = YoyoTrackpadView(session: session, picture: picture)
        keyboard = YoyoScreenKeyboard(session: session)
        super.init(nibName: nil, bundle: nil)
        session.presenter = self
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Whose screen this is.
    var host: YoyoComputer { session.computer }
    var status: ScreenStatus? { session.status }
    /// Taps and keys go to the computer.
    var controlling: Bool { session.isControlling }

    // The whole page is a trackpad: the system's edge swipes (Home, Control Center) wait for a second swipe.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    /// No system three-finger editing gestures (undo swipes, copy pinches): three fingers drag here.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var prefersHomeIndicatorAutoHidden: Bool { landscape == true }
    override var prefersStatusBarHidden: Bool { landscape == true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        // control is with the trackpad and the keyboard, in portrait (a phone); full screen is watching, in landscape
        fullScreen ? .landscape : traitCollection.userInterfaceIdiom == .phone ? .portrait : super.supportedInterfaceOrientations
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = host.title
        view.backgroundColor = Theme.groupedBackground
        view.accessibilityIdentifier = "screen"

        closeButton.accessibilityLabel = L("Close")
        closeButton.accessibilityIdentifier = "screen.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        helpButton.accessibilityLabel = L("Gestures")
        helpButton.accessibilityIdentifier = "screen.gestures"
        helpButton.addAction(UIAction { [weak self] _ in self?.showGestureCard() }, for: .primaryActionTriggered)
        displayButton.accessibilityLabel = L("Display")
        displayButton.accessibilityIdentifier = "screen.display"
        displayButton.showsMenuAsPrimaryAction = true
        displayButton.isHidden = true
        keyboardButton.accessibilityLabel = L("Keyboard")
        keyboardButton.accessibilityIdentifier = "screen.keyboard"
        keyboardButton.addAction(UIAction { [weak self] _ in self?.keyboard.toggle() }, for: .primaryActionTriggered)
        audioButton.accessibilityIdentifier = "screen.audio"
        audioButton.addAction(UIAction { [weak self] _ in self?.toggleAudio() }, for: .primaryActionTriggered)
        updateAudioButton()
        fullScreenButton.accessibilityIdentifier = "screen.fullscreen"
        fullScreenButton.translatesAutoresizingMaskIntoConstraints = false
        fullScreenButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setFullScreen(!self.fullScreen)
        }, for: .primaryActionTriggered)
        updateFullScreenButton()
        zoomHint.isUserInteractionEnabled = false
        zoomHint.accessibilityIdentifier = "screen.zoomHint"
        zoomHint.translatesAutoresizingMaskIntoConstraints = false
        clipboardButton.accessibilityLabel = L("Clipboard")
        clipboardButton.accessibilityIdentifier = "screen.bar.clipboard"
        clipboardButton.showsMenuAsPrimaryAction = true
        clipboardButton.isHidden = true
        // built as it opens: what each side holds now (and opening it is seeing it: the dot goes)
        clipboardButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated { completion(self?.clipboardMenu() ?? []) }
        }])
        for (stack, buttons) in [(leadingButtons, [closeButton, helpButton, displayButton]),
                                 (trailingButtons, [clipboardButton, audioButton, keyboardButton])] {
            for b in buttons { stack.addArrangedSubview(b) }
            stack.spacing = 10
            stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
        }

        // the picture over the page (it takes only the touches on the picture), the trackpad under it; both laid out in
        // `layoutPage`
        view.addSubview(picture)
        view.addSubview(trackpad)
        view.addLayoutGuide(pictureGuide)
        // the pill under the controller badge (a hidden one takes no room)
        pill.isHidden = true
        pill.onTakeOver = { [weak self] in self?.takeControlTapped() }
        for b in [badge, pill] { badges.addArrangedSubview(b) }
        badges.axis = .vertical
        badges.alignment = .center
        badges.spacing = 6
        badges.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badges)
        accessNote.translatesAutoresizingMaskIntoConstraints = false
        accessNote.isHidden = true
        accessNote.onRequest = { [weak self] in self?.session.requestPermissions() }
        view.addSubview(accessNote)
        hintPill.translatesAutoresizingMaskIntoConstraints = false
        hintPill.onTap = { [weak self] in self?.hintTapped() }
        view.addSubview(hintPill)
        view.addSubview(zoomHint)
        view.addSubview(fullScreenButton)
        view.addSubview(leadingButtons)
        view.addSubview(trailingButtons)
        floatLayer.translatesAutoresizingMaskIntoConstraints = false
        floatLayer.isUserInteractionEnabled = false
        toast.translatesAutoresizingMaskIntoConstraints = false
        floatLayer.addSubview(toast)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statsLabel.textColor = .white
        statsLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
        statsLabel.layer.cornerRadius = 4
        statsLabel.layer.masksToBounds = true
        statsLabel.numberOfLines = 0
        statsLabel.isHidden = true
        // never takes touches: they go to the picture under it
        statsLabel.isUserInteractionEnabled = false
        statsLabel.accessibilityIdentifier = "screen.stats"
        view.addSubview(statsLabel)
        view.addSubview(keyboard)
        view.addSubview(floatLayer)

        let safe = view.safeAreaLayoutGuide
        pictureGuideConstraints = [
            pictureGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pictureGuide.topAnchor.constraint(equalTo: view.topAnchor),
            pictureGuide.widthAnchor.constraint(equalToConstant: 0),
            pictureGuide.heightAnchor.constraint(equalToConstant: 0),
        ]
        badgesTop = badges.topAnchor.constraint(equalTo: view.topAnchor)
        badgesCenterX = badges.centerXAnchor.constraint(equalTo: view.leadingAnchor)
        NSLayoutConstraint.activate(pictureGuideConstraints + [
            badgesTop, badgesCenterX,
            badges.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -32),
            accessNote.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            accessNote.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            statsLabel.leadingAnchor.constraint(equalTo: pictureGuide.leadingAnchor, constant: 8),
            statsLabel.topAnchor.constraint(equalTo: pictureGuide.topAnchor, constant: 8),
            statsLabel.trailingAnchor.constraint(lessThanOrEqualTo: pictureGuide.trailingAnchor, constant: -8),
            hintPill.topAnchor.constraint(equalTo: pictureGuide.topAnchor, constant: 10),
            hintPill.centerXAnchor.constraint(equalTo: pictureGuide.centerXAnchor),
            hintPill.widthAnchor.constraint(lessThanOrEqualTo: pictureGuide.widthAnchor, constant: -24),
            hintPill.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            zoomHint.bottomAnchor.constraint(equalTo: pictureGuide.bottomAnchor, constant: -12),
            zoomHint.centerXAnchor.constraint(equalTo: pictureGuide.centerXAnchor),
            zoomHint.widthAnchor.constraint(lessThanOrEqualTo: pictureGuide.widthAnchor, constant: -120),
            fullScreenButton.trailingAnchor.constraint(equalTo: pictureGuide.trailingAnchor, constant: -8),
            fullScreenButton.bottomAnchor.constraint(equalTo: pictureGuide.bottomAnchor, constant: -8),
        ])
        // the toast's layer: pinned to the page, the toast inside it over the buttons (`toastClearance`) and the keyboard,
        // as low as those let it
        let floatSafe = floatLayer.safeAreaLayoutGuide
        toastClearance = toast.bottomAnchor.constraint(lessThanOrEqualTo: floatLayer.bottomAnchor, constant: -16)
        let toastSinks = toast.bottomAnchor.constraint(equalTo: floatLayer.bottomAnchor)
        toastSinks.priority = .defaultLow
        NSLayoutConstraint.activate([
            floatLayer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            floatLayer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            floatLayer.topAnchor.constraint(equalTo: view.topAnchor),
            floatLayer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: floatSafe.centerXAnchor),
            toast.widthAnchor.constraint(lessThanOrEqualTo: floatSafe.widthAnchor, constant: -32),
            toastClearance,
            toast.bottomAnchor.constraint(lessThanOrEqualTo: floatLayer.keyboardLayoutGuide.topAnchor, constant: -16),
            toastSinks,
        ])
        // portrait: the buttons in one row at the bottom, the picture above them; the keyboard covers the bottom of the
        // page (nothing moves: the trackpad above it still works)
        portraitConstraints = [
            leadingButtons.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            trailingButtons.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            leadingButtons.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
            trailingButtons.centerYAnchor.constraint(equalTo: leadingButtons.centerYAnchor),
            trailingButtons.leadingAnchor.constraint(greaterThanOrEqualTo: leadingButtons.trailingAnchor, constant: 10),
            accessNote.bottomAnchor.constraint(equalTo: leadingButtons.topAnchor, constant: -12),
        ]
        // landscape: a column on each side, the picture between them (no keyboard)
        landscapeConstraints = [
            leadingButtons.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            trailingButtons.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            leadingButtons.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            trailingButtons.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            accessNote.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
        ]
        picture.onPictureFrameChange = { [weak self] in self?.view.setNeedsLayout() }
        picture.onTap = { [weak self] zoomed in self?.pictureTapped(zoomed: zoomed) }
        picture.onZoomChange = { [weak self] _ in self?.zoomHint.hide() }
        trackpad.onThreeFingerTap = { [weak self] in self?.toggleStats() }
        trackpad.onTouch = { [weak self] down in if down { self?.hideHint() } }
        session.onKeySent = { [weak self] in self?.hideHint() }
        session.onClipboardChange = { [weak self] hint in self?.clipboardChanged(hint) }
        observation = session.observe { [weak self] update in self?.sessionUpdate(update) }

        // the phone's pasteboard changed in this app (another app's copy shows as the page comes back)
        NotificationCenter.default.addObserver(self, selector: #selector(pasteboardChanged), name: UIPasteboard.changedNotification,
                                               object: nil)
        clipboardChanged(nil)
        render()
        #if DEBUG
        // `-<namespace>InputLog YES` (UI tests): what the page sent the computer, as the kinds in order ("down,move,up")
        if UserDefaults.standard.bool(forKey: YoyoHost.key("InputLog")) {
            let log = UILabel(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            log.isAccessibilityElement = true
            log.accessibilityIdentifier = "screen.debug.inputs"
            view.addSubview(log)
            session.inner.onDelivered = { [weak log] kinds in log?.accessibilityValue = kinds.joined(separator: ",") }
        }
        #endif
    }

    isolated deinit {
        chromeFadeTask?.cancel()
        statsTimer?.invalidate()
    }

    @objc private func pasteboardChanged() { updateClipboardDot() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPage()
    }

    /// Portrait: the picture at the top, full width, the trackpad under it (the badges at its top), the buttons in a
    /// row at the bottom. Landscape (an iPad): the picture and the trackpad between the two columns of buttons. Full
    /// screen: the picture alone, as big as fits the safe area. The keyboard (portrait only) covers the bottom of the
    /// page and moves nothing.
    private func layoutPage() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let wide = bounds.width > bounds.height
        if landscape != wide {
            landscape = wide
            NSLayoutConstraint.deactivate(wide ? portraitConstraints : landscapeConstraints)
            NSLayoutConstraint.activate(wide ? landscapeConstraints : portraitConstraints)
            for stack in [leadingButtons, trailingButtons] { stack.axis = wide ? .vertical : .horizontal }
            // landscape has no keyboard
            keyboard.isEnabled = !wide
            updateChrome()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
            setNeedsStatusBarAppearanceUpdate()
            view.setNeedsLayout()
            view.layoutIfNeeded()  // the buttons where they now go (this runs again, inside)
            return
        }
        let safe = view.safeAreaLayoutGuide.layoutFrame
        // one row of up to seven buttons: on a narrow phone they close up
        let row = (leadingButtons.arrangedSubviews + trailingButtons.arrangedSubviews).filter { !$0.isHidden }
        let rowWidth = row.reduce(0) { $0 + max($1.intrinsicContentSize.width, 44) } + CGFloat(max(row.count - 2, 0)) * 10 + 10 + 32
        let spacing: CGFloat = !wide && rowWidth > safe.width ? 4 : 10
        for stack in [leadingButtons, trailingButtons] where stack.spacing != spacing { stack.spacing = spacing }
        // the toast over the buttons (portrait) or the safe area's bottom (landscape, full screen)
        let floor = wide || fullScreen ? safe.maxY : min(leadingButtons.frame.minY, trailingButtons.frame.minY)
        let clearance = -(bounds.maxY - floor) - 16
        if toastClearance.constant != clearance { toastClearance.constant = clearance }
        var area = safe
        if wide, !fullScreen {
            area.origin.x = leadingButtons.frame.maxX + 8
            area.size.width = trailingButtons.frame.minX - 8 - area.minX
        } else if !wide {
            area.size.height = min(leadingButtons.frame.minY, trailingButtons.frame.minY) - 8 - safe.minY
        }
        let badgeHeight = badges.isHidden ? 0 : badges.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        let padTopInset = badgeHeight > 0 ? badgeHeight + 16 : 0
        let (place, pad) = ScreenPageLayout.layout(area: area, aspect: picture.pictureAspect, padTopInset: padTopInset,
                                                   pad: !fullScreen)
        if picture.frame != bounds { picture.frame = bounds }
        let insets = UIEdgeInsets(top: place.minY, left: place.minX, bottom: bounds.maxY - place.maxY, right: bounds.maxX - place.maxX)
        if picture.contentInsets != insets { picture.contentInsets = insets }
        picture.layoutIfNeeded()
        if let pad, trackpad.frame != pad { trackpad.frame = pad }
        trackpad.topInset = padTopInset
        trackpad.isHidden = pad == nil || !session.canShow
        let shown = picture.convert(picture.pictureFrame, to: view)
        let values = [shown.minX, shown.minY, shown.width, shown.height]
        for (c, v) in zip(pictureGuideConstraints, values) where c.constant != v { c.constant = v }
        // the badges at the top of the trackpad (portrait), else at the top of the picture
        let anchor = pad ?? shown
        if badgesTop.constant != anchor.minY + 8 { badgesTop.constant = anchor.minY + 8 }
        if badgesCenterX.constant != anchor.midX { badgesCenterX.constant = anchor.midX }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        // `-<namespace>FullScreen YES` (screenshots): the page goes full screen (view only, landscape)
        if UserDefaults.standard.bool(forKey: YoyoHost.key("FullScreen")), !fullScreen { setFullScreen(true) }
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        keyboard.hide()
        session.stop(release: true)
    }

    // MARK: The session

    private func sessionUpdate(_ update: YoyoScreenSession.Update) {
        switch update {
        case .changed(let c):
            if c.contains(.computer) { hostChanged() }
            if c.contains(.audio) { updateAudioButton() }
            if c.contains(.activity) { activityChanged() }
            if !c.isDisjoint(with: [.status, .control]) { render() }
        case .notice(let n):
            switch n {
            case .message(let text): notify(text)
            case .tookControl:
                UIImpactFeedbackGenerator(style: .light, view: view).impactOccurred()
                // the first time in control: what the fingers do
                trackpad.showGestureCardOnce(from: self)
            case .lostControl(let loss):
                if case .takenOver = loss { UINotificationFeedbackGenerator(view: pill).notificationOccurred(.warning) }
                if let text = loss.message { notify(text) }
            case .nudge: pill.nudge()
            }
        }
    }

    /// Started (it appeared, or came back from the background): what the phone copied meanwhile; stopped: the hint and
    /// the stats line's ticks go.
    private func activityChanged() {
        updateStatsTimer()
        if session.isActive {
            phoneHintAsked = false
            showPhoneHintIfNew()
            updateClipboardDot()
        } else {
            hideHint()
        }
    }

    func refreshStatus() async { await session.refreshStatus() }

    private func render() {
        let showing = session.canShow
        picture.isHidden = !showing
        if !showing { trackpad.isHidden = true } else if trackpad.isHidden, !fullScreen { view.setNeedsLayout() }
        let state = ScreenControlPolicy.pill(controlling: controlling, canControl: session.canControl, role: session.controlModel.role)
        if let state { pill.set(state) }
        pill.setShown(state != nil)
        badge.isHidden = !showing || state != nil
        badge.set(session.controlModel.isViewer ? .none : status?.controller ?? .none)
        fullScreenButton.isEnabled = showing || fullScreen
        // watching (the page opens so): what takes the screen
        if controlling || !session.canTakeControl { trackpad.hint = nil }
        else if status?.controller == .agent { trackpad.hint = L("The agent is using the screen. Touch to take over.") }
        else if status?.controller == ScreenController.none { trackpad.hint = L("Touch to take control.") }
        else { trackpad.hint = nil }
        // in control, or watching with nobody else's control in the way (the keyboard takes the screen then)
        keyboardButton.isEnabled = controlling || session.canTakeControl
        updateChrome()
        accessNote.isHidden = !(showing && status?.accessibility == false)
        accessNote.text = L("To control the Mac from here, allow Accessibility for Yoyo Control in System Settings on the Mac.")
        updateDisplayMenu()
        setNeedsUpdateContentUnavailableConfiguration()
    }

    private func updateDisplayMenu() {
        let displays = session.displays
        // one display: nothing to pick, no button
        guard session.canShow, displays.count > 1 else {
            displayButton.isHidden = true
            return
        }
        let actions = displays.enumerated().map { i, d in
            UIAction(title: ScreenDisplayMenuText.title(d, index: i), subtitle: ScreenDisplayMenuText.subtitle(d),
                     state: d.id == (session.displayId ?? status?.mainDisplay?.id) ? .on : .off) { [weak self] _ in
                self?.session.selectDisplay(d.id)
            }
        }
        displayButton.menu = UIMenu(title: L("Display"), children: actions)
        displayButton.isHidden = false
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        guard !session.canShow else { contentUnavailableConfiguration = nil; return }
        var c = UIContentUnavailableConfiguration.empty()
        c.textProperties.color = Theme.text
        c.secondaryTextProperties.color = Theme.secondaryText
        if let status {
            if !status.available, let action = status.unavailableAction {
                // the backend knows what to do about it (install or update what serves the screen…): a button for it
                c.image = UIImage(systemName: action.symbol ?? "arrow.down.app")
                c.text = action.headline ?? host.unavailableTitle
                c.secondaryText = action.message ?? status.reason ?? host.unavailableDetail
                var b = UIButton.Configuration.prominentGlass()
                b.title = action.title
                c.button = b
                let url = action.url
                c.buttonProperties.primaryAction = UIAction { _ in UIApplication.shared.open(url) }
            } else if !status.available {
                c.image = UIImage(systemName: "display.trianglebadge.exclamationmark")
                c.text = host.unavailableTitle
                c.secondaryText = status.reason ?? host.unavailableDetail
            } else {
                c.image = UIImage(systemName: "rectangle.dashed.badge.record")
                c.text = L("Screen Recording permission needed")
                c.secondaryText = L("Allow Screen Recording for Yoyo Control in System Settings › Privacy & Security on the Mac. Tap below to show the request there.")
                var b = UIButton.Configuration.prominentGlass()
                b.title = L("Request permissions")
                c.button = b
                c.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.session.requestPermissions() }
            }
        } else if let statusError = session.statusError {
            c.image = UIImage(systemName: "wifi.exclamationmark")
            c.text = L("Couldn’t reach the screen")
            c.secondaryText = (statusError as? LocalizedError)?.errorDescription ?? statusError.localizedDescription
            var b = UIButton.Configuration.gray()
            b.title = L("Retry")
            c.button = b
            c.buttonProperties.primaryAction = UIAction { [weak self] _ in Task { await self?.refreshStatus() } }
        } else {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
            return
        }
        c.imageProperties.tintColor = Theme.tertiaryText
        contentUnavailableConfiguration = c
    }

    // MARK: Control

    /// The pill's button (Take Control / Take Over: explicit, so another phone's control too). In full screen: back to
    /// the page first, then the take.
    private func takeControlTapped() {
        if fullScreen { setFullScreen(false) }
        Task {
            do { try await session.takeControl() } catch {
                if YoyoHost.current.handleError(error) { return }
                notify(ScreenSession.message(error))
            }
        }
    }

    // MARK: Full screen (view only)

    /// Full screen: control goes back, the keyboard goes, the page turns to landscape and shows the picture alone with
    /// its button (faded after a moment). Back: the page turns back to portrait (on a phone), watching (the next real
    /// input takes the screen again).
    private func setFullScreen(_ on: Bool) {
        guard on != fullScreen else { return }
        fullScreen = on
        if on {
            keyboard.hide()
            trackpad.cancelDrag()
        }
        session.viewOnly = on
        updateFullScreenButton()
        render()
        view.setNeedsLayout()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        if let scene = view.window?.windowScene {
            if on {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
            } else if traitCollection.userInterfaceIdiom == .phone {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        UIImpactFeedbackGenerator(style: .light, view: view).impactOccurred()
        showChrome()
    }

    private func updateFullScreenButton() {
        fullScreenButton.symbol = fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        fullScreenButton.accessibilityLabel = fullScreen ? L("Exit full screen") : L("Full screen (view only)")
    }

    /// Which buttons show: full screen, none (the full-screen button is on the picture); landscape, no keyboard.
    private func updateChrome() {
        leadingButtons.isHidden = fullScreen
        trailingButtons.isHidden = fullScreen
        keyboardButton.isHidden = fullScreen || landscape == true
        clipboardButton.isHidden = fullScreen || !clipboardShown
        if fullScreen { hideHint() }
        audioButton.isHidden = fullScreen || !session.hasAudio
    }

    /// The full-screen button (and the badges) show; in full screen they fade after a moment (a tap on the picture
    /// brings them back).
    private func showChrome() {
        chromeFadeTask?.cancel()
        chromeFadeTask = nil
        if fullScreenButton.alpha < 1 || badges.alpha < 1 {
            UIView.animate(withDuration: 0.2) {
                self.fullScreenButton.alpha = 1
                self.badges.alpha = 1
            }
        }
        guard fullScreen, !UIAccessibility.isVoiceOverRunning else { return }
        chromeFadeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.chromeFadeAfter)
            guard !Task.isCancelled, let self, self.fullScreen else { return }
            UIView.animate(withDuration: 0.4) {
                self.fullScreenButton.alpha = 0
                self.badges.alpha = 0
            }
        }
    }

    static let chromeFadeAfter: Duration = .seconds(3)

    /// A tap on the picture: it says what the picture does (pinch to zoom, zoomed: double tap to fit), with a soft tap;
    /// in full screen the button comes back too.
    private func pictureTapped(zoomed: Bool) {
        if fullScreen { showChrome() }
        UIImpactFeedbackGenerator(style: .soft, view: view).impactOccurred(intensity: 0.7)
        zoomHint.show(zoomed ? L("Double-tap to fit") : L("Pinch to zoom"),
                      symbol: zoomed ? "arrow.down.right.and.arrow.up.left" : "plus.magnifyingglass", for: .seconds(1.6))
    }

    // MARK: Sound

    private func toggleAudio() {
        session.setAudioOn(!session.audioOn)
        UIImpactFeedbackGenerator(style: .light, view: view).impactOccurred()
    }

    private func updateAudioButton() {
        audioButton.symbol = session.audioOn ? "speaker.wave.2.fill" : "speaker.slash.fill"
        audioButton.accessibilityLabel = host.soundLabel(on: session.audioOn)
        updateChrome()
    }

    // MARK: Gestures, keys (the tests touch the trackpad and press keys)

    private func showGestureCard() {
        guard presentedViewController == nil, view.window != nil else { return }
        present(YoyoTrackpadView.makeGestureCard(computer: host, showsClipboard: clipboardShown), animated: true)
    }

    /// The first finger came down on the trackpad / the last one lifted.
    func touches(_ down: Bool) { trackpad.touches(down) }

    /// A key from the key bar.
    func sendKey(_ name: String) { session.pressKey(name) }

    // MARK: Clipboard menu, dot and hints

    /// The clipboard resource changed (`hint`: the one the computer's new item calls for): the keys and the button
    /// follow support; a hint over the picture while the page is open.
    private func clipboardChanged(_ hint: ScreenClipboardHint?) {
        let shown = session.hasClipboard
        if !shown { hideHint() }
        if shown != clipboardShown {
            clipboardShown = shown
            updateChrome()
            view.setNeedsLayout()
        }
        if let hint, !fullScreen { showHint(hint) }
        showPhoneHintIfNew()
        updateClipboardDot()
    }

    /// What the phone holds, without reading it.
    private var phoneKind: ClipboardActions.PhoneKind? {
        let b = UIPasteboard.general
        return ClipboardActions.PhoneKind(hasStrings: b.hasStrings, hasURLs: b.hasURLs, hasImages: b.hasImages)
    }

    /// `GET /screen` said another platform than the role's guess: the words follow.
    private func hostChanged() {
        title = host.title
        updateAudioButton()
    }

    private func updateClipboardDot() {
        clipboardButton.showsDot = clipboardShown && session.clipboardMarks.dot(
            phoneCount: UIPasteboard.general.changeCount, phoneKind: phoneKind, mac: session.clipboardStatus?.item?.summary)
    }

    /// Once per visit, when the server's clipboard is known: the phone holds something the page hasn't acted on.
    private func showPhoneHintIfNew() {
        guard !phoneHintAsked, clipboardShown, session.isActive, !fullScreen, session.clipboardStatus?.available != false else { return }
        phoneHintAsked = true
        if let h = ScreenClipboardHint.onAppear(marks: session.clipboardMarks, phoneCount: UIPasteboard.general.changeCount,
                                                phoneKind: phoneKind) {
            showHint(h)
        }
    }

    private func showHint(_ h: ScreenClipboardHint) {
        let text: String?
        let symbol: String
        switch h {
        case .phone(let kind):
            text = ClipboardActions.phoneHint(kind, host: host)
            symbol = ScreenClipboardKey.pasteOnMac.symbol
        case .mac:
            text = session.clipboardStatus?.item.flatMap { ClipboardActions.macHint($0.summary, host: host) }
            symbol = ScreenClipboardKey.copyFromMac.symbol
        }
        guard let text else { return }
        hint = h
        hintPill.show(text, symbol: symbol, for: ScreenClipboardHint.duration)
    }

    private func hideHint() {
        hint = nil
        hintPill.hide()
    }

    /// A tap on the hint does what it says.
    private func hintTapped() {
        guard let h = hint else { return }
        hideHint()
        switch h {
        case .phone: session.clipboardKey(.pasteOnMac)
        case .mac: session.clipboardKey(.copyFromMac)
        }
    }

    /// The clipboard button's menu, as it opens: both sides count as seen (the dot goes).
    private func clipboardMenu() -> [UIMenuElement] {
        let kind = phoneKind
        let mac = session.clipboardStatus
        session.clipboardMarks.sawMenu(phoneCount: UIPasteboard.general.changeCount, mac: mac?.item?.summary)
        updateClipboardDot()
        hideHint()
        func action(_ title: String, _ symbol: String, _ item: ClipboardActions.MenuItem, id: String,
                    _ run: @escaping (YoyoScreenSession) -> Void) -> UIAction {
            UIAction(title: title, subtitle: item.subtitle, image: UIImage(systemName: symbol),
                     identifier: UIAction.Identifier(id), attributes: item.enabled ? [] : .disabled) { [weak self] _ in
                guard let self else { return }
                run(self.session)
            }
        }
        let send = ClipboardActions.sendItem(mac: mac)
        // Photos… / Files… only for a backend that sends files
        let pick = session.backend.sendsClipboardFiles ? [
            action(L("Photos…"), "photo.on.rectangle", send, id: "screen.clipboard.menu.photos") { $0.pickForComputer(.photos) },
            action(L("Files…"), "folder", send, id: "screen.clipboard.menu.files") { $0.pickForComputer(.files) },
        ] : []
        let toMac = UIMenu(title: host.sendTitle, options: .displayInline, children: [
            action(host.pasteLabel, ScreenClipboardKey.pasteOnMac.symbol, ClipboardActions.pasteItem(phone: kind, mac: mac),
                   id: "screen.clipboard.menu.paste") { $0.clipboardKey(.pasteOnMac) },
        ] + pick)
        let fromMac = UIMenu(options: .displayInline, children: [
            action(host.copyLabel, ScreenClipboardKey.copyFromMac.symbol, ClipboardActions.copyItem(mac: mac, host: host),
                   id: "screen.clipboard.menu.copy") { $0.clipboardKey(.copyFromMac) },
            action(L("Open clipboard"), "doc.on.clipboard", ClipboardActions.MenuItem(enabled: true), id: "screen.clipboard.menu.open") {
                $0.openClipboardPage()
            },
        ])
        return [toMac, fromMac]
    }

    // MARK: Stats

    private func toggleStats() {
        statsLabel.isHidden.toggle()
        if !statsLabel.isHidden {
            session.resetStats()
            statsLabel.text = " … "
        }
        updateStatsTimer()
    }

    /// Ticks once a second while the stats line shows on an active page.
    private func updateStatsTimer() {
        guard session.isActive, !statsLabel.isHidden else {
            statsTimer?.invalidate()
            statsTimer = nil
            return
        }
        guard statsTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statsLabel.text = self.session.statsText()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        statsTimer = t
    }
}

extension ScreenViewController: YoyoPageSwipeGate {
    /// A short notice: the host's (`YoyoHost.toast`) or the page's own glass toast.
    func notify(_ text: String) {
        if let toast = YoyoHost.current.toast { toast(text, self) } else { self.toast.show(text) }
    }

    /// The trackpad's touches are its own (those that land on it, and any while a finger is on it), and so are the
    /// picture's (a sideways swipe over the computer's screen felt odd: the page goes only from under the picture);
    /// full screen keeps the page.
    public func pageSwipeShouldReceive(_ touch: UITouch) -> Bool {
        let p = touch.location(in: view)
        let onPad = !trackpad.isHidden && trackpad.frame.contains(p)
        return !fullScreen && !trackpad.isTouched && !onPad && !picture.convert(picture.pictureFrame, to: view).contains(p)
    }

    /// One finger swipes the page off (two on the picture pinch).
    public func pageSwipeShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        pan.numberOfTouches <= 1 && picture.touchCount <= 1
    }
}

/// Where the Screen page puts the picture and the trackpad. Pure.
enum ScreenPageLayout {
    /// The trackpad is at least this tall (the picture narrows to leave it that).
    static let minPadHeight: CGFloat = 160
    /// The picture doesn't narrow below this height for the trackpad (there is none then).
    static let minPictureHeight: CGFloat = 120
    /// Between the picture and the trackpad.
    static let padGap: CGFloat = 12

    /// The picture's frame and the trackpad's (nil: none) for a picture of `aspect` (width / height) in `area`. With
    /// the trackpad (`pad`) the picture is full width at the top when that leaves the trackpad `minPadHeight` (past the
    /// inset), else it narrows to leave it that, centered; it is never shorter than `minPictureHeight` (then there is
    /// no trackpad). Without it, the picture is aspect-fit and centered.
    static func layout(area: CGRect, aspect: CGFloat, padTopInset: CGFloat = 0, pad wantsPad: Bool = true) -> (picture: CGRect, pad: CGRect?) {
        guard area.width > 0, area.height > 0, aspect.isFinite, aspect > 0 else { return (.zero, nil) }
        let fullWidthHeight = floor(area.width / aspect)
        let padRoom = minPadHeight + padTopInset + padGap
        if wantsPad, area.height - fullWidthHeight >= padRoom || area.height - padRoom >= minPictureHeight {
            let fits = area.height - fullWidthHeight >= padRoom
            let height = fits ? fullWidthHeight : area.height - padRoom
            let width = fits ? area.width : min(area.width, floor(height * aspect))
            let picture = CGRect(x: area.minX + floor((area.width - width) / 2), y: area.minY, width: width, height: height)
            let top = picture.maxY + padGap
            let pad = CGRect(x: area.minX + padGap, y: top, width: area.width - 2 * padGap, height: area.maxY - top)
            return (picture, pad)
        }
        return (YoyoScreenPictureView.fit(area: area, aspect: aspect), nil)
    }
}
