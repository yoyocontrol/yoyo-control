// Tickets, lists and notices, and the key ring: the reference checks refuse a forged, tampered, expired, replayed,
// misaddressed or misowned ticket, one signed by an unpinned key, and one kind passed off as another (same key, other
// typ); a new key is taken only through an endorsement chain from a pinned one.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { KeyRing, verifyKeyChain, type PublicJwk } from "../src/keys.js";
import { ReplayCache, RevocationView, signRevocationList, signTicket, TicketError, verifyRevocationList, verifyTicket } from "../src/ticket.js";

const ISS = "https://account.example.com";
const A = "a".repeat(64);
const B = "b".repeat(64);
const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
const code = (c: TicketError["code"]) => (e: unknown) => e instanceof TicketError && e.code === c;

async function setup() {
  const ring = KeyRing.load(null);
  const keys = ring.jwks();
  const t = await signTicket(ring, { issuer: ISS, account: "a_owner", accountName: "Alice", linkId: A, device: { id: "d_phone", name: "Phone" } });
  return { ring, keys, t };
}
const check = (t: string, keys: PublicJwk[], o: Partial<Parameters<typeof verifyTicket>[1]> = {}) => verifyTicket(t, { issuer: ISS, keys, owner: "a_owner", linkId: A, replay: new ReplayCache(), ...o });

test("a good ticket: 120 s, one computer, one device, once", async () => {
  const { keys, t } = await setup();
  const replay = new ReplayCache();
  const c = await check(t, keys, { replay });
  assert.equal(c.exp - c.iat, 120);
  assert.equal(c.aud, A);
  assert.equal(c.name, "Alice");
  await assert.rejects(check(t, keys, { replay }), code("replayed"));
});

test("refused: another computer, another owner, another issuer, expired, from the future, tampered, an unpinned key", async () => {
  const { keys, t } = await setup();
  await assert.rejects(check(t, keys, { linkId: B }), code("wrong_computer"));
  await assert.rejects(check(t, keys, { owner: "a_other" }), code("not_owner"));
  await assert.rejects(check(t, keys, { issuer: "https://evil.example.net" }), code("wrong_issuer"));
  await assert.rejects(check(t, keys, { now: Date.now() + 121_000 + 30_000 }), code("expired"));
  const ring = KeyRing.load(null);
  const future = await signTicket(ring, { issuer: ISS, account: "a_owner", linkId: A, device: { id: "d", name: "x" }, now: Date.now() + 600_000 });
  await assert.rejects(check(future, ring.jwks()), code("malformed"));
  const [h, p, s] = t.split(".");
  const payload = JSON.parse(Buffer.from(p!, "base64url").toString());
  payload.aud = B;
  await assert.rejects(check(`${h}.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.${s}`, keys, { linkId: B }), code("bad_signature"));
  // signed by another server's key with the same kid
  const other = KeyRing.load(null);
  const forged = await signTicket(other, { issuer: ISS, account: "a_owner", linkId: A, device: { id: "d", name: "x" } });
  await assert.rejects(check(forged, keys), code("unknown_key"));
  const sameKid = keys.map((k) => ({ ...k, x: other.jwks()[0]!.x }));
  await assert.rejects(check(t, sameKid), code("bad_signature"));
  await assert.rejects(check("not.a.jwt", keys), code("malformed"));
});

test("a revocation list is never taken as a ticket (and the other way round)", async () => {
  const { ring, keys, t } = await setup();
  const list = await signRevocationList(ring, ISS, { account: "a_owner", version: 1, devices: [], computers: [], disabled: null });
  await assert.rejects(check(list, keys), code("malformed"));
  await assert.rejects(verifyRevocationList(t, { issuer: ISS, keys, owner: "a_owner", minVersion: 0 }), code("malformed"));
});

