// Request parameters checked before they reach the server (a proxy validates what its own clients send), and the
// server's answers read leniently. Every refusal is a 400 LocalError; an answer that isn't one at all is a 502.
import { LocalError } from "./errors.js";
import { INPUT_TYPES, MODIFIERS, POINTER_BUTTONS, SCROLL_PHASES, } from "./types.js";
const clamp01 = (n) => Math.min(1, Math.max(0, n));
const isNum = (v) => typeof v === "number" && Number.isFinite(v);
/** A POST /input body, validated (400 LocalError otherwise). Coordinates are clamped to the display. */
export function parseInput(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        throw new LocalError("body must be a JSON object", 400);
    const b = raw;
    const type = b.type;
    if (typeof type !== "string" || !INPUT_TYPES.includes(type)) {
        throw new LocalError(`type must be one of ${INPUT_TYPES.join(", ")}`, 400);
    }
    const out = { type: type };
    if (b.display !== undefined && b.display !== null) {
        if (!isNum(b.display) || !Number.isInteger(b.display) || b.display < 0)
            throw new LocalError("display must be a display id", 400);
        out.display = b.display;
    }
    for (const k of ["x", "y", "dx", "dy"]) {
        if (b[k] === undefined || b[k] === null)
            continue;
        if (!isNum(b[k]))
            throw new LocalError(`${k} must be a number`, 400);
        out[k] = k === "x" || k === "y" ? clamp01(b[k]) : b[k];
    }
    const pointer = out.type === "click" || out.type === "doubleClick" || out.type === "rightClick" || out.type === "move" || out.type === "drag" ||
        out.type === "down" || out.type === "up";
    if (pointer && (out.x === undefined || out.y === undefined))
        throw new LocalError(`${out.type} needs x and y (0…1)`, 400);
    // a live drag: `move` with the left button held (between `down` and `up`); no other button, and only on `move`
    if (b.button !== undefined && b.button !== null) {
        if (typeof b.button !== "string" || !POINTER_BUTTONS.includes(b.button)) {
            throw new LocalError(`button must be ${POINTER_BUTTONS.map((x) => `"${x}"`).join(" or ")}`, 400);
        }
        if (out.type === "move")
            out.button = b.button;
    }
    // a pipelined move's counter (the server answers an overtaken one `stale`): a non-negative integer, only on a move
    if (b.seq !== undefined && b.seq !== null) {
        if (!isNum(b.seq) || !Number.isSafeInteger(b.seq) || b.seq < 0)
            throw new LocalError("seq must be a non-negative integer", 400);
        if (out.type === "move")
            out.seq = b.seq;
    }
    if (out.type === "drag" && out.dx === undefined && out.dy === undefined)
        throw new LocalError("drag needs dx and/or dy", 400);
    if (out.type === "scroll" && out.dx === undefined && out.dy === undefined)
        throw new LocalError("scroll needs dx and/or dy", 400);
    // a two-finger gesture's phase and, on `ended`, the velocity at lift (the server's momentum); only on a scroll
    if (b.phase !== undefined && b.phase !== null) {
        if (typeof b.phase !== "string" || !SCROLL_PHASES.includes(b.phase)) {
            throw new LocalError(`phase must be one of ${SCROLL_PHASES.join(", ")}`, 400);
        }
        if (out.type === "scroll")
            out.phase = b.phase;
    }
    for (const k of ["vx", "vy"]) {
        if (b[k] === undefined || b[k] === null)
            continue;
        if (!isNum(b[k]))
            throw new LocalError(`${k} must be a number`, 400);
        if (out.type === "scroll")
            out[k] = b[k];
    }
    if (out.type === "type") {
        if (typeof b.text !== "string" || !b.text)
            throw new LocalError("type needs a non-empty text", 400);
        if (b.text.length > 4000)
            throw new LocalError("text is too long (max 4000 characters)", 400);
        out.text = b.text;
    }
    if (out.type === "key") {
        if (typeof b.key !== "string" || !b.key.trim() || b.key.length > 32)
            throw new LocalError("key needs a key name", 400);
        out.key = b.key.trim();
    }
    if (b.modifiers !== undefined && b.modifiers !== null) {
        if (!Array.isArray(b.modifiers) || !b.modifiers.every((m) => MODIFIERS.includes(m))) {
            throw new LocalError(`modifiers must be a list of ${MODIFIERS.join(", ")}`, 400);
        }
        // held with the button: they count on `down`, not on what moves or lifts it
        const heldMove = out.type === "up" || (out.type === "move" && out.button !== undefined);
        if (b.modifiers.length && !heldMove)
            out.modifiers = [...new Set(b.modifiers)];
    }
    return out;
}
/** FrameParams from a parameter lookup (a URL query's `get`, a JSON body's fields): clamped; not a number → 400. */
export function parseFrameParams(get) {
    const num = (name) => {
        const v = get(name);
        if (v === undefined || v === null || v === "")
            return undefined;
        const n = typeof v === "number" ? v : Number(v);
        if (!Number.isFinite(n))
            throw new LocalError(`${name} must be a number`, 400);
        return n;
    };
    const p = {};
    const display = num("display");
    if (display !== undefined)
        p.display = Math.trunc(display);
    const maxWidth = num("maxWidth");
    if (maxWidth !== undefined)
        p.maxWidth = Math.min(3840, Math.max(160, Math.round(maxWidth)));
    const quality = num("quality");
    if (quality !== undefined)
        p.quality = Math.min(95, Math.max(10, Math.round(quality)));
    const fps = num("fps");
    // up to 60 fps: video streams only encode a frame when it changes, so a high cap is cheap
    if (fps !== undefined)
        p.fps = Math.min(60, Math.max(1, fps));
    return p;
}
/** An on/off flag parameter: 1 / "1" / true / "true" → true; absent / "" / 0 / "0" / false / "false" → false; else 400. */
function flagParam(v, name) {
    if (v === 1 || v === "1" || v === true || v === "true")
        return true;
    if (v === undefined || v === null || v === "" || v === 0 || v === "0" || v === false || v === "false")
        return false;
    throw new LocalError(`${name} must be 1`, 400);
}
export const STREAM_CODEC_TOKENS = ["hevc", "h264"];
/** A client-chosen stream id. */
export const STREAM_ID = /^[A-Za-z0-9_-]{8,64}$/;
export function parseStreamParams(get) {
    const p = parseFrameParams(get);
    const codecs = get("codecs");
    if (codecs !== undefined && codecs !== null && codecs !== "") {
        const raw = Array.isArray(codecs) ? codecs.join(",") : typeof codecs === "string" ? codecs : null;
        if (raw === null)
            throw new LocalError("codecs must be a comma-separated list", 400);
        const known = [...new Set(raw.split(",").map((t) => t.trim().toLowerCase()))].filter((t) => STREAM_CODEC_TOKENS.includes(t));
        if (known.length)
            p.codecs = known.join(",");
    }
    const stream = get("stream");
    if (stream !== undefined && stream !== null && stream !== "") {
        if (typeof stream !== "string" || !STREAM_ID.test(stream))
            throw new LocalError("stream must be 8–64 characters of A-Z a-z 0-9 _ -", 400);
        p.stream = stream;
    }
    if (flagParam(get("ack"), "ack"))
        p.ack = 1;
    const cursor = get("cursor");
    if (cursor === "client")
        p.cursor = "client";
    else if (!(cursor === undefined || cursor === null || cursor === ""))
        throw new LocalError('cursor must be "client"', 400);
    if (flagParam(get("status"), "status"))
        p.status = 1;
    const maxKbps = get("maxKbps");
    if (maxKbps !== undefined && maxKbps !== null && maxKbps !== "") {
        const n = typeof maxKbps === "number" ? maxKbps : typeof maxKbps === "string" && /^\d+$/.test(maxKbps) ? Number(maxKbps) : NaN;
        if (!Number.isInteger(n) || n < 100 || n > 100_000)
            throw new LocalError("maxKbps must be an integer 100…100000", 400);
        p.maxKbps = n;
    }
    return p;
}
/** The largest stream ack body worth reading (bytes); a proxy answers 413 above it. */
export const ACK_BODY_MAX = 16 * 1024;
/**
 * A POST /stream/ack body (400 LocalError otherwise): `stream`, `seq` and `keyframe` checked; `report` passed on as it
 * came when it is a JSON object (else dropped) — the server decodes it leniently.
 */
