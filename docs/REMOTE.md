# 远程访问：手机连 Mac

Yoyo Control 的 iOS 客户端连 Mac 上的 Yoyo Control.app。本文是两边的约定；服务端在
`mac/Sources/YoyoServer/Remote*.swift`、`Link*.swift`，菜单在 `mac/Sources/YoyoApp/RemoteMenu.swift`。
接口本身（画面、声音、输入、剪贴板）就是 `mac/README.md`「HTTP API」那一套，这里只写远程多出来的部分。

**只有一条路：uu Link**（`LINK.md`）。局域网、外网（路由器映射的端口、打洞）、直连不上时经 uu 的中继 relay1——都是同一个 Link 会话，
iroh 同时试各条路径、留最好的那条，网络变了自己换；浏览器走 Link 的 WebRTC（`LINK.md`「WebRTC」）。配对也在 Link 上做。
没有 TLS 监听、没有 Bonjour、没有 Cloudflare 的中继（2026-11 退役）。
手机上，Link 的路径不在局域网（中继、公网地址、打洞、Tailscale）要 Yoyo Control Pro（`ios/README.md`「Yoyo Control Pro」）；Mac 这边不管，一视同仁。

## 谁来跑

- 菜单栏 App 的服务（`yoyo-control --socket <home>/screen.sock --exit-on-stdin-eof --remote`）。别的程序自己拉起的服务（`LOCAL-API.md`「自己拉起服务」）
  不带 `--remote`，没有远程访问。
- 状态都在 Yoyo Control 的 home（`~/Library/Application Support/YoyoControl`，0700），只有服务写：
  - `remote.json`：`serverId`（随机，手机记住它来认 Mac）、`enabled`（默认开）、`direct`（外网直连，默认开）、`account: { id, since }`（加入的账号，`ACCOUNT.md`；没有就不写）
  - `devices.json`（0600）：配对的设备，令牌只存 SHA-256；`linkKey` 是它的令牌绑定的客户端 Link 钥匙
  - `tls-key.der`（0600）：身份钥匙（下面「身份」；名字是它还做 TLS 时起的）
  - `link-key`（0600）：Link 的 Ed25519 钥匙（`LINK.md`「服务端：Mac」）
- Link 监听（UDP 47820，浏览器的 WebRTC 在 47821）只在「远程访问开着」且「有配对的设备，或者正在显示配对码」时运行；最后一台设备被移除后
  再留 2 分钟，让它在重连时听到 `unauthorized`（手机据此忘掉这台 Mac），而不是连不上。监听在跑时 Mac 登记在信令服务 signal1（`RELAY.md`）。

## 身份

- EC P-256 钥匙，不进钥匙串。指纹 = `"sha256:" + hex(SHA-256(公钥 X9.63 字节 04‖X‖Y))`，手机和浏览器配对时记住它（钉住）。
- 它签 Link 的绑定（`LINK.md`「身份与信任」：Link 钥匙由身份钥匙签名，手机拨号前核对）、WebRTC 的 answer、在信令服务上的登记。
  中继、信令服务或别人冒充不了 Mac：换掉绑定、answer 都会被发现。钥匙丢了才会换指纹（手机得重新配对）。
- iOS 的 ATS 照常开着：App 唯一的 HTTPS 是 signal1（正规证书）；Link 是 UDP。

## 配对

1. Mac 菜单「配对 iPhone…」：服务生成一次性配对码（128 bit，5 分钟有效，用一次；连续 10 次错码作废），窗口显示二维码。
   窗口不进任何截图（`sharingType = .none`），正在看这台 Mac 的手机或 agent 拿不到码。关窗即作废。
