import {
  ClickGate,
  CursorModel,
  deviceName,
  hasVideoDecoder,
  InputQueue,
  keyInput,
  mainDisplay,
  modifiersOf,
  PASTE_KEY,
  phaseText,
  resetField,
  textInput,
  TouchGestures,
  wheelDelta,
  type CursorPart,
  type Display,
  type Input,
  type Modifier,
  type TouchAction,
} from "@yoyocontrol/screen-web";
import { ClipboardActions, ClipboardHints, ClipboardMarks, ClipboardState, clipboardSupported, DEFAULT_FILE_LIMIT, HINT_DURATION_MS, type ClipboardHint, type PhoneKind } from "./clipboard-model.js";
import type { ClipboardPut, ScreenBackend, ScreenEvent, ScreenHost, ScreenStatus } from "./contracts.js";
import { caughtUp, GestureHints, Loupe, pageLayout, pointerGrow, TwoFingerScroll, Zoom, type Axis, type DragStep, type Point, type Rect, type ScrollStep, type Size } from "./gestures.js";
import { FALLBACK_POINTER, FALLBACK_POINTER_SIZE, ICONS, type IconName } from "./icons.js";
import { Drop } from "./drop.js";
import { LoupeView } from "./loupe.js";
import { ScreenSession } from "./session.js";
import { Words, type StringKey } from "./strings.js";
import { COMMON, SCREEN_STYLE, THEME } from "./styles.js";
import { TrackpadGestures, type Click, type TrackpadHost } from "./trackpad.js";
import { ControlModel, controlAnswer, controlledElsewhere, controlPill } from "./viewer.js";
import { tagNames, type YoyoClipboardElement } from "./clipboard-element.js";

/**
 * `<yoyo-screen>`: a computer's screen, live, as the iOS kit's Screen page (ios/YoyoKit/Sources/YoyoScreen,
 * docs/PROTOCOL.md「屏幕」). Give it a `backend` (and optionally a `host`); it fills its box.
 *
 * The stream shows in a zoomable picture (screen-web's `VideoStream`: H.264 on WebCodecs, acks, smooth playout, a
 * client-drawn pointer). While the picture is on its way back the last one stays dimmed with why; a display that can't
 * be shown says why, with Retry; a missing permission says so, with "Request permissions". The page opens as a viewer
 * and takes the screen only at a real input — the first touch on the trackpad or the picture, a click, a scroll on
 * the picture, the keyboard button, a key or typed text, a paste into the computer (`controlAnswer`; the user wins over
 * automation then). Opening, zooming or panning the picture, full screen and turning the phone never take it, so an
 * agent working between short idle gaps isn't stopped by someone who only watches. While the page doesn't control, a
 * pill at the top says who holds it with an explicit button ("View only · Take Control", "Agent is using the screen ·
 * Take Over", "<name> is controlling · Take Over": another device's control only goes this way; in full screen the
 * button leaves full screen into control; a phone turned to landscape shows the badge alone). Touch devices get the iOS trackpad under the picture (`trackpad`
 * mode: `TrackpadGestures`) or a direct touch mode (tap where you click), switched on the bar, each with its gesture
 * card that opens by itself the first time; the picture pinches to zoom (the shown part follows the pointer), a double
 * tap fits it; while a finger works, the liquid-drop loupe magnifies around the pointer; a three-finger tap shows the
 * stats line. Mouse-and-keyboard devices click, drag, scroll and type on the picture itself. The soft keyboard comes
 * with a key bar (sticky ⌘ ⇧ ⌥ ⌃, Esc, Tab, arrows, the clipboard's two verbs, hide) and comes up by itself when a
 * click focuses a text field (`focus`). The bar: close, gestures, mode, display | clipboard, sound, keyboard. Full
 * screen: on a phone the picture alone, view only (control given back), also when the phone is turned to landscape;
 * on a desktop the element fills the screen and keeps control. Leaving the page (hidden, the back-forward cache)
 * gives control back and closes the stream.
 *
 * The close button shows with `host.onClose` or the `closable` attribute. Events (bubbling, composed): `yoyo-close`, `yoyo-control` (`detail: { controller, mine }`), `yoyo-status`
 * (`detail: ScreenStatus`).
 */

type Mode = "trackpad" | "touch" | "mouse";
type Modifiers = Set<Modifier>;

const STATUS_EVERY_MS = 10_000;
const FOCUS_LOOKS_MS = [250, 650, 1500];
const CHROME_FADE_MS = 3000;
const KEY_HOLD_MS = 500;

const coarse = () => typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;
const reducedMotion = () => typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
const reducedTransparency = () => typeof matchMedia === "function" && (matchMedia("(prefers-reduced-transparency: reduce)").matches || matchMedia("(prefers-contrast: more)").matches);

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls?: string, html?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html !== undefined) e.innerHTML = html;
  return e;
}

function place(e: HTMLElement, r: Rect): void {
  const s = e.style;
  s.left = `${r.x}px`;
  s.top = `${r.y}px`;
  s.width = `${r.width}px`;
  s.height = `${r.height}px`;
}

function errorText(e: unknown, words: Words): string {
  if (e instanceof Error && e.message) return e.message;
  const status = (e as { status?: unknown } | null)?.status;
  return typeof status === "number" ? words.t("httpStatus", { code: status }) : String(e);
}

export class YoyoScreenElement extends HTMLElement {
  private _backend: ScreenBackend | null = null;
  private _host: ScreenHost = {};
  private words = new Words();
  private built = false;
  private root!: ShadowRoot;

  // views
  private stage!: HTMLDivElement;
  private probe!: HTMLDivElement;
  private pad!: HTMLDivElement;
  private padHint!: HTMLDivElement;
  private clip!: HTMLDivElement;
  private zoomLayer!: HTMLDivElement;
  private canvas!: HTMLCanvasElement;
  private dim!: HTMLDivElement;
  private overlay!: HTMLDivElement;
  private cursorImg!: HTMLImageElement;
  private pbadge!: HTMLDivElement;
  private loupe!: LoupeView;
  private fsButton!: HTMLButtonElement;
  private badges!: HTMLDivElement;
  private badge!: HTMLDivElement;
  private vpill!: HTMLDivElement;
  private hintPill!: HTMLButtonElement;
  private zoomHint!: HTMLDivElement;
  private stats!: HTMLDivElement;
  private conn!: HTMLDivElement;
  private spinner!: HTMLDivElement;
  private note!: HTMLDivElement;
  private empty!: HTMLDivElement;
  private bar!: HTMLDivElement;
  private lead!: HTMLDivElement;
  private trail!: HTMLDivElement;
  private buttons!: Record<"close" | "help" | "mode" | "display" | "clipboard" | "sound" | "keyboard", HTMLButtonElement>;
  private toastEl!: HTMLDivElement;
  private keys!: HTMLTextAreaElement;
  private keybar!: HTMLDivElement;
  private keybarButtons = new Map<Modifier, HTMLButtonElement>();
  private clipKeys: HTMLButtonElement[] = [];
  private filePicker!: HTMLInputElement;
  private scrim!: HTMLDivElement;
  private sheet!: HTMLDivElement;
  private menu!: HTMLDivElement;

  // state
  private session: ScreenSession | null = null;
  private status: ScreenStatus | null = null;
  private statusError: unknown = null;
  private displayId: number | undefined;
  private heldByMe = false;
  /** A take of control on its way. */
  private taking: Promise<void> | null = null;
  /** What the real inputs that asked for control wait to do once the take is through (in order; dropped if it fails). */
  private afterTake: (() => void)[] = [];
  private fullScreen = false;
  private desktopFull = false;
  private mode: Mode = "mouse";
  private modifiers: Modifiers = new Set();
  private readonly viewers = new ControlModel();
  private readonly cursor = new CursorModel();
  private cursorPart: CursorPart | null = null;
  private localCursor: { p: Point; at: number } | null = null;
  private lensScale = 1;
  private zoom = new Zoom();
  private pinch: { scale: number; anchor: Point; dist: number } | null = null;
  private followed: Point | null = null;
  private imageSize: Size = { width: 0, height: 0 };
  private layoutBox = { picture: { x: 0, y: 0, width: 0, height: 0 } as Rect, pad: null as Rect | null, wide: false, phoneLandscape: false };
  private hostRect: DOMRect | null = null;
  private trackpad!: TrackpadGestures;
  private input!: InputQueue;
  private clicks!: ClickGate;
  private clickTimer: ReturnType<typeof setTimeout> | null = null;
  private touch!: TouchGestures;
  private touchTimer: ReturnType<typeof setTimeout> | null = null;
  private pictureTouches = new Map<number, { start: Point; pos: Point; t: number }>();
  private pictureTapAt: { t: number; p: Point } | null = null;
  private padPointers = new Set<number>();
  private mouse: { p: Point; cx: number; cy: number; dragging: boolean; mods: Modifier[] } | null = null;
  private suppressClick = false;
  private dragHeld: { display: number | undefined; p: Point } | null = null;
  private composing = false;
  private focusLook: { cancelled: boolean } | null = null;
  private focusUnsupported = false;
  private statusTimer: ReturnType<typeof setInterval> | null = null;
  private statsTimer: ReturnType<typeof setInterval> | null = null;
  private events: AsyncIterator<ScreenEvent> | null = null;
  private chromeFade: ReturnType<typeof setTimeout> | null = null;
  private toastTimer: ReturnType<typeof setTimeout> | null = null;
  private hintTimer: ReturnType<typeof setTimeout> | null = null;
  private zoomHintTimer: ReturnType<typeof setTimeout> | null = null;
  private hint: ClipboardHint | null = null;
  private clipboard: ClipboardState | null = null;
  private clipboardOn = false;
  private unobserveClipboard: (() => void) | null = null;
  private macCountKnown: number | null = null;
  private readonly marks = new ClipboardMarks();
  private clipboardBusy = false;
  private phoneHintAsked = false;
  private activeFlag = false;
  private resize: ResizeObserver | null = null;
  private layoutQueued = false;
  private readonly off: (() => void)[] = [];

  /** The computer this page shows. Setting it (re)starts the page. */
  get backend(): ScreenBackend | null {
    return this._backend;
  }
  set backend(b: ScreenBackend | null) {
    if (b === this._backend) return;
    this.stop(true);
    this._backend = b;
    if (this.isConnected && b) this.start();
  }

  /** The app around the page: theme, words, errors, preferences. */
  get host(): ScreenHost {
    return this._host;
  }
  set host(h: ScreenHost) {
    this._host = h ?? {};
    this.words = new Words(this._host);
    this.words.mac = this.isMac;
    this.applyTheme();
    if (this.built) this.relabel();
  }

  connectedCallback(): void {
    if (!this.built) this.build();
    this.applyTheme();
    if (this._backend && !this.session) this.start();
  }

  disconnectedCallback(): void {
    this.stop(true);
  }

  // ---------------------------------------------------------------- public

  /** Shows / hides the stats line (a three-finger tap does it on touch devices). */
  toggleStats(): void {
    this.stats.hidden = !this.stats.hidden;
    if (!this.stats.hidden) {
      this.session?.statsText();
      this.stats.textContent = " … ";
    }
    this.updateStatsTimer();
  }

  /** The gesture card for the current mode. */
  showGestures(): void {
    this.openCard();
  }

  // ---------------------------------------------------------------- setup

  private get ns(): string {
    return this._host.preferencesNamespace ?? "Yoyo";
  }
  private pref(name: string): string | null {
    try {
      return localStorage.getItem(this.ns + name);
    } catch {
      return null;
    }
  }
  private setPref(name: string, v: string): void {
    try {
      localStorage.setItem(this.ns + name, v);
    } catch {
      /* not kept */
    }
  }
  private get deviceId(): string {
    if (this._host.deviceId) return this._host.deviceId;
    let id = this.pref("DeviceId");
    if (!id || id.length > 128) {
      id = crypto.randomUUID();
      this.setPref("DeviceId", id);
    }
    return id;
  }
  private get device() {
    const name = (this._host.deviceName ?? deviceName(navigator.userAgent)).slice(0, 80);
    return { id: this.deviceId, name };
  }
  private get isMac(): boolean {
    const p = this.status?.platform ?? knownPlatform.get(this._backend?.cacheScope ?? "") ?? this._backend?.platformHint ?? "mac";
    return p === "mac";
  }

  private applyTheme(): void {
    for (const [k, v] of Object.entries(this._host.theme ?? {})) this.style.setProperty(`--yoyo-${k}`, v);
    const cs = this._host.colorScheme;
    if (cs) this.setAttribute("color-scheme", cs);
    else this.removeAttribute("color-scheme");
  }

