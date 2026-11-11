// GET /stream (README.md「视频流」): one stream loop per client over its own yoyo-x11video process, after the reference
// server's VideoStreamLoop.swift — a picture is encoded only when the screen changed (or a key frame is due), at most
// `fps` (counted from the start of the previous picture's work); with acks at most W pictures are in flight and the
// queueing delay steers the bit rate (flow.mjs); an unchanged picture gets sharper re-encodes (`refine`: 300 ms after
// the change, then every 100 ms until two in a row add little, at most 20; flow.mjs RefineSchedule) and a keepalive
// every 5 s. A stream without `cursor=client` has the pointer drawn into its pictures; one
// with it gets cursor parts instead (cursor.mjs): one before the first picture, then on every change, at most 60 a
// second, outside the window — and a pointer move is never a picture change.
import { spawn } from "node:child_process";
import { CURSOR_MIN_INTERVAL, SENT_SHAPES_MAX, cursorBody } from "./cursor.mjs";
import { RefineSchedule, StreamFlow, TUNING, limitedTuning, liveBudget, playoutLine, refineKbps } from "./flow.mjs";
import { RecordReader, streamPart } from "./wire.mjs";

/** The quality the encoder aims at (x264 CRF) for live pictures and for refines. */
export const CRF = Object.freeze({ live: 23, refine: 17 });

/** Open streams by the client's stream id (acks find them here). A new stream with the same id replaces the old one. */
export const flows = new Map();

const monotonic = () => performance.now() / 1000;

/**
 * The video helper of one stream: yoyo-x11video, driven over its stdin, its records read from its stdout. `cursor`:
 * `--cursor client` (the pointer as 'P' records to `onPointer`, never in the picture); `ready` then waits for the
 * first one too (it comes right after the hello), so the stream's first cursor part has a position and a shape.
 *
 * A helper whose hello says so keeps time for the loop (`timer`; yoyo-winvideo): Node's timers on Windows tick every
 * 15.6 ms, too coarse to pace 60 pictures a second, so a precise wait is a `T <ms> <id>` to the helper (which runs at
 * 1 ms) and its 'T' record back; a setTimeout behind it stays as the backstop.
 */
export class VideoHelper {
  constructor({ path, fps, env, log, spawnFn = spawn, cursor = false }) {
    this.log = log;
    this.cursor = cursor;
    /** The 'P' records' receiver (a stream's CursorFeed). */
    this.onPointer = null;
    this.pointerSeen = false;
    const args = ["--fps", String(Math.round(fps)), ...(cursor ? ["--cursor", "client"] : [])];
    this.child = spawnFn(path, args, { stdio: ["pipe", "pipe", "pipe"], env });
    this.reader = new RecordReader();
    this.size = null;
    /** The helper answers `T <ms> <id>` with a 'T' record (its hello's flag). */
    this.timer = false;
    this.timerId = 0;
    /** Waits a 'T' record ends: a wait()'s (also in `waiters`) or a pause()'s. */
    this.timed = new Set();
    this.changeToken = 0;
    this.waiters = new Set();
    /** A wake() with nobody waiting: the next wait() returns at once (a cursor change between look and wait). */
    this.kicked = false;
    this.pending = [];
    this.exited = false;
    /** Its exit code once it exited (null: running, or killed by a signal). */
    this.exitCode = null;
    this.ready = new Promise((resolve, reject) => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (s) => {
      for (const line of s.split("\n")) if (line.trim()) this.log(`video helper: ${line.trim()}`);
    });
    this.child.stdin.on("error", () => {});
    this.child.stdout.on("data", (d) => {
      let recs;
      try {
        recs = this.reader.feed(d);
      } catch (err) {
        this.log(err.message);
        this.stop();
        return;
      }
      for (const r of recs) this.onRecord(r);
    });
    this.child.on("exit", (code, signal) => {
      this.exited = true;
      this.exitCode = code;
      this.readyReject(new Error(`the video helper exited (${signal ?? `code ${code}`})`));
      for (const p of this.pending.splice(0)) p.resolve(null);
      for (const w of [...this.timed]) w();
      this.wake();
    });
    this.child.on("error", (err) => {
      this.exited = true;
      this.readyReject(err);
    });
  }

