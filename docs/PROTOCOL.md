# Yoyo Control 线上协议

`mac/README.md`「HTTP API」那张表列出了每个接口和参数；本文写表后面的线上语义：流怎么分段、确认和流控怎么走、
播放报告与网络质量、声音的时间戳、连接状态、输入的几条规则、剪贴板的数据模型。适用于任何客户端：Yoyo Control 的
iOS App（`ios/YoyoKit`，经远程访问直连），或者同一台 Mac 上经 unix socket 连上来的程序；Linux 上的无头服务端（`linux/`）说同一套协议，
它的差别与为此加的可选字段见「Linux 服务端」。本机怎么找到并接上服务见
`docs/LOCAL-API.md`，手机的配对、远程访问与控制权见 `docs/REMOTE.md`。下面的 TypeScript 形状只是记法，线上都是 JSON。

## 屏幕

截屏、声音与输入都在签名的 `Yoyo Control.app` 里（`yoyo-control`）：macOS 的「屏幕录制」「辅助功能」「录制系统声音」
权限（TCC）按 App 授予。服务说 HTTP/1.1：本机在 unix socket 上，配对的手机经 uu Link 的 RPC（`docs/REMOTE.md`）；两条路上是同一套
路由、同一份实现。

屏幕是**控制台上的那个**：服务所在的 macOS 账号登录在 Mac 上的图形会话，用 ScreenCaptureKit 截它的实体显示器、用
CGEvent（HID 事件流）输入。没有图形登录会话时 `GET /status` 照常 200，但 `ok: false`、`session.loggedIn: false` 并带
`error`；会话里没有显示器同样 `ok: false`。画面（`/frame`、`/stream`）都来自 ScreenCaptureKit：取流时先等第一个完整帧
（至多 1.5 s，从开始截屏算起），来了就回响应头；没来就照样开始（迟到的帧照常发出）；截屏还没出帧就停了是 503。
控制台锁屏时画面就是锁屏（`console.locked`，见「连接状态」）。

**显示器**：`/status` 的 `displays` 里每个显示器都以点（`width` / `height`）加 `scale`（每点像素）报告，客户端要显示像素
就是点 × `scale`。`name` 是 macOS 给显示器起的名字（`NSScreen.localizedName`，主线程读、缓存，不做 I/O），没有或没意义时
缺省（例如只有 ` (AirPlay)` 这样空的产品名加传输方式）。

```ts
interface ScreenDisplay {
  id: number;                  // CGDirectDisplayID；/frame、/stream、/input 的 display
  width: number; height: number; // 点（逻辑尺寸）
  scale: number;               // 每点像素
  main: boolean;
  asleep: boolean;
  kind: "builtin" | "external"; // 开放集合，未知值按缺省；嵌入方自己的显示器（LOCAL-API.md「外部显示器」）是它给的词
  name?: string;               // 按 Mac 的语言：「内建视网膜显示器」「LG UltraFine」…
}
```

`display` 缺省 = 主显示器；截屏会先唤醒睡眠中的显示器，流开着期间显示器保持唤醒。

### 媒体类型

`GET /stream` 与 `GET /audio` 的回答是同一种分段格式：每个分段是
`--<boundary>\r\nContent-Type: …\r\nContent-Length: N\r\n<分段头>\r\n\r\n<N 字节>\r\n`。**不是**
`multipart/x-mixed-replace`（URLSession 会自己拆那种，把分段头当响应头给出、丢掉我们要的东西）；每个分段都有
`Content-Length`，边界只起分隔作用。名字（`StreamWire.swift`）：

| 用途 | 名字 |
| --- | --- |
| `/stream` 回答 | `application/vnd.yoyo-control.stream; boundary=frame` |
| `/audio` 回答 | `application/vnd.yoyo-control.audio; boundary=frame` |
| 指针分段 | `application/vnd.yoyo-control.cursor+json` |
| 状态分段 | `application/vnd.yoyo-control.status+json` |
| 视频 / 声音分段 | `video/h264`、`video/hevc` / `audio/opus` |

客户端从回答的 `Content-Type` 读 `boundary`。请求的 `Accept` 写 `application/vnd.yoyo-control.stream`（`/stream`）或
`application/vnd.yoyo-control.audio`（`/audio`）仍然可以，服务端不再看它。2026-11-01 起删掉了发布前的旧名字（另一套
`application/x-*` 媒体类型与它们的边界、`/clipboard/file` 的旧文件名头、环境变量的旧名）；`api` 仍为 1。

### 视频流、确认与客户端指针

`GET /stream` 只出视频（一个视频流循环，`VideoStreamLoop.swift`；画面来自 ScreenCaptureKit 的实体显示器）。参数全在
query 里、全部可选：

```ts
interface ScreenStreamRequest {
  display?: number;
  maxWidth?: number;    // 160…3840；客户端报到 3840 即可（实际宽度见下「视频最宽」）
  fps?: number;         // 缺省 2，夹到 1…60；只在画面变了时编码，上限高不费什么
  codecs?: string;      // 逗号分隔，客户端偏好顺序，取自 hevc,h264；别的 token 丢弃；缺省 / 空 = h264
  stream?: string;      // 客户端起的流 id，8–64 个 [A-Za-z0-9_-]；要确认就得带。同 id 的新流顶替旧的
  ack?: 1;              // 客户端会 POST /stream/ack
  cursor?: "client";    // 客户端自己画指针：画面里不画指针，改发指针分段
  status?: 1;           // 状态分段（见「连接状态」）
  maxKbps?: number;     // 整数 100…100000，只供测试（手动取流时用，客户端不带）：天花板 = min(服务端天花板, maxKbps)，起步同样不超过它
}
interface ScreenStreamAck { stream: string; seq: number; keyframe?: boolean; report?: ScreenPlayoutReport }
interface ScreenStreamAckResponse { ok: true; net: ScreenNetQuality }   // 见「网络质量」
interface ScreenCursorPart {      // 指针分段的 JSON body
  x: number; y: number; visible: boolean; shapeId: number;
  shape?: { id: number; png: string /* base64 PNG */; hotX: number; hotY: number; width: number; height: number };
}
```

`stream` / `ack` / `cursor` / `status` / `maxKbps` 不合法 400。**编码按客户端的顺序取**：从 `codecs` 第一个起，取第一个
服务端允许（`YOYO_VIDEO_CODECS` 白名单，缺省 h264、hevc 都允许；它的顺序没有意义）、且本机真能编的（进程内探测一次：只用
硬件编码器 + 低延迟码率控制的 VTCompressionSession（Apple silicon），建不出这样的会话就算不能编，没有退路）；列表走完还没有
就取 h264、再 hevc；两种都编不了 503（`this Mac can't encode h264 or hevc video (VideoToolbox)`），在做任何别的事之前回。
iOS 客户端在能硬解 HEVC 的机型上发 `hevc,h264`，否则 `h264`。

**响应**：`Content-Type` 见「媒体类型」，另有 `Cache-Control: no-store`、`X-Display`（截的显示器）、`X-Stream-Codec: h264|hevc`、
`X-Stream-Id`（回显，若给了）。流头的 `X-Stream-Codec` 不是 h264 / hevc 时客户端当作流失败；流头没带它（URLSession 自己拆流、
第一个响应已经是第一个分段，例如状态分段）时以视频分段的类型为准。URLSession 可能把每个分段拆成一次
`didReceive(response)` 并把分段头当响应头给出，所以客户端需要的东西都在**分段头**里，不只在外层头里。客户端断开即停止截屏。

分段按 `Content-Type` 分（`status=1` 时还有状态分段；客户端不认识的类型只记它的 `X-Frame-Seq`、丢掉内容）：

1. `video/h264` / `video/hevc`：恰好**一个** access unit（一幅画面），Annex-B（4 字节起始码 `00 00 00 01`）。每个 `key` 分段
   以参数集开头（h264：SPS、PPS；hevc：VPS、SPS、PPS），后接 IDR。没有 B 帧、不重排：解码顺序 = 显示顺序，解出来就显示。
   编码器用低延迟码率控制，只在流开始、客户端请求、尺寸变化时出关键帧（外加 60 s 的保底）。
2. 指针分段（`cursor=client`）：JSON（`ScreenCursorPart`），很小，不计入确认窗口。

分段头：`Content-Type`、`Content-Length`（总有）；`X-Frame-Width` / `X-Frame-Height`（只在画面分段上：画面覆盖整个显示器，
客户端据此换算触点；尺寸只会在 `key` 分段上变）；`X-Frame-Seq`（每条流单调递增，**每个**分段都占号，画面、指针、状态分段
都算）；`X-Frame-Time`（Mac 墙钟下这份内容截到的时刻，自 1970 起的 ms）；`X-Frame-Kind`（视频：`key` / `delta` / `refine` /
`keepalive`——refine 与 keepalive 都是同一画面的普通可解码 delta，照常解码即可；指针分段：`cursor`；状态分段：`status`）；
`X-Stream-Codec`（画面分段上都有）。

