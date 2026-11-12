// uu Link on the Linux server (docs/LINK.md, README.md「uu Link」): remote access's door — the phones of Yoyo Control's
// iOS app pair over it and reach this server over UDP / QUIC, as they reach a Mac — one session per phone carrying the
// screen (x264 → the link's media layer: FEC, NACK, the bit rate), the sound, the pointer and input; everything else
// (status, events, the clipboard) as RPC streams through the remote routes and their allowlist (REMOTE_ROUTES).
//
// - Runs while remote access listens (remote.mjs starts and stops it); UDP `port` (default 47820) on every interface.
//   The link key is `<home>/link-key`, its binding signed with remote access's identity key: `/status` `link` and the
//   signaling server's `{"type":"link", …}` carry it.
// - Who enters: `Bearer <token>` of a paired device (bound to the first link key it comes with), or `Pair <code>` with
//   the pairing code being shown (pairs, binds the key, hands the token back in `welcome.principal`).
// - The router maps the UDP port (remote.mjs, with its port-mapping options); the mapped address and the `--advertise`
//   ones go to the endpoint as external addresses (a container's own addresses are not where a phone reaches it).
// - A lost picture costs a small one, not a key frame: the video helper keeps earlier pictures (x264enc.h), so a
//   recovery request is answered with a picture that references the newest one the phone confirmed (`recovery`,
//   `recoveryBase`). A key frame only at the start, when the phone's decoder asks for one, or when the confirmed
//   picture is older than the helper keeps (at most one per 500 ms). A helper without that (the hello's `refs`)
//   answers every recovery request with a key frame.
// - Needs the native addon (vendor/link/uu-link.linux-<arch>-gnu.node in the release tar, or YOYO_LINK_NATIVE): without
//   it the server runs as before, without the link (one log line).
// - Authority mode (headless, no `--remote`: `--link on --link-home <dir>`): one local program holding the token decides
//   who opens a session and who sends input (LinkAuthority, docs/LOCAL-API.md「Link 的主人」, as on the Mac). The keys
//   are `<dir>/link-key` and the identity `<dir>/tls-key.der` the binding is signed with; its fingerprint is in
//   `/status.link.fingerprint`.
// - Browsers (docs/LINK.md「WebRTC」): a second UDP socket, `rtcPort` (default the link port + 1), for WebRTC sessions of
//   the same protocol; offers come through `POST /link/rtc` on the token listener (`acceptRtcOffer`), answers are signed
//   with the identity key. The router maps it like the link port; `--advertise` hosts are offered on it too;
//   `/status.link.rtc = { port, direct? }`.
import { EventEmitter } from "node:events";
import { join } from "node:path";
import { CURSOR_MIN_INTERVAL, SENT_SHAPES_MAX } from "./cursor.mjs";
import { RefineSchedule, TUNING, limitedTuning, linkBufferKbit, liveBudget, parsePlayoutReport, playoutLine, refineKbps } from "./flow.mjs";
import { InputError } from "./input.mjs";
import { AUDIO, audioCookie } from "./audio.mjs";
import { CRF } from "./video.mjs";

/** The token listener's client as the routes know it (server.mjs LOCAL): authority-mode input and RPC are the host's. */
const LOCAL_CLIENT = Object.freeze({ kind: "local" });

export const DEFAULT_LINK_PORT = 47820;

/** The rtc port that goes with a link port: the next one (any when the link's is any). */
export function defaultRtcPort(port) {
  return port === 0 ? 0 : port + 1;
}

/** `host[:port]` → `host:port` on `port` (a link `--advertise` address on the rtc port). */
export function onPort(addr, port) {
  const host = addr.startsWith("[") ? addr.slice(0, addr.indexOf("]") + 1) : addr.replace(/:\d+$/, "");
  return `${host}:${port}`;
}
/** The fewest seconds between two key frames asked for by the phone (recovery, a decoder that lost its way). */
export const KEY_MIN_INTERVAL = 0.5;
/**
 * How long a key frame of `bytes` is on its way at `kbps` before another may follow (seconds, at least
 * KEY_MIN_INTERVAL): twice what the link takes to release it, and the phone's patience for its last packets. A second
 * key frame sent sooner overtakes the first on the phone — which then waits for the second, just as long.
 */
export function keyTransit(bytes, kbps) {
  return Math.max(KEY_MIN_INTERVAL, (2 * bytes * 8) / (Math.max(kbps, 1) * 1000) + 0.2);
}
/** The fewest seconds between two recovery pictures (a request repeated before the first answer reached the phone). */
export const RECOVERY_MIN_INTERVAL = 0.05;
/** How many sent pictures' numbers a stream remembers (the helper keeps at most 16 pictures). */
const NUMBERS_KEPT = 128;
/** How often a full link queue is looked at again while it holds a picture back. */
const HELD_POLL_MS = 4;
const STATS_EVERY = 10;
/** The routes' answers to the link's input refusals (docs/LINK.md「控制流」`input.rejected.code`). */
const REJECT_CODES = { 400: "bad-event", 401: "unauthorized", 403: "no-permission", 404: "bad-event", 409: "no-control", 429: "rate-limited" };
/** Authority mode: an `auth` the host leaves unanswered this long is denied `busy`; a take / release is answered then. */
export const AUTHORITY_ANSWER_MS = 3000;
/** Authority mode: at most one `activity` line per device this often. */
export const AUTHORITY_ACTIVITY_MS = 1000;
/** Authority mode: a blank line on the host's channel this often (a dead host is noticed). */
const AUTHORITY_PING_MS = 15_000;
/** Authority mode: the RPC routes a session may use (the rest of the host's API is the host's to serve). */
const AUTHORITY_RPC = new Set(["GET /status"]);

const monotonic = () => performance.now() / 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The link package (vendor/link) with its addon loaded, or null and why. */
export async function loadLink() {
  try {
    const L = await import("./vendor/link/index.js");
    L.version();
    return { L };
  } catch (err) {
    return { L: null, error: err instanceof Error ? err.message : String(err) };
  }
}

/** `host[:port]` (IPv4) → `host:port` with `port` filled in. */
export function withPort(addr, port) {
  return /:\d+$/.test(addr) ? addr : `${addr}:${port}`;
}

/** The stream byte of a control message's `id`: 1…255, else null. */
export function streamId(v) {
  return Number.isInteger(v) && v >= 1 && v <= 255 ? v : null;
}

