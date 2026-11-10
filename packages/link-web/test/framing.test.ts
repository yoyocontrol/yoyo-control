import assert from "node:assert/strict";
import { test } from "node:test";
import { decodeFrameBody, encodeFrame, FrameReader, LinkError, messageBytes } from "../src/index.js";

test("a frame is u32 BE length + JSON", () => {
  const f = encodeFrame({ t: "hello", v: 1 });
  assert.equal(new DataView(f.buffer).getUint32(0), f.length - 4);
  assert.deepEqual(decodeFrameBody(f.subarray(4)), { t: "hello", v: 1 });
  assert.throws(() => encodeFrame([1, 2] as unknown as object), LinkError);
  assert.throws(() => encodeFrame({ t: "x".repeat(100) }, 50), /over 50/);
  assert.throws(() => decodeFrameBody(new TextEncoder().encode("[1]")), /not a JSON object/);
  assert.throws(() => decodeFrameBody(new TextEncoder().encode("{")), /not JSON/);
});

test("frames split across messages and several in one", () => {
  const a = encodeFrame({ t: "a" }), b = encodeFrame({ t: "b", n: 2 });
  const all = new Uint8Array(a.length + b.length);
  all.set(a);
  all.set(b, a.length);
  const r = new FrameReader();
  assert.deepEqual(r.push(all.subarray(0, 3)), []);
  assert.deepEqual(r.push(all.subarray(3, a.length + 2)), [{ t: "a" }]);
  assert.equal(r.pending, 2);
  assert.deepEqual(r.push(all.subarray(a.length + 2)), [{ t: "b", n: 2 }]);
  assert.deepEqual(new FrameReader().push(all), [{ t: "a" }, { t: "b", n: 2 }]);
});

test("a frame over the limit is a protocol error before its body comes", () => {
  const r = new FrameReader(10);
  const head = new Uint8Array(4);
  new DataView(head.buffer).setUint32(0, 11);
  assert.throws(() => r.push(head), (e: unknown) => e instanceof LinkError && e.kind === "protocol");
});

test("the bytes after a head stay for the body", () => {
  const head = encodeFrame({ s: 200 });
  const msg = new Uint8Array(head.length + 3);
  msg.set(head);
  msg.set([1, 2, 3], head.length);
  const r = new FrameReader();
  r.append(msg);
  assert.deepEqual(r.next(), { s: 200 });
  assert.deepEqual([...r.rest()], [1, 2, 3]);
  assert.equal(r.pending, 0);
});

test("message data as bytes", () => {
  assert.deepEqual([...messageBytes(new Uint8Array([1, 2]).buffer)], [1, 2]);
  assert.deepEqual([...messageBytes("hi")], [104, 105]);
  assert.throws(() => messageBytes(42), LinkError);
});