**编码节奏**：画面只在内容变了（或要关键帧）时编码，最多 `fps`。`fps` 的间隔从上一个画面**开始编码**时算起（从发完算会把
30 fps 压到约 21）；低延迟码率控制可能跳过超预算的画面（码流不受影响），稍后再编最新的。画面停下 300 ms 后把同一画面再编
（`refine`，文字变清楚），之后画面不变就每 100 ms 再编一次，直到连续两次都不超过一幅实时画面的预算（目标码率 / 8 / `fps` 字节：
编码器在这个码率下已经没什么可补的；被码率控制跳过的那次不算小），最多 20 次；有新内容就从头再来。refine 用临时提高的码率
（目标的 2 倍、至少 4 Mbps，不超过网络档位的天花板；排队时不提高；经 Link 时这些 refine 加起来不超过媒体层给的目标码率）。
（只编两次时，滚动后的文字在中低码率下一直是糊的：每次 refine 大约只补一幅画面的量。）之后
没有变化时每 5 s 编一次同一画面（`keepalive`，很小的 delta，让中间的代理不断开）。编码器连续失败 3 次后服务端正常结束这条流
（客户端重开）。画面尺寸在流内固定（拥塞时只降码率，不降分辨率）。这些数都是 `StreamTuning`（`StreamFlow.swift`）里的常量。

**客户端指针**（`cursor=client`）：画面里不画指针（`SCStreamConfiguration.showsCursor = false`，指针移动也不再触发重编码），
改为第一个画面之前先发一个指针分段，之后位置 / 形状 / 可见性变化时再发（合并，最多约 60 次/秒）。不带 `cursor=client` 的流
指针由系统画进画面，没有指针分段；客户端以「流的第一个画面之前有没有指针分段」判断谁画指针（iOS 每条流都带
`cursor=client`；第一个画面之前没收到指针分段就去掉自己画的指针）。

- 坐标：`x` / `y` / `hotX` / `hotY` / `width` / `height` 与该显示器 `POST /input` 的 `x` / `y` 同一坐标系（相对显示器的 0…1，
  `x - hotX` 是形状图的左边）。还不知道指针在哪时 `visible: false`；指针在别的显示器上时 `visible: false`。
- 位置有两个来源：服务处理完一个会移动指针的 `/input`（`move`（含按着左键的）/ `click` / `doubleClick` / `rightClick` /
  `down` / `up`、带 `x` / `y` 的 `scroll`、`drag` 的终点）就立刻发它的位置，客户端据此把本地指针交还给服务端；另外每 50 ms
  读一次系统的指针位置，**只有它变了**才跟随（有人在 Mac 前移动鼠标；读回我们自己输入的位置差不到 1.5 pt 不算），所以不跟
  输入走的读数（例如不在前台的会话）不会把指针拉回去。
- 形状：每 100 ms 看一次系统当前指针（`NSCursor.currentSystem`：箭头、I 形、手形…，尺寸按点数相对显示器归一化，PNG 是它的
  像素分辨率），拿不到时用内置箭头（`shapeId: 0`，也以 PNG 发一次：每 1600 px 画面宽 26 px 高，PNG 是它的 2 倍分辨率）。
  `shape` 只在形状变化后的第一个指针分段（以及第一个）里带，其余时候按 `shapeId` 沿用：同一个 `shapeId` 在本进程里总是同一张图
  （客户端可以跨流按 id 缓存），系统指针的 id 是不重用的大数（≥ 1000000；Linux 服务端的取法见「Linux 服务端」）。客户端解析 `shapeId` / `shape.id` 时不能套坐标的
  数值范围（曾有客户端把 ≥ 1e6 的数当无效值丢掉，结果只见点击水波纹、不见指针）；`visible: true` 而形状缺失或 PNG 解不出时，
  客户端画自己的箭头，不留空。服务端编出的 PNG 读不回来时同样改发内置箭头（日志记一次）。

**确认**：`POST /stream/ack` `{ stream, seq, keyframe?, report? }`。`seq` 是**累计**的：「seq 及以前的分段我都收全了」。
客户端每收全一个画面分段（解码前）就立即确认，最多 4 个确认请求同时在途，超出时只记住最新的 seq、等有一个回来再发（只允许
一个在途不行：上一个确认还没回来时到的画面要多等一整个 RTT 才被确认，服务端会把它当成排队延迟、白白降码率）；失败的确认约
100 ms 后重发；确认请求的超时要短（iOS 1.5 s：卡住的确认占着在途名额，超时放弃后才能在服务端停用窗口之前发出新的）。
`keyframe: true` = 解码器需要关键帧（解码出错、缺参数集、断档）：服务端尽快回一个 `key` 分段（每 500 ms 至多一个）。
`stream` / `seq` / `keyframe` 不合法 400；`report` 宽松解码，从不让确认失败（见「播放报告」）。回答 `{ ok: true, net }`；
没有这个 id 的打开中的流 404（客户端停止确认）。确认不需要控制权。

**流控**（服务端）：

- 窗口：已发出但还没被累计确认覆盖的画面分段 ≤ W（至少 4，并随路径的高 RTT 放大到能覆盖两个 RTT 的画面数：⌈2 × RTT × fps⌉ + 2，
  RTT 取最近 10 s 样本的 p90，最多 24——固定的 W 把帧率卡在 W / RTT，RTT 140 ms 的手机路径上 4 个只有约 21 帧/s；只覆盖一个
  最小 RTT 也不够（实际 RTT 高于最小值、确认成批回来、画面成串到），130 ms 的路径上窗口 9 一分钟要卡几百次、是手机上多数顿挫的
  来源，16 则一次不卡；两个**最小** RTT 在 5G 上也不够：最小 80 ms、p90 170 ms、尖峰到 440 ms 的路径上算出 12，滚动时每 10 s
  卡 6–9 次，p90 算出 23；视频分段只有几 KB，排队由下面按排队延迟调码率来控制，不靠窗口）。窗口满时不编码；窗口一开就编**最新**的画面（相对上一个
  **编出来的**画面的 delta——码流从不跳帧，中间的桌面状态只是被合并掉）。
- RTT 完全在 Mac 时钟上量：画面分段写完 → 覆盖它的确认到达。不需要对时。
- 收到第一个确认之前没有窗口。窗口满且 1 s 没有确认：发一个探测画面。确认开始后又 3 s 没有确认（有画面在途时）：这条流暂不用
  窗口（记日志），之后来了一个**新鲜**的确认（确认到的画面发出不到 1 s）就恢复（记日志；卡在路上的旧确认不算），每条流最多
  恢复 5 次，再停就一直不用。没有确认的流按起步码率跑。
- 自适应（稳定 > 帧率 > 低延迟 > 画质）：排队延迟 = 最近 1 s 内 RTT 样本的**最小值** − 最近 10 s 的最小 RTT（窗口里不足 3 个
  样本时不做判断）。抖动是尖峰，抬不高窗口最小值；真排队（发得比路径能带的多）会抬高每个样本。（以前用平滑 RTT（EWMA）−
  最小 RTT：走隧道的手机路径光抖动就让它停在 30 ms 上下，码率既越不过起步值、掉下去也爬不回来。）
  - 下调：排队延迟 > 50 ms 持续约 500 ms → 码率 ×0.85（下限 300 kbps），并把下调前码率的 0.9 倍记为临时天花板，30 s 内任何上调
    都不越过它（再撞一次就刷新）；到了下限仍拥塞就停在下限。不算拥塞的情形：关键帧发出后 1.5 s 内（它是一阵几十 KB 的突发）；
    这条流最近 2 s 实际发出的不到目标的一半、且这 2 s 里窗口没卡住过画面（画面静止、只发指针和保活时，路径上的排队不是它造成
    的，降了只会让下一次滚动发糊：5G 上一块静止屏幕每秒只发 39 kbit/s，RTT 尖峰 23 s 就把它从 3500 砍到 300，之后 20 s 的滚动
    都在 300–900 kbit/s）；跳过的次数计入统计行的 `held N`。
  - 上调：排队延迟 < 25 ms 为干净。低于起步码率时每 500 ms ×1.25 回升到起步码率；高于它时，干净满 2 s 后每 1 s（一个判断窗口）
    ×1.1，且要这条流最近 2 s 实际发出的码率达到目标的 80%（编码器用不满的目标说明不了路径能带多少）。被窗口卡住**不**算能涨的
    证据（以前算：5G 上 RTT 尖峰超过约 270 ms 就把 16 个画面的窗口占满，而流只发 0.4–3 Mbps，码率因此从 3500 一路涨到 12000 kbps，
    内容一用到 10 Mbps 路径就排队）。
  - 蜂窝网络（下面的 `cellular` 档）上：临时天花板记 120 s（不是 30 s），越过起步码率的上调每 2 s 至多一次、每次 ×1.05（不是每 1 s
    ×1.1）。5G 上一条稳定能带 6–10 Mbps 的路径，30 s 的天花板一过期就以每秒 ×1.1 冲到 15–20 Mbps，3 分钟下调 10 次，每次排队都把
    RTT 从 90 ms 推到 200–330 ms、手机操作时每秒顿 3–5 次；模拟里同样一条 10 Mbps 的路径 3 分钟：原规则下调 19 次、拥塞 14.8 s，
    蜂窝规则下调 3 次、拥塞 3.9 s，停在约 8 Mbps。
  - 码率起步 3.5 Mbps、天花板 20 Mbps（`YOYO_VIDEO_MAX_KBPS` 可调低天花板，起步随之不超过它）。
