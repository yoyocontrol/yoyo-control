import type { NetQuality, PlayoutReport } from "./types.js";
/**
 * The screen page's stats line (three fingers on iOS): what the iOS kit's `ScreenSession.statsText` shows, as data and
 * a formatter. Numbers, units and protocol codes only: never localized, nothing for a page to translate.
 *
 * ```
 *  h264 · 60 fps · 412 KB/s · 2.1 ms · link lan · live ready
 *  smooth · 60 Hz · gap 17/18 · arr 16/24 · hitch 0.0/s · stall 0.0/0.0/s · buf 28 ms · jit 24 · cap 100 · drop 0.5/s · ~62 ms
 *  lan wifi rtt 0.4/1.2/2.0 ms loss 0.0 % …            (a link's own line; else the server's grade: net good · rtt 9/12)
 *  audio 120 ms (buf 118) · 0 underruns · 0 drops · 96 kbps
 * ```
 */
/** The stream's numbers over the window since the previous snapshot (`VideoStream.stats()`). */
export interface StreamStatsSnapshot {
    /** `h264` (`-` before the first picture). */
    codec: string;
    /** Pictures drawn per second. */
    fps: number;
    kilobytesPerSecond: number;
    /** Average decode time of the window's pictures (null: none decoded). */
    decodeMs: number | null;
    /** The playout of the last few seconds (null: nothing drawn). */
    playout: PlayoutReport | null;
    /** The playout is responsive right now (the user interacts). */
    interactive: boolean;
    /** The server's latest grade of the stream's network (null: none; on a link: none, the link's line stands in). */
    net: NetQuality | null;
    /** The input's way to the computer: p50 of the input round trips (ms; null: none answered). */
    inputRttP50Ms: number | null;
    /** The freshest round trip of the stream's path (ms; the ack answers' or the link's min; null: none). */
    rttMinMs: number | null;
}
/** `h264 · 30 fps · 412 KB/s · 2.1 ms` (`· live` while interactive). */
export declare function streamLine(s: Pick<StreamStatsSnapshot, "codec" | "fps" | "kilobytesPerSecond" | "decodeMs" | "interactive">): string;
/** The playout report's line: `smooth · 60 Hz · pace 33 · gap 33/41 · arr 33/52 · hitch 0.3/s · stall 0.3/0.0/s ·
 *  buf 28 ms · jit 24 · cap 100 · drop 0.5/s`; interactive: `responsive · … · touch 21 ms`. */
export declare function playoutReportLine(r: PlayoutReport): string;
/** The computer's part of a touch's way (capture 14 + encode ~12 + write, ms). */
export declare const LATENCY_COMPUTER_MS = 30;
/**
 * How long a touch takes to show here (ms; null: no round trip known), as the iOS kit's `ScreenLatencyEstimate`: the
 * input's way (half the input round trip's p50; half the path's min while no input was answered), the computer's part,
 * the picture's way back (half the path's min; half the input p50 without one), the playout's hold, the decode and one
 * refresh.
 */
export declare function latencyEstimate(o: {
    inputRttP50Ms: number | null;
    rttMinMs: number | null;
    holdMs: number | null;
    decodeMs: number | null;
    refreshHz: number | null;
}): number | null;
/** The sound's stats (`ScreenAudio.stats()`). */
export interface AudioStats {
    /** The depth asked for and what is buffered now (ms; null: not playing yet). */
    depthMs: number | null;
    bufferedMs: number | null;
    underruns: number;
    /** Packets dropped (late, or over the queue's cap). */
    drops: number;
    kbps: number;
}
/** `audio 120 ms (buf 118) · 0 underruns · 0 drops · 96 kbps` (`audio · 96 kbps` before it plays). */
export declare function audioStatsLine(a: AudioStats): string;
/** What `statsLines` puts together. */
export interface StatsLineInput {
    stream: StreamStatsSnapshot;
    /** The way: a link's `pathLabel` (`link lan`), else the host's name for its route (`tunnel`, `lan`…). */
    way: string;
    /** The connection's codes (`ConnectionModel.statsText`): `live ready`, `reconnecting helper-restart · locked`. */
    connection: string;
    /** A link's own line (`ScreenLink.statsLine`): in place of the server's grade. */
    linkLine?: string | null;
    /** The sound, while a sound stream is open. */
    audio?: AudioStats | null;
}
/** The stats line's rows (1–4): stream · way · connection; playout · latency; the network; the sound. */
export declare function statsLines(i: StatsLineInput): string[];
