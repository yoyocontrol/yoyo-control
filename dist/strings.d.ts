import type { ScreenStrings } from "@yoyocontrol/screen-web";
import type { Language, ScreenHost } from "./contracts.js";
/**
 * Every word the pages show, in English and Simplified Chinese (the iOS kit's wording, its `Localizable.xcstrings`;
 * "iPhone" there is "this device" here). A host overrides any of them by key (`ScreenHost.strings`, in the language in
 * use). `{name}` placeholders are filled by `Words.t`. Keys ending in `Mac` have a `…Other` twin for a computer that
 * isn't a Mac (a Linux desktop): `Words.c` picks.
 */
export declare const STRINGS: {
    readonly screenTitleMac: {
        readonly en: "Screen";
        readonly zh: "屏幕";
    };
    readonly screenTitleOther: {
        readonly en: "Desktop";
        readonly zh: "桌面";
    };
    readonly pictureLabelMac: {
        readonly en: "Mac screen";
        readonly zh: "Mac 屏幕";
    };
    readonly pictureLabelOther: {
        readonly en: "Desktop";
        readonly zh: "桌面";
    };
    readonly close: {
        readonly en: "Close";
        readonly zh: "关闭";
    };
    readonly gestures: {
        readonly en: "Gestures";
        readonly zh: "手势";
    };
    readonly display: {
        readonly en: "Display";
        readonly zh: "显示器";
    };
    readonly keyboard: {
        readonly en: "Keyboard";
        readonly zh: "键盘";
    };
    readonly clipboard: {
        readonly en: "Clipboard";
        readonly zh: "剪贴板";
    };
    readonly fullScreen: {
        readonly en: "Full screen (view only)";
        readonly zh: "全屏（仅查看）";
    };
    readonly fullScreenDesktop: {
        readonly en: "Full screen";
        readonly zh: "全屏";
    };
    readonly exitFullScreen: {
        readonly en: "Exit full screen";
        readonly zh: "退出全屏";
    };
    readonly modeTrackpad: {
        readonly en: "Trackpad";
        readonly zh: "触控板";
    };
    readonly modeTouch: {
        readonly en: "Touch";
        readonly zh: "触摸";
    };
    readonly switchToTouch: {
        readonly en: "Switch to touch: tap where you want to click";
        readonly zh: "切换到触摸：点哪里就点击哪里";
    };
    readonly padHere: {
        readonly en: "Drag here to move the pointer, tap to click";
        readonly zh: "在这里拖动来移动指针，轻点就是点击";
    };
    readonly tapUsesPad: {
        readonly en: "Clicks go through the trackpad below the picture. To tap the picture itself, switch to touch (the button at the bottom).";
        readonly zh: "点击要在画面下方的触控板上做。想直接点画面，请用底部的按钮切换到触摸模式。";
    };
    readonly switchToTrackpad: {
        readonly en: "Switch to trackpad: move the pointer like on a laptop";
        readonly zh: "切换到触控板：像笔记本那样移动指针";
    };
    readonly soundMuteMac: {
        readonly en: "Mute Mac sound";
        readonly zh: "静音 Mac 的声音";
    };
    readonly soundMuteOther: {
        readonly en: "Mute sound";
        readonly zh: "静音";
    };
    readonly soundPlayMac: {
        readonly en: "Play Mac sound";
        readonly zh: "播放 Mac 的声音";
    };
    readonly soundPlayOther: {
        readonly en: "Play sound";
        readonly zh: "播放声音";
    };
    readonly pinchToZoom: {
        readonly en: "Pinch to zoom";
        readonly zh: "双指捏合可放大";
    };
    readonly doubleTapToFit: {
        readonly en: "Double-tap to fit";
        readonly zh: "轻点两下还原";
    };
    readonly tapToType: {
        readonly en: "Tap to type";
        readonly zh: "轻点即可输入";
    };
    readonly badgeAgent: {
        readonly en: "Agent is using the screen";
        readonly zh: "Agent 正在使用屏幕";
    };
    readonly badgeAgentNamed: {
        readonly en: "{name} is using the screen";
        readonly zh: "{name} 正在使用屏幕";
    };
    readonly badgeYou: {
        readonly en: "You have control";
        readonly zh: "你正在控制";
    };
    readonly badgeViewOnly: {
        readonly en: "View only";
        readonly zh: "仅查看";
    };
    readonly isControlling: {
        readonly en: "{name} is controlling";
        readonly zh: "{name} 正在操作";
    };
    readonly tookOver: {
        readonly en: "{name} took over";
        readonly zh: "{name} 接管了操作";
    };
    readonly pairingOpen: {
        readonly en: "The pairing window is open on the computer. For safety it never shows here: scan its code in front of the screen.";
        readonly zh: "配对窗口已在电脑上打开。为了安全，远程画面里看不到它：请到电脑前扫码。";
    };
    readonly takeOver: {
        readonly en: "Take Over";
        readonly zh: "接管";
    };
    readonly takeControl: {
        readonly en: "Take Control";
        readonly zh: "开始控制";
    };
    readonly anotherDevice: {
        readonly en: "Another device";
        readonly zh: "另一台设备";
    };
    readonly anotherIPhone: {
        readonly en: "Another iPhone";
        readonly zh: "另一台 iPhone";
    };
    readonly anotherIPad: {
        readonly en: "Another iPad";
        readonly zh: "另一台 iPad";
    };
    readonly agentTouchToTakeOver: {
        readonly en: "The agent is using the screen. Touch to take over.";
        readonly zh: "Agent 正在使用屏幕。触摸即可接管。";
    };
    readonly touchToControl: {
        readonly en: "Touch to take control.";
        readonly zh: "触摸即可开始控制。";
    };
    readonly noLongerControl: {
        readonly en: "You no longer have control of the screen.";
        readonly zh: "你已不再控制屏幕。";
    };
    readonly connecting: {
        readonly en: "Connecting…";
        readonly zh: "连接中…";
    };
    readonly reconnecting: {
        readonly en: "Reconnecting…";
        readonly zh: "重新连接中…";
    };
    readonly retry: {
        readonly en: "Retry";
        readonly zh: "重试";
    };
    readonly unavailableMac: {
        readonly en: "Screen unavailable";
        readonly zh: "无法显示屏幕";
    };
    readonly unavailableOther: {
        readonly en: "Desktop unavailable";
        readonly zh: "无法显示桌面";
    };
    readonly unavailableDetailMac: {
        readonly en: "The Mac’s screen can’t be shown right now.";
        readonly zh: "现在无法显示 Mac 的屏幕。";
    };
    readonly unavailableDetailOther: {
        readonly en: "The desktop can’t be shown right now.";
        readonly zh: "现在无法显示桌面。";
    };
    readonly reasonHelperRestartMac: {
        readonly en: "The screen helper is restarting";
        readonly zh: "屏幕助手正在重启";
    };
    readonly reasonHelperRestartOther: {
        readonly en: "The desktop is restarting";
        readonly zh: "桌面正在重启";
    };
    readonly reasonTimeoutMac: {
        readonly en: "The Mac’s screen isn’t responding";
        readonly zh: "Mac 的屏幕没有响应";
    };
    readonly reasonTimeoutOther: {
        readonly en: "The desktop isn’t responding";
        readonly zh: "桌面没有响应";
    };
    readonly reasonHelperDownMac: {
        readonly en: "The screen helper can’t start";
        readonly zh: "屏幕助手无法启动";
    };
    readonly reasonHelperDownOther: {
        readonly en: "The desktop can’t start";
        readonly zh: "桌面无法启动";
    };
    readonly reasonNoSession: {
        readonly en: "This account isn’t logged in on the Mac";
        readonly zh: "这个账号没有在 Mac 上登录";
    };
    readonly reasonNoPermission: {
        readonly en: "Yoyo Control is missing a permission on the Mac";
        readonly zh: "Yoyo Control 在 Mac 上缺少权限";
    };
    readonly couldNotReach: {
        readonly en: "Couldn’t reach the screen";
        readonly zh: "无法连接屏幕";
    };
    readonly noVideo: {
        readonly en: "This browser can’t play the screen’s video.";
        readonly zh: "这个浏览器无法播放屏幕画面。";
    };
    readonly recordingNeeded: {
        readonly en: "Screen Recording permission needed";
        readonly zh: "需要屏幕录制权限";
    };
    readonly recordingNeededDetail: {
        readonly en: "Allow Screen Recording for Yoyo Control in System Settings › Privacy & Security on the Mac. Tap below to show the request there.";
        readonly zh: "请在 Mac 的「系统设置 › 隐私与安全性」中允许 Yoyo Control 录制屏幕。点下面的按钮，在 Mac 上弹出授权请求。";
    };
    readonly accessibilityNote: {
        readonly en: "To control the Mac from here, allow Accessibility for Yoyo Control in System Settings on the Mac.";
        readonly zh: "要在这里控制 Mac，请在 Mac 的「系统设置」中允许 Yoyo Control 使用辅助功能。";
    };
    readonly requestPermissions: {
        readonly en: "Request permissions";
        readonly zh: "请求权限";
    };
    readonly permissionPrompted: {
        readonly en: "Check your Mac and allow Yoyo Control there.";
        readonly zh: "请到 Mac 上允许 Yoyo Control。";
    };
    readonly builtinDisplay: {
        readonly en: "Built-in display";
        readonly zh: "内建显示器";
    };
    readonly externalDisplay: {
        readonly en: "External display";
        readonly zh: "外接显示器";
    };
    readonly mainDisplay: {
        readonly en: "Main display";
        readonly zh: "主显示器";
    };
    readonly displayN: {
        readonly en: "Display {n}";
        readonly zh: "显示器 {n}";
    };
    readonly main: {
        readonly en: "Main";
        readonly zh: "主";
    };
    readonly commandKey: {
        readonly en: "Command key";
        readonly zh: "Command 键";
    };
    readonly shiftKey: {
        readonly en: "Shift key";
        readonly zh: "Shift 键";
    };
    readonly optionKey: {
        readonly en: "Option key";
        readonly zh: "Option 键";
    };
    readonly controlKey: {
        readonly en: "Control key";
        readonly zh: "Control 键";
    };
    readonly escape: {
        readonly en: "Escape";
        readonly zh: "Esc 键";
    };
    readonly tab: {
        readonly en: "Tab";
        readonly zh: "Tab 键";
    };
    readonly leftArrow: {
        readonly en: "Left arrow";
        readonly zh: "左箭头";
    };
    readonly upArrow: {
        readonly en: "Up arrow";
        readonly zh: "上箭头";
    };
    readonly downArrow: {
        readonly en: "Down arrow";
        readonly zh: "下箭头";
    };
    readonly rightArrow: {
        readonly en: "Right arrow";
        readonly zh: "右箭头";
    };
    readonly hideKeyboard: {
        readonly en: "Hide keyboard";
        readonly zh: "收起键盘";
    };
    readonly holdForFiles: {
        readonly en: "Touch and hold to send photos or files instead.";
        readonly zh: "按住可改为发送照片或文件。";
    };
    readonly trackpadGestures: {
        readonly en: "Trackpad gestures";
        readonly zh: "触控板手势";
    };
    readonly touchGestures: {
        readonly en: "Touch gestures";
        readonly zh: "触摸手势";
    };
    readonly mouseGestures: {
        readonly en: "Mouse and keyboard";
        readonly zh: "鼠标和键盘";
    };
    readonly trackpadIntro: {
        readonly en: "The panel under the picture is a trackpad: the pointer moves with your finger, taps click where it is. While you move it, a loupe magnifies around the pointer. Pinch the picture to zoom in, double-tap it to fit.";
        readonly zh: "画面下方的面板是触控板：指针随手指移动，轻点就在指针处点击；移动时，指针周围会出现放大镜。双指捏合画面可放大，轻点两下还原。";
    };
    readonly touchIntro: {
        readonly en: "Your finger is the pointer: tap the picture where you want to click. Pinch to zoom in on small things.";
        readonly zh: "手指就是指针：在画面上点哪里，就点击哪里。双指捏合可以放大细小的地方。";
    };
    readonly mouseIntro: {
        readonly en: "The picture works like the computer’s own screen: click, drag and scroll on it, and type with your keyboard.";
        readonly zh: "画面就像电脑自己的屏幕：在上面点击、拖动、滚动，用键盘直接输入。";
    };
    readonly gesture: {
        readonly en: "Gesture";
        readonly zh: "手势";
    };
    readonly action: {
        readonly en: "Action";
        readonly zh: "作用";
    };
    readonly dragOneFinger: {
        readonly en: "Drag with one finger";
        readonly zh: "单指拖动";
    };
    readonly movePointer: {
        readonly en: "Move the pointer";
        readonly zh: "移动指针";
    };
    readonly tap: {
        readonly en: "Tap";
        readonly zh: "轻点";
    };
    readonly click: {
        readonly en: "Click";
        readonly zh: "点击";
    };
    readonly doubleTap: {
        readonly en: "Double tap";
        readonly zh: "轻点两下";
    };
    readonly doubleClick: {
        readonly en: "Double-click";
        readonly zh: "双击";
    };
    readonly tapTwoFingers: {
        readonly en: "Tap with two fingers";
        readonly zh: "双指轻点";
    };
    readonly rightClick: {
        readonly en: "Right-click";
        readonly zh: "右键点击";
    };
    readonly holdThenDrag: {
        readonly en: "Touch and hold, then drag — or tap, then touch and drag";
        readonly zh: "按住片刻再拖动，或轻点后再按住拖动";
    };
    readonly selectOrDrag: {
        readonly en: "Select or drag";
        readonly zh: "选择或拖动";
    };
    readonly dragThreeFingers: {
        readonly en: "Drag with three fingers";
        readonly zh: "三指拖动";
    };
    readonly dragKeepGoing: {
        readonly en: "Drag — lift and touch again to keep going";
        readonly zh: "拖移——抬起后再按下可接着拖";
    };
    readonly dragTwoFingers: {
        readonly en: "Drag with two fingers";
        readonly zh: "双指拖动";
    };
    readonly scroll: {
        readonly en: "Scroll";
        readonly zh: "滚动";
    };
    readonly touchAndHold: {
        readonly en: "Touch and hold";
        readonly zh: "按住";
    };
    readonly pinch: {
        readonly en: "Pinch";
        readonly zh: "双指捏合";
    };
    readonly zoomPicture: {
        readonly en: "Zoom the picture";
        readonly zh: "放大画面";
    };
    readonly clickMouse: {
        readonly en: "Click, double-click";
        readonly zh: "单击、双击";
    };
    readonly clickMouseAction: {
        readonly en: "The same on the computer";
        readonly zh: "在电脑上同样点击";
    };
    readonly dragMouse: {
        readonly en: "Drag";
        readonly zh: "拖动";
    };
    readonly wheel: {
        readonly en: "Scroll wheel or trackpad";
        readonly zh: "滚轮或触控板";
    };
    readonly typeKeys: {
        readonly en: "Type, shortcuts";
        readonly zh: "输入、快捷键";
    };
    readonly typeKeysAction: {
        readonly en: "Go to the computer (⌘ or Ctrl)";
        readonly zh: "直接发到电脑（⌘ 或 Ctrl）";
    };
    readonly gotIt: {
        readonly en: "Got it";
        readonly zh: "知道了";
    };
    readonly sendFilesHint: {
        readonly en: "Send photos and files from the clipboard button.";
        readonly zh: "照片和文件可以用剪贴板按钮发送。";
    };
    readonly pasteOnMac: {
        readonly en: "Paste on Mac";
        readonly zh: "粘贴到 Mac";
    };
    readonly pasteOnOther: {
        readonly en: "Paste on Computer";
        readonly zh: "粘贴到电脑";
    };
    readonly copyFromMac: {
        readonly en: "Copy from Mac";
        readonly zh: "从 Mac 复制";
    };
    readonly copyFromOther: {
        readonly en: "Copy from Computer";
        readonly zh: "从电脑复制";
    };
    readonly pasteExplainedMac: {
        readonly en: "What you copied on this device goes to the Mac and is pasted there";
        readonly zh: "把本机拷贝的内容放到 Mac 上并粘贴";
    };
    readonly pasteExplainedOther: {
        readonly en: "What you copied on this device goes to the computer and is pasted there";
        readonly zh: "把本机拷贝的内容放到电脑上并粘贴";
    };
    readonly copyExplainedMac: {
        readonly en: "What the Mac copied comes to this device’s clipboard";
        readonly zh: "把 Mac 上拷贝的内容放进本机的剪贴板";
    };
    readonly copyExplainedOther: {
        readonly en: "What the computer copied comes to this device’s clipboard";
        readonly zh: "把电脑上拷贝的内容放进本机的剪贴板";
    };
    readonly sendToMac: {
        readonly en: "Send to Mac";
        readonly zh: "发送到 Mac";
    };
    readonly sendToOther: {
        readonly en: "Send to Computer";
        readonly zh: "发送到电脑";
    };
    readonly onYourMac: {
        readonly en: "On your Mac";
        readonly zh: "Mac 上的内容";
    };
    readonly onYourOther: {
        readonly en: "On your computer";
        readonly zh: "电脑上的内容";
    };
    readonly openClipboard: {
        readonly en: "Open clipboard";
        readonly zh: "打开剪贴板";
    };
    readonly photos: {
        readonly en: "Photos…";
        readonly zh: "照片…";
    };
    readonly files: {
        readonly en: "Files…";
        readonly zh: "文件…";
    };
    readonly newDot: {
        readonly en: "New";
        readonly zh: "有新内容";
    };
    readonly pastedMac: {
        readonly en: "Pasted on the Mac";
        readonly zh: "已在 Mac 上粘贴";
    };
    readonly pastedOther: {
        readonly en: "Pasted on the computer";
        readonly zh: "已在电脑上粘贴";
    };
    readonly copiedTakeControlMac: {
        readonly en: "Copied to the Mac. Take control to paste.";
        readonly zh: "已复制到 Mac。接管后即可粘贴。";
    };
    readonly copiedTakeControlOther: {
        readonly en: "Copied to the computer. Take control to paste.";
        readonly zh: "已复制到电脑。接管后即可粘贴。";
    };
    readonly copiedFromMac: {
        readonly en: "Copied from the Mac";
        readonly zh: "已从 Mac 复制";
    };
    readonly copiedFromOther: {
        readonly en: "Copied from the computer";
        readonly zh: "已从电脑复制";
    };
    readonly concealedMac: {
        readonly en: "The Mac’s clipboard is hidden by a password manager.";
        readonly zh: "Mac 的剪贴板内容被密码管理器隐藏了。";
    };
    readonly concealedOther: {
        readonly en: "The computer’s clipboard is hidden by a password manager.";
        readonly zh: "电脑的剪贴板内容被密码管理器隐藏了。";
    };
    readonly emptyMessageMac: {
        readonly en: "The Mac’s clipboard is empty.";
        readonly zh: "Mac 的剪贴板是空的。";
    };
    readonly emptyMessageOther: {
        readonly en: "The computer’s clipboard is empty.";
        readonly zh: "电脑的剪贴板是空的。";
    };
    readonly emptyLineMac: {
        readonly en: "The Mac’s clipboard is empty";
        readonly zh: "Mac 的剪贴板是空的";
    };
    readonly emptyLineOther: {
        readonly en: "The computer’s clipboard is empty";
        readonly zh: "电脑的剪贴板是空的";
    };
    readonly nothingToTakeMac: {
        readonly en: "Nothing this device can take from the Mac’s clipboard.";
        readonly zh: "Mac 剪贴板上的内容无法放到本机。";
    };
    readonly nothingToTakeOther: {
        readonly en: "Nothing this device can take from the computer’s clipboard.";
        readonly zh: "电脑剪贴板上的内容无法放到本机。";
    };
    readonly sendingFilesMac: {
        readonly en: "Sending {n} files to the Mac…";
        readonly zh: "正在把 {n} 个文件发送到 Mac…";
    };
    readonly sendingFilesOther: {
        readonly en: "Sending {n} files to the computer…";
        readonly zh: "正在把 {n} 个文件发送到电脑…";
    };
    readonly copiedToMac: {
        readonly en: "Copied to the Mac";
        readonly zh: "已复制到 Mac";
    };
    readonly copiedToOther: {
        readonly en: "Copied to the computer";
        readonly zh: "已复制到电脑";
    };
    readonly sentMac: {
        readonly en: "Sent to the Mac";
        readonly zh: "已发送到 Mac";
    };
    readonly sentOther: {
        readonly en: "Sent to the computer";
        readonly zh: "已发送到电脑";
    };
    readonly sentSavedMac: {
        readonly en: "Sent to the Mac · saved in {folder}";
        readonly zh: "已发送到 Mac · 保存在「{folder}」";
    };
    readonly sentSavedOther: {
        readonly en: "Sent to the computer · saved in {folder}";
        readonly zh: "已发送到电脑 · 保存在「{folder}」";
    };
    readonly copiedOnMac: {
        readonly en: "Copied on the Mac";
        readonly zh: "在 Mac 上复制";
    };
    readonly copiedOnOther: {
        readonly en: "Copied on the computer";
        readonly zh: "在电脑上复制";
    };
    readonly copiedOnWhenMac: {
        readonly en: "Copied on the Mac · {when}";
        readonly zh: "在 Mac 上复制 · {when}";
    };
    readonly copiedOnWhenOther: {
        readonly en: "Copied on the computer · {when}";
        readonly zh: "在电脑上复制 · {when}";
    };
    readonly copiedHintMac: {
        readonly en: "Copied on Mac: {what} — Copy here";
        readonly zh: "Mac 上拷贝了：{what} — 复制到本机";
    };
    readonly copiedHintOther: {
        readonly en: "Copied on computer: {what} — Copy here";
        readonly zh: "电脑上拷贝了：{what} — 复制到本机";
    };
    readonly phoneHintMac: {
        readonly en: "This device’s clipboard: {kind} — Paste on Mac";
        readonly zh: "本机剪贴板：{kind} — 粘贴到 Mac";
    };
    readonly phoneHintOther: {
        readonly en: "This device’s clipboard: {kind} — Paste on Computer";
        readonly zh: "本机剪贴板：{kind} — 粘贴到电脑";
    };
    readonly sendFooterMac: {
        readonly en: "Text and links go onto the Mac’s clipboard. Photos and files are saved to its Downloads folder and copied there too.";
        readonly zh: "文本和链接会放到 Mac 的剪贴板上；照片和文件会保存到 Mac 的「下载」文件夹，并同时复制到剪贴板。";
    };
    readonly sendFooterOther: {
        readonly en: "Text and links go onto the computer’s clipboard. Photos and files are saved to its Downloads folder and copied there too.";
        readonly zh: "文本和链接会放到电脑的剪贴板上；照片和文件会保存到电脑的「下载」文件夹，并同时复制到剪贴板。";
    };
    readonly sendTextFooterMac: {
        readonly en: "Text and links go onto the Mac’s clipboard.";
        readonly zh: "文本和链接会放到 Mac 的剪贴板上。";
    };
    readonly sendTextFooterOther: {
        readonly en: "Text and links go onto the computer’s clipboard.";
        readonly zh: "文本和链接会放到电脑的剪贴板上。";
    };
    readonly folderOnMac: {
        readonly en: "Folder · copy its contents on the Mac";
        readonly zh: "文件夹 · 请在 Mac 上复制其中的内容";
    };
    readonly folderOnOther: {
        readonly en: "Folder · copy its contents on the computer";
        readonly zh: "文件夹 · 请在电脑上复制其中的内容";
    };
    readonly copySomethingMac: {
        readonly en: "Copy something on the Mac and it shows up here.";
        readonly zh: "在 Mac 上复制点什么，就会显示在这里。";
    };
    readonly copySomethingOther: {
        readonly en: "Copy something on the computer and it shows up here.";
        readonly zh: "在电脑上复制点什么，就会显示在这里。";
    };
    readonly clipboardUnavailable: {
        readonly en: "Clipboard unavailable";
        readonly zh: "剪贴板不可用";
    };
    readonly clipboardNotAvailable: {
        readonly en: "Clipboard not available";
        readonly zh: "剪贴板不可用";
    };
    readonly clipboardCantShare: {
        readonly en: "This computer can’t share its clipboard.";
        readonly zh: "这台电脑无法共享剪贴板。";
    };
    readonly couldNotReadClipboard: {
        readonly en: "Couldn’t read the clipboard";
        readonly zh: "无法读取剪贴板";
    };
    readonly empty: {
        readonly en: "Empty";
        readonly zh: "空";
    };
    readonly text: {
        readonly en: "Text";
        readonly zh: "文本";
    };
    readonly textWord: {
        readonly en: "text";
        readonly zh: "文字";
    };
    readonly link: {
        readonly en: "Web link";
        readonly zh: "链接";
    };
    readonly linkWord: {
        readonly en: "link";
        readonly zh: "链接";
    };
    readonly image: {
        readonly en: "Image";
        readonly zh: "图片";
    };
    readonly imageWord: {
        readonly en: "image";
        readonly zh: "图片";
    };
    readonly imageSized: {
        readonly en: "Image · {w}×{h}";
        readonly zh: "图片 · {w}×{h}";
    };
    readonly textSized: {
        readonly en: "Text · {size}";
        readonly zh: "文本 · {size}";
    };
    readonly textQuoted: {
        readonly en: "Text · “{text}”";
        readonly zh: "文字 · “{text}”";
    };
    readonly nFiles: {
        readonly en: "{n} files";
        readonly zh: "{n} 个文件";
    };
    readonly nFilesNamed: {
        readonly en: "{n} files · {names}";
        readonly zh: "{n} 个文件 · {names}";
    };
    readonly andMore: {
        readonly en: "and {n} more not listed";
        readonly zh: "还有 {n} 个未列出";
    };
    readonly hiddenPasswordManager: {
        readonly en: "Hidden (password manager)";
        readonly zh: "已隐藏（密码管理器）";
    };
    readonly hiddenByPasswordManager: {
        readonly en: "Hidden by a password manager";
        readonly zh: "已被密码管理器隐藏";
    };
    readonly hiddenExplained: {
        readonly en: "A password manager marked this item hidden; it can’t be read from here.";
        readonly zh: "密码管理器将此项标记为隐藏，无法从这里读取。";
    };
    readonly cantBeShown: {
        readonly en: "Something that can’t be shown here";
        readonly zh: "无法在此显示的内容";
    };
    readonly sentFromHere: {
        readonly en: "Sent from this device";
        readonly zh: "从本机发送";
    };
    readonly sentFromHereWhen: {
        readonly en: "Sent from this device · {when}";
        readonly zh: "从本机发送 · {when}";
    };
    readonly copiedByAgent: {
        readonly en: "Copied by an agent";
        readonly zh: "由智能体复制";
    };
    readonly copiedByAgentWhen: {
        readonly en: "Copied by an agent · {when}";
        readonly zh: "由智能体复制 · {when}";
    };
    readonly copiedByName: {
        readonly en: "Copied by {name}";
        readonly zh: "由 {name} 复制";
    };
    readonly copiedByNameWhen: {
        readonly en: "Copied by {name} · {when}";
        readonly zh: "由 {name} 复制 · {when}";
    };
    readonly justNow: {
        readonly en: "just now";
        readonly zh: "刚刚";
    };
    readonly nothingCopiedHere: {
        readonly en: "Nothing copied on this device";
        readonly zh: "本机上没有拷贝内容";
    };
    readonly nothingToPaste: {
        readonly en: "Nothing to paste: copy something on this device first.";
        readonly zh: "没有可粘贴的内容：请先在本机复制点什么。";
    };
    readonly clipboardReadRefused: {
        readonly en: "This browser didn’t allow reading the clipboard.";
        readonly zh: "浏览器没有允许读取剪贴板。";
    };
    readonly clipboardWriteRefused: {
        readonly en: "This browser didn’t allow writing to the clipboard.";
        readonly zh: "浏览器没有允许写入剪贴板。";
    };
    readonly textTooLong: {
        readonly en: "Too long to copy (max 1 MB).";
        readonly zh: "文本太长，无法复制（最多 1 MB）。";
    };
    readonly tooManyFiles: {
        readonly en: "At most {n} files at a time.";
        readonly zh: "一次最多 {n} 个文件。";
    };
    readonly fileTooLarge: {
        readonly en: "{name} is too large (max {limit}).";
        readonly zh: "{name} 太大了（上限 {limit}）。";
    };
    readonly copy: {
        readonly en: "Copy";
        readonly zh: "拷贝";
    };
    readonly copied: {
        readonly en: "Copied";
        readonly zh: "已拷贝";
    };
    readonly share: {
        readonly en: "Share";
        readonly zh: "分享";
    };
    readonly download: {
        readonly en: "Download";
        readonly zh: "下载";
    };
    readonly copying: {
        readonly en: "Copying…";
        readonly zh: "正在复制…";
    };
    readonly loading: {
        readonly en: "Loading…";
        readonly zh: "正在读取…";
    };
    readonly uploadingFiles: {
        readonly en: "Uploading {n} files…";
        readonly zh: "正在上传 {n} 个文件…";
    };
    readonly downloadingOf: {
        readonly en: "Downloading {i} of {n}…";
        readonly zh: "正在下载第 {i} 个，共 {n} 个…";
    };
    readonly foldersLeftOut: {
        readonly en: "Folders were left out.";
        readonly zh: "文件夹未包含在内。";
    };
    readonly pasteRowDetail: {
        readonly en: "What you copied on this device: text, a link or an image";
        readonly zh: "本机复制的内容：文本、链接或图片";
    };
    readonly dropFilesHere: {
        readonly en: "Drop files here to send them";
        readonly zh: "把文件拖到这里即可发送";
    };
    readonly showsWholeText: {
        readonly en: "Show all";
        readonly zh: "显示全部";
    };
    readonly showsFirstLines: {
        readonly en: "Show less";
        readonly zh: "收起";
    };
    readonly watchMac: {
        readonly en: "Watch the Mac, or take control";
        readonly zh: "查看 Mac 的画面，或接管操作";
    };
    readonly watchOther: {
        readonly en: "Watch the desktop, or take control";
        readonly zh: "查看桌面，或接管操作";
    };
    readonly httpStatus: {
        readonly en: "The server returned HTTP {code}.";
        readonly zh: "服务器返回 HTTP {code}。";
    };
};
export type StringKey = keyof typeof STRINGS;
/** The browser's language as one of the pages' (zh* → zh-Hans, else English). */
export declare function browserLanguage(): Language;
/** The pages' words in one language, with a host's overrides, for a Mac or another computer. */
export declare class Words {
    readonly language: Language;
    readonly locale: string;
    readonly agentName: string | null;
    private readonly overrides;
    /** The computer is a Mac (its words; `c()` picks the `…Mac` keys). */
    mac: boolean;
    constructor(host?: ScreenHost);
    /** `key`'s words with `{name}` placeholders filled. */
    t(key: StringKey, vars?: Record<string, string | number>): string;
    /** The Mac's or the other computer's variant of `stem` (`stem + "Mac"` / `stem + "Other"`). */
    c(stem: string, vars?: Record<string, string | number>): string;
    /** A number in the locale. */
    num(n: number): string;
    /** "95 MB" in the locale. */
    bytes(n: number): string;
    /** "just now" under a minute, else "2 min. ago". */
    relative(at: number, now?: number): string;
    /** screen-web's `ScreenStrings` (the connection phases) in these words. */
    screenStrings(): ScreenStrings;
}
