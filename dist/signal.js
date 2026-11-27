// The signaling client (docs/RELAY.md, protocol v1): keeps this server registered in its room at the signaling server
// (`relay/signal` is one; none is built in) — a WebSocket signed in with the identity key, so only the holder of that
// key can hold the room. Phones and browsers ask the room for the uu Link binding (`setLink`: `{"type":"link", …}`,
// docs/LINK.md「身份与信任」, sent after `ready` and whenever it changes). A browser's WebRTC offer comes as
// `{"type":"rtc","id","offer","from"}` (docs/RELAY.md「WebRTC」): `rtcAnswerer` (the link listener's) answers it, and the
// answer goes back as `{"type":"rtc-answer","id","answer"}` or `{"type":"rtc-error","id","status","message"}`.
//
// Reconnects after a drop (1 s, doubling to 60 s); a `ping` every 30 s, and no `pong` for 45 s more counts as a drop.
// Node 22's global WebSocket.
import { sign } from "node:crypto";
import { EventEmitter } from "node:events";
/** Where a server keeps its room: `explicit`, else `YOYO_SIGNAL_URL`; none is built in (`""`: no signaling server). */
export function signalUrl(explicit) {
    return (explicit || process.env.YOYO_SIGNAL_URL || "").trim().replace(/\/+$/, "");
}
export const RELAY_PING_MS = 30_000;
export const RELAY_PONG_TIMEOUT_MS = 45_000;
export const RELAY_MAX_BACKOFF_MS = 60_000;
const SIGNED_PREFIX = "yoyocontrol-relay-v1:";
/** The room of a key: 64 lowercase hex digits (its fingerprint without "sha256:"). */
export function relayRoom(keyFingerprint) {
    return keyFingerprint.replace(/^sha256:/, "");
}
/** The answer to the room's challenge: `{ type: "hello", v: 1, key, sig }`, `sig` = raw r ‖ s over "yoyocontrol-relay-v1:" + nonce. */
export function relayHello(nonce, identity) {
    const sig = sign("sha256", Buffer.from(SIGNED_PREFIX + nonce, "utf8"), { key: identity.key, dsaEncoding: "ieee-p1363" });
    return JSON.stringify({ key: identity.publicKey.toString("base64"), sig: sig.toString("base64"), type: "hello", v: 1 });
}
/** `{"direct":[…],"id","key","relays":[…],"sig","type":"link"}`. */
export function linkMessage(link) {
    return JSON.stringify({ direct: link.direct, id: link.id, key: link.key, relays: link.relays, sig: link.sig, type: "link" });
}
/** `{"id","type":"account"}` (`"id":null`: none). */
export function accountMessage(id) {
    return JSON.stringify({ id, type: "account" });
}
/** The reply to an `rtc` message: `rtc-answer`, or `rtc-error` with the failure's status (default 503). */
export async function rtcReply(id, offer, from, answerer) {
    try {
        if (!offer || typeof offer !== "object" || Array.isArray(offer))
            throw Object.assign(new Error("offer must be a JSON object"), { status: 400 });
        if (!answerer)
            throw Object.assign(new Error("uu Link's WebRTC is not running"), { status: 404 });
        const answer = await answerer(offer, from);
        return JSON.stringify({ answer, id, type: "rtc-answer" });
    }
    catch (e) {
        const status = e.status;
        const message = e instanceof Error ? e.message : String(e);
        return JSON.stringify({ id, message, status: typeof status === "number" && status >= 400 && status < 600 ? status : 503, type: "rtc-error" });
    }
}
/** Events: `change` (registered or not: `registered`); `unlinked` (the room says it isn't in its account any more). */
export class SignalClient extends EventEmitter {
    /** Who answers browsers' WebRTC offers (the link listener's `acceptRtcOffer`); null: none (they get a 404). */
    rtcAnswerer = null;
    base;
    room;
    opts;
    log;
    WS;
    control = null;
    running = false;
    _registered = false;
    backoff = 1000;
    lastPong = 0;
    pinger = null;
    retry = null;
    linkText = null;
    account = null;
    constructor(opts) {
        super();
        this.opts = opts;
        this.log = opts.log ?? (() => { });
        this.base = signalUrl(opts.url);
        if (!this.base)
            throw new Error("SignalClient: no signaling server (opts.url or YOYO_SIGNAL_URL); none is built in");
        this.room = relayRoom(opts.identity.keyFingerprint);
        const WS = opts.WebSocket ?? globalThis.WebSocket;
        if (!WS)
            throw new Error("no WebSocket in this Node (22 or later is needed)");
        this.WS = WS;
    }
    get registered() {
        return this._registered;
    }
    start() {
        if (this.running)
            return;
        this.running = true;
        this.connect();
    }
    /** Leaves the room. */
    stop() {
        this.running = false;
        if (this.retry)
            clearTimeout(this.retry);
        this.retry = null;
        this.stopPinging();
        const c = this.control;
        this.control = null;
        try {
            c?.close(1000);
        }
        catch {
            // closing anyway
        }
        this.setRegistered(false);
    }
    /** The link told to the room (null: none — not sent; a room keeps the last one until this server registers again). */
    setLink(link) {
        const text = link ? linkMessage(link) : null;
        if (text === this.linkText)
            return;
        this.linkText = text;
        if (text && this._registered && this.control)
            this.send(this.control, text);
    }
    /**
     * The account this server is in (docs/ACCOUNT.md; null: none), told to the room after `ready` and when it changes.
     * The room answers `{"type":"account","state"}`; "unlinked" (it isn't in that account's directory any more) is the
     * `unlinked` event.
     */
    setAccount(id) {
        if (id === this.account)
            return;
        this.account = id;
        if (this._registered && this.control)
            this.send(this.control, accountMessage(id));
    }
    connect() {
        if (!this.running)
            return;
        let ws;
        try {
            ws = new this.WS(`${this.base}/v1/mac/${this.room}`);
        }
        catch (err) {
            this.log(`remote: signal: ${err instanceof Error ? err.message : String(err)}`);
            this.again();
            return;
        }
        this.control = ws;
        ws.addEventListener("message", (ev) => {
            if (this.control !== ws)
                return;
            if (typeof ev.data === "string")
                this.handle(ev.data, ws);
        });
        const dropped = (why) => this.dropped(ws, why);
        ws.addEventListener("close", (ev) => dropped(`closed ${ev.code}${ev.reason ? ` ${ev.reason}` : ""}`));
        ws.addEventListener("error", () => dropped("connection failed"));
    }
    handle(text, ws) {
        if (text === "pong") {
            this.lastPong = Date.now();
            return;
        }
        let msg;
        try {
            msg = JSON.parse(text);
        }
        catch {
            return;
        }
        switch (msg.type) {
            case "challenge":
                if (typeof msg.nonce !== "string")
                    return this.dropped(ws, "a challenge it can't answer");
                this.send(ws, relayHello(msg.nonce, this.opts.identity));
                return;
            case "ready":
                this.backoff = 1000;
                this.lastPong = Date.now();
                this.setRegistered(true);
                this.startPinging(ws);
                if (this.linkText)
                    this.send(ws, this.linkText);
                this.send(ws, accountMessage(this.account));
                this.log(`remote: signal: registered (${hostOf(this.base)})`);
                return;
            case "account":
                if (msg.state === "unlinked" && this.account !== null) {
                    this.account = null;
                    this.emit("unlinked");
                }
                return;
            case "rtc": {
                const m = msg;
                if (typeof m.id !== "string" || !/^[0-9a-f]{32}$/i.test(m.id))
                    return;
                void rtcReply(m.id, m.offer, typeof m.from === "string" ? m.from : null, this.rtcAnswerer).then((reply) => {
                    // (the connection it came on, only: a new one's room knows nothing of this offer)
                    if (this.control === ws)
                        this.send(ws, reply);
                });
                return;
            }
        }
    }
    send(ws, text) {
        try {
            if (ws.readyState === 1)
                ws.send(text);
        }
        catch {
            // the drop handler takes it from here
        }
    }
    startPinging(ws) {
        this.stopPinging();
        this.pinger = setInterval(() => {
            if (this.control !== ws)
                return;
            if (Date.now() - this.lastPong > RELAY_PING_MS + RELAY_PONG_TIMEOUT_MS)
                this.dropped(ws, "no pong");
            else
                this.send(ws, "ping");
        }, RELAY_PING_MS);
        this.pinger.unref();
    }
    stopPinging() {
        if (this.pinger)
            clearInterval(this.pinger);
        this.pinger = null;
    }
    dropped(ws, why) {
        if (this.control !== ws)
            return;
        this.control = null;
        this.stopPinging();
        try {
            ws.close();
        }
        catch {
            // gone already
        }
        if (this._registered || this.backoff === 1000)
            this.log(`remote: signal: disconnected from ${hostOf(this.base)} (${why}); again in ${this.backoff / 1000} s`);
        this.setRegistered(false);
        this.again();
    }
    again() {
        if (!this.running || this.retry)
            return;
        const wait = this.backoff;
        this.backoff = Math.min(this.backoff * 2, RELAY_MAX_BACKOFF_MS);
        this.retry = setTimeout(() => {
            this.retry = null;
            if (this.running && !this.control)
                this.connect();
        }, wait);
        this.retry.unref();
    }
    setRegistered(on) {
        if (this._registered === on)
            return;
        this._registered = on;
        this.emit("change", on);
    }
}
function hostOf(url) {
    try {
        return new URL(url).host;
    }
    catch {
        return url;
    }
}
