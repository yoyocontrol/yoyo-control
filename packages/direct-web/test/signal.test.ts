import assert from "node:assert/strict";
import { test } from "node:test";
import { LinkError } from "@yoyocontrol/link-web";
import { DirectError, directError } from "../src/errors.js";
import { fallbackSignal, pathsTurn, relaySignal, relayTurn, SignalError, signalPaths } from "../src/signal.js";
import { iceServersFor } from "../src/connection.js";
import { json } from "./fakes.js";

const fp = `sha256:${"cd".repeat(32)}`;
const offer = { v: 1 as const, offer: "v=0", device: { id: "browser-1", name: "Safari" } };

test("the offer goes to the relay's room as JSON; the answer comes back", async () => {
  const seen: { url: string; init: RequestInit }[] = [];
  const signal = relaySignal("https://relay.test/", fp, async (url, init) => {
    seen.push({ url: String(url), init: init! });
    return json(200, { v: 1, answer: "v=0 answer" });
  });
  assert.deepEqual(await signal(offer), { v: 1, answer: "v=0 answer" });
  assert.equal(seen[0]!.url, `https://relay.test/v1/rtc/${"cd".repeat(32)}`);
  assert.equal(seen[0]!.init.method, "POST");
  assert.deepEqual(JSON.parse(String(seen[0]!.init.body)), offer);
  assert.equal(seen[0]!.init.credentials, "omit");
});

test("the relay's refusals are SignalErrors; 503 is offline", async () => {
  for (const [status, offline] of [[503, true], [504, false], [429, false]] as const) {
    const signal = relaySignal("https://relay.test", fp, async () => json(status, { error: `e${status}` }));
    await assert.rejects(signal(offer), (e: unknown) => e instanceof SignalError && e.status === status && e.offline === offline && e.message === `e${status}`);
  }
});

test("dial failures as DirectErrors", () => {
  const signalFailure = (status: number) => new LinkError("signal", "x", undefined, { cause: new SignalError(status, "y") });
  const cases: [unknown, string, number][] = [
    [new LinkError("denied", "no", "unauthorized"), "unpaired", 401],
    [new LinkError("denied", "busy", "busy"), "busy", 429],
    [new LinkError("denied", "slow down", "rate-limited"), "busy", 429],
    [signalFailure(503), "offline", 523],
    [signalFailure(504), "unreachable", 522],
    [signalFailure(429), "busy", 429],
    [new LinkError("signal", "failed to fetch"), "unreachable", 522],
    [new LinkError("timeout", "no session"), "unreachable", 522],
    [new LinkError("verification", "not the paired Mac"), "verification", 495],
    [new LinkError("unsupported", "no WebRTC"), "unsupported", 501],
    [new TypeError("Failed to fetch"), "unreachable", 522],
  ];
  for (const [e, kind, status] of cases) {
    const d = directError(e);
    assert.equal(d.kind, kind, String(e));
    assert.equal(d.status, status);
  }
  assert.equal(directError(new LinkError("denied", "wrong code", "unauthorized"), true).kind, "pairing");
  assert.equal(new DirectError("offline", "x").retryable, true);
  assert.equal(new DirectError("unpaired", "x").retryable, false);
});

test("the host's words replace the message of their kind", () => {
  const d = directError(new LinkError("denied", "unknown token", "unauthorized"), false, { unpaired: "Pair again." });
  assert.equal(d.kind, "unpaired");
  assert.equal(d.message, "Pair again.");
  assert.equal(directError(new LinkError("timeout", "no session"), false, { unpaired: "Pair again." }).message, "no session");
});

test("TURN comes from the relay before a dial, kept until an hour before it runs out", async () => {
  const urls: string[] = [];
  const server = { urls: ["turn:relay1.test:3478?transport=udp"], username: "1:x", credential: "c" };
  const f = async (url: string | URL | Request) => {
    urls.push(String(url));
    return json(200, { iceServers: [server], ttl: 43200 });
  };
  const fpT = `sha256:${"ef".repeat(32)}`;
  assert.deepEqual(await relayTurn("https://relay.test/", fpT, f as typeof fetch, 0), [server]);
  assert.equal(urls[0], `https://relay.test/v1/turn/${"ef".repeat(32)}`);
  await relayTurn("https://relay.test", fpT, f as typeof fetch, 1000);
  assert.equal(urls.length, 1, "kept");
  await relayTurn("https://relay.test", fpT, f as typeof fetch, (43200 - 3600) * 1000 + 1);
  assert.equal(urls.length, 2, "asked again near the end");
});

