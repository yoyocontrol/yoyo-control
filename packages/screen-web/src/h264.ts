/**
 * H.264 access units of the screen stream (docs/PROTOCOL.md「视频流」: one access unit per `video/h264` part, Annex-B with
 * 4-byte start codes, SPS + PPS in front of every key picture, no B frames) turned into what WebCodecs wants: length-
 * prefixed (AVCC) samples, an `avcC` description and an `avc1.PPCCLL` codec string. Always AVCC: Safari's
 * VideoDecoder doesn't promise the Annex-B mode. Ported from the iOS AnnexB / ScreenVideoDecoderCore. HEVC is in
 * `hevc.ts` (asked for only where the browser decodes it in hardware, `preferredCodecs`).
 */

/** The NAL units of an Annex-B byte stream (3- or 4-byte start codes), without their start codes. Emulation
 *  prevention bytes stay; bytes before the first start code are dropped. */
export function nalUnits(data: Uint8Array): Uint8Array[] {
  const units: Uint8Array[] = [];
  const n = data.length;
  let start = -1;
  let i = 0;
  while (i + 2 < n) {
    // 00 00 01 (a 4-byte code is a zero byte before it); a byte > 1 at i + 2 rules out i, i + 1 and i + 2
    if (data[i + 2]! > 1) {
      i += 3;
      continue;
    }
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1) {
      if (start >= 0) {
        let end = i;
        if (end > start && data[end - 1] === 0) end -= 1;
        if (end > start) units.push(data.subarray(start, end));
      }
      start = i + 3;
      i += 3;
    } else {
      i += 1;
    }
  }
  if (start >= 0 && start < n) units.push(data.subarray(start, n));
  return units;
}

/** The units, each behind its 4-byte big-endian length. */
export function lengthPrefixed(units: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(units.reduce((s, u) => s + 4 + u.length, 0));
  const view = new DataView(out.buffer);
  let o = 0;
  for (const u of units) {
    view.setUint32(o, u.length);
    out.set(u, o + 4);
    o += 4 + u.length;
  }
  return out;
}

export const nalType = (unit: Uint8Array) => (unit[0] ?? 0) & 0x1f;
const SPS = 7;
const PPS = 8;
const AUD = 9;
const IDR = 5;

/** One access unit taken apart: its parameter sets (in order), and the units a sample carries. */
export interface AccessUnit {
  sps: Uint8Array[];
  pps: Uint8Array[];
  /** Slices (and SEI): what goes into the sample. */
  slices: Uint8Array[];
  /** An IDR slice is in it. */
  idr: boolean;
}

export function splitAccessUnit(data: Uint8Array): AccessUnit {
  const au: AccessUnit = { sps: [], pps: [], slices: [], idr: false };
  for (const u of nalUnits(data)) {
    if (u.length === 0) continue;
    const t = nalType(u);
    if (t === SPS) au.sps.push(u);
    else if (t === PPS) au.pps.push(u);
    else if (t === AUD) continue;
    else {
      if (t === IDR) au.idr = true;
      au.slices.push(u);
    }
  }
  return au;
}

const hex2 = (v: number) => v.toString(16).padStart(2, "0");

/** `avc1.PPCCLL` from an SPS (profile_idc, constraint flags, level_idc); null when it is too short. */
export function codecString(sps: Uint8Array): string | null {
  if (sps.length < 4) return null;
  return `avc1.${hex2(sps[1]!)}${hex2(sps[2]!)}${hex2(sps[3]!)}`;
}

/**
 * The AVCDecoderConfigurationRecord (ISO/IEC 14496-15 §5.2.4.1) for these parameter sets, with 4-byte NAL lengths.
 * The high-profile extension (chroma format, bit depths) is left out: decoders take it from the SPS.
 */
export function avcC(sps: Uint8Array[], pps: Uint8Array[]): Uint8Array | null {
  const first = sps[0];
  if (!first || first.length < 4 || pps.length === 0 || sps.length > 31 || pps.length > 255) return null;
  const size = 6 + sps.reduce((s, u) => s + 2 + u.length, 0) + 1 + pps.reduce((s, u) => s + 2 + u.length, 0);
  const out = new Uint8Array(size);
  let o = 0;
  out[o++] = 1; // configurationVersion
  out[o++] = first[1]!; // AVCProfileIndication
  out[o++] = first[2]!; // profile_compatibility
  out[o++] = first[3]!; // AVCLevelIndication
  out[o++] = 0xfc | 3; // reserved 6 bits + lengthSizeMinusOne = 3
  out[o++] = 0xe0 | sps.length; // reserved 3 bits + numOfSequenceParameterSets
  for (const u of sps) {
    out[o++] = u.length >> 8;
    out[o++] = u.length & 0xff;
    out.set(u, o);
    o += u.length;
  }
  out[o++] = pps.length;
  for (const u of pps) {
    out[o++] = u.length >> 8;
    out[o++] = u.length & 0xff;
    out.set(u, o);
    o += u.length;
  }
  return out;
}

/** Byte-equal. */
export function sameBytes(a: Uint8Array | null | undefined, b: Uint8Array | null | undefined): boolean {
  if (!a || !b || a.length !== b.length) return a === b;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
