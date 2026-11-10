// A fake home network for the PortMapping tests: one gateway that speaks any of UPnP IGD / NAT-PMP / PCP, a manual clock.

import type { Clock, HttpRequest, HttpResponse, Network, UdpTarget } from "../src/index.js";
import { parsePcpResponse, xmlText } from "../src/index.js";

export const GATEWAY = "192.168.50.1";
export const ME = "192.168.50.151";
export const LOCATION = `http://${GATEWAY}:49152/47495533/gatedesc0b.xml`;

export const SAGEMCOM_DESCRIPTION = `<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
    <friendlyName>Giga Hub 4000E Internet Gateway Device</friendlyName>
    <deviceList><device>
      <deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
      <serviceList><service>
        <serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:WANCommonIFC1</serviceId>
        <controlURL>/47495533/upnp/control/WANCommonIFC1</controlURL>
      </service></serviceList>
      <deviceList><device>
        <deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>
        <serviceList><service>
          <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
          <serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
          <controlURL>/47495533/upnp/control/WANIPConn1</controlURL>
          <eventSubURL>/47495533/upnp/control/WANIPConn1</eventSubURL>
          <SCPDURL>/47495533/wanipconnSCPD.xml</SCPDURL>
        </service></serviceList>
      </device></deviceList>
    </device></deviceList>
  </device>
</root>`;

export interface Entry {
  internalClient: string;
  internalPort: number;
  description: string;
  lifetime: number;
}

export interface FakeOptions {
  upnp?: boolean;
  pmp?: boolean;
  pcp?: boolean;
  /** PCP requests answered NAT-PMP style ("unsupported version"), like a NAT-PMP-only gateway */
  pcpAsPmp?: boolean;
  externalAddress?: string;
  /** UPnP: AddPortMapping fails with this code for these external ports */
  refuse?: Map<number, number>;
  /** UPnP: every AddPortMapping with a lease ≠ 0 fails 725 */
  permanentOnly?: boolean;
  /** UPnP: AddPortMapping with external ≠ internal fails 724 */
  samePortOnly?: boolean;
  /** UPnP: AddPortMapping fails 606 */
  readOnly?: boolean;
  /** NAT-PMP / PCP: the port they hand out instead of the suggested one */
  assignPort?: number;
  /** granted lifetime for NAT-PMP / PCP (default: what was asked) */
  grantLifetime?: number;
}

export class FakeRouter implements Network {
  gatewayAddress: string | null = GATEWAY;
  me = ME;
  upnp: Map<string, Entry> = new Map(); // "TCP:47820"
  pmp: Map<number, { internal: number; lifetime: number }> = new Map();
  pcp: Map<number, { internal: number; lifetime: number; nonce: string }> = new Map();
  calls: string[] = [];
  /** runs before each SOAP action is answered */
  hook: ((action: string) => void) | null = null;

  constructor(public opts: FakeOptions = {}) {}

  get externalAddress(): string {
    return this.opts.externalAddress ?? "93.184.216.34";
  }

  async gateway(): Promise<string | null> {
    return this.gatewayAddress;
  }

  async localAddress(towards: string): Promise<string | null> {
    return towards === this.gatewayAddress ? this.me : null;
  }

  async ssdpSearch(targets: UdpTarget[]): Promise<Array<{ from: string; message: string }>> {
    this.calls.push(`ssdp ${targets.length}`);
    if (!this.opts.upnp || !this.gatewayAddress) return [];
    return [
      {
        from: this.gatewayAddress,
        message: `HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: ${LOCATION}\r\nSERVER: Linux/4.1 UPnP/1.0 Portable SDK for UPnP devices/1.14.12\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\nUSN: uuid:x::urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n`,
      },
    ];
  }

  async http(req: HttpRequest): Promise<HttpResponse> {
    if (!this.opts.upnp || !this.gatewayAddress || new URL(req.url).hostname !== this.gatewayAddress) throw new Error("ECONNREFUSED");
    if (req.method === "GET") return req.url === LOCATION ? { status: 200, body: SAGEMCOM_DESCRIPTION } : { status: 404, body: "" };
    const action = /#(\w+)"$/.exec(req.headers["SOAPAction"] ?? "")?.[1] ?? "";
    const body = req.body ?? "";
    const arg = (n: string) => xmlText(body, n) ?? "";
    this.calls.push(`upnp ${action} ${arg("NewExternalPort")}`.trim());
    this.hook?.(action);
    const ok = (inner = "") => ({
      status: 200,
      body: `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:${action}Response xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">${inner}</u:${action}Response></s:Body></s:Envelope>`,
    });
    const fault = (code: number, desc: string) => ({
      status: 500,
      body: `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>${code}</errorCode><errorDescription>${desc}</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>`,
    });
    const key = `${arg("NewProtocol")}:${arg("NewExternalPort")}`;
    switch (action) {
      case "GetExternalIPAddress":
        return ok(`<NewExternalIPAddress>${this.externalAddress}</NewExternalIPAddress>`);
      case "GetSpecificPortMappingEntry": {
        const e = this.upnp.get(key);
        if (!e) return fault(714, "NoSuchEntryInArray");
        return ok(`<NewInternalPort>${e.internalPort}</NewInternalPort><NewInternalClient>${e.internalClient}</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>${e.description}</NewPortMappingDescription><NewLeaseDuration>${e.lifetime}</NewLeaseDuration>`);
      }
      case "AddPortMapping": {
        const ext = Number(arg("NewExternalPort"));
        const lease = Number(arg("NewLeaseDuration"));
        if (this.opts.readOnly) return fault(606, "Action not authorized");
        const refuse = this.opts.refuse?.get(ext);
        if (refuse) return fault(refuse, "refused");
        if (this.opts.permanentOnly && lease !== 0) return fault(725, "OnlyPermanentLeasesSupported");
        if (this.opts.samePortOnly && ext !== Number(arg("NewInternalPort"))) return fault(724, "SamePortValuesRequired");
        const prev = this.upnp.get(key);
        if (prev && prev.internalClient !== arg("NewInternalClient")) return fault(718, "ConflictInMappingEntry");
        this.upnp.set(key, { internalClient: arg("NewInternalClient"), internalPort: Number(arg("NewInternalPort")), description: arg("NewPortMappingDescription"), lifetime: lease });
        return ok();
      }
      case "DeletePortMapping":
        if (!this.upnp.delete(key)) return fault(714, "NoSuchEntryInArray");
        return ok();
      default:
        return fault(401, "Invalid Action");
    }
  }

