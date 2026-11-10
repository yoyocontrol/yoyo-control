import {
  AVSyncDriver,
  browserNetPath,
  ConnectionModel,
  Interactivity,
  isUnreachableStatus,
  linkInputSender,
  linkSetControl,
  NetSampler,
  ReopenPolicy,
  RequestError,
  retryDelay,
  ScreenAudio,
  sendInput,
  setControl as httpSetControl,
  statsLines,
  VideoStream,
  withNetSampler,
  type AudioState,
  type ConnectionLike,
  type ControlDevice,
  type CursorPart,
  type DisplayState,
  type Input,
  type Phase,
  type ScreenLink,
  type ScreenTransport,
  type StreamStatusPart,
} from "@yoyocontrol/screen-web";
import { DIRECT_ROUTE, type ScreenBackend, type ScreenRoute, type ScreenRouting, type ScreenStatus } from "./contracts.js";

/**
 * The Screen page's media without its views (iOS `ScreenSession`): the stream and its playback on screen-web's
 * `VideoStream` (drawn into the page's canvas), the sound (`ScreenAudio`) and the A/V sync between them
 * (`AVSyncDriver`), the way it goes (the backend's routing, if any: a stream about to open waits for a decision, moves
 * when the way changes, falls back when a shortcut fails; a way that is a uu Link session — `screenLink(route)` —
 * carries the pictures, the sound, input and control itself), the playout report's network part (`NetSampler`), the
 * connection state (`ConnectionModel`, from the stream's status parts, the states the status and events carry, and
 * gaps), reopening (`ReopenPolicy`), interactive playback (`Interactivity`), input with fallback, control, focus, and
 * the stats line (screen-web's `statsLines`).
 */

export interface SessionCallbacks {
  /** A picture was drawn (its size in pixels). */
  picture(width: number, height: number): void;
  cursor(part: CursorPart): void;
  /** A new stream opened: the pointer starts over. */
  streamOpened(): void;
  /** The connection phase may have changed. */
  connection(): void;
  /** The sound's button may have changed (shown, on / off). */
  audio(): void;
  /** The display is gone or the status may be stale: the page asks for it again. */
  refreshStatus(): void;
  /** Every error goes here first; true = handled. */
  handleError(error: unknown): boolean;
}

export interface SessionOptions {
  canvas: HTMLCanvasElement;
  /** Where the sound setting is kept (localStorage key; null: not kept). */
  audioKey: string | null;
}

/** The stream request's maximum width (docs/PROTOCOL.md: 3840). */
export const VIDEO_MAX_WIDTH = 3840;

export class ScreenSession {
  readonly routing: ScreenRouting | null;
  readonly interactivity = new Interactivity();
  readonly connection = new ConnectionModel();
  active = false;
  /** The display shown (undefined: the server's default). */
  display: number | undefined;
  displayIsMain = true;
  /** The display shown is a virtual one: its pictures don't carry same-instant times, so no A/V sync. */
  displayIsVirtual = false;
  /** This side's network for the playout report (route, path, input round trips, failures, bytes). */
  readonly net = new NetSampler();
  /** The picture can be shown (the page says: the status allows it). */
  canShow = false;
  hasFrame = false;

  private video: VideoStream | null = null;
  /** The link the open stream is on (null: HTTP). */
  private streamLink: ScreenLink | null = null;
  private streamRoute: ScreenRoute;
  private streamToken = 0;
  private streamResponded = false;
  private delivered = false;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  private openTimer: ReturnType<typeof setTimeout> | null = null;
  private decisionTimer: ReturnType<typeof setTimeout> | null = null;
  private decisionSince: number | null = null;
  private pendingOpen = false;
  private waitingToRetry = false;
  private waitingOnUnavailable = false;
  private connectionTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly reopen = new ReopenPolicy();
  /** The last status the page gave (control over a link answers with the holder only). */
  private lastStatus: ScreenStatus | null = null;
  private readonly connectionInfo: (ConnectionLike & EventTarget) | null;
  private readonly pathChanged = () => (this.net.path = browserNetPath());

