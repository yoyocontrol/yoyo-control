# 安全桌面的代理（Windows：yoyo-broker）

Windows 把 UAC 的提示、登录 / 锁屏界面、Ctrl+Alt+Del 放在另一个桌面上（`winsta0\Winlogon`，「安全桌面」）：只有 SYSTEM 能截它、往它上面
输入；用户自己的程序（yoyo-windows 的辅助程序也是）连管理员身份都不行。Mac 上靠用户给 App 的「屏幕录制」「辅助功能」两项授权就能看、能点
锁屏；Windows 没有这种授权，这个代理就是它的那份授权。

yoyo-broker 是一个 LocalSystem 服务（`YoyoBroker`，自动启动，崩了由服务管理器拉起），**只做一件事**：在控制台用户的会话里以 SYSTEM 身份
起视频辅助程序（`yoyo-winvideo.exe`：流、`/frame` 的一张）和输入辅助程序（`yoyo-wininput.exe`），把它们的 stdin / stdout / stderr / 退出码
经命名管道转给那个用户自己的 yoyo-windows。剪贴板、声音、窗口列表、Esc 监听仍是用户自己的进程。辅助程序自己跟着「输入桌面」走
（`OpenInputDesktop` + `SetThreadDesktop`，`windows/common.h` `follow_input_desktop`）：UAC 的提示一来，画面接着就是它，点击也落在它上面；
没有切换流、没有关键帧空档。

没有代理（没装、这个用户没被授权、不在控制台）时什么都不变：辅助程序以用户身份运行，安全桌面只被**报告**（`console.secureDesktop`，
`docs/PROTOCOL.md`「Windows 服务端」），画面停在上一张。

## 边界

- **谁能用**：一个连接只有同时满足这三条才被接受（`windows/broker.c` `check_client`，按管道客户端的令牌判断，不按进程号）：
  它的会话不是 0 且就是当前的控制台会话（否则 `not-console`）；它的用户就是那个会话登录的用户（`not-user`）；这个用户的 SID 在
  `users.txt` 里（`not-allowed`）。`users.txt` 只有提升过的 `install --user <SID>` 写得进去：那就是授权。
- **边界是 Windows 账号，不是哪个程序**：被授权的账号里的任何程序都能经它看安全桌面、点 UAC 的「是」——对这个账号来说 UAC 不再是一道
  关卡（和 Mac 上任何本用户进程都能找 Nest.app 一样）。不授权的账号（家里别人的账号）什么都拿不到。
- **跑什么**：只有那两个辅助程序，只从它自己的文件夹（`%ProgramFiles%\YoyoBroker\versions\<版本>\`，继承 Program Files 的权限：只有管理员
  和 SYSTEM 写得进）。请求里永远没有路径、程序名、环境变量；参数按固定的语法重建（`video_args`：`--fps 1…240`、`--cursor client`、
  `--encoder gpu|x264`、`--preset <x264 的名字>`、`--threads 1…64`、`--jpeg 10…95`、`--size`、`--crop`、至多 64 个 `--box`，整数 0…65535；
  没有 `--bench`），不合语法就是 `bad-request`。
- **令牌**：服务自己的令牌复制一份，会话改成客户端的，再用 `DISABLE_MAX_PRIVILEGE` 去掉除 `SeChangeNotify` 以外的全部特权；只继承三个管道端
  （`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`）；每个连接一个 job（`KILL_ON_JOB_CLOSE`）：连接断了，辅助程序就结束。控制台换了会话（快速切换
  用户、断开）时，别的会话的辅助程序全部结束。每个会话至多 8 个视频、4 个输入辅助程序（`busy`）。
- **辅助程序的 stdin 是一道边界**：`yoyo-wininput` 的次数、等待都有上限，`yoyo-winvideo` 的 `E` / `T` 参数夹在范围内。

## 管道

`\\.\pipe\yoyo-broker`（`FILE_FLAG_FIRST_PIPE_INSTANCE`、`PIPE_REJECT_REMOTE_CLIENTS`；SDDL `D:(D;;GA;;;NU)(A;;GA;;;SY)(A;;GRGW;;;IU)`：
网络登录拒绝，交互用户可读写）。一个连接一个请求：

```
yoyo-broker/1 <版本> status | video <参数…> | input | install <文件夹>\n      ← 一行，至多 512 字节；<版本> 是 [a-z0-9.-]{1,16}
```

回来的是帧：`u8 种类, u32 BE 长度, 内容`。0 = 回答（`ok …` 或 `err <原因>`），1 = 辅助程序的 stdout，2 = 它的 stderr，3 = 它退出了
（`u32 BE` 退出码）。`ok` 之后客户端写进来的字节就是辅助程序的 stdin。原因（开放集合）：`not-console`、`not-user`、`not-allowed`、
`no-version`、`floor`、`busy`、`bad-request`、`signature`、`failed`；客户端自己加 `not-installed`（管道不存在）。

`status` 回 `ok broker <代理的版本> floor <下限> installed yes|no`（`<版本>` 装了没有）。

## 签名与更新（不用提升）

发布包（`windows/build.sh`，设了 `YOYO_BROKER_SIGN_KEY` 时）多一个 `broker\`：`yoyo-broker.exe`、`yoyo-winvideo.exe`、`yoyo-wininput.exe`，
以及 `windows/sign-broker.mjs` 写的：

```
manifest.txt   yoyo-broker-manifest 1
               version 0.12.0
               floor 0.12.0                       ← windows/broker-floor：有安全修复时才提高
               <sha256> <大小> yoyo-broker.exe     ← 只认这三个名字，各一行
               …
