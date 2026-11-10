# 本机 API：给同一台 Mac 上的程序用

Yoyo Control.app 在本机的一个 unix socket 上提供 HTTP API：本账号下的任何程序（自动化工具、别的 App、脚本）都可以
用它看屏幕、听声音、点击 / 打字、读写剪贴板、标出「正在被自动操作」。本文是本机使用方要知道的约定：怎么找到它、
怎么判断能不能用、兼容承诺，以及几个专门给本机使用方的能力。每个接口的参数见 `mac/README.md`「HTTP API」，
视频流 / 声音 / 输入的细节见 `PROTOCOL.md`，手机远程访问（uu Link、配对）见 `REMOTE.md`。

## 找到它

- **身份**：bundle id `ca.sarria.yoyocontrol.mac`，App 名 `Yoyo Control.app`。
- **固定的 socket**：`~/Library/Application Support/YoyoControl/screen.sock`。目录 0700、socket 0600：只有本账号能连。
  App（不带参数启动的 `yoyo-control`，菜单栏常驻、开机自启）在这里跑服务；同一个 home 只有一个 App（`app.lock` 上的 flock）。
- **`GET /status` 说明是谁**：每个回答（`ok` 与否）都带
  - `app: "YoyoControl"`：只认这个值的回答；别的东西在这个路径上应答 → 当作没有。
  - `version`（CFBundleShortVersionString，未打包时 `"dev"`）、`build`（CFBundleVersion，未打包时没有）。
  - `api`：整数，现为 **1**。HTTP API 有不兼容的变化时 +1；新增字段、接口、参数不加。使用方应声明自己支持的范围，
    超出范围按「需要更新 Yoyo Control / 需要更新自己」处理。
- **建议的发现顺序**：
  1. 连固定 socket（2 s 超时），`GET /status` 回答 `app == "YoyoControl"` 且 `api` 在支持范围内 → 用它。
  2. 没应答而 `/Applications/Yoyo Control.app` 或 `~/Applications/Yoyo Control.app` 存在 → `open -g -j <path>`（后台、
     不抢焦点），每 200 ms 探测一次，最多约 10 s → 回到 1。不建议用 Spotlight 找：它会找到各处构建目录里的旧版本。
  3. 都没有 → 告诉用户去安装。

  Node 程序可以直接用 `@yoyocontrol/local`（`packages/local/README.md`）：它按这个顺序找（也能自己拉起服务、或连一台远程的服务端），
  按调用方声明的 `api` 范围判断，保持一条 `/events` 并在断开后重连，剪贴板、流与声音的转发也在里面。
- **生命周期是 App 自己的**：服务是 App 的子进程，崩溃 / 声音失聪（exit 75）由 App 重启，缺屏幕录制权限时 App 也会定期重启
  服务以看到新授权。使用方只会看到 socket 短暂断开：`/events` 断了就重连，连不上就过一会儿再按发现顺序找。使用方不要杀它。
- 日志：`~/Library/Logs/YoyoControl/yoyo-control.log`（App 和服务的都在里面）。

### 自己拉起服务（开发用）

`yoyo-control --socket <path> --exit-on-stdin-eof` 直接跑服务，作为调用方的子进程（用 `YoyoServer` 库的 `ServiceHost`
搭的服务一样，见 `mac/README.md`「Embedding the service」）：stdin 断开（父进程没了）它就退出并删掉
socket；exit 75 表示「请马上再起一个」（不计失败、不退避），其它退出按 1 s 起翻倍、最多 60 s 退避。权限按
`Yoyo Control.app` 的签名记（启动时以 TCC responsibility disclaim 重新拉起自己），所以要用打包好的 App 里的可执行文件。
这样跑起来的服务没有远程访问。

## 兼容承诺

- `api` 不变时只做兼容的新增：新字段、新接口、新的可选参数。使用方要忽略不认识的字段（包括 `/status.features` 里不认识的键）、
  `/events` 里不认识的 `type`、流里不认识的分段类型。
- 改名时旧名字保留（不设期限）：`POST /agent-control` = `POST /automation`；`/status` 的 `agentControl` = `automation`
  （少一个 `label`）。
