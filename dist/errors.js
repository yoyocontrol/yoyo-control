/**
 * Every failure of this package: a message for people, the HTTP status it maps to (a proxy answers with it), and more
 * fields for the error body (`install` when Yoyo Control is missing or too old, `code` of a 409…).
 */
export class LocalError extends Error {
    status;
    extra;
    constructor(message, status, 
    /** More fields of the error body, next to `error`. */
    extra) {
        super(message);
        this.status = status;
        this.extra = extra;
    }
    /** The response body: `{ error, ...extra }`. */
    get body() {
        return { error: this.message, ...this.extra };
    }
}
/** The `{ error }` text of a server's error answer, else `fallback`. */
export function errorText(json, fallback) {
    return json && typeof json === "object" && typeof json.error === "string" ? json.error : fallback;
}
/**
 * A server's error answer as a LocalError: its `error` text (else "screen helper answered HTTP <status>"), its status
 * when it is one a caller passes on (400 / 403 = a missing permission / 404 / 409 / 413 / 503), else 502.
 */
export function answerError(status, json) {
    const mapped = status === 400 || status === 403 || status === 404 || status === 409 || status === 413 || status === 503 ? status : 502;
    return new LocalError(errorText(json, `screen helper answered HTTP ${status}`), mapped);
}
