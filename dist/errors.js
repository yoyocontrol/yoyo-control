import { LinkError } from "@yoyocontrol/link-web";
import { RequestError } from "@yoyocontrol/screen-web";
import { SignalError } from "./signal.js";
const STATUS = {
    unpaired: 401,
    offline: 523,
    unreachable: 522,
    busy: 429,
    verification: 495,
    unsupported: 501,
    pairing: 403,
};
export class DirectError extends RequestError {
    kind;
    constructor(kind, message, options) {
        super(STATUS[kind], message, { error: message, code: kind });
        this.kind = kind;
        this.name = "DirectError";
        if (options?.cause !== undefined)
            this.cause = options.cause;
    }
    /** Whether trying again (later) may work: not for `unpaired`, `verification`, `unsupported`, `pairing`. */
    get retryable() {
        return this.kind === "offline" || this.kind === "unreachable" || this.kind === "busy";
    }
}
/** A dial's failure (link-web's `LinkError`, the relay's `SignalError`) as a `DirectError`; `pairing`: dialed with a
 *  pairing code (an `unauthorized` is the code's); `messages`: the host's words for the kinds. */
export function directError(e, pairing = false, messages = {}) {
    if (e instanceof DirectError)
        return e;
    const d = classify(e, pairing);
    const words = messages[d.kind];
    return words ? new DirectError(d.kind, words, { cause: d.cause }) : d;
}
function classify(e, pairing) {
    if (e instanceof LinkError) {
        switch (e.kind) {
            case "denied":
                if (e.code === "unauthorized")
                    return new DirectError(pairing ? "pairing" : "unpaired", e.message, { cause: e });
                return new DirectError("busy", e.message, { cause: e });
            case "signal": {
                const cause = e.cause;
                if (cause instanceof SignalError) {
                    if (cause.offline)
                        return new DirectError("offline", "the Mac is not online", { cause: e });
                    if (cause.status === 429)
                        return new DirectError("busy", cause.message, { cause: e });
                    if (cause.status === 504)
                        return new DirectError("unreachable", "the Mac did not answer", { cause: e });
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
