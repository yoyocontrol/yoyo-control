export declare class FailureLimiter {
    private readonly limit;
    private readonly windowMs;
    private hits;
    constructor(limit: number, windowMs: number);
    private recent;
    /** Seconds until the next attempt is allowed, or 0 if not blocked. */
    blockedFor(key: string): number;
    fail(key: string): void;
    private prune;
}
/**
 * The bucket an address counts in: an IPv4 address as it is, an IPv6 one by its /64 (one home, one phone network's
 * customer, gets a whole /64: counting each address apart would give one client millions of budgets). An IPv4 address
 * written as IPv6 (`::ffff:a.b.c.d`) is that IPv4 address. Anything else (`link:relay:…`, "unknown") as it is.
 */
export declare function ipBucket(ip: string): string;
/**
 * A token bucket per key: `burst` at once, then one more every `everyMs` (so `60_000 / everyMs` a minute). An unused
 * key is forgotten once full again.
 */
export declare class TokenBuckets {
    private readonly burst;
    private readonly everyMs;
    private readonly now;
    private buckets;
    constructor(burst: number, everyMs: number, now?: () => number);
    private level;
    /** Takes one: 0 when there was one, else the seconds until there is. */
    take(key: string): number;
    private prune;
}
