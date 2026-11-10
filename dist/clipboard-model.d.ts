import type { ClipboardPut, ClipboardStatus, ClipboardSummary, ScreenBackend } from "./contracts.js";
import type { Words } from "./strings.js";
/**
 * The clipboard's logic without the DOM (iOS ClipboardActions / ClipboardHints / ClipboardState): what the UI may do
 * with a status, the lines it shows, the Screen page's menu items and hints, the dot's marks, and one shared state per
 * computer that its events patch.
 */
export declare const CLIPBOARD_TEXT_BYTES: number;
export declare const CLIPBOARD_FILES_PER_ITEM = 20;
export declare const DEFAULT_FILE_LIMIT = 95000000;
/** What the browser's clipboard holds, as far as can be told (null: nothing, or not allowed to look). */
export type PhoneKind = "text" | "link" | "image";
export interface Enabled {
    copy: boolean;
    share: boolean;
    save: boolean;
    send: boolean;
}
export declare const ClipboardActions: {
    /** The buttons under the computer's card, and whether this device may send anything. */
    enabled(status: ClipboardStatus | null): Enabled;
    /** One line for a summary: the text's preview, "Image · 1280×720", "3 files · a.pdf, b.jpg"… */
    previewLine(s: ClipboardSummary, w: Words): string;
    /** The card's footer: who copied it and how long ago. */
    footer(s: ClipboardSummary, w: Words, now?: number): string;
    /** Text that reads as code or a path: shown monospaced. */
    looksLikeCode(text: string): boolean;
    /** What `putClipboard` gets from what this device holds (files beat text), or why not. */
    payload(content: {
        text?: string | null;
        files?: File[];
    }, limit: number, w: Words): {
        put: ClipboardPut;
    } | {
        error: string;
    };
    /** What "Copy from Mac" does with a status. */
    copyMove(status: ClipboardStatus): {
        t: "text";
        text: string;
    } | {
        t: "image";
        changeCount: number;
    } | {
        t: "openFiles";
    } | {
        t: "concealed";
    } | {
        t: "empty";
    } | {
        t: "unavailable";
        reason: string | null;
    } | {
        t: "nothing";
    };
    kindTitle(kind: PhoneKind, w: Words): string;
    kindWord(kind: PhoneKind, w: Words): string;
    /** "Paste on Mac": what this device holds, or why it can't. */
    pasteItem(phone: PhoneKind | null, mac: ClipboardStatus | null, w: Words): {
        enabled: boolean;
        subtitle: string | null;
    };
    /** "Copy from Mac": what the computer holds, or why there is nothing to copy. Unknown yet: enabled. */
    copyItem(mac: ClipboardStatus | null, w: Words): {
        enabled: boolean;
        subtitle: string | null;
    };
    macLine(s: ClipboardSummary, w: Words): string;
    /** The hint when the computer has just copied something; null: nothing to copy. */
    macHint(s: ClipboardSummary, w: Words): string | null;
    phoneHint(kind: PhoneKind, w: Words): string;
    /** After files were sent (and saved in a folder). */
    sentMessage(put: ClipboardPut, saved: {
        path: string;
    }[] | undefined, w: Words): string;
};
/** The preview's line breaks as spaces. */
export declare function oneLine(s: string): string;
/** `s` at most `max` characters, the middle replaced by "…". */
export declare function middleTruncated(s: string, max: number): string;
/**
 * What the Screen page has shown or done with either clipboard (the dot, the hints), for this run of the page. The
 * browser's clipboard has no change count: its "count" is a fingerprint of what it held when last looked at.
 */
export declare class ClipboardMarks {
    phone: string | null;
    mac: number | null;
    phoneIsNew(count: string | null, kind: PhoneKind | null): boolean;
    macIsNew(s: ClipboardSummary | null | undefined, w: Words): boolean;
    dot(phoneCount: string | null, phoneKind: PhoneKind | null, mac: ClipboardSummary | null | undefined, w: Words): boolean;
    knowMac(s: ClipboardSummary | null | undefined): void;
    sawMenu(phoneCount: string | null, mac: ClipboardSummary | null | undefined): void;
}
export type ClipboardHint = {
    t: "phone";
    kind: PhoneKind;
} | {
    t: "mac";
    changeCount: number;
};
export declare const HINT_DURATION_MS = 6000;
export declare const ClipboardHints: {
    onAppear(marks: ClipboardMarks, phoneCount: string | null, phoneKind: PhoneKind | null): ClipboardHint | null;
    /** The computer's clipboard changed while the page is open (`previous`: the count known before; null: the first heard). */
    onMacChange(s: ClipboardSummary | null | undefined, previous: number | null, w: Words): ClipboardHint | null;
};
/** A clipboard failure that hides the keys instead of failing on every tap: 404 (none) and 403 (not this account's). */
export declare function clipboardSupported(hasValue: boolean, error: unknown): boolean;
/**
 * One computer's clipboard as the pages know it (`GET /clipboard`, its events): one per `cacheScope`, shared by every
 * page that shows it, loaded on demand, kept for TTL_MS, patched by the computer's clipboard events while anyone
 * observes it. Never stored: what a computer copied is live data and may be private.
 */
export declare class ClipboardState {
    private readonly backend;
    static readonly TTL_MS = 15000;
    status: ClipboardStatus | null;
    error: unknown;
    loading: boolean;
    private loadedAt;
    private inflight;
    private readonly observers;
    private events;
    private constructor();
    /** The state of `backend`'s computer (the same object for the same `cacheScope`). */
    static of(backend: ScreenBackend): ClipboardState;
    /** Tests: every state forgotten. */
    static forgetAll(): void;
    /** The computer has no clipboard (404). */
    get isUnsupported(): boolean;
    /** `fn` at once when something is known, then after every change; returns the unsubscribe. */
    observe(fn: (s: ClipboardState) => void): () => void;
    refresh(): void;
    load(force?: boolean): Promise<ClipboardStatus>;
    /** An answer that came another way (`putClipboard`'s). */
    set(status: ClipboardStatus): void;
    /** A clipboard event: its summary replaces the item's (no text: a page that needs it loads again). */
    apply(available: boolean | null | undefined, summary: ClipboardSummary | null | undefined): void;
    private notify;
    private followEvents;
    private stopEvents;
}
