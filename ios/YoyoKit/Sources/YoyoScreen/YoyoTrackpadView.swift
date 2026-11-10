import UIKit
import YoyoClipboard
import YoyoCore

/// A trackpad for a session's computer (`YoyoScreenSession`), drawn as a rounded panel (a hint in the middle, its rim
/// lights up while a finger is off it), driving the pointer of a `YoyoScreenPictureView`. One finger moves the pointer
/// (relative, accelerated over the picture: `ScreenTrackpad.gain`, at the speed the finger's own touches give:
/// `ScreenFingerSpeed`), a tap / double tap clicks where the pointer is, a two-finger tap right-clicks, two fingers
/// scroll there, a touch held still for a moment then moved drags (selects), so does a tap then a touch that moves, and
/// so do three fingers (lifting keeps the button down for a moment, so the drag can go on with another swipe of the
/// same kind: `ScreenDrag`, `ScreenHoldToDrag`, `ScreenTapToDrag`; fingers resting near an edge keep the pointer
/// going: `ScreenEdgeMove`), a three-finger tap is the host's (`onThreeFingerTap`). A touch must land on the panel;
/// more fingers may then come down anywhere in its superview, and a finger that wanders off keeps working but says so
/// (a buzz, the rim lights up, `onLeftPad`). While the fingers work, a liquid drop on the picture magnifies around the
/// pointer (`ScreenDrop`); while a drag holds the button or two fingers scroll, a small glass badge by the pointer says
/// which (`ScreenPointerBadge`).
///
/// The gestures become input only while the session controls the screen (`isControlling`). The first finger down
/// otherwise is a real input that asks for control (`YoyoScreenSession.requestInput`: under `.takeOnInput` it takes
/// the screen; under `.explicit` it only nudges). A finger down puts the session's keyboard away (that touch then taps
/// nothing). Lay it out where it should be; it takes the touches that land on it.
@MainActor
public final class YoyoTrackpadView: UIView, UIGestureRecognizerDelegate {
    public let session: YoyoScreenSession
    public let picture: YoyoScreenPictureView

    /// What the panel says in its middle (nil: nothing).
    public var hint: String? {
        get { surface.hint }
        set { surface.hint = newValue }
    }
    /// Room kept free at the top of the panel (the hint centers below it).
    public var topInset: CGFloat {
        get { surface.topInset }
        set { surface.topInset = newValue }
    }
    /// A finger on the trackpad went off the panel (true) / every finger is back on it (false).
    public var onLeftPad: ((Bool) -> Void)?
    /// A three-finger tap (never input).
    public var onThreeFingerTap: (() -> Void)?
    /// The first finger came down (true) / the last one lifted (false). Any time, controlling or not.
    public var onTouch: ((Bool) -> Void)?
    /// A finger is on the trackpad now.
    public var isTouched: Bool { touchObserver.count > 0 }

