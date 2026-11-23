// The wire names and what a computer keeps of the services it is lent (the account server's package tests the
// signing and the whole exchange against a real server).
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { test } from "node:test";
import { CompactSign, SignJWT } from "jose";
import { cleanJwk, DEFAULT_WIRE, ReplayCache, TicketError, validServices, verifyKeyChain, verifyTicket, Wire, type PublicJwk } from "../src/index.js";

test("every wire name is made of the namespace", () => {
  const w = new Wire("acme");
  assert.equal(w.ticketTyp, "acme-ticket+jwt");
  assert.equal(w.revocationsTyp, "acme-revocations+jwt");
  assert.equal(w.serviceTyp, "acme-service+jwt");
  assert.equal(w.endorsementTyp, "acme-key-endorsement+jwt");
  assert.equal(w.endorsementField, "acme_endorsement");
  assert.equal(w.sessionPrefix, "acme_as_");
  assert.equal(w.joinKeyPrefix, "acme_jk_");
  assert.equal(w.linkScheme, "AcmeLink");
  assert.equal(w.proofHeader, "acme-proof");
  assert.equal(w.service("push"), "acme-push");
  assert.ok(w.joinKeyRe.test(`acme_jk_${"A".repeat(43)}`));
  assert.ok(!w.joinKeyRe.test(`yoyo_jk_${"A".repeat(43)}`));
  assert.ok(w.computerProofText("https://a.example.com", "GET", "/v1/x", 1, "").startsWith("acme-account-computer-v1\n"));
  assert.equal(DEFAULT_WIRE.ns, "yoyo");
  for (const bad of ["", "A", "a", "1abc", "a-b", "abcdefghijklmnopq"]) assert.throws(() => new Wire(bad), bad);
});

const key = () => {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const x = (publicKey.export({ format: "jwk" }) as { x: string }).x;
  const jwk: PublicJwk = { kty: "OKP", crv: "Ed25519", x, kid: x.slice(0, 12), alg: "EdDSA", use: "sig" };
  return { jwk, privateKey };
};

test("a key endorsed under one namespace is not taken under another", async () => {
  const a = key();
  const b = key();
  const w = new Wire("acme");
  const endorsement = await new CompactSign(new TextEncoder().encode(JSON.stringify({ kid: b.jwk.kid, x: b.jwk.x, iat: 1 })))
    .setProtectedHeader({ alg: "EdDSA", kid: a.jwk.kid, typ: w.endorsementTyp })
    .sign(a.privateKey);
  const offered = cleanJwk({ ...b.jwk, [w.endorsementField]: endorsement }, w)!;
  assert.equal(offered.acme_endorsement, endorsement);
  assert.deepEqual((await verifyKeyChain([a.jwk], [offered], w)).map((k) => k.kid), [a.jwk.kid, b.jwk.kid]);
  // (the default namespace looks for its own field and its own typ)
  assert.deepEqual((await verifyKeyChain([a.jwk], [offered])).map((k) => k.kid), [a.jwk.kid]);
});

test("a ticket of another namespace is refused", async () => {
  const s = key();
  const linkId = "a".repeat(64);
  const sign = (typ: string) =>
    new SignJWT({ dev: { id: "d_1", name: "Phone" } })
      .setProtectedHeader({ alg: "EdDSA", kid: s.jwk.kid, typ })
      .setIssuer("https://account.example.com").setSubject("a_0123456789").setAudience(linkId)
      .setIssuedAt().setExpirationTime("100s").setJti("j1").sign(s.privateKey);
  const o = { issuer: "https://account.example.com", keys: [s.jwk], owner: "a_0123456789", linkId, replay: new ReplayCache() };
  await assert.rejects(verifyTicket(await sign("acme-ticket+jwt"), o), (e: TicketError) => e.code === "malformed");
  assert.equal((await verifyTicket(await sign("acme-ticket+jwt"), { ...o, wire: new Wire("acme") })).dev.id, "d_1");
});

test("services: only whole entries, https (loopback only from a loopback server), short fields, a time", () => {
  const server = "https://account.example.com";
  const got = validServices({
    relay: { url: "https://relay.example.com", token: "relay-token-0123456789" },
    push: { url: "https://push.example.com", token: "a.b.c", expiresAt: 1_900_000_000_000 },
    web: { url: "https://app.example.com" },
    plain: { url: "http://relay.example.com" },
    local: { url: "http://127.0.0.1:9000" },
    pathy: { url: "https://relay.example.com/x" },
    late: { url: "https://x.example.com", expiresAt: "soon" },
    nested: { url: "https://x.example.com", more: { a: 1 } },
    spaced: { url: "https://x.example.com", token: "a b" },
    "Bad Name": { url: "https://x.example.com" },
    off: null,
  }, server);
  assert.deepEqual(Object.keys(got), ["relay", "push", "web"]);
  assert.equal(got.push!.expiresAt, 1_900_000_000_000);
  assert.deepEqual(Object.keys(validServices({ local: { url: "http://127.0.0.1:9000" } }, "http://127.0.0.1:8000")), ["local"]);
  assert.deepEqual(validServices([1, 2], server), {});
  assert.deepEqual(validServices(null, server), {});
});
