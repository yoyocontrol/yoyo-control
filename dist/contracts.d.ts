import type { ControlDevice, Controller, Display, DisplayState, Features, Input, ScreenLink, ScreenTransport } from "@yoyocontrol/screen-web";
/**
 * What the pages ask of one computer, and what the app around them decides: the web counterparts of the iOS kit's
 * `YoyoBackend`, `YoyoRouting`, `YoyoScreenLink` and `YoyoHost` (docs/PROTOCOL.md for every wire shape). The pages
 * don't know how the computer is reached: Yoyo Control's own web app reaches it over uu Link signaled through the
 * relay; another app may go through its own server. Every request names the route it goes on (a backend with one way
 * ignores it).
 */
/** A button the backend offers while the screen can't be shown (install or update what serves it…). */
export interface UnavailableAction {
    headline?: string;
    message?: string;
    title: string;
    url: string;
}
/** `GET /status` as the pages read it (docs/PROTOCOL.md「屏幕」). Unknown fields are ignored. */
export interface ScreenStatus {
    available: boolean;
    reason?: string | null;
    screenRecording: boolean;
    accessibility: boolean;
    displays: Display[];
    controller: Controller;
    controllerSince?: number | null;
    controllerDevice?: ControlDevice | null;
    states?: DisplayState[];
    console?: {
        locked: boolean;
    } | null;
    /** "mac", "linux", or another computer (named generically). */
    platform?: string | null;
    features?: Features | null;
    unavailableAction?: UnavailableAction | null;
}
/** What a computer's clipboard holds (docs/PROTOCOL.md「剪贴板」). */
export type ClipboardKind = "text" | "image" | "files" | "concealed" | "other" | "empty";
export interface ClipboardFile {
    name: string;
    size?: number | null;
    dir?: boolean;
}
/** The summary every client may see (the event, a preview row): never the text or the bytes. */
export interface ClipboardSummary {
    changeCount: number;
    kind: ClipboardKind | (string & {});
    preview?: string;
    size?: number | null;
    width?: number | null;
    height?: number | null;
    files?: ClipboardFile[];
    moreFiles?: number;
    /** When the computer first saw this item (ms since 1970). */
    at?: number;
    /** Who put it there: the computer itself (default), a phone / browser, or an agent. */
    source?: "mac" | "phone" | "agent" | (string & {});
}
/** `GET /clipboard`'s item: the summary plus, for text, the string itself. */
export interface ClipboardItem extends ClipboardSummary {
    text?: string;
    truncated?: boolean;
}
export interface ClipboardStatus {
    available: boolean;
    reason?: string | null;
    item?: ClipboardItem | null;
}
export interface ClipboardPutResponse extends ClipboardStatus {
    saved?: {
        name: string;
        path: string;
        size: number;
    }[];
}
/** One event of the computer the pages follow, in its wire shape (docs/PROTOCOL.md「事件」). */
export type ScreenEvent = {
    type: "screen.control";
    controller: Controller;
    controllerSince?: number | null;
    controllerDevice?: ControlDevice | null;
} | {
    type: "screen.state";
    states: DisplayState[];
    console?: {
        locked: boolean;
    } | null;
} | {
    type: "clipboard.changed";
    available?: boolean | null;
    item?: ClipboardSummary | null;
}
/** The computer's pairing window opened / closed: it never shows in a remote picture (the code stays on the screen). */
 | {
    type: "pairing";
    open: boolean;
};
/** One way a backend's requests reach the computer. */
export interface ScreenRoute {
    /** The backend's name for it. */
    id: string;
    /** The computer is on this device's local network: the playout's tighter local values. */
    isLocalNetwork: boolean;
    /** This browser reaches the computer itself, not through a tunnel / relay. */
    isDirect: boolean;
    /** A way that may stop working, next to one that always works: a stream on it that fails goes back at once. */
    isShortcut: boolean;
    /** For the stats line ("LAN", "link", "tunnel"); not localized. */
    label: string;
    /** What the network report says about it. */
    report: "lan" | "direct" | "tunnel";
}
/** The one way of a backend without routing. */
export declare const DIRECT_ROUTE: ScreenRoute;
/**
 * The ways of a backend with more than one, for one visit of the Screen page (iOS `YoyoRouting`): the page asks it
 * which way a stream goes, moves its stream and sound when the way changes, and reports what happened on a way.
 * `Connector` is a ready-made one.
 */
