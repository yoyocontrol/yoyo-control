/**
 * Smooth playback with a responsive mode (docs/PROTOCOL.md「客户端的平滑播放」), the same rules as the iOS kit's
 * `ScreenPlayout`: a jitter buffer that shows decoded pictures at an even pace, whose depth drops to about one picture
 * interval while the user interacts. Pure and deterministic: every time is passed in, in ms — host times on the page's
 * clock (`performance.now()`), `macTime` = the part's `X-Frame-Time` (ms since 1970, the server's clock). Acks and
 * decoding never wait for it; only showing does, and only decoded pictures are dropped (every part is decoded as it
 * comes: later pictures reference earlier ones).
 *
 * Each picture's delay = arrival − macTime holds the clock offset plus the network delay. `base` = the smallest delay of
 * the last `windowMs`; the delays above it are the jitter. The depth is their p95 + `marginMs`, within 0…`maxDepthMs`:
 * it grows at once and shrinks by at most `shrinkPerSecondMs` a second (`defaultDepthMs` until `minSamples` were seen).
 * A picture is due at macTime + base + depth + lead (`lead`: one display refresh — the animation frame draws for the
 * refresh after it). Each refresh shows the newest due picture (older ones are dropped); at most `maxQueue` wait. A
 * picture later than any depth could absorb (by more than `maxDepthMs` + a picture interval) is shown at once and left
 * out of the estimate; a delay `clockStepMs` below the base, or that far above it for `clockStepHoldMs`, starts the
 * estimate over. Without a macTime a picture shows at once; refine / keepalive pictures (`sample: false`) are due on
 * arrival and not sampled.
 *
 * Even pace (`evenPace`): a picture at most every `pace` refreshes, the largest n ≥ 1 with n × refresh ≤ content
 * interval + 0.15 × refresh (never slower than the content), changed once a new value held `paceHoldMs`, with a band of
 * `paceSlower` / `paceFaster` refreshes around the pace in use.
 *
 * Interactive (`interactive`: a finger on the picture, keys, the wheel — `Interactivity`): the depth drops to the
 * interactive depth = min(depth, `touchBudgetMs`, `interactiveCapMs`, picture interval + `marginMs`) and even pace is
 * off: a sampled picture is due at min(macTime + base + that, arrival + that) + lead; a later one (or a stall) shows on
 * the next refresh. Without a touch budget (the LAN), or an interactive depth under `minTouchBudgetMs`, pictures show on
 * arrival. Turned on, what waits is re-timed at once, so the next refresh shows the newest due picture and drops the
 * older ones (the queue catches up in one refresh). Turned off, the depth in use starts at the interactive depth and
 * rises to the smooth depth by at most `rampPerSecondMs` a second: each picture is held a little longer than the one
 * before, never a sudden freeze.
 *
 * A/V sync (`syncFloor`, `AVSync`): while watching, smooth pictures wait this much longer for the computer's sound (a
 * Bluetooth output's latency, a deeper sound buffer); the extra wait in use moves to it by at most `rampPerSecondMs`
 * either way, is 0 at once when interactive starts, and room is made in the queue for the pictures it holds.
 */
export const DEFAULT_PLAYOUT = {
    windowMs: 3000,
    minSamples: 10,
    defaultDepthMs: 25,
    marginMs: 4,
    maxDepthMs: 100,
    shrinkPerSecondMs: 10,
    percentile: 0.95,
    maxQueue: 12,
    clockStepMs: 500,
    clockStepHoldMs: 1000,
    paceHoldMs: 1000,
    paceSlower: 0.12,
    paceFaster: 0.12,
    rampPerSecondMs: 100,
    minTouchBudgetMs: 8,
    interactiveCapMs: 30,
};
/** The cap off the local network (on 5G the jitter's p95 runs past 100 ms). */
export const REMOTE_MAX_DEPTH_MS = 200;
/** The depth before anything was measured, on the local network. */
export const LAN_DEFAULT_DEPTH_MS = 10;
/** A config with another cap, and room in the queue for that much at 60 fps (as 12 is for 100 ms). */
export function playoutConfig(over = {}) {
    const { capMs, ...rest } = over;
    const c = { ...DEFAULT_PLAYOUT, ...rest };
    if (capMs !== undefined && capMs > 0) {
        c.maxDepthMs = capMs;
        c.maxQueue = Math.ceil((capMs * 60) / 1000) + 6;
    }
    c.defaultDepthMs = Math.min(c.defaultDepthMs, c.maxDepthMs);
    return c;
}
/** Nearest-rank percentile (`p` in 0…1); undefined for no values. */
export function percentile(values, p) {
    if (values.length === 0)
        return undefined;
    const s = [...values].sort((a, b) => a - b);
    const rank = Math.ceil(p * s.length) - 1;
    return s[Math.min(Math.max(rank, 0), s.length - 1)];
}
/** The largest n ≥ 1 with n × refresh ≤ the content interval + 0.15 × refresh: never slower than the content. */
export function paceFor(contentMs, refreshMs) {
    if (!(refreshMs > 0))
        return 1;
    return Math.max(1, Math.floor((contentMs + 0.15 * refreshMs) / refreshMs));
}
/** The pace to move to from `current` (hysteresis, see above). */
export function paceFrom(contentMs, refreshMs, current, slower = 0.12, faster = 0.12) {
    if (!(refreshMs > 0))
        return 1;
    const lenient = paceFor(contentMs + faster * refreshMs, refreshMs);
    if (lenient < current)
        return lenient;
    const strict = paceFor(contentMs - slower * refreshMs, refreshMs);
    if (strict > current)
        return strict;
    return current;
}
/**
 * The automatic touch budget (one bound of the interactive depth, ms; null: on arrival): a quarter of the path's
 * minimum round trip (the latest ack answer's `net.rttMs.min`), at most 45 ms; without one, none on the LAN and 30 ms
 * elsewhere. Under 8 ms: none.
 */
