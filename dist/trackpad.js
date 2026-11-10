import { Drag, EdgeMove, FingerSmoother, FingerSpeed, HoldToDrag, TapSpotter, TapToDrag, Trackpad, TwoFingerScroll, } from "./gestures.js";
/** A one-finger pan begins past this many points (UIKit's pan hysteresis). */
export const PAN_SLOP = 10;
/** The second tap of a double tap comes within this long (s) of the first's lift. */
export const DOUBLE_TAP_S = 0.35;
/** How far (points) a trackpad finger may go past the surface's edge before it counts as off it. */
export const PAD_SLOP = 6;
/** How long (s) the tap that let go of a locked drag or put the keyboard away keeps its click from going. */
export const SWALLOW_S = 0.6;
const GLIDE_SETTLED = 0.05;
export class TrackpadGestures {
    host;
    now;
    /** Where this page has the pointer (0…1). */
    pointer = { x: 0.5, y: 0.5 };
    drag = new Drag();
    dragKind = "threeFingers";
    dragPoint = { x: 0.5, y: 0.5 };
    tapToDrag = new TapToDrag();
    hold = new HoldToDrag();
    holdTimer = null;
    spotter = new TapSpotter();
    speed = new FingerSpeed();
    smoother = new FingerSmoother();
    twoFinger = new TwoFingerScroll();
    fingers = new Map();
    pan = null;
    lastTranslation = { x: 0, y: 0 };
    rawTranslation = { x: 0, y: 0 };
    glideRaf = 0;
    edgeRaf = 0;
    edgeLast = null;
    lockTimer = null;
    lockTimerFor = null;
    singleTimer = null;
    /** A single tap waiting for a second (its lift time and place). */
    pendingTap = null;
    /** The tap before an armed touch: its click waits until that touch lifts without dragging. */
    heldTapClick = false;
    swallowUntil = null;
    quiet = false;
    quietMoved = false;
    outside = false;
    landed = null;
    liftedAt = null;
    /** Two fingers or more came down in this touch: no loupe until they all lift. */
    multiFinger = false;
    /** A finger is down. */
    fingersDown = false;
    /** Two fingers scroll now. */
    isScrolling = false;
    /** The holdArmed state (the loupe's tint). */
    holdIsArmed = false;
    /** The trackpad's acceleration scale (1). */
    gainScale = 1;
    constructor(host, now = () => performance.now() / 1000) {
        this.host = host;
        this.now = now;
    }
    /** Fingers on the surface now. */
    get count() {
        return this.fingers.size;
    }
    /** The touch now down puts the keyboard away: a tap of it clicks nothing, anything else goes on. */
    quieten() {
        this.quiet = true;
    }
    // ---------------------------------------------------------------- pointer events
    /** A touch pointer went down at `p` (page coordinates). false: not the trackpad's (it landed off the surface). */
    down(id, p, t = this.now()) {
        const pad = this.host.padRect();
        if (this.fingers.size === 0 && (!pad || !inside(pad, p, 0)))
            return false;
        const first = this.fingers.size === 0;
        if (first)
            this.landed = p;
        this.fingers.set(id, { start: p, pos: p });
        this.spotter.down(this.fingers.size, t);
        if (this.fingers.size === 1)
            this.speed.reset(p, t);
        else
            this.speed.reset();
        this.updateOutside();
        if (first)
            this.firstDown(t);
        this.fingerCount(this.fingers.size);
        // another finger: the pan of the old count ends, the new count's starts from here
        if (!first)
            this.endPan(false, t);
        return true;
    }
    /** A touch pointer moved; `samples`: its coalesced positions (oldest first, with their times in seconds). */
    move(id, p, samples = [], t = this.now()) {
        const f = this.fingers.get(id);
        if (!f)
            return;
        f.pos = p;
        this.spotter.moved(Math.hypot(p.x - f.start.x, p.y - f.start.y));
        if (this.fingers.size === 1) {
            this.hold.moved({ x: p.x - f.start.x, y: p.y - f.start.y }, t);
            for (const s of samples.length ? samples : [{ p, t }])
                this.speed.add(s.p, s.t);
        }
        this.updateOutside();
        this.panMoved(t);
    }
    /** A touch pointer lifted (or was cancelled: the browser took it). */
    up(id, p, cancelled = false, t = this.now()) {
        const f = this.fingers.get(id);
        if (!f)
            return;
        f.pos = p;
        this.fingers.delete(id);
        if (cancelled)
            this.spotter.cancel();
        this.updateOutside();
        if (this.fingers.size > 0) {
            if (this.fingers.size === 1)
                this.speed.reset();
            this.endPan(false, t);
            return;
        }
        this.liftedAt = p;
        this.endPan(cancelled, t);
        const tap = this.spotter.allUp(t);
        // a tap then a touch that may drag: its click waited for this touch, which ends as a second tap or as nothing
        const held = this.heldTapClick;
        this.heldTapClick = false;
        this.allUp(t);
        if (held && this.host.controlling && !this.drag.isPressed) {
            this.host.click(tap === 1 ? "doubleClick" : "click", this.syncPointer());
            if (tap === 1)
                return;
        }
        if (tap !== null)
            this.tapped(tap, t);
    }
    /** Every touch is gone without lifting (the page hid, control went): a drag is cancelled. */
    reset() {
        for (const id of [...this.fingers.keys()])
            this.up(id, this.fingers.get(id).pos, true);
        this.emit(this.cancelDrag());
    }
    // ---------------------------------------------------------------- the touch
    firstDown(t) {
        this.fingersDown = true;
        this.multiFinger = false;
        this.tapToDrag.touched(t, this.landed);
        this.armHold(t);
        this.quiet = false;
        this.quietMoved = false;
        if (this.drag.isLocked)
            this.dragStep((d) => d.touched(t));
        this.host.touches(true);
        this.host.loupeChanged();
    }
    allUp(t) {
        this.fingersDown = false;
        this.tapToDrag.lifted();
        this.cancelHold();
        if (this.quiet) {
            this.quiet = false;
            if (!this.quietMoved) {
                this.swallowUntil = t + SWALLOW_S;
                this.host.quietTap();
            }
        }
        if (this.drag.isLocked && this.drag.lockedUntil === null) {
            // touched and lifted without moving: let go where the pointer is; the tap clicks nothing
            this.swallowUntil = t + SWALLOW_S;
            this.dragStep((d) => d.released());
        }
        this.stopEdgeMove();
        this.host.touches(false);
        this.host.loupeChanged();
    }
    tapped(fingers, t) {
        if (!this.host.controlling)
            return;
        if (fingers === 3)
            return this.host.threeFingerTap();
        if (fingers > 3)
            return;
        if (this.swallowUntil !== null && t < this.swallowUntil) {
            this.swallowUntil = null;
            return;
        }
        this.swallowUntil = null;
        if (this.drag.isLocked)
            return this.dragStep((d) => d.released());
        const p = this.syncPointer();
        this.host.tapFeedback(this.host.drawnPointer() ?? this.pointer);
        if (fingers === 2) {
            this.clearSingle(true);
            this.host.click("rightClick", p);
            return;
        }
        this.tapToDrag.tapped(t, this.liftedAt);
        const pending = this.pendingTap;
        if (pending && t - pending.t <= DOUBLE_TAP_S + 0.15) {
            this.clearSingle(false);
            this.host.click("doubleClick", p);
            return;
        }
        this.clearSingle(true);
        this.pendingTap = { t, at: p };
        this.singleTimer = setTimeout(() => this.singleDue(), DOUBLE_TAP_S * 1000);
    }
    /** The single tap's wait ran out: it clicks (unless the touch after it may still drag: then when that lifts). */
    singleDue() {
        this.singleTimer = null;
        if (!this.pendingTap)
            return;
        this.pendingTap = null;
        if (!this.host.controlling)
            return;
        if (this.tapToDrag.armed && this.fingersDown) {
            this.heldTapClick = true;
            return;
        }
        this.host.click("click", this.syncPointer());
    }
    /** `send`: a waiting single tap clicks now (another input comes after it); else it is dropped. */
    clearSingle(send) {
        if (this.singleTimer)
            clearTimeout(this.singleTimer);
        this.singleTimer = null;
        const p = this.pendingTap;
        this.pendingTap = null;
        if (send && p && this.host.controlling)
            this.host.click("click", p.at);
    }
    fingerCount(n) {
        if (n >= 2) {
            this.tapToDrag.disarm();
            this.cancelHold();
            this.multiFinger = true;
            this.host.loupeChanged();
        }
        if (n > 3 && this.drag.isPressed)
            this.emit(this.cancelDrag());
    }
    updateOutside() {
        const pad = this.host.padRect();
        const out = !!pad && [...this.fingers.values()].some((f) => !inside(pad, f.pos, PAD_SLOP));
        if (out === this.outside)
            return;
        this.outside = out;
        if (out)
            this.host.vibrate(12);
        this.host.leftPad(out);
    }
    // ---------------------------------------------------------------- holds
    armHold(t) {
        this.cancelHold();
        if (!this.host.controlling || this.drag.isPressed)
            return;
        this.hold.touched(t);
        const wait = () => {
            const due = this.hold.due;
            if (due === null)
                return;
            const left = due - this.now();
            if (left > 0.002) {
                this.holdTimer = setTimeout(wait, left * 1000);
                return;
            }
            this.holdTimer = null;
            if (!this.host.controlling || !this.fingersDown || this.multiFinger || this.drag.isPressed || !this.hold.check(Math.max(this.now(), due)))
                return;
            this.host.vibrate(8);
            this.holdIsArmed = true;
            this.host.holdArmed(true);
        };
        this.holdTimer = setTimeout(wait, HoldToDrag.DELAY * 1000);
    }
    cancelHold() {
        if (this.holdTimer)
            clearTimeout(this.holdTimer);
        this.holdTimer = null;
        this.hold.cancel();
        if (this.holdIsArmed) {
            this.holdIsArmed = false;
            this.host.holdArmed(false);
        }
    }
    // ---------------------------------------------------------------- pans
    centroid() {
        let x = 0, y = 0;
        for (const f of this.fingers.values()) {
            x += f.pos.x;
            y += f.pos.y;
        }
        const n = Math.max(1, this.fingers.size);
        return { x: x / n, y: y / n };
    }
    panMoved(t) {
        if (!this.host.controlling && this.fingers.size !== 2)
            return;
        const n = this.fingers.size;
        if (n < 1 || n > 3)
            return;
        const c = this.centroid();
        if (!this.pan || this.pan.kind !== n)
            this.pan = { kind: n, origin: c, began: false, last: c, trail: [] };
        const pan = this.pan;
        pan.trail.push({ t, p: c });
        while (pan.trail.length > 2 && t - pan.trail[0].t > 0.1)
            pan.trail.shift();
        const tr = { x: c.x - pan.origin.x, y: c.y - pan.origin.y };
        if (!pan.began) {
            if (Math.hypot(tr.x, tr.y) < (n === 2 ? 4 : PAN_SLOP))
                return;
            pan.began = true;
            this.panBegan(n, tr, t);
        }
        else
            this.panChanged(n, tr, t);
        pan.last = c;
    }
    velocity() {
        const tr = this.pan?.trail ?? [];
        if (tr.length < 2)
            return { x: 0, y: 0 };
        const a = tr[0], b = tr[tr.length - 1];
        const dt = b.t - a.t;
        if (!(dt > 0))
            return { x: 0, y: 0 };
        return { x: (b.p.x - a.p.x) / dt, y: (b.p.y - a.p.y) / dt };
    }
    panBegan(n, tr, t) {
        this.gestureBegan();
        this.spotter.cancel();
        if (n === 1) {
            if (!this.host.controlling)
                return;
            if (this.drag.isLocked && this.dragKind === "tap") {
                this.cancelHold();
                this.dragStep((d) => d.began(this.dragPoint));
                this.host.moveCursor(this.dragPoint);
                this.host.vibrate(6);
            }
            else {
                this.releaseLock();
                this.syncPointer();
                const held = this.hold.take();
                const tapped = this.tapToDrag.take();
                if (held || tapped)
                    this.beginDrag("tap", t);
            }
            this.lastTranslation = { x: 0, y: 0 };
            this.smoother.reset({ x: 0, y: 0 }, t);
            this.smoothPan(tr, t);
        }
        else if (n === 2) {
            this.releaseLock();
            this.isScrolling = true;
            this.emitScroll(this.twoFinger.began(tr, this.host.shownPicture(), this.host.controlling));
        }
        else {
            if (!this.host.controlling)
                return;
            this.stopGlide();
            this.tapToDrag.disarm();
            this.cancelHold();
            if (this.drag.isLocked && this.dragKind === "threeFingers") {
                this.dragStep((d) => d.began(this.dragPoint));
                this.host.vibrate(6);
            }
            else {
                this.releaseLock();
                this.beginDrag("threeFingers", t);
            }
            this.host.moveCursor(this.dragPoint);
            this.lastTranslation = { x: 0, y: 0 };
            this.smoother.reset({ x: 0, y: 0 }, t);
            this.dragged(tr, t, true);
        }
    }
    panChanged(n, tr, t) {
        if (n === 1) {
            if (this.host.controlling)
                this.smoothPan(tr, t);
        }
        else if (n === 2) {
            this.emitScroll(this.twoFinger.changed(tr, this.host.shownPicture(), this.host.controlling));
        }
        else if (this.host.controlling)
            this.dragged(tr, t, true);
    }
    /** The pan of the current finger count ends (`cancelled`: no velocity, a drag is cancelled). */
    endPan(cancelled, t) {
        const pan = this.pan;
        this.pan = null;
        if (!pan?.began)
            return;
        if (pan.kind === 2) {
            this.isScrolling = false;
            this.emitScroll(this.twoFinger.ended(cancelled ? null : this.velocityOf(pan), this.host.shownPicture()));
            return;
        }
        if (cancelled) {
            this.stopGlide();
            if (this.drag.isDragging)
                this.emit(this.cancelDrag());
            return;
        }
        if (pan.kind === 3) {
            if (!this.drag.isDragging)
                return;
            const tr = { x: pan.last.x - pan.origin.x, y: pan.last.y - pan.origin.y };
            this.dragged(tr, t, false);
            this.dragStep((d) => d.ended(this.dragPoint, t));
            return;
        }
        // one finger: a drag locks where it is; a plain move glides the rest of the way
        if (this.drag.isDragging) {
            this.stopGlide();
            this.dragStep((d) => d.ended(this.dragPoint, t));
        }
    }
    velocityOf(pan) {
        const was = this.pan;
        this.pan = pan;
        const v = this.velocity();
        this.pan = was;
        return v;
    }
    emitScroll(step) {
        this.host.scrolling(this.isScrolling ? this.twoFinger.axis : null, step && step.phase !== "ended" ? { x: -step.delta.x, y: -step.delta.y } : null);
        if (step)
            this.host.scroll(step, this.syncPointer());
    }
    gestureBegan() {
        if (!this.quiet || this.quietMoved)
            return;
        this.quietMoved = true;
        this.host.gestureBegan();
    }
    /** The one-finger pan's translation is `raw`: the smoothed one follows it and moves the pointer. */
    smoothPan(raw, t) {
        this.rawTranslation = raw;
        const s = this.smoother.add(raw, t, this.speed.speed);
        const step = { x: s.x - this.lastTranslation.x, y: s.y - this.lastTranslation.y };
        this.lastTranslation = s;
        if (step.x !== 0 || step.y !== 0)
            this.panned(step);
        const behind = Math.hypot(raw.x - s.x, raw.y - s.y) > GLIDE_SETTLED;
        if (behind && !this.glideRaf)
            this.glideRaf = requestAnimationFrame(() => this.glideTick());
        else if (!behind)
            this.stopGlide();
    }
    glideTick() {
        this.glideRaf = 0;
        if (!this.host.controlling || this.drag.isLocked)
            return;
        this.smoothPan(this.rawTranslation, this.now());
    }
    stopGlide() {
        if (this.glideRaf)
            cancelAnimationFrame(this.glideRaf);
        this.glideRaf = 0;
    }
    panned(step) {
        const p = this.movePointer(step, this.speed.speed);
        if (!this.drag.isDragging) {
            this.host.pointerMoved(p);
            return;
        }
        this.dragPoint = p;
        this.dragStep((d) => d.moved(p));
        this.updateEdgeMove();
    }
    /** Three fingers' translation is `raw`: the pointer follows (smoothed unless `smoothed` is false) as a held move. */
    dragged(raw, t, smoothed) {
        if (!this.drag.isDragging)
            return;
        const v = this.velocity() ?? { x: 0, y: 0 };
        const speed = Math.hypot(v.x, v.y);
        const s = smoothed ? this.smoother.add(raw, t, speed) : raw;
        const step = { x: s.x - this.lastTranslation.x, y: s.y - this.lastTranslation.y };
        this.lastTranslation = s;
        if (step.x === 0 && step.y === 0)
            return;
        this.dragPoint = this.movePointer(step, speed);
        this.dragStep((d) => d.moved(this.dragPoint));
        this.updateEdgeMove();
    }
    movePointer(step, speed) {
        const display = this.host.display();
        const gain = Trackpad.gain(speed, display, this.host.shownPicture(), this.gainScale);
        const p = Trackpad.moved(this.pointer, step, display, gain);
        this.pointer = p;
        this.host.moveCursor(p);
        return p;
    }
    /** The pointer where it is drawn now, taken as the trackpad's. */
    syncPointer() {
        const d = this.host.drawnPointer();
        if (d)
            this.pointer = d;
        return this.pointer;
    }
    // ---------------------------------------------------------------- drags
    beginDrag(kind, t) {
        this.dragKind = kind;
        this.cancelHold();
        if (kind === "tap") {
            if (this.heldTapClick)
                this.heldTapClick = false;
            // the tap before it clicks nothing
            if (this.singleTimer)
                clearTimeout(this.singleTimer);
            this.singleTimer = null;
            this.pendingTap = null;
            this.swallowUntil = t + SWALLOW_S;
        }
        const start = this.syncPointer();
        this.dragPoint = start;
        this.dragStep((d) => d.began(start));
        this.host.vibrate(10);
    }
    /** Stops a drag under way (the page goes away, control is gone): what it leaves to do (`up`). */
    cancelDrag() {
        if (!this.drag.isPressed)
            return [];
        const steps = this.drag.cancelled();
        this.host.pressed(false, this.dragPoint);
        this.updateDragTimers();
        this.host.loupeChanged();
        return steps;
    }
    releaseLock() {
        if (this.drag.isLocked)
            this.dragStep((d) => d.released());
    }
    dragStep(change) {
        const was = this.drag.isPressed;
        const steps = change(this.drag);
        if (was !== this.drag.isPressed) {
            this.host.pressed(this.drag.isPressed, this.dragPoint);
            this.host.loupeChanged();
        }
        this.updateDragTimers();
        this.emit(steps);
    }
    emit(steps) {
        for (const s of steps)
            this.host.drag(s);
    }
    updateDragTimers() {
        if (!this.drag.isDragging)
            this.stopEdgeMove();
        const until = this.drag.lockedUntil;
        if (until !== null) {
            if (this.lockTimerFor === until)
                return;
            if (this.lockTimer)
                clearTimeout(this.lockTimer);
            this.lockTimerFor = until;
            this.lockTimer = setTimeout(() => {
                this.lockTimer = null;
                this.lockTimerFor = null;
                this.dragStep((d) => d.expire(Math.max(this.now(), until)));
            }, Math.max(until - this.now(), 0) * 1000);
        }
        else if (this.lockTimer) {
            clearTimeout(this.lockTimer);
            this.lockTimer = null;
            this.lockTimerFor = null;
        }
    }
    // ---------------------------------------------------------------- edge move
    dragFinger() {
        if (this.dragKind === "tap")
            return this.speed.location ?? ([...this.fingers.values()][0]?.pos ?? null);
        return this.fingers.size ? this.centroid() : null;
    }
    updateEdgeMove() {
        if (this.edgeRaf || !this.drag.isDragging || !this.fingersDown)
            return;
        const finger = this.dragFinger();
        const pad = this.host.padRect();
        if (!finger || !pad)
            return;
        const v = EdgeMove.velocity(finger, pad, this.host.shownPicture().width);
        if (v.x === 0 && v.y === 0)
            return;
        this.edgeLast = null;
        this.edgeRaf = requestAnimationFrame((ts) => this.edgeTick(ts));
    }
    edgeTick(ts) {
        this.edgeRaf = 0;
        const finger = this.dragFinger();
        const pad = this.host.padRect();
        if (!this.host.controlling || !this.drag.isDragging || !this.fingersDown || !finger || !pad)
            return;
        const v = EdgeMove.velocity(finger, pad, this.host.shownPicture().width);
        if (v.x === 0 && v.y === 0)
            return;
        const dt = Math.min(Math.max((ts - (this.edgeLast ?? ts - 16.7)) / 1000, 0), 1 / 30);
        this.edgeLast = ts;
        const display = this.host.display();
        const factor = Trackpad.pictureFactor(display, this.host.shownPicture());
        const p = Trackpad.moved(this.pointer, { x: v.x * dt, y: v.y * dt }, display, factor);
        if (p.x === this.pointer.x && p.y === this.pointer.y)
            return;
        this.pointer = p;
        this.host.moveCursor(p);
        this.dragPoint = p;
        this.dragStep((d) => d.moved(p));
        this.edgeRaf = requestAnimationFrame((n) => this.edgeTick(n));
    }
    stopEdgeMove() {
        if (this.edgeRaf)
            cancelAnimationFrame(this.edgeRaf);
        this.edgeRaf = 0;
        this.edgeLast = null;
    }
}
function inside(r, p, slop) {
    return p.x >= r.x - slop && p.x <= r.x + r.width + slop && p.y >= r.y - slop && p.y <= r.y + r.height + slop;
}
