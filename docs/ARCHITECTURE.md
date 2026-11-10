# 架构

```
Yoyo Control（iOS App，ios/App + ios/YoyoKit）
   │  uu Link（LINK.md）：局域网 / 路由器映射 / 打洞直连，直连不上经 relay1（RELAY.md）；
   │  钉 Mac 的身份钥匙 + 设备令牌，配对也在 Link 上（REMOTE.md）
   ▼
Yoyo Control.app（mac/，菜单栏常驻，开机自启）
   │  服务进程：采集（ScreenCaptureKit）、编码（VideoToolbox）、输入（CGEvent）、声音（Core Audio tap → Opus）、剪贴板
   ▲  本机 unix socket：~/Library/Application Support/YoyoControl/screen.sock（LOCAL-API.md）
   │
本机程序（自动化工具、别的 App：找到它、用它，缺了就引导用户安装）

yoyo-linux（linux/，Linux 上的无头服务端）
   │  X11（XDamage + MIT-SHM → x264）、xdotool、PulseAudio → Opus、X 剪贴板
   ▲  TCP + Bearer 令牌（linux/README.md），同一套 HTTP API
   │
客户端，或替客户端转发的程序（自己起它、自己管它的生命周期）

yoyo-windows（windows/：同一个服务 linux/*.mjs，Windows 的辅助程序）
   │  DXGI 桌面复制 → x264、SendInput、WASAPI 回环 → Opus、Windows 剪贴板
   ▲  托盘程序 yoyo-control.exe 在登录用户的会话里起它；uu Link（手机），可选 127.0.0.1 + Bearer 令牌（本机程序）
```

- **服务端是一个独立的 App**：用户自己安装、自己授权（屏幕录制、辅助功能、系统录音按签名 App 记），自己常驻运行。
  App 外壳（`YoyoApp`）监督服务进程：退出重启、退避、等新授权的重启；菜单栏显示状态、权限、配对与设备管理。
- **两个入口，同一套路由**：本机 unix socket（本账号的程序，`LOCAL-API.md`）和远程访问的 Link 监听（配对的手机和浏览器，
  接口白名单经 RPC，`REMOTE.md`）。接口见 `mac/README.md`「HTTP API」，流与输入的语义见 `PROTOCOL.md`。
- **控制权在服务端**：配对的手机之间一次一个控制者；手机拿着控制权时本机 socket 上的输入回 409。
- **本机自动化是通用能力**：`POST /automation`（谁在操作由调用方传 `label`，边框与 Esc 停止由 App 负责），
  `hide=`（调用方要藏起来的 App），别处来的输入（`/events` 的 `input-elsewhere`：有人在用键盘鼠标、或别的进程在发事件，
  调用方自己决定怎么办）。Yoyo Control 不认识任何具体的使用方。
- **服务是库**：Mac 服务是 `YoyoServer` 库（仓库根 `Package.swift` 的 macOS 产品），进程的外壳（命令行、TCC 责任的重新拉起、
  信号、stdin EOF、exit 75）是其中的 `ServiceHost`。Yoyo Control 的 `yoyo-control` 只是它的一个调用者；别的 App 用同一个库
  搭自己的服务、用自己的签名和权限跑，两者互不相干（`mac/README.md`「Embedding the service」）。
- **Linux 是无头模式**：`linux/` 说同一套接口（`app: "yoyo-linux"`、`api: 1`），没有 App、配对、中继；起它的程序给令牌
  （stdin 或 `--token-file`）、选监听地址。它和 Mac 版的差别（`/status.platform`、`/status.features`、键名 `insert`、剪贴板的
  CLIPBOARD + PRIMARY、`shapeId` 的取法）是协议的可选部分，写在 `PROTOCOL.md`「Linux 服务端」。
- **Windows 是同一个服务**：`windows/` 只有 Windows 的辅助程序（说 Linux 辅助程序的记录格式）、托盘程序和安装；`linux/platform.mjs` 按系统
  选它们。`app: "yoyo-windows"`、`platform: "windows"`，差别写在 `PROTOCOL.md`「Windows 服务端」。
- **客户端**：`ios/YoyoKit` 是 kit（仓库根 `Package.swift`）：`YoyoScreen` 屏幕页（解码与平滑播放、声音与音画同步、
  手势 / 键盘）、`YoyoClipboard` 剪贴板页、`YoyoCore` 契约（`YoyoBackend` / `YoyoHost`），`YoyoDirect` 直连后端，
  `YoyoPro` 付费墙；`ios/App` 是由它们搭起来的独立 App（扫码配对、找 Mac、钥匙串）。别的 App 写自己的 `YoyoBackend`
  就能嵌入屏幕页（`ios/README.md`「Kit」）。