/**
 * The link listener: `start(identity)` binds and listens, `stop()` ends every session. Either of one remote access
 * (remote.mjs; `remote`: the RemoteAccess — its devices, control, settings) or in authority mode (`authority`: a
 * LinkAuthority, `home`: the keys' folder, `serverId`, `name`). `svc`: the YoyoLinux service. `relays`: iroh relay
 * URLs published in the binding (empty: direct only, and no hole punching, which needs a relay on both ends).
 */
export class LinkServer {
  constructor({ L, svc, remote = null, authority = null, home, serverId, name, port = DEFAULT_LINK_PORT, relays = [], rtcPort = defaultRtcPort(port), stun = [], advertise = [], exempt = [], bind = [], log = () => {}, clock = monotonic }) {
    this.L = L;
    this.svc = svc;
    this.remote = remote;
    this.authority = authority;
    this.home = home ?? remote?.home;
    this.serverId = serverId;
    this.name = name;
    /** The identity key's fingerprint (what the binding is signed with), once started. */
    this.fingerprint = null;
    this.port = port;
    this.relays = relays;
    /** The WebRTC socket's UDP port (null: no rtc) and its STUN servers. */
    this.rtcPort = rtcPort;
    this.stun = stun;
    this.advertiseHosts = advertise;
    this.advertise = advertise.map((a) => withPort(a, port));
    this.exempt = exempt;
    /** Only these local addresses (empty: every interface). */
    this.bind = bind;
    this.log = log;
    this.clock = clock;
    this.ep = null;
    this.binding = null;
    this.addr = null;
    /** The router's mapping of the UDP port (an external `ip:port`), when there is one; the same for the rtc port. */
    this.mapped = null;
    this.rtcMapped = null;
    this.listener = null;
    this.peers = new Set();
    /** Called when what `json()` says changes (the signaling server is told). */
    this.onChange = () => {};
  }

  async start(identity) {
    const L = this.L;
    // the core's lines (link[server] / link[phone] every 10 s, sessions, paths, the guard) into the server's log
    L.setLogSink((level, message) => {
      if (level !== "debug") this.log(message);
    });
    const key = L.loadOrCreateLinkKey(join(this.home, "link-key"));
    this.ep = await L.bindEndpoint({
      role: "server",
      secretKey: key,
      port: this.port,
      relays: this.relays,
      portmapper: false,
      guard: { exempt: this.exempt },
      ...(this.bind.length ? { bindIps: this.bind } : {}),
      ...(this.rtcPort === null ? {} : { rtcPort: this.rtcPort, rtcStunServers: this.stun }),
    });
    const { x963Private } = await import("./vendor/remote/index.js");
    const identityKey = x963Private(identity.key);
    this.binding = this.ep.binding(identityKey);
    this.fingerprint = identity.keyFingerprint;
    for (const a of this.advertise) await this.ep.addExternalAddr(a).catch((err) => this.log(`link: advertise ${a}: ${err.message}`));
    const rtcPort = this.ep.rtcPort;
    if (rtcPort !== null) {
      for (const h of this.advertiseHosts) {
        try {
          this.ep.addRtcExternalAddr(onPort(h, rtcPort));
        } catch (err) {
          this.log(`link: advertise ${h} (rtc): ${err.message}`);
        }
      }
    }
    this.ep.watchAddr((info) => {
      this.addr = info;
      this.onChange();
    });
    this.addr = this.ep.addrInfo();
    const listener = this.ep.listen({
      server: this.remote ? { id: this.remote.settings.serverId, name: this.remote.name, platform: this.svc.platform?.id ?? "linux" } : { id: this.serverId, name: this.name, platform: this.svc.platform?.id ?? "linux" },
      features: ["screen", "audio", "cursor", "input"],
      // a NACK asks for a recovery picture at once where one is cheap (the helper keeps earlier pictures): when the
      // retransmit fails too, the picture that mends the stream is already on its way
      recoveryOnNack: this.svc.platform?.cheapRecovery === true,
      authenticate: (r) => this.authenticate(r),
      rpc: (session, req, body, res) => this.rpc(session, req, body, res),
      identityKey,
    });
    this.listener = listener;
    this.log(`link: listening on udp ${this.ep.port} (${this.ep.id.slice(0, 12)}…)${rtcPort !== null ? `, rtc on udp ${rtcPort}` : ""}`);
    void (async () => {
      for await (const s of listener) this.opened(s);
    })().catch((err) => this.log(`link: ${err?.stack ?? err}`));
  }

  async stop() {
    const ep = this.ep;
    this.ep = null;
    this.listener = null;
    for (const p of [...this.peers]) await p.session.close(this.L.CloseCode.shuttingDown, "the server is stopping").catch(() => {});
    await ep?.close().catch(() => {});
    this.L.setLogSink(null);
  }

  /** `/status` `link` (and the signaling server's): the binding, where the endpoint is, the identity key's fingerprint. */
  json() {
    if (!this.ep || !this.binding) return null;
    // the relays without their `?token=` (each side has its own; an older phone matches the bare URL)
    const j = { ...this.binding, port: this.ep.port, relays: this.relays.map((r) => r.replace(/\?.*$/, "")), direct: this.addr?.direct ?? [], fingerprint: this.fingerprint };
    const rtcPort = this.ep.rtcPort;
    if (rtcPort !== null) j.rtc = { port: rtcPort, ...(this.rtcMapped ? { direct: [this.rtcMapped] } : {}) };
    return j;
  }

  /**
   * A browser's WebRTC offer JSON → the signed answer JSON (`POST /link/rtc`); the session comes out of the listener
   * like a phone's. Throws an error with `status`: 404 (no rtc), 400 (a bad offer), 429 / 503 (the guard).
   */
  async acceptRtcOffer(offer, sourceIp) {
    const fail = (status, message) => Object.assign(new Error(message), { status });
    if (!this.listener || this.ep?.rtcPort === null) throw fail(404, "uu Link's WebRTC is not running");
    try {
      return await this.listener.acceptRtcOffer(offer, sourceIp);
    } catch (err) {
      if (err?.kind === "invalid-argument") throw fail(400, err.message);
      if (err?.kind === "denied") throw fail(err.code === "rate-limited" ? 429 : 503, err.message);
      throw fail(503, err?.message ?? String(err));
    }
  }

