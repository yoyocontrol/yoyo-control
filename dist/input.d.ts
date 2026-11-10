import type { Input, Modifier, ScrollPhase } from "./types.js";
/**
 * The screen page's input to the computer (`POST /input`, docs/PROTOCOL.md「输入」): what browser events
 * become, and the queue that sends them in order (ported from the iOS InputQueue, simplified). Pure: the page
 * wires DOM events to these functions.
 */
export type SendInput = (input: Input) => Promise<void>;
/** Pointer moves on their way at once (each with its `seq`; the server drops a stale one). */
export declare const MAX_MOVES_IN_FLIGHT = 3;
/** Less than this (points, on both axes) waits for more. */
export declare const MIN_SCROLL = 0.5;
/** A failed move this soon after a reported failure isn't reported (a dead path fails several at once: one toast). */
export declare const MOVE_FAILURE_QUIET_MS = 1000;
export interface InputQueueOptions {
    /** The way in use's link sender (null: HTTP requests, one at a time). Asked for each input. */
    link?: () => ((input: Input) => void) | null;
}
/** `next` folded into `last` when both are of one move or one scroll gesture (null: they go as two). */
export declare function mergeLinkInput(last: Input, next: Input): Input | null;
/**
 * Input in order, one request at a time, except pointer moves: up to MAX_MOVES_IN_FLIGHT of those go at once, each
 * with the next `seq` (from the wall clock in ms, one up per move). Scrolls and moves never queue up: while one is on
 * its way, two-finger / wheel deltas add up and moves keep only the latest position, and what waited goes as one
 * when it returns. Anything else (clicks, keys, text, a drag's down / up) waits for every earlier request, moves
 * included, to return. Scroll phases keep their order: `began` starts a merge of its own, `changed` adds up into the
 * open one, `ended` goes with what waited (or after a `began` not sent yet, on its own).
 *
 * **Link mode** (`options.link` gives a sender: the way in use is a uu Link session): nothing waits for an answer — the
 * link orders, repeats and acknowledges input itself (discrete events exactly once, the newest move wins). What comes in
 * one turn of the event loop goes out at the end of it (a microtask), in order: pointer moves merge into the latest
 * (same display, button and modifiers), and so do scroll deltas of one gesture (`mergeLinkInput`). Moves still take the
 * next `seq`. A refusal comes back later (the link's input error handler); a send that throws (too many unacknowledged
 * events: 429) goes to `failed` at once. A way that stopped being a link before the flush gets them as requests.
 */
export declare class InputQueue {
    private readonly send;
    private readonly failed;
    private readonly now;
    private readonly options;
    private line;
    private busy;
    private movesInFlight;
    private nextSeq;
    private generation;
    private reportedAt;
    private outbox;
    private flushScheduled;
    constructor(send: SendInput, failed: (e: unknown) => void, firstSeq?: number, now?: () => number, options?: InputQueueOptions);
    /** Link mode: inputs waiting for the end of this turn. */
    get queuedForLink(): number;
    /** Requests waiting in line (not sent yet). */
    get waiting(): number;
    get inFlight(): number;
    /** A click, a key, text, a drag's down / up: in order, after what came before. */
    input(input: Input): void;
    /** The pointer to (x, y) (0…1); `button`: held (a live drag). Only the latest position waits. */
    move(x: number, y: number, display?: number, button?: "left"): void;
    /** A scroll by (dx, dy) display points at (x, y), in a gesture's `phase` (none: a wheel); velocity at lift for `ended`. */
    scroll(dx: number, dy: number, x: number, y: number, display?: number, phase?: ScrollPhase, vx?: number, vy?: number): void;
    /** Drops everything not sent yet (the page stopped); what is on its way is let go. */
    cancel(): void;
    /** Link mode: into the outbox (merged with the last one when it can be), sent at the end of this turn. */
    private linkEnqueue;
    private flushLink;
    private report;
    /** The last entry if it is an open merge of this kind, else a new one. */
    private open;
    private closeOpen;
    private pump;
    private done;
}
/** The fields of a KeyboardEvent the mapping reads. */
export interface KeyLike {
    key: string;
    code: string;
    metaKey: boolean;
    ctrlKey: boolean;
    altKey: boolean;
    shiftKey: boolean;
    isComposing?: boolean;
    keyCode?: number;
}
/** ⌘ and Ctrl both send `cmd` (a Mac takes ⌘, the Linux desktop maps it to Ctrl); Shift and Option / Alt as they are. */
export declare function modifiersOf(e: Pick<KeyLike, "metaKey" | "ctrlKey" | "altKey" | "shiftKey">): Modifier[];
/**
 * A keydown as a `key` input, or null when it isn't one: a plain character (with or without Shift / Option) is typed
 * through the hidden text field (`input` / `compositionend` → `type`, so the browser's IME composes Chinese first),
 * and so is anything while a composition is on. Keys with names (Return, arrows, F-keys…) and shortcuts (⌘ / Ctrl +
 * a letter, digit or punctuation) are keys. `linux`: Insert has a name there (the paste key, Shift+Insert).
 */
export declare function keyInput(e: KeyLike, linux?: boolean): Input | null;
/**
 * What the hidden text field's `input` event sends (`beforeinput` types from a phone's keyboard included): typed
 * text → `type`, a line break → Return, a backspace → Delete. Null while composing (the text comes with
 * `compositionend`) or for anything else.
 */
