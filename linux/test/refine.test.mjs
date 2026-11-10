// node --test test/ (in linux/): a still picture's refines — the schedule (flow.mjs RefineSchedule, refineKbps) and
// the stream loop running it (video.mjs streamLoop over a fake yoyo-x11video whose pictures have chosen sizes).
import assert from "node:assert/strict";
import { test } from "node:test";
import { RefineSchedule, TUNING, liveBudget, refineKbps } from "../flow.mjs";
import { CRF, VideoHelper, streamLoop } from "../video.mjs";
import { WIRE } from "../wire.mjs";
import { fakeProcess, frameRecord, record } from "./fakes.mjs";

const BIG = 1e9;

test("refine: the numbers (the same names as the Mac server's StreamTuning)", () => {
  assert.equal(TUNING.refineIdle, 0.3);
  assert.equal(TUNING.refineEvery, 0.1);
  assert.equal(TUNING.videoRefines, 20);
  assert.equal(TUNING.refineSmallInARow, 2);
  assert.equal(TUNING.refineMinKbps, 4000);
  assert.equal(liveBudget(300, 30), 1250);
  assert.equal(liveBudget(3500, 30), (3500 * 1000) / 8 / 30);
});

test("refine: the first refineIdle after the live picture, then every refineEvery while the picture is big", () => {
  const r = new RefineSchedule(TUNING);
  assert.equal(r.dueAt, null, "nothing sent: nothing to refine");
  r.noteLive(10);
  assert.equal(r.dueAt, 10.3);
  assert.ok(!r.isDue(10.29) && r.isDue(10.3));
  for (let i = 1; i < 10; i++) {
    r.noteRefined(10 + i, 5000, 1000);
    assert.equal(r.dueAt, 10 + i + 0.1, `refine ${i}: the next one 100 ms later`);
  }
});

test("refine: two small ones in a row stop it; one small alone does not; a skip is not small", () => {
  const r = new RefineSchedule(TUNING);
  r.noteLive(0);
  r.noteRefined(1, 100, 1000); // small (x264 right after a scroll: the VBV drained)
  assert.notEqual(r.dueAt, null, "one small refine is no proof");
  r.noteRefined(2, 5000, 1000); // big again: the run starts over
  r.noteRefined(3, 1000, 1000); // ≤ the budget: small
  r.noteRefined(4, null, 1000); // skipped by the encoder (over budget): the run starts over
  assert.notEqual(r.dueAt, null, "a skip says nothing about the picture");
  r.noteRefined(5, null, 1000);
  assert.notEqual(r.dueAt, null, "nor do two");
  r.noteRefined(6, 10, 1000);
  r.noteRefined(7, 0, 1000);
  assert.equal(r.dueAt, null, "two small in a row: as sharp as this rate makes it");
  assert.equal(r.sent, 7, "skips count toward videoRefines");
});

test("refine: at most videoRefines; new content re-arms everything; cancel", () => {
  const r = new RefineSchedule(TUNING);
  r.noteLive(0);
  for (let i = 0; i < 19; i++) r.noteRefined(i + 1, BIG, 1000);
  assert.notEqual(r.dueAt, null);
  r.noteRefined(20, BIG, 1000);
  assert.equal(r.dueAt, null, "20 refines: done until the next change");
  r.noteLive(30);
  assert.deepEqual([r.dueAt, r.sent, r.smallRun], [30.3, 0, 0], "a change re-arms");
  r.noteRefined(31, 10, 1000);
  r.noteLive(32);
  r.noteRefined(33, 10, 1000);
  assert.notEqual(r.dueAt, null, "the small run starts over after a change too");
  r.cancel();
  assert.equal(r.dueAt, null);
  const none = new RefineSchedule({ ...TUNING, videoRefines: 0 });
  none.noteLive(0);
  assert.equal(none.dueAt, null, "videoRefines 0: no refines");
});

test("refine: the rate — 2×, at least refineMinKbps, under the ceiling; none when queueing; a link stream within its target", () => {
  assert.equal(refineKbps(TUNING, { kbps: 3500, ceiling: 20000 }), 7000);
  assert.equal(refineKbps(TUNING, { kbps: 300, ceiling: 20000 }), 4000);
  assert.equal(refineKbps(TUNING, { kbps: 1500, ceiling: 2500 }), 2500, "the profile's ceiling");
  assert.equal(refineKbps(TUNING, { kbps: 3000, ceiling: 2500 }), 3000, "never below the stream's own rate");
  assert.equal(refineKbps(TUNING, { kbps: 3500, ceiling: 20000, congested: true }), 3500, "queueing: no boost");
  // the link: refines every 100 ms at 30 fps add up to at most the target with a rate ≤ 3× it (fps · refineEvery)
  assert.equal(refineKbps(TUNING, { kbps: 300, ceiling: 20000, linkFps: 30 }), 900, "not 4000: that would be 4.4× the target");
  assert.equal(refineKbps(TUNING, { kbps: 3500, ceiling: 20000, linkFps: 30 }), 7000);
  assert.equal(refineKbps(TUNING, { kbps: 1000, ceiling: 20000, linkFps: 10 }), 1000, "10 fps: no room for a boost");
});