test("no TURN (an older relay, an error, garbage) leaves the dial on STUN alone", async () => {
  const fpN = `sha256:${"12".repeat(32)}`;
  assert.deepEqual(await relayTurn("https://relay.test", fpN, (async () => json(404, { error: "not found" })) as typeof fetch), []);
  assert.deepEqual(await relayTurn("https://relay.test", fpN, (async () => { throw new TypeError("failed to fetch"); }) as typeof fetch), []);
  assert.deepEqual(await relayTurn("https://relay.test", fpN, (async () => json(200, { iceServers: [{ nope: 1 }] })) as typeof fetch), []);
});

test("a dial's ICE servers: STUN plus the relay's TURN, or STUN only with turn: false", async () => {
  const stun = { urls: "stun:stun.test:3478" };
  const turn = { urls: ["turn:relay1.test:3478"], username: "1:x", credential: "c" };
  const fetchTurn = (async () => json(200, { iceServers: [turn], ttl: 60 })) as typeof fetch;
  const base = { identity: {} as never, deviceName: "x", app: { name: "t", version: "1" }, iceServers: [stun], fetch: fetchTurn };
  const mac = { fingerprint: `sha256:${"34".repeat(32)}`, relay: "https://relay.test" };
  assert.deepEqual(await iceServersFor(base, mac), [stun, turn]);
  assert.deepEqual(await iceServersFor({ ...base, turn: false }, mac), [stun]);
});

test("a dial signals through the given servers first, the Mac's relay after", () => {
  assert.deepEqual(signalPaths(["https://signal1.test/"], "https://relay.test"), ["https://signal1.test", "https://relay.test"]);
  assert.deepEqual(signalPaths(["https://relay.test"], "https://relay.test/"), ["https://relay.test"]);
  assert.deepEqual(signalPaths([], "https://relay.test"), ["https://relay.test"]);
  assert.deepEqual(signalPaths([], ""), [], "no server built in");
});

test("an offer goes on to the next path when one can't take it; the one that answered goes first next time", async () => {
  const fpx = `sha256:${"ef".repeat(32)}`;
  const seen: string[] = [];
  let signalUp = false;
  const fetchImpl: typeof fetch = async (url) => {
    const u = String(url);
    seen.push(new URL(u).host);
    if (u.startsWith("https://signal1.test")) {
      if (!signalUp) throw new TypeError("Failed to fetch");
      return json(503, { error: "mac offline" });
    }
    return json(200, { v: 1, answer: "a" });
  };
  const signal = fallbackSignal(["https://signal1.test", "https://relay.test"], fpx, fetchImpl);
  assert.deepEqual(await signal(offer), { v: 1, answer: "a" });
  assert.deepEqual(seen, ["signal1.test", "relay.test"]);
  seen.length = 0;
  await signal(offer);
  assert.deepEqual(seen, ["relay.test"], "the relay answered last time: it goes first");

  // a refusal from the Mac itself is thrown at once, wherever it came from
  const refusing = fallbackSignal(["https://signal1.test", "https://relay.test"], `sha256:${"01".repeat(32)}`, async (url) => {
    seen.push(new URL(String(url)).host);
    return json(429, { error: "cooling down" });
  });
  seen.length = 0;
  await assert.rejects(refusing(offer), (e: unknown) => e instanceof SignalError && e.status === 429);
  assert.deepEqual(seen, ["signal1.test"]);

  // every path down: the most telling failure (a room's 503 over a fetch that failed)
  signalUp = true;
  const down = fallbackSignal(["https://signal1.test", "https://relay.test"], `sha256:${"02".repeat(32)}`, async (url) => {
    if (String(url).startsWith("https://relay.test")) throw new TypeError("Failed to fetch");
    return json(503, { error: "mac offline" });
  });
  await assert.rejects(down(offer), (e: unknown) => e instanceof SignalError && e.offline);
});

test("TURN comes from the first path that hands some out", async () => {
  const fpx = `sha256:${"03".repeat(32)}`;
  const servers = await pathsTurn(["https://signal1.test", "https://relay.test"], fpx, async (url) =>
    String(url).startsWith("https://signal1.test") ? json(404, { error: "no TURN here" }) : json(200, { iceServers: [{ urls: ["turn:x"], username: "u", credential: "c" }], ttl: 43200 }),
  );
  assert.deepEqual(servers, [{ urls: ["turn:x"], username: "u", credential: "c" }]);
});
