import { LinkRequestError, linkScreen } from "@yoyocontrol/link-web";
/**
 * The Screen page's media way to one Mac (`ScreenBackend.screenLink`): one stable `ScreenLink` over the connection's
 * sessions. Each stream opens on the session open now, or on the next one (dialed for it); a stream whose session ends
 * hears `failed` (the page opens it again, which dials again). Input goes on the open session; control waits for one.
 * `isClosed` / `closed` are the backend's end, not one session's.
 */
export class DirectScreenLink {
    connection;
    make;
    links = new WeakMap();
    inputError = null;
    ended = false;
    resolveClosed;
    closed = new Promise((r) => (this.resolveClosed = r));
    constructor(connection, make = linkScreen) {
        this.connection = connection;
        this.make = make;
    }
    /** The screen media of the session open now. */
    get media() {
        const s = this.connection.current;
        return s ? this.mediaOf(s) : null;
    }
    mediaOf(session) {
        let m = this.links.get(session);
        if (!m) {
            m = this.make(session);
            m.setInputErrorHandler((e) => this.inputError?.(e));
            this.links.set(session, m);
        }
        return m;
    }
    get pathLabel() {
        return this.media?.pathLabel ?? "link";
    }
    get isLocalNetwork() {
        return this.media?.isLocalNetwork ?? false;
    }
    get rttMinMs() {
        return this.media?.rttMinMs ?? null;
    }
    get statsLine() {
        return this.media?.statsLine ?? null;
    }
    get isClosed() {
        return this.ended;
    }
    /** The backend is gone for good. */
    end(why) {
        if (this.ended)
            return;
        this.ended = true;
        this.resolveClosed(why);
    }
    /** The screen media of an open session (dialed when there is none). */
    async ready() {
        return this.mediaOf(await this.connection.session());
    }
    openVideo(query, onEvent) {
        let video = null;
        let closed = false;
        const pending = [];
        const when = (f) => (video ? f(video) : pending.push(f));
        this.ready().then((m) => {
            if (closed)
                return;
            video = m.openVideo(query, onEvent);
            for (const f of pending.splice(0))
                f(video);
        }, (e) => !closed && onEvent({ type: "failed", reason: e instanceof Error ? e.message : String(e) }));
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
    openAudio(query, onEvent) {
        let audio = null;
        let closed = false;
        this.ready().then((m) => {
            if (!closed)
                audio = m.openAudio(query, onEvent);
        }, (e) => !closed && onEvent({ type: "failed", reason: e instanceof Error ? e.message : String(e) }));
        return {
            close: () => {
                closed = true;
                audio?.close();
            },
        };
    }
    /** On the open session; none open: a 503 (the page reports it as a network failure and the stream reconnects). */
    sendInput(json, move) {
        const m = this.media;
        if (!m)
            throw new LinkRequestError(503, "not connected to the Mac");
        m.sendInput(json, move);
    }
    setInputErrorHandler(handler) {
        this.inputError = handler;
    }
    /** `control.take` / `control.release` on a session (dialed when needed). */
    async control(take) {
        return (await this.ready()).control(take);
    }
}
