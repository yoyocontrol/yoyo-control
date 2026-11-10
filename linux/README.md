# yoyo-linux：Yoyo Control 的 Linux 服务端（无头模式）

把一台 Linux 的 X 显示（Xvfb 这样的虚拟桌面，或者现成的 X11 会话）经 **Yoyo Control 的 HTTP API**（`api: 1`）给出去：
看画面（H.264 流、单帧 JPEG）、听声音（Opus）、点击 / 打字 / 滚动、读写剪贴板，以及自动化程序要的窗口列表、命中测试、只露某些 App 的单帧和「正在自动化」的状态。和 Mac 版是同一套接口与语义
（`docs/PROTOCOL.md`，流控与码率的数照 `mac/Sources/YoyoServer/StreamFlow.swift`），只是**无头**：没有菜单栏 App，监听一个 TCP 地址，
每个请求带 Bearer 令牌。适合云主机、开发机、家里的 Linux 小机器，或者任何「自己起一个虚拟桌面、让客户端来看」的程序。加上
`--remote` 还能像 Mac 一样让 Yoyo Control 的 iPhone App 配对、直连（局域网、路由器的端口映射）或经中继连上（下面「远程访问」），
并且走 uu Link（UDP，下面「uu Link」）。这里只写这个实现自己的事；它和 Mac 版不同的地方（`platform`、`features`、键名 `insert` 等）是协议的一部分，写在
`docs/PROTOCOL.md`「Linux 服务端」。

| 文件 | 内容 |
| --- | --- |
| `server.mjs` | HTTP 服务（入口）、鉴权、路由；`pair` / `devices` / `remove` / `disconnect` / `status` 命令 |
| `platform.mjs` | Linux 与 Windows 的不同：辅助程序的名字、`/status` 的 `app` / `platform`、`/frame` 怎么截。这些 `.mjs` 也是 Windows 版的服务（`windows/README.md`） |
| `qr.mjs` | 配对码的二维码（`pair`：没有 qrencode 时的终端二维码，`--page` 的网页） |
| `remote.mjs` | `--remote`：远程访问（监听的开关、配对、远程的路由、中继、端口映射、管理 socket），建在 `@yoyocontrol/remote` 上 |
| `link.mjs` | uu Link（UDP / QUIC）：`--remote` 时跟着远程访问，或无头的主人模式（`LinkAuthority`）；会话、视频（x264 → Link 的媒体层）、声音、指针、输入、RPC 走现有路由 |
| `control.mjs` | 控制权（`--remote` 时）：谁在控制、409、10 分钟放开 |
| `vendor/remote/`、`vendor/link/` | `@yoyocontrol/remote`（连同它带的 `@yoyocontrol/portmap`）和 `@yoyocontrol/link` 编好的 JS，提交在仓库里：不用装 npm 包；`./vendor.sh` 重新生成。Link 的原生插件 `uu-link.linux-<arch>-gnu.node` 不提交，在发布包里 |
| `video.mjs` | 一条流的循环（只在画面变了时编码、≤ fps、窗口、refine、保活、指针分段）与 `yoyo-x11video` 进程 |
| `cursor.mjs` | `cursor=client`：一条流的指针（位置、形状、可见性），形状的 id 与 PNG 缓存 |
| `png.mjs` | 指针的 PNG（预乘 → 直通 alpha、zlib）与内置箭头（`shapeId 0`） |
| `audio.mjs` | `/audio`：共用的一份采集（`yoyo-pa-opus`）、每个客户端的队列、分段 |
| `clipboard.mjs` | `/clipboard*` 与 `/events` 的 `clipboard` 行，经 `yoyo-x11clip` |
| `windows.mjs` | `/windows`、`/hit`、`/frame` 的 `visible=` / `hide=`（盖住）与 `crop=`，经一次性的 `yoyo-x11windows`（见下「窗口」） |
| `automation.mjs` | `POST /automation`（`/agent-control`）与 `/status.automation`；Esc 经 `yoyo-x11windows --esc`（见下「自动化」） |
| `flow.mjs` | 确认、窗口、按排队延迟调码率、网络档位、网络质量、播放报告（纯逻辑） |
| `input.mjs` | `/input` 的校验与到 xdotool 命令的映射、滚动的节奏与惯性（纯逻辑） |
| `wire.mjs` | 媒体类型、分段字节、`yoyo-x11video` 的记录格式 |
| `x11video.c` | `yoyo-x11video`：XDamage + 指针轮询报「变了」，收到命令才 MIT-SHM 截屏、画上指针（XFixes）、BGRX → I420（BT.709 limited）、x264 编一帧；`--cursor client` 时指针不画、改报 `'P'` 记录 |
| `pa-opus.c` | `yoyo-pa-opus`：录 PulseAudio 的一个源（默认 sink 的 monitor），libopus 编 20 ms 一包，时间戳照 `AudioTimeline` |
| `x11clip.c` | `yoyo-x11clip`：XFixes 报 CLIPBOARD 换了拥有者 → 取 TARGETS 与内容（INCR）；写入时拥有 CLIPBOARD 与 PRIMARY |
| `x11windows.c` | `yoyo-x11windows`：一次性，按叠放次序列出根窗口下看得见的窗口（WM_CLASS、`_NET_WM_PID`、窗口类型与状态、外框）和 `_NET_ACTIVE_WINDOW`，一个 JSON；`--esc`：常驻，XInput 2 的原始按键里不是 XTEST 来的 Esc 报一行 |
| `build.sh`、`release.Dockerfile` | 发布包：在 Docker 里为 arm64 / amd64 编出四个辅助程序和 Link 的原生插件，和 `.mjs` 一起打成 tar（见「发布」） |
| `test/` | `node --test test/`：纯逻辑与假进程下的 HTTP 服务（`test/fakes.mjs` 假扮辅助程序、xdotool、ffmpeg，不需要 X），远程访问的生命周期与控制权；`link.test.mjs` 是真的 Link 会话（要原生插件，`YOYO_LINK_NATIVE`，没有就跳过） |
| `demo/` | 一台拿来试的 Linux 机器（Docker：Debian bookworm、Xvfb + Xfce、PulseAudio、`--remote`），见「试一台」 |

## 要求

- **支持的基础系统：Debian 12（bookworm）**，arm64 或 amd64。发布包里的四个辅助程序是在 `debian:bookworm-slim` 上编的，动态链接
  这个版本的库：`libx11-6 libxext6 libxdamage1 libxfixes3 libxi6 libx264-164 libpulse0 libopus0`（装上这些就能跑）。别的发行版 / 版本
  从源码编（下面「从源码跑」）。
