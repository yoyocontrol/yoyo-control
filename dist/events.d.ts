import type { ScreenEvent } from "@yoyocontrol/screen-ui";
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
export declare class MacEvents {
    private readonly source;
    private readonly unauthorized;
    private readonly sleep;
    private readonly queues;
    private abort;
    constructor(source: EventSource, unauthorized?: () => void, sleep?: (ms: number, signal: AbortSignal) => Promise<void>);
    /** A new subscription; `return()` (a `for await` that ends) unsubscribes, the last one stops the reader. */
    subscribe(): AsyncIterable<ScreenEvent>;
    /** Every subscription ends; the reader stops. */
    close(): void;
    private add;
    private remove;
    private stop;
    private post;
    private run;
    private read;
    private line;
}
