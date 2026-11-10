/**
 * The clipboard's logic without the DOM (iOS ClipboardActions / ClipboardHints / ClipboardState): what the UI may do
 * with a status, the lines it shows, the Screen page's menu items and hints, the dot's marks, and one shared state per
 * computer that its events patch.
 */
export const CLIPBOARD_TEXT_BYTES = 1 << 20;
export const CLIPBOARD_FILES_PER_ITEM = 20;
export const DEFAULT_FILE_LIMIT = 95_000_000;
export const ClipboardActions = {
    /** The buttons under the computer's card, and whether this device may send anything. */
    enabled(status) {
        const e = { copy: false, share: false, save: false, send: false };
        if (!status?.available)
            return e;
        e.send = true;
        const kind = status.item?.kind ?? "empty";
        if (kind === "text")
            e.copy = e.share = true;
        else if (kind === "image")
            e.copy = e.share = e.save = true;
        else if (kind === "files")
            e.share = e.save = (status.item?.files ?? []).some((f) => !f.dir);
        return e;
    },
    /** One line for a summary: the text's preview, "Image · 1280×720", "3 files · a.pdf, b.jpg"… */
    previewLine(s, w) {
        switch (s.kind) {
            case "text":
                return s.preview ? s.preview : w.t("text");
            case "image":
                return s.width && s.height ? w.t("imageSized", { w: s.width, h: s.height }) : w.t("image");
            case "files": {
                const n = (s.files?.length ?? 0) + (s.moreFiles ?? 0);
                const names = (s.files ?? []).map((f) => f.name).join(", ");
                return names ? w.t("nFilesNamed", { n, names }) : w.t("nFiles", { n });
            }
            case "concealed":
                return w.t("hiddenPasswordManager");
            case "empty":
                return w.t("empty");
            default:
                return w.t("cantBeShown");
        }
    },
    /** The card's footer: who copied it and how long ago. */
    footer(s, w, now = Date.now()) {
        const when = s.at && s.at > 0 ? w.relative(s.at, now) : "";
        if (s.source === "phone")
            return when ? w.t("sentFromHereWhen", { when }) : w.t("sentFromHere");
        if (s.source === "agent") {
            if (w.agentName)
                return when ? w.t("copiedByNameWhen", { name: w.agentName, when }) : w.t("copiedByName", { name: w.agentName });
            return when ? w.t("copiedByAgentWhen", { when }) : w.t("copiedByAgent");
        }
        return when ? w.c("copiedOnWhen", { when }) : w.c("copiedOn");
    },
    /** Text that reads as code or a path: shown monospaced. */
    looksLikeCode(text) {
        const t = text.trim();
        if (!t)
            return false;
        if (t.startsWith("/") || t.startsWith("~/") || t.startsWith("./"))
            return !t.includes(" ") || t.includes("\n");
        const lines = t.split("\n");
        const codey = lines.filter((l) => {
            const s = l.trim();
            return s.endsWith(";") || s.endsWith("{") || s.endsWith("}") || s.startsWith("#") || s.startsWith("//") || s.includes("=>") || s.includes("()") || s.startsWith("$ ") || s.startsWith("import ") || s.startsWith("let ") || s.startsWith("const ");
        });
        return lines.length > 1 ? codey.length * 2 >= lines.length : codey.length > 0;
    },
    /** What `putClipboard` gets from what this device holds (files beat text), or why not. */
    payload(content, limit, w) {
        const files = content.files ?? [];
        if (files.length) {
            if (files.length > CLIPBOARD_FILES_PER_ITEM)
                return { error: w.t("tooManyFiles", { n: CLIPBOARD_FILES_PER_ITEM }) };
            const big = files.find((f) => f.size > limit);
            if (big)
                return { error: w.t("fileTooLarge", { name: big.name, limit: w.bytes(limit) }) };
            return { put: { files } };
        }
        const text = content.text ?? "";
        if (!text.trim())
            return { error: w.t("nothingToPaste") };
        if (new TextEncoder().encode(text).length > CLIPBOARD_TEXT_BYTES)
            return { error: w.t("textTooLong") };
        return { put: { text } };
    },
    /** What "Copy from Mac" does with a status. */
    copyMove(status) {
        if (!status.available)
            return { t: "unavailable", reason: status.reason ?? null };
        const item = status.item;
        if (!item || item.kind === "empty")
            return { t: "empty" };
        switch (item.kind) {
            case "text":
                return typeof item.text === "string" ? { t: "text", text: item.text } : { t: "nothing" };
            case "image":
                return { t: "image", changeCount: item.changeCount };
            case "files":
                return { t: "openFiles" };
            case "concealed":
                return { t: "concealed" };
            default:
                return { t: "nothing" };
        }
    },
    kindTitle(kind, w) {
        return w.t(kind === "text" ? "text" : kind === "link" ? "link" : "image");
    },
    kindWord(kind, w) {
        return w.t(kind === "text" ? "textWord" : kind === "link" ? "linkWord" : "imageWord");
    },
    /** "Paste on Mac": what this device holds, or why it can't. */
    pasteItem(phone, mac, w) {
        if (mac && !mac.available)
            return { enabled: false, subtitle: mac.reason ?? w.t("clipboardUnavailable") };
        return { enabled: true, subtitle: phone ? ClipboardActions.kindTitle(phone, w) : null };
    },
    /** "Copy from Mac": what the computer holds, or why there is nothing to copy. Unknown yet: enabled. */
    copyItem(mac, w) {
        if (!mac)
            return { enabled: true, subtitle: null };
        if (!mac.available)
            return { enabled: false, subtitle: mac.reason ?? w.t("clipboardUnavailable") };
        const s = mac.item;
        if (!s || s.kind === "empty")
            return { enabled: false, subtitle: w.c("emptyLine") };
        if (s.kind === "concealed")
            return { enabled: false, subtitle: w.t("hiddenByPasswordManager") };
        if (s.kind !== "text" && s.kind !== "image" && s.kind !== "files")
            return { enabled: false, subtitle: ClipboardActions.previewLine(s, w) };
        return { enabled: true, subtitle: ClipboardActions.macLine(s, w) };
    },
    macLine(s, w) {
        if (s.kind === "text")
            return s.preview ? w.t("textQuoted", { text: middleTruncated(oneLine(s.preview), 24) }) : w.t("text");
        if (s.kind === "files")
            return w.t("nFiles", { n: (s.files?.length ?? 0) + (s.moreFiles ?? 0) });
        return ClipboardActions.previewLine(s, w);
    },
    /** The hint when the computer has just copied something; null: nothing to copy. */
    macHint(s, w) {
        let what;
        if (s.kind === "text")
            what = s.preview ? `“${middleTruncated(oneLine(s.preview), 24)}”` : w.t("text");
        else if (s.kind === "image")
            what = w.t("image");
        else if (s.kind === "files")
            what = w.t("nFiles", { n: (s.files?.length ?? 0) + (s.moreFiles ?? 0) });
        else
            return null;
        return w.c("copiedHint", { what });
    },
    phoneHint(kind, w) {
        return w.c("phoneHint", { kind: ClipboardActions.kindWord(kind, w) });
    },
    /** After files were sent (and saved in a folder). */
    sentMessage(put, saved, w) {
        if ("text" in put)
            return w.c("copiedTo");
        const path = saved?.[0]?.path ?? "";
        const parts = path.split("/").filter(Boolean);
        const folder = parts.length >= 2 ? parts[parts.length - 2] : null;
        return folder ? w.c("sentSaved", { folder }) : w.c("sent");
    },
};
/** The preview's line breaks as spaces. */
export function oneLine(s) {
    return s.replaceAll("⏎ ", " ").replaceAll("\n", " ");
}
/** `s` at most `max` characters, the middle replaced by "…". */
export function middleTruncated(s, max) {
    const chars = [...s];
    if (chars.length <= max || max <= 1)
        return s;
    const keep = max - 1;
    const head = Math.floor((keep + 1) / 2), tail = Math.floor(keep / 2);
    return chars.slice(0, head).join("") + "…" + chars.slice(chars.length - tail).join("");
}
/**
 * What the Screen page has shown or done with either clipboard (the dot, the hints), for this run of the page. The
 * browser's clipboard has no change count: its "count" is a fingerprint of what it held when last looked at.
 */
