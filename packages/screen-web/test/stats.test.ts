import { test } from "node:test";
import assert from "node:assert/strict";
import { PlayoutMeter, roundReport } from "../src/meter.js";
import { browserNetPath, isNetworkFailure, isUnreachableStatus, NetSampler, netQualityLine, parseNetQuality, withNetSampler } from "../src/net.js";
import { audioStatsLine, latencyEstimate, playoutReportLine, statsLines, streamLine, type StreamStatsSnapshot } from "../src/stats.js";
import { ConnectionModel } from "../src/status.js";
import { RequestError } from "../src/transport.js";

// The stats line's data (the iOS kit's ScreenStreamStats / ScreenPlayoutMeter / ScreenNetSampler / ScreenNetQuality /
// ScreenLatencyEstimate): deterministic, every time injected (ms).

test("meter: fps, gaps, hitches, drops, decode and stalls over the window; pauses aren't gaps", () => {
  const m = new PlayoutMeter();
  m.reset(0);
  // 30 fps for 3 s, one picture held 200 ms longer than the computer's gap, one 100 ms hitch
  let t = 0, mac = 1000;
  for (let i = 0; i < 90; i++) {
    const gap = i === 40 ? 100 : 33;
    t += gap;
    mac += i === 60 ? 33 : gap;
    if (i === 60) t += 200;
    m.arrived(t - 5);
    m.shown(t, 2, mac);
  }
  m.dropped(3, t - 10);
  const r = m.report("smooth", t)!;
  assert.ok(r.fps! > 25 && r.fps! < 32, String(r.fps));
  assert.equal(r.gapP50Ms, 33);
  assert.ok(r.hitchesPerSec! > 0);
  assert.equal(r.decodeMs, 2);
  assert.ok(r.droppedPerSec! > 0.9 && r.droppedPerSec! < 1.1);
  assert.ok(r.stall150PerSec! > 0, "a 200 ms hold is a stall");
  assert.equal(r.stall300PerSec, 0);
  assert.equal(m.report("smooth", t + 10_000), null, "nothing shown in the window");
  assert.deepEqual(roundReport({ mode: "smooth", fps: 29.96, decodeMs: Number.NaN, net: { route: "lan" } }), { mode: "smooth", fps: 30, net: { route: "lan" } });
});

test("net sampler: input round trips on the stream's route, failures and bytes over their windows", () => {
  const n = new NetSampler();
  n.setRoute("tunnel");
  n.streamStarted(0);
  n.inputAnswered("tunnel", 120, 100);
  n.inputAnswered("tunnel", 140, 200);
  n.inputAnswered("lan", 5, 300); // another route: left out
  n.failed(400);
  n.received(30_000, 500);
  n.received(30_000, 550); // same bucket
  n.path = { iface: "wifi" };
  let r = n.report(1000)!;
  assert.deepEqual(r.inputRttMs, { p50: 120, p90: 140, n: 2 });
  assert.equal(r.failures, 1);
  assert.equal(r.iface, "wifi");
  assert.equal(r.route, "tunnel");
  assert.equal(Math.round(r.rxKbps!), 480, "60 kB over the 1 s since the stream started");
  n.setRoute("lan");
  r = n.report(1000)!;
  assert.equal(r.inputRttMs, undefined, "a new route forgets the old round trips");
  r = n.report(20_000)!;
  assert.equal(r.failures, 0);
  assert.equal(new NetSampler().report(0), null, "nothing known");
});

test("browserNetPath from navigator.connection; none without the API", () => {
  assert.equal(browserNetPath(null), null);
  assert.equal(browserNetPath({}), null);
  assert.deepEqual(browserNetPath({ type: "wifi" }), { iface: "wifi" });
  assert.deepEqual(browserNetPath({ type: "cellular", saveData: true }), { iface: "cellular", expensive: true, constrained: true });
  assert.deepEqual(browserNetPath({ type: "ethernet" }), { iface: "wired" });
  assert.deepEqual(browserNetPath({ type: "bluetooth" }), { iface: "other" });
  assert.deepEqual(browserNetPath({ type: "none" }), {});
});

test("network failures: thrown fetches and proxy statuses count; the computer's answers and aborts don't", async () => {
  assert.equal(isNetworkFailure(new TypeError("Failed to fetch")), true);
  assert.equal(isNetworkFailure(new RequestError(502, "bad gateway")), true);
  assert.equal(isNetworkFailure(new RequestError(409, "not the controller")), false);
  assert.equal(isNetworkFailure(new RequestError(503, "no screen")), false);
  assert.equal(isNetworkFailure(new DOMException("aborted", "AbortError")), false);
  assert.equal(isUnreachableStatus(530), true);
  const n = new NetSampler();
  n.setRoute("tunnel");
  let t = 0;
  const send = withNetSampler(async () => void (t += 80), n, () => "tunnel", () => t);
  await send({ type: "click" });
  const failing = withNetSampler(async () => Promise.reject(new TypeError("offline")), n, () => "tunnel", () => t);
  await assert.rejects(failing({ type: "click" }));
  const r = n.report(t)!;
  assert.deepEqual(r.inputRttMs, { p50: 80, p90: 80, n: 1 });
  assert.equal(r.failures, 1);
});

