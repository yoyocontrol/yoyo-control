import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_PLAYOUT, paceFor, percentile, Playout, playoutConfig, playoutLine, REMOTE_MAX_DEPTH_MS, touchBudgetMs } from "../src/playout.js";

// Smooth playback and its responsive mode (docs/PROTOCOL.md「客户端的平滑播放」): the same rules and the same simulated
// paths as the iOS kit's ScreenPlayout tests. Deterministic: every time is injected (ms), the jitter is an LCG.

const MAC = 1_761_170_000_000;
const HOST = 5_000_000;
const HZ = 120;
const REFRESH = 1000 / HZ;

function noise(seed: number): () => number {
  let s = BigInt(seed);
  return () => {
    s = (s * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn;
    return Number(s >> 11n) / 2 ** 53;
  };
}

interface Arrival {
  mac: number;
  at: number;
}

/** `fps` pictures for `seconds`, `network` ms on the way plus `jitter(t, n)`; in order, as on one connection. */
function pictures(seconds: number, jitter: (t: number, n: () => number) => number, fps = 60, network = 80, seed = 3): Arrival[] {
  const n = noise(seed);
  let last = -Infinity;
  return Array.from({ length: Math.floor(seconds * fps) }, (_, i) => {
    const t = (i * 1000) / fps;
    last = Math.max(last, HOST + t + network + jitter(t, n));
    return { mac: MAC + t, at: last };
  });
}

/** 5G as measured: most pictures within ~15 ms, one in twenty 40–110 ms later. */
const fiveG = (_t: number, n: () => number) => (n() < 0.05 ? 40 + n() * 70 : n() * 15);

interface Run {
  shown: (number | null)[];
  holds: { at: number; hold: number }[];
  maxWaiting: number;
  lastShown: number | null;
}

/** A 120 Hz display: before each refresh the interactivity is set, the arrived pictures pushed, the next one taken. */
function play(ps: Arrival[], core: Playout<number>, opts: { until?: number; interactive?: (now: number) => boolean } = {}): Run {
  const run: Run = { shown: ps.map(() => null), holds: [], maxWaiting: 0, lastShown: null };
  let next = 0;
  const end = opts.until ?? (ps.at(-1)?.at ?? HOST) + 400;
  core.lead = REFRESH;
  for (let tick = 0; ; tick++) {
    const now = HOST + tick * REFRESH;
    if (now > end) break;
    core.interactive = opts.interactive?.(now) ?? false;
    while (next < ps.length && ps[next]!.at <= now) {
      core.push(next, ps[next]!.mac, true, ps[next]!.at);
      next++;
    }
    const i = core.next(now + REFRESH);
    if (i !== null) {
      run.shown[i] = now + REFRESH;
      run.lastShown = i;
    }
    run.maxWaiting = Math.max(run.maxWaiting, core.queued);
    run.holds.push({ at: now, hold: core.hold });
  }
  return run;
}

/** Off the LAN (the 200 ms cap) with the touch budget of a 136 ms round trip (34 ms). */
function remote(discard?: (p: number) => void): Playout<number> {
  const core = new Playout<number>(playoutConfig({ capMs: REMOTE_MAX_DEPTH_MS }), discard);
  core.touchBudget = touchBudgetMs(136, false);
  return core;
}

function learned(ps: Arrival[]): Playout<number> {
  const core = remote();
  play(ps, core);
  return core;
}

const gaps = (ts: number[]) => ts.slice(1).map((t, i) => t - ts[i]!);

// ---- smooth

test("smooth: jittery arrivals are shown at an even pace; the depth grows at once and shrinks back slowly", () => {
  // 30 fps, calm (0–2 ms) for 4 s, jittery (0–40 ms) for 3 s, calm again for 10 s
  const ps = pictures(17, (t, n) => n() * (t >= 4000 && t < 7000 ? 40 : 2), 30, 40, 7);
  const core = new Playout<number>();
  const depths: { at: number; depth: number }[] = [];
  for (const [i, p] of ps.entries()) {
    core.push(i, p.mac, true, p.at);
    depths.push({ at: p.at - HOST, depth: core.depth });
  }
  const at = (t: number) => depths.filter((d) => d.at <= t).at(-1)!.depth;
  assert.ok(at(3900) < 10);
  assert.ok(at(4600) > 20);
  assert.ok(at(6900) > 35 && at(6900) <= 60);
  for (let k = 1; k < depths.length; k++) {
    const a = depths[k - 1]!, b = depths[k]!;
    if (b.depth < a.depth) assert.ok(a.depth - b.depth <= 0.010 * (b.at - a.at) + 1e-9, "shrinks by at most 10 ms a second");
  }
  assert.ok(at(16900) < 10);
  assert.equal(core.resets, 0);
  // played: after the first second the shown pictures are 33 ms apart (even), though the arrivals are not
  const played = new Playout<number>();
  const run = play(pictures(4, (_t, n) => n() * 30, 30, 40, 7), played);
  const shownGaps = gaps(run.shown.slice(40).filter((t): t is number => t !== null));
  const even = shownGaps.filter((g) => Math.abs(g - 1000 / 30) <= REFRESH + 1e-9).length / shownGaps.length;
  assert.ok(even > 0.9, `even share ${even}`);
});

test("the remote cap absorbs 5G jitter; the queue never passes its cap and discarded pictures are let go", () => {
  const config = playoutConfig({ capMs: REMOTE_MAX_DEPTH_MS });
  assert.equal(config.maxDepthMs, 200);
  assert.equal(config.maxQueue, 18);
  assert.equal(DEFAULT_PLAYOUT.maxDepthMs, 100);
  assert.equal(DEFAULT_PLAYOUT.maxQueue, 12);
  let discarded = 0;
  const core = remote(() => discarded++);
  for (let i = 0; i < 30; i++) core.push(i, MAC + i * 16, true, HOST + i * 16 + 80);
  assert.equal(core.queued, 18);
  const shown = core.next(HOST + 10_000);
  assert.equal(shown, 29, "the newest due one");
  assert.equal(core.queued, 0);
  assert.equal(discarded, 29, "every other picture was let go");
  assert.equal(core.dropped, 12 + 17);
  // without a frame time: shown now, what waited is let go
  core.push(100, MAC + 1000, true, HOST + 1080);
  assert.equal(core.push(101, null, true, HOST + 1090), "now");
  assert.equal(core.queued, 0);
  assert.equal(discarded, 30);
  // flush (the stream ended) lets go too, not counted as dropped
  core.push(102, MAC + 1100, true, HOST + 1180);
  const dropped = core.dropped;
  core.flush();
  assert.equal(discarded, 31);
  assert.equal(core.dropped, dropped);
});

test("pace: never slower than the content", () => {
  assert.equal(paceFor(37, 1000 / 120), 4);
  assert.equal(paceFor(25, 1000 / 120), 3);
  assert.equal(paceFor(25, 1000 / 60), 1);
  assert.equal(paceFor(1000 / 60, 1000 / 120), 2);
});

// ---- the interactive depth

test("interactive: the depth drops to about one picture interval (bounded), none on a calm path or the LAN", () => {
  const core = learned(pictures(4, fiveG));
  assert.ok(core.depth > 60, `smooth depth ${core.depth}`);
  assert.equal(core.touchBudget, 34);
  const d = core.interactiveDepth!;
  assert.ok(Math.abs(d - (1000 / 60 + 4)) < 1, `interactive depth ${d}`);
  assert.equal(core.touchBuffer, null, "not interactive yet");
  core.interactive = true;
  assert.equal(core.touchBuffer, d);
  assert.ok(Math.abs(core.hold - (d + core.lead)) < 1e-9);
  assert.equal(core.paceInterval, null);
  // 30 fps: the 30 ms ceiling
  const slow = learned(pictures(4, fiveG, 30));
  assert.equal(slow.interactiveDepth, 30);
  // a short round trip: the touch budget binds
  const near = learned(pictures(4, fiveG));
  near.touchBudget = 12;
  assert.equal(near.interactiveDepth, 12);
  // a calm path: the smooth depth is under 8 ms, shown on arrival
  const calm = learned(pictures(4, (_t, n) => n() * 2));
  assert.ok(calm.depth < 8);
  assert.equal(calm.interactiveDepth, null);
  calm.interactive = true;
  assert.equal(calm.hold, 0);
  assert.equal(calm.push(0, MAC + 4000, true, HOST + 4080), "now");
  // the LAN: no touch budget
  const lan = new Playout<number>();
  lan.touchBudget = touchBudgetMs(8, true);
  assert.equal(lan.interactiveDepth, null);
});

test("the touch budget: a quarter of the minimum round trip, at most 45 ms; none on the LAN", () => {
  assert.equal(touchBudgetMs(136, false), 34);
  assert.equal(touchBudgetMs(240, false), 45);
  assert.equal(touchBudgetMs(32, false), 8);
  assert.equal(touchBudgetMs(30, false), null);
  assert.equal(touchBudgetMs(8, true), null);
  assert.equal(touchBudgetMs(null, true), null);
  assert.equal(touchBudgetMs(null, false), 30);
  assert.equal(touchBudgetMs(Number.NaN, false), 30);
});

// ---- catching up

test("a finger down catches the queue up on the next refresh (only undrawn pictures are dropped)", () => {
  const ps = pictures(5, fiveG);
  const now = HOST + 4000;
  const waiting = (run: Run) => ps.map((_, i) => i).filter((i) => i > (run.lastShown ?? -1) && ps[i]!.at <= now);
  let discarded = 0;
  const core = remote(() => discarded++);
  const run = play(ps, core, { until: now });
  const queued = waiting(run);
  assert.equal(core.queued, queued.length);
  assert.ok(queued.length >= 4, `${core.depth} ms of pictures wait`);
  const d = core.interactiveDepth!;
  const base = core.base!;
  core.interactive = true;
  const target = now + 2 * REFRESH;
  const expected = queued.filter((i) => Math.min(ps[i]!.mac + base + d, ps[i]!.at + d) + core.lead <= target).at(-1)!;
  const before = { dropped: core.dropped, discarded };
  assert.equal(core.next(target), expected);
  assert.equal(core.dropped - before.dropped, queued.indexOf(expected));
  assert.equal(discarded - before.discarded, queued.indexOf(expected));
  assert.ok(target - (ps[expected]!.mac + base) < d + core.lead + 1000 / 60 + 1e-9);
  // without a touch budget: the newest shows at once
  const lan = remote();
  const lanRun = play(ps, lan, { until: now });
  lan.touchBudget = null;
  lan.interactive = true;
  assert.equal(lan.next(now + REFRESH), waiting(lanRun).at(-1));
  assert.equal(lan.queued, 0);
});

test("a stall while interactive shows on the next refresh", () => {
  const core = learned(pictures(3, fiveG));
  core.interactive = true;
  const at = HOST + 3900;
  assert.equal(core.push(1, MAC + 3000, true, at), "queued");
  assert.equal(core.next(at + REFRESH), 1);
});

test("refine / keepalive pictures are due on arrival and not sampled", () => {
  const core = learned(pictures(3, fiveG));
  const base = core.base;
  core.push(7, MAC, false, HOST + 3500);
  assert.equal(core.next(HOST + 3500), 7);
  assert.equal(core.base, base);
});

// ---- a jittery path

test("interactive on 5G: shown within the interactive depth, far sooner than smooth, never starved", () => {
  const ps = pictures(12, fiveG);
  const touchAt = HOST + 4000;
  const core = remote();
  const run = play(ps, core, { interactive: (now) => now >= touchAt });
  const d = core.interactiveDepth!;
  assert.ok(d < 25);
  const touching = ps.map((_, i) => i).filter((i) => ps[i]!.at > touchAt + 500);
  const waits: number[] = [];
  for (const i of touching) {
    const at = run.shown[i];
    if (at === null || at === undefined) continue;
    const wait = at - ps[i]!.at;
    assert.ok(wait <= d + 2 * REFRESH + 1e-9, `waited ${wait}`);
    waits.push(wait);
  }
  assert.ok(waits.length / touching.length > 0.7);
  const median = percentile(waits, 0.5)!;
  assert.ok(median < 30);
  const shownTimes = touching.map((i) => run.shown[i]).filter((t): t is number => t !== null && t !== undefined);
  const longestShown = Math.max(...gaps(shownTimes));
  const longestArrival = Math.max(...gaps(touching.map((i) => ps[i]!.at)));
  assert.ok(longestShown <= longestArrival + d + 2 * REFRESH + 1e-9, "no starvation");
  const watching = ps.map((_, i) => i).filter((i) => ps[i]!.at > HOST + 2000 && ps[i]!.at < touchAt);
  const smoothWaits = watching.map((i) => (run.shown[i] ?? NaN) - ps[i]!.at).filter((w) => !Number.isNaN(w));
  assert.ok(percentile(smoothWaits, 0.5)! > 2 * median);
});

test("extreme jitter while interactive: in order, nothing waits past the interactive cap", () => {
  const ps = pictures(10, (t, n) => (Math.floor((t * 60) / 1000) % 97 === 0 ? 600 : n() < 0.5 ? n() * 300 : 0), 60, 80, 99);
  const core = remote();
  const run = play(ps, core, { interactive: () => true });
  const order = run.shown.map((at, i) => [i, at] as const).filter((x): x is readonly [number, number] => x[1] !== null).sort((a, b) => a[1] - b[1]);
  assert.ok(order.length > 100);
  for (let k = 1; k < order.length; k++) assert.ok(order[k - 1]![0] < order[k]![0], "in order");
  for (const [i, at] of order) assert.ok(at - ps[i]!.at <= core.config.interactiveCapMs + 2 * REFRESH + 1e-9);
  assert.notEqual(run.shown.at(-1), null);
});

// ---- back to smooth

test("after the tail the depth eases back (at most 100 ms a second), with no freeze", () => {
  const ps = pictures(12, fiveG);
  const on = HOST + 3000, off = HOST + 6000;
  const core = remote();
  const run = play(ps, core, { interactive: (now) => now >= on && now < off });
  assert.ok(core.depth > 60);
  const smoothHold = core.depth + core.lead;
  const after = run.holds.filter((h) => h.at >= off);
  const first = after[0]!;
  assert.ok(first.hold < 35, `starts at the interactive depth (${first.hold})`);
  for (const b of after) assert.ok(b.hold <= first.hold + 0.1 * (b.at - off) + 1e-6);
  const back = after.find((h) => h.hold >= smoothHold - 2)!;
  assert.ok(back, "reaches the smooth depth");
  assert.ok(back.at - off <= (smoothHold - first.hold) / 0.1 + 300);
  const ramp = after.filter((h) => h.at <= back.at);
  for (let k = 1; k < ramp.length; k++) assert.ok(ramp[k]!.hold >= ramp[k - 1]!.hold - 0.01 * (ramp[k]!.at - ramp[k - 1]!.at) - 2);
  const window = ps.map((_, i) => i).filter((i) => ps[i]!.at >= off && ps[i]!.at < off + 1500);
  const shown = window.map((i) => run.shown[i]).filter((t): t is number => t !== null && t !== undefined).sort((a, b) => a - b);
  assert.ok(shown.length / window.length > 0.7);
  const g = gaps(shown);
  assert.ok(percentile(g, 0.9)! < 30);
  assert.ok(Math.max(...g) < 120);
});

// ---- decoder pressure, the stats line

test("trim keeps the newest waiting pictures and lets the rest go", () => {
  let discarded = 0;
  const core = remote(() => discarded++);
  for (let i = 0; i < 5; i++) core.push(i, MAC + i * 16, true, HOST + i * 16 + 80);
  core.trim(1);
  assert.equal(core.queued, 1);
  assert.equal(discarded, 4);
  assert.equal(core.dropped, 4);
  assert.equal(core.next(HOST + 10_000), 4);
});

test("the stats line says smooth / responsive and the depth", () => {
  const base = { holdMs: 104.2, depthMs: 96, touchMs: null, jitterMs: 92, capMs: 200, queued: 5, refreshHz: 120, paceMs: 16.7 };
  assert.equal(playoutLine({ mode: "smooth", ...base }), "smooth · 120 Hz · pace 17 · buf 104 ms · depth 96 · jit 92 · cap 200");
  assert.equal(
    playoutLine({ mode: "responsive", ...base, holdMs: 29, touchMs: 20.7, paceMs: null }),
    "responsive · 120 Hz · buf 29 ms · touch 21 ms · depth 96 · jit 92 · cap 200",
  );
});
