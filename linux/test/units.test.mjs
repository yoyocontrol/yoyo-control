// node --test test/ (in linux/): the pure parts (the wire, input, flow control).
import assert from "node:assert/strict";
import { test } from "node:test";
import { FlowController, TUNING, chooseProfile, gradeNet, parsePlayoutReport, rttSummary } from "../flow.mjs";
import { InputDriver, InputError, KEYS, MoveGate, SCROLL, ScrollMotion, charKey, parseInput, typeLines } from "../input.mjs";
import { EventEmitter } from "node:events";
import { AudioCapture, AudioClientQueue, AudioRecordReader, audioCookie, audioEnabled, audioPart } from "../audio.mjs";
import { drained } from "../server.mjs";
import { RecordReader, WIRE, nalTypes, negotiate, streamPart } from "../wire.mjs";
import { IDR, P, PPS, SPS, audioHello, audioRecord, fakeProcess, frameRecord, parseParts, record } from "./fakes.mjs";

test("wire: the vnd.yoyo-control names whatever Accept says; a part is --boundary, headers, body, CRLF", () => {
  assert.equal(negotiate("application/vnd.yoyo-control.stream", "application/vnd.yoyo-control.stream"), WIRE.current);
  assert.equal(negotiate(undefined, "application/vnd.yoyo-control.stream"), WIRE.current);
  assert.equal(WIRE.legacy, undefined);
  assert.equal(WIRE.current.stream, "application/vnd.yoyo-control.stream; boundary=frame");
  const body = Buffer.concat([SPS, PPS, IDR]);
  const part = streamPart({ boundary: "frame", contentType: "video/h264", body, size: [1280, 832], seq: 7, time: 1792725383971.6, kind: "key", codec: "h264" });
  const text = part.subarray(0, part.indexOf("\r\n\r\n") + 4).toString();
  assert.equal(text, `--frame\r\nContent-Type: video/h264\r\nContent-Length: ${body.length}\r\nX-Frame-Width: 1280\r\nX-Frame-Height: 832\r\nX-Frame-Seq: 7\r\nX-Frame-Time: 1792725383972\r\nX-Frame-Kind: key\r\nX-Stream-Codec: h264\r\n\r\n`);
  assert.deepEqual(part.subarray(part.length - 2), Buffer.from("\r\n"));
  const [p] = parseParts(part);
  assert.deepEqual(p.body, body);
  assert.deepEqual(nalTypes(body), [7, 8, 5], "SPS, PPS, IDR");
  // a status part has no size and no codec
  const s = streamPart({ boundary: "frame", contentType: WIRE.current.status, body: Buffer.from("{}"), seq: 1, kind: "status" });
  assert.ok(!s.toString().includes("X-Frame-Width") && !s.toString().includes("X-Stream-Codec") && !s.toString().includes("X-Frame-Time"));
});

test("wire: the video helper's records come out whole from chunks split anywhere", () => {
  const hello = Buffer.alloc(4);
  hello.writeUInt16BE(1280, 0);
  hello.writeUInt16BE(832, 2);
  const bytes = Buffer.concat([record("H", hello), record("C"), frameRecord({ key: true, changed: true, time: 1234.5 }), record("S"), frameRecord({ key: false, changed: false, au: P })]);
  for (const size of [1, 3, 7, bytes.length]) {
    const r = new RecordReader();
    const out = [];
    for (let i = 0; i < bytes.length; i += size) out.push(...r.feed(bytes.subarray(i, i + size)));
    assert.deepEqual(out.map((x) => x.type), ["H", "C", "F", "S", "F"], `chunks of ${size}`);
    assert.deepEqual([out[0].width, out[0].height], [1280, 832]);
    assert.deepEqual([out[2].key, out[2].changed, out[2].time], [true, true, 1234.5]);
    assert.deepEqual(nalTypes(out[2].au), [7, 8, 5]);
    assert.deepEqual([out[4].key, out[4].changed], [false, false]);
  }
  assert.throws(() => new RecordReader(10).feed(record("F", Buffer.alloc(11))), /a record of 11 bytes/);
});

