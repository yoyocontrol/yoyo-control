import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { CODE_TTL_MS, DeviceStore, MAX_CODE_ATTEMPTS, PairError, cleanName, pairingLink } from "../src/devices.js";

const path = () => join(mkdtempSync(join(tmpdir(), "devices-")), "devices.json");

test("devices: pair with the live code → a token that authenticates; the code is used once; only hashes on disk (0600)", () => {
  const p = path();
  let changes = 0;
  const s = new DeviceStore(p, { onChange: () => changes++ });
  assert.throws(() => s.pair("x", "phone-0001", "Phone"), (e: PairError) => e.kind === "bad-code");
  const { code, expiresAt } = s.startPairing();
  assert.equal(code.length, 22); // 16 bytes, base64url
  assert.ok(expiresAt > Date.now() + CODE_TTL_MS - 1000);
  const token = s.pair(code, "phone-0001", "My\niPhone");
  assert.equal(s.pairingCode, null);
  assert.throws(() => s.pair(code, "phone-0002", "Other"), (e: PairError) => e.kind === "bad-code");
  assert.equal(s.authenticate(token)?.name, "MyiPhone");
  assert.equal(s.authenticate("nope"), null);
  assert.equal(s.authenticate(null), null);
  assert.equal(statSync(p).mode & 0o777, 0o600);
  const disk = readFileSync(p, "utf8");
  assert.ok(!disk.includes(token));
  assert.match(disk, /"tokenHash": "[0-9a-f]{64}"/);
  // a new store reads it back
  assert.equal(new DeviceStore(p).authenticate(token)?.id, "phone-0001");
  assert.ok(changes >= 2);
});

test("devices: pairing the same id again replaces its token; remove() ends it", () => {
  const s = new DeviceStore(path());
  const t1 = s.pair(s.startPairing().code, "phone-0001", "A");
  const t2 = s.pair(s.startPairing().code, "phone-0001", "A");
  assert.equal(s.list.length, 1);
  assert.equal(s.authenticate(t1), null);
  assert.ok(s.authenticate(t2));
  assert.equal(s.remove("phone-0001"), true);
  assert.equal(s.remove("phone-0001"), false);
  assert.equal(s.authenticate(t2), null);
});

test("devices: 10 wrong codes in a row end the code; an expired code doesn't work", () => {
  let now = 1_000_000;
  const s = new DeviceStore(path(), { now: () => now });
  const { code } = s.startPairing();
  for (let i = 0; i < MAX_CODE_ATTEMPTS - 1; i++) assert.throws(() => s.pair("wrong", "phone-0001", "A"));
  assert.ok(s.pairingCode);
  assert.throws(() => s.pair("wrong", "phone-0001", "A"));
  assert.equal(s.pairingCode, null);
  assert.throws(() => s.pair(code, "phone-0001", "A"));
  const c2 = s.startPairing().code;
  now += CODE_TTL_MS;
  assert.throws(() => s.pair(c2, "phone-0001", "A"));
});

test("devices: cleanName, the pairing link", () => {
  assert.equal(cleanName("  "), "iPhone");
  assert.equal(cleanName("x".repeat(80)).length, 64);
  const link = pairingLink({
    serverId: "srv1234567890abcd",
    name: "Linux test",
    fingerprint: "sha256:ab",
    code: "CODE",
    link: { id: "cd".repeat(32), key: "BA+/x==", sig: "q/+w", port: 47820 },
    addresses: ["192.168.1.151", "100.64.0.10"],
  });
  assert.equal(link, `yoyocontrol://pair?v=2&id=srv1234567890abcd&n=Linux%20test&fp=sha256%3Aab&l=${"cd".repeat(32)}&lk=BA-_x&ls=q_-w&lp=47820&a=192.168.1.151%2C100.64.0.10&c=CODE`);
  const u = new URL(link);
  assert.equal(u.searchParams.get("a"), "192.168.1.151,100.64.0.10");
  assert.equal(u.searchParams.get("fp"), "sha256:ab");
  const bare = new URL(pairingLink({ serverId: "s", name: "n", fingerprint: "sha256:ab", code: "CODE", link: { id: "ab", key: "k", sig: "s" } }));
  assert.equal(bare.searchParams.get("a"), null);
  assert.equal(bare.searchParams.get("lp"), null);
});

