/** Session close codes (docs/LINK.md「控制流」): the QUIC application codes, carried by `bye.code` on WebRTC. */
export const CloseCode = {
  normal: 0,
  unauthorized: 1,
  rateLimited: 2,
  busy: 3,
  protocol: 4,
  shuttingDown: 5,
  replaced: 6,
} as const;

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
export class LinkError extends Error {
  constructor(
    readonly kind: LinkErrorKind,
    message: string,
    readonly code?: DenyCode,
    options?: { cause?: unknown },
  ) {
    super(message, options);
    this.name = "LinkError";
  }
}

/** An unknown deny code reads as `busy` (try again later, don't forget the computer), as in the Rust core. */
export function denyCode(s: unknown): DenyCode {
  return s === "unauthorized" || s === "rate-limited" ? s : "busy";
}

/** The deny code a close code before `welcome` stands for (1 / 2 / 3), else null. */
export function denyForClose(code: number | undefined): DenyCode | null {
  if (code === CloseCode.unauthorized) return "unauthorized";
  if (code === CloseCode.rateLimited) return "rate-limited";
  if (code === CloseCode.busy) return "busy";
  return null;
}

/**
 * An error shaped like `@yoyocontrol/screen-web`'s `RequestError` (`status`, the server's `message`, its JSON `body`):
 * what a link answers where HTTP would have answered with a status — `input.rejected`, a local 429.
 */
export class LinkRequestError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly body?: unknown,
  ) {
    super(message);
    this.name = "LinkRequestError";
  }
}