test("input: checked like the reference server (400s first), coordinates clamped, modifiers only where they count", () => {
  assert.deepEqual(parseInput({ type: "click", x: 1.5, y: -1, modifiers: ["cmd", "cmd"] }), { type: "click", x: 1, y: 0, modifiers: ["cmd"] });
  assert.deepEqual(parseInput({ type: "move", x: 0.5, y: 0.5, button: "left", seq: 9, modifiers: ["shift"] }), { type: "move", x: 0.5, y: 0.5, button: "left", seq: 9 });
  assert.deepEqual(parseInput({ type: "scroll", dy: 30, phase: "ended", vx: 0, vy: 900, seq: 1 }), { type: "scroll", dy: 30, phase: "ended", vx: 0, vy: 900 });
  assert.deepEqual(parseInput({ type: "key", key: " PageDown " }), { type: "key", key: "pagedown" });
  for (const [bad, re] of [
    [null, /JSON object/],
    [{ type: "tap" }, /type must be/],
    [{ type: "click", x: 0.5 }, /needs x and y/],
    [{ type: "drag", x: 0, y: 0 }, /dx and\/or dy/],
    [{ type: "scroll" }, /dx and\/or dy/],
    [{ type: "scroll", dy: 1, phase: "start" }, /phase/],
    [{ type: "move", x: 0, y: 0, button: "right" }, /button/],
    [{ type: "move", x: 0, y: 0, seq: -1 }, /seq/],
    [{ type: "type", text: "" }, /non-empty/],
    [{ type: "type", text: "x".repeat(4001) }, /too long/],
    [{ type: "key", key: "hyper" }, /unknown key/],
    [{ type: "key", key: "a", modifiers: ["meta"] }, /modifiers/],
    [{ type: "click", x: "1", y: 0 }, /x must be a number/],
  ]) {
    assert.throws(() => parseInput(bad), (e) => e instanceof InputError && e.status === 400 && re.test(e.message), JSON.stringify(bad));
  }
  // every protocol key name maps to an X keysym
  for (const k of ["return", "enter", "esc", "tab", "space", "delete", "backspace", "forwardDelete", "up", "home", "pageUp", "f12", "`", "\\", "z", "0"]) {
    assert.ok(KEYS[k.toLowerCase()], k);
  }
});

test("input: typed text goes as keysyms (never argv); characters off the keyboard map one at a time with a pause", () => {
  assert.equal(charKey("a"), "U0061");
  assert.equal(charKey("\n"), "Return");
  assert.equal(charKey("😀"), "U1F600");
  assert.equal(charKey("\u0007"), null);
  assert.deepEqual(typeLines("ls -a\n你好，x"), ["key --delay 8 U006C U0073 space U002D U0061 Return", "key U4F60", "sleep 0.04", "key U597D", "sleep 0.04", "key UFF0C", "sleep 0.04", "key --delay 8 U0078"]);
  assert.equal(typeLines("a".repeat(70)).length, 3, "batches of 32");
});

test("input: the driver's xdotool lines — clicks with modifiers, ⌘ as Ctrl, a live drag, keys, stale moves", () => {
  const lines = [];
  let now = 100;
  const d = new InputDriver({ send: (l) => lines.push(...l), width: 1280, height: 832, now: () => now });
  d.apply(parseInput({ type: "click", x: 0.5, y: 1, modifiers: ["cmd", "shift"] }));
  assert.deepEqual(lines.splice(0), ["mousemove 640 831", "keydown ctrl", "keydown shift", "click 1", "keyup shift", "keyup ctrl"]);
  d.apply(parseInput({ type: "doubleClick", x: 0, y: 0 }));
  assert.deepEqual(lines.splice(0), ["mousemove 0 0", "click --repeat 2 --delay 80 1"]);
  d.apply(parseInput({ type: "rightClick", x: 0.1, y: 0.1 }));
  assert.equal(lines.splice(0)[1], "click 3");
  d.apply(parseInput({ type: "key", key: "c", modifiers: ["cmd"] }));
  assert.deepEqual(lines.splice(0), ["key --clearmodifiers ctrl+c"]);
  d.apply(parseInput({ type: "key", key: "pageDown" }));
  assert.deepEqual(lines.splice(0), ["key --clearmodifiers Next"]);
  // a live drag: down (modifiers held), moves with the button, up lifts both
  d.apply(parseInput({ type: "down", x: 0.25, y: 0.25, modifiers: ["alt"] }));
  assert.deepEqual(lines.splice(0), ["mousemove 320 208", "keydown alt", "mousedown 1", "sleep 0.015"]);
  d.apply(parseInput({ type: "move", x: 0.3, y: 0.3, button: "left" }));
  d.apply(parseInput({ type: "up", x: 0.3, y: 0.3 }));
  assert.deepEqual(lines.splice(0), ["mousemove 384 250", "mousemove 384 250", "mouseup 1", "keyup alt"]);
  // a move overtaken by a newer one is stale and not applied
  assert.deepEqual(d.apply(parseInput({ type: "move", x: 0.1, y: 0.1, seq: 5000 })), { ok: true });
  assert.deepEqual(d.apply(parseInput({ type: "move", x: 0.2, y: 0.2, seq: 4999 })), { ok: true, stale: true });
  now += 3;
  assert.deepEqual(d.apply(parseInput({ type: "move", x: 0.2, y: 0.2, seq: 4999 })), { ok: true }, "2 s without a move: counted afresh");
  d.stop();
  const g = new MoveGate();
  assert.ok(g.admit(10_000, 0) && !g.admit(9_999, 1) && g.admit(8_000, 1), "1000 or more below: a new count");
});

