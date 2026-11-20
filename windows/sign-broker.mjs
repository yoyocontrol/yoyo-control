// The secure-desktop broker's package (docs/BROKER.md「签名」): in <dir> (yoyo-broker.exe, yoyo-winvideo.exe,
// yoyo-wininput.exe) writes manifest.txt (version, floor, each file's sha256 and size), manifest.sig (ECDSA P-256 over
// SHA-256 of the manifest's bytes, raw r‖s) and trust.txt (the public key the broker checks it with).
//
//   node windows/sign-broker.mjs <key.pem> <dir> <version> <floor>
import { createHash, createPrivateKey, createPublicKey, sign } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [keyFile, dir, version, floor] = process.argv.slice(2);
if (!keyFile || !dir || !version || !floor) {
  console.error("usage: node sign-broker.mjs <key.pem> <dir> <version> <floor>");
  process.exit(2);
}
const ok = (v) => /^[a-z0-9.-]{1,16}$/.test(v);
if (!ok(version) || !ok(floor)) throw new Error("bad version / floor");
const key = createPrivateKey(readFileSync(keyFile));
let manifest = `yoyo-broker-manifest 1\nversion ${version}\nfloor ${floor}\n`;
for (const name of ["yoyo-broker.exe", "yoyo-winvideo.exe", "yoyo-wininput.exe"]) {
  const b = readFileSync(join(dir, name));
  manifest += `${createHash("sha256").update(b).digest("hex")} ${b.length} ${name}\n`;
}
writeFileSync(join(dir, "manifest.txt"), manifest);
writeFileSync(join(dir, "manifest.sig"), sign("sha256", Buffer.from(manifest), { key, dsaEncoding: "ieee-p1363" }));
// SPKI DER of a P-256 key ends with 04 ‖ X ‖ Y
const spki = createPublicKey(key).export({ type: "spki", format: "der" });
writeFileSync(join(dir, "trust.txt"), `yoyo-broker-key 1\n${spki.subarray(spki.length - 64).toString("base64")}\n`);
console.log(`signed the broker's ${version} (floor ${floor}) in ${dir}`);