  /** The router mapped the rtc port to `ip:port` (null: no mapping now). */
  setRtcMapped(addr) {
    if (addr === this.rtcMapped || !this.ep) return;
    const old = this.rtcMapped;
    this.rtcMapped = addr;
    if (old) this.ep.removeRtcExternalAddr(old);
    if (addr) this.ep.addRtcExternalAddr(addr);
    this.onChange();
  }

  /** The router mapped the UDP port to `ip:port` (null: no mapping now). */
  async setMapped(addr) {
    if (addr === this.mapped || !this.ep) return;
    const old = this.mapped;
    this.mapped = addr;
    if (old) await this.ep.removeExternalAddr(old).catch(() => {});
    if (addr) await this.ep.addExternalAddr(addr).catch((err) => this.log(`link: external address ${addr}: ${err.message}`));
  }

  /**
   * The `hello`'s `Bearer <token>`, bound to the client key on its first link session (docs/LINK.md「身份与信任」), or
   * `Pair <code>` (docs/LINK.md「配对」); in authority mode the host's decision on its credential.
   */
  async authenticate(r) {
    const source = r.sourceAddr ?? (r.sourceRelay ? `relay ${r.sourceRelay}` : null);
    if (this.authority) {
      const d = await this.authority.authorize(r.hello?.credential ?? "", r.hello?.device ?? {}, source);
      if (!d.ok) return { ok: false, code: d.code, message: d.message };
      return { ok: true, principal: d.principal };
    }
    const pair = /^Pair\s+(\S+)\s*$/i.exec(r.hello?.credential ?? "");
    if (pair) return this.pair(pair[1], r, source ?? "?");
    const m = /^Bearer\s+(\S+)\s*$/i.exec(r.hello?.credential ?? "");
    const a = this.remote.devices.authenticateLink(m?.[1], r.clientKey);
    if (a.kind === "unknown") return { ok: false, code: "unauthorized", message: "unknown device token" };
    if (a.kind === "other-key") {
      this.log(`link: ${a.device.name}'s token came with another link key; refused until it pairs again`);
      return { ok: false, code: "unauthorized", message: "this device token belongs to another installation; pair again" };
    }
    return { ok: true, principal: { device: { id: a.device.id, name: a.device.name } } };
  }

  /**
   * `Pair <code>`: the same code checks and device rules as on the Mac (DeviceStore.pair); the new token is bound to
   * this session's client key and handed back in `welcome.principal.token` (with `server: { id, name, platform }`).
   */
  pair(code, r, source) {
    const devices = this.remote.devices;
    const id = r.hello?.device?.id ?? "";
    try {
      const token = devices.pair(code, id, r.hello?.device?.name ?? "", r.clientKey);
      devices.authenticateLink(token, r.clientKey);
      const d = devices.list.find((x) => x.id === id);
      this.log(`link: paired ${d?.name ?? id} (from ${source})`);
      return { ok: true, principal: { device: { id, name: d?.name ?? id }, token, server: { id: this.remote.settings.serverId, name: this.remote.name, platform: this.svc.platform?.id ?? "linux" } } };
    } catch (err) {
      if (err?.kind === "full") return { ok: false, code: "busy", message: "too many paired devices; remove one first" };
      if (err?.kind === "bad-device") return { ok: false, code: "unauthorized", message: err.message };
      this.log(`link: a wrong or expired pairing code from ${source}`);
      return { ok: false, code: "unauthorized", message: "the pairing code is wrong or has expired; make a new one" };
    }
  }

  /** The paired device a session authenticated as, if it still is (authority mode: the host's principal.device). */
  device(session) {
    if (this.authority) return authorityDevice(session.principal?.device);
    const id = session.principal?.device?.id;
    return this.remote.devices.list.find((d) => d.id === id) ?? null;
  }

  opened(session) {
    const device = this.device(session);
    if (!device) {
      if (this.authority) void session.close(this.L.CloseCode.protocol, "no device in the principal");
      else void session.close(this.L.CloseCode.unauthorized, "the device is no longer paired");
      return;
    }
    const peer = new LinkPeer({ server: this, session, device });
    this.peers.add(peer);
    void peer.run().finally(() => this.peers.delete(peer));
  }

  /** Every session of a device no longer paired ends (`keep(device id)` says which stay). */
  disconnect(keep) {
    for (const p of this.peers) if (!keep(p.device.id)) void p.session.close(this.L.CloseCode.unauthorized, "the device was removed");
  }

  /** Control changed hands: every session hears it. */
  controlChanged() {
    for (const p of this.peers) p.sendControlState();
  }

  /**
   * One RPC stream through the routes, as a paired phone's. Authority mode: only AUTHORITY_RPC
   * (everything else is the host's to serve).
   */
  async rpc(session, req, body, res) {
    const device = this.device(session);
    if (!device) return res.json(401, { error: "unauthorized" });
    const path = req.path.split("?")[0];
    if (this.authority) {
      if (!AUTHORITY_RPC.has(`${req.method.toUpperCase()} ${path}`)) return res.json(404, { error: `no such endpoint ${path}` });
      const fake = rpcExchange(req, body, res);
      await this.svc.handle(fake.req, fake.res, LOCAL_CLIENT).catch((err) => this.svc.fail(fake.res, err));
      return void (await fake.done);
    }
    const { ACCOUNT_ROUTES, REMOTE_ROUTES } = await import("./remote.mjs");
    const route = `${req.method.toUpperCase()} ${path}`;
    if (ACCOUNT_ROUTES.has(route)) {
      let parsed = null;
      try {
        parsed = body?.length ? JSON.parse(Buffer.from(body).toString("utf8")) : {};
      } catch {
        return res.json(400, { error: "body must be JSON" });
      }
      const a = this.remote.accountRoute(route, parsed, device);
      return res.json(a.status, a.json);
    }
    if (!REMOTE_ROUTES.has(`${req.method.toUpperCase()} ${path}`)) return res.json(404, { error: `no such endpoint ${path}` });
    const fake = rpcExchange(req, body, res);
    await this.svc.handle(fake.req, fake.res, { kind: "remote", device }).catch((err) => this.svc.fail(fake.res, err));
    await fake.done;
  }
}

/** A device as the host names it (`principal.device`, a holder): `{ id, name }` (name: the id when absent), or null. */
export function authorityDevice(raw) {
  if (!raw || typeof raw !== "object" || typeof raw.id !== "string" || !raw.id) return null;
  return { id: raw.id, name: typeof raw.name === "string" && raw.name ? raw.name : raw.id };
}