2. 二维码内容（Link 监听起来之后才有）：

   ```
   yoyocontrol://pair?v=2&id=<serverId>&n=<Mac 名>&fp=<指纹>&l=<Link id>&lk=<身份公钥>&ls=<签名>[&lp=<UDP 端口>][&a=<IPv4,…>]&c=<配对码>
   ```

   `l` 十六进制，`lk` / `ls` 是 base64url 不带补齐；`a`：Mac 的局域网地址（拨号的提示，绑定里还有它自己的地址）。二维码用 L 级纠错（在屏幕上，
   不怕脏）。iOS 相机扫到会打开 Yoyo Control App（注册 `yoyocontrol` scheme）。`v=1`（TLS 时代的码）不再认。
3. 手机用 `fp` 核对绑定，拨 Link（经 relay1，局域网地址同时试），`hello.credential = "Pair <配对码>"`、`hello.device = { id, name }`：
   - `device.id`：手机自己的稳定 id，8–64 个 `A–Z a–z 0–9 _ -`（UUID 即可）；同一个 id 再配对会替换旧令牌。
   - `name` 会去掉换行、截到 64 字符，空的记作 "iPhone"。
   - 成功：`welcome.principal = { device, token, server: { id, name } }`（`LINK.md`「配对」），令牌随即绑定这把客户端钥匙，会话接着就是这台设备的。
   - 拒绝：码不对 / 过期 / 没在显示、`device.id` 不对 → `denied unauthorized`；配对设备已满（32）→ `busy`。失败照样记进 Link 的守卫。
4. 之后每次 `hello.credential = "Bearer <token>"`。令牌存进钥匙串。不认识的令牌、或者别的 Link 钥匙带来的 → `unauthorized`。

账号里的另一台 iPhone 也能用同样的 `Pair <code>` 配对，码由一台已配对的 iPhone 替它向电脑要（定向码：只认那台 iPhone 的 id 和 Link 钥匙，
`ACCOUNT.md`「批准」）。

**浏览器配对**（uu 的网页 `https://yoyocontrol.com/app/`）：配对窗口另给一个网页链接（第二个二维码 + 拷贝）：

```
https://yoyocontrol.com/app/pair#v=1&id=<serverId>&n=<Mac 名>&fp=<指纹>&c=<配对码>
```

参数都在 `#` 后面（片段不发给任何服务器，网页也不把它发出去）。`GET /remote` 的 `pairing.webUrl` 就是它，只在浏览器进得来时有：
Link 收 WebRTC（`link.rtc`）而且 Mac 登记着信令服务（浏览器的 offer 经它来）。`YOYO_WEBAPP_URL` 换网页的地址（试本地构建用）。
网页经 signal1 拨 Link 的 WebRTC（`LINK.md`「WebRTC」，钉 `fp`），同样 `hello.credential = "Pair <配对码>"`，令牌绑到这个浏览器的 DTLS 证书。

Mac 菜单里「已配对的设备」可以逐个移除：令牌立刻失效，**这台设备正开着的会话（包括视频流）立刻被断开**。
「允许远程访问」关掉：停止监听、断开所有会话、放开控制权。

## 远程能用的接口

经 Link 的 RPC（`LINK.md`「RPC 流」）：`GET /status`、`GET /frame`、`GET /stream`、`POST /stream/ack`、`GET /events`、`GET /focus`、`GET /audio`、
`POST /input`、`POST /control`、`GET /clipboard`、`POST /clipboard`（只收 `text`；`files` 是 Mac 上的路径，远程不收）、
`GET /clipboard/image`、`GET /clipboard/file`。其它（`/windows`、`/hit`、`/app/*`、`/agent-control`、`/maps/*`、
`/permissions/request`、`/remote*`）对远程一律 404。画面、声音、指针、输入走 Link 自己的通道（`video.open`、`audio.open`、`send_input`）。

## 控制权

- 状态：`none`，或者 `remote`（某台配对的手机）。`GET /status` 的 `control`：
  `{ controller: "none" }` / `{ controller: "remote", since, device: { id, name } }`；每次变化 `/events` 推一行
  `{"type":"control","control":{…}}`，每个会话收到 `control` 消息。
