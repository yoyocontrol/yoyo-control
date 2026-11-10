import { LinkError } from "./errors.js";
/** Largest control frame (docs/LINK.md「控制流」). */
export const MAX_CONTROL_FRAME = 256 * 1024;
/** Largest RPC request / response head. */
export const MAX_RPC_HEAD = 64 * 1024;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });
/** A JSON object as one frame: `u32 BE length` + UTF-8 JSON. Throws `protocol` past `max`. */
export function encodeFrame(message, max = MAX_CONTROL_FRAME) {
    if (message === null || typeof message !== "object" || Array.isArray(message))
        throw new LinkError("protocol", "a frame is a JSON object");
    const body = encoder.encode(JSON.stringify(message));
    if (body.length > max)
        throw new LinkError("protocol", `frame of ${body.length} bytes is over ${max}`);
    const out = new Uint8Array(4 + body.length);
    new DataView(out.buffer).setUint32(0, body.length);
    out.set(body, 4);
    return out;
}
/** A frame's JSON body as an object; `protocol` when it isn't one. */
export function decodeFrameBody(body) {
    let v;
    try {
        v = JSON.parse(decoder.decode(body));
    }
    catch (e) {
        throw new LinkError("protocol", `frame is not JSON: ${e instanceof Error ? e.message : String(e)}`);
    }
    if (v === null || typeof v !== "object" || Array.isArray(v))
        throw new LinkError("protocol", "frame is not a JSON object");
    return v;
}
/**
 * Bytes in, frames out. A DataChannel carries messages, but the frames are a byte stream as on QUIC: a frame may come
 * in pieces or several in one message, so this keeps what is left over.
 */
export class FrameReader {
    max;
    buf = new Uint8Array(0);
    constructor(max = MAX_CONTROL_FRAME) {
        this.max = max;
    }
    /** Bytes waiting for the rest of their frame. */
    get pending() {
        return this.buf.length;
    }
    /** Appends `bytes`; returns every frame now complete. Throws `protocol` on a frame over the limit or not JSON. */
    push(bytes) {
        this.append(bytes);
        const out = [];
        for (;;) {
            const f = this.next();
            if (!f)
                return out;
            out.push(f);
        }
    }
    /** The next complete frame (or null), consuming it. */
    next() {
        if (this.buf.length < 4)
            return null;
        const n = new DataView(this.buf.buffer, this.buf.byteOffset, 4).getUint32(0);
        if (n > this.max)
            throw new LinkError("protocol", `frame of ${n} bytes is over ${this.max}`);
        if (this.buf.length < 4 + n)
            return null;
        const body = this.buf.subarray(4, 4 + n);
        this.buf = this.buf.subarray(4 + n);
        return decodeFrameBody(body);
    }
    /** What comes after the frames read so far (an RPC body after its head), and nothing kept. */
    rest() {
        const r = this.buf;
        this.buf = new Uint8Array(0);
        return r;
    }
    append(bytes) {
        if (this.buf.length === 0) {
            this.buf = bytes;
            return;
        }
        const b = new Uint8Array(this.buf.length + bytes.length);
        b.set(this.buf);
        b.set(bytes, this.buf.length);
        this.buf = b;
    }
}
/** A DataChannel message as bytes (binary as is; a text message as its UTF-8). */
export function messageBytes(data) {
    if (data instanceof ArrayBuffer)
        return new Uint8Array(data);
    if (ArrayBuffer.isView(data))
        return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    if (typeof data === "string")
        return encoder.encode(data);
    throw new LinkError("protocol", "unexpected message type (set binaryType to arraybuffer)");
}
