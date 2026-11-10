// The clipboard (README.md「剪贴板」; the protocol's「剪贴板」, the reference server's Clipboard.swift / Router.swift):
// GET /clipboard[?text=0], GET /clipboard/image, GET /clipboard/file?index=N, POST /clipboard, and the `clipboard`
// lines of /events — over yoyo-x11clip, which watches the X CLIPBOARD selection (event-driven) and owns it (and
// PRIMARY) for writes. `changeCount` starts at 1 and only grows within a process: one per change the helper reports.
// `at` is when this process first saw that count; `source` marks counts this process's own POST made.
//
// Platform differences from the Mac (README.md): nothing is ever `concealed` except KeePassXC-style items
// (x-kde-passwordManagerHint; on Windows a password manager's ExcludeClipboardContentFromMonitorProcessing); on X the
// clipboard empties when the app that copied exits (X has no clipboard of its own; no clipboard manager runs); an
// image is one only when its owner offers image/png (Windows' helper encodes a copied bitmap as PNG). On Windows the
// same protocol runs over yoyo-winclip (windows/winclip.c); paths are Windows paths there.
import { spawn } from "node:child_process";
import { createReadStream } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { basename, extname, isAbsolute } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { InputError } from "./input.mjs";

export const CLIP = Object.freeze({
  previewMax: 160,
  filesMax: 20,
  /** 1 MiB of text either way. */
  textMax: 1_048_576,
  /** A single image file larger than this goes on the clipboard as a file only (no image data). */
  imageMax: 64 * 1024 * 1024,
  /** How long a write may wait for the helper. */
  writeTimeoutMs: 3000,
  /** The helper started again this long after it exited (no X yet, X restarted). */
  restartMs: 2000,
});

/** The first 160 characters, newline runs shown as "⏎ ", "…" when cut (Clipboard.preview). */
export function clipPreview(text) {
  const head = [...text.slice(0, CLIP.previewMax * 8 * 2)].slice(0, CLIP.previewMax * 8).join("");
  const flat = head
    .split(/[\n\r\u000b\u000c\u0085\u2028\u2029]+/)
    .map((l) => l.trim())
    .filter(Boolean)
    .join("⏎ ");
  return cutPreview(flat);
}

const cutPreview = (s) => {
  const chars = [...s];
  return chars.length > CLIP.previewMax ? `${chars.slice(0, CLIP.previewMax - 1).join("")}…` : s;
};

/** `text` cut to `max` bytes of UTF-8 at a character boundary (Clipboard.clipText). */
export function clipText(text, max = CLIP.textMax) {
  const b = Buffer.from(text, "utf8");
  if (b.length <= max) return { text, truncated: false };
  let cut = max;
  while (cut > 0 && (b[cut] & 0xc0) === 0x80) cut--;
  return { text: b.subarray(0, cut).toString("utf8"), truncated: true };
}

/** A text/uri-list (or x-special/gnome-copied-files) → the local paths of its file: URIs. */
export function parseUriList(s, win32 = process.platform === "win32") {
  const out = [];
  for (const raw of s.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#") || line === "copy" || line === "cut") continue;
    let u;
    try {
      u = new URL(line);
    } catch {
      continue;
    }
    if (u.protocol !== "file:") continue;
    // Windows: file:///C:/x → C:\x, file://server/share/x → \\server\share\x
    if (win32) {
      try {
        out.push(fileURLToPath(u, { windows: true }));
      } catch {}
      continue;
    }
    if (u.hostname && u.hostname !== "localhost") continue;
    try {
      out.push(decodeURIComponent(u.pathname));
    } catch {}
  }
  return out;
}

/** A path as a file: URI (each segment percent-encoded). */
export const fileUri = (path, win32 = process.platform === "win32") =>
  win32 ? pathToFileURL(path, { windows: true }).href : `file://${path.split("/").map(encodeURIComponent).join("/")}`;

/** Formats a password manager marks its copies with: the item is `concealed` (never read, never shown). */
const CONCEALED = ["x-kde-passwordManagerHint", "ExcludeClipboardContentFromMonitorProcessing"];

const MIME = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  heic: "image/heic",
  pdf: "application/pdf",
  txt: "text/plain",
  md: "text/markdown",
  html: "text/html",
  json: "application/json",
  csv: "text/csv",
  zip: "application/zip",
  mp4: "video/mp4",
  mov: "video/quicktime",
  mp3: "audio/mpeg",
  m4a: "audio/mp4",
};

/** `Content-Type` by extension (best effort). */
export const mimeOf = (path) => MIME[extname(path).slice(1).toLowerCase()] ?? "application/octet-stream";
/** The image type a single image file also goes on the clipboard as (Clipboard.imageType), by extension. */
export const imageTypeOf = (path) => {
  const m = MIME[extname(path).slice(1).toLowerCase()];
  return m?.startsWith("image/") ? m : null;
};

