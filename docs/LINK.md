# uu Link：手机 ↔ 电脑的 UDP 通道

手机和电脑之间一条加密的 UDP 连接，专为远程控制做：画面、声音、指针走不可靠的数据报（丢了就不等），输入、控制消息、
接口请求走可靠的流。底层是 iroh（QUIC + 多路径 + 打洞 + 中继也是一条 QUIC 路径，Ed25519 原始公钥的 TLS 1.3），上面的
会话协议、数据报通道、拥塞控制、统计是 uu 自己的。一份 Rust 代码，Swift（UniFFI）和 Node（napi-rs）各包一层。浏览器拨不了 QUIC：
同一个会话协议和媒体层还跑在第二种传输 WebRTC（`rtc`，下面「WebRTC」）上，服务端的会话从同一个监听出来。

Link 是远程访问唯一的门（`REMOTE.md`）：手机 App 走 QUIC，浏览器走 WebRTC，配对也在它上做；直连不上时经 uu 的中继 relay1（`RELAY.md`）。本机 socket 照旧是 HTTP（`LOCAL-API.md`）。

```
link/                     Rust workspace（Cargo.lock 提交；rust-toolchain.toml 固定 1.96）
  core/   uu-link           端点、身份绑定、会话（控制、RPC、数据报通道）、MediaCc、守卫、路径、统计
  media/  uu-link-media     画面 / 声音 / 输入的无 I/O 状态机（FEC、NACK、组帧、码率），会话里的通道 1–5
  ffi/    uu-link-ffi       UniFFI → Swift（静态库）
  node/   uu-link-node      napi-rs → Node（.node）
  wasm/   uu-link-wasm      wasm-bindgen → 浏览器（客户端媒体层 ClientMedia）
  tools/  uu-link-netem     UDP 损伤代理；uu-link-probe：serve / dial（QUIC）、serve-rtc / dial-rtc（WebRTC）实测
  vendor/sctp-proto        str0m 的 SCTP（crates.io 0.10.8）加 uu 的补丁（「WebRTC」）
scripts/link-apple.sh     YoyoLinkFFI.xcframework + Swift 绑定
ios/YoyoKit/Sources/YoyoLink   Swift 包装（根 Package.swift 的 YoyoLink）
packages/link             @yoyocontrol/link（TypeScript 包装 + 预编译的 .node）
packages/link-web         @yoyocontrol/link-web（浏览器：WebRTC 上的会话 + .wasm 的媒体层）
```

## 身份与信任

- 服务端的身份：P-256 钥匙，`fp = "sha256:" + hex(SHA-256(04‖X‖Y))`（`REMOTE.md`「身份」），配对链接里给出、手机和浏览器钉住它。
- **Link 钥匙**：Ed25519 私钥 32 字节，存 `<home>/link-key`（0600），第一次启动时生成，只随身份一起换。它的公钥就是
  endpoint id（64 位十六进制）。`load_or_create_link_key(path)` 做这件事：文件长度不对就报错，不会悄悄换掉。
- **绑定**：身份钥匙对 Link 钥匙的签名。

  ```json
  {"id": "<hex(ed25519 公钥)>", "key": "<b64(P-256 公钥 65 字节)>", "sig": "<b64(r‖s 64 字节)>"}
  ```

  `sig` = ECDSA-P256-SHA256，签的是字节串 `"yoyocontrol-link-v1:"` ‖ Ed25519 公钥（32 个原始字节）。签名用身份文件里
  97 字节的 X9.63 私钥（04‖X‖Y‖D）。服务端在配对链接（`REMOTE.md`「配对」）、`GET /status` 的 `link`（另带 `port`、`relays`、`direct`）和
  信令服务的控制连接 `{"type":"link", …}`（`RELAY.md`）里发布它。
- 客户端：核对 `SHA-256(key) == fp`（钉住的指纹，大小写、首尾空白不计较）和签名，然后只认 `id`。对不上就是硬失败。
- **客户端钥匙**：每次安装随机一把（iOS 放钥匙串）。服务端在 `hello` 的认证里拿到它（`AuthRequest.client_key`）：
  设备令牌第一次成功 `welcome` 时绑定到这把钥匙，之后同一令牌换了钥匙就 `unauthorized`（直到重新配对）。绑定存在
  服务端自己的设备库里，Link 只负责把钥匙交给认证回调。
- ALPN `yoyo-link/1`。QUIC 握手之后的一切都是端到端加密，中继只看到密文。

## 端点、地址、路径

- 服务端绑 UDP `0.0.0.0:<端口>` 和 `[::]:<端口>`（IPv6 绑不上不算错）。uu 的 Mac 和 Linux 用 47820/udp，嵌入方自己选。
  iroh 自带的端口映射只在它的网络探测（net report）之后才映射，而那要有中继；中继列表为空时它从不映射。所以端口映射由 App
  做（Mac：远程访问那套 `PortMapper`，UDP），把路由器给的公网 `ip:port` 交给端点（`add_external_addr`），它就和本机地址一样进
  `direct`、进打洞；映射没了或换了就 `remove_external_addr`。`EndpointConfig.portmapper` 仍可打开 iroh 自己的（Mac 服务端关着它：
  两个映射器抢同一个端口的条目）。
- 没有 DNS / pkarr 查找；中继只用配置的列表（可以为空：只走直连，也打不了洞——打洞的信令经中继）。uu 自己的中继是
  `https://relay1.yoyocontrol.com/`（`relay/iroh/`，iroh 官方的 `iroh-relay`，版本同 `link/Cargo.lock` 的 iroh；OVH 美西的一台 VPS，
  不限流量）：Mac / Linux 服务端的默认 `relays`、手机端点的默认中继都是它；中继只见密文，QUIC 握手仍是端到端。
  实测（2026-11-04，Mac 在温尼伯）：经它的会话 RTT ≈ 80 ms，8 Mbps 数据报 0 丢，8 MiB 下载 49 Mbps。
- `addr_info()` = `{id, relays, direct}`：本机网卡地址、路由器映射、对端观察到的地址；`watch_addr` 在变化时通知。
- 客户端拨 `{id, relays, direct}`：`direct` 是服务端发布的地址 + 配对链接里的。iroh 同时试、打洞、保留多条路径，
  选 RTT 最好的。
- 网络变了（iOS 的 `NWPathMonitor` 每次更新）就调 `network_changed(iface)`：立刻重新探测地址和路径；`iface` 记进统计。
- 保活：连接 5 s、每条路径 5 s；空闲 20 s 断开。连接死了会话就结束，由上层的连接器重新竞速。
- 路径分类（日志、界面）：

  | 值 | 含义 |
  | --- | --- |
  | `relay` | 经中继 |
  | `lan` | 对端地址是私有 / 链路本地 / 回环 / ULA（fc00::/7）|
  | `direct` | 公网地址，且是客户端拨过的（服务端：连接最初来的那个地址）；同一公网 IP 换了端口也算 |
  | `punched` | 公网地址，打洞得来的 |

  另有客户端的网卡 `wifi` / `cellular` / `wired` / `other`（App 告诉 Link）。100.64/10（CGNAT、Tailscale）按公网算。

## 会话协议

### 控制流

客户端开的第一条双向流。帧 = `u32 BE 长度` + UTF-8 JSON 对象（带字符串 `t`），每帧最多 256 KiB。

1. 客户端 → `{"t":"hello","v":1,"credential":"<不透明>","device":{"id","name"},"app":{"name","version"},"features":[…]}`，
   握手完成后 5 s 内，否则服务端用代码 4 关掉。
2. 服务端 → `{"t":"welcome","v":1,"server":{"id","name","platform"},"principal":{…},"features":[…],"maxDatagram":n}` 或
   `{"t":"denied","code":"unauthorized"|"rate-limited"|"busy","message"}` 然后关闭（客户端读到后用对应代码关掉；服务端最多等 2 s
   再自己关）。客户端没读到 `denied` 就看到代码 1 / 2 / 3 的关闭，按同样的拒绝处理。认证回调 10 s 不答 = `busy`。
3. 之后两边随时可以发控制消息。Link 本身只处理 `bye`（关闭前发）和 `link.stats`（每 2 s 一次，见「统计」，不交给 App），
   其余原样交给 App：

| `t` | 方向 | 字段 | 含义 |
|---|---|---|---|
| `video.open` | c→s | `id`, `query` | 开一路视频；`query` 就是现在 `/stream` 的查询串 |
| `video.opened` | s→c | `id`, `codec`, `width`, `height`, `headers` | 现在的响应头（X-Display、X-Stream-Codec…）|
| `video.error` | s→c | `id`, `status`, `message` | 同现在的 HTTP 错误 |
| `video.close` / `video.closed` | 双向 | `id`, `reason?` | |
| `video.status` | s→c | `id`, `json` | 现在的状态分段 |
| `cursor.shape` | s→c | `id`, `shapeId`, `shape` | 指针形状（位置走数据报）|
| `audio.open` / `audio.opened` / `audio.close` / `audio.closed` | | `id`, `query` / `codec`,`rate`,`channels`,`frames`,`cookie`,`videoOffsetMs` | 现在的 `/audio` |
| `keyframe` | c→s | `id` | 解码器接不上了 |
| `report` | c→s | 现在 ack 里的 `report` 对象，每 2 s | |
| `control.take` / `control.release` | c→s | `rid` | 要 / 放控制权 |
| `control` | s→c | `rid?`, `granted`, `holder` | 回答 + 每次变化 |
| `input.rejected` | s→c | `seq`, `status`, `code`, `message` | 某个输入被拒 |
| `link.stats` | 双向 | 见「统计」 | 每 2 s |
| `bye` | 双向 | `reason` | 有序关闭 |
| `link.probe` / `link.probe.stop` | c→s | `id`, `stream`, `ms` / `id` | 测速（「测速」；Link 自己处理，不交给 App） |
| `link.probe.started` / `.done` / `.error` | s→c | 见「测速」 | 测速的回答（Link 自己处理） |

字段的细节（Mac 服务端这样做，客户端照此）：

- 流的 `id` 是 1–255 的整数，就是数据报里的 `stream` 字节（视频、声音各自的编号空间）；不对 → `video.error` 400，已开着 → 409。
- `video.opened.headers`：`X-Stream-Codec`、`X-Display`（真实显示器时）、`X-Stream-Id`（查询串有 `stream=` 时）；`width` / `height`
  是显示器按 `maxWidth` 算出的画面大小（不知道时 0，以帧的 meta 为准）。之后每个 `video.close`、出错或采集停止都以
  `video.closed {id, reason}` 结束（出错时先有 `video.error`）。
- `video.status.json`：现在状态分段的对象（`ScreenDisplayState` + `console`），不是字符串；画面不可用时发完它就 `video.closed`。
- `cursor.shape`：`{id, shapeId, shape: {id, png, hotX, hotY, width, height}}`（现在指针分段里的 `shape`）；位置的数据报 JSON 是
  `{x, y, visible, shapeId}`，坐标同 `/input`。
- `audio.opened`：`codec: "opus"`、`rate`、`channels`、`frames`、`cookie`（base64，有时才有）、`videoOffsetMs`（现在的
  `X-Audio-Video-Offset`）。开不了时 `audio.error {id, status, message}`（`/audio` 会回的状态码，如 503）；结束时
  `audio.closed {id, reason}`。
- `report`：`{"t":"report","id":<视频流 id>,"report":{…}}`，`report` 是现在 ack 的 `report` 对象（铺在消息里也收）。
- `control`：`granted` = 持有者是不是这个会话的设备，`holder` = `{id, name}` 或 `null`；`rid` 原样带回（数字或字符串）。
- `input.rejected.code`：`no-control`（没拿控制权）、`controlled-elsewhere`（别人拿着）、`bad-event`（400）、`no-permission`
  （403，没有辅助功能权限）、`unauthorized`（设备已被移除）、`rate-limited`（429）；`status` 是 `POST /input` 会回的状态码，
  `message` 是它的 `error`；`controlled-elsewhere` 时带 `controllerDevice: {id, name}`（同 `/input` 409 的正文）。

QUIC 应用关闭代码：0 正常、1 unauthorized、2 rate-limited、3 busy、4 协议错误、5 关机、6 被顶替。

客户端这一边（iOS 的 `YoyoLinkClient` 就这样发、这样读）：

- 流的 `id` 由客户端选（1–255），客户端在发 `video.open` 之前先 `open_video(id)`（画面可能比 `video.opened` 先到）；`query`
  是 `/stream` 的查询串，但不带 `ack`（这条路上没有确认窗口）。`video.status.json` 也收它的文本；`cursor.shape` 当成一个
  `{shapeId, shape}` 指针分段；`audio.error` 之后这一路就没了（404 / 403 / 501：这次访问不再要声音）。
