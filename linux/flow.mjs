// Flow control and latency-first bit-rate adaptation of one video stream (README.md「视频流」; the Yoyo Control
// protocol's「视频流、确认与客户端指针」「网络质量」「播放报告」, whose reference is the Mac server's StreamFlow.swift /
// StreamNetQuality.swift / StreamPlayoutReport.swift — the numbers and rules here are that server's). The client acks
// cumulatively; at most W picture parts are in flight; RTT is measured on this clock (part written → its covering ack);
// the queueing delay (the lowest RTT of the last second − the min RTT over 10 s) steers the bit rate. The picture size
// is fixed for a stream, so congestion only lowers the bit rate.
//
// Pure: every decision is a function of the calls made with their own timestamps (seconds, any monotonic clock).

/** Every number the streams run by (the reference server's StreamTuning defaults). */
export const TUNING = Object.freeze({
  videoWindow: 4,
  maxVideoWindow: 16,
  probeAfter: 1,
  disableAfter: 3,
  reenableWithin: 1,
  maxReenables: 5,
  keyMinInterval: 0.5,
  maxTracked: 64,
  minRTTWindow: 10,
  srttGain: 0.125,
  qdWindow: 1,
  qdMinSamples: 3,
  congestedDelay: 0.05,
  congestedHold: 0.5,
  cleanDelay: 0.025,
  increaseInterval: 0.5,
  climbHold: 2,
  ceilingHold: 30,
  ceilingFactor: 0.9,
  climbUtilization: 0.8,
  utilizationWindow: 2,
  decreaseFactor: 0.85,
  increaseFactor: 1.1,
  recoverFactor: 1.25,
  keyGrace: 1.5,
  startKbps: 3500,
  minKbps: 300,
  maxKbps: 20000,
  constrainedMaxKbps: 2500,
  holdBelowUtilization: 0.5,
  // the stream loop
  maxFPS: 60,
  keepalive: 5,
  // a still picture's sharper re-encodes (RefineSchedule): the first refineIdle after its last live picture, then one
  // every refineEvery until refineSmallInARow in a row came out no bigger than one live picture's budget, at most
  // videoRefines (skipped ones included); a refine's temporary rate: refineKbps
  refineIdle: 0.3,
  refineEvery: 0.1,
  videoRefines: 20,
  refineSmallInARow: 2,
  refineMinKbps: 4000,
  maxEncodeFailures: 3,
  keyFloor: 60,
  // a link stream's pictures (link.mjs): the encoder's VBV buffer in pictures' shares of the rate (linkBufferKbit)
  linkBufferPictures: 8,
});

/**
 * The VBV buffer (kbit) of a link stream's encoder at `kbps` and `fps` pictures a second: `linkBufferPictures` of one
 * picture's share. What it holds is what one picture may take — x264 gives a picture at most half of a buffer this
 * size — so after a pause a changed picture gets about four shares, the ones after it less, and none is so large that
 * the link (which releases what it is given at about the rate) is still sending it several pictures later. With the
 * one-second buffer this replaced, a new window was a picture of up to half a second's bits: half a second late on any
 * path, and at a low rate late past the viewer's patience (lost, asked for again, lost again).
 */
export function linkBufferKbit(t, kbps, fps) {
  return Math.max(1, Math.round((kbps / Math.max(fps, 1)) * t.linkBufferPictures));
}

/** The tuning with a ceiling (YOYO_VIDEO_MAX_KBPS, or a stream's `maxKbps`): the start and floor follow it down. */
export function limitedTuning(t, kbps, fromRequest = false) {
  if (kbps == null) return t;
  const maxKbps = Math.min(t.maxKbps, kbps);
  const minKbps = Math.min(t.minKbps, maxKbps);
  return { ...t, maxKbps, minKbps, startKbps: Math.min(Math.max(t.startKbps, minKbps), maxKbps), ...(fromRequest ? { requestMaxKbps: kbps } : {}) };
}

/** The bit-rate ceiling from the client's fresh `report.net`: test (a stream's maxKbps) / constrained / cellular / wifi. */
export function chooseProfile(net, t) {
  if (t.requestMaxKbps != null) return { name: "test", maxKbps: t.maxKbps };
  const base = net?.constrained === true ? ["constrained", t.constrainedMaxKbps] : net?.iface === "cellular" ? ["cellular", t.maxKbps] : ["wifi", null];
  return { name: base[0], maxKbps: Math.max(t.minKbps, Math.min(base[1] ?? t.maxKbps, t.maxKbps)) };
}

