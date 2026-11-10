// What the port mapper needs from the network, as an interface: tests (and unusual hosts) inject their own; `nodeNetwork()`
// is the real one (Node's dgram / http, the routing table on macOS and Linux).
import { execFile } from "node:child_process";
import { createSocket } from "node:dgram";
import { readFile } from "node:fs/promises";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { parseIPv4 } from "./address.js";
export const systemClock = {
    now: () => Date.now(),
    setTimeout: (fn, ms) => {
        const t = setTimeout(fn, ms);
        t.unref?.(); // a lease timer never keeps the process alive
        return t;
    },
    clearTimeout: (h) => clearTimeout(h),
};
const MAX_HTTP_BODY = 512 * 1024;
/** The default gateway from `route -n get default` (macOS / BSD), /proc/net/route (Linux) or `route print` (Windows). */
export async function systemGateway(platform = process.platform) {
    if (platform === "linux") {
        try {
            return parseProcNetRoute(await readFile("/proc/net/route", "utf8"));
        }
        catch {
            return null;
        }
    }
    if (platform === "win32") {
        const out = await new Promise((resolve) => {
            const route = `${process.env.SystemRoot ?? "C:\\Windows"}\\System32\\ROUTE.EXE`;
            execFile(route, ["print", "-4", "0.0.0.0"], { timeout: 3000, windowsHide: true }, (err, stdout) => resolve(err ? "" : String(stdout)));
        });
        return parseRoutePrint(out);
    }
    if (platform === "darwin" || platform === "freebsd" || platform === "openbsd") {
        const out = await new Promise((resolve) => {
            execFile("/sbin/route", ["-n", "get", "default"], { timeout: 3000 }, (err, stdout) => resolve(err ? "" : String(stdout)));
        });
        return parseRouteGetDefault(out);
    }
    return null;
}
/** `route -n get default` → the `gateway:` line when it is an IPv4 address (not `link#N` on a point-to-point VPN). */
export function parseRouteGetDefault(out) {
    const m = /^\s*gateway:\s*(\S+)\s*$/m.exec(out);
    return m && parseIPv4(m[1]) ? m[1] : null;
}
/**
 * Windows' `route print -4 0.0.0.0` → the gateway of the lowest-metric active default route. The table's rows are
 * `0.0.0.0  0.0.0.0  <gateway>  <interface>  <metric>` whatever the display language; an on-link row has no address
 * there and is skipped; persistent routes (a later table, no interface column) don't match.
 */
export function parseRoutePrint(out) {
    let best = null;
    for (const line of out.split(/\r?\n/)) {
        const m = /^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s*$/.exec(line);
        if (!m || !parseIPv4(m[1]) || m[1] === "0.0.0.0")
            continue;
        const metric = Number(m[3]);
        if (!best || metric < best.metric)
            best = { gw: m[1], metric };
    }
    return best?.gw ?? null;
}
/** /proc/net/route → the gateway of the lowest-metric default route (little-endian hex). */
export function parseProcNetRoute(text) {
    let best = null;
    for (const line of text.split("\n").slice(1)) {
        const f = line.trim().split(/\s+/);
        if (f.length < 7 || f[1] !== "00000000" || f[2] === "00000000")
            continue;
        const flags = parseInt(f[3], 16);
        if (!(flags & 0x1) || !(flags & 0x2))
            continue; // RTF_UP | RTF_GATEWAY
        const n = parseInt(f[2], 16);
        const gw = `${n & 0xff}.${(n >>> 8) & 0xff}.${(n >>> 16) & 0xff}.${(n >>> 24) & 0xff}`;
        const metric = Number(f[6]);
        if (!best || metric < best.metric)
            best = { gw, metric };
    }
    return best?.gw ?? null;
}
function closeQuietly(s) {
    try {
        s.close();
    }
    catch {
        // already closed
    }
}
export function nodeNetwork(opts = {}) {
    return {
        gateway: () => systemGateway(opts.platform),
        localAddress: (towards) => new Promise((resolve) => {
            const s = createSocket("udp4");
            s.on("error", () => {
                closeQuietly(s);
                resolve(null);
            });
            // connect() on UDP sends nothing: it only picks the route, and with it the source address
            s.connect(9, towards, () => {
                const a = s.address().address;
                closeQuietly(s);
                resolve(parseIPv4(a) && a !== "0.0.0.0" ? a : null);
            });
        }),
        udpRequest: (host, port, payload, timeoutsMs, accept) => new Promise((resolve) => {
            const s = createSocket("udp4");
            let timer = null;
            let done = false;
            const finish = (v) => {
                if (done)
                    return;
                done = true;
                if (timer)
                    clearTimeout(timer);
                closeQuietly(s);
                resolve(v);
            };
            s.on("error", () => finish(null));
            s.on("message", (msg, rinfo) => {
                if (rinfo.address !== host || rinfo.port !== port)
                    return;
                const b = new Uint8Array(msg.buffer, msg.byteOffset, msg.byteLength);
                if (!accept || accept(b))
                    finish(b);
            });
            let i = 0;
            const send = () => {
                if (done)
                    return;
                if (i >= timeoutsMs.length)
                    return finish(null);
                s.send(payload, port, host, (err) => {
                    if (err)
                        finish(null);
                });
                timer = setTimeout(send, timeoutsMs[i++]);
            };
            s.bind(0, send);
        }),
        ssdpSearch: (targets, waitMs, localAddress, preferFrom) => new Promise((resolve) => {
            const s = createSocket({ type: "udp4", reuseAddr: true });
            const answers = [];
            const timers = [];
            let done = false;
            const finish = () => {
                if (done)
                    return;
                done = true;
                for (const t of timers)
                    clearTimeout(t);
                closeQuietly(s);
                resolve(answers);
            };
            s.on("error", finish);
            s.on("message", (msg, rinfo) => {
                answers.push({ from: rinfo.address, message: msg.toString("utf8") });
                if (preferFrom && rinfo.address === preferFrom)
                    timers.push(setTimeout(finish, 250)); // the stragglers
            });
            const sendAll = () => {
                if (done)
                    return;
                for (const t of targets)
                    s.send(t.payload, t.port, t.host, () => { });
            };
            s.bind(0, () => {
                try {
                    s.setMulticastTTL(2);
                    if (localAddress)
                        s.setMulticastInterface(localAddress);
                }
                catch {
                    // keep the defaults
                }
                sendAll();
                timers.push(setTimeout(sendAll, Math.min(500, waitMs / 3))); // UDP: once more
                timers.push(setTimeout(finish, waitMs));
            });
        }),
        http: (req) => new Promise((resolve, reject) => {
            const u = new URL(req.url);
            const body = req.body !== undefined ? Buffer.from(req.body, "utf8") : undefined;
            const r = (u.protocol === "https:" ? httpsRequest : httpRequest)(u, {
                method: req.method,
                agent: false,
                headers: { ...req.headers, Connection: "close", ...(body ? { "Content-Length": String(body.length) } : {}) },
                timeout: req.timeoutMs,
                ...(u.protocol === "https:" ? { rejectUnauthorized: false } : {}), // LAN devices: self-signed, if at all
            }, (res) => {
                const chunks = [];
                let size = 0;
                res.on("data", (c) => {
                    size += c.length;
                    if (size > MAX_HTTP_BODY) {
                        r.destroy(new Error("response too large"));
                        return;
                    }
                    chunks.push(c);
                });
                res.on("end", () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8") }));
                res.on("error", reject);
            });
            r.on("timeout", () => r.destroy(new Error(`timed out after ${req.timeoutMs} ms`)));
            r.on("error", reject);
            r.end(body);
        }),
    };
}