  private build(): void {
    this.built = true;
    this.root = this.attachShadow({ mode: "open" });
    const style = el("style");
    style.textContent = THEME + COMMON + SCREEN_STYLE;
    const page = el("div", "page");
    page.setAttribute("part", "page");
    this.probe = el("div", "probe");
    this.stage = el("div", "stage");
    this.pad = el("div", "pad");
    this.padHint = el("div", "pad-hint");
    this.pad.append(this.padHint);
    this.clip = el("div", "clip");
    this.zoomLayer = el("div", "zoom");
    this.canvas = el("canvas", "video");
    this.canvas.setAttribute("role", "img");
    this.dim = el("div", "dim");
    this.zoomLayer.append(this.canvas, this.dim);
    this.loupe = new LoupeView();
    this.loupe.onMagnification = (m) => {
      this.lensScale = m;
      this.layoutCursor();
    };
    this.overlay = el("div", "overlay");
    this.cursorImg = el("img", "cursor");
    this.cursorImg.alt = "";
    this.cursorImg.hidden = true;
    this.cursorImg.draggable = false;
    this.pbadge = el("div", "pbadge");
    this.pbadge.hidden = true;
    this.overlay.append(this.cursorImg, this.pbadge);
    this.fsButton = this.roundButton("enterFull", () => this.toggleFullScreen());
    this.fsButton.classList.add("fs", "glass");
    this.clip.append(this.zoomLayer, this.loupe.canvas, this.overlay);
    this.badges = el("div", "badges");
    this.badge = el("div", "badge glass");
    this.vpill = el("div", "vpill glass");
    this.vpill.hidden = true;
    // built once (a render between a press and its click mustn't replace the button); its touches are its own, not
    // the trackpad's or the picture's under it
    this.vpill.innerHTML = `<span class="icon"></span><span class="name"></span><span class="sep">·</span><button type="button" class="take"></button>`;
    // (the stage cancels a touch's default, which would cost the button its click)
    this.vpill.addEventListener("pointerdown", (e) => e.stopPropagation());
    this.vpill.addEventListener("touchstart", (e) => e.stopPropagation(), { passive: true });
    this.vpill.querySelector("button")!.addEventListener("click", (e) => {
      e.stopPropagation();
      this.takeControlTapped();
    });
    this.badges.append(this.badge, this.vpill);
    this.hintPill = el("button", "hint glass");
    this.hintPill.addEventListener("click", () => this.hintTapped());
    this.zoomHint = el("div", "hint zhint glass");
    this.stats = el("div", "stats");
    this.stats.hidden = true;
    this.conn = el("div", "conn glass");
    this.conn.hidden = true;
    this.spinner = el("div", "spinner", `<div class="spin"></div>`);
    this.spinner.hidden = true;
    this.note = el("div", "note glass");
    this.note.hidden = true;
    this.empty = el("div", "empty");
    this.empty.hidden = true;
    this.stage.append(this.pad, this.clip, this.fsButton, this.badges, this.hintPill, this.zoomHint, this.stats, this.conn, this.spinner, this.note, this.empty);

    this.bar = el("div", "bar");
    this.lead = el("div", "group");
    this.trail = el("div", "group");
    this.buttons = {
      close: this.roundButton("close", () => this.close()),
      help: this.roundButton("question", () => this.openCard()),
      mode: this.roundButton("trackpad", () => this.switchMode()),
      display: this.roundButton("display", (b) => this.openDisplayMenu(b)),
      clipboard: this.roundButton("clipboard", (b) => this.openClipboardMenu(b)),
      sound: this.roundButton("speaker", () => this.toggleSound()),
      keyboard: this.roundButton("keyboard", () => this.toggleKeyboard()),
    };
    for (const b of Object.values(this.buttons)) b.classList.add("glass");
    this.lead.append(this.buttons.close, this.buttons.help, this.buttons.mode, this.buttons.display);
    this.trail.append(this.buttons.clipboard, this.buttons.sound, this.buttons.keyboard);
    this.bar.append(this.lead, this.trail);

    this.toastEl = el("div", "toast glass");
    this.toastEl.setAttribute("role", "status");
    this.keys = el("textarea", "keys");
    for (const [k, v] of Object.entries({ autocapitalize: "off", autocomplete: "off", autocorrect: "off", spellcheck: "false", "aria-hidden": "true", enterkeyhint: "enter", tabindex: "-1" })) this.keys.setAttribute(k, v);
    this.keybar = el("div", "keybar");
    this.keybar.hidden = true;
    this.buildKeyBar();
    this.filePicker = el("input");
    this.filePicker.type = "file";
    this.filePicker.multiple = true;
    this.filePicker.hidden = true;
    this.filePicker.addEventListener("change", () => this.picked());
    this.scrim = el("div", "scrim");
    this.scrim.hidden = true;
    this.scrim.addEventListener("click", () => this.closeOverlays());
    this.sheet = el("div", "sheet");
    this.sheet.hidden = true;
    this.sheet.setAttribute("role", "dialog");
    this.menu = el("div", "menu glass");
    this.menu.hidden = true;
    this.menu.setAttribute("role", "menu");
    page.append(this.probe, this.stage, this.bar, this.toastEl, this.keys, this.keybar, this.filePicker, this.scrim, this.sheet, this.menu);
    this.root.append(style, page);

    this.trackpad = new TrackpadGestures(this.trackpadHost());
    this.clicks = new ClickGate((i) => this.send(i));
    this.touch = new TouchGestures(
      (x, y) => this.pictureNormalized({ x, y }),
      () => this.displayPointsPerPx(),
    );
    this.wireEvents();
    this.relabel();
  }

  private roundButton(icon: IconName, action: (b: HTMLButtonElement) => void): HTMLButtonElement {
    const b = el("button", "round", ICONS[icon]);
    b.type = "button";
    b.addEventListener("click", (e) => {
      e.stopPropagation();
      this.session?.gesture();
      action(b);
    });
    return b;
  }

  private setIcon(b: HTMLButtonElement, icon: IconName): void {
    const dot = b.querySelector(".dot");
    b.innerHTML = ICONS[icon];
    if (dot) b.append(dot);
  }

  /** Words that follow the language and whose computer it is. */
  private relabel(): void {
    const w = this.words;
    w.mac = this.isMac;
    const label = (b: HTMLButtonElement, key: StringKey) => {
      b.setAttribute("aria-label", w.t(key));
      b.title = w.t(key);
    };
    label(this.buttons.close, "close");
    label(this.buttons.help, "gestures");
    label(this.buttons.display, "display");
    label(this.buttons.clipboard, "clipboard");
    label(this.buttons.keyboard, "keyboard");
    this.canvas.setAttribute("aria-label", w.c("pictureLabel"));
    this.updateModeButton();
    this.updateSoundButton();
    this.updateFsButton();
    this.relabelKeyBar();
  }

  // ---------------------------------------------------------------- lifecycle

  private start(): void {
    const backend = this._backend;
    if (!backend || this.session) return;
    this.words.mac = this.isMac;
    this.mode = coarse() ? (this.pref("TouchMode") === "touch" ? "touch" : "trackpad") : "mouse";
    this.session = new ScreenSession(
      backend,
      { canvas: this.canvas, audioKey: this.ns + "Audio" },
      {
        picture: (w, h) => this.pictureArrived(w, h),
        cursor: (c) => this.cursorArrived(c),
        streamOpened: () => {
          this.cursor.streamOpened();
          this.cursorPart = null;
        },
        connection: () => this.renderConnection(),
        audio: () => this.updateSoundButton(),
        refreshStatus: () => void this.refreshStatus(),
        handleError: (e) => this.handleError(e),
      },
    );
    // over a link input goes at once into its media layer (merged per turn); over HTTP one request at a time
    this.input = new InputQueue(
      (i) => this.session!.deliver(i),
      (e) => this.inputFailed(e),
      Date.now(),
      undefined,
      { link: () => this.session?.linkInput((e) => this.inputFailed(e)) ?? null },
    );
    this.session.newVisit();
    this.focusUnsupported = false;
    this.resize = new ResizeObserver(() => this.queueLayout());
    this.resize.observe(this);
    this.listen();
    this.layout();
    this.render();
    this.updateClipboardCapability();
    if (document.visibilityState !== "hidden") this.activate();
  }

  /** The page stops for good (`release`: control goes back). */
  private stop(release: boolean): void {
    if (!this.session) return;
    this.deactivate(release);
    this.session.dispose();
    this.session = null;
    this.resize?.disconnect();
    this.resize = null;
    this.unobserveClipboard?.();
    this.unobserveClipboard = null;
    this.clipboard = null;
    this.clipboardOn = false;
    this.loupe.stop();
    for (const f of this.off.splice(0)) f();
  }

  private activate(): void {
    const s = this.session;
    if (!s || this.activeFlag) return;
    this.activeFlag = true;
    this.statusTimer = setInterval(() => void this.refreshStatus(), STATUS_EVERY_MS);
    s.activate();
    this.followEvents();
    void this.refreshStatus();
    this.updateStatsTimer();
    this.phoneHintAsked = false;
    void this.showPhoneHintIfNew();
    this.updateClipboardDot();
  }

  private deactivate(release: boolean): void {
    const s = this.session;
    if (!s || !this.activeFlag) return;
    this.activeFlag = false;
    s.deactivate();
    this.stopEvents();
    this.hideHint();
    if (this.statusTimer) clearInterval(this.statusTimer);
    this.statusTimer = null;
    this.updateStatsTimer();
    this.trackpad.reset();
    this.liftDrag();
    this.input?.cancel();
    this.clicks.cancel();
    this.touch.cancel();
    this.dropFocusLook();
    if (release) this.releaseControl(true);
    s.leaveRoute();
  }

  /** The element's own listeners (once, as it is built). */
  private wireEvents(): void {
    const st = this.stage;
    st.addEventListener("pointerdown", (e) => this.pointerDown(e));
    st.addEventListener("pointermove", (e) => this.pointerMove(e));
    st.addEventListener("pointerup", (e) => this.pointerUp(e, false));
    st.addEventListener("pointercancel", (e) => this.pointerUp(e, true));
    st.addEventListener("click", (e) => this.mouseClick(e));
    st.addEventListener("contextmenu", (e) => this.contextMenu(e));
    st.addEventListener("wheel", (e) => this.wheel(e), { passive: false });
    st.addEventListener("touchstart", (e) => e.preventDefault(), { passive: false });
    const k = this.keys;
    k.addEventListener("keydown", (e) => this.keyDown(e));
    k.addEventListener("input", (e) => this.typedInput(e as InputEvent));
    k.addEventListener("compositionstart", () => (this.composing = true));
    k.addEventListener("compositionend", (e) => this.compositionEnd(e));
    k.addEventListener("focus", () => this.keyboardShown(true));
    k.addEventListener("blur", () => this.keyboardShown(false));
  }

  /** The page's listeners on the document and the window (while it runs). */
  private listen(): void {
    const on = (t: EventTarget, type: string, fn: (e: Event) => void, opts?: AddEventListenerOptions) => {
      t.addEventListener(type, fn, opts);
      this.off.push(() => t.removeEventListener(type, fn, opts));
    };
    on(document, "visibilitychange", () => {
      if (document.visibilityState === "hidden") this.deactivate(true);
      else this.activate();
    });
    on(window, "pagehide", () => this.deactivate(true));
    on(window, "pageshow", (e) => {
      if ((e as PageTransitionEvent).persisted) this.activate();
    });
    on(document, "fullscreenchange", () => this.fullscreenChanged());
    on(document, "focusout", () => this.refocusKeys());
    on(window, "resize", () => this.queueLayout());
    const vv = window.visualViewport;
    if (vv) {
      on(vv, "resize", () => this.placeKeyBar());
      on(vv, "scroll", () => this.placeKeyBar());
    }
  }

  private close(): void {
    this.dispatchEvent(new CustomEvent("yoyo-close", { bubbles: true, composed: true }));
    this._host.onClose?.();
  }

  // ---------------------------------------------------------------- status

  private async refreshStatus(): Promise<void> {
    const b = this._backend;
    if (!b || !this.session) return;
    try {
      this.apply(await b.status());
    } catch (e) {
      if (this.handleError(e)) return;
      if (!this.status || (e as { status?: number }).status === 404) {
        this.status = null;
        this.statusError = e;
        this.session.canShow = false;
        this.session.stopFrames();
        this.render();
      }
    }
  }

  private apply(answer: ScreenStatus): void {
    const s0 = this.session;
    const b = this._backend;
    if (!s0 || !b) return;
    // what the computer is and can do (an answer that doesn't say keeps what an earlier one said)
    const known = noteCapabilities(answer, b.cacheScope);
    const wasMac = this.isMac;
    const s: ScreenStatus = known.platform && known.platform !== "mac" ? { ...known, screenRecording: true, accessibility: true } : known;
    this.status = s;
    this.statusError = null;
    if (this.isMac !== wasMac) this.relabel();
    if (this.displayId !== undefined && !s.displays.some((d) => d.id === this.displayId)) {
      const main = mainDisplay(s);
      if (s0.displayIsMain && main?.main) this.displayId = main.id;
      else {
        this.displayId = undefined;
        s0.display = undefined;
        s0.restartFrames();
      }
    }
    if (this.displayId === undefined) this.displayId = mainDisplay(s)?.id;
    s0.display = this.displayId;
    s0.displayIsMain = this.currentDisplay?.main ?? true;
    s0.displayIsVirtual = this.currentDisplay?.kind === "virtual";
    const effect = this.viewers.status(s.controller, s.controllerDevice, s.controllerSince, this.deviceId);
    if (effect) this.tookOver(effect.tookOver);
    if (s.controller !== "user" || this.viewers.isViewer) this.heldByMe = false;
    s0.canShow = this.canShow;
    s0.statusChanged(s);
    this.updateClipboardCapability();
    this.render();
    s0.updateFrames();
    s0.updateConnection();
    this.dispatchEvent(new CustomEvent("yoyo-status", { bubbles: true, composed: true, detail: s }));
  }

  private get currentDisplay(): Display | null {
    return this.status ? (this.status.displays.find((d) => d.id === this.displayId) ?? mainDisplay(this.status)) : null;
  }
  private get canShow(): boolean {
    return this.status?.available === true && this.status.screenRecording === true;
  }
  private get canControl(): boolean {
    return this.canShow && this.status?.accessibility === true;
  }
  private get viewOnly(): boolean {
    return this.fullScreen || this.layoutBox.phoneLandscape;
  }
  /** Taps and keys go to the computer. */
  private get controlling(): boolean {
    return this.canControl && !this.viewOnly && this.status?.controller === "user" && !this.viewers.isViewer;
  }
  /** A real input would take the screen now (not view only, not watching another device's control). */
  private get canTake(): boolean {
    return this.canControl && !this.viewOnly && !this.viewers.isViewer;
  }

  /** A real input (the first touch on the trackpad or the picture, a click, a scroll, the keyboard button, a key, typed
   *  text, a paste into the computer): in control, `then` runs now; else the page takes the screen if it can (over the
   *  agent too: the user wins) and `then` runs once it controls. Watching another device's control, the Take Over pill
   *  is nudged (only it takes the screen then). Nothing else takes the screen. */
  private userInput(then?: () => void): void {
    switch (controlAnswer(this.controlling, this.viewers.isViewer, this.canTake)) {
      case "go":
        then?.();
        break;
      case "nudge":
        this.nudgePill();
        break;
      case "take":
        void this.setControl(then);
        break;
    }
  }