- **node ≥ 22.2**（`zlib.crc32`），不需要 npm 包。uu Link 的原生插件要 glibc ≥ 2.36（Debian 12）。
- **X server**：带 XDamage、XFixes、MIT-SHM、XInput 2 扩展（Xvfb、Xorg 都有）；`DISPLAY`（和需要时的 `XAUTHORITY`）在环境里。只看一个屏幕。
  Wayland 不支持。
- **xdotool**（输入）、**ffmpeg**（`/frame`，x11grab）。
- **PulseAudio**（或 PipeWire 的 pulse 兼容层；声音，可选）：录默认 sink 的 monitor，照常找服务（`$PULSE_SERVER`，否则
  `$XDG_RUNTIME_DIR/pulse/native`）。没有就没有声音（`features.audio: false`，`/audio` 503），其余照常。
- 剪贴板只要 X（没有剪贴板管理器也行：复制的程序退出后剪贴板就空了）。

## 运行

```sh
# 发布包：解到一个目录里
mkdir -p /opt/yoyo-linux && tar -xzf yoyo-linux-0.8.0-linux-arm64.tar.gz -C /opt/yoyo-linux
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > ~/.yoyo-token && chmod 600 ~/.yoyo-token
DISPLAY=:0 node /opt/yoyo-linux/server.mjs --host 127.0.0.1 --port 7380 --name "My desktop" --token-file ~/.yoyo-token
# 或者令牌从 stdin 来（第一行）
printf '%s\n' "$TOKEN" | DISPLAY=:0 node /opt/yoyo-linux/server.mjs --host iface:eth0 --port 7380
curl -H "Authorization: Bearer $(cat ~/.yoyo-token)" http://127.0.0.1:7380/status
```

- `--host <地址 | iface:<网卡>>`：只听这一个地址（缺省 `127.0.0.1`）；`iface:eth0` = 那块网卡的第一个 IPv4 地址。
- `--port <n>`：缺省 7380。
- `--name <名字>`：`/status` 里这块屏幕的 `name`（缺省 `Linux`）。
- `--token-file <路径>`：令牌是这个文件的第一行；不给就读 stdin 的第一行（读到 EOF）。至少 16 个字符。不走 argv / 环境变量：同一台
  机器上别的用户读得到别人进程的 argv 和环境。每个请求都要 `Authorization: Bearer <token>`，否则 401。令牌在进程活着时不变：
  换令牌 = 重起进程。
- 明文 HTTP/1.1：要经不可信的网络访问，放在 TLS / 隧道 / VPN 后面；或者用下面的「远程访问」（uu Link：加密、配对、中继）。
- 环境变量：`YOYO_VIDEO_MAX_KBPS`（码率天花板）、`YOYO_LINUX_MAX_FPS`（缺省 30）、`YOYO_AUDIO`（`off` / `0` / `false` / `no`：没有声音，`/audio` 503 `audio off`）、
  `YOYO_X11VIDEO` / `YOYO_PA_OPUS` / `YOYO_X11CLIP` / `YOYO_X11WINDOWS`（辅助程序，缺省是 `server.mjs` 同目录下的）、`YOYO_XDOTOOL` / `YOYO_FFMPEG`（缺省在 `PATH` 里找）。
- 就绪：stderr 出一行 `yoyo-linux <version> (api 1) listening on <地址>:<端口>, display <DISPLAY>`。SIGTERM / SIGINT 关掉所有流后退出。
- JSON 的回答保持连接（keep-alive）：客户端每秒 30 个移动经转发方复用一个连接；流与 `/events` 照旧 `Connection: close`（Mac 版每个回答都是 close）。
- 日志：stderr，一行一条；每条流每 10 s 一行 `stats:`。

### 从源码跑

```sh
gcc -O2 -o yoyo-x11video x11video.c -lX11 -lXext -lXdamage -lXfixes -lx264
gcc -O2 -o yoyo-pa-opus pa-opus.c -lpulse-simple -lpulse -lopus -lm -lpthread
gcc -O2 -o yoyo-x11clip x11clip.c -lX11 -lXfixes
gcc -O2 -o yoyo-x11windows x11windows.c -lX11 -lXi
DISPLAY=:0 node server.mjs --host 127.0.0.1 --port 7380 --token-file ~/.yoyo-token
```

（Debian / Ubuntu 的开发包：`libx11-dev libxext-dev libxdamage-dev libxfixes-dev libxi-dev libx264-dev libpulse-dev libopus-dev`。）

## 远程访问

`--remote <home>`（默认关）：Yoyo Control 的 iPhone App 像连 Mac 一样连这台机器——`docs/REMOTE.md` 的那一套：经 uu Link（`docs/LINK.md`，
UDP / QUIC，钉身份钥匙）、在 Link 上用一次性配对码配对、Bearer 令牌绑定手机的 Link 钥匙、控制权、路由器的端口映射、信令服务 signal1
（`docs/RELAY.md`）。实现在 `remote.mjs` 和 `link.mjs`，建在 `@yoyocontrol/remote`（`packages/remote`）上，它编好的 JS 在 `vendor/remote/`
（发布包里也带着：不用 `npm install`）。Link 和 Mac 是同一个 Rust 核心（`@yoyocontrol/link` 的原生插件）；找不到插件就没有远程访问（日志一行
`remote: off: no uu Link …`）。不带 `--remote` 的进程什么都不变（没有 409、没有 `/control`）。

```sh
DISPLAY=:0 node server.mjs --remote ~/.yoyo-remote --name "My desktop"          # 只有远程访问（没有令牌监听）
DISPLAY=:0 node server.mjs --remote ~/.yoyo-remote --port 7380 --token-file ~/.yoyo-token   # 两个都要
node server.mjs pair --remote ~/.yoyo-remote          # 配对链接 + 终端二维码（qrencode 的，没有就自带的；--page 另开一页）：iPhone 扫码，5 分钟、一次
node server.mjs devices --remote ~/.yoyo-remote       # 配对的设备（--json：同 GET /remote）；remove <id>、disconnect（收回控制权）、status
node server.mjs account --remote ~/.yoyo-remote       # 在不在 Yoyo Control 账号里（docs/ACCOUNT.md）；account leave 退出
```