export interface ScreenRouting {
    readonly current: ScreenRoute;
    /** A better way is being tried: a stream about to open waits up to `decisionWaitMs` for it. */
    readonly isDeciding: boolean;
    readonly decisionWaitMs: number;
    /** A stream on a shortcut whose response hasn't come by then counts as failed there. */
    readonly openTimeoutMs: number;
    /** Set by the page: called whenever `current` or `isDeciding` changed. */
    onChange: (() => void) | null;
    newVisit(): void;
    activate(): void;
    streamWillOpen(): void;
    /** The page stopped (its last requests went out). */
    leave(): void;
    /** A stream on a shortcut failed, ended before its first picture or didn't answer in time; `unauthorized`: a 401. */
    streamFailed(route: ScreenRoute, unauthorized: boolean): void;
    /** An ack of a stream on `route` came back: its HTTP status, null when it failed on the way. */
    ackAnswered(route: ScreenRoute, status: number | null): void;
    /** A request on `route` failed: the way to send it again on now, or null to give up. */
    fallback(route: ScreenRoute, error: unknown): Promise<ScreenRoute | null>;
    /** The page is gone for good. */
    close?(): void;
}
/**
 * A way that carries the Screen page's media itself (a uu Link session, docs/LINK.md; iOS `YoyoScreenLink`) is
 * screen-web's `ScreenLink` (`@yoyocontrol/link-web`'s `linkScreen(session)` makes one): the pictures, the sound, the
 * pointer, input and control go over it, not as `/stream`, `/audio`, `/input` and `/control` requests. A backend whose
 * route is such a session hands it out with `ScreenBackend.screenLink(route)`. Re-exported here for backends that
 * only import this package.
 */
export type { ScreenLink, ScreenLinkAudio, ScreenLinkAudioEvent, ScreenLinkControlAnswer, ScreenLinkFrame, ScreenLinkFrameKind, ScreenLinkVideo, ScreenLinkVideoEvent, } from "@yoyocontrol/screen-web";
/** A file going to the computer's clipboard. */
export type ClipboardPut = {
    text: string;
} | {
    files: File[];
};
/**
 * Everything the pages ask of one computer (iOS `YoyoBackend`). Required: `cacheScope`, `status`, `transport`; the rest
 * have defaults (input and control through the transport's `/input` and `/control`) or hide what needs them (no
 * `clipboard`: no clipboard keys; no `focus`: the keyboard never comes up by itself).
 *
 * Errors: throw a `RequestError` (screen-web) for an answer that isn't 2xx — its `status` decides (401: the credential
 * no longer works; `ScreenHost.handleError` sees every error first).
 */
