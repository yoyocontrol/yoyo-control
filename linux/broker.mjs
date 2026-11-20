// The secure-desktop broker's client (Windows; docs/BROKER.md): the video helper, its one-picture mode (/frame) and the
// input helper run through it as SYSTEM inside this user's session, so UAC's prompt and the sign-in screen are seen and
// driven like any other screen. A broker that isn't there (not installed, this user not allowed, not at the console)
// changes nothing: the helpers run as this user, as before (the secure desktop is then reported, not shown).
//
// One request per connection to the pipe: `yoyo-broker/1 <version> status | video <args…> | input | install <dir>\n`,
// then frames back — u8 kind, u32 BE length, bytes: 0 the answer (`ok …` / `err <reason>`), 1 stdout, 2 stderr, 3 the
// exit (u32 BE code); after the line, our bytes are the helper's stdin.
import { EventEmitter } from "node:events";
import { connect as netConnect } from "node:net";
import { PassThrough, Writable } from "node:stream";

export const DEFAULT_PIPE = "\\\\.\\pipe\\yoyo-broker";

/** Reasons the broker (or this client) gives; an open set. */
export const BROKER_REASONS = Object.freeze(["not-installed", "not-allowed", "not-user", "not-console", "no-version", "floor", "signature", "busy", "bad-request", "failed"]);

/** Frames off a byte stream. */
class FrameReader {
  constructor() {
    this.buf = Buffer.alloc(0);
  }
  feed(chunk) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    const out = [];
    while (this.buf.length >= 5) {
      const len = this.buf.readUInt32BE(1);
      if (this.buf.length < 5 + len) break;
      out.push({ kind: this.buf[0], body: this.buf.subarray(5, 5 + len) });
      this.buf = this.buf.subarray(5 + len);
    }
    return out;
  }
}

/**
 * A helper the broker started, shaped like the ChildProcess the server would have spawned: `stdin`, `stdout`, `stderr`,
 * `exitCode`, `killed`, `kill()`, and `error` / `exit` / `close` events. A refusal (`err <reason>`) is an `error`
 * (its `code` the reason) and then an exit with code 1.
 */
export class BrokerChild extends EventEmitter {
  constructor(socket, line, { onRefused } = {}) {
    super();
    this.socket = socket;
    this.exitCode = null;
    this.killed = false;
    this.started = false;
    this.stdout = new PassThrough();
    this.stderr = new PassThrough();
    this.stdin = new Writable({
      write: (chunk, _enc, cb) => {
        if (this.socket.destroyed) return cb();
        this.socket.write(chunk, () => cb());
      },
      // no half-close over the pipe: the helper's stdin ends with the connection
      final: (cb) => cb(),
    });
    const reader = new FrameReader();
    let done = false;
    // stderr in whole lines (the relay cuts the helper's unbuffered writes anywhere: "y" + "oyo-winvideo: …")
    let partial = "";
    const finish = (code) => {
      if (done) return;
      done = true;
      this.exitCode = code;
      this.stdout.end();
      if (partial) this.stderr.write(`${partial}\n`);
      this.stderr.end();
      this.emit("exit", code, null);
      // after stdout's last bytes were read
      setImmediate(() => this.emit("close", code, null));
    };
    socket.on("data", (d) => {
      for (const f of reader.feed(d)) {
        if (f.kind === 0) {
          const answer = f.body.toString("utf8");
          if (answer.startsWith("ok")) {
            this.started = true;
            continue;
          }
          const reason = /^err (\S+)/.exec(answer)?.[1] ?? "failed";
          onRefused?.(reason);
          const err = Object.assign(new Error(`the secure-desktop broker said no (${reason})`), { code: reason });
          this.emit("error", err);
          socket.destroy();
          finish(1);
        } else if (f.kind === 1) this.stdout.write(f.body);
        else if (f.kind === 2) {
          partial += f.body.toString("utf8");
          const cut = partial.lastIndexOf("\n");
          if (cut >= 0) {
            this.stderr.write(partial.slice(0, cut + 1));
            partial = partial.slice(cut + 1);
          }
        }
        else if (f.kind === 3 && f.body.length >= 4) {
          finish(f.body.readUInt32BE(0));
          socket.end();
        }
      }
    });
    socket.on("error", (err) => {
      if (!this.started && !done) {
        onRefused?.(err.code === "ENOENT" ? "not-installed" : "failed");
        this.emit("error", err);
      }
    });
    socket.on("close", () => finish(this.killed ? null : 1));
    socket.write(line);
  }

