# yoyo-windows：Yoyo Control 的 Windows 版

在 iPhone 上看、操作一台 Windows 电脑：画面（H.264）、声音（Opus）、点击 / 打字 / 滚动、剪贴板，以及自动化程序要的窗口列表、命中测试、
只露某些 App 的单帧。手机经 uu Link 连（局域网直连、路由器的端口映射、中继），配对、控制权、账号都和 Mac 一样。

它和 Linux 服务端是**同一个服务**：`linux/` 里的 `server.mjs` 等 `.mjs` 一字不差地在 Windows 上跑，`linux/platform.mjs` 按系统选辅助程序。
这里是 Windows 自己的部分：五个辅助程序（C，说和 Linux 辅助程序一样的记录格式）、托盘程序、安装脚本和发布。协议上和别的平台的差别写在
`docs/PROTOCOL.md`「Windows 服务端」。

| 文件 | 内容 |
| --- | --- |
| `winvideo.c` | `yoyo-winvideo.exe`：DXGI 桌面复制（Desktop Duplication）看主显示器的变化与指针，收到命令才取最新的一张、画上指针、编一帧（BT.709 limited）——`linux/x11video.c` 的同一套参数、命令与记录；有显卡编码器就用它（`winhw.h`），没有才读回 CPU 用 x264；`--cursor client` 时指针走 `'P'` 记录；`--jpeg`：`/frame` 的一张（盖住、切、缩放，WIC 编 JPEG）；`--bench`：不要桌面的编码测速 |
| `winhw.h` | `yoyo-winvideo.exe` 的显卡那条路：画面不离开显卡——显卡的视频处理器 BGRA → NV12，显卡自己的 H.264 编码器（NVENC / AMF / Quick Sync，经 Media Foundation 的硬件编码器，各家同一套代码）出一帧 |
| `wininput.c` | `yoyo-wininput.exe`：读 `linux/input.mjs` 写给 xdotool 的那些行（`mousemove`、`click`、`key`、`keydown`…），用 SendInput 放出来；`U<hex>` 的字符按 Unicode 直接打 |
| `winwindows.c` | `yoyo-winwindows.exe`：一次性列出顶层窗口（同 `x11windows.c` 的 JSON：程序名、窗口类、pid、类型、外框）；`--esc`：低级键盘钩子，用户按的 Esc 报一行 |
| `winclip.c` | `yoyo-winclip.exe`：剪贴板（格式监听，60 ms 去抖）：文件（CF_HDROP → file: URI）、PNG（"PNG" 或位图经 WIC 编）、文字（CF_UNICODETEXT）；写入文字、文件（+ 一张图） |
| `winaudio.c` | `yoyo-winaudio.exe`：默认输出设备的 WASAPI 回环，重采样到 48 kHz 立体声，libopus 20 ms 一包（同 `pa-opus.c` 的记录） |
| `common.h` | 辅助程序共用：墙钟、记录、stdin 的读线程、DPI 感知 |
| `launcher.c` | `yoyo-control.exe`：登录用户的托盘程序（通知区域的图标：Pair iPhone… / Open Log / Quit），隐藏地跑并看着服务（`node server.mjs`），日志 `<home>\yoyo-control.log` |
| `install.ps1` / `uninstall.ps1` | 安装：程序目录、登录时启动的计划任务、uu Link 的防火墙规则（管理员时）；卸载 |
| `yoyo.cmd` | `yoyo pair` / `devices` / `remove <id>` / `disconnect` / `status` / `account`：和跑着的服务说话（经命名管道） |
| `build.sh` | 发布包（在 Mac / Linux 上用 mingw-w64 交叉编译） |

## 要求

- **Windows 10 1809 或更新、64 位（x64）**。发布包自带 `node.exe`（Node.js 24），不用另装。
- 服务跑在**登录用户的会话**里（看得见桌面的那个）。Windows 服务（会话 0）没有桌面：在那里起，画面是 `ok: false`。
- 声音要有一个输出设备（扬声器、耳机、显示器的 HDMI 声音都行）。

## 安装

