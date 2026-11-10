const isFallbackKind = (k) => k === "relay" || k === "tunnel";
const rankOf = (k) => (k === "link" ? -1 : k === "lan" ? 0 : k === "direct" ? 1 : 2);
/** A candidate with the defaults filled in. */
export function candidate(c) {
    const label = c.label ?? { lan: "LAN", direct: "direct", relay: "relay", tunnel: "tunnel", link: "link" }[c.kind];
    const report = c.report ?? (c.kind === "lan" ? "lan" : c.kind === "direct" || c.kind === "link" ? "direct" : "tunnel");
    return { id: c.id ?? [c.kind, c.host].filter(Boolean).join(":"), kind: c.kind, label, isLocalNetwork: c.isLocalNetwork ?? c.kind === "lan", credential: c.credential ?? null, report, data: c.data };
}
const sameCandidate = (a, b) => a.id === b.id && a.kind === b.kind && (a.credential ?? null) === (b.credential ?? null);
export function routeOf(c, hasFallback) {
    return { id: c.id, isLocalNetwork: c.isLocalNetwork, isDirect: !isFallbackKind(c.kind), isShortcut: hasFallback && !isFallbackKind(c.kind), label: c.label, report: c.report };
}
/** The default: a refusal by the computer (400 / 403 / 404 / 409 / 413, another device in control) is an answer; 401
 *  is unauthorized; anything else (a network error, 5xx) is the way. */
export function classifyFailure(error) {
    const status = error?.status;
    if (typeof status !== "number")
        return "link";
    if (status === 401)
        return "unauthorized";
    if ([400, 403, 404, 409, 413].includes(status))
        return "answer";
    return "link";
}
export const DEFAULT_POLICY = {
    offsets: { link: -250, lan: 0, direct: 150, relay: 300, tunnel: 300 },
    linkGraceMs: 1500,
    decisionWaitMs: 500,
    openTimeoutMs: 3000,
    retryIntervalMs: 30_000,
    ackFailuresToLeave: 3,
    renewBeforeMs: 10 * 60_000,
    pathSettleMs: 300,
    keepRetiredMs: 5000,
    classify: classifyFailure,
};
export const browserClock = {
    now: () => performance.now(),
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (h) => clearTimeout(h),
};
function sleep(clock, ms, signal) {
    return new Promise((resolve) => {
        if (ms <= 0 || signal?.aborted)
            return resolve();
        const h = clock.setTimeout(() => {
            signal?.removeEventListener("abort", done);
            resolve();
        }, ms);
        const done = () => {
            clock.clearTimeout(h);
            resolve();
        };
        signal?.addEventListener("abort", done, { once: true });
    });
}
/** The first of `candidates` reached, each kind starting at its offset; the others are aborted, a late one released. */
export function raceFirst(candidates, offsets, probe, release, signal, clock = browserClock) {
    if (candidates.length === 0 || signal.aborted)
        return Promise.resolve({ t: "unreachable" });
    const start = Math.min(...candidates.map((c) => offsets[c.kind] ?? 0));
    const plan = candidates.map((c, i) => ({ c, i, delay: Math.max((offsets[c.kind] ?? 0) - start, 0) })).sort((a, b) => a.delay - b.delay || a.i - b.i);
    const inner = new AbortController();
    const abort = () => inner.abort();
    signal.addEventListener("abort", abort, { once: true });
    return new Promise((resolve) => {
        let pending = plan.length;
        let unauthorized = false;
        let done = false;
        const finish = (o) => {
            if (done)
                return;
            done = true;
            signal.removeEventListener("abort", abort);
            inner.abort();
            resolve(o);
        };
        signal.addEventListener("abort", () => finish({ t: "unreachable" }), { once: true });
        for (const { c, delay } of plan) {
            void (async () => {
                await sleep(clock, delay, inner.signal);
                let p = { t: "unreachable" };
                if (!inner.signal.aborted) {
                    try {
                        p = await probe(c, inner.signal);
                    }
                    catch {
                        p = { t: "unreachable" };
                    }
                }
                pending--;
                if (p.t === "reached") {
                    if (done)
                        release(p.link);
                    else
                        finish({ t: "reached", link: p.link, candidate: p.as ?? c });
                    return;
                }
                if (p.t === "unauthorized")
                    unauthorized = true;
                if (pending === 0)
                    finish(unauthorized ? { t: "unauthorized" } : { t: "unreachable" });
            })();
        }
    });
}
/** The ways of one backend to its computer: shared by the backend (which link a request on a route goes through) and
 *  its connector (which way is current). It starts with `initial` and knows the fallbacks it may go back to. */
