# client

Yoyo Control 的手机端：经 uu Link 连 Mac 上的 Yoyo Control.app（配对与远程访问见 `../docs/REMOTE.md`，Link 见 `../docs/LINK.md`，流与输入见 `../docs/PROTOCOL.md`）。

- **`YoyoKit/`**：iOS 的 kit（Swift Package，iOS 26+，包在仓库根 `Package.swift`：SwiftPM 的远程依赖要求包在仓库根），
  六个 product，见下「Kit」。屏幕页本身（画面解码与平滑播放、声音与音画同步、手势 / 键盘 / 修饰键、显示器切换、
  控制权与「别的手机在控制」（打开时只看，第一次真正输入或点胶囊上的「开始控制」/「接管」才拿控制权：`ScreenControlPolicy`，`../docs/PROTOCOL.md`「客户端什么时候拿控制权」）、
  剪贴板键与提示）、剪贴板页，加上 Yoyo Control 自己的后端 `YoyoDirect`：配对（`YoyoInvite`、
  `YoyoClient.pair`：在 Link 上用 `Pair <码>`）、连 Mac（Link 的绑定先核对钉住的身份指纹）、`/status` / `/events` /
  `/clipboard` 到 kit 模型的映射。
- **`App/`**：独立 App（bundle id `ca.sarria.yoyocontrol`，xcodegen）：已配对的电脑列表（Mac 和 Linux 服务端 `--remote` 都行，每行标平台，来自配对时的 `server.platform` 与 `/status` 的 `platform`；`-YoyoFixtureMac YES` 截图用；`-YoyoFixtureScreen YES` 直接打开一个进程内演示电脑的屏幕页，`-YoyoFixtureController agent|user` 定谁拿着控制权，截图对比用）、扫码配对（也接
  `yoyocontrol://pair?…`，相机扫码直接打开）、令牌存钥匙串、Yoyo Control Pro 的付费墙。

```sh
cd ios/App && xcodegen generate && open YoyoControl.xcodeproj      # 真机：选自己的 iPhone 运行
xcodebuild test -scheme YoyoKit-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -collect-test-diagnostics never   # 仓库根，kit 的全部测试
python3 ios/Scripts/l10n.py check                                  # 每个 kit 的字符串表：L("…") 都有键和 zh-Hans
ios/App/testflight.sh                                              # Release 归档、分发签名、上传 TestFlight（要求见脚本开头）
```

试用：Mac 上运行 Yoyo Control.app → 菜单「配对 iPhone…」→ 手机上的 Yoyo Control 点 + 扫码（或用相机扫）→ 自动连上。

没带过来的：拖放文件到 Mac（远程只收文本进剪贴板，`docs/REMOTE.md`）。

## Kit

| product | 内容 | 依赖 |
|---|---|---|
| `YoyoCore` | 契约：线上模型（`ScreenStatus`、`ScreenInput`、`ScreenStreamOptions`、`ScreenStreamAck`、剪贴板的 `ClipboardStatus`…，宽松解码）、`YoyoError`、`YoyoEvent`（+ `YoyoEventHub`）、`ScreenWire`；`YoyoBackend`（页面向一台电脑要什么）、`YoyoRouting`（有不止一条路时）、`YoyoTrust`；`YoyoScreenLink`（一条自己带媒体的路：uu Link）；`YoyoHost`（外面的 App 决定什么）；`YoyoComputer`（是谁的电脑：Mac / 别的平台，跟着它的文案） | Foundation、UIKit |
| `YoyoClipboard` | 剪贴板的共享状态 `YoyoClipboardState`（每台电脑一个，跟着事件更新）、动作（`ClipboardActions`：粘到电脑 / 从电脑拷、提示与小红点）、剪贴板页 `YoyoClipboard.makePage(backend:computer:)` | Core |
| `YoyoScreen` | 屏幕页 `YoyoScreen.makePage(backend:host:)`，以及拼它的三层（`YoyoScreenSession`、`YoyoScreenPictureView`、`YoyoTrackpadView` + `YoyoScreenKeyboard`，见下「自己拼屏幕页」）、预览行的模型 `YoyoScreenPreview`、进程内的流 `YoyoStreamSource`（演示用的电脑、UI 测试） | Core、Clipboard |
| `YoyoConnect` | 不止一条路时的选路（见下「YoyoConnect」）：候选（`ConnectCandidate`：lan / direct / relay / tunnel，钉公钥 / 钉整张证书 / 系统校验）、happy-eyeballs 竞速（`ConnectRace`）、`YoyoConnector`（一个 `YoyoRouting`：网络变化重选、差路上每 30 s 再试、捷径失败立刻回落、401 换凭证、续期）、`ConnectWays`（后端按路取链接） | Core |
| `YoyoDirect` | Yoyo Control 自己的 `YoyoBackend`：在 Link 上配对和连接、记录里缺绑定时问信令服务（`SignalLookup`）、Link 候选（`DirectConnect`，跑在 YoyoConnect 上）、`RemoteAccess` | Core、Connect、Screen、YoyoLinkClient |
| `YoyoPro` | StoreKit 付费墙（`ProStore`、`ProPaywall`） | Core |
| `YoyoLinkClient` | uu Link 的手机端（`../docs/LINK.md`「客户端：iOS」）：每个进程一个端点、钥匙串里的钥匙、拨一台电脑的绑定（先核对钉住的指纹）、会话作为 `YoyoScreenLink` 和 RPC 通道（`YoyoLinkConnection`）。只有根 `Package.swift` 找到 YoyoLink（本地 `scripts/link-apple.sh build` 或发布仓库）时才有；YoyoDirect 离不开它 | Core、Connect、YoyoLink |