  onRecord(r) {
    if (r.type === "H") {
      this.size = [r.width, r.height];
      this.timer = !!r.timer;
      if (!this.cursor || this.pointerSeen) this.readyResolve(this.size);
    } else if (r.type === "P") {
      this.onPointer?.(r);
      if (!this.pointerSeen) {
        this.pointerSeen = true;
        if (this.size) this.readyResolve(this.size);
      }
    } else if (r.type === "T") {
      // the timer asked for last (an earlier one was replaced: its waits ended, or the backstop ends them)
      if (r.id === this.timerId) for (const w of [...this.timed]) w();
    } else if (r.type === "C") {
      this.changeToken++;
      this.wake();
    } else if (r.type === "F" || r.type === "S") {
      this.pending.shift()?.resolve(r.type === "F" ? r : { type: "S" });
    }
  }

  /** Encode the screen now: a frame record, `{ type: "S" }` (skipped), or null (the helper is gone). */
  /** `buf`: the VBV buffer (kbit; default `kbps`), for a `kbps` scaled up per picture (the link's frame-rate cap). */
  encode(key, kbps, crf, buf = null) {
    if (this.exited) return Promise.resolve(null);
    return new Promise((resolve) => {
      this.pending.push({ resolve });
      const tail = buf != null ? ` ${Math.round(buf)}` : "";
      this.child.stdin.write(`E ${key ? 1 : 0} ${Math.round(kbps)} ${crf}${tail}\n`);
    });
  }

  /**
   * Resolves when something changed since `token`, `wake()` was called (since the last `clearKick()`), or after `ms` —
   * `precise`: to the millisecond where the helper keeps time (a picture's pace), else as Node's timers have it.
   */
  wait(token, ms, precise = false) {
    if (this.changeToken !== token || this.exited || this.kicked) return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(t);
        this.waiters.delete(done);
        this.timed.delete(done);
        resolve();
      };
      const t = setTimeout(done, this.askTimer(precise, ms, done));
      this.waiters.add(done);
    });
  }

  /** Resolves after `ms`, whatever changes meanwhile (precise where the helper keeps time). */
  pause(ms) {
    if (this.exited) return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(t);
        this.timed.delete(done);
        resolve();
      };
      const t = setTimeout(done, this.askTimer(true, ms, done));
    });
  }

  /** A precise wait of `ms` asked of the helper when it keeps time (`done` ends it); returns setTimeout's delay. */
  askTimer(precise, ms, done) {
    if (!precise || !this.timer || this.exited) return Math.max(precise ? 1 : 2, ms);
    this.timerId = (this.timerId + 1) >>> 0;
    this.timed.add(done);
    this.child.stdin.write(`T ${(Math.max(0, ms) + 0.2).toFixed(1)} ${this.timerId}\n`);
    return ms + 40;
  }

  wake() {
    this.kicked = true;
    for (const w of [...this.waiters]) w();
  }

  /** The loop is about to look at everything: earlier wake-ups are seen. */
  clearKick() {
    this.kicked = false;
  }

  stop() {
    if (this.exited) return;
    try {
      this.child.stdin.end("Q\n");
    } catch {}
    const t = setTimeout(() => this.child.kill("SIGKILL"), 2000);
    t.unref();
  }
}

/**
 * Serve one stream on `res` (an http.ServerResponse whose head is already written) until the client goes or the helper
 * stops (it exits on any capture or encoder failure: the stream ends normally and the client reopens). `o`: { helper,
 * wire, id, fps, status, maxKbps, displayId, log, clock, tuning, statsEvery, closed(), feed } — `feed`: the stream's
 * CursorFeed (`cursor=client`), whose changes wake the loop.
 */
