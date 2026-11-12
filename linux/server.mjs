#!/usr/bin/env node
// yoyo-linux: Yoyo Control's Linux server, headless — a Linux X display served over the Yoyo Control HTTP API
// (README.md), so a Yoyo Control client, or a program on another machine relaying one, can see and drive it: /status,
// /stream (H.264), /stream/ack, /input, /frame, /events, /audio, /clipboard*, /windows, /hit, /automation. Plain HTTP/1.1 on one TCP address; every
// request needs `Authorization: Bearer <token>`. With `--remote <home>` also the phones of Yoyo Control's iOS app, as
// with a Mac: over uu Link — pairing, control, the router's port mapping, the signaling server (remote.mjs, link.mjs,
// README.md「远程访问」). Focus and the /app/* routes are not here: those answer 404 (README.md「HTTP API」).
//
//   DISPLAY=:0 XAUTHORITY=… node server.mjs --host <address | iface:eth0> --port 7380 [--name <display name>] < token
//   DISPLAY=:0 XAUTHORITY=… node server.mjs --host … --port … --token-file <path>
//   DISPLAY=:0 node server.mjs --remote <home> [--advertise ip[:port],…] [--direct on|off]
//                              [--link-port 47820]   # uu Link (UDP, link.mjs): remote access's door
//                              [--link-rtc-port 47821|off] [--link-stun host:port,…]   # its WebRTC socket (POST /link/rtc)
//   DISPLAY=:0 node server.mjs --host … --port … --link on --link-home <dir> [--link-port 47820] [--advertise ip[:port],…]
//                              [--link-bind ip,…] < token
//                              # uu Link without remote access: the token's holder is its authority (/link/*, link.mjs)
//   node server.mjs pair --remote <home>        # a pairing link (and a QR code with qrencode); also devices, remove <id>, disconnect, account [leave]
//
// The token is the first line of stdin, or of the file `--token-file` names (never argv or the environment: both are
// readable by other processes of the machine). Env: YOYO_VIDEO_MAX_KBPS (bit-rate ceiling), YOYO_LINUX_MAX_FPS (default 30), YOYO_X11VIDEO (the video
// helper, default ./yoyo-x11video beside this file), YOYO_PA_OPUS (the sound helper, ./yoyo-pa-opus), YOYO_X11CLIP
// (the clipboard helper, ./yoyo-x11clip), YOYO_X11WINDOWS (the windows helper, ./yoyo-x11windows), YOYO_AUDIO (off: no
// sound), YOYO_XDOTOOL (default xdotool), YOYO_FFMPEG (default ffmpeg).
import { spawn } from "node:child_process";
import { timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { availableParallelism, networkInterfaces } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { besideServer, hostPlatform, maxFpsFor } from "./platform.mjs";
import { AUDIO, AudioCapture, audioCookie, audioPart } from "./audio.mjs";
import { Automation, parseAutomation } from "./automation.mjs";
import { Clipboard, sendClipboardFile } from "./clipboard.mjs";
import { CursorFeed, CursorShapes } from "./cursor.mjs";
import { TUNING, limitedTuning, parsePlayoutReport } from "./flow.mjs";
import { InputDriver, InputError, parseInput, positionAfter } from "./input.mjs";
import { VideoHelper, flows, streamLoop } from "./video.mjs";
import { authorityDevice } from "./link.mjs";
import { negotiate } from "./wire.mjs";
import { drawboxes, hitAnswer, maskBoxes, parseCrop, parseHide, parseVisible, pixelRect, readWindows, unitParameter, windowCatalog, windowsAnswer } from "./windows.mjs";

/** `/status.app` of this process: "yoyo-linux", or "yoyo-windows" on Windows (platform.mjs). */
export const APP = hostPlatform().app;
export const VERSION = "0.11.0";
/** The Yoyo Control HTTP API version this speaks (`/status` `api`; +1 only on an incompatible change). */
export const API = 1;
/** The one display's id (`/status` displays, `/stream`, `/input`). */
export const DISPLAY_ID = 1;
/** The token listener's clients (no identity: not a controller, control.mjs). */
export const LOCAL = Object.freeze({ kind: "local" });
const STREAM_ID = /^[A-Za-z0-9_-]{8,64}$/;
const MAX_STREAMS = 4;
/** /frame captures at a time (an ffmpeg each), and how many more may wait. */
const FRAME_SLOTS = 2;
const FRAME_QUEUE = 4;

const log = (line) => process.stderr.write(`${new Date().toISOString()} ${line}\n`);

function arg(argv, name) {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}

/** `iface:<name>` → that interface's first IPv4 address; anything else as it is. */
export function resolveHost(host, ifaces = networkInterfaces()) {
  if (!host?.startsWith("iface:")) return host;
  const a = (ifaces[host.slice(6)] ?? []).find((x) => x.family === "IPv4" || x.family === 4);
  if (!a) throw new Error(`no IPv4 address on ${host.slice(6)}`);
  return a.address;
}

// kept alive (an answer of known length): a phone's 30 moves a second through a relaying program reuse one connection
// instead of each paying for a new one (measured: most of the server's CPU while the pointer moved)
const json = (res, status, body, headers = {}) => {
  const b = Buffer.from(JSON.stringify(body));
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": b.length, "Cache-Control": "no-store", ...headers });
  res.end(b);
};

/** The response can take more (drain) or is gone (close); neither listener is left behind. */
export function drained(res) {
  return new Promise((resolve) => {
    const done = () => {
      res.off("drain", done);
      res.off("close", done);
      resolve();
    };
    res.on("drain", done);
    res.on("close", done);
  });
}

async function readBody(req, max) {
  const chunks = [];
  let n = 0;
  for await (const c of req) {
    n += c.length;
    if (n > max) throw new InputError(`body is too large (max ${max} bytes)`, 413);
    chunks.push(c);
  }
  const text = Buffer.concat(chunks).toString("utf8");
  try {
    return JSON.parse(text);
  } catch {
    throw new InputError("body must be JSON");
  }
}

/**
 * The service: `token`, the paths of the tools, and hooks for tests. `listen()` starts it; `close()` stops it and every
 * stream. Exported for the tests (the server's own entry is at the bottom).
 */
export class YoyoLinux {
  constructor({ token, platform = hostPlatform(), name = platform.name, env = process.env, videoHelper, audioHelper, clipboardHelper, windowsHelper, xdotool, ffmpeg, maxKbps, maxFps, logLine = log, spawnFn = spawn, audioLingerMs }) {
    // null: no token listener (remote access only)
    if (token !== null && (typeof token !== "string" || token.length < 16)) throw new Error("a token of at least 16 characters is needed");
    this.token = token === null ? null : Buffer.from(token);
    /** Linux or Windows (platform.mjs): the helpers' names, `/status.app` / `platform`, how /frame is taken. */
    this.platform = platform;
    this.name = name;
    this.env = env;
    this.videoHelper = videoHelper ?? besideServer(platform.helpers.video);
    this.xdotool = xdotool ?? (platform.input === "xdotool" ? "xdotool" : besideServer(platform.input));
    this.ffmpeg = ffmpeg ?? "ffmpeg";
    this.tuning = maxKbps ? limitedTuning(TUNING, Math.min(Math.max(maxKbps, 100), 100_000)) : TUNING;
    this.maxFps = Math.min(Math.max(maxFps || maxFpsFor(platform, availableParallelism()) || 30, 1), TUNING.maxFPS);
    this.log = logLine;
    this.spawn = spawnFn;
    this.size = null;
    this.sizeAt = 0;
    this.sizeError = null;
    this.sizing = null;
    /** /frame captures running, and the ones waiting for a turn (FRAME_SLOTS at a time). */
    this.frames = { running: 0, waiting: [] };
    this.since = Date.now();
    this.streams = new Set();
    /** The pointers of the open `cursor=client` streams (`/input` tells them where it left it). */
    this.pointerFeeds = new Set();
    this.cursorShapes = new CursorShapes({ log: this.log });
    this.events = new Set();
    this.audio = new AudioCapture({ path: audioHelper ?? besideServer(platform.helpers.audio), env, log: this.log, spawnFn: this.spawn, ...(audioLingerMs != null ? { lingerMs: audioLingerMs } : {}) });
    this.clipboard = new Clipboard({
      path: clipboardHelper ?? besideServer(platform.helpers.clipboard),
      env,
      log: this.log,
      spawnFn: this.spawn,
      onChange: (summary) => this.publish({ type: "clipboard", ...summary }),
    });
    this.windowsHelper = windowsHelper ?? besideServer(platform.helpers.windows);
    /** The windows helper could be started the last time it was (`features.windows`). */
    this.windowsOk = true;
    this.automation = new Automation({ path: this.windowsHelper, env, spawnFn: this.spawn, log: this.log, onAbort: () => this.publish({ type: "abort", reason: "esc" }) });
    this.xdo = { pointer: null, keys: null };
    this.input = null;
    /** Remote access (remote.mjs) when started with `--remote`: control, the paired phones' routes. */
    this.remote = null;
    /** The headless link listener (`--link on --link-home`, no `--remote`: authority mode, link.mjs) and its authority. */
    this.link = null;
    this.linkAuthority = null;
    this.server = createServer((req, res) => {
      if (!this.authorized(req)) return json(res, 401, { error: "unauthorized" });
      this.handle(req, res, LOCAL).catch((err) => this.fail(res, err));
    });
    this.server.keepAliveTimeout = 5000;
  }

  listen(port, host) {
    this.clipboard.start();
    return new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(port, host, () => resolve(this.server.address()));
    });
  }

  close() {
    void this.remote?.stop();
    void this.link?.stop();
    this.linkAuthority?.detach();
    for (const s of this.streams) s.stop();
    for (const e of this.events) e.end();
    this.audio.close();
    this.clipboard.stop();
    this.automation.stop();
    this.input?.stop();
    for (const p of Object.values(this.xdo)) p?.kill();
    this.server.close();
    this.server.closeAllConnections?.();
  }

  authorized(req) {
    if (!this.token) return false;
    const m = /^Bearer\s+(\S+)\s*$/i.exec(req.headers.authorization ?? "");
    if (!m) return false;
    const got = Buffer.from(m[1]);
    return got.length === this.token.length && timingSafeEqual(got, this.token);
  }

  fail(res, err) {
    if (res.headersSent) {
      res.destroy();
      return;
    }
    if (err instanceof InputError) return json(res, err.status, { error: err.message, ...(err.extra ?? {}) });
    this.log(`error: ${err?.stack ?? err}`);
    json(res, 500, { error: err instanceof Error ? err.message : String(err) });
  }

  /**
   * The screen's size from a video helper's hello: the one known when it is younger than `maxAgeMs`, else asked again
   * (a short-lived helper). Failing to open the display forgets it: /status then says `ok: false`.
   */
  async screenSize(maxAgeMs = Infinity) {
    if (this.size && Date.now() - this.sizeAt < maxAgeMs) return this.size;
    if (!this.sizing) {
      this.sizing = (async () => {
        const h = new VideoHelper({ path: this.videoHelper, fps: 1, env: this.env, log: this.log, spawnFn: this.spawn });
        try {
          this.setSize(await Promise.race([h.ready, new Promise((_, rej) => setTimeout(() => rej(new Error("the video helper did not answer in 5 s")), 5000))]));
        } catch (err) {
          this.lostDisplay(err.message);
          throw err;
        } finally {
          h.stop();
          this.sizing = null;
        }
        return this.size;
      })();
    }
    return this.sizing;
  }

  /** A helper's hello: the screen's size now (input maps onto it at once when it changed). */
  setSize(size) {
    if (!this.size || this.size[0] !== size[0] || this.size[1] !== size[1]) {
      if (this.size) this.log(`the screen is now ${size[0]} x ${size[1]}`);
      this.input?.resize(size[0], size[1]);
    }
    this.size = size;
    this.sizeAt = Date.now();
    this.sizeError = null;
  }

  /** The display can't be had (or changed under a helper): nothing known about it until it is asked again. */
  lostDisplay(why) {
    this.size = null;
    this.sizeError = why;
  }

  /**
   * `/status.features` (a Linux extension; an open set, readers ignore keys they don't know): what works right now —
   * the clipboard (its X helper is running), sound (PulseAudio answers and the encoder starts, `YOYO_AUDIO` not off),
   * the client-drawn pointer (always), focus (never: no accessibility tree here), uu Link (its listener runs), the
   * window list (/windows, /hit, /frame?visible=: its helper could be started last time), automation (always).
   */
  async features() {
    return { clipboard: this.clipboard?.running ?? false, audio: await this.audio.available(), cursor: true, focus: false, link: !!this.linkListener, windows: this.windowsOk, automation: true };
  }

  /** The link listener running now: remote access's, or the headless one (authority mode). */
  get linkListener() {
    return this.remote?.link ?? this.link ?? null;
  }

  status(features) {
    const base = {
      app: this.platform.app,
      version: VERSION,
      api: API,
      platform: this.platform.id,
      screenRecording: true,
      accessibility: true,
      control: this.remote?.control.json ?? { controller: "none" },
      automation: this.automation.json,
      // the uu Link binding and endpoint (docs/LINK.md「身份与信任」): while its listener runs
      ...(this.linkListener?.json() ? { link: this.linkListener.json() } : {}),
      ...(features ? { features } : {}),
    };
    if (!this.size) return { ...base, ok: false, error: this.sizeError ?? "no display", session: { loggedIn: true }, displays: [], states: [], console: null };
    const [width, height] = this.size;
    return {
      ...base,
      ok: true,
      session: { loggedIn: true },
      displays: [{ id: DISPLAY_ID, width, height, scale: 1, main: true, asleep: false, kind: "builtin", name: this.name }],
      states: [this.state()],
      console: { locked: false },
    };
  }

  state() {
    return { display: DISPLAY_ID, main: true, phase: "ready", since: this.since };
  }

  /**
   * The long-lived `xdotool -` of one input channel (started again when it exits): `pointer` (moves, clicks, the wheel)
   * and `keys` (key presses, typed text) are separate processes, so text being typed never holds the pointer back.
   */
  sendInput(lines, channel = "pointer") {
    let p = this.xdo[channel];
    if (!p || p.exitCode !== null || p.killed) {
      p = this.spawn(this.xdotool, ["-"], { stdio: ["pipe", "ignore", "pipe"], env: this.env });
      this.xdo[channel] = p;
      const proc = p;
      p.stdin.on("error", () => {});
      p.stderr.setEncoding("utf8");
      p.stderr.on("data", (s) => {
        for (const l of s.split("\n")) if (l.trim()) this.log(`xdotool (${channel}): ${l.trim()}`);
      });
      p.on("exit", (code, signal) => {
        if (this.xdo[channel] === proc) this.xdo[channel] = null;
        if (code !== 0) this.log(`xdotool (${channel}) exited (${signal ?? `code ${code}`}); started again on the next input`);
      });
    }
    p.stdin.write(lines.map((l) => `${l}\n`).join(""));
  }

  /**
   * One request of an authenticated client: `LOCAL` (the token listener) or `{ kind: "remote", device }` (a paired phone
   * through remote.mjs, which only lets REMOTE_ROUTES through).
   */
  async handle(req, res, client = LOCAL) {
    const url = new URL(req.url ?? "/", "http://x");
    const route = `${req.method} ${url.pathname}`;
    switch (route) {
      case "GET /status":
        // asked again when 5 s old: a desktop whose X server went away says so (ok: false)
        await this.screenSize(5000).catch(() => {});
        return json(res, 200, this.status(await this.features()));
      case "GET /events":
        return this.eventsRoute(req, res);
      case "GET /frame":
        return this.frameRoute(url, res);
      case "GET /windows": {
        this.knownDisplay(url);
        return json(res, 200, windowsAnswer(windowCatalog(await this.readWindows()), DISPLAY_ID));
      }
      case "GET /hit": {
        const x = unitParameter(url, "x");
        const y = unitParameter(url, "y");
        this.knownDisplay(url);
        return json(res, 200, hitAnswer(windowCatalog(await this.readWindows()), x, y));
      }
      case "POST /automation":
      case "POST /agent-control": {
        const { active, label } = parseAutomation(await readBody(req, 64 * 1024));
        return json(res, 200, { ok: true, ...(await this.automation.set(active, label)) });
      }
      case "GET /stream":
        return this.streamRoute(req, url, res);
      case "POST /stream/ack":
        return this.ackRoute(req, res);
      case "POST /input":
        return this.inputRoute(req, res, client);
      case "POST /control":
        return this.controlRoute(req, res, client);
      case "GET /link/authority":
      case "POST /link/authority/answer":
      case "POST /link/control":
        return this.linkAuthorityRoute(route, req, res, client);
      case "POST /link/rtc":
        return this.linkRtcRoute(req, res, client);
      case "GET /audio":
        return this.audioRoute(req, res);
      case "GET /audio/stats":
        return json(res, 200, this.audio.stats());
      case "GET /clipboard":
        return json(res, 200, this.clipboard.read(url.searchParams.get("text") !== "0"));
      case "GET /clipboard/image": {
        const { data, changeCount } = await this.clipboard.image();
        res.writeHead(200, { "Content-Type": "image/png", "Content-Length": data.length, "X-Clipboard-Change-Count": changeCount, "Cache-Control": "no-store", Connection: "close" });
        return res.end(data);
      }
      case "GET /clipboard/file": {
        const raw = url.searchParams.get("index");
        const index = raw === null || raw === "" ? NaN : Number(raw);
        if (!Number.isInteger(index) || index < 0) return json(res, 400, { error: "index is required" });
        return sendClipboardFile(res, await this.clipboard.file(index));
      }
      case "POST /clipboard": {
        // 1 MiB of text, JSON-escaped (\uXXXX: up to 6 bytes a byte)
        const body = await readBody(req, 7 * 1024 * 1024);
        // a phone sends text only (`files` are paths on this machine), always as the phone
        if (client.kind === "remote") {
          if (typeof body?.text !== "string") throw new InputError("body needs text (a string)");
          return json(res, 200, await this.clipboard.write({ text: body.text }));
        }
        return json(res, 200, await this.clipboard.write(body));
      }
      default:
        return json(res, 404, { error: "not found" });
    }
  }

  /** One line to every /events subscriber. */
  publish(msg) {
    const line = `${JSON.stringify(msg)}\n`;
    for (const e of this.events) e.send(line);
  }

  eventsRoute(req, res) {
    res.writeHead(200, { "Content-Type": "application/x-ndjson", "Cache-Control": "no-cache", Connection: "close" });
    res.write(`${JSON.stringify({ type: "state", states: this.size ? [this.state()] : [], console: this.size ? { locked: false } : null })}\n`);
    // the clipboard's summary right after it (then a line per change)
    const clip = this.clipboard.running ? this.clipboard.summary() : null;
    if (clip) res.write(`${JSON.stringify({ type: "clipboard", ...clip })}\n`);
    const ping = setInterval(() => res.write(`${JSON.stringify({ type: "ping" })}\n`), 15_000);
    const sub = { end: () => res.end(), send: (line) => res.write(line) };
    this.events.add(sub);
    req.on("close", () => {
      clearInterval(ping);
      this.events.delete(sub);
    });
  }

  /**
   * GET /audio: the desktop's sound (audio.mjs) until the client hangs up. 503 `{ error }` before the head when the
   * capture can't start (`YOYO_AUDIO=off`: "audio off", the Mac's answer with its sound off).
   */
  async audioRoute(req, res) {
    let q;
    try {
      q = await this.audio.subscribe();
    } catch (err) {
      return json(res, err.status ?? 503, { error: err.message });
    }
    let closed = false;
    const onClose = () => {
      closed = true;
      q.close();
    };
    req.on("close", onClose);
    res.on("close", onClose);
    try {
      const wire = negotiate(req.headers.accept, "application/vnd.yoyo-control.audio");
      res.writeHead(200, {
        "Content-Type": wire.audio,
        "Cache-Control": "no-cache",
        "X-Audio-Codec": "opus",
        "X-Audio-Rate": "48000",
        "X-Audio-Channels": "2",
        "X-Audio-Frames": "960",
        "X-Audio-Cookie": audioCookie().toString("base64"),
        // the same clock as X-Frame-Time, no speaker, no scan-out — but the null sink renders up to its latency (our own
        // 20 ms request) ahead of its clock, and a chunk is labeled by when its read returned: the samples are heard
        // (by an app syncing its pictures to them) ~10 ms after their X-Audio-Time (README.md「声音」)
        "X-Audio-Video-Offset": String(AUDIO.videoOffsetMs),
        Connection: "close",
      });
      res.flushHeaders();
      while (!closed) {
        const items = await q.popAll(500);
        if (!items.length && q.closed) break;
        for (const it of items) {
          if (closed) break;
          // a client that can't keep up: its queue drops the oldest meanwhile
          if (!res.write(audioPart(wire.boundary, it))) await drained(res);
        }
      }
    } finally {
      this.audio.unsubscribe(q);
      if (!res.writableEnded) res.end();
    }
  }

  /** `display=` names the one display (or is absent); else a 404 InputError. */
  knownDisplay(url) {
    const display = url.searchParams.get("display");
    if (display !== null && display !== "" && Number(display) !== DISPLAY_ID) throw new InputError("unknown display", 404);
  }

  /** The windows helper's answer now (windows.mjs; 503 when it can't be had). */
  readWindows() {
    return readWindows({ path: this.windowsHelper, env: this.env, spawnFn: this.spawn, onSpawn: (ok) => (this.windowsOk = ok) });
  }

  /**
   * GET /frame: one ffmpeg x11grab picture. `visible=` / `hide=` cover every window of the other apps with a solid box
   * (the Mac's mask fallback, windows.mjs; header `X-Frame-Filter: mask`), `crop=` cuts a region of the full-resolution
   * picture after covering (header `X-Crop`), then it is scaled to `maxWidth`.
   */
  async frameRoute(url, res) {
    const [w, h] = await this.screenSize();
    this.knownDisplay(url);
    const num = (k, d, lo, hi) => {
      const v = url.searchParams.get(k);
      if (v === null || v === "") return d;
      const n = Number(v);
      if (!Number.isFinite(n)) throw new InputError(`${k} must be a number`);
      return Math.min(hi, Math.max(lo, Math.round(n)));
    };
    const maxWidth = num("maxWidth", 1280, 160, 3840);
    const quality = num("quality", 70, 10, 95);
    const q0 = (k) => url.searchParams.get(k);
    const hidden = parseHide(q0("hide"));
    const visible = q0("visible") === null ? null : new Set([...parseVisible(q0("visible"))].filter((id) => !hidden.hides(id)));
    const crop = q0("crop") === null ? null : parseCrop(q0("crop"));
    // the region of the full picture that is sent (a crop: whole pixels, rounded outward)
    const cut = crop ? pixelRect(crop, w, h) : { x: 0, y: 0, w, h };
    const outW = Math.max(2, Math.min(cut.w, maxWidth) & ~1);
    const outH = Math.max(2, Math.round((cut.h * outW) / cut.w) & ~1);
    // JPEG quality 10…95 → ffmpeg's qscale 31…2
    const q = Math.round(2 + ((95 - quality) / 85) * 29);
    const release = await this.frameSlot();
    // the window list right before the picture
    const boxes = await (visible ? this.readWindows().then((raw) => maskBoxes(windowCatalog(raw), visible, hidden, w, h)) : Promise.resolve([])).catch((err) => {
      release();
      throw err;
    });
    // Linux: ffmpeg's x11grab and filters; Windows: the video helper's one picture (winvideo.c `--jpeg`), the same steps
    const [tool, args] =
      this.platform.frame === "helper"
        ? [this.videoHelper, ["--jpeg", String(quality), "--size", String(outW), String(outH), ...(crop ? ["--crop", cut.x, cut.y, cut.w, cut.h].map(String) : []), ...boxes.flatMap((b) => ["--box", b.x, b.y, b.w, b.h].map(String))]]
        : [this.ffmpeg, ["-hide_banner", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "1", "-video_size", `${w}x${h}`, "-i", this.env.DISPLAY ?? ":0", "-frames:v", "1", "-vf", [...drawboxes(boxes), ...(crop ? [`crop=${cut.w}:${cut.h}:${cut.x}:${cut.y}`] : []), `scale=${outW}:${outH}:flags=area`].join(","), "-q:v", String(q), "-f", "mjpeg", "pipe:1"]];
    const jpeg = await new Promise((resolve, reject) => {
      const p = this.spawn(tool, args, { stdio: ["ignore", "pipe", "pipe"], env: this.env });
      const out = [];
      let err = "";
      p.stdout.on("data", (d) => out.push(d));
      p.stderr.on("data", (d) => (err += d));
      p.on("error", reject);
      p.on("close", (code) => (code === 0 ? resolve(Buffer.concat(out)) : reject(new Error(`${this.platform.frame === "helper" ? "the video helper" : "ffmpeg"}: ${err.trim().slice(0, 300) || `exit ${code}`}`))));
    }).finally(release);
    const extra = {
      ...(visible ? { "X-Frame-Filter": "mask" } : {}),
      ...(crop ? { "X-Crop": [cut.x / w, cut.y / h, cut.w / w, cut.h / h].map((v) => v.toFixed(4)).join(",") } : {}),
    };
    res.writeHead(200, { "Content-Type": "image/jpeg", "Content-Length": jpeg.length, "Cache-Control": "no-store", "X-Frame-Width": outW, "X-Frame-Height": outH, "X-Display": DISPLAY_ID, ...extra, Connection: "close" });
    res.end(jpeg);
  }

  /**
   * A turn to run one /frame capture (an ffmpeg each): FRAME_SLOTS at a time, FRAME_QUEUE more waiting, any more 503.
   * Resolves to the function that gives the turn back.
   */
  frameSlot() {
    const f = this.frames;
    const release = () => {
      f.running--;
      const next = f.waiting.shift();
      if (next) {
        f.running++;
        next(release);
      }
    };
    if (f.running < FRAME_SLOTS) {
      f.running++;
      return Promise.resolve(release);
    }
    if (f.waiting.length >= FRAME_QUEUE) return Promise.reject(new InputError(`too many frames asked for at once (max ${FRAME_SLOTS + FRAME_QUEUE})`, 503));
    return new Promise((resolve) => f.waiting.push(resolve));
  }

  /**
   * A `/stream` query (also a link `video.open`'s): `{ id, fps, maxKbps, cursor, status }`, or throws its 400 / 404 /
   * 503 (an InputError) before anything starts.
   */
  streamQuery(url) {
    const q = (k) => url.searchParams.get(k);
    const display = q("display");
    if (display !== null && display !== "" && Number(display) !== DISPLAY_ID) throw new InputError("unknown display", 404);
    const id = q("stream") || null;
    if (id !== null && !STREAM_ID.test(id)) throw new InputError("stream must be 8–64 characters of A-Z a-z 0-9 _ -");
    for (const k of ["ack", "status"]) {
      const v = q(k);
      if (v !== null && v !== "" && v !== "1" && v !== "0" && v !== "true" && v !== "false") throw new InputError(`${k} must be 1`);
    }
    const cursor = q("cursor");
    if (cursor !== null && cursor !== "" && cursor !== "client") throw new InputError('cursor must be "client"');
    let maxKbps = null;
    if (q("maxKbps")) {
      maxKbps = Number(q("maxKbps"));
      if (!Number.isInteger(maxKbps) || maxKbps < 100 || maxKbps > 100_000) throw new InputError("maxKbps must be an integer 100…100000");
    }
    const fpsRaw = q("fps");
    const fps = Math.min(this.maxFps, Math.max(1, fpsRaw ? Number(fpsRaw) || 2 : 2));
    if (this.streams.size >= MAX_STREAMS) throw new InputError(`too many streams (max ${MAX_STREAMS})`, 503);
    return { id, fps, maxKbps, cursor: cursor === "client", status: q("status") === "1" || q("status") === "true" };
  }

  /**
   * A stream's video helper (counted in `streams`) and, with `cursor`, its pointer feed (made at the helper's first
   * 'P', right after the hello). `done()` gives both back.
   */
  openHelper({ fps, cursor }) {
    const helper = new VideoHelper({ path: this.videoHelper, fps, env: this.env, log: this.log, spawnFn: this.spawn, cursor });
    this.streams.add(helper);
    const s = { helper, feed: null };
    if (cursor) {
      helper.onPointer = (r) => {
        if (!s.feed) {
          s.feed = new CursorFeed({ width: helper.size[0], height: helper.size[1], shapes: this.cursorShapes, onChange: () => helper.wake() });
          this.pointerFeeds.add(s.feed);
        }
        s.feed.fromHelper(r);
      };
    }
    s.done = () => {
      // a helper that stopped by itself (the display went away, or changed size): what we knew of the screen is old
      if (helper.exitCode !== null && helper.exitCode !== 0) this.lostDisplay(`the video helper exited (code ${helper.exitCode})`);
      helper.stop();
      this.streams.delete(helper);
      if (s.feed) this.pointerFeeds.delete(s.feed);
      // the last stream gone with the left button still down (the client vanished mid-drag): lift it
      if (!this.streams.size) this.input?.release();
    };
    return s;
  }

  async streamRoute(req, url, res) {
    let o;
    try {
      o = this.streamQuery(url);
    } catch (err) {
      if (err instanceof InputError) return json(res, err.status, { error: err.message });
      throw err;
    }
    const { id, fps, maxKbps } = o;
    const clientCursor = o.cursor;
    // h264 only: whatever the client lists (the reference server falls back to h264 too)
    const opened = this.openHelper(o);
    const helper = opened.helper;
    let closed = false;
    const onClose = () => {
      closed = true;
      helper.wake();
    };
    req.on("close", onClose);
    res.on("close", onClose);
    try {
      this.setSize(await helper.ready);
      const wire = negotiate(req.headers.accept, "application/vnd.yoyo-control.stream");
      res.writeHead(200, {
        "Content-Type": wire.stream,
        "Cache-Control": "no-store",
        "X-Display": DISPLAY_ID,
        "X-Stream-Codec": "h264",
        ...(id ? { "X-Stream-Id": id } : {}),
        Connection: "close",
      });
      res.flushHeaders();
      this.log(`video: h264 @${fps} fps stream ${id ?? "-"}${o.status ? ", status" : ""}${clientCursor ? ", client cursor" : ""}`);
      await streamLoop(res, {
        helper,
        wire,
        id,
        fps,
        status: o.status,
        maxKbps,
        displayId: DISPLAY_ID,
        tuning: this.tuning,
        statsEvery: 10,
        log: this.log,
        closed: () => closed,
        feed: opened.feed,
      });
    } catch (err) {
      if (!res.headersSent) {
        // the helper couldn't open the display: /status says so until it can again
        this.lostDisplay(err.message);
        return json(res, 503, { error: err.message });
      }
    } finally {
      opened.done();
      if (!res.writableEnded) res.end();
      this.log(`video: stream ${id ?? "-"} closed`);
    }
  }

  async ackRoute(req, res) {
    const b = await readBody(req, 16 * 1024);
    if (!b || typeof b !== "object" || Array.isArray(b)) throw new InputError("body must be a JSON object");
    if (typeof b.stream !== "string" || !STREAM_ID.test(b.stream)) throw new InputError("stream must be a stream id");
    if (typeof b.seq !== "number" || !Number.isSafeInteger(b.seq) || b.seq < 0) throw new InputError("seq must be a non-negative integer");
    if (b.keyframe != null && typeof b.keyframe !== "boolean") throw new InputError("keyframe must be a boolean");
    const flow = flows.get(b.stream);
    if (!flow) return json(res, 404, { error: "no open stream with this id" });
    flow.ack(b.seq, b.keyframe === true, parsePlayoutReport(b.report));
    return json(res, 200, { ok: true, net: flow.netQuality() });
  }

  /**
   * `POST /control { controller: "user" | "none" }` from a paired phone → `{ ok: true, control }`: takes control (always
   * succeeds; the latest taker holds it) or lets go of its own. The token listener: 404, as on the Mac's socket.
   */
  async controlRoute(req, res, client) {
    if (client.kind !== "remote" || !this.remote) return json(res, 404, { error: "POST /control is for paired devices (remote access)" });
    const b = await readBody(req, 64 * 1024);
    switch (b?.controller) {
      case "user":
        this.remote.control.take(client.device);
        break;
      case "none":
        this.remote.control.release(client.device);
        break;
      default:
        throw new InputError('controller must be "user" or "none"');
    }
    return json(res, 200, { ok: true, control: this.remote.control.json });
  }

  /**
   * The link's authority (docs/LOCAL-API.md「Link 的主人」), on the token listener only (paired phones and a server
   * without the headless link: 404): `GET /link/authority` the host's NDJSON channel (409 while another host holds it),
   * `POST /link/authority/answer` → `{ ok: true }`, `POST /link/control { holder: { id, name } | null }` →
   * `{ ok: true, holder }`.
   */
  async linkAuthorityRoute(route, req, res, client) {
    const a = this.linkAuthority;
    if (client.kind !== "local" || !a) return json(res, 404, { error: "not found" });
    switch (route) {
      case "GET /link/authority":
        if (!a.attach(req, res)) return json(res, 409, { error: "another authority host is connected" });
        return;
      case "POST /link/authority/answer":
        a.answer(await readBody(req, 64 * 1024));
        return json(res, 200, { ok: true });
      case "POST /link/control": {
        const b = await readBody(req, 64 * 1024);
        if (!b || typeof b !== "object" || !("holder" in b)) throw new InputError("body must be { holder: { id, name } | null }");
        const holder = b.holder === null ? null : authorityDevice(b.holder);
        if (b.holder !== null && !holder) throw new InputError("holder must be { id, name } or null");
        a.setHolder(holder);
        return json(res, 200, { ok: true, holder: a.holder });
      }
    }
  }

  /**
   * `POST /link/rtc` (the token listener only): a browser's WebRTC offer JSON → uu Link's signed answer JSON (docs/LINK.md
   * 「WebRTC」), for a host that relays offers for its clients. 404 while the link (or its rtc socket) isn't running,
   * 400 a bad offer, 429 / 503 the guard's refusals.
   */
  async linkRtcRoute(req, res, client) {
    const link = this.linkListener;
    if (client.kind !== "local" || !link) return json(res, 404, { error: "not found" });
    const offer = await readBody(req, 64 * 1024);
    try {
      const answer = await link.acceptRtcOffer(JSON.stringify(offer), null);
      res.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(answer) });
      return res.end(answer);
    } catch (err) {
      return json(res, err.status ?? 503, { error: err.message });
    }
  }

  async inputRoute(req, res, client = LOCAL) {
    return json(res, 200, await this.applyInput(await readBody(req, 64 * 1024), client));
  }

  /** One `/input` event (also a link session's input): its answer, or throws the route's error (an InputError). */
  async applyInput(body, client = LOCAL) {
    const e = parseInput(body);
    // a paired phone needs control; the token listener's input waits while a phone holds it (control.mjs)
    this.remote?.control.admitInput(client.kind === "remote" ? client.device : null);
    if (e.display !== undefined && e.display !== DISPLAY_ID) throw new InputError("unknown display", 404);
    const [width, height] = await this.screenSize();
    this.input ??= new InputDriver({ send: (lines) => this.sendInput(lines, "pointer"), sendKeys: (lines) => this.sendInput(lines, "keys"), width, height, log: this.log });
    const answer = this.input.apply(e);
    // the cursor=client streams show the pointer where this input leaves it, before any picture or poll does
    const at = answer.stale ? null : positionAfter(e);
    if (at) for (const f of this.pointerFeeds) f.noteInput(at.x, at.y);
    return answer;
  }
}

