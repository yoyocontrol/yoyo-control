# @yoyocontrol/remote

What a screen server needs beside its **uu Link listener** (`docs/LINK.md`) to be reached the way Yoyo Control's Mac is
(`docs/REMOTE.md`): the **identity key** phones and browsers pin, this host's **addresses**, the **home router's port
mapping** with overrides for a container, and two entries: the **signaling client** (`@yoyocontrol/remote/signal`,
`docs/RELAY.md`) and Yoyo Control's **standard pairing** (`@yoyocontrol/remote/devices`). Node ≥ 22, ESM, typed, no
dependencies (the port mapper, `@yoyocontrol/portmap`, is bundled in `dist/portmap`).

Until 0.2.0 this package also had a TLS listener for phones (`Door`), a per-source guard and the relay's data path:
remote access is uu Link only now (the link core has its own guard).

```js
import { loadOrCreateIdentity, interfaceAddresses, PortMapping, nodeNetwork } from "@yoyocontrol/remote";
import { SignalClient } from "@yoyocontrol/remote/signal";
import { DeviceStore, pairingLink } from "@yoyocontrol/remote/devices";

const identity = loadOrCreateIdentity(home);                     // tls-key.der made there (0700 / 0600)
const devices = new DeviceStore(`${home}/devices.json`);
// the link listener signs its binding with identity.key; in its authenticate: "Pair <code>" → devices.pair(code, id,
// name) then devices.authenticateLink(token, clientKey); "Bearer <token>" → devices.authenticateLink(token, clientKey)
const signal = new SignalClient({ identity });
signal.setLink({ id, key, sig, relays, direct });                // the binding, as the listener publishes it
signal.start();
const map = new PortMapping({ internalPort: 47820, protocol: "udp", network: nodeNetwork(), onChange: (s) => … });
const { code } = devices.startPairing();                         // show it as a QR code / print it
console.log(pairingLink({ serverId, name: "My box", fingerprint: identity.keyFingerprint, code,
                          link: { id, key, sig, port: 47820 }, addresses: interfaceAddresses() }));
```

## Identity, addresses, port mapping

- `loadOrCreateIdentity(dir)`: an EC P-256 key in `dir` (0700; `tls-key.der` = X9.63 private bytes, 0600), made when
  missing. `keyFingerprint` = `"sha256:" + hex(SHA-256(04 ‖ X ‖ Y))` (what a phone pins, the same as the Mac's);
  `key` (Node's), `publicKey` (X9.63). `x963Private` / `x963Public` / `keyFromX963`, `writePrivate(path, data)` (0600
  through a temporary file).
- `interfaceAddresses()`: this host's IPv4 addresses but loopback and link-local; `parseEndpoint("ip[:port]", port)`.
- `PortMapping` / `nodeNetwork` (re-exported from `@yoyocontrol/portmap`: PCP, NAT-PMP, UPnP IGD) and
  `overrideNetwork(base, { gateway, internalClient, upnpLocation })` for a listener behind another NAT (a container's
  published port: the router forwards to the host, its SSDP answers can't come back).

## Signaling client (`@yoyocontrol/remote/signal`)

`new SignalClient({ identity, url?, log? })` keeps the server registered in its room at the signaling server
(`signalUrl()`: `url`, else `YOYO_SIGNAL_URL`; none is built in — without one the constructor throws): `/v1/mac/<room>`, the room being
`relayRoom(keyFingerprint)` (the fingerprint's 64 hex digits). It answers the challenge with `relayHello` (ECDSA P-256,
raw r ‖ s over `"yoyocontrol-relay-v1:" + nonce`), pings every 30 s (no pong for 45 s more = a drop), reconnects 1 s →
60 s, and sends the link binding (`setLink`) after `ready` and whenever it changes: phones and browsers ask the room
for it (`GET /v1/candidates/<room>`). `registered`, `"change"` events, `stop()`.

## Pairing (`@yoyocontrol/remote/devices`)

`new DeviceStore(path)`: `devices.json` (0600) of `{ id, name, pairedAt, lastSeenAt?, tokenHash, linkKey? }` (SHA-256;
tokens are 32 random bytes, base64url, shown once). `startPairing()` → a one-time code (128 bits, 5 min; 10 wrong tries
in a row end it), `stopPairing()`, `pair(code, id, name)` (same `id` again replaces its token; at most 32 devices),
`authenticateLink(token, clientKey)` (binds the token to the first link key it comes with; another key is refused until
the device pairs again), `authenticate(token)`, `remove(id)`, `list`, `onChange`. `pairingLink({ serverId, name,
fingerprint, code, link, addresses? })` → `yoyocontrol://pair?v=2&id=&n=&fp=&l=&lk=&ls=[&lp=][&a=]&c=`, the format the
Mac's QR code uses.

## Development

```sh
npm -w packages/remote test        # identity, signal (fake WebSocket), devices
scripts/git-dist.sh remote 0.2.0   # publish (bump the version first); builds portmap and bundles it into dist/portmap
```
