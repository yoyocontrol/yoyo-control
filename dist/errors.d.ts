/** Session close codes (docs/LINK.md「控制流」): the QUIC application codes, carried by `bye.code` on WebRTC. */
export declare const CloseCode: {
    readonly normal: 0;
    readonly unauthorized: 1;
    readonly rateLimited: 2;
    readonly busy: 3;
    readonly protocol: 4;
    readonly shuttingDown: 5;
    readonly replaced: 6;
};
/** Why a server refused a session (`denied.code`). */
export type DenyCode = "unauthorized" | "rate-limited" | "busy";
/** What went wrong:
 *  - `signal`: the host's signaling path failed (its error is the `cause`);
 *  - `verification`: the answer is not from the pinned computer (fingerprint, signature or DTLS fingerprint mismatch);
 *  - `timeout`: no connection / no `welcome` in time;
 *  - `denied`: the server refused the credential or is busy (`code`);
 *  - `protocol`: a malformed message;
 *  - `closed`: the session is over;
 *  - `unsupported`: this browser has no WebRTC (or no WebCrypto);
 *  - `media`: the media layer refused a call (e.g. input overflow). */
export type LinkErrorKind = "signal" | "verification" | "timeout" | "denied" | "protocol" | "closed" | "unsupported" | "media";
/** Every error of this package. `code` is the deny code for `kind: "denied"`. */
export declare class LinkError extends Error {
    readonly kind: LinkErrorKind;
    readonly code?: DenyCode | undefined;
    constructor(kind: LinkErrorKind, message: string, code?: DenyCode | undefined, options?: {
        cause?: unknown;
    });
}
/** An unknown deny code reads as `busy` (try again later, don't forget the computer), as in the Rust core. */
export declare function denyCode(s: unknown): DenyCode;
/** The deny code a close code before `welcome` stands for (1 / 2 / 3), else null. */
export declare function denyForClose(code: number | undefined): DenyCode | null;
/**
 * An error shaped like `@yoyocontrol/screen-web`'s `RequestError` (`status`, the server's `message`, its JSON `body`):
 * what a link answers where HTTP would have answered with a status — `input.rejected`, a local 429.
 */
export declare class LinkRequestError extends Error {
    readonly status: number;
    readonly body?: unknown | undefined;
    constructor(status: number, message: string, body?: unknown | undefined);
}
