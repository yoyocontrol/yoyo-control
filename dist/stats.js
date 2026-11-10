import { netQualityLine } from "./net.js";
/** `h264 · 30 fps · 412 KB/s · 2.1 ms` (`· live` while interactive). */
export function streamLine(s) {
    const parts = [s.codec, `${Math.round(s.fps)} fps`, `${Math.round(s.kilobytesPerSecond)} KB/s`];
    if (s.decodeMs !== null)
        parts.push(`${s.decodeMs.toFixed(1)} ms`);
    if (s.interactive)
        parts.push("live");
    return parts.join(" · ");
}
/** The playout report's line: `smooth · 60 Hz · pace 33 · gap 33/41 · arr 33/52 · hitch 0.3/s · stall 0.3/0.0/s ·
 *  buf 28 ms · jit 24 · cap 100 · drop 0.5/s`; interactive: `responsive · … · touch 21 ms`. */
export function playoutReportLine(r) {
    const ms = (v) => (v === undefined ? "-" : String(Math.round(v)));
    const parts = [r.mode === "smooth" ? "smooth" : "responsive"];
    if (r.refreshHz !== undefined)
        parts.push(`${Math.round(r.refreshHz)} Hz`);
    if (r.paceMs !== undefined)
        parts.push(`pace ${Math.round(r.paceMs)}`);
    parts.push(`gap ${ms(r.gapP50Ms)}/${ms(r.gapP90Ms)}`, `arr ${ms(r.arrivalGapP50Ms)}/${ms(r.arrivalGapP90Ms)}`);
    if (r.hitchesPerSec !== undefined)
        parts.push(`hitch ${r.hitchesPerSec.toFixed(1)}/s`);
    if (r.stall150PerSec !== undefined)
        parts.push(`stall ${r.stall150PerSec.toFixed(1)}/${(r.stall300PerSec ?? 0).toFixed(1)}/s`);
    if (r.bufferMs !== undefined)
        parts.push(`buf ${Math.round(r.bufferMs)} ms`);
    if (r.jitterP95Ms !== undefined)
        parts.push(`jit ${Math.round(r.jitterP95Ms)}`);
    if (r.bufferCapMs !== undefined)
        parts.push(`cap ${Math.round(r.bufferCapMs)}`);
    if (r.touchBufferMs !== undefined)
        parts.push(`touch ${Math.round(r.touchBufferMs)} ms`);
    if (r.droppedPerSec !== undefined)
        parts.push(`drop ${r.droppedPerSec.toFixed(1)}/s`);
    return parts.join(" · ");
}
/** The computer's part of a touch's way (capture 14 + encode ~12 + write, ms). */
export const LATENCY_COMPUTER_MS = 30;
/**
 * How long a touch takes to show here (ms; null: no round trip known), as the iOS kit's `ScreenLatencyEstimate`: the
 * input's way (half the input round trip's p50; half the path's min while no input was answered), the computer's part,
 * the picture's way back (half the path's min; half the input p50 without one), the playout's hold, the decode and one
 * refresh.
 */
export function latencyEstimate(o) {
    const ms = (v) => (v !== null && Number.isFinite(v) && v >= 0 ? v : null);
    const input = ms(o.inputRttP50Ms), path = ms(o.rttMinMs);
    const up = input ?? path, down = path ?? input;
    if (up === null || down === null)
        return null;
    const hz = ms(o.refreshHz) || 60;
    return up / 2 + LATENCY_COMPUTER_MS + down / 2 + (ms(o.holdMs) ?? 0) + (ms(o.decodeMs) ?? 0) + 1000 / hz;
}
/** `audio 120 ms (buf 118) · 0 underruns · 0 drops · 96 kbps` (`audio · 96 kbps` before it plays). */
export function audioStatsLine(a) {
    if (a.depthMs === null)
        return `audio · ${Math.round(a.kbps)} kbps`;
    return `audio ${Math.round(a.depthMs)} ms (buf ${Math.round(a.bufferedMs ?? 0)}) · ${a.underruns} underruns · ${a.drops} drops · ${Math.round(a.kbps)} kbps`;
}
/** The stats line's rows (1–4): stream · way · connection; playout · latency; the network; the sound. */
export function statsLines(i) {
    const s = i.stream;
    const lines = [[streamLine(s), i.way, i.connection].filter((p) => p).join(" · ")];
    const latency = latencyEstimate({ inputRttP50Ms: s.inputRttP50Ms, rttMinMs: s.rttMinMs, holdMs: s.playout?.bufferMs ?? null, decodeMs: s.decodeMs, refreshHz: s.playout?.refreshHz ?? null });
    const second = [s.playout ? playoutReportLine(s.playout) : null, latency !== null ? `~${Math.round(latency)} ms` : null].filter((p) => p !== null);
    if (second.length)
        lines.push(second.join(" · "));
    const net = i.linkLine ?? (s.net ? netQualityLine(s.net) : null);
    if (net)
        lines.push(net);
    if (i.audio)
        lines.push(audioStatsLine(i.audio));
    return lines;
}
