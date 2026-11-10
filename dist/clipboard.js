import { LocalError, errorText } from "./errors.js";
import { readAll } from "./http.js";
export const CLIPBOARD_KINDS = ["text", "image", "files", "concealed", "other", "empty"];
export const isClipboardKind = (v) => typeof v === "string" && CLIPBOARD_KINDS.includes(v);
/** Text either way: 1 MiB (the server refuses more with 413, and cuts what it gives at a character boundary). */
export const CLIPBOARD_TEXT_MAX = 1_048_576;
export const CLIPBOARD_PREVIEW_MAX = 160;
/** Files listed per item (more → `moreFiles`). */
export const CLIPBOARD_FILES_MAX = 20;
const isNum = (v) => typeof v === "number" && Number.isFinite(v);
/** A clipboard answer as a summary, leniently (an odd field is dropped, an unknown kind is "other"); null when it is not one. */
export function parseClipboardSummary(raw) {
    if (!raw || typeof raw !== "object")
        return null;
    const r = raw;
    if (!isNum(r.changeCount) || typeof r.kind !== "string")
        return null;
    const s = {
        changeCount: Math.floor(r.changeCount),
        kind: isClipboardKind(r.kind) ? r.kind : "other",
        preview: typeof r.preview === "string" ? [...r.preview].slice(0, CLIPBOARD_PREVIEW_MAX).join("") : "",
        size: isNum(r.size) && r.size >= 0 ? Math.floor(r.size) : null,
        at: isNum(r.at) ? r.at : Date.now(),
    };
    if (isNum(r.width) && isNum(r.height) && r.width > 0 && r.height > 0) {
        s.width = Math.floor(r.width);
        s.height = Math.floor(r.height);
    }
    if (Array.isArray(r.files)) {
        const files = [];
        for (const f of r.files.slice(0, CLIPBOARD_FILES_MAX)) {
            if (!f || typeof f !== "object" || typeof f.name !== "string")
                continue;
            const e = f;
            files.push({ name: e.name, size: isNum(e.size) && e.size >= 0 ? Math.floor(e.size) : null, dir: e.dir === true });
        }
        s.files = files;
        if (isNum(r.moreFiles) && r.moreFiles > 0)
            s.moreFiles = Math.floor(r.moreFiles);
    }
    if (r.source === "phone" || r.source === "agent" || r.source === "mac")
        s.source = r.source;
    return s;
}
/** `parseClipboardSummary` plus the text of a text item. */
export function parseClipboardItem(raw) {
    const s = parseClipboardSummary(raw);
    if (!s)
        return null;
    const r = raw;
    const item = { ...s };
    if (s.kind === "text" && typeof r.text === "string") {
        item.text = r.text;
        if (r.truncated === true)
            item.truncated = true;
    }
    return item;
}
/** Text to write: a non-empty string of at most CLIPBOARD_TEXT_MAX bytes (400 / 413 LocalError otherwise). */
export function validateClipboardText(raw) {
    if (typeof raw !== "string")
        throw new LocalError("text must be a string", 400);
    if (!raw.trim())
        throw new LocalError("text is empty", 400);
    if (Buffer.byteLength(raw) > CLIPBOARD_TEXT_MAX)
        throw new LocalError(`text is too long (max ${CLIPBOARD_TEXT_MAX} bytes)`, 413);
    return raw;
}
/** `attachment; filename*=UTF-8''<percent-encoded>` → the name; null without one. */
export function dispositionName(v) {
    if (typeof v !== "string")
        return null;
    const m = /filename\*\s*=\s*UTF-8''([^;]+)/i.exec(v);
    return m ? safeDecode(m[1].trim()) : null;
}
function safeDecode(s) {
    try {
        return decodeURIComponent(s);
    }
    catch {
        return null;
    }
}
/** A clipboard error answer (`{ error }`, else `fallback`) as a LocalError: 400 / 404 / 409 / 413 / 503 as they are, else 502. */
export function clipboardError(status, body, fallback) {
    let json = null;
    try {
        json = JSON.parse(body.toString("utf8"));
    }
    catch {
        /* not JSON */
    }
    return new LocalError(errorText(json, fallback), status === 400 || status === 404 || status === 409 || status === 413 || status === 503 ? status : 502);
}
export class ClipboardClient {
    server;
    constructor(server) {
        this.server = server;
    }
    /** What the clipboard holds (`text` included unless `withText` is false). An unreadable answer is a 502. */
    async read(withText = true) {
        return this.item(await this.server.json("GET", withText ? "/clipboard" : "/clipboard?text=0"));
    }
    /** The image item as PNG (404 when it holds none). */
    async image() {
        const res = await this.server.request("GET", "/clipboard/image");
        const buf = await readAll(res.body);
        if (res.status !== 200)
            throw clipboardError(res.status, buf, "the clipboard holds no image");
        return buf;
    }
    /** File `index` of a files item, streamed (400 a folder, 404 not files / out of range / gone; no size → 502). */
    async file(index, signal) {
        const res = await this.server.request("GET", `/clipboard/file?index=${index}`, undefined, signal);
        if (res.status !== 200)
            throw clipboardError(res.status, await readAll(res.body), "the clipboard holds no files");
        const size = Number(res.headers["content-length"]);
        if (!Number.isFinite(size) || size < 0) {
            res.body.destroy();
            throw new LocalError("the screen helper gave no file size", 502);
        }
        const name = dispositionName(res.headers["content-disposition"]);
        return { body: res.body, size, name };
    }
    /** The clipboard becomes `text` (`source`: who asked); the server's answer as an item. */
    async writeText(text, source) {
        return this.item(await this.server.json("POST", "/clipboard", { text, source }));
    }
    /** The clipboard gets these files (absolute paths on the Mac); the server's answer as an item. */
    async writeFiles(paths, source) {
        return this.item(await this.server.json("POST", "/clipboard", { files: paths, source }));
    }
    item(raw) {
        const item = parseClipboardItem(raw);
        if (!item)
            throw new LocalError("the screen helper gave an unreadable clipboard answer", 502);
        return item;
    }
}
/**
 * "The clipboard changed" announcements, deduplicated: `reported` (an `/events` clipboard line, or any answer) announces
 * when its changeCount differs from the last announced one, or when the clipboard was last announced unavailable;
 * `gone` announces unavailable once, until something is reported again (and only after something was announced).
 */
export class ClipboardAnnouncer {
    onChanged;
    announced = null;
    constructor(onChanged) {
        this.onChanged = onChanged;
    }
    reported(raw) {
        const summary = parseClipboardSummary(raw);
        if (!summary)
            return;
        if (this.announced?.available && this.announced.changeCount === summary.changeCount)
            return;
        this.announced = { available: true, changeCount: summary.changeCount };
        this.onChanged(true, summary.kind === "empty" ? null : summary);
    }
    gone() {
        if (!this.announced || !this.announced.available)
            return;
        this.announced = { available: false, changeCount: null };
        this.onChanged(false, null);
    }
}