/**
 * A stream loop over a fake helper: the first encode is the changed picture, every later one is unchanged unless
 * `change()` was called; a refine's size comes from `sizes` (bytes, null = skipped), a live picture's is 10 bytes.
 */
function runLoop({ tuning, sizes, congested = false }) {
  const encodes = [];
  let dirty = true;
  const proc = fakeProcess((line, p) => {
    const m = /^E (\d) (\d+) ([\d.]+)$/.exec(line);
    if (!m) return;
    const e = { key: m[1] === "1", kbps: Number(m[2]), crf: Number(m[3]), changed: dirty };
    encodes.push(e);
    if (!dirty && Number(m[3]) === CRF.refine) {
      const size = sizes.length ? sizes.shift() : 10;
      if (size === null) return p.stdout.write(record("S"));
      p.stdout.write(frameRecord({ key: e.key, changed: false, au: Buffer.alloc(size, 1) }));
    } else p.stdout.write(frameRecord({ key: e.key, changed: dirty }));
    dirty = false;
  });
  const helper = new VideoHelper({ path: "yoyo-x11video", fps: 30, env: {}, log: () => {}, spawnFn: () => proc });
  const hello = Buffer.alloc(4);
  hello.writeUInt16BE(1280, 0);
  hello.writeUInt16BE(832, 2);
  proc.stdout.write(record("H", hello));
  proc.stdout.write(record("C"));
  const kinds = [];
  const res = {
    destroyed: false,
    writableEnded: false,
    write(buf, cb) {
      const m = /X-Frame-Kind: (\w+)/.exec(buf.subarray(0, 400).toString());
      if (m) kinds.push(m[1]);
      cb();
    },
  };
  let closed = false;
  const o = { helper, wire: WIRE.current, id: congested ? "refine-test" : null, fps: 30, log: () => {}, closed: () => closed, tuning };
  const running = (async () => {
    await helper.ready;
    await streamLoop(res, o);
  })();
  return {
    encodes,
    kinds,
    change() {
      dirty = true;
      proc.stdout.write(record("C"));
    },
    async stop() {
      if (closed) return;
      closed = true;
      helper.wake();
      await running;
      proc.exit(0);
    },
  };
}

const fast = { ...TUNING, refineIdle: 0.05, refineEvery: 0.02, keepalive: 60 };
const until = async (cond, what, ms = 3000) => {
  for (let i = 0; i < ms / 10 && !cond(); i++) await new Promise((r) => setTimeout(r, 10));
  assert.ok(cond(), `timed out waiting for ${what}`);
};
const settle = (ms) => new Promise((r) => setTimeout(r, ms));

test("stream loop: refines repeat while big or skipped, stop after two small in a row, re-arm on a change", { timeout: 10000 }, async (t) => {
  const budget = liveBudget(TUNING.startKbps, 30); // ≈ 14.6 KB
  const big = Math.ceil(budget) + 1;
  const loop = runLoop({ tuning: fast, sizes: [big, 100, null, big, Math.floor(budget), 1, big, 100, 100] });
  t.after(() => loop.stop());
  const refines = () => loop.encodes.filter((e) => !e.changed);
  await until(() => refines().length >= 6, "six refines");
  await settle(200);
  assert.equal(refines().length, 6, "stopped: the 5th (≤ the budget) and 6th were both small");
  for (const e of refines()) assert.deepEqual([e.crf, e.kbps], [CRF.refine, 7000], "refine quality, 2× the rate");
  assert.equal(loop.kinds.filter((k) => k === "refine").length, 5, "a skipped refine sends nothing");
  // new content: a live picture, then refines from the start (big, 100, 100 → three more)
  loop.change();
  await until(() => refines().length >= 9, "the refines of the new picture");
  await settle(200);
  assert.equal(refines().length, 9);
});

test("stream loop: at most videoRefines while every refine is big", { timeout: 10000 }, async (t) => {
  const loop = runLoop({ tuning: { ...fast, videoRefines: 5 }, sizes: Array(50).fill(BIG / 1e4) });
  t.after(() => loop.stop());
  await until(() => loop.encodes.filter((e) => !e.changed).length >= 5, "five refines");
  await settle(200);
  assert.equal(loop.encodes.filter((e) => !e.changed).length, 5);
});

test("stream loop: a queueing path — refines keep the refine quality, only the rate boost is left out", { timeout: 10000 }, async (t) => {
  // congestedDelay −1: the path always counts as queueing (the stream has an id, so it has a flow; no acks, so its
  // window lets the first few pictures through)
  const loop = runLoop({ tuning: { ...fast, congestedDelay: -1 }, sizes: Array(10).fill(BIG / 1e4), congested: true });
  t.after(() => loop.stop());
  await until(() => loop.encodes.filter((e) => !e.changed).length >= 2, "two refines");
  for (const e of loop.encodes.filter((e) => !e.changed)) assert.deepEqual([e.crf, e.kbps], [CRF.refine, TUNING.startKbps]);
});