manifest.sig   manifest.txt 字节的 ECDSA P-256 / SHA-256 签名（r‖s，64 字节）
trust.txt      yoyo-broker-key 1\n<公钥 X‖Y 的 base64>
```

用户自己的 yoyo-windows 发现代理里没有自己的版本（`installed no`）时，发 `install <它包里的 broker 文件夹>`。代理**以客户端的身份**读那个
文件夹（读得到的就是客户端读得到的），用已装的 `trust.txt` 验签名，大小和 sha256 在内存里的字节上核对，写进它自己新建的
`staging-…` 再改名成 `versions\<版本>`（核对的就是写下的：没有检查后被换掉的空当）。低于 `floor.txt` 的版本既不装也不运行（`floor`：
旧的、有漏洞的签名版本不能拿来重放）；保留最新的三个版本。清单里的 `yoyo-broker.exe` 和正在运行的不同时，把自己换掉并退出，由服务管理器
按恢复动作重新拉起（回 `ok <版本> restart`，客户端 2 s 后再问）。

签名用的私钥不在仓库里（发布的人自己保管，丢了就只能在每台电脑上提升重装）；别人自己构建，就带着他自己的钥匙。没有钥匙的构建不带
`broker\`：这个功能就不存在（`not-installed`）。

## 安装、卸载

```
yoyo-broker.exe install --user <SID>       提升后运行（ssh 的会话 0 也行）：用包里自己的 trust.txt 验包，复制到 Program Files，写 trust.txt，
                                            把 SID 加进 users.txt，建（或更新）并启动服务。再跑一次 = 加一个用户或更新
yoyo-broker.exe uninstall [--user <SID>]   提升后运行：去掉这个 SID；没人了（或没给 --user）就删掉服务和文件夹
```

`windows/install.ps1` 以管理员运行时替装它的用户装上；`uninstall.ps1` 去掉当前用户。日志在 `%ProgramFiles%\YoyoBroker\broker.log`（1 MB 轮换）。

## 服务端（`linux/broker.mjs`）

只在 Windows 平台：启动时问一次（`status`，没有自己的版本就 `install`）；准备好了，视频辅助程序（流、尺寸探测、`/frame`）和输入辅助程序
就经它起（`BrokerChild` 和 `ChildProcess` 一个样子），否则照旧在本地起，并且至多每 10 s 再问一次。被拒绝（`err …`）的那一个辅助程序失败，
之后的回到本地，直到它再答应。代理变成可用 / 不可用时，正在跑的输入辅助程序结束，下一次输入按新的方式起。`/status`：
`features.secureDesktop`（准备好了为 true）和 `secureDesktopHelper: { ok, version? , reason? }`。安全桌面显示着时，`/windows`、`/hit` 是空的，
`/frame?visible=` 整张遮住（窗口列表属于另一个桌面）。`YOYO_BROKER=off` 不用它，`YOYO_BROKER_PIPE` 换管道（测试）。

## 还没有

- 在登录界面自动输入密码解锁（Mac 的 `/console/unlock` 那样）：下一轮。现在登录界面能看、能点、能打字（手机上自己输 PIN）。
- Ctrl+Alt+Del（`SendSAS`）：家用 Windows 的锁屏用不着，需要机器策略，不做。
- 代码签名证书（Authenticode）：不需要；只有 Defender / SmartScreen 拦的时候才考虑（要花钱）。
