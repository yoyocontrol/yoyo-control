import type { ScreenEvent } from "@yoyocontrol/screen-ui";
import { eventFromMacLine } from "./mapping.js";

/** What the reader needs: one `/events` request (NDJSON body), and whether automation drives the Mac now. */
export interface EventSource {
  /** `GET /events` on the link; a non-2xx answer is a `RequestError` (401: unpaired). */
  open(signal: AbortSignal): Promise<Response>;
  /** `/status`'s answer to "is an agent using it" (a `control` line with nobody holding it may mean one is). */
  agentActive(): Promise<boolean>;
}

/**
 * The Mac's `/events` (NDJSON, over the link), read while somebody listens, handed to every subscriber as the pages'
 * events. Reconnects 1 s → 10 s after an end or a failure; a 401 calls `unauthorized` and stops.
 */
export class MacEvents {
  private readonly queues = new Set<{ push(e: ScreenEvent): void; end(): void }>();
  private abort: AbortController | null = null;

  constructor(
    private readonly source: EventSource,
    private readonly unauthorized: () => void = () => {},
    private readonly sleep: (ms: number, signal: AbortSignal) => Promise<void> = abortableSleep,
  ) {}

  /** A new subscription; `return()` (a `for await` that ends) unsubscribes, the last one stops the reader. */
  subscribe(): AsyncIterable<ScreenEvent> {
    const self = this;
    return {
      [Symbol.asyncIterator]() {
        const buffered: ScreenEvent[] = [];
        let wake: ((r: IteratorResult<ScreenEvent>) => void) | null = null;
        let ended = false;
        const q = {
          push(e: ScreenEvent) {
            if (wake) {
              const w = wake;
              wake = null;
              w({ value: e, done: false });
            } else buffered.push(e);
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
          next(): Promise<IteratorResult<ScreenEvent>> {
            const e = buffered.shift();
            if (e) return Promise.resolve({ value: e, done: false });
            if (ended) return Promise.resolve({ value: undefined, done: true });
            return new Promise((resolve) => (wake = resolve));
          },
          return(): Promise<IteratorResult<ScreenEvent>> {
            q.end();
            self.remove(q);
            return Promise.resolve({ value: undefined, done: true });
          },
        };
      },
    };
  }

  /** Every subscription ends; the reader stops. */
  close(): void {
    for (const q of this.queues) q.end();
    this.queues.clear();
    this.stop();
  }

  private add(q: { push(e: ScreenEvent): void; end(): void }): void {
    this.queues.add(q);
    if (!this.abort) {
      const a = new AbortController();
      this.abort = a;
      void this.run(a.signal);
    }
  }

  private remove(q: { push(e: ScreenEvent): void; end(): void }): void {
    this.queues.delete(q);
    if (this.queues.size === 0) this.stop();
  }

  private stop(): void {
    this.abort?.abort();
    this.abort = null;
  }

  private post(e: ScreenEvent): void {
    for (const q of this.queues) q.push(e);
  }

  private async run(signal: AbortSignal): Promise<void> {
    let delay = 1000;
    while (!signal.aborted) {
      try {
        const res = await this.source.open(signal);
        if (res.body) {
          delay = 1000;
          await this.read(res.body, signal);
        }
      } catch (e) {
        if (signal.aborted) return;
        if ((e as { status?: unknown })?.status === 401) {
          this.unauthorized();
          return;
        }
      }
      if (signal.aborted) return;
      await this.sleep(delay, signal);
      delay = Math.min(delay * 2, 10_000);
    }
  }

  private async read(body: ReadableStream<Uint8Array>, signal: AbortSignal): Promise<void> {
    const reader = body.getReader();
    const stop = () => void reader.cancel().catch(() => {});
    signal.addEventListener("abort", stop, { once: true });
    const decoder = new TextDecoder();
    let rest = "";
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done || signal.aborted) return;
        rest += decoder.decode(value, { stream: true });
        let nl: number;
        while ((nl = rest.indexOf("\n")) >= 0) {
          const line = rest.slice(0, nl).trim();
          rest = rest.slice(nl + 1);
          if (line) await this.line(line);
        }
      }
    } finally {
      signal.removeEventListener("abort", stop);
    }
  }

  private async line(text: string): Promise<void> {
    let json: Record<string, unknown>;
    try {
      json = JSON.parse(text) as Record<string, unknown>;
    } catch {
      return;
    }
    const e = eventFromMacLine(json);
    if (!e) return;
    // nobody's device holds control any more: an agent may be using the Mac (only /status says)
    if (e.type === "screen.control" && e.controller === "none" && (await this.source.agentActive().catch(() => false))) {
      this.post({ ...e, controller: "agent" });
      return;
    }
    this.post(e);
  }
}

function abortableSleep(ms: number, signal: AbortSignal): Promise<void> {
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
