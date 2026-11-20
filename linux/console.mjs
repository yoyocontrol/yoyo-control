// The Windows console's lock (docs/LOCAL-API.md「锁屏与解锁」, docs/PROTOCOL.md「Windows 服务端」): whether this session is
// locked — a long-running `yoyo-winwindows --session` says so now and on every change, whether or not anything is being
// captured — and the local API's POST /console/lock and /console/unlock.
//
// - Lock: `rundll32 user32.dll,LockWorkStation` in this (the user's) session, then wait for the watcher to see it.
// - Unlock: the password goes to an input helper started through the secure-desktop broker (SYSTEM in this session: the
//   only kind of process that can reach the sign-in screen, docs/BROKER.md) on its stdin, never in an argv or a log;
//   the helper types it there and answers (windows/wininput.c `unlock_flow`). One at a time; never retried.
import { createInterface } from "node:readline";

/** How long the watcher waits before it starts `--session` again after it ended. */
const WATCH_RETRY_MS = 5000;
/** The input helper's unlock: ≤ 0.6 + 1.3 s before typing, 40 ms a unit, ≤ 3 + 6 s after. */
const UNLOCK_TIMEOUT_MS = 30_000;
const LOCK_WAIT_MS = 3000;

/** A password the unlock takes: a string of 1…1024 UTF-16 units, no control characters. */
export function checkPassword(body) {
  const pw = body && typeof body === "object" ? body.password : undefined;
  if (typeof pw !== "string" || pw.length === 0) return "body needs password (a non-empty string)";
  if (pw.length > 1024) return "password is too long (max 1024 UTF-16 units)";
  for (let i = 0; i < pw.length; i++) {
    const c = pw.charCodeAt(i);
    if (c < 0x20 || c === 0x7f) return "password has a control character";
  }
  return null;
}

/** The helper's stdin line for a password: its UTF-16 units as `U<hex>` words. */
export function passwordLine(pw) {
  const words = [];
  for (let i = 0; i < pw.length; i++) words.push(`U${pw.charCodeAt(i).toString(16)}`);
  return `${words.join(" ")}\n`;
}

export class WindowsConsole {
  /**
   * `windowsHelper`: yoyo-winwindows.exe; `spawnFn`: node's spawn (this user's processes); `inputHelper()`: an input
   * helper through the broker, or null when the broker isn't ready (async); `onChange()`: the lock changed.
   */
  constructor({ windowsHelper, spawnFn, inputHelper, env = process.env, log = () => {}, onChange = () => {}, retryMs = WATCH_RETRY_MS, lockWaitMs = LOCK_WAIT_MS }) {
    this.windowsHelper = windowsHelper;
    this.spawn = spawnFn;
    this.inputHelper = inputHelper;
    this.env = env;
    this.log = log;
    this.onChange = onChange;
    this.retryMs = retryMs;
    this.lockWaitMs = lockWaitMs;
    /** true / false, or null while the watcher doesn't say. */
    this.locked = null;
    this.watcher = null;
    this.stopped = true;
    this.retry = null;
    this.queue = Promise.resolve();
  }

  start() {
    if (!this.stopped) return;
    this.stopped = false;
    this.watch();
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.retry);
    const w = this.watcher;
    this.watcher = null;
    w?.stdin?.end();
    w?.kill();
  }

  set(locked) {
    if (locked === this.locked) return;
    this.locked = locked;
    this.log(`console: ${locked === null ? "lock state unknown" : locked ? "locked" : "unlocked"}`);
    this.onChange();
  }

  watch() {
    let child;
    try {
      child = this.spawn(this.windowsHelper, ["--session"], { stdio: ["pipe", "pipe", "pipe"], env: this.env, windowsHide: true });
    } catch (err) {
      this.log(`console: the session watcher can't start (${err.message})`);
      return this.again();
    }
    this.watcher = child;
    child.on("error", (err) => this.log(`console: the session watcher: ${err.message}`));
    child.stdin?.on("error", () => {});
    child.stderr?.on("data", () => {});
    createInterface({ input: child.stdout }).on("line", (line) => {
      const m = /^L (locked|unlocked|unknown)$/.exec(line.trim());
      if (m) this.set(m[1] === "unknown" ? null : m[1] === "locked");
    });
    child.on("exit", (code) => {
      if (this.watcher !== child) return;
      this.watcher = null;
      if (this.stopped) return;
      this.log(`console: the session watcher exited (${code}); again in ${this.retryMs / 1000} s`);
      this.set(null);
      this.again();
    });
  }

  again() {
    if (this.stopped) return;
    this.retry = setTimeout(() => this.watch(), this.retryMs);
    this.retry.unref?.();
  }

  /** One after the other: a second request waits for the first, then looks again. */
  serial(fn) {
    const run = this.queue.then(fn, fn);
    this.queue = run.catch(() => {});
    return run;
  }

  lock() {
    return this.serial(async () => {
      if (this.locked === true) return { ok: true, locked: true, already: true };
      try {
        const p = this.spawn("rundll32.exe", ["user32.dll,LockWorkStation"], { stdio: "ignore", env: this.env, windowsHide: true });
        p.on("error", () => {});
      } catch {
        return { ok: false, locked: false, reason: "failed" };
      }
      const t0 = Date.now();
      while (Date.now() - t0 < this.lockWaitMs) {
        if (this.locked === true) {
          this.log(`console: locked in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
          return { ok: true, locked: true };
        }
        await new Promise((r) => setTimeout(r, 100));
      }
      return { ok: false, locked: false, reason: "timeout" };
    });
  }

  /** `pw`: a checked password (checkPassword). */
  unlock(pw) {
    return this.serial(async () => {
      if (this.locked === false) return { ok: true, unlocked: true, already: true };
      const child = await this.inputHelper();
      if (!child) return { ok: false, unlocked: false, reason: "no-secure-desktop" };
      const t0 = Date.now();
      const answer = await new Promise((resolve) => {
        let done = false;
        const finish = (r) => {
          if (done) return;
          done = true;
          clearTimeout(timer);
          resolve(r);
        };
        const timer = setTimeout(() => finish("timeout"), UNLOCK_TIMEOUT_MS);
        child.on("error", () => finish("failed"));
        child.on("exit", () => finish("failed"));
        child.stderr?.on("data", () => {});
        createInterface({ input: child.stdout }).on("line", (line) => {
          const m = /^unlock (\S+)$/.exec(line.trim());
          if (m) finish(m[1]);
        });
        child.stdin.on?.("error", () => {});
        child.stdin.write("unlock\n");
        child.stdin.write(passwordLine(pw));
      });
      child.stdin.end?.();
      child.kill?.();
      const s = ((Date.now() - t0) / 1000).toFixed(1);
      if (answer === "ok" || answer === "already") {
        this.log(answer === "ok" ? `console: unlocked in ${s} s` : "console: unlock: it was unlocked meanwhile");
        this.set(false);
        return { ok: true, unlocked: true, ...(answer === "already" ? { already: true } : {}) };
      }
      this.log(`console: unlock: ${answer === "wrong-password" ? "still locked after the password (wrong password?)" : answer} (${s} s)`);
      return { ok: false, unlocked: false, reason: answer };
    });
  }
}
