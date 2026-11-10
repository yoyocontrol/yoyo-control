import { type Features, type Focus, type Input, type StreamAck } from "./types.js";
/** A POST /input body, validated (400 LocalError otherwise). Coordinates are clamped to the display. */
export declare function parseInput(raw: unknown): Input;
/** Query of /frame and /stream, clamped: display id, max width (px), JPEG quality, frames per second. */
export interface FrameParams {
    display?: number;
    maxWidth?: number;
    quality?: number;
    fps?: number;
}
/** FrameParams from a parameter lookup (a URL query's `get`, a JSON body's fields): clamped; not a number → 400. */
export declare function parseFrameParams(get: (name: string) => unknown): FrameParams;
/** /stream's parameters (docs/PROTOCOL.md「视频流、确认与客户端指针」): FrameParams plus the video-stream ones. */
export interface StreamParams extends FrameParams {
    /** Known tokens of the client's list, in its order (left out when it listed only unknown ones: the server serves h264). */
    codecs?: string;
    stream?: string;
    ack?: 1;
    cursor?: "client";
    /** Status parts (「连接状态」); a server without them ignores it. */
    status?: 1;
    /** The video bit rate's ceiling (kbit/s, an integer 100…100000; testing only); a server without it ignores it. */
    maxKbps?: number;
}
export declare const STREAM_CODEC_TOKENS: readonly string[];
/** A client-chosen stream id. */
export declare const STREAM_ID: RegExp;
export declare function parseStreamParams(get: (name: string) => unknown): StreamParams;
/** The largest stream ack body worth reading (bytes); a proxy answers 413 above it. */
export declare const ACK_BODY_MAX: number;
/**
 * A POST /stream/ack body (400 LocalError otherwise): `stream`, `seq` and `keyframe` checked; `report` passed on as it
 * came when it is a JSON object (else dropped) — the server decodes it leniently.
 */
export declare function parseStreamAck(raw: unknown): StreamAck;
/** The /focus answer (anything odd = not editable; a role of at most 64 characters). */
export declare function parseFocus(raw: unknown): Focus;
/** `/status.features`: its boolean entries (an open set), null when it has none. */
export declare function parseFeatures(raw: unknown): Features | null;
/** An app as the server names it (GET /windows, GET /hit). */
export interface AppRef {
    pid: number;
    bundleId: string | null;
    /** As the system shows it (localized). */
    name: string;
    /** The app's English name, when the server knows one that differs from `name` ("Notification Center" for "Notification Centre"). */
    englishName?: string;
}
/** An app with on-screen windows (the desktop, Dock and menu bar fold into Finder), front to back. */
export interface AppInfo extends AppRef {
    windows: number;
}
/** An on-screen window, front to back; x / y / w / h normalized 0…1 on its display. No title (it leaks content). */
export interface WindowInfo {
    pid: number;
    display: number;
    x: number;
    y: number;
    w: number;
    h: number;
    layer: number;
}
/** GET /windows: the apps, the windows (of `display` when asked), the app taking keyboard input (null: unknown). */
export interface Windows {
    apps: AppInfo[];
    windows: WindowInfo[];
    focused: AppRef | null;
}
/** Which part of the menu bar a /hit point is (newer services; absent outside the menu bar). */
export type MenuBarArea = "appleMenu" | "appMenu" | "statusItem" | "bar";
/** GET /hit: the app owning the frontmost window at a point, null = none. */
export interface Hit {
    app: AppRef | null;
    layer: number | null;
    /** In the menu bar: which part (the app is that part's: a status item's app, the Apple menu, an app's menu, the frontmost app). */
    menuBar?: MenuBarArea;
}
/** A normalized region (0…1) of a display. */
export interface Region {
    x: number;
    y: number;
    w: number;
    h: number;
}
/** One AppRef of an answer, or null when it is not one (no pid / name). */
export declare function parseAppRef(raw: unknown): AppRef | null;
/** GET /windows, leniently (odd entries dropped); not an object at all → a 502. */
export declare function parseWindows(raw: unknown): Windows;
/** GET /hit, leniently. */
export declare function parseHit(raw: unknown): Hit;
/** GET /app/windows: one window of an app, front to back; x / y / w / h normalized 0…1 on its display. */
export interface AppWindowInfo {
    /** The CGWindowID. */
    id: number;
    display: number;
    x: number;
    y: number;
    w: number;
    h: number;
    onScreen: boolean;
    minimized: boolean;
}
/** GET /app/screenshot: one window's picture, whatever covers it. */
export interface AppScreenshot {
    jpeg: Buffer;
    width: number | null;
    height: number | null;
    window: number | null;
    /** The window on its display, normalized (X-Window-Bounds); null when the server did not say. */
    bounds: Region | null;
}
/** One actionable element of GET /app/ax; x / y / w / h normalized 0…1 in the window's picture. Never a value. */
export interface AppAxElement {
    i: number;
    role: string;
    subrole?: string;
    title?: string;
    x: number;
    y: number;
    w: number;
    h: number;
    enabled: boolean;
    focused: boolean;
}
/** GET /app/ax: the window's actionable elements; `truncated`: the walk ran out of time. */
export interface AppAx {
    app: AppRef | null;
    focused: number | null;
    elements: AppAxElement[];
    truncated: boolean;
}
/** GET /app/windows, leniently (odd entries dropped); not an object → a 502. */
export declare function parseAppWindows(raw: unknown): AppWindowInfo[];
/** GET /app/ax, leniently; not an object → a 502. */
export declare function parseAppAx(raw: unknown): AppAx;
/** A `x,y,w,h` header (X-Crop, X-Window-Bounds) as a Region, null when it isn't one. */
export declare function regionHeader(v: unknown): Region | null;
