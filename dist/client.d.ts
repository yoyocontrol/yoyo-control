import { EventEmitter } from "node:events";
import { type RemoteMode } from "./app.js";
import { type RawResponse } from "./http.js";
import { type AppAx, type AppScreenshot, type AppWindowInfo, type FrameParams, type Hit, type Region, type StreamParams, type Windows } from "./params.js";
import type { AppStatus, Console, DisplayState, Focus, Input, InputResponse, ServerIdentity } from "./types.js";
/** What this client holds of a running child service (node's ChildProcess, or a stand-in in tests). */
export interface ChildHandle extends EventEmitter {
    kill(signal?: NodeJS.Signals): boolean;
}
/** Where a remote server answers, and the bearer token every request to it carries. */
export interface RemoteEndpoint {
    host: string;
    port: number;
    token: string;
}
export interface RemoteOptions {
    /** Its endpoint, the server started first when needed (RemoteMode says how). A LocalError (503) when it can't be had. */
    connect(mode: RemoteMode): Promise<RemoteEndpoint>;
    /** The `app` its `/status` names (with `api` in range). */
    app: string;
    /** A video stream is open (a viewer): what keeps the machine up meanwhile; the returned function lets go. */
    hold?(): () => void;
}
export interface AppOptions {
    /** The app's fixed socket (appSocketPath()). */
    socketPath: string;
    /** Loopback TCP instead of `socketPath` (tests). */
    endpoint?: {
        host: string;
        port: number;
    };
    /** Where people get the app (`install.url` of a not-installed / outdated LocalError). */
    downloadUrl: string;
    /** The installed Yoyo Control.app, or null (default: findApp). Called on every look: keep it cheap. */
    find?: () => string | null;
    /** Opens it in the background (default: openApp). */
    launch?: (path: string) => Promise<void>;
    /** How long an opened app may take to answer (default APP_LAUNCH_TIMEOUT_MS). */
    launchTimeoutMs?: number;
    /** The installed bundle's identity, to notice it was replaced (default: appStamp). */
    stamp?: (path: string) => string | null;
}
/** Log lines (the default writes them to the console with a "[yoyo]" prefix). */
export interface Logger {
    log(message: string): void;
    warn(message: string): void;
    error(message: string): void;
}
/** The texts of the failures a caller shows people as they are (override any to word them its own way). */
export interface Messages {
    /** Not on macOS (and no `remote`). */
    unsupportedPlatform: string;
    /** No `app` options and no child service found. */
    childMissing(looked: string): string;
    notInstalled(url: string): string;
    outdated(version: string | undefined, api: number, url: string, range: {
        min: number;
        max: number;
    }): string;
    tooNew(version: string | undefined, api: number, range: {
        min: number;
        max: number;
    }): string;
    /** An installed app was opened and never answered. */
    silentApp(path: string, url: string): string;
    /** stop() was called. */
    stopped: string;
}
export declare const defaultMessages: Messages;
export interface LocalClientOptions {
    /**
     * The child service's executable; null = none at all; undefined = the first existing of `childCandidates`, looked
     * up on every use (so one built later is found without a restart).
     */
    childPath?: string | null;
    childCandidates?: readonly string[];
    /** The child service's socket (`--socket`). */
    socketPath: string;
    /** Talk to the child over loopback TCP instead of `socketPath` (tests). */
    endpoint?: {
        host: string;
        port: number;
    };
    /** Starts the child (tests start an in-process stand-in); default: spawn the executable. */
    spawn?: (path: string, args: string[]) => ChildHandle;
    /** How long a fresh child may take to answer /status (default 5 s). */
    readyTimeoutMs?: number;
    /** Look for the Yoyo Control app first. Absent: child mode only. */
    app?: AppOptions;
    /** A server elsewhere over TCP; takes over from `app` / the child. */
    remote?: RemoteOptions;
    /** The `api` range this caller speaks (default API). */
    api?: {
        min: number;
        max: number;
    };
    platform?: NodeJS.Platform;
    now?: () => number;
    /** First retry delay of the `/events` subscription (doubling up to 10× this; default 1 s). */
    eventsRetryMs?: number;
    messages?: Partial<Messages>;
    log?: Logger;
    /** Every connection-state change, deduplicated (`since` ignored). */
    onState?: (states: DisplayState[], console: Console | null) => void;
    /** Every `{"type":"clipboard",…}` line of `/events`. */
    onClipboard?: (summary: Record<string, unknown>) => void;
    /** `{"type":"abort"}` on `/events`: the user stopped the automation (Esc); the indicator is off already. */
    onAbort?: (reason: string) => void;
    /** Every other `/events` line with a `type` (`control`, newer kinds), pings left out. */
    onEvent?: (line: Record<string, unknown>) => void;
    /** The server is gone or cannot be started (whenever the displays' state is made up here). */
    onGone?: () => void;
}
/** A /frame request: FrameParams, plus what an automation's view asks for. */
export interface FrameQuery extends FrameParams {
    /** Bundle ids shown as they are; every other app's windows are masked. Undefined = no masking. */
    visible?: readonly string[];
    /** `hide=`: apps that never show (docs/LOCAL-API.md「不让别人看到的 App」). */
    hide?: string;
    crop?: Region;
}
/** One /frame answer. `crop`: the region the server used (`X-Crop`), null when it did not crop. */
export interface Frame {
    jpeg: Buffer;
    width: number | null;
    height: number | null;
    display: number | null;
    crop: Region | null;
}
export declare class LocalClient {
    private readonly opts;
    private child;
    /** When the server in use answered first (ms). */
    private startedAt;
    /** Servers this client let go of itself (their exit is not a failure). */
    private readonly retired;
    private starting;
    private failures;
    private retryAt;
    private lastFailure;
    private stopped;
    private readonly now;
    private readonly platform;
    private readonly spawnChild;
    private readonly readyTimeoutMs;
    private readonly range;
    private readonly messages;
    private readonly log;
    private events;
    private eventsTimer;
    private eventsDelay;
    private eventsErrorLogged;
    private lastStates;
    private lastConsole;
    private stateSig;
    private serverIdentity;
    private remoteEndpoint;
    private remoteNext;
    private strangerLogged;
    private silentApp;
    private automation;
    private automationChain;
    constructor(opts: LocalClientOptions);
    /** The child service's executable to run now, or null. */
    childPath(): string | null;
    /** Why there can't be a server at all (known without asking one), or null. With `app` a missing app is only known by looking. */
    unavailableReason(): string | null;
    /** Without starting anything: a server may be had (one is in use, the app's socket or an installed app or a child is there). */
    maybeThere(): boolean;
    /** A server is in use (it answered and hasn't gone since). */
    get connected(): boolean;
    /** The server in use is the app or a remote one (not a child this client started). */
    get attached(): boolean;
    /** The server in use, as its `/status` said when it was found (null: none yet). */
    get identity(): ServerIdentity | null;
    /** The connection state last forwarded to onState. */
    get states(): DisplayState[];
    get console(): Console | null;
    /** The automation indicator was turned on here (setAutomation) and not off since (nor by the user's Esc). */
    get automationActive(): boolean;
    /** A server is in use; found (or started, after the backoff) when needed. */
    ensure(): Promise<void>;
    private connect;
    private appStamp;
    private isSilent;
    /**
     * A remote server: its endpoint (started when needed), then its `/status` must name the expected app with an API in
     * range. A known endpoint that refuses or is unreachable is started again once (`remoteFailure`); one that is only
     * slow is not touched. Failures are LocalErrors with the retry backoff.
     */
    private connectRemote;
    /** The app's `/status`, or a rejection when nothing answers there within PROBE_TIMEOUT_MS. */
    private appStatus;
    /** The app's socket answers as Yoyo Control with an API in range: use it (true). A LocalError when it is too old / too new. */
    private tryAttach;
    private attach;
    /** Open the installed app and use it once its socket answers (true); false when it never answers in time (remembered). */
    private launchAndAttach;
    private start;
    /** Lets go of the server in use on purpose (a child is stopped; the app is only let go of): the next use looks again. */
    release(): void;
    private retire;
    private watchEvents;
    private unwatchEvents;
    /** Read one subscription's NDJSON lines until it ends; then reconnect it (1 s → 10 s) while its server lives. */
    private readEvents;
    private eventLine;
    private applyStates;
    /** The server is gone (`helper-restart`) or cannot be started (`helper-down`, with retryAt): every last-known entry says so. */
    private synthesize;
    private failed;
    private appTarget;
    private target;
    private raw;
    private rawJson;
    /**
     * A request to the server, found first when needed; the response as it came (status, headers, the body still
     * streaming). A connection failure looks for the server again once; a remote server that refuses the token is
     * rekeyed once.
     */
    request(method: string, path: string, body?: unknown, signal?: AbortSignal, headers?: Record<string, string>): Promise<RawResponse>;
    /** `request` with a JSON answer (a non-2xx `{ error }` becomes a LocalError with the server's status, answerError). */
    json<T>(method: string, path: string, body?: unknown): Promise<T>;
    /**
     * GET /status, unchecked. Lifecycle on the way: an installed app that never answered was replaced since a child stood
     * in for it → that child goes (the next look opens the app); a child without Screen Recording older than
     * REFRESH_GRANT_MS goes (macOS caches the grant per process; the app restarts its own service for that).
     */
    status(): Promise<AppStatus>;
    /** One JPEG of a display (default the main one); `visible` masks every other app, `crop` is a region at full resolution. */
    frame(p: FrameQuery): Promise<Frame>;
    /** The apps and on-screen windows (GET /windows; `display`: only its windows). */
    windows(display?: number): Promise<Windows>;
    /** The app at a normalized point of a display (GET /hit). */
    hit(display: number, x: number, y: number): Promise<Hit>;
    /** One app's windows, front to back, off-screen and minimized ones too (GET /app/windows). */
    appWindows(bundleId: string): Promise<AppWindowInfo[]>;
    /** One window's picture (GET /app/screenshot), covered or on another Space or not. */
    appScreenshot(window: number, p?: {
        maxWidth?: number;
        quality?: number;
        hide?: string;
    }): Promise<AppScreenshot>;
    /** A window's actionable elements (GET /app/ax; 403 without Accessibility). */
    appAx(window: number, max?: number, hide?: string): Promise<AppAx>;
    /**
     * The video stream (multipart: H.264 / HEVC, cursor and status parts), not read yet: the caller pipes it; abort
     * `signal` to stop it. `accept`: the viewer's `Accept`, passed on, so the part names are the ones it understands.
     * A remote server's `hold` keeps its machine up while the stream is open.
     */
    stream(p: StreamParams, signal: AbortSignal, accept?: string): Promise<RawResponse>;
    /** The sound (`GET /audio`: Opus parts), not read yet: the caller pipes it. The server's error status passes through. */
    audio(signal: AbortSignal, accept?: string): Promise<RawResponse>;
    /** POST /input of a checked input (parseInput). */
    input(input: Input): Promise<InputResponse>;
    /**
     * A viewer's ack for a stream (checked: parseStreamAck) → POST /stream/ack. The answer as it is when it is a JSON
     * object (`{ ok, net? }`); anything else → `{ ok: true }`, with status 404 kept (no such stream: the viewer stops
     * acking), else 200.
     */
    ack(raw: unknown): Promise<{
        status: 200 | 404;
        body: Record<string, unknown>;
    }>;
    /** Whether the focused element takes typing (GET /focus). */
    focus(display?: number): Promise<Focus>;
    /** POST /permissions/request: the app asks the user for its missing grants. */
    requestPermissions(): Promise<void>;
    /**
     * The automation indicator (POST /automation: a border and "<label> is using this computer · press Esc to stop"),
     * in order, best effort: `true` may find the server first; `false` goes only to one in use. A server without the
     * route (404: an older Yoyo Control) gets POST /agent-control. A failure is logged. `automationActive` follows at once.
     */
    setAutomation(active: boolean, label?: string): void;
    /** The setAutomation calls so far have been answered. */
    automationSettled(): Promise<void>;
    /** Stops everything: no more requests; the automation indicator goes down on an app (it outlives this client); a child is stopped. */
    stop(): void;
}
