/**
 * Smooth playback with a responsive mode (docs/PROTOCOL.md「客户端的平滑播放」), the same rules as the iOS kit's
 * `ScreenPlayout`: a jitter buffer that shows decoded pictures at an even pace, whose depth drops to about one picture
 * interval while the user interacts. Pure and deterministic: every time is passed in, in ms — host times on the page's
 * clock (`performance.now()`), `macTime` = the part's `X-Frame-Time` (ms since 1970, the server's clock). Acks and
 * decoding never wait for it; only showing does, and only decoded pictures are dropped (every part is decoded as it
 * comes: later pictures reference earlier ones).
 *
 * Each picture's delay = arrival − macTime holds the clock offset plus the network delay. `base` = the smallest delay of
 * the last `windowMs`; the delays above it are the jitter. The depth is their p95 + `marginMs`, within 0…`maxDepthMs`:
 * it grows at once and shrinks by at most `shrinkPerSecondMs` a second (`defaultDepthMs` until `minSamples` were seen).
 * A picture is due at macTime + base + depth + lead (`lead`: one display refresh — the animation frame draws for the
 * refresh after it). Each refresh shows the newest due picture (older ones are dropped); at most `maxQueue` wait. A
 * picture later than any depth could absorb (by more than `maxDepthMs` + a picture interval) is shown at once and left
 * out of the estimate; a delay `clockStepMs` below the base, or that far above it for `clockStepHoldMs`, starts the
 * estimate over. Without a macTime a picture shows at once; refine / keepalive pictures (`sample: false`) are due on
 * arrival and not sampled.
 *
 * Even pace (`evenPace`): a picture at most every `pace` refreshes, the largest n ≥ 1 with n × refresh ≤ content
 * interval + 0.15 × refresh (never slower than the content), changed once a new value held `paceHoldMs`, with a band of
 * `paceSlower` / `paceFaster` refreshes around the pace in use.
 *
 * Interactive (`interactive`: a finger on the picture, keys, the wheel — `Interactivity`): the depth drops to the
 * interactive depth = min(depth, `touchBudgetMs`, `interactiveCapMs`, picture interval + `marginMs`) and even pace is
 * off: a sampled picture is due at min(macTime + base + that, arrival + that) + lead; a later one (or a stall) shows on
 * the next refresh. Without a touch budget (the LAN), or an interactive depth under `minTouchBudgetMs`, pictures show on
 * arrival. Turned on, what waits is re-timed at once, so the next refresh shows the newest due picture and drops the
 * older ones (the queue catches up in one refresh). Turned off, the depth in use starts at the interactive depth and
 * rises to the smooth depth by at most `rampPerSecondMs` a second: each picture is held a little longer than the one
 * before, never a sudden freeze.
 *
 * A/V sync (`syncFloor`, `AVSync`): while watching, smooth pictures wait this much longer for the computer's sound (a
 * Bluetooth output's latency, a deeper sound buffer); the extra wait in use moves to it by at most `rampPerSecondMs`
 * either way, is 0 at once when interactive starts, and room is made in the queue for the pictures it holds.
 */
export interface PlayoutConfig {
    windowMs: number;
    minSamples: number;
    defaultDepthMs: number;
    marginMs: number;
    /** The cap (only binds on bad paths). */
    maxDepthMs: number;
    shrinkPerSecondMs: number;
    percentile: number;
    /** Room for `maxDepthMs` of pictures at 60 fps. */
    maxQueue: number;
    clockStepMs: number;
    clockStepHoldMs: number;
    paceHoldMs: number;
    paceSlower: number;
    paceFaster: number;
    /** Back from interactive: how fast the depth in use rises to the smooth depth (ms per second). */
    rampPerSecondMs: number;
    /** An interactive depth under this shows interactive pictures on arrival (nothing to even out). */
    minTouchBudgetMs: number;
    /** The interactive depth's ceiling. */
    interactiveCapMs: number;
}
export declare const DEFAULT_PLAYOUT: Readonly<PlayoutConfig>;
/** The cap off the local network (on 5G the jitter's p95 runs past 100 ms). */
export declare const REMOTE_MAX_DEPTH_MS = 200;
/** The depth before anything was measured, on the local network. */
export declare const LAN_DEFAULT_DEPTH_MS = 10;
/** A config with another cap, and room in the queue for that much at 60 fps (as 12 is for 100 ms). */
export declare function playoutConfig(over?: Partial<PlayoutConfig> & {
    capMs?: number;
}): PlayoutConfig;
/** Nearest-rank percentile (`p` in 0…1); undefined for no values. */
export declare function percentile(values: readonly number[], p: number): number | undefined;
/** The largest n ≥ 1 with n × refresh ≤ the content interval + 0.15 × refresh: never slower than the content. */
export declare function paceFor(contentMs: number, refreshMs: number): number;
/** The pace to move to from `current` (hysteresis, see above). */
export declare function paceFrom(contentMs: number, refreshMs: number, current: number, slower?: number, faster?: number): number;
/**
 * The automatic touch budget (one bound of the interactive depth, ms; null: on arrival): a quarter of the path's
 * minimum round trip (the latest ack answer's `net.rttMs.min`), at most 45 ms; without one, none on the LAN and 30 ms
 * elsewhere. Under 8 ms: none.
 */