test("input: keys and text on their own channel; the typing backlog drains with time and caps what may queue", () => {
  const pointer = [];
  const keys = [];
  let now = 0;
  const d = new InputDriver({ send: (l) => pointer.push(...l), sendKeys: (l) => keys.push(...l), width: 100, height: 100, now: () => now });
  d.apply(parseInput({ type: "type", text: "日".repeat(1150) })); // ≈ 52 ms each: just under a minute
  d.apply(parseInput({ type: "click", x: 0.5, y: 0.5 }));
  assert.deepEqual(pointer, ["mousemove 50 50", "click 1"]);
  assert.equal(keys.filter((l) => l.startsWith("key U65E5")).length, 1150);
  assert.throws(() => d.apply(parseInput({ type: "type", text: "日".repeat(20) })), (e) => e instanceof InputError && e.status === 429);
  now = 50;
  d.apply(parseInput({ type: "key", key: "return" }));
  assert.equal(keys.at(-1), "key --clearmodifiers Return", "drained: keys go again");
  assert.throws(() => d.apply(parseInput({ type: "type", text: "日".repeat(1300) })), (e) => e instanceof InputError && e.status === 413);
  d.resize(200, 50);
  d.apply(parseInput({ type: "click", x: 0.5, y: 0.5 }));
  assert.equal(pointer.at(-2), "mousemove 100 25");
  d.stop();
});

test("input: a left button left down is released after 10 s without a move or up", async () => {
  const lines = [];
  const d = new InputDriver({ send: (l) => lines.push(...l), width: 100, height: 100, holdTimeoutMs: 30 });
  d.apply(parseInput({ type: "down", x: 0.5, y: 0.5, modifiers: ["shift"] }));
  lines.length = 0;
  await new Promise((r) => setTimeout(r, 60));
  assert.deepEqual(lines, ["mouseup 1", "keyup shift"]);
  d.stop();
});

test("scroll: paced over 0.9 × the request interval, every pixel out once; momentum after a fast lift; wheel clicks of 50 px", () => {
  const m = new ScrollMotion();
  let t = 0;
  const out = { x: 0, y: 0 };
  const run = (until) => {
    while (t < until) {
      t += SCROLL.tick;
      const d = m.tick(t);
      out.x += d.x;
      out.y += d.y;
    }
  };
  m.submit({ dy: 100, phase: "began" }, t);
  run(0.016);
  assert.ok(out.y > 0 && out.y < 100, `paced, not at once (${out.y})`);
  run(0.05);
  assert.equal(out.y, 100, "all of the first request inside the fast window");
  m.submit({ dy: 120, phase: "changed" }, t);
  run(0.3);
  assert.equal(out.y, 220);
  m.submit({ dy: 0, phase: "ended", vy: 2000 }, t);
  run(3);
  assert.ok(out.y > 220 + 500, `momentum carried on (${out.y})`);
  assert.equal(m.busy, false, "and stopped");
  // slow lift: no momentum
  const s = new ScrollMotion();
  s.submit({ dy: 10, phase: "began" }, 0);
  s.submit({ dy: 0, phase: "ended", vy: 50 }, 0.01);
  let total = 0;
  for (let i = 1; i < 100; i++) total += s.tick(i * SCROLL.tick).y;
  assert.equal(total, 10);
  // the driver turns pixels into clicks (5 = down, 4 = up), the rest kept
  const lines = [];
  const d = new InputDriver({ send: (l) => lines.push(...l), width: 100, height: 100 });
  d.flushScroll({ x: 0, y: 120 });
  d.flushScroll({ x: -60, y: -40 });
  assert.deepEqual(lines, ["click --repeat 2 --delay 1 5", "click --repeat 1 --delay 1 6"]);
  assert.deepEqual(d.notch, { x: -10, y: -20 });
  d.stop();
});

