/** Largest control frame (docs/LINK.md「控制流」). */
export declare const MAX_CONTROL_FRAME: number;
/** Largest RPC request / response head. */
export declare const MAX_RPC_HEAD: number;
/** A JSON object as one frame: `u32 BE length` + UTF-8 JSON. Throws `protocol` past `max`. */
export declare function encodeFrame(message: object, max?: number): Uint8Array<ArrayBuffer>;
/** A frame's JSON body as an object; `protocol` when it isn't one. */
export declare function decodeFrameBody(body: Uint8Array): Record<string, unknown>;
/**
 * Bytes in, frames out. A DataChannel carries messages, but the frames are a byte stream as on QUIC: a frame may come
 * in pieces or several in one message, so this keeps what is left over.
 */
export declare class FrameReader {
    private readonly max;
    private buf;
    constructor(max?: number);
    /** Bytes waiting for the rest of their frame. */
    get pending(): number;
    /** Appends `bytes`; returns every frame now complete. Throws `protocol` on a frame over the limit or not JSON. */
    push(bytes: Uint8Array): Record<string, unknown>[];
    /** The next complete frame (or null), consuming it. */
    next(): Record<string, unknown> | null;
    /** What comes after the frames read so far (an RPC body after its head), and nothing kept. */
    rest(): Uint8Array;
    append(bytes: Uint8Array): void;
}
/** A DataChannel message as bytes (binary as is; a text message as its UTF-8). */
export declare function messageBytes(data: unknown): Uint8Array;