- 2026-11-01：发布前的另一套名字删掉了（流与声音的旧媒体类型和旧边界、`/clipboard/file` 的旧文件名头、环境变量 `YOYO_AUDIO`
  的旧名）。现在只有一套：下面「流的媒体类型」、`Content-Disposition`、`YOYO_AUDIO`。`api` 仍为 1。
- 远程控制优先：配对的手机拿着控制权时，本机 socket 上的 `POST /input` 回 409
  `{ error, code: "controlled-elsewhere", controllerDevice: { id, name } }`。`/status` 的 `control` 和 `/events` 的
  `{"type":"control",…}` 说明现在谁在控制（`REMOTE.md`「控制权」）。本机使用方不是控制者：没有手机拿着时照常输入。

## 本机自动化：`POST /automation`

程序要替用户操作这台 Mac 时，先告诉 Yoyo Control，让用户看得见、停得下：

- `POST /automation { active: true, label?: "Claude" }` → 每块屏幕一圈橙色呼吸边框，顶部胶囊
  「Claude 正在使用这台电脑 · 按 Esc 停止」/ "Claude is using this computer · press Esc to stop"（按系统语言；没有 `label` 时是
  「自动化程序正在使用这台电脑」/ "Automation is using this computer"）。`label` 是谁在操作（一行，≤ 40 个字符，控制字符变空格），
  文案由 Yoyo Control 按系统语言组织，使用方不用管本地化。active 期间再发一次带新 `label` 的请求会重画胶囊。
- active 期间，用户按下不带 ⌘ ⇧ ⌥ ⌃ 的 Esc（不是本进程发出的；经 `/input` 发出的键不算）→ 吞掉这个键、结束 active，
  `/events` 发 `{"type":"abort","reason":"esc"}`。使用方收到后应当停下。没有辅助功能权限时装不上这个键盘监听：回答的 `esc: false`，
  胶囊也不提 Esc。
- `POST /automation { active: false }` 收起。使用方退出前、做完一轮操作后都应当发；Yoyo Control 不会替它超时收起。
- 回答 `{ ok: true, active, esc, label? }`；`/status` 的 `automation` 同样形状。边框窗口从不出现在任何画面里。
- 只有一个状态：两个使用方同时用会互相覆盖。
- 旧字段 `title`（在做什么）接受但不显示。

## 锁屏与解锁：`/console/*`

本机使用方可以替用户锁上 / 解开这台 Mac 的控制台。只在 unix socket 上（配对的手机经 Link 来是 404），只在服务所在账号的图形会话
**就是控制台上的那个**时可用（快速切换用户后在后台的会话回 `not-console`）。同一时间只跑一个：后来的请求等前一个做完，再重新看一遍。

**解锁** `POST /console/unlock { password }` → `{ ok, unlocked, already?, reason? }`。密码由调用方给（Yoyo Control 不存密码）。一次调用
做完整个流程：

1. `IOConsoleLocked` 不是真：`{ ok: true, unlocked: true, already: true }`，**一个字都不输**。
2. 唤醒显示器（`IOPMAssertionDeclareUserActivity`，等同 `caffeinate -u`），等它亮（≤ 3 s；没亮：`display-asleep`，一个字都没输）。
   显示器黑着时输的键会被锁屏吞掉（实测），还算一次输错。刚醒来的再等 0.5 s。
   然后**再读一次 `IOConsoleLocked`**，仍是锁屏才在锁屏的时钟处（主显示器水平居中、从上往下 35%）点一下左键，**总是**再等 1.3 s：
   锁屏放久了会进入空闲（macOS 27：时钟、头像、密码框都藏起来，只剩墙纸，显示器是亮的），声明用户活动和挪指针都叫不回来，输的字就落空
   （实测：`timeout`、失败计数不动）；点一下约 1.2 s 内密码框就回来了。此刻已经解开就不点（点下去会落在某个 App 上），回 `already`。
3. 一个字一个字地输，**每个字之前都再读一次 `IOConsoleLocked`**：途中被别的方式解开了（有人在 Mac 前、Touch ID、Apple Watch）就立刻停，
   不按回车，回 `{ ok: true, unlocked: true, already: true }`——剩下的密码不会打进某个 App 的输入框。
