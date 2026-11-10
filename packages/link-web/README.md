# @yoyocontrol/link-web

uu Link in the browser. A browser can't open raw UDP or pin a self-signed certificate for `fetch`, so here a uu Link
session runs over **WebRTC**: one `RTCPeerConnection` per session, carrying the same session protocol as the native
transport (`hello` / `welcome`, JSON control messages, RPC, datagram channels) and the same media layer
(`uu-link-media`'s FEC, NACK, frame reassembly, input reliability), compiled to WebAssembly. The server's DTLS
certificate is signed by the computer's identity key, so the browser pins the computer exactly like the iOS app does.
Protocol: `docs/LINK.md`「WebRTC」. ESM, typed, no framework, no UI, no dependencies.

| module | what |
| --- | --- |
| `dial` | `dialRtc(options)` → `LinkSession`: offer, signaling (yours), answer verification, `hello` → `welcome` |
| `session` | `LinkSession`: `sendControl` / `onControl` / `controlMessages()`, `request` / `fetch` (RPC), `sendDatagram` / `onDatagram` (channels 6–15), `media`, `path()`, `stats()`, `peerStats()`, `close(code, reason)`, `closed()` |
| `screen` | `linkScreen(session)` → `@yoyocontrol/screen-web`'s `ScreenLink` (video, sound, cursor, input, control over the session) |
| `media` | `LinkMedia`: the session's media layer, driven on its own timer (`openVideo`, `frameDecoded`, `requestKeyframe`, `sendInput`, `onEvent`, `counters`) |
| `wasm` | `loadLinkMedia(source?)`: the `.wasm` (one per page), and the typed media events |
| `verify` | `verifyAnswer(offerSdp, answer, pinnedFingerprint)` with WebCrypto, `rtcSignedText`, fingerprints |
| `rpc` | `RpcResponse`: status, headers, the body as it streams (`chunk`, `readAll`, `text`, `json`, `for await`, `toResponse`) |
| `stats` | `link.stats` objects, the `link:` line (`statsLine`), path kinds from the selected candidate pair |
| `framing` | `u32 BE length` + JSON frames over a channel's byte stream |
| `errors` | `LinkError` (`kind`, `code`), `LinkRequestError` (status-shaped), `CloseCode` |

## Quick start

```ts
import { dialRtc, LinkError } from "@yoyocontrol/link-web";

const session = await dialRtc({
  // your signaling path: anything that gets the offer to the computer and its answer back
  signal: async (offer) => (await fetch(`https://relay.example/v1/rtc/${fp}`, { method: "POST", body: JSON.stringify(offer) })).json(),
  pinnedFingerprint: fp,                       // "sha256:<hex>": the computer's identity, as paired
  credential: `Bearer ${deviceToken}`,         // hello.credential
  device: { id: deviceId, name: "Safari on iPhone" },
  app: { name: "my-app", version: "1.0" },
  iceServers: [{ urls: "stun:stun.cloudflare.com:3478" }],
});
console.log(session.server.name, session.path().kind);       // "My Mac" "lan"
console.log(session.timing);                                   // { gatheredMs, answeredMs, connectedMs, welcomeMs }

const status = await (await session.fetch("/status")).json();  // any route as RPC
session.onControl((m) => console.log(m.t));                    // control messages
await session.close();
```

`dialRtc` rejects with a `LinkError`: `denied` (`code`: `unauthorized` / `rate-limited` / `busy`), `verification`
(the answer is not from the pinned computer: never retry it), `signal` (your signaling path threw; `cause`), `timeout`,
`closed`, `unsupported`.

## The screen over a link

`linkScreen(session)` is the media route `@yoyocontrol/screen-web` takes: the page's `VideoStream`, `ScreenAudio`, cursor
and `InputQueue` run over the session instead of HTTP (the iOS kit's `YoyoLinkConnection`).

```ts
import { linkScreen } from "@yoyocontrol/link-web";
import { InputQueue, linkInputSender, linkSetControl, ScreenAudio, VideoStream } from "@yoyocontrol/screen-web";

