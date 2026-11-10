import assert from "node:assert/strict";
import { test } from "node:test";
import { PortMapping, probe, type PortMapState, type PortMappingOptions } from "../src/index.js";
import { FakeClock, FakeRouter, ME, settle, type FakeOptions } from "./fake.js";

function setup(fake: FakeOptions, extra: Partial<PortMappingOptions> = {}) {
  const router = new FakeRouter(fake);
  const clock = new FakeClock();
  const states: PortMapState[] = [];
  const logs: string[] = [];
  let seed = 0;
  const m = new PortMapping({
    internalPort: 47820,
    description: "Test",
    lifetime: 3600,
    network: router,
    clock,
    random: () => ((seed = (seed * 7 + 3) % 11) / 11),
    onChange: (s) => states.push(s),
    log: (l) => logs.push(l),
    ...extra,
  });
  return { router, clock, states, logs, m };
}

test("UPnP: maps the preferred port to this host, renews at half the lease, deletes on stop", async () => {
  const { router, clock, states, m } = setup({ upnp: true });
  const s = await m.start();
  assert.equal(s.status, "mapped");
  assert.ok(s.status === "mapped");
  assert.equal(s.method, "upnp");
  assert.equal(s.externalAddress, "93.184.216.34");
  assert.equal(s.externalPort, 47820);
  assert.equal(s.internalAddress, ME);
  assert.equal(s.lifetime, 3600);
  assert.deepEqual(router.upnp.get("TCP:47820"), { internalClient: ME, internalPort: 47820, description: "Test", lifetime: 3600 });
  assert.deepEqual(states.map((x) => x.status), ["probing", "mapped"]);
  assert.deepEqual(clock.pending, [1800_000]);

  router.calls.length = 0;
  clock.advance(1800_000);
  await settle();
  assert.ok(router.calls.includes("upnp AddPortMapping 47820"), router.calls.join(", "));
  assert.equal(router.calls.filter((c) => c.startsWith("ssdp")).length, 0, "the IGD is remembered between renewals");
  assert.equal(states.length, 2, "a renewal that changes nothing isn't a change");
  assert.deepEqual(clock.pending, [1800_000]);

  await m.stop();
  assert.equal(router.upnp.size, 0);
  assert.equal(m.state.status, "idle");
  assert.deepEqual(clock.pending, []);
  await m.stop(); // twice is fine
});

test("UPnP: an external port held by another host is skipped; the next one is used and kept on renewals", async () => {
  const { router, clock, m } = setup({ upnp: true });
  router.upnp.set("TCP:47820", { internalClient: "192.168.50.20", internalPort: 47820, description: "someone", lifetime: 0 });
  const s = await m.start();
  assert.ok(s.status === "mapped");
  assert.notEqual(s.externalPort, 47820);
  assert.equal(router.upnp.get("TCP:47820")!.internalClient, "192.168.50.20", "the other host's mapping is left alone");
  assert.equal(router.upnp.get(`TCP:${s.externalPort}`)!.internalClient, ME);
  const port = s.externalPort;
  clock.advance(1800_000);
  await settle();
  assert.ok(m.state.status === "mapped" && m.state.externalPort === port);
  await m.stop();
  assert.equal(router.upnp.size, 1);
});

test("UPnP: a stale mapping of our own on the port is taken over", async () => {
  const { router, m } = setup({ upnp: true });
  router.upnp.set("TCP:47820", { internalClient: ME, internalPort: 47820, description: "Test", lifetime: 3600 });
  const s = await m.start();
  assert.ok(s.status === "mapped" && s.externalPort === 47820);
  await m.stop();
  assert.equal(router.upnp.size, 0);
});

test("UPnP: 718 on the preferred port moves on; 725 retries with a permanent lease that is refreshed every 20 min", async () => {
  {
    const { router, m } = setup({ upnp: true, refuse: new Map([[47820, 718]]) });
    const s = await m.start();
    assert.ok(s.status === "mapped" && s.externalPort !== 47820);
    await m.stop();
    assert.equal(router.upnp.size, 0);
  }
  {
    const { router, clock, m } = setup({ upnp: true, permanentOnly: true });
    const s = await m.start();
    assert.ok(s.status === "mapped" && s.lifetime === 0 && s.externalPort === 47820);
    assert.equal(router.upnp.get("TCP:47820")!.lifetime, 0);
    assert.deepEqual(clock.pending, [1200_000]);
    await m.stop();
    assert.equal(router.upnp.size, 0);
  }
});

test("UPnP: a router that needs external = internal gets only that port", async () => {
  const { router, m } = setup({ upnp: true, samePortOnly: true }, { externalPort: 50000 });
  const s = await m.start();
  assert.ok(s.status === "mapped" && s.externalPort === 47820);
  await m.stop();
  assert.equal(router.upnp.size, 0);
});

test("UPnP: a read-only router (606) is a failure, retried later with backoff", async () => {
  const { clock, m, logs } = setup({ upnp: true, readOnly: true });
  const s = await m.start();
  assert.equal(s.status, "failed");
  assert.ok(s.status === "failed" && /606/.test(s.error), JSON.stringify(s));
  assert.deepEqual(clock.pending, [60_000]);
  clock.advance(60_000);
  await settle();
  assert.deepEqual(clock.pending, [120_000]);
  assert.ok(logs.some((l) => l.includes("606")));
  await m.stop();
});

