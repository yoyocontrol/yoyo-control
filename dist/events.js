import { eventFromMacLine } from "./mapping.js";
/**
 * The Mac's `/events` (NDJSON, over the link), read while somebody listens, handed to every subscriber as the pages'
 * events. Reconnects 1 s → 10 s after an end or a failure; a 401 calls `unauthorized` and stops.
 */
export class MacEvents {
    source;
    unauthorized;
    sleep;
    queues = new Set();
    abort = null;
    constructor(source, unauthorized = () => { }, sleep = abortableSleep) {
        this.source = source;
        this.unauthorized = unauthorized;
        this.sleep = sleep;
    }
    /** A new subscription; `return()` (a `for await` that ends) unsubscribes, the last one stops the reader. */
    subscribe() {
        const self = this;
        return {
            [Symbol.asyncIterator]() {
                const buffered = [];
                let wake = null;
                let ended = false;
                const q = {
                    push(e) {
                        if (wake) {
                            const w = wake;
                            wake = null;
                            w({ value: e, done: false });
                        }
                        else
                            buffered.push(e);
                    },
                    end() {
                        ended = true;
                        if (wake) {
                            const w = wake;
                            wake = null;
                            w({ value: undefined, done: true });
                        }
                    },
                };
                self.add(q);
                return {
                    next() {
                        const e = buffered.shift();
                        if (e)
                            return Promise.resolve({ value: e, done: false });
                        if (ended)
                            return Promise.resolve({ value: undefined, done: true });
                        return new Promise((resolve) => (wake = resolve));
                    },
                    return() {
                        q.end();
                        self.remove(q);
                        return Promise.resolve({ value: undefined, done: true });
                    },
                };
            },
        };
    }
    /** Every subscription ends; the reader stops. */
    close() {
        for (const q of this.queues)
            q.end();
        this.queues.clear();
        this.stop();
    }
    add(q) {
        this.queues.add(q);
        if (!this.abort) {
            const a = new AbortController();
            this.abort = a;
            void this.run(a.signal);
        }
    }
    remove(q) {
        this.queues.delete(q);
        if (this.queues.size === 0)
            this.stop();
    }
    stop() {
        this.abort?.abort();
        this.abort = null;
    }
    post(e) {
        for (const q of this.queues)
            q.push(e);
    }
    async run(signal) {
        let delay = 1000;
        while (!signal.aborted) {
            try {
                const res = await this.source.open(signal);
                if (res.body) {
                    delay = 1000;
                    await this.read(res.body, signal);
                }
            }
            catch (e) {
                if (signal.aborted)
                    return;
                if (e?.status === 401) {
                    this.unauthorized();
                    return;
                }
            }
            if (signal.aborted)
                return;
            await this.sleep(delay, signal);
            delay = Math.min(delay * 2, 10_000);
        }
    }
    async read(body, signal) {
        const reader = body.getReader();
        const stop = () => void reader.cancel().catch(() => { });
        signal.addEventListener("abort", stop, { once: true });
        const decoder = new TextDecoder();
        let rest = "";
        try {
            for (;;) {
                const { value, done } = await reader.read();
                if (done || signal.aborted)
                    return;
                rest += decoder.decode(value, { stream: true });
                let nl;
                while ((nl = rest.indexOf("\n")) >= 0) {
                    const line = rest.slice(0, nl).trim();
                    rest = rest.slice(nl + 1);
                    if (line)
                        await this.line(line);
                }
            }
        }
        finally {
            signal.removeEventListener("abort", stop);
        }
    }
    async line(text) {
        let json;
        try {
            json = JSON.parse(text);
        }
        catch {
            return;
        }
        const e = eventFromMacLine(json);
        if (!e)
            return;
        // nobody's device holds control any more: an agent may be using the Mac (only /status says)
        if (e.type === "screen.control" && e.controller === "none" && (await this.source.agentActive().catch(() => false))) {
            this.post({ ...e, controller: "agent" });
            return;
        }
        this.post(e);
    }
}
function abortableSleep(ms, signal) {
    return new Promise((resolve) => {
        const t = setTimeout(done, ms);
        function done() {
            clearTimeout(t);
            signal.removeEventListener("abort", done);
            resolve();
        }
        signal.addEventListener("abort", done, { once: true });
    });
}
