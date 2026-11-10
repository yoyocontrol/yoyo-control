# @yoyocontrol/link

uu Link for Node: the UDP / QUIC (and, for browsers, WebRTC) transport between a phone and a computer running a uu server — sessions with a
`hello` / `welcome` handshake, JSON control messages, RPC (request → status, headers, streamed body) and datagram
channels — over the shared Rust core (`link/` in this repository; protocol and API: `docs/LINK.md`). Node ≥ 22, ESM,
typed. The native addon is prebuilt per platform (`native/uu-link.<platform>-<arch>[-gnu].node`: darwin-arm64,
linux-x64-gnu, linux-arm64-gnu).

```js
import { bindEndpoint, loadOrCreateLinkKey, Channel } from "@yoyocontrol/link";

const ep = await bindEndpoint({ role: "server", secretKey: loadOrCreateLinkKey(`${home}/link-key`), port: 47820 });
const binding = ep.binding(identityKeyX963);            // published with ep.addrInfo() for clients to dial
const listener = ep.listen({
  server: { id: serverId, name: "My Computer", platform: "linux" },
  features: ["link"],
  authenticate: async ({ hello, clientKey, sourceAddr }) =>
    devices.check(hello.credential, clientKey) ? { ok: true, principal: { device: hello.device } }
                                               : { ok: false, code: "unauthorized" },
  rpc: async (session, req, body, res) => routes.handle(session.principal, req, body, res),   // res.head / write / finish
});
for await (const session of listener) {
  for await (const m of session.controlMessages()) { /* { t: "video.open", … } */ }
}
```

Client side: `const ep = await bindEndpoint({ role: "client", secretKey })`, then
`await ep.dial({ id, relays, direct }, hello)` → the same `Session` (`request`, `sendControl`, `recvDatagram(Channel.video)`, …).

Browsers (WebRTC, `docs/LINK.md`「WebRTC」): give the server endpoint an rtc port and the listener the identity key; the
offers a browser sends by whatever path you have go to `acceptRtcOffer`, and its session comes out of the same listener:

```js
const ep = await bindEndpoint({ role: "server", secretKey, port: 47820, rtcPort: 47821 });
const listener = ep.listen({ server, authenticate, rpc, identityKey: identityKeyX963 });   // signs the answers
http.post("/link/rtc", async (req, res) => res.json(JSON.parse(await listener.acceptRtcOffer(await req.text(), req.ip))));
for await (const session of listener) session.transport;   // "rtc" for a browser, "quic" for the apps
```

`endpoint.dialRtc(signal, fingerprint, hello)` is the offering side (what a browser does), for tests and tools.

Building the addon for this machine: `npm run native` (needs a Rust toolchain; `link/rust-toolchain.toml`). Tests:
`npm test` (loopback: handshake, denied, RPC, control messages, datagrams, binding; the same over WebRTC).