test("a revoked device's tickets issued up to its revocation are refused; a later sign-in's are not", async () => {
  const { ring, keys, t } = await setup();
  const iat = JSON.parse(Buffer.from(t.split(".")[1]!, "base64url").toString()).iat as number;
  const view = new RevocationView({ account: "a_owner", version: 3, devices: [{ id: "d_phone", at: iat }], computers: [], disabled: null });
  await assert.rejects(check(t, keys, { revoked: view }), code("revoked"));
  const later = await signTicket(ring, { issuer: ISS, account: "a_owner", linkId: A, device: { id: "d_phone", name: "Phone" }, now: (iat + 5) * 1000 });
  assert.ok(await check(later, keys, { revoked: view, now: (iat + 5) * 1000 }));
  // a newer list that says the account is disabled: nothing is taken
  view.state = { ...view.state, version: 4, disabled: iat + 10 };
  await assert.rejects(check(later, keys, { revoked: view, now: (iat + 5) * 1000 }), code("revoked"));
});

test("the replay cache is bounded and fails closed when full of live tickets", () => {
  const c = new ReplayCache(2);
  const now = Date.now();
  const exp = Math.floor(now / 1000) + 120;
  assert.equal(c.take("a", exp, now), true);
  assert.equal(c.take("b", exp, now), true);
  assert.equal(c.take("c", exp, now), "full");
  // once they are past, room again
  assert.equal(c.take("c", exp, now + 200_000), true);
});

test("the key ring: 0600 on disk, the same keys after a restart; a rotated key is taken only through endorsements", async () => {
  const dir = mkdtempSync(join(tmpdir(), "acct-keys-"));
  dirs.push(dir);
  const f = join(dir, "keys.json");
  const ring = KeyRing.load(f);
  assert.equal(statSync(f).mode & 0o777, 0o600);
  const pinned = ring.jwks();
  assert.equal(pinned[0]!.yoyo_endorsement, undefined);
  assert.equal((pinned[0] as unknown as { d?: string }).d, undefined, "no private part in the JWKS");
  const k2 = await ring.rotate();
  const k3 = await ring.rotate();
  assert.deepEqual(KeyRing.load(f).jwks(), ring.jwks());
  const offered = ring.jwks();
  const trusted = await verifyKeyChain(pinned, offered);
  assert.deepEqual(trusted.map((k) => k.kid).sort(), [pinned[0]!.kid, k2.kid, k3.kid].sort());
  // a key someone slipped into the JWKS without an endorsement, or endorsed by itself: not taken
  const evil = KeyRing.load(null);
  const evilKey = evil.jwks()[0]!;
  await evil.rotate();
  const selfEndorsed = evil.jwks()[1]!;
  const t2 = await verifyKeyChain(pinned, [...offered, evilKey, selfEndorsed]);
  assert.ok(!t2.some((k) => k.kid === evilKey.kid || k.kid === selfEndorsed.kid));
  // an endorsement moved onto another key: not taken
  const moved = { ...evilKey, kid: k2.kid + "x", yoyo_endorsement: k2.yoyo_endorsement! };
  assert.ok(!(await verifyKeyChain(pinned, [moved])).some((k) => k.kid === moved.kid));
  // a ticket by the newest key verifies with the chain-trusted set
  const t = await signTicket(ring, { issuer: ISS, account: "a_owner", linkId: A, device: { id: "d", name: "x" } });
  assert.ok(await check(t, trusted));
  await assert.rejects(check(t, pinned), code("unknown_key"));
});

test("lists: an older version than held is refused, and another owner's", async () => {
  const { ring, keys } = await setup();
  const l5 = await signRevocationList(ring, ISS, { account: "a_owner", version: 5, devices: [{ id: "d1", at: 10 }], computers: [], disabled: null });
  assert.equal((await verifyRevocationList(l5, { issuer: ISS, keys, owner: "a_owner", minVersion: 5 })).version, 5);
  await assert.rejects(verifyRevocationList(l5, { issuer: ISS, keys, owner: "a_owner", minVersion: 6 }), code("replayed"));
  await assert.rejects(verifyRevocationList(l5, { issuer: ISS, keys, owner: "a_other", minVersion: 0 }), code("not_owner"));
});
