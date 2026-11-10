/**
 * The screen stream's multipart framing (docs/PROTOCOL.md「媒体类型」「视频流、确认与客户端指针」「声音」), as the iOS
 * ScreenStreamParts.swift: the stream and the sound answer with `--<boundary>\r\n<headers>\r\n\r\n<body>\r\n` parts,
 * (`application/vnd.yoyo-control.*`, docs/LOCAL-API.md「流的媒体类型」). Pure and synchronous: feed it the bytes as they
 * come, split anywhere, and it returns the parts completed so far.
 */
/** What the client accepts (docs/LOCAL-API.md「流的媒体类型」). */
export declare const STREAM_ACCEPT = "application/vnd.yoyo-control.stream";
export declare const AUDIO_ACCEPT = "application/vnd.yoyo-control.audio";
/** The boundary of a response whose Content-Type names none. */
export declare const DEFAULT_BOUNDARY = "frame";
export type PartKind = "h264" | "hevc" | "cursor" | "status" | "audio" | "other";
/** A part's headers; every value optional (missing or not parsing = undefined). */
export interface PartHeaders {
    contentType?: string;
    /** Picture size in pixels (the picture covers the whole display). */
    width?: number;
    height?: number;
    /** `X-Frame-Seq`: monotonic per stream, counting every part (pictures, cursor and status parts). */
    seq?: number;
    /** `X-Frame-Kind`: key / delta / refine / keepalive (video), cursor, status. Lowercased. */
    kind?: string;
    /** `X-Frame-Time`: ms since 1970 (the server's clock) when the content was published. */
    time?: number;
    /** `X-Stream-Codec`, lowercased. */
    codec?: string;
    /** `X-Audio-Seq` / `X-Audio-Time` of a sound part. */
    audioSeq?: number;
    audioTime?: number;
    /** `Content-Length`. */
    length?: number;
}
export interface StreamPart {
    kind: PartKind;
    /** Empty for an `other` part (only its seq is reported). */
    body: Uint8Array;
    headers: PartHeaders;
}
/** The kind of a part's `Content-Type` (none, or one this client doesn't know: "other"). */
export declare function partKind(contentType: string | undefined): PartKind;
/** A video picture (acked as it arrives). */
export declare const isPicture: (k: PartKind) => k is "h264" | "hevc";
/** A picture that moves the picture on (not a re-encode of an unchanged one: refine / keepalive). */
export declare const isLivePicture: (h: PartHeaders) => boolean;
/** Largest accepted body of each kind (never above `limit`); bigger parts are skipped unread. */
export declare function maxBody(kind: PartKind, limit: number): number;
/** The boundary of a `…; boundary=<b>` Content-Type (quotes removed); null when there is none. */
export declare function boundaryOf(contentType: string | null | undefined): string | null;
/** From a header lookup (names as sent; the lookup decides about case), e.g. a Response's `headers.get`. */
export declare function headersFrom(value: (name: string) => string | null | undefined): PartHeaders;
/** From a part's header block (`Name: value` lines, CRLF). */
export declare function parseHeaderBlock(block: string): PartHeaders;
/** The first index of `needle` in `hay[from, to)`, or -1. */
export declare function indexOfBytes(hay: Uint8Array, needle: Uint8Array, from?: number, to?: number): number;
/**
 * Incremental parser of the multipart body. With `Content-Length` a body is taken by length, without it it ends at the
 * next `\r\n--<boundary>`. A preamble and the closing `--<boundary>--` are skipped. A part of an unknown type, or larger
 * than its kind allows, is skipped without being buffered (an unknown one is still reported, bodiless, for its seq).
 * A buffer that grows past `maxBuffer` without completing a part is dropped.
 */
export declare class PartParser {
    readonly boundary: string;
    private readonly maxBuffer;
    static readonly maxHeaderBytes: number;
    private readonly delimiter;
    private readonly bodyEnd;
    private buf;
    /** Start of the unread bytes in `buf`. */
    private off;
    private state;
    /** How much of the current search was already done (the search resumes there). */
    private scanned;
    constructor(boundary: string, maxBuffer?: number);
    /** Bytes waiting for the rest of their part. */
    get buffered(): number;
    feed(chunk: Uint8Array): StreamPart[];
    private append;
    private consume;
    private resetBuffer;
    /** One state transition; false when more bytes are needed. */
    private step;
}
