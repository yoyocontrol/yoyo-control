import type { Interactivity } from "./interaction.js";
import { type PlayoutState } from "./playout.js";
import type { AVSyncVideo } from "./avsync.js";
import { type ScreenLink } from "./link.js";
import { type NetSampler } from "./net.js";
import type { StreamStatsSnapshot } from "./stats.js";
import type { ScreenTransport } from "./transport.js";
import type { AudioReport, CursorPart, NetReport, StreamAckResponse, StreamStatusPart } from "./types.js";
/**
 * One video stream of a screen page (docs/PROTOCOL.md「视频流、确认与客户端指针」), on WebCodecs: `POST /stream` through
 * the page's transport (ScreenTransport), its multipart parts parsed as they come; each whole picture
 * part is acked before it is decoded (AckSender); H.264 access units go to a VideoDecoder as AVCC samples (the avcC
 * from the key picture's SPS / PPS). Every picture is decoded as it comes; decoded pictures wait in the smooth playout
 * (`Playout`, 「客户端的平滑播放」) and an animation frame draws the newest due one (the ones it passes are closed
 * undrawn). While the page's `Interactivity` is on (a finger, keys, the wheel) the playout's depth drops to about one
 * picture interval and what waits catches up at once. `playout: "arrival"` draws each picture on the next animation
 * frame instead. A decoder error or a missing key picture asks for one (on the next ack). A playout report rides on an
 * ack every 2 s.
 *
 * Over a link (`VideoOptions.link`, docs/LINK.md「会话协议」): `video.open` with the same parameters as a query (no
 * `ack`), each picture straight to the decoder (the link's media layer repairs, orders and paces them: no parts, no
 * acks), the decoder's verdict back per picture (`decoded`), a key picture request on the link, the report on the link
 * every 2 s; the link's round trip stands in for the ack answers' (the touch budget), its `isLocalNetwork` for the LAN.
 */
export interface VideoCallbacks {
    /** A decoded picture was drawn (its pixel size). */
    onPicture: (width: number, height: number) => void;
    onCursor: (part: CursorPart) => void;
    onStatus: (part: StreamStatusPart) => void;
    /** The stream ended: `delivered` = it drew pictures; `status` = the HTTP status of a refused open (else null). */
    onEnd: (info: {
        delivered: boolean;
        failed: boolean;
        lifetimeMs: number;
        status: number | null;
        error: string | null;
    }) => void;
    /** An ack's network grade (when the server gives one). */
    onNet?: (net: NonNullable<StreamAckResponse["net"]>) => void;
    /** A link stream was opened (`video.opened`): what `/stream`'s response headers would have said (`X-Display`…). */
    onOpened?: (headers: Record<string, string>) => void;
}
export interface VideoOptions {
    /** How the stream, its acks and its reports reach the server (not needed with `link`). */
    transport?: ScreenTransport;
    /** The way carries the media itself (a uu Link session): the stream opens on it instead of `POST /stream`. */
    link?: ScreenLink;
    /** This side's network for the report's `net` (route, path, input round trips, failures, bytes): the page's sampler,
     *  shared with its input. Without one the report says only the route, the bytes and the ack failures. */
    net?: NetSampler;
    /** The sound's part of the report (`ScreenAudio.report`), while a sound stream is open. */
    audioReport?: () => AudioReport | null;
    display?: number;
    canvas: HTMLCanvasElement;
    /** The stream request's fields beyond the defaults (a test panel's `maxKbps`…). */
    extra?: Record<string, unknown>;
    /** The path the reports say the stream takes (default "tunnel"; on a link "lan" when it is local, else "direct"). */
    route?: NetReport["route"];
    /** No byte for this long (ms) = a half-open stream: it ends as failed (and the page reopens it). Default STALL_MS. */
    stallMs?: number;
    /** "smooth" (default): the jitter buffer with its responsive mode; "arrival": each picture as soon as it is decoded. */
    playout?: "smooth" | "arrival";
    /** The page's interaction state (a finger on the picture, keys…): the playout is responsive while it is on. */
    interactivity?: Interactivity;
    /** The smooth buffer's cap (ms). Default: 100 on the LAN (`route: "lan"`), REMOTE_MAX_DEPTH_MS elsewhere. */
    maxDepthMs?: number;
    /** The codecs to ask for, in preference order (default `preferredCodecs()`: HEVC first where this browser decodes it
     *  in hardware, as the iOS app does; H.264 always). */
    codecs?: VideoCodec[];
}
export type VideoCodec = "hevc" | "h264";
/** Whether this browser decodes the Mac's HEVC in hardware (WebCodecs `isConfigSupported`, asked once). */
export declare function hevcDecodable(): Promise<boolean>;
/** The codecs a stream asks for by default: `hevc,h264` where HEVC decodes here (and hasn't failed in this page), else `h264`. */
export declare function preferredCodecs(): Promise<VideoCodec[]>;
/** An ack answer's round trip gives the touch budget for at most this long (ms). */
export declare const FRESH_RTT_MS = 10000;
/** The decoder has this many chunks waiting while pictures wait in the playout: it may be short of output buffers
 *  (some hold only a few frames), so the playout lets go of all but the newest. */