/**
 * Authority mode of the link listener (docs/LOCAL-API.md「Link 的主人」, the Mac's LinkAuthority.swift): one local
 * program, the host, decides who may open a link session and who may send input; this server only asks and obeys.
 * The host's credentials and principals are opaque here.
 *
 * - The host holds `GET /link/authority` open (NDJSON, `attach(res)`; a second one is a 409). Lines to it:
 *   `{"type":"auth","id","credential","device","source"}` per `hello`, `{"type":"control","id","device","want"}` per
 *   `control.take` / `control.release`, `{"type":"session","event":"opened"|"closed","device"}`, `{"type":"activity",
 *   "device"}` (≤ 1/s per device while its input flows); a blank line every 15 s.
 * - `answer(body)`: `POST /link/authority/answer`; an `auth` unanswered for `timeoutMs` is denied `busy`.
 * - `setHolder(device | null)`: `POST /link/control`; input from anyone else is refused; every change is a "holder" event.
 * - No host: new sessions are denied `busy`; existing ones keep running; the host leaving sets the holder to null.
 */
export class LinkAuthority extends EventEmitter {
  constructor({ timeoutMs = AUTHORITY_ANSWER_MS, activityMs = AUTHORITY_ACTIVITY_MS, log = () => {}, now = Date.now } = {}) {
    super();
    this.timeoutMs = timeoutMs;
    this.activityMs = activityMs;
    this.log = log;
    this.now = now;
    this.host = null;
    this.pending = new Map();
    this.holder = null;
    this.lastActivity = new Map();
    this.seq = 0;
  }

  get hasHost() {
    return !!this.host;
  }

  /** The host's channel on `res` (an http.ServerResponse); false while another host is attached. */
  attach(req, res) {
    if (this.host) return false;
    res.writeHead(200, { "Content-Type": "application/x-ndjson", "Cache-Control": "no-cache", Connection: "close" });
    res.flushHeaders?.();
    const host = { res, ping: setInterval(() => res.write("\n"), AUTHORITY_PING_MS) };
    host.ping.unref?.();
    this.host = host;
    this.log("link: authority host connected");
    const gone = () => this.detach(host);
    req.on("close", gone);
    res.on("close", gone);
    return true;
  }

  /** The host went away: what it was asked is denied `busy`, nobody holds control. */
  detach(host = this.host) {
    if (!host || this.host !== host) return;
    this.host = null;
    clearInterval(host.ping);
    if (!host.res.writableEnded) host.res.end();
    this.log("link: authority host gone");
    const waiting = [...this.pending.values()];
    this.pending.clear();
    for (const p of waiting) {
      clearTimeout(p.timer);
      p.done({ ok: false, code: "busy", message: "the authority went away" });
    }
    this.setHolder(null);
  }

  send(line) {
    if (!this.host) return false;
    this.host.res.write(`${JSON.stringify(line)}\n`);
    return true;
  }

  nextId() {
    this.seq += 1;
    return `${Date.now().toString(36)}-${this.seq}`;
  }

  /** A `hello`: the host's decision `{ ok, principal } | { ok: false, code, message }` (no host or no answer: `busy`). */
  authorize(credential, device, source) {
    if (!this.host) return Promise.resolve({ ok: false, code: "busy", message: "no authority is connected" });
    const id = this.nextId();
    return new Promise((done) => {
      const timer = setTimeout(() => {
        if (!this.pending.delete(id)) return;
        done({ ok: false, code: "busy", message: `the authority did not answer in ${Math.round(this.timeoutMs / 1000)} s` });
      }, this.timeoutMs);
      timer.unref?.();
      this.pending.set(id, { timer, done });
      const d = device && typeof device === "object" ? { id: String(device.id ?? ""), name: String(device.name ?? "") } : { id: "", name: "" };
      this.send({ type: "auth", id, credential: String(credential ?? ""), device: d, source: source ?? null });
    });
  }

  /** `POST /link/authority/answer`'s body; throws an InputError (400 a bad body, 404 an unknown or late id). */
  answer(body) {
    if (!body || typeof body !== "object" || typeof body.id !== "string" || typeof body.ok !== "boolean") throw new InputError("body must be { id, ok, principal | code }");
    let decision;
    if (body.ok) {
      const device = authorityDevice(body.principal?.device);
      if (!device || typeof body.principal !== "object") throw new InputError("principal must be an object with device: { id, name }");
      decision = { ok: true, principal: { ...body.principal, device } };
    } else {
      const code = body.code ?? "unauthorized";
      if (!["unauthorized", "rate-limited", "busy"].includes(code)) throw new InputError("code must be unauthorized, rate-limited or busy");
      decision = { ok: false, code, message: typeof body.message === "string" ? body.message : "refused by the authority" };
    }
    const p = this.pending.get(body.id);
    if (!p) throw new InputError(`no pending request ${body.id}`, 404);
    this.pending.delete(body.id);
    clearTimeout(p.timer);
    p.done(decision);
  }

  /** A session asks for control (`want` take / release): the host decides by `setHolder`. */
  control(want, device) {
    this.send({ type: "control", id: this.nextId(), device, want });
  }

  session(event, device) {
    this.send({ type: "session", event, device });
  }

  /** Input from `device` went through (at most one line per `activityMs` per device). */
  activity(device) {
    const now = this.now();
    const last = this.lastActivity.get(device.id);
    if (last !== undefined && now - last < this.activityMs) return;
    if (this.lastActivity.size > 256) this.lastActivity.clear();
    this.lastActivity.set(device.id, now);
    this.send({ type: "activity", device });
  }

  /** `POST /link/control`'s holder (null: nobody); a "holder" event when it changed. */
  setHolder(device) {
    const h = device ? authorityDevice(device) : null;
    if (h?.id === this.holder?.id && h?.name === this.holder?.name) return;
    this.holder = h;
    this.log(`link: authority: control ${h ? `given to ${h.name}` : "released"}`);
    this.emit("holder", h);
  }

  /** Whether `device`'s input may go through now: null, or the refusal `{ status, code, message, controllerDevice? }`. */
  admitInput(device) {
    const h = this.holder;
    if (!h) return { status: 409, code: "no-control", message: "the authority gave control to nobody" };
    if (h.id !== device.id) return { status: 409, code: "controlled-elsewhere", message: `${h.name} controls the screen`, controllerDevice: { id: h.id, name: h.name } };
    return null;
  }
}