别的 App 嵌入屏幕页：依赖 `YoyoScreen`（剪贴板页加 `YoyoClipboard`），写自己的 `YoyoBackend`（自己的服务器、隧道、鉴权），
`YoyoScreen.makePage(backend:host:)` 拿到导航控制器后自己 present。kit 不假设怎么连到电脑：

- **请求**：流、它的确认和声音以 `URLRequest` 交给 kit（kit 自己跑 data-delegate 会话，确认走流的那条连接）；
  输入、控制权、焦点、剪贴板是方法调用。错误：非 2xx 抛 `YoyoError.http(code, message)`，凭证失效抛 `.unauthorized`
  （`YoyoHost.handleError` 先看到所有错误），另一台手机在控制抛 `ScreenControlledElsewhere`。
- **证书**：`trust(for:)` 返回 `.system` 或 `.custom { trust, host in … }`（自签证书：钉公钥、钉整张证书都行；
  custom 时不跟重定向；`ConnectTrust` 有现成的两种钉法）。YoyoDirect 钉 Mac 的公钥（`ScreenPinTrust`）。
- **路**：只有一条时用 `route`（`isLocalNetwork` 决定播放缓冲和声音的抖动下限：局域网 100 ms 上限 / 声音 80 ms，
  否则 200 ms / 120 ms）。不止一条（局域网捷径 + 一定能通的中转）时 `makeRouting()` 给一个 `YoyoRouting`：
  流开之前问它（`isDeciding` 时等最多 `decisionWait`）、路变了流和声音一起搬过去（`onChange`）、捷径上的流失败 /
  出画面前结束 / `openTimeout` 内没回应就 `streamFailed` 并马上走另一条（不算失败重试），确认的结果报给它，
  输入 / 控制 / 焦点失败时问它 `fallback(from:after:)` 换哪条重发一次（点击不会丢）。路由策略全在后端里。
- **Link**：路是一个自己带媒体的会话（uu Link）时，`screenLink(for:)` 返回它（`YoyoScreenLink`）：流、声音、指针、输入走它
  （`video.open` 用 `streamRequest` 的查询），不再用 `streamRequest` / `audioRequest` / `input` 的请求本身；拒绝的输入经
  `setInputErrorHandler` 回到页面同样的错误处理。`YoyoLinkClient.YoyoLinkConnection` 是现成的一个，嵌入方也能用自己的。
- **事件**：`events()` 每调一次一个新订阅（`YoyoEventHub` 帮着分发）：`screen.control` / `screen.state` /
  剪贴板变化。没有事件的后端：页面每 10 s 问一次 `status()`。
- **可选**：`frame`（预览行的一帧）、`focus`、`requestPermissions`、剪贴板五个方法（缺省 404：入口隐藏）、
  `sendsClipboardFiles`、`clipboardFileLimit`、`platformHint`（状态说之前猜的平台）、`isUnreachable`（哪些回答算
  「路断了」，缺省 502 / 504 / 520–527 / 530）。
