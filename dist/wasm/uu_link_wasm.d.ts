/* tslint:disable */
/* eslint-disable */

/**
 * The client side of a session's media (one per rtc session). See the module docs for the calling convention.
 */
export class ClientMedia {
    free(): void;
    [Symbol.dispose](): void;
    closeAudio(stream: number): void;
    closeVideo(stream: number): void;
    /**
     * The decoder's verdict on a delivered frame; `ok = false` asks for a key frame.
     */
    frameDecoded(stream: number, frame: number, ok: boolean): void;
    handleTimeout(now_us: number): void;
    /**
     * Whether video stream `stream` is open (by `openVideo`, `openProbe` or an early datagram).
     */
    hasVideo(stream: number): boolean;
    /**
     * Discrete input events waiting for an ack.
     */
    inputUnacked(): number;
    /**
     * Datagrams refused as malformed or on a channel this side doesn't receive.
     */
    malformed(): number;
    /**
     * A new media layer. `config` (every field optional, `undefined`: the defaults): `maxDatagram` (bytes),
     * `feedbackIntervalMs`, `feedbackIdleMs`, `audioReportIntervalMs`, `nackRepeatMs` (0: NACKs go once),
     * `inputMaxUnacked`.
     */
    constructor(config: any);
    /**
     * One datagram of channels 1–5 from the server (the `dgram` channel's message). False: malformed or not for
     * this side (counted in `malformed`).
     */
    onDatagram(bytes: Uint8Array | number[], now_us: number): boolean;
    openAudio(stream: number): void;
    /**
     * Opens `stream` for a speed test (docs/LINK.md「测速」): its frames never become `frame` events — each one is
     * acknowledged as decoded at once and counted (`probeStats`). `closeVideo` ends it.
     */
    openProbe(stream: number, now_us: number): void;
    /**
     * Start receiving video stream `stream` (before `video.open` goes: pictures may beat `video.opened`).
     */
    openVideo(stream: number): void;
    /**
     * The next event, or `undefined`:
     * - `{type: "frame", stream, frame, codec: "h264"|"hevc", kind, width, height, captureUs, recoveryBase,
     *   firstArrivalUs, deliveredUs, au: Uint8Array}` — decode it, then `frameDecoded`;
     * - `{type: "audio", stream, seq, timeUs, data: Uint8Array, recovered, gapBefore}`;
     * - `{type: "cursor", stream, cseq, json: string}`;
     * - `{type: "inputAcked", through}`, `{type: "inputFailed", seq}`.
     */
    pollEvent(): any;
    /**
     * When to call `handleTimeout` next (µs on the caller's clock; `undefined`: no timer needed).
     */
    pollTimeout(now_us: number): number | undefined;
    /**
     * The next datagram to send on `dgram`, or `undefined`. Call until `undefined` after every other call.
     */
    pollTransmit(now_us: number): Uint8Array | undefined;
    /**
     * A speed-test stream's counters (`undefined`: not one): `{frames, bytes, spanUs, meanBps, peakBps, finalBps,
     * finalFps}` (rates in bits/s; `null` = not enough yet).
     */
    probeStats(stream: number, now_us: number): any;
    /**
     * The decoder can't continue: a key frame.
     */
    requestKeyframe(stream: number): void;
    /**
     * Queues an input event (`/input`'s JSON): `move` = a pointer move (newest wins), else discrete (exactly once,
     * in order). Returns its seq; throws `"overflow"` (too many unacked: answer like HTTP 429) or `"too-large"`.
     */
    sendInput(now_us: number, json: string, move: boolean): number;
    /**
     * The transport's largest datagram now (bytes).
     */
    setMaxDatagram(n: number): void;
    /**
     * A round-trip sample from the transport (the selected candidate pair's RTT, ~every 100 ms).
     */
    setRtt(now_us: number, rtt_us: number): void;
    /**
     * The media layer's counters since the session started (camelCase [`MediaStats`]: `atUs`, `rttMinMs`,
     * `rttP50Ms`, `rttP90Ms`, `lossPct`, `mediaReceived`, `mediaMissing`, `fecRecovered`, `nackRecovered`, `nackSent`,
     * `framesDelivered`, `framesLost`, `framesSkipped`, `freezes`, `freezeMs`, `fps`, `inputP50Ms`, `inputP90Ms`,
     * `inputEvents`, `inputFailed`, `audioLossPct`, `audioLost`, `audioRecovered`; unknown values `null`).
     */
    stats(now_us: number): any;
    /**
     * Every frame's fate since the last call (for the playout report's `rx`, the server's per-frame trace):
     * `[{stream, frame, fate: "delivered"|"skipped"|"lost", kind, au, captureMs, firstMs, lastMs, completeMs,
     * decidedMs, shards, fec, retx, nacks}]` (ms on the media clock; `captureMs` the sender's wall clock).
     */
    takeRxTraces(): Array<any>;
}

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_clientmedia_free: (a: number, b: number) => void;
    readonly clientmedia_closeAudio: (a: number, b: number) => void;
    readonly clientmedia_closeVideo: (a: number, b: number) => void;
    readonly clientmedia_frameDecoded: (a: number, b: number, c: number, d: number) => void;
    readonly clientmedia_handleTimeout: (a: number, b: number) => void;
    readonly clientmedia_hasVideo: (a: number, b: number) => number;
    readonly clientmedia_inputUnacked: (a: number) => number;
    readonly clientmedia_malformed: (a: number) => number;
    readonly clientmedia_new: (a: any) => number;
    readonly clientmedia_onDatagram: (a: number, b: number, c: number, d: number) => number;
    readonly clientmedia_openAudio: (a: number, b: number) => void;
    readonly clientmedia_openProbe: (a: number, b: number, c: number) => void;
    readonly clientmedia_openVideo: (a: number, b: number) => void;
    readonly clientmedia_pollEvent: (a: number) => any;
    readonly clientmedia_pollTimeout: (a: number, b: number) => [number, number];
    readonly clientmedia_pollTransmit: (a: number, b: number) => [number, number];
    readonly clientmedia_probeStats: (a: number, b: number, c: number) => any;
    readonly clientmedia_requestKeyframe: (a: number, b: number) => void;
    readonly clientmedia_sendInput: (a: number, b: number, c: number, d: number, e: number) => [number, number, number];
    readonly clientmedia_setMaxDatagram: (a: number, b: number) => void;
    readonly clientmedia_setRtt: (a: number, b: number, c: number) => void;
    readonly clientmedia_stats: (a: number, b: number) => any;
    readonly clientmedia_takeRxTraces: (a: number) => any;
    readonly __wbindgen_exn_store: (a: number) => void;
    readonly __externref_table_alloc: () => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
