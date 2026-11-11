# yoyo-control (Yoyo Control.app)

Lets you (and programs on this Mac) see this Mac's screen, hear its sound and click / type on it. macOS grants Screen Recording and
Accessibility per signed app (TCC), so capture and input live in this app. It runs two ways, both speaking plain
HTTP/1.1 over a unix socket:

- **The app** (no arguments: Finder, `open`, a login item): a menu bar app that keeps the service running on the fixed
  socket `~/Library/Application Support/YoyoControl/screen.sock`, where local clients attach (`../docs/LOCAL-API.md`).
  See「The app」.
- **The service** (`--socket <path>`): the server itself, the app's child (or, for development, a client's: see
  「Running the service yourself」).

Swift Package, macOS 14+. Three targets:

- `YoyoServer` (library, `Sources/YoyoServer/`, no dependencies): capture, input, the HTTP-over-unix-socket server and
  `ServiceHost`, the process around it (the command line, the TCC-responsibility re-launch, signals,
  `--exit-on-stdin-eof`, socket cleanup, exit 75). Public API: `ServiceHost.main(arguments:options:)` /
  `run(_:options:)` / `parse` (see「Embedding the service」), `ScreenService(socketPath:remoteHome:watchInputElsewhere:)`
  with `start()` / `stop()` / `onFatal`, `ScreenPermissions` (preflight / request / System Settings URLs), `ScreenHost`
  (`appName` for error messages, `logName`, `logSink`, `onAudioServiceRestart`, `onAudioDeaf`, `onClipboardReceived`),
  `ServerIdentity` (`/status`'s `app` / `version` / `build` / `api`), `LinkOptions` (the uu Link listener, 「uu Link」),
  `ExternalDisplay` / `ExternalDisplays` (displays whose pictures the embedder supplies, 「External displays」).
  Its target is defined in the repository-root `Package.swift` (a product there, so another package can depend on it
  by git URL); this package uses it from there (`.package(name: "YoyoKit", path: "..")`). With `YoyoLink` in the root
  package (`../scripts/link-apple.sh build`, docs/LINK.md「构建」) it has the link listener, without it not.
- `YoyoApp` (library, `Sources/YoyoApp/`, with Sparkle): the menu bar app: paths, the single-instance lock, the service
  supervisor, the status poll, the menu, the login item, updates.
- `yoyo-control` (executable, `Sources/yoyo-control/`): picks the mode: the menu bar app, or `ServiceHost` with
  `--remote` allowed.

The screen is the console's: the macOS account the service runs as, logged in on the Mac. Pictures come from
ScreenCaptureKit, input goes in as CGEvents (the HID event stream).

## Build

```sh
./build.sh            # build/Yoyo Control.app, signed (see below)
./release.sh 1.0.1    # a release: notarized app and DMG, the appcast, deployed to yoyocontrol.com
```

Run both outside a sandbox (`swift build` sandboxes itself and fails inside another one).

`build.sh` output: `build/Yoyo Control.app` (bundle id `ca.sarria.yoyocontrol.mac`, `LSUIElement`, no Dock icon),
`Sparkle.framework` in `Contents/Frameworks` (without its XPC services: the app is not sandboxed). Signed with the
keychain's Developer ID Application identity, else its Apple Development one (`SIGN_IDENTITY` overrides; ad-hoc only
without either), inside out (Sparkle's `Autoupdate` and `Updater.app`, the framework, the app), with the hardened runtime
and `YoyoControl.entitlements` (audio input: the sound capture reads its tap through an aggregate device's input);
Developer ID adds a secure timestamp. `codesign -dv "build/Yoyo Control.app"` should show
`Identifier=ca.sarria.yoyocontrol.mac` and `flags=0x10000(runtime)`. Switches: `VERSION` / `BUILD_NUMBER`
(`CFBundleShortVersionString` / `CFBundleVersion`, default 1.0 / the time as `yyyyMMddHHmm`), `YOYO_BUNDLE_ID`,
`YOYO_FEED_URL` / `YOYO_ED_KEY` (Sparkle's appcast and public key; `YOYO_FEED_URL=` builds without updates).

`release.sh <version> [notes.html]`: `build.sh` with Developer ID, the app notarized (`notarytool`, the App Store
Connect API key in `~/.config/yoyocontrol/asc.env`) and stapled, then `build/release/YoyoControl-<version>.dmg` (the app
and an Applications link) signed, notarized and stapled; Sparkle's `sign_update` signs it with the EdDSA private key from
`~/.config/yoyocontrol/sparkle-ed25519.key` (`YOYO_ED_KEY_FILE`; exported from the login keychain's item, account
`ca.sarria.yoyocontrol.mac`, which is used without the file but waits on a keychain prompt at the Mac). Without the key
installed copies can't verify updates any more: keep a backup of it. It writes `../web/public/appcast.xml` (only the
newest version, `notes.html` as its description) and `_redirects` (`/download` → the newest DMG), copies the DMG to
`../web/public/download/`, and runs `../web/deploy.sh` (`NO_DEPLOY=1` skips that). Commit the new appcast afterwards.

## Updates

Sparkle 2 (`Updater`): Info.plist's `SUFeedURL` (`https://yoyocontrol.com/appcast.xml`), `SUPublicEDKey`,
`SUEnableAutomaticChecks` (a check a day, no first-run question), `SUAutomaticallyUpdate` (the daily check downloads an
update by itself). Installing quits the app (the service goes with it) and relaunches the new one. A resident app never
quits on its own, and Sparkle's fallback is to install on quit without a relaunch, so an update never waits for that:
one the daily check downloaded installs once the Mac has been quiet for 2 min (no phone connected or being paired, no
automation; `UpdateInstallGate`, log lines `update: …`); Check for Updates… in the menu shows Sparkle's window, and its
Install Update installs as soon as the download is in, with no second "Install and Relaunch" window to close
(`InstallingUserDriver`). Developer ID builds share one designated requirement (bundle id + team), so the TCC grants survive updates.
A build without `SUFeedURL` (`swift build`'s binary) has no updater and no menu item.

## The app

`yoyo-control` with no arguments (or `--app`; LaunchServices' `-psn_…` is ignored) is the menu bar app
(`YoyoApp.run()`, `LSUIElement`: no Dock icon).

- Paths (`AppPaths`): home `~/Library/Application Support/YoyoControl` (0700), socket `<home>/screen.sock` (0600, must
  fit 103 bytes), lock `<home>/app.lock`, log `~/Library/Logs/YoyoControl/yoyo-control.log` (rolled to `.1` past 10 MB at
  launch). `YOYO_HOME` moves all of it (log in `<home>/logs/`): a test copy beside the real one.
- One app per home: an exclusive `flock` on the lock file (it holds the pid); a second app logs who holds it and exits 0.
- The service is its child (`ServiceSupervisor`): this executable with `--socket <home>/screen.sock
  --exit-on-stdin-eof --remote` (`--remote`: paired phones reach it over uu Link, docs/REMOTE.md), stdin a pipe the app holds (the app gone however it goes → EOF → the service exits and removes
  the socket), stdout / stderr into the log. It re-launches itself with TCC responsibility disclaimed, so the grants are
  Yoyo Control.app's even when the app was started from a terminal.
- Restarts (`RestartPolicy`): exit 75 after ≥ 2 s of running → a fresh service at once (see「Sound: deaf helper and
  coreaudiod restarts」); any other end → 1 s, 2 s, 4 s … 60 s, the count cleared by a run of ≥ 60 s or the menu's
  Restart.
- `/status` every 5 s and when the menu opens (`StatusMonitor`). While it says `screenRecording: false`, the service is
  restarted once it has run 15 s (a grant shows only in a new process), the interval doubling to 5 min after each such
  restart (`GrantRefresh`); back to 15 s when the grant appears or the user opens the menu / its permission items.
- The menu: version, state (starting / running / <label> is using this Mac (`automation`) / no screen / stopped, restarting in N s),
  Screen Recording and Accessibility (checked when granted; otherwise opens the System Settings pane), Request
  Permissions… (`POST /permissions/request`, when one is missing), Open at Login (`SMAppService.mainApp`; bundled only),
  remote access (who controls the Mac and Take Back Control, Pair iPhone… — a QR code window never captured,
  `sharingType = .none`, with an iPhone App / Browser switch while `pairing.webUrl` is there: the web app's link as a
  second QR code and Copy Link (marked concealed + transient) —, Paired Devices with Remove, Allow Connections Through the Relay (docs/RELAY.md), Allow Direct Connections from the Internet with its status line (the router's port mapping, docs/REMOTE.md「外网直连」), Allow Remote Access; from `GET /remote`, docs/REMOTE.md),
  Check for Updates… (see「Updates」), Restart Service, Show Log, Quit. English or Chinese by the system's first language. The icon is `display`,
  `iphone.radiowaves.left.and.right` while a paired phone is connected, or a warning triangle while the service doesn't
  answer / has no screen / lacks a permission.
- Login item: a copy in `/Applications` or `~/Applications` registers itself the first time it runs (once: switching it
  off sticks; key `LoginItemOffered` in the app's defaults).
- Quit / SIGTERM: SIGTERM to the service, ≤ 3 s for it to go (then SIGKILL), then exit.

## Running the service yourself

- Path: `Yoyo Control.app/Contents/MacOS/yoyo-control` (the bundled one: the grants are the app's).
- Spawned as `yoyo-control --socket <path> --exit-on-stdin-eof` and restarted with backoff (the app's
  `RestartPolicy`: 1 s doubling to 60 s).
  `--exit-on-stdin-eof` makes it die with its parent. Exit code 75 asks for a
  fresh helper (after a coreaudiod restart, or when the sound watchdog finds the process deaf, see「Sound: deaf helper and
  coreaudiod restarts」): the parent starts one at once, no backoff.
- At startup the helper re-launches itself with TCC responsibility disclaimed
  (`responsibility_spawnattrs_setdisclaim`), so permissions are checked against Yoyo Control.app rather than its parent.
  The outer process only relays SIGTERM/SIGINT and the exit status (set `YOYO_DISCLAIMED=1` to skip this).
- `/status` reports the session (`CGSessionCopyCurrentDictionary`: `kCGSessionLoginDoneKey`); without one it answers
  `ok: false`.

## Embedding the service

Another app can ship its own screen service built from this library, with its own bundle, signature and TCC grants
(nothing of Yoyo Control's runs or is needed). SwiftPM resolves the repository-root `Package.swift`, whose `YoyoServer`
product is this library (macOS only, no Sparkle; the root package's iOS kits are not built for it):

```swift
// Package.swift of the embedding package
dependencies: [
    .package(url: "https://github.com/yoyocontrol/yoyo-control.git", revision: "<commit>"),
],
targets: [
    .executableTarget(name: "my-screen", dependencies: [.product(name: "YoyoServer", package: "yoyocontrol")]),
]
```

```swift
// Sources/my-screen/main.swift
import YoyoServer

ServiceHost.main(options: .init(logName: "my-screen"))
```

`ServiceHost.main` reads `--socket <path> [--exit-on-stdin-eof]` (exit 2 otherwise), re-launches the executable with
TCC responsibility disclaimed, runs the service until SIGTERM / SIGINT / stdin EOF (exit 0), a fatal socket error (1) or
an audio failure only a new process fixes (75: start a fresh one at once), and never returns. `Options`:

- `logName` (default `yoyo-control`): the stderr prefix `<logName>[pid]: …` and the name of the power assertions.
- `appName` (default: the bundle's `CFBundleDisplayName` / `CFBundleName`, else "Yoyo Control"): named in the 403s
  ("… is not granted to <appName>"). The system's permission prompts name the bundle by themselves.
- `allowsRemote` (default false): accept `--remote` (remote access for paired phones, Yoyo Control's own app).
- `watchInputElsewhere` (default true): the input-from-elsewhere tap (「Input from elsewhere」).
- `disclaimedEnvironmentKey` (default `YOYO_DISCLAIMED`): marks the re-launched child.

`ScreenHost`'s hooks (`logSink`, `onClipboardReceived`, …) may be set before the call. The rest is the embedder's: put
the executable in an app bundle (`LSUIElement`; `NSScreenCaptureUsageDescription`, `NSAccessibilityUsageDescription`,
`NSAudioCaptureUsageDescription` in its Info.plist) and sign it with a stable identity, since TCC keys the grants by
bundle id and designated requirement (see「Build」). The `/automation` capsule names whatever `label` the caller
passes; nothing else the service shows names a product.

### External displays

An embedder can serve displays that are not WindowServer's — anything it has pictures of (a device's or a virtual
machine's framebuffer, a canvas it draws). They are displays like the others on the wire: listed in `/status`'s
`displays` (after WindowServer's, `main: false`, the `kind` and `name` the embedder gives), streamed by
`GET /stream?display=<id>` and a link session's `video.open` (the same video loop: codecs, `maxWidth`, `fps`, acks, the
link's rate control and recovery), a still by `GET /frame?display=<id>`.

```swift
let display = ExternalDisplay(id: 4_000_000_001, name: "Device", kind: "virtual", scale: 3)
ExternalDisplays.add(display)        // false: the id is taken (another external display's, or one of WindowServer's)
display.publish(pixelBuffer)         // the display's picture from now on (BGRA or anything VideoToolbox converts)
display.changed()                    // a live surface was drawn into: the same buffer, new content
ExternalDisplays.remove(id: display.id)   // its streams end; the id is unknown again
```

- A display is listed once it has a picture; its size is the buffer's (`width` / `height` in points = pixels /
  `scale`). A stream is at most `maxWidth` wide and never larger than the buffer; its size is fixed while it runs.
- The buffer may be a live surface: each encoded picture is a copy (scaled to the stream's size) taken at that
  moment. Call `changed()` when it was drawn into, or nothing new is sent.
- No Screen Recording, no GUI session: they are served whatever `/status`'s `ok` and `screenRecording` say. A
  `status=1` stream gets one status part, `ready`, with `console: null`.
- They take no input and have no pointer, windows, focus or console: `/input`, `/focus`, `/windows`, `/hit` with their
  id answer 404 `unknown display`; `/frame` takes no `visible=` / `crop=` (400); `cursor=client` sends no cursor parts.

## Permissions

System Settings → Privacy & Security → **Screen & System Audio Recording** and **Accessibility** → add / enable
`Yoyo Control.app`. Or trigger the prompts from the app's Screen page ("Request permissions"), or:

```sh
curl --unix-socket data/screen.sock -X POST http://x/permissions/request
```

Sound (`GET /audio`) asks for a third grant, **System Audio Recording Only** (in the same Screen & System Audio
Recording pane; TCC service `AudioCapture`), the first time a client opens `/audio` (that response's head waits for
the answer).

An unbundled build (`.build/debug/yoyo-control`) is its own TCC identity: its first `/audio` asks again, every Core
Audio call of the process hangs until the prompt goes (measured ~50–90 s), and its taps then read silence. Test sound with `./build.sh`'s Yoyo Control.app (same signing identity = the same grant).

### Sound: deaf helper and coreaudiod restarts

After a coreaudiod restart (`kAudioHardwarePropertyServiceRestarted`) a process's new taps read zeros for other apps,
which only a new process fixes: `yoyo-control` exits with 75 (`ScreenHost.onAudioServiceRestart`, `AudioServiceWatch`)
and its parent (the app) starts a fresh one (the clients reopen their streams); without the hook the
capture is torn down and rebuilt in-process when its clients reopen, which may not bring the sound back.

The same deafness has been seen with no known cause (and after a TCC refusal): every tap of the process reads zeros,
a fresh process hears at once. `AudioDeafWatchdog` (AudioWatchdog.swift): every 2 s, when the capture's last 4 s were
exact zeros while another process of this user ran output, it asks the shared tap check (`AudioTapCheck`: an `afplay`
child plays an inaudible -90 dBFS tone and gets a private tap of its own; `AudioTapCheckCache`: one afplay at a time, a
hearing answer holds 120 s, any other 30 s). Deaf → `yoyo-control` exits 75 (`ScreenHost.onAudioDeaf`), at most once
per 15 min across helpers (stamp `$TMPDIR/yoyo-audio-deaf-<uid>`; a respawn deaf again within that keeps running and
logs: a restart doesn't help, e.g. after a TCC refusal); without the hook the capture is torn down at most once per
10 min. Log lines `audio: watchdog: …`, counters in `/audio/stats` `watchdog`.

An ad-hoc signature changes with every rebuild, so the grants must be toggled off and on again after each
`./build.sh` unless `SIGN_IDENTITY` is a stable identity. Grants follow the designated requirement: moving between
Apple Development and Developer ID builds asks for them again; Developer ID builds (and their updates) share them. A newly granted Screen Recording permission may
only take effect after the helper restarts.

## HTTP API

All errors are JSON `{ "error": "..." }` with a matching status; every response is `Connection: close`.

| Request | Response |
| --- | --- |
| `GET /status` | `{ app: "YoyoControl", version, build?, api, ok, session: { loggedIn }, screenRecording, accessibility, displays: [{ id, width, height, scale, main, asleep, kind, name? }], states, console, control }` (`control`: who controls the screen, `{ controller: "none" }` or `{ controller: "remote", since, device: { id, name } }`, RemoteControl.swift, docs/REMOTE.md) (points + `scale` = pixels per point on every display; `kind`: `builtin` / `external`; `name`: `NSScreen.localizedName` read on the main queue and cached (DisplayNames.swift), absent when empty or only a parenthesised suffix such as " (AirPlay)"; `ok: false` + `error` without a GUI session or without displays; `states` / `console`: the connection state, ../docs/PROTOCOL.md 「连接状态」; `automation: { active, esc, label? }`: `POST /automation`'s state, `esc` = the Escape tap is in (`agentControl: { active, esc }`: the same, its older name); `app` / `version` (CFBundleShortVersionString, "dev" unbundled) / `build` (CFBundleVersion, absent unbundled) / `api` (`ServerIdentity`, now 1: +1 only on an incompatible API change): who answers, on every answer, ok or not, ../docs/LOCAL-API.md; `candidates: [{ kind: "lan" \| "public", host, port }]`: where paired phones reach the remote listener, only while it runs — every interface address, then the router's public mapping, docs/REMOTE.md「外网直连」; `inputElsewhere: { at, source, pid?, app?, bundleId? } \| null`: the latest input this process did not post, `features: { inputElsewhere, link }`: whether that watch is in, 「Input from elsewhere」, and whether the link listener runs; `link: { id, key, sig, port, relays, direct }` while it does, 「uu Link」) |
| `GET /frame?display=&maxWidth=1280&quality=70[&visible=][&hide=][&crop=]` | `image/jpeg`, headers `X-Frame-Width`, `X-Frame-Height`, `X-Display`. For automation (Windows.swift, NativeFilter.swift; `/stream` takes neither): `visible=<bundleId,…>` (comma-separated, case-insensitive) shows only those apps' windows. First natively (header `X-Frame-Filter: native`): ScreenCaptureKit composes exactly the windows to show, `SCContentFilter(display:including: [SCWindow])` from the on-screen window list (`NativeFilterPlan.showWindows`; when ScreenCaptureKit doesn't list one of them, by app instead: `SCContentFilter(display:including:exceptingWindows:)`, and the menu bar may then be missing): the system's menu bar (main-menu and status levels' windows of the Window Server and `com.apple.*` processes; another app's window there — its status item on older macOS — only like its other windows; on macOS 27 every status item is drawn in the Window Server's one bar window and shows) and the wallpaper (the Window Server's, the Dock's and the wallpaper agent's windows below the normal level) and the lock screen / screen saver (loginwindow, `com.apple.ScreenSaver*`: a locked Mac looks locked) always; Finder's windows, the desktop icons / the rest of the desktop layer and the Dock's bar only with `com.apple.finder` in `visible` (Control Centre's / SystemUIServer's other windows with their own bundle id); other windows when their owner is in `visible`; never this helper's windows (the automation border) nor this app's (`ca.sarria.yoyocontrol*`) nor a hidden app's: `hide=<bundleId,…>` (comma-separated, case-insensitive, a trailing `*` matches a prefix, ≤ 64, 400 for one that is not a bundle id) takes those apps out of `visible` (`HiddenApps`, ../docs/LOCAL-API.md); without `visible=` it does nothing. Apps owning a shown window are included, their other windows on the list excepted; nothing of another app is in the picture (the desktop shows where its windows were). When that fails (the API throws, an app to include has no `SCRunningApplication`, no picture within 5 s; logged) it falls back to covering (`X-Frame-Filter: mask`): every on-screen window of any other app gets a solid #3a3a3a block carrying the app's name (12 pt white, top-left), painted back → front so an allowed window in front of a covered one shows; the desktop (wallpaper, icons) and the system's menu bar are never covered, the Dock counts as Finder's; the window list is taken right before the ScreenCaptureKit picture. `visible=` empty: only the furniture (native) / every window covered (mask). Every `/frame` leaves this helper's own windows out. `crop=x,y,w,h` (normalized 0…1, clipped to the picture; 400 when empty) cuts that region from the full-resolution picture after covering, then scales it to `maxWidth`; header `X-Crop: x,y,w,h` = the region actually used (4 decimals) |
| `GET /windows[?display=]` | `{ apps: [{ pid, bundleId, name, windows }], windows: [{ pid, display, x, y, w, h, layer }], focused: { pid, bundleId, name } \| null }` from `CGWindowListCopyWindowInfo` (on-screen only; this login session's own list; no window titles). `windows` front → back, each on the display holding its center, geometry normalized 0…1 on that display (clipped to it); only `display`'s with `display=` (`apps` stays complete). `apps`: one per owner in front → back order with its window count. The desktop layer, the Dock and the Window Server's menu bar fold into one Finder entry (`com.apple.finder`; windows carry Finder's pid); SystemUIServer and Control Centre are apps of their own. Left out: fully transparent windows, the pointer and the Window Server's other overlays, this process, and the invisible full-display windows some system processes keep above the apps (the Dock's, WindowManager's, Notification Centre's, Control Centre's: `WindowCatalog.isSystemBackdrop`) — except what Accessibility shows drawn in one (OverlayContent.swift, `OverlaySurfaces`: in the AX window with the same frame, else the AX windows inside it, the first elements down each branch at most 0.6 of its width and height; ≤ 150 elements, 0.5 s): each such surface (a Notification Centre banner, its panel's widgets) is listed as a window of its own with that frame (same pid and layer; `apps` counts the window once), and hit / covered like any other. An app's `englishName` (also on `focused`, `/hit`, `/app/windows`, `/app/ax`): its bundle's English name (`en` InfoPlist strings, else its Info.plist name), only when it differs from `name` (the localized one: "Notification Centre" in en-CA, "Notification Center" in English). `focused`: the app taking keyboard input (FocusProbe: `kAXFocusedApplicationAttribute`, else the owner of the frontmost normal window), null without Accessibility |
| `GET /hit?display=&x=&y=` | `{ app: { pid, bundleId, name, englishName? } \| null, layer: number \| null, menuBar?: "appleMenu" \| "appMenu" \| "statusItem" \| "bar" }`: the owner of the topmost on-screen window containing the normalized point (same list and folding as `/windows`: desktop and Dock report Finder, a system overlay counts only where something is drawn in it); `app: null` when no window is there. **The menu bar** (a main-menu / status level window along the display's top edge, ≤ 80 pt: on macOS 27 one Window Server window holds the whole bar, the hidden bar's strip over a full-screen app too) is answered by Accessibility (MenuBar.swift, `WindowCatalog.menuBarHit`; `menuBar` says which part): a status item → the app whose `AXExtrasMenuBar` holds it (every regular / accessory app asked, 0.1 s each, ≤ 0.6 s, kept 1 s), else the item the system's hit test finds (`AXMenuExtra` subrole or in an extras bar); the Apple menu (the first title of an app's `AXMenuBar`) → `{ bundleId: "com.apple.AppleMenu", name: "Apple menu" }` with the drawing app's pid; an app's menu title → that app; the rest of the bar → the frontmost app (FocusProbe, else the frontmost normal window's owner); never Finder unless it is the frontmost app. `app: null` there without Accessibility / in a session switched away, or when an app did not answer for its status items and the point may be one of its icons: from 40 pt left of the leftmost item found on that bar rightward (no item found: the whole bar; the empty middle of the bar stays the frontmost app's); another app's own window at the menu bar's levels (older macOS' status items) is that app's without Accessibility too. When that window is an overlay (above the normal level, not the menu bar, the lock screen / screen saver or the Window Server's: a popover, a floating panel, a banner), the system's own hit test decides whether it is clear at the point (`AXUIElementCopyElementAtPosition` on the system-wide element → its pid): the answer is then the first window under the point of that pid, looking through overlays only (never past a normal window); no Accessibility, a session switched away, or a pid with no window there: the topmost window stays. 400 when `x` / `y` is missing or outside 0…1 |
| `GET /app/windows?bundleId=` | `{ app: { pid, bundleId, name } \| null, windows: [{ id, display, x, y, w, h, onScreen, minimized }] }` (AppWindows.swift; background automation: none of the `/app/*` endpoints needs control of the screen). Every process with that bundle id (case-insensitive; not running: `app: null`, no windows), from `CGWindowListCopyWindowInfo(.optionAll)` so off-screen, other-Space and minimized windows are listed too. `id` is the CGWindowID (= `SCWindow.windowID`). Kept: alpha > 0, layer from normal (0) up to below the menu bar (no desktop, menus, status items), at least 40 pt on a side on screen / 80 pt off screen (apps keep 33 pt menu-bar strips off screen), not a full-display backdrop (`/windows`): an on-screen system overlay with something drawn in it is listed with the bounding box of its surfaces as its frame. `display`: the one holding the window's center (else the one it overlaps most, else the first); `x y w h` normalized on it, **not clipped** (a window past its display's edge goes past 0…1). Order: on screen at the normal level front → back, then other on-screen levels, then off screen, then minimized. `minimized`: Accessibility's `kAXMinimizedAttribute` of the AX window with the same frame (`AXWindowMatch`), false without Accessibility. 400 without `bundleId` |
| `GET /app/screenshot?window=&maxWidth=1280&quality=70` | `image/jpeg` of that one window, `SCContentFilter(desktopIndependentWindow:)` (also covered, on another Space or behind the lock screen), no shadow (`ignoreShadowsSingleWindow`: the picture is exactly the window's frame), no pointer, the window's points × its display's scale capped at `maxWidth`. Headers `X-Frame-Width`, `X-Frame-Height`, `X-Window` (the id), `X-Display`, `X-Window-Bounds: x,y,w,h` (normalized on that display, unclipped, 4 decimals: as `/app/windows`). A system overlay over a whole display (as `/windows`): only the bounding box of what is drawn in it, cut from the window's full-resolution picture and then scaled to `maxWidth` (`X-Window-Bounds` = that box); 409 when nothing is drawn in it. 400 no `window`; 404 unknown window; 403 Screen Recording missing, or the window is this helper's or a hidden app's (`hide=` as for `/frame`, this app always); 409 `{ error }` minimized (Accessibility says so) or no picture (ScreenCaptureKit doesn't list it, fails, or 5 s pass) |
| `GET /app/ax?window=&max=60` | `{ app: { pid, bundleId, name }, window, focused: i \| null, truncated, elements: [{ i, role, subrole?, title?, x, y, w, h, enabled, focused }] }` (AppAX.swift). The window's AX element (`AXUIElementCreateApplication(pid)` → `kAXWindowsAttribute`, matched to the CGWindowID by frame: `_AXUIElementGetWindow` is private API, so the AX window whose position and size are within 4 pt on every edge, the closest, the first on a tie; Electron / Chromium apps first get `AXManualAccessibility` / `AXEnhancedUserInterface` as for `/focus`), walked depth-first (pre-order, depth ≤ 15, ≤ 400 children per element). Listed: AXButton, AXTextField, AXTextArea, AXComboBox, AXSearchField, AXLink, AXRadioButton, AXCheckBox, AXPopUpButton, AXMenuButton, AXTab, AXDisclosureTriangle, AXMenuItem; AXRow / AXCell whose `kAXSelectedAttribute` is settable; AXGroup that has a label and offers `AXPress` (a notification banner: pressed as a whole, its texts are its label); AXStaticText that has a label and is not inside a pressable group, a button / link / menu item / tab / pop-up / check box / radio button. `i` is 1-based in walk order; `title` = `kAXTitleAttribute`, else `kAXDescriptionAttribute`, else `kAXPlaceholderValueAttribute` (trimmed, ≤ 200 characters); **`kAXValueAttribute` is never read** (a text field may hold a password). `x y w h`: normalized 0…1 on the window (= on its `/app/screenshot` picture), clipped to the window and to every enclosing AXScrollArea (elements scrolled out of view are left out, as are ones without a frame). One batched read per element (`AXUIElementCopyMultipleAttributeValues`) with a 0.3 s messaging timeout; at most `max` elements (default 60, 1…200) and 2 s for the walk, then `truncated: true` with what was collected. `focused`: the element whose `kAXFocusedAttribute` is true, else the app's `kAXFocusedUIElementAttribute` if listed. A system overlay over a whole display (as `/app/screenshot`): the AX window with its frame, else the AX windows inside it, one after the other, `x y w h` normalized on and clipped to the bounding box of what is drawn in it (= its `/app/screenshot` picture). 403 without Accessibility (or a hidden app's window, `hide=` as for `/app/screenshot`); 404 unknown window / no matching AX window (another Space); 409 minimized; while the Mac is locked apps answer no window elements (their AX tree is just AXApplication) → 404 `has no Accessibility window right now` |
| `POST /automation` (or `POST /agent-control`, its older name) | `{ active: bool, label?: string }` → `{ ok: true, active, esc, label? }` (Automation.swift; ../docs/LOCAL-API.md「本机自动化」). `active: true` (from false): a session event tap for key-downs is installed (needs Accessibility; `esc: false` when it can't be), then one borderless window per display (`level` screenSaver − 1, `ignoresMouseEvents`, `[.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`, `sharingType = .none`) draws a 6 pt orange glowing border (`CAShapeLayer`, a 1.6 s breathing opacity) with a capsule at the top center below the menu bar: "<label> is using this computer · press Esc to stop" / 「<label> 正在使用这台电脑 · 按 Esc 停止」 by the system language, "Automation" / 「自动化程序」 without a label (without the Esc part when there is no tap); `label`: who is driving, one line (control characters → spaces), ≤ 40 characters kept; a new label while active redraws the capsule; `title` (older clients: what is being done) is accepted and not shown. `active: false` (from true): tap and border removed. Same value again: no effect. While active, Escape without ⌘ ⇧ ⌥ ⌃ that this process did not post (the automation's and the phones' keys come through `/input`) is swallowed, ends the active state as `false` would and writes `{"type":"abort","reason":"esc"}` to `/events`. No system notifications. The border windows are never in a picture: every capture (`/frame` either way, `/stream` at its start) leaves this process's windows out. 400 when `active` is not a boolean or `label` / `title` not a string. Not reachable by paired phones |
| `GET /stream?display=&maxWidth=&fps=2&codecs=&stream=&ack=&cursor=&status=&maxKbps=` | `application/vnd.yoyo-control.stream; boundary=frame` (StreamWire.swift, ../docs/LOCAL-API.md「流的媒体类型」; multipart bytes, not `multipart/x-mixed-replace`, which URLSession splits itself), head `X-Stream-Codec` (+ `X-Stream-Id`): H.264 / HEVC parts (one access unit each, Annex-B, `X-Frame-Kind` key / delta / refine / keepalive) and, with `cursor=client`, cursor parts (`application/vnd.yoyo-control.cursor+json`) — video only (`codecs`: h264 / hevc in the client's order, unknown tokens dropped, none = h264; a codec whose
low-latency hardware session can't be made is skipped; neither encodable: 503). ScreenCaptureKit (Capture.swift) through one video loop (VideoStreamLoop.swift); ../docs/PROTOCOL.md 「视频流、确认与客户端指针」 |
| `POST /stream/ack` | `{ stream, seq, keyframe?, report? }` → `{ ok: true, net }`; 404 for an unknown stream (StreamFlow.swift) |
| `GET /events` | `application/x-ndjson`, streamed: `{"type":"state","states":[…],"console":…}` at once and on every change, `{"type":"control","control":{…}}` when control changes (docs/REMOTE.md), `{"type":"clipboard",…}` (the clipboard's summary, Clipboard.swift) right after it and on every pasteboard change, `{"type":"abort","reason":"esc"}` when the user pressed Esc while automation was active (`POST /automation`; only to subscribers connected at that moment), `{"type":"input-elsewhere","at","source","pid"?,"app"?,"bundleId"?}` while input this process did not post goes on (「Input from elsewhere」), `{"type":"ping"}` every 15 s (ScreenState.swift; `/stream?status=1` adds status parts, `application/vnd.yoyo-control.status+json`, StreamStatus.swift) |
| `GET /clipboard[?text=0]` | what `NSPasteboard.general` holds (../docs/PROTOCOL.md 「剪贴板」 `ClipboardItem` + `ok`): `kind` text / image / files / concealed (a password manager's item: nothing else) / other / empty, `preview`, `size`, `width` / `height`, `files` (≤ 20 + `moreFiles`), `at` (first seen), `source` (phone / agent when this helper's own POST made it), `text` unless `text=0`; 503 without a GUI session (Clipboard.swift) |
| `GET /clipboard/image` | the image item as `image/png` (converted once per changeCount); 404 otherwise |
| `GET /clipboard/file?index=N` | file N of a files item, streamed in chunks; `Content-Length`, `Content-Disposition: attachment; filename*=UTF-8''<name>`, `Content-Type` by extension; 400 a folder, 404 not files / out of range / gone |
| `POST /clipboard` | `{ text }` or `{ files: ["/abs/path"…], source?: "phone" \| "agent" }` → the pasteboard replaced (one item per file; a single image file also carries its image data), `source` remembered for that changeCount, `ScreenHost.onClipboardReceived` for files (unset: a log line); answers like `GET /clipboard`. 400 bad body / missing path, 413 text over 1 MiB |
| `GET /audio` | `application/vnd.yoyo-control.audio; boundary=frame`: the session's sound (Core Audio process tap → Opus 48 kHz stereo 96 kbit/s), one 20 ms packet per `audio/opus` part with `X-Audio-Seq` / `X-Audio-Time`; head `X-Audio-Codec` / `-Rate` / `-Channels` / `-Frames` / `-Cookie` / `-Video-Offset` (ms to add to `X-Audio-Time` for a real display's `X-Frame-Time` of the same instant: the output device's latency + ScreenCaptureKit's capture latency, AudioVideoOffset.swift) (AudioStream.swift, AudioCapture.swift; ../docs/PROTOCOL.md 「屏幕」「声音」). One capture for every client, stopped 3 s after the last; 503 when it can't start or `YOYO_AUDIO=off` |
| `GET /audio/stats` | the audio capture's counters: `running`, `starts`, `failures`, `lastError`, `capture` { `clients`, `packets`, `bytes`, `drops`, `peakDBFS`, `firstIOSeconds`, `firstSoundSeconds`, `zeroSeconds`, `outputDevice`, … }, `videoOffset` { `tapToSpeakerMs`, `captureLatencyMs`, `totalMs` }, `watchdog` { `checks`, `deaf`, `lastResult`, `lastAgoSeconds`, `exits`, `suppressed`, `teardowns` }, `serviceRestarts` (see「Sound: deaf helper and coreaudiod restarts」) |
| `POST /input` | `{ "ok": true }`; a `move` whose `seq` is lower than one applied in the last 2 s: `{ "ok": true, "stale": true }`, not applied (`PointerMoveGate`, Input.swift). 409 while a paired phone holds control (`{ error, code: "controlled-elsewhere", controllerDevice: { id, name } }`; a phone's own input: 409 until it took control, RemoteControl.swift) |
| `POST /console/unlock` | the unix socket only (404 over the link): `{ password }` → `{ ok, unlocked, already?, reason? }`: types the caller's password into the lock screen, only while `IOConsoleLocked` is true (「Console lock」) |
| `POST /console/lock` | the unix socket only (404 over the link): → `{ ok, locked, already?, reason? }` (「Console lock」) |
| `POST /control` | paired phones only (over the link; 404 on the unix socket): `{ controller: "user" \| "none" }` → `{ ok: true, control }` (docs/REMOTE.md「控制权」) |
| `GET /remote`, `POST /remote/pairing`, `/remote/pairing/stop`, `/remote/enabled`, `/remote/direct`, `/remote/devices/remove`, `/remote/disconnect`, `/remote/account/leave` | the unix socket only, with `--remote` (else 404): the menu bar app's management of remote access (docs/REMOTE.md「本机管理接口」); `GET /remote` has `signal: { connected }` (registered at the signaling server, docs/RELAY.md), `direct: { enabled, status, address?, port?, method? }` (the router's mapping of the link's UDP port), `account: { id, since } \| null` (the Yoyo Control account this Mac is in, docs/ACCOUNT.md; `POST /remote/account/leave` leaves it), and `POST /remote/direct { enabled }` switches the mapping (PortMapper.swift, docs/REMOTE.md「外网直连」) |
| `GET /account`, `POST /account/join { account }`, `POST /account/invite { id, name, linkKey }` | a paired phone over its link session only (404 elsewhere, AccountRoutes.swift): which account this Mac is in; put it in the phone's account (→ the signed statement for the account service); a code that pairs the phone `id` alone, from the link key `linkKey` (→ `{ code, expiresAt }`), docs/ACCOUNT.md |
| `POST /permissions/request` | `{ ok: true, screenRecording, accessibility }` (shows the system prompts) |

### uu Link

Remote access's only door (docs/LINK.md「服务端：Mac」, docs/REMOTE.md, `Link*.swift`): with `--remote`, a link listener on
UDP 47820 runs while remote access is on and a phone is paired or a pairing code is shown. Phones and browsers pair over
it (`hello.credential = "Pair <code>"`, the token in `welcome.principal.token`, docs/LINK.md「配对」) and come back with
`Bearer <token>` (a token binds to the first link key it comes with: `devices.json`'s `linkKey`); their requests go
through remote access's allowlist over RPC streams, with its control rules. Its key is `<home>/link-key` (Ed25519,
0600), its binding signed with the identity key (`tls-key.der`, RemoteIdentity.swift). The router forwards a public UDP
port to it (`PortMapper`; the switch `direct`, and `YOYO_PORTMAP=off`; `link: port mapping …` lines): the public
`ip:port` goes to the endpoint (`add_external_addr`), so it is in `link.direct`, and the mapping is deleted when the
listener stops or the service exits (`GET /remote` `link.mapping`). iroh's own port mapper stays off: it maps only
after a net report, which needs relays. Video runs the same loop as `/stream` into a link sink (the media layer's
`can_send_frame` and target bit rate instead of the ack window and the bit-rate steps — the gate also holds frames to
the media layer's frame-rate cap, fewer and sharper frames at a low rate, which VideoToolbox's time-based rate control
gives the bits on its own; recovery frames on VideoToolbox long-term references after a loss), sound the same capture as `/audio`, input the same handler as `POST /input`.
`/status` has `link: { id, key, sig, port, relays, direct }` (the binding) and `features.link` while it runs;
`GET /remote` has `link` (or null); the signaling server (`YOYO_SIGNAL_URL`, RemoteSignal.swift; none is built in: unset = no signaling) hears it as `{ type: "link", … }` and passes browsers' offers on. Log lines:
`link: listening on udp port …`, `link session opened/closed …`, `link path …`, `link[server]: …` / `link[phone]: …` every
10 s, the video stream's stats line with `link target … Mbps keys … recoveries …`.

- `ServiceHost.Options.link` / `ScreenService(link:)` (`LinkOptions`): `port` (47820), `relays` (iroh relay URLs; empty =
  direct only, the default: no relay is built in; `--remote` reads `YOYO_LINK_RELAYS`), `keyDirectory` (default the remote home), `authority` (authority mode: a local host decides
  who enters and who controls, docs/LOCAL-API.md「Link 的主人」; no remote access needed), `portMapping` (default on,
  `YOYO_PORTMAP=off` off), `bindAddresses` (default every interface), `traceDirectory` (a per-frame trace of every
  session, docs/LINK.md「逐帧跟踪」; default none). `Options.link == nil`: with `--remote` the
  defaults, without it none. `--no-link` turns it off (and with it remote access).
- Authority mode's routes (unix socket only; 404 otherwise): `GET /link/authority` (the host's NDJSON channel, one host,
  409 for a second), `POST /link/authority/answer`, `POST /link/control` (docs/LOCAL-API.md「Link 的主人」).
- Tests: `swift test --filter Link` (the bookkeeping, VideoToolbox long-term references, authority mode, and
  `LinkSessionTests`: a YoyoLink client on loopback; through `uu-link-netem` with the environment in docs/LINK.md「测试工具」).

Optional `/status` fields of this API that this server does not send (yet): `platform` (`"mac"` / `"linux"`, an open set; absent =
`"mac"`) and `features` (`{ clipboard, audio, cursor, focus }` booleans, an open set: readers ignore keys they don't know; absent =
everything this table lists). The Linux server (`../linux/README.md`) sends both; its key name `insert` is answered 400 here
(../docs/PROTOCOL.md「Linux 服务端」). Clients must accept both fields absent.

`display` defaults to the main display; `maxWidth` is clamped to 160…3840, `quality` to 10…95, a stream's `fps` to
1…60 (the low-latency hardware encoder of Apple silicon; there is no regular-session fallback).
Capture wakes a sleeping display first, and a stream keeps the display awake while it runs. `X-Display` is the
display captured. A stream waits up to 1.5 s for ScreenCaptureKit's first complete frame before its head goes out
(none by then: it starts anyway, late frames still go out; the capture stopping first is a 503).
Status codes: 403 permission missing, 404 unknown display, 503 no displays, 400 bad parameters.
Every number a stream runs by (ack window, bit-rate / resolution adaptation, refine / keepalive timers) is in
`StreamTuning` (StreamFlow.swift) as a constant (the environment switches are listed below). The picture size is fixed for a stream (congestion only
lowers the bit rate); after 300 ms without changes sharper "refine" re-encodes of the same picture follow, then one
every 100 ms (`refineEvery`) while it stays unchanged, until two in a row come out no bigger than one live picture's
budget (target rate / 8 / fps bytes; a refine the rate control skipped is not small), at most 20 (`videoRefines`);
new content starts them over (`RefineSchedule`, VideoStreamLoop.swift). A refine is encoded at a temporarily higher
rate (`refineBitrate`: 2× the target, at least 4 Mbit/s, under the network profile's ceiling; not while the path is
queueing; on a link stream also at most target × fps × `refineEvery`, so the refines add up to no more than the link's
target). Parts
carry `X-Frame-Seq` (per stream), `X-Frame-Time` (ms since 1970 when the shown content was captured) and
`X-Frame-Kind`. A stream logs a stats line every 10 s (capture callbacks by status, complete-frame gaps, pictures
sent, encode times, `cursor parts N` with `cursor=client`, the flow, then the phone's latest playout report
`phone smooth 59.6 fps hitch 0.4/s stall 0.1/s buf 52 ms jit 48 ms` and, while sound plays, `audio delay 118 ms
underruns 0` summed over the 10 s). Other stream lines: open / close, the network grade when it changes
(`phone net: … → fair (rtt)`) and once at the end, a bit-rate step down or a climb that reached its ceiling
(`bitrate 3500 → 2975 kbps (…)`; other climbs are the stats line's `climbs`), a profile change, `acks are back`.

A video stream honours `cursor=client` (DisplayPointer.swift): the capture leaves
the pointer out (`showsCursor = false`) and the stream sends cursor parts — one before the first picture, then on
changes, outside the ack window. The position comes from `/input` the moment it is handled and
from `CGEvent(source: nil).location` polled every 50 ms (followed only when it changes; off the display = invisible);
the shape from `NSCursor.currentSystem` every 100 ms, else the built-in arrow. Streams without `cursor=client` keep
the pointer baked in. The stream-open log line says `cursor client`; its stats line counts the cursor parts.

`POST /input` body: `{ type, display?, x?, y?, dx?, dy?, text?, key?, modifiers?, button?, phase?, vx?, vy?, seq? }`

- `x`, `y` are normalized 0…1 within the display.
- Types: `click`, `doubleClick`, `rightClick`, `move` (need x/y); `drag` (x/y to x+dx/y+dy, normalized);
  `scroll` (dx/dy in points, positive dy reveals content further down; x/y optional); `type` (`text`, newlines
  press Return); `key` (`key`: a–z, 0–9, return, enter, escape/esc, tab, space, delete/backspace, forwardDelete,
  up/down/left/right, home, end, pageUp, pageDown, f1–f12, `- = [ ] ; ' , . / \ ``).
- `modifiers`: any of `cmd`, `shift`, `alt`, `ctrl`.
- `scroll` only: `phase` (`began` / `changed` / `ended`: a two-finger gesture; absent = a plain scroll) and, on
  `ended` (dx/dy: the last movement not sent yet, often 0), `vx` / `vy`: the fingers' velocity at lift in points per second, the signs of dx/dy.
- `move` only: `seq`, the phone's move counter (a non-negative 64-bit integer, starting at the wall clock in ms): the
  highest one applied in the last 2 s is kept, a lower one is answered `stale` and not applied; ≥ 1000
  below, or 2 s without a move, starts over; without `seq` every move applies.
- Bad input is 400 (checked before permissions); a missing Accessibility grant is 403.

### Console lock

`POST /console/unlock { password }` and `POST /console/lock` (ConsoleControl.swift; ../docs/LOCAL-API.md「锁屏与解锁」):
a local client locks or unlocks the console for its user. The unix socket's only (404 over the link), and only when
this process's GUI session is the console's (`kCGSessionOnConsoleKey`; else `reason: "not-console"`). One flow at a time
(a second request waits, then looks again). The password always comes from the caller; the service keeps none.

Unlock: `IOConsoleLocked` (the registry root's) not true → `{ ok: true, unlocked: true, already: true }`, nothing typed.
Otherwise: Accessibility is needed (403 without); the display is woken (`IOPMAssertionDeclareUserActivity`, like
`caffeinate -u`; a sleeping display's lock screen swallows the keys and counts a failed attempt) and waited for (≤ 3 s,
else `display-asleep`, nothing typed; 0.5 s more after a wake). Then, only after reading `IOConsoleLocked` true once
more (unlocked by now → `already`, no click), one left click on the lock screen's clock (top center, 35 % down the main
display) and 1.3 s, always: a lock screen left alone for a while goes idle (macOS 27: clock, avatar and password field
hidden, the display on) and neither user activity nor pointer moves bring it back, so keys would go nowhere (measured:
`timeout`, the failed-login count unchanged); the click does, in ~1.2 s. Then one character at a time (a surrogate pair is one), `IOConsoleLocked` read again before every
one: unlocked meanwhile (a person, Touch ID, a Watch) → stop at once, no Return, `{ ok: true, unlocked: true, already: true }`.
Return, then ≤ 5 s for the unlock: `{ ok: true, unlocked: true }`; else `{ ok: false, unlocked: false, reason }`,
`wrong-password` when the account's failed-login count (`accountPolicyData` `failedLoginCount` / `failedLoginTimestamp`
through OpenDirectory; it moves ~0.5 s after a wrong password) moved, or when it cannot be read (so a caller stops
trying), `timeout` when it was read and did not move. Never retried. The body is parsed by hand into a buffer the
service owns (no Foundation strings) and wiped after use; neither the body nor the password is logged. The keystrokes
are this process's own events: not input from elsewhere. 400: no JSON object with a non-empty `password` string, more
than 1024 UTF-16 units, control characters.

Lock: already locked → `{ ok: true, locked: true, already: true }`; else `SACLockScreenImmediate` (the private
login.framework, dlopen'd; no permission needed), Ctrl+Cmd+Q when it is missing or has not locked after 1 s (needs
Accessibility); the display stays on; ≤ 3 s for `IOConsoleLocked`: `{ ok: true, locked: true }`, else
`{ ok: false, locked: false, reason: "timeout" | "not-console" | "no-permission" }`.

Either flow's result is settled into the console watcher at once (`/status.console`, the `/events` state line), without
the watcher's 1.5 s settle time. Log lines: `console: unlocked in 2.1 s`, `console: unlock: wrong password …`,
`console: unlock: unlocked meanwhile, stopped typing …`, `console: locked in 0.2 s`.

### Input from elsewhere

While the service runs and Accessibility is granted, a pass-through session event tap (InputElsewhere.swift; the same
kind as the automation's Escape tap, so Accessibility is enough, not Input Monitoring) watches key-downs, modifier
changes, every button's down / up / drag, pointer moves and scrolls. Events this process posted (`POST /input`, the
phones' and local clients' alike: `eventSourceUnixProcessID` is its pid) do not count. Anything else is input from
elsewhere:

- `source: "hardware"`: no posting process (the HID system: a physical keyboard, mouse or trackpad, also virtual-HID
  drivers).
- `source: "process"`: another process posted it (`pid`; `app` / `bundleId` from `NSRunningApplication` when it is an
  app: a remote-desktop tool, another automation, …).

Reported as `/events` lines `{"type":"input-elsewhere","at":<ms since 1970>,"source":…,"pid"?:…,"app"?:…,"bundleId"?:…}`
(the first at once, then at most one per second while it goes on) and as `/status`'s `inputElsewhere` (the latest, or
`null`); `/status.features.inputElsewhere` is true while the tap is in (false without Accessibility; it is retried every
3 s, so a later grant starts it). The callback only reads a field and the clock (the event passes unchanged; the tap is
re-enabled when the system times it out). The service itself does nothing about it: a client decides (e.g. holds its
automation while a person is at the keyboard, ../docs/LOCAL-API.md). `ServiceHost.Options.watchInputElsewhere = false`
leaves the tap out.

### Scrolling

Scrolls (CGEvents into the HID tap) go through `ScrollSynth`
(`ScrollSynth.swift`): one per tap, a serial queue ticked by a strict timer at 120 Hz while there is work, idle
otherwise; the request is answered at once. Its core, `ScrollMotion`, is a value type with unit tests
(`ScrollMotionTests`):

- Pacing: a request's pixels join what is left and all of it goes out linearly by a deadline set at its arrival:
  0.9 × the expected interval (the time between requests, smoothed 0.7/0.3; a pause of 0.5 s or a gesture's `began`
  starts afresh with 30 ms), within one tick…140 ms. Sub-pixel remainders carry over (whole pixels add up to what was
  asked, within one). The phone keeps one request in flight (15 ms apart on the LAN, 130–250 ms over the tunnel), so
  the picture keeps moving between requests and stops within a window once the fingers do.
- Phases (with `phase`): the gesture's first event has `scrollWheelEventScrollPhase` began, later ones changed; on
  `ended` what is left goes out, then a zero-delta ended. `changed` with no open gesture begins one; a `began` while
  the last gesture is still going out continues it (no ended, no momentum); a gesture with no request for 3 s ends
  (no momentum).
- Momentum: after the ended, from |v| ≥ 120 pt/s (capped at 8000): `scrollWheelEventMomentumPhase` begin, then
  continue every tick with the distance of v decaying by 0.998 per ms (UIScrollView's normal deceleration), until
  |v| < 20 pt/s, then a zero-delta end. A new scroll, or other pointer input on that path (click, double / right
  click, down, move, drag: `interrupt`) stops it at once with a zero-delta end; the interrupt also sends what is left
  of a scroll and ends an open gesture first.
- One log line per gesture when it is over: `hid scroll gesture: 14 requests every 128 ms, (0, 812) px in 1920 ms;
  momentum 2350 pt/s → (0, 1172) px in 2410 ms`.

## Environment

Every switch the helper reads (nothing else is read; the tests have their own opt-in ones, e.g.
`YOYO_AUDIO_LIVE_TESTS=1`, `YOYO_CODEC_BENCH_DIR`):

- `YOYO_VIDEO_MAX_KBPS` (100…100000): lowers the video bit-rate ceiling (20000); the start rate follows it
  down (`StreamTuning.fromEnvironment`).
- `YOYO_VIDEO_MAX_WIDTH` (320…3840): the widest video picture, as is; unset, the width is automatic
  (`Router.videoWidthCap`).
- `YOYO_VIDEO_CODECS` (a comma list of `h264` / `hevc`): the codecs a stream may use, default both
  (`StreamCodecs.serverAllowed`; the client's order still decides).
- `YOYO_AUDIO=off` (or 0 / false / no): `/audio` answers 503 "audio off".
- `YOYO_DISCLAIMED=1`: internal, set by the TCC-responsibility re-launch on its child (see above; an embedder may
  pick another name, `ServiceHost.Options.disclaimedEnvironmentKey`).
- `YOYO_LINK_PORT` (1…65535) / `YOYO_LINK_BIND` (a comma list of IP addresses): the link listener's UDP port and the
  addresses it binds, for `--remote`'s default options (tests beside a running app, behind `uu-link-netem`; an
  embedder's `ServiceHost.Options.link` ignores them).
- `YOYO_LINK_RELAYS` (a comma list of iroh relay URLs, `off` = none): `--remote`'s default `LinkOptions.relays` instead of
  Yoyo Control's relay (`LinkOptions.defaultRelays`, docs/LINK.md「端点、地址、路径」).
- `YOYO_LINK_TRACE` (a directory, `off` = none): `--remote`'s default `LinkOptions.traceDirectory`. The app sets it to
  `<log directory>/link-trace` for its service unless the environment already has it.
- `YOYO_HOME` (the app only): its home instead of `~/Library/Application Support/YoyoControl` (see「The app」).

## Manual test

The app, beside a real one:

```sh
export YOYO_HOME=$TMPDIR/nsh
"build/Yoyo Control.app/Contents/MacOS/yoyo-control" &      # the menu bar icon appears
curl -s --unix-socket $YOYO_HOME/screen.sock http://x/status
kill %1                                                 # the service and the socket go too
```

The service alone:

```sh
S=$TMPDIR/ns.sock
"build/Yoyo Control.app/Contents/MacOS/yoyo-control" --socket $S &
curl -s --unix-socket $S http://x/status
curl -s -D - -o frame.jpg --unix-socket $S 'http://x/frame?maxWidth=640'
curl -s --max-time 3 --unix-socket $S 'http://x/stream?fps=2' -o stream.bin
curl -s --unix-socket $S -X POST -d '{"type":"move","x":0.5,"y":0.5}' http://x/input
kill %1     # SIGTERM: the relay forwards it, the socket is removed
```
