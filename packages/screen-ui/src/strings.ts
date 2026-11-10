import type { Host, ScreenStrings } from "@yoyocontrol/screen-web";
import type { Language, ScreenHost } from "./contracts.js";

/**
 * Every word the pages show, in English and Simplified Chinese (the iOS kit's wording, its `Localizable.xcstrings`;
 * "iPhone" there is "this device" here). A host overrides any of them by key (`ScreenHost.strings`, in the language in
 * use). `{name}` placeholders are filled by `Words.t`. Keys ending in `Mac` have a `…Other` twin for a computer that
 * isn't a Mac (a Linux desktop): `Words.c` picks.
 */
export const STRINGS = {
  // the page
  screenTitleMac: { en: "Screen", zh: "屏幕" },
  screenTitleOther: { en: "Desktop", zh: "桌面" },
  pictureLabelMac: { en: "Mac screen", zh: "Mac 屏幕" },
  pictureLabelOther: { en: "Desktop", zh: "桌面" },
  close: { en: "Close", zh: "关闭" },
  gestures: { en: "Gestures", zh: "手势" },
  display: { en: "Display", zh: "显示器" },
  keyboard: { en: "Keyboard", zh: "键盘" },
  clipboard: { en: "Clipboard", zh: "剪贴板" },
  fullScreen: { en: "Full screen (view only)", zh: "全屏（仅查看）" },
  fullScreenDesktop: { en: "Full screen", zh: "全屏" },
  exitFullScreen: { en: "Exit full screen", zh: "退出全屏" },
  modeTrackpad: { en: "Trackpad", zh: "触控板" },
  modeTouch: { en: "Touch", zh: "触摸" },
  switchToTouch: { en: "Switch to touch: tap where you want to click", zh: "切换到触摸：点哪里就点击哪里" },
  padHere: { en: "Drag here to move the pointer, tap to click", zh: "在这里拖动来移动指针，轻点就是点击" },
  tapUsesPad: {
    en: "Clicks go through the trackpad below the picture. To tap the picture itself, switch to touch (the button at the bottom).",
    zh: "点击要在画面下方的触控板上做。想直接点画面，请用底部的按钮切换到触摸模式。",
  },
  switchToTrackpad: { en: "Switch to trackpad: move the pointer like on a laptop", zh: "切换到触控板：像笔记本那样移动指针" },
  soundMuteMac: { en: "Mute Mac sound", zh: "静音 Mac 的声音" },
  soundMuteOther: { en: "Mute sound", zh: "静音" },
  soundPlayMac: { en: "Play Mac sound", zh: "播放 Mac 的声音" },
  soundPlayOther: { en: "Play sound", zh: "播放声音" },
  pinchToZoom: { en: "Pinch to zoom", zh: "双指捏合可放大" },
  doubleTapToFit: { en: "Double-tap to fit", zh: "轻点两下还原" },
  tapToType: { en: "Tap to type", zh: "轻点即可输入" },
  // who controls
  badgeAgent: { en: "Agent is using the screen", zh: "Agent 正在使用屏幕" },
  badgeAgentNamed: { en: "{name} is using the screen", zh: "{name} 正在使用屏幕" },
  badgeYou: { en: "You have control", zh: "你正在控制" },
  badgeViewOnly: { en: "View only", zh: "仅查看" },
  isControlling: { en: "{name} is controlling", zh: "{name} 正在操作" },
  tookOver: { en: "{name} took over", zh: "{name} 接管了操作" },
  pairingOpen: {
    en: "The pairing window is open on the computer. For safety it never shows here: scan its code in front of the screen.",
    zh: "配对窗口已在电脑上打开。为了安全，远程画面里看不到它：请到电脑前扫码。",
  },
  takeOver: { en: "Take Over", zh: "接管" },
  takeControl: { en: "Take Control", zh: "开始控制" },
  anotherDevice: { en: "Another device", zh: "另一台设备" },
  anotherIPhone: { en: "Another iPhone", zh: "另一台 iPhone" },
  anotherIPad: { en: "Another iPad", zh: "另一台 iPad" },
  agentTouchToTakeOver: { en: "The agent is using the screen. Touch to take over.", zh: "Agent 正在使用屏幕。触摸即可接管。" },
  touchToControl: { en: "Touch to take control.", zh: "触摸即可开始控制。" },
  noLongerControl: { en: "You no longer have control of the screen.", zh: "你已不再控制屏幕。" },
  // the connection
  connecting: { en: "Connecting…", zh: "连接中…" },
  reconnecting: { en: "Reconnecting…", zh: "重新连接中…" },
  retry: { en: "Retry", zh: "重试" },
  unavailableMac: { en: "Screen unavailable", zh: "无法显示屏幕" },
  unavailableOther: { en: "Desktop unavailable", zh: "无法显示桌面" },
  unavailableDetailMac: { en: "The Mac’s screen can’t be shown right now.", zh: "现在无法显示 Mac 的屏幕。" },
  unavailableDetailOther: { en: "The desktop can’t be shown right now.", zh: "现在无法显示桌面。" },
  reasonHelperRestartMac: { en: "The screen helper is restarting", zh: "屏幕助手正在重启" },
  reasonHelperRestartOther: { en: "The desktop is restarting", zh: "桌面正在重启" },
  reasonTimeoutMac: { en: "The Mac’s screen isn’t responding", zh: "Mac 的屏幕没有响应" },
  reasonTimeoutOther: { en: "The desktop isn’t responding", zh: "桌面没有响应" },
  reasonHelperDownMac: { en: "The screen helper can’t start", zh: "屏幕助手无法启动" },
  reasonHelperDownOther: { en: "The desktop can’t start", zh: "桌面无法启动" },
  reasonNoSession: { en: "This account isn’t logged in on the Mac", zh: "这个账号没有在 Mac 上登录" },
  reasonNoPermission: { en: "Yoyo Control is missing a permission on the Mac", zh: "Yoyo Control 在 Mac 上缺少权限" },
  couldNotReach: { en: "Couldn’t reach the screen", zh: "无法连接屏幕" },
  noVideo: { en: "This browser can’t play the screen’s video.", zh: "这个浏览器无法播放屏幕画面。" },
  // permissions
  recordingNeeded: { en: "Screen Recording permission needed", zh: "需要屏幕录制权限" },
  recordingNeededDetail: {
    en: "Allow Screen Recording for Yoyo Control in System Settings › Privacy & Security on the Mac. Tap below to show the request there.",
    zh: "请在 Mac 的「系统设置 › 隐私与安全性」中允许 Yoyo Control 录制屏幕。点下面的按钮，在 Mac 上弹出授权请求。",
  },
  accessibilityNote: {
    en: "To control the Mac from here, allow Accessibility for Yoyo Control in System Settings on the Mac.",
    zh: "要在这里控制 Mac，请在 Mac 的「系统设置」中允许 Yoyo Control 使用辅助功能。",
  },
  requestPermissions: { en: "Request permissions", zh: "请求权限" },
  permissionPrompted: { en: "Check your Mac and allow Yoyo Control there.", zh: "请到 Mac 上允许 Yoyo Control。" },
  // displays
  builtinDisplay: { en: "Built-in display", zh: "内建显示器" },
  externalDisplay: { en: "External display", zh: "外接显示器" },
  mainDisplay: { en: "Main display", zh: "主显示器" },
  displayN: { en: "Display {n}", zh: "显示器 {n}" },
  main: { en: "Main", zh: "主" },
  // the key bar
  commandKey: { en: "Command key", zh: "Command 键" },
  shiftKey: { en: "Shift key", zh: "Shift 键" },
  optionKey: { en: "Option key", zh: "Option 键" },
  controlKey: { en: "Control key", zh: "Control 键" },
  escape: { en: "Escape", zh: "Esc 键" },
  tab: { en: "Tab", zh: "Tab 键" },
  leftArrow: { en: "Left arrow", zh: "左箭头" },
  upArrow: { en: "Up arrow", zh: "上箭头" },
  downArrow: { en: "Down arrow", zh: "下箭头" },
  rightArrow: { en: "Right arrow", zh: "右箭头" },
  hideKeyboard: { en: "Hide keyboard", zh: "收起键盘" },
  holdForFiles: { en: "Touch and hold to send photos or files instead.", zh: "按住可改为发送照片或文件。" },
  // the gesture card
  trackpadGestures: { en: "Trackpad gestures", zh: "触控板手势" },
  touchGestures: { en: "Touch gestures", zh: "触摸手势" },
  mouseGestures: { en: "Mouse and keyboard", zh: "鼠标和键盘" },
  trackpadIntro: {
    en: "The panel under the picture is a trackpad: the pointer moves with your finger, taps click where it is. While you move it, a loupe magnifies around the pointer. Pinch the picture to zoom in, double-tap it to fit.",
    zh: "画面下方的面板是触控板：指针随手指移动，轻点就在指针处点击；移动时，指针周围会出现放大镜。双指捏合画面可放大，轻点两下还原。",
  },
  touchIntro: {
    en: "Your finger is the pointer: tap the picture where you want to click. Pinch to zoom in on small things.",
    zh: "手指就是指针：在画面上点哪里，就点击哪里。双指捏合可以放大细小的地方。",
  },
  mouseIntro: {
    en: "The picture works like the computer’s own screen: click, drag and scroll on it, and type with your keyboard.",
    zh: "画面就像电脑自己的屏幕：在上面点击、拖动、滚动，用键盘直接输入。",
  },
  gesture: { en: "Gesture", zh: "手势" },
  action: { en: "Action", zh: "作用" },
  dragOneFinger: { en: "Drag with one finger", zh: "单指拖动" },
  movePointer: { en: "Move the pointer", zh: "移动指针" },
  tap: { en: "Tap", zh: "轻点" },
  click: { en: "Click", zh: "点击" },
  doubleTap: { en: "Double tap", zh: "轻点两下" },
  doubleClick: { en: "Double-click", zh: "双击" },
  tapTwoFingers: { en: "Tap with two fingers", zh: "双指轻点" },
  rightClick: { en: "Right-click", zh: "右键点击" },
  holdThenDrag: { en: "Touch and hold, then drag — or tap, then touch and drag", zh: "按住片刻再拖动，或轻点后再按住拖动" },
  selectOrDrag: { en: "Select or drag", zh: "选择或拖动" },
  dragThreeFingers: { en: "Drag with three fingers", zh: "三指拖动" },
  dragKeepGoing: { en: "Drag — lift and touch again to keep going", zh: "拖移——抬起后再按下可接着拖" },
  dragTwoFingers: { en: "Drag with two fingers", zh: "双指拖动" },
  scroll: { en: "Scroll", zh: "滚动" },
  touchAndHold: { en: "Touch and hold", zh: "按住" },
  pinch: { en: "Pinch", zh: "双指捏合" },
  zoomPicture: { en: "Zoom the picture", zh: "放大画面" },
  clickMouse: { en: "Click, double-click", zh: "单击、双击" },
  clickMouseAction: { en: "The same on the computer", zh: "在电脑上同样点击" },
  dragMouse: { en: "Drag", zh: "拖动" },
  wheel: { en: "Scroll wheel or trackpad", zh: "滚轮或触控板" },
  typeKeys: { en: "Type, shortcuts", zh: "输入、快捷键" },
  typeKeysAction: { en: "Go to the computer (⌘ or Ctrl)", zh: "直接发到电脑（⌘ 或 Ctrl）" },
  gotIt: { en: "Got it", zh: "知道了" },
  sendFilesHint: { en: "Send photos and files from the clipboard button.", zh: "照片和文件可以用剪贴板按钮发送。" },
  // clipboard: the two verbs
  pasteOnMac: { en: "Paste on Mac", zh: "粘贴到 Mac" },
  pasteOnOther: { en: "Paste on Computer", zh: "粘贴到电脑" },
  copyFromMac: { en: "Copy from Mac", zh: "从 Mac 复制" },
  copyFromOther: { en: "Copy from Computer", zh: "从电脑复制" },
  pasteExplainedMac: { en: "What you copied on this device goes to the Mac and is pasted there", zh: "把本机拷贝的内容放到 Mac 上并粘贴" },
  pasteExplainedOther: { en: "What you copied on this device goes to the computer and is pasted there", zh: "把本机拷贝的内容放到电脑上并粘贴" },
  copyExplainedMac: { en: "What the Mac copied comes to this device’s clipboard", zh: "把 Mac 上拷贝的内容放进本机的剪贴板" },
  copyExplainedOther: { en: "What the computer copied comes to this device’s clipboard", zh: "把电脑上拷贝的内容放进本机的剪贴板" },
  sendToMac: { en: "Send to Mac", zh: "发送到 Mac" },
  sendToOther: { en: "Send to Computer", zh: "发送到电脑" },
  onYourMac: { en: "On your Mac", zh: "Mac 上的内容" },
  onYourOther: { en: "On your computer", zh: "电脑上的内容" },
  openClipboard: { en: "Open clipboard", zh: "打开剪贴板" },
  photos: { en: "Photos…", zh: "照片…" },
  files: { en: "Files…", zh: "文件…" },
  newDot: { en: "New", zh: "有新内容" },
  // clipboard: what happened
  pastedMac: { en: "Pasted on the Mac", zh: "已在 Mac 上粘贴" },
  pastedOther: { en: "Pasted on the computer", zh: "已在电脑上粘贴" },
  copiedTakeControlMac: { en: "Copied to the Mac. Take control to paste.", zh: "已复制到 Mac。接管后即可粘贴。" },
  copiedTakeControlOther: { en: "Copied to the computer. Take control to paste.", zh: "已复制到电脑。接管后即可粘贴。" },
  copiedFromMac: { en: "Copied from the Mac", zh: "已从 Mac 复制" },
  copiedFromOther: { en: "Copied from the computer", zh: "已从电脑复制" },
  concealedMac: { en: "The Mac’s clipboard is hidden by a password manager.", zh: "Mac 的剪贴板内容被密码管理器隐藏了。" },
  concealedOther: { en: "The computer’s clipboard is hidden by a password manager.", zh: "电脑的剪贴板内容被密码管理器隐藏了。" },
  emptyMessageMac: { en: "The Mac’s clipboard is empty.", zh: "Mac 的剪贴板是空的。" },
  emptyMessageOther: { en: "The computer’s clipboard is empty.", zh: "电脑的剪贴板是空的。" },
  emptyLineMac: { en: "The Mac’s clipboard is empty", zh: "Mac 的剪贴板是空的" },
  emptyLineOther: { en: "The computer’s clipboard is empty", zh: "电脑的剪贴板是空的" },
  nothingToTakeMac: { en: "Nothing this device can take from the Mac’s clipboard.", zh: "Mac 剪贴板上的内容无法放到本机。" },
  nothingToTakeOther: { en: "Nothing this device can take from the computer’s clipboard.", zh: "电脑剪贴板上的内容无法放到本机。" },
  sendingFilesMac: { en: "Sending {n} files to the Mac…", zh: "正在把 {n} 个文件发送到 Mac…" },
  sendingFilesOther: { en: "Sending {n} files to the computer…", zh: "正在把 {n} 个文件发送到电脑…" },
  copiedToMac: { en: "Copied to the Mac", zh: "已复制到 Mac" },
  copiedToOther: { en: "Copied to the computer", zh: "已复制到电脑" },
  sentMac: { en: "Sent to the Mac", zh: "已发送到 Mac" },
  sentOther: { en: "Sent to the computer", zh: "已发送到电脑" },
  sentSavedMac: { en: "Sent to the Mac · saved in {folder}", zh: "已发送到 Mac · 保存在「{folder}」" },
  sentSavedOther: { en: "Sent to the computer · saved in {folder}", zh: "已发送到电脑 · 保存在「{folder}」" },
  copiedOnMac: { en: "Copied on the Mac", zh: "在 Mac 上复制" },
  copiedOnOther: { en: "Copied on the computer", zh: "在电脑上复制" },
  copiedOnWhenMac: { en: "Copied on the Mac · {when}", zh: "在 Mac 上复制 · {when}" },
  copiedOnWhenOther: { en: "Copied on the computer · {when}", zh: "在电脑上复制 · {when}" },
  copiedHintMac: { en: "Copied on Mac: {what} — Copy here", zh: "Mac 上拷贝了：{what} — 复制到本机" },
  copiedHintOther: { en: "Copied on computer: {what} — Copy here", zh: "电脑上拷贝了：{what} — 复制到本机" },
  phoneHintMac: { en: "This device’s clipboard: {kind} — Paste on Mac", zh: "本机剪贴板：{kind} — 粘贴到 Mac" },
  phoneHintOther: { en: "This device’s clipboard: {kind} — Paste on Computer", zh: "本机剪贴板：{kind} — 粘贴到电脑" },
  sendFooterMac: {
    en: "Text and links go onto the Mac’s clipboard. Photos and files are saved to its Downloads folder and copied there too.",
    zh: "文本和链接会放到 Mac 的剪贴板上；照片和文件会保存到 Mac 的「下载」文件夹，并同时复制到剪贴板。",
  },
  sendFooterOther: {
    en: "Text and links go onto the computer’s clipboard. Photos and files are saved to its Downloads folder and copied there too.",
    zh: "文本和链接会放到电脑的剪贴板上；照片和文件会保存到电脑的「下载」文件夹，并同时复制到剪贴板。",
  },
  sendTextFooterMac: { en: "Text and links go onto the Mac’s clipboard.", zh: "文本和链接会放到 Mac 的剪贴板上。" },
  sendTextFooterOther: { en: "Text and links go onto the computer’s clipboard.", zh: "文本和链接会放到电脑的剪贴板上。" },
  folderOnMac: { en: "Folder · copy its contents on the Mac", zh: "文件夹 · 请在 Mac 上复制其中的内容" },
  folderOnOther: { en: "Folder · copy its contents on the computer", zh: "文件夹 · 请在电脑上复制其中的内容" },
  copySomethingMac: { en: "Copy something on the Mac and it shows up here.", zh: "在 Mac 上复制点什么，就会显示在这里。" },
  copySomethingOther: { en: "Copy something on the computer and it shows up here.", zh: "在电脑上复制点什么，就会显示在这里。" },
  // clipboard: items
  clipboardUnavailable: { en: "Clipboard unavailable", zh: "剪贴板不可用" },
  clipboardNotAvailable: { en: "Clipboard not available", zh: "剪贴板不可用" },
  clipboardCantShare: { en: "This computer can’t share its clipboard.", zh: "这台电脑无法共享剪贴板。" },
  couldNotReadClipboard: { en: "Couldn’t read the clipboard", zh: "无法读取剪贴板" },
  empty: { en: "Empty", zh: "空" },
  text: { en: "Text", zh: "文本" },
  textWord: { en: "text", zh: "文字" },
  link: { en: "Web link", zh: "链接" },
  linkWord: { en: "link", zh: "链接" },
  image: { en: "Image", zh: "图片" },
  imageWord: { en: "image", zh: "图片" },
  imageSized: { en: "Image · {w}×{h}", zh: "图片 · {w}×{h}" },
  textSized: { en: "Text · {size}", zh: "文本 · {size}" },
  textQuoted: { en: "Text · “{text}”", zh: "文字 · “{text}”" },
  nFiles: { en: "{n} files", zh: "{n} 个文件" },
  nFilesNamed: { en: "{n} files · {names}", zh: "{n} 个文件 · {names}" },
  andMore: { en: "and {n} more not listed", zh: "还有 {n} 个未列出" },
  hiddenPasswordManager: { en: "Hidden (password manager)", zh: "已隐藏（密码管理器）" },
  hiddenByPasswordManager: { en: "Hidden by a password manager", zh: "已被密码管理器隐藏" },
  hiddenExplained: { en: "A password manager marked this item hidden; it can’t be read from here.", zh: "密码管理器将此项标记为隐藏，无法从这里读取。" },
  cantBeShown: { en: "Something that can’t be shown here", zh: "无法在此显示的内容" },
  sentFromHere: { en: "Sent from this device", zh: "从本机发送" },
  sentFromHereWhen: { en: "Sent from this device · {when}", zh: "从本机发送 · {when}" },
  copiedByAgent: { en: "Copied by an agent", zh: "由智能体复制" },
  copiedByAgentWhen: { en: "Copied by an agent · {when}", zh: "由智能体复制 · {when}" },
  copiedByName: { en: "Copied by {name}", zh: "由 {name} 复制" },
  copiedByNameWhen: { en: "Copied by {name} · {when}", zh: "由 {name} 复制 · {when}" },
  justNow: { en: "just now", zh: "刚刚" },
  nothingCopiedHere: { en: "Nothing copied on this device", zh: "本机上没有拷贝内容" },
  nothingToPaste: { en: "Nothing to paste: copy something on this device first.", zh: "没有可粘贴的内容：请先在本机复制点什么。" },
  clipboardReadRefused: { en: "This browser didn’t allow reading the clipboard.", zh: "浏览器没有允许读取剪贴板。" },
  clipboardWriteRefused: { en: "This browser didn’t allow writing to the clipboard.", zh: "浏览器没有允许写入剪贴板。" },
  textTooLong: { en: "Too long to copy (max 1 MB).", zh: "文本太长，无法复制（最多 1 MB）。" },
  tooManyFiles: { en: "At most {n} files at a time.", zh: "一次最多 {n} 个文件。" },
  fileTooLarge: { en: "{name} is too large (max {limit}).", zh: "{name} 太大了（上限 {limit}）。" },
  copy: { en: "Copy", zh: "拷贝" },
  copied: { en: "Copied", zh: "已拷贝" },
  share: { en: "Share", zh: "分享" },
  download: { en: "Download", zh: "下载" },
  copying: { en: "Copying…", zh: "正在复制…" },
  loading: { en: "Loading…", zh: "正在读取…" },
  uploadingFiles: { en: "Uploading {n} files…", zh: "正在上传 {n} 个文件…" },
  downloadingOf: { en: "Downloading {i} of {n}…", zh: "正在下载第 {i} 个，共 {n} 个…" },
  foldersLeftOut: { en: "Folders were left out.", zh: "文件夹未包含在内。" },
  pasteRowDetail: { en: "What you copied on this device: text, a link or an image", zh: "本机复制的内容：文本、链接或图片" },
  dropFilesHere: { en: "Drop files here to send them", zh: "把文件拖到这里即可发送" },
  showsWholeText: { en: "Show all", zh: "显示全部" },
  showsFirstLines: { en: "Show less", zh: "收起" },
  // the preview row
  watchMac: { en: "Watch the Mac, or take control", zh: "查看 Mac 的画面，或接管操作" },
  watchOther: { en: "Watch the desktop, or take control", zh: "查看桌面，或接管操作" },
  // errors
  httpStatus: { en: "The server returned HTTP {code}.", zh: "服务器返回 HTTP {code}。" },
} as const satisfies Record<string, { en: string; zh: string }>;