- 手机先拿控制权（`control.take`，等同 `POST /control { controller: "user" }`；总是成功，最后拿的那台持有；换手时按住的鼠标键会被抬起），
  才能输入；没拿到 → `input.rejected`（`POST /input` 是 409 `take control of the screen first`），别人拿着 → 409
  `{ code: "controlled-elsewhere", controllerDevice }`。`control.release` / `{ controller: "none" }` 只放开自己的。
- 客户端打开屏幕页时只看，用户第一次真正输入（触控板的第一下、按键、粘贴到电脑…）才 `control.take`（`PROTOCOL.md`「输入」的
  「客户端什么时候拿控制权」）：只是打开看看不会打断本机的自动化。不在控制时页面顶上有明确的「开始控制」/「接管」按钮
  （另一部手机拿着时只有这个按钮会拿）。
- 10 分钟没有输入自动放开；设备被移除、Mac 菜单「收回控制权」、关掉远程访问也会放开。
- 本机 socket 的使用方（`LOCAL-API.md`；它们转来的手机输入、自动化都从这里来）不是控制者：没有手机拿着控制权时照常输入；有手机拿着时
  `/input` 回 409 `controlled-elsewhere`（见 `LOCAL-API.md`「兼容承诺」）。
- Mac 端能看见：有手机连着时菜单栏图标变成 iPhone，菜单写「X 正在控制这台 Mac」并提供「收回控制权」。

## 外网直连

不经中继，在 5G 下也直连 Mac：服务请家里的路由器把 Link 的 UDP 端口（和 WebRTC 的）转过来，把「公网地址:端口」放进 Link 的绑定（`direct`）。

- 谁来做：Link 监听在跑且 `remote.json` 的 `direct` 开着（默认开）时，`PortMapper`（`mac/Sources/YoyoServer/PortMap*.swift`）依次试
  PCP（RFC 6887）、NAT-PMP（RFC 6886）、UPnP IGD（SSDP 找 `WANIPConnection` / `WANPPPConnection`，SOAP `AddPortMapping`），
  先映射成功的那个算数。外网端口先要同号，被占（`GetSpecificPortMappingEntry`）或路由器拒绝（718 / 729 / 501）就换端口再试，最多 6 个。
  日志 `link: port mapping …`、`link rtc: port mapping …`。
- 租约：要 1 小时，到一半时续；只支持永久映射的路由器（725）用 0，每 20 分钟重加一次。网络变化（`NWPathMonitor`）后 2 s 重新映射。
  关掉开关、监听停了、服务退出（SIGTERM / stdin 关闭：先删映射，最多等 2 s）都会删掉映射；崩溃留下的映射最多活到租约结束。
- 不可直连：路由器报的外网地址是私有地址（前面还有一层路由器）、CGNAT（100.64/10）或 0.0.0.0 时，状态是 `unreachable`，映射立即删掉。
  什么都没应答是 `unsupported`（5 分钟后再试），路由器拒绝是 `failed`（1 分钟起翻倍，最多 30 分钟）。映射不了也没关系：打洞、中继照旧。
- 安全：映射后 Link 端口对整个互联网可见。靠的是 Link 的握手（绑定由身份钥匙签名）+ 令牌绑定客户端钥匙，加上核心的守卫（60 s 内 10 次失败
  冷却 5 分钟，32 个会话，4 个没认证的）。
- 菜单：「允许从外网直连」开关，下面一行状态：可用（地址）/ 正在询问路由器 / 路由器不支持 / 不可用（前面还有一层 NAT）/ 路由器拒绝了 / 关。
- 测试：`YOYO_PORTMAP=off` 让服务不碰路由器；`YOYO_PORTMAP_REAL=1 swift test --filter PortMapTests/testRealRouter` 对本机路由器做一次真实映射
  （测试端口 47998，查到后删掉）。Node 端同样的逻辑在 `packages/portmap`（`@yoyocontrol/portmap`）。

