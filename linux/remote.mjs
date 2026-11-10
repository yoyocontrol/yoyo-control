// Remote access (`--remote <home>`, README.md「远程访问」): the phones Yoyo Control's iOS app pairs with reach this
// server the way they reach a Mac (docs/REMOTE.md) — over uu Link (link.mjs): pairing with a one-time code over the link
// itself, bearer tokens bound to the phone's link key, control, the router's port mapping of the link's UDP ports, the
// signaling server — built on @yoyocontrol/remote (its built JS is vendored in vendor/remote: nothing to install).
//
// - State in `<home>` (0700), this process the only writer: `remote.json` (`serverId`, `direct`, `linkPublicPort`,
//   `rtcPublicPort`), `devices.json`, `tls-key.der` (the identity key), `link-key`, and `admin.sock` (0600: the `pair` /
//   `devices` / `remove` / `disconnect` commands talk to the running server over it).
// - The link listener runs while a phone is paired or a pairing code is live (and 2 min after the last phone was
//   removed, so it hears `unauthorized` and forgets this server); with it the signaling registration and the mappings.
// - Remote clients get the Mac's remote routes (REMOTE_ROUTES) — what this server lacks answers 404 as on the token
//   listener — with control: `POST /control`, and `/input` only while holding it.
// - The link: UDP `linkPort` (default 47820); its WebRTC socket on `rtcPort` (default the link port + 1, `null` = none).
import { mkdirSync, chmodSync, readFileSync, rmSync } from "node:fs";
import { createServer, request } from "node:http";
import { isIP } from "node:net";
import { hostname } from "node:os";
import { createHash } from "node:crypto";
import v8 from "node:v8";
import { runInNewContext } from "node:vm";
import { join, resolve } from "node:path";
import { RemoteControl } from "./control.mjs";
import { DEFAULT_LINK_PORT, LinkServer, defaultRtcPort, loadLink } from "./link.mjs";
import { accountStatement, interfaceAddresses, loadOrCreateIdentity, overrideNetwork, validAccount, writePrivate } from "./vendor/remote/index.js";
import { PortMapping, nodeNetwork } from "./vendor/remote/portmap/index.js";
import { DeviceStore, pairingLink, randomToken } from "./vendor/remote/devices.js";
import { SignalClient } from "./vendor/remote/signal.js";

/** A full garbage collection now (V8's gc, exposed at run time): what lets a closed endpoint's sockets go. */
function collectGarbage() {
  try {
    v8.setFlagsFromString("--expose-gc");
    runInNewContext("gc")();
  } catch {}
}

/**
 * Where the admin socket listens: `<home>/admin.sock` (0600), or on Windows — no socket files there — a named pipe
 * named after the home (`\\.\pipe\yoyo-remote-<16 hex>`; a pipe's default ACL lets other users read but not write).
 */
export function adminPath(home, os = process.platform) {
  if (os !== "win32") return join(home, "admin.sock");
  return `\\\\.\\pipe\\yoyo-remote-${createHash("sha256").update(resolve(home).toLowerCase()).digest("hex").slice(0, 16)}`;
}

/** After the last device is removed the listener stays this long (a removed phone reconnecting hears `unauthorized`). */
export const LINGER_MS = 120_000;
/** `POST /remote/pairing` waits at most this long for the router's answer (the link then has the public address). */
const MAPPING_WAIT_MS = 6000;

/** The routes a paired phone may use (method, path); everything else is a 404 for it. */
export const REMOTE_ROUTES = new Set([
  "GET /status", "GET /frame", "GET /stream", "POST /stream/ack", "GET /events", "GET /focus", "GET /audio",
  "POST /input", "POST /control", "GET /clipboard", "POST /clipboard", "GET /clipboard/image", "GET /clipboard/file",
]);

/** The account routes a paired phone uses over its link (docs/ACCOUNT.md; `accountRoute`). */
export const ACCOUNT_ROUTES = new Set(["GET /account", "POST /account/join", "POST /account/invite"]);

/** `remote.json`: who this server is, the direct switch, the public ports the router gave last, the account it joined. */
export function loadSettings(path) {
  let j = {};
  try {
    j = JSON.parse(readFileSync(path, "utf8"));
  } catch {}
  const port = (p) => (Number.isInteger(p) && p > 0 && p < 65536 ? p : undefined);
  return {
    serverId: typeof j.serverId === "string" && j.serverId.length >= 16 ? j.serverId : randomToken(16),
    direct: typeof j.direct === "boolean" ? j.direct : true,
    linkPublicPort: port(j.linkPublicPort),
    rtcPublicPort: port(j.rtcPublicPort),
    account: validAccount(j.account?.id) ? { id: j.account.id, since: typeof j.account.since === "number" ? j.account.since : Date.now() } : null,
  };
}

