/**
 * The screen stream's multipart framing (docs/PROTOCOL.md「媒体类型」「视频流、确认与客户端指针」「声音」), as the iOS
 * ScreenStreamParts.swift: the stream and the sound answer with `--<boundary>\r\n<headers>\r\n\r\n<body>\r\n` parts,
 * (`application/vnd.yoyo-control.*`, docs/LOCAL-API.md「流的媒体类型」). Pure and synchronous: feed it the bytes as they
 * come, split anywhere, and it returns the parts completed so far.
 */
/** What the client accepts (docs/LOCAL-API.md「流的媒体类型」). */
export const STREAM_ACCEPT = "application/vnd.yoyo-control.stream";
export const AUDIO_ACCEPT = "application/vnd.yoyo-control.audio";
/** The boundary of a response whose Content-Type names none. */
export const DEFAULT_BOUNDARY = "frame";
/** The kind of a part's `Content-Type` (none, or one this client doesn't know: "other"). */
export function partKind(contentType) {
    const type = (contentType ?? "").split(";", 1)[0].trim().toLowerCase();
    switch (type) {
        case "video/h264":
        case "video/avc":
            return "h264";
        case "video/hevc":
        case "video/h265":
            return "hevc";
        case "application/vnd.yoyo-control.cursor+json":
            return "cursor";
        case "application/vnd.yoyo-control.status+json":
            return "status";
        default:
            return type.startsWith("audio/") ? "audio" : "other";
    }
}
/** A video picture (acked as it arrives). */
export const isPicture = (k) => k === "h264" || k === "hevc";
/** A picture that moves the picture on (not a re-encode of an unchanged one: refine / keepalive). */
export const isLivePicture = (h) => h.kind !== "refine" && h.kind !== "keepalive";
const MAX_VIDEO = 8 * 1024 * 1024;
const MAX_CURSOR = 1024 * 1024;
const MAX_STATUS = 64 * 1024;
const MAX_AUDIO = 64 * 1024;
/** Largest accepted body of each kind (never above `limit`); bigger parts are skipped unread. */
export function maxBody(kind, limit) {
    switch (kind) {
        case "h264":
        case "hevc":
            return Math.min(limit, MAX_VIDEO);
        case "cursor":
            return Math.min(limit, MAX_CURSOR);
        case "status":
            return Math.min(limit, MAX_STATUS);
        case "audio":
            return Math.min(limit, MAX_AUDIO);
        default:
            return 0;
    }
}
/** The boundary of a `…; boundary=<b>` Content-Type (quotes removed); null when there is none. */
export function boundaryOf(contentType) {
    if (!contentType)
        return null;
    for (const param of contentType.split(";").slice(1)) {
        const eq = param.indexOf("=");
        if (eq < 0 || param.slice(0, eq).trim().toLowerCase() !== "boundary")
            continue;
        let v = param.slice(eq + 1).trim();
        if (v.length >= 2 && v.startsWith('"') && v.endsWith('"'))
            v = v.slice(1, -1);
        return v || null;
    }
    return null;
}
/** From a header lookup (names as sent; the lookup decides about case), e.g. a Response's `headers.get`. */
export function headersFrom(value) {
    const text = (n) => {
        const v = value(n)?.trim();
        return v ? v : undefined;
    };
    const int = (n, min) => {
        const t = text(n);
        if (t === undefined || !/^[+-]?\d+$/.test(t))
            return undefined;
        const v = Number(t);
        return Number.isSafeInteger(v) && v >= min ? v : undefined;
    };
    const num = (n) => {
        const t = text(n);
        const v = t === undefined ? NaN : Number(t);
        return Number.isFinite(v) ? v : undefined;
    };
    const h = {};
    const set = (k, v) => {
        if (v !== undefined)
            h[k] = v;
    };
    set("contentType", text("Content-Type"));
    set("width", int("X-Frame-Width", 1));
    set("height", int("X-Frame-Height", 1));
    set("seq", int("X-Frame-Seq", 0));
    set("kind", text("X-Frame-Kind")?.toLowerCase());
    set("time", num("X-Frame-Time"));
    set("codec", text("X-Stream-Codec")?.toLowerCase());
    set("audioSeq", int("X-Audio-Seq", 0));
    set("audioTime", num("X-Audio-Time"));
    set("length", int("Content-Length", 0));
    return h;
}
/** From a part's header block (`Name: value` lines, CRLF). */
export function parseHeaderBlock(block) {
    const fields = new Map();
    for (const line of block.split("\r\n")) {
        const colon = line.indexOf(":");
        if (colon < 0)
            continue;
        fields.set(line.slice(0, colon).trim().toLowerCase(), line.slice(colon + 1));
    }
    return headersFrom((n) => fields.get(n.toLowerCase()));
}
const enc = new TextEncoder();
const dec = new TextDecoder();
const CRLF = enc.encode("\r\n");
const HEADER_END = enc.encode("\r\n\r\n");
/** The first index of `needle` in `hay[from, to)`, or -1. */
export function indexOfBytes(hay, needle, from = 0, to = hay.length) {
    const n = needle.length;
    if (n === 0)
        return from;
    const first = needle[0];
    for (let i = hay.indexOf(first, from); i >= 0 && i + n <= to; i = hay.indexOf(first, i + 1)) {
        let j = 1;
        while (j < n && hay[i + j] === needle[j])
            j++;
        if (j === n)
            return i;
    }
    return -1;
}
/**
 * Incremental parser of the multipart body. With `Content-Length` a body is taken by length, without it it ends at the
 * next `\r\n--<boundary>`. A preamble and the closing `--<boundary>--` are skipped. A part of an unknown type, or larger
 * than its kind allows, is skipped without being buffered (an unknown one is still reported, bodiless, for its seq).
 * A buffer that grows past `maxBuffer` without completing a part is dropped.
 */
