import { AckSender, ACK_TIMEOUT_MS, ackOutcome } from "./acks.js";
import { parseCursorPart } from "./cursor.js";
import { avcC, codecString, lengthPrefixed, sameBytes, splitAccessUnit } from "./h264.js";
import { hevcCodecString, hvcC, splitHevcAccessUnit } from "./hevc.js";
import { boundaryOf, headersFrom, isLivePicture, isPicture, DEFAULT_BOUNDARY, PartParser, STREAM_ACCEPT } from "./parts.js";
import { LAN_DEFAULT_DEPTH_MS, percentile, Playout, playoutConfig, REMOTE_MAX_DEPTH_MS, touchBudgetMs } from "./playout.js";
import { parseStatusPart } from "./status.js";
import { linkStreamQuery } from "./link.js";
import { PlayoutMeter, roundReport } from "./meter.js";
import { parseNetQuality } from "./net.js";
/** The HEVC the Mac sends (Main, up to level 5.1) as WebCodecs names it, for the support check. */
const HEVC_PROBE = "hvc1.1.6.L153.B0";
let hevcCheck = null;
/** The check's answer once it came (no WebCodecs: no at once). */
let hevcKnown = typeof VideoDecoder === "undefined" ? false : null;
/** HEVC failed in this page (a decoder that said yes and then couldn't): H.264 from then on. */
let hevcFailed = false;
/** Whether this browser decodes the Mac's HEVC in hardware (WebCodecs `isConfigSupported`, asked once). */
export function hevcDecodable() {
    hevcCheck ??= (async () => {
        try {
            if (typeof VideoDecoder === "undefined" || typeof VideoDecoder.isConfigSupported !== "function")
                return false;
            const r = await VideoDecoder.isConfigSupported({ codec: HEVC_PROBE, hardwareAcceleration: "prefer-hardware", optimizeForLatency: true });
            return r.supported === true;
        }
        catch {
            return false;
        }
    })().then((yes) => (hevcKnown = yes));
    return hevcCheck;
}
// asked when the module loads: the first stream rarely has to wait for it
if (hevcKnown === null)
    void hevcDecodable();
/** The default codecs if they are known now (null: the check is still out). */
function codecsNow() {
    if (hevcFailed || hevcKnown === false)
        return ["h264"];
    return hevcKnown ? ["hevc", "h264"] : null;
}
/** The codecs a stream asks for by default: `hevc,h264` where HEVC decodes here (and hasn't failed in this page), else `h264`. */
export async function preferredCodecs() {
    return codecsNow() ?? (!hevcFailed && (await hevcDecodable()) ? ["hevc", "h264"] : ["h264"]);
}
/** An ack answer's round trip gives the touch budget for at most this long (ms). */
export const FRESH_RTT_MS = 10_000;
/** The decoder has this many chunks waiting while pictures wait in the playout: it may be short of output buffers
 *  (some hold only a few frames), so the playout lets go of all but the newest. */
export const DECODER_PRESSURE = 3;
/** The link's round trip goes into the touch budget this often (ms). */
export const LINK_RTT_EVERY_MS = 1000;
/** More pictures than this waiting in the decoder, the oldest for longer than DECODER_BEHIND_MS (ms): it can't keep up,
 *  and the stream starts over from a key picture. */