4. 回车，等解开（≤ 5 s）：`{ ok: true, unlocked: true }`。
5. 没解开：`{ ok: false, unlocked: false, reason }`。`wrong-password`：账号的失败登录计数（`accountPolicyData` 的 `failedLoginCount` /
   `failedLoginTimestamp`，输错后约 0.5 s 就变）动了，或者读不到这个计数（读不到时按输错报，让调用方停手）；`timeout`：计数读得到、没动，5 s 内也没解开。

- **不重试**：输错几次后 macOS 会加延迟甚至停用账号。`wrong-password` 之后调用方应当停用自己的自动解锁，直到用户换了密码。
- 密码只在服务自己的缓冲区里（不经 Foundation 的 JSON），用完清零；请求体和密码都不进日志。日志只有
  `console: unlocked in 2.1 s` / `console: unlock: wrong password …` 这样的行。
- 发出的按键是服务进程自己的事件，不算「别处来的输入」。
- 状态码：body 不是带 `password` 字符串的 JSON 对象、空、超过 1024 个 UTF-16 单元、含控制字符：400；需要输入而没有辅助功能权限：403；
  其余结果都是 200 + 上面的形状。`reason` 是开放集合：`wrong-password`、`timeout`、`display-asleep`、`not-console`。

**锁屏** `POST /console/lock`（无 body）→ `{ ok, locked, already?, reason? }`：已经锁着 `{ ok: true, locked: true, already: true }`；否则调
`SACLockScreenImmediate`（私有的 login.framework，菜单栏「锁定屏幕」用的那个；不需要权限），1 s 内没锁上（或没有这个函数）再按
Ctrl+Cmd+Q（要辅助功能权限）。显示器保持亮着。等锁上（≤ 3 s）：`{ ok: true, locked: true }`；否则 `{ ok: false, locked: false, reason }`，
`reason`：`timeout`、`not-console`、`no-permission`（没有那个函数，也没有辅助功能权限按快捷键）。

两条成功后 `/status` 的 `console` 和 `/events` 的状态行立即反映结果（不等控制台监视那 1.5 s 的稳定时间，`docs/PROTOCOL.md`「连接状态」）。

## 别处来的输入：`input-elsewhere`

服务在跑、有辅助功能权限时，它看着这台 Mac 上所有的键盘 / 鼠标 / 触控板输入（按键、修饰键、各个键的按下 / 抬起 / 拖动、
指针移动、滚动；一个只放行不改的事件 tap，不要「输入监控」权限）。**不是它自己发出的**（经 `POST /input` 发的都不算，不论来自
手机还是本机使用方）就是「别处来的输入」：

- `source: "hardware"`：没有发出它的进程，是 HID 系统来的：有人在用物理键盘、鼠标、触控板（虚拟 HID 驱动也算这一类）。
- `source: "process"`：别的进程发的事件（`pid`；是 App 的话还有 `app` 名字和 `bundleId`）：远程桌面工具、别的自动化程序等。

通知方式：

- `/events` 一行 `{"type":"input-elsewhere","at":<1970 年起的 ms>,"source":…,"pid"?:…,"app"?:…,"bundleId"?:…}`：一段输入的
  第一下立即发，持续时至多每秒一行。
- `/status` 的 `inputElsewhere`：最近一次（`{ at, source, pid?, app?, bundleId? }`），没有过为 `null`。
- `/status.features.inputElsewhere`：此刻在看（`true`）；没有辅助功能权限时 `false`（每 3 s 重试，授权后自己开始）。

Yoyo Control 自己不因此做任何事（`/automation` 照旧），怎么用由使用方决定。典型用法：自动化程序替用户操作时，看到最近几秒有
`input-elsewhere` 就先停手（有人在用这台 Mac），安静几秒后再继续，或者去问用户。用 `YoyoServer` 库搭自己服务的 App 可以用
`ServiceHost.Options.watchInputElsewhere = false` 关掉它。

## 不让别人看到的 App：`hide=`

