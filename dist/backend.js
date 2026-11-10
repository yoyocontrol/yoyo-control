import { LinkError } from "@yoyocontrol/link-web";
import { linkSetControl, RequestError, requestError } from "@yoyocontrol/screen-web";
import { DirectError, directError } from "./errors.js";
import { MacEvents } from "./events.js";
import { agentActive, clipboardFromMac, filenameOf, statusFromMac } from "./mapping.js";
import { DirectScreenLink } from "./screen-link.js";
/** The one way a browser has to a Mac: uu Link over WebRTC, signaled through the relay. Not a shortcut (nothing to
 *  fall back to); `isLocalNetwork` and the stats line's label come from the session's path. */
export const LINK_ROUTE = { id: "link", isLocalNetwork: false, isDirect: true, isShortcut: false, label: "link", report: "direct" };
/**
 * Yoyo Control's own `ScreenBackend` for a browser (the iOS kit's `DirectBackend` on its link way): every request is
 * RPC on the Mac's uu Link session (`/status`, `/focus`, `/frame`, `/clipboard*`, `/events`), the Screen page's media,
 * pointer and input ride the session itself (`screenLink`), control is `control.take` / `control.release`. Answers are
 * mapped onto the pages' shapes (`mapping.ts`). Errors are screen-web `RequestError`s (`DirectError` when the Mac
 * can't be reached: 523 offline, 522 unreachable — the pages' default `isUnreachable` — and 401 unpaired).
 */
export class DirectBackend {
    mac;
    connection;
    options;
    cacheScope;
    platformHint;
    route = LINK_ROUTE;
    /** A browser sends text only (files on the Mac's clipboard are paths there). */
    sendsClipboardFiles = false;
    link;
    hub;
    unpairedFired = false;
    constructor(mac, connection, options = {}) {
        this.mac = mac;
        this.connection = connection;
        this.options = options;
        this.cacheScope = `yoyocontrol:${mac.id}`;
        this.platformHint = mac.platform ?? "mac";
        this.link = new DirectScreenLink(connection, options.screenLink);
        this.hub = new MacEvents({
            open: (signal) => this.call("/events", { signal }),
            agentActive: async () => agentActive((await (await this.call("/status")).json())),
        }, () => this.unpaired());
    }
    unpaired() {
        if (this.unpairedFired)
            return;
        this.unpairedFired = true;
        this.options.onUnpaired?.();
    }
    /** One request as RPC on the session (dialed when needed); a non-2xx answer throws its `RequestError`. */
    async call(path, init = {}) {
        let res;
        try {
            const session = await this.connection.session();
            res = await session.fetch(path, init);
        }
        catch (e) {
            if (e instanceof DirectError) {
                if (e.kind === "unpaired")
                    this.unpaired();
                throw e;
            }
            if (init.signal?.aborted)
                throw e;
            // the session broke under the request: the next one dials again
            if (e instanceof LinkError)
                throw directError(e, false, this.connection.messages);
            throw e;
        }
        if (!res.ok) {
            if (res.status === 401)
                this.unpaired();
            throw await requestError(res);
        }
        return res;
    }
    async json(path, init) {
        return (await (await this.call(path, init)).json());
    }
    async status() {
        return statusFromMac(await this.json("/status"));
    }
    /** RPC on the session (the page's media doesn't come this way: `screenLink`). */
    transport(_route) {
        return { fetch: (path, init) => this.call(path, init) };
    }
    async input(input) {
        this.link.sendInput(JSON.stringify(input), input.type === "move");
    }
    async setControl(controller, _route, _device, keepalive) {
        // the page is going: release on the session open now, if any (no dial for it)
        if (keepalive && controller === "none" && !this.connection.current)
            return null;
        // a 409 controlled-elsewhere with the holder when another device has it, as POST /control answers
        await linkSetControl(this.link, controller === "user");
        return keepalive ? null : this.status();
    }
    async focus(display) {
        const j = await this.json(display === undefined ? "/focus" : `/focus?display=${display}`);
        return { editable: j.editable === true };
    }
    async frame(display, maxWidth, quality) {
        const q = new URLSearchParams({ maxWidth: String(Math.round(maxWidth)), quality: String(quality) });
        if (display !== undefined)
            q.set("display", String(display));
        return (await this.call(`/frame?${q}`)).blob();
    }
    /** The prompts are the Mac's to show: a paired device can't ask for them (a 403 saying where to grant them). */
    async requestPermissions() {
        throw new RequestError(403, this.connection.messages.permissions ?? "Grant the permissions from Yoyo Control’s menu on the Mac.");
    }
    /** `GET /clipboard` (503: the Mac can't do clipboard now, its reason kept). */
    async clipboard() {
        try {
            return clipboardFromMac(await this.json("/clipboard"));
        }
        catch (e) {
            if (e instanceof RequestError && e.status === 503 && !(e instanceof DirectError))
                return { available: false, reason: e.message };
            throw e;
        }
    }
    async clipboardImage(_changeCount) {
        return (await this.call("/clipboard/image")).blob();
    }
    async clipboardFile(index, _changeCount, progress) {
        const res = await this.call(`/clipboard/file?index=${index}`);
        const blob = await res.blob();
        progress(1);
        const name = filenameOf(res.headers.get("content-disposition"));
        const mime = res.headers.get("content-type");
        return { blob, ...(name ? { name } : {}), ...(mime ? { mime } : {}) };
    }
    async putClipboard(put, progress) {
        if (!("text" in put))
            throw new RequestError(501, "a browser sends text only");
        const body = await this.json("/clipboard", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text: put.text }) });
        progress(1);
        return clipboardFromMac(body);
    }
    events() {
        return this.hub.subscribe();
    }
    screenLink(_route) {
        return this.link;
    }
    /** The page is gone for good: the events reader and the session end. */
    close() {
        this.hub.close();
        this.link.end("closed");
        this.connection.close();
    }
}
