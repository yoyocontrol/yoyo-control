export declare const hevcNalType: (unit: Uint8Array) => number;
/** One HEVC access unit taken apart: its parameter sets (in order), and the units a sample carries. */
export interface HevcAccessUnit {
    vps: Uint8Array[];
    sps: Uint8Array[];
    pps: Uint8Array[];
    /** Slices (and SEI): what goes into the sample. */
    slices: Uint8Array[];
    /** A random access picture is in it (BLA / IDR / CRA). */
    idr: boolean;
}
export declare function splitHevcAccessUnit(data: Uint8Array): HevcAccessUnit;
/** What the decoder configuration needs from an SPS. */
export interface HevcSpsInfo {
    profileSpace: number;
    tier: number;
    profileIdc: number;
    /** general_profile_compatibility_flags, bit 31 = flag 0. */
    compatibility: number;
    /** The 6 bytes from general_progressive_source_flag on. */
    constraints: Uint8Array;
    levelIdc: number;
    maxSubLayersMinus1: number;
    temporalIdNested: boolean;
    chromaFormatIdc: number;
    bitDepthLumaMinus8: number;
    bitDepthChromaMinus8: number;
}
/** The SPS's profile_tier_level, chroma format and bit depths; null when it is too short or malformed. */
export declare function parseHevcSps(sps: Uint8Array): HevcSpsInfo | null;
/** `hvc1.<space><profile>.<compatibility, bit-reversed hex>.<L|H><level>[.<constraint bytes>]` (ISO/IEC 14496-15 Annex E). */
export declare function hevcCodecString(sps: Uint8Array): string | null;
/** The HEVCDecoderConfigurationRecord for these parameter sets, with 4-byte NAL lengths; null without an SPS it can read. */
export declare function hvcC(vps: Uint8Array[], sps: Uint8Array[], pps: Uint8Array[]): Uint8Array | null;