export function saveSettings(path, s) {
  writePrivate(path, `${JSON.stringify({ version: 2, serverId: s.serverId, direct: s.direct, ...(s.linkPublicPort ? { linkPublicPort: s.linkPublicPort } : {}), ...(s.rtcPublicPort ? { rtcPublicPort: s.rtcPublicPort } : {}), ...(s.account ? { account: s.account } : {}) }, null, 2)}\n`);
}

export class RemoteAccess {
  /**
   * `svc`: the YoyoLinux service. `home`: the state directory. Options: `direct` (overrides remote.json when given),
   * `name` (the computer's name in the pairing link and `welcome`), `advertise` (`ip[:port]` hosts instead of the
   * interfaces': the pairing link's addresses and the link's external addresses), `portMap` (the mappings' overrides:
   * `internalClient`, `internalPort`, `externalPort`, `gateway`, `upnpLocation`), `exempt` (addresses never cooled
   * down), `signalUrl`, `WebSocket` (tests; `signalUrl: null`: no signaling server), the link's `linkPort`,
   * `linkRelays`, `rtcPort`, `stun`.
   */
  constructor({ svc, home, direct, name, advertise, portMap, exempt, signalUrl, WebSocket, linkPort = DEFAULT_LINK_PORT, linkRelays = [], rtcPort = defaultRtcPort(linkPort), stun = [], log = () => {}, lingerMs = LINGER_MS }) {
    this.svc = svc;
    this.home = home;
    this.log = log;
    this.lingerMs = lingerMs;
    mkdirSync(home, { recursive: true, mode: 0o700 });
    try {
      chmodSync(home, 0o700);
    } catch {}
    this.settingsPath = join(home, "remote.json");
    this.settings = loadSettings(this.settingsPath);
    if (direct !== undefined) this.settings.direct = direct;
    saveSettings(this.settingsPath, this.settings);
    this.name = name || hostname() || "Linux";
    this.advertise = advertise?.length ? advertise : undefined;
    this.portMapOptions = portMap ?? {};
    this.exempt = new Set(exempt ?? []);
    // none built in: no URL (`--signal`, `YOYO_SIGNAL_URL`) = no signaling server
    this.signalUrl = signalUrl ?? null;
    this.WebSocket = WebSocket;
    this.identity = null;
    this.devices = new DeviceStore(join(home, "devices.json"), { log, onChange: () => this.devicesChanged() });
    this.deviceCount = this.devices.list.length;
    this.control = new RemoteControl({
      log,
      onChange: (control, previous) => {
        if (previous) svc.input?.release();
        svc.publish({ type: "control", control });
        this.link?.controlChanged();
      },
    });
    this.signal = null;
    this.linkPort = linkPort;
    /** The link's iroh relays (link.mjs `relays`; server.mjs's default is Yoyo Control's). */
    this.linkRelays = linkRelays;
    this.rtcPort = rtcPort;
    this.stun = stun;
    /** The link listener (null: not listening, or no addon). */
    this.link = null;
    this.linkMapper = null;
    this.linkMapping = null;
    this.rtcMapper = null;
    this.admin = null;
    this.lingerUntil = 0;
    this.timers = new Set();
    this.updating = Promise.resolve();
    this.running = false;
  }

  /** The identity, the admin socket, and the listener if a phone is paired. */
  async start() {
    this.running = true;
    this.identity = loadOrCreateIdentity(this.home);
    await this.startAdmin();
    await this.update();
  }

  async stop() {
    this.running = false;
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    this.control.stop();
    this.admin?.close();
    this.admin = null;
    if (process.platform !== "win32") rmSync(adminPath(this.home), { force: true });
    await this.stopLink();
  }

  get listening() {
    return this.link !== null;
  }

  needsListener() {
    return !this.devices.isEmpty || this.devices.pairingCode !== null || Date.now() < this.lingerUntil;
  }

  /** Starts or stops the link (and with it the signaling registration and the mappings) to match. One at a time. */
  update() {
    this.updating = this.updating.then(() => this.apply()).catch((err) => this.log(`remote: ${err?.stack ?? err}`));
    return this.updating;
  }