- **状态**：`ScreenStatus.platform`（开放集合：`mac`、`linux`…；别的平台用「电脑 / Desktop」的文案、没有 macOS
  权限、粘贴键 Linux 是 Shift+Insert、其他 Ctrl+V）、`features`（clipboard / audio / cursor / focus，三态：没说 = 老行为）、
  `unavailableAction`（屏幕显示不了时后端给的一个按钮：标题 + 链接，比如「安装 / 更新」）。声音 404 / 403 / 501 或
  `features.audio == false` = 没有声音（喇叭按钮隐藏）。
- **宿主** `YoyoHost`：主题 `YoyoTheme`、错误处理、toast、语言（kit 自带每个 target 的 `Localizable.xcstrings`，
  en + zh-Hans；`language` 让 kit 用那个 `.lproj`，跟 App 内的语言切换）、`locale`、呈现方式（全屏，或自己配导航控制器：
  侧滑关闭的转场问 `YoyoPageSwipeGate`）、偏好的命名空间（`<namespace>Audio`、`<namespace>GestureCard2Shown`、
  `<namespace>DeviceId`、启动参数 `-<namespace>Loupe YES`…；缺省 `Yoyo`）、这台手机的 id、自动化的名字（「由 … 复制」）。
- **调试 / UI 测试**的启动参数（DEBUG）：`-<namespace>FullScreen YES`、`-<namespace>InputLog YES`（页面上
  `screen.debug.inputs` 的无障碍值是送出的输入种类）、`-<namespace>Loupe`、`-<namespace>PointerBadge`。

### 自己拼屏幕页（三层）

整页之外，屏幕页就是用下面三层拼的，别的 App 可以用它们拼自己的页面（布局、按钮、什么时候能操作都自己定）：

- **`YoyoScreenSession`**（没有视图，`@MainActor`）：`init(backend:controlPolicy:)`。流、播放、声音和音画同步、走哪条路、连接状态
  （`isLive` / `hasPicture`）、统计行（`statsText()`）；状态（`status`，活动时每 10 s 问一次，加后端事件）、显示器（`displays`、
  `selectDisplay`）、是谁的电脑（`computer`）、声音（`audioOn` / `setAudioOn` / `hasAudio`）；控制权（`controlModel`、`isControlling`、
  `isTakingControl`、`takeControl() async throws`、`releaseControl()`）；输入（`send`、`click` / `movePointer` / `scroll`、
  `beginDrag` / `moveDrag` / `endDrag`、`type` / `pressKey`、粘滞修饰键 `toggleModifier`）、剪贴板（`pasteOnComputer` /
  `copyFromComputer`）。**控制策略** `YoyoControlPolicy`：`.takeOnInput`（整页用：第一下真实输入先拿控制权再发）、`.explicit`
  （没拿到时输入直接丢掉，不发请求也不自动拿，只有 `takeControl()` 才拿；这时手机上「这台电脑说是 user」也不算，只认这个 session 自己拿的）。
  `start()` / `stop(release:)`：进后台自动停、放开自己拿的控制权，回前台自动接着跑。`continuesInBackground = true`
  （画中画用，缺省 false）：进后台不停（流、声音、状态、事件、走的路都照旧），回前台也不重新开始、不重新选路；自己拿的控制权
  照样在进后台时放开（拖拽抬起、排队的输入丢掉、路上的接管拿到就还），后台里画面一到就显示（平滑播放的 display link 在后台不跑）。
  音频会话还是声音自己设的 `.playback`；让 App 在后台活着（「音频、AirPlay 和画中画」后台模式、画中画真的开着）是宿主的事。
  在后台把它关掉，就当场按缺省那样停下。`viewOnly`：只看（全屏播放那样），不输入、
  放开控制权。观察：`observe { update in … }` 返回 `YoyoScreenObservation`（可以有多个，释放或 `cancel()` 就停），`update` 是
  `.changed(Changes)`（`status` / `control` / `connection` / `audio` / `computer` / `clipboard` / `modifiers` / `activity`）或
  `.notice(Notice)`（`message`：要给用户看的一句话；`tookControl`；`lostControl(.takenOver(by:) / .refused / .ended)`；
  `nudge`：来了不能拿控制权的输入，宿主的「接管」按钮可以提示一下）。`addVideoSink` 再挂一个画面的接收端（画中画之类）。
  `presenter`：照片 / 文件选择器、剪贴板页弹在哪（缺省：键盘或画面所在的页面）。