/** One live picture's share of the target rate, in bytes: kbps · 1000 / 8 / fps. */
export function liveBudget(kbps, fps) {
  return (kbps * 1000) / 8 / Math.max(fps, 1);
}

/**
 * A refine's rate (kbit/s) for a stream at `kbps`: twice that, at least `refineMinKbps`, never past `ceiling`; `kbps`
 * itself while the path is queueing (`congested`). A link stream (`linkFps`: its frame rate) also gets no more than
 * kbps · fps · refineEvery: refines one every refineEvery then add up to at most the rate the link's media layer set
 * (a refine's size is about the encoder's per-picture budget, rate / fps). The reference server's
 * StreamTuning.refineBitrate.
 */
export function refineKbps(t, { kbps, ceiling, congested = false, linkFps = null }) {
  if (congested) return kbps;
  let r = Math.min(ceiling, Math.max(kbps * 2, t.refineMinKbps));
  if (linkFps != null) r = Math.min(r, Math.floor(kbps * linkFps * t.refineEvery));
  return Math.max(kbps, r);
}

/**
 * When to send the sharper "refine" re-encodes of an unchanged picture, and when to stop (the reference server's
 * RefineSchedule): the first `refineIdle` after its live picture went out, then every `refineEvery` while the content
 * stays the same, until `refineSmallInARow` refines in a row came out no bigger than one live picture's budget (one
 * small refine alone is no proof: right after a scroll x264's VBV may be drained), or after `videoRefines`. A refine
 * the encoder skipped counts toward `videoRefines` but is not small: it is the rate control over budget, not a settled
 * picture. New content re-arms it, which also cancels a refine that was not yet due.
 */
export class RefineSchedule {
  constructor(t = TUNING) {
    this.idle = t.refineIdle;
    this.every = t.refineEvery;
    this.limit = t.videoRefines;
    this.smallInARow = t.refineSmallInARow;
    /** When the next refine is due; null: nothing to refine (done / nothing sent). */
    this.dueAt = null;
    /** Refines since the last live picture, and how many of the latest in a row were small. */
    this.sent = 0;
    this.smallRun = 0;
  }

  /** A live (changed-content) picture went out at `time`: refines again from the start. */
  noteLive(time) {
    this.sent = 0;
    this.smallRun = 0;
    this.dueAt = this.limit > 0 ? time + this.idle : null;
  }

  isDue(now) {
    return this.dueAt != null && now >= this.dueAt;
  }

  /** A refine went out at `time` with `bytes` (null: the encoder skipped it); `budget`: one live picture's bytes. */
  noteRefined(time, bytes, budget) {
    this.sent++;
    if (bytes != null && bytes <= budget) this.smallRun++;
    else this.smallRun = 0;
    this.dueAt = this.sent >= this.limit || this.smallRun >= this.smallInARow ? null : time + this.every;
  }

  /** No refine until the next live picture. */
  cancel() {
    this.dueAt = null;
  }
}

/** Nearest-rank summary of RTTs in ms; null without samples. */
export function rttSummary(values) {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b);
  const q = (p) => s[Math.min(s.length - 1, Math.max(0, Math.ceil(s.length * p) - 1))];
  return { minMs: s[0], p50Ms: q(0.5), p90Ms: q(0.9), samples: s.length };
}

export class FlowController {
  constructor(tuning = TUNING, frameInterval = null) {
    this.t = tuning;
    this.frameInterval = frameInterval;
    this.bitrateKbps = tuning.startKbps;
    this.acksStarted = false;
    this.disabled = false;
    this.reenables = 0;
    this.outstanding = [];
    this.lastAckSeq = 0;
    this.lastSentSeq = 0;
    this.lastAckAt = null;
    this.lastPictureAt = null;
    this.srtt = null;
    this.rttSamples = [];
    this.congestedSince = null;
    this.cleanSince = null;
    this.lastIncreaseAt = null;
    this.lastDecreaseAt = null;
    this.ceiling = null;
    this.profile = null;
    this.sentBytes = null;
    this.lastSampleAt = null;
    this.keyPending = false;
    this.lastKeyAt = null;
    this.lastWindowLimitedAt = null;
    this.counters = { windowLimited: 0, held: 0, probes: 0, keyRequests: 0, decreases: 0, increases: 0, climbs: 0, acks: 0 };
  }

