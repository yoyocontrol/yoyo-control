// The admin commands: listing, disable / enable, remove (and its tombstone), revoke-device, rebind-issuer (and its
// refusal to merge), rotate-key, and that what they revoke reaches the outbox the server pushes from.
import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { AdminError, rebindIssuer, runAdmin } from "../src/admin.js";
import { appSignIn, bearer, get, harness, joinComputer, pkce, stopAll, throughIdp } from "../src/testing/harness.js";

afterEach(stopAll);

test("accounts, account, disable, enable", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  await joinComputer(h, s.session);
  const run = (...a: string[]) => runAdmin(a, { store: h.store, ring: h.ring });
  assert.match(await run("accounts"), new RegExp(`${s.account.id}  Alice .* active  1 computer\\(s\\)  1 device\\(s\\)`));
  assert.match(await run("account", s.account.id), /session s_.* live/);
  assert.match(await run("disable", s.account.id), /1 session\(s\) ended/);
  assert.equal((await get(`${h.url}/v1/me`, bearer(s.session))).status, 401);
  assert.equal(h.store.revocationState(s.account.id).disabled !== null, true);
  // its notice waits in the outbox until the server pushes it
  assert.ok(h.store.outbox().length >= 1);
  await h.svc.deliverNotices();
  assert.equal(h.store.outbox().length, 0);
  await run("enable", s.account.id);
  assert.equal(h.store.revocationState(s.account.id).disabled, null);
  const again = await appSignIn(h);
  assert.equal(again.account.id, s.account.id);
  assert.equal(h.store.computersOf(s.account.id).length, 1, "its computers stayed");
  await assert.rejects(run("disable", "a_nope"), AdminError);
  await assert.rejects(run("frobnicate"), AdminError);
});

test("remove leaves a tombstone; clear-tombstone lets it sign in again as a new account", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  const c = await joinComputer(h, s.session);
  const run = (...a: string[]) => runAdmin(a, { store: h.store, ring: h.ring });
  await run("remove", s.account.id);
  assert.match(await run("tombstones"), /sub=u-alice/);
  // its computers are told (the list outlives the account)
  const st = h.store.revocationState(s.account.id);
  assert.ok(st.disabled !== null && st.computers.some((x) => x.id === c.k.id));
  const { challenge } = pkce();
  assert.equal(new URL((await throughIdp(h, { redirect_uri: "example://account", code_challenge: challenge, code_challenge_method: "S256" })).location).searchParams.get("error"), "account_removed");
  assert.match(await run("clear-tombstone", h.idp.issuer, "u-alice"), /may sign in again/);
  assert.notEqual((await appSignIn(h)).account.id, s.account.id);
});

test("revoke-device: that device's session ends, the others stay", async () => {
  const h = await harness();
  const a = await appSignIn(h, { device: { name: "Phone" } });
  const b = await appSignIn(h, { device: { name: "iPad" } });
  await runAdmin(["revoke-device", a.device.id], { store: h.store, ring: h.ring });
  assert.equal((await get(`${h.url}/v1/me`, bearer(a.session))).status, 401);
  assert.equal((await get(`${h.url}/v1/me`, bearer(b.session))).status, 200);
  assert.deepEqual(h.store.revocationState(a.account.id).devices.map((d) => d.id), [a.device.id]);
});

test("rebind-issuer moves every account to the new issuer URL; refuses to merge two accounts", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  const NEW = "https://id.example.com";
  assert.deepEqual(rebindIssuer(h.store, h.idp.issuer, NEW, true), { accounts: 1, tombstones: 0 });
  assert.equal(h.store.account(s.account.id)!.iss, h.idp.issuer, "a dry run changes nothing");
  rebindIssuer(h.store, h.idp.issuer, NEW);
  assert.equal(h.store.account(s.account.id)!.iss, NEW);
  assert.ok(h.store.accountOf(NEW, "u-alice"));
  // someone signed in under the old issuer again meanwhile: moving back would merge
  await appSignIn(h);
  assert.throws(() => rebindIssuer(h.store, h.idp.issuer, NEW), /already have an account/);
});

test("rotate-key and keys", async () => {
  const h = await harness();
  const run = (...a: string[]) => runAdmin(a, { store: h.store, ring: h.ring });
  const first = h.ring.jwks()[0]!.kid;
  assert.match(await run("rotate-key"), /endorsed/);
  const out = await run("keys");
  assert.match(out, new RegExp(`^${first}\\n.*\\(current\\)$`));
});
