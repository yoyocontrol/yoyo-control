// In-memory sliding-window counter of failed logins per IP.
import { isIP } from "node:net";
export class FailureLimiter {
    limit;
    windowMs;
    hits = new Map();
    constructor(limit, windowMs) {
        this.limit = limit;
        this.windowMs = windowMs;
        setInterval(() => this.prune(), windowMs).unref();
    }
    recent(key, now = Date.now()) {
        const list = (this.hits.get(key) ?? []).filter((t) => now - t < this.windowMs);
        if (list.length)
            this.hits.set(key, list);
        else
            this.hits.delete(key);
        return list;
    }
    /** Seconds until the next attempt is allowed, or 0 if not blocked. */
    blockedFor(key) {
        const list = this.recent(key);
        if (list.length < this.limit)
            return 0;
        return Math.max(1, Math.ceil((list[0] + this.windowMs - Date.now()) / 1000));
    }
    fail(key) {
        const list = this.recent(key);
        list.push(Date.now());
        this.hits.set(key, list);
    }
    prune() {
        for (const k of [...this.hits.keys()])
            this.recent(k);
    }
}
/**
 * The bucket an address counts in: an IPv4 address as it is, an IPv6 one by its /64 (one home, one phone network's
 * customer, gets a whole /64: counting each address apart would give one client millions of budgets). An IPv4 address
 * written as IPv6 (`::ffff:a.b.c.d`) is that IPv4 address. Anything else (`link:relay:…`, "unknown") as it is.
 */
export function ipBucket(ip) {
    const bare = ip.replace(/%.*$/, "");
    if (isIP(bare) !== 6)
        return ip;
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(bare);
    if (mapped)
        return mapped[1];
    const [head = "", tail = ""] = bare.split("::");
    const left = head ? head.split(":") : [];
    const right = bare.includes("::") ? (tail ? tail.split(":") : []) : [];
    // (a dotted IPv4 tail only appears in the last 32 bits: beyond the /64 that counts)
    const groups = bare.includes("::") ? [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right] : left;
    return `${groups.slice(0, 4).map((g) => (parseInt(g, 16) || 0).toString(16)).join(":")}::/64`;
}
/**
 * A token bucket per key: `burst` at once, then one more every `everyMs` (so `60_000 / everyMs` a minute). An unused
 * key is forgotten once full again.
 */
export class TokenBuckets {
    burst;
    everyMs;
    now;
    buckets = new Map();
    constructor(burst, everyMs, now = Date.now) {
        this.burst = burst;
        this.everyMs = everyMs;
        this.now = now;
        setInterval(() => this.prune(), Math.max(everyMs * burst, 1000)).unref();
    }
    level(key, t) {
        const b = this.buckets.get(key) ?? { tokens: this.burst, at: t };
        const tokens = Math.min(this.burst, b.tokens + (t - b.at) / this.everyMs);
        return { tokens, at: t };
    }
    /** Takes one: 0 when there was one, else the seconds until there is. */
    take(key) {
        const t = this.now();
        const b = this.level(key, t);
        if (b.tokens >= 1) {
            this.buckets.set(key, { tokens: b.tokens - 1, at: t });
            return 0;
        }
        this.buckets.set(key, b);
        return Math.max(1, Math.ceil(((1 - b.tokens) * this.everyMs) / 1000));
    }
    prune() {
        const t = this.now();
        for (const k of [...this.buckets.keys()])
            if (this.level(k, t).tokens >= this.burst)
                this.buckets.delete(k);
    }
}
