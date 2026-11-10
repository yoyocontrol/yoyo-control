import assert from "node:assert/strict";
import { test } from "node:test";
import { LinkError, normalizeFingerprint, parseAnswer, rtcSignedText, sdpFingerprints, sha256Hex, verifyAnswer, type RtcAnswer } from "../src/index.js";
import { Identity } from "./fake.js";

const OFFER = "v=0\r\na=fingerprint:sha-256 01:02\r\n";

const verificationError = (e: unknown) => e instanceof LinkError && e.kind === "verification";

test("fingerprints in every spelling", () => {
  assert.equal(normalizeFingerprint(" SHA256:AbCd "), "abcd");
  assert.equal(normalizeFingerprint("sha-256 AB:CD"), "abcd");
  assert.deepEqual(sdpFingerprints("v=0\r\na=fingerprint:sha-256 AB:CD\r\na=fingerprint:sha-1 00\r\n"), ["abcd"]);
});

test("the signed text names the offer's hash and the DTLS fingerprint", async () => {
  assert.equal(await sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  assert.equal(await rtcSignedText("abc", "sha256:ff"), "yoyocontrol-rtc-v1:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad:sha256:ff");
});

test("a signed answer from the pinned computer verifies", async () => {
  const id = await Identity.create();
  const a = parseAnswer(await id.answer(OFFER));
  await verifyAnswer(OFFER, a, id.fingerprint);
  // the pinned fingerprint's case and padding don't matter
  await verifyAnswer(OFFER, a, `  ${id.fingerprint.toUpperCase()} `);
  // the JSON text works as well
  await verifyAnswer(OFFER, parseAnswer(JSON.stringify(a)), id.fingerprint);
});

test("every mismatch is a hard failure", async () => {
  const id = await Identity.create();
  const other = await Identity.create();
  const a = parseAnswer(await id.answer(OFFER));
  // another computer's pin
  await assert.rejects(verifyAnswer(OFFER, a, other.fingerprint), verificationError);
  // signed for another offer
  await assert.rejects(verifyAnswer(`${OFFER}x`, a, id.fingerprint), verificationError);
  // the signature by another key, with this key in the binding
  const forged = parseAnswer(await other.answer(OFFER));
  await assert.rejects(verifyAnswer(OFFER, { ...forged, binding: a.binding }, id.fingerprint), verificationError);
  // the SDP names another DTLS certificate than the signed one
  const swapped = parseAnswer(await id.answer(OFFER, "ab".repeat(32), { sdpFingerprint: "cd".repeat(32) }));
  await assert.rejects(verifyAnswer(OFFER, swapped, id.fingerprint), verificationError);
  // the signed fingerprint changed after signing
  await assert.rejects(verifyAnswer(OFFER, { ...a, fingerprint: `sha256:${"cd".repeat(32)}` } as RtcAnswer, id.fingerprint), verificationError);
  // no fingerprint line at all
  await assert.rejects(verifyAnswer(OFFER, { ...a, answer: "v=0\r\n" }, id.fingerprint), verificationError);
  // garbage
  await assert.rejects(verifyAnswer(OFFER, { ...a, sig: "!!" }, id.fingerprint), verificationError);
  await assert.rejects(verifyAnswer(OFFER, { ...a, binding: { ...a.binding, key: Buffer.from([4, 1, 2]).toString("base64") } }, id.fingerprint), verificationError);
});

test("an answer without its fields is a protocol error", () => {
  assert.throws(() => parseAnswer("nope"), (e: unknown) => e instanceof LinkError && e.kind === "protocol");
  assert.throws(() => parseAnswer({ v: 1, answer: "x" }), (e: unknown) => e instanceof LinkError && e.kind === "protocol");
});
