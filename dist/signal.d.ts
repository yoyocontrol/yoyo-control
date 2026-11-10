import type { RtcOffer } from "@yoyocontrol/link-web";
/** More signaling servers a dial tries before the Mac's own (`signalPaths`): none by default. */
export declare const DEFAULT_SIGNALS: string[];
/** How long a signaling path that isn't the last one gets before the next is tried (answers take well under 1 s). */
export declare const SIGNAL_ATTEMPT_MS = 5000;
/** STUN servers WebRTC gets by default (its own reflexive candidates, for hole punching): none built in. */
export declare const DEFAULT_ICE_SERVERS: RTCIceServer[];
/** How long `relayTurn` waits for the relay; without an answer the dial goes on with STUN only. */
export declare const TURN_TIMEOUT_MS = 3000;
/**
 * TURN servers for a dial to the Mac `fingerprint` (docs/RELAY.md「TURN」): `POST <relay>/v1/turn/<hex>` → uu's coturn
 * with short-lived credentials, so the browser's WebRTC can relay when it and the Mac can't reach each other directly
 * (5G that is IPv6 only, symmetric NATs). Kept until an hour before they run out. Any failure (an older relay, no
 * network, a timeout) is `[]`: the dial goes on with STUN alone, as before.
 */
export declare function relayTurn(relay: string, fingerprint: string, fetchImpl?: typeof fetch, now?: number): Promise<RTCIceServer[]>;
/** Why the relay didn't hand back an answer. `offline`: no Mac in the room (503). */
export declare class SignalError extends Error {
    readonly status: number;
    readonly offline: boolean;
    constructor(status: number, message: string, offline?: boolean);
}
/**
 * The signaling path through the relay for the Mac with `fingerprint` (`sha256:<hex>`): `POST <relay>/v1/rtc/<hex>`
 * with the offer JSON → the Mac's answer (verified by link-web against the pinned fingerprint). A non-2xx answer
 * throws a `SignalError` with the relay's (or the Mac's) status and message.
 */
export declare function relaySignal(relay: string, fingerprint: string, fetchImpl?: typeof fetch): (offer: RtcOffer) => Promise<unknown>;
/** The signaling paths of a dial, in order: `signals`, then the Mac's own (each once). */
export declare function signalPaths(signals: readonly string[], relay: string): string[];
/**
 * Signals through the first of `paths` that answers (`relaySignal` on each): a path that can't be reached, times out
 * (`SIGNAL_ATTEMPT_MS`, all but the last) or has no Mac in the room passes
 * the offer to the next. Any other refusal is the Mac's own (it would say the same through every path) and is thrown.
 * The path that answered goes first next time.
 */
export declare function fallbackSignal(paths: readonly string[], fingerprint: string, fetchImpl?: typeof fetch): (offer: RtcOffer) => Promise<unknown>;
/** TURN servers from the first of `paths` that hands some out (`relayTurn` on each); `[]` when none does. */
export declare function pathsTurn(paths: readonly string[], fingerprint: string, fetchImpl?: typeof fetch): Promise<RTCIceServer[]>;