- 参数：`--remote <home>`（状态目录，0700）、`--name`（`/status` 的显示器名，也是手机上这台电脑的名字；`--computer-name` 单独给后者）、
  `--advertise <ip[:port],…>`（配对链接里的局域网地址和 Link 的外部地址，代替本机网卡的：容器看不见宿主的地址；没写端口就是 Link 的端口）、
  `--direct on|off`（端口映射，缺省 on，`YOYO_PORTMAP=off` 也关；记进 `remote.json`）、`--direct-client <ip[:port]>`（路由器转到哪：容器发布的
  端口在宿主上，就是宿主的局域网地址和端口）、`--direct-gateway <ip>`、`--direct-upnp <URL>`（路由器的 UPnP 描述地址：容器里收不到路由器的
  SSDP 回答——它从别的端口回，过不了 NAT）、`--direct-port <n>`（想要的外网端口）、`--exempt <ip,…>`（Link 的守卫不按来源冷却的地址：容器发布的
  端口上所有客户端都从网桥的地址来）。`YOYO_SIGNAL_URL` 换信令服务。
- `<home>` 里：`remote.json`（`serverId`、`direct`、`linkPublicPort`、`rtcPublicPort`、`account`）、`tls-key.der`（0600，身份钥匙，格式和 Mac 的一样）、
  `link-key`（0600，Link 的钥匙）、`devices.json`（0600，令牌只存 SHA-256）、`admin.sock`（0600：上面那些命令经它和跑着的服务说话，接口同 Mac 的
  `GET /remote`、`POST /remote/pairing`、`/remote/pairing/stop`、`/remote/direct`、`/remote/devices/remove`、`/remote/disconnect`、`/remote/account/leave`，没有
  `/remote/enabled`：开关就是 `--remote`）。
- Link（连同信令服务的登记和端口映射）只在有配对的设备、或配对码还有效时运行；最后一台设备被移除后再留 2 分钟（它重连时听到 `unauthorized`、
  忘掉这台）。`pair` 等路由器回答（至多 6 s）再给链接，这样绑定里有公网地址。
- 配对链接同 Mac 的二维码：`yoyocontrol://pair?v=2&id=&n=&fp=<身份钥匙指纹>&l=&lk=&ls=&lp=[&a=<局域网 IPv4>]&c=<码>`。手机在 Link 上配对：
  `hello.credential = "Pair <码>"`，`welcome.principal` 给回 `token` 和 `server: { id, name, platform: "linux" }`，令牌随即绑定这把客户端钥匙。
- 手机能用的路由：Mac 的那一套（`docs/REMOTE.md`「远程能用的接口」），经 Link 的 RPC；这里没有的（`/focus`）照旧 404，其余（`/windows`、`/hit`、
  `/automation`、`/audio/stats`…）对手机 404。`POST /clipboard` 只收 `text`。
- 账号（`docs/ACCOUNT.md`）：和 Mac 一样，已配对的手机经 Link 用 `GET /account`、`POST /account/join`（签名声明，`platform: "linux"`）、
  `POST /account/invite`（定向码）；信令连接上发 `{"type":"account","id"}`。
- 控制权（`control.mjs`，语义同 `docs/REMOTE.md`「控制权」）：手机 `control.take`（= `POST /control { controller: "user" }`）拿到（最后拿的那台
  持有，换手时按着的左键抬起）才能输入（没拿：`input.rejected`）；令牌监听的 `/input` 在有手机拿着时 409 `controlled-elsewhere`；10 分钟没有
  输入、设备被移除、`disconnect` 都放开；每次变化 `/events` 一行 `{"type":"control","control":{…}}`（两种客户端都收到），`/status.control`
  跟着变。
- 安全：Link 的握手钉身份钥匙（绑定由它签名）、令牌绑定客户端钥匙；核心的守卫同 Mac（60 s 内 10 次失败冷却 5 分钟，32 个会话，4 个没认证的）。

## uu Link

远程访问的门（上面）。手机经 UDP / QUIC 连上来，画面经 Link 的媒体层（FEC、NACK、按延迟调码率）走。实现在 `link.mjs`。

- UDP `--link-port`（缺省 47820），`0.0.0.0` 和 `[::]`。
- 中继：`--link-relay <url,…|off>`（`YOYO_LINK_RELAYS` 同），缺省没有（服务端不带任何中继，`docs/LINK.md`「端点、地址、路径」）：
  给了的话直连不上的手机经它进来，打洞也靠它；不给或 `off` 就只有直连。
- 信令服务：`--signal <url|off>`（`YOYO_SIGNAL_URL` 同），缺省没有（浏览器的 WebRTC 配对、按指纹查绑定都要它）。
- `defaults.env`（`server.mjs` 旁，可选）：发行方给自己的发布包放的缺省环境（`KEY=value` 行，真实环境优先）；开源的发布包没有。
- 钥匙 `<home>/link-key`，绑定由远程访问的身份钥匙签：`/status.link` = `{id, key, sig, port, relays, direct}`（监听时才有），
  `/status.features.link`；信令服务的控制连接发 `{"type":"link", …}`；`GET /remote`（管理 socket）的 `link` = `{id, port, direct, sessions, mapping}`。
- 地址：本机网卡的，加 `--advertise` 的，加路由器映射的（UDP，外网端口先要 `--direct-port`，之后记在 `linkPublicPort`）。日志 `portmap: … /udp`。
- 认证：`hello.credential` = `Bearer <设备令牌>`；令牌第一次经 Link 用时绑定手机的客户端钥匙（`devices.json` 里这台设备的 `linkKey`），之后别的
  钥匙 → `unauthorized`，重新配对后解开。`Pair <码>`：见上。设备被移除，它的会话随即关掉（代码 1）。
- 视频：`video.open` 的 `query` 同 `/stream`（同样的 400 / 404 / 503），每条一个 `yoyo-x11video`；只在画面变了时编、≤ `fps`（夹到
  `YOYO_LINUX_MAX_FPS`）、refine（同下「视频流」；临时码率另外不超过目标 × `fps` × 0.1 s，refine 加起来不超过媒体层的目标）、5 s 保活；
  `can_send_frame` 关着时这张先不编；码率跟媒体层的 `encoderBps`（`maxKbps`、`YOYO_VIDEO_MAX_KBPS` 是天花板）；帧率不超过媒体层按码率定的
  上限（`frameRateCap`：低码率下帧少些、每帧清楚些，`docs/LINK.md`「帧率上限」），x264 按 `--fps` 记每帧的预算，所以上限低时给它
  `encoderBps × fps / 上限`，VBV 缓冲仍是 1 s 的真实码率（`E` 命令的第 4 个数，旧的辅助程序不认就照旧）。x264 没有长期参考：手机要恢复帧（`recoveryNeeded`）或关键帧时都发关键帧，最多 500 ms 一个。`cursor=client`：位置走指针数据报，
  形状是 `cursor.shape` 控制消息（每个形状一次）。每 10 s 一行 `link <设备>: video <id> stats: …`（含 `held` = Link 的队列或帧率上限挡着的次数和时间、`fps cap`）。