export declare const DECODER_PRESSURE = 3;
/** The link's round trip goes into the touch budget this often (ms). */
export declare const LINK_RTT_EVERY_MS = 1000;
/** More pictures than this waiting in the decoder, the oldest for longer than DECODER_BEHIND_MS (ms): it can't keep up,
 *  and the stream starts over from a key picture. */
export declare const DECODER_QUEUE_MAX = 8;
export declare const DECODER_BEHIND_MS = 500;
/** The server sends at least a keepalive picture every 5 s: three of them missing is a dead stream. */
export declare const STALL_MS = 15000;
/** Decode start times of pictures that never came out (a reset, a close) are forgotten after this long. */
export declare const ENQUEUED_MAX_AGE_MS = 2000;
/** Drops the entries of `map` (value = when, ms) older than `maxAge` at `now`. */
export declare function pruneOlder(map: Map<number, number>, now: number, maxAge: number): void;
/** The browser can decode the stream (WebCodecs' VideoDecoder). */
export declare const hasVideoDecoder: () => boolean;
/** A stream id: 8–64 of [A-Za-z0-9_-]. */
export declare function streamId(): string;
export declare class VideoStream implements AVSyncVideo {
    private readonly opts;
    private readonly cb;
    readonly id: string;
    private readonly ctrl;
    private readonly acks;
    private decoder;
    private config;
    private needKey;
    private keyAskedAt;
    private failures;
    /** A picture to draw on the next animation frame (on arrival). */
    private latest;
    private raf;
    private ts;
    private readonly enqueued;
    private readonly meta;
    private readonly playout;
    private readonly smooth;
    private readonly onLan;
    /** The animation frames' recent periods (their median is the playout's lead) and the last one's time. */
    private periods;
    private lastRaf;
    /** The latest ack answer's minimum round trip, and when it came. */
    private rtt;
    private unsubscribe;
    private delivered;
    private ended;
    private readonly openedAt;
    private reportTimer;
    private watchdog;
    private lastData;
    /** Why the stream was aborted from inside: no data (a stall), or an ack's status that ends it. */
    private abortedFor;
    private bytes;
    private ackFailures;
    private lastReportAt;
    private readonly meter;
    private readonly drawn;
    private readonly route;
    private linkVideo;
    private linkRttAt;
    private codecName;
    /** What `streamBody` asks for (set by `run`). */
    private codecs;
    /** A picture came out of the decoder in this stream. */
    private decodedAny;
    private quality;
    private statsSince;
    private statsPictures;
    private statsBytes;
    private statsDecode;
    constructor(opts: VideoOptions, cb: VideoCallbacks);
    /** Responsive (on) or smooth (off) playout; the page's `interactivity` calls it, or the page itself. */
    setInteractive(on: boolean): void;
    /** The playout now (a stats line: `playoutLine`). */
    playoutState(): PlayoutState;
    /** The playout responds at once (the user interacts). */
    get interactive(): boolean;
    /** The A/V sync's extra wait for smooth pictures (ms; `AVSyncDriver` sets it). */
    get syncFloor(): number;
    set syncFloor(ms: number);
    /** For the A/V sync: the smooth video delay without the floor (base + depth + 2 refreshes) and the one in use (base +
     *  hold + a refresh), ms on this clock − the computer's; null without smooth playout or before it measured. */
    syncDelays(): {
        smooth: number;
        shown: number;
    } | null;
    /** The stats line's numbers since the previous call (`statsLines`): the window's pictures, bytes and decodes, the
     *  playout of the last few seconds, the network grade (an ack's; none on a link) and the round trips known. */
    stats(now?: number): StreamStatsSnapshot;
    /** Opens the stream and reads it until it ends or `close()`. */
    run(): Promise<void>;
    /** The stream's parameters (`POST /stream`'s body; a link's `video.open` query without `ack`). */
    private streamBody;
    /** The stream on a link, until it ends or `close()`. */
    private runLink;
    /** A link picture: straight to the decoder; now and then the link's round trip into the touch budget. */
    private linkFrame;
    private received;
    /** Stops the stream (the page left, another display). No onEnd. */
    close(): void;
    /** Ends the stream from inside (a stall, an ack the server refused for good): run() reports it as failed. */
    private abortFor;
    private finish;
    private teardown;
    private part;
    private requestKey;
    /** Into the decoder; false when it couldn't take it (no decoder yet, waiting for a key picture, a reset). */
    private decode;
    /** How long the oldest picture still in the decoder has waited (ms; 0: none). */
    private oldestWaiting;
    private configure;
    private decodeFailed;
    private output;
    private schedule;
    /** On an animation frame at `t`: the picture on arrival, else the playout's newest due one for the refresh after. */
    private draw;
    private countDropped;
    private sendAck;
    /** The latest round trip if it is at most FRESH_RTT_MS old (ms; null: none). */
    private freshRtt;
    /** The touch budget follows the latest fresh round trip (and falls back once it is too old). */
    private updateTouchBudget;
    private ackFailed;
    /** The meter's report with the playout's own fields (ms, unrounded); null when nothing was drawn lately. */
    private playoutReport;
    /** The playout report of the last few seconds: on the next ack, or on the link. */
    private report;
}
/** One frame for a preview (a list row, the page before the stream): `GET /frame` as an object URL (null on failure). */
export declare function fetchFrame(transport: ScreenTransport, display: number | undefined, maxWidth: number, signal?: AbortSignal): Promise<{
    url: string;
    width: number;
    height: number;
} | null>;
