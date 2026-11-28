import { test } from "node:test";
import assert from "node:assert/strict";
import { AVSyncDriver, type AVSyncAudio, type AVSyncVideo } from "../src/avsync.js";
import { DECODE_EASY_HOLD_MS, DecodeWatch, LEVEL_UP_AFTER_MS, STREAM_LEVELS, StreamLevels } from "../src/decodeload.js";

/** Pictures every 17 ms for `ms`, each taking `decode` ms; the verdicts said. */
function feed(w: DecodeWatch, from: number, ms: number, decode: number, floor: number): string[] {
  const out: string[] = [];
  for (let t = from; t < from + ms; t += 17) {
    const v = w.add(decode, t, floor);
    if (v) out.push(v);
  }
  return out;
}

test("DecodeWatch: slow with the A/V floor holding pictures is 'floor', without it 'slow', once each", () => {
  const w = new DecodeWatch();
  assert.deepEqual(feed(w, 0, 900, 250, 300), []);
  assert.deepEqual(feed(w, 900, 2000, 250, 300), ["floor"]);
  // the floor goes away, the decoder still can't keep up
  assert.deepEqual(feed(w, 2900, 5000, 250, 0), ["slow"]);
  assert.deepEqual(feed(w, 7900, 5000, 250, 0), []);
});

test("DecodeWatch: a short burst isn't slow; a minute of quick decodes is 'easy'", () => {
  const w = new DecodeWatch();
  assert.deepEqual(feed(w, 0, 1000, 10, 0), []);
  assert.deepEqual(feed(w, 1000, 2000, 200, 0), []);
  assert.deepEqual(feed(w, 3000, 2000, 10, 0), []);
  assert.deepEqual(feed(w, 5000, DECODE_EASY_HOLD_MS + 2000, 10, 0), ["easy"]);
});

test("StreamLevels: down on slow to the lowest, up only after a while, never again after a failed step up", () => {
  const l = new StreamLevels();
  assert.deepEqual(l.level, STREAM_LEVELS[0]);
  assert.equal(l.slow(0), true);
  assert.equal(l.index, 1);
  assert.equal(l.easy(1000), false);
  assert.equal(l.easy(LEVEL_UP_AFTER_MS + 1), true);
  assert.equal(l.index, 0);
  // slow again right after going up: down, and it stays down
  assert.equal(l.slow(LEVEL_UP_AFTER_MS + 10_000), true);
  assert.equal(l.easy(10 * LEVEL_UP_AFTER_MS), false);
  for (let i = 0; i < 10; i++) l.slow(i);
  assert.equal(l.index, STREAM_LEVELS.length - 1);
  assert.equal(l.slow(99), false);
});

test("AVSyncDriver: no video floor when holding pictures starves the decoder", () => {
  const audio: AVSyncAudio = { syncDelays: () => ({ delay: 600, ownDelay: 600, soundRecent: true }), setSyncDelayGoal() {}, setSyncReport() {} };
  const video: AVSyncVideo & { holdsFewFrames: boolean } = { syncDelays: () => ({ smooth: 200, shown: 200 }), interactive: false, syncFloor: 0, holdsFewFrames: false };
  const d = new AVSyncDriver(audio, () => video);
  assert.ok(d.tick().videoFloor > 0);
  video.holdsFewFrames = true;
  assert.equal(d.tick().videoFloor, 0);
  assert.equal(video.syncFloor, 0);
});
