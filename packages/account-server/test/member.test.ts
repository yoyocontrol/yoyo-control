// The computer's half (@yoyocontrol/account AccountMember) against this server: joining with a join key, a ticket
// taken once, a removed device out within the list's wait, what the account lends, leaving — in a namespace of its
// own, and refused by a computer of another namespace.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { AccountMember, TicketError, type AccountServices, type ComputerSelf } from "@yoyocontrol/account";
import { appSignIn, bearer, harness, linkKey, post, stopAll, type Harness, type LinkKey } from "../src/testing/harness.js";

const dirs: string[] = [];
const members: AccountMember[] = [];
after(async () => {
  for (const m of members.splice(0)) m.stop();
  await stopAll();
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

function member(h: Harness, k: LinkKey, o: { namespace?: string; validServices?: (s: AccountServices, server: string) => AccountServices } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "account-member-"));
  dirs.push(dir);
  const self: ComputerSelf = { linkId: k.id, name: "Study PC", relays: [], direct: [], origins: [] };
  const logs: string[] = [];
  const m = new AccountMember({
    file: join(dir, "account.json"),
    self: () => self,
    sign: (id, text) => (id === k.id ? k.sign(text) : null),
    log: (l) => logs.push(l),
    timing: { waitS: 1, retryMinMs: 50, retryMaxMs: 200 },
    ...(o.namespace ? { namespace: o.namespace } : {}),
    ...(o.validServices ? { validServices: o.validServices } : {}),
  });
  members.push(m);
  return { m, dir, logs, file: join(dir, "account.json") };
}

async function until(what: string, ok: () => boolean, ms = 5_000) {
  const end = Date.now() + ms;
  while (!ok()) {
    if (Date.now() > end) throw new Error(`timed out: ${what}`);
    await new Promise((r) => setTimeout(r, 20));
  }
}

async function ticketFor(h: Harness, session: string, k: LinkKey): Promise<string> {
  const r = await post(`${h.url}/v1/tickets`, { computer: k.id }, bearer(session));
  assert.equal(r.status, 200);
  return ((await r.json()) as { ticket: string }).ticket;
}

test("a computer joins with a join key, takes a ticket once, drops a removed device, is lent services, and leaves", async () => {
  const h = await harness({ env: { ACCOUNT_NAMESPACE: "acme", ACCOUNT_RELAY_URL: "https://relay.example.com", ACCOUNT_RELAY_TOKEN: "relay-token-0123456789", ACCOUNT_PUSH_URL: "https://push.example.com" } });
  const phone = await appSignIn(h);
  const key = h.store.createJoinKey(phone.account.id, 1, Date.now() + 3600_000, Date.now());
  assert.match(key, /^acme_jk_/);
  const k = linkKey();
  const { m, file } = member(h, k, { namespace: "acme" });

  const rec = await m.joinWithKey(h.url, key);
  assert.equal(rec.account.id, phone.account.id);
  assert.equal(statSync(file).mode & 0o777, 0o600);
  m.start();

  // the ticket: taken once (after the first list), never twice
  const t = await ticketFor(h, phone.session, k);
  const claims = await m.redeem(t);
  assert.equal(claims.sub, phone.account.id);
  assert.equal(claims.dev.id, phone.device.id);
  await assert.rejects(m.redeem(t), (e: TicketError) => e.code === "replayed");
  const token = { acc: claims.sub, dev: claims.dev.id, tat: claims.iat, sx: claims.sx! };
  assert.ok(m.ticketValid(token));

  // what the account lends: the relay as it is, a push token of this computer's own (its `aud` in the namespace)
  await until("services", () => !!m.services()?.push);
  const lent = m.services()!;
  assert.deepEqual(lent.relay, { url: "https://relay.example.com", token: "relay-token-0123456789" });
  assert.equal(lent.push!.url, "https://push.example.com");
  assert.equal(JSON.parse(Buffer.from(String(lent.push!.token).split(".")[1]!, "base64url").toString()).aud, "acme-push");

  // the device removed at the server: out here within the list's wait
  assert.equal((await fetch(`${h.url}/v1/devices/${phone.device.id}`, { method: "DELETE", headers: bearer(phone.session) })).status, 200);
  await until("revocation", () => !m.ticketValid(token));

  // leaving: the file goes, nothing counts
  assert.equal(await m.leave(), true);
  assert.equal(m.current(), null);
  assert.equal(m.services(), null);
  assert.throws(() => readFileSync(file));
});

test("a computer of another namespace cannot join: its join key and its signed requests are not this server's", async () => {
  const h = await harness({ env: { ACCOUNT_NAMESPACE: "acme" } });
  const phone = await appSignIn(h);
  const key = h.store.createJoinKey(phone.account.id, 1, Date.now() + 3600_000, Date.now());
  const { m } = member(h, linkKey());
  await assert.rejects(m.joinWithKey(h.url, key), /not a join key/);
  // the same key's shape in the computer's namespace: the server refuses it
  await assert.rejects(m.joinWithKey(h.url, key.replace(/^acme_/, "yoyo_")));
});

test("a caller's own rules for what is lent run on top of the library's", async () => {
  const h = await harness({ env: { ACCOUNT_RELAY_URL: "https://relay.example.com", ACCOUNT_RELAY_TOKEN: "relay-token-0123456789", ACCOUNT_PUSH_URL: "https://push.example.com" } });
  const phone = await appSignIn(h);
  const k = linkKey();
  const { m } = member(h, k, {
    // (this one takes no push relay)
    validServices: (s) => {
      const { push: _push, ...rest } = s;
      return rest;
    },
  });
  await m.joinWithKey(h.url, h.store.createJoinKey(phone.account.id, 1, Date.now() + 3600_000, Date.now()));
  m.start();
  await until("services", () => !!m.services()?.relay);
  assert.deepEqual(Object.keys(m.services()!), ["relay"]);
});
