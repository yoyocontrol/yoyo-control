// Stand-ins for the processes yoyo-linux starts (the video, clipboard, sound and windows helpers, xdotool, ffmpeg), for
// tests without an X server.
import { EventEmitter } from "node:events";
import { PassThrough, Writable } from "node:stream";

/** One video helper record (the yoyo-x11video wire: type byte, u32 BE length, payload). */
export function record(type, payload = Buffer.alloc(0)) {
  const head = Buffer.alloc(5);
  head[0] = type.charCodeAt(0);
  head.writeUInt32BE(payload.length, 1);
  return Buffer.concat([head, payload]);
}

export const SPS = Buffer.from([0, 0, 0, 1, 0x67, 0x64, 0, 0x1f]);
export const PPS = Buffer.from([0, 0, 0, 1, 0x68, 0xee, 0x3c]);
export const IDR = Buffer.from([0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00]);
export const P = Buffer.from([0, 0, 0, 1, 0x41, 0x9a, 0x02]);

export function frameRecord({ key, changed, time = Date.now(), au, number = null }) {
  const head = Buffer.alloc(number === null ? 9 : 13);
  head[0] = (key ? 1 : 0) | (changed ? 2 : 0) | (number === null ? 0 : 4);
  head.writeDoubleLE(time, 1);
  if (number !== null) head.writeUInt32BE(number, 9);
  return record("F", Buffer.concat([head, au ?? (key ? Buffer.concat([SPS, PPS, IDR]) : P)]));
}

/** A 'P' record (yoyo-x11video --cursor client): the pointer at (x, y) px, its shape, the pixels when given. */
export function pointerRecord({ x = 10, y = 20, serial = 7, xhot = 1, yhot = 2, w = 4, h = 4, visible = true, none = false, pixels }) {
  const head = Buffer.alloc(17);
  head.writeInt16BE(x, 0);
  head.writeInt16BE(y, 2);
  head.writeUInt32BE(serial, 4);
  head.writeUInt16BE(xhot, 8);
  head.writeUInt16BE(yhot, 10);
  head.writeUInt16BE(w, 12);
  head.writeUInt16BE(h, 14);
  head[16] = (visible ? 1 : 0) | (pixels ? 2 : 0) | (none ? 4 : 0);
  return record("P", pixels ? Buffer.concat([head, pixels]) : head);
}

/** A w × h cursor of one premultiplied colour. */
export const solidCursor = (w, h, [r, g, b, a]) => Buffer.from(Array.from({ length: w * h }, () => [r, g, b, a]).flat());

/** yoyo-pa-opus's records: the hello, a packet (time, filled silence, Opus bytes). */
export function audioHello({ rate = 48000, channels = 2, frames = 960, lookahead = 312 } = {}) {
  const b = Buffer.alloc(10);
  b.writeUInt32BE(rate, 0);
  b.writeUInt16BE(channels, 4);
  b.writeUInt16BE(frames, 6);
  b.writeUInt16BE(lookahead, 8);
  return record("H", b);
}

export function audioRecord({ time, fill = false, data = Buffer.from([0xfc, 0xff, 0xfe]) }) {
  const head = Buffer.alloc(9);
  head.writeDoubleLE(time, 0);
  head[8] = fill ? 1 : 0;
  return record("A", Buffer.concat([head, data]));
}

/**
 * yoyo-x11clip stand-in: a hello and the clipboard as it is, then its commands (binary-safe: a header line, the bytes
 * it names): T / F own it (an own-write report, then "ok"), I answers with `state.clipPng`. `state.clipCopy(k)`: another
 * app copied (a 'K' report as given). Writes are kept in `state.clipWrites`.
 */