  get window() {
    const rtt = this.minRTT;
    const i = this.frameInterval;
    if (rtt == null || !i) return this.t.videoWindow;
    const cover = Math.ceil((2 * rtt) / i) + 2;
    return Math.min(Math.max(this.t.videoWindow, cover), Math.max(this.t.videoWindow, this.t.maxVideoWindow));
  }

  get active() {
    return this.acksStarted && !this.disabled;
  }

  get minRTT() {
    if (!this.rttSamples.length) return null;
    let m = Infinity;
    for (const s of this.rttSamples) m = Math.min(m, s.rtt);
    return m;
  }

  rttSummaryAt(now, window) {
    return rttSummary(this.rttSamples.filter((s) => now - s.at <= window).map((s) => s.rtt * 1000));
  }

  get queueDelayMin() {
    const last = this.lastSampleAt;
    const m = this.minRTT;
    if (last == null || m == null) return null;
    let n = 0;
    let low = Infinity;
    for (let i = this.rttSamples.length - 1; i >= 0; i--) {
      const s = this.rttSamples[i];
      if (last - s.at > this.t.qdWindow) break;
      n++;
      low = Math.min(low, s.rtt);
    }
    if (n < Math.max(1, this.t.qdMinSamples)) return null;
    return Math.max(0, low - m);
  }

  ceilingAt(now) {
    return this.ceiling && now < this.ceiling.until ? this.ceiling.kbps : null;
  }

  get maxKbpsNow() {
    return Math.min(this.t.maxKbps, this.profile?.maxKbps ?? Infinity);
  }

  /** A (new) network profile: a ceiling under the current rate steps it down at once. Returns the new rate or null. */
  applyProfile(p) {
    this.profile = p;
    if (this.bitrateKbps <= this.maxKbpsNow) return null;
    this.bitrateKbps = this.maxKbpsNow;
    return this.bitrateKbps;
  }

  sentKbps(now) {
    if (!this.sentBytes) return null;
    let bytes = 0;
    for (const s of this.sentBytes) if (now - s.at <= this.t.utilizationWindow) bytes += s.bytes;
    return (bytes * 8) / 1000 / this.t.utilizationWindow;
  }

  // ------------------------------------------------------------ the window

  pictureSent(seq, now, bytes) {
    this.lastPictureAt = now;
    this.lastSentSeq = Math.max(this.lastSentSeq, seq);
    if (bytes != null) {
      const sent = this.sentBytes ?? [];
      sent.push({ at: now, bytes });
      this.sentBytes = sent.filter((s) => now - s.at <= this.t.utilizationWindow);
    }
    this.outstanding.push({ seq, sentAt: now });
    if ((!this.acksStarted || this.disabled) && this.outstanding.length > this.t.maxTracked) {
      this.outstanding.splice(0, this.outstanding.length - this.t.maxTracked);
    }
  }

  /** "open" | "probe" | { full: until }. Drops the window first when acks stalled. */
  gate(now) {
    this.checkStall(now);
    if (!this.active || this.outstanding.length < this.window) return "open";
    const since = Math.max(this.lastAckAt ?? -Infinity, this.lastPictureAt ?? -Infinity);
    if (now - since >= this.t.probeAfter) return "probe";
    return { full: since + this.t.probeAfter };
  }

  noteWindowLimited(now) {
    this.counters.windowLimited++;
    this.lastWindowLimitedAt = now;
  }

  contentLimited(now) {
    const sent = this.sentKbps(now);
    if (!(this.t.holdBelowUtilization > 0) || sent == null || sent >= this.t.holdBelowUtilization * this.bitrateKbps) return false;
    return this.lastWindowLimitedAt == null || now - this.lastWindowLimitedAt > this.t.utilizationWindow;
  }

  stallDeadline() {
    if (!this.active || !this.outstanding.length) return null;
    return Math.max(this.lastAckAt ?? -Infinity, this.outstanding[0].sentAt) + this.t.disableAfter;
  }

  /** True when it just dropped the window (acks stopped for disableAfter while pictures are out). */
  checkStall(now) {
    const d = this.stallDeadline();
    if (d == null || now < d) return false;
    this.disabled = true;
    this.outstanding = [];
    return true;
  }