  private followEvents(): void {
    const b = this._backend;
    if (this.events || !b?.events) return;
    const it = b.events()[Symbol.asyncIterator]();
    this.events = it;
    void (async () => {
      try {
        for (;;) {
          const { value, done } = await it.next();
          if (done || this.events !== it) break;
          this.event(value);
        }
      } catch {
        /* the subscription ended */
      }
      if (this.events === it) this.events = null;
    })();
  }

  private stopEvents(): void {
    const it = this.events;
    this.events = null;
    void it?.return?.();
  }

  private event(e: ScreenEvent): void {
    if (!this.status) return;
    if (e.type === "screen.control") {
      this.status = { ...this.status, controller: e.controller, controllerSince: e.controllerSince ?? null, controllerDevice: e.controller === "user" ? (e.controllerDevice ?? null) : null };
      const effect = this.viewers.status(e.controller, e.controllerDevice, e.controllerSince, this.deviceId);
      if (effect) this.tookOver(effect.tookOver);
      if (e.controller !== "user" || this.viewers.isViewer) this.heldByMe = false;
      this.render();
    } else if (e.type === "screen.state") {
      this.status = { ...this.status, states: e.states, console: e.console ?? null };
      this.session?.statesChanged(e.states, e.console);
      this.updateDisplayButton();
    } else if (e.type === "pairing" && e.open) {
      // the window stays out of the remote picture: say so, or the click on "Pair iPhone" looks like nothing
      this.toast(this.words.t("pairingOpen"), 6000);
    }
  }

  // ---------------------------------------------------------------- control

  /** The pill's button (Take Control / Take Over: explicit, so another device's control too). In full screen: back to
   *  the page first, then the take. */
  private takeControlTapped(): void {
    this.vibrate(8);
    if (this.fullScreen) this.setFullScreen(false);
    void this.setControl();
  }

  /** Takes the screen (at a real input, or the pill's button), then runs `then` if it controls. Given back with `releaseControl`. */
  private setControl(then?: () => void): Promise<void> {
    if (then) this.afterTake.push(then);
    if (this.taking) return this.taking;
    const s = this.session;
    if (!s) {
      this.afterTake = [];
      return Promise.resolve();
    }
    const take = (async () => {
      try {
        const st = await s.control("user", this.device);
        if (!st) return;
        const effect = this.viewers.took(st.controller, st.controllerDevice, st.controllerSince, this.deviceId);
        if (effect) this.tookOver(effect.tookOver);
        this.heldByMe = st.controller === "user" && !this.viewers.isViewer;
        this.apply(st);
        if (this.viewOnly || !this.activeFlag) {
          this.releaseControl(false);
          return;
        }
        this.vibrate(10);
        // what asked for control goes now (a key typed, a click made while the take was on its way)
        const waiting = this.afterTake;
        this.afterTake = [];
        if (this.controlling) for (const f of waiting) f();
        if (this.heldByMe) this.showCardOnce();
      } catch (e) {
        if (this.handleError(e)) return;
        this.toast(errorText(e, this.words));
        this.render();
        void this.refreshStatus();
      } finally {
        this.taking = null;
        this.afterTake = [];
      }
    })();
    this.taking = take;
    return take;
  }

  /** Gives the screen back if this page took it (`leaving`: the page may be going away — keepalive). */
  private releaseControl(leaving: boolean): void {
    if (!this.heldByMe || !this.session) return;
    this.heldByMe = false;
    const route = this.session.way;
    void this.session.control("none", this.device, leaving, route).catch(() => {});
    if (this.status?.controller === "user") this.status = { ...this.status, controller: "none", controllerDevice: null };
    this.render();
  }

  private tookOver(name: string | null): void {
    this.vibrate([20, 60, 20]);
    this.toast(this.words.t("tookOver", { name: ControlModel.displayName(name, this.words) }));
  }

  // ---------------------------------------------------------------- render

  private render(): void {
    if (!this.session) return;
    const w = this.words;
    const showing = this.canShow;
    const controlling = this.controlling;
    this.clip.hidden = !showing;
    this.session.canShow = showing;
    // the badge, or while this page doesn't control (and could) the pill with the button that takes it; a phone
    // turned to landscape is view only with no way back from here: the badge alone
    const agent = w.agentName ? w.t("badgeAgentNamed", { name: w.agentName }) : w.t("badgeAgent");
    const pill = controlPill(controlling, this.canControl && !this.layoutBox.phoneLandscape, this.viewers.role);
    this.vpill.hidden = !pill;
    if (pill) {
      const [icon, label, title] =
        pill.t === "other"
          ? [ICONS.device, w.t("isControlling", { name: ControlModel.displayName(pill.name, w) }), w.t("takeOver")]
          : pill.t === "agent"
            ? [ICONS.sparkle, agent, w.t("takeOver")]
            : [ICONS.eye, w.t("badgeViewOnly"), w.t("takeControl")];
      this.vpill.classList.toggle("free", pill.t === "free");
      this.vpill.classList.toggle("agent", pill.t === "agent");
      this.vpill.classList.toggle("other", pill.t === "other");
      const iconBox = this.vpill.querySelector(".icon")!;
      if (iconBox.innerHTML !== icon) iconBox.innerHTML = icon;
      this.vpill.querySelector(".name")!.textContent = label;
      this.vpill.querySelector("button")!.textContent = title;
    }
    const c = this.viewers.isViewer ? "none" : (this.status?.controller ?? "none");
    this.badge.hidden = !showing || !!pill;
    this.badge.className = `badge glass ${c === "agent" ? "agent" : c === "user" ? "user" : "none"}`;
    const [icon, text] = c === "agent" ? [ICONS.sparkle, agent] : c === "user" ? [ICONS.handTap, w.t("badgeYou")] : [ICONS.eye, w.t("badgeViewOnly")];
    this.badge.innerHTML = `${icon}<span></span>`;
    this.badge.querySelector("span")!.textContent = text;
    // the pad's hint: watching (the page opens so), what takes the screen
    const watching = !controlling && this.canTake ? this.status?.controller : undefined;
    const watchHint = watching === "agent" ? "agentTouchToTakeOver" : watching === "none" ? "touchToControl" : null;
    // until the pad was used once: what it is (people tap the picture and think the input is broken)
    const padNew = controlling && this.mode === "trackpad" && this.pref("PadUsed") !== "1";
    const padText = watchHint ?? (padNew ? "padHere" : null);
    this.padHint.innerHTML = padText ? `${ICONS.trackpad}<span></span>` : "";
    if (padText) this.padHint.querySelector("span")!.textContent = w.t(padText);
    if (!controlling) {
      this.session.interactivity.reset();
      if (this.trackpad.drag.isPressed) this.trackpad.reset();
      this.input?.cancel();
      this.clicks.cancel();
      this.touch.cancel();
      // (watching with a mouse and keyboard, the keys stay where typing goes: a key takes the screen; a soft keyboard
      // brought up by its button stays while the take is on its way)
      if (this.isKeyboardUp && !this.taking && (this.mode !== "mouse" || !this.canTake)) this.keys.blur();
      if (this.modifiers.size) {
        this.modifiers.clear();
        this.updateModifierKeys();
      }
    }
    // in control, or watching with nobody else's control in the way (the keyboard takes the screen then)
    this.buttons.keyboard.disabled = !controlling && !this.canTake;
    this.fsButton.disabled = !showing && !this.viewOnly;
    // the permission note
    this.note.hidden = !(showing && this.status?.accessibility === false);
    if (!this.note.hidden) {
      this.note.innerHTML = `<span></span>`;
      this.note.querySelector("span")!.textContent = w.t("accessibilityNote");
      const b = el("button", "prominent small");
      b.textContent = w.t("requestPermissions");
      b.addEventListener("click", () => this.requestPermissions());
      this.note.append(b);
    }
    this.renderEmpty();
    this.updateDisplayButton();
    this.updateChrome();
    this.renderConnection();
    this.updateLoupe();
    this.layoutCursor();
    this.dispatchEvent(new CustomEvent("yoyo-control", { bubbles: true, composed: true, detail: { controller: this.status?.controller ?? "none", mine: controlling } }));
    if ((controlling || this.canTake) && !coarse()) this.refocusKeys(true);
  }

  /** What shows instead of the picture: loading, unreachable, unavailable, the Screen Recording permission. */
  private renderEmpty(): void {
    const w = this.words;
    const e = this.empty;
    if (this.canShow) {
      e.hidden = true;
      return;
    }
    e.hidden = false;
    e.innerHTML = "";
    const s = this.status;
    const parts: { icon: IconName | null; title: string; detail?: string; button?: { text: string; run: () => void; quiet?: boolean } } = s
      ? !s.available
        ? s.unavailableAction
          ? { icon: "warning", title: s.unavailableAction.headline ?? w.c("unavailable"), detail: s.unavailableAction.message ?? s.reason ?? w.c("unavailableDetail"), button: { text: s.unavailableAction.title, run: () => window.open(s.unavailableAction!.url, "_blank", "noopener") } }
          : { icon: "warning", title: w.c("unavailable"), detail: s.reason ?? w.c("unavailableDetail") }
        : { icon: "record", title: w.t("recordingNeeded"), detail: w.t("recordingNeededDetail"), button: { text: w.t("requestPermissions"), run: () => this.requestPermissions() } }
      : this.statusError
        ? { icon: "wifiOff", title: w.t("couldNotReach"), detail: errorText(this.statusError, w), button: { text: w.t("retry"), run: () => void this.refreshStatus(), quiet: true } }
        : { icon: null, title: "" };
    if (!parts.icon) {
      e.innerHTML = `<div class="spin"></div>`;
      return;
    }
    e.innerHTML = ICONS[parts.icon];
    const t = el("div", "title");
    t.textContent = parts.title;
    e.append(t);
    if (parts.detail) {
      const d = el("div", "detail");
      d.textContent = parts.detail;
      e.append(d);
    }
    if (parts.button) {
      const b = el("button", parts.button.quiet ? "round glass" : "prominent");
      b.textContent = parts.button.text;
      b.addEventListener("click", parts.button.run);
      e.append(b);
    }
  }

  private async requestPermissions(): Promise<void> {
    const b = this._backend;
    if (!b?.requestPermissions) return;
    try {
      this.apply(await b.requestPermissions());
      this.toast(this.words.t("permissionPrompted"));
      setTimeout(() => void this.refreshStatus(), 3000);
    } catch (e) {
      if (!this.handleError(e)) this.toast(errorText(e, this.words));
    }
  }

  private renderConnection(): void {
    const s = this.session;
    if (!s) return;
    const phase = s.phase();
    const showing = this.canShow;
    const live = phase.t === "live";
    const overlay = showing && !live && (s.hasFrame || phase.t !== "reconnecting" || phase.reason !== null);
    this.dim.classList.toggle("on", showing && s.hasFrame && !live);
    this.loupe.dim = showing && s.hasFrame && !live ? 0.45 : 0;
    this.conn.hidden = !overlay;
    if (overlay) {
      const text = phaseText(phase, this.isMac ? "mac" : this.status?.platform === "windows" ? "windows" : "linux", this.words.screenStrings());
      this.conn.innerHTML = phase.t === "unavailable" ? "" : `<div class="spin"></div>`;
      const t = el("div", "title");
      t.textContent = text?.title ?? "";
      this.conn.append(t);
      if (text?.detail) {
        const d = el("div", "detail");
        d.textContent = text.detail;
        this.conn.append(d);
      }
      if (phase.t === "unavailable") {
        const b = el("button", "prominent small");
        b.textContent = this.words.t("retry");
        b.addEventListener("click", () => {
          s.retryConnection();
          void this.refreshStatus();
        });
        this.conn.append(b);
      }
    }
    this.spinner.hidden = !(showing && !s.hasFrame && !overlay);
    if (!hasVideoDecoder() && showing && !this.conn.hidden) return;
    if (!hasVideoDecoder() && showing) {
      this.conn.hidden = false;
      this.spinner.hidden = true;
      this.conn.innerHTML = "";
      const t = el("div", "title");
      t.textContent = this.words.t("noVideo");
      this.conn.append(t);
    }
  }

  private updateChrome(): void {
    const full = this.viewOnly;
    this.bar.hidden = full;
    const touchDevice = this.mode !== "mouse";
    this.buttons.close.hidden = !this._host.onClose && !this.hasAttribute("closable");
    this.buttons.mode.hidden = !touchDevice;
    this.buttons.keyboard.hidden = !touchDevice || this.layoutBox.wide;
    this.buttons.clipboard.hidden = !this.clipboardOn;
    this.buttons.sound.hidden = !this.session?.audioShown || !this.canShow;
    this.fsButton.hidden = !this.canShow || this.layoutBox.phoneLandscape;
    // a mouse over the picture: the computer's pointer is the one that shows
    this.clip.style.cursor = this.mode === "mouse" && this.controlling && this.cursor.drawn ? "none" : "";
    if (full) this.hideHint();
    for (const k of this.clipKeys) k.hidden = !this.clipboardOn;
    this.queueLayout();
  }

  private updateDisplayButton(): void {
    const n = this.status?.displays.length ?? 0;
    this.buttons.display.hidden = !(this.canShow && n > 1) || this.viewOnly;
  }

  // ---------------------------------------------------------------- layout

  private queueLayout(): void {
    if (this.layoutQueued) return;
    this.layoutQueued = true;
    requestAnimationFrame(() => {
      this.layoutQueued = false;
      this.layout();
    });
  }