    private let surface = ScreenTrackpadSurface()
    private let tap = UITapGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let threeFingerPan = UIPanGestureRecognizer()
    private let twoFingerPan = UIPanGestureRecognizer()
    private let threeFingerTap = UITapGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let trackpadPan = ScreenTrackpadPan()
    private let touchObserver = ScreenTouchObserver()
    private var observation: YoyoScreenObservation?
    /// Whether gestures become input (the session controls the screen).
    private(set) var controlling = false {
        didSet {
            guard controlling != oldValue else { return }
            updateGestures()
            surface.active = controlling
            if !controlling { picture.hideLoupe(animated: true) }
        }
    }
    /// The live drag (a tap then a moving touch, or three fingers) and which of them began it (a lock is carried on
    /// only by the same kind).
    private var drag = ScreenDrag()
    private var dragKind = DragKind.threeFingers
    enum DragKind { case tap, threeFingers }
    /// A tap then a touch: armed while that touch is down (`ScreenTapToDrag`).
    private var tapToDrag = ScreenTapToDrag()
    /// A touch held still: armed after a moment (`ScreenHoldToDrag`), by `holdTask`.
    private var holdToDrag = ScreenHoldToDrag()
    private var holdTask: Task<Void, Never>?
    /// Which tap recognizer answers click (only those for touches the spotter saw as taps).
    private var tapGate = ScreenTapGate()
    /// The tap recognizer's click for the tap before an armed touch, held until that touch lifts without dragging.
    private var heldTapClick = false
    /// The three-finger pan's translation (smoothed) as of its last move, and where its fingers are (their middle, this
    /// view's points; nil: not dragging).
    private var lastDragTranslation: CGPoint = .zero
    private var dragFingers: CGPoint?
    /// The pointer (normalized) the drag is at now.
    private var dragPoint: CGPoint = .zero
    /// Lets go of a locked drag when its window runs out (`ScreenDrag.lockWindow`), and the time it was set for.
    private var lockTask: Task<Void, Never>?
    private var lockTaskFire: TimeInterval?
    /// The tap that let go of a locked drag clicks nothing: the tap recognizers' next answer is dropped until then.
    private var swallowClicksUntil: CFTimeInterval?
    /// This touch puts the keyboard away: unless a pan began in it (it goes on as usual), it clicks nothing however
    /// long it was held, and says so with a soft tap as it lifts. Cleared when the next touch comes down.
    private var quietTap = false
    /// A pan began in the quiet touch.
    private var quietMoved = false
    /// Moves the pointer while dragging fingers rest near an edge (`ScreenEdgeMove`), and its last frame's time.
    private var edgeLink: CADisplayLink?
    private var edgeLast: CFTimeInterval?
    /// The one-finger pan's translation (smoothed) as of its last move, and its latest one as it is.
    private var lastTrackpadTranslation: CGPoint = .zero
    private var trackpadRawTranslation: CGPoint = .zero
    /// Carries the smoothed pan on to the finger, frame by frame, while it trails it and no touch moves it there: the
    /// travel before the pan was recognized, a finger that stopped, one that lifted.
    private var glideLink: CADisplayLink?
    /// The slow finger's tremor taken out of the pans' moves.
    private var fingerSmoother = ScreenFingerSmoother()
    private var twoFingerScroll = ScreenTwoFingerScroll()
    /// A finger is down (the loupe shows while one is).
    private var fingersDown = false
    /// Two fingers or more came down in this touch (a scroll, a right-click, a three-finger drag or tap): no loupe until
    /// they all lift.
    private var multiFingerTouch = false
    /// Two fingers are scrolling now (their axis, once decided, is `twoFingerScroll.axis`).
    private var scrolling = false

    /// How far (points) a trackpad finger may go past the panel's edge before it counts as off it.
    static let padSlop: CGFloat = 6

