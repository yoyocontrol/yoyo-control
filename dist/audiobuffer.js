import { percentile } from "./playout.js";
/** The floors by route. */
export const AUDIO_LAN_FLOOR_MS = 80;
export const AUDIO_REMOTE_FLOOR_MS = 120;
export function audioJitterConfig(lan, over = {}) {
    const floorMs = lan ? AUDIO_LAN_FLOOR_MS : AUDIO_REMOTE_FLOOR_MS;
    return {
        windowMs: 10_000,
        minSamples: 10,
        startDepthMs: Math.max(floorMs, 60),
        marginMs: 20,
        floorMs,
        maxDepthMs: 400,
        percentile: 0.99,
        bumpStepMs: 40,
        bumpMaxMs: 240,
        bumpDecayMs: 10,
        bumpDecayEveryMs: 15_000,
        leadMs: 10,
        syncRateMsPerSec: 20,
        clockStepMs: 500,
        clockStepHoldMs: 1000,
        ...over,
    };
}
export class AudioJitter {
    config;
    /** The smallest recent delay (null until the first packet). */
    base = null;
    /** The buffer's own need (ms: jitter + margin within floor + bump … max). */
    need;
    /** The adaptive floor's bump (ms). */
    bump = 0;
    /** The p99 of the window's delays above the base (null until `minSamples`). */
    jitter = null;
    /** The A/V sync depth in use (ms; null: none). */
    sync = null;
    resets = 0;
    samples = [];
    seen = 0;
    highSince = null;
    lastBumpAt = null;
    syncGoal = null;
    syncAt = null;
    constructor(config = audioJitterConfig(false)) {
        this.config = config;
        this.need = config.startDepthMs;
    }
    get floor() {
        return this.config.floorMs + this.bump;
    }
    /** A packet's delay (arrival − macTime) at `arrival`. */
    observe(delay, arrival) {
        const c = this.config;
        this.decayBump(arrival);
        if (this.base !== null) {
            if (delay < this.base - c.clockStepMs)
                this.restart();
            else if (delay > this.base + c.clockStepMs) {
                this.highSince ??= arrival;
                if (arrival - this.highSince < c.clockStepHoldMs)
                    return;
                this.restart();
            }
            else
                this.highSince = null;
        }
        this.samples.push({ at: arrival, delay });
        this.seen++;
        while (this.samples.length > c.minSamples && arrival - this.samples[0].at > c.windowMs)
            this.samples.shift();
        let base = Infinity;
        for (const s of this.samples)
            base = Math.min(base, s.delay);
        this.base = base;
        if (this.seen < c.minSamples) {
            this.need = Math.max(c.startDepthMs, this.floor);
            return;
        }
        this.jitter = percentile(this.samples.map((s) => s.delay - base), c.percentile) ?? 0;
        this.need = Math.min(Math.max(this.jitter + c.marginMs, this.floor), Math.max(c.maxDepthMs, this.floor));
    }
    /** Playback was interrupted (an underrun): the floor goes up. */
    interruption(now) {
        this.bump = Math.min(this.bump + this.config.bumpStepMs, this.config.bumpMaxMs);
        this.lastBumpAt = now;
        this.need = Math.max(this.need, this.floor);
    }
    /** The A/V sync's delay goal (ms; null: none) — the depth giving it is `syncDepthFor`. */
    setSyncGoal(depthMs) {
        this.syncGoal = depthMs;
    }
    /** The depth now (ms, from the slot's macTime + base): need + output latency + lead, or the sync depth when more. */
    depth(now, outputLatencyMs) {
        const own = this.need + outputLatencyMs + this.config.leadMs;
        const goal = this.syncGoal;
        const dt = this.syncAt === null ? 0 : Math.max(now - this.syncAt, 0);
        this.syncAt = now;
        const step = (this.config.syncRateMsPerSec / 1000) * dt;
        if (goal === null || goal <= own) {
            // back to its own depth, at the same pace
            if (this.sync !== null)
                this.sync = this.sync - step <= own ? null : this.sync - step;
        }
        else {
            const from = this.sync ?? own;
            this.sync = goal > from ? Math.min(goal, from + step) : Math.max(goal, from - step);
        }
        return this.sync !== null ? Math.max(this.sync, own) : own;
    }
    decayBump(now) {
        if (this.bump <= 0 || this.lastBumpAt === null)
            return;
        const every = this.config.bumpDecayEveryMs;
        const steps = Math.floor((now - this.lastBumpAt) / every);
        if (steps <= 0)
            return;
        this.bump = Math.max(this.bump - steps * this.config.bumpDecayMs, 0);
        this.lastBumpAt += steps * every;
    }
    restart() {
        this.samples = [];
        this.seen = 0;
        this.base = null;
        this.jitter = null;
        this.highSince = null;
        this.need = Math.max(this.config.startDepthMs, this.floor);
        this.resets++;
    }
}
export function audioSchedulerConfig(rate = 48_000, packetFrames = 960) {
    const f = (ms) => Math.round((ms * rate) / 1000);
    return {
        rate,
        packetFrames,
        lateFrames: f(10),
        fadeFrames: f(5),
        maxConcealed: 25,
        excessFrames: f(20),
        excessHoldFrames: f(1000),
        cutFrames: f(10),
        crossfadeFrames: f(2.5),
        cutEveryFrames: f(250),
        maxQueuedFrames: f(1000),
    };
}
/**
 * The audio thread's half (see above). Self-contained on purpose — no imports, no module constants: its source is put
 * into the page's AudioWorklet as is (`AudioScheduler.toString()`).
 */
