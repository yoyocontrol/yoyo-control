# @yoyocontrol/screen-ui

The Screen page and the Clipboard page of a Yoyo Control computer as framework-free Web Components: `<yoyo-screen>`
and `<yoyo-clipboard>`, plus a preview-row model (`ScreenPreview`) and a ready-made routing (`Connector`). The UX is
the iOS kit's (`ios/YoyoKit/Sources/YoyoScreen`, `YoyoClipboard`, `YoyoConnect`); the media engine is
[`@yoyocontrol/screen-web`](../screen-web) (stream, H.264 on WebCodecs, acks, smooth playout, sound, input).

What the page does:

- the live picture, zoomable (pinch, ⌃-wheel on a desktop; the shown part follows the pointer; a double tap fits);
  a dimmed still with why while it reconnects; Retry when a display can't be shown; the Screen Recording and
  Accessibility permission notes with "Request permissions";
- who controls: in control a badge ("You have control"); not in control a pill with an explicit button — "View only ·
  Take Control" (nobody holds it), "Agent is using the screen · Take Over", "X is controlling · Take Over" (another
  device: only this button takes it) — also in full screen, where the button leaves full screen into control
  (`controlPill`; a phone turned to landscape and a computer without Accessibility show the badge alone); "X took
  over" with a haptic. The page opens as a viewer and otherwise takes the screen only at a real input — the first
  touch on the trackpad, a click or scroll on the picture (a tap or drag in touch mode), the keyboard button, a key or
  typed text, a paste into the computer — over an agent too; opening, zooming or panning the picture, full screen and
  turning the phone never take it (`controlAnswer`; the pad says "Touch to take control.");
- touch devices: the **trackpad** under the picture (pointer follows the finger with acceleration and tremor
  smoothing, tap / double tap / two-finger tap, hold-to-drag, tap-to-drag, three-finger drag with drag lock, edge
  move, two-finger scroll with phases and momentum) or **touch** mode (tap where you click), switched on the bar, each
  with its gestures card that opens by itself the first time; the **liquid-drop loupe** over the pointer (WebGL2;
  a plain magnifier without it or with Reduce Transparency; no wobble with Reduce Motion); a three-finger tap shows
  the stats line;
- mouse and keyboard devices: click, double-click, right-click, drag, wheel and type on the picture itself;
- the soft keyboard with a key bar (sticky ⌘ ⇧ ⌥ ⌃, Esc, Tab, arrows, Paste on Mac / Copy from Mac — a long press on
  Paste offers Photos… / Files… —, hide); it comes up by itself when a click focuses a text field (`focus`); IME
  composition sends committed text only;
- the clipboard: a menu (Paste on Mac, Photos…, Files…, Copy from Mac, Open clipboard) with a dot for news, a hint
  capsule when the computer copies something, the Clipboard sheet;
- the sound toggle (remembered), the display menu, full screen (a phone: view only like a video, also when turned
  to landscape; a desktop: keeps control); hidden pages / the back-forward cache give control back and close the stream.

## Quick start

```html
<yoyo-screen style="position: fixed; inset: 0"></yoyo-screen>
<script type="module">
  import "@yoyocontrol/screen-ui"; // registers <yoyo-screen> and <yoyo-clipboard>
  const screen = document.querySelector("yoyo-screen");
  screen.host = { language: "en", onClose: () => history.back() };
  screen.backend = myBackend; // a ScreenBackend, below
</script>
```

The element fills its box; give it one (it handles safe areas itself with `viewport-fit=cover`).

## A backend

A `ScreenBackend` is how the page reaches one computer. Required: `cacheScope`, `status()`, `transport(route)`; the
rest are optional (input and control default to `POST /input` / `POST /control` on the transport; no `clipboard`
hides the clipboard, no `focus` keeps the keyboard from coming up by itself).

```ts
import type { ScreenBackend } from "@yoyocontrol/screen-ui";
import { requestError } from "@yoyocontrol/screen-web";

const api = (path: string, init: RequestInit = {}) =>
  fetch(`/api/computer${path}`, { credentials: "same-origin", ...init });

const backend: ScreenBackend = {
  cacheScope: "my-mac",
  async status() {
    const res = await api("/screen");
    if (!res.ok) throw await requestError(res);
    return res.json();
  },
  // /stream, /stream/ack, /audio, /frame, /input, /control: the page asks, the transport maps
  transport: () => ({ fetch: (path, init) => api(path, init) }),
  async focus() {
    const res = await api("/screen/focus");
    if (!res.ok) throw await requestError(res);
    return res.json();
  },
  async clipboard() {
    const res = await api("/clipboard");
    if (!res.ok) throw await requestError(res);
    return res.json();
  },
  async putClipboard(put) {
    const res = await api("/clipboard", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(put) });
    if (!res.ok) throw await requestError(res);
    return res.json();
  },
  events() {
    // your account's event stream, filtered to screen.control / screen.state / clipboard.changed (wire JSON)
    return myEventStream();
  },
};
```

