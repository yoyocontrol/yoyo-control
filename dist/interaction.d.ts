import type { SendInput } from "./input.js";
/**
 * Whether the user is interacting with the screen right now (docs/PROTOCOL.md「操作时自动低延迟」): a pointer or finger
 * pressed on the picture (from the first contact, before any gesture is recognized), or an input sent to the computer
 * (a key, text, the wheel, a pointer move), and INTERACTIVE_TAIL_MS after the last contact lifts or the last input.
 * While it is on, the video's playout shows pictures with a depth of about one picture interval (`Playout.interactive`)
 * instead of the smooth buffer's. The page owns one for the screen (it outlives a stream: a stream opened while a
 * finger is down starts interactive) and passes it to each `VideoStream`.
 *
 * The page wires it: `down()` / `up()` on pointerdown / pointerup / pointercancel over the picture (while it holds
 * control), and either `pulse()` on each input, or its sends through `withInteraction(send, interactivity)`.
 */
/** 600 ms covers the computer's answer to the last input (a round trip and an encode, ~250 ms on 5G) with room for a
 *  second tap or key; longer would keep showing a calm screen without its smoothing. */
export declare const INTERACTIVE_TAIL_MS = 600;
export interface InteractivityClock {
    now: () => number;
    setTimeout: (fn: () => void, ms: number) => unknown;
    clearTimeout: (handle: unknown) => void;
}
export declare class Interactivity {
    readonly tailMs: number;
    private readonly clock;
    private contacts;
    /** When the tail ends (null: no tail running). */
    private until;
    private timer;
    private readonly listeners;
    private last;
    constructor(tailMs?: number, clock?: InteractivityClock);
    /** A contact is down, or the tail runs. */
    get on(): boolean;
    /** Calls `fn` with each change (not with the current state); returns the unsubscribe. */
    subscribe(fn: (on: boolean) => void): () => void;
    /** A pointer / finger went down on the picture. */
    down(): void;
    /** One went up (or was cancelled); the last one starts the tail. */
    up(): void;
    /** An input went to the computer (a key, text, the wheel, a move): on for the tail from now (with a contact down,
     *  until it lifts and the tail runs out). */
    pulse(): void;
    /** Off at once (control lost, the page stops). */
    reset(): void;
    private startTail;
    private stopTail;
    private expire;
    private changed;
}
/** `send` that marks each input as interaction (InputQueue's `SendInput`). */
export declare function withInteraction(send: SendInput, interactivity: Interactivity): SendInput;
