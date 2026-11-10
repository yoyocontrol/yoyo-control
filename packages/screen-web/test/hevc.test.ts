import assert from "node:assert/strict";
import { test } from "node:test";
import { hevcCodecString, hevcNalType, hvcC, parseHevcSps, splitHevcAccessUnit } from "../src/hevc.js";

// one key picture's parameter sets from VideoToolbox's HEVC encoder (the Mac's), 1280×720 Main; the record is what
// ffmpeg writes into an MP4 for the same stream
const hex = (s: string) => Uint8Array.from(s.match(/../g)!.map((b) => parseInt(b, 16)));
const VPS = hex("40010c01ffff016000000300b0000003000003005d170240");
const SPS = hex("420101016000000300b0000003000003005da00280802d16205ee45914bff2e7f13fac05a810101004");
const PPS = hex("4401c072f05324");
const FFMPEG_HVCC = hex(
  "010160000000b000000000005df000fcfdf8f800000f03a00001001840010c01ffff016000000300b0000003000003005d170240a100010029420101016000000300b0000003000003005da00280802d16205ee45914bff2e7f13fac05a810101004a2000100074401c072f05324",
);
const startCode = [0, 0, 0, 1];
const annexB = (...units: Uint8Array[]) => Uint8Array.from(units.flatMap((u) => [...startCode, ...u]));

test("an HEVC key picture: parameter sets apart, the slices in the sample", () => {
  const idr = Uint8Array.from([0x26, 0x01, 0xaf, 0x00, 0x00, 0x03, 0x01]); // IDR_W_RADL
  const aud = Uint8Array.from([0x46, 0x01, 0x50]);
  const au = splitHevcAccessUnit(annexB(aud, VPS, SPS, PPS, idr));
  assert.deepEqual([au.vps.length, au.sps.length, au.pps.length, au.slices.length, au.idr], [1, 1, 1, 1, true]);
  assert.equal(hevcNalType(au.slices[0]!), 19);
  const trail = splitHevcAccessUnit(annexB(Uint8Array.from([0x02, 0x01, 0xd0])));
  assert.deepEqual([trail.slices.length, trail.idr], [1, false]);
});

test("the SPS's profile, level and format", () => {
  const s = parseHevcSps(SPS)!;
  assert.deepEqual(
    { space: s.profileSpace, tier: s.tier, profile: s.profileIdc, level: s.levelIdc, chroma: s.chromaFormatIdc, luma: s.bitDepthLumaMinus8, nested: s.temporalIdNested },
    { space: 0, tier: 0, profile: 1, level: 93, chroma: 1, luma: 0, nested: true },
  );
  assert.equal(s.compatibility, 0x60000000);
  assert.equal(parseHevcSps(SPS.subarray(0, 8)), null);
});

test("the codec string and the hvcC record are ffmpeg's", () => {
  assert.equal(hevcCodecString(SPS), "hvc1.1.6.L93.B0");
  assert.deepEqual(hvcC([VPS], [SPS], [PPS]), FFMPEG_HVCC);
  assert.equal(hvcC([], [SPS], [PPS]), null);
});