export const DECODER_QUEUE_MAX = 8;
export const DECODER_BEHIND_MS = 500;
/** The server sends at least a keepalive picture every 5 s: three of them missing is a dead stream. */
export const STALL_MS = 15_000;
/** Decode start times of pictures that never came out (a reset, a close) are forgotten after this long. */
export const ENQUEUED_MAX_AGE_MS = 2000;
/** Drops the entries of `map` (value = when, ms) older than `maxAge` at `now`. */
export function pruneOlder(map, now, maxAge) {
    for (const [k, at] of map)
        if (now - at > maxAge)
            map.delete(k);
}
/** The browser can decode the stream (WebCodecs' VideoDecoder). */
export const hasVideoDecoder = () => typeof VideoDecoder !== "undefined" && typeof EncodedVideoChunk !== "undefined";
/** A stream id: 8–64 of [A-Za-z0-9_-]. */
export function streamId() {
    const bytes = new Uint8Array(12);
    crypto.getRandomValues(bytes);
    return `w${Array.from(bytes, (b) => b.toString(36).padStart(2, "0")).join("")}`.slice(0, 24);
}
export class VideoStream {
    opts;
    cb;
    id = streamId();
    ctrl = new AbortController();
    acks;
    decoder = null;
    config = null;
    needKey = true;
    keyAskedAt = -Infinity;
    failures = [];
    /** A picture to draw on the next animation frame (on arrival). */
    latest = null;
    raf = 0;
    ts = 0;
    enqueued = new Map();
    meta = new Map();
    playout;
    smooth;
    onLan;
    /** The animation frames' recent periods (their median is the playout's lead) and the last one's time. */
    periods = [];
    lastRaf = null;
    /** The latest ack answer's minimum round trip, and when it came. */
    rtt = null;
    unsubscribe = null;
    delivered = false;
    ended = false;
    openedAt = performance.now();
    reportTimer = null;
    watchdog = null;
    lastData = performance.now();
    /** Why the stream was aborted from inside: no data (a stall), or an ack's status that ends it. */
    abortedFor = null;
    // the report's window
    bytes = 0;
    ackFailures = [];
    lastReportAt = performance.now();
    meter = new PlayoutMeter();
    drawn = new Map();
    route;
    linkVideo = null;
    linkRttAt = -Infinity;
    codecName = "";
    /** What `streamBody` asks for (set by `run`). */
    codecs = ["h264"];
    /** A picture came out of the decoder in this stream. */
    decodedAny = false;
    quality = null;
    // the stats line's window (`stats()`)
    statsSince = performance.now();
    statsPictures = 0;
    statsBytes = 0;
    statsDecode = [];
    constructor(opts, cb) {
        this.opts = opts;
        this.cb = cb;
        this.acks = new AckSender(this.id, (ack) => this.sendAck(ack));
        this.smooth = (opts.playout ?? "smooth") === "smooth";
        this.route = opts.route ?? (opts.link ? (opts.link.isLocalNetwork ? "lan" : "direct") : "tunnel");
        this.onLan = this.route === "lan";
        if (opts.net) {
            opts.net.setRoute(this.route);
            opts.net.streamStarted(performance.now());
        }
        this.meter.reset(performance.now());
        const config = playoutConfig({
            capMs: opts.maxDepthMs ?? (this.onLan ? undefined : REMOTE_MAX_DEPTH_MS),
            ...(this.onLan ? { defaultDepthMs: LAN_DEFAULT_DEPTH_MS } : {}),
        });
        this.playout = new Playout(config, (frame) => frame.close());
        this.playout.evenPace = true;
        this.playout.touchBudget = touchBudgetMs(null, this.onLan);
        const i = opts.interactivity;
        if (i) {
            // a stream opened while a finger is down starts interactive
            this.playout.interactive = i.on;
            this.unsubscribe = i.subscribe((on) => this.setInteractive(on));
        }
    }
    /** Responsive (on) or smooth (off) playout; the page's `interactivity` calls it, or the page itself. */
    setInteractive(on) {
        if (this.ended || this.playout.interactive === on)
            return;
        this.playout.interactive = on;
        // what waits catches up on the next animation frame
        if (this.playout.queued > 0)
            this.schedule();
    }
    /** The playout now (a stats line: `playoutLine`). */
    playoutState() {
        const p = this.playout;
        const responsive = !this.smooth || p.interactive;
        return {
            mode: responsive ? "responsive" : "smooth",
            holdMs: this.smooth ? p.hold : 0,
            depthMs: p.depth,
            touchMs: this.smooth ? p.touchBuffer : null,
            jitterMs: p.jitter,
            capMs: p.config.maxDepthMs,
            queued: p.queued,
            refreshHz: this.periods.length ? 1000 / p.lead : null,
            paceMs: this.smooth ? p.paceInterval : null,
        };
    }
    /** The playout responds at once (the user interacts). */
    get interactive() {
        return this.playout.interactive;
    }
    /** The A/V sync's extra wait for smooth pictures (ms; `AVSyncDriver` sets it). */
    get syncFloor() {
        return this.playout.syncFloor;
    }
    set syncFloor(ms) {
        this.playout.syncFloor = ms;
    }
    /** For the A/V sync: the smooth video delay without the floor (base + depth + 2 refreshes) and the one in use (base +
     *  hold + a refresh), ms on this clock − the computer's; null without smooth playout or before it measured. */
    syncDelays() {
        const p = this.playout;
        if (!this.smooth || p.base === null)
            return null;
        return { smooth: p.base + p.depth + 2 * p.lead, shown: p.base + p.hold + p.lead };
    }
    /** The stats line's numbers since the previous call (`statsLines`): the window's pictures, bytes and decodes, the
     *  playout of the last few seconds, the network grade (an ack's; none on a link) and the round trips known. */
    stats(now = performance.now()) {
        const secs = Math.max((now - this.statsSince) / 1000, 0.001);
        const d = this.statsDecode;
        const report = this.playoutReport(now);
        const net = this.opts.net?.report(now) ?? null;
        const snap = {
            codec: this.codecName || "-",
            fps: this.statsPictures / secs,
            kilobytesPerSecond: this.statsBytes / 1024 / secs,
            decodeMs: d.length ? d.reduce((a, b) => a + b, 0) / d.length : null,
            playout: report,
            interactive: this.smooth && this.playout.interactive,
            net: this.quality,
            inputRttP50Ms: net?.inputRttMs?.p50 ?? null,
            rttMinMs: this.freshRtt(),
        };
        this.statsSince = now;
        this.statsPictures = 0;
        this.statsBytes = 0;
        this.statsDecode = [];
        return snap;
    }
    /** Opens the stream and reads it until it ends or `close()`. */
    async run() {
        this.codecs = this.opts.codecs?.length ? this.opts.codecs : (codecsNow() ?? (await preferredCodecs()));
        if (this.opts.link)
            return this.runLink(this.opts.link);
        let status = null;
        let error = null;
        let failed = false;
        // a half-open connection never ends by itself: no byte for stallMs (from the request on) ends it as failed
        const stallMs = this.opts.stallMs ?? STALL_MS;
        this.lastData = performance.now();
        this.watchdog = setInterval(() => {
            if (performance.now() - this.lastData > stallMs)
                this.abortFor(`no data for ${Math.round(stallMs / 1000)} s`, null);
        }, Math.min(1000, Math.max(10, stallMs / 4)));
        try {
            const body = this.streamBody();
            const transport = this.opts.transport;
            if (!transport)
                throw new Error("no transport");
            const res = await transport.fetch("/stream", {
                method: "POST",
                cache: "no-store",
                headers: { "content-type": "application/json", accept: STREAM_ACCEPT },
                body: JSON.stringify(body),
                signal: this.ctrl.signal,
            });
            if (!res.ok || !res.body) {
                status = res.status;
                failed = true;
                try {
                    error = (await res.json()).error ?? `HTTP ${res.status}`;
                }
                catch {
                    error = `HTTP ${res.status}`;
                }
                return;
            }
            const codec = (res.headers.get("x-stream-codec") ?? "h264").toLowerCase();
            if (!this.codecs.includes(codec)) {
                failed = true;
                error = `unexpected codec ${codec}`;
                return;
            }
            this.codecName = codec;
            const parser = new PartParser(boundaryOf(res.headers.get("content-type")) ?? DEFAULT_BOUNDARY);
            this.reportTimer = setInterval(() => this.report(), 2000);
            const reader = res.body.getReader();
            for (;;) {
                const { done, value } = await reader.read();
                if (done)
                    break;
                this.lastData = performance.now();
                this.received(value.length, this.lastData);
                for (const part of parser.feed(value))
                    this.part(part);
            }
        }
        catch (e) {
            if (this.abortedFor) {
                failed = true;
                error = this.abortedFor.error;
                status = this.abortedFor.status;
            }
            else if (!this.ctrl.signal.aborted) {
                failed = true;
                error = e instanceof Error ? e.message : String(e);
            }
        }
        finally {
            this.finish({ delivered: this.delivered, failed, lifetimeMs: performance.now() - this.openedAt, status, error });
        }
    }
    /** The stream's parameters (`POST /stream`'s body; a link's `video.open` query without `ack`). */
    streamBody() {
        return {
            ...(this.opts.display !== undefined ? { display: this.opts.display } : {}),
            maxWidth: 3840,
            fps: 60,
            codecs: this.codecs.join(","),
            stream: this.id,
            ack: 1,
            cursor: "client",
            status: 1,
            ...this.opts.extra,
        };
    }
    /** The stream on a link, until it ends or `close()`. */
    runLink(link) {
        const stallMs = this.opts.stallMs ?? STALL_MS;
        this.lastData = performance.now();
        return new Promise((resolve) => {
            let status = null;
            let error = null;
            let failed = false;
            const end = () => {
                this.linkVideo?.close();
                this.linkVideo = null;
                this.finish({ delivered: this.delivered, failed, lifetimeMs: performance.now() - this.openedAt, status, error });
                resolve();
            };
            this.ctrl.signal.addEventListener("abort", () => {
                if (this.abortedFor) {
                    failed = true;
                    error = this.abortedFor.error;
                    status = this.abortedFor.status;
                }
                end();
            });
            this.watchdog = setInterval(() => {
                if (performance.now() - this.lastData > stallMs)
                    this.abortFor(`no data for ${Math.round(stallMs / 1000)} s`, null);
            }, Math.min(1000, Math.max(10, stallMs / 4)));
            this.reportTimer = setInterval(() => this.report(), 2000);
            const onEvent = (e) => {
                if (this.ended)
                    return;
                switch (e.type) {
                    case "opened": {
                        const codec = (e.codec ?? Object.entries(e.headers).find(([k]) => k.toLowerCase() === "x-stream-codec")?.[1] ?? "h264").toLowerCase();
                        this.cb.onOpened?.(e.headers);
                        if (!this.codecs.includes(codec)) {
                            failed = true;
                            error = `unexpected codec ${codec}`;
                            this.ctrl.abort();
                        }
                        else {
                            this.codecName = codec;
                        }
                        return;
                    }
                    case "frame":
                        return this.linkFrame(e.frame);
                    case "status": {
                        this.lastData = performance.now();
                        const s = parseStatusPart(e.json);
                        if (s)
                            this.cb.onStatus(s);
                        return;
                    }
                    case "cursor": {
                        const c = parseCursorPart(e.json);
                        if (c)
                            this.cb.onCursor(c);
                        return;
                    }
                    case "error":
                        failed = true;
                        status = e.status;
                        error = e.message ?? `HTTP ${e.status}`;
                        this.ctrl.abort();
                        return;
                    case "closed":
                        this.ctrl.abort();
                        return;
                    case "failed":
                        failed = true;
                        error = e.reason;
                        this.ctrl.abort();
                        return;
                }
            };
            const video = link.openVideo(linkStreamQuery(this.streamBody()), onEvent);
            if (this.ended)
                video.close();
            else
                this.linkVideo = video;
        });
    }
    /** A link picture: straight to the decoder; now and then the link's round trip into the touch budget. */
    linkFrame(f) {
        const now = performance.now();
        this.lastData = now;
        this.received(f.au.length, now);
        const codec = f.codec.toLowerCase();
        if (codec !== this.codecName && !this.codecs.includes(codec)) {
            this.abortFor(`unexpected codec ${f.codec}`, null);
            return;
        }
        const part = {
            kind: codec === "hevc" ? "hevc" : "h264",
            body: f.au,
            headers: { kind: f.kind, ...(f.captureMs !== null ? { time: f.captureMs } : {}), ...(f.width > 0 ? { width: f.width, height: f.height } : {}) },
        };
        if (isLivePicture(part.headers))
            this.meter.arrived(now);
        if (!this.decode(part, now, f.number))
            this.linkVideo?.decoded(f.number, false);
        if (now - this.linkRttAt >= LINK_RTT_EVERY_MS) {
            this.linkRttAt = now;
            const rtt = this.opts.link?.rttMinMs;
            if (typeof rtt === "number" && Number.isFinite(rtt)) {
                this.rtt = { min: rtt, at: now };
                this.updateTouchBudget();
            }
        }
    }
    received(bytes, now) {
        this.bytes += bytes;
        this.statsBytes += bytes;
        this.opts.net?.received(bytes, now);
    }
    /** Stops the stream (the page left, another display). No onEnd. */
    close() {
        this.ended = true;
        this.ctrl.abort();
        this.linkVideo?.close();
        this.linkVideo = null;
        this.teardown();
    }
    /** Ends the stream from inside (a stall, an ack the server refused for good): run() reports it as failed. */
    abortFor(error, status) {
        if (this.ended || this.abortedFor)
            return;
        this.abortedFor = { error, status };
        this.ctrl.abort();
    }
    finish(info) {
        if (this.ended)
            return;
        this.ended = true;
        this.teardown();
        this.cb.onEnd(info);
    }
    teardown() {
        this.unsubscribe?.();
        this.unsubscribe = null;
        this.playout.flush();
        this.meta.clear();
        this.drawn.clear();
        this.acks.stop();
        if (this.reportTimer)
            clearInterval(this.reportTimer);
        this.reportTimer = null;
        if (this.watchdog)
            clearInterval(this.watchdog);
        this.watchdog = null;
        if (this.raf)
            cancelAnimationFrame(this.raf);
        this.raf = 0;
        this.enqueued.clear();
        this.latest?.close();
        this.latest = null;
        if (this.decoder && this.decoder.state !== "closed") {
            try {
                this.decoder.close();
            }
            catch {
                /* closed already */
            }
        }
        this.decoder = null;
    }
    part(p) {
        if (this.ended)
            return;
        if (isPicture(p.kind)) {
            const now = performance.now();
            if (isLivePicture(p.headers))
                this.meter.arrived(now);
            // acked as soon as it is whole, before decoding
            if (p.headers.seq !== undefined)
                this.acks.received(p.headers.seq);
            this.decode(p, now);
            return;
        }
        if (p.kind === "cursor") {
            const c = parseCursorPart(p.body);
            if (c)
                this.cb.onCursor(c);
            return;
        }
        if (p.kind === "status") {
            const s = parseStatusPart(p.body);
            if (s)
                this.cb.onStatus(s);
        }
    }
    requestKey() {
        const now = performance.now();
        if (now - this.keyAskedAt < 1000)
            return;
        this.keyAskedAt = now;
        if (this.opts.link)
            this.linkVideo?.requestKeyframe();
        else
            this.acks.requestKeyframe();
    }
    /** Into the decoder; false when it couldn't take it (no decoder yet, waiting for a key picture, a reset). */
    decode(p, arrival, linkFrame) {
        const hevc = p.kind === "hevc";
        const au = hevc ? splitHevcAccessUnit(p.body) : splitAccessUnit(p.body);
        const isKey = p.headers.kind === "key" || au.idr;
        if (isKey && au.sps.length && au.pps.length) {
            const codec = hevc ? hevcCodecString(au.sps[0]) : codecString(au.sps[0]);
            const description = hevc ? hvcC(au.vps, au.sps, au.pps) : avcC(au.sps, au.pps);
            if (codec && description && (!this.config || this.config.codec !== codec || !sameBytes(this.config.description, description) || !this.decoder)) {
                this.configure({ codec, description });
            }
        }
        if (au.slices.length === 0)
            return false;
        if (!this.decoder || this.decoder.state !== "configured") {
            this.needKey = true;
            this.requestKey();
            return false;
        }
        if (this.needKey && !isKey) {
            this.requestKey();
            return false;
        }
        // a decoder falling behind (a slow machine): start over from a key picture rather than piling up. A burst (the
        // decoder warming up, pictures a stall held back) isn't that: only a queue whose oldest picture waited too long
        if (this.decoder.decodeQueueSize > DECODER_QUEUE_MAX && this.oldestWaiting(performance.now()) > DECODER_BEHIND_MS) {
            this.decoder.reset();
            this.configure(this.config);
            this.needKey = true;
            this.requestKey();
            return false;
        }
        this.needKey = false;
        const timestamp = (this.ts += 16_667);
        const now = performance.now();
        // pictures a reset or an error swallowed never come out: their start times go after a while
        pruneOlder(this.enqueued, now, ENQUEUED_MAX_AGE_MS);
        for (const [k, m] of this.meta)
            if (now - m.arrival > ENQUEUED_MAX_AGE_MS)
                this.meta.delete(k);
        this.enqueued.set(timestamp, now);
        const time = p.headers.time;
        this.meta.set(timestamp, { arrival, macTime: typeof time === "number" && Number.isFinite(time) ? time : null, sample: isLivePicture(p.headers), ...(linkFrame !== undefined ? { linkFrame } : {}) });
        try {
            this.decoder.decode(new EncodedVideoChunk({ type: isKey ? "key" : "delta", timestamp, data: lengthPrefixed(au.slices) }));
        }
        catch {
            this.decodeFailed();
        }
        return true;
    }
    /** How long the oldest picture still in the decoder has waited (ms; 0: none). */
    oldestWaiting(now) {
        let oldest = now;
        for (const at of this.enqueued.values())
            if (at < oldest)
                oldest = at;
        return now - oldest;
    }
    configure(config) {
        if (!this.decoder || this.decoder.state === "closed") {
            this.decoder = new VideoDecoder({
                output: (frame) => this.output(frame),
                error: () => this.decodeFailed(),
            });
        }
        try {
            this.decoder.configure({ codec: config.codec, description: config.description, hardwareAcceleration: "prefer-hardware", optimizeForLatency: true });
            this.config = config;
            this.needKey = true;
        }
        catch {
            this.decodeFailed();
        }
    }
    decodeFailed() {
        const now = performance.now();
        // HEVC that said yes and can't (no picture yet): H.264 from now on in this page; the page opens the stream again
        if (this.codecName === "hevc" && !this.decodedAny && !this.opts.codecs) {
            hevcFailed = true;
            this.abortFor("HEVC didn't decode here: H.264 next", null);
            return;
        }
        // on a link, the pictures inside the decoder are lost: the computer hears it (and references something else)
        if (this.linkVideo) {
            for (const [k, m] of this.meta) {
                if (m.linkFrame !== undefined)
                    this.linkVideo.decoded(m.linkFrame, false);
                this.meta.delete(k);
            }
        }
        this.failures = this.failures.filter((t) => now - t < 10_000);
        this.failures.push(now);
        if (this.decoder && this.decoder.state !== "closed") {
            try {
                this.decoder.close();
            }
            catch {
                /* closed already */
            }
        }
        this.decoder = null;
        this.config = null;
        this.needKey = true;
        if (this.failures.length >= 3 && !this.delivered) {
            // video doesn't work here
            this.ctrl.abort();
            this.finish({ delivered: false, failed: true, lifetimeMs: now - this.openedAt, status: null, error: "this browser can't decode the video" });
            return;
        }
        this.keyAskedAt = -Infinity;
        this.requestKey();
    }
    output(frame) {
        this.decodedAny = true;
        const at = this.enqueued.get(frame.timestamp);
        const now = performance.now();
        let decodeMs = null;
        if (at !== undefined) {
            decodeMs = now - at;
            this.statsDecode.push(decodeMs);
            this.enqueued.delete(frame.timestamp);
        }
        const meta = this.meta.get(frame.timestamp);
        this.meta.delete(frame.timestamp);
        if (meta?.linkFrame !== undefined)
            this.linkVideo?.decoded(meta.linkFrame, true);
        if (this.ended) {
            frame.close();
            return;
        }
        for (const [k, d] of this.drawn)
            if (now - d.at > ENQUEUED_MAX_AGE_MS)
                this.drawn.delete(k);
        this.drawn.set(frame.timestamp, { decodeMs, macTime: meta?.sample ? meta.macTime : null, at: now });
        const p = this.playout;
        const before = p.dropped;
        const placement = this.smooth && meta ? p.push(frame, meta.macTime, meta.sample, meta.arrival) : "now";
        if (placement === "now") {
            if (this.latest) {
                this.drawn.delete(this.latest.timestamp);
                this.latest.close();
                this.countDropped(1, now);
            }
            this.latest = frame;
        }
        else if (p.queued > 1 && (this.decoder?.decodeQueueSize ?? 0) >= DECODER_PRESSURE) {
            p.trim(1);
        }
        this.countDropped(p.dropped - before, now);
        this.schedule();
    }
    schedule() {
        if (!this.raf && !this.ended)
            this.raf = requestAnimationFrame((t) => this.draw(t));
    }
    /** On an animation frame at `t`: the picture on arrival, else the playout's newest due one for the refresh after. */
    draw(t = performance.now()) {
        this.raf = 0;
        const p = this.playout;
        if (this.lastRaf !== null) {
            const period = t - this.lastRaf;
            if (period > 4 && period < 50) {
                this.periods.push(period);
                if (this.periods.length > 31)
                    this.periods.shift();
                p.lead = percentile(this.periods, 0.5) ?? period;
            }
        }
        this.lastRaf = t;
        let frame = this.latest;
        this.latest = null;
        if (!frame) {
            const before = p.dropped;
            frame = p.next(t + p.lead);
            this.countDropped(p.dropped - before, t);
        }
        // keep the frames coming while pictures wait (consecutive frames measure the refresh)
        if (p.queued > 0)
            this.schedule();
        else
            this.lastRaf = null;
        if (!frame)
            return;
        const c = this.opts.canvas;
        const w = frame.displayWidth, h = frame.displayHeight;
        if (c.width !== w || c.height !== h) {
            c.width = w;
            c.height = h;
        }
        c.getContext("2d")?.drawImage(frame, 0, 0, w, h);
        const d = this.drawn.get(frame.timestamp);
        this.drawn.delete(frame.timestamp);
        this.meter.shown(t, d?.decodeMs ?? null, d?.macTime ?? null);
        frame.close();
        this.statsPictures++;
        this.delivered = true;
        this.cb.onPicture(w, h);
    }
    countDropped(n, t) {
        if (n <= 0)
            return;
        this.meter.dropped(n, t);
    }
    async sendAck(ack) {
        try {
            const transport = this.opts.transport;
            if (!transport)
                return "gone";
            const res = await transport.fetch("/stream/ack", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify(ack),
                signal: AbortSignal.timeout(ACK_TIMEOUT_MS),
            });
            if (!res.ok) {
                const { outcome, ends } = ackOutcome(res.status);
                // 401 (the sign-in expired), 403…: retrying won't help, and the stream can't go on without acks
                if (ends)
                    this.abortFor(`ack refused: HTTP ${res.status}`, res.status);
                return outcome === "failed" ? this.ackFailed() : outcome;
            }
            const body = (await res.json().catch(() => null));
            const q = parseNetQuality(body?.net);
            if (q) {
                this.quality = q;
                if (q.rttMs)
                    this.rtt = { min: q.rttMs.min, at: performance.now() };
                this.cb.onNet?.(q);
            }
            this.updateTouchBudget();
            return "ok";
        }
        catch {
            return this.ackFailed();
        }
    }
    /** The latest round trip if it is at most FRESH_RTT_MS old (ms; null: none). */
    freshRtt() {
        return this.rtt && performance.now() - this.rtt.at <= FRESH_RTT_MS ? this.rtt.min : null;
    }
    /** The touch budget follows the latest fresh round trip (and falls back once it is too old). */
    updateTouchBudget() {
        this.playout.touchBudget = touchBudgetMs(this.freshRtt(), this.onLan);
    }
    ackFailed() {
        const now = performance.now();
        this.ackFailures.push(now);
        this.opts.net?.failed(now);
        return "failed";
    }
    /** The meter's report with the playout's own fields (ms, unrounded); null when nothing was drawn lately. */
    playoutReport(now) {
        const p = this.playout;
        const latency = !this.smooth || p.interactive;
        const r = this.meter.report(latency ? "latency" : "smooth", now);
        if (!r)
            return null;
        if (this.smooth) {
            r.bufferMs = p.hold;
            if (p.jitter !== null)
                r.jitterP95Ms = p.jitter;
            if (!latency)
                r.bufferCapMs = p.config.maxDepthMs;
            const pace = p.paceInterval;
            if (pace !== null)
                r.paceMs = pace;
        }
        if (this.periods.length)
            r.refreshHz = 1000 / p.lead;
        if (latency)
            r.touchBufferMs = (this.smooth ? p.touchBuffer : null) ?? 0;
        return r;
    }
    /** The playout report of the last few seconds: on the next ack, or on the link. */
    report() {
        const now = performance.now();
        const secs = Math.max(0.5, (now - this.lastReportAt) / 1000);
        this.ackFailures = this.ackFailures.filter((t) => now - t < 10_000);
        const r = this.playoutReport(now) ?? { mode: !this.smooth || this.playout.interactive ? "latency" : "smooth", fps: 0 };
        r.net = this.opts.net?.report(now) ?? { route: this.route, rxKbps: Math.round((this.bytes * 8) / 1000 / secs), failures: this.ackFailures.length };
        const audio = this.opts.audioReport?.() ?? null;
        if (audio)
            r.audio = audio;
        const out = roundReport(r);
        if (this.opts.link)
            this.linkVideo?.report(out);
        else
            this.acks.attach(out);
        this.bytes = 0;
        this.lastReportAt = now;
    }
}
/** One frame for a preview (a list row, the page before the stream): `GET /frame` as an object URL (null on failure). */
export async function fetchFrame(transport, display, maxWidth, signal) {
    const q = new URLSearchParams({ maxWidth: String(maxWidth), quality: "70" });
    if (display !== undefined)
        q.set("display", String(display));
    try {
        const res = await transport.fetch(`/frame?${q}`, { method: "GET", cache: "no-store", ...(signal ? { signal } : {}) });
        if (!res.ok)
            return null;
        const h = headersFrom((n) => res.headers.get(n));
        return { url: URL.createObjectURL(await res.blob()), width: h.width ?? 0, height: h.height ?? 0 };
    }
    catch {
        return null;
    }
}
