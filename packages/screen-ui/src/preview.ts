import type { ScreenBackend, ScreenHost, ScreenStatus, UnavailableAction } from "./contracts.js";
import { Words } from "./strings.js";
import { mainDisplay, type Controller } from "@yoyocontrol/screen-web";

/**
 * A computer's screen as a row of an app's list (iOS `YoyoScreenPreview`, docs/PROTOCOL.md「屏幕」): whether it has
 * one, who drives it, and a small frame of the main display, asked again every few seconds while the row is on screen
 * (`ScreenBackend.frame`). A sleeping display is left asleep (a frame would wake it). The app draws the row from
 * `state`, `image` and `line()`; `start` / `stop` follow the row; it pauses while the page is hidden.
 */
export type PreviewState =
  | { t: "unknown" }
  /** The computer has no screen (404): no row. */
  | { t: "absent" }
  | { t: "unavailable"; reason: string | null }
  | { t: "action"; action: UnavailableAction }
  | { t: "needsPermission" }
  | { t: "asleep" }
  | { t: "live"; controller: Controller };

export function previewState(s: ScreenStatus): PreviewState {
  if (!s.available && s.unavailableAction) return { t: "action", action: s.unavailableAction };
  if (!s.available) return { t: "unavailable", reason: s.reason ?? null };
  if (!s.screenRecording && s.platform !== "linux" && (s.platform ?? "mac") === "mac") return { t: "needsPermission" };
  if (mainDisplay(s)?.asleep) return { t: "asleep" };
  return { t: "live", controller: s.controller };
}

const sameState = (a: PreviewState, b: PreviewState) => JSON.stringify(a) === JSON.stringify(b);

export class ScreenPreview {
  static readonly EVERY_MS = 5000;
  static readonly MAX_WIDTH = 320;
  static readonly QUALITY = 50;
  state: PreviewState = { t: "unknown" };
  /** An object URL of the latest frame (kept while it can't be refreshed; revoked when replaced). */
  image: string | null = null;
  /** The computer's platform ("mac" until a status says). */
  platform: string;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private running = false;
  private onChange: (() => void) | null = null;
  private readonly words: Words;
  private readonly visibility = () => (document.visibilityState === "hidden" ? this.pause() : this.resume());

  constructor(
    private readonly backend: ScreenBackend,
    host: ScreenHost = {},
  ) {
    this.platform = backend.platformHint ?? "mac";
    this.words = new Words(host);
  }

  /** The row shows (the computer has a screen, or hasn't answered yet). */
  get showsRow(): boolean {
    return this.state.t !== "absent";
  }

  /** The row's second line while nobody drives it: "Watch the Mac, or take control". */
  line(): string {
    this.words.mac = this.platform === "mac";
    return this.words.c("watch");
  }

  /** The row is on screen: keep it current (`onChange` after every change). */
  start(onChange: () => void): void {
    this.onChange = onChange;
    if (!this.running) document.addEventListener("visibilitychange", this.visibility);
    this.running = true;
    this.resume();
  }

  stop(): void {
    this.running = false;
    document.removeEventListener("visibilitychange", this.visibility);
    this.pause();
  }

  private resume(): void {
    if (!this.running || this.timer || document.visibilityState === "hidden") return;
    const loop = async () => {
      await this.tick();
      if (this.running && this.timer !== null) this.timer = setTimeout(() => void loop(), ScreenPreview.EVERY_MS);
    };
    this.timer = setTimeout(() => void loop(), 0);
  }

  private pause(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private async tick(): Promise<void> {
    let s: ScreenStatus;
    try {
      s = await this.backend.status();
    } catch (e) {
      if ((e as { status?: number }).status === 404) this.set({ t: "absent" });
      return;
    }
    if (s.platform) this.platform = s.platform;
    this.set(previewState(s));
    if (this.state.t !== "live" || !this.backend.frame) return;
    try {
      const blob = await this.backend.frame(mainDisplay(s)?.id, ScreenPreview.MAX_WIDTH, ScreenPreview.QUALITY);
      if (this.image) URL.revokeObjectURL(this.image);
      this.image = URL.createObjectURL(blob);
      this.onChange?.();
    } catch {
      /* a frame that fails keeps the last one */
    }
  }

  private set(s: PreviewState): void {
    if (sameState(s, this.state)) return;
    this.state = s;
    this.onChange?.();
  }
}