- **网络档位**：天花板还看客户端最近一份 `report.net`（10 s 内的，见「网络质量」）：`constrained: true`（低数据模式）→ 2500；
  `iface: "cellular"` 也是上面的天花板（档位名仍叫 `cellular`；以前是 8000：屏幕是自己的，不为省流量限速，排队由按延迟的下调
  管住；模拟里 5G 滚动时发出的码率 5.4 → 7.7 Mbps，p95 延迟多约 14 ms）；其余（Wi-Fi、有线、没有报告）是 `wifi` 档。流参数
  `maxKbps` **取代**档位（档位叫 `test`，不论什么网络）。档位实时生效：比当前码率低的天花板立即把码率降到它（日志
  `bitrate 12000 → 8000 kbps (profile cellular)`），更高的只是让以后的上调走得更远；档位每变一次记一行
  `profile cellular: max 20000 kbps`；客户端的 `net` 超过 10 s 没更新就回到缺省档位。refine 临时提高的码率也不超过档位的天花板。
- **视频最宽**：设了 `YOYO_VIDEO_MAX_WIDTH` 就是它（与客户端 `maxWidth` 取小）；没设时取**源像素宽的 2/3**，夹在 1600…2560 且
  不超过源（3456 px 的 Retina Mac → 2304，约每个显示点 1.33 像素，比手机横屏全图要的还多；真实桌面截图上 1792 的文字明显发虚，
  2304 与原生差别很小；M1 Pro 上 HEVC 编码 2304 约 12 ms、2560 约 14 ms、1792 约 8 ms），再与客户端 `maxWidth` 取小；结果仍不到
  1080p 像素数、而服务启动时测得本机硬件编码器在画面像素数超过 1920×1080 时明显更快（M1 Pro：1600×1034 约 16 ms，1792×1158 约
  9 ms）时，在客户端 `maxWidth`、源尺寸与 2048 px 之内放宽到刚超过 1080p 像素数的宽度。

**日志**：每条流每 10 s 一行 `stats:`（截屏回调、发出的画面、编码耗时、指针分段数，以及流控：编码器、宽度、码率、RTT、窗口
最小的排队延迟 `qdmin`、临时天花板 `cap`、上调 / 下调次数 `climbs` / `downs`，有跳过的下调时 `held N`，不是 `wifi` 档时还有档位），
行末是客户端最新一份播放报告的摘要 `phone …` 与声音的 `audio …`（见「播放报告」）。码率变化只在下调、以及上调到了当时的天花板
时另记一行（`bitrate 3500 → 2975 kbps (…)`），其余上调只计入 `climbs`；另外单独成行的有：流的打开（`h264 @60 fps stream <id>,
cursor client`）与关闭、档位变化、网络等级变化（`phone net: …`）、窗口停用（`no ack for 3 s; flow-control window off for this
stream`）与恢复（`acks are back`）、编码器连续失败而结束流。

**客户端的播放**（Yoyo Control iOS 的做法，全自动、没有设置项；网页 kit `@yoyocontrol/screen-web` 的 `Playout` 是同一套规则；
别的客户端可参考）：

- **平滑播放**：确认与解码的时机不变（收全即确认、立即解码），只推迟**显示**。每个画面的 `delay = 收全时刻（本机时钟）−
  X-Frame-Time`（含两边的时钟差与网络延迟）；`base` = 最近约 3 s 内 `delay` 的最小值（跟踪时钟差与漂移；`delay` 比 `base` 小
  500 ms 以上、或大 500 ms 以上持续 1 s → 时钟跳变，清空窗口重新估计）；深度 = 窗口内 `delay − base` 的 p95 + 4 ms，夹在 0…100 ms
  （以前 60 ms，5G 上一直顶在上限；模拟里 100 ms 在类似 LTE 的路径上把顿挫从 0.81 降到 0.45 次/s，抖动小的路径上深度本来就远在
  上限之下、没有代价）；Mac 不在局域网上（直连的不是私有 / 链路本地地址，如 Tailscale）时上限 200 ms（5G 上看视频时抖动的 p95
  过了 100 ms，顶在上限时每秒顿 2 次；等待的画面数上限随之从 12 放到 18），变大立即生效、变小每秒至多 10 ms，前 10 个样本用 25 ms。画面在 `X-Frame-Time + base + 深度 + 一个刷新
  周期` 时显示（CADisplayLink 的回调比它画的那次刷新早一个周期，不加这一项，在深度之内到的画面也可能晚一帧）：每次刷新显示已到时
  的最新一幅，更早的丢掉；队列至多 12 幅（4 幅在 60 帧/s 时等于把深度悄悄限在 67 ms）。比深度上限再晚一个画面间隔以上才到的画面
  立即显示、不计入估计（缓冲吸收不了的卡顿不应把深度顶到上限）。`refine` / `keepalive`（`X-Frame-Time` 是原画面的）不计入估计、
  到了就显示；没有 `X-Frame-Time` 的解出来就显示。剩下的 ≥ 150 ms 停顿（模拟里 5G 上约每分钟 2–3 次）是路径本身的尖峰。
- **操作时自动低延迟**（跟手，统计行写 `responsive`）：持有控制权且有手指按在画面上（第一根手指落下起，不等手势识别：点按、
  触控板拖动、双指滚动、捏合都算），或刚向 Mac 发出按键 / 文字（网页：任何发出的输入，含滚轮与指针移动）时，播放进入「操作中」，
  深度降到**交互深度** = min(平滑深度, 预算, 30 ms, 画面间隔 + 4 ms)：约一个画面间隔（比它更晚的画面反正会被下一幅追上），够抹平
  路径的小抖动，不为 5G 的尖峰等。均匀节奏不起作用；采样的画面（不是 `refine` / `keepalive`、带 `X-Frame-Time`）的显示时刻 =
  min(`X-Frame-Time + base + 交互深度`, `收全时刻 + 交互深度`) + 一个刷新周期；比这晚到的、以及吸收不了的卡顿画面在下一次刷新
  显示（以前卡顿画面还要再等一个预算）。预算 = min(0.25 × 最近一次确认回答的 `net.rttMs.min`（10 s 内的）, 45 ms)，不到 8 ms 就是 0；
  还没有这样的回答时，Mac 在手机的局域网上（连的是私有 / 链路本地 IPv4 地址）为 0，其他路径（Tailscale、转发的端口）为 30 ms。
  预算为 0、或交互深度不到 8 ms（平滑深度本来就浅的平稳路径）时解出来就显示：局域网上最小 RTT 约 8 ms，所以和以前一样解出来就显示。
  经隧道转发的 5G 路径（最小 RTT 约 136 ms，预算 34 ms）上 60 帧/s 时交互深度约 21 ms、30 帧/s 时 30 ms（以前是预算本身 34 ms），
  而看视频时的平滑深度是 100–200 ms。
  - **追帧**：进入操作中的那一刻，队列里等着的画面立即按交互深度（预算为 0 时按「到了就显示」）重新定时，下一次刷新就显示其中已到时的
    最新一幅、更早的丢掉：队列一次追上，不是慢慢变浅。丢的只是**解码后没显示**的画面：每个分段收全就解码（H.264 / HEVC 的后续画面
    参考前面的画面，解码从不跳过），只是不显示，参考链不受影响。
  - **回到平滑**：最后一根手指抬起、最后一次按键之后 600 ms（以前 800 ms：盖住 Mac 对最后一次输入的回应——5G 上往返加编码约
    250 ms——和紧接着的第二下点按 / 按键；更长只会让静下来的画面继续不平滑）回到平滑；等待从交互深度起、按每秒至多 100 ms 升到
    平滑的深度：每幅画面比前一幅多等一点，画面放慢约 10%，没有「抬手那一刻停住 100 ms 等缓冲填满」。之后照平滑的规则变化。
  - 声音不跟着变：音画同步（「声音」）在操作中本来就不给视频加等待，回到平滑后它的等待同样按每秒至多 100 ms 恢复。
  - 模拟（确定性，`ScreenInteractivePlayoutTests` / `screen-web` 的 `playout.test.ts`；60 帧/s，5G：多数画面 15 ms 内到、二十分之一晚
    40–110 ms，按到达顺序）：操作中每幅显示的画面都在收全后「交互深度 + 两个刷新周期」之内显示，中位等待不到平滑时的一半；最长的显示
    间隔不超过最长的到达间隔 + 交互深度 + 两个刷新周期（不会饿死）；回到平滑的 1.5 s 里显示间隔 p90 < 30 ms、没有 ≥ 120 ms 的停顿。
- **均匀节奏**（平滑时）：Mac 发布画面的间隔本身不匀（18 / 31 / 55 ms），60 Hz 的屏幕上就成了隔一帧 / 隔两帧的顿挫。每 n 次刷新
  至多显示一幅：n 是满足 n × 刷新周期 ≤ 内容间隔 + 0.15 × 刷新周期的最大正整数（换 n 有滞回：换到更大的 m 要 m × 刷新周期 ≤
  内容间隔 + 0.03 × 刷新周期，换到更小的则在 n × 刷新周期 > 内容间隔 + 0.27 × 刷新周期时），即节奏**不慢于内容**（内容间隔 =
  窗口里画面间隔的平均值，不计超过 100 ms 的停顿；37 ms @120 Hz → 4；25 ms @60 Hz → 1）；新的 n 要保持约 1 s 才换。到了该显示的
  那次刷新且有已到时的画面就显示最新的一幅，下一格 = 这次的目标时刻 + n × 刷新周期；没有就等，有了马上显示并从那里重新起算。刷新
  周期取显示链路最近约 30 次 `targetTimestamp − timestamp` 的中位数。