## Linux 服务端

`linux/server.mjs --remote <home>`（`linux/README.md`「远程访问」）给手机的是同一套：同样的身份钥匙（文件格式和指纹都一样）、Link 上的配对
（同一种链接，命令行 `pair` 打出来、带终端二维码——有 qrencode 时用它的，否则用自带的 `qr.mjs`；`--page` 另在浏览器里打开一页二维码，没有菜单）、令牌、「远程能用的接口」（`/focus` 照旧 404）、控制权、
外网直连、信令服务。实现在 `linux/remote.mjs` / `link.mjs`，建在 `@yoyocontrol/remote`（`packages/remote`：身份、配对、信令客户端、端口映射）上。
差别：

- 没有菜单。`welcome.server` 多 `platform: "linux"`，`/status` 也说 `platform: "linux"`：iPhone 的列表按它显示平台。
- 管理接口在 `<home>/admin.sock`（0600）上（同下表，没有 `/remote/enabled`：开关就是 `--remote`），命令行 `pair` / `devices` / `remove` /
  `disconnect` / `status` 经它说话。令牌监听（`--token-file`）的客户端就是这里的「本机 socket 的使用方」：手机拿着控制权时它们的 `/input` 409。
- 浏览器的 offer 只经令牌监听的 `POST /link/rtc`（宿主转），还没有经信令服务的。
- Windows（`windows/`，同一个服务）：`platform: "windows"`；管理接口是命名管道 `\\.\pipe\yoyo-remote-<状态目录的哈希>`（Windows 没有 socket 文件）；
  配对在托盘图标的 Pair iPhone…（浏览器里的二维码）或 `yoyo pair`（终端二维码，自带编码器）；端口映射的网关从 `route print` 读。
- 在容器里（`linux/demo`）：`--advertise` 给出宿主的地址和发布的端口；路由器的 SSDP 回答从别的端口回来、过不了容器的 NAT，所以
  `--direct-upnp` 直接给 UPnP 描述地址，`--direct-client` 让映射指向宿主的地址和端口；发布的端口上所有客户端都从网桥的地址来，
  `--exempt` 让守卫不按来源冷却（否则一个乱试的人会让所有手机一起被冷却）。

## 本机管理接口（只在 unix socket 上，只在 `--remote` 的服务里；菜单栏 App 用）

| 接口 | 作用 |
| --- | --- |
| `GET /remote` | `{ enabled, listening, serverId, name, addresses, fingerprint, devices: [{ id, name, pairedAt, lastSeenAt?, connected }], pairing: { code, expiresAt, url?, webUrl? } \| null, control, signal: { connected }, direct: { enabled, status, address?, port?, method? }, link, error? }`（`direct.status`：`off` / `probing` / `mapped` / `unreachable` / `unsupported` / `failed`，见「外网直连」；`pairing.url` 在 Link 监听起来后才有） |
| `POST /remote/pairing` | 生成新的配对码（远程访问关着就先打开），回答同 `GET /remote` |
| `POST /remote/pairing/stop` | 作废配对码 |
| `POST /remote/enabled { enabled }` | 开 / 关远程访问 |
| `POST /remote/direct { enabled }` | 开 / 关外网直连（关掉即删映射），回答同 `GET /remote` |
| `POST /remote/devices/remove { id }` | 移除设备（404：没这台） |
| `POST /remote/disconnect` | 放开控制权（设备仍然配对） |
| `POST /remote/account/leave` | 退出账号（`ACCOUNT.md`；配对不受影响），回答同 `GET /remote` |

`GET /remote` 还有 `account: { id, since } | null`。已配对的手机经 Link 另有三个账号路由：`GET /account`、`POST /account/join`、
`POST /account/invite`（`ACCOUNT.md`「电脑加入账号」「批准」）。

没带 `--remote` 的服务对这些都回 404。
