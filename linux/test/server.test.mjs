// The HTTP service with its processes faked (test/fakes.mjs): auth, /status, /stream's parts and the ack loop, /input,
// /frame, and what a missing feature answers.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { after, before, test } from "node:test";
import { YoyoLinux, readToken, resolveHost } from "../server.mjs";
import { nalTypes } from "../wire.mjs";
import { fakeSpawn, parseParts } from "./fakes.mjs";

const TOKEN = "f".repeat(64);
const fake = fakeSpawn();
const lines = [];
const svc = new YoyoLinux({ token: TOKEN, name: "Desktop", spawnFn: fake.spawn, logLine: (l) => lines.push(l), audioLingerMs: 150 });
let port;

before(async () => {
  port = (await svc.listen(0, "127.0.0.1")).port;
});
after(() => svc.close());

function call(method, path, { body, token = TOKEN, headers = {}, stream } = {}) {
  return new Promise((resolve, reject) => {
    const b = body === undefined ? undefined : Buffer.from(typeof body === "string" ? body : JSON.stringify(body));
    const req = request(
      { host: "127.0.0.1", port, method, path, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(b ? { "content-type": "application/json", "content-length": b.length } : {}), ...headers } },
      (res) => {
        if (stream) return resolve({ res, req });
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const buf = Buffer.concat(chunks);
          let json;
          try {
            json = JSON.parse(buf.toString());
          } catch {}
          resolve({ status: res.statusCode, headers: res.headers, buf, json });
        });
      },
    );
    req.on("error", reject);
    req.end(b);
  });
}