/**
 * An http.IncomingMessage / ServerResponse pair over one RPC stream, enough for the routes: the request's body, a head,
 * writes (with drain: at most 1 MiB in flight), end, close when the phone stops reading.
 */
export function rpcExchange(rq, body, responder) {
  const req = new EventEmitter();
  req.method = rq.method.toUpperCase();
  req.url = rq.path;
  req.headers = Object.fromEntries(Object.entries(rq.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]));
  req[Symbol.asyncIterator] = async function* () {
    if (body.length) yield body;
  };
  const res = new EventEmitter();
  let status = 200;
  let headers = {};
  let chain = Promise.resolve();
  let inFlight = 0;
  let closed = false;
  let finish;
  const done = new Promise((r) => (finish = r));
  const close = () => {
    if (closed) return;
    closed = true;
    res.destroyed = true;
    res.emit("close");
    req.emit("close");
    finish();
  };
  const head = () => {
    if (res.headersSent) return;
    res.headersSent = true;
    const h = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v)]));
    delete h.connection;
    delete h["content-length"];
    chain = chain.then(() => responder.head(status, h)).catch(close);
  };
  const push = (chunk) => {
    const b = typeof chunk === "string" ? Buffer.from(chunk) : Buffer.from(chunk);
    inFlight += b.length;
    chain = chain
      .then(() => (closed ? undefined : responder.write(b)))
      .then(() => {
        const was = inFlight;
        inFlight -= b.length;
        if (was > 1 << 20 && inFlight <= 1 << 20) res.emit("drain");
      })
      .catch(close);
    return inFlight <= 1 << 20;
  };
  Object.assign(res, {
    headersSent: false,
    writableEnded: false,
    destroyed: false,
    get statusCode() {
      return status;
    },
    writeHead(s, h = {}) {
      status = s;
      headers = { ...headers, ...h };
      return res;
    },
    setHeader(k, v) {
      headers[k] = v;
    },
    flushHeaders: head,
    write(chunk, cb) {
      head();
      const ok = closed ? false : push(chunk);
      if (typeof cb === "function") chain.then(() => cb(closed ? new Error("closed") : null));
      return ok;
    },
    end(chunk) {
      if (res.writableEnded) return res;
      res.writableEnded = true;
      head();
      if (chunk != null && chunk.length) push(chunk);
      chain = chain
        .then(() => (closed ? undefined : responder.finish()))
        .catch(() => {})
        .then(() => {
          if (!closed) res.emit("finish");
          close();
        });
      return res;
    },
    destroy() {
      // the stream is reset when the responder goes (never finished): the phone sees an error, not a cut-short body
      res.writableEnded = true;
      close();
    },
  });
  responder.stopped().then(close, close);
  return { req, res, done };
}
/** One phone's link session: its control messages, video and audio streams, input and media events. */
class LinkPeer {
  constructor({ server, session, device }) {
    this.server = server;
    this.svc = server.svc;
    this.session = session;
    this.device = device;
    this.label = `link ${device.name}`;
    this.videos = new Map();
    this.audios = new Map();
    this.encoderBps = null;
    this.report = null;
    /** Input events in the order they came (one at a time through the routes). */
    this.inputs = Promise.resolve();
    this.out = Promise.resolve();
    /** Authority mode: the `rid` of the last take / release, answered with the next holder change (or after 3 s). */
    this.pendingRid = undefined;
  }

  get authority() {
    return this.server.authority;
  }

  log(line) {
    this.server.log(`${this.label}: ${line}`);
  }

  /** Control messages go out in order; a failure means the session ended. */
  send(m) {
    this.out = this.out.then(() => this.session.sendControl(m)).catch(() => {});
  }

  async run() {
    const s = this.session;
    const path = s.path();
    this.log(`session opened (${path.kind}${path.remote ? ` ${path.remote}` : ""})`);
    const a = this.authority;
    const onHolder = (h) => this.controlChanged(h);
    if (a) {
      a.session("opened", this.device);
      a.on("holder", onHolder);
    }
    void this.events();
    try {
      for await (const m of s.controlMessages()) this.message(m);
    } catch {}
    if (a) {
      a.off("holder", onHolder);
      a.session("closed", this.device);
    }
    for (const v of this.videos.values()) v.close("the session ended");
    for (const a of this.audios.values()) a.close();
    const info = await s.closed().catch(() => null);
    this.log(`session closed${info ? `: ${info.description || info.reason || "closed"}` : ""}`);
  }

  message(m) {
    switch (m.t) {
      case "video.open":
        return this.openVideo(m);
      case "video.close":
        return this.videos.get(m.id)?.close("closed by the phone");
      case "keyframe":
        return this.videos.get(m.id)?.keyNeeded();
      case "audio.open":
        return void this.openAudio(m);
      case "audio.close":
        return this.audios.get(m.id)?.close();
      case "report": {
        const r = parsePlayoutReport(m.report ?? m);
        if (r) this.report = r;
        return;
      }
      case "control.take":
      case "control.release":
        return this.controlRequest(m.t === "control.take", m.rid);
      default:
      // unknown messages are ignored (newer phones)
    }
  }

  // ---- control of the screen ----

  controlMessage(rid) {
    const h = this.authority ? this.authority.holder : this.server.remote.control.holder;
    const m = { t: "control", granted: h?.id === this.device.id, holder: h ? { id: h.id, name: h.name } : null };
    if (rid !== undefined && rid !== null) m.rid = rid;
    return m;
  }

  sendControlState() {
    this.send(this.controlMessage());
  }

  /** Authority mode: the holder changed; the take / release waiting for an answer gets it. */
  controlChanged() {
    const rid = this.pendingRid;
    this.pendingRid = undefined;
    this.send(this.controlMessage(rid));
  }

  controlRequest(take, rid) {
    const a = this.authority;
    if (a) {
      // the host decides (POST /link/control); its next holder answers, or the holder as it is after 3 s
      const mine = rid ?? null;
      this.pendingRid = mine;
      a.control(take ? "take" : "release", this.device);
      setTimeout(() => {
        if (this.pendingRid !== mine) return;
        this.pendingRid = undefined;
        this.send(this.controlMessage(mine));
      }, a.timeoutMs).unref?.();
      return;
    }
    const device = this.server.device(this.session);
    if (!device) return this.send(this.controlMessage(rid));
    const c = this.server.remote.control;
    if (take) c.take(device);
    else c.release(device);
    this.send(this.controlMessage(rid));
  }

  // ---- media events and input ----

