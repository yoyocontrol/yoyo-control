// The home router's port mapping for a listener of the caller's (@yoyocontrol/portmap: PCP, NAT-PMP, UPnP IGD), with
// overrides for a listener behind another NAT (a container's published port).
/**
 * The mapper's network with the caller's overrides: the gateway, the internal client (the address the router forwards
 * to: a container's host), and a UPnP description URL added to the SSDP answers (a NAT in front drops the router's
 * SSDP replies: they come from another port than the one asked).
 */
export function overrideNetwork(base, o) {
    const gatewayFromLocation = o.upnpLocation ? safeHost(o.upnpLocation) : null;
    return {
        ...base,
        gateway: async () => o.gateway ?? gatewayFromLocation ?? (await base.gateway()),
        localAddress: async (towards) => o.internalClient ?? (await base.localAddress(towards)),
        ssdpSearch: async (targets, waitMs, localAddress, preferFrom) => {
            const answers = await base.ssdpSearch(targets, o.upnpLocation ? Math.min(waitMs, 1000) : waitMs, o.internalClient ? null : localAddress, preferFrom);
            if (!o.upnpLocation)
                return answers;
            const from = gatewayFromLocation ?? o.gateway ?? "0.0.0.0";
            return [{ from, message: `HTTP/1.1 200 OK\r\nLOCATION: ${o.upnpLocation}\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n` }, ...answers];
        },
    };
}
function safeHost(url) {
    try {
        return new URL(url).hostname || null;
    }
    catch {
        return null;
    }
}
