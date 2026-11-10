import assert from "node:assert/strict";
import { test } from "node:test";
import { clientCertificate, clientKeyOf, CERTIFICATE_LIFETIME_MS, dialRtc, type CertificateStore, type DialRtcOptions } from "../src/index.js";
import { FakePeerConnection, Identity, ScriptedServer } from "./fake.js";

/** A stand-in certificate: what `generateCertificate` would make. */
function fakeCertificate(expires: number, hex = "AB:CD:EF"): RTCCertificate {
  return { expires, getFingerprints: () => [{ algorithm: "sha-256", value: hex }] } as unknown as RTCCertificate;
}

function memoryStore(initial?: RTCCertificate): CertificateStore & { saved: RTCCertificate[] } {
  let kept = initial;
  const saved: RTCCertificate[] = [];
  return {
    saved,
    load: async () => kept,
    save: async (c) => {
      kept = c;
      saved.push(c);
    },
  };
}

/** Installs a `RTCPeerConnection.generateCertificate` that counts its calls. */
function stubGenerate(): { calls: unknown[]; restore: () => void } {
  const g = globalThis as { RTCPeerConnection?: unknown };
  const before = g.RTCPeerConnection;
  const calls: unknown[] = [];
  g.RTCPeerConnection = { generateCertificate: async (alg: unknown) => (calls.push(alg), fakeCertificate(Date.now() + CERTIFICATE_LIFETIME_MS, `0${calls.length}:FF`)) };
  return { calls, restore: () => (g.RTCPeerConnection = before) };
}

test("a kept certificate is reused; none, or one about to expire, is replaced and saved", async () => {
  const gen = stubGenerate();
  try {
    const valid = fakeCertificate(Date.now() + 30 * 24 * 3600 * 1000);
    assert.equal(await clientCertificate(memoryStore(valid)), valid);
    assert.equal(gen.calls.length, 0);

    const empty = memoryStore();
    const [a, b] = await Promise.all([clientCertificate(empty), clientCertificate(empty)]);
    assert.equal(a, b, "concurrent calls share one certificate");
    assert.equal(gen.calls.length, 1);
    assert.deepEqual(gen.calls[0], { name: "ECDSA", namedCurve: "P-256", expires: CERTIFICATE_LIFETIME_MS });
    assert.deepEqual(empty.saved, [a]);
    assert.equal(await clientCertificate(empty), a, "the saved one comes back");

    const expiring = memoryStore(fakeCertificate(Date.now() + 3600 * 1000));
    const renewed = await clientCertificate(expiring);
    assert.equal(gen.calls.length, 2);
    assert.deepEqual(expiring.saved, [renewed]);
  } finally {
    gen.restore();
  }
});

test("the client key is dtls-sha256 of the certificate's fingerprint, lower case without colons", () => {
  assert.equal(clientKeyOf(fakeCertificate(0, "AB:CD:EF")), "dtls-sha256:abcdef");
  assert.equal(clientKeyOf({ expires: 0 } as unknown as RTCCertificate), undefined);
});

test("dialRtc gives the peer connection the stored certificate; explicit certificates win; null = none", async () => {
  const identity = await Identity.create();
  const kept = fakeCertificate(Date.now() + CERTIFICATE_LIFETIME_MS);
  const explicit = fakeCertificate(Date.now() + CERTIFICATE_LIFETIME_MS);
  const configs: RTCConfiguration[] = [];
  const dial = (over: Partial<DialRtcOptions>) =>
    dialRtc({
      signal: async (offer) => identity.answer(offer.offer),
      pinnedFingerprint: identity.fingerprint,
      credential: "Bearer t",
      device: { id: "d", name: "n" },
      app: { name: "test", version: "1" },
      media: false,
      createPeerConnection: (c) => (configs.push(c), new FakePeerConnection(new ScriptedServer(), c)) as unknown as RTCPeerConnection,
      ...over,
    });
  await (await dial({ certificateStore: memoryStore(kept) })).close();
  await (await dial({ certificateStore: memoryStore(kept), certificates: [explicit] })).close();
  await (await dial({ certificateStore: null })).close();
  assert.deepEqual(configs.map((c) => c.certificates), [[kept], [explicit], undefined]);

  await assert.rejects(dial({ certificateStore: { load: async () => Promise.reject(new Error("blocked")), save: async () => {} } }), (e: Error & { kind?: string }) => e.kind === "unsupported");
});
