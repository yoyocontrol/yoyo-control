const hypot = Math.hypot;
const clamp01 = (v) => Math.min(Math.max(v, 0), 1);
/**
 * A live drag (iOS `ScreenDrag`). Lifting the fingers mid-drag doesn't let go at once (a Mac trackpad's drag lock): the
 * button stays down for `LOCK_WINDOW`. The same kind of touch that comes back within it and moves carries on with the
 * same drag; anything else lets go first; no touch at all lets go when the window runs out. Fingers resting on the
 * glass hold the window open until they move or lift. Interrupted: `up` where the pointer was.
 */
export class Drag {
    /** How long (s) the button stays down after the fingers lift mid-drag. */
    static LOCK_WINDOW = 0.8;
    phase = { t: "idle" };
    get isPressed() {
        return this.phase.t !== "idle";
    }
    get isDragging() {
        return this.phase.t === "dragging";
    }
    get isLocked() {
        return this.phase.t === "locked";
    }
    /** When a lock runs out (null: not locked, or held open by resting fingers). */
    get lockedUntil() {
        return this.phase.t === "locked" ? this.phase.until : null;
    }
    /** The drag's touch began to move with the pointer at `point`: `down` there (a locked drag carries on instead). */
    began(point) {
        if (this.phase.t === "locked") {
            this.phase = { t: "dragging", at: this.phase.at };
            return [];
        }
        const lifted = this.cancelled();
        this.phase = { t: "dragging", at: point };
        return [...lifted, { t: "down", at: point }];
    }
    moved(point) {
        if (!this.isDragging)
            return [];
        this.phase = { t: "dragging", at: point };
        return [{ t: "move", at: point }];
    }
    /** The fingers lifted at `now`: the drag locks (nothing sent). */
    ended(point, now) {
        if (!this.isDragging)
            return [];
        this.phase = { t: "locked", at: point, until: now + Drag.LOCK_WINDOW };
        return [];
    }
    /** A finger came down at `now`: on an open lock it holds it; on one that ran out it lets go. */
    touched(now) {
        const p = this.phase;
        if (p.t !== "locked")
            return [];
        if (p.until !== null && now >= p.until) {
            this.phase = { t: "idle" };
            return [{ t: "up", at: p.at }];
        }
        this.phase = { t: "locked", at: p.at, until: null };
        return [];
    }
    /** Something other than the drag's kind of move came of the touch on a lock: it lets go. */
    released() {
        const p = this.phase;
        if (p.t !== "locked")
            return [];
        this.phase = { t: "idle" };
        return [{ t: "up", at: p.at }];
    }
    /** A lock that ran out with no finger on the glass lets go. */
    expire(now) {
        const p = this.phase;
        if (p.t !== "locked" || p.until === null || now < p.until)
            return [];
        this.phase = { t: "idle" };
        return [{ t: "up", at: p.at }];
    }
    /** Interrupted: a pressed button is lifted where the pointer was. */
    cancelled() {
        const p = this.phase;
        this.phase = { t: "idle" };
        return p.t === "idle" ? [] : [{ t: "up", at: p.at }];
    }
}
/** A tap, then a touch within `WINDOW` and `REACH` of it: armed while that touch is down; if it moves it drags. */
export class TapToDrag {
    static WINDOW = 0.3;
    static REACH = 44;
    tapUp = null;
    tapAt = null;
    armed = false;
    tapped(time, location = null) {
        this.tapUp = time;
        this.tapAt = location;
    }
    touched(time, location = null) {
        let near = true;
        if (this.tapAt && location)
            near = hypot(location.x - this.tapAt.x, location.y - this.tapAt.y) <= TapToDrag.REACH;
        this.armed = near && this.tapUp !== null && time >= this.tapUp && time - this.tapUp <= TapToDrag.WINDOW;
        this.tapUp = null;
        this.tapAt = null;
    }
    /** The touch moves: true = it drags (once). */
    take() {
        const a = this.armed;
        this.armed = false;
        return a;
    }
    disarm() {
        this.armed = false;
    }
    lifted() {
        this.armed = false;
    }
}
/**
 * One finger down and come to rest for `DELAY`: armed; if it then moves it drags. Resting = it never rolled more than
 * `STILLNESS` from where it landed, and kept within `REST_RADIUS` of one spot for the last `REST_TIME`.
 */