给自动化看的画面（`GET /frame?visible=`）和单个窗口（`/app/screenshot`、`/app/ax`）里，Yoyo Control 自己的窗口永远不出现。
使用方要把自己的 App 也藏起来（免得自动化看到、点到它），在请求上带 `hide=<bundleId,…>`：

- 逗号分隔的 bundle id，不分大小写；结尾的 `*` 匹配前缀（`com.example.mine*`）。最多 64 个；不像 bundle id 的条目 → 400。
- `/frame`：从 `visible=` 里去掉被藏的 App（`hide` 优先）；遮盖模式下被藏的 App 的色块不写名字。没有 `visible=` 的 `/frame`
  是原样的整屏画面，`hide=` 不起作用。
- `/app/screenshot`、`/app/ax`：被藏的 App 的窗口 → 403。
- `/windows`、`/hit`、`/app/windows`、`/stream` 不看 `hide=`：前三个只给元数据，使用方自己过滤；`/stream` 是给人看的画面。

## 系统浮层：通知横幅这一类

有些系统进程把自己的界面画在一个盖满整块屏幕、大部分透明的窗口里，层级在 App 之上（macOS 27：通知中心的横幅和面板在
一个 level 21 的全屏窗口里；程序坞、WindowManager、控制中心也各有一个什么都不画的）。窗口列表只知道整个窗口，所以：

- `/windows`、`/hit`、`/frame?visible=` 的遮盖、`/app/windows`：这种窗口只按辅助功能里看得到的部分算（`mac/README.md`
  `/windows` 一行）——画着横幅的地方是通知中心的，旁边透明的地方还是下面那个 App 的；什么都没画（或没有辅助功能权限）就当它不存在。
- `/hit`：最上面是浮层（弹出框、浮动面板、横幅）时，再问一次系统自己的命中测试（`AXUIElementCopyElementAtPosition`），
  浮层在那一点透明就往下找；不会越过普通窗口、菜单栏和锁屏。
- `/app/screenshot`、`/app/ax`：这种窗口只给画着东西的那一块（图和元素坐标都相对这一块）；什么都没画 → 409。
- 应用的 `englishName`（与本地化的 `name` 不同时才有，如 en-CA 的 "Notification Centre" / "Notification Center"）：
  使用方按英文名找 App 时用。

## 菜单栏：`/hit` 按区域算主人

macOS 27 的整条菜单栏（App 菜单和所有状态图标）在窗口列表里只是 Window Server 的一个 main-menu 层窗口（全屏 App 在刘海屏上
顶部那条黑边、移上去才露出菜单栏的地方也是它），状态图标没有各自的窗口，所以 `/hit` 在菜单栏里问辅助功能（`mac/Sources/YoyoServer/MenuBar.swift`）：

- 状态图标 → 持有它的 App：先看每个 App 自己的 `AXExtrasMenuBar`（macOS 27 的时钟 / Wi-Fi / 控制中心按钮 / 正在播放 /
  用户切换是 `com.apple.MenuBarAgent`，旧系统是 `com.apple.controlcenter` / `com.apple.systemuiserver`，输入法菜单
  `com.apple.TextInputMenuAgent`，第三方 App 的是它们自己的），
  再看系统命中测试找到的菜单项；`menuBar: "statusItem"`。
- 苹果菜单（每个 App 菜单栏的第一项）→ 固定的 `{ bundleId: "com.apple.AppleMenu", name: "Apple menu" }`（pid 是画它的前台 App）：
  里面是重启、关机、退出登录、强制退出、系统设置这些系统的命令，不是前台 App 的；`menuBar: "appleMenu"`。
- App 的菜单标题 → 那个 App（前台 App：操作它的菜单就是操作它）；`menuBar: "appMenu"`。
- 菜单栏其余地方（菜单和图标之间、刘海、全屏时隐藏菜单栏的那条）→ 前台 App（移上去露出的是它的菜单）；`menuBar: "bar"`。
- 菜单栏里从不答 Finder（除非前台 App 就是 Finder）；Finder 只是真正桌面的主人。控制中心、SystemUIServer 也不再算 Finder 的
  （`/windows` 里是各自的 App，控制中心面板要授权控制中心）。
