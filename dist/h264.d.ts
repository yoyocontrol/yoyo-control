/**
 * H.264 access units of the screen stream (docs/PROTOCOL.md「视频流」: one access unit per `video/h264` part, Annex-B with
 * 4-byte start codes, SPS + PPS in front of every key picture, no B frames) turned into what WebCodecs wants: length-
 * prefixed (AVCC) samples, an `avcC` description and an `avc1.PPCCLL` codec string. Always AVCC: Safari's
 * VideoDecoder doesn't promise the Annex-B mode. Ported from the iOS AnnexB / ScreenVideoDecoderCore. HEVC is in
 * `hevc.ts` (asked for only where the browser decodes it in hardware, `preferredCodecs`).
 */
/** The NAL units of an Annex-B byte stream (3- or 4-byte start codes), without their start codes. Emulation
 *  prevention bytes stay; bytes before the first start code are dropped. */
export declare function nalUnits(data: Uint8Array): Uint8Array[];
/** The units, each behind its 4-byte big-endian length. */
export declare function lengthPrefixed(units: Uint8Array[]): Uint8Array;
export declare const nalType: (unit: Uint8Array) => number;
/** One access unit taken apart: its parameter sets (in order), and the units a sample carries. */
export interface AccessUnit {
    sps: Uint8Array[];
    pps: Uint8Array[];
    /** Slices (and SEI): what goes into the sample. */
    slices: Uint8Array[];
    /** An IDR slice is in it. */
    idr: boolean;
}
export declare function splitAccessUnit(data: Uint8Array): AccessUnit;
/** `avc1.PPCCLL` from an SPS (profile_idc, constraint flags, level_idc); null when it is too short. */
export declare function codecString(sps: Uint8Array): string | null;
/**
 * The AVCDecoderConfigurationRecord (ISO/IEC 14496-15 §5.2.4.1) for these parameter sets, with 4-byte NAL lengths.
 * The high-profile extension (chroma format, bit depths) is left out: decoders take it from the SPS.
 */
export declare function avcC(sps: Uint8Array[], pps: Uint8Array[]): Uint8Array | null;
/** Byte-equal. */
export declare function sameBytes(a: Uint8Array | null | undefined, b: Uint8Array | null | undefined): boolean;
