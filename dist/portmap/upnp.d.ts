import type { Network } from "./network.js";
import type { Protocol } from "./natpmp.js";
export declare const SSDP_ADDRESS = "239.255.255.250";
export declare const SSDP_PORT = 1900;
export declare const SSDP_WAIT_MS = 2000;
export declare const SOAP_TIMEOUT_MS = 5000;
/** The search targets, in order of preference. */
export declare const IGD_SEARCH_TARGETS: string[];
/** WAN connection services that can map ports, best first. */
export declare const WAN_SERVICE_TYPES: string[];
export declare const UPNP_ERRORS: Record<number, string>;
export declare function ssdpSearchMessage(st: string, host?: string, mx?: number): string;
export interface SsdpResponse {
    location: string;
    st: string;
    server: string;
    usn: string;
}
/** Parses an SSDP search response (`HTTP/1.1 200 OK` + headers). Null when it isn't one or has no http(s) LOCATION. */
export declare function parseSsdpResponse(text: string): SsdpResponse | null;
export declare function escapeXml(s: string): string;
export declare function unescapeXml(s: string): string;
/** The text of the first `<name>` element (any namespace prefix), unescaped and trimmed; null when absent. */
export declare function xmlText(xml: string, name: string): string | null;
export interface WanService {
    serviceType: string;
    controlURL: string;
    /** The device description it came from */
    location: string;
}
/** The WAN connection services of an IGD's description, best first (WAN_SERVICE_TYPES order). */
export declare function parseDeviceDescription(xml: string, location: string): WanService[];
export declare function soapEnvelope(serviceType: string, action: string, args: Array<[string, string | number]>): string;
export declare function soapHeaders(serviceType: string, action: string): Record<string, string>;
export type SoapResult = {
    ok: true;
    values: Record<string, string>;
} | {
    ok: false;
    code: number | null;
    description: string;
};
/** Parses a SOAP answer: the `<action>Response` values, or the UPnP fault (`errorCode` / `errorDescription`). */
export declare function parseSoapResponse(status: number, xml: string, action: string, names?: string[]): SoapResult;
export declare class UpnpError extends Error {
    readonly action: string;
    readonly code: number | null;
    constructor(action: string, code: number | null, description: string);
}
/** Searches for IGDs (multicast, and unicast to the gateway when known) and returns their WAN services, best first. */
export declare function discoverWanServices(net: Network, opts?: {
    gateway?: string | null;
    localAddress?: string | null;
    waitMs?: number;
}): Promise<WanService[]>;
export declare function soapCall(net: Network, svc: WanService, action: string, args: Array<[string, string | number]>, names?: string[]): Promise<Record<string, string>>;
export declare function getExternalIPAddress(net: Network, svc: WanService): Promise<string>;
export interface UpnpMapping {
    externalPort: number;
    protocol: Protocol;
    internalPort: number;
    internalClient: string;
    description: string;
    /** seconds; 0 = permanent */
    lifetime: number;
}
export declare function addPortMapping(net: Network, svc: WanService, m: UpnpMapping): Promise<void>;
export declare function deletePortMapping(net: Network, svc: WanService, externalPort: number, protocol: Protocol): Promise<void>;
/** The mapping of an external port, or null when there is none (714). */
export declare function getSpecificPortMappingEntry(net: Network, svc: WanService, externalPort: number, protocol: Protocol): Promise<UpnpMapping | null>;