- 声音：`audio.open` 订阅同一份采集，每个 Opus 包 → `send_audio`；开不了时 `audio.error`（503）。
- 输入：媒体层的输入事件按顺序进 `/input` 的处理（控制权、坐标），被拒 → `input.rejected`（`code` 同 `docs/LINK.md`）。`control.take` /
  `control.release` = `POST /control`，每次变化所有会话收到 `control`。
- RPC：别的请求（`/status`、`/events`、剪贴板…）经同一张远程路由表进现有路由，流式的照样流式。
- 日志：Link 核心的 `link[server]:` / `link[phone]:` 每 10 s 一行、会话开关、路径变化，都进 stderr。还没有 Mac 那样的逐帧跟踪文件。
- 浏览器（`docs/LINK.md`「WebRTC」）：同一个监听另开一个 WebRTC 的 UDP 端口（`--link-rtc-port`，缺省 Link 端口 + 1，`off` 关掉；
  `YOYO_LINK_RTC_PORT` 同），`--advertise` 的主机也在这个端口上给出，路由器同样映射它（外网端口记在 `rtcPublicPort`）；`--link-stun host:port`
  让答复多一个 STUN 问来的公网地址。offer 经令牌监听上的 `POST /link/rtc` 进来（`docs/LOCAL-API.md`「浏览器的 Link」），会话和手机的一样
  （令牌绑定浏览器 DTLS 证书的 `dtls-sha256:…`）。`/status.link.rtc = { port, direct? }`。还没有经信令服务的 offer（Mac 有）。

### 不开远程访问：主人模式

不带 `--remote` 也能开 Link：`--link on --link-home <目录>`（缺省关）。这时没有配对和设备库：谁能开会话、谁能发输入，由拿着令牌的
那个程序（主人）决定——和 Mac 的主人模式同一套接口（`docs/LOCAL-API.md`「Link 的主人」），在令牌监听上：

```sh
printf '%s\n' "$TOKEN" | DISPLAY=:0 node server.mjs --host iface:eth0 --port 7380 \
  --link on --link-home /var/lib/yoyo-link --link-port 47820 --advertise 192.168.1.20:47900
```

- `--link-home <目录>`：Link 钥匙 `link-key` 和签绑定的身份钥匙 `tls-key.der`（P-256，同远程访问的身份文件）放这里（0700，文件
  0600；没有就生成，之后跨重启不变）。`/status.link` = `{id, key, sig, port, relays, direct, fingerprint}`：`fingerprint` 是身份钥匙的
  指纹（`sha256:<hex>`），手机拨号时按它核对绑定；主人把绑定和指纹交给手机。`welcome.server.id` 取自这个指纹。
- `--advertise <ip[:port],…>`：进 `direct` 的地址（没写端口就是 Link 的端口）——在容器里就是宿主上发布的那个 UDP 端口。这个模式
  不做路由器的端口映射（要公网，由主人在外面做，再经 `--advertise` 告诉这里）。`--link-port`（缺省 47820）、`--exempt` 同上。
- 主人：`GET /link/authority`（NDJSON，一直开着；同时一个，第二个 409；每 15 s 一个空行）收 `auth` / `control` / `session` / `activity`
  行；`POST /link/authority/answer` 放行（`principal.device` 是之后认人的身份）或拒绝；`POST /link/control { holder }` 说现在谁能发输入。
  手机的 `hello.credential` 原样交给主人（3 s 没回答 = `busy`；没有主人连着 = `busy`）。只在令牌监听上：配对的手机一律 404。
- 输入：只有主人给的持有者的输入放行（别人 `input.rejected` `controlled-elsewhere`，没人持有 `no-control`），之后在路由看来是令牌
  监听的输入；`control.take` / `control.release` 只是告诉主人，主人改了持有者（或 3 s 后）回 `control`。
- RPC：只有 `GET /status`；别的请求（`/events`、剪贴板、`/control`…）由主人自己经它的路给手机。
- 主人断开：新会话 `busy`，已有的照常，持有者变成没人。

## 试一台

`demo/`：一台 Debian 12（bookworm）的 Docker 机器，1920×1080 的 Xvfb + Xfce（终端、Firefox）、PulseAudio、发布包，带 `--remote` 起来：

```sh
linux/demo/run.sh                      # 容器 uu-linux-test，宿主端口 47830 / 47831（UDP：Link 和它的 WebRTC），状态在卷 uu-linux-test
docker exec uu-linux-test yoyo pair    # iPhone 扫这个码（或在 iPhone 上打开链接）
docker exec uu-linux-test yoyo devices # remove <id>、disconnect、status
```

`run.sh` 用 `build/` 里这个架构的发布包（没有就 `gh release download`），告诉手机的地址是宿主的局域网 IPv4 和 Tailscale IPv4（有的话）加
`PORT`；外网直连：在宿主上找出路由器的 UPnP 描述地址（宿主上有 node 时；或设 `UPNP_LOCATION`），让路由器把外网端口转到宿主的局域网地址和
`PORT`（`DIRECT=off` 不要），实测（OrbStack、家里的路由器）映射成功、从局域网经公网地址回环也通；`RELAY=off` 不登记中继。`NAME` / `PORT` 换一个
就能并排再起一台。

## 测试

```sh
cd linux && node --test test/
./vendor.sh --check        # vendor/ 和 packages/ 现在编出来的一样（改了 packages/remote、portmap 或 link 就 ./vendor.sh 再提交）
```

不需要 X、xdotool、ffmpeg：`test/fakes.mjs` 假扮这些进程（以及四个辅助程序的记录格式），macOS 上也能跑。`test/link.test.mjs` 用真的
Link 客户端连（要原生插件：仓库里 `cd link && cargo build -p uu-link-node` 编出的 debug 版自动找到，或设 `YOYO_LINK_NATIVE`；没有就跳过）。

## 发布

