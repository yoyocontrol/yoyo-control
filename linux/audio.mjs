// GET /audio (README.md「声音」; the protocol's「声音」, the reference server's AudioStream.swift / AudioCapture.swift):
// the desktop's sound as Opus, one 20 ms packet per part, in the stream's multipart framing. One capture
// (yoyo-pa-opus, recording the PulseAudio sink's monitor) for every client: the first client starts it, it stops 3 s
// after the last one leaves; each client has a bounded queue (25 packets ≈ 500 ms) that loses its OLDEST packets when
// the client falls behind, and `X-Audio-Seq` is given on the way in, so a lost packet leaves a gap.
import { spawn } from "node:child_process";

export const AUDIO = Object.freeze({
  rate: 48_000,
  channels: 2,
  frames: 960,
  queue: 25,
  lingerMs: 3000,
  statsEveryMs: 10_000,
  /** How long a starting capture may take to connect to PulseAudio and say hello. */
  startTimeoutMs: 3000,
  /**
   * `X-Audio-Video-Offset`: a packet's samples play (on the null sink's clock, which an app syncs its pictures to)
   * about this much after its `X-Audio-Time` — the sink renders up to its latency ahead (our reader's 20 ms request
   * is the smallest, so it sets it: measured 0–19 ms with a player), half of it on average.
   */
  videoOffsetMs: 10,
});

/**
 * `X-Audio-Cookie`: the bytes the reference server sends (its AVAudioConverter's Opus magic cookie, read off a live Mac
 * on 2026-10-31 — not an OpusHead): seven big-endian 32-bit fields, 2048, the sample rate, the frames per packet,
 * -1000, the channels, 0, 0. The same here so a client that hands it to its decoder (iOS: AVAudioConverter) gets what
 * it gets from a Mac for the same stream shape.
 */
export function audioCookie({ rate = AUDIO.rate, frames = AUDIO.frames, channels = AUDIO.channels } = {}) {
  const b = Buffer.alloc(28);
  [2048, rate, frames, -1000, channels, 0, 0].forEach((v, i) => b.writeInt32BE(v, i * 4));
  return b;
}

/** `YOYO_AUDIO` off / 0 / false / no turns `/audio` off (503 "audio off"), as on the Mac. */
export function audioEnabled(env) {
  const v = String(env.YOYO_AUDIO ?? "").trim().toLowerCase();
  return !["off", "0", "false", "no"].includes(v);
}

/** One client's packets, waiting for its writes (AudioClientQueue): at most `capacity`, the oldest dropped. */
export class AudioClientQueue {
  constructor(capacity = AUDIO.queue) {
    this.capacity = capacity;
    this.items = [];
    this.nextSeq = 0;
    this.dropped = 0;
    this.closed = false;
    this.waiter = null;
  }

  push(packet) {
    if (this.closed) return;
    this.nextSeq++;
    if (this.items.length >= this.capacity) {
      this.items.shift();
      this.dropped++;
    }
    this.items.push({ seq: this.nextSeq, packet });
    this.waiter?.();
  }

  /** Everything queued, oldest first; waits up to `ms` while empty ([] = nothing came, or closed). */
  popAll(ms) {
    if (this.items.length || this.closed) return Promise.resolve(this.items.splice(0));
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(t);
        this.waiter = null;
        resolve(this.items.splice(0));
      };
      const t = setTimeout(done, ms);
      this.waiter = done;
    });
  }

  close() {
    this.closed = true;
    this.waiter?.();
  }
}

/** yoyo-pa-opus's records: `{ type: "H", rate, channels, frames, lookahead }`, `{ type: "A", time, fill, data }`. */
export class AudioRecordReader {
  constructor() {
    this.buf = Buffer.alloc(0);
  }

  feed(chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    const out = [];
    while (this.buf.length >= 5) {
      const len = this.buf.readUInt32BE(1);
      if (len > 65536) throw new Error(`audio helper: a record of ${len} bytes`);
      if (this.buf.length < 5 + len) break;
      const type = String.fromCharCode(this.buf[0]);
      const body = this.buf.subarray(5, 5 + len);
      this.buf = this.buf.subarray(5 + len);
      if (type === "H" && len >= 10) out.push({ type, rate: body.readUInt32BE(0), channels: body.readUInt16BE(4), frames: body.readUInt16BE(6), lookahead: body.readUInt16BE(8) });
      else if (type === "A" && len >= 9) out.push({ type, time: body.readDoubleLE(0), fill: (body[8] & 1) !== 0, data: Buffer.from(body.subarray(9)) });
    }
    return out;
  }
}