  /** Portrait: the picture at the top, the trackpad surface under it (the badges at its top), the buttons in a row at
   *  the bottom. Wide: the buttons in a column on each side. Full screen: the picture alone. */
  private layout(): void {
    if (!this.built) return;
    const W = this.clientWidth, H = this.clientHeight;
    if (!(W > 0) || !(H > 0)) return;
    this.hostRect = this.getBoundingClientRect();
    const cs = getComputedStyle(this.probe);
    const safe = { top: parseFloat(cs.paddingTop) || 0, right: parseFloat(cs.paddingRight) || 0, bottom: parseFloat(cs.paddingBottom) || 0, left: parseFloat(cs.paddingLeft) || 0 };
    const wide = W > H;
    const phoneLandscape = this.mode !== "mouse" && wide && H < 520;
    const wasViewOnly = this.viewOnly;
    this.layoutBox.wide = wide;
    this.layoutBox.phoneLandscape = phoneLandscape;
    if (this.viewOnly !== wasViewOnly) this.viewOnlyChanged();
    const full = this.viewOnly;
    const area: Rect = { x: safe.left, y: safe.top, width: W - safe.left - safe.right, height: H - safe.top - safe.bottom };
    this.bar.classList.toggle("column", wide);
    // a row of up to seven buttons: on a narrow phone they close up
    const shown = [...this.lead.children, ...this.trail.children].filter((b) => !(b as HTMLElement).hidden).length;
    const narrow = !wide && shown * 44 + (shown - 2) * 10 + 42 > area.width;
    this.bar.classList.toggle("narrow", narrow);
    const size = narrow ? 40 : 44;
    if (!full) {
      if (!wide) {
        const top = H - safe.bottom - 8 - size;
        Object.assign(this.bar.style, { left: `${safe.left + 16}px`, right: `${safe.right + 16}px`, top: `${top}px`, bottom: "auto", width: "auto", height: `${size}px`, justifyContent: "space-between", flexDirection: "row" });
        area.height = top - 8 - safe.top;
      } else {
        Object.assign(this.bar.style, { left: `${safe.left + 12}px`, right: `${safe.right + 12}px`, top: `${safe.top}px`, bottom: `${safe.bottom}px`, width: "auto", height: "auto", justifyContent: "space-between", flexDirection: "row" });
        this.lead.style.flexDirection = this.trail.style.flexDirection = "column";
        area.x += 12 + size + 8;
        area.width -= 2 * (12 + size + 8);
      }
      if (!wide) this.lead.style.flexDirection = this.trail.style.flexDirection = "row";
    }
    const aspect = this.imageSize.width > 0 && this.imageSize.height > 0 ? this.imageSize.width / this.imageSize.height : this.displayAspect();
    const badgeH = this.badges.offsetHeight || 34;
    const wantsPad = this.mode === "trackpad" && !full && !this.desktopFull;
    const { picture, pad } = pageLayout(area, aspect, wantsPad ? badgeH + 16 : 0, wantsPad);
    this.layoutBox.picture = picture;
    this.layoutBox.pad = pad;
    place(this.clip, picture);
    this.pad.hidden = !pad;
    if (pad) place(this.pad, pad);
    this.padHint.style.marginTop = `${badgeH + 16}px`;
    this.layoutZoom(false);
    // the badges at the top of the surface, else of the picture
    const anchor = pad ?? picture;
    this.badges.style.left = `${anchor.x + anchor.width / 2}px`;
    this.badges.style.top = `${anchor.y + 8}px`;
    const mid = { x: picture.x + picture.width / 2, y: picture.y + picture.height / 2 };
    for (const e of [this.conn, this.spinner]) {
      e.style.left = `${mid.x}px`;
      e.style.top = `${mid.y}px`;
    }
    this.hintPill.style.left = `${mid.x}px`;
    this.hintPill.style.top = `${picture.y + 10}px`;
    this.zoomHint.style.left = `${mid.x}px`;
    this.zoomHint.style.top = `${picture.y + picture.height - 12 - 36}px`;
    this.stats.style.left = `${picture.x + 8}px`;
    this.stats.style.top = `${picture.y + 8}px`;
    this.fsButton.style.left = `${picture.x + picture.width - 8 - 36}px`;
    this.fsButton.style.top = `${picture.y + picture.height - 8 - 36}px`;
    Object.assign(this.note.style, { left: `${safe.left + 12}px`, right: `${safe.right + 12}px`, top: "auto", bottom: `${H - (wide || full ? H - safe.bottom : parseFloat(this.bar.style.top || "0")) + 12}px` });
    this.toastEl.style.bottom = `${(wide || full ? safe.bottom : H - parseFloat(this.bar.style.top || `${H}`)) + 16}px`;
    this.layoutCursor();
    this.placeKeyBar();
  }

  private displayAspect(): number {
    const d = this.currentDisplay;
    return d && d.width > 0 && d.height > 0 ? d.width / d.height : 1.6;
  }

  /** The picture at the zoom, in its clip. */
  private layoutZoom(animated: boolean): void {
    const size = { width: this.layoutBox.picture.width, height: this.layoutBox.picture.height };
    const f = this.zoom.frame(size);
    this.zoomLayer.classList.toggle("animate", animated && !reducedMotion());
    this.zoomLayer.style.width = `${size.width}px`;
    this.zoomLayer.style.height = `${size.height}px`;
    this.zoomLayer.style.transform = `translate3d(${f.x}px, ${f.y}px, 0) scale(${this.zoom.scale})`;
  }

  /** The picture as it shows now (zoomed: bigger than its frame), in its clip's coordinates. */
  private get shown(): Rect {
    return this.zoom.frame({ width: this.layoutBox.picture.width, height: this.layoutBox.picture.height });
  }

  private setZoom(z: Zoom, animated: boolean): void {
    const was = this.zoom.zoomed;
    this.zoom = z;
    this.canvas.setAttribute("aria-valuetext", z.zoomed ? `${z.scale.toFixed(1)}×` : "");
    this.layoutZoom(animated);
    this.layoutCursor();
    if (was !== z.zoomed) this.hideZoomHint();
  }

  private followPointer(): void {
    const p = this.drawnPointer() ?? (this.controlling ? this.trackpad.pointer : null);
    if (!this.zoom.zoomed || this.pinch || !p || (this.followed && p.x === this.followed.x && p.y === this.followed.y)) return;
    this.followed = p;
    const z = this.zoom.copy();
    z.follow(p);
    if (z.equals(this.zoom)) return;
    const jump = Math.hypot((z.center.x - this.zoom.center.x) * this.zoom.scale, (z.center.y - this.zoom.center.y) * this.zoom.scale) > 0.5;
    this.zoom = z;
    this.layoutZoom(jump);
  }

  // ---------------------------------------------------------------- pictures and the pointer

  private pictureArrived(w: number, h: number): void {
    const sameAspect = this.imageSize.width > 0 && Math.abs(this.imageSize.width / this.imageSize.height - w / h) < 0.002;
    if (w !== this.imageSize.width || h !== this.imageSize.height) {
      this.imageSize = { width: w, height: h };
      if (!sameAspect) {
        this.setZoom(new Zoom(), false);
        this.layout();
      }
    }
    if (this.cursor.picture()) this.cursorPart = null;
    this.loupe.setSource(this.canvas);
    this.renderConnection();
    this.spinner.hidden = true;
  }

  private cursorArrived(c: CursorPart): void {
    this.cursor.cursor(c);
    this.cursorPart = c;
    if (this.localCursor) {
      const display = this.displaySize();
      if (caughtUp({ x: c.x, y: c.y }, this.localCursor.p, display) || performance.now() - this.localCursor.at > 600) this.localCursor = null;
    }
    this.layoutCursor();
  }

  /** Where the pointer is drawn now (0…1), null when none is (the pictures carry the computer's own). */
  private drawnPointer(): Point | null {
    if (!this.cursor.drawn) return null;
    if (this.localCursor) return this.localCursor.p;
    const v = this.cursor.view();
    if (!v || !this.cursorPart) return null;
    return { x: this.cursorPart.x, y: this.cursorPart.y };
  }

  /** The pointer goes to `p` at once: this page sent it there. */
  private moveCursor(p: Point): void {
    this.trackpad.pointer = p;
    if (this.cursor.drawn) this.localCursor = { p, at: performance.now() };
    this.layoutCursor();
  }

  private layoutCursor(): void {
    if (!this.built) return;
    this.followPointer();
    const f = this.shown;
    const v = this.cursor.view();
    const part = this.cursorPart;
    if (!v || !part || !(f.width > 0) || !this.canShow) {
      this.cursorImg.hidden = true;
    } else {
      const at = this.localCursor?.p ?? { x: part.x, y: part.y };
      const known = v.url !== null && v.width > 0 && v.height > 0;
      const w0 = known ? v.width : (FALLBACK_POINTER_SIZE.width / FALLBACK_POINTER_SIZE.height) * (20 / f.height) * (f.height / f.width);
      const h0 = known ? v.height : 20 / f.height;
      const hotX = known ? (at.x - v.left - (this.localCursor ? at.x - part.x : 0)) / v.width : FALLBACK_POINTER_SIZE.hotX;
      const hotY = known ? (at.y - v.top - (this.localCursor ? at.y - part.y : 0)) / v.height : FALLBACK_POINTER_SIZE.hotY;
      const display = this.displaySize();
      const grow = known ? pointerGrow(h0, f.height, display.height > 0 ? display.height : null) : 1;
      const w = w0 * grow * f.width * this.lensScale, h = h0 * grow * f.height * this.lensScale;
      const url = v.url ?? FALLBACK_POINTER;
      if (this.cursorImg.getAttribute("src") !== url) this.cursorImg.src = url;
      this.cursorImg.style.width = `${w}px`;
      this.cursorImg.style.height = `${h}px`;
      this.cursorImg.style.transform = `translate3d(${f.x + at.x * f.width - hotX * w}px, ${f.y + at.y * f.height - hotY * h}px, 0)`;
      this.cursorImg.style.setProperty("--hx", `${hotX * 100}%`);
      this.cursorImg.style.setProperty("--hy", `${hotY * 100}%`);
      this.cursorImg.hidden = false;
    }
    this.updateLoupe();
    this.updatePointerBadge();
  }

  private displaySize(): Size {
    const d = this.currentDisplay;
    return d && d.width > 0 ? { width: d.width, height: d.height } : this.imageSize;
  }

  /** A click shows at once where it lands: a ring spreads (Reduce Motion: it only fades). */
  private showClick(p: Point): void {
    const f = this.shown;
    if (!(f.width > 0)) return;
    const r = el("div", "ring");
    r.style.left = `${f.x + p.x * f.width}px`;
    r.style.top = `${f.y + p.y * f.height}px`;
    if (reducedMotion()) r.style.animationName = "none";
    this.overlay.append(r);
    setTimeout(() => r.remove(), reducedMotion() ? 150 : 260);
    if (!this.cursorImg.hidden && !reducedMotion()) {
      this.cursorImg.animate([{ scale: 0.92 }, { scale: 1 }], { duration: 160, easing: "cubic-bezier(.3,1.4,.5,1)" });
    }
  }

  // ---------------------------------------------------------------- the loupe and the pointer badge

  private updateLoupe(): void {
    if (!this.built) return;
    this.loupe.reduceMotion = reducedMotion();
    this.loupe.plain = reducedTransparency();
    const colors = this.loupeColors();
    this.loupe.accent = colors.accent;
    this.loupe.ink = colors.ink;
    const f = this.shown;
    const t = this.trackpad;
    if (!this.controlling || this.mode !== "trackpad" || !(f.width > 0) || !this.session?.hasFrame) {
      if (this.loupe.visible) this.loupe.setVisible(false, false);
      return;
    }
    if (t.drag.isPressed || t.multiFinger) {
      if (this.loupe.visible) this.loupe.setVisible(false, true);
      return;
    }
    if (!t.fingersDown && !this.loupe.visible) return;
    const display = this.displaySize();
    const m = Loupe.magnification(display.width > 0 ? f.width / display.width : 1);
    const p = this.drawnPointer() ?? t.pointer;
    const clip = { x: 0, y: 0, width: this.layoutBox.picture.width, height: this.layoutBox.picture.height };
    this.loupe.aim({ x: f.x + p.x * f.width, y: f.y + p.y * f.height }, f, clip, m, Drop.radius({ width: clip.width, height: clip.height }));
    this.loupe.tinted = t.holdIsArmed;
    if (t.fingersDown && !this.loupe.visible) {
      this.loupe.setSource(this.canvas);
      this.loupe.setVisible(true, true);
    } else if (!t.fingersDown && this.loupe.visible) this.loupe.setVisible(false, true);
  }

  private colorCache: { accent: [number, number, number]; ink: [number, number, number]; key: string } | null = null;
  private loupeColors(): { accent: [number, number, number]; ink: [number, number, number] } {
    const cs = getComputedStyle(this);
    const a = cs.getPropertyValue("--yoyo-accent").trim(), i = cs.getPropertyValue("--yoyo-text").trim();
    const key = a + i;
    if (this.colorCache?.key === key) return this.colorCache;
    const rgb = (c: string): [number, number, number] => {
      const m = /^#([0-9a-f]{6})$/i.exec(c);
      if (!m) return [0.85, 0.47, 0.34];
      const n = parseInt(m[1]!, 16);
      return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
    };
    this.colorCache = { accent: rgb(a), ink: rgb(i), key };
    return this.colorCache;
  }

  private badgeKind: "drag" | Axis | "undecided" | null = null;
  private updatePointerBadge(lean: Point | null = null): void {
    const t = this.trackpad;
    const kind = !this.controlling ? null : t.drag.isPressed ? "drag" : t.isScrolling ? (this.scrollAxis ?? "undecided") : null;
    const f = this.shown;
    const p = this.drawnPointer() ?? t.pointer;
    if (!kind || !(f.width > 0)) {
      this.pbadge.hidden = true;
      this.badgeKind = null;
      return;
    }
    if (kind !== this.badgeKind) {
      this.badgeKind = kind;
      this.pbadge.innerHTML = ICONS[kind === "drag" ? "drag" : kind === "horizontal" ? "scrollH" : kind === "vertical" ? "scroll" : "drag"];
    }
    this.pbadge.style.transform = `translate3d(${f.x + p.x * f.width + 20}px, ${f.y + p.y * f.height + 24}px, 0)`;
    this.pbadge.hidden = false;
    const icon = this.pbadge.firstElementChild as SVGElement | null;
    if (lean && icon && !reducedMotion()) {
      const n = Math.hypot(lean.x, lean.y);
      if (n > 0) icon.style.translate = `${(lean.x / n) * 2.5}px ${(lean.y / n) * 2.5}px`;
      clearTimeout(this.leanTimer ?? undefined);
      this.leanTimer = setTimeout(() => icon && (icon.style.translate = ""), 120);
    }
  }
  private leanTimer: ReturnType<typeof setTimeout> | null = null;
  private scrollAxis: Axis | null = null;