- 没有辅助功能（或会话切到后台，-25204）、或有 App 没及时回答而那一点可能是它的图标：`app: null`（不知道是谁的）。
  「可能是」= 这条菜单栏上已知最左边的状态图标左边 40 pt 往右（图标从右往左挨着排，没回答的 App 的图标只会在这一段）；
  一个图标都不知道时整条都算。菜单和图标之间的空白照样是前台 App 的。macOS 27 上时钟、Wi-Fi、控制中心、正在播放、
  快速用户切换这些在 `com.apple.MenuBarAgent` 的 `AXExtrasMenuBar` 里，答的就是它。
  旧 macOS 上 App 自己的状态图标窗口（status 层、属主是那个 App）不用辅助功能也认得。
- 画面：苹果自己的菜单栏窗口总是在；别的 App 在菜单栏层的窗口（旧 macOS 的状态图标）只在它可见时出现，遮盖模式下盖住。
  macOS 27 上别的 App 的图标画在 Window Server 那一个窗口里，ScreenCaptureKit 没法单独去掉，所以还看得见。

## Link 的主人：`/link/*`（主人模式）

用 `YoyoServer` 搭自己服务的程序可以开 uu Link 的监听（`LINK.md`「服务端：Mac」，`ServiceHost.Options.link` /
`ScreenService(link:)`）并选**主人模式**（`LinkOptions(authority: true, keyDirectory: …)`）：谁能开 Link 会话、谁能控制屏幕，
由本机的一个程序（主人）决定，Yoyo Control 只问、只照办；凭据和身份对它是不透明的。只在 unix socket 上（远程一律 404），
不是主人模式的服务也是 404。

- `GET /link/authority`：主人的通道，NDJSON，一直开着；同时只能有一个（第二个 409）。发给主人的行：
  - `{"type":"auth","id","credential","device":{"id","name"},"source"}`：有手机的 `hello`（`credential` 原样，`device` 是手机自报的，
    `source` 是来源地址或 `relay <url>`）。
  - `{"type":"control","id","device":{"id","name"},"want":"take"|"release"}`：会话要 / 放控制权（`device` 是主人给的身份）。
  - `{"type":"session","event":"opened"|"closed","device"}`。
  - `{"type":"activity","device"}`：这台设备的输入进来了（每台每秒至多一行）。
- `POST /link/authority/answer`：`{"id","ok":true,"principal":{"device":{"id","name"},…}}` 放行（`principal` 原样进 `welcome`，
  之后按 `principal.device` 认人）或 `{"id","ok":false,"code":"unauthorized"|"rate-limited"|"busy","message"?}` 拒绝 → `{ ok: true }`；
  不认识（或已超时）的 `id` 404，body 不对 400。3 s 没回答 = `busy`。
- `POST /link/control`：`{"holder":{"id","name"}|null}` → `{ ok: true, holder }`：现在谁能发输入。别人的输入被拒（`input.rejected`
  `controlled-elsewhere`，没人持有时 `no-control`）；每次变化发给所有会话（`control`，`granted` 按各自的设备算）。会话的
  `control.take` 只是告诉主人，由主人决定改不改。
- 主人断开：新的会话被拒（`busy`），已有的会话照常；持有者变成 `null`。没有主人连着时同样 `busy`。
- 主人模式下 Link 来的输入在路由看来是本机 socket 的输入（主人已经决定过），远程手机的控制权（`POST /control`）照旧有效：
  有手机拿着时它们也会 409。

## 浏览器的 Link：`POST /link/rtc`

uu Link 的 WebRTC 那一路（`LINK.md`「WebRTC」）：浏览器拨不了 QUIC，它把 WebRTC 的 offer 经某条路交给 Mac，拿回签过名的 answer。
本机程序替自己的客户端转交 offer 时用这个（主人模式也行：之后 `hello` 照样问主人）。只在 unix socket 上（远程 404）。

- 请求体 = 浏览器的 offer JSON（`{"v":1,"offer":"<SDP>","device":{"id","name"}}`，≤ 64 KiB），回答 200 = answer JSON
  （`{"v":1,"answer","fingerprint","binding","sig"}`），原样交回浏览器；会话之后在 WebRTC 上自己连、`hello`。
