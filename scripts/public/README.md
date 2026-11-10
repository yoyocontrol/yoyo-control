# Yoyo Control — open-source kits and servers

See and drive a computer from a phone or a browser: the picture, sound, pointer / keyboard and clipboard of a Mac,
a Windows PC or a Linux desktop, over a fast UDP transport of its own (uu Link: QUIC + a low-latency media layer).

This repository is the open-source part of Yoyo Control: the libraries and servers, licensed Apache-2.0. Every
setup built from them is **your own**: nothing here has a service address built in — no relay, no signaling server, no
update check, no web app of anyone's. Run your own (an [iroh relay](https://github.com/n0-computer/iroh), any STUN /
TURN server) and pass their addresses in, or use the local network / your own VPN (Tailscale, WireGuard) and need none.

Yoyo Control the product (the iPhone and menu bar apps, its paywall and its own servers) is built from these parts
and is not in this repository.

## What is here

| Path | What |
| --- | --- |
| `mac/` | The Mac's screen service as a Swift library (`YoyoServer`: ScreenCaptureKit capture, CGEvent input, Core Audio → Opus, the clipboard, an HTTP API on a unix socket, the uu Link listener) and `yoyo-server`, the service on its own (`mac/README.md`) |
| `linux/` | The Linux server (headless or a real X11 session): the same HTTP API and uu Link, Node + small C helpers (`linux/README.md`) |
| `windows/` | The Windows server: the same server code with Windows helpers (DXGI capture, SendInput, WASAPI loopback, the clipboard), run in the signed-in user's desktop session (`windows/README.md`) |
| `ios/YoyoKit/` | The iOS kits (root `Package.swift`): YoyoCore, YoyoScreen (the Screen page), YoyoClipboard, YoyoConnect, YoyoDirect, YoyoLink / YoyoLinkClient (`ios/README.md`) |
| `packages/` | TypeScript kits: `@yoyocontrol/local`, `remote`, `link`, `link-web`, `screen-web`, `screen-ui`, `direct-web`, `portmap` |
| `link/` | uu Link's Rust core (iroh / QUIC, the media layer, WebRTC for browsers), with its Swift, Node and WebAssembly bindings |
| `docs/` | The protocol (`PROTOCOL.md`), the local API (`LOCAL-API.md`), remote access (`REMOTE.md`), uu Link (`LINK.md`), relays and signaling (`RELAY.md`), the architecture (`ARCHITECTURE.md`). Mostly in Chinese |

## Use it

- **Swift** (iOS kits, `YoyoServer`): `.package(url: "https://github.com/yoyocontrol/yoyo-control.git", revision: "<tag's commit>")`
  — tags `kit-vX.Y.Z`; the uu Link binary comes from this repository's release `link-apple-vX.Y.Z`.
- **npm**: `"@yoyocontrol/<kit>": "git+https://github.com/yoyocontrol/yoyo-control.git#<kit>-vX.Y.Z"` (built packages on
  `dist/<kit>` tags; no registry needed).
- **Linux / Windows servers**: the releases `linux-vX.Y.Z` / `windows-vX.Y.Z` of this repository.

Services, all optional, all yours: `YOYO_LINK_RELAYS` (iroh relays, `?token=` an access token), `YOYO_SIGNAL_URL`
(a signaling server, `docs/RELAY.md`), `YOYO_WEBAPP_URL` (a web app for browser pairing links), or the matching
options of each kit. Unset means none: the local network and direct paths (including a router's port mapping) still work.

## Build and test

```sh
cd mac && swift build && swift test                 # macOS (outside any sandbox: SwiftPM sandboxes itself)
cd linux && node --test test/                       # the Linux / Windows server (fake helpers: runs anywhere)
npm ci && npm test                                  # the TypeScript kits (link-web needs Rust + wasm-pack for its build)
scripts/link-apple.sh build                         # the uu Link xcframework from source (else the release's is used)
```

## License

Apache License 2.0 (`LICENSE`, `NOTICE`).
