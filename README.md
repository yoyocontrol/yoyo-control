# @yoyocontrol/direct-web

Yoyo Control's own backend for browsers: the Macs this browser paired with, pairing from a Mac's web pairing link,
and a [`ScreenBackend`](../screen-ui) for `<yoyo-screen>`, `<yoyo-clipboard>` and `ScreenPreview`. It is what
Yoyo Control's web app (`webapp/`, `https://yoyocontrol.com/app/`) runs on — the browser counterpart of the iOS kit's
`YoyoDirect`.

A browser can't dial QUIC, so **uu Link over WebRTC is its way** ([`@yoyocontrol/link-web`](../link-web),
docs/LINK.md「WebRTC」). The offer goes through a signaling server you name (`relay`; `POST <server>/v1/rtc/<fp>`,
docs/RELAY.md; none is built in), the Mac's answer is signed by its identity
key and checked against the fingerprint pinned at pairing, and everything after that — status, control, input,
clipboard, events, pictures and sound — rides the link session. ESM, typed, no framework, no UI.

| module | what |
| --- | --- |
| `direct` | `DirectWeb`: the paired Macs, `pair(link)`, `forget(id)`, `backend(mac)` (one per Mac), this browser's identity |
| `pairing` | `parsePairingLink(url \| fragment)` → `{ serverId, name, fingerprint, code }` |
| `store` | `PairedMac`, `DeviceIdentity`; `browserStore()` (IndexedDB) / `memoryStore()` / your own `DirectStore` (Macs and the device id) |
| `connection` | `MacConnection`: the session to one Mac, dialed when needed and again after it ended (backoff 1 → 10 s) |
| `backend` | `DirectBackend` (`ScreenBackend`): `/status`, `/focus`, `/frame`, `/clipboard*`, `/events` as RPC; control as `control.take` / `release` |
| `screen-link` | `DirectScreenLink`: the page's media way, one stable object over the connection's sessions |
| `events` | `MacEvents`: the Mac's `/events` (NDJSON) as the pages' events, shared by every subscriber, reconnecting |
| `mapping` | the Mac's answers in the pages' shapes (`statusFromMac`, `clipboardFromMac`, `eventFromMacLine`) |
| `signal` | `relaySignal(relay, fingerprint)`, `relayTurn(relay, fingerprint)` (the relay's TURN servers before each dial; `turn: false` turns it off), `fallbackSignal(paths, fingerprint)` / `pathsTurn` / `signalPaths(signals, relay)` (the given signaling servers first, then the Mac's relay: docs/RELAY.md「信令服务」; `DirectWeb`'s `signals` option, default `DEFAULT_SIGNALS`: none), `DEFAULT_ICE_SERVERS` (none: no STUN server is built in) |
| `errors` | `DirectError` (`kind`: `unpaired` / `offline` / `unreachable` / `busy` / `verification` / `unsupported` / `pairing`) |

## Quick start

```ts
import { DirectWeb, parsePairingLink } from "@yoyocontrol/direct-web";
import "@yoyocontrol/screen-ui"; // <yoyo-screen>, <yoyo-clipboard>

const direct = new DirectWeb({ app: { name: "My Web App", version: "1.0" } });

// pairing: the Mac's pairing window (Browser) shows https://yoyocontrol.com/app/pair#v=1&id=…&n=…&fp=…&c=…
const link = parsePairingLink(location.hash);
history.replaceState(null, "", location.pathname);   // the one-time code doesn't stay in the address
const mac = await direct.pair(link);                  // saved in IndexedDB

// the Screen page
const [first] = await direct.macs();
const screen = document.querySelector("yoyo-screen")!;
screen.host = { deviceId: (await direct.identity()).deviceId, computerName: first.name, onClose: () => history.back() };
screen.backend = await direct.backend(first, () => alert(`${first.name} no longer knows this browser`));
```

`host.deviceId` must be the identity's `deviceId`: it is the device the Mac knows (the page tells "you have control"
from "another device has it" by it).

## Pairing over the link

`pair(link)` dials the Mac with `hello.credential = "Pair <code>"` (no media layer). The Mac checks the code exactly as
for a phone (one live code, one use, 5 minutes, 10 wrong tries, 32 devices), binds the new device token to this
browser's DTLS certificate and hands it back in `welcome.principal.token` (docs/LINK.md「配对」, docs/REMOTE.md「配对」).
The Mac is stored as `{ id, name, fingerprint, token, relay, pairedAt, platform }`; later sessions say
`Bearer <token>`.

Failures are `DirectError`s: `pairing` (wrong / used / expired code, no code shown), `busy` (32 devices, too many
tries), `offline` (the Mac isn't at the relay: asleep, remote access or the relay off), `unreachable`, `verification`
(the answer isn't from the Mac in the link: never retried), `unsupported` (no WebRTC / WebCrypto; needs a secure
context).

## Identity

The DTLS certificate is this browser's key to every Mac (the Mac binds the token to `dtls-sha256:<its fingerprint>`,
link-web's `clientKeyOf`). It lives in link-web's certificate store — by default the same IndexedDB record every
link-web dial uses (`indexedDbCertificateStore()`, database `yoyocontrol-link`), or `DirectWebOptions.certificateStore`
— and is made there once (ECDSA P-256, a year; a new one a day before it expires, and the Macs then answer `unpaired`
until the browser pairs again). The device id (a UUID) is kept in direct-web's store. A certificate an earlier build
kept in direct-web's own record moves to the certificate store on first use, so their pairings stay valid. Clearing the
site's data means pairing again.

## Errors and the pages

`DirectError` is a screen-web `RequestError`, so the pages read its `status`: 401 `unpaired` (the backend also calls
`onUnpaired`), 523 `offline` and 522 `unreachable` (the statuses screen-ui already treats as "the way is down": the
page shows it is reconnecting and tries again), 429 `busy`, 495 `verification`, 501 `unsupported`, 403 `pairing`.
`DirectWebOptions.messages` puts your words (your language) on each kind, plus `permissions` (what "Request
permissions" answers: a browser can't make the Mac show its prompts).

## What a browser can't do (yet)

- Send files to the Mac's clipboard (`sendsClipboardFiles` is false: text only), as a paired iPhone.
- Reach a Linux server: it has no pairing over the link and no relay signaling yet (docs/REMOTE.md「Linux 服务端」).
- TURN: when neither side can reach the other directly (both behind symmetric NATs), the dial fails `unreachable`.

## Install

Private for now: published as a git tag (`scripts/git-dist.sh direct-web <version>`):

```json
"@yoyocontrol/direct-web": "git+https://github.com/yoyocontrol/yoyo-control.git#direct-web-v0.1.0"
```

It needs `@yoyocontrol/link-web` (≥ 0.1.1) and `@yoyocontrol/screen-web` (≥ 0.3); `@yoyocontrol/screen-ui` is a peer
(its types).

## Develop

```sh
npm -w packages/direct-web test        # node --test: pairing links, signaling, errors, the connection, the backend, the media way, pairing
npm -w packages/direct-web run build
```

The tests use a fake session and a fake screen link; the web app's `test/e2e.mjs` runs it against a real Mac
listener in Chrome.
