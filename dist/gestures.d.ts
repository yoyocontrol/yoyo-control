import type { ScrollPhase } from "@yoyocontrol/screen-web";
/**
 * The Screen page's gestures as plain values (the trackpad controller drives them, the tests check them), ported from
 * the iOS kit's ScreenGestures.swift: the live drag — a touch held still then moved, a tap then a moving touch, or three
 * fingers — with its drag lock and its move at the edges, the trackpad's accelerated pointer, the finger's speed and
 * smoothing, the two-finger scroll's phases, the tap spotter, the gesture card's "seen" flag, the loupe's numbers, the
 * springs and the picture's zoom. Times are the caller's clock in seconds; points are CSS pixels.
 */
export interface Point {
    x: number;
    y: number;
}
export interface Size {
    width: number;
    height: number;
}
export interface Rect extends Point, Size {
}
export type DragStep = {
    t: "down";
    at: Point;
} | {
    t: "move";
    at: Point;
} | {
    t: "up";
    at: Point;
};
export type DragPhase = {
    t: "idle";
}
/** `down` sent; the pointer is at `at`. */
 | {
    t: "dragging";
    at: Point;
}
/** `down` sent, the fingers lifted: the button stays down until `until` (null: fingers rest on the glass). */
 | {
    t: "locked";
    at: Point;
    until: number | null;
};
/**
 * A live drag (iOS `ScreenDrag`). Lifting the fingers mid-drag doesn't let go at once (a Mac trackpad's drag lock): the
 * button stays down for `LOCK_WINDOW`. The same kind of touch that comes back within it and moves carries on with the
 * same drag; anything else lets go first; no touch at all lets go when the window runs out. Fingers resting on the
 * glass hold the window open until they move or lift. Interrupted: `up` where the pointer was.
 */
export declare class Drag {
    /** How long (s) the button stays down after the fingers lift mid-drag. */
    static readonly LOCK_WINDOW = 0.8;
    phase: DragPhase;
    get isPressed(): boolean;
    get isDragging(): boolean;
    get isLocked(): boolean;
    /** When a lock runs out (null: not locked, or held open by resting fingers). */
    get lockedUntil(): number | null;
    /** The drag's touch began to move with the pointer at `point`: `down` there (a locked drag carries on instead). */
    began(point: Point): DragStep[];
    moved(point: Point): DragStep[];
    /** The fingers lifted at `now`: the drag locks (nothing sent). */
    ended(point: Point, now: number): DragStep[];
    /** A finger came down at `now`: on an open lock it holds it; on one that ran out it lets go. */
    touched(now: number): DragStep[];
    /** Something other than the drag's kind of move came of the touch on a lock: it lets go. */
    released(): DragStep[];
    /** A lock that ran out with no finger on the glass lets go. */
    expire(now: number): DragStep[];
    /** Interrupted: a pressed button is lifted where the pointer was. */
    cancelled(): DragStep[];
}
/** A tap, then a touch within `WINDOW` and `REACH` of it: armed while that touch is down; if it moves it drags. */
export declare class TapToDrag {
    static readonly WINDOW = 0.3;
    static readonly REACH = 44;
    private tapUp;
    private tapAt;
    armed: boolean;
    tapped(time: number, location?: Point | null): void;
    touched(time: number, location?: Point | null): void;
    /** The touch moves: true = it drags (once). */
    take(): boolean;
    disarm(): void;
    lifted(): void;
}
/**
 * One finger down and come to rest for `DELAY`: armed; if it then moves it drags. Resting = it never rolled more than
 * `STILLNESS` from where it landed, and kept within `REST_RADIUS` of one spot for the last `REST_TIME`.
 */
