import { type LinkSession } from "@yoyocontrol/link-web";
import type { ScreenLink, ScreenLinkAudio, ScreenLinkAudioEvent, ScreenLinkControlAnswer, ScreenLinkVideo, ScreenLinkVideoEvent } from "@yoyocontrol/screen-web";
import type { MacConnection } from "./connection.js";
/** A session's screen media (default link-web's `linkScreen`). */
export type ScreenLinkFactory = (session: LinkSession) => ScreenLink;
/**
 * The Screen page's media way to one Mac (`ScreenBackend.screenLink`): one stable `ScreenLink` over the connection's
 * sessions. Each stream opens on the session open now, or on the next one (dialed for it); a stream whose session ends
 * hears `failed` (the page opens it again, which dials again). Input goes on the open session; control waits for one.
 * `isClosed` / `closed` are the backend's end, not one session's.
 */
export declare class DirectScreenLink implements ScreenLink {
    private readonly connection;
    private readonly make;
    private readonly links;
    private inputError;
    private ended;
    private resolveClosed;
    readonly closed: Promise<string>;
    constructor(connection: MacConnection, make?: ScreenLinkFactory);
    /** The screen media of the session open now. */
    private get media();
    private mediaOf;
    get pathLabel(): string;
    get isLocalNetwork(): boolean;
    get rttMinMs(): number | null;
    get statsLine(): string | null;
    get isClosed(): boolean;
    /** The backend is gone for good. */
    end(why: string): void;
    /** The screen media of an open session (dialed when there is none). */
    private ready;
    openVideo(query: string, onEvent: (e: ScreenLinkVideoEvent) => void): ScreenLinkVideo;
    openAudio(query: string, onEvent: (e: ScreenLinkAudioEvent) => void): ScreenLinkAudio;
    /** On the open session; none open: a 503 (the page reports it as a network failure and the stream reconnects). */
    sendInput(json: string, move: boolean): void;
    setInputErrorHandler(handler: ((error: unknown) => void) | null): void;
    /** `control.take` / `control.release` on a session (dialed when needed). */
    control(take: boolean): Promise<ScreenLinkControlAnswer>;
}