- **`YoyoScreenPictureView`**（`UIView`，`init(session:)`）：画面（视频、断线时变暗的静止画面、客户端画的指针、点击的圆环），
  在 bounds 减去 `contentInsets` 里 aspect-fit，`pictureFrame` 是显示器实际画在哪；捏合放大、双击回到适配（`zoomEnabled`），
  `onTap(zoomed)` 是单击（永远不点电脑）；只接画面上的触摸。坐标：`viewPoint(fromNormalized:)` / `normalizedPoint(fromView:)`；
  `showRipple(at:)` 在画面上画别人（比如 agent）的一下点击。连接覆盖层（重连中 / 显示不了 + Retry）默认开，`showsConnectionOverlay`。
  转场用 `pictureContentView`（画画面的那个 view）或 `snapshotView()`。一个 session 同一时间由最后建（或最后进窗口）的那个画面显示；
  正在显示的那个换父视图、换窗口、改 frame 都还是它显示，视频层不重新挂接、不清空（宿主可以整通电话只用一个画面，在小窗和全屏之间挪）。
  `videoDisplayLayer`：视频解码进去的那个 `AVSampleBufferDisplayLayer`（这个 view 活着就一直是它），给宿主做画中画
  （`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`）；kit 在别的线程往里 enqueue
  （每张立即显示，没有 timebase），宿主只把它交给画中画，不 enqueue / flush / 设 timebase。第一张视频画面之前是空的；
  断线变成静止画面时它的 view 隐藏但层里留着最后一张；只有换显示器才清空。
- **输入**：`YoyoTrackpadView(session:picture:)`：触控板面板和它全部的手势（移动、点击、双击、右键、滚动、拖拽、贴边继续、
  三指点击 `onThreeFingerTap`），手指滑出面板时震一下、亮边（`onLeftPad`），放大镜和指针旁的徽章画在画面上；只有 session 在控制时
  手势才变成输入，否则第一下触摸按策略请求输入（`.explicit` 下只 `nudge`）。`hint` / `topInset` 是面板上的字和顶上留的空。
  手势说明卡：`YoyoTrackpadView.makeGestureCard(computer:showsClipboard:)`、`showGestureCardOnce(from:)`（记在
  `<namespace>GestureCard2Shown`）。`YoyoScreenKeyboard(session:)`：一个看不见的小 view，放进哪个视图层级由宿主定，`show()` /
  `hide()` / `toggle()`，键栏是粘滞修饰键、Esc / Tab / 方向键、剪贴板键；点到能输入的地方时自己弹出（`showsForFocus`），
  `isEnabled = false` 时不弹（比如横屏）。

```swift
// 一个「先看、点按钮才操作」的页面
let session = YoyoScreenSession(backend: backend, controlPolicy: .explicit)
let picture = YoyoScreenPictureView(session: session)
let trackpad = YoyoTrackpadView(session: session, picture: picture)
let keyboard = YoyoScreenKeyboard(session: session)
[picture, trackpad, keyboard].forEach(view.addSubview)
trackpad.isHidden = true
let observation = session.observe { update in
    if case .changed(let c) = update, c.contains(.control) { trackpad.isHidden = !session.isControlling }
    if case .notice(.message(let text)) = update { showToast(text) }
}
takeButton.addAction(UIAction { _ in Task { try? await session.takeControl() } }, for: .primaryActionTriggered)
// viewWillAppear: session.start()；viewWillDisappear: session.stop()；布局时摆好 picture / trackpad 的 frame
```

版本：私有期按 commit 固定（`revision:`），另打人看的 tag `kit-vX.Y.Z`（不用纯 semver tag：会和 App 的版本混）；
kit 有改动就升 patch，不挪 tag。

## YoyoConnect

一台电脑不止一条路时（局域网捷径、公网直连、一定能通的中继 / 隧道）的选路，和怎么连无关：后端给候选、自己探测，
`YoyoConnector` 决定用哪条，页面跟着它搬流和声音（`YoyoRouting`）。

