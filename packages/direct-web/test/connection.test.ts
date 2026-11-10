import assert from "node:assert/strict";
import { test } from "node:test";
import { LinkError } from "@yoyocontrol/link-web";
import { MacConnection } from "../src/connection.js";
import { DirectError } from "../src/errors.js";
import { FakeDialer, FakeSession, IDENTITY, MAC } from "./fakes.js";

const settings = (dial: FakeDialer) => ({ identity: IDENTITY, deviceName: "Chrome on Mac", app: { name: "test", version: "1" }, iceServers: [], turn: false, dial: dial.dial });

test("one dial for concurrent callers, with the token, the pinned identity and the kept certificate", async () => {
  const s = new FakeSession();
  const d = new FakeDialer(() => s);
  const c = new MacConnection(MAC, settings(d));
  const [a, b] = await Promise.all([c.session(), c.session()]);
  assert.equal(a, b);
  assert.equal(d.dials.length, 1);
  const o = d.dials[0]!;
  assert.equal(o.credential, "Bearer tok-1");
  assert.equal(o.pinnedFingerprint, MAC.fingerprint);
  assert.deepEqual(o.device, { id: "browser-1", name: "Chrome on Mac" });
  assert.deepEqual(o.certificates, [IDENTITY.certificate]);
  assert.equal(c.current, s.asSession());
  assert.equal(await c.session(), a, "the open one is reused");
});

test("a session that ended is made again; a new name from welcome is kept", async () => {
  let n = 0;
  const d = new FakeDialer(() => new FakeSession(undefined, { id: "mac-1", name: n++ ? "Studio 2" : "Studio", platform: "mac" }));
  const changed: string[] = [];
  const c = new MacConnection(MAC, settings(d), (m) => changed.push(m.name));
  const first = (await c.session()) as unknown as FakeSession;
  first.drop();
  assert.equal(c.current, null);
  await c.session();
  assert.equal(d.dials.length, 2);
  assert.deepEqual(changed, ["Studio 2"]);
});

test("after a failure the next dial waits; retryNow skips the wait; unpaired sticks", async () => {
  let fail: Error | null = new LinkError("timeout", "no session");
  const d = new FakeDialer(() => fail ?? new FakeSession());
  const c = new MacConnection(MAC, settings(d));
  await assert.rejects(c.session(), (e: unknown) => e instanceof DirectError && e.kind === "unreachable");
  fail = null;
  const t0 = Date.now();
  const p = c.session();
  setTimeout(() => c.retryNow(), 50);
  await p;
  assert.ok(Date.now() - t0 < 900, "retryNow woke the wait");

  const u = new MacConnection(MAC, settings(new FakeDialer(() => new LinkError("denied", "unknown token", "unauthorized"))));
  await assert.rejects(u.session(), (e: unknown) => e instanceof DirectError && e.kind === "unpaired");
  await assert.rejects(u.session(), (e: unknown) => e instanceof DirectError && e.kind === "unpaired");
  assert.equal(u.lastError?.kind, "unpaired");
});

test("close ends the session and makes no more", async () => {
  const s = new FakeSession();
  const c = new MacConnection(MAC, settings(new FakeDialer(() => s)));
  await c.session();
  c.close();
  assert.equal(s.isClosed, true);
  await assert.rejects(c.session(), DirectError);
});