- **TypeScript 套件**（`packages/`）：`@yoyocontrol/local` 是本机 API 的 Node 客户端（发现顺序、版本范围、unix socket /
  TCP + Bearer、`/events` 重连与状态去重、参数校验、流与声音按 `Accept` 转发、剪贴板），给本机程序和「把屏幕转给自己的客户端」
  的服务端用；`@yoyocontrol/screen-web` 是网页端的屏幕客户端（不含界面和文案，传输是宿主注入的一个 `fetch(path, init)`，
  或一条 Link 会话：`ScreenLink`）；`@yoyocontrol/link-web` 是浏览器的 Link 客户端（`dialRtc`、`linkScreen`）；
  `@yoyocontrol/screen-ui` 在它们上面做出整个屏幕页（Web Components，交互照搬 iOS 的 YoyoScreen / YoyoClipboard / YoyoConnect，
  契约同名：`ScreenBackend` = `YoyoBackend` 等）。
  `@yoyocontrol/portmap` 让家里路由器把公网端口转到本机的监听（PCP / NAT-PMP / UPnP IGD，续租、退出时删除、公网地址与
  CGNAT 判断），给 Node 端的远程访问用；Mac 端的同一套逻辑是 Swift 写的（`mac/Sources/YoyoServer/PortMap*.swift`）。
- **网页版**（`webapp/`，`https://yoyocontrol.com/app/`）：浏览器里的 Yoyo Control。浏览器拨不了 QUIC，所以它走 Link 的
  WebRTC（offer 经信令服务 signal1 的 `POST /v1/rtc/<fp>` 交给 Mac，answer 由 Mac 的身份签名，直连不上经 relay1 的 TURN）；配对也在 Link 上做（`hello.credential = "Pair <码>"`，
  `REMOTE.md`「配对」）。后端是 `@yoyocontrol/direct-web`（`packages/direct-web`：配对过的 Mac 和浏览器的 DTLS 证书存在 IndexedDB，
  `ScreenBackend` 的一切——状态、控制、剪贴板、`/events`、画面——都在 Link 会话上），界面是 `@yoyocontrol/screen-ui`。
- **Link**（`link/`，`LINK.md`）：手机 ↔ 电脑的 UDP 通道（QUIC + 打洞 + 自己的中继，iroh），一份 Rust 代码：会话、控制消息、
  RPC、数据报通道、跟着码率走的拥塞控制、统计。Swift 经 UniFFI（`YoyoLink`，`scripts/link-apple.sh`），Node 经 napi-rs
  （`@yoyocontrol/link`）；浏览器经 WebRTC（`@yoyocontrol/link-web`：同一套会话协议，媒体层是 `link/wasm` 编出的 WebAssembly）。
  Link 是手机和浏览器到电脑唯一的一条路（2026-11 起：TLS 监听和 Cloudflare 的中继退役）。
- **uu 自己的 VPS**（`relay/`，`RELAY.md`）：relay1 上的 iroh-relay（Link 的中继、打洞、地址探测）、coturn（浏览器的 STUN / TURN）、
  信令服务 signal1（Mac 的房间：浏览器的 offer、TURN 凭据、Link 绑定）。

## 分发

- Mac：`mac/release.sh` 出 Developer ID 签名、公证过的 App 和 DMG，Sparkle 的 appcast；`web/deploy.sh` 把它们和官网页面一起
  部署到 yoyocontrol.com（Cloudflare Workers 静态资源）。下载地址固定为 `https://yoyocontrol.com/download`（指向最新的 DMG），
  已安装的 App 每天查一次 `https://yoyocontrol.com/appcast.xml`。见 `mac/README.md`「Build」「Updates」。
- iOS：`ios/App/testflight.sh` 上传 TestFlight。
- Linux：`linux/build.sh <版本>` 在 Docker 里为 arm64 / amd64（Debian 12 bookworm）编出辅助程序，打成平的 tar + `SHA256SUMS`，
  发成 GitHub Release `linux-v<版本>`（`linux/README.md`「发布」）。使用方按版本和 sha256 固定。
- TypeScript 套件：私有期不进 npm registry。`scripts/git-dist.sh <包> <版本>` 构建、测试，把装包需要的文件（去掉 scripts /
  devDependencies 的 `package.json`、`dist/`、README）提交到孤儿分支 `dist/<包>`，打 tag `<包>-v<版本>` 并推送；
  使用方依赖 `git+https://github.com/yoyocontrol/yoyo-control.git#<包>-v<版本>`。发布过的版本不再移动，改了就升补丁版本。

## 由来

`mac/` 与 `ios/YoyoKit` 的屏幕页从更早的一个私有项目导入（提交历史保留），之后只在这里维护：这里只有 Yoyo Control
自己的接口与文档。
`linux/` 也是带着原来的提交历史导入的（`git subtree`），之后只在这里维护。

## 还没做

- 拖放文件（客户端；剪贴板页已有，`YoyoClipboard`）。
- 第二台 VPS（另一个地区）：relay1 现在是单点。
