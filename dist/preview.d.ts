import type { ScreenBackend, ScreenHost, ScreenStatus, UnavailableAction } from "./contracts.js";
import { type Controller } from "@yoyocontrol/screen-web";
/**
 * A computer's screen as a row of an app's list (iOS `YoyoScreenPreview`, docs/PROTOCOL.md「屏幕」): whether it has
 * one, who drives it, and a small frame of the main display, asked again every few seconds while the row is on screen
 * (`ScreenBackend.frame`). A sleeping display is left asleep (a frame would wake it). The app draws the row from
 * `state`, `image` and `line()`; `start` / `stop` follow the row; it pauses while the page is hidden.
 */
export type PreviewState = {
    t: "unknown";
}
/** The computer has no screen (404): no row. */
 | {
    t: "absent";
} | {
    t: "unavailable";
    reason: string | null;
} | {
    t: "action";
    action: UnavailableAction;
} | {
    t: "needsPermission";
} | {
    t: "asleep";
} | {
    t: "live";
    controller: Controller;
};
export declare function previewState(s: ScreenStatus): PreviewState;
export declare class ScreenPreview {
    private readonly backend;
    static readonly EVERY_MS = 5000;
    static readonly MAX_WIDTH = 320;
    static readonly QUALITY = 50;
    state: PreviewState;
    /** An object URL of the latest frame (kept while it can't be refreshed; revoked when replaced). */
    image: string | null;
    /** The computer's platform ("mac" until a status says). */
    platform: string;
    private timer;
    private running;
    private onChange;
    private readonly words;
    private readonly visibility;
    constructor(backend: ScreenBackend, host?: ScreenHost);
    /** The row shows (the computer has a screen, or hasn't answered yet). */
    get showsRow(): boolean;
    /** The row's second line while nobody drives it: "Watch the Mac, or take control". */
    line(): string;
    /** The row is on screen: keep it current (`onChange` after every change). */
    start(onChange: () => void): void;
    stop(): void;
    private resume;
    private pause;
    private tick;
    private set;
}