  // ---------------------------------------------------------------- the trackpad's host

  private trackpadHost(): TrackpadHost {
    const self = this;
    return {
      get controlling() {
        return self.controlling;
      },
      padRect: () => this.layoutBox.pad,
      shownPicture: () => ({ width: this.shown.width, height: this.shown.height }),
      display: () => this.displaySize(),
      drawnPointer: () => this.drawnPointer(),
      moveCursor: (p) => this.moveCursor(p),
      click: (kind, p) => this.clickAt(kind, p),
      scroll: (step, p) => this.queueScroll(step, p),
      drag: (step) => this.dragStep(step),
      pointerMoved: (p) => {
        if (this.controlling) this.input.move(p.x, p.y, this.displayId);
      },
      touches: (down) => this.touches(down),
      quietTap: () => this.vibrate(4),
      tapFeedback: (p) => {
        this.showClick(p);
        this.vibrate(6);
      },
      threeFingerTap: () => this.toggleStats(),
      leftPad: (out) => this.pad.classList.toggle("outside", out),
      holdArmed: () => this.updateLoupe(),
      pressed: (on) => {
        this.cursorImg.classList.toggle("press", on);
        if (on && this.cursorImg.hidden) this.showClick(this.trackpad.pointer);
        this.updatePointerBadge();
      },
      scrolling: (axis, lean) => {
        this.scrollAxis = axis || null;
        this.updatePointerBadge(lean);
      },
      loupeChanged: () => this.updateLoupe(),
      gestureBegan: () => this.updateLoupe(),
      vibrate: (p) => this.vibrate(p),
    };
  }

  /** The first finger came down on the trackpad / picture, or the last one lifted. Not in control (the page opened
   *  watching, the agent drives): the touch takes the screen (watching another device's control: only Take Over
   *  does). The keyboard goes at a touch. `deferTake`: a touch on the picture in touch mode, which may be a pinch
   *  (zooming isn't input): it takes the screen once it is a tap or a drag (`pictureTouchUp` / `pictureTouchMove`). */
  private touches(down: boolean, deferTake = false): void {
    const s = this.session;
    if (!s) return;
    if (down) {
      s.gesture();
      this.dropFocusLook();
      this.hideHint();
      if (this.isKeyboardUp && this.mode !== "mouse") {
        this.trackpad.quieten();
        this.keys.blur();
      }
      if (!this.controlling) {
        if (!deferTake || this.viewers.isViewer) this.userInput();
        return;
      }
      s.touchBegan();
      return;
    }
    s.touchEnded();
  }

  private nudgePill(): void {
    this.vibrate(5);
    if (reducedMotion()) return;
    this.vpill.classList.remove("nudge");
    void this.vpill.offsetWidth;
    this.vpill.classList.add("nudge");
  }

  // ---------------------------------------------------------------- pointer events