Errors are `RequestError`s (screen-web): the page reads `status` (401, 409 with `code: "controlled-elsewhere"`…).
`ScreenHost.handleError` sees every error first (return true to handle it, e.g. sign in again on 401).

### More than one way: `ScreenRouting` and `Connector`

A backend with a shortcut next to a way that always works returns a `ScreenRouting` from `makeRouting()`; the page
asks it which way a stream goes, waits up to `decisionWaitMs` for a decision, moves the stream and the sound when the
way changes and reports failures. `Connector` is the ready-made one (the iOS kit's YoyoConnect): you give it the
ways' fallback and a `ConnectSource` (candidates, a probe, release, `ended` for a link session):

```ts
import { candidate, Connector, ConnectWays } from "@yoyocontrol/screen-ui";

const tunnel = candidate({ kind: "tunnel", id: "tunnel" });
makeRouting() {
  const ways = new ConnectWays(tunnel, null, [tunnel]);
  const c = new Connector(ways, {
    candidates: async () => ({ candidates: [candidate({ kind: "link", id: "link" })], fresh: true }),
    probe: async (cand, signal) => ({ t: "reached", link: await dialMyLink(signal) }),
    release: (link) => link?.close(),
    ended: (link) => link.closed.then(() => true),
  });
  c.linkPossible = true;
  return c;
}
```

`screenLink(route)` then returns the `ScreenLink` for the link's route — screen-web's interface;
[`@yoyocontrol/link-web`](../link-web)'s `linkScreen(session)` makes one from a uu Link session over WebRTC. The
page's stream (`video.open`, each picture's decoder verdict back as `frameDecoded`), sound (`audio.open`), pointer,
input (straight into the link's media layer) and control (`control.take` / `control.release`) then go over it; the
playout report rides on it every 2 s. Return the same object while the session lasts. `demo/link-way.js`
(`withLinkWay(httpBackend, { signal, fingerprint, credential })`) is a complete two-way backend: link-web dialing
through a signaling URL, next to the backend's HTTP way.

### What the page measures

The stats line (three-finger tap, `toggleStats()`) is screen-web's `statsLines`, what the iOS app shows: codec, fps,
KB/s, decode ms, the way (`link lan`, or the route's `label`), the connection; the playout (pace, gaps, arrival
gaps, hitches, stalls, buffer, jitter, cap, drops) with a latency estimate; the link's own `link:` numbers or the
server's network grade; the sound (depth, buffer, underruns, drops, kbps). The playout report the computer gets
carries a `NetSampler`'s `net` (route, `navigator.connection` where the browser has it, input round trips over HTTP,
failures, bytes) and the sound's report; A/V sync (`AVSyncDriver`) runs while the sound plays (not for a display
whose `kind` is `virtual`).

## The host

```ts
screen.host = {
  language: "zh-Hans",                 // or "en"; default: the browser's
  strings: { takeOver: "接手" },        // any string by key (src/strings.ts), in the language in use
  theme: { accent: "#0a84ff" },        // --yoyo-<name>
  colorScheme: null,                   // "light" | "dark" | null (the system's)
  agentName: "Claude",                 // "Claude is using the screen", "Copied by Claude"
  handleError: (e) => false,
  toast: undefined,                    // your own notices instead of the page's toast
  preferencesNamespace: "Yoyo",        // localStorage keys: <ns>Audio, <ns>DeviceId, <ns>TouchMode, <ns>GestureCard2Shown…
  deviceId: undefined,                 // default: a random id kept in <ns>DeviceId
  deviceName: undefined,               // default: "Chrome on Mac"
  onClose: () => history.back(),       // shows the close button (or set the `closable` attribute)
};
```

### Theme variables

Set on the element (or through `host.theme` without the prefix). Light and dark defaults are built in.

| variable | what |
| --- | --- |
| `--yoyo-font`, `--yoyo-mono` | the text and the stats line's fonts |
| `--yoyo-background` | the page behind everything |
| `--yoyo-picture-background` | behind the picture before the first frame |
| `--yoyo-text`, `--yoyo-text-secondary`, `--yoyo-text-tertiary` | text |
| `--yoyo-accent`, `--yoyo-on-accent` | buttons, the loupe's armed tint, icons in cards; text on it |
| `--yoyo-success`, `--yoyo-danger` | "You have control"; errors |
| `--yoyo-glass`, `--yoyo-glass-solid`, `--yoyo-glass-border`, `--yoyo-glass-shadow`, `--yoyo-glass-blur` | the glass buttons, badges and pills (solid with Reduce Transparency) |
| `--yoyo-pad`, `--yoyo-pad-border` | the trackpad surface |
| `--yoyo-sheet`, `--yoyo-sheet-grouped`, `--yoyo-separator`, `--yoyo-scrim` | sheets and menus |
| `--yoyo-key`, `--yoyo-key-bar` | the key bar over the soft keyboard |
| `--yoyo-radius` | the large corner radius |