  async events() {
    try {
      for await (const e of this.session.serverEvents()) {
        switch (e.type) {
          case "targetBitrate":
            this.encoderBps = e.encoderBps;
            for (const v of this.videos.values()) v.setBitrate(e.encoderBps);
            break;
          case "recoveryNeeded":
            this.videos.get(e.stream)?.recoveryNeeded(e.lastDelivered ?? null);
            break;
          case "frameDelivered":
            this.videos.get(e.stream)?.delivered(e.frame);
            break;
          case "keyframeNeeded":
            this.videos.get(e.stream)?.keyNeeded();
            break;
          case "input":
            this.inputs = this.inputs.then(() => this.input(e.input));
            break;
          default:
        }
      }
    } catch {}
  }

  async input(ev) {
    let body;
    try {
      body = JSON.parse(Buffer.from(ev.json).toString("utf8"));
    } catch {
      return this.reject(ev.seq, 400, "bad-event", "the event is not JSON");
    }
    const a = this.authority;
    let client;
    if (a) {
      // the host decided who holds control; to the routes it is the token listener's input
      const refusal = a.admitInput(this.device);
      if (refusal) return this.reject(ev.seq, refusal.status, refusal.code, refusal.message, refusal.controllerDevice);
      client = LOCAL_CLIENT;
    } else {
      const device = this.server.device(this.session);
      if (!device) return this.reject(ev.seq, 401, "unauthorized", "the device is no longer paired");
      client = { kind: "remote", device };
    }
    try {
      await this.svc.applyInput(body, client);
      a?.activity(this.device);
    } catch (err) {
      if (!(err instanceof InputError)) {
        this.log(`input: ${err?.stack ?? err}`);
        return this.reject(ev.seq, 500, "error", err instanceof Error ? err.message : String(err));
      }
      this.reject(ev.seq, err.status, err.extra?.code ?? REJECT_CODES[err.status] ?? "error", err.message, err.extra?.controllerDevice);
    }
  }

  reject(seq, status, code, message, controller) {
    const m = { t: "input.rejected", seq, status, code, message };
    if (controller) m.controllerDevice = controller;
    this.send(m);
  }

  // ---- video ----

  openVideo(m) {
    const id = streamId(m.id);
    if (id === null) return this.send({ t: "video.error", id: m.id ?? null, status: 400, message: "id must be a stream number 1…255" });
    if (this.videos.has(id)) return this.send({ t: "video.error", id, status: 409, message: `video stream ${id} is open` });
    let o;
    try {
      o = this.svc.streamQuery(new URL(`/stream?${typeof m.query === "string" ? m.query.replace(/^\?/, "") : ""}`, "http://x"));
    } catch (err) {
      const status = err instanceof InputError ? err.status : 500;
      return this.send({ t: "video.error", id, status, message: err.message });
    }
    const v = new LinkVideo({ peer: this, id, o });
    this.videos.set(id, v);
    void v.run().finally(() => this.videos.delete(id));
  }

  // ---- audio ----

  async openAudio(m) {
    const id = streamId(m.id);
    if (id === null) return this.send({ t: "audio.error", id: m.id ?? null, status: 400, message: "id must be a stream number 1…255" });
    if (this.audios.has(id)) return this.send({ t: "audio.error", id, status: 409, message: `audio stream ${id} is open` });
    const a = { closed: false, q: null, close: () => {} };
    this.audios.set(id, a);
    let q;
    try {
      q = await this.svc.audio.subscribe();
    } catch (err) {
      this.audios.delete(id);
      return this.send({ t: "audio.error", id, status: err.status ?? 503, message: err.message });
    }
    a.close = () => {
      a.closed = true;
      q.close();
    };
    if (a.closed) q.close();
    const s = this.session;
    let reason = "the capture stopped";
    try {
      s.openAudio(id);
      this.send({ t: "audio.opened", id, codec: "opus", rate: AUDIO.rate, channels: AUDIO.channels, frames: AUDIO.frames, cookie: audioCookie().toString("base64"), videoOffsetMs: AUDIO.videoOffsetMs });
      while (!a.closed && !s.isClosed) {
        const items = await q.popAll(500);
        if (!items.length && q.closed) break;
        for (const it of items) s.sendAudio(id, Math.max(0, Math.round(it.packet.time * 1000)), it.packet.data);
      }
      if (a.closed) reason = "closed by the phone";
    } catch (err) {
      reason = err.message;
    } finally {
      this.svc.audio.unsubscribe(q);
      this.audios.delete(id);
      try {
        s.closeAudio(id);
      } catch {}
      this.send({ t: "audio.closed", id, reason });
    }
  }
}

/**
 * One video stream over the link (the TCP stream loop's rules, video.mjs): a picture only when the screen changed (or
 * a key frame is due), at most `fps`; refines and keepalives while it is still; the link's media layer says when the
 * queue takes another picture (`canSendFrame`), at which rate (`encoderBps`) and at most how many a second
 * (`frameRateCap`: fewer, sharper frames at a low rate). x264 budgets per frame at the `--fps` it was started with, so
 * under a lower cap it gets the rate scaled up by `fps / cap`: each of the fewer frames gets the bits. No picture is
 * much larger than its share of the rate (flow.mjs linkBufferKbit), so none is still on its way pictures later.
 *
 * A picture the phone lost: the next one references the newest picture the phone confirmed (`recoveryNeeded` says
 * which; the helper forgets everything after it), sent as a `recovery` frame — when the helper keeps earlier pictures
 * and still has that one; else a key frame. No key frames by the clock: the link delivers every picture or says which
 * it lost.
 */
export class LinkVideo {
  constructor({ peer, id, o }) {
    this.peer = peer;
    this.session = peer.session;
    this.id = id;
    this.o = o;
    this.closed = false;
    this.closeReason = null;
    this.needKey = true;
    this.recoveries = 0;
    this.keyRequests = 0;
    /** Recovery requests answered with a picture that references an earlier one (the rest got a key frame). */
    this.mended = 0;
    /** Sent pictures: the link's frame number → the helper's picture number (the newest NUMBERS_KEPT). */
    this.numbers = new Map();
    /** The newest frame the phone confirmed, the newest key frame sent, and the frame a recovery picture is due for. */
    this.confirmed = 0;
    this.keyFrame = 0;
    this.recoverBase = null;
    /** Key frames sent since the phone last confirmed a picture: each next one is given half the bytes (a path too slow for the first). */
    this.keysUnconfirmed = 0;
    this.helper = null;
    const base = peer.svc.tuning ?? TUNING;
    this.t = o.maxKbps != null ? limitedTuning(base, o.maxKbps, true) : base;
    this.kbps = peer.encoderBps ? this.clampKbps(peer.encoderBps / 1000) : this.t.startKbps;
  }