- **统计浮层**（三指轻点画面，调试用）：第二行以模式开头（`smooth` 平滑 / `responsive` 跟手；报告里 `mode` 仍是 `smooth` /
  `latency`），带当前等待 `buf N ms`（深度 + 一个刷新周期），跟手时还有交互深度 `touch N ms`；接着是客户端自己估算的点击 → 画面延迟
  `~N ms` = 输入往返 p50 / 2（还没有时用确认往返最小值 / 2）+ 30 ms（截屏约 14 + 编码约 12 + 写出）+ 确认往返最小值 / 2 + 播放等待
  （`bufferMs`）+ 解码耗时 + 一个刷新周期；只在客户端算，不发给 Mac。操作中第一行末尾带 `· live`。网页 kit 的 `playoutLine()` 给同样的
  `smooth · … · buf 104 ms · depth 96 …` / `responsive · … · buf 29 ms · touch 21 ms · depth 96 …`。

### 播放报告

可选。客户端大约每 2 s 在**一个**确认上带 `report`（失败的那个确认不必重发它），说明它这边的播放情况，供服务端记日志：服务端
只留最新的一份，不为它单独记行，而是在这条流每 10 s 一行的 `stats:` 末尾带上摘要
`phone <mode> <fps> fps hitch <n>/s stall <n>/s buf <ms> ms jit <ms> ms`（`stall` 是 `stall150PerSec`；没给的项不写；例：
`phone smooth 59.6 fps hitch 0.4/s stall 0.1/s buf 52 ms jit 48 ms`）。除了 `net` 决定码率的网络档位，它**不**影响流控。

```ts
interface ScreenPlayoutReport {   // 客户端最近约 3 s；除 mode 外都可缺
  mode: "smooth" | "latency";     // smooth = 抖动缓冲后匀速显示；latency = 操作中（跟手），按交互深度显示
  fps?: number;                   // 每秒显示的画面
  gapP50Ms?: number; gapP90Ms?: number;                 // 相邻两次显示的间隔
  arrivalGapP50Ms?: number; arrivalGapP90Ms?: number;   // 相邻两个画面分段收全的间隔
  hitchesPerSec?: number;         // 显示间隔超过 max(中位数 × 2, 50 ms) 的次数 / 秒
  stall150PerSec?: number;        // 显示间隔比两幅画面 X-Frame-Time 之差长 ≥ 150 ms 的次数 / 秒（Mac 的内容在动、客户端的画面停住了）
  stall300PerSec?: number;        // 同上，≥ 300 ms
  bufferMs?: number;              // 准时到的画面要等多久：smooth 是抖动缓冲深度 + 一个刷新周期；latency 是交互深度 + 一个刷新周期
  jitterP95Ms?: number;           // 播放估计里 (delay − base) 的 p95，即缓冲要多深才吸收得了
  touchBufferMs?: number;         // latency 时在用的交互深度（0 = 解出来就显示）
  droppedPerSec?: number;         // 解出来却没显示的画面 / 秒
  decodeMs?: number;              // 平均解码耗时
  refreshHz?: number;             // 显示链路实测的屏幕刷新率
  paceMs?: number;                // 均匀节奏的固定间隔（不按节奏时缺省；latency 时没有）
  bufferCapMs?: number;           // 抖动缓冲深度的上限（smooth；100）
  net?: ScreenNetReport;          // 客户端这边的网络（见「网络质量」）
  audio?: ScreenAudioReport;      // 声音流开着时的声音播放
}
interface ScreenAudioReport {     // 计数（underruns … cuts）与 stretchMs 是自上一份带 audio 的报告以来的
  outputMs: number;               // AVAudioSession.outputLatency（0…1000）
  ioMs: number;                   // AVAudioSession.ioBufferDuration（0…200）
  bluetooth?: boolean;            // 输出是蓝牙（A2DP / LE / HFP）或 AirPlay
  depthMs: number;                // 缓冲自己需要的抖动深度（0…3000）
  bufferedMs: number;             // 现在缓冲着多少（0…3000）
  addedMs: number;                // 准时到的包在客户端还要加多少：播放延迟 + io + 输出（0…5000）
  skewMs?: number;                // 同一时刻的声音 − 画面，+ = 声音晚（−3000…3000）；只在看真实显示器的视频时有
  floorMs?: number;               // 为对齐而给视频加的延迟（蓝牙），> 0 时才有（0…1000）
  underruns: number;              // 缓冲见底（各 0…100000）
  late: number;                   // 过了播放时刻才到的包
  concealed: number;              // 解码器补出来的包
  cuts: number;                   // 听得见的断音
  stretchMs?: number;             // 净变速，+ = 放慢了、延迟变大（−60000…60000）
  kbps: number;                   // 收到的声音码率（0…100000）
}
```

服务端宽松解码（`StreamPlayoutReport.swift`、`StreamAudioReport.swift`），这是唯一的校验，报告有问题从不让确认失败：`report`
不是对象或 `mode` 不认识 → 没有报告；数字字段不是有限的非负数就丢掉那一项；不认识的键忽略。`audio` 不是对象就忽略；它的数字
不是有限数就丢掉，其余夹到上面的范围（只有 `skewMs` / `stretchMs` 可以为负），缺字段没关系。服务端把 10 s 里的 `audio` 计数
（`underruns` / `late` / `concealed` / `cuts` 与 `stretchMs`）加起来、其余取最新的一份，统计行在 `phone …` 之后接
`; audio delay 118 ms underruns 0`（`delay` 是最新的 `addedMs`，`underruns` 是这 10 s 的合计；两项都没有时写 `-`；这 10 s 里没有带
`audio` 的报告就没有这一段）。声音报告不影响任何流控。

### 网络质量

可选，为排查与提示用（`StreamNetQuality.swift`）。客户端在播放报告里带 `net`；服务端用这条流**自己的确认往返**加上客户端最近一份
`net`（10 s 内的）打分，结果放进**每个**确认回答的 `net`（至多每秒重算一次）。

```ts
interface ScreenNetReport {       // 全部可缺；不认识的值丢掉
  route?: "lan" | "direct" | "tunnel";   // 这条流现在走的路：局域网直连（含 Tailscale）/ 公网直连（外网直连，REMOTE.md）/ 经中继或别的通路转发
  iface?: "wifi" | "cellular" | "wired" | "other";
  radio?: "5g" | "lte" | "3g" | "other";   // 蜂窝制式（iface 为 cellular 时）
  expensive?: boolean; constrained?: boolean;   // 系统路径的标志（蜂窝 / 热点；低数据模式）
  inputRttMs?: { p50?: number; p90?: number; n?: number };   // POST /input 发出 → 收到回答，最近 10 s，只算当前路线（换路线清零）
  rxKbps?: number;                // 报告窗口内收到的流字节（kbit/s）
  failures?: number;              // 最近 10 s 输入与确认请求失败（超时 / 网络错误，不含 4xx）的次数
}
interface ScreenNetQuality {      // 服务端看到的这条流的网络（最近 10 s）
  grade: "good" | "fair" | "poor" | "unknown";   // 不认识的值按 unknown
  rttMs?: { min: number; p50: number; p90: number };   // 这条流自己的确认往返（画面写出 → 它的确认到达）
  jitterMs?: number;
  reasons: string[];              // 不是 good 的原因："rtt" | "jitter" | "failures" | "few-samples"（开放集合）
}
```

打分：往返取确认往返的 p90，抖动 = p90 − min；确认往返样本少于 5 个时改用 `inputRttMs`（要 n ≥ 5：往返取它的 p90，抖动 = p90 − p50，
日志写 `by input`）；两样都不够 → `unknown`（`few-samples`），但只有失败也说明问题：失败 ≥ 1 → `fair`、≥ 3 → `poor`
（`failures, few-samples`）。往返 > 250 ms、抖动 > 80 ms 或失败 ≥ 3 → `poor`；否则往返 > 100 ms、抖动 > 30 ms 或失败 ≥ 1 → `fair`；
其余 `good`。`reasons` 依次列出达到该档的项。`rttMs` 只在确认往返样本够 5 个、按它打分时给；按输入往返打分时没有 `rttMs`，那时的
`jitterMs` 是输入往返的 p90 − p50，与确认往返的 p90 − min 口径不同。

服务端在等级变化时（流开始时从 `unknown` 算起；只在有确认时）记一行
`phone net: tunnel wifi rtt 137/165/210 ms jitter 73 ms input 160/190 (12) rx 1.6 Mbps fail 0 → fair (rtt, jitter)`（客户端没给的项
不写；低数据模式写 `low-data`；按输入往返打分时是 `→ fair by input (…)`），流结束时再记一次最后的等级 `… ended; last phone net: …`
（从没有过确认就不记）。服务端宽松解码 `net`（不认识的枚举值、不是有限非负数的数字丢掉，`net` 不是对象就忽略，报告其余部分照常）；
客户端同样宽松解码回答（不认识的等级按 `unknown`，`rttMs` 三项不全就当没有；回答里没有 `net` 就不显示等级）。等级只做提示与日志，
不影响流控；`net` 本身的 `iface` / `constrained` 决定码率的网络档位，客户端交互深度的预算取回答里的 `rttMs.min`。

### 声音

`GET /audio`：Mac 上本登录会话的系统声音，只有 Mac → 客户端（没有麦克风，也没有客户端 → Mac）。没有参数。分段格式与 `/stream`
相同（Content-Type 见「媒体类型」）。看画面级别：不需要控制权。客户端断开即停止。实现在 `AudioStream.swift`、`AudioCapture.swift`。

