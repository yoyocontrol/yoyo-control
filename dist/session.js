import { CloseCode, LinkError } from "./errors.js";
import { encodeFrame, FrameReader, messageBytes } from "./framing.js";
import { probeReport } from "./probe.js";
import { rpcRequest } from "./rpc.js";
import { browserIface, classifyPath, linkMediaStats, parseLinkStats, RttWindow, statsLine } from "./stats.js";
/** Largest datagram payload over WebRTC (SCTP over DTLS over UDP, safe on every path). */
export const MAX_DATAGRAM = 1200;
/** `link.stats` goes this often. */
export const STATS_EVERY_MS = 2000;
/** The media layer gets the path's RTT this often. */
export const RTT_EVERY_MS = 100;
/** `getStats()` is read this often (the RTT it reports changes with the ICE consent checks). */
export const PEER_STATS_EVERY_MS = 500;
/** Nothing from the server for this long: the session is dead (the server sends `link.stats` every 2 s). */
export const IDLE_MS = 20_000;
/** While the app expects traffic (`setActivityTimeout`, e.g. a video stream is open: the server sends `link.stats`
 *  every 2 s and the stream's keepalives), this much silence ends the session. */
export const ACTIVE_IDLE_MS = 3000;
/** `dgram`'s send buffer: past it a datagram is dropped rather than queued (new datagrams are what matters). */
export const DGRAM_BUFFER = 256 * 1024;
/** RPC answers start within this long. */
export const RPC_TIMEOUT_MS = 30_000;
/** A lost path (ICE `disconnected` / `failed`: the network changed, Wi-Fi ↔ 5G) is looked for again this long by ICE
 *  restarts before the session ends (the server keeps a silent connection about 20 s). */
export const RECOVER_MS = 15_000;
/** ICE gets this long to come back by itself before the first restart (a short blip). */
export const RESTART_AFTER_MS = 1000;
/** A restart that found no path by then is tried again. */
export const RESTART_EVERY_MS = 4000;
const describe = (c) => {
    const who = c.remote ? "closed by the server" : "closed";
    return c.code === undefined ? `${who}: ${c.reason}` : `${who} (${c.code}${c.reason ? `: ${c.reason}` : ""})`;
};
/** `link.probe`'s ids (per page). */
let nextProbeId = 1;
/**
 * One uu Link session over WebRTC (docs/LINK.md「会话协议」, 「WebRTC」): control messages both ways, RPC requests,
 * datagram channels 6–15 for the app, the media layer on channels 1–5 (`media`), the path and its stats. The same
 * shape as `@yoyocontrol/link`'s Node `Session`, client side. It ends when either side closes it (`bye`), the
 * peer connection closes, or nothing came for `IDLE_MS` (`setActivityTimeout` while traffic is expected:
 * `ACTIVE_IDLE_MS` with a video stream open through `linkScreen`). A lost path (ICE `disconnected` / `failed`: the
 * network changed) is looked for again with ICE restarts for up to `RECOVER_MS` when the server takes them
 * (`recovering`, `onRecovering`); the session ends only when none is found (at once with servers that don't).
 */
