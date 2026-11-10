import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { avcC, codecString, lengthPrefixed, nalType, nalUnits, sameBytes, splitAccessUnit } from "../src/h264.js";
import { PartParser } from "../src/parts.js";

const FIXTURE = new Uint8Array(readFileSync(resolve(import.meta.dirname, "fixtures/screen-stream.bin")));
const pictures = new PartParser("frame").feed(FIXTURE).filter((p) => p.kind === "h264");

test("nalUnits: 3- and 4-byte start codes, a leading zero of the next code dropped, junk before the first dropped", () => {
  const data = new Uint8Array([9, 9, 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 4, 5, 0]);
  assert.deepEqual(nalUnits(data).map((u) => [...u]), [[0x67, 1, 2], [0x68, 3], [0x65, 4, 5, 0]]);
  assert.deepEqual(nalUnits(new Uint8Array([1, 2, 3])), []);
});

test("lengthPrefixed: 4-byte big-endian lengths", () => {
  const out = lengthPrefixed([new Uint8Array([0x65, 1]), new Uint8Array(300).fill(7)]);
  assert.deepEqual([...out.subarray(0, 6)], [0, 0, 0, 2, 0x65, 1]);
  assert.deepEqual([...out.subarray(6, 10)], [0, 0, 1, 44]);
  assert.equal(out.length, 4 + 2 + 4 + 300);
});

test("the recorded key picture: SPS + PPS + IDR; codec avc1.640020; avcC built from them", () => {
  const key = splitAccessUnit(pictures[0]!.body);
  assert.equal(key.sps.length, 1);
  assert.equal(key.pps.length, 1);
  assert.equal(key.idr, true);
  assert.ok(key.slices.every((s) => nalType(s) !== 7 && nalType(s) !== 8 && nalType(s) !== 9));
  assert.equal(codecString(key.sps[0]!), "avc1.640020");
  const c = avcC(key.sps, key.pps)!;
  assert.equal(c[0], 1);
  assert.deepEqual([...c.subarray(1, 4)], [...key.sps[0]!.subarray(1, 4)]);
  assert.equal(c[4], 0xff); // 4-byte lengths
  assert.equal(c[5], 0xe1); // one SPS
  const spsLen = (c[6]! << 8) | c[7]!;
  assert.equal(spsLen, key.sps[0]!.length);
  assert.ok(sameBytes(c.subarray(8, 8 + spsLen), key.sps[0]));
  assert.equal(c[8 + spsLen], 1); // one PPS
  const ppsLen = (c[9 + spsLen]! << 8) | c[10 + spsLen]!;
  assert.ok(sameBytes(c.subarray(11 + spsLen, 11 + spsLen + ppsLen), key.pps[0]));
  assert.equal(c.length, 11 + spsLen + ppsLen);
});

test("refines are plain deltas: no parameter sets, no IDR", () => {
  for (const p of pictures.slice(1)) {
    const au = splitAccessUnit(p.body);
    assert.equal(au.sps.length + au.pps.length, 0);
    assert.equal(au.idr, false);
    assert.ok(au.slices.length > 0);
  }
});

test("no avcC without both parameter sets; sameBytes", () => {
  assert.equal(avcC([], [new Uint8Array([0x68])]), null);
  assert.equal(avcC([new Uint8Array([0x67, 0x64, 0, 0x20])], []), null);
  assert.equal(codecString(new Uint8Array([0x67, 0x42])), null);
  assert.ok(sameBytes(new Uint8Array([1, 2]), new Uint8Array([1, 2])));
  assert.ok(!sameBytes(new Uint8Array([1, 2]), new Uint8Array([1, 3])));
  assert.ok(!sameBytes(null, new Uint8Array([1])));
});