  kill() {
    if (this.exitCode !== null || this.killed) return false;
    this.killed = true;
    this.socket.destroy();
    return true;
  }
}

/**
 * The broker as this server sees it: `ready` once it answered that our version is installed (installing it from the
 * package's signed `broker\` folder when it isn't), else `reason`. Asked at start and again — at most every 10 s — when
 * a helper is about to start while it is not ready, or after it refused one.
 */
export class Broker {
  constructor({ version, packageDir, pipe = DEFAULT_PIPE, log = () => {}, connect = netConnect, retryMs = 10_000 }) {
    this.version = version;
    this.packageDir = packageDir;
    this.pipe = pipe;
    this.log = log;
    this.connect = connect;
    this.retryMs = retryMs;
    this.ready = false;
    this.reason = "not-installed";
    this.askedAt = 0;
    this.asking = null;
    this.onChange = null;
  }

  /** `/status.secureDesktopHelper`. */
  json() {
    return this.ready ? { ok: true, version: this.version } : { ok: false, reason: this.reason };
  }

  set(ready, reason) {
    const changed = ready !== this.ready || (!ready && reason !== this.reason);
    this.ready = ready;
    this.reason = ready ? null : reason;
    if (changed) {
      this.log(ready ? `secure-desktop broker: ready (${this.version})` : `secure-desktop broker: not used (${reason})`);
      this.onChange?.();
    }
  }

  /** One request, its answer line (`ok …` / `err <reason>`); a pipe that isn't there is `err not-installed`. */
  request(line) {
    return new Promise((resolve) => {
      const s = this.connect(this.pipe);
      const reader = new FrameReader();
      const timer = setTimeout(() => {
        s.destroy();
        resolve("err failed");
      }, 15_000);
      const done = (a) => {
        clearTimeout(timer);
        s.destroy();
        resolve(a);
      };
      s.on("data", (d) => {
        for (const f of reader.feed(d)) if (f.kind === 0) return done(f.body.toString("utf8"));
      });
      s.on("error", (err) => done(err.code === "ENOENT" ? "err not-installed" : "err failed"));
      s.on("close", () => done("err failed"));
      s.write(`yoyo-broker/1 ${this.version} ${line}\n`);
    });
  }

  /** Asks again unless it did within `retryMs` (`force`: now). */
  probe(force = false) {
    if (this.asking) return this.asking;
    if (!force && (this.ready || Date.now() - this.askedAt < this.retryMs)) return Promise.resolve(this.ready);
    this.askedAt = Date.now();
    this.asking = (async () => {
      try {
        for (let attempt = 0; attempt < 3; attempt++) {
          const a = await this.request("status");
          if (/^ok .*installed yes/.test(a)) return this.set(true), true;
          if (!a.startsWith("ok")) return this.set(false, reason(a)), false;
          // our version isn't there: from the package's signed folder
          if (!this.packageDir) return this.set(false, "no-version"), false;
          const r = await this.request(`install ${this.packageDir}`);
          if (!r.startsWith("ok")) return this.set(false, reason(r)), false;
          this.log(`secure-desktop broker: installed ${r.slice(3)}`);
          // a new broker restarts itself
          if (/restart/.test(r)) await new Promise((res) => setTimeout(res, 2000));
        }
        return this.set(false, "failed"), false;
      } finally {
        this.asking = null;
      }
    })();
    return this.asking;
  }

  /** A helper through the broker: `role` "video" (with the video helper's arguments) or "input". */
  spawn(role, args = []) {
    const s = this.connect(this.pipe);
    return new BrokerChild(s, `yoyo-broker/1 ${this.version} ${role}${args.length ? ` ${args.join(" ")}` : ""}\n`, {
      onRefused: (why) => {
        // a refusal or a broker gone: the next helpers run as this user until it answers again (busy is only now)
        if (why === "busy") return;
        this.set(false, why);
        this.askedAt = Date.now();
      },
    });
  }
}

function reason(answer) {
  return /^err (\S+)/.exec(answer)?.[1] ?? "failed";
}
