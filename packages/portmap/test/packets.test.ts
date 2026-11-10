import assert from "node:assert/strict";
import { test } from "node:test";
import {
  classifyIPv4,
  escapeXml,
  ipv4Mapped,
  isPublicIPv4,
  parseDeviceDescription,
  parsePcpResponse,
  parsePmpExternalAddress,
  parsePmpMapResponse,
  parseProcNetRoute,
  parseRouteGetDefault,
  parseRoutePrint,
  parseSoapResponse,
  parseSsdpResponse,
  pcpAnnounceRequest,
  pcpMapRequest,
  pmpExternalAddressRequest,
  pmpMapRequest,
  soapEnvelope,
  soapHeaders,
  ssdpSearchMessage,
  xmlText,
} from "../src/index.js";
import { LOCATION, SAGEMCOM_DESCRIPTION } from "./fake.js";

test("address classes: public, private, CGNAT, unspecified, reserved", () => {
  assert.equal(classifyIPv4("93.184.216.34"), "public");
  assert.equal(classifyIPv4("8.8.8.8"), "public");
  assert.equal(classifyIPv4("10.1.2.3"), "private");
  assert.equal(classifyIPv4("172.16.0.1"), "private");
  assert.equal(classifyIPv4("172.32.0.1"), "public");
  assert.equal(classifyIPv4("192.168.50.1"), "private");
  assert.equal(classifyIPv4("100.64.0.1"), "cgnat");
  assert.equal(classifyIPv4("100.127.255.255"), "cgnat");
  assert.equal(classifyIPv4("100.128.0.1"), "public");
  assert.equal(classifyIPv4("0.0.0.0"), "unspecified");
  assert.equal(classifyIPv4("127.0.0.1"), "loopback");
  assert.equal(classifyIPv4("169.254.1.1"), "link-local");
  assert.equal(classifyIPv4("224.0.0.1"), "reserved");
  assert.equal(classifyIPv4("203.0.113.9"), "reserved");
  assert.equal(classifyIPv4("256.1.1.1"), null);
  assert.equal(classifyIPv4(""), null);
  assert.equal(isPublicIPv4("1.1.1.1"), true);
  assert.equal(isPublicIPv4("100.100.1.1"), false);
});