```sh
cd linux && ./build.sh 0.8.0      # build/yoyo-linux-0.8.0-linux-{arm64,amd64}.tar.gz + build/SHA256SUMS（要 docker buildx；C 辅助程序的另一个架构走模拟，Link 插件在本机交叉编译）
gh release create linux-v0.8.0 --prerelease --target <commit> --title "yoyo-linux 0.8.0" build/yoyo-linux-0.8.0-linux-*.tar.gz build/SHA256SUMS
```

- 版本号是 `server.mjs` 的 `VERSION`（`/status` 的 `version`），`build.sh` 不一致就停；tag 是 `linux-v<版本>`，指向发布的那个提交。
  发过的 tag 不挪：之后的改动出下一个补丁版本。
- Link 的原生插件：`release.Dockerfile` 的 `link-addon` 阶段在构建机上用 `rust:1.96-slim-bookworm` 交叉编译（gcc 的交叉链接器，glibc 同 bookworm），
  放到 `vendor/link/uu-link.linux-<x64|arm64>-gnu.node`；Rust 源码由 `build.sh` 作为命名上下文 `link-src` 传进去（不带 `target/`）。
- tar 是平的（没有顶层目录）：`.mjs` 与 `vendor/` 0644（目录 0755）、四个辅助程序 0755，`build.sh` 先跑 `./vendor.sh --check`，属主 0:0，时间固定、按名排序、gzip 不带时间戳——同样的源码出同样的字节。
- 使用方按版本固定：下载 `yoyo-linux-<版本>-linux-<架构>.tar.gz`，按 `SHA256SUMS`（或自己记下的 sha256）校验，解到一个目录。

## HTTP API

| 请求 | 回答 |
| --- | --- |
| `GET /status` | `{ app: "yoyo-linux", version, api: 1, platform: "linux", features: { clipboard, audio, cursor: true, focus: false, link, windows, automation: true }, automation: { active, esc, label? }, ok, session: { loggedIn: true }, screenRecording: true, accessibility: true, displays: [{ id: 1, width, height, scale: 1, main: true, asleep: false, kind: "builtin", name }], states: [{ display: 1, main: true, phase: "ready", since }], console: { locked: false }, control: { controller: "none" } }`（`control`：`--remote` 时是配对手机的控制权，见「远程访问」；`platform` / `features`：协议的可选字段，`docs/PROTOCOL.md`「Linux 服务端」；`features` 是开放集合：`clipboard` = `yoyo-x11clip` 在跑，`audio` = PulseAudio 应答且编码器起得来（探测一次 `yoyo-pa-opus --probe`，成功记 60 s、失败 10 s；采集在跑时就是 true）且没关；`link` = uu Link 的监听在跑；`windows` = `/windows`、`/hit`、`/frame?visible=` 能用（`yoyo-x11windows` 上次起得来；X 没了时它们 503，这个键仍是 true）；`automation` = `POST /automation` 有）；`automation`：见下「自动化」；显示连不上时 `ok: false` + `error`、`displays: []`。屏幕大小超过 5 s 就重新问一次（起一个短命的 `yoyo-x11video` 读它的 hello），X 没了就因此变成 `ok: false`；某条流的 `yoyo-x11video` 自己退出了（X 没了、屏幕换了大小）也立即作废 |
| `GET /events` | `application/x-ndjson`：先一行 `{"type":"state",…}`，紧跟一行 `{"type":"clipboard",…ClipboardSummary}`（剪贴板辅助进程在跑时），之后剪贴板每变一次一行、自动化时按了 Esc 一行 `{"type":"abort","reason":"esc"}`（只给那一刻连着的）、每 15 s `{"type":"ping"}`（状态不会变：没有锁屏、权限这些） |
| `GET /frame?display=1&maxWidth=1280&quality=70[&visible=][&hide=][&crop=]` | `image/jpeg`（ffmpeg x11grab 一帧，画着指针，按 `maxWidth` 缩），头 `X-Frame-Width` / `X-Frame-Height` / `X-Display`；别的 `display` 404。同时至多 2 个 ffmpeg，再 4 个排队，更多 503。`visible=<app,…>`（WM_CLASS 的 class，逗号分隔，不分大小写）只露这些 App 的窗口：其余盖住（头 `X-Frame-Filter: mask`，见下「窗口」）；`hide=`（同样，末尾 `*` 匹配前缀，≤ 64 个，不像 class 的 400）把它们从 `visible` 里去掉，桌面与面板也只在这里点名时才盖；没有 `visible=` 时什么都不变。`crop=x,y,w,h`（归一化，夹到画面内；空 400）在盖住之后从全分辨率的画面切出这块（整像素、向外取整），再按 `maxWidth` 缩（不放大），头 `X-Crop: x,y,w,h`（实际用的，4 位小数）。窗口辅助程序起不来 503 |
| `GET /windows[?display=1]` | `{ apps: [{ pid, bundleId, name, windows }], windows: [{ pid, display: 1, x, y, w, h, layer }], focused: { pid, bundleId, name } \| null }`：X 的叠放次序里看得见的窗口，**前 → 后**（见下「窗口」）；`bundleId` = `name` = WM_CLASS 的 class；几何归一化到屏幕、夹到屏幕内；`apps` 每个（pid, class）一个、按前 → 后、带窗口数；`focused` = `_NET_ACTIVE_WINDOW` 的主人（没有 null）。没有窗口标题。别的 `display` 404；X 没了 503 |
| `GET /hit?display=1&x=&y=` | `{ app: { pid, bundleId, name } \| null, layer: number \| null }`：盖住归一化点的最上面那个列出的窗口的主人（同 `/windows` 的列表）；那里没有窗口 `app: null`。`x` / `y` 缺或不在 0…1 400；别的 `display` 404 |
| `POST /automation`（或 `POST /agent-control`，旧名） | `{ active: bool, label?: string }` → `{ ok: true, active, esc, label? }`（见下「自动化」）。`active` 不是布尔、`label` / `title` 不是字符串 400。对手机 404 |
| `GET /stream?display=&maxWidth=&fps=2&codecs=&stream=&ack=&cursor=&status=&maxKbps=` | 同 Yoyo Control：回 `application/vnd.yoyo-control.stream; boundary=frame`（0.2.0 起不看 `Accept`：发布前的旧名字去掉了）；头 `X-Stream-Codec: h264`、`X-Display`、`X-Stream-Id`。只有 **h264**（`codecs` 列了 hevc 也是 h264，和 Mac 编不了时的退路一样）；`fps` 夹到 1…30；`maxWidth` 不缩（画面就是屏幕的大小）；`cursor=client`：画面里不画指针，改发指针分段（见下「指针」）；`status=1` 先发一个状态分段（`ready`）。最多同时 4 条流（多了 503） |
| `POST /stream/ack` | `{ stream, seq, keyframe?, report? }` → `{ ok: true, net }`；没有这个流 404；`stream` / `seq` / `keyframe` 不合法 400，`report` 宽松解码、从不让确认失败 |
| `POST /input` | 字段同 Yoyo Control 的 `POST /input`（`click` / `doubleClick` / `rightClick` / `move` / `drag` / `scroll` / `type` / `key` / `down` / `up`，`modifiers`、`button`、`phase` / `vx` / `vy`、`seq`）→ `{ ok: true }`，被超过的 `move` → `{ ok: true, stale: true }`；不合法 400；别的 `display` 404。键名另认 `insert`（Linux 服务端的键名，`docs/PROTOCOL.md`「Linux 服务端」：Shift+Insert 是这里的粘贴键）。没有控制权的概念（那是配对手机的事） |
| `GET /audio` | 桌面的声音（见下「声音」）：头 `X-Audio-Codec: opus`、`X-Audio-Rate: 48000`、`X-Audio-Channels: 2`、`X-Audio-Frames: 960`、`X-Audio-Cookie`、`X-Audio-Video-Offset: 10`，分段 `audio/opus` + `X-Audio-Seq` / `X-Audio-Time`；媒体类型 `application/vnd.yoyo-control.audio; boundary=frame`。起不来时响应头之前 503 `{ error }`（`YOYO_AUDIO=off`：`audio off`） |
| `GET /audio/stats` | `{ enabled, running, clients, starts, failures, packets, fills, lastError }` |
| `GET /clipboard[?text=0]` | 剪贴板此刻的 `ClipboardItem` + `ok: true`（见下「剪贴板」）；`text=0` 不带正文。辅助进程没在跑 503 |
| `GET /clipboard/image` | 图片项的 PNG（`X-Clipboard-Change-Count`；每个 changeCount 向拥有者要一次、缓存）；不是图片 404 |
| `GET /clipboard/file?index=N` | 文件项的第 N 个文件，流式；`Content-Length`、`Content-Disposition: attachment; filename*=UTF-8''<名>`、`Content-Type` 按扩展名；文件夹 400，不是文件项 / 越界 / 没了 404，没有 `index` 400 |
| `POST /clipboard` | `{ text }` 或 `{ files: ["/绝对路径"…], source?: "phone" \| "agent" }`（缺省 phone）→ 剪贴板换成它（CLIPBOARD 与 PRIMARY 都是），记下这个 changeCount 的 `source`，`/events` 立刻出一行；回答同 `GET /clipboard`。文字空 400、超过 1 MiB 413；路径不是存在的文件或文件夹 400；至多 20 个；别的程序抢着不放 503 |
| `POST /control` | 只给配对的手机（`--remote`，见「远程访问」）：`{ controller: "user" \| "none" }` → `{ ok: true, control }`；令牌监听上 404 |
| 其他：`/focus`、`/app/windows`、`/app/screenshot`、`/app/ax`、`/permissions/request`、`/remote*` | 404 `{ error: "not found" }`：这些 Mac 版有、这里还没有（客户端按 404 / `features` 关掉对应的功能） |

