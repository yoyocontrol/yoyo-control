import { type ControlDevice, type Input } from "@yoyocontrol/screen-web";
import type { ClipboardPut, ClipboardPutResponse, ClipboardStatus, ScreenBackend, ScreenEvent, ScreenRoute, ScreenStatus } from "@yoyocontrol/screen-ui";
import type { MacConnection } from "./connection.js";
import { DirectScreenLink, type ScreenLinkFactory } from "./screen-link.js";
import type { PairedMac } from "./store.js";
/** The one way a browser has to a Mac: uu Link over WebRTC, signaled through the relay. Not a shortcut (nothing to
 *  fall back to); `isLocalNetwork` and the stats line's label come from the session's path. */
export declare const LINK_ROUTE: ScreenRoute;
export interface DirectBackendOptions {
    /** The Mac no longer knows this browser (a 401, `unauthorized` on dial): forget it or pair again. */
    onUnpaired?: () => void;
    /** Tests: the session's screen media. */
    screenLink?: ScreenLinkFactory;
}
/**
 * Yoyo Control's own `ScreenBackend` for a browser (the iOS kit's `DirectBackend` on its link way): every request is
 * RPC on the Mac's uu Link session (`/status`, `/focus`, `/frame`, `/clipboard*`, `/events`), the Screen page's media,
 * pointer and input ride the session itself (`screenLink`), control is `control.take` / `control.release`. Answers are
 * mapped onto the pages' shapes (`mapping.ts`). Errors are screen-web `RequestError`s (`DirectError` when the Mac
 * can't be reached: 523 offline, 522 unreachable — the pages' default `isUnreachable` — and 401 unpaired).
 */
export declare class DirectBackend implements ScreenBackend {
    readonly mac: PairedMac;
    readonly connection: MacConnection;
    private readonly options;
    readonly cacheScope: string;
    readonly platformHint: string;
    readonly route: ScreenRoute;
    /** A browser sends text only (files on the Mac's clipboard are paths there). */
    readonly sendsClipboardFiles = false;
    private readonly link;
    private readonly hub;
    private unpairedFired;
    constructor(mac: PairedMac, connection: MacConnection, options?: DirectBackendOptions);
    private unpaired;
    /** One request as RPC on the session (dialed when needed); a non-2xx answer throws its `RequestError`. */
    private call;
    private json;
    status(): Promise<ScreenStatus>;
    /** RPC on the session (the page's media doesn't come this way: `screenLink`). */
    transport(_route: ScreenRoute): {
        fetch: (path: string, init?: RequestInit) => Promise<Response>;
    };
    input(input: Input): Promise<void>;
    setControl(controller: "user" | "none", _route: ScreenRoute, _device: ControlDevice, keepalive: boolean): Promise<ScreenStatus | null>;
    focus(display: number | undefined): Promise<{
        editable: boolean;
    }>;
    frame(display: number | undefined, maxWidth: number, quality: number): Promise<Blob>;
    /** The prompts are the Mac's to show: a paired device can't ask for them (a 403 saying where to grant them). */
    requestPermissions(): Promise<ScreenStatus>;
    /** `GET /clipboard` (503: the Mac can't do clipboard now, its reason kept). */
    clipboard(): Promise<ClipboardStatus>;
    clipboardImage(_changeCount: number): Promise<Blob>;
    clipboardFile(index: number, _changeCount: number, progress: (fraction: number) => void): Promise<{
        blob: Blob;
        name?: string;
        mime?: string;
    }>;
    putClipboard(put: ClipboardPut, progress: (fraction: number) => void): Promise<ClipboardPutResponse>;
    events(): AsyncIterable<ScreenEvent>;
    screenLink(_route: ScreenRoute): DirectScreenLink;
    /** The page is gone for good: the events reader and the session end. */
    close(): void;
}
