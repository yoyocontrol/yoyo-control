/**
 * HEVC access units of the screen stream (docs/PROTOCOL.md「视频流」: one access unit per `video/hevc` part, Annex-B,
 * VPS + SPS + PPS in front of every key picture) turned into what WebCodecs wants, as `h264.ts` does for H.264:
 * length-prefixed samples, an `hvcC` description (ISO/IEC 14496-15 §8.3.3.1) and an `hvc1.…` codec string (its
 * Annex E). The fields come from the SPS's profile_tier_level and the few values after it; the rest of the record
 * takes the "unknown" values decoders accept.
 */
import { nalUnits } from "./h264.js";
export const hevcNalType = (unit) => ((unit[0] ?? 0) >> 1) & 0x3f;
const VPS = 32;
const SPS = 33;
const PPS = 34;
const AUD = 35;
export function splitHevcAccessUnit(data) {
    const au = { vps: [], sps: [], pps: [], slices: [], idr: false };
    for (const u of nalUnits(data)) {
        if (u.length < 2)
            continue;
        const t = hevcNalType(u);
        if (t === VPS)
            au.vps.push(u);
        else if (t === SPS)
            au.sps.push(u);
        else if (t === PPS)
            au.pps.push(u);
        else if (t === AUD)
            continue;
        else {
            if (t >= 16 && t <= 21)
                au.idr = true;
            au.slices.push(u);
        }
    }
    return au;
}
/** A unit's payload without its 2-byte header and with the emulation prevention bytes (00 00 03) taken out. */
function rbsp(unit) {
    const out = new Uint8Array(unit.length);
    let n = 0;
    let zeros = 0;
    for (let i = 2; i < unit.length; i++) {
        const b = unit[i];
        if (zeros >= 2 && b === 3) {
            zeros = 0;
            continue;
        }
        zeros = b === 0 ? zeros + 1 : 0;
        out[n++] = b;
    }
    return out.subarray(0, n);
}
class Bits {
    pos = 0;
    data;
    constructor(data) {
        this.data = data;
    }
    bit() {
        const byte = this.data[this.pos >> 3];
        if (byte === undefined)
            throw new RangeError("past the end");
        const b = (byte >> (7 - (this.pos & 7))) & 1;
        this.pos++;
        return b;
    }
    bits(n) {
        let v = 0;
        for (let i = 0; i < n; i++)
            v = v * 2 + this.bit();
        return v;
    }
    skip(n) {
        this.pos += n;
    }
    /** Exp-Golomb, unsigned. */
    ue() {
        let zeros = 0;
        while (this.bit() === 0)
            if (++zeros > 31)
                throw new RangeError("bad ue(v)");
        return 2 ** zeros - 1 + this.bits(zeros);
    }
}
/** The SPS's profile_tier_level, chroma format and bit depths; null when it is too short or malformed. */
export function parseHevcSps(sps) {
    const r = rbsp(sps);
    if (r.length < 13)
        return null;
    try {
        const maxSubLayersMinus1 = (r[0] >> 1) & 0x07;
        const temporalIdNested = (r[0] & 1) === 1;
        const info = {
            profileSpace: r[1] >> 6,
            tier: (r[1] >> 5) & 1,
            profileIdc: r[1] & 0x1f,
            compatibility: ((r[2] << 24) | (r[3] << 16) | (r[4] << 8) | r[5]) >>> 0,
            constraints: r.slice(6, 12),
            levelIdc: r[12],
            maxSubLayersMinus1,
            temporalIdNested,
        };
        const b = new Bits(r);
        b.skip(13 * 8);
        // the sub-layers' profile / level, skipped
        const present = [];
        for (let i = 0; i < maxSubLayersMinus1; i++)
            present.push([b.bit(), b.bit()]);
        if (maxSubLayersMinus1 > 0)
            for (let i = maxSubLayersMinus1; i < 8; i++)
                b.skip(2);
        for (const [profile, level] of present) {
            if (profile)
                b.skip(88);
            if (level)
                b.skip(8);
        }
        b.ue(); // sps_seq_parameter_set_id
        const chromaFormatIdc = b.ue();
        if (chromaFormatIdc === 3)
            b.skip(1); // separate_colour_plane_flag
        b.ue(); // pic_width_in_luma_samples
        b.ue(); // pic_height_in_luma_samples
        if (b.bit())
            for (let i = 0; i < 4; i++)
                b.ue(); // the conformance window
        const bitDepthLumaMinus8 = b.ue();
        const bitDepthChromaMinus8 = b.ue();
        if (chromaFormatIdc > 3 || bitDepthLumaMinus8 > 7 || bitDepthChromaMinus8 > 7)
            return null;
        return { ...info, chromaFormatIdc, bitDepthLumaMinus8, bitDepthChromaMinus8 };
    }
    catch {
        return null;
    }
}
/** `hvc1.<space><profile>.<compatibility, bit-reversed hex>.<L|H><level>[.<constraint bytes>]` (ISO/IEC 14496-15 Annex E). */
export function hevcCodecString(sps) {
    const s = parseHevcSps(sps);
    if (!s)
        return null;
    let reversed = 0;
    for (let i = 0; i < 32; i++)
        if ((s.compatibility >>> i) & 1)
            reversed |= 1 << (31 - i);
    const constraints = [...s.constraints];
    while (constraints.length && constraints[constraints.length - 1] === 0)
        constraints.pop();
    const space = ["", "A", "B", "C"][s.profileSpace];
    return [`hvc1`, `${space}${s.profileIdc}`, (reversed >>> 0).toString(16).toUpperCase(), `${s.tier ? "H" : "L"}${s.levelIdc}`, ...constraints.map((c) => c.toString(16).toUpperCase())].join(".");
}
/** The HEVCDecoderConfigurationRecord for these parameter sets, with 4-byte NAL lengths; null without an SPS it can read. */
export function hvcC(vps, sps, pps) {
    const first = sps[0];
    const s = first && parseHevcSps(first);
    if (!s || vps.length === 0 || pps.length === 0)
        return null;
    const arrays = [
        [VPS, vps],
        [SPS, sps],
        [PPS, pps],
    ];
    const size = 23 + arrays.reduce((n, [, units]) => n + 3 + units.reduce((m, u) => m + 2 + u.length, 0), 0);
    if (arrays.some(([, units]) => units.length > 0xffff || units.some((u) => u.length > 0xffff)))
        return null;
    const out = new Uint8Array(size);
    let o = 0;
    out[o++] = 1; // configurationVersion
    out[o++] = (s.profileSpace << 6) | (s.tier << 5) | s.profileIdc;
    out[o++] = s.compatibility >>> 24;
    out[o++] = (s.compatibility >>> 16) & 0xff;
    out[o++] = (s.compatibility >>> 8) & 0xff;
    out[o++] = s.compatibility & 0xff;
    out.set(s.constraints, o);
    o += 6;
    out[o++] = s.levelIdc;
    out[o++] = 0xf0; // reserved 4 bits + min_spatial_segmentation_idc = 0 (unknown)
    out[o++] = 0x00;
    out[o++] = 0xfc; // reserved 6 bits + parallelismType = 0 (unknown)
    out[o++] = 0xfc | s.chromaFormatIdc;
    out[o++] = 0xf8 | s.bitDepthLumaMinus8;
    out[o++] = 0xf8 | s.bitDepthChromaMinus8;
    out[o++] = 0; // avgFrameRate = 0 (unknown)
    out[o++] = 0;
    // constantFrameRate 0, numTemporalLayers, temporalIdNested, lengthSizeMinusOne = 3
    out[o++] = (((s.maxSubLayersMinus1 + 1) & 7) << 3) | ((s.temporalIdNested ? 1 : 0) << 2) | 3;
    out[o++] = arrays.length;
    for (const [type, units] of arrays) {
        out[o++] = 0x80 | type; // array_completeness = 1
        out[o++] = units.length >> 8;
        out[o++] = units.length & 0xff;
        for (const u of units) {
            out[o++] = u.length >> 8;
            out[o++] = u.length & 0xff;
            out.set(u, o);
            o += u.length;
        }
    }
    return out;
}
