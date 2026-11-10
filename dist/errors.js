/** Session close codes (docs/LINK.md「控制流」): the QUIC application codes, carried by `bye.code` on WebRTC. */
export const CloseCode = {
    normal: 0,
    unauthorized: 1,
    rateLimited: 2,
    busy: 3,
    protocol: 4,
    shuttingDown: 5,
    replaced: 6,
};
/** Every error of this package. `code` is the deny code for `kind: "denied"`. */
export class LinkError extends Error {
    kind;
    code;
    constructor(kind, message, code, options) {
        super(message, options);
        this.kind = kind;
        this.code = code;
        this.name = "LinkError";
    }
}
/** An unknown deny code reads as `busy` (try again later, don't forget the computer), as in the Rust core. */
export function denyCode(s) {
    return s === "unauthorized" || s === "rate-limited" ? s : "busy";
}
/** The deny code a close code before `welcome` stands for (1 / 2 / 3), else null. */
export function denyForClose(code) {
    if (code === CloseCode.unauthorized)
        return "unauthorized";
    if (code === CloseCode.rateLimited)
        return "rate-limited";
    if (code === CloseCode.busy)
        return "busy";
    return null;
}
/**
 * An error shaped like `@yoyocontrol/screen-web`'s `RequestError` (`status`, the server's `message`, its JSON `body`):
 * what a link answers where HTTP would have answered with a status — `input.rejected`, a local 429.
 */
export class LinkRequestError extends Error {
    status;
    body;
    constructor(status, message, body) {
        super(message);
        this.status = status;
        this.body = body;
        this.name = "LinkRequestError";
    }
}
