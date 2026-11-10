import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { LinkMedia, LinkRequestError, loadLinkMedia, type MediaEvent } from "../src/index.js";

const WASM = fileURLToPath(new URL("../src/wasm/uu_link_wasm_bg.wasm", import.meta.url));
const FIXTURE = fileURLToPath(new URL("../../../link/wasm/tests/fixtures/fec-frame.bin", import.meta.url));

/** link/wasm/tests/fec_fixture.rs's file: the native sender's datagrams for one key frame, what to drop, the AU. */
function fixture() {
  const b = readFileSync(FIXTURE);
  assert.equal(b.subarray(0, 5).toString(), "UUFX1");
  let at = 5;
  const u16 = () => ((at += 2), b.readUInt16BE(at - 2));
  const u32 = () => ((at += 4), b.readUInt32BE(at - 4));
  const datagrams: Uint8Array[] = [];
  for (let n = u32(); n > 0; n--) {
    const len = u16();
    datagrams.push(new Uint8Array(b.subarray(at, at + len)));
    at += len;
  }
  const drops = new Set<number>();
  for (let n = u16(); n > 0; n--) drops.add(u16());
  const len = u32();
  return { datagrams, drops, au: new Uint8Array(b.subarray(at, at + len)) };
}

const media = () => loadLinkMedia(readFileSync(WASM));

test("the wasm media layer restores the native sender's frame with its FEC (cross-check with the Rust test)", async () => {
  const m = (await media()).createClientMedia();
  const { datagrams, drops, au } = fixture();
  assert.equal(drops.size, 2);
  m.openVideo(1);
  const now = 1_000_000;
  datagrams.forEach((d, i) => {
    if (!drops.has(i)) assert.equal(m.onDatagram(d, now), true);
  });
  const events: MediaEvent[] = [];
  for (let e = m.pollEvent(); e; e = m.pollEvent()) events.push(e);
  const frame = events.find((e) => e.type === "frame");
  assert.ok(frame && frame.type === "frame");
  assert.deepEqual({ stream: frame.stream, frame: frame.frame, codec: frame.codec, kind: frame.kind, width: frame.width, height: frame.height, captureUs: frame.captureUs }, { stream: 1, frame: 1, codec: "h264", kind: "key", width: 640, height: 360, captureUs: 1_700_000_000_000_000 });
  assert.ok(Buffer.from(frame.au).equals(Buffer.from(au)), "the same access unit");
  assert.equal(m.stats(now).fecRecovered, 2);
  m.frameDecoded(1, 1, true);
  // feedback goes (frame report, transport-cc) on channel 4
  const out: Uint8Array[] = [];
  for (let d = m.pollTransmit(now + 30_000); d; d = m.pollTransmit(now + 30_000)) out.push(d);
  assert.ok(out.length > 0 && out.every((d) => d[0] === ((4 << 4) | 1)));
  const traces = m.takeRxTraces();
  assert.equal(traces[0]?.fate, "delivered");
  assert.equal(traces[0]?.fec, 2);
  m.free();
});

test("input goes on channel 3 at once; overflow is a local 429", async () => {
  const engine = (await media()).createClientMedia({ inputMaxUnacked: 2 });
  let now = 5_000_000;
  const sent: Uint8Array[] = [];
  const lm = new LinkMedia(engine, (d) => sent.push(d), () => now);
  const seq = lm.sendInput('{"type":"click","x":0.5,"y":0.5}', false);
  assert.equal(typeof seq, "number");
  assert.ok(sent.some((d) => d[0] === ((3 << 4) | 1)));
  lm.sendInput('{"type":"key","key":"a"}', false);
  assert.throws(() => lm.sendInput('{"type":"key","key":"b"}', false), (e: unknown) => e instanceof LinkRequestError && e.status === 429);
  assert.equal(lm.inputUnacked, 2);
  // a move never overflows
  lm.sendInput('{"type":"move","x":0.1,"y":0.1}', true);
  assert.ok(lm.counters()!.inputEvents >= 0);
  lm.end();
  assert.throws(() => lm.sendInput("{}", false), /ended/);
  now++;
});

test("the driver's timer resends unacked input", async () => {
  const engine = (await media()).createClientMedia();
  const t0 = performance.now();
  const sent: number[] = [];
  const lm = new LinkMedia(engine, () => sent.push(performance.now() - t0), () => Math.round(performance.now() * 1000));
  lm.sendInput('{"type":"click","x":0.5,"y":0.5}', false);
  await new Promise((r) => setTimeout(r, 120));
  // at once, the duplicate 5 ms later, then resends while unacked
  assert.ok(sent.length >= 3, `sent ${sent.length}`);
  lm.end();
});