test("flow: the window grows with the min RTT, probes after 1 s full, drops after 3 s without acks, comes back on a fresh ack", () => {
  const c = new FlowController(TUNING, 1 / 30);
  assert.equal(c.gate(0), "open", "no window before the first ack");
  for (let s = 1; s <= 4; s++) c.pictureSent(s, 0.01 * s, 1000);
  c.ack(1, false, 0.11);
  assert.equal(c.window, Math.ceil((2 * 0.1) / (1 / 30)) + 2, "covers two min RTTs at the frame rate");
  for (let s = 5; s <= 12; s++) c.pictureSent(s, 0.2, 1000);
  assert.deepEqual(c.gate(0.3), { full: 1.2 }, "full until a probe is due");
  assert.equal(c.gate(1.25), "probe");
  assert.equal(c.checkStall(3.3), true, "3 s without an ack while pictures are out: the window goes");
  assert.equal(c.gate(3.3), "open");
  c.pictureSent(13, 3.4, 1000);
  c.ack(13, false, 3.5);
  assert.equal(c.active, true, "a fresh ack brings it back");
  assert.equal(c.reenables, 1);
});

test("flow: congestion steps the rate down (not within the key grace, not when the stream sends little), clean paths climb back", () => {
  const c = new FlowController(TUNING, 1 / 30);
  let seq = 0;
  let t = 0;
  // a stream that uses its target (well over 3500 kbit/s at these paces)
  const sample = (rtt, bytes = 100_000) => {
    seq++;
    c.pictureSent(seq, t, bytes);
    t += rtt;
    const k = c.ack(seq, false, t);
    t += 1 / 30;
    return k;
  };
  for (let i = 0; i < 20; i++) sample(0.03);
  assert.equal(c.bitrateKbps, 3500);
  c.noteKeySent(t);
  for (let i = 0; i < 10; i++) sample(0.15);
  assert.equal(c.bitrateKbps, 3500, "no step inside the key grace");
  let stepped = null;
  for (let i = 0; i < 40 && stepped === null; i++) stepped = sample(0.15);
  assert.equal(stepped, Math.round(3500 * 0.85));
  assert.equal(c.ceilingAt(t), Math.round(3500 * 0.9));
  // the queue drains: back up to the start rate, never past the remembered ceiling
  for (let i = 0; i < 400; i++) sample(0.03);
  assert.equal(c.bitrateKbps, Math.round(3500 * 0.9), "climbs to the ceiling it remembers");
  // a still screen (little sent) is not stepped down by a queue that isn't its own
  const q = new FlowController(TUNING, 1 / 30);
  for (let i = 0; i < 60; i++) {
    q.pictureSent(i + 1, i / 10, 200);
    q.ack(i + 1, false, i / 10 + (i < 10 ? 0.02 : 0.3));
  }
  assert.equal(q.bitrateKbps, 3500);
  assert.ok(q.counters.held > 0);
});

test("flow: key requests at most every 500 ms; the profile from report.net; the grade from ack round trips", () => {
  const c = new FlowController();
  c.requestKey();
  assert.equal(c.keyDue(0), true);
  c.noteKeySent(10);
  c.requestKey();
  assert.equal(c.keyDue(10.2), false);
  assert.equal(c.keyDue(10.5), true);
  assert.deepEqual(chooseProfile({ constrained: true }, TUNING), { name: "constrained", maxKbps: 2500 });
  assert.deepEqual(chooseProfile({ iface: "cellular" }, TUNING), { name: "cellular", maxKbps: 20000 });
  assert.deepEqual(chooseProfile(null, { ...TUNING, maxKbps: 3000, requestMaxKbps: 3000 }), { name: "test", maxKbps: 3000 });
  assert.equal(c.applyProfile({ name: "constrained", maxKbps: 2500 }), 2500, "a lower ceiling steps the rate down at once");
  assert.deepEqual(gradeNet(null, null), { grade: "unknown", reasons: ["few-samples"] });
  assert.deepEqual(gradeNet(rttSummary([10, 12, 11, 13, 12]), null), { grade: "good", rttMs: { min: 10, p50: 12, p90: 13 }, jitterMs: 3, reasons: [] });
  assert.equal(gradeNet(rttSummary([120, 130, 125, 140, 300]), null).grade, "poor");
  assert.deepEqual(gradeNet(null, { failures: 1 }).reasons, ["failures", "few-samples"]);
  const byInput = gradeNet(null, { inputRttSamples: 6, inputRttP50Ms: 100, inputRttP90Ms: 150 });
  assert.equal(byInput.grade, "fair");
  assert.equal(byInput.rttMs, undefined, "no rttMs when graded by input");
  // reports decode leniently
  assert.equal(parsePlayoutReport({ mode: "fast" }), null);
  assert.deepEqual(parsePlayoutReport({ mode: "smooth", fps: 59.6, bufferMs: -1, net: { iface: "satellite", constrained: true } }), {
    mode: "smooth",
    fps: 59.6,
    net: { route: undefined, iface: undefined, radio: undefined, expensive: undefined, constrained: true, inputRttP50Ms: undefined, inputRttP90Ms: undefined, inputRttSamples: undefined, rxKbps: undefined, failures: undefined },
  });
});