- **响应头**：`X-Audio-Codec: opus`、`X-Audio-Rate: 48000`、`X-Audio-Channels: 2`、`X-Audio-Frames: 960`（每个包的帧数）、编码器有
  magic cookie 时 `X-Audio-Cookie: <base64>`（解码器的 `magicCookie`；Opus 一般有）、`X-Audio-Video-Offset: <ms>`（整数，可为负）：
  `X-Audio-Time` 加上它，就是**真实显示器**上同一时刻的画面会带的 `X-Frame-Time`（`AudioVideoOffset.swift`）。它等于 tap → 扬声器
  （默认输出设备的 `kAudioDevicePropertyLatency` + `SafetyOffset`（输出方向）+ 它第一个输出流的 `kAudioStreamPropertyLatency`，不算
  `BufferFrameSize`：tap 给采样打的是输出周期的时间，本来就比「现在」早一个缓冲；帧数按标称采样率换成 ms；采集开始时读一次，读不到
  按 18）加截屏延迟（最近一条真实显示器流最近 120 帧「回调时的墙钟 − `SCStreamFrameInfo.displayTime`」的中位数；本进程还没截过时
  按 14，即实测值：客户端与画面同时开声音，第一个响应通常早于第一帧）。实测（2026-10-25，内建扬声器）：`X-Audio-Time` 比采样真正从
  扬声器出来早 18.4 ms（±0.2），`X-Frame-Time` 比内容上屏晚 13.7 ms（74 帧的中位数），即同一时刻画面的时间戳比声音的晚约 31 ms；
  两边延迟相同时声音会早约 31 ms 播出。这台 Mac 上属性给出 latency 70 + safety 74 + stream 690 = 834 帧 = 17.4 ms，实测 18.1–19.0
  （再加上 512 帧的输出缓冲就是 28.0，与实测不符）。这一项只在 tap 用缺省 IO 缓冲时成立（见下）。每个响应开头取一次、之后不变；
  客户端只对真实显示器的视频用它。采集开始时记一行 `audio: A/V offset 31 ms = tap→speaker … + capture …`。
- **分段**：`Content-Type: audio/opus`、`Content-Length`、`X-Audio-Seq`、`X-Audio-Time`，每个分段一个 Opus 包（20 ms）。
  `X-Audio-Seq`：交给这个响应的包的序号（1、2、…，只增不重置），跟不上的客户端被丢掉的包留下缺口；`X-Audio-Time`：这个包解出来的
  第一个采样在 Mac 墙钟上的时刻（自 1970 起的 ms，与 `X-Frame-Time` 同一个钟）——按采样计数排（t0 + 采样数 / 48000，相邻两包正好差
  20），t0 取自 Core Audio IO 的主机时间，计数与它偏差超过 20 ms 时重新对齐；编码器输出比输入晚 312 帧（Opus 的 priming）。静音时
  照样每 20 ms 一个包（Opus 只有 3 个字节）：macOS 只在有声音播放时才跑 tap 的 IO（声音开始后约 0.2–0.3 s 来第一块，最后一个声音停后
  几秒停），其间服务自己补静音（比墙钟晚 25 ms 补，到达的延迟与有声音时相近）；IO 重新跑起来的那一刻 `X-Audio-Time` 会向前跳一次
  （实测 27–70 ms，`X-Audio-Seq` 连续），客户端按时间排，这段空当就是静音。不认识的分段头忽略即可。
- **采集**：Core Audio process tap（`CATapDescription` 全局立体声、排除自己，`muteBehavior = unmuted`，macOS 14.2+）放进一个只有这个
  tap 的私有 aggregate 设备（不带扬声器子设备：带了的话，不在控制台上的会话里 `AudioDeviceStart` 会卡死）。不用 ScreenCaptureKit 的
  声音，是因为它在快速用户切换切走的会话里全是 0；tap 拿到的是音量之前的采样（会话静音也有声音）。aggregate 保持设备缺省的 IO 缓冲
  （这台 Mac 上 512 帧 = 10.7 ms）：在 socket 上实测包到达 − `X-Audio-Time` 最小 41 / 中位 47 / p95 53 ms、抖动 p95 11.5 ms。试过
  256 帧（中位 29 ms、抖动 p95 6.8 ms）而没有采用：IO 缓冲比输出设备的小时，tap 的时间戳整体后移约 16.7 ms，真实的延迟只少约 1–5 ms，
  CPU 多约 0.8 %，`X-Audio-Video-Offset` 的 tap → 扬声器一项也不再成立。AVAudioConverter 编 Opus（48 kHz 立体声，96 kbit/s VBR；放音乐
  时整条声音路径约占一个核的 3 %，闲时约 0）。所有 `/audio` 客户端共用一份采集：第一个客户端来时开始（响应头与第一个静音包几十 ms
  内就到），最后一个走后 3 s 停；每个客户端一个约 500 ms 的有界队列，满了丢**最早**的包。有客户端时每 10 s 一行日志；`GET /audio/stats`
  给出计数器（见 `mac/README.md`）。
- **看门狗**：实测运行中的进程可能整个变「聋」：每个客户端、新建的 tap 都只读到 0，同一个可执行文件新起一个进程立刻就有声音（也见过
  发生在 TCC 拒绝之后、或进程熬过了一次 coreaudiod 重启之后）。采集运行时每 2 s 看一次：最近 ≥ 4 s 全是精确的 0，**同时**这 4 s 里本
  账号有别的进程在输出（`kAudioProcessPropertyIsRunningOutput`）——什么都没在放时永远不会触发——就做一次自检（起一个 `afplay` 子进程放
  -90 dBFS 的 1 kHz 音（听不见），给它单独一个探测 tap；听得见的结果 120 s 内有效，否则 30 s 后再测）。听不见 → 服务以 75 退出，菜单栏
  App 不退避地重启它（客户端重开流）；15 分钟内至多一次（`$TMPDIR/yoyo-audio-deaf-<uid>` 记着上次退出的时间）：新进程又聋了说明重启
  没用，而每隔一两分钟重启一次还会每次打断视频流。coreaudiod 重启（`kAudioHardwarePropertyServiceRestarted`）之后，熬过它的进程新建的
  tap 读到别的 App 的声音全是 0，所以服务一看到重启同样以 75 退出。
- **不做的**（2026-10-25 测过）：新的分帧（分段头约 120 B × 50/s ≈ 44.5 kbit/s，载荷 1.2（静音）… 70 kbit/s（音乐），合计 ≤ 115 kbit/s，
  只是视频的 1–4 %）、10 ms 的包、DTX（静音不发包：客户端靠每 20 ms 一个包判断流活着）、声音比视频优先。
- **错误**：采集起不来（`YOYO_AUDIO=off` → `audio off`；没有 process tap（macOS 14.2 之前）、tap / aggregate 建不出来、编码器不可用）时
  在响应头之前 503 `{ error }`；客户端这次访问不再取声音。已经回了响应头之后 5 s 还没有 IO 只记日志（多半只是还没有东西在放），流照样
  开着、照样发静音包。
- **权限**：「录制系统声音」（`kTCCServiceAudioCapture`）按 App 授予。第一次 `AudioDeviceStart` 时弹框，等到有回答才返回（那一次的响应头
  会晚约 10 s）；弹框没人看得见时（快速用户切换切走的会话）约 10 s 后被取消、记成拒绝，之后不再弹。实测（macOS 27，2026-10-24）记成拒绝
  之后 tap 照样拿到声音；以后的 macOS 可能真的拦，稳妥的做法是在 Mac 前去「系统设置 → 隐私与安全性 → 屏幕与系统录音 → 仅系统录音」里
  打开 Yoyo Control。

### 连接状态

服务给每个显示器算出「它的画面此刻在干什么」，只发**代码**（`phase` + `reason`）：界面上的文字由客户端按代码自己生成，未知的 `reason`
显示一句通用的话；`detail` 是英文技术说明（例如 `Screen Recording permission is not granted to Yoyo Control`），只用于日志 / 调试浮层。
实现在 `ScreenState.swift`（纯映射 + 发布）、`StreamStatus.swift`（状态分段）。

```ts
type ScreenPhase = "connecting" | "reconnecting" | "ready" | "unavailable";   // 未知值按 "reconnecting"
type ScreenStateReason =      // 开放集合
  | "starting"          // connecting：还没算出第一个状态
  | "no-session"        // unavailable：本账号没有图形登录会话
  | "no-permission";    // unavailable：没有屏幕录制权限
interface ScreenDisplayState {
  display: number;      // ScreenDisplay.id
  main?: boolean;       // 主显示器的那条；它的 id 会变（换了主显示器），客户端的 id 找不到时用 main: true 那条
  phase: ScreenPhase;
  reason?: ScreenStateReason | string;
  since: number;        // ms（Mac 墙钟，epoch）：这个 phase + reason 开始的时刻
  detail?: string;      // 英文、技术性
}
interface ScreenConsole { locked: boolean }   // IOConsoleLocked：锁屏时画面就是锁屏
interface ScreenStreamStatusPart extends ScreenDisplayState { console: ScreenConsole | null }   // 状态分段的 body
```

- **条目**：主屏幕一条（`main: true`，`display` 为当前主显示器的 id）：ScreenCaptureKit 这条路能截就 `ready`，否则
  `unavailable/no-session` / `no-permission`。服务自己不发 `reconnecting`：那是客户端（或转发方）在连接断开时自己推断的。
- **控制台**：约每 0.5 s 读一次 IORegistry 根（`IORegistryGetRootEntry`；不是路径 `IOService:/`，那是平台设备，没有这个属性——2026-11-07 以前的版本因此一直报 `false`）上的 `IOConsoleLocked`、稳定 1.5 s 后的状态；服务刚启动、还没读到时为 null。
  Mac 版本机的 `POST /console/lock` / `/console/unlock`（`docs/LOCAL-API.md`「锁屏与解锁」）成功后不等这 1.5 s，状态立即更新。