export class ConnectWays {
    ways = new Map();
    cur;
    next = 0;
    closedFlag = false;
    fallbacks;
    hasFallback;
    constructor(initial, link, fallbacks = []) {
        this.fallbacks = fallbacks.filter((f) => isFallbackKind(f.kind) && f.id !== initial.id);
        this.hasFallback = isFallbackKind(initial.kind) || this.fallbacks.length > 0;
        this.cur = initial;
        this.ways.set(initial.id, { candidate: initial, link, token: 0 });
    }
    get current() {
        return routeOf(this.cur, this.hasFallback);
    }
    get currentCandidate() {
        return this.cur;
    }
    get currentLink() {
        return this.ways.get(this.cur.id)?.link ?? null;
    }
    get isClosed() {
        return this.closedFlag;
    }
    route(c) {
        return routeOf(c, this.hasFallback);
    }
    /** The link of `route` (null: no such way any more). */
    link(route) {
        return this.ways.get(route.id)?.link ?? null;
    }
    candidate(route) {
        return this.ways.get(route.id)?.candidate ?? null;
    }
    put(c, link, current) {
        if (this.closedFlag)
            return null;
        const replaced = this.ways.get(c.id)?.link ?? null;
        const token = ++this.next;
        this.ways.set(c.id, { candidate: c, link, token });
        if (current)
            this.cur = c;
        return { token, replaced };
    }
    token(id) {
        return this.ways.get(id)?.token ?? null;
    }
    setCurrent(id) {
        const w = this.ways.get(id);
        if (!w)
            return false;
        this.cur = w.candidate;
        return true;
    }
    heldFallback() {
        const held = [...this.ways.values()].map((w) => w.candidate).filter((c) => isFallbackKind(c.kind));
        for (const f of this.fallbacks) {
            const c = held.find((h) => h.id === f.id);
            if (c)
                return c;
        }
        return held[0] ?? null;
    }
    remove(id, token) {
        const w = this.ways.get(id);
        if (this.cur.id === id || !w || w.token !== token)
            return null;
        this.ways.delete(id);
        return w.link;
    }
    close() {
        this.closedFlag = true;
        const links = [...this.ways.values()].map((w) => w.link);
        this.ways.clear();
        return links;
    }
}
export function browserPath() {
    const online = typeof navigator === "undefined" || navigator.onLine !== false;
    const type = navigator.connection?.type;
    return { online, hasLocal: online && type !== "cellular" && type !== "none" };
}
const signature = (p) => `${p.online}|${p.hasLocal}`;
export class Connector {
    ways;
    source;
    clock;
    onChange = null;
    policy;
    /** The source may give a `link` candidate: races try for it from any other way. Set before `activate`. */
    linkPossible = false;
    /** Off: the host calls `pathUpdated` itself (tests). */
    watchesPath = true;
    shortcutsAllowed = true;
    supported = true;
    path = { online: true, hasLocal: true };
    active = false;
    closed = false;
    attempt = 0;
    racing = null;
    raceWaits = false;
    settling = null;
    nextTry = null;
    renewAt = null;
    renewing = false;
    timer = null;
    reachingFallback = null;
    lostAcks = 0;
    reissued = false;
    pathSig = null;
    linkRacing = false;
    currentEnded = false;
    unwatch = null;
    constructor(ways, source, policy = {}, clock = browserClock) {
        this.ways = ways;
        this.source = source;
        this.clock = clock;
        this.policy = { ...DEFAULT_POLICY, ...policy, offsets: { ...DEFAULT_POLICY.offsets, ...policy.offsets } };
    }
    get current() {
        return this.ways.current;
    }
    get decisionWaitMs() {
        return this.policy.decisionWaitMs;
    }
    get openTimeoutMs() {
        return this.policy.openTimeoutMs;
    }
    get isDeciding() {
        if (!((this.racing !== null || this.settling !== null) && this.raceWaits))
            return false;
        return isFallbackKind(this.kind) || this.currentEnded || (this.linkRacing && this.kind !== "link");
    }
    get kind() {
        return this.ways.currentCandidate.kind;
    }
    // ---------------------------------------------------------------- ScreenRouting
    newVisit() {
        this.supported = true;
        this.nextTry = null;
        this.reissued = false;
        this.lostAcks = 0;
    }
    activate() {
        if (this.closed)
            return;
        this.active = true;
        this.startPathWatch();
        this.tryBetter(true);
        this.schedule();
    }
    streamWillOpen() {
        this.tryBetter(true);
    }
    leave() {
        this.active = false;
        this.cancelRace();
        this.clearTimer();
        this.renewing = false;
        this.renewAt = null;
        this.unwatch?.();
        this.unwatch = null;
        this.pathSig = null;
        if (!isFallbackKind(this.kind)) {
            const fb = this.ways.heldFallback();
            if (fb)
                this.move(fb);
        }
        this.changed();
    }
    streamFailed(route, unauthorized) {
        if (route.id !== this.current.id || !this.current.isShortcut)
            return;
        if (unauthorized)
            this.unauthorized();
        else
            this.failed();
    }
    ackAnswered(route, status) {
        if (route.id !== this.current.id || !this.current.isShortcut)
            return;
        if (status === 401)
            return this.unauthorized();
        if (status !== null && status < 500) {
            this.lostAcks = 0;
            this.reissued = false;
            return;
        }
        if (++this.lostAcks >= this.policy.ackFailuresToLeave)
            this.failed();
    }
    async fallback(route, error) {
        if (!route.isShortcut || !this.ways.hasFallback)
            return null;
        switch (this.policy.classify(error)) {
            case "answer":
                return null;
            case "unauthorized":
                if (route.id === this.current.id)
                    this.unauthorized();
                break;
            case "link":
                if (route.id === this.current.id)
                    this.failed();
                break;
        }
        const fb = await this.reachFallback();
        return fb ? this.ways.route(fb) : null;
    }
    // ---------------------------------------------------------------- the host's
    setShortcutsAllowed(on) {
        if (on === this.shortcutsAllowed)
            return;
        this.shortcutsAllowed = on;
        if (on) {
            this.nextTry = null;
            this.tryBetter(true);
        }
        else {
            this.cancelRace();
            if (!isFallbackKind(this.kind))
                this.demote();
        }
        this.schedule();
        this.changed();
    }
    close() {
        this.leave();
        this.closed = true;
        for (const l of this.ways.close())
            this.source.release?.(l);
    }
    /** A change of network (the connector's own watch's, or the host's with `watchesPath` off). */
    pathUpdated(next) {
        if (!this.active) {
            this.path = next;
            return;
        }
        const first = this.pathSig === null;
        const sig = signature(next);
        if (sig === this.pathSig)
            return;
        this.pathSig = sig;
        const old = this.path;
        this.path = next;
        const lost = !next.online || (!first && old.hasLocal && !next.hasLocal && this.kind === "lan") || !this.usable(this.ways.currentCandidate);
        if (first && !lost && old.online === next.online && old.hasLocal === next.hasLocal)
            return;
        this.cancelRace();
        if (lost && this.current.isShortcut)
            this.demote();
        this.nextTry = null;
        if (next.online) {
            this.raceWaits = true;
            const anyRank = lost || !this.ways.hasFallback;
            this.settling = this.clock.setTimeout(() => {
                this.settling = null;
                this.tryBetter(true, "held", anyRank);
            }, this.policy.pathSettleMs);
        }
        this.schedule();
        this.changed();
    }
    // ---------------------------------------------------------------- racing
    get bestRankHere() {
        if (!this.shortcutsAllowed || !this.supported || !this.path.online)
            return null;
        if (this.linkPossible)
            return rankOf("link");
        return this.path.hasLocal ? 0 : 1;
    }
    get canImprove() {
        const best = this.bestRankHere;
        return best !== null && (this.currentEnded || best < rankOf(this.kind));
    }
    usable(c) {
        if (c.kind === "lan")
            return this.path.hasLocal;
        if (c.kind === "direct" || c.kind === "link")
            return this.path.online;
        return true;
    }
    raceable(cs, anyRank) {
        const rank = rankOf(this.kind);
        return cs.filter((c) => !isFallbackKind(c.kind) && this.usable(c) && (anyRank || rankOf(c.kind) < rank));
    }
    tryBetter(wait, reason = "held", anyRank = false) {
        if (!this.active || this.closed)
            return;
        const any = anyRank || this.currentEnded;
        if (this.racing) {
            if (wait && !this.raceWaits) {
                this.raceWaits = true;
                this.changed();
            }
            return;
        }
        if (!this.shortcutsAllowed || !this.supported || !this.path.online || !(any || this.canImprove))
            return;
        if (this.nextTry !== null && this.clock.now() < this.nextTry)
            return;
        if (this.settling !== null)
            this.clock.clearTimeout(this.settling);
        this.settling = null;
        const a = ++this.attempt;
        this.raceWaits = wait;
        const ctrl = new AbortController();
        this.racing = ctrl;
        void this.race(a, reason, any, ctrl.signal);
        this.changed();
    }
    async race(a, first, anyRank, signal) {
        let reason = first;
        for (let round = 0; round < 2; round++) {
            let supply;
            try {
                supply = await this.source.candidates(reason);
            }
            catch {
                if (a !== this.attempt)
                    return;
                break;
            }
            if (a !== this.attempt)
                return;
            if (!supply) {
                this.supported = false;
                break;
            }
            const held = !supply.fresh;
            const expiring = supply.expires != null && supply.expires - Date.now() < this.policy.renewBeforeMs;
            const cs = held && expiring ? [] : this.raceable(supply.candidates, anyRank);
            if (cs.length) {
                const { outcome, interim } = await this.reach(cs, a, supply, signal);
                if (a !== this.attempt || !this.active) {
                    if (outcome.t === "reached")
                        this.source.release?.(outcome.link);
                    return;
                }
                if (outcome.t === "reached") {
                    this.take(outcome.candidate, outcome.link, supply);
                    break;
                }
                if (interim)
                    break;
            }
            if (!held || round !== 0)
                break;
            reason = "stale";
        }
        this.racing = null;
        this.raceWaits = false;
        this.linkRacing = false;
        this.nextTry = this.clock.now() + this.policy.retryIntervalMs;
        this.schedule();
        this.changed();
    }
    async reach(cs, a, supply, signal) {
        const { offsets, linkGraceMs } = this.policy;
        const release = (l) => this.source.release?.(l);
        const probe = this.source.probe.bind(this.source);
        const links = cs.filter((c) => c.kind === "link");
        const others = cs.filter((c) => c.kind !== "link");
        if (!links.length)
            return { outcome: await raceFirst(cs, offsets, probe, release, signal, this.clock), interim: false };
        const started = this.clock.now();
        this.linkRacing = true;
        this.changed();
        try {
            const linkCtrl = new AbortController();
            signal.addEventListener("abort", () => linkCtrl.abort(), { once: true });
            const linkRace = raceFirst(links, offsets, probe, release, linkCtrl.signal, this.clock);
            if (!others.length)
                return { outcome: await linkRace, interim: false };
            const head = Math.max(Math.min(...others.map((c) => offsets[c.kind] ?? 0)) - (offsets.link ?? 0), 0);
            const done = { o: null };
            void linkRace.then((o) => (done.o = o));
            await Promise.race([linkRace, sleep(this.clock, head, signal)]);
            const early = done.o;
            if (early) {
                if (early.t === "reached")
                    return { outcome: early, interim: false };
                return { outcome: await raceFirst(others, offsets, probe, release, signal, this.clock), interim: false };
            }
            const othersRace = raceFirst(others, offsets, probe, release, signal, this.clock);
            const first = await Promise.race([linkRace.then((o) => ({ link: true, o })), othersRace.then((o) => ({ link: false, o }))]);
            if (first.link) {
                if (first.o.t !== "reached")
                    return { outcome: await othersRace, interim: false };
                void othersRace.then((o) => o.t === "reached" && release(o.link));
                return { outcome: first.o, interim: false };
            }
            if (first.o.t !== "reached")
                return { outcome: await linkRace, interim: false };
            if (a !== this.attempt || !this.active)
                return { outcome: first.o, interim: false };
            this.take(first.o.candidate, first.o.link, supply);
            const left = started + linkGraceMs - this.clock.now();
            await Promise.race([linkRace, sleep(this.clock, left, signal)]);
            const late = done.o;
            if (late?.t === "reached")
                return { outcome: late, interim: false };
            linkCtrl.abort();
            return { outcome: { t: "unreachable" }, interim: true };
        }
        finally {
            this.linkRacing = false;
        }
    }
    take(c, link, supply) {
        if (!this.shortcutsAllowed || !this.usable(c)) {
            this.source.release?.(link);
            return;
        }
        const old = this.ways.currentCandidate;
        if (sameCandidate(old, c) && !this.currentEnded) {
            this.source.release?.(link);
        }
        else {
            const put = this.ways.put(c, link, true);
            if (!put) {
                this.source.release?.(link);
                return;
            }
            if (put.replaced !== null)
                this.retireLink(put.replaced);
            if (old.id !== c.id && !isFallbackKind(old.kind))
                this.retire(old.id);
            this.watchEnd(c.id, put.token, link);
        }
        this.currentEnded = false;
        this.lostAcks = 0;
        this.renewAt = supply.expires != null ? this.renewDeadline(supply.expires) : null;
        this.changed();
    }
    renewDeadline(expires) {
        return this.clock.now() + Math.max(expires - Date.now() - this.policy.renewBeforeMs, this.policy.retryIntervalMs);
    }
    cancelRace() {
        this.attempt++;
        this.racing?.abort();
        this.racing = null;
        if (this.settling !== null)
            this.clock.clearTimeout(this.settling);
        this.settling = null;
        this.raceWaits = false;
    }
    watchEnd(id, token, link) {
        const ended = this.source.ended;
        if (!ended)
            return;
        void ended.call(this.source, link).then((yes) => yes && this.wayEnded(id, token));
    }
    wayEnded(id, token) {
        if (this.closed || this.ways.token(id) !== token)
            return;
        if (this.ways.currentCandidate.id === id) {
            this.lostAcks = 0;
            this.renewAt = null;
            const fb = this.ways.heldFallback();
            if (fb)
                this.move(fb);
            else if (this.ways.hasFallback)
                this.demote();
            this.currentEnded = this.ways.currentCandidate.id === id;
        }
        const l = this.ways.remove(id, token);
        if (l !== null)
            this.source.release?.(l);
        this.cancelRace();
        this.nextTry = null;
        this.tryBetter(true);
        this.schedule();
        this.changed();
    }
    // ---------------------------------------------------------------- failures
    failed() {
        if (!this.current.isShortcut)
            return;
        this.nextTry = this.clock.now() + this.policy.retryIntervalMs;
        this.demote();
        this.schedule();
        this.changed();
    }
    unauthorized() {
        if (!this.current.isShortcut)
            return;
        if (this.reissued)
            return this.failed();
        this.reissued = true;
        this.demote();
        this.cancelRace();
        this.nextTry = null;
        this.tryBetter(true, "unauthorized", true);
        this.schedule();
    }
    demote() {
        this.lostAcks = 0;
        this.renewAt = null;
        this.renewing = false;
        if (isFallbackKind(this.kind))
            return;
        const fb = this.ways.heldFallback();
        if (fb)
            return this.move(fb);
        if (!this.ways.fallbacks.length)
            return;
        const from = this.ways.currentCandidate.id;
        void this.reachFallback().then((f) => {
            if (f && this.ways.currentCandidate.id === from) {
                this.move(f);
                this.schedule();
            }
        });
    }
    reachFallback() {
        const held = this.ways.heldFallback();
        if (held)
            return Promise.resolve(held);
        if (this.reachingFallback)
            return this.reachingFallback;
        if (this.closed || !this.ways.fallbacks.length)
            return Promise.resolve(null);
        const p = (async () => {
            const o = await raceFirst(this.ways.fallbacks, this.policy.offsets, this.source.probe.bind(this.source), (l) => this.source.release?.(l), new AbortController().signal, this.clock);
            if (o.t !== "reached")
                return null;
            if (!this.ways.put(o.candidate, o.link, false)) {
                this.source.release?.(o.link);
                return null;
            }
            return o.candidate;
        })();
        this.reachingFallback = p;
        void p.finally(() => {
            if (this.reachingFallback === p)
                this.reachingFallback = null;
        });
        return p;
    }
    move(c) {
        const old = this.ways.currentCandidate;
        if (old.id === c.id || !this.ways.setCurrent(c.id))
            return;
        this.currentEnded = false;
        if (!isFallbackKind(old.kind))
            this.retire(old.id);
        this.changed();
    }
    retire(id) {
        const token = this.ways.token(id);
        if (token === null)
            return;
        this.clock.setTimeout(() => {
            const l = this.ways.remove(id, token);
            if (l !== null)
                this.source.release?.(l);
        }, this.policy.keepRetiredMs);
    }
    retireLink(link) {
        this.clock.setTimeout(() => this.source.release?.(link), this.policy.keepRetiredMs);
    }
    // ---------------------------------------------------------------- renewal and timers
    renew() {
        const from = this.ways.currentCandidate;
        this.renewing = true;
        void this.source.candidates("renew").then((supply) => this.renewed(from, supply), () => this.renewed(from, undefined));
    }
    renewed(from, supply) {
        if (!this.renewing)
            return;
        this.renewing = false;
        if (this.ways.currentCandidate.id !== from.id)
            return;
        if (supply === undefined)
            this.renewAt = this.clock.now() + this.policy.retryIntervalMs;
        else if (supply === null) {
            this.supported = false;
            this.demote();
        }
        else if (supply.candidates.some((c) => sameCandidate(c, from))) {
            this.renewAt = supply.expires != null ? this.renewDeadline(supply.expires) : null;
        }
        else {
            this.demote();
            this.nextTry = null;
            this.tryBetter(true, "held", true);
        }
        this.schedule();
        this.changed();
    }
    clearTimer() {
        if (this.timer !== null)
            this.clock.clearTimeout(this.timer);
        this.timer = null;
    }
    schedule() {
        this.clearTimer();
        if (!this.active || this.closed)
            return;
        let next = null;
        if (!this.racing && this.settling === null && this.canImprove && this.nextTry !== null)
            next = this.nextTry;
        if (this.current.isShortcut && !this.renewing && this.renewAt !== null)
            next = next === null ? this.renewAt : Math.min(next, this.renewAt);
        if (next === null)
            return;
        this.timer = this.clock.setTimeout(() => {
            this.timer = null;
            this.fire();
        }, Math.max(0, next - this.clock.now()));
    }
    fire() {
        const now = this.clock.now();
        if (this.renewAt !== null && now >= this.renewAt && this.current.isShortcut && !this.renewing) {
            this.renewAt = null;
            this.renew();
        }
        if (this.nextTry !== null && now >= this.nextTry)
            this.tryBetter(false);
        this.schedule();
    }
    changed() {
        this.onChange?.();
    }
    startPathWatch() {
        if (this.unwatch || !this.watchesPath || typeof window === "undefined")
            return;
        const update = () => this.pathUpdated(browserPath());
        const conn = navigator.connection;
        window.addEventListener("online", update);
        window.addEventListener("offline", update);
        conn?.addEventListener?.("change", update);
        this.unwatch = () => {
            window.removeEventListener("online", update);
            window.removeEventListener("offline", update);
            conn?.removeEventListener?.("change", update);
        };
        update();
    }
}
