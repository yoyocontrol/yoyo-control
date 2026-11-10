// A WebRTC stand-in for the unit tests: an RTCPeerConnection whose data channels are wired to a scripted server in the
// same process (the §2 contract: negotiated `control` id 0 / `dgram` id 1, in-band `rpc` channels), and a signing
// identity for its answers. The end-to-end test against a real server runs in a real browser (test/e2e/).

import { encodeFrame, FrameReader, messageBytes, rtcSignedText } from "../src/index.js";

export class FakeChannel extends EventTarget {
  readyState: RTCDataChannelState = "connecting";
  bufferedAmount = 0;
  binaryType: BinaryType = "arraybuffer";
  peer: FakeChannel | null = null;
  sent: Uint8Array[] = [];

  constructor(
    readonly label: string,
    readonly id: number | null,
    readonly ordered = true,
  ) {
    super();
  }

  send(data: string | ArrayBuffer | ArrayBufferView | Blob): void {
    if (this.readyState !== "open") throw new Error("InvalidStateError: not open");
    const bytes = messageBytes(data).slice();
    this.sent.push(bytes);
    const peer = this.peer;
    queueMicrotask(() => {
      if (peer && peer.readyState === "open") peer.dispatchEvent(new MessageEvent("message", { data: bytes.buffer }));
    });
  }

  open(): void {
    if (this.readyState !== "connecting") return;
    this.readyState = "open";
    this.dispatchEvent(new Event("open"));
  }

  close(): void {
    if (this.readyState === "closed") return;
    this.readyState = "closed";
    queueMicrotask(() => this.dispatchEvent(new Event("close")));
    const peer = this.peer;
    if (peer && peer.readyState !== "closed") queueMicrotask(() => peer.close());
  }
}

/** The server half: what a test scripts. */
export interface FakeServer {
  /** The negotiated channels' server ends, when the connection is up. */
  connected(control: FakeChannel, dgram: FakeChannel): void;
  /** A channel the client opened in-band (`rpc`). */
  channel?(ch: FakeChannel): void;
}

export class FakePeerConnection extends EventTarget {
  localDescription: RTCSessionDescriptionInit | null = null;
  iceGatheringState: RTCIceGatheringState = "new";
  connectionState: RTCPeerConnectionState = "new";
  readonly channels: FakeChannel[] = [];
  private serverEnds = new Map<number, FakeChannel>();
  stats: Record<string, unknown>[] = [
    { id: "T1", type: "transport", selectedCandidatePairId: "CP1" },
    { id: "CP1", type: "candidate-pair", localCandidateId: "L1", remoteCandidateId: "R1", currentRoundTripTime: 0.012, bytesSent: 100, bytesReceived: 200 },
    { id: "L1", type: "local-candidate", candidateType: "host", address: "192.168.1.20", port: 50000 },
    { id: "R1", type: "remote-candidate", candidateType: "host", address: "192.168.1.10", port: 47821 },
  ];

  constructor(
    readonly server: FakeServer,
    readonly config: RTCConfiguration,
  ) {
    super();
  }

  createDataChannel(label: string, init: RTCDataChannelInit = {}): FakeChannel {
    const ch = new FakeChannel(label, init.negotiated ? (init.id ?? null) : null, init.ordered ?? true);
    this.channels.push(ch);
    if (init.negotiated && init.id !== undefined) {
      const s = new FakeChannel(label, init.id, init.ordered ?? true);
      ch.peer = s;
      s.peer = ch;
      this.serverEnds.set(init.id, s);
    } else if (this.connectionState === "connected") {
      queueMicrotask(() => this.openInBand(ch));
    }
    return ch;
  }

  private openInBand(ch: FakeChannel): void {
    const s = new FakeChannel(ch.label, null, ch.ordered);
    ch.peer = s;
    s.peer = ch;
    s.readyState = "open";
    this.server.channel?.(s);
    ch.open();
  }

  async createOffer(): Promise<RTCSessionDescriptionInit> {
    return { type: "offer", sdp: "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\na=fingerprint:sha-256 AA:BB\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" };
  }

  async setLocalDescription(d: RTCSessionDescriptionInit): Promise<void> {
    this.localDescription = { ...d, sdp: `${d.sdp}a=candidate:1 1 udp 2122260223 192.168.1.20 50000 typ host\r\n` };
    this.iceGatheringState = "complete";
    this.dispatchEvent(new Event("icegatheringstatechange"));
  }

  async setRemoteDescription(_d: RTCSessionDescriptionInit): Promise<void> {
    queueMicrotask(() => {
      this.connectionState = "connected";
      this.dispatchEvent(new Event("connectionstatechange"));
      const control = this.serverEnds.get(0)!;
      const dgram = this.serverEnds.get(1)!;
      control.readyState = "open";
      dgram.readyState = "open";
      this.server.connected(control, dgram);
      for (const ch of this.channels) ch.open();
    });
  }

