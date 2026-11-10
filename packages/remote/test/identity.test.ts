import assert from "node:assert/strict";
import { createHash, createPublicKey, sign, verify } from "node:crypto";
import { mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { KEY_FILE, keyFromX963, loadOrCreateIdentity, x963Private } from "../src/index.js";

const tmp = () => mkdtempSync(join(tmpdir(), "remote-id-"));

test("identity: made once (0700 dir, a 0600 file), the same key and fingerprint when loaded again", () => {
  const dir = join(tmp(), "home");
  const a = loadOrCreateIdentity(dir);
  assert.equal(statSync(dir).mode & 0o777, 0o700);
  assert.equal(statSync(join(dir, KEY_FILE)).mode & 0o777, 0o600);
  assert.match(a.keyFingerprint, /^sha256:[0-9a-f]{64}$/);
  // the key file is the Mac's format: X9.63 private bytes (04 ‖ X ‖ Y ‖ D)
  const raw = readFileSync(join(dir, KEY_FILE));
  assert.equal(raw.length, 97);
  assert.equal(raw[0], 4);
  // the pin: SHA-256 over the public key's X9.63 bytes (04 ‖ X ‖ Y)
  assert.equal(a.publicKey.length, 65);
  assert.deepEqual(a.publicKey, raw.subarray(0, 65));
  assert.equal(a.keyFingerprint, `sha256:${createHash("sha256").update(a.publicKey).digest("hex")}`);
  const b = loadOrCreateIdentity(dir);
  assert.equal(b.keyFingerprint, a.keyFingerprint);
});

test("identity: an unreadable key means a new key", () => {
  const dir = tmp();
  const a = loadOrCreateIdentity(dir);
  writeFileSync(join(dir, KEY_FILE), Buffer.alloc(10));
  assert.notEqual(loadOrCreateIdentity(dir).keyFingerprint, a.keyFingerprint);
});

test("identity: X9.63 private bytes round-trip; a signature verifies with the public key", () => {
  const id = loadOrCreateIdentity(tmp());
  const raw = x963Private(id.key);
  const k = keyFromX963(raw);
  assert.deepEqual(x963Private(k), raw);
  const sig = sign("sha256", Buffer.from("x"), k);
  assert.ok(verify("sha256", Buffer.from("x"), createPublicKey(id.key), sig));
  assert.throws(() => keyFromX963(Buffer.alloc(97)));
});