  clampKbps(k) {
    return Math.round(Math.min(this.t.maxKbps, Math.max(this.t.minKbps, k)));
  }

  setBitrate(bps) {
    this.kbps = this.clampKbps(bps / 1000);
  }

  /** The phone's decoder needs a key frame. */
  keyNeeded() {
    this.keyRequests++;
    this.needKey = true;
    this.helper?.wake();
  }

  /** The phone decoded `frame` (the newest so far). */
  delivered(frame) {
    if (frame > this.confirmed) this.confirmed = frame;
    if (frame >= this.keyFrame) this.keysUnconfirmed = 0;
  }

  /**
   * The phone lost a picture (`lastDelivered`: the newest it confirmed, as the link has it): the next picture
   * references that one, when the helper still can — it keeps earlier pictures, this one is among those sent since
   * the last key frame — else a key frame.
   */
  recoveryNeeded(lastDelivered) {
    this.recoveries++;
    const base = Math.max(lastDelivered ?? 0, this.confirmed);
    if (this.helper?.refs && base > 0 && base >= this.keyFrame && this.numbers.has(base)) this.recoverBase = base;
    else this.needKey = true;
    this.helper?.wake();
  }

  close(reason) {
    if (this.closed) return;
    this.closed = true;
    this.closeReason = reason;
    this.helper?.wake();
  }

  log(line) {
    this.peer.log(`video ${this.id} ${line}`);
  }

  async run() {
    const { peer, session: s, id, o } = this;
    const svc = peer.svc;
    const opened = svc.openHelper(o);
    const helper = opened.helper;
    this.helper = helper;
    if (this.closed) helper.wake();
    let reason = null;
    try {
      svc.setSize(await helper.ready);
      s.openVideo(id);
      const [width, height] = helper.size;
      peer.send({ t: "video.opened", id, codec: "h264", width, height, headers: { "X-Display": "1", "X-Stream-Codec": "h264", ...(o.id ? { "X-Stream-Id": o.id } : {}) } });
      if (o.status) peer.send({ t: "video.status", id, json: { display: 1, main: true, phase: "ready", since: Date.now(), console: { locked: false } } });
      this.log(`h264 @${o.fps} fps${o.cursor ? ", client cursor" : ""}`);
      await this.loop(opened);
      reason = this.closeReason ?? (s.isClosed ? "the session ended" : "the capture stopped");
    } catch (err) {
      if (!this.closed) {
        if (!helper.size) svc.lostDisplay(err.message);
        peer.send({ t: "video.error", id, status: 503, message: err.message });
      }
      reason = this.closeReason ?? err.message;
    } finally {
      opened.done();
      try {
        s.closeVideo(id);
      } catch {}
      peer.send({ t: "video.closed", id, reason });
      this.log(`closed: ${reason}`);
    }
  }