export class AudioScheduler {
    config;
    queue = [];
    pos = 0;
    playing = false;
    expectedSeq = null;
    concealLeft = 0;
    fadeIn = 0;
    /** The head packet's boundary was handled (its gap concealed, the cut decided). */
    entered = false;
    lagFrom = null;
    lastCut = -Infinity;
    cut = null;
    stats = { playing: false, playingMacTime: null, bufferedFrames: 0, underruns: 0, late: 0, overflow: 0, concealed: 0, cuts: 0, cutFrames: 0 };
    constructor(config) {
        this.config = config;
    }
    push(p) {
        this.queue.push(p);
        let queued = -this.pos;
        for (const q of this.queue)
            queued += q.l.length;
        if (queued > this.config.maxQueuedFrames) {
            // the output stopped pulling: what waits is stale
            this.queue.shift();
            this.pos = 0;
            this.playing = false;
            this.entered = false;
            this.stats.overflow++;
        }
    }
    /** Fills `l` / `r` (one render quantum) whose first sample is heard at context frame `frame`. */
    render(l, r, frame) {
        const c = this.config;
        for (let i = 0; i < l.length; i++) {
            const f = frame + i;
            if (!this.playing && !this.start(f)) {
                l[i] = 0;
                r[i] = 0;
                continue;
            }
            if (this.concealLeft > 0) {
                this.concealLeft--;
                l[i] = 0;
                r[i] = 0;
                continue;
            }
            let head = this.queue[0];
            if (!head) {
                this.playing = false;
                this.stats.underruns++;
                l[i] = 0;
                r[i] = 0;
                continue;
            }
            if (!this.entered)
                this.atBoundary(f, head);
            head = this.queue[0];
            if (!head || !this.playing) {
                l[i] = 0;
                r[i] = 0;
                continue;
            }
            if (this.concealLeft > 0) {
                this.concealLeft--;
                l[i] = 0;
                r[i] = 0;
                continue;
            }
            let a = head.l[this.pos], b = head.r[this.pos];
            const x = this.cut;
            if (x) {
                const t = 1 - x.left / c.crossfadeFrames;
                const j = this.pos + x.skip;
                a = a * (1 - t) + (head.l[j] ?? 0) * t;
                b = b * (1 - t) + (head.r[j] ?? 0) * t;
                if (--x.left <= 0) {
                    this.pos += x.skip;
                    this.cut = null;
                }
            }
            let gain = 1;
            if (this.fadeIn > 0) {
                gain = 1 - this.fadeIn / c.fadeFrames;
                this.fadeIn--;
            }
            const ahead = this.buffered();
            if (ahead < c.fadeFrames && this.queue.length === 1)
                gain *= ahead / c.fadeFrames;
            l[i] = a * gain;
            r[i] = b * gain;
            this.pos++;
            if (this.pos >= head.l.length) {
                this.queue.shift();
                this.pos = 0;
                this.cut = null;
                this.entered = false;
            }
        }
        this.stats.playing = this.playing;
        const h = this.queue[0];
        this.stats.playingMacTime = this.playing && h && h.macTime !== null ? h.macTime + (this.pos / c.rate) * 1000 : null;
        this.stats.bufferedFrames = this.buffered();
    }
    buffered() {
        let n = this.concealLeft - this.pos;
        for (const q of this.queue)
            n += q.l.length;
        return Math.max(n, 0);
    }
    /** Not playing: drop what is past its slot, start when the head's slot comes. */
    start(f) {
        while (this.queue.length && this.queue[0].at + this.config.lateFrames < f) {
            this.queue.shift();
            this.stats.late++;
        }
        const head = this.queue[0];
        if (!head || f < head.at)
            return false;
        this.playing = true;
        this.pos = Math.min(f - head.at, head.l.length - 1);
        this.expectedSeq = head.seq + 1;
        this.concealLeft = 0;
        this.fadeIn = this.config.fadeFrames;
        this.lagFrom = null;
        this.entered = true;
        return true;
    }
    /** A new packet starts: conceal a seq gap, cut when playback lags its slots. */
    atBoundary(f, head) {
        const c = this.config;
        this.entered = true;
        if (this.expectedSeq !== null && head.seq !== this.expectedSeq) {
            const n = head.seq - this.expectedSeq;
            if (n > 0 && n <= c.maxConcealed) {
                this.concealLeft = n * c.packetFrames;
                this.stats.concealed += n;
            }
            else if (n !== 0) {
                // too much missing (or a new stream): start over from the slots
                this.playing = false;
                this.expectedSeq = null;
                this.start(f);
                return;
            }
        }
        this.expectedSeq = head.seq + 1;
        const lag = f + this.concealLeft - head.at;
        if (lag > c.excessFrames) {
            this.lagFrom ??= f;
            if (f - this.lagFrom >= c.excessHoldFrames && f - this.lastCut >= c.cutEveryFrames && head.l.length > c.cutFrames + c.crossfadeFrames) {
                this.cut = { left: c.crossfadeFrames, skip: c.cutFrames };
                this.lastCut = f;
                this.stats.cuts++;
                this.stats.cutFrames += c.cutFrames;
            }
        }
        else {
            this.lagFrom = null;
        }
    }
}