test("NAT-PMP: the external address and map requests / responses (RFC 6886)", () => {
  assert.deepEqual([...pmpExternalAddressRequest()], [0, 0]);
  assert.deepEqual(
    [...pmpMapRequest("tcp", 47820, 47820, 7200)],
    [0, 2, 0, 0, 0xba, 0xcc, 0xba, 0xcc, 0, 0, 0x1c, 0x20],
  );
  assert.deepEqual([...pmpMapRequest("udp", 1, 0, 0)], [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
  assert.deepEqual(parsePmpExternalAddress(Uint8Array.of(0, 128, 0, 0, 0, 0, 0, 5, 93, 184, 216, 34)), { result: 0, epoch: 5, address: "93.184.216.34" });
  assert.deepEqual(parsePmpExternalAddress(Uint8Array.of(0, 128, 0, 3, 0, 0, 0, 5)), { result: 3, epoch: 0, address: "" });
  assert.equal(parsePmpExternalAddress(Uint8Array.of(0, 129, 0, 0)), null);
  assert.deepEqual(
    parsePmpMapResponse(Uint8Array.of(0, 130, 0, 0, 0, 0, 0, 7, 0xba, 0xcc, 0xba, 0xcd, 0, 0, 0x0e, 0x10), "tcp"),
    { result: 0, epoch: 7, internalPort: 47820, externalPort: 47821, lifetime: 3600 },
  );
  assert.equal(parsePmpMapResponse(Uint8Array.of(0, 129, 0, 0), "tcp"), null, "a UDP answer isn't the TCP one");
});

test("PCP: MAP and ANNOUNCE requests, responses, and a NAT-PMP gateway's answer (RFC 6887)", () => {
  assert.deepEqual([...ipv4Mapped("192.168.50.151")], [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 50, 151]);
  assert.deepEqual([...ipv4Mapped("")].slice(10), [0xff, 0xff, 0, 0, 0, 0]);
  const a = pcpAnnounceRequest("192.168.50.151");
  assert.equal(a.length, 24);
  assert.deepEqual([...a.slice(0, 8)], [2, 0, 0, 0, 0, 0, 0, 0]);
  const nonce = Uint8Array.from({ length: 12 }, (_, i) => i + 1);
  const m = pcpMapRequest({ nonce, protocol: "tcp", internalPort: 47820, externalPort: 47820, lifetime: 7200, clientAddress: "192.168.50.151" });
  assert.equal(m.length, 60);
  assert.deepEqual([...m.slice(0, 8)], [2, 1, 0, 0, 0, 0, 0x1c, 0x20]);
  assert.deepEqual([...m.slice(20, 24)], [192, 168, 50, 151]);
  assert.deepEqual([...m.slice(24, 36)], [...nonce]);
  assert.equal(m[36], 6);
  assert.deepEqual([...m.slice(40, 44)], [0xba, 0xcc, 0xba, 0xcc]);
  assert.deepEqual([...m.slice(54, 60)], [0xff, 0xff, 0, 0, 0, 0]);
  assert.throws(() => pcpMapRequest({ nonce: new Uint8Array(4), protocol: "tcp", internalPort: 1, externalPort: 1, lifetime: 1, clientAddress: "" }));

  const r = new Uint8Array(60);
  r[0] = 2;
  r[1] = 0x81;
  r[3] = 0;
  const v = new DataView(r.buffer);
  v.setUint32(4, 3600);
  v.setUint32(8, 42);
  r.set(nonce, 24);
  r[36] = 6;
  v.setUint16(40, 47820);
  v.setUint16(42, 50000);
  r.set([0xff, 0xff, 93, 184, 216, 34], 54);
  const p = parsePcpResponse(r)!;
  assert.equal(p.version, 2);
  assert.equal(p.result, 0);
  assert.equal(p.lifetime, 3600);
  assert.equal(p.epoch, 42);
  assert.equal(p.map!.externalPort, 50000);
  assert.equal(p.map!.externalAddress, "93.184.216.34");
  assert.deepEqual([...p.map!.nonce], [...nonce]);

  assert.deepEqual(parsePcpResponse(Uint8Array.of(0, 0x81, 0, 1, 0, 0, 0, 0)), { version: 0, opcode: 1, result: 1, lifetime: 0, epoch: 0 });
  assert.equal(parsePcpResponse(Uint8Array.of(2, 1, 0, 0)), null, "a request isn't a response");
});

test("SSDP: the search message and parsing an answer", () => {
  const msg = ssdpSearchMessage("urn:schemas-upnp-org:device:InternetGatewayDevice:1");
  assert.match(msg, /^M-SEARCH \* HTTP\/1\.1\r\nHOST: 239\.255\.255\.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n$/);
  const r = parseSsdpResponse(`HTTP/1.1 200 OK\r\nCache-Control: max-age=1800\r\nLocation: ${LOCATION}\r\nServer: x\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\nUSN: uuid:1\r\n\r\n`);
  assert.deepEqual(r, { location: LOCATION, st: "urn:schemas-upnp-org:device:InternetGatewayDevice:1", server: "x", usn: "uuid:1" });
  assert.equal(parseSsdpResponse("NOTIFY * HTTP/1.1\r\nLOCATION: http://x/\r\n\r\n"), null);
  assert.equal(parseSsdpResponse("HTTP/1.1 200 OK\r\nLOCATION: file:///etc/passwd\r\n\r\n"), null);
});

test("device description: the WAN connection service with an absolute control URL", () => {
  assert.deepEqual(parseDeviceDescription(SAGEMCOM_DESCRIPTION, LOCATION), [
    { serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1", controlURL: "http://192.168.50.1:49152/47495533/upnp/control/WANIPConn1", location: LOCATION },
  ]);
  const two = `<root><URLBase>http://10.0.0.1:5000/</URLBase><device><serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType><controlURL>ppp</controlURL></service>
    <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType><controlURL>/ctl/IPConn</controlURL></service>
  </serviceList></device></root>`;
  assert.deepEqual(
    parseDeviceDescription(two, "http://10.0.0.1:1900/rootDesc.xml").map((s) => s.controlURL),
    ["http://10.0.0.1:5000/ctl/IPConn", "http://10.0.0.1:5000/ppp"],
  );
});

test("SOAP: the envelope, the headers, a response's values and a UPnP fault", () => {
  const st = "urn:schemas-upnp-org:service:WANIPConnection:1";
  const env = soapEnvelope(st, "AddPortMapping", [["NewExternalPort", 47820], ["NewPortMappingDescription", "a<b>&\"c'"]]);
  assert.match(env, /<u:AddPortMapping xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1"><NewExternalPort>47820<\/NewExternalPort><NewPortMappingDescription>a&lt;b&gt;&amp;&quot;c&apos;<\/NewPortMappingDescription><\/u:AddPortMapping>/);
  assert.equal(xmlText(env, "NewPortMappingDescription"), `a<b>&"c'`);
  assert.equal(escapeXml("<&>"), "&lt;&amp;&gt;");
  assert.deepEqual(soapHeaders(st, "GetExternalIPAddress"), { "Content-Type": 'text/xml; charset="utf-8"', SOAPAction: `"${st}#GetExternalIPAddress"` });
  assert.deepEqual(
    parseSoapResponse(200, `<s:Envelope><s:Body><u:GetExternalIPAddressResponse xmlns:u="${st}"><NewExternalIPAddress>93.184.216.34</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>`, "GetExternalIPAddress", ["NewExternalIPAddress"]),
    { ok: true, values: { NewExternalIPAddress: "93.184.216.34" } },
  );
  assert.deepEqual(parseSoapResponse(200, `<s:Body><m:DeletePortMappingResponse xmlns:m="${st}"/></s:Body>`, "DeletePortMapping"), { ok: true, values: {} });
  assert.deepEqual(
    parseSoapResponse(500, `<s:Fault><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>718</errorCode><errorDescription>ConflictInMappingEntry</errorDescription></UPnPError></detail></s:Fault>`, "AddPortMapping"),
    { ok: false, code: 718, description: "ConflictInMappingEntry" },
  );
  assert.deepEqual(parseSoapResponse(500, `<errorCode>725</errorCode>`, "AddPortMapping"), { ok: false, code: 725, description: "only permanent leases supported" });
  assert.deepEqual(parseSoapResponse(404, "", "AddPortMapping"), { ok: false, code: null, description: "HTTP 404" });
});

test("the default gateway from route(8) and /proc/net/route", () => {
  assert.equal(parseRouteGetDefault("   route to: default\ndestination: default\n       mask: default\n    gateway: 192.168.50.1\n  interface: en0\n"), "192.168.50.1");
  assert.equal(parseRouteGetDefault("    gateway: link#22\n"), null);
  assert.equal(parseRouteGetDefault(""), null);
  const proc = [
    "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT",
    "wlan0\t00000000\t0132A8C0\t0003\t0\t0\t600\t00000000\t0\t0\t0",
    "eth0\t00000000\t0100000A\t0003\t0\t0\t100\t00000000\t0\t0\t0",
    "eth0\t0000000A\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0",
  ].join("\n");
  assert.equal(parseProcNetRoute(proc), "10.0.0.1");
  assert.equal(parseProcNetRoute(proc.split("\n").slice(0, 2).join("\n")), "192.168.50.1");
  assert.equal(parseProcNetRoute("Iface\tDestination\n"), null);
});

test("parseRoutePrint: Windows' active default route with the lowest metric; on-link and persistent rows skipped", () => {
  const out = [
    "===========================================================================",
    "活动路由:",
    "网络目标        网络掩码          网关       接口   跃点数",
    "          0.0.0.0          0.0.0.0     192.168.50.1     192.168.50.10     25",
    "          0.0.0.0          0.0.0.0       10.8.0.1        10.8.0.6     281",
    "          0.0.0.0          0.0.0.0            在链路上       100.64.0.2      5",
    "===========================================================================",
    "永久路由:",
    "  网络地址          网络掩码  网关地址  跃点数",
    "          0.0.0.0          0.0.0.0      192.168.9.1  默认",
  ].join("\r\n");
  assert.equal(parseRoutePrint(out), "192.168.50.1");
  assert.equal(parseRoutePrint("          0.0.0.0          0.0.0.0          On-link      100.64.0.2      5\r\n"), null);
  assert.equal(parseRoutePrint(""), null);
});
