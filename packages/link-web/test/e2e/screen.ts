// A browser test of @yoyocontrol/screen-web's link route (run.mjs --page screen): VideoStream and ScreenAudio over an
// in-page ScreenLink whose computer is the browser's own encoders (WebCodecs H.264 from a moving canvas at 60 fps,
// Opus from an oscillator), with a simulated one-way delay + jitter. It checks what the probe's synthetic video can't:
// real access units through VideoDecoder, every verdict going back (`decoded`), the playout, the sound's buffer and the
// A/V sync — and returns the stats as JSON.

import { AVSyncDriver, ScreenAudio, VideoStream, statsLines, type ScreenLink, type ScreenLinkAudioEvent, type ScreenLinkFrameKind, type ScreenLinkVideoEvent } from "@yoyocontrol/screen-web";

interface Config {
  seconds: number;
  /** one-way delay and its jitter (ms) */
  delayMs: number;
  jitterMs: number;
  /** The "computer"'s codec (`--codec hevc`: the stream asks for HEVC by itself where this browser decodes it). */
  codec?: "h264" | "hevc";
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const decoderLog: string[] = [];
{
  const Real = VideoDecoder;
  (globalThis as { VideoDecoder: typeof VideoDecoder }).VideoDecoder = class extends Real {
    constructor(init: VideoDecoderInit) {
      super({ output: init.output, error: (e) => (decoderLog.push(`error ${e.message} q`), init.error(e)) });
    }
    override configure(c: VideoDecoderConfig) {
      decoderLog.push(`configure ${c.codec} ${performance.now() | 0}`);
      super.configure(c);
    }
    override reset() {
      decoderLog.push(`reset q=${this.decodeQueueSize} ${performance.now() | 0}`);
      super.reset();
    }
  };
}

async function run(cfg: Config) {
  const verdicts = { ok: 0, failed: 0, keyRequests: 0, reports: 0, failedFrames: [] as number[] };
  let videoListener: ((e: ScreenLinkVideoEvent) => void) | null = null;
  let audioListener: ((e: ScreenLinkAudioEvent) => void) | null = null;
  const later = (f: () => void) => setTimeout(f, cfg.delayMs + Math.random() * cfg.jitterMs);
  // in order like the media layer: a FIFO, each one due no earlier than the one before it
  const fifo: { at: number; f: () => void }[] = [];
  let pumping: ReturnType<typeof setTimeout> | null = null;
  const pump = () => {
    pumping = null;
    while (fifo.length && fifo[0]!.at <= performance.now()) fifo.shift()!.f();
    if (fifo.length) pumping = setTimeout(pump, fifo[0]!.at - performance.now());
  };
  const inOrder = (f: () => void) => {
    const at = Math.max(performance.now() + cfg.delayMs + Math.random() * cfg.jitterMs, fifo.at(-1)?.at ?? 0);
    fifo.push({ at, f });
    if (!pumping) pumping = setTimeout(pump, at - performance.now());
  };

  const link: ScreenLink = {
    pathLabel: "link lan",
    isLocalNetwork: false,
    rttMinMs: cfg.delayMs * 2,
    statsLine: "test",
    isClosed: false,
    closed: new Promise(() => {}),
    openVideo(_query, onEvent) {
      videoListener = onEvent;
      // as the Mac does: HEVC when the stream asked for it first
      const codec = cfg.codec === "hevc" && /codecs=hevc/.test(_query) ? "hevc" : "h264";
      sentCodec = codec;
      later(() => onEvent({ type: "opened", codec, width: 640, height: 360, headers: { "X-Stream-Codec": codec } }));
      return {
        decoded: (f, ok) => {
          if (ok) verdicts.ok++;
          else {
            verdicts.failed++;
            if (verdicts.failedFrames.length < 40) verdicts.failedFrames.push(f);
          }
        },
        requestKeyframe: () => {
          decoderLog.push(`key requested at frame ${number} ${performance.now() | 0}`);
          verdicts.keyRequests++;
          forceKey = true;
        },
        report: () => verdicts.reports++,
        close: () => (videoListener = null),
      };
    },
    openAudio(_query, onEvent) {
      audioListener = onEvent;
      later(() => onEvent({ type: "opened", format: { "X-Audio-Codec": "opus", "X-Audio-Rate": "48000", "X-Audio-Channels": "2", "X-Audio-Frames": "960", "X-Audio-Video-Offset": "31" } }));
      return { close: () => (audioListener = null) };
    },
    sendInput: () => {},
    setInputErrorHandler: () => {},
    control: async () => ({ granted: true, holder: { id: "me" } }),
  };

  // the "computer": a moving picture → H.264 (Annex B), a tone → Opus
  const src = new OffscreenCanvas(640, 360);
  const g = src.getContext("2d")!;
  let number = 0;
  let forceKey = true;
  let sentCodec: "h264" | "hevc" = "h264";
  const encoder = new VideoEncoder({
    output: (chunk) => {
      const au = new Uint8Array(chunk.byteLength);
      chunk.copyTo(au);
      if (chunk.type === "key") decoderLog.push(`key frame ${number + 1} ${performance.now() | 0}`);
      const frame = { number: ++number, codec: sentCodec, kind: (chunk.type === "key" ? "key" : "delta") as ScreenLinkFrameKind, width: 640, height: 360, captureMs: Date.now(), au };
      inOrder(() => videoListener?.({ type: "frame", frame }));
    },
    error: (e) => console.error("encoder", e.message),
  });
  const hevcConfig = { codec: "hvc1.1.6.L93.B0", width: 640, height: 360, bitrate: 2_000_000, framerate: 60, latencyMode: "realtime", hevc: { format: "annexb" } } as VideoEncoderConfig;
  if (cfg.codec === "hevc" && !(await VideoEncoder.isConfigSupported(hevcConfig)).supported) throw new Error("this browser has no HEVC encoder");
  encoder.configure(cfg.codec === "hevc" ? hevcConfig : { codec: "avc1.42001f", width: 640, height: 360, bitrate: 2_000_000, framerate: 60, latencyMode: "realtime", avc: { format: "annexb" } });
  let aseq = 0;
  const audioEncoder = new AudioEncoder({
    output: (chunk) => {
      const data = new Uint8Array(chunk.byteLength);
      chunk.copyTo(data);
      const seq = aseq++;
      const timeMs = Date.now();
      later(() => audioListener?.({ type: "packet", seq, timeMs, data }));
    },
    error: (e) => console.error("audio encoder", e.message),
  });
  audioEncoder.configure({ codec: "opus", sampleRate: 48000, numberOfChannels: 2, bitrate: 64000 });

  const canvas = document.createElement("canvas");
  document.body.append(canvas);
  let pictures = 0;
  let ended: unknown = null;
  const video = new VideoStream(
    { link, canvas, route: "direct" },
    { onPicture: () => pictures++, onCursor: () => {}, onStatus: () => {}, onEnd: (i) => (ended = i) },
  );
  void video.run();
  // the codec the stream asked for decides what the "computer" encodes: let it open first
  await sleep(cfg.delayMs + cfg.jitterMs + 20);
  const states: string[] = [];
  const audio = new ScreenAudio({ fetch: () => Promise.reject(new Error("no HTTP here")) }, (s) => states.push(s), { link: () => link });
  await audio.start();
  const sync = new AVSyncDriver(audio, () => video);
  sync.start();

  const t0 = performance.now();
  let ts = 0;
  let audioTs = 0;
  const tick = setInterval(() => {
    const t = (performance.now() - t0) / 1000;
    g.fillStyle = `hsl(${(t * 90) % 360} 60% 50%)`;
    g.fillRect(0, 0, 640, 360);
    g.fillStyle = "#fff";
    g.fillRect(((t * 200) % 600) | 0, 150, 40, 40);
    const f = new VideoFrame(src, { timestamp: (ts += 16_667) });
    encoder.encode(f, { keyFrame: forceKey });
    forceKey = false;
    f.close();
  }, 1000 / 60);
  const audioTick = setInterval(() => {
    // 20 ms of a 440 Hz tone, planar stereo
    const n = 960;
    const pcm = new Float32Array(n * 2);
    for (let i = 0; i < n; i++) pcm[i] = pcm[n + i] = 0.2 * Math.sin((2 * Math.PI * 440 * (audioTs / 1e6 * 48000 + i)) / 48000);
    audioEncoder.encode(new AudioData({ format: "f32-planar", sampleRate: 48000, numberOfFrames: n, numberOfChannels: 2, timestamp: audioTs, data: pcm }));
    audioTs += 20_000;
  }, 20);
  const lines: string[][] = [];
  const statsTimer = setInterval(() => {
    const a = audio.stats();
    lines.push(statsLines({ stream: video.stats(), way: link.pathLabel, connection: "live", linkLine: link.statsLine, audio: a }));
  }, 2000);
  await sleep(cfg.seconds * 1000);
  clearInterval(tick);
  clearInterval(audioTick);
  clearInterval(statsTimer);
  const result = {
    encoded: number,
    pictures,
    verdicts,
    ended,
    stats: video.stats(),
    playout: video.playoutState(),
    audio: { states, stats: audio.stats(), report: audio.report() },
    sync: sync.last,
    lines: lines.at(-1),
    decoderLog,
  };
  sync.stop();
  video.close();
  audio.dispose();
  encoder.close();
  audioEncoder.close();
  return result;
}

(globalThis as { e2e?: (c: Config) => Promise<unknown> }).e2e = (c) =>
  run(c).catch((e: unknown) => ({ error: e instanceof Error ? `${e.name}: ${e.message}\n${e.stack}` : String(e) }));