  async apply() {
    const should = this.running && this.needsListener();
    if (should && !this.link) await this.startLink();
    else if (!should && this.link) {
      await this.stopLink();
      this.log("remote: listener stopped");
    }
  }

  /** The link listener, the signaling registration and the router's mappings of its UDP ports; a missing addon is one log line. */
  async startLink() {
    const { L, error } = await loadLink();
    if (!L) {
      this.log(`remote: off: no uu Link (native addon: ${error})`);
      return;
    }
    let link;
    for (let attempt = 0; ; attempt++) {
      link = new LinkServer({ L, svc: this.svc, remote: this, port: this.linkPort, relays: this.linkRelays, rtcPort: this.rtcPort, stun: this.stun, advertise: this.advertise ?? [], exempt: [...this.exempt].filter((a) => isIP(a)), log: this.log });
      try {
        await link.start(this.identity);
        break;
      } catch (err) {
        await link.stop();
        // a stopped endpoint's UDP sockets are let go when its native objects are collected, not on close(): on
        // Windows (no address reuse) the next start can't bind the port until then — collect, and try again
        if (attempt < 3 && /bind/i.test(err.message)) {
          collectGarbage();
          await new Promise((r) => setTimeout(r, 300));
          continue;
        }
        this.log(`link: cannot listen on udp ${this.linkPort}: ${err.message}`);
        return;
      }
    }
    this.link = link;
    if (this.signalUrl !== null) {
      this.signal = new SignalClient({ identity: this.identity, url: this.signalUrl, log: this.log, WebSocket: this.WebSocket });
      this.signal.setLink(link.json());
      this.signal.setAccount(this.settings.account?.id ?? null);
      this.signal.on("unlinked", () => this.setAccount(null, "no longer in the account (removed from its directory)"));
      this.signal.start();
    }
    link.onChange = () => this.signal?.setLink(link.json());
    if (this.settings.direct && process.env.YOYO_PORTMAP !== "off") this.startMapping(link);
  }

  startMapping(link) {
    const o = this.portMapOptions;
    const base = nodeNetwork();
    const network = o.internalClient || o.gateway || o.upnpLocation ? overrideNetwork(base, o) : base;
    this.linkMapper = new PortMapping({
      internalPort: o.internalPort ?? this.linkPort,
      protocol: "udp",
      externalPort: this.settings.linkPublicPort ?? o.externalPort,
      description: "Yoyo Control Link",
      network,
      log: this.log,
      onChange: (st) => {
        this.linkMapping = st;
        if (st.status === "mapped") {
          if (this.settings.linkPublicPort !== st.externalPort) {
            this.settings.linkPublicPort = st.externalPort;
            saveSettings(this.settingsPath, this.settings);
          }
          void link.setMapped(`${st.externalAddress}:${st.externalPort}`);
        } else if (st.status !== "probing" && st.status !== "idle") void link.setMapped(null);
      },
    });
    void this.linkMapper.start().catch((err) => this.log(`link: port mapping: ${err.message}`));
    const rtcPort = link.ep?.rtcPort ?? null;
    if (rtcPort === null) return;
    this.rtcMapper = new PortMapping({
      internalPort: rtcPort,
      protocol: "udp",
      externalPort: this.settings.rtcPublicPort ?? rtcPort,
      description: "Yoyo Control Link rtc",
      network,
      log: this.log,
      onChange: (st) => {
        if (st.status === "mapped") {
          if (this.settings.rtcPublicPort !== st.externalPort) {
            this.settings.rtcPublicPort = st.externalPort;
            saveSettings(this.settingsPath, this.settings);
          }
          link.setRtcMapped(`${st.externalAddress}:${st.externalPort}`);
        } else if (st.status !== "probing" && st.status !== "idle") link.setRtcMapped(null);
      },
    });
    void this.rtcMapper.start().catch((err) => this.log(`link: rtc port mapping: ${err.message}`));
  }

  async stopLink() {
    const link = this.link;
    const mappers = [this.linkMapper, this.rtcMapper];
    this.link = null;
    this.linkMapper = null;
    this.rtcMapper = null;
    this.linkMapping = null;
    this.signal?.stop();
    this.signal = null;
    const stops = mappers.map((m) => Promise.resolve(m?.stop()).catch(() => {}));
    await Promise.race([Promise.all(stops), new Promise((r) => setTimeout(r, 2000).unref?.())]);
    await link?.stop();
  }