async function fileInfo(path) {
  const name = basename(path);
  try {
    const s = await stat(path);
    return { name, size: s.isDirectory() ? null : s.size, dir: s.isDirectory() };
  } catch {
    return { name, size: null, dir: false };
  }
}

/**
 * The clipboard over one yoyo-x11clip (started with the service, started again 2 s after it exits). `running`:
 * its hello came (`/status` `features.clipboard`). `onChange(summary)`: every new changeCount (/events lines).
 */
export class Clipboard {
  constructor({ path, env, log, spawnFn = spawn, onChange = () => {}, now = () => Date.now(), restartMs = CLIP.restartMs }) {
    this.path = path;
    this.env = env;
    this.log = log;
    this.spawn = spawnFn;
    this.onChange = onChange;
    this.now = now;
    this.restartMs = restartMs;
    this.child = null;
    this.running = false;
    this.stopped = false;
    this.changeCount = 0;
    /** The current item: summary fields plus `text` / `paths` (null before the helper's first report). */
    this.item = null;
    /** A write's source, waiting for the helper's own-write report; the waiters of writes and of a PNG. */
    this.pendingWrite = null;
    this.pngWaiters = [];
    this.png = null; // { changeCount, data }
    this.failures = 0;
    this.kBase = 0;
    this.queue = Promise.resolve();
  }