- **接法**：后端建一个 `ConnectWays(initial:link:fallbacks:)`（开始时走的路和它的链接，`Link` 由后端定：一个钉好证书的
  会话、一个 base URL、一个转发器…；`fallbacks` 是可以回落的 `relay` / `tunnel` 候选），请求时用 `ways.link(for: route)`、
  `ways.trust(for: route)`；`makeRouting()` 返回 `YoyoConnector(ways:source:policy:)`。`ConnectSource` 三件事：
  `candidates(why)`（捷径候选；`nil` = 这台电脑没有别的路，本次不再试；抛错 = 一会儿再问；`ConnectSupply.fresh` /
  `expires` 说是不是刚要来的、凭证什么时候过期）、`probe(candidate)`（`.reached(link, as:)`：一个候选代表多个地址时
  `as` 是真正答应的那个；`.unauthorized`；`.unreachable`）、`release(link)`。
- **竞速**（`ConnectPolicy.offsets`，可改）：`lan` 立即、`direct` 150 ms 后、`relay` / `tunnel` 300 ms 后，相对于在场最好的一种
  （没有 `lan` 候选时 `direct` 立即开始）；先探到的胜出，其余取消，晚到的链接释放。只有比当前更好的候选参赛。
- **Link**（候选种类 `.link`，排最前）：它先跑，别的 250 ms 后才起（它先连上就不起）；别的先连上就先用着，`linkGrace` 1.5 s
  内 Link 连上还是换过去；它在跑时要开的流等它（最多 `decisionWait`）。宿主设 `linkPossible` 后，在任何别的路上都每 30 s 再试
  Link；`ConnectSource.ended` 说链接自己断了（会话结束）：回落、马上再竞速。换网络不离开 Link（它自己换路径）。
- **什么时候试**：页面出现、流要开（`isDeciding` 时流最多等 `decisionWait` 600 ms）、在差的路上每 `retryInterval` 30 s、
  网络路径变化后（`pathSettle` 300 ms）。`lan` 候选只要有 Wi-Fi / 有线接口就试（默认路由在蜂窝上也算：Wi-Fi 助理），
  `direct` 任何网络都试。丢了接口 / 断网：捷径立刻回落再重选；多了接口：从当前的路往更好的找（5G 直连 → 局域网，不经回落）。
- **捷径**（有回落时的 lan / direct）：流失败、连续 3 个确认没回来、请求在链路上失败（`ConnectFailure.classify`：
  电脑自己的回答 409 / 404… 照原样交给页面，不重发）立刻回落（请求在回落的路上重发一次），30 s 内不再试；
  回落的路没连着时先把它连上（`fallbacks` 竞速）。
- **凭证**：手里的候选（`fresh == false`）试不通、或快过期（`renewBefore` 10 min 内），马上再要一次新的；路上 401 →
  先回落，立刻用新凭证（`.unauthorized`）再试一次，再 401 算失败（之后有确认通过就又允许）。用着的捷径凭证会过期时
  提前 `renewBefore` 续期（`.renew`）：新的候选里还有它就留着，没有了（换了票据 / 端口 / 证书）回落重选。
- `leave()`：停掉竞速和计时器，捷径回到手里的回落（下次出现重选），旧链接留 `keepRetired` 5 s 给最后一个请求（比如交还控制权）；
  `close()`：页面没了，所有链接释放。`setShortcutsAllowed(false)`：这台电脑不能走捷径。

### Yoyo Control 自己的候选（`DirectConnect`）

只有一个：Mac 的 Link 会话（候选 `link`，`linkPossible` 开着）。它在哪条路径上（局域网、公网直连、打洞、中继）由 iroh 自己选、自己换，
统计行写 `link lan / direct / punched / relay`；路径在局域网时用局域网的播放参数（`onLan`）。会话断了 YoyoConnector 马上拨一个新的。

## Yoyo Control Pro

局域网连接免费；Pro 解锁「不在同一局域网」的连接（经中继 `../docs/RELAY.md`、外网直连 `../docs/REMOTE.md`「外网直连」、打洞，或用户自己的 Tailscale）。界线是
Link 会话的路径：对端地址是私有 / 链路本地 / ULA 算局域网（`YoyoLinkConnection.isLocalNetwork`，`RemoteAccess.allows(onLocalNetwork:pro:)`）；
中继、公网地址、100.64/10 都不算。