  /** `GET /remote`'s `link`: the endpoint and the UDP mapping (null: not running). */
  linkJson() {
    const j = this.link?.json();
    if (!j) return null;
    const m = this.linkMapping;
    const mapping = !m ? { status: "off" } : m.status === "mapped" ? { status: "mapped", address: m.externalAddress, port: m.externalPort, method: m.method } : { status: m.status };
    return { id: j.id, port: j.port, direct: j.direct, sessions: this.link.peers.size, mapping };
  }

  devicesChanged() {
    const ids = new Set(this.devices.list.map((d) => d.id));
    if (ids.size === 0 && this.deviceCount > 0 && this.link) {
      this.lingerUntil = Date.now() + this.lingerMs;
      this.later(this.lingerMs + 500, () => this.update());
    }
    this.deviceCount = ids.size;
    this.link?.disconnect((id) => ids.has(id));
    if (this.control.holder && !ids.has(this.control.holder.id)) this.control.deviceRemoved(this.control.holder.id);
    // a code that runs out without a phone pairing: the listener may go when it does
    const code = this.devices.pairingCode;
    if (code) this.later(code.expiresAt - Date.now() + 500, () => this.update());
    void this.update();
  }

  later(ms, fn) {
    const t = setTimeout(() => {
      this.timers.delete(t);
      fn();
    }, Math.max(0, ms));
    t.unref?.();
    this.timers.add(t);
  }

  // ---- management (GET /remote and friends: the admin socket) ----

  /** The local addresses in the pairing link: the advertised hosts, else the interfaces'. */
  addresses() {
    return this.advertise ? this.advertise.map((a) => a.replace(/:\d+$/, "")) : interfaceAddresses();
  }

  json() {
    const active = new Set([...(this.link?.peers ?? [])].map((p) => p.device.id));
    const code = this.devices.pairingCode;
    const url = code ? this.pairingUrl(code.code) : null;
    return {
      enabled: true,
      listening: this.listening,
      serverId: this.settings.serverId,
      name: this.name,
      addresses: this.addresses(),
      ...(this.identity ? { fingerprint: this.identity.keyFingerprint } : {}),
      devices: this.devices.list.map((x) => ({ ...x, connected: active.has(x.id) })),
      pairing: code ? { code: code.code, expiresAt: code.expiresAt, ...(url ? { url } : {}) } : null,
      control: this.control.json,
      signal: { connected: this.signal?.registered ?? false },
      direct: this.directJson(),
      link: this.linkJson(),
      account: this.settings.account,
    };
  }

  // ---- the account (docs/ACCOUNT.md) ----

  setAccount(account, why) {
    const id = account?.id ?? null;
    if ((this.settings.account?.id ?? null) === id) return;
    this.settings.account = account;
    saveSettings(this.settingsPath, this.settings);
    this.signal?.setAccount(id);
    this.log(`remote: ${why}`);
  }

  /** A paired phone's account route over its link: `{ status, json }`. */
  accountRoute(route, body, device) {
    switch (route) {
      case "GET /account":
        return { status: 200, json: { account: this.settings.account } };
      case "POST /account/join": {
        if (!validAccount(body?.account)) return { status: 400, json: { error: "account must be 32 lowercase hex digits" } };
        if (!this.identity) return { status: 503, json: { error: "no identity" } };
        if (this.settings.account?.id !== body.account) this.setAccount({ id: body.account, since: Date.now() }, `${device.name} put this computer in its account`);
        return { status: 200, json: accountStatement(this.identity, body.account, { serverId: this.settings.serverId, name: this.name, platform: this.svc.platform?.id ?? "linux" }) };
      }
      case "POST /account/invite": {
        if (typeof body?.id !== "string" || typeof body?.linkKey !== "string") return { status: 400, json: { error: "id and linkKey are required" } };
        try {
          const c = this.devices.invite(body.id, body.linkKey);
          this.log(`remote: ${device.name} let ${typeof body.name === "string" ? body.name.slice(0, 64) : body.id} in (a code for it alone)`);
          return { status: 200, json: { code: c.code, expiresAt: c.expiresAt } };
        } catch (err) {
          return { status: err?.kind === "full" ? 429 : 400, json: { error: err.message } };
        }
      }
      default:
        return { status: 404, json: { error: "not found" } };
    }
  }

  /** The pairing link (v=2, the link's binding in it); null until the link listens. */
  pairingUrl(code) {
    const j = this.link?.json();
    if (!j || !this.identity) return null;
    return pairingLink({ serverId: this.settings.serverId, name: this.name, fingerprint: this.identity.keyFingerprint, code, link: { id: j.id, key: j.key, sig: j.sig, port: j.port }, addresses: this.addresses() });
  }

