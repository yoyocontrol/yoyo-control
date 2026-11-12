// The encoder of the video helper (x264enc.h) through test/synthvideo.c — yoyo-x11video with made-up pictures — and
// the server's own VideoHelper: what one picture may weigh under the link's VBV buffer, and recovery from lost
// pictures without a key frame (the stream with those pictures cut out must decode to the very same pictures as the
// whole one). Needs a C compiler and libx264 (skipped without); the decoding checks need ffmpeg.
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, test } from "node:test";
import { TUNING, linkBufferKbit } from "../flow.mjs";
import { VideoHelper } from "../video.mjs";
import { nalTypes } from "../wire.mjs";

const dir = mkdtempSync(join(tmpdir(), "yoyo-x264enc-"));
const bin = join(dir, "synthvideo");

/** Compile synthvideo; null, or why it can't be had here. */
function build() {
  const src = fileURLToPath(new URL("./synthvideo.c", import.meta.url));
  let flags = ["-lx264"];
  const pc = spawnSync("pkg-config", ["--cflags", "--libs", "x264"], { encoding: "utf8" });
  if (pc.status === 0) flags = pc.stdout.trim().split(/\s+/);
  else if (process.platform === "darwin") flags = ["-I/opt/homebrew/include", "-L/opt/homebrew/lib", "-lx264"];
  const cc = spawnSync(process.env.CC || "cc", ["-O2", "-o", bin, src, ...flags], { encoding: "utf8" });
  if (cc.error) return `no C compiler (${cc.error.code})`;
  if (cc.status !== 0) return `synthvideo does not compile here (libx264's headers?): ${cc.stderr.split("\n")[0]}`;
  return null;
}
const skip = build() ?? false;
const ffmpeg = spawnSync("ffmpeg", ["-version"]).status === 0;
const noDecoder = skip || (ffmpeg ? false : "no ffmpeg");

const helpers = [];
after(() => {
  for (const h of helpers) h.stop();
});

async function helper(scene, fps = 30, size = "640x480") {
  const h = new VideoHelper({ path: bin, fps, env: { ...process.env, YOYO_SYNTH_SCENE: scene, YOYO_SYNTH_SIZE: size }, log: () => {} });
  helpers.push(h);
  await h.ready;
  return h;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The decoded pictures' checksums of an Annex-B stream (ffmpeg's own H.264 decoder, or VideoToolbox's). */
function pictures(units, hw = false) {
  const file = join(dir, `s${Math.random().toString(36).slice(2)}.h264`);
  writeFileSync(file, Buffer.concat(units));
  const out = execFileSync("ffmpeg", ["-v", "error", ...(hw ? ["-hwaccel", "videotoolbox"] : []), "-f", "h264", "-i", file, "-pix_fmt", "yuv420p", "-f", "framemd5", "-"], { encoding: "utf8" });
  return out
    .split("\n")
    .filter((l) => l && !l.startsWith("#"))
    .map((l) => l.split(",").pop().trim());
}

test("the hello says the helper keeps earlier pictures; frames carry their numbers", { skip }, async () => {
  const h = await helper("scroll");
  assert.deepEqual(h.size, [640, 480]);
  assert.equal(h.refs, true);
  const a = await h.encode(true, 2000, 23);
  const b = await h.encode(false, 2000, 23);
  assert.equal(a.key, true);
  assert.equal(a.number, 0);
  assert.equal(b.key, false);
  assert.equal(b.number, 1);
  assert.ok(nalTypes(a.au).includes(7) && nalTypes(a.au).includes(5));
  h.stop();
});

test("under the link's buffer a new page is a picture of about half of it; with a second of buffer, several times that", { skip }, async () => {
  // a new page every second (the helper says when), pictures 30 a second at 1500 kbit/s: one picture's share is
  // 50 kbit, the buffer 8 of them
  const kbps = 1500;
  const buf = linkBufferKbit(TUNING, kbps, 30);
  assert.equal(buf, 400);
  const pages = async (b) => {
    const h = await helper("pages", 30, "1280x832");
    const first = await h.encode(true, kbps, 23, b);
    const out = [];
    for (let i = 0; i < 4; i++) {
      // the still page's refines, as the stream loop sends them (they are small once the page is sharp, and each
      // leaves its share in the buffer: x264 counts the buffer in pictures, not in time)
      for (let j = 0; j < 8; j++) await h.encode(false, kbps * 2, 17, b);
      h.clearKick();
      await h.wait(h.changeToken, 3000);
      const r = await h.encode(false, kbps, 23, b);
      assert.equal(r.changed, true);
      out.push(r.au.length);
    }
    h.stop();
    return { key: first.au.length, pages: out };
  };
  const bounded = await pages(buf);
  const whole = (buf * 1000) / 8;
  // the first picture (a key frame) may take the buffer; a changed one about half of it (x264 misses by a little)
  assert.ok(bounded.key <= whole * 1.25, `the key frame: ${bounded.key} bytes, the buffer holds ${whole}`);
  assert.ok(Math.max(...bounded.pages) <= (whole / 2) * 1.5, `a new page: ${bounded.pages} bytes, half the buffer is ${whole / 2}`);
  // the one-second buffer this replaced: the same pages several times as heavy
  const loose = await pages(null);
  assert.ok(Math.max(...loose.pages) > 2 * Math.max(...bounded.pages), `one second of buffer: ${loose.pages}, the link's: ${bounded.pages}`);
});

test("pictures forgotten: the next one is no key frame and needs none of them to decode", { skip: noDecoder }, async () => {
  const h = await helper("scroll");
  const units = [];
  const next = async (key = false) => {
    await sleep(20);
    const r = await h.encode(key, 3000, 23, 800);
    units.push(r);
    return r;
  };
  await next(true);
  for (let i = 1; i < 10; i++) await next();
  // pictures 5…9 never arrived: the viewer's newest is 4
  h.forget(5);
  const mend = await next();
  assert.equal(mend.number, 10);
  assert.equal(mend.key, false, "a picture that references number 4, not a key frame");
  for (let i = 0; i < 4; i++) await next();
  h.stop();
  const whole = pictures(units.map((u) => u.au));
  const cut = pictures(units.filter((u) => u.number < 5 || u.number >= 10).map((u) => u.au));
  assert.equal(whole.length, 15);
  // the last five pictures are the same whether 5…9 were decoded or not
  assert.deepEqual(cut.slice(-5), whole.slice(-5));
  assert.deepEqual(cut.slice(0, 5), whole.slice(0, 5));
});

test("the same through VideoToolbox (the phones' decoder)", { skip: noDecoder || (process.platform === "darwin" ? false : "not a Mac") }, async () => {
  const h = await helper("scroll");
  const units = [];
  for (let i = 0; i < 12; i++) {
    await sleep(20);
    if (i === 8) h.forget(4);
    units.push(await h.encode(i === 0, 3000, 23, 800));
  }
  h.stop();
  const whole = pictures(units.map((u) => u.au), true);
  const cut = pictures(units.filter((u) => u.number < 4 || u.number >= 8).map((u) => u.au), true);
  assert.equal(whole.length, 12);
  assert.deepEqual(cut.slice(-4), whole.slice(-4));
});

test("forgetting more than the helper keeps: a key frame by itself", { skip }, async () => {
  const h = await helper("scroll");
  for (let i = 0; i < 24; i++) {
    await sleep(5);
    await h.encode(i === 0, 3000, 23, 800);
  }
  // 640x480 keeps 16 pictures: number 1 is long gone
  h.forget(2);
  const r = await h.encode(false, 3000, 23, 800);
  assert.equal(r.key, true);
  h.stop();
});
