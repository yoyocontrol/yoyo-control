import assert from "node:assert/strict";
import { test } from "node:test";
import { classifyPath, isLocalAddress, linkMediaStats, parseLinkStats, RttWindow, statsLine, type LinkStats, type MediaCounters } from "../src/index.js";

const snap = (): LinkStats => ({ path: "direct", iface: "cellular", remote: "93.184.216.34:47820", rttMinMs: 61.2, rttP50Ms: 66, rttP90Ms: 131.4, bytesSent: 10, bytesReceived: 20, packetsLost: 1, datagramsSent: 3, datagramsReceived: 4, datagramDrops: 0 });

test("the link: line as the Rust core writes it", () => {
  assert.equal(statsLine(snap()), "direct cellular rtt 61/66/131 ms");
  const s: LinkStats = { ...snap(), rttMinMs: 1.26, lossPct: 1.04, fecRecovered: 12, nackRecovered: 3, nackSent: 4, lostFrames: 1, skippedFrames: 2, freezeCount: 1, freezeMs: 240, rateTargetMbps: 8, rateSentMbps: 7.43, rateCuts: 2, rateLossCuts: 0, jitterMs: 21.4, fps: 59.6, inputP50Ms: 33, inputP90Ms: 48, inputN: 120, audioLossPct: 0.5, audioRed: 1 };
  assert.equal(statsLine(s), "direct cellular rtt 1.3/66/131 ms loss 1.0 % fec 12 nack 3/4 lost 1 skip 2 freeze 1/240 rate 8.0/7.4 Mbps cuts 2/0 jitter 21 ms fps 60 input 33/48 ms (120) audio loss 0.5 % red 1");
});

test("a peer's link.stats, leniently", () => {
  const p = parseLinkStats({ t: "link.stats", ...snap(), fecRecovered: 5, bogus: "x" })!;
  assert.equal(p.fecRecovered, 5);
  assert.equal(p.remote, "93.184.216.34:47820");
  assert.equal(parseLinkStats({ t: "link.stats" }), null);
  assert.equal(parseLinkStats({ path: "warp", iface: "5g" })!.path, "none");
});

test("media counters as link.stats fields", () => {
  const m: MediaCounters = { atUs: 1, rttMinMs: null, rttP50Ms: null, rttP90Ms: null, lossPct: 0.5, mediaReceived: 100, mediaMissing: 1, fecRecovered: 2, nackRecovered: 3, nackSent: 4, framesDelivered: 50, framesLost: 1, framesSkipped: 0, freezes: 0, freezeMs: 0, fps: 60, inputP50Ms: null, inputP90Ms: null, inputEvents: 7, inputFailed: 0, audioLossPct: null, audioLost: 0, audioRecovered: 0 };
  const s = linkMediaStats(m);
  assert.deepEqual(s, { mediaReceived: 100, mediaMissing: 1, fecRecovered: 2, nackRecovered: 3, nackSent: 4, lostFrames: 1, skippedFrames: 0, freezeCount: 0, freezeMs: 0, inputN: 7, lossPct: 0.5, fps: 60 });
});

test("rtt window summary", () => {
  const w = new RttWindow(10_000);
  assert.deepEqual(w.summary(), [0, 0, 0]);
  for (let i = 1; i <= 10; i++) w.push(i * 1000, i * 10);
  assert.deepEqual(w.summary(), [10, 60, 90]);
  w.push(25_000, 5);
  assert.deepEqual(w.summary(), [5, 5, 5]);
});

test("path kinds of the selected candidate pair", () => {
  assert.equal(isLocalAddress("192.168.1.2"), true);
  assert.equal(isLocalAddress("10.0.0.1"), true);
  assert.equal(isLocalAddress("172.20.1.1"), true);
  assert.equal(isLocalAddress("100.64.0.1"), false);
  assert.equal(isLocalAddress("fd12::1"), true);
  assert.equal(isLocalAddress("fe80::1"), true);
  assert.equal(isLocalAddress("2001:db8::1"), false);
  assert.deepEqual(classifyPath({ candidateType: "host" }, { candidateType: "host", address: "192.168.1.10", port: 47821 }), { kind: "lan", remote: "192.168.1.10:47821" });
  assert.equal(classifyPath({ candidateType: "srflx" }, { candidateType: "host", address: "93.184.216.34", port: 47821 }).kind, "direct");
  assert.equal(classifyPath({ candidateType: "host" }, { candidateType: "prflx", address: "93.184.216.34", port: 50111 }).kind, "punched");
  assert.equal(classifyPath({ candidateType: "host" }, { candidateType: "srflx", address: "93.184.216.34", port: 50111 }).kind, "punched");
  assert.deepEqual(classifyPath({ candidateType: "host" }, { candidateType: "host", address: "2001:db8::1", port: 1 }), { kind: "direct", remote: "[2001:db8::1]:1" });
  assert.equal(classifyPath(undefined, undefined).kind, "none");
});