  async loop({ helper, feed }) {
    const s = this.session;
    const t = this.t;
    const clock = this.peer.server.clock;
    const size = helper.size;
    let fps = this.o.fps;
    let shown = false;
    let lastPictureAt = -Infinity;
    let lastPictureStart = -Infinity;
    let lastKeyAt = -Infinity;
    /** No key frame before this: the previous one is still on its way (keyTransit). */
    let keyHoldUntil = -Infinity;
    let lastRecoveryAt = -Infinity;
    const refine = new RefineSchedule(t);
    let seenToken = -1;
    let heldSince = null;
    let sentCursor = null;
    let lastCursorAt = -Infinity;
    const sentShapes = new Set();
    const win = { live: 0, refines: 0, keepalives: 0, keys: 0, drops: 0, held: 0, heldMs: 0, encodeMs: [], bytes: 0, largest: 0, start: clock() };

    const stats = (now) => {
      const seconds = now - win.start;
      if (seconds < STATS_EVERY) return;
      const pics = win.live + win.refines + win.keepalives;
      const mean = win.encodeMs.length ? win.encodeMs.reduce((a, b) => a + b, 0) / win.encodeMs.length : 0;
      let line = `stats: last ${seconds.toFixed(1)} s sent ${(pics / seconds).toFixed(1)} pics/s (live ${win.live} refine ${win.refines} keepalive ${win.keepalives} key ${win.keys} dropped ${win.drops}); encode ${mean.toFixed(1)}/${Math.max(0, ...win.encodeMs).toFixed(1)} ms (mean/max); held ${win.held} (${Math.round(win.heldMs)} ms); h264 ${size[0]}px ${this.kbps}kbps ${Math.round(win.bytes / seconds / 1024)}KB/s, largest ${Math.round(win.largest / 1024)} KB; fps cap ${fps}; link target ${(s.targetBitrate / 1e6).toFixed(1)} Mbps recoveries ${this.recoveries} (${this.mended} without a key frame) key requests ${this.keyRequests}`;
      if (this.peer.report) line += `; phone ${playoutLine(this.peer.report)}`;
      this.log(line);
      Object.assign(win, { live: 0, refines: 0, keepalives: 0, keys: 0, drops: 0, held: 0, heldMs: 0, encodeMs: [], bytes: 0, largest: 0, start: now });
    };

    while (!this.closed && !helper.exited && !s.isClosed) {
      helper.clearKick();
      const token = helper.changeToken;
      fps = Math.max(1, Math.min(this.o.fps, s.frameRateCap?.(this.id) ?? this.o.fps));
      const interval = 1 / fps;
      let now = clock();
      stats(now);
      let deadline = now + 0.25;
      // 1. the pointer (cursor=client): a datagram per change, coalesced; its shape once as a control message
      if (feed) {
        const { cursor: c, shape } = feed.current();
        const newShape = shape ? !sentShapes.has(shape.id) : false;
        if (c !== sentCursor || newShape) {
          if (now - lastCursorAt >= CURSOR_MIN_INTERVAL) {
            if (newShape) {
              if (sentShapes.size >= SENT_SHAPES_MAX) sentShapes.clear();
              sentShapes.add(shape.id);
              this.peer.send({ t: "cursor.shape", id: this.id, shapeId: shape.id, shape });
            }
            s.sendCursor(this.id, { x: c.x, y: c.y, visible: c.visible, shapeId: c.shapeId });
            sentCursor = c;
            lastCursorAt = now;
          } else deadline = Math.min(deadline, lastCursorAt + CURSOR_MIN_INTERVAL);
        }
      }
      // 2. pictures: a change (or a key frame due), else a refine, else a keepalive
      const changed = token !== seenToken;
      const keyAllowed = now >= keyHoldUntil;
      const wantKey = this.needKey && keyAllowed;
      // a recovery picture (a key frame that is due answers the request too)
      if (this.needKey) this.recoverBase = null;
      const recoveryAllowed = now - lastRecoveryAt >= RECOVERY_MIN_INTERVAL;
      const wantRecovery = this.recoverBase !== null && recoveryAllowed;
      let want = null;
      if (changed || wantKey || wantRecovery) want = "live";
      else if (refine.isDue(now)) want = "refine";
      else if (shown && now - lastPictureAt >= t.keepalive) want = "keepalive";
      if (this.needKey && !keyAllowed) deadline = Math.min(deadline, keyHoldUntil);
      if (this.recoverBase !== null && !recoveryAllowed) deadline = Math.min(deadline, lastRecoveryAt + RECOVERY_MIN_INTERVAL);

      if (want) {
        const gap = interval - (now - lastPictureStart);
        // (a recovery picture doesn't wait for the pace: the phone shows nothing until it comes)
        if (want === "live" && gap > 0 && !wantRecovery && !wantKey) {
          await helper.wait(helper.changeToken, Math.min(gap, Math.max(0.001, deadline - now)) * 1000);
          continue;
        }
        if (!s.canSendFrame(this.id)) {
          if (heldSince === null) {
            heldSince = now;
            win.held++;
          }
          await sleep(HELD_POLL_MS);
          continue;
        }
        if (heldSince !== null) {
          win.heldMs += (now - heldSince) * 1000;
          heldSince = null;
        }
        // a refine aims at the refine quality, at a temporarily higher rate: the link's queue is open (else we would
        // not be here), and the refines together stay within the rate its media layer set (flow.mjs refineKbps)
        // the link's rate over the frames the cap allows: x264 counts it per frame at `o.fps`
        const kbps = Math.round((this.kbps * this.o.fps) / fps);
        const rate = want === "refine" ? refineKbps(t, { kbps: this.kbps, ceiling: t.maxKbps, linkFps: this.o.fps }) : kbps;
        const start = clock();
        seenToken = helper.changeToken;
        // what one picture may take: a few pictures' shares of the real rate (not of the per-picture scaling). A key
        // frame takes the whole buffer where another picture takes half: it gets half the buffer. (A platform whose
        // encoders haven't been tried with that keeps a second of the real rate.)
        // A key frame after one the phone never confirmed: half of the last one's, down to an eighth — at the start
        // the rate is a guess, and on a path far below it the first key frame doesn't arrive in the phone's patience.
        const share = wantKey ? 2 << Math.min(this.keysUnconfirmed, 3) : 1;
        const buf = this.peer.svc.platform?.boundedPictures === true ? Math.ceil(linkBufferKbit(t, this.kbps, fps) / share) : want === "refine" || kbps === this.kbps ? null : this.kbps;
        // the picture the phone lost and everything after it are no references any more
        let base = null;
        if (!wantKey && wantRecovery) {
          base = this.recoverBase;
          helper.forget(this.numbers.get(base) + 1);
        }
        this.recoverBase = null;
        const r = await helper.encode(wantKey, rate, want === "refine" ? CRF.refine : CRF.live, buf);
        now = clock();
        if (r === null) break;
        if (r.type === "S") {
          win.drops++;
          lastPictureAt = now;
          lastPictureStart = now;
          // the recovery picture is still owed
          if (base !== null && this.recoverBase === null) this.recoverBase = base;
          // a skipped refine: one fewer left, and the picture is not settled yet
          if (want === "refine") refine.noteRefined(now, null, liveBudget(kbps, this.o.fps));
          continue;
        }
        win.encodeMs.push((now - start) * 1000);
        // (the helper answers with a key frame by itself when it keeps nothing as old as the base any more)
        const kind = r.key ? "key" : base !== null ? "recovery" : r.changed ? "delta" : want === "refine" ? "refine" : want === "keepalive" ? "keepalive" : "delta";
        let frame;
        try {
          frame = s.sendFrame(this.id, { codec: "h264", kind, width: size[0], height: size[1], captureUs: Math.round(r.time * 1000), ...(kind === "recovery" ? { recoveryBase: base } : {}) }, r.au);
        } catch (err) {
          if (s.isClosed) break;
          // not sent: the next picture can't reference it
          if (helper.refs && r.number !== null && !r.key) {
            this.log(`a picture was not sent (${err.message}); the next one skips it`);
            helper.forget(r.number);
            if (base !== null && this.recoverBase === null) this.recoverBase = base;
          } else {
            this.log(`a picture was not sent (${err.message}); a key frame next`);
            this.needKey = true;
          }
          continue;
        }
        if (r.number !== null) {
          this.numbers.set(frame, r.number);
          if (this.numbers.size > NUMBERS_KEPT) this.numbers.delete(this.numbers.keys().next().value);
        }
        if (kind === "recovery") {
          this.mended++;
          lastRecoveryAt = now;
        }
        win.bytes += r.au.length;
        win.largest = Math.max(win.largest, r.au.length);
        lastPictureAt = now;
        lastPictureStart = start;
        if (r.key) {
          this.needKey = false;
          this.keyFrame = frame;
          this.keysUnconfirmed++;
          lastKeyAt = now;
          keyHoldUntil = now + keyTransit(r.au.length, this.kbps);
          win.keys++;
        }
        if (r.changed) win.live++;
        else if (want === "refine") win.refines++;
        else if (want === "keepalive") win.keepalives++;
        else win.live++;
        if (r.changed || want === "live") {
          shown = true;
          refine.noteLive(now);
        } else if (want === "refine") refine.noteRefined(now, r.au.length, liveBudget(kbps, this.o.fps));
        continue;
      }
      now = clock();
      if (shown) deadline = Math.min(deadline, lastPictureAt + t.keepalive);
      if (refine.dueAt != null) deadline = Math.min(deadline, refine.dueAt);
      await helper.wait(token, Math.max(2, (deadline - now) * 1000));
    }
  }
}