/** An HTTP 503 for `/audio` (before the response head). */
export class AudioError extends Error {
  constructor(message) {
    super(message);
    this.status = 503;
  }
}

/**
 * The shared capture: `subscribe()` (starting yoyo-pa-opus when it isn't running; 503 AudioError when it can't),
 * `unsubscribe(client)` (the last one out stops it `lingerMs` later), `available()` (can it start: a probe, cached).
 */
export class AudioCapture {
  constructor({ path, env, log, spawnFn = spawn, enabled = audioEnabled(env), now = () => Date.now(), lingerMs = AUDIO.lingerMs, statsEveryMs = AUDIO.statsEveryMs, startTimeoutMs = AUDIO.startTimeoutMs }) {
    this.path = path;
    this.env = env;
    this.log = log;
    this.spawn = spawnFn;
    this.enabled = enabled;
    this.now = now;
    this.lingerMs = lingerMs;
    this.statsEveryMs = statsEveryMs;
    this.startTimeoutMs = startTimeoutMs;
    this.clients = new Set();
    this.helper = null;
    this.starting = null;
    this.stopTimer = null;
    this.probed = null; // { ok, at, error }
    this.probing = null;
    this.counters = { starts: 0, failures: 0, packets: 0, fills: 0, lastError: null };
    this.window = null;
  }

  /** Whether sound can be had now (a running capture: yes; else a probe, kept 60 s when it worked, 10 s when not). */
  async available() {
    if (!this.enabled) return false;
    if (this.helper) return true;
    const p = this.probed;
    if (p && this.now() - p.at < (p.ok ? 60_000 : 10_000)) return p.ok;
    this.probing ??= new Promise((resolve) => {
      let child;
      let err = "";
      const finish = (ok, why) => {
        clearTimeout(t);
        this.probed = { ok, at: this.now(), error: ok ? null : why };
        this.probing = null;
        resolve(ok);
      };
      const t = setTimeout(() => {
        child?.kill("SIGKILL");
        finish(false, "the audio helper did not answer in 3 s");
      }, AUDIO.startTimeoutMs);
      try {
        child = this.spawn(this.path, ["--probe"], { stdio: ["ignore", "ignore", "pipe"], env: this.env });
      } catch (e) {
        return finish(false, e.message);
      }
      child.stderr?.setEncoding("utf8");
      child.stderr?.on("data", (s) => (err += s));
      child.on("error", (e) => finish(false, e.message));
      child.on("exit", (code) => finish(code === 0, err.trim().split("\n").at(-1) || `exit ${code}`));
    });
    return this.probing;
  }

  /** A new client (its queue) of the running capture, starting it first if needed. */
  async subscribe() {
    if (!this.enabled) throw new AudioError("audio off");
    clearTimeout(this.stopTimer);
    this.stopTimer = null;
    if (!this.helper) {
      this.starting ??= this.start().finally(() => (this.starting = null));
      await this.starting;
    }
    const q = new AudioClientQueue();
    this.clients.add(q);
    this.log(`audio: client connected (${this.clients.size} now)`);
    return q;
  }

  unsubscribe(q) {
    q.close();
    if (!this.clients.delete(q)) return;
    this.log(`audio: client left (${this.clients.size} now; it lost ${q.dropped} packets)`);
    if (this.clients.size || !this.helper) return;
    this.stopTimer = setTimeout(() => {
      this.stopTimer = null;
      if (!this.clients.size) this.stop("no clients for 3 s");
    }, this.lingerMs);
    this.stopTimer.unref?.();
  }