export class HoldToDrag {
    static DELAY = 0.5;
    static STILLNESS = 6;
    static REST_RADIUS = 1.5;
    static REST_TIME = 0.25;
    downAt = null;
    armed = false;
    rest = { x: 0, y: 0 };
    restSince = 0;
    touched(time) {
        this.downAt = time;
        this.armed = false;
        this.rest = { x: 0, y: 0 };
        this.restSince = time;
    }
    /** The finger is `offset` from where it landed at `time`. */
    moved(offset, time) {
        if (this.armed || this.downAt === null)
            return;
        if (!(hypot(offset.x, offset.y) <= HoldToDrag.STILLNESS)) {
            this.downAt = null;
            return;
        }
        if (!(hypot(offset.x - this.rest.x, offset.y - this.rest.y) <= HoldToDrag.REST_RADIUS)) {
            this.rest = offset;
            this.restSince = time;
        }
    }
    /** When it may arm if the finger stays (null: not in this touch, or armed already). */
    get due() {
        if (this.armed || this.downAt === null)
            return null;
        return Math.max(this.downAt + HoldToDrag.DELAY, this.restSince + HoldToDrag.REST_TIME);
    }
    check(now) {
        const due = this.due;
        if (due === null || now < due)
            return false;
        this.armed = true;
        return true;
    }
    take() {
        const a = this.armed;
        this.downAt = null;
        this.armed = false;
        return a;
    }
    cancel() {
        this.downAt = null;
        this.armed = false;
    }
}
// ---------------------------------------------------------------- the trackpad's pointer
/**
 * Relative moves accelerated like a Mac's trackpad, relative to the picture: at a normal speed the pointer covers as much
 * of the picture as the finger covers of the trackpad, so a full swipe crosses the display however small it is drawn.
 */