### Strings

English and Simplified Chinese are built in (`STRINGS`, the iOS kit's wording; "iPhone" there is "this device"
here). Keys ending in `Mac` have an `Other` twin for a computer that isn't a Mac (a Linux desktop says "Desktop",
"Paste on Computer"); which one shows follows the status's `platform`.

## Events

| event | `detail` |
| --- | --- |
| `yoyo-close` | — (the close button) |
| `yoyo-control` | `{ controller, mine }` after every render |
| `yoyo-status` | the `ScreenStatus` after every answer |
| `yoyo-toast` (from `<yoyo-clipboard>`) | the text, when the host has no `toast`; `preventDefault()` to show it yourself |

Methods: `toggleStats()`, `showGestures()`.

## `<yoyo-clipboard>`

```ts
const page = document.createElement("yoyo-clipboard");
page.host = host;
page.computer = "mac";      // or "linux"…
page.backend = backend;     // needs clipboard(); putClipboard / clipboardImage / clipboardFile when you have them
```

Files dropped on it or pasted into it go to the computer (with `sendsClipboardFiles`).

## `ScreenPreview`

A list row's model: `state` (`live` with who controls, `asleep`, `needsPermission`, `unavailable`, `action`,
`absent`), `image` (an object URL of the main display, every 5 s while shown), `line()`.

```ts
const preview = new ScreenPreview(backend, host);
preview.start(() => drawRow(preview.state, preview.image));
// …
preview.stop();
```

## Demo

```sh
npm install                                   # at the repo root
npm -w packages/screen-web run build
npm -w packages/screen-ui run build
node packages/screen-ui/demo/serve.mjs        # http://localhost:8790/
```

An in-memory computer (`demo/fake-backend.js`) draws a desktop, encodes it with WebCodecs and serves it as the
stream's parts. Query: `?lang=zh`, `?scheme=dark`, `?state=agent|viewer|unavailable|permission`, `?clipboard=1`,
`?stats=1`, `?card=1`. Open it on a phone on the same network for the touch gestures.

With a uu Link way next to it (`demo/link-way.js`; build `packages/link-web` too):

```sh
link/target/release/uu-link-probe serve-rtc --screen-clip <clip>   # prints fingerprint and signal URL
# http://localhost:8790/?stats=1&link=http://127.0.0.1:47830/rtc&fp=<fingerprint>
```

`--screen-clip` is a looped H.264 clip (format in `link/tools/probe/src/main.rs`; the end-to-end test makes one with
the browser's encoder). Kill the probe and the page falls back to the in-memory way; start it again and it comes back.

## Develop

```sh
npm -w packages/screen-ui test
npm -w packages/screen-ui run typecheck
npm -w packages/screen-ui run e2e      # headless Chrome: <yoyo-screen>, the Connector, link-web ↔ uu-link-probe serve-rtc
npm -w packages/screen-ui run e2e:control   # headless Chrome on the demo: who takes the screen (no take on open, the pill's button, full screen, first input)
```

The end-to-end test (`test/e2e/run.mjs`) mounts `<yoyo-screen>` with the demo's two-way backend, checks the page goes
on the link and its pictures decode (real H.264, `frameDecoded` verdicts, the stats line), kills the probe and checks
the page plays on the HTTP way, starts the probe again (same identity) and checks it comes back to the link. It needs
`cargo build --release -p uu-link-probe` in `link/`, the `.wasm` (`npm -w packages/link-web run wasm`) and Chrome.

## Install

Private for now: published as a git tag (`scripts/git-dist.sh screen-ui <version>` → branch `dist/screen-ui`, tag
`screen-ui-v<version>`). Its dependency on `@yoyocontrol/screen-web` points at screen-web's tag in the dist; add
`@yoyocontrol/link-web` yourself when a backend has a link way:

```json
"@yoyocontrol/screen-ui": "git+https://github.com/yoyocontrol/yoyo-control.git#screen-ui-v0.1.0"
```

ESM only, typed. Importing the package registers the two elements (its one side effect); `defineElements({ screen,
clipboard })` picks other tag names.

## Not yet

- A link that dies without a word (the computer gone, the network cut) is left after the session's 20 s idle timeout
  (or the stream's 15 s stall watchdog, whichever comes first: about 17 s in the end-to-end test), as on iOS; a
  closed session (`bye`) is left at once.
- iOS Safari shows the soft keyboard only from a tap: when a click focuses a text field there, a "Tap to type" pill
  brings it up.