  // sound
  private audioOnPref: boolean;
  private audio: ScreenAudio;
  private audioState: AudioState = "off";
  private audioRoute: ScreenRoute | null = null;
  private audioOffByServer = false;
  private audioGaveUp = false;
  private readonly sync: AVSyncDriver;
  private inputLink: ScreenLink | null = null;

  constructor(
    readonly backend: ScreenBackend,
    private readonly opts: SessionOptions,
    private readonly cb: SessionCallbacks,
  ) {
    this.routing = backend.makeRouting?.() ?? null;
    this.streamRoute = this.currentRoute;
    if (this.routing) this.routing.onChange = () => this.routeChanged();
    this.audioOnPref = readPref(opts.audioKey) !== "0";
    // the sound goes the stream's way (it moves with the stream): over its link when it has one, else HTTP
    const audioRoute = () => this.audioRoute ?? this.way;
    this.audio = new ScreenAudio({ fetch: (path, init) => backend.transport(audioRoute()).fetch(path, init) }, (s) => this.audioChanged(s), {
      link: () => backend.screenLink?.(audioRoute()) ?? null,
      lan: () => (backend.screenLink?.(audioRoute())?.isLocalNetwork ?? audioRoute().isLocalNetwork),
    });
    this.sync = new AVSyncDriver(this.audio, () => (this.displayIsVirtual ? null : this.video));
    this.net.path = browserNetPath();
    this.connectionInfo = ((globalThis.navigator as { connection?: ConnectionLike & EventTarget } | undefined)?.connection ?? null) as (ConnectionLike & EventTarget) | null;
    this.connectionInfo?.addEventListener?.("change", this.pathChanged);
  }

  get currentRoute(): ScreenRoute {
    return this.routing?.current ?? this.backend.route ?? DIRECT_ROUTE;
  }
  /** The way requests go now (the stream's while one is open). */
  get way(): ScreenRoute {
    return this.video ? this.streamRoute : this.currentRoute;
  }
  get link(): ScreenLink | null {
    return this.backend.screenLink?.(this.way) ?? null;
  }

  // ---------------------------------------------------------------- lifecycle

  newVisit(): void {
    this.audioGaveUp = false;
    this.reopen.reset();
    this.routing?.newVisit();
  }

  activate(): void {
    if (this.active) return;
    this.active = true;
    this.routing?.activate();
    this.updateFrames();
    this.cb.connection();
  }

  /** The page stops: the stream, the sound, interactive playback. The way stays until `leaveRoute`. */
  deactivate(): void {
    this.active = false;
    this.stopFrames();
    this.stopAudio();
    this.clearTimer("connectionTimer");
    this.interactivity.reset();
  }

  leaveRoute(): void {
    this.routing?.leave();
  }

  /** The page is gone for good. */
  dispose(): void {
    this.deactivate();
    this.audio.dispose();
    this.routing?.close?.();
    this.inputLink?.setInputErrorHandler(null);
    this.connectionInfo?.removeEventListener?.("change", this.pathChanged);
  }

  // ---------------------------------------------------------------- status

  statusChanged(s: ScreenStatus): void {
    this.lastStatus = s;
    for (const st of s.states ?? []) if (this.isOurs(st)) this.connection.status({ ...st, console: s.console ?? null }, performance.now());
    if (s.console) this.connection.locked = s.console.locked;
    const off = s.features?.audio === false;
    if (off !== this.audioOffByServer) {
      this.audioOffByServer = off;
      if (off) this.stopAudio();
      else this.syncAudio();
      this.cb.audio();
    }
  }