  // ------------------------------------------------------------ acks

  /** A cumulative ack (maybe a key request). Returns the new bit rate (kbps) when it changed, else null. */
  ack(seq, keyframe, now) {
    if (keyframe) this.requestKey();
    if (this.disabled) {
      let newest = null;
      while (this.outstanding.length && this.outstanding[0].seq <= seq) newest = this.outstanding.shift();
      if (this.reenables >= this.t.maxReenables || !newest || now - newest.sentAt > this.t.reenableWithin) return null;
      this.disabled = false;
      this.reenables++;
      this.lastAckAt = now;
      this.lastAckSeq = Math.max(this.lastAckSeq, seq);
      this.counters.acks++;
      return this.rttSample(Math.max(0, now - newest.sentAt), now);
    }
    this.counters.acks++;
    this.acksStarted = true;
    this.lastAckAt = now;
    if (seq <= this.lastAckSeq) return null;
    this.lastAckSeq = seq;
    let newest = null;
    while (this.outstanding.length && this.outstanding[0].seq <= seq) newest = this.outstanding.shift();
    if (!newest) return null;
    return this.rttSample(Math.max(0, now - newest.sentAt), now);
  }

  rttSample(rtt, now) {
    this.srtt = this.srtt == null ? rtt : this.srtt + this.t.srttGain * (rtt - this.srtt);
    this.rttSamples.push({ at: now, rtt });
    this.rttSamples = this.rttSamples.filter((s) => now - s.at <= this.t.minRTTWindow);
    this.lastSampleAt = now;
    const qd = this.queueDelayMin;
    if (qd == null) return null;
    if (qd > this.t.congestedDelay) {
      this.cleanSince = null;
      if (this.lastKeyAt != null && now - this.lastKeyAt < this.t.keyGrace) {
        this.congestedSince = null;
        return null;
      }
      const since = this.congestedSince ?? now;
      this.congestedSince = since;
      if (now - since < this.t.congestedHold) return null;
      this.congestedSince = now;
      if (this.contentLimited(now)) {
        this.counters.held++;
        return null;
      }
      return this.decrease(now);
    }
    this.congestedSince = null;
    if (qd >= this.t.cleanDelay) {
      this.cleanSince = null;
      return null;
    }
    const clean = this.cleanSince ?? now;
    this.cleanSince = clean;
    return this.increase(clean, now);
  }

  increase(clean, now) {
    const t = this.t;
    if (now - (this.lastIncreaseAt ?? -Infinity) < t.increaseInterval || now - (this.lastDecreaseAt ?? -Infinity) < t.increaseInterval) return null;
    const cap = Math.min(this.maxKbpsNow, this.ceilingAt(now) ?? Infinity);
    let next;
    if (this.bitrateKbps < t.startKbps) {
      next = Math.min(t.startKbps, cap, Math.round(this.bitrateKbps * t.recoverFactor));
    } else {
      const climbInterval = Math.max(t.increaseInterval, t.qdWindow);
      const sent = this.sentKbps(now);
      const due = now - clean >= t.climbHold && now - (this.lastIncreaseAt ?? -Infinity) >= climbInterval && (sent == null || sent >= t.climbUtilization * this.bitrateKbps);
      if (!due) return null;
      next = Math.min(cap, Math.round(this.bitrateKbps * t.increaseFactor));
    }
    if (next <= this.bitrateKbps) return null;
    if (next > t.startKbps) this.counters.climbs++;
    this.bitrateKbps = next;
    this.lastIncreaseAt = now;
    this.counters.increases++;
    return next;
  }

  decrease(now) {
    const t = this.t;
    this.lastDecreaseAt = now;
    this.counters.decreases++;
    this.ceiling = { kbps: Math.max(t.minKbps, Math.round(this.bitrateKbps * t.ceilingFactor)), until: now + t.ceilingHold };
    if (this.bitrateKbps <= t.minKbps) return null;
    this.bitrateKbps = Math.max(t.minKbps, Math.round(this.bitrateKbps * t.decreaseFactor));
    return this.bitrateKbps;
  }

  // ------------------------------------------------------------ key frames

  requestKey() {
    this.counters.keyRequests++;
    this.keyPending = true;
  }

  get keyDueAt() {
    return this.keyPending ? (this.lastKeyAt ?? -Infinity) + this.t.keyMinInterval : null;
  }