const link = linkScreen(session);
const video = new VideoStream({ link, canvas, interactivity }, { onPicture, onCursor, onStatus, onEnd });
void video.run();                                              // video.open; frames → WebCodecs; decoder answers back
const audio = new ScreenAudio(transport, onAudioState, { link: () => link });
const input = new InputQueue(httpSend, onInputFailed, Date.now(), undefined, { link: () => linkInputSender(link) });
link.setInputErrorHandler(onInputFailed);                      // input.rejected, unacknowledged input
await linkSetControl(link, true);                              // control.take
statsLine.textContent = link.statsLine;                        // "lan wifi rtt 0.4/1.2/2.0 ms loss 0.0 % fec 3 …"
```

## The `.wasm`

`dist/wasm/uu_link_wasm_bg.wasm` (≈ 250 KB, ≈ 90 KB gzipped) is loaded once per page, by default from next to the
module (`new URL("./wasm/uu_link_wasm_bg.wasm", import.meta.url)`): Vite and other bundlers that understand that
pattern copy it as an asset. A host that serves it from elsewhere passes `wasm` to `dialRtc` (a URL, a `Response`,
the bytes or a compiled `WebAssembly.Module`), or calls `loadLinkMedia(source)` first. With Vite, keep the package out
of dependency pre-bundling so `import.meta.url` stays the file's own:

```ts
// vite.config.ts
export default { optimizeDeps: { exclude: ["@yoyocontrol/link-web"] } };
```

The package also exports the file as `@yoyocontrol/link-web/uu_link_wasm_bg.wasm` (for `?url` imports).
`dialRtc({ media: false })` makes a session without the media layer (control and RPC only; nothing is loaded). Call
`loadLinkMedia()` early (when the page opens) so the first dial doesn't wait for the download and compile (~90 ms).

## What the browser does (docs/LINK.md「WebRTC」)

- Channels: `control` (negotiated id 0, ordered, reliable), `dgram` (negotiated id 1, `ordered: false`,
  `maxRetransmits: 0`; one message = one datagram, byte 0 = `channel << 4 | 1`), one in-band `rpc` channel per
  request (head frame, body, a zero-length message as the FIN; closed without it = reset).
- Offer: non-trickle, ICE gathering capped at `gatherTimeoutMs` (1 s); `{v: 1, offer, device}` to `signal`.
- Answer: `SHA-256(binding.key)` must be the pinned fingerprint, `sig` must verify (ECDSA P-256) over
  `"yoyocontrol-rtc-v1:" + sha256(offer SDP) + ":" + fingerprint`, and the answer SDP's `a=fingerprint` must be
  `fingerprint`. Only then is it applied.
- The session: `link.stats` every 2 s (path and RTT from `getStats()`'s selected candidate pair, iface from
  `navigator.connection` or `iface`), the media layer fed the RTT every 100 ms, `bye {code, reason}` on close, ended
  after 20 s without anything from the server, after 3 s of silence while a `linkScreen` video stream is open (the
  server then always sends: `link.stats` every 2 s, the stream's keepalives; `session.setActivityTimeout(ms)` for
  other uses), or as soon as the peer connection or ICE goes `disconnected` / `failed` — so a page with another way
  falls back within seconds (screen-ui's e2e: probe killed → pictures on the HTTP way in ≈ 4.1 s, was ≈ 17 s).
- The DTLS certificate is the client's key on the server side (`dtls-sha256:<hex>`; a device token binds to it), so
  it is kept: by default in IndexedDB (database `yoyocontrol-link`, made on the first dial, ECDSA P-256, valid a year,
  replaced a day before it expires — which means pairing again). Pass `certificateStore` (`{ load, save }`) to keep it
  elsewhere, `certificates` to supply your own, or `certificateStore: null` for a fresh one per connection.
  `clientKeyOf(certificate)` is the string the server sees.

## Install

Private for now: published as a git tag (`scripts/git-dist.sh link-web <version>` → branch `dist/link-web`, tag
`link-web-v<version>`; the `.wasm` is in the dist):

```json
"@yoyocontrol/link-web": "git+https://github.com/yoyocontrol/yoyo-control.git#link-web-v0.1.1"
```

`@yoyocontrol/screen-web` (≥ 0.3.0) is an optional peer: only `linkScreen`'s types need it.

## Develop

```sh
npm install                              # at the repo root (workspaces)
npm -w packages/link-web run wasm        # the .wasm from link/wasm (Rust toolchain + wasm32 target; installs wasm-bindgen-cli once)
npm -w packages/link-web test            # node --test: framing, verification, RPC, session (fake peer connection), the wasm build
npm -w packages/link-web run e2e         # a real Chrome against uu-link-probe serve-rtc (see test/e2e/run.mjs); -- --netem 5g
npm -w packages/link-web run e2e -- --page screen   # screen-web's VideoStream / ScreenAudio over a link, in Chrome
npm -w packages/link-web run build       # dist/ with the glue and the .wasm
```

The wasm-bindgen glue (`src/wasm/uu_link_wasm.js`, `.d.ts`) is committed; `npm run wasm:check` fails when it no
longer matches the Rust code. `link/wasm/tests/fec_fixture.rs` and `test/wasm.test.ts` share a fixture (one key
frame's datagrams from the native sender, with two data shards to drop) so the wasm build is checked against the
native FEC.

## Not yet

- TURN (`relay` paths): only host / reflexive candidates this round.
- A Worker: everything runs on the main thread (the wasm calls are cheap; a frame's access unit is copied once).
