import type { ScreenRoute, ScreenRouting } from "./contracts.js";

/**
 * A `ScreenRouting` over candidate ways to one computer (the iOS kit's YoyoConnect, ios/README.md「YoyoConnect」), for
 * one visit of the Screen page: the backend supplies candidates and probes them (`ConnectSource`), the connector decides
 * which way is current and the page moves its stream and sound with it.
 *
 * - **Races**, happy eyeballs (`ConnectPolicy.offsets`): when the page shows, when a stream is about to open, every
 *   `retryIntervalMs` while on a worse way than the network allows, and after a change of network. Only candidates
 *   better than the way in use race. The first reached becomes current. A stream about to open waits up to
 *   `decisionWaitMs` for a race that may move it off a fallback.
 * - **Link** first: a `link` candidate (a uu Link session) is better than every other way; it starts alone, the
 *   others start `offsets` later only if it isn't reached by then, and one of them reached first is taken meanwhile
 *   while the link may still win within `linkGraceMs` (the stream moves to it). A link whose session ends
 *   (`ConnectSource.ended`) is left at once.
 * - **Shortcuts** (a non-fallback way while the ways have a fallback): their stream failing, `ackFailuresToLeave` acks
 *   lost in a row, or a request failing on the way (`classify`) goes back to the fallback at once (the request is sent
 *   again there); then no race for `retryIntervalMs`.
 * - **Credentials**: a held supply is asked anew once when racing it reached nothing; a 401 on the way in use goes to
 *   the fallback and races a fresh supply at once, once. A supply that `expires` is renewed `renewBeforeMs` before.
 * - **Network**: `online` / `offline` and `navigator.connection` changes (a browser can't see its interfaces: `lan`
 *   candidates are tried unless the connection type says cellular). Going offline leaves a shortcut at once.
 */

export type CandidateKind = "lan" | "direct" | "relay" | "tunnel" | "link";

const isFallbackKind = (k: CandidateKind) => k === "relay" || k === "tunnel";
const rankOf = (k: CandidateKind) => (k === "link" ? -1 : k === "lan" ? 0 : k === "direct" ? 1 : 2);

/** One way to reach a computer that a connector may race and use. `data`: the backend's own (an address, a ticket). */
export interface Candidate {
  /** The route's id. Default `<kind>:<host>`. */
  id: string;
  kind: CandidateKind;
  label: string;
  isLocalNetwork: boolean;
  /** What its requests authenticate with: a candidate with another credential is another one. */
  credential?: string | null;
  report: ScreenRoute["report"];
  data?: unknown;
}

/** A candidate with the defaults filled in. */
export function candidate(c: { kind: CandidateKind; id?: string; host?: string; label?: string; isLocalNetwork?: boolean; credential?: string | null; report?: ScreenRoute["report"]; data?: unknown }): Candidate {
  const label = c.label ?? { lan: "LAN", direct: "direct", relay: "relay", tunnel: "tunnel", link: "link" }[c.kind];
  const report = c.report ?? (c.kind === "lan" ? "lan" : c.kind === "direct" || c.kind === "link" ? "direct" : "tunnel");
  return { id: c.id ?? [c.kind, c.host].filter(Boolean).join(":"), kind: c.kind, label, isLocalNetwork: c.isLocalNetwork ?? c.kind === "lan", credential: c.credential ?? null, report, data: c.data };
}

const sameCandidate = (a: Candidate, b: Candidate) => a.id === b.id && a.kind === b.kind && (a.credential ?? null) === (b.credential ?? null);

export function routeOf(c: Candidate, hasFallback: boolean): ScreenRoute {
  return { id: c.id, isLocalNetwork: c.isLocalNetwork, isDirect: !isFallbackKind(c.kind), isShortcut: hasFallback && !isFallbackKind(c.kind), label: c.label, report: c.report };
}

export type Probe<L> = { t: "reached"; link: L; as?: Candidate } | { t: "unauthorized" } | { t: "unreachable" };
export type Refresh = "held" | "stale" | "unauthorized" | "renew";

