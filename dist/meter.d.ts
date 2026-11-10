import type { PlayoutReport } from "./types.js";
/**
 * The playout report's measurements over a sliding window (the iOS kit's `ScreenPlayoutMeter`), pure: every time is
 * passed in (ms, the page's clock). Pictures shown (with their decode time and, for live pictures, their `X-Frame-Time`),
 * whole picture parts arrived and decoded pictures dropped undrawn. Gaps longer than `pauseMs` are pauses of the content,
 * not gaps of the playout, and are left out. A hitch is a gap of more than twice the median (and at least `minHitchMs`);
 * a stall is live pictures in a row shown `STALL_MS.short` / `.long` further apart than the computer captured them.
 */
export declare class PlayoutMeter {
    readonly windowMs: number;
    readonly pauseMs: number;
    readonly minHitchMs: number;
    /** The two stall lengths reported (`stall150PerSec` / `stall300PerSec`). */
    static readonly STALL_MS: {
        readonly short: 150;
        readonly long: 300;
    };
    private since;
    private arrivals;
    private shownAt;
    private drops;
    constructor(windowMs?: number, pauseMs?: number, minHitchMs?: number);
    /** Starts over (a new stream). */
    reset(now: number): void;
    /** A whole live picture part arrived. */
    arrived(t: number): void;
    /** A picture was drawn at `t`; `macTime`: a live picture's `X-Frame-Time` (null for refine / keepalive). */
    shown(t: number, decodeMs: number | null, macTime?: number | null): void;
    /** Decoded pictures that were never drawn. */
    dropped(count: number, t: number): void;
    /** The window's measurements (null when nothing was shown in it); the caller adds the playout's own fields. */
    report(mode: PlayoutReport["mode"], now: number): PlayoutReport | null;
    private static gaps;
    private prune;
}
/** A report's numbers rounded to 0.1 and the non-finite ones left out (what goes on the wire). */
export declare function roundReport(r: PlayoutReport): PlayoutReport;