export type StringKey = keyof typeof STRINGS;

/** The browser's language as one of the pages' (zh* → zh-Hans, else English). */
export function browserLanguage(): Language {
  const langs = typeof navigator !== "undefined" ? (navigator.languages ?? [navigator.language]) : [];
  return langs.some((l) => /^zh\b/i.test(l ?? "")) ? "zh-Hans" : "en";
}

/** The pages' words in one language, with a host's overrides, for a Mac or another computer. */
export class Words {
  readonly language: Language;
  readonly locale: string;
  readonly agentName: string | null;
  private readonly overrides: Partial<Record<string, string>>;
  /** The computer is a Mac (its words; `c()` picks the `…Mac` keys). */
  mac = true;

  constructor(host: ScreenHost = {}) {
    this.language = host.language ?? browserLanguage();
    this.locale = host.locale ?? (this.language === "zh-Hans" ? "zh-CN" : "en");
    this.agentName = host.agentName ?? null;
    this.overrides = host.strings ?? {};
  }

  /** `key`'s words with `{name}` placeholders filled. */
  t(key: StringKey, vars: Record<string, string | number> = {}): string {
    const own = this.overrides[key];
    const base = own ?? (this.language === "zh-Hans" ? STRINGS[key].zh : STRINGS[key].en);
    return base.replace(/\{(\w+)\}/g, (m, k: string) => (k in vars ? String(vars[k]) : m));
  }

