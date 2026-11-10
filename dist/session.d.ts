import { ConnectionModel, Interactivity, NetSampler, type AudioState, type ControlDevice, type CursorPart, type DisplayState, type Input, type Phase, type ScreenLink } from "@yoyocontrol/screen-web";
import { type ScreenBackend, type ScreenRoute, type ScreenRouting, type ScreenStatus } from "./contracts.js";
/**
 * The Screen page's media without its views (iOS `ScreenSession`): the stream and its playback on screen-web's
 * `VideoStream` (drawn into the page's canvas), the sound (`ScreenAudio`) and the A/V sync between them
 * (`AVSyncDriver`), the way it goes (the backend's routing, if any: a stream about to open waits for a decision, moves
 * when the way changes, falls back when a shortcut fails; a way that is a uu Link session — `screenLink(route)` —
 * carries the pictures, the sound, input and control itself), the playout report's network part (`NetSampler`), the
 * connection state (`ConnectionModel`, from the stream's status parts, the states the status and events carry, and
 * gaps), reopening (`ReopenPolicy`), interactive playback (`Interactivity`), input with fallback, control, focus, and
 * the stats line (screen-web's `statsLines`).
 */
export interface SessionCallbacks {
    /** A picture was drawn (its size in pixels). */
    picture(width: number, height: number): void;
    cursor(part: CursorPart): void;
    /** A new stream opened: the pointer starts over. */
    streamOpened(): void;
    /** The connection phase may have changed. */
    connection(): void;
    /** The sound's button may have changed (shown, on / off). */
    audio(): void;
    /** The display is gone or the status may be stale: the page asks for it again. */
    refreshStatus(): void;
    /** Every error goes here first; true = handled. */
    handleError(error: unknown): boolean;
}
export interface SessionOptions {
    canvas: HTMLCanvasElement;
    /** Where the sound setting is kept (localStorage key; null: not kept). */
    audioKey: string | null;
}
/** The stream request's maximum width (docs/PROTOCOL.md: 3840). */
export declare const VIDEO_MAX_WIDTH = 3840;
export declare class ScreenSession {
    readonly backend: ScreenBackend;
    private readonly opts;
    private readonly cb;
    readonly routing: ScreenRouting | null;
    readonly interactivity: Interactivity;
    readonly connection: ConnectionModel;
    active: boolean;
    /** The display shown (undefined: the server's default). */
    display: number | undefined;
    displayIsMain: boolean;
    /** The display shown is a virtual one: its pictures don't carry same-instant times, so no A/V sync. */
    displayIsVirtual: boolean;
    /** This side's network for the playout report (route, path, input round trips, failures, bytes). */
    readonly net: NetSampler;
    /** The picture can be shown (the page says: the status allows it). */
    canShow: boolean;
    hasFrame: boolean;
    private video;
    /** The link the open stream is on (null: HTTP). */
    private streamLink;
    private streamRoute;
    private streamToken;
    private streamResponded;
    private delivered;
    private retryTimer;
    private openTimer;
    private decisionTimer;
    private decisionSince;
    private pendingOpen;
    private waitingToRetry;
    private waitingOnUnavailable;
    private connectionTimer;
    private readonly reopen;
    /** The last status the page gave (control over a link answers with the holder only). */
    private lastStatus;
    private readonly connectionInfo;
    private readonly pathChanged;
    private audioOnPref;
    private audio;
    private audioState;
    private audioRoute;
    private audioOffByServer;
    private audioGaveUp;
    private readonly sync;
    private inputLink;
    constructor(backend: ScreenBackend, opts: SessionOptions, cb: SessionCallbacks);
    get currentRoute(): ScreenRoute;
    /** The way requests go now (the stream's while one is open). */
    get way(): ScreenRoute;
    get link(): ScreenLink | null;
    newVisit(): void;
    activate(): void;
    /** The page stops: the stream, the sound, interactive playback. The way stays until `leaveRoute`. */
    deactivate(): void;
    leaveRoute(): void;
    /** The page is gone for good. */
    dispose(): void;
    statusChanged(s: ScreenStatus): void;
    statesChanged(states: DisplayState[], console: {
        locked: boolean;
    } | null | undefined): void;
    private isOurs;
    private reopenIfReady;
    /** Retry (the display was unavailable): ask again now, keeping the still. */
    retryConnection(): void;
    /** The phase now (and a timer for when it changes by itself). */
    phase(): Phase;
    updateConnection(): void;
    updateFrames(): void;
    /** Another display: the picture goes, and what was known of the last one's connection. */
    restartFrames(): void;
    stopFrames(): void;
    private dropStream;
    private openStream;
    private streamStatus;
    /** The open stream was answered (its response, or `video.opened` on a link): no open timeout. */
    private responded;
    private streamEnded;
    /** The route's HTTP transport with the stream's response and its acks watched (the routing). */
    private observed;
    private routeChanged;
    get audioOn(): boolean;
    /** The speaker shows (the computer has sound, this browser can play it). */
    get audioShown(): boolean;
    get audioPlaying(): AudioState;
    /** The speaker button (a user gesture: the AudioContext may start). */
    setAudioOn(on: boolean): void;
    /** A user gesture on the page: a sound that is on but couldn't start without one starts now. */
    gesture(): void;
    private syncAudio;
    /** Browsers start sound only after a gesture on the page; once one came, a reopen may start it by itself. */
    private audioUnlocked;
    private stopAudio;
    private audioChanged;
    /** A finger / button on the picture (in control). */
    touchBegan(): void;
    touchEnded(): void;
    keySent(): void;
    /** `op` on the way in use; when it fails, the routing may name another way to send it on (once). */
    private run;
    /**
     * The input sender of the way in use when it is a link (`InputQueueOptions.link`; null: HTTP, `deliver`). Refused
     * or unacknowledged input on it comes to `onInputError`.
     */
    linkInput(onInputError: (e: unknown) => void): ((input: Input) => void) | null;
    /** One input over HTTP on the way in use (its round trip goes into the network report), with the routing's fallback. */
    deliver(input: Input): Promise<void>;
    /**
     * Take or release control (`route`: the way a release goes on as the page goes). Over a link: `control.take` /
     * `control.release`, answered with the last status and the new holder.
     */
    control(controller: "user" | "none", device: ControlDevice, keepalive?: boolean, route?: ScreenRoute): Promise<ScreenStatus | null>;
    focus(): Promise<{
        editable: boolean;
    } | null>;
    /** An answer that means the way is down (the network report counts it). */
    isUnreachable(status: number, message: string | null): boolean;
    /**
     * The stats line (not localized; screen-web's `statsLines`, what iOS shows): codec, fps, KB/s, decode ms, the way,
     * the connection; the playout (gaps, hitches, stalls, buffer, jitter, drops) and the latency estimate; the link's
     * own line or the server's network grade; the sound. Each call starts a new window.
     */
    statsText(): string;
    private clearTimer;
}