解开 `yoyo-windows-<版本>-windows-x64.zip`，在那个文件夹里：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1           # 给自己装：%LOCALAPPDATA%\Programs\YoyoControl，登录时启动
```

然后点通知区域的 Yoyo Control 图标 → **Pair iPhone…**：浏览器里出一个二维码，用 iPhone 的相机扫（或在命令行 `yoyo pair`，终端里也有码）。

- 以**管理员**运行时，另加防火墙规则「Yoyo Control (uu Link)」（`node.exe` 的入站 UDP：同一网络里的 iPhone 直连），计划任务以最高权限运行
  （输入也能进以管理员身份运行的窗口）。不是管理员时，Windows 第一次会问 `node.exe` 能不能用网络：允许专用网络即可。
- 给另一个用户装（要管理员）：`install.ps1 -User <名字> -StateDir C:\ProgramData\YoyoControl`：程序进 `%ProgramFiles%\Yoyo Control`，那个用户
  一登录就在他的会话里跑（计划任务的 Interactive 登录，不要密码）。
- `-LocalPort 7380`：另在 `127.0.0.1:7380` 给本机程序用 HTTP API（`docs/LOCAL-API.md`），令牌写在 `<StateDir>\token`（只有那个用户、SYSTEM、
  管理员能读）。
- 再运行一次 = 更新（先停掉在跑的）。`uninstall.ps1` 卸载（`-State` 连配对和钥匙一起删）。

状态目录（缺省 `%LOCALAPPDATA%\YoyoControl`，或 `-StateDir`）里是远程访问的那些文件（`linux/README.md`「远程访问」：`remote.json`、身份钥匙、
`link-key`、`devices.json`）、日志、令牌。管理的「socket」在 Windows 上是命名管道 `\\.\pipe\yoyo-remote-<状态目录的哈希>`。

## 运行（不用安装脚本）

```powershell
.\yoyo-control.exe                                   # 托盘 + 服务，状态在 %LOCALAPPDATA%\YoyoControl
.\yoyo-control.exe --no-tray --remote D:\yoyo        # 没有托盘图标
.\node.exe server.mjs --host 127.0.0.1 --port 7380 --token-file token.txt   # 只要本机的 HTTP API（同 Linux 的参数）
```

`server.mjs` 的参数、环境变量、HTTP API 都同 `linux/README.md`；辅助程序的路径另可用 `YOYO_VIDEO_HELPER` / `YOYO_AUDIO_HELPER` /
`YOYO_CLIPBOARD_HELPER` / `YOYO_WINDOWS_HELPER` / `YOYO_INPUT_HELPER` 换（缺省是 `server.mjs` 旁边的 `.exe`），`YOYO_MAX_FPS` 同
`YOYO_LINUX_MAX_FPS`（Windows 上缺省 60：显卡编码一帧只要几毫秒）；`YOYO_VIDEO_ENCODER`：`gpu`（只用显卡的编码器，没有就不出画面）、
`x264`（只用 CPU），缺省有显卡编码器就用、没有或中途坏了用 x264。

## 辅助程序

记录格式、命令、退出码与 Linux 的一一对应（各自文件开头有完整的说明），所以 `video.mjs`、`audio.mjs`、`clipboard.mjs`、`windows.mjs`、
`automation.mjs`、`input.mjs` 两边共用。Windows 上不同的：

- 画面：DXGI 桌面复制每来一帧（画了东西、指针动了）就把它留在显卡上；`E` 命令时编最新的一张。没有新帧时（静止的桌面）`E` 用
  上一张。复制丢了（切到安全桌面、改分辨率、全屏独占的游戏）每 250 ms 重来一次；换了大小以 3 退出，客户端按新尺寸开下一条流。
- 编码：**显卡编**（缺省）——画面留在显卡上，视频处理器转成 NV12，显卡的 H.264 编码器出一帧：2560×1440 一帧 3–5 ms，几乎不占 CPU
  （x264 读回 + 转色彩 + 编码要 20–30 ms，还吃满各个核）。码率、缓冲随 `E` 即时改；`crf` 在这里是码率控制可用的最低 QP（`crf − 3`）；
  关键帧只在 `E 1` 时出。没有硬件编码器（虚拟机、没有 Media Foundation 的 Windows N / Server）或它中途失败：改用 x264，stderr 有一行说明
  （日志里的 `video helper: … encoding on the graphics card (…)` / `… with x264 on the CPU`）。测速：
  `yoyo-winvideo.exe --bench 300 --fps 60 > out.h264`（不需要桌面，ssh 里也能跑；`--encoder x264` 对比）。
- 节奏：Windows 给普通进程的定时器 15.6 ms 一跳，Node 的 `setTimeout` 排不出 60 帧。辅助程序自己跑在 1 ms（`timeBeginPeriod`），hello 的
  第 5 个字节（标志 1）告诉服务它能代为计时：`T <毫秒> <id>` → 到点回一条 `'T'` 记录，`video.mjs` 用它等「下一帧该发的时刻」。
  桌面的帧在它自己的线程上取（不在复制里等：那样会一直占着显卡上下文的锁；有帧来时每 1 ms 看一次，静止时每 4 ms），主线程只等
  命令和计时器，来了就办。
- 显示器：流开着时不让显示器睡（睡着的显示器什么都不呈现，就没有画面）；开流时没有画面（显示器已经睡了）就发一次零位移的鼠标移动叫醒它。
- 指针：桌面复制给的指针形状（彩色、单色、带掩码的彩色）转成预乘 RGBA；单色与掩码里「反色」的像素画成黑色。形状的 id 是本进程里每个不同的
  形状一个序号。
- `/frame`：没有 ffmpeg，`yoyo-winvideo.exe --jpeg <质量> --size <宽> <高> [--crop x y w h] [--box x y w h]…` 截一张。这一张取的是
  GDI 给的合成后的桌面（从屏幕 `BitBlt`，指针用 `DrawIconEx` 画上），不走桌面复制：新开的复制要等有东西呈现到显示器才有画面，静止的
  桌面上什么都不呈现，它的第一帧是黑的（0.10.1：没人在用的电脑上每张 `/frame` 都是黑底加一个指针，旁边开着的流却有画面）。`BitBlt`
  不成时才退回桌面复制。
- 窗口的身份是程序名（`chrome`），不是窗口类；见 `docs/PROTOCOL.md`「Windows 服务端」。
- 指针穿得过去的窗口不列：带 `WS_EX_TRANSPARENT` 的，以及样式上没说、但系统自己的命中测试（`WindowFromPoint`）在它身上哪儿都找不到它的
  ——在窗口外框里取 8×8 个点，每个点的回答是「这个窗口」（实的，留下）、「它后面的窗口或没有」（这里穿过去了）或「它前面的窗口」（被挡着，
  说明不了什么）；有点穿过去、没有一个点是实的，就不列。NVIDIA Overlay 就是这样一个盖住整块屏幕的分层窗口：0.10.1 把它列了出来，于是
  每个 `/hit` 都答它，`/frame?visible=` 里它「在前面」把该盖住的窗口又露了出来。禁用的窗口（模态对话框后面的主窗口）`WindowFromPoint`
  会跳过，但点击到它为止，照样列。

## 发布

```sh
cd windows && ./build.sh 0.9.0     # build/yoyo-windows-0.9.0-windows-x64.zip + build/SHA256SUMS
gh release create windows-v0.9.0 --prerelease --target <commit> --title "yoyo-windows 0.9.0" build/yoyo-windows-0.9.0-windows-x64.zip build/SHA256SUMS
```

- 在 Mac（或 Linux）上交叉编译：`brew install mingw-w64 nasm cmake`、Rust 加 `rustup target add x86_64-pc-windows-gnu`。版本是
  `linux/server.mjs` 的 `VERSION`（不一致就停）；tag 是 `windows-v<版本>`，发过的不挪。
- 固定并校验的依赖：x264（一个提交，静态链接，GPL）、libopus 1.5.2（tar 包的 sha256）、Node.js 24.22.2 的 `node.exe`（nodejs.org 的
  SHASUMS256）。许可证在包里的 `licenses/`。
- uu Link 的原生插件：`link/` 按 `x86_64-pc-windows-gnu` 编，放成 `vendor/link/uu-link.win32-x64.node`。napi-rs 在 mingw 下直接链接 N-API
  的符号：`build.sh` 从 napi-sys 的源码列出它们，用 `dlltool` 做一个指向 `node.exe` 的导入库（napi-build 还要一个存在的 `libnode.dll`：
  一个空文件，什么都不用它）。
- zip 里的文件按名排序、时间固定。

## 测试

`cd linux && node --test test/` 包括 `test/platform.test.mjs`：Windows 平台下的同一个服务（辅助程序是 Linux 的假进程换了名字）——
`/status` 的 `app` / `platform`、`/frame` 经 `--jpeg`、输入到 `yoyo-wininput.exe`、窗口、剪贴板的 Windows 路径与 `concealed`、管理管道的名字。
辅助程序本身要在一台登录着的 Windows 上试（`/status`、`/frame`、`/stream`、`/audio`、`/windows`、`/clipboard`，以及 `yoyo pair` 后用 iPhone 连）。
