import { LinkError } from "@yoyocontrol/link-web";
import { linkSetControl, RequestError, requestError, type ControlDevice, type Input } from "@yoyocontrol/screen-web";
import type { ClipboardPut, ClipboardPutResponse, ClipboardStatus, ScreenBackend, ScreenEvent, ScreenRoute, ScreenStatus } from "@yoyocontrol/screen-ui";
import type { MacConnection } from "./connection.js";
import { DirectError, directError } from "./errors.js";
import { MacEvents } from "./events.js";
import { agentActive, clipboardFromMac, filenameOf, statusFromMac } from "./mapping.js";
import { DirectScreenLink, type ScreenLinkFactory } from "./screen-link.js";
import type { PairedMac } from "./store.js";

/** The one way a browser has to a Mac: uu Link over WebRTC, signaled through the relay. Not a shortcut (nothing to
 *  fall back to); `isLocalNetwork` and the stats line's label come from the session's path. */
export const LINK_ROUTE: ScreenRoute = { id: "link", isLocalNetwork: false, isDirect: true, isShortcut: false, label: "link", report: "direct" };

export interface DirectBackendOptions {
  /** The Mac no longer knows this browser (a 401, `unauthorized` on dial): forget it or pair again. */
  onUnpaired?: () => void;
  /** Tests: the session's screen media. */
  screenLink?: ScreenLinkFactory;
}

/**
 * Yoyo Control's own `ScreenBackend` for a browser (the iOS kit's `DirectBackend` on its link way): every request is
 * RPC on the Mac's uu Link session (`/status`, `/focus`, `/frame`, `/clipboard*`, `/events`), the Screen page's media,
 * pointer and input ride the session itself (`screenLink`), control is `control.take` / `control.release`. Answers are
 * mapped onto the pages' shapes (`mapping.ts`). Errors are screen-web `RequestError`s (`DirectError` when the Mac
 * can't be reached: 523 offline, 522 unreachable — the pages' default `isUnreachable` — and 401 unpaired).
 */
export class DirectBackend implements ScreenBackend {
  readonly cacheScope: string;
  readonly platformHint: string;
  readonly route = LINK_ROUTE;
  /** A browser sends text only (files on the Mac's clipboard are paths there). */
  readonly sendsClipboardFiles = false;
  private readonly link: DirectScreenLink;
  private readonly hub: MacEvents;
  private unpairedFired = false;

  constructor(
    readonly mac: PairedMac,
    readonly connection: MacConnection,
    private readonly options: DirectBackendOptions = {},
  ) {
    this.cacheScope = `yoyocontrol:${mac.id}`;
    this.platformHint = mac.platform ?? "mac";
    this.link = new DirectScreenLink(connection, options.screenLink);
    this.hub = new MacEvents(
      {
        open: (signal) => this.call("/events", { signal }),
        agentActive: async () => agentActive((await (await this.call("/status")).json()) as Record<string, unknown>),
      },
      () => this.unpaired(),
    );
  }

  private unpaired(): void {
    if (this.unpairedFired) return;
    this.unpairedFired = true;
    this.options.onUnpaired?.();
  }

  /** One request as RPC on the session (dialed when needed); a non-2xx answer throws its `RequestError`. */
  private async call(path: string, init: RequestInit = {}): Promise<Response> {
    let res: Response;
    try {
      const session = await this.connection.session();
      res = await session.fetch(path, init);
    } catch (e) {
      if (e instanceof DirectError) {
        if (e.kind === "unpaired") this.unpaired();
        throw e;
      }
      if (init.signal?.aborted) throw e;
      // the session broke under the request: the next one dials again
      if (e instanceof LinkError) throw directError(e, false, this.connection.messages);
      throw e;
    }
    if (!res.ok) {
      if (res.status === 401) this.unpaired();
      throw await requestError(res);
    }
    return res;
  }

  private async json(path: string, init?: RequestInit): Promise<Record<string, unknown>> {
    return (await (await this.call(path, init)).json()) as Record<string, unknown>;
  }

  async status(): Promise<ScreenStatus> {
    return statusFromMac(await this.json("/status"));
  }

  /** RPC on the session (the page's media doesn't come this way: `screenLink`). */
  transport(_route: ScreenRoute) {
    return { fetch: (path: string, init?: RequestInit) => this.call(path, init) };
  }

  async input(input: Input): Promise<void> {
    this.link.sendInput(JSON.stringify(input), input.type === "move");
  }

  async setControl(controller: "user" | "none", _route: ScreenRoute, _device: ControlDevice, keepalive: boolean): Promise<ScreenStatus | null> {
    // the page is going: release on the session open now, if any (no dial for it)
    if (keepalive && controller === "none" && !this.connection.current) return null;
    // a 409 controlled-elsewhere with the holder when another device has it, as POST /control answers
    await linkSetControl(this.link, controller === "user");
    return keepalive ? null : this.status();
  }

  async focus(display: number | undefined): Promise<{ editable: boolean }> {
    const j = await this.json(display === undefined ? "/focus" : `/focus?display=${display}`);
    return { editable: j.editable === true };
  }

  async frame(display: number | undefined, maxWidth: number, quality: number): Promise<Blob> {
    const q = new URLSearchParams({ maxWidth: String(Math.round(maxWidth)), quality: String(quality) });
    if (display !== undefined) q.set("display", String(display));
    return (await this.call(`/frame?${q}`)).blob();
  }

  /** The prompts are the Mac's to show: a paired device can't ask for them (a 403 saying where to grant them). */
  async requestPermissions(): Promise<ScreenStatus> {
    throw new RequestError(403, this.connection.messages.permissions ?? "Grant the permissions from Yoyo Control’s menu on the Mac.");
  }

  /** `GET /clipboard` (503: the Mac can't do clipboard now, its reason kept). */
  async clipboard(): Promise<ClipboardStatus> {
    try {
      return clipboardFromMac(await this.json("/clipboard"));
    } catch (e) {
      if (e instanceof RequestError && e.status === 503 && !(e instanceof DirectError)) return { available: false, reason: e.message };
      throw e;
    }
  }

  async clipboardImage(_changeCount: number): Promise<Blob> {
    return (await this.call("/clipboard/image")).blob();
  }

  async clipboardFile(index: number, _changeCount: number, progress: (fraction: number) => void): Promise<{ blob: Blob; name?: string; mime?: string }> {
    const res = await this.call(`/clipboard/file?index=${index}`);
    const blob = await res.blob();
    progress(1);
    const name = filenameOf(res.headers.get("content-disposition"));
    const mime = res.headers.get("content-type");
    return { blob, ...(name ? { name } : {}), ...(mime ? { mime } : {}) };
  }

  async putClipboard(put: ClipboardPut, progress: (fraction: number) => void): Promise<ClipboardPutResponse> {
    if (!("text" in put)) throw new RequestError(501, "a browser sends text only");
    const body = await this.json("/clipboard", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text: put.text }) });
    progress(1);
    return clipboardFromMac(body);
  }

  events(): AsyncIterable<ScreenEvent> {
    return this.hub.subscribe();
  }

  screenLink(_route: ScreenRoute): DirectScreenLink {
    return this.link;
  }

  /** The page is gone for good: the events reader and the session end. */
  close(): void {
    this.hub.close();
    this.link.end("closed");
    this.connection.close();
  }
}
