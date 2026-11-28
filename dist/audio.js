import { AudioJitter, audioJitterConfig, AudioScheduler, audioSchedulerConfig } from "./audiobuffer.js";
import { AUDIO_ACCEPT, boundaryOf, DEFAULT_BOUNDARY, PartParser } from "./parts.js";
import { AudioPolicy } from "./status.js";
/**
 * The computer's sound on a screen page (docs/PROTOCOL.md「声音」): Opus packets (20 ms, 48 kHz stereo) — `POST /audio`
 * through the page's transport in the stream's multipart framing, or `audio.open` on a link (`ScreenAudioOptions.link`)
 * — → WebCodecs' AudioDecoder → a timed jitter buffer in an AudioWorklet (`AudioJitter` + `AudioScheduler`): each packet
 * is heard at its slot (its `X-Audio-Time` + the measured base delay + the depth), a gap in its seq is concealed with
 * silence, the depth follows the path's jitter and the A/V sync (`AVSyncDriver`). A browser without AudioDecoder or
 * AudioWorklet has no speaker. 404 / 403 / 501 = no sound here (not asked again this visit), 503 = can't capture now
 * (asked again in 30 s), any other end reopens (AudioPolicy).
 */
export const hasAudioDecoder = () => typeof AudioDecoder !== "undefined" && typeof EncodedAudioChunk !== "undefined" && typeof AudioWorkletNode !== "undefined";
/** The buffer's start depth on a remote path (ms; the LAN starts at `AUDIO_LAN_FLOOR_MS`). */
export const TARGET_MS = 120;
let wasmOpus = null;
function loadWasmOpus() {
    wasmOpus ??= import("opus-decoder").then((m) => m.OpusDecoder, () => null);
    return wasmOpus;
}
/** Opus packets here are 20 ms (960 frames at 48 kHz); gaps up to this many packets are concealed by libopus. */
export const AUDIO_PACKET_FRAMES = 960;
export const AUDIO_PLC_MAX_PACKETS = 5;
/** The decoder counts as stuck with this many packets in it and nothing out for this long (ms). */
export const AUDIO_DECODER_STUCK_PACKETS = 5;
export const AUDIO_DECODER_STUCK_MS = 150;
/** `X-Audio-Video-Offset` when the server doesn't say (ms). */
export const DEFAULT_VIDEO_OFFSET_MS = 31;
const RATE = 48_000;
/** How often the worklet reports its state (render quanta of 128 frames ≈ 2.7 ms). */
const REPORT_QUANTA = 32;
/** The worklet: `AudioScheduler`'s own source, run on the audio thread (`__name`: what a bundler keeping names may
 *  have put into that source). */
