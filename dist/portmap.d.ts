import type { Network } from "./portmap/index.js";
/** Where the router should forward to, when it isn't this host as the mapper sees it. */
export interface NetworkOverrides {
    /** The address the router forwards to (default: this host's on the way to the gateway; a container: its host's LAN address). */
    internalClient?: string;
    /** The router (default: the default gateway). */
    gateway?: string;
    /** The router's UPnP device description URL, for when its SSDP answers can't come back (a container behind NAT). */
    upnpLocation?: string;
}
/**
 * The mapper's network with the caller's overrides: the gateway, the internal client (the address the router forwards
 * to: a container's host), and a UPnP description URL added to the SSDP answers (a NAT in front drops the router's
 * SSDP replies: they come from another port than the one asked).
 */
export declare function overrideNetwork(base: Network, o: NetworkOverrides): Network;
