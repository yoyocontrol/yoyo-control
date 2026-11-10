# @yoyocontrol/local

A Node client of Yoyo Control's **local API** (`docs/LOCAL-API.md`): for programs on the same machine — automation
tools, other apps, scripts, a server that relays the screen to its own clients. Node ≥ 22, ESM, typed.

```js
import { LocalClient, ClipboardClient, appSocketPath, DOWNLOAD_URL } from "@yoyocontrol/local";

const yoyo = new LocalClient({
  socketPath: "/tmp/my-child.sock",              // only used for a child service (development)
  childPath: null,                               // never spawn one
  app: { socketPath: appSocketPath(), downloadUrl: DOWNLOAD_URL },
  onState: (states, console) => {},              // /events "state", deduplicated
  onAbort: (reason) => {},                       // the user pressed Esc during automation
});

const status = await yoyo.status();              // GET /status (finds / opens the app first)
yoyo.setAutomation(true, "My Tool");             // the border + "press Esc to stop"
const { jpeg } = await yoyo.frame({ maxWidth: 1280, visible: ["com.apple.TextEdit"], hide: "com.example.mine*" });
await yoyo.input({ type: "click", x: 0.5, y: 0.5 });
yoyo.setAutomation(false);
const clip = await new ClipboardClient(yoyo).read();
yoyo.stop();
```

## What it does

- **Finding the server** (`LocalClient`), in the order the options allow:
  - `remote`: a server elsewhere over TCP with a bearer token (`connect(mode)` gives — and starts — its endpoint;
    `known` / `restart` / `rekey`, see `remoteFailure`); its `/status` must name `remote.app`.
  - `app`: the fixed socket answers as `YoyoControl` with an `api` in range → used as it is; else an installed
    `Yoyo Control.app` is opened in the background (`open -g -j`) and waited for (10 s); an app that never answers
    is not opened again until its bundle changes (`appStamp`).
  - a child service (`childPath` / `childCandidates`): `--socket <socketPath> --exit-on-stdin-eof`, respawned on the
    next use, exit 75 without backoff, other exits 1 s → 30 s.
  - nothing: a 503 `LocalError` with `extra.install = { reason: "not-installed" | "outdated", url, version? }`.
- **Requests**: HTTP/1.1 over the unix socket, or TCP + `Authorization: Bearer`; a connection failure looks for the
  server again once; `request()` (raw, body streaming) and `json()`. Every failure is a `LocalError` with the HTTP
  status a proxy can answer with (`answerError`: 400 / 403 / 404 / 409 / 413 / 503 as they are, else 502).
- **`/events`**: one subscription while a server is in use, reconnected 1 s → 10 s; `state` lines deduplicated
  (ignoring `since`) → `onState`; `clipboard` → `onClipboard`; `abort` → `onAbort` (the automation indicator is off);
  any other typed line → `onEvent`. A server that goes away turns the last states into
  `reconnecting / helper-restart`; one that can't be started into `unavailable / helper-down` (with `retryAt`).
- **The API**: `status()`, `frame()`, `windows()`, `hit()`, `appWindows()`, `appScreenshot()`, `appAx()`,
  `stream()` / `audio()` (the response body to pipe; the viewer's `Accept` is passed on so it gets the media type
  names it reads), `input()`, `ack()`, `focus()`, `requestPermissions()`, `setAutomation()` (ordered; an older build
  gets `/agent-control`).
- **Checking what your own clients send** before it reaches the server: `parseInput`, `parseFrameParams`,
  `parseStreamParams`, `parseStreamAck` (400 `LocalError`s), and lenient readers of the answers (`parseWindows`,
  `parseHit`, `parseAppWindows`, `parseAppAx`, `parseFocus`, `parseFeatures`).
- **Clipboard** (`ClipboardClient`): `read()`, `image()`, `file(index)` (streamed, with its name from
  `Content-Disposition`), `writeText()`, `writeFiles()`; `parseClipboardSummary` / `parseClipboardItem`,
  `validateClipboardText`; `ClipboardAnnouncer` deduplicates "changed" by `changeCount` and availability.

Wording: every text a person may see can be replaced (`messages`), and log lines go to `log` (default: the console
with a `[yoyo]` prefix).

## Install

Private for now: published as a git tag (`scripts/git-dist.sh local <version>` → branch `dist/local`, tag
`local-v<version>`):

```json
"@yoyocontrol/local": "git+https://github.com/yoyocontrol/yoyo-control.git#local-v0.1.0"
```

## Develop

```sh
npm install            # at the repo root (workspaces)
npm -w packages/local test
npm -w packages/local run build
```
