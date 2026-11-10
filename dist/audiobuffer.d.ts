/**
 * The sound's jitter buffer, in two pure halves (the iOS kit's `ScreenAudioBuffer`, compacted):
 *
 * - `AudioJitter` (page thread) estimates the depth. Each packet's delay = arrival − its `X-Audio-Time` (ms) holds the
 *   clock offset plus the network delay; `base` = the smallest of the last `windowMs`, the delays above it are the
 *   jitter. The buffer's need is their p99 + `marginMs`, within the floor…`maxDepthMs` (`startDepthMs` until
 *   `minSamples` were seen). The floor is the route's (80 ms on a LAN, 120 ms elsewhere) plus a bump: each interruption
 *   (an underrun) raises it by `bumpStepMs` (at most `bumpMaxMs`), and it falls by `bumpDecayMs` every
 *   `bumpDecayEveryMs` without one. The depth is need + the output's latency + `leadMs`, or the A/V sync's depth when
 *   that is more (it moves at most `syncRateMsPerSec`). A packet's slot — when it should be heard — is macTime + base +
 *   depth. A delay `clockStepMs` below the base, or that far above it for `clockStepHoldMs`, starts the estimate over.
 * - `AudioScheduler` (the audio thread: its source runs inside the page's AudioWorklet) plays the packets. Playback starts
 *   at the first packet's slot (a packet more than `lateFrames` past its slot is late: dropped) and then runs sample by
 *   sample, packet after packet, without looking at the clock; a gap in `seq` is that many packets of silence (more than
 *   `maxConcealed`: playback starts over from the slots). Running dry is an underrun: it starts over at the next packet's
 *   slot. Sound fades in at a start and out as it runs dry. When playback runs `excessFrames` behind the slots for
 *   `excessHoldFrames` (the depth shrank, the computer's clock runs fast), `cutFrames` of a packet are dropped with a
 *   crossfade, at most every `cutEveryFrames`. More than `maxQueuedFrames` waiting drops the oldest and starts over.
 *
 * Times: the page's clock in ms (`performance.now()`) for `AudioJitter`; frames of the AudioContext for `AudioScheduler`.
 */
export interface AudioJitterConfig {
    windowMs: number;
    minSamples: number;
    startDepthMs: number;
    marginMs: number;
    floorMs: number;
    maxDepthMs: number;
    percentile: number;
    bumpStepMs: number;
    bumpMaxMs: number;
    bumpDecayMs: number;
    bumpDecayEveryMs: number;
    /** The output's own lead beyond its latency: a render quantum and the message to the worklet. */
    leadMs: number;
    syncRateMsPerSec: number;
    clockStepMs: number;
    clockStepHoldMs: number;
}
/** The floors by route. */
export declare const AUDIO_LAN_FLOOR_MS = 80;
export declare const AUDIO_REMOTE_FLOOR_MS = 120;
export declare function audioJitterConfig(lan: boolean, over?: Partial<AudioJitterConfig>): AudioJitterConfig;
export declare class AudioJitter {
    readonly config: AudioJitterConfig;
    /** The smallest recent delay (null until the first packet). */
    base: number | null;
    /** The buffer's own need (ms: jitter + margin within floor + bump … max). */
    need: number;
    /** The adaptive floor's bump (ms). */
    bump: number;
    /** The p99 of the window's delays above the base (null until `minSamples`). */
    jitter: number | null;
    /** The A/V sync depth in use (ms; null: none). */
    sync: number | null;
    resets: number;
    private samples;
    private seen;
    private highSince;
    private lastBumpAt;
    private syncGoal;
    private syncAt;
    constructor(config?: AudioJitterConfig);
    get floor(): number;
    /** A packet's delay (arrival − macTime) at `arrival`. */
    observe(delay: number, arrival: number): void;
    /** Playback was interrupted (an underrun): the floor goes up. */
    interruption(now: number): void;
    /** The A/V sync's delay goal (ms; null: none) — the depth giving it is `syncDepthFor`. */
    setSyncGoal(depthMs: number | null): void;
    /** The depth now (ms, from the slot's macTime + base): need + output latency + lead, or the sync depth when more. */
    depth(now: number, outputLatencyMs: number): number;
    private decayBump;
    private restart;
}
/** One decoded packet on its way to the speaker. */
export interface ScheduledPacket {
    /** Left and right samples (the same array twice for mono). */
    l: Float32Array;
    r: Float32Array;
    /** The context frame its first sample should be heard at (its slot). */
    at: number;
    /** `X-Audio-Seq` (or the link's aseq): a gap is lost packets. */
    seq: number;
    /** Its first sample's `X-Audio-Time` (ms; null: none). */
    macTime: number | null;
}
export interface AudioSchedulerConfig {
    rate: number;
    packetFrames: number;
    lateFrames: number;
    fadeFrames: number;
    maxConcealed: number;
    excessFrames: number;
    excessHoldFrames: number;
    cutFrames: number;
    crossfadeFrames: number;
    cutEveryFrames: number;
    maxQueuedFrames: number;
}
export declare function audioSchedulerConfig(rate?: number, packetFrames?: number): AudioSchedulerConfig;
/** The counters and state the worklet reports. */
export interface AudioSchedulerStats {
    playing: boolean;
    /** The macTime (ms) of the sample playing now (null: not playing, or no time). */
    playingMacTime: number | null;
    /** Frames queued ahead of the playhead (silence to conceal included). */
    bufferedFrames: number;
    underruns: number;
    late: number;
    overflow: number;
    concealed: number;
    cuts: number;
    cutFrames: number;
}
/**
 * The audio thread's half (see above). Self-contained on purpose — no imports, no module constants: its source is put
 * into the page's AudioWorklet as is (`AudioScheduler.toString()`).
 */
export declare class AudioScheduler {
    readonly config: AudioSchedulerConfig;
    queue: ScheduledPacket[];
    pos: number;
    playing: boolean;
    expectedSeq: number | null;
    concealLeft: number;
    fadeIn: number;
    /** The head packet's boundary was handled (its gap concealed, the cut decided). */
    entered: boolean;
    lagFrom: number | null;
    lastCut: number;
    cut: {
        left: number;
        skip: number;
    } | null;
    stats: AudioSchedulerStats;
    constructor(config: AudioSchedulerConfig);
    push(p: ScheduledPacket): void;
    /** Fills `l` / `r` (one render quantum) whose first sample is heard at context frame `frame`. */
    render(l: Float32Array, r: Float32Array, frame: number): void;
    buffered(): number;
    /** Not playing: drop what is past its slot, start when the head's slot comes. */
    start(f: number): boolean;
    /** A new packet starts: conceal a seq gap, cut when playback lags its slots. */
    atBoundary(f: number, head: ScheduledPacket): void;
}