export const Trackpad = {
    PRECISE_SPEED: 25,
    NORMAL_SPEED: 150,
    FAST_SPEED: 1400,
    PRECISE_GAIN: 0.55,
    FAST_GAIN: 2.6,
    /** Picture points per trackpad point at `speed` (points per second). */
    curve(speed) {
        if (!Number.isFinite(speed) || speed <= Trackpad.PRECISE_SPEED)
            return Trackpad.PRECISE_GAIN;
        if (speed >= Trackpad.FAST_SPEED)
            return Trackpad.FAST_GAIN;
        const rise = Math.pow(smoothstep(logPosition(speed)), RISE_POWER);
        return Trackpad.PRECISE_GAIN + (Trackpad.FAST_GAIN - Trackpad.PRECISE_GAIN) * rise;
    },
    /** Display points per picture point (1 when either is unknown). */
    pictureFactor(display, picture) {
        if (!(display.width > 0) || !(picture.width > 0) || !Number.isFinite(display.width) || !Number.isFinite(picture.width))
            return 1;
        return display.width / picture.width;
    },
    gain(speed, display, picture, scale = 1) {
        const s = Number.isFinite(scale) && scale > 0 ? scale : 1;
        return Trackpad.curve(speed) * Trackpad.pictureFactor(display, picture) * s;
    },
    /** The pointer `p` (0…1) moved by the finger's `finger` (trackpad points) on a display of `display` points. */
    moved(p, finger, display, gain) {
        if (!(display.width > 0) || !(display.height > 0) || !Number.isFinite(gain))
            return Trackpad.clamp(p);
        return Trackpad.clamp({ x: p.x + (finger.x * gain) / display.width, y: p.y + (finger.y * gain) / display.height });
    },
    clamp(p) {
        return { x: clamp01(Number.isFinite(p.x) ? p.x : 0.5), y: clamp01(Number.isFinite(p.y) ? p.y : 0.5) };
    },
};
function smoothstep(t) {
    return t * t * (3 - 2 * t);
}
function logPosition(speed) {
    return clamp01(Math.log(speed / Trackpad.PRECISE_SPEED) / Math.log(Trackpad.FAST_SPEED / Trackpad.PRECISE_SPEED));
}
/** The rise's power so it passes through 1 at the normal speed (about 1.74). */
const RISE_POWER = Math.log((1 - Trackpad.PRECISE_GAIN) / (Trackpad.FAST_GAIN - Trackpad.PRECISE_GAIN)) / Math.log(smoothstep(logPosition(Trackpad.NORMAL_SPEED)));
/** The finger's speed from its own (coalesced) samples: the path over the last `WINDOW` divided by the time. */
export class FingerSpeed {
    static WINDOW = 0.04;
    static MIN_SPAN = 0.012;
    samples = [];
    speed = 0;
    get location() {
        return this.samples.length ? this.samples[this.samples.length - 1].location : null;
    }
    reset(location = null, time = 0) {
        this.samples = location ? [{ time, location }] : [];
        this.speed = 0;
    }
    add(location, time) {
        if (!Number.isFinite(location.x) || !Number.isFinite(location.y) || !Number.isFinite(time))
            return;
        const last = this.samples[this.samples.length - 1];
        if (last && time < last.time)
            return;
        this.samples.push({ time, location });
        const start = time - FingerSpeed.WINDOW;
        const firstInside = this.samples.findIndex((s) => s.time > start);
        if (firstInside > 1)
            this.samples.splice(0, firstInside - 1);
        this.speed = FingerSpeed.speedOf(this.samples, FingerSpeed.WINDOW);
    }
    static speedOf(samples, window) {
        const newest = samples[samples.length - 1];
        if (!newest || samples.length < 2)
            return 0;
        const start = newest.time - window;
        let path = 0;
        let from = newest.time;
        for (let i = 1; i < samples.length; i++) {
            const a = samples[i - 1], b = samples[i];
            if (!(b.time > start))
                continue;
            const piece = hypot(b.location.x - a.location.x, b.location.y - a.location.y);
            const dt = b.time - a.time;
            if (a.time < start && dt > 0) {
                path += (piece * (b.time - start)) / dt;
                from = start;
            }
            else {
                path += piece;
                from = Math.min(from, a.time);
            }
        }
        const v = path / Math.max(newest.time - from, FingerSpeed.MIN_SPAN);
        return Number.isFinite(v) ? v : 0;
    }
}
/** A "1€ filter" for a slow finger's tremor: a low-pass whose cutoff rises with the speed. */
export class FingerSmoother {
    static REST_CUTOFF = 3;
    static CUTOFF_PER_SPEED = 0.06;
    static get MAX_LAG() {
        return 1 / (2 * Math.PI * FingerSmoother.CUTOFF_PER_SPEED);
    }
    location = null;
    time = 0;
    reset(location, time) {
        this.location = location;
        this.time = time;
    }
    add(p, time, speed) {
        if (!Number.isFinite(p.x) || !Number.isFinite(p.y) || !Number.isFinite(time))
            return this.location ?? { x: 0, y: 0 };
        const last = this.location;
        if (!last) {
            this.reset(p, time);
            return p;
        }
        const dt = time - this.time;
        if (!(dt > 0))
            return last;
        const v = Number.isFinite(speed) ? Math.max(speed, 0) : 0;
        const tau = 1 / (2 * Math.PI * (FingerSmoother.REST_CUTOFF + FingerSmoother.CUTOFF_PER_SPEED * v));
        const a = dt / (dt + tau);
        const next = { x: last.x + a * (p.x - last.x), y: last.y + a * (p.y - last.y) };
        this.reset(next, time);
        return next;
    }
}
/** While dragging, a finger near the trackpad's edge keeps the pointer going that way. */
export const EdgeMove = {
    BAND: 36,
    MAX_RATE: 1.2,
    /** Velocity (trackpad points per second over the picture) for a finger at `finger` in `bounds`. */
    velocity(finger, bounds, pictureWidth) {
        const band = EdgeMove.BAND;
        if (!Number.isFinite(finger.x) || !Number.isFinite(finger.y) || !(pictureWidth > 0) || bounds.width <= 2 * band || bounds.height <= 2 * band)
            return { x: 0, y: 0 };
        const top = EdgeMove.MAX_RATE * pictureWidth;
        const depth = (d) => clamp01((band - d) / band);
        const axis = (v, lo, hi) => (v < lo + band ? -top * depth(v - lo) : v > hi - band ? top * depth(hi - v) : 0);
        return { x: axis(finger.x, bounds.x, bounds.x + bounds.width), y: axis(finger.y, bounds.y, bounds.y + bounds.height) };
    },
};
/** The loupe over the pointer: how big, how much it magnifies, how it moves. */
export const Loupe = {
    TARGET_SCALE: 0.45,
    MIN_MAGNIFICATION: 1.6,
    MAX_MAGNIFICATION: 4,
    follow: { response: 0.11, dampingRatio: 0.72 },
    appear: { response: 0.3, dampingRatio: 0.58 },
    disappear: { response: 0.2, dampingRatio: 1 },
    magnification(pictureScale) {
        if (!Number.isFinite(pictureScale) || pictureScale <= 0)
            return Loupe.MIN_MAGNIFICATION;
        return Math.min(Math.max(Loupe.TARGET_SCALE / pictureScale, Loupe.MIN_MAGNIFICATION), Loupe.MAX_MAGNIFICATION);
    },
    /** Its diameter over a picture: half the picture's short side, 100…150. */
    diameter(picture) {
        return Math.min(Math.max(Math.min(picture.width, picture.height) * 0.5, 100), 150);
    },
};
/** A damped spring (Apple's response / damping ratio, unit mass); retargets keep the velocity. */
export class Spring {
    value;
    velocity = 0;
    target;
    constructor(value) {
        this.value = value;
        this.target = value;
    }
    settled(epsilon = 0.001) {
        return Math.abs(this.target - this.value) < epsilon && Math.abs(this.velocity) < epsilon * 10;
    }
    /** Advances `dt` seconds in sub-steps of at most 1/480 s. */
    step(dt, p) {
        if (!(dt > 0) || !Number.isFinite(dt))
            return;
        const r = Math.max(p.response, 0.01);
        const k = Math.pow((2 * Math.PI) / r, 2);
        const c = (4 * Math.PI * p.dampingRatio) / r;
        const n = Math.max(1, Math.ceil(dt * 480));
        const h = dt / n;
        for (let i = 0; i < n; i++) {
            this.velocity += (k * (this.target - this.value) - c * this.velocity) * h;
            this.value += this.velocity * h;
        }
    }
}
/** A two-finger pan as scroll steps, with UIScrollView's directional lock (iOS `ScreenTwoFingerScroll`). */
export class TwoFingerScroll {
    static LOCK_DISTANCE = 8;
    static LOCK_RATIO = 2;
    static MAX_LIFT_SPEED = 6000;
    last = { x: 0, y: 0 };
    active = false;
    axis = null;
    began(t, size, reporting) {
        this.last = { x: 0, y: 0 };
        this.active = false;
        this.axis = null;
        return this.changed(t, size, reporting);
    }
    changed(t, size, reporting) {
        if (this.axis === null && hypot(t.x, t.y) >= TwoFingerScroll.LOCK_DISTANCE)
            this.axis = TwoFingerScroll.axisFor(t);
        if (this.axis === null)
            return null;
        const step = TwoFingerScroll.locked({ x: t.x - this.last.x, y: t.y - this.last.y }, this.axis);
        this.last = t;
        if (!reporting || !(size.width > 0) || !(size.height > 0))
            return null;
        const phase = this.active ? "changed" : "began";
        this.active = true;
        return { delta: { x: -step.x / size.width, y: -step.y / size.height }, phase, velocity: { x: 0, y: 0 } };
    }
    /** The fingers lifted (`v` in points per second) or the gesture was cancelled (null). */
    ended(v, size) {
        const active = this.active, axis = this.axis;
        this.active = false;
        this.last = { x: 0, y: 0 };
        this.axis = null;
        if (!active)
            return null;
        if (!v || !(size.width > 0) || !(size.height > 0) || !Number.isFinite(v.x) || !Number.isFinite(v.y))
            return { delta: { x: 0, y: 0 }, phase: "ended", velocity: { x: 0, y: 0 } };
        const l = TwoFingerScroll.locked(v, axis);
        return { delta: { x: 0, y: 0 }, phase: "ended", velocity: { x: -l.x / size.width, y: -l.y / size.height } };
    }
    static axisFor(t) {
        const ax = Math.abs(t.x), ay = Math.abs(t.y);
        if (ay >= TwoFingerScroll.LOCK_RATIO * ax)
            return "vertical";
        if (ax >= TwoFingerScroll.LOCK_RATIO * ay)
            return "horizontal";
        return "both";
    }
    static locked(v, axis) {
        if (axis === "vertical")
            return { x: 0, y: v.y };
        if (axis === "horizontal")
            return { x: v.x, y: 0 };
        return v;
    }
    /** A velocity at lift (display points per second) kept under MAX_LIFT_SPEED, its direction unchanged. */
    static capped(v) {
        if (!Number.isFinite(v.x) || !Number.isFinite(v.y))
            return { x: 0, y: 0 };
        const speed = hypot(v.x, v.y);
        if (speed <= TwoFingerScroll.MAX_LIFT_SPEED)
            return v;
        const k = TwoFingerScroll.MAX_LIFT_SPEED / speed;
        return { x: v.x * k, y: v.y * k };
    }
}
/** Tells a tap from the touches alone, the moment the last finger lifts: quick, still, and how many fingers. */
export class TapSpotter {
    static MAX_DURATION = HoldToDrag.DELAY;
    static SLOP = 10;
    start = null;
    fingers = 0;
    spoiled = false;
    down(count, time) {
        if (this.start === null) {
            this.start = time;
            this.spoiled = false;
            this.fingers = 0;
        }
        this.fingers = Math.max(this.fingers, count);
    }
    moved(distance) {
        if (!(distance <= TapSpotter.SLOP))
            this.spoiled = true;
    }
    cancel() {
        this.spoiled = true;
    }
    /** The last finger lifted at `time`: the tap's finger count, or null. */
    allUp(time) {
        const { start, spoiled, fingers } = this;
        this.start = null;
        this.fingers = 0;
        this.spoiled = false;
        if (start === null || spoiled || time - start > TapSpotter.MAX_DURATION || fingers <= 0)
            return null;
        return fingers;
    }
}
/** The gesture card shows once per mode. */
export class GestureHints {
    seen;
    constructor(seen) {
        this.seen = seen;
    }
    take() {
        if (this.seen)
            return false;
        this.seen = true;
        return true;
    }
}
// ---------------------------------------------------------------- zoom
/** The picture's zoom: `scale` (1 = fitted) and the display's point (0…1) in the middle of what shows. */
export class Zoom {
    scale;
    center;
    static MAX_SCALE = 5;
    static DOUBLE_TAP_SCALE = 2.5;
    static SNAP_TO_FIT = 1.05;
    static FOLLOW_MARGIN = 0.18;
    static RUBBER = 0.3;
    constructor(scale = 1, center = { x: 0.5, y: 0.5 }) {
        this.scale = scale;
        this.center = center;
    }
    copy() {
        return new Zoom(this.scale, { ...this.center });
    }
    equals(o) {
        return this.scale === o.scale && this.center.x === o.center.x && this.center.y === o.center.y;
    }
    get zoomed() {
        return this.scale > 1.001;
    }
    static clampedScale(s, rubber) {
        if (!Number.isFinite(s) || s <= 0)
            return 1;
        if (!rubber)
            return Math.min(Math.max(s, 1), Zoom.MAX_SCALE);
        if (s < 1)
            return Math.max(1 - (1 - s) * Zoom.RUBBER, 0.5);
        if (s > Zoom.MAX_SCALE)
            return Zoom.MAX_SCALE + (s - Zoom.MAX_SCALE) * Zoom.RUBBER;
        return s;
    }
    /** The picture's frame in a frame of `size` (the fitted picture's). */
    frame(size) {
        const w = size.width * this.scale, h = size.height * this.scale;
        if (this.scale <= 1)
            return { x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h };
        const origin = (length, zoomed, c) => Math.min(Math.max(length / 2 - c * zoomed, length - zoomed), 0);
        return { x: origin(size.width, w, this.center.x), y: origin(size.height, h, this.center.y), width: w, height: h };
    }
    /** The display's point (0…1) at `p` in a frame of `size`. */
    point(p, size) {
        const f = this.frame(size);
        if (!(f.width > 0) || !(f.height > 0))
            return { x: 0.5, y: 0.5 };
        return { x: clamp01((p.x - f.x) / f.width), y: clamp01((p.y - f.y) / f.height) };
    }
    /** Moves what shows so the display's point `anchor` is at `p` (as far as the edges let it). */
    place(anchor, p, size) {
        const w = size.width * this.scale, h = size.height * this.scale;
        if (!(w > 0) || !(h > 0))
            return;
        this.center = { x: (size.width / 2 - (p.x - anchor.x * w)) / w, y: (size.height / 2 - (p.y - anchor.y * h)) / h };
        this.clampCenter();
    }
    clampCenter() {
        if (this.scale <= 1) {
            this.center = { x: 0.5, y: 0.5 };
            return;
        }
        const half = 0.5 / this.scale;
        this.center = { x: Math.min(Math.max(this.center.x, half), 1 - half), y: Math.min(Math.max(this.center.y, half), 1 - half) };
    }
    /** Moves what shows just enough to keep the pointer `p` FOLLOW_MARGIN clear of its edges. */
    follow(p) {
        if (!this.zoomed || !Number.isFinite(p.x) || !Number.isFinite(p.y))
            return;
        const half = 0.5 / this.scale;
        const margin = Zoom.FOLLOW_MARGIN / this.scale;
        const axis = (c, v) => {
            const lo = c - half + margin, hi = c + half - margin;
            return v < lo ? c - (lo - v) : v > hi ? c + (v - hi) : c;
        };
        this.center = { x: axis(this.center.x, p.x), y: axis(this.center.y, p.y) };
        this.clampCenter();
    }
}
// ---------------------------------------------------------------- the page's layout
/** The trackpad surface is at least this tall (the picture narrows to leave it that). */
export const MIN_PAD_HEIGHT = 160;
/** The picture doesn't narrow below this for the surface (there is none then). */
export const MIN_PICTURE_HEIGHT = 120;
export const PAD_GAP = 12;
/**
 * The picture's frame and the trackpad surface's (null: none) for a picture of `aspect` in `area` (iOS
 * `ScreenCanvasView.layout`): with the surface the picture is full width at the top when that leaves the surface
 * MIN_PAD_HEIGHT, else it narrows; never shorter than MIN_PICTURE_HEIGHT (then no surface). Without it the picture is
 * aspect-fit and centered.
 */