export declare function textInput(inputType: string, data: string | null, composing: boolean): Input | null;
/**
 * The paste key after the phone / browser put text on the computer's clipboard: ⌘V on the Mac; Shift+Insert on the
 * Linux desktop (yoyo-linux's `insert`: GTK apps and xfce4-terminal both paste with it; Ctrl+V doesn't in a terminal);
 * Ctrl+V on Windows (yoyo-windows: every Windows app, the console included, pastes with it).
 */
export declare const PASTE_KEY: Record<"mac" | "linux" | "windows", Input>;
export interface Box {
    left: number;
    top: number;
    width: number;
    height: number;
}
/** A client point as the display's 0…1 (clamped), from the picture's box on the page. */
export declare function normalizedPoint(clientX: number, clientY: number, box: Box): {
    x: number;
    y: number;
};
/**
 * A wheel event's scroll in display points (positive dy = see content further down, as the browser's deltaY). Pixel
 * deltas (trackpads) follow the fingers on the picture: × the display's points per picture pixel; line and page
 * deltas are wheel notches (40 points a line, a page = the display's height).
 */
export declare function wheelDelta(deltaX: number, deltaY: number, deltaMode: number, pointsPerPx: number, pageHeight: number): {
    dx: number;
    dy: number;
};
/** What a finger on the picture does (a phone's browser): tap, double tap, long press, one-finger scroll. */
export type TouchAction = {
    t: "click" | "doubleClick" | "rightClick";
    x: number;
    y: number;
} | {
    t: "scroll";
    phase: ScrollPhase;
    dx: number;
    dy: number;
    x: number;
    y: number;
    vx: number;
    vy: number;
};
export declare const TOUCH_SLOP_PX = 8;
export declare const LONG_PRESS_MS = 500;
export declare const DOUBLE_TAP_MS = 300;
export declare const DOUBLE_TAP_PX = 24;
/**
 * One-finger gestures over the picture, by time and position (client px), pure: `down` / `move` / `up` / `tick`
 * (timers: the page calls it at `deadline`) return what to send. A tap waits DOUBLE_TAP_MS for a second one (then
 * `doubleClick`, else `click`); a finger held LONG_PRESS_MS without moving right-clicks; one that moves past the slop
 * scrolls, the content following it (finger up = content further down), in display points (`pointsPerPx`), with the
 * gesture's phases and the velocity at lift. `at` maps a client point to the display's 0…1.
 */
export declare class TouchGestures {
    private readonly at;
    private readonly pointsPerPx;
    private start;
    private last;
    private scrolling;
    private pressed;
    private longFired;
    private pendingTap;
    /** Recent finger positions (for the velocity at lift). */
    private trail;
    constructor(at: (x: number, y: number) => {
        x: number;
        y: number;
    }, pointsPerPx: () => number);
    /** When `tick` has something to do (a long press, a single tap's wait running out), or null. */
    get deadline(): number | null;
    down(x: number, y: number, t: number): TouchAction[];
    move(x: number, y: number, t: number): TouchAction[];
    up(x: number, y: number, t: number): TouchAction[];
    cancel(): void;
    tick(t: number): TouchAction[];
    private flushTap;
    private scrollAction;
}
/**
 * A mouse's clicks as the computer should get them: a double click is ONE `doubleClick` (not `click` + `doubleClick`,
 * which the Mac takes as three presses and the Linux desktop's xdotool as a triple click). A first click (`detail` 1)
 * waits DOUBLE_TAP_MS (as a tap does); a second one (`detail` 2) within it replaces it with a `doubleClick`; else it
 * goes as `click` at its deadline. `flush()` sends a waiting click at once: the page calls it before any other input
 * (keys, text, a drag's down, a right-click, a scroll) so the order stays. Pure: `now` and `tick` come from the page.
 */
export declare class ClickGate {
    private readonly emit;
    private pending;
    constructor(emit: (input: Input) => void);
    /** When `tick` sends the waiting click, or null. */
    get deadline(): number | null;
    /** A browser click with its `detail` (the click count) at (x, y). */
    click(x: number, y: number, detail: number, modifiers: Modifier[], t: number): void;
    /** The waiting click goes now (before other input). */
    flush(): void;
    tick(t: number): void;
    /** The page stopped: a waiting click is dropped. */
    cancel(): void;
}
/**
 * What the hidden text field holds between inputs: one character, so a phone's soft keyboard (Android in particular)
 * has something to delete and sends `deleteContentBackward` — mapped to the Delete key — instead of nothing. The field
 * goes back to it after every input (iOS keeps a sentinel the same way).
 */
export declare const FIELD_SENTINEL = "\u200B";
/** Puts the field back to the sentinel, the caret after it. */
export declare function resetField(field: {
    value: string;
    setSelectionRange?: (start: number, end: number) => void;
}): void;
/** Composed text without the sentinel (a keyboard that replaced the field's whole text sends it along). */
export declare const withoutSentinel: (text: string) => string;
/** A name for this browser to show on the other devices: "Chrome on Mac", "Safari on iPhone". */
export declare function deviceName(ua: string): string;
