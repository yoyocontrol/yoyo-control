import { LinkError, LinkRequestError } from "./errors.js";
import { ACTIVE_IDLE_MS } from "./session.js";
/** `control` answers wait this long. */
export const CONTROL_TIMEOUT_MS = 5000;
/** The `/audio` response header each `audio.opened` field stands for. */
const AUDIO_FIELDS = {
    codec: "X-Audio-Codec",
    rate: "X-Audio-Rate",
    channels: "X-Audio-Channels",
    frames: "X-Audio-Frames",
    cookie: "X-Audio-Cookie",
    videoOffsetMs: "X-Audio-Video-Offset",
};
const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v) => (typeof v === "string" ? v : null);
function device(v) {
    if (!v || typeof v !== "object")
        return null;
    const o = v;
    if (typeof o.id !== "string" || !o.id)
        return null;
    return typeof o.name === "string" ? { id: o.id, name: o.name } : { id: o.id };
}
/** `input.rejected {seq, status, code, message, controllerDevice?}` as the error `POST /input` would have answered. */
export function inputRejection(o) {
    const status = num(o.status) ?? 400;
    const message = str(o.message) ?? `HTTP ${status}`;
    const body = { error: message };
    if (typeof o.code === "string")
        body.code = o.code;
    const holder = device(o.controllerDevice ?? o.holder);
    if (holder)
        body.controllerDevice = holder;
    return new LinkRequestError(status, message, body);
}
/**
 * A session's screen media as `@yoyocontrol/screen-web`'s `ScreenLink` (the iOS kit's `YoyoLinkConnection`): video
 * and sound streams with their own ids (1–255), the media layer's frames / packets / cursor positions handed to the
 * stream they belong to, `video.status` / `cursor.shape` / `video.opened`… from the control channel likewise, input
 * straight into the media layer, `control.take` / `control.release` with their answers, the playout report as
 * `report` (with this side's per-frame fates, `rx`). When the session ends every open stream hears `failed`.
 */