  keyDue(now) {
    const d = this.keyDueAt;
    return d != null && now >= d;
  }

  noteKeySent(now) {
    this.lastKeyAt = now;
    this.keyPending = false;
  }
}

// ---------------------------------------------------------------- the client's reports (lenient: never fail an ack)

const num = (v) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : undefined);
const pick = (v, allowed) => (typeof v === "string" && allowed.includes(v) ? v : undefined);
const bool = (v) => (typeof v === "boolean" ? v : undefined);

/** `report.net`, unknown values dropped; null when not an object. */
export function parseNetReport(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const rtt = raw.inputRttMs && typeof raw.inputRttMs === "object" ? raw.inputRttMs : {};
  const n = num(rtt.n);
  const f = num(raw.failures);
  return {
    route: pick(raw.route, ["lan", "direct", "tunnel"]),
    iface: pick(raw.iface, ["wifi", "cellular", "wired", "other"]),
    radio: pick(raw.radio, ["5g", "lte", "3g", "other"]),
    expensive: bool(raw.expensive),
    constrained: bool(raw.constrained),
    inputRttP50Ms: num(rtt.p50),
    inputRttP90Ms: num(rtt.p90),
    inputRttSamples: n === undefined ? undefined : Math.round(Math.min(n, 100_000)),
    rxKbps: num(raw.rxKbps),
    failures: f === undefined ? undefined : Math.round(Math.min(f, 10_000)),
  };
}

const PLAYOUT_NUMBERS = ["fps", "gapP50Ms", "gapP90Ms", "arrivalGapP50Ms", "arrivalGapP90Ms", "hitchesPerSec", "stall150PerSec", "stall300PerSec", "bufferMs", "jitterP95Ms", "touchBufferMs", "droppedPerSec", "decodeMs", "refreshHz", "paceMs", "bufferCapMs"];

/** A playout report: null when not an object or its mode is unknown; bad numbers dropped, unknown keys ignored. */
export function parsePlayoutReport(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  if (raw.mode !== "smooth" && raw.mode !== "latency") return null;
  const out = { mode: raw.mode };
  for (const k of PLAYOUT_NUMBERS) if (num(raw[k]) !== undefined) out[k] = raw[k];
  const net = parseNetReport(raw.net);
  if (net) out.net = net;
  return out;
}

/** The stats line's `phone …` tail: `smooth 59.6 fps hitch 0.4/s stall 0.1/s buf 52 ms jit 48 ms`. */
export function playoutLine(r) {
  const f = (v, d = 1) => (Math.round(v * 10 ** d) / 10 ** d).toString();
  let s = r.mode;
  if (r.fps !== undefined) s += ` ${f(r.fps)} fps`;
  if (r.hitchesPerSec !== undefined) s += ` hitch ${f(r.hitchesPerSec)}/s`;
  if (r.stall150PerSec !== undefined) s += ` stall ${f(r.stall150PerSec)}/s`;
  if (r.bufferMs !== undefined) s += ` buf ${Math.round(r.bufferMs)} ms`;
  if (r.jitterP95Ms !== undefined) s += ` jit ${Math.round(r.jitterP95Ms)} ms`;
  return s;
}

export const NET_THRESHOLDS = Object.freeze({ rttPoorMs: 250, rttFairMs: 100, jitterPoorMs: 80, jitterFairMs: 30, failuresPoor: 3, failuresFair: 1, minSamples: 5 });

