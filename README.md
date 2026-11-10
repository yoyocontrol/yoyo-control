# @yoyocontrol/screen-web

The web client of a Yoyo Control screen, without UI and without a transport of its own: a page brings its markup
(React or not), its words and how it reaches the server; this package does the rest (`docs/PROTOCOL.md`).

| module | what |
| --- | --- |
| `parts` | the multipart part parser of the stream and the sound (both sets of media type names) |
| `h264` | Annex-B access units → AVCC samples, `avcC`, `avc1.PPCCLL` |
| `hevc` | the same for HEVC: `hvcC` (byte for byte what ffmpeg writes for VideoToolbox's stream), `hvc1.…`; `VideoStream` asks for `hevc,h264` where `VideoDecoder.isConfigSupported` says HEVC decodes in hardware (`hevcDecodable`, `preferredCodecs`), else `h264`; HEVC that fails before its first picture falls back to H.264 for the page |
| `video` | `VideoStream`: the stream on WebCodecs, acks before decoding, key picture requests, smooth playout, a stall watchdog, playout reports; `fetchFrame` |
| `playout` | `Playout`: the jitter buffer (even pace, 100 / 200 ms caps) and its responsive mode while the user interacts; `touchBudgetMs`, `playoutLine` |
| `interaction` | `Interactivity`: a finger / pointer on the picture or an input sent, plus a 600 ms tail; `withInteraction(send, interactivity)` |
| `acks` | `AckSender` (cumulative, up to 4 in flight, retry), `ackOutcome` |
| `cursor` | `CursorModel`: the client-drawn pointer (`cursor=client`), shapes cached by id |
| `audio` | `ScreenAudio`: Opus on WebCodecs into an AudioWorklet ring buffer |
| `input` | `InputQueue` (moves pipelined with `seq`, scrolls merged), `TouchGestures`, `ClickGate`, key / text / wheel mapping, `PASTE_KEY` |
| `control` | `sendInput`, `setControl` |
| `status` | `ConnectionModel` (+ `statsText`), `ReopenPolicy`, `AudioPolicy`, `controlRole`, `hostOf`, `phaseText` with `ScreenStrings` |
| `link` | `ScreenLink`: a media route that carries the screen itself (a uu Link session); `linkStreamQuery` |
| `meter` | `PlayoutMeter`: the playout report's gaps, hitches, stalls, drops, decode time; `roundReport` |
| `net` | `NetSampler` (the report's `net`), `browserNetPath`, `withNetSampler`, `isNetworkFailure`, `parseNetQuality`, `netQualityLine` |
| `stats` | the stats line: `StreamStatsSnapshot`, `statsLines`, `streamLine`, `playoutReportLine`, `latencyEstimate`, `audioStatsLine` |
| `avsync` | `AVSync` (pictures wait for late sound, sound for a slower smooth picture), `AVSyncDriver` |
| `audiobuffer` | the sound's timed jitter buffer: `AudioJitter` (depth), `AudioScheduler` (the AudioWorklet's player) |

## Quick start

```ts
import { ConnectionModel, InputQueue, Interactivity, normalizedPoint, sendInput, VideoStream, type ScreenTransport } from "@yoyocontrol/screen-web";

const transport: ScreenTransport = { fetch: (path, init) => fetch(`/api/screen${path}`, init) };   // your server
const canvas = document.querySelector("canvas")!;
const interactivity = new Interactivity();
const connection = new ConnectionModel();
const video = new VideoStream({ transport, canvas, interactivity }, {
  onPicture: () => connection.picture(performance.now()),
  onCursor: (c) => drawPointer(c),
  onStatus: (s) => connection.status(s, performance.now()),
  onEnd: (info) => console.log("stream ended", info),       // reopen with ReopenPolicy
});
void video.run();
const input = new InputQueue((i) => sendInput(transport, i), (e) => console.warn(e));
canvas.addEventListener("click", (e) => input.input({ type: "click", ...normalizedPoint(e.clientX, e.clientY, canvas.getBoundingClientRect()) }));
```

A whole page (trackpad, loupe, key bar, clipboard, control) is [`@yoyocontrol/screen-ui`](../screen-ui)'s
`<yoyo-screen>`, built on this package.

## The transport

Everything that talks to the server takes a `ScreenTransport` — one `fetch(path, init)`:

```ts
import { VideoStream, ScreenAudio, fetchFrame, sendInput, type ScreenTransport } from "@yoyocontrol/screen-web";

const transport: ScreenTransport = {
  fetch: (path, init) => fetch(`/my-proxy${path}`, { ...init, credentials: "same-origin" }),
};
const video = new VideoStream({ transport, canvas }, { onPicture, onCursor, onStatus, onEnd });
void video.run();
```

The client asks for `POST /stream` (JSON body = the stream's parameters), `POST /stream/ack`, `POST /audio`,
`GET /frame?…`, `POST /input`, `POST /control`; the transport maps them onto its server (a prefix, cookies or a
token, a device header, `GET /stream?…` for a server that wants the query). See `src/transport.ts`.

## Smooth and responsive playback

Decoded pictures wait in a small jitter buffer and are drawn at an even pace (docs/PROTOCOL.md「客户端的平滑播放」):
100 ms at most on the LAN (`route: "lan"`), 200 ms elsewhere (`maxDepthMs` to choose). While the user interacts the
depth drops to about one picture interval (≤ 30 ms; none on the LAN) and what waits catches up at once; 600 ms after
the last contact or input it eases back. The page tells it when the user interacts:

```ts
import { Interactivity, InputQueue, VideoStream, playoutLine, sendInput, withInteraction } from "@yoyocontrol/screen-web";

const interactivity = new Interactivity();          // one per screen page: it outlives a stream
const input = new InputQueue(withInteraction((i) => sendInput(transport, i), interactivity), onFailed);
canvas.addEventListener("pointerdown", () => interactivity.down());
for (const e of ["pointerup", "pointercancel"]) canvas.addEventListener(e, () => interactivity.up());
const video = new VideoStream({ transport, canvas, interactivity, route: "tunnel" }, callbacks);
statsLine.textContent = playoutLine(video.playoutState());   // smooth · … · buf 104 ms · depth 96 · …
```

`playout: "arrival"` draws each picture as soon as it is decoded (0.1.x behaviour).

## Media over a link

When the way to the computer is a uu Link session (`@yoyocontrol/link-web`'s `linkScreen(session)`, or any object
implementing `ScreenLink`), the same classes run over it instead of HTTP (docs/LINK.md「会话协议」, the iOS kit's
`YoyoScreenLink`):

```ts
import { InputQueue, linkInputSender, linkSetControl, ScreenAudio, VideoStream, type ScreenLink } from "@yoyocontrol/screen-web";

let link: ScreenLink | null = linkScreen(session);           // null while the way in use is HTTP
const video = new VideoStream({ link, canvas, interactivity }, callbacks);   // video.open, no acks
void video.run();
const audio = new ScreenAudio(transport, onAudioState, { link: () => link });  // audio.open (asked at each open)
const input = new InputQueue(httpSend, onInputFailed, Date.now(), undefined, { link: () => (link ? linkInputSender(link) : null) });
link.setInputErrorHandler(onInputFailed);                  // input.rejected (409 / controlled elsewhere / 401…) and unacked input
await linkSetControl(link, true);                          // control.take; a 409 RequestError as POST /control would give
```

- `VideoStream` with `link`: the stream's parameters go as `video.open`'s query (without `ack`); each picture goes
  straight to the decoder and its verdict back (`decoded(frame, ok)`); a missing key picture or a decoder error asks
  the link for one; the playout report goes on the link every 2 s; the link's `rttMinMs` is the touch budget's source
  and its `isLocalNetwork` picks the LAN caps (unless `route` is given: default `lan` / `direct`). `transport` is not
  needed then. `onOpened(headers)` hears `video.opened`'s headers (`X-Display`…). `video.error` ends the stream with
  its status (401: the credential is gone), `video.closed` as an empty end, the session's end as a failure.
- `ScreenAudio`'s third argument (`ScreenAudioOptions`) is additive: `link: () => ScreenLink | null` (the sound opens
  on the link when it gives one), `lan: () => boolean` (the buffer's lower floor; default the link's).
- `InputQueue`'s fifth argument (`InputQueueOptions`): in link mode nothing waits for an answer; what comes in one turn
  is merged (`mergeLinkInput`: moves into the latest, a scroll gesture's deltas) and sent at the end of it, moves with
  their `seq`. A send that throws (429) goes to `failed` at once.

## Stats line

The three-finger stats line of the iOS app, as data (numbers, units and protocol codes only — nothing to translate):

```ts
import { statsLines } from "@yoyocontrol/screen-web";
const lines = statsLines({
  stream: video.stats(),                     // the window since the previous call: codec, fps, KB/s, decode, playout, grade
  way: link ? link.pathLabel : "tunnel",     // the host's name for its HTTP route
  connection: connectionModel.statsText(performance.now()),
  linkLine: link?.statsLine,                 // a link's own `link:` numbers stand in for the server's grade
  audio: soundOn ? audio.stats() : null,
});
// ["h264 · 60 fps · 412 KB/s · 2.1 ms · link lan · live ready",
//  "smooth · 60 Hz · gap 17/18 · arr 16/24 · hitch 0.0/s · stall 0.0/0.0/s · buf 28 ms · jit 24 · cap 100 · drop 0.5/s · ~62 ms",
//  "lan wifi rtt 0.4/1.2/2.0 ms loss 0.0 % …",
//  "audio 120 ms (buf 118) · 0 underruns · 0 drops · 96 kbps"]
```

The playout report sent to the computer (every 2 s, on an ack or on the link) carries the same meter's fields
(`stall150PerSec` / `stall300PerSec` are new), `net` from a `NetSampler` when the page gives one (`VideoOptions.net`;
share it with the input: `withNetSampler(send, net, () => route)`, and set `net.path = browserNetPath()` on
`navigator.connection`'s `change` where the browser has it) and `audio` (`VideoOptions.audioReport: () =>
audio.report()`).

## A/V sync

`ScreenAudio` plays each packet at its slot (`X-Audio-Time` + the measured base delay + a depth that follows the path's
jitter: 80 ms floor on the LAN, 120 ms elsewhere, raised after an underrun), so its delay is known; `VideoStream`'s
smooth playout knows its own. `AVSyncDriver` lines them up a few times a second (the iOS kit's `ScreenAVSync`): while
watching, pictures wait for a later sound (`syncFloor`, at most 300 ms, ramped), and the sound waits for a slower smooth
picture; never while the user interacts.

```ts
import { AVSyncDriver } from "@yoyocontrol/screen-web";
const sync = new AVSyncDriver(audio, () => (realDisplay ? currentVideo : null));
sync.start();   // with the sound; sync.stop() when it goes off
```

Only a real display's pictures carry same-instant times (a virtual display's don't): return null from the video getter
for those.

## Words

`phaseText(phase, host, strings)` takes the page's `ScreenStrings` (English by default: `englishStrings`). Nothing
else in the package shows text; error messages (`RequestError`, a stream's `onEnd` `error`) are the server's or
technical English.

## Install

Private for now: published as a git tag (`scripts/git-dist.sh screen-web <version>` → branch `dist/screen-web`,
tag `screen-web-v<version>`):

```json
"@yoyocontrol/screen-web": "git+https://github.com/yoyocontrol/yoyo-control.git#screen-web-v0.3.0"
```

ESM only, typed (`dist/*.d.ts`), no dependencies, `sideEffects: false`.

## Develop

```sh
npm install                   # at the repo root (workspaces)
npm -w packages/screen-web test
npm -w packages/screen-web run build
```