export class LinkSession {
    hello;
    welcome;
    /** The media layer (null when the session was dialed without one). */
    media;
    /** How long the dial took to each step. */
    timing;
    pc;
    control;
    dgram;
    reader;
    iface;
    controlListeners = new Set();
    datagramListeners = new Map();
    closedListeners = new Set();
    closeInfo = null;
    closedPromise;
    resolveClosed;
    rtt = new RttWindow();
    latestRtt = null;
    pathInfo = { kind: "none" };
    bytes = { sent: 0, received: 0 };
    counts = { sent: 0, received: 0, drops: 0 };
    peer = null;
    lastReceived;
    activityTimeoutMs = null;
    tick = null;
    ticks = 0;
    readingStats = false;
    /** @internal the first read of the selected candidate pair (`dialRtc` waits for it: the path is known at once). */
    firstStats;
    pathListeners = new Set();
    early;
    restartIce;
    recoveringSince = null;
    recoveringListeners = new Set();
    /** ICE restarts that found a new path. */
    restarts = 0;
    /** The running speed test hears its `link.probe.*` replies here. */
    probeListener = null;
    /** @internal use `dialRtc` */
    constructor(p) {
        this.pc = p.pc;
        this.control = p.control;
        this.dgram = p.dgram;
        this.reader = p.reader;
        this.hello = p.hello;
        this.welcome = p.welcome;
        this.media = p.media;
        this.timing = p.timing;
        this.iface = p.iface;
        this.lastReceived = performance.now();
        this.restartIce = p.restartIce ?? null;
        this.closedPromise = new Promise((r) => (this.resolveClosed = r));
        this.control.addEventListener("message", (ev) => this.onControlData(ev.data));
        this.control.addEventListener("close", () => this.finish({ reason: "the control channel closed", remote: true }));
        this.dgram.addEventListener("message", (ev) => this.receiveDatagram(ev.data));
        // a lost path shows here within seconds (consent checks): ICE restarts look for a new one (`recover`)
        this.pc.addEventListener("connectionstatechange", () => {
            const s = this.pc.connectionState;
            if (s === "closed")
                this.finish({ reason: "the connection closed", remote: true });
            else if (s === "disconnected" || s === "failed")
                this.pathLost(`the connection ${s}`);
        });
        this.pc.addEventListener("iceconnectionstatechange", () => {
            const s = this.pc.iceConnectionState;
            if (globalThis.__linkDebug)
                console.log(`link: ICE ${s} (connection ${this.pc.connectionState})`);
            if (s === "disconnected" || s === "failed")
                this.pathLost(`ICE ${s}`);
        });
        // the device's network changed (where the browser says so): new candidates at once, before the old path dies
        if (typeof window !== "undefined")
            window.addEventListener("online", this.onNetworkChange);
        globalThis.navigator?.connection?.addEventListener?.("change", this.onNetworkChange);
        this.tick = setInterval(() => this.onTick(), RTT_EVERY_MS);
        this.media?.setTransport(null, this.maxDatagramSize);
        // what came with `welcome` goes to the listeners the caller adds right after the dial (before anything newer)
        this.early = p.early;
        if (this.early.length)
            setTimeout(() => this.flushEarly(), 0);
        this.firstStats = this.readPeerStats();
    }
    /**
     * How long silence from the server may last before the session ends: `ms` while the app expects traffic (a video
     * stream open: `ACTIVE_IDLE_MS`), null for `IDLE_MS` again. Anything received (control or datagram) counts.
     */
    setActivityTimeout(ms) {
        this.activityTimeoutMs = ms;
    }
    /** The server's identity as it says (`welcome.server`). */
    get server() {
        return this.welcome.server;
    }
    /** Who the server says this client is (`welcome.principal`). */
    get principal() {
        return this.welcome.principal;
    }
    /** Largest datagram payload (bytes). */
    get maxDatagramSize() {
        const w = this.welcome.maxDatagram;
        return w > 0 ? Math.min(w, MAX_DATAGRAM) : MAX_DATAGRAM;
    }
    get isClosed() {
        return this.closeInfo !== null;
    }
    /** The path was lost and ICE restarts are looking for a new one (the session goes on if one is found). */
    get recovering() {
        return this.recoveringSince !== null;
    }
    /** How many times a lost path was found again (ICE restarts that worked). */
    get recoveries() {
        return this.restarts;
    }
    /** Hears `recovering` change (true: the path is lost, false: found again; the session's end is `closed`). */
    onRecovering(listener) {
        this.recoveringListeners.add(listener);
        return () => this.recoveringListeners.delete(listener);
    }
    // MARK: control
    /** Sends a control message (not `hello` / `welcome` / `denied`). Throws `closed` once the session ended. */
    sendControl(message) {
        if (["hello", "welcome", "denied"].includes(message.t))
            throw new LinkError("protocol", `${message.t} is the handshake's`);
        this.writeControl(message);
    }
    /** Hears every control message from the server but `link.stats` (kept: `peerStats()`) and `bye`; returns the
     *  unsubscribe. */
    onControl(listener) {
        this.controlListeners.add(listener);
        return () => this.controlListeners.delete(listener);
    }
    /** The control messages from now on, until the session ends. */
    async *controlMessages() {
        const queue = [];
        let wake = null;
        const off = this.onControl((m) => {
            queue.push(m);
            wake?.();
        });
        const offClosed = this.onClosed(() => wake?.());
        try {
            for (;;) {
                const m = queue.shift();
                if (m) {
                    yield m;
                    continue;
                }
                if (this.closeInfo)
                    return;
                await new Promise((r) => (wake = r));
                wake = null;
            }
        }
        finally {
            off();
            offClosed();
        }
    }
    // MARK: RPC
    /** One request (docs/LINK.md「RPC 流」); resolves with the answer once its head came. */
    request(request, body) {
        if (this.closeInfo)
            return Promise.reject(new LinkError("closed", this.closeInfo.description));
        return rpcRequest(this.pc, request, body, RPC_TIMEOUT_MS);
    }
    /**
     * `fetch` over RPC: `path` (with its query) and a `RequestInit` (method, headers, a string / bytes / Blob body;
     * `signal` cancels) → a `Response` streaming the answer's body. For code written against HTTP (a `ScreenTransport`).
     */
    async fetch(path, init = {}) {
        const headers = {};
        new Headers(init.headers).forEach((v, k) => (headers[k] = v));
        let body;
        if (init.body !== undefined && init.body !== null)
            body = new Uint8Array(await new Response(init.body).arrayBuffer());
        const res = await this.request({ method: init.method ?? "GET", path, headers }, body);
        init.signal?.addEventListener("abort", () => res.cancel(), { once: true });
        return res.toResponse();
    }
    // MARK: datagrams
    /** One datagram on an app channel (6–15). Dropped (counted) when `dgram`'s buffer is full or past the size. */
    sendDatagram(channel, payload) {
        if (!Number.isInteger(channel) || channel < 6 || channel > 15)
            throw new LinkError("protocol", "app datagram channels are 6–15");
        const d = new Uint8Array(1 + payload.length);
        d[0] = (channel << 4) | 1;
        d.set(payload, 1);
        this.sendDatagramRaw(d);
    }
    /** @internal a datagram with its header byte (the media layer's and `sendDatagram`'s). */
    sendDatagramRaw(d) {
        if (this.closeInfo || this.dgram.readyState !== "open" || d.length > this.maxDatagramSize || this.dgram.bufferedAmount > DGRAM_BUFFER) {
            this.counts.drops++;
            return;
        }
        try {
            this.dgram.send(d);
            this.counts.sent++;
        }
        catch {
            this.counts.drops++;
        }
    }
    /** Hears the datagrams of an app channel (6–15), payload without the header byte; returns the unsubscribe. */
    onDatagram(channel, listener) {
        let set = this.datagramListeners.get(channel);
        if (!set)
            this.datagramListeners.set(channel, (set = new Set()));
        set.add(listener);
        return () => set.delete(listener);
    }
    // MARK: path and stats
    /** The selected candidate pair's path now. */
    path() {
        return { ...this.pathInfo };
    }
    /** Hears path changes (kind or remote address); returns the unsubscribe. */
    onPath(listener) {
        this.pathListeners.add(listener);
        return () => this.pathListeners.delete(listener);
    }
    /** This side's stats now (what goes out as `link.stats` every 2 s) and the `link:` line's body. */
    stats() {
        const [rttMinMs, rttP50Ms, rttP90Ms] = this.rtt.summary();
        const s = {
            path: this.pathInfo.kind,
            iface: this.iface(),
            rttMinMs,
            rttP50Ms,
            rttP90Ms,
            bytesSent: this.bytes.sent,
            bytesReceived: this.bytes.received,
            packetsLost: 0,
            datagramsSent: this.counts.sent,
            datagramsReceived: this.counts.received,
            datagramDrops: this.counts.drops,
        };
        if (this.pathInfo.remote)
            s.remote = this.pathInfo.remote;
        const m = this.media?.used ? this.media.counters() : null;
        if (m)
            Object.assign(s, linkMediaStats(m));
        return { ...s, line: statsLine(s) };
    }
    /** The server's latest `link.stats` (null: none yet). */
    peerStats() {
        return this.peer;
    }
    /** The latest RTT sample of the selected path (ms; null: none yet). */
    get rttMs() {
        return this.latestRtt;
    }
    // MARK: speed test
    /**
     * The speed test (docs/LINK.md「测速」): the computer sends filler frames through this session's video path for
     * `durationMs` (it keeps it within 1000–20000; 8000 lets the rate control's startup climb reach its ceiling) and
     * the report says what a picture would get. Run it on a session that shows no picture (open streams share the
     * rate). Throws `LinkError("unsupported")` when this build or the computer has no speed test (the computer: after
     * 3 s), `"closed"` when the session ends; `signal` stops it.
     */
    async probe(durationMs = 8000, opts = {}) {
        const media = this.media;
        if (!media?.canProbe)
            throw new LinkError("unsupported", "this build of the media layer has no speed test");
        if (this.probeListener)
            throw new LinkError("media", "a speed test is running");
        const stream = media.freeVideoStream();
        if (stream === null)
            throw new LinkError("media", "no free video stream");
        const id = nextProbeId++;
        const idle = this.rtt.summary()[0];
        const before = media.counters();
        media.openProbe(stream);
        const queue = [];
        let wake = null;
        this.probeListener = (m) => {
            if (m.id !== id)
                return;
            queue.push(m);
            wake?.();
        };
        const rtts = [];
        const sampler = setInterval(() => {
            if (this.latestRtt !== null)
                rtts.push(this.latestRtt);
        }, RTT_EVERY_MS);
        let finished = false;
        // the next reply, or null at `ms`
        const next = (ms) => new Promise((resolve, reject) => {
            if (queue.length)
                return resolve(queue.shift());
            if (this.closeInfo)
                return reject(new LinkError("closed", this.closeInfo.description));
            let offClosed = () => { };
            const done = (f) => {
                clearTimeout(timer);
                wake = null;
                offClosed();
                opts.signal?.removeEventListener("abort", onAbort);
                f();
            };
            const timer = setTimeout(() => done(() => resolve(null)), ms);
            wake = () => done(() => resolve(queue.shift()));
            offClosed = this.onClosed((info) => done(() => reject(new LinkError("closed", info.description))));
            const onAbort = () => done(() => reject(new LinkError("closed", "the speed test was stopped")));
            if (opts.signal?.aborted)
                return onAbort();
            opts.signal?.addEventListener("abort", onAbort);
        });
        try {
            this.writeControl({ t: "link.probe", id, stream, ms: durationMs });
            let startedMs = durationMs;
            for (;;) {
                const m = await next(3000);
                if (!m)
                    throw new LinkError("unsupported", "the computer doesn't answer the speed test (an older version?)");
                if (m.t === "link.probe.error")
                    throw new LinkError("media", `speed test: ${typeof m.message === "string" ? m.message : "refused"}`);
                if (m.t === "link.probe.started") {
                    startedMs = typeof m.ms === "number" ? m.ms : durationMs;
                    break;
                }
            }
            const deadline = performance.now() + startedMs + 5000;
            let done = null;
            while (!done) {
                const m = await next(Math.max(0, deadline - performance.now()));
                if (!m)
                    break;
                if (m.t === "link.probe.done")
                    done = m;
            }
            finished = done !== null;
            return probeReport({
                path: this.pathInfo.kind,
                iface: this.iface(),
                durationMs: typeof done?.ms === "number" ? done.ms : startedMs,
                rttIdleMs: idle > 0 ? idle : null,
                rtts,
                before,
                after: media.counters(),
                probe: media.probeCounters(stream),
                done,
            });
        }
        finally {
            clearInterval(sampler);
            this.probeListener = null;
            media.closeVideo(stream);
            if (!finished && !this.closeInfo) {
                try {
                    this.writeControl({ t: "link.probe.stop", id });
                }
                catch {
                    /* closing */
                }
            }
        }
    }
    // MARK: closing
    /** Sends `bye` and closes (code `CloseCode.normal` by default). */
    async close(code = CloseCode.normal, reason = "") {
        if (this.closeInfo)
            return;
        try {
            this.writeControl({ t: "bye", code, reason });
        }
        catch {
            /* the channel is gone already */
        }
        // the bye leaves before the peer connection closes (SCTP flushes on a graceful close; give it a moment)
        await waitDrained(this.control, 250);
        this.finish({ code, reason, remote: false });
    }
    /** Resolves when the session ended (by either side or the network). */
    closed() {
        return this.closedPromise;
    }
    /** How it ended (null: it hasn't). */
    get closeReason() {
        return this.closeInfo;
    }
    /** Hears the end (at once when it ended already); returns the unsubscribe. */
    onClosed(listener) {
        if (this.closeInfo) {
            listener(this.closeInfo);
            return () => { };
        }
        this.closedListeners.add(listener);
        return () => this.closedListeners.delete(listener);
    }
    // MARK: internals
    writeControl(m) {
        if (this.closeInfo || this.control.readyState !== "open")
            throw new LinkError("closed", this.closeInfo?.description ?? "the control channel is not open");
        this.control.send(encodeFrame(m));
    }
    flushEarly() {
        const early = this.early;
        this.early = [];
        for (const f of early)
            this.dispatch(f);
    }
    onControlData(data) {
        this.flushEarly();
        this.lastReceived = performance.now();
        let frames;
        try {
            frames = this.reader.push(messageBytes(data));
        }
        catch (e) {
            void this.close(CloseCode.protocol, e instanceof Error ? e.message : String(e));
            return;
        }
        for (const f of frames)
            this.dispatch(f);
    }
    dispatch(f) {
        const t = f.t;
        if (typeof t !== "string" || this.closeInfo)
            return;
        if (t === "link.stats") {
            this.peer = parseLinkStats(f);
            return;
        }
        if (t === "link.probe.started" || t === "link.probe.done" || t === "link.probe.error") {
            this.probeListener?.(f);
            return;
        }
        if (t === "bye") {
            this.finish({ ...(typeof f.code === "number" ? { code: f.code } : { code: CloseCode.normal }), reason: typeof f.reason === "string" ? f.reason : "", remote: true });
            return;
        }
        for (const l of this.controlListeners) {
            try {
                l(f);
            }
            catch (err) {
                queueMicrotask(() => {
                    throw err;
                });
            }
        }
    }
    receiveDatagram(data) {
        this.lastReceived = performance.now();
        let d;
        try {
            d = messageBytes(data);
        }
        catch {
            this.counts.drops++;
            return;
        }
        this.counts.received++;
        if (d.length === 0 || (d[0] & 0x0f) !== 1) {
            this.counts.drops++;
            return;
        }
        const channel = d[0] >> 4;
        if (channel >= 1 && channel <= 5) {
            if (!this.media || !this.media.datagram(d))
                this.counts.drops++;
            return;
        }
        const set = this.datagramListeners.get(channel);
        if (!set || set.size === 0) {
            this.counts.drops++;
            return;
        }
        const payload = d.subarray(1);
        for (const l of set)
            l(payload);
    }
    onTick() {
        if (this.closeInfo)
            return;
        const now = performance.now();
        this.ticks++;
        if (this.latestRtt !== null)
            this.rtt.push(now, this.latestRtt);
        this.media?.setTransport(this.latestRtt, this.maxDatagramSize);
        if (this.ticks % Math.round(PEER_STATS_EVERY_MS / RTT_EVERY_MS) === 0)
            void this.readPeerStats();
        if (this.ticks % Math.round(STATS_EVERY_MS / RTT_EVERY_MS) === 0) {
            const { line: _line, ...s } = this.stats();
            try {
                this.writeControl({ t: "link.stats", ...s });
            }
            catch {
                /* closing */
            }
        }
        const limit = this.activityTimeoutMs ?? IDLE_MS;
        // while a lost path is looked for, `recover` decides
        if (this.recoveringSince === null && now - this.lastReceived > limit)
            this.pathLost(`nothing from the server for ${limit / 1000} s`, 0);
    }
    /** The selected candidate pair: its RTT, path and byte counts. */
    async readPeerStats() {
        if (this.readingStats || this.closeInfo)
            return;
        this.readingStats = true;
        try {
            const report = await this.pc.getStats();
            const pair = selectedPair(report);
            if (!pair)
                return;
            if (typeof pair.currentRoundTripTime === "number" && pair.currentRoundTripTime > 0)
                this.latestRtt = pair.currentRoundTripTime * 1000;
            if (typeof pair.bytesSent === "number")
                this.bytes.sent = pair.bytesSent;
            if (typeof pair.bytesReceived === "number")
                this.bytes.received = pair.bytesReceived;
            const cand = (id) => {
                const c = typeof id === "string" ? report.get(id) : undefined;
                if (!c)
                    return undefined;
                const address = (c.address ?? c.ip);
                return { ...(typeof c.candidateType === "string" ? { candidateType: c.candidateType } : {}), ...(address ? { address } : {}), ...(typeof c.port === "number" ? { port: c.port } : {}) };
            };
            const path = classifyPath(cand(pair.localCandidateId), cand(pair.remoteCandidateId));
            if (path.kind !== "none" && (path.kind !== this.pathInfo.kind || path.remote !== this.pathInfo.remote)) {
                this.pathInfo = path;
                for (const l of this.pathListeners)
                    l(this.path());
            }
        }
        catch {
            /* the connection is going away */
        }
        finally {
            this.readingStats = false;
        }
    }
    onNetworkChange = () => {
        if (!this.closeInfo && this.restartIce && this.recoveringSince === null) {
            this.recoveringSince = performance.now();
            void this.recover("the network changed", 0, false);
        }
    };
    /** The path is lost (ICE says so, or nothing came for the idle limit): look for a new one when the server takes
     *  restarts, else end. `firstAfterMs`: how long it gets to come back by itself first. */
    pathLost(why, firstAfterMs = RESTART_AFTER_MS) {
        if (this.closeInfo || this.recoveringSince !== null)
            return;
        if (!this.restartIce) {
            this.finish({ reason: why, remote: true });
            return;
        }
        this.recoveringSince = performance.now();
        void this.recover(why, firstAfterMs, true);
    }
    /** Resolves once something came from the server after `since` (or after `ms`, or when the session ended). */
    untilHeard(since, ms) {
        const until = performance.now() + ms;
        return new Promise((resolve) => {
            const poll = () => (this.lastReceived > since || this.closeInfo || performance.now() >= until ? resolve() : setTimeout(poll, 50));
            poll();
        });
    }
    /**
     * Restarts ICE until the server is heard again over the path it finds (or `RECOVER_MS` passed, or the server
     * refused the restart: it doesn't know the connection any more). `lost`: the path is known to be gone (else this is
     * a network change with the old path maybe still working: `recovering` only shows once a restart didn't help).
     */
    async recover(why, firstAfterMs, lost) {
        const t0 = this.recoveringSince ?? performance.now();
        const tell = (on) => {
            for (const l of this.recoveringListeners)
                l(on);
        };
        if (lost)
            tell(true);
        let ok = false;
        if (firstAfterMs > 0) {
            await this.untilHeard(t0, firstAfterMs);
            ok = this.lastReceived > t0;
        }
        while (!ok && !this.closeInfo && this.restartIce && performance.now() - t0 < RECOVER_MS) {
            const at = performance.now();
            try {
                if (!(await this.restartIce()))
                    this.restartIce = null; // this one is the server's last
            }
            catch (e) {
                // the server didn't know the connection (or refused it): no restart will work
                if (!(e instanceof LinkError && e.kind === "signal" && isNetworkFailure(e)))
                    this.restartIce = null;
            }
            await this.untilHeard(at, RESTART_EVERY_MS);
            ok = this.lastReceived > at;
            if (!ok && !lost) {
                lost = true;
                tell(true);
            }
        }
        this.recoveringSince = null;
        if (this.closeInfo)
            return;
        if (ok) {
            if (lost) {
                this.restarts++;
                tell(false);
            }
            void this.readPeerStats();
            return;
        }
        this.finish({ reason: `${why}; no new path found`, remote: true });
    }
    finish(c) {
        if (this.closeInfo)
            return;
        if (typeof window !== "undefined")
            window.removeEventListener("online", this.onNetworkChange);
        globalThis.navigator?.connection?.removeEventListener?.("change", this.onNetworkChange);
        this.recoveringListeners.clear();
        const info = { ...c, description: "" };
        info.description = describe(info);
        this.closeInfo = info;
        if (this.tick)
            clearInterval(this.tick);
        this.tick = null;
        this.media?.end();
        for (const ch of [this.control, this.dgram]) {
            try {
                ch.close();
            }
            catch {
                /* closed */
            }
        }
        try {
            this.pc.close();
        }
        catch {
            /* closed */
        }
        this.resolveClosed(info);
        for (const l of this.closedListeners)
            l(info);
        this.closedListeners.clear();
        this.controlListeners.clear();
        this.datagramListeners.clear();
        this.pathListeners.clear();
    }
}
/** The selected candidate pair of a stats report (Chrome / Safari: the transport's; Firefox: `selected`). */
export function selectedPair(report) {
    let byTransport;
    let fallback;
    report.forEach((s) => {
        if (s.type === "transport" && typeof s.selectedCandidatePairId === "string")
            byTransport = s.selectedCandidatePairId;
    });
    if (byTransport)
        return report.get(byTransport);
    report.forEach((s) => {
        if (s.type !== "candidate-pair")
            return;
        if (s.selected === true || (s.nominated === true && s.state === "succeeded" && !fallback))
            fallback = s;
    });
    return fallback;
}
/** Resolves when `ch` sent what it buffered (or after `maxMs`). */
export function waitDrained(ch, maxMs) {
    if (ch.bufferedAmount === 0 || ch.readyState !== "open")
        return new Promise((r) => setTimeout(r, 20));
    return new Promise((resolve) => {
        const t0 = performance.now();
        const poll = () => (ch.bufferedAmount === 0 || ch.readyState !== "open" || performance.now() - t0 > maxMs ? resolve() : setTimeout(poll, 10));
        poll();
    });
}
/** A signaling failure that came from not reaching the signaling path (offline, a timeout), not from its answer. */
function isNetworkFailure(e) {
    const cause = e.cause;
    const status = cause?.status;
    // a SignalError-like refusal with a status: 502 / 503 / 504 can pass (the path or the server is busy), the rest is final
    if (typeof status === "number")
        return status >= 502 && status <= 504;
    return true;
}
