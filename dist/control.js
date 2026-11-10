import { RequestError, requestError } from "./transport.js";
/** One input (`POST /input`); a refusal is a RequestError (a 409's body says why: `code: "controlled-elsewhere"`…). */
export async function sendInput(transport, input) {
    const res = await transport.fetch("/input", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(input),
    });
    if (!res.ok)
        throw await requestError(res);
}
/**
 * Take ("user") or release ("none") control (`POST /control { controller, device? }`) → the server's JSON answer.
 * `keepalive`: the page may be going away (the request outlives it; no answer is read: null).
 */
export async function setControl(transport, controller, device, keepalive = false) {
    const res = await transport.fetch("/control", {
        method: "POST",
        keepalive,
        headers: { "content-type": "application/json" },
        body: JSON.stringify(device ? { controller, device } : { controller }),
    });
    if (!res.ok)
        throw await requestError(res);
    return keepalive ? null : (await res.json());
}
/** The `code` a 409 carries when another device holds control (`POST /input` / `POST /control`). */
export const CONTROLLED_ELSEWHERE = "controlled-elsewhere";
/**
 * Take (`take`) or release control over a link (`control.take` / `control.release`), as `setControl` would over HTTP:
 * granted → `{ controller, device }` (the holder); not granted with another device holding it → a `RequestError(409)`
 * whose body is `{ code: "controlled-elsewhere", controllerDevice }` (what `/control`'s 409 says); not granted and nobody
 * holding it → `RequestError(409)`. Releasing always resolves.
 */
export async function linkSetControl(link, take) {
    const a = await link.control(take);
    if (!take)
        return { controller: a.holder ? "user" : "none", device: a.holder };
    if (a.granted)
        return { controller: "user", device: a.holder };
    if (a.holder)
        throw new RequestError(409, "controlled elsewhere", { error: "controlled elsewhere", code: CONTROLLED_ELSEWHERE, controllerDevice: a.holder });
    throw new RequestError(409, "control not granted", { error: "control not granted" });
}
/** An input sender on a link (`InputQueueOptions.link`'s): `/input`'s JSON, `move` for pointer moves. Its 429 (too many
 *  unacknowledged) is thrown as a `RequestError`. */
export function linkInputSender(link) {
    return (input) => {
        try {
            link.sendInput(JSON.stringify(input), input.type === "move");
        }
        catch (e) {
            const status = e && typeof e === "object" && "status" in e ? e.status : null;
            if (typeof status === "number" && !(e instanceof RequestError))
                throw new RequestError(status, e instanceof Error ? e.message : `HTTP ${status}`);
            throw e;
        }
    };
}