  private local(e: { clientX: number; clientY: number }): Point {
    const r = this.hostRect ?? this.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  private onPicture(p: Point): boolean {
    const r = this.layoutBox.picture;
    return this.canShow && p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height;
  }

  /** A page point as the display's 0…1, through the zoom. */
  private pictureNormalized(p: Point): Point {
    const r = this.layoutBox.picture;
    return this.zoom.point({ x: p.x - r.x, y: p.y - r.y }, { width: r.width, height: r.height });
  }

  private displayPointsPerPx(): number {
    const d = this.displaySize();
    const f = this.shown;
    return d.width > 0 && f.width > 0 ? d.width / f.width : 1;
  }

  private pointerDown(e: PointerEvent): void {
    if (!this.session) return;
    this.hostRect = this.getBoundingClientRect();
    const p = this.local(e);
    if (e.pointerType === "touch" || (e.pointerType === "pen" && this.mode !== "mouse")) {
      e.preventDefault();
      if (this.mode === "trackpad" && this.trackpad.down(e.pointerId, p, e.timeStamp / 1000)) {
        this.padPointers.add(e.pointerId);
        if (this.pref("PadUsed") !== "1") {
          // found the pad: its hint goes
          this.setPref("PadUsed", "1");
          this.render();
        }
        this.stage.setPointerCapture(e.pointerId);
        return;
      }
      if (this.trackpad.count === 0 && (this.pictureTouches.size > 0 || this.onPicture(p))) {
        this.pictureTouchDown(e.pointerId, p, e.timeStamp);
        this.stage.setPointerCapture(e.pointerId);
      }
      return;
    }
    // a mouse
    this.session.gesture();
    if (!this.onPicture(p)) return;
    if (!this.controlling) {
      // a press on the picture takes the screen (its click goes once it's taken: `mouseClick`)
      this.userInput();
      if (this.viewOnly) this.showChrome();
      return;
    }
    this.session.touchBegan();
    if (e.button !== 0) return;
    this.refocusKeys(true);
    const n = this.pictureNormalized(p);
    this.mouse = { p: n, cx: e.clientX, cy: e.clientY, dragging: false, mods: this.withSticky(modifiersOf(e)) };
    this.stage.setPointerCapture(e.pointerId);
  }

  private pointerMove(e: PointerEvent): void {
    if (this.padPointers.has(e.pointerId)) {
      const samples = (e.getCoalescedEvents?.() ?? []).map((c) => ({ p: this.local(c), t: c.timeStamp / 1000 }));
      this.trackpad.move(e.pointerId, this.local(e), samples, e.timeStamp / 1000);
      return;
    }
    if (this.pictureTouches.has(e.pointerId)) {
      this.pictureTouchMove(e.pointerId, this.local(e), e.timeStamp);
      return;
    }
    if (e.pointerType !== "mouse" || !this.controlling) return;
    const p = this.local(e);
    if (!this.mouse && !this.onPicture(p)) return;
    const n = this.pictureNormalized(p);
    const m = this.mouse;
    if (m && !m.dragging && Math.hypot(e.clientX - m.cx, e.clientY - m.cy) > 3) {
      m.dragging = true;
      this.clicks.flush();
      this.send({ type: "down", x: m.p.x, y: m.p.y, ...(m.mods.length ? { modifiers: m.mods } : {}) });
      this.takeModifiers();
    }
    this.input.move(n.x, n.y, this.displayId, m?.dragging ? "left" : undefined);
    this.moveCursor(n);
  }

  private pointerUp(e: PointerEvent, cancelled: boolean): void {
    if (this.padPointers.delete(e.pointerId)) {
      this.trackpad.up(e.pointerId, this.local(e), cancelled, e.timeStamp / 1000);
      return;
    }
    if (this.pictureTouches.has(e.pointerId)) {
      this.pictureTouchUp(e.pointerId, this.local(e), e.timeStamp, cancelled);
      return;
    }
    if (e.pointerType !== "mouse") return;
    this.session?.touchEnded();
    const m = this.mouse;
    this.mouse = null;
    if (m?.dragging && this.controlling) {
      const n = this.pictureNormalized(this.local(e));
      this.send({ type: "up", x: n.x, y: n.y });
      this.suppressClick = true;
    }
  }

  private mouseClick(e: MouseEvent): void {
    if ((e as PointerEvent).pointerType && (e as PointerEvent).pointerType !== "mouse") return;
    if (this.lastWasTouch()) return;
    if (!this.controlling) {
      // the press that took the screen: its click goes once the take is through
      if (!this.taking) return;
      const p = this.local(e);
      if (!this.onPicture(p)) return;
      const n = this.pictureNormalized(p);
      const detail = e.detail;
      const mods = modifiersOf(e);
      this.afterTake.push(() => this.mouseClickAt(n, detail, mods));
      return;
    }
    if (this.suppressClick) {
      this.suppressClick = false;
      return;
    }
    const p = this.local(e);
    if (!this.onPicture(p)) return;
    this.mouseClickAt(this.pictureNormalized(p), e.detail, modifiersOf(e));
  }

  private mouseClickAt(n: Point, detail: number, mods: ReturnType<typeof modifiersOf>): void {
    this.clicks.click(n.x, n.y, detail, this.takeModifiers(mods), performance.now());
    this.showClick(n);
    this.lookAtFocus();
    if (this.clickTimer) clearTimeout(this.clickTimer);
    const d = this.clicks.deadline;
    if (d !== null) this.clickTimer = setTimeout(() => this.clicks.tick(performance.now()), Math.max(0, d - performance.now()) + 5);
  }

  private lastWasTouch(): boolean {
    return this.pictureTouches.size > 0 || this.trackpad.count > 0;
  }

  private contextMenu(e: MouseEvent): void {
    e.preventDefault();
    if (this.mode !== "mouse") return;
    const p = this.local(e);
    if (!this.onPicture(p)) return;
    const n = this.pictureNormalized(p);
    const go = () => {
      this.clicks.flush();
      this.send({ type: "rightClick", x: n.x, y: n.y, ...this.modifierField(this.takeModifiers()) });
      this.moveCursor(n);
    };
    // the press that took the screen: its right-click goes once the take is through
    if (this.controlling) go();
    else if (this.taking) this.afterTake.push(go);
  }

  private wheel(e: WheelEvent): void {
    const p = this.local(e);
    if (!this.onPicture(p)) return;
    e.preventDefault();
    // ctrl + wheel is a trackpad's pinch: the picture zooms here (watching too: zooming isn't input)
    if (e.ctrlKey && e.deltaMode === 0) {
      const r = this.layoutBox.picture;
      const at = { x: p.x - r.x, y: p.y - r.y };
      const anchor = this.zoom.point(at, r);
      const z = this.zoom.copy();
      z.scale = Zoom.clampedScale(z.scale * Math.exp(-e.deltaY / 100), false);
      if (z.scale < Zoom.SNAP_TO_FIT) this.setZoom(new Zoom(), false);
      else {
        z.place(anchor, at, r);
        this.setZoom(z, false);
      }
      return;
    }
    // a scroll on the picture is input: watching, it takes the screen (the scroll goes from the next wheel event)
    if (!this.controlling) {
      if (this.canTake) this.userInput();
      return;
    }
    const n = this.pictureNormalized(p);
    const d = wheelDelta(e.deltaX, e.deltaY, e.deltaMode, this.displayPointsPerPx(), this.displaySize().height || 800);
    this.clicks.flush();
    this.input.scroll(d.dx, d.dy, n.x, n.y, this.displayId);
    this.session?.keySent();
  }

  // ---------------------------------------------------------------- touches on the picture

  private pictureTouchDown(id: number, p: Point, t: number): void {
    const first = this.pictureTouches.size === 0;
    this.pictureTouches.set(id, { start: p, pos: p, t });
    if (first && this.mode === "touch") this.touches(true, true);
    if (first && this.viewOnly) this.showChrome();
    if (this.pictureTouches.size === 2) {
      this.touch.cancel();
      const [a, b] = [...this.pictureTouches.values()];
      const r = this.layoutBox.picture;
      const mid = { x: (a!.pos.x + b!.pos.x) / 2 - r.x, y: (a!.pos.y + b!.pos.y) / 2 - r.y };
      this.pinch = { scale: this.zoom.scale, anchor: this.zoom.point(mid, r), dist: Math.max(1, Math.hypot(a!.pos.x - b!.pos.x, a!.pos.y - b!.pos.y)) };
      return;
    }
    if (first && this.mode === "touch" && this.controlling) this.runTouch(this.touch.down(p.x, p.y, t));
  }

  private pictureTouchMove(id: number, p: Point, t: number): void {
    const f = this.pictureTouches.get(id);
    if (!f) return;
    f.pos = p;
    if (this.pinch && this.pictureTouches.size >= 2) {
      const [a, b] = [...this.pictureTouches.values()];
      const r = this.layoutBox.picture;
      const mid = { x: (a!.pos.x + b!.pos.x) / 2 - r.x, y: (a!.pos.y + b!.pos.y) / 2 - r.y };
      const dist = Math.hypot(a!.pos.x - b!.pos.x, a!.pos.y - b!.pos.y);
      const z = this.zoom.copy();
      z.scale = Zoom.clampedScale((this.pinch.scale * dist) / this.pinch.dist, true);
      z.place(this.pinch.anchor, mid, r);
      this.setZoom(z, false);
      return;
    }
    if (this.mode === "touch" && this.pictureTouches.size === 1) {
      if (this.controlling) this.runTouch(this.touch.move(p.x, p.y, t));
      // watching: a drag on the picture is input (a pinch isn't): it takes the screen
      else if (this.canTake && Math.hypot(p.x - f.start.x, p.y - f.start.y) >= 10) this.userInput();
    }
  }

  private pictureTouchUp(id: number, p: Point, t: number, cancelled: boolean): void {
    const f = this.pictureTouches.get(id);
    if (!f) return;
    this.pictureTouches.delete(id);
    if (this.pinch) {
      if (this.pictureTouches.size < 2) {
        this.pinch = null;
        const z = this.zoom.copy();
        z.scale = Zoom.clampedScale(z.scale, false);
        if (z.scale < Zoom.SNAP_TO_FIT) this.setZoom(new Zoom(), true);
        else {
          z.clampCenter();
          this.setZoom(z, true);
        }
        this.followed = this.drawnPointer();
        // the finger left on the glass does nothing more this touch
        this.pictureTouches.clear();
        if (this.mode === "touch") this.touches(false);
      }
      return;
    }
    const quick = t - f.t < 350 && Math.hypot(p.x - f.start.x, p.y - f.start.y) < 10 && !cancelled;
    if (this.mode === "touch" && this.controlling) {
      if (cancelled) this.touch.cancel();
      else this.runTouch(this.touch.up(p.x, p.y, t));
      if (quick) this.showClick(this.pictureNormalized(p));
    } else if (this.mode === "touch" && quick && this.canTake) {
      // watching: a tap on the picture is input: it takes the screen (this tap clicks nothing)
      this.userInput();
    } else if (quick) {
      // the picture's own: a double tap fits (or zooms in there); a tap says how
      const prev = this.pictureTapAt;
      if (prev && t - prev.t < 350 && Math.hypot(p.x - prev.p.x, p.y - prev.p.y) < 40) {
        this.pictureTapAt = null;
        if (this.zoomHintTimer) clearTimeout(this.zoomHintTimer);
        this.pictureDoubleTapped(p);
      } else {
        this.pictureTapAt = { t, p };
        if (this.zoomHintTimer) clearTimeout(this.zoomHintTimer);
        this.zoomHintTimer = setTimeout(() => this.pictureTapped(), 360);
      }
    }
    if (this.pictureTouches.size === 0 && this.mode === "touch") this.touches(false);
  }

  private runTouch(actions: TouchAction[]): void {
    for (const a of actions) {
      if (a.t === "scroll") {
        this.input.scroll(a.dx, a.dy, a.x, a.y, this.displayId, a.phase, a.vx, a.vy);
        this.moveCursor({ x: a.x, y: a.y });
      } else {
        this.clickAt(a.t, { x: a.x, y: a.y });
      }
    }
    if (this.touchTimer) clearTimeout(this.touchTimer);
    const d = this.touch.deadline;
    if (d !== null) this.touchTimer = setTimeout(() => this.runTouch(this.touch.tick(performance.now())), Math.max(0, d - performance.now()) + 5);
  }

  private pictureDoubleTapped(p: Point): void {
    const r = this.layoutBox.picture;
    if (this.zoom.zoomed) this.setZoom(new Zoom(), true);
    else {
      const z = new Zoom(Zoom.DOUBLE_TAP_SCALE, this.zoom.point({ x: p.x - r.x, y: p.y - r.y }, r));
      z.clampCenter();
      this.setZoom(z, true);
      this.followed = this.drawnPointer();
    }
    this.vibrate(6);
  }

  private pictureTapped(): void {
    this.zoomHintTimer = null;
    if (this.viewOnly) {
      this.showChrome();
      return;
    }
    this.vibrate(4);
    // in trackpad mode a tap on the picture doesn't click: say where clicks go
    if (this.mode === "trackpad" && this.controlling) {
      this.showZoomHint(this.words.t("tapUsesPad"), "trackpad");
      return;
    }
    const z = this.zoom.zoomed;
    this.showZoomHint(this.words.t(z ? "doubleTapToFit" : "pinchToZoom"), z ? "exitFull" : "zoomIn");
  }

  private showZoomHint(text: string, icon: IconName): void {
    this.zoomHint.innerHTML = `${ICONS[icon]}<span></span>`;
    this.zoomHint.querySelector("span")!.textContent = text;
    this.zoomHint.classList.add("shown");
    if (this.zoomHintHide) clearTimeout(this.zoomHintHide);
    this.zoomHintHide = setTimeout(() => this.hideZoomHint(), 1600);
  }
  private zoomHintHide: ReturnType<typeof setTimeout> | null = null;
  private hideZoomHint(): void {
    this.zoomHint.classList.remove("shown");
  }

  // ---------------------------------------------------------------- input

  private send(i: Input): void {
    if (!this.input) return;
    const withDisplay = i.display === undefined && this.displayId !== undefined && i.type !== "type" && i.type !== "key" ? { ...i, display: this.displayId } : i;
    this.input.input(withDisplay);
  }

  private modifierField(m: Modifier[]): { modifiers?: Modifier[] } {
    return m.length ? { modifiers: m } : {};
  }

  /** The armed (sticky) modifiers, disarmed, merged with `with`. */
  private takeModifiers(withMods: Modifier[] = []): Modifier[] {
    const all = [...new Set([...withMods, ...this.modifiers])];
    if (this.modifiers.size) {
      this.modifiers.clear();
      this.updateModifierKeys();
    }
    const order: Modifier[] = ["cmd", "shift", "alt", "ctrl"];
    return order.filter((m) => all.includes(m));
  }

  private withSticky(m: Modifier[]): Modifier[] {
    return [...new Set([...m, ...this.modifiers])];
  }

  private clickAt(kind: Click | "click" | "doubleClick" | "rightClick", p: Point): void {
    if (!this.controlling) return;
    this.send({ type: kind, x: p.x, y: p.y, ...this.modifierField(this.takeModifiers()) });
    if (kind !== "rightClick") this.lookAtFocus();
    this.moveCursor(p);
  }

  private queueScroll(step: ScrollStep, p: Point): void {
    if (!this.controlling) return;
    const d = this.displaySize();
    const v = TwoFingerScroll.capped({ x: step.velocity.x * d.width, y: step.velocity.y * d.height });
    this.input.scroll(step.delta.x * d.width, step.delta.y * d.height, p.x, p.y, this.displayId, step.phase, v.x, v.y);
    this.moveCursor(p);
  }

  /** A live drag's step: `down` / `up` in order with everything else, the held moves merged. */
  private dragStep(step: DragStep): void {
    if (step.t === "down") {
      if (!this.controlling) return;
      this.dragHeld = { display: this.displayId, p: step.at };
      this.send({ type: "down", x: step.at.x, y: step.at.y, ...this.modifierField(this.takeModifiers()) });
    } else if (step.t === "move") {
      if (!this.dragHeld) return;
      this.dragHeld.p = step.at;
      this.input.move(step.at.x, step.at.y, this.dragHeld.display ?? this.displayId, "left");
    } else {
      const held = this.dragHeld;
      if (!held) return;
      this.dragHeld = null;
      this.send({ type: "up", x: step.at.x, y: step.at.y, ...(held.display !== undefined ? { display: held.display } : {}) });
    }
    this.moveCursor(step.at);
  }

  /** The page stops mid-drag: `up` goes now, past the queue (best effort). */
  private liftDrag(): void {
    const held = this.dragHeld;
    this.dragHeld = null;
    if (!held || !this.session) return;
    const up: Input = { type: "up", x: held.p.x, y: held.p.y, ...(held.display !== undefined ? { display: held.display } : {}) };
    const link = this.session.linkInput((e) => this.inputFailed(e));
    try {
      if (link) link(up);
      else void this.session.deliver(up).catch(() => {});
    } catch {
      /* best effort */
    }
  }

  private inputFailed(e: unknown): void {
    if (this.handleError(e)) return;
    const device = controlledElsewhere(e);
    if (device) {
      const effect = this.viewers.refused(device);
      if (effect) this.tookOver(effect.tookOver);
      this.heldByMe = false;
      this.render();
      void this.refreshStatus();
      return;
    }
    if ((e as { status?: number }).status === 409) {
      this.heldByMe = false;
      if (this.status?.controller === "user") this.status = { ...this.status, controller: "none" };
      this.render();
      this.toast(this.words.t("noLongerControl"));
      void this.refreshStatus();
      return;
    }
    this.toast(errorText(e, this.words));
  }

  private handleError(e: unknown): boolean {
    try {
      return this._host.handleError?.(e) === true;
    } catch {
      return false;
    }
  }

  // ---------------------------------------------------------------- keyboard

  private get isKeyboardUp(): boolean {
    return this.root.activeElement === this.keys;
  }

  private refocusKeys(now = false): void {
    if (this.mode !== "mouse" || !(this.controlling || this.canTake) || !this.activeFlag) return;
    const go = () => {
      const a = document.activeElement;
      if (this.sheet.hidden && this.menu.hidden && (!a || a === document.body || a === this)) this.keys.focus({ preventScroll: true });
    };
    if (now) go();
    else setTimeout(go, 0);
  }

  private keyDown(e: KeyboardEvent): void {
    // a key is input: watching, it takes the screen and goes once it's taken
    if (!this.controlling && !this.canTake) return;
    const k = keyInput(
      { key: e.key, code: e.code, metaKey: e.metaKey, ctrlKey: e.ctrlKey, altKey: e.altKey, shiftKey: e.shiftKey, isComposing: e.isComposing || this.composing, keyCode: e.keyCode },
      !this.isMac,
    );
    if (!k) {
      // a plain character with a sticky modifier armed is a shortcut (⌘C)
      if (this.modifiers.size && e.key.length === 1 && !e.isComposing && !this.composing) {
        e.preventDefault();
        const ch = e.key;
        this.userInput(() => this.sendShortcut(ch));
      }
      return;
    }
    e.preventDefault();
    this.userInput(() => {
      this.clicks.flush();
      this.session?.keySent();
      this.hideHint();
      this.send({ ...k, ...this.modifierField(this.takeModifiers(k.modifiers ?? [])) });
    });
  }

  private sendShortcut(ch: string): void {
    const shifted = ch !== ch.toLowerCase() && ch === ch.toUpperCase();
    const name = ch === " " ? "space" : ch === "\t" ? "tab" : ch.toLowerCase();
    const m = this.takeModifiers(shifted ? ["shift"] : []);
    this.session?.keySent();
    this.send({ type: "key", key: name, ...this.modifierField(m) });
  }

  private typedInput(e: InputEvent): void {
    const t = textInput(e.inputType, e.data ?? null, this.composing || e.isComposing);
    if (t && (this.controlling || this.canTake)) {
      // typed text is input: watching, it takes the screen and goes once it's taken
      this.userInput(() => {
        if (t.type === "type" && this.modifiers.size && [...(t.text ?? "")].length === 1) this.sendShortcut(t.text!);
        else {
          this.clicks.flush();
          this.session?.keySent();
          this.hideHint();
          this.send(t.type === "key" ? { ...t, ...this.modifierField(this.takeModifiers()) } : t);
        }
      });
    }
    if (!this.composing) resetField(this.keys);
  }

  private compositionEnd(e: CompositionEvent): void {
    this.composing = false;
    const text = (e.data ?? "").replaceAll("​", "");
    if (text && (this.controlling || this.canTake)) {
      this.userInput(() => {
        this.session?.keySent();
        this.send({ type: "type", text });
      });
    }
    resetField(this.keys);
  }

  /** The keyboard button: up (taking the screen when watching: typing is input; the keyboard comes up at once, as the
   *  tap allows, and what is typed meanwhile waits for the take) or away. */
  private toggleKeyboard(): void {
    if (this.isKeyboardUp) this.keys.blur();
    else if (this.controlling || this.canTake) {
      this.userInput();
      this.showKeyboard();
    }
  }

  private showKeyboard(): void {
    resetField(this.keys);
    this.keys.focus({ preventScroll: true });
    // (a window without focus sends no focus event)
    this.keyboardShown(this.isKeyboardUp);
    // a browser that only shows the keyboard from a tap (iOS Safari): a hint to tap
    if (!this.isKeyboardUp) this.showHintText(this.words.t("tapToType"), "keyboard", () => this.keys.focus({ preventScroll: true }));
  }

  private keyboardShown(on: boolean): void {
    this.keybar.hidden = !on || this.mode === "mouse";
    this.buttons.keyboard.classList.toggle("on", on && this.mode !== "mouse");
    this.placeKeyBar();
  }

  /** The key bar sits on top of the soft keyboard (the visual viewport's bottom). */
  private placeKeyBar(): void {
    if (this.keybar.hidden) return;
    const vv = window.visualViewport;
    const bottom = vv ? vv.offsetTop + vv.height : window.innerHeight;
    this.keybar.style.top = `${bottom - this.keybar.offsetHeight}px`;
  }

  /** After a click: whether the focused element takes typing (then the keyboard comes up), looked at a few times. */
  private lookAtFocus(): void {
    this.dropFocusLook();
    if (this.focusUnsupported || !this.controlling || this.mode === "mouse" || this.layoutBox.wide || this.isKeyboardUp || !this._backend?.focus) return;
    const look = { cancelled: false };
    this.focusLook = look;
    void (async () => {
      let waited = 0;
      for (const at of FOCUS_LOOKS_MS) {
        await new Promise((r) => setTimeout(r, at - waited));
        waited = at;
        if (look.cancelled) return;
        let f: { editable: boolean } | null = null;
        try {
          f = await this.session!.focus();
        } catch (e) {
          const st = (e as { status?: number }).status;
          if (st === 404 || st === 403 || st === 501) this.focusUnsupported = true;
          return;
        }
        if (look.cancelled) return;
        if (f?.editable) {
          if (this.controlling && this.activeFlag && this.sheet.hidden && !this.isKeyboardUp) this.showKeyboard();
          return;
        }
      }
    })();
  }

  private dropFocusLook(): void {
    if (this.focusLook) this.focusLook.cancelled = true;
    this.focusLook = null;
  }

  private buildKeyBar(): void {
    const kb = this.keybar;
    const key = (label: string, cls: string, run: () => void, holdMenu?: (b: HTMLButtonElement) => void): HTMLButtonElement => {
      const b = el("button", cls, label);
      b.type = "button";
      let held: ReturnType<typeof setTimeout> | null = null;
      let longPressed = false;
      // never take the focus from the text field (the keyboard stays up)
      b.addEventListener("pointerdown", (e) => {
        e.preventDefault();
        longPressed = false;
        if (holdMenu)
          held = setTimeout(() => {
            longPressed = true;
            this.vibrate(8);
            holdMenu(b);
          }, KEY_HOLD_MS);
      });
      const cancel = () => {
        if (held) clearTimeout(held);
        held = null;
      };
      b.addEventListener("pointerup", cancel);
      b.addEventListener("pointercancel", cancel);
      b.addEventListener("pointerleave", cancel);
      b.addEventListener("contextmenu", (e) => e.preventDefault());
      b.addEventListener("click", (e) => {
        e.preventDefault();
        if (longPressed) return;
        this.vibrate(3);
        run();
      });
      kb.append(b);
      return b;
    };
    for (const [m, glyph] of [["cmd", "⌘"], ["shift", "⇧"], ["alt", "⌥"], ["ctrl", "⌃"]] as [Modifier, string][]) {
      this.keybarButtons.set(m, key(glyph, "", () => this.toggleModifier(m)));
    }
    kb.append(el("span", "gap"));
    for (const [glyph, name] of [["esc", "escape"], ["tab", "tab"], ["←", "left"], ["↑", "up"], ["↓", "down"], ["→", "right"]]) {
      const b = key(glyph!, glyph!.length > 1 ? "word" : "", () => this.sendKey(name!));
      b.dataset.key = name;
    }
    kb.append(el("span", "gap"));
    const paste = key("", "word", () => void this.pasteOnMac(), (b) => {
      if (this._backend?.sendsClipboardFiles) this.openPickMenu(b);
    });
    paste.dataset.clip = "paste";
    const copy = key("", "word", () => void this.copyFromMac());
    copy.dataset.clip = "copy";
    this.clipKeys = [paste, copy];
    kb.append(el("span", "gap"));
    const hide = key(ICONS.keyboardDown, "", () => this.keys.blur());
    hide.dataset.key = "hide";
  }

  private relabelKeyBar(): void {
    const w = this.words;
    const names: Record<string, StringKey> = { cmd: "commandKey", shift: "shiftKey", alt: "optionKey", ctrl: "controlKey" };
    for (const [m, b] of this.keybarButtons) b.setAttribute("aria-label", w.t(names[m]!));
    const keyNames: Record<string, StringKey> = { escape: "escape", tab: "tab", left: "leftArrow", up: "upArrow", down: "downArrow", right: "rightArrow", hide: "hideKeyboard" };
    for (const b of this.keybar.querySelectorAll<HTMLButtonElement>("button[data-key]")) b.setAttribute("aria-label", w.t(keyNames[b.dataset.key!]!));
    const [paste, copy] = this.clipKeys;
    if (paste) {
      paste.innerHTML = `${ICONS.paste}<span></span>`;
      paste.querySelector("span")!.textContent = w.c("pasteOn");
      paste.title = this._backend?.sendsClipboardFiles ? w.t("holdForFiles") : "";
    }
    if (copy) {
      copy.innerHTML = `${ICONS.copyFrom}<span></span>`;
      copy.querySelector("span")!.textContent = w.c("copyFrom");
    }
  }

  private toggleModifier(m: Modifier): void {
    if (this.modifiers.has(m)) this.modifiers.delete(m);
    else this.modifiers.add(m);
    this.updateModifierKeys();
  }

  private updateModifierKeys(): void {
    for (const [m, b] of this.keybarButtons) {
      b.classList.toggle("on", this.modifiers.has(m));
      b.setAttribute("aria-pressed", String(this.modifiers.has(m)));
    }
  }

  private sendKey(name: string): void {
    if (!this.controlling) {
      if (this.canTake) this.userInput(() => this.sendKey(name));
      return;
    }
    this.session?.keySent();
    this.send({ type: "key", key: name, ...this.modifierField(this.takeModifiers()) });
  }

  // ---------------------------------------------------------------- modes, the card, full screen, sound

  private switchMode(): void {
    if (this.mode === "mouse") return;
    this.trackpad.reset();
    this.touch.cancel();
    this.mode = this.mode === "trackpad" ? "touch" : "trackpad";
    this.setPref("TouchMode", this.mode);
    this.vibrate(8);
    this.setZoom(new Zoom(), false);
    this.updateModeButton();
    this.layout();
    this.render();
    if (this.controlling) this.showCardOnce();
  }

  private updateModeButton(): void {
    const b = this.buttons.mode;
    const touchNow = this.mode === "touch";
    this.setIcon(b, touchNow ? "touch" : "trackpad");
    const label = this.words.t(touchNow ? "switchToTrackpad" : "switchToTouch");
    b.setAttribute("aria-label", label);
    b.title = label;
  }

  private showCardOnce(): void {
    if (this.mode === "mouse") return;
    const key = this.mode === "trackpad" ? "GestureCard2Shown" : "TouchCardShown";
    const hints = new GestureHints(this.pref(key) === "1");
    if (!hints.take()) return;
    this.setPref(key, "1");
    this.openCard();
  }

  private openCard(): void {
    const w = this.words;
    const rows: [IconName, StringKey, StringKey][] =
      this.mode === "trackpad"
        ? [
            ["pointer", "dragOneFinger", "movePointer"],
            ["handTap", "tap", "click"],
            ["doubleTap", "doubleTap", "doubleClick"],
            ["twoFingers", "tapTwoFingers", "rightClick"],
            ["select", "holdThenDrag", "selectOrDrag"],
            ["drag", "dragThreeFingers", "dragKeepGoing"],
            ["scroll", "dragTwoFingers", "scroll"],
          ]
        : this.mode === "touch"
          ? [
              ["handTap", "tap", "click"],
              ["doubleTap", "doubleTap", "doubleClick"],
              ["hold", "touchAndHold", "rightClick"],
              ["scroll", "dragOneFinger", "scroll"],
              ["pinch", "pinch", "zoomPicture"],
            ]
          : [
              ["mouse", "clickMouse", "clickMouseAction"],
              ["drag", "dragMouse", "selectOrDrag"],
              ["scroll", "wheel", "scroll"],
              ["key", "typeKeys", "typeKeysAction"],
            ];
    const title = this.mode === "trackpad" ? "trackpadGestures" : this.mode === "touch" ? "touchGestures" : "mouseGestures";
    const intro = this.mode === "trackpad" ? "trackpadIntro" : this.mode === "touch" ? "touchIntro" : "mouseIntro";
    const card = el("div", "card");
    const h = el("h2");
    h.textContent = w.t(title);
    const p = el("p", "intro");
    p.textContent = w.t(intro);
    const table = el("table");
    const head = el("tr");
    head.innerHTML = `<th></th><th></th><th></th>`;
    head.children[1]!.textContent = w.t("gesture");
    head.children[2]!.textContent = w.t("action");
    table.append(head);
    const addRow = (icon: IconName, g: string, a: string) => {
      const tr = el("tr");
      tr.innerHTML = `<td class="icon">${ICONS[icon]}</td><td></td><td class="what"></td>`;
      tr.children[1]!.textContent = g;
      tr.children[2]!.textContent = a;
      table.append(tr);
    };
    for (const [i, g, a] of rows) addRow(i, w.t(g), w.t(a));
    card.append(h, p, table);
    if (this.clipboardOn) {
      const h3 = el("h3");
      h3.textContent = w.t("clipboard");
      const t2 = el("table");
      const add2 = (icon: IconName, g: string, a: string) => {
        const tr = el("tr");
        tr.innerHTML = `<td class="icon">${ICONS[icon]}</td><td></td><td class="what"></td>`;
        tr.children[1]!.textContent = g;
        tr.children[2]!.textContent = a;
        t2.append(tr);
      };
      add2("paste", w.c("pasteOn"), w.c("pasteExplained"));
      add2("copyFrom", w.c("copyFrom"), w.c("copyExplained"));
      card.append(h3, t2);
      if (this._backend?.sendsClipboardFiles) {
        const foot = el("p", "foot");
        foot.textContent = w.t("sendFilesHint");
        card.append(foot);
      }
    }
    const done = el("button", "prominent done");
    done.textContent = w.t("gotIt");
    done.addEventListener("click", () => this.closeOverlays());
    card.append(done);
    this.openSheet(card);
  }

  private toggleFullScreen(): void {
    if (this.mode === "mouse") {
      if (document.fullscreenElement === this) void document.exitFullscreen?.().catch(() => {});
      else void this.requestFullscreen?.({ navigationUI: "hide" }).catch(() => {});
      return;
    }
    this.setFullScreen(!this.fullScreen);
  }

  /** Full screen on a touch device: the picture alone, view only (control given back), landscape where it can lock. */
  private setFullScreen(on: boolean): void {
    if (on === this.fullScreen) return;
    this.fullScreen = on;
    this.toggleAttribute("fullscreen", on);
    if (on) {
      void this.requestFullscreen?.({ navigationUI: "hide" })
        .then(() => (screen.orientation as ScreenOrientation & { lock?: (o: string) => Promise<void> }).lock?.("landscape"))
        .catch(() => {});
    } else if (document.fullscreenElement === this) void document.exitFullscreen().catch(() => {});
    this.vibrate(8);
    this.viewOnlyChanged();
    this.layout();
  }

  private fullscreenChanged(): void {
    const inFull = document.fullscreenElement === this;
    if (this.mode === "mouse") {
      this.desktopFull = inFull;
      this.toggleAttribute("fullscreen", inFull);
      this.updateFsButton();
      this.layout();
      return;
    }
    if (!inFull && this.fullScreen) this.setFullScreen(false);
  }

  /** Into view only: the keyboard and any drag go, control goes back. Out: watching (the next real input takes the
   *  screen again). */
  private viewOnlyChanged(): void {
    if (this.viewOnly) {
      this.dropFocusLook();
      this.keys.blur();
      this.trackpad.reset();
      this.liftDrag();
      this.releaseControl(false);
      this.setZoom(new Zoom(), false);
    }
    this.updateFsButton();
    this.render();
    this.showChrome();
  }

  private updateFsButton(): void {
    if (!this.built) return;
    const on = this.mode === "mouse" ? this.desktopFull : this.fullScreen;
    this.setIcon(this.fsButton, on ? "exitFull" : "enterFull");
    const label = this.words.t(on ? "exitFullScreen" : this.mode === "mouse" ? "fullScreenDesktop" : "fullScreen");
    this.fsButton.setAttribute("aria-label", label);
    this.fsButton.title = label;
    this.fsButton.hidden = !this.canShow || this.layoutBox.phoneLandscape;
  }

  /** The full-screen button and the badges show; in view-only full screen they fade after a moment. */
  private showChrome(): void {
    if (this.chromeFade) clearTimeout(this.chromeFade);
    this.chromeFade = null;
    this.fsButton.classList.remove("faded");
    this.badges.classList.remove("faded");
    if (!this.viewOnly) return;
    this.chromeFade = setTimeout(() => {
      this.fsButton.classList.add("faded");
      this.badges.classList.add("faded");
    }, CHROME_FADE_MS);
  }

  private toggleSound(): void {
    const s = this.session;
    if (!s) return;
    s.setAudioOn(!s.audioOn);
    this.vibrate(6);
  }

  private updateSoundButton(): void {
    const s = this.session;
    if (!this.built) return;
    const on = s?.audioOn ?? true;
    this.setIcon(this.buttons.sound, on ? "speaker" : "speakerOff");
    const label = this.words.c(on ? "soundMute" : "soundPlay");
    this.buttons.sound.setAttribute("aria-label", label);
    this.buttons.sound.title = label;
    this.buttons.sound.hidden = !s?.audioShown || this.viewOnly || !this.canShow;
  }

  // ---------------------------------------------------------------- menus and sheets

  private openMenu(anchor: HTMLElement, sections: { title?: string; items: { label: string; sub?: string | null; icon?: IconName; checked?: boolean; disabled?: boolean; run: () => void }[] }[]): void {
    const m = this.menu;
    m.innerHTML = "";
    for (const s of sections) {
      const sec = el("div", "section");
      if (s.title) {
        const t = el("div", "title");
        t.textContent = s.title;
        sec.append(t);
      }
      for (const it of s.items) {
        const b = el("button");
        b.type = "button";
        b.setAttribute("role", "menuitem");
        b.disabled = !!it.disabled;
        b.innerHTML = `<span class="mark">${it.checked ? ICONS.check : it.icon ? ICONS[it.icon] : ""}</span><span class="label"><span></span><span class="sub"></span></span>`;
        b.querySelector(".label > span")!.textContent = it.label;
        const sub = b.querySelector(".sub")!;
        if (it.sub) sub.textContent = it.sub;
        else sub.remove();
        b.addEventListener("click", () => {
          this.closeOverlays();
          it.run();
        });
        sec.append(b);
      }
      m.append(sec);
    }
    m.hidden = false;
    this.scrim.hidden = false;
    this.scrim.style.background = "transparent";
    const W = this.clientWidth, H = this.clientHeight;
    const r = anchor.getBoundingClientRect();
    const host = this.getBoundingClientRect();
    const mw = Math.min(m.offsetWidth, W - 24);
    const left = Math.min(Math.max(12, r.left - host.left + r.width / 2 - mw / 2), W - mw - 12);
    const above = r.top - host.top > H / 2;
    m.style.left = `${left}px`;
    m.style.top = above ? "auto" : `${r.bottom - host.top + 8}px`;
    m.style.bottom = above ? `${H - (r.top - host.top) + 8}px` : "auto";
    m.style.transformOrigin = above ? "bottom center" : "top center";
    requestAnimationFrame(() => {
      m.classList.add("shown");
      this.scrim.classList.add("shown");
    });
  }

  private openSheet(content: HTMLElement): void {
    this.keys.blur();
    this.sheet.innerHTML = `<div class="grabber"></div>`;
    this.sheet.append(content);
    this.sheet.hidden = false;
    this.scrim.hidden = false;
    this.scrim.style.background = "";
    requestAnimationFrame(() => {
      this.sheet.classList.add("shown");
      this.scrim.classList.add("shown");
    });
  }

  private closeOverlays(): void {
    for (const e of [this.menu, this.sheet, this.scrim]) e.classList.remove("shown");
    const done = () => {
      for (const e of [this.menu, this.sheet, this.scrim]) if (!e.classList.contains("shown")) e.hidden = true;
      if (this.sheet.hidden) this.sheet.innerHTML = "";
      this.refocusKeys();
    };
    setTimeout(done, reducedMotion() ? 0 : 280);
  }

  private openDisplayMenu(anchor: HTMLElement): void {
    const s = this.status;
    if (!s) return;
    const w = this.words;
    const current = this.displayId ?? mainDisplay(s)?.id;
    this.openMenu(anchor, [
      {
        title: w.t("display"),
        items: s.displays.map((d, i) => ({ label: displayTitle(d, i, w), sub: displaySubtitle(d, w), checked: d.id === current, run: () => this.selectDisplay(d.id) })),
      },
    ]);
  }

  private selectDisplay(id: number): void {
    if (id === this.displayId || !this.session) return;
    this.displayId = id;
    this.session.display = id;
    this.session.displayIsMain = this.currentDisplay?.main ?? true;
    this.session.displayIsVirtual = this.currentDisplay?.kind === "virtual";
    this.cursorPart = null;
    this.setZoom(new Zoom(), false);
    this.session.restartFrames();
    this.render();
  }

  // ---------------------------------------------------------------- clipboard

  /** The computer has a clipboard (`features.clipboard`, else the Mac only), and the backend can reach it. */
  private updateClipboardCapability(): void {
    const b = this._backend;
    if (!b) return;
    const features = this.status?.features ?? knownFeatures.get(b.cacheScope);
    const has = !!b.clipboard && (features?.clipboard ?? this.isMac);
    if (has && !this.clipboard) {
      this.clipboard = ClipboardState.of(b);
      this.unobserveClipboard = this.clipboard.observe((st) => this.clipboardChanged(st));
      this.clipboard.refresh();
    } else if (!has && this.clipboard) {
      this.unobserveClipboard?.();
      this.unobserveClipboard = null;
      this.clipboard = null;
      this.hideHint();
      this.setClipboardOn(false);
    }
  }

  private setClipboardOn(on: boolean): void {
    if (on === this.clipboardOn) return;
    this.clipboardOn = on;
    this.updateChrome();
    this.layout();
  }

  private clipboardChanged(st: ClipboardState): void {
    this.setClipboardOn(clipboardSupported(st.status !== null, st.error));
    const summary = st.status?.item ?? null;
    if (st.status) {
      if (this.activeFlag && !this.viewOnly) {
        const h = ClipboardHints.onMacChange(summary, this.macCountKnown, this.words);
        if (h) this.showHint(h);
      }
      this.macCountKnown = summary?.changeCount ?? -1;
      this.marks.knowMac(summary);
    }
    void this.showPhoneHintIfNew();
    this.updateClipboardDot();
  }

  /** What this browser's clipboard holds, when it lets the page look without asking (Chrome with the permission granted). */
  private async phoneClipboard(): Promise<{ kind: PhoneKind | null; count: string | null }> {
    try {
      const perm = await navigator.permissions?.query({ name: "clipboard-read" as PermissionName });
      if (perm?.state !== "granted" || !navigator.clipboard?.read) return { kind: null, count: null };
      const items = await navigator.clipboard.read();
      const types = items.flatMap((i) => [...i.types]);
      if (types.some((t) => t.startsWith("image/"))) return { kind: "image", count: types.join(",") + items.length };
      const text = items.find((i) => i.types.includes("text/plain"));
      if (!text) return { kind: null, count: null };
      const s = await (await text.getType("text/plain")).text();
      if (!s.trim()) return { kind: null, count: null };
      return { kind: /^https?:\/\/\S+$/.test(s.trim()) ? "link" : "text", count: `${s.length}:${s.slice(0, 64)}` };
    } catch {
      return { kind: null, count: null };
    }
  }

  private async showPhoneHintIfNew(): Promise<void> {
    if (this.phoneHintAsked || !this.clipboardOn || !this.activeFlag || this.viewOnly || this.clipboard?.status?.available === false) return;
    this.phoneHintAsked = true;
    const { kind, count } = await this.phoneClipboard();
    this.phoneCount = count;
    this.phoneKind = kind;
    const h = ClipboardHints.onAppear(this.marks, count, kind);
    if (h) this.showHint(h);
    this.updateClipboardDot();
  }
  private phoneCount: string | null = null;
  private phoneKind: PhoneKind | null = null;

  private updateClipboardDot(): void {
    const b = this.buttons?.clipboard;
    if (!b) return;
    const on = this.clipboardOn && this.marks.dot(this.phoneCount, this.phoneKind, this.clipboard?.status?.item ?? null, this.words);
    const dot = b.querySelector(".dot");
    if (on && !dot) b.append(el("span", "dot"));
    else if (!on) dot?.remove();
    b.setAttribute("aria-description", on ? this.words.t("newDot") : "");
  }

  private showHint(h: ClipboardHint): void {
    const w = this.words;
    const text = h.t === "phone" ? ClipboardActions.phoneHint(h.kind, w) : this.clipboard?.status?.item ? ClipboardActions.macHint(this.clipboard.status.item, w) : null;
    if (!text) return;
    this.hint = h;
    this.showHintText(text, h.t === "phone" ? "paste" : "copyFrom", null);
  }

  private hintAction: (() => void) | null = null;
  private showHintText(text: string, icon: IconName, action: (() => void) | null): void {
    this.hintAction = action;
    this.hintPill.innerHTML = `${ICONS[icon]}<span></span>`;
    this.hintPill.querySelector("span")!.textContent = text;
    this.hintPill.setAttribute("aria-label", text);
    this.hintPill.classList.add("shown");
    if (this.hintTimer) clearTimeout(this.hintTimer);
    this.hintTimer = setTimeout(() => this.hideHint(), HINT_DURATION_MS);
  }

  private hideHint(): void {
    this.hint = null;
    this.hintAction = null;
    this.hintPill?.classList.remove("shown");
    if (this.hintTimer) clearTimeout(this.hintTimer);
    this.hintTimer = null;
  }

  private hintTapped(): void {
    const h = this.hint, action = this.hintAction;
    this.hideHint();
    if (action) return action();
    if (h?.t === "phone") void this.pasteOnMac();
    else if (h?.t === "mac") void this.copyFromMac();
  }

  private openClipboardMenu(anchor: HTMLElement): void {
    const w = this.words;
    const mac = this.clipboard?.status ?? null;
    this.marks.sawMenu(this.phoneCount, mac?.item ?? null);
    this.updateClipboardDot();
    this.hideHint();
    const paste = ClipboardActions.pasteItem(this.phoneKind, mac, w);
    const copy = ClipboardActions.copyItem(mac, w);
    const sendOk = !mac || mac.available;
    const files = this._backend?.sendsClipboardFiles
      ? [
          { label: w.t("photos"), icon: "photo" as IconName, disabled: !sendOk, run: () => this.pick("photos") },
          { label: w.t("files"), icon: "folder" as IconName, disabled: !sendOk, run: () => this.pick("files") },
        ]
      : [];
    this.openMenu(anchor, [
      { title: w.c("sendTo"), items: [{ label: w.c("pasteOn"), sub: paste.subtitle, icon: "paste", disabled: !paste.enabled, run: () => void this.pasteOnMac() }, ...files] },
      {
        items: [
          { label: w.c("copyFrom"), sub: copy.subtitle, icon: "copyFrom", disabled: !copy.enabled, run: () => void this.copyFromMac() },
          { label: w.t("openClipboard"), icon: "clipboard", run: () => this.openClipboardSheet() },
        ],
      },
    ]);
  }

  private openPickMenu(anchor: HTMLElement): void {
    const w = this.words;
    this.openMenu(anchor, [{ items: [{ label: w.t("photos"), icon: "photo", run: () => this.pick("photos") }, { label: w.t("files"), icon: "folder", run: () => this.pick("files") }] }]);
  }

  private openClipboardSheet(): void {
    const b = this._backend;
    if (!b) return;
    const page = document.createElement(tagNames.clipboard) as YoyoClipboardElement;
    page.host = this._host;
    page.computer = this.isMac ? "mac" : (this.status?.platform ?? "linux");
    page.backend = b;
    page.addEventListener("yoyo-toast", (e) => {
      e.preventDefault();
      this.toast((e as CustomEvent<string>).detail);
    });
    this.openSheet(page);
  }

  /** Paste on Mac: this browser's clipboard onto the computer's, then ⌘V (Shift+Insert on Linux) while in control. */
  private async pasteOnMac(): Promise<void> {
    if (this.clipboardBusy || !this._backend?.putClipboard) return;
    const w = this.words;
    let content: { text?: string | null; files?: File[] };
    try {
      content = await readBrowserClipboard(!!this._backend.sendsClipboardFiles);
    } catch {
      this.toast(w.t("clipboardReadRefused"));
      return;
    }
    const payload = ClipboardActions.payload(content, this._backend.clipboardFileLimit ?? DEFAULT_FILE_LIMIT, w);
    if ("error" in payload) return this.toast(payload.error);
    this.marks.phone = this.phoneCount;
    this.updateClipboardDot();
    await this.sendToComputer(payload.put, true);
  }

  private async sendToComputer(put: ClipboardPut, paste: boolean): Promise<void> {
    const b = this._backend;
    if (!b?.putClipboard) return;
    const w = this.words;
    this.clipboardBusy = true;
    if ("files" in put) this.toast(w.c("sendingFiles", { n: put.files.length }));
    try {
      const r = await b.putClipboard(put, () => {});
      this.clipboard?.set(r);
      if (paste && "text" in put) {
        if (this.controlling || this.canTake) {
          // a paste into the computer is input: watching, it takes the screen first
          this.userInput(() => {
            this.session?.keySent();
            this.send(this.isMac ? PASTE_KEY.mac : this.status?.platform === "linux" ? PASTE_KEY.linux : PASTE_KEY.windows);
            this.toast(w.c("pasted"));
          });
        } else this.toast(w.c("copiedTakeControl"));
      } else {
        this.vibrate([10, 40, 10]);
        this.toast(ClipboardActions.sentMessage(put, r.saved, w));
      }
    } catch (e) {
      if (!this.handleError(e)) this.toast(errorText(e, w));
    } finally {
      this.clipboardBusy = false;
    }
  }

  /** Copy from Mac: the computer's text / image onto this browser's clipboard; files open the Clipboard sheet. */
  private async copyFromMac(): Promise<void> {
    const state = this.clipboard;
    const b = this._backend;
    if (this.clipboardBusy || !state || !b) return;
    const w = this.words;
    this.clipboardBusy = true;
    // the write needs the click's user activation: the image's bytes may come later (a promise in the ClipboardItem)
    try {
      const status = await state.load(true);
      if (status.item) this.marks.mac = status.item.changeCount;
      const move = ClipboardActions.copyMove(status);
      switch (move.t) {
        case "text":
          await navigator.clipboard.writeText(move.text);
          this.toast(w.c("copiedFrom"));
          break;
        case "image": {
          if (!b.clipboardImage || typeof ClipboardItem === "undefined") return this.openClipboardSheet();
          const blob = b.clipboardImage(move.changeCount).then((x) => (x.type === "image/png" ? x : new Blob([x], { type: "image/png" })));
          await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
          this.toast(w.c("copiedFrom"));
          break;
        }
        case "openFiles":
          this.openClipboardSheet();
          break;
        case "concealed":
          this.toast(w.c("concealed"));
          break;
        case "empty":
          this.toast(w.c("emptyMessage"));
          break;
        case "unavailable":
          this.toast(move.reason ?? w.t("clipboardUnavailable"));
          break;
        case "nothing":
          this.toast(w.c("nothingToTake"));
          break;
      }
    } catch (e) {
      if (!this.handleError(e)) this.toast(e instanceof DOMException ? w.t("clipboardWriteRefused") : errorText(e, w));
    } finally {
      this.clipboardBusy = false;
      this.updateClipboardDot();
    }
  }

  private pick(source: "photos" | "files"): void {
    this.filePicker.accept = source === "photos" ? "image/*,video/*" : "";
    this.filePicker.value = "";
    this.filePicker.click();
  }

  private picked(): void {
    const files = [...(this.filePicker.files ?? [])];
    if (!files.length || !this._backend) return;
    const payload = ClipboardActions.payload({ files }, this._backend.clipboardFileLimit ?? DEFAULT_FILE_LIMIT, this.words);
    if ("error" in payload) return this.toast(payload.error);
    void this.sendToComputer(payload.put, false);
  }

  // ---------------------------------------------------------------- the stats line, the toast, haptics

  private updateStatsTimer(): void {
    if (!this.activeFlag || this.stats.hidden) {
      if (this.statsTimer) clearInterval(this.statsTimer);
      this.statsTimer = null;
      return;
    }
    if (this.statsTimer) return;
    this.statsTimer = setInterval(() => {
      if (this.session) this.stats.textContent = this.session.statsText();
    }, 1000);
  }

  private toast(text: string, ms = 2600): void {
    if (this._host.toast) return this._host.toast(text);
    this.toastEl.textContent = text;
    this.toastEl.classList.add("shown");
    if (this.toastTimer) clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => this.toastEl.classList.remove("shown"), ms);
  }