function fakeClipHelper(state) {
  const p = new EventEmitter();
  p.stdout = new PassThrough();
  p.stderr = new PassThrough();
  p.exitCode = null;
  let buf = Buffer.alloc(0);
  let reports = 0;
  const emit = (type, payload) => {
    if (type === "K") reports++;
    p.stdout.write(record(type, Buffer.from(payload)));
  };
  p.stdin = new Writable({
    write(chunk, _enc, cb) {
      buf = Buffer.concat([buf, chunk]);
      for (;;) {
        const nl = buf.indexOf(10);
        if (nl < 0) break;
        const head = buf.subarray(0, nl).toString();
        const nums = head.split(" ").slice(1, 5).map(Number);
        const need = head[0] === "T" ? nums[0] : head[0] === "F" ? nums.reduce((a, b) => a + b, 0) : 0;
        if (buf.length < nl + 1 + need) break;
        const body = buf.subarray(nl + 1, nl + 1 + need);
        buf = buf.subarray(nl + 1 + need);
        if (head === "Q") return (cb(), p.exit(0));
        if (head === "I") {
          const ord = Buffer.alloc(4);
          ord.writeUInt32BE(reports, 0);
          emit("I", Buffer.concat([ord, state.clipPng ?? Buffer.alloc(0)]));
        }
        else if (head[0] === "T" || head[0] === "F") {
          state.clipWrites.push({ head, body: Buffer.from(body) });
          if (state.clipRefuse) emit("W", "another program holds the clipboard");
          else {
            emit("K", JSON.stringify({ own: true, owner: true }));
            emit("W", "ok");
          }
        }
      }
      cb();
    },
    final(cb) {
      cb();
      p.exit(0);
    },
  });
  p.exit = (code = 0, signal = null) => {
    if (p.exitCode !== null) return;
    p.exitCode = code;
    p.stdout.end();
    p.stderr.end();
    setImmediate(() => p.emit("exit", code, signal));
  };
  p.kill = (sig = "SIGTERM") => (p.exit(null, sig), true);
  p.report = (json) => emit("K", json);
  setImmediate(() => {
    emit("H", "");
    emit("K", JSON.stringify(state.clipStart ?? { own: false, owner: false, targets: [] }));
  });
  return p;
}

/** A child process stand-in: stdin lines are given to `onLine(line, proc)`; stdout / stderr are PassThroughs. */
export function fakeProcess(onLine = () => {}) {
  const p = new EventEmitter();
  p.stdout = new PassThrough();
  p.stderr = new PassThrough();
  p.exitCode = null;
  p.killed = false;
  p.lines = [];
  let buf = "";
  p.stdin = new Writable({
    write(chunk, _enc, cb) {
      buf += chunk.toString();
      for (let i = buf.indexOf("\n"); i >= 0; i = buf.indexOf("\n")) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        p.lines.push(line);
        onLine(line, p);
      }
      cb();
    },
    final(cb) {
      if (buf) onLine(buf, p);
      cb();
      p.exit(0);
    },
  });
  p.exit = (code = 0, signal = null) => {
    if (p.exitCode !== null) return;
    p.exitCode = code;
    p.stdout.end();
    p.stderr.end();
    setImmediate(() => {
      p.emit("exit", code, signal);
      p.emit("close", code, signal);
    });
  };
  p.kill = (sig = "SIGTERM") => {
    p.killed = true;
    p.exit(null, sig);
    return true;
  };
  return p;
}

/**
 * spawn() for YoyoLinux: the video helper (hello 1280 x 832, a change, a frame per E — a key when asked), xdotool
 * (its lines kept in `xdotool`), ffmpeg (a 4-byte "JPEG"). `screenChanges(n)` makes the running helpers report a change.
 * `state.refs = true`: the next helpers keep earlier pictures as yoyo-x11video does (the hello's flag, numbered frames,
 * `I <n>` kept in `forgets`; a picture after forgetting more than the 16 kept is a key frame).
 */
