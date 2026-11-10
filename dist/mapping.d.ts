import type { ClipboardStatus, ScreenEvent, ScreenStatus } from "@yoyocontrol/screen-ui";
/**
 * The Mac's own answers (mac/README.md, docs/LOCAL-API.md) in the pages' shapes (docs/PROTOCOL.md), as the iOS
 * kit's `DirectBackend` maps them.
 */
type Json = Record<string, unknown>;
/** Automation drives the Mac (`automation.active`; an older Mac: `agentControl.active`). */
export declare function agentActive(mac: Json): boolean;
/** `controller`, `controllerSince`, `controllerDevice` from the Mac's `control`: a paired device holding it is
 *  `user` (this browser or another: the page tells by id); else automation is `agent`; else `none`. */
export declare function controlFields(control: unknown, agent: boolean): Pick<ScreenStatus, "controller" | "controllerSince" | "controllerDevice">;
/** The Mac's `GET /status` as the page's `ScreenStatus`. */
export declare function statusFromMac(mac: Json): ScreenStatus;
/** The Mac's `GET /clipboard` (the item itself, with `ok`) as a `ClipboardStatus`. */
export declare function clipboardFromMac(body: Json): ClipboardStatus;
/** One `/events` line of the Mac as the pages' event (null: not one they follow). A `control` line never says
 *  `agent` (only `/status` does): the backend asks. */
export declare function eventFromMacLine(line: Json): ScreenEvent | null;
/** `filename*=UTF-8''<percent-encoded>` (or a plain `filename="…"`) of a `Content-Disposition`. */
export declare function filenameOf(contentDisposition: string | null): string | null;
export {};