    public init(session: YoyoScreenSession, picture: YoyoScreenPictureView) {
        self.session = session
        self.picture = picture
        super.init(frame: .zero)
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
        picture.driver = self

        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(doubleTapped(_:)))
        tap.require(toFail: doubleTap)
        tap.addTarget(self, action: #selector(tapped(_:)))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3
        threeFingerPan.addTarget(self, action: #selector(threeFingerPanned(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.addTarget(self, action: #selector(twoFingerPanned(_:)))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.addTarget(self, action: #selector(threeFingerTapped))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.addTarget(self, action: #selector(twoFingerTapped(_:)))
        trackpadPan.minimumNumberOfTouches = 1
        trackpadPan.maximumNumberOfTouches = 1
        trackpadPan.addTarget(self, action: #selector(trackpadPanned(_:)))
        touchObserver.onFirstDown = { [weak self] in self?.fingers(down: true) }
        touchObserver.onAllUp = { [weak self] in self?.fingers(down: false) }
        touchObserver.onTap = { [weak self] fingers in self?.tappedAtOnce(fingers) }
        touchObserver.onOtherTouch = { [weak self] in self?.tapGate.other(at: CACurrentMediaTime()) }
        touchObserver.onFingerMoved = { [weak self] offset in self?.holdToDrag.moved(offset, at: CACurrentMediaTime()) }
        touchObserver.onFingerCount = { [weak self] count in self?.fingerCount(count) }
        touchObserver.area = { [weak self] p in self?.bounds.insetBy(dx: -Self.padSlop, dy: -Self.padSlop).contains(p) ?? true }
        touchObserver.onLeftArea = { [weak self] out in self?.leftPad(out) }
        for g in [tap, doubleTap, threeFingerPan, twoFingerPan, threeFingerTap, twoFingerTap, trackpadPan, touchObserver] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        updateGestures()
        observation = session.observe { [weak self] update in
            guard let self, case let .changed(c) = update else { return }
            if !c.isDisjoint(with: [.control, .status, .activity]) { self.sessionChanged() }
        }
        sessionChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func sessionChanged() {
        controlling = session.isControlling
        // the session stopped: a drag under way ends here (the session lifted its button)
        if !session.isActive { cancelDrag() }
    }

    /// No system three-finger editing gestures (undo swipes, copy pinches): three fingers drag here.
    public override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// A touch must land on the panel (and not while fingers are on the picture); once a finger is on it, any touch
    /// in its superview is the trackpad's (two fingers spread over its edge still scroll).
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if touchObserver.count > 0 { return true }
        return !picture.isTouched && bounds.contains(point)
    }

    /// The one- and two-finger pans begin only with exactly that many fingers down: a pan ignores fingers past its
    /// maximum rather than failing, so three moving fingers would otherwise move the pointer or scroll, and the drag
    /// would never begin.
    public override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === trackpadPan { return touchObserver.count <= 1 }
        if g === twoFingerPan { return touchObserver.count == 2 }
        return super.gestureRecognizerShouldBegin(g)
    }

    /// Stops a drag under way (control is gone) and returns what it leaves to do: `up` when it had pressed the button.
    /// The gesture's own end then does nothing.
    @discardableResult
    func cancelDrag() -> [ScreenDrag.Step] {
        guard drag.isPressed else { return [] }
        let steps = drag.cancelled()
        picture.setPressed(false, at: dragPoint)
        updateDragTimers()
        dragPressedChanged()
        return steps
    }

    // MARK: The session

    /// The first finger came down on the trackpad / the last one lifted. Not in control (opened watching, the agent
    /// drives, the computer let go after a while), the touch asks for control. The keyboard goes at a touch (the whole
    /// trackpad is free again): that touch goes on as a pan, but taps nothing. (Not private: the tests touch it.)
    func touches(_ down: Bool) {
        onTouch?(down)
        guard down else { session.endInteraction(); return }
        session.dropFocusLook()
        if let keyboard = session.keyboard, keyboard.isShown {
            // the touch carries on (a pan moves the pointer, three fingers drag), but as a tap it clicks nothing (a
            // soft haptic says the keyboard went). Before the keyboard goes: that lays the page out, which would bring
            // up the loupe
            quietenTap()
            keyboard.hide()
        }
        guard session.isControlling else {
            // a real input: as the policy says (watching another phone's control: only an explicit take takes it)
            session.requestInput()
            return
        }
        session.beginInteraction()
    }

    private func click(_ kind: ScreenInput.Kind, at p: CGPoint) {
        // the pointer is there now (a client-drawn one moves before the computer answers); the click showed when the
        // finger lifted
        if session.click(kind, at: p) { picture.moveCursor(to: p) }
    }

    /// Two-finger pans become scrolls with their gesture's phases (fractions of the picture → display points, velocity
    /// included); the computer paces them and scrolls on with the velocity at lift.
    private func scroll(_ step: ScreenScrollStep, at p: CGPoint) {
        guard let d = session.currentDisplay else { return }
        let delta = CGVector(dx: step.delta.dx * d.width, dy: step.delta.dy * d.height)
        let velocity = ScreenTwoFingerScroll.capped(CGVector(dx: step.velocity.dx * d.width, dy: step.velocity.dy * d.height))
        // a scroll moves the pointer to where it happens
        if session.scroll(by: delta, at: p, phase: step.phase, velocity: velocity) { picture.moveCursor(to: p) }
    }

    /// A live drag's step: `down` and `up` in order with everything else, the held moves on the merging lane.
    private func dragged(_ step: ScreenDrag.Step) {
        switch step {
        case let .down(p): if session.beginDrag(at: p) { picture.moveCursor(to: p) }
        case let .move(p): if session.moveDrag(to: p) { picture.moveCursor(to: p) }
        case let .up(p): if session.endDrag(at: p) { picture.moveCursor(to: p) }
        }
    }

    // MARK: Off the trackpad

    /// A trackpad finger went off the panel (`out`) or every one is back: a firm buzz going off, the rim lights up
    /// while one is off.
    private func leftPad(_ out: Bool) {
        surface.outside = out
        if out { UIImpactFeedbackGenerator(style: .rigid, view: self).impactOccurred(intensity: 0.8) }
        onLeftPad?(out)
    }

    // MARK: Loupe

    /// Where the loupe looks (normalized): the pointer drawn, else where this phone has it.
    private var loupePoint: CGPoint { picture.currentPointer ?? picture.pointer }

    private func fingers(down: Bool) {
        fingersDown = down
        if down {
            multiFingerTouch = false
            tapToDrag.touched(at: CACurrentMediaTime(), location: touchObserver.landed)
            armHold()
        } else {
            tapToDrag.lifted()
            cancelHold()
            // a tap then a touch that never moved: the tap's click goes now
            if heldTapClick { heldTapClick = false; if !drag.isPressed { click(.click, at: syncPointer()) } }
        }
        if down {
            quietTap = false
            quietMoved = false
        } else if quietTap {
            quietTap = false
            if !quietMoved {
                // the tap recognizers' answer for it is dropped, and `tappedAtOnce` shows no click
                swallowClicksUntil = CACurrentMediaTime() + Self.swallowClicks
                // a tap that only put the keyboard away: a soft tap of its own, no click
                UIImpactFeedbackGenerator(style: .soft, view: self).impactOccurred(intensity: 0.8)
            }
        }
        if drag.isLocked {
            if down {
                // holds the lock open until the fingers move (three carry on with the drag) or lift (they let go)
                dragStep { $0.touched(at: CACurrentMediaTime()) }
            } else if drag.lockedUntil == nil {
                // touched and lifted without moving: let go where the pointer is; the tap clicks nothing
                swallowClicksUntil = CACurrentMediaTime() + Self.swallowClicks
                dragStep { $0.released() }
            }
        }
        if !down { stopEdgeMove() }
        touches(down)
        // it comes with the first finger and goes with the last, at once
        if down { updateLoupe() } else { picture.hideLoupe(animated: true) }
    }

    /// Shows the loupe at the pointer while a finger is down (moves it when it shows already).
    func updateLoupe() {
        let pic = picture.imageView.frame
        guard controlling, pic.width > 0, pic.height > 0 else { picture.hideLoupe(animated: false); return }
        #if DEBUG
        // `-<namespace>Loupe YES` (screenshots): the loupe shows while controlling, fingers or not; `-<namespace>Loupe
        // 0.3,0.2`: with the pointer there
        let pin = UserDefaults.standard.string(forKey: YoyoHost.key("Loupe")) ?? ""
        var pinned = pin == "YES" || pin.contains(",")
        if pin.contains(","), !picture.loupe.visible, coursePoint == nil {
            let xy = pin.split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { picture.pointer = CGPoint(x: xy[0], y: xy[1]) }
        }
        // `-<namespace>LoupePath YES` (recordings): the pointer runs `ScreenDropCourse`, lifting and touching as it says
        if course == nil, UserDefaults.standard.bool(forKey: YoyoHost.key("LoupePath")) { startCourse() }
        if let coursePoint {
            picture.pointer = coursePoint.point
            pinned = coursePoint.down
            if !coursePoint.down { picture.hideLoupe(animated: true); return }
        }
        #else
        let pinned = false
        #endif
        // a drag or a scroll shows its badge instead (two fingers or more: neither, nor the taps, magnifies)
        guard !drag.isPressed, !multiFingerTouch else { picture.hideLoupe(animated: true); return }
        // the touch that puts the keyboard away: no loupe unless it pans (a tap of it only buzzes)
        let quiet = quietTap && !quietMoved
        guard (fingersDown && !quiet) || picture.loupe.visible || pinned else { return }
        let display = picture.trackpadDisplay
        let m = ScreenLoupe.magnification(pictureScale: display.width > 0 ? pic.width / display.width : 1)
        let p = loupePoint
        let wasVisible = picture.loupe.visible
        picture.loupe.aim(at: CGPoint(x: pic.minX + p.x * pic.width, y: pic.minY + p.y * pic.height), picture: pic,
                          magnification: m, radius: ScreenDrop.radius(picture: pic.size))
        if !wasVisible { picture.showLoupe() }
    }

    #if DEBUG
    private var course: CADisplayLink?
    private var courseStart: CFTimeInterval?
    private var coursePoint: (point: CGPoint, down: Bool)?

    private func startCourse() {
        let l = CADisplayLink(target: self, selector: #selector(courseTick(_:)))
        l.add(to: .main, forMode: .common)
        course = l
    }

    @objc private func courseTick(_ l: CADisplayLink) {
        guard window != nil else { l.invalidate(); course = nil; return }
        let start = courseStart ?? l.targetTimestamp
        courseStart = start
        coursePoint = ScreenDropCourse.at((l.targetTimestamp - start).truncatingRemainder(dividingBy: ScreenDropCourse.duration))
        updateLoupe()
    }
    #endif

    // MARK: Pointer badge

    func updatePointerBadge() {
        let b = picture.overlayBounds
        var kind: ScreenPointerBadge.Kind? = drag.isPressed ? .drag : scrolling ? .scroll(twoFingerScroll.axis) : nil
        #if DEBUG
        // `-<namespace>PointerBadge drag|scroll` (screenshots): the badge shows while controlling
        switch UserDefaults.standard.string(forKey: YoyoHost.key("PointerBadge")) {
        case "drag"?: kind = kind ?? .drag
        case "scroll"?: kind = kind ?? .scroll(.vertical)
        default: break
        }
        #endif
        guard controlling, b.width > 0, b.height > 0, let kind else { picture.pointerBadge.show(nil); return }
        // a fixed step below and right of where the pointer points (where a Mac puts the badges on its own): not from
        // the drawn shape, which changes under a scroll (arrow, I-beam, hand) and would make the badge jump
        let p = loupePoint
        picture.pointerBadge.center = CGPoint(x: p.x * b.width + ScreenPointerBadge.offset.x, y: p.y * b.height + ScreenPointerBadge.offset.y)
        picture.pointerBadge.show(kind)
    }

    // MARK: Gestures

    private func updateGestures() {
        if !controlling { emit(cancelDrag()) }
        tap.isEnabled = controlling
        doubleTap.isEnabled = controlling
        threeFingerPan.isEnabled = controlling
        twoFingerPan.isEnabled = controlling
        twoFingerTap.isEnabled = controlling
        trackpadPan.isEnabled = controlling
    }

    /// The touch now down puts the keyboard away: a tap of it clicks nothing, anything else goes on.
    func quietenTap() { quietTap = true }

    /// A pan began: in the quiet touch it goes on as usual (the loupe comes now; the cursor moving is its feedback).
    private func gestureBegan() {
        guard quietTap, !quietMoved else { return }
        quietMoved = true
        updateLoupe()
    }

    /// How long after the tap that let go of a locked drag the tap recognizers' answer for it is dropped (a single tap
    /// is told from a double one about 0.3 s after it lifts).
    static let swallowClicks: CFTimeInterval = 0.6

    /// Changes the drag and sends what it says; the pointer stops looking pressed when the button is let go; the
    /// lock's timer and the edge move follow the phase.
    private func dragStep(_ change: (inout ScreenDrag) -> [ScreenDrag.Step]) {
        let wasPressed = drag.isPressed
        let steps = change(&drag)
        if wasPressed, !drag.isPressed { picture.setPressed(false, at: dragPoint) }
        updateDragTimers()
        if wasPressed != drag.isPressed { dragPressedChanged() }
        emit(steps)
    }

    /// The button went down / up: the drag badge comes / goes, the loupe goes / comes back (a finger still down).
    private func dragPressedChanged() {
        updatePointerBadge()
        updateLoupe()
    }

    private func emit(_ steps: [ScreenDrag.Step]) {
        for step in steps { dragged(step) }
    }

    /// A lock that can run out has a timer for it; nothing else does. Only a drag moves at an edge.
    private func updateDragTimers() {
        if !drag.isDragging { stopEdgeMove() }
        if let until = drag.lockedUntil {
            guard lockTaskFire != until else { return }
            lockTask?.cancel()
            lockTaskFire = until
            let delay = max(until - CACurrentMediaTime(), 0)
            lockTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.lockTask = nil
                self.lockTaskFire = nil
                // a sleep can wake a hair early
                self.dragStep { $0.expire(at: max(CACurrentMediaTime(), until)) }
            }
        } else if lockTask != nil {
            lockTask?.cancel()
            lockTask = nil
            lockTaskFire = nil
        }
    }

    /// The fingers down now: a fourth one lets go of a drag (three fingers come back to a lock one by one, so fewer
    /// can't tell; what they do once they move lets go when it isn't a drag).
    private func fingerCount(_ count: Int) {
        if count >= 2 {
            tapToDrag.disarm()
            cancelHold()
            multiFingerTouch = true
            updateLoupe()
        }
        guard count > 3, drag.isPressed else { return }
        emit(cancelDrag())
    }

    /// One finger came down: once it has rested for `ScreenHoldToDrag.delay` (and come to rest, `ScreenHoldToDrag.due`),
    /// a drag arms (a selection buzz, the loupe turns clay), and moving then drags. Not on a drag that holds the button
    /// already (its lock), nor without control.
    private func armHold() {
        holdTask?.cancel()
        holdTask = nil
        guard controlling, !drag.isPressed else { holdToDrag.cancel(); return }
        holdToDrag.touched(at: CACurrentMediaTime())
        holdTask = Task { [weak self] in
            // the finger shifting on its spot puts the moment off: wait again until it has rested
            while !Task.isCancelled, let due = self?.holdToDrag.due {
                let wait = due - CACurrentMediaTime()
                // a sleep can wake a hair early
                if wait > 0.002 { try? await Task.sleep(for: .seconds(wait)); continue }
                guard let self else { return }
                self.holdTask = nil
                guard self.controlling, self.fingersDown, !self.multiFingerTouch, !self.drag.isPressed,
                      self.holdToDrag.check(at: max(CACurrentMediaTime(), due)) else { return }
                UISelectionFeedbackGenerator(view: self).selectionChanged()
                self.picture.loupe.tinted = true
                return
            }
        }
    }

    /// No hold this touch (it moved, more fingers came, it lifted, a drag began).
    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        holdToDrag.cancel()
        picture.loupe.tinted = false
    }

