import { LinkRequestError, linkScreen, type LinkSession } from "@yoyocontrol/link-web";
import type {
  ScreenLink,
  ScreenLinkAudio,
  ScreenLinkAudioEvent,
  ScreenLinkControlAnswer,
  ScreenLinkVideo,
  ScreenLinkVideoEvent,
} from "@yoyocontrol/screen-web";
import type { MacConnection } from "./connection.js";

/** A session's screen media (default link-web's `linkScreen`). */
export type ScreenLinkFactory = (session: LinkSession) => ScreenLink;

/**
 * The Screen page's media way to one Mac (`ScreenBackend.screenLink`): one stable `ScreenLink` over the connection's
 * sessions. Each stream opens on the session open now, or on the next one (dialed for it); a stream whose session ends
 * hears `failed` (the page opens it again, which dials again). Input goes on the open session; control waits for one.
 * `isClosed` / `closed` are the backend's end, not one session's.
 */
export class DirectScreenLink implements ScreenLink {
  private readonly links = new WeakMap<LinkSession, ScreenLink>();
  private inputError: ((error: unknown) => void) | null = null;
  private ended = false;
  private resolveClosed!: (why: string) => void;
  readonly closed = new Promise<string>((r) => (this.resolveClosed = r));

  constructor(
    private readonly connection: MacConnection,
    private readonly make: ScreenLinkFactory = linkScreen,
  ) {}

  /** The screen media of the session open now. */
  private get media(): ScreenLink | null {
    const s = this.connection.current;
    return s ? this.mediaOf(s) : null;
  }

  private mediaOf(session: LinkSession): ScreenLink {
    let m = this.links.get(session);
    if (!m) {
      m = this.make(session);
      m.setInputErrorHandler((e) => this.inputError?.(e));
      this.links.set(session, m);
    }
    return m;
  }

  get pathLabel(): string {
    return this.media?.pathLabel ?? "link";
  }

  get isLocalNetwork(): boolean {
    return this.media?.isLocalNetwork ?? false;
  }

  get rttMinMs(): number | null {
    return this.media?.rttMinMs ?? null;
  }

  get statsLine(): string | null {
    return this.media?.statsLine ?? null;
  }

  get isClosed(): boolean {
    return this.ended;
  }

  /** The backend is gone for good. */
  end(why: string): void {
    if (this.ended) return;
    this.ended = true;
    this.resolveClosed(why);
  }

  /** The screen media of an open session (dialed when there is none). */
  private async ready(): Promise<ScreenLink> {
    return this.mediaOf(await this.connection.session());
  }

  openVideo(query: string, onEvent: (e: ScreenLinkVideoEvent) => void): ScreenLinkVideo {
    let video: ScreenLinkVideo | null = null;
    let closed = false;
    const pending: ((v: ScreenLinkVideo) => void)[] = [];
    const when = (f: (v: ScreenLinkVideo) => void) => (video ? f(video) : pending.push(f));
    this.ready().then(
      (m) => {
        if (closed) return;
        video = m.openVideo(query, onEvent);
        for (const f of pending.splice(0)) f(video);
      },
      (e: unknown) => !closed && onEvent({ type: "failed", reason: e instanceof Error ? e.message : String(e) }),
    );
    return {
      decoded: (frame, ok) => when((v) => v.decoded(frame, ok)),
      requestKeyframe: () => when((v) => v.requestKeyframe()),
      report: (report) => when((v) => v.report(report)),
      close: () => {
        closed = true;
        pending.length = 0;
        video?.close();
      },
    };
  }

  openAudio(query: string, onEvent: (e: ScreenLinkAudioEvent) => void): ScreenLinkAudio {
    let audio: ScreenLinkAudio | null = null;
    let closed = false;
    this.ready().then(
      (m) => {
        if (!closed) audio = m.openAudio(query, onEvent);
      },
      (e: unknown) => !closed && onEvent({ type: "failed", reason: e instanceof Error ? e.message : String(e) }),
    );
    return {
      close: () => {
        closed = true;
        audio?.close();
      },
    };
  }

  /** On the open session; none open: a 503 (the page reports it as a network failure and the stream reconnects). */
  sendInput(json: string, move: boolean): void {
    const m = this.media;
    if (!m) throw new LinkRequestError(503, "not connected to the Mac");
    m.sendInput(json, move);
  }

  setInputErrorHandler(handler: ((error: unknown) => void) | null): void {
    this.inputError = handler;
  }

  /** `control.take` / `control.release` on a session (dialed when needed). */
  async control(take: boolean): Promise<ScreenLinkControlAnswer> {
    return (await this.ready()).control(take);
  }
}
