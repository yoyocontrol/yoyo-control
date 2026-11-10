import { percentile } from "./playout.js";

/**
 * The sound's jitter buffer, in two pure halves (the iOS kit's `ScreenAudioBuffer`, compacted):
 *
 * - `AudioJitter` (page thread) estimates the depth. Each packet's delay = arrival − its `X-Audio-Time` (ms) holds the
 *   clock offset plus the network delay; `base` = the smallest of the last `windowMs`, the delays above it are the
 *   jitter. The buffer's need is their p99 + `marginMs`, within the floor…`maxDepthMs` (`startDepthMs` until
 *   `minSamples` were seen). The floor is the route's (80 ms on a LAN, 120 ms elsewhere) plus a bump: each interruption
 *   (an underrun) raises it by `bumpStepMs` (at most `bumpMaxMs`), and it falls by `bumpDecayMs` every
 *   `bumpDecayEveryMs` without one. The depth is need + the output's latency + `leadMs`, or the A/V sync's depth when
 *   that is more (it moves at most `syncRateMsPerSec`). A packet's slot — when it should be heard — is macTime + base +
 *   depth. A delay `clockStepMs` below the base, or that far above it for `clockStepHoldMs`, starts the estimate over.
 * - `AudioScheduler` (the audio thread: its source runs inside the page's AudioWorklet) plays the packets. Playback starts
 *   at the first packet's slot (a packet more than `lateFrames` past its slot is late: dropped) and then runs sample by
 *   sample, packet after packet, without looking at the clock; a gap in `seq` is that many packets of silence (more than
 *   `maxConcealed`: playback starts over from the slots). Running dry is an underrun: it starts over at the next packet's
 *   slot. Sound fades in at a start and out as it runs dry. When playback runs `excessFrames` behind the slots for
 *   `excessHoldFrames` (the depth shrank, the computer's clock runs fast), `cutFrames` of a packet are dropped with a
 *   crossfade, at most every `cutEveryFrames`. More than `maxQueuedFrames` waiting drops the oldest and starts over.
 *
 * Times: the page's clock in ms (`performance.now()`) for `AudioJitter`; frames of the AudioContext for `AudioScheduler`.
 */

export interface AudioJitterConfig {
  windowMs: number;
  minSamples: number;
  startDepthMs: number;
  marginMs: number;
  floorMs: number;
  maxDepthMs: number;
  percentile: number;
  bumpStepMs: number;
  bumpMaxMs: number;
  bumpDecayMs: number;
  bumpDecayEveryMs: number;
  /** The output's own lead beyond its latency: a render quantum and the message to the worklet. */
  leadMs: number;
  syncRateMsPerSec: number;
  clockStepMs: number;
  clockStepHoldMs: number;
}

/** The floors by route. */
export const AUDIO_LAN_FLOOR_MS = 80;
export const AUDIO_REMOTE_FLOOR_MS = 120;

export function audioJitterConfig(lan: boolean, over: Partial<AudioJitterConfig> = {}): AudioJitterConfig {
  const floorMs = lan ? AUDIO_LAN_FLOOR_MS : AUDIO_REMOTE_FLOOR_MS;
  return {
    windowMs: 10_000,
    minSamples: 10,
    startDepthMs: Math.max(floorMs, 60),
    marginMs: 20,
    floorMs,
    maxDepthMs: 400,
    percentile: 0.99,
    bumpStepMs: 40,
    bumpMaxMs: 240,
    bumpDecayMs: 10,
    bumpDecayEveryMs: 15_000,
    leadMs: 10,
    syncRateMsPerSec: 20,
    clockStepMs: 500,
    clockStepHoldMs: 1000,
    ...over,
  };
}

export class AudioJitter {
  /** The smallest recent delay (null until the first packet). */
  base: number | null = null;
  /** The buffer's own need (ms: jitter + margin within floor + bump … max). */
  need: number;
  /** The adaptive floor's bump (ms). */
  bump = 0;
  /** The p99 of the window's delays above the base (null until `minSamples`). */
  jitter: number | null = null;
  /** The A/V sync depth in use (ms; null: none). */
  sync: number | null = null;
  resets = 0;
  private samples: { at: number; delay: number }[] = [];
  private seen = 0;
  private highSince: number | null = null;
  private lastBumpAt: number | null = null;
  private syncGoal: number | null = null;
  private syncAt: number | null = null;

  constructor(readonly config: AudioJitterConfig = audioJitterConfig(false)) {
    this.need = config.startDepthMs;
  }

  get floor(): number {
    return this.config.floorMs + this.bump;
  }