- 状态每 0.5 s 重算一次（权限授予、换主显示器），控制台变化时立即重算；变化立即发布并去重：`since` 只在 phase / reason 变化时才变，
  没有变化不发。

**三条通路**：

1. `GET /status` 的 `states` / `console`。
2. `GET /events`：`200`、`Content-Type: application/x-ndjson`、`Cache-Control: no-cache`，流式到连接关闭为止；可以多个订阅者；服务停止时
   结束（客户端断了就重连，1 s 起翻倍、最多 10 s）。每行一个 JSON 对象，按 `type` 分，客户端忽略不认识的 `type`：
   - `{"type":"state","states":[…],"console":{…}|null}`：连上立即一行，之后每次状态变化一行。
   - `{"type":"clipboard",…ClipboardSummary}`：紧跟第一行 `state`，之后剪贴板每变一次一行（见「剪贴板」）。
   - `{"type":"control","control":{…}}`：控制权变化（`docs/REMOTE.md`「控制权」）。
   - `{"type":"abort","reason":"esc"}`：本机自动化开着时用户在 Mac 上按了 Esc（`docs/LOCAL-API.md`）；只发给当时连着的订阅者。
   - `{"type":"input-elsewhere","at":…,"source":"hardware"|"process","pid"?:…,"app"?:…,"bundleId"?:…}`：有不是这个服务发出的输入
     （`docs/LOCAL-API.md`「别处来的输入」）：第一次立即，持续时至多每秒一行。只有 Mac 版有（要辅助功能权限，`/status.features.inputElsewhere`）。
   - `{"type":"pairing","open":true|false}`：配对窗口打开 / 关上（Mac 版）。窗口不进任何截图，远程画面靠它说「配对窗口在电脑上开着」；
     不带配对码。
   - `{"type":"ping"}`：15 s 没有别的行时。
3. 取流带 `status=1`。

**流里的状态分段**（`/stream?status=1`；不带它的流里没有状态分段，字节与以前完全相同）：

- 响应头之后立刻一个状态分段（这条流的显示器——`display` 是这条流的 `X-Display`，`main` 说明它是不是主显示器——外加 `console`），之后
  这条流的状态每变一次再发一个。分段头：`Content-Type`、`Content-Length`、`X-Frame-Seq`（与画面 / 指针分段同一个序列，占一个号）、
  `X-Frame-Kind: status`。**不**计入确认窗口，也不用为它确认（累计确认照常覆盖它的号）。
- 流报的是 ScreenCaptureKit 这条路的状态；变成 `unavailable` 时发出那个状态分段后正常结束。
- 还没有任何状态（没收到状态分段，也没有 `/events`）时，客户端自己推断（流结束 / 失败且 0.7 s 没有新帧 → 通用的「重连中」）。

例：

```
GET /events → application/x-ndjson
{"console":{"locked":false},"states":[{"display":1,"main":true,"phase":"ready","since":1792725383971}],"type":"state"}
{"type":"ping"}

--frame
Content-Type: application/vnd.yoyo-control.status+json
Content-Length: 89
X-Frame-Seq: 1
X-Frame-Kind: status

{"console":{"locked":true},"display":1,"main":true,"phase":"ready","since":1792725399000}
```

### 输入

`POST /input`（字段见 `mac/README.md`「HTTP API」）。坐标 `x` / `y` 是相对显示器的 0…1（超出的夹到边上）；不合法 400（先于权限
检查），没有辅助功能权限 403。回答 `{ ok: true }`，被超过的移动 `{ ok: true, stale: true }`。

