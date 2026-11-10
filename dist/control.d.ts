import type { ScreenLink } from "./link.js";
import { type ScreenTransport } from "./transport.js";
import type { ControlDevice, Input } from "./types.js";
/** One input (`POST /input`); a refusal is a RequestError (a 409's body says why: `code: "controlled-elsewhere"`…). */
export declare function sendInput(transport: ScreenTransport, input: Input): Promise<void>;
/**
 * Take ("user") or release ("none") control (`POST /control { controller, device? }`) → the server's JSON answer.
 * `keepalive`: the page may be going away (the request outlives it; no answer is read: null).
 */
export declare function setControl<T = unknown>(transport: ScreenTransport, controller: "user" | "none", device?: ControlDevice, keepalive?: boolean): Promise<T | null>;
/** The `code` a 409 carries when another device holds control (`POST /input` / `POST /control`). */
export declare const CONTROLLED_ELSEWHERE = "controlled-elsewhere";
/**
 * Take (`take`) or release control over a link (`control.take` / `control.release`), as `setControl` would over HTTP:
 * granted → `{ controller, device }` (the holder); not granted with another device holding it → a `RequestError(409)`
 * whose body is `{ code: "controlled-elsewhere", controllerDevice }` (what `/control`'s 409 says); not granted and nobody
 * holding it → `RequestError(409)`. Releasing always resolves.
 */
export declare function linkSetControl(link: Pick<ScreenLink, "control">, take: boolean): Promise<{
    controller: "user" | "none";
    device: ControlDevice | null;
}>;
/** An input sender on a link (`InputQueueOptions.link`'s): `/input`'s JSON, `move` for pointer moves. Its 429 (too many
 *  unacknowledged) is thrown as a `RequestError`. */
export declare function linkInputSender(link: Pick<ScreenLink, "sendInput">): (input: Input) => void;
