import { test } from "node:test";
import assert from "node:assert/strict";
import type { StreamAck } from "../src/types.js";
import { AckSender, MAX_IN_FLIGHT, type AckOutcome } from "../src/acks.js";

/** A transport whose acks the test answers by hand. */
function harness() {
  const sent: { ack: StreamAck; answer: (o: AckOutcome) => void }[] = [];
  const timers: (() => void)[] = [];
  const acks = new AckSender(
    "s1234567",
    (ack) => new Promise<AckOutcome>((answer) => sent.push({ ack, answer })),
    (fn) => {
      timers.push(fn);
      return timers.length as unknown as ReturnType<typeof setTimeout>;
    },
  );
  const flush = () => new Promise((r) => setImmediate(r));
  return { acks, sent, timers, flush };
}

test("each picture is acked at once, up to 4 in flight; beyond that only the newest waits (cumulative)", async () => {
  const { acks, sent, flush } = harness();
  for (let seq = 1; seq <= 7; seq++) acks.received(seq);
  assert.deepEqual(sent.map((s) => s.ack.seq), [1, 2, 3, 4]);
  assert.equal(acks.acksInFlight, MAX_IN_FLIGHT);
  sent[0]!.answer("ok");
  await flush();
  // seqs 5, 6 were folded into 7
  assert.deepEqual(sent.map((s) => s.ack.seq), [1, 2, 3, 4, 7]);
  sent[1]!.answer("ok");
  await flush();
  assert.equal(sent.length, 5, "nothing newer: no ack");
});

test("an older seq arriving late doesn't go backwards", () => {
  const { acks, sent } = harness();
  acks.received(5);
  acks.received(3);
  assert.deepEqual(sent.map((s) => s.ack.seq), [5]);
});

test("a key picture request rides on the next ack (right away when a slot is free), and only once", async () => {
  const { acks, sent, flush } = harness();
  acks.received(1);
  acks.requestKeyframe();
  assert.deepEqual(sent.map((s) => [s.ack.seq, s.ack.keyframe ?? false]), [[1, false], [1, true]]);
  sent[0]!.answer("ok");
  sent[1]!.answer("ok");
  await flush();
  assert.equal(sent.length, 2);
});

test("a playout report goes with the next ack only", () => {
  const { acks, sent } = harness();
  acks.attach({ mode: "latency", fps: 30 });
  acks.received(1);
  acks.received(2);
  assert.deepEqual(sent.map((s) => s.ack.report?.fps ?? null), [30, null]);
});

test("a failed ack is sent again after the retry delay (with its key request); 404 stops acking", async () => {
  const { acks, sent, timers, flush } = harness();
  acks.received(1);
  acks.requestKeyframe();
  sent[0]!.answer("failed");
  sent[1]!.answer("failed");
  await flush();
  assert.equal(sent.length, 2, "not at once");
  assert.equal(timers.length, 1, "one retry timer");
  timers[0]!();
  assert.deepEqual(sent.slice(2).map((s) => [s.ack.seq, s.ack.keyframe ?? false]), [[1, true]]);
  sent[2]!.answer("gone");
  await flush();
  assert.equal(acks.isStopped, true);
  acks.received(9);
  assert.equal(sent.length, 3);
});
