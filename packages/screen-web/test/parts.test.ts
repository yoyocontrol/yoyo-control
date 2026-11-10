import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { boundaryOf, headersFrom, indexOfBytes, isLivePicture, parseHeaderBlock, partKind, PartParser, type StreamPart } from "../src/parts.js";

const enc = new TextEncoder();
/** The stream recorded from the test account's Linux desktop (status part, key picture, two refines). */
const FIXTURE = new Uint8Array(readFileSync(resolve(import.meta.dirname, "fixtures/screen-stream.bin")));

function part(type: string, body: string | Uint8Array, headers: Record<string, string | number> = {}, boundary = "frame", length = true): Uint8Array {
  const b = typeof body === "string" ? enc.encode(body) : body;
  const head = [`--${boundary}`, `Content-Type: ${type}`, ...(length ? [`Content-Length: ${b.length}`] : []), ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`)].join("\r\n");
  const out = new Uint8Array(enc.encode(head + "\r\n\r\n").length + b.length + 2);
  out.set(enc.encode(head + "\r\n\r\n"), 0);
  out.set(b, out.length - b.length - 2);
  out.set(enc.encode("\r\n"), out.length - 2);
  return out;
}
const concat = (...xs: Uint8Array[]) => {
  const out = new Uint8Array(xs.reduce((s, x) => s + x.length, 0));
  let o = 0;
  for (const x of xs) {
    out.set(x, o);
    o += x.length;
  }
  return out;
};
function feedIn(p: PartParser, data: Uint8Array, cuts: number[]): StreamPart[] {
  const out: StreamPart[] = [];
  let at = 0;
  for (const c of [...cuts, data.length]) {
    out.push(...p.feed(data.subarray(at, c)));
    at = c;
  }
  return out;
}

test("boundaryOf: the media type's boundary, quotes, none", () => {
  assert.equal(boundaryOf("application/vnd.yoyo-control.stream; boundary=frame"), "frame");
  assert.equal(boundaryOf("application/vnd.yoyo-control.audio; boundary=other"), "other");
  assert.equal(boundaryOf('multipart/mixed; charset=utf-8; Boundary="b 1"'), "b 1");
  assert.equal(boundaryOf("application/json"), null);
  assert.equal(boundaryOf(null), null);
});

test("partKind: Yoyo Control's names; audio/*; unknown = other", () => {
  assert.equal(partKind("video/h264"), "h264");
  assert.equal(partKind("video/hevc"), "hevc");
  assert.equal(partKind("application/vnd.yoyo-control.cursor+json"), "cursor");
  assert.equal(partKind("application/vnd.yoyo-control.status+json; charset=utf-8"), "status");
  assert.equal(partKind("audio/opus"), "audio");
  assert.equal(partKind("image/jpeg"), "other");
  assert.equal(partKind(undefined), "other");
});

test("headers: numbers parse or are absent; kind and codec lowercased", () => {
  const h = parseHeaderBlock("Content-Type: video/h264\r\nContent-Length: 12\r\nX-Frame-Width: 1280\r\nX-Frame-Height: 0\r\nX-Frame-Seq: 7\r\nX-Frame-Time: 1793471227385\r\nX-Frame-Kind: KEY\r\nX-Stream-Codec: H264\r\nX-Audio-Seq: -1");
  assert.deepEqual(h, { contentType: "video/h264", length: 12, width: 1280, seq: 7, time: 1793471227385, kind: "key", codec: "h264" });
  assert.deepEqual(headersFrom(() => null), {});
  assert.equal(isLivePicture({ kind: "refine" }), false);
  assert.equal(isLivePicture({ kind: "delta" }), true);
});

test("indexOfBytes", () => {
  const hay = enc.encode("ab--frame\r\n--fra");
  assert.equal(indexOfBytes(hay, enc.encode("--frame")), 2);
  assert.equal(indexOfBytes(hay, enc.encode("--frame"), 3), -1);
  assert.equal(indexOfBytes(hay, enc.encode("\r\n")), 9);
});

test("the recorded fixture: status, key, refine, refine — whatever the chunking", () => {
  const whole = new PartParser("frame").feed(FIXTURE);
  assert.deepEqual(whole.map((p) => [p.kind, p.headers.seq, p.headers.kind]), [
    ["status", 1, "status"],
    ["h264", 2, "key"],
    ["h264", 3, "refine"],
    ["h264", 4, "refine"],
  ]);
  assert.equal(whole[1]!.headers.width, 1280);
  assert.equal(whole[1]!.body.length, whole[1]!.headers.length);
  assert.deepEqual(JSON.parse(new TextDecoder().decode(whole[0]!.body)).phase, "ready");
  // byte by byte, and at random places
  const p1 = new PartParser("frame");
  const bytes: StreamPart[] = [];
  for (let i = 0; i < FIXTURE.length; i++) bytes.push(...p1.feed(FIXTURE.subarray(i, i + 1)));
  assert.deepEqual(bytes.map((p) => p.body.length), whole.map((p) => p.body.length));
  let seed = 7;
  const rnd = () => (seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31;
  for (let round = 0; round < 20; round++) {
    const cuts = Array.from({ length: 12 }, () => Math.floor(rnd() * FIXTURE.length)).sort((a, b) => a - b);
    const got = feedIn(new PartParser("frame"), FIXTURE, cuts);
    assert.deepEqual(got.map((p) => [p.headers.seq, p.body.length]), whole.map((p) => [p.headers.seq, p.body.length]));
    assert.deepEqual(got[1]!.body, whole[1]!.body);
  }
});

test("unknown types are reported bodiless (their seq is no gap); preamble and the closing boundary are skipped", () => {
  const data = concat(enc.encode("preamble\r\n"), part("image/jpeg", "JPEGDATA", { "X-Frame-Seq": 5 }, "b2"), part("application/vnd.yoyo-control.cursor+json", '{"x":0.5,"y":0.5,"visible":true,"shapeId":0}', { "X-Frame-Seq": 6 }, "b2"), enc.encode("--b2--\r\n"));
  const parts = new PartParser("b2").feed(data);
  assert.deepEqual(parts.map((p) => [p.kind, p.headers.seq, p.body.length]), [
    ["other", 5, 0],
    ["cursor", 6, 44],
  ]);
});

test("a part without Content-Length ends at the next boundary", () => {
  const data = concat(part("audio/opus", "abc\r\ndef", { "X-Audio-Seq": 1 }, "frame", false), part("audio/opus", "xyz", { "X-Audio-Seq": 2 }, "frame", false), enc.encode("--frame--"));
  const got = feedIn(new PartParser("frame"), data, [10, 30, 31, 50]);
  assert.deepEqual(got.map((p) => new TextDecoder().decode(p.body)), ["abc\r\ndef", "xyz"]);
  assert.deepEqual(got.map((p) => p.headers.audioSeq), [1, 2]);
});

test("an oversized part is skipped unread; the buffer stays bounded", () => {
  const big = new Uint8Array(2048).fill(1);
  const data = concat(part("application/vnd.yoyo-control.status+json", big, { "X-Frame-Seq": 1 }), part("application/vnd.yoyo-control.status+json", "{}", { "X-Frame-Seq": 2 }));
  const p = new PartParser("frame", 1024);
  const got = feedIn(p, data, [100, 900, 1500]);
  assert.deepEqual(got.map((x) => x.headers.seq), [2]);
  assert.ok(p.buffered < 16, "only the trailing CRLF waits");
});