    /// The touch on a locked drag became something else (a tap, a one-finger move, a scroll): it lets go first.
    private func releaseLock() {
        if drag.isLocked { dragStep { $0.released() } }
    }

    /// Drops the tap recognizers' answer for the tap that let go of a locked drag or put the keyboard away; true = this
    /// one was it.
    private func swallowClick() -> Bool {
        guard let until = swallowClicksUntil else { return false }
        swallowClicksUntil = nil
        return CACurrentMediaTime() < until
    }

    @objc private func threeFingerTapped() { onThreeFingerTap?() }

    /// A tap lifted: its click shows where the pointer is, right away (the click itself goes when the recognizers
    /// have decided between a click and a double click), with a light tap.
    private func tappedAtOnce(_ fingers: Int) {
        let now = CACurrentMediaTime()
        guard controlling, fingers <= 2 else { tapGate.other(at: now); return }
        // the tap that let go of a locked drag or put the keyboard away clicks nothing: no click to show
        if let until = swallowClicksUntil, now < until { tapGate.other(at: now); return }
        tapGate.tapped(fingers: fingers, at: now)
        if fingers == 1 { tapToDrag.tapped(at: now, location: touchObserver.liftedAt) }
        picture.showClick(at: picture.currentPointer ?? picture.pointer)
        UIImpactFeedbackGenerator(style: .light, view: self).impactOccurred(intensity: 0.6)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard controlling else { return }
        if drag.isLocked { dragStep { $0.released() }; return }
        if swallowClick() { return }
        // a touch that moved (the pan doesn't stop the tap recognizers) clicks nothing
        guard tapGate.single(fingers: 1, at: CACurrentMediaTime()) else { return }
        // the touch after it may still drag: the click waits for it to lift
        if tapToDrag.armed, fingersDown { heldTapClick = true; return }
        click(.click, at: syncPointer())
    }