  start() {
    if (this.stopped || this.child) return;
    let child;
    try {
      child = this.spawn(this.path, [], { stdio: ["pipe", "pipe", "pipe"], env: this.env });
    } catch (err) {
      this.log(`clipboard: cannot start the X helper: ${err.message}`);
      return this.again();
    }
    this.child = child;
    let buf = Buffer.alloc(0);
    child.stdin.on("error", () => {});
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (s) => {
      for (const l of s.split("\n")) if (l.trim()) this.log(`clipboard helper: ${l.trim()}`);
    });
    child.stdout.on("data", (d) => {
      buf = buf.length ? Buffer.concat([buf, d]) : d;
      while (buf.length >= 5) {
        const len = buf.readUInt32BE(1);
        if (buf.length < 5 + len) break;
        const type = String.fromCharCode(buf[0]);
        const body = Buffer.from(buf.subarray(5, 5 + len));
        buf = buf.subarray(5 + len);
        // in order (a report's summary may stat files): changeCounts follow the helper's reports
        this.queue = this.queue.then(() => this.onRecord(type, body)).catch((err) => this.log(`clipboard: ${err.stack ?? err}`));
      }
    });
    child.on("error", (err) => this.log(`clipboard: the X helper: ${err.message}`));
    child.on("exit", (code, signal) => {
      if (this.child !== child) return;
      this.child = null;
      const was = this.running;
      this.running = false;
      this.failPending(new InputError("the desktop's clipboard helper stopped", 503));
      if (!this.stopped) {
        if (was || this.failures++ < 3) this.log(`clipboard: the X helper exited (${signal ?? `code ${code}`}); starting it again in ${this.restartMs / 1000} s`);
        this.again();
      }
    });
  }

  again() {
    if (this.stopped) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.start(), this.restartMs);
    this.timer.unref?.();
  }

  stop() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.failPending(new InputError("shutting down", 503));
    try {
      this.child?.stdin.end("Q\n");
    } catch {}
    this.child?.kill("SIGTERM");
    this.child = null;
    this.running = false;
  }

  failPending(err) {
    this.pendingWrite?.reject(err);
    this.pendingWrite = null;
    for (const w of this.pngWaiters.splice(0)) w.reject(err);
  }

  async onRecord(type, body) {
    if (type === "H") {
      this.running = true;
      this.failures = 0;
      // this helper counts its reports from 0: its nth is changeCount kBase + n
      this.kBase = this.changeCount;
      return;
    }
    if (type === "W") {
      const msg = body.toString();
      if (msg !== "ok" && this.pendingWrite) {
        this.pendingWrite.reject(new InputError(msg, 503));
        this.pendingWrite = null;
      }
      return;
    }
    if (type === "I") {
      // the PNG of the item the helper had reported last when it answered: another than asked for = it changed
      const w = this.pngWaiters.shift();
      if (!w) return;
      const of = body.length >= 4 ? this.kBase + body.readUInt32BE(0) : -1;
      if (of !== w.changeCount) w.reject(new InputError("the clipboard changed; fetch it again", 409));
      else w.resolve(body.subarray(4));
      return;
    }
    if (type === "K") return this.changed(JSON.parse(body.toString("utf8")));
  }

  /** The helper's report of a change → the next changeCount, its summary built (files stat-ed here). */
  async changed(k) {
    const at = this.now();
    let item;
    if (k.own) {
      const w = this.pendingWrite;
      item = w ? { ...(await this.summarize(w.content)), source: w.source } : { kind: "other", preview: "", size: null };
    } else item = await this.summarize(this.fromHelper(k));
    const changeCount = ++this.changeCount;
    this.item = { changeCount, ...item, at };
    this.png = null;
    if (k.own && this.pendingWrite) {
      this.pendingWrite.resolve(this.item);
      this.pendingWrite = null;
    }
    this.onChange(this.summary());
  }

  /** What the helper's report holds → the content to summarize (kind by the protocol's order). */
  fromHelper(k) {
    if (!k.owner) return { kind: "empty" };
    const targets = k.targets ?? [];
    if (CONCEALED.some((t) => targets.includes(t))) return { kind: "concealed" };
    if (typeof k.uris === "string") {
      const paths = parseUriList(k.uris);
      if (paths.length) return { kind: "files", paths };
    }
    if (k.png) return { kind: "image", png: k.png };
    if (typeof k.text === "string") return { kind: "text", text: k.text, textSize: k.textSize, textCut: k.textCut };
    if (targets.some((t) => t.startsWith("image/")) && !this.loggedImageType) {
      this.loggedImageType = true;
      this.log(`clipboard: an image without image/png (${targets.filter((t) => t.startsWith("image/")).join(", ")}): reported as other`);
    }
    return { kind: targets.length ? "other" : "empty" };
  }

  /** A summary (ClipboardItem without changeCount / at) of some content. */
  async summarize(c) {
    switch (c.kind) {
      case "text": {
        const size = c.textSize ?? Buffer.byteLength(c.text);
        return { kind: "text", preview: clipPreview(c.text), size, text: c.text, cut: c.textCut === true };
      }
      case "image":
        return { kind: "image", preview: "", size: c.png.size, width: c.png.width, height: c.png.height };
      case "files": {
        const infos = await Promise.all(c.paths.map(fileInfo));
        const listed = infos.slice(0, CLIP.filesMax);
        const sizes = infos.filter((f) => f.size != null).map((f) => f.size);
        return {
          kind: "files",
          preview: cutPreview(listed.map((f) => f.name).join(", ")),
          size: sizes.length ? sizes.reduce((a, b) => a + b, 0) : null,
          files: listed,
          ...(infos.length > CLIP.filesMax ? { moreFiles: infos.length - CLIP.filesMax } : {}),
          paths: c.paths,
        };
      }
      default:
        return { kind: c.kind, preview: "", size: null };
    }
  }

  /** The `/events` line's ClipboardSummary of the current item (never the text). */
  summary() {
    const i = this.item;
    if (!i) return null;
    const s = { changeCount: i.changeCount, kind: i.kind, preview: i.preview, size: i.size, at: i.at };
    if (i.width != null) s.width = i.width;
    if (i.height != null) s.height = i.height;
    if (i.files) s.files = i.files;
    if (i.moreFiles) s.moreFiles = i.moreFiles;
    if (i.source) s.source = i.source;
    return s;
  }

  /** GET /clipboard: the item (+ its text, ≤ 1 MiB, unless `withText` is false). 503 without the helper. */
  read(withText = true) {
    this.ready();
    const s = this.summary() ?? { changeCount: this.changeCount, kind: "empty", preview: "", size: null, at: this.now() };
    const i = this.item;
    if (withText && i?.kind === "text") {
      const { text, truncated } = clipText(i.text);
      s.text = text;
      if (truncated || i.cut) s.truncated = true;
    }
    return { ...s, ok: true };
  }

  ready() {
    if (!this.running) throw new InputError("the desktop's clipboard is not available (its X helper is not running)", 503);
  }

  /** GET /clipboard/image: the image item's PNG (asked of the helper once per changeCount). */
  async image() {
    this.ready();
    const i = this.item;
    if (i?.kind !== "image") throw new InputError(i?.kind === "concealed" ? "the clipboard's content is hidden by a password manager" : "the clipboard holds no image", 404);
    if (this.png?.changeCount === i.changeCount) return { data: this.png.data, changeCount: i.changeCount };
    const data = await new Promise((resolve, reject) => {
      this.pngWaiters.push({ resolve, reject, changeCount: i.changeCount });
      this.child.stdin.write("I\n");
    });
    if (!data.length) throw new InputError("the clipboard holds no image", 404);
    if (this.item?.changeCount === i.changeCount) this.png = { changeCount: i.changeCount, data };
    return { data, changeCount: i.changeCount };
  }

  /** GET /clipboard/file?index=N: file N of a files item (its path, info, mime). */
  async file(index) {
    this.ready();
    const i = this.item;
    if (i?.kind !== "files") throw new InputError("the clipboard holds no files", 404);
    if (!Number.isInteger(index) || index < 0 || index >= i.paths.length) throw new InputError(`no file ${index} on the clipboard`, 404);
    const path = i.paths[index];
    const info = await fileInfo(path);
    if (info.dir) throw new InputError(`${info.name} is a folder; copy its contents`, 400);
    if (info.size == null) throw new InputError(`${info.name} is no longer there`, 404);
    return { path, ...info, mime: mimeOf(path), changeCount: i.changeCount };
  }

  /**
   * POST /clipboard `{ text }` or `{ files: ["/abs/path"…], source? }` (source "phone" by default): the clipboard
   * replaced (CLIPBOARD and PRIMARY), that changeCount's source remembered; answers like GET /clipboard.
   */
  async write(body) {
    this.ready();
    if (!body || typeof body !== "object" || Array.isArray(body)) throw new InputError("body must be a JSON object");
    const source = body.source ?? "phone";
    if (source !== "phone" && source !== "agent") throw new InputError('source must be "phone" or "agent"');
    let content;
    let command;
    if (typeof body.text === "string") {
      if (!body.text) throw new InputError("text is empty");
      const bytes = Buffer.from(body.text, "utf8");
      if (bytes.length > CLIP.textMax) throw new InputError(`text is too long (max ${CLIP.textMax} bytes)`, 413);
      content = { kind: "text", text: body.text };
      command = [Buffer.from(`T ${bytes.length}\n`), bytes];
      this.log(`clipboard: ${bytes.length} bytes of text from the ${source}`);
    } else if (Array.isArray(body.files) && body.files.length) {
      const paths = body.files;
      if (paths.length > CLIP.filesMax) throw new InputError(`at most ${CLIP.filesMax} files`);
      for (const p of paths) {
        const ok = typeof p === "string" && isAbsolute(p) && (await stat(p).then(() => true, () => false));
        if (!ok) throw new InputError(`${p} is not an existing file or folder`);
      }
      const uris = Buffer.from(paths.map((p) => `${fileUri(p)}\r\n`).join(""));
      const gnome = Buffer.from(`copy\n${paths.map(fileUri).join("\n")}`);
      const text = Buffer.from(paths.join("\n"));
      // one image file: its picture too (a paste into an image-taking app gives the image)
      let img = Buffer.alloc(0);
      let mime = "-";
      const type = paths.length === 1 ? imageTypeOf(paths[0]) : null;
      if (type) {
        const s = await stat(paths[0]).catch(() => null);
        if (s?.isFile() && s.size <= CLIP.imageMax) {
          img = await readFile(paths[0]).catch(() => Buffer.alloc(0));
          if (img.length) mime = type;
        }
      }
      content = { kind: "files", paths };
      command = [Buffer.from(`F ${uris.length} ${gnome.length} ${text.length} ${img.length} ${mime}\n`), uris, gnome, text, img];
      this.log(`clipboard: ${paths.length} file(s) from the ${source}: ${paths.map((p) => basename(p)).join(", ")}`);
    } else {
      throw new InputError("body needs text (a string) or files (paths)");
    }
    if (this.pendingWrite) await this.pendingWrite.done.catch(() => {});
    const done = new Promise((resolve, reject) => {
      const t = setTimeout(() => {
        if (this.pendingWrite?.done === done) this.pendingWrite = null;
        reject(new InputError("the desktop's clipboard did not answer", 503));
      }, CLIP.writeTimeoutMs);
      this.pendingWrite = {
        content,
        source,
        done: null,
        resolve: (v) => (clearTimeout(t), resolve(v)),
        reject: (e) => (clearTimeout(t), reject(e)),
      };
    });
    this.pendingWrite.done = done;
    for (const b of command) this.child.stdin.write(b);
    await done;
    return this.read(true);
  }
}

/** GET /clipboard/file's answer: the file streamed (never whole in memory), its name in Content-Disposition. */
export function sendClipboardFile(res, f) {
  const encoded = encodeURIComponent(f.name);
  res.writeHead(200, {
    "Content-Type": f.mime,
    "Content-Length": f.size,
    "Content-Disposition": `attachment; filename*=UTF-8''${encoded}`,
    "X-Clipboard-Change-Count": f.changeCount,
    "Cache-Control": "no-store",
    Connection: "close",
  });
  const s = createReadStream(f.path);
  s.on("error", () => res.destroy());
  res.on("close", () => s.destroy());
  s.pipe(res);
}