  private vibrate(pattern: number | number[]): void {
    try {
      navigator.vibrate?.(pattern);
    } catch {
      /* not allowed here */
    }
  }
}

// ---------------------------------------------------------------- helpers

/** What a computer last said it is (per `cacheScope`): an answer that doesn't say keeps it. */
const knownPlatform = new Map<string, string>();
const knownFeatures = new Map<string, NonNullable<ScreenStatus["features"]>>();

function noteCapabilities(s: ScreenStatus, scope: string): ScreenStatus {
  if (s.platform) knownPlatform.set(scope, s.platform);
  if (s.features) knownFeatures.set(scope, s.features);
  return { ...s, platform: knownPlatform.get(scope) ?? null, features: knownFeatures.get(scope) ?? null };
}

/** A display's name: what the computer calls it, else its kind; else the main display or a number. */
export function displayTitle(d: Display, index: number, w: Words): string {
  if (d.name) return d.name;
  if (d.kind === "builtin") return w.t("builtinDisplay");
  if (d.kind === "external") return w.t("externalDisplay");
  return d.main ? w.t("mainDisplay") : w.t("displayN", { n: index + 1 });
}

/** Its size in pixels, the scale when whole, and whether it is the main one: `3456 × 2234 @2x · Main`. */
export function displaySubtitle(d: Display, w: Words): string {
  const px = (v: number) => (Number.isFinite(v) && Math.abs(v) < 1e9 ? String(Math.round(v)) : "?");
  let s = `${px(d.width * d.scale)} × ${px(d.height * d.scale)}`;
  if (d.scale > 1 && Number.isFinite(d.scale) && d.scale === Math.round(d.scale) && d.scale < 100) s += ` @${d.scale}x`;
  if (d.main) s += ` · ${w.t("main")}`;
  return s;
}

/** This browser's clipboard: an image as a file (when files can go), else its text. Throws when the browser refuses. */
async function readBrowserClipboard(files: boolean): Promise<{ text?: string | null; files?: File[] }> {
  const c = navigator.clipboard;
  if (files && c?.read) {
    try {
      const items = await c.read();
      for (const item of items) {
        const type = item.types.find((t) => t.startsWith("image/"));
        if (type) {
          const blob = await item.getType(type);
          return { files: [new File([blob], `image.${type.split("/")[1] ?? "png"}`, { type })] };
        }
      }
      const text = items.find((i) => i.types.includes("text/plain"));
      if (text) return { text: await (await text.getType("text/plain")).text() };
    } catch {
      /* fall back to the text */
    }
  }
  return { text: await c.readText() };
}