export class ClipboardMarks {
    phone = null;
    mac = null;
    phoneIsNew(count, kind) {
        return kind !== null && count !== null && this.phone !== count;
    }
    macIsNew(s, w) {
        if (!s || this.mac === null || s.changeCount === this.mac || s.source === "phone")
            return false;
        return ClipboardActions.macHint(s, w) !== null;
    }
    dot(phoneCount, phoneKind, mac, w) {
        return this.phoneIsNew(phoneCount, phoneKind) || this.macIsNew(mac, w);
    }
    knowMac(s) {
        if (this.mac === null && s)
            this.mac = s.changeCount;
    }
    sawMenu(phoneCount, mac) {
        if (phoneCount !== null)
            this.phone = phoneCount;
        if (mac)
            this.mac = mac.changeCount;
    }
}
export const HINT_DURATION_MS = 6000;
export const ClipboardHints = {
    onAppear(marks, phoneCount, phoneKind) {
        return phoneKind && marks.phoneIsNew(phoneCount, phoneKind) ? { t: "phone", kind: phoneKind } : null;
    },
    /** The computer's clipboard changed while the page is open (`previous`: the count known before; null: the first heard). */
    onMacChange(s, previous, w) {
        if (!s || previous === null || s.changeCount === previous || s.source === "phone" || ClipboardActions.macHint(s, w) === null)
            return null;
        return { t: "mac", changeCount: s.changeCount };
    },
};
/** A clipboard failure that hides the keys instead of failing on every tap: 404 (none) and 403 (not this account's). */
export function clipboardSupported(hasValue, error) {
    if (hasValue)
        return true;
    if (error == null)
        return false;
    const status = error.status;
    return status !== 403 && status !== 404;
}
// ---------------------------------------------------------------- the shared state
const states = new Map();
/**
 * One computer's clipboard as the pages know it (`GET /clipboard`, its events): one per `cacheScope`, shared by every
 * page that shows it, loaded on demand, kept for TTL_MS, patched by the computer's clipboard events while anyone
 * observes it. Never stored: what a computer copied is live data and may be private.
 */
