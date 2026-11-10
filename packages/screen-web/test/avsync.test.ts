import { test } from "node:test";
import assert from "node:assert/strict";
import { AudioJitter, audioJitterConfig, AudioScheduler, audioSchedulerConfig, type ScheduledPacket } from "../src/audiobuffer.js";
import { AVSync, AVSyncDriver, type AVSyncAudio, type AVSyncInput, type AVSyncVideo } from "../src/avsync.js";
import { MAX_SYNC_FLOOR_MS, Playout } from "../src/playout.js";

// A/V sync (the iOS kit's ScreenAVSync) and the sound's jitter buffer (ScreenAudioBuffer, compacted).

const input = (o: Partial<AVSyncInput>): AVSyncInput => ({ audioDelay: null, audioOwnDelay: null, videoDelay: null, shownDelay: null, interactive: false, soundRecent: true, ...o });

test("AVSync: the video waits for a later sound, stays engaged down to 15 ms, never while interactive", () => {
  const s = new AVSync();
  assert.deepEqual(s.update(input({ audioDelay: 200, videoDelay: 170 })), { videoFloor: 0, audioDelayGoal: null, skew: 30 }, "30 ms: not enough to engage");
  let o = s.update(input({ audioDelay: 200, audioOwnDelay: 200, videoDelay: 140, shownDelay: 140 }));
  assert.equal(o.videoFloor, 45);
  assert.equal(s.engaged, true);
  o = s.update(input({ audioDelay: 200, audioOwnDelay: 200, videoDelay: 170 }));
  assert.equal(o.videoFloor, 15, "engaged: follows the skew under the entry threshold");
  o = s.update(input({ audioDelay: 200, audioOwnDelay: 200, videoDelay: 170, interactive: true }));
  assert.equal(o.videoFloor, 0, "interactive pictures get no floor");
  assert.equal(s.engaged, true, "but it comes back with smooth playback");
  o = s.update(input({ audioDelay: 200, videoDelay: 190 }));
  assert.equal(s.engaged, false, "skew under 15 ms releases it");
  s.update(input({ audioDelay: 200, videoDelay: 100 }));
  assert.equal(s.update(input({ audioDelay: 200, videoDelay: 100, soundRecent: false })).videoFloor, 0, "silence releases it");
  assert.equal(s.update(input({ audioDelay: 900, videoDelay: 100 })).videoFloor, AVSync.MAX_VIDEO_FLOOR_MS);
  assert.equal(s.update(input({ audioDelay: 900, videoDelay: 100, enabled: false })).videoFloor, 0);
});

test("AVSync: the sound follows a slower smooth picture, never the touch drops", () => {
  const s = new AVSync();
  assert.equal(s.update(input({ audioDelay: 150, audioOwnDelay: 150, videoDelay: 250, shownDelay: 120 })).audioDelayGoal, 265);
  assert.equal(s.update(input({ audioDelay: 150, audioOwnDelay: 150, videoDelay: 140, shownDelay: 60 })).audioDelayGoal, null);
});

test("Playout's sync floor: ramps in at 100 ms/s, holds room in the queue, drops to 0 when interactive", () => {
  const p = new Playout<number>({ minSamples: 2 });
  p.syncFloor = 500;
  assert.equal(p.syncFloor, MAX_SYNC_FLOOR_MS, "capped");
  p.syncFloor = 60;
  const mac = 1_000_000, host = 5000;
  for (let i = 0; i < 60; i++) p.push(i, mac + i * 16.7, true, host + i * 16.7 + 40);
  assert.ok(p.syncHold > 50 && p.syncHold <= 60, String(p.syncHold));
  assert.ok(p.hold >= p.depth + p.syncHold);
  assert.ok(p.queued > p.config.maxQueue, "room for the pictures the sync wait holds");
  p.interactive = true;
  assert.equal(p.syncHold, 0);
});

