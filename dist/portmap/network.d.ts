export interface HttpRequest {
    url: string;
    method: "GET" | "POST";
    headers: Record<string, string>;
    body?: string;
    timeoutMs: number;
}
export interface HttpResponse {
    status: number;
    body: string;
}
export interface UdpTarget {
    host: string;
    port: number;
    payload: Uint8Array;
}
export interface Network {
    /** The IPv4 default gateway, or null when unknown (then only multicast UPnP discovery is tried). */
    gateway(): Promise<string | null>;
    /** This host's IPv4 address on the interface that reaches `towards` (the UPnP `NewInternalClient`, PCP's client address). */
    localAddress(towards: string): Promise<string | null>;
    /**
     * Sends `payload` to `host:port` and waits for one datagram from `host` that `accept` takes, retransmitting after each
     * of `timeoutsMs`. Null when nothing came back.
     */
    udpRequest(host: string, port: number, payload: Uint8Array, timeoutsMs: number[], accept?: (msg: Uint8Array) => boolean): Promise<Uint8Array | null>;
    /**
     * Sends the SSDP searches from one socket and collects the unicast answers for `waitMs` (an implementation may stop
     * early once `preferFrom` has answered).
     */
    ssdpSearch(targets: UdpTarget[], waitMs: number, localAddress: string | null, preferFrom?: string | null): Promise<Array<{
        from: string;
        message: string;
    }>>;
    http(req: HttpRequest): Promise<HttpResponse>;
}
export interface Clock {
    now(): number;
    setTimeout(fn: () => void, ms: number): unknown;
    clearTimeout(handle: unknown): void;
}
export declare const systemClock: Clock;
/** The default gateway from `route -n get default` (macOS / BSD), /proc/net/route (Linux) or `route print` (Windows). */
export declare function systemGateway(platform?: NodeJS.Platform): Promise<string | null>;
/** `route -n get default` → the `gateway:` line when it is an IPv4 address (not `link#N` on a point-to-point VPN). */
export declare function parseRouteGetDefault(out: string): string | null;
/**
 * Windows' `route print -4 0.0.0.0` → the gateway of the lowest-metric active default route. The table's rows are
 * `0.0.0.0  0.0.0.0  <gateway>  <interface>  <metric>` whatever the display language; an on-link row has no address
 * there and is skipped; persistent routes (a later table, no interface column) don't match.
 */
export declare function parseRoutePrint(out: string): string | null;
/** /proc/net/route → the gateway of the lowest-metric default route (little-endian hex). */
export declare function parseProcNetRoute(text: string): string | null;
export declare function nodeNetwork(opts?: {
    platform?: NodeJS.Platform;
}): Network;
