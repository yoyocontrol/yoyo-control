import { Words } from "./strings.js";
import { mainDisplay } from "@yoyocontrol/screen-web";
export function previewState(s) {
    if (!s.available && s.unavailableAction)
        return { t: "action", action: s.unavailableAction };
    if (!s.available)
        return { t: "unavailable", reason: s.reason ?? null };
    if (!s.screenRecording && s.platform !== "linux" && (s.platform ?? "mac") === "mac")
        return { t: "needsPermission" };
    if (mainDisplay(s)?.asleep)
        return { t: "asleep" };
    return { t: "live", controller: s.controller };
}
const sameState = (a, b) => JSON.stringify(a) === JSON.stringify(b);
export class ScreenPreview {
    backend;
    static EVERY_MS = 5000;
    static MAX_WIDTH = 320;
    static QUALITY = 50;
    state = { t: "unknown" };
    /** An object URL of the latest frame (kept while it can't be refreshed; revoked when replaced). */
    image = null;
    /** The computer's platform ("mac" until a status says). */
    platform;
    timer = null;
    running = false;
    onChange = null;
    words;
    visibility = () => (document.visibilityState === "hidden" ? this.pause() : this.resume());
    constructor(backend, host = {}) {
        this.backend = backend;
        this.platform = backend.platformHint ?? "mac";
        this.words = new Words(host);
    }
    /** The row shows (the computer has a screen, or hasn't answered yet). */
    get showsRow() {
        return this.state.t !== "absent";
    }
    /** The row's second line while nobody drives it: "Watch the Mac, or take control". */
    line() {
        this.words.mac = this.platform === "mac";
        return this.words.c("watch");
    }
    /** The row is on screen: keep it current (`onChange` after every change). */
    start(onChange) {
        this.onChange = onChange;
        if (!this.running)
            document.addEventListener("visibilitychange", this.visibility);
        this.running = true;
        this.resume();
    }
    stop() {
        this.running = false;
        document.removeEventListener("visibilitychange", this.visibility);
        this.pause();
    }
    resume() {
        if (!this.running || this.timer || document.visibilityState === "hidden")
            return;
        const loop = async () => {
            await this.tick();
            if (this.running && this.timer !== null)
                this.timer = setTimeout(() => void loop(), ScreenPreview.EVERY_MS);
        };
        this.timer = setTimeout(() => void loop(), 0);
    }
    pause() {
        if (this.timer)
            clearTimeout(this.timer);
        this.timer = null;
    }
    async tick() {
        let s;
        try {
            s = await this.backend.status();
        }
        catch (e) {
            if (e.status === 404)
                this.set({ t: "absent" });
            return;
        }
        if (s.platform)
            this.platform = s.platform;
        this.set(previewState(s));
        if (this.state.t !== "live" || !this.backend.frame)
            return;
        try {
            const blob = await this.backend.frame(mainDisplay(s)?.id, ScreenPreview.MAX_WIDTH, ScreenPreview.QUALITY);
            if (this.image)
                URL.revokeObjectURL(this.image);
            this.image = URL.createObjectURL(blob);
            this.onChange?.();
        }
        catch {
            /* a frame that fails keeps the last one */
        }
    }
    set(s) {
        if (sameState(s, this.state))
            return;
        this.state = s;
        this.onChange?.();
    }
}