  statesChanged(states: DisplayState[], console: { locked: boolean } | null | undefined): void {
    const before = this.connection.phase(performance.now());
    for (const st of states) if (this.isOurs(st)) this.connection.status({ ...st, console: console ?? null }, performance.now());
    if (this.displayIsMain && this.display !== undefined && !states.some((s) => s.display === this.display) && states.some((s) => s.main)) this.cb.refreshStatus();
    this.updateConnection();
    this.reopenIfReady(before);
  }

  private isOurs(st: DisplayState): boolean {
    return this.display === undefined ? st.main === true : st.display === this.display || (this.displayIsMain && st.main === true);
  }

  private reopenIfReady(before: Phase): void {
    if (!this.active || !this.canShow || this.video) return;
    const now = this.connection.phase(performance.now());
    if (now.t === before.t) return;
    if (this.waitingOnUnavailable ? now.t === "unavailable" : !(this.waitingToRetry && now.t === "live")) return;
    this.clearTimer("retryTimer");
    this.waitingOnUnavailable = false;
    this.waitingToRetry = false;
    this.openStream();
  }

  /** Retry (the display was unavailable): ask again now, keeping the still. */
  retryConnection(): void {
    this.connection.retry(performance.now());
    this.reopen.reset();
    this.stopFrames();
    this.updateFrames();
    this.updateConnection();
  }

  /** The phase now (and a timer for when it changes by itself). */
  phase(): Phase {
    return this.connection.phase(performance.now());
  }

  updateConnection(): void {
    this.clearTimer("connectionTimer");
    const d = this.connection.deadline();
    if (d !== null && this.active) {
      const wait = d - performance.now();
      if (wait > 0) this.connectionTimer = setTimeout(() => this.updateConnection(), wait + 5);
    }
    this.cb.connection();
  }

  // ---------------------------------------------------------------- frames

  updateFrames(): void {
    if (!this.active || !this.canShow) {
      this.stopFrames();
      this.stopAudio();
      return;
    }
    if (!this.video && !this.waitingToRetry && !this.pendingOpen) this.openStream();
  }

  /** Another display: the picture goes, and what was known of the last one's connection. */
  restartFrames(): void {
    this.stopFrames();
    this.hasFrame = false;
    this.updateFrames();
    this.updateConnection();
  }

  stopFrames(): void {
    this.dropStream();
    this.waitingToRetry = false;
    this.waitingOnUnavailable = false;
    this.pendingOpen = false;
    this.clearTimer("retryTimer");
    this.clearTimer("decisionTimer");
  }

  private dropStream(): void {
    if (this.video) this.connection.streamEnded(performance.now());
    this.video?.close();
    this.video = null;
    this.streamLink = null;
    this.clearTimer("openTimer");
  }

  private openStream(): void {
    this.pendingOpen = false;
    this.dropStream();
    const r = this.routing;
    r?.streamWillOpen();
    if (r?.isDeciding) {
      const since = this.decisionSince ?? performance.now();
      this.decisionSince = since;
      const left = since + r.decisionWaitMs - performance.now();
      if (left > 0) {
        this.pendingOpen = true;
        if (!this.decisionTimer)
          this.decisionTimer = setTimeout(() => {
            this.decisionTimer = null;
            if (this.pendingOpen && this.active && this.canShow) this.openStream();
          }, left);
        return;
      }
    }
    this.clearTimer("decisionTimer");
    this.waitingToRetry = false;
    const token = ++this.streamToken;
    const route = this.currentRoute;
    this.streamRoute = route;
    this.streamResponded = false;
    this.delivered = false;
    const link = this.backend.screenLink?.(route) ?? null;
    this.streamLink = link;
    const common = {
      canvas: this.opts.canvas,
      ...(this.display !== undefined ? { display: this.display } : {}),
      interactivity: this.interactivity,
      net: this.net,
      audioReport: () => (this.audioState === "playing" || this.audioState === "waiting" ? this.audio.report() : null),
    };
    // over a link the stream opens on it (video.open; its route from the link's path); else POST /stream on the route
    const video = new VideoStream(
      link ? { ...common, link } : { ...common, transport: this.observed(route, token), route: route.isLocalNetwork ? "lan" : route.report },
      {
        onPicture: (w, h) => {
          if (token !== this.streamToken) return;
          const first = !this.delivered;
          this.delivered = true;
          this.hasFrame = true;
          this.connection.picture(performance.now());
          if (first) {
            this.reopen.reset();
            this.updateConnection();
          }
          this.cb.picture(w, h);
        },
        onCursor: (c) => token === this.streamToken && this.cb.cursor(c),
        onStatus: (s) => token === this.streamToken && this.streamStatus(s),
        onEnd: (info) => token === this.streamToken && this.streamEnded(info),
        onOpened: () => {
          if (token === this.streamToken) this.responded();
        },
      },
    );
    this.video = video;
    this.connection.streamOpened();
    this.cb.streamOpened();
    void video.run();
    if (r && route.isShortcut) {
      this.openTimer = setTimeout(() => {
        this.openTimer = null;
        if (token !== this.streamToken || !this.video || this.streamResponded) return;
        r.streamFailed(route, false);
        if (this.active && this.canShow) this.openStream();
      }, r.openTimeoutMs);
    }
    this.syncAudio();
  }