test("the token: the first line of --token-file's file, else of stdin", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yoyo-linux-token-"));
  try {
    const file = join(dir, "token");
    writeFileSync(file, `${TOKEN}\nanything after\n`, { mode: 0o600 });
    assert.equal(await readToken(file), TOKEN);
    assert.equal(await readToken(undefined, Readable.from([Buffer.from(`  ${TOKEN}  \nmore`)])), TOKEN);
    await assert.rejects(readToken(join(dir, "missing")), /ENOENT/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("every route wants the bearer token", async () => {
  for (const token of [null, "f".repeat(63), "g".repeat(64)]) {
    const r = await call("GET", "/status", { token });
    assert.deepEqual([r.status, r.json], [401, { error: "unauthorized" }]);
  }
  assert.throws(() => new YoyoLinux({ token: "short" }), /16 characters/);
  assert.equal(resolveHost("iface:eth9", { eth9: [{ family: "IPv6", address: "fe80::1" }, { family: "IPv4", address: "10.1.2.3" }] }), "10.1.2.3");
  assert.equal(resolveHost("192.168.1.2"), "192.168.1.2");
  assert.throws(() => resolveHost("iface:none", {}), /no IPv4/);
});

test("/status: yoyo-linux, api 1, one ready display of the screen's size; what's missing answers like the Mac with it off", async () => {
  const r = await call("GET", "/status");
  assert.equal(r.status, 200);
  assert.equal(r.json.app, "yoyo-linux");
  assert.equal(r.json.api, 1);
  assert.equal(r.json.platform, "linux");
  assert.equal(r.json.ok, true);
  assert.deepEqual(r.json.session, { loggedIn: true });
  assert.deepEqual(r.json.displays, [{ id: 1, width: 1280, height: 832, scale: 1, main: true, asleep: false, kind: "builtin", name: "Desktop" }]);
  assert.equal(r.json.states[0].phase, "ready");
  assert.deepEqual(r.json.console, { locked: false });
  assert.deepEqual(r.json.features, { clipboard: true, audio: true, cursor: true, focus: false, link: false, windows: true, automation: true });
  assert.deepEqual(r.json.automation, { active: false, esc: false });
  for (const [m, p] of [["GET", "/focus"], ["POST", "/control"], ["GET", "/app/windows"], ["GET", "/app/screenshot"], ["GET", "/app/ax"]]) {
    assert.equal((await call(m, p)).status, 404, `${m} ${p}`);
  }
});

test("/frame: one JPEG of the screen scaled to maxWidth, its size in the headers", async () => {
  const r = await call("GET", "/frame?maxWidth=640&quality=95");
  assert.equal(r.status, 200);
  assert.equal(r.headers["content-type"], "image/jpeg");
  assert.deepEqual([r.headers["x-frame-width"], r.headers["x-frame-height"], r.headers["x-display"]], ["640", "416", "1"]);
  const args = fake.state.ffmpegArgs.at(-1);
  assert.ok(args.includes("scale=640:416:flags=area") && args[args.indexOf("-q:v") + 1] === "2");
  assert.equal((await call("GET", "/frame?display=2")).status, 404);
});

test("/input: checked, then xdotool lines through one long-lived process (text never in argv)", async () => {
  assert.deepEqual((await call("POST", "/input", { body: { type: "click", x: 0.5, y: 0.5 } })).json, { ok: true });
  assert.deepEqual((await call("POST", "/input", { body: { type: "type", text: "密码 secret" } })).json, { ok: true });
  assert.equal((await call("POST", "/input", { body: { type: "click", x: 0.5 } })).status, 400);
  assert.equal((await call("POST", "/input", { body: "{" })).status, 400);
  assert.equal((await call("POST", "/input", { body: { type: "click", x: 0.5, y: 0.5, display: 3 } })).status, 404);
  await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(fake.state.xdotool.slice(0, 2), ["mousemove 640 416", "click 1"]);
  assert.ok(fake.state.xdotool.includes("key U5BC6") && fake.state.xdotool.some((l) => l.includes("U0073")));
});

test("/stream: status part first, a key picture with SPS/PPS, acks with net, a key frame on request, a change encoded; 404 acks after", async () => {
  assert.equal((await call("GET", "/stream?stream=bad")).status, 400);
  assert.equal((await call("GET", "/stream?cursor=server")).status, 400);
  assert.equal((await call("GET", "/stream?maxKbps=50")).status, 400);
  const id = "stream-test-1";
  const { res, req } = await call("GET", `/stream?fps=60&stream=${id}&ack=1&status=1&cursor=client&codecs=hevc,h264`, {
    headers: { accept: "application/vnd.yoyo-control.stream, multipart/x-mixed-replace" },
    stream: true,
  });
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers["content-type"], "application/vnd.yoyo-control.stream; boundary=frame");
  assert.deepEqual([res.headers["x-stream-codec"], res.headers["x-stream-id"], res.headers["x-display"]], ["h264", id, "1"]);
  let buf = Buffer.alloc(0);
  res.on("data", (d) => (buf = Buffer.concat([buf, d])));
  const until = async (pred, what) => {
    for (let i = 0; i < 200; i++) {
      const parts = parseParts(buf);
      if (pred(parts)) return parts;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error(`timed out waiting for ${what}`);
  };
  let parts = await until((p) => p.length >= 3, "the first picture");
  assert.equal(parts[0].headers["content-type"], "application/vnd.yoyo-control.status+json");
  assert.equal(parts[0].headers["x-frame-kind"], "status");
  assert.equal(JSON.parse(parts[0].body).phase, "ready");
  // (cursor=client: the pointer's part comes before the first picture)
  assert.equal(parts[1].headers["x-frame-kind"], "cursor");
  const key = parts[2];
  assert.equal(key.boundary, "--frame");
  assert.equal(key.headers["content-type"], "video/h264");
  assert.deepEqual([key.headers["x-frame-kind"], key.headers["x-frame-seq"], key.headers["x-frame-width"], key.headers["x-frame-height"], key.headers["x-stream-codec"]], ["key", "3", "1280", "832", "h264"]);
  assert.ok(Number(key.headers["x-frame-time"]) > 1.7e12);
  assert.deepEqual(nalTypes(key.body).slice(0, 3), [7, 8, 5]);
  const helper = fake.state.helpers.at(-1);
  assert.deepEqual(helper.args, ["--fps", "30", "--cursor", "client"], "fps capped at 30");
  assert.equal(fake.state.encodes.at(-1).key, true);
  // acks: the grade comes back; a key request is answered with a key picture
  const ack = await call("POST", "/stream/ack", { body: { stream: id, seq: 3, report: { mode: "smooth", fps: 30, net: { iface: "wifi" } } } });
  assert.equal(ack.status, 200);
  assert.equal(ack.json.ok, true);
  assert.equal(ack.json.net.grade, "unknown");
  assert.equal((await call("POST", "/stream/ack", { body: { stream: id, seq: -1 } })).status, 400);
  assert.equal((await call("POST", "/stream/ack", { body: { stream: id, seq: 2, keyframe: "yes" } })).status, 400);
  assert.equal((await call("POST", "/stream/ack", { body: { stream: "no-such-stream", seq: 2 } })).status, 404);
  await call("POST", "/stream/ack", { body: { stream: id, seq: 2, keyframe: true } });
  parts = await until((p) => p.slice(3).some((x) => x.headers["x-frame-kind"] === "key"), "a key picture on request");
  // a change: a delta
  fake.state.screenChanges();
  parts = await until((p) => p.slice(3).some((x) => x.headers["x-frame-kind"] === "delta"), "a delta for the change");
  const seqs = parts.map((p) => Number(p.headers["x-frame-seq"]));
  assert.deepEqual(seqs, seqs.map((_, i) => i + 1), "every part numbered in order");
  // refines follow 300 ms after the last change, sharper (a lower crf, a higher cap)
  parts = await until((p) => p.some((x) => x.headers["x-frame-kind"] === "refine"), "a refine");
  const refine = fake.state.encodes.find((e) => e.crf < 23);
  assert.ok(refine && refine.kbps >= 4000);
  req.destroy();
  for (let i = 0; i < 100 && fake.state.helpers.at(-1).exitCode === null; i++) await new Promise((r) => setTimeout(r, 10));
  assert.notEqual(helper.exitCode, null, "the client gone: its helper stops");
  assert.equal((await call("POST", "/stream/ack", { body: { stream: id, seq: 9 } })).status, 404, "its acks: no such stream");
});

test("/stream without Accept: the same vnd.yoyo-control names (the pre-release ones are gone)", async () => {
  const { res, req } = await call("GET", "/stream", { stream: true });
  assert.equal(res.headers["content-type"], "application/vnd.yoyo-control.stream; boundary=frame");
  req.destroy();
});

test("/frame: at most 2 captures (ffmpeg) at once, 4 more waiting, the rest 503", async () => {
  fake.state.ffmpegMs = 60;
  fake.state.ffmpegMax = 0;
  const all = await Promise.all(Array.from({ length: 8 }, () => call("GET", "/frame?maxWidth=320")));
  fake.state.ffmpegMs = 0;
  assert.deepEqual(all.map((r) => r.status).sort(), [200, 200, 200, 200, 200, 200, 503, 503]);
  assert.equal(fake.state.ffmpegMax, 2);
});

test("/input: text is typed on its own xdotool (a click is never behind it); more than a minute of typing queued is refused", async () => {
  const before = fake.state.xdotools.length;
  const cjk = (n) => "中".repeat(n);
  assert.equal((await call("POST", "/input", { body: { type: "type", text: cjk(600) } })).status, 200);
  const busy = await call("POST", "/input", { body: { type: "type", text: cjk(600) } });
  assert.equal(busy.status, 429);
  assert.match(busy.json.error, /still typing/);
  assert.equal((await call("POST", "/input", { body: { type: "type", text: cjk(2000) } })).status, 413);
  assert.deepEqual((await call("POST", "/input", { body: { type: "click", x: 0.25, y: 0.25 } })).json, { ok: true });
  await new Promise((r) => setTimeout(r, 20));
  const [pointer, keys] = fake.state.xdotools;
  assert.equal(fake.state.xdotools.length - before, 0, "the two processes were made by the earlier input");
  assert.ok(pointer.includes("mousemove 320 208") && !pointer.some((l) => l.startsWith("key ")), "the pointer's process has no keys");
  assert.ok(keys.filter((l) => l === "key U4E2D").length === 600 && !keys.some((l) => l.startsWith("mouse")), "the keyboard's has the text");
});

test("a display that can't be opened is `ok: false`; a new size (from the next helper) moves input onto it", async () => {
  fake.state.noDisplay = true;
  assert.equal((await call("GET", "/stream")).status, 503);
  const down = await call("GET", "/status");
  assert.equal(down.json.ok, false);
  assert.match(down.json.error, /exited|cannot open/);
  assert.deepEqual(down.json.displays, []);
  fake.state.noDisplay = false;
  fake.state.size = [1024, 768];
  const up = await call("GET", "/status");
  assert.equal(up.json.ok, true);
  assert.deepEqual([up.json.displays[0].width, up.json.displays[0].height], [1024, 768]);
  await call("POST", "/input", { body: { type: "click", x: 0.5, y: 0.5 } });
  await new Promise((r) => setTimeout(r, 20));
  assert.ok(fake.state.xdotools[0].includes("mousemove 512 384"), "the pointer maps onto the new size");
  fake.state.size = [1280, 832];
});

/** Open a stream and collect its bytes: `parts()` parsed so far, `until(pred)`, `close()`. */
async function openStream(path, headers = { accept: "application/vnd.yoyo-control.stream" }) {
  const { res, req } = await call("GET", path, { headers, stream: true });
  let buf = Buffer.alloc(0);
  res.on("data", (d) => (buf = Buffer.concat([buf, d])));
  const parts = () => parseParts(buf);
  const until = async (pred, what, ms = 2000) => {
    for (let i = 0; i < ms / 10; i++) {
      const p = parts();
      if (pred(p)) return p;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error(`timed out waiting for ${what}`);
  };
  const helper = fake.state.helpers.at(-1);
  const close = async () => {
    req.destroy();
    for (let i = 0; i < 100 && helper.exitCode === null; i++) await new Promise((r) => setTimeout(r, 10));
  };
  return { res, parts, until, close, helper };
}

const cursorParts = (parts) => parts.filter((p) => p.headers["x-frame-kind"] === "cursor").map((p) => ({ seq: Number(p.headers["x-frame-seq"]), ...JSON.parse(p.body) }));

test("cursor=client: the helper runs with --cursor client; a cursor part with its shape before the first picture; moves are cursor parts, never pictures", async () => {
  const s = await openStream("/stream?fps=30&stream=cursor-test-1&ack=1&status=1&cursor=client");
  assert.deepEqual(s.helper.args, ["--fps", "30", "--cursor", "client"]);
  let parts = await s.until((p) => p.some((x) => x.headers["content-type"] === "video/h264"), "the first picture");
  const kinds = parts.map((p) => p.headers["x-frame-kind"]);
  assert.deepEqual(kinds.slice(0, 3), ["status", "cursor", "key"]);
  const cursor = parts[1];
  assert.equal(cursor.headers["content-type"], "application/vnd.yoyo-control.cursor+json");
  assert.equal(cursor.headers["x-frame-seq"], "2");
  assert.ok(Number(cursor.headers["x-frame-time"]) > 1.7e12);
  assert.equal(cursor.headers["x-frame-width"], undefined, "no picture size on a cursor part");
  const first = JSON.parse(cursor.body);
  assert.deepEqual([first.x, first.y, first.visible], [0.5, 0.5, true]);
  assert.ok(first.shapeId >= 1e6 && first.shapeId % 2 ** 20 === 7, "base + serial 7");
  assert.equal(first.shape.id, first.shapeId);
  assert.deepEqual([first.shape.hotX, first.shape.hotY, first.shape.width, first.shape.height], [1 / 1280, 2 / 832, 4 / 1280, 4 / 832]);
  assert.equal(Buffer.from(first.shape.png, "base64").subarray(1, 4).toString(), "PNG");
  // the pointer moves (polled by the helper): cursor parts without the shape, and no new encode
  const encodes = fake.state.encodes.length;
  fake.state.pointerMoves({ x: 128, y: 83 });
  parts = await s.until((p) => cursorParts(p).some((c) => c.x === 0.1), "a cursor part for the move");
  const moved = cursorParts(parts).find((c) => c.x === 0.1);
  assert.equal(moved.shape, undefined, "the shape went once");
  assert.equal(moved.shapeId, first.shapeId);
  // (refines of the first picture may still come; a live picture for the move must not)
  assert.ok(fake.state.encodes.slice(encodes).every((e) => e.crf < 23), "no live encode for a pointer move");
  // a new shape: its PNG once
  fake.state.pointerMoves({ serial: 8, pixels: Buffer.alloc(4 * 4 * 4, 255) });
  parts = await s.until((p) => cursorParts(p).some((c) => c.shape && c.shape.id % 2 ** 20 === 8), "the new shape");
  // an /input click: its position at once, before any poll
  const t0 = Date.now();
  assert.deepEqual((await call("POST", "/input", { body: { type: "click", x: 0.25, y: 0.75 } })).json, { ok: true });
  parts = await s.until((p) => cursorParts(p).some((c) => c.x === 0.25 && c.y === 0.75), "the click's position");
  assert.ok(Date.now() - t0 < 500);
  // the helper reads back where xdotool put it (320, 624): within 1.5 px, no news
  const n = cursorParts(parts).length;
  fake.state.pointerMoves({ x: 320, y: 624, serial: 8 });
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(cursorParts(s.parts()).length, n, "a read-back of our own input is no news");
  const seqs = s.parts().map((p) => Number(p.headers["x-frame-seq"]));
  assert.deepEqual(seqs, seqs.map((_, i) => i + 1), "cursor parts take sequence numbers too");
  await s.close();
});

test("cursor=client: changes coalesced to at most 60 parts a second; a stream without it has no cursor parts", async () => {
  const s = await openStream("/stream?fps=30&stream=cursor-test-2&cursor=client");
  await s.until((p) => p.some((x) => x.headers["content-type"] === "video/h264"), "the first picture");
  const before = cursorParts(s.parts()).length;
  const t0 = Date.now();
  for (let i = 0; i < 40; i++) {
    fake.state.pointerMoves({ x: 10 + i * 10, y: 10 });
    await new Promise((r) => setTimeout(r, 2));
  }
  await new Promise((r) => setTimeout(r, 60));
  const sent = cursorParts(s.parts()).slice(before);
  const seconds = (Date.now() - t0) / 1000;
  assert.ok(sent.length >= 2 && sent.length <= Math.ceil(seconds * 60) + 1, `${sent.length} parts in ${seconds.toFixed(2)} s`);
  assert.equal(sent.at(-1).x, 400 / 1280, "the latest position wins");
  await s.close();
  const plain = await openStream("/stream?fps=30&stream=cursor-test-3");
  assert.deepEqual(plain.helper.args, ["--fps", "30"]);
  await plain.until((p) => p.some((x) => x.headers["content-type"] === "video/h264"), "the first picture");
  await call("POST", "/input", { body: { type: "click", x: 0.5, y: 0.5 } });
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(cursorParts(plain.parts()).length, 0);
  await plain.close();
});

/** Read an /audio response's parts until `n` audio parts came (or `ms`). */
async function audioParts(res, n, ms = 2000) {
  let buf = Buffer.alloc(0);
  const onData = (d) => (buf = Buffer.concat([buf, d]));
  res.on("data", onData);
  for (let i = 0; i < ms / 10 && parseParts(buf).length < n; i++) await new Promise((r) => setTimeout(r, 10));
  res.off("data", onData);
  return parseParts(buf);
}

test("/audio: Opus parts with the reference server's headers, seq from 1, times 20 ms apart; one capture for two clients, stopped after the last leaves", async () => {
  const before = fake.state.audioHelpers.length;
  const a = await call("GET", "/audio", { headers: { accept: "application/vnd.yoyo-control.audio" }, stream: true });
  assert.equal(a.res.statusCode, 200);
  const h = a.res.headers;
  assert.equal(h["content-type"], "application/vnd.yoyo-control.audio; boundary=frame");
  assert.deepEqual([h["x-audio-codec"], h["x-audio-rate"], h["x-audio-channels"], h["x-audio-frames"], h["x-audio-video-offset"]], ["opus", "48000", "2", "960", "10"]);
  // the Mac's cookie bytes (AVAudioConverter's Opus magic cookie), not an OpusHead
  assert.equal(h["x-audio-cookie"], "AAAIAAAAu4AAAAPA///8GAAAAAIAAAAAAAAAAA==");
  const parts = await audioParts(a.res, 4);
  assert.ok(parts.length >= 4);
  assert.equal(parts[0].boundary, "--frame");
  assert.equal(parts[0].headers["content-type"], "audio/opus");
  assert.deepEqual(parts.map((p) => Number(p.headers["x-audio-seq"])), parts.map((_, i) => i + 1));
  const times = parts.map((p) => Number(p.headers["x-audio-time"]));
  for (let i = 1; i < times.length; i++) assert.ok(Math.abs(times[i] - times[i - 1] - 20) <= 1, `times ${times}`);
  assert.deepEqual([...parts[0].body], [0xfc, 0xff, 0xfe]);
  // a second client (no Accept: the same names): the same capture; its seq starts at 1 too
  const b = await call("GET", "/audio", { stream: true });
  assert.equal(b.res.headers["content-type"], "application/vnd.yoyo-control.audio; boundary=frame");
  const bp = await audioParts(b.res, 2);
  assert.equal(bp[0].headers["x-audio-seq"], "1");
  assert.equal(fake.state.audioHelpers.length - before, 1, "one capture for both");
  const helper = fake.state.audioHelpers.at(-1);
  assert.equal((await call("GET", "/audio/stats")).json.clients, 2);
  a.req.destroy();
  b.req.destroy();
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(helper.exitCode, null, "kept a while after the last client (3 s on the real server)");
  for (let i = 0; i < 100 && helper.exitCode === null; i++) await new Promise((r) => setTimeout(r, 10));
  assert.notEqual(helper.exitCode, null, "then stopped");
  assert.ok(lines.some((l) => /audio: capture stopped/.test(l)));
});

test("/audio: a capture that can't start is 503 { error } before the head, and /status says audio: false", async () => {
  fake.state.audioFails = true;
  svc.audio.probed = null;
  const r = await call("GET", "/audio");
  assert.equal(r.status, 503);
  assert.match(r.json.error, /Connection refused/);
  assert.equal((await call("GET", "/status")).json.features.audio, false);
  fake.state.audioFails = false;
  svc.audio.probed = null;
  assert.equal((await call("GET", "/status")).json.features.audio, true);
  // YOYO_AUDIO=off: what the Mac answers with its sound off
  const off = new YoyoLinux({ token: TOKEN, spawnFn: fake.spawn, logLine: () => {}, env: { YOYO_AUDIO: "off" } });
  await assert.rejects(off.audio.subscribe(), /audio off/);
  assert.equal(await off.audio.available(), false);
  off.close();
});