```ts
interface ScreenInput {
  type: "click" | "doubleClick" | "rightClick" | "move" | "drag" | "scroll" | "type" | "key" | "down" | "up";
  display?: number;            // 缺省 = 主显示器
  x?: number; y?: number;      // click / doubleClick / rightClick / move / drag / down / up 必填；scroll 可选（先把指针移过去）
  dx?: number; dy?: number;    // drag：相对 (x, y) 的位移，同样 0…1；scroll：点，dy > 0 = 往下看更多内容，dx > 0 = 往右
  text?: string;               // type：非空，换行 = 回车
  key?: string;                // key：键名（不分大小写）：a–z、0–9、return、enter、escape / esc、tab、space、delete / backspace（退格）、forwardDelete、up / down / left / right、home、end、pageUp、pageDown、f1…f12、- = [ ] ; ' , . / \ `；Linux 服务端另认 insert（「Linux 服务端」）
  modifiers?: ("cmd" | "shift" | "alt" | "ctrl")[];   // 指针类与 key 按住的修饰键（实时拖拽：只对 down 生效，按住到 up）
  button?: "left";             // 只用于 move：按着左键移动（实时拖拽）；其他值 400
  phase?: "began" | "changed" | "ended";   // 只用于 scroll：两指手势的阶段；缺省 = 普通滚动；其他值 400
  vx?: number; vy?: number;    // 只用于 scroll 的 ended：抬手时手指的速度，点/秒，正负同 dx / dy
  seq?: number;                // 只用于 move：客户端的移动序号（非负整数）
}
```

**控制权**：配对的手机要先 `POST /control { controller: "user" }` 才能输入，没拿到 409 `take control of the screen first (POST /control)`；另一部手机
拿着时 409 `{ error, code: "controlled-elsewhere", controllerDevice: { id, name } }`（客户端据此转为旁观、显示谁在操作）。本机 socket
上的程序不是控制者：没有手机拿着时照常输入，有手机拿着时同样 409 `controlled-elsewhere`。控制权换手时还按着的左键先抬起。详见
`docs/REMOTE.md`「控制权」。

**客户端什么时候拿控制权**（Yoyo Control 的屏幕页，iOS kit 与 `@yoyocontrol/screen-ui` 一样）：页面打开时只看（旁观），不发
`POST /control`；只有用户真的输入时才拿：触控板上的第一下触摸（网页上还有画面上的点击 / 滚轮、触摸模式下画面上的轻点或拖动）、
键盘按钮、按键或打字、把剪贴板粘到电脑。打开、回到页面、状态轮询 / `screen.control` 事件、缩放或拖动画面、全屏、转屏都不拿。
拿的时候压过自动化（agent 在用时照样拿走）；另一部手机拿着时只有「接管」按钮会拿。这样一个在操作间隙短暂放开控制的自动化，
不会因为有人打开屏幕页看一眼就被打断。触控板上写着怎么拿（「触摸即可开始控制。」/ agent 在用时「触摸即可接管。」）。

页面不在控制时（没人拿着、agent 在用、另一部手机拿着），顶上的胶囊写着谁拿着，并带一个明确的按钮：没人拿着时「仅查看 · 开始控制」，
agent 在用时「Agent 正在使用屏幕 · 接管」，另一部手机拿着时「X 正在操作 · 接管」。点它就 `POST /control { controller: "user" }`
（另一部手机拿着时也一样：这是用户明确的动作），拿到后胶囊换成「你正在控制」的徽章。全屏（只看）时胶囊也显示，点按钮先退出全屏、
回到普通页面再拿；网页上把手机转到横屏的只看模式回不去，那里只显示徽章。没有「辅助功能」权限（不能输入）时没有按钮，只有徽章。

上面是整页（iOS `YoyoControlPolicy.takeOnInput`）的规矩。用 iOS kit 的三层自己拼页面的宿主可以选 `.explicit`：没拿到控制权时输入在客户端
就丢掉，既不发输入也不 `POST /control`，只有页面上明确的「接管」才拿；服务端的语义不变。

**流水线移动**（`seq`）：`move` 可带 `seq`（客户端每个移动加一；iOS 从当时的墙钟毫秒数起，换页面 / 换设备也接着往上走，所以是 64 位）。
服务记住最近 2 s 内执行过的最大 `seq`（同一时间只有一个控制者，所以全局一个，`PointerMoveGate`），`seq` 比它小的 `move` 回
`stale`、**不执行**；比它小 1000 以上、或 2 s 没有 `move`，从新的 `seq` 重新计起；不带 `seq` 的移动都执行。客户端因此可以让移动
至多 3 条同时在途，被超过的由服务丢掉。

**两指滚动**（`phase` / `vx` / `vy`）：`began` = 手指开始动（它的 dx / dy 就是第一段位移），`changed` = 继续移动，`ended` = 抬手（dx / dy 是
最后一段还没发出的位移，没有就是 0，仍然带上；`vx` / `vy` = 抬手速度）。服务把每条滚动的像素在「0.9 × 预计的请求间隔」内以 120 Hz
均匀发出，带 `phase` 时按 trackpad 的手势阶段发，抬手速度 ≥ 120 点/秒时在 Mac 上接着做惯性（UIScrollView 的正常减速）；新的滚动或这条路上
的点击、按下、移动立刻停下惯性；手势 3 s 没有新请求就自动结束（不做惯性）。不带 `phase` 的滚动同样均匀摊开，没有阶段和惯性。细节见
`mac/README.md`「Scrolling」。客户端（iOS）同一时刻至多一条滚动在途：其间的两指移动累加，上一条返回（成功或失败）后合成一条再发；
阶段保序：`began` 先把上一个手势剩下的发掉、另起一条（再小也发），`changed` 合进等着的那条（还没发的 `began` 仍是 `began`），`ended` 和等着
的位移合成一条发（省掉一个来回，惯性紧接着位移开始；只有等着的还是没发出的 `began` 时，`began` 先单独发、`ended` 再排一条）；点击 / 按键等
其他输入保序，发之前先把累加的滚动发出去。

**实时拖拽**：`down` 在 (`x`, `y`) 按下**左键**（`modifiers` 按住到 `up`），之后若干 `move` 带 `button: "left"` 按着左键移动，`up` 在
(`x`, `y`) 松开；一次性的 `drag` 保留。服务用 CGEvent 的 `leftMouseDown` / `leftMouseDragged` / `leftMouseUp`；按下后第一个按着的 `move`
（或 `up`）至少等按下 15 ms 再发（太快会被当成点击）。按下状态按显示器记一份（`PointerHold.swift`）；**卡死保护**（客户端可能在拖到一半时
消失：App 被杀、网络断了，Mac 的左键就一直按着，下一次点哪儿都成了拖）：按下后 10 s 没有按着的 `move` 也没有 `up` → 服务自己松开（日志
`input: left button held on display <id> for 10 s without a move or up; releasing it`）；最后一条打开着的流关闭时若还按着也松开；控制权换手
时松开。客户端（iOS）的发送规则：按着的 `move` 与触控板模式的指针移动（不带 `button` 的 `move`）走和滚动同一条合并通道——移动至多 3 条同时
在途（每条带递增的 `seq`），滚动同一时刻至多一条，其间只保留最新的位置，换类型（滚动 ↔ 移动）时先把等着的发出去；`down` / `up` 和点击、
按键一样保序（`up` 之前先发出等着的移动）；页面消失 / 进入后台时若已按下，绕过队列直接发一条 `up`（尽力而为，失败靠 10 s 保护）。

**焦点**：`GET /focus[?display=]` → `{ editable: boolean, role: string | null }`：Mac 上当前获得焦点的元素能不能打字（文本框、多行文本、网页里
可编辑的内容、终端……），经辅助功能 API 读出（`Focus.swift`）。Electron 与 Chromium 系浏览器要先被要求才建辅助功能树（服务对每个焦点 App 的
进程设一次：Electron 认 `AXManualAccessibility`；Chrome / Edge / Brave / Arc 等按 bundle id 设 `AXEnhancedUserInterface`，别的 App 不设，它会
打乱窗口动画），建树要几秒，所以浏览器刚启动后的头几次回答可能是 false。客户端在自己的单击 / 双击之后问（约 0.25 s 后，不是就 0.65 s、1.5 s
再问），`editable` 就弹出键盘。不需要控制权；没有辅助功能权限时 false；`role` 只供日志。

## 剪贴板

Mac 的剪贴板只由服务里的原生代码碰（`Clipboard.swift`）：读写 `NSPasteboard.general`、每 0.5 s 看一次 `changeCount`。客户端经
`GET /clipboard`、`/clipboard/image`、`/clipboard/file`、`POST /clipboard` 读写（参数与错误码见 `mac/README.md`「HTTP API」），经
`/events` 的 `clipboard` 行得知变化。没有图形登录会话时这些接口 503。

```ts
type ClipboardKind = "text" | "image" | "files" | "concealed" | "other" | "empty";   // 未知值按 "other"
interface ClipboardFile { name: string; size: number | null; dir: boolean }        // size null = 不知道 / 是文件夹
interface ClipboardSummary {                 // /events 的 clipboard 行：只有摘要，从不带正文
  changeCount: number;                       // NSPasteboard.changeCount；标识这一项（类似 ETag）
  kind: ClipboardKind;
  preview: string;                           // text：前 160 字，换行显示为「⏎ 」，截断时以「…」结尾；files：文件名以「, 」连起来（≤ 160）；其余 ""
  size: number | null;                       // text：UTF-8 字节数；image：PNG 字节数；files：普通文件大小之和；其余 null
  width?: number; height?: number;           // 只有 image（像素）
  files?: ClipboardFile[];                   // 只有 files，≤ 20 条（更多的计入 moreFiles）
  moreFiles?: number;
  at: number;                                // 服务第一次见到这个 changeCount 的时间（unix ms）
  source?: "phone" | "agent";                // 这个 changeCount 是服务自己的 POST /clipboard 造出来的；缺省 = Mac 上的人或程序
}
interface ClipboardItem extends ClipboardSummary {   // GET /clipboard（另有 ok: true）
  text?: string;                             // kind text：正文，≤ 1 MiB（在字符边界截断，truncated: true）；?text=0 时不带
  truncated?: boolean;
}
```

**种类**按顺序判：项上有 `org.nspasteboard.ConcealedType` 或 `org.nspasteboard.TransientType` 标记（密码管理器）→ `concealed`：没有预览、
没有正文，`/clipboard/image` / `/clipboard/file` 对它 404；有 `public.file-url` 的项 → `files`（名字、大小、`dir`）；有 `public.png` /
`public.tiff`，或者没有文字而 `NSImage` 读得了（PDF 等：从 Pages 或浏览器复制的文字也带一份 PDF / 富文本渲染，用户心里那是文字）→ `image`
（宽高、PNG 大小——每个 changeCount 只转一次 PNG 并缓存；读不出来的图不算图）；有文字 → `text`；没有项 → `empty`；其余 `other`。

**写入**：`POST /clipboard { text }` 或 `{ files: ["/abs/path"…], source?: "phone" | "agent" }`（缺省 `phone`）：`clearContents()` 后写入。
文件：每个文件一个 `NSPasteboardItem`（`public.file-url`）；单个图片文件（png / jpeg / gif / webp / heic，按扩展名）在同一项上另带图片数据，
⌘V 进收图片的 App 贴出来的是图。服务记下这个 changeCount 的 `source`，立即发一行 `clipboard`（不等下一次轮询），回答同 `GET /clipboard`。
文字为空 400、超过 1 MiB 413；路径不是存在的文件或文件夹 400；至多 20 个文件。配对的手机只能写文字（`files` 是 Mac 上的路径），`source`
总是 `phone`。本机的程序要把手机发来的文件放上剪贴板，先自己把文件存到 Mac 上，再以路径写入。

**事件**：`/events` 在第一行 `state` 之后紧跟一行 `{"type":"clipboard",…ClipboardSummary}`，之后每看到一个新的 `changeCount` 再写一行。
正文只在客户端来要时才离开 Mac（`GET /clipboard`、`/clipboard/image`、`/clipboard/file`）。重连后客户端从第一行 `clipboard` 得到当前摘要
（没有回放）。
Linux 服务端读 X 的 CLIPBOARD、写入时同时拥有 CLIPBOARD 与 PRIMARY（「Linux 服务端」）。

## Linux 服务端

`linux/`（`linux/README.md`）是这套接口在 Linux 上的实现：无头（没有 App），把一个 X 显示经 TCP + Bearer 令牌给出去；带
`--remote` 时另有 Mac 那样的远程访问（uu Link、配对、控制权、端口映射、信令服务，`docs/REMOTE.md`「Linux 服务端」）。上面各节的语义都适用；下面是它和 Mac 版不同的地方，以及为此加进协议的**可选**字段——Mac 版可以不发，客户端必须接受缺省。

**是谁、是哪种电脑、能做什么**：`/status` 的 `app` 是 `"yoyo-linux"`（Mac 版 `"YoyoControl"`），`api` 同为 1。另有两个可选字段：

```ts
type ScreenPlatform = "mac" | "linux" | "windows"; // 开放集合（"windows"：见「Windows 服务端」）；缺省 / 未知值 = 按 "mac"（Mac 版现在不发）
interface ScreenFeatures {                  // 此刻能做什么；开放集合：读的一方忽略不认识的键，缺省的键按「这个平台平常有」
  clipboard?: boolean;  // 剪贴板接口能用（Linux：X 剪贴板的辅助进程在跑；false 时 /clipboard* 503）
  audio?: boolean;      // /audio 起得来（Linux：PulseAudio 应答且编码器起得来、没关；探测结果成功记 60 s、失败记 10 s）
  cursor?: boolean;     // /stream 认 cursor=client
  focus?: boolean;      // GET /focus 有（Linux：false，没有辅助功能树，/focus 404）
  inputElsewhere?: boolean; // 在看别处来的输入（/events 的 input-elsewhere；Mac：有辅助功能权限时 true；Linux 不发）
  link?: boolean;       // uu Link 的监听在跑（docs/LINK.md；Mac、Linux 都发）
  windows?: boolean;    // GET /windows、GET /hit、/frame?visible= 能用（Linux 0.8.0 起：窗口辅助程序起得来；Mac 不发 = 有）
  automation?: boolean; // POST /automation 有（Linux 0.8.0 起 true；Mac 不发 = 有）
}
interface ScreenStatusExtras { platform?: ScreenPlatform; features?: ScreenFeatures }   // GET /status 的一部分
```

客户端按 `features` 开关对应的按钮（喇叭、剪贴板、打字时的焦点探测）；没有 `features`（旧的 Mac 版）按旧规则：都有；Mac 版的 `features` 只有
`inputElsewhere`，其余的键缺省。值只取布尔，
不是布尔的当缺省。

**输入**：键名另认 **`insert`**（Insert 键；只有 Linux 服务端认，Mac 版回 400 `unknown key insert`）。Linux 上 Shift+Insert 是
终端、GTK、Chromium、文件管理器都认的粘贴键（终端不认 Ctrl+V），客户端在 `platform: "linux"` 时用它当「粘贴」。`cmd` 修饰键在
Linux 上当 Ctrl 发（Linux 程序的快捷键）。不带 `--remote` 时没有控制权的概念（不会 409）；带 `--remote` 时同 Mac 的「控制权」
（`docs/REMOTE.md`）；键盘那条排着的字超过约 60 s 的量时 `key` / `type` 回 429
`still typing the earlier text`，单独一次就超过的 `type` 回 413（分几次发）。

**uu Link**（`--remote` 时，`linux/README.md`「uu Link」）：同 Mac（`docs/LINK.md`），差别是只有 h264；x264 没有长期参考，手机要
恢复帧时回关键帧（最多 500 ms 一个，`recovery_on_nack` 关着）；还没有逐帧跟踪文件。`/status.link` 多一个可选的 `fingerprint`
（签绑定的身份钥匙的指纹）。浏览器经 WebRTC（`docs/LINK.md`「WebRTC」）：`/status.link.rtc = { port, direct? }`、令牌监听上的
`POST /link/rtc`，同 Mac（`docs/LOCAL-API.md`「浏览器的 Link」）。不开 `--remote` 时可以用主人模式（`--link on --link-home`，`docs/LOCAL-API.md`「Link 的主人」）：谁能进、
谁能控制由拿令牌的程序决定。

**剪贴板**：只读 X 的 **CLIPBOARD**（PRIMARY 是鼠标的每一次选中，不算）；写入（`POST /clipboard`）同时拥有 **CLIPBOARD 与
PRIMARY**（同一内容：Ctrl+V / Shift+Insert 和鼠标中键贴出来的一样）。`concealed` 按 `x-kde-passwordManagerHint` 判；复制的程序
退出后剪贴板就空了（X 没有自己的剪贴板）。`changeCount` 每个服务进程从 1 起。语义、限制、错误码同上面「剪贴板」。

**声音**：响应头与分段同上面「声音」；`X-Audio-Video-Offset` 在 Linux 上是常数 **10**（PulseAudio null sink 按读者的 20 ms 延迟
提前渲染，一个块按读回来的时刻标：样本平均比 `X-Audio-Time` 晚约 10 ms 才「放」）。时间线没有空洞：采集没给样本时补静音，相邻两包
`X-Audio-Time` 正好差 20、不回退。`/audio/stats` 的形状不同（`{ enabled, running, clients, starts, failures, packets, fills, lastError }`）。

**指针的 `shapeId`**：规则同上面「视频流、确认与客户端指针」（≥ 1000000、同一个 id 在本进程里总是同一张图、内置箭头 0）。Linux 上
`shapeId` = 每个进程一个随机基数（[2^20, 2^40) 里 2^20 的倍数）+ X 的 cursor serial，所以重起后的进程不会撞上以前的 id，客户端按 id
缓存的图跨重连也不会错；id 最大到约 2^40，客户端按 64 位整数（或 JS 的安全整数）读。动画光标（一秒内超过 10 个新形状）只报位置、
形状停在上一个，静下来 0.5 s 后再报。

**画面**：只有 H.264（`codecs` 列了 hevc 也是 h264），`fps` 至多 30，`maxWidth` 不缩（画面就是屏幕大小），一个显示器（id 1、
`scale: 1`、`phase` 恒为 `ready`），最多 4 条流。`/events` 只有 `state`（一次）、`clipboard`、`abort`、`ping`，带 `--remote` 时还有
`control`。JSON 回答保持连接（keep-alive），流与 `/events` 照旧 `Connection: close`。

**窗口**（0.8.0 起；`linux/README.md`「窗口」）：`GET /windows`、`GET /hit`、`/frame` 的 `visible=` / `hide=` / `crop=` 同 Mac 的形状。
差别：App 的身份是 X 窗口的 **WM_CLASS 的 class**（`bundleId` 与 `name` 都是它，例如 `Xfce4-terminal`、`Thunar`、`firefox-esr`；没有
`englishName`），`visible=` / `hide=` 按它不分大小写匹配（`hide=` 另认内部的空格）；`pid` 是 `_NET_WM_PID`，没有时 0。列表是 X 的叠放次序里看得见的
顶层窗口（含 override-redirect 的菜单、提示），最小化的、别的工作区的不在。`layer` 不是 Mac 的窗口层级数，只取四个值：桌面 −1、普通窗口 0、
面板与置顶窗口 1、菜单 / 提示 / 通知 / override-redirect 2。桌面（xfdesktop）与面板（xfce4-panel）各是自己的 App（Mac 归到 Finder），
`/frame?visible=` 只在 `hide=` 点名时才盖它们。`/hit` 没有 `menuBar`、没有系统浮层的特例。`visible=` 只有盖住这条路（`X-Frame-Filter: mask`，
实心 #3a3a3a，不写 App 名），没有 `native`。`focused` 是 `_NET_ACTIVE_WINDOW` 的主人。

**自动化**（0.8.0 起）：`POST /automation`（`/agent-control`）与 `/status.automation` 同 Mac，但不画边框（无头），也没有旧名
`agentControl`。`esc: true` = 正在用 XInput 2 看这块 X 显示的键盘：不是 XTEST 发的 Esc（不带 Shift / Ctrl / Alt / Super）关掉自动化并在
`/events` 写 `abort`；这个 Esc **不被吞掉**（前面的程序也收到）。本服务的 `/input` 与手机的键走 XTEST，不算。没有 XInput 2 时 `esc: false`。

**没有的接口**（404）：`/console/unlock`、`/console/lock`（Mac 本机 socket 才有，`docs/LOCAL-API.md`「锁屏与解锁」）、`/focus`、`/control`（`--remote` 时配对的手机有）、`/app/windows`、`/app/screenshot`、
`/app/ax`、`/permissions/request`、`/remote*`。

## Windows 服务端

`windows/`（`windows/README.md`）是这套接口在 Windows 上的实现。它和 Linux 服务端是**同一个服务**（`linux/server.mjs`，`linux/platform.mjs`
按所在的系统选辅助程序），所以上面「Linux 服务端」说的差别、可选字段、`features`、控制权、uu Link 都照样适用；只列不同的地方：

- **是谁**：`/status` 的 `app` 是 `"yoyo-windows"`，`platform` 是 **`"windows"`**（`ScreenPlatform` 是开放集合，客户端按「别的电脑」叫它：「桌面」
  「电脑」）；配对时 `welcome.server.platform`、账号声明的 `platform` 也是 `"windows"`。`version` 与 Linux 发布包的相同（同一份代码）。
- **画面**：登录用户的桌面的主显示器（坐标 0,0 的那块），物理像素（按显示器 DPI 感知：150 % 缩放的 2560×1440 就是 2560×1440）。安全桌面
  （UAC 的提示、锁屏、Ctrl+Alt+Del）截不到也操作不了：那时画面停在上一张，`phase` 仍是 `ready`。只有一块显示器。流最多 60 帧每秒
  （Linux 30）：有显卡编码器就由显卡编（H.264 High，BT.709 limited，同样的 Annex-B 访问单元），没有才用 x264；流开着时显示器不睡。
  `GET /frame` 的一张（0.10.2 起）取自 GDI 的合成桌面，不依赖有没有新的一帧呈现：静止的桌面、没开着流时也是当前的画面。
- **输入**：`cmd` 修饰键当 Ctrl 发；键名同 Linux（也认 `insert`）；`type` 的每个字符按 Unicode 直接打（不经键盘布局与输入法），所以中文、
  emoji 都一样快。**粘贴键是 Ctrl+V**（客户端在 `platform: "windows"` 时用它）。输入进不了以管理员身份运行的窗口，除非服务本身也以管理员
  身份运行（安装脚本在管理员安装时这样设）。
- **剪贴板**：Windows 自己的剪贴板（程序退出后内容还在）；文件项的路径是 Windows 路径（`C:\…`），`POST /clipboard` 的 `files` 也收 Windows
  的绝对路径；图片项：复制的是 PNG（"PNG" 格式）就是它，否则把位图编成 PNG。`concealed`：密码管理器按 Windows 剪贴板历史的约定标的
  `ExcludeClipboardContentFromMonitorProcessing`。
- **声音**：默认输出设备的回环（WASAPI loopback），重采样到 48 kHz 立体声；没有声音在放时补静音，换了默认设备（插耳机）就跟着换。
- **窗口**：App 的身份是**程序名**（可执行文件名去掉 `.exe`：`chrome`、`Code`、`explorer`）；`pid` 是窗口所属进程。列表是 Z 序里看得见、
  没被隐藏（别的虚拟桌面、挂起的商店应用）、不是点击穿透（`WS_EX_TRANSPARENT` 的游戏浮层）的顶层窗口，外框按 DWM 的可见边框（不含看不见
  的缩放边）。桌面（`Progman` / `WorkerW`）是 `explorer` 的 `layer −1`，任务栏是 `explorer` 的 `layer 1`，菜单与提示 `layer 2`，置顶窗口 `layer 1`。
  `focused` 是前台窗口的主人。0.10.2 起，指针穿得过去的窗口都不列（不只是带 `WS_EX_TRANSPARENT` 的：还有系统命中测试在它身上哪儿都
  找不到它的分层浮层，例如盖住整屏的 NVIDIA Overlay；`windows/README.md`「辅助程序」）——`/hit` 答的是点击真正落到的窗口。
- **自动化**：Esc 经低级键盘钩子看；本服务（与手机）的输入是注入的（`LLKHF_INJECTED`），不算。