  /** A packet's delay (arrival − macTime) at `arrival`. */
  observe(delay: number, arrival: number): void {
    const c = this.config;
    this.decayBump(arrival);
    if (this.base !== null) {
      if (delay < this.base - c.clockStepMs) this.restart();
      else if (delay > this.base + c.clockStepMs) {
        this.highSince ??= arrival;
        if (arrival - this.highSince < c.clockStepHoldMs) return;
        this.restart();
      } else this.highSince = null;
    }
    this.samples.push({ at: arrival, delay });
    this.seen++;
    while (this.samples.length > c.minSamples && arrival - this.samples[0]!.at > c.windowMs) this.samples.shift();
    let base = Infinity;
    for (const s of this.samples) base = Math.min(base, s.delay);
    this.base = base;
    if (this.seen < c.minSamples) {
      this.need = Math.max(c.startDepthMs, this.floor);
      return;
    }
    this.jitter = percentile(this.samples.map((s) => s.delay - base), c.percentile) ?? 0;
    this.need = Math.min(Math.max(this.jitter + c.marginMs, this.floor), Math.max(c.maxDepthMs, this.floor));
  }

  /** Playback was interrupted (an underrun): the floor goes up. */
  interruption(now: number): void {
    this.bump = Math.min(this.bump + this.config.bumpStepMs, this.config.bumpMaxMs);
    this.lastBumpAt = now;
    this.need = Math.max(this.need, this.floor);
  }

  /** The A/V sync's delay goal (ms; null: none) — the depth giving it is `syncDepthFor`. */
  setSyncGoal(depthMs: number | null): void {
    this.syncGoal = depthMs;
  }

  /** The depth now (ms, from the slot's macTime + base): need + output latency + lead, or the sync depth when more. */
  depth(now: number, outputLatencyMs: number): number {
    const own = this.need + outputLatencyMs + this.config.leadMs;
    const goal = this.syncGoal;
    const dt = this.syncAt === null ? 0 : Math.max(now - this.syncAt, 0);
    this.syncAt = now;
    const step = (this.config.syncRateMsPerSec / 1000) * dt;
    if (goal === null || goal <= own) {
      // back to its own depth, at the same pace
      if (this.sync !== null) this.sync = this.sync - step <= own ? null : this.sync - step;
    } else {
      const from = this.sync ?? own;
      this.sync = goal > from ? Math.min(goal, from + step) : Math.max(goal, from - step);
    }
    return this.sync !== null ? Math.max(this.sync, own) : own;
  }

  private decayBump(now: number): void {
    if (this.bump <= 0 || this.lastBumpAt === null) return;
    const every = this.config.bumpDecayEveryMs;
    const steps = Math.floor((now - this.lastBumpAt) / every);
    if (steps <= 0) return;
    this.bump = Math.max(this.bump - steps * this.config.bumpDecayMs, 0);
    this.lastBumpAt += steps * every;
  }

  private restart(): void {
    this.samples = [];
    this.seen = 0;
    this.base = null;
    this.jitter = null;
    this.highSince = null;
    this.need = Math.max(this.config.startDepthMs, this.floor);
    this.resets++;
  }
}

/** One decoded packet on its way to the speaker. */
export interface ScheduledPacket {
  /** Left and right samples (the same array twice for mono). */
  l: Float32Array;
  r: Float32Array;
  /** The context frame its first sample should be heard at (its slot). */
  at: number;
  /** `X-Audio-Seq` (or the link's aseq): a gap is lost packets. */
  seq: number;
  /** Its first sample's `X-Audio-Time` (ms; null: none). */
  macTime: number | null;
}

export interface AudioSchedulerConfig {
  rate: number;
  packetFrames: number;
  lateFrames: number;
  fadeFrames: number;
  maxConcealed: number;
  excessFrames: number;
  excessHoldFrames: number;
  cutFrames: number;
  crossfadeFrames: number;
  cutEveryFrames: number;
  maxQueuedFrames: number;
}

export function audioSchedulerConfig(rate = 48_000, packetFrames = 960): AudioSchedulerConfig {
  const f = (ms: number) => Math.round((ms * rate) / 1000);
  return {
    rate,
    packetFrames,
    lateFrames: f(10),
    fadeFrames: f(5),
    maxConcealed: 25,
    excessFrames: f(20),
    excessHoldFrames: f(1000),
    cutFrames: f(10),
    crossfadeFrames: f(2.5),
    cutEveryFrames: f(250),
    maxQueuedFrames: f(1000),
  };
}

/** The counters and state the worklet reports. */
export interface AudioSchedulerStats {
  playing: boolean;
  /** The macTime (ms) of the sample playing now (null: not playing, or no time). */
  playingMacTime: number | null;
  /** Frames queued ahead of the playhead (silence to conceal included). */
  bufferedFrames: number;
  underruns: number;
  late: number;
  overflow: number;
  concealed: number;
  cuts: number;
  cutFrames: number;
}

/**
 * The audio thread's half (see above). Self-contained on purpose — no imports, no module constants: its source is put
 * into the page's AudioWorklet as is (`AudioScheduler.toString()`).
 */
export class AudioScheduler {
  queue: ScheduledPacket[] = [];
  pos = 0;
  playing = false;
  expectedSeq: number | null = null;
  concealLeft = 0;
  fadeIn = 0;
  /** The head packet's boundary was handled (its gap concealed, the cut decided). */
  entered = false;
  lagFrom: number | null = null;
  lastCut = -Infinity;
  cut: { left: number; skip: number } | null = null;
  stats: AudioSchedulerStats = { playing: false, playingMacTime: null, bufferedFrames: 0, underruns: 0, late: 0, overflow: 0, concealed: 0, cuts: 0, cutFrames: 0 };