  async udpRequest(host: string, port: number, payload: Uint8Array, _t: number[], accept?: (m: Uint8Array) => boolean): Promise<Uint8Array | null> {
    if (host !== this.gatewayAddress || port !== 5351) return null;
    const answer = this.pmpAnswer(payload);
    if (!answer) return null;
    return !accept || accept(answer) ? answer : null;
  }

  private pmpAnswer(p: Uint8Array): Uint8Array | null {
    const v = new DataView(p.buffer, p.byteOffset, p.byteLength);
    if (p[0] === 2) {
      // PCP
      if (this.opts.pcpAsPmp && this.opts.pmp) {
        const b = new Uint8Array(8);
        b[1] = 128 + (p[1]! & 0x7f);
        new DataView(b.buffer).setUint16(2, 1);
        return b;
      }
      if (!this.opts.pcp) return null;
      const opcode = p[1]! & 0x7f;
      const lifetime = v.getUint32(4);
      const b = new Uint8Array(opcode === 1 ? 60 : 24);
      const o = new DataView(b.buffer);
      b[0] = 2;
      b[1] = 0x80 | opcode;
      o.setUint32(8, 1234);
      if (opcode === 1) {
        const nonce = Buffer.from(p.slice(24, 36)).toString("hex");
        const internal = v.getUint16(40);
        const suggested = v.getUint16(42);
        let ext = this.opts.assignPort ?? suggested;
        if (lifetime === 0) {
          for (const [k, m] of this.pcp) if (m.internal === internal && m.nonce === nonce) this.pcp.delete(k);
          ext = 0;
        } else {
          this.pcp.set(ext, { internal, lifetime: this.opts.grantLifetime ?? lifetime, nonce });
        }
        this.calls.push(`pcp map ${internal}→${ext} ${lifetime}`);
        o.setUint32(4, lifetime === 0 ? 0 : this.opts.grantLifetime ?? lifetime);
        b.set(p.slice(24, 40), 24);
        o.setUint16(40, internal);
        o.setUint16(42, ext);
        b[54] = 0xff;
        b[55] = 0xff;
        b.set(this.externalAddress.split(".").map(Number), 56);
      } else {
        this.calls.push("pcp announce");
      }
      return b;
    }
    if (p[0] !== 0 || !this.opts.pmp) return null;
    if (p[1] === 0) {
      this.calls.push("pmp address");
      const b = new Uint8Array(12);
      b[1] = 128;
      new DataView(b.buffer).setUint32(4, 99);
      b.set(this.externalAddress.split(".").map(Number), 8);
      return b;
    }
    const internal = v.getUint16(4);
    const suggested = v.getUint16(6);
    const lifetime = v.getUint32(8);
    const b = new Uint8Array(16);
    const o = new DataView(b.buffer);
    b[1] = 128 + p[1]!;
    o.setUint32(4, 99);
    o.setUint16(8, internal);
    if (lifetime === 0) {
      for (const [k, m] of this.pmp) if (m.internal === internal) this.pmp.delete(k);
      this.calls.push(`pmp delete ${internal}`);
      return b;
    }
    const ext = this.opts.assignPort ?? suggested;
    const granted = this.opts.grantLifetime ?? lifetime;
    this.pmp.set(ext, { internal, lifetime: granted });
    this.calls.push(`pmp map ${internal}→${ext} ${lifetime}`);
    o.setUint16(10, ext);
    o.setUint32(12, granted);
    return b;
  }
}

/** A manual clock: timers run when advance() passes them. */
export class FakeClock implements Clock {
  t = 1_000_000;
  private timers: Array<{ at: number; fn: () => void; id: number }> = [];
  private next = 1;

  now(): number {
    return this.t;
  }

  setTimeout(fn: () => void, ms: number): unknown {
    const id = this.next++;
    this.timers.push({ at: this.t + ms, fn, id });
    return id;
  }

  clearTimeout(h: unknown): void {
    this.timers = this.timers.filter((x) => x.id !== h);
  }

  get pending(): number[] {
    return this.timers.map((x) => x.at - this.t).sort((a, b) => a - b);
  }

  advance(ms: number): void {
    this.t += ms;
    const due = this.timers.filter((x) => x.at <= this.t);
    this.timers = this.timers.filter((x) => x.at > this.t);
    for (const d of due) d.fn();
  }
}

export async function settle(): Promise<void> {
  for (let i = 0; i < 50; i++) await new Promise((r) => setImmediate(r));
}

export { parsePcpResponse };
