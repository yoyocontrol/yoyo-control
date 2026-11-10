import assert from "node:assert/strict";
import { test } from "node:test";
import { candidate, ConnectWays, Connector, raceFirst, type Clock, type ConnectSource, type Probe } from "../src/connector.js";

/** A clock the test moves by hand. */
class FakeClock implements Clock {
  t = 0;
  private timers: { at: number; fn: () => void; id: number }[] = [];
  private next = 0;
  now() {
    return this.t;
  }
  setTimeout(fn: () => void, ms: number) {
    const id = ++this.next;
    this.timers.push({ at: this.t + Math.max(0, ms), fn, id });
    return id;
  }
  clearTimeout(h: unknown) {
    this.timers = this.timers.filter((x) => x.id !== h);
  }
  async advance(ms: number) {
    const end = this.t + ms;
    for (;;) {
      await flush();
      this.timers.sort((a, b) => a.at - b.at);
      const first = this.timers[0];
      if (!first || first.at > end) break;
      this.timers.shift();
      this.t = first.at;
      first.fn();
    }
    this.t = end;
    await flush();
  }
}
const flush = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

const tunnel = candidate({ kind: "tunnel", id: "tunnel" });
const link = candidate({ kind: "link", id: "link", host: "mac" });
const lan = candidate({ kind: "lan", id: "lan", host: "10.0.0.2" });

function setup(probe: (c: { id: string }, clock: FakeClock) => Promise<Probe<string>>, candidates = [link, lan]) {
  const clock = new FakeClock();
  const released: string[] = [];
  const source: ConnectSource<string> = {
    candidates: async () => ({ candidates, fresh: true }),
    probe: (c) => probe(c, clock),
    release: (l) => released.push(l),
  };
  const ways = new ConnectWays<string>(tunnel, "tunnel-link", [tunnel]);
  const c = new Connector(ways, source, {}, clock);
  c.watchesPath = false;
  c.linkPossible = true;
  return { c, clock, released };
}

const after = (clock: FakeClock, ms: number, p: Probe<string>) => new Promise<Probe<string>>((r) => clock.setTimeout(() => r(p), ms));

test("the link is raced first and becomes the way; a stream about to open waits for it", async () => {
  const { c, clock } = setup((cand, clock) => (cand.id === "link" ? after(clock, 100, { t: "reached", link: "L" }) : after(clock, 10, { t: "reached", link: "N" })));
  let changes = 0;
  c.onChange = () => changes++;
  c.activate();
  await flush();
  assert.equal(c.isDeciding, true);
  assert.equal(c.current.id, "tunnel");
  await clock.advance(150);
  assert.equal(c.current.id, "link");
  assert.equal(c.current.isShortcut, true);
  assert.equal(c.isDeciding, false);
  assert.equal(c.ways.link(c.current), "L");
  assert.ok(changes > 0);
});

test("another way reached while the link is late is taken, and the link still wins within its grace", async () => {
  const { c, clock } = setup((cand, clock) => (cand.id === "link" ? after(clock, 900, { t: "reached", link: "L" }) : after(clock, 20, { t: "reached", link: "N" })));
  c.activate();
  await clock.advance(400);
  assert.equal(c.current.id, "lan");
  await clock.advance(800);
  assert.equal(c.current.id, "link");
});

test("a failing shortcut goes back to the fallback and isn't raced again for a while", async () => {
  const { c, clock } = setup((cand, clock) => (cand.id === "link" ? after(clock, 10, { t: "reached", link: "L" }) : after(clock, 10, { t: "unreachable" })));
  c.activate();
  await clock.advance(100);
  assert.equal(c.current.id, "link");
  const route = c.current;
  for (let i = 0; i < 3; i++) c.ackAnswered(route, null);
  assert.equal(c.current.id, "tunnel");
  c.streamWillOpen();
  await flush();
  assert.equal(c.isDeciding, false, "no race before the retry interval");
  await clock.advance(30_000 + 100);
  assert.equal(c.current.id, "link", "raced again after it");
});

test("a request failing on the shortcut is sent again on the fallback; the computer's own answers aren't", async () => {
  const { c, clock } = setup((cand, clock) => after(clock, 10, cand.id === "link" ? { t: "reached", link: "L" } : { t: "unreachable" }));
  c.activate();
  await clock.advance(100);
  const route = c.current;
  assert.equal(await c.fallback(route, { status: 409 }), null);
  assert.equal(c.current.id, "link");
  const fb = await c.fallback(route, new TypeError("network"));
  assert.equal(fb?.id, "tunnel");
  assert.equal(c.current.id, "tunnel");
});

test("a race: the first reached wins, a late one is released, all failing with a 401 says so", async () => {
  const clock = new FakeClock();
  const released: string[] = [];
  const probe = (c: { id: string }) => after(clock, c.id === "lan" ? 5 : 50, { t: "reached", link: c.id });
  const race = raceFirst([lan, candidate({ kind: "direct", id: "direct" })], { link: -250, lan: 0, direct: 150, relay: 300, tunnel: 300 }, probe, (l) => released.push(l), new AbortController().signal, clock);
  await clock.advance(300);
  const o = await race;
  assert.equal(o.t === "reached" && o.candidate.id, "lan");
  const none = raceFirst([lan], { link: 0, lan: 0, direct: 0, relay: 0, tunnel: 0 }, async () => ({ t: "unauthorized" }), () => {}, new AbortController().signal, clock);
  await clock.advance(10);
  assert.deepEqual(await none, { t: "unauthorized" });
});
