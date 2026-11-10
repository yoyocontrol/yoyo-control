import { LinkError } from "@yoyocontrol/link-web";
import { RequestError } from "@yoyocontrol/screen-web";
import { SignalError } from "./signal.js";

/**
 * Why a Mac can't be reached or used:
 * - `unpaired`: the Mac no longer knows this browser (removed there, or this browser's certificate changed): pair again;
 * - `offline`: the Mac isn't registered at the relay (asleep, off, remote access or the relay switched off);
 * - `unreachable`: the relay answered but no connection came up in time (no path between the two networks);
 * - `busy`: the Mac refused for now (too many tries, too many sessions): try again later;
 * - `verification`: the answer wasn't signed by the paired Mac: never retried;
 * - `unsupported`: this browser has no WebRTC / WebCrypto (or isn't a secure context);
 * - `pairing`: the pairing code was refused (wrong, used, expired, or no code is being shown).
 *
 * It is a screen-web `RequestError` whose `status` says the same to the pages: 401 unpaired, 523 offline and 522
 * unreachable (the "origin unreachable / timed out" statuses the pages already read as the way being down, never
 * the Mac's own), 429 busy, 495 verification, 501 unsupported, 403 pairing.
 */
export type DirectErrorKind = "unpaired" | "offline" | "unreachable" | "busy" | "verification" | "unsupported" | "pairing";

const STATUS: Record<DirectErrorKind, number> = {
  unpaired: 401,
  offline: 523,
  unreachable: 522,
  busy: 429,
  verification: 495,
  unsupported: 501,
  pairing: 403,
};

export class DirectError extends RequestError {
  constructor(
    readonly kind: DirectErrorKind,
    message: string,
    options?: { cause?: unknown },
  ) {
    super(STATUS[kind], message, { error: message, code: kind });
    this.name = "DirectError";
    if (options?.cause !== undefined) (this as { cause?: unknown }).cause = options.cause;
  }

  /** Whether trying again (later) may work: not for `unpaired`, `verification`, `unsupported`, `pairing`. */
  get retryable(): boolean {
    return this.kind === "offline" || this.kind === "unreachable" || this.kind === "busy";
  }
}

/** The words a host shows for each kind (its language); a kind without one keeps the technical message. `permissions`:
 *  what "Request permissions" answers (a browser can't make the Mac show its prompts). */
export type DirectMessages = Partial<Record<DirectErrorKind | "permissions", string>>;

/** A dial's failure (link-web's `LinkError`, the relay's `SignalError`) as a `DirectError`; `pairing`: dialed with a
 *  pairing code (an `unauthorized` is the code's); `messages`: the host's words for the kinds. */
export function directError(e: unknown, pairing = false, messages: DirectMessages = {}): DirectError {
  if (e instanceof DirectError) return e;
  const d = classify(e, pairing);
  const words = messages[d.kind as DirectErrorKind];
  return words ? new DirectError(d.kind, words, { cause: (d as { cause?: unknown }).cause }) : d;
}

function classify(e: unknown, pairing: boolean): DirectError {
  if (e instanceof LinkError) {
    switch (e.kind) {
      case "denied":
        if (e.code === "unauthorized") return new DirectError(pairing ? "pairing" : "unpaired", e.message, { cause: e });
        return new DirectError("busy", e.message, { cause: e });
      case "signal": {
        const cause = (e as { cause?: unknown }).cause;
        if (cause instanceof SignalError) {
          if (cause.offline) return new DirectError("offline", "the Mac is not online", { cause: e });
          if (cause.status === 429) return new DirectError("busy", cause.message, { cause: e });
          if (cause.status === 504) return new DirectError("unreachable", "the Mac did not answer", { cause: e });
        }
        return new DirectError("unreachable", e.message, { cause: e });
      }
      case "verification":
        return new DirectError("verification", e.message, { cause: e });
      case "unsupported":
        return new DirectError("unsupported", e.message, { cause: e });
      default:
        return new DirectError("unreachable", e.message, { cause: e });
    }
  }
  // fetch's own failure (the relay itself unreachable, offline browser)
  return new DirectError("unreachable", e instanceof Error ? e.message : String(e), { cause: e });
}