export function parseStreamAck(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        throw new LocalError("body must be a JSON object", 400);
    const b = raw;
    if (typeof b.stream !== "string" || !STREAM_ID.test(b.stream))
        throw new LocalError("stream must be a stream id", 400);
    if (!isNum(b.seq) || !Number.isSafeInteger(b.seq) || b.seq < 0)
        throw new LocalError("seq must be a non-negative integer", 400);
    const out = { stream: b.stream, seq: b.seq };
    if (b.keyframe !== undefined && b.keyframe !== null) {
        if (typeof b.keyframe !== "boolean")
            throw new LocalError("keyframe must be a boolean", 400);
        if (b.keyframe)
            out.keyframe = true;
    }
    if (b.report && typeof b.report === "object" && !Array.isArray(b.report))
        out.report = b.report;
    return out;
}
/** The /focus answer (anything odd = not editable; a role of at most 64 characters). */
export function parseFocus(raw) {
    const r = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
    const role = typeof r.role === "string" && r.role.length > 0 && r.role.length <= 64 ? r.role : null;
    return { editable: r.editable === true, role };
}
/** `/status.features`: its boolean entries (an open set), null when it has none. */
export function parseFeatures(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return null;
    const out = {};
    for (const [k, v] of Object.entries(raw))
        if (typeof v === "boolean")
            out[k] = v;
    return Object.keys(out).length ? out : null;
}
const MENU_BAR_AREAS = ["appleMenu", "appMenu", "statusItem", "bar"];
const rec = (raw) => (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : null);
const finite = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
/** One AppRef of an answer, or null when it is not one (no pid / name). */
export function parseAppRef(raw) {
    const r = rec(raw);
    const pid = finite(r?.pid);
    if (!r || pid === null || typeof r.name !== "string")
        return null;
    const englishName = typeof r.englishName === "string" && r.englishName && r.englishName !== r.name ? r.englishName : undefined;
    return { pid, bundleId: typeof r.bundleId === "string" && r.bundleId ? r.bundleId : null, name: r.name, ...(englishName ? { englishName } : {}) };
}
/** GET /windows, leniently (odd entries dropped); not an object at all → a 502. */
export function parseWindows(raw) {
    const r = rec(raw);
    if (!r || !Array.isArray(r.apps))
        throw new LocalError("screen helper: bad answer to /windows", 502);
    const apps = r.apps.flatMap((a) => {
        const ref = parseAppRef(a);
        return ref ? [{ ...ref, windows: Math.max(0, Math.trunc(finite(rec(a)?.windows) ?? 0)) }] : [];
    });
    const windows = (Array.isArray(r.windows) ? r.windows : []).flatMap((w) => {
        const o = rec(w);
        const v = ["pid", "display", "x", "y", "w", "h"].map((k) => finite(o?.[k]));
        if (v.some((n) => n === null))
            return [];
        const [pid, display, x, y, ww, h] = v;
        return [{ pid: pid, display: display, x: x, y: y, w: ww, h: h, layer: finite(o?.layer) ?? 0 }];
    });
    return { apps, windows, focused: parseAppRef(r.focused) };
}
/** GET /hit, leniently. */
export function parseHit(raw) {
    const r = rec(raw);
    const menuBar = typeof r?.menuBar === "string" && MENU_BAR_AREAS.includes(r.menuBar) ? r.menuBar : undefined;
    return { app: parseAppRef(r?.app), layer: finite(r?.layer), ...(menuBar ? { menuBar } : {}) };
}
const str = (v, max = 500) => (typeof v === "string" && v.length ? v.slice(0, max) : undefined);
/** GET /app/windows, leniently (odd entries dropped); not an object → a 502. */
export function parseAppWindows(raw) {
    const r = rec(raw);
    if (!r || !Array.isArray(r.windows))
        throw new LocalError("screen helper: bad answer to /app/windows", 502);
    return r.windows.flatMap((w) => {
        const o = rec(w);
        const v = ["id", "display", "x", "y", "w", "h"].map((k) => finite(o?.[k]));
        if (!o || v.some((n) => n === null))
            return [];
        const [id, display, x, y, ww, h] = v;
        return [{ id: id, display: display, x: x, y: y, w: ww, h: h, onScreen: o.onScreen !== false, minimized: o.minimized === true }];
    });
}
/** GET /app/ax, leniently; not an object → a 502. */
export function parseAppAx(raw) {
    const r = rec(raw);
    if (!r || !Array.isArray(r.elements))
        throw new LocalError("screen helper: bad answer to /app/ax", 502);
    const elements = r.elements.flatMap((e) => {
        const o = rec(e);
        const v = ["i", "x", "y", "w", "h"].map((k) => finite(o?.[k]));
        const role = str(o?.role, 64);
        if (!o || !role || v.some((n) => n === null))
            return [];
        const [i, x, y, w, h] = v;
        const subrole = str(o.subrole, 64);
        const title = str(o.title, 200);
        return [{ i: Math.trunc(i), role, ...(subrole ? { subrole } : {}), ...(title ? { title } : {}), x: x, y: y, w: w, h: h, enabled: o.enabled !== false, focused: o.focused === true }];
    });
    const focused = finite(r.focused);
    return { app: parseAppRef(r.app), focused: focused === null ? null : Math.trunc(focused), elements, truncated: r.truncated === true };
}
/** A `x,y,w,h` header (X-Crop, X-Window-Bounds) as a Region, null when it isn't one. */
export function regionHeader(v) {
    const parts = typeof v === "string" ? v.split(",").map(Number) : [];
    return parts.length === 4 && parts.every(Number.isFinite) ? { x: parts[0], y: parts[1], w: parts[2], h: parts[3] } : null;
}