/** The ack answer's `net` from the stream's ack round trips (rttSummary) and the client's fresh `report.net`. */
export function gradeNet(acks, client) {
  const T = NET_THRESHOLDS;
  const ackUsable = acks && acks.samples >= T.minSamples ? acks : null;
  const failures = client?.failures ?? 0;
  let rtt = null;
  let jitter = null;
  let byInput = false;
  if (ackUsable) {
    rtt = ackUsable.p90Ms;
    jitter = ackUsable.p90Ms - ackUsable.minMs;
  } else if (client && (client.inputRttSamples ?? 0) >= T.minSamples && client.inputRttP90Ms !== undefined) {
    rtt = client.inputRttP90Ms;
    jitter = client.inputRttP50Ms !== undefined ? Math.max(0, rtt - client.inputRttP50Ms) : null;
    byInput = true;
  }
  if (rtt == null) {
    if (failures >= T.failuresFair) return { grade: failures >= T.failuresPoor ? "poor" : "fair", reasons: ["failures", "few-samples"] };
    return { grade: "unknown", reasons: ["few-samples"] };
  }
  const j = jitter ?? 0;
  const poor = [rtt > T.rttPoorMs, j > T.jitterPoorMs, failures >= T.failuresPoor];
  const fair = [rtt > T.rttFairMs, j > T.jitterFairMs, failures >= T.failuresFair];
  const grade = poor.some(Boolean) ? "poor" : fair.some(Boolean) ? "fair" : "good";
  const level = grade === "poor" ? poor : fair;
  const reasons = grade === "good" ? [] : ["rtt", "jitter", "failures"].filter((_, i) => level[i]);
  const r1 = (v) => Math.round(v * 10) / 10;
  return {
    grade,
    ...(ackUsable ? { rttMs: { min: r1(ackUsable.minMs), p50: r1(ackUsable.p50Ms), p90: r1(ackUsable.p90Ms) } } : {}),
    ...(jitter != null ? { jitterMs: r1(jitter) } : {}),
    reasons,
    ...(byInput ? { byInput: true } : {}),
  };
}

/**
 * One live stream's flow: the controller, the client's latest report and network, the grade (recomputed at most every
 * second). The stream loop and the ack route share it.
 */
export class StreamFlow {
  static qualityWindow = 10;
  static qualityInterval = 1;

  constructor({ id, tuning = TUNING, frameInterval = null, clock, wake = () => {}, log = () => {} }) {
    this.id = id;
    this.c = new FlowController(tuning, frameInterval);
    this.clock = clock;
    this.wake = wake;
    this.log = log;
    this.report = null;
    this.clientNet = null;
    this.quality = null;
    this.loggedGrade = "unknown";
    /** A new bit rate for the loop to apply (kbps), or null. */
    this.pendingKbps = null;
    this.c.applyProfile(chooseProfile(null, tuning));
  }

  freshClientNet(now) {
    return this.clientNet && now - this.clientNet.at <= StreamFlow.qualityWindow ? this.clientNet.report : null;
  }

  updateProfile(now) {
    const p = chooseProfile(this.freshClientNet(now), this.c.t);
    if (this.c.profile && p.name === this.c.profile.name && p.maxKbps === this.c.profile.maxKbps) return;
    const before = this.c.bitrateKbps;
    const k = this.c.applyProfile(p);
    this.log(`profile ${p.name}: max ${p.maxKbps} kbps`);
    if (k != null) {
      this.pendingKbps = k;
      this.log(`bitrate ${before} → ${k} kbps (profile ${p.name})`);
    }
  }

  /** An ack (with its report, already parsed or null). */
  ack(seq, keyframe, report) {
    const now = this.clock();
    if (report) {
      this.report = report;
      if (report.net) this.clientNet = { report: report.net, at: now };
    }
    const wasDisabled = this.c.disabled;
    const before = this.c.bitrateKbps;
    const k = this.c.ack(seq, keyframe, now);
    if (k != null) {
      this.pendingKbps = k;
      if (k < before || k >= Math.min(this.c.maxKbpsNow, this.c.ceilingAt(now) ?? Infinity)) this.log(`bitrate ${before} → ${k} kbps`);
    }
    this.updateProfile(now);
    if (wasDisabled && !this.c.disabled) this.log("acks are back; flow-control window on again");
    this.wake();
  }

  /** The ack answer's `net`, recomputed at most every qualityInterval; the grade logged when it changes. */
  netQuality() {
    const now = this.clock();
    if (this.quality && now - this.quality.at < StreamFlow.qualityInterval) return this.quality.value;
    const { byInput, ...value } = gradeNet(this.c.rttSummaryAt(now, StreamFlow.qualityWindow), this.freshClientNet(now));
    this.quality = { value, at: now };
    if (value.grade !== this.loggedGrade) {
      this.loggedGrade = value.grade;
      const rtt = value.rttMs ? ` rtt ${value.rttMs.min}/${value.rttMs.p50}/${value.rttMs.p90} ms` : "";
      this.log(`phone net:${rtt} → ${value.grade}${byInput ? " by input" : ""}${value.reasons.length ? ` (${value.reasons.join(", ")})` : ""}`);
    }
    return value;
  }
}