export interface ScreenBackend {
    /** Whose state this is (one computer): what the pages key what they remember by. */
    readonly cacheScope: string;
    /** What the computer most likely is before its status says ("mac" when absent). */
    readonly platformHint?: string;
    /** The way requests go when there is no routing. Default DIRECT_ROUTE. */
    readonly route?: ScreenRoute;
    status(): Promise<ScreenStatus>;
    /** The HTTP part of `route`: `/stream`, `/stream/ack`, `/audio`, `/frame` (and `/input`, `/control` by default). */
    transport(route: ScreenRoute): ScreenTransport;
    /** One input. Default: `POST /input` on the route's transport. */
    input?(input: Input, route: ScreenRoute): Promise<void>;
    /** Take ("user") or release ("none"); the status after it (null when `keepalive`: the page is going away). */
    setControl?(controller: "user" | "none", route: ScreenRoute, device: ControlDevice, keepalive: boolean): Promise<ScreenStatus | null>;
    /** Whether the focused element takes typing (the keyboard comes up by itself). */
    focus?(display: number | undefined, route: ScreenRoute): Promise<{
        editable: boolean;
    }>;
    /** Shows the permission prompts on the computer. */
    requestPermissions?(): Promise<ScreenStatus>;
    /** One JPEG of a display (the preview row). */
    frame?(display: number | undefined, maxWidth: number, quality: number): Promise<Blob>;
    clipboard?(): Promise<ClipboardStatus>;
    clipboardImage?(changeCount: number): Promise<Blob>;
    clipboardFile?(index: number, changeCount: number, progress: (fraction: number) => void): Promise<{
        blob: Blob;
        name?: string;
        mime?: string;
    }>;
    putClipboard?(put: ClipboardPut, progress: (fraction: number) => void): Promise<ClipboardPutResponse>;
    /** `putClipboard({ files })` works (Photos… / Files…). Default false. */
    readonly sendsClipboardFiles?: boolean;
    /** The largest file `putClipboard` takes (bytes). Default 95 MB. */
    readonly clipboardFileLimit?: number;
    /** The computer's events while a page shows; each call is a new subscription, ended by `return()`. */
    events?(): AsyncIterable<ScreenEvent>;
    /** The routing of one visit of the Screen page, for a backend with more than one way. */
    makeRouting?(): ScreenRouting | null;
    /** When `route` carries the media itself (uu Link): its `ScreenLink` (null: an HTTP way). Asked often: return the
     *  same object while the session lasts. */
    screenLink?(route: ScreenRoute): ScreenLink | null;
    /** An answer that means the way is down (a proxy couldn't reach the computer). Default: 502, 504, 520–527, 530. */
    isUnreachable?(status: number, message: string | null): boolean;
}
/** The default of `ScreenBackend.isUnreachable` (screen-web's). */
export { isUnreachableStatus } from "@yoyocontrol/screen-web";
export type Language = "en" | "zh-Hans";
/**
 * What the app around the pages decides (iOS `YoyoHost`): colours, words, what happens to an error, where settings are
 * kept, this device's id and name. Set it as the element's `host` property (or once with `setScreenHost`).
 */
export interface ScreenHost {
    /** CSS custom properties without the `--yoyo-` prefix (`{ accent: "#d97757" }`); see the README's list. */
    theme?: Record<string, string>;
    /** "light" / "dark" (default: the system's, `prefers-color-scheme`). */
    colorScheme?: "light" | "dark" | null;
    /** The pages' language (default: the browser's, `zh*` → zh-Hans, else English). */
    language?: Language | null;
    /** Any string, in the language in use, by its key (`strings.ts` lists them). */
    strings?: Partial<Record<string, string>>;
    /** The locale of numbers and dates (default: the language). */
    locale?: string | null;
    /** What to call automation that drives the computer ("Copied by <name>"; default: the generic words). */
    agentName?: string | null;
    /** The computer's name for the page's title (default: "Screen" / "Desktop"). */
    computerName?: string | null;
    /** Every error of the pages' requests goes here first; true = handled (the page says nothing more). */
    handleError?(error: unknown): boolean;
    /** Shows a short notice instead of the page's own toast. */
    toast?(text: string): void;
    /** The prefix of every localStorage key the pages read or write (`<ns>Audio`, `<ns>DeviceId`…). Default "Yoyo". */
    preferencesNamespace?: string;
    /** This device's id as the computer knows it (≤ 128 characters). Default: a random id kept in `<ns>DeviceId`. */
    deviceId?: string | null;
    /** This device's name for the other devices (default: "Chrome on Mac", "Safari on iPhone"). */
    deviceName?: string | null;
    /** The close button's action (default: none shown). */
    onClose?: (() => void) | null;
}
