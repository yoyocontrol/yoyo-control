import type { ScreenLink } from "@yoyocontrol/screen-web";
import { LinkRequestError } from "./errors.js";
import { type LinkSession } from "./session.js";
/** `control` answers wait this long. */
export declare const CONTROL_TIMEOUT_MS = 5000;
/** `input.rejected {seq, status, code, message, controllerDevice?}` as the error `POST /input` would have answered. */
export declare function inputRejection(o: Record<string, unknown>): LinkRequestError;
/**
 * A session's screen media as `@yoyocontrol/screen-web`'s `ScreenLink` (the iOS kit's `YoyoLinkConnection`): video
 * and sound streams with their own ids (1–255), the media layer's frames / packets / cursor positions handed to the
 * stream they belong to, `video.status` / `cursor.shape` / `video.opened`… from the control channel likewise, input
 * straight into the media layer, `control.take` / `control.release` with their answers, the playout report as
 * `report` (with this side's per-frame fates, `rx`). When the session ends every open stream hears `failed`.
 */
export declare function linkScreen(session: LinkSession): ScreenLink & {
    readonly session: LinkSession;
};