export interface Supply {
  /** The shortcuts; fallbacks are the ways'. */
  candidates: Candidate[];
  /** Just asked for, not held from before. */
  fresh: boolean;
  /** When their credential expires (ms since 1970). */
  expires?: number | null;
}

/** What a connector does on the network, from its host. */
export interface ConnectSource<L> {
  /** The candidates now; null: the computer has no other way (no more races this visit); a throw: tried again later. */
  candidates(why: Refresh): Promise<Supply | null>;
  /** Probes one candidate; `signal` aborts when another wins. */
  probe(c: Candidate, signal: AbortSignal): Promise<Probe<L>>;
  /** A link no longer in use. */
  release?(link: L): void;
  /** Resolves true when a link in use stops working by itself (a uu Link session ending); false: it doesn't. */
  ended?(link: L): Promise<boolean>;
}

export type Failure = "answer" | "unauthorized" | "link";

/** The default: a refusal by the computer (400 / 403 / 404 / 409 / 413, another device in control) is an answer; 401
 *  is unauthorized; anything else (a network error, 5xx) is the way. */
export function classifyFailure(error: unknown): Failure {
  const status = (error as { status?: unknown } | null)?.status;
  if (typeof status !== "number") return "link";
  if (status === 401) return "unauthorized";
  if ([400, 403, 404, 409, 413].includes(status)) return "answer";
  return "link";
}

export interface ConnectPolicy {
  /** When each kind's probes start after a race begins, relative to the best kind present (ms). */
  offsets: Record<CandidateKind, number>;
  linkGraceMs: number;
  decisionWaitMs: number;
  openTimeoutMs: number;
  retryIntervalMs: number;
  ackFailuresToLeave: number;
  renewBeforeMs: number;
  pathSettleMs: number;
  keepRetiredMs: number;
  classify: (error: unknown) => Failure;
}

