import { ClipboardActions, ClipboardState, DEFAULT_FILE_LIMIT } from "./clipboard-model.js";
import { ICONS } from "./icons.js";
import { Words } from "./strings.js";
import { COMMON, THEME } from "./styles.js";
/**
 * `<yoyo-clipboard>`: a computer's clipboard (iOS ClipboardViewController, docs/PROTOCOL.md「剪贴板」). An "On your Mac"
 * card with what it has copied, live (text up to 12 lines — tap for all of it —, an image's thumbnail, a files item's
 * rows), Copy / Share / Download under it; and "Send to Mac": Paste on Mac (what this browser has copied), Photos… and
 * Files… (when the backend sends files), files dropped on the page or pasted into it. Text lands on the computer's
 * clipboard, files in its Downloads and on its clipboard. Works as a page of its own or inside the Screen page's sheet.
 * `computer`: "mac" (default) or another platform (the words say "computer"). Event: `yoyo-toast` (`detail`: the
 * text) when the host has no `toast`; a listener that calls `preventDefault()` shows it itself.
 */
const STYLE = `
:host { display: block; font-family: var(--yoyo-font); color: var(--yoyo-text); -webkit-user-select: none; user-select: none; }
.wrap { display: flex; flex-direction: column; gap: 6px; padding-bottom: 8px; }
.wrap.drop { outline: 2px dashed var(--yoyo-accent); outline-offset: 4px; border-radius: 12px; }
h4 { font-size: 13px; font-weight: 400; text-transform: uppercase; letter-spacing: .02em; color: var(--yoyo-text-secondary); margin: 14px 16px 2px; }
.group { background: var(--yoyo-sheet); border-radius: 12px; overflow: hidden; }
.row { display: flex; align-items: center; gap: 12px; padding: 11px 16px; min-height: 44px; font-size: 16px; }
.row + .row { border-top: 0.5px solid var(--yoyo-separator); }
.row svg { width: 22px; height: 22px; flex: none; color: var(--yoyo-text-secondary); }
.row .main { flex: 1; min-width: 0; }
.row .sub { display: block; font-size: 12.5px; color: var(--yoyo-text-tertiary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row .name { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
button.row { width: 100%; background: none; border: 0; text-align: left; cursor: pointer; }
button.row:disabled { color: var(--yoyo-text-tertiary); cursor: default; }
button.row:not(:disabled):active { background: rgba(127,127,127,.14); }
.card { padding: 14px 16px; }
.card .kind { font-size: 13px; color: var(--yoyo-text-secondary); margin-bottom: 6px; }
.card .body { font-size: 16px; line-height: 1.38; white-space: pre-wrap; word-break: break-word; -webkit-user-select: text; user-select: text; }
.card .body.clamped { display: -webkit-box; -webkit-line-clamp: 12; -webkit-box-orient: vertical; overflow: hidden; }
.card .body.code { font-family: var(--yoyo-mono); font-size: 13.5px; }
.card .more { margin-top: 6px; }
.card img { display: block; max-width: 100%; max-height: 320px; border-radius: 8px; margin: 4px auto 0; background: var(--yoyo-picture-background); }
.card .foot { font-size: 12.5px; color: var(--yoyo-text-tertiary); margin-top: 10px; }
.card .dimmed { color: var(--yoyo-text-secondary); }
.actions { display: flex; gap: 8px; padding: 0 16px 14px; flex-wrap: wrap; }
.actions button { flex: 1; min-width: 90px; display: inline-flex; align-items: center; justify-content: center; gap: 6px; border: 0; border-radius: 10px;
  padding: 10px; background: rgba(127,127,127,.14); color: var(--yoyo-text); font-size: 15px; font-weight: 500; cursor: pointer; }
.actions button:disabled { color: var(--yoyo-text-tertiary); cursor: default; }
.actions svg { width: 18px; height: 18px; }
.footer { font-size: 13px; color: var(--yoyo-text-secondary); margin: 2px 16px 0; line-height: 1.35; }
.busy { font-size: 13px; color: var(--yoyo-text-secondary); text-align: center; padding: 6px; }
.busy progress { display: block; width: 100%; height: 3px; margin-top: 4px; accent-color: var(--yoyo-accent); }
.empty { text-align: center; padding: 40px 16px; color: var(--yoyo-text-secondary); }
.empty b { display: block; color: var(--yoyo-text); font-size: 18px; margin-bottom: 6px; }
.toast { position: fixed; bottom: calc(24px + env(safe-area-inset-bottom)); }
`;
/** The tag names the elements are registered under (`defineElements`). */
export const tagNames = { screen: "yoyo-screen", clipboard: "yoyo-clipboard" };
export class YoyoClipboardElement extends HTMLElement {
    _backend = null;
    _host = {};
    _computer = "mac";
    words = new Words();
    root;
    wrap;
    toastEl;
    picker;
    state = null;
    unobserve = null;
    expanded = false;
    thumbnail = null;
    thumbLoading = null;
    textAsked = null;
    busy = null;
    toastTimer = null;
    lastChange = null;
    constructor() {
        super();
        this.root = this.attachShadow({ mode: "open" });
        const style = document.createElement("style");
        style.textContent = THEME + COMMON + STYLE;
        this.wrap = document.createElement("div");
        this.wrap.className = "wrap";
        this.toastEl = document.createElement("div");
        this.toastEl.className = "toast glass";
        this.picker = document.createElement("input");
        this.picker.type = "file";
        this.picker.multiple = true;
        this.picker.hidden = true;
        this.picker.addEventListener("change", () => {
            const files = [...(this.picker.files ?? [])];
            if (files.length)
                this.sendFiles(files);
        });
        this.root.append(style, this.wrap, this.toastEl, this.picker);
        // files dropped on the page, or pasted into it
        this.addEventListener("dragover", (e) => {
            if (!this.canSend || !e.dataTransfer?.types.includes("Files"))
                return;
            e.preventDefault();
            this.wrap.classList.add("drop");
        });
        this.addEventListener("dragleave", () => this.wrap.classList.remove("drop"));
        this.addEventListener("drop", (e) => {
            this.wrap.classList.remove("drop");
            const files = [...(e.dataTransfer?.files ?? [])];
            if (!files.length || !this.canSend)
                return;
            e.preventDefault();
            this.sendFiles(files);
        });
        this.addEventListener("paste", (e) => {
            if (!this.canSend)
                return;
            const files = [...(e.clipboardData?.files ?? [])];
            const text = e.clipboardData?.getData("text/plain");
            if (files.length)
                this.sendFiles(files);
            else if (text)
                void this.send({ text });
            else
                return;
            e.preventDefault();
        });
    }
    get backend() {
        return this._backend;
    }
    set backend(b) {
        if (b === this._backend)
            return;
        this.unobserve?.();
        this.unobserve = null;
        this._backend = b;
        this.state = b ? ClipboardState.of(b) : null;
        if (this.isConnected)
            this.observe();
    }
    get host() {
        return this._host;
    }
    set host(h) {
        this._host = h ?? {};
        this.words = new Words(this._host);
        this.words.mac = this._computer === "mac";
        for (const [k, v] of Object.entries(this._host.theme ?? {}))
            this.style.setProperty(`--yoyo-${k}`, v);
        if (this._host.colorScheme)
            this.setAttribute("color-scheme", this._host.colorScheme);
        this.render();
    }
    /** Whose clipboard: "mac", or another platform ("linux"…: the words say "computer"). */
    get computer() {
        return this._computer;
    }
    set computer(c) {
        this._computer = c || "mac";
        this.words.mac = this._computer === "mac";
        this.render();
    }
    connectedCallback() {
        this.observe();
    }
    disconnectedCallback() {
        this.unobserve?.();
        this.unobserve = null;
        if (this.thumbnail)
            URL.revokeObjectURL(this.thumbnail.url);
        this.thumbnail = null;
    }
    observe() {
        if (!this.state || this.unobserve)
            return;
        this.unobserve = this.state.observe(() => this.changed());
        this.state.refresh();
        this.render();
    }
    get status() {
        return this.state?.status ?? null;
    }
    get canSend() {
        return ClipboardActions.enabled(this.status).send && this.busy === null && !!this._backend?.putClipboard;
    }
    changed() {
        const s = this.status;
        const item = s?.item;
        if (item && item.changeCount !== this.lastChange) {
            this.lastChange = item.changeCount;
            this.expanded = false;
        }
        // the event carries no text: asked once per item
        if (item?.kind === "text" && item.text === undefined && this.textAsked !== item.changeCount) {
            this.textAsked = item.changeCount;
            void this.state?.load(true).catch(() => { });
        }
        if (item?.kind === "image")
            void this.loadThumbnail(item);
        this.render();
    }
    async loadThumbnail(item) {
        const get = this._backend?.clipboardImage;
        if (!get || this.thumbnail?.for === item.changeCount || this.thumbLoading === item.changeCount)
            return;
        this.thumbLoading = item.changeCount;
        try {
            const blob = await get.call(this._backend, item.changeCount);
            if (this.thumbnail)
                URL.revokeObjectURL(this.thumbnail.url);
            this.thumbnail = { url: URL.createObjectURL(blob), for: item.changeCount };
            this.render();
        }
        catch {
            /* the card says "Image" without one */
        }
        finally {
            this.thumbLoading = null;
        }
    }
    render() {
        const w = this.words;
        const wrap = this.wrap;
        wrap.innerHTML = "";
        const state = this.state;
        if (!state)
            return;
        if (state.isUnsupported) {
            wrap.innerHTML = `<div class="empty"><b></b><span></span></div>`;
            wrap.querySelector("b").textContent = w.t("clipboardNotAvailable");
            wrap.querySelector("span").textContent = w.t("clipboardCantShare");
            return;
        }
        const s = this.status;
        if (!s && state.error) {
            const box = document.createElement("div");
            box.className = "empty";
            box.innerHTML = `<b></b><span></span>`;
            box.querySelector("b").textContent = w.t("couldNotReadClipboard");
            box.querySelector("span").textContent = state.error instanceof Error ? state.error.message : "";
            const retry = document.createElement("button");
            retry.className = "round glass";
            retry.style.marginTop = "12px";
            retry.textContent = w.t("retry");
            retry.addEventListener("click", () => void state.load(true).catch(() => { }));
            box.append(retry);
            wrap.append(box);
            return;
        }
        // On your Mac
        const h1 = document.createElement("h4");
        h1.textContent = w.c("onYour");
        const g1 = document.createElement("div");
        g1.className = "group";
        g1.append(this.card(s));
        for (const [i, f] of (s?.item?.kind === "files" ? (s.item.files ?? []) : []).entries()) {
            const row = document.createElement("div");
            row.className = "row";
            row.innerHTML = `${f.dir ? ICONS.folder : ICONS.file}<span class="main"><span class="name"></span><span class="sub"></span></span>`;
            row.querySelector(".name").textContent = f.name;
            row.querySelector(".sub").textContent = f.dir ? w.c("folderOn") : typeof f.size === "number" ? w.bytes(f.size) : "";
            row.dataset.index = String(i);
            g1.append(row);
        }
        g1.append(this.actions(s));
        wrap.append(h1, g1);
        if (this.busy) {
            const b = document.createElement("div");
            b.className = "busy";
            b.textContent = this.busy.text;
            if (this.busy.fraction !== null) {
                const p = document.createElement("progress");
                p.value = this.busy.fraction;
                b.append(p);
            }
            wrap.append(b);
        }
        // Send to Mac
        const h2 = document.createElement("h4");
        h2.textContent = w.c("sendTo");
        const g2 = document.createElement("div");
        g2.className = "group";
        const can = this.canSend;
        const row = (icon, title, sub, run) => {
            const b = document.createElement("button");
            b.className = "row";
            b.type = "button";
            b.disabled = !can;
            b.innerHTML = `${icon}<span class="main"><span class="name"></span><span class="sub"></span></span>`;
            b.querySelector(".name").textContent = title;
            if (sub)
                b.querySelector(".sub").textContent = sub;
            else
                b.querySelector(".sub").remove();
            b.addEventListener("click", run);
            g2.append(b);
        };
        row(ICONS.paste, w.c("pasteOn"), w.t("pasteRowDetail"), () => void this.pasteFromBrowser());
        if (this._backend?.sendsClipboardFiles) {
            row(ICONS.photo, w.t("photos"), null, () => this.pick("image/*,video/*"));
            row(ICONS.folder, w.t("files"), w.t("dropFilesHere"), () => this.pick(""));
        }
        const foot = document.createElement("p");
        foot.className = "footer";
        foot.textContent = s && !s.available ? (s.reason ?? w.t("clipboardUnavailable")) : w.c(this._backend?.sendsClipboardFiles ? "sendFooter" : "sendTextFooter");
        wrap.append(h2, g2, foot);
    }
    card(s) {
        const w = this.words;
        const c = document.createElement("div");
        c.className = "card";
        const kind = document.createElement("div");
        kind.className = "kind";
        const body = document.createElement("div");
        body.className = "body";
        c.append(kind, body);
        if (!s) {
            body.innerHTML = `<div class="spin"></div>`;
            kind.remove();
            return c;
        }
        if (!s.available) {
            kind.textContent = w.t("clipboardUnavailable");
            body.className = "body dimmed";
            body.textContent = s.reason ?? "";
            return c;
        }
        const item = s.item;
        if (!item || item.kind === "empty") {
            kind.textContent = w.t("empty");
            body.className = "body dimmed";
            body.textContent = w.c("copySomething");
            return c;
        }
        switch (item.kind) {
            case "text": {
                kind.textContent = typeof item.size === "number" ? w.t("textSized", { size: w.bytes(item.size) }) : w.t("text");
                const text = item.text ?? item.preview ?? "";
                body.textContent = text;
                body.classList.toggle("code", ClipboardActions.looksLikeCode(text));
                const lines = text.split("\n").length;
                if (!this.expanded)
                    body.classList.add("clamped");
                if (lines > 12 || text.length > 900) {
                    const more = document.createElement("button");
                    more.className = "plain-button more";
                    more.textContent = w.t(this.expanded ? "showsFirstLines" : "showsWholeText");
                    more.addEventListener("click", () => {
                        this.expanded = !this.expanded;
                        this.render();
                    });
                    c.append(more);
                }
                break;
            }
            case "image": {
                kind.textContent = ClipboardActions.previewLine(item, w);
                body.remove();
                if (this.thumbnail?.for === item.changeCount) {
                    const img = document.createElement("img");
                    img.src = this.thumbnail.url;
                    img.alt = w.t("image");
                    c.append(img);
                }
                break;
            }
            case "files": {
                const n = (item.files?.length ?? 0) + (item.moreFiles ?? 0);
                kind.textContent = w.t("nFiles", { n }) + (typeof item.size === "number" ? ` · ${w.bytes(item.size)}` : "");
                if (item.moreFiles)
                    body.textContent = w.t("andMore", { n: item.moreFiles });
                else
                    body.remove();
                break;
            }
            case "concealed":
                kind.textContent = w.t("hiddenPasswordManager");
                body.className = "body dimmed";
                body.textContent = w.t("hiddenExplained");
                break;
            default:
                kind.textContent = w.t("cantBeShown");
                body.remove();
        }
        const foot = document.createElement("div");
        foot.className = "foot";
        foot.textContent = ClipboardActions.footer(item, w);
        c.append(foot);
        return c;
    }
    actions(s) {
        const w = this.words;
        const e = ClipboardActions.enabled(s);
        const busy = this.busy !== null;
        const bar = document.createElement("div");
        bar.className = "actions";
        const add = (icon, label, on, run) => {
            const b = document.createElement("button");
            b.type = "button";
            b.disabled = !on || busy;
            b.innerHTML = `${icon}<span></span>`;
            b.querySelector("span").textContent = label;
            b.addEventListener("click", run);
            bar.append(b);
        };
        add(ICONS.copy, w.t("copy"), e.copy, () => void this.copy());
        if (typeof navigator.share === "function")
            add(ICONS.share, w.t("share"), e.share, () => void this.share());
        add(ICONS.download, w.t("download"), e.save, () => void this.save());
        return bar;
    }
    // ---------------------------------------------------------------- the computer's item onto this device
    async copy() {
        const item = this.status?.item;
        const w = this.words;
        if (!item)
            return;
        try {
            if (item.kind === "text" && typeof item.text === "string")
                await navigator.clipboard.writeText(item.text);
            else if (item.kind === "image" && this._backend?.clipboardImage) {
                const b = this._backend;
                const blob = b.clipboardImage(item.changeCount).then((x) => (x.type === "image/png" ? x : new Blob([x], { type: "image/png" })));
                await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
            }
            else
                return;
            this.toast(w.t("copied"));
        }
        catch (e) {
            this.toast(e instanceof DOMException ? w.t("clipboardWriteRefused") : e instanceof Error ? e.message : String(e));
        }
    }
    /** The item as files (an image, or a files item's regular files, downloaded one by one). */
    async asFiles(item) {
        const b = this._backend;
        const w = this.words;
        if (item.kind === "text")
            return [new File([item.text ?? ""], "clipboard.txt", { type: "text/plain" })];
        if (item.kind === "image" && b.clipboardImage)
            return [new File([await b.clipboardImage(item.changeCount)], "clipboard.png", { type: "image/png" })];
        const regular = (item.files ?? []).map((f, i) => ({ f, i })).filter(({ f }) => !f.dir);
        if (!b.clipboardFile)
            return [];
        const out = [];
        for (const [n, { f, i }] of regular.entries()) {
            this.setBusy({ text: w.t("downloadingOf", { i: n + 1, n: regular.length }), fraction: n / regular.length });
            const d = await b.clipboardFile(i, item.changeCount, (x) => this.setBusy({ text: w.t("downloadingOf", { i: n + 1, n: regular.length }), fraction: (n + x) / regular.length }));
            out.push(new File([d.blob], d.name ?? f.name, { type: d.mime ?? d.blob.type }));
        }
        if (regular.length < (item.files ?? []).length)
            this.toast(w.t("foldersLeftOut"));
        return out;
    }
    async share() {
        const item = this.status?.item;
        if (!item || this.busy)
            return;
        try {
            if (item.kind === "text")
                await navigator.share({ text: item.text ?? item.preview ?? "" });
            else {
                const files = await this.asFiles(item);
                this.setBusy(null);
                if (files.length)
                    await navigator.share({ files });
            }
        }
        catch (e) {
            if (!(e instanceof DOMException && e.name === "AbortError"))
                this.toast(e instanceof Error ? e.message : String(e));
        }
        finally {
            this.setBusy(null);
        }
    }
    async save() {
        const item = this.status?.item;
        if (!item || this.busy)
            return;
        try {
            for (const f of await this.asFiles(item)) {
                const a = document.createElement("a");
                a.href = URL.createObjectURL(f);
                a.download = f.name;
                a.click();
                setTimeout(() => URL.revokeObjectURL(a.href), 30_000);
            }
        }
        catch (e) {
            this.toast(e instanceof Error ? e.message : String(e));
        }
        finally {
            this.setBusy(null);
        }
    }
    // ---------------------------------------------------------------- this device's onto the computer
    async pasteFromBrowser() {
        const w = this.words;
        let text;
        try {
            text = await navigator.clipboard.readText();
        }
        catch {
            this.toast(w.t("clipboardReadRefused"));
            return;
        }
        const p = ClipboardActions.payload({ text }, this.limit, w);
        if ("error" in p)
            return this.toast(p.error);
        await this.send(p.put);
    }
    get limit() {
        return this._backend?.clipboardFileLimit ?? DEFAULT_FILE_LIMIT;
    }
    pick(accept) {
        this.picker.accept = accept;
        this.picker.value = "";
        this.picker.click();
    }
    sendFiles(files) {
        if (!this._backend?.sendsClipboardFiles)
            return;
        const p = ClipboardActions.payload({ files }, this.limit, this.words);
        if ("error" in p)
            return this.toast(p.error);
        void this.send(p.put);
    }
    async send(put) {
        const b = this._backend;
        const w = this.words;
        if (!b?.putClipboard || this.busy)
            return;
        const n = "files" in put ? put.files.length : 0;
        this.setBusy({ text: n ? w.t("uploadingFiles", { n }) : w.t("copying"), fraction: n ? 0 : null });
        try {
            const r = await b.putClipboard(put, (f) => n && this.setBusy({ text: w.t("uploadingFiles", { n }), fraction: f }));
            this.state?.set(r);
            this.toast(ClipboardActions.sentMessage(put, r.saved, w));
        }
        catch (e) {
            if (!this._host.handleError?.(e))
                this.toast(e instanceof Error ? e.message : String(e));
        }
        finally {
            this.setBusy(null);
        }
    }
    setBusy(b) {
        this.busy = b;
        this.render();
    }
    toast(text) {
        if (this._host.toast)
            return this._host.toast(text);
        const ev = new CustomEvent("yoyo-toast", { detail: text, bubbles: true, composed: true, cancelable: true });
        if (!this.dispatchEvent(ev))
            return;
        this.toastEl.textContent = text;
        this.toastEl.classList.add("shown");
        if (this.toastTimer)
            clearTimeout(this.toastTimer);
        this.toastTimer = setTimeout(() => this.toastEl.classList.remove("shown"), 2600);
    }
}