  /** The Mac's or the other computer's variant of `stem` (`stem + "Mac"` / `stem + "Other"`). */
  c(stem: string, vars: Record<string, string | number> = {}): string {
    return this.t(`${stem}${this.mac ? "Mac" : "Other"}` as StringKey, vars);
  }

  /** A number in the locale. */
  num(n: number): string {
    return new Intl.NumberFormat(this.locale).format(n);
  }

  /** "95 MB" in the locale. */
  bytes(n: number): string {
    const units = ["B", "KB", "MB", "GB"];
    let v = n, i = 0;
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000;
      i++;
    }
    return `${new Intl.NumberFormat(this.locale, { maximumFractionDigits: i === 0 || v >= 10 ? 0 : 1 }).format(v)} ${units[i]}`;
  }

  /** "just now" under a minute, else "2 min. ago". */
  relative(at: number, now = Date.now()): string {
    const age = (now - at) / 1000;
    if (age < 60) return this.t("justNow");
    const rtf = new Intl.RelativeTimeFormat(this.locale, { numeric: "auto", style: "short" });
    if (age < 3600) return rtf.format(-Math.floor(age / 60), "minute");
    if (age < 86400) return rtf.format(-Math.floor(age / 3600), "hour");
    return rtf.format(-Math.floor(age / 86400), "day");
  }

  /** screen-web's `ScreenStrings` (the connection phases) in these words. */
  screenStrings(): ScreenStrings {
    const pick = (host: Host, stem: string) => this.t(`${stem}${host === "mac" ? "Mac" : "Other"}` as StringKey);
    return {
      connecting: this.t("connecting"),
      reconnecting: this.t("reconnecting"),
      unavailable: (host) => pick(host, "unavailable"),
      unavailableDetail: (host) => pick(host, "unavailableDetail"),
      reason: (reason, host) => {
        switch (reason) {
          case "helper-restart":
            return pick(host, "reasonHelperRestart");
          case "timeout":
            return pick(host, "reasonTimeout");
          case "helper-down":
            return pick(host, "reasonHelperDown");
          case "no-session":
            return host === "mac" ? this.t("reasonNoSession") : null;
          case "no-permission":
            return host === "mac" ? this.t("reasonNoPermission") : null;
          default:
            return null;
        }
      },
    };
  }
}