    @objc private func twoFingerTapped(_ g: UITapGestureRecognizer) {
        guard controlling else { return }
        if drag.isLocked { dragStep { $0.released() }; return }
        if swallowClick() { return }
        guard tapGate.single(fingers: 2, at: CACurrentMediaTime()) else { return }
        click(.rightClick, at: syncPointer())
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard controlling else { return }
        if drag.isLocked { dragStep { $0.released() }; return }
        if swallowClick() { return }
        guard tapGate.double(at: CACurrentMediaTime()) else { return }
        click(.doubleClick, at: syncPointer())
    }

    /// The pointer where it is drawn now (the computer's latest, or where this phone put it), taken as the trackpad's.
    @discardableResult
    private func syncPointer() -> CGPoint {
        if let p = picture.currentPointer { picture.pointer = p }
        return picture.pointer
    }

    /// The pointer moved by the finger's `step` (points on the phone) at `speed` (points per second): accelerated over
    /// the picture as it is drawn now.
    private func movePointer(by step: CGPoint, speed: CGFloat) -> CGPoint {
        let size = picture.trackpadDisplay
        let gain = ScreenTrackpad.gain(speed: speed, display: size, picture: picture.shownPicture, scale: Preferences.screenTrackpadGain)
        let p = ScreenTrackpad.moved(picture.pointer, by: CGVector(dx: step.x, dy: step.y), display: size, gain: gain)
        picture.moveCursor(to: p)
        return p
    }

