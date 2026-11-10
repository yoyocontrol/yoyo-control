import type { ClientMediaEngine, MediaCounters, MediaEvent, ProbeCounters, RxTrace } from "./wasm.js";
/**
 * A session's media layer, driven (docs/LINK.md「媒体」): the `dgram` channel's media datagrams (channels 1–5) go
 * into the wasm `ClientMedia`, what it hands out goes back on `dgram`, its events go to the listeners, and one timer
 * runs at its `pollTimeout`. Every call runs the loop once (there may be datagrams or events now). Main thread; the
 * wasm calls are cheap.
 */
export declare class LinkMedia {
    private readonly engine;
    private readonly send;
    readonly now: () => number;
    private readonly listeners;
    private timer;
    private timerAt;
    private pumping;
    private ended;
    private usedFlag;
    /**
     * `send`: one datagram onto `dgram` (false: dropped, counted by the session). `now`: the media clock in µs
     * (monotonic; the session's `performance.now()`-based one).
     */
    constructor(engine: ClientMediaEngine, send: (datagram: Uint8Array) => void, now: () => number);
    /** Media flowed (a stream opened, a datagram, an input): `link.stats` gets the media fields. */
    get used(): boolean;
    /** Hears every media event, in order; returns the unsubscribe. */
    onEvent(listener: (e: MediaEvent) => void): () => void;
    /** A datagram of channels 1–5 from the server. False: the media layer refused it (malformed / not for this side). */
    datagram(bytes: Uint8Array): boolean;
    /** The transport's facts: the selected path's RTT (ms) and the largest datagram. */
    setTransport(rttMs: number | null, maxDatagram: number): void;
    /** Start receiving video stream `stream` (call before `video.open`: pictures may beat `video.opened`). */
    openVideo(stream: number): void;
    closeVideo(stream: number): void;
    openAudio(stream: number): void;
    /** The media layer has the speed test's receiving side (docs/LINK.md「测速」). */
    get canProbe(): boolean;
    /** The highest video stream id not open (null: none, or no speed test in this build). */
    freeVideoStream(): number | null;
    /** Opens `stream` for a speed test: its frames are acknowledged and counted inside, never events. */
    openProbe(stream: number): void;
    /** A speed-test stream's counters (null: not one). */
    probeCounters(stream: number): ProbeCounters | null;
    closeAudio(stream: number): void;
    /** The decoder took (`ok`) or failed on a frame (`ok = false` asks for a key frame). */
    frameDecoded(stream: number, frame: number, ok: boolean): void;
    /** The decoder can't go on: a key frame. */
    requestKeyframe(stream: number): void;
    /**
     * One input event (`/input`'s JSON): `move` = a pointer move (the newest wins), else discrete (exactly once, in
     * order). Returns its seq. Throws `LinkRequestError(429)` when too many discrete events wait for their ack, and
     * `LinkError("closed")` after the session ended.
     */
    sendInput(json: string, move: boolean): number;
    /** Discrete input events waiting for an ack. */
    get inputUnacked(): number;
    /** The counters since the session started (null after it ended). */
    counters(): MediaCounters | null;
    /** Every frame's fate since the last call. */
    takeRxTraces(): RxTrace[];
    /** Malformed datagrams so far. */
    get malformed(): number;
    /** The session ended: no more calls, the wasm memory goes. */
    end(): void;
    private call;
    /** Datagrams out, events out, the timer re-armed. Re-entrant calls (a listener calling back in) fold into this one. */
    private pump;
    private arm;
}