  start() {
    return new Promise((resolve, reject) => {
      let child;
      try {
        child = this.spawn(this.path, [], { stdio: ["pipe", "pipe", "pipe"], env: this.env });
      } catch (e) {
        this.counters.failures++;
        return reject(new AudioError(e.message));
      }
      const reader = new AudioRecordReader();
      let hello = false;
      let failed = false;
      let err = "";
      const startedAt = this.now();
      // once: the timeout and the exit (or an error) may both come
      const fail = (why) => {
        if (failed || hello) return;
        failed = true;
        clearTimeout(timer);
        this.counters.failures++;
        this.counters.lastError = why;
        this.probed = { ok: false, at: this.now(), error: why };
        this.log(`audio: cannot start: ${why}`);
        child.kill("SIGKILL");
        reject(new AudioError(why));
      };
      const timer = setTimeout(() => fail(`the audio helper did not answer in ${this.startTimeoutMs / 1000} s`), this.startTimeoutMs);
      child.stdin.on("error", () => {});
      child.stderr.setEncoding("utf8");
      child.stderr.on("data", (s) => {
        for (const line of s.split("\n")) {
          if (!line.trim()) continue;
          if (!hello) err = line.trim();
          this.log(`audio helper: ${line.trim()}`);
        }
      });
      child.stdout.on("data", (d) => {
        let recs;
        try {
          recs = reader.feed(d);
        } catch (e) {
          this.log(e.message);
          child.kill("SIGKILL");
          return;
        }
        for (const r of recs) {
          if (r.type === "H" && !hello && !failed) {
            hello = true;
            clearTimeout(timer);
            this.helper = child;
            this.counters.starts++;
            this.counters.lastError = null;
            this.probed = { ok: true, at: this.now(), error: null };
            this.window = { at: this.now(), packets: 0, fills: 0, bytes: 0 };
            this.log(`audio: capture started (Opus ${r.rate} Hz ${r.channels} ch, ${r.frames} frames, lookahead ${r.lookahead}, ${this.now() - startedAt} ms)`);
            resolve();
          } else if (r.type === "A") this.packet(r);
        }
      });
      child.on("error", (e) => {
        if (!hello) fail(e.message);
      });
      child.on("exit", (code, signal) => {
        if (!hello) return fail(err || `the audio helper exited (${signal ?? `code ${code}`})`);
        if (this.helper !== child) return;
        this.helper = null;
        const left = [...this.clients];
        this.clients.clear();
        for (const q of left) q.close();
        if (code !== 0 && signal !== "SIGTERM") {
          this.counters.lastError = err || `exit ${code ?? signal}`;
          this.probed = null;
          this.log(`audio: the capture stopped (${signal ?? `code ${code}`}); ${left.length} client(s) ended`);
        }
      });
    });
  }

  packet(r) {
    this.counters.packets++;
    if (r.fill) this.counters.fills++;
    for (const q of this.clients) q.push(r);
    const w = this.window;
    if (!w) return;
    w.packets++;
    w.bytes += r.data.length;
    if (r.fill) w.fills++;
    const ms = this.now() - w.at;
    if (ms >= this.statsEveryMs && this.clients.size) {
      const dropped = [...this.clients].reduce((n, q) => n + q.dropped, 0);
      this.log(`audio: last ${(ms / 1000).toFixed(1)} s ${w.packets} packets (${w.fills} silence filled), ${Math.round((w.bytes * 8) / ms)} kbit/s Opus, ${this.clients.size} client(s), dropped ${dropped} so far`);
      this.window = { at: this.now(), packets: 0, fills: 0, bytes: 0 };
    }
  }

  stop(why) {
    const h = this.helper;
    if (!h) return;
    this.helper = null;
    this.log(`audio: capture stopped (${why})`);
    try {
      h.stdin.end();
    } catch {}
    h.kill("SIGTERM");
  }

  close() {
    clearTimeout(this.stopTimer);
    for (const q of this.clients) q.close();
    this.clients.clear();
    this.stop("shutting down");
  }

  stats() {
    return { enabled: this.enabled, running: !!this.helper, clients: this.clients.size, ...this.counters };
  }
}

/** One audio part (AudioWire.part). */
export function audioPart(boundary, { seq, packet }) {
  const head = `--${boundary}\r\nContent-Type: audio/opus\r\nContent-Length: ${packet.data.length}\r\nX-Audio-Seq: ${seq}\r\nX-Audio-Time: ${Math.round(packet.time)}\r\n\r\n`;
  return Buffer.concat([Buffer.from(head, "latin1"), packet.data, Buffer.from("\r\n")]);
}