- 404：Link 没在跑，或 WebRTC 关着（`LinkOptions.rtc`）；400：offer 不对；429：来源被守卫冷却；503：会话或还没认证的会话满了
  （同时最多 4 个没 `welcome` 的，含 QUIC 的）；504：15 s 没答。错误体是 `{ error }`。
- `/status.link.rtc = { port, direct? }`：WebRTC 的 UDP 端口（默认 Link 端口 + 1，即 47821）和路由器给它的映射（有时）。
- 选项（`LinkOptions`）：`rtc`（默认开）、`rtcPort`（nil = Link 端口 + 1）、`stunServers`（默认空）；环境变量 `YOYO_LINK_RTC_PORT`
  （`off` 关掉）。

## 流的媒体类型

`GET /stream` 和 `GET /audio` 的回答是同一种 multipart 分段格式（`PROTOCOL.md`「媒体类型」），只有一套名字：

| 用途 | 名字 |
| --- | --- |
| `/stream` 回答 | `application/vnd.yoyo-control.stream; boundary=frame` |
| `/audio` 回答 | `application/vnd.yoyo-control.audio; boundary=frame` |
| 指针分段 | `application/vnd.yoyo-control.cursor+json` |
| 状态分段 | `application/vnd.yoyo-control.status+json` |

分隔符从回答的 `Content-Type` 读。请求带不带 `Accept` 都一样（2026-11-01 以前不带它会得到旧名字）。

## Linux 版（`linux/`，无头）

上面讲的是 Mac：App、固定 socket、发现顺序。Linux 上的服务端（`linux/README.md`）没有这些：使用方自己把它起起来（解开发布包，
`node server.mjs --host … --port … --token-file …`，或令牌经 stdin），自己管它的生命周期，经 **TCP + `Authorization: Bearer <令牌>`**
连它（不是 unix socket）。之后是同一套接口：

- **是谁**：`/status` 的 `app` 是 `"yoyo-linux"`（只认这个值的回答），`api` 同为 1，`version` 是发布包的版本；另有 `platform: "linux"`
  与 `features`（此刻能做什么，开放集合；`docs/PROTOCOL.md`「Linux 服务端」）。Mac 版不发 `platform`，`features` 里只有 `inputElsewhere`：使用方要接受缺省。
- **兼容承诺同上**。
- **没有的**：`/console/unlock`、`/console/lock`、`/app/*`、`/focus`、`/control`（都是 404）；不会因为控制权回 409。0.8.0 起有 `/windows`、`/hit`、
  `/frame?visible=&hide=&crop=`（盖住）和 `/automation`（不画边框；App 的身份是 WM_CLASS 的 class，`features.windows` / `features.automation`），
  差别见 `docs/PROTOCOL.md`「Linux 服务端」。
- **浏览器的 Link**：同样的 `POST /link/rtc` 在令牌监听上（Link 在跑时：`--remote` 或主人模式；`--link-rtc-port <端口|off>`，
  默认 Link 端口 + 1；`--link-stun host:port`）。`--advertise` 的地址也在 WebRTC 端口上给出。
- **Windows**（`windows/`，同一个服务）：`app` 是 `"yoyo-windows"`、`platform: "windows"`；`install.ps1 -LocalPort 7380` 让它另听
  `127.0.0.1:7380`，令牌在状态目录的 `token`（那个用户、SYSTEM、管理员能读）。服务跑在登录用户的会话里（会话 0 的程序也能经回环连它）。
- **Link 的主人**：带 `--link on --link-home <目录>`（不带 `--remote`）时，上面「Link 的主人」的三个路由在令牌监听上（同样的行与回答；
  没开时 404）。`/status.link` 多一个 `fingerprint`：签绑定的身份钥匙的指纹，主人连同绑定交给手机。Link 会话的 RPC 只有 `GET /status`。
  使用方按 404 / `features` 关掉对应的功能。
- **令牌**：至少 16 个字符，进程活着时不变（换令牌 = 重起它）。一个回答 401 的服务端 = 令牌不对（被别人以别的令牌重起过）。