export class PartParser {
    boundary;
    maxBuffer;
    static maxHeaderBytes = 8 * 1024;
    delimiter;
    bodyEnd;
    buf = new Uint8Array(0);
    /** Start of the unread bytes in `buf`. */
    off = 0;
    state = { s: "boundary" };
    /** How much of the current search was already done (the search resumes there). */
    scanned = 0;
    constructor(boundary, maxBuffer = 20 * 1024 * 1024) {
        this.boundary = boundary;
        this.maxBuffer = maxBuffer;
        this.delimiter = enc.encode(`--${boundary}`);
        this.bodyEnd = enc.encode(`\r\n--${boundary}`);
    }
    /** Bytes waiting for the rest of their part. */
    get buffered() {
        return this.buf.length - this.off;
    }
    feed(chunk) {
        if (chunk.length === 0)
            return [];
        this.append(chunk);
        const parts = [];
        while (this.step(parts))
            ;
        if (this.buffered > this.maxBuffer)
            this.resetBuffer();
        return parts;
    }
    append(chunk) {
        const live = this.buf.length - this.off;
        if (live === 0) {
            this.buf = chunk.slice();
            this.off = 0;
            return;
        }
        const next = new Uint8Array(live + chunk.length);
        next.set(this.buf.subarray(this.off), 0);
        next.set(chunk, live);
        this.buf = next;
        this.off = 0;
    }
    consume(n) {
        this.off += n;
    }
    resetBuffer() {
        this.buf = new Uint8Array(0);
        this.off = 0;
        this.state = { s: "boundary" };
        this.scanned = 0;
    }
    /** One state transition; false when more bytes are needed. */
    step(parts) {
        const b = this.buf;
        const start = this.off;
        const end = b.length;
        switch (this.state.s) {
            case "boundary": {
                const at = indexOfBytes(b, this.delimiter, start, end);
                if (at < 0) {
                    // keep only what could be the start of a delimiter
                    const keep = this.delimiter.length - 1;
                    if (end - start > keep)
                        this.off = end - keep;
                    return false;
                }
                const after = at + this.delimiter.length;
                if (end - after < 2)
                    return false;
                // the closing `--<b>--`
                if (b[after] === 0x2d && b[after + 1] === 0x2d) {
                    this.off = after + 2;
                    return true;
                }
                const eol = indexOfBytes(b, CRLF, after, end);
                if (eol < 0) {
                    // padding after a boundary is a few bytes; this much isn't a boundary line
                    if (end - after <= PartParser.maxHeaderBytes)
                        return false;
                    this.off = after;
                    return true;
                }
                this.off = eol + 2;
                this.state = { s: "headers" };
                return true;
            }
            case "headers": {
                // no headers at all: the blank line comes first
                if (end - start >= 2 && b[start] === 0x0d && b[start + 1] === 0x0a) {
                    this.off = start + 2;
                    this.state = { s: "body", headers: {} };
                    return true;
                }
                const from = start + Math.max(0, this.scanned - (HEADER_END.length - 1));
                const r = indexOfBytes(b, HEADER_END, from, end);
                if (r < 0) {
                    if (end - start > PartParser.maxHeaderBytes)
                        this.resetBuffer();
                    else
                        this.scanned = end - start;
                    return false;
                }
                this.scanned = 0;
                const headers = parseHeaderBlock(dec.decode(b.subarray(start, r)));
                this.off = r + HEADER_END.length;
                const kind = partKind(headers.contentType);
                if (headers.length !== undefined && headers.length > maxBody(kind, this.maxBuffer)) {
                    // not kept: an unknown part is still reported (its seq is no gap), an oversized one is lost
                    if (kind === "other")
                        parts.push({ kind, body: new Uint8Array(0), headers });
                    this.state = { s: "skip", remaining: headers.length };
                }
                else {
                    this.state = { s: "body", headers };
                }
                return true;
            }
            case "skip": {
                const n = Math.min(this.state.remaining, end - start);
                this.consume(n);
                if (n < this.state.remaining) {
                    this.state = { s: "skip", remaining: this.state.remaining - n };
                    return false;
                }
                this.state = { s: "boundary" };
                return true;
            }
            case "body": {
                const headers = this.state.headers;
                let bodyEnd;
                let resume;
                if (headers.length !== undefined) {
                    if (end - start < headers.length)
                        return false;
                    bodyEnd = start + headers.length;
                    resume = bodyEnd;
                }
                else {
                    const from = start + Math.max(0, this.scanned - (this.bodyEnd.length - 1));
                    const r = indexOfBytes(b, this.bodyEnd, from, end);
                    if (r < 0) {
                        this.scanned = end - start;
                        return false;
                    }
                    bodyEnd = r;
                    // leave `--<b>` for the boundary state
                    resume = r + 2;
                }
                const kind = partKind(headers.contentType);
                if (kind === "other")
                    parts.push({ kind, body: new Uint8Array(0), headers });
                else if (bodyEnd > start && bodyEnd - start <= maxBody(kind, this.maxBuffer))
                    parts.push({ kind, body: b.slice(start, bodyEnd), headers });
                this.off = resume;
                this.state = { s: "boundary" };
                this.scanned = 0;
                return true;
            }
        }
    }
}
