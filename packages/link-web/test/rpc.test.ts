import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { dialRtc, LinkError, RPC_CHUNK, RPC_SEND_HIGH, rpcRequest, type LinkSession } from "../src/index.js";
import { FakePeerConnection, Identity, ScriptedServer } from "./fake.js";

const WASM = readFileSync(fileURLToPath(new URL("../src/wasm/uu_link_wasm_bg.wasm", import.meta.url)));

async function dial(server: ScriptedServer): Promise<{ session: LinkSession; pc: FakePeerConnection }> {
  const identity = await Identity.create();
  let pc: FakePeerConnection | null = null;
  const session = await dialRtc({
    signal: async (offer) => identity.answer(offer.offer),
    pinnedFingerprint: identity.fingerprint,
    credential: "Bearer t0ken",
    device: { id: "dev-1", name: "Test Browser" },
    app: { name: "test", version: "1" },
    wasm: WASM,
    iface: "wifi",
    createPeerConnection: (c) => (pc = new FakePeerConnection(server, c)) as unknown as RTCPeerConnection,
  });
  return { session, pc: pc! };
}

test("a 30 MiB upload is paced by the channel's buffer (a browser's send queue refuses past its size)", async () => {
  const server = new ScriptedServer();
  const { session, pc } = await dial(server);
  const size = 30 * 1024 * 1024;
  const body = new Uint8Array(size);
  for (let i = 0; i < size; i += 4096) body[i] = (i / 4096) & 0xff;
  const pending = session.request({ method: "POST", path: "/upload" }, body);
  const ch = pc.channels.at(-1)!;
  // what is sent stays buffered until SCTP takes it; Chrome refuses sends past 16 MiB queued
  ch.buffering = true;
  ch.queueLimit = 16 * 1024 * 1024;
  const pump = setInterval(() => ch.drain(), 1);
  try {
    const r = await pending;
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { m: "POST", p: "/upload", n: size });
  } finally {
    clearInterval(pump);
  }
  assert.ok(ch.maxBuffered <= RPC_SEND_HIGH + RPC_CHUNK, `at most the high-water mark and a piece buffered: ${ch.maxBuffered}`);
  assert.ok(ch.maxBuffered > RPC_SEND_HIGH / 2, "it did fill to the mark");
  const sentBody = ch.sent.slice(1, -1);
  assert.equal(sentBody.reduce((n, m) => n + m.length, 0), size);
  await session.close();
});

test("the timeout runs from the request's FIN: a slow upload that makes progress isn't cut off; no answer after the FIN is", async () => {
  const server = new ScriptedServer();
  const { session, pc } = await dial(server);
  const conn = pc as unknown as RTCPeerConnection;
  const timeout = 100;
  const slowly = async (path: string) => {
    const p = rpcRequest(conn, { method: "POST", path }, new Uint8Array(8 * 1024 * 1024), timeout);
    const ch = pc.channels.at(-1)!;
    ch.buffering = true;
    // ~8 drains 40 ms apart: the upload takes about 3x the timeout
    const pump = setInterval(() => ch.drain(), 40);
    const t0 = performance.now();
    try {
      return { r: await p, ms: performance.now() - t0 };
    } finally {
      clearInterval(pump);
    }
  };
  const { r, ms } = await slowly("/slow");
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { m: "POST", p: "/slow", n: 8 * 1024 * 1024 });
  assert.ok(ms > 2 * timeout, `the upload took longer than the timeout: ${ms} ms`);

  // a server that never answers: the clock starts at the FIN
  server.rpc = () => {};
  const t0 = performance.now();
  await assert.rejects(slowly("/silent"), (e: unknown) => e instanceof LinkError && e.kind === "timeout" && /no answer to POST \/silent/.test(e.message));
  assert.ok(performance.now() - t0 > 2 * timeout, "not before the upload was done");

  // and a channel that never opens still times out
  pc.connectionState = "new";
  await assert.rejects(rpcRequest(conn, { method: "GET", path: "/never" }, undefined, timeout), (e: unknown) => e instanceof LinkError && e.kind === "timeout" && /no channel/.test(e.message));
  pc.connectionState = "connected";
  await session.close();
});