export function pageLayout(area, aspect, padTopInset = 0, wantsPad = true) {
    if (!(area.width > 0) || !(area.height > 0) || !Number.isFinite(aspect) || aspect <= 0)
        return { picture: { x: 0, y: 0, width: 0, height: 0 }, pad: null };
    const fullWidthHeight = Math.floor(area.width / aspect);
    const padRoom = MIN_PAD_HEIGHT + padTopInset + PAD_GAP;
    if (wantsPad && (area.height - fullWidthHeight >= padRoom || area.height - padRoom >= MIN_PICTURE_HEIGHT)) {
        const fits = area.height - fullWidthHeight >= padRoom;
        const height = fits ? fullWidthHeight : area.height - padRoom;
        const width = fits ? area.width : Math.min(area.width, Math.floor(height * aspect));
        const picture = { x: area.x + Math.floor((area.width - width) / 2), y: area.y, width, height };
        const top = picture.y + picture.height + PAD_GAP;
        return { picture, pad: { x: area.x + PAD_GAP, y: top, width: area.width - 2 * PAD_GAP, height: area.y + area.height - top } };
    }
    const s = Math.min(area.width / aspect, area.height);
    const w = Math.floor(s * aspect), h = Math.floor(s);
    return { picture: { x: area.x + Math.floor((area.width - w) / 2), y: area.y + Math.floor((area.height - h) / 2), width: w, height: h }, pad: null };
}
// ---------------------------------------------------------------- the client-drawn pointer's size
export const MIN_POINTER_HEIGHT = 20;
export const REFERENCE_POINTER_HEIGHT = 40;
/** How much a pointer shape grows so the arrow is never smaller on screen than MIN_POINTER_HEIGHT (iOS `pointerGrow`). */
export function pointerGrow(shapeHeight, screenHeight, displayHeight) {
    const onScreen = displayHeight && displayHeight > 0 && Number.isFinite(displayHeight) ? (REFERENCE_POINTER_HEIGHT / displayHeight) * screenHeight : shapeHeight * screenHeight;
    return onScreen > 0 && Number.isFinite(onScreen) ? Math.max(1, MIN_POINTER_HEIGHT / onScreen) : 1;
}
export const CAUGHT_UP_TOLERANCE = 2;
/** The server's pointer is where this page sent it (both 0…1 on a display of `display` points). */
export function caughtUp(server, local, display) {
    const w = display.width > 0 && Number.isFinite(display.width) ? display.width : 1000;
    const h = display.height > 0 && Number.isFinite(display.height) ? display.height : 1000;
    return Math.abs(server.x - local.x) * w <= CAUGHT_UP_TOLERANCE && Math.abs(server.y - local.y) * h <= CAUGHT_UP_TOLERANCE;
}
