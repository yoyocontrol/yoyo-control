const mbps = (bps) => (typeof bps === "number" ? Math.round(bps / 1e4) / 100 : null);
const num = (v, d = 0) => (typeof v === "number" && Number.isFinite(v) ? v : d);
const numOrNull = (v) => (typeof v === "number" && Number.isFinite(v) ? v : null);
/** The server's `link.probe.done` as its half of the report. */
export function probeServerReport(m) {
    return {
        targetMbps: num(m.targetMbps),
        maxTargetMbps: num(m.maxTargetMbps),
        encoderMbps: num(m.encoderMbps),
        fpsCap: num(m.fpsCap),
        sentMbps: numOrNull(m.sentMbps),
        frames: num(m.frames),
        bytes: num(m.bytes),
        rateCuts: num(m.rateCuts),
        rateLossCuts: num(m.rateLossCuts),
        retransmits: num(m.retransmits),
        jitterMs: numOrNull(m.jitterMs),
        reason: typeof m.reason === "string" ? m.reason : "done",
    };
}
/** (min, p50, p90) of RTT samples; null without any. */
export function rttSummary(samples) {
    if (!samples.length)
        return null;
    const v = [...samples].sort((a, b) => a - b);
    const at = (p) => v[Math.round((v.length - 1) * p)];
    return [v[0], at(0.5), at(0.9)];
}
/** The client's half of the report: the media counters' change over the test and the probe stream's counters. */
export function probeReport(p) {
    const d = (k) => Math.max(0, num(p.after?.[k]) - num(p.before?.[k]));
    const received = d("mediaReceived");
    const missing = d("mediaMissing");
    const loaded = rttSummary(p.rtts);
    const r2 = (v) => (v === null ? null : Math.round(v * 100) / 100);
    return {
        transport: "rtc",
        path: p.path,
        iface: p.iface,
        durationMs: p.durationMs,
        rttIdleMs: p.rttIdleMs,
        rttP50Ms: loaded ? loaded[1] : null,
        rttP90Ms: loaded ? loaded[2] : null,
        frames: num(p.probe?.frames),
        receivedMbps: mbps(p.probe?.meanBps),
        peakMbps: mbps(p.probe?.peakBps),
        finalMbps: mbps(p.probe?.finalBps),
        finalFps: p.probe?.finalFps == null ? null : Math.round(p.probe.finalFps * 10) / 10,
        lossPct: received + missing > 0 ? r2((missing * 100) / (received + missing)) : null,
        fecRecovered: d("fecRecovered"),
        nackRecovered: d("nackRecovered"),
        lostFrames: d("framesLost"),
        skippedFrames: d("framesSkipped"),
        freezes: d("freezes"),
        freezeMs: d("freezeMs"),
        server: p.done ? probeServerReport(p.done) : null,
    };
}