test("AVSyncDriver: feeds the floor to the video and the goal and the report to the sound", () => {
  const set: { goal: number | null; report: [number | null, number | null] | null } = { goal: null, report: null };
  const audio: AVSyncAudio = {
    syncDelays: () => ({ delay: 260, ownDelay: 200, soundRecent: true }),
    setSyncDelayGoal: (g) => void (set.goal = g),
    setSyncReport: (skew, floor) => void (set.report = [skew, floor]),
  };
  const video: AVSyncVideo = { syncDelays: () => ({ smooth: 210, shown: 210 }), interactive: false, syncFloor: 0 };
  const d = new AVSyncDriver(audio, () => video);
  d.tick();
  assert.equal(video.syncFloor, 35);
  assert.equal(set.goal, 225);
  assert.deepEqual(set.report, [50, 35]);
  d.stop();
  assert.equal(video.syncFloor, 0);
  assert.equal(set.goal, null);
});

test("AudioJitter: base and need from the delays, the floor's bump, the sync depth's pace, clock steps", () => {
  const j = new AudioJitter(audioJitterConfig(true));
  assert.equal(j.need, 80, "the LAN starts at its floor");
  for (let i = 0; i < 50; i++) j.observe(30 + (i % 10 === 0 ? 70 : i % 5), i * 20);
  assert.equal(j.base, 30);
  assert.equal(j.need, 90, "p99 of the jitter (70) + 20");
  j.interruption(1000);
  assert.equal(j.floor, 120);
  assert.equal(j.need, 120);
  j.observe(30, 1000 + 16_000);
  assert.equal(j.bump, 30, "10 ms back per 15 s without one");
  const own = j.depth(20_000, 15);
  assert.equal(own, j.need + 15 + 10);
  j.setSyncGoal(own + 100);
  assert.equal(j.depth(21_000, 15), own + 20, "the sync depth moves 20 ms a second");
  j.observe(30 + 900, 21_000);
  j.observe(30 + 900, 22_100);
  assert.equal(j.resets, 1, "a step held for a second starts over");
  const remote = new AudioJitter();
  assert.equal(remote.need, 120);
});

const packet = (seq: number, at: number, frames = 960, value = 0.5): ScheduledPacket => {
  const l = new Float32Array(frames).fill(value);
  return { l, r: l, at, seq, macTime: seq * 20 };
};

function render(s: AudioScheduler, from: number, frames: number): Float32Array {
  const out = new Float32Array(frames);
  const r = new Float32Array(frames);
  for (let f = 0; f < frames; f += 128) s.render(out.subarray(f, f + 128), r.subarray(f, f + 128), from + f);
  return out;
}

test("AudioScheduler: starts at the slot, fades in, conceals a seq gap, underruns when dry, drops late packets", () => {
  const s = new AudioScheduler(audioSchedulerConfig());
  s.push(packet(1, 1000));
  s.push(packet(3, 2920));
  const out = render(s, 0, 128 * 40);
  assert.equal(out[999], 0, "silent before the slot");
  assert.ok(out[1001]! > 0 && out[1001]! < 0.5, "fading in");
  assert.equal(out[1500], 0.5);
  assert.equal(s.stats.concealed, 1, "seq 2 is missing: a packet of silence");
  assert.equal(out[1000 + 960 + 100], 0);
  assert.equal(out[1000 + 1920 + 100], 0.5);
  assert.equal(s.stats.underruns, 1, "ran dry after seq 3");
  assert.equal(s.stats.playing, false);
  s.push(packet(4, 100)); // long past its slot
  s.push(packet(5, 128 * 40 + 500));
  render(s, 128 * 40, 1024);
  assert.equal(s.stats.late, 1);
  assert.equal(s.stats.playing, true);
});

test("AudioScheduler: playing late behind the slots for a second cuts 10 ms; the worklet source stands alone", () => {
  const c = audioSchedulerConfig();
  const s = new AudioScheduler(c);
  // slots 30 ms earlier than where playback is (after the first): it runs behind
  s.push(packet(1, 0));
  for (let i = 2; i < 100; i++) {
    s.push(packet(i, (i - 1) * 960 - 1440));
    render(s, (i - 2) * 960, 960);
  }
  assert.ok(s.stats.cuts >= 1, String(s.stats.cuts));
  assert.equal(s.stats.cutFrames, s.stats.cuts * c.cutFrames);
  // AudioScheduler's source is what the AudioWorklet runs: it must work with nothing around it
  const Fresh = new Function(`const __name = (t) => t; return (${AudioScheduler.toString()});`)() as typeof AudioScheduler;
  const f = new Fresh(c);
  f.push(packet(1, 0));
  assert.equal(render(f, 0, 512)[300], 0.5);
});