    @objc private func trackpadPanned(_ g: UIPanGestureRecognizer) {
        guard controlling else { return }
        let speed = touchObserver.finger.speed
        switch g.state {
        case .began:
            gestureBegan()
            // a touch that moves is no tap (its tap recognizers' answers click nothing)
            touchObserver.spoil()
            if drag.isLocked, dragKind == .tap {
                // back on a one-finger drag's lock: the same drag goes on, with a light tap to say so
                cancelHold()
                dragStep { $0.began(at: dragPoint) }
                picture.moveCursor(to: dragPoint)
                UIImpactFeedbackGenerator(style: .light, view: self).impactOccurred()
            } else {
                // a finger moving on a three-finger lock lets go of it first; it moves the pointer from where it is drawn
                releaseLock()
                syncPointer()
                // held still first, or right after a tap: it drags; else it only moves the pointer
                let held = holdToDrag.take()
                let tapped = tapToDrag.take()
                if held || tapped { beginDrag(.tap) }
            }
            // the travel before the pan was recognized moves the pointer too, gliding in from where the finger landed
            // rather than in one jump
            lastTrackpadTranslation = .zero
            fingerSmoother.reset(at: .zero, time: CACurrentMediaTime())
            smoothPan(to: g.translation(in: self), speed: speed)
        case .changed:
            smoothPan(to: g.translation(in: self), speed: speed)
        case .ended:
            // a drag locks where it is; a plain move glides the rest of the way
            if drag.isDragging { stopGlide(); dragStep { $0.ended(at: dragPoint, now: CACurrentMediaTime()) } }
        case .cancelled, .failed:
            stopGlide()
            if drag.isDragging { emit(cancelDrag()) }
        default:
            break
        }
    }

