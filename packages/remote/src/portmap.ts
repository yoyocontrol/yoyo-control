// The home router's port mapping for a listener of the caller's (@yoyocontrol/portmap: PCP, NAT-PMP, UPnP IGD), with
// overrides for a listener behind another NAT (a container's published port).

import type { Network } from "@yoyocontrol/portmap";

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
export function overrideNetwork(base: Network, o: NetworkOverrides): Network {
  const gatewayFromLocation = o.upnpLocation ? safeHost(o.upnpLocation) : null;
  return {
    ...base,
    gateway: async () => o.gateway ?? gatewayFromLocation ?? (await base.gateway()),
    localAddress: async (towards) => o.internalClient ?? (await base.localAddress(towards)),
    ssdpSearch: async (targets, waitMs, localAddress, preferFrom) => {
      const answers = await base.ssdpSearch(targets, o.upnpLocation ? Math.min(waitMs, 1000) : waitMs, o.internalClient ? null : localAddress, preferFrom);
      if (!o.upnpLocation) return answers;
      const from = gatewayFromLocation ?? o.gateway ?? "0.0.0.0";
      return [{ from, message: `HTTP/1.1 200 OK\r\nLOCATION: ${o.upnpLocation}\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n` }, ...answers];
    },
  };
}

function safeHost(url: string): string | null {
  try {
    return new URL(url).hostname || null;
  } catch {
    return null;
  }
}
