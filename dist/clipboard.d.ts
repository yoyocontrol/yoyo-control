import type { Readable } from "node:stream";
import { LocalError } from "./errors.js";
import { type RawResponse } from "./http.js";
export type ClipboardKind = "text" | "image" | "files" | "concealed" | "other" | "empty";
export declare const CLIPBOARD_KINDS: readonly ClipboardKind[];
export declare const isClipboardKind: (v: unknown) => v is ClipboardKind;
/** Text either way: 1 MiB (the server refuses more with 413, and cuts what it gives at a character boundary). */
export declare const CLIPBOARD_TEXT_MAX = 1048576;
export declare const CLIPBOARD_PREVIEW_MAX = 160;
/** Files listed per item (more → `moreFiles`). */
export declare const CLIPBOARD_FILES_MAX = 20;
/** Who put the item there: a phone, an automation, or (absent / unknown) someone at the Mac. */
export type ClipboardSource = "mac" | "phone" | "agent";
export interface ClipboardFile {
    name: string;
    /** null = unknown / a directory. */
    size: number | null;
    dir: boolean;
}
/** What the clipboard holds, without its content. */
export interface ClipboardSummary {
    /** NSPasteboard.changeCount; identifies the item. */
    changeCount: number;
    kind: ClipboardKind;
    preview: string;
    size: number | null;
    width?: number;
    height?: number;
    files?: ClipboardFile[];
    moreFiles?: number;
    /** When the server first saw this changeCount (unix ms). */
    at: number;
    source?: ClipboardSource;
}
export interface ClipboardItem extends ClipboardSummary {
    /** kind text: the string (cut at CLIPBOARD_TEXT_MAX bytes, `truncated`). */
    text?: string;
    truncated?: boolean;
}
/** A clipboard answer as a summary, leniently (an odd field is dropped, an unknown kind is "other"); null when it is not one. */
export declare function parseClipboardSummary(raw: unknown): ClipboardSummary | null;
/** `parseClipboardSummary` plus the text of a text item. */
export declare function parseClipboardItem(raw: unknown): ClipboardItem | null;
/** Text to write: a non-empty string of at most CLIPBOARD_TEXT_MAX bytes (400 / 413 LocalError otherwise). */
export declare function validateClipboardText(raw: unknown): string;
/** `attachment; filename*=UTF-8''<percent-encoded>` → the name; null without one. */
export declare function dispositionName(v: unknown): string | null;
/** A clipboard error answer (`{ error }`, else `fallback`) as a LocalError: 400 / 404 / 409 / 413 / 503 as they are, else 502. */
export declare function clipboardError(status: number, body: Buffer, fallback: string): LocalError;
/** How the clipboard reaches the server: a LocalClient (`request` / `json`), or anything that forwards to one. */
export interface ClipboardRequester {
    request(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<RawResponse>;
    json<T>(method: string, path: string, body?: unknown): Promise<T>;
}
/** A file of the clipboard, streaming: the caller pipes `body` (and destroys it when it doesn't want it). */
export interface ClipboardFileStream {
    body: Readable;
    /** Content-Length. */
    size: number;
    /** The name the server gave (Content-Disposition), null when none. */
    name: string | null;
}
export declare class ClipboardClient {
    private readonly server;
    constructor(server: ClipboardRequester);
    /** What the clipboard holds (`text` included unless `withText` is false). An unreadable answer is a 502. */
    read(withText?: boolean): Promise<ClipboardItem>;
    /** The image item as PNG (404 when it holds none). */
    image(): Promise<Buffer>;
    /** File `index` of a files item, streamed (400 a folder, 404 not files / out of range / gone; no size → 502). */
    file(index: number, signal?: AbortSignal): Promise<ClipboardFileStream>;
    /** The clipboard becomes `text` (`source`: who asked); the server's answer as an item. */
    writeText(text: string, source?: ClipboardSource): Promise<ClipboardItem>;
    /** The clipboard gets these files (absolute paths on the Mac); the server's answer as an item. */
    writeFiles(paths: readonly string[], source?: ClipboardSource): Promise<ClipboardItem>;
    private item;
}
/**
 * "The clipboard changed" announcements, deduplicated: `reported` (an `/events` clipboard line, or any answer) announces
 * when its changeCount differs from the last announced one, or when the clipboard was last announced unavailable;
 * `gone` announces unavailable once, until something is reported again (and only after something was announced).
 */
export declare class ClipboardAnnouncer {
    private readonly onChanged;
    private announced;
    constructor(onChanged: (available: boolean, item: ClipboardSummary | null) => void);
    reported(raw: unknown): void;
    gone(): void;
}