export class ClipboardState {
    backend;
    static TTL_MS = 15_000;
    status = null;
    error = null;
    loading = false;
    loadedAt = null;
    inflight = null;
    observers = new Set();
    events = null;
    constructor(backend) {
        this.backend = backend;
    }
    /** The state of `backend`'s computer (the same object for the same `cacheScope`). */
    static of(backend) {
        let s = states.get(backend.cacheScope);
        if (!s) {
            s = new ClipboardState(backend);
            states.set(backend.cacheScope, s);
        }
        return s;
    }
    /** Tests: every state forgotten. */
    static forgetAll() {
        for (const s of states.values())
            s.stopEvents();
        states.clear();
    }
    /** The computer has no clipboard (404). */
    get isUnsupported() {
        return this.error?.status === 404 && this.status === null;
    }
    /** `fn` at once when something is known, then after every change; returns the unsubscribe. */
    observe(fn) {
        this.observers.add(fn);
        this.followEvents();
        if (this.status || this.error)
            fn(this);
        return () => {
            this.observers.delete(fn);
            if (this.observers.size === 0)
                this.stopEvents();
        };
    }
    refresh() {
        if (this.loadedAt !== null && this.status && performance.now() - this.loadedAt < ClipboardState.TTL_MS)
            return;
        void this.load(true).catch(() => { });
    }
    async load(force = false) {
        if (!force && this.status && this.loadedAt !== null && performance.now() - this.loadedAt < ClipboardState.TTL_MS)
            return this.status;
        if (this.inflight)
            return this.inflight;
        const get = this.backend.clipboard;
        if (!get) {
            this.error = { status: 404 };
            this.notify();
            throw this.error;
        }
        this.loading = true;
        this.inflight = get.call(this.backend);
        this.notify();
        try {
            const s = await this.inflight;
            this.status = s;
            this.error = null;
            this.loadedAt = performance.now();
            return s;
        }
        catch (e) {
            this.error = e;
            if (e.status === 404)
                this.status = null;
            throw e;
        }
        finally {
            this.inflight = null;
            this.loading = false;
            this.notify();
        }
    }
    /** An answer that came another way (`putClipboard`'s). */
    set(status) {
        this.status = status;
        this.error = null;
        this.loadedAt = performance.now();
        this.notify();
    }
    /** A clipboard event: its summary replaces the item's (no text: a page that needs it loads again). */
    apply(available, summary) {
        const current = this.status;
        if (!current) {
            if (!this.isUnsupported && typeof available === "boolean")
                this.set({ available, item: summary ?? null });
            return;
        }
        const avail = typeof available === "boolean" ? available : current.available;
        if (current.available === avail && (current.item?.changeCount ?? null) === (summary?.changeCount ?? null) && !current.item === !summary)
            return;
        this.status = { available: avail, reason: avail ? null : (current.reason ?? null), item: summary ? { ...summary } : null };
        this.notify();
    }
    notify() {
        for (const fn of [...this.observers])
            fn(this);
    }
    followEvents() {
        if (this.events || !this.backend.events)
            return;
        const it = this.backend.events()[Symbol.asyncIterator]();
        this.events = it;
        void (async () => {
            try {
                for (;;) {
                    const { value, done } = await it.next();
                    if (done || this.events !== it)
                        break;
                    if (value.type === "clipboard.changed")
                        this.apply(value.available, value.item);
                }
            }
            catch {
                /* the subscription ended */
            }
            if (this.events === it)
                this.events = null;
        })();
    }
    stopEvents() {
        const it = this.events;
        this.events = null;
        void it?.return?.();
    }
}
