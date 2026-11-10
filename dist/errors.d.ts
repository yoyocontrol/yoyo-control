import { RequestError } from "@yoyocontrol/screen-web";
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
export declare class DirectError extends RequestError {
    readonly kind: DirectErrorKind;
    constructor(kind: DirectErrorKind, message: string, options?: {
        cause?: unknown;
    });
    /** Whether trying again (later) may work: not for `unpaired`, `verification`, `unsupported`, `pairing`. */
    get retryable(): boolean;
}
/** The words a host shows for each kind (its language); a kind without one keeps the technical message. `permissions`:
 *  what "Request permissions" answers (a browser can't make the Mac show its prompts). */
export type DirectMessages = Partial<Record<DirectErrorKind | "permissions", string>>;
/** A dial's failure (link-web's `LinkError`, the relay's `SignalError`) as a `DirectError`; `pairing`: dialed with a
 *  pairing code (an `unauthorized` is the code's); `messages`: the host's words for the kinds. */
export declare function directError(e: unknown, pairing?: boolean, messages?: DirectMessages): DirectError;