- 商品：订阅组「Yoyo Control Pro」，`ca.sarria.yoyocontrol.pro.monthly`（$2.99 / 月）和
  `ca.sarria.yoyocontrol.pro.yearly`（$19.99 / 年，新用户 1 周免费试用），都开家人共享。
- `ProStore`（StoreKit 2）：`hasPro` 来自 `Transaction.currentEntitlements`（只认验证过、没退款的这两个商品），
  启动时读一次，`Transaction.updates` 每来一条、购买和恢复购买之后都再读。App 启动就建好它，整个生命周期都在。
- 连 Mac 时（`YoyoClient.connect(_:deviceId:pro:unpaired:)`）拨 Link（记录里的绑定；没有、或拨不通时问一次信令服务）。没有 Pro：会话要在
  1.5 s 内落在局域网路径上（iroh 同时试局域网地址和中继，中继可能先答），否则抛 `Failure.needsPro`，App 弹付费墙（`ProPaywall`：StoreKit 的
  `SubscriptionStoreView` 加上说明、恢复购买、条款 / 隐私链接），买到或恢复后接着连那台 Mac。已经打开的屏幕页不受影响。
  `/status` 的 `link` 和 `platform` 记进 `YoyoMac`（App 保存 `connect` 返回的 Mac）。
- TestFlight 版本（`AppTransaction.environment == .sandbox`）和开发者装的版本（Xcode、`devicectl`：App 里带着
  `embedded.mobileprovision`，App Store / TestFlight 的没有）不用买就算有 Pro（`ProStore.isTestBuild`），测试者能试所有连法；
  App Store 版照旧要买。
- 本地测试：从 Xcode 运行用 `App/YoyoControl.storekit`（scheme 的 StoreKit Configuration），不连 App Store；
  TestFlight 用沙盒账号买真的商品。`-YoyoShowPaywall YES`（DEBUG）启动就打开付费墙，截图用；
  `-YoyoSignalURL https://…`（DEBUG）换一个信令服务，`-YoyoAssumePro YES` 当作已经买了 Pro。

## 账号

`../docs/ACCOUNT.md`。App（`AccountStore.swift`、`AccountView.swift`）：工具栏左边的人像按钮 → 通过 Apple 登录（`com.apple.developer.applesignin`，
`project.yml` 的 entitlements）→ signal1 的会话存钥匙串（`ca.sarria.yoyocontrol.account`，只在本机）。登录后 App 在前台时每 10 s：拉目录（电脑的
声明逐条核签名才显示）、把本机配对过的电脑经 Link 加入账号（`YoyoClient.call(_:method:path:body:)`，`POST /account/join`）、看其他 iPhone 的请求
（替本机配对过的电脑弹「允许“…”连接？」，允许就 `POST /account/invite` 要定向码交给服务）。列表多一节「你账号里的电脑」：本机还没配对的，点
「申请连接」等另一台 iPhone 允许，拿到码后照常配对（`YoyoClient.invite(id:name:fingerprint:code:)`）。Pro 的最新交易（`ProStore.proTransactionJWS`）上报给账号。
kit 为此加了（都是新增）：`YoyoClient.call`、`YoyoClient.invite`、`YoyoClient.linkId`（`YoyoLinkClient.linkId`）、`YoyoInvite(id:name:…:link:)`、
`ProStore.proTransactionJWS`。

App 里屏幕页只经 `YoyoBackend` 跟 Mac 说话，用的是 `DirectBackend`：请求都是 Link 会话上的 RPC，画面、声音、指针、输入走会话自己的通道
（`screenLink(for:)`），凭配对令牌认手机；剪贴板只收发文本（远程不收 Mac 上的路径）。路径在局域网时（`DirectBackend.onLan` → `route.isLocalNetwork`），
播放的交互深度（预算为 0：解出来就显示）、起始缓冲（10 ms）和声音的抖动下限用局域网的值（声音 80 ms）；其他路径用远程路径的默认值（声音 120 ms，
平滑播放的缓冲上限 200 ms 而不是 100 ms）。