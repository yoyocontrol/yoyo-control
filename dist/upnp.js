// UPnP IGD (Internet Gateway Device): SSDP discovery, the device description, and the WANIPConnection /
// WANPPPConnection SOAP actions a port mapping needs. The pure parts (messages, parsing) are exported for tests and
// for other implementations; the network parts take a `Network` (network.ts).
export const SSDP_ADDRESS = "239.255.255.250";
export const SSDP_PORT = 1900;
export const SSDP_WAIT_MS = 2000;
export const SOAP_TIMEOUT_MS = 5000;
const MAX_XML = 256 * 1024;
/** The search targets, in order of preference. */
export const IGD_SEARCH_TARGETS = [
    "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
    "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
    "urn:schemas-upnp-org:service:WANIPConnection:2",
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    "urn:schemas-upnp-org:service:WANPPPConnection:1",
];
/** WAN connection services that can map ports, best first. */
export const WAN_SERVICE_TYPES = [
    "urn:schemas-upnp-org:service:WANIPConnection:2",
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    "urn:schemas-upnp-org:service:WANPPPConnection:1",
];
export const UPNP_ERRORS = {
    401: "invalid action",
    402: "invalid args",
    501: "action failed",
    606: "action not authorized",
    714: "no such entry in array",
    715: "wildcard not permitted in source IP",
    716: "wildcard not permitted in external port",
    718: "conflict in mapping entry",
    724: "same port values required",
    725: "only permanent leases supported",
    726: "remote host only supports wildcard",
    727: "external port only supports wildcard",
    728: "no port maps available",
    729: "conflict with other mechanisms",
};
// ---- SSDP ----
export function ssdpSearchMessage(st, host = `${SSDP_ADDRESS}:${SSDP_PORT}`, mx = 2) {
    return `M-SEARCH * HTTP/1.1\r\nHOST: ${host}\r\nMAN: "ssdp:discover"\r\nMX: ${mx}\r\nST: ${st}\r\n\r\n`;
}
/** Parses an SSDP search response (`HTTP/1.1 200 OK` + headers). Null when it isn't one or has no http(s) LOCATION. */
export function parseSsdpResponse(text) {
    const lines = text.slice(0, 8192).split(/\r?\n/);
    if (!/^HTTP\/1\.[01] 200\b/i.test(lines[0] ?? ""))
        return null;
    const h = {};
    for (const line of lines.slice(1)) {
        const i = line.indexOf(":");
        if (i > 0)
            h[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
    }
    const location = h["location"] ?? "";
    if (!/^https?:\/\//i.test(location))
        return null;
    return { location, st: h["st"] ?? "", server: h["server"] ?? "", usn: h["usn"] ?? "" };
}
// ---- XML (just enough: UPnP's documents are small and flat) ----
export function escapeXml(s) {
    return s.replace(/[<>&'"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" })[c]);
}
export function unescapeXml(s) {
    return s
        .replace(/&#x([0-9a-f]{1,6});/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
        .replace(/&#(\d{1,7});/g, (_, d) => String.fromCodePoint(Number(d)))
        .replace(/&(lt|gt|amp|apos|quot);/g, (_, n) => ({ lt: "<", gt: ">", amp: "&", apos: "'", quot: '"' })[n]);
}
/** The text of the first `<name>` element (any namespace prefix), unescaped and trimmed; null when absent. */
export function xmlText(xml, name) {
    const re = new RegExp(`<(?:[A-Za-z_][\\w.-]{0,40}:)?${name}(?:\\s[^>]{0,400})?(?:/>|>([\\s\\S]{0,8192}?)</(?:[A-Za-z_][\\w.-]{0,40}:)?${name}\\s{0,8}>)`);
    const m = re.exec(xml);
    if (!m)
        return null;
    return unescapeXml(m[1] ?? "").trim();
}
function xmlBlocks(xml, name) {
    const re = new RegExp(`<(?:[A-Za-z_][\\w.-]{0,40}:)?${name}(?:\\s[^>]{0,400})?>([\\s\\S]{0,65536}?)</(?:[A-Za-z_][\\w.-]{0,40}:)?${name}\\s{0,8}>`, "g");
    return [...xml.matchAll(re)].map((m) => m[1] ?? "");
}
/** The WAN connection services of an IGD's description, best first (WAN_SERVICE_TYPES order). */
export function parseDeviceDescription(xml, location) {
    const doc = xml.slice(0, MAX_XML);
    const base = xmlText(doc, "URLBase") || location;
    const out = [];
    for (const block of xmlBlocks(doc, "service")) {
        const serviceType = xmlText(block, "serviceType") ?? "";
        const control = xmlText(block, "controlURL");
        if (!WAN_SERVICE_TYPES.includes(serviceType) || !control)
            continue;
        let controlURL;
        try {
            controlURL = new URL(control, base).toString();
        }
        catch {
            continue;
        }
        if (!/^https?:/.test(controlURL))
            continue;
        out.push({ serviceType, controlURL, location });
    }
    return out.sort((a, b) => WAN_SERVICE_TYPES.indexOf(a.serviceType) - WAN_SERVICE_TYPES.indexOf(b.serviceType));
}
// ---- SOAP ----
export function soapEnvelope(serviceType, action, args) {
    const body = args.map(([k, v]) => `<${k}>${escapeXml(String(v))}</${k}>`).join("");
    return (`<?xml version="1.0"?>\r\n` +
        `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">` +
        `<s:Body><u:${action} xmlns:u="${escapeXml(serviceType)}">${body}</u:${action}></s:Body></s:Envelope>\r\n`);
}
export function soapHeaders(serviceType, action) {
    return { "Content-Type": 'text/xml; charset="utf-8"', SOAPAction: `"${serviceType}#${action}"` };
}
/** Parses a SOAP answer: the `<action>Response` values, or the UPnP fault (`errorCode` / `errorDescription`). */
export function parseSoapResponse(status, xml, action, names = []) {
    const doc = xml.slice(0, MAX_XML);
    if (status === 200 && new RegExp(`<(?:[A-Za-z_][\\w.-]{0,40}:)?${action}Response[\\s>/]`).test(doc)) {
        const values = {};
        for (const n of names) {
            const v = xmlText(doc, n);
            if (v !== null)
                values[n] = v;
        }
        return { ok: true, values };
    }
    const code = xmlText(doc, "errorCode");
    const n = code !== null && /^\d+$/.test(code) ? Number(code) : null;
    const description = xmlText(doc, "errorDescription") || (n !== null ? UPNP_ERRORS[n] : undefined) || `HTTP ${status}`;
    return { ok: false, code: n, description };
}
export class UpnpError extends Error {
    action;
    code;
    constructor(action, code, description) {
        super(`UPnP ${action}: ${code !== null ? `${code} ` : ""}${description}`);
        this.action = action;
        this.code = code;
        this.name = "UpnpError";
    }
}
// ---- the network side ----
/** Searches for IGDs (multicast, and unicast to the gateway when known) and returns their WAN services, best first. */
export async function discoverWanServices(net, opts = {}) {
    const targets = [];
    const enc = new TextEncoder();
    for (const st of IGD_SEARCH_TARGETS) {
        targets.push({ host: SSDP_ADDRESS, port: SSDP_PORT, payload: enc.encode(ssdpSearchMessage(st)) });
        if (opts.gateway)
            targets.push({ host: opts.gateway, port: SSDP_PORT, payload: enc.encode(ssdpSearchMessage(st, `${opts.gateway}:${SSDP_PORT}`)) });
    }
    const answers = await net.ssdpSearch(targets, opts.waitMs ?? SSDP_WAIT_MS, opts.localAddress ?? null);
    const locations = [];
    for (const a of answers) {
        const r = parseSsdpResponse(a.message);
        if (!r || locations.includes(r.location))
            continue;
        // the gateway's own answers first (another UPnP device on the LAN can answer a WAN* search too)
        if (opts.gateway && a.from === opts.gateway)
            locations.unshift(r.location);
        else
            locations.push(r.location);
    }
    const services = [];
    for (const location of locations) {
        try {
            const res = await net.http({ url: location, method: "GET", headers: {}, timeoutMs: SOAP_TIMEOUT_MS });
            if (res.status !== 200)
                continue;
            for (const s of parseDeviceDescription(res.body, location)) {
                if (!services.some((x) => x.controlURL === s.controlURL))
                    services.push(s);
            }
        }
        catch {
            // a device that doesn't answer its own LOCATION: skip it
        }
    }
    return services;
}
export async function soapCall(net, svc, action, args, names = []) {
    const res = await net.http({
        url: svc.controlURL,
        method: "POST",
        headers: soapHeaders(svc.serviceType, action),
        body: soapEnvelope(svc.serviceType, action, args),
        timeoutMs: SOAP_TIMEOUT_MS,
    });
    const r = parseSoapResponse(res.status, res.body, action, names);
    if (!r.ok)
        throw new UpnpError(action, r.code, r.description);
    return r.values;
}
export async function getExternalIPAddress(net, svc) {
    const v = await soapCall(net, svc, "GetExternalIPAddress", [], ["NewExternalIPAddress"]);
    return v["NewExternalIPAddress"] ?? "";
}
export async function addPortMapping(net, svc, m) {
    await soapCall(net, svc, "AddPortMapping", [
        ["NewRemoteHost", ""],
        ["NewExternalPort", m.externalPort],
        ["NewProtocol", m.protocol.toUpperCase()],
        ["NewInternalPort", m.internalPort],
        ["NewInternalClient", m.internalClient],
        ["NewEnabled", 1],
        ["NewPortMappingDescription", m.description],
        ["NewLeaseDuration", m.lifetime],
    ]);
}
export async function deletePortMapping(net, svc, externalPort, protocol) {
    await soapCall(net, svc, "DeletePortMapping", [
        ["NewRemoteHost", ""],
        ["NewExternalPort", externalPort],
        ["NewProtocol", protocol.toUpperCase()],
    ]);
}
/** The mapping of an external port, or null when there is none (714). */
export async function getSpecificPortMappingEntry(net, svc, externalPort, protocol) {
    try {
        const v = await soapCall(net, svc, "GetSpecificPortMappingEntry", [["NewRemoteHost", ""], ["NewExternalPort", externalPort], ["NewProtocol", protocol.toUpperCase()]], ["NewInternalPort", "NewInternalClient", "NewEnabled", "NewPortMappingDescription", "NewLeaseDuration"]);
        return {
            externalPort,
            protocol,
            internalPort: Number(v["NewInternalPort"] ?? 0),
            internalClient: v["NewInternalClient"] ?? "",
            description: v["NewPortMappingDescription"] ?? "",
            lifetime: Number(v["NewLeaseDuration"] ?? 0),
        };
    }
    catch (e) {
        if (e instanceof UpnpError && e.code === 714)
            return null;
        throw e;
    }
}
