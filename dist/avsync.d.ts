/**
 * A/V sync on the screen page, as the iOS kit's `ScreenAVSync` (pure; the page runs it a few times a second, or lets an
 * `AVSyncDriver` do it). Every delay is this side's clock − the computer's (ms), for the same instant on the computer:
 * the sound's `X-Audio-Time` + `X-Audio-Video-Offset` is the `X-Frame-Time` a real display's picture of that instant
 * carries.
 *
 * - Sound: what plays now + the output latency − the offset; its own delay leaves the sync depth out.
 * - Picture: base + smooth depth + two refreshes (`videoDelay`, what the video would do by itself); `shownDelay` the one
 *   in use (touch, sync floor).
 * - Skew = sound − picture (+ = the sound comes later; the report's `skewMs`).
 *
 * The video waits for the sound while watching: not interactive, sound in the last 5 s and the sound more than
 * `VIDEO_ENTER_MS` later than the picture: the playout's `syncFloor` = that − `SOUND_LATER_MS`, at most
 * `MAX_VIDEO_FLOOR_MS` (the playout ramps to it). It stays engaged (following the skew) until the skew is under
 * `SOUND_LATER_MS`, the sound has been silent, or it is turned off; interactive pictures get no floor. The sound never
 * chases the video's touch drops: only when the smooth video delay is above the sound's own does the sound's delay goal
 * become video + `SOUND_LATER_MS` (the buffer moves its depth there by at most 20 ms a second).
 */
export declare class AVSync {
    static readonly VIDEO_ENTER_MS = 45;
    static readonly SOUND_LATER_MS = 15;
    static readonly MAX_VIDEO_FLOOR_MS = 300;
    /** Sound is "playing" when a packet with sound came this recently (ms). */
    static readonly SILENT_AFTER_MS = 5000;
    /** The video floor is engaged. */
    engaged: boolean;
    update(i: AVSyncInput): AVSyncOutput;
}
export interface AVSyncInput {
    /** The sound's delay now (ms; null: nothing known yet). */
    audioDelay: number | null;
    /** The sound's own delay, without the sync depth. */
    audioOwnDelay: number | null;
    /** The smooth video delay without the floor, and the one in use (ms; null: no smooth playout measured yet). */
    videoDelay: number | null;
    shownDelay: number | null;
    interactive: boolean;
    /** Sound came in the last `SILENT_AFTER_MS`. */
    soundRecent: boolean;
    /** Off: no A/V sync at all / the video never waits for the sound (default on). */
    enabled?: boolean;
    videoFloorEnabled?: boolean;
}
export interface AVSyncOutput {
    /** The playout's `syncFloor` (ms, 0: none). */
    videoFloor: number;
    /** The sound's delay goal (ms; null: its own). */
    audioDelayGoal: number | null;
    /** Sound − picture as shown (ms; null: not both known). */
    skew: number | null;
}
/** What the driver reads from and sets on the sound (`ScreenAudio` is one). */
export interface AVSyncAudio {
    /** The sound's delays now (null: not playing). */
    syncDelays(): {
        delay: number | null;
        ownDelay: number | null;
        soundRecent: boolean;
    } | null;
    /** The A/V sync's delay goal (ms; null: the buffer's own depth). */
    setSyncDelayGoal(goalMs: number | null): void;
    /** The skew and floor the sound's report carries. */
    setSyncReport(skewMs: number | null, floorMs: number | null): void;
}
/** What the driver reads from and sets on the video (`VideoStream` is one). */
export interface AVSyncVideo {
    /** The smooth delay without the floor and the one in use (ms; null: no smooth playout measured yet). */
    syncDelays(): {
        smooth: number;
        shown: number;
    } | null;
    readonly interactive: boolean;
    /** The playout's sync floor (ms). */
    syncFloor: number;
}
/**
 * Runs `AVSync` every `everyMs` between the page's sound and its current video stream (the video changes with each
 * reopen: `video()` returns the one open now). Only a real display's video should be synced (the page knows: a virtual
 * display's pictures don't carry the same-instant times); return null from `video()` otherwise.
 */
export declare class AVSyncDriver {
    private readonly audio;
    private readonly video;
    readonly everyMs: number;
    private readonly sync;
    private timer;
    /** The last output (for a stats line or a test). */
    last: AVSyncOutput;
    constructor(audio: AVSyncAudio, video: () => AVSyncVideo | null, everyMs?: number);
    start(): void;
    /** Stops, and takes the floor and the goal away. */
    stop(): void;
    /** One round (the timer calls it). */
    tick(): AVSyncOutput;
}
