/**
 * How hard the decoder works here, from each picture's decode time (queued → out of `VideoDecoder`, ms), and what the
 * page does about it (pure; `VideoStream` feeds it, the page's session acts):
 *
 * - `DecodeWatch` (one stream): the median of the last `DECODE_WINDOW_MS`. Above `DECODE_SLOW_MS` while the A/V sync
 *   holds pictures back (a floor) for `DECODE_FLOOR_HOLD_MS`: "floor" — the decoder has few output buffers and the
 *   pictures held for the sound use them up (seen on Android: decode 9 ms without the floor, 250 ms with a 300 ms one);
 *   above it without a floor for `DECODE_SLOW_HOLD_MS`: "slow" — it can't keep up with the stream's size and rate;
 *   under `DECODE_EASY_MS` for `DECODE_EASY_HOLD_MS`: "easy". Each verdict once per stream.
 * - `StreamLevels` (the page): the stream's size and rate, `STREAM_LEVELS[index]` (the stream request's `maxWidth` /
 *   `fps`). "slow" steps down; "easy" steps up again after `LEVEL_UP_AFTER_MS` at a level, unless the last step up
 *   turned slow within `LEVEL_UP_FAILED_MS` (then it stays for the visit).
 */
export declare const DECODE_WINDOW_MS = 1500;
export declare const DECODE_MIN_SAMPLES = 15;
export declare const DECODE_SLOW_MS = 80;
export declare const DECODE_SLOW_HOLD_MS = 3000;
export declare const DECODE_FLOOR_HOLD_MS = 1000;
export declare const DECODE_EASY_MS = 30;
export declare const DECODE_EASY_HOLD_MS = 60000;
export type DecodeVerdict = "slow" | "floor" | "easy";
export declare class DecodeWatch {
    private samples;
    private slowSince;
    private floorSince;
    private easySince;
    private said;
    /** One picture's decode time `ms`, out at `at`; `floorMs` the A/V sync's hold now. A verdict the first time one holds. */
    add(ms: number, at: number, floorMs: number): DecodeVerdict | null;
    /** The window's median decode time (null: fewer than `DECODE_MIN_SAMPLES`). */
    median(): number | null;
    private say;
}
/** The stream's size and rate, best first. */
export declare const STREAM_LEVELS: readonly {
    maxWidth: number;
    fps: number;
}[];
export declare const LEVEL_UP_AFTER_MS = 180000;
export declare const LEVEL_UP_FAILED_MS = 60000;
export declare class StreamLevels {
    index: number;
    private changedAt;
    private wentUpAt;
    private upFailed;
    get level(): {
        maxWidth: number;
        fps: number;
    };
    /** The decoder can't keep up: one level down (false: already the lowest). */
    slow(now: number): boolean;
    /** The decoder has room: one level up when it has been long enough (false: stays). */
    easy(now: number): boolean;
}
