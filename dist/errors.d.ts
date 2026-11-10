/** The HTTP statuses a LocalError carries (what a caller's own HTTP layer can pass on as they are). */
export type ErrorStatus = 400 | 403 | 404 | 409 | 413 | 502 | 503;
/**
 * Every failure of this package: a message for people, the HTTP status it maps to (a proxy answers with it), and more
 * fields for the error body (`install` when Yoyo Control is missing or too old, `code` of a 409…).
 */
export declare class LocalError extends Error {
    readonly status: ErrorStatus;
    /** More fields of the error body, next to `error`. */
    readonly extra?: Record<string, unknown> | undefined;
    constructor(message: string, status: ErrorStatus, 
    /** More fields of the error body, next to `error`. */
    extra?: Record<string, unknown> | undefined);
    /** The response body: `{ error, ...extra }`. */
    get body(): Record<string, unknown>;
}
/** Why Yoyo Control has to be installed or updated (`LocalError.extra.install`). */
export interface InstallHint {
    reason: "not-installed" | "outdated";
    /** Where to get it (the caller's `downloadUrl`). */
    url: string;
    /** "outdated": the version that answered, when it said. */
    version?: string;
}
/** The `{ error }` text of a server's error answer, else `fallback`. */
export declare function errorText(json: unknown, fallback: string): string;
/**
 * A server's error answer as a LocalError: its `error` text (else "screen helper answered HTTP <status>"), its status
 * when it is one a caller passes on (400 / 403 = a missing permission / 404 / 409 / 413 / 503), else 502.
 */
export declare function answerError(status: number, json: unknown): LocalError;