test("devices: a token's first link session binds its client key; another key is refused until it pairs again", () => {
  const p = path();
  const s = new DeviceStore(p);
  const token = s.pair(s.startPairing().code, "phone-0001", "Phone");
  const a = "AB".repeat(32);
  assert.equal(s.authenticateLink("nope", a).kind, "unknown");
  assert.equal(s.authenticateLink(token, a).kind, "accepted");
  assert.equal(s.authenticateLink(token, a.toLowerCase()).kind, "accepted");
  assert.equal(s.authenticateLink(token, "cd".repeat(32)).kind, "other-key");
  assert.equal(new DeviceStore(p).authenticateLink(token, "cd".repeat(32)).kind, "other-key");
  assert.ok(!("linkKey" in s.list[0]!));
  const again = s.pair(s.startPairing().code, "phone-0001", "Phone");
  assert.equal(s.authenticateLink(again, "cd".repeat(32)).kind, "accepted");
});

test("devices: an invitation pairs only its phone, from its link key, once, and runs out", () => {
  let now = 1_000_000;
  const s = new DeviceStore(path(), { now: () => now });
  const key = "ab".repeat(32);
  const inv = s.invite("phone-0002", key.toUpperCase());
  assert.equal(s.pairingCode, null, "not the shown code");
  const bad = (e: PairError) => e.kind === "bad-code";
  assert.throws(() => s.pair(inv.code, "phone-0003", "x", key), bad, "another phone");
  assert.throws(() => s.pair(inv.code, "phone-0002", "x", "cd".repeat(32)), bad, "another key");
  assert.throws(() => s.pair(inv.code, "phone-0002", "x"), bad, "no key");
  const token = s.pair(inv.code, "phone-0002", "New iPhone", key);
  assert.equal(s.authenticateLink(token, key).kind, "accepted", "bound to its key at once");
  assert.equal(s.authenticateLink(token, "cd".repeat(32)).kind, "other-key");
  assert.throws(() => s.pair(inv.code, "phone-0002", "x", key), bad, "used once");
  const late = s.invite("phone-0004", key);
  now += 10 * 60_000 + 1;
  assert.throws(() => s.pair(late.code, "phone-0004", "x", key), bad, "expired");
  assert.throws(() => s.invite("phone-0004", "nothex"), (e: PairError) => e.kind === "bad-device");
});

test("an account's device: admitted with its grant, its token bound to its link key, gone when the grant no longer counts or its sign-in ends", () => {
  const dir = mkdtempSync(join(tmpdir(), "devices-acct-"));
  let t = 1_000_000_000_000;
  const store = new DeviceStore(join(dir, "devices.json"), { now: () => t });
  const key = "ab".repeat(32);
  const grant = { acc: "a_0123456789ab", dev: "d_0123456789ab", tat: t / 1000, sx: t / 1000 + 3600 };
  const token = store.admit("phone-ipad-0001", "iPad", key, grant);
  assert.deepEqual(store.list[0]!.account, grant);
  assert.equal(store.isPaired("phone-ipad-0001"), false);
  assert.equal(store.authenticateLink(token, key).kind, "accepted");
  assert.equal(store.authenticateLink(token, "cd".repeat(32)).kind, "other-key");
  // kept on disk as it is
  assert.deepEqual(new DeviceStore(join(dir, "devices.json")).list[0]!.account, grant);
  // a paired one is not touched by prune
  store.startPairing();
  store.pair(store.pairingCode!.code, "phone-paired-01", "iPhone");
  assert.equal(store.isPaired("phone-paired-01"), true);
  assert.equal(store.prune(() => true), 0);
  assert.equal(store.prune((g) => g.dev !== grant.dev), 1);
  assert.deepEqual(store.list.map((d) => d.id), ["phone-paired-01"]);
  // the sign-in's end is the token's
  const t2 = store.admit("phone-ipad-0001", "iPad", key, grant);
  t += 3601_000;
  assert.equal(store.authenticate(t2), null);
  assert.equal(store.prune(() => true), 1);
  assert.throws(() => store.admit("x", "x", key, grant), /device.id/);
  assert.throws(() => store.admit("phone-ipad-0002", "x", "nothex", grant), /link key/);
  rmSync(dir, { recursive: true, force: true });
});