- `report` 在画面流着时最多每 2 s 一次，放在 `report` 字段里。
- `control.take` 没拿到、`holder` 是别的设备 → 当成 `controlled-elsewhere`；没拿到又没有别的持有者 → 409。
- `input.rejected` → 同 `POST /input` 失败时的错误：带 `controllerDevice` 的 `controlled-elsewhere` 显示「谁在控制」，其余按
  `status`（409 结束控制，401 = 设备被移除）；离散输入 2 s 没确认（`InputFailed`）按网络失败处理。
- 已配对手机的 `hello.credential` 是 `Bearer <设备令牌>`（还没配对的浏览器用 `Pair <配对码>`，见「配对」）；`hello.features` 现在是 `["screen","audio","cursor","input"]`（只是说明）。

### 配对

服务端也可以在 Link 上直接配对（浏览器只有这条路，`REMOTE.md`「配对」）：`hello.credential = "Pair <配对码>"`，`hello.device` = 要配对的
设备 `{id, name}`。Mac 的默认模式照 `REMOTE.md`「配对」办（码检查、设备库、`id` / `name` 规则），新令牌马上绑到这个会话的客户端钥匙
（QUIC：Link 钥匙；rtc：`dtls-sha256:<hex>`），然后：

```
welcome.principal = {"device":{"id","name"},"token":"<设备令牌>","server":{"id","name"}}
```

会话接着就是这台设备的（不用重连）；客户端把 `token` 存起来，以后用 `Bearer <token>`。只有配对的这次 `principal` 里有 `token`。
拒绝：码不对 / 过期 / 没在显示、`device.id` 不对 → `unauthorized`（`message` 说明原因，失败照样记进守卫）；设备满了 → `busy`。
主人模式里 `Pair …` 和别的凭据一样交给主人；Linux 服务端还没有（只认 `Bearer`）。

### RPC 流

控制流之后客户端开的每条双向流是一个请求：`u32 长度 + {"m","p","h"}`，然后是请求体直到 FIN；回答 `u32 长度 + {"s","h"}`，
然后是回答体直到 FIN（可以流式：`/events` 的 NDJSON、`/clipboard/file`）。头的名字一律小写，头部最多 64 KiB。服务端把请求交给
App 的处理器（它走现有的 HTTP 路由，同远程访问的白名单，认证结果是会话的 `principal`）。

- `/stream`、`/stream/ack`、`/audio`、`/input`、`/control` 在 RPC 上回 404（它们是通道 / 控制消息），由 Link 直接回，不到处理器。
- 请求体最多 8 MiB（可配），超了回 413。同时最多 32 条 RPC 流（QUIC 的流数上限：控制流 + 32）。服务端不开流。
- 客户端取消（停止读）后，服务端的写入失败，`stopped()` 返回。处理器没 `finish` 就丢掉回答者：流被重置，客户端看到错误，
  不是截短的正文。

### 数据报

字节 0 = `通道 << 4 | 1`（版本 1），整数大端。通道：1 视频、2 声音、3 输入、4 反馈、5 指针，归会话里的媒体层
（下面「媒体」）；6–15 给 App 自己用（探测工具用 14、15），每个通道一个接收队列（2048 个，满了丢新的并计数）；版本或通道
不对的丢掉并计数。发送时 QUIC 的发送缓冲满了会挤掉最老的
还没发的数据报（新的赢）。下面的格式由媒体层（`uu-link-media`）编解码：

`tseq` = 每个方向一个 u32 传输序号，跨所有媒体类数据报（视频、声音、指针），是码率控制的包号。

- **视频 (1)** `u8 hdr, u8 stream, u8 flags, u8 block, u32 tseq, u32 frame, u16 shard, u16 k, u16 m, u16 shardSize`（20 字节）+ 分片。
  flags：0x01 校验片、0x02 重传、0x04 关键帧、0x08 恢复帧、0x10 最后一块。帧的字节 = meta（`u8 ver=1, u8 codec 1=h264 2=hevc,
  u8 kind 0 delta 1 key 2 refine 3 keepalive 4 recovery, u8 0, u16 width, u16 height, u64 采集时间 µs, u32 恢复基准帧（0 无）,
  u32 AU 长度`）+ Annex-B AU；按 ≤ 32 个数据片分块，Reed-Solomon 校验片紧跟其后。
- **声音 (2)** `u8 hdr, u8 stream, u8 r, u8 flags, u32 tseq, u32 aseq, u64 时间 µs, u16 len, opus`，再跟 `r` 个旧包
  （`u16 aseqDelta, u16 len, opus`）。
- **输入 (3)** c→s `u8 hdr, u8 flags, u16 n`，再 n 个 `u32 seq, u8 kind（0 离散 1 移动）, u16 len, JSON`（JSON 就是现在 `/input`
  的事件）。不占 `tseq`。
- **反馈 (4)** `u8 hdr, u8 nSections`，每段 `u8 type, u16 len, 内容`：1 transport-cc、2 nack、3 帧报告、4 输入确认、5 声音报告。
- **指针 (5)** s→c `u8 hdr, u8 stream, u32 tseq, u32 cseq, JSON {x,y,visible,shapeId}`，cseq 大的赢。

### 测速

这条会话的路径能带多少画面，按画面走的路量（不是另一种测法）：服务端的**会话本身**（不是 App）在客户端开的一路视频流上发填充帧，
走同一套 FEC、NACK、发送节奏、帧率上限和码率控制，客户端的媒体层收下就当解码成功并计数。所以结果就是这时开屏幕会得到的：
码率控制爬到哪、停在哪、多少帧、丢了多少、冻结几次、负载下 RTT 涨多少。Mac、Linux、Windows 服务端都有（在 Link 核心里），
App 不用做什么。

1. 客户端在媒体层开一路测速流（`ClientMedia::open_probe`：它的帧不变成 `Frame` 事件，到了就确认、计数；没被占的最大流号，
   一般 255），发 `{"t":"link.probe","id":<数>,"stream":<1–255>,"ms":<时长>}`。
2. 服务端：`ms` 夹到 1000–20000（缺省 8000）；同一会话同时只有一个测速，流号已开着 → `{"t":"link.probe.error","id","message"}`。
   否则开这路流、回 `{"t":"link.probe.started","id","stream","ms"}`，然后按 60 Hz 的帧钟：发送闸门（`send_gate`）开着就发一帧，
   大小 = 编码器码率 / 8 / 帧率上限（1000 B–1 MiB，像一直在滚动的屏幕），第一帧和每次丢帧之后（`RecoveryNeeded` /
   `KeyframeNeeded`，这路流的事件留在会话里，不给 App）是关键帧。
3. 到时（或 `{"t":"link.probe.stop","id"}`）关掉这路流，回 `{"t":"link.probe.done","id","stream","ms","reason":"done"|"stopped",
   "frames","bytes","targetMbps","maxTargetMbps","encoderMbps","fpsCap","sentMbps","rateCuts","rateLossCuts","retransmits",
   "jitterMs"}`（服务端这一边：码率控制最后的和最高的目标、编码器码率与帧率上限、实发、下调次数、单程延迟抖动）。会话断了就不回。
4. 客户端的报告（`ProbeReport`，驼峰 JSON）：`transport`、`path`、`iface`、`durationMs`、`rttIdleMs`（开始前 10 s 的最小 RTT）、
   `rttP50Ms` / `rttP90Ms`（测速期间每 100 ms 采一次）、`frames`、`receivedMbps`（全程的载荷码率）、`peakMbps`（最好的 1 s）、
   `finalMbps` / `finalFps`（最后 2 s：码率控制停在哪）、`lossPct`（FEC 前的丢包）、`fecRecovered`、`nackRecovered`、`lostFrames`、
   `skippedFrames`、`freezes`、`freezeMs`，以及 `server`（上面 `done` 的字段；没收到是 `null`）。

- 3 s 没有 `started` = 服务端没有测速（旧版本把这条消息交给 App，App 不理）：客户端报超时。
- 会话里别的视频流开着时，编码器码率按流平分，测速只拿到它那份：测速用一条不显示画面的会话。
- 时长：码率控制的起步每秒涨 50 %，3.5 Mbps 到 20 Mbps 的天花板约 4.5 s；8 s 让它爬完，再看最后 2 s。
- 实测（2026-11-09，`uu-link-probe dial-rtc --speed-test 8000` 经 netem）：`5g` 最后 15.3 Mbps / 55 fps、FEC 前丢 5 %（FEC 补 408、
  NACK 补 105）、不丢帧，RTT 89 → 103 ms；`bad` 最后 0.6 Mbps / 11 fps、冻结 11 次 3.7 s；本机（`lan` 档天花板 40 Mbps）最后 35.7 Mbps / 60 fps。

## 媒体

每个会话带一个媒体层（`uu-link-media`，无 I/O）：服务端一个 `ServerMedia`，客户端一个 `ClientMedia`。会话里一个驱动任务跑它的
循环：对端来的通道 1–5 的数据报交给它，它要发的（`poll_transmit`）放进 QUIC 的数据报队列，它的事件交给 App，它要的定时器
由驱动任务来等。会话每 100 ms 把所选路径的 RTT 和当前最大数据报喂给它；服务端从客户端的 `link.stats` 得到网络类型（`lan` →
Lan、`cellular` → Cellular，其余 Default）；QUIC 判定持续拥塞时告诉它的码率控制。数据报的发送时间取 `poll_transmit` 的时刻
（noq 不报告真正离开的时刻）。

- 服务端：`open_video(stream)`（每个 `video.open`，帧号从 1 开始）、`can_send_frame(stream)`（false = 这一张别编了；
  也按帧率上限挡住来得太早的一张）、`frame_rate_cap(stream)`（帧率上限，见下）、
  `send_frame(stream, meta, au)`、`open_audio` / `send_audio(stream, time_us, opus)`、`send_cursor(stream, json)`、
  `request_keyframe(stream)`；事件 `recv_server_event()`：`TargetBitrate { target_bps, encoder_bps }`（编码器用 `encoder_bps`）、
  `FrameDelivered`（LTR 确认）、`RecoveryNeeded { last_delivered }`、`KeyframeNeeded`、`Input(InputEvent)`（交给现有的输入处理）。
- 客户端：`open_video` / `open_audio`（每个 `video.opened` / `audio.opened`）、`send_input(kind, json)`（离散 / 移动；溢出 = 本地 429）、
  `frame_decoded(stream, frame, ok)`、`request_keyframe`；事件 `recv_client_event()`：`Frame`（按序、参考链完整）、`Audio`、
  `Cursor`、`InputAcked { through }`、`InputFailed { seq }`。
- 服务端会话的 `TargetBitrate` 跟着码率控制的 `TargetRate`；`set` 是它旁边的下限（`max`，默认 0，比如大文件传输时用）。
- `link:` 行的媒体字段（loss、fec、nack、lost、skip、freeze、rate、cuts、jitter、fps、input、audio）来自媒体层（媒体动过之后才有）；
  `set_media_stats` 给的字段优先。
- 抖动的路径（5G：延迟起伏几十毫秒、后面没有队列）：码率控制量出路径的抖动（10 s 内每 100 ms 里单程延迟的极差取中位数），
  「有排队」「持续排队」的门槛都至少是它的 1.5 倍；趋势判成「下降」（underuse）而没有排队时码率照样往上走。客户端的安静计时
  （一块的分片停了多久算发完、缺的去要）按结果学：要过之后先到的是原包 = 只是晚到，晚到的比例把等待拉长到 2 s 内帧内最长的
  分片间隔（≤ 60 ms）；真丢包多的路径保持短等待。（以前在 5G 上：码率卡在 1–3 Mbps，NACK 几百个、补回 0。）
- 码率下调后的天花板（蜂窝网 120 s）：上次下调后 10 s 没有排队、目标顶着天花板时，天花板按增长速度（每秒 8 %）往上抬——小区
  空出来时码率能回去（以前一次下调就把 5G 上的码率钉在 5.3 Mbps 两分钟）；真有瓶颈时排队出现，下一次下调定新的天花板。
- 帧的期限 = 首片到达 + clamp(1.5 × RTT 中位数, 60, 200 ms) + 最近 10 s 帧内分片之间最长的停顿（≤ 150 ms）：5G 的调度停顿
  把一帧的分片扣住 50–150 ms 再一起送到，期限没算上它时帧被放弃，什么都没丢也要冻结、等恢复帧。
  长路径（RTT 过 ~130 ms）上 200 ms 放不下一轮 NACK（要在期限前 1.2 个 RTT 发出），FEC 补不上的帧全丢、都等恢复帧（x264 是
  关键帧，低码率下很糊）：路径**持续**有随机丢包时（客户端最近 10 s 里 2 s 丢包率的最低值 ≥ 2 %，`nack_deadline_loss`），期限至少
  1.5 × RTT 中位数（≤ 600 ms），一轮 NACK 放得下。只排队不丢包的路径不放宽：那里的分片只是晚到，NACK 会把重发灌进满着的队列。
