import type { AVSyncAudio } from "./avsync.js";
import type { ScreenLink } from "./link.js";
import type { AudioStats } from "./stats.js";
import type { ScreenTransport } from "./transport.js";
import type { AudioReport } from "./types.js";
/**
 * The computer's sound on a screen page (docs/PROTOCOL.md「声音」): Opus packets (20 ms, 48 kHz stereo) — `POST /audio`
 * through the page's transport in the stream's multipart framing, or `audio.open` on a link (`ScreenAudioOptions.link`)
 * — → WebCodecs' AudioDecoder → a timed jitter buffer in an AudioWorklet (`AudioJitter` + `AudioScheduler`): each packet
 * is heard at its slot (its `X-Audio-Time` + the measured base delay + the depth), a gap in its seq is concealed with
 * silence, the depth follows the path's jitter and the A/V sync (`AVSyncDriver`). A browser without AudioDecoder or
 * AudioWorklet has no speaker. 404 / 403 / 501 = no sound here (not asked again this visit), 503 = can't capture now
 * (asked again in 30 s), any other end reopens (AudioPolicy).
 */
export declare const hasAudioDecoder: () => boolean;
/** What the speaker shows. */
export type AudioState = "off" | "starting" | "playing" | "waiting" | "none";
/** The buffer's start depth on a remote path (ms; the LAN starts at `AUDIO_LAN_FLOOR_MS`). */
export declare const TARGET_MS = 120;
/** `X-Audio-Video-Offset` when the server doesn't say (ms). */
export declare const DEFAULT_VIDEO_OFFSET_MS = 31;
/** `X-Audio-Cookie` as an Opus description: only an OpusHead (else the decoder's defaults for 48 kHz stereo). */
export declare function opusDescription(cookie: string | null): Uint8Array | undefined;
/** `X-Audio-Video-Offset` (ms, may be negative); missing, garbled or beyond ±2 s: DEFAULT_VIDEO_OFFSET_MS. */
export declare function videoOffsetMs(value: string | null | undefined): number;
export interface ScreenAudioOptions {
    /** The way in use carries the media itself: the sound opens on it (`audio.open`) instead of `POST /audio`. Asked at
     *  each open (the way may change between two). */
    link?: () => ScreenLink | null;
    /** The path is the local network: the buffer's lower floor (asked at each open; default: a link's
     *  `isLocalNetwork`, else false). */
    lan?: () => boolean;
}
export declare class ScreenAudio implements AVSyncAudio {
    private readonly transport;
    private readonly onState;
    private readonly options;
    private ctx;
    private node;
    private decoder;
    private ctrl;
    private linkStream;
    private timer;
    private readonly policy;
    private on;
    private gaveUp;
    private ts;
    private generation;
    private readonly pending;
    private jitter;
    private lan;
    private offset;
    private worklet;
    private lastUnderruns;
    private soundAt;
    private bytes;
    private syncReport;
    private reported;
    private seq;
    /** `options` (additive): a link to open the sound on, the route's floor. */
    constructor(transport: ScreenTransport, onState: (s: AudioState) => void, options?: ScreenAudioOptions);
    get given(): boolean;
    /** Turn the sound on: call it from a click (the AudioContext needs a user gesture). */
    start(): Promise<void>;
    /** Turn it off (the stream closes; the context is kept for the next start). */
    stop(): void;
    /** The page is gone. */
    dispose(): void;
    /** The stats line's numbers (`audioStatsLine`). */
    stats(now?: number): AudioStats;
    /** The playout report's `audio` (counts since the previous call); null while nothing plays. */
    report(now?: number): AudioReport | null;
    /** The sound's delays for `AVSync` (ms, this clock − the computer's, aligned to the pictures' times by the offset). */
    syncDelays(now?: number): {
        delay: number | null;
        ownDelay: number | null;
        soundRecent: boolean;
    } | null;
    setSyncDelayGoal(goalMs: number | null): void;
    setSyncReport(skewMs: number | null, floorMs: number | null): void;
    private giveUp;
    private closeStream;
    /** A new stream: the buffer's estimate starts over on another route (the same route keeps what it learned). */
    private begin;
    private decoderFailed;
    private open;
    private openLink;
    /** The stream ended by itself: the policy says whether and when to open again. */
    private ended;
    /** One Opus packet: its delay into the estimate, then the decoder (its slot is set when it comes out). */
    private packet;
    private play;
    private fromWorklet;
    private depthNow;
    /** The output's latency: what a sample takes from the worklet to the speaker (ms). */
    private outputLatencyMs;
    /** The context frame heard at page time `t` (ms). */
    private frameAt;
    /** The page time (ms) context frame `frame` is heard at. */
    private timeOf;
    /** Heard now − the macTime of the sample heard now (ms; null: not playing). */
    private playingDelay;
    private kbps;
}
