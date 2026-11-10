import { type AddressClass } from "./address.js";
import { type Protocol } from "./natpmp.js";
import { type Clock, type Network } from "./network.js";
import { type WanService } from "./upnp.js";
export type Method = "pcp" | "natpmp" | "upnp";
export declare const DEFAULT_METHODS: readonly Method[];
export declare const DEFAULT_LIFETIME_S = 7200;
/** How often a permanent UPnP mapping (a router that only does lease 0) is re-added: survives router reboots. */
export declare const PERMANENT_REFRESH_S = 1200;
export type PortMapState = {
    status: "idle";
} | {
    status: "probing";
} | {
    status: "mapped";
    method: Method;
    protocol: Protocol;
    externalAddress: string;
    externalPort: number;
    internalAddress: string;
    internalPort: number;
    /** seconds the router granted; 0 = permanent (UPnP only, refreshed every PERMANENT_REFRESH_S) */
    lifetime: number;
    since: number;
}
/** The router maps, but its external address isn't public (another NAT in front: CGNAT, a second router). */
 | {
    status: "unreachable";
    method: Method;
    externalAddress: string;
    reason: Exclude<AddressClass, "public"> | "unknown";
    since: number;
}
/** Nothing on the network speaks PCP, NAT-PMP or UPnP IGD. */
 | {
    status: "unsupported";
    since: number;
}
/** A router answered but refused (UPnP switched to read-only, no free entries, …). */
 | {
    status: "failed";
    method?: Method;
    error: string;
    since: number;
};
export interface PortMappingOptions {
    internalPort: number;
    protocol?: Protocol;
    /** The external port to ask for (default: internalPort). Persist `state.externalPort` and pass it back for a stable address. */
    externalPort?: number;
    /** UPnP's NewPortMappingDescription (what the router's page lists) */
    description?: string;
    /** Requested lease, seconds (default 7200). */
    lifetime?: number;
    methods?: readonly Method[];
    network?: Network;
    clock?: Clock;
    random?: () => number;
    /** How many other external ports to try when the preferred one is taken (default 6). */
    portAttempts?: number;
    onChange?: (state: PortMapState) => void;
    log?: (line: string) => void;
}
export declare class PortMapping {
    readonly protocol: Protocol;
    readonly internalPort: number;
    private preferredPort;
    private readonly description;
    private readonly lifetime;
    private readonly methods;
    private readonly net;
    private readonly clock;
    private readonly random;
    private readonly portAttempts;
    private readonly onChange?;
    private readonly log;
    private _state;
    private cur;
    private nonce;
    private services;
    private discovery;
    private timer;
    private queue;
    private running;
    private failures;
    constructor(opts: PortMappingOptions);
    get state(): PortMapState;
    /** Starts mapping (and keeps it alive until stop()); resolves with the first outcome. */
    start(): Promise<PortMapState>;
    /** Maps again now: after a network change (the caller watches the network), or to retry sooner. */
    refresh(): Promise<PortMapState>;
    /** Deletes the mapping on the router and stops renewing. Safe to call more than once. */
    stop(): Promise<void>;
    private enqueue;
    private cancelTimer;
    private schedule;
    private setState;
    private attempt;
    private tryMethod;
    private reachability;
    private pcp;
    private tryPcp;
    private tryPmp;
    private tryUpnp;
    /** AddPortMapping on the preferred port, then on others while the router says it's taken. */
    private upnpMap;
    /** Deletes what we hold (best effort, each method's own way). */
    private release;
}
/** Creates a PortMapping and starts it. */
export declare function mapPort(opts: PortMappingOptions): Promise<PortMapping>;
export interface ProbeResult {
    gateway: string | null;
    internalAddress: string | null;
    pcp: {
        epoch: number;
    } | null;
    natpmp: {
        externalAddress: string;
        epoch: number;
    } | null;
    upnp: {
        services: WanService[];
        externalAddress: string | null;
    } | null;
}
/** What the network offers, without mapping anything (diagnostics). */
export declare function probe(opts?: {
    network?: Network;
}): Promise<ProbeResult>;
