import { Drag, type Axis, type DragStep, type Point, type Rect, type ScrollStep, type Size } from "./gestures.js";
/**
 * The trackpad surface under the picture (iOS ScreenCanvasView's gestures, on pointer events): one finger moves the
 * pointer (relative, accelerated over the picture at the finger's own speed, its tremor smoothed), a tap / double tap
 * clicks where the pointer is, a two-finger tap right-clicks, two fingers scroll (with the gesture's phases and the
 * velocity at lift: the computer scrolls on with momentum), a touch held still then moved drags (selects), so does a
 * tap then a touch that moves, and so do three fingers — lifting keeps the button down for a moment (`Drag`), and a
 * finger resting near the surface's edge keeps the pointer going (`EdgeMove`). A three-finger tap toggles the stats
 * line. A touch must land on the surface; more fingers may then come down anywhere; a finger that wanders off it keeps
 * working but says so (`leftPad`).
 */
export type Click = "click" | "doubleClick" | "rightClick";
/** What the trackpad needs from its page. */
export interface TrackpadHost {
    readonly controlling: boolean;
    /** The surface (page coordinates of the pointer events' target), null: none (full screen). */
    padRect(): Rect | null;
    /** The picture as it shows now (zoomed: bigger than its frame). */
    shownPicture(): Size;
    /** The display's size in points (before the status says: the picture's pixels). */
    display(): Size;
    /** Where the pointer is drawn now (the computer's, or where this page put it), null: none drawn. */
    drawnPointer(): Point | null;
    /** The pointer goes to `p` (0…1) at once: this page sent it there. */
    moveCursor(p: Point): void;
    click(kind: Click, p: Point): void;
    scroll(step: ScrollStep, p: Point): void;
    drag(step: DragStep): void;
    pointerMoved(p: Point): void;
    /** The first finger came down (true) / the last one lifted (false). Any time, controlling or not. */
    touches(down: boolean): void;
    /** The touch that put the keyboard away lifted without a pan: it clicked nothing. */
    quietTap(): void;
    /** A tap lifted (its click shows at once, before single and double are told apart). */
    tapFeedback(p: Point): void;
    threeFingerTap(): void;
    leftPad(out: boolean): void;
    /** A held touch armed a drag (the loupe turns the accent colour) / no longer. */
    holdArmed(on: boolean): void;
    /** The button went down / up (the pointer looks pressed; the drag badge). */
    pressed(on: boolean, p: Point): void;
    /** Two fingers scroll (the badge: their axis once decided, `lean` the way they go) / stopped (null). */
    scrolling(axis: Axis | null | false, lean: Point | null): void;
    /** Something the loupe follows changed (a finger, the pointer, a drag). */
    loupeChanged(): void;
    /** A gesture began in the quiet touch: it goes on as usual. */
    gestureBegan(): void;
    vibrate(pattern: number | number[]): void;
}
/** A one-finger pan begins past this many points (UIKit's pan hysteresis). */
export declare const PAN_SLOP = 10;
/** The second tap of a double tap comes within this long (s) of the first's lift. */
export declare const DOUBLE_TAP_S = 0.35;
/** How far (points) a trackpad finger may go past the surface's edge before it counts as off it. */
export declare const PAD_SLOP = 6;
/** How long (s) the tap that let go of a locked drag or put the keyboard away keeps its click from going. */
export declare const SWALLOW_S = 0.6;
export declare class TrackpadGestures {
    private readonly host;
    private readonly now;
    /** Where this page has the pointer (0…1). */
    pointer: Point;
    readonly drag: Drag;
    private dragKind;
    private dragPoint;
    private readonly tapToDrag;
    private readonly hold;
    private holdTimer;
    private readonly spotter;
    private readonly speed;
    private readonly smoother;
    private readonly twoFinger;
    private fingers;
    private pan;
    private lastTranslation;
    private rawTranslation;
    private glideRaf;
    private edgeRaf;
    private edgeLast;
    private lockTimer;
    private lockTimerFor;
    private singleTimer;
    /** A single tap waiting for a second (its lift time and place). */
    private pendingTap;
    /** The tap before an armed touch: its click waits until that touch lifts without dragging. */
    private heldTapClick;
    private swallowUntil;
    private quiet;
    private quietMoved;
    private outside;
    private landed;
    private liftedAt;
    /** Two fingers or more came down in this touch: no loupe until they all lift. */
    multiFinger: boolean;
    /** A finger is down. */
    fingersDown: boolean;
    /** Two fingers scroll now. */
    isScrolling: boolean;
    /** The holdArmed state (the loupe's tint). */
    holdIsArmed: boolean;
    /** The trackpad's acceleration scale (1). */
    gainScale: number;
    constructor(host: TrackpadHost, now?: () => number);
    /** Fingers on the surface now. */
    get count(): number;
    /** The touch now down puts the keyboard away: a tap of it clicks nothing, anything else goes on. */
    quieten(): void;
    /** A touch pointer went down at `p` (page coordinates). false: not the trackpad's (it landed off the surface). */
    down(id: number, p: Point, t?: number): boolean;
    /** A touch pointer moved; `samples`: its coalesced positions (oldest first, with their times in seconds). */
    move(id: number, p: Point, samples?: {
        p: Point;
        t: number;
    }[], t?: number): void;
    /** A touch pointer lifted (or was cancelled: the browser took it). */
    up(id: number, p: Point, cancelled?: boolean, t?: number): void;
    /** Every touch is gone without lifting (the page hid, control went): a drag is cancelled. */
    reset(): void;
    private firstDown;
    private allUp;
    private tapped;
    /** The single tap's wait ran out: it clicks (unless the touch after it may still drag: then when that lifts). */
    private singleDue;
    /** `send`: a waiting single tap clicks now (another input comes after it); else it is dropped. */
    private clearSingle;
    private fingerCount;
    private updateOutside;
    private armHold;
    private cancelHold;
    private centroid;
    private panMoved;
    private velocity;
    private panBegan;
    private panChanged;
    /** The pan of the current finger count ends (`cancelled`: no velocity, a drag is cancelled). */
    private endPan;
    private velocityOf;
    private emitScroll;
    private gestureBegan;
    /** The one-finger pan's translation is `raw`: the smoothed one follows it and moves the pointer. */
    private smoothPan;
    private glideTick;
    private stopGlide;
    private panned;
    /** Three fingers' translation is `raw`: the pointer follows (smoothed unless `smoothed` is false) as a held move. */
    private dragged;
    private movePointer;
    /** The pointer where it is drawn now, taken as the trackpad's. */
    syncPointer(): Point;
    private beginDrag;
    /** Stops a drag under way (the page goes away, control is gone): what it leaves to do (`up`). */
    cancelDrag(): DragStep[];
    private releaseLock;
    private dragStep;
    private emit;
    private updateDragTimers;
    private dragFinger;
    private updateEdgeMove;
    private edgeTick;
    private stopEdgeMove;
}