    /// A drag of `kind` begins at the pointer: `down` there, the pointer looks pressed, a firm tap to say so. The tap
    /// before a tap's drag clicks nothing.
    private func beginDrag(_ kind: DragKind) {
        dragKind = kind
        cancelHold()
        tapGate.drop()
        if kind == .tap {
            // its click held already, or still to come from the tap recognizer: dropped either way
            if heldTapClick { heldTapClick = false } else { swallowClicksUntil = CACurrentMediaTime() + Self.swallowClicks }
        }
        let start = syncPointer()
        dragPoint = start
        dragStep { $0.began(at: start) }
        picture.setPressed(true, at: start)
        UIImpactFeedbackGenerator(style: .medium, view: self).impactOccurred()
    }

    /// The pan's translation is `raw` now: the smoothed one follows it (`ScreenFingerSmoother`) and moves the pointer.
    private func smoothPan(to raw: CGPoint, speed: CGFloat) {
        trackpadRawTranslation = raw
        let t = fingerSmoother.add(raw, at: CACurrentMediaTime(), speed: speed)
        let step = CGPoint(x: t.x - lastTrackpadTranslation.x, y: t.y - lastTrackpadTranslation.y)
        lastTrackpadTranslation = t
        if step != .zero { panned(by: step, speed: speed) }
        let behind = hypot(raw.x - t.x, raw.y - t.y) > Self.glideSettled
        if behind, glideLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(glideTick))
            link.add(to: .main, forMode: .common)
            glideLink = link
        } else if !behind {
            stopGlide()
        }
    }

    /// The smoothed pan is this close (phone points) to the finger: done gliding.
    static let glideSettled: CGFloat = 0.05

    @objc private func glideTick() {
        guard window != nil, controlling, !drag.isLocked else { stopGlide(); return }
        smoothPan(to: trackpadRawTranslation, speed: touchObserver.finger.speed)
    }

    private func stopGlide() {
        glideLink?.invalidate()
        glideLink = nil
    }

    /// One finger's pan moved by `step`: a held move when it drags, else the pointer.
    private func panned(by step: CGPoint, speed: CGFloat) {
        let p = movePointer(by: step, speed: speed)
        guard drag.isDragging else { session.movePointer(to: p); return }
        dragPoint = p
        dragStep { $0.moved(to: p) }
        updateEdgeMove()
    }

    /// Three fingers drag: `down` where the pointer is once they move (or the locked drag goes on), held moves as they
    /// go (relative and accelerated like one finger, at the pan's own speed: the touch observer follows one finger
    /// only), the lock when they lift.
    @objc private func threeFingerPanned(_ g: UIPanGestureRecognizer) {
        guard controlling else { return }
        let v = g.velocity(in: self)
        let speed = hypot(v.x, v.y)
        switch g.state {
        case .began:
            gestureBegan()
            stopGlide()
            tapToDrag.disarm()
            cancelHold()
            if drag.isLocked, dragKind == .threeFingers {
                // back on a locked drag: the same drag goes on, with a light tap to say so
                dragStep { $0.began(at: dragPoint) }
                UIImpactFeedbackGenerator(style: .light, view: self).impactOccurred()
            } else {
                releaseLock()
                beginDrag(.threeFingers)
            }
            picture.moveCursor(to: dragPoint)
            // the travel before the pan was recognized moves the pointer too
            lastDragTranslation = .zero
            fingerSmoother.reset(at: .zero, time: CACurrentMediaTime())
            threeFingersMoved(to: g.translation(in: self), at: g.location(in: self), speed: speed, smoothed: true)
        case .changed:
            threeFingersMoved(to: g.translation(in: self), at: g.location(in: self), speed: speed, smoothed: true)
        case .ended:
            defer { dragFingers = nil }
            guard drag.isDragging else { return }
            // the rest of the way to where the fingers lifted, then the lock
            threeFingersMoved(to: g.translation(in: self), at: g.location(in: self), speed: speed, smoothed: false)
            dragStep { $0.ended(at: dragPoint, now: CACurrentMediaTime()) }
        case .cancelled, .failed:
            dragFingers = nil
            emit(cancelDrag())
        default:
            return
        }
    }

    /// The three-finger pan's translation is `raw` now (its fingers' middle at `fingers`): the pointer follows the
    /// smoothed translation (`smoothed` false: all the way) as a held move.
    private func threeFingersMoved(to raw: CGPoint, at fingers: CGPoint, speed: CGFloat, smoothed: Bool) {
        guard drag.isDragging else { return }
        dragFingers = fingers
        let t = smoothed ? fingerSmoother.add(raw, at: CACurrentMediaTime(), speed: speed) : raw
        let step = CGPoint(x: t.x - lastDragTranslation.x, y: t.y - lastDragTranslation.y)
        lastDragTranslation = t
        guard step != .zero else { return }
        dragPoint = movePointer(by: step, speed: speed)
        dragStep { $0.moved(to: dragPoint) }
        updateEdgeMove()
    }

    // MARK: Edge move

    /// Where the dragging fingers are (this view's points): the one finger of a tap's drag, the three's middle.
    private var dragFingerLocation: CGPoint? {
        dragKind == .tap ? touchObserver.finger.location : dragFingers
    }

    /// While dragging with the fingers near an edge of the panel, the pointer keeps going that way (`ScreenEdgeMove`),
    /// frame by frame, until the fingers leave the band, lift, or the pointer reaches the display's edge.
    private func updateEdgeMove() {
        guard edgeLink == nil, drag.isDragging, fingersDown, let finger = dragFingerLocation,
              ScreenEdgeMove.velocity(finger: finger, bounds: bounds, pictureWidth: picture.shownPicture.width) != .zero
        else { return }
        let link = CADisplayLink(target: self, selector: #selector(edgeTick(_:)))
        link.add(to: .main, forMode: .common)
        edgeLink = link
        edgeLast = nil
    }

    private func stopEdgeMove() {
        edgeLink?.invalidate()
        edgeLink = nil
        edgeLast = nil
    }

    @objc private func edgeTick(_ link: CADisplayLink) {
        guard window != nil, controlling, drag.isDragging, fingersDown, let finger = dragFingerLocation else {
            stopEdgeMove()
            return
        }
        let v = ScreenEdgeMove.velocity(finger: finger, bounds: bounds, pictureWidth: picture.shownPicture.width)
        guard v != .zero else { stopEdgeMove(); return }
        // one frame's worth (a stall doesn't make it jump)
        let dt = min(max(link.targetTimestamp - (edgeLast ?? link.timestamp), 0), 1.0 / 30)
        edgeLast = link.targetTimestamp
        let size = picture.trackpadDisplay
        let factor = ScreenTrackpad.pictureFactor(display: size, picture: picture.shownPicture)
        let p = ScreenTrackpad.moved(picture.pointer, by: CGVector(dx: v.dx * dt, dy: v.dy * dt), display: size, gain: factor)
        // at the display's edge on every axis it pushes: nothing more to do
        guard p != picture.pointer else { stopEdgeMove(); return }
        picture.moveCursor(to: p)
        dragPoint = p
        dragStep { $0.moved(to: p) }
    }

    @objc private func twoFingerPanned(_ g: UIPanGestureRecognizer) {
        // at the picture's scale: the content moves with the fingers
        let size = picture.imageView.bounds.size
        let step: ScreenScrollStep?
        switch g.state {
        case .began:
            gestureBegan()
            // a scroll on a locked drag lets go of it first
            releaseLock()
            step = twoFingerScroll.began(translation: g.translation(in: self), size: size, reporting: controlling)
            scrolling = true
        case .changed:
            step = twoFingerScroll.changed(translation: g.translation(in: self), size: size, reporting: controlling)
        case .ended:
            step = twoFingerScroll.ended(velocity: g.velocity(in: self), size: size)
            scrolling = false
        case .cancelled, .failed:
            step = twoFingerScroll.ended(velocity: nil, size: size)
            scrolling = false
        default:
            return
        }
        // the badge shows the axis once decided, its arrows leaning the way the fingers go
        updatePointerBadge()
        if scrolling, let step, step.delta != .zero { picture.pointerBadge.lean(CGVector(dx: -step.delta.dx, dy: -step.delta.dy)) }
        if let step { scroll(step, at: syncPointer()) }
    }

    // MARK: Gesture card

    /// What the fingers do here (and, when the computer has one, the clipboard's moves): a sheet to present.
    public static func makeGestureCard(computer: YoyoComputer = .mac, showsClipboard: Bool = true) -> UIViewController {
        ScreenGestureCardController(showsClipboard: showsClipboard, host: computer)
    }

    /// The gesture card over `presenter`, unless it was seen already on this phone (kept in
    /// `<namespace>GestureCard2Shown`); then it counts as seen.
    public func showGestureCardOnce(from presenter: UIViewController) {
        var hints = Preferences.screenGestureHints
        guard hints.take() else { return }
        Preferences.screenGestureHints = hints
        guard presenter.presentedViewController == nil, presenter.view.window != nil else { return }
        presenter.present(Self.makeGestureCard(computer: session.computer, showsClipboard: session.hasClipboard), animated: true)
    }
}
