# 中继与信令：uu 自己的 VPS（relay1）

手机、浏览器和电脑之间只有 uu Link（`LINK.md`、`REMOTE.md`）。能直连就直连（局域网、路由器映射的端口、打洞）；直连不上时经 uu 自己的
一台 VPS 转发。上面跑三样东西，都只见密文：

| 服务 | 地址 | 给谁 | 做什么 |
| --- | --- | --- | --- |
| iroh-relay | `relay1.yoyocontrol.com`（HTTPS 443、UDP 7842） | 手机 App、Mac、Linux 的 Link 端点 | Link 直连不上时转发 QUIC；打洞的信令；公网地址探测（`LINK.md`「端点、地址、路径」） |
| coturn | `relay1.yoyocontrol.com:3478`（UDP / TCP），转发端口 UDP 49152–49407 | 浏览器的 WebRTC | STUN；直连不上时 TURN 转发（下面「TURN」） |
| 信令服务 | `signal1.yoyocontrol.com`（HTTPS 443） | Mac / Linux 登记；浏览器、手机来问 | Mac 的房间：浏览器的 offer / answer、TURN 凭据、Link 绑定（下面「协议」）；账号服务（`ACCOUNT.md`） |

代码：`relay/iroh/`（部署、配置）、`relay/signal/`（信令服务，Node），Mac 端 `mac/Sources/YoyoServer/RemoteSignal.swift`，Linux 端
`@yoyocontrol/remote` 的 `SignalClient`，浏览器 `@yoyocontrol/direct-web`，手机 `ios/YoyoKit/Sources/YoyoDirect/SignalLookup.swift`。
机器、部署、监控见 `relay/iroh/README.md`。

经中继（Link 的 relay 路径、浏览器的 TURN）的连接不在局域网，要 Yoyo Control Pro（`ios/README.md`）。

2026-11 之前还有一个 Cloudflare Worker + Durable Object 的中继 `relay.yoyocontrol.com`，转发 TLS 连接的字节，兼做信令；Durable Object 一天被
重启十来次，挂在上面的连接全断。它连同 TLS 监听一起退役了。

## 协议（v1，信令服务）

Mac 的控制连接是 `wss://signal1.yoyocontrol.com/v1/mac/<fp>` 上的 WebSocket，其余是普通 HTTPS。`<fp>` 是 Mac 身份钥匙的指纹
（`REMOTE.md`「身份」）去掉 `sha256:`，64 位小写十六进制；不是这个样子：404。每台 Mac 一个房间，名字就是它。

### Mac 登记：`/v1/mac/<fp>`

1. 服务先发 `{"type":"challenge","nonce":"<base64，32 字节随机>"}`。
2. Mac 回 `{"type":"hello","v":1,"key":"<base64，公钥 X9.63 65 字节>","sig":"<base64，64 字节 r‖s>"}`：
   用身份钥匙对 UTF-8 的 `"yoyocontrol-relay-v1:" + nonce`（nonce 原样的 base64 字符串）做 ECDSA P-256 / SHA-256 签名。
3. 服务核对 SHA-256(key) 等于 `<fp>`、签名对，然后回 `{"type":"ready"}`；不对就用 4001 关掉。10 s 内没有 hello 也关掉。
   同一个房间新登记的 Mac 顶掉旧的（旧的被 4002 关掉）：同一把钥匙只有一台 Mac。
4. 之后 Mac 每 30 s 发文本 `ping`，服务回 `pong`；45 s 没收到 `pong` 就算断了，重连（1 s 起翻倍，最多 60 s）。
   服务 100 s 没收到 Mac 任何消息就断开；重启时用 1012 关掉所有 Mac，它们 1 s 后重新登记。
5. Mac 在 `ready` 之后和变化时发 `{"type":"link","id","key","sig","relays","direct"}`（`LINK.md`「身份与信任」），服务记在这条连接上；
   还发 `{"type":"account","id":<账号 id | null>}`，服务对照账号目录回 `{"type":"account","state":"linked"|"unlinked"}`，目录里删了这台时也主动发
   `unlinked`（`ACCOUNT.md`）。旧版本不发，服务也不管。
   （旧版本还发 `{"type":"candidates",…}`：TLS 监听的公网候选，服务照收，没人再用。）
6. 浏览器的 offer 来时，服务发 `{"type":"rtc",…}`（下面「WebRTC」）。

日志不记 IP；同一 IP 同时未登录的连接最多 16 条。`/healthz` 回 `{ ok, macs, uptime }`；`/metrics`（Prometheus 文本，只给本机）。
客户端地址：服务只信本机代理给的 `X-Forwarded-For`。

### Link 绑定：`GET /v1/candidates/<fp>`

- `200 { candidates: [], link?: { id, key, sig, relays, direct } }`（`Cache-Control: no-store`）；房间里没有登记好的 Mac → 503
  `{"error":"mac offline"}`；别的方法 405。
- `link` 是登记好的 Mac 最近一次发的，只留格式对的：`id` 64 位十六进制，`key` 是 65 字节的 P-256 公钥且 SHA-256 等于 `<fp>`（只能是这个房间的
  钥匙），`sig` 64 字节，`relays` 只留 `https://` 的、最多 2 个，`direct` 只留 `ip:port` / `[ipv6]:port`、最多 8 个；格式不对的消息清掉已有的。
  签名由手机 / 浏览器核对，服务不验。
