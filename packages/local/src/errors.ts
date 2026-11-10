/** The HTTP statuses a LocalError carries (what a caller's own HTTP layer can pass on as they are). */
export type ErrorStatus = 400 | 403 | 404 | 409 | 413 | 502 | 503;

/**
 * Every failure of this package: a message for people, the HTTP status it maps to (a proxy answers with it), and more
 * fields for the error body (`install` when Yoyo Control is missing or too old, `code` of a 409…).
 */
export class LocalError extends Error {
  constructor(
    message: string,
    readonly status: ErrorStatus,
    /** More fields of the error body, next to `error`. */
    readonly extra?: Record<string, unknown>,
  ) {
    super(message);
  }

  /** The response body: `{ error, ...extra }`. */
  get body(): Record<string, unknown> {
    return { error: this.message, ...this.extra };
  }
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
export function errorText(json: unknown, fallback: string): string {
  return json && typeof json === "object" && typeof (json as { error?: unknown }).error === "string" ? (json as { error: string }).error : fallback;
}

/**
 * A server's error answer as a LocalError: its `error` text (else "screen helper answered HTTP <status>"), its status
 * when it is one a caller passes on (400 / 403 = a missing permission / 404 / 409 / 413 / 503), else 502.
 */
export function answerError(status: number, json: unknown): LocalError {
  const mapped = status === 400 || status === 403 || status === 404 || status === 409 || status === 413 || status === 503 ? status : 502;
  return new LocalError(errorText(json, `screen helper answered HTTP ${status}`), mapped);
}
