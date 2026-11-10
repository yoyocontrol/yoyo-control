// One connection to a Yoyo Control server (docs/LOCAL-API.md): finding it, talking to it, following its `/events`.
//
// Where the server comes from — every look goes, in this order, through what the options allow:
// - `remote`: a server elsewhere over TCP + bearer token (a Linux desktop, another machine): `connect` gives its
//   endpoint (and starts it when needed); its `/status` must name `remote.app` with an API in range.
// - `app`: the Yoyo Control app's fixed socket answers as "YoyoControl" with an API in range → used as it is (never
//   spawned or killed here; let go of when it stops answering). Else an installed Yoyo Control.app is opened in the
//   background (`open -g -j`) and its socket waited for. Too old an API → "outdated" (LocalError with `install`). An
//   installed app that was opened and never answered (an old build) is not opened again until its bundle changes.
// - a child service (`childPath` / `childCandidates`, for development): spawned on first use with
//   `--socket <socketPath> --exit-on-stdin-eof` and spoken to over that socket; respawned on the next use after it
//   died, with backoff (none after exit code 75, RESTART_EXIT: it asks for a fresh process).
// - nothing: "not-installed" (LocalError with `install` and the caller's download URL).
//
// Connection state (「连接状态」): while a server is in use one `GET /events` subscription stays open (reconnected
// 1 s → 10 s while it lives; an error answer is logged once per server). Every snapshot that differs from the last
// one (ignoring `since`) goes to `onState`. A server that exits unexpectedly turns every last-known entry into
// reconnecting/helper-restart; one that cannot be started, unavailable/helper-down (with the backoff's retryAt).
import { EventEmitter } from "node:events";
import { spawn as nodeSpawn } from "node:child_process";
import { existsSync } from "node:fs";
import { API, APP_ID, APP_LAUNCH_TIMEOUT_MS, APP_NAME, appStamp, findApp, openApp, PROBE_TIMEOUT_MS, REFRESH_GRANT_MS, remoteFailure, resolveChildPath, RESTART_EXIT } from "./app.js";
import { answerError, LocalError } from "./errors.js";
import { acceptHeader, query, rawRequest, readAll, safeJson } from "./http.js";
import { parseAppAx, parseAppWindows, parseFocus, parseHit, parseStreamAck, parseWindows, regionHeader } from "./params.js";
export const defaultMessages = {
    unsupportedPlatform: "Yoyo Control's local API needs macOS",
    childMissing: (looked) => `the screen helper is not there (looked for ${looked || "nothing"})`,
    notInstalled: (url) => `Yoyo Control is not installed on this Mac. Download it from ${url}, open it, and allow Screen Recording and Accessibility`,
    outdated: (version, api, url, r) => `Yoyo Control${version ? ` ${version}` : ""} on this Mac is too old for this program (its API is ${api}, it needs ${r.min}…${r.max}). Update it from ${url}`,
    tooNew: (version, api, r) => `Yoyo Control${version ? ` ${version}` : ""} on this Mac speaks API ${api}, newer than this program knows (${r.min}…${r.max}): update the program`,
    silentApp: (path, url) => `Yoyo Control at ${path} was opened but did not answer: it is probably an old build. Update it from ${url}`,
    stopped: "the client is stopped",
};
/** The app in use (it runs on its own): stands in for a child process; kill() only lets go of it. */
class AttachedApp extends EventEmitter {
    kill() {
        this.emit("exit", null, null);
        return true;
    }
}
/** `identity` from a `/status`. */
function identityOf(mode, st) {
    return {
        mode,
        ...(typeof st.version === "string" && st.version ? { version: st.version } : {}),
        ...(typeof st.build === "string" && st.build ? { build: st.build } : {}),
        ...(typeof st.api === "number" && Number.isInteger(st.api) ? { api: st.api } : {}),
    };
}
/** States + console without `since` (what counts as a change). */
const stateKey = (states, console) => JSON.stringify([states.map(({ since: _since, ...rest }) => Object.fromEntries(Object.entries(rest).sort(([a], [b]) => (a < b ? -1 : 1)))), console]);
const consoleLogger = (prefix) => ({
    log: (m) => console.log(`${prefix} ${m}`),
    warn: (m) => console.warn(`${prefix} ${m}`),
    error: (m) => console.error(`${prefix} ${m}`),
});
export class LocalClient {
    opts;
    child = null;
    /** When the server in use answered first (ms). */
    startedAt = 0;
    /** Servers this client let go of itself (their exit is not a failure). */
    retired = new WeakSet();
    starting = null;
    failures = 0;
    retryAt = 0;
    lastFailure = null;
    stopped = false;
    now;
    platform;
    spawnChild;
    readyTimeoutMs;
    range;
    messages;
    log;
    events = null;
    eventsTimer = null;
    eventsDelay = 0;
    eventsErrorLogged = null;
    lastStates = [];
    lastConsole = null;
    stateSig = null;
    serverIdentity = null;
    remoteEndpoint = null;
    remoteNext = "known";
    strangerLogged = false;
    silentApp = null;
    automation = false;
    automationChain = Promise.resolve();
    constructor(opts) {
        this.opts = opts;
        this.now = opts.now ?? Date.now;
        this.platform = opts.platform ?? process.platform;
        this.log = opts.log ?? consoleLogger("[yoyo]");
        this.spawnChild = opts.spawn ?? ((path, args) => defaultSpawn(path, args, this.log));
        this.readyTimeoutMs = opts.readyTimeoutMs ?? 5000;
        this.range = opts.api ?? API;
        this.messages = { ...defaultMessages, ...opts.messages };
    }
    /** The child service's executable to run now, or null. */
    childPath() {
        if (this.opts.childPath !== undefined)
            return this.opts.childPath && existsSync(this.opts.childPath) ? this.opts.childPath : null;
        return resolveChildPath(null, this.opts.childCandidates ?? []);
    }
    /** Why there can't be a server at all (known without asking one), or null. With `app` a missing app is only known by looking. */
    unavailableReason() {
        if (this.opts.remote)
            return null;
        if (this.platform !== "darwin")
            return this.messages.unsupportedPlatform;
        if (!this.opts.app && !this.childPath()) {
            const looked = this.opts.childPath !== undefined ? (this.opts.childPath ?? "nothing") : (this.opts.childCandidates ?? []).join(", ");
            return this.messages.childMissing(looked);
        }
        return null;
    }
    /** Without starting anything: a server may be had (one is in use, the app's socket or an installed app or a child is there). */
    maybeThere() {
        if (this.unavailableReason() !== null)
            return false;
        if (!this.opts.app || this.child !== null)
            return true;
        const app = this.opts.app;
        return !!app.endpoint || existsSync(app.socketPath) || !!(app.find ?? findApp)() || !!this.childPath();
    }
    /** A server is in use (it answered and hasn't gone since). */
    get connected() {
        return this.child !== null;
    }
    /** The server in use is the app or a remote one (not a child this client started). */
    get attached() {
        return this.child instanceof AttachedApp;
    }
    /** The server in use, as its `/status` said when it was found (null: none yet). */
    get identity() {
        return this.serverIdentity ? { ...this.serverIdentity } : null;
    }
    /** The connection state last forwarded to onState. */
    get states() {
        return this.lastStates;
    }
    get console() {
        return this.lastConsole;
    }
    /** The automation indicator was turned on here (setAutomation) and not off since (nor by the user's Esc). */
    get automationActive() {
        return this.automation;
    }
    // ------------------------------------------------------------------------- finding the server
    /** A server is in use; found (or started, after the backoff) when needed. */
    async ensure() {
        const reason = this.unavailableReason();
        if (reason)
            throw new LocalError(reason, 503);
        if (this.stopped)
            throw new LocalError(this.messages.stopped, 503);
        if (this.child && !this.starting)
            return;
        if (this.starting)
            return this.starting;
        if (this.now() < this.retryAt) {
            throw new LocalError(`the screen helper failed (${this.lastFailure ?? "exited"}); retrying in ${Math.ceil((this.retryAt - this.now()) / 1000)} s`, 503);
        }
        this.starting = this.connect().finally(() => {
            this.starting = null;
        });
        return this.starting;
    }
    async connect() {
        if (this.opts.remote)
            return this.connectRemote();
        const app = this.opts.app;
        let silent = null;
        if (app) {
            if (await this.tryAttach())
                return;
            const installed = (app.find ?? findApp)();
            if (installed) {
                if (!this.isSilent(installed) && (await this.launchAndAttach(installed)))
                    return;
                silent = installed;
            }
        }
        const child = this.childPath();
        if (child)
            return this.start(child);
        const url = app.downloadUrl;
        if (silent) {
            // installed but it never answers: an old build, which only an update fixes
            const install = { reason: "outdated", url };
            throw new LocalError(this.messages.silentApp(silent, url), 503, { install });
        }
        const install = { reason: "not-installed", url };
        throw new LocalError(this.messages.notInstalled(url), 503, { install });
    }
    appStamp(path) {
        return (this.opts.app.stamp ?? appStamp)(path);
    }
    isSilent(path) {
        const s = this.silentApp;
        return !!s && s.path === path && s.stamp === this.appStamp(path);
    }
    /**
     * A remote server: its endpoint (started when needed), then its `/status` must name the expected app with an API in
     * range. A known endpoint that refuses or is unreachable is started again once (`remoteFailure`); one that is only
     * slow is not touched. Failures are LocalErrors with the retry backoff.
     */
    async connectRemote() {
        const remote = this.opts.remote;
        const tryOnce = async (mode) => {
            this.remoteEndpoint = await remote.connect(mode);
            return this.appStatus();
        };
        const first = this.remoteNext;
        let st;
        try {
            try {
                st = await tryOnce(first);
            }
            catch (err) {
                const kind = remoteFailure(err);
                // busy (no answer in time: its CPUs may be full of encoders) is not gone: starting it again would cut every
                // open stream; only a refused / unreachable endpoint or a refused token is started again, once
                if (err instanceof LocalError || kind === "busy" || first !== "known")
                    throw err;
                st = await tryOnce(kind);
            }
        }
        catch (err) {
            const kind = err instanceof LocalError ? null : remoteFailure(err);
            if (kind !== "busy") {
                this.remoteEndpoint = null;
                if (kind)
                    this.remoteNext = kind;
            }
            this.failed(err instanceof Error ? err.message : String(err));
            if (kind !== "busy")
                this.synthesize("unavailable", "helper-down");
            if (err instanceof LocalError)
                throw err;
            throw new LocalError(kind === "busy" ? `the desktop is busy (no answer within ${PROBE_TIMEOUT_MS / 1000} s); try again` : `the desktop does not answer: ${this.lastFailure}`, 503);
        }
        const api = typeof st.api === "number" ? st.api : 0;
        if (st.app !== remote.app || api < this.range.min || api > this.range.max) {
            // something else answers there (a reused address?): the next look starts ours anew, with a new token
            this.remoteEndpoint = null;
            this.remoteNext = "rekey";
            throw new LocalError(`the desktop answers as ${String(st.app)} api ${api}, not ${remote.app} api ${this.range.min}…${this.range.max}`, 503);
        }
        this.remoteNext = "known";
        this.attach(st);
    }
    /** The app's `/status`, or a rejection when nothing answers there within PROBE_TIMEOUT_MS. */
    async appStatus() {
        const res = await this.raw("GET", "/status", undefined, AbortSignal.timeout(PROBE_TIMEOUT_MS), this.appTarget());
        const json = safeJson(await readAll(res.body));
        if (res.status !== 200 || !json || typeof json !== "object")
            throw Object.assign(new Error(`HTTP ${res.status}`), { httpStatus: res.status });
        return json;
    }
    /** The app's socket answers as Yoyo Control with an API in range: use it (true). A LocalError when it is too old / too new. */
    async tryAttach() {
        let st;
        try {
            st = await this.appStatus();
        }
        catch {
            return false;
        }
        if (st.app !== APP_ID) {
            if (!this.strangerLogged)
                this.log.warn(`something other than ${APP_NAME} answers on ${this.opts.app.socketPath}; ignoring it`);
            this.strangerLogged = true;
            return false;
        }
        const version = typeof st.version === "string" && st.version ? st.version : undefined;
        const api = typeof st.api === "number" ? st.api : 0;
        if (api < this.range.min) {
            const url = this.opts.app.downloadUrl;
            const install = { reason: "outdated", url, ...(version ? { version } : {}) };
            throw new LocalError(this.messages.outdated(version, api, url, this.range), 503, { install });
        }
        if (api > this.range.max)
            throw new LocalError(this.messages.tooNew(version, api, this.range), 503);
        this.attach(st);
        return true;
    }
    attach(st) {
        const app = new AttachedApp();
        this.child = app;
        this.failures = 0;
        this.startedAt = this.now();
        this.serverIdentity = identityOf("app", st);
        app.on("exit", () => {
            if (this.child === app)
                this.child = null;
            this.unwatchEvents(app);
            // gone on its own (quit, its service restarting): looked for again on the next use
            if (!this.stopped && !this.retired.has(app)) {
                this.log.log(`${this.opts.remote ? this.opts.remote.app : APP_NAME} stopped answering; looking for it again on the next use`);
                this.synthesize("reconnecting", "helper-restart");
            }
        });
        const where = this.remoteEndpoint ? `${this.remoteEndpoint.host}:${this.remoteEndpoint.port}` : this.opts.app.socketPath;
        this.log.log(`using ${typeof st.app === "string" ? st.app : APP_NAME} ${this.serverIdentity.version ?? "?"} (api ${this.serverIdentity.api}) on ${where}`);
        this.watchEvents();
    }
    /** Open the installed app and use it once its socket answers (true); false when it never answers in time (remembered). */
    async launchAndAttach(path) {
        const app = this.opts.app;
        const timeout = app.launchTimeoutMs ?? APP_LAUNCH_TIMEOUT_MS;
        this.log.log(`opening ${APP_NAME} (${path})`);
        try {
            await (app.launch ?? openApp)(path);
        }
        catch (err) {
            this.failed(`cannot open ${path}: ${err instanceof Error ? err.message : err}`);
            this.synthesize("unavailable", "helper-down");
            throw new LocalError(`cannot open ${APP_NAME}: ${this.lastFailure}`, 503);
        }
        const deadline = Date.now() + timeout;
        while (Date.now() < deadline) {
            if (await this.tryAttach()) {
                this.silentApp = null;
                return true;
            }
            await new Promise((r) => setTimeout(r, 200));
        }
        this.log.warn(`${path} was opened but did not answer within ${timeout} ms (an old build?); not opening it again until it changes`);
        this.silentApp = { path, stamp: this.appStamp(path) };
        return false;
    }
    async start(childPath) {
        const args = ["--socket", this.opts.socketPath, "--exit-on-stdin-eof"];
        let child;
        try {
            child = this.spawnChild(childPath, args);
        }
        catch (err) {
            this.failed(err instanceof Error ? err.message : String(err));
            this.synthesize("unavailable", "helper-down");
            throw new LocalError(`cannot start the screen helper: ${this.lastFailure}`, 503);
        }
        this.child = child;
        let exited = false;
        let ready = false;
        child.on("error", (err) => {
            this.log.error(`helper error: ${err.message}`);
        });
        child.on("exit", (code, signal) => {
            exited = true;
            if (this.child === child)
                this.child = null;
            this.unwatchEvents(child);
            if (!this.stopped && !this.retired.has(child)) {
                if (code === RESTART_EXIT && ready) {
                    // it asked for a fresh process (not a failure): the next use starts one at once
                    this.log.log("helper exited to be restarted; a fresh one starts on the next use");
                }
                else {
                    this.log.warn(`helper exited (${signal ?? `code ${code}`})`);
                    this.failed(signal ? `killed by ${signal}` : `exit code ${code}`);
                }
                if (ready)
                    this.synthesize("reconnecting", "helper-restart");
            }
        });
        const deadline = Date.now() + this.readyTimeoutMs;
        let lastErr = "no answer";
        while (Date.now() < deadline && !exited) {
            try {
                const st = await this.rawJson("GET", "/status");
                this.failures = 0;
                this.startedAt = this.now();
                this.serverIdentity = identityOf("child", st);
                ready = true;
                this.log.log(`helper ready on ${this.opts.socketPath}`);
                this.watchEvents();
                return;
            }
            catch (err) {
                lastErr = err instanceof Error ? err.message : String(err);
                await new Promise((r) => setTimeout(r, 100));
            }
        }
        if (!exited)
            this.retire(child);
        this.failed(exited ? (this.lastFailure ?? "exited") : `did not answer within ${this.readyTimeoutMs} ms (${lastErr})`);
        this.synthesize("unavailable", "helper-down");
        throw new LocalError(`the screen helper did not start: ${this.lastFailure}`, 503);
    }
    /** Lets go of the server in use on purpose (a child is stopped; the app is only let go of): the next use looks again. */
    release() {
        if (this.child)
            this.retire(this.child);
    }
    retire(child) {
        this.retired.add(child);
        if (this.child === child)
            this.child = null;
        this.unwatchEvents(child);
        child.kill("SIGTERM");
    }
    // ------------------------------------------------------------------------- connection state (/events)
    watchEvents() {
        if (this.stopped || this.eventsTimer)
            return;
        const child = this.child;
        if (!child)
            return;
        if (this.events?.child === child)
            return;
        this.events?.abort.abort();
        const sub = { child, abort: new AbortController() };
        this.events = sub;
        void this.readEvents(sub);
    }
    unwatchEvents(child) {
        if (this.events?.child !== child)
            return;
        this.events.abort.abort();
        this.events = null;
    }
    /** Read one subscription's NDJSON lines until it ends; then reconnect it (1 s → 10 s) while its server lives. */
    async readEvents(sub) {
        try {
            const res = await this.raw("GET", "/events", undefined, sub.abort.signal);
            if (res.status !== 200) {
                res.body.resume();
                if (this.eventsErrorLogged !== sub.child)
                    this.log.warn(`the screen helper's /events answered HTTP ${res.status}; retrying`);
                this.eventsErrorLogged = sub.child;
                throw new Error(`HTTP ${res.status}`);
            }
            res.body.setEncoding("utf8");
            let buf = "";
            for await (const chunk of res.body) {
                buf += chunk;
                for (let i = buf.indexOf("\n"); i >= 0; i = buf.indexOf("\n")) {
                    const line = buf.slice(0, i).trim();
                    buf = buf.slice(i + 1);
                    if (line)
                        this.eventLine(line);
                }
            }
        }
        catch {
            // the server went away, or we aborted
        }
        finally {
            if (this.events === sub)
                this.events = null;
        }
        if (sub.abort.signal.aborted || this.stopped)
            return;
        if (this.child !== sub.child)
            return;
        // the app runs on its own: when its socket no longer answers, let go of it (looked for again on the next use)
        if (sub.child instanceof AttachedApp) {
            // a remote server that is only slow is still there (its events are retried below); one that refuses or is gone
            // is let go of and started again (or rekeyed) on the next use
            const gone = await this.appStatus().then(() => null, (err) => (this.opts.remote ? remoteFailure(err) : "restart"));
            if (gone !== null && gone !== "busy") {
                if (this.opts.remote)
                    this.remoteNext = gone;
                if (this.child === sub.child)
                    sub.child.emit("exit", null, null);
                return;
            }
        }
        if (this.child !== sub.child || this.stopped)
            return;
        const base = this.opts.eventsRetryMs ?? 1000;
        this.eventsDelay = this.eventsDelay ? Math.min(base * 10, this.eventsDelay * 2) : base;
        this.eventsTimer = setTimeout(() => {
            this.eventsTimer = null;
            this.watchEvents();
        }, this.eventsDelay);
        this.eventsTimer.unref();
    }
    eventLine(line) {
        let msg;
        try {
            msg = JSON.parse(line);
        }
        catch {
            return;
        }
        if (!msg || typeof msg !== "object" || Array.isArray(msg))
            return;
        switch (msg.type) {
            case "clipboard":
                this.opts.onClipboard?.(msg);
                return;
            case "abort":
                this.automation = false;
                this.opts.onAbort?.(typeof msg.reason === "string" ? msg.reason : "esc");
                return;
            case "state": {
                if (!Array.isArray(msg.states))
                    return;
                this.eventsDelay = 0; // a working subscription: the next reconnect starts at 1 s again
                const console_ = msg.console && typeof msg.console === "object" ? msg.console : null;
                this.applyStates(msg.states, console_);
                return;
            }
            case "ping":
                return;
            default:
                if (typeof msg.type === "string")
                    this.opts.onEvent?.(msg);
        }
    }
    applyStates(states, console_) {
        this.lastStates = states;
        this.lastConsole = console_;
        const sig = stateKey(states, console_);
        if (sig === this.stateSig)
            return;
        this.stateSig = sig;
        this.opts.onState?.(states, console_);
    }
    /** The server is gone (`helper-restart`) or cannot be started (`helper-down`, with retryAt): every last-known entry says so. */
    synthesize(phase, reason) {
        this.opts.onGone?.();
        if (!this.lastStates.length)
            return;
        const since = this.now();
        const retryAt = this.retryAt > since ? this.retryAt : undefined;
        const states = this.lastStates.map(({ detail: _detail, retryAt: _retry, ...s }) => ({
            ...s,
            phase,
            reason,
            since,
            ...(retryAt ? { retryAt } : {}),
        }));
        this.applyStates(states, this.lastConsole);
    }
    failed(why) {
        this.lastFailure = why;
        this.failures++;
        this.retryAt = this.now() + Math.min(30_000, 1000 * 2 ** (this.failures - 1));
    }
    // ------------------------------------------------------------------------- requests
    appTarget() {
        if (this.opts.remote) {
            const e = this.remoteEndpoint;
            // no endpoint (it went away): a request there fails like one to a dead socket
            return e ? { host: e.host, port: e.port } : { socketPath: "/nonexistent/yoyo-remote-screen" };
        }
        const app = this.opts.app;
        return app.endpoint ?? { socketPath: app.socketPath };
    }
    target() {
        return this.attached ? this.appTarget() : (this.opts.endpoint ?? { socketPath: this.opts.socketPath });
    }
    raw(method, path, body, signal, to = this.target(), headers = {}) {
        // a remote server wants its bearer token on every request (a local socket is guarded by its file permissions)
        const token = this.remoteEndpoint && "host" in to ? this.remoteEndpoint.token : undefined;
        return rawRequest(to, method, path, { body, signal, headers, ...(token ? { token } : {}) });
    }
    async rawJson(method, path, body) {
        return jsonOf(await this.raw(method, path, body), path);
    }
    /**
     * A request to the server, found first when needed; the response as it came (status, headers, the body still
     * streaming). A connection failure looks for the server again once; a remote server that refuses the token is
     * rekeyed once.
     */
    async request(method, path, body, signal, headers) {
        await this.ensure();
        try {
            const res = await this.raw(method, path, body, signal, this.target(), headers);
            if (res.status === 401 && this.opts.remote && this.child) {
                res.body.resume();
                this.remoteNext = "rekey";
                this.retire(this.child);
                await this.ensure();
                return this.raw(method, path, body, signal, this.target(), headers);
            }
            return res;
        }
        catch (err) {
            if (signal?.aborted)
                throw err;
            if (this.opts.remote) {
                const kind = remoteFailure(err);
                // slow is not gone: restarting it would cut every open stream
                if (kind === "busy")
                    throw new LocalError(`the desktop did not answer: ${err instanceof Error ? err.message : String(err)}`, 503);
                this.remoteNext = kind;
            }
            this.log.warn(`helper unreachable (${err instanceof Error ? err.message : err}); restarting it`);
            if (this.child)
                this.retire(this.child);
            await this.ensure();
            return this.raw(method, path, body, signal, this.target(), headers);
        }
    }
    /** `request` with a JSON answer (a non-2xx `{ error }` becomes a LocalError with the server's status, answerError). */
    async json(method, path, body) {
        return jsonOf(await this.request(method, path, body), path);
    }
    // ------------------------------------------------------------------------- the API
    /**
     * GET /status, unchecked. Lifecycle on the way: an installed app that never answered was replaced since a child stood
     * in for it → that child goes (the next look opens the app); a child without Screen Recording older than
     * REFRESH_GRANT_MS goes (macOS caches the grant per process; the app restarts its own service for that).
     */
    async status() {
        if (this.silentApp && this.child && !this.attached && this.appStamp(this.silentApp.path) !== this.silentApp.stamp) {
            this.log.log(`${this.silentApp.path} changed; looking for ${APP_NAME} again`);
            this.silentApp = null;
            this.retire(this.child);
        }
        const st = await this.json("GET", "/status");
        if (st.session?.loggedIn === true && st.ok && !st.screenRecording && this.child && !this.attached && this.now() - this.startedAt > REFRESH_GRANT_MS) {
            this.retire(this.child);
        }
        return st;
    }
    /** One JPEG of a display (default the main one); `visible` masks every other app, `crop` is a region at full resolution. */
    async frame(p) {
        const q = new URLSearchParams(query({ display: p.display, maxWidth: p.maxWidth, quality: p.quality }).slice(1));
        if (p.visible)
            q.set("visible", p.visible.join(","));
        if (p.hide)
            q.set("hide", p.hide);
        if (p.crop)
            q.set("crop", [p.crop.x, p.crop.y, p.crop.w, p.crop.h].map((n) => String(Math.round(n * 1e6) / 1e6)).join(","));
        const qs = q.toString();
        const res = await this.request("GET", `/frame${qs ? `?${qs}` : ""}`);
        const buf = await readAll(res.body);
        if (res.status < 200 || res.status >= 300)
            throw answerError(res.status, safeJson(buf));
        const h = positiveHeader(res);
        return { jpeg: buf, width: h("x-frame-width"), height: h("x-frame-height"), display: h("x-display"), crop: regionHeader(res.headers["x-crop"]) };
    }
    /** The apps and on-screen windows (GET /windows; `display`: only its windows). */
    async windows(display) {
        return parseWindows(await this.json("GET", `/windows${query({ display })}`));
    }
    /** The app at a normalized point of a display (GET /hit). */
    async hit(display, x, y) {
        return parseHit(await this.json("GET", `/hit?display=${display}&x=${x}&y=${y}`));
    }
    /** One app's windows, front to back, off-screen and minimized ones too (GET /app/windows). */
    async appWindows(bundleId) {
        return parseAppWindows(await this.json("GET", `/app/windows?bundleId=${encodeURIComponent(bundleId)}`));
    }
    /** One window's picture (GET /app/screenshot), covered or on another Space or not. */
    async appScreenshot(window, p = {}) {
        const res = await this.request("GET", `/app/screenshot${query({ window, maxWidth: p.maxWidth, quality: p.quality, hide: p.hide })}`);
        const buf = await readAll(res.body);
        if (res.status < 200 || res.status >= 300)
            throw answerError(res.status, safeJson(buf));
        const h = positiveHeader(res);
        return { jpeg: buf, width: h("x-frame-width"), height: h("x-frame-height"), window: h("x-window"), bounds: regionHeader(res.headers["x-window-bounds"]) };
    }
    /** A window's actionable elements (GET /app/ax; 403 without Accessibility). */
    async appAx(window, max, hide) {
        return parseAppAx(await this.json("GET", `/app/ax${query({ window, max, hide })}`));
    }
    /**
     * The video stream (multipart: H.264 / HEVC, cursor and status parts), not read yet: the caller pipes it; abort
     * `signal` to stop it. `accept`: the viewer's `Accept`, passed on, so the part names are the ones it understands.
     * A remote server's `hold` keeps its machine up while the stream is open.
     */
    async stream(p, signal, accept) {
        const res = await this.request("GET", `/stream${query(p)}`, undefined, signal, acceptHeader(accept));
        if (res.status < 200 || res.status >= 300)
            throw answerError(res.status, safeJson(await readAll(res.body)));
        const release = this.opts.remote?.hold?.();
        if (release)
            res.body.once("close", release);
        return res;
    }
    /** The sound (`GET /audio`: Opus parts), not read yet: the caller pipes it. The server's error status passes through. */
    async audio(signal, accept) {
        const res = await this.request("GET", "/audio", undefined, signal, acceptHeader(accept));
        if (res.status < 200 || res.status >= 300)
            throw answerError(res.status, safeJson(await readAll(res.body)));
        return res;
    }
    /** POST /input of a checked input (parseInput). */
    async input(input) {
        const answer = await this.json("POST", "/input", input);
        // a move another one overtook (its `seq` is older than one already applied): the server didn't apply it
        const stale = !!answer && typeof answer === "object" && answer.stale === true;
        return stale ? { ok: true, stale: true } : { ok: true };
    }
    /**
     * A viewer's ack for a stream (checked: parseStreamAck) → POST /stream/ack. The answer as it is when it is a JSON
     * object (`{ ok, net? }`); anything else → `{ ok: true }`, with status 404 kept (no such stream: the viewer stops
     * acking), else 200.
     */
    async ack(raw) {
        const res = await this.request("POST", "/stream/ack", parseStreamAck(raw));
        const json = safeJson(await readAll(res.body));
        if (res.status >= 200 && res.status < 300 && json && typeof json === "object" && !Array.isArray(json)) {
            return { status: 200, body: json };
        }
        if (res.status === 404) {
            const error = json && typeof json === "object" && !Array.isArray(json) ? json.error : undefined;
            return { status: 404, body: { error: typeof error === "string" ? error : "no open stream" } };
        }
        return { status: 200, body: { ok: true } };
    }
    /** Whether the focused element takes typing (GET /focus). */
    async focus(display) {
        return parseFocus(await this.json("GET", `/focus${query({ display })}`));
    }
    /** POST /permissions/request: the app asks the user for its missing grants. */
    async requestPermissions() {
        await this.json("POST", "/permissions/request");
    }
    /**
     * The automation indicator (POST /automation: a border and "<label> is using this computer · press Esc to stop"),
     * in order, best effort: `true` may find the server first; `false` goes only to one in use. A server without the
     * route (404: an older Yoyo Control) gets POST /agent-control. A failure is logged. `automationActive` follows at once.
     */
    setAutomation(active, label) {
        this.automation = active;
        if (this.unavailableReason() || this.stopped)
            return;
        this.automationChain = this.automationChain.then(async () => {
            if (!active && !this.child)
                return;
            try {
                let r;
                try {
                    r = await this.json("POST", "/automation", label !== undefined ? { active, label } : { active });
                }
                catch (err) {
                    if (!(err instanceof LocalError && err.status === 404))
                        throw err;
                    r = await this.json("POST", "/agent-control", { active });
                }
                if (active && r?.esc === false)
                    this.log.log("the helper can't watch for Esc (no Accessibility permission)");
            }
            catch (err) {
                this.log.warn(`POST /automation failed: ${err instanceof Error ? err.message : err}`);
            }
        });
    }
    /** The setAutomation calls so far have been answered. */
    automationSettled() {
        return this.automationChain;
    }
    /** Stops everything: no more requests; the automation indicator goes down on an app (it outlives this client); a child is stopped. */
    stop() {
        this.stopped = true;
        this.events?.abort.abort();
        this.events = null;
        if (this.eventsTimer)
            clearTimeout(this.eventsTimer);
        this.eventsTimer = null;
        if (this.attached && this.automation) {
            const off = (path) => this.raw("POST", path, { active: false }).then((r) => (r.body.resume(), r.status), () => 0);
            void off("/automation").then((status) => (status === 404 ? off("/agent-control") : undefined));
        }
        this.child?.kill("SIGTERM");
        this.child = null;
    }
}
/** A JSON answer: not JSON → 502; non-2xx → answerError. */
async function jsonOf(res, path) {
    const text = await readAll(res.body);
    let json;
    try {
        json = JSON.parse(text.toString("utf8"));
    }
    catch {
        throw new LocalError(`screen helper: bad answer to ${path} (HTTP ${res.status})`, 502);
    }
    if (res.status < 200 || res.status >= 300)
        throw answerError(res.status, json);
    return json;
}
const positiveHeader = (res) => (name) => {
    const v = Number(res.headers[name]);
    return Number.isFinite(v) && v > 0 ? v : null;
};
function defaultSpawn(path, args, log) {
    // stdin stays an open pipe: the service exits when it closes (this process died)
    const child = nodeSpawn(path, args, { stdio: ["pipe", "ignore", "pipe"] });
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (s) => {
        for (const line of s.split("\n"))
            if (line.trim())
                log.log(`${new Date().toISOString()} helper: ${line.trim()}`);
    });
    return child;
}
