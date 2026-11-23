// The IdP re-check: a rotated refresh token is kept (one transaction, compare-and-swap), two checks of one session at
// once make one IdP call (in one process, and across two through the lease), a network failure / 5xx / 429 /
// invalid_client / a bad refreshed id_token leave everything as it was, and only a definite invalid_grant ends that one
// device session — not the account, not its other devices, not its computers — and puts its device on the list.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, test } from "node:test";
import { OidcClient } from "../src/oidc.js";
import { Rechecker } from "../src/recheck.js";
import { Store } from "../src/store.js";
import { appSignIn, bearer, get, harness, joinComputer, stopAll } from "../src/testing/harness.js";

afterEach(stopAll);
const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

const RECHECK = { ACCOUNT_IDP_RECHECK: "1" };
const refreshOf = (h: Awaited<ReturnType<typeof harness>>, device: string) => h.store.get<{ idp_refresh: string | null; id: string }>("SELECT id, idp_refresh FROM sessions WHERE device_id = ? AND ended_at IS NULL", device);

test("with the re-check on, offline access is asked for (offline_access where listed); off, it is not", async () => {
  const on = await harness({ env: RECHECK });
  await appSignIn(on);
  assert.equal(on.idp.authorizeRequests[0]!.get("scope"), "openid profile offline_access");
  const off = await harness();
  await appSignIn(off);
  assert.equal(off.idp.authorizeRequests[0]!.get("scope"), "openid profile");
  // a session without a refresh token is not checked, and that is no failure
  off.idp.giveRefresh = false;
  const s = await appSignIn(off, { device: { name: "x" } });
  const id = refreshOf(off, s.device.id)!.id;
  assert.equal(await off.recheck.check(id), "unchecked");
  assert.equal((await get(`${off.url}/v1/me`, bearer(s.session))).status, 200);
});

test("ok: the rotated refresh token is stored, the old one is never used again", async () => {
  const h = await harness({ env: RECHECK });
  const s = await appSignIn(h);
  const first = refreshOf(h, s.device.id)!;
  assert.ok(first.idp_refresh);
  h.idp.user = { sub: "u-alice", name: "Alice Liddell" };
  // (the IdP's id_token on refresh carries the user as signed in; a new name follows)
  assert.equal(await h.recheck.check(first.id), "ok");
  const second = refreshOf(h, s.device.id)!;
  assert.notEqual(second.idp_refresh, first.idp_refresh);
  assert.deepEqual(h.idp.liveRefreshTokens(), [second.idp_refresh]);
  assert.equal(await h.recheck.check(first.id), "ok");
  assert.equal(h.idp.refreshCalls, 2);
  const me = await (await get(`${h.url}/v1/me`, bearer(s.session))).json() as { session: { idpCheck: string } };
  assert.equal(me.session.idpCheck, "ok");
});

test("two checks of one session at once: one IdP call (a second would trip reuse detection and kill the family)", async () => {
  const h = await harness({ env: RECHECK });
  const s = await appSignIn(h);
  const id = refreshOf(h, s.device.id)!.id;
  h.idp.refreshDelayMs = 200;
  const results = await Promise.all([h.recheck.check(id), h.recheck.check(id), h.recheck.check(id), h.recheck.runDue()]);
  assert.equal(h.idp.refreshCalls, 1);
  assert.deepEqual(results.slice(0, 3), ["ok", "ok", "ok"]);
  assert.equal(h.idp.liveRefreshTokens().length, 1);
  assert.equal(await h.recheck.check(id), "ok");
  assert.equal(h.idp.refreshCalls, 2);
});

test("two processes on one database: the lease lets only one refresh", async () => {
  const dir = mkdtempSync(join(tmpdir(), "acct-recheck-"));
  dirs.push(dir);
  const h = await harness({ env: RECHECK, dbFile: join(dir, "account.db") });
  const s = await appSignIn(h);
  const id = refreshOf(h, s.device.id)!.id;
  // the "admin process": its own connection, its own Rechecker
  const other = new Store(join(dir, "account.db"));
  const r2 = new Rechecker(other, new OidcClient(h.cfg), { log: () => {} });
  h.idp.refreshDelayMs = 300;
  const [a, b] = await Promise.all([h.recheck.check(id), new Promise((r) => setTimeout(r, 50)).then(() => r2.check(id))]);
  assert.deepEqual([a, b].sort(), ["busy", "ok"]);
  assert.equal(h.idp.refreshCalls, 1);
  other.close();
});

test("network failure, 5xx, 429, invalid_client, a non-JSON page: 'later' — nothing ends, nothing is lost", async () => {
  const h = await harness({ env: RECHECK });
  const s = await appSignIn(h);
  const c = await joinComputer(h, s.session);
  const before = refreshOf(h, s.device.id)!;
  for (const mode of ["drop", "5xx", "429", "invalid_client", "html"] as const) {
    h.idp.mode = mode;
    assert.equal(await h.recheck.check(before.id), "retry", mode);
    assert.equal(refreshOf(h, s.device.id)!.idp_refresh, before.idp_refresh, mode);
  }
  // the IdP gone altogether
  h.idp.mode = "ok";
  assert.equal((await get(`${h.url}/v1/me`, bearer(s.session))).status, 200);
  assert.equal(h.store.computersOf(s.account.id).length, 1);
  assert.equal(h.store.revocationState(s.account.id).devices.length, 0);
  // and once it answers again, the same token still works
  assert.equal(await h.recheck.check(before.id), "ok");
  assert.ok(c);
});