export async function streamLoop(res, o) {
  const clock = o.clock ?? monotonic;
  const base = o.tuning ?? TUNING;
  const t = o.maxKbps != null ? limitedTuning(base, o.maxKbps, true) : base;
  const helper = o.helper;
  const interval = 1 / o.fps;
  const label = `video: stream ${o.id ?? "-"}`;
  const log = (l) => o.log(`${label} ${l}`);
  const flow = o.id ? new StreamFlow({ id: o.id, tuning: t, frameInterval: interval, clock, wake: () => helper.wake(), log }) : null;
  if (flow) flows.set(o.id, flow);
  const size = helper.size;
  let seq = 0;
  let shown = false;
  let lastPictureAt = -Infinity;
  let lastPictureStart = -Infinity;
  let lastKeyAt = -Infinity;
  let needKey = true;
  const refine = new RefineSchedule(t);
  let kbps = flow ? flow.c.bitrateKbps : t.startKbps;
  /** The change token the last grab saw (the helper reports a change once per grab). */
  let seenToken = -1;
  let limitedToken = null;
  const feed = o.feed ?? null;
  /** The cursor last sent, when, and the shape ids this stream sent (the client caches them by id). */
  let sentCursor = null;
  let lastCursorAt = -Infinity;
  const sentShapes = new Set();
  const win = { live: 0, refines: 0, keepalives: 0, keys: 0, drops: 0, encodeMs: [], bytes: 0, cursorParts: 0, start: clock() };

  const write = (buf) =>
    new Promise((resolve) => {
      if (res.destroyed || res.writableEnded) return resolve(false);
      res.write(buf, (err) => resolve(!err));
    });

  const stats = (now) => {
    const seconds = now - win.start;
    if (!o.statsEvery || seconds < o.statsEvery) return;
    const pics = win.live + win.refines + win.keepalives;
    const mean = win.encodeMs.length ? win.encodeMs.reduce((a, b) => a + b, 0) / win.encodeMs.length : 0;
    const c = flow?.c;
    let line = `stats: last ${seconds.toFixed(1)} s sent ${(pics / seconds).toFixed(1)} pics/s (live ${win.live} refine ${win.refines} keepalive ${win.keepalives} key ${win.keys} dropped ${win.drops}); encode ${mean.toFixed(1)}/${Math.max(0, ...win.encodeMs).toFixed(1)} ms (mean/max)${feed ? `; cursor parts ${win.cursorParts}` : ""}; flow h264 ${size[0]}px ${kbps}kbps ${Math.round(win.bytes / seconds / 1024)}KB/s`;
    if (c) {
      const qd = c.queueDelayMin;
      line += ` rtt ${c.srtt == null ? "-" : Math.round(c.srtt * 1000)}/${c.minRTT == null ? "-" : Math.round(c.minRTT * 1000)}ms qdmin ${qd == null ? "-" : Math.round(qd * 1000) + "ms"} downs ${c.counters.decreases}`;
      line += c.disabled ? " window off" : c.active ? ` win ${c.outstanding.length}/${c.window} limited ${c.counters.windowLimited}` : "";
    }
    if (flow?.report) line += `; phone ${playoutLine(flow.report)}`;
    log(line);
    Object.assign(win, { live: 0, refines: 0, keepalives: 0, keys: 0, drops: 0, encodeMs: [], bytes: 0, cursorParts: 0, start: now });
  };

  /** One cursor part, its shape when this stream hasn't sent that one yet (VideoStreamLoop.sendCursor). false = gone. */
  const sendCursor = async (c, shape, now) => {
    const withShape = shape && !sentShapes.has(shape.id) ? shape : null;
    const body = cursorBody(c, withShape);
    if (!(await write(streamPart({ boundary: o.wire.boundary, contentType: o.wire.cursor, body, seq: ++seq, time: Date.now(), kind: "cursor" })))) return false;
    if (withShape) {
      if (sentShapes.size >= SENT_SHAPES_MAX) sentShapes.clear();
      sentShapes.add(withShape.id);
    }
    sentCursor = c;
    lastCursorAt = now;
    win.bytes += body.length;
    win.cursorParts++;
    return true;
  };

  try {
    if (o.status) {
      const body = Buffer.from(JSON.stringify({ display: o.displayId, main: true, phase: "ready", since: Date.now(), console: { locked: false } }));
      if (!(await write(streamPart({ boundary: o.wire.boundary, contentType: o.wire.status, body, seq: ++seq, time: Date.now(), kind: "status" })))) return;
    }
    while (!o.closed() && !helper.exited) {
      helper.clearKick();
      const token = helper.changeToken;
      let now = clock();
      stats(now);
      let deadline = now + 0.25;
      let blockedUntil = null;
      if (flow) {
        if (flow.pendingKbps != null) {
          kbps = flow.pendingKbps;
          flow.pendingKbps = null;
        }
        if (flow.c.checkStall(now)) log(`no ack for ${t.disableAfter} s; flow-control window off for this stream`);
      }
      // 1. the pointer (cursor=client): before the first picture, then on changes, coalesced; never held by the window
      if (feed) {
        const { cursor: c, shape } = feed.current();
        const newShape = shape ? !sentShapes.has(shape.id) : false;
        if (c !== sentCursor || newShape) {
          if (now - lastCursorAt >= CURSOR_MIN_INTERVAL) {
            if (!(await sendCursor(c, shape, now))) break;
            now = clock();
          } else deadline = Math.min(deadline, lastCursorAt + CURSOR_MIN_INTERVAL);
        }
      }
      // 2. pictures: a change (or a key frame due), else a refine, else a keepalive
      const changed = token !== seenToken;
      const wantKey = needKey || (flow?.c.keyDue(now) ?? false) || now - lastKeyAt >= t.keyFloor;
      let want = null;
      if (changed || (wantKey && shown)) want = "live";
      else if (refine.isDue(now)) want = "refine";
      else if (shown && now - lastPictureAt >= t.keepalive) want = "keepalive";

      if (want) {
        const gap = interval - (now - lastPictureStart);
        if (want === "live" && gap > 0) {
          const ms = Math.min(gap, Math.max(0.001, deadline - now));
          // a cursor stream's pointer moves on during the wait (a wake-up ends it)
          if (feed && !helper.kicked) await helper.wait(helper.changeToken, ms * 1000, true);
          else if (!feed) await helper.pause(ms * 1000);
          continue;
        }
        let gate = "open";
        if (flow) {
          gate = flow.c.gate(now);
          if (typeof gate === "object" && limitedToken !== token) flow.c.noteWindowLimited(now);
          if (gate === "probe") flow.c.counters.probes++;
        }
        if (typeof gate === "object") {
          limitedToken = token;
          blockedUntil = gate.full;
          deadline = Math.min(deadline, gate.full);
        } else {
          // a refine always aims at the refine quality, and goes out at a temporarily higher rate unless the path is
          // queueing; never above the network profile's ceiling
          const congested = flow ? (flow.c.queueDelayMin ?? 0) > t.congestedDelay : false;
          const ceiling = flow ? flow.c.maxKbpsNow : t.maxKbps;
          const rate = want === "refine" ? refineKbps(t, { kbps, ceiling, congested }) : kbps;
          const start = clock();
          seenToken = helper.changeToken;
          const r = await helper.encode(wantKey, rate, want === "refine" ? CRF.refine : CRF.live);
          now = clock();
          if (r === null) break;
          if (r.type === "S") {
            win.drops++;
            lastPictureAt = now;
            lastPictureStart = now;
            // a skipped refine: one fewer left, and the picture is not settled yet
            if (want === "refine") refine.noteRefined(now, null, liveBudget(kbps, o.fps));
            continue;
          }
          win.encodeMs.push((now - start) * 1000);
          const isNew = r.changed;
          const kind = r.key ? "key" : isNew ? "delta" : want === "refine" ? "refine" : want === "keepalive" ? "keepalive" : "delta";
          const part = streamPart({ boundary: o.wire.boundary, contentType: "video/h264", body: r.au, size, seq: ++seq, time: r.time, kind, codec: "h264" });
          if (!(await write(part))) break;
          const done = clock();
          flow?.c.pictureSent(seq, done, part.length);
          win.bytes += part.length;
          lastPictureAt = done;
          lastPictureStart = start;
          if (r.key) {
            needKey = false;
            lastKeyAt = done;
            win.keys++;
            flow?.c.noteKeySent(done);
          }
          if (isNew) win.live++;
          else if (want === "refine") win.refines++;
          else win.keepalives++;
          if (isNew || want === "live") {
            shown = true;
            refine.noteLive(done);
          } else if (want === "refine") refine.noteRefined(done, r.au.length, liveBudget(kbps, o.fps));
          continue;
        }
      }
      now = clock();
      // picture deadlines (keepalive, refine, a deferred key frame) can't fire before the window reopens
      const floor = blockedUntil ?? now;
      if (shown) deadline = Math.min(deadline, Math.max(floor, lastPictureAt + t.keepalive), Math.max(floor, lastKeyAt + t.keyFloor));
      if (refine.dueAt != null) deadline = Math.min(deadline, Math.max(floor, refine.dueAt));
      if (flow) {
        const k = flow.c.keyDueAt;
        if (k != null) deadline = Math.min(deadline, Math.max(floor, k));
        const s = flow.c.stallDeadline();
        if (s != null) deadline = Math.min(deadline, s);
      }
      await helper.wait(token, Math.max(2, (deadline - now) * 1000));
    }
  } finally {
    if (flow && flows.get(o.id) === flow) flows.delete(o.id);
    if (flow?.quality) log(`ended; last phone net → ${flow.quality.value.grade}`);
  }
}