export function touchBudgetMs(rttMinMs, onLan) {
    let budget;
    if (typeof rttMinMs === "number" && Number.isFinite(rttMinMs) && rttMinMs >= 0)
        budget = Math.min(0.25 * rttMinMs, 45);
    else if (onLan)
        return null;
    else
        budget = 30;
    return budget < 8 ? null : budget;
}
/** The most the A/V sync makes smooth pictures wait (ms). */
export const MAX_SYNC_FLOOR_MS = 300;
export class Playout {
    discard;
    config;
    /** The buffer's depth (ms). */
    depth;
    /** The smallest recent delay (null until the first sample). */
    base = null;
    /** Pictures dropped (never shown), in all. */
    dropped = 0;
    /** Clock steps seen. */
    resets = 0;
    /** The usual gap between the server's pictures (median of the window's, 1000/120…100 ms). */
    frameInterval = 1000 / 30;
    /** The content's pictures per second as an interval (mean gap up to 100 ms). */
    contentInterval = 1000 / 30;
    /** Even pace: refreshes per shown picture. */
    pace = 1;
    /** The p95 of the window's delays above the base (null until `minSamples`). */
    jitter = null;
    /** The display's refresh period (ms; the page measures it from its animation frames). */
    lead = 1000 / 60;
    /** The most an interactive picture waits for its time (ms; null: on arrival). */
    touchBudget = null;
    evenPaceOn = false;
    interactiveOn = false;
    paceCandidate = null;
    nextShowAt = null;
    samples = [];
    seen = 0;
    depthAt = null;
    highSince = null;
    queue = [];
    ramp = null;
    syncFloorMs = 0;
    syncLevel = 0;
    syncAt = null;
    /** `discard`: called for each picture let go without being shown (a VideoFrame to close). */
    constructor(config = {}, discard = () => { }) {
        this.discard = discard;
        this.config = { ...DEFAULT_PLAYOUT, ...config };
        this.depth = this.config.defaultDepthMs;
    }
    get queued() {
        return this.queue.length;
    }
    get evenPace() {
        return this.evenPaceOn;
    }
    /** Show at most one picture every `pace` refreshes; turned on mid-stream it takes the content's pace at once. */
    set evenPace(on) {
        if (on === this.evenPaceOn)
            return;
        this.evenPaceOn = on;
        this.paceCandidate = null;
        this.nextShowAt = null;
        this.pace = on && this.seen >= this.config.minSamples ? paceFor(this.contentInterval, this.lead) : 1;
    }
    get interactive() {
        return this.interactiveOn;
    }
    /** The A/V sync's extra wait for smooth pictures (ms, 0…MAX_SYNC_FLOOR_MS; see above). */
    get syncFloor() {
        return this.syncFloorMs;
    }
    set syncFloor(ms) {
        this.syncFloorMs = ms >= 0 && ms <= MAX_SYNC_FLOOR_MS ? ms : ms > 0 ? MAX_SYNC_FLOOR_MS : 0;
    }
    /** The sync wait in use now (0 while interactive). */
    get syncHold() {
        return this.interactiveOn ? 0 : this.syncLevel;
    }
    syncDepth(t) {
        const dt = this.syncAt === null ? 0 : Math.max(t - this.syncAt, 0);
        this.syncAt = Math.max(t, this.syncAt ?? t);
        const step = (this.config.rampPerSecondMs / 1000) * dt;
        const f = this.syncFloorMs;
        this.syncLevel = f > this.syncLevel ? Math.min(f, this.syncLevel + step) : Math.max(f, this.syncLevel - step);
        return this.syncLevel;
    }
    /** The user interacts (see above): the depth drops to the interactive depth, and what waits catches up at once. */
    set interactive(on) {
        if (on === this.interactiveOn)
            return;
        this.interactiveOn = on;
        this.nextShowAt = null;
        this.paceCandidate = null;
        if (on) {
            this.ramp = null;
            this.syncLevel = 0;
            this.syncAt = null;
            const touch = this.interactiveDepth;
            for (const w of this.queue) {
                if (touch !== null && this.base !== null && w.macTime !== null) {
                    w.due = Math.min(w.due, this.touchDue(w.macTime, w.arrival, this.base, touch));
                }
                else {
                    w.due = Math.min(w.due, w.arrival);
                }
            }
        }
        else {
            const from = this.touchDepth;
            this.ramp = from < this.depth ? { level: from, at: null } : null;
        }
    }
    /** The interactive depth (ms; null: shown on arrival). */
    get interactiveDepth() {
        const b = this.touchBudget;
        if (b === null || !Number.isFinite(b) || b < this.config.minTouchBudgetMs)
            return null;
        const d = Math.min(this.depth, b, this.config.interactiveCapMs, this.frameInterval + this.config.marginMs);
        return d >= this.config.minTouchBudgetMs ? d : null;
    }
    /** The interactive depth in use now (null: not interactive, or on arrival). */
    get touchBuffer() {
        return this.interactiveOn ? this.interactiveDepth : null;
    }
    get touchDepth() {
        return this.interactiveDepth ?? 0;
    }
    touchDue(macTime, arrival, base, depth) {
        return Math.min(macTime + base + depth, arrival + depth) + this.lead;
    }
    /** Even pace: how far apart shown pictures are (null: off, or interactive). */
    get paceInterval() {
        return this.evenPaceOn && !this.interactiveOn ? this.pace * this.lead : null;
    }
    /** How long an on-time picture waits (ms): depth + sync wait + lead; interactive: its depth + lead (0 on arrival); back from it,
     *  the ramp's depth + lead. */
    get hold() {
        if (this.interactiveOn) {
            const d = this.interactiveDepth;
            return d === null ? 0 : d + this.lead;
        }
        return Math.min(this.ramp?.level ?? this.depth, this.depth) + this.syncLevel + this.lead;
    }
    smoothDepth(t) {
        const r = this.ramp;
        if (!r)
            return this.depth;
        if (r.at !== null)
            r.level += (this.config.rampPerSecondMs / 1000) * Math.max(t - r.at, 0);
        r.at = Math.max(t, r.at ?? t);
        if (r.level >= this.depth) {
            this.ramp = null;
            return this.depth;
        }
        return r.level;
    }
    /** A decoded picture. `macTime`: its `X-Frame-Time` (ms; null: none). `sample`: false for refine / keepalive. */
    push(picture, macTime, sample, arrival) {
        if (macTime === null || macTime === undefined || !Number.isFinite(macTime)) {
            this.dropAll();
            return "now";
        }
        if (this.interactiveOn) {
            const onTime = sample && this.observe(arrival - macTime, macTime, arrival);
            const touch = this.interactiveDepth;
            if (touch === null) {
                this.dropAll();
                return "now";
            }
            let due = arrival;
            if (onTime && this.base !== null)
                due = this.touchDue(macTime, arrival, this.base, touch);
            return this.enqueue(picture, due, sample ? macTime : null, arrival);
        }
        let due = arrival;
        if (sample && this.observe(arrival - macTime, macTime, arrival) && this.base !== null) {
            const sync = this.syncDepth(arrival);
            due = Math.min(macTime + this.base + this.smoothDepth(arrival) + sync, arrival + this.config.maxDepthMs + sync) + this.lead;
        }
        return this.enqueue(picture, due, sample ? macTime : null, arrival);
    }
    enqueue(picture, due, macTime, arrival) {
        this.queue.push({ picture, due, macTime, arrival });
        // the sync wait holds more pictures
        const limit = this.config.maxQueue + (this.interactiveOn ? 0 : Math.ceil(this.syncLevel / Math.max(this.frameInterval, 1000 / 120)));
        if (this.queue.length > limit) {
            for (const w of this.queue.splice(0, this.queue.length - limit))
                this.discard(w.picture);
            this.dropped += 1;
        }
        return "queued";
    }
    dropAll() {
        this.dropped += this.queue.length;
        for (const w of this.queue)
            this.discard(w.picture);
        this.queue = [];
    }
    /** The picture for a display refresh that appears at `target`: the newest one due by then (older ones are dropped);
     *  null = keep what's shown. */
    next(target) {
        if (this.evenPaceOn) {
            this.updatePace(target);
            if (!this.interactiveOn && this.pace > 1 && this.nextShowAt !== null && target < this.nextShowAt - this.lead / 2)
                return null;
        }
        let i = -1;
        for (let k = this.queue.length - 1; k >= 0; k--) {
            if (this.queue[k].due <= target) {
                i = k;
                break;
            }
        }
        if (i < 0)
            return null;
        const picture = this.queue[i].picture;
        for (const w of this.queue.slice(0, i))
            this.discard(w.picture);
        this.dropped += i;
        this.queue.splice(0, i + 1);
        this.nextShowAt = target + this.pace * this.lead;
        return picture;
    }
    /** Keeps only the newest `keep` waiting pictures (the decoder is short of buffers); the rest count as dropped. */
    trim(keep) {
        const n = this.queue.length - Math.max(keep, 0);
        if (n <= 0)
            return;
        for (const w of this.queue.splice(0, n))
            this.discard(w.picture);
        this.dropped += n;
    }
    /** Lets go of what waits (the stream ended); not counted as dropped. */
    flush() {
        for (const w of this.queue)
            this.discard(w.picture);
        this.queue = [];
    }
    updatePace(now) {
        const n = paceFrom(this.contentInterval, this.lead, this.pace, this.config.paceSlower, this.config.paceFaster);
        if (n === this.pace) {
            this.paceCandidate = null;
            return;
        }
        const c = this.paceCandidate;
        if (c && c.n === n) {
            if (now - c.since >= this.config.paceHoldMs) {
                this.pace = n;
                this.paceCandidate = null;
            }
        }
        else {
            this.paceCandidate = { n, since: now };
        }
    }
    /** One delay into the estimate; false = too late for any depth (show it on arrival). */
    observe(delay, macTime, arrival) {
        const c = this.config;
        if (this.base !== null) {
            if (delay < this.base - c.clockStepMs) {
                this.restart();
            }
            else if (delay > this.base + c.clockStepMs || delay - this.base - this.depth > c.maxDepthMs + this.frameInterval) {
                const since = this.highSince ?? arrival;
                this.highSince = since;
                if (arrival - since < c.clockStepHoldMs)
                    return false;
                this.restart();
            }
            else {
                this.highSince = null;
            }
        }
        this.samples.push({ arrival, delay, macTime });
        this.seen++;
        while (this.samples.length > c.minSamples && arrival - this.samples[0].arrival > c.windowMs)
            this.samples.shift();
        const base = Math.min(...this.samples.map((s) => s.delay));
        this.base = base;
        const gaps = [];
        for (let k = 1; k < this.samples.length; k++) {
            const g = this.samples[k].macTime - this.samples[k - 1].macTime;
            if (g > 0)
                gaps.push(g);
        }
        const median = percentile(gaps, 0.5);
        if (median !== undefined)
            this.frameInterval = Math.min(Math.max(median, 1000 / 120), 100);
        const moving = gaps.filter((g) => g <= 100);
        if (moving.length)
            this.contentInterval = Math.min(Math.max(moving.reduce((a, b) => a + b, 0) / moving.length, 1000 / 120), 100);
        if (this.seen < c.minSamples) {
            this.depth = c.defaultDepthMs;
            this.depthAt = arrival;
            return true;
        }
        const jitter = percentile(this.samples.map((s) => s.delay - base), c.percentile) ?? 0;
        this.jitter = jitter;
        const target = Math.min(Math.max(jitter + c.marginMs, 0), c.maxDepthMs);
        if (target >= this.depth) {
            this.depth = target;
        }
        else {
            const elapsed = Math.max(arrival - (this.depthAt ?? arrival), 0);
            this.depth = Math.max(target, this.depth - (c.shrinkPerSecondMs / 1000) * elapsed);
        }
        this.depthAt = arrival;
        return true;
    }
    restart() {
        this.samples = [];
        this.seen = 0;
        this.base = null;
        this.depth = this.config.defaultDepthMs;
        this.depthAt = null;
        this.highSince = null;
        this.jitter = null;
        this.ramp = null;
        this.resets++;
    }
}
/** `smooth · buf 104 ms · depth 96 · jit 92 · cap 200` / `responsive · buf 29 ms · touch 21 ms · depth 96 · jit 92 ·
 *  cap 200` (numbers and units only: not localized). */
export function playoutLine(s) {
    const parts = [s.mode];
    if (s.refreshHz !== null)
        parts.push(`${Math.round(s.refreshHz)} Hz`);
    if (s.paceMs !== null)
        parts.push(`pace ${Math.round(s.paceMs)}`);
    parts.push(`buf ${Math.round(s.holdMs)} ms`);
    if (s.touchMs !== null)
        parts.push(`touch ${Math.round(s.touchMs)} ms`);
    parts.push(`depth ${Math.round(s.depthMs)}`);
    if (s.jitterMs !== null)
        parts.push(`jit ${Math.round(s.jitterMs)}`);
    parts.push(`cap ${Math.round(s.capMs)}`);
    return parts.join(" · ");
}