const WORKLET = `
const __name = (target) => target;
const Scheduler = (${AudioScheduler.toString()});
class YoyoTimedRing extends AudioWorkletProcessor {
  constructor(o) {
    super();
    this.s = new Scheduler(o.processorOptions.config);
    this.n = 0;
    this.port.onmessage = (e) => {
      const m = e.data;
      if (m.t === "packet") this.s.push(m.p);
      else if (m.t === "flush") { this.s.queue = []; this.s.pos = 0; this.s.playing = false; this.s.entered = false; this.s.expectedSeq = null; }
    };
  }
  process(_in, outs) {
    const out = outs[0]; const L = out[0]; const R = out[1] || out[0];
    this.s.render(L, R, currentFrame);
    if (++this.n >= ${REPORT_QUANTA}) { this.n = 0; this.port.postMessage({ frame: currentFrame, stats: this.s.stats }); }
    return true;
  }
}
registerProcessor("yoyo-timed-ring", YoyoTimedRing);
`;
/** `X-Audio-Cookie` as an Opus description: only an OpusHead (else the decoder's defaults for 48 kHz stereo). */
export function opusDescription(cookie) {
    if (!cookie)
        return undefined;
    try {
        const bin = atob(cookie.trim());
        const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
        return bin.startsWith("OpusHead") && bytes.length >= 19 ? bytes : undefined;
    }
    catch {
        return undefined;
    }
}
/** `X-Audio-Video-Offset` (ms, may be negative); missing, garbled or beyond ±2 s: DEFAULT_VIDEO_OFFSET_MS. */
export function videoOffsetMs(value) {
    const v = value === null || value === undefined || value.trim() === "" ? NaN : Number(value);
    return Number.isFinite(v) && Math.abs(v) <= 2000 ? v : DEFAULT_VIDEO_OFFSET_MS;
}
export class ScreenAudio {
    transport;
    onState;
    options;
    ctx = null;
    node = null;
    decoder = null;
    ctrl = null;
    linkStream = null;
    timer = null;
    policy = new AudioPolicy();
    on = false;
    gaveUp = false;
    ts = 0;
    generation = 0;
    pending = new Map();
    decoderConfig = null;
    /** The wasm decoder once it is ready (packets go there instead of `decoder`). */
    wasm = null;
    /** When the decoder last gave a packet out (its watchdog). */
    outputAt = 0;
    jitter = new AudioJitter(audioJitterConfig(false));
    lan = false;
    offset = DEFAULT_VIDEO_OFFSET_MS;
    worklet = null;
    lastUnderruns = 0;
    // diagnostics for the report (`AudioReport.arrivalGapMaxMs`…), reset by each report
    diag = { lastArrival: null, lastPlayed: null, arrivalGapMax: 0, decodedGapMax: 0, concealed: 0, underrunsAt: [], overflow: 0, metaMissing: 0, decoderResets: 0 };
    /** The last packet's seq (the wasm decoder conceals the ones missing before the next). */
    lastSeq = null;
    soundAt = -Infinity;
    bytes = [];
    syncReport = { skewMs: null, floorMs: null };
    reported = null;
    seq = 0;
    /** `options` (additive): a link to open the sound on, the route's floor. */
    constructor(transport, onState, options = {}) {
        this.transport = transport;
        this.onState = onState;
        this.options = options;
    }
    get given() {
        return this.gaveUp;
    }
    /** Turn the sound on: call it from a click (the AudioContext needs a user gesture). */
    async start() {
        if (this.on || this.gaveUp)
            return;
        this.on = true;
        this.policy.reset();
        this.onState("starting");
        try {
            if (!this.ctx) {
                this.ctx = new AudioContext({ sampleRate: RATE, latencyHint: "interactive" });
                const url = URL.createObjectURL(new Blob([WORKLET], { type: "text/javascript" }));
                await this.ctx.audioWorklet.addModule(url);
                URL.revokeObjectURL(url);
                this.node = new AudioWorkletNode(this.ctx, "yoyo-timed-ring", {
                    numberOfInputs: 0,
                    outputChannelCount: [2],
                    processorOptions: { config: audioSchedulerConfig(this.ctx.sampleRate) },
                });
                this.node.port.onmessage = (e) => this.fromWorklet(e.data);
                this.node.connect(this.ctx.destination);
            }
            await this.ctx.resume();
        }
        catch {
            this.giveUp();
            return;
        }
        void this.open();
    }
    /** Turn it off (the stream closes; the context is kept for the next start). */
    stop() {
        this.on = false;
        this.closeStream();
        void this.ctx?.suspend().catch(() => { });
        if (!this.gaveUp)
            this.onState("off");
    }
    /** The page is gone. */
    dispose() {
        this.stop();
        void this.ctx?.close().catch(() => { });
        this.ctx = null;
        this.node = null;
    }
    /** The stats line's numbers (`audioStatsLine`). */
    stats(now = performance.now()) {
        const w = this.worklet;
        const rate = this.ctx?.sampleRate ?? RATE;
        const playing = w?.stats.playing ?? false;
        return {
            depthMs: playing ? this.depthNow(now) : null,
            bufferedMs: w ? (w.stats.bufferedFrames / rate) * 1000 : null,
            underruns: w?.stats.underruns ?? 0,
            drops: (w?.stats.late ?? 0) + (w?.stats.overflow ?? 0),
            kbps: this.kbps(now),
        };
    }
    /** The playout report's `audio` (counts since the previous call); null while nothing plays. */
    report(now = performance.now()) {
        const w = this.worklet;
        if (!w || !this.on)
            return null;
        const s = w.stats;
        const from = this.reported ?? { underruns: 0, late: 0, concealed: 0, cuts: 0, cutFrames: 0, padFrames: 0 };
        const fresh = s.underruns < from.underruns || s.late < from.late || s.concealed < from.concealed || s.cuts < from.cuts;
        const base = fresh ? { underruns: 0, late: 0, concealed: 0, cuts: 0, cutFrames: 0, padFrames: 0 } : from;
        this.reported = { underruns: s.underruns, late: s.late, concealed: s.concealed, cuts: s.cuts, cutFrames: s.cutFrames, padFrames: s.padFrames ?? 0 };
        const rate = this.ctx?.sampleRate ?? RATE;
        const out = this.outputLatencyMs();
        const delay = this.playingDelay();
        const r = {
            outputMs: out,
            ioMs: (128 / rate) * 1000,
            depthMs: this.jitter.need,
            bufferedMs: (s.bufferedFrames / rate) * 1000,
            addedMs: delay !== null && this.jitter.base !== null ? delay - this.jitter.base : this.depthNow(now),
            underruns: s.underruns - base.underruns,
            late: s.late - base.late,
            concealed: s.concealed - base.concealed,
            cuts: s.cuts - base.cuts,
            kbps: this.kbps(now),
        };
        const d = this.diag;
        r.arrivalGapMaxMs = Math.round(d.arrivalGapMax);
        r.decodedGapMaxMs = Math.round(d.decodedGapMax);
        if (d.concealed)
            r.plcPackets = d.concealed;
        if (d.underrunsAt.length)
            r.underrunsAt = d.underrunsAt;
        if (d.overflow)
            r.overflow = d.overflow;
        r.decoder = this.wasm ? "wasm" : "webcodecs";
        if (d.metaMissing)
            r.unmatchedOutputs = d.metaMissing;
        if (d.decoderResets)
            r.decoderResets = d.decoderResets;
        d.arrivalGapMax = d.decodedGapMax = d.concealed = d.overflow = d.metaMissing = d.decoderResets = 0;
        d.underrunsAt = [];
        const stretchMs = (((s.padFrames ?? 0) - base.padFrames - (s.cutFrames - base.cutFrames)) / rate) * 1000;
        if (stretchMs !== 0)
            r.stretchMs = stretchMs;
        if (this.syncReport.skewMs !== null)
            r.skewMs = this.syncReport.skewMs;
        if (this.syncReport.floorMs !== null)
            r.floorMs = this.syncReport.floorMs;
        return r;
    }
    // ---------------------------------------------------------------- A/V sync (AVSyncAudio)
    /** The sound's delays for `AVSync` (ms, this clock − the computer's, aligned to the pictures' times by the offset). */
    syncDelays(now = performance.now()) {
        const base = this.jitter.base;
        if (!this.on || base === null)
            return null;
        const out = this.outputLatencyMs();
        const playing = this.playingDelay();
        const delay = (playing ?? base + this.depthNow(now)) - this.offset;
        const own = base + this.jitter.need + out + this.jitter.config.leadMs - this.offset;
        return { delay, ownDelay: own, soundRecent: now - this.soundAt < 5000 };
    }
    setSyncDelayGoal(goalMs) {
        const base = this.jitter.base;
        this.jitter.setSyncGoal(goalMs === null || base === null ? null : goalMs + this.offset - base);
    }
    setSyncReport(skewMs, floorMs) {
        this.syncReport = { skewMs, floorMs };
    }
    // ---------------------------------------------------------------- the stream
    giveUp() {
        this.gaveUp = true;
        this.on = false;
        this.closeStream();
        this.onState("none");
    }
    closeStream() {
        this.generation++;
        if (this.timer)
            clearTimeout(this.timer);
        this.timer = null;
        this.ctrl?.abort();
        this.ctrl = null;
        this.linkStream?.close();
        this.linkStream = null;
        if (this.decoder && this.decoder.state !== "closed") {
            try {
                this.decoder.close();
            }
            catch {
                /* closed */
            }
        }
        this.decoder = null;
        this.wasm?.free();
        this.wasm = null;
        this.pending.clear();
        this.lastSeq = null;
        this.diag.lastArrival = this.diag.lastPlayed = null;
    }
    /** A new stream: the buffer's estimate starts over on another route (the same route keeps what it learned). */
    begin(format, lan) {
        if (lan !== this.lan || this.jitter.base === null)
            this.jitter = new AudioJitter(audioJitterConfig(lan));
        this.lan = lan;
        this.offset = format.offsetMs;
        this.node?.port.postMessage({ t: "flush" });
        const config = { codec: "opus", sampleRate: format.sampleRate, numberOfChannels: format.channels, ...(format.description ? { description: format.description } : {}) };
        this.decoderConfig = config;
        this.outputAt = performance.now();
        this.startWasm(format);
        try {
            this.decoder = new AudioDecoder({ output: (d) => this.play(d), error: () => this.decoderFailed() });
            this.decoder.configure(config);
        }
        catch {
            return false;
        }
        this.onState("playing");
        return true;
    }
    /** The wasm decoder for this stream: packets go to it from when it is ready (WebCodecs until then). */
    startWasm(format) {
        const gen = this.generation;
        if (format.sampleRate !== 48_000 || format.channels < 1 || format.channels > 2)
            return;
        void loadWasmOpus().then(async (Ctor) => {
            if (!Ctor || gen !== this.generation)
                return;
            let dec;
            try {
                // no pre-skip: every packet keeps its length and its place in time (as on iOS)
                dec = new Ctor({ channels: format.channels, sampleRate: 48_000, preSkip: 0 });
                await dec.ready;
            }
            catch {
                return;
            }
            if (gen !== this.generation)
                return dec.free();
            this.wasm = dec;
            this.pending.clear();
        });
    }
    decoderFailed() {
        if (this.ctrl)
            this.ctrl.abort();
        else
            this.ended(this.generation, null, performance.now());
    }
    async open() {
        const link = this.options.link?.() ?? null;
        if (link)
            return this.openLink(link);
        const ctrl = new AbortController();
        this.ctrl = ctrl;
        const gen = this.generation;
        const opened = performance.now();
        let status = null;
        try {
            const res = await this.transport.fetch("/audio", {
                method: "POST",
                cache: "no-store",
                headers: { accept: AUDIO_ACCEPT, "content-type": "application/json" },
                body: "{}",
                signal: ctrl.signal,
            });
            if (!res.ok || !res.body) {
                status = res.status;
                throw new Error(`HTTP ${res.status}`);
            }
            const format = formatOf((n) => res.headers.get(n));
            if (!(await supported(format))) {
                status = 415;
                throw new Error("opus is not supported");
            }
            if (gen !== this.generation || !this.begin(format, this.options.lan?.() ?? false))
                throw new Error("closed");
            const parser = new PartParser(boundaryOf(res.headers.get("content-type")) ?? DEFAULT_BOUNDARY);
            const reader = res.body.getReader();
            for (;;) {
                const { done, value } = await reader.read();
                if (done)
                    break;
                for (const p of parser.feed(value)) {
                    if (p.kind !== "audio")
                        continue;
                    this.packet(p.headers.audioSeq ?? ++this.seq, p.headers.audioTime ?? null, p.body);
                }
            }
        }
        catch {
            /* ended: the policy decides */
        }
        if (this.ctrl !== ctrl)
            return;
        this.ended(gen, status, opened);
    }
    openLink(link) {
        const gen = this.generation;
        const opened = performance.now();
        const lan = this.options.lan?.() ?? link.isLocalNetwork;
        let started = false;
        const stream = link.openAudio("", (e) => {
            if (gen !== this.generation)
                return;
            switch (e.type) {
                case "opened": {
                    const lookup = (name) => {
                        for (const [k, v] of Object.entries(e.format))
                            if (k.toLowerCase() === name.toLowerCase())
                                return v;
                        return null;
                    };
                    const format = formatOf(lookup);
                    void supported(format).then((ok) => {
                        if (gen !== this.generation)
                            return;
                        if (!ok)
                            return this.ended(gen, 415, opened);
                        started = this.begin(format, lan);
                        if (!started)
                            this.ended(gen, null, opened);
                    });
                    return;
                }
                case "packet":
                    if (started)
                        this.packet(e.seq, e.timeMs, e.data);
                    return;
                case "error":
                    return this.ended(gen, e.status, opened);
                case "closed":
                case "failed":
                    return this.ended(gen, null, opened);
            }
        });
        if (gen !== this.generation)
            stream.close();
        else
            this.linkStream = stream;
    }
    /** The stream ended by itself: the policy says whether and when to open again. */
    ended(gen, status, opened) {
        if (gen !== this.generation || !this.on)
            return;
        this.closeStream();
        const wait = this.policy.ended(status, performance.now() - opened);
        if (wait === null) {
            this.giveUp();
            return;
        }
        this.onState("waiting");
        this.timer = setTimeout(() => {
            this.timer = null;
            if (this.on)
                void this.open();
        }, wait);
    }
    /** One Opus packet: its delay into the estimate, then the decoder (its slot is set when it comes out). */
    packet(seq, macTime, data) {
        const d = this.decoder;
        if (!this.wasm && (!d || d.state !== "configured"))
            return;
        const arrival = performance.now();
        if (this.diag.lastArrival !== null)
            this.diag.arrivalGapMax = Math.max(this.diag.arrivalGapMax, arrival - this.diag.lastArrival);
        this.diag.lastArrival = arrival;
        this.bytes.push({ at: arrival, n: data.length });
        while (this.bytes.length && arrival - this.bytes[0].at > 3000)
            this.bytes.shift();
        if (macTime !== null && Number.isFinite(macTime))
            this.jitter.observe(arrival - macTime, arrival);
        if (this.wasm) {
            const meta = { seq, macTime: macTime !== null && Number.isFinite(macTime) ? macTime : null, arrival };
            // a few packets missing before this one: libopus' loss concealment fills them (sound like what came before,
            // fading), where the player would otherwise play silence
            const missing = this.lastSeq === null ? 0 : seq - this.lastSeq - 1;
            if (missing > 0 && missing <= AUDIO_PLC_MAX_PACKETS)
                this.conceal(missing, meta);
            if (this.lastSeq === null || seq > this.lastSeq)
                this.lastSeq = seq;
            try {
                const out = this.wasm.decodeFrame(data);
                const l = out.channelData[0];
                if (!l || out.samplesDecoded <= 0)
                    return;
                const r = out.channelData[1];
                // own copies: they go to the worklet
                this.deliver(l.slice(0, out.samplesDecoded), r ? r.slice(0, out.samplesDecoded) : null, meta);
            }
            catch {
                /* a packet that doesn't decode: concealed as missing */
            }
            return;
        }
        if (!d)
            return;
        // a decoder that stops giving packets out while they go in (seen on Android: 0.2…3 s, every so often) starts over:
        // a few packets of silence instead of the sound stopping until it wakes
        if (this.pending.size >= AUDIO_DECODER_STUCK_PACKETS && arrival - this.outputAt > AUDIO_DECODER_STUCK_MS && this.decoderConfig) {
            try {
                d.reset();
                d.configure(this.decoderConfig);
            }
            catch {
                return this.decoderFailed();
            }
            this.pending.clear();
            this.outputAt = arrival;
            this.diag.decoderResets++;
        }
        const timestamp = (this.ts += 20_000);
        this.pending.set(timestamp, { seq, macTime: macTime !== null && Number.isFinite(macTime) ? macTime : null, arrival });
        try {
            d.decode(new EncodedAudioChunk({ type: "key", timestamp, data }));
        }
        catch {
            this.pending.delete(timestamp);
        }
    }
    play(d) {
        try {
            this.outputAt = performance.now();
            // its packet by timestamp; a decoder that stamps its output its own way: the oldest one waiting (output comes
            // in order). Older ones still waiting were swallowed: they go.
            let key = this.pending.has(d.timestamp) ? d.timestamp : null;
            if (key === null) {
                this.diag.metaMissing++;
                for (const k of this.pending.keys()) {
                    key = k;
                    break;
                }
            }
            const meta = key === null ? undefined : this.pending.get(key);
            if (key !== null)
                for (const k of [...this.pending.keys()])
                    if (k <= key)
                        this.pending.delete(k);
            if (!meta || !this.ctx || !this.node)
                return;
            const n = d.numberOfFrames;
            const l = new Float32Array(n);
            d.copyTo(l, { planeIndex: 0, format: "f32-planar" });
            let r = null;
            if (d.numberOfChannels > 1) {
                r = new Float32Array(n);
                d.copyTo(r, { planeIndex: 1, format: "f32-planar" });
            }
            this.deliver(l, r, meta);
        }
        catch {
            /* a format this browser won't convert: silence */
        }
        finally {
            d.close();
        }
    }
    /** `n` packets lost right before `next`: one decode without data (libopus' PLC gives up to 120 ms), cut into
     *  packets of the stream's size with their seqs and times. */
    conceal(n, next) {
        const w = this.wasm;
        if (!w)
            return;
        try {
            const out = w.decodeFrame(new Uint8Array(0));
            const l = out.channelData[0];
            const r = out.channelData[1];
            const per = AUDIO_PACKET_FRAMES;
            for (let k = 0; k < n && (k + 1) * per <= out.samplesDecoded; k++) {
                const back = n - k;
                const meta = { seq: next.seq - back, macTime: next.macTime === null ? null : next.macTime - (back * per * 1000) / 48_000, arrival: next.arrival };
                this.deliver(l.slice(k * per, (k + 1) * per), r ? r.slice(k * per, (k + 1) * per) : null, meta);
                this.diag.concealed++;
            }
        }
        catch {
            /* silence then */
        }
    }
    /** A decoded packet (planar; `r` null for mono) to the player, at its slot. */
    deliver(l, right, meta) {
        if (!this.ctx || !this.node)
            return;
        const r = right ?? l;
        {
            if (hasSound(l))
                this.soundAt = meta.arrival;
            const now = performance.now();
            const base = this.jitter.base;
            const slot = meta.macTime !== null && base !== null ? meta.macTime + base + this.depthNow(now) : meta.arrival + this.depthNow(now);
            const at = Math.round(this.frameAt(slot));
            if (this.diag.lastPlayed !== null)
                this.diag.decodedGapMax = Math.max(this.diag.decodedGapMax, now - this.diag.lastPlayed);
            this.diag.lastPlayed = now;
            this.node.port.postMessage({ t: "packet", p: { l, r, at, seq: meta.seq, macTime: meta.macTime } }, r === l ? [l.buffer] : [l.buffer, r.buffer]);
        }
    }
    fromWorklet(m) {
        const now = performance.now();
        if (m.stats.underruns > this.lastUnderruns) {
            this.jitter.interruption(now);
            const d = this.diag;
            if (d.underrunsAt.length < 10)
                d.underrunsAt.push({ sincePacketMs: d.lastArrival === null ? -1 : Math.round(now - d.lastArrival), sincePlayedMs: d.lastPlayed === null ? -1 : Math.round(now - d.lastPlayed) });
        }
        const prevOverflow = this.worklet?.stats.overflow;
        if (prevOverflow !== undefined && m.stats.overflow > prevOverflow)
            this.diag.overflow += m.stats.overflow - prevOverflow;
        this.lastUnderruns = m.stats.underruns;
        this.worklet = { ...m, at: now };
    }
    // ---------------------------------------------------------------- clocks
    depthNow(now) {
        return this.jitter.depth(now, this.outputLatencyMs());
    }
    /** The output's latency: what a sample takes from the worklet to the speaker (ms). */
    outputLatencyMs() {
        const c = this.ctx;
        if (!c)
            return 0;
        const out = typeof c.outputLatency === "number" && Number.isFinite(c.outputLatency) ? c.outputLatency : 0;
        const base = typeof c.baseLatency === "number" && Number.isFinite(c.baseLatency) ? c.baseLatency : 0;
        return (out + base) * 1000;
    }
    /** The context frame heard at page time `t` (ms). */
    frameAt(t) {
        const c = this.ctx;
        const ts = typeof c.getOutputTimestamp === "function" ? c.getOutputTimestamp() : null;
        if (ts && typeof ts.contextTime === "number" && typeof ts.performanceTime === "number" && ts.performanceTime > 0) {
            return (ts.contextTime + (t - ts.performanceTime) / 1000) * c.sampleRate;
        }
        // without an output timestamp: the render clock now, heard after the output latency
        return (c.currentTime + (t - performance.now() - this.outputLatencyMs()) / 1000) * c.sampleRate;
    }
    /** The page time (ms) context frame `frame` is heard at. */
    timeOf(frame) {
        const c = this.ctx;
        const ts = typeof c.getOutputTimestamp === "function" ? c.getOutputTimestamp() : null;
        if (ts && typeof ts.contextTime === "number" && typeof ts.performanceTime === "number" && ts.performanceTime > 0) {
            return ts.performanceTime + (frame / c.sampleRate - ts.contextTime) * 1000;
        }
        return performance.now() + (frame / c.sampleRate - c.currentTime) * 1000 + this.outputLatencyMs();
    }
    /** Heard now − the macTime of the sample heard now (ms; null: not playing). */
    playingDelay() {
        const w = this.worklet;
        if (!w || !this.ctx || !w.stats.playing || w.stats.playingMacTime === null)
            return null;
        // the sample at the worklet's playhead is heard at timeOf(frame)
        return this.timeOf(w.frame) - w.stats.playingMacTime;
    }
    kbps(now) {
        const from = now - 3000;
        const bytes = this.bytes.filter((b) => b.at > from).reduce((n, b) => n + b.n, 0);
        return (bytes * 8) / 3000;
    }
}
/** A sound stream's format from `/audio`'s response headers (or a link's `audio.opened` by the same names). */
function formatOf(header) {
    return {
        channels: Number(header("x-audio-channels") ?? 2) || 2,
        sampleRate: Number(header("x-audio-rate") ?? RATE) || RATE,
        description: opusDescription(header("x-audio-cookie")),
        offsetMs: videoOffsetMs(header("x-audio-video-offset")),
    };
}
async function supported(f) {
    const config = { codec: "opus", sampleRate: f.sampleRate, numberOfChannels: f.channels, ...(f.description ? { description: f.description } : {}) };
    const s = await AudioDecoder.isConfigSupported(config).catch(() => ({ supported: false }));
    return s.supported === true;
}
/** Any sample above −60 dBFS. */
function hasSound(s) {
    for (let i = 0; i < s.length; i += 4)
        if (Math.abs(s[i]) > 0.001)
            return true;
    return false;
}