  private streamStatus(s: StreamStatusPart): void {
    this.connection.status(s, performance.now());
    if (s.console) this.connection.locked = s.console.locked;
    this.updateConnection();
  }

  /** The open stream was answered (its response, or `video.opened` on a link): no open timeout. */
  private responded(): void {
    this.streamResponded = true;
    this.clearTimer("openTimer");
  }

  private streamEnded(info: { delivered: boolean; failed: boolean; lifetimeMs: number; status: number | null; error: string | null }): void {
    this.video = null;
    this.streamLink = null;
    this.clearTimer("openTimer");
    this.connection.streamEnded(performance.now());
    const route = this.streamRoute;
    const shortcut = this.routing !== null && route.isShortcut;
    this.updateConnection();
    if (!this.active || !this.canShow) return;
    if (info.status !== null && info.status !== 401 && this.cb.handleError(new RequestError(info.status, info.error ?? `HTTP ${info.status}`))) return;
    if (shortcut && (info.failed || !info.delivered)) {
      this.routing!.streamFailed(route, info.status === 401);
      this.openStream();
      return;
    }
    if (info.status === 401 && this.cb.handleError(new RequestError(401, info.error ?? "unauthorized"))) return;
    const phase = this.connection.phase(performance.now());
    if (phase.t === "unavailable") {
      this.waitingOnUnavailable = true;
      this.retryTimer = setTimeout(() => {
        this.retryTimer = null;
        this.waitingOnUnavailable = false;
        if (this.active && this.canShow && !this.video) {
          this.cb.refreshStatus();
          this.openStream();
        }
      }, retryDelay(phase.retryAt));
      return;
    }
    const wait = this.reopen.ended(info.delivered, info.failed, info.lifetimeMs);
    if (wait === 0) {
      this.openStream();
      return;
    }
    this.waitingToRetry = true;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      this.waitingToRetry = false;
      if (this.active && this.canShow && !this.video) this.openStream();
    }, wait);
    // a stream refused for good (403 / 404 / 503) may mean the status changed
    if (info.status === 403 || info.status === 404 || info.status === 503) this.cb.refreshStatus();
  }

  /** The route's HTTP transport with the stream's response and its acks watched (the routing). */
  private observed(route: ScreenRoute, token: number): ScreenTransport {
    const inner = this.backend.transport(route);
    return {
      fetch: async (path, init) => {
        const kind = path.split("?", 1)[0];
        if (kind === "/stream/ack") {
          try {
            const res = await inner.fetch(path, init);
            if (token === this.streamToken) this.routing?.ackAnswered(route, res.status);
            return res;
          } catch (e) {
            if (token === this.streamToken) this.routing?.ackAnswered(route, null);
            throw e;
          }
        }
        const res = await inner.fetch(path, init);
        if (kind === "/stream" && token === this.streamToken) this.responded();
        return res;
      },
    };
  }

  private routeChanged(): void {
    const r = this.routing;
    if (!r) return;
    if (!r.isDeciding) {
      this.decisionSince = null;
      if (this.pendingOpen && this.active && this.canShow) return this.openStream();
    }
    if (this.video && this.streamRoute.id !== r.current.id && this.active && this.canShow && !this.pendingOpen) return this.openStream();
    // a stream that failed on a way left behind, or on a link whose session ended (a new session on the same way),
    // needn't wait for its retry
    const link = this.backend.screenLink?.(r.current) ?? null;
    const newLink = link !== null && link !== this.streamLink;
    if (!this.video && this.waitingToRetry && !this.waitingOnUnavailable && (this.streamRoute.id !== r.current.id || newLink) && this.active && this.canShow && !this.pendingOpen && !r.isDeciding) {
      this.clearTimer("retryTimer");
      this.openStream();
    }
  }

  // ---------------------------------------------------------------- sound

  get audioOn(): boolean {
    return this.audioOnPref;
  }
  /** The speaker shows (the computer has sound, this browser can play it). */
  get audioShown(): boolean {
    return !this.audioOffByServer && !this.audioGaveUp && this.audioState !== "none";
  }
  get audioPlaying(): AudioState {
    return this.audioState;
  }

  /** The speaker button (a user gesture: the AudioContext may start). */
  setAudioOn(on: boolean): void {
    this.audioOnPref = on;
    writePref(this.opts.audioKey, on ? "1" : "0");
    if (on) this.syncAudio(true);
    else this.stopAudio();
    this.cb.audio();
  }

  /** A user gesture on the page: a sound that is on but couldn't start without one starts now. */
  gesture(): void {
    if (this.audioOnPref && this.audioState === "off" && this.video) this.syncAudio(true);
  }

  private syncAudio(gesture = false): void {
    if (!this.active || !this.video || !this.audioOnPref || this.audioOffByServer || this.audioGaveUp) {
      this.stopAudio();
      return;
    }
    if (this.audioRoute && this.audioRoute.id === this.streamRoute.id && this.audioState !== "off") return;
    // the sound moves with the stream: the same ScreenAudio (its AudioContext lasts the visit) on the new way
    if (this.audioState !== "off") this.audio.stop();
    this.audioRoute = this.streamRoute;
    if (gesture || this.audioUnlocked) void this.audio.start();
  }

  /** Browsers start sound only after a gesture on the page; once one came, a reopen may start it by itself. */
  private audioUnlocked = false;

  private stopAudio(): void {
    if (this.audioState !== "off" && this.audioState !== "none") this.audio.stop();
    this.audioRoute = null;
    this.sync.stop();
  }

  private audioChanged(s: AudioState): void {
    if (s === "playing") this.audioUnlocked = true;
    if (s === "none") this.audioGaveUp = true;
    this.audioState = s;
    // the sync runs while a sound stream plays (the iOS kit's syncTimer)
    if (s === "playing" || s === "waiting") this.sync.start();
    else this.sync.stop();
    this.cb.audio();
  }

  // ---------------------------------------------------------------- input, control, focus

  /** A finger / button on the picture (in control). */
  touchBegan(): void {
    this.interactivity.down();
  }
  touchEnded(): void {
    this.interactivity.up();
  }
  keySent(): void {
    this.interactivity.pulse();
  }

  /** `op` on the way in use; when it fails, the routing may name another way to send it on (once). */
  private async run<T>(route: ScreenRoute, op: (r: ScreenRoute) => Promise<T>): Promise<T> {
    try {
      return await op(route);
    } catch (e) {
      const next = this.routing ? await this.routing.fallback(route, e) : null;
      if (!next || next.id === route.id) throw e;
      return op(next);
    }
  }

  /**
   * The input sender of the way in use when it is a link (`InputQueueOptions.link`; null: HTTP, `deliver`). Refused
   * or unacknowledged input on it comes to `onInputError`.
   */
  linkInput(onInputError: (e: unknown) => void): ((input: Input) => void) | null {
    const link = this.link;
    if (!link) return null;
    if (this.inputLink !== link) {
      this.inputLink?.setInputErrorHandler(null);
      this.inputLink = link;
      link.setInputErrorHandler(onInputError);
    }
    const send = linkInputSender(link);
    return (input) => {
      this.interactivity.pulse();
      send(input);
    };
  }

  /** One input over HTTP on the way in use (its round trip goes into the network report), with the routing's fallback. */
  async deliver(input: Input): Promise<void> {
    this.interactivity.pulse();
    const b = this.backend;
    const way = this.way;
    const http = withNetSampler((i) => this.run(way, (r) => (b.input ? b.input(i, r) : sendInput(b.transport(r), i))), this.net, () => (way.isLocalNetwork ? "lan" : way.report));
    await http(input);
  }

  /**
   * Take or release control (`route`: the way a release goes on as the page goes). Over a link: `control.take` /
   * `control.release`, answered with the last status and the new holder.
   */
  async control(controller: "user" | "none", device: ControlDevice, keepalive = false, route: ScreenRoute = this.way): Promise<ScreenStatus | null> {
    const b = this.backend;
    const link = b.screenLink?.(route) ?? null;
    if (link) {
      const held = await linkSetControl(link, controller === "user");
      const last = this.lastStatus;
      if (!last || keepalive) return null;
      return { ...last, controller: held.controller, controllerDevice: held.device, controllerSince: held.controller === "user" ? Date.now() : null };
    }
    return this.run(route, async (r) => (b.setControl ? b.setControl(controller, r, device, keepalive) : httpSetControl<ScreenStatus>(b.transport(r), controller, device, keepalive)));
  }

  async focus(): Promise<{ editable: boolean } | null> {
    const f = this.backend.focus;
    if (!f) return null;
    return this.run(this.way, (r) => f.call(this.backend, this.display, r));
  }

  /** An answer that means the way is down (the network report counts it). */
  isUnreachable(status: number, message: string | null): boolean {
    return this.backend.isUnreachable ? this.backend.isUnreachable(status, message) : isUnreachableStatus(status);
  }

  // ---------------------------------------------------------------- the stats line

  /**
   * The stats line (not localized; screen-web's `statsLines`, what iOS shows): codec, fps, KB/s, decode ms, the way,
   * the connection; the playout (gaps, hitches, stalls, buffer, jitter, drops) and the latency estimate; the link's
   * own line or the server's network grade; the sound. Each call starts a new window.
   */
  statsText(): string {
    const now = performance.now();
    const link = this.video ? this.streamLink : this.link;
    const way = link?.pathLabel ?? this.way.label;
    const connection = this.connection.statsText(now);
    if (!this.video) return [way, connection].filter((p) => p).join(" · ");
    const audio = this.audioState === "playing" || this.audioState === "waiting" ? this.audio.stats(now) : null;
    return statsLines({ stream: this.video.stats(now), way, connection, linkLine: link?.statsLine ?? null, audio }).join("\n");
  }

  // ---------------------------------------------------------------- helpers

  private clearTimer(name: "retryTimer" | "openTimer" | "decisionTimer" | "connectionTimer"): void {
    const t = this[name];
    if (t) clearTimeout(t);
    this[name] = null;
  }
}

function readPref(key: string | null): string | null {
  if (!key) return null;
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function writePref(key: string | null, value: string): void {
  if (!key) return;
  try {
    localStorage.setItem(key, value);
  } catch {
    /* private mode: not kept */
  }
}