  directJson() {
    const j = { enabled: this.settings.direct };
    const s = this.linkMapping;
    if (!this.settings.direct || process.env.YOYO_PORTMAP === "off" || !this.link || !s) return { ...j, status: "off" };
    switch (s.status) {
      case "idle":
      case "probing":
        return { ...j, status: "probing" };
      case "mapped":
        return { ...j, status: "mapped", address: s.externalAddress, port: s.externalPort, method: s.method };
      case "unreachable":
        return { ...j, status: "unreachable", method: s.method, address: s.externalAddress, reason: s.reason };
      case "unsupported":
        return { ...j, status: "unsupported" };
      default:
        return { ...j, status: "failed", ...(s.method ? { method: s.method } : {}), error: s.error };
    }
  }

  /** A new pairing code; the listener started for it, and the router asked (≤ 6 s) so the link has the public address. */
  async startPairing() {
    this.devices.startPairing();
    await this.update();
    const t0 = Date.now();
    const maps = this.settings.direct && process.env.YOYO_PORTMAP !== "off";
    while (maps && this.link && (!this.linkMapping || ["idle", "probing"].includes(this.linkMapping.status)) && Date.now() - t0 < MAPPING_WAIT_MS) {
      await new Promise((r) => setTimeout(r, 100));
    }
    return this.json();
  }

  async setDirect(on) {
    if (this.settings.direct === on) return this.json();
    this.settings.direct = on;
    saveSettings(this.settingsPath, this.settings);
    // the mappings follow the link: start it again
    await this.stopLink();
    await this.update();
    return this.json();
  }

  async startAdmin() {
    const path = adminPath(this.home);
    if (process.platform !== "win32") rmSync(path, { force: true });
    const server = createServer((req, res) => {
      this.adminRoute(req, res).catch((err) => sendJson(res, err.status ?? 500, { error: err.message }));
    });
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(path, () => {
        server.off("error", reject);
        resolve();
      });
    });
    if (process.platform !== "win32") chmodSync(path, 0o600);
    this.admin = server;
  }

  async adminRoute(req, res) {
    const route = `${req.method} ${new URL(req.url ?? "/", "http://x").pathname}`;
    const body = req.method === "POST" ? parseJson(await readAll(req, 64 * 1024)) : null;
    switch (route) {
      case "GET /remote":
        return sendJson(res, 200, this.json());
      case "POST /remote/pairing":
        return sendJson(res, 200, await this.startPairing());
      case "POST /remote/pairing/stop":
        this.devices.stopPairing();
        return sendJson(res, 200, this.json());
      case "POST /remote/direct":
        if (typeof body?.enabled !== "boolean") return sendJson(res, 400, { error: "body must be { enabled: boolean }" });
        return sendJson(res, 200, await this.setDirect(body.enabled));
      case "POST /remote/devices/remove":
        if (typeof body?.id !== "string") return sendJson(res, 400, { error: "body must be { id }" });
        if (!this.devices.remove(body.id)) return sendJson(res, 404, { error: "no such device" });
        this.log(`remote: removed device ${body.id}`);
        return sendJson(res, 200, this.json());
      case "POST /remote/account/leave":
        this.setAccount(null, "left the account");
        return sendJson(res, 200, this.json());
      case "POST /remote/disconnect":
        this.control.releaseAny("control taken back on this computer");
        return sendJson(res, 200, this.json());
      default:
        return sendJson(res, 404, { error: "not found" });
    }
  }
}

function parseJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function readAll(req, max) {
  const chunks = [];
  let n = 0;
  for await (const c of req) {
    n += c.length;
    if (n > max) throw Object.assign(new Error(`body is too large (max ${max} bytes)`), { status: 413 });
    chunks.push(c);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function sendJson(res, status, body, headers = {}) {
  const b = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": b.length, "Cache-Control": "no-store", ...headers });
  res.end(b);
}

/** The admin socket's client (the `pair` / `devices` / `remove` / `disconnect` commands). */
export function adminCall(home, method, path, body) {
  return new Promise((resolve, reject) => {
    const b = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    const req = request({ socketPath: adminPath(home), method, path, headers: b ? { "Content-Type": "application/json", "Content-Length": b.length } : {} }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString();
        resolve({ status: res.statusCode, json: parseJson(text) });
      });
    });
    req.on("error", (err) => reject(err.code === "ENOENT" || err.code === "ECONNREFUSED" ? new Error(`no server running with --remote ${home} (${err.code})`) : err));
    req.end(b);
  });
}