  async getStats(): Promise<RTCStatsReport> {
    return new Map(this.stats.map((s) => [s.id as string, s])) as unknown as RTCStatsReport;
  }

  close(): void {
    if (this.connectionState === "closed") return;
    this.connectionState = "closed";
    for (const ch of this.channels) ch.close();
    this.dispatchEvent(new Event("connectionstatechange"));
  }
}

/** A computer's P-256 identity: its binding key, fingerprint, and a signer of rtc answers. */
export class Identity {
  private constructor(
    private readonly keys: CryptoKeyPair,
    readonly publicKey: Uint8Array,
    readonly fingerprint: string,
  ) {}

  static async create(): Promise<Identity> {
    const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const raw = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
    const fp = Buffer.from(await crypto.subtle.digest("SHA-256", raw)).toString("hex");
    return new Identity(keys, raw, `sha256:${fp}`);
  }

  /** A signed answer to `offerSdp` (with `dtls` as the answer's certificate fingerprint, bare hex). */
  async answer(offerSdp: string, dtls = "ab".repeat(32), opts: { sdpFingerprint?: string } = {}): Promise<Record<string, unknown>> {
    const fingerprint = `sha256:${dtls}`;
    const colon = (opts.sdpFingerprint ?? dtls).toUpperCase().match(/../g)!.join(":");
    const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, this.keys.privateKey, new TextEncoder().encode(await rtcSignedText(offerSdp, fingerprint))));
    return {
      v: 1,
      answer: `v=0\r\no=- 3 4 IN IP4 127.0.0.1\r\ns=-\r\na=fingerprint:sha-256 ${colon}\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n`,
      fingerprint,
      binding: { id: "00".repeat(32), key: Buffer.from(this.publicKey).toString("base64"), sig: Buffer.from(new Uint8Array(64)).toString("base64") },
      sig: Buffer.from(sig).toString("base64"),
    };
  }
}

/** A scripted server: answers `hello` (with `onHello`), records control messages, echoes app datagrams, serves RPC. */
export class ScriptedServer implements FakeServer {
  control: FakeChannel | null = null;
  dgram: FakeChannel | null = null;
  received: Record<string, unknown>[] = [];
  datagrams: Uint8Array[] = [];
  onHello: (hello: Record<string, unknown>, send: (m: object) => void) => void = (_h, send) =>
    send({ t: "welcome", v: 1, server: { id: "srv", name: "Test Mac", platform: "macos" }, principal: { device: { id: "d1", name: "Browser" } }, features: ["screen"], maxDatagram: 1200 });
  onControl: (m: Record<string, unknown>, send: (m: object) => void) => void = () => {};
  rpc: (head: Record<string, unknown>, body: Uint8Array, ch: FakeChannel) => void = (head, body, ch) => {
    ch.send(encodeFrame({ s: 200, h: { "content-type": "application/json" } }));
    ch.send(new TextEncoder().encode(JSON.stringify({ m: head.m, p: head.p, n: body.length })));
    ch.send(new Uint8Array(0));
  };
  private reader = new FrameReader();

  send = (m: object) => this.control?.send(encodeFrame(m));

  connected(control: FakeChannel, dgram: FakeChannel): void {
    this.control = control;
    this.dgram = dgram;
    control.addEventListener("message", (ev) => {
      for (const f of this.reader.push(messageBytes((ev as MessageEvent).data))) {
        this.received.push(f);
        if (f.t === "hello") this.onHello(f, this.send);
        else this.onControl(f, this.send);
      }
    });
    dgram.addEventListener("message", (ev) => {
      const d = messageBytes((ev as MessageEvent).data);
      this.datagrams.push(d);
      if (d[0]! >> 4 >= 6) dgram.send(d);
    });
  }

  channel(ch: FakeChannel): void {
    const reader = new FrameReader();
    let head: Record<string, unknown> | null = null;
    const body: Uint8Array[] = [];
    ch.addEventListener("message", (ev) => {
      const b = messageBytes((ev as MessageEvent).data);
      if (!head) {
        reader.append(b);
        head = reader.next();
        if (head) {
          const rest = reader.rest();
          if (rest.length) body.push(rest);
        }
        return;
      }
      if (b.length === 0) {
        const all = new Uint8Array(body.reduce((n, x) => n + x.length, 0));
        let at = 0;
        for (const x of body) {
          all.set(x, at);
          at += x.length;
        }
        this.rpc(head, all, ch);
        return;
      }
      body.push(b);
    });
  }
}