## 视频流

一条流一个 `yoyo-x11video` 进程（`cursor=client` 时带 `--cursor client`）（流关了它就退出；屏幕换了大小它以 3 退出、X 出错以 1 退出，流就正常结束，客户端重开一条按新尺寸的），
节奏照 Yoyo Control 的 `VideoStreamLoop.swift`：

- 只在画面（不带 `cursor=client` 时还有指针）变了、或要关键帧时编码，至多 `fps`；间隔从上一幅**开始编码**算。关键帧：流开始、客户端 `keyframe: true`（每 500 ms 至多一个）、60 s 保底。
- 确认窗口、1 s 的探测、3 s 没确认停用窗口 / 新鲜确认恢复（每条流至多 5 次）、排队延迟（1 s 内最小 RTT − 10 s 内最小 RTT）> 50 ms 持续 500 ms 降码率 ×0.85
  （关键帧后 1.5 s 内、发得不到目标一半时不降）、干净时回升 / 上调、临时天花板、网络档位（低数据模式 2500）——数都和 Mac 一样（`flow.mjs` 的 `TUNING`）。
- 编码：x264 `superfast` + `zerolatency`，High profile，没有 B 帧、没有延迟帧；按质量（CRF 23）编、码率当上限（VBV：`kbps` / 1 s），这样静止的屏幕很少的几幅画面
  也是清楚的。画面停下 300 ms 后 `refine`，之后不变就每 100 ms 一次，直到连续两次都不超过一幅实时画面的预算（`kbps` × 1000 / 8 / `fps` 字节；
  `'S'` 跳过的不算小），最多 20 次，有新内容就从头再来（`flow.mjs` 的 `RefineSchedule`，数在 `TUNING`，名字和 Mac 的 `StreamTuning` 一样）。
  refine 总是 CRF 17；上限临时 2 倍（至少 4 Mbps，不超过档位的天花板；排队时不提高，CRF 照样 17）。x264 的 VBV 按画面数而不是按秒补预算，
  每次 refine 只拿到大约一幅画面的量，所以要编多次才清楚。没变化时每 5 s 一个 `keepalive`。
- 分段头：`Content-Type: video/h264`、`Content-Length`、`X-Frame-Width` / `X-Frame-Height`、`X-Frame-Seq`、`X-Frame-Time`（截屏时的墙钟 ms）、`X-Frame-Kind`
  （`key` / `delta` / `refine` / `keepalive` / `status`）、`X-Stream-Codec: h264`。每个 `key` 分段以 SPS、PPS 开头（4 字节起始码）。

`yoyo-x11video` 的接口（stdin 命令一行一个、stdout 二进制记录）见 `x11video.c` 开头。

## 指针（`cursor=client`）

照 Yoyo Control 的 `VideoStreamLoop.swift` / `DisplayPointer.swift` / `StreamCursor.swift`：

- 画面里不画指针，指针动了也不是画面变了（不重编码，refine 不被打断）。`yoyo-x11video --cursor client` 每 33 ms 看一次指针位置、变了才报一个 `'P'`；形状跟着
  XFixes 的 cursor notify 走，这个进程第一次见到一个 cursor serial 时带上它的像素（预乘 ARGB → 预乘 RGBA）。一秒内超过 10 个新 serial（动画光标）就只报位置、
  形状保持上一个，静下来 0.5 s 后再报（日志一次）。拿不到图（XFixes 给不出）时报「没有形状」：客户端用内置箭头。
