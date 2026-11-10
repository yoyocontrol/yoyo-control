# @yoyocontrol/portmap

Asks the home router to forward a public port to a local listener — **PCP** (RFC 6887), **NAT-PMP** (RFC 6886) or
**UPnP IGD** (WANIPConnection / WANPPPConnection) — keeps the lease alive, finds the public address, and removes the
mapping again. Node ≥ 22, ESM, typed, no dependencies.

```js
import { PortMapping } from "@yoyocontrol/portmap";

const m = new PortMapping({
  internalPort: 47820,               // the local listener (TCP by default; protocol: "udp")
  externalPort: saved ?? undefined,  // the public port to ask for (default: internalPort)
  description: "My Server",          // what the router's port forwarding page shows (UPnP)
  onChange: (s) => {},               // status changes (renewals that change nothing don't count)
  log: (line) => console.log(line),
});
const s = await m.start();           // keeps running until stop()
if (s.status === "mapped") publish(`${s.externalAddress}:${s.externalPort}`), saved = s.externalPort;
// … on a network change: await m.refresh();
process.once("SIGTERM", async () => { await m.stop(); process.exit(0); });   // deletes the mapping
```

## What it does

- **Which mechanism**: PCP, then NAT-PMP, then UPnP (`methods` to limit / reorder); the first that maps wins. UPnP's
  SSDP search (multicast, and unicast to the default gateway) runs while PCP / NAT-PMP wait for an answer
  (250 / 500 / 1000 ms each). A renewal asks the mechanism holding the mapping first.
- **Ports**: asks for `externalPort` (default `internalPort`). UPnP: an external port that another host holds
  (`GetSpecificPortMappingEntry`) or that the router refuses (718 / 729 / 501) is skipped for up to `portAttempts` (6)
  others; a stale mapping of this host on the same port is taken over; 724 (`SamePortValuesRequired`) leaves only
  `internalPort`. PCP / NAT-PMP pick a free port themselves. Persist `state.externalPort` and pass it back so the public
  address stays the same across restarts.
- **Leases**: `lifetime` (default 7200 s), renewed at half of what the router granted. A UPnP router that only allows
  permanent mappings (725) gets lease 0, re-added every 20 min (survives router reboots) and deleted by `stop()`.
- **Reachability**: an external address that isn't public — RFC 1918 (a second router in front), 100.64/10 (carrier NAT),
  0.0.0.0 (WAN down) — makes the state `unreachable` with that `reason`, and the mapping is deleted at once: a hole in an
  inner NAT is useless. Port mapping can't punch through those; something else must (a relay, hole punching).
- **Retries**: `unsupported` (nothing answered) every 5 min, `failed` (a router refused) after 1 → 30 min (doubling),
  `unreachable` every 30 min; `refresh()` now. The library doesn't watch the network: call `refresh()` when it changes.
- **Cleanup**: `stop()` deletes the mapping (each mechanism's own way) and stops the timers; a `stop()` that arrives
  during an attempt removes what that attempt made. Timers are `unref`'d: a mapping never keeps the process alive, so
  call `stop()` before exiting — a mapping left behind lapses by its lease (except a permanent UPnP one).

## States

```ts
{ status: "idle" }                                   // before start() / after stop()
{ status: "probing" }
{ status: "mapped", method: "pcp" | "natpmp" | "upnp", protocol, externalAddress, externalPort,
  internalAddress, internalPort, lifetime /* s, 0 = permanent */, since }
{ status: "unreachable", method, externalAddress, reason: "private" | "cgnat" | "unspecified" | …, since }
{ status: "unsupported", since }                     // no PCP / NAT-PMP / UPnP gateway on this network
{ status: "failed", method?, error, since }          // e.g. "UPnP AddPortMapping: 606 Action not authorized"
```

## Lower level

- `probe()` — what the network offers (gateway, this host's address, PCP / NAT-PMP / UPnP and their external
  addresses), without mapping anything.
- UPnP: `discoverWanServices`, `getExternalIPAddress`, `addPortMapping`, `deletePortMapping`,
  `getSpecificPortMappingEntry`; the pure parts `ssdpSearchMessage`, `parseSsdpResponse`, `parseDeviceDescription`,
  `soapEnvelope`, `parseSoapResponse`.
- NAT-PMP / PCP packets: `pmpExternalAddressRequest`, `pmpMapRequest`, `parsePmp*`, `pcpMapRequest`,
  `pcpAnnounceRequest`, `parsePcpResponse`.
- `classifyIPv4` / `isPublicIPv4`.
- Everything that touches the network goes through a `Network` (`nodeNetwork()` is the real one: dgram, http, the
  default gateway from `route -n get default` on macOS / BSD or `/proc/net/route` on Linux), and timers through a
  `Clock`: tests inject fakes (`test/fake.ts` is a router speaking all three).

## Security notes

A mapping exposes the listener to the whole internet. The listener must authenticate every connection itself
(uu Link: a pinned identity, tokens), bound unauthenticated connections and rate-limit failures per source address.

## Development

```sh
npm -w packages/portmap test        # unit tests against a fake router
scripts/git-dist.sh portmap 0.1.1   # publish (bump the version first)
```