export declare class HoldToDrag {
    static readonly DELAY = 0.5;
    static readonly STILLNESS = 6;
    static readonly REST_RADIUS = 1.5;
    static readonly REST_TIME = 0.25;
    downAt: number | null;
    armed: boolean;
    private rest;
    private restSince;
    touched(time: number): void;
    /** The finger is `offset` from where it landed at `time`. */
    moved(offset: Point, time: number): void;
    /** When it may arm if the finger stays (null: not in this touch, or armed already). */
    get due(): number | null;
    check(now: number): boolean;
    take(): boolean;
    cancel(): void;
}
/**
 * Relative moves accelerated like a Mac's trackpad, relative to the picture: at a normal speed the pointer covers as much
 * of the picture as the finger covers of the trackpad, so a full swipe crosses the display however small it is drawn.
 */
export declare const Trackpad: {
    PRECISE_SPEED: number;
    NORMAL_SPEED: number;
    FAST_SPEED: number;
    PRECISE_GAIN: number;
    FAST_GAIN: number;
    /** Picture points per trackpad point at `speed` (points per second). */
    curve(speed: number): number;
    /** Display points per picture point (1 when either is unknown). */
    pictureFactor(display: Size, picture: Size): number;
    gain(speed: number, display: Size, picture: Size, scale?: number): number;
    /** The pointer `p` (0…1) moved by the finger's `finger` (trackpad points) on a display of `display` points. */
    moved(p: Point, finger: Point, display: Size, gain: number): Point;
    clamp(p: Point): Point;
};
/** The finger's speed from its own (coalesced) samples: the path over the last `WINDOW` divided by the time. */
export declare class FingerSpeed {
    static readonly WINDOW = 0.04;
    static readonly MIN_SPAN = 0.012;
    samples: {
        time: number;
        location: Point;
    }[];
    speed: number;
    get location(): Point | null;
    reset(location?: Point | null, time?: number): void;
    add(location: Point, time: number): void;
    static speedOf(samples: {
        time: number;
        location: Point;
    }[], window: number): number;
}
/** A "1€ filter" for a slow finger's tremor: a low-pass whose cutoff rises with the speed. */
export declare class FingerSmoother {
    static readonly REST_CUTOFF = 3;
    static readonly CUTOFF_PER_SPEED = 0.06;
    static get MAX_LAG(): number;
    location: Point | null;
    private time;
    reset(location: Point | null, time: number): void;
    add(p: Point, time: number, speed: number): Point;
}
/** While dragging, a finger near the trackpad's edge keeps the pointer going that way. */
export declare const EdgeMove: {
    BAND: number;
    MAX_RATE: number;
    /** Velocity (trackpad points per second over the picture) for a finger at `finger` in `bounds`. */
    velocity(finger: Point, bounds: Rect, pictureWidth: number): Point;
};
export interface SpringParameters {
    /** Seconds for one undamped oscillation. */
    response: number;
    /** 1 = no overshoot. */
    dampingRatio: number;
}
/** The loupe over the pointer: how big, how much it magnifies, how it moves. */
export declare const Loupe: {
    TARGET_SCALE: number;
    MIN_MAGNIFICATION: number;
    MAX_MAGNIFICATION: number;
    follow: SpringParameters;
    appear: SpringParameters;
    disappear: SpringParameters;
    magnification(pictureScale: number): number;
    /** Its diameter over a picture: half the picture's short side, 100…150. */
    diameter(picture: Size): number;
};
/** A damped spring (Apple's response / damping ratio, unit mass); retargets keep the velocity. */
export declare class Spring {
    value: number;
    velocity: number;
    target: number;
    constructor(value: number);
    settled(epsilon?: number): boolean;
    /** Advances `dt` seconds in sub-steps of at most 1/480 s. */
    step(dt: number, p: SpringParameters): void;
}
/** screen-web's (a scroll input's `phase`). */
export type { ScrollPhase } from "@yoyocontrol/screen-web";
export type Axis = "vertical" | "horizontal" | "both";
/** One step of a two-finger scroll: fractions of the picture (positive = see further right / down). */
export interface ScrollStep {
    delta: Point;
    phase: ScrollPhase;
    velocity: Point;
}
/** A two-finger pan as scroll steps, with UIScrollView's directional lock (iOS `ScreenTwoFingerScroll`). */
export declare class TwoFingerScroll {
    static readonly LOCK_DISTANCE = 8;
    static readonly LOCK_RATIO = 2;
    static readonly MAX_LIFT_SPEED = 6000;
    private last;
    active: boolean;
    axis: Axis | null;
    began(t: Point, size: Size, reporting: boolean): ScrollStep | null;
    changed(t: Point, size: Size, reporting: boolean): ScrollStep | null;
    /** The fingers lifted (`v` in points per second) or the gesture was cancelled (null). */
    ended(v: Point | null, size: Size): ScrollStep | null;
    static axisFor(t: Point): Axis;
    static locked(v: Point, axis: Axis | null): Point;
    /** A velocity at lift (display points per second) kept under MAX_LIFT_SPEED, its direction unchanged. */
    static capped(v: Point): Point;
}
/** Tells a tap from the touches alone, the moment the last finger lifts: quick, still, and how many fingers. */
export declare class TapSpotter {
    static readonly MAX_DURATION = 0.5;
    static readonly SLOP = 10;
    private start;
    private fingers;
    private spoiled;
    down(count: number, time: number): void;
    moved(distance: number): void;
    cancel(): void;
    /** The last finger lifted at `time`: the tap's finger count, or null. */
    allUp(time: number): number | null;
}
/** The gesture card shows once per mode. */
export declare class GestureHints {
    seen: boolean;
    constructor(seen: boolean);
    take(): boolean;
}
/** The picture's zoom: `scale` (1 = fitted) and the display's point (0…1) in the middle of what shows. */
export declare class Zoom {
    scale: number;
    center: Point;
    static readonly MAX_SCALE = 5;
    static readonly DOUBLE_TAP_SCALE = 2.5;
    static readonly SNAP_TO_FIT = 1.05;
    static readonly FOLLOW_MARGIN = 0.18;
    static readonly RUBBER = 0.3;
    constructor(scale?: number, center?: Point);
    copy(): Zoom;
    equals(o: Zoom): boolean;
    get zoomed(): boolean;
    static clampedScale(s: number, rubber: boolean): number;
    /** The picture's frame in a frame of `size` (the fitted picture's). */
    frame(size: Size): Rect;
    /** The display's point (0…1) at `p` in a frame of `size`. */
    point(p: Point, size: Size): Point;
    /** Moves what shows so the display's point `anchor` is at `p` (as far as the edges let it). */
    place(anchor: Point, p: Point, size: Size): void;
    clampCenter(): void;
    /** Moves what shows just enough to keep the pointer `p` FOLLOW_MARGIN clear of its edges. */
    follow(p: Point): void;
}
/** The trackpad surface is at least this tall (the picture narrows to leave it that). */
export declare const MIN_PAD_HEIGHT = 160;
/** The picture doesn't narrow below this for the surface (there is none then). */
export declare const MIN_PICTURE_HEIGHT = 120;
export declare const PAD_GAP = 12;
/**
 * The picture's frame and the trackpad surface's (null: none) for a picture of `aspect` in `area` (iOS
 * `ScreenCanvasView.layout`): with the surface the picture is full width at the top when that leaves the surface
 * MIN_PAD_HEIGHT, else it narrows; never shorter than MIN_PICTURE_HEIGHT (then no surface). Without it the picture is
 * aspect-fit and centered.
 */
export declare function pageLayout(area: Rect, aspect: number, padTopInset?: number, wantsPad?: boolean): {
    picture: Rect;
    pad: Rect | null;
};
export declare const MIN_POINTER_HEIGHT = 20;
export declare const REFERENCE_POINTER_HEIGHT = 40;
/** How much a pointer shape grows so the arrow is never smaller on screen than MIN_POINTER_HEIGHT (iOS `pointerGrow`). */
export declare function pointerGrow(shapeHeight: number, screenHeight: number, displayHeight: number | null): number;
export declare const CAUGHT_UP_TOLERANCE = 2;
/** The server's pointer is where this page sent it (both 0…1 on a display of `display` points). */
export declare function caughtUp(server: Point, local: Point, display: Size): boolean;