export const DEFAULT_POLICY: Readonly<ConnectPolicy> = {
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

/** The timers a connector uses (tests pass their own). */
export interface Clock {
  now(): number;
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(h: unknown): void;
}

export const browserClock: Clock = {
  now: () => performance.now(),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
};

function sleep(clock: Clock, ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    if (ms <= 0 || signal?.aborted) return resolve();
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

export type Outcome<L> = { t: "reached"; link: L; candidate: Candidate } | { t: "unauthorized" } | { t: "unreachable" };

/** The first of `candidates` reached, each kind starting at its offset; the others are aborted, a late one released. */
export function raceFirst<L>(candidates: Candidate[], offsets: Record<CandidateKind, number>, probe: ConnectSource<L>["probe"], release: (l: L) => void, signal: AbortSignal, clock: Clock = browserClock): Promise<Outcome<L>> {
  if (candidates.length === 0 || signal.aborted) return Promise.resolve({ t: "unreachable" });
  const start = Math.min(...candidates.map((c) => offsets[c.kind] ?? 0));
  const plan = candidates.map((c, i) => ({ c, i, delay: Math.max((offsets[c.kind] ?? 0) - start, 0) })).sort((a, b) => a.delay - b.delay || a.i - b.i);
  const inner = new AbortController();
  const abort = () => inner.abort();
  signal.addEventListener("abort", abort, { once: true });
  return new Promise((resolve) => {
    let pending = plan.length;
    let unauthorized = false;
    let done = false;
    const finish = (o: Outcome<L>) => {
      if (done) return;
      done = true;
      signal.removeEventListener("abort", abort);
      inner.abort();
      resolve(o);
    };
    signal.addEventListener("abort", () => finish({ t: "unreachable" }), { once: true });
    for (const { c, delay } of plan) {
      void (async () => {
        await sleep(clock, delay, inner.signal);
        let p: Probe<L> = { t: "unreachable" };
        if (!inner.signal.aborted) {
          try {
            p = await probe(c, inner.signal);
          } catch {
            p = { t: "unreachable" };
          }
        }
        pending--;
        if (p.t === "reached") {
          if (done) release(p.link);
          else finish({ t: "reached", link: p.link, candidate: p.as ?? c });
          return;
        }
        if (p.t === "unauthorized") unauthorized = true;
        if (pending === 0) finish(unauthorized ? { t: "unauthorized" } : { t: "unreachable" });
      })();
    }
  });
}

/** The ways of one backend to its computer: shared by the backend (which link a request on a route goes through) and
 *  its connector (which way is current). It starts with `initial` and knows the fallbacks it may go back to. */
export class ConnectWays<L> {
  private ways = new Map<string, { candidate: Candidate; link: L; token: number }>();
  private cur: Candidate;
  private next = 0;
  private closedFlag = false;
  readonly fallbacks: Candidate[];
  readonly hasFallback: boolean;

  constructor(initial: Candidate, link: L, fallbacks: Candidate[] = []) {
    this.fallbacks = fallbacks.filter((f) => isFallbackKind(f.kind) && f.id !== initial.id);
    this.hasFallback = isFallbackKind(initial.kind) || this.fallbacks.length > 0;
    this.cur = initial;
    this.ways.set(initial.id, { candidate: initial, link, token: 0 });
  }

  get current(): ScreenRoute {
    return routeOf(this.cur, this.hasFallback);
  }
  get currentCandidate(): Candidate {
    return this.cur;
  }
  get currentLink(): L | null {
    return this.ways.get(this.cur.id)?.link ?? null;
  }
  get isClosed(): boolean {
    return this.closedFlag;
  }
  route(c: Candidate): ScreenRoute {
    return routeOf(c, this.hasFallback);
  }
  /** The link of `route` (null: no such way any more). */
  link(route: ScreenRoute): L | null {
    return this.ways.get(route.id)?.link ?? null;
  }
  candidate(route: ScreenRoute): Candidate | null {
    return this.ways.get(route.id)?.candidate ?? null;
  }

  put(c: Candidate, link: L, current: boolean): { token: number; replaced: L | null } | null {
    if (this.closedFlag) return null;
    const replaced = this.ways.get(c.id)?.link ?? null;
    const token = ++this.next;
    this.ways.set(c.id, { candidate: c, link, token });
    if (current) this.cur = c;
    return { token, replaced };
  }
  token(id: string): number | null {
    return this.ways.get(id)?.token ?? null;
  }
  setCurrent(id: string): boolean {
    const w = this.ways.get(id);
    if (!w) return false;
    this.cur = w.candidate;
    return true;
  }
  heldFallback(): Candidate | null {
    const held = [...this.ways.values()].map((w) => w.candidate).filter((c) => isFallbackKind(c.kind));
    for (const f of this.fallbacks) {
      const c = held.find((h) => h.id === f.id);
      if (c) return c;
    }
    return held[0] ?? null;
  }
  remove(id: string, token: number): L | null {
    const w = this.ways.get(id);
    if (this.cur.id === id || !w || w.token !== token) return null;
    this.ways.delete(id);
    return w.link;
  }
  close(): L[] {
    this.closedFlag = true;
    const links = [...this.ways.values()].map((w) => w.link);
    this.ways.clear();
    return links;
  }
}

/** What of the network decides which candidates are worth a try. */
export interface ConnectPath {
  online: boolean;
  /** A `lan` candidate is worth a try (a Wi-Fi / wired connection, or the browser doesn't say). */
  hasLocal: boolean;
}

export function browserPath(): ConnectPath {
  const online = typeof navigator === "undefined" || navigator.onLine !== false;
  const type = (navigator as Navigator & { connection?: { type?: string } }).connection?.type;
  return { online, hasLocal: online && type !== "cellular" && type !== "none" };
}

const signature = (p: ConnectPath) => `${p.online}|${p.hasLocal}`;

export class Connector<L> implements ScreenRouting {
  onChange: (() => void) | null = null;
  readonly policy: ConnectPolicy;
  /** The source may give a `link` candidate: races try for it from any other way. Set before `activate`. */
  linkPossible = false;
  /** Off: the host calls `pathUpdated` itself (tests). */
  watchesPath = true;
  shortcutsAllowed = true;
  supported = true;
  path: ConnectPath = { online: true, hasLocal: true };

  private active = false;
  private closed = false;
  private attempt = 0;
  private racing: AbortController | null = null;
  private raceWaits = false;
  private settling: unknown = null;
  private nextTry: number | null = null;
  private renewAt: number | null = null;
  private renewing = false;
  private timer: unknown = null;
  private reachingFallback: Promise<Candidate | null> | null = null;
  private lostAcks = 0;
  private reissued = false;
  private pathSig: string | null = null;
  private linkRacing = false;
  private currentEnded = false;
  private unwatch: (() => void) | null = null;

  constructor(
    readonly ways: ConnectWays<L>,
    private readonly source: ConnectSource<L>,
    policy: Partial<ConnectPolicy> = {},
    private readonly clock: Clock = browserClock,
  ) {
    this.policy = { ...DEFAULT_POLICY, ...policy, offsets: { ...DEFAULT_POLICY.offsets, ...policy.offsets } };
  }

  get current(): ScreenRoute {
    return this.ways.current;
  }
  get decisionWaitMs(): number {
    return this.policy.decisionWaitMs;
  }
  get openTimeoutMs(): number {
    return this.policy.openTimeoutMs;
  }
  get isDeciding(): boolean {
    if (!((this.racing !== null || this.settling !== null) && this.raceWaits)) return false;
    return isFallbackKind(this.kind) || this.currentEnded || (this.linkRacing && this.kind !== "link");
  }
  private get kind(): CandidateKind {
    return this.ways.currentCandidate.kind;
  }

  // ---------------------------------------------------------------- ScreenRouting

  newVisit(): void {
    this.supported = true;
    this.nextTry = null;
    this.reissued = false;
    this.lostAcks = 0;
  }

  activate(): void {
    if (this.closed) return;
    this.active = true;
    this.startPathWatch();
    this.tryBetter(true);
    this.schedule();
  }

  streamWillOpen(): void {
    this.tryBetter(true);
  }

  leave(): void {
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
      if (fb) this.move(fb);
    }
    this.changed();
  }

  streamFailed(route: ScreenRoute, unauthorized: boolean): void {
    if (route.id !== this.current.id || !this.current.isShortcut) return;
    if (unauthorized) this.unauthorized();
    else this.failed();
  }

  ackAnswered(route: ScreenRoute, status: number | null): void {
    if (route.id !== this.current.id || !this.current.isShortcut) return;
    if (status === 401) return this.unauthorized();
    if (status !== null && status < 500) {
      this.lostAcks = 0;
      this.reissued = false;
      return;
    }
    if (++this.lostAcks >= this.policy.ackFailuresToLeave) this.failed();
  }

  async fallback(route: ScreenRoute, error: unknown): Promise<ScreenRoute | null> {
    if (!route.isShortcut || !this.ways.hasFallback) return null;
    switch (this.policy.classify(error)) {
      case "answer":
        return null;
      case "unauthorized":
        if (route.id === this.current.id) this.unauthorized();
        break;
      case "link":
        if (route.id === this.current.id) this.failed();
        break;
    }
    const fb = await this.reachFallback();
    return fb ? this.ways.route(fb) : null;
  }

  // ---------------------------------------------------------------- the host's

  setShortcutsAllowed(on: boolean): void {
    if (on === this.shortcutsAllowed) return;
    this.shortcutsAllowed = on;
    if (on) {
      this.nextTry = null;
      this.tryBetter(true);
    } else {
      this.cancelRace();
      if (!isFallbackKind(this.kind)) this.demote();
    }
    this.schedule();
    this.changed();
  }

  close(): void {
    this.leave();
    this.closed = true;
    for (const l of this.ways.close()) this.source.release?.(l);
  }

  /** A change of network (the connector's own watch's, or the host's with `watchesPath` off). */
  pathUpdated(next: ConnectPath): void {
    if (!this.active) {
      this.path = next;
      return;
    }
    const first = this.pathSig === null;
    const sig = signature(next);
    if (sig === this.pathSig) return;
    this.pathSig = sig;
    const old = this.path;
    this.path = next;
    const lost = !next.online || (!first && old.hasLocal && !next.hasLocal && this.kind === "lan") || !this.usable(this.ways.currentCandidate);
    if (first && !lost && old.online === next.online && old.hasLocal === next.hasLocal) return;
    this.cancelRace();
    if (lost && this.current.isShortcut) this.demote();
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

  private get bestRankHere(): number | null {
    if (!this.shortcutsAllowed || !this.supported || !this.path.online) return null;
    if (this.linkPossible) return rankOf("link");
    return this.path.hasLocal ? 0 : 1;
  }

  private get canImprove(): boolean {
    const best = this.bestRankHere;
    return best !== null && (this.currentEnded || best < rankOf(this.kind));
  }

  private usable(c: Candidate): boolean {
    if (c.kind === "lan") return this.path.hasLocal;
    if (c.kind === "direct" || c.kind === "link") return this.path.online;
    return true;
  }

  private raceable(cs: Candidate[], anyRank: boolean): Candidate[] {
    const rank = rankOf(this.kind);
    return cs.filter((c) => !isFallbackKind(c.kind) && this.usable(c) && (anyRank || rankOf(c.kind) < rank));
  }

  private tryBetter(wait: boolean, reason: Refresh = "held", anyRank = false): void {
    if (!this.active || this.closed) return;
    const any = anyRank || this.currentEnded;
    if (this.racing) {
      if (wait && !this.raceWaits) {
        this.raceWaits = true;
        this.changed();
      }
      return;
    }
    if (!this.shortcutsAllowed || !this.supported || !this.path.online || !(any || this.canImprove)) return;
    if (this.nextTry !== null && this.clock.now() < this.nextTry) return;
    if (this.settling !== null) this.clock.clearTimeout(this.settling);
    this.settling = null;
    const a = ++this.attempt;
    this.raceWaits = wait;
    const ctrl = new AbortController();
    this.racing = ctrl;
    void this.race(a, reason, any, ctrl.signal);
    this.changed();
  }

  private async race(a: number, first: Refresh, anyRank: boolean, signal: AbortSignal): Promise<void> {
    let reason = first;
    for (let round = 0; round < 2; round++) {
      let supply: Supply | null;
      try {
        supply = await this.source.candidates(reason);
      } catch {
        if (a !== this.attempt) return;
        break;
      }
      if (a !== this.attempt) return;
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
          if (outcome.t === "reached") this.source.release?.(outcome.link);
          return;
        }
        if (outcome.t === "reached") {
          this.take(outcome.candidate, outcome.link, supply);
          break;
        }
        if (interim) break;
      }
      if (!held || round !== 0) break;
      reason = "stale";
    }
    this.racing = null;
    this.raceWaits = false;
    this.linkRacing = false;
    this.nextTry = this.clock.now() + this.policy.retryIntervalMs;
    this.schedule();
    this.changed();
  }

  private async reach(cs: Candidate[], a: number, supply: Supply, signal: AbortSignal): Promise<{ outcome: Outcome<L>; interim: boolean }> {
    const { offsets, linkGraceMs } = this.policy;
    const release = (l: L) => this.source.release?.(l);
    const probe = this.source.probe.bind(this.source);
    const links = cs.filter((c) => c.kind === "link");
    const others = cs.filter((c) => c.kind !== "link");
    if (!links.length) return { outcome: await raceFirst(cs, offsets, probe, release, signal, this.clock), interim: false };
    const started = this.clock.now();
    this.linkRacing = true;
    this.changed();
    try {
      const linkCtrl = new AbortController();
      signal.addEventListener("abort", () => linkCtrl.abort(), { once: true });
      const linkRace = raceFirst(links, offsets, probe, release, linkCtrl.signal, this.clock);
      if (!others.length) return { outcome: await linkRace, interim: false };
      const head = Math.max(Math.min(...others.map((c) => offsets[c.kind] ?? 0)) - (offsets.link ?? 0), 0);
      const done: { o: Outcome<L> | null } = { o: null };
      void linkRace.then((o) => (done.o = o));
      await Promise.race([linkRace, sleep(this.clock, head, signal)]);
      const early = done.o;
      if (early) {
        if (early.t === "reached") return { outcome: early, interim: false };
        return { outcome: await raceFirst(others, offsets, probe, release, signal, this.clock), interim: false };
      }
      const othersRace = raceFirst(others, offsets, probe, release, signal, this.clock);
      const first = await Promise.race([linkRace.then((o) => ({ link: true, o })), othersRace.then((o) => ({ link: false, o }))]);
      if (first.link) {
        if (first.o.t !== "reached") return { outcome: await othersRace, interim: false };
        void othersRace.then((o) => o.t === "reached" && release(o.link));
        return { outcome: first.o, interim: false };
      }
      if (first.o.t !== "reached") return { outcome: await linkRace, interim: false };
      if (a !== this.attempt || !this.active) return { outcome: first.o, interim: false };
      this.take(first.o.candidate, first.o.link, supply);
      const left = started + linkGraceMs - this.clock.now();
      await Promise.race([linkRace, sleep(this.clock, left, signal)]);
      const late = done.o;
      if (late?.t === "reached") return { outcome: late, interim: false };
      linkCtrl.abort();
      return { outcome: { t: "unreachable" }, interim: true };
    } finally {
      this.linkRacing = false;
    }
  }

  private take(c: Candidate, link: L, supply: Supply): void {
    if (!this.shortcutsAllowed || !this.usable(c)) {
      this.source.release?.(link);
      return;
    }
    const old = this.ways.currentCandidate;
    if (sameCandidate(old, c) && !this.currentEnded) {
      this.source.release?.(link);
    } else {
      const put = this.ways.put(c, link, true);
      if (!put) {
        this.source.release?.(link);
        return;
      }
      if (put.replaced !== null) this.retireLink(put.replaced);
      if (old.id !== c.id && !isFallbackKind(old.kind)) this.retire(old.id);
      this.watchEnd(c.id, put.token, link);
    }
    this.currentEnded = false;
    this.lostAcks = 0;
    this.renewAt = supply.expires != null ? this.renewDeadline(supply.expires) : null;
    this.changed();
  }

  private renewDeadline(expires: number): number {
    return this.clock.now() + Math.max(expires - Date.now() - this.policy.renewBeforeMs, this.policy.retryIntervalMs);
  }

  private cancelRace(): void {
    this.attempt++;
    this.racing?.abort();
    this.racing = null;
    if (this.settling !== null) this.clock.clearTimeout(this.settling);
    this.settling = null;
    this.raceWaits = false;
  }

  private watchEnd(id: string, token: number, link: L): void {
    const ended = this.source.ended;
    if (!ended) return;
    void ended.call(this.source, link).then((yes) => yes && this.wayEnded(id, token));
  }

  private wayEnded(id: string, token: number): void {
    if (this.closed || this.ways.token(id) !== token) return;
    if (this.ways.currentCandidate.id === id) {
      this.lostAcks = 0;
      this.renewAt = null;
      const fb = this.ways.heldFallback();
      if (fb) this.move(fb);
      else if (this.ways.hasFallback) this.demote();
      this.currentEnded = this.ways.currentCandidate.id === id;
    }
    const l = this.ways.remove(id, token);
    if (l !== null) this.source.release?.(l);
    this.cancelRace();
    this.nextTry = null;
    this.tryBetter(true);
    this.schedule();
    this.changed();
  }

  // ---------------------------------------------------------------- failures

  private failed(): void {
    if (!this.current.isShortcut) return;
    this.nextTry = this.clock.now() + this.policy.retryIntervalMs;
    this.demote();
    this.schedule();
    this.changed();
  }

  private unauthorized(): void {
    if (!this.current.isShortcut) return;
    if (this.reissued) return this.failed();
    this.reissued = true;
    this.demote();
    this.cancelRace();
    this.nextTry = null;
    this.tryBetter(true, "unauthorized", true);
    this.schedule();
  }

  private demote(): void {
    this.lostAcks = 0;
    this.renewAt = null;
    this.renewing = false;
    if (isFallbackKind(this.kind)) return;
    const fb = this.ways.heldFallback();
    if (fb) return this.move(fb);
    if (!this.ways.fallbacks.length) return;
    const from = this.ways.currentCandidate.id;
    void this.reachFallback().then((f) => {
      if (f && this.ways.currentCandidate.id === from) {
        this.move(f);
        this.schedule();
      }
    });
  }

  private reachFallback(): Promise<Candidate | null> {
    const held = this.ways.heldFallback();
    if (held) return Promise.resolve(held);
    if (this.reachingFallback) return this.reachingFallback;
    if (this.closed || !this.ways.fallbacks.length) return Promise.resolve(null);
    const p = (async () => {
      const o = await raceFirst(this.ways.fallbacks, this.policy.offsets, this.source.probe.bind(this.source), (l) => this.source.release?.(l), new AbortController().signal, this.clock);
      if (o.t !== "reached") return null;
      if (!this.ways.put(o.candidate, o.link, false)) {
        this.source.release?.(o.link);
        return null;
      }
      return o.candidate;
    })();
    this.reachingFallback = p;
    void p.finally(() => {
      if (this.reachingFallback === p) this.reachingFallback = null;
    });
    return p;
  }

  private move(c: Candidate): void {
    const old = this.ways.currentCandidate;
    if (old.id === c.id || !this.ways.setCurrent(c.id)) return;
    this.currentEnded = false;
    if (!isFallbackKind(old.kind)) this.retire(old.id);
    this.changed();
  }

  private retire(id: string): void {
    const token = this.ways.token(id);
    if (token === null) return;
    this.clock.setTimeout(() => {
      const l = this.ways.remove(id, token);
      if (l !== null) this.source.release?.(l);
    }, this.policy.keepRetiredMs);
  }

  private retireLink(link: L): void {
    this.clock.setTimeout(() => this.source.release?.(link), this.policy.keepRetiredMs);
  }

  // ---------------------------------------------------------------- renewal and timers

  private renew(): void {
    const from = this.ways.currentCandidate;
    this.renewing = true;
    void this.source.candidates("renew").then(
      (supply) => this.renewed(from, supply),
      () => this.renewed(from, undefined),
    );
  }

  private renewed(from: Candidate, supply: Supply | null | undefined): void {
    if (!this.renewing) return;
    this.renewing = false;
    if (this.ways.currentCandidate.id !== from.id) return;
    if (supply === undefined) this.renewAt = this.clock.now() + this.policy.retryIntervalMs;
    else if (supply === null) {
      this.supported = false;
      this.demote();
    } else if (supply.candidates.some((c) => sameCandidate(c, from))) {
      this.renewAt = supply.expires != null ? this.renewDeadline(supply.expires) : null;
    } else {
      this.demote();
      this.nextTry = null;
      this.tryBetter(true, "held", true);
    }
    this.schedule();
    this.changed();
  }

  private clearTimer(): void {
    if (this.timer !== null) this.clock.clearTimeout(this.timer);
    this.timer = null;
  }

  private schedule(): void {
    this.clearTimer();
    if (!this.active || this.closed) return;
    let next: number | null = null;
    if (!this.racing && this.settling === null && this.canImprove && this.nextTry !== null) next = this.nextTry;
    if (this.current.isShortcut && !this.renewing && this.renewAt !== null) next = next === null ? this.renewAt : Math.min(next, this.renewAt);
    if (next === null) return;
    this.timer = this.clock.setTimeout(() => {
      this.timer = null;
      this.fire();
    }, Math.max(0, next - this.clock.now()));
  }

  private fire(): void {
    const now = this.clock.now();
    if (this.renewAt !== null && now >= this.renewAt && this.current.isShortcut && !this.renewing) {
      this.renewAt = null;
      this.renew();
    }
    if (this.nextTry !== null && now >= this.nextTry) this.tryBetter(false);
    this.schedule();
  }

  private changed(): void {
    this.onChange?.();
  }

  private startPathWatch(): void {
    if (this.unwatch || !this.watchesPath || typeof window === "undefined") return;
    const update = () => this.pathUpdated(browserPath());
    const conn = (navigator as Navigator & { connection?: EventTarget }).connection;
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
