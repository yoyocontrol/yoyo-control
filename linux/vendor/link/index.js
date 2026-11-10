// @yoyocontrol/link: uu Link for Node (docs/LINK.md). Endpoints, sessions, control messages, RPC, datagram channels
// over the shared Rust core (link/, the native addon in native/).
import { native, } from "./native.js";
export { nativeName } from "./native.js";
/** The media layer's datagram channels (byte 0 of a datagram is `channel << 4 | 1`). They belong to the session's
 * media API (`sendFrame`, `nextClientEvent`, …); raw datagrams are for the app's own channels 6–15. */
export const Channel = { video: 1, audio: 2, input: 3, feedback: 4, cursor: 5 };
/** QUIC application close codes. */
export const CloseCode = {
    normal: 0,
    unauthorized: 1,
    rateLimited: 2,
    busy: 3,
    protocol: 4,
    shuttingDown: 5,
    replaced: 6,
};
/** Every error of this package. `code` is the deny code for `kind: "denied"`. */
export class LinkError extends Error {
    kind;
    code;
    constructor(kind, message, code) {
        super(message);
        this.kind = kind;
        this.code = code;
        this.name = "LinkError";
    }
}
function lift(e) {
    if (e instanceof LinkError)
        return e;
    const message = e instanceof Error ? e.message : String(e);
    const m = /^\[([a-z-]+)(?::([a-z-]+))?\] ([\s\S]*)$/.exec(message);
    if (!m)
        return new LinkError("internal", message);
    return new LinkError(m[1], m[3] ?? "", m[2]);
}
async function call(f) {
    try {
        return await f();
    }
    catch (e) {
        throw lift(e);
    }
}
function sync(f) {
    try {
        return f();
    }
    catch (e) {
        throw lift(e);
    }
}
export const version = () => native().version();
/** A new random link secret key (32 bytes). */
export const generateLinkKey = () => native().generateLinkKey();
/** hex of the public key (endpoint id) of a link secret key. */
export const linkPublicKey = (secretKey) => sync(() => native().linkPublicKey(secretKey));
/** The link secret key in `path` (32 bytes, 0600), made on first use. */
export const loadOrCreateLinkKey = (path) => sync(() => native().loadOrCreateLinkKey(path));
/** `"sha256:" + hex(SHA-256(public key))` of a 97-byte X9.63 identity private key. */
export const identityFingerprint = (identityKey) => sync(() => native().identityFingerprint(identityKey));
/** The identity's binding over a link public key (hex). */
export const signBinding = (identityKey, linkPublicKey) => sync(() => native().signBinding(identityKey, linkPublicKey));
/** Checks a binding against the pinned fingerprint; returns the endpoint id it vouches for. */
export const verifyBinding = (binding, fingerprint) => sync(() => native().verifyBinding(binding, fingerprint));
/** Where the link's log lines go (`link:` stats, sessions, paths, guard); `null`: nowhere. */
export function setLogSink(sink) {
    native().setLogSink(sink ? (level, message) => sink(level, message) : null);
}
export async function bindEndpoint(config) {
    const ep = await call(() => native().bindEndpoint(config));
    return new Endpoint(ep);
}
export class Endpoint {
    ep;
    /** @internal */
    constructor(ep) {
        this.ep = ep;
    }
    /** hex of the link public key */
    get id() {
        return this.ep.id;
    }
    get port() {
        return this.ep.port;
    }
    /** The rtc UDP port; `null` without rtc. */
    get rtcPort() {
        return this.ep.rtcPort;
    }
    /** The rtc port's router mapping (`ip:port`): rtc answers offer it until removed. False without rtc. */
    addRtcExternalAddr(addr) {
        return sync(() => this.ep.addRtcExternalAddr(addr));
    }
    removeRtcExternalAddr(addr) {
        return sync(() => this.ep.removeRtcExternalAddr(addr));
    }
    addrInfo() {
        return this.ep.addrInfo();
    }
    /** Calls `cb` now and at every change of the address info, until the endpoint is closed. */
    watchAddr(cb) {
        this.ep.watchAddr(cb);
    }
    /** The identity's binding over this endpoint's key (97-byte X9.63 identity private key). */
    binding(identityKey) {
        return sync(() => this.ep.binding(identityKey));
    }
    /** An `ip:port` this endpoint is reachable on that it can't see itself (a router port mapping the app made):
     * advertised with its own addresses until removed. */
    addExternalAddr(addr) {
        return call(() => this.ep.addExternalAddr(addr));
    }
    removeExternalAddr(addr) {
        return call(() => this.ep.removeExternalAddr(addr));
    }
    /** The network changed: re-probe addresses and paths now. */
    networkChanged(iface) {
        return call(() => this.ep.networkChanged(iface));
    }
    async dial(target, hello, options = {}) {
        const s = await call(() => this.ep.dial(target, hello, options.connectTimeoutMs));
        return new Session(s);
    }
    /** Dials a server over WebRTC the way a browser does (docs/LINK.md「WebRTC」): `signal(offerJson)` carries the offer
     * to the server's `acceptRtcOffer` (any path: HTTP, a relay) and resolves with the answer JSON, which is checked
     * against the pinned identity `fingerprint` before connecting. Needs `rtcPort` in the endpoint config. */
    async dialRtc(signal, fingerprint, hello, options = {}) {
        const s = await call(() => this.ep.dialRtc(signal, fingerprint, hello, options.connectTimeoutMs));
        return new Session(s);
    }
    /** Starts accepting sessions (servers, once). */
    listen(options) {
        const authenticate = async (r) => {
            const d = await options.authenticate({ ...r, path: r.path });
            return d.ok
                ? { ok: true, principal: d.principal ?? null, features: d.features }
                : { ok: false, code: d.code, message: d.message ?? "" };
        };
        const handler = options.rpc;
        const rpc = handler
            ? (s, req, body, res) => {
                const response = new RpcResponder(res);
                Promise.resolve()
                    .then(() => handler(new Session(s), { ...req, headers: req.headers ?? {} }, body, response))
                    .catch((e) => response.fail(e));
            }
            : undefined;
        const settings = {
            server: options.server,
            features: options.features,
            rpcBlockedPaths: options.rpcBlockedPaths,
            maxRequestBody: options.maxRequestBody,
            recoveryOnNack: options.recoveryOnNack,
            identityKey: options.identityKey,
        };
        return new Listener(sync(() => this.ep.listen(settings, authenticate, rpc)));
    }
    close() {
        return this.ep.close();
    }
}
export class Listener {
    l;
    /** @internal */
    constructor(l) {
        this.l = l;
    }
    /** The next authenticated session; `null` once the endpoint is closed. */
    async accept() {
        const s = await this.l.accept();
        return s ? new Session(s) : null;
    }
    /** A browser's WebRTC offer JSON (`{"v":1,"offer","device"}`) → the signed answer JSON; the session comes out of
     * `accept` once it connected and said hello (docs/LINK.md「WebRTC」). `sourceIp`: the signaling request's address
     * when known. Rejects with `LinkError` kind `invalid-argument` (no rtc / identity, a bad offer) or `denied`
     * (`rate-limited`: the source is blocked; `busy`: too many sessions or pending offers). */
    acceptRtcOffer(offerJson, sourceIp) {
        return call(() => this.l.acceptRtcOffer(offerJson, sourceIp));
    }
    async *[Symbol.asyncIterator]() {
        for (;;) {
            const s = await this.accept();
            if (!s)
                return;
            yield s;
        }
    }
}
export class Session {
    s;
    /** @internal */
    constructor(s) {
        this.s = s;
    }
    get id() {
        return this.s.id;
    }
    get isServer() {
        return this.s.isServer;
    }
    /** hex of the other side's link public key (an rtc client: `dtls-sha256:<hex>` of its DTLS certificate) */
    get remoteId() {
        return this.s.remoteId;
    }
    /** "quic" or "rtc" (WebRTC: a browser) */
    get transport() {
        return this.s.transport;
    }
    /** the client's hello (both sides) */
    get hello() {
        return this.s.hello();
    }
    /** the server's welcome (both sides) */
    get welcome() {
        return this.s.welcome();
    }
    get principal() {
        return this.s.welcome().principal;
    }
    sendControl(message) {
        return call(() => this.s.sendControl(message));
    }
    /** The next control message; `null` once the session ended. */
    recvControl() {
        return this.s.recvControl();
    }
    async *controlMessages() {
        for (;;) {
            const m = await this.recvControl();
            if (!m)
                return;
            yield m;
        }
    }
    async request(request, body) {
        const r = await call(() => this.s.request(request, body));
        return new RpcResponse(r);
    }
    /** Sends `channel << 4 | 1` then `payload`. */
    sendDatagram(channel, payload) {
        sync(() => this.s.sendDatagram(channel, payload));
    }
    /** Sends a whole datagram (byte 0 already the header). */
    sendDatagramRaw(datagram) {
        sync(() => this.s.sendDatagramRaw(datagram));
    }
    /** The next datagram of `channel`, whole (byte 0 = header); `null` once the session ended. */
    recvDatagram(channel) {
        return call(() => this.s.recvDatagram(channel));
    }
    async *datagrams(channel) {
        for (;;) {
            const d = await this.recvDatagram(channel);
            if (!d)
                return;
            yield d;
        }
    }
    get maxDatagramSize() {
        return this.s.maxDatagramSize;
    }
    /** bits per second every path's congestion window follows */
    get targetBitrate() {
        return this.s.targetBitrate;
    }
    set targetBitrate(bps) {
        this.s.targetBitrate = bps;
    }
    path() {
        const p = this.s.path();
        return { kind: p.kind, remote: p.remote };
    }
    stats() {
        return this.s.stats();
    }
    peerStats() {
        return this.s.peerStats();
    }
    /** The media layer's numbers (lossPct, fecRecovered, fps, …). */
    setMediaStats(stats) {
        sync(() => this.s.setMediaStats(stats));
    }
    /** Sends `bye` and closes with `code` (default normal). */
    close(code = CloseCode.normal, reason = "") {
        return this.s.close(code, reason);
    }
    get isClosed() {
        return this.s.isClosed;
    }
    // media (channels 1–5)
    /** Opens video stream `stream` (server: per `video.open`, frames from 1; client: per `video.opened`). */
    openVideo(stream) {
        sync(() => this.s.openVideo(stream));
    }
    closeVideo(stream) {
        sync(() => this.s.closeVideo(stream));
    }
    openAudio(stream) {
        sync(() => this.s.openAudio(stream));
    }
    closeAudio(stream) {
        sync(() => this.s.closeAudio(stream));
    }
    /** Server: whether to encode the next picture now (false: skip it, the newest picture wins). */
    canSendFrame(stream) {
        return sync(() => this.s.canSendFrame(stream));
    }
    /**
     * Server: the frame-rate cap of `stream` (frames/s, follows the encoder rate; null: no such stream). An encoder
     * that budgets per frame at a fixed frame rate (x264 without VFR) should get `encoderBps × its fps / cap`.
     * Older native addons don't have it: null.
     */
    frameRateCap(stream) {
        if (typeof this.s.frameRateCap !== "function")
            return null;
        return sync(() => this.s.frameRateCap(stream)) ?? null;
    }
    /** Server: one encoded frame (Annex-B); returns its frame number. */
    sendFrame(stream, meta, au) {
        return sync(() => this.s.sendFrame(stream, meta, au));
    }
    /** Server: one Opus packet; returns its aseq. */
    sendAudio(stream, timeUs, opus) {
        return sync(() => this.s.sendAudio(stream, timeUs, opus));
    }
    /** Server: the newest cursor position (`{x, y, visible, shapeId}`). */
    sendCursor(stream, cursor) {
        const json = Buffer.isBuffer(cursor) ? cursor : Buffer.from(JSON.stringify(cursor));
        sync(() => this.s.sendCursor(stream, json));
    }
    /** Server: force a key frame next; client: ask for one. */
    requestKeyframe(stream) {
        sync(() => this.s.requestKeyframe(stream));
    }
    /** Server: the next media event (target bitrate, deliveries, recovery / key frame needed, input). */
    nextServerEvent() {
        return this.s.nextServerEvent();
    }
    async *serverEvents() {
        for (;;) {
            const e = await this.nextServerEvent();
            if (!e)
                return;
            yield e;
        }
    }
    /** Client: one input event (the `/input` body); returns its seq. A `media` error with "Overflow" is a 429. */
    sendInput(kind, event) {
        const json = Buffer.isBuffer(event) ? event : Buffer.from(JSON.stringify(event));
        return sync(() => this.s.sendInput(kind, json));
    }
    /** Client: the decoder took (`ok`) or failed on a frame. */
    frameDecoded(stream, frame, ok = true) {
        sync(() => this.s.frameDecoded(stream, frame, ok));
    }
    /** Client: the next media event (frames, audio packets, cursor, input acked / failed). */
    nextClientEvent() {
        return this.s.nextClientEvent();
    }
    async *clientEvents() {
        for (;;) {
            const e = await this.nextClientEvent();
            if (!e)
                return;
            yield e;
        }
    }
    closed() {
        return this.s.closed();
    }
}
// MARK: RPC
export class RpcResponse {
    r;
    /** @internal */
    constructor(r) {
        this.r = r;
    }
    get status() {
        return this.r.status;
    }
    /** lower-case names */
    get headers() {
        return this.r.headers;
    }
    /** The next piece of the body; `null` at its end. */
    chunk() {
        return call(() => this.r.chunk());
    }
    /** The rest of the body (at most `limit` bytes, default 64 MiB). */
    readAll(limit) {
        return call(() => this.r.readAll(limit));
    }
    async text() {
        return (await this.readAll()).toString("utf8");
    }
    async json() {
        return JSON.parse(await this.text());
    }
    async *[Symbol.asyncIterator]() {
        for (;;) {
            const c = await this.chunk();
            if (!c)
                return;
            yield c;
        }
    }
    /** Stops reading (a streamed response ends). */
    cancel() {
        this.r.cancel();
    }
}
export class RpcResponder {
    r;
    started = false;
    /** @internal */
    constructor(r) {
        this.r = r;
    }
    head(status, headers = {}) {
        this.started = true;
        return call(() => this.r.head(status, headers));
    }
    write(data) {
        return call(() => this.r.write(typeof data === "string" ? Buffer.from(data) : data));
    }
    /** Ends the body (a 200 head first if none was sent). */
    finish() {
        this.started = true;
        return call(() => this.r.finish());
    }
    /** Head, body, finish. */
    respond(status, headers = {}, body) {
        this.started = true;
        const b = typeof body === "string" ? Buffer.from(body) : body;
        return call(() => this.r.respond(status, headers, b));
    }
    json(status, value, headers = {}) {
        return this.respond(status, { "content-type": "application/json", ...headers }, JSON.stringify(value));
    }
    /** Resolves when the client stopped reading (cancelled) or the session ended. */
    stopped() {
        return this.r.stopped();
    }
    /** @internal a handler threw */
    fail(e) {
        if (this.started)
            return;
        const message = e instanceof Error ? e.message : String(e);
        void this.json(500, { error: message }).catch(() => { });
    }
}