- 起步：会话里还没下调过（没有天花板）时，码率每秒涨 50 %（平时 8 %），发出去的有目标的四分之一就算用满（平时一半）；丢包超过
  丢包门槛、又不是随机丢包时按平时的涨。屏幕是一阵一阵地发（静止、打字、然后整屏滚动）：以前 5G 上从 3.5 涨到 20 Mbps 要 ~100 s，头一分钟
  滚动只有 11 Mbps。第一次下调（排队、丢包）就结束起步。
- NACK 发两遍：每个 NACK 10 ms 后单独再发一次（`ClientConfig::nack_repeat`）。5G 上来不及第二轮 NACK，一个上行数据报丢了就是
  一帧丢了加 ~250 ms 冻结；发送端对半个 RTT 内重发过的分片不理重复的请求。
- 随机丢包不降码率（`LossKind`）：按丢包降码率（1 s 里 > 10 %、持续 1 s → `目标 × (1 − 0.5 × 丢包率)`）只对**像拥塞的**丢包。
  随机丢包（丢包多的跨洋线路、无线）在什么码率下都一样多，降码率降不下来，只让画面变糊（实测：RTT 280 ms、空闲时也丢 8 %、
  1 kbit/s 的声音也丢 11–13 % 的线路，码率被压到 0.3 Mbps 的下限）；它交给 FEC 和 NACK。判别（GCC v2 的「固有丢包」、BBR
  不把少量丢包当拥塞是同一个意思：拥塞的丢包随发送速率涨）：
  - 拥塞：丢包 > 40 %（FEC 扛不住）；或丢包放过了每阵数据报的头一个（停 ≥ 5 ms 后的那个：队列空了、限速器的桶满了，满队列、
    限速器只丢一阵里后面的，随机丢包同样丢头一个）——后面的比头一个多丢 5 个百分点以上（且超过 3 个标准误差）；或最近 1 s 发得
    明显快（≥ 1.2 倍）时比之前慢的时候多丢同样多（`loss_grows_with_rate`，数据报按发送时间每 500 ms 一格，看 20 s）。
  - 随机：比明显慢的时候不多丢，或比明显快的时候不少丢；判成随机的丢包率记下来，之后丢包不超过它（加余量）、又没有排队时
    照样算随机。码率不降，也不停止上涨（真有瓶颈时排队或随速率涨的丢包会出现）。有排队时由按延迟的规则去降。
  - 分不出（发送速率几乎没变）：降到 0.75 倍、停 5 s 不涨，慢下来的这段说明是哪种。
  - 实发码率仍算 FEC：`encoder_bps = (目标 − 声音) × (1 − FEC 比例) × 0.95`。
- FEC：`r = clamp(5 % + 2.5 × 丢包率, 5 %, 50 %)`，此外丢包 > 0.5 %（≤ 30 %）时每块至少给到「块解不出来的概率 ≤ 1 %」
  （按独立丢包算二项分布，`FecPolicy::residual`）：只按比例时小块在大丢包下不够，15 % 丢包下 5 片的块配 3 片校验有 2 % 解不出，
  60 fps 下每半秒丢一帧。
- 帧率上限（`VideoSendConfig::fps_steps`）：按编码器码率分档：≥ 3.5 Mbps 60 fps、≥ 1.3 Mbps 30、≥ 0.7 Mbps 20、≥ 0.4 Mbps 15、
  更低 10（不超过流自己的 fps；往上一档要 1.2 倍的码率，不在边界上来回跳）。低码率下帧多了每帧分到的就少，滚动的文字是糊的；
  帧少些、每帧清楚些。`can_send_frame` 挡住比 `0.85 / 上限` 来得早的一张；每帧的预算按上限算；视频放出去的速度（平时目标的 1.8 倍）
  超出目标的部分乘 `√(上限 / fps)`（帧大了，一阵发得太快会在瓶颈的队列里待得久）。按时间算码率的编码器（VideoToolbox）帧少了每帧
  自然大；按帧算的（x264 不开 VFR）要告诉它：Linux / Windows 服务端给 x264 `encoderBps × fps / 上限` 的码率，VBV 缓冲仍是 1 s 的真实
  码率（关键帧不跟着变大）。

## 拥塞控制（MediaCc）

每个会话的每条路径都用 `MediaCc`：`cwnd = max(2 × target × srtt, 16 × MTU)`，`target` 是这个会话共享的目标码率（`TargetBitrate`：
服务端是媒体层码率控制的 `TargetRate`，客户端是固定的 3.5 Mbps；所有路径读）。随机丢包不缩窗（FEC 管）；QUIC 判定持续拥塞时把目标降到下限（300 kbps，
窗口随之到最小）并计数（`persistent_congestion_events`），码率控制据此从下限重来。pacing 用 QUIC 默认的（窗口 / srtt × 1.25）。
这样 QUIC 不会成为卡住画面的那一环，排队由码率控制按延迟来防。一次只发一个 UDP 数据报（`enable_segmentation_offload(false)`）：媒体层本来就匀着发，
把几个攒成一次分段发送（GSO）省不了什么；而不会分段的虚拟网卡（容器的网桥、虚拟机的）会把整批丢掉——匀速的流上那正好是一次突发的包。

## 守卫（服务端）

- 每个来源 IP 的失败（握手没完成、5 s 没 `hello`、`hello` 不对、`unauthorized`）60 s 内满 10 次，这个 IP 5 分钟内的连接在
  TLS 之前就被拒（`Incoming::refuse`）。回环和配置的豁免地址不算；经中继来的没有 IP，不算。
- 同时最多 32 个会话，其中还没 `welcome` 的最多 4 个；超了在握手前拒绝。都可配（`GuardConfig` / `GuardSettings`）。

## 统计与日志

每端每 10 s、每次路径变化、结束时记一行（日志经 App 设的 sink，没设就进 `tracing`）：

```
link: <path> <iface> rtt <min>/<p50>/<p90> ms loss <FEC 前 %> fec <FEC 补回的片> nack <补回>/<发出> lost <帧> skip <帧>
      freeze <次>/<ms> rate <目标>/<实发> Mbps cuts <按延迟>/<按丢包> jitter <ms> ms fps <送出的帧> input <p50>/<p90> ms (<n>)
      audio loss <%> red <r>
```

RTT 取最近 10 s（每 250 ms 采一次所选路径的 RTT）。媒体字段由媒体层填（`set_media_stats`），没有的那段整段不写。
日志里的每一行是**这一段**的：计数（FEC、NACK、丢帧、跳帧、冻结、降码率、输入次数）是距上一行的差，fps、实发码率和 FEC 前的丢包率是
这一段的（媒体层的 `MediaStats::since`；丢包率由收到 / 没收到的媒体数据报计数 `media_received` / `media_missing` 算，服务端的来自
反馈。以前读的是 2 s 的窗口，10 s 一行时常常是 0 %，而同一段里 FEC、NACK 补回了分片）；第一行从会话开始算；`link[phone]:` 的计数同样是客户端两次 `link.stats` 之差。`stats()` / `link.stats` 仍是从会话开始累计。
服务端记两行：`link[server]:`（自己）和 `link[phone]:`（客户端最近一次 `link.stats`）。另有
`link session opened <设备> <path>`、`link session closed <设备> after <s> s: <原因>`、`link path <旧> → <新> (<地址>)`。

`link.stats` 对象（驼峰）：`path, iface, remote?, rttMinMs, rttP50Ms, rttP90Ms, bytesSent, bytesReceived, packetsLost,
datagramsSent, datagramsReceived, datagramDrops`，以及有值的媒体字段 `lossPct, fecRecovered, nackRecovered, nackSent, lostFrames,
skippedFrames, freezeCount, freezeMs, rateTargetMbps, rateSentMbps, rateCuts, rateLossCuts, jitterMs, fps, inputP50Ms, inputP90Ms, inputN, audioLossPct, audioRed`。

### 逐帧跟踪

给实测调优用：Mac 服务在 `LinkOptions.traceDirectory`（`YOYO_LINK_TRACE`，App 设成日志目录的 `link-trace/`，`off` 关）里给每个
会话写一个 `<开始时间>-<设备>.jsonl`，一行一个 JSON 对象；整个目录超过 2 GB 时开新文件前删最旧的。日志里有一行
`link <设备>: trace <路径>`。每条记录有 `t`（类型）和 `at`（Mac 的开机时钟，ms：文件里 Mac 一侧的时间都是它）：

- `session`（设备、路径、远端地址）、`clock`（每 5 s：媒体层的会话时钟 `mediaUs` 和墙钟，对上 `at`）、`end`。
- `cap`：ScreenCaptureKit 的每次回调：`st`（SCFrameStatus，0 = complete）、`gated`（被 fps 闸门丢掉）、`seq`（最新收下的画面号）、
  `latMs`（显示 → 回调）。
- `enc`：每张编出去的画面：`seq`（采集号）、`frame`（Link 帧号）、`kind`、`bytes`、`encMs`、`bitrate`、`capWaitMs`（回调 → 开始编）、
  `capToSentMs`、`sendMs`（`send_frame`）、`sinceLastMs`；`missed`（上一张编出去之后收下了却没编的画面数）和 `cause`：
  `held` = 期间 `can_send_frame` 关过（Link 的队列满），`busy` = 没关过（循环在编码、在等 fps 上限）；`heldChecks` / `heldMs`
  （关了几次、多久）、`capSleepMs`；`gate`：关着时媒体层的数（`why` = `queue` / `space`、`own` / `transport` 排队字节、`budget`、
  `limit`、`estimate`、`targetBps`、`pacingBps`，FFI 的 `send_gate`）。`drop`：编码器丢掉的画面。
- `tx`：媒体层每帧的出口（`take_tx_traces`；时间已换成 Mac 的开机时钟）：`enq`（进队列）、`firstOut` / `lastOut`（第一个 / 最后一个
  原始数据报离开限速器）、`acked`（手机的帧报告说已解码）、`lost`、`au` / `wire` 字节、`dgrams`、`parity`、`retx`（为 NACK 重发的片）、
  `ahead`（前面排着的字节）、`targetBps`、`pacingBps`、`fec`、`queueDelayMs`、`rttMs`。帧报告到了，或进队 3 s 后写出。
- `rate`：`TargetBitrate`（`targetBps`、`encoderBps`）；`need`：恢复帧 / 关键帧请求；`stats`：每秒的 `stats()`（`phone`：`peer_stats()`）。
- `phone`：手机每 2 s 的 `report`（播放报告本身，`clock` = 手机的 `hostMs` / `hostNowMs` / `mediaUs` / `wallMs`），它带来的
  `rx`（手机媒体层每帧的结局，`take_rx_traces`：`fate` = delivered / skipped / lost、`firstMs` / `lastMs` / `completeMs` / `decidedMs`
  = 手机会话时钟、`shards`、`fec`、`retx`、`nacks` = 为它发的 NACK 条数）和 `ph`（手机解码、显示：`arrivalMs` = 手机开机时钟，
  `decodedMs` / `shownMs` 是距到达的 ms，`decodeMs`、`ok`；`e2eMs` = 手机墙钟到达 − Mac 采集时间，含两边时钟差）。

`scripts/link-trace.py [文件]`（默认最新的一个）读它：每 10 s 的 fps 漏斗（采集 → 闸门 → 编码 → 没编的原因 → 发出 → 手机
送达 / 跳过 / 丢 → 显示）、各段延迟的 p50 / p90 / p99 / max、闸门原因、码率目标、手机上最长的几段空白和其间那些帧的结局；
`--frames out.csv` 按帧号把 `enc` + `tx` + `rx` + `ph` 拼成一行一帧。

## WebRTC（浏览器）

