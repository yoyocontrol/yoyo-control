import assert from "node:assert/strict";
import { createHash, createPublicKey, verify } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { loadOrCreateIdentity } from "../src/index.js";
import { SignalClient, relayHello, relayRoom, signalUrl } from "../src/signal.js";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** A WebSocket stand-in the test drives as the signaling server. */
class FakeWS extends EventTarget {
  static made: FakeWS[] = [];
  readyState = 0;
  binaryType = "blob";
  bufferedAmount = 0;
  sent: Array<string | Buffer> = [];
  closed = false;
  constructor(readonly url: string) {
    super();
    FakeWS.made.push(this);
  }
  open() {
    this.readyState = 1;
    this.dispatchEvent(new Event("open"));
  }
  message(data: string | ArrayBuffer) {
    this.dispatchEvent(new MessageEvent("message", { data }));
  }
  send(d: string | Uint8Array) {
    this.sent.push(typeof d === "string" ? d : Buffer.from(d));
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    this.readyState = 3;
    this.dispatchEvent(Object.assign(new Event("close"), { code: 1000, reason: "" }));
  }
}

test("signal: hello is signed by the key (raw r ‖ s over the prefix + nonce); the room is the fingerprint's hex", () => {
  const id = loadOrCreateIdentity(mkdtempSync(join(tmpdir(), "relay-")));
  const hello = JSON.parse(relayHello("bm9uY2U=", id));
  assert.equal(hello.type, "hello");
  assert.equal(hello.v, 1);
  const key = Buffer.from(hello.key, "base64");
  assert.equal(key.length, 65);
  assert.equal(createHash("sha256").update(key).digest("hex"), relayRoom(id.keyFingerprint));
  const sig = Buffer.from(hello.sig, "base64");
  assert.equal(sig.length, 64);
  assert.ok(verify("sha256", Buffer.from("yoyocontrol-relay-v1:bm9uY2U="), { key: createPublicKey(id.key), dsaEncoding: "ieee-p1363" }, sig));
  assert.equal(signalUrl("wss://x.test/"), "wss://x.test");
  if (!process.env.YOYO_SIGNAL_URL) assert.equal(signalUrl(), "", "none built in");
});

test("signal: registers, sends the link binding, reconnects after a drop", async () => {
  FakeWS.made = [];
  const id = loadOrCreateIdentity(mkdtempSync(join(tmpdir(), "relay-")));
  const changes: boolean[] = [];
  const r = new SignalClient({ identity: id, url: "wss://signal.test/", WebSocket: FakeWS as never });
  r.on("change", (on: boolean) => changes.push(on));
  try {
    r.start();
    const control = FakeWS.made[0]!;
    assert.equal(control.url, `wss://signal.test/v1/mac/${relayRoom(id.keyFingerprint)}`);
    control.open();
    control.message(JSON.stringify({ type: "challenge", nonce: "abc=" }));
    const hello = JSON.parse(control.sent[0] as string);
    assert.ok(verify("sha256", Buffer.from("yoyocontrol-relay-v1:abc="), { key: createPublicKey(id.key), dsaEncoding: "ieee-p1363" }, Buffer.from(hello.sig, "base64")));
    control.message(JSON.stringify({ type: "ready" }));
    assert.equal(r.registered, true);
    assert.equal(control.sent[1], '{"id":null,"type":"account"}', "no account: said so");
    assert.equal(control.sent.length, 2, "no binding yet: nothing more");
    // the link binding: sent now and after every registration
    const link = { id: "ab".repeat(32), key: "a2V5", sig: "c2ln", relays: [], direct: ["81.2.69.160:47820"] };
    r.setLink(link);
    assert.equal(control.sent[2], '{"direct":["81.2.69.160:47820"],"id":"' + "ab".repeat(32) + '","key":"a2V5","relays":[],"sig":"c2ln","type":"link"}');
    r.setLink({ ...link });
    assert.equal(control.sent.length, 3);
    // the account: sent now; the room's "unlinked" forgets it
    let unlinked = 0;
    r.on("unlinked", () => unlinked++);
    r.setAccount("0a".repeat(16));
    assert.equal(control.sent[3], '{"id":"' + "0a".repeat(16) + '","type":"account"}');
    control.message(JSON.stringify({ type: "account", state: "linked" }));
    assert.equal(unlinked, 0);

    // dropped: registered → false, again after 1 s, the binding sent at once
    control.close();
    assert.equal(r.registered, false);
    await sleep(1100);
    assert.equal(FakeWS.made.length, 2);
    const again = FakeWS.made[1]!;
    again.open();
    again.message(JSON.stringify({ type: "challenge", nonce: "x" }));
    again.message(JSON.stringify({ type: "ready" }));
    assert.equal(again.sent[1], control.sent[2], "the binding again");
    assert.equal(again.sent[2], control.sent[3], "and the account");
    again.message(JSON.stringify({ type: "account", state: "unlinked" }));
    assert.equal(unlinked, 1);
    assert.deepEqual(changes, [true, false, true]);
  } finally {
    r.stop();
  }
});