/** The token: the first line of `file` when given, else of stdin (read to its end). */
export async function readToken(file, stdin = process.stdin) {
  if (file) return (await readFile(file, "utf8")).split("\n")[0].trim();
  const chunks = [];
  for await (const c of stdin) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8").split("\n")[0].trim();
}

/** `on` / `off` (and 1 / 0, true / false, yes / no); undefined when not given. */
export function onOff(value, name) {
  if (value === undefined) return undefined;
  if (["on", "1", "true", "yes"].includes(value)) return true;
  if (["off", "0", "false", "no"].includes(value)) return false;
  throw new Error(`${name} must be on or off`);
}

/** `a,b , c` → ["a", "b", "c"]. */
export function list(value) {
  return (value ?? "").split(",").map((x) => x.trim()).filter(Boolean);
}

/** `ip[:port]` → `{ host, port? }`. */
function endpoint(value, name) {
  const m = /^(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?$/.exec(value ?? "");
  if (!m) throw new Error(`${name} must be ip[:port]`);
  return { host: m[1], port: m[2] ? Number(m[2]) : undefined };
}

/** The commands that talk to a running server's admin socket: `pair`, `devices`, `remove <id>`, `disconnect`, `status`, `account [leave]`. */
async function command(cmd, argv) {
  const home = arg(argv, "--remote");
  if (!home) throw new Error(`usage: node server.mjs ${cmd} --remote <home>${cmd === "remove" ? " <device id>" : ""}`);
  const { adminCall } = await import("./remote.mjs");
  const ok = (r) => {
    if (r.status !== 200) throw new Error(r.json?.error ?? `the server answered ${r.status}`);
    return r.json;
  };
  const out = (s) => process.stdout.write(`${s}\n`);
  switch (cmd) {
    case "pair": {
      const j = ok(await adminCall(home, "POST", "/remote/pairing"));
      if (!j.pairing?.url) throw new Error("uu Link isn't listening, so there's no pairing link (the server's log says why)");
      if (argv.includes("--json")) return out(JSON.stringify(j.pairing));
      // a terminal QR code (the iPhone's Camera opens Yoyo Control with it): qrencode's when it is there, else ours
      const { spawnSync } = await import("node:child_process");
      const qr = process.platform === "win32" ? { error: true } : spawnSync("qrencode", ["-t", "ANSIUTF8", "-m", "2", j.pairing.url], { stdio: ["ignore", "inherit", "ignore"] });
      if (qr.error) {
        const { qrTerminal } = await import("./qr.mjs");
        out(qrTerminal(j.pairing.url));
      }
      // --page: the code as a page too (<home>/pair.html), opened in the browser — a window to scan on a desktop
      if (argv.includes("--page")) {
        const { qrSvg } = await import("./qr.mjs");
        const { writeFileSync } = await import("node:fs");
        const page = join(home, "pair.html");
        const esc = (t) => t.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
        writeFileSync(page, `<!doctype html><meta charset="utf-8"><title>Pair ${esc(j.name)}</title><body style="font:16px system-ui;text-align:center;margin-top:6vh">${qrSvg(j.pairing.url)}<p>Scan with the iPhone's Camera to pair <b>${esc(j.name)}</b> with Yoyo Control.<br>Good for ${Math.round((j.pairing.expiresAt - Date.now()) / 60_000)} minutes, once.</p></body>`);
        const opener = process.platform === "win32" ? ["cmd", ["/c", "start", "", page]] : process.platform === "darwin" ? ["open", [page]] : ["xdg-open", [page]];
        spawnSync(opener[0], opener[1], { stdio: "ignore" });
        out(`(the code is also in ${page})`);
      }
      out(j.pairing.url);
      const mins = Math.round((j.pairing.expiresAt - Date.now()) / 60_000);
      out(`Pair "${j.name}" with Yoyo Control on the iPhone (scan, or open the link on it): good for ${mins} min, once.`);
      out(`uu Link on udp ${j.link?.port ?? "?"} (${j.addresses.join(", ") || "no address yet"}); signaling ${j.signal.connected ? "registered" : "connecting"}; direct from the internet: ${j.direct.status}${j.direct.address ? ` (${j.direct.address}:${j.direct.port})` : ""}.`);
      return;
    }
    case "devices": {
      const j = ok(await adminCall(home, "GET", "/remote"));
      if (argv.includes("--json")) return out(JSON.stringify(j, null, 2));
      if (!j.devices.length) out("No devices paired.");
      for (const d of j.devices) out(`${d.id}  ${d.name}  paired ${new Date(d.pairedAt).toISOString()}${d.connected ? "  (connected)" : ""}`);
      if (j.control.controller === "remote") out(`${j.control.device.name} controls the screen.`);
      return;
    }
    case "status":
      return out(JSON.stringify(ok(await adminCall(home, "GET", "/remote")), null, 2));
    case "remove": {
      const id = argv.find((a, i) => i > 0 && !a.startsWith("--") && argv[i - 1] !== "--remote");
      if (!id) throw new Error("usage: node server.mjs remove --remote <home> <device id>");
      ok(await adminCall(home, "POST", "/remote/devices/remove", { id }));
      return out(`Removed ${id}.`);
    }
    case "disconnect":
      ok(await adminCall(home, "POST", "/remote/disconnect"));
      return out("Control taken back.");
    case "account": {
      // docs/ACCOUNT.md: an iPhone signed in to its account puts this computer there; `account leave` takes it out
      if (argv.includes("leave")) {
        ok(await adminCall(home, "POST", "/remote/account/leave"));
        return out("Left the account. Paired iPhones stay paired.");
      }
      const j = ok(await adminCall(home, "GET", "/remote"));
      return out(j.account ? `In a Yoyo Control account since ${new Date(j.account.since).toISOString()} (\`account leave\` to leave it).` : "Not in a Yoyo Control account (an iPhone signed in to one puts it there).");
    }
  }
}

const COMMANDS = ["pair", "devices", "remove", "disconnect", "status", "account"];

/**
 * `--link-rtc-port <port|off>` (default the link port + 1; `YOYO_LINK_RTC_PORT` too) and `--link-stun host:port,…`: the
 * link's WebRTC socket for browsers (link.mjs).
 */
export function rtcOptions(argv, linkPort, env = process.env) {
  const v = arg(argv, "--link-rtc-port") ?? env.YOYO_LINK_RTC_PORT;
  const rtcPort = v === undefined ? (linkPort === 0 ? 0 : linkPort + 1) : v === "off" ? null : Number(v);
  if (rtcPort !== null && !(Number.isInteger(rtcPort) && rtcPort >= 0 && rtcPort < 65536)) throw new Error(`--link-rtc-port ${v}: a port or off`);
  return { rtcPort, stun: list(arg(argv, "--link-stun")) };
}

/**
 * `--signal <url|off>` (`YOYO_SIGNAL_URL` too): the signaling server this computer keeps its room at (docs/RELAY.md
 * 「信令服务」, `relay/signal` is one): browsers' WebRTC offers, lookups by fingerprint. None is built in: unset = none.
 */
export function signalUrl(argv, env = process.env) {
  const v = (arg(argv, "--signal") ?? env.YOYO_SIGNAL_URL ?? "").trim();
  return v === "" || v === "off" ? null : v;
}

/**
 * `defaults.env` beside server.mjs, when a distributor's build carries one (`KEY=value` lines, `#` comments): the
 * environment this server starts with where the real one says nothing (`YOYO_LINK_RELAYS`, `YOYO_SIGNAL_URL`, …).
 * The open-source release has none, so it reaches no service of anyone's unless told to.
 */
export async function loadDefaults(file = join(fileURLToPath(new URL(".", import.meta.url)), "defaults.env"), env = process.env) {
  let text;
  try {
    text = await readFile(file, "utf8");
  } catch {
    return [];
  }
  const set = [];
  for (const line of text.split(/\r?\n/)) {
    const m = /^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
    if (!m || env[m[1]] !== undefined) continue;
    env[m[1]] = m[2];
    set.push(m[1]);
  }
  return set;
}

/**
 * `--link-relay <url,…|off>` (`YOYO_LINK_RELAYS` too): the link's iroh relays (docs/LINK.md「中继」), published to phones in
 * the binding (a `?token=` is the relay's access token); none is built in: unset or `off` = direct only.
 */
export function linkRelays(argv, env = process.env, defaults = []) {
  const v = arg(argv, "--link-relay") ?? env.YOYO_LINK_RELAYS;
  if (v === undefined) return [...defaults];
  const relays = v === "off" ? [] : list(v);
  for (const r of relays) {
    if (!/^https?:\/\//.test(r)) throw new Error(`--link-relay ${r}: a relay URL (https://…) or off`);
  }
  return relays;
}

/**
 * `--link on` without `--remote`: the link listener in authority mode (link.mjs LinkAuthority), its link key and the
 * identity its binding is signed with in `--link-home` (made 0700 when missing; stable across restarts), `--advertise`
 * as its external addresses (a container's published UDP port on its host). No router mapping here. A missing addon or
 * a port it can't have is one log line: the HTTP API runs on.
 */
export async function startHeadlessLink(svc, argv, { log: logLine = log } = {}) {
  const home = arg(argv, "--link-home");
  if (!home) throw new Error("--link on without --remote needs --link-home <dir> (the link's keys)");
  const { DEFAULT_LINK_PORT, LinkAuthority, LinkServer, loadLink } = await import("./link.mjs");
  const { loadOrCreateIdentity } = await import("./vendor/remote/index.js");
  const { L, error } = await loadLink();
  if (!L) {
    logLine(`link: off (no native addon: ${error})`);
    return null;
  }
  const identity = loadOrCreateIdentity(home);
  const authority = new LinkAuthority({ log: logLine });
  const port = arg(argv, "--link-port") ? Number(arg(argv, "--link-port")) : DEFAULT_LINK_PORT;
  const link = new LinkServer({
    ...rtcOptions(argv, port),
    relays: linkRelays(argv),
    L,
    svc,
    authority,
    home,
    // stable: the identity key's
    serverId: identity.keyFingerprint.slice("sha256:".length, "sha256:".length + 32),
    name: arg(argv, "--computer-name") ?? arg(argv, "--name") ?? svc.name,
    port,
    advertise: list(arg(argv, "--advertise")),
    exempt: list(arg(argv, "--exempt")),
    bind: list(arg(argv, "--link-bind")),
    log: logLine,
  });
  try {
    await link.start(identity);
  } catch (err) {
    logLine(`link: cannot listen on udp ${port}: ${err.message}`);
    await link.stop().catch(() => {});
    return null;
  }
  svc.link = link;
  svc.linkAuthority = authority;
  logLine(`link: authority mode, udp ${link.ep.port}, keys in ${home}, fingerprint ${identity.keyFingerprint}`);
  return link;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  await loadDefaults();
  const argv = process.argv.slice(2);
  if (COMMANDS.includes(argv[0])) {
    try {
      await command(argv[0], argv);
      process.exit(0);
    } catch (err) {
      process.stderr.write(`${err.message}\n`);
      process.exit(1);
    }
  }
  const remoteHome = arg(argv, "--remote");
  // with --remote alone there is no token listener; --token-file, --port or --host ask for it too
  const tokenListener = !remoteHome || ["--token-file", "--port", "--host"].some((f) => argv.includes(f));
  const svc = new YoyoLinux({
    token: tokenListener ? await readToken(arg(argv, "--token-file")) : null,
    ...(arg(argv, "--name") ? { name: arg(argv, "--name") } : {}),
    // the helpers' own names (YOYO_X11VIDEO…) or, on either platform, YOYO_VIDEO_HELPER / AUDIO / CLIPBOARD / WINDOWS / INPUT
    videoHelper: process.env.YOYO_VIDEO_HELPER || process.env.YOYO_X11VIDEO || undefined,
    audioHelper: process.env.YOYO_AUDIO_HELPER || process.env.YOYO_PA_OPUS || undefined,
    clipboardHelper: process.env.YOYO_CLIPBOARD_HELPER || process.env.YOYO_X11CLIP || undefined,
    windowsHelper: process.env.YOYO_WINDOWS_HELPER || process.env.YOYO_X11WINDOWS || undefined,
    xdotool: process.env.YOYO_INPUT_HELPER || process.env.YOYO_XDOTOOL || undefined,
    ffmpeg: process.env.YOYO_FFMPEG || undefined,
    maxKbps: Number(process.env.YOYO_VIDEO_MAX_KBPS) || undefined,
    maxFps: Number(process.env.YOYO_MAX_FPS || process.env.YOYO_LINUX_MAX_FPS) || undefined,
  });
  if (tokenListener) {
    const addr = await svc.listen(Number(arg(argv, "--port") ?? 7380), resolveHost(arg(argv, "--host") ?? "127.0.0.1"));
    log(`${APP} ${VERSION} (api ${API}) listening on ${addr.address}:${addr.port}, ${svc.platform.display(process.env)}`);
  } else {
    svc.clipboard.start();
  }
  // uu Link without remote access: authority mode, the keys in --link-home (link.mjs)
  const headlessLink = !remoteHome && onOff(arg(argv, "--link"), "--link") === true && process.env.YOYO_LINK !== "off";
  if (headlessLink) await startHeadlessLink(svc, argv);
  if (remoteHome) {
    const { RemoteAccess } = await import("./remote.mjs");
    const client = arg(argv, "--direct-client") ? endpoint(arg(argv, "--direct-client"), "--direct-client") : null;
    svc.remote = new RemoteAccess({
      svc,
      home: remoteHome,
      direct: onOff(arg(argv, "--direct"), "--direct"),
      name: arg(argv, "--computer-name") ?? arg(argv, "--name"),
      advertise: list(arg(argv, "--advertise")),
      portMap: {
        ...(client ? { internalClient: client.host, ...(client.port ? { internalPort: client.port } : {}) } : {}),
        ...(arg(argv, "--direct-port") ? { externalPort: Number(arg(argv, "--direct-port")) } : {}),
        ...(arg(argv, "--direct-gateway") ? { gateway: arg(argv, "--direct-gateway") } : {}),
        ...(arg(argv, "--direct-upnp") ? { upnpLocation: arg(argv, "--direct-upnp") } : {}),
      },
      exempt: list(arg(argv, "--exempt")),
      ...(arg(argv, "--link-port") ? { linkPort: Number(arg(argv, "--link-port")) } : {}),
      ...rtcOptions(argv, arg(argv, "--link-port") ? Number(arg(argv, "--link-port")) : 47820),
      linkRelays: linkRelays(argv),
      signalUrl: signalUrl(argv),
      log,
    });
    await svc.remote.start();
    const r = svc.remote.json();
    log(`${APP} ${VERSION} (api ${API}) remote access: ${remoteHome}${r.link ? `, link udp ${r.link.port}` : ""}, ${r.devices.length} device(s) paired${r.listening ? ", listening" : " (listening once a phone pairs: node server.mjs pair --remote …)"}, ${svc.platform.display(process.env)}`);
  }
  for (const sig of ["SIGTERM", "SIGINT", ...(process.platform === "win32" ? ["SIGBREAK"] : [])]) {
    process.on(sig, async () => {
      // the router's mapping goes first (at most 2 s)
      await svc.remote?.stop().catch(() => {});
      await svc.link?.stop().catch(() => {});
      svc.close();
      process.exit(0);
    });
  }
}