test("audio: a client's queue keeps 25 packets, dropping the oldest, seq given on the way in (a gap where one was lost)", async () => {
  const q = new AudioClientQueue();
  for (let i = 0; i < 30; i++) q.push({ time: i * 20, data: Buffer.from([i]) });
  const items = await q.popAll(10);
  assert.equal(items.length, 25);
  assert.deepEqual([items[0].seq, items.at(-1).seq, q.dropped], [6, 30, 5]);
  const waited = q.popAll(1000);
  q.push({ time: 0, data: Buffer.alloc(1) });
  assert.equal((await waited)[0].seq, 31);
  q.close();
  assert.deepEqual(await q.popAll(1000), []);
});

test("audio: the helper's records, the part bytes, the cookie, YOYO_AUDIO", () => {
  const r = new AudioRecordReader();
  const bytes = Buffer.concat([audioHello(), audioRecord({ time: 1792725383971.4, fill: true }), audioRecord({ time: 1792725383991.4, data: Buffer.from([1, 2, 3, 4]) })]);
  const out = [];
  for (let i = 0; i < bytes.length; i += 5) out.push(...r.feed(bytes.subarray(i, i + 5)));
  assert.deepEqual(out[0], { type: "H", rate: 48000, channels: 2, frames: 960, lookahead: 312 });
  assert.deepEqual([out[1].fill, out[2].fill, [...out[2].data]], [true, false, [1, 2, 3, 4]]);
  const part = audioPart("frame", { seq: 7, packet: out[1] }).toString("latin1");
  assert.equal(part, "--frame\r\nContent-Type: audio/opus\r\nContent-Length: 3\r\nX-Audio-Seq: 7\r\nX-Audio-Time: 1792725383971\r\n\r\n\xfc\xff\xfe\r\n");
  assert.equal(audioCookie().toString("base64"), "AAAIAAAAu4AAAAPA///8GAAAAAIAAAAAAAAAAA==");
  assert.equal(audioEnabled({}), true);
  for (const v of ["off", "0", "FALSE", " no "]) assert.equal(audioEnabled({ YOYO_AUDIO: v }), false);
});

test("input: `insert` (a Linux extension) — Shift+Insert, a Linux client's paste key", () => {
  const sent = [];
  const d = new InputDriver({ send: (l) => sent.push(...l), width: 100, height: 100 });
  d.apply(parseInput({ type: "key", key: "Insert", modifiers: ["shift"] }));
  assert.deepEqual(sent, ["key --clearmodifiers shift+Insert"]);
  assert.equal(KEYS.insert, "Insert");
});

test("audio: backpressure waits leave no listeners behind (drain or close, whichever comes)", async () => {
  const res = new EventEmitter();
  for (let i = 0; i < 50; i++) {
    const w = drained(res);
    res.emit("drain");
    await w;
  }
  assert.deepEqual([res.listenerCount("drain"), res.listenerCount("close")], [0, 0]);
  const w = drained(res);
  res.emit("close");
  await w;
  assert.deepEqual([res.listenerCount("drain"), res.listenerCount("close")], [0, 0]);
});

test("audio: a helper that never says hello and then exits fails the start once (the timeout and the exit both come)", async () => {
  const lines = [];
  let child;
  const cap = new AudioCapture({ path: "/x/yoyo-pa-opus", env: {}, log: (l) => lines.push(l), startTimeoutMs: 30, spawnFn: () => (child = fakeProcess()) });
  await assert.rejects(cap.subscribe(), /did not answer/);
  child.exit(1);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(cap.counters.failures, 1);
  assert.equal(lines.filter((l) => l.startsWith("audio: cannot start")).length, 1);
});