export declare function touchBudgetMs(rttMinMs: number | null | undefined, onLan: boolean): number | null;
export type Placement = "now" | "queued";
/** The most the A/V sync makes smooth pictures wait (ms). */
export declare const MAX_SYNC_FLOOR_MS = 300;
export declare class Playout<P> {
    private readonly discard;
    readonly config: PlayoutConfig;
    /** The buffer's depth (ms). */
    depth: number;
    /** The smallest recent delay (null until the first sample). */
    base: number | null;
    /** Pictures dropped (never shown), in all. */
    dropped: number;
    /** Clock steps seen. */
    resets: number;
    /** The usual gap between the server's pictures (median of the window's, 1000/120…100 ms). */
    frameInterval: number;
    /** The content's pictures per second as an interval (mean gap up to 100 ms). */
    contentInterval: number;
    /** Even pace: refreshes per shown picture. */
    pace: number;
    /** The p95 of the window's delays above the base (null until `minSamples`). */
    jitter: number | null;
    /** The display's refresh period (ms; the page measures it from its animation frames). */
    lead: number;
    /** The most an interactive picture waits for its time (ms; null: on arrival). */
    touchBudget: number | null;
    private evenPaceOn;
    private interactiveOn;
    private paceCandidate;
    private nextShowAt;
    private samples;
    private seen;
    private depthAt;
    private highSince;
    private queue;
    private ramp;
    private syncFloorMs;
    private syncLevel;
    private syncAt;
    /** `discard`: called for each picture let go without being shown (a VideoFrame to close). */
    constructor(config?: Partial<PlayoutConfig>, discard?: (p: P) => void);
    get queued(): number;
    get evenPace(): boolean;
    /** Show at most one picture every `pace` refreshes; turned on mid-stream it takes the content's pace at once. */
    set evenPace(on: boolean);
    get interactive(): boolean;
    /** The A/V sync's extra wait for smooth pictures (ms, 0…MAX_SYNC_FLOOR_MS; see above). */
    get syncFloor(): number;
    set syncFloor(ms: number);
    /** The sync wait in use now (0 while interactive). */
    get syncHold(): number;
    private syncDepth;
    /** The user interacts (see above): the depth drops to the interactive depth, and what waits catches up at once. */
    set interactive(on: boolean);
    /** The interactive depth (ms; null: shown on arrival). */
    get interactiveDepth(): number | null;
    /** The interactive depth in use now (null: not interactive, or on arrival). */
    get touchBuffer(): number | null;
    private get touchDepth();
    private touchDue;
    /** Even pace: how far apart shown pictures are (null: off, or interactive). */
    get paceInterval(): number | null;
    /** How long an on-time picture waits (ms): depth + sync wait + lead; interactive: its depth + lead (0 on arrival); back from it,
     *  the ramp's depth + lead. */
    get hold(): number;
    private smoothDepth;
    /** A decoded picture. `macTime`: its `X-Frame-Time` (ms; null: none). `sample`: false for refine / keepalive. */
    push(picture: P, macTime: number | null | undefined, sample: boolean, arrival: number): Placement;
    private enqueue;
    private dropAll;
    /** The picture for a display refresh that appears at `target`: the newest one due by then (older ones are dropped);
     *  null = keep what's shown. */
    next(target: number): P | null;
    /** Keeps only the newest `keep` waiting pictures (the decoder is short of buffers); the rest count as dropped. */
    trim(keep: number): void;
    /** Lets go of what waits (the stream ended); not counted as dropped. */
    flush(): void;
    private updatePace;
    /** One delay into the estimate; false = too late for any depth (show it on arrival). */
    private observe;
    private restart;
}
/** What the page's stats line shows of the playout now. */
export interface PlayoutState {
    /** `smooth` (watching) or `responsive` (the user interacts, or the page asked for on-arrival playback). */
    mode: "smooth" | "responsive";
    /** How long an on-time picture waits now (ms). */
    holdMs: number;
    /** The smooth depth it is at / goes back to (ms). */
    depthMs: number;
    /** The interactive depth in use (ms; null: on arrival, or not interactive). */
    touchMs: number | null;
    jitterMs: number | null;
    capMs: number;
    queued: number;
    refreshHz: number | null;
    paceMs: number | null;
}
/** `smooth · buf 104 ms · depth 96 · jit 92 · cap 200` / `responsive · buf 29 ms · touch 21 ms · depth 96 · jit 92 ·
 *  cap 200` (numbers and units only: not localized). */
export declare function playoutLine(s: PlayoutState): string;