- 谁问：手机的记录里没有绑定时（配对码从来带着它，旧记录才缺），浏览器拨号前。

### WebRTC：`POST /v1/rtc/<fp>`

浏览器的 Link（`LINK.md`「WebRTC」）：它把 WebRTC 的 offer 经信令服务交给 Mac，拿回 answer，之后自己用 WebRTC 连 Mac（直连、打洞、TURN）。

- 请求体 = offer JSON（≤ 64 KiB）。服务在 Mac 的控制连接上发 `{"type":"rtc","id":"<32 位十六进制>","offer":{…},"from":"<浏览器的 IP>"}`；
  Mac 回 `{"type":"rtc-answer","id","answer":{…}}` 或 `{"type":"rtc-error","id","status","message"}`，服务把 `answer` 作为 200 的回答体
  （或 `status` + `{ error: message }`）交回去。
- 服务自己的回答：503 房间里没有 Mac（Mac 离开时等着的 offer 马上 503）；504 Mac 10 s 没答；400 请求体不是 JSON 对象；413 太大；405 不是 POST；
  429 同一个 IP 对同一个房间 10 s 内超过 10 个 offer，或房间里同时等着的超过 16 个。`Cache-Control: no-store`。
- CORS：`Access-Control-Allow-Origin: *`（预检 `OPTIONS` 回 204）。answer 由 Mac 的身份钥匙签名（浏览器按钉住的指纹核对），会话还要 `hello`
  里的凭据，所以不限来源。
- Mac 收到的 `from` 进 Link 的守卫：同一来源失败多了会被冷却，冷却中的来源 Mac 回 `rtc-error` 429。

### TURN：`POST /v1/turn/<fp>`

浏览器拨 Mac 之前先问一次（`@yoyocontrol/direct-web` 的 `relayTurn`），拿到 relay1 上 coturn（`relay/iroh/turnserver.conf`）的短期凭据，
放进 WebRTC 的 `iceServers`：浏览器和 Mac 直连不上时（只有 IPv6 的 5G 对只有 IPv4 的家、对称 NAT），浏览器经 TURN 转发；里面的 DTLS 照旧在
浏览器和 Mac 之间端到端。Mac 不用改：它是完整的 ICE，会自己往浏览器的 relay 候选发检查。

- 回答 `{ iceServers: [{ urls, username, credential }], ttl }`：`urls` 是 `stun:` / `turn:…?transport=udp` / `turn:…?transport=tcp`
  （relay1.yoyocontrol.com:3478），凭据是 coturn 的 TURN REST 式（`use-auth-secret`）：`username = <过期的 unix 秒>:<fp 前 16 位>`，
  `credential = base64(HMAC-SHA1(TURN_SECRET, username))`，`ttl` 12 h（coturn 每次续期都核对，所以一条会话在 TURN 上最多走 12 h，之后浏览器重拨）。
  浏览器留着它，直到过期前 1 h。
- `TURN_SECRET`：Mac 钥匙串 `yoyocontrol-turn-secret`，`relay/iroh/deploy.sh` 写到 VPS 的 `.env`，coturn 和信令服务读同一个。没设：404。
- coturn 只转到公网地址（私网、回环、CGNAT 段都拒），每个凭据最多 8 个分配，总共 256 个。

## 部署

relay1 上：HAProxy 拿着 443，只看 TLS 的 SNI、不解密：`relay1` 原样交给 iroh-relay（127.0.0.1:4443，证书自己签），`signal1` 交给 Caddy
（Let's Encrypt 走 TLS-ALPN-01，经 PROXY 协议知道客户端地址），再到本机 8790 的信令服务。没选 8443 之类的端口：有的网络只放行 443。

```sh
cd relay/iroh && ./deploy.sh       # 配置、TURN 密钥、中继令牌，构建并重启容器（relay/iroh/README.md）
cd relay/signal && npm test        # 信令服务的测试
```

## 安全

- 内容：Link 的 QUIC（TLS 1.3，原始公钥）在手机和电脑之间端到端，WebRTC 的 DTLS 在浏览器和电脑之间端到端；iroh-relay、coturn 只见密文。
  手机 / 浏览器核对的是电脑的身份钥匙（绑定、answer 都由它签名），中继、信令服务或别人冒充不了它。
- 登记：只有握着私钥的电脑能登记进自己的房间。
- 知道某台电脑指纹的人可以问到它的绑定（里面有它的公网地址和外网端口）、经中继拨它，但到了电脑还要令牌（Link 的守卫：没认证的会话最多 4 个，
  失败多了按来源冷却），跟直连时一样。不想暴露公网端口就关掉 Mac 菜单的「允许从外网直连」。
- iroh-relay 只放行带 relay1 令牌的客户端（`relay/iroh/README.md`「令牌」）：挡的是别人顺手白用，不是安全边界。
- 服务看得到的：两端的 IP 地址、连接时间、流量大小，WebRTC 的 SDP（里面有双方的 IP 地址、端口和 DTLS 证书指纹）（隐私政策里写明）；不留日志。