export function fakeSpawn({ width = 1280, height = 832 } = {}) {
  // `size`: what the next helper's hello says; `noDisplay`: the next helpers can't open it (exit 1 before the hello);
  // `ffmpegMs`: how long a frame capture takes (`ffmpegRunning` / `ffmpegMax`: at once, now / at most)
  // `pointer`: the pointer the next cursor helpers report first (their 'P' after the hello)
  const state = { xdotool: [], xdotools: [], helpers: [], encodes: [], ffmpegArgs: [], size: [width, height], noDisplay: false, ffmpegMs: 0, ffmpegRunning: 0, ffmpegMax: 0, audioSpawns: [], audioHelpers: [], audioFails: false, clipHelpers: [], clipWrites: [], clipPng: null, clipStart: null, clipRefuse: false, windows: { screen: [width, height], active: 0, windows: [] }, windowsRuns: 0, windowsFail: false, escWatches: [], escFails: false, refs: false, forgets: [], pointer: { x: 640, y: 416, serial: 7, xhot: 1, yhot: 2, w: 4, h: 4 } };
  const spawn = (path, args) => {
    if (path.endsWith("yoyo-x11video") && state.noDisplay) {
      const p = fakeProcess();
      setImmediate(() => {
        p.stderr.write("yoyo-x11video: cannot open the display ($DISPLAY / $XAUTHORITY)\n");
        p.exit(1);
      });
      state.helpers.push(p);
      return p;
    }
    if (path.endsWith("yoyo-x11video")) {
      const p = fakeProcess((line, proc) => {
        if (line === "Q") return proc.exit(0);
        const forget = /^I (\d+)$/.exec(line);
        if (forget && proc.refs) {
          state.forgets.push(Number(forget[1]));
          // nothing kept is as old as the picture before it: a key frame next
          if (proc.number - Number(forget[1]) >= 16) proc.keyNext = true;
          return;
        }
        // E <key> <kbps> <crf> [<buf>] (buf: the VBV buffer in kbit)
        const m = /^E (\d) (\d+) ([\d.]+)(?: (\d+))?$/.exec(line);
        if (!m) return;
        const key = m[1] === "1" || proc.keyNext;
        proc.keyNext = false;
        state.encodes.push({ key, kbps: Number(m[2]), crf: Number(m[3]), buf: m[4] != null ? Number(m[4]) : null });
        proc.stdout.write(frameRecord({ key, changed: proc.dirty, number: proc.refs ? proc.number : null }));
        proc.number++;
        proc.dirty = false;
      });
      p.args = args;
      p.dirty = true;
      p.refs = state.refs;
      p.number = 0;
      p.keyNext = false;
      p.cursor = args.includes("--cursor");
      const hello = Buffer.alloc(p.refs ? 5 : 4);
      hello.writeUInt16BE(state.size[0], 0);
      hello.writeUInt16BE(state.size[1], 2);
      if (p.refs) hello[4] = 2;
      setImmediate(() => {
        p.stdout.write(record("H", hello));
        // the pointer right after the hello (its pixels: the first time this helper sees the serial)
        if (p.cursor) p.stdout.write(pointerRecord({ ...state.pointer, pixels: solidCursor(state.pointer.w, state.pointer.h, [100, 50, 0, 200]) }));
        p.stdout.write(record("C"));
      });
      state.helpers.push(p);
      return p;
    }
    if (path.endsWith("yoyo-x11windows") && args.includes("--esc")) {
      // the Escape watch: "H" once listening (not when `escFails`: no XInput 2), "E" per `pressEscape()`
      const p = fakeProcess();
      p.args = args;
      state.escWatches.push(p);
      setImmediate(() => {
        if (state.escFails) {
          p.stderr.write("yoyo-x11windows: no XInput 2\n");
          return p.exit(1);
        }
        p.stdout.write("H\n");
      });
      return p;
    }
    if (path.endsWith("yoyo-x11windows")) {
      // one shot: `state.windows` as the helper's JSON (`windowsFail`: it can't open the display)
      state.windowsRuns++;
      const p = fakeProcess();
      setImmediate(() => {
        if (state.windowsFail) {
          p.stderr.write("yoyo-x11windows: cannot open the display ($DISPLAY / $XAUTHORITY)\n");
          return p.exit(1);
        }
        p.stdout.write(JSON.stringify(state.windows));
        p.exit(0);
      });
      return p;
    }
    if (path.endsWith("yoyo-x11clip")) {
      const p = fakeClipHelper(state);
      state.clipHelpers.push(p);
      return p;
    }
    if (path.endsWith("yoyo-pa-opus")) {
      state.audioSpawns.push(args);
      const p = fakeProcess();
      if (state.audioFails) {
        setImmediate(() => {
          p.stderr.write("yoyo-pa-opus: PulseAudio: Connection refused\n");
          p.exit(1);
        });
        return p;
      }
      setImmediate(() => p.stdout.write(audioHello()));
      if (args.includes("--probe")) {
        setImmediate(() => p.exit(0));
        return p;
      }
      // a packet every 20 ms on its own timeline, until stdin ends or it is killed
      const t0 = Date.now();
      let i = 0;
      const timer = setInterval(() => {
        if (p.exitCode !== null) return clearInterval(timer);
        p.stdout.write(audioRecord({ time: t0 + i * 20 - 6.5, fill: i < 2 }));
        i++;
      }, 20);
      p.on("exit", () => clearInterval(timer));
      state.audioHelpers.push(p);
      return p;
    }
    if (path === "xdotool") {
      const own = [];
      state.xdotools.push(own);
      return fakeProcess((line) => (state.xdotool.push(line), own.push(line)));
    }
    if (path === "ffmpeg") {
      state.ffmpegArgs.push(args);
      state.ffmpegRunning++;
      state.ffmpegMax = Math.max(state.ffmpegMax, state.ffmpegRunning);
      const p = fakeProcess();
      setTimeout(() => {
        state.ffmpegRunning--;
        p.stdout.write(Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
        p.exit(0);
      }, state.ffmpegMs);
      return p;
    }
    throw new Error(`unexpected spawn ${path}`);
  };
  state.screenChanges = () => {
    for (const h of state.helpers) {
      if (h.exitCode !== null) continue;
      h.dirty = true;
      h.stdout.write(record("C"));
    }
  };
  /** Escape at the keyboard: the running Escape watches say so. */
  state.pressEscape = () => {
    for (const p of state.escWatches) if (p.exitCode === null) p.stdout.write("E\n");
  };
  /** Another app copied: the running clipboard helper reports it. */
  state.clipCopy = (k) => {
    for (const h of state.clipHelpers) if (h.exitCode === null) h.report(JSON.stringify({ own: false, owner: true, ...k }));
  };
  /** The running cursor helpers report the pointer (a 'P'; `pixels` when given). */
  state.pointerMoves = (rec) => {
    for (const h of state.helpers) if (h.exitCode === null && h.cursor) h.stdout.write(pointerRecord({ ...state.pointer, ...rec }));
  };
  return { spawn, state };
}

/** Parse multipart bytes (as yoyo-linux writes them) into parts: { headers, body }. */
export function parseParts(buf) {
  const parts = [];
  let rest = buf;
  for (;;) {
    const he = rest.indexOf("\r\n\r\n");
    if (he < 0) break;
    const head = rest.subarray(0, he).toString("latin1");
    const lines = head.split("\r\n");
    const headers = {};
    for (const l of lines.slice(1)) {
      const i = l.indexOf(":");
      headers[l.slice(0, i).toLowerCase()] = l.slice(i + 1).trim();
    }
    const len = Number(headers["content-length"]);
    if (rest.length < he + 4 + len + 2) break;
    parts.push({ boundary: lines[0], headers, body: rest.subarray(he + 4, he + 4 + len) });
    rest = rest.subarray(he + 4 + len + 2);
  }
  return parts;
}
