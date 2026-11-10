// A signaling server (docs/RELAY.md「信令服务」, `relay/signal` is one): the browser's offers go to
// `POST <server>/v1/rtc/<fp hex>`, TURN credentials come from `POST <server>/v1/turn/<fp hex>`. A pairing remembers the
// one it signaled through (`relay`). None is built in: whoever runs the page names its own (`DirectWebOptions.relay`).
/** More signaling servers a dial tries before the Mac's own (`signalPaths`): none by default. */
export const DEFAULT_SIGNALS = [];
/** How long a signaling path that isn't the last one gets before the next is tried (answers take well under 1 s). */
export const SIGNAL_ATTEMPT_MS = 5000;
/** STUN servers WebRTC gets by default (its own reflexive candidates, for hole punching): none built in. */
export const DEFAULT_ICE_SERVERS = [];
/** How long `relayTurn` waits for the relay; without an answer the dial goes on with STUN only. */
export const TURN_TIMEOUT_MS = 3000;
const turnCache = new Map();
/**
 * TURN servers for a dial to the Mac `fingerprint` (docs/RELAY.md「TURN」): `POST <relay>/v1/turn/<hex>` → uu's coturn
 * with short-lived credentials, so the browser's WebRTC can relay when it and the Mac can't reach each other directly
 * (5G that is IPv6 only, symmetric NATs). Kept until an hour before they run out. Any failure (an older relay, no
 * network, a timeout) is `[]`: the dial goes on with STUN alone, as before.
 */
export async function relayTurn(relay, fingerprint, fetchImpl = (i, o) => fetch(i, o), now = Date.now()) {
    const hex = fingerprint.replace(/^sha256:/, "");
    const url = `${relay.replace(/\/+$/, "")}/v1/turn/${hex}`;
    const kept = turnCache.get(url);
    if (kept && kept.until > now)
        return kept.servers;
    try {
        const res = await fetchImpl(url, {
            method: "POST",
            cache: "no-store",
            credentials: "omit",
            referrerPolicy: "no-referrer",
            signal: AbortSignal.timeout(TURN_TIMEOUT_MS),
        });
        if (!res.ok)
            return [];
        const body = (await res.json());
        const servers = Array.isArray(body.iceServers)
            ? body.iceServers.filter((s) => s && (typeof s.urls === "string" || Array.isArray(s.urls)))
            : [];
        const ttl = typeof body.ttl === "number" ? body.ttl : 0;
        if (servers.length && ttl > 7200)
            turnCache.set(url, { servers, until: now + (ttl - 3600) * 1000 });
        return servers;
    }
    catch {
        return [];
    }
}
/** Why the relay didn't hand back an answer. `offline`: no Mac in the room (503). */
export class SignalError extends Error {
    status;
    offline;
    constructor(status, message, offline = status === 503) {
        super(message);
        this.status = status;
        this.offline = offline;
        this.name = "SignalError";
    }
}
/**
 * The signaling path through the relay for the Mac with `fingerprint` (`sha256:<hex>`): `POST <relay>/v1/rtc/<hex>`
 * with the offer JSON → the Mac's answer (verified by link-web against the pinned fingerprint). A non-2xx answer
 * throws a `SignalError` with the relay's (or the Mac's) status and message.
 */
export function relaySignal(relay, fingerprint, fetchImpl = (i, o) => fetch(i, o)) {
    const hex = fingerprint.replace(/^sha256:/, "");
    const url = `${relay.replace(/\/+$/, "")}/v1/rtc/${hex}`;
    return async (offer) => {
        const res = await fetchImpl(url, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(offer),
            cache: "no-store",
            credentials: "omit",
            referrerPolicy: "no-referrer",
        });
        if (!res.ok) {
            let message = `HTTP ${res.status}`;
            try {
                const body = (await res.json());
                if (typeof body.error === "string" && body.error)
                    message = body.error;
            }
            catch {
                /* not JSON */
            }
            throw new SignalError(res.status, message);
        }
        return res.json();
    };
}
/** The signaling paths of a dial, in order: `signals`, then the Mac's own (each once). */
export function signalPaths(signals, relay) {
    return [...new Set([...signals, relay].filter(Boolean).map((u) => u.replace(/\/+$/, "")))];
}
/** The path that last answered for a Mac (fingerprint → index into its paths): the next dial starts there. */
const lastGood = new Map();
/**
 * Signals through the first of `paths` that answers (`relaySignal` on each): a path that can't be reached, times out
 * (`SIGNAL_ATTEMPT_MS`, all but the last) or has no Mac in the room passes
 * the offer to the next. Any other refusal is the Mac's own (it would say the same through every path) and is thrown.
 * The path that answered goes first next time.
 */
export function fallbackSignal(paths, fingerprint, fetchImpl = (i, o) => fetch(i, o)) {
    return async (offer) => {
        const good = lastGood.get(fingerprint);
        const order = good && paths.includes(good) ? [good, ...paths.filter((p) => p !== good)] : [...paths];
        let failure = new SignalError(503, "no signaling path");
        for (const [i, path] of order.entries()) {
            const last = i === order.length - 1;
            const attempt = last ? fetchImpl : (input, init) => fetchImpl(input, { ...init, signal: AbortSignal.timeout(SIGNAL_ATTEMPT_MS) });
            try {
                const answer = await relaySignal(path, fingerprint, attempt)(offer);
                lastGood.set(fingerprint, path);
                return answer;
            }
            catch (e) {
                // a refusal from a room with a Mac in it is the Mac's: the same everywhere
                if (e instanceof SignalError && ![404, 502, 503, 504].includes(e.status))
                    throw e;
                // keep the most telling failure: a path's own answer over not reaching one
                if (e instanceof SignalError || !(failure instanceof SignalError) || failure.message === "no signaling path")
                    failure = e;
            }
        }
        throw failure;
    };
}
/** TURN servers from the first of `paths` that hands some out (`relayTurn` on each); `[]` when none does. */
export async function pathsTurn(paths, fingerprint, fetchImpl) {
    for (const path of paths) {
        const servers = await relayTurn(path, fingerprint, fetchImpl);
        if (servers.length)
            return servers;
    }
    return [];
}
