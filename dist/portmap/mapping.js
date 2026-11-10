// A port mapping kept alive on the home router: PCP, then NAT-PMP, then UPnP IGD (the first that answers wins);
// renewed at half the lease, moved to another external port when the router refuses the preferred one, deleted by
// stop(). An external address that the internet can't reach (private, CGNAT, 0.0.0.0) is reported as "unreachable"
// and its mapping removed again: a hole in an inner NAT helps nobody.
import { randomBytes } from "node:crypto";
import { classifyIPv4 } from "./address.js";
import { parsePcpResponse, parsePmpExternalAddress, parsePmpMapResponse, pcpAnnounceRequest, pcpMapRequest, PCP_OP_MAP, PCP_RESULTS, PMP_PORT, PMP_RESULTS, PMP_TIMEOUTS_MS, pmpExternalAddressRequest, pmpMapRequest, } from "./natpmp.js";
import { nodeNetwork, systemClock } from "./network.js";
import { addPortMapping, deletePortMapping, discoverWanServices, getExternalIPAddress, getSpecificPortMappingEntry, UpnpError, } from "./upnp.js";
export const DEFAULT_METHODS = ["pcp", "natpmp", "upnp"];
export const DEFAULT_LIFETIME_S = 7200;
/** How often a permanent UPnP mapping (a router that only does lease 0) is re-added: survives router reboots. */
export const PERMANENT_REFRESH_S = 1200;
export class PortMapping {
    protocol;
    internalPort;
    preferredPort;
    description;
    lifetime;
    methods;
    net;
    clock;
    random;
    portAttempts;
    onChange;
    log;
    _state = { status: "idle" };
    cur = null;
    nonce = randomBytes(12);
    services = null;
    discovery = null;
    timer = null;
    queue = Promise.resolve();
    running = false;
    failures = 0;
    constructor(opts) {
        if (!Number.isInteger(opts.internalPort) || opts.internalPort < 1 || opts.internalPort > 65535)
            throw new RangeError("internalPort must be 1…65535");
        this.protocol = opts.protocol ?? "tcp";
        this.internalPort = opts.internalPort;
        this.preferredPort = validPort(opts.externalPort) ? opts.externalPort : opts.internalPort;
        this.description = (opts.description ?? "portmap").slice(0, 64);
        this.lifetime = Math.max(120, Math.floor(opts.lifetime ?? DEFAULT_LIFETIME_S));
        this.methods = opts.methods ?? DEFAULT_METHODS;
        this.net = opts.network ?? nodeNetwork();
        this.clock = opts.clock ?? systemClock;
        this.random = opts.random ?? Math.random;
        this.portAttempts = opts.portAttempts ?? 6;
        this.onChange = opts.onChange;
        this.log = opts.log ?? (() => { });
    }
    get state() {
        return this._state;
    }
    /** Starts mapping (and keeps it alive until stop()); resolves with the first outcome. */
    start() {
        this.running = true;
        return this.enqueue(() => this.attempt());
    }
    /** Maps again now: after a network change (the caller watches the network), or to retry sooner. */
    refresh() {
        if (!this.running)
            return Promise.resolve(this._state);
        this.services = null;
        this.discovery = null;
        return this.enqueue(() => this.attempt());
    }
    /** Deletes the mapping on the router and stops renewing. Safe to call more than once. */
    stop() {
        this.running = false;
        this.cancelTimer();
        return this.enqueue(async () => {
            await this.release();
            this.setState({ status: "idle" });
        }).then(() => { });
    }
    // ---- the work, one step at a time ----
    enqueue(step) {
        const p = this.queue.then(step, step).then(() => this._state);
        this.queue = p.then(() => { }, () => { });
        return p;
    }
    cancelTimer() {
        if (this.timer !== null)
            this.clock.clearTimeout(this.timer);
        this.timer = null;
    }
    schedule(seconds, step) {
        this.cancelTimer();
        if (!this.running)
            return;
        this.timer = this.clock.setTimeout(() => {
            this.timer = null;
            void this.enqueue(step);
        }, Math.max(1, seconds) * 1000);
    }
    setState(s) {
        const prev = this._state;
        this._state = s;
        if (sameState(prev, s))
            return;
        this.onChange?.(s);
    }
    async attempt() {
        if (!this.running)
            return;
        this.cancelTimer();
        if (this._state.status === "idle")
            this.setState({ status: "probing" });
        const gateway = await this.net.gateway().catch(() => null);
        const internalAddress = gateway ? await this.net.localAddress(gateway).catch(() => null) : null;
        // a mapping we hold on another network / address goes first (best effort: the old router may be gone)
        if (this.cur && (this.cur.gateway !== gateway || (internalAddress && this.cur.internalAddress !== internalAddress))) {
            await this.release();
        }
        // UPnP's discovery (SSDP, ~2 s) runs while PCP / NAT-PMP wait for their answers
        if (this.methods.includes("upnp") && !this.services && !this.discovery) {
            this.discovery = discoverWanServices(this.net, { gateway, localAddress: internalAddress }).catch(() => []);
        }
        // a renewal asks the mechanism that holds the mapping first
        const order = this.cur ? [this.cur.method, ...this.methods.filter((x) => x !== this.cur.method)] : this.methods;
        const outcomes = [];
        for (const method of order) {
            let o;
            try {
                o = await this.tryMethod(method, gateway, internalAddress);
            }
            catch (e) {
                o = { kind: "failed", method, error: e instanceof Error ? e.message : String(e) };
            }
            outcomes.push(o);
            if (o.kind === "mapped" || o.kind === "unreachable")
                break;
        }
        const mapped = outcomes.find((o) => o.kind === "mapped");
        if (!this.running) {
            // stop() came while we were mapping: what we just made goes again
            if (mapped)
                await this.release(mapped.cur);
            return;
        }
        if (mapped) {
            const prev = this.cur;
            if (prev && prev.method !== mapped.cur.method)
                await this.release(prev); // moved to another mechanism
            this.cur = mapped.cur;
            this.failures = 0;
            this.preferredPort = mapped.cur.externalPort;
            if (!prev || prev.externalPort !== mapped.cur.externalPort || prev.externalAddress !== mapped.cur.externalAddress || prev.method !== mapped.cur.method) {
                this.log(`portmap: ${mapped.cur.method} ${mapped.cur.externalAddress}:${mapped.cur.externalPort} → ${mapped.cur.internalAddress}:${this.internalPort}/${this.protocol} (${mapped.cur.lifetime ? `lease ${mapped.cur.lifetime} s` : "permanent"})`);
            }
            const since = this._state.status === "mapped" && sameMapping(this._state, mapped.cur) ? this._state.since : this.clock.now();
            this.setState({
                status: "mapped",
                method: mapped.cur.method,
                protocol: this.protocol,
                externalAddress: mapped.cur.externalAddress,
                externalPort: mapped.cur.externalPort,
                internalAddress: mapped.cur.internalAddress,
                internalPort: this.internalPort,
                lifetime: mapped.cur.lifetime,
                since,
            });
            this.schedule(mapped.cur.lifetime ? mapped.cur.lifetime / 2 : PERMANENT_REFRESH_S, () => this.attempt());
            return;
        }
        await this.release(); // whatever the router still has of ours (best effort)
        this.failures++;
        const unreachable = outcomes.find((o) => o.kind === "unreachable");
        const failed = outcomes.find((o) => o.kind === "failed");
        const now = this.clock.now();
        if (unreachable) {
            this.log(`portmap: ${unreachable.method} external address ${unreachable.externalAddress || "(none)"} is ${unreachable.reason}: not reachable from the internet`);
            this.setState({ status: "unreachable", method: unreachable.method, externalAddress: unreachable.externalAddress, reason: unreachable.reason, since: now });
            this.schedule(1800, () => this.attempt());
        }
        else if (failed) {
            this.log(`portmap: ${failed.method} failed: ${failed.error}`);
            this.setState({ status: "failed", method: failed.method, error: failed.error, since: now });
            this.schedule(Math.min(1800, 60 * 2 ** Math.min(5, this.failures - 1)), () => this.attempt());
        }
        else {
            if (this._state.status !== "unsupported")
                this.log("portmap: no PCP / NAT-PMP / UPnP gateway answered");
            this.setState({ status: "unsupported", since: now });
            this.schedule(300, () => this.attempt());
        }
    }
    async tryMethod(method, gateway, internalAddress) {
        switch (method) {
            case "pcp":
                return gateway && internalAddress ? this.tryPcp(gateway, internalAddress) : { kind: "none" };
            case "natpmp":
                return gateway && internalAddress ? this.tryPmp(gateway, internalAddress) : { kind: "none" };
            case "upnp":
                return this.tryUpnp(gateway, internalAddress);
        }
    }
    reachability(method, externalAddress) {
        const c = classifyIPv4(externalAddress);
        if (c === "public")
            return null;
        return { kind: "unreachable", method, externalAddress, reason: c ?? "unknown" };
    }
    // ---- PCP ----
    async pcp(gateway, internalAddress, externalPort, lifetime, externalAddress) {
        const req = pcpMapRequest({ nonce: this.nonce, protocol: this.protocol, internalPort: this.internalPort, externalPort, externalAddress, lifetime, clientAddress: internalAddress });
        const nonce = this.nonce;
        const msg = await this.net.udpRequest(gateway, PMP_PORT, req, PMP_TIMEOUTS_MS, (b) => {
            const r = parsePcpResponse(b);
            return !!r && (r.version === 0 || (r.opcode === PCP_OP_MAP && !!r.map && equalBytes(r.map.nonce, nonce)));
        });
        return msg ? parsePcpResponse(msg) : null;
    }
    async tryPcp(gateway, internalAddress) {
        const same = this.cur?.method === "pcp" ? this.cur : null;
        const r = await this.pcp(gateway, internalAddress, same?.externalPort ?? this.preferredPort, this.lifetime, same?.externalAddress);
        if (!r || r.version === 0)
            return { kind: "none" }; // silent, or NAT-PMP only
        if (r.result !== 0 || !r.map)
            return { kind: "failed", method: "pcp", error: `PCP ${r.result} ${PCP_RESULTS[r.result] ?? ""}`.trim() };
        const externalAddress = r.map.externalAddress ?? "";
        const cur = { method: "pcp", gateway, internalAddress, externalAddress, externalPort: r.map.externalPort, lifetime: r.lifetime };
        const bad = this.reachability("pcp", externalAddress);
        if (bad) {
            this.cur = cur;
            await this.release();
            return bad;
        }
        return { kind: "mapped", cur };
    }
    // ---- NAT-PMP ----
    async tryPmp(gateway, internalAddress) {
        const a = await this.net.udpRequest(gateway, PMP_PORT, pmpExternalAddressRequest(), PMP_TIMEOUTS_MS, (b) => parsePmpExternalAddress(b) !== null);
        const ext = a ? parsePmpExternalAddress(a) : null;
        if (!ext)
            return { kind: "none" };
        if (ext.result !== 0)
            return { kind: "failed", method: "natpmp", error: `NAT-PMP ${ext.result} ${PMP_RESULTS[ext.result] ?? ""}`.trim() };
        const bad = this.reachability("natpmp", ext.address);
        if (bad)
            return bad;
        const same = this.cur?.method === "natpmp" ? this.cur : null;
        const m = await this.net.udpRequest(gateway, PMP_PORT, pmpMapRequest(this.protocol, this.internalPort, same?.externalPort ?? this.preferredPort, this.lifetime), PMP_TIMEOUTS_MS, (b) => parsePmpMapResponse(b, this.protocol) !== null);
        const r = m ? parsePmpMapResponse(m, this.protocol) : null;
        if (!r)
            return { kind: "failed", method: "natpmp", error: "NAT-PMP: no answer to the mapping request" };
        if (r.result !== 0)
            return { kind: "failed", method: "natpmp", error: `NAT-PMP ${r.result} ${PMP_RESULTS[r.result] ?? ""}`.trim() };
        return { kind: "mapped", cur: { method: "natpmp", gateway, internalAddress, externalAddress: ext.address, externalPort: r.externalPort, lifetime: r.lifetime } };
    }
    // ---- UPnP IGD ----
    async tryUpnp(gateway, knownInternal) {
        if (!this.services) {
            const pending = this.discovery ?? discoverWanServices(this.net, { gateway, localAddress: knownInternal });
            this.discovery = null;
            this.services = await pending;
        }
        if (this.services.length === 0) {
            this.services = null; // look again next time
            return { kind: "none" };
        }
        let lastError = null;
        for (const svc of this.services) {
            const host = new URL(svc.controlURL).hostname;
            const internalAddress = knownInternal && host === gateway ? knownInternal : await this.net.localAddress(host).catch(() => null);
            if (!internalAddress)
                continue;
            let externalAddress;
            try {
                externalAddress = await getExternalIPAddress(this.net, svc);
            }
            catch (e) {
                lastError = errorText(e);
                continue; // e.g. an unconnected WANPPPConnection next to the real WANIPConnection
            }
            const bad = this.reachability("upnp", externalAddress);
            if (bad) {
                if (classifyIPv4(externalAddress) === "unspecified")
                    continue; // this connection is down: another may be up
                return bad;
            }
            try {
                const got = await this.upnpMap(svc, internalAddress);
                return { kind: "mapped", cur: { method: "upnp", gateway, internalAddress, externalAddress, externalPort: got.port, lifetime: got.lifetime, service: svc } };
            }
            catch (e) {
                lastError = errorText(e);
            }
        }
        this.services = null;
        return lastError ? { kind: "failed", method: "upnp", error: lastError } : { kind: "none" };
    }
    /** AddPortMapping on the preferred port, then on others while the router says it's taken. */
    async upnpMap(svc, internalAddress) {
        const same = this.cur?.method === "upnp" && this.cur.service?.controlURL === svc.controlURL ? this.cur : null;
        const ports = [same?.externalPort ?? this.preferredPort];
        if (!ports.includes(this.internalPort))
            ports.push(this.internalPort);
        while (ports.length < this.portAttempts + 1) {
            const p = 10000 + Math.floor(this.random() * 55000);
            if (!ports.includes(p))
                ports.push(p);
        }
        let lifetime = same ? same.lifetime : this.lifetime;
        let last = null;
        for (let i = 0; i < ports.length; i++) {
            const port = ports[i];
            const entry = await getSpecificPortMappingEntry(this.net, svc, port, this.protocol).catch(() => null);
            if (entry && !(entry.internalClient === internalAddress && entry.internalPort === this.internalPort)) {
                this.log(`portmap: upnp external port ${port} is taken by ${entry.internalClient}:${entry.internalPort} (${entry.description})`);
                continue;
            }
            try {
                await addPortMapping(this.net, svc, { externalPort: port, protocol: this.protocol, internalPort: this.internalPort, internalClient: internalAddress, description: this.description, lifetime });
                return { port, lifetime };
            }
            catch (e) {
                last = e;
                if (!(e instanceof UpnpError))
                    throw e;
                if (e.code === 725 && lifetime !== 0) {
                    lifetime = 0; // only permanent leases: refreshed by us, deleted on stop()
                    i--;
                    continue;
                }
                if (e.code === 724) {
                    // external must equal internal: only that one port can work
                    if (port === this.internalPort)
                        throw e;
                    ports.splice(i + 1, ports.length, this.internalPort);
                    continue;
                }
                if (e.code === 718 || e.code === 729 || e.code === 501)
                    continue; // taken / refused for this port: try another
                throw e;
            }
        }
        throw last instanceof Error ? last : new Error("UPnP: no external port could be mapped");
    }
    /** Deletes what we hold (best effort, each method's own way). */
    async release(cur = this.cur) {
        if (cur === this.cur)
            this.cur = null;
        if (!cur)
            return;
        try {
            if (cur.method === "upnp" && cur.service) {
                await deletePortMapping(this.net, cur.service, cur.externalPort, this.protocol);
            }
            else if (cur.method === "natpmp" && cur.gateway) {
                await this.net.udpRequest(cur.gateway, PMP_PORT, pmpMapRequest(this.protocol, this.internalPort, 0, 0), PMP_TIMEOUTS_MS, (b) => parsePmpMapResponse(b, this.protocol) !== null);
            }
            else if (cur.method === "pcp" && cur.gateway) {
                await this.pcp(cur.gateway, cur.internalAddress, cur.externalPort, 0);
            }
            this.log(`portmap: ${cur.method} deleted ${cur.externalAddress}:${cur.externalPort}`);
        }
        catch (e) {
            this.log(`portmap: ${cur.method} delete of ${cur.externalPort} failed: ${errorText(e)}`);
        }
        this.nonce = randomBytes(12);
    }
}
/** Creates a PortMapping and starts it. */
export async function mapPort(opts) {
    const m = new PortMapping(opts);
    await m.start();
    return m;
}
/** What the network offers, without mapping anything (diagnostics). */
export async function probe(opts = {}) {
    const net = opts.network ?? nodeNetwork();
    const gateway = await net.gateway().catch(() => null);
    const internalAddress = gateway ? await net.localAddress(gateway).catch(() => null) : null;
    const [pcpMsg, pmpMsg, services] = await Promise.all([
        gateway && internalAddress ? net.udpRequest(gateway, PMP_PORT, pcpAnnounceRequest(internalAddress), PMP_TIMEOUTS_MS, (b) => parsePcpResponse(b) !== null) : null,
        gateway ? net.udpRequest(gateway, PMP_PORT, pmpExternalAddressRequest(), PMP_TIMEOUTS_MS, (b) => parsePmpExternalAddress(b) !== null) : null,
        discoverWanServices(net, { gateway, localAddress: internalAddress }).catch(() => []),
    ]);
    const pcp = pcpMsg ? parsePcpResponse(pcpMsg) : null;
    const pmp = pmpMsg ? parsePmpExternalAddress(pmpMsg) : null;
    let upnpAddress = null;
    for (const s of services) {
        upnpAddress = await getExternalIPAddress(net, s).catch(() => null);
        if (upnpAddress)
            break;
    }
    return {
        gateway,
        internalAddress,
        pcp: pcp && pcp.version === 2 && pcp.result === 0 ? { epoch: pcp.epoch } : null,
        natpmp: pmp && pmp.result === 0 ? { externalAddress: pmp.address, epoch: pmp.epoch } : null,
        upnp: services.length ? { services, externalAddress: upnpAddress } : null,
    };
}
function validPort(p) {
    return p !== undefined && Number.isInteger(p) && p >= 1 && p <= 65535;
}
function equalBytes(a, b) {
    return a.length === b.length && a.every((x, i) => x === b[i]);
}
function errorText(e) {
    return e instanceof Error ? e.message : String(e);
}
function sameMapping(s, c) {
    return s.method === c.method && s.externalAddress === c.externalAddress && s.externalPort === c.externalPort;
}
/** Whether a listener would care: renewals that change nothing don't count. */
function sameState(a, b) {
    if (a.status !== b.status)
        return false;
    switch (b.status) {
        case "mapped": {
            const x = a;
            return x.method === b.method && x.externalAddress === b.externalAddress && x.externalPort === b.externalPort && x.internalAddress === b.internalAddress && x.lifetime === b.lifetime;
        }
        case "unreachable": {
            const x = a;
            return x.method === b.method && x.externalAddress === b.externalAddress && x.reason === b.reason;
        }
        case "failed": {
            const x = a;
            return x.method === b.method && x.error === b.error;
        }
        default:
            return true;
    }
}