test("a refreshed id_token for another sub: 'later', not an end", async () => {
  const h = await harness({ env: RECHECK });
  const s = await appSignIn(h);
  const id = refreshOf(h, s.device.id)!.id;
  // the IdP's record of whose token it is changes under it (it must not end or move the session)
  const before = refreshOf(h, s.device.id)!.idp_refresh!;
  (h.idp as unknown as { refresh: Map<string, { user: { sub: string } }> }).refresh.get(before)!.user = { sub: "u-mallory" };
  assert.equal(await h.recheck.check(id), "retry");
  assert.equal((await get(`${h.url}/v1/me`, bearer(s.session))).status, 200);
});

test("invalid_grant ends that one device session only: the other devices, the account and its computers stay", async () => {
  const h = await harness({ env: RECHECK });
  const phone = await appSignIn(h, { device: { name: "Phone" } });
  const ipad = await appSignIn(h, { device: { name: "iPad" } });
  const c = await joinComputer(h, phone.session);
  // the phone's refresh token alone dies (a reuse elsewhere, a per-session sign-out)
  const phoneRow = refreshOf(h, phone.device.id)!;
  (h.idp as unknown as { deadFamilies: Set<string>; refresh: Map<string, { family: string }> }).deadFamilies.add(
    (h.idp as unknown as { refresh: Map<string, { family: string }> }).refresh.get(phoneRow.idp_refresh!)!.family,
  );
  const counts = await h.recheck.runDue();
  assert.equal(counts.ended, 1);
  assert.equal(counts.ok, 1);
  assert.equal((await get(`${h.url}/v1/me`, bearer(phone.session))).status, 401);
  assert.equal((await get(`${h.url}/v1/me`, bearer(ipad.session))).status, 200);
  assert.equal(h.store.computersOf(phone.account.id).length, 1);
  assert.equal(h.store.account(phone.account.id)!.disabled_at, null);
  // the phone's device goes on the list (its computers stop taking what it holds) and the notice went out
  const st = h.store.revocationState(phone.account.id);
  assert.deepEqual(st.devices.map((d) => d.id), [phone.device.id]);
  assert.ok(h.notices.some((n) => n.linkIds.includes(c.k.id)));
  // its refresh token is gone from storage
  assert.equal(h.store.get<{ idp_refresh: string | null }>("SELECT idp_refresh FROM sessions WHERE device_id = ?", phone.device.id)!.idp_refresh, null);
  // the phone signs in again and works
  const again = await appSignIn(h, { device: { name: "Phone" } });
  assert.equal(again.account.id, phone.account.id);
});

test("the IdP's 'sign out everywhere': each session ends at its own next check", async () => {
  const h = await harness({ env: RECHECK });
  const a = await appSignIn(h, { device: { name: "Phone" } });
  const b = await appSignIn(h, { device: { name: "iPad" } });
  h.idp.revokeUser("u-alice");
  assert.equal(await h.recheck.check(refreshOf(h, a.device.id)!.id), "ended");
  // b not yet checked: still works
  assert.equal((await get(`${h.url}/v1/me`, bearer(b.session))).status, 200);
  assert.equal(await h.recheck.check(refreshOf(h, b.device.id)!.id), "ended");
  assert.equal((await get(`${h.url}/v1/me`, bearer(b.session))).status, 401);
  assert.equal(h.store.computersOf(a.account.id).length, 0);
  assert.ok(h.store.account(a.account.id));
});

test("a session signed out while its check is in flight is not brought back", async () => {
  const h = await harness({ env: RECHECK });
  const s = await appSignIn(h);
  const id = refreshOf(h, s.device.id)!.id;
  h.idp.refreshDelayMs = 200;
  const p = h.recheck.check(id);
  await new Promise((r) => setTimeout(r, 50));
  await fetch(`${h.url}/v1/signout`, { method: "POST", headers: bearer(s.session) });
  assert.equal(await p, "gone");
  const row = h.store.session(id)!;
  assert.ok(row.ended_at);
  assert.equal(row.idp_refresh, null);
});

test("runDue: only sessions not checked for an hour; a 'later' is tried again ten minutes on", async () => {
  const h = await harness({ env: RECHECK });
  await appSignIn(h);
  assert.equal((await h.recheck.runDue()).ok, 1);
  assert.equal((await h.recheck.runDue()).ok, 0);
  h.clock.t = Date.now() + 3_600_000 + 1000;
  h.idp.mode = "5xx";
  assert.equal((await h.recheck.runDue()).retry, 1);
  assert.equal((await h.recheck.runDue()).retry, 0);
  h.idp.mode = "ok";
  h.clock.t += 11 * 60_000;
  assert.equal((await h.recheck.runDue()).ok, 1);
});
