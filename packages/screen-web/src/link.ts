import type { ControlDevice } from "./types.js";

/**
 * A media route that carries the screen itself (docs/LINK.md「会话协议」): the browser's mirror of the iOS kit's
 * `YoyoScreenLink`. When the way in use is a uu Link session, the page's `VideoStream`, `ScreenAudio`, cursor and
 * `InputQueue` run over it instead of HTTP: `video.open` with `/stream`'s query (no `ack`: the link's media layer
 * repairs, orders and paces the pictures), `audio.open` with `/audio`'s, input straight into the media layer (nothing
 * waits for an answer), control as `control.take` / `control.release`. `@yoyocontrol/link-web`'s `linkScreen(session)`
 * is one; a host may bring its own (a test double, another transport).
 *
 * Callbacks come in order on the page's thread. Every text here (`pathLabel`, `statsLine`, reasons) is technical and
 * not localized.
 */
export interface ScreenLink {
  /** For the stats line: `link lan`, `link direct`, `link punched`, `link relay`. */
  readonly pathLabel: string;
  /** The path in use is on this device's local network now (the playout's and the sound's tighter local values). */
  readonly isLocalNetwork: boolean;
  /** The path's smallest round trip of the last seconds (ms; null: not measured yet): the touch budget's source. */
  readonly rttMinMs: number | null;
  /** The link's own numbers for the stats line, in place of the server's network grade (the `link:` line's body:
   *  `lan wifi rtt 0.4/1.2/2.0 ms loss 0.0 % …`). null: none. */
  readonly statsLine: string | null;
  /** The session ended (by either side or the network): nothing more comes from it. */
  readonly isClosed: boolean;
  /** Resolves with why, when the session ends. */
  readonly closed: Promise<string>;

  /** Opens a video stream (`video.open`): `query` is exactly the query `/stream` would get (without `ack`). Its events
   *  go to `onEvent` until it is closed (by `close()`, the server — `closed` — or the session's end — `failed`). */
  openVideo(query: string, onEvent: (event: ScreenLinkVideoEvent) => void): ScreenLinkVideo;
  /** Opens the sound (`audio.open`), `query` as `/audio` would get it. */
  openAudio(query: string, onEvent: (event: ScreenLinkAudioEvent) => void): ScreenLinkAudio;
  /**
   * One input, `/input`'s JSON body, sent at once (the link orders and repeats it; nothing waits for an answer).
   * `move`: a pointer move (the newest wins), else a discrete event (exactly once, in order). Throws a
   * `RequestError(429)`-shaped error (`status: 429`) when too many discrete events wait for their ack, or the session's
   * error once it ended.
   */
  sendInput(json: string, move: boolean): void;
  /** Where input the computer refused (`input.rejected`: 409 not in control or controlled elsewhere, 400…) and input never
   *  acknowledged (a network failure) are reported. One handler; null removes it. */
  setInputErrorHandler(handler: ((error: unknown) => void) | null): void;
  /** `control.take` (`take`) or `control.release`, and the server's answer (`control` with the same `rid`). Rejects
   *  after a timeout or when the session ends. */
  control(take: boolean): Promise<ScreenLinkControlAnswer>;
}

/** The answer to `control.take` / `control.release`. */
export interface ScreenLinkControlAnswer {
  /** The holder is this session's device. */
  granted: boolean;
  /** Who holds control now (null: nobody). */
  holder: ControlDevice | null;
}

/** A link frame's kind: `recovery` = a delta on an acknowledged long-term reference. */
export type ScreenLinkFrameKind = "key" | "delta" | "refine" | "keepalive" | "recovery";

/** One picture of a link's video stream: in order, its reference chain intact. */
export interface ScreenLinkFrame {
  /** The stream's frame number (from 1). */
  number: number;
  /** `h264` / `hevc`. */
  codec: string;
  kind: ScreenLinkFrameKind;
  /** Pixels (0: not said; the access unit's SPS knows). */
  width: number;
  height: number;
  /** When the computer captured it: ms since 1970 (its clock; null: not said). */
  captureMs: number | null;
  /** One Annex-B access unit. The receiver owns it (no copy is kept on the other side). */
  au: Uint8Array;
}

/** What a link's video stream delivers. */
export type ScreenLinkVideoEvent =
  /** `video.opened`: its codec and size, and what `/stream`'s response headers would have said (`X-Display`…). */
  | { type: "opened"; codec: string | null; width: number | null; height: number | null; headers: Record<string, string> }
  /** A picture for the decoder (answer with `ScreenLinkVideo.decoded`). */
  | { type: "frame"; frame: ScreenLinkFrame }
  /** `video.status`: a status part's JSON text. */
  | { type: "status"; json: string }
  /** A cursor part's JSON text: a position from the datagrams, or a shape (`cursor.shape`). */
  | { type: "cursor"; json: string }
  /** `video.error`: what the HTTP stream would have answered (401: the credential is no longer known). */
  | { type: "error"; status: number; message: string | null }
  /** The computer ended the stream (`video.closed`). Nothing comes after it. */
  | { type: "closed"; reason: string | null }
  /** The session under it ended or failed. Nothing comes after it. */
  | { type: "failed"; reason: string };

/** An open video stream of a link. */
export interface ScreenLinkVideo {
  /** The decoder took (`ok`) or failed on `frame`: what the computer's encoder references next (and a key picture
   *  after a failure). */
  decoded(frame: number, ok: boolean): void;
  /** The decoder can't go on: a key picture. */
  requestKeyframe(): void;
  /** The playout report (what rides the HTTP stream's acks), sent as `report`. */
  report(report: Record<string, unknown>): void;
  close(): void;
}

/** What a link's sound delivers. */
export type ScreenLinkAudioEvent =
  /** `audio.opened`: its format by the names of `/audio`'s response headers (`X-Audio-Codec`, `X-Audio-Rate`,
   *  `X-Audio-Channels`, `X-Audio-Frames`, `X-Audio-Cookie`, `X-Audio-Video-Offset`). */
  | { type: "opened"; format: Record<string, string> }
  /** One Opus packet: its sequence number (+1 a packet; a gap is a lost one) and the time of its first sample (ms since
   *  1970, the computer's clock as the pictures' `captureMs`). */
  | { type: "packet"; seq: number; timeMs: number; data: Uint8Array }
  /** `/audio`'s answer (404 / 403 / 501: none; 503: not now). */
  | { type: "error"; status: number; message: string | null }
  /** The computer ended it (`audio.closed`). */
  | { type: "closed"; reason: string | null }
  /** The session under it ended or failed. */
  | { type: "failed"; reason: string };

/** An open sound stream of a link. */
export interface ScreenLinkAudio {
  close(): void;
}

/** `/stream`'s JSON body (what `VideoStream` posts) as a link's `video.open` query: every field but `ack`, in order. */
export function linkStreamQuery(body: Record<string, unknown>): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(body)) {
    if (k === "ack" || v === undefined || v === null) continue;
    q.set(k, String(v));
  }
  return q.toString();
}