test("a CGNAT / private external address is unreachable: nothing stays mapped", async () => {
  for (const [fake, method] of [[{ upnp: true }, "upnp"], [{ pmp: true }, "natpmp"], [{ pcp: true }, "pcp"]] as const) {
    const { router, m } = setup({ ...fake, externalAddress: "100.72.1.9" });
    const s = await m.start();
    assert.equal(s.status, "unreachable", method);
    assert.ok(s.status === "unreachable" && s.reason === "cgnat" && s.method === method && s.externalAddress === "100.72.1.9");
    assert.equal(router.upnp.size + router.pmp.size + router.pcp.size, 0, `${method}: no mapping left`);
    await m.stop();
  }
  const { m } = setup({ upnp: true, externalAddress: "192.168.1.5" });
  const s = await m.start();
  assert.ok(s.status === "unreachable" && s.reason === "private");
  await m.stop();
});

test("nothing answers: unsupported, retried every 5 min", async () => {
  const { clock, m, states } = setup({});
  const s = await m.start();
  assert.equal(s.status, "unsupported");
  assert.deepEqual(clock.pending, [300_000]);
  clock.advance(300_000);
  await settle();
  assert.deepEqual(states.map((x) => x.status), ["probing", "unsupported"]);
  await m.stop();
});

test("NAT-PMP: maps with the router's port and lease, deletes on stop", async () => {
  const { router, clock, m } = setup({ pmp: true, pcpAsPmp: true, assignPort: 61000, grantLifetime: 600 });
  const s = await m.start();
  assert.ok(s.status === "mapped");
  assert.equal(s.method, "natpmp");
  assert.equal(s.externalPort, 61000);
  assert.equal(s.lifetime, 600);
  assert.equal(s.externalAddress, "93.184.216.34");
  assert.deepEqual(clock.pending, [300_000]);
  router.calls.length = 0;
  clock.advance(300_000);
  await settle();
  assert.ok(router.calls.some((c) => c.startsWith("pmp map 47820→61000")), router.calls.join(", "));
  await m.stop();
  assert.equal(router.pmp.size, 0);
});

test("PCP is preferred over NAT-PMP and UPnP; renewals and the delete use the same nonce", async () => {
  const { router, clock, m } = setup({ pcp: true, pmp: true, upnp: true });
  const s = await m.start();
  assert.ok(s.status === "mapped" && s.method === "pcp" && s.externalPort === 47820);
  assert.equal(router.pcp.size, 1);
  const nonce = router.pcp.get(47820)!.nonce;
  clock.advance(1800_000);
  await settle();
  assert.equal(router.pcp.get(47820)!.nonce, nonce);
  assert.equal(router.upnp.size + router.pmp.size, 0);
  await m.stop();
  assert.equal(router.pcp.size, 0);
});

test("methods can be limited", async () => {
  const { router, m } = setup({ pcp: true, upnp: true }, { methods: ["upnp"] });
  const s = await m.start();
  assert.ok(s.status === "mapped" && s.method === "upnp");
  assert.equal(router.pcp.size, 0);
  await m.stop();
});

test("a network change: refresh() drops the old router's mapping and maps on the new one", async () => {
  const { router, m, states } = setup({ upnp: true });
  await m.start();
  assert.equal(router.upnp.size, 1);
  // the same fake plays the new network: another gateway / address
  router.gatewayAddress = "10.0.0.1";
  router.me = "10.0.0.7";
  router.upnp.clear(); // the old router is unreachable now: its table stays behind (it expires by itself)
  const s = await m.refresh();
  assert.equal(s.status, "unsupported", "the fake's IGD lives at 192.168.50.1 only");
  assert.deepEqual(states.map((x) => x.status), ["probing", "mapped", "unsupported"]);
  await m.stop();
});

test("stop() during the first attempt still removes what that attempt mapped", async () => {
  const { router, m } = setup({ upnp: true });
  let stopped: Promise<void> | null = null;
  router.hook = (action) => {
    if (action === "AddPortMapping" && !stopped) stopped = m.stop();
  };
  await m.start();
  await stopped;
  assert.ok(router.calls.includes("upnp DeletePortMapping 47820"), router.calls.join(", "));
  assert.equal(router.upnp.size, 0);
  assert.equal(m.state.status, "idle");
});

test("probe() reports what the gateway speaks", async () => {
  const r = await probe({ network: new FakeRouter({ upnp: true, pmp: true, pcpAsPmp: true }) });
  assert.equal(r.gateway, "192.168.50.1");
  assert.equal(r.internalAddress, ME);
  assert.equal(r.pcp, null);
  assert.deepEqual(r.natpmp, { externalAddress: "93.184.216.34", epoch: 99 });
  assert.equal(r.upnp!.externalAddress, "93.184.216.34");
  assert.equal(r.upnp!.services.length, 1);
});