- 流里：第一个画面之前一个指针分段（带形状），之后位置 / 形状 / 可见性变化时再发，合并、至多 60 个/秒；不计入确认窗口、占 `X-Frame-Seq`；
  `Content-Type: application/vnd.yoyo-control.cursor+json`，`X-Frame-Kind: cursor`，`X-Frame-Time` 是发出的时刻。
  body `{ x, y, visible, shapeId, shape? }`：坐标归一化到屏幕（`x - hotX` 是形状图的左边），`shape { id, png, hotX, hotY, width, height }` 只在这条流还没发过这个
  `shapeId` 时带（每条流记 32 个，多了清空重来）；全透明的指针 `visible: false`。
- `shapeId` = 每进程一个随机基数（[2^20, 2^40) 里 2^20 的倍数）+ X 的 cursor serial：≥ 1e6，同一个 id 在本进程里总是同一张图（PNG 每个 serial 编一次，缓存 64 个），
  不会撞上以前进程的 id；同一个 serial 来了另一张图（换了 X server）就换一个基数。内置箭头 `shapeId 0`：Mac 的同一个画法（每 1600 px 画面宽 26 px 高，PNG 2 倍）。
- 位置的两个来源：处理完一个会移动指针的 `/input`（`click` / `doubleClick` / `rightClick` / `move` / `down` / `up`、带 x / y 的 `scroll`、`drag` 的终点；被超过的
  `move` 不算）立刻发；轮询读到的位置只有它**变了**才跟随，且与当前位置差不到 1.5 px 不算（读回的是我们自己的输入）。
- 统计行多 `cursor parts N`。

## 声音

照 Yoyo Control 的 `AudioStream.swift` / `AudioCapture.swift`：所有 `/audio` 客户端共用一个 `yoyo-pa-opus`（第一个来时起，最后一个走后 3 s 停）；每个客户端一个
25 包（约 500 ms）的队列，跟不上就丢**最早**的，`X-Audio-Seq` 在入队时给（丢的留下缺口）。`yoyo-pa-opus` 读 PulseAudio 默认 sink 的 monitor（48 kHz 立体声 s16），
每 960 帧（20 ms）用 libopus 编一包（`OPUS_APPLICATION_AUDIO`、96 kbit/s VBR、复杂度 5）。`X-Audio-Time` = 这个包解出来的第一个采样的墙钟 ms：采样从 0 起数、
锚定在墙钟上（一次 20 ms 读回来的时刻减 20 ms），按采样数往前推（相邻两包正好差 20），与墙钟差超过 20 ms 时重新锚定；编码器输出晚输入 312 帧（Opus 的 lookahead）。
null sink 没在放声音时 PulseAudio 按 2 s 一块渲染，新读者的第一批采样要等 0–2 s（可能成阵到来）：在那之前（以及之后采样晚了 60 ms 以上时）编码器拿到静音（落后墙钟 10 ms：第一个真块正好落在时间线 ±20 ms 内），所以第一个包约 30 ms 就到、之后每 20 ms 一包。时间线只往前走：一个读回来的块的时间 = 读回来的时刻 − 20 ms − 同一阵里排在它后面的块数 × 20 ms；比时间线晚 20 ms 以上的块（那段已经由补的静音盖过）丢掉，连续 5 块都早 20 ms 以上才往前挪（挪最小的那个差：单独一次读晚了只是调度），所以 `X-Audio-Time` 永远相邻差 20、不回退（实测：从补静音到真采样、以及进程被停 400 ms 后的一阵积压，都严格 20 ms 一包）。有客户端时每 10 s 一行 `audio:` 日志。

- `X-Audio-Cookie`：Mac 实际发的那 28 个字节（AVAudioConverter 的 Opus magic cookie：7 个大端 32 位数 `2048, 48000, 960, -1000, 2, 0, 0`），不是 OpusHead。
- `X-Audio-Video-Offset: 10`：同一个钟、没有扬声器、没有扫描输出，但 null sink 按它的延迟提前渲染（这个延迟是我们自己的读者要的 20 ms：最小的那个说了算；实测带一个播放器时 0.5–19 ms），一个块又按它读回来的时刻标：样本在 sink 的钟上（照它对画面的程序看到的）平均比 `X-Audio-Time` 晚约 10 ms 才「放」。拿 pulse 的延迟逐包修正不可行：monitor 的样本在 sink 的未来，`pa_simple_get_latency` 报 0。

## 剪贴板

照 Yoyo Control 的 `Clipboard.swift` / `Router.swift` 的语义，经一个常驻的 `yoyo-x11clip`（启动时起、退出了 2 s 后再起；没在跑时剪贴板路由 503，`features.clipboard` false）：

- 只看 **CLIPBOARD**（PRIMARY 是鼠标的每一次选中）：XFixes 报拥有者换了（有程序复制了，或拥有者没了）就问 TARGETS，再按需要取内容（大的走 INCR），每次变化报一次——
  不轮询，空闲时不花 CPU。`changeCount` 每进程从 1 起、每次变化加一；`at` 是本进程第一次见到它的时间；`source` 是自己的 `POST` 造出来的那些。
- 种类按顺序：有 `x-kde-passwordManagerHint`（KeePassXC 一类）→ `concealed`；`text/uri-list`（没有就 `x-special/gnome-copied-files`）里有 `file:` 的 → `files`（本机路径，
  `stat` 出大小与 `dir`）；`image/png` → `image`（宽高读 IHDR，PNG 留着给 `/clipboard/image`）；文字（`UTF8_STRING` / `text/plain;charset=utf-8` / `STRING` / `TEXT` /
  `text/plain`）→ `text`（预览 160 字、换行显示「⏎ 」，正文 ≤ 1 MiB 在字符边界截断）；没有拥有者 → `empty`；其余 `other`（只有别的图片格式时日志一次）。
- 写入：`yoyo-x11clip` 自己拥有 **CLIPBOARD 与 PRIMARY**（同一内容），按请求给 `TARGETS`、`TIMESTAMP`；文字给五种文字目标；文件给 `text/uri-list`
  （`file://` + 按段百分号编码的路径，`\r\n` 分隔）、`x-special/gnome-copied-files`（`copy` + 各 URI，Thunar 认）、路径的纯文字（终端里贴出来是路径），只有一个
  图片文件（png / jpeg / gif / webp / heic，≤ 64 MiB）时另带它的字节（按扩展名的类型：贴进收图片的程序是图）。大的值走 INCR。
