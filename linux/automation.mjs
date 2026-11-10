// `POST /automation { active, label? }` (and `/agent-control`, its older name; the Mac's Automation.swift): a local
// program says it is driving the desktop. No border is drawn here. While active, an Escape pressed at a keyboard of
// this X display (not posted through XTEST — the server's own /input and the phones' keys are) ends it and writes
// `{"type":"abort","reason":"esc"}` to /events: `yoyo-x11windows --esc` watches XInput 2 raw key presses. The key is not
// swallowed (nothing is grabbed): the app in front gets the Escape too. `esc` says whether the watch is in.
import { spawn } from "node:child_process";
import { InputError } from "./input.mjs";

export const AUTOMATION = Object.freeze({
  /** Longest label kept (characters). */
  maxLabel: 40,
  /** How long `active: true` waits for the Escape watch to say it listens before answering `esc: false`. */
  helloMs: 1000,
});

const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** The body `{ active, label?, title? }` → `{ active, label }`; 400 when malformed. `title` is accepted, not used. */
export function parseAutomation(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new InputError("body must be a JSON object");
  if (typeof body.active !== "boolean") throw new InputError("active must be a boolean");
  if (body.title != null && typeof body.title !== "string") throw new InputError("title must be a string");
  if (body.label != null && typeof body.label !== "string") throw new InputError("label must be a string");
  // one line of printable text: control characters (newlines too) become spaces, runs of them one
  const words = (body.label ?? "").replace(/\p{Cc}/gu, " ").split(" ").filter(Boolean).join(" ");
  const label = [...segmenter.segment(words)].slice(0, AUTOMATION.maxLabel).map((s) => s.segment).join("");
  return { active: body.active, label };
}

export class Automation {
  /** `path`: yoyo-x11windows; `onAbort()`: the user pressed Escape while active (already off by then). */
  constructor({ path, env, spawnFn = spawn, log = () => {}, onAbort = () => {}, helloMs = AUTOMATION.helloMs }) {
    this.path = path;
    this.env = env;
    this.spawn = spawnFn;
    this.log = log;
    this.onAbort = onAbort;
    this.helloMs = helloMs;
    this.active = false;
    this.label = "";
    this.esc = false;
    /** The running Escape watch (only ever while active). */
    this.watch = null;
  }

  /** `/status.automation` and the answer's fields. */
  get json() {
    return { active: this.active, esc: this.esc, ...(this.label ? { label: this.label } : {}) };
  }

  /** `POST /automation`: on → the watch started (waits for its hello, ≤ helloMs); off → stopped. Same value: nothing. */
  async set(active, label) {
    if (active && !this.active) {
      this.active = true;
      this.label = label;
      this.log(`automation: on${label ? ` (${label})` : ""}`);
      const ok = await this.startWatch();
      // (turned off, or the watch gone, while it started)
      this.esc = ok && this.active && this.watch !== null;
    } else if (!active && this.active) {
      this.log("automation: off");
      this.stop();
    } else if (active) {
      this.label = label;
    }
    return this.json;
  }

  stop() {
    this.active = false;
    this.label = "";
    this.esc = false;
    const w = this.watch;
    this.watch = null;
    if (w) {
      w.stdin?.end();
      w.kill("SIGTERM");
    }
  }

  /** Starts `yoyo-x11windows --esc`; true once it says "H" (it listens), false when it can't (no XInput 2, no helper). */
  startWatch() {
    return new Promise((resolve) => {
      let p;
      try {
        p = this.spawn(this.path, ["--esc"], { stdio: ["pipe", "pipe", "pipe"], env: this.env });
      } catch (err) {
        this.log(`automation: no Escape watch: ${err.message}`);
        return resolve(false);
      }
      this.watch = p;
      let settled = false;
      const settle = (ok) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(ok);
      };
      const timer = setTimeout(() => {
        this.log("automation: the Escape watch did not start in time");
        settle(false);
      }, this.helloMs);
      p.stdin?.on("error", () => {});
      p.stderr.setEncoding("utf8");
      p.stderr.on("data", (s) => {
        for (const l of s.split("\n")) if (l.trim()) this.log(`automation: ${l.trim()}`);
      });
      let buf = "";
      p.stdout.setEncoding("utf8");
      p.stdout.on("data", (s) => {
        buf += s;
        for (let i = buf.indexOf("\n"); i >= 0; i = buf.indexOf("\n")) {
          const line = buf.slice(0, i);
          buf = buf.slice(i + 1);
          if (line === "H") settle(true);
          else if (line === "E" && this.watch === p && this.active) {
            this.log("automation: Escape pressed: off");
            this.stop();
            this.onAbort();
          }
        }
      });
      p.on("error", (err) => {
        this.log(`automation: no Escape watch: ${err.message}`);
        settle(false);
      });
      p.on("exit", (code, signal) => {
        settle(false);
        if (this.watch !== p) return;
        this.watch = null;
        this.esc = false;
        this.log(`automation: the Escape watch exited (${signal ?? `code ${code}`})`);
      });
    });
  }
}