浏览器打不开任意的 UDP / QUIC，也钉不住自签的证书；WebRTC（RTCPeerConnection + DataChannel）Safari / Chrome / Firefox 都有，
自带 ICE（局域网、路由器映射、STUN 打洞）和 DTLS。所以 Link 有第二种传输 `rtc`：一条 PeerConnection 就是一个会话，上面跑
**同一个**会话协议 v1（hello / welcome、控制消息、RPC、数据报通道 1–15）和**同一个**媒体层。服务端用
[str0m](https://github.com/algesten/str0m)（sans-IO 的 ICE / DTLS / SCTP，和 Link 自己的驱动方式一样：一把锁下「改 → 取完输出」，
每个连接一个计时任务），跑在端点自己的 UDP 套接字上（`EndpointConfig::rtc`）。选它是因为：没有自己的线程和 I/O（能放进 Link 的
tokio 运行时和套接字）、有完整的 ICE（服务端也打洞）、数据通道全（协商 id、部分可靠、DCEP）、纯 Rust 能交叉编到 iOS / Linux；
webrtc-rs 自带线程和异步栈，libdatachannel 是 C++。

| QUIC 会话的部分 | WebRTC |
| --- | --- |
| 控制流 | DataChannel `control`，negotiated id 0，有序、可靠；同样的帧（`u32 BE 长度` + JSON），不管消息边界 |
| 每条 RPC 流 | 客户端新开的 DataChannel `rpc`（DCEP），有序、可靠。请求头帧 + 体；体的结束 = 一条零长度消息（FIN）；回答一样；不带 FIN 关掉通道 = 重置。客户端读到回答的 FIN 后关掉通道（服务端不关完成了的通道：关通道的一方会复用 SCTP 流号，服务端去关会和客户端的下一条撞上）；同时最多 32 条 |
| 数据报 | DataChannel `dgram`，negotiated id 1，`ordered:false, maxRetransmits:0`；一条消息 = 一个数据报（同样的字节，字节 0 = `通道<<4\|1`），最大 1200 字节（含头：一个 SCTP 包） |
| 关闭代码 + 原因 | `control` 上的 `{"t":"bye","code":n,"reason":"…"}`，然后关 PeerConnection（250 ms 后）。收到的一方按 `code` 关 |
| 路径的 RTT | 选中的候选对上 ICE 保活（STUN）的往返（服务端每 ≤ 250 ms 一次检查，str0m 每 250 ms 报一次）；客户端用 `getStats()` 的 `currentRoundTripTime` |
| 路径种类 | 对端地址私有 → `lan`；客户端到了服务端在答复里给的 host 地址（网卡的、路由器映射的）→ `direct`（服务端：有映射或对端给的是公网 host）；其余（srflx / prflx）→ `punched`。没有 `relay`（这一轮没有 TURN） |
| 断开 | 服务端：ICE `disconnected` 10 s → 会话结束（`timed out`）；PeerConnection / `control` 被关 → 结束（对端，没有代码）。浏览器（link-web）：PeerConnection 或 ICE 一到 `disconnected` / `failed` 就结束；开着视频流时 3 s 什么都没收到（服务端每 2 s 有 `link.stats`，还有流的保活）就结束，别的时候 20 s——有别的路的页面几秒内回落 |

- 发送缓冲：会话自己的数据报队列（1 MiB，同 QUIC）在前，SCTP 在 `dgram` 上最多存 1 MiB（含在途的）；队列满了挤掉最老的没发的（新的赢）。
  `datagram_send_buffer_space` 只算会话自己的队列（SCTP 那 1 MiB 是在途的，见下）。流的写在通道存够 192 KiB 时等。
- 消息切成 ≤ 16 KiB：没有 SCTP 消息交错（RFC 8260），大消息会挡住别的通道。

### 信令

浏览器把 offer 经**某条路**（宿主自己的 HTTP、uu 的中继、本机程序）交给服务端，拿回 answer：

- 客户端 → `{"v":1,"offer":"<SDP>","device":{"id","name"}}`。不 trickle：等 ICE 收集完（≤ 1 s）再发；mDNS 的 `.local` host 候选可以带
  （服务端跳过解析不了的：对端的检查到了照样按 prflx 认出来）。
- 服务端 → `{"v":1,"answer":"<SDP>","fingerprint":"sha256:<hex>","binding":{id,key,sig},"sig":"<b64 r‖s>"}`（offer 带了 `rk` 时还有
  `"restarts":true`，下面「换网络」）。`fingerprint` = 服务端 DTLS
  证书的 SHA-256，小写十六进制不带冒号；`binding` 就是 `/status.link` 的绑定；`sig` = **身份钥匙**（P-256）的 ECDSA-SHA256，签的是 UTF-8 的
  `"yoyocontrol-rtc-v1:" + hex(SHA-256(offer SDP 的字节)) + ":" + fingerprint`。
- 客户端核对 `SHA-256(binding.key) == 钉住的指纹`（同 Link 的绑定）、用 WebCrypto 验 `sig`、answer SDP 的 `a=fingerprint:sha-256 AA:BB:…`
  （去冒号、小写）等于 `fingerprint`；任何一项不对都是硬失败。签名不覆盖 answer 的其余部分（ICE 凭据、候选）：改了它们只会连不上——DTLS
  还是要出示签过的证书——而能改 answer 的路本来就能把它扔掉。
- 服务端的候选：每个网卡地址在 rtc 端口上（host）、路由器映射（`add_rtc_external_addr`，也作为 host 给出）、配了 STUN 时问来的公网地址
  （srflx，`RtcConfig::stun_servers`，每 5 min 和网络变化时重问）。每个公网 IPv4 候选在应答里还以 NAT64 地址再给一次
  （`64:ff9b::<v4>`，同一端口，优先级低一点，`signal::with_nat64`）：只有 IPv6 的网络（5G + NAT64）上的浏览器用不了 IPv4 候选
  （Safari 不像系统给 App 那样合成 IPv6），经运营商的 NAT64 这个地址就到了同一个 IPv4 地址和端口；它的检查以 NAT64 的 IPv4 到达，
  ICE 当 peer-reflexive 认。只在 SDP 里，str0m 不知道它（服务端不从它发）；没有 NAT64 的网络上这对候选只是连不通。`RtcConfig::external_only`：只给映射和 STUN 的（容器、经 netem 的测试）。
  客户端用宿主给的 `iceServers`（默认没有；uu 的网页和 nest 给 `stun:stun.cloudflare.com:3478`；uu 的网页每次拨之前还向中继要 relay1 的
  TURN，`RELAY.md`「TURN」：直连不上时浏览器经它转发；服务端认得出：选中的对端地址是 offer 里 `typ relay` 的候选，路径就是 `relay`）。ICE：服务端是完整的 ICE（不是 lite：
  它也要发检查去打洞），客户端是 offer 方（controlling）。
- 认证不变：`control` 上 `hello.credential`（设备令牌 / 主人模式的凭据）。`AuthRequest.client_key` / `Session::remote_id()` =
  `"dtls-sha256:<hex>"`（浏览器 DTLS 证书的指纹，offer 里的 `a=fingerprint`，DTLS 验过）：设备令牌第一次用时绑定它，像绑定 Link 钥匙一样。
  所以浏览器要一直用同一张证书（`RTCPeerConnection.generateCertificate({name:"ECDSA",namedCurve:"P-256"})` 存进 IndexedDB）；换了证书 =
  重新配对（Chrome 的证书最多一年）。
- 守卫：一个 offer = 一个等着的会话（占「没认证的」4 个名额之一，同 QUIC 的一起算）；10 s 内要连通（ICE + DTLS + SCTP，`control` 打开），
  之后 5 s 内 `hello`。失败（连不通、没 hello、`unauthorized`）记在信令请求的来源 IP 上（宿主知道时传给 `accept_rtc_offer`；不知道就记在
  对端的地址上）；冷却中的来源 → `Denied(RateLimited)`，满了 → `Denied(Busy)`。

入口（都是通用的）：

1. Rust：`Listener::accept_rtc_offer(offer_json, source: Option<IpAddr>) -> answer_json`（`ServerOptions::rtc_identity`：身份钥匙
   `rtc::IdentityKey::new(97 字节)` 或任何 `IdentitySigner`）。会话从同一个 `Listener::accept()` 出来，`transport() == Transport::Rtc`。
   Swift `LinkListener.acceptRtcOffer(offerJson:sourceIp:)`（`ServerSettings.identityKey`），Node `listener.acceptRtcOffer(json, ip?)`
   （`listen({ identityKey })`）。
2. Mac `POST /link/rtc`（unix socket，`LOCAL-API.md`「浏览器的 Link」）；Linux 同样在令牌监听上。
3. 中继 `POST /v1/rtc/<fp>`（`RELAY.md`「WebRTC」）→ Mac 控制连接上的 `{"type":"rtc",…}` → `rtc-answer` / `rtc-error`。
4. 拨的一方（测试、工具、Node）：`Endpoint::dial_rtc(signal, fingerprint, hello, opts)`——`signal(offer_json)` 把 offer 送到上面任何一个入口、
   返回 answer。str0m 当 offer 方，和浏览器做的一样（Swift `LinkEndpoint.dialRtc(signaler:…)`，Node `endpoint.dialRtc(signal, fp, hello)`）。

UDP 端口：rtc 自己一个套接字（`0.0.0.0` 和 `[::]`，或 `bind_ips`；按包的目的地址认出是哪个候选），默认 Link 端口 + 1（uu 的 Mac / Linux：
47821；被别的程序占着时只有 rtc 换到随机端口，Link 端口不变）；外网直连开着时同样做端口映射（UDP）。

### 换网络：ICE restart

浏览器的网络变了（Wi-Fi ↔ 5G、换了 Wi-Fi），原来那对候选就断了。会话不重拨，只重新找路：同一个 RTCPeerConnection 做 ICE restart，
DTLS、SCTP、通道、会话（令牌、正在放的视频）都不变。

- 第一次 offer 带 `rk`：一个只有浏览器知道的秘密的钥匙（`hex(SHA-256(秘密的 UTF-8))`，`newRestartSecret`）。支持的服务端记下它
  （连接 ↔ 钥匙），answer 里多一个 `"restarts": true`；旧的服务端不认这个字段，answer 里也就没有，浏览器照旧在断路时结束会话。
- 重启的 offer：`pc.createOffer({iceRestart: true})`（新的 ICE 凭据、重新收集的候选），`{"v":1,"offer","device","restart":"<秘密>",
  "rk":"<下一次的钥匙>"}`，走和第一次一样的信令路（中继 / 信令服务）。服务端按 `SHA-256(restart)` 找到连接（钥匙用一次就作废），核对 offer 的
  DTLS 指纹是同一个浏览器的，str0m `accept_offer` 接下新的凭据和候选，answer 照常签名（浏览器照常验）。找不到 / 不是同一个浏览器：
  `InvalidArgument`，记一次失败（守卫）。中继只见过钥匙，见不到还能用的秘密。
- 什么时候重启（`LinkSession`）：ICE `disconnected` / `failed` 了 1 s 还没自己回来；或者什么都没收到超过空闲限度（看视频时 3 s，
  浏览器自己认出断路往往要 5–7 s）；或者浏览器说网络变了（`online`、`navigator.connection` 的 `change`：旧路也许还通，先把新候选交过去）。
  每次重启后等 4 s 听对方的消息（`link.stats` 每 2 s 一条），没听到再来，最多 15 s（`RECOVER_MS`）；服务端拒绝了就不再试，会话结束。
  这期间 `session.recovering` 为真（`onRecovering`），找回来了 `recoveries` 加一。
- 服务端：一条连接的路断了（str0m 的 ICE `Disconnected`）后留 10 s（`LOST_GRACE`）；收到重启时从那一刻重新算。
- 实测（headless Chrome ↔ probe，经 netem 每 14 s 黑 6–10 s，`npm -w packages/link-web run e2e -- --netem handover --netem-args "…"`）：
  黑了 3 s 认出、重启，路一通 0.5 s 内就回来，会话不断、视频从下一个关键帧接着放；以前同样的黑屏会话直接结束、重拨。

### SCTP 的拥塞控制：交给媒体层

SCTP 自带的 Reno 窗口在随机丢包的路径上会塌：5G 的 1 % 丢包让它每个 RTT 减半，媒体层按延迟调出来的码率根本发不出去（最初经 netem `5g`：
目标 3.5 Mbps，实发 0–0.5 Mbps，ping 几秒）。服务端的 SCTP 是我们的（str0m → sctp-proto），所以 `link/vendor/sctp-proto` 是 0.10.8 加
uu 的补丁（每处标 `uu patch`），让它像 QUIC 上的 MediaCc 一样不碍事：

- 窗口：起始 1 MiB，**丢包不缩**（快速恢复不减半）；超时（T3，真的断了）减半、不低于 1 MiB；快速恢复里也照样增长。发多少由媒体层的
  码率控制（按延迟）和它的步调决定；会话对每个流 / `dgram` 通道在 SCTP 里存多少有上限（上面）。
- 不可重传的块（`maxRetransmits:0`）：SACK 报告它在「最高新确认 TSN」之下缺了，就当丢了，马上放弃（FORWARD-TSN 跟着就发），不等第三次
  报告、不等 T3。FORWARD-TSN 跳过对端已经确认（gap-ack）的块：以前它停在那里，每个往返只跳过一个丢了的数据报，丢包比这多时在途的越积越多
  （5G 上一分钟积到 25 000 个块）。同一个 FORWARD-TSN 半个 RTO 内不重发（过时的 FORWARD-TSN 让对端立即回 SACK，SACK 又引出 FORWARD-TSN：
  在丢包的路上互相喂，SACK 塞满了回程）。
- 快速重传：恢复期间新报告缺了三次的块也快速重传（RFC 4960 一次恢复只重传第一个丢的，其余的等 T3，而 T3 会把整个窗口重发一遍）。
- SACK 最多 200 个 gap、16 个重复 TSN（一个包装得下；以前更大的 SACK 让 DTLS 拒绝，连接断了）。RTO 最小 200 ms、初始 1 s（RFC：1 s / 3 s）。
- 每个包上不再扫整个在途队列（没有限时消息时跳过过期检查、没有 T3 标记时跳过重传扫描、TSN 表用 FxHash、有序队列追加不再整体排序）：
  以前丢包时在途的一多，收一个包要 1 ms，接收线程跟不上，延迟（连 ICE 的 RTT）涨到几秒。
- 空消息（流的 FIN）按 RFC 8831 §6.6 发一个字节（以前根本没发出去）。

浏览器→服务端方向（输入、反馈、NACK、RPC 请求）是浏览器的 SCTP（Chrome 的 dcsctp），我们改不了；这个方向的流量小，实测（下面）输入
确认、NACK 补回都正常。

### 实测

`uu-link-probe dial-rtc`（str0m 当浏览器）和真的无头 Chrome（`packages/link-web` 的 e2e，`@yoyocontrol/link-web` 拨，wasm 媒体层），
服务端是 `uu-link-probe serve-rtc`，经 netem 时客户端只能经 `uu-link-netem` 到服务端（`--advertise <netem>` `--advertise-only`）。
2026-11-03，M 系列 Mac，release；QUIC 那列是上面「测试工具」的表：

| | rtc 回环（probe / Chrome） | rtc 经 netem `5g`（probe） | rtc 经 netem `5g`（Chrome 156） | QUIC 经 netem `5g` |
| --- | --- | --- | --- | --- |
| 到 `welcome` | 8.6 ms / 229 ms（Chrome 含 ~130 ms 收集候选） | 540–550 ms | 793 ms（收集 135 + 连通 446 + hello 94） | 197 ms |
| RPC echo p50 / p90 | 0.32 / 0.37 ms / 0.9 / 1.6 ms | 196 / 205–576 ms | 103 / 108 ms | 94 / 101 ms |
| 8 MiB RPC 下载 | 768 / 464 Mbps | 6–13 Mbps | 12.7 Mbps | 22 Mbps |
| 控制消息往返 p50 / p90 | 0.07 / 0.08 ms / 0.2 / 0.2 ms | 95 / 102 ms | 98 / 104 ms | 94 / 101 ms |
| 50 Hz 数据报 ping p50 / p90 / p99 | 0.46 / 0.79 / 2.4 ms / 0.8 / 4.6 / 6.5 ms，0 丢 | 103 / 109 / 118–124 ms，5.5–8 % 丢 | 104 / 108 / 129 ms，6 % 丢 | 96 / 101 / 110 ms，5.3 % 丢 |
| 8 Mbps 数据报负载（客户端→服务端） | 0 % 丢 | 4.4–4.6 % 丢，7.6 Mbps 送达 | — | 3.6 % 丢，7.7 Mbps |
| 60 fps 合成视频（20 s） | 60 fps 26 / 29 Mbps，0 丢 | 63 fps 16.3 Mbps，码率 22.6 / 实发 20 Mbps，丢 1 帧 | 55 fps 13.7 Mbps，5 次冻结共 1.6 s，丢 5 帧 | 60 fps 7.3 Mbps，4 次冻结共 1.25 s |
| 输入确认 | 114 / 114，p50 5 ms / 200 / 200，p50 3.2 ms | 214 / 215，p50 / p90 106 / 114 ms | 200 / 200，p50 / p90 106 / 109 ms | 215 / 216，101 / 106 ms |

- 码率跟着媒体层的目标走（经 netem 22–23 Mbps 目标、实发 20–22 Mbps，30 Mbps 的瓶颈），ping 和输入在 RTT 上：SCTP 不再是卡住的那一环。
- 慢的两项：`welcome`（ICE + DTLS 1.2 的两个往返 + SCTP 的四次握手 + hello，约 5.5 个 RTT；QUIC 是 2 个）和可靠的大下载（一条流在 SCTP 里
  最多 192 KiB，丢包要等重传，经 netem 6–13 Mbps）。probe 的 RPC echo 是 2 个 RTT：str0m 开通道要等 DCEP 的 ACK 才发数据；浏览器
  （Chrome）不等，是 1 个 RTT。
- 修 SCTP 之前（同样的 netem `5g`，Chrome，B 的 e2e）：8 MiB 下载 0.7 Mbps，视频 4 fps / 0.2 Mbps、4 次冻结 4.6 s，ping p50 287 ms / p99 3.2 s、
  17.6 % 丢，输入 19 / 200 失败。

### 拿浏览器试真的服务端

```sh
cd link && cargo build --release -p uu-link-probe -p uu-link-netem
target/release/uu-link-probe serve-rtc --port 47960 --bind 127.0.0.1      # 打印 fingerprint、token、signal URL
#   signal http://127.0.0.1:47830/rtc        POST offer JSON → answer JSON（CORS 全开，只听 127.0.0.1）；GET /info
#   页面：dialRtc({ signal: (o) => fetch(url, {method:"POST", body:o}).then(r => r.text()), pinnedFingerprint: <fingerprint>,
#          credential: "Bearer probe", … })；probe 的 RPC /echo、/bytes?n=，控制 ping → pong，数据报通道 14 回显、15 计数，
#          video.open → 60 fps 合成视频
# 经 5G 损伤：服务端只给 netem 的地址
target/release/uu-link-probe serve-rtc --port 47960 --bind 127.0.0.1 --advertise '[::1]:47972' --advertise-only &
target/release/uu-link-netem --listen '[::1]:47972' --to 127.0.0.1:47961 --profile 5g &
target/release/uu-link-probe dial-rtc http://127.0.0.1:47830/rtc <fingerprint> --bind ::1 --seconds 20 [--video]
```

`--screen-clip <文件>` 让探针当一个最小的屏幕，给真的页面用（`@yoyocontrol/screen-ui` 的 e2e、它的 demo 的 `?link=`）：
`video.open` 回 `video.opened`（带 `id`），按 30 fps 循环放文件里的 H.264 AU（客户端要关键帧就从头的关键帧再来），`video.close`
停，`control.take` / `control.release` 都给。文件格式在 `tools/probe/src/main.rs` 的开头（`UUCLIP01`、宽高、每个 AU 一个
类型字节 + 长度 + Annex-B）；e2e 用浏览器自己的编码器现做一个。`welcome.principal` 是 `{device, client}`（`client` = 它看到的
客户端钥匙，测试拿来核对证书有没有存住）。

`RUST_LOG=str0m=debug,sctp_proto=debug` 打开库自己的日志（probe 的 stderr）。

## 服务端：Mac（`YoyoServer`）

`mac/Sources/YoyoServer/Link*.swift`（`#if canImport(YoyoLink)`：根 `Package.swift` 没有 `YoyoLink` 时服务照旧、没有 Link）。

- **谁来跑**：默认模式就是远程访问（`RemoteAccess`）：开着、有配对的设备或正在显示配对码时运行（同一个开关、同一个设备库、同一套控制权），
  UDP 端口默认 47820（`LinkOptions.port`）。Link 钥匙在 `<home>/link-key`。`/status` 的 `link` = `{id, key, sig, port, relays,
  direct}`（只在监听时有），`/status.features.link`；`GET /remote` 也有 `link`；信令服务的控制连接发 `{"type":"link", id, key, sig,
  relays, direct}`（`RELAY.md`「Link 绑定」）。
- **公网**：路由器给 Link 的 UDP 端口做映射（远程访问的 `PortMapper`：PCP → NAT-PMP → UPnP、租约一半时续、外网端口先要同号，
  占了就要路由器给的；跟着「允许从外网直连」开关和 `YOYO_PORTMAP=off`），日志 `link: port mapping upnp <公网>:<端口> → <本机>:<端口>`；
  映射到的地址经 `add_external_addr` 进 `direct`（`/status`、中继的 `link`），换了、没了随即更新；网络变化 2 s 后重新映射。
  停下（关开关、监听停、服务退出：最多等 2 s）删掉映射。`GET /remote` 的 `link.mapping` = `{status, address?, port?, method?}`。
- **认证**：`credential` = `Bearer <令牌>`；令牌第一次经 Link 进来时绑定客户端钥匙（存在 `devices.json` 这台设备的 `linkKey`），
  之后别的钥匙 → `unauthorized`（日志一行），重新配对后解开。`welcome.principal` = `{device: {id, name}}`（配对时的设备）。
  `Pair <配对码>`：在 Link 上配对（「配对」），日志 `link: paired <名字> (from <来源>)`。
  守卫用核心的（同远程访问的数字：60 s 内 10 次失败冷却 5 min，32 个会话，4 个没认证的）。
- **RPC**：经远程访问的白名单进现有路由（`Router.handle`，认证结果就是会话的设备），流式回答照样流式。
- **视频**：`video.open` 的 `query` 按 `/stream` 解析（同一套参数、同样的 400 / 503），跑同一个视频循环（`VideoStreamLoop`：
  有变化才编、refine、keepalive、指针合并），只是出口换成 Link 的 sink：`can_send_frame` 代替确认窗口，媒体层的
  `TargetBitrate.encoder_bps` 代替码率台阶；refine 照样临时加码率，但加到的码率不超过目标 × `fps` × `refineEvery`
  （每 100 ms 一次的 refine 加起来不超过目标码率；`StreamTuning.refineBitrate`），队列关着时照样不编。
- **恢复帧**：VideoToolbox 开 `EnableLTR`。输出带 token 的帧记下来；`FrameDelivered` 到来时，最新送达帧的参考链上（中间没有关键帧、
  恢复帧的基准不在它之前）最新的那个长期参考算确认，之后每次编码都带它（`AcknowledgedLTRTokens`）。`RecoveryNeeded` → 下一帧
  `ForceLTRRefresh`，作为 kind 4、`recovery base` = 那个确认帧发出（P 帧，马上发，不受关键帧间隔限制）；没有确认的长期参考，
  或 VideoToolbox 还是给了 IDR，就是关键帧（最多 500 ms 一个）。监听开着 `recovery_on_nack`（每次 NACK 也要一个恢复帧）。
  一帧没发出去（`send_frame` 出错）也走恢复，免得下一帧引用手机没有的帧。
- **声音**：`audio.open` 订阅现有的声音采集，每个 Opus 包 → `send_audio`。
- **输入**：媒体层的 `Input` 事件按顺序进 `POST /input` 的处理（控制权、`PointerMoveGate`、显示器坐标），被拒 → `input.rejected`。
- **控制权**：`control.take` / `control.release` = 现在的 `POST /control`（`RemoteControl`），每次变化给所有会话发 `control`。
- **主人模式**（`LinkOptions.authority`，嵌入方用）：谁能进、谁能控制由本机的一个程序决定（`LOCAL-API.md`「Link 的主人」）；
  不需要远程访问，钥匙和身份放在 `LinkOptions.keyDirectory`。
- **日志**：核心的 `link session opened/closed`、`link path`、每 10 s 的 `link[server]:` / `link[phone]:`（这一段的数）都进服务的
  日志；视频流每 10 s 的 stats 行多 `missed held … busy …, held … ms; size p50/90/max … KB`（没编的画面按原因、Link 队列挡着的
  时间、画面大小）和末尾的 `link target … Mbps keys … recoveries …`、手机 `report` 的摘要，手机网络评级变化时
  `link <设备> phone net: …`。逐帧的在「逐帧跟踪」。
- **浏览器**（「WebRTC」）：同一个监听开着 rtc 套接字（`LinkOptions.rtc`，默认开；`rtcPort` 默认 Link 端口 + 1；`stunServers`），
  端口映射同 Link 端口（日志前缀 `link rtc`），`/status.link.rtc = {port, direct?}`；offer 经 `POST /link/rtc`（unix socket）和信令服务的
  `rtc` 消息进来（`LinkRtcSignaling`），answer 用远程访问的身份签。会话和手机的走同一套（设备令牌绑定浏览器证书的 `dtls-sha256:…`）。
- **选项**（`ServiceHost.Options.link` / `ScreenService(link:)`，`LinkOptions`）：`port`、`relays`（默认空 = 只直连：库里不带任何中继；
  `--remote` 的默认选项取 `YOYO_LINK_RELAYS`，逗号分隔的列表或 `off`；Yoyo Control 这个产品的可执行文件把 relay1 放进这个环境变量）、`keyDirectory`、
  `authority`、`portMapping`（默认开，`YOYO_PORTMAP=off` 关）、`bindAddresses`、`traceDirectory`（「逐帧跟踪」，默认没有；
  `--remote` 的默认选项取 `YOYO_LINK_TRACE`）。`--no-link` 关掉（远程访问也就没了）。

## 服务端：Linux（`linux/link.mjs`）

`linux/README.md`「uu Link」。用 `@yoyocontrol/link`（JS 在 `linux/vendor/link`，原生插件在发布包里）；跟着远程访问（`--remote`）起停，
UDP `--link-port`（缺省 47820），钥匙 `<home>/link-key`，认证、绑定客户端钥匙、`/status.link`、中继的 `link`、RPC 走远程路由表、
控制消息、输入的拒绝代码都同 Mac。差别：

- 只有 h264（x264）。恢复帧不靠长期参考，靠 x264 的 reference invalidation：辅助程序留着前面最多 16 幅画面，`recoveryNeeded` 来了就忘掉手机确认过的那幅
  之后的所有画面，下一幅只引用那一幅，作为 `recovery` 帧发（`recovery_base` = 那一幅）；所以也开 `recovery_on_nack`。确认的那幅已经不在留着的里面、
  或者手机还什么都没确认，才回关键帧；`keyframeNeeded` / `keyframe` 照旧回关键帧（上一个还在路上时不发下一个）。一幅画面不超过它那一份码率的几倍
  （VBV 缓冲 = 8 幅的份）。细节在 `linux/README.md`「uu Link」。Windows 的辅助程序还是老规矩（恢复 = 关键帧，不开 `recovery_on_nack`）。
- 公网：端口映射用 `@yoyocontrol/portmap`（UDP，选项同 TCP 那一份），映射到的地址和 `--advertise` 的地址都经 `add_external_addr` 进
  `direct`（容器里本机网卡的地址手机连不上）。
- 还没有逐帧跟踪（`traceDirectory`）；视频每 10 s 一行 `link <设备>: video <id> stats: …`。
- `/status.link` 另有 `fingerprint`（签绑定的身份钥匙的指纹，Mac 版不发）。
- 中继：`--link-relay <url,…|off>`（`YOYO_LINK_RELAYS` 同），缺省没有（只直连：服务端不带任何中继）；直接 `new LinkServer`
  的（测试、嵌入）不给 `relays` 也没有。发行方可以在发布包里放 `defaults.env`（`server.mjs` 旁，`KEY=value`，真实环境优先）：
  开源的发布包没有这个文件。信令服务同理：`--signal <url>`（`YOYO_SIGNAL_URL`），缺省没有。
- 浏览器：`--link-rtc-port`（缺省 Link 端口 + 1，`off`）、`--link-stun`，`POST /link/rtc` 在令牌监听上；还没有经中继的 offer，也还没有
  经 Link 的配对（`Pair <配对码>` → `unauthorized`；浏览器用令牌模式的凭据）。
- **主人模式**（不开 `--remote`：`--link on --link-home <目录>`）：同 Mac 的主人模式（`LOCAL-API.md`「Link 的主人」），接口在令牌监听上；
  钥匙和身份在 `--link-home`，地址只有本机网卡的和 `--advertise` 的（不做端口映射），RPC 只有 `GET /status`（`linux/README.md`「主人模式」）。

## 客户端：iOS（YoyoKit）

`YoyoLinkClient`（根 `Package.swift` 有 YoyoLink 时才有的 product）是手机这一端，kit 其余部分不依赖 Rust：

- `YoyoLinkClient.shared`：每个进程一个客户端端点（随机端口、不映射；中继 `YoyoLinkClient.relays`，默认没有（kit 不带任何中继），宿主在第一次
  `endpoint()` 前设自己的，`YOYO_LINK_RELAYS` 给测试用——端点不用中继就拨不了绑定里的中继，也打不了洞）；钥匙每次安装一把，存钥匙串
  （本机、不同步，`<namespace>LinkClientKey`；钥匙串用不了时只给这个进程一把）；每次 `NWPathMonitor` 更新都调
  `network_changed(iface)`。`dial(binding, fingerprint:, hints:, credential:)` 先用核心的 `verify_binding` 核对钉住的指纹
  （对不上：`Failure.binding`，记一行，不拨），`direct` = 绑定的地址 + `hints`（配对链接里的地址，用绑定的端口）。
  `isEnabled`（`<namespace>Link`，默认开）是 kit 的开关。核心的日志行进系统日志（`ca.sarria.yoyocontrol` / `link`）和
  `logHandler`：本机的 `link:` 统计行写成 `link[phone]:`（同服务端记手机那行），另有 `connected in … ms`、`denied`、
  `dial failed`、`binding refused`。
- `YoyoLinkConnection`：一个会话。自己读控制消息和媒体事件，按流 id 分给各路；实现 YoyoCore 的 `YoyoScreenLink`
  （画面、声音、指针、输入、`report`）；`control(take:)`；`data(for: URLRequest)` / `lines(for:)` 把一个 HTTP 请求
  原样走 RPC（方法、路径 + 查询、小写的头、正文），`/events` 是流式的。
  `speedTest(durationMs:)` → `(YoyoLinkSpeedTest, json)`：「测速」（报告按 Link 的 JSON 解码；给一条不显示画面的连接用）。
- YoyoCore `YoyoScreenLink` + `YoyoBackend.screenLink(for:)`（缺省 nil）：路是一个 Link 会话时，屏幕页的流走
  `video.open`（`/stream` 的查询，没有 `ack`），画面直接进解码器和平滑播放（不走 multipart 解析、没有确认），每帧解码结果
  回 `frame_decoded`，解码失败要关键帧，每 2 s 发 `report`；链路的 RTT 代替确认的 RTT 给触摸预算；声音 `audio.open`
  进同一个声音输出；指针位置 + `cursor.shape`；输入不等回答直接 `send_input`（`move` = 1，其余 = 0），`input.rejected`
  走页面现在的错误处理；统计行的路写 `link lan / direct / punched / relay`，第三行是链路自己的 `link:` 数字。
- YoyoConnect：候选种类 `.link`（排在 `lan` 前面）。`ConnectPolicy.offsets[.link] = −250 ms`：它先起跑，别的晚 250 ms，
  250 ms 内连上就不起别的；别的先连上就先用，`linkGrace`（1.5 s）内 Link 连上还是换过去（流跟着搬）；Link 在跑时要开的流
  最多等 `decisionWait`。`YoyoConnector.linkPossible`（宿主设）让它在任何别的路上都去试 Link，之后每 `retryInterval` 30 s 再试；
  `ConnectSource.ended` 说一个链接自己断了：有回落就回落，然后马上再竞速；没有回落时这条路标成「已断」，什么候选都能顶上
  （包括同一个 Link 的新会话）。换网络（Wi-Fi ↔ 5G）不离开 Link，只有断网才离开。
- Yoyo Control 自己的后端（YoyoDirect）只有这一个候选：配对（`YoyoClient.pair`：`Pair <码>`）、连接（`YoyoClient.connect`）都在 Link 上；
  `/status`、剪贴板、焦点、`/events` 走 RPC，控制走 `control.take` / `control.release`，会话断了 YoyoConnector 拨一个新的。记录里没有绑定时
  问一次信令服务的 `/v1/candidates`；记录里的绑定拨不通时也问一次（换了中继、地址）。没有 Pro：会话要在 1.5 s 内落在局域网路径上，
  否则算 `needsPro`（`RemoteAccess`）。

端到端（模拟器里的 kit ↔ Mac 的 `LinkServer`，同一台 Mac）：Mac 的测试 `LinkServeTests` 起真的监听、设备库、控制、视频循环、
LTR 编码器和 Link 出口（假画面：没打包的测试程序没有屏幕录制权限；输入只记下，不发到这台 Mac），把绑定和配对好的令牌写进一个文件；
kit 的 `LinkSmokeTests` 读它，用 Yoyo Control 自己的后端和连接器连过去。经 netem 时客户端只绑 `::1`（`YOYO_LINK_BIND`）：

```sh
cd mac && YOYO_LINK_SERVE=$TMPDIR/serve.json YOYO_LINK_TEST_SERVER=127.0.0.1:47942 YOYO_LINK_SERVE_SECONDS=150 \
  [YOYO_LINK_SERVE_DIRECT='[::1]:47952'] swift test --filter LinkServeTests &
[link/target/release/uu-link-netem --listen '[::1]:47952' --to 127.0.0.1:47942 --profile 5g &]
TEST_RUNNER_YOYO_LINK_SMOKE=$TMPDIR/serve.json TEST_RUNNER_YOYO_LINK_SMOKE_SECONDS=20 [TEST_RUNNER_YOYO_LINK_BIND=::1] \
  xcodebuild test -scheme YoyoKit-Package -destination "id=<模拟器>" -collect-test-diagnostics never \
  -only-testing:YoyoKitTests/LinkSmokeTests
```

2026-11-01，20 s，960 px 的假桌面 30 fps（编码约 24 fps），每 100 ms 一个移动、每 300 ms 一个按键：

| | 直连回环 | 经 netem `5g` |
| --- | --- | --- |
| 连上（`welcome`） | 5 ms | 205 ms |
| 第一个画面（页面出现起） | 179 ms | 486 ms |
| 帧（关键帧 / 恢复帧） | 496（1 / 0） | 507（1 / 4） |
| 解码成功 / 失败 | 496 / 0 | 507 / 0 |
| 输入确认 p50 / p90 | 0.8 / 3.4 ms | 93 / 104 ms（RTT 87/91/93） |
| 冻结、丢帧、跳过 | 0 | 0（NACK 补回 8 / 8） |
| 服务端收到的输入 | 64 键 + 192 移动，没控制权时的点击被拒（409） | 64 键 + 191 移动 |

## 客户端：浏览器（`@yoyocontrol/link-web`）

浏览器开不了 UDP，也不能给 `fetch` 钉自签证书，所以浏览器走 WebRTC（「WebRTC」那一节的映射），会话协议和媒体层同上：

- `dialRtc({ signal, pinnedFingerprint, credential, device, app, iceServers?, certificates?, timeoutMs?, media?, wasm? })`：
  一个 `RTCPeerConnection`，先建好协商的 `control`（id 0）和 `dgram`（id 1，`ordered: false`、`maxRetransmits: 0`），
  等 ICE 收集（最多 1 s）后把 `{v: 1, offer, device}` 交给宿主的 `signal`（中继、本机 `POST /link/rtc`、宿主自己的后端都行），
  拿回的回答先用 WebCrypto 核对（`SHA-256(binding.key)` = 钉住的指纹、`sig` 验签、回答 SDP 的 `a=fingerprint` = `fingerprint`，
  对不上 = `LinkError("verification")`，硬失败），再 `setRemoteDescription`，然后 `hello` → `welcome`。`denied`（以及 `welcome`
  之前带 1 / 2 / 3 的 `bye`）是 `LinkError("denied")` 带 `code`。整个拨号默认 15 s。
- `LinkSession`：`sendControl` / `onControl` / `controlMessages()`；RPC 每次开一条带内的 `rpc` 通道（头帧、正文按 16 KiB 分条、
  空消息 = FIN，没有 FIN 就关 = 重置），`request()` 和 `fetch(path, init)`（给按 HTTP 写的代码，比如一个 `ScreenTransport`）；
  `probe(durationMs, {signal})` → `ProbeReport`（「测速」；`signal` 停止；wasm 没有它时 `LinkError("unsupported")`）；
  `sendDatagram` / `onDatagram`（通道 6–15，超过 1200 字节或 `dgram` 缓冲超过 256 KiB 就丢并计数）；`close(code, reason)` 发
  `bye {code, reason}`；`closed()`。每 2 s 发 `link.stats`（路径和 RTT 取 `getStats()` 里选中的候选对：`currentRoundTripTime`，
  地址私有 = `lan`、服务端的 host 公网地址 = `direct`、srflx / prflx = `punched`；网卡取 `navigator.connection`，Safari 没有就是
  `other`）；20 s 没收到服务端的任何东西、或连接 `failed` 就结束。
- 媒体层：`link/wasm`（`uu-link-media` 的 `ClientMedia` 原样编成 wasm32），`dgram` 上通道 1–5 的数据报交给它，它要发的回到
  `dgram`，事件交给监听者，定时器按它的 `poll_timeout`；每 100 ms 喂一次路径 RTT。`.wasm` 一页加载一次，默认从模块旁边
  （`new URL("./wasm/uu_link_wasm_bg.wasm", import.meta.url)`），宿主可以换（`wasm`）。帧的 AU 从 wasm 内存拷出一次。
  `link/wasm/tests/fec_fixture.rs` 提交了一个原生发送端的关键帧（含 RS 校验片、要丢的两片），`packages/link-web` 的测试把
  同样的字节喂给 wasm：同样的 AU、同样补回 2 片。
- `linkScreen(session)`：`@yoyocontrol/screen-web` 的 `ScreenLink`（iOS `YoyoLinkConnection` 的对应物）：画面、声音、指针、
  输入、`control.take` / `control.release`、`report`（附这一端每帧的结局 `rx` 和 `clock.mediaUs`），`input.rejected` 变成
  状态码形状的错误（`LinkRequestError`，同 `POST /input` 的 409 / 401…）。
- DTLS 证书就是服务端看到的客户端钥匙（`dtls-sha256:<hex>`，设备令牌绑定它）：默认存在 IndexedDB（库 `yoyocontrol-link`、
  对象库 `certificates`、键 `rtc`；`RTCPeerConnection.generateCertificate({name:"ECDSA",namedCurve:"P-256"})`，有效一年，
  离过期不到一天就换一把 = 要重新配对），第一次拨号时生成。宿主可以给自己的 `certificateStore`（`load` / `save`），或直接给
  `certificates`；`certificateStore: null` = 每次连接一把（只适合不绑定客户端钥匙的凭据）。存不了（没有 IndexedDB 又没给）就是
  每次一把；IndexedDB 出错 = `LinkError("unsupported")`。`clientKeyOf(cert)` 算出服务端看到的那个字符串。

端到端（真的 Chrome ↔ `uu-link-probe serve-rtc`）：`npm -w packages/link-web run e2e -- [--seconds 10] [--netem 5g]`
（`packages/link-web/test/e2e/run.mjs`：打包页面、起探针和本机的信令、无头 Chrome 经 CDP 跑 `test/e2e/page.ts`，打印 JSON；
`--netem` 时探针只绑回环、`--advertise <代理> --advertise-only`：回答里只有代理的地址，信令原样转发）。最后再拨一次：
探针把它看到的客户端钥匙放进 `welcome.principal.client`，两次和 IndexedDB 里那张证书的 `clientKeyOf` 要一样。`--page screen` 不要探针：
`screen-web` 的 `VideoStream` / `ScreenAudio` 走页面里的一个 `ScreenLink`，画面和声音由浏览器自己的 WebCodecs 编码器出
（真的 H.264 经 VideoDecoder、每帧的结局、平滑播放、声音缓冲和音画同步；`--codec hevc`：浏览器自己出 HEVC，页面自己要 `hevc,h264`，
走 `hevc.ts` 的 `hvcC`——Chrome 156 上 58 fps、0 失败）。

2026-11-03（rebase 到 rtc 服务端合并之后），M 系列 Mac，Chrome 156 无头，`uu-link-probe serve-rtc`；本机（`lan`）10 s 和经 netem `5g` 20 s：

| | 本机 | netem `5g` |
| --- | --- | --- |
| 到 `welcome` | 152 ms（ICE 收集 131、回答 14、ICE + DTLS + SCTP 5、`hello` → `welcome` 1；第一次另加载 `.wasm` 约 90–120 ms） | 695 ms（收集 137、回答 19、连通 449、hello 91） |
| RPC echo p50 / p90 | 1.0 / 4.6 ms | 104 / 108 ms |
| 8 MiB RPC 下载 | 441 Mbps | 14.1 Mbps |
| 控制消息往返 p50 / p90 | 0.1 / 0.2 ms | 97 / 105 ms |
| 50 Hz 数据报 ping p50 / p90 / p99 | 0.8 / 4.3 / 7.0 ms，0 丢 | 105 / 108 / 122 ms，5.9 % 丢 |
| 合成视频（探针 60 fps） | 617 帧，60 fps，22 Mbps，0 丢 / 跳 / 冻结 | 58 fps，14.7 Mbps，FEC 补回 1314 片、NACK 补回 255，丢 1 帧、跳 15、冻结 1 次 266 ms |
| 输入 | 100 / 100 确认，p50 / p90 3.1 / 5.4 ms | 200 / 200，106 / 108 ms |
| 第二次拨号的客户端钥匙 | 一样（IndexedDB 里的证书） | 一样 |

## API

三种语言是同一个形状。

### Rust（`uu-link`）

- `Endpoint::bind(EndpointConfig)`（`EndpointConfig::server(key, port)` / `::client(key)`；`relays`、`portmapper`、`guard`、
  `initial_target_bps`、`bind_ips`（只绑这些地址；Swift 的 `bindIps`、默认空）、`rtc: Option<RtcConfig { port, stun_servers,
  external_only }>`（「WebRTC」））；`id()`、`port()`、`bound_sockets()`、`addr_info()`、`watch_addr_info()`、`binding(identity_key)`、
  `network_changed(Option<Iface>)`、`add_external_addr(SocketAddr)` / `remove_external_addr`（App 自己做的端口映射）、
  `dial(&DialTarget, &Hello, &DialOptions)`、`listen(ServerOptions) -> Listener`、`close()`；rtc：`rtc_port()`、`rtc_bound_sockets()`、
  `add_rtc_external_addr` / `remove_rtc_external_addr`、`rtc_peer_count()`、`dial_rtc(signal, fingerprint, &Hello, &DialOptions)`。
- `DialTarget { id, relays, direct }`，`DialTarget::from_binding(binding, fp, relays, direct)` 先验签。
- 服务端：`ServerOptions::new(ServerInfo, Arc<dyn Authenticator>)` + `features`、`rpc: Option<Arc<dyn RpcHandler>>`、
  `rpc_blocked_paths`、`max_request_body`、`hello_timeout`、`media`（每个会话的 `ServerMedia` 配置，例如
  `video.recovery_on_nack`：每次 NACK 同时要一个恢复帧，给恢复帧便宜的编码器（VideoToolbox 长期参考帧）；默认关，Swift
  `ServerSettings.recoveryOnNack`、Node `recoveryOnNack`）；`Authenticator::authenticate(AuthRequest { hello, client_key, source })
  -> AuthDecision::{Accept { principal, features }, Deny { code, message }}`；`Listener::accept() -> Option<Session>`；
  `ServerOptions::rtc_identity: Option<Arc<dyn rtc::IdentitySigner>>`（`rtc::IdentityKey`）+ `Listener::accept_rtc_offer(json, source)`。
- `Session`：`id`、`side`、`transport()`（`Transport::Quic` / `Rtc`）、`remote_id`、`hello`、`welcome`、`principal`；`send_control(&Value)` / `recv_control()`；
  `request(&RpcRequest, body) -> RpcResponse { status, headers, body: RpcBody }`（`chunk()`、`read_all(limit)`、`cancel()`）；
  `send_datagram(channel, payload)`、`send_datagram_raw(bytes)`、`recv_datagram(channel)`、`try_recv_datagram`、`max_datagram_size`、
  `datagram_send_buffer_space`；`target_bitrate()`；`path()` / `watch_path()`；`stats()`、`peer_stats()`、`set_media_stats`；
  `close(CloseCode, reason)`、`closed()`、`close_info()`；`connection()`（QUIC 的连接，rtc 上 `None`）；`probe(Duration) -> ProbeReport`
  （客户端：「测速」；丢掉 future = 停止）。会话的最后一个句柄丢掉时自动关闭（代码 0）。
  媒体：见「媒体」（`media::{FrameMeta, Codec, FrameKind, InputKind, ServerEvent, ClientEvent, …}`）。
- `RpcHandler::handle(session, request, body, RpcResponder)`；`RpcResponder`：`head`、`write`、`finish`、`respond`、`stopped()`。
- `binding::{sign_binding, verify_binding, fingerprint, identity_fingerprint, generate_link_key, link_public_key,
  load_or_create_link_key}`；`cc::{MediaCc, MediaCcFactory, TargetBitrate}`；`guard::{Guard, GuardConfig}`；
  `stats::{StatsSnapshot, MediaStats}`；`log::set_log_sink`；`runtime::runtime()`（绑定层共用的 tokio 运行时，2 个线程）；
  `rtc::{RtcOffer, RtcAnswer, sign_answer, verify_answer, sdp_fingerprint, IdentityKey, IdentitySigner}`（信令的类型和核对）；
  `transport::Transport`。

### Swift（`YoyoLink`）

`import YoyoLink`。生成的部分（`Generated/YoyoLink.swift`，别手改）：`bindEndpoint(config:)`、`LinkEndpoint`（`id()`、`port()`、
`addrInfo()`、`watchAddr(observer:)`、`binding(identityKey:)`、`networkChanged(iface:)`、`addExternalAddr(addr:)` /
`removeExternalAddr(addr:)`、`dial(target:hello:connectTimeoutMs:)`、
`listen(settings:authenticator:rpc:)`、`close()`；rtc：`EndpointConfig.rtcPort` / `rtcStunServers` / `rtcExternalOnly`、`rtcPort()`、
`addRtcExternalAddr(addr:)` / `removeRtcExternalAddr(addr:)`、`dialRtc(signaler:fingerprint:hello:connectTimeoutMs:)`（回调协议
`RtcSignaler` + `SignalReply`）、`ServerSettings.identityKey`）、`LinkListener.accept()` / `acceptRtcOffer(offerJson:sourceIp:)`、
`LinkSession`（`transport()` → `Transport`、`sendControl(json:)`、`recvControl()`、
`request(request:body:)`、`sendDatagram(channel:payload:)`、`recvDatagram(channel:)`、`targetBitrate()` / `setTargetBitrate(bps:)`、
`path()`、`stats()`、`peerStats()`、`setMediaStats(stats:)`、`probe(durationMs:)` → `ProbeReport`（「测速」，带 `json`；取消 Task = 停止）、
`close(code:reason:)`、`closed()`）、`RpcResponse`（`status()`、
`headers()`、`chunk()`、`readAll(limit:)`、`cancel()`）、`RpcResponder`（`head`、`write`、`finish`、`respond`、`stopped`）、
`AuthReply`（`accept(principalJson:features:)`、`deny(code:message:)`），媒体（`openVideo(stream:)`、`canSendFrame(stream:)`、
`sendFrame(stream:meta:au:)`、`sendAudio`、`sendCursor`、`requestKeyframe`、`nextServerEvent()` → `ServerMediaEvent`、
`sendInput(kind:json:)`、`frameDecoded(stream:frame:ok:)`、`nextClientEvent()` → `ClientMediaEvent`；`FrameMeta`、`VideoFrame`、
`AudioPacket`、`InputEvent`），回调协议 `Authenticator`、`RpcHandler`、`AddrObserver`、
`LogSink`，函数 `generateLinkKey()`、`linkPublicKey(secretKey:)`、`loadOrCreateLinkKey(path:)`、`identityFingerprint(identityKey:)`、
`signBinding(identityKey:linkPublicKey:)`、`verifyBinding(binding:fingerprint:)`、`setLogSink(sink:)`、`defaultGuardSettings()`，
错误 `LinkError`（`.Denied(code:message:)` 等）。

`LinkSupport.swift` 加的：`LinkChannel`、`LinkCloseCode`、`LinkControlMessage`（`type`、`json`、`decode(_:)`）、
`session.send(control:)`（Encodable）/ `send(controlObject:)`、`session.controlMessages`、
`session.send(_:onChannel:)` / `datagrams(onChannel:)`（App 的通道 6–15）、`session.serverEvents` / `clientEvents`、
`session.principal`、`listener.sessions`、`endpoint.addressUpdates`、
`endpoint.listen(_:authenticate:rpc:)`（闭包版，`LinkAuthDecision`）、`response.body`（AsyncThrowingStream）、`LinkLog.setHandler`。

回调在 Rust 的线程上同步调用；要花时间的回答走回答对象（`AuthReply`、`RpcResponder`），闭包版替你开 `Task`。异步调用都在
Rust 的运行时上跑，里面的 panic 变成 `LinkError.Internal`（发布版 `panic = abort`）。

### Node（`@yoyocontrol/link`）

`bindEndpoint({ role, secretKey, port?, relays?, portmapper?, guard?, rtcPort?, rtcStunServers?, rtcExternalOnly?, bindIps? })` → `Endpoint`
（`id`、`port`、`rtcPort`、`addRtcExternalAddr` / `removeRtcExternalAddr`、`dialRtc(signal, fingerprint, hello)`、`addrInfo()`、`watchAddr(cb)`、
`binding(identityKey)`、`networkChanged(iface?)`、`dial(target, hello, { connectTimeoutMs })`、
`listen({ server, features, authenticate, rpc, rpcBlockedPaths, maxRequestBody, identityKey })`、`close()`）；`Listener`（`accept()`，可
`for await`；`acceptRtcOffer(json, ip?)`）；`Session.transport`（`"quic"` / `"rtc"`）；
`Session`（`sendControl` / `recvControl` / `controlMessages()`、`request(req, body?)`、`sendDatagram` / `sendDatagramRaw` /
`recvDatagram` / `datagrams(channel)`、`targetBitrate`、`path()`、`stats()`、`peerStats()`、`setMediaStats`、`close(code, reason)`、
`closed()`；媒体 `openVideo`、`canSendFrame`、`frameRateCap(stream)`（旧的原生插件没有：null）、`sendFrame(stream, { codec, kind, width, height }, au)`、`sendAudio`、`sendCursor`、
`requestKeyframe`、`nextServerEvent()` / `serverEvents()`、`sendInput("discrete" | "move", event)`、`frameDecoded`、
`nextClientEvent()` / `clientEvents()`，事件是带 `type` 的对象）；`RpcResponse`（`status`、`headers`、`chunk()`、`readAll()`、`text()`、`json()`、`for await`、`cancel()`）；
`RpcResponder`（`head`、`write`、`finish`、`respond`、`json`、`stopped`）；`generateLinkKey`、`linkPublicKey`、`loadOrCreateLinkKey`、
`identityFingerprint`、`signBinding`、`verifyBinding`、`setLogSink`；`Channel`、`CloseCode`；错误都是 `LinkError`（`kind`，拒绝时
`code`）。`authenticate(request)` 返回（或 resolve 成）`{ ok: true, principal, features? }` / `{ ok: false, code, message? }`；
`rpc(session, request, body, response)` 抛错时回 500。

## 构建

- Rust：`cd link && cargo test`（沙盒外，第一次要下载 crate）。iOS 静态库：
  `cargo build --release --target aarch64-apple-ios -p uu-link-ffi`。
- Swift：`scripts/link-apple.sh build` 编三个切片（ios-arm64、ios-arm64-simulator、macos-arm64），去掉调试信息（约 80 MB → 17 MB
  一个切片），打成 `link/target/apple/YoyoLinkFFI.xcframework`（不提交），并把生成的 Swift 写进 `Generated/`（提交）。
  根 `Package.swift` 看到本地的 xcframework 就有 `YoyoLink` 这个 product：`swift build --product YoyoLink`。没有本地构建时用
  发布的二进制：公开仓库 `yoyocontrol/yoyo-control` 的 release `link-apple-vX.Y.Z` 里那个 zip（`linkRelease`：URL + SwiftPM
  校验和，`.binaryTarget(url:checksum:)`，谁都能下，不用任何账号）；设成 nil 时包里就没有 `YoyoLink`，别的 product 不受影响。
  换了 `link/` 的代码要发新版本再改 `linkRelease`：发布的二进制和提交的 Swift 绑定要出自同一份代码。
  `scripts/link-apple.sh check` 核对提交的绑定和代码一致；`scripts/link-apple.sh release <x.y.z>` 构建、核对、打 zip 并给出
  校验和（上传为 release 的附件，再把 URL 和校验和写进 `linkRelease`）。
- 链接需要的系统库（根 `Package.swift` 已写）：Network、SystemConfiguration、Security、CoreFoundation、iconv、objc。
- Node：`npm -w packages/link run native` 编本机的 `.node`（`release-node` profile：`panic = unwind`）放进
  `packages/link/native/uu-link.<platform>-<arch>[-gnu].node`；加载顺序 `$YOYO_LINK_NATIVE` → `native/` → JS 旁边（`dist/` 的拷贝，Linux 的 `vendor/link`）→ 仓库里的
  `link/target/{release-node,debug}`。`npm -w packages/link test`。
- 浏览器：`npm -w packages/link-web run wasm` 编 `uu-link-wasm`（`wasm32-unknown-unknown`，`release-wasm` profile：保留 wasm-bindgen
  要读的 `target_features`），用 Cargo.lock 里同版本的 wasm-bindgen-cli（没有就装一次到 `link/target/tools`）生成胶水：
  `packages/link-web/src/wasm/uu_link_wasm.js` / `.d.ts` 提交，`.wasm`（约 250 KB，gzip 约 90 KB）不提交，`npm run build` 把它放进
  `dist/wasm/`，`git-dist.sh link-web` 发布时随 dist 提交。`npm run wasm:check` 核对提交的胶水和代码一致。
- Linux 的 `.node`：`linux/release.Dockerfile` 的 `link-addon` 阶段，在构建机上用 `rust:1.96-slim-bookworm` 交叉编译到目标架构
  （gcc 的交叉链接器，glibc 同 Debian 12），产物放进发布包的 `vendor/link/uu-link.linux-<x64|arm64>-gnu.node`（`linux/README.md`「发布」）。
  也可在 Mac 上 `cargo zigbuild --target x86_64-unknown-linux-gnu.2.36`（glibc 2.36 = Debian 12）。
- Windows 的 `.node`：`windows/build.sh` 在 Mac 上按 `x86_64-pc-windows-gnu`（mingw-w64）编，放成 `vendor/link/uu-link.win32-x64.node`；N-API 的
  符号经一个指向 `node.exe` 的导入库链接（`windows/README.md`「发布」）。

## 测试工具

- `uu-link-netem --listen <ip:port> --to <ip:port> --profile lan|5g|bad|handover`：两个方向各自损伤。

  | 配置 | 内容 |
  | --- | --- |
  | `lan` | 单程 2 ms |
  | `5g` | 单程 35 ms + 0–15 ms 抖动（不乱序），1 % 随机丢包，0.2 % 的包开始一串 5–20 个的连续丢包，30 Mbps 瓶颈、队列 60 ms |
  | `bad` | 60 ms + 0–40 ms，5 % 丢包，0.5 % 开始 30 个的连续丢包，10 Mbps、队列 100 ms |
  | `handover` | 35 ms + 0–5 ms，从第 10 s 起每 10 s 断 300 ms，之后 3 s 多 20 ms |

  单项可以在 `--profile` 后覆盖（`--delay`、`--jitter`、`--loss`、`--burst`、`--reorder`、`--rate`、`--queue`、`--handover-every`…）。
- `uu-link-probe serve [--port] [--key] [--token] [--bind <ip>] [--rtc …]` / `uu-link-probe dial <id> <ip:port> [--seconds 10]
  [--load-mbps 8] [--bind <ip>]`（WebRTC：`serve-rtc` / `dial-rtc <signal url> <fingerprint>`，「WebRTC」「拿浏览器试真的服务端」）：握手时间、RPC 往返和 8 MiB 下载、控制消息往返，然后同时跑 50 Hz 的数据报 ping
  （通道 14）和合成的数据报负载（通道 15），打印 `link:` 行和汇总。服务端默认不碰路由器（`--portmap` 才映射）。
- `uu-link-probe watch <id> <ip:port> [--credential <text>] [--query <流的查询>] [--seconds 30] [--csv <file>] [--h264 <file>] [--bind <ip>]`：
  一台没有屏幕的手机，接真的屏幕服务端（Mac 的、yoyo-linux）：按 `--credential` 开会话、`video.open`，每帧回「解码了」，每 5 s 一行 `link:`，最后汇总——各类帧数、
  fps、变了的画面从截屏到到达的时间（服务端的墙钟对本机的，同一台机器上才准；`over best` 以最快的一帧当两边时钟的差）、最长的几段空白、丢了 / 跳过多少。
  `--csv` 一帧一行，`--h264` 把交给解码器的访问单元原样写成一个 Annex-B 文件（解码器放得出来的话，画面坏就是流坏）。
  yoyo-linux 在一台 Mac 上整条跑：`YOYO_VIDEO_HELPER=<linux/test/synthvideo> YOYO_LINK_NATIVE=<.node> node linux/server.mjs --host 127.0.0.1 --port 7390
  --link on --link-home <dir> --link-bind 127.0.0.1 --link-rtc-port off`（令牌经 stdin；另起一个程序握着 `GET /link/authority`、对每个 `auth` 回 `ok`），
  netem 在 `[::1]` 上收，`watch … --bind ::1`。
- 同一台机器上不用容器也行：让客户端只能经 netem 到服务端——服务端只绑 IPv4 回环，netem 在 IPv6 回环上收，客户端只绑 `::1`
  （它拿到服务端的 `127.0.0.1` 也发不过去）。Mac 服务端的 Link 测试这样跑：

  ```sh
  link/target/release/uu-link-netem --listen '[::1]:47952' --to 127.0.0.1:47951 --profile 5g &
  cd mac && YOYO_LINK_TEST_SERVER=127.0.0.1:47951 YOYO_LINK_TEST_CLIENT_BIND=::1 YOYO_LINK_TEST_DIAL='[::1]:47952' \
    YOYO_LINK_TEST_SECONDS=20 swift test --filter LinkSessionTests
  ```

  经 netem `5g` 偶尔要 1.2 s 才到 `welcome`（通常约 190 ms）：握手的一个包被丢了，而握手时还没有 RTT 样本，QUIC 按初始 RTT
  333 ms 等一个 PTO（约 1 s）才重发。netem 的随机数有固定种子，所以同样的测试每次丢的都是同一个包、每次都慢；
  probe 连拨 8 次大约 1 次慢。真实 5G 上一样会有，要改就把 QUIC 的初始 RTT 调低（两端）。
  （两边都绑 IPv4 时不行：macOS 上绑在 `127.0.0.1` 的套接字也发得到本机的局域网地址，反过来也一样，iroh 就换到直连的路径上。）
- 同一台机器上 netem 会被绕过：服务端把自己所有的地址告诉客户端，iroh 找到直连的路径就换过去（RTT 更低）。所以服务端放进
  容器，只经发布的端口可达：

  ```sh
  docker run --rm -v "$PWD/link:/src" -w /src -e CARGO_TARGET_DIR=/src/target/linux rust:1.96-slim-bookworm \
    cargo build --locked --release -p uu-link-probe
  docker run -d --rm --name link-probe -p 127.0.0.1:47921:47911/udp -v "$PWD/link/target/linux/release:/probe:ro" \
    rust:1.96-slim-bookworm /probe/uu-link-probe serve --port 47911
  link/target/release/uu-link-netem --listen 127.0.0.1:47922 --to 127.0.0.1:47921 --profile 5g &
  link/target/release/uu-link-probe dial <id> 127.0.0.1:47922 --bind 127.0.0.1 --seconds 20
  ```

  2026-11-01 在 M 系列 Mac 上（release）：

  | | 本机回环 | 经 netem `5g` |
  | --- | --- | --- |
  | 到 `welcome` | 1.8 ms | 197 ms |
  | RPC echo p50 / p90 | 0.14 / 0.16 ms | 94 / 101 ms |
  | 8 MiB RPC 下载 | 833 Mbps | 22 Mbps（30 Mbps 瓶颈） |
  | 控制消息往返 p50 / p90 | 0.08 / 0.10 ms | 94 / 101 ms |
  | 50 Hz 数据报 ping p50 / p90 / p99 | 0.21 / 0.63 / 5.9 ms，0 丢 | 96 / 101 / 110 ms，5.3 % 丢（两个方向） |
  | 8 Mbps 数据报负载 | 0 % 丢 | 3.6 % 丢（= 单向的随机 + 连续丢包），7.7 Mbps 送达 |

  `--video`：服务端按 `encoder_bps` 发 60 fps 的合成帧，客户端解码确认，同时 10 Hz 发离散输入。经 netem `5g` 20 s：
  1208 帧送达（60 fps，7.3 Mbps），FEC 补回 188 片、NACK 补回 230 / 发出 328，丢 5 帧、跳过 72 帧、4 次冻结（共 1.25 s），
  码率控制 13 → 17.7 Mbps；输入 216 发出 215 确认，确认往返 p50 101 ms / p90 106 ms（RTT ≈ 95 ms）。

## 还没做

- WebRTC：Linux 还不接信令服务的 `rtc`（只有令牌监听的 `POST /link/rtc`）；`welcome` 比 QUIC 多 3 个多 RTT；可靠的大下载 6–13 Mbps（QUIC 22）。
- 中继只有一台（relay1，美西）：单点，欧洲、亚洲的用户绕远；多了用户再加地区（iroh 按 RTT 选）。iroh 的中继走 TCP（WebSocket）：
  经它的会话丢包时有队头阻塞，靠尽快打洞换成直连。
- 客户端：Link 上的剪贴板文件按整块读，没有进度。