  constructor(readonly config: AudioSchedulerConfig) {}

  push(p: ScheduledPacket): void {
    this.queue.push(p);
    let queued = -this.pos;
    for (const q of this.queue) queued += q.l.length;
    if (queued > this.config.maxQueuedFrames) {
      // the output stopped pulling: what waits is stale
      this.queue.shift();
      this.pos = 0;
      this.playing = false;
      this.entered = false;
      this.stats.overflow++;
    }
  }

  /** Fills `l` / `r` (one render quantum) whose first sample is heard at context frame `frame`. */
  render(l: Float32Array, r: Float32Array, frame: number): void {
    const c = this.config;
    for (let i = 0; i < l.length; i++) {
      const f = frame + i;
      if (!this.playing && !this.start(f)) {
        l[i] = 0;
        r[i] = 0;
        continue;
      }
      if (this.concealLeft > 0) {
        this.concealLeft--;
        l[i] = 0;
        r[i] = 0;
        continue;
      }
      let head = this.queue[0];
      if (!head) {
        this.playing = false;
        this.stats.underruns++;
        l[i] = 0;
        r[i] = 0;
        continue;
      }
      if (!this.entered) this.atBoundary(f, head);
      head = this.queue[0];
      if (!head || !this.playing) {
        l[i] = 0;
        r[i] = 0;
        continue;
      }
      if (this.concealLeft > 0) {
        this.concealLeft--;
        l[i] = 0;
        r[i] = 0;
        continue;
      }
      let a = head.l[this.pos]!, b = head.r[this.pos]!;
      const x = this.cut;
      if (x) {
        const t = 1 - x.left / c.crossfadeFrames;
        const j = this.pos + x.skip;
        a = a * (1 - t) + (head.l[j] ?? 0) * t;
        b = b * (1 - t) + (head.r[j] ?? 0) * t;
        if (--x.left <= 0) {
          this.pos += x.skip;
          this.cut = null;
        }
      }
      let gain = 1;
      if (this.fadeIn > 0) {
        gain = 1 - this.fadeIn / c.fadeFrames;
        this.fadeIn--;
      }
      const ahead = this.buffered();
      if (ahead < c.fadeFrames && this.queue.length === 1) gain *= ahead / c.fadeFrames;
      l[i] = a * gain;
      r[i] = b * gain;
      this.pos++;
      if (this.pos >= head.l.length) {
        this.queue.shift();
        this.pos = 0;
        this.cut = null;
        this.entered = false;
      }
    }
    this.stats.playing = this.playing;
    const h = this.queue[0];
    this.stats.playingMacTime = this.playing && h && h.macTime !== null ? h.macTime + (this.pos / c.rate) * 1000 : null;
    this.stats.bufferedFrames = this.buffered();
  }

  buffered(): number {
    let n = this.concealLeft - this.pos;
    for (const q of this.queue) n += q.l.length;
    return Math.max(n, 0);
  }

  /** Not playing: drop what is past its slot, start when the head's slot comes. */
  start(f: number): boolean {
    while (this.queue.length && this.queue[0]!.at + this.config.lateFrames < f) {
      this.queue.shift();
      this.stats.late++;
    }
    const head = this.queue[0];
    if (!head || f < head.at) return false;
    this.playing = true;
    this.pos = Math.min(f - head.at, head.l.length - 1);
    this.expectedSeq = head.seq + 1;
    this.concealLeft = 0;
    this.fadeIn = this.config.fadeFrames;
    this.lagFrom = null;
    this.entered = true;
    return true;
  }

  /** A new packet starts: conceal a seq gap, cut when playback lags its slots. */
  atBoundary(f: number, head: ScheduledPacket): void {
    const c = this.config;
    this.entered = true;
    if (this.expectedSeq !== null && head.seq !== this.expectedSeq) {
      const n = head.seq - this.expectedSeq;
      if (n > 0 && n <= c.maxConcealed) {
        this.concealLeft = n * c.packetFrames;
        this.stats.concealed += n;
      } else if (n !== 0) {
        // too much missing (or a new stream): start over from the slots
        this.playing = false;
        this.expectedSeq = null;
        this.start(f);
        return;
      }
    }
    this.expectedSeq = head.seq + 1;
    const lag = f + this.concealLeft - head.at;
    if (lag > c.excessFrames) {
      this.lagFrom ??= f;
      if (f - this.lagFrom >= c.excessHoldFrames && f - this.lastCut >= c.cutEveryFrames && head.l.length > c.cutFrames + c.crossfadeFrames) {
        this.cut = { left: c.crossfadeFrames, skip: c.cutFrames };
        this.lastCut = f;
        this.stats.cuts++;
        this.stats.cutFrames += c.cutFrames;
      }
    } else {
      this.lagFrom = null;
    }
  }
}