test("the server's grade: lenient parse and its line", () => {
  assert.equal(parseNetQuality(null), null);
  assert.equal(parseNetQuality("x"), null);
  const q = parseNetQuality({ grade: "fair", rttMs: { min: 150, p50: 165.4, p90: 210 }, jitterMs: 73, reasons: ["rtt", "jitter", 4, "x".repeat(40)] })!;
  assert.deepEqual(q, { grade: "fair", rttMs: { min: 150, p50: 165.4, p90: 210 }, jitterMs: 73, reasons: ["rtt", "jitter"] });
  assert.equal(netQualityLine(q), "net fair (rtt, jitter) · rtt 165/210 · jitter 73");
  assert.deepEqual(parseNetQuality({ grade: "great", jitterMs: -1 }), { grade: "unknown", reasons: [] });
});

test("latency estimate: the input's way, the computer, the picture's way back, hold, decode and a refresh", () => {
  assert.equal(latencyEstimate({ inputRttP50Ms: null, rttMinMs: null, holdMs: 20, decodeMs: 2, refreshHz: 60 }), null);
  assert.equal(Math.round(latencyEstimate({ inputRttP50Ms: 100, rttMinMs: 80, holdMs: 20, decodeMs: 2, refreshHz: 100 })!), 50 + 30 + 40 + 20 + 2 + 10);
  assert.equal(Math.round(latencyEstimate({ inputRttP50Ms: null, rttMinMs: 80, holdMs: null, decodeMs: null, refreshHz: null })!), 40 + 30 + 40 + 17);
});

test("the stats line's rows", () => {
  const stream: StreamStatsSnapshot = {
    codec: "h264",
    fps: 59.6,
    kilobytesPerSecond: 412.2,
    decodeMs: 2.14,
    playout: { mode: "smooth", refreshHz: 60, gapP50Ms: 17, gapP90Ms: 18, arrivalGapP50Ms: 16, arrivalGapP90Ms: 24, hitchesPerSec: 0, stall150PerSec: 0, stall300PerSec: 0, bufferMs: 28, jitterP95Ms: 24, bufferCapMs: 100, droppedPerSec: 0.5 },
    interactive: false,
    net: { grade: "good", rttMs: { min: 8, p50: 9, p90: 12 }, reasons: [] },
    inputRttP50Ms: 10,
    rttMinMs: 8,
  };
  assert.equal(streamLine({ ...stream, interactive: true }), "h264 · 60 fps · 412 KB/s · 2.1 ms · live");
  assert.equal(playoutReportLine(stream.playout!), "smooth · 60 Hz · gap 17/18 · arr 16/24 · hitch 0.0/s · stall 0.0/0.0/s · buf 28 ms · jit 24 · cap 100 · drop 0.5/s");
  assert.equal(playoutReportLine({ mode: "latency", touchBufferMs: 21 }), "responsive · gap -/- · arr -/- · touch 21 ms");
  const lines = statsLines({ stream, way: "tunnel", connection: "live ready", audio: { depthMs: 120, bufferedMs: 118, underruns: 0, drops: 1, kbps: 96 } });
  assert.equal(lines.length, 4);
  assert.equal(lines[0], "h264 · 60 fps · 412 KB/s · 2.1 ms · tunnel · live ready");
  assert.match(lines[1]!, / · ~\d+ ms$/);
  assert.equal(lines[2], "net good · rtt 9/12");
  assert.equal(lines[3], "audio 120 ms (buf 118) · 0 underruns · 1 drops · 96 kbps");
  // on a link the link's own line stands in for the grade
  assert.equal(statsLines({ stream, way: "link lan", connection: "live", linkLine: "lan wifi rtt 0.4/1.2/2.0 ms" })[2], "lan wifi rtt 0.4/1.2/2.0 ms");
  assert.equal(audioStatsLine({ depthMs: null, bufferedMs: null, underruns: 0, drops: 0, kbps: 95.6 }), "audio · 96 kbps");
});

test("the connection's codes for the stats line", () => {
  const c = new ConnectionModel();
  assert.equal(c.statsText(0), "live");
  c.status({ display: 1, phase: "ready", since: 0 }, 1);
  assert.equal(c.statsText(2), "live ready");
  c.status({ display: 1, phase: "reconnecting", reason: "helper-restart", since: 0, console: { locked: true } }, 3);
  assert.equal(c.statsText(4), "reconnecting helper-restart · locked");
});