- 平台差异：复制的程序退出后剪贴板就空了（X 没有自己的剪贴板，也没跑剪贴板管理器）；没有 `concealed` 标记的惯例。

## 窗口

`/windows`、`/hit` 和 `/frame?visible=` 每次请求起一个 `yoyo-x11windows`（一次性，几毫秒；2 s 没答 503），`/frame` 在截图前一刻取：

- **列表**：根窗口的子窗口按 X 的叠放次序（合成器开不开都是它决定谁画在谁上面），只取看得见的（`IsViewable`、InputOutput）。窗口管理器的外框报它里面
  带 `WM_STATE` 的客户窗口的身份，几何是外框（含标题栏；客户端画装饰的 GTK 窗口减去 `_GTK_FRAME_EXTENTS` 的透明阴影）；override-redirect 的窗口（菜单、
  提示、弹出框）按它自己的 WM_CLASS / pid 列出。没有 WM_CLASS 也没有 pid 的不列（窗口管理器自己的、输入窗口）。最小化的（`_NET_WM_STATE_HIDDEN`，
  xfwm4 下本来就没映射）、在别的工作区的（没映射）、整个在屏幕外的不列。这比 `_NET_CLIENT_LIST_STACKING` 多出 override-redirect 的菜单：打开的菜单
  能命中、能盖住。
- **身份**：Linux 的 App 没有 bundle id，`bundleId` 与 `name` 都是 WM_CLASS 的 class（第二个字符串：`Xfce4-terminal`、`Thunar`、`firefox-esr`、
  `Google-chrome`）；没有 class 的 `bundleId: null`、`name` 是 instance 或 `pid N`。`pid` 来自 `_NET_WM_PID`（没有就 0，照样列出）。从不读窗口标题。
- **`layer`**：桌面（`_NET_WM_WINDOW_TYPE_DESKTOP`，xfdesktop）−1；普通窗口 0；面板（`_DOCK`，xfce4-panel）与置顶（`_NET_WM_STATE_ABOVE`）1；
  override-redirect 与菜单、提示、通知类型 2。桌面与面板像别的 App 一样列出（Mac 把桌面和 Dock 归到 Finder；这里各是自己的 App）。
- **盖住**（`/frame?visible=`，Mac 的退路那种 `X-Frame-Filter: mask`；这里没有「原生」那条路）：每个不在 `visible` 里（或在 `hide` 里）的 App 的每个窗口
  盖上实心的 #3a3a3a（ffmpeg `drawbox`，不写 App 名），效果同从后往前画：允许的窗口挡在被盖的前面时仍露着（被盖的矩形减去它前面允许的窗口）。桌面与面板
  只在 `hide=` 点名时才盖。
- **命中**：前 → 后第一个包含该点的窗口；屏幕的最后一行 / 列（`x` 或 `y` = 1）归碰到它的那个窗口。没有 Mac 那些菜单栏、系统浮层的特例。

## 自动化

`POST /automation { active, label? }`（Mac 的 `Automation.swift`）：本机程序说「我在操作这台电脑」。`label` 一行（控制字符变空格、连续的并成一个），至多 40 个字；
`title`（旧字段）收下不用。这里**不画边框**（无头）；状态在 `/status.automation`（`{ active, esc, label? }`）。打开时起一个常驻的 `yoyo-x11windows --esc`
（等它说在听，至多 1 s）：XInput 2 的原始按键（不抓键盘）里，这块 X 显示的键盘上按下的 Esc（不带 Shift / Ctrl / Alt / Super、不是 XTEST 发的——
本服务的 `/input` 和手机的键经 xdotool 走 XTEST）就关掉自动化（同 `active: false`）并给 `/events` 写 `{"type":"abort","reason":"esc"}`。和 Mac 不同：
这个 Esc **不会被吞掉**，前面的程序照样收到。`esc: true` = 这个监视在跑；没有 XInput 2、辅助程序起不来时 `esc: false`（自动化照样是 `active`）。
关掉时监视退出。同一个值再发一次没有作用（`active: true` 时换 `label` 只更新它）。Xvfb 上没有真键盘：Esc 只会来自 XTEST，所以永远不会触发
（`yoyo-x11windows --esc --xtest` 把 XTEST 的也算上，只为在这样的显示上试它）。

## 输入

- 两个常驻的 `xdotool -`：指针（移动、点击、拖拽、滚轮）一个，键盘（`key`、`type`）一个，命令一行一行写进各自的 stdin（退出了下次输入时再起）。
  长文字在键盘那条上慢慢打，点击、滚动不排在它后面；按键之间保序。坐标 = `x × 宽` 夹到屏幕内（屏幕换了大小就按新的算）。
- 键盘那条排着的字按估算的耗时（键盘布局上有的约 10 ms 一个，没有的约 50 ms）至多 60 s：再来的 `key` / `type` 回 429
  `still typing the earlier text`，单独一次就超过 60 s 的 `type` 回 413（例如 1200 个以上的汉字：分几次发）。
- `type`：每个字符按它的 Unicode keysym 发（`key U4F60`），键盘布局上没有的字（中日韩、emoji…）xdotool 临时映射一个空键码；这样的字一行一个、之后停 40 ms，
  否则应用读到的是下一个字的映射（实测「你好，世界」打成「你好界界」）。ASCII 一行至多 32 个。
- 修饰键：`cmd` 当 Ctrl 发（Linux 程序的快捷键），`ctrl` / `alt` / `shift` 照旧。`enter` 是小键盘回车，`delete` 是退格，`forwardDelete` 是 Delete，`insert` 是 Insert
  （Linux 服务端的键名：Shift+Insert 在终端、GTK、Chromium、Thunar 里都粘贴，终端不认 Ctrl+V）。
- 滚动：X 只有滚轮按键（4 / 5 上下、6 / 7 左右），每 50 px 一下；像素的节奏与惯性照 Mac 的 `ScrollSynth`（0.9 × 请求间隔内匀速放出、抬手速度 ≥ 120 pt/s 时惯性，
  每毫秒 ×0.998），别的指针输入打断它。
- `move` 的 `seq`：最近 2 s 内的最大值之下的回 `stale`（少 1000 以上或 2 s 没有移动就重新计）。实时拖拽：`down` 之后 15 ms 才发第一个按着的移动；按下 10 s 没有
  移动也没有 `up` 就自己松开；最后一条流关掉时还按着也松开。
