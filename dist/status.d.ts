import type { ControlDevice, Controller, Display, DisplayState, Features, StreamStatusPart } from "./types.js";
/**
 * The page's reading of a screen's status and the connection codes (docs/PROTOCOL.md「连接状态」), as the iOS
 * ScreenHost / ScreenConnectionModel / ScreenControlModel. Pure. No words of its own beyond `englishStrings`: a host
 * page passes its own `ScreenStrings`.
 */
export type Host = "mac" | "linux" | "windows";
/** What the screen runs on: "linux" / "windows" when the server says so, any other `platform` is a Mac; none → `fallback`. */
export declare function hostOf(status: {
    platform?: string | null;
} | null | undefined, fallback?: Host): Host;
/** The computer's clipboard: `features.clipboard` when the server says, else `fallback`. */
export declare function clipboardOn(status: {
    features?: Features | null;
} | null | undefined, fallback: boolean): boolean;
/** The speaker: hidden at once when the server says there is no sound; otherwise found out by asking (404 / 503). */
export declare function audioOn(status: {
    features?: Features | null;
} | null | undefined): boolean;
/** The display `id` (when it is still there), else the main one, else the first. */
export declare function mainDisplay<D extends Display>(s: {
    displays: D[];
}, id?: number | null): D | null;
export type ControlRole = {
    t: "free";
} | {
    t: "agent";
} | {
    t: "me";
} | {
    t: "other";
    name: string | null;
};
/** Who holds the screen as this browser sees it (`me`: its device id). A holder that names no device: as before (mine). */
export declare function controlRole(controller: Controller, device: ControlDevice | undefined | null, me: string): ControlRole;
export type Phase = {
    t: "live";
} | {
    t: "reconnecting";
    reason: string | null;
} | {
    t: "unavailable";
    reason: string | null;
    retryAt: number | null;
};
/** An unexplained gap (the stream ended, no picture since) shows "Reconnecting" after this long. */
export declare const GAP_GRACE_MS = 700;
/** A status part's JSON, leniently: null when it isn't one. */
export declare function parseStatusPart(body: Uint8Array | string): StreamStatusPart | null;
/**
 * What the page says about its picture (the iOS ScreenConnectionModel, without the reopen hold): the open stream's status
 * part counts first, then the display's state entry; a state that isn't `ready` shows at once until a NEW PICTURE
 * arrives after it; without states, a stream that ended and brought no picture for GAP_GRACE_MS reads "Reconnecting".
 */
export declare class ConnectionModel {
    private stateAt;
    private state;
    private lastPicture;
    private gapSince;
    private retried;
    private open;
    locked: boolean;
    streamOpened(): void;
    streamEnded(now: number): void;
    picture(now: number): void;
    /** A status part of the open stream, or the display's entry of the screen's status / a state event. */
    status(s: DisplayState & {
        console?: {
            locked: boolean;
        } | null;
    }, now: number): void;
    retry(now: number): void;
    phase(now: number): Phase;
    /** The stats line's part (codes, not words): `live ready`, `reconnecting helper-restart`, `unavailable no-session`,
     *  `· locked` when the console is. */
    statsText(now: number): string;
    /** When the phase changes by itself (a gap turning into "Reconnecting"), or null. */
    deadline(): number | null;
}
/** The words of the connection phases (a host page passes its own: its language, its names for the computer). */
export interface ScreenStrings {
    /** The headline while a stream first connects (reason "starting"). */
    connecting: string;
    reconnecting: string;
    /** The headline when the screen can't be shown. */
    unavailable(host: Host): string;
    /** The line under it when no reason has words. */
    unavailableDetail(host: Host): string;
    /** A reason code's words, null for codes it has none for. */
    reason(reason: string, host: Host): string | null;
}
export declare const englishStrings: ScreenStrings;
/** The overlay's headline and the line under it (null: live, nothing to say). */
export declare function phaseText(p: Phase, host: Host, strings?: ScreenStrings): {
    title: string;
    detail: string | null;
} | null;
/** How long to wait before asking again for a display the server called unavailable: until its `retryAt`, 2…15 s; 5 s without one. */
export declare function retryDelay(retryAt: number | null | undefined, nowMs?: number): number;
export declare const QUICK_LIFETIME_MS = 3000;
export declare const QUICK_ENDS_ALLOWED = 3;
export declare const REOPEN_BACKOFF_MS = 1000;
export declare const RETRY_FAILED_MS = 3000;
export declare const RETRY_EMPTY_MS = 5000;
/** What to do when the video stream ends (iOS ScreenStreamReopenPolicy; its 15 s retry is shorter here: a page has no
 *  background state to save power for). */
export declare class ReopenPolicy {
    quickEnds: number;
    /** ms to wait before opening again. */
    ended(delivered: boolean, failed: boolean, lifetimeMs: number): number;
    reset(): void;
}
/** When the sound opens again after its stream ended (iOS ScreenAudioPolicy): null = not again this visit. */
export declare class AudioPolicy {
    static readonly unavailableRetryMs = 30000;
    static readonly failedRetryMs = 5000;
    static readonly quickLifetimeMs = 5000;
    quickEnds: number;
    ended(status: number | null, lifetimeMs: number): number | null;
    reset(): void;
}