export function linkScreen(session) {
    const media = session.media;
    if (!media)
        throw new LinkError("media", "the session was dialed without its media layer");
    const streams = new Map();
    const waiters = new Map();
    let next = 0;
    let inputError = null;
    let ended = null;
    let resolveClosed;
    const closed = new Promise((r) => (resolveClosed = r));
    const send = (m, failed) => {
        try {
            session.sendControl(m);
        }
        catch (e) {
            failed?.(e instanceof Error ? e.message : String(e));
        }
    };
    /** With a video stream open the server never goes quiet (link.stats every 2 s, the stream's keepalives): a silence
     *  of `ACTIVE_IDLE_MS` ends the session, so the page falls back in seconds, not after the idle timeout. */
    const watch = () => session.setActivityTimeout([...streams.values()].some((s) => s.video) ? ACTIVE_IDLE_MS : null);
    /** A new stream id (1…255, the oldest reused after a wrap). */
    const register = (s) => {
        for (let i = 0; i < 255; i++) {
            next = next === 255 ? 1 : next + 1;
            if (!streams.has(next))
                break;
        }
        streams.set(next, s);
        watch();
        return next;
    };
    const idOf = (v) => {
        const n = num(v);
        return n !== null && Number.isInteger(n) && n >= 1 && n <= 255 ? n : null;
    };
    /** A stream the server ended: forgotten here and in the media layer. */
    const drop = (id, video) => {
        if (id === null)
            return undefined;
        const s = streams.get(id);
        if (!s)
            return undefined;
        streams.delete(id);
        watch();
        if (video)
            media.closeVideo(id);
        else
            media.closeAudio(id);
        return s;
    };
    const offControl = session.onControl((m) => {
        const id = idOf(m.id);
        switch (m.t) {
            case "video.opened": {
                const headers = {};
                if (m.headers && typeof m.headers === "object")
                    for (const [k, v] of Object.entries(m.headers))
                        headers[k] = String(v);
                if (id !== null)
                    streams.get(id)?.video?.({ type: "opened", codec: str(m.codec), width: num(m.width), height: num(m.height), headers });
                break;
            }
            case "video.error":
                drop(id, true)?.video?.({ type: "error", status: num(m.status) ?? 500, message: str(m.message) });
                break;
            case "video.closed":
                drop(id, true)?.video?.({ type: "closed", reason: str(m.reason) });
                break;
            case "video.status": {
                const json = typeof m.json === "string" ? m.json : m.json && typeof m.json === "object" ? JSON.stringify(m.json) : null;
                if (json !== null && id !== null)
                    streams.get(id)?.video?.({ type: "status", json });
                break;
            }
            case "cursor.shape": {
                const cursor = {};
                if (m.shapeId !== undefined)
                    cursor.shapeId = m.shapeId;
                if (m.shape !== undefined)
                    cursor.shape = m.shape;
                if (id !== null)
                    streams.get(id)?.video?.({ type: "cursor", json: JSON.stringify(cursor) });
                break;
            }
            case "audio.opened": {
                const format = {};
                for (const [field, header] of Object.entries(AUDIO_FIELDS))
                    if (m[field] !== undefined && m[field] !== null)
                        format[header] = String(m[field]);
                if (id !== null)
                    streams.get(id)?.audio?.({ type: "opened", format });
                break;
            }
            case "audio.error":
                drop(id, false)?.audio?.({ type: "error", status: num(m.status) ?? 500, message: str(m.message) });
                break;
            case "audio.closed":
                drop(id, false)?.audio?.({ type: "closed", reason: str(m.reason) });
                break;
            case "control":
                if (typeof m.rid === "string")
                    waiters.get(m.rid)?.(m);
                break;
            case "input.rejected":
                inputError?.(inputRejection(m));
                break;
        }
    });
    const offMedia = media.onEvent((e) => {
        switch (e.type) {
            case "frame":
                streams.get(e.stream)?.video?.({
                    type: "frame",
                    frame: {
                        number: e.frame,
                        codec: e.codec,
                        kind: e.kind,
                        width: e.width,
                        height: e.height,
                        captureMs: e.captureUs > 0 ? e.captureUs / 1000 : null,
                        au: e.au,
                    },
                });
                break;
            case "audio":
                streams.get(e.stream)?.audio?.({ type: "packet", seq: e.seq, timeMs: e.timeUs / 1000, data: e.data });
                break;
            case "cursor":
                streams.get(e.stream)?.video?.({ type: "cursor", json: e.json });
                break;
            case "inputFailed":
                inputError?.(new LinkError("timeout", "input not acknowledged"));
                break;
            case "inputAcked":
                break;
        }
    });
    session.onClosed((info) => {
        ended = info.description;
        offControl();
        offMedia();
        for (const w of [...waiters.values()])
            w(null);
        waiters.clear();
        const all = [...streams.values()];
        streams.clear();
        for (const s of all) {
            s.video?.({ type: "failed", reason: info.description });
            s.audio?.({ type: "failed", reason: info.description });
        }
        resolveClosed(info.description);
    });
    const closeStream = (id, video) => {
        if (!streams.delete(id))
            return;
        watch();
        if (video)
            media.closeVideo(id);
        else
            media.closeAudio(id);
        send({ t: video ? "video.close" : "audio.close", id });
    };
    return {
        session,
        get pathLabel() {
            return `link ${session.path().kind}`;
        },
        get isLocalNetwork() {
            return session.path().kind === "lan";
        },
        get rttMinMs() {
            const ms = session.stats().rttMinMs;
            return ms > 0 ? ms : null;
        },
        get statsLine() {
            return session.stats().line;
        },
        get isClosed() {
            return session.isClosed;
        },
        closed,
        openVideo(query, onEvent) {
            let id = 0;
            if (ended)
                queueMicrotask(() => onEvent({ type: "failed", reason: ended }));
            else {
                id = register({ video: onEvent });
                media.openVideo(id);
                send({ t: "video.open", id, query }, (reason) => drop(id, true)?.video?.({ type: "failed", reason }));
            }
            return {
                decoded: (frame, ok) => {
                    if (id)
                        media.frameDecoded(id, frame, ok);
                },
                requestKeyframe: () => {
                    if (id)
                        media.requestKeyframe(id);
                },
                report: (report) => {
                    if (!id || ended)
                        return;
                    const r = { ...report };
                    // every frame's fate in this side's media layer since the last report (the server's per-frame trace)
                    const rx = media.takeRxTraces();
                    if (rx.length || r.frames !== undefined) {
                        r.rx = rx;
                        const clock = r.clock && typeof r.clock === "object" ? { ...r.clock } : {};
                        clock.mediaUs = media.now();
                        clock.hostNowMs = Math.round(performance.now() * 1000) / 1000;
                        r.clock = clock;
                    }
                    send({ t: "report", id, report: r });
                },
                close: () => {
                    if (id)
                        closeStream(id, true);
                },
            };
        },
        openAudio(query, onEvent) {
            let id = 0;
            if (ended)
                queueMicrotask(() => onEvent({ type: "failed", reason: ended }));
            else {
                id = register({ audio: onEvent });
                media.openAudio(id);
                send({ t: "audio.open", id, query }, (reason) => drop(id, false)?.audio?.({ type: "failed", reason }));
            }
            return {
                close: () => {
                    if (id)
                        closeStream(id, false);
                },
            };
        },
        sendInput(json, move) {
            media.sendInput(json, move);
        },
        setInputErrorHandler(handler) {
            inputError = handler;
        },
        control(take) {
            if (ended)
                return Promise.reject(new LinkError("closed", ended));
            const rid = crypto.randomUUID();
            return new Promise((resolve, reject) => {
                const timer = setTimeout(() => answer(null), CONTROL_TIMEOUT_MS);
                const answer = (m) => {
                    clearTimeout(timer);
                    waiters.delete(rid);
                    if (!m)
                        reject(new LinkError(ended ? "closed" : "timeout", ended ?? "no answer to control"));
                    else
                        resolve({ granted: m.granted === true, holder: device(m.holder) });
                };
                waiters.set(rid, answer);
                send({ t: take ? "control.take" : "control.release", rid }, (reason) => {
                    clearTimeout(timer);
                    waiters.delete(rid);
                    reject(new LinkError("closed", reason));
                });
            });
        },
    };
}
